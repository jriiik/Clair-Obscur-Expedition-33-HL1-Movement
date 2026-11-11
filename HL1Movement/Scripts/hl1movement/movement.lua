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
-- on a slope turns part of the fall into speed along it, and a player rising faster
-- than 180 u/s is in the air, so running or landing fast against an upward slope
-- slides up it without friction and flies off the top.
--
-- When the mod hands the movement back, every value goes back to the last one the
-- game set (see overrides.lua), including the walking speed. The mod doesn't ask
-- ALS to work out its walking speed again: that would lose a speed the game set
-- for the area. (ALS's request flag is also a uint8, which UE4SS sets to 0 when
-- given a Lua true.)

local physics = require("hl1movement.physics")
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
local MAX_CUT_LINES = 5
local MAX_NOTE_LINES = 3 -- for each other kind of thing the game did
local MAX_HOP_LINES = 20
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
-- Slopes (SlopeLandings, SlopeBoosts). Floors flatter than 1 degree count as flat. The
-- floor's normal is only used when the capsule's contact normal agrees with the
-- surface's within 8 degrees: on a step's edge they differ, and the edge isn't a slope.
local FLAT_NZ = math.cos(math.rad(1))
local CONTACT_AGREES = math.cos(math.rad(8))
local MAX_UNREADABLE_FLOORS = 30 -- reads in a row of a floor whose normal can't be read
local MAX_SLIDE_LINES = 10 -- slides up a slope and flights off one
-- Landings on a slope are logged only on one of LOGGED_SLOPE degrees or more, or if
-- the speed changed by LOGGED_CHANGE u/s or more: most ground is a little uneven.
local MAX_LANDING_LINES = 5
local LOGGED_SLOPE = 3
local LOGGED_CHANGE = 10
-- After a slide, rising faster than this share of the jump speed is the game's own jump.
local GAME_JUMP_SHARE = 0.5
local DEFAULT_MAX_STEP = 0.05 -- s, Unreal's MaxSimulationTimeStep if it can't be read

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
    jump = { latched = false },
    sim = {}, -- physics.simulate's state
    lastStepFrame = nil,
    written = nil, -- the horizontal velocity the mod left for the game last frame, and the platform's
    lastMode = nil,
    lastSpeed = 0,
    emptyInputFrames = 0,
    hop = nil, -- the jump in progress, for the hop lines
    hops = 0,
    maxSpeed = nil, -- what GetMaxSpeed() said after the mod set MaxWalkSpeed
    gameWalkSpeed = nil, -- the MaxWalkSpeed the game wrote since the last frame, if it did
    stayBasedInAir = false, -- the movement component's bStayBasedInAir
    airBaseX = 0, -- the moving platform's velocity that leaving it added, while in the air
    airBaseY = 0,
    headingFrame = nil, -- the frame of headingYaw (see movement.heading)
    headingYaw = false, -- where the character heads in the air, in degrees (false: too slow)
    headingTarget = false, -- headingYaw, led by its turn rate: what the body turns towards
    headingRate = nil, -- that turn rate in degrees per second
    headingRef = false, -- the heading after the last Half-Life update, and the time since
    headingTime = 0,
    facedFrame = nil, -- the last frame movement.faceHeading turned the body to where it heads
    inAirRotation = nil, -- whether the character has ALS's InAirRotation (nil: not looked yet)
    slide = nil, -- { vz = cm/s }: sliding up a slope, in the air for Half-Life while Unreal walks
    flight = nil, -- { takeoff, time }: in the air after flying off a slope (not a hop)
    slopeBroken = false, -- the floor's normal can't be read: slopes are left to Unreal
    unreadableFloors = 0,
    slideLines = 0,
    landingLines = 0,
    maxStep = DEFAULT_MAX_STEP, -- the movement component's MaxSimulationTimeStep
    counts = { cuts = 0, restores = 0, rewrites = 0, wakes = 0, leaks = 0, jumpChanges = 0, slopeLandings = 0,
        slides = 0, launches = 0, stoppedJumps = 0 },
}

-- What happened since the last status line (see movement.takeStats).
local function newStats()
    return { frames = 0, keys = 0, stick = 0, game = 0, none = 0, hops = 0, landings = 0, top = 0, topGround = 0,
        airHops = 0, airGain = 0, airTurn = 0, landingLoss = 0, steps = 0, cuts = 0, restores = 0, rewrites = 0,
        wakes = 0, leaks = 0, slopeLandings = 0, slopeGain = 0, slides = 0, launches = 0 }
