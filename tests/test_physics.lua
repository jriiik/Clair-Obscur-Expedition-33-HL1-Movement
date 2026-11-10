-- Tests for HL1Movement/Scripts/hl1movement/physics.lua, in Half-Life units
-- (unit scale 1), so the numbers can be checked against Half-Life's.

local t = require("testlib")
local physics = require("hl1movement.physics")
local settings = require("hl1movement.settings")

local P = settings.physics(settings.load({ UnitScale = 1 }))

t.test("default parameters match Half-Life's", function()
    t.eq(P.maxSpeed, 320)
    t.eq(P.airSpeedCap, 30)
    t.eq(P.stopSpeed, 100)
    t.eq(P.gravity, 800)
    t.near(P.jumpSpeed, math.sqrt(2 * 800 * 45), 1e-9, "jump speed for a 45 unit jump")
    t.near(P.jumpSpeed, 268.33, 0.01)
end)

t.test("friction above the stop speed takes speed * friction * dt", function()
    local vx = physics.friction(320, 0, 0, 0.01, 4, 100, 0.1)
    t.near(vx, 320 - 320 * 4 * 0.01, 1e-9)
end)

t.test("friction below the stop speed takes stopSpeed * friction * dt", function()
    local vx = physics.friction(50, 0, 0, 0.01, 4, 100, 0.1)
    t.near(vx, 50 - 100 * 4 * 0.01, 1e-9)
end)

t.test("friction stops at zero and leaves tiny speeds alone", function()
    local vx, vy = physics.friction(2, 1, 0, 0.1, 4, 100, 0.1)
    t.eq(vx, 0)
    t.eq(vy, 0)
    local sx = physics.friction(0.05, 0, 0, 0.1, 4, 100, 0.1)
    t.eq(sx, 0.05)
end)

t.test("ground acceleration adds accel * wishSpeed * dt up to the wish speed", function()
    local vx = physics.accelerate(0, 0, 0, 1, 0, 320, 320, 10, 0.01)
    t.near(vx, 32, 1e-9)
    local capped = physics.accelerate(310, 0, 0, 1, 0, 320, 320, 10, 0.01)
    t.near(capped, 320, 1e-9)
    local over = physics.accelerate(400, 0, 0, 1, 0, 320, 320, 10, 0.01)
    t.eq(over, 400, "no change above the wish speed")
end)

t.test("air acceleration across the velocity adds speed (air strafing)", function()
    local vx, vy = physics.accelerate(320, 0, 0, 0, 1, 320, 30, 10, 0.01)
    t.eq(vx, 320)
    t.near(vy, 30, 1e-9, "capped at the air speed cap")
    t.truthy(math.sqrt(vx * vx + vy * vy) > 320, "faster than before")
end)

t.test("air acceleration along the velocity adds nothing above the air cap", function()
    local vx, vy = physics.accelerate(320, 0, 0, 1, 0, 320, 30, 10, 0.01)
    t.eq(vx, 320)
    t.eq(vy, 0)
end)

t.test("wish direction follows the view yaw (Unreal: X forward, Y right)", function()
    local wx, wy, speed = physics.wish(0, 1, 0, 400, 320)
    t.near(wx, 1, 1e-9)
    t.near(wy, 0, 1e-9)
    t.eq(speed, 320, "clamped to max speed")
    wx, wy = physics.wish(0, 0, 1, 400, 320)
    t.near(wx, 0, 1e-9, "right at yaw 0 is +Y")
    t.near(wy, 1, 1e-9)
    wx, wy = physics.wish(90, 1, 0, 400, 320)
    t.near(wx, 0, 1e-9, "forward at yaw 90 is +Y")
    t.near(wy, 1, 1e-9)
    wx, wy = physics.wish(90, 0, 1, 400, 320)
    t.near(wx, -1, 1e-9, "right at yaw 90 is -X")
    t.near(wy, 0, 1e-9)
end)

t.test("diagonal input is not faster", function()
    local wx, wy, speed = physics.wish(0, 1, 1, 400, 320)
    t.eq(speed, 320)
    t.near(wx, math.sqrt(0.5), 1e-9)
    t.near(wy, math.sqrt(0.5), 1e-9)
end)

t.test("small analog input gives a slower wish speed", function()
    local _, _, speed = physics.wish(0, 0.5, 0, 400, 320)
    t.near(speed, 200, 1e-9)
end)

t.test("no input gives no wish", function()
    local wx, wy, speed = physics.wish(37, 0, 0, 400, 320)
    t.eq(wx, 0)
    t.eq(wy, 0)
    t.eq(speed, 0)
end)

t.test("jumping on the ground keeps all horizontal speed (no friction that frame)", function()
    local vx, vy, vz, jumped = physics.step(500, 0, 0, true, 0, 0, 0, true, P, 0.01)
    t.truthy(jumped)
    t.eq(vx, 500)
    t.eq(vy, 0)
    t.near(vz, P.jumpSpeed, 1e-9)
end)

