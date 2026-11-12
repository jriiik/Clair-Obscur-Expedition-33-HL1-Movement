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

--- Half-Life's response to running into a surface, with an overbounce of 1: the
--- part of the velocity going into the surface is taken out, so what is left runs
--- along it. (nx, ny, nz) is the surface's unit normal. A velocity that doesn't go
--- into the surface is returned as it is. Landing on a slope this turns some of the
--- fall into speed down the slope; running into an upward slope it turns some of
--- the speed into rising.
function physics.clip(vx, vy, vz, nx, ny, nz)
    local into = vx * nx + vy * ny + vz * nz
    if into >= 0 then
        return vx, vy, vz
    end
    return vx - into * nx, vy - into * ny, vz - into * nz
end

--- Whether Half-Life's player leaves a floor that falls away under it at the end of an
--- update on the ground of `step` seconds: its ground move goes straight ahead, and the
--- ground check after it reaches `reach` below. From `rest` off the floor's plane (at
--- right angles, where a player rests), moving at (vx, vy), it ends (vx nx + vy ny) / nz
--- * step + rest / nz above that plane, straight up. (nx, ny, nz): the floor's unit normal.
function physics.leavesFloor(vx, vy, nx, ny, nz, step, reach, rest)
    return (vx * nx + vy * ny) / nz * step + rest / nz >= reach
end

--- The shortest turn in degrees from one yaw to another, from -180 to 180.
function physics.turn(fromDegrees, toDegrees)
    return (toDegrees - fromDegrees + 180) % 360 - 180
end

local MAX_STEPS = 25 -- per frame; time beyond that is dropped (a very long frame)

-- One update's move in a slide whose path is followed (slide.h: how far it is above
-- the plane of the floor, slide.nx, ny, nz, straight up, in cm). Half-Life's move runs
-- into the floor only if it would end behind its plane: it stops there 1/32 unit off it
-- (at right angles, p.restHeight), or where it was if it was closer, and goes on along
-- it with the velocity clipped. Above about 160 updates a second one update's gravity
-- closes less than the 1/32 unit, so the update after a clip can fall short of the
-- floor and keep its gravity; where the floor falls away, the path leaves it. Without a
-- normal the path only rises and falls. For the frame it adds how far the path went
-- (slide.dx, slide.dy), how far the plane rose under it (slide.rise), what the clips
-- took out (slide.push) and how long the updates ran (slide.time); slide.clipped: the
-- last move ran into the floor.
local function slideMove(slide, vx, vy, vz, p, stepTime)
    local nx, ny, nz = slide.nx, slide.ny, slide.nz
    local before = slide.h
    slide.time = slide.time + stepTime
    if not nx then
        slide.h, slide.clipped = before + vz * stepTime, false
        slide.dx, slide.dy = slide.dx + vx * stepTime, slide.dy + vy * stepTime
        return vx, vy, vz
    end
    local into = vx * nx + vy * ny + vz * nz
    local after = before + into / nz * stepTime
    local dx, dy
    if after >= 0 then
        slide.h, slide.clipped = after, false
        dx, dy = vx * stepTime, vy * stepTime
    else
        -- It goes this share of the move before it stops, then along the floor.
        local rest = p.restHeight / nz
        local share = before > rest and (before - rest) / (before - after) or 0
        dx, dy = vx * stepTime * share, vy * stepTime * share
        slide.push = slide.push - into
        vx, vy, vz = physics.clip(vx, vy, vz, nx, ny, nz)
        dx, dy = dx + vx * stepTime * (1 - share), dy + vy * stepTime * (1 - share)
        slide.h, slide.clipped = math.min(before, rest), true
    end
    slide.dx, slide.dy = slide.dx + dx, slide.dy + dy
    slide.rise = slide.rise - (dx * nx + dy * ny) / nz
    return vx, vy, vz
end

