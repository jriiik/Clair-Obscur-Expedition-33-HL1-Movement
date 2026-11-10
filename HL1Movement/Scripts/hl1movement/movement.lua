-- Half-Life movement on the game's character.
--
-- Each frame, before the character's movement update, the mod takes the movement
-- input away from the game, works out the new velocity with physics.lua and hands
-- it to Unreal's character movement component. That component still handles
-- collisions, stairs, slopes, landing and gravity (with gravity set to Half-Life's).
--
-- Unreal brakes a character that gets no input. The mod turns braking friction off,
-- sets the plain braking values to almost zero, and adds back whatever braking is
-- left, so only the Half-Life friction applies.
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
    limiter = nil, -- the game's speed limiter component, if paused; false: none found
    jump = { latched = false },
    lastMode = nil,
    lastSpeed = 0,
    emptyInputFrames = 0,
    takeoffSpeed = nil, -- horizontal speed when the mod's last jump left the ground
    airYaw = nil, -- view yaw on the last frame in the air
    airTurn = 0, -- degrees the view turned during this jump
}

-- What happened since the last status line (see movement.takeStats).
local function newStats()
    return { frames = 0, keys = 0, stick = 0, game = 0, none = 0, hops = 0, landings = 0, top = 0,
        airHops = 0, airGain = 0, airTurn = 0, landingLoss = 0 }
end
local stats = newStats()

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
-- the curve, the plain values the mod sets to zero apply. ALS sets the curve
-- again when the character's stance or gait changes, so this runs every frame.
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
            log.first("curve", "Taking out the character's movement curve (%s)", tostring(ue.fullName(curve)))
            st.curve = curve
            local curveName = ue.fullName(curve)
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
    local curve = st.curve
    st.curve = nil
    st.curveName = nil
    journal.forget("curve", st.cmcName, "")
    if not curve or not ue.valid(st.cmc) or ue.fullName(st.cmc) ~= st.cmcName then
        return
    end
    pcall(function()
        local movementSettings = st.cmc.CurrentMovementSettings
        if not ue.valid(movementSettings.MovementCurve) and ue.valid(curve) then
            movementSettings.MovementCurve = curve
        end
    end)
end

-- The character has a component that caps its speed at the movement component's
-- maximum speed. It is paused while the mod runs, so bunny hopping can build
-- speed. (The huge MaxWalkSpeed already keeps it from acting; this is in case it
-- uses another limit.)
local function findLimiter(pawn)
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

-- Called at every refresh: the game may start the component again.
local function pauseLimiter(pawn)
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
        log.debug("Paused the game's speed limiter (%s)", LIMITER_CLASS)
        return
    end
    if ue.valid(limiter.obj) and ue.fullName(limiter.obj) == limiter.fullName then
        local ok, enabled = ue.call(limiter.obj, "IsComponentTickEnabled")
        if ok and enabled == true then
            -- The game started it again, so it is on when the mod hands back.
            limiter.wasEnabled = true
            journal.note("tick", limiter.fullName, "", true)
            limiter.obj:SetComponentTickEnabled(false)
        end
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
    overrides:set(cmc, "bUseSeparateBrakingFriction", true)
    overrides:set(cmc, "BrakingFriction", 0)
    overrides:set(cmc, "BrakingDecelerationWalking", TINY_BRAKING)
    overrides:set(cmc, "BrakingDecelerationFalling", TINY_BRAKING)
    overrides:set(cmc, "MaxWalkSpeedCrouched", SPEED_LIMIT)
    -- The game's own jump (on the first press) gets the same height as the mod's.
    overrides:set(cmc, "JumpZVelocity", P.jumpSpeed)
    overrides:set(pawn, "JumpMaxHoldTime", 0)
    if st.worldGravity then
        overrides:set(cmc, "GravityScale", P.gravity / -st.worldGravity)
    end
end

--- Takes over the character's movement, or keeps it taken over. Called every frame
--- while the mod's movement should run.
function movement.apply(pawn, cmc, cfg, P, now)
    if st.active and not ue.same(st.cmc, cmc) then
        movement.release()
    end
    if not st.active then
        st.active = true
        st.cmc = cmc
        st.cmcName = ue.fullName(cmc)
        st.worldGravity = measureGravity(cmc)
        st.nextRefresh = 0
        st.jump.latched = false
        st.lastMode = nil
        st.emptyInputFrames = 0
        if not st.worldGravity then
            log.once("gravity", "Could not read the game's gravity, so the game's own gravity stays.")
        end
        log.first("movement", "Taking over the movement of %s (mode %s, world gravity %s cm/s2)",
            tostring(ue.className(pawn)), tostring(ue.number(cmc, "MovementMode")), tostring(st.worldGravity))
        st.takeoffSpeed, st.airYaw, st.airTurn = nil, nil, 0
        log.debug("Movement taken over")
    end
    -- ALS sets the walking speed itself whenever the gait changes, and the game
    -- sets it for some areas, so this is set every frame. The high value stops the
    -- game from capping your speed.
    overrides:set(cmc, "MaxWalkSpeed", SPEED_LIMIT)
    takeCurve(cmc)
    if now >= st.nextRefresh then
        st.nextRefresh = now + REFRESH
        applyValues(pawn, cmc, P)
        if cfg.DisableSpeedLimiter then
            guard.run("pausing the speed limiter", pauseLimiter, pawn)
        end
    end
