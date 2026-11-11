-- Half-Life's slopes (SlopeLandings, SlopeBoosts): the maths, and main.lua against the
-- fake game, whose walking follows a terrain (g.terrain) and fills CurrentFloor. Also
-- the air strafing check behind the strafe gain answer.

local t = require("testlib")
local fake = require("fake_game")
local physics = require("hl1movement.physics")
local settings = require("hl1movement.settings")

local root = TEST_ROOT
local F6, F8 = 0x75, 0x77
local SCALE = 2.5
local MAX_SPEED = 320 * SCALE
local JUMP_SPEED = math.sqrt(2 * 800 * SCALE * 45 * SCALE)
local GRAVITY = 800 * SCALE
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone

local function start(config, options)
    local g = fake.newGame(options)
    fake.useConfig(config)
    fake.loadMod(root)
    return g
end

local function running(config, options)
    local g = start(config, options)
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    return g
end

local function noErrors(g)
    t.absent(g.log, "Error in", "the mod logged an error")
    t.absent(g.log, "Turned off", "the mod turned something off")
end

local function count(lines, text)
    local n = 0
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function runTo(g, speed)
    g.keys.W = true
    for _ = 1, 600 do
        g.frame()
        if g.speed() >= speed - 0.5 then
            return
        end
    end
    error("never reached " .. speed)
end

-- Flat at Z = 0 up to x0, a slope of `angle` degrees going up along +X (down for a
-- negative angle) to x1, then flat again.
local function ramp(angle, x0, x1)
    local a = math.rad(angle)
    local tan, s, c = math.tan(a), math.sin(a), math.cos(a)
    return function(x)
        if x <= x0 then
            return 0, 0, 0, 1
        elseif x >= x1 then
            return (x1 - x0) * tan, 0, 0, 1
        end
        return (x - x0) * tan, -s, 0, c
    end
end

-- Runs along +X at `speed` cm/s until x, keeping the speed up against the mod's friction.
local function runFastTo(g, speed, x)
    g.keys.W = true
    for _ = 1, 600 do
        if g.position.X >= x then
            break
        end
        fake.props(g.cmc).Velocity.X = speed
        g.frame()
    end
    g.keys.W = false
end

local function velocityZ(g)
    return fake.props(g.cmc).Velocity.Z
end

-- Runs frames until the movement mode becomes `mode`, at most `limit` frames. Returns
-- how many frames that took, or nil.
local function untilMode(g, mode, limit)
    for i = 1, limit or 200 do
        g.frame()
        if g.mode() == mode then
            return i
        end
    end
    return nil
end

-- Jumps from where the character is, and lets go of the key.
local function jump(g)
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3, "jumped")
    g.keys.SpaceBar = false
end

-- The maths ----------------------------------------------------------------------

t.test("clip takes out the part of the velocity going into a surface (overbounce 1)", function()
    -- Landing at 400 u/s falling 500 u/s on a 30 degree slope going down ahead.
    local s, c = math.sin(math.rad(30)), math.cos(math.rad(30))
    local vx, vy, vz = physics.clip(400, 0, -500, s, 0, c)
    t.near(vx, 400 + (500 * c - 400 * s) * s, 1e-9, "faster down the slope")
    t.eq(vy, 0)
    t.near(vx * s + vz * c, 0, 1e-9, "what is left runs along the slope")
    t.truthy(vx > 500, "the fall turned into speed: " .. vx)
end)

t.test("clip: falling straight down at 2000 u/s on a 45 degree slope leaves 1000 u/s along it", function()
    local n = math.sqrt(0.5)
    local vx, _, vz = physics.clip(0, 0, -2000, n, 0, n)
    t.near(vx, 1000, 1e-9)
    t.near(vz, -1000, 1e-9)
end)

t.test("clip: running into an upward slope turns some of the speed into rising", function()
    local s, c = math.sin(math.rad(20)), math.cos(math.rad(20))
    local vx, _, vz = physics.clip(1000, 0, 0, -s, 0, c)
    t.near(vz, 1000 * s * c, 1e-9, "rising 1000 sin cos")
    t.near(vx, 1000 * c * c, 1e-9)
end)

