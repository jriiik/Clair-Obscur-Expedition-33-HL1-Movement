-- Half-Life's slopes (SlopeLandings, SlopeBoosts): the maths, and main.lua against the
-- fake game, whose walking follows a terrain (g.terrain) and fills CurrentFloor. Also
-- the air strafing check behind the strafe gain answer, and two checks that the fake
-- game's flights are Unreal's (what the heights and distances measured here rest on).

local t = require("testlib")
local fake = require("fake_game")
local physics = require("hl1movement.physics")
local settings = require("hl1movement.settings")

local root = TEST_ROOT
local F6, F7, F8 = 0x75, 0x76, 0x77
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
-- dt: the length of a frame, if not 1/60 s.
local function runFastTo(g, speed, x, dt)
    g.keys.W = true
    for _ = 1, 2400 do
        if g.position.X >= x then
            break
        end
        fake.props(g.cmc).Velocity.X = speed
        g.frame(dt)
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

-- How far above the floor the character stands (cm): Unreal keeps a walking capsule
-- 1.9 to 2.4 cm above it, and so does the fake.
local function floorDist(g)
    return fake.props(g.cmc).CurrentFloor.FloorDist
end

-- A plane under the character where it stands, rising along +X at `angle` degrees
-- (falling for a negative angle): a hop along it lands on the plane it took off from.
local function plane(g, angle)
    local a = math.rad(angle)
    local tan, s, c = math.tan(a), math.sin(a), math.cos(a)
    local x0, z0 = g.position.X, g.position.Z - floorDist(g)
    return function(x)
        return z0 + (x - x0) * tan, -s, 0, c
    end
end

