-- Half-Life movement on the game's character.
--
-- Each frame, before the character's movement update, the mod takes the movement
-- input away from the game, works out the new velocity with physics.lua (at a
-- fixed rate of Half-Life updates per second, see physics.simulate) and hands it
-- to Unreal's character movement component. That component still handles
-- collisions, stairs, slopes, landing and gravity (with gravity set to Half-Life's).
--
-- Unreal brakes a character that gets no input. The mod turns braking friction off,
-- sets the plain braking values to almost zero, and adds back whatever braking is
-- left, so only the Half-Life friction applies.
--
-- The game has a speed limiter (a component that caps the speed at the movement
-- component's maximum). Its tick is paused, checked every frame, and the maximum
-- walking speed is set very high. If the speed still comes back cut while keeping
-- its direction, although the character moved the whole way, the game capped it:
-- the cut is logged and, with KeepSpeed, undone. (Walls and slopes turn the
-- velocity. A wall or a step that stops the character part of the way lowers it
-- in the same direction, but then the character moved less too: Unreal works the
-- velocity out from the distance moved. A moving platform's own motion doesn't
-- count, as far as Unreal reports the platform's velocity (a movement component's
-- or a physics body's); a platform moved some other way still counts. Walking off
-- a moving platform adds its velocity, as the mod's jump does. The distance isn't
-- checked when the movement mode changed during Unreal's update, at a landing or
-- when walking off a ledge: the speed limiter listens to mode changes, and a cap
-- there comes part of the way through the move.)
--
-- On a moving platform, Unreal carries the character along, and the velocity is
-- relative to the platform. Leaving it adds the platform's velocity (Unreal does,
-- and the mod's jump keeps it). Landing on one, Unreal leaves the velocity as it
-- was in the air, so the mod takes the platform's velocity out.
--
-- On slopes, Unreal keeps the horizontal speed, walking or landing. With SlopeLandings
-- and SlopeBoosts the mod goes by Half-Life's rules instead (see slopeStep): a landing
-- that runs into a slope turns part of the fall into speed along it (one that
-- Half-Life's ground check catches just above the slope keeps its speed: see
-- landingKind, which tells the two apart), and a player rising faster than 180 u/s is
-- in the air, so running or landing fast against an upward slope slides up it without
-- friction and flies off the top.
--
-- When the mod hands the movement back, every value goes back to the last one the
-- game set (see overrides.lua), including the walking speed. The mod doesn't ask
-- ALS to work out its walking speed again: that would lose a speed the game set
-- for the area. (ALS's request flag is also a uint8, which UE4SS sets to 0 when
-- given a Lua true.)
--
-- Ducking: Half-Life's duck runs update by update in physics.simulate (duck.lua), from
-- the duck, duck tap and jump buttons of the frame (input.buttons); its state lives in
-- st.duck, which outlives the frames the mod doesn't move the character. hull.lua makes
-- Unreal's capsule follow it (the crouch, read back at the next hook) and gives the
-- updates the room they have; the duck tap's lift is a third way of leaving the ground,
-- beside the jump and the flight off a slope. The order in a frame: the hull's answers
-- (hull.read), the keys, the landing and the speed checks, the slopes (which arm the run
-- into an upward slope, decided per update), the room, the updates, the lift (or the
-- frame run again without it), the slide a run-in started, leaving the ground, the
-- velocity, and the hull request last (after every SetMovementMode of the frame).

local physics = require("hl1movement.physics")
local duck = require("hl1movement.duck")
local hull = require("hl1movement.hull")
local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local input = require("hl1movement.input")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local Overrides = require("hl1movement.overrides")

local movement = {}

local WALKING, NAVWALKING, FALLING = 1, 2, 3
local REFRESH = 0.5 -- seconds between re-applying the values below
local SPEED_LIMIT = 100000 -- cm/s, high enough that the game never caps your speed
-- cm/s² of braking left in place instead of 0: ALS's animation code divides by the
-- braking deceleration, and the mod adds this tiny amount back every frame anyway.
local TINY_BRAKING = 1
local LIMITER_CLASS = "BP_VelocityControllerComponent_C"
-- A speed cut: the speed fell to between these shares of what the mod wrote, while
-- the direction stayed within 2 degrees. Below CUT_MIN it is the game stopping the
-- character, unless the speed limiter just ran or the speed is now its maximum.
local CUT_MIN, CUT_MAX, CUT_COS = 0.2, 0.97, math.cos(math.rad(2))
-- ...and the character moved at least this share of the way the mod's velocity
-- would take it, and not much more (more: the game moved it). A moving platform's
-- own motion is taken out first, as far as Unreal reports its velocity.
local MOVED_MIN, MOVED_MAX = 0.9, 2
local MIN_CHECKED_SPEED = 50 -- cm/s
-- The log takes so many lines of each kind, then no more until the reload key starts
-- the counts again (see movement.logAgain): a test presses it before each part it
-- wants in the log. One part of docs/TESTING.md fits in 30: 10 hops and 20 strafing
-- ones; a hill hopped down; a slide or two up a rough slope.
local MAX_CUT_LINES = 5 -- the game's speed cuts
local MAX_NOTE_LINES = 3 -- for each other kind of thing the game did
local MAX_HOP_LINES = 30
-- In the air the body turns towards where the character heads once it moves at
-- least this fast (cm/s, apart from a moving platform it left): ALS's own jump
-- (EventOnJumped) takes the velocity's direction above the same speed.
local HEADING_SPEED = 100
-- ALS turns the body in the air this share per second of the way that is left
-- (UpdateInAirRotation, RInterpTo at 5), so a heading that turns is led by its turn
-- rate times (1/5 - the frame's length), at most LEAD_LIMIT degrees either way:
-- then the body keeps up with it.
local ALS_AIR_TURN = 5
local LEAD_LIMIT = 45
-- Slopes (SlopeLandings, SlopeBoosts). Floors flatter than 1 degree count as flat (a
-- step's edge with a flat tread too: its surface normal is flat). A sloped floor's
-- normal is only used when the capsule's contact normal agrees with the surface's
-- within 8 degrees: where the capsule rests on an edge or a crease of sloped ground
-- (the lip of a ramp, a ridge) they differ, and that isn't a slope to slide on.
local FLAT_NZ = math.cos(math.rad(1))
local CONTACT_AGREES = math.cos(math.rad(8))
local MAX_UNREADABLE_FLOORS = 30 -- reads in a row of a floor whose normal can't be read
-- Slides up a slope and flights off one: a boost takes three lines, a slide up a rough
-- slope from 2 to over 20 (more the faster it starts).
local MAX_SLIDE_LINES = 30
-- Landings on a slope are logged only on one of LOGGED_SLOPE degrees or more, or if
-- the speed changed by LOGGED_CHANGE u/s or more: most ground is a little uneven. Those
-- that ran into the slope and those that kept their speed have a budget each, so the
-- log shows both kinds, and each as many as hop lines: whichever kind a logged hop's
-- landing is, the log has its slope and how it came down.
local MAX_LANDING_LINES = 30
local MAX_KEPT_LINES = 30
local LOGGED_SLOPE = 3
local LOGGED_CHANGE = 10
-- After a slide, rising faster than this share of the jump speed is the game's own jump.
local GAME_JUMP_SHARE = 0.5
-- Walking down a slope, the floor is read once the character went down, in the frame
-- before, by this share of the ground check's reach in one Half-Life update: from there
-- on an update may leave the floor (with some room for a speed that grew since).
local DESCENT_SHARE = 0.75
-- Unreal keeps a character it walks 1.9 to 2.4 cm above the floor. So a character still
-- in the air on the frame before a landing can't have been further below where it stands
-- now than that: if it was, it didn't come down on this floor's plane (see landingKind).
-- A CurrentFloor.FloorDist outside 0 to this isn't taken for that gap either (see floorGap).
local FLOOR_GAP = 3 -- cm
-- For the report, landings are counted by how far their floor leaned, in degrees: under
-- the first limit (flat for the mod, see FLAT_NZ), up to each next one, and beyond the
-- last. A landing's clip changes the speed by about the speed times the lean's sine
-- squared, so each band stands for about four times the one before.
local FLOOR_BANDS = { 1, 2, 4, 8, 16 }
-- The duck tap lines and the "Duck:" lines, until the reload key starts their counts again.
local MAX_TAP_LINES = 30
local MAX_DUCK_LINES = 30
-- The lines about a sudden loss of speed (see speedLoss) and about the game playing an animation
-- that moves the character itself (root motion, see noteRootMotion), until the reload key.
local MAX_LOSS_LINES = 10
local MAX_ROOT_LINES = 10
-- A sudden loss: the speed Unreal moved with under this share of what the mod wrote, and
-- lower by at least LOSS_MIN u/s.
local LOSS_SHARE = 0.75
local LOSS_MIN = 100

-- What was read of the floor in this frame, so that nothing is read twice: the
-- movement component's CurrentFloor, if it is a floor the character walks on, and how
-- steep the mod takes it to be (its normal's Z, see floorNormal); and how far above it
-- the character stands (see floorGap; false: not asked yet). walkFloor: a sloped floor
-- that falls away under the character as it walks on it in this frame, for Half-Life's
-- updates on the ground to leave (see slopeStep, physics.simulate). leaveFall: where the
-- character leaves such a floor in this frame, the second half of the gravity of the
-- Half-Life update that left it (cm/s), for the leap's landing (see slopeLanding).
-- runInFloor: a sloped floor the character walks on in this frame, for Half-Life's
-- updates on the ground to run into if it rises under them (physics.simulate's dk.runIn).
local seenFloor, seenNz, seenGap, walkFloor, leaveFall, runInFloor = nil, nil, false, nil, nil, nil

local overrides = Overrides.new()
local st = {
    active = false,
    cmc = nil,
    cmcName = nil,
    worldGravity = nil,
    nextRefresh = 0,
    curve = nil, -- the movement curve the mod took out, to put back
    curveName = nil,
    curveBroken = false,
    limiter = nil, -- { obj, fullName, wasEnabled } once found; false: none found
    sim = {}, -- physics.simulate's state
    -- Half-Life's duck state (duck.new): kept apart from st.sim, which is emptied after any
    -- frame the mod didn't move the character, while a duck (and its timer, a waiting notch,
    -- the duck tap's memory and the jump's mark) outlives a pause or root motion. A new one
    -- at every take-over, from the capsule as it is.
    duck = nil,
    dkOut = {}, -- physics.simulate's dk.out, used again every frame
    duckKey = false, -- a duck key read down at the last hook that read the keys (for root motion)
    eye = nil, -- what the camera gets (see movement.eyeInfo), and its frame
    eyeFrame = nil,
    tap = nil, -- the duck tap in progress, for the tap lines
    taps = 0, -- duck taps landed in this session: the tap lines' numbers
    tapLines = 0, -- tap lines written since the count last started (see movement.logAgain)
    duckLines = 0, -- "Duck:" lines written since then
    lossLines = 0, -- lines about a sudden loss of speed written since then
    rootLines = 0, -- lines about the game's root motion written since then
    duckClock = 0, -- s: the Half-Life updates the duck ran, added up (for the Duck lines' times)
    pressedAt = nil, -- duckClock at the press of the transition in progress
    duckedAt = nil, -- duckClock when the character last became fully ducked
    -- Where the flight in progress took off with a hull of its own: how much higher than
    -- usual Half-Life's player is above the floor's plane against the character (cm): a duck
    -- tap's lift is placed lower than Half-Life's 18 units (takeoffLift), and a ducked take-off
    -- rests on Valve's ducked floor, which lies duck.restGap below the standing one where
    -- Unreal's crouched capsule rests 18 units lower (takeoffDuck). nil: none.
    takeoffLift = nil,
    takeoffDuck = nil,
    hullAir = nil, -- how long the character had been in the air at the hook of the last hull change there
    lastStepFrame = nil,
    written = nil, -- the horizontal velocity the mod left for the game last frame, and the platform's
    lastMode = nil,
    lastSpeed = 0,
    emptyInputFrames = 0,
    hop = nil, -- the jump in progress, for the hop lines
    hops = 0, -- hops landed in this session: the hop lines' numbers
    hopLines = 0, -- hop lines written since the count last started (see movement.logAgain)
    maxSpeed = nil, -- what GetMaxSpeed() said after the mod set MaxWalkSpeed
    gameWalkSpeed = nil, -- the MaxWalkSpeed the game wrote since the last frame, if it did
    stayBasedInAir = false, -- the movement component's bStayBasedInAir
    airBaseX = 0, -- the moving platform's velocity that leaving it added, while in the air
    airBaseY = 0,
    airNext = nil, -- how long the character will have been in the air at the next frame's hook (s)
    -- How far above the floor the character stood where the flight in progress took off
    -- (cm, see floorGap); nil if the mod didn't start it or couldn't read it.
    takeoffGap = nil,
    -- How far above its floor's plane Half-Life's player rested where that flight took
    -- off, and rests since the landing just decided or during the slide it began (cm,
    -- straight up, see landingKind); nil: its usual 1/32 unit off the plane.
    takeoffRest = nil,
    landRest = nil,
    headingFrame = nil, -- the frame of headingYaw (see movement.heading)
    headingYaw = false, -- where the character heads in the air, in degrees (false: too slow)
    headingTarget = false, -- headingYaw, led by its turn rate: what the body turns towards (see trackHeading)
    headingRate = nil, -- that turn rate in degrees per second
    headingRef = false, -- the heading after the last Half-Life update, and the time since
    headingTime = 0,
    facedFrame = nil, -- the last frame movement.faceHeading turned the body to where it heads
    inAirRotation = nil, -- whether the character has ALS's InAirRotation (nil: not looked yet)
    -- { vz = cm/s }: sliding up a slope, in the air for Half-Life while Unreal walks (away:
    -- it began at a landing that didn't go into the floor, see slopeLanding; nx, ny, nz:
    -- the floor's normal in this frame, if it has one; edge: for how many frames in a row
    -- the floor wasn't used because the capsule was on an edge, see edgeNote; jump, ended,
    -- endX, endY, endZ, h, rise, push, time, clipped, dx, dy: see physics.simulate, which
    -- runs the slide update by update; floorZ: where the floor is under Half-Life's path,
    -- and ox, oy: how far the path is ahead of the character, see slopeStep and
    -- movement.step)
    slide = nil,
    flight = nil, -- { takeoff, time }: in the air after flying off a slope (not a hop)
    groundSteps = 0, -- Half-Life updates run on the ground since the character last left it (see slopeStep)
    slopeBroken = false, -- the floor's normal can't be read: slopes are left to Unreal
    -- Such reads in a row. Only a floor that reads starts the count again, not a take-over
    -- (the reload key, a battle, the game taking the input away): with fewer than
    -- MAX_UNREADABLE_FLOORS reads between two of those, the log would never say so.
    unreadableFloors = 0,
    slideLines = 0,
    landingLines = 0,
    keptLines = 0,
    noteLines = {}, -- by kind: lines about what the game did, since the count last started (see noted)
    slopeGained = 0, -- what landings on slopes added to the horizontal speed in all (cm/s), for the report,
    slopeLost = 0, -- and what they took: kept apart, since hopping down a hill and up it again cancels out
    -- The floors at the landings so far, for the report (how rough the game's ground
    -- is): how many leaned by each of FLOOR_BANDS, and how many the mod couldn't use.
    floors = { 0, 0, 0, 0, 0, 0, unusable = 0, bands = FLOOR_BANDS },
    -- slopeLandings: landings on a slope with SlopeLandings, of which slopeHits ran into it
    -- (Half-Life clips those) and slopeUnknown couldn't be told; the rest were caught by
    -- Half-Life's ground check and kept their speed. groundedJumps: jumps of the mod's that
    -- Unreal landed again within the frame they started in (not hops, see movement.step).
    -- taps: duck taps (lifts the game had room for), tapLandings their landings; groundDucks,
    -- airDucks, groundStands, airStands: Half-Life's ducks and stand-ups; runInPresses: duck
    -- tap presses that ran into an upward slope instead (Half-Life's slope boost, no tap).
    -- speedLosses: frames Unreal moved the character much slower than the mod wrote (see
    -- speedLoss); rootMotions: animations the game moved the character with while the mod had it.
    counts = { cuts = 0, restores = 0, rewrites = 0, wakes = 0, leaks = 0, jumpChanges = 0, slopeLandings = 0,
        slopeHits = 0, slopeUnknown = 0, slides = 0, launches = 0, stoppedJumps = 0, groundedJumps = 0, taps = 0,
        tapLandings = 0, groundDucks = 0, airDucks = 0, groundStands = 0, airStands = 0, runInPresses = 0,
        speedLosses = 0, rootMotions = 0 },
}

-- What happened since the last status line (see movement.takeStats).
local function newStats()
    return { frames = 0, keys = 0, stick = 0, game = 0, none = 0, hops = 0, landings = 0, top = 0, topGround = 0,
        airHops = 0, airGain = 0, airTurn = 0, landingLoss = 0, steps = 0, cuts = 0, restores = 0, rewrites = 0,
        wakes = 0, leaks = 0, slopeLandings = 0, slopeHits = 0, slopeGain = 0, slides = 0, launches = 0,
        groundedJumps = 0, taps = 0, tapLandings = 0, groundDucks = 0, airDucks = 0, groundStands = 0,
        airStands = 0, runInPresses = 0, speedLosses = 0, rootMotions = 0 }
end
local stats = newStats()

local function count(name)
    st.counts[name] = st.counts[name] + 1
    if stats[name] then
        stats[name] = stats[name] + 1
    end
    return st.counts[name]
end

-- Counts one more thing the game did (a speed cut, its limiter started again ...), and
-- returns how many of that kind there have been since the reload key last started the
-- log's counts (see movement.logAgain): only the first few of each get a line.
local function noted(name)
    count(name)
    st.noteLines[name] = (st.noteLines[name] or 0) + 1
    return st.noteLines[name]
end

-- A landing on a slope, counted for the status line (since the last one) and for the
-- report (since the mod loaded). kind: "hit" (it ran into the slope, which changed the
-- horizontal speed by change cm/s), "caught" (Half-Life's ground check set it down
-- first: the speed stays) or "unknown" (the mod couldn't tell: the speed stays).
local function countSlopeLanding(kind, change)
    count("slopeLandings")
    if kind == "unknown" then
        count("slopeUnknown")
    end
    if kind ~= "hit" then
        return
    end
    count("slopeHits")
    stats.slopeGain = stats.slopeGain + change
    if change > 0 then
        st.slopeGained = st.slopeGained + change
    else
        st.slopeLost = st.slopeLost - change
    end
end

function movement.isActive()
    return st.active
end

--- For the speedometer: the horizontal speed (cm/s) Unreal moved the character with,
--- as the mod read it back on this frame (see st.readSpeed in movement.step), or nil
--- if the mod didn't move the character on this frame.
function movement.speed(frame)
    if st.active and st.lastStepFrame == frame and st.written then
        return st.readSpeed
    end
    return nil
end

local function horizontal(x, y)
    return math.sqrt(x * x + y * y)
end

-- The gravity of the world, before the character's GravityScale.
local function measureGravity(cmc)
    local scale = ue.number(cmc, "GravityScale")
    local ok, gravityZ = ue.call(cmc, "GetGravityZ")
    if scale and scale ~= 0 and ok and type(gravityZ) == "number" and gravityZ < 0 then
        return gravityZ / scale
    end
    return nil
end

-- ALS, the locomotion system the game's character is built on, takes ground
-- acceleration, braking and friction from a curve whenever one is set. Without
-- the curve, the plain values the mod sets to almost zero apply. ALS sets the
-- curve again when the character's stance or gait changes, so this runs every frame.
local function takeCurve(cmc)
    if st.curveBroken then
        return
    end
    local ok, err = pcall(function()
        local movementSettings = cmc.CurrentMovementSettings
        if ue.typeOf(movementSettings) ~= "UScriptStruct" then
            return
        end
        local curve = movementSettings.MovementCurve
        if ue.valid(curve) then
            local curveName = ue.fullName(curve)
            log.first("curve", "Taking out the character's movement curve (%s)", tostring(curveName))
            st.curve = curve
            if curveName ~= st.curveName then
                st.curveName = curveName
                journal.note("curve", st.cmcName, "", curveName)
            end
            movementSettings.MovementCurve = nil
        end
    end)
    if not ok then
        st.curveBroken = true
        log.once("curve", "Could not take out the character's movement curve (%s); "
            .. "its braking is cancelled out instead.", tostring(err))
    end
end

local function putCurveBack()
    local curve, curveName = st.curve, st.curveName
    st.curve = nil
    st.curveName = nil
    journal.forget("curve", st.cmcName, "")
    if not curve or not ue.valid(st.cmc) or ue.fullName(st.cmc) ~= st.cmcName then
        return
    end
    -- Only the same curve goes back: another object could have its address now.
    if not (ue.valid(curve) and ue.fullName(curve) == curveName) then
        return
    end
    pcall(function()
        local movementSettings = st.cmc.CurrentMovementSettings
        if not ue.valid(movementSettings.MovementCurve) then
            movementSettings.MovementCurve = curve
        end
    end)
end

-- The character's component that caps its speed at the movement component's
-- maximum speed. Its tick is paused while the mod runs, so bunny hopping can
-- build speed.
local function findLimiter(pawn)
    local direct = ue.object(pawn, "BP_VelocityControllerComponent")
    if direct then
        return direct
    end
    local component = ue.find("/Script/Engine.ActorComponent")
    if not component then
        return nil
    end
    local ok, components = ue.call(pawn, "K2_GetComponentsByClass", component)
    if not ok then
        return nil
    end
    for _, candidate in ipairs(ue.list(components)) do
        if ue.className(candidate) == LIMITER_CLASS then
            return candidate
        end
    end
    return nil
end

-- Called every frame: the game may start the limiter again at any time, for
-- example when the movement mode changes on a jump or a landing.
local function pauseLimiter(pawn, cmc, refresh)
    local limiter = st.limiter
    if limiter == false then
        return
    end
    if limiter == nil then
        local component = findLimiter(pawn)
        if not component then
            st.limiter = false
            log.debug("No %s found on the character", LIMITER_CLASS)
            return
        end
        local ok, enabled = ue.call(component, "IsComponentTickEnabled")
        log.first("limiter", "Pausing the game's speed limiter %s (it was %s)", LIMITER_CLASS,
            ok and (enabled and "ticking" or "not ticking") or "in an unknown state")
        limiter = { obj = component, fullName = ue.fullName(component), wasEnabled = ok and enabled == true }
        st.limiter = limiter
        journal.note("tick", limiter.fullName, "", limiter.wasEnabled)
        component:SetComponentTickEnabled(false)
        return
    end
    if not ue.valid(limiter.obj) or (refresh and ue.fullName(limiter.obj) ~= limiter.fullName) then
        return
    end
    local ok, enabled = ue.call(limiter.obj, "IsComponentTickEnabled")
    if ok and enabled == true then
        -- The game started it again, so it is on when the mod hands back.
        st.limiterWoke = true
        local wakes = noted("wakes")
        if wakes <= MAX_NOTE_LINES then
            log.info("The game turned its speed limiter on again (movement mode %s); pausing it again%s",
                tostring(ue.number(cmc, "MovementMode")), wakes == MAX_NOTE_LINES and " (not logged again)" or "")
        end
        limiter.wasEnabled = true
        journal.note("tick", limiter.fullName, "", true)
        limiter.obj:SetComponentTickEnabled(false)
    end
end

local function resumeLimiter()
    local limiter = st.limiter
    st.limiter = nil
    if not limiter then
        return
    end
    journal.forget("tick", limiter.fullName, "")
    if limiter.wasEnabled and ue.valid(limiter.obj) and ue.fullName(limiter.obj) == limiter.fullName then
        pcall(function()
            limiter.obj:SetComponentTickEnabled(true)
        end)
    end
end

local function applyValues(pawn, cmc, P)
    -- Braking friction comes from BrakingFriction (zero) instead of the ground
    -- friction, whatever braking factor the game sets on landing.
    overrides:set(cmc, "bUseSeparateBrakingFriction", true, true)
    overrides:set(cmc, "BrakingFriction", 0, true)
    overrides:set(cmc, "BrakingDecelerationWalking", TINY_BRAKING, true)
    overrides:set(cmc, "BrakingDecelerationFalling", TINY_BRAKING, true)
    -- The game's own jump (on the first press) gets the same height as the mod's.
    overrides:set(cmc, "JumpZVelocity", P.jumpSpeed, true)
    overrides:set(pawn, "JumpMaxHoldTime", 0, true)
    if st.worldGravity then
        overrides:set(cmc, "GravityScale", P.gravity / -st.worldGravity, true)
    end
end

-- Whether the game's speed cap follows MaxWalkSpeed: logged once if it doesn't.
local function checkMaxSpeed(cmc)
    local ok, max = ue.call(cmc, "GetMaxSpeed")
    if not ok or type(max) ~= "number" then
        return
    end
    st.maxSpeed = max
    if max < SPEED_LIMIT * 0.99 then
        log.once("max-speed", "The movement component's GetMaxSpeed() is %.0f cm/s although the mod set "
            .. "MaxWalkSpeed to %d, so the game's speed cap doesn't follow MaxWalkSpeed (movement mode %s). "
            .. "Please report UE4SS.log.", max, SPEED_LIMIT, tostring(ue.number(cmc, "MovementMode")))
    end
end

-- One more line about the duck ("Duck: ..."), within its budget.
local function duckLine(fmt, ...)
    st.duckLines = st.duckLines + 1
    if st.duckLines <= MAX_DUCK_LINES then
        log.info("Duck: %s%s", string.format(fmt, ...),
            st.duckLines == MAX_DUCK_LINES and " (further ducks and stand-ups aren't logged)" or "")
    end
end

--- Takes over the character's movement, or keeps it taken over. Called every frame
--- while the mod's movement should run. Returns true if it took over in this call
--- (its refreshes start then, see movement.stagger), and whether this is a frame of
--- the half-second refresh.
function movement.apply(pawn, cmc, cfg, P, now)
    if st.active and not ue.same(st.cmc, cmc) then
        movement.release()
    end
    local first = false
    if not st.active then
        first = true
        st.active = true
        st.cmc = cmc
        st.cmcName = ue.fullName(cmc)
        st.worldGravity = measureGravity(cmc)
        st.stayBasedInAir = ue.bool(cmc, "bStayBasedInAir") == true
        st.nextRefresh = 0
        st.lastMode = nil
        st.emptyInputFrames = 0
        st.sim = {}
        st.lastStepFrame = nil
        st.written = nil
        st.hop, st.tap = nil, nil
        st.airBaseX, st.airBaseY = 0, 0
        st.airNext, st.takeoffGap, st.takeoffRest, st.landRest = nil, nil, nil, nil
        st.takeoffLift, st.takeoffDuck, st.hullAir = nil, nil, nil
        st.headingFrame, st.facedFrame = nil, nil
        st.inAirRotation = nil
        st.slide, st.flight = nil, nil
        st.eye, st.eyeFrame, st.duckKey = nil, nil, false
        st.pressedAt, st.duckedAt, st.standLine, st.groundRun, st.airRefusal = nil, nil, nil, nil, nil
        st.rootMotion = nil
        st.breakfall = nil
        if not st.worldGravity then
            log.once("gravity", "Could not read the game's gravity, so the game's own gravity stays.")
        end
        log.first("movement", "Taking over the movement of %s (mode %s, world gravity %s cm/s2)",
            tostring(ue.className(pawn)), tostring(ue.number(cmc, "MovementMode")), tostring(st.worldGravity))
        log.debug("Movement taken over")
        -- Half-Life's duck starts as the capsule is: fully ducked if it reads crouched (the
        -- game's crouch, or one left from before), with the hull's way and values.
        hull.takeOver(pawn, cmc, cfg, P)
        st.duck = duck.new(cfg.Ducking ~= false and ue.bool(pawn, "bIsCrouched") == true)
    end
    local refresh = now >= st.nextRefresh
    if refresh then
        -- The second refresh comes a quarter period after the first instead of a
        -- whole one, so that refreshes fall between the camera's (see movement.stagger),
        -- and each is counted from when the last was due, not from its frame, which
        -- would drift with the frame times.
        if first then
            st.nextRefresh = now + REFRESH / 4
        else
            repeat
                st.nextRefresh = st.nextRefresh + REFRESH
            until st.nextRefresh > now
        end
    end
    -- ALS sets the walking speed itself whenever the gait or the stance changes (the
    -- crouched one too, at every crouch and stand-up), and the game sets it for some
    -- areas, so these are set every frame. The high value stops the game from capping
    -- your speed.
    st.gameWalkSpeed, st.gameCrouchedSpeed = nil, nil
    for _, name in ipairs({ "MaxWalkSpeed", "MaxWalkSpeedCrouched" }) do
        if overrides:set(cmc, name, SPEED_LIMIT, refresh) then
            -- What the game wrote since the last frame: its speed cap may have cut the
            -- speed to it meanwhile (see atMaxSpeed).
            if name == "MaxWalkSpeed" then
                st.gameWalkSpeed = overrides:saved(cmc, name)
            else
                st.gameCrouchedSpeed = overrides:saved(cmc, name)
            end
            local rewrites = noted("rewrites")
            if rewrites <= MAX_NOTE_LINES then
                log.info("The game set %s to %s; the mod sets it back to %d%s", name,
                    tostring(overrides:saved(cmc, name)), SPEED_LIMIT,
                    rewrites == MAX_NOTE_LINES and " (not logged again)" or "")
            end
        end
    end
    takeCurve(cmc)
    if not cfg.LandingRoll then
        -- ALS's breakfall: on a landing with movement input it plays a roll, whose root motion
        -- takes the movement from the mod (and most of the speed with it). Half-Life has no roll.
        -- Every frame, one read (written when the game set it again): the game's value comes back
        -- at the release. Only on a character that has it (ALS's; a flag it doesn't have reads as
        -- no boolean).
        if st.breakfall == nil then
            st.breakfall = type(ue.get(pawn, "bBreakfallOnLand")) == "boolean"
        end
        if st.breakfall then
            overrides:set(pawn, "bBreakfallOnLand", false, refresh)
        end
    end
    if refresh then
        applyValues(pawn, cmc, P)
        if first then
            checkMaxSpeed(cmc)
        end
        hull.refresh(pawn, cmc)
    end
    if cfg.DisableSpeedLimiter then
        guard.run("pausing the speed limiter", pauseLimiter, pawn, cmc, refresh)
    end
    return first, refresh
end

--- Puts the refreshes here a quarter period after first person's, between them:
--- called when first person starts, or when the movement starts while first person
--- is on. cameraNext: when first person's next refresh is due.
function movement.stagger(now, cameraNext)
    if st.active and cameraNext then
        local at = cameraNext - REFRESH + REFRESH / 4
        while at <= now do
            at = at + REFRESH
        end
        st.nextRefresh = at
    end
end

-- The game's movement input still reaching Unreal's movement component, after the
-- mod took it: then Unreal steers the velocity too. Shows as acceleration.
local function checkInputLeak(cmc)
    local ok, acceleration = ue.call(cmc, "GetCurrentAcceleration")
    if not ok or type(acceleration) ~= "table" then
        return
    end
    local ax, ay = ue.vector(acceleration)
    if ax * ax + ay * ay > 1 then
        count("leaks")
        log.once("input-leak", "The game's movement input still reaches Unreal's movement after the mod took it "
            .. "(acceleration X=%.0f Y=%.0f cm/s2), so the game steers the character too. Please report UE4SS.log.",
            ax, ay)
    end
end

-- Whether the velocity read back was capped at the movement component's maximum,
-- or at a walking speed the game wrote since the last frame, crouched or not (the mod
-- has already set MaxWalkSpeed back this frame, so GetMaxSpeed() may no longer say it).
local function atMaxSpeed(cmc, vx, vy, vz)
    local speed, flat = math.sqrt(vx * vx + vy * vy + vz * vz), horizontal(vx, vy)
    local function at(cap)
        return type(cap) == "number" and cap > 0
            and (math.abs(speed - cap) <= cap * 0.01 or math.abs(flat - cap) <= cap * 0.01)
    end
    if at(st.gameWalkSpeed) or at(st.gameCrouchedSpeed) then
        return true
    end
    local ok, max = ue.call(cmc, "GetMaxSpeed")
    return ok and at(max)
end

-- The velocity of the moving platform the character is on (zero on still ground,
-- and in the air unless the movement component's bStayBasedInAir is set), read
-- while it is still standing on it.
local function platformVelocity(cmc)
    local ok, base = ue.call(cmc, "GetImpartedMovementBaseVelocity")
    if ok and type(base) == "table" then
        return ue.vector(base)
    end
    return nil
end

-- A cut of the speed the mod wrote last frame, with the direction kept, although
-- the character moved the whole way (at is where it is now), is the game capping
-- the speed. Logged, and undone with KeepSpeed. Returns the velocity to start from, and
-- true as the third value if it was a cut.
local function checkCut(cmc, cfg, P, vx, vy, vz, mode, landed, at)
    local w = st.written
    if not w then
        return vx, vy
    end
    -- Walking off a ledge (leaving the ground other than by the mod's jump), Unreal
    -- adds the velocity of the platform the character stood on, as the mod's jump does.
    -- Unless a long frame, which Unreal walks in several moves, took the character
    -- onto still ground first: then what the mod wrote comes back, no cut either.
    local ex, ey = w.x, w.y
    if mode == FALLING and w.mode ~= FALLING and not st.stayBasedInAir then
        local plain, speed = horizontal(ex, ey), horizontal(vx, vy)
        if plain >= MIN_CHECKED_SPEED and speed > plain * CUT_MAX
            and vx * ex + vy * ey >= speed * plain * CUT_COS then
            return vx, vy
        end
        ex, ey = ex + w.baseX, ey + w.baseY
    end
    local written = horizontal(ex, ey)
    local speed = horizontal(vx, vy)
    if written < MIN_CHECKED_SPEED or speed < 1e-3 then
        return vx, vy
    end
    local ratio = speed / written
    if ratio > CUT_MAX or (vx * ex + vy * ey) / (speed * written) < CUT_COS then
        return vx, vy
    end
    if w.mode == mode and w.at and at and w.dt and w.dt > 0 then
        -- How fast the character really moved. A wall or a step that stopped it part
        -- of the way lowers the velocity to match the distance moved; a cap lowers
        -- the velocity after the move. Unreal moves a character on a moving platform
        -- with it, apart from its velocity, so the motion of the platform it stood on
        -- when the mod wrote is taken out, as far as Unreal reports its velocity.
        -- (When the mode changed during the move, a cap by a listener of that change
        -- came part of the way through it, so the distance tells nothing.)
        local mx, my = (at.X - w.at.X) / w.dt - w.baseX, (at.Y - w.at.Y) / w.dt - w.baseY
        local moved = horizontal(mx, my)
        if moved < written * MOVED_MIN or moved > written * MOVED_MAX or speed > moved * CUT_MAX then
            return vx, vy
        end
    end
    if ratio < CUT_MIN and not (st.limiterWoke or atMaxSpeed(cmc, vx, vy, vz)) then
        return vx, vy
    end
    local cuts = noted("cuts")
    if cuts <= MAX_CUT_LINES then
        local okMax, max = ue.call(cmc, "GetMaxSpeed")
        local limiter
        if not cfg.DisableSpeedLimiter then
            limiter = "not paused (DisableSpeedLimiter = false)"
        elseif st.limiterWoke then
            limiter = "started again by the game"
        elseif st.limiter then
            limiter = "paused"
        else
            limiter = "not found"
        end
        log.info("The game cut the speed from %.0f to %.0f u/s (%s, movement mode %s then %s%s; GetMaxSpeed %s, "
            .. "MaxWalkSpeed %s, speed limiter %s)%s%s", written / P.unitScale, speed / P.unitScale,
            landed and "on landing" or (mode == FALLING and "in the air" or "on the ground"),
            tostring(w.mode), tostring(mode),
            w.jumped and ", after a jump" or (w.launched and ", after flying off a slope" or ""),
            okMax and string.format("%.0f", max or -1) or "?", tostring(ue.number(cmc, "MaxWalkSpeed"))
                .. (st.gameWalkSpeed and string.format(" (the game had set %s)", tostring(st.gameWalkSpeed)) or ""),
            limiter, cfg.KeepSpeed and "; the speed is kept" or "; KeepSpeed is off, so the cut stays",
            cuts == MAX_CUT_LINES and " (not logged again)" or "")
    end
    if not cfg.KeepSpeed then
        return vx, vy, true
    end
    count("restores")
    local scale = written / speed
    return vx * scale, vy * scale, true
end

-- The floor Unreal's walking found under the character (the movement component's
-- CurrentFloor, updated while it walks): the unit normal of its surface, or (0, 0, 1)
-- for a flat one. nil when there is no floor the mod can use: none, one found by a
-- line trace, or a sloped one the capsule only touches with an edge or a crease (its
-- contact normal is more than 8 degrees off the surface's). Returns false as the 4th
-- value if the floor can't be read (every character movement component has one), and
-- true as the 5th if the floor isn't used because of its contact normal: the capsule is
-- on an edge. Field by field: in UE4SS, reading a field a struct doesn't have raises an
-- error.
local function floorNormal(cmc)
    local floor = ue.get(cmc, "CurrentFloor")
    local walkable
    if ue.typeOf(floor) == "UScriptStruct" then
        walkable = ue.bool(floor, "bWalkableFloor")
    end
    if walkable == nil then
        return nil, nil, nil, false
    end
    if not walkable or ue.bool(floor, "bLineTrace") == true then
        return nil
    end
    seenFloor = floor
    local hit = ue.get(floor, "HitResult")
    local surface = ue.get(hit, "ImpactNormal")
    local nz = ue.number(surface, "Z")
    if not nz then
        return nil, nil, nil, false
    end
    if nz >= FLAT_NZ then
        seenNz = 1
        return 0, 0, 1
    end
    local nx, ny = ue.number(surface, "X"), ue.number(surface, "Y")
    local contact = ue.get(hit, "Normal")
    local cx, cy, cz = ue.number(contact, "X"), ue.number(contact, "Y"), ue.number(contact, "Z")
    if not (nx and ny and cx and cy and cz) then
        return nil, nil, nil, false
    end
    local length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length < 0.5 then
        return nil
    end
    nx, ny, nz = nx / length, ny / length, nz / length
    if nx * cx + ny * cy + nz * cz < CONTACT_AGREES * math.sqrt(cx * cx + cy * cy + cz * cz) then
        return nil, nil, nil, nil, true
    end
    seenNz = nz
    return nx, ny, nz
end

-- ", after 2 frames on its edge" for the slide lines: how many frames in a row, just
-- before, the floor wasn't used because the capsule was on an edge (see floorNormal).
-- Unreal's capsule may round the edge at the end of a slope before it leaves it; the
-- slide then has gravity and no clip, and the character doesn't rise.
local function edgeNote(frames)
    if not frames or frames < 1 then
        return ""
    end
    return string.format(", after %d frame%s on its edge", frames, frames == 1 and "" or "s")
end

-- How far above the floor Unreal holds the character while it walks, measured straight
-- down (CurrentFloor.FloorDist: 1.9 to 2.4 cm, and their middle right after a landing),
-- or nil if it stands on no such floor or the number can't be read. Half-Life's player
-- stands on its floor, so its hop is the character's less this gap where it took off:
-- the mod reads it where its jump or launch starts and at a landing on a slope (see
-- slopeLanding), once a frame at most. At a landing the floor has been read already
-- (one more number of it); at a take-off from a floor not read in that frame it costs
-- one read of CurrentFloor and three of its fields.
local function floorGap(cmc)
    if seenGap ~= false then
        return seenGap
    end
    seenGap = nil
    local floor = seenFloor
    if not floor then
        floor = ue.get(cmc, "CurrentFloor")
        if ue.typeOf(floor) ~= "UScriptStruct" or ue.bool(floor, "bWalkableFloor") ~= true
            or ue.bool(floor, "bLineTrace") == true then
            return nil
        end
    end
    local dist = ue.number(floor, "FloorDist")
    if dist and dist >= 0 and dist <= FLOOR_GAP then
        seenGap = dist
    end
    return seenGap
end

-- The slope lines, with a budget each: slides up a slope and flights off one, and
-- landings on one.
local function slideLine(fmt, ...)
    st.slideLines = st.slideLines + 1
    if st.slideLines <= MAX_SLIDE_LINES then
        log.info("Slope: %s%s", string.format(fmt, ...),
            st.slideLines == MAX_SLIDE_LINES and " (further slides and flights aren't logged)" or "")
    end
end

-- hit: the landing ran into the slope; otherwise it kept its speed.
local function landingLine(hit, fmt, ...)
    local lines, most, rest
    if hit then
        st.landingLines = st.landingLines + 1
        lines, most, rest = st.landingLines, MAX_LANDING_LINES, "that run into a slope"
    else
        st.keptLines = st.keptLines + 1
        lines, most, rest = st.keptLines, MAX_KEPT_LINES, "on slopes that keep their speed"
    end
    if lines <= most then
        log.info("Slope: %s%s", string.format(fmt, ...),
            lines == most and string.format(" (further landings %s aren't logged)", rest) or "")
    end
end

local function degrees(nz)
    return math.deg(math.acos(math.max(-1, math.min(1, nz))))
end

-- Counts a landing's floor for the report (see st.floors): by its lean if the mod can
-- use it (nx, nz as floorNormal gave them), or as one it can't use (found by a line
-- trace, touched with an edge, or not walkable). A floor that can't be read at all has
-- its own warning and isn't counted.
local function noteFloor(nx, nz, readable)
    local floors = st.floors
    if not nx then
        if readable ~= false then
            floors.unusable = floors.unusable + 1
        end
        return
    end
    local lean, band = degrees(nz), #FLOOR_BANDS + 1
    for i, limit in ipairs(FLOOR_BANDS) do
        if lean < limit then
            band = i
            break
        end
    end
    floors[band] = floors[band] + 1
end

-- "falling 158 u/s" or "rising 40 u/s", for a vertical speed in cm/s.
local function vertical(vz, P)
    return string.format(vz < 0 and "falling %.0f u/s" or "rising %.0f u/s", math.abs(vz) / P.unitScale)
end

-- How Half-Life would have landed where Unreal just did. Half-Life looks for the ground
-- once per update: a player not rising faster than 180 u/s, with a walkable floor within
-- 2 units below, is put on it with its velocity as it is, and a held jump starts at once.
-- Only if no update ends that close to the floor does the next one's move run into it,
-- and only then is the velocity clipped against it. Which of the two happens depends on
-- where the updates fall along the path. In Half-Life a hop starts on an update, from
-- the floor, so the mod counts the updates from the take-off (w.air: how long the
-- character had been in the air at the last frame's hook), 1/PhysicsRate s apart,
-- whatever the game's frame rate. With one update per frame (PhysicsRate 0) the hooks
-- are the updates.
--
-- Where the character was at the last update before it came down follows from what the
-- mod has anyway: where it was at the last hook (w.at), the velocity written there, the
-- frame's length (w.dt), where it stands now (at) and the floor's normal. Unreal's fall
-- is a parabola (it moves a falling character with the average of the old and the new
-- velocity), and after touching down it walks on along the floor for the rest of the
-- frame, so the plane it stands on goes through `at`. Measured straight down, as the
-- ground check measures, the height above that plane t seconds after the last hook was
-- h0 + a t - g t^2 / 2. Half-Life's player is `lift` higher than that above its floor's
-- plane (see slopeLanding): Unreal walks the character 1.9 to 2.4 cm above the floor, so
-- if it took off from the same height, the plane through `at` is where Half-Life's
-- player would stand, 1/32 unit off its floor's plane; and a walking height that differs
-- between the take-off and here is taken out. Unreal lands the character when it touches
-- the real floor, a moment after Half-Life's player came down to its floor, so that
-- time, tc, can lie before the last hook; the path is followed back as far as needed.
-- (fx, fy, fz): the velocity of the floor, if it is a moving platform; (rx, ry, rz): the
-- velocity written at the last hook, relative to the floor. ahead (cm, 0 or more): the
-- part of `lift` by which Half-Life's player is still above its floor as Unreal lands the
-- character, as after a duck tap's lift, placed lower than Half-Life's (see hull.lift),
-- which times Unreal's landing to Half-Life's ground check: that player comes down after
-- the frame's end, on the path the frame had, and the updates after the hook count too.
-- Without it, the path must reach the plane within the frame.
--
-- Returns "caught" (the ground check found the floor: nothing is clipped) or "hit" (an
-- update ran into it); the vertical speed of the update that hit (cm/s: Half-Life moves
-- with the speed half an update on); the height above the floor's plane where the last
-- update before the landing ended (cm; for a caught one, the update that caught it),
-- and the vertical speed there; and how far above that plane Half-Life's player rests
-- afterwards (cm, straight up: 1/32 unit off it, or as low as the ground check found
-- it). Or nil and why, if it can't be told.
local function landingKind(P, w, at, nx, ny, nz, fx, fy, fz, rx, ry, rz, lift, ahead)
    local from, length, g = w.at, w.dt, P.gravity
    if not (from and at) then
        return nil, "the mod has no position for it"
    elseif w.long then
        return nil, "the frame was longer than the mod counts"
    elseif not st.worldGravity then
        return nil, "the game's gravity isn't known" -- the fall isn't the mod's parabola then
    end
    local dx, dy, dz = from.X - at.X + fx * length, from.Y - at.Y + fy * length, from.Z - at.Z + fz * length
    local h0 = dz + (dx * nx + dy * ny) / nz
    local a = rz + (rx * nx + ry * ny) / nz
    -- When the path above the plane, from the height h, comes down to it.
    local function down(h)
        if g > 0 then
            -- (No root: inside Unreal's walking gap and never above the plane. The top of the path.)
            local root = a * a + 2 * g * h
            return root > 0 and (a + math.sqrt(root)) / g or a / g
        elseif a < 0 then
            return -h / a
        end
        return nil
    end
    ahead = math.max(0, ahead or 0)
    local tc
    if h0 < -FLOOR_GAP then
        tc = nil -- under this plane while still in the air: it came down on something else
    else
        tc = down(h0 + lift - ahead)
        if tc and tc > length + 1e-6 then
            tc = nil -- it didn't come down to this plane within the frame
        elseif tc and ahead > 0 then
            tc = down(h0 + lift)
        end
        h0 = h0 + lift
    end
    if not tc then
        return nil, "the floor isn't the plane it came down on"
    end
    -- The last update that began at or before tc: when (tb), and how long it is.
    local tb, step
    if P.rate > 0 then
        local air = w.air or 0
        step = 1 / P.rate
        tb = math.floor((air + tc) * P.rate + 1e-9) * step - air
    elseif tc > length + 1e-6 then
        tb, step = length, length -- (the update this hook begins: the next frame's length isn't known)
    else
        step = w.prevDt or length
        local back = math.ceil(-tc / step - 1e-9) -- frames before the last hook
        if back > 0 then
            tb = -back * step
        else
            tb, step = 0, length
        end
    end
    local above = h0 + a * tb - 0.5 * g * tb * tb
    local rising = rz - g * tb
    local resting = P.restHeight / nz -- where a player rests above the plane, straight up
    -- (The check's 2 units end short of a floor exactly 2 units below.)
    if rising <= P.airborneSpeed and above < P.groundCheck then
        -- Coming down on the floor by less than 2 units an update, an earlier update may
        -- have ended within reach too: the first that did is where the player was set
        -- down from. (Not looked for with one update per frame: the lengths of the frames
        -- before the last two aren't kept. The height returned, which the log names, is
        -- then the last such update's, up to nearly 2 units lower, and the resting height
        -- up to 1/32 unit lower. The kind is the same.) Nor before the hook of the last
        -- hull change in the air (w.hullAir): the updates before it had the other hull's
        -- feet, 18 units off.
        if P.rate > 0 then
            for _ = 1, 64 do
                local t = tb - step
                local h, v = h0 + a * t - 0.5 * g * t * t, rz - g * t
                if (w.air or 0) + t < step - 1e-9 or v > P.airborneSpeed or h >= P.groundCheck or h < 0
                    or (w.hullAir and (w.air or 0) + t < w.hullAir - 1e-9) then
                    break
                end
                tb, above, rising = t, h, v
            end
        end
        -- The ground check moves the player down to its resting height, never up.
        return "caught", nil, above, rising, math.max(0, math.min(above, resting))
    end
    -- The move stops where the player rests, or stays as low as it started.
    return "hit", rising - 0.5 * g * step, above, rising, math.max(0, math.min(above, resting))
end

-- A landing's height above the slope (cm, see landingKind) in units, for the log: to 0.1
-- unit, but where that would read the ground check's 2.0, to 0.01 and cut, not rounded,
-- so that a height within its reach never reads 2 or more, nor one out of it less.
local function heightText(P, above)
    local h = math.max(above, 0) / P.unitScale
    local text = string.format("%.1f", h)
    if text == string.format("%.1f", P.groundCheck / P.unitScale) then
        text = string.format("%.2f", math.floor(h * 100) / 100)
    end
    return text
end

-- Why a landing ran into the slope instead of being set down by the ground check, for
-- the log. above, rising: from landingKind (nil if it couldn't tell).
local function whyHit(P, above, rising)
    local u = P.unitScale
    if not above then
        return "it was still rising faster than 180 u/s, so Half-Life has you in the air"
    elseif rising > P.airborneSpeed then
        return string.format("at the Half-Life update before it you were rising %.0f u/s, over the ground check's "
            .. "180", rising / u)
    end
    return string.format("the Half-Life update before it ended %s units above the slope, out of the ground "
        .. "check's reach of %.0f", heightText(P, above), P.groundCheck / u)
end

-- Whether a rise a clip left (cm/s) keeps Half-Life's player in the air, sliding up the
-- slope. Its ground check at the start of the next update has the player on the ground
-- once it rises no faster than 180 u/s, and that is half an update of gravity after the
-- clip: so the rise must be over 180 u/s then (184 at the clip, at 100 updates a
-- second). dt: this frame's length, which is the update with PhysicsRate 0.
local function staysUp(P, rise, dt)
    local step = P.rate > 0 and 1 / P.rate or dt
    return rise - 0.5 * P.gravity * step > P.airborneSpeed
end

-- A slide up a slope from a clip against the floor (unit normal nx, ny, nz) that left the
-- rise vz: Half-Life's player rests 1/32 unit off the floor's plane after it, or lower
-- where a landing left it lower (st.landRest; see physics.simulate, which follows the
-- path's height above the floor).
local function newSlide(P, vz, nx, ny, nz, away)
    return { vz = vz, away = away, nx = nx, ny = ny, nz = nz, h = st.landRest or P.restHeight / nz, rise = 0,
        push = 0, time = 0, clipped = true, dx = 0, dy = 0, ox = 0, oy = 0 }
end

-- The end of a slide up a slope, at that ground check: with the horizontal velocity its
-- last clip left (vx, vy) and the rise it had then.
local function slideOver(P, vx, vy, rise)
    local onEdge = st.slide and st.slide.edge
    st.slide = nil
    slideLine("the slide up the slope ended at %.0f u/s (rising %.0f u/s, not more than 180 at Half-Life's next "
        .. "ground check)%s", horizontal(vx, vy) / P.unitScale, rise / P.unitScale, edgeNote(onEdge))
end

-- For a slide, the part of a frame that Half-Life's updates don't count (extra seconds,
-- in a frame over 0.1 s): Unreal walks all of the frame, so the slide's gravity covers
-- that part too, in one piece. Returns the horizontal velocity, and whether the slide
-- is over.
local function slideRest(P, slide, vx, vy, extra, dt)
    local up = slide.vz - P.gravity * extra
    if slide.nx then
        local cx, cy
        cx, cy, up = physics.clip(vx, vy, up, slide.nx, slide.ny, slide.nz)
        if cx * vx + cy * vy < 0 then
            -- So long that its gravity would turn the slide back down the slope: it
            -- stops there (Half-Life's slide ends long before it turns).
            cx, cy, up = 0, 0, 0
        end
        vx, vy = cx, cy
    end
    slide.vz = up
    return vx, vy, not staysUp(P, up, dt)
end

-- A landing on a slope (see slopeStep), with (nx, ny, nz) the floor's normal and
-- (vx, vy) the horizontal velocity, relative to a moving platform it landed on.
-- touchdown: where the character stands now (at), the platform's velocity (x, y, z) and
-- how far above the floor it stands (gap, see floorGap). dt: this frame's length.
-- The last value returned describes the landing for the hop line: how much the
-- horizontal speed changed (change, cm/s), and without a slide its kind and the
-- height above the slope where the last update before it ended (see landingKind).
local function slopeLanding(cfg, P, nx, ny, nz, vx, vy, touchdown, dt)
    -- Unreal's landing stands with no usable floor or a flat one.
    if not nx or nz >= 1 then
        return true, vx, vy, 0
    end
    local w = st.written
    local u = P.unitScale
    -- How Half-Life would have landed here. With nothing written in the air on the frame
    -- before (after a pause, for one) it can't be told.
    local kind, fall, above, rising
    local why = "the mod has nothing from the frame before, as after a pause"
    if w then
        local fx, fy, fz = touchdown.x, touchdown.y, touchdown.z
        local rx, ry, rz = w.x - fx, w.y - fy, w.z - fz
        if st.stayBasedInAir then
            -- The platform carried the character in the air, up and down too, and the
            -- velocity stayed relative to it.
            fx, fy, fz = w.baseX, w.baseY, w.baseZ
            rx, ry, rz = w.x, w.y, w.z
        end
        -- How much higher Half-Life's player is above its floor's plane than the character
        -- above the plane it now stands on. Half-Life's player took off from where it
        -- rested: 1/32 unit off its floor's plane, at right angles to it, or lower if its
        -- last landing left it lower (st.takeoffRest). And Unreal holds the character 1.9
        -- to 2.4 cm above the floor it walks on, not always the same: Half-Life's hop
        -- starts on the floor, so it is the character's less the gap at the take-off, and
        -- the floor lies the gap at the landing below where the character now stands.
        -- (Without both gaps they are taken as equal: half a centimetre between them is
        -- 0.2 units of the ground check's 2, as much as a hop on the spot has to spare.)
        local lift = st.takeoffRest or P.restHeight / nz
        if touchdown.gap and st.takeoffGap then
            lift = lift + touchdown.gap - st.takeoffGap
        end
        -- A flight with a hull of its own. A duck tap's: Half-Life lifted its player 18 units,
        -- the mod the character a little less (see hull.lift). Ducked at the take-off
        -- (st.takeoffDuck) or here: Unreal's crouched capsule rests exactly 18 units below the
        -- standing one on any slope, while on Valve's maps the ducked hull's floor lies
        -- duck.restGap below the standing hull's (17 units on a 17.7 degree ramp), so a ducked
        -- Half-Life player rests that much higher than the crouched capsule. Where these leave
        -- Half-Life's player higher than the character, it is still above its floor as Unreal
        -- lands the character (after a duck tap's lift by about 2 units: that is what times
        -- Unreal's landing to Half-Life's ground check), and comes down after the frame's end.
        local own = (st.takeoffLift or 0) + (st.takeoffDuck or 0)
        if touchdown.ducked then
            own = own + (duck.restGap(nz) - duck.SHIFT) * P.unitScale
        end
        kind, fall, above, rising, st.landRest = landingKind(P, w, touchdown.at, nx, ny, nz, fx, fy, fz, rx, ry, rz,
            lift + own, own)
        if not kind then
            -- Still rising faster than 180 u/s after the whole frame's gravity, it was in
            -- the air for Half-Life on every update of the frame, whatever the floor: the
            -- ground check can't have caught it. (Unreal also lands a character that rises
            -- away from the floor, see below.)
            why = fall -- (landingKind's reason)
            fall = rz - P.gravity * w.dt
            kind = fall > P.airborneSpeed and "hit" or nil
        end
    end
    local before = horizontal(vx, vy)
    if fall and touchdown.leaveFall then
        -- A leap down a slope (see slopeStep). Half-Life's update that left the floor moved
        -- straight ahead and ended in the air, c/rate above the slope (c: how fast the floor
        -- falls under the velocity), with the second half of its gravity on; the mod's flight
        -- starts from the floor without either. On an even slope the heights differ by
        -- (c - g t / 2) / rate, t seconds into the flight, which is nothing where they come
        -- down (t = 2 c / g): the last update above the slope is as high as Half-Life's, within
        -- g / (2 rate^2), and the landing comes out the same kind. But Half-Life's player comes
        -- down that half update of gravity faster, and a landing that runs into the slope
        -- clips that fall. (Correcting the height too was tried: see CLAUDE.md, "Slopes".)
        fall = fall - touchdown.leaveFall
    end
    if kind == "hit" then
        local cx, cy, cz = physics.clip(vx, vy, fall, nx, ny, nz)
        local after = horizontal(cx, cy)
        if staysUp(P, cz, dt) and cfg.SlopeBoosts then
            -- Unreal also lands a character that still rises away from the floor: its capsule
            -- caught the edge of a ledge, or it came down on a steeper part and the frame
            -- ended on this one. The clip leaves that velocity as it is. Half-Life has this
            -- player in the air too, so the rules of a slide apply: no jump, and on the next
            -- frame it flies off if its path leaves the floor far enough. If not, Unreal walks
            -- it, and within 0.1 s the rise is down to 180 u/s (a held jump fires then) or
            -- the path is back on the slope, a slide like any other. The line tells the two
            -- kinds of landing apart.
            local away = vx * nx + vy * ny + fall * nz >= 0
            st.slide = newSlide(P, cz, nx, ny, nz, away)
            count("slides")
            countSlopeLanding("hit", after - before)
            if away then
                slideLine("the game landed you on a %.0f degree slope at %.0f u/s while still %s, away from it: "
                    .. "Half-Life keeps you in the air above 180", degrees(nz), before / u, vertical(fall, P))
            else
                slideLine("landed on a %.0f degree slope at %.0f u/s, %s: sliding up it at %.0f u/s, rising %.0f u/s "
                    .. "(Half-Life keeps you in the air above 180)", degrees(nz), before / u, vertical(fall, P),
                    after / u, cz / u)
            end
            return false, cx, cy, cz, nil, { change = after - before }
        end
        if not cfg.SlopeLandings then
            return true, vx, vy, 0
        end
        countSlopeLanding("hit", after - before)
        if degrees(nz) >= LOGGED_SLOPE or math.abs(after - before) >= LOGGED_CHANGE * u then
            landingLine(true, "landed on a %.0f degree slope at %.0f u/s, %s: %.0f u/s (%+.0f). It ran into the "
                .. "slope: %s", degrees(nz), before / u, vertical(fall, P), after / u, (after - before) / u,
                whyHit(P, above, rising))
        end
        return true, cx, cy, 0, nil, { change = after - before, kind = "hit", above = above }
    end
    if not cfg.SlopeLandings then
        return true, vx, vy, 0
    end
    -- Caught by Half-Life's ground check, or not to be told: the speed stays, as Unreal
    -- landed it.
    kind = kind or "unknown"
    countSlopeLanding(kind, 0)
    if degrees(nz) >= LOGGED_SLOPE then
        if kind == "caught" then
            landingLine(false, "landed on a %.0f degree slope at %.0f u/s: the speed stays. A Half-Life update "
                .. "ended %s units above the slope, within the ground check's reach of %.0f, which sets you down "
                .. "before you run into it", degrees(nz), before / u, heightText(P, above), P.groundCheck / u)
        else
            landingLine(false, "landed on a %.0f degree slope at %.0f u/s: the speed stays. The mod can't tell "
                .. "whether a Half-Life update would have run into it (%s)", degrees(nz), before / u, why)
        end
    end
    return true, vx, vy, 0, nil, { change = 0, kind = kind, above = above }
end

-- Whether the character walked down so steeply in the frame before that one of
-- Half-Life's updates on the ground may leave the floor (see physics.leavesFloor), at any
-- speed: then the floor is read, also below the speed at which one could slide up a
-- slope. It goes by where the character was at the last hook and is now (read every
-- frame anyway), so it costs no game call.
local function descends(P, at, dt)
    local w = st.written
    if not (w and w.at and at and w.mode == WALKING and w.dt and w.dt > 0) then
        return false
    end
    local step = P.rate > 0 and 1 / P.rate or dt
    return (w.at.Z - at.Z) / w.dt * step + P.restHeight >= DESCENT_SHARE * P.groundCheck
end

-- A flight off a slope that the mod starts gets its line from movement.step, once the
-- take-off speed over the ground is known (with the velocity of the moving platform the
-- character left, as the flight's landing line and the hop lines count it). flewLine and
-- leaveLine give the function that writes it, called with that speed in u/s.

-- Flying off the top of a slide: rise, the vertical speed it flies off with (cm/s);
-- tail, the end of the line.
local function flewLine(P, rise, tail)
    return function(speed)
        slideLine("flew off the slope at %.0f u/s, rising %.0f u/s%s", speed, rise / P.unitScale, tail)
    end
end

-- Leaving a slope that falls away under the character (see slopeStep): (vx, vy), the
-- velocity on the floor (relative to a moving platform, as the floor moves with it).
local function leaveLine(P, nx, ny, nz, vx, vy, dt)
    local u = P.unitScale
    count("launches")
    local falls = (vx * nx + vy * ny) / nz * (P.rate > 0 and 1 / P.rate or dt) / u
    return function(speed)
        slideLine("flew off a %.0f degree slope going down it at %.0f u/s (the floor falls %.1f units in one "
            .. "Half-Life update, out of the ground check's reach of %.0f)", degrees(nz), speed, falls,
            P.groundCheck / u)
    end
end

-- A sloped floor the character walks on, for this frame's Half-Life updates on the
-- ground (see walkFloor): if it falls away under the velocity (vx, vy), one of them
-- may leave it.
local function walkOn(cfg, nx, ny, nz, vx, vy)
    if cfg.SlopeBoosts and nx and nz < 1 and vx * nx + vy * ny > 0 then
        walkFloor = { nx = nx, ny = ny, nz = nz }
    end
end

-- A sloped floor the character walks on, for this frame's Half-Life updates on the ground
-- to run into (see runInFloor): each update that ran on the ground and didn't jump or lift
-- runs into it with the velocity it left, after its friction, and slides up it if the clip
-- leaves a rise over 180 u/s at the next update's ground check (physics.simulate, Half-Life's
-- order: its worked example has the friction first).
local function armRunIn(cfg, nx, ny, nz)
    if cfg.SlopeBoosts and nx and nz < 1 then
        runInFloor = { nx = nx, ny = ny, nz = nz }
    end
end

-- Half-Life's slopes, on the velocity this frame starts from (relative to a moving
-- platform the character stands on; vz is Unreal's vertical speed). Unreal walks a
-- character along any walkable floor keeping its horizontal speed, and lands it
-- keeping its horizontal speed. Half-Life clips the velocity against a surface it runs
-- into (overbounce 1): at a landing whose move reaches the floor before the ground
-- check does (SlopeLandings, see landingKind), and on the ground running into an
-- upward slope. A player rising faster than 180 u/s is in the air even on a slope
-- (SlopeBoosts): it slides up the slope without friction and flies off where the slope
-- falls away. While it slides, Unreal still walks the character along the slope (so
-- the game doesn't land it again every frame); the mod keeps the vertical speed
-- Half-Life would have, with the gravity Unreal doesn't apply while it walks. The slide
-- runs update by update with the rest of Half-Life's movement (physics.simulate): each
-- update takes its gravity off and clips against the slope again if its move reaches the
-- slope's plane (Half-Life's player rests 1/32 unit off it; the path is followed above
-- the floor, which is measured again each frame where Unreal walked the character), and
-- the slide is over at the start of the update that finds the rise at 180 u/s or less,
-- half an update of gravity after the last move (see staysUp), with the speed it left,
-- if the floor is within the ground check's 2 units of the path; where the floor fell
-- away under the path (a top that rounds off), it flies on instead. (0.3.0 took
-- a frame's gravity off, clipped again and then compared with 180 u/s: its slides ended
-- later and slower than Half-Life's.) A frame longer than the updates count (0.1 s)
-- has the slide's gravity for all of it, as Unreal walks all of it (see slideRest). A
-- flight off the slope starts with the rise the slide had, not that less this frame's
-- gravity: Unreal's falling update takes the frame's gravity off itself, in the same
-- frame. Running into an upward slope is decided at each of the frame's Half-Life updates
-- on the ground, after its friction and acceleration, as Half-Life's ground move runs:
-- this arms it (see armRunIn; physics.simulate decides, and movement.step starts the slide),
-- on a walkable slope and after a landing Half-Life leaves on the ground. An update that
-- jumps or lifts a duck tap makes no ground move, so it never runs into the slope.
-- Running down a slope (SlopeBoosts), Half-Life's ground move goes straight ahead and
-- its ground check after it reaches 2 units down: where the floor falls further than
-- that under one update's move, the player is in the air from the end of that update,
-- without friction, until it comes down on the slope again (a landing like any other).
-- Unreal walks a character down any walkable slope, so the mod has it leave, as at the
-- top of a slide (SetMovementMode, no vertical speed): at the start of a frame if the
-- last update ran on the ground and its velocity leaves this floor, or at one of the
-- frame's updates (see walkFloor and physics.simulate, and movement.step). Not while
-- the game's own jump is pressed (bPressedJump): Unreal does that jump. The half update
-- of gravity Half-Life's leaving update ends with is kept for the leap's landing
-- (leaveFall, see slopeLanding).
-- landed: at a landing, where the character stands and the velocity of the floor (see
-- slopeLanding); nil otherwise. pawn: the character. at: where it is now.
-- Returns whether Half-Life has the player on the ground; the velocity; how it leaves
-- the ground off a slope ("launch": the mod has it leave now; "off the end": Unreal
-- walked it off the end of the slope); at a landing on a slope, what it did to the
-- horizontal speed (see slopeLanding); and at a launch, what writes its line (see
-- flewLine: movement.step writes it once the platform's velocity is known).
local function slopeStep(cmc, cfg, P, mode, landed, vx, vy, vz, dt, pawn, at)
    local slide = st.slide
    local u = P.unitScale
    if mode == FALLING then
        st.slide = nil
        if not slide then
            return false, vx, vy, vz
        end
        if vz > GAME_JUMP_SHARE * P.jumpSpeed then
            -- The game's own jump, which Unreal does whenever it walks the character and
            -- the mod couldn't hold back (see holdGameJump): the higher rise stays. The
            -- game's jump has had a frame of Unreal's gravity, so the slide's rise is
            -- compared after one too.
            local up = math.max(vz, slide.vz - P.gravity * dt)
            slideLine("the game jumped while sliding up the slope, at %.0f u/s, rising %.0f u/s",
                horizontal(vx, vy) / u, up / u)
            return false, vx, vy, up
        end
        -- Unreal walked the character off the end of the slope: it flies on, rising as
        -- it slid.
        count("launches")
        slideLine("off the end of the slope at %.0f u/s, rising %.0f u/s%s", horizontal(vx, vy) / u, slide.vz / u,
            edgeNote(slide.edge))
        return false, vx, vy, slide.vz, "off the end"
    end
    local fast = vx * vx + vy * vy > (2 * P.airborneSpeed) ^ 2 -- slower can't slide up a walkable slope
    if mode ~= WALKING or not (landed or slide or (cfg.SlopeBoosts and (fast or descends(P, at, dt)))) then
        st.slide = nil
        return true, vx, vy, 0
    end
    local nx, ny, nz, readable, edge = floorNormal(cmc)
    if readable == false then
        st.unreadableFloors = st.unreadableFloors + 1
        if st.unreadableFloors >= MAX_UNREADABLE_FLOORS then
            st.slopeBroken = true
            st.slide = nil
            log.once("slope-floor", "Could not read the normal of the floor under the character (CurrentFloor."
                .. "HitResult.ImpactNormal), so slopes are left to Unreal. Please report UE4SS.log.")
            return true, vx, vy, 0
        end
    else
        st.unreadableFloors = 0
    end
    if landed then
        noteFloor(nx, nz, readable)
        if nx and nz < 1 then
            landed.gap = floorGap(cmc)
        end
        local ground, cx, cy, cz, leave, slope = slopeLanding(cfg, P, nx, ny, nz, vx, vy, landed, dt)
        if ground then
            -- On the ground for Half-Life (set down, not told apart, or run into without a
            -- slide): this frame's updates walk on it, and may run into it.
            walkOn(cfg, nx, ny, nz, cx, cy)
            armRunIn(cfg, nx, ny, nz)
        end
        return ground, cx, cy, cz, leave, slope
    end
    if slide then
        -- Frames in a row on an edge, for the log (see edgeNote).
        local onEdge = slide.edge
        slide.edge = edge and (onEdge or 0) + 1 or nil
        -- Half-Life's velocity: as the last frame's updates left it, unless the floor fell
        -- away under them (see below).
        local hx, hy, hz = vx, vy, slide.vz
        if slide.floorZ and at then
            -- How far Half-Life's path is above the floor now (slide.h, straight up). Last
            -- frame's updates followed it against the plane of the floor read then; Unreal
            -- walked the character on along the real floor, which may have fallen away
            -- under the path (the top of the slope rounding off). The path is ahead of the
            -- character by (slide.ox, slide.oy), see movement.step.
            local floorZ = at.Z - (floorGap(cmc) or 0) - (nx and (nx * slide.ox + ny * slide.oy) / nz or 0)
            local drop = slide.floorZ + slide.rise - floorZ -- how far the floor lies below that plane
            slide.h, slide.floorZ = math.max(0, slide.h + drop), floorZ
            if slide.clipped and drop > 0 and nx and slide.nx and slide.push > 0 and slide.time > 0 then
                -- The updates ended against that plane, but the floor bent away under them:
                -- the clips after the path left it (their share by how far it fell, as if
                -- it bent in one place) were the plane's, not the floor's. Taken back.
                local was = -(vx * slide.nx + vy * slide.ny) / slide.nz
                local now = -(vx * nx + vy * ny) / nz
                if was > now then
                    local back = math.min(1, drop / ((was - now) * slide.time)) * slide.push
                    hx, hy, hz = vx - back * slide.nx, vy - back * slide.ny, slide.vz - back * slide.nz
                end
            end
        end
        slide.rise, slide.push, slide.time = 0, 0, 0
        if not staysUp(P, hz, dt) then
            if slide.h >= P.groundCheck then
                -- Not rising faster than 180 u/s any more, but out of the ground check's
                -- reach above the floor, which fell away under the slide: Half-Life's player
                -- is in the air, and flies on, with the velocity the slide had.
                st.slide = nil
                count("launches")
                return false, hx, hy, hz, "launch", nil, flewLine(P, hz, string.format(": the slide ended %.1f units "
                    .. "above it, out of the ground check's reach of %.0f%s", slide.h / u, P.groundCheck / u,
                    edgeNote(onEdge)))
            end
            -- Over at this frame's first update: on the ground from here on.
            slideOver(P, hx, hy, hz)
            return true, hx, hy, 0
        end
        slide.nx, slide.ny, slide.nz = nx, ny, nz
        if nx then
            -- Half-Life's player only touches the floor while its velocity goes into it.
            -- Where the floor falls away (the top of the slope, or a steeper part going
            -- down), it flies off if it would rise more than leaveHeight above the floor.
            -- (Decided from the rise after this frame's gravity, counted over dt also in
            -- a long frame; the flight itself starts with the rise before it, see above.)
            local away = vx * nx + vy * ny + (slide.vz - P.gravity * dt) * nz
            if away > 0 and away * away > 2 * P.gravity * nz * P.leaveHeight then
                st.slide = nil
                count("launches")
                return false, vx, vy, slide.vz, "launch", nil, flewLine(P, slide.vz, edgeNote(onEdge))
            end
        end
        -- (The frame's updates of the slide run in physics.simulate, see movement.step.)
        slide.vz = hz
        return false, hx, hy, hz
    end
    if nx and nz < 1 then
        -- Running down a slope: the last update ran on the ground, and its ground move
        -- left the floor (a jump can't start then: the player is in the air).
        if st.groundSteps > 0 and physics.leavesFloor(vx, vy, nx, ny, nz, P.rate > 0 and 1 / P.rate or dt,
            P.groundCheck, P.restHeight) and ue.bool(pawn, "bPressedJump") ~= true then
            -- (With PhysicsRate 0 the update that left was the frame before.)
            leaveFall = 0.5 * P.gravity * (P.rate > 0 and 1 / P.rate or (st.written and st.written.dt or dt))
            return false, vx, vy, 0, "launch", nil, leaveLine(P, nx, ny, nz, vx, vy, dt)
        end
        -- Running into an upward slope, Half-Life's ground move clips the velocity against
        -- it and keeps its vertical part: if that still rises faster than 180 u/s at the next
        -- update's ground check, the player is in the air from then on. First the update
        -- that took the character onto this floor: Unreal's walk after the last hook did, so
        -- the last frame's updates had the floor before, and the last of them ran into this
        -- one with the velocity it left, after its friction (what the mod wrote then: Half-
        -- Life's order, as for the frame's own updates, which simulate decides one by one).
        local w = st.written
        if w and w.mode == WALKING and not w.jumped and not w.launched and not w.lifted then
            local _, _, up = physics.clip(w.x, w.y, 0, nx, ny, nz)
            if staysUp(P, up, dt) then
                st.slide = newSlide(P, up, nx, ny, nz)
                count("slides")
                slideLine("ran into a %.0f degree slope at %.0f u/s: sliding up it, rising %.0f u/s (Half-Life "
                    .. "keeps you in the air above 180)", degrees(nz), horizontal(w.x, w.y) / u, up / u)
                return false, w.x, w.y, up
            elseif up > P.airborneSpeed and st.duck then
                -- In the air at that update's last ground check, on the ground at the next one's
                -- first: the client builds the next duck button from the air (physics.simulate).
                st.duck.airSeen = true
            end
        end
        armRunIn(cfg, nx, ny, nz)
        walkOn(cfg, nx, ny, nz, vx, vy)
    end
    return true, vx, vy, 0
end

-- The line of a slide a run-in started at one of this frame's updates: the velocity and
-- the rise that update left (after its friction: Half-Life's numbers). onPress: the update
-- pressed the duck (+ducktap or a duck notch): Half-Life's slope boost from the ground,
-- where there is no duck tap.
local function runInLine(P, slide, runIn, onPress)
    local u = P.unitScale
    slideLine("ran into a %.0f degree slope at %.0f u/s: sliding up it, rising %.0f u/s (Half-Life keeps you in the "
        .. "air above 180)%s", degrees(slide.nz), horizontal(runIn.vx, runIn.vy) / u, runIn.up / u,
        onPress and ", on a duck tap's press (no tap: Half-Life's slope boost)" or "")
end

-- While the character slides up a slope it is in the air for Half-Life, where a jump
-- does nothing, but Unreal walks it and would do the game's own jump: the game's
-- input sets bPressedJump before this hook, and Unreal's movement update jumps. So
-- the game's press is taken back.
local function holdGameJump(pawn)
    if ue.bool(pawn, "bPressedJump") ~= true then
        return
    end
    log.first("slide-jump", "Holding back the game's own jump while sliding up a slope (StopJumping): Half-Life "
        .. "doesn't jump in the air")
    if ue.call(pawn, "StopJumping") then
        count("stoppedJumps")
    end
end

-- The landing after flying off a slope. A flight isn't a hop, so this line (in the
-- slides' budget) stands in for a hop line.
local function flightLine(flight, landing, P)
    local u = P.unitScale
    local change = (landing - flight.takeoff) / u
    slideLine("landed %.2f s after flying off the slope, at %.0f u/s (%+.0f)", flight.time, landing / u,
        math.abs(change) <= 0.5 and 0 or change)
end

local function keysHeld(forward, right)
    return (forward > 0 and "W" or "") .. (right < 0 and "A" or "") .. (forward < 0 and "S" or "")
        .. (right > 0 and "D" or "")
end

-- slope: at a landing on a slope, what it did to the horizontal speed (see slopeLanding).
-- The line says which kind of landing it was, so a reader can tell why one landing on
-- a hill changed the speed and the next didn't.
local function hopLine(hop, landing, P, slope)
    st.hops = st.hops + 1
    if st.hopLines >= MAX_HOP_LINES then
        return
    end
    st.hopLines = st.hopLines + 1
    local u = P.unitScale
    local time = math.max(hop.time, 1e-6)
    local gain = (landing - hop.takeoff) / u
    if math.abs(gain) <= 0.5 then
        gain = 0 -- not "-0"
    end
    local onSlope = ""
    if slope then
        local change = slope.change / u
        change = math.abs(change) <= 0.5 and 0 or change
        local from = slope.above and string.format(" from %s u up", heightText(P, slope.above)) or ""
        if st.slide then
            onSlope = string.format(", slope %+.0f (%s)", change, st.slide.away and "still in the air"
                or "sliding up it")
        elseif slope.kind == "hit" then
            onSlope = string.format(", slope %+.0f (ran into it%s)", change, from)
        elseif slope.kind == "caught" then
            onSlope = string.format(", slope: speed kept (set down%s)", from)
        else
            onSlope = ", slope: speed kept (can't tell how it landed)"
        end
    end
    local keys = {}
    for _, key in ipairs({ "W", "A", "S", "D" }) do
        if hop.keys[key] then
            keys[#keys + 1] = key
        end
    end
    local body = ""
    if hop.bodyOff then
        body = string.format(", body %+.0f deg from where it headed", math.abs(hop.bodyOff) < 0.5 and 0 or hop.bodyOff)
    end
    -- Half-Life's duck in the hop: fully ducked as it left the ground, or ducked in the air
    -- (after so long), stood up in the air, and ducked at the landing.
    local ducking = ""
    if hop.duckedTakeoff then
        ducking = ", ducked as it took off"
    elseif hop.duckedAt then
        ducking = string.format(", ducked after %.2f s", hop.duckedAt)
    end
    if hop.stoodAt then
        ducking = ducking .. string.format(", stood up in the air after %.2f s", hop.stoodAt)
    end
    if hop.landedDucked then
        ducking = ducking .. ", landed ducked"
    end
    -- A sudden loss of speed in the hop (see speedLoss): what it ran into took this much, or the
    -- game setting the speed itself.
    local hit = (hop.hit and string.format(", ran into something, -%.0f u/s", hop.hit / u) or "")
        .. (hop.gameSet and string.format(", the game set the speed, -%.0f u/s", hop.gameSet / u) or "")
    log.info("Hop %d (%.0f fps, %.1f updates per frame): take-off %.0f u/s, landing %.0f u/s (%+.0f)%s, %.2f s in "
        .. "the air, view turned %.0f deg (%.0f deg/s), keys %s%s%s, speed cuts %d%s%s", hop.n, hop.frames / time,
        hop.steps / math.max(hop.frames, 1), hop.takeoff / u, landing / u, gain, onSlope, hop.time,
        hop.turn, hop.turn / time, #keys > 0 and table.concat(keys) or "none", ducking, hit, st.counts.cuts - hop.cuts,
        body, st.hopLines == MAX_HOP_LINES and " (further hops aren't logged)" or "")
end

-- The landing of a duck tap: its line (a tap isn't a hop), within its own budget.
-- landing: the horizontal speed it landed with (cm/s).
local function tapLine(tap, landing, P)
    st.taps = st.taps + 1
    if st.tapLines >= MAX_TAP_LINES then
        return
    end
    st.tapLines = st.tapLines + 1
    local u = P.unitScale
    local function signed(v)
        v = v / u
        return math.abs(v) <= 0.5 and 0 or v
    end
    local keys = {}
    for _, key in ipairs({ "W", "A", "S", "D" }) do
        if tap.keys[key] then
            keys[#keys + 1] = key
        end
    end
    local frames = math.max(tap.frames, 1)
    log.info("Tap %d (%.0f fps, %.1f updates per frame): %.0f u/s before its ground update%s, %.0f at "
        .. "the lift (%+.0f), %d ground update%s before the lift, %.2f s and %d updates in the air, landing %.0f u/s "
        .. "(%+.0f), keys %s%s", tap.n, frames / math.max(tap.time, 1e-6), tap.updates / frames, tap.before / u,
        tap.ground == 1 and "" or "s", tap.lifted / u, signed(tap.lifted - tap.before), tap.ground,
        tap.ground == 1 and "" or "s", tap.time, tap.updates, landing / u, signed(landing - tap.lifted),
        #keys > 0 and table.concat(keys) or "none", st.tapLines == MAX_TAP_LINES and " (further taps aren't logged)"
            or "")
end

-- Where the character heads in the air (see movement.heading): the yaw of hx, hy,
-- the horizontal velocity the mod hands to Unreal apart from the moving platform's
-- that leaving it added, so that hopping in place on a moving platform doesn't turn
-- the body to the platform's way. The body's target is led by how fast the heading
-- turns. The heading only changes in Half-Life updates, each with the view of its own
-- time (physics.simulate), so that rate is the heading's turn over the time the
-- frame's updates stand for (updateTime: their number over PhysicsRate; with
-- PhysicsRate 0, the time since the last frame that ran one), and a frame that runs
-- none keeps the last rate. A frame with two updates then turns the heading and the
-- target twice as far as one with one, while ALS turns the body evenly, within about
-- an update's turn of the heading. (Over the frames' time the rate read 0.6 to 1.6
-- times the real one, by the frame's number of updates, and the target jumped by
-- about 20 degrees from frame to frame.)
-- It starts again whenever the run of air frames breaks. When a run ends because the
-- character got too slow, the body's target is once more the last heading, without
-- the lead. The rate isn't averaged: an average leaves the body further behind after
-- every change between A and D (see "Facing" in CLAUDE.md).
local function trackHeading(frame, hx, hy, dt, frameDt, steps, updateTime)
    local going = st.headingFrame == frame - 1 and st.headingYaw ~= false
    local heading, target = false, false
    if hx * hx + hy * hy > HEADING_SPEED * HEADING_SPEED then
        heading = math.deg(math.atan(hy, hx))
        target = heading
        if going and dt > 0 then
            st.headingTime = st.headingTime + dt
            if steps > 0 then
                st.headingRate = physics.turn(st.headingRef, heading) / (updateTime or st.headingTime)
                st.headingRef, st.headingTime = heading, 0
            end
            local lead = (st.headingRate or 0) * math.max(0, 1 / ALS_AIR_TURN - (frameDt or dt))
            target = heading + math.max(-LEAD_LIMIT, math.min(LEAD_LIMIT, lead))
        end
    elseif going then
        -- Too slow from here on (a wall hit head on, braking in the air). The target
        -- of the frame before was led, and nothing is written while it is slow: ALS
        -- would go on turning the body to that target, up to LEAD_LIMIT degrees past
        -- where the character last headed, and leave it there on the ground (it turns
        -- a body there only above 150 cm/s, or with movement input, which the mod
        -- takes). So the body gets the last heading once, to settle on.
        target = st.headingYaw
    end
    if not (heading and going) then
        st.headingRate, st.headingRef, st.headingTime = nil, heading, 0
    end
    st.headingFrame, st.headingYaw, st.headingTarget = frame, heading, target
end

-- How far the body is from where the character headed in the frame before, in
-- degrees (+: to the right of it), for the hop line. ALS's update in that frame
-- turned the body towards that heading, led, so this shows how well it keeps up.
-- Read once per logged hop, at its top, and only if movement.faceHeading turned the
-- body to where it heads in that frame (not in first person, where it faces the view).
local function bodyOffset(pawn, frame)
    if st.hopLines >= MAX_HOP_LINES or st.facedFrame ~= frame - 1 or type(st.headingYaw) ~= "number" then
        return nil
    end
    local ok, rotation = ue.call(pawn, "K2_GetActorRotation")
    local yaw = ok and ue.number(rotation, "Yaw")
    if not yaw then
        return nil
    end
    return physics.turn(st.headingYaw, yaw)
end

-- The frame's Half-Life updates as physics.simulate ran them, kept to run them again
-- without a duck tap's lift (see movement.step): the simulation's clock and view, the duck
-- state, a slide's fields and a walked floor's leave.
local function copy(t)
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return c
end

local function snapshot(slide, floor)
    return { time = st.sim.time, yaw = st.sim.yaw, duck = duck.copy(st.duck), slide = slide and copy(slide),
        left = floor and floor.left }
end

local function putBackSnapshot(snap, slide, floor)
    st.sim.time, st.sim.yaw = snap.time, snap.yaw
    st.duck = snap.duck
    if slide then
        for k in pairs(slide) do
            slide[k] = nil
        end
        for k, v in pairs(snap.slide) do
            slide[k] = v
        end
    end
    if floor then
        floor.left = snap.left
    end
end

-- A sudden loss of speed in Unreal's last update: the horizontal speed it moved the character
-- with (speed, cm/s, read back) under LOSS_SHARE of what the mod handed it (w, st.written)
-- and lower by LOSS_MIN u/s or more, where it wasn't a cut of the game's (checkCut: undone with
-- KeepSpeed, a cut line of its own without). Most likely the character ran into something: a
-- wall, a prop, a person, a blocking volume the game doesn't show. Counted, noted in the hop's
-- line, and one line within its budget: from what to what, on the ground or in the air, the
-- heading, how far of its way the move got, Half-Life's duck, and where (at: the location the
-- movement read at this hook). Nothing is read for it.
local function speedLoss(P, w, speed, at, mode, d)
    local written, s = horizontal(w.x, w.y), P.unitScale
    if mode == FALLING and w.mode ~= FALLING and not st.stayBasedInAir then
        -- Walking off a ledge, Unreal adds the velocity of the platform left (see checkCut),
        -- which may be against the run; a long frame may leave from still ground without it.
        written = math.min(written, horizontal(w.x + w.baseX, w.y + w.baseY))
    end
    if not (speed < written * LOSS_SHARE and written - speed >= LOSS_MIN * s) then
        return
    end
    count("speedLosses")
    -- A move that went (nearly) its whole way, the mode unchanged, wasn't stopped by
    -- anything: the game set the velocity itself (stopped the character, or moved it).
    local share, set = "an unknown share", false
    if w.at and at and w.dt and w.dt > 0 then
        local mx, my = (at.X - w.at.X) / w.dt - w.baseX, (at.Y - w.at.Y) / w.dt - w.baseY
        local moved = horizontal(mx, my)
        share = string.format("%.0f %%", moved / written * 100)
        set = w.mode == mode and moved >= written * MOVED_MIN
    end
    if st.hop then
        local key = set and "gameSet" or "hit"
        st.hop[key] = (st.hop[key] or 0) + written - speed
    end
    st.lossLines = st.lossLines + 1
    if st.lossLines > MAX_LOSS_LINES then
        return
    end
    local how = "walking"
    if w.mode == FALLING then
        how = mode == FALLING and "in the air" or "in the air, landing"
    elseif mode == FALLING then
        how = "walking off the ground"
    end
    local ducked = d.state == duck.DUCKED and "ducked" or (d.state == duck.IN_DUCK and "ducking" or "standing")
    log.info("Speed lost: from %.0f to %.0f u/s in one frame (%s, %s, heading %.0f deg; the move got %s of its "
        .. "way; at X=%s Y=%s Z=%s): %s%s", written / s, speed / s, how,
        ducked, math.deg(math.atan(w.y, w.x)), share, at and string.format("%.0f", at.X) or "?",
        at and string.format("%.0f", at.Y) or "?", at and string.format("%.0f", at.Z) or "?",
        set and "the game set the speed itself (nothing cut the move short)"
            or "the character most likely ran into something",
        st.lossLines == MAX_LOSS_LINES and " (further losses aren't logged)" or "")
end

-- The game moving the character with an animation of its own (root motion: ALS's roll on a
-- landing, for one), which the mod leaves to it (see main.lua): on its first frame right
-- after a frame the mod moved the character, what plays (the character's GetCurrentMontage)
-- and the speed the mod had written are noted, and counted; the line comes once the mod has
-- the movement again (rootMotionLine), with the speed then. Nothing is read on other frames.
local function noteRootMotion(pawn, P, dt, frame)
    local r = st.rootMotion
    if r then
        r.frames, r.time = r.frames + 1, r.time + dt
        return
    end
    if st.lastStepFrame ~= frame - 1 then
        return -- (the mod hadn't been moving the character)
    end
    local name = "unknown"
    local ok, montage = ue.call(pawn, "GetCurrentMontage")
    if ok and ue.valid(montage) then
        name = ue.name(montage) or name
    elseif ok then
        name = "no montage"
    end
    count("rootMotions")
    st.rootMotion = { montage = name, before = st.lastSpeed, frames = 1, time = dt, s = P.unitScale }
end

-- The root motion's line, within its budget: after is the horizontal speed (cm/s) as the mod
-- has the movement again, nil if it gave the movement back first.
local function rootMotionLine(after)
    local r = st.rootMotion
    st.rootMotion = nil
    if not r then
        return
    end
    st.rootLines = st.rootLines + 1
    if st.rootLines > MAX_ROOT_LINES then
        return
    end
    local s = r.s
    log.info("Root motion: the game moved the character itself, playing %s, for %d frames (%.2f s): %.0f u/s "
        .. "before it, %s%s", r.montage, r.frames, r.time, (r.before or 0) / s,
        after and string.format("%.0f as the mod had the movement again", after / s)
            or "and the mod gave the movement back before it ended",
        st.rootLines == MAX_ROOT_LINES and " (not logged again)" or "")
end

-- What a duck tap's flight keeps, for its line: the speed before its ground updates (at the
-- landing, or at its press if it came later: before), the speed at the lift, the ground
-- updates, the frames, time and updates in the air, and the keys.
local function newTap(before, lifted, ground, airUpdates)
    return { n = st.taps + 1, before = before, lifted = lifted, ground = ground, time = 0, frames = 0,
        updates = airUpdates, keys = {} }
end

--- One frame of Half-Life movement. yaw is the camera's yaw in degrees; frame is
--- main.lua's frame counter; dt is the time to simulate, frameDt the frame's real
--- length (dt is limited for very long frames, Unreal's movement isn't). owned: the
--- duck, duck tap and jump keys are the mod's on this frame (false while the game shows
--- a dialogue, a cinematic or another view target: they read as up).
function movement.step(pc, pawn, cmc, cfg, P, dt, yaw, frame, frameDt, owned)
    local mode = cmc.MovementMode
    local onGround = mode == WALKING or mode == NAVWALKING
    seenFloor, seenNz, seenGap, walkFloor, leaveFall, runInFloor = nil, nil, false, nil, nil, nil
    local s = P.unitScale

    -- What carries over from the last frame only does so if the mod moved the
    -- character on the frame just before. (Not the duck: st.duck outlives such frames.)
    local afterMove = st.lastStepFrame == frame - 1 and st.written ~= nil
    if st.lastStepFrame ~= frame - 1 then
        st.sim = {}
        st.written = nil
        st.lastMode = nil
        st.hop, st.tap = nil, nil
        st.airBaseX, st.airBaseY = 0, 0
        st.airNext, st.takeoffGap, st.takeoffRest = nil, nil, nil
        st.takeoffLift, st.takeoffDuck, st.hullAir = nil, nil, nil
        st.slide, st.flight = nil, nil
    elseif st.written and st.written.afterMove then
        -- Only if the mod moved the character on the frame before that one too: the
        -- first frame after a pause, or after a frame the mod left alone, may have
        -- been one Unreal ran as paused although the game had just unpaused (if
        -- main.lua couldn't tell), so its movement didn't run and the acceleration
        -- read now is an old one.
        checkInputLeak(cmc)
    end
    st.lastStepFrame = frame

    -- Take this frame's movement input away from the game, so Unreal doesn't
    -- accelerate the character on its own. It is kept as a fallback direction.
    local pending = pawn:ConsumeMovementInputVector()
    local px, py = ue.vector(pending)

    local forward, right, source = input.moveAxes(pc, cfg)
    local wish
    if forward ~= 0 or right ~= 0 then
        wish = { forward = forward, right = right }
        if px == 0 and py == 0 then
            st.emptyInputFrames = st.emptyInputFrames + 1
            if st.emptyInputFrames == 120 then
                log.once("input-order", "Movement keys are held but the game reports no movement input. "
                    .. "If moving feels wrong, please report this with UE4SS.log.")
            end
        else
            st.emptyInputFrames = 0
        end
    elseif px ~= 0 or py ~= 0 then
        -- No known key is held, but the game got movement input (other key
        -- bindings, or a stick the mod doesn't read): use its direction.
        local wx, wy, wishSpeed = physics.wishFromVector(px * P.inputSpeed, py * P.inputSpeed, P.maxSpeed)
        wish = { x = wx, y = wy, speed = wishSpeed }
        source = "game"
        log.first("input-game", "Movement comes from the game's own input, not from reading the keys "
            .. "(vector X=%.2f Y=%.2f)", px, py)
    end
    source = source or "none"
    stats[source] = stats[source] + 1
    stats.frames = stats.frames + 1

    local velocity = cmc.Velocity
    local rx, ry, rz = velocity.X, velocity.Y, velocity.Z
    if st.rootMotion then
        rootMotionLine(horizontal(rx, ry)) -- the game's animation is over: the speed it left
    end
    local okAt, at = ue.call(pawn, "K2_GetActorLocation")
    at = okAt and type(at) == "table" and at or nil

    -- What Unreal made of the last frame's hull request (told to Half-Life's duck), and
    -- where Half-Life's origin is against the capsule's middle where Unreal walks.
    st.duck = st.duck or duck.new(false)
    local d = st.duck
    local crouched = hull.read(pawn, cmc, d, at, mode, st.written, P)
    if onGround and not st.slide then
        duck.groundDrop(d, crouched, hull.delta() or duck.SHIFT * s, s)
    end
    local answer = hull.answer()
    if answer == "stood late" then
        duckLine("stood up late, once Unreal found room")
    elseif answer == "stood" and st.standLine then
        duckLine("%s", st.standLine)
    end
    st.standLine = nil
    -- The duck, duck tap and jump buttons of this frame's Half-Life updates.
    local k = input.buttons(pc, cfg, frame, frameDt or dt, owned, d.wiped)
    st.duckKey = k.duckHeld
    duck.frame(d, { held = k.duckHeld, notch = k.duckNotch, tap = k.tapHeld and not hull.liftOff(), jump = k.jumpHeld,
        jumpNotch = k.jumpNotch, autoHop = cfg.AutoHop })

    local landed = st.lastMode == FALLING and onGround
    if not onGround and st.lastMode and st.lastMode ~= FALLING then
        -- Walked off a ledge in Unreal's last update: leaving a moving platform added
        -- its velocity (not with bStayBasedInAir), as the mod's jump does. (How far above
        -- the floor it stood there wasn't read: the mod reads that at its own take-offs.
        -- A duck tap's lift, a ducked take-off and a hull change in the air belonged to
        -- the flights they started in, and go with them.)
        local w = st.written
        st.airBaseX, st.airBaseY = 0, 0
        st.takeoffGap, st.takeoffRest, st.takeoffLift, st.takeoffDuck, st.hullAir = nil, nil, nil, nil, nil
        if w and not st.stayBasedInAir then
            st.airBaseX, st.airBaseY = w.baseX, w.baseY
        end
    end
    local vx, vy, cut = checkCut(cmc, cfg, P, rx, ry, rz, mode, landed, at)
    st.limiterWoke = false
    -- The frame of ALS's braking a crouch or a stand-up on the ground brought back, given back.
    vx, vy = hull.brakeBack(st.written, vx, vy)
    if st.written and not cut then
        speedLoss(P, st.written, horizontal(vx, vy), at, mode, d)
    end
    local vz = rz
    if not onGround and st.lastMode and st.lastMode ~= FALLING and not st.slide
        and rz <= GAME_JUMP_SHARE * P.jumpSpeed then
        -- Walked off a ledge: Half-Life's update that walked off ended in the air, so the
        -- second half of its gravity stayed on the vertical speed (it is zeroed only on the
        -- ground), where Unreal starts the fall from 0. (Not the game's own jump, nor the
        -- end of a slide, whose rise slopeStep keeps.)
        vz = vz - 0.5 * P.gravity * (P.rate > 0 and 1 / P.rate or (st.written and st.written.dt or dt))
    end

    local landingSpeed
    -- At a landing: where the character stands now, and the velocity of the floor it
    -- landed on (a moving platform's), for the slopes (see slopeLanding).
    local touchdown
    if landed then
        landingSpeed = horizontal(vx, vy)
        if st.tap then
            -- (A duck tap's landing isn't a hop's: the speed lost at landing is about hops.)
            count("tapLandings")
        else
            stats.landings = stats.landings + 1
            stats.landingLoss = stats.landingLoss + math.max(0, st.lastSpeed - horizontal(rx, ry))
        end
        if st.hop and st.hop.frames == 0 then
            -- Unreal landed the jump again within the frame it started in: the floor
            -- rose faster than the jump (a steep slope taken fast). With SlopeBoosts such
            -- a landing starts a slide; without (or on a floor the mod can't use) a held
            -- jump key jumps again on every frame. Not a hop: it was never in the air on
            -- a frame of the mod's, so it has no hop line and isn't in the strafing
            -- numbers. It is counted, for the status line and the report.
            st.hop = nil
            count("groundedJumps")
            log.first("grounded-jump", "A jump landed again within the frame it started in (at %.0f u/s): the floor "
                .. "rises faster than the jump here. Such jumps aren't hops: the status lines and the report count "
                .. "them.", landingSpeed / P.unitScale)
        end
        if st.hop then
            stats.airHops = stats.airHops + 1
            stats.airGain = stats.airGain + (st.lastSpeed - st.hop.takeoff)
            stats.airTurn = stats.airTurn + st.hop.turn
        end
        local leftWith -- (a leap down a slope: see slopeLanding)
        if st.flight then
            flightLine(st.flight, landingSpeed, P)
            leftWith = st.flight.leaveFall
            st.flight = nil
        end
        -- ducked: Half-Life's player came down fully ducked, and so did the capsule.
        touchdown = { at = at, x = 0, y = 0, z = 0, leaveFall = leftWith,
            ducked = crouched and d.state == duck.DUCKED }
        -- Landed on a moving platform: from now on Unreal carries the character with
        -- it, apart from its velocity, but leaves the velocity as it was in the air,
        -- so the platform's motion would count twice (and each hop on the platform
        -- would add its speed again). Take the platform's velocity out, as leaving it
        -- put it in. (With bStayBasedInAir the velocity stayed relative to the platform.)
        if not st.stayBasedInAir then
            local baseX, baseY, baseZ = platformVelocity(cmc)
            if baseX then
                vx, vy = vx - baseX, vy - baseY
                touchdown.x, touchdown.y, touchdown.z = baseX, baseY, baseZ or 0
            end
        end
    end
    -- For the speedometer: the speed Unreal moved the character with on the last
    -- frame, as read back (against a wall, what the wall left of it), with a speed cut
    -- undone and, at a landing, without the platform's velocity. Not the speed the
    -- mod writes below, which has this frame's acceleration in it.
    st.readSpeed = horizontal(vx, vy)

    -- Half-Life's slopes: whether Half-Life has the player on the ground (it is in the
    -- air while Unreal walks it up a slope), and how it leaves the ground off a slope.
    local hlGround, leave, slope, launchLine = onGround, nil, nil, nil
    local slopes = (cfg.SlopeLandings or cfg.SlopeBoosts) and not st.slopeBroken
    if not st.slide then
        st.landRest = nil -- (a landing in this frame sets it; a slide keeps its landing's)
    end
    if slopes then
        hlGround, vx, vy, vz, leave, slope, launchLine = slopeStep(cmc, cfg, P, mode, touchdown, vx, vy, vz, dt, pawn,
            at)
    end
    local launch = leave == "launch"
    if landed then
        if st.hop then
            st.hop.landedDucked = d.state == duck.DUCKED
            hopLine(st.hop, landingSpeed, P, slope)
        end
        st.hop = nil
        if st.tap then
            tapLine(st.tap, landingSpeed, P)
        end
        st.tap = nil
        st.airRefusal = nil
    end
    local slide = st.slide
    if slide then
        if not slide.floorZ and at then
            -- Half-Life's path starts on the floor under the character.
            slide.floorZ, slide.ox, slide.oy = at.Z - (floorGap(cmc) or 0), 0, 0
        end
        holdGameJump(pawn)
    end
    -- On the ground for Half-Life since the character last landed or took over, or since a
    -- duck tap's press on a later frame: the speed then and the updates since, for the tap's line.
    local hookSpeed = horizontal(vx, vy)
    if hlGround and not st.groundRun then
        st.groundRun = { before = hookSpeed, updates = 0 }
    elseif not hlGround then
        st.groundRun = nil
    end

    -- The room the frame's updates have: to stand up on the ground or in the air (where
    -- Unreal would pop a capsule up near a floor, so the floor below is asked first), and
    -- to lift a duck tap.
    local roomBelow
    if d.state == duck.DUCKED and mode == FALLING and not slide and not duck.heldInAir(d) then
        roomBelow = hull.floorRoom(cmc, at)
    end
    local room = hull.room(d, slide ~= nil, roomBelow, mode == NAVWALKING)
    local floor = hlGround and not slide and walkFloor or nil
    local dk = { d = d, room = room, runIn = hlGround and not slide and runInFloor or nil, out = st.dkOut }
    local snap = snapshot(slide, floor)
    local updateTime = P.rate > 0 and 1 / P.rate or dt
    local clock = st.duckClock
    local nx, ny, nz, jumped, steps = physics.simulate(st.sim, vx, vy, vz, hlGround, yaw, wish, nil, P, dt, P.rate,
        slide, floor, dk)
    local out = dk.out
    -- A duck tap's lift: the take-off's readings while the character still stands on its
    -- floor, then the lift (a swept move up first: Half-Life's room test). Without room the
    -- frame's updates run again without it, before Unreal has moved anything.
    local liftAt, liftH, liftBase
    if out.lifted then
        local gap = floorGap(cmc)
        if not st.stayBasedInAir then
            liftBase = { platformVelocity(cmc) }
        end
        liftAt, liftH = hull.lift(pawn, cmc, at, gap)
        if not liftAt then
            putBackSnapshot(snap, slide, floor)
            d = st.duck
            dk.d, room.lift = d, false
            nx, ny, nz, jumped, steps = physics.simulate(st.sim, vx, vy, vz, hlGround, yaw, wish, nil, P, dt, P.rate,
                slide, floor, dk)
            out, liftBase = dk.out, nil
        end
    end
    local lifted = out.lifted ~= nil and liftAt ~= nil
    st.duckClock = clock + steps * updateTime
    stats.steps = stats.steps + steps
    if floor and floor.left and floor.left < steps and ue.bool(pawn, "bPressedJump") ~= true then
        -- Running down a slope, one of this frame's updates on the ground left the floor
        -- (see slopeStep): in the air for the rest of them, and from now on. (After the
        -- frame's last update, the next frame's start decides it, as Unreal walks on.)
        launchLine = leaveLine(P, floor.nx, floor.ny, floor.nz, nx, ny, dt)
        hlGround, leave, launch = false, "launch", true
        leaveFall = 0.5 * P.gravity * (P.rate > 0 and 1 / P.rate or dt)
    end
    if out.runIn then
        -- One of this frame's updates on the ground ran into the upward slope fast enough to
        -- slide up it from the next update on (Half-Life's step move): Unreal walks the
        -- character up the slope for the rest of the frame, as for a slide that was on.
        local runIn = out.runIn
        slide = out.slide
        st.slide = slide
        count("slides")
        local onPress = false
        for _, e in ipairs(out.events) do
            if e.k == runIn.k and e.what == "pressed" then
                onPress = true
            end
        end
        if onPress then
            count("runInPresses")
        end
        runInLine(P, slide, runIn, onPress)
        holdGameJump(pawn)
        slide.floorZ = at and at.Z - (floorGap(cmc) or 0) or nil
        hlGround = false
    end
    if slide and slide.ducked then
        -- Ducked while sliding: the ducked hull's lower edge is 18 units higher, off the
        -- slope, and Half-Life's player flies on with the rise the slide had (the gravity of
        -- the update that ducked is Unreal's, in its falling update).
        st.slide = nil
        count("launches")
        local rise = nz
        launchLine = function(speed)
            slideLine("ducked while sliding up the slope: flying off it at %.0f u/s, rising %.0f u/s", speed,
                rise / P.unitScale)
        end
        hlGround, leave, launch = false, "launch", true
    elseif slide then
        if slide.ended then
            -- Over at one of this frame's updates: the rest of them were on the ground.
            slideOver(P, slide.endX, slide.endY, slide.endZ)
            hlGround = true
        else
            slide.vz = nz
            -- How far Half-Life's path is ahead of the character: the updates moved it, and
            -- Unreal walks the character with the velocity they left, for the whole frame.
            slide.ox = slide.ox + slide.dx - nx * (frameDt or dt)
            slide.oy = slide.oy + slide.dy - ny * (frameDt or dt)
            slide.dx, slide.dy = 0, 0
            if frameDt and frameDt > dt then
                local over
                -- (The path starts again from the floor: the updates don't count the rest
                -- of this frame, which Unreal walks, clipped against the floor.)
                slide.h, slide.clipped, slide.floorZ = P.restHeight / (slide.nz or 1), true, nil
                nx, ny, over = slideRest(P, slide, nx, ny, frameDt - dt, dt)
                if over then
                    slideOver(P, nx, ny, slide.vz)
                    hlGround = true
                end
            end
        end
    end
    -- Leaving the ground: the jump, a flight off a slope, or a duck tap's lift.
    local leaving = jumped or launch or lifted
    st.groundSteps = (hlGround and not leaving) and st.groundSteps + steps or 0

    -- The duck's events in this frame's updates: Half-Life's origin against the capsule's
    -- middle (the eye's drop), the lines and counts, and what the hull request needs.
    local groundChange, airChange, airDucked, groundPress = false, false, false, nil
    for _, e in ipairs(out.events) do
        local what, ground = e.what, e.ground
        duck.eventDrop(d, what, ground, s, what == "lift" and liftH or nil)
        local when = clock + e.k * updateTime
        if what == "pressed" then
            st.pressedAt = when
            groundPress = ground and e.k or groundPress
        elseif what == "ducked" or what == "stood" then
            groundChange = ground
            if not ground then
                airChange = true
            end
            if what == "ducked" then
                st.duckedAt = when
                airDucked = airDucked or not ground
                count(ground and "groundDucks" or "airDucks")
                if ground then
                    local since = st.pressedAt and when - st.pressedAt
                    duckLine("ducked on the ground after %s", since and string.format("%.2f s (%d updates)", since,
                        math.floor(since / updateTime + 0.5)) or "a press the mod didn't see")
                elseif k.duckNotch and not k.duckHeld then
                    duckLine("ducked in the air for a wheel notch (the feet 18 units higher)")
                else
                    duckLine("ducked in the air (the feet 18 units higher)")
                end
                if st.hop and not ground and not st.hop.duckedAt then
                    st.hop.duckedAt = st.hop.time
                end
            else
                count(ground and "groundStands" or "airStands")
                if ground then
                    local text = string.format("stood up on the ground after %s", st.duckedAt
                        and string.format("%.1f s ducked", when - st.duckedAt) or "a duck from before")
                    if crouched then
                        st.standLine = text -- (said once Unreal has stood the capsule up: it may find no room)
                    else
                        duckLine("%s", text)
                    end
                else
                    duckLine("stood up in the air")
                end
                if st.hop and not ground and not st.hop.stoodAt then
                    st.hop.stoodAt = st.hop.time
                end
            end
        elseif what == "refused" and not ground and roomBelow == false and not st.airRefusal then
            st.airRefusal = true
            duckLine("can't stand up in the air yet: the floor is closer under the ducked feet than the standing "
                .. "hull needs (Half-Life's 18 units); standing up once there is room or on the ground")
        end
    end

    local bx, by, bz = 0, 0, 0
    if leaving then
        if jumped then
            log.first("jump", "First jump by the mod (speed %.0f cm/s)", horizontal(nx, ny))
        elseif launch then
            log.first("launch", "First flight off a slope by the mod (speed %.0f cm/s)", horizontal(nx, ny))
        end
        -- How far above the floor it stands as it takes off, and where Half-Life's
        -- player rests there (as its landing left it, or 1/32 unit off this floor's
        -- plane if the floor was read in this frame), for the landing (see
        -- slopeLanding): read before the floor is gone. A take-off fully ducked rests on
        -- Valve's ducked floor, which needs the floor's slope (st.takeoffDuck below): read
        -- here if this frame didn't (slow on the ground, the floor isn't read otherwise).
        if slopes and seenNz == nil and onGround and not lifted and d.state == duck.DUCKED and not airDucked then
            floorNormal(cmc)
        end
        st.takeoffGap = slopes and floorGap(cmc) or nil
        st.takeoffRest = st.landRest or (seenNz and P.restHeight / seenNz) or nil
        st.takeoffLift = lifted and duck.SHIFT * s - liftH or nil
        st.hullAir, st.airRefusal = nil, nil
        -- With bStayBasedInAir, Unreal keeps carrying the character with the
        -- platform in the air and adds nothing when it leaves the ground, so the
        -- mod keeps nothing either. (A lift read it before the character moved.)
        local platformX, platformY, platformZ = 0, 0, 0
        if lifted then
            if liftBase then
                platformX, platformY, platformZ = liftBase[1], liftBase[2], liftBase[3]
            end
        elseif not st.stayBasedInAir then
            platformX, platformY, platformZ = platformVelocity(cmc)
        end
        cmc:SetMovementMode(FALLING, 0)
        -- Leaving the ground adds the velocity of a moving platform the character
        -- stood on (while walking, Velocity is relative to it). Keep that, and only
        -- that: the speed limiter, for one, listens to mode changes.
        local after = cmc.Velocity
        local cx, cy, cz = after.X - rx, after.Y - ry, after.Z - rz
        if platformX then
            bx, by, bz = platformX, platformY, platformZ
            local ux, uy, uz = cx - bx, cy - by, cz - bz
            if ux * ux + uy * uy + uz * uz > 25 then
                local changes = noted("jumpChanges")
                if changes <= MAX_NOTE_LINES then
                    log.info("Something in the game changed the velocity by (X=%.0f Y=%.0f Z=%.0f) cm/s when %s", ux,
                        uy, uz, jumped and "the jump started; the mod's jump ignores it"
                            or lifted and "the duck tap lifted the character; the mod ignores it"
                            or "the character flew off a slope; the mod ignores it")
                end
            end
        else
            bx, by, bz = cx, cy, cz -- no platform velocity to read: keep what the jump added
        end
    end
    st.lastMode = leaving and FALLING or mode
    if leaving then
        st.airBaseX, st.airBaseY = bx, by -- none with bStayBasedInAir
    end
    -- Over the ground at a jump (with the platform's velocity) and in the air, as a
    -- landing reads it; relative to the platform on it. With bStayBasedInAir, relative
    -- to it at a jump and in the air too: the platform goes on carrying the character.
    st.lastSpeed = horizontal(nx + bx, ny + by)
    if launchLine then
        -- A flight off a slope the mod started: its line, with its take-off speed as the
        -- landing line after it (flightLine) and the hop lines count it: with the velocity
        -- of the moving platform it left.
        launchLine(st.lastSpeed / P.unitScale)
    end
    -- A duck tap's press on the ground after the frame its run on the ground began on (walking,
    -- standing, a wheel notch by hand): the tap's ground updates count from it, as the ones
    -- before weren't the tap's. (At the landing's own hook, as +ducktap presses, they count
    -- from the landing: a stand-up's update there is the tap's too.)
    local run = st.groundRun
    if groundPress and run and run.updates > 0 then
        run.before, run.updates = hookSpeed, -(groundPress - 1)
    end
    if lifted then
        -- A duck tap: not a hop (no hop line, not in the strafing numbers), a line of its own.
        count("taps")
        st.tap = newTap(run and run.before or st.lastSpeed, st.lastSpeed, (run and run.updates or 0) + out.ground,
            steps - out.lifted + 1)
    elseif st.tap and not onGround then
        local tap = st.tap
        tap.time = tap.time + (frameDt or dt)
        tap.frames = tap.frames + 1
        tap.updates = tap.updates + steps
        for key in keysHeld(forward, right):gmatch(".") do
            tap.keys[key] = true
        end
    end
    if leaving or not hlGround then
        st.groundRun = nil
    elseif st.groundRun then
        st.groundRun.updates = st.groundRun.updates + out.ground
    end
    if jumped then
        -- Half-Life's duck at the take-off: fully ducked as it jumped, or ducked in the air
        -- on one of this frame's later updates.
        st.hop = { n = st.hops + 1, takeoff = st.lastSpeed, time = 0, turn = 0, frames = 0, steps = 0,
            cuts = st.counts.cuts, keys = {}, yaw = yaw, duckedTakeoff = d.state == duck.DUCKED and not airDucked,
            duckedAt = airDucked and 0 or nil }
    elseif st.hop and not onGround then
        local hop = st.hop
        if hop.frames == 0 then
            -- A hop from its first frame in the air on: a jump that Unreal lands again
            -- within its own frame isn't one (see the landing above).
            stats.hops = stats.hops + 1
        end
        hop.time = hop.time + (frameDt or dt) -- (all of a long frame: Unreal moves all of it)
        hop.frames = hop.frames + 1
        hop.steps = hop.steps + steps
        hop.turn = hop.turn + math.abs(physics.turn(hop.yaw, yaw))
        hop.yaw = yaw
        for key in keysHeld(forward, right):gmatch(".") do
            hop.keys[key] = true
        end
        if not hop.top and nz <= 0 then
            -- The top of the hop: the vertical speed the mod writes no longer goes up.
            hop.top = true
            hop.bodyOff = bodyOffset(pawn, frame)
        end
    end
    -- A flight off a slope isn't a hop: it has no hop line and isn't in the strafing stats.
    if leave then
        st.flight = { takeoff = st.lastSpeed, time = 0, leaveFall = leaveFall }
    elseif st.flight and not onGround then
        st.flight.time = st.flight.time + (frameDt or dt)
    end
    if leaving or mode == FALLING then
        trackHeading(frame, nx + bx - st.airBaseX, ny + by - st.airBaseY, dt, frameDt, steps,
            P.rate > 0 and steps > 0 and steps / P.rate or nil)
    end
    if st.lastSpeed > stats.top then
        stats.top = st.lastSpeed
    end
    if hlGround and not leaving and st.lastSpeed > stats.topGround then
        stats.topGround = st.lastSpeed
    end

    -- Add back what Unreal's braking will take this frame (it brakes the character
    -- whenever it gets no movement input, and the mod took that input away). Unreal
    -- brakes the velocity it moves with: after the mod's jump, with the platform's.
    local wx, wy = nx + bx, ny + by
    local ok, decel = ue.call(cmc, "GetMaxBrakingDeceleration")
    if ok and type(decel) == "number" and decel > 0 then
        local speed = horizontal(wx, wy)
        if speed > 1e-3 then
            local scale = (speed + decel * dt) / speed
            wx, wy = wx * scale, wy * scale
        end
    end
    -- While Unreal walks the character (also up a slope Half-Life has it slide up in
    -- the air), its velocity stays horizontal: Unreal follows the floor.
    local writtenZ = (onGround and not leaving) and 0 or nz + bz
    cmc.Velocity = { X = wx, Y = wy, Z = writtenZ }
    -- The velocity of the platform that carries the character in Unreal's update
    -- (none after the mod's jump, unless bStayBasedInAir), read while it still
    -- stands on it: that update starts by moving it along with the platform, and
    -- adds the platform's velocity if it walks off.
    local baseX, baseY, baseZ = 0, 0, 0
    if (onGround and not leaving) or st.stayBasedInAir then
        baseX, baseY, baseZ = platformVelocity(cmc)
    end
    -- How long the character has been in the air at this hook, for its landing (see
    -- landingKind): Half-Life's updates of a hop count from its take-off. A flight that
    -- the mod first sees now began in Unreal's last update. The game's own jump started
    -- at the hook before, so it counts from there. Walking off a ledge, Unreal walked
    -- that whole frame along the floor and the fall starts here, as Half-Life's starts
    -- at the end of the update that left the ground (with the second half of that
    -- update's gravity on it, see above): it counts from now. Unreal doesn't
    -- move a paused frame, so a pause in the middle of a hop doesn't count (st.airNext
    -- stays through movement.hold).
    local was, air = st.written, nil
    if leaving then
        air = 0
    elseif mode == FALLING then
        air = st.airNext
        if not air then
            air = (rz > GAME_JUMP_SHARE * P.jumpSpeed and was and was.dt) or 0
        end
    end
    st.airNext = air and air + (frameDt or dt)
    if airChange and air then
        -- The hull changed in the air in this frame: a landing doesn't look back past this
        -- hook for an update that ended within reach (they had the other hull's feet).
        st.hullAir = air
    end

    -- Last, after every SetMovementMode of the frame (ALS clears the crouch wish inside
    -- it): the crouch Unreal is to make of Half-Life's duck in its next update.
    hull.request(pawn, cmc, { state = d.state, button = out.held, falling = mode == FALLING or leaving,
        navWalking = mode == NAVWALKING and not leaving, sliding = st.slide ~= nil, roomBelow = roomBelow,
        groundChange = groundChange, leaving = leaving, duckKey = k.duckHeld, dt = frameDt or dt })
    if leaving then
        -- A ducked take-off rests on Valve's ducked floor, duck.restGap below the standing
        -- one, where the crouched capsule rests 18 units lower (see slopeLanding).
        local ducked = not lifted and d.state == duck.DUCKED and not airDucked and (crouched or hull.aheadBase())
        st.takeoffDuck = ducked and (duck.SHIFT - duck.restGap(seenNz)) * s or nil
    end
    -- What the camera gets: Half-Life's eye against the standing eye, and for the game's
    -- camera, ahead of a crouch Unreal makes keeping the feet (see movement.eyeInfo).
    st.eye = { offset = duck.eyeOffset(d, s, crouched, false), crouched = crouched, standHalf = hull.standHalf(),
        aheadOffset = hull.aheadBase() and duck.eyeOffset(d, s, crouched, true) or nil }
    -- For the view's smoothing of rises on the ground, after Unreal's movement (camera.lateEye):
    -- Half-Life's player on the ground after the frame's updates, its view height against the
    -- standing one and its origin's drop below the capsule's middle (cm), the hull difference
    -- Unreal's crouch moves the middle by, where the middle was at this hook (hookZ: where the
    -- smoothing starts from after a frame without it), and stillZ, the same, if Unreal can't
    -- have moved the character (no speed written, no platform rising or sinking).
    if hlGround and not leaving and not st.slide then
        st.eye.ground, st.eye.view, st.eye.drop = true, (d.view - duck.VIEW_STAND) * s, d.drop
        st.eye.delta = hull.delta() or duck.SHIFT * s
        st.eye.hookX, st.eye.hookY, st.eye.hookZ = at and at.X, at and at.Y, at and at.Z
        if at and horizontal(wx, wy) < 1 and math.abs(baseZ or 0) < 1 then
            st.eye.stillZ = at.Z
        end
    end
    st.eyeFrame = frame

    -- What the game should hand back next frame, once its braking took the extra,
    -- and where the character was before this frame's move (after a duck tap's lift,
    -- where the lift put it). long: a frame longer than the Half-Life updates count;
    -- prevDt: the length of the frame before this one; hullAir: see landingKind.
    st.written = { x = nx + bx, y = ny + by, z = writtenZ, mode = leaving and FALLING or mode, jumped = jumped,
        launched = launch, lifted = lifted, at = lifted and liftAt or at, dt = frameDt or dt, baseX = baseX or 0,
        baseY = baseY or 0, baseZ = baseZ or 0, afterMove = afterMove, air = air, prevDt = was and was.dt,
        long = frameDt ~= nil and frameDt > dt, hullAir = st.hullAir }
end

--- A frame Unreal runs as paused (see main.lua's isPaused). Unreal doesn't move the
--- character then, so a landing the mod hasn't handled yet is handled after the
--- pause, and a hop goes on. What the mod wrote before isn't checked after the pause
--- (no speed cut, no input leak): if main.lua can't tell such frames, it goes by
--- IsGamePaused, and on the frame the game pauses from the controller's own input
--- the character's update still runs once, with the game's input.
function movement.hold(frame)
    if st.lastStepFrame == frame - 1 then
        st.lastStepFrame = frame
        st.written = nil
    end
    -- The duck stays as it is (its timer doesn't run), and so does the eye.
    if st.eye then
        st.eyeFrame = frame
    end
end

--- A frame of root motion, which the mod leaves to the game: the hull keeps Half-Life's
--- duck as it is (the crouch the mod holds is asked for again, a game's crouch read),
--- with no Half-Life update. P: the movement's numbers (P.gravity, P.unitScale); dt: the
--- frame's length.
function movement.keepHull(pawn, cmc, P, dt, frame)
    if st.active then
        noteRootMotion(pawn, P, dt, frame)
    end
    local d = st.duck
    if not st.active or not d then
        return
    end
    local mode = ue.number(cmc, "MovementMode")
    local crouched = hull.read(pawn, cmc, d, nil, mode, nil, P)
    hull.request(pawn, cmc, { state = d.state, button = d.held, falling = mode == FALLING,
        navWalking = mode == NAVWALKING, sliding = st.slide ~= nil, groundChange = false, leaving = false,
        duckKey = st.duckKey, dt = dt })
    if st.eye then
        st.eye.crouched = crouched
        st.eye.offset = duck.eyeOffset(d, P.unitScale, crouched, false)
        st.eye.aheadOffset = nil
        st.eye.ground, st.eye.stillZ = nil, nil -- (the game moves the character: no smoothing)
        st.eyeFrame = frame
    end
end

--- What the camera needs of Half-Life's duck for the eye (camera.applyEye), while the
--- movement steers the character (a pause and root motion keep the last): { offset (cm to
--- add to the standing eye), aheadOffset (the same for the game's camera, on a frame Unreal
--- crouches the standing capsule keeping its feet; else nil), crouched (bIsCrouched at this
--- hook), standHalf (the standing capsule's half height, cm, scaled; nil until known) }, or
--- nil: then the camera follows the game's hull.
function movement.eyeInfo(frame)
    if st.active and st.eye and st.eyeFrame == frame then
        return st.eye
    end
    return nil
end

--- Where the character heads in the air in this frame, for the body to face: the
--- yaw in degrees for it to turn towards (where it heads, led by how fast that turns),
--- and the yaw where it heads (that of the horizontal velocity the mod handed to
--- Unreal, apart from a moving platform it left). While that is slower than
--- HEADING_SPEED: on the first such frame after one with a heading, both are that
--- last heading, for the body to settle on instead of the led target; after that,
--- false and false. nil unless the mod moved the character in this frame and it is
--- in the air after the mod's update (its jump included).
function movement.heading(frame)
    if st.headingFrame == frame then
        return st.headingTarget, st.headingYaw or st.headingTarget
    end
    return nil
end

--- Has the game's locomotion system (ALS) turn the character towards yaw while it
--- is in the air: in the character's update, after Unreal's movement, ALS turns it a
--- little towards its InAirRotation on each frame in the air, and sets that to the
--- character's own rotation whenever it leaves the ground (the mod's jump included),
--- so this runs after the mod's jump. heading (where the character heads, not led)
--- goes into TargetRotation: ALS's update in the air replaces that with InAirRotation,
--- but the update of a landing frame starts from it. Without heading (first person,
--- where camera.faceView sets TargetRotation to the view), only InAirRotation is set.
--- Nothing to put back: ALS sets InAirRotation again at every take-off.
function movement.faceHeading(pawn, yaw, heading)
    if st.inAirRotation == nil then
        st.inAirRotation = ue.typeOf(ue.get(pawn, "InAirRotation")) == "UScriptStruct"
        if not st.inAirRotation then
            log.once("in-air-rotation", "The character has no InAirRotation (ALS), so in third person it keeps "
                .. "facing the way it took off while it hops.")
        end
    end
    if not st.inAirRotation then
        return
    end
    if heading then
        log.first("in-air-heading", "Turning the character towards where it heads in the air (ALS's InAirRotation, "
            .. "yaw %.0f)", yaw)
    else
        log.first("in-air-view", "Keeping the character turned to the view in the air too (ALS's InAirRotation, "
            .. "yaw %.0f)", yaw)
    end
    pawn.InAirRotation = { Pitch = 0, Yaw = yaw, Roll = 0 }
    if heading then
        pawn.TargetRotation = { Pitch = 0, Yaw = heading, Roll = 0 }
        st.facedFrame = st.headingFrame
    end
end

--- Gives the movement back to the game and puts back everything the mod changed.
function movement.release()
    if not st.active then
        return
    end
    overrides:restore()
    putCurveBack()
    resumeLimiter()
    rootMotionLine(nil) -- (an animation of the game's still playing: the mod gives the movement back first)
    hull.release()
    st.active = false
    st.cmc = nil
    st.cmcName = nil
    st.written = nil
    st.hop, st.tap = nil, nil
    st.slide, st.flight = nil, nil
    st.duck, st.eye, st.groundRun = nil, nil, nil
    seenFloor, seenNz, seenGap = nil, nil, false
    log.debug("Movement given back to the game")
end

--- Forgets everything without touching the game: for a new level, whose loading
--- destroyed the objects the mod had changed.
function movement.forget()
    overrides:forget()
    journal.forget("curve", st.cmcName, "")
    if st.limiter then
        journal.forget("tick", st.limiter.fullName, "")
    end
    st.limiter = nil
    st.curve = nil
    st.curveName = nil
    hull.forget()
    st.active = false
    st.rootMotion = nil
    st.cmc = nil
    st.cmcName = nil
    st.written = nil
    st.hop, st.tap = nil, nil
    st.slide, st.flight = nil, nil
    st.duck, st.eye, st.groundRun = nil, nil, nil
    seenFloor, seenNz, seenGap = nil, nil, false
end

--- Starts the counts of this file's lines again (hops, duck taps, ducks, landings on
--- slopes of both kinds, slides and flights, and what the game did: speed cuts, its
--- limiter, MaxWalkSpeed, a changed jump, and the hull's), so that what comes next is
--- logged like a session's first: for the reload key, which a test presses before each
--- part it wants in the log.
function movement.logAgain()
    st.hopLines, st.slideLines, st.landingLines, st.keptLines = 0, 0, 0, 0
    st.tapLines, st.duckLines, st.lossLines, st.rootLines = 0, 0, 0, 0
    st.noteLines = {}
    hull.logAgain()
end

--- What happened since the last call: frames moved, where the input came from,
--- hops, top speeds, per jump the speed gained in the air and how far the view
--- turned meanwhile, the speed lost at landing, Half-Life updates run, what the game
--- did to the speed, and the duck's taps, ducks and stand-ups (with the hull's counts
--- since then: hull.takeStats). Speeds in cm/s.
function movement.takeStats()
    local result = stats
    stats = newStats()
    result.hull = hull.takeStats()
    return result
end

--- Half-Life's duck as the movement has it, and its counts since the mod loaded, for the
--- report.
function movement.duckStatus()
    local d = st.duck
    return {
        state = d and d.state, timer = d and d.timer, view = d and d.view, drop = d and d.drop,
        held = d and d.held, wiped = d and d.wiped, notch = d and d.notch, tapHad = d and d.tapHad,
        jumpWas = d and d.jumpWas, taps = st.counts.taps, tapLandings = st.counts.tapLandings,
        groundDucks = st.counts.groundDucks, airDucks = st.counts.airDucks, groundStands = st.counts.groundStands,
        airStands = st.counts.airStands, runInPresses = st.counts.runInPresses,
        tapLinesLeft = math.max(0, MAX_TAP_LINES - st.tapLines), duckLinesLeft = math.max(0, MAX_DUCK_LINES -
            st.duckLines),
    }
end

--- The game's own value of a property the movement changed (the one put back at the release),
--- or nil if it hasn't changed it: for the report.
function movement.gameValue(obj, name)
    return overrides:saved(obj, name)
end

--- What the movement side is doing, for the diagnostics report.
function movement.status()
    local limiter = "not looked for"
    if st.limiter == false then
        limiter = "none found"
    elseif st.limiter then
        limiter = string.format("paused (%s, the game started it again %d times)", ue.describe(st.limiter.obj),
            st.counts.wakes)
    end
    return {
        active = st.active,
        worldGravity = st.worldGravity,
        curveTaken = st.curve ~= nil,
        curveBroken = st.curveBroken,
        limiter = limiter,
        maxSpeed = st.maxSpeed,
        stayBasedInAir = st.stayBasedInAir,
        slopeBroken = st.slopeBroken,
        floors = st.floors,
        slopeGained = st.slopeGained,
        slopeLost = st.slopeLost,
        sliding = st.slide ~= nil,
        gameMaxWalkSpeed = st.cmc and overrides:saved(st.cmc, "MaxWalkSpeed"),
        gameMaxWalkSpeedCrouched = st.cmc and overrides:saved(st.cmc, "MaxWalkSpeedCrouched"),
        counts = st.counts,
        hops = st.hops,
        hopLinesLeft = math.max(0, MAX_HOP_LINES - st.hopLines),
        lossLinesLeft = math.max(0, MAX_LOSS_LINES - st.lossLines),
        rootLinesLeft = math.max(0, MAX_ROOT_LINES - st.rootLines),
        rootMotion = st.rootMotion and st.rootMotion.montage,
    }
end

return movement
