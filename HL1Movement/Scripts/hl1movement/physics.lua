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

local duck = require("hl1movement.duck")

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
--- jumpSpeed, maxSpeed, bhopCap, maxVelocity and unitScale (the length of one Half-Life
--- unit in the velocities' unit; 1 if missing). `jump` says whether to jump this update
--- if on the ground. Returns the new vx, vy, vz and whether a jump started.
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
        -- Half-Life's walk move: a player left slower than 1 u/s by friction and the ground
        -- acceleration stops, wish or not (with no movement key too: friction alone leaves
        -- 0.3 u/s of 1.9 at 250 updates a second).
        local unit = p.unitScale or 1
        if vx * vx + vy * vy < unit * unit then
            vx, vy = 0, 0
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

-- The slide a run-in starts at one of a frame's updates (simulate's dk.runIn), with the
-- fields of the slides movement.lua starts at a hook: Half-Life's step move leaves the
-- player on the slope, 1/32 unit off it (h, straight up), and the path's travel (dx, dy)
-- and the rise of the plane under it (rise) count from the frame's start, as for a slide
-- that was on then (travelX, travelY: the frame's updates on the ground so far).
local function runInSlide(p, up, n, travelX, travelY)
    return { vz = up, nx = n.nx, ny = n.ny, nz = n.nz, h = p.restHeight / n.nz, clipped = true, push = 0, time = 0,
        dx = travelX, dy = travelY, rise = -(travelX * n.nx + travelY * n.ny) / n.nz, ox = 0, oy = 0 }
end

local OPEN = {} -- room for every stand-up and lift

-- A frame with no update, with ducking: no duck step (a waiting notch waits, the timer
-- doesn't run), and the jump at once only where the first update would jump. Where its
-- duck step, tried on a copy of the state, lifts a duck tap (the player is in the air
-- before that update's jump) or stands up from the full duck (Half-Life stands up first and
-- jumps standing), the jump button waits for that update, with no "jump is down" mark set,
-- and so does a jump notch alone in the air (Unreal may land the character before the next
-- update, which then begins on the ground): a notch waits in d.jumpWait. A held jump key in
-- the air is judged at once, as 0.3.1's one decision a frame did (a fresh press without
-- AutoHop, or under a ducktap key, is used up there). Returns whether to jump now.
local function jumpWithoutUpdate(d, onGround, room)
    local c = duck.copy(d)
    local _, event = duck.step(c, duck.button(c, onGround and not c.airSeen), onGround, room, 0)
    if (onGround and (event == "lift" or event == "stood")) or (not onGround and d.jumpNotch and not d.jumpKey) then
        d.jumpWait = d.jumpNotch
        return false
    end
    return duck.jump(d, duck.jumpButton(d, true), onGround)
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
--- on the update a slide ends on (slide.jump, below); with dk, on an update its keys
--- and the duck step decide (below).
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
--- dk, if given, adds Half-Life's ducking and decides the jump update by update:
--- { d = the duck state (duck.new; the caller keeps it between frames and gives it the
--- hook's keys with duck.frame), room = { ground, air, lift } (false where Unreal has no
--- room to stand up on the ground, in the air, or to lift a duck tap; nil or missing:
--- room), runIn = nil or { nx, ny, nz }, out = {} }. The jump argument and slide.jump are
--- not used then. Each update, in Half-Life's order: its duck and jump buttons, with "on
--- the ground" as the update before left the player (duck.button, duck.jumpButton); a
--- slide's ground check; the duck step (duck.step: in a slide no stand-up, the slope
--- being too close below; a duck in a slide ends it, slide.ducked, with no more gravity
--- or clips this frame); a slide's gravity; the wish, capped to maxSpeed, times the duck
--- step's scale; the jump (duck.jump); the move. runIn is the unit normal of an upward
--- slope the player walks on: an update that ran on the ground and didn't jump runs into
--- it with the velocity it left (after its friction and acceleration), and if the clip's
--- rise is still over p.airborneSpeed half an update of gravity later, the player is in
--- the air from the next update on, sliding up it, with that rise and its level velocity
--- as it was (Half-Life's step move). Only in a frame that starts on the ground (not
--- after a slide that was on). A rise over p.airborneSpeed that isn't half an update later
--- leaves the player on the ground, but in the air for the next update's duck button
--- (d.airSeen): Half-Life's last ground check of the update had it there. dk.out gets: events
--- (a list of { k = the update, what = duck.step's event, ground = whether that update's
--- duck step found the player on the ground }), lifted (the update of a duck tap's lift),
--- jumped (the update a jump started on, 0 in a frame with no update), scaled (updates
--- with their moves scaled), ground (updates run on the ground), runIn ({ k, vx, vy, up }:
--- the run-in's update, its velocity and rise) and slide (the slide it started, a table
--- as a slide given here), and at the end state (the duck state's), button (the last
--- update's duck button) and held (the duck button was down on every update of the last
--- frame that ran one; kept in d.held). A frame with no update runs no duck step and
--- jumps at once only where its first update would (not where it lifts a duck tap).
---
--- Returns the new vx, vy, vz, whether a jump started, and the number of steps.
function physics.simulate(sim, vx, vy, vz, onGround, yaw, wish, jump, p, dt, rate, slide, floor, dk)
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
    local d, out, room, slideRoom
    if dk then
        d, room = dk.d, dk.room or OPEN
        slideRoom = { ground = room.ground, air = false, lift = room.lift }
        out = dk.out or {}
        dk.out = out
        out.events, out.lifted, out.jumped, out.scaled, out.ground = {}, nil, nil, 0, 0
        out.runIn, out.slide = nil, nil
    end
    if steps == 0 then
        -- Less than one step of time so far. A jump can't wait for the next frame,
        -- since the game moves the character in between: it starts now.
        local jumped = false
        if d then
            -- (In a slide the player is in the air, where no lift can be and no jump starts.)
            jump = jumpWithoutUpdate(d, onGround, room)
            out.state, out.button, out.held = d.state, d.wasDown, d.held
        end
        if jump and onGround then
            vx, vy, vz, jumped = physics.step(vx, vy, vz, true, 0, 0, 0, true, p, 0)
            if out then
                out.jumped = 0
            end
        end
        return vx, vy, vz, jumped, 0
    end
    local turn = physics.turn(fromYaw, yaw)
    local jumped = false
    local sliding = slide ~= nil and not onGround
    -- (A frame with a slide on starts in the air: its updates after the slide's end run
    -- into no slope.)
    local runIn = d and onGround and dk.runIn or nil
    local held = true -- the duck button on every update so far
    local travelX, travelY = 0, 0 -- the frame's travel on the ground so far, for a run-in's slide
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
        local button, jumpButton
        if d then
            -- The buttons as OpenAG's client builds them, from where the update before left
            -- the player (d.airSeen: in the air, though this update finds the floor).
            button, jumpButton = duck.button(d, onGround and not d.airSeen), duck.jumpButton(d, k == 1)
            d.airSeen = false
        end
        if sliding then
            if vz - 0.5 * p.gravity * stepTime <= p.airborneSpeed and (slide.h or 0) < p.groundCheck then
                -- The ground check at the update's start: the slide is over, with the
                -- velocity the last update left. This update is the first on the ground.
                sliding, onGround = false, true
                slide.ended, slide.endX, slide.endY, slide.endZ = true, vx, vy, vz
                jumpNow = slide.jump
            elseif not d then
                vz = vz - p.gravity * stepTime
            end
        end
        if d then
            -- The duck step, then (still sliding) the slide's gravity: an update that ducks
            -- out of a slide is the flight's, whose gravity is Unreal's.
            local before = onGround
            local scale, event
            scale, event, onGround = duck.step(d, button, onGround, sliding and slideRoom or room, 1000 * stepTime)
            if event then
                out.events[#out.events + 1] = { k = k, what = event, ground = before }
                if event == "lift" then
                    out.lifted = k
                elseif event == "ducked" and sliding then
                    -- The ducked hull's lower edge is 18 units higher: off the slope.
                    sliding, slide.ducked = false, true
                end
            end
            if sliding then
                vz = vz - p.gravity * stepTime
            end
            if scale < 1 then
                wishSpeed = wishSpeed * scale
                out.scaled = out.scaled + 1
            end
            jumpNow = duck.jump(d, jumpButton, onGround)
            held = held and button
        end
        local ground = onGround
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
        if d then
            if started then
                out.jumped = k
            elseif ground then
                out.ground = out.ground + 1
            end
        end
        if runIn and not onGround then
            runIn = nil -- in the air from here on: a jump, a lift or leaving the floor
        elseif runIn then
            -- Half-Life's ground move runs into the slope with the velocity this update left
            -- and keeps the clip's rise (its step move): over 180 u/s at the next update's
            -- ground check, the player is in the air from there on, sliding up the slope.
            travelX, travelY = travelX + vx * stepTime, travelY + vy * stepTime
            local _, _, up = physics.clip(vx, vy, 0, runIn.nx, runIn.ny, runIn.nz)
            if up - 0.5 * p.gravity * stepTime > p.airborneSpeed then
                slide = runInSlide(p, up, runIn, travelX, travelY)
                out.slide, out.runIn = slide, { k = k, vx = vx, vy = vy, up = up }
                vz, onGround, sliding, runIn = up, false, true, nil
            elseif up > p.airborneSpeed then
                -- Over 180 u/s at this update's last ground check, and not half an update of
                -- gravity later at the next one's first: on the ground for the next update, in
                -- the air for the client that builds its buttons (it ends this update so).
                d.airSeen = true
            end
        end
    end
    if d then
        d.held = held
        out.state, out.button, out.held = d.state, d.wasDown, held
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
