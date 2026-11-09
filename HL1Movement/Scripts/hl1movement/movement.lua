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

local physics = require("hl1movement.physics")
local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local input = require("hl1movement.input")
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
    maxWalkSaved = false,
    curve = nil, -- the movement curve the mod took out, to put back
    curveBroken = false,
    limiter = nil, -- the game's speed limiter component, if paused; false: none found
    jump = { latched = false },
    lastMode = nil,
    lastSpeed = 0,
    emptyInputFrames = 0,
}

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
            st.curve = curve
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

-- The character has a component that seems to cap its speed at the normal running
-- speed. It is paused while the mod runs, so bunny hopping can build speed.
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

local function pauseLimiter(pawn)
    if st.limiter ~= nil then
        return
    end
    local limiter = findLimiter(pawn)
    if not limiter then
        st.limiter = false
        log.debug("No %s found on the character", LIMITER_CLASS)
        return
    end
    local ok, enabled = ue.call(limiter, "IsComponentTickEnabled")
    st.limiter = { obj = limiter, fullName = ue.fullName(limiter), wasEnabled = ok and enabled == true }
    limiter:SetComponentTickEnabled(false)
    log.debug("Paused the game's speed limiter (%s)", LIMITER_CLASS)
end

local function resumeLimiter()
    local limiter = st.limiter
    st.limiter = nil
    if limiter and limiter.wasEnabled and ue.valid(limiter.obj) and ue.fullName(limiter.obj) == limiter.fullName then
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
        st.maxWalkSaved = false
        st.jump.latched = false
        st.lastMode = nil
        st.emptyInputFrames = 0
        if not st.worldGravity then
            log.once("gravity", "Could not read the game's gravity, so the game's own gravity stays.")
        end
        log.debug("Movement taken over")
    end
    -- ALS sets the walking speed itself whenever the gait changes, so this is set
    -- every frame. The high value stops the game from capping your speed.
    if st.maxWalkSaved then
        cmc.MaxWalkSpeed = SPEED_LIMIT
    else
        st.maxWalkSaved = overrides:set(cmc, "MaxWalkSpeed", SPEED_LIMIT)
    end
    takeCurve(cmc)
    if now >= st.nextRefresh then
        st.nextRefresh = now + REFRESH
        applyValues(pawn, cmc, P)
        if cfg.DisableSpeedLimiter then
            pauseLimiter(pawn)
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

    local forward, right = input.moveAxes(pc, cfg)
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
    end

    local doJump = physics.wantJump(st.jump, input.jumpHeld(pc, cfg, frame), onGround, cfg.AutoHop)

    local velocity = cmc.Velocity
    local vx, vy, vz = velocity.X, velocity.Y, velocity.Z
    if st.lastMode == FALLING and onGround then
        local speed = horizontal(vx, vy)
        if st.lastSpeed > P.maxSpeed and speed < st.lastSpeed * 0.8 then
            log.once("landing-speed", "Landing cut the speed from %.0f to %.0f cm/s, so something in the game "
                .. "still limits speed. Please report this with UE4SS.log.", st.lastSpeed, speed)
        end
    end

    local nx, ny, nz, jumped = physics.step(vx, vy, vz, onGround, wx, wy, wishSpeed, doJump, P, dt)
    if jumped then
        cmc:SetMovementMode(FALLING, 0)
    end
    st.lastMode = jumped and FALLING or mode
    st.lastSpeed = horizontal(nx, ny)

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
    cmc.Velocity = { X = nx, Y = ny, Z = nz }
end

--- Gives the movement back to the game and puts back everything the mod changed.
function movement.release()
    if not st.active then
        return
    end
    overrides:restore()
    putCurveBack()
    resumeLimiter()
    if ue.valid(st.cmc) and ue.fullName(st.cmc) == st.cmcName then
        -- Makes ALS set its own walking speed again.
        pcall(function()
            st.cmc.bRequestMovementSettingsChange = true
        end)
    end
    st.active = false
    st.cmc = nil
    st.cmcName = nil
    st.jump.latched = false
    log.debug("Movement given back to the game")
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