--- Runs the Half-Life update at a fixed rate within one game frame. Half-Life
--- updates the player once per input command, usually 100 times a second, and
--- air strafing gains speed in small steps: at a low frame rate, one big update
--- per frame gains much less, or even loses speed.
---
--- sim is a table the caller keeps between frames (an empty table to start): the
--- time left over from earlier frames, and the view yaw of the last frame. wish is
--- the input: { forward = f, right = r } (axes from -1 to 1, turned with the view:
--- each step gets the view of its own time, between the last frame's and this one's,
--- the short way round, as each of Half-Life's updates has the view of its own), or
--- { x = wx, y = wy, speed = s } (a fixed direction), or nil for none. With a rate
--- of 0 there is one update per frame. A jump can only start on the first step, or
--- on the update a slide ends on (slide.jump, below).
---
--- slide, if given, is a slide up a slope: the player is in the air for Half-Life,
--- rising at vz along a floor the game walks it up, so the game applies no gravity and
--- each update here does (p.gravity), as Half-Life: the ground check at the update's
--- start, which finds the player on the ground once it rises no faster than
--- p.airborneSpeed, half an update of gravity after the last move, and is within its
--- reach (p.groundCheck) of the floor's plane, if slide.h follows the path (see
--- slideMove); then the rest of the update's gravity, the air acceleration, and the
--- clip against the floor it runs into (slide.nx, slide.ny, slide.nz: its unit normal;
--- without them nothing is clipped; with slide.h only a move that reaches the floor's
--- plane, see slideMove, without it every update). When the ground check ends the slide,
--- slide.ended is set, with slide.endX, slide.endY (the horizontal velocity of the last
--- update) and slide.endZ; that update and the rest are on the ground, and a jump starts
--- on it if slide.jump is set.
---
--- floor, if given, is the floor the player walks on ({ nx, ny, nz }: its unit normal):
--- where it falls away so far under an update's ground move that the ground check
--- misses it (see physics.leavesFloor), the player is in the air from the next update
--- on, and floor.left is set to the number of that update.
---
--- Returns the new vx, vy, vz, whether a jump started, and the number of steps.
function physics.simulate(sim, vx, vy, vz, onGround, yaw, wish, jump, p, dt, rate, slide, floor)
    local fromYaw = sim.yaw or yaw
    sim.yaw = yaw
    local steps, stepTime
    local leftover = 0 -- the time from the last step to the last frame
    if not rate or rate <= 0 then
        steps, stepTime = 1, dt
        sim.time = 0
    else
        stepTime = 1 / rate
        leftover = sim.time or 0
        local total = leftover + dt
        steps = math.floor(total * rate + 1e-9)
        if steps > MAX_STEPS then
            steps = MAX_STEPS
            sim.time = 0
        else
            sim.time = math.max(0, total - steps * stepTime)
        end
    end
    if steps == 0 then
        -- Less than one step of time so far. A jump can't wait for the next frame,
        -- since the game moves the character in between: it starts now.
        local jumped = false
        if jump and onGround then
            vx, vy, vz, jumped = physics.step(vx, vy, vz, true, 0, 0, 0, true, p, 0)
        end
        return vx, vy, vz, jumped, 0
    end
    local turn = physics.turn(fromYaw, yaw)
    local jumped = false
    local sliding = slide ~= nil and not onGround
    for k = 1, steps do
        local wx, wy, wishSpeed = 0, 0, 0
        if wish and wish.speed then
            wx, wy, wishSpeed = wish.x, wish.y, wish.speed
        elseif wish and (wish.forward ~= 0 or wish.right ~= 0) then
            -- This step ends k steps after the last one, which was `leftover` before the
            -- last frame: the view has turned that share of this frame's turn by then.
            -- (A share of the turn for each step made the steps' turns uneven whenever the
            -- frames ran different numbers of steps, and air strafing gained less.)
            local share = dt > 0 and math.max(0, math.min(1, (k * stepTime - leftover) / dt)) or 1
            wx, wy, wishSpeed = physics.wish(fromYaw + turn * share, wish.forward, wish.right,
                p.inputSpeed, p.maxSpeed)
        end
        local jumpNow = jump and k == 1
        if sliding then
            if vz - 0.5 * p.gravity * stepTime <= p.airborneSpeed and (slide.h or 0) < p.groundCheck then
                -- The ground check at the update's start: the slide is over, with the
                -- velocity the last update left. This update is the first on the ground.
                sliding, onGround = false, true
                slide.ended, slide.endX, slide.endY, slide.endZ = true, vx, vy, vz
                jumpNow = slide.jump
            else
                vz = vz - p.gravity * stepTime
            end
        end
        local started
        local walked = onGround and floor and not floor.left
        vx, vy, vz, started = physics.step(vx, vy, vz, onGround, wx, wy, wishSpeed, jumpNow, p, stepTime)
        if started then
            jumped = true
            onGround = false
        elseif walked and physics.leavesFloor(vx, vy, floor.nx, floor.ny, floor.nz, stepTime, p.groundCheck,
            p.restHeight) then
            onGround, floor.left = false, k
        elseif sliding and slide.h then
            vx, vy, vz = slideMove(slide, vx, vy, vz, p, stepTime)
        elseif sliding and slide.nx then
            vx, vy, vz = physics.clip(vx, vy, vz, slide.nx, slide.ny, slide.nz)
        end
    end
    return vx, vy, vz, jumped, steps
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