t.test("clip leaves a velocity that doesn't go into the surface", function()
    local vx, vy, vz = physics.clip(300, 20, 100, 0, 0, 1)
    t.eq(vx, 300)
    t.eq(vy, 20)
    t.eq(vz, 100)
end)

t.test("the slope settings are on by default, take only true or false, and use Half-Life's 180 u/s", function()
    t.eq(settings.DEFAULTS.SlopeLandings, true)
    t.eq(settings.DEFAULTS.SlopeBoosts, true)
    local cfg, warnings = settings.load({ SlopeLandings = false, SlopeBoosts = "yes" })
    t.eq(cfg.SlopeLandings, false)
    t.eq(cfg.SlopeBoosts, true, "the default stays")
    t.eq(#warnings, 1)
    t.truthy(warnings[1]:find("SlopeBoosts", 1, true), warnings[1])
    local P = settings.physics(cfg)
    t.near(P.airborneSpeed, 180 * SCALE, 1e-9)
    t.near(P.leaveHeight, 8 * SCALE, 1e-9)
end)

t.test("air strafing at 100 updates a second with the air cap 30 gains most per update at 90 degrees", function()
    -- In u/s (UnitScale 1), at 500 u/s with the wish direction turned from the velocity.
    local P = settings.physics((settings.load({ UnitScale = 1 })))
    local function gain(degrees)
        local a = math.rad(degrees)
        local vx, vy = physics.step(500, 0, 0, false, math.cos(a), math.sin(a), 320, false, P, 1 / 100)
        return vx * vx + vy * vy - 500 * 500
    end
    local best, bestAngle = -math.huge, nil
    for k = 8000, 10000 do
        local g = gain(k / 100)
        if g > best then
            best, bestAngle = g, k / 100
        end
    end
    t.near(bestAngle, 90, 0.011, "the best angle")
    t.near(best, 30 * 30, 1e-6, "the gain in v squared per update is the cap squared")
    t.truthy(gain(85) < best and gain(95) < best, "less on either side")
end)

-- Slides and launches ---------------------------------------------------------------

t.test("running fast up a slope slides you up it in the air and launches you off the top", function()
    local g = running()
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 2000, 300)
    -- The vertical speed the mod hands to Unreal's update (which walks it up the slope).
    local walk, handed = g.moveTick, nil
    g.moveTick = function(dt)
        handed = velocityZ(g)
        walk(dt)
    end
    local launched
    for _ = 1, 120 do
        g.frame()
        if g.mode() == 3 then
            launched = true
            break
        end
        t.eq(g.mode(), 1, "Unreal walks it up the slope meanwhile")
        t.eq(handed, 0, "with a horizontal velocity, as walking wants it (the mod keeps the rise)")
    end
    t.truthy(launched, "flew off")
    t.truthy(g.position.X >= 880, "at the top of the slope: " .. g.position.X)
    t.truthy(velocityZ(g) > 450, string.format("rising %.0f cm/s, over 180 u/s", velocityZ(g)))
    t.contains(g.log, "Slope: ran into a 20 degree slope at ")
    t.contains(g.log, "Slope: flew off the slope at ")
    t.contains(g.log, "First flight off a slope by the mod")
    g.frames(60)
    t.truthy(g.landings >= 1 and g.mode() == 1, "landed again")
    local line = t.contains(g.log, "s after flying off the slope, at ")
    local time = tonumber(line:match("landed ([%d%.]+) s after"))
    t.truthy(time and time > 0.2, "the time in the air: " .. line)
    noErrors(g)
end)

t.test("too slow to slide up a slope, the character walks up it as before", function()
    local g = running()
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 800, 300) -- 320 u/s: rising 103 u/s against it
    g.keys.W = true
    g.frames(90)
    t.eq(g.mode(), 1)
    t.truthy(g.position.X > 900, "walked over the top")
    t.absent(g.log, "Slope:")
    noErrors(g)
end)

t.test("SlopeBoosts = false: running fast up a slope just walks up it, as before", function()
    local g = running({ SlopeBoosts = false })
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 2000, 300)
    for _ = 1, 40 do
        g.frame()
        t.eq(g.mode(), 1)
    end
    t.absent(g.log, "Slope:")
    noErrors(g)
