-- Tests for HL1Movement/Scripts/hl1movement/duck.lua, in Half-Life units: the duck step,
-- the duck and jump buttons of an update, the eye's offsets and the ducked hull's floor on
-- a slope; and for physics.simulate with ducking (its dk argument), which runs them update
-- by update with the rest of Half-Life's movement: the jump of each update, the scaled
-- moves, a duck in a slide, and running into an upward slope after each update's ground
-- move. The numbers are Half-Life's, from descriptions of its movement and of OpenAG's
-- input code; a few were measured in the owner's demo and log and are quoted as
-- expectations of made-up inputs.
--
-- Each test was seen to fail with the rule it guards broken in a scratch copy of duck.lua
-- or physics.lua: its comment names the broken rule ("Fails with ...").

local t = require("testlib")
local duck = require("hl1movement.duck")
local physics = require("hl1movement.physics")
local settings = require("hl1movement.settings")

-- Half-Life's parameters in Half-Life units; each test gives the update rate itself.
local P = settings.physics(settings.load({ UnitScale = 1 }))

local function keys(k)
    return { held = k.held or false, notch = k.notch or false, tap = k.tap or false, jump = k.jump or false,
        jumpNotch = k.jumpNotch or false, autoHop = k.autoHop or false }
end

-- Runs fn with duck.HELD_DUCK_UNDER_TAP set to rule2022, and puts it back.
local function withRule(rule2022, fn)
    local before = duck.HELD_DUCK_UNDER_TAP
    duck.HELD_DUCK_UNDER_TAP = rule2022
    local ok, err = pcall(fn)
    duck.HELD_DUCK_UNDER_TAP = before
    if not ok then
        error(err, 0)
    end
end

-- One frame hook's updates through physics.simulate with ducking, standing still (the
-- movement itself plays no part here): exactly `steps` updates of 1/rate s (a frame that
-- long, nothing left over). Per update physics.simulate gives the duck and jump buttons,
-- with "on the ground" as the update before left the player (the caller's for the
-- first), runs the duck step, then the jump; at the end d.held (the duck button was down
-- on every update). A hook with no update runs no duck step and keeps d.held, and jumps
-- at once only where its first update would jump: a lift on that update puts the player
-- in the air before the jump. Returns physics.simulate's dk.out: events (each with the
-- update's number and whether its duck step found the player on the ground), lifted,
-- jumped (the update), ground (the updates run on the ground), scaled, held.
local function runUpdates(d, onGround, steps, room, rate)
    local dk = { d = d, room = room, out = {} }
    physics.simulate({}, 0, 0, 0, onGround, 0, nil, false, P, steps / rate, rate, nil, nil, dk)
    return dk.out
end

-- One hook: its keys, then its updates.
local function hook(d, k, onGround, steps, room, rate)
    duck.frame(d, keys(k))
    return runUpdates(d, onGround, steps, room, rate or 250)
end

-- "1 pressed, 2 lift": the events of a hook, for comparing.
local function events(out)
    local list = {}
    for _, e in ipairs(out.events) do
        list[#list + 1] = e.k .. " " .. e.what
    end
    return table.concat(list, ", ")
end

-- Half-Life's curve, written out again here: the view height ms after the press's update.
local function hlCurve(ms)
    local s = math.min(ms / 400, 1)
    return 28 - 34 * (3 * s * s - 2 * s * s * s)
end

local function state(st, timer, view, wasDown)
    local d = duck.new(false)
    d.state, d.timer, d.view, d.wasDown = st, timer, view, wasDown
    return d
end

local S, I, D = duck.STANDING, duck.IN_DUCK, duck.DUCKED

-- Fails with: new(true) standing; any flag starting true; no held field (the frame's held
-- would have no place that survives a frame physics.simulate empties st.sim before).
t.test("a new duck state stands, or is fully ducked for a capsule that reads crouched; the constants are Half-Life's",
    function()
        t.eq(duck.SCALE, 0.333, "the three digits, not a third")
        t.eq(duck.TIMER, 1000)
        t.eq(duck.DONE, 600)
        t.eq(duck.VIEW_STAND, 28)
        t.eq(duck.VIEW_DUCK, 12)
        t.eq(duck.SHIFT, 18)
        t.eq(duck.HELD_DUCK_UNDER_TAP, true, "OpenAG's 2022 rule, which the owner's client has")
        local flags = { "wasDown", "tapHad", "wiped", "notch", "keyHeld", "tap", "jumpKey", "jumpNotch", "autoHop",
            "jumpWas", "held", "airSeen" }
        local d = duck.new(false)
        t.eq(d.state, S)
        t.eq(d.timer, 0)
        t.eq(d.view, 28)
        for _, name in ipairs(flags) do
            t.eq(d[name], false, name)
        end
        t.eq(d.drop, 0)
        local c = duck.new(true)
        t.eq(c.state, D)
        t.eq(c.timer, 0)
        t.eq(c.view, 12)
        for _, name in ipairs(flags) do
            t.eq(c[name], false, "crouched: " .. name)
        end
    end)

-- Every row of the duck step's table, with its event: from a state, one update of 4 ms.
-- Fails with any row changed: the press not entering the transition (row 1), the curve
-- not followed (5), the duck not completing at 600 ms (6) or in the air (2, 4, 7), the lift
-- leaving the player on the ground (8), a refused lift standing up (9), a drop in the air
-- staying in the transition (10), a press fully ducked starting the timer again (12), a
-- stand-up without room on the ground (15) or in the air (16), a held button taken for a
-- press (17).
t.test("each row of the duck step's table: the state, timer, view, event and ground it leaves", function()
    local rows = {
        { "standing, pressed on the ground: the transition, timer 1000, view 28", { S, 0, 28, false }, true, true,
            nil, { I, 1000, 28, "pressed", true, 1 } },
        { "standing, pressed in the air: fully ducked at once, timer 1000", { S, 0, 28, false }, true, false,
            nil, { D, 1000, 12, "ducked", false, 1 } },
        { "a refused tap pressed again on the ground: the timer and the view start again", { I, 700, 20, false }, true,
            true, nil, { I, 1000, 28, "pressed", true, 1 } },
        { "in the transition, pressed in the air: fully ducked", { I, 700, 20, false }, true, false, nil,
            { D, 1000, 12, "ducked", false, 1 } },
        { "in the transition, held on the ground above 600: the curve", { I, 900, hlCurve(100), true }, true, true,
            nil, { I, 896, hlCurve(104), nil, true, 1 } },
        { "in the transition, held on the ground, 600 reached: fully ducked", { I, 604, hlCurve(396), true }, true,
            true, nil, { D, 600, 12, "ducked", true, 1 } },
        { "in the transition, held in the air: fully ducked", { I, 900, hlCurve(100), true }, true, false, nil,
            { D, 896, 12, "ducked", false, 1 } },
        { "in the transition, let go on the ground with room: the lift, then in the air", { I, 900, 22.7, true },
            false, true, { lift = true }, { S, 0, 28, "lift", false, 1 } },
        { "in the transition, let go on the ground with no room to lift: view held, timer running",
            { I, 900, 22.7, true }, false, true, { lift = false, ground = true, air = true },
            { I, 896, 22.7, "refused", true, 1 } },
        { "in the transition, let go in the air: standing again", { I, 900, 22.7, true }, false, false,
            { lift = false }, { S, 0, 28, "dropped", false, 1 } },
        { "fully ducked, held: nothing, the moves scaled", { D, 500, 12, true }, true, true, nil,
            { D, 496, 12, nil, true, 0.333 } },
        { "fully ducked, pressed again: nothing, the timer isn't started again", { D, 500, 12, false }, true, false,
            nil, { D, 496, 12, nil, false, 0.333 } },
        { "fully ducked, let go on the ground with room: standing, still scaled", { D, 500, 12, true }, false, true,
            { ground = true, air = false }, { S, 0, 28, "stood", true, 0.333 } },
        { "fully ducked, let go in the air with room: standing", { D, 500, 12, true }, false, false,
            { ground = false, air = true }, { S, 0, 28, "stood", false, 0.333 } },
        { "fully ducked, let go on the ground with no room: refused", { D, 500, 12, true }, false, true,
            { ground = false, air = true, lift = true }, { D, 496, 12, "refused", true, 0.333 } },
        { "fully ducked, let go in the air with no room: refused", { D, 500, 12, true }, false, false,
            { ground = true, air = false, lift = true }, { D, 496, 12, "refused", false, 0.333 } },
        { "standing, held but not pressed (a press that was lost): nothing", { S, 0, 28, true }, true, true, nil,
            { S, 0, 28, nil, true, 1 } },
        { "standing, up: nothing", { S, 0, 28, false }, false, false, nil, { S, 0, 28, nil, false, 1 } },
        { "no room table is room everywhere: the lift", { I, 900, 22.7, true }, false, true, nil,
            { S, 0, 28, "lift", false, 1 } },
        { "no room table: a stand-up on the ground", { D, 500, 12, true }, false, true, nil,
            { S, 0, 28, "stood", true, 0.333 } },
        { "no room table: a stand-up in the air", { D, 500, 12, true }, false, false, nil,
            { S, 0, 28, "stood", false, 0.333 } },
    }
    for _, row in ipairs(rows) do
        local name, from, button, ground, room, want = row[1], row[2], row[3], row[4], row[5], row[6]
        local d = state(from[1], from[2], from[3], from[4])
        local scale, event, after = duck.step(d, button, ground, room, 4)
        t.eq(d.state, want[1], name .. ": state")
        t.near(d.timer, want[2], 1e-9, name .. ": timer")
        t.near(d.view, want[3], 1e-9, name .. ": view")
        t.eq(event, want[4], name .. ": event")
        t.eq(after, want[5], name .. ": on the ground after the step")
        t.eq(scale, want[6], name .. ": scale")
        t.eq(d.wasDown, button, name .. ": the button kept for the next update")
    end
end)

-- Fails with: "<" for "<=" (250 and 100 a second complete an update late); no tolerance
-- (240 a second: 96 updates of 1/240 s add up to a hair over 400 ms); the timer set before
-- the press's count-down (the press's update ends at 996 at 250 a second: an update early).
t.test("the duck completes on the update that finds 400 ms run since the press's: the 100th at 250 a second, "
    .. "the 40th at 100, the 58th at 144 (406 ms), the 96th at 240; exactly 600 counts", function()
    local function updatesToDuck(rate)
        local ms = 1000 * (1 / rate)
        local d = duck.new(false)
        local _, event = duck.step(d, true, true, nil, ms)
        t.eq(event, "pressed")
        t.eq(d.timer, 1000, "the press sets the timer after its own count-down")
        local n = 0
        repeat
            n = n + 1
            _, event = duck.step(d, true, true, nil, ms)
        until event == "ducked" or n > 1000
        return n, d.timer
    end
    local n, timer = updatesToDuck(250)
    t.eq(n, 100, "updates after the press's at 250 a second")
    t.eq(timer, 600, "the timer at exactly 600")
    n, timer = updatesToDuck(100)
    t.eq(n, 40, "at 100 a second")
    t.eq(timer, 600)
    t.eq(updatesToDuck(144), 58, "at 144 a second")
    t.eq(updatesToDuck(240), 96, "at 240 a second")
    -- Held through the 600: the timer runs on to 0, the state stays.
    local d = duck.new(false)
    duck.step(d, true, true, nil, 4)
    for _ = 1, 300 do
        duck.step(d, true, true, nil, 4)
    end
    t.eq(d.state, D)
    t.eq(d.timer, 0)
end)