t.test("standing on the ground without jumping applies friction", function()
    local vx, _, vz, jumped = physics.step(500, 0, 30, true, 0, 0, 0, false, P, 0.01)
    t.falsy(jumped)
    t.near(vx, 500 - 500 * 4 * 0.01, 1e-9)
    t.eq(vz, 0, "no vertical speed on the ground")
end)

t.test("the jump frame uses air acceleration", function()
    local _, vy = physics.step(500, 0, 0, true, 0, 1, 320, true, P, 0.01)
    t.near(vy, 30, 1e-9, "air cap, not ground acceleration")
end)

t.test("falling keeps vertical speed for the game's gravity", function()
    local _, _, vz = physics.step(0, 0, -100, false, 0, 0, 0, true, P, 0.01)
    t.eq(vz, -100)
end)

t.test("bunny-hop cap is off by default and cuts speed when on", function()
    local vx = physics.capBhop(1000, 0, 0, 320, 0)
    t.eq(vx, 1000)
    vx = physics.capBhop(1000, 0, 0, 320, 1.7)
    t.near(vx, 320 * 1.7 * 0.65, 1e-9)
    vx = physics.capBhop(500, 0, 0, 320, 1.7)
    t.eq(vx, 500, "below the cap nothing changes")
end)

t.test("each axis is clamped to the max velocity", function()
    local vx, vy, vz = physics.clampAxes(3000, -2500, 100, 2000)
    t.eq(vx, 2000)
    t.eq(vy, -2000)
    t.eq(vz, 100)
end)

t.test("auto hop jumps on every landing while held", function()
    local state = { latched = false }
    t.truthy(physics.wantJump(state, true, true, true))
    t.falsy(physics.wantJump(state, true, false, true), "not in the air")
    t.truthy(physics.wantJump(state, true, true, true), "again on landing")
    t.falsy(physics.wantJump(state, false, true, true), "not when released")
end)

t.test("without auto hop the key must be released between jumps", function()
    local state = { latched = false }
    t.truthy(physics.wantJump(state, true, true, false), "first press jumps")
    t.falsy(physics.wantJump(state, true, false, false))
    t.falsy(physics.wantJump(state, true, true, false), "still held on landing: no jump")
    t.falsy(physics.wantJump(state, false, true, false), "released")
    t.truthy(physics.wantJump(state, true, true, false), "pressed again")
end)

t.test("without auto hop a press in the air is used up", function()
    local state = { latched = false }
    t.falsy(physics.wantJump(state, true, false, false), "pressed in the air")
    t.falsy(physics.wantJump(state, true, true, false), "held through the landing")
end)

-- A whole bunny hop run: jump, fly, land, jump again, with air strafing. Gravity and
-- landing are simulated here the way the game does it.
local function simulateHops(seconds, strafe)
    local dt = 1 / 100
    local vx, vy, vz = P.maxSpeed, 0, 0
    local z = 0
    local onGround = true
    local yaw = 0
    local state = { latched = false }
    local hops = 0
    for _ = 1, math.floor(seconds / dt) do
        local wx, wy, wishSpeed = 0, 0, 0
        if strafe and not onGround then
            yaw = yaw + 1.5 -- turning right while holding the right key
            wx, wy, wishSpeed = physics.wish(yaw, 0, 1, P.inputSpeed, P.maxSpeed)
        end
        local jump = physics.wantJump(state, true, onGround, true)
        local jumped
        vx, vy, vz, jumped = physics.step(vx, vy, vz, onGround, wx, wy, wishSpeed, jump, P, dt)
        if jumped then
            onGround = false
            hops = hops + 1
        end
        if not onGround then
            vz = vz - P.gravity * dt
            z = z + vz * dt
            if z <= 0 then
                z, vz, onGround = 0, 0, true
            end
        end
    end
    return math.sqrt(vx * vx + vy * vy), hops
end

t.test("holding jump keeps the speed across many hops", function()
    local speed, hops = simulateHops(5, false)
    t.truthy(hops >= 6, "hopped " .. hops .. " times")
    t.near(speed, P.maxSpeed, 1e-6, "no speed lost")
end)

t.test("air strafing while hopping builds speed past the max speed", function()
    local speed = simulateHops(5, true)
    t.truthy(speed > P.maxSpeed * 1.3, string.format("speed %.1f should be well above %.1f", speed, P.maxSpeed))
end)

-- About one hop's worth of air strafing (0.6 s) from 320 u/s: the right key held
-- and the view turning right at turnRate degrees per second, at a given frame rate.
local function airStrafe(fps, rate, turnRate)
    local sim = { yaw = 0 }
    local vx, vy, vz = 320, 0, 0
    local yaw = 0
    local dt = 1 / fps
    for _ = 1, math.floor(0.6 * fps + 0.5) do
        yaw = yaw + turnRate * dt
        vx, vy, vz = physics.simulate(sim, vx, vy, vz, false, yaw, { forward = 0, right = 1 }, false, P, dt, rate)
    end
    return math.sqrt(vx * vx + vy * vy)