end)

-- Landings ----------------------------------------------------------------------

t.test("landing on a downward slope turns some of the fall into speed down it", function()
    local g = running()
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(-20, x + 50, x + 20000)
    jump(g)
    local before
    for _ = 1, 200 do
        before = g.speed()
        g.frame()
        if g.mode() == 1 then
            break
        end
    end
    g.frame()
    t.eq(g.mode(), 1, "landed on the slope")
    local line = t.contains(g.log, "Slope: landed on a 20 degree slope at ")
    t.truthy(g.speed() > before + 150, string.format("%.0f cm/s after landing, %.0f before (%s)", g.speed(), before,
        line))
    noErrors(g)
end)

t.test("landing on an upward slope costs speed, as in Half-Life", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.keys.W = false
    local x = g.position.X
    g.terrain = ramp(15, x + 150, x + 20000)
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.eq(g.mode(), 1)
    local line = t.contains(g.log, "Slope: landed on a 15 degree slope at 320 u/s")
    -- Falling 158 u/s onto it: 320 - (320 sin 15 + 158 cos 15) sin 15 = 259 u/s, less a frame of friction.
    t.truthy(line:find("falling 158 u/s: 259 u/s (-61)", 1, true), line)
    local speed = g.speed()
    t.truthy(speed <= 259 * SCALE and speed >= 259 * SCALE * 0.96 ^ 2 - 1, "then a frame of ground friction: " .. speed)
    noErrors(g)
end)

t.test("landing fast on an upward slope slides up it instead of landing", function()
    local g = running()
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(25, x + 300, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "Unreal landed it")
    g.frame()
    t.contains(g.log, "Slope: landed on a 25 degree slope at ")
    t.contains(g.log, "sliding up it at ")
    t.eq(g.mode(), 1, "Unreal walks it up the slope")
    noErrors(g)
end)

t.test("SlopeLandings = false: a landing on a slope keeps Unreal's speed, and a fast one still slides up it", function()
    local g = running({ SlopeLandings = false })
    runTo(g, MAX_SPEED)
    g.keys.W = false
    local x = g.position.X
    g.terrain = ramp(15, x + 150, x + 20000)
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.absent(g.log, "Slope:")
    -- (With SlopeLandings it would be 259 u/s, see above; here a frame of friction.)
    t.truthy(g.speed() > 280 * SCALE, string.format("no slope loss: %.0f cm/s", g.speed()))

    g = running({ SlopeLandings = false })
    runTo(g, MAX_SPEED)
    x = g.position.X
    g.terrain = ramp(25, x + 300, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "Unreal landed it")
    g.frame()
    t.contains(g.log, "sliding up it at ")
    noErrors(g)
end)

t.test("SlopeBoosts = false: a fast landing on an upward slope lands with the slope's speed, without a slide",
    function()
        local g = running({ SlopeBoosts = false })
        runTo(g, MAX_SPEED)
        local x = g.position.X
        g.terrain = ramp(25, x + 300, x + 20000)
        fake.props(g.cmc).Velocity.X = 2000
        jump(g)
        t.truthy(untilMode(g, 1), "Unreal landed it")
        g.frame()
        local line = t.contains(g.log, "Slope: landed on a 25 degree slope at 800 u/s")
        t.truthy(line:match(": (%d+) u/s %(%-(%d+)%)$"), line)
        t.truthy(line:find("u/s, rising %d+ u/s: "), "it hit the slope while still rising: " .. line)
        t.absent(g.log, "falling -")
        t.absent(g.log, "sliding up it")
        g.frames(5)
        t.eq(g.mode(), 1)
        t.truthy(g.speed() < 800 * SCALE, "slower uphill")
        noErrors(g)
    end)