-- What a hop line says of its landing on a slope: "hit" (it ran into the slope),
-- "caught" (Half-Life's ground check set it down first: the speed stays), "slide",
-- "unknown" (the mod couldn't tell), or "flat" (no slope part).
local function landingKind(line)
    for text, kind in pairs({ ["(ran into it"] = "hit", ["speed kept (set down"] = "caught",
        ["(sliding up it)"] = "slide", ["(still in the air)"] = "slide", ["(can't tell"] = "unknown" }) do
        if line:find(text, 1, true) then
            return kind
        end
    end
    return "flat"
end

-- Hops along +X from `speed` u/s with W and Space held until `landings` hops have
-- landed (dt: the frame time, if not 1/60 s, or a function giving the length of each
-- frame from its number, 1 for the take-off's). Returns for each landing its hop line,
-- the kind of landing the line says it was, and the horizontal speed in u/s once the
-- frame that handled it is over (in the air again: the next hop's take-off speed).
local function hopAlong(g, speed, landings, dt)
    fake.props(g.cmc).Velocity.X = speed * SCALE
    g.keys.W, g.keys.SpaceBar = true, true
    local found, seen = {}, #g.log
    for frame = 1, 20000 do
        g.frame(type(dt) == "function" and dt(frame) or dt)
        for i = seen + 1, #g.log do
            if g.log[i]:find("] Hop ", 1, true) then
                found[#found + 1] = { line = g.log[i], kind = landingKind(g.log[i]), speed = g.speed() / SCALE }
            end
        end
        seen = #g.log
        if #found >= landings then
            return found
        end
    end
    error("only " .. #found .. " hops landed")
end

-- Half-Life's updates, step by step, for a player hopping with jump held along a plane
-- that rises along +X at `angle` degrees: a point above the plane, moved `rate` times a
-- second. Written from published descriptions of the engine's player movement, with
-- none of the mod's code. Each update: the ground check (not rising faster than 180 u/s
-- and less than 2 units above the floor's plane: on the ground, moved down to where a
-- player rests, 1/32 unit off the plane, the velocity untouched); on the ground, the
-- jump at once; half of the gravity; the move, which the floor stops 1/32 unit off its
-- plane if it would end behind it, the velocity clipped there and the rest of the move
-- along the floor; the ground check again; the other half of the gravity. Returns for
-- each landing its kind ("caught": the ground check found the floor; "hit": the move ran
-- into it and the update ended on the ground; "slide": it ended in the air, rising
-- faster than 180 u/s), the speed after it in u/s (after a slide: once it is on the
-- ground again), how many updates the hop took, and how far above the plane its last
-- update before the floor ended. (rate may also be a function giving the length of each
-- update from its number, 1 for the first hop's take-off: one update per frame.)
local function halfLifeHops(angle, speed, rate, landings)
    local tan, nx, nz = math.tan(math.rad(angle)), -math.sin(math.rad(angle)), math.cos(math.rad(angle))
    local dt, jumpSpeed, gravity = type(rate) == "number" and 1 / rate, math.sqrt(2 * 800 * 45), 800
    local rest = 1 / 32 / nz -- where a player rests above the plane, straight up
    local x, z, vx, vz = 0, rest, speed, 0
    local onGround, hitAt, update, found, jumpedAt, before = true, nil, 0, {}, 0, nil
    local function groundCheck(atEnd)
        local above = z - x * tan
        if vz > 180 or above >= 2 then
            return false
        end
        z = x * tan + math.min(above, rest)
        if not onGround then
            local kind = "caught"
            if hitAt then
                kind = (atEnd and hitAt == update) and "hit" or "slide"
            end
            found[#found + 1] = { kind = kind, speed = vx, updates = update - jumpedAt + 1,
                above = hitAt and before or above }
        end
        onGround = true
        return true
    end
    while #found < landings do
        groundCheck(false)
        update = update + 1
        if type(rate) == "function" then
            dt = rate(update)
        end
        if onGround then
            onGround, hitAt, vz, jumpedAt = false, nil, jumpSpeed, update
        end
        vz = vz - 0.5 * gravity * dt
        local left = dt
        for _ = 1, 2 do
            local above = z - x * tan
            local after = above + (vz - vx * tan) * left
            if after >= 0 then
                x, z = x + vx * left, z + vz * left
                break
            end
            local share = math.max(0, (above - rest) / (above - after))
            x, z = x + vx * left * share, z + vz * left * share
            local into = vx * nx + vz * nz
            vx, vz = vx - into * nx, vz - into * nz
            if not hitAt then
                hitAt, before = update, above
            end
            left = left * (1 - share)
        end
        if groundCheck(true) then
            vz = 0
        else
            vz = vz - 0.5 * gravity * dt
        end
    end
    return found
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

-- The fake game's flights --------------------------------------------------------------

t.test("the fake game's falling move is Unreal's: the mod's jump tops out at 45 units at 30, 60 and 144 fps",
    function()
        -- Unreal takes the frame's gravity off the velocity and moves a falling character
        -- with the average of the old and the new velocity, so a flight is the same at any
        -- frame rate. (Moved with the velocity after gravity, the jump topped out at 40.6,
        -- 42.8 and 44.1 units.)
        for _, fps in ipairs({ 30, 60, 144 }) do
            local g = running()
            local from = g.position.Z
            g.keys.SpaceBar = true
            g.frame(1 / fps)
            t.eq(g.mode(), 3, "jumped")
            g.keys.SpaceBar = false
            local top, frames = 0, 1
            for _ = 1, 400 do
                g.frame(1 / fps)
                frames = frames + 1
                top = t.max(top, g.position.Z - from)
                if g.mode() == 1 then
                    break
                end
            end
            t.eq(g.mode(), 1, "landed")
            t.near(top, 45 * SCALE, 0.05 * SCALE, fps .. " fps: the top of the jump (cm)")
            -- It took off from its gap above the floor and comes down until it touches the
            -- floor: 2.15 cm further, 3 ms more than Half-Life's 0.671 s (21, 41 and 98
            -- frames; 97 at 144 fps without the gap).
            local air = (JUMP_SPEED + math.sqrt(JUMP_SPEED ^ 2 + 2 * GRAVITY * fake.FLOOR_DIST)) / GRAVITY
            t.eq(frames, math.ceil(air * fps), fps .. " fps: frames until it touches the floor again")
            t.near(g.position.Z, from, 1e-9, "standing at its gap above the floor again")
            noErrors(g)
        end
    end)

t.test("the fake game keeps Unreal's gap: a walking character stands CurrentFloor.FloorDist above the floor, and a "
    .. "flight ends where it touches the floor", function()
    -- Unreal keeps a walking capsule 1.9 to 2.4 cm above the floor, measured straight down
    -- (2.15 after a landing, and whenever it finds it outside that), and says how far in
    -- CurrentFloor.FloorDist. A flight starts from there and ends where the capsule
    -- touches the floor. (0.3.0's fake stood on the floor itself while FloorDist said 2.15.)
    local g = running()
    local floor = fake.props(g.cmc).CurrentFloor
    local function gap()
        return g.position.Z - g.groundAt(g.position.X, g.position.Y)
    end
    t.near(gap(), 2.15, 1e-9, "standing")
    t.near(floor.FloorDist, 2.15, 1e-9)
    -- Up a ramp: where the floor changes by more than the band, the gap is 2.15 again.
    g.terrain = ramp(10, 100, 1e6)
    g.keys.W = true
    g.frames(60)
    g.keys.W = false
    g.frames(60)
    t.truthy(g.position.X > 200 and g.speed() == 0, "standing on the ramp")
    t.near(gap(), 2.15, 1e-9, "walked up a ramp")
    t.near(floor.FloorDist, 2.15, 1e-9)

    -- Over a gentle crease (level, then 1 degree down) the gap changes within the band,
    -- stays what it then is, and FloorDist says it.
    g = running()
    floor = fake.props(g.cmc).CurrentFloor
    g.terrain = ramp(-1, 105, 1e6)
    runFastTo(g, MAX_SPEED, 110)
    local wide = gap()
    t.truthy(wide > 2.16 and wide <= 2.4, "past the crease: " .. wide)
    t.near(floor.FloorDist, wide, 1e-9, "FloorDist is the gap")
    fake.props(g.cmc).Velocity.X = MAX_SPEED
    g.frames(5)
    t.near(gap(), wide, 1e-9, "walking on along the slope keeps it")
    -- A jump from there: in the air until the frame whose move reaches the floor, then
    -- lifted to 2.15 cm again.
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    t.eq(g.mode(), 3, "jumped")
    t.eq(floor.FloorDist, 0, "no floor in the air")
    local before, falling
    while g.mode() == 3 do
        before, falling = gap(), velocityZ(g)
        t.truthy(before > 0, "above the floor while in the air")
        g.frame()
    end
    local v = fake.props(g.cmc).Velocity
    local closing = (falling - GRAVITY / 60 / 2) + v.X * math.tan(math.rad(1))
    t.truthy(before + closing / 60 <= 0, string.format("it landed in the frame whose move reached the floor, from "
        .. "%.2f cm above it", before))
    t.near(gap(), 2.15, 1e-9, "landed: lifted to its gap again")
    t.near(floor.FloorDist, 2.15, 1e-9)
    noErrors(g)
end)

t.test("the fake game keeps Unreal's gap: a jump into a slope lands in its own frame only past it", function()
    -- Unreal walks the capsule about 2 cm above the floor, and a jump has to lose that
    -- against a rising floor before it can land. On 30 degrees at 60 fps the floor
    -- out-rises the jump's first frame from 453 u/s, and the gap as well from 543.
    -- (Both slope settings off: this is Unreal's own landing.)
    local function jumpFrom(runSpeed, least, most)
        local g = running({ SlopeBoosts = false, SlopeLandings = false })
        g.terrain = ramp(30, 300, 1e9)
        runFastTo(g, runSpeed * SCALE, 600) -- up the slope; the last frame's friction takes a little
        local speed = g.speed() / SCALE
        t.truthy(speed > least and speed < most, "the speed at the jump: " .. speed)
        g.keys.SpaceBar = true
        g.frame()
        t.contains(g.log, "First jump by the mod")
        noErrors(g)
        return g.mode()
    end
    t.eq(jumpFrom(520, 460, 535), 3, "between the two speeds the jump is still in the air after its own frame")
    t.eq(jumpFrom(680, 550, 680), 1, "above both, Unreal landed it again within the frame")
end)

t.test("the fake game's walk off the end of a ramp follows the ramp's line for that frame, as Unreal's does",
    function()
        -- Unreal's walking move goes along the line of the floor it starts on for the whole
        -- frame (MoveAlongFloor), also where that floor ends. (Both slope settings off: this
        -- is Unreal's own walk up the ramp.) The line is the terrain's, whatever UE4SS can
        -- read of CurrentFloor: the same with nothing of it to read.
        for _, unreadable in ipairs({ false, true }) do
            local g = running({ SlopeLandings = false, SlopeBoosts = false }, { floorNormalUnreadable = unreadable })
            if unreadable then
                fake.set(g.cmc, "CurrentFloor", nil)
            end
            runTo(g, MAX_SPEED)
            local tan = math.tan(math.rad(20))
            local x0 = g.position.X + 50
            local slope = ramp(20, x0, x0 + 400)
            g.terrain = function(x)
                if x >= x0 + 400 then
                    return 400 * tan - 300, 0, 0, 1 -- a drop at the top: Unreal walks off it
                end
                return slope(x)
            end
            local fromX, fromZ
            for _ = 1, 200 do
                fromX, fromZ = g.position.X, g.position.Z
                g.frame()
                if g.mode() == 3 then
                    break
                end
            end
            t.eq(g.mode(), 3, "walked off the end")
            t.truthy(fromX > x0 and fromX < x0 + 400, "from the ramp: " .. fromX)
            t.truthy(g.position.X > x0 + 400, "past its end: " .. g.position.X)
            t.near(g.position.Z, fromZ + (g.position.X - fromX) * tan, 0.01, "it climbed along the ramp's line "
                .. "meanwhile" .. (unreadable and ", with a floor UE4SS can't read" or ""))
            noErrors(g)
        end
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

t.test("running fast down a slope without jumping flies as in Half-Life: one update with friction per flight, none "
    .. "in the air, at any frame rate", function()
    -- Half-Life's ground move goes straight ahead and its ground check looks 2 units
    -- down: down 20 degrees the floor falls further than that in one update (of 1/100 s)
    -- from 540 u/s (2 less the 1/32 unit the player rests above the floor, over 0.01 x
    -- tan 20). Above that the player is in the air after each update on the ground, the
    -- only one with friction in its flight, which takes 0.04 of the speed (sv_friction 4
    -- over 0.01 s). Below, it stays on the ground and brakes on every update. (The
    -- reference model of Half-Life's movement takes off at 700, 672, 645, 619 and 595 u/s
    -- here, 0.64 s apart.)
    local function downhill(speed, fps, angle, w)
        local g = running()
        g.terrain = plane(g, -(angle or 20))
        g.frame(1 / fps)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        g.keys.W = w
        local air, frames = 0, 2 * fps
        local speeds = {}
        for i = 1, frames do
            g.frame(1 / fps)
            if g.mode() == 3 then
                air = air + 1
            end
            speeds[i] = g.speed() / SCALE
        end
        local takeoffs = {}
        for _, line in ipairs(g.log) do
            local v = line:match("Slope: flew off a %d+ degree slope going down it at (%d+) u/s")
            if v then
                takeoffs[#takeoffs + 1] = tonumber(v)
            end
        end
        noErrors(g)
        return g, air / frames, takeoffs, speeds
    end
    -- Below 100 frames a second a frame has two or more updates: the one after a landing
    -- has friction, the rest of the frame is in the air.
    for _, fps in ipairs({ 100, 144, 80, 60, 30 }) do
        local g, inAir, takeoffs = downhill(700, fps)
        t.truthy(inAir > 0.9, string.format("%d fps: in the air on %.0f %% of the frames", fps, inAir * 100))
        t.truthy(#takeoffs >= 3, string.format("%d fps: %d flights", fps, #takeoffs))
        t.eq(takeoffs[1], 700, "the first flight keeps the speed it was walking at")
        for k = 2, #takeoffs do
            local ratio = takeoffs[k] / takeoffs[k - 1]
            t.truthy(ratio >= 0.955 and ratio <= 0.965, string.format("%d fps: flight %d took off at %d u/s, after %d",
                fps, k, takeoffs[k], takeoffs[k - 1]))
        end
        local line = t.contains(g.log, "s after flying off the slope, at ")
        local time = tonumber(line:match("landed ([%d%.]+) s after"))
        -- 2 x 700 x tan 20 / 800 = 0.64 s
        t.truthy(time and time > 0.6 and time < 0.67, fps .. " fps: the time in the air: " .. line)
        t.contains(g.log, "the floor falls 2.5 units in one Half-Life update, out of the ground check's reach of 2")
    end
    -- Just above and below where the floor falls out of the ground check's reach.
    local _, _, takeoffs = downhill(545, 100)
    t.truthy(#takeoffs >= 1, "flies from 545 u/s")
    local g, inAir, none, speeds = downhill(535, 100)
    t.eq(#none, 0, "not from 535 u/s")
    t.eq(inAir, 0, "on the ground all the way")
    -- Friction on every update, as Half-Life's: 535 x 0.96^10 after 0.1 s.
    t.near(speeds[10], 535 * 0.96 ^ 10, 0.5, "braked on every update")
    t.absent(g.log, "Slope:")
    -- Steep enough, a plain run leaves the ground too (down 35 degrees from 280 u/s), where
    -- no slope can be slid up and the floor isn't read for that: Half-Life's player
    -- bounds down the slope at 320 u/s, in the air nearly all the time.
    local _, steepAir, steepTakeoffs, steepSpeeds = downhill(320, 80, 35, true)
    t.truthy(steepAir > 0.9, string.format("down 35 degrees: in the air on %.0f %% of the frames", steepAir * 100))
    t.truthy(#steepTakeoffs >= 3, #steepTakeoffs .. " flights")
    t.near(steepSpeeds[#steepSpeeds], 320, 1, "at running speed")
end)

t.test("a leap down a slope that runs into it as it lands gains what Half-Life's does: it comes down with the half "
    .. "update of gravity Half-Life's leaving update ended with", function()
    -- Half-Life's update that leaves the slope ends in the air, so the second half of its
    -- gravity stays on (-4 u/s at 100 updates a second); the mod's flight starts from the
    -- floor with none. On an even slope the last update above the slope comes out as high
    -- as Half-Life's all the same, but not the speed it comes down with. The reference model of
    -- Half-Life's movement the 0.3.1 review compared with, from the same speed: down 30
    -- degrees from 600 u/s the leaps take off at 600, 721.322, 692.469 and 831.131 u/s (the
    -- first landing runs into the slope, the second is set down, the third runs into it);
    -- without the half update the second leaves at 719.659 and the next landing runs into
    -- the slope too (862.348). With PhysicsRate 0 at 60 fps down 20 degrees from 700: 700,
    -- 653.333, 682.432, 636.936 and 664.919 (680.432 without it). At 30 fps the leaves
    -- after a landing come at one of the frame's updates, at 144 fps at a frame's start.
    local function takeoffs(angle, speed, fps, rate, howMany)
        local g = running({ PhysicsRate = rate })
        g.terrain = plane(g, -angle)
        g.frame(1 / fps)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        local found, last = {}, g.mode()
        for _ = 1, 6 * fps do
            g.frame(1 / fps)
            if g.mode() == 3 and last ~= 3 then
                found[#found + 1] = g.speed() / SCALE -- (nothing changes it in the air)
            end
            last = g.mode()
            if #found >= howMany then
                break
            end
        end
        noErrors(g)
        return found
    end
    local downThirty = { 600, 721.322, 692.469, 831.131 }
    for _, case in ipairs({ { 30, 600, 30, 100, downThirty }, { 30, 600, 80, 100, downThirty },
        { 30, 600, 144, 100, downThirty }, { 20, 700, 60, 0, { 700, 653.333, 682.432, 636.936, 664.919 } } }) do
        local angle, speed, fps, rate, ref = case[1], case[2], case[3], case[4], case[5]
        local found = takeoffs(angle, speed, fps, rate, #ref)
        t.eq(#found, #ref, string.format("%d degrees from %d u/s at %d fps: leaps", angle, speed, fps))
        for i, v in ipairs(ref) do
            t.near(found[i], v, 0.01, string.format("%d degrees from %d u/s at %d fps, PhysicsRate %d: leap %d",
                angle, speed, fps, rate, i))
        end
    end
end)

t.test("a slide starts where the ground clip's rise stays over 180 u/s until the next update (184 at the clip), and "
    .. "under 360 u/s the floor isn't even read", function()
    -- One frame on a slope of `angle` degrees at `speed` u/s: the game, and how often
    -- the mod read the floor in that frame.
    local function at(angle, speed)
        local g = running()
        g.frames(200) -- after the automatic report, which reads the floor too
        t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
        g.terrain = ramp(angle, 300, 30000)
        runFastTo(g, speed * SCALE, 320)
        local reads = 0
        fake.onRead(g.cmc, "CurrentFloor", function()
            reads = reads + 1
        end)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        g.frame()
        return g, reads
    end
    -- On 30 degrees the clip rises at sin 30 cos 30 = 0.433 of the speed: 186.2 u/s at
    -- 430 u/s, and 181.9 at 420, which Half-Life's next ground check has on the ground.
    local g, reads = at(30, 430)
    t.contains(g.log, "Slope: ran into a 30 degree slope at 430 u/s: sliding up it, rising 186 u/s")
    t.eq(reads, 1)
    noErrors(g)
    g, reads = at(30, 420)
    t.absent(g.log, "Slope:")
    t.eq(reads, 1, "fast enough for a steeper slope, so the floor is read")
    noErrors(g)
    -- The steepest slope Unreal walks (44.77 degrees) rises at just under half the speed,
    -- so nothing slower than 360 u/s can rise at 180: there the floor isn't read at all.
    -- (On 44 degrees: 185.9 u/s at 372 u/s, 182.4 at 365.)
    g, reads = at(44, 372)
    t.contains(g.log, "Slope: ran into a 44 degree slope at 372 u/s: sliding up it, rising 186 u/s")
    t.eq(reads, 1)
    noErrors(g)
    g, reads = at(44, 365)
    t.absent(g.log, "Slope:")
    t.eq(reads, 1, "over 360 u/s the floor is read")
    noErrors(g)
    g, reads = at(44, 355)
    t.absent(g.log, "Slope:")
    t.eq(reads, 0, "below 360 u/s the floor isn't read")
    noErrors(g)
end)

t.test("a slide ends once its rise is down to 180 u/s half an update of gravity on, and the character walks on",
    function()
        local g = running()
        g.terrain = ramp(20, 300, 30000)
        runFastTo(g, 2000, 300)
        for _ = 1, 200 do
            g.frame()
            if count(g.log, "Slope: the slide up the slope ended") > 0 then
                break
            end
        end
        local line = t.contains(g.log, "Slope: the slide up the slope ended at ")
        local speed, rise = line:match("ended at (%d+) u/s %(rising (%d+) u/s, not more than 180 at Half%-Life's next "
            .. "ground check%)")
        t.truthy(speed and rise, line)
        -- The line gives the rise its last clip left: at most 184 u/s (4 u/s are half an
        -- update's gravity), and over 177, since an update takes 7 u/s off it on 20
        -- degrees. There the rise is the horizontal speed times tan 20: 184 u/s at 506 u/s.
        t.truthy(tonumber(rise) >= 177 and tonumber(rise) <= 184, line)
        t.truthy(tonumber(speed) >= 486 and tonumber(speed) <= 506, line)
        t.eq(g.mode(), 1, "it walks on")
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

-- Half-Life has two kinds of landing. Its ground check runs once per update: a player
-- less than 2 units above a floor's plane is put on it with its velocity as it is. Only
-- if no update ends that close does the next one's move run into the floor, and only
-- then is the velocity clipped against it. 0.3.0 clipped every landing. The numbers in
-- these tests follow from the hop: along a plane at v u/s it is in the air 2 a / 800 s,
-- with a = 268.33 - v tan(angle) its rise from the plane at the take-off (u/s), and
-- a t - 400 t^2 units above where it took off t seconds after it. A player rests 1/32
-- unit off the floor's plane (0.03 units above it, straight up), and the heights in the
-- log are above that plane. The updates count from the take-off, PhysicsRate (100) a
-- second.

t.test("a landing that runs into a downward slope turns some of the fall into speed down it", function()
    -- Down 20 degrees from 576 u/s: a = 477.98, in the air 1.19495 s. The update that
    -- ends at 1.19 s leaves it 2.38 units above the slope's plane, out of the ground
    -- check's reach, so the next one runs into it: with that update's fall,
    -- 268.33 - 800 x 1.195 = 687.67 u/s (Half-Life moves with the speed half an update on).
    local g = running()
    g.terrain = plane(g, -20)
    local landed = hopAlong(g, 576, 2)
    t.eq(landed[1].kind, "hit", landed[1].line)
    t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154). It ran into "
        .. "the slope: the Half-Life update before it ended 2.4 units above the slope, out of the ground check's "
        .. "reach of 2")
    local s, c = math.sin(math.rad(20)), math.cos(math.rad(20))
    local clipped = 576 + (687.672 * c - 576 * s) * s
    t.near(landed[1].speed, clipped, 0.01, "the part of the velocity going into the slope is taken out")
    t.truthy(landed[1].line:find("landing 576 u/s (+0), slope +154 (ran into it from 2.4 u up), ", 1, true),
        landed[1].line)
    -- The next hop, from 729.63 u/s, is 1.3347 s long: 2.52 units up at 1.33 s, a hit again.
    t.eq(landed[2].kind, "hit", landed[2].line)
    t.truthy(landed[2].speed > clipped + 150, "faster again: " .. landed[2].speed)
    noErrors(g)
end)

t.test("a landing that runs into an upward slope costs speed", function()
    -- Up 5 degrees from 282 u/s: a = 243.66, in the air 0.6091 s, and 2.23 units above
    -- the slope's plane at 0.60 s: the next update runs into it, falling
    -- 268.33 - 800 x 0.605 = 215.67 u/s.
    local g = running()
    g.terrain = plane(g, 5)
    fake.props(g.cmc).Velocity.X = 282 * SCALE
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.eq(g.mode(), 1)
    local line = t.contains(g.log, "Slope: landed on a 5 degree slope at 282 u/s")
    -- 282 - (282 sin 5 + 215.67 cos 5) sin 5 = 261.13 u/s, less a frame of friction.
    t.truthy(line:find("falling 216 u/s: 261 u/s (-21). It ran into the slope: the Half-Life update before it ended "
        .. "2.2 units above the slope, out of the ground check's reach of 2", 1, true), line)
    local speed = g.speed()
    t.truthy(speed <= 261.14 * SCALE and speed >= 261.13 * SCALE * 0.96 ^ 2 - 1, "then a frame of ground friction: "
        .. speed)
    noErrors(g)
end)

t.test("Half-Life's player rests 1/32 unit off the floor: a move that ends between there and the floor isn't stopped",
    function()
        -- Up 5 degrees from 370 u/s: a = 235.96, in the air 0.5899 s. The update that ends
        -- at 0.59 s ends 0.025 units below where the player took off, but that was 0.031
        -- above the floor's plane: the move doesn't reach the floor, and the ground check
        -- finds the floor 0.006 units below the player. The player stays that low (the
        -- check moves it down to its resting height, never up), so its next hop, the same
        -- again, would end 0.019 units behind the floor: that one runs into it, from 2.30
        -- units up at 0.58 s. The third, from 349.85 u/s, is set down from 1.05 units.
        -- (With the heights taken from where the character stands, the first hop ran into
        -- the slope: so it was before the mod knew of the 1/32 unit.)
        local g = running()
        g.terrain = plane(g, 5)
        local landed = hopAlong(g, 370, 3)
        t.eq(landed[1].kind, "caught", landed[1].line)
        t.truthy(landed[1].line:find("slope: speed kept (set down from 0.0 u up), ", 1, true), landed[1].line)
        t.near(landed[1].speed, 370, 0.01)
        t.eq(landed[2].kind, "hit", landed[2].line)
        t.truthy(landed[2].line:find("slope -20 (ran into it from 2.3 u up), ", 1, true), landed[2].line)
        t.near(landed[2].speed, 349.853, 0.01)
        t.eq(landed[3].kind, "caught", landed[3].line)
        t.truthy(landed[3].line:find("slope: speed kept (set down from 1.0 u up), ", 1, true), landed[3].line)
        noErrors(g)
    end)

t.test("a landing an update ends within 2 units above keeps its speed, as Half-Life's ground check sets it down",
    function()
        -- Up 15 degrees from 320 u/s: a = 182.59, in the air 0.4565 s, and 1.16 units above
        -- the slope at 0.45 s: the ground check puts the player on the slope there, with
        -- its velocity as it is, and the held jump starts at once. 0.3.0 clipped this
        -- landing too and took 50 u/s.
        local g = running()
        g.terrain = plane(g, 15)
        local landed = hopAlong(g, 320, 3)
        for i = 1, 3 do
            t.eq(landed[i].kind, "caught", landed[i].line)
            t.near(landed[i].speed, 320, 0.01, "landing " .. i .. " keeps the speed")
        end
        t.truthy(landed[1].line:find("landing 320 u/s (+0), slope: speed kept (set down from 1.2 u up), ", 1, true),
            landed[1].line)
        t.contains(g.log, "Slope: landed on a 15 degree slope at 320 u/s: the speed stays. A Half-Life update ended "
            .. "1.2 units above the slope, within the ground check's reach of 2, which sets you down before you run "
            .. "into it")
        t.absent(g.log, "It ran into the slope")
        t.absent(g.log, "sliding up it")
        noErrors(g)
    end)

t.test("a height within 0.05 units of the ground check's 2 reads to 0.01, cut: under 2 if set down, 2 or more if not",
    function()
        -- Up 10 degrees from 30 u/s, with only Space held (W would add speed in the air
        -- below 30 u/s), the update before the floor ends 2.0067 units above the slope's
        -- plane, and 0.1146 units lower for each u/s more: from 29.84 u/s it ends 2.0250
        -- above, out of the ground check's reach, and from 30.10 it ends 1.9952 above,
        -- within it. To 0.1 unit both read 2.0, and the second rounded to 0.01 would read
        -- 2.00.
        local cases = {
            { 29.84, "hit", "(ran into it from 2.02 u up)", "the Half-Life update before it ended 2.02 units above "
                .. "the slope, out of the ground check's reach of 2" },
            { 30.10, "caught", "(set down from 1.99 u up)", "A Half-Life update ended 1.99 units above the slope, "
                .. "within the ground check's reach of 2" },
        }
        for _, case in ipairs(cases) do
            local g = running()
            g.terrain = plane(g, 10)
            fake.props(g.cmc).Velocity.X = case[1] * SCALE
            g.keys.SpaceBar = true
            local line
            for _ = 1, 120 do
                g.frame()
                for _, text in ipairs(g.log) do
                    if text:find("] Hop 1 ", 1, true) then
                        line = text
                    end
                end
                if line then
                    break
                end
            end
            t.truthy(line, "the hop landed")
            t.eq(landingKind(line), case[2], line)
            t.truthy(line:find(case[3], 1, true), line)
            t.contains(g.log, case[4])
            noErrors(g)
        end
    end)

t.test("each landing on a slope is decided as Half-Life's updates decide it, whatever the frame rate", function()
    -- The mod's hops against the step-by-step model above, landing by landing: the same
    -- kind of landing and the same speed after it. With PhysicsRate 0 the frames are the
    -- updates. (0.3.0 clipped every landing: the first case alone then loses 9 u/s a hop.)
    -- (At 250 updates a second a hop comes down on the slope by about 1 unit an update,
    -- so two updates may end within the ground check's reach: the first sets it down.
    -- With PhysicsRate 0 at 240 fps too, but there the mod names the last of them, see
    -- landingKind: the kind and the speed are the same, the height no higher.)
    local cases = {
        { rate = 100, fps = { 30, 80, 240 }, hops = { { 2, 330 }, { 5, 370 }, { 15, 320 }, { -2, 320 },
            { -10, 360 }, { -20, 576 } } },
        { rate = 144, fps = { 60, 240 }, hops = { { 5, 370 }, { -10, 320 }, { -20, 500 } } },
        { rate = 250, fps = { 60 }, hops = { { 5, 370 }, { 10, 320 }, { -5, 400 } } },
        { rate = 0, fps = { 30, 80, 240 }, hops = { { 2, 320 }, { 10, 320 }, { -5, 400 } } },
    }
    local hits, caught, lower = 0, 0, 0
    for _, case in ipairs(cases) do
        for _, fps in ipairs(case.fps) do
            for _, hop in ipairs(case.hops) do
                local angle, speed = hop[1], hop[2]
                local what = string.format("%d degrees from %d u/s at %d fps with PhysicsRate %d", angle, speed, fps,
                    case.rate)
                local model = halfLifeHops(angle, speed, case.rate > 0 and case.rate or fps, 4)
                local g = running({ PhysicsRate = case.rate })
                g.terrain = plane(g, angle)
                local landed = hopAlong(g, speed, 4, 1 / fps)
                for i = 1, 4 do
                    t.eq(landed[i].kind, model[i].kind, what .. ", landing " .. i .. ": " .. landed[i].line)
                    t.near(landed[i].speed, model[i].speed, 0.05, what .. ", the speed after landing " .. i)
                    -- The height in the hop line (to 0.1 units, 0.01 next to 2): where the update
                    -- that set it down ended, or where the one that ran into the slope began.
                    local height = tonumber(landed[i].line:match("from ([%d%.]+) u up"))
                    if case.rate == 0 and model[i].kind == "caught" then
                        t.truthy(height and height <= model[i].above + 0.0501, string.format("%s, the height above "
                            .. "the slope at landing %d: %s, the model %.3f", what, i, tostring(height),
                            model[i].above))
                        lower = lower + (height < model[i].above - 0.0501 and 1 or 0)
                    else
                        t.near(height, model[i].above, 0.0501, what .. ", the height above the slope at landing "
                            .. i)
                    end
                    hits = hits + (model[i].kind == "hit" and 1 or 0)
                    caught = caught + (model[i].kind == "caught" and 1 or 0)
                end
                noErrors(g)
            end
        end
    end
    t.truthy(hits >= 25 and caught >= 50, string.format("both kinds are in the cases: %d hits, %d caught", hits,
        caught))
    -- (None would mean that the cases no longer have a landing two updates end within
    -- reach of, or that the mod now looks for the first with PhysicsRate 0 too: then
    -- landingKind's comment, CLAUDE.md and this test change with it.)
    t.truthy(lower > 0, "with PhysicsRate 0, the mod named a lower update than the model's first within reach at no "
        .. "landing")
end)

t.test("PhysicsRate 0 with frames of two lengths in turn: a landing is decided with the update it came down in as "
    .. "long as its own frame", function()
    -- With one update per frame the hop often comes down on the plane before the last
    -- hook in the air (Unreal lands it a little later), in the frame before, which needn't
    -- be as long as the last one: that frame is the update that hit, and its length is the
    -- half update of gravity in the speed of the clip. Against the model with each update
    -- as long as its frame (taken as long as the last, the speeds after these three
    -- landings are 0.46, 0.35 and 0.95 u/s off).
    for _, case in ipairs({ { -5, 400, 45, 110, 0 }, { 5, 282, 50, 100, 0 }, { -10, 500, 40, 90, 1 } }) do
        local angle, speed, a, b, phase = case[1], case[2], case[3], case[4], case[5]
        local function length(k) -- the frame's (and update's) length, 1 for the take-off's
            return (k + phase) % 2 == 0 and 1 / a or 1 / b
        end
        local what = string.format("%d degrees from %d u/s, frames of 1/%d and 1/%d s", angle, speed, a, b)
        local model = halfLifeHops(angle, speed, length, 1)[1]
        t.eq(model.kind, "hit", what .. ": the model")
        local g = running({ PhysicsRate = 0 })
        g.terrain = plane(g, angle)
        g.frame(length(0))
        local landed = hopAlong(g, speed, 1, length)[1]
        t.eq(landed.kind, model.kind, what .. ": " .. landed.line)
        t.near(landed.speed, model.speed, 0.05, what .. ", the speed after the landing")
        noErrors(g)
    end
end)

t.test("PhysicsRate 144: a plain hop up a hill closes in on it by under 2 units an update, so none is clipped",
    function()
        -- Up 5 degrees from 370 u/s the hop comes down on the slope at 235.96 u/s: 2.36
        -- units an update at 100 a second (and it runs into the slope, see above), 1.64 at
        -- 144: there is always an update that ends within the ground check's 2 units.
        local g = running({ PhysicsRate = 144 })
        g.terrain = plane(g, 5)
        local landed = hopAlong(g, 370, 4)
        for i = 1, 4 do
            t.eq(landed[i].kind, "caught", landed[i].line)
        end
        t.near(g.speed(), 370 * SCALE, 0.05, "no speed lost")
        noErrors(g)
    end)

t.test("the ground check's 2 units are Half-Life units: with another UnitScale the same hops land the same way",
    function()
        local kinds = {}
        for _, scale in ipairs({ 1, 2.5, 4 }) do
            local g = running({ UnitScale = scale })
            g.terrain = plane(g, -20)
            fake.props(g.cmc).Velocity.X = 576 * scale
            g.keys.W, g.keys.SpaceBar = true, true
            g.frames(260)
            local found = {}
            for _, line in ipairs(g.log) do
                if line:find("] Hop ", 1, true) then
                    found[#found + 1] = landingKind(line)
                end
            end
            kinds[#kinds + 1] = table.concat(found, " ")
            t.contains(g.log, "the Half-Life update before it ended 2.4 units above the slope")
            noErrors(g)
        end
        t.eq(kinds[1], "hit hit caught", "UnitScale 1")
        t.eq(kinds[2], kinds[1], "UnitScale 2.5")
        t.eq(kinds[3], kinds[1], "UnitScale 4")
    end)

t.test("a hop from level ground that runs into an upward slope fast slides up it instead of landing", function()
    -- The slope begins 290 cm ahead of the jump: the hop meets it while still rising, and
    -- the update before ends 2.9 units above it. (Begun 300 cm ahead, an update ends 1.7
    -- units above it: see the next test.)
    local g = running()
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(25, x + 290, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "Unreal landed it")
    g.frame()
    local line = t.contains(g.log, "Slope: landed on a 25 degree slope at 800 u/s, rising 64 u/s: sliding up it at 682 "
        .. "u/s, rising 318 u/s (Half-Life keeps you in the air above 180)")
    t.eq(g.mode(), 1, "Unreal walks it up the slope")
    -- It goes on with the clipped velocity, as the line says (less the slide's one or two
    -- updates in the landing's frame, 3 u/s each on 25 degrees).
    local before, after = line:match("slope at (%d+) u/s, .-: sliding up it at (%d+) u/s")
    before, after = tonumber(before), tonumber(after)
    t.truthy(before and after and after < before - 50, line)
    t.truthy(g.speed() / SCALE <= after + 0.5 and g.speed() / SCALE >= after - 7,
        "the speed Unreal walks it up the slope with: " .. g.speed() / SCALE)
    noErrors(g)
end)

t.test("set down on a steep slope at speed, nothing slides at the landing: the next update runs into the slope",
    function()
        -- The same hop with the slope 300 cm ahead: an update ends 1.7 units above it, so
        -- Half-Life's ground check puts the player on it with 800 u/s. Then its ground
        -- move runs into the slope (Space let go), or its jump does (Space held): the
        -- slide starts one frame later. 0.3.0 clipped at the landing.
        local function land(held)
            local g = running()
            runTo(g, MAX_SPEED)
            g.keys.W = false
            local x = g.position.X
            g.terrain = ramp(25, x + 300, x + 20000)
            fake.props(g.cmc).Velocity.X = 2000
            jump(g)
            g.keys.SpaceBar = held
            t.truthy(untilMode(g, 1), "Unreal landed it")
            g.frame()
            t.contains(g.log, "Slope: landed on a 25 degree slope at 800 u/s: the speed stays. A Half-Life update "
                .. "ended 1.7 units above the slope")
            t.absent(g.log, "sliding up it")
            return g
        end
        -- Space let go: a frame of friction on the ground, then the slide.
        local g = land(false)
        t.eq(g.mode(), 1)
        g.frame()
        t.contains(g.log, "Slope: ran into a 25 degree slope at ")
        noErrors(g)
        -- Space held: the jump, which runs into the slope within its own update, rising
        -- 264 u/s (the jump's 268 less half an update of gravity).
        g = land(true)
        g.frame()
        t.contains(g.log, "Slope: landed on a 25 degree slope at 800 u/s, rising 264 u/s: sliding up it at ")
        t.absent(g.log, "Slope: ran into")
        noErrors(g)
    end)

t.test("a hop onto a steep slope with jump held: set down, the jump runs into the slope and slides with nearly all "
    .. "the speed; run into at the landing, the slide has what the clip left", function()
    -- A hop from level ground at 600 u/s onto a 30 degree slope, as Half-Life's updates
    -- give it. With the slope's foot 120.7 units ahead the ground check sets the player
    -- down with its 600 u/s, and it jumps: the jump's own update runs into the slope,
    -- rising 264 u/s, and the slide starts at 564 u/s, rising 326. With the foot 344.7
    -- units ahead the landing runs into the slope, falling 224 u/s: the slide starts at
    -- 353 u/s, rising 204. Both end at 319 u/s. (0.3.0 clipped both at the landing.)
    local function hopOnto(distance)
        local g = running()
        local foot = g.position.X + distance * SCALE
        g.terrain = ramp(30, foot, foot + 1e6)
        fake.props(g.cmc).Velocity.X = 600 * SCALE
        g.keys.SpaceBar = true
        for _ = 1, 400 do
            g.frame()
            if count(g.log, "Slope: the slide up the slope ended at ") > 0 then
                break
            end
        end
        t.eq(count(g.log, "sliding up it at "), 1, "one slide")
        t.contains(g.log, "Slope: the slide up the slope ended at 319 u/s")
        noErrors(g)
        return g
    end
    local g = hopOnto(120.7)
    t.contains(g.log, "Slope: landed on a 30 degree slope at 600 u/s: the speed stays. A Half-Life update ended ")
    t.contains(g.log, "Slope: landed on a 30 degree slope at 600 u/s, rising 264 u/s: sliding up it at 564 u/s, "
        .. "rising 326 u/s")
    g = hopOnto(344.7)
    t.absent(g.log, "the speed stays")
    t.contains(g.log, "Slope: landed on a 30 degree slope at 600 u/s, falling 224 u/s: sliding up it at 353 u/s, "
        .. "rising 204 u/s")
end)

t.test("a hop the game lands while it still rises away from the slope stays in the air for Half-Life, and the log "
    .. "says so", function()
    -- A surface 30 cm up, met 0.03 s into a hop. Unreal lands a rising character whose
    -- capsule catches the edge of a ledge; the fake lands it on any ground it dips below.
    -- It rises faster than 180 u/s, away from the surface: the clip changes nothing.
    local function hopOnto(angle)
        local g = running()
        local tan, s, c = math.tan(math.rad(angle)), math.sin(math.rad(angle)), math.cos(math.rad(angle))
        g.terrain = function(x)
            if x <= 1000 then
                return 0, 0, 0, 1
            end
            return 30 + (x - 1000) * tan, -s, 0, c
        end
        runFastTo(g, MAX_SPEED, 900)
        g.position.X = 975 -- the hop's second frame crosses the edge, whatever the run-up's frame phase
        g.keys.SpaceBar = true
        g.frame()
        t.eq(g.mode(), 3, "jumped")
        g.frame()
        t.eq(g.mode(), 1, "the game landed it in mid-rise")
        t.truthy(g.position.Z > 25, "on the raised surface")
        return g
    end

    -- Sloping up at 20 degrees: the path would stay within 8 units of it, so Unreal walks
    -- the character until the rise is down to 180 u/s. By then the path is 7 to 8 units
    -- above the surface, out of the ground check's reach: Half-Life's player is still in
    -- the air, so the character flies on with that rise, comes down on the surface, and
    -- the held jump fires there.
    local g = hopOnto(20)
    local walked = untilMode(g, 3, 10)
    t.truthy(walked and walked >= 2 and walked <= 7, "it flies on within 0.1 s: " .. tostring(walked) .. " frames")
    t.truthy(velocityZ(g) > 0 and velocityZ(g) < 180 * SCALE,
        string.format("with the slide's rise, not a jump: %.0f cm/s", velocityZ(g)))
    local line = t.contains(g.log, "Slope: flew off the slope at 320 u/s, rising 1")
    t.truthy(line:find(" units above it, out of the ground check's reach of 2", 1, true), line)
    t.truthy(untilMode(g, 1, 30), "it comes down on the surface")
    t.eq(untilMode(g, 3, 2), 1, "and the held jump fires at once")
    t.near(velocityZ(g), JUMP_SPEED - GRAVITY / 60, 1, "a jump")
    t.near(g.speed(), MAX_SPEED, 1, "no friction and no clip meanwhile")
    line = t.contains(g.log, "Slope: the game landed you on a 20 degree slope at 320 u/s while still rising 2")
    t.truthy(line:find(" u/s, away from it: Half-Life keeps you in the air above 180", 1, true), line)
    t.absent(g.log, "sliding up it", "nothing was turned along the slope")
    t.contains(g.log, ", slope +0 (still in the air), ")
    t.absent(g.log, "Slope: the slide up the slope ended")
    t.contains(g.log, "s after flying off the slope, at 320 u/s (+0)")
    noErrors(g)

    -- Sloping down at 10 degrees: it flies on with the rise it had, one frame later.
    g = hopOnto(-10)
    g.frames(2)
    t.eq(g.mode(), 3, "in the air again")
    -- (Two frames of gravity in the hop; in the frame Unreal walked it, the gravity of the
    -- one or two Half-Life updates the mod ran, since Half-Life has it in the air there
    -- too; and Unreal's in the frame it flies off. A new jump would rise 67 cm/s faster.)
    local rise = velocityZ(g) - (JUMP_SPEED - 3 * GRAVITY / 60)
    t.truthy(rise <= -GRAVITY / 100 + 1e-6 and rise >= -2 * GRAVITY / 100 - 1e-6,
        "still the first jump's rise, not a new jump: " .. velocityZ(g))
    t.contains(g.log, "Slope: the game landed you on a 10 degree slope at 320 u/s while still rising 2")
    t.absent(g.log, "sliding up it")
    t.contains(g.log, "Slope: flew off the slope at 320 u/s, rising 2")
    noErrors(g)
end)

t.test("SlopeLandings = false: a landing on a slope keeps Unreal's speed, and a fast one still slides up it", function()
    -- Up 5 degrees from 282 u/s, a landing that runs into the slope (see above): with
    -- SlopeLandings it leaves 261.13 u/s; here only a frame of friction is taken.
    local g = running({ SlopeLandings = false })
    g.terrain = plane(g, 5)
    fake.props(g.cmc).Velocity.X = 282 * SCALE
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.absent(g.log, "Slope:")
    t.truthy(g.speed() > 282 * SCALE * 0.96 ^ 2 - 1, string.format("no slope loss: %.0f cm/s", g.speed()))
    g.press(F8)
    t.contains(g.log, "  slopes (SlopeLandings=false, SlopeBoosts=true): landings on one 0, slides up one 0,")

    -- (The slope 290 cm ahead: the hop runs into it, see above.)
    g = running({ SlopeLandings = false })
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(25, x + 290, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "Unreal landed it")
    g.frame()
    t.contains(g.log, "sliding up it at ")
    noErrors(g)
end)

t.test("SlopeBoosts = false: a fast landing that runs into an upward slope lands with the slope's speed, without a "
    .. "slide", function()
    -- (The slope 290 cm ahead: the hop runs into it, see above.)
    local g = running({ SlopeBoosts = false })
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(25, x + 290, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    jump(g)
    t.truthy(untilMode(g, 1), "Unreal landed it")
    g.frame()
    local line = t.contains(g.log, "Slope: landed on a 25 degree slope at 800 u/s")
    t.truthy(line:match("u/s: (%d+) u/s %(%-(%d+)%)%. It ran into the slope: "), line)
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
    g.frames(200)
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
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

-- The speeds in docs/TESTING.md ---------------------------------------------------------

-- The table under "Slope boosting" in docs/TESTING.md, which the owner's test goes by:
-- for each slope, the speed from which every hop onto it slides, the lowest speed at
-- which some do, the speed from which running into it without the jump key slides, and
-- the speed a slide ends at.
-- Line ends as LF, whatever the checkout has: git on Windows (core.autocrlf) writes CR LF,
-- and the patterns below look for "\n".
local function readFile(path)
    local file = assert(io.open(root .. path, "r"))
    local text = file:read("a")
    file:close()
    return (text:gsub("\r\n", "\n"))
end

local function boostTable()
    local text = readFile("docs/TESTING.md")
    local rows = {}
    for angle, always, some, runIn, ends in text:gmatch("\n| (%d+) degrees[^|\n]*| (%d+) u/s | (%d+) u/s | (%d+) u/s | "
        .. "(%d+) u/s |") do
        rows[#rows + 1] = { angle = tonumber(angle), always = tonumber(always), some = tonumber(some),
            runIn = tonumber(runIn), ends = tonumber(ends) }
    end
    return rows
end

t.test("the slope boosting speeds in docs/TESTING.md are the mod's: running into a slope, a hop onto one, and where a "
    .. "slide ends", function()
    local rows = boostTable()
    t.eq(#rows, 5, 'the rows of the table, written like "| 20 degrees | 675 u/s | 600 u/s | 573 u/s | 505 u/s |" '
        .. "for 10, 15, 20, 25 and 30 degrees")
    local FPS = 80 -- the table says it is for 80 frames a second
    local jumpSpeed = JUMP_SPEED / SCALE
    -- On paper. A clip against a slope leaves a rise of the speed times sin cos (less the
    -- fall times sin squared, at a landing), and a slide needs a rise over 184 u/s: 180
    -- half an update of gravity later. It ends once the rise, then the speed times tan, is
    -- down to that. A landing that runs into the slope can slide from the speed of a hop
    -- that took off at the slope's foot up to that of one that falls at the full 268 u/s.
    for _, row in ipairs(rows) do
        local a = math.rad(row.angle)
        local s, c, tan = math.sin(a), math.cos(a), math.tan(a)
        local name = row.angle .. " degrees: "
        t.near(row.runIn, 184 / (s * c), 1.5, name .. "running into it")
        t.near(row.ends, 184 / tan, 6, name .. "where a slide ends")
        local lowest = (184 + jumpSpeed * s * s) / (s * c + 2 * tan * s * s)
        local highest = (184 + jumpSpeed * s * s) / (s * c)
        t.truthy(row.some >= lowest - 5 and row.some <= highest + 5, string.format("%ssome hops slide from %d u/s, "
            .. "between %.0f and %.0f on paper", name, row.some, lowest, highest))
        t.truthy(row.always >= row.some and row.always >= row.runIn - 5, name .. "every hop from a higher speed")
        -- Every hop: also the one whose landing falls at the full 268 u/s just past the foot.
        t.truthy(row.always >= highest, string.format("%severy hop slides from %d u/s, not below the %.0f u/s on "
            .. "paper of a landing that falls at the full 268 u/s", name, row.always, highest))
    end
    -- In the fake game, every row. Each game settles in frames of 0.1 s, the longest the
    -- mod counts, instead of the other tests' 190 frames of 1/60 s: a hop's updates are
    -- counted from its take-off, so the slides come out the same (measured for 4000
    -- approaches at the speeds checked here), in about two thirds of the time.
    local function settled()
        local g = start()
        g.loadSave()
        g.frames(31, 0.1)
        g.frames(10)
        return g
    end
    -- Running into the slope without the jump key, at exactly `speed` u/s.
    local function runInto(angle, speed)
        local g = settled()
        g.terrain = ramp(angle, 300, 30000)
        runFastTo(g, speed * SCALE, 320, 1 / FPS)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        g.frame(1 / FPS)
        noErrors(g)
        return count(g.log, "Slope: ran into a " .. angle .. " degree slope at ") > 0
    end
    -- A hop from level ground at `speed` u/s with jump held, the slope's foot `share` of
    -- the hop's length ahead. Returns whether a slide begins, at the hop's landing on
    -- the slope or in the hop the held jump starts there, and the speed it ends with.
    local function hopOnto(angle, speed, share)
        local g = settled()
        local foot = g.position.X + share * speed * SCALE * 2 * JUMP_SPEED / GRAVITY
        g.terrain = ramp(angle, foot, foot + 1e6)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        g.keys.W, g.keys.SpaceBar = true, true
        local slid
        for _ = 1, 6 * FPS do
            g.frame(1 / FPS)
            if not slid then
                slid = count(g.log, "sliding up it") > 0
                if not slid and count(g.log, "Slope: landed on a ") >= 2 then
                    break -- two landings on the slope, and neither began a slide
                end
            elseif count(g.log, "Slope: the slide up the slope ended at ") > 0 then
                break
            end
        end
        noErrors(g)
        local line = slid and t.contains(g.log, "Slope: the slide up the slope ended at ")
        return slid, line and tonumber(line:match("ended at (%d+) u/s"))
    end
    -- The slope's foot at 13 places along the hop before it (every other one of the 25
    -- the table was made with), and at the end of a hop, where the landing falls at the
    -- full 268 u/s just past the foot: the last approaches to slide as the speed rises
    -- (at 600 u/s on 25 degrees and 575 on 30, those from 0.98 of a hop on don't).
    local PLACES = {}
    for k = 0, 24, 2 do
        PLACES[#PLACES + 1] = k / 25
    end
    PLACES[#PLACES + 1] = 0.98
    PLACES[#PLACES + 1] = 0.99
    local always = {}
    for _, row in ipairs(rows) do
        local name = row.angle .. " degrees: "
        always[row.angle] = row.always
        t.truthy(runInto(row.angle, row.runIn), name .. "running into it at " .. row.runIn .. " u/s slides")
        t.falsy(runInto(row.angle, row.runIn - 1), name .. "1 u/s slower it doesn't")
        -- From the table's speed on, a hop slides wherever the slope's foot lies...
        for _, share in ipairs(PLACES) do
            local slid, ended = hopOnto(row.angle, row.always, share)
            t.truthy(slid, string.format("%sa hop at %d u/s slides with the foot %.2f of a hop ahead", name,
                row.always, share))
            -- (The table rounds to 5 u/s, and on one slope the log's end speeds differ by up to
            -- 4 u/s from one hop speed to another.)
            t.near(ended, row.ends, 4.5, name .. "the speed its slide ends with")
        end
        -- ... and at the table's step of 25 u/s less, not everywhere (the end of a hop first).
        local all = true
        for i = #PLACES, 1, -1 do
            if not hopOnto(row.angle, row.always - 25, PLACES[i]) then
                all = false
                break
            end
        end
        t.falsy(all, string.format("%sat %d u/s some hop onto it doesn't slide", name, row.always - 25))
        -- At the "some hops" speed, one approach of 200 slides: near that speed only a few
        -- narrow places along the hop do (at 750 u/s on 15 degrees, 2 of 200)...
        local some = false
        for k = 0, 199 do
            if hopOnto(row.angle, row.some, k / 200) then
                some = true
                break
            end
        end
        t.truthy(some, string.format("%sat %d u/s some hop onto it slides", name, row.some))
        -- ... and 25 u/s slower, none of 50. (A "some hops" speed set 25 u/s too high is
        -- caught where one of these 50 slides at the right speed: in 0.3.1 in every row.)
        for k = 0, 49 do
            t.falsy(hopOnto(row.angle, row.some - 25, k / 50), string.format("%sat %d u/s a hop with the foot %.2f "
                .. "of a hop ahead doesn't slide", name, row.some - 25, k / 50))
        end
    end
    -- The README, config.lua and docs/TESTING.md itself quote the speeds from which every
    -- hop slides, in these words, with the table's numbers.
    local everyHop = string.format("Every hop slides from about %d u/s on a 20 degree slope, %d on 30 degrees, %d on "
        .. "15 and %d on 10", always[20], always[30], always[15], always[10])
    for _, quote in ipairs({
        { "README.md", string.format("(about %d u/s for a 20 degree slope, %d for a 30 degree one)", always[20],
            always[30]) },
        { "README.md", everyHop },
        { "HL1Movement/Scripts/config.lua", everyHop },
        { "docs/TESTING.md", string.format("at 10 degrees you would need %d u/s", always[10]) },
    }) do
        local path, sentence = quote[1], quote[2]
        -- One line of words: line ends, and a comment's "--" after them, gone.
        local text = readFile(path):gsub("\n%s*%-%-", " "):gsub("%s+", " ")
        t.truthy(text:find(sentence, 1, true), string.format('%s should say "%s", with the speeds of the table in '
            .. "docs/TESTING.md (this test looks for these words)", path, sentence))
    end
end)

t.test("what config.lua, the README and docs/TESTING.md say PhysicsRate adds to air strafing is the mod's: their "
    .. "figures with A and D and the view swinging, a few per cent with D held and a slow turn", function()
    -- Where the turn limits it the speed grows by w (cap - w v / 2R) a second (w: the turn
    -- in radians a second, R: PhysicsRate), so more updates only shrink the second part:
    -- the docs' figures hold where w v is large, and a slow turn leaves a few per cent.
    local function flat(path)
        return (readFile(path):gsub("\n%s*%-%-", " "):gsub("%s+", " "))
    end
    local configText = flat("HL1Movement/Scripts/config.lua")
    local figures = { configText:match("144, 200 or 250 gain about (%d+), (%d+) or (%d+) %% more speed per hop when "
        .. "air strafing with A and D in turn and the view swinging about 150 to 180 degrees a second") }
    t.eq(#figures, 3, "config.lua gives its figures for A and D with the view swinging 150 to 180 degrees a second")
    t.truthy(configText:find("with one key and a slow turn only a few per cent", 1, true),
        "and what a slow turn leaves")
    local low, high = flat("README.md"):match("`144` to `250` gain a little more when air strafing %(about (%d+) to "
        .. "(%d+) %% with A and D in turn and the view swinging about 150 to 180 degrees a second, only a few per cent "
        .. "with one key and a slow turn%)")
    t.truthy(low == figures[1] and high == figures[3], "the README gives config.lua's figures, for the same strafing")
    t.truthy(figures[1] == "10" and flat("docs/TESTING.md"):find("with the view swinging about 150 to 180 degrees a "
        .. "second, `PhysicsRate = 144` adds about a tenth per hop", 1, true), "docs/TESTING.md gives the same for 144")
    -- At 80 fps on level ground: a run, three hops straight, then 11 strafing hops with the
    -- view turning `rate` deg/s, swinging back every 0.335 s (two turns a hop) with A and D
    -- in step, or with D held and the view turning right. Returns the gain per hop in u/s.
    local function strafe(config, rate, oneKey)
        local dt, hops = 1 / 80, 11
        local g = running(config)
        g.keys.W = true
        g.frames(160, dt)
        g.keys.SpaceBar = true
        local landings, yaw, direction, clock, from = g.landings, 0, 1, 0.165, nil
        for _ = 1, 30 * 80 do
            if g.landings - landings >= 3 then
                from = from or g.speed() / SCALE
                g.keys.W = false
                clock = clock + dt
                if not oneKey and clock >= 0.335 then
                    clock, direction = 0, -direction
                end
                g.keys.D, g.keys.A = direction > 0, direction < 0
                yaw = yaw + direction * rate * dt
                g.rotation.Yaw = yaw
            end
            g.frame(dt)
            if g.landings - landings >= 3 + hops then
                break
            end
        end
        t.eq(g.landings - landings, 3 + hops, "all the hops")
        noErrors(g)
        return (g.speed() / SCALE - from) / hops
    end
    local swinging, slow = strafe({}, 165), strafe({}, 60, true)
    for i, R in ipairs({ 144, 200, 250 }) do
        local more = (strafe({ PhysicsRate = R }, 165) / swinging - 1) * 100
        t.near(more, tonumber(figures[i]), 3, string.format("PhysicsRate %d with the view swinging 165 degrees a "
            .. "second, in per cent more per hop", R))
    end
    t.truthy(strafe({ PhysicsRate = 144 }, 60, true) / slow < 1.05, "D held turning 60 degrees a second: 144 adds "
        .. "under 5 %")
    t.truthy(strafe({ PhysicsRate = 250 }, 60, true) / slow < 1.08, "and 250 under 8 %")
end)

-- Jumping -------------------------------------------------------------------------

t.test("a jump that Unreal lands again within its own frame, where the floor rises faster than it, isn't a hop",
    function()
        -- At 700 u/s a 30 degree floor rises 404 u/s, the jump 268: Unreal lands the mod's
        -- jump again in the frame it started in. With the defaults that landing starts a
        -- slide. With slopes left to Unreal, or a floor the mod can't read, a held Space
        -- jumps again on the next frame, and so on up the slope.
        for name, setup in pairs({
            ["both slope settings off"] = { config = { SlopeBoosts = false, SlopeLandings = false } },
            ["a floor that can't be read"] = { options = { floorNormalUnreadable = true } },
        }) do
            local g = running(setup.config, setup.options)
            local movement = require("hl1movement.movement")
            if setup.options then
                runFastTo(g, 2000, 1500) -- 45 frames at 800 u/s, each reading the floor
                t.contains(g.log, "Could not read the normal of the floor")
                g.frames(90) -- to a stop, so that the hop below takes off at 320 u/s here too
            end
            runTo(g, MAX_SPEED)
            local x = g.position.X
            g.terrain = ramp(30, x + 600, x + 1e9)
            g.keys.SpaceBar = true
            g.frame()
            t.eq(g.mode(), 3, "jumped")
            fake.props(g.cmc).Velocity.X = 700 * SCALE
            for _ = 1, 200 do
                if g.position.X >= x + 600 and g.mode() == 1 then
                    break
                end
                g.frame()
            end
            g.frame() -- the mod's frame after the hop's landing on the slope
            local hops, hopLines, landings = movement.status().hops, count(g.log, "] Hop "), g.landings
            g.frames(120)
            t.truthy(g.landings - landings >= 110, name .. ": Unreal landed it on nearly every frame: "
                .. (g.landings - landings))
            t.eq(count(g.log, "] Hop ") - hopLines, 0, name .. ": no hop lines for them")
            t.absent(g.log, "0.00 s in the air")
            t.eq(movement.status().hops - hops, 0, name .. ": not counted as hops")
            t.truthy(movement.status().counts.groundedJumps >= 110, name .. ": counted on their own")
            t.eq(count(g.log, "A jump landed again within the frame it started in"), 1, name .. ": said once")
            -- The status line keeps them apart from the hops its per-jump numbers are about.
            local status
            for _ = 1, 700 do
                g.frame()
                status = g.log[#g.log]:find("Status (10s)", 1, true) and g.log[#g.log] or status
                if status then
                    break
                end
            end
            t.truthy(status, name .. ": a status line")
            local counted, grounded = status:match("; (%d+) hops %(and (%d+) jumps that landed again within their own "
                .. "frame%), top speed")
            t.truthy(counted and tonumber(counted) <= 3 and tonumber(grounded) >= 110, status)
            -- (If the hop onto the slope is in this line, its 380 u/s aren't shared out among them.)
            local gain = status:match("per jump %+(%d+) u/s in the air")
            t.truthy(not status:find("per jump ", 1, true) or tonumber(gain or 0) > 300, status)
            g.press(F8)
            local report
            for _, line in ipairs(g.log) do
                report = line:find("jumps that landed again within their own frame ", 1, true) and line or report
            end
            t.truthy(report and tonumber(report:match("within their own frame (%d+)")) >= 110, tostring(report))
            noErrors(g)
        end

        -- With the defaults: one such jump, then the slide. It has no hop line either.
        local g = running()
        g.terrain = ramp(30, 300, 20000)
        runFastTo(g, 2000, 300)
        g.keys.SpaceBar = true
        g.frame()
        t.eq(g.mode(), 1, "the jump at the foot of the slope landed again at once")
        t.contains(g.log, "First jump by the mod")
        g.frame()
        local slide = t.contains(g.log, "Slope: landed on a 30 degree slope at ")
        t.truthy(slide:find(" u/s, rising %d+ u/s: sliding up it at "), slide)
        g.frames(5)
        t.absent(g.log, "] Hop ")
        t.eq(count(g.log, "A jump landed again within the frame it started in"), 1)
        t.eq(require("hl1movement.movement").status().counts.groundedJumps, 1)
        noErrors(g)

        -- SlopeBoosts = false alone (docs/TESTING.md step 9): no hop line without time in the air.
        g = running({ SlopeBoosts = false })
        g.terrain = ramp(30, 300, 1e9)
        runFastTo(g, 2000, 300)
        g.keys.SpaceBar = true
        g.frames(120)
        t.absent(g.log, "0.00 s in the air")
        t.absent(g.log, "sliding up it")
        noErrors(g)
    end)

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

t.test("a game that presses its jump on every frame the key is held: holding it through a slide never jumps",
    function()
        -- (ALS's JumpAction calls Jump() on every jump event while the character is on the
        -- ground, and some input set-ups send the event on every frame the key is held.)
        for _, case in ipairs({ { 30000, "the slide up the slope ended at " }, { 900, "flew off the slope at " } }) do
            local g = running(nil, { jumpEventEveryFrame = true })
            g.terrain = ramp(20, 300, case[1])
            runFastTo(g, 2000, 300)
            g.frame()
            t.contains(g.log, "Slope: ran into a 20 degree slope")
            g.keys.SpaceBar = true
            local slid = 0
            for _ = 1, 300 do
                g.frame()
                if g.mode() ~= 1 then
                    break
                end
                slid = slid + 1
                t.eq(g.stoppedJumps, slid, "the game's press was taken back on every frame of the slide so far")
            end
            t.truthy(slid >= 15, case[2] .. "slid for " .. slid .. " frames")
            t.eq(g.mode(), 3)
            t.eq(g.gameJumps, 0, "the game never jumped")
            t.contains(g.log, "Slope: " .. case[2])
            t.absent(g.log, "the game jumped while sliding")
            if case[1] > 900 then
                -- The held key jumps as the slide ends: the mod's jump, not the game's.
                t.near(velocityZ(g), JUMP_SPEED - GRAVITY / 60, 1)
            end
            noErrors(g)
        end

        -- Hops on flat ground with such a game: the mod's jump still comes first.
        local g = running(nil, { jumpEventEveryFrame = true })
        runTo(g, MAX_SPEED)
        g.keys.SpaceBar = true
        g.frames(180)
        t.truthy(g.landings >= 3, "hopped")
        t.eq(g.gameJumps, 0, "the game never jumped")
        t.eq(g.stoppedJumps, 0, "and no press had to be taken back")
        noErrors(g)
    end)

t.test("AutoHop = false: a jump key held since the last jump doesn't stop a slide from starting, and a press during "
    .. "the slide is used up", function()
    local g = running({ AutoHop = false })
    g.terrain = ramp(20, 2000, 30000)
    g.keys.SpaceBar = true -- pressed once, and held from now on
    g.frame()
    t.eq(g.mode(), 3, "the press jumped")
    t.truthy(untilMode(g, 1), "landed")
    g.frames(3)
    t.eq(g.mode(), 1, "holding the key doesn't jump again")
    runFastTo(g, 2000, 2000)
    g.frames(3)
    t.contains(g.log, "Slope: ran into a 20 degree slope")
    t.eq(g.mode(), 1)
    -- Let go and press again while it slides: Half-Life uses the press up in the air.
    g.keys.SpaceBar = false
    g.frame()
    g.keys.SpaceBar = true
    local ended
    for _ = 1, 300 do
        g.frame()
        if count(g.log, "Slope: the slide up the slope ended") > 0 then
            ended = true
            break
        end
        t.eq(g.mode(), 1, "no jump while it slides")
    end
    t.truthy(ended, "the slide ended")
    g.frames(5)
    t.eq(g.mode(), 1, "the press was used up in the air: no jump as the slide ends")
    t.eq(g.gameJumps, 0, "and the game's own jump was held back")
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

t.test("a sloped floor the capsule only touches with an edge (its contact normal is off the surface's) isn't a slope",
    function()
        -- The lip of a ramp, or a ridge: the surface slopes at 20 degrees, and the capsule's
        -- contact normal leans 37 degrees the other way. (A step's edge with a flat tread
        -- doesn't get this far: its surface normal is flat.)
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

t.test("slopes go off at the 30th unreadable floor in a row, not before", function()
    local g = running(nil, { floorNormalUnreadable = true })
    g.frames(200) -- after the automatic report, which reads the floor too
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
    local reads = 0
    fake.onRead(g.cmc, "CurrentFloor", function()
        reads = reads + 1
    end)
    g.keys.W = true
    for _ = 1, 60 do
        fake.props(g.cmc).Velocity.X = 2000
        g.frame()
        if reads <= 29 then
            t.absent(g.log, "Could not read the normal of the floor")
        end
    end
    t.eq(reads, 30, "then the floor isn't read any more")
    t.eq(count(g.log, "Could not read the normal of the floor"), 1)
    noErrors(g)
end)

t.test("...and the count goes on when the movement is given back and taken over again in between: the reload "
    .. "key, a battle, the game taking the movement input away", function()
    local g = running({ Debug = true }, { floorNormalUnreadable = true })
    g.frames(200) -- after the automatic report, which reads the floor too
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
    local reads = 0
    fake.onRead(g.cmc, "CurrentFloor", function()
        reads = reads + 1
    end)
    -- Runs fast along the ground, each frame reading the floor, until it was read `upTo`
    -- times in all; then stands (stopped at once: slowing down would read it some more).
    local function runUntil(upTo)
        g.keys.W = true
        for _ = 1, 60 do
            if reads >= upTo then
                break
            end
            fake.props(g.cmc).Velocity.X = 2000
            g.frame()
        end
        g.keys.W = false
        fake.props(g.cmc).Velocity.X = 0
        g.frames(2)
        t.eq(reads, upTo, "one read a frame, and none standing")
    end
    local takeOvers = count(g.log, "debug: Movement taken over")
    local function takenOverAgain(what)
        takeOvers = takeOvers + 1
        t.eq(count(g.log, "debug: Movement taken over"), takeOvers, what)
    end
    runUntil(8)
    g.press(F7)
    takenOverAgain("the reload key")
    runUntil(15)
    g.inBattle = true
    g.frames(5)
    g.inBattle = false
    g.frames(5)
    takenOverAgain("a battle")
    runUntil(22)
    g.inputLocked = true
    g.frames(5)
    g.inputLocked = false
    g.frames(5)
    takenOverAgain("the game taking the movement input away")
    runUntil(29)
    t.absent(g.log, "Could not read the normal of the floor")
    runUntil(30)
    t.eq(count(g.log, "Could not read the normal of the floor"), 1)
    g.keys.W = true
    for _ = 1, 10 do
        fake.props(g.cmc).Velocity.X = 2000
        g.frame()
    end
    t.eq(reads, 30, "then the floor isn't read any more")
    g.press(F8)
    t.contains(g.log, "; off: the floor's normal can't be read")
    noErrors(g)
end)

t.test("a bumpy slope slid up at 800 u/s doesn't launch off its bumps, from 60 to 240 fps", function()
    -- 25 degrees on average, in 1 m segments of 21 and 29 degrees, like a landscape. (The
    -- launch goes by the rise after the frame's gravity, so it comes a little sooner at a
    -- higher frame rate. Faster, or over bigger bumps, the character does fly off them.)
    -- Where a slide's rise is down to 180 u/s just past a bump, Half-Life's path can be
    -- out of the ground check's reach: then it flies on for a few hundredths of a second.
    local x0, heights = 300, { [0] = 0 }
    local function angle(i)
        return math.rad(25 + (i % 2 == 0 and 4 or -4))
    end
    for i = 1, 200 do
        heights[i] = heights[i - 1] + 100 * math.tan(angle(i))
    end
    for _, fps in ipairs({ 60, 80, 144, 240 }) do
        local g = running()
        g.terrain = function(x)
            if x <= x0 then
                return 0, 0, 0, 1
            end
            local i = math.floor((x - x0) / 100) + 1
            return heights[i - 1] + (x - x0 - (i - 1) * 100) * math.tan(angle(i)), -math.sin(angle(i)), 0,
                math.cos(angle(i))
        end
        runFastTo(g, 2000, x0, 1 / fps)
        local changes, last = 0, g.mode()
        g.frames(4 * fps, 1 / fps, function()
            if g.mode() ~= last then
                changes, last = changes + 1, g.mode()
            end
        end)
        t.contains(g.log, "Slope: ran into a 21 degree slope")
        local flights, ends = count(g.log, "Slope: flew off the slope at "), count(g.log, ": the slide ended ")
        t.eq(flights, ends, fps .. " fps: no launch off a bump on the way up, only where a slide ended above one")
        t.truthy(ends <= 2, fps .. " fps: at most one at the end of each slide: " .. ends)
        t.truthy(ends + count(g.log, "Slope: the slide up the slope ended") >= 1,
            fps .. " fps: the slide's end is logged")
        for _, line in ipairs(g.log) do
            local time = line:match("Slope: landed ([%d%.]+) s after flying off the slope")
            t.truthy(not time or tonumber(time) <= 0.05, fps .. " fps: a short flight: " .. line)
        end
        t.eq(changes, 2 * flights, fps .. " fps: no other launches and landings on the way up")
        t.eq(g.landings, flights, fps .. " fps")
        noErrors(g)
    end
end)

-- 20 degrees for 4 m from x0, then a top of 20 m radius in faces of 2 degrees (70 cm), as
-- a landscape's hill.
local function roundedTop(x0)
    local run, radius = 400, 2000
    local a = math.rad(20)
    local points = { { x0, 0 }, { x0 + run, run * math.tan(a) } }
    local cx, cz = points[2][1] + radius * math.sin(a), points[2][2] - radius * math.cos(a)
    for deg = 18, 0, -2 do
        points[#points + 1] = { cx - radius * math.sin(math.rad(deg)), cz + radius * math.cos(math.rad(deg)) }
    end
    return function(x)
        for i = 1, #points - 1 do
            local p, q = points[i], points[i + 1]
            if x >= p[1] and x <= q[1] then
                local dx, dz = q[1] - p[1], q[2] - p[2]
                local len = math.sqrt(dx * dx + dz * dz)
                return p[2] + (x - p[1]) * dz / dx, -dz / len, 0, dx / len
            end
        end
        return x < x0 and 0 or points[#points][2], 0, 0, 1
    end
end

t.test("a slide over a top that rounds off flies off it where Half-Life's path has left the floor, from 60 to 240 fps",
    function()
        -- The top above, run into at 1000 u/s. Unreal walks the character over the top,
        -- and no single bend lifts the path 8 units above the floor. But the floor falls
        -- away under the slide: by the time its rise is down to 180 u/s, Half-Life's path
        -- is 4 to 9 units above the floor, out of the ground check's reach, and it flies on
        -- (a model of Half-Life's updates over the same floor: 13 to 24 units high).
        local x0 = 300
        local floorAt = roundedTop(x0)
        for _, fps in ipairs({ 60, 80, 144, 240 }) do
            local g = running()
            g.terrain = floorAt
            runFastTo(g, 1000 * SCALE, x0, 1 / fps)
            local high, flew = 0, false
            g.frames(3 * fps, 1 / fps, function()
                if g.mode() == 3 then
                    flew = true
                    high = t.max(high, g.position.Z - (floorAt(g.position.X)))
                end
            end)
            t.contains(g.log, "Slope: ran into a 20 degree slope at ")
            local line = t.contains(g.log, "Slope: flew off the slope at ")
            t.truthy(line:find(": the slide ended ", 1, true), fps .. " fps: " .. line)
            t.absent(g.log, "Slope: the slide up the slope ended", fps .. " fps: the slide doesn't end on the top")
            t.truthy(flew and high > 8 * SCALE, string.format("%d fps: it flies %.0f cm above the top", fps, high))
            t.contains(g.log, "s after flying off the slope, at ")
            t.eq(g.mode(), 1, fps .. " fps: and lands")
            noErrors(g)
        end
    end)

t.test("over the same top a little slower, Half-Life's path stays within the ground check's reach and the slide "
    .. "ends on the top: the clips against the slope after the floor fell away under the path are taken back",
    function()
        -- A frame's updates clip against the plane of the floor under the character, also
        -- after the path ahead of it passed a bend: the floor there falls away, and Half-Life's
        -- player flies on without those clips. Measured at the next frame, they are taken back
        -- (their share by how far the floor fell). Kept, they leave the rise a few u/s too high,
        -- and the path ends the slide out of reach: a flight of 3.3 units here (60 fps), where a
        -- model of Half-Life's updates over the same floor stays 1.6 units up. (Closer to the 2
        -- units, which way it comes out depends on the frame phase.)
        for _, speed in ipairs({ 850 }) do
            local g = running()
            g.terrain = roundedTop(300)
            runFastTo(g, speed * SCALE, 300, 1 / 60)
            local flew = false
            g.frames(180, 1 / 60, function()
                flew = flew or g.mode() == 3
            end)
            t.contains(g.log, "Slope: ran into a 20 degree slope at ")
            t.contains(g.log, "Slope: the slide up the slope ended at ", speed .. " u/s")
            t.absent(g.log, "Slope: flew off the slope at ", speed .. " u/s")
            t.falsy(flew, speed .. " u/s: on the ground all the way")
            noErrors(g)
        end
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

t.test("a slide that leaves a slope over its edge: the log says how many frames the capsule was on the edge", function()
    -- With Unreal's defaults (PerchRadiusThreshold 0, no flat base) a capsule rounds an
    -- edge: until its middle is nearly its radius past the end of the slope, the floor
    -- check still finds the slope's surface, now with a contact normal that leans from
    -- the edge to the middle of its round bottom, and sets the character down on the edge.
    -- The mod doesn't use such a floor; the log line tells how long that lasted. (The
    -- terrain here is the height of a 35 cm capsule's lowest point, less what it stands
    -- higher on the slope than a point.)
    local R = 35
    local tan, s, c = math.tan(math.rad(20)), math.sin(math.rad(20)), math.cos(math.rad(20))
    local slope = ramp(20, 300, 700)
    local function onEdge(x)
        return x - 700 >= -R * s and x - 700 < R - 0.15
    end
    -- The ramp, stopping at its rounded edge with the ground `drop` cm lower behind it.
    local function rounded(drop)
        return function(x)
            if x - 700 >= R - 0.15 then
                return 400 * tan - drop, 0, 0, 1
            elseif onEdge(x) then
                return 400 * tan + math.sqrt(R * R - (x - 700) ^ 2) - R / c, -s, 0, c
            end
            return slope(x)
        end
    end
    -- The contact normal of the capsule at x: on the edge, from the edge to the middle of
    -- its round bottom.
    local function rounding(x, nx, ny, nz)
        if onEdge(x) then
            return (x - 700) / R, 0, math.sqrt(1 - (x - 700) ^ 2 / (R * R))
        end
        return nx, ny, nz
    end
    -- Slides up `ground` from 800 u/s until a slide line with `text` is logged. Returns
    -- that line, and for how many frames in a row the floor the mod found at its hook
    -- had a contact normal (contact, a function as above) over 8 degrees off its
    -- surface's: up to the frame before the line's (before), and with the line's own
    -- frame (now: 0 if that one's floor is used, or if there is none).
    local function slideUntil(ground, text, fps, contact)
        local g = running()
        g.terrain = ground
        g.contactNormal = function(nx, ny, nz)
            return contact(g.position.X, nx, ny, nz)
        end
        runFastTo(g, 2000, 300, 1 / fps)
        local now = 0
        local before
        for _ = 1, 3 * fps do
            local hit = fake.props(g.cmc).CurrentFloor.HitResult
            local n, k = hit.ImpactNormal, hit.Normal
            local leans = g.mode() == 1 and n.X * k.X + n.Y * k.Y + n.Z * k.Z < math.cos(math.rad(8))
            before, now = now, leans and now + 1 or 0
            g.frame(1 / fps)
            if count(g.log, text) > 0 then
                noErrors(g)
                return t.contains(g.log, text), before, now, g
            end
        end
        error("no line with " .. text)
    end
    local function note(frames)
        return string.format(", after %d frame%s on its edge", frames, frames == 1 and "" or "s")
    end

    -- Off the end, over a drop of 3 m: a frame or two on the edge at 60 and 80 fps, three
    -- or four at 144 fps.
    for _, fps in ipairs({ 60, 80, 144 }) do
        local line, frames, _, g = slideUntil(rounded(300), "Slope: off the end of the slope at ", fps, rounding)
        t.eq(g.mode(), 3, "off the end")
        t.truthy(frames >= (fps == 144 and 3 or 1), fps .. " fps: frames on the edge: " .. frames)
        t.truthy(line:find(note(frames), 1, true), fps .. " fps, " .. frames .. " frames on the edge: " .. line)
    end

    -- A step down of 30 cm behind the edge: Unreal steps the character down onto the
    -- level ground, whose floor the mod uses, and the slide flies off from there. The
    -- line counts the frames on the edge before that one.
    local line, frames, now = slideUntil(rounded(30), "Slope: flew off the slope at ", 144, rounding)
    t.truthy(frames >= 3 and now == 0, "frames on the edge, then a floor that is used: " .. frames .. ", " .. now)
    t.truthy(line:find(note(frames), 1, true), frames .. " frames on the edge: " .. line)

    -- A slide that ends on such a floor (a long ridge: from x = 500 on the contact normal
    -- leans 37 degrees the other way). Without the clip its rise only falls, and the line
    -- of its end counts the frames up to its own.
    local ended, _, onRidge = slideUntil(ramp(20, 300, 1e6), "Slope: the slide up the slope ended at ", 80,
        function(x, nx, ny, nz)
            if x >= 500 then
                return 0.6, 0, 0.8
            end
            return nx, ny, nz
        end)
    t.truthy(onRidge >= 5, "frames on the ridge: " .. onRidge)
    t.truthy(ended:find("ground check)" .. note(onRidge), 1, true), onRidge .. " frames on the ridge: " .. ended)

    -- The frames count in a row: a slide that crosses a short ridge (x = 500 to 600) and
    -- ends later, on a floor that is used, says nothing of it.
    local leaned = 0
    local later, _, last = slideUntil(ramp(20, 300, 1e6), "Slope: the slide up the slope ended at ", 80,
        function(x, nx, ny, nz)
            if x >= 500 and x < 600 then
                leaned = leaned + 1
                return 0.6, 0, 0.8
            end
            return nx, ny, nz
        end)
    t.truthy(leaned >= 3 and last == 0, "frames on the ridge, and none at the end: " .. leaned .. ", " .. last)
    t.falsy(later:find("on its edge", 1, true), later)

    -- And a slope that ends without an edge to round (the fake's own point of a
    -- character) says nothing.
    local g = running()
    g.terrain = function(x)
        if x >= 700 then
            return 400 * tan - 300, 0, 0, 1
        end
        return slope(x)
    end
    runFastTo(g, 2000, 300)
    t.truthy(untilMode(g, 3, 60), "off the end")
    g.frame()
    t.contains(g.log, "Slope: off the end of the slope at ")
    t.absent(g.log, "on its edge")
    noErrors(g)
end)

t.test("a flight off a slope starts with the slide's rise, and Unreal's update takes the frame's gravity off once",
    function()
        -- Along a 20 degree slope the slide's velocity runs along it: its rise is its speed
        -- over the ground times tan 20. 0.3.0 handed Unreal that less a frame of gravity,
        -- and Unreal's falling update then took the same frame's gravity off again.
        local tan = math.tan(math.rad(20))
        local slope = ramp(20, 300, 700)
        local function withDrop(x)
            if x >= 700 then
                return 400 * tan - 300, 0, 0, 1 -- a drop at the top: Unreal walks off it
            end
            return slope(x)
        end
        for _, case in ipairs({ { "flew off the slope", slope }, { "off the end of the slope", withDrop } }) do
            local g = running()
            g.terrain = case[2]
            runFastTo(g, 2000, 300)
            -- The velocity the mod hands to Unreal's update, and the movement mode it finds.
            local walk, handed = g.moveTick, nil
            g.moveTick = function(dt)
                local v = fake.props(g.cmc).Velocity
                handed = { x = v.X, z = v.Z, mode = g.mode() }
                walk(dt)
            end
            for _ = 1, 120 do
                g.frame()
                if handed.mode == 3 then
                    break
                end
            end
            t.eq(handed.mode, 3, case[1] .. ": in the air")
            t.contains(g.log, "Slope: " .. case[1])
            t.near(handed.z, handed.x * tan, 0.5, case[1] .. ": it flies on as it slid, along the slope")
            t.near(velocityZ(g), handed.z - GRAVITY / 60, 1e-6, case[1] .. ": less one frame of Unreal's gravity")
            noErrors(g)
        end
    end)

t.test("a long frame during a slide: the slide's gravity covers the whole frame, as Unreal's walk does", function()
    -- 0.3 s of a slide in one frame (a stutter) or in 18 frames: the speed afterwards is
    -- the same. 0.3.0 counted 0.1 s of the long frame's gravity, though Unreal walked all of it.
    local function speedAfter(stutter)
        local g = running()
        g.terrain = ramp(20, 300, 1e6)
        runFastTo(g, 2000, 300)
        g.frames(5)
        t.contains(g.log, "Slope: ran into a 20 degree slope")
        if stutter then
            g.frame(0.3)
        else
            g.frames(18)
        end
        g.frame()
        t.eq(g.mode(), 1, "Unreal still walks it up the slope")
        t.absent(g.log, "the slide up the slope ended")
        noErrors(g)
        return g.speed()
    end
    local steady, stutter = speedAfter(false), speedAfter(true)
    t.near(stutter, steady, 1, "the same speed after 0.3 s of sliding, in one frame or in 18")
end)

t.test("a frame so long that its gravity would turn a slide back down the slope stops it instead", function()
    local g = running()
    g.terrain = ramp(44, 300, 1e6)
    runFastTo(g, 1200, 300)
    g.frames(3)
    t.contains(g.log, "Slope: ran into a 44 degree slope")
    t.absent(g.log, "the slide up the slope ended")
    -- (Unreal's own longest frame is 0.4 s by default, too short for this on a slope it walks.)
    g.frame(1)
    t.contains(g.log, "Slope: the slide up the slope ended at 0 u/s")
    t.eq(g.speed(), 0, "it stopped, and doesn't slide back")
    noErrors(g)
end)

-- Hops along the plane with W and Space held, at 60 fps, until a frame of `long` seconds
-- would bring the character down, and runs that long frame. Returns the speed before it.
local function landInLongFrame(g, speed, long)
    fake.props(g.cmc).Velocity.X = speed * SCALE
    g.keys.W, g.keys.SpaceBar = true, true
    g.frame()
    for _ = 1, 400 do
        -- Where a frame of that length would take it (the fake moves with the average of
        -- the old and the new velocity, as Unreal does).
        local v = fake.props(g.cmc).Velocity
        local z = g.position.Z + (v.Z - GRAVITY * long / 2) * long
        if z <= g.groundAt(g.position.X + v.X * long, 0) then
            local before = g.speed()
            g.frame(long)
            t.eq(g.mode(), 1, "landed in the long frame")
            return before
        end
        g.frame()
        t.eq(g.mode(), 3, "still in the air")
    end
    error("never came down")
end

t.test("a landing in a frame longer than Unreal's MaxSimulationTimeStep is decided like any other", function()
    -- Unreal moves a frame over 0.05 s in several steps and lands in one of them, but the
    -- fall is the same parabola, so where the Half-Life updates fell is worked out as in
    -- any frame. Down 20 degrees from 576 u/s the hop runs into the slope, falling 688
    -- u/s (see above), also if its last frame is 0.06 s long. 0.3.0, which took the fall
    -- from the end of the landing frame, left such landings alone.
    local g = running()
    g.terrain = plane(g, -20)
    landInLongFrame(g, 576, 0.06)
    g.frame()
    t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154). It ran into the "
        .. "slope: the Half-Life update before it ended 2.4 units above the slope")
    noErrors(g)
    -- And one the ground check sets down (up 15 degrees from 320 u/s, see above).
    g = running()
    g.terrain = plane(g, 15)
    landInLongFrame(g, 320, 0.06)
    g.frame()
    t.contains(g.log, "Slope: landed on a 15 degree slope at 320 u/s: the speed stays. A Half-Life update ended 1.2 "
        .. "units above the slope")
    noErrors(g)
end)

t.test("a landing the mod can't place keeps its speed and says why: a frame over 0.1 s, a pause, another floor, "
    .. "gravity it couldn't read",
    function()
        -- A frame longer than the 0.1 s the mod counts (a stutter): the Half-Life updates
        -- no longer keep time with Unreal there.
        local g = running()
        g.terrain = plane(g, -20)
        local before = landInLongFrame(g, 576, 0.25)
        g.frame()
        t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s: the speed stays. The mod can't tell whether "
            .. "a Half-Life update would have run into it (the frame was longer than the mod counts)")
        t.near(g.speed(), before, 0.5, "the speed stays")
        t.contains(g.log, ", slope: speed kept (can't tell how it landed), ")
        t.absent(g.log, "It ran into the slope")
        g.press(F8)
        t.contains(g.log, "landings on one 1 (0 ran into it: +0 and -0 u/s in all; 0 set down first by the ground "
            .. "check, speed kept; 1 not told apart, speed kept)")
        noErrors(g)

        -- A pause that begins on the frame after the landing: what the mod wrote before
        -- isn't used after a pause.
        g = running()
        g.terrain = plane(g, -20)
        fake.props(g.cmc).Velocity.X = 576 * SCALE
        g.keys.W, g.keys.SpaceBar = true, true
        g.frame()
        t.truthy(untilMode(g, 1), "landed")
        g.paused = true
        g.frames(5)
        g.paused = false
        g.frame()
        t.contains(g.log, "The mod can't tell whether a Half-Life update would have run into it (the mod has nothing "
            .. "from the frame before, as after a pause)")
        t.near(g.speed(), 576 * SCALE, 0.05, "the speed stays")
        noErrors(g)

        -- A floor that isn't the plane it came down on: a slope 15 cm higher than the
        -- ground before it, which the hop reaches in mid-fall (the fake lands a character
        -- on any ground it dips below; in the game, a ledge the capsule catches). The
        -- character was under that slope's plane on the frame before.
        g = running()
        runTo(g, MAX_SPEED)
        g.keys.W = false
        local x = g.position.X
        local tan, s, c = math.tan(math.rad(10)), math.sin(math.rad(10)), math.cos(math.rad(10))
        g.terrain = function(at)
            if at <= x + 510 then
                return 0, 0, 0, 1
            end
            return 35 + (at - x - 510) * tan, -s, 0, c
        end
        -- (0.633 s after the jump it is 507 cm on and 24 cm up, short of the edge; a
        -- frame later it would be 520 cm on and 14 cm up, under the raised slope.)
        jump(g)
        t.truthy(untilMode(g, 1), "landed")
        t.truthy(g.position.Z > 35, "on the raised slope")
        g.frame()
        t.contains(g.log, "Slope: landed on a 10 degree slope at 320 u/s: the speed stays. The mod can't tell whether "
            .. "a Half-Life update would have run into it (the floor isn't the plane it came down on)")
        noErrors(g)

        -- And one lower than that plane: Unreal walked the rest of the landing's frame down
        -- a step of 30 cm (its floor check reaches 47 cm below), so the path doesn't reach
        -- the plane of the floor it ends on within the frame. Down 20 degrees from 576 u/s,
        -- which on the plane it came down on runs into it (see above).
        g = running()
        g.terrain = plane(g, -20)
        fake.props(g.cmc).Velocity.X = 576 * SCALE
        g.keys.W, g.keys.SpaceBar = true, true
        g.frame()
        t.truthy(untilMode(g, 1), "landed")
        local still, edge = g.terrain, g.position.X - 1
        g.terrain = function(at, y)
            local z, nx, ny, nz = still(at, y)
            return at > edge and z - 30 or z, nx, ny, nz
        end
        g.position.Z = g.position.Z - 30
        g.frame()
        t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s: the speed stays. The mod can't tell whether "
            .. "a Half-Life update would have run into it (the floor isn't the plane it came down on)")
        t.near(g.speed(), 576 * SCALE, 0.05, "the speed stays")
        noErrors(g)

        -- The game's gravity couldn't be read as the mod took over, so it stays the game's
        -- own: the fall isn't the parabola the mod would work with.
        g = start()
        local unreadable = true
        fake.method(g.cmc, "GetGravityZ", function()
            return unreadable and 0 or -980 * fake.props(g.cmc).GravityScale
        end)
        g.loadSave()
        g.frames(SETTLE_FRAMES)
        unreadable = false
        t.contains(g.log, "Could not read the game's gravity")
        g.terrain = plane(g, -20)
        hopAlong(g, 576, 1)
        t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s: the speed stays. The mod can't tell whether "
            .. "a Half-Life update would have run into it (the game's gravity isn't known)")
        noErrors(g)
    end)

t.test("a pause in the middle of a hop doesn't shift Half-Life's updates: the landings are decided as without it",
    function()
        -- Down 20 degrees from 576 u/s: a hit, a hit, then set down (see above).
        local g = running()
        g.terrain = plane(g, -20)
        fake.props(g.cmc).Velocity.X = 576 * SCALE
        g.keys.W, g.keys.SpaceBar = true, true
        local kinds = {}
        local seen = #g.log
        for i = 1, 400 do
            g.paused = (i >= 20 and i < 33) or (i >= 100 and i < 104) or (i >= 180 and i < 250)
            g.frame()
            for k = seen + 1, #g.log do
                if g.log[k]:find("] Hop ", 1, true) then
                    kinds[#kinds + 1] = landingKind(g.log[k])
                end
            end
            seen = #g.log
            if #kinds == 3 then
                break
            end
        end
        t.eq(table.concat(kinds, " "), "hit hit caught")
        t.contains(g.log, "falling 688 u/s: 730 u/s (+154)")
        noErrors(g)
    end)

t.test("a stutter in the middle of a hop doesn't shift Half-Life's updates: they count the whole frame, not the 0.1 s "
    .. "the mod simulates of it", function()
    -- Unreal moves the character for all of a 0.25 s frame, so the hop's updates go on
    -- 1/100 s apart through all of it. Down 20 degrees from 576 u/s: a hit, a hit, then
    -- set down, as without the stutter. (Counted with the 0.1 s, the first landing is
    -- set down, wherever in the hop's first 0.7 s the stutter comes.) The speeds are the
    -- model's to 0.1 u/s: the braking added back in the long frame is that of 0.1 s.
    local model = halfLifeHops(-20, 576, 100, 3)
    local g = running()
    g.terrain = plane(g, -20)
    g.frame()
    local landed = hopAlong(g, 576, 3, function(frame)
        return frame == 20 and 0.2537 or 1 / 60
    end)
    for i = 1, 3 do
        t.eq(landed[i].kind, model[i].kind, "landing " .. i .. ": " .. landed[i].line)
        t.near(landed[i].speed, model[i].speed, 0.1, "the speed after landing " .. i)
    end
    -- The hop line counts all of the long frame too: 1.19 s in the air at 48 fps (without
    -- the stutter 1.18 s at 60 fps; counted with the 0.1 s, it read 1.03 s at 55 fps).
    t.truthy(landed[1].line:find("(48 fps, ", 1, true) and landed[1].line:find(", 1.19 s in the air", 1, true),
        landed[1].line)
    noErrors(g)
end)

t.test("Unreal's walking gap doesn't change how a landing is decided, also when it spans a frame", function()
    -- Unreal walks a character about 2.15 cm above the floor and lands a falling one when
    -- it touches the floor itself: 0.9 units lower than where it took off, a few
    -- milliseconds later, and at a high frame rate in a later frame. The floor Half-Life's
    -- player would stand on is where the character walks, so the hops land as in the
    -- model.
    for _, fps in ipairs({ 60, 240 }) do
        for _, hop in ipairs({ { -20, 576 }, { 5, 370 }, { 15, 320 } }) do
            local what = string.format("%d degrees from %d u/s at %d fps", hop[1], hop[2], fps)
            local model = halfLifeHops(hop[1], hop[2], 100, 4)
            local g = running()
            g.terrain = plane(g, hop[1])
            g.frame(1 / fps)
            t.near(g.position.Z, fake.FLOOR_DIST, 1e-9, "walking at its gap above the floor")
            local landed = hopAlong(g, hop[2], 4, 1 / fps)
            for i = 1, 4 do
                t.eq(landed[i].kind, model[i].kind, what .. ", landing " .. i .. ": " .. landed[i].line)
                t.near(landed[i].speed, model[i].speed, 0.05, what .. ", the speed after landing " .. i)
            end
            noErrors(g)
        end
    end
end)

-- Has the character stand `gap` cm above the floor under it (Unreal: 1.9 to 2.4, and
-- 2.15 after a landing), with CurrentFloor.FloorDist saying so.
local function standAt(g, gap)
    g.position.Z = g.groundAt(g.position.X, g.position.Y) + gap
    fake.props(g.cmc).CurrentFloor.FloorDist = gap
end

t.test("a walking height that differs between the take-off and the landing doesn't change how the landing is "
    .. "decided: the floor's distance is read at both", function()
    -- Unreal holds a walking character 1.9 to 2.4 cm above the floor, and at 2.15 cm
    -- after a landing. Taken from 1.9 or 2.4 cm up, a hop is 0.1 units off the one
    -- Half-Life's player makes from its floor: a twentieth of the ground check's reach,
    -- enough for a landing near the edge between the two kinds. So the mod reads
    -- CurrentFloor.FloorDist where a hop takes off and where it lands, and takes the
    -- difference out.
    --   Up 10 degrees from 320 u/s the update before the landing ends 2.06 units above
    --   the slope's plane, and the next would end 0.02 behind it: it runs into the slope
    --   (-36 u/s). Taken 0.1 units off, either way, it would be set down.
    --   Up 5 degrees from 370 u/s it is set down 0.006 units above the plane (see above).
    --   Taken 0.1 units lower it would run into the slope.
    for _, gap in ipairs({ 1.9, 2.4 }) do
        for _, hop in ipairs({ { 10, 320, "hit" }, { 5, 370, "caught" } }) do
            local what = string.format("%d degrees from %d u/s, taking off %.1f cm above the floor", hop[1], hop[2],
                gap)
            local model = halfLifeHops(hop[1], hop[2], 100, 2)
            t.eq(model[1].kind, hop[3], what .. ": the model")
            local g = running()
            g.terrain = plane(g, hop[1])
            g.frame()
            standAt(g, gap)
            local landed = hopAlong(g, hop[2], 2)
            for i = 1, 2 do
                t.eq(landed[i].kind, model[i].kind, what .. ", landing " .. i .. ": " .. landed[i].line)
                t.near(landed[i].speed, model[i].speed, 0.05, what .. ", the speed after landing " .. i)
            end
            noErrors(g)
        end
    end
end)

t.test("a FloorDist that can't be Unreal's walking gap (negative, huge, not a number) isn't used: the landing is "
    .. "decided with the two gaps taken as equal", function()
    -- What UE4SS reads of CurrentFloor.FloorDist in the game isn't known yet. Only 0 to 3
    -- cm is taken for the gap Unreal walks the character at: anything else would put the
    -- floor's plane far off, or make the height not a number. Read at each landing (and so
    -- at the take-off in the same frame), down 20 degrees from 576 u/s: a hit, a hit, then
    -- set down, as the model has it.
    local model = halfLifeHops(-20, 576, 100, 3)
    local g = running()
    g.terrain = plane(g, -20)
    g.frame()
    local floor, readings, landings, before = fake.props(g.cmc).CurrentFloor, { 0 / 0, 1e9, -5 }, 0, g.mode()
    local landed = hopAlong(g, 576, 3, function()
        -- (Before each frame: one that starts on the ground after one that started in the
        -- air is the landing's, whose hook reads the floor.)
        local mode = g.mode()
        if mode == 1 and before == 3 then
            landings = landings + 1
            floor.FloorDist = readings[landings] or floor.FloorDist
        end
        before = mode
        return 1 / 60
    end)
    t.eq(landings, 3, "a number read at each landing")
    for i = 1, 3 do
        t.eq(landed[i].kind, model[i].kind, "landing " .. i .. ": " .. landed[i].line)
        t.near(landed[i].speed, model[i].speed, 0.05, "the speed after landing " .. i)
    end
    t.absent(g.log, "nan", "no height that isn't a number")
    t.absent(g.log, "can't tell")
    noErrors(g)
end)

t.test("a slide up a slope ends as Half-Life's does: at the update that finds the rise at 180 u/s or less, half an "
    .. "update of gravity after its last clip, with the speed that clip left", function()
    -- The mod's slide against the step-by-step model above, at 60 and 144 fps: the speed
    -- once it is on the ground again (the held jump starts there, so no friction is taken).
    --   Up 20 degrees from 640 u/s the hop comes back to the slope still rising 200 u/s,
    --   too fast for the ground check: it runs into the slope and slides for 50 updates.
    --   Up 25 degrees from 600 u/s the jump itself runs into the slope.
    -- (0.3.0 took a frame's gravity off, clipped again and then compared with 180 u/s:
    -- its slides ended later, 9 to 13 u/s slower on 20 degrees.)
    for _, case in ipairs({ { 20, 640, 100, 503.53 }, { 20, 640, 144, 500.50 }, { 25, 600, 100, 391.84 } }) do
        local angle, speed, rate = case[1], case[2], case[3]
        local model = halfLifeHops(angle, speed, rate, 1)[1]
        t.eq(model.kind, "slide")
        t.near(model.speed, case[4], 0.01, "the model's slide ends at")
        for _, fps in ipairs({ 60, 144 }) do
            local what = string.format("%d degrees from %d u/s at %d fps with PhysicsRate %d", angle, speed, fps, rate)
            local g = running({ PhysicsRate = rate })
            g.terrain = plane(g, angle)
            fake.props(g.cmc).Velocity.X = speed * SCALE
            g.keys.W, g.keys.SpaceBar = true, true
            local ended = false
            for _ = 1, 3 * fps do
                g.frame(1 / fps)
                if count(g.log, "Slope: the slide up the slope ended at ") > 0 then
                    ended = true
                    break
                end
            end
            t.truthy(ended, what .. ": the slide ended")
            t.eq(count(g.log, "sliding up it at "), 1, what .. ": one slide")
            t.eq(g.mode(), 3, what .. ": the held jump started in the same frame")
            t.near(g.speed() / SCALE, model.speed, 0.05, what .. ": the speed the slide ended with")
            noErrors(g)
        end
    end
end)

t.test("a rise of 180 to 184 u/s against a slope starts no slide: Half-Life's next ground check has the player on "
    .. "the ground", function()
    -- Running into a 20 degree slope, the clip leaves a rise of the speed times 0.3214.
    -- Half-Life is in the air at the end of that update if it is over 180 u/s, but at the
    -- start of the next, half an update of gravity later (4 u/s), on the ground again
    -- unless it is still over 180: friction every update, and it may jump. So a slide
    -- starts from a rise over 184 u/s. (0.3.0 began one at 180, and ended it a frame later.)
    local function runInto(speed)
        local g = running()
        g.terrain = ramp(20, 300, 20000)
        runFastTo(g, speed * SCALE, 300)
        fake.props(g.cmc).Velocity.X = speed * SCALE
        g.frame()
        t.eq(g.mode(), 1)
        noErrors(g)
        return g
    end
    local g = runInto(566) -- rising 181.9 u/s
    t.absent(g.log, "Slope:")
    g.frames(20)
    t.absent(g.log, "Slope:")
    g = runInto(580) -- rising 186.4 u/s
    t.contains(g.log, "Slope: ran into a 20 degree slope at 580 u/s: sliding up it, rising 186 u/s")

    -- The same at a landing that runs into a slope: a hop from level ground at 550 u/s onto
    -- 25 degrees. With the foot 225 units ahead it hits falling 152 u/s and the clip leaves
    -- a rise of 183.5 u/s: no slide. With the foot 216 units ahead it hits falling 144 u/s,
    -- and the rise of 184.9 u/s slides.
    local function hopOnto(distance)
        g = running()
        local foot = g.position.X + distance * SCALE
        g.terrain = ramp(25, foot, foot + 1e6)
        fake.props(g.cmc).Velocity.X = 550 * SCALE
        g.keys.SpaceBar = true
        for _ = 1, 200 do
            g.frame()
            if count(g.log, "Slope: landed on a ") > 0 then
                break
            end
        end
        noErrors(g)
        return g
    end
    g = hopOnto(225)
    t.contains(g.log, "Slope: landed on a 25 degree slope at 550 u/s, falling 152 u/s: 394 u/s (-156). It ran into "
        .. "the slope")
    t.absent(g.log, "sliding up it")
    g = hopOnto(216)
    t.contains(g.log, "Slope: landed on a 25 degree slope at 550 u/s, falling 144 u/s: sliding up it at 397 u/s, "
        .. "rising 185 u/s")
end)

t.test("at 250 updates a second the update after a clip can stop short of the slope (Half-Life's player rests 1/32 "
    .. "unit off it): a slide from a rise just over 180 u/s is on the ground again an update or a few later, as in "
    .. "Half-Life", function()
    -- Above about 160 updates a second one update's gravity closes less than the 1/32
    -- unit, so a move just after a clip may not reach the slope and keeps its gravity,
    -- with no clip to give it back: the ground checks after it see the rise less one and
    -- one and a half updates of gravity (3.2 u/s an update at 250). Running into 8 degrees
    -- with no keys, the first move after the ground clip closes 0.027 units of the 1/32:
    -- from a rise of 184 u/s Half-Life's next ground check finds 179.2 and the player on
    -- the ground, with friction (HL-V's reference: one update in the air, then the ground
    -- at 1335 u/s). 0.3.1 clipped every update and slid on for 97 updates. From 186 u/s
    -- the checks stay over 180, the next move reaches the slope and the slide goes on.
    local function runInto(speed)
        local g = running({ PhysicsRate = 250 })
        g.terrain = ramp(8, 1000, 1e9)
        runFastTo(g, speed * SCALE, 1000 - speed * SCALE / 500, 1 / 250)
        local ran, ended, rise
        for i = 1, 40 do
            local seen = #g.log
            g.frame(1 / 250)
            for k = seen + 1, #g.log do
                if g.log[k]:find("Slope: ran into", 1, true) then
                    ran, rise = i, tonumber(g.log[k]:match("rising (%d+) u/s"))
                elseif g.log[k]:find("Slope: the slide up the slope ended", 1, true) then
                    ended = ended or i
                end
            end
        end
        noErrors(g)
        return g, ran, ended, rise
    end
    local g, ran, ended, rise = runInto(1360)
    t.truthy(ran, "it ran into the slope")
    t.eq(rise, 184, "the rise the ground clip left")
    t.eq(ended and ended - ran, 1, "frames until it is on the ground again (one update in the air)")
    t.eq(g.mode(), 1)
    t.truthy(g.speed() / SCALE < 1200, "friction slows it once it is on the ground: " .. g.speed() / SCALE)
    g, ran, ended, rise = runInto(1375)
    t.truthy(ran, "it ran into the slope")
    t.eq(rise, 186, "the rise the ground clip left")
    t.eq(ended, nil, "still sliding 40 updates later")
    t.truthy(g.speed() / SCALE > 1300, "no friction in the slide: " .. g.speed() / SCALE)
    -- A landing that runs into the slope, on any slope: off a ledge 3.96 m high at 700 u/s
    -- (689 u/s after the walk-off's update of friction) onto 20 degrees, the clip leaves
    -- 508.47 u/s rising 185.07. The reference model of Half-Life's updates the 0.3.1 review
    -- compared with (from the same walk-off, without its edge friction, which the mod
    -- hasn't got): 3 updates in the air (the first and the third fall short of the slope),
    -- on the ground at 506.41 u/s. 0.3.1 slid 10 updates
    -- and ended at 498. (Only ledges from 3.958 to 3.963 m run into the slope here: from
    -- 4 m, Half-Life's last update before it ends 1.5 units above it, and the landing is
    -- set down. The fall from a ledge starts with half an update of gravity, see "walking
    -- off a ledge onto a slope ...")
    g = running({ PhysicsRate = 250 })
    local x0, a = g.position.X + 300, math.rad(20)
    g.terrain = function(x)
        if x <= x0 then
            return 0, 0, 0, 1
        end
        return -396 + (x - x0) * math.tan(a), -math.sin(a), 0, math.cos(a)
    end
    for _ = 1, 2000 do
        if g.mode() == 3 then
            break
        end
        fake.props(g.cmc).Velocity.X = 700 * SCALE
        g.frame(1 / 250)
    end
    local landedAt, endedAt, line
    for i = 1, 250 do
        local seen = #g.log
        g.frame(1 / 250)
        for k = seen + 1, #g.log do
            if g.log[k]:find("sliding up it at 508 u/s, rising 185 u/s", 1, true) then
                landedAt = i
            elseif g.log[k]:find("Slope: the slide up the slope ended", 1, true) then
                endedAt, line = endedAt or i, line or g.log[k]
            end
        end
    end
    t.truthy(landedAt, "the landing ran into the slope and slides")
    t.eq(endedAt and endedAt - landedAt, 3, "updates until it is on the ground again")
    t.truthy(line and line:find("ended at 506 u/s", 1, true), tostring(line))
    noErrors(g)
end)

t.test("on a moving platform with a sloped floor, landings are decided as on still ground", function()
    -- The platform's motion is taken out: the floor is taken where it was when the
    -- character came down, and the velocity relative to it. Down 20 degrees from 576 u/s:
    -- a hit (to 729.63 u/s), a hit (to 901.29), then set down (see above). Each landing's
    -- kind and the height its hop line gives must be still ground's. (At 300 cm/s along
    -- the slope the platform moves the floor 1.8 cm up or down under the character in a
    -- frame: taken where it is at the frame's end, all three landings would be set down.
    -- At 150 cm/s they would keep their kinds, and only the heights would move, by 0.1 to
    -- 0.4 units; with the velocity not taken relative to the platform, the same.)
    local cases = {
        { name = "sideways and along the slope", platform = { X = 300, Y = 160, Z = 0 } },
        { name = "rising too", platform = { X = -120, Y = 0, Z = 60 } },
        { name = "with bStayBasedInAir", platform = { X = 300, Y = 160, Z = 0 }, stay = true },
        { name = "with bStayBasedInAir, rising too", platform = { X = -120, Y = 0, Z = 60 }, stay = true },
    }
    local function kindsAndHeights(landed)
        local seen = {}
        for i, landing in ipairs(landed) do
            seen[i] = landing.kind .. " " .. tostring(landing.line:match(" from ([%d%.]+) u up"))
        end
        return table.concat(seen, ", ")
    end
    local onStillGround
    do
        local g = running()
        g.terrain = plane(g, -20)
        g.frames(3)
        onStillGround = kindsAndHeights(hopAlong(g, 576, 3))
        t.eq(onStillGround, "hit 2.4, hit 2.6, caught 0.6", "still ground")
        noErrors(g)
    end
    for _, case in ipairs(cases) do
        local g = running(nil, { stayBasedInAir = case.stay })
        local platform, still, began = case.platform, plane(g, -20), g.worldTime
        g.baseVelocity = platform
        g.terrain = function(x, y)
            local moved = g.worldTime - began
            local z, nx, ny, nz = still(x - platform.X * moved, y - platform.Y * moved)
            return z + platform.Z * moved, nx, ny, nz
        end
        g.frames(3)
        local landed = hopAlong(g, 576, 3)
        t.eq(kindsAndHeights(landed), onStillGround, case.name)
        -- (In the air the velocity has the platform's in it, unless the character stays
        -- based on it.)
        local v = fake.props(g.cmc).Velocity
        local x, y = v.X - (case.stay and 0 or platform.X), v.Y - (case.stay and 0 or platform.Y)
        t.near(math.sqrt(x * x + y * y) / SCALE, 901.29, 0.05, case.name .. ": the speed over the platform")
        t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154)")
        t.absent(g.log, "can't tell")
        noErrors(g)
    end
end)

t.test("the landing of the game's own jump is decided like the mod's, and a cap inside the landing's move doesn't "
    .. "change it", function()
    -- The game's jump (an input the mod doesn't read) starts in Unreal's update, on the
    -- frame's hook: the Half-Life updates count from there. (No friction, so that the
    -- frame on the ground before it leaves the 576 u/s.)
    local g = running({ Friction = 0 })
    g.terrain = plane(g, -20)
    g.frame()
    -- First a hop of the mod's on the spot, from a walking height far from the one a
    -- landing leaves: the floor's distance it read there is not the game's jump's, and
    -- taken for it, it would have the landing below set down.
    standAt(g, 1)
    jump(g)
    t.truthy(untilMode(g, 1), "landed")
    g.frames(2)
    t.eq(g.speed(), 0, "the hop on the spot was set down")
    fake.props(g.cmc).Velocity.X = 576 * SCALE
    g.pressedJump = true
    g.frame()
    t.eq(g.gameJumps, 1, "the game jumped")
    t.truthy(untilMode(g, 1), "landed")
    g.frame()
    t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154). It ran into the "
        .. "slope: the Half-Life update before it ended 2.4 units above the slope")
    noErrors(g)

    -- A listener of the landing's mode change that caps the speed inside the move (the
    -- game's speed limiter may be one): the character walks less far along the slope,
    -- but still on its plane. KeepSpeed undoes the cut first.
    g = running(nil, { landingListenerClamps = true, maxSpeedIgnoresWalkSpeed = true })
    g.terrain = plane(g, -20)
    local landed = hopAlong(g, 576, 1)
    t.eq(g.landingClamps, 1, "the game capped the speed at the landing")
    t.contains(g.log, "to 260 u/s (on landing")
    t.eq(landed[1].kind, "hit", landed[1].line)
    t.contains(g.log, "Slope: landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154)")
    noErrors(g)
end)

t.test("walking off a ledge onto a slope: Half-Life's updates count from where the fall starts, the hook after "
    .. "Unreal walked off", function()
    -- Half-Life leaves the ground at the end of an update: its ground check finds no
    -- floor there, and the fall starts with the next update. That update ends in the
    -- air, so the second half of its gravity stays on: the fall starts at -4 u/s. Unreal
    -- walks the whole frame along the floor, past the edge, and falls from the next frame
    -- on, from 0: the first hook the mod sees it in the air is where the updates count
    -- from. (The game's own jump starts a frame earlier, at the hook before the one that
    -- first sees it.) The model: a point that starts `height` units above the plane
    -- below, moving level.
    local function halfLifeDrop(angle, speed, height)
        local tan, nx, nz = math.tan(math.rad(angle)), -math.sin(math.rad(angle)), math.cos(math.rad(angle))
        local dt = 1 / 100
        local x, z, vx, vz = 0, height, speed, -0.5 * 800 * dt
        for _ = 1, 1000 do
            local above = z - x * tan
            if above < 2 then
                return "caught", vx
            end
            vz = vz - 0.5 * 800 * dt
            if above + (vz - vx * tan) * dt < 0 then
                local into = vx * nx + vz * nz
                return "hit", vx - into * nx
            end
            x, z = x + vx * dt, z + vz * dt
            vz = vz - 0.5 * 800 * dt
        end
        error("never came down")
    end
    local tan, s, c = math.tan(math.rad(-10)), math.sin(math.rad(-10)), math.cos(math.rad(-10))
    local kinds = { caught = 0, hit = 0 }
    for drop = 98, 106 do
        local what = "a drop of " .. drop .. " cm"
        local g = running()
        runTo(g, MAX_SPEED)
        local edge = g.position.X + 30
        local function below(x) -- a slope about 1 m under the ledge, falling away at 10 degrees
            return -drop + (x - edge) * tan
        end
        g.terrain = function(x)
            if x <= edge then
                return 0, 0, 0, 1
            end
            return below(x), -s, 0, c
        end
        t.truthy(untilMode(g, 3, 20), what .. ": walked off")
        t.eq(velocityZ(g), 0, "the fall starts on the next frame")
        -- Half-Life's player rests 1/32 unit above the ledge it walked on; the character
        -- walked 2.15 cm above it.
        local height = (g.position.Z - fake.FLOOR_DIST - below(g.position.X)) / SCALE + 1 / 32
        local kind, speed = halfLifeDrop(-10, 320, height)
        kinds[kind] = kinds[kind] + 1
        g.frame()
        t.near(velocityZ(g), -0.5 * GRAVITY / 100 - GRAVITY / 60, 1e-3, what .. ": the fall starts with the half "
            .. "update of gravity Half-Life's update that walked off ended with")
        t.truthy(untilMode(g, 1), what .. ": landed")
        g.frame()
        if kind == "hit" then
            t.contains(g.log, "Slope: landed on a 10 degree slope at 320 u/s, falling ", what)
            t.absent(g.log, "the speed stays", what)
        else
            t.contains(g.log, "Slope: landed on a 10 degree slope at 320 u/s: the speed stays. A Half-Life update "
                .. "ended ", what)
        end
        -- (W is held: on the ground again, a frame of friction and acceleration at most.)
        t.truthy(g.speed() / SCALE <= speed + 0.01 and g.speed() / SCALE >= math.min(speed * 0.96 ^ 2, 320) - 0.5,
            string.format("%s: %s, %.2f u/s after it, the model %.2f", what, kind, g.speed() / SCALE, speed))
        noErrors(g)
    end
    t.truthy(kinds.caught >= 2 and kinds.hit >= 2, string.format("both kinds are in the cases: %d set down, %d ran "
        .. "into the slope", kinds.caught, kinds.hit))
end)

t.test("deciding a landing costs no game calls, and of reads only the floor's: hopping on a slope costs what it does "
    .. "with slopes off, but for the floor at a landing and at a take-off", function()
    -- What it uses was read already (the character's location every frame, a platform's
    -- velocity at a landing), but for the floor: CurrentFloor at a landing, with the 11
    -- flags and numbers of its normals as in 0.3.0 (5 on level ground) and now how far
    -- above it the character stands (FloorDist); and at a take-off from a floor not read
    -- in that frame, CurrentFloor with two flags and that distance.
    local function cost(angle, config, speed)
        local g = running(config)
        g.frames(200) -- after the automatic report
        t.contains(g.log, "diagnostics (automatic", "the automatic report came first")
        g.terrain = plane(g, angle)
        g.frames(3) -- the floor under it is the plane's now
        fake.props(g.cmc).Velocity.X = (speed or 576) * SCALE
        g.keys.W, g.keys.SpaceBar = true, true
        local air, landing, takeoff = {}, nil, nil
        local landings = g.landings
        for _ = 1, 400 do
            local calls, reads, fields, mode = fake.counts.calls, fake.counts.reads, fake.counts.fields, g.mode()
            local landed = g.landings > landings -- the mod handles the landing in this frame, and jumps
            landings = g.landings
            g.frame()
            local used = { calls = fake.counts.calls - calls, reads = fake.counts.reads - reads,
                fields = fake.counts.fields - fields }
            if landed then
                landing = landing or used
            elseif mode == 1 and g.mode() == 3 then
                takeoff = takeoff or used
            elseif mode == 3 and g.mode() == 3 then
                air[#air + 1] = used
            end
            if landing and #air > 100 then
                break
            end
        end
        table.sort(air, function(a, b)
            return a.calls + a.reads + a.fields < b.calls + b.reads + b.fields
        end)
        -- A frame in the air without a refresh, the first take-off's frame, and a landing's.
        return air[1], takeoff, landing
    end
    local off = { SlopeLandings = false, SlopeBoosts = false }
    local offAir, offTakeoff, offLanding = cost(-20, off, 320)
    local air, takeoff, landing = cost(-20, nil, 320)
    t.eq(air.calls, offAir.calls, "game calls on a frame in the air")
    t.eq(air.reads, offAir.reads, "reads on a frame in the air")
    t.eq(air.fields, offAir.fields, "struct fields read on a frame in the air")
    t.eq(landing.calls, offLanding.calls, "game calls on the landing's frame")
    t.eq(landing.reads, offLanding.reads + 1, "reads on the landing's frame: the floor, once")
    t.eq(landing.fields, offLanding.fields + 12, "fields of the floor at a landing on a slope: 11 and its distance")
    -- The first take-off, at 320 u/s (faster, the floor is read anyway for the slope boosts).
    t.eq(takeoff.calls, offTakeoff.calls, "game calls on the take-off's frame")
    t.eq(takeoff.reads, offTakeoff.reads + 1, "reads on the take-off's frame: the floor, once")
    t.eq(takeoff.fields, offTakeoff.fields + 3, "fields of the floor read at a take-off: two flags and its distance")
    -- Level ground costs the same in the air; at a landing the floor's distance is read
    -- for the jump that follows in the same frame. (A level landing comes 17 frames
    -- before one down this slope, so one of the mod's half-second refreshes can fall on
    -- one and not the other: each is weighed against the same hops with slopes off.)
    local flatAir, flatTakeoff, flatLanding = cost(0, nil, 320)
    local _, _, offFlatLanding = cost(0, off, 320)
    t.eq(air.calls, flatAir.calls, "game calls in the air, over a slope and over level ground")
    t.eq(air.reads, flatAir.reads, "reads in the air, over a slope and over level ground")
    t.eq(air.fields, flatAir.fields, "fields in the air, over a slope and over level ground")
    t.eq(flatLanding.calls, offFlatLanding.calls, "game calls at a landing on level ground")
    t.eq(flatLanding.reads, offFlatLanding.reads + 1, "reads at a landing on level ground: the floor, once")
    t.eq(flatLanding.fields, offFlatLanding.fields + 6, "fields of the floor read at a landing on level ground")
    t.eq(flatTakeoff.fields, takeoff.fields, "fields at a take-off, on a slope and on level ground")
end)

-- With the rest of the mod -------------------------------------------------------------

t.test("KeepSpeed: the game's landing cut is undone before the slope's clip, and a slide brings no cut lines",
    function()
        local options = { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true }
        local g = running(nil, options)
        g.terrain = plane(g, 5)
        fake.props(g.cmc).Velocity.X = 282 * SCALE
        jump(g)
        t.truthy(untilMode(g, 1), "landed")
        g.frame()
        t.contains(g.log, "to 260 u/s (on landing")
        -- The same as without the game's cut (a landing that runs into the slope, see
        -- above): the clip starts from 282 u/s.
        t.contains(g.log, "Slope: landed on a 5 degree slope at 282 u/s, falling 216 u/s: 261 u/s (-21)")

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

t.test("root motion during a slide ends it: no flight from the old slide's rise afterwards", function()
    local g = running()
    g.terrain = ramp(20, 300, 30000)
    runFastTo(g, 2000, 300)
    g.frames(5)
    t.contains(g.log, "Slope: ran into a 20 degree slope")
    g.press(F8)
    t.contains(g.log, "; sliding up a slope now")
    -- The game plays root motion (the mod leaves the movement alone), which stops the character.
    g.rootMotion = true
    g.frames(3)
    local v = fake.props(g.cmc).Velocity
    v.X, v.Y, v.Z = 0, 0, 0
    g.rootMotion = false
    g.frames(30)
    t.eq(g.mode(), 1, "it stands on the slope")
    t.absent(g.log, "flew off the slope")
    t.absent(g.log, "First flight off a slope")
    g.press(F8)
    local last
    for _, line in ipairs(g.log) do
        last = line:find("  slopes (SlopeLandings", 1, true) and line or last
    end
    t.falsy(last:find("sliding up a slope now", 1, true), last)
    noErrors(g)
end)

t.test("a pause right after a landing on a slope: the landing is handled after it, without the slope's clip", function()
    -- A hop from level ground at 320 u/s onto a 10 degree slope that begins 200 cm ahead
    -- runs into it: the update before ends 2.5 units above it, and the clip takes 44 u/s.
    local function land(pause)
        local g = running()
        runTo(g, MAX_SPEED)
        g.keys.W = false
        local x = g.position.X
        g.terrain = ramp(10, x + 200, x + 20000)
        jump(g)
        t.truthy(untilMode(g, 1), "Unreal landed it")
        local landed = g.speed()
        if pause then
            g.paused = true
            g.frames(10)
            g.paused = false
        end
        g.frame()
        t.contains(g.log, "] Hop 1 (")
        noErrors(g)
        return g, landed
    end
    local g, landed = land(false)
    t.contains(g.log, "Slope: landed on a 10 degree slope at 320 u/s, falling 200 u/s: 276 u/s (-44). It ran into the "
        .. "slope: ")
    t.truthy(g.speed() < landed * 0.85, string.format("%.0f cm/s after, %.0f at the landing", g.speed(), landed))
    -- With a pause in between, how it fell is no longer known (what the mod wrote isn't
    -- kept over a pause): the speed stays, less the frame of friction both have.
    g, landed = land(true)
    t.contains(g.log, "Slope: landed on a 10 degree slope at 320 u/s: the speed stays. The mod can't tell whether a "
        .. "Half-Life update would have run into it (the mod has nothing from the frame before, as after a pause)")
    t.absent(g.log, "It ran into the slope")
    t.contains(g.log, ", slope: speed kept (can't tell how it landed), ")
    t.truthy(g.speed() <= landed and g.speed() > landed * 0.9, string.format("%.0f cm/s after, %.0f at the landing",
        g.speed(), landed))
end)

t.test("nav-mesh walking has no slope physics", function()
    local g = running()
    g.frames(200)
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
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

t.test("a flight off a slope on a moving platform: its line gives the take-off speed its landing line compares with",
    function()
        local g = running()
        g.baseVelocity = { X = 150 * SCALE, Y = 200 * SCALE, Z = 0 }
        g.terrain = ramp(20, 300, 900)
        runFastTo(g, 2000, 300)
        t.truthy(untilMode(g, 3, 120), "flew off")
        local over = g.speed() / SCALE -- over the ground, the platform's velocity in it
        t.truthy(untilMode(g, 1), "landed")
        g.frame()
        local line = t.contains(g.log, "Slope: flew off the slope at ")
        local launch = tonumber(line:match("flew off the slope at (%d+) u/s"))
        line = t.contains(g.log, "s after flying off the slope, at ")
        local landing, change = line:match("after flying off the slope, at (%d+) u/s %(([%+%-]%d+)%)")
        t.near(launch, over, 1, "the launch line's speed is over the ground")
        t.near(launch + tonumber(change), tonumber(landing), 1, "the landing's change is from the launch line's speed: "
            .. line)
        noErrors(g)
    end)

t.test("so do the other flights the mod starts off a slope, going down it and at the end of a slide whose floor fell "
    .. "away, each in one line", function()
    -- On a platform moving sideways, across the slope, so that it changes nothing under
    -- the character: over the ground its 200 u/s are in the take-off speed. (The frame
    -- the mod lands it in is the next flight's down a slope, so the lines are counted
    -- before it.)
    local function flight(g, what, text)
        t.truthy(untilMode(g, 3, 240), what .. ": flew off")
        local over = g.speed() / SCALE
        t.truthy(untilMode(g, 1, 240), what .. ": landed")
        t.eq(count(g.log, "Slope: flew off"), 1, what .. ": one line for the flight")
        g.frame()
        local line = t.contains(g.log, text)
        local launch = tonumber(line:match(" at (%d+) u/s"))
        t.near(launch, over, 1, what .. ": the launch line's speed is over the ground: " .. line)
        line = t.contains(g.log, "s after flying off the slope, at ")
        local landing, change = line:match("after flying off the slope, at (%d+) u/s %(([%+%-]%d+)%)")
        t.near(launch + tonumber(change), tonumber(landing), 1, what .. ": the landing's change is from it: " .. line)
        noErrors(g)
    end
    local g = running()
    g.terrain = plane(g, -20)
    g.baseVelocity = { X = 0, Y = 200 * SCALE, Z = 0 }
    g.frame()
    fake.props(g.cmc).Velocity.X = 700 * SCALE
    flight(g, "down a slope", "Slope: flew off a 20 degree slope going down it at ")
    g = running()
    g.terrain = roundedTop(300)
    g.baseVelocity = { X = 0, Y = 200 * SCALE, Z = 0 }
    runFastTo(g, 1000 * SCALE, 300)
    flight(g, "over a top that rounds off", "Slope: flew off the slope at ")
    t.contains(g.log, ": the slide ended ", "the slide's own end")
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
    t.truthy(status:find("slopes: 0 landings on one (0 ran into it: +0 u/s in all), 1 slides up one, 1 flights off "
        .. "one", 1, true), status)
    noErrors(g)
end)

t.test("a flight's landing line counts all of a long frame in the air, as Unreal moves all of it", function()
    local g = running()
    g.terrain = ramp(20, 300, 900)
    runFastTo(g, 2000, 300)
    t.truthy(untilMode(g, 3, 120), "flew off")
    local airTime = 0
    for i = 1, 300 do
        local dt = i == 3 and 0.2537 or 1 / 60
        g.frame(dt)
        airTime = airTime + dt
        if g.mode() == 1 then
            break
        end
    end
    t.eq(g.mode(), 1, "landed")
    g.frame()
    local line = t.contains(g.log, "s after flying off the slope, at ")
    t.near(tonumber(line:match("landed ([%d%.]+) s after flying off")), airTime, 0.0051, line)
    noErrors(g)
end)

t.test("the hop line says what a landing on a slope did to the speed, and which kind of landing it was", function()
    -- Up 5 degrees from 282 u/s the first landing runs into the slope (see above). The
    -- second, from 261.13 u/s, has an update end 0.9 units above the slope: set down.
    local g = running()
    g.terrain = plane(g, 5)
    local landed = hopAlong(g, 282, 2)
    t.truthy(landed[1].line:find("Hop 1 (", 1, true), landed[1].line)
    t.truthy(landed[1].line:find("landing 282 u/s (+0), slope -21 (ran into it from 2.2 u up), ", 1, true),
        landed[1].line)
    t.truthy(landed[2].line:find("landing 261 u/s (+0), slope: speed kept (set down from 0.9 u up), ", 1, true),
        landed[2].line)
    noErrors(g)
end)

-- The last report's slopes line, and its numbers: the landings on a slope, those that
-- ran into it, what those gained and lost in all (u/s), those the ground check set down
-- first, and those the mod couldn't tell.
local function slopeTotals(g)
    g.press(F8)
    local slopes
    for _, line in ipairs(g.log) do
        slopes = line:find("  slopes (SlopeLandings", 1, true) and line or slopes
    end
    local landings, hits, gained, lost, caught, unknown = slopes:match("landings on one (%d+) %((%d+) ran into it: "
        .. "%+(%d+) and %-(%d+) u/s in all; (%d+) set down first by the ground check, speed kept; (%d+) not told "
        .. "apart, speed kept%)")
    t.truthy(landings, slopes)
    return { landings = tonumber(landings), hits = tonumber(hits), gained = tonumber(gained), lost = tonumber(lost),
        caught = tonumber(caught), unknown = tonumber(unknown), line = slopes }
end

t.test("hopping on the spot on a slope stays on the spot: eight seconds on 10 degrees move nothing and no landing "
    .. "runs into the slope, at PhysicsRate 100 and 144", function()
    -- Half-Life's hop on the spot takes 67 updates at 100 a second and ends 0.22 units
    -- above where it started, within the ground check's reach, on any slope: the player
    -- doesn't move sideways, so the floor under it doesn't change. (Measured in Half-Life
    -- itself on a 17.7 degree ramp: 67 updates, 0.220 units, speed 0 before and after,
    -- hop after hop.) At 144 updates a second: 96 updates, 1.11 units. The heights in the
    -- log are above the slope's plane, 0.03 units more. (0.3.0 ran every landing into the
    -- slope: 49 m downhill in these 8 seconds.)
    for _, case in ipairs({ { 100, 67, 0.2198, "0.3" }, { 144, 96, 1.1077, "1.1" } }) do
        local rate = case[1]
        local model = halfLifeHops(10, 0, rate, 3)
        for i = 1, 3 do
            t.eq(model[i].kind, "caught", "the model")
            t.eq(model[i].updates, case[2], "the model's updates a hop")
            t.near(model[i].above - 1 / 32 / math.cos(math.rad(10)), case[3], 0.0005, "the model's last update ends")
            t.eq(model[i].speed, 0)
        end
        for _, fps in ipairs({ 60, 80, 144 }) do
            local what = string.format("PhysicsRate %d at %d fps", rate, fps)
            local g = running({ PhysicsRate = rate })
            g.terrain = plane(g, 10)
            g.frame(1 / fps)
            local x, y = g.position.X, g.position.Y
            local landings = g.landings
            g.keys.SpaceBar = true
            g.frames(8 * fps, 1 / fps)
            g.keys.SpaceBar = false
            t.truthy(untilMode(g, 1), "landed")
            g.frame(1 / fps)
            t.truthy(g.landings - landings >= 11, what .. ": hopped " .. (g.landings - landings) .. " times")
            t.eq(g.position.X, x, what .. ": it hasn't moved")
            t.eq(g.position.Y, y)
            t.eq(g.speed(), 0, what .. ": no speed")
            local totals = slopeTotals(g)
            t.eq(totals.landings, g.landings - landings, totals.line)
            t.eq(totals.hits, 0, what .. ": no landing ran into the slope: " .. totals.line)
            t.eq(totals.unknown, 0, totals.line)
            t.eq(totals.caught, totals.landings, totals.line)
            t.eq(count(g.log, "slope: speed kept (set down from " .. case[4] .. " u up)"),
                math.min(30, totals.landings), what .. ": every hop line says where it was set down from")
            noErrors(g)
        end
    end
    -- The first hop from a walking height 0.75 cm below the one a landing leaves (more
    -- than Unreal's 0.5 cm of play): the floor's distance is read at both ends, so this
    -- hop too is set down. Taken for the same height, it would end 0.05 units behind
    -- the slope's plane and run into it.
    local g = running()
    g.terrain = plane(g, 10)
    g.frame()
    standAt(g, 1.4)
    local x = g.position.X
    g.keys.SpaceBar = true
    g.frames(120)
    t.eq(g.position.X, x, "it hasn't moved")
    t.eq(slopeTotals(g).hits, 0)
    noErrors(g)
end)

t.test("landing lines: only those that matter, at most 30 of each kind (ran into the slope, or kept the speed), and "
    .. "F7 makes room for 30 more of each", function()
        -- (A low PhysicsRate in this test and the next, so that many landings run into the
        -- slope: at 30 updates a second a plain hop comes down on it by about 9 units an
        -- update.)
        -- Hopping down a 1.5 degree slope: a landing that runs into it gains about 7 u/s,
        -- and one that doesn't changes nothing: neither is logged.
        local g = running({ PhysicsRate = 30 })
        g.terrain = plane(g, -1.5)
        hopAlong(g, 420, 8)
        t.absent(g.log, "Slope:")
        t.contains(g.log, ", slope +7 (ran into it from ")
        t.contains(g.log, ", slope: speed kept (set down from ")
        local totals = slopeTotals(g)
        t.eq(totals.landings, 8, totals.line)
        t.truthy(totals.hits >= 4 and totals.caught >= 1 and totals.hits + totals.caught == 8, totals.line)

        -- Down a 10 degree slope, each kind is logged up to its number of lines: as many
        -- as hop lines, so that each logged hop has the slope and the fall of its landing,
        -- whichever kind it is. (The speed is pushed up by 17 u/s in every hop, so that the
        -- hops differ: left alone, they soon repeat and every landing is set down.)
        local RAN_INTO, KEPT = "It ran into the slope: ", "the speed stays. A Half-Life update ended "
        g = running({ PhysicsRate = 60 })
        g.terrain = plane(g, -10)
        g.keys.W, g.keys.SpaceBar = true, true
        local landings, push = g.landings, false
        local function hopUntil(landed)
            for _ = 1, 4000 do
                g.frame()
                if push then
                    local v = fake.props(g.cmc).Velocity
                    v.X, push = v.X + 17 * SCALE, false
                end
                if g.landings > landings then
                    landings, push = g.landings, true -- pushed on the next frame, in the air again
                end
                if landings >= landed then
                    break
                end
            end
        end
        -- 24 landings from 320 u/s: 17 run into the slope and 7 are set down. By then the
        -- hops have reached the top speed of 2000 u/s, where they repeat and are all set
        -- down: so twice from 320 u/s, then on at the top speed for the landings that keep
        -- their speed.
        local function hopDown(from)
            for round = 0, 1 do
                fake.props(g.cmc).Velocity.X, push = 320 * SCALE, false
                hopUntil(from + 24 * (round + 1))
            end
            hopUntil(from + 72)
        end
        hopDown(0)
        totals = slopeTotals(g)
        t.truthy(totals.hits > 30 and totals.caught > 30, totals.line)
        t.eq(count(g.log, RAN_INTO), 30)
        t.eq(count(g.log, "(further landings that run into a slope aren't logged)"), 1)
        t.eq(count(g.log, KEPT), 30)
        t.eq(count(g.log, "(further landings on slopes that keep their speed aren't logged)"), 1)
        t.eq(count(g.log, "Slope: landed on a 10 degree slope"), 60)
        -- Each of the 30 hop lines has its landing's line right before it. (0.3.0 had 5
        -- landing lines for 20 hop lines, and the first round of fixes 5 and 3.)
        local hops, withLanding = 0, 0
        for i, line in ipairs(g.log) do
            if line:find("] Hop ", 1, true) then
                hops = hops + 1
                if g.log[i - 1]:find("Slope: landed on a 10 degree slope", 1, true) then
                    withLanding = withLanding + 1
                end
            end
        end
        t.eq(hops, 30)
        t.eq(withLanding, 30, "every logged hop has its landing's line")
        -- F7 starts both budgets again: a long test presses it before the parts it wants in
        -- the log.
        g.press(F7)
        hopDown(72)
        local later = slopeTotals(g)
        t.truthy(later.hits > totals.hits + 30 and later.caught > totals.caught + 30, later.line)
        t.eq(count(g.log, RAN_INTO), 60, "30 more after F7")
        t.eq(count(g.log, KEPT), 60, "30 more after F7")
        t.eq(count(g.log, "Slope: landed on a 10 degree slope"), 120)
        t.eq(count(g.log, "(further landings that run into a slope aren't logged)"), 2)
        t.eq(count(g.log, "(further landings on slopes that keep their speed aren't logged)"), 2)
        noErrors(g)
    end)

t.test("the report counts the landings on slopes by kind, and sums what they gained and what they lost", function()
    -- Hopping up a 1.5 degree slope with W and Space held: each landing that runs into it
    -- takes about 7 u/s, too little for a "Slope:" line, and the hop lines stop after 30
    -- hops.
    local g = running({ PhysicsRate = 30 })
    runTo(g, MAX_SPEED)
    local x = g.position.X
    g.terrain = ramp(1.5, x + 50, x + 1e6)
    g.keys.SpaceBar = true
    g.frames(1800)
    t.absent(g.log, "Slope:")
    t.eq(count(g.log, "] Hop "), 30)
    t.truthy(g.speed() < 250 * SCALE, string.format("slowed to %.0f cm/s", g.speed()))
    local up = slopeTotals(g)
    t.truthy(up.landings >= 35, up.line)
    t.truthy(up.hits >= 15 and up.caught >= 5, up.line)
    t.eq(up.hits + up.caught, up.landings, up.line)
    t.eq(up.unknown, 0, up.line)
    t.eq(up.gained, 0, up.line)
    t.truthy(up.lost > 100, up.line)
    -- Then back down it from 320 u/s (20 s: 19 or 20 landings on the slope, then it is
    -- past its foot): the gains are counted apart, so they don't cancel the losses out.
    g.rotation.Yaw = 180
    fake.props(g.cmc).Velocity.X = -MAX_SPEED
    g.frames(1200)
    local down = slopeTotals(g)
    t.truthy(down.landings >= up.landings + 15, down.line)
    t.truthy(down.gained > 80, down.line)
    t.truthy(down.lost >= up.lost and down.lost < up.lost + 30, down.line)
    noErrors(g)
end)

-- The "Slope:" lines of the slides' and flights' count. (Landings on a slope that kept
-- their speed or ran into it have lines and counts of their own.)
local function slideLines(g)
    local n = 0
    for _, line in ipairs(g.log) do
        if line:find("Slope: ", 1, true) and not line:find("the speed stays", 1, true)
            and not line:find("It ran into the slope: ", 1, true) then
            n = n + 1
        end
    end
    return n
end

t.test("slide and flight lines: at most 30, and F7 makes room for 30 more", function()
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
    local function boosts(frames)
        g.keys.W = true
        for _ = 1, frames do
            fake.props(g.cmc).Velocity.X = 2000
            g.frame()
        end
    end
    boosts(1200)
    t.truthy(count(g.log, "sliding up it") >= 10, "ten boosts and more")
    t.eq(slideLines(g), 30)
    t.eq(count(g.log, "(further slides and flights aren't logged)"), 1)
    -- F7 starts them again. (It ends the flight it is pressed in, whose landing then has a
    -- line of the landings' count.)
    g.press(F7)
    boosts(1200)
    t.eq(slideLines(g), 60, "30 more after F7")
    t.eq(count(g.log, "(further slides and flights aren't logged)"), 2)
    noErrors(g)
end)

t.test("a slide up a rough slope after two boosts is logged to its end, and so is the next one after F7",
    function()
        -- As docs/TESTING.md step 9 has it: a boost off a ramp, the same with a tap of
        -- Space, then a slide up a rough slope (20 +-6 degrees in 1 m segments) at 1200
        -- u/s. In 0.3.0 the log had room for 10 such lines in a session, so the rough
        -- slope got the last 4 of them, and a second try none.
        local NOTE = "(further slides and flights aren't logged)"
        local g = running()
        local function over(terrain, speed, frames, tap)
            g.position.Z = fake.FLOOR_DIST
            local x0 = g.position.X + 300
            g.terrain = terrain(x0)
            runFastTo(g, speed, x0)
            local from = slideLines(g)
            g.frames(frames, nil, function(i)
                g.keys.SpaceBar = tap and i == 4
            end)
            g.terrain = nil
            g.position.Z = fake.FLOOR_DIST
            g.frames(60) -- lands, and stands
            return slideLines(g) - from
        end
        local function smooth(x0)
            return ramp(20, x0, x0 + 600)
        end
        local function rough(x0)
            local heights = { [0] = 0 }
            local function angle(i)
                return math.rad(20 + (i % 2 == 0 and 6 or -6))
            end
            for i = 1, 400 do
                heights[i] = heights[i - 1] + 100 * math.tan(angle(i))
            end
            return function(x)
                if x <= x0 then
                    return 0, 0, 0, 1
                end
                local i = math.floor((x - x0) / 100) + 1
                return heights[i - 1] + (x - x0 - (i - 1) * 100) * math.tan(angle(i)), -math.sin(angle(i)), 0,
                    math.cos(angle(i))
            end
        end
        t.eq(over(smooth, 2000, 120), 3, "a boost: ran into, flew off, landed")
        t.eq(over(smooth, 2000, 120, true), 3, "the same with a tap of Space")
        local first = over(rough, 3000, 300)
        t.truthy(first >= 10, first .. " lines for the slide up the rough slope")
        -- (It ends on the slope, or where a bump left Half-Life's path out of the ground
        -- check's reach, in a short flight.)
        t.truthy(count(g.log, "Slope: the slide up the slope ended at ") + count(g.log, ": the slide ended ") >= 1,
            "the slide's end is logged")
        t.absent(g.log, NOTE)
        g.press(F7)
        local second = over(rough, 3000, 300)
        t.truthy(second >= 10, second .. " lines for the same slide after F7")
        t.truthy(6 + first + second > 30, "more lines than one count has room for: " .. 6 + first + second)
        t.absent(g.log, NOTE)
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
            .. "the game's jumps held back while sliding 0",
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

t.test("the report counts the landings by how far their floor leaned, and those on a floor the mod can't use",
    function()
        -- The last report's line, as numbers: the landings read, the six counts, the unusable ones.
        local function floorsLine(g)
            g.press(F8)
            local line
            for _, text in ipairs(g.log) do
                line = text:find("  floors at landings: ", 1, true) and text or line
            end
            t.truthy(line, "the report has the line")
            local numbers = { line:match("^.-floors at landings: (%d+) read %(leaning under 1 deg: (%d+), "
                .. "1 to 2: (%d+), 2 to 4: (%d+), 4 to 8: (%d+), 8 to 16: (%d+), 16 or more: (%d+)%); no usable floor "
                .. "at (%d+) landings %(found by a line trace, touched with an edge, or not walkable%)$") }
            t.eq(#numbers, 8, line)
            for i, text in ipairs(numbers) do
                numbers[i] = tonumber(text)
            end
            return numbers, line
        end
        -- Hops with Space held, until `landings` more landings were handled.
        local function hop(g, landings)
            local from = g.landings
            g.keys.SpaceBar = true
            for _ = 1, 3000 do
                if g.landings - from >= landings and g.mode() == 3 then
                    break
                end
                g.frame()
            end
            t.eq(g.landings - from, landings, "hopped")
        end
        -- Level on the whole: the floor leans `angle` degrees one way and the other, metre by metre.
        local function strips(angle)
            local s, c = math.sin(math.rad(angle)), math.cos(math.rad(angle))
            return function(x)
                return 0, (math.floor(x / 100) % 2 == 0 and 1 or -1) * s, 0, c
            end
        end

        local g = running()
        runTo(g, MAX_SPEED)
        g.keys.W = false
        local numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "0 0 0 0 0 0 0 0", line)
        hop(g, 4) -- a flat floor
        g.terrain = strips(0.5)
        hop(g, 3) -- flat for the mod too
        g.terrain = strips(1.5)
        hop(g, 2)
        g.terrain = strips(3)
        hop(g, 5)
        g.terrain = strips(5)
        hop(g, 6)
        g.terrain = strips(10)
        hop(g, 3)
        g.terrain = strips(20)
        hop(g, 1)
        numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "24 7 2 5 6 3 1 0", line)

        -- A floor the capsule only touches with an edge, and one found by a line trace:
        -- counted apart, whatever their lean.
        g.terrain = strips(5)
        g.contactNormal = function()
            return 0.6, 0, 0.8
        end
        hop(g, 3)
        g.contactNormal = nil
        g.terrain = nil
        g.afterMove = function()
            fake.props(g.cmc).CurrentFloor.bLineTrace = g.mode() == 1
        end
        hop(g, 2)
        g.afterMove = nil
        numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "24 7 2 5 6 3 1 5", line)
        noErrors(g)

        -- With both slope settings off the floor isn't read, so nothing is counted.
        g = running({ SlopeLandings = false, SlopeBoosts = false })
        g.terrain = strips(5)
        hop(g, 3)
        numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "0 0 0 0 0 0 0 0", line)
        noErrors(g)

        -- Running fast, the floor is read on every frame (for slides): only landings count.
        g = running()
        g.terrain = strips(5)
        runFastTo(g, 2000, 1500)
        numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "0 0 0 0 0 0 0 0", line)
        noErrors(g)

        -- A floor that can't be read at all has its own warning, and isn't counted here.
        g = running(nil, { floorNormalUnreadable = true })
        hop(g, 3)
        numbers, line = floorsLine(g)
        t.eq(table.concat(numbers, " "), "0 0 0 0 0 0 0 0", line)
        noErrors(g)
    end)

t.test("on flat ground below 360 u/s slopes cost nothing, and hops read the floor once per landing", function()
    local costs = {}
    for _, config in ipairs({ {}, { SlopeLandings = false, SlopeBoosts = false } }) do
        local g = running(config)
        g.frames(200) -- after the automatic report, which reads the floor too
        t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
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
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the floor too, came first")
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
    -- (The first take-off is from a floor not read in that frame: the mod reads how far
    -- above it the character stands, see floorGap. The later ones follow a landing.)
    t.eq(reads, g.landings - landings + 1, "one read per landing, and one at the first take-off")
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
        -- On the frames after the launch too: the platform's velocity stays out of the heading.
        for _ = 1, 8 do
            g.frame()
            t.eq(g.mode(), 3)
            inAir = fake.props(g.pawn).InAirRotation.Yaw
            t.truthy(math.abs(inAir) < 3, string.format("platform %s: still where it flies: %.1f", tostring(platform),
                inAir))
        end
        t.truthy(untilMode(g, 1), "landed")
        t.truthy(math.abs(g.actorYaw) < 20, "facing where it flew at the landing: " .. g.actorYaw)
        noErrors(g)
    end
end)

-- The shortcut in docs/TESTING.md ---------------------------------------------------

-- The speeds in the table take a long clean run of air strafing that ends at the foot of
-- a steep slope: on level ground about 100 m for 700 u/s. So the section "Slope
-- boosting" gives the owner another way to them: two lines in config.lua and F7.
-- InputSpeed is a setting config.lua doesn't list, and nothing else would notice if
-- that way stopped working.
t.test("docs/TESTING.md's shortcut to the slope boosting speeds works: with its two lines in config.lua and F7 the "
    .. "character runs that fast, slides up a slope, and the way back gives Half-Life's speed again", function()
    local section = readFile("docs/TESTING.md"):match("\n## Slope boosting\n(.-)\n## ")
    t.truthy(section, 'the section "Slope boosting"')
    local maxSpeed = tonumber(section:match("`MaxSpeed = (%d+)`"))
    local inputSpeed = tonumber(section:match("`InputSpeed = (%d+),`"))
    t.truthy(maxSpeed and inputSpeed, "the section gives the two lines for config.lua, written `MaxSpeed = 800` and "
        .. "`InputSpeed = 800,` (this test reads them)")
    t.eq(inputSpeed, maxSpeed, "the speed the keys ask for is the speed allowed")
    local back = tonumber(section:match(".*`MaxSpeed = (%d+)`"))
    t.eq(back, settings.DEFAULTS.MaxSpeed, "the last MaxSpeed the section gives is the way back, the default")
    -- Fast enough for what step 9 asks on the slopes the section sends the owner to, 20
    -- degrees or more: "well above the speed in the table", from which every hop slides.
    for _, row in ipairs(boostTable()) do
        if row.angle >= 20 then
            t.truthy(maxSpeed >= row.always + 100, string.format("%d u/s is well above the %d u/s from which every hop "
                .. "onto a %d degree slope slides", maxSpeed, row.always, row.angle))
        end
    end
    -- config.lua as the owner changes it: the number on the MaxSpeed line, and the new
    -- line below it.
    local shipped = readFile("HL1Movement/Scripts/config.lua")
    local edited, lines = shipped:gsub("(\n +MaxSpeed = )%d+(,[^\n]*\n)", "%1" .. maxSpeed .. "%2    InputSpeed = "
        .. inputSpeed .. ",\n")
    t.eq(lines, 1, "config.lua's MaxSpeed line")
    local changed = string.format("Changed: InputSpeed = %d (was %d), MaxSpeed = %d (was %d).", inputSpeed,
        settings.DEFAULTS.InputSpeed, maxSpeed, settings.DEFAULTS.MaxSpeed)
    local fast = maxSpeed * SCALE
    local function shortcut()
        local g = running(shipped)
        fake.useConfig(edited)
        g.press(F7)
        t.contains(g.log, changed)
        t.absent(g.log, "WARNING")
        g.keys.W = true
        g.frames(30)
        t.near(g.speed(), fast, 0.5, "running with the two lines")
        return g
    end
    -- Running into a slope with W held, and no jump key.
    local g = shortcut()
    g.terrain = ramp(20, g.position.X + 300, g.position.X + 1e6)
    g.frames(30)
    t.contains(g.log, string.format("Slope: ran into a 20 degree slope at %d u/s: sliding up it", maxSpeed))
    noErrors(g)
    -- Hopping onto it, as the section says to.
    g = shortcut()
    g.keys.SpaceBar = true
    g.frames(90)
    t.near(g.speed(), fast, 0.5, "hopping keeps the speed")
    g.terrain = ramp(20, g.position.X + 500, g.position.X + 1e6)
    g.frames(120)
    t.contains(g.log, string.format("Slope: landed on a 20 degree slope at %d u/s", maxSpeed))
    t.contains(g.log, "sliding up it at ")
    noErrors(g)
    -- The way back.
    g = shortcut()
    g.keys.W = false
    g.frames(120)
    fake.useConfig(shipped)
    g.press(F7)
    t.contains(g.log, string.format("Changed: InputSpeed = %d (was %d), MaxSpeed = %d (was %d).",
        settings.DEFAULTS.InputSpeed, inputSpeed, settings.DEFAULTS.MaxSpeed, maxSpeed))
    g.keys.W = true
    g.frames(60)
    t.near(g.speed(), MAX_SPEED, 0.5, "running with the shipped file again")
    noErrors(g)
end)
