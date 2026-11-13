-- Ducking on the game's side: the character's hull and every game call ducking makes, but
-- the eye's (camera.lua) and the keys' (keys.lua). Half-Life's duck itself runs in duck.lua,
-- update by update; this file gives it the room it has and makes Unreal's capsule follow it.
--
-- The hull is Unreal's own crouch: the mod sets the crouched half height to the standing one
-- less Half-Life's 18 units (45 cm), and asks for a crouch by writing the movement component's
-- bWantsToCrouch, last in the frame hook (after any SetMovementMode of the hook: ALS clears the
-- wish inside that call). Unreal crouches or stands the capsule up at the start of its movement
-- update after the hook, so the answer is read at the next hook (hull.read). Unreal keeps the
-- feet on the ground and the middle in the air, as Half-Life does; where Half-Life changes the
-- hull on the ground in an update that then leaves it (a duck or a stand-up before the jump),
-- the mod has Unreal keep the feet too (bCrouchMaintainsBaseLocation, written true for that
-- update and false again at the next hook in the air).
--
-- Whose crouch it is: the mod never clears a crouch it didn't ask for. It takes the wish only
-- when the wish isn't set and the capsule isn't crouched, or the crouch is its own from before
-- (owned, pendingStand, leftover); a crouch the game makes is left alone, and while it lasts
-- Half-Life's player stays fully ducked (no stand-up, no tap: hull.room). Handing back (a battle,
-- an area change, the mod switched off) clears the wish the mod holds and puts its values back;
-- Unreal then stands the character up as soon as there is room, with or without the mod.
--
-- Unreal's answers go to the physics (duck.confirm): a stand-up Unreal refused leaves Half-Life's
-- player fully ducked whatever it did since (the physics stands up at once where it may, and
-- learns the refusal a frame later), a crouch the game made makes it fully ducked, a stand-up
-- Unreal made late stands it up. A hull change Unreal made in the air moves the capsule's middle
-- against Half-Life's origin by what the change kept, measured against the free path, which
-- re-bases the eye (duck.rebase). Detectors give the hull change up for the session where the
-- game doesn't let the character crouch (on the ground: no hull change at all; in the air only:
-- the crouch on the ground alone), where its crouch flushes the duck key, or where something
-- keeps standing the character up; each with one warning and a state line.
--
-- Standing up in the air, Unreal doesn't refuse near a floor (it moves the character up to
-- stand), where Half-Life does: hull.floorRoom asks first how far the floor is. The duck tap's
-- lift is a swept move 18 units up (Half-Life's room test), then a placement 16 1/32 units less
-- the walking gap up, so that Unreal's landing on contact comes when Half-Life's ground check
-- would catch the player (hull.lift). And the frame of braking ALS's stance change brings back
-- inside Unreal's update is given back on the next hook, within what such a frame can take
-- (hull.brakeBack).
--
-- Every game call runs inside a guarded step ("ducking the character", "the duck tap's lift",
-- "the floor below, for standing up in the air"): one that fails 30 times in a row is turned off
-- with its clean-up, until F5 or F7. Every value changed is remembered (overrides.lua, and the
-- journal's "field" kind for NavAgentProps.bCanCrouch), and the wish while the mod holds it is in
-- the journal too, so a UE4SS mods restart in mid-duck puts them all back.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local duck = require("hl1movement.duck")
local Overrides = require("hl1movement.overrides")

local hull = {}

local FALLING = 3

local STEP = "ducking the character"
local LIFT_STEP = "the duck tap's lift"
local FLOOR_STEP = "the floor below, for standing up in the air"
hull.STEP, hull.LIFT_STEP, hull.FLOOR_STEP = STEP, LIFT_STEP, FLOOR_STEP

-- Half-Life's hulls: the standing one's lower edge is 18 units below the ducked one's on the
-- ground, and the duck tap puts the standing player 18 units up, which needs that much room above.
local SHIFT_UNITS = duck.SHIFT
-- The tap's placement: 16 1/32 units above where the player stood (less Unreal's walking gap),
-- 2 units below Half-Life's lift, so that Unreal's landing on contact comes at Half-Life's catch.
local PLACE_UNITS = 16 + 1 / 32
local LIFT_SHORT = 0.1 -- cm: a sweep that stops this much short still arrived
local LIFT_ACROSS = 0.5 -- cm: and moved no further sideways than this
-- After a refused lift, +ducktap doesn't sweep again until this much time has passed (s) or the
-- character moved this far across (cm): each sweep is a hit event for the game.
local LIFT_WAIT, LIFT_MOVE = 0.1, 10
-- Unreal's walking gap above the floor (CurrentFloor.FloorDist): 2.15 cm when it can't be read,
-- and a reading beyond 3 cm isn't one.
local WALK_GAP, GAP_MAX = 2.15, 3
-- The floor query sweeps the ducked capsule this far beyond the hulls' difference, and the
-- standing feet need the difference and this margin (cm): Unreal's own test is 0.001 cm stricter.
local FLOOR_SWEEP, FLOOR_MARGIN = 2.5, 0.5
-- A stand-up in the air whose middle rose more than this above what the request should give is
-- one Unreal made by moving the character up (cm).
local POPUP = 5
-- ALS's one frame of braking at a stance change, given back up to this share of the speed and
-- this deceleration over the frame (cm/s²), in the same direction within 2 degrees.
local BRAKE_SHARE, BRAKE_RATE, BRAKE_COS = 0.1, 5000, math.cos(math.rad(2))
local BRAKE_TINY = 0.5 -- cm/s: less is nothing to give back
-- The detectors: so many in a row (or within the window, s) give the hull change up.
local REFUSALS = 3
local UNCROUCHES, UNCROUCH_WINDOW = 3, 10
local FLUSHES, FLUSH_WINDOW = 3, 0.03 -- (the window decides only after a frame over 0.03 s: the second hook
-- with the key up counts anyway; no test holds it)
local MAX_NOTE_LINES = 3 -- for each kind of thing the game did, until F7 (see hull.logAgain)
local CAN_CROUCH = "NavAgentProps.bCanCrouch" -- (its journal id: a field of a struct property)

local overrides = Overrides.new()

local function newCounts()
    return { groundCrouches = 0, airCrouches = 0, groundStands = 0, airStands = 0, refusedGroundDucks = 0,
        refusedAirDucks = 0, standRefusals = 0, lateStands = 0, popups = 0, gameCrouches = 0, gameStands = 0,
        gameUncrouches = 0, flushSuspects = 0, wishClears = 0, lifts = 0, refusedLifts = 0, brakeGiven = 0,
        brakeKept = 0, brakeTotal = 0, brakeLargest = 0, floorQueries = 0, floorRoom = 0, floorNoRoom = 0,
        rebases = 0, rebasesMeasured = 0, rebaseLargest = 0, rebaseStandBase = 0, rebaseCrouchBase = 0,
        rebaseMiddleKept = 0, rebaseUnasked = 0 }
end

local st = {
    -- For the session, until F5 or F7 (hull.reset): the way the hull follows the duck ("crouch",
    -- "ground": Unreal's crouch on the ground only, "none": no hull change, "off": Ducking =
    -- false), the state line saying why, and the detectors' counts.
    way = nil,
    why = nil,
    fresh = true, -- the next take-over starts the way again
    refused = { ground = 0, air = 0 }, -- ducks in a row the capsule never crouched for
    uncrouchTimes = {}, -- when something in the game stood the character up while the mod held the crouch
    flushes = 0, -- crouches in a row after which the duck key read as let go
    counts = newCounts(), -- since the mod loaded, for the report
    taken = newCounts(), -- the same, at the last hull.takeStats
    noteLines = {}, -- lines about what the game did, by kind, since F7
    -- The character: its movement component and pawn, and its capsule standing (cm, scaled;
    -- the unscaled half height, the scale and the radius), the crouched half height the mod
    -- writes (unscaled) and the hulls' difference (scaled).
    cmc = nil,
    cmcName = nil,
    pawn = nil,
    standHalf = nil,
    standHalfUnscaled = nil,
    scale = nil,
    radius = nil,
    crouchedHalf = nil,
    delta = nil,
    canCrouchSeen = nil, -- NavAgentProps.bCanCrouch as the mod first read it
    canCrouchWritten = false, -- the mod set it true, to put back
    owned = false, -- the mod wrote bWantsToCrouch = true and hasn't handed it back
    wishKept = false, -- and kept it true at the last hook (an owned wish left as it is: false)
    pendingStand = false, -- the mod let go of its crouch, and the capsule still read crouched
    leftover = false, -- the same, across a hand-back
    restoredWish = nil, -- the movement component (full name) whose crouch wish a UE4SS mods restart's journal cleared
    byGame = false, -- the crouch is the game's
    refusedGround = false, -- Unreal refused a stand-up on the ground, in the air
    refusedAir = false,
    liftHeld = nil, -- { x, y, time }: after a refused lift
    -- This hook and the last request.
    firstRead = false, -- the next hull.read is the first since the take-over
    crouched = nil, -- bIsCrouched at the last hook that read it (nil: none since the take-over)
    wishTrue = false, -- bWantsToCrouch read true at this hook (read only while the mod holds it)
    falling = false,
    at = nil,
    req = nil, -- the last hook's request: { falling, duckKey, time }
    run = nil, -- the crouch requests of one kind (falling or not) in a row: { falling, got }
    lastAsk = nil, -- what the last request has Unreal do: "crouch-base", "crouch", "stand-base", "stand" or nil
    answer = nil, -- what Unreal answered at this hook, for the movement's lines
    brakeArmed = nil, -- "crouched" or "stood": Unreal changed the hull the mod asked for, walking at both hooks
    flushWatch = nil, -- { time, seenUp }: after a ground crouch asked with a duck key held
    clock = 0, -- s: the frames the mod asked the hull for, added up
    hookError = nil, -- the first error of the hull's work since the last request
    baseWritten = false, -- the last request wrote bCrouchMaintainsBaseLocation true (for one update)
    keepSpeed = true,
    unitScale = 2.5,
}

local function count(name, amount)
    st.counts[name] = st.counts[name] + (amount or 1)
end

-- One more of a kind of thing the game did: whether it still gets a line (3 per F7).
local function noted(name)
    st.noteLines[name] = (st.noteLines[name] or 0) + 1
    return st.noteLines[name] <= MAX_NOTE_LINES, st.noteLines[name] == MAX_NOTE_LINES
end

local function note(name, fmt, ...)
    local logged, last = noted(name)
    if logged then
        log.info("%s%s", string.format(fmt, ...), last and " (not logged again)" or "")
    end
end

local function setWay(way, why)
    st.way, st.why = way, why
    log.state("Ducking", why)
end

-- Runs fn; an error is kept for the next request, which counts the hook's work as one step.
local function attempt(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not st.hookError then
        st.hookError = err
    end
    return ok
end

local function sameCharacter(cmc)
    return st.cmc ~= nil and ue.same(cmc, st.cmc)
end

-- The class's default capsule half height (unscaled), which Unreal stands a crouched
-- character up to: the class default object's CapsuleComponent.CapsuleHalfHeight.
local function classDefaultHalf(pawn)
    if not ue.valid(pawn) then
        return nil
    end
    local okClass, class = pcall(function()
        return pawn:GetClass()
    end)
    local name = okClass and ue.fullName(class)
    local path = name and name:match("^%S+ (.+)$")
    local outer, short = (path or ""):match("^(.*)%.([^.:]+)$")
    if not outer then
        return nil
    end
    local cdo = ue.find(outer .. ".Default__" .. short)
    local capsule = cdo and ue.object(cdo, "CapsuleComponent")
    local half = capsule and ue.number(capsule, "CapsuleHalfHeight")
    if half and half > 0 then
        return half
    end
    return nil
end

-- The standing capsule, from the capsule if it stands, else from the class default.
local function measure(pawn, crouched)
    local capsule = ue.object(pawn, "CapsuleComponent")
    if not capsule then
        return
    end
    local okScaled, scaled = ue.call(capsule, "GetScaledCapsuleHalfHeight")
    local okUnscaled, unscaled = ue.call(capsule, "GetUnscaledCapsuleHalfHeight")
    local okRadius, radius = ue.call(capsule, "GetScaledCapsuleRadius")
    if not (okScaled and okUnscaled and okRadius and type(scaled) == "number" and type(unscaled) == "number"
        and type(radius) == "number" and scaled > 0 and unscaled > 0 and radius > 0) then
        return
    end
    local scale = scaled / unscaled
    if crouched then
        unscaled = classDefaultHalf(pawn)
        if not unscaled then
            return -- (until the capsule reads standing: no crouch is asked for before)
        end
        scaled = unscaled * scale
    end
    st.standHalf, st.standHalfUnscaled, st.scale, st.radius = scaled, unscaled, scale, radius
    st.crouchedHalf = math.max(unscaled - SHIFT_UNITS * st.unitScale / scale, radius / scale + 1)
    st.delta = scaled - st.crouchedHalf * scale
end

local function hullChanges()
    return st.way == "crouch" or st.way == "ground"
end

-- The values the crouch needs: the crouched half height, walking off ledges crouched, and
-- crouching allowed at all (NavAgentProps.bCanCrouch, only if it isn't).
local function writeValues(cmc, verify)
    if not hullChanges() or not st.standHalf then
        return
    end
    overrides:set(cmc, "CrouchedHalfHeight", st.crouchedHalf, verify)
    overrides:set(cmc, "bCanWalkOffLedgesWhenCrouching", true, verify)
    local nav = ue.get(cmc, "NavAgentProps")
    if ue.typeOf(nav) ~= "UScriptStruct" then
        return
    end
    local can = ue.bool(nav, "bCanCrouch")
    if st.canCrouchSeen == nil then
        st.canCrouchSeen = can
    end
    if can ~= false then
        return -- true, or it can't be read: then nothing is written or put back
    end
    log.first("can-crouch", "Allowing the character to crouch (NavAgentProps.bCanCrouch was false)")
    cmc.NavAgentProps = { bCanCrouch = true }
    if ue.bool(ue.get(cmc, "NavAgentProps"), "bCanCrouch") == true then
        if not st.canCrouchWritten then
            st.canCrouchWritten = true
            journal.note("field", st.cmcName, CAN_CROUCH, false)
        end
    else
        log.once("can-crouch-write", "NavAgentProps.bCanCrouch didn't take the mod's true: the character may not "
            .. "crouch (the mod notices if it doesn't).")
    end
end

local function putValuesBack(same)
    overrides:restore()
    if st.canCrouchWritten then
        st.canCrouchWritten = false
        journal.forget("field", st.cmcName, CAN_CROUCH)
        if same then
            pcall(function()
                st.cmc.NavAgentProps = { bCanCrouch = false }
            end)
        end
    end
end

local function takeOwnership(cmc)
    st.owned, st.pendingStand, st.leftover, st.byGame = true, false, false, false
    journal.note("prop", st.cmcName, "bWantsToCrouch", false)
    log.first("crouch", "Asking Unreal to crouch the character for the first time (bWantsToCrouch; "
        .. "CrouchedHalfHeight %.1f cm)", st.crouchedHalf * st.scale)
    cmc.bWantsToCrouch = true
end

local function giveUp(cmc)
    st.owned, st.wishKept = false, false
    journal.forget("prop", st.cmcName, "bWantsToCrouch")
    st.pendingStand = st.crouched == true
    cmc.bWantsToCrouch = false
end

-- The hull change given up for the session (a detector, or the step's errors).
local function noHull(why, warning, ...)
    if st.owned and st.cmc and ue.valid(st.cmc) then
        pcall(giveUp, st.cmc)
    end
    st.owned, st.wishKept, st.run, st.flushWatch = false, false, nil, nil
    if st.cmc and ue.valid(st.cmc) then
        putValuesBack(ue.fullName(st.cmc) == st.cmcName)
    end
    setWay("none", why)
    if warning then
        log.warn(warning, ...)
    end
end

local function canCrouchNow()
    local nav = st.cmc and ue.get(st.cmc, "NavAgentProps")
    local can = ue.typeOf(nav) == "UScriptStruct" and ue.bool(nav, "bCanCrouch")
    local ok, result = false, nil
    if st.pawn then
        ok, result = ue.call(st.pawn, "CanCrouch")
    end
    return tostring(can), ok and tostring(result) or "?"
end

-- A run of crouch requests of one kind ended: it got the crouch, or one more refused duck.
local function endRun()
    local run = st.run
    st.run = nil
    if not run then
        return
    end
    local kind = run.falling and "air" or "ground"
    if run.got then
        st.refused[kind] = 0
        return
    end
    st.refused[kind] = st.refused[kind] + 1
    count(run.falling and "refusedAirDucks" or "refusedGroundDucks")
    if st.refused[kind] < REFUSALS then
        return
    end
    if kind == "ground" then
        local can, call = canCrouchNow()
        noHull(string.format("on: no hull change (the game doesn't let the character crouch: %d ducks without a "
            .. "crouch; NavAgentProps.bCanCrouch %s, CanCrouch() %s)", REFUSALS, can, call),
            "The game doesn't let the character crouch (%d ducks without a crouch; NavAgentProps.bCanCrouch %s, "
            .. "CanCrouch() %s): ducking goes on without the hull change, so the character no longer fits under "
            .. "low things. Please report UE4SS.log.", REFUSALS, can, call)
    elseif st.way == "crouch" then
        setWay("ground", "on: Unreal's crouch on the ground, no hull change in the air (the game doesn't let a "
            .. "falling character crouch)")
        log.warn("The game doesn't let a falling character crouch (%d ducks in the air without a crouch): the hull "
            .. "changes on the ground only, so ducked hops land as standing ones. Please report UE4SS.log.", REFUSALS)
    end
end

local function gameUncrouched()
    count("gameUncrouches")
    local times = st.uncrouchTimes
    times[#times + 1] = st.clock
    while times[1] and st.clock - times[1] > UNCROUCH_WINDOW do
        table.remove(times, 1)
    end
    note("gameUncrouch", "Something in the game stood the character up while the mod kept it ducked; the mod asks "
        .. "for the crouch again")
    if #times >= UNCROUCHES then
        noHull(string.format("on: no hull change (something in the game stood the character up %d times in %d s "
            .. "while the mod kept it ducked)", UNCROUCHES, UNCROUCH_WINDOW),
            "Something in the game stood the character up %d times in %d s while the mod kept it ducked: ducking goes "
            .. "on without the hull change. Please report UE4SS.log.", UNCROUCHES, UNCROUCH_WINDOW)
    end
end

local function halfNow(pawn)
    local capsule = ue.object(pawn, "CapsuleComponent")
    local ok, half = false, nil
    if capsule then
        ok, half = ue.call(capsule, "GetScaledCapsuleHalfHeight")
    end
    return ok and type(half) == "number" and half or nil
end

-- The lines with what Unreal did at the first crouch and stand-up on the ground and in the air
-- (once a session each: their game reads only then).
local evidenced = {}
local function evidence(pawn, crouched, falling, moved, req)
    local what = crouched and "crouch" or "stand"
    local key = string.format("evidence-%s-%s", what, falling and "air" or "ground")
    if evidenced[key] then
        return
    end
    evidenced[key] = true
    local half = halfNow(pawn)
    local from = crouched and st.standHalf or (half and st.delta and half - st.delta)
    local feet = moved and half and from and moved - (half - from)
    local eyes = string.format("BaseEyeHeight %s (CrouchedEyeHeight %s)", tostring(ue.number(pawn, "BaseEyeHeight")),
        tostring(ue.number(pawn, "CrouchedEyeHeight")))
    log.info("The character %s (Unreal's %s, %s): half height %s -> %s cm, middle moved %s cm, feet moved %s "
        .. "cm, %s%s", crouched and "crouched" or "stood up", crouched and "crouch" or "un-crouch",
        falling and "in the air" or "on the ground", from and string.format("%.1f", from) or "?",
        half and string.format("%.1f", half) or "?", moved and string.format("%+.1f", moved) or "?",
        feet and string.format("%+.1f", feet) or "?", eyes,
        crouched and string.format(", the duck key still held: %s", req and req.duckKey and "yes" or "no") or "")
end

-- What the last request has Unreal do to the middle, against the free path (cm).
local function expectedRise(crouched)
    local delta = st.delta or 0
    if crouched then
        return st.lastAsk == "crouch-base" and -delta or 0
    end
    return st.lastAsk == "stand-base" and delta or 0
end

local function readAnswers(pawn, cmc, d, at, mode, w, P)
    local crouched = ue.bool(pawn, "bIsCrouched") == true
    local falling = mode == FALLING
    st.wishTrue = st.owned and ue.bool(cmc, "bWantsToCrouch") == true
    local was, req = st.crouched, st.req
    st.req = nil
    if not st.standHalf and not crouched then
        measure(pawn, false)
        writeValues(cmc, false)
    end
    local reqFalling = req and req.falling
    if reqFalling == nil then
        reqFalling = falling
    end
    local first = st.firstRead
    st.firstRead = false
    -- How far the middle moved since the last hook: in the air against the free path of the
    -- vertical speed written (and of a platform that carries the character in the air:
    -- w.baseZ, with bStayBasedInAir), on the ground in all.
    local moved
    if w and w.at and at and w.dt then
        moved = falling and (at.Z - (w.at.Z + ((w.z or 0) + (w.baseZ or 0)) * w.dt - 0.5 * P.gravity * w.dt * w.dt))
            or (at.Z - w.at.Z)
    end
    if st.owned then
        if st.wishKept and not st.wishTrue then
            count("wishClears")
            note("wishClear", "ALS or the game cleared the crouch wish the mod holds (bWantsToCrouch); the mod asks "
                .. "again")
        end
        if crouched then
            if st.run then
                st.run.got = true
            end
            if was == false then
                st.answer = "ducked"
                count(reqFalling and "airCrouches" or "groundCrouches")
                st.refused[reqFalling and "air" or "ground"] = 0
                evidence(pawn, true, reqFalling, moved, req)
                if not falling and not reqFalling then
                    st.brakeArmed = "crouched"
                    if req and req.duckKey then
                        st.flushWatch = { time = req.time, seenUp = false }
                    end
                end
            end
        elseif was == true and not falling then
            st.answer = "uncrouched by the game"
            gameUncrouched()
        elseif was == true then
            st.answer = "uncrouched in the air" -- (the engine's rule for falling crouches: the air's run counts it)
        end
    elseif st.pendingStand or st.leftover then
        if crouched and first then
            -- (A crouch of the mod's left at a hand-back, read as the take-over begins: Unreal may
            -- have had no update since, as when F7 hands back and takes over in one hook.)
            st.answer = nil
        elseif crouched then
            st.answer = "stand refused"
            if d and d.state ~= duck.DUCKED then
                duck.confirm(d, "refused")
            end
            local flag = reqFalling and "refusedAir" or "refusedGround"
            if not st[flag] then
                st[flag] = true
                count("standRefusals")
                note("standRefused", "No room to stand up (%s, under something): the character stays ducked and "
                    .. "stands up as soon as there is room", reqFalling and "in the air" or "on the ground")
            end
        else
            st.answer = "stood"
            if d and d.state == duck.DUCKED then
                duck.confirm(d, "stood")
                st.answer = "stood late"
                count("lateStands")
            end
            if was == true then
                count(reqFalling and "airStands" or "groundStands")
                evidence(pawn, false, reqFalling, moved, req)
                if not falling and not reqFalling then
                    st.brakeArmed = "stood"
                end
            end
            st.pendingStand, st.leftover = false, false
        end
    elseif st.byGame then
        if not crouched and was == true then
            st.byGame = false
            st.answer = "stood by the game"
            if d and d.state ~= duck.STANDING then
                duck.confirm(d, "stood")
            end
            count("gameStands")
            note("gameStand", "The game stood the character up itself")
        end
    elseif crouched then
        st.byGame = true
        st.answer = "crouched by the game"
        if d and d.state ~= duck.DUCKED then
            duck.confirm(d, "crouched")
        end
        count("gameCrouches")
        note("gameCrouch", "The game crouched the character itself: the mod leaves its crouch alone, and the "
            .. "Half-Life duck stays fully ducked while it lasts")
    end
    if not crouched then
        st.refusedGround, st.refusedAir = false, false
    elseif falling then
        st.refusedGround = false
    else
        st.refusedAir = false
    end
    -- Unreal changed the hull in its last update, in the air: Half-Life's origin didn't move
    -- with the capsule's middle, so the drop changes by how far the middle moved against the
    -- free path (Unreal's falling move takes the frame's gravity, then moves with the mean of
    -- the two speeds: exactly that sum). Without the frame before, the request's own move.
    if falling and was ~= nil and crouched ~= was and d then
        local expected = expectedRise(crouched)
        local rise = moved or expected
        duck.rebase(d, rise)
        count("rebases")
        local ask = st.lastAsk
        if ask and (ask:find("^crouch") ~= nil) == crouched then
            count(ask == "stand-base" and "rebaseStandBase" or ask == "crouch-base" and "rebaseCrouchBase"
                or "rebaseMiddleKept")
        else
            count("rebaseUnasked")
        end
        if moved then
            count("rebasesMeasured")
            st.counts.rebaseLargest = math.max(st.counts.rebaseLargest, math.abs(rise - expected))
            local asked = st.lastAsk == "stand" or st.lastAsk == "stand-base"
            if not crouched and asked and rise - expected > POPUP then
                count("popups")
                note("popup", "Unreal stood the character up %.1f cm higher than its place in the air (the floor "
                    .. "below was closer than the mod's query found)", rise - expected)
            end
        end
    end
    st.crouched, st.falling, st.at = crouched, falling, at
    return crouched
end

--- Starts the way again at the next take-over (Unreal's crouch, or none with DuckHull =
--- false): for F5 and F7.
function hull.reset()
    st.fresh = true
end

local function newCharacter(pawn, cmc, name)
    st.cmc, st.cmcName, st.pawn = cmc, name, pawn
    st.standHalf, st.standHalfUnscaled, st.scale, st.radius, st.crouchedHalf, st.delta = nil, nil, nil, nil, nil, nil
    st.canCrouchSeen, st.canCrouchWritten = nil, false
    st.owned, st.wishKept, st.pendingStand, st.leftover, st.byGame = false, false, false, false, false
    st.refusedGround, st.refusedAir, st.liftHeld = false, false, nil
end

local function takeOverNow(pawn, cmc, cfg, P)
    st.unitScale = P.unitScale or st.unitScale
    st.keepSpeed = cfg.KeepSpeed ~= false
    if cfg.Ducking == false then
        if st.way ~= "off" then
            setWay("off", "off (Ducking = false)")
        end
        st.fresh = true
    elseif st.fresh or st.way == nil or st.way == "off" then
        st.fresh = false
        st.refused.ground, st.refused.air, st.uncrouchTimes, st.flushes = 0, 0, {}, 0
        if cfg.DuckHull == false then
            setWay("none", "on: no hull change (DuckHull = false)")
        else
            setWay("crouch", "on: Unreal's crouch")
        end
    end
    local name = ue.fullName(cmc)
    if not (sameCharacter(cmc) and name == st.cmcName) then
        newCharacter(pawn, cmc, name)
    end
    st.pawn = pawn
    if st.restoredWish and st.restoredWish == name and ue.bool(pawn, "bIsCrouched") == true then
        -- The previous copy's crouch, still on after a UE4SS mods restart: the mod's (as after
        -- a hand-back), not the game's.
        st.leftover, st.byGame = true, false
    end
    st.restoredWish = nil
    st.crouched, st.req, st.run, st.lastAsk, st.answer, st.brakeArmed, st.flushWatch = nil, nil, nil, nil, nil, nil, nil
    st.firstRead = true
    if not hullChanges() then
        return
    end
    if not st.standHalf then
        measure(pawn, ue.bool(pawn, "bIsCrouched") == true)
    end
    writeValues(cmc, true)
end

--- After a UE4SS mods restart, from main.lua's put-back of the journal: the previous copy's
--- crouch wish on this movement component (full name) was cleared. If the capsule still reads
--- crouched at the next take-over, that crouch is the mod's leftover, not the game's.
function hull.restoredWish(fullName)
    st.restoredWish = fullName
end

--- On the frame the mod takes over the character's movement: the way, the character's
--- standing capsule (or, first seen crouched, its class default's) and the values the crouch
--- needs. cfg's Ducking and DuckHull (false: no duck at all, no hull change), KeepSpeed.
function hull.takeOver(pawn, cmc, cfg, P)
    if guard.isOff(STEP) then
        return
    end
    attempt(takeOverNow, pawn, cmc, cfg, P)
end

--- At the movement's half-second refresh: the values the crouch needs again (and their objects'
--- full names checked), in case the game wrote its own meanwhile.
function hull.refresh(pawn, cmc)
    if guard.isOff(STEP) or not sameCharacter(cmc) then
        return
    end
    attempt(function()
        st.pawn = pawn
        writeValues(cmc, true)
    end)
end

--- Early in each frame the mod moves the character (and in root motion): what Unreal made of
--- the last request (bIsCrouched, and bWantsToCrouch while the mod holds it), told to the
--- Half-Life duck state d (duck.confirm), the detectors, and the drop re-based after a hull
--- change in the air (duck.rebase), from at (the location read at this hook), mode, w (the
--- movement's record of the last frame: at, z, dt; nil after a frame the mod didn't move the
--- character) and P (P.gravity). Returns whether the capsule reads crouched.
function hull.read(pawn, cmc, d, at, mode, w, P)
    st.answer, st.brakeArmed = nil, nil
    if st.way == "off" or guard.isOff(STEP) or not sameCharacter(cmc) then
        return ue.bool(pawn, "bIsCrouched") == true
    end
    local crouched
    attempt(function()
        crouched = readAnswers(pawn, cmc, d, at, mode, w, P)
    end)
    if crouched == nil then
        crouched = ue.bool(pawn, "bIsCrouched") == true
    end
    return crouched
end

--- What Unreal answered at this hook's hull.read: "ducked", "stood", "stood late" (a stand-up
--- Unreal had refused, made now), "stand refused", "crouched by the game", "stood by the game",
--- "uncrouched by the game", "uncrouched in the air", or nil.
function hull.answer()
    return st.answer
end

local function floorQuery(cmc, at)
    if not (at and st.radius and st.delta) then
        return false
    end
    log.first("floor-query", "Asking Unreal for the floor below the character for the first time "
        .. "(K2_ComputeFloorDist), to stand up in the air")
    count("floorQueries")
    local out = {}
    cmc:K2_ComputeFloorDist({ X = at.X, Y = at.Y, Z = at.Z }, 0, st.delta + FLOOR_SWEEP, st.radius, out)
    local dist = out.FloorDist
    local room = type(dist) == "number" and dist >= st.delta + FLOOR_MARGIN
    count(room and "floorRoom" or "floorNoRoom")
    return room
end

--- Whether the standing capsule has room below to stand up in the air here: asked at the hook,
--- before the physics, where the physics is fully ducked, Unreal falls, no slide is on and
--- some update of the hook may stand up (the caller's conditions); it asks only while the
--- capsule reads crouched in the air. nil: not asked (then the air is open); false also when
--- the query fails or its step was turned off (the duck waits for the ground: never a pop-up).
function hull.floorRoom(cmc, at)
    if not hullChanges() or st.crouched ~= true or not st.falling then
        return nil
    end
    if guard.isOff(FLOOR_STEP) then
        return false
    end
    local ok, room = guard.run(FLOOR_STEP, floorQuery, cmc, at)
    return ok and room == true
end

local function liftHeld()
    local held = st.liftHeld
    if not held then
        return false
    end
    local at = st.at
    local far = at and ((at.X - held.x) ^ 2 + (at.Y - held.y) ^ 2 >= LIFT_MOVE * LIFT_MOVE)
    if far or st.clock - held.time >= LIFT_WAIT then
        st.liftHeld = nil
        return false
    end
    return true
end

--- The room the frame's Half-Life updates have (duck.step's room): ground, air and lift,
--- each false where Unreal can't: a stand-up on the ground Unreal refused, one in the air
--- (refused, while sliding, or roomBelow false: hull.floorRoom), a lift held back after one was
--- refused or turned off by its errors, or in nav-mesh walking (navWalking: Unreal's capsule
--- ignores static and dynamic geometry there, so the lift's sweep would test nothing); none
--- at all while the crouch is the game's.
function hull.room(_, sliding, roomBelow, navWalking)
    local room = { ground = true, air = true, lift = true }
    if st.byGame and st.crouched == true then
        room.ground, room.air, room.lift = false, false, false
        return room
    end
    room.ground = not st.refusedGround
    room.air = not (sliding or st.refusedAir or roomBelow == false)
    room.lift = not (navWalking or liftHeld() or guard.isOff(LIFT_STEP))
    return room
end

local function putBack(pawn, at)
    pawn:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = at.Z }, false, {}, true)
end

local function sweepUp(pawn, at, sweep, h)
    pawn:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = at.Z + sweep }, true, {}, true)
    local after = pawn:K2_GetActorLocation()
    if type(after) ~= "table" then
        return false, nil
    end
    local x, y, z = ue.vector(after)
    local rose = z - at.Z
    if rose < sweep - LIFT_SHORT or math.abs(x - at.X) > LIFT_ACROSS or math.abs(y - at.Y) > LIFT_ACROSS then
        return false, rose
    end
    pawn:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = at.Z + h }, false, {}, true)
    local placed = pawn:K2_GetActorLocation()
    if type(placed) ~= "table" then
        placed = { X = at.X, Y = at.Y, Z = at.Z + h }
    end
    return true, placed
