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
-- count. The distance isn't checked when the movement mode changed during Unreal's
-- update, at a landing or when walking off a ledge: the speed limiter listens to
-- mode changes, and a cap there comes part of the way through the move.)
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
-- own motion is taken out first.
local MOVED_MIN, MOVED_MAX = 0.9, 2
local MIN_CHECKED_SPEED = 50 -- cm/s
local MAX_CUT_LINES = 5
local MAX_NOTE_LINES = 3 -- for each other kind of thing the game did
local MAX_HOP_LINES = 20

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
    written = nil, -- the horizontal velocity the mod left for the game last frame
    lastMode = nil,
    lastSpeed = 0,
    emptyInputFrames = 0,
    hop = nil, -- the jump in progress, for the hop lines
    hops = 0,
    maxSpeed = nil, -- what GetMaxSpeed() said after the mod set MaxWalkSpeed
    gameWalkSpeed = nil, -- the MaxWalkSpeed the game wrote since the last frame, if it did
    stayBasedInAir = false, -- the movement component's bStayBasedInAir
    counts = { cuts = 0, restores = 0, rewrites = 0, wakes = 0, leaks = 0, jumpChanges = 0 },
}

-- What happened since the last status line (see movement.takeStats).
local function newStats()
    return { frames = 0, keys = 0, stick = 0, game = 0, none = 0, hops = 0, landings = 0, top = 0, topGround = 0,
        airHops = 0, airGain = 0, airTurn = 0, landingLoss = 0, steps = 0, cuts = 0, restores = 0, rewrites = 0,
        wakes = 0, leaks = 0 }
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
--- while the mod's movement should run.
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
        -- whole one, so that refreshes fall between the camera's (see movement.stagger).
        st.nextRefresh = now + (first and REFRESH / 4 or REFRESH)
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
end

--- Called when first person starts, whose refreshes start then: the next refresh
--- here comes a quarter period later, between the camera's.
function movement.stagger(now)
    if st.active then
        st.nextRefresh = now + REFRESH / 4
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

-- The velocity of the moving platform the character is on (zero on still ground
-- and in the air), read while it is still standing on it.
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
    local written = horizontal(w.x, w.y)
    local speed = horizontal(vx, vy)
    if written < MIN_CHECKED_SPEED or speed < 1e-3 then
        return vx, vy
    end
    local ratio = speed / written
    if ratio > CUT_MAX or (vx * w.x + vy * w.y) / (speed * written) < CUT_COS then
        return vx, vy
    end
    if w.mode == mode and w.at and at and w.dt and w.dt > 0 then
        -- How fast the character really moved. A wall or a step that stopped it part
        -- of the way lowers the velocity to match the distance moved; a cap lowers
        -- the velocity after the move. Unreal moves a character on a moving platform
        -- with it, apart from its velocity, so the platform's motion is taken out.
        -- (When the mode changed during the move, a cap by a listener of that change
        -- came part of the way through it, so the distance tells nothing.)
        local mx, my = (at.X - w.at.X) / w.dt, (at.Y - w.at.Y) / w.dt
        local baseX, baseY = platformVelocity(cmc)
        if baseX and baseY then
            mx, my = mx - baseX, my - baseY
        end
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
            tostring(w.mode), tostring(mode), w.jumped and ", after a jump" or "",
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

local function keysHeld(forward, right)
    return (forward > 0 and "W" or "") .. (right < 0 and "A" or "") .. (forward < 0 and "S" or "")
        .. (right > 0 and "D" or "")
end

