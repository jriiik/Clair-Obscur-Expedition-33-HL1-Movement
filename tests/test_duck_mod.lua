-- Ducking, the duck tap and the keys through main.lua in the fake game, with its crouching
-- capsule (tests/fake_hull.lua) and its input (tests/fake_input.lua): the frame's order in
-- movement.step and main.lua, as the parts' own tests (test_duck, test_hull, test_keys,
-- test_eye) can't show it. Each test's comment says what breaks it (each was run once
-- against that broken variant, in a scratch copy, and failed).

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7, F8, F9 = 0x74, 0x75, 0x76, 0x77, 0x78
local SCALE = 2.5
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local DT = 1 / 80
local E = 0.78 * 96 -- the standing eye on the fake character, cm above the capsule's middle

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

local function count(lines, text, from)
    local n = 0
    for i = (from or 0) + 1, #lines do
        if lines[i]:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function since(g, from)
    return { table.unpack(g.log, from + 1) }
end

local function crouched(g)
    return fake.props(g.pawn).bIsCrouched == true
end

local function speed(g)
    return g.speed() / SCALE
end

-- Frames of dt until fn(g) is true, at most limit; returns how many it took.
local function untilTrue(g, dt, limit, fn, what)
    for i = 1, limit do
        g.frame(dt)
        if fn(g) then
            return i
        end
    end
    error("not within " .. limit .. " frames: " .. what, 2)
end