end

local function liftNow(pawn, at, gap)
    local s = st.unitScale
    local sweep = SHIFT_UNITS * s
    if st.crouched == true and st.delta then
        -- The hook's updates stood the physics up and then lifted it, but Unreal stands the
        -- capsule up only at the start of its update: swept this far, the crouched capsule's top
        -- reaches the lifted standing one's, Half-Life's room test.
        sweep = sweep + 2 * st.delta
    end
    if type(gap) ~= "number" or gap < 0 or gap > GAP_MAX then
        gap = WALK_GAP
    end
    local h = PLACE_UNITS * s - gap
    log.first("lift", "Lifting the character for a duck tap for the first time (K2_SetActorLocation: swept %.0f cm "
        .. "up, then placed %.1f cm up)", sweep, h)
    local ok, room, result = pcall(sweepUp, pawn, at, sweep, h)
    if not ok then
        pcall(putBack, pawn, at)
        error(room, 0)
    end
    if not room then
        putBack(pawn, at)
        st.liftHeld = { x = at.X, y = at.Y, time = st.clock }
        count("refusedLifts")
        note("refusedLift", "No room for a duck tap (only %s cm above the head): you stay on the ground",
            result and string.format("%.0f", math.max(0, result)) or "?")
        return false
    end
    count("lifts")
    return { at = result, h = h }