t.test("with both off, slopes are Unreal's: the floor isn't even read", function()
    local g = running({ SlopeLandings = false, SlopeBoosts = false })
    local reads = 0
    fake.onRead(g.cmc, "CurrentFloor", function()
        reads = reads + 1
    end)
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(-20, x + 50, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    local speed = g.speed()
    t.truthy(speed <= 2000 and speed >= 2000 * 0.96 ^ 2 - 1, "the horizontal speed is kept, less friction: "
        .. speed)
    t.eq(reads, 0)
    t.absent(g.log, "Slope:")
    noErrors(g)
end)

-- Jumping -------------------------------------------------------------------------

t.test("sliding up a slope, a held jump waits until the slide ends, as in Half-Life", function()
    local g = running()
    g.terrain = ramp(20, 300, 20000)
    runFastTo(g, 2000, 300)
    g.frame()
    t.contains(g.log, "Slope: ran into a 20 degree slope at ")
    g.keys.SpaceBar = true
    local slid = untilMode(g, 3)
    t.truthy(slid and slid > 30, "slid for " .. tostring(slid) .. " frames before jumping")
    t.contains(g.log, "Slope: the slide up the slope ended at ")
    t.near(velocityZ(g), JUMP_SPEED, 60, "a jump, not a launch")
    t.contains(g.log, "First jump by the mod")
    noErrors(g)
end)

t.test("holding jump as you run into a slope jumps: Half-Life jumps before its ground move", function()
    local g = running()
    -- (15 degrees: at 2000 cm/s a steeper slope rises faster than the jump, and Unreal
    -- would land it again at once.)
    g.terrain = ramp(15, 300, 20000)
    runFastTo(g, 2000, 300)
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3, "jumped")
    t.absent(g.log, "Slope: ran into")
    t.near(velocityZ(g), JUMP_SPEED - GRAVITY / 60, 1)
    noErrors(g)
end)

t.test("tapping jump while sliding: the game's own jump is held back, as Half-Life doesn't jump in the air",
    function()
        local g = running()
        g.terrain = ramp(15, 300, 2000)
        runFastTo(g, 2000, 300)
        g.frames(3)
        t.contains(g.log, "Slope: ran into a 15 degree slope")
        g.keys.SpaceBar = true
        g.frame()
        g.keys.SpaceBar = false
        t.eq(g.stoppedJumps, 1, "the game's press was taken back")
        t.eq(g.gameJumps, 0, "the game didn't jump")
        t.contains(g.log, "Holding back the game's own jump while sliding up a slope (StopJumping)")
        g.frames(10)
        t.eq(g.mode(), 1, "still sliding up it")
        t.absent(g.log, "the game jumped while sliding")
        t.absent(g.log, "off the end of the slope")
        noErrors(g)
    end)

t.test("if the mod can't see the game's jump press, the game's jump while sliding counts as a jump", function()
    local g = running(nil, { noPressedJump = true })
    g.terrain = ramp(15, 300, 2000)
    runFastTo(g, 2000, 300)
    g.frames(3)
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    t.eq(g.gameJumps, 1, "the game jumped")
    t.eq(g.mode(), 3)
    g.frame()
    t.contains(g.log, "Slope: the game jumped while sliding up the slope")
    t.absent(g.log, "off the end of the slope")
    t.truthy(velocityZ(g) > JUMP_SPEED - 3 * GRAVITY / 60, string.format("rising %.0f cm/s", velocityZ(g)))
    noErrors(g)
end)

-- Edges of the rules --------------------------------------------------------------------

t.test("a step's edge, where the capsule's contact leans but the surface doesn't, isn't a slope", function()
    local g = running()
    g.terrain = ramp(20, 300, 900)
    g.contactNormal = function()
        return 0.6, 0, 0.8
    end
    runFastTo(g, 2000, 300)
    g.frames(30)
    t.absent(g.log, "Slope:")
    noErrors(g)
end)

t.test("a floor normal that can't be read leaves slopes to Unreal, with one line in the log", function()
    local g = running(nil, { floorNormalUnreadable = true })
    runFastTo(g, 2000, 1500) -- 45 frames at 800 u/s, each reading the floor
    g.terrain = ramp(20, g.position.X + 100, g.position.X + 900)
    runFastTo(g, 2000, g.position.X + 300)
    g.frames(30)
    t.eq(count(g.log, "Could not read the normal of the floor"), 1)
    t.absent(g.log, "Slope:")
    g.press(F8)
    t.contains(g.log, "; off: the floor's normal can't be read")
    noErrors(g)
end)