-- Fails with: a straight line (f = s) for the curve.
t.test("the transition's view follows Half-Life's curve: 27.98987 after 4 ms, 22.6875 at 100, 11 at 200, -0.6875 at "
    .. "300, -5.98987 at 396, the demo's 27.75, 22.5, 11, -0.5 and -5.75 cut to a quarter", function()
    t.eq(duck.curve(1000), 28)
    t.near(duck.curve(996), 27.98987, 1e-5)
    t.near(duck.curve(900), 22.6875, 1e-12)
    t.near(duck.curve(800), 11, 1e-12)
    t.near(duck.curve(700), -0.6875, 1e-12)
    t.near(duck.curve(604), -5.98987, 1e-5)
    t.near(duck.curve(600), -6, 1e-12, "-6 at 400 ms: 12 less the 18 the origin hasn't dropped")
    t.near(duck.curve(0), -6, 1e-12)
    -- Through the step at 250 a second, cut towards zero to a quarter as the demo stores it.
    local function quarter(v)
        local q = v * 4
        return (q >= 0 and math.floor(q) or math.ceil(q)) / 4
    end
    local seen = { [1] = 27.75, [25] = 22.5, [50] = 11, [75] = -0.5, [99] = -5.75 }
    local d = duck.new(false)
    duck.step(d, true, true, nil, 4)
    for k = 1, 99 do
        duck.step(d, true, true, nil, 4)
        t.near(d.view, hlCurve(4 * k), 1e-9, "the view " .. 4 * k .. " ms after the press")
        if seen[k] then
            t.eq(quarter(d.view), seen[k], "as the demo stores it, " .. 4 * k .. " ms after the press")
        end
    end
end)