end

--- The duck tap's lift, at the hook after the physics ran and before the mode change: swept
--- 18 units up from at (from a capsule that reads crouched, 18 units and twice the hulls'
--- difference), then placed 16 1/32 units less gap up (CurrentFloor.FloorDist, read before; 2.15
--- cm if unreadable). Returns the location read back and the height placed (cm), or false:
--- no room (the character is put back where it stood, and the lift held back for 0.1 s or 10 cm)
--- or an error (also put back; 30 in a row turn lifts off, see hull.liftOff).
function hull.lift(pawn, _, at, gap)
    if guard.isOff(LIFT_STEP) or not at then
        return false
    end
    local ok, result = guard.run(LIFT_STEP, liftNow, pawn, at, gap)
    if ok and result then
        return result.at, result.h
    end
    return false
end

--- Whether the lift was turned off by its errors (until F5 or F7): then +ducktap keys read as up.
function hull.liftOff()
    return guard.isOff(LIFT_STEP)
end

local function requestNow(_, cmc, o)
    local crouched = st.crouched == true
    local falling = o.falling == true
    local standAllowed = (not falling and not o.sliding) or (falling and o.roomBelow == true)
    local want = o.state == duck.DUCKED and (o.button == true or not standAllowed)
    if not hullChanges() then
        want = nil -- (no hull change: nothing is asked)
    elseif want and falling and st.way == "ground" then
        want = nil -- no new crouch in the air; an owned wish is left as it is
    end
    if want == true then
        if not st.owned then
            if st.standHalf then
                local wish = ue.bool(cmc, "bWantsToCrouch")
                if wish ~= true and (not crouched or st.pendingStand or st.leftover) then
                    takeOwnership(cmc)
                elseif not st.byGame then
                    st.byGame = true -- the game wants a crouch of its own: it is the game's
                    count("gameCrouches")
                    note("gameCrouch", "The game crouched the character itself: the mod leaves its crouch alone, and "
                        .. "the Half-Life duck stays fully ducked while it lasts")
                end
            end
        elseif o.leaving or not st.wishTrue then
            cmc.bWantsToCrouch = true -- (ALS clears it as the character leaves the ground)
        end
        st.wishKept = st.owned
    elseif want == false then
        if st.owned then
            giveUp(cmc)
        end
    else
        st.wishKept = false -- (left as it is)
    end
    -- The runs of requests, for the detectors: one of each kind (in the air or not) in a row,
    -- and a flight's requests are one run (a landing hook whose jump leaves at once ends it).
    local asking = st.owned and want == true
    if st.run and (not asking or st.run.falling ~= falling or (st.run.falling and not st.falling)) then
        endRun()
    end
    if asking and not st.run and hullChanges() then
        st.run = { falling = falling, got = false }
    end
    -- What Unreal will do with the hull, and whether it keeps the feet (its update starts
    -- walking, or the flag is written for it: Half-Life changed the hull on the ground before
    -- the update that leaves it, in nav-mesh walking too). Unreal itself sets the flag only at
    -- a mode change, so a true written for that update would last the whole flight, and a
    -- later duck or stand-up in it would keep the feet: the next hook in the air writes false
    -- again (Unreal's own value while falling).
    local crouchComing = st.owned and not crouched and want == true
    local standComing = not st.owned and crouched and (st.pendingStand or st.leftover)
    local base = false
    if (crouchComing or standComing) and o.groundChange and (o.leaving or o.navWalking) then
        cmc.bCrouchMaintainsBaseLocation = true
        base = true
        st.baseWritten = true
    elseif st.baseWritten then
        if falling then
            cmc.bCrouchMaintainsBaseLocation = false
        end
        st.baseWritten = false
    end
    base = base or (not falling and not o.navWalking)
    if crouchComing then
        st.lastAsk = base and "crouch-base" or "crouch"
    elseif standComing then
        st.lastAsk = base and "stand-base" or "stand"
    else
        st.lastAsk = nil
    end
    st.req = { falling = falling, duckKey = o.duckKey == true, time = st.clock }
    -- The key flush: a ground crouch asked with a duck key held, after which the key read as let go.
    local watch = st.flushWatch
    if watch then
        if o.duckKey then
            st.flushWatch, st.flushes = nil, 0
        elseif watch.seenUp or st.clock - watch.time > FLUSH_WINDOW then
            st.flushWatch = nil
            st.flushes = st.flushes + 1
            count("flushSuspects")
            if st.flushes >= FLUSHES then
                noHull("on: no hull change (the duck key read as let go right after each crouch: the game may clear "
                    .. "held keys when it crouches)", "The duck key read as let go right after each crouch (%d "
                    .. "times): the game may clear held keys when it crouches, so ducking goes on without the hull "
                    .. "change. Please report UE4SS.log.", FLUSHES)
            end
        else
            watch.seenUp = true
        end
    end
end

--- Last in the hook, after every SetMovementMode of it: the crouch wish for Unreal's next
--- update, from o = { state (Half-Life's duck state after the frame's updates), button (the
--- duck button was down on every update of the frame), falling (Unreal starts its update
--- falling: mode 3 now or leaving), navWalking (mode 2, not leaving), sliding (a slide still
--- on), roomBelow (hull.floorRoom's answer, or nil), groundChange (the frame's last duck or
--- stand-up of Half-Life's was on the ground), leaving (a jump, a launch or a lift in this
--- hook), duckKey (a duck key, not a notch, read down at this hook), dt (the frame's length, s) }.
--- Ducked with the button held through the frame asks for the crouch; ducked with the button up
--- on some update (a stand-up the room refused) lets Unreal try to stand up where its test is
--- Half-Life's (walking, or in the air with room below) and keeps the crouch elsewhere.
function hull.request(pawn, cmc, o)
    if st.way ~= "off" and not guard.isOff(STEP) and sameCharacter(cmc) then
        attempt(requestNow, pawn, cmc, o)
        local err = st.hookError
        st.hookError = nil
        guard.run(STEP, function()
            if err then
                error(err, 0)
            end
        end)
    end
    st.clock = st.clock + (type(o.dt) == "number" and o.dt or 0)
end

--- Whether this hook's request has Unreal crouch the capsule keeping its feet (from standing):
--- the middle drops before the view is built, which the game camera anticipates.
function hull.aheadBase()
    return st.lastAsk == "crouch-base"
end

--- The character's standing capsule half height (cm, scaled), from its class default if it was
--- first seen crouched; nil until known.
function hull.standHalf()
    return st.standHalf
end

--- How much shorter the crouched capsule is than the standing one, in half height (cm, scaled:
--- 45 with the mod's crouched half height), for duck.groundDrop; nil until known.
function hull.delta()
    return st.delta
end

--- On the hook whose hull.read saw a crouch or a stand-up the mod asked for, walking at both
--- hooks, with KeepSpeed: the frame of braking ALS's stance change brought back inside Unreal's
--- update, given back (the speed written, w.x and w.y, in the direction read) if the speed read
--- back is lower by at most 10 % of it and 5000 cm/s² over the frame, in the same direction.
--- More is a wall or the game, and stays. Returns the velocity to go on with.
function hull.brakeBack(w, vx, vy)
    local kind = st.brakeArmed
    st.brakeArmed = nil
    if not kind or not st.keepSpeed or not w or w.mode == FALLING then
        return vx, vy
    end
    local wx, wy = w.x or 0, w.y or 0
    local written, speed = math.sqrt(wx * wx + wy * wy), math.sqrt(vx * vx + vy * vy)
    local drop = written - speed
    if written < 1 or speed < 1e-3 or drop <= BRAKE_TINY
        or (vx * wx + vy * wy) / (speed * written) < BRAKE_COS then
        return vx, vy
    end
    local as = kind == "crouched" and "crouched" or "stood up"
    if drop > math.min(BRAKE_SHARE * written, BRAKE_RATE * (w.dt or 0)) then
        count("brakeKept")
        note("brake", "ALS braked the character for one frame as it %s: %.0f u/s is more than a frame of braking, "
            .. "not given back", as, drop / st.unitScale)
        return vx, vy
    end
    count("brakeGiven")
    count("brakeTotal", drop)
    st.counts.brakeLargest = math.max(st.counts.brakeLargest, drop)
    note("brake", "ALS braked the character for one frame as it %s: %.0f u/s, given back", as, drop / st.unitScale)
    local k = written / speed
    return vx * k, vy * k
end

--- Hands the hull back (from movement.release): the wish the mod holds cleared (if the
--- movement component is still the same object), its values put back; a crouch of the mod's
--- still on is left for Unreal to end when there is room, and known as the mod's (leftover).
function hull.release()
    if st.cmc then
        local same = ue.valid(st.cmc) and ue.fullName(st.cmc) == st.cmcName
        local mine = st.owned or st.pendingStand or st.leftover
        if st.owned and same then
            pcall(function()
                st.cmc.bWantsToCrouch = false
            end)
        end
        journal.forget("prop", st.cmcName, "bWantsToCrouch")
        st.owned, st.wishKept = false, false
        putValuesBack(same)
        local crouched = same and ue.bool(st.pawn, "bIsCrouched") == true
        st.leftover = crouched and mine and not st.byGame
        st.pendingStand, st.byGame = false, false
    end
    st.crouched, st.req, st.run, st.lastAsk, st.answer, st.brakeArmed, st.flushWatch = nil, nil, nil, nil, nil, nil, nil
    st.refusedGround, st.refusedAir, st.liftHeld, st.hookError = false, false, nil, nil
    st.baseWritten = false
end

--- Forgets everything without touching the game: for a new level, whose loading destroyed the
--- objects the mod had changed.
function hull.forget()
    overrides:forget()
    if st.cmcName then
        journal.forget("prop", st.cmcName, "bWantsToCrouch")
        journal.forget("field", st.cmcName, CAN_CROUCH)
    end
    newCharacter(nil, nil, nil)
    st.crouched, st.req, st.run, st.lastAsk, st.answer, st.brakeArmed, st.flushWatch = nil, nil, nil, nil, nil, nil, nil
    st.hookError, st.baseWritten = nil, false
end

--- Starts the counts of the lines about what the game did again (3 of each kind): for F7.
function hull.logAgain()
    st.noteLines = {}
end

--- What happened since the last call (taps, ducks, stand-ups, braking given back ...), for
--- the status line: the counts of hull.status, as differences.
function hull.takeStats()
    local result = {}
    for name, value in pairs(st.counts) do
        result[name] = value - (st.taken[name] or 0)
    end
    for name, value in pairs(st.counts) do
        st.taken[name] = value
    end
    return result
end

--- What the hull side is doing, for the report.
function hull.status()
    return {
        way = st.way,
        why = st.why,
        owned = st.owned,
        pendingStand = st.pendingStand,
        leftover = st.leftover,
        byGame = st.byGame,
        lastAsk = st.lastAsk,
        crouched = st.crouched,
        standHalf = st.standHalf,
        standHalfUnscaled = st.standHalfUnscaled,
        radius = st.radius,
        scale = st.scale,
        crouchedHalf = st.crouchedHalf,
        delta = st.delta,
        canCrouchSeen = st.canCrouchSeen,
        canCrouchWritten = st.canCrouchWritten,
        refusedGround = st.refusedGround,
        refusedAir = st.refusedAir,
        liftHeld = st.liftHeld ~= nil,
        liftOff = guard.isOff(LIFT_STEP),
        floorOff = guard.isOff(FLOOR_STEP),
        stepOff = guard.isOff(STEP),
        refusedInARow = { ground = st.refused.ground, air = st.refused.air },
        flushesInARow = st.flushes,
        gameCrouchedValue = overrides:saved(st.cmc, "CrouchedHalfHeight"),
        counts = st.counts,
    }
end

guard.whenOff(STEP, function()
    hull.release()
    setWay("none", "on: no hull change (ducking the character was turned off by its errors)")
end)

return hull