local function hopLine(hop, landing, P)
    st.hops = st.hops + 1
    if st.hops > MAX_HOP_LINES then
        return
    end
    local u = P.unitScale
    local time = math.max(hop.time, 1e-6)
    local keys = {}
    for _, key in ipairs({ "W", "A", "S", "D" }) do
        if hop.keys[key] then
            keys[#keys + 1] = key
        end
    end
    log.info("Hop %d (%.0f fps, %.1f updates per frame): take-off %.0f u/s, landing %.0f u/s (%+.0f), %.2f s in "
        .. "the air, view turned %.0f deg (%.0f deg/s), keys %s, speed cuts %d%s", hop.n, hop.frames / time,
        hop.steps / math.max(hop.frames, 1), hop.takeoff / u, landing / u, (landing - hop.takeoff) / u, hop.time,
        hop.turn, hop.turn / time, #keys > 0 and table.concat(keys) or "none", st.counts.cuts - hop.cuts,
        st.hops == MAX_HOP_LINES and " (further hops aren't logged)" or "")
end

--- One frame of Half-Life movement. yaw is the camera's yaw in degrees; frame is
--- main.lua's frame counter; dt is the time to simulate, frameDt the frame's real
--- length (dt is limited for very long frames, Unreal's movement isn't).
function movement.step(pc, pawn, cmc, cfg, P, dt, yaw, frame, frameDt)
    local mode = cmc.MovementMode
    local onGround = mode == WALKING or mode == NAVWALKING

    -- What carries over from the last frame only does so if the mod moved the
    -- character on the frame just before.
    if st.lastStepFrame ~= frame - 1 then
        st.sim = {}
        st.written = nil
        st.lastMode = nil
        st.hop = nil
    elseif st.written then
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

    local doJump = physics.wantJump(st.jump, input.jumpHeld(pc, cfg, frame), onGround, cfg.AutoHop)

    local velocity = cmc.Velocity
    local rx, ry, rz = velocity.X, velocity.Y, velocity.Z
    local okAt, at = ue.call(pawn, "K2_GetActorLocation")
    at = okAt and type(at) == "table" and at or nil
    local landed = st.lastMode == FALLING and onGround
    local vx, vy = checkCut(cmc, cfg, P, rx, ry, rz, mode, landed, at)
    st.limiterWoke = false
    local vz = rz

    if landed then
        local speed = horizontal(vx, vy)
        stats.landings = stats.landings + 1
        stats.landingLoss = stats.landingLoss + math.max(0, st.lastSpeed - horizontal(rx, ry))
        if st.hop then
            stats.airHops = stats.airHops + 1
            stats.airGain = stats.airGain + (st.lastSpeed - st.hop.takeoff)
            stats.airTurn = stats.airTurn + st.hop.turn
            hopLine(st.hop, speed, P)
        end
        st.hop = nil
    end

    local nx, ny, nz, jumped, steps = physics.simulate(st.sim, vx, vy, vz, onGround, yaw, wish, doJump, P, dt,
        P.rate)
    stats.steps = stats.steps + steps

    local bx, by, bz = 0, 0, 0
    if jumped then
        log.first("jump", "First jump by the mod (speed %.0f cm/s)", horizontal(nx, ny))
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
                    log.info("Something in the game changed the velocity by (X=%.0f Y=%.0f Z=%.0f) cm/s when the jump "
                        .. "started; the mod's jump ignores it", ux, uy, uz)
                end
            end
        else
            bx, by, bz = cx, cy, cz -- no platform velocity to read: keep what the jump added
        end
    end
    st.lastMode = jumped and FALLING or mode
    st.lastSpeed = horizontal(nx, ny)
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
    end
    if st.lastSpeed > stats.top then
        stats.top = st.lastSpeed
    end
    if onGround and not jumped and st.lastSpeed > stats.topGround then
        stats.topGround = st.lastSpeed
    end

    -- Add back what Unreal's braking will take this frame (none in the air, and
    -- none on the ground once the movement curve is out).
    local wx, wy = nx, ny
    local ok, decel = ue.call(cmc, "GetMaxBrakingDeceleration")
    if ok and type(decel) == "number" and decel > 0 then
        local speed = horizontal(wx, wy)
        if speed > 1e-3 then
            local scale = (speed + decel * dt) / speed
            wx, wy = wx * scale, wy * scale
        end
    end
    cmc.Velocity = { X = wx + bx, Y = wy + by, Z = nz + bz }
    -- What the game should hand back next frame, once its braking took the extra,
    -- and where the character was before this frame's move.
    st.written = { x = nx + bx, y = ny + by, mode = jumped and FALLING or mode, jumped = jumped, at = at,
        dt = frameDt or dt }
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
        gameMaxWalkSpeed = st.cmc and overrides:saved(st.cmc, "MaxWalkSpeed"),
        counts = st.counts,
        hops = st.hops,
    }
end

return movement
