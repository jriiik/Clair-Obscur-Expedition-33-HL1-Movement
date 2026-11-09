-- Half-Life style movement maths.
--
-- Pure Lua with no game or UE4SS dependency, so the tests in tests/ can run it
-- outside the game. It is an independent implementation of the movement model
-- Half-Life inherited from Quake: ground friction, ground acceleration, air
-- acceleration with a low speed cap (which is what makes air strafing and bunny
-- hopping work) and a fixed jump speed. It contains no code from the Half-Life SDK.
--
-- Vectors are passed as separate numbers. Any length unit works as long as the
-- velocities and the parameters use the same one; the mod uses centimetres,
-- Unreal's unit.

local physics = {}

local sqrt = math.sqrt

--- Ground friction: speed drops by max(speed, stopSpeed) * friction * dt, never
--- below zero. Speeds under minSpeed are left alone.
function physics.friction(vx, vy, vz, dt, friction, stopSpeed, minSpeed)
    local speed = sqrt(vx * vx + vy * vy + vz * vz)
    if speed < minSpeed then
        return vx, vy, vz
    end
    local control = speed < stopSpeed and stopSpeed or speed
    local newSpeed = speed - control * friction * dt
    if newSpeed < 0 then
        newSpeed = 0
    end
    local scale = newSpeed / speed
    return vx * scale, vy * scale, vz * scale
end

--- Accelerates along the unit wish direction (wx, wy). The speed along that
--- direction may grow up to `limit`, by at most accel * wishSpeed per second.
--- On the ground the limit is wishSpeed. In the air it is the small air cap while
--- the rate still uses the full wishSpeed, so turning while strafing adds speed.
function physics.accelerate(vx, vy, vz, wx, wy, wishSpeed, limit, accel, dt)
    local current = vx * wx + vy * wy
    local add = limit - current
    if add <= 0 then
        return vx, vy, vz
    end
    local amount = accel * wishSpeed * dt
    if amount > add then
        amount = add
    end
    return vx + amount * wx, vy + amount * wy, vz
end

--- Wish direction and speed from a ground-plane vector whose length is the
--- wanted speed. Returns wx, wy, wishSpeed (0, 0, 0 for no input).
function physics.wishFromVector(x, y, maxSpeed)
    local length = sqrt(x * x + y * y)
    if length < 1e-6 then
        return 0, 0, 0
    end
    local speed = length < maxSpeed and length or maxSpeed
    return x / length, y / length, speed
end

--- Wish direction and speed from movement axes (forward and right, each from -1
--- to 1) and the view yaw in degrees. Unreal is X forward, Y right, Z up, so yaw 0
--- looks along +X and yaw 90 along +Y. Diagonal input is not faster: the speed
--- is capped at maxSpeed.
function physics.wish(yawDegrees, forward, right, inputSpeed, maxSpeed)
    local yaw = math.rad(yawDegrees)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    local rx, ry = -fy, fx
    local x = (fx * forward + rx * right) * inputSpeed
    local y = (fy * forward + ry * right) * inputSpeed
    return physics.wishFromVector(x, y, maxSpeed)
end

--- Take-off speed for a jump of the given height under the given gravity.
function physics.jumpSpeed(gravity, height)
    return sqrt(2 * gravity * height)
end

--- Optional bunny-hop cap, as in later Half-Life updates: a jump that starts
--- above factor * maxSpeed cuts the velocity to 65% of that limit. A factor of 0
--- turns the cap off.
function physics.capBhop(vx, vy, vz, maxSpeed, factor)
    if not factor or factor <= 0 then
        return vx, vy, vz
    end
    local limit = factor * maxSpeed
    local speed = sqrt(vx * vx + vy * vy + vz * vz)
    if speed <= limit then
        return vx, vy, vz
    end
    local scale = limit / speed * 0.65
    return vx * scale, vy * scale, vz * scale
end

local function clamp(v, limit)
    if v > limit then
        return limit
    elseif v < -limit then
        return -limit
    end
    return v
end

--- Clamps each axis to +-limit, like Half-Life's sv_maxvelocity. A limit of 0
--- turns the clamp off.
function physics.clampAxes(vx, vy, vz, limit)
    if not limit or limit <= 0 then
        return vx, vy, vz
    end
    return clamp(vx, limit), clamp(vy, limit), clamp(vz, limit)
end

--- One movement update. Gravity is not applied here: the game's physics does it.
---
--- p holds accelerate, airAccelerate, airSpeedCap, friction, stopSpeed, minSpeed,
--- jumpSpeed, maxSpeed, bhopCap and maxVelocity. `jump` says whether to jump this
--- update if on the ground. Returns the new vx, vy, vz and whether a jump started.
function physics.step(vx, vy, vz, onGround, wx, wy, wishSpeed, jump, p, dt)
    local jumped = false
    if onGround and jump then
        -- The jump comes before friction, so jumping on the frame you land
        -- keeps all of your speed.
        vx, vy = physics.capBhop(vx, vy, vz, p.maxSpeed, p.bhopCap)
        vz = p.jumpSpeed
        onGround = false
        jumped = true
    end
    if onGround then
        vz = 0
        vx, vy, vz = physics.friction(vx, vy, vz, dt, p.friction, p.stopSpeed, p.minSpeed)
        if wishSpeed > 0 then
            vx, vy, vz = physics.accelerate(vx, vy, vz, wx, wy, wishSpeed, wishSpeed, p.accelerate, dt)
        end
    elseif wishSpeed > 0 then
        local limit = wishSpeed < p.airSpeedCap and wishSpeed or p.airSpeedCap
        vx, vy, vz = physics.accelerate(vx, vy, vz, wx, wy, wishSpeed, limit, p.airAccelerate, dt)
    end
    vx, vy, vz = physics.clampAxes(vx, vy, vz, p.maxVelocity)
    return vx, vy, vz, jumped
end

--- Decides whether to jump. With auto hop, holding the key jumps on every
--- landing. Without it (Half-Life 1's own rule) the key has to be released
--- between jumps, and holding it in the air uses the press up.
--- `state` is a table the caller keeps between updates. Returns true to jump.
function physics.wantJump(state, held, onGround, autoHop)
    if not held then
        state.latched = false
        return false
    end
    if autoHop then
        return onGround
    end
    if state.latched then
        return false
    end
    state.latched = true
    return onGround
end

return physics