end
local stats = newStats()

local function count(name)
    st.counts[name] = st.counts[name] + 1
    if stats[name] then
        stats[name] = stats[name] + 1
    end
    return st.counts[name]
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
        local wakes = count("wakes")
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
    overrides:set(cmc, "MaxWalkSpeedCrouched", SPEED_LIMIT, true)
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

--- Takes over the character's movement, or keeps it taken over. Called every frame
--- while the mod's movement should run. Returns true if it took over in this call
--- (its refreshes start then, see movement.stagger).
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
        st.jump.latched = false
        st.lastMode = nil
        st.emptyInputFrames = 0
        st.sim = {}
        st.lastStepFrame = nil
        st.written = nil
        st.hop = nil
        st.airBaseX, st.airBaseY = 0, 0
        st.headingFrame, st.facedFrame = nil, nil
        st.inAirRotation = nil
        st.slide, st.flight = nil, nil
        st.unreadableFloors = 0
        local maxStep = ue.number(cmc, "MaxSimulationTimeStep")
        st.maxStep = maxStep and maxStep > 0 and maxStep or DEFAULT_MAX_STEP
        if not st.worldGravity then
            log.once("gravity", "Could not read the game's gravity, so the game's own gravity stays.")
        end
        log.first("movement", "Taking over the movement of %s (mode %s, world gravity %s cm/s2)",
            tostring(ue.className(pawn)), tostring(ue.number(cmc, "MovementMode")), tostring(st.worldGravity))
        log.debug("Movement taken over")
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
    -- ALS sets the walking speed itself whenever the gait changes, and the game
    -- sets it for some areas, so this is set every frame. The high value stops the
    -- game from capping your speed.
    st.gameWalkSpeed = nil
    if overrides:set(cmc, "MaxWalkSpeed", SPEED_LIMIT, refresh) then
        -- What the game wrote since the last frame: its speed cap may have cut the
        -- speed to it meanwhile (see atMaxSpeed).
        st.gameWalkSpeed = overrides:saved(cmc, "MaxWalkSpeed")
        local rewrites = count("rewrites")
        if rewrites <= MAX_NOTE_LINES then
            log.info("The game set MaxWalkSpeed to %s; the mod sets it back to %d%s",
                tostring(overrides:saved(cmc, "MaxWalkSpeed")), SPEED_LIMIT,
                rewrites == MAX_NOTE_LINES and " (not logged again)" or "")
        end
    end
    takeCurve(cmc)
    if refresh then
        applyValues(pawn, cmc, P)
        if first then
            checkMaxSpeed(cmc)
        end
    end
    if cfg.DisableSpeedLimiter then
        guard.run("pausing the speed limiter", pauseLimiter, pawn, cmc, refresh)
    end
    return first
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
-- or at a walking speed the game wrote since the last frame (the mod has already
-- set MaxWalkSpeed back this frame, so GetMaxSpeed() may no longer say it).
local function atMaxSpeed(cmc, vx, vy, vz)
    local speed, flat = math.sqrt(vx * vx + vy * vy + vz * vz), horizontal(vx, vy)
    local function at(cap)
        return type(cap) == "number" and cap > 0
            and (math.abs(speed - cap) <= cap * 0.01 or math.abs(flat - cap) <= cap * 0.01)
    end
    if at(st.gameWalkSpeed) then
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
-- the speed. Logged, and undone with KeepSpeed. Returns the velocity to start from.
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
    local cuts = count("cuts")
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
        return vx, vy
    end
    count("restores")
    local scale = written / speed
    return vx * scale, vy * scale
end

-- The floor Unreal's walking found under the character (the movement component's
-- CurrentFloor, updated while it walks): the unit normal of its surface, or (0, 0, 1)
-- for a flat one. nil when there is no floor the mod can use: none, one found by a
-- line trace, or a step's edge (where the capsule's contact normal leans while the
-- surface's doesn't). Returns false as the 4th value if the floor can't be read
-- (every character movement component has one). Field by field: in UE4SS, reading a
-- field a struct doesn't have raises an error.
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
    local hit = ue.get(floor, "HitResult")
    local surface = ue.get(hit, "ImpactNormal")
    local nz = ue.number(surface, "Z")
    if not nz then
        return nil, nil, nil, false
    end
    if nz >= FLAT_NZ then
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
        return nil
    end
    return nx, ny, nz
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

