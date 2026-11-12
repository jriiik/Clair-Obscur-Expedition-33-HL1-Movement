-- The speedometer (F9): the horizontal speed in Half-Life units per second, as one
-- number on the screen. Runs main.lua against the fake game's UMG, as test_mod.lua does.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7, F8, F9 = 0x74, 0x75, 0x76, 0x77, 0x78
local JOURNAL = "HL1Movement.changes"
local SCALE = 2.5
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local NUMERIC_TEXT = "/Script/CommonUI.CommonNumericTextBlock"
local USER_WIDGET = "/Script/UMG.UserWidget"

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

local function units(g)
    return math.floor(g.speed() / SCALE + 0.5)
end

-- The speedometer's text and widget, on the screen.
local function theText(g)
    local w = g.viewport[1]
    local canvas = fake.props(fake.props(w).WidgetTree).RootWidget
    return fake.props(canvas).Child, w
end

t.test("F9 shows the horizontal speed in Half-Life units; F9 again takes it off the screen", function()
    local g = running()
    t.eq(#g.viewport, 0, "off by default")
    g.press(F9)
    t.eq(#g.viewport, 1, "one widget on the screen")
    t.eq(g.shownText(), "0")
    t.truthy(g.shared[JOURNAL]:find("widget", 1, true), "noted in the journal")
    runTo(g, 320 * SCALE)
    g.frames(5)
    t.eq(g.shownText(), tostring(units(g)), "the speed in u/s")
    t.eq(g.shownText(), "320")
    t.contains(g.log, "Speedometer on")
    t.contains(g.log, "Putting the speedometer on the screen (a CommonNumericTextBlock")
    g.press(F9)
    t.eq(#g.viewport, 0, "taken off the screen")
    t.contains(g.log, "Speedometer off")
    t.eq(g.shared[JOURNAL]:find("widget", 1, true), nil, "nothing left in the journal")
    noErrors(g)
end)

t.test("with Movement = false it follows the game's own speed while first person is on", function()
    local g = running({ Speedometer = true, Movement = false })
    g.keys.W = true
    g.frames(60)
    t.truthy(g.shownText() ~= nil and g.shownText() ~= "0", "the game's velocity")
    t.eq(g.shownText(), tostring(units(g)))
    noErrors(g)
end)

t.test("the speedometer is made with the settings: place, size, colour, centred, no input taken", function()
    local g = running({ Speedometer = true, SpeedometerPosition = { 0.25, 0.9 }, SpeedometerSize = 40.4,
        SpeedometerColor = { 255, 255, 255 } })
    g.frame()
    local text, w = theText(g)
    local p = fake.props(text)
    t.eq(p.Font.Size, 40)
    t.eq(p.Font.OutlineSettings.OutlineSize, 2)
    t.eq(p.Font.OutlineSettings.OutlineColor.A, 0.85, "a dark outline")
    t.near(p.SetColorAndOpacity.SpecifiedColor.G, 1, 1e-9, "white")
    t.eq(p.SetColorAndOpacity.ColorUseRule, 0, "the colour given, not the style's")
    t.eq(p.SetJustification, 1, "centred")
    t.eq(p.FormattingSpecification.UseGrouping, false, "1234, not 1,234")
    local slot = fake.props(fake.props(fake.props(w).WidgetTree).RootWidget).Slot
    local s = fake.props(slot)
    t.eq(s.Anchors.Minimum.X, 0.25)
    t.eq(s.Anchors.Maximum.Y, 0.9)
    t.eq(s.Alignment.X, 0.5, "its middle at the place")
    t.eq(s.AutoSize, true)
    t.eq(fake.props(w).Visibility, 3, "HitTestInvisible: never takes the mouse")
    t.eq(fake.props(w).ZOrder, 10)
    noErrors(g)
end)

t.test("the default colour is Half-Life's HUD orange, 255 160 0, in Unreal's linear colours", function()
    local g = running({ Speedometer = true })
    g.frame()
    local color = fake.props(theText(g)).SetColorAndOpacity.SpecifiedColor
    t.eq(color.R, 1)
    t.near(color.G, ((160 / 255 + 0.055) / 1.055) ^ 2.4, 1e-12)
    t.eq(color.B, 0)
    t.eq(color.A, 1)
end)

t.test("the number is sent only when it changes, at most 20 times a second, as a float", function()
    local g = running({ Speedometer = true })
    runTo(g, 320 * SCALE)
    g.frames(30)
    local sets = g.umg.valueSets
    g.frames(120) -- steady speed: nothing to send
    t.eq(g.umg.valueSets, sets, "no update while the number stays the same")
    -- Changing speed: hopping and turning.
    g.keys.SpaceBar = true
    g.keys.D = true
    sets = g.umg.valueSets
    g.frames(120, 1 / 120, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 120
    end)
    local perSecond = g.umg.valueSets - sets
    t.truthy(perSecond > 3, "it follows the speed")
    t.truthy(perSecond <= 21, "at most 20 a second, got " .. perSecond)
    t.eq(g.umg.ftexts, 0, "no FText made in Lua")
    noErrors(g)
end)

t.test("without CommonUI a TextBlock is used, updated at most 10 times a second", function()
    local g = running({ Speedometer = true }, { noCommonUI = true })
    runTo(g, 320 * SCALE)
    g.keys.SpaceBar = true
    g.keys.D = true
    local sets = g.umg.textSets
    g.frames(120, nil, function()
        g.rotation.Yaw = g.rotation.Yaw + 1.5 -- strafe-hopping: the speed changes all the time
    end)
    t.contains(g.log, "(a TextBlock in a UserWidget)")
    t.truthy(g.umg.textSets - sets <= 21, "at most 10 a second, got " .. g.umg.textSets - sets)
    t.truthy(g.umg.textSets - sets >= 3, "it follows the speed")
    noErrors(g)
end)

t.test("hidden while paused, in battle and without movement input; back afterwards, the same widget", function()
    local g = running({ Speedometer = true })
    g.frame()
    t.eq(g.shownText(), "0")
    local _, w = theText(g)
    local function hiddenWhile(what, set)
        set(true)
        g.frames(2)
        t.eq(g.shownText(), nil, what)
        t.eq(#g.viewport, 1, what .. ": hidden, not taken off the screen")
        set(false)
        g.frames(2)
        t.eq(g.shownText(), "0", "back after: " .. what)
    end
    hiddenWhile("paused", function(on)
        g.paused = on
    end)
    hiddenWhile("battle", function(on)
        g.inBattle = on
    end)
    hiddenWhile("the game locks the movement input", function(on)
        g.inputLocked = on -- menus, gameplay pauses
    end)
    hiddenWhile("the game ignores movement input", function(on)
        g.moveIgnored = on
    end)
    t.eq(g.viewport[1], w, "the same widget throughout: shown and hidden, not made again")
    noErrors(g)
end)

t.test("hidden while first person waits for a dialogue, a cinematic or another view target", function()
    local g = running({ Speedometer = true })
    g.frame()
    local other = fake.object({ className = "BP_SneakCamera_C" })
    local function hiddenWhile(what, set)
        set(true)
        g.frames(20) -- the game's dialogue and cinematic systems are asked every 0.25 s
        t.eq(g.shownText(), nil, what)
        set(false)
        g.frames(20)
        t.eq(g.shownText(), "0", "back after: " .. what)
    end
    hiddenWhile("dialogue", function(on)
        g.inDialogue = on
    end)
    hiddenWhile("a cinematic", function(on)
        g.inCinematic = on
    end)
    hiddenWhile("another view target", function(on)
        g.viewTarget = on and other or nil
    end)
    -- With first person off (F6) the mod doesn't look at those; only a game that takes
    -- the movement input away hides it then.
    g.press(F6)
    g.inDialogue = true
    g.frames(20)
    t.eq(g.shownText(), "0", "first person off: shown in dialogue")
    g.inputLocked = true
    g.frames(2)
    t.eq(g.shownText(), nil, "but not without movement input")
    noErrors(g)
end)

-- Makes the camera module's function `name` raise until the camera step's errors
-- have turned the step off (see guard.lua), so its clean-up runs while it still raises.
local function cameraStepTurnedOff(g, name)
    local camera = require("hl1movement.camera")
    local real = camera[name]
    camera[name] = function()
        error(name .. " failed")
    end
    g.frames(80) -- 30 errors in a row, once first person waits (asked every 0.25 s)
    camera[name] = real
    t.contains(g.log, "Turned off the first-person camera after 30 errors in a row")
end

t.test("a camera step turned off because first person couldn't be released doesn't keep the number hidden", function()
    local waits = {
        { "a dialogue", function(g, on)
            g.inDialogue = on
        end },
        { "another view target", function(g, on, other)
            g.viewTarget = on and other or nil
        end },
    }
    for _, wait in ipairs(waits) do
        local what, set = wait[1], wait[2]
        local g = running({ Speedometer = true })
        local other = fake.object({ className = "BP_SneakCamera_C" })
        runTo(g, 320 * SCALE)
        g.frames(5)
        t.eq(g.shownText(), "320", what .. ": shown before it")
        -- First person waits and is released, which fails on every frame: the step is
        -- turned off, and the release in its clean-up fails too.
        set(g, true, other)
        cameraStepTurnedOff(g, "release")
        set(g, false)
        g.frame()
        t.truthy(require("hl1movement.movement").isActive(), what .. ": the movement goes on")
        t.eq(g.shownText(), "320", what .. ": shown after it, without F5 or F7")
    end
end)

t.test("a camera step turned off before it could say why first person waits doesn't keep the number hidden", function()
    local g = running({ Speedometer = true })
    runTo(g, 320 * SCALE)
    g.inDialogue = true
    g.frames(20)
    t.eq(g.shownText(), nil, "hidden in the dialogue")
    -- The step now fails before it gets to why first person waits: its last answer,
    -- the dialogue, would stay for good.
    cameraStepTurnedOff(g, "watchBlend")
    g.inDialogue = false
    g.frame()
    t.truthy(require("hl1movement.movement").isActive(), "the movement goes on")
    t.eq(g.shownText(), "320", "shown after the dialogue, without F5 or F7")
end)

t.test("with the fallback hook it shows the game's speed, but can't hide while the game is paused", function()
    local g = running({ Speedometer = true }, { noControllerTick = true })
    local warning = t.contains(g.log, "Only the character's update could be hooked")
    t.truthy(warning:find("the speedometer stays on the screen then", 1, true), warning)
    t.truthy(warning:find("the mod's keys act once the game runs again", 1, true), warning)
    g.keys.W = true
    g.frames(60)
    t.truthy(g.shownText() ~= nil and g.shownText() ~= "0", "the game's own speed")
    t.eq(g.shownText(), tostring(units(g)))
    -- The character doesn't tick while the game is paused, so the hook doesn't run:
    -- nothing hides the number, and F9's action waits.
    local before = g.shownText()
    g.paused = true
    g.frames(60)
    t.eq(g.shownText(), before, "still on the screen, as it was")
    g.keybinds[F9]()
    g.frames(10)
    t.eq(g.shownText(), before, "F9 waits until the game runs again")
    g.paused = false
    g.frames(2)
    t.eq(#g.viewport, 0, "then F9 takes it off the screen")
    g.press(F9)
    g.frames(2)
    t.truthy(g.shownText() ~= nil, "and brings it back")
    -- What the hook does see still hides it.
    g.inBattle = true
    g.frames(2)
    t.eq(g.shownText(), nil, "battle")
    g.inBattle = false
    g.inputLocked = true
    g.frames(2)
    t.eq(g.shownText(), nil, "the game locks the movement input")
    noErrors(g)
end)

t.test("the movement and the speedometer ask the game about the movement input once a frame", function()
    local g = running({ Speedometer = true })
    g.frames(200)
    t.contains(g.log, "diagnostics (automatic", "the automatic report, which asks both too, came first")
    local asked = { IsMoveInputIgnored = 0, CanAddMovementInput = 0 }
    fake.method(g.pc, "IsMoveInputIgnored", fake.ufunction("IsMoveInputIgnored", 0, function()
        asked.IsMoveInputIgnored = asked.IsMoveInputIgnored + 1
        return false
    end))
    fake.method(g.pawn, "CanAddMovementInput", fake.ufunction("CanAddMovementInput", 0, function()
        asked.CanAddMovementInput = asked.CanAddMovementInput + 1
        return true
    end))
    g.keys.W = true
    g.frames(60)
    t.truthy(require("hl1movement.movement").isActive(), "the mod moves the character")
    t.eq(asked.IsMoveInputIgnored, 60, "IsMoveInputIgnored")
    t.eq(asked.CanAddMovementInput, 60, "CanAddMovementInput")
    fake.props(g.cmc).MovementMode = 0 -- a mantle: the movement doesn't ask, the speedometer does
    g.frames(60)
    t.eq(asked.IsMoveInputIgnored, 120, "IsMoveInputIgnored, asked by the speedometer alone")
    t.eq(asked.CanAddMovementInput, 120, "CanAddMovementInput, asked by the speedometer alone")
    t.truthy(g.shownText() ~= nil)
    noErrors(g)
end)

t.test("in movement mode None it stays, showing the game's velocity: 0 during an ALS mantle in mid-run", function()
    local g = running({ Speedometer = true })
    runTo(g, 320 * SCALE)
    g.frames(5)
    local _, w = theText(g)
    -- ALS's mantle starts with SetMovementMode(None), which stops the velocity in
    -- Unreal, and then moves the character itself, without one.
    g.cmc:SetMovementMode(0, 0)
    g.frames(10)
    t.contains(g.log, "Half-Life movement: off (the game's movement mode is 0")
    t.eq(g.shownText(), "0", "the game's own velocity, which Unreal stopped")
    -- A move of the game's in mode None that does set a velocity.
    fake.props(g.cmc).Velocity.X = 100 * SCALE
    fake.props(g.cmc).Velocity.Y = 0
    g.frames(5)
    t.eq(g.shownText(), "100", "follows the game's velocity")
    fake.props(g.cmc).MovementMode = 4 -- swimming
    g.frames(5)
    t.truthy(g.shownText() ~= nil, "swimming: shown")
    fake.props(g.cmc).MovementMode = 1
    g.frames(30)
    t.eq(g.shownText(), tostring(units(g)), "the mod's movement again")
    t.eq(g.viewport[1], w, "never hidden or made again")
    noErrors(g)
end)

t.test("switching the mod off, F7 and an area change take it off the screen; it comes back", function()
    local g = running({ Speedometer = true })
    g.frame()
    t.eq(#g.viewport, 1)
    g.press(F5)
    t.eq(#g.viewport, 0, "mod off")
    g.press(F5)
    g.frames(3)
    t.eq(#g.viewport, 1, "mod on again")
    local before = g.viewport[1]
    g.press(F7)
    t.eq(#g.viewport, 1, "settings reloaded: made again at once, with the new settings")
    t.truthy(g.viewport[1] ~= before, "a new widget")
    g.changingArea = true
    g.frame()
    t.eq(#g.viewport, 0, "area change")
    g.changingArea = false
    -- The mod's own 3 s after an area change are 180 frames: 170 are within them, 200
    -- past them. (Not SETTLE_FRAMES - 10, which is how long the tests wait before they
    -- start, and was exactly the 3 s, so that the clock's rounding decided the test.)
    g.frames(170)
    t.eq(#g.viewport, 0, "not while the game sets the character up")
    g.frames(30)
    t.eq(#g.viewport, 1)
    g.collectGarbage()
    g.frames(5)
    noErrors(g)
end)

t.test("F7 makes it again with the new look", function()
    local g = running({ Speedometer = true })
    g.frame()
    fake.useConfig({ Speedometer = true, SpeedometerSize = 64, SpeedometerPosition = { 0.5, 0.25 } })
    g.press(F7)
    local text, w = theText(g)
    t.eq(fake.props(text).Font.Size, 64)
    t.eq(fake.props(fake.props(fake.props(fake.props(w).WidgetTree).RootWidget).Slot).Anchors.Minimum.Y, 0.25)
    noErrors(g)
end)

t.test("every time the speedometer is made, the log's last line then says so: a crash there would show", function()
    local MARKER = "Putting the speedometer on the screen"
    local g = running()
    -- The last line in the log whenever a widget is made: where UE4SS.log would end
    -- if making it crashed the game.
    local library = g.statics["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local create = library.Create
    local builds, unmarked = 0, {}
    fake.method(library, "Create", function(...)
        builds = builds + 1
        if not g.log[#g.log]:find(MARKER, 1, true) then
            unmarked[#unmarked + 1] = builds .. ": " .. g.log[#g.log]
        end
        return create(...)
    end)
    g.press(F9) -- the first of the session
    g.press(F9)
    g.press(F9) -- off and on
    g.press(F7) -- the settings loaded again
    g.press(F5)
    g.press(F5) -- the mod off and on
    g.frames(3)
    g.changingArea = true -- an area change
    g.frame()
    g.changingArea = false
    g.frames(SETTLE_FRAMES + 5)
    g.useCharacter(g.buildCharacter()) -- a new character
    g.frames(SETTLE_FRAMES + 5)
    g.removeWorldWidgets() -- the game takes it off the screen
    g.frames(40)
    t.eq(builds, 7, "made 7 times")
    t.eq(#unmarked, 0, "made without the line just before: " .. table.concat(unmarked, "; "))
    t.eq(count(g.log, MARKER), 7, "one line for each")
    -- ...and a line once it is made, so the first isn't left as the log's last line
    -- for minutes when nothing else is logged (a later crash would be blamed on it).
    t.eq(count(g.log, "The speedometer is on the screen (made with WidgetBlueprintLibrary.Create)"), 7)
    for i, line in ipairs(g.log) do
        if line:find(MARKER, 1, true) then
            t.truthy(g.log[i + 1] and g.log[i + 1]:find("The speedometer is on the screen", 1, true),
                "the line after it: " .. tostring(g.log[i + 1]))
        end
    end
    noErrors(g)
end)

t.test("a build that fails has the warning after the line, not the line that says it is on the screen", function()
    local g = running({ Speedometer = true }, { addFails = true })
    g.frames(5)
    local at
    for i, line in ipairs(g.log) do
        if line:find("Putting the speedometer on the screen", 1, true) then
            at = i
        end
    end
    t.truthy(at, "the line before the build")
    t.truthy(g.log[at + 1]:find("Can't show the speedometer", 1, true), tostring(g.log[at + 1]))
    t.absent(g.log, "The speedometer is on the screen")
    noErrors(g)
end)

t.test("the line that says it is on the screen comes after the first number and the first show, not before",
    function()
        -- The number's first SetCurrentValue fails: had it crashed the game, the log
        -- would have to end with the line from before the build.
        local g = running()
        local construct = StaticConstructObject
        _G.StaticConstructObject = function(class, outer, ...)
            local made = construct(class, outer, ...)
            if class == g.statics[NUMERIC_TEXT] then
                fake.method(made, "SetCurrentValue", function()
                    error("SetCurrentValue failed")
                end)
            end
            return made
        end
        g.press(F9)
        local at
        for i, line in ipairs(g.log) do
            at = line:find("Putting the speedometer on the screen", 1, true) and i or at
        end
        t.truthy(at, "the line before the build")
        t.truthy(g.log[at + 1]:find("Error in the speedometer", 1, true), tostring(g.log[at + 1]))
        t.absent(g.log, "The speedometer is on the screen")
        g.frames(40)
        t.contains(g.log, "Turned off the speedometer after 30 errors in a row")
        t.absent(g.log, "The speedometer is on the screen")
    end)

t.test("late in a session, when little else is logged, the log doesn't end with the line from before a build",
    function()
        -- The status lines stop after 30 and the hop lines after 30. A build that worked
        -- must not leave "Putting the speedometer on the screen" as the log's last line:
        -- after a crash for any other reason, the log would read as a crash in the build.
        local MARKER = "Putting the speedometer on the screen"
        local g = running()
        -- (As in test_mod.lua: over five minutes of walking in frames of 0.1 s for the
        -- status lines, then about 38 hops for the hop lines.)
        g.keys.W = true
        g.frames(3200, 0.1)
        g.keys.SpaceBar = true
        g.frames(1500)
        t.contains(g.log, "Status (10s), the last one")
        t.contains(g.log, "(further hops aren't logged)")
        g.press(F9)
        t.eq(g.shownText() ~= nil, true, "the speedometer is on the screen")
        local lines = #g.log
        g.frames(60 * 30)
        t.eq(#g.log, lines, "nothing else was logged in the next half minute")
        t.falsy(g.log[#g.log]:find(MARKER, 1, true), "the log ends with: " .. g.log[#g.log])
        t.truthy(g.log[#g.log]:find("The speedometer is on the screen (made with ", 1, true), g.log[#g.log])
        noErrors(g)
    end)

t.test("F9 during the settle or an area change: nothing is made until the game is ready", function()
    local g = start()
    g.loadSave()
    g.frames(60) -- the game is still setting up the character
    g.press(F9)
    t.contains(g.log, "Speedometer on")
    g.frames(60)
    t.eq(g.umg.made, 0, "nothing made while the game sets up the character")
    g.frames(SETTLE_FRAMES - 120)
    t.eq(#g.viewport, 1, "on the screen once the settle is over")
    g.changingArea = true
    g.frame()
    t.eq(#g.viewport, 0, "taken off as the area change starts")
    local made = g.umg.made
    g.press(F9)
    g.press(F9)
    g.frames(30)
    t.eq(g.umg.made, made, "nothing made during the area change")
    g.press(F9) -- off
    g.changingArea = false
    g.frames(SETTLE_FRAMES + 10)
    t.eq(#g.viewport, 0, "switched off during the area change: stays off")
    g.press(F9)
    t.eq(#g.viewport, 1, "and on again")
    noErrors(g)
end)

t.test("F9 while the mod is switched off shows nothing, the log says why, and F5 brings the number", function()
    local g = running()
    g.press(F5)
    g.press(F9)
    g.frames(60)
    t.eq(#g.viewport, 0, "nothing on the screen while the mod is off")
    t.contains(g.log, "Speedometer on (it shows once the mod is on: F5)")
    g.press(F5)
    g.frames(3)
    t.eq(g.shownText(), "0", "shown once the mod is on")
    g.press(F9)
    g.press(F9)
    t.eq(count(g.log, "Speedometer on"), 2, "switched on a second time, with the mod on")
    t.eq(count(g.log, "it shows once the mod is on"), 1, "no such note while the mod is on")
    noErrors(g)
    -- A mod that starts switched off, and has no key to switch it on: the note names none.
    g = running({ StartEnabled = false, ToggleKey = false })
    g.press(F9)
    g.frames(60)
    t.eq(#g.viewport, 0, "StartEnabled = false: nothing on the screen")
    local line = t.contains(g.log, "Speedometer on (it shows once the mod is on")
    t.truthy(line:find("Speedometer on (it shows once the mod is on)", 1, true), line)
    noErrors(g)
end)

-- docs/TESTING.md (step 6) has the owner press F9 with the mod off. With the number on when
-- the mod went off, that press switches it off, so F5 then brings no number: the step's
-- sentence has to name both lines the log can get.
t.test("F9 while the mod is switched off, with the number on, switches it off: F5 brings no number, and "
    .. "docs/TESTING.md names both of the log's lines", function()
    local g = running()
    g.press(F9)
    t.eq(g.shownText(), "0", "on, with the mod on")
    g.press(F5)
    t.eq(#g.viewport, 0, "F5 takes it off the screen")
    g.press(F9)
    g.frames(60)
    t.eq(#g.viewport, 0, "nothing on the screen while the mod is off")
    t.eq(g.log[#g.log], "[HL1Movement] Speedometer off", "the log's line for that press")
    g.press(F5)
    g.frames(60)
    t.eq(#g.viewport, 0, "switched off while the mod was off: F5 brings no number")
    t.absent(g.log, "it shows once the mod is on", "no line said the number would come")
    g.press(F9)
    t.eq(g.shownText(), "0", "F9 brings it")
    noErrors(g)
    local file = assert(io.open(root .. "docs/TESTING.md", "r"))
    local text = file:read("a"):gsub("%s+", " ")
    file:close()
    local from = text:find("F9 pressed while the mod is off", 1, true)
    t.truthy(from, "docs/TESTING.md no longer has the sentence 'F9 pressed while the mod is off'")
    local to = text:find("In first person it may also go away", from, true)
    local sentence = text:sub(from, to and to - 1 or from + 400)
    for _, quoted in ipairs({ "`Speedometer on (it shows once the mod is on: F5)`", "`Speedometer off`" }) do
        t.truthy(sentence:find(quoted, 1, true), "docs/TESTING.md, on F9 with the mod off, doesn't quote "
            .. quoted .. ": " .. sentence)
    end
end)

t.test("Speedometer in config.lua is only read when the game starts: F7 keeps what F9 last chose", function()
    local g = running({ Speedometer = false })
    fake.useConfig({ Speedometer = true })
    g.press(F7)
    g.frames(30)
    t.eq(#g.viewport, 0, "true and F7: not shown")
    g.press(F9)
    t.eq(g.shownText(), "0", "F9 shows it")
    fake.useConfig({ Speedometer = false })
    g.press(F7)
    g.frames(30)
    t.eq(g.shownText(), "0", "false and F7: still shown")
    noErrors(g)
end)

t.test("F9 before a save is loaded touches nothing of the game", function()
    local g = start()
    local calls, reads, writes = fake.counts.calls, fake.counts.reads, fake.counts.writes
    g.keybinds[F9]()
    t.eq(fake.counts.calls, calls, "no game calls")
    t.eq(fake.counts.reads, reads, "no reads")
    t.eq(fake.counts.writes, writes, "no writes")
    t.contains(g.log, "Speedometer on")
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(#g.viewport, 1, "on the screen after the settle")
    noErrors(g)
end)

t.test("an unsupported character takes it off the screen; a supported one brings it back", function()
    local g = running({ Speedometer = true })
    g.frame()
    t.eq(#g.viewport, 1)
    local mapPawn = g.buildCharacter()
    fake.props(mapPawn.pawn).bIsWorldMapPawn = true
    g.useCharacter(mapPawn)
    g.frames(SETTLE_FRAMES + 5)
    t.eq(#g.viewport, 0, "a world map character")
    g.useCharacter(g.buildCharacter())
    g.frames(SETTLE_FRAMES + 5)
    t.eq(#g.viewport, 1)
    noErrors(g)
end)

t.test("a new level: the old widget is never touched, a new one is made after the settle", function()
    local g = running({ Speedometer = true })
    g.frame()
    local old = g.viewport[1]
    local newWorld = fake.object({ className = "World", name = "Level_Other", path = "/Game/Levels/Other.Level_Other" })
    g.removeWorldWidgets()
    g.collectGarbage() -- the old widget is destroyed: using it now would raise
    local used = fake.counts.destroyed -- a use through ue.call logs nothing (see below)
    local c = g.buildCharacter()
    fake.setWorld(c.pawn, newWorld)
    fake.setWorld(g.pc, newWorld)
    g.useCharacter(c)
    g.frames(SETTLE_FRAMES + 5)
    t.eq(#g.viewport, 1)
    t.truthy(g.viewport[1] ~= old, "a new widget")
    t.eq(count(g.log, "taken off the screen by the game;"), 0, "forgotten, not taken for the game's doing")
    t.eq(fake.counts.destroyed, used, "nothing freed was used")
    noErrors(g)
end)

t.test("a new level: the old level's widget isn't touched, even before it is freed", function()
    local g = running({ Speedometer = true })
    g.frame()
    local old = g.viewport[1]
    local oldName = old:GetFullName()
    local calls = {}
    for _, name in ipairs({ "RemoveFromParent", "SetVisibility", "IsInViewport" }) do
        fake.method(old, name, function()
            calls[#calls + 1] = name
        end)
    end
    local newWorld = fake.object({ className = "World", name = "Level_Other", path = "/Game/Levels/Other.Level_Other" })
    g.removeWorldWidgets() -- the engine takes the old level's widgets off the screen with it
    local c = g.buildCharacter()
    fake.setWorld(c.pawn, newWorld)
    fake.setWorld(g.pc, newWorld)
    g.useCharacter(c)
    g.frames(SETTLE_FRAMES + 5)
    t.eq(#calls, 0, "nothing called on the old widget: " .. table.concat(calls, ", "))
    t.eq(#g.viewport, 1, "a new one")
    t.falsy(g.shared[JOURNAL]:find(oldName, 1, true), "the old one is forgotten in the journal")
    t.truthy(g.shared[JOURNAL]:find(g.viewport[1]:GetFullName(), 1, true), "the new one is noted")
    noErrors(g)
end)

t.test("the game taking every widget off the screen: made again; the old one is taken off while it is still the "
    .. "mod's own, and never used once freed", function()
    local g = running({ Speedometer = true })
    g.frame()
    local old = g.viewport[1]
    g.removeWorldWidgets()
    -- Until the half-second check notices, the old widget is still the mod's own: the
    -- check asks it IsInViewport, and then it is taken off with RemoveFromParent.
    for _ = 1, 40 do -- the check is every 0.5 s
        g.frame()
        if #g.viewport > 0 then
            break
        end
    end
    t.eq(#g.viewport, 1)
    t.truthy(g.viewport[1] ~= old)
    t.eq(g.shownText(), "0", "the new one shows the number on the frame it is made")
    t.contains(g.log, "taken off the screen by the game")
    -- Once freed, the old widget is never used. The fake raises on any use of a freed
    -- object (but IsValid, GetAddress and type), before it looks at what was asked
    -- for, so recording calls on the old widget would find nothing. A direct call's
    -- error is logged as an error in the speedometer, which noErrors finds; one made
    -- through ue.call is caught there without a line, so the fake's count of such
    -- uses is checked too.
    local used = fake.counts.destroyed
    g.collectGarbage()
    g.frames(60)
    t.eq(fake.counts.destroyed, used, "nothing freed was used")
    noErrors(g)
end)

t.test("the game taking it off the screen and the garbage collection coming at once: never touched", function()
    local g = running({ Speedometer = true })
    g.keys.W = true -- the number keeps changing
    g.frame()
    g.removeWorldWidgets()
    g.collectGarbage()
    local used = fake.counts.destroyed -- a use through ue.call logs nothing (see the test before)
    g.frames(60)
    t.eq(#g.viewport, 1, "made again")
    t.eq(fake.counts.destroyed, used, "nothing freed was used")
    noErrors(g)
end)

-- The speedometer on the screen, then objects of the game at the addresses of its
-- widget, its text or both, after they were freed: their Lua objects read as valid
-- again, as in UE4SS. ("text" and "widget" alone can't happen in the game, where the
-- one keeps the other alive, but each name is checked.) Returns the game and the
-- calls those objects got.
local function reusedAddresses(which)
    local g = running({ Speedometer = true })
    g.frame()
    local text, w = theText(g)
    local otherText = StaticConstructObject(g.statics[NUMERIC_TEXT], g.gameInstance)
    local otherWidget = StaticConstructObject(g.statics[USER_WIDGET], g.gameInstance)
    local calls = {}
    for obj, names in pairs({ [otherText] = { "SetCurrentValue", "SetText", "SetVisibility" },
        [otherWidget] = { "SetVisibility", "IsInViewport", "RemoveFromParent", "AddToViewport" } }) do
        for _, name in ipairs(names) do
            fake.method(obj, name, function()
                calls[#calls + 1] = name
                return false
            end)
        end
    end
    if which == "both" then
        g.removeWorldWidgets()
        g.collectGarbage()
    elseif which == "widget" then
        g.removeWorldWidgets()
        fake.destroy(w)
    else
        fake.destroy(text)
    end
    if which ~= "text" then
        fake.reuseAddress(w, otherWidget)
    end
    if which ~= "widget" then
        fake.reuseAddress(text, otherText)
    end
    return g, calls
end

t.test("a freed widget or text whose address another object took, reading as valid, is never called", function()
    local cases = {
        ["the number changes"] = function(g)
            g.keys.W = true
            g.frames(30)
        end,
        ["the number is hidden"] = function(g)
            g.paused = true
            g.frames(2)
            g.paused = false
            g.frames(2)
        end,
        ["the half-second check"] = function(g)
            g.frames(40)
        end,
        ["F9 takes it off the screen"] = function(g)
            g.press(F9)
        end,
    }
    for _, which in ipairs({ "both", "text", "widget" }) do
        for what, case in pairs(cases) do
            local label = which .. ", " .. what
            local g, calls = reusedAddresses(which)
            case(g)
            t.eq(#calls, 0, label .. ": called " .. table.concat(calls, ", "))
            if what == "F9 takes it off the screen" then
                t.eq(#g.viewport, 0, label .. ": nothing left on the screen")
            else
                t.eq(#g.viewport, 1, label .. ": a new speedometer, and only that one")
                t.eq(g.shownText(), tostring(units(g)), label .. ": the new one shows the speed")
            end
            noErrors(g)
        end
    end
end)

t.test("the game taking it away again and again: made again 5 times, then one warning; F9 tries again", function()
    local g = running({ Speedometer = true })
    g.frame()
    for _ = 1, 8 do
        g.removeWorldWidgets()
        g.frames(31) -- the check is every 0.5 s
    end
    t.eq(count(g.log, "taken off the screen by the game; it is made again"), 3, "3 lines at most")
    t.eq(count(g.log, "Can't show the speedometer: the game keeps taking it off the screen"), 1)
    t.eq(#g.viewport, 0, "not made again")
    t.eq(g.umg.made, 6 * 5, "the first and 5 more, 5 objects each")
    g.press(F9)
    g.press(F9)
    t.eq(#g.viewport, 1, "F9 tries again")
    g.removeWorldWidgets()
    g.frames(31)
    t.eq(#g.viewport, 1, "and counts again from 0")
    noErrors(g)
end)

t.test("the game taking it away now and then, as each battle or menu opens: made again every time", function()
    local g = running({ Speedometer = true })
    g.frame()
    for n = 1, 8 do
        if n % 2 == 1 then
            g.inBattle = true -- the number is hidden: the loss is found when it should show again
        else
            g.paused = true
        end
        g.removeWorldWidgets() -- the game clears the screen, the mod's widget with its own
        g.frames(60)
        g.collectGarbage()
        g.frames(60)
        g.inBattle, g.paused = false, false
        g.frames(11 * 60) -- 11 s of play
        t.eq(g.shownText(), "0", "shown after removal " .. n)
    end
    t.eq(g.umg.made, 9 * 5, "the first and 8 more, 5 objects each")
    t.absent(g.log, "Can't show the speedometer")
    t.eq(count(g.log, "taken off the screen by the game; it is made again"), 3, "3 lines at most")
    g.press(F8)
    t.contains(g.log, "taken off the screen by the game 8 times")
    -- Taken away soon after each making, five times in a row, still ends it.
    for _ = 1, 6 do
        g.removeWorldWidgets()
        g.frames(9 * 60) -- under 10 s each
    end
    t.eq(count(g.log, "Can't show the speedometer: the game keeps taking it off the screen"), 1)
    t.eq(#g.viewport, 0, "not made again")
    noErrors(g)
end)

t.test("a failing speedometer is turned off alone and taken off the screen; F5 twice brings it back", function()
    local g = running({ Speedometer = true })
    g.keys.W = true
    g.frames(30)
    t.truthy(g.shownText() ~= nil, "shown")
    fake.method(theText(g), "SetCurrentValue", function()
        error("SetCurrentValue failed")
    end)
    g.keys.SpaceBar = true -- hopping and turning: the number keeps changing
    g.keys.D = true
    g.frames(240, nil, function()
        g.rotation.Yaw = g.rotation.Yaw + 1.5
    end)
    t.contains(g.log, "Error in the speedometer: ")
    t.contains(g.log, "Turned off the speedometer after 30 errors in a row")
    t.eq(#g.viewport, 0, "taken off the screen: no number that stands still")
    t.falsy(g.shared[JOURNAL]:find("widget", 1, true), "and nothing left in the journal")
    t.absent(g.log, "Turned off the Half-Life movement")
    t.absent(g.log, "Turned off the first-person camera")
    t.absent(g.log, "Error in the mod's frame update")
    t.truthy(require("hl1movement.movement").isActive(), "the movement goes on")
    t.truthy(require("hl1movement.camera").isActive(), "and first person")
    t.truthy(g.speed() > 320 * SCALE, "air strafing still gains speed")
    g.press(F9)
    g.press(F9)
    t.eq(#g.viewport, 0, "F9 doesn't turn the step back on: the log says F5 twice")
    g.press(F5)
    g.press(F5)
    g.frames(3)
    t.eq(#g.viewport, 1, "F5 twice does: a new widget")
    t.truthy(g.shownText() ~= nil, "which shows a number again")
end)

t.test("UE4SS restarting its mods: the new copy takes the old speedometer off the screen", function()
    local g = running({ Speedometer = true })
    g.frame()
    local old = g.viewport[1]
    t.truthy(g.shared[JOURNAL]:find("widget", 1, true), "noted")
    g.restartMods(root)
    g.frame()
    t.eq(#g.viewport, 0, "the old copy's widget is gone")
    t.contains(g.log, "Put back")
    g.frames(SETTLE_FRAMES + 5)
    t.eq(#g.viewport, 1, "the new copy makes its own")
    t.truthy(g.viewport[1] ~= old)
    noErrors(g)
end)

t.test("CreateWidget failing: the widget is made with StaticConstructObject instead", function()
    local g = running({ Speedometer = true }, { createFails = true })
    g.frame()
    t.eq(#g.viewport, 1)
    t.eq(g.shownText(), "0")
    g.press(F8)
    t.contains(g.log, "made 1 times (the last with StaticConstructObject, a CommonNumericTextBlock)")
    noErrors(g)
end)

t.test("a speedometer that can't be made: one warning, the movement goes on, F9 tries again", function()
    local g = start({ Speedometer = true }, { createFails = true, noCommonUI = true })
    g.statics["/Script/UMG.TextBlock"] = nil
    g.loadSave()
    g.frames(SETTLE_FRAMES + 30)
    t.eq(count(g.log, "Can't show the speedometer"), 1, "once")
    runTo(g, 320 * SCALE)
    g.press(F8)
    local line = t.contains(g.log, "Speedometer: wanted=true, on the screen=false, shown=false, number=nil u/s, "
        .. "made 0 times, taken off the screen by the game 0 times, can't be shown: the game has no text widget class")
    t.falsy(line:find("TextBlock", 1, true), "no text widget named after a failed build")
    g.press(F9)
    g.press(F9)
    t.eq(count(g.log, "Can't show the speedometer"), 2, "tried again")
    g.press(F5)
    g.press(F5)
    t.eq(count(g.log, "Can't show the speedometer"), 3, "F5 twice tries again too")
    g.press(F7)
    t.eq(count(g.log, "Can't show the speedometer"), 4, "and F7")
    g.press(F6)
    g.press(F6)
    g.frames(40)
    t.eq(count(g.log, "Can't show the speedometer"), 4, "F6 twice doesn't: it is the camera's key")
    g.changingArea = true
    g.frame()
    g.changingArea = false
    g.frames(SETTLE_FRAMES + 5)
    t.eq(count(g.log, "Can't show the speedometer"), 4, "nor an area change that keeps the character")
    g.useCharacter(g.buildCharacter())
    g.frames(SETTLE_FRAMES + 5)
    t.eq(count(g.log, "Can't show the speedometer"), 5, "a new character tries again")
    noErrors(g)
end)

t.test("without CommonUI and without UE4SS's FText, it can't be made, and says why", function()
    local g = running({ Speedometer = true }, { noCommonUI = true, noFText = true })
    g.frames(5)
    t.contains(g.log, "Can't show the speedometer: the game has no /Script/CommonUI.CommonNumericTextBlock, "
        .. "and this UE4SS can't make text for a TextBlock")
    t.eq(#g.viewport, 0)
    noErrors(g)
end)

t.test("a widget the game doesn't put on the screen: one warning, not made again every 0.5 s", function()
    local g = running({ Speedometer = true }, { addFails = true })
    local made = g.umg.made
    g.frames(600)
    t.contains(g.log, "Can't show the speedometer: the game didn't put it on the screen")
    t.eq(g.umg.made, made, "not made again")
    t.absent(g.log, "taken off the screen by the game; it is made again", "the game isn't blamed")
    noErrors(g)
end)

t.test("a look the game's engine doesn't take is lost alone: the speedometer still shows", function()
    local g = running({ Speedometer = true }, { textWithoutOutline = true })
    g.frame()
    t.eq(count(g.log, "The speedometer can't take its outline"), 1)
    t.eq(g.shownText(), "0")
    local p = fake.props(theText(g))
    t.eq(p.Font.Size, 32, "the size, before the outline")
    t.eq(p.SetJustification, 1, "the centring, after it")
    noErrors(g)
end)

t.test("a number that can't be hidden is taken off the screen", function()
    local g = running({ Speedometer = true })
    g.frame()
    local _, w = theText(g)
    fake.method(w, "SetVisibility", function()
        error("SetVisibility failed")
    end)
    g.paused = true
    g.frame()
    t.eq(#g.viewport, 0, "taken off while it should be hidden")
    g.paused = false
    g.frames(2)
    t.eq(g.shownText(), "0", "a new one afterwards")
    noErrors(g)
end)

t.test("a speed that isn't a number shows 0, and a huge one 99999", function()
    for _, case in ipairs({ { 0 / 0, "0" }, { math.huge, "0" }, { 1e9, "99999" } }) do
        local g = running({ Speedometer = true, Movement = false, FirstPerson = false }, { noCommonUI = true })
        g.frame()
        local sets = g.umg.textSets
        local v = fake.props(g.cmc).Velocity
        g.frames(30, nil, function()
            v.X, v.Y = case[1], 0 -- as the game's movement left it
        end)
        t.eq(g.shownText(), case[2], tostring(case[1]))
        t.truthy(g.umg.textSets - sets <= 1, tostring(case[1]) .. ": sent once")
        noErrors(g)
    end
end)

-- At 20 fps every frame's number is sent: NUMBER_INTERVAL is 0.05 s.
local function shownEachFrame(g, frames, each)
    local shown = {}
    g.frames(frames, 1 / 20, function(i)
        if each then
            each(i)
        end
        shown[#shown + 1] = g.shownText()
    end)
    shown[#shown + 1] = g.shownText()
    return shown
end

t.test("a speed cut the mod undoes doesn't show: the number is the speed it kept", function()
    local g = running({ Speedometer = true }, { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true })
    runTo(g, 320 * SCALE)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    local shown = shownEachFrame(g, 200, function()
        g.rotation.Yaw = g.rotation.Yaw + 72 / 20
    end)
    t.contains(g.log, "The game cut the speed from ", "the game's speed limiter cut the speed")
    t.truthy(g.speed() > 290 * SCALE, "air strafing gained speed")
    local cut = 0
    for _, text in ipairs(shown) do
        if text == "260" then -- the speed limiter's cap
            cut = cut + 1
        end
    end
    t.eq(cut, 0, "the cut speed was never shown")
    noErrors(g)
end)

t.test("hopping in place on a moving platform, a landing shows the speed on the platform, as walking does", function()
    local g = running({ Speedometer = true })
    g.baseVelocity = { X = 200, Y = 0, Z = 0 } -- 80 u/s
    g.frames(3)
    t.eq(g.shownText(), "0", "standing on it")
    g.keys.SpaceBar = true
    local shown = shownEachFrame(g, 100)
    local counts = {}
    for _, text in ipairs(shown) do
        counts[text] = (counts[text] or 0) + 1
    end
    t.truthy((counts["80"] or 0) > 50, "in the air: the speed over the ground, with the platform's")
    t.truthy((counts["0"] or 0) >= 3, "at each landing: relative to the platform, which carries the character on")
    noErrors(g)
end)

t.test("pressed against a wall it shows 0, as Half-Life does, and sends nothing", function()
    for _, fps in ipairs({ 30, 60, 144 }) do
        local g = running({ Speedometer = true })
        runTo(g, 320 * SCALE)
        g.moveShare = 0 -- a wall straight ahead
        g.frames(fps, 1 / fps)
        local sets = g.umg.valueSets
        local shown = {}
        g.frames(fps, 1 / fps, function()
            shown[g.shownText() or "nil"] = true
        end)
        t.eq(next(shown), "0", fps .. " fps: shows 0")
        t.eq(next(shown, "0"), nil, fps .. " fps: nothing else")
        t.eq(g.umg.valueSets, sets, fps .. " fps: no updates")
        noErrors(g)
    end
end)

t.test("the report says what the speedometer does", function()
    local g = running({ Speedometer = true })
    runTo(g, 320 * SCALE)
    g.frames(5)
    g.press(F8)
    t.contains(g.log, "Speedometer: wanted=true, on the screen=true, shown=true, number=320 u/s, made 1 times "
        .. "(the last with WidgetBlueprintLibrary.Create, a CommonNumericTextBlock), taken off the screen by the "
        .. "game 0 times")
    t.contains(g.log, "Controller.MyHUD = ")
    -- Taken away just after one of the mod's half-second checks of the widget: one on
    -- the report's frame would find it gone and make it again before the report.
    local widget, checks = g.viewport[1], 0
    local isInViewport = widget.IsInViewport
    fake.method(widget, "IsInViewport", function(...)
        checks = checks + 1
        return isInViewport(...)
    end)
    for _ = 1, 40 do
        if checks > 0 then
            break
        end
        g.frame()
    end
    t.eq(checks, 1, "the mod checks its widget every half second")
    g.removeWorldWidgets()
    g.press(F8)
    t.contains(g.log, "Speedometer: wanted=true, on the screen=false", "IsInViewport, not the mod's guess")
    noErrors(g)
end)

t.test("bad speedometer settings are reported, and out-of-range ones clamped with a warning", function()
    local g = start({ SpeedometerPosition = { 2 }, SpeedometerColor = "red", SpeedometerSize = 1000 })
    t.contains(g.log, "SpeedometerPosition = { 2 } must be a list of 2 numbers from 0 to 1; using the default, "
        .. "{ 0.5, 0.75 }")
    t.contains(g.log, 'SpeedometerColor = "red" must be a list of 3 numbers from 0 to 255; using the default, '
        .. "{ 255, 160, 0 }")
    t.contains(g.log, "SpeedometerSize = 1000: lowered to the highest allowed value, 200")
    g = running({ Speedometer = true, SpeedometerPosition = { -1, 1.5 }, SpeedometerColor = { 300, 0, 0 / 0 } })
    t.contains(g.log, "SpeedometerPosition = { -1, 1.5 }: entry 1 raised to the lowest allowed value, 0; entry 2 "
        .. "lowered to the highest allowed value, 1")
    t.contains(g.log, "SpeedometerColor = { 300, 0, ")
    g.frame()
    local s = fake.props(fake.props(fake.props(fake.props(g.viewport[1]).WidgetTree).RootWidget).Slot)
    t.eq(s.Anchors.Minimum.X, 0, "clamped")
    t.eq(s.Anchors.Minimum.Y, 1, "clamped")
    t.eq(fake.props(theText(g)).SetColorAndOpacity.SpecifiedColor.R, 1, "the default colour")
    noErrors(g)
end)