t.test("...but only after 30 reads in a row: a floor that reads, even one the mod can't use, starts the count again",
    function()
        local g = running(nil, { floorNormalUnreadable = true })
        local floor = fake.props(g.cmc).CurrentFloor
        g.keys.W = true
        for i = 1, 80 do
            floor.bLineTrace = i % 2 == 0 -- found by a line trace: readable, but not used
            fake.props(g.cmc).Velocity.X = 2000
            g.frame()
        end
        t.absent(g.log, "Could not read the normal of the floor")
        floor.bLineTrace = false
        for _ = 1, 40 do
            fake.props(g.cmc).Velocity.X = 2000
            g.frame()
        end
        t.eq(count(g.log, "Could not read the normal of the floor"), 1)
        noErrors(g)
    end)

t.test("a bumpy slope doesn't launch and land again and again", function()
    -- 25 degrees on average, in 1 m segments of 21 and 29 degrees, like a landscape.
    local g = running()
    local x0, heights = 300, { [0] = 0 }
    local function angle(i)
        return math.rad(25 + (i % 2 == 0 and 4 or -4))
    end
    for i = 1, 200 do
        heights[i] = heights[i - 1] + 100 * math.tan(angle(i))
    end
    g.terrain = function(x)
        if x <= x0 then
            return 0, 0, 0, 1
        end
        local i = math.floor((x - x0) / 100) + 1
        return heights[i - 1] + (x - x0 - (i - 1) * 100) * math.tan(angle(i)), -math.sin(angle(i)), 0,
            math.cos(angle(i))
    end
    runFastTo(g, 2000, x0)
    local changes, last = 0, g.mode()
    g.frames(240, nil, function()
        if g.mode() ~= last then
            changes, last = changes + 1, g.mode()
        end
    end)
    t.contains(g.log, "Slope: ran into a 21 degree slope")
    t.contains(g.log, "Slope: the slide up the slope ended")
    t.eq(changes, 0, "no launches and landings on the way up")
    t.eq(g.landings, 0)
    noErrors(g)
end)

t.test("Unreal walking off the end of a slope during a slide keeps the slide's rise", function()
    local g = running()
    local x0, x1 = 300, 700
    local top = (x1 - x0) * math.tan(math.rad(20))
    local slope = ramp(20, x0, x1)
    g.terrain = function(x)
        if x >= x1 then
            return top - 300, 0, 0, 1 -- a drop at the top: Unreal walks off it
        end
        return slope(x)
    end
    runFastTo(g, 2000, x0)
    t.truthy(untilMode(g, 3, 60), "off the end")
    t.absent(g.log, "flew off the slope")
    g.frame()
    t.contains(g.log, "Slope: off the end of the slope at ")
    t.truthy(velocityZ(g) > 400, string.format("rising %.0f cm/s as it slid, not falling", velocityZ(g)))
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.contains(g.log, "s after flying off the slope, at ")
    g.press(F8)
    t.contains(g.log, "slides up one 1, flights off one 1,")
    noErrors(g)
end)