-- Fails with: the scale by the state the step leaves (the completing update scaled, the
-- stand-up's not); a third for 0.333 (106.67 u/s). The cap to MaxSpeed before the scale is
-- physics.simulate's to make (tested with it below): here physics.wish caps the wish first.
t.test("the moves are scaled by the state the update begins in: the completing update full, then 0.333, the "
    .. "stand-up's update still 0.333; a ducked walk at InputSpeed 400 tops at 106.56 u/s", function()
    local d = duck.new(false)
    local scales = {}
    local event
    duck.step(d, true, true, nil, 4) -- the press
    for k = 1, 102 do
        local scale
        scale, event = duck.step(d, true, true, nil, 4)
        scales[k] = scale
        if k == 100 then
            t.eq(event, "ducked", "the 100th completes")
        end
    end
    t.eq(scales[99], 1)
    t.eq(scales[100], 1, "the completing update has full moves")
    t.eq(scales[101], 0.333, "the next is scaled")
    local scale
    scale, event = duck.step(d, false, true, nil, 4)
    t.eq(event, "stood")
    t.eq(scale, 0.333, "the stand-up's update is still scaled")
    scale = duck.step(d, false, true, nil, 4)
    t.eq(scale, 1, "full from the next")
    -- A press in the air ducks at once: that update full, the next scaled.
    d = duck.new(false)
    scale, event = duck.step(d, true, false, nil, 4)
    t.eq(event, "ducked")
    t.eq(scale, 1)
    t.eq(duck.step(d, false, false, nil, 4), 0.333, "the update after a one-update duck in the air")
    -- The ducked walk, through physics.step at 250 updates a second.
    local wx, wy, wishSpeed = physics.wish(0, 1, 0, P.inputSpeed, P.maxSpeed)
    t.eq(wishSpeed, 320, "a movement key asks for 400, capped to MaxSpeed")
    local vx, vy, vz = 0, 0, 0
    for _ = 1, 250 do
        vx, vy, vz = physics.step(vx, vy, vz, true, wx, wy, wishSpeed * duck.SCALE, false, P, 1 / 250)
    end
    t.near(math.sqrt(vx * vx + vy * vy), 106.56, 1e-6, "the ducked walk from rest")
    vx, vy, vz = 320, 0, 0
    for k = 1, 69 do
        vx, vy, vz = physics.step(vx, vy, vz, true, wx, wy, wishSpeed * duck.SCALE, false, P, 1 / 250)
        if k == 68 then
            t.truthy(vx > 106.8, "friction alone above the ducked speed")
        end
    end
    t.near(vx, 106.56, 1e-6, "from a run at 320: down to the ducked speed in 69 updates (0.276 s)")
end)

-- Fails with: a waiting notch dropped by the next hook (consumed by an empty frame; the
-- random hooks' lost count and the hook with no update below); a notch not spent by its
-- update (the button on every update after it); a notch under a ducktap key dropped at its
-- hook, or counting under the ducktap rule.
t.test("a duck notch gives the button to exactly one update, the first that runs at or after its hook; notches "
    .. "before it is spent are one; notches at two hooks whose updates follow each other give two", function()
    -- Random hooks of 0 to 4 updates, a notch at one hook in ten. A notch counts as lost when
    -- the first update at or after its hook comes without the button: counting only the
    -- buttons given can't see it, as a lost notch merges with the next one.
    local episodes, given, extra, lost = 0, 0, 0, 0
    for seed = 1, 200 do
        math.randomseed(seed)
        local d = duck.new(false)
        local pending = false
        for _ = 1, 300 do
            local notch = math.random() < 0.1
            local steps = math.random(0, 4)
            duck.frame(d, keys({ notch = notch }))
            if notch and not pending then
                episodes, pending = episodes + 1, true
            end
            for k = 1, steps do
                local button = duck.button(d, true)
                if k == 1 and pending and not button then
                    lost = lost + 1
                end
                if button then
                    given = given + 1
                    if not pending then
                        extra = extra + 1
                    end
                    pending = false
                end
            end
        end
        if pending then
            episodes = episodes - 1 -- the last one still waiting at the end
        end
    end
    t.eq(lost, 0, "notches whose first update came without the button")
    t.truthy(episodes > 5000, "notches seen: " .. episodes)
    t.eq(given, episodes, "updates with the button, one per notch")
    t.eq(extra, 0, "updates with the button and no notch waiting")
    -- One at a hook with no update waits for the next hook's first update.
    local d = duck.new(false)
    duck.frame(d, keys({ notch = true }))
    duck.frame(d, keys({}))
    t.truthy(d.notch, "still waiting after a hook with no update")
    t.eq(duck.button(d, true), true, "the next hook's first update")
    t.eq(duck.button(d, true), false, "its second")
    -- Two at one hook are one.
    d = duck.new(false)
    duck.frame(d, keys({ notch = true }))
    duck.frame(d, keys({ notch = true }))
    t.eq(duck.button(d, true), true)
    t.eq(duck.button(d, true), false)
    -- On the ground at a hook with two updates: press and lift in that hook.
    d = duck.new(false)
    local out = hook(d, { notch = true }, true, 2)
    t.eq(events(out), "1 pressed, 2 lift", "a tap by hand")
    t.eq(out.ground, 1)
    -- Notches at two hooks in a row, one update each: a press held over two updates.
    d = duck.new(false)
    out = hook(d, { notch = true }, true, 1)
    t.eq(events(out), "1 pressed")
    out = hook(d, { notch = true }, true, 1)
    t.eq(events(out), "", "held on the second update: still in the transition")
    t.eq(d.state, I)
    out = hook(d, {}, true, 1)
    t.eq(events(out), "1 lift", "the lift on the update after the last notch")
    -- In the air: ducked for one update, standing on the next, which is scaled.
    d = duck.new(false)
    out = hook(d, { notch = true }, false, 3)
    t.eq(events(out), "1 ducked, 2 stood")
    t.eq(out.scaled, 1, "the update after the notch's")
    -- With a counting duck key held a notch does nothing. Under a ducktap key it waits like
    -- any other, and the update under the ducktap rule spends it for nothing: the rule alone
    -- decides (here a release on the ground, the last update under the rule having pressed).
    d = duck.new(false)
    duck.frame(d, keys({ held = true, notch = true }))
    t.falsy(d.notch)
    d = duck.new(false)
    d.tapHad = true
    duck.frame(d, keys({ notch = true }))
    duck.frame(d, keys({ tap = true }))
    t.eq(duck.button(d, true), false, "a notch is lost under the ducktap rule")
    t.falsy(d.notch, "and spent there")
    t.eq(duck.button(d, true), true, "the rule's press on the next update")
    -- A notch under a ducktap key at a hook with no update, the key let go before the next
    -- hook's update: the button went down, and that update isn't under the rule (OpenAG's next
    -- command has the button): on the ground a tap by hand, in the air a one-update duck.
    d = duck.new(false)
    hook(d, { tap = true, notch = true }, true, 0)
    t.truthy(d.notch, "still waiting after a hook with no update under a ducktap key")
    out = hook(d, {}, true, 2)
    t.eq(events(out), "1 pressed, 2 lift", "a tap by hand")
    d = duck.new(false)
    hook(d, { tap = true, notch = true }, false, 0)
    out = hook(d, {}, false, 2)
    t.eq(events(out), "1 ducked, 2 stood", "a one-update duck in the air")
end)

-- Fails with: no memory (the button down on every update on the ground); the memory reset
-- when a hold begins.
t.test("+ducktap: on the ground the button goes down and up in turn, in the air it stays up; the memory is kept "
    .. "between holds, so a hold after one that ended on a press begins with a release", function()
    local d = duck.new(false)
    duck.frame(d, keys({ tap = true }))
    local seq = {}
    for k = 1, 6 do
        seq[k] = tostring(duck.button(d, true))
    end
    t.eq(table.concat(seq, " "), "true false true false true false", "on the ground")
    for _ = 1, 4 do
        t.eq(duck.button(d, false), false, "in the air")
    end
    t.eq(duck.button(d, true), true, "the first update back on the ground")
    -- The hold ends right after a press; keys up for a while; a new hold on the ground.
    duck.frame(d, keys({}))
    for _ = 1, 5 do
        t.eq(duck.button(d, true), false, "no keys")
    end
    t.truthy(d.tapHad, "the memory isn't touched while the ducktap key is up")
    duck.frame(d, keys({ tap = true }))
    t.eq(duck.button(d, true), false, "the new hold begins with a release")
    t.eq(duck.button(d, true), true, "then the press")
    -- Through the duck step under a low ceiling (no room to lift): press, refused, press ...
    d = duck.new(false)
    local out = hook(d, { tap = true }, true, 4, { lift = false })
    t.eq(events(out), "1 pressed, 2 refused, 3 pressed, 4 refused")
    t.eq(out.ground, 4, "one update of friction each")
    t.eq(d.view, 28, "every other update is a fresh press: the view stays at 28")
end)

-- The ducktap loop at many frame rates, each frame through physics.simulate with its own
-- accumulator. Unreal is a point that falls under exact gravity from the lift's place (16
-- 1/32 units above the floor less the walking gap: 37.93 cm above where it walked) and
-- lands on contact; the mod sees the landing at the next hook.
local G, GAP = 800 * 2.5, 2.15 -- cm/s^2, cm
local LIFT = (16 + 1 / 32) * 2.5 - GAP

local function ducktapRun(fps, rate, jitter, seconds, seed)
    math.randomseed(seed or 1)
    local d = duck.new(false)
    local sim, time, update = {}, 0, 0
    local falling, z, vz = false, GAP, 0 -- the capsule's bottom above the floor, cm
    local perTap, lifts, groundNow = {}, {}, 0
    while time < seconds do
        local dt = 1 / fps
        if jitter then
            dt = dt * (1 + (math.random() * 2 - 1) * jitter)
        end
        duck.frame(d, keys({ tap = true }))
        local dk = { d = d, out = {} }
        local _, _, _, _, steps = physics.simulate(sim, 0, 0, 0, not falling, 0, nil, false, P, dt, rate, nil, nil, dk)
        local out = dk.out
        groundNow = groundNow + out.ground
        if out.lifted then
            lifts[#lifts + 1] = update + out.lifted
            perTap[#perTap + 1] = groundNow
            groundNow = 0
            falling, z, vz = true, GAP + LIFT, 0
        end
        update = update + steps
        if falling then
            local zEnd = z + vz * dt - 0.5 * G * dt * dt
            if zEnd <= 0 then
                falling, z, vz = false, GAP, 0
            else
                z, vz = zEnd, vz - G * dt
            end
        end
        time = time + dt
    end
    return perTap, (lifts[#lifts] - lifts[2]) / (#lifts - 2)
end

-- Fails with: the lift leaving the player on the ground for the rest of the hook's updates
-- (duck.lua), or "on the ground" taken from the hook for every update (physics.simulate):
-- a second press on the lift's hook.
t.test("+ducktap at 30 to 300 fps, steady and with frames +-30 %: one ground update per tap, at 250 and 100 updates "
    .. "a second; at 250 a cycle of 53.1 updates at 80 fps, 51.2 at 144, 52.1 at 240 (Half-Life's 52)", function()
    for _, rate in ipairs({ 250, 100 }) do
        for _, fps in ipairs({ 30, 45, 60, 80, 100, 144, 165, 200, 240, 300 }) do
            for _, jitter in ipairs({ false, 0.3 }) do
                local perTap = ducktapRun(fps, rate, jitter or nil, 20, fps)
                local label = string.format("%d fps, PhysicsRate %d%s", fps, rate, jitter and ", +-30 %" or "")
                t.truthy(#perTap > 80, label .. ": taps " .. #perTap)
                for i, n in ipairs(perTap) do
                    t.eq(n, 1, label .. ": ground updates of tap " .. i)
                end
            end
        end
    end
    local _, cycle = ducktapRun(80, 250, nil, 20)
    t.near(cycle, 53.12, 0.05, "updates a cycle at 80 fps")
    _, cycle = ducktapRun(144, 250, nil, 20)
    t.near(cycle, 51.18, 0.05, "at 144 fps")
    _, cycle = ducktapRun(240, 250, nil, 20)
    t.near(cycle, 52.07, 0.05, "at 240 fps")
end)

-- Fails with: no wipe; the wipe under the 2020 rule; no duck in the air under the 2022 rule;
-- a notch that makes a wiped key count again not waiting for its update.
t.test("the 2022 rule: under +ducktap a counting duck key ducks in the air; the first release on the ground wipes it "
    .. "until every duck key is let go; a notch while wiped and held counts again; 2020: no duck, no wipe", function()
    withRule(true, function()
        local d = duck.new(false)
        local out = hook(d, { held = true, tap = true }, false, 3)
        t.eq(events(out), "1 ducked", "ducked in the air")
        t.falsy(d.wiped)
        out = hook(d, { held = true, tap = true }, true, 3)
        t.eq(events(out), "1 stood, 2 pressed, 3 lift", "the landing: a release (standing up), a press, the lift")
        t.eq(out.ground, 2, "two updates of friction at that landing")
        t.truthy(d.wiped, "the release wiped the duck key")
        t.falsy(d.keyHeld)
        out = hook(d, { held = true, tap = true }, false, 3)
        t.eq(events(out), "", "the next flight: the held key doesn't count")
        t.eq(d.state, S)
        out = hook(d, { held = true, tap = true, notch = true }, false, 2)
        t.falsy(d.wiped, "a notch while wiped and held")
        t.eq(events(out), "1 ducked", "counts again: ducked in the air")
        d.wiped = true
        duck.frame(d, keys({ tap = true }))
        t.falsy(d.wiped, "every duck key let go")
        t.truthy(duck.heldInAir(duck.new(false)) == false)
        -- That notch at a hook with no update, the key let go before the next hook's update:
        -- the button went down (the wipe had left it idle), so that update has it; here on the
        -- ground with the ducktap key up too: a tap by hand.
        d = duck.new(false)
        d.wiped = true
        hook(d, { held = true, notch = true }, true, 0)
        t.falsy(d.wiped, "counts again")
        out = hook(d, {}, true, 2)
        t.eq(events(out), "1 pressed, 2 lift", "the notch's update has the button")
    end)
    withRule(false, function()
        local d = duck.new(false)
        local out = hook(d, { held = true, tap = true }, false, 3)
        t.eq(events(out), "", "2020: not ducked in the air under +ducktap")
        out = hook(d, { held = true, tap = true }, true, 3)
        t.eq(events(out), "1 pressed, 2 lift", "a plain tap at the landing")
        t.falsy(d.wiped, "no wipe")
        t.truthy(d.keyHeld)
        out = hook(d, { held = true }, false, 2)
        t.eq(events(out), "1 ducked", "the key ducks again once the ducktap key is up")
    end)
end)

-- Fails with: the mark kept (set) under AutoHop.
t.test("the jump: with AutoHop a held key jumps on every update on the ground after its duck step and the mark stays "
    .. "clear; without it one jump per press, and a press in the air is used up", function()
    local d = duck.new(false)
    duck.frame(d, keys({ jump = true, autoHop = true }))
    t.truthy(duck.jump(d, duck.jumpButton(d, true), true), "on the ground")
    t.falsy(d.jumpWas, "the mark stays clear")
    t.falsy(duck.jump(d, duck.jumpButton(d, false), false), "in the air")
    t.falsy(d.jumpWas, "the mark stays clear in the air too")
    t.truthy(duck.jump(d, duck.jumpButton(d, true), true), "landed with the key still held: jumps again")
    t.truthy(duck.jump(d, duck.jumpButton(d, false), true), "and on every update that is on the ground")
    -- Without AutoHop.
    d = duck.new(false)
    duck.frame(d, keys({ jump = true }))
    t.truthy(duck.jump(d, duck.jumpButton(d, true), true), "a fresh press on the ground")
    t.truthy(d.jumpWas)
    t.falsy(duck.jump(d, duck.jumpButton(d, false), false), "in the air")
    t.falsy(duck.jump(d, duck.jumpButton(d, true), true), "landed with the key still held: no jump")
    duck.frame(d, keys({}))
    t.falsy(duck.jump(d, duck.jumpButton(d, true), true), "let go")
    t.falsy(d.jumpWas, "no button clears the mark")
    duck.frame(d, keys({ jump = true }))
    t.truthy(duck.jump(d, duck.jumpButton(d, true), true), "pressed again: jumps")
    d = duck.new(false)
    duck.frame(d, keys({ jump = true }))
    t.falsy(duck.jump(d, duck.jumpButton(d, true), false), "pressed in the air")
    t.falsy(duck.jump(d, duck.jumpButton(d, true), true), "the press was used up in the air")
end)

-- Fails with: the jump notch on every update of its hook.
t.test("a held jump key gives the jump button on every update, a jump notch on its hook's first update only; a notch "
    .. "in the air does nothing and isn't kept; at a hook with no update it jumps at once", function()
    local d = duck.new(false)
    duck.frame(d, keys({ jump = true }))
    t.truthy(duck.jumpButton(d, true))
    t.truthy(duck.jumpButton(d, false))
    duck.frame(d, keys({ jumpNotch = true }))
    t.truthy(duck.jumpButton(d, true), "a notch on the first update")
    t.falsy(duck.jumpButton(d, false), "not on the others")
    -- A hook whose first update is in the air and whose second is on the ground (a slide
    -- that ends inside the hook): the notch belonged to the first.
    d = duck.new(false)
    duck.frame(d, keys({ jumpNotch = true, autoHop = true }))
    t.falsy(duck.jump(d, duck.jumpButton(d, true), false))
    t.falsy(duck.jump(d, duck.jumpButton(d, false), true), "the notch isn't on the second update")
    duck.frame(d, keys({}))
    t.falsy(duck.jump(d, duck.jumpButton(d, true), true), "nor kept for the next hook")
    -- On the ground at a hook with three updates: the first jumps.
    d = duck.new(false)
    local out = hook(d, { jumpNotch = true }, true, 3)
    t.eq(out.jumped, 1)
    -- At a hook with no update, on the ground: at once.
    d = duck.new(false)
    out = hook(d, { jumpNotch = true }, true, 0)
    t.eq(out.jumped, 0, "a jump can't wait for the next hook")
end)

-- Fails with: AutoHop under the ducktap key (part 1); the mark set under AutoHop (part 2);
-- OpenAG's cl_autojump instead of Bunnymod XT's (part 3: one update without the jump
-- button before the hop).
t.test("ducktap wins: hopping with Space, Shift pressed in the air gives the tap at the landing and no jump; Shift "
    .. "pressed at the landing hook gives a jump with the transition begun; Shift let go on the ground hops at once",
    function()
        -- 1. Hopping, then Shift pressed in the air.
        local d = duck.new(false)
        local out = hook(d, { jump = true, autoHop = true }, true, 1)
        t.eq(out.jumped, 1, "a hop")
        hook(d, { jump = true, autoHop = true, tap = true }, false, 3)
        out = hook(d, { jump = true, autoHop = true, tap = true }, true, 3)
        t.eq(out.jumped, nil, "no jump at the landing")
        t.eq(events(out), "1 pressed, 2 lift", "the tap")
        -- 2. Hopping, Shift pressed on the landing hook.
        d = duck.new(false)
        hook(d, { jump = true, autoHop = true }, true, 1)
        hook(d, { jump = true, autoHop = true }, false, 3)
        out = hook(d, { jump = true, autoHop = true, tap = true }, true, 3)
        t.eq(out.jumped, 1, "the press update jumps")
        t.eq(events(out), "1 pressed, 2 dropped", "with the transition begun, dropped in the air")
        -- 3. Shift and Space held on the ground (a low ceiling keeps the taps down), Shift let go.
        d = duck.new(false)
        hook(d, { jump = true, autoHop = true, tap = true }, false, 2) -- the press of Space used up in the air
        out = hook(d, { jump = true, autoHop = true, tap = true }, true, 4, { lift = false })
        t.eq(out.jumped, nil, "no jump while both are held")
        t.eq(out.ground, 4)
        out = hook(d, { jump = true, autoHop = true }, true, 2, { lift = false })
        t.eq(out.jumped, 1, "Shift let go: AutoHop hops on the next update")
    end)

-- Fails with: the lift leaving the player on the ground (the jump fires after the lift), or
-- physics.simulate jumping before the duck step, or jumping at once at a hook with no update
-- where its first update would lift (the jump without that update's duck step tried first).
t.test("the duck step comes before the jump: a release in the transition plus a jump is a lift and no jump; a press "
    .. "plus a jump jumps, and the next update in the air ducks if held; a release fully ducked plus a jump does both; "
    .. "a hook with no update jumps at once only where its first update would",
    function()
        local d = duck.new(false)
        hook(d, { held = true }, true, 1)
        t.eq(d.state, I)
        local out = hook(d, { jump = true }, true, 2)
        t.eq(events(out), "1 lift")
        t.eq(out.jumped, nil, "the jump finds the player in the air")
        t.truthy(d.jumpWas, "and the press is used up")
        d = duck.new(false)
        out = hook(d, { held = true, jump = true }, true, 2)
        t.eq(out.jumped, 1)
        t.eq(events(out), "1 pressed, 2 ducked", "the jump with the transition begun, ducked at once in the air")
        d = duck.new(true)
        out = hook(d, { jump = true }, true, 1)
        t.eq(events(out), "1 stood")
        t.eq(out.jumped, 1, "stood up, then jumped")
        t.eq(out.scaled, 1, "that update still scaled")
        -- At a hook with no update a jump can't wait (0.3's rule), but only where the first
        -- update would jump (B7): a release in the transition lifts on that update first, by
        -- hand or under +ducktap; with no room to lift the player stays on the ground and jumps.
        d = duck.new(false)
        hook(d, { held = true }, true, 1)
        out = hook(d, { jump = true }, true, 0)
        t.eq(out.jumped, nil, "no jump at once: the first update lifts")
        t.eq(d.state, I, "and nothing ran")
        out = hook(d, { jump = true }, true, 2)
        t.eq(events(out), "1 lift", "the lift on the next hook's first update")
        t.eq(out.jumped, nil, "the jump finds the player in the air")
        d = duck.new(false)
        hook(d, { tap = true }, true, 1)
        out = hook(d, { tap = true, jump = true }, true, 0)
        t.eq(out.jumped, nil, "+ducktap after its press: the lift first")
        d = duck.new(false)
        hook(d, { held = true }, true, 1)
        out = hook(d, { jump = true }, true, 0, { lift = false })
        t.eq(out.jumped, 0, "no room to lift: the jump at once")
        d = duck.new(false)
        out = hook(d, { jump = true }, true, 0)
        t.eq(out.jumped, 0, "standing: the jump at once")
        -- Fully ducked with the duck key let go, the first update stands up and then jumps
        -- standing: at a hook with no update the jump waits for it (a notch too). (Fails
        -- with: a stand-up not among the first update's events that hold the jump back:
        -- the hop starts 18 units low, fully ducked.)
        for _, k in ipairs({ { jump = true }, { jump = true, autoHop = true }, { jumpNotch = true } }) do
            d = duck.new(true)
            out = hook(d, k, true, 0)
            t.eq(out.jumped, nil, "fully ducked, the duck let go: no jump at once")
            out = hook(d, { jump = k.jump, autoHop = k.autoHop }, true, 1)
            t.eq(events(out), "1 stood")
            t.eq(out.jumped, 1, "stood up, then jumped, on the next hook's first update")
        end
    end)

-- Fails with: a jump notch judged in the air at a hook with no update (dropped there, or
-- setting the "jump is down" mark there).
t.test("in the air at a hook with no update, a jump notch waits for the next update: one that begins on the ground "
    .. "(Unreal landed the character in between) jumps", function()
    for _, k in ipairs({ { jumpNotch = true, autoHop = true }, { jumpNotch = true },
        { jumpNotch = true, tap = true, autoHop = true } }) do
        local d = duck.new(false)
        local out = hook(d, k, false, 0)
        t.eq(out.jumped, nil, "nothing in the air")
        out = hook(d, { jump = k.jump, tap = k.tap, autoHop = k.autoHop }, true, 1)
        t.eq(out.jumped, 1, string.format("jumped on the ground (AutoHop %s, Shift %s)", tostring(k.autoHop),
            tostring(k.tap)))
    end
    -- A notch from a hook with no update waits for one update only.
    local d = duck.new(false)
    hook(d, { jumpNotch = true }, false, 0)
    hook(d, {}, false, 2)
    t.eq(hook(d, {}, true, 1).jumped, nil, "spent by the next update, in the air")
end)

-- Fails with: a press in a refused tap not starting the timer again.
t.test("a refused lift stays in the transition with the view held and the timer running; a new press starts again at "
    .. "28; the first update with room lifts", function()
    local d = duck.new(false)
    hook(d, { held = true }, true, 25) -- (a frame runs 25 updates at most)
    hook(d, { held = true }, true, 25)
    local view = d.view
    t.near(view, hlCurve(196), 1e-9)
    local out = hook(d, {}, true, 10, { lift = false })
    t.eq(#out.events, 10, "asked again on every update")
    t.eq(out.events[10].what, "refused")
    t.eq(d.state, I)
    t.eq(d.view, view, "the view held")
    t.eq(d.timer, 1000 - 4 * 59, "the timer runs on")
    out = hook(d, { held = true }, true, 1, { lift = false })
    t.eq(events(out), "1 pressed")
    t.eq(d.timer, 1000)
    t.eq(d.view, 28, "the curve starts again")
    out = hook(d, {}, true, 3, { lift = false })
    t.eq(events(out), "1 refused, 2 refused, 3 refused")
    out = hook(d, {}, true, 3)
    t.eq(events(out), "1 lift", "room: the lift")
end)

-- Fails with: room.ground ignored; room.air ignored.
t.test("a stand-up with no room waits fully ducked, scaled, asked again on every update, and comes on the first "
    .. "update with room, on the ground and in the air", function()
    local d = duck.new(true)
    local out = hook(d, {}, true, 5, { ground = false, air = true, lift = true })
    t.eq(events(out), "1 refused, 2 refused, 3 refused, 4 refused, 5 refused")
    t.eq(out.scaled, 5)
    t.eq(d.state, D)
    out = hook(d, { held = true }, true, 2, { ground = false })
    t.eq(events(out), "", "pressing again changes nothing")
    out = hook(d, {}, true, 2, { ground = true, air = false })
    t.eq(events(out), "1 stood")
    d = duck.new(true)
    out = hook(d, {}, false, 3, { ground = true, air = false })
    t.eq(events(out), "1 refused, 2 refused, 3 refused", "in the air")
    out = hook(d, {}, false, 1, { ground = false, air = true })
    t.eq(events(out), "1 stood")
end)

-- Fails with: heldInAir as keyHeld alone.
t.test("heldInAir: true for a counting duck key without a ducktap key, and with one under the 2022 rule; false "
    .. "under the 2020 rule, for a notch alone and for a wiped key", function()
    local d = duck.new(false)
    duck.frame(d, keys({ held = true }))
    t.eq(duck.heldInAir(d), true)
    duck.frame(d, keys({ held = true, tap = true }))
    t.eq(duck.heldInAir(d), true, "2022")
    withRule(false, function()
        t.eq(duck.heldInAir(d), false, "2020: the ducktap rule takes the button out in the air")
    end)
    duck.frame(d, keys({ notch = true }))
    t.eq(duck.heldInAir(d), false, "a notch: the hook's other updates may stand up")
    t.truthy(d.notch, "and asking changed nothing")
    d.wiped = true
    duck.frame(d, keys({ held = true, tap = true }))
    t.eq(duck.heldInAir(d), false, "a wiped key")
end)

-- What the request for the crouched hull reads (dk.out.held): physics.simulate writes d.held
-- at the end of a frame with updates. Fails with: held from the last update's button; held
-- not kept through a hook with no update (false there, or the last update's button).
t.test("held: the duck button down on every update of the hook; Ctrl held gives true, +ducktap on the ground over "
    .. "several updates false, a notch over several updates false; a hook with no update keeps the last", function()
    local d = duck.new(false)
    local out = hook(d, { held = true }, true, 3)
    t.eq(out.held, true, "Ctrl held")
    t.eq(d.held, true, "kept with the duck state")
    out = hook(d, { held = true }, true, 0)
    t.eq(out.held, true, "a hook with no update keeps it")
    -- +ducktap under a ceiling (no room to lift): pressed, refused, pressed. The last update has
    -- the button, the second hasn't.
    d = duck.new(false)
    out = hook(d, { tap = true }, true, 3, { lift = false })
    t.eq(events(out), "1 pressed, 2 refused, 3 pressed")
    t.eq(out.held, false, "+ducktap on the ground")
    out = hook(d, { tap = true }, true, 0, { lift = false })
    t.eq(out.held, false, "kept through a hook with no update")
    d = duck.new(false)
    out = hook(d, { notch = true }, false, 3)
    t.eq(events(out), "1 ducked, 2 stood")
    t.eq(out.held, false, "a notch: the button on its update only")
end)

-- Fails with: the mark not set by a press in the air without AutoHop; a held key's button
-- on the hook's first update only.
t.test("without ducking, the per-update jump gives 0.3.1's physics.wantJump on 40,000 random frames of 0 to 4 "
    .. "updates, with AutoHop and without", function()
    local frames, diffs = 0, 0
    for _, autoHop in ipairs({ true, false }) do
        for seed = 1, 5 do
            math.randomseed(seed)
            local latch = { latched = false }
            local d = duck.new(false)
            local held, ground = false, true
            for _ = 1, 4000 do
                if math.random() < 0.1 then
                    held = not held
                end
                if math.random() < 0.2 then
                    ground = not ground
                end
                local steps = math.random(0, 4)
                -- 0.3.1: one decision a frame, the jump on its first update, or at once with none.
                local old = physics.wantJump(latch, held, ground, autoHop) and ground
                duck.frame(d, keys({ jump = held, autoHop = autoHop }))
                local mine = runUpdates(d, ground, steps, nil, 250).jumped ~= nil
                frames = frames + 1
                if mine ~= old then
                    diffs = diffs + 1
                end
            end
        end
    end
    t.eq(frames, 40000)
    t.eq(diffs, 0, "frames where the two jump rules differ")
end)

-- Fails with: no clamp; the drop not set again on the ground; the lift's height ignored;
-- the anticipation ignored; a duck in the air moving the drop.
t.test("the eye: 70.2 cm standing, 66.5, 56.9, 27.7, -1.5, -14.8 in the transition, 30.2 above the crouched middle "
    .. "ducked, -14.8 with no hull, 77.3 in a tap's flight; never above the ducked eye while crouched", function()
    local s, E, delta = 2.5, 70.2, 45
    local d = duck.new(false)
    t.near(E + duck.eyeOffset(d, s, false), 70.2, 1e-9, "standing")
    local transition = { [50] = 66.54765625, [100] = 56.91875, [200] = 27.7, [300] = -1.51875, [396] = -14.77467 }
    for ms, eye in pairs(transition) do
        d.state, d.timer, d.view = I, 1000 - ms, duck.curve(1000 - ms)
        t.near(E + duck.eyeOffset(d, s, false), eye, 1e-5, ms .. " ms into the transition")
    end
    -- Fully ducked on the ground: with the hull (the crouched middle 45 cm lower) and without.
    d = duck.new(true)
    duck.groundDrop(d, true, delta, s)
    t.near(d.drop, 0, 1e-12)
    t.near(E + duck.eyeOffset(d, s, true), 30.2, 1e-9, "above the crouched middle")
    duck.groundDrop(d, false, delta, s)
    t.near(E + duck.eyeOffset(d, s, false), -14.8, 1e-9, "no hull: above the standing middle")
    -- Ducked in the air keeps the middle: 30.2 either way.
    d = duck.new(false)
    local _, event, ground = duck.step(d, true, false, nil, 4)
    duck.eventDrop(d, event, false, s)
    t.near(E + duck.eyeOffset(d, s, false), 30.2, 1e-9, "in the air, no hull")
    t.near(E + duck.eyeOffset(d, s, true), 30.2, 1e-9, "in the air, crouched")
    t.falsy(ground)
    -- A tap's flight: Half-Life's origin 18 units up, the character 37.93 cm.
    d = duck.new(false)
    duck.step(d, true, true, nil, 4)
    _, event = duck.step(d, false, true, nil, 4)
    t.eq(event, "lift")
    duck.eventDrop(d, event, true, s, LIFT)
    t.near(d.drop, -7.07, 0.005, "the origin above the middle")
    t.near(E + duck.eyeOffset(d, s, false), 77.27, 0.005, "the tap's flight")
    -- The optimistic stand-up with the capsule still crouched: never above the ducked eye.
    d = duck.new(true)
    duck.groundDrop(d, true, delta, s)
    _, event = duck.step(d, false, true, nil, 4)
    t.eq(event, "stood")
    duck.eventDrop(d, event, true, s)
    t.near(duck.eyeOffset(d, s, false), 45, 1e-9, "unclamped: the origin 45 cm above the crouched middle")
    t.near(duck.eyeOffset(d, s, true), -40, 1e-9, "while the capsule reads crouched: the ducked eye")
    -- A duck completing on the ground this hook, the capsule standing until Unreal crouches it.
    d = duck.new(false)
    d.state, d.timer, d.view, d.wasDown = I, 604, duck.curve(604), true
    _, event = duck.step(d, true, true, nil, 4)
    t.eq(event, "ducked")
    duck.eventDrop(d, event, true, s)
    t.near(duck.eyeOffset(d, s, false), -85, 1e-9, "the same eye, above the standing middle")
    t.near(duck.eyeOffset(d, s, false, true), -40, 1e-9, "the game camera's anticipation of the crouch")
    -- On the ground the drop comes from the state and the capsule again, whatever came before.
    d = duck.new(false)
    duck.rebase(d, 3.2)
    duck.groundDrop(d, false, delta, s)
    t.eq(d.drop, 0, "set again on the ground")
end)

-- Fails with: confirm("refused") only from standing.
t.test("the game's answers: stood stands the physics up; refused and crouched make it fully ducked from standing "
    .. "or from the transition, keeping the timer", function()
    local d = duck.new(true)
    d.timer = 300
    duck.confirm(d, "stood")
    t.eq(d.state, S)
    t.eq(d.view, 28)
    t.eq(d.timer, 0)
    duck.confirm(d, "refused")
    t.eq(d.state, D)
    t.eq(d.view, 12)
    d = state(I, 996, duck.curve(996), false)
    duck.confirm(d, "refused")
    t.eq(d.state, D, "from the transition (a press under +ducktap after the optimistic stand-up)")
    t.eq(d.view, 12)
    t.eq(d.timer, 996, "the timer kept")
    d = state(I, 800, duck.curve(800), true)
    duck.confirm(d, "crouched")
    t.eq(d.state, D, "the game's crouch")
    d = duck.new(false)
    duck.confirm(d, "crouched")
    t.eq(d.state, D)
    t.falsy(pcall(duck.confirm, d, "maybe"), "an unknown answer is an error")
end)

-- Fails with: rebase setting the drop instead of moving it; copy sharing the table.
t.test("rebase moves the drop by the capsule's measured rise; copy is a separate table with every field", function()
    local d = duck.new(false)
    duck.rebase(d, 45.2)
    duck.rebase(d, -0.2)
    t.near(d.drop, 45, 1e-12)
    d.state, d.timer, d.tapHad, d.notch = I, 812, true, true
    local c = duck.copy(d)
    for k, v in pairs(d) do
        t.eq(c[k], v, k)
    end
    c.state, c.timer, c.drop = S, 0, 0
    t.eq(d.state, I, "the original keeps its state")
    t.eq(d.timer, 812)
    t.near(d.drop, 45, 1e-12)
end)

-- Fails with: the hulls' exact 18 on every slope; 18 nz cut down instead of rounded; the
-- band left out with h; the compiler's cut taken downwards instead of towards zero.
t.test("restGap: the ducked hull rests 18 nz units lower, rounded, as on Valve's maps (18 to 13.5 degrees, 17 to 23.6, "
    .. "16 to 30.6, 15 to 36.3, 14 to 41.4, 13 beyond); 17 on the owner's ramp; one less in the compiler's band",
    function()
        t.eq(duck.restGap(1), 18, "level ground")
        t.eq(duck.restGap(nil), 18, "no normal: level")
        t.eq(duck.restGap(1.0000001), 18, "a normal a hair over 1")
        local steps = { { 13.4, 18 }, { 13.6, 17 }, { 23.5, 17 }, { 23.7, 16 }, { 30.5, 16 }, { 30.7, 15 },
            { 36.2, 15 }, { 36.4, 14 }, { 41.3, 14 }, { 41.5, 13 }, { 45.5, 13 } }
        for _, step in ipairs(steps) do
            t.eq(duck.restGap(math.cos(math.rad(step[1]))), step[2], step[1] .. " degrees")
        end
        t.eq(duck.restGap(0.7), 13, "the steepest floor")
        t.eq(duck.restGap(-0.2), 0, "below 0 counts as 0")
        -- The owner's ramp: normal (-8, 0, 25) made one unit long, 17.7 degrees. The log has its
        -- two hulls' planes 16.1913 apart along the normal (-68.4983 and -84.6896): 17 straight up.
        local nz = 25 / math.sqrt(8 * 8 + 25 * 25)
        t.eq(duck.restGap(nz), 17)
        t.near((84.6896 - 68.4983) / nz, duck.restGap(nz), 1e-3, "the log's planes, straight up")
        -- Why it matters there: a ducked hop on the spot at 100 updates a second ends its 73rd
        -- update 17.281 units below its take-off. 17 below, that reaches the floor (a clip,
        -- 90.47 u/s down the ramp in the log); 18 below, it would be caught with no speed.
        local fall = 268.328 * 0.73 - 0.5 * 800 * 0.73 * 0.73
        t.near(fall, -17.281, 1e-3)
        t.truthy(fall + duck.restGap(nz) < 0 and fall + 18 > 0)
        -- The compiler's rule with the face's defining height h, on the ramp (18 nz = 17.14).
        t.eq(duck.restGap(nz, 0), 17, "h of -18 nz or more: both cut down")
        t.eq(duck.restGap(nz, -17), 17)
        t.eq(duck.restGap(nz, -18), 16, "in the band: one less")
        t.eq(duck.restGap(nz, -34), 16, "still in the band (from -36 nz = -34.29)")
        t.eq(duck.restGap(nz, -35), 17, "below the band: both cut up")
        -- Halves: 18 nz = 13.5.
        t.eq(duck.restGap(0.75), 14, "halves up")
        t.eq(duck.restGap(0.75, 0), 14)
        t.eq(duck.restGap(0.75, -30), 13, "below the band: halves down")
        t.eq(duck.restGap(0.75, -20), 13, "in the band")
        t.eq(duck.restGap(1, -20), 18, "a whole 18 nz has no band")
    end)

-- Fails with: a released duck key staying wiped; a notch with a key held leaving the wipe;
-- a notch that makes a wiped key count again not waiting; a notch with a counting key held
-- waiting; a notch dropped at its hook under a ducktap key (the hook may run no update).
t.test("duck.frame: letting go of every duck key ends a wipe, and so does a notch with one held; a notch waits for "
    .. "its update, under a ducktap key too, but does nothing with a counting duck key held; the hook's keys are kept",
    function()
        local d = duck.new(false)
        d.wiped = true
        duck.frame(d, keys({ held = true }))
        t.truthy(d.wiped, "still held")
        t.falsy(d.keyHeld, "and not counting")
        duck.frame(d, keys({}))
        t.falsy(d.wiped, "let go")
        d.wiped = true
        duck.frame(d, keys({ held = true, notch = true }))
        t.falsy(d.wiped, "a notch while held")
        t.truthy(d.keyHeld)
        t.truthy(d.notch, "the notch went down on a button the wipe had left idle: it waits for its update")
        duck.button(d, true)
        duck.frame(d, keys({ held = true, notch = true }))
        t.falsy(d.notch, "with a counting key held the button is down already")
        duck.frame(d, keys({ notch = true }))
        t.truthy(d.notch)
        d.notch = false
        duck.frame(d, keys({ notch = true, tap = true }))
        t.truthy(d.notch, "under a ducktap key too: the update spends it")
        duck.frame(d, keys({ tap = true, jump = true, jumpNotch = true, autoHop = true }))
        t.eq(d.tap, true)
        t.eq(d.jumpKey, true)
        t.eq(d.jumpNotch, true)
        t.eq(d.autoHop, true)
        duck.frame(d, keys({}))
        t.eq(d.tap, false)
        t.eq(d.jumpKey, false)
        t.eq(d.jumpNotch, false)
        t.eq(d.autoHop, false)
    end)

-- physics.simulate with ducking, beyond the update loop above: the moves, slides and running
-- into a slope.

-- A slope rising along +X at deg degrees: its unit normal.
local function slope(deg)
    local a = math.rad(deg)
    return { nx = -math.sin(a), ny = 0, nz = math.cos(a) }
end

-- A slide up a slope of deg degrees as movement.lua starts one: Half-Life's player 1/32 unit
-- off its plane, the velocity running along it at a level speed of v.
local function slideOn(deg, v)
    local n = slope(deg)
    return { vz = v * math.tan(math.rad(deg)), nx = n.nx, ny = n.ny, nz = n.nz, h = P.restHeight / n.nz, rise = 0,
        push = 0, time = 0, clipped = true, dx = 0, dy = 0, ox = 0, oy = 0 }
end

-- One hook through physics.simulate with ducking: the keys k, then `steps` updates of 1/rate
-- s from the velocity (f.vx, 0, f.vz), on the ground or not (f.ground), with f.slide, f.runIn,
-- f.room, f.wish and the jump argument f.jump. Returns dk.out and simulate's vx, vy, vz,
-- jumped.
local function duckFrame(d, k, f, steps, rate)
    duck.frame(d, keys(k))
    local dk = { d = d, room = f.room, runIn = f.runIn, out = {} }
    local vx, vy, vz, jumped = physics.simulate({}, f.vx or 0, 0, f.vz or (f.slide and f.slide.vz) or 0, f.ground, 0,
        f.wish, f.jump or false, P, steps / rate, rate, f.slide, nil, dk)
    return dk.out, vx, vy, vz, jumped
end

-- Fails with: the scale before the cap to MaxSpeed (InputSpeed 400 times 0.333: 133.2 u/s);
-- no scale in physics.simulate; the wish in the game's own direction not scaled.
t.test("through physics.simulate a fully ducked update's wish is capped to MaxSpeed, then scaled: a ducked walk with "
    .. "InputSpeed 400 tops at 106.56 u/s, in the game's own direction too; each such update is counted", function()
    t.eq(P.inputSpeed, 400, "a movement key asks for 400")
    for _, wish in ipairs({ { forward = 1, right = 0 }, { x = 1, y = 0, speed = P.maxSpeed } }) do
        local label = wish.speed and "the game's direction" or "a movement key"
        local d = duck.new(true)
        local sim, vx, vy, vz = {}, 0, 0, 0
        local scaled, updates = 0, 0
        for _ = 1, 160 do -- 2 s at 80 fps
            duck.frame(d, keys({ held = true }))
            local dk = { d = d, out = {} }
            local nx, ny, nz, _, steps = physics.simulate(sim, vx, vy, vz, true, 0, wish, false, P, 1 / 80, 250, nil,
                nil, dk)
            vx, vy, vz = nx, ny, nz
            scaled, updates = scaled + dk.out.scaled, updates + steps
        end
        t.near(math.sqrt(vx * vx + vy * vy), 106.56, 1e-6, label .. ": the ducked walk")
        t.truthy(updates > 490, label .. ": updates " .. updates)
        t.eq(scaled, updates, label .. ": every update scaled")
    end
    local d = duck.new(false)
    local sim, vx, vy, vz = {}, 0, 0, 0
    for _ = 1, 160 do
        duck.frame(d, keys({}))
        vx, vy, vz = physics.simulate(sim, vx, vy, vz, true, 0, { forward = 1, right = 0 }, false, P, 1 / 80, 250, nil,
            nil, { d = d, out = {} })
    end
    t.near(math.sqrt(vx * vx + vy * vy), P.maxSpeed, 1e-6, "standing, MaxSpeed")
end)

-- Fails with: the slide's gravity taken before the duck step (the rise an update's gravity
-- low: 3.2 u/s at 250 a second, 8 at 100); the slide kept after the duck (its gravity and
-- clips on the frame's other updates).
t.test("a duck in a slide ends it in its own update, with no slide gravity or clip from there on, and sets "
    .. "slide.ducked: the frame's rise is the slide's at the hook, at 250 and 100 updates a second", function()
    for _, rate in ipairs({ 250, 100 }) do
        local slide = slideOn(20, 800)
        local out, vx, vy, vz = duckFrame(duck.new(false), { held = true }, { ground = false, vx = 800, slide = slide },
            3, rate)
        t.eq(events(out), "1 ducked", rate .. " a second: fully ducked at once in the air")
        t.eq(vz, slide.vz, rate .. " a second: the rise the slide had at the hook")
        t.eq(vx, 800, "no clip against the slope")
        t.eq(vy, 0)
        t.eq(slide.ducked, true)
        t.falsy(slide.ended)
        t.eq(slide.time, 0, "no update of the slide ran")
        t.eq(out.scaled, 2, "the updates after the duck's")
    end
end)

-- Fails with: a stand-up let in the air while sliding.
t.test("fully ducked in a slide, letting go stands nothing up (the slope lies closer below than the 18 units a "
    .. "stand-up in the air needs) and the slide goes on; on the update that ends the slide it stands up on the ground",
    function()
        local slide = slideOn(20, 800)
        local d = duck.new(true)
        local out = duckFrame(d, {}, { ground = false, vx = 800, slide = slide }, 3, 250)
        t.eq(events(out), "1 refused, 2 refused, 3 refused")
        t.eq(d.state, D)
        t.near(slide.time, 3 / 250, 1e-12, "three updates of the slide")
        t.falsy(slide.ducked)
        -- Along the slope at 505.5 u/s the slide ends at the second update's ground check.
        slide = slideOn(20, 505.5)
        d = duck.new(true)
        out = duckFrame(d, {}, { ground = false, vx = 505.5, slide = slide }, 3, 250)
        t.truthy(slide.ended)
        t.eq(events(out), "1 refused, 2 stood")
        t.eq(out.events[2].ground, true)
        t.eq(out.ground, 2)
    end)

-- Fails with: the run-in decided from the velocity before the update's friction (0.3.1's
-- rule at the hook: 425 to 442 u/s slide here); the slide started on the run-in's own update
-- (an update of slide gravity too many); the level velocity changed by the run-in (the
-- slide's clip instead of the step move's); the slide's path counted from the run-in
-- instead of from the frame's start.
t.test("running into an upward slope is decided after each update's ground move, as in Half-Life: on 30 degrees at 100 "
    .. "updates a second 442 u/s doesn't slide and 443 does (442.6 after the update's 4 % of friction), from the next "
    .. "update, with the clip's rise and the level velocity the update left", function()
    local n = slope(30)
    for _, case in ipairs({ { 425, false }, { 440, false }, { 442, false }, { 443, true }, { 445, true } }) do
        local out = duckFrame(duck.new(false), {}, { ground = true, vx = case[1], runIn = n }, 2, 100)
        t.eq(out.runIn ~= nil, case[2], case[1] .. " u/s")
    end
    -- One update: friction to 427.2, rising 427.2 sin 30 cos 30 = 184.98.
    local out, vx, vy, vz = duckFrame(duck.new(false), {}, { ground = true, vx = 445, runIn = n }, 1, 100)
    local up = 427.2 * math.sin(math.rad(30)) * math.cos(math.rad(30))
    t.eq(out.runIn.k, 1)
    t.near(out.runIn.vx, 427.2, 1e-9, "the velocity after the update's friction")
    t.eq(out.runIn.vy, 0)
    t.near(out.runIn.up, up, 1e-9, "the clip's rise")
    t.near(up, 184.98, 0.005)
    t.near(vx, 427.2, 1e-9, "the level velocity as the update left it")
    t.eq(vy, 0)
    t.near(vz, up, 1e-12, "rising with the clip's rise")
    t.eq(out.ground, 1, "the run-in's update ran on the ground")
    local s = out.slide
    t.near(s.vz, up, 1e-12)
    t.eq(s.nx, n.nx)
    t.eq(s.nz, n.nz)
    t.near(s.h, P.restHeight / n.nz, 1e-12, "Half-Life's step move leaves the player 1/32 unit off the slope")
    t.near(s.dx, 4.272, 1e-9, "the path's travel from the frame's start")
    t.eq(s.dy, 0)
    t.near(s.rise, 4.272 * math.tan(math.rad(30)), 1e-9, "the plane's rise under it")
    t.eq(s.time, 0, "no update of the slide yet")
    t.eq(s.clipped, true)
    -- Two updates: the second is the slide's, with its gravity and a clip against the slope.
    out, vx, vy, vz = duckFrame(duck.new(false), {}, { ground = true, vx = 445, runIn = n }, 2, 100)
    local ex, ey, ez = physics.clip(427.2, 0, up - 800 / 100, n.nx, n.ny, n.nz)
    t.near(vx, ex, 1e-9, "the slide's update")
    t.eq(vy, ey)
    t.near(vz, ez, 1e-9)
    t.eq(out.ground, 1)
    t.near(out.slide.time, 0.01, 1e-12)
end)

-- Fails with: the run-in decided at the hook (the +ducktap press lifted on the next update,
-- where Half-Life slides); the run-in after the frame's updates (the slide from the frame's
-- first update).
t.test("a +ducktap press or a duck notch at 500 u/s at the foot of a 30 degree slope runs into it in its own update "
    .. "(friction to 492 u/s, rising 213) and the next update drops the transition in the air, no lift; the 2022 "
    .. "rule's ducked landing stands up, then slides, standing", function()
    local n = slope(30)
    local up = 492 * math.sin(math.rad(30)) * math.cos(math.rad(30))
    for _, k in ipairs({ { tap = true }, { notch = true } }) do
        local d = duck.new(false)
        local out = duckFrame(d, k, { ground = true, vx = 500, runIn = n }, 2, 250)
        local label = k.tap and "+ducktap" or "a notch"
        t.eq(events(out), "1 pressed, 2 dropped", label)
        t.eq(out.events[1].ground, true, label)
        t.eq(out.events[2].ground, false, label .. ": in the air on the next update")
        t.eq(out.lifted, nil, label .. ": no lift")
        t.eq(out.runIn.k, 1, label)
        t.near(out.runIn.vx, 492, 1e-9, label .. ": one update of friction at 250 a second")
        t.near(out.runIn.up, up, 1e-9, label)
        t.near(up, 213.04, 0.005)
        t.eq(d.state, S, label .. ": standing in the slide")
        t.falsy(out.slide.ducked, label .. ": no duck in the air")
    end
    withRule(true, function()
        local d = duck.new(true)
        d.tapHad = true -- the 2022 rule kept the button down in the air under +ducktap
        local out = duckFrame(d, { held = true, tap = true }, { ground = true, vx = 500, runIn = n }, 2, 250)
        t.eq(events(out), "1 stood", "stood up on the ground, then ran into the slope")
        t.truthy(d.wiped, "the release wiped the duck key")
        t.eq(out.runIn.k, 1)
        t.near(out.runIn.up, up, 1e-9)
        t.eq(d.state, S)
        t.eq(out.scaled, 1, "the stand-up's update still scaled")
    end)
end)

-- Fails with: the run-in on a jump's update; on a lift's update; after a slide that ended in
-- the frame (the run-in armed for a frame that began in the air); a held jump key that can't
-- jump stopping it.
t.test("no run-in on an update that jumps or lifts a duck tap, nor in a frame that began in a slide; a jump key held "
    .. "since a jump runs into the slope", function()
    local n = slope(30)
    local out, _, _, vz = duckFrame(duck.new(false), { jump = true, autoHop = true }, { ground = true, vx = 500,
        runIn = n }, 3, 250)
    t.eq(out.jumped, 1)
    t.eq(out.runIn, nil, "a jump")
    t.near(vz, P.jumpSpeed, 1e-9)
    local d = duck.new(false)
    d.jumpWas = true
    out = duckFrame(d, { jump = true }, { ground = true, vx = 500, runIn = n }, 2, 250)
    t.eq(out.jumped, nil)
    t.eq(out.runIn.k, 1, "the press used up: it runs into the slope")
    d = state(I, 996, duck.curve(996), true) -- pressed on the hook before's last update
    out = duckFrame(d, {}, { ground = true, vx = 500, runIn = n }, 3, 250)
    t.eq(out.lifted, 1)
    t.eq(out.runIn, nil, "the lift's update is in the air from its duck step")
    -- A slide along 20 degrees at 480 u/s ends at the first update's ground check. A 40 degree
    -- slope there would make the ground updates rise 233 u/s.
    local slide = slideOn(20, 480)
    out = duckFrame(duck.new(false), {}, { ground = false, vx = 480, slide = slide, runIn = slope(40) }, 3, 250)
    t.truthy(slide.ended)
    t.eq(out.ground, 3)
    t.eq(out.runIn, nil, "after the slide")
    out = duckFrame(duck.new(false), {}, { ground = true, vx = 480, runIn = slope(40) }, 1, 250)
    t.eq(out.runIn.k, 1, "without the slide it would")
    t.near(out.runIn.up, 232.57, 0.005)
end)

-- Fails with: the next update's duck button built from where the mod has the player (on
-- the ground) instead of where Half-Life's client saw it (in the air); that view not kept
-- to the next frame; a frame with no update trying its first update with the ground view.
t.test("a ground update that runs into a slope rising over 180 u/s at its end, and not half an update of gravity "
    .. "later, stays on the ground, but the next duck button sees the air: +ducktap with Ctrl held (2022) at 424 u/s "
    .. "onto 30 degrees lifts an update later, as in Half-Life, also across frames", function()
    local n = slope(30)
    -- Friction leaves 417.2 u/s of 424 and a rise of 180.66 u/s: over 180 at the update's last
    -- ground check, 179.06 at the next one's first.
    t.near(424 * 0.984 * math.sin(math.rad(30)) * math.cos(math.rad(30)), 180.66, 0.005)
    local function play(v, split, jumpAt)
        local d = duck.new(false)
        local list, k0, vx, ground = {}, 0, v, true
        local jumped
        for i, steps in ipairs(split) do
            duck.frame(d, keys({ held = true, tap = true, jump = i == jumpAt }))
            local dk = { d = d, runIn = n, out = {} }
            vx = physics.simulate({}, vx, 0, 0, ground, 0, nil, false, P, steps / 250, 250, nil, nil, dk)
            for _, e in ipairs(dk.out.events) do
                list[#list + 1] = (k0 + e.k) .. " " .. e.what
            end
            jumped = jumped or dk.out.jumped
            ground = not (dk.out.lifted or dk.out.runIn or dk.out.jumped)
            k0 = k0 + steps
        end
        return table.concat(list, ", "), jumped
    end
    withRule(true, function()
        for _, split in ipairs({ { 3 }, { 1, 2 }, { 1, 0, 2 } }) do
            t.eq(play(424, split), "1 pressed, 3 lift", "frames of " .. table.concat(split, "+"))
        end
        t.eq(play(420, { 3 }), "1 pressed, 2 lift", "a rise under 180 u/s: the plain tap")
        t.eq(play(427, { 3 }), "1 pressed, 2 ducked", "a slide, with Ctrl held ducking in it")
        -- Space pressed at a hook with no update right after: the next update, with the duck
        -- button down (Ctrl), lifts nothing and jumps, so the jump comes at once.
        local _, jumped = play(424, { 1, 0 }, 2)
        t.eq(jumped, 0, "the jump at once")
    end)
end)

-- Fails with: slide.jump used with ducking (a jump without the key); the jump argument used
-- with ducking; a press at the hook whose first update ends the slide taken as used up.
t.test("with ducking the jump comes from the keys, update by update: a held jump with AutoHop starts on the update a "
    .. "slide ends on; slide.jump and the jump argument count for nothing; without AutoHop a press during the slide is "
    .. "used up, and a press at the hook whose first update ends the slide jumps", function()
    local slide = slideOn(20, 505.5) -- ends at the second update's ground check
    local out, _, _, vz, jumped = duckFrame(duck.new(false), { jump = true, autoHop = true }, { ground = false,
        vx = 505.5, slide = slide }, 3, 250)
    t.truthy(slide.ended)
    t.eq(out.jumped, 2, "the update the slide ends on")
    t.truthy(jumped)
    t.near(vz, P.jumpSpeed, 1e-9)
    slide = slideOn(20, 505.5)
    slide.jump = true
    out = duckFrame(duck.new(false), {}, { ground = false, vx = 505.5, slide = slide, jump = true }, 3, 250)
    t.truthy(slide.ended)
    t.eq(out.jumped, nil, "slide.jump and the jump argument without a key")
    out = duckFrame(duck.new(false), {}, { ground = true, vx = 300, jump = true }, 2, 250)
    t.eq(out.jumped, nil, "the jump argument on the ground")
    slide = slideOn(20, 505.5)
    out = duckFrame(duck.new(false), { jump = true }, { ground = false, vx = 505.5, slide = slide }, 3, 250)
    t.truthy(slide.ended)
    t.eq(out.jumped, nil, "without AutoHop the press was used up in the air")
    slide = slideOn(20, 480) -- ends at the first update's ground check
    out = duckFrame(duck.new(false), { jump = true }, { ground = false, vx = 480, slide = slide }, 3, 250)
    t.truthy(slide.ended)
    t.eq(out.jumped, 1, "a fresh press, on the ground at the first update's ground check")
end)

-- Fails with: the duck button taken after the slide's ground check (a press on the update that
-- ends the slide).
t.test("+ducktap in a slide: no duck button in the air; the update the slide ends on has none either (the client last "
    .. "saw the player in the air), the next one presses and the one after lifts", function()
    local slide = slideOn(20, 505.5)
    local out = duckFrame(duck.new(false), { tap = true }, { ground = false, vx = 505.5, slide = slide }, 4, 250)
    t.truthy(slide.ended)
    t.eq(events(out), "3 pressed, 4 lift")
    t.eq(out.lifted, 4)
end)

-- Fails with: dk.out's counts carried over from the frame before (a frame run again after a
-- refused lift must count only its own updates).
t.test("dk.out is the frame's own: given the same table again, its events, counts, lift, jump and slide start from "
    .. "nothing; state, button and held are the duck state's", function()
    local d = duck.new(false)
    local dk = { d = d, runIn = slope(30), out = {} }
    duck.frame(d, keys({ tap = true }))
    physics.simulate({}, 500, 0, 0, true, 0, nil, false, P, 2 / 250, 250, nil, nil, dk)
    t.eq(events(dk.out), "1 pressed, 2 dropped")
    t.truthy(dk.out.runIn and dk.out.slide)
    dk.runIn = nil
    duck.frame(d, keys({ jump = true, autoHop = true }))
    physics.simulate({}, 0, 0, 0, true, 0, nil, false, P, 2 / 250, 250, nil, nil, dk)
    t.eq(events(dk.out), "")
    t.eq(dk.out.runIn, nil)
    t.eq(dk.out.slide, nil)
    t.eq(dk.out.jumped, 1)
    t.eq(dk.out.ground, 0)
    duck.frame(d, keys({ tap = true }))
    physics.simulate({}, 0, 0, 0, true, 0, nil, false, P, 2 / 250, 250, nil, nil, dk)
    t.eq(events(dk.out), "1 pressed, 2 lift")
    t.eq(dk.out.events[2].ground, true, "the lift's duck step found the player on the ground")
    t.eq(dk.out.jumped, nil)
    t.eq(dk.out.lifted, 2)
    t.eq(dk.out.ground, 1)
    t.eq(dk.out.state, d.state)
    t.eq(dk.out.button, false, "the last update's duck button")
    t.eq(dk.out.held, false)
    duck.frame(d, keys({ held = true }))
    physics.simulate({}, 0, 0, 0, false, 0, nil, false, P, 2 / 250, 250, nil, nil, dk)
    t.eq(events(dk.out), "1 ducked")
    t.eq(dk.out.lifted, nil)
    t.eq(dk.out.scaled, 1)
    t.eq(dk.out.ground, 0)
    t.eq(dk.out.button, true)
    t.eq(dk.out.held, true)
    physics.simulate({}, 0, 0, 0, false, 0, nil, false, P, 0, 250, nil, nil, dk)
    t.eq(events(dk.out), "", "a frame with no update")
    t.eq(dk.out.scaled, 0)
    t.eq(dk.out.state, D)
    t.eq(dk.out.held, true, "kept")
end)

-- Fails with: the slide's gravity taken twice, or not at all, with dk; the jump decided
-- otherwise than 0.3.1's without ducking; the wish or the leave down a slope changed.
t.test("without ducking physics.simulate moves the same with dk as without it: velocities, jumps, steps and leaves "
    .. "on 32,000 random frames on the ground, in the air and in slides, at 100 and 250 updates a second", function()
    local frames, diffs, seen = 0, 0, { jumps = 0, ends = 0, none = 0, leaves = 0 }
    local first
    for _, rate in ipairs({ 250, 100 }) do
        for _, autoHop in ipairs({ true, false }) do
            for seed = 1, 4 do
                math.randomseed(seed)
                local simA, simB, latch, d = {}, {}, { latched = false }, duck.new(false)
                local held, yaw = false, 0
                for _ = 1, 2000 do
                    if math.random() < 0.15 then
                        held = not held
                    end
                    yaw = yaw + (math.random() - 0.5) * 30
                    local r = math.random()
                    local ground = r < 0.5
                    -- Slides only with AutoHop: without it a press at the hook whose first update ends
                    -- the slide jumps with ducking (Half-Life's order) and not without (the test above).
                    local deg = math.random(10, 35)
                    local sliding = not ground and autoHop and r < 0.8
                    local vx, vy = math.random() * 900 - 300, math.random() * 200 - 100
                    local vz = ground and 0 or math.random() * 600 - 300
                    local slideA, slideB, floorA, floorB
                    if sliding then
                        vx, vy = 200 + math.random() * 800, 0
                        slideA, slideB = slideOn(deg, vx), slideOn(deg, vx)
                        vz = slideA.vz + math.random() * 20 - 10
                        slideA.jump = held and autoHop
                    elseif ground and math.random() < 0.3 then
                        local n = slope(-deg) -- falling away along +X
                        floorA, floorB = { nx = n.nx, ny = n.ny, nz = n.nz }, { nx = n.nx, ny = n.ny, nz = n.nz }
                    end
                    local wishes = { false, { forward = 1, right = 0 }, { forward = 0, right = 1 },
                        { forward = 1, right = -1 }, { x = 0.6, y = 0.8, speed = 200 } }
                    local wish = wishes[math.random(#wishes)] or nil
                    local dt = math.random() < 0.15 and math.random() * 0.003 or math.random() * 0.05
                    local jump = physics.wantJump(latch, held, ground, autoHop)
                    local ax, ay, az, aj, as = physics.simulate(simA, vx, vy, vz, ground, yaw, wish, jump, P, dt, rate,
                        slideA, floorA)
                    duck.frame(d, keys({ jump = held, autoHop = autoHop }))
                    local bx, by, bz, bj, bs = physics.simulate(simB, vx, vy, vz, ground, yaw, wish, false, P, dt, rate,
                        slideB, floorB, { d = d, out = {} })
                    frames = frames + 1
                    local same = ax == bx and ay == by and az == bz and aj == bj and as == bs
                        and (floorA and floorA.left) == (floorB and floorB.left)
                        and (slideA and slideA.ended) == (slideB and slideB.ended)
                    if not same then
                        diffs = diffs + 1
                        first = first or string.format("rate %d, AutoHop %s, seed %d: %.4f %.4f %.4f %s %d against "
                            .. "%.4f %.4f %.4f %s %d", rate, tostring(autoHop), seed, ax, ay, az, tostring(aj), as, bx,
                            by, bz, tostring(bj), bs)
                    end
                    seen.jumps = seen.jumps + (aj and 1 or 0)
                    seen.ends = seen.ends + (slideA and slideA.ended and 1 or 0)
                    seen.none = seen.none + (as == 0 and 1 or 0)
                    seen.leaves = seen.leaves + (floorA and floorA.left and 1 or 0)
                end
            end
        end
    end
    t.eq(frames, 32000)
    t.eq(diffs, 0, "frames that differ" .. (first and (", the first: " .. first) or ""))
    t.truthy(seen.jumps > 1000 and seen.ends > 500 and seen.none > 1000 and seen.leaves > 100, string.format(
        "the frames had jumps (%d), slides that ended (%d), no update (%d) and leaves (%d)", seen.jumps, seen.ends,
        seen.none, seen.leaves))
end)