end

t.test("at a low frame rate, one update per frame gains little from air strafing", function()
    local at30 = airStrafe(30, 0, 300)
    local at100 = airStrafe(100, 0, 300)
    t.truthy(at30 < 340, string.format("30 fps, once per frame: %.1f", at30))
    t.truthy(at100 > 375, string.format("100 fps, once per frame: %.1f", at100))
end)

t.test("updates at 100 a second air strafe the same at any frame rate", function()
    local reference = airStrafe(100, 0, 300)
    for _, fps in ipairs({ 20, 30, 45, 60, 120, 240 }) do
        local speed = airStrafe(fps, 100, 300)
        t.truthy(math.abs(speed - reference) < reference * 0.02,
            string.format("%d fps: %.1f, at 100 fps once per frame: %.1f", fps, speed, reference))
    end
end)

t.test("ground running still settles at the max speed with updates at 100 a second", function()
    local sim = {}
    local vx, vy, vz = 0, 0, 0
    for _ = 1, 60 do
        vx, vy, vz = physics.simulate(sim, vx, vy, vz, true, 0, { forward = 1, right = 0 }, false, P, 1 / 30, 100)
    end
    t.near(math.sqrt(vx * vx + vy * vy), P.maxSpeed, 1e-6)
end)

t.test("leftover time is carried to the next frame", function()
    local sim = {}
    local _, _, _, _, steps = physics.simulate(sim, 0, 0, 0, true, 0, nil, false, P, 0.015, 100)
    t.eq(steps, 1)
    t.near(sim.time, 0.005, 1e-9)
    _, _, _, _, steps = physics.simulate(sim, 0, 0, 0, true, 0, nil, false, P, 0.015, 100)
    t.eq(steps, 2, "the 5 ms left over plus 15 ms")
    t.near(sim.time, 0, 1e-9)
end)

t.test("a very long frame runs at most 25 updates", function()
    local sim = {}
    local _, _, _, _, steps = physics.simulate(sim, 0, 0, 0, true, 0, nil, false, P, 1, 100)
    t.eq(steps, 25)
    t.eq(sim.time, 0, "the rest is dropped, not carried")
end)

t.test("the view's turn is spread over the steps the short way round", function()
    t.eq(physics.turn(170, -170), 20)
    t.eq(physics.turn(-170, 170), -20)
    t.eq(physics.turn(10, 350), -20)
    local sim = { yaw = 170 }
    local wish = { forward = 1, right = 0 }
    local vx, vy = physics.simulate(sim, 0, 0, 0, false, -170, wish, false, P, 0.02, 100)
    -- Two steps, with the view at 180 and then at 190 (-170), never through 0.
    local ex, ey = 0, 0
    for _, yaw in ipairs({ 180, 190 }) do
        local wx, wy, speed = physics.wish(yaw, 1, 0, P.inputSpeed, P.maxSpeed)
        ex, ey = physics.step(ex, ey, 0, false, wx, wy, speed, false, P, 0.01)
    end
    t.near(vx, ex, 1e-9)
    t.near(vy, ey, 1e-9)
    t.truthy(vx < 0, "accelerated towards yaw 180")
    t.eq(sim.yaw, -170)
end)

t.test("a jump starts on the first step only, and even in a frame too short for a step", function()
    local sim = {}
    local _, _, vz, jumped, steps = physics.simulate(sim, 320, 0, 0, true, 0, nil, true, P, 1 / 30, 100)
    t.truthy(jumped)
    t.eq(steps, 3)
    t.near(vz, P.jumpSpeed, 1e-9, "one jump, not three")
    _, _, vz, jumped, steps = physics.simulate({}, 320, 0, 0, true, 0, nil, true, P, 0.004, 100)
    t.eq(steps, 0)
    t.truthy(jumped, "jumped without waiting for a step")
    t.near(vz, P.jumpSpeed, 1e-9)
end)

t.test("a rate of 0 is one update per frame", function()
    local sim = {}
    local vx, vy, vz, jumped, steps = physics.simulate(sim, 320, 0, 0, false, 30, { forward = 0, right = 1 },
        false, P, 1 / 30, 0)
    local wx, wy, speed = physics.wish(30, 0, 1, P.inputSpeed, P.maxSpeed)
    local ex, ey, ez = physics.step(320, 0, 0, false, wx, wy, speed, false, P, 1 / 30)
    t.eq(steps, 1)
    t.falsy(jumped)
    t.near(vx, ex, 1e-9)
    t.near(vy, ey, 1e-9)
    t.near(vz, ez, 1e-9)
end)