t.test("a frame longer than Unreal's MaxSimulationTimeStep before a landing: no slope clip and no slide", function()
    for _, case in ipairs({ { -20, 0.05 }, { 25, 0.05 }, { -20, 0.1 } }) do
        local angle, maxStep = case[1], case[2]
        local g = start()
        fake.props(g.cmc).MaxSimulationTimeStep = maxStep -- read as the mod takes over
        g.loadSave()
        g.frames(SETTLE_FRAMES)
        runTo(g, MAX_SPEED)
        local x = g.position.X
        g.terrain = ramp(angle, x + 150, x + 20000)
        fake.props(g.cmc).Velocity.X = angle > 0 and 2000 or MAX_SPEED
        jump(g)
        local speed
        for _ = 1, 200 do
            -- Where a frame of 0.06 s would take it (the fake's gravity comes first).
            local v = fake.props(g.cmc).Velocity
            local z = g.position.Z + (v.Z - GRAVITY * 0.06) * 0.06
            if z <= g.groundAt(g.position.X + v.X * 0.06, 0) then
                speed = g.speed()
                g.frame(0.06) -- Unreal moves it in two steps, and lands in one of them
                break
            end
            g.frame()
            t.eq(g.mode(), 3, "still in the air")
        end
        t.eq(g.mode(), 1, "landed in the long frame")
        g.frame()
        if maxStep < 0.06 then
            t.absent(g.log, "Slope:", "slope " .. angle)
            t.truthy(g.speed() <= speed + 1e-6, string.format("slope %d: %.0f cm/s, %.0f before", angle, g.speed(),
                speed))
        else
            -- Unreal moves a frame up to its MaxSimulationTimeStep in one step.
            t.contains(g.log, "Slope: landed on a 20 degree slope")
        end
        noErrors(g)
    end
end)

-- With the rest of the mod -------------------------------------------------------------

t.test("KeepSpeed: the game's landing cut is undone before the slope's clip, and a slide brings no cut lines",
    function()
        local options = { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true }
        local g = running(nil, options)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        local x = g.position.X
        g.terrain = ramp(15, x + 150, x + 20000)
        jump(g)
        t.truthy(untilMode(g, 1), "landed")
        g.frame()
        t.contains(g.log, "to 260 u/s (on landing")
        -- The same as without the game's cut (see above): the clip starts from 320 u/s.
        t.contains(g.log, "Slope: landed on a 15 degree slope at 320 u/s, falling 158 u/s: 259 u/s (-61)")

        g = running(nil, options)
        g.terrain = ramp(20, 300, 900)
        runFastTo(g, 2000, 300)
        local cuts = count(g.log, "The game cut the speed")
        t.truthy(untilMode(g, 3, 120), "flew off")
        t.eq(count(g.log, "The game cut the speed"), cuts, "no cuts while it slid")
        g.frame()
        local line = t.contains(g.log, "after flying off a slope")
        t.truthy(line:find("the speed is kept", 1, true), line)
        noErrors(g)
    end)

t.test("a pause during a slide keeps it", function()
    local g = running()
    g.terrain = ramp(20, 300, 1500)
    runFastTo(g, 2000, 300)
    g.frames(7)
    t.contains(g.log, "Slope: ran into a 20 degree slope")
    local x = g.position.X
    g.paused = true
    g.frames(12)
    t.eq(g.position.X, x, "nothing moves while paused")
    g.paused = false
    t.truthy(untilMode(g, 3, 120), "flew off the top")
    t.eq(count(g.log, "Slope: ran into"), 1, "the same slide went on")
    t.absent(g.log, "the slide up the slope ended")
    t.contains(g.log, "Slope: flew off the slope at ")
    noErrors(g)
end)

t.test("nav-mesh walking has no slope physics", function()
    local g = running()
    local reads = 0
    fake.onRead(g.cmc, "CurrentFloor", function()
        reads = reads + 1
    end)
    g.terrain = ramp(20, 300, 900)
    fake.props(g.cmc).MovementMode = 2
    runFastTo(g, 2000, 300)
    g.frames(30)
    t.eq(g.mode(), 2)
    t.absent(g.log, "Slope:")
    t.eq(reads, 0, "the floor isn't read")
    noErrors(g)
end)

t.test("a slide on a moving platform: the platform's velocity isn't taken for the character's, nor added", function()
    local g = running()
    g.baseVelocity = { X = 0, Y = 300, Z = 0 } -- the platform moves sideways
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 2000, 300)
    t.truthy(untilMode(g, 3, 120), "flew off")
    local launched = g.speed()
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    local v = fake.props(g.cmc).Velocity
    t.truthy(math.abs(v.Y) < 5, string.format("relative to the platform again: Y %.1f cm/s", v.Y))
    t.truthy(math.abs(v.X) < launched, string.format("no speed added: %.0f cm/s, %.0f at the launch", v.X,
        launched))
    t.absent(g.log, "The game cut the speed")
    t.absent(g.log, "Something in the game changed the velocity")
    noErrors(g)
end)