local function landingLine(fmt, ...)
    st.landingLines = st.landingLines + 1
    if st.landingLines <= MAX_LANDING_LINES then
        log.info("Slope: %s%s", string.format(fmt, ...),
            st.landingLines == MAX_LANDING_LINES and " (further landings on slopes aren't logged)" or "")
    end
end

local function degrees(nz)
    return math.deg(math.acos(math.max(-1, math.min(1, nz))))
end

-- "falling 158 u/s" or "rising 40 u/s", for a vertical speed in cm/s.
local function vertical(vz, P)
    return string.format(vz < 0 and "falling %.0f u/s" or "rising %.0f u/s", math.abs(vz) / P.unitScale)
end

-- A landing on a slope (see slopeStep), with (nx, ny, nz) the floor's normal and
-- (vx, vy) the horizontal velocity, relative to a moving platform it landed on.
local function slopeLanding(cfg, P, nx, ny, nz, vx, vy)
    local w = st.written
    -- Unreal's landing stands with no usable floor or a flat one; with nothing written
    -- in the air on the frame before (after a pause, for one); and after a frame longer
    -- than Unreal's MaxSimulationTimeStep, which Unreal moves in several steps and
    -- lands in one of them: how fast the character fell then can't be told.
    if not nx or nz >= 1 or not w or w.dt > st.maxStep then
        return true, vx, vy, 0
    end
    -- The velocity it hit the floor with: what the mod wrote, plus Unreal's gravity in
    -- the frame (it landed somewhere in it).
    local fall = w.z - P.gravity * w.dt
    local before = horizontal(vx, vy)
    local cx, cy, cz = physics.clip(vx, vy, fall, nx, ny, nz)
    local after = horizontal(cx, cy)
    local u = P.unitScale
    if cz > P.airborneSpeed and cfg.SlopeBoosts then
        st.slide = { vz = cz }
        count("slides")
        count("slopeLandings")
        stats.slopeGain = stats.slopeGain + (after - before)
        slideLine("landed on a %.0f degree slope at %.0f u/s, %s: sliding up it at %.0f u/s, rising %.0f u/s "
            .. "(Half-Life keeps you in the air above 180)", degrees(nz), before / u, vertical(fall, P), after / u,
            cz / u)
        return false, cx, cy, cz, nil, after - before
    end
    if not cfg.SlopeLandings then
        return true, vx, vy, 0
    end
    count("slopeLandings")
    stats.slopeGain = stats.slopeGain + (after - before)
    if degrees(nz) >= LOGGED_SLOPE or math.abs(after - before) >= LOGGED_CHANGE * u then
        landingLine("landed on a %.0f degree slope at %.0f u/s, %s: %.0f u/s (%+.0f)", degrees(nz), before / u,
            vertical(fall, P), after / u, (after - before) / u)
    end
    return true, cx, cy, 0, nil, after - before
end