end

--- One frame of Half-Life movement. yaw is the camera's yaw in degrees; frame is
--- main.lua's frame counter.
function movement.step(pc, pawn, cmc, cfg, P, dt, yaw, frame)
    local mode = cmc.MovementMode
    local onGround = mode == WALKING or mode == NAVWALKING

    -- Take this frame's movement input away from the game, so Unreal doesn't
    -- accelerate the character on its own. It is kept as a fallback direction.
    local pending = pawn:ConsumeMovementInputVector()
    local px, py = ue.vector(pending)

    local forward, right, source = input.moveAxes(pc, cfg)
    local wx, wy, wishSpeed = 0, 0, 0
    if forward ~= 0 or right ~= 0 then
        wx, wy, wishSpeed = physics.wish(yaw, forward, right, P.inputSpeed, P.maxSpeed)
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
        wx, wy, wishSpeed = physics.wishFromVector(px * P.inputSpeed, py * P.inputSpeed, P.maxSpeed)
        source = "game"
        log.first("input-game", "Movement comes from the game's own input, not from reading the keys "
            .. "(vector X=%.2f Y=%.2f)", px, py)
    end
    source = source or "none"
    stats[source] = stats[source] + 1
    stats.frames = stats.frames + 1

    local doJump = physics.wantJump(st.jump, input.jumpHeld(pc, cfg, frame), onGround, cfg.AutoHop)

    local velocity = cmc.Velocity
    local vx, vy, vz = velocity.X, velocity.Y, velocity.Z
    if st.lastMode == FALLING and onGround then
        local speed = horizontal(vx, vy)
        if st.lastSpeed > P.maxSpeed and speed < st.lastSpeed * 0.8 then
            log.once("landing-speed", "Landing cut the speed from %.0f to %.0f cm/s, so something in the game "
                .. "still limits speed. Please report this with UE4SS.log.", st.lastSpeed, speed)
        end
        stats.landings = stats.landings + 1
        stats.landingLoss = stats.landingLoss + math.max(0, st.lastSpeed - speed)
        if st.takeoffSpeed then
            stats.airHops = stats.airHops + 1
            stats.airGain = stats.airGain + (st.lastSpeed - st.takeoffSpeed)
            stats.airTurn = stats.airTurn + st.airTurn
        end
        st.takeoffSpeed, st.airYaw, st.airTurn = nil, nil, 0
    elseif not onGround then
        if st.airYaw then
            st.airTurn = st.airTurn + math.abs((yaw - st.airYaw + 180) % 360 - 180)
        end
        st.airYaw = yaw
    end

    local nx, ny, nz, jumped = physics.step(vx, vy, vz, onGround, wx, wy, wishSpeed, doJump, P, dt)
    local bx, by, bz = 0, 0, 0
    if jumped then
        log.first("jump", "First jump by the mod (speed %.0f cm/s)", horizontal(nx, ny))
        cmc:SetMovementMode(FALLING, 0)
        -- Leaving the ground adds the velocity of a moving platform the character
        -- stood on (while walking, Velocity is relative to it). Keep that.
        local after = cmc.Velocity
        bx, by, bz = after.X - vx, after.Y - vy, after.Z - vz
    end
    st.lastMode = jumped and FALLING or mode
    st.lastSpeed = horizontal(nx, ny)
    if jumped then
        stats.hops = stats.hops + 1
        st.takeoffSpeed, st.airYaw, st.airTurn = st.lastSpeed, yaw, 0
    end
    if st.lastSpeed > stats.top then
        stats.top = st.lastSpeed
    end

    -- Add back what Unreal's braking will take this frame (none in the air, and
    -- none on the ground once the movement curve is out).
    local ok, decel = ue.call(cmc, "GetMaxBrakingDeceleration")
    if ok and type(decel) == "number" and decel > 0 then
        local speed = horizontal(nx, ny)
        if speed > 1e-3 then
            local scale = (speed + decel * dt) / speed
            nx, ny = nx * scale, ny * scale
        end
    end
    cmc.Velocity = { X = nx + bx, Y = ny + by, Z = nz + bz }
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
    log.debug("Movement given back to the game")
end

--- What happened since the last call: frames moved, where the input came from,
--- hops, top speed, and per jump the speed gained in the air, how far the view
--- turned meanwhile, and the speed lost at landing. Speeds in cm/s.
function movement.takeStats()
    local result = stats
    stats = newStats()
    return result
end

--- What the movement side is doing, for the diagnostics report.
function movement.status()
    return {
        active = st.active,
        worldGravity = st.worldGravity,
        curveTaken = st.curve ~= nil,
        curveBroken = st.curveBroken,
        limiter = st.limiter == nil and "not looked for" or (st.limiter and "paused" or "none found"),
    }
end

return movement