t.test("flights off a slope aren't hops: their own lines, no hop line, not in the strafing stats", function()
    local g = running()
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 2000, 300)
    t.truthy(untilMode(g, 3, 120), "flew off")
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.contains(g.log, "Slope: landed ")
    t.absent(g.log, "Hop ")
    g.keys.SpaceBar = true
    t.truthy(untilMode(g, 3), "a hop")
    g.keys.SpaceBar = false
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.contains(g.log, "Hop 1 (")
    t.eq(count(g.log, "Hop "), 1)
    local status
    for _ = 1, 700 do
        g.frame()
        status = g.log[#g.log]:find("Status (10s)", 1, true) and g.log[#g.log] or status
        if status then
            break
        end
    end
    t.truthy(status, "a status line")
    t.truthy(status:find("1 hops", 1, true), status)
    t.truthy(status:find("slopes: 0 landings on one (+0 u/s in all), 1 slides up one, 1 flights off one", 1, true),
        status)
    noErrors(g)
end)

t.test("the hop line says how much a landing on a slope changed the speed", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.keys.W = false
    local x = g.position.X
    g.terrain = ramp(15, x + 150, x + 20000)
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    local line = t.contains(g.log, "Hop 1 (")
    t.truthy(line:find("landing 320 u/s (+0), slope -61, ", 1, true), line)
    noErrors(g)
end)

t.test("landing lines: only those that matter, at most 5", function()
    -- Hopping down a 1.5 degree slope: each landing gains about 7 u/s, not logged.
    local g = running()
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(-1.5, x + 50, x + 1e6)
    g.keys.SpaceBar = true
    g.frames(300)
    t.absent(g.log, "Slope:")
    t.contains(g.log, ", slope +7, ")
    g.press(F8)
    local slopes
    for _, line in ipairs(g.log) do
        slopes = line:find("  slopes (SlopeLandings", 1, true) and line or slopes -- the last report's
    end
    local landings = tonumber(slopes:match("landings on one (%d+)"))
    t.truthy(landings and landings >= 6, slopes)

    -- Down a 10 degree slope, every landing is logged, up to 5.
    g = running()
    runTo(g, MAX_SPEED)
    x = g.position.X
    g.terrain = ramp(-10, x + 50, x + 1e6)
    g.keys.SpaceBar = true
    g.frames(600)
    t.eq(count(g.log, "Slope: landed on a 10 degree slope"), 5)
    t.contains(g.log, "(further landings on slopes aren't logged)")
    noErrors(g)
end)

t.test("slide and flight lines: at most 10", function()
    -- Ramps of 20 degrees with drops at their tops, one after the other.
    local g = running()
    local tan, s, c = math.tan(math.rad(20)), math.sin(math.rad(20)), math.cos(math.rad(20))
    g.terrain = function(x)
        local d = (x - 300) % 900
        if x < 300 or d >= 300 then
            return 0, 0, 0, 1
        end
        return d * tan, -s, 0, c
    end
    g.keys.W = true
    for _ = 1, 600 do
        fake.props(g.cmc).Velocity.X = 2000
        g.frame()
    end
    t.truthy(count(g.log, "sliding up it") >= 3, "several slides")
    t.eq(count(g.log, "Slope: "), 10)
    t.contains(g.log, "(further slides and flights aren't logged)")
    noErrors(g)
end)