-- Half-Life's slopes, on the velocity this frame starts from (relative to a moving
-- platform the character stands on; vz is Unreal's vertical speed). Unreal walks a
-- character along any walkable floor keeping its horizontal speed, and lands it
-- keeping its horizontal speed. Half-Life clips the velocity against a surface it runs
-- into (overbounce 1): at a landing (SlopeLandings), and on the ground running into an
-- upward slope. A player rising faster than 180 u/s is in the air even on a slope
-- (SlopeBoosts): it slides up the slope without friction and flies off where the slope
-- falls away. While it slides, Unreal still walks the character along the slope (so
-- the game doesn't land it again every frame); the mod keeps the vertical speed
-- Half-Life would have. jumpReady: a jump would start now if on the ground; Half-Life
-- jumps before its ground move, so it runs up a slope only without one.
-- Returns whether Half-Life has the player on the ground; the velocity; how it leaves
-- the ground off a slope ("launch": the mod has it leave now; "off the end": Unreal
-- walked it off the end of the slope); and, at a landing on a slope, how much the
-- horizontal speed changed (cm/s).
local function slopeStep(cmc, cfg, P, mode, landed, vx, vy, vz, dt, jumpReady)
    local slide = st.slide
    local u = P.unitScale
    if mode == FALLING then
        st.slide = nil
        if not slide then
            return false, vx, vy, vz
        end
        local up = slide.vz - P.gravity * dt
        if vz > GAME_JUMP_SHARE * P.jumpSpeed then
            -- The game's own jump, which Unreal does whenever it walks the character and
            -- the mod couldn't hold back (see holdGameJump): the higher rise stays.
            up = math.max(vz, up)
            slideLine("the game jumped while sliding up the slope, at %.0f u/s, rising %.0f u/s",
                horizontal(vx, vy) / u, up / u)
            return false, vx, vy, up
        end
        -- Unreal walked the character off the end of the slope: it flies on, rising as
        -- it slid.
        count("launches")
        slideLine("off the end of the slope at %.0f u/s, rising %.0f u/s", horizontal(vx, vy) / u, up / u)
        return false, vx, vy, up, "off the end"
    end
    local fast = vx * vx + vy * vy > (2 * P.airborneSpeed) ^ 2 -- slower can't slide up a walkable slope
    if mode ~= WALKING or not (landed or slide or (fast and cfg.SlopeBoosts)) then
        st.slide = nil
        return true, vx, vy, 0
    end
    local nx, ny, nz, readable = floorNormal(cmc)
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
        return slopeLanding(cfg, P, nx, ny, nz, vx, vy)
    end
    if slide then
        local up = slide.vz - P.gravity * dt
        if nx then
            -- Half-Life's player only touches the floor while its velocity goes into it.
            -- Where the floor falls away (the top of the slope, or a steeper part going
            -- down), it flies off if it would rise more than leaveHeight above the floor.
            local away = vx * nx + vy * ny + up * nz
            if away > 0 and away * away > 2 * P.gravity * nz * P.leaveHeight then
                st.slide = nil
                count("launches")
                slideLine("flew off the slope at %.0f u/s, rising %.0f u/s", horizontal(vx, vy) / u, up / u)
                return false, vx, vy, up, "launch"
            end
            vx, vy, up = physics.clip(vx, vy, up, nx, ny, nz)
        end
        if up <= P.airborneSpeed then
            st.slide = nil
            slideLine("the slide up the slope ended at %.0f u/s (rising %.0f u/s, not more than 180)",
                horizontal(vx, vy) / u, up / u)
            return true, vx, vy, 0
        end
        slide.vz = up
        return false, vx, vy, up
    end
    if nx and nz < 1 and not jumpReady then
        -- Running into an upward slope, Half-Life's ground move clips the velocity
        -- against it and keeps its vertical part: rising faster than 180 u/s, the
        -- player is in the air on the next update.
        local _, _, up = physics.clip(vx, vy, 0, nx, ny, nz)
        if up > P.airborneSpeed then
            st.slide = { vz = up }
            count("slides")
            slideLine("ran into a %.0f degree slope at %.0f u/s: sliding up it, rising %.0f u/s (Half-Life keeps "
                .. "you in the air above 180)", degrees(nz), horizontal(vx, vy) / u, up / u)
            return false, vx, vy, up
        end
    end
    return true, vx, vy, 0
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

-- slope: how much a landing on a slope changed the horizontal speed (cm/s), if it did.
local function hopLine(hop, landing, P, slope)
    st.hops = st.hops + 1
    if st.hops > MAX_HOP_LINES then
        return
    end
    local u = P.unitScale
    local time = math.max(hop.time, 1e-6)
    local gain = (landing - hop.takeoff) / u
    if math.abs(gain) <= 0.5 then
        gain = 0 -- not "-0"
    end
    local onSlope = ""
    if slope then
        local change = slope / u
        onSlope = string.format(", slope %+.0f%s", math.abs(change) <= 0.5 and 0 or change,
            st.slide and " (sliding up it)" or "")
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
    log.info("Hop %d (%.0f fps, %.1f updates per frame): take-off %.0f u/s, landing %.0f u/s (%+.0f)%s, %.2f s in "
        .. "the air, view turned %.0f deg (%.0f deg/s), keys %s, speed cuts %d%s%s", hop.n, hop.frames / time,
        hop.steps / math.max(hop.frames, 1), hop.takeoff / u, landing / u, gain, onSlope, hop.time,
        hop.turn, hop.turn / time, #keys > 0 and table.concat(keys) or "none", st.counts.cuts - hop.cuts, body,
        st.hops == MAX_HOP_LINES and " (further hops aren't logged)" or "")
end

-- Where the character heads in the air (see movement.heading): the yaw of hx, hy,
-- the horizontal velocity the mod hands to Unreal apart from the moving platform's
-- that leaving it added, so that hopping in place on a moving platform doesn't turn
-- the body to the platform's way. The body's target is led by how fast the heading
-- turns. The heading only changes in Half-Life updates, so that rate is measured over
-- the time since the last frame that ran one, and a frame that runs none keeps the
-- last rate (above PhysicsRate frames per second, a rate from one frame alone read 0
-- in such a frame and far too much in the next). It starts again whenever the run of
-- air frames breaks.
local function trackHeading(frame, hx, hy, dt, frameDt, steps)
    local going = st.headingFrame == frame - 1 and st.headingYaw ~= false
    local heading, target = false, false
    if hx * hx + hy * hy > HEADING_SPEED * HEADING_SPEED then
        heading = math.deg(math.atan(hy, hx))
        target = heading
        if going and dt > 0 then
            st.headingTime = st.headingTime + dt
            if steps > 0 then
                st.headingRate = physics.turn(st.headingRef, heading) / st.headingTime
                st.headingRef, st.headingTime = heading, 0
            end
            local lead = (st.headingRate or 0) * math.max(0, 1 / ALS_AIR_TURN - (frameDt or dt))
            target = heading + math.max(-LEAD_LIMIT, math.min(LEAD_LIMIT, lead))
        end
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
    if st.hops >= MAX_HOP_LINES or st.facedFrame ~= frame - 1 or type(st.headingYaw) ~= "number" then
        return nil
    end
    local ok, rotation = ue.call(pawn, "K2_GetActorRotation")
    local yaw = ok and ue.number(rotation, "Yaw")
    if not yaw then
        return nil
    end
    return physics.turn(st.headingYaw, yaw)
end

--- One frame of Half-Life movement. yaw is the camera's yaw in degrees; frame is
--- main.lua's frame counter; dt is the time to simulate, frameDt the frame's real
--- length (dt is limited for very long frames, Unreal's movement isn't).
function movement.step(pc, pawn, cmc, cfg, P, dt, yaw, frame, frameDt)
    local mode = cmc.MovementMode
    local onGround = mode == WALKING or mode == NAVWALKING

    -- What carries over from the last frame only does so if the mod moved the
    -- character on the frame just before.
    local afterMove = st.lastStepFrame == frame - 1 and st.written ~= nil
    if st.lastStepFrame ~= frame - 1 then
        st.sim = {}
        st.written = nil
        st.lastMode = nil
        st.hop = nil
        st.airBaseX, st.airBaseY = 0, 0
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

    local jumpHeld = input.jumpHeld(pc, cfg, frame)

    local velocity = cmc.Velocity
    local rx, ry, rz = velocity.X, velocity.Y, velocity.Z
    local okAt, at = ue.call(pawn, "K2_GetActorLocation")
    at = okAt and type(at) == "table" and at or nil
    local landed = st.lastMode == FALLING and onGround
    if not onGround and st.lastMode and st.lastMode ~= FALLING then
        -- Walked off a ledge in Unreal's last update: leaving a moving platform added
        -- its velocity (not with bStayBasedInAir), as the mod's jump does.
        local w = st.written
        st.airBaseX, st.airBaseY = 0, 0
        if w and not st.stayBasedInAir then
            st.airBaseX, st.airBaseY = w.baseX, w.baseY
        end
    end
    local vx, vy = checkCut(cmc, cfg, P, rx, ry, rz, mode, landed, at)
    st.limiterWoke = false
    local vz = rz

    local landingSpeed
    if landed then
        landingSpeed = horizontal(vx, vy)
        stats.landings = stats.landings + 1
        stats.landingLoss = stats.landingLoss + math.max(0, st.lastSpeed - horizontal(rx, ry))
        if st.hop then
            stats.airHops = stats.airHops + 1
            stats.airGain = stats.airGain + (st.lastSpeed - st.hop.takeoff)
            stats.airTurn = stats.airTurn + st.hop.turn
        end
        if st.flight then
            flightLine(st.flight, landingSpeed, P)
            st.flight = nil
        end
        -- Landed on a moving platform: from now on Unreal carries the character with
        -- it, apart from its velocity, but leaves the velocity as it was in the air,
        -- so the platform's motion would count twice (and each hop on the platform
        -- would add its speed again). Take the platform's velocity out, as leaving it
        -- put it in. (With bStayBasedInAir the velocity stayed relative to the platform.)
        if not st.stayBasedInAir then
            local baseX, baseY = platformVelocity(cmc)
            if baseX then
                vx, vy = vx - baseX, vy - baseY
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
    local hlGround, leave, slope = onGround, nil, nil
    if (cfg.SlopeLandings or cfg.SlopeBoosts) and not st.slopeBroken then
        hlGround, vx, vy, vz, leave, slope = slopeStep(cmc, cfg, P, mode, landed, vx, vy, vz, dt,
            jumpHeld and (cfg.AutoHop or not st.jump.latched))
    end
    local launch = leave == "launch"
    if landed then
        if st.hop then
            hopLine(st.hop, landingSpeed, P, slope)
        end
        st.hop = nil
    end
    if st.slide then
        holdGameJump(pawn)
    end
    local doJump = physics.wantJump(st.jump, jumpHeld, hlGround, cfg.AutoHop)

    local nx, ny, nz, jumped, steps = physics.simulate(st.sim, vx, vy, vz, hlGround, yaw, wish, doJump, P, dt,
        P.rate)
    stats.steps = stats.steps + steps
    local leaving = jumped or launch

    local bx, by, bz = 0, 0, 0
    if leaving then
        if jumped then
            log.first("jump", "First jump by the mod (speed %.0f cm/s)", horizontal(nx, ny))
        else
            log.first("launch", "First flight off a slope by the mod (speed %.0f cm/s)", horizontal(nx, ny))
        end
        -- With bStayBasedInAir, Unreal keeps carrying the character with the
        -- platform in the air and adds nothing when it leaves the ground, so the
        -- mod keeps nothing either.
        local platformX, platformY, platformZ = 0, 0, 0
        if not st.stayBasedInAir then
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
                local changes = count("jumpChanges")
                if changes <= MAX_NOTE_LINES then
                    log.info("Something in the game changed the velocity by (X=%.0f Y=%.0f Z=%.0f) cm/s when %s", ux,
                        uy, uz, jumped and "the jump started; the mod's jump ignores it"
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
    if jumped then
        stats.hops = stats.hops + 1
        st.hop = { n = st.hops + 1, takeoff = st.lastSpeed, time = 0, turn = 0, frames = 0, steps = 0,
            cuts = st.counts.cuts, keys = {}, yaw = yaw }
    elseif st.hop and not onGround then
        local hop = st.hop
        hop.time = hop.time + dt
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
        st.flight = { takeoff = st.lastSpeed, time = 0 }
    elseif st.flight and not onGround then
        st.flight.time = st.flight.time + dt
    end
    if leaving or mode == FALLING then
        trackHeading(frame, nx + bx - st.airBaseX, ny + by - st.airBaseY, dt, frameDt, steps)
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
    local baseX, baseY = 0, 0
    if (onGround and not leaving) or st.stayBasedInAir then
        baseX, baseY = platformVelocity(cmc)
    end
    -- What the game should hand back next frame, once its braking took the extra,
    -- and where the character was before this frame's move.
    st.written = { x = nx + bx, y = ny + by, z = writtenZ, mode = leaving and FALLING or mode, jumped = jumped,
        launched = launch, at = at, dt = frameDt or dt, baseX = baseX or 0, baseY = baseY or 0,
        afterMove = afterMove }
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
end

--- Where the character heads in the air in this frame, for the body to face: the
--- yaw in degrees for it to turn towards (where it heads, led by how fast that turns),
--- and the yaw where it heads (that of the horizontal velocity the mod handed to
--- Unreal, apart from a moving platform it left); false and false while that is
--- slower than HEADING_SPEED. nil unless the mod moved the character in this frame
--- and it is in the air after the mod's update (its jump included).
function movement.heading(frame)
    if st.headingFrame == frame then
        return st.headingTarget, st.headingYaw
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
    st.active = false
    st.cmc = nil
    st.cmcName = nil
    st.jump.latched = false
    st.written = nil
    st.hop = nil
    st.slide, st.flight = nil, nil
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
    st.active = false
    st.cmc = nil
    st.cmcName = nil
    st.jump.latched = false
    st.written = nil
    st.hop = nil
    st.slide, st.flight = nil, nil
end

--- What happened since the last call: frames moved, where the input came from,
--- hops, top speeds, per jump the speed gained in the air and how far the view
--- turned meanwhile, the speed lost at landing, Half-Life updates run, and what
--- the game did to the speed. Speeds in cm/s.
function movement.takeStats()
    local result = stats
    stats = newStats()
    return result
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
        sliding = st.slide ~= nil,
        maxStep = st.maxStep,
        gameMaxWalkSpeed = st.cmc and overrides:saved(st.cmc, "MaxWalkSpeed"),
        counts = st.counts,
        hops = st.hops,
    }
end

return movement