-- The tap lines from log line `from` on: { ground updates, updates in the air, the line }.
local function taps(g, from)
    local list = {}
    for i = (from or 0) + 1, #g.log do
        local line = g.log[i]
        local ground, air = line:match("%] Tap %d+ .-, (%d+) ground updates? before the lift, [%d.]+ s and "
            .. "(%d+) updates")
        if ground then
            list[#list + 1] = { ground = tonumber(ground), air = tonumber(air), line = line }
        end
    end
    return list
end

local function duckState()
    return require("hl1movement.movement").duckStatus()
end

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

-------------------------------------------------------------------------------------------
-- Ducking on the ground and in the air

t.test("Ctrl held at 80 fps: 0.4 s at full speed, then Unreal's crouch keeping the feet, a ducked walk at 106.56 "
    .. "u/s, and the standing eye again on the frame after the release", function()
    -- Fails with: no hull request (the capsule never crouches); the moves scaled from the press;
    -- the eye step not after the movement, or no eye from the movement (first person's eye
    -- stays standing through the transition); the drop not worked out again where Unreal walks
    -- (the eye 45 cm low once crouched); the ground stand-up's Duck line written before Unreal
    -- stood the capsule up.
    local g = running()
    local feet = g.position.Z
    g.keys.W = true
    g.frames(120, DT)
    t.near(speed(g), 320, 0.01, "running")
    g.keys.LeftControl = true
    local slowest, followed = math.huge, 0
    local frames = untilTrue(g, DT, 60, function()
        local d = duckState()
        if d.state ~= 2 then
            slowest = math.min(slowest, speed(g)) -- (a frame all of whose updates were in the transition)
            if d.view < 20 then
                -- Half-Life's view through the transition, at the standing capsule's eye.
                t.near(fake.props(g.pawn).BaseEyeHeight, E + (d.view - 28) * SCALE, 1e-6, "the eye in the transition")
                followed = followed + 1
            end
        end
        return crouched(g)
    end, "a crouch")
    t.truthy(slowest >= 320 - 1e-6, string.format("full speed through the transition: %.2f u/s at least", slowest))
    t.truthy(followed >= 10, followed .. " frames of the eye following the view down")
    -- The duck completes on the 101st update after the press (400 ms at 250 a second),
    -- and Unreal crouches at the start of its next update: 32 to 34 frames of 1/80 s.
    t.truthy(frames >= 32 and frames <= 34, "crouched after " .. frames .. " frames")
    t.contains(g.log, "Duck: ducked on the ground after 0.40 s (100 updates)")
    t.near(g.position.Z, feet, 1e-6, "the feet stay on the floor")
    t.near(fake.props(g.pawn).BaseEyeHeight, E - 16 * SCALE, 0.01, "the ducked eye: 16 units below the standing")
    g.frames(200, DT)
    t.near(speed(g), 106.56, 0.01, "Half-Life's ducked walk: 320 x 0.333")
    t.near(fake.props(g.pawn).BaseEyeHeight, E - 16 * SCALE, 0.01, "still the ducked eye, the mod's now")
    g.keys.LeftControl = false
    local from = #g.log
    g.frame(DT)
    t.falsy(crouched(g), "standing up at once: there is room")
    t.absent(since(g, from), "Duck: stood up", "said once the next hook reads Unreal's stand-up")
    g.frame(DT)
    t.contains(since(g, from), "Duck: stood up on the ground after ")
    t.near(fake.props(g.pawn).BaseEyeHeight, E, 0.01, "the standing eye on the frame after")
    g.frames(120, DT)
    t.near(speed(g), 320, 0.01, "running again")
    noErrors(g)
end)

t.test("ALS's crouched walking speed, which it writes at each crouch and stand-up, is set back on the next frame",
    function()
        -- (The game's speed cap follows GetMaxSpeed(), MaxWalkSpeedCrouched while crouched on the
        -- ground.) Fails with: MaxWalkSpeedCrouched set only at the take-over (0.3.1's).
        local g = running()
        g.keys.LeftControl = true
        untilTrue(g, DT, 60, crouched, "a crouch")
        local p = fake.props(g.cmc)
        t.eq(p.MaxWalkSpeedCrouched, 375, "ALS's, written in Unreal's update that crouched")
        g.frame(DT)
        t.eq(p.MaxWalkSpeedCrouched, 100000, "the mod's again")
        t.contains(g.log, "The game set MaxWalkSpeedCrouched to 375; the mod sets it back to 100000")
        noErrors(g)
    end)

t.test("crouched, a cut to the crouched walking speed the game wrote since the last frame is a speed cut even below 20 "
    .. "%, and KeepSpeed undoes it", function()
    -- (At 900 u/s on the ground ducked, the game writes 375 cm/s and caps the speed at it after
    -- Unreal's move: 17 % of the speed. Below 20 % a cut counts only at the game's cap.) Fails
    -- with: only MaxWalkSpeed's writes taken for the game's cap (0.3.1's atMaxSpeed).
    local g = running()
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch")
    g.frames(5, DT)
    fake.props(g.cmc).Velocity.X = 900 * SCALE
    g.frame(DT)
    local cap = true
    g.afterMove = function(v)
        if cap then
            cap = false
            fake.props(g.cmc).MaxWalkSpeedCrouched = 375
            local s = math.sqrt(v.X * v.X + v.Y * v.Y)
            v.X, v.Y = v.X / s * 375, v.Y / s * 375
        end
    end
    g.frame(DT)
    t.near(speed(g), 150, 0.01, "capped at 375 cm/s")
    g.frame(DT)
    t.contains(g.log, "The game cut the speed from ")
    t.truthy(speed(g) > 700, string.format("the speed back: %.1f u/s", speed(g)))
    noErrors(g)
end)

t.test("a hop ducked in the air lands later than a standing one: 73 updates against 67 at 100 updates a second",
    function()
        -- Half-Life's player ducked in the air keeps its middle and its feet are 18 units
        -- higher, so the hop on the spot comes down that much later. (100 fps, PhysicsRate 100.)
        -- Fails with: the crouch not asked for in the air (Unreal's capsule lands standing).
        local function hop(duckIt)
            local g = running({ PhysicsRate = 100 })
            g.keys.SpaceBar = true
            g.frame(0.01)
            g.keys.SpaceBar = false
            t.eq(g.mode(), 3, "in the air")
            if duckIt then
                g.keys.LeftControl = true
            end
            local frames = untilTrue(g, 0.01, 200, function()
                return g.mode() == 1
            end, "a landing")
            noErrors(g)
            return frames, g
        end
        local standing = hop(false)
        local ducked, g = hop(true)
        t.truthy(standing >= 67 and standing <= 68, "standing: " .. standing .. " frames")
        t.truthy(ducked - standing >= 5 and ducked - standing <= 7, string.format("ducked %d frames, standing %d",
            ducked, standing))
        t.truthy(crouched(g), "landed ducked")
        t.contains(g.log, "Duck: ducked in the air (the feet 18 units higher)")
    end)

t.test("under something low, a stand-up Unreal refuses keeps Half-Life's player fully ducked and scaled; it stands "
    .. "up once out", function()
    -- Fails with: the refusal not told to the physics (it walks at 320 under the ceiling); the
    -- ground stand-up's Duck line written before Unreal's answer.
    local g = running()
    local x = g.position.X
    -- A ceiling 150 cm above the floor from 200 cm ahead to 600: room for the crouched
    -- capsule (102 cm), not the standing one (192).
    g.ceilingAt = function(px)
        if px > x + 200 and px < x + 600 then
            return 150
        end
        return nil
    end
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch")
    g.keys.W = true
    untilTrue(g, DT, 400, function()
        return g.position.X > x + 300
    end, "under the ceiling")
    g.keys.LeftControl = false
    local top = 0
    for _ = 1, 40 do
        g.frame(DT)
        top = math.max(top, speed(g))
        t.truthy(crouched(g), "still crouched under the ceiling")
    end
    t.contains(g.log, "No room to stand up (on the ground, under something)")
    t.absent(g.log, "Duck: stood up on the ground", "no stand-up said while Unreal refuses it")
    t.truthy(top < 150, string.format("one frame of full moves at most (%.1f u/s)", top))
    t.near(speed(g), 106.56, 0.5, "ducked and scaled again")
    untilTrue(g, DT, 400, function()
        return not crouched(g)
    end, "standing up out of it")
    t.truthy(g.position.X >= x + 600 - 20, "stood up where the ceiling ends")
    g.frame(DT) -- (the next hook reads Unreal's stand-up)
    t.contains(g.log, "Duck: stood up late, once Unreal found room")
    t.eq(duckState().state, 0, "Half-Life's player stands")
    g.frames(120, DT)
    t.near(speed(g), 320, 0.5, "running")
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- The duck tap

t.test("+ducktap held: one ground update a tap at any frame rate, a cycle of 53 updates at 80 fps and 52 at 250 fps "
    .. "(250 a second), no hop lines", function()
    -- Fails with: the lift placed 18 units up (cycles of 56); the lift's re-run without its
    -- snapshot; the tap counted as a hop.
    for _, case in ipairs({ { 80, 250, 52, 54 }, { 250, 250, 51, 53 }, { 144, 250, 50, 53 }, { 30, 250, 52, 60 },
        { 80, 100, 21, 24 } }) do
        local fps, rate, low, high = case[1], case[2], case[3], case[4]
        local what = string.format("%d fps, PhysicsRate %d", fps, rate)
        local g = running({ PhysicsRate = rate })
        local from = #g.log
        g.keys.LeftShift = true
        g.frames(3 * fps, 1 / fps)
        local list = taps(g, from)
        t.truthy(#list >= 10, what .. ": " .. #list .. " taps")
        for i = 2, #list do
            t.eq(list[i].ground, 1, what .. ": one ground update a tap: " .. list[i].line)
            local cycle = list[i].ground + list[i].air
            t.truthy(cycle >= low and cycle <= high, string.format("%s: a cycle of %d updates: %s", what, cycle,
                list[i].line))
        end
        t.eq(count(g.log, "] Hop ", from), 0, what .. ": no hop lines")
        noErrors(g)
    end
end)

t.test("ducktapping onto a 30 degree ramp at 500 u/s: the press update runs into it and slides (Half-Life's slope "
    .. "boost), no lift; at 400 u/s the taps go up the ramp", function()
    -- (PhysicsRate 250, 80 fps.) Fails with: the run into a slope decided at the hook, before
    -- the update's friction (0.3.1's); no run-in armed at a landing.
    local function onto(v)
        local g = running()
        local x = g.position.X
        g.terrain = ramp(30, x + 400, x + 1e6)
        g.keys.LeftShift = true
        -- Taps towards the ramp, kept at v until the character is over it.
        local from = #g.log
        for _ = 1, 400 do
            if g.position.X > x + 400 then
                break
            end
            fake.props(g.cmc).Velocity.X = v * SCALE
            g.frame(DT)
        end
        g.frames(40, DT)
        noErrors(g)
        return g, from
    end
    local g, from = onto(500)
    local line = t.contains(since(g, from), "Slope: ran into a 30 degree slope at ")
    t.truthy(line:find(", on a duck tap's press (no tap: Half-Life's slope boost)", 1, true), line)
    g, from = onto(400)
    t.absent(since(g, from), "Slope: ran into")
    t.truthy(#taps(g, from) >= 3, "taps up the ramp")
end)

t.test("a duck tap by hand under something too low for the lift: no tap, the frame's updates run again from where "
    .. "they began, and Half-Life's player stays in the transition, as there without room", function()
    -- (Ctrl down 0.2 s and let go: the duck tap's lift, swept 45 cm up, finds 26 cm.) Fails
    -- with: the frame run again without its snapshot (Half-Life's player stands, lifted).
    local g = running()
    local feet = g.position.Z
    g.ceilingAt = function()
        return 220
    end
    g.keys.LeftControl = true
    g.frames(16, DT)
    t.eq(duckState().state, 1, "in the transition")
    local view = duckState().view
    g.keys.LeftControl = false
    g.frame(DT)
    t.contains(g.log, "No room for a duck tap")
    t.eq(duckState().state, 1, "still in the transition")
    t.truthy(duckState().view <= view + 1e-9, string.format("the view where the curve left it: %.3f", duckState().view))
    t.eq(g.mode(), 1, "on the ground")
    t.near(g.position.Z, feet, 1e-6, "where it stood")
    g.frames(40, DT)
    t.eq(duckState().state, 1, "the lift tried again, without room")
    t.eq(count(g.log, "] Tap "), 0, "no tap line")
    noErrors(g)
end)

t.test("after a refused lift, no new try for 0.1 s unless the character moved 10 cm", function()
    -- Fails with: another distance than 10 cm (3: a try after 5 cm; 20: none after 12).
    local g = running()
    local hull = require("hl1movement.hull")
    g.ceilingAt = function()
        return 220
    end
    g.keys.LeftControl = true
    g.frames(16, DT)
    g.keys.LeftControl = false
    g.frame(DT)
    local refused = hull.status().counts.refusedLifts
    t.truthy(refused >= 1, "refused")
    g.frame(DT)
    t.eq(hull.status().counts.refusedLifts, refused, "held back on the next frame")
    g.position.X = g.position.X + 5
    g.frame(DT)
    t.eq(hull.status().counts.refusedLifts, refused, "5 cm away: still held back")
    g.position.X = g.position.X + 7
    g.frame(DT)
    t.eq(hull.status().counts.refusedLifts, refused + 1, "12 cm away: tried again")
    noErrors(g)
end)

t.test("+ducktap from the frame after Unreal walked the character onto a slope its last update ran into rising 180 to "
    .. "184 u/s: no press on that frame's first update (Half-Life's client built it in the air)", function()
    -- (PhysicsRate 100 at 100 fps; 20 degrees at 590 u/s: 566.4 after that update's friction,
    -- rising 182.0, under 180 half an update of gravity later: no slide.) Fails with: no
    -- airSeen from the update that ran onto the slope at the end of the frame before.
    local g = running({ PhysicsRate = 100 })
    local x = g.position.X
    g.terrain = ramp(20, x + 300, x + 1e6)
    g.keys.W = true
    for _ = 1, 400 do
        fake.props(g.cmc).Velocity.X = 590 * SCALE
        g.frame(0.01)
        if g.position.X > x + 300 then
            break
        end
    end
    t.truthy(g.position.X > x + 300, "on the slope")
    g.keys.LeftShift = true
    g.frame(0.01)
    t.eq(duckState().state, 0, "no press yet")
    g.frame(0.01)
    t.eq(duckState().state, 1, "pressed on the next update, on the ground")
    t.absent(g.log, "Slope: ran into", "no slide")
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- The lines

t.test("the duck's first-use and evidence lines come once; the tap and Duck lines 30 each until F7", function()
    -- Fails with: the tap or Duck lines' counts not started again by F7 (movement.logAgain).
    local g = running()
    g.keys.LeftShift = true
    g.frames(800, DT) -- 40 taps or so
    t.eq(count(g.log, "] Tap "), 30, "30 tap lines")
    t.eq(count(g.log, "(further taps aren't logged)"), 1)
    t.eq(count(g.log, "Lifting the character for a duck tap for the first time"), 1)
    g.keys.LeftShift = false
    g.frames(40, DT)
    -- Ctrl pressed and let go 16 times: a duck and a stand-up each.
    for _ = 1, 16 do
        g.keys.LeftControl = true
        g.frames(40, DT)
        g.keys.LeftControl = false
        g.frames(10, DT)
    end
    t.eq(count(g.log, "] Duck: "), 30, "30 Duck lines")
    t.eq(count(g.log, "(further ducks and stand-ups aren't logged)"), 1)
    t.eq(count(g.log, "Asking Unreal to crouch the character for the first time"), 1)
    t.eq(count(g.log, "The character crouched (Unreal's crouch, on the ground)"), 1, "the evidence line once")
    local from = #g.log
    g.press(F7)
    g.keys.LeftShift = true
    g.frames(200, DT)
    g.keys.LeftShift = false
    g.frames(40, DT)
    t.truthy(count(g.log, "] Tap ", from) >= 5, "tap lines again after F7")
    g.keys.LeftControl = true
    g.frames(40, DT)
    t.truthy(count(g.log, "] Duck: ", from) >= 1, "Duck lines again after F7")
    t.eq(count(g.log, "Lifting the character for a duck tap for the first time"), 1, "first use: once a session")
    noErrors(g)
end)

t.test("a tap line counts the tap's own ground updates: from its press when that came after the landing (a wheel "
    .. "notch standing, +ducktap held while walking), from the landing under +ducktap", function()
    -- Fails with: the ground updates counted from the landing or the take-over (walking first,
    -- a notch after standing: dozens or hundreds of them); counted from the press at the
    -- landing's own hook too (the 2022 landing's stand-up update lost).
    local g = running()
    g.frames(40, DT)
    g.notch("MouseScrollDown") -- a tap by hand: the duck button on one update, standing still
    g.frames(40, DT)
    local list = taps(g)
    t.eq(#list, 1, "one tap")
    t.eq(list[1].ground, 1, list[1].line)
    t.truthy(list[1].line:find(": 0 u/s before its ground update, 0 at the lift (+0)", 1, true), list[1].line)
    -- W held 1 s, then Shift with it: the first tap's press is the first update with Shift,
    -- after a second of running, and the next ones come at their landings.
    local from = #g.log
    g.keys.W = true
    g.frames(80, DT)
    g.keys.LeftShift = true
    g.frames(80, DT)
    list = taps(g, from)
    t.truthy(#list >= 3, #list .. " taps")
    for _, tap in ipairs(list) do
        t.eq(tap.ground, 1, tap.line)
    end
    t.truthy(list[1].line:find(": 320 u/s before its ground update, ", 1, true), list[1].line)
    -- Ctrl pressed in a tap's flight (the 2022 rule: ducked in the air under Shift): its landing
    -- stands up, presses and lifts at one hook, and both ground updates are the next tap's.
    g.keys.W = false
    untilTrue(g, DT, 80, function()
        return g.mode() == 3
    end, "a tap in the air")
    g.keys.LeftControl = true
    from = #g.log
    untilTrue(g, DT, 160, function()
        return #taps(g, from) >= 2
    end, "two taps")
    list = taps(g, from)
    t.eq(list[2].ground, 2, list[2].line)
    noErrors(g)
end)

t.test("ten seconds of duck taps on the spot get a status line that counts them", function()
    -- Fails with: taps not something happening (no status line: nothing moved, nothing turned).
    local g = running()
    g.keys.LeftShift = true
    local line
    for _ = 1, 1300 do
        g.frame(DT)
        local last = g.log[#g.log]
        if last:find("] Status (10s)", 1, true) then
            line = last
        end
    end
    t.truthy(line, "a status line")
    t.truthy(line and line:find("ducking: %d+ taps %(0 without room%)"), tostring(line))
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- The hotkeys with Ctrl and Shift held

t.test("F5 to F9 work with Ctrl, Shift or both held, once a press; F8's report says the modifier", function()
    -- Fails with: bindKey not through keys.bindAll (no bind with modifiers); neither keys.bindAll's
    -- de-dup nor main.lua's queue de-dup (with every bind fired, F5 acts three times; either alone
    -- holds this, and the queue's is held alone by the loading-screen test); the modifier left out
    -- of F8's title.
    local g = running(nil, { fireEveryBind = true })
    g.press(F5, { "CONTROL" })
    t.contains(g.log, "Half-Life movement off")
    g.press(F5, { "CONTROL", "SHIFT" })
    t.eq(count(g.log, "Half-Life movement on"), 1, "on again, once")
    local from = #g.log
    g.press(F7, { "SHIFT" })
    t.eq(count(g.log, "Settings reloaded", from), 1, "config.lua read once")
    g.keys.LeftControl = true
    g.frames(60, DT)
    t.truthy(crouched(g), "ducked")
    g.press(F8, { "CONTROL" })
    t.contains(g.log, "diagnostics (asked for with F8, Ctrl held)")
    g.press(F9, { "CONTROL" })
    t.contains(g.log, "Speedometer on")
    noErrors(g)
end)

t.test("F7 while ducked with Ctrl held: the mod hands the crouch back (Unreal stands up) and Ctrl counts again only "
    .. "after a release", function()
    -- Fails with: no input.ignoreHeld at the take-over (the held Ctrl ducks again at once).
    local g = running()
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch")
    g.press(F7)
    g.frames(60, DT)
    t.falsy(crouched(g), "standing: the held key is the game's until it is let go")
    t.eq(duckState().state, 0, "Half-Life's player stands")
    g.keys.LeftControl = false
    g.frames(5, DT)
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch after a new press")
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- The eye, ALS's braking, and steps turned off by their errors

t.test("first person in a duck tap: the eye is Half-Life's, 18 units above where it stood, where the character "
    .. "rose 37.9 cm", function()
    -- Fails with: the drop not moved by the frame's duck events (the eye 7 cm low in the flight).
    local g = running()
    g.keys.LeftShift = true
    untilTrue(g, DT, 20, function()
        return g.mode() == 3
    end, "the lift")
    local lifted = (16 + 1 / 32) * SCALE - fake.FLOOR_DIST
    t.near(fake.props(g.pawn).BaseEyeHeight, E + 18 * SCALE - lifted, 0.01, "the eye above the lifted character")
    noErrors(g)
end)

t.test("ALS's braking at a crouch and a stand-up on the ground is given back, and the status line counts it",
    function()
        -- (The fake's ALS brings its movement curve back for the update of a stance change.)
        -- Fails with: no hull.brakeBack in movement.step.
        local g = running()
        g.keys.W = true
        g.frames(120, DT)
        g.keys.LeftControl = true
        untilTrue(g, DT, 60, crouched, "a crouch")
        g.frame(DT)
        t.contains(g.log, "ALS braked the character for one frame as it crouched: ")
        g.keys.LeftControl = false
        untilTrue(g, DT, 10, function()
            return not crouched(g)
        end, "a stand-up")
        g.frame(DT)
        t.contains(g.log, "ALS braked the character for one frame as it stood up: ")
        local line
        for _ = 1, 1300 do
            g.frame(DT)
            if g.log[#g.log]:find("] Status (10s)", 1, true) then
                line = g.log[#g.log]
                break
            end
        end
        t.truthy(line and line:find("ALS's braking given back 2 times", 1, true), tostring(line))
        noErrors(g)
    end)

t.test("the eye step failing 30 frames in a row is turned off, and first person with it; the movement goes on",
    function()
        -- Fails with: first person kept on with its eye step off (no "eye" reason in the camera's
        -- blocker: camera.apply starts it again on the next frame).
        local g = running()
        local camera = require("hl1movement.camera")
        t.truthy(camera.isActive(), "first person on")
        local real = camera.applyEye
        camera.applyEye = function()
            error("a broken eye")
        end
        g.frames(40, DT)
        camera.applyEye = real
        g.frames(5, DT)
        t.falsy(camera.isActive(), "first person off")
        t.contains(g.log, "First person: off (the eye height couldn't be set)")
        g.keys.W = true
        g.frames(60, DT)
        t.near(speed(g), 320, 0.5, "the movement goes on")
    end)

t.test("the movement step turned off by its errors gives the mod's keys back at once, saying why", function()
    -- Fails with: no keys.give in the movement step's clean-up (the keys step gives them back a
    -- frame later, as the mod letting go).
    local g = running()
    local movement = require("hl1movement.movement")
    local real = movement.step
    movement.step = function()
        error("a broken movement")
    end
    g.frames(40, DT)
    movement.step = real
    t.contains(g.log, "Keys: given back (errors)")
end)

t.test("the keys step turned off by its errors gives the keys back: the game's sprint on Shift works again", function()
    -- Fails with: no keys.give in the keys step's clean-up (the game's context stays out).
    local g = running()
    local keys = require("hl1movement.keys")
    local real = keys.take
    keys.take = function()
        error("broken keys")
    end
    g.frames(40, DT)
    keys.take = real
    t.contains(g.log, "Keys: given back (errors)")
    g.keys.LeftShift = true
    g.frames(5, DT)
    t.eq(fake.props(g.pawn).DesiredGait, 2, "the game's sprint")
end)

t.test("the duck tap's lift turned off by its errors: duck tap keys read as up (no transition left hanging)",
    function()
        -- Fails with: the duck tap key counted with the lift off (Half-Life's player stays in the
        -- transition, its lift refused on every update).
        local g = running()
        local guard = require("hl1movement.guard")
        for _ = 1, 30 do
            guard.run("the duck tap's lift", function()
                error("a broken lift")
            end)
        end
        g.keys.LeftShift = true
        g.frames(40, DT)
        t.eq(duckState().state, 0, "standing")
        t.eq(count(g.log, "] Tap "), 0, "no taps")
    end)

-------------------------------------------------------------------------------------------
-- The keys and the hull, tried again: F5, F7

t.test("the key names of config.lua are asked of the game once the mod acts, and again after F7", function()
    -- Fails with: keys.validate not called from main.lua, or not again after F7.
    local g = running({ JumpKeys = { "SpaceBar", "Bogus" } })
    t.eq(count(g.log, 'JumpKeys: "Bogus" is not a key the game knows'), 1)
    fake.useConfig({ JumpKeys = { "SpaceBar", "Bogus2" } })
    g.press(F7)
    g.frames(3, DT)
    t.eq(count(g.log, 'JumpKeys: "Bogus2" is not a key the game knows'), 1)
    noErrors(g)
end)

t.test("the game dropping the mod's keys is seen at the half-second check and they are taken again; the status line "
    .. "counts it", function()
    -- Fails with: no keys.check at the movement's refresh; the keys' part left out of the
    -- status line.
    local g = running()
    g.keys.W = true
    g.frames(30, DT)
    g.input.dropAll()
    g.frames(60, DT)
    t.contains(g.log, "Keys: the game dropped the mod's keys (once so far); they are taken again as they come up")
    local line
    for _ = 1, 1300 do
        g.frame(DT)
        if g.log[#g.log]:find("] Status (10s)", 1, true) then
            line = g.log[#g.log]
            break
        end
    end
    t.truthy(line and line:find("dropped by the game 1", 1, true), tostring(line))
    noErrors(g)
end)

t.test("F7 starts the keys' lines again; F5 off and on tries the keys' context again after the game dropped it "
    .. "five times", function()
    -- Fails with: keys.logAgain not called at F7; keys.retry not called at F5.
    local g = running()
    for _ = 1, 4 do
        g.input.dropAll()
        g.frames(50, DT)
    end
    t.eq(count(g.log, "Keys: the game dropped the mod's keys"), 3, "three logged")
    g.press(F7)
    g.frames(10, DT)
    g.input.dropAll()
    g.frames(50, DT)
    t.eq(count(g.log, "Keys: the game dropped the mod's keys"), 4, "logged again after F7")
    for _ = 1, 4 do
        g.input.dropAll()
        g.frames(50, DT)
    end
    t.contains(g.log, "Keys: the game's walk/run state is kept instead")
    local from = #g.log
    g.press(F5)
    g.frames(5, DT)
    g.press(F5)
    g.frames(5, DT)
    t.contains(since(g, from), "Keys: trying again")
end)

t.test("F5 off and on after the game never let the character crouch: Unreal's crouch is tried again", function()
    -- Fails with: hull.reset not called at F5 (the hull change stays off for the session).
    local g = running(nil, { noCrouch = true })
    for _ = 1, 3 do
        g.keys.LeftControl = true
        g.frames(48, DT)
        g.keys.LeftControl = false
        g.frames(16, DT)
    end
    t.contains(g.log, "The game doesn't let the character crouch")
    local from = #g.log
    g.press(F5)
    g.frames(5, DT)
    g.press(F5)
    g.frames(5, DT)
    t.contains(since(g, from), "Ducking: on: Unreal's crouch")
end)

t.test("F7 with DuckHull = false: ducking without the hull change; F7 back: the crouch again", function()
    -- (docs/TESTING.md D12.) Fails with: hull.reset not called at F7 (the hull's way kept).
    local g = running()
    fake.useConfig({ DuckHull = false })
    g.press(F7)
    g.frames(5, DT)
    g.keys.LeftControl = true
    g.frames(60, DT)
    t.falsy(crouched(g), "no crouch")
    t.eq(duckState().state, 2, "Half-Life's player ducked")
    g.keys.LeftControl = false
    g.frames(10, DT)
    fake.useConfig(nil)
    g.press(F7)
    g.frames(5, DT)
    g.keys.LeftControl = true
    g.frames(60, DT)
    t.truthy(crouched(g), "crouched again")
    noErrors(g)
end)

t.test("F7 pressed twice before a frame runs (a loading screen): config.lua is read once", function()
    -- (UE4SS's binds of one press are told apart by keys.bindAll within 0.05 s; two presses
    -- further apart, with no frame between them, are two.) Fails with: no queue de-dup in
    -- bindKey (the reload queued and run twice).
    local g = running()
    local from = #g.log
    local bind = g.bindFor(F7, {})
    bind()
    local t0, spins = os.clock(), 0
    while os.clock() - t0 < 0.06 do
        spins = spins + 1
    end
    t.truthy(spins > 0)
    bind()
    g.frame(DT)
    t.eq(count(g.log, "Settings reloaded", from), 1, "read once")
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- Cost

-- Game calls and property reads a frame over `frames` frames of dt.
local function cost(g, frames, dt, each)
    local calls, reads = fake.counts.calls, fake.counts.reads
    for i = 1, frames do
        if each then
            each(i)
        end
        g.frame(dt)
    end
    return (fake.counts.calls - calls) / frames, (fake.counts.reads - reads) / frames
end

t.test("ducking costs few game calls: a steady run, a ducked walk and duck taps with strafing at most 30 a frame, "
    .. "standing still 31", function()
    -- Fails with: a wheel key asked with IsInputKeyDown; quick taps asked at 60 fps.
    local g = running({ Speedometer = true })
    g.keys.W = true
    g.frames(70)
    local calls, reads = cost(g, 60)
    t.truthy(calls <= 30, string.format("running: %.2f calls a frame", calls))
    t.truthy(reads <= 45, string.format("running: %.2f reads a frame", reads))
    g.keys.LeftControl = true
    g.frames(70)
    calls = cost(g, 60)
    t.truthy(calls <= 30, string.format("a ducked walk: %.2f calls a frame", calls))
    g.keys.LeftControl, g.keys.W = false, false
    g.frames(70)
    calls = cost(g, 60)
    t.truthy(calls <= 31, string.format("standing still (the stick asked): %.2f calls a frame", calls))
    g.keys.LeftShift, g.keys.D = true, true
    calls = cost(g, 400, DT, function()
        g.rotation.Yaw = g.rotation.Yaw + 150 * DT
    end)
    t.truthy(calls <= 30, string.format("duck taps strafing at 80 fps: %.2f calls a frame", calls))
    noErrors(g)
end)

t.test("third person in a dialogue that leaves the movement input on: at most 31 game calls a frame", function()
    -- (In third person the game's dialogue and cinematic systems are asked every 0.25 s.)
    local g = running()
    g.press(F6)
    g.inDialogue = true
    g.keys.W = true
    g.frames(70)
    local calls = cost(g, 60)
    t.truthy(calls <= 31, string.format("%.2f calls a frame", calls))
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- Slides, slopes and platforms

-- Runs along +X at `v` u/s until x, keeping the speed up against the mod's friction.
local function runFastTo(g, v, x, dt)
    g.keys.W = true
    for _ = 1, 2400 do
        if g.position.X >= x then
            break
        end
        fake.props(g.cmc).Velocity.X = v * SCALE
        g.frame(dt)
    end
    g.keys.W = false
end

t.test("a duck while sliding up a slope flies off it with the rise the slide had, ducked in the air", function()
    -- Fails with: slide.ducked not turned into a launch (the character walks on up the slope
    -- with Half-Life's player in the air for good).
    local g = running()
    g.terrain = ramp(20, 300, 30000)
    runFastTo(g, 800, 300)
    g.frame()
    t.contains(g.log, "Slope: ran into a 20 degree slope at ")
    g.keys.LeftControl = true
    g.frame()
    local line = t.contains(g.log, "Slope: ducked while sliding up the slope: flying off it at ")
    local rise = tonumber(line:match("rising (%d+) u/s"))
    t.truthy(rise and rise > 180, line)
    t.eq(g.mode(), 3, "in the air")
    g.frame()
    t.truthy(crouched(g), "ducked in the air")
    noErrors(g)
end)

t.test("fully ducked, a stand-up waits while Half-Life's player slides up a slope: the slope is too close below",
    function()
        -- Fails with: the room open in the air during a slide (Unreal would stand the capsule up
        -- while Half-Life's player is still in the air on the slope).
        local g = running()
        g.keys.LeftControl = true
        untilTrue(g, DT, 60, crouched, "a crouch")
        g.terrain = ramp(20, g.position.X + 300, 30000)
        runFastTo(g, 800, g.position.X + 300)
        g.frame()
        t.contains(g.log, "Slope: ran into a 20 degree slope at ")
        g.keys.LeftControl = false
        local sliding = 0
        for _ = 1, 200 do
            g.frame()
            if count(g.log, "Slope: the slide up the slope ended at ") > 0 then
                break
            end
            sliding = sliding + 1
            t.truthy(crouched(g), "still ducked while sliding")
            t.eq(duckState().state, 2, "Half-Life's player stays fully ducked")
        end
        t.truthy(sliding >= 5, "slid for " .. sliding .. " frames")
        g.frames(10)
        t.falsy(crouched(g), "stood up once the slide was over")
        noErrors(g)
    end)

t.test("set down on a steep slope at 800 u/s without jump, at 250 updates a second: the slide starts in the landing's "
    .. "frame after one update of friction, at 787 u/s", function()
    -- (Half-Life's order: the first update on the ground runs into the slope after its
    -- friction, 1.6 % of the speed.) Fails with: the run-in decided at the next hook (0.3.1's).
    local g = running()
    g.keys.W = true
    for _ = 1, 600 do
        g.frame()
        if speed(g) >= 319.5 then
            break
        end
    end
    g.keys.W = false
    local x = g.position.X
    g.terrain = ramp(25, x + 300, x + 20000)
    fake.props(g.cmc).Velocity.X = 2000
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    untilTrue(g, nil, 200, function()
        return g.mode() == 1
    end, "a landing")
    local from = #g.log
    g.frame()
    local landing = t.contains(since(g, from), "Slope: landed on a 25 degree slope at 800 u/s: ")
    t.truthy(landing:find("the speed stays", 1, true), landing)
    t.contains(since(g, from), "Slope: ran into a 25 degree slope at 787 u/s: sliding up it")
    noErrors(g)
end)

t.test("the game's own jump on the frame an update runs into a slope is held back: Half-Life's player slides up it",
    function()
        -- (TakeKeys = false, and the mod's jump on the pad's A only: Space is the game's jump
        -- alone, pressed on the frame of the landing whose first update runs into the slope.)
        -- Fails with: no holdGameJump at a run-in's slide (Unreal jumps the character it walks).
        local g = running({ TakeKeys = false, JumpKeys = { "Gamepad_FaceButton_Bottom" } })
        g.keys.W = true
        for _ = 1, 600 do
            g.frame()
            if speed(g) >= 319.5 then
                break
            end
        end
        g.keys.W = false
        local x = g.position.X
        g.terrain = ramp(25, x + 300, x + 20000)
        fake.props(g.cmc).Velocity.X = 2000
        g.keys.Gamepad_FaceButton_Bottom = true
        g.frame()
        g.keys.Gamepad_FaceButton_Bottom = false
        untilTrue(g, nil, 200, function()
            return g.mode() == 1
        end, "a landing")
        local jumps, from = g.gameJumps, #g.log
        g.keys.SpaceBar = true
        g.frame()
        t.contains(since(g, from), "Slope: ran into a 25 degree slope at 787 u/s: sliding up it")
        t.eq(g.gameJumps, jumps, "no jump of the game's")
        t.eq(g.mode(), 1, "Unreal walks the character up the slope")
        noErrors(g)
    end)

t.test("the game writing the crouched capsule's half height while the mod moves the character: the mod's comes back "
    .. "at the half-second refresh", function()
    -- Fails with: no hull.refresh at the movement's refresh.
    local g = running()
    local p = fake.props(g.cmc)
    local mine = p.CrouchedHalfHeight
    t.truthy(mine ~= 60, "the mod's crouched half height: " .. tostring(mine))
    p.CrouchedHalfHeight = 60
    g.frames(60, DT)
    t.eq(p.CrouchedHalfHeight, mine)
    noErrors(g)
end)

t.test("a ducked hop on the spot on a 17.7 degree ramp lands clipped (Valve's ducked floor is 17 units below the "
    .. "standing one there), where a standing one is set down, and so is one ducked throughout", function()
    -- (PhysicsRate 100 and 100 fps, as the owner's Half-Life log: a standing hop on the spot
    -- there is set down 0.22 units up and keeps 0 u/s; a ducked one comes down 0.25 units into
    -- the ducked floor and gains 90.47 u/s. Ducked throughout it takes off from the ducked
    -- floor and comes down on it: caught after 67 updates as standing, in a model of Half-Life's
    -- updates with those floors.) Fails
    -- with: the ducked landing on the exact 18 units (duck.restGap left out); a ducked take-off
    -- on the exact 18 units, or its floor not read at a slow take-off (set down from 1.9 units).
    local function hop(duckIt)
        local g = running({ PhysicsRate = 100 })
        local a = math.rad(17.7)
        local x0, z0 = g.position.X, g.position.Z - fake.props(g.cmc).CurrentFloor.FloorDist
        g.terrain = function(x)
            return z0 + (x - x0) * math.tan(a), -math.sin(a), 0, math.cos(a)
        end
        g.frame(0.01)
        if duckIt == "throughout" then
            g.keys.LeftControl = true
            g.frames(60, 0.01)
        end
        g.keys.SpaceBar = true
        g.frame(0.01)
        g.keys.SpaceBar = false
        if duckIt then
            g.keys.LeftControl = true
        end
        local from = #g.log
        for _ = 1, 200 do
            g.frame(0.01)
            if count(g.log, "] Hop ", from) > 0 then
                break
            end
        end
        noErrors(g)
        return t.contains(since(g, from), "] Hop "), g
    end
    local line = hop(false)
    t.truthy(line:find("landing 0 u/s (+0), slope: speed kept (set down from ", 1, true), line)
    line = hop(true)
    local gain = tonumber(line:match("slope %+(%d+) %(ran into it"))
    t.truthy(gain and math.abs(gain - 90) <= 2, line)
    t.truthy(line:find(", landed ducked", 1, true), line)
    line = hop("throughout")
    t.truthy(line:find("landing 0 u/s (+0), slope: speed kept (set down from 0.3 u up), 0.67 s in the air", 1, true),
        line)
    t.truthy(line:find(", ducked as it took off, landed ducked", 1, true), line)
end)

t.test("a duck tap's landing on a slope is Half-Life's: set down where one of its updates ends within 2 units of the "
    .. "slope, run into it where none does, as a model of its updates has it", function()
    -- (Shift pressed at one hook while walking up a 30 degree ramp at v u/s, no movement key,
    -- at 80 fps.) Half-Life's player is lifted 18 units, the character about 2 less, so that
    -- Unreal lands it as Half-Life's ground check reaches the floor: Half-Life's player is
    -- still above it then and comes down after that frame. Fails with: the path not followed
    -- past the frame's end (every tap landing on a slope "can't tell", the speed kept).
    local tan, nz = math.tan(math.rad(30)), math.cos(math.rad(30))
    -- Half-Life's tap from where it rests on the slope, at u u/s up it, `rate` updates a second.
    local function model(u, rate)
        local dt, above, vz = 1 / rate, 1 / 32 / nz + 18, 0
        for _ = 1, 1000 do
            vz = vz - 400 * dt
            local after = above + (vz - u * tan) * dt
            if after < 0 then
                return "hit", above
            end
            above = after
            vz = vz - 400 * dt
            if above < 2 then
                return "caught", above
            end
        end
    end
    -- (rate, v): at 100 updates a second some of these run into the slope, at 250 none. (None
    -- ends within 0.05 units of 2, where the line gives two decimals.)
    for _, case in ipairs({ { 100, 225 }, { 100, 255 }, { 100, 300 }, { 100, 345 }, { 100, 420 }, { 250, 300 },
        { 250, 420 }, { 0, 300 }, { 0, 315 } }) do
        local rate, v = case[1], case[2]
        local g = start({ PhysicsRate = rate })
        g.loadSave()
        g.terrain = ramp(30, g.position.X - 200, g.position.X + 1e6) -- (standing on the ramp)
        g.frames(SETTLE_FRAMES)
        g.frames(10, DT)
        local from = #g.log
        fake.props(g.cmc).Velocity.X = v * SCALE
        g.keys.LeftShift = true
        local line
        for _ = 1, 60 do
            g.frame(DT)
            for i = from + 1, #g.log do
                line = line or (g.log[i]:find("Slope: landed", 1, true) and g.log[i])
            end
            if line then
                break
            end
        end
        -- The press update's friction (4 u/s per 100 u/s at 100 updates a second; PhysicsRate 0:
        -- one update a frame), then the flight at that speed.
        local updates = rate > 0 and rate or 80
        local kind, above = model(v * (1 - 4 / updates), updates)
        local what = string.format("PhysicsRate %d, %d u/s: %s", rate, v, tostring(line))
        t.truthy(line, what)
        if kind == "hit" then
            t.truthy(line:find("It ran into the slope: the Half-Life update before it ended "
                .. string.format("%.1f", above) .. " units above the slope", 1, true), what)
        else
            t.truthy(line:find("the speed stays. A Half-Life update ended " .. string.format("%.1f", above)
                .. " units above the slope, within the ground check's reach", 1, true), what)
        end
        noErrors(g)
    end
end)

t.test("a walk-off onto a 30 degree slope after a duck tap lands as in a fresh game (the tap's lift went with its "
    .. "flight)", function()
    -- At 100 updates a second, a 130 cm drop at 400 u/s runs into the slope from 2.5 units up.
    -- Fails with: the walk-off keeping the last flight's st.takeoffLift (it is decided 2.83
    -- units higher, and set down).
    local function landing(tap)
        local g = running({ PhysicsRate = 100 })
        local x0 = g.position.X + 600
        local z0 = g.position.Z - fake.props(g.cmc).CurrentFloor.FloorDist
        local a = math.rad(30)
        local tan, s, c = math.tan(a), math.sin(a), math.cos(a)
        g.terrain = function(x)
            if x < x0 then
                return z0, 0, 0, 1
            end
            return z0 - 130 - (x - x0) * tan, s, 0, c
        end
        if tap then
            g.keys.LeftShift = true
            g.frames(2, DT)
            g.keys.LeftShift = false
        else
            g.frames(2, DT)
        end
        g.frames(160, DT)
        t.eq(g.mode(), 1, "on the ground before the run")
        local from = #g.log
        g.keys.W = true
        untilTrue(g, DT, 320, function()
            fake.props(g.cmc).Velocity.X = 400 * SCALE
            return g.mode() == 3
        end, "walking off the ledge")
        g.keys.W = false
        local line
        untilTrue(g, DT, 160, function()
            for i = from + 1, #g.log do
                if g.log[i]:find("Slope: landed", 1, true) then
                    line = g.log[i]
                    return true
                end
            end
        end, "the landing's Slope: line")
        noErrors(g)
        return line:match("Slope: landed.*$")
    end
    local fresh, after = landing(false), landing(true)
    t.truthy(fresh:find("It ran into", 1, true), "fresh: ran into the slope: " .. fresh)
    t.eq(after, fresh, "the same landing after a tap")
end)

t.test("a duck tap on a moving platform leaves it keeping its velocity, and the landing takes it out again", function()
    -- (As the jump does.) Fails with: the platform's velocity read after the lift moved the
    -- character, or not kept at the lift.
    local g = running()
    g.baseVelocity = { X = 200, Y = 0, Z = 0 }
    g.frames(30, DT)
    local x0 = g.position.X
    g.keys.LeftShift = true
    g.frames(240, DT) -- 3 s: some 14 taps
    t.truthy(#taps(g) >= 10, "taps")
    -- Carried with the platform the whole time, in the air too: 3 s at 200 cm/s.
    local carried = g.position.X - x0
    t.near(carried, 200 * 240 / 80, 10, string.format("moved %.0f cm with the platform", carried))
    noErrors(g)
end)

t.test("walking off a ledge ducked stays ducked (the crouch is allowed off ledges)", function()
    -- Fails with: bCanWalkOffLedgesWhenCrouching not set (the fake's crouched character stops
    -- at the ledge, as Unreal's does).
    local g = running()
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch")
    local x = g.position.X
    g.terrain = function(px)
        return px > x + 100 and -300 or 0, 0, 0, 1
    end
    g.keys.W = true
    untilTrue(g, DT, 200, function()
        return g.mode() == 3
    end, "walking off the ledge")
    g.frame(DT)
    t.truthy(crouched(g), "ducked in the air")
    untilTrue(g, DT, 200, function()
        return g.mode() == 1
    end, "the landing")
    t.truthy(crouched(g), "landed ducked")
    noErrors(g)
end)

t.test("a stand-up and a jump in one update keep the feet on the floor as the jump starts (Unreal's flag for it)",
    function()
        -- Half-Life stands up on the ground, then jumps, in that update. Fails with: the
        -- base-location flag not written (Unreal keeps the middle at its stand-up in the air:
        -- the feet 45 cm lower, and its pop-up).
        local g = running()
        g.keys.LeftControl = true
        untilTrue(g, DT, 60, crouched, "a crouch")
        g.frames(10, DT)
        local floor = g.position.Z
        g.keys.LeftControl, g.keys.SpaceBar = false, true
        g.frame(DT)
        g.keys.SpaceBar = false
        t.eq(g.mode(), 3, "jumped")
        t.falsy(crouched(g), "stood up")
        t.truthy(g.position.Z > floor, string.format("the feet rose with the jump: %.1f cm above the floor",
            g.position.Z - floor))
        t.eq(g.popups or 0, 0, "Unreal didn't pop the capsule up")
        noErrors(g)
    end)

t.test("after a stand-up and a jump in one update, a duck and a stand-up later in that flight keep the middle, as "
    .. "after a plain jump (the flag is for the jump's update only)", function()
    -- Fails with: bCrouchMaintainsBaseLocation left true for the flight (Unreal sets it only at
    -- mode changes): the duck keeps the feet and the middle drops 45 cm, and the stand-up keeps
    -- them too and counts as a pop-up.
    local hull = require("hl1movement.hull")
    local function flight(standJump, standUp)
        local g = running()
        if standJump then
            g.keys.LeftControl = true
            untilTrue(g, DT, 60, crouched, "a crouch")
            g.frames(10, DT)
            g.keys.LeftControl = false
        end
        g.keys.SpaceBar = true
        g.frame(DT)
        g.keys.SpaceBar = false
        t.eq(g.mode(), 3, "jumped")
        t.falsy(crouched(g), "standing as it took off")
        local moved
        if standUp then
            g.frames(3, DT)
            g.keys.LeftControl = true
            g.frames(10, DT)
            t.truthy(crouched(g), "ducked in the air")
            local z = g.position.Z
            g.keys.LeftControl = false
            g.frames(2, DT)
            t.falsy(crouched(g), "stood up in the air")
            moved = g.position.Z - z
        else
            g.frames(12, DT)
            local z = g.position.Z
            g.keys.LeftControl = true
            g.frames(2, DT)
            t.truthy(crouched(g), "ducked in the air")
            moved = g.position.Z - z
        end
        local frames = untilTrue(g, DT, 200, function()
            return g.mode() == 1
        end, "the landing")
        local c = hull.status().counts
        noErrors(g)
        return moved, frames, c.popups, c.rebaseLargest
    end
    for _, standUp in ipairs({ false, true }) do
        local what = standUp and "the stand-up" or "the duck"
        local plain, plainFrames = flight(false, standUp)
        local moved, frames, popups, largest = flight(true, standUp)
        t.near(moved, plain, 1, string.format("the middle moved %.1f cm over %s (%.1f after a plain jump)", moved,
            what, plain))
        t.eq(frames, plainFrames, "the landing as after a plain jump, " .. what)
        t.eq(popups, 0, "no pop-up counted, " .. what)
        t.truthy(type(largest) == "number" and largest < 1, string.format("the re-bases measured no gap "
            .. "(largest %s cm), %s", tostring(largest), what))
    end
end)

t.test("a pause in the duck's transition keeps it, and a duck key held through the pause counts after it", function()
    -- Fails with: the pause taken for a take-over (the held key ignored after it).
    local g = running()
    g.keys.LeftControl = true
    g.frames(20, DT)
    t.falsy(crouched(g), "still in the transition")
    g.paused = true
    g.frames(80, DT)
    g.paused = false
    local frames = untilTrue(g, DT, 40, crouched, "the crouch after the pause")
    t.truthy(frames >= 12 and frames <= 15, "the rest of the 0.4 s: " .. frames .. " frames")
    noErrors(g)
end)

t.test("root motion in the middle of a duck: the crouch the mod holds is asked for again if the game clears it",
    function()
        -- Fails with: no hull request in root motion (movement.keepHull): Unreal stands the
        -- character up.
        local g = running()
        g.keys.LeftControl = true
        untilTrue(g, DT, 60, crouched, "a crouch")
        g.rootMotion = true
        g.frames(5, DT)
        fake.props(g.cmc).bWantsToCrouch = false -- the game (a montage, ALS) clears the wish
        g.frames(10, DT)
        t.truthy(crouched(g), "still crouched")
        g.rootMotion = false
        g.frames(10, DT)
        t.truthy(crouched(g), "and after it")
        t.eq(duckState().state, 2)
        noErrors(g)
    end)

-------------------------------------------------------------------------------------------
-- Keys given back and taken again

t.test("third person, a dialogue that leaves the movement input on: the keys are the game's (Space is its jump); a "
    .. "Ctrl held as it ends ducks only after a release and a new press", function()
    -- Fails with: the keys given back on what first person waits for (third person never asks);
    -- no input.ignoreHeld on the frame the keys are the mod's again.
    local g = running()
    g.press(F6)
    g.inDialogue = true
    g.frames(30, DT)
    t.contains(g.log, "Keys: given back (dialogue)")
    local jumps = g.gameJumps
    g.keys.SpaceBar = true
    g.frames(3, DT)
    g.keys.SpaceBar = false
    t.eq(g.gameJumps, jumps + 1, "the game's jump action saw Space")
    g.frames(60, DT)
    g.keys.LeftControl = true
    g.frames(10, DT)
    g.inDialogue = false
    g.frames(60, DT)
    t.falsy(crouched(g), "the Ctrl held as the dialogue ended was the game's")
    g.keys.LeftControl = false
    g.frames(3, DT)
    g.keys.LeftControl = true
    untilTrue(g, DT, 60, crouched, "a crouch after a new press")
    noErrors(g)
end)

t.test("F5 with Ctrl held: the game's walk toggle under the held key is put back, with the mod off", function()
    -- (The engine, here, doesn't ignore the held key when the game's mappings come back.)
    -- Fails with: keys.watch after onFrame's return for the mod switched off.
    local g = running()
    g.frames(5, DT)
    g.input.losesIgnoreFlag = true
    g.keys.LeftControl = true
    g.frames(5, DT)
    g.press(F5)
    g.frames(3, DT)
    t.eq(g.input.fired.WalkAction, 1, "the game toggled walk under the held key")
    t.eq(fake.props(g.pawn).DesiredGait, 1, "put back")
    t.contains(g.log, "Keys: the game reacted to LeftControl")
    noErrors(g)
end)

-- A run the game has from a key it kept over a hand-back with one of the mod's keys held,
-- that key let go first, then the mod's: the game ends its run, and the guard keeps that.
local function runEndsUnderGuard(runKey, guardKey)
    local g = running()
    local pawn = fake.props(g.pawn)
    g.frames(20, DT)
    if runKey == "LeftShift" then
        -- Shift pressed in a battle, held as the mod takes over: the game's until let go.
        g.inBattle = true
        g.frames(20, DT)
        g.keys.LeftShift = true
        g.frames(5, DT)
        g.inBattle = false
        g.frames(40, DT)
    else
        g.keys[runKey] = true
        g.frames(20, DT)
    end
    t.eq(pawn.IsSprintRequested, true, "the game's run on " .. runKey)
    g.keys[guardKey] = true
    g.frames(20, DT)
    g.inBattle = true -- the next battle, both keys held
    g.frames(20, DT)
    g.keys[runKey] = false
    g.frames(20, DT)
    g.keys[guardKey] = false
    g.frames(20, DT)
    g.inBattle = false
    g.frames(40, DT)
    t.eq(pawn.IsSprintRequested, false, "the run ended as " .. runKey .. " was let go")
    t.eq(pawn.DesiredGait, 1, "running again, not sprinting")
    t.absent(g.log, "Keys: the game reacted to", "no guard line")
    noErrors(g)
end

t.test("Shift held since a take-over and Ctrl held into a battle, Shift let go first: the game's run ends, and the "
    .. "hand-back guard keeps that", function()
    -- Fails with: the guard writing every change of IsSprintRequested back (the run stays on
    -- with no key held, and the guard blames Ctrl).
    runEndsUnderGuard("LeftShift", "LeftControl")
end)

t.test("a gamepad's run (the right trigger, never the mod's) and A held into a battle, the trigger let go first: the "
    .. "game's run ends, and the hand-back guard keeps that", function()
    -- Fails with: the guard writing every change of IsSprintRequested back.
    runEndsUnderGuard("Gamepad_RightTrigger", "Gamepad_FaceButton_Bottom")
end)

t.test("Ctrl held through a pause of 15 s: the hand-back guard's 10 s don't count the pause, so it still puts back "
    .. "what the game does under the key once it runs again", function()
    -- Fails with: the guard's 10 s counting paused frames (gone when the game could act).
    local g = running()
    local pawn = fake.props(g.pawn)
    g.frames(5, DT)
    g.keys.LeftControl = true
    g.frames(10, DT)
    g.paused = true
    g.frames(15 * 80, DT)
    g.paused = false
    g.frames(2, DT)
    t.truthy(require("hl1movement.keys").status().guard ~= nil, "the guard still on after the pause")
    pawn.IsSprintRequested = true -- (the game starting its run under the held key)
    g.frame(DT)
    t.eq(pawn.IsSprintRequested, false, "put back")
    t.contains(g.log, "Keys: the game reacted to LeftControl")
    noErrors(g)
end)

t.test("a new character with Ctrl held: the keys go back to the game without the guard (it may be setting the new "
    .. "one up)", function()
    -- Fails with: "character" not among the reasons that arm no guard.
    local g = running()
    g.keys.LeftControl = true
    g.frames(5, DT)
    g.useCharacter(g.buildCharacter())
    g.frame(DT)
    t.eq(require("hl1movement.keys").status().guard, nil, "no guard")
    noErrors(g)
end)

t.test("in nav-mesh walking a duck tap has no lift (Unreal's capsule ignores the level's geometry there, so the "
    .. "sweep would test nothing)", function()
    -- Fails with: hull.room giving the lift room in nav-mesh walking.
    local g = running()
    local p = fake.props(g.cmc)
    p.MovementMode = 2
    g.frames(5, DT)
    local z = g.position.Z
    g.keys.LeftShift = true
    g.frames(80, DT)
    g.keys.LeftShift = false
    t.eq(require("hl1movement.hull").status().counts.lifts, 0, "no lift")
    t.eq(#taps(g), 0, "no tap")
    t.truthy(g.position.Z - z < 1, string.format("not lifted: %.1f cm", g.position.Z - z))
    noErrors(g)
end)

t.test("a UE4SS mods restart ducked under something low: the old copy's crouch is the mod's, not the game's; a new "
    .. "press holds it again", function()
    -- Fails with: the new copy taking the crouch it finds for the game's ("The game crouched
    -- the character itself", counted; walking out with Ctrl held, Unreal stands it up).
    local g = running()
    local x = g.position.X
    g.ceilingAt = function(px)
        return (px > x - 1000 and px < x + 600) and 150 or nil
    end
    g.keys.LeftControl = true
    g.frames(60, DT)
    t.truthy(crouched(g), "ducked under it")
    local from = #g.log
    g.restartMods(root)
    g.frames(250, DT) -- the new copy's settle and take-over
    t.truthy(crouched(g), "still crouched: no room to stand up")
    g.keys.LeftControl = false
    g.frames(10, DT)
    g.keys.LeftControl = true
    g.frames(60, DT)
    g.keys.W = true
    untilTrue(g, DT, 400, function()
        return g.position.X > x + 700
    end, "walking out")
    g.frames(40, DT)
    t.truthy(crouched(g), "out from under it with Ctrl held: still ducked")
    local lines = since(g, from)
    t.absent(lines, "The game crouched the character itself", "not the game's crouch")
    t.absent(lines, "The game stood the character up itself", "nor its stand-up")
    t.eq(require("hl1movement.hull").status().counts.gameCrouches, 0, "none counted")
    noErrors(g)
end)

t.test("the 2020 rule: a duck key counting under +ducktap gives no button in the air, so the floor below is asked "
    .. "before a stand-up there, and the capsule never pops up", function()
    -- Fails with: the floor asked only while no duck key is held (heldInAir's "keyHeld" alone).
    local g = running()
    local duck = require("hl1movement.duck")
    duck.HELD_DUCK_UNDER_TAP = false
    local ok, err = pcall(function()
        g.keys.SpaceBar = true
        g.frame(DT)
        g.keys.SpaceBar = false
        g.keys.LeftControl = true
        untilTrue(g, DT, 30, crouched, "ducked in the air")
        untilTrue(g, DT, 100, function()
            return fake.props(g.cmc).Velocity.Z < 0 and g.position.Z < 30
        end, "30 cm above the floor on the way down")
        g.keys.LeftShift = true
        untilTrue(g, DT, 100, function()
            return g.mode() == 1
        end, "the landing")
        t.eq(g.popups or 0, 0, "Unreal never moved the character up to stand it up")
        t.contains(g.log, "Asking Unreal for the floor below the character for the first time")
        noErrors(g)
    end)
    duck.HELD_DUCK_UNDER_TAP = true
    assert(ok, err)
end)