t.test("the report shows the floor, the floor settings, the slopes, the fall detector and ALS's landing", function()
    local g = running()
    g.terrain = ramp(20, 100, 2000)
    g.keys.W = true
    g.frames(60)
    t.eq(g.mode(), 1)
    g.press(F8)
    t.contains(g.log, "  Movement.CurrentFloor: bBlockingHit=true, bWalkableFloor=true, bLineTrace=false, "
        .. "FloorDist=2.150, LineDist=0, HitResult.ImpactNormal=(X=-0.342 Y=0.000 Z=0.940, 20.0 deg), "
        .. "HitResult.Normal=(X=-0.342 Y=0.000 Z=0.940, 20.0 deg)")
    for _, text in ipairs({ "Movement.WalkableFloorAngle = 44.765", "Movement.WalkableFloorZ = 0.710",
        "Movement.PerchRadiusThreshold = 0", "Movement.bUseFlatBaseForFloorChecks = false",
        "Movement.LedgeCheckThreshold = 4", "Movement.bCanWalkOffLedges = true",
        "Movement.MaxSimulationTimeStep = 0.050",
        "  slopes (SlopeLandings=true, SlopeBoosts=true): landings on one 0, slides up one 0, flights off one 0, "
            .. "the game's jumps held back while sliding 0, MaxSimulationTimeStep 0.050 s",
        "  BP_FallDetectorComponent: EnableKillDetection=true, KillDistance=3000, KillTime=4",
        "  ALS on landing: bRagdollOnLand=false, RagdollOnLandVelocity=1000, bBreakfallOnLand=true, "
            .. "BreakfallOnLandVelocity=700" }) do
        t.contains(g.log, text)
    end
    -- In the air the floor is cleared, and without these parts the report goes on.
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    fake.set(g.pawn, "BP_FallDetectorComponent", nil)
    g.press(F8)
    t.contains(g.log, "HitResult.ImpactNormal=(X=0.000 Y=0.000 Z=0.000), HitResult.Normal=(X=0.000 Y=0.000 Z=0.000)")
    t.contains(g.log, "  BP_FallDetectorComponent: not found")
    fake.set(g.cmc, "CurrentFloor", nil)
    g.press(F8)
    t.contains(g.log, "  Movement.CurrentFloor: not found")
    t.eq(count(g.log, "end of diagnostics"), 3 + count(g.log, "automatic, 3 s after"))
    noErrors(g)
end)

t.test("on flat ground below 360 u/s slopes cost nothing, and hops read the floor once per landing", function()
    local costs = {}
    for _, config in ipairs({ {}, { SlopeLandings = false, SlopeBoosts = false } }) do
        local g = running(config)
        g.frames(200) -- after the automatic report, which reads the floor too
        local reads = 0
        fake.onRead(g.cmc, "CurrentFloor", function()
            reads = reads + 1
        end)
        runTo(g, MAX_SPEED)
        g.frames(10)
        local calls, all = fake.counts.calls, fake.counts.reads
        g.frames(60)
        costs[#costs + 1] = { calls = fake.counts.calls - calls, reads = fake.counts.reads - all, floor = reads }
    end
    t.eq(costs[1].floor, 0, "the floor isn't read while walking at 320 u/s")
    t.eq(costs[1].calls, costs[2].calls, "the same game calls")
    t.eq(costs[1].reads, costs[2].reads, "the same reads")

    local g = running()
    g.frames(200)
    local reads = 0
    fake.onRead(g.cmc, "CurrentFloor", function()
        reads = reads + 1
    end)
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    local landings = g.landings
    g.frames(200)
    untilMode(g, 3) -- (each landing is handled on the frame after)
    t.truthy(g.landings - landings >= 4, "hopped")
    t.eq(reads, g.landings - landings, "one read per landing")
end)

t.test("third person: a flight off a slope turns the body towards where it flies, from the launch on", function()
    for _, platform in ipairs({ false, true }) do
        local g = running()
        g.press(F6) -- third person
        if platform then
            g.baseVelocity = { X = 0, Y = 300, Z = 0 } -- not where it heads, though it moves the character
        end
        g.terrain = ramp(20, 300, 900)
        runFastTo(g, 2000, 300)
        local resets
        for _ = 1, 120 do
            g.actorYaw = 60 -- the body faces away, as if ALS hadn't turned it yet
            resets = g.inAirResets
            g.frame()
            if g.mode() == 3 then
                break
            end
        end
        t.eq(g.mode(), 3, "flew off")
        t.eq(g.inAirResets, resets + 1, "ALS set its in-air rotation to the body's as it left the ground")
        local inAir = fake.props(g.pawn).InAirRotation.Yaw
        t.truthy(math.abs(inAir) < 3, string.format("platform %s: the in-air rotation is where it flies: %.1f",
            tostring(platform), inAir))
        t.truthy(g.actorYaw < 59, "the body turned towards it in the launch's own frame: " .. g.actorYaw)
        t.truthy(untilMode(g, 1), "landed")
        t.truthy(math.abs(g.actorYaw) < 20, "facing where it flew at the landing: " .. g.actorYaw)
        noErrors(g)
    end
end)
