-- Tests for the keys: settings.lua's key lists (the rule kind "keys"), input.lua's reading of
-- the duck, duck tap and jump keys (input.buttons, input.ignoreHeld, input.lastPolls) and
-- keys.lua (the keys taken from the game while the mod moves the character, the hand-back
-- guard, the fall-backs, the journal's restorer, the hotkeys with modifiers), against the fake
-- game with tests/fake_input.lua. main.lua calls these in this order (see keysStep and
-- movementStep); drive, a small frame hook here, runs them the same way, so that each rule
-- shows on its own. test_duck_mod.lua has them through main.lua.
-- Each test's comment names the broken rules it was seen to fail with.

local t = require("testlib")
local fake = require("fake_game")
local settings = require("hl1movement.settings")

local F5 = 0x74
-- UE4SS's Key table, as far as these tests need it (settings.load checks the hotkeys with it).
local KEY_TABLE = { F5 = 0x74, F6 = 0x75, F7 = 0x76, F8 = 0x77, F9 = 0x78, HOME = 0x24, NUM_ZERO = 0x60 }
local DEFAULT_TAKEN = "LeftControl, MouseScrollDown, LeftShift, SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom"

local function list(values)
    return table.concat(values, ", ")
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

-- Fresh copies of the mod's modules, each test's own, required after fake.newGame so that
-- their log goes to that game.
local function modules()
    for name in pairs(package.loaded) do
        if name:match("^hl1movement%.") then
            package.loaded[name] = nil
        end
    end
    return { settings = require("hl1movement.settings"), input = require("hl1movement.input"),
        keys = require("hl1movement.keys"), journal = require("hl1movement.journal"),
        log = require("hl1movement.log") }
end

-- A game, the modules, and the settings from user (a config.lua table).
local function game(user, options)
    local g = fake.newGame(options)
    local m = modules()
    local cfg, warnings = m.settings.load(user, KEY_TABLE)
    return g, m, cfg, warnings
end

-- Runs the keys as main.lua's frame hook is to run them: keys.watch first (also with
-- the mod off); keys.validate on the first frame the mod acts; then a blocker or a pause
-- gives the keys back; at a take-over and when the game stops showing something the duck keys
-- held are ignored; the buttons are read (owned unless the game shows something); then
-- keys.take, or keys.give while the game shows something. d.off: the mod is off; d.blocked:
-- why the mod lets go ("battle" ...); d.shows: what the game shows; d.wiped: the duck state's
-- wipe; d.k: this frame's buttons.
local function drive(g, m, cfg)
    -- keyCalls, keyNames: the game calls and full names keys.watch, take and give made.
    local d = { frame = 0, now = 0, takeOver = true, keyCalls = 0, keyNames = 0 }
    local function counted(fn, ...)
        local calls, names = fake.counts.calls, fake.counts.fullNames
        fn(...)
        d.keyCalls = d.keyCalls + fake.counts.calls - calls
        d.keyNames = d.keyNames + fake.counts.fullNames - names
    end
    g.functions[g.tickPath] = true
    g.hooks[g.tickPath] = function(_, dtParam)
        local dt = dtParam:get()
        d.frame, d.now = d.frame + 1, d.now + dt
        local pc = g.pc
        counted(m.keys.watch, pc, d.now)
        if d.off then
            d.takeOver = true
            return
        end
        if not d.validated then
            d.validated = true
            m.keys.validate(pc, cfg)
        end
        local why = d.blocked or (g.paused and "paused") or nil
        if why then
            counted(m.keys.give, pc, why)
            if why ~= "paused" then
                d.takeOver = true
            end
            return
        end
        if d.takeOver then
            d.takeOver, d.showing = false, false
            m.input.ignoreHeld(pc, cfg)
        end
        local owned = d.shows == nil
        if owned and d.showing then
            m.input.ignoreHeld(pc, cfg)
        end
        d.showing = not owned
        d.k = m.input.buttons(pc, cfg, d.frame, dt, owned, d.wiped)
        if owned then
            counted(m.keys.take, pc, m.input.lastPolls(d.frame), cfg)
        else
            counted(m.keys.give, pc, d.shows)
        end
    end
    return d
end

-- The mod's own contexts applied now, as "priority: keys".
local function modContexts(g)
    local result = {}
    for _, entry in ipairs(g.input.applied()) do
        if entry.mine then
            local keys = {}
            for _, m in ipairs(g.input.mappings()) do
                if m.action == "mod" then
                    keys[#keys + 1] = m.key
                end
            end
            result[#result + 1] = entry.priority .. ": " .. list(keys)
        end
    end
    return list(result)
end

-- Records every poll of the mod's (how and key), after fake_input's own point.
local function pollRecorder()
    local asked = {}
    local ext = { poll = function(_, how, name, value)
        asked[#asked + 1] = how .. " " .. name
        return value
    end }
    return ext, asked
end

-- The fake's input (tests/fake_input.lua): the models the tests below rely on ------------------

t.test("the fake's input makes no object until Enhanced Input is looked up, so a game that doesn't use it has the "
    .. "addresses of a game without it", function()
    -- Fails if: fake_input makes its objects at install (every later object's address, and with
    -- it its name in the log, would differ from the fake's without the file: H0's rule).
    fake.newGame({ noExtensionModules = true }) -- (the classes the fake makes once a run)
    local function made(options)
        local before = fake.addressOf(fake.object({ className = "Marker" }))
        local g = fake.newGame(options)
        return fake.addressOf(fake.object({ className = "Marker" })) - before, g
    end
    local without = made({ noExtensionModules = true })
    local with, g = made(nil)
    t.eq(with, without, "as many objects made by a game with fake_input as without")
    t.truthy(g.input and not g.input.built)
    t.truthy(StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):IsValid(), "made at the lookup")
    t.truthy(g.input.built)
end)

t.test("the fake's input: a mapping that goes while its key is held sends no release, and one that comes back under "
    .. "a held key does nothing until the key is let go, unless the engine loses that flag", function()
    -- What the tests below rely on. Fails if: a release is sent for a mapping that went (the mod's
    -- take of a held key would look harmless); the ignore option ignored; the switch ignored.
    local g = fake.newGame({ battleRemovesLocomotion = true })
    local pawn = fake.props(g.pawn)
    g.keys.LeftShift = true
    g.frame()
    t.eq(pawn.DesiredGait, 2, "running")
    g.inBattle = true
    g.frame() -- the game takes its context away: SprintAction's mapping goes under the held key
    g.keys.LeftShift = false
    g.frame()
    t.eq(pawn.DesiredGait, 2, "no release came")
    g.inBattle = false
    g.keys.LeftControl = true
    g.frame() -- the context back, with Ctrl held: ignored until let go (ALS's options)
    t.eq(g.input.fired.WalkAction, nil)
    g.keys.LeftControl = false
    g.frame()
    g.keys.LeftControl = true
    g.frame()
    t.eq(g.input.fired.WalkAction, 1, "a new press acts")
    -- An engine that loses the flag: the mapping that comes back acts on the held key.
    local lost = fake.newGame({ battleRemovesLocomotion = true, inputLosesIgnoreFlag = true })
    lost.inBattle = true
    lost.frame()
    lost.keys.LeftControl = true
    lost.frame()
    lost.inBattle = false
    lost.frame()
    t.eq(lost.input.fired.WalkAction, 1, "acted at once")
    -- The game's jump: Space held as its mapping goes, no release event, and none when let go.
    local jumps = fake.newGame({ battleRemovesLocomotion = true })
    jumps.keys.SpaceBar = true
    jumps.frame()
    t.eq(jumps.jumpWasDown, true)
    jumps.inBattle = true
    jumps.frame()
    t.eq(jumps.jumpWasDown, false, "the mapping went without a release")
end)

t.test("the fake's input: UE4SS's key binds fire only with exactly their modifiers held, or with fireEveryBind every "
    .. "bind whose modifiers are held; key names are read without case", function()
    local g = fake.newGame()
    local fired = {}
    local CONTROL = rawget(_G, "ModifierKey").CONTROL
    RegisterKeyBind(F5, function()
        fired[#fired + 1] = "plain"
    end)
    RegisterKeyBind(F5, { CONTROL }, function()
        fired[#fired + 1] = "ctrl"
    end)
    g.press(F5, { "CONTROL", "SHIFT" })
    g.press(F5, { "CONTROL" })
    g.press(F5)
    t.eq(list(fired), "ctrl, plain")
    local every = fake.newGame({ fireEveryBind = true })
    fired = {}
    RegisterKeyBind(F5, function()
        fired[#fired + 1] = "plain"
    end)
    RegisterKeyBind(F5, { CONTROL }, function()
        fired[#fired + 1] = "ctrl"
    end)
    every.press(F5, { "CONTROL", "SHIFT" })
    t.eq(list(fired), "plain, ctrl")
    every.keys.LeftControl = true
    t.eq(every.pc:IsInputKeyDown({ KeyName = FName("leftcontrol") }), true, "FNames compare without case")
    t.eq(rawget(_G, "ModifierKey").CONTROL, 0x11)
    fake.newGame({ noModifierKey = true })
    t.eq(rawget(_G, "ModifierKey"), nil, "cleared in a game without it")
end)

-- Settings: the key lists ------------------------------------------------------------------

t.test("a key list takes Half-Life's names in any case: CTRL is either Ctrl key, MWHEELDOWN the wheel, mouse4 "
    .. "a mouse button, a digit its key; each is noted", function()
    -- Fails if: the aliases are looked up with their case; CTRL is LeftControl alone (as in
    -- Half-Life, CTRL is either key); the note is left out.
    local cfg, warnings = settings.load({ DuckKeys = { "ctrl", "MWHEELDOWN" }, DuckTapKeys = { "lshift" },
        JumpKeys = { "SPACE", "mouse4", "MOUSE5", "1" }, ForwardKeys = { "uparrow" } }, KEY_TABLE)
    t.eq(list(cfg.DuckKeys), "LeftControl, RightControl, MouseScrollDown")
    t.eq(list(cfg.DuckTapKeys), "LeftShift")
    t.eq(list(cfg.JumpKeys), "SpaceBar, ThumbMouseButton, ThumbMouseButton2, One")
    t.eq(list(cfg.ForwardKeys), "Up")
    t.contains(warnings, 'DuckKeys = { "ctrl", "MWHEELDOWN" }: ctrl is read as LeftControl and RightControl; '
        .. "MWHEELDOWN is read as MouseScrollDown")
    t.contains(warnings, 'JumpKeys = { "SPACE", "mouse4", "MOUSE5", "1" }: SPACE is read as SpaceBar; mouse4 is read '
        .. "as ThumbMouseButton; MOUSE5 is read as ThumbMouseButton2; 1 is read as One")
    t.eq(#warnings, 4, "a note for each list with an alias, nothing else")
end)

t.test("a name that is Unreal's but for case takes Unreal's spelling, and a name twice in one list is kept once, "
    .. "both silently", function()
    -- Fails if: names are compared with their case; duplicates are kept or warned about.
    local cfg, warnings = settings.load({ DuckKeys = { "leftcontrol", "LEFTCONTROL", "CTRL", "mousescrolldown" },
        JumpKeys = { "spacebar", "gamepad_facebutton_bottom", "SpaceBar" } }, KEY_TABLE)
    t.eq(list(cfg.DuckKeys), "LeftControl, RightControl, MouseScrollDown")
    t.eq(list(cfg.JumpKeys), "SpaceBar, Gamepad_FaceButton_Bottom")
    t.eq(#warnings, 1, "only CTRL's note")
    t.contains(warnings, "CTRL is read as LeftControl and RightControl")
end)

t.test("a key name the mod doesn't know is kept, with a warning that suggests the known name closest to it", function()
    -- Fails if: an unknown name is dropped (the list can't hold every key: the game's word on it
    -- comes from keys.validate); no suggestion; a suggestion where nothing is close.
    local cfg, warnings = settings.load({ DuckKeys = { "LeftCtrl" }, JumpKeys = { "Spacebr", "Foo" } }, KEY_TABLE)
    t.eq(list(cfg.DuckKeys), "LeftCtrl", "kept as it is")
    t.eq(list(cfg.JumpKeys), "Spacebr, Foo")
    t.contains(warnings, 'DuckKeys: "LeftCtrl" is not a key name the mod knows (did you mean LeftControl?). It is used '
        .. "as it is; if it is wrong it never reads as pressed")
    t.contains(warnings, 'JumpKeys: "Spacebr" is not a key name the mod knows (did you mean SpaceBar?)')
    t.contains(warnings, 'JumpKeys: "Foo" is not a key name the mod knows. It is used as it is')
    t.eq(#warnings, 3)
    for name, expected in pairs({ LeftCtrl = "LeftControl", Control = "LeftControl", Spacebr = "SpaceBar",
        MouseWheelUp = "MouseScrollUp", Gamepad_FaceButton_Botom = "Gamepad_FaceButton_Bottom",
        ThumbMouseButon = "ThumbMouseButton" }) do
        t.eq(settings.suggestKey(name), expected, "the suggestion for " .. name)
    end
    t.eq(settings.suggestKey("Foo"), nil, "nothing close to Foo")
    t.eq(settings.suggestKey("xyzzy"), nil)
    t.truthy(settings.suggestKey("Escapee") ~= "Escape", "never Escape, which a list can't hold")
end)

t.test("Escape, the mod's own hotkeys, axes and a wheel in DuckTapKeys are left out of the key lists, each with a "
    .. "warning", function()
    -- Fails if: Escape is kept (it opens the game's menu); a hotkey is kept (F5 would switch the
    -- mod off and duck); an axis is kept; a wheel in DuckTapKeys is kept (+ducktap does nothing on a
    -- notch); the hotkeys' UE4SS names (HOME, NUM_ZERO) aren't matched with Unreal's.
    local cfg, warnings = settings.load({ JumpKeys = { "SpaceBar", "escape", "F5", "MouseX", "Gamepad_RightX" },
        DuckTapKeys = { "LeftShift", "MWHEELUP", "MouseScrollDown" }, CameraKey = "HOME", DiagnosticsKey = "NUM_ZERO",
        ForwardKeys = { "W", "home" }, LeftKeys = { "A", "NumPadZero" } }, KEY_TABLE)
    t.eq(list(cfg.JumpKeys), "SpaceBar")
    t.eq(list(cfg.DuckTapKeys), "LeftShift")
    t.eq(list(cfg.ForwardKeys), "W")
    t.eq(list(cfg.LeftKeys), "A")
    t.contains(warnings, "JumpKeys: \"Escape\" is left out: Escape opens the game's menu")
    t.contains(warnings, "JumpKeys: \"F5\" is left out: it is the mod's ToggleKey")
    t.contains(warnings, 'JumpKeys: "MouseX" is left out: it is an axis (a mouse or stick movement), not a key that '
        .. "can be held")
    t.contains(warnings, 'JumpKeys: "Gamepad_RightX" is left out: it is an axis')
    t.contains(warnings, 'DuckTapKeys: "MouseScrollUp" is left out: +ducktap does nothing on a wheel notch: it is over '
        .. "before the next update, as in OpenAG; put it in DuckKeys for a duck tap by hand")
    t.contains(warnings, 'DuckTapKeys: "MouseScrollDown" is left out: +ducktap does nothing on a wheel notch')
    t.contains(warnings, "ForwardKeys: \"Home\" is left out: it is the mod's CameraKey")
    t.contains(warnings, "LeftKeys: \"NumPadZero\" is left out: it is the mod's DiagnosticsKey")
end)

t.test("a key in two of the lists is named in a warning and kept in both; not for the duck lists with "
    .. "Ducking = false", function()
    -- Fails if: no warning (an old config.lua with the wheel down in JumpKeys, as 0.3's advised);
    -- the key dropped from one list; the duck lists counted with Ducking = false.
    local cfg, warnings = settings.load({ JumpKeys = { "SpaceBar", "MouseScrollDown" } }, KEY_TABLE)
    t.eq(#warnings, 1)
    t.contains(warnings, "MouseScrollDown is in DuckKeys and JumpKeys: it does both")
    t.eq(list(cfg.DuckKeys), "LeftControl, MouseScrollDown")
    t.eq(list(cfg.JumpKeys), "SpaceBar, MouseScrollDown")
    local _, three = settings.load({ DuckKeys = { "Q" }, DuckTapKeys = { "q" }, JumpKeys = { "Q" } }, KEY_TABLE)
    t.contains(three, "Q is in DuckKeys, DuckTapKeys and JumpKeys: it does all of them")
    local _, moving = settings.load({ DuckTapKeys = { "W" } }, KEY_TABLE)
    t.contains(moving, "W is in DuckTapKeys and ForwardKeys: it does both", "the movement lists too")
    local _, off = settings.load({ Ducking = false, JumpKeys = { "SpaceBar", "MouseScrollDown" } }, KEY_TABLE)
    t.eq(#off, 0, "the duck keys aren't read with Ducking = false")
end)

t.test("a key list that isn't a list keeps its default, and entries that aren't names are counted", function()
    local cfg, warnings = settings.load({ DuckKeys = "LeftControl", DuckTapKeys = { "LeftShift", 4, false } },
        KEY_TABLE)
    t.eq(list(cfg.DuckKeys), "LeftControl, MouseScrollDown")
    t.contains(warnings, 'DuckKeys = "LeftControl" must be a list such as { "SpaceBar" }; using the default')
    t.contains(warnings, 'DuckTapKeys = { "LeftShift", 4, "false" }: ignored 2 entries that are not a name')
    t.eq(list(cfg.DuckTapKeys), "LeftShift")
end)

-- The shipped config.lua, read as main.lua reads it (see test_settings.lua).
local function shippedConfig()
    local file = assert(io.open(TEST_ROOT .. "HL1Movement/Scripts/config.lua", "rb"))
    local text = file:read("a"):gsub("^\239\187\191", "")
    file:close()
    local env, unknown = settings.environment(_G)
    return assert(load(text, "@config.lua", "t", env))(), unknown
end

t.test("the shipped config.lua lists the new settings at their defaults, the key lists element by element, and "
    .. "loads without a warning", function()
    -- Fails if: a key list in config.lua differs from settings.DEFAULTS (test_settings.lua's check
    -- compares only values that aren't lists); a new setting is missing from the file.
    local user, unknown = shippedConfig()
    local cfg, warnings = settings.load(user, KEY_TABLE, unknown)
    t.eq(#warnings, 0, "warnings: " .. table.concat(warnings, " | "))
    for _, name in ipairs(settings.KEY_LISTS) do
        t.eq(list(user[name] or {}), list(settings.DEFAULTS[name]), "config.lua's " .. name)
        t.eq(list(cfg[name]), list(settings.DEFAULTS[name]), name .. " as loaded")
    end
    for _, name in ipairs({ "Ducking", "DuckHull", "TakeKeys", "TakeJumpKeys" }) do
        t.eq(user[name], true, "config.lua sets " .. name)
        t.eq(settings.DEFAULTS[name], true)
    end
    t.eq(list(settings.DEFAULTS.DuckKeys), "LeftControl, MouseScrollDown")
    t.eq(list(settings.DEFAULTS.DuckTapKeys), "LeftShift")
    t.eq(list(settings.DEFAULTS.JumpKeys), "SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom")
end)

t.test("settings.physics has the duck's distances in centimetres: 18 units, the lift's 18 and 16 1/32", function()
    local P = settings.physics(settings.load({ UnitScale = 2 }, KEY_TABLE))
    t.eq(P.duckShift, 36)
    t.eq(P.tapRoom, 36)
    t.eq(P.tapPlace, 32.0625)
    P = settings.physics(settings.load(nil, KEY_TABLE))
    t.eq(P.duckShift, 45)
    t.eq(P.tapPlace, 40.078125)
end)

-- input.buttons ------------------------------------------------------------------------------

t.test("a frame with no key down at 60 fps asks Ctrl, the wheel down, Shift, Space, the pad's A and the wheel up "
    .. "once each, each kind as it can be read", function()
    -- The cost test's frame (four polls more than 0.3.1's two jump keys). Fails if: a wheel
    -- key is asked IsInputKeyDown (it is never down); quick taps are asked at 60 fps; the pad's A
    -- is asked WasInputKeyJustPressed (sampled every frame); a key is asked twice.
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.eq(list(asked), "down LeftControl, pressed MouseScrollDown, down LeftShift, down SpaceBar, "
        .. "down Gamepad_FaceButton_Bottom, pressed MouseScrollUp")
    for _, name in ipairs({ "duckHeld", "duckNotch", "tapHeld", "jumpHeld", "jumpNotch" }) do
        t.eq(k[name], false, name)
    end
end)

t.test("a list is read up to its first key down: with Ctrl held the wheel isn't asked, with Space held neither "
    .. "the pad's A nor the wheel up", function()
    -- Fails if: a list goes on after a key down; the notches are asked with a key held.
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    g.keys.LeftControl, g.keys.SpaceBar = true, true
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.eq(list(asked), "down LeftControl, down LeftShift, down SpaceBar")
    t.truthy(k.duckHeld and k.jumpHeld and not k.duckNotch and not k.jumpNotch and not k.tapHeld)
end)

t.test("in a frame longer than 1/40 s with no key of the list down, a keyboard key's quick tap is a notch; never "
    .. "a duck tap key's or a gamepad button's", function()
    -- Fails if: quick taps are asked in short frames, with a key of the list down, of DuckTapKeys
    -- or of gamepad buttons; a quick tap isn't a notch.
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    m.input.buttons(g.pc, cfg, 1, 0.03, true, false)
    t.eq(list(asked), "down LeftControl, pressed LeftControl, pressed MouseScrollDown, down LeftShift, down SpaceBar, "
        .. "down Gamepad_FaceButton_Bottom, pressed SpaceBar, pressed MouseScrollUp")
    g.notch("LeftControl")
    g.notch("SpaceBar")
    g.notch("LeftShift")
    local k = m.input.buttons(g.pc, cfg, 2, 0.03, true, false)
    t.truthy(k.duckNotch and k.jumpNotch, "both quick taps are notches")
    t.truthy(not k.duckHeld and not k.jumpHeld and not k.tapHeld, "none of them held")
    k = m.input.buttons(g.pc, cfg, 3, 0.02, true, false)
    t.truthy(not k.duckNotch and not k.jumpNotch, "a frame of 0.02 s doesn't ask")
    -- A held duck key: its list isn't asked for quick taps, the jump list still is.
    for i = #asked, 1, -1 do
        asked[i] = nil
    end
    g.justPressed = {} -- (a frame would have cleared them)
    g.keys.LeftControl = true
    m.input.buttons(g.pc, cfg, 4, 0.05, true, false)
    t.eq(list(asked), "down LeftControl, down LeftShift, down SpaceBar, down Gamepad_FaceButton_Bottom, "
        .. "pressed SpaceBar, pressed MouseScrollUp")
    -- A gamepad button is never asked whether it was pressed.
    local _, padWarnings = settings.load({ JumpKeys = { "Gamepad_FaceButton_Bottom" } }, KEY_TABLE)
    t.eq(#padWarnings, 0)
    local pad = settings.load({ JumpKeys = { "Gamepad_FaceButton_Bottom" } }, KEY_TABLE)
    for i = #asked, 1, -1 do
        asked[i] = nil
    end
    g.keys.LeftControl = false
    g.notch("Gamepad_FaceButton_Bottom")
    k = m.input.buttons(g.pc, pad, 5, 0.05, true, false)
    t.eq(k.jumpNotch, false)
    t.absent(asked, "pressed Gamepad_FaceButton_Bottom")
end)

t.test("the duck notch is asked with a duck key held only while the duck keys are wiped (OpenAG's 2022 rule)",
    function()
    -- Fails if: the notch isn't asked while wiped (a notch makes a wiped key count again); it
    -- is asked with a counting key held (a call a frame for nothing).
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    g.keys.LeftControl = true
    g.notch("MouseScrollDown")
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.eq(k.duckNotch, false)
    t.absent(asked, "pressed MouseScrollDown")
    g.notch("MouseScrollDown")
    k = m.input.buttons(g.pc, cfg, 2, 1 / 60, true, true)
    t.eq(k.duckNotch, true, "asked while wiped")
    t.eq(k.duckHeld, true)
    t.contains(asked, "pressed MouseScrollDown")
end)

t.test("a wheel notch is a notch, never held; the pad's A held is held", function()
    local g, m, cfg = game()
    g.notch("MouseScrollDown")
    g.notch("MouseScrollUp")
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.truthy(k.duckNotch and k.jumpNotch and not k.duckHeld and not k.jumpHeld)
    g.keys.Gamepad_FaceButton_Bottom = true
    k = m.input.buttons(g.pc, cfg, 2, 1 / 60, true, false)
    t.truthy(k.jumpHeld and not k.jumpNotch)
    t.eq(list(m.input.pressesSeen()), "MouseScrollDown, MouseScrollUp", "keys seen pressed, for the report")
    t.contains(m.input.keysSeen(), "Gamepad_FaceButton_Bottom")
end)

t.test("the first time a Control key ducks, one line says that UE4SS's Keybinds mod dumps on Ctrl+J and Ctrl+H",
    function()
    -- Fails if: no line; one every frame; one for a duck key that isn't Ctrl.
    local g, m, cfg = game({ DuckKeys = { "Q", "CTRL" } })
    g.keys.Q = true
    m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.absent(g.log, "Keybinds")
    g.keys.Q, g.keys.RightControl = false, true
    for frame = 2, 4 do
        m.input.buttons(g.pc, cfg, frame, 1 / 60, true, false)
    end
    g.keys.LeftControl = true
    m.input.buttons(g.pc, cfg, 5, 1 / 60, true, false)
    t.eq(count(g.log, "Keybinds"), 1)
    t.contains(g.log, "Ducking on RightControl: UE4SS's Keybinds mod, if it is on, starts a long dump on Ctrl+J and "
        .. "Ctrl+H; don't press J or H while ducked, or turn that mod off in ue4ss\\Mods\\mods.txt")
end)

t.test("with the keys the game's (owned false) the duck, duck tap and jump buttons read up and aren't asked; the "
    .. "movement keys still move", function()
    -- Fails if: owned is ignored (the game and the mod both act on one key: Space skips a dialogue
    -- line and hops); the movement keys stop too.
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    g.keys.LeftControl, g.keys.LeftShift, g.keys.SpaceBar, g.keys.W = true, true, true, true
    g.notch("MouseScrollUp")
    local k = m.input.buttons(g.pc, cfg, 1, 0.05, false, true)
    for _, name in ipairs({ "duckHeld", "duckNotch", "tapHeld", "jumpHeld", "jumpNotch" }) do
        t.eq(k[name], false, name)
    end
    t.eq(#asked, 0, "nothing asked")
    t.eq(m.input.moveAxes(g.pc, cfg), 1, "W moves")
    -- With Ducking = false the duck parts are false and not asked either.
    local off = settings.load({ Ducking = false }, KEY_TABLE)
    for i = #asked, 1, -1 do
        asked[i] = nil
    end
    k = m.input.buttons(g.pc, off, 2, 1 / 60, true, false)
    t.truthy(not k.duckHeld and not k.tapHeld and k.jumpHeld)
    t.eq(list(asked), "down SpaceBar")
end)

t.test("a duck or duck tap key held when the mod takes the keys over counts only after it is let go; a jump key "
    .. "counts at once", function()
    -- Fails if: a held key acts at once (Shift held through a battle's end is the game's run, and
    -- would also duck tap); a jump key is ignored too (0.3: a held jump hops at once); an ignored
    -- key isn't read while the keys are the game's, so a release then is missed.
    local recorder, asked = pollRecorder()
    local g, m, cfg = game(nil, { extensions = { recorder } })
    g.keys.LeftControl, g.keys.LeftShift, g.keys.SpaceBar = true, true, true
    t.eq(list(m.input.ignoreHeld(g.pc, cfg)), "LeftControl, LeftShift")
    t.eq(list(m.input.ignoredKeys()), "LeftControl, LeftShift")
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.truthy(not k.duckHeld and not k.tapHeld, "held at the take-over: not yet")
    t.eq(k.jumpHeld, true, "the jump key isn't ignored")
    k = m.input.buttons(g.pc, cfg, 2, 1 / 60, true, false)
    t.truthy(not k.duckHeld and not k.tapHeld, "still held: still not")
    -- Let go while the keys are the game's: still read, so the release is seen.
    g.keys.LeftShift = false
    for i = #asked, 1, -1 do
        asked[i] = nil
    end
    m.input.buttons(g.pc, cfg, 3, 1 / 60, false, false)
    t.eq(list(asked), "down LeftControl, down LeftShift", "only the ignored keys")
    g.keys.LeftShift = true
    k = m.input.buttons(g.pc, cfg, 4, 1 / 60, true, false)
    t.eq(k.tapHeld, true, "pressed again: it counts")
    t.eq(k.duckHeld, false, "Ctrl, never let go, still doesn't")
    g.keys.LeftControl = false
    m.input.buttons(g.pc, cfg, 5, 1 / 60, true, false)
    g.keys.LeftControl = true
    k = m.input.buttons(g.pc, cfg, 6, 1 / 60, true, false)
    t.eq(k.duckHeld, true, "let go and pressed again: counts")
    t.eq(#m.input.ignoredKeys(), 0)
    -- Nothing is held at the next take-over: nothing ignored, and a reset forgets them.
    g.keys.LeftControl, g.keys.LeftShift = false, false
    t.eq(#m.input.ignoreHeld(g.pc, cfg), 0)
    g.keys.LeftControl = true
    m.input.ignoreHeld(g.pc, cfg)
    m.input.reset()
    k = m.input.buttons(g.pc, cfg, 7, 1 / 60, true, false)
    t.eq(k.duckHeld, true, "input.reset forgets the ignored keys")
end)

t.test("input.lastPolls hands over what input.buttons read this frame, and nothing for another frame", function()
    -- Fails if: another frame's readings are handed over (a key that went down since would be
    -- taken from the game while held: root motion reads no keys); "pressed" is lost.
    local g, m, cfg = game()
    g.keys.LeftControl = true
    g.notch("MouseScrollUp")
    m.input.buttons(g.pc, cfg, 7, 1 / 60, true, false)
    local polls = m.input.lastPolls(7)
    t.eq(polls.LeftControl, true)
    t.eq(polls.MouseScrollDown, nil, "not read: Ctrl was down")
    t.eq(polls.LeftShift, false)
    t.eq(polls.SpaceBar, false)
    t.eq(polls.MouseScrollUp, "pressed")
    t.eq(next(m.input.lastPolls(8)), nil, "nothing read on frame 8")
end)

t.test("JumpInput: \"game\" reads no jump key, only the game's jump event; \"auto\" counts that event until a jump "
    .. "key has read down", function()
    local recorder, asked = pollRecorder()
    local g, m, cfg = game({ JumpInput = "game" }, { extensions = { recorder } })
    g.keys.SpaceBar = true
    m.input.onGameJump(true, 1)
    local k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.eq(k.jumpHeld, true)
    t.absent(asked, "SpaceBar")
    g, m, cfg = game()
    m.input.onGameJump(true, 1)
    k = m.input.buttons(g.pc, cfg, 1, 1 / 60, true, false)
    t.eq(k.jumpHeld, true, "auto: the game's event before a key was seen")
    g.keys.SpaceBar = true
    m.input.buttons(g.pc, cfg, 2, 1 / 60, true, false)
    g.keys.SpaceBar = false
    k = m.input.buttons(g.pc, cfg, 3, 1 / 60, true, false)
    t.eq(k.jumpHeld, false, "auto: the keys alone once they work")
end)

-- keys.lua -------------------------------------------------------------------------------

t.test("the keys are taken from the game while the mod moves the character: its run, walk and jump don't act on "
    .. "Shift, Ctrl and Space, and act again once they are given back", function()
    -- Fails if: no context, a priority under the game's, the game's mappings on the keys not left
    -- out; the context not removed at the hand-back.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN)
    t.contains(g.log, "Taking the mod's keys from the game while it moves your character: " .. DEFAULT_TAKEN)
    t.contains(g.log, "Keys: taken: Gamepad_FaceButton_Bottom, LeftControl, LeftShift, MouseScrollDown, "
        .. "MouseScrollUp, SpaceBar")
    local pawn = fake.props(g.pawn)
    g.keys.LeftShift, g.keys.LeftControl, g.keys.SpaceBar = true, true, true
    g.frames(10)
    g.keys.LeftShift, g.keys.LeftControl, g.keys.SpaceBar = false, false, false
    g.frames(10)
    t.eq(pawn.DesiredGait, 1, "still running")
    t.eq(pawn.IsSprintRequested, false)
    t.eq(g.input.fired.SprintAction, nil)
    t.eq(g.input.fired.WalkAction, nil)
    t.eq(g.gameJumps, 0, "Space calls no game jump")
    t.truthy(d.k.duckHeld == false and d.k.jumpHeld == false)
    -- The mod lets go (F5): the keys are the game's again.
    m.keys.give(g.pc, "off")
    d.off = true
    t.eq(modContexts(g), "")
    t.contains(g.log, "Keys: given back (off)")
    g.keys.LeftControl = true
    g.frame()
    t.eq(pawn.DesiredGait, 0, "Ctrl toggles the game's walk again")
    g.keys.LeftShift = true
    g.frame()
    t.eq(pawn.DesiredGait, 2, "Shift runs")
    g.keys.SpaceBar = true
    g.frames(2)
    t.eq(g.gameJumps, 1, "Space jumps")
    t.eq(g.input.crashes, 0)
end)

t.test("a key held when the mod takes over stays the game's until it is let go, and the game sees its release; "
    .. "then it is taken with the others", function()
    -- Fails if: a held key is taken (its mapping goes while held, the game's run never ends);
    -- the keys wait for every key to be let go (Space held through a
    -- battle's end would leave Ctrl and Shift with the game).
    local g, m, cfg = game()
    local pawn = fake.props(g.pawn)
    g.keys.LeftShift = true
    g.frame() -- the game's run starts (no hook yet)
    t.eq(pawn.DesiredGait, 2)
    drive(g, m, cfg)
    g.frames(5)
    t.eq(modContexts(g), "1000000: LeftControl, MouseScrollDown, SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom")
    t.contains(g.log, "LeftShift is held, so it stays the game's until you let go")
    g.keys.LeftShift = false
    g.frame()
    t.eq(pawn.DesiredGait, 1, "the game saw the release: running again")
    t.eq(pawn.IsSprintRequested, false)
    g.frame()
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN)
    local status = m.keys.status()
    t.eq(status.takes, 1)
    t.eq(status.remakes, 1, "a new context for the new set")
    t.eq(#g.input.applied(), 2, "the old one removed: the game's and the mod's")
    g.keys.LeftShift = true
    g.frames(3)
    t.eq(pawn.DesiredGait, 1, "Shift is the mod's now")
end)

t.test("adds don't ask to ignore pressed keys and removals that give the keys back do: a game action held across a "
    .. "new context isn't cut, and every call has all three options", function()
    -- Fails if: one set of options for both (the add's ignore cuts the aim held on
    -- the right mouse button); the re-make's removal ignores pressed keys; a field left out (UE4SS
    -- zeroes the parameter).
    local g, m, cfg = game()
    g.keys.RightMouseButton = true
    g.keys.LeftShift = true
    g.frame()
    t.eq(g.input.aiming, true, "aiming")
    drive(g, m, cfg)
    g.frames(3)
    g.keys.LeftShift = false
    g.frames(3) -- Shift is taken: a new context, the old one removed
    t.eq(m.keys.status().remakes, 1)
    t.eq(g.input.aiming, true, "still aiming")
    m.keys.give(g.pc, "battle")
    local adds, removes = {}, {}
    for _, entry in ipairs(g.input.log) do
        t.truthy(entry.allThree, "all three fields")
        t.truthy(entry.force, "at once")
        t.eq(entry.notify, false)
        t.truthy(entry.mine)
        if entry.call == "add" then
            adds[#adds + 1] = tostring(entry.ignore)
        else
            removes[#removes + 1] = tostring(entry.ignore)
        end
    end
    t.eq(list(adds), "false, false", "two adds, neither ignoring")
    t.eq(list(removes), "false, true", "the re-make's removal doesn't, the hand-back's does")
end)

t.test("Ctrl held as the keys are given back (a battle) toggles nothing, neither then nor when let go; its next "
    .. "press is the game's", function()
    -- Fails if: the removal doesn't ask to ignore pressed keys (the game's walk toggles under the
    -- held key; the guard would put it back, but the game acted).
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    g.keys.LeftControl = true -- ducking
    g.frames(5)
    d.blocked = "battle"
    g.frames(5)
    local pawn = fake.props(g.pawn)
    t.eq(pawn.DesiredGait, 1)
    t.eq(g.input.fired.WalkAction, nil, "the game's walk didn't act on the held key")
    g.keys.LeftControl = false
    g.frames(3)
    t.eq(pawn.DesiredGait, 1, "nor on its release")
    g.keys.LeftControl = true
    g.frame()
    t.eq(pawn.DesiredGait, 0, "the next press toggles walk: the keys are the game's in battle")
    t.absent(g.log, "Keys: the game reacted to")
end)

t.test("the hand-back guard: when the engine doesn't ignore a key held over the hand-back, the game's change is "
    .. "put back while the key stays down, also with the mod off; DesiredGait is read on few frames", function()
    -- Fails if: no guard; the guard runs only while the mod is on; it reads
    -- the enum DesiredGait on every frame (UE4SS builds a table of its names at each read); it
    -- stays after the key's release; an area change arms it.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    g.input.losesIgnoreFlag = true
    g.keys.LeftControl = true
    g.frames(3)
    local reads = g.input.enumReads
    m.keys.give(g.pc, "off") -- F5 with Ctrl held
    d.off = true
    t.eq(g.input.enumReads - reads, 1, "read once as the guard is armed")
    t.truthy(m.keys.status().guard, "armed")
    g.frame()
    local pawn = fake.props(g.pawn)
    t.eq(g.input.fired.WalkAction, 1, "the game toggled walk under the held key")
    t.eq(pawn.DesiredGait, 1, "put back")
    t.contains(g.log, "Keys: the game reacted to LeftControl, held as the mod gave the keys back; its walk/run state "
        .. "is put back")
    g.frames(59)
    t.eq(g.input.enumReads - reads, 1 + 3, "then on the first three frames only")
    pawn.IsSprintRequested = true -- the game changing it while the key stays down
    g.frame()
    t.eq(pawn.IsSprintRequested, false, "IsSprintRequested is read on every frame")
    g.keys.LeftControl = false
    g.frames(5)
    t.eq(g.input.enumReads - reads, 1 + 3 + 2, "and on the frame the key is let go and the next")
    t.eq(m.keys.status().guard, nil, "disarmed")
    t.eq(m.keys.status().guardPutBack, 2)
    -- An area change arms no guard: the game may be replacing the character.
    g, m, cfg = game()
    d = drive(g, m, cfg)
    g.frames(3)
    g.input.losesIgnoreFlag = true
    g.keys.LeftControl = true
    g.frames(3)
    m.keys.give(g.pc, "area")
    d.off = true
    g.frames(3)
    t.eq(m.keys.status().guard, nil)
    t.eq(fake.props(g.pawn).DesiredGait, 0, "not put back")
end)

t.test("the guard lasts 10 s at most, and ends with another character", function()
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    g.keys.LeftControl = true
    g.frames(3)
    m.keys.give(g.pc, "off")
    d.off = true
    local pawn = fake.props(g.pawn)
    g.frames(5 * 60)
    pawn.IsSprintRequested = true
    g.frame()
    t.eq(pawn.IsSprintRequested, false, "put back after 5 s")
    g.frames(6 * 60)
    pawn.IsSprintRequested = true
    g.frame()
    t.eq(pawn.IsSprintRequested, true, "not after 10 s")
    t.eq(m.keys.status().guard, nil)
    -- Another character
    g, m, cfg = game()
    d = drive(g, m, cfg)
    g.frames(3)
    g.keys.LeftControl = true
    g.frames(3)
    m.keys.give(g.pc, "off")
    d.off = true
    g.useCharacter(g.buildCharacter())
    g.frame()
    t.eq(m.keys.status().guard, nil, "a new character")
end)

t.test("a UE4SS mods restart with the keys taken: the journal's context line, with the subsystem's full name, has "
    .. "the new copy remove the context, ignoring held keys", function()
    -- Fails if: no journal line; the restorer removes without ignoring held keys; keys.lua doesn't
    -- register its restorer with journal.restorer (journal.lua's API).
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    m.journal.flush()
    local status = m.keys.status()
    local line = string.format("context\t%s\t\ts%s", status.context, status.subsystem)
    t.truthy(g.shared["HL1Movement.changes"]:find(line, 1, true), "the journal line: " .. line)
    t.truthy(status.context:find("^InputMappingContext /Engine/Transient%.InputMappingContext_"), status.context)
    t.truthy(status.subsystem:find("^EnhancedInputLocalPlayerSubsystem /Engine/Transient%."), status.subsystem)
    -- The new copy's restorer, as journal.restorePending calls it.
    g.hooks[g.tickPath] = nil
    local n = modules()
    local ctx = g.input.applied()[1].obj
    local found = { n.keys.restoreContext(ctx, "", status.subsystem) }
    t.eq(#found, 0)
    t.eq(modContexts(g), "")
    t.eq(g.input.log[#g.input.log].ignore, true)
    t.eq(g.input.crashes, 0)
    -- A gone subsystem is an error (counted by the journal as not put back), not a crash.
    t.falsy(pcall(n.keys.restoreContext, ctx, "", "EnhancedInputLocalPlayerSubsystem /Engine/Transient.Gone"))
    -- Registered with the journal once the journal can take it.
    for name in pairs(package.loaded) do
        if name:match("^hl1movement%.") then
            package.loaded[name] = nil
        end
    end
    local journal = require("hl1movement.journal")
    local registered = {}
    journal.restorer = function(kind, fn)
        registered[kind] = fn
    end
    local keys = require("hl1movement.keys")
    t.eq(registered.context, keys.restoreContext)
    d.off = true
end)

t.test("a world change: keys.forget removes the context if it still exists, without a crash, and forgets its "
    .. "journal line; the new controller gets the keys afresh", function()
    -- Fails if: forget passes the old objects without checking them (a crash); the journal keeps
    -- the line (the next restart would say it couldn't be found).
    local g, m, cfg = game()
    drive(g, m, cfg)
    g.frames(3)
    g.pc = fake.copy(g.pc) -- a new level brings a new controller
    m.keys.forget()
    local last = g.input.log[#g.input.log]
    t.truthy(last.call == "remove" and last.ignore, "removed, ignoring held keys")
    m.journal.flush()
    t.falsy((g.shared["HL1Movement.changes"] or ""):find("context", 1, true), "no context line")
    t.eq(m.keys.status().context, nil)
    g.frames(3)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN, "taken on the new controller")
    t.eq(g.input.crashes, 0)
    -- The context freed by the garbage collector while the keys were given back: found gone, no call.
    m.keys.give(g.pc, "battle")
    g.collectGarbage()
    m.keys.forget()
    g.frames(3)
    t.eq(g.input.crashes, 0)
end)

t.test("the game dropping the mod's context: the half-second check sees it and the keys are taken again; five "
    .. "drops in a minute fall back to keeping the game's walk/run state", function()
    -- Fails if: no check (the keys stay the game's); the drops not counted; no fall-back.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    local calls = g.input.calls.has
    m.keys.check(d.now)
    t.eq(g.input.calls.has - calls, 1, "one HasMappingContext")
    t.eq(m.keys.status().drops, 0)
    local _, text = m.keys.takeStats()
    t.eq(text, "keys taken 1 time, re-made 0, dropped by the game 0, the game's gait put back 0")
    t.eq(select(2, m.keys.takeStats()), nil, "nothing since")
    for i = 1, 4 do
        g.input.dropAll()
        m.keys.check(d.now)
        t.eq(m.keys.status().drops, i)
        g.frames(2)
        t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN, "taken again after drop " .. i)
    end
    t.eq(count(g.log, "Keys: the game dropped the mod's keys"), 3, "the first three logged")
    local stats
    stats, text = m.keys.takeStats()
    t.eq(stats.drops, 4)
    t.eq(text, "keys taken 4 times, re-made 0, dropped by the game 4, the game's gait put back 0")
    g.input.dropAll()
    m.keys.check(d.now)
    t.eq(m.keys.status().method, "gait")
    t.contains(g.log, "Keys: the game dropped the mod's keys 5 times in a minute, so the mod can't keep its keys from "
        .. "the game")
    g.frames(3)
    t.eq(modContexts(g), "", "no more tries")
    m.keys.retry() -- F5
    g.frames(2)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN, "F5 tries again")
end)

t.test("five drops spread over more than a minute don't fall back; five within 56 s do", function()
    -- Fails with: a window shorter than 56 s (20 s passes the first part alone).
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    for _ = 1, 6 do
        g.input.dropAll()
        m.keys.check(d.now)
        g.frames(20 * 60)
    end
    t.eq(m.keys.status().method, "context")
    t.eq(m.keys.status().drops, 6)
    g, m, cfg = game()
    d = drive(g, m, cfg)
    g.frames(3)
    for i = 1, 5 do
        g.input.dropAll()
        m.keys.check(d.now)
        if i < 5 then
            g.frames(14 * 60)
        end
    end
    t.eq(m.keys.status().method, "gait", "five drops in 56 s")
end)

-- One fall-back: the game set up by setup(g) after the take-over's frames, then Shift pressed.
local function fallBackGame(options, setup)
    local g, m, cfg = game(nil, options)
    if setup then
        setup(g)
    end
    local d = drive(g, m, cfg)
    g.frames(3)
    return g, m, cfg, d
end

t.test("each way the context can't be set up falls back, with one warning, to putting the game's walk/run state "
    .. "back on frames with one of the mod's keys down", function()
    -- Fails if: a failure isn't noticed (the keys stay the game's without a word); the
    -- fall-back doesn't put the state back; it puts back the game's own changes on other frames.
    local cases = {
        { "no subsystem", { noInputSubsystem = true }, nil, "the game's Enhanced Input subsystem wasn't found" },
        { "no context", nil, function(g)
            g.input.objects().constructFails = { InputMappingContext = true }
        end, "the mod's input mapping context couldn't be made" },
        { "no action", nil, function(g)
            g.input.objects().constructFails = { InputAction = true }
        end, "the mod's input action couldn't be made" },
        { "MapKey", nil, function(g)
            g.input.objects().mapKeyFails = true
        end, "mapping LeftControl failed" },
        { "not added", nil, function(g)
            g.input.objects().addIgnored = true
        end, "the game didn't apply the mod's input mapping context" },
        { "not there", nil, function(g)
            g.input.objects().hasLies = true
        end, "the game didn't apply the mod's input mapping context" },
    }
    for _, case in ipairs(cases) do
        local g, m = fallBackGame(case[2], case[3])
        t.eq(m.keys.status().method, "gait", case[1])
        t.eq(count(g.log, "so the mod can't keep its keys from the game"), 1, case[1] .. ": one warning")
        t.contains(g.log, "Keys: " .. case[4])
        t.eq(modContexts(g), "", case[1] .. ": no context of the mod's left")
        local pawn = fake.props(g.pawn)
        g.keys.LeftShift = true
        g.frame()
        t.eq(pawn.DesiredGait, 1, case[1] .. ": the game's run put back on the frame")
        t.eq(pawn.IsSprintRequested, false, case[1])
        g.keys.LeftShift = false
        g.frames(3)
        t.eq(pawn.DesiredGait, 1, case[1] .. ": the release too")
        t.contains(g.log, "Keys: the game changed its gait from 1 to 2 on a frame with LeftShift down; put back")
        -- A change of the game's own, with none of the mod's keys down: kept.
        g.frames(70)
        pawn.DesiredGait = 0
        g.frames(70)
        t.eq(pawn.DesiredGait, 0, case[1] .. ": the game's own change is kept")
        g.keys.LeftControl = true
        g.frame()
        t.eq(pawn.DesiredGait, 0, case[1] .. ": and kept from then on")
        t.eq(g.input.crashes, 0)
    end
end)

t.test("way \"gait\": a duck key held since the take-over is the game's until let go, so its release's change is "
    .. "the game's own and kept", function()
    -- Fails if: an ignored key counts as one of the mod's keys down (Shift held through a battle's
    -- end: the game's run, ended by the release, would be put back on: stuck running).
    local g, m, cfg = game(nil, { noInputSubsystem = true })
    local pawn = fake.props(g.pawn)
    g.keys.LeftShift = true
    g.frame()
    t.eq(pawn.DesiredGait, 2, "the game's run")
    drive(g, m, cfg)
    g.frames(5)
    t.eq(m.keys.status().method, "gait")
    g.keys.LeftShift = false
    g.frames(5)
    t.eq(pawn.DesiredGait, 1, "the release ended the run, and that stays")
    t.eq(m.keys.status().gaitPutBack, 0)
    g.keys.LeftShift = true -- now the mod's key: the game's run on it is put back
    g.frame()
    t.eq(pawn.DesiredGait, 1)
    t.eq(m.keys.status().gaitPutBack, 2, "its run and its request")
end)

t.test("way \"gait\" reads DesiredGait only on frames with one of the mod's keys down, the two after, and once a "
    .. "second", function()
    -- Fails if: the enum is read on every frame.
    local g, m = fallBackGame({ noInputSubsystem = true })
    t.eq(m.keys.status().method, "gait")
    local reads = g.input.enumReads
    g.frames(120)
    local idle = g.input.enumReads - reads
    t.truthy(idle >= 1 and idle <= 3, "two seconds without a key: about once a second, read " .. idle)
    reads = g.input.enumReads
    g.keys.LeftControl = true
    g.frames(10)
    g.keys.LeftControl = false
    g.frames(10)
    t.eq(g.input.enumReads - reads, 10 + 2, "the frames with Ctrl down and the two after")
end)

t.test("a game action still on a taken key after the add: a warning, and the game's walk/run state kept as well",
    function()
    -- Fails if: the list isn't read after the first takes.
    local g, m = fallBackGame(nil, function(g)
        g.input.addGameContext("IMC_Above", 2000000, { { "SprintAction", "LeftShift" } })
    end)
    t.eq(m.keys.status().method, "context")
    t.eq(m.keys.status().alsoGait, true)
    t.contains(g.log, "Keys: the game's SprintAction still answers to LeftShift with the mod's keys taken")
    local pawn = fake.props(g.pawn)
    g.keys.LeftShift = true
    g.frame()
    t.eq(pawn.DesiredGait, 1, "its run is put back")
end)

t.test("way \"gait\" falls back to nothing when the game's walk/run state can't be read", function()
    local g, m = fallBackGame({ noInputSubsystem = true, noGaitFields = true })
    t.eq(m.keys.status().method, "off")
    t.contains(g.log, "the game's walk and run state can't be read (DesiredGait, IsSprintRequested), so the game may "
        .. "toggle walk and run on the mod's keys while the mod moves you.")
    g.frames(5)
    t.eq(g.input.crashes, 0)
end)

t.test("TakeKeys = false makes no Enhanced Input call at all; JumpInput \"game\", TakeJumpKeys = false and "
    .. "Ducking = false leave their keys to the game", function()
    -- Fails if: TakeKeys is ignored; the jump keys are taken with JumpInput "game" (the mod needs
    -- the game's jump event then) or TakeJumpKeys false; the duck keys with Ducking false.
    local g, m, cfg = game({ TakeKeys = false })
    drive(g, m, cfg)
    g.frames(5)
    g.keys.LeftShift = true
    g.frames(3)
    for name, n in pairs(g.input.calls) do
        if name ~= "isValid" and name ~= "isAnalog" then
            t.eq(n, 0, name)
        end
    end
    t.eq(fake.props(g.pawn).DesiredGait, 2, "the game runs on Shift")
    t.contains(g.log, "Keys: off (TakeKeys = false)")
    for _, case in ipairs({ { { JumpInput = "game" }, "LeftControl, MouseScrollDown, LeftShift" },
        { { TakeJumpKeys = false }, "LeftControl, MouseScrollDown, LeftShift" },
        { { Ducking = false }, "SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom" } }) do
        g, m, cfg = game(case[1])
        drive(g, m, cfg)
        g.frames(3)
        t.eq(modContexts(g), "1000000: " .. case[2])
    end
    g.keys.SpaceBar = true
    g.frames(2)
    t.eq(g.gameJumps, 0, "Ducking = false: the jump keys are still taken")
end)

t.test("paused frames give the keys back and the next frame the mod moves the character takes them again; a "
    .. "dialogue shown with the movement on gives them back too", function()
    -- Fails if: the keys stay taken while paused (menus use Space and the wheel); they aren't taken
    -- again after; a key pressed during the dialogue is acted on when the keys come back.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    g.keys.LeftControl = true -- ducking, through the pause
    g.frame()
    g.paused = true
    g.frames(3)
    t.eq(modContexts(g), "")
    t.contains(g.log, "Keys: given back (paused)")
    g.paused = false
    g.frames(2)
    t.eq(d.k.duckHeld, true, "a pause isn't a take-over: Ctrl held through it still ducks")
    t.eq(modContexts(g), "1000000: MouseScrollDown, LeftShift, SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom",
        "Ctrl, held, is the game's until let go (its mapping ignored meanwhile)")
    g.keys.LeftControl = false
    g.frames(2)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN)
    t.eq(m.keys.status().takes, 2)
    t.eq(fake.props(g.pawn).DesiredGait, 1, "the game's walk never toggled")
    d.shows = "dialogue"
    g.frames(2)
    t.eq(modContexts(g), "")
    g.keys.LeftControl = true -- the game's walk toggles: its key, in the dialogue
    g.frames(2)
    t.eq(fake.props(g.pawn).DesiredGait, 0)
    d.shows = nil
    g.frames(3)
    t.eq(d.k.duckHeld, false, "held from the dialogue: not a duck until pressed again")
    g.keys.LeftControl = false
    g.frame()
    g.keys.LeftControl = true
    g.frame()
    t.eq(d.k.duckHeld, true)
    t.eq(fake.props(g.pawn).DesiredGait, 0, "the game's walk, toggled in the dialogue, stays the game's")
end)

t.test("keys.validate asks the game about each name: one it doesn't know is left out of every reading with a "
    .. "warning, one only the mod doesn't know is used, an axis is left out", function()
    -- Fails if: names aren't checked with Key_IsValid; a refused name is still read or taken;
    -- Key_IsAnalog asked of names the mod knows (a call for nothing).
    local recorder, asked = pollRecorder()
    local g, m, cfg = game({ JumpKeys = { "SpaceBar", "Ampersand", "Bogus", "Gamepad_Special_Left_X" } },
        { extensions = { recorder } })
    drive(g, m, cfg)
    g.frames(3)
    t.contains(g.log, 'JumpKeys: "Bogus" is not a key the game knows, so it is left out')
    t.contains(g.log, 'JumpKeys: "Gamepad_Special_Left_X" is an axis for the game, not a key, so it is left out')
    t.absent(g.log, '"Ampersand" is not a key the game knows')
    t.absent(asked, "Bogus")
    t.absent(asked, "Gamepad_Special_Left_X")
    t.contains(asked, "down Ampersand")
    t.eq(modContexts(g), "1000000: LeftControl, MouseScrollDown, LeftShift, SpaceBar, Ampersand")
    t.eq(g.input.calls.isValid, 11, "once for each name of the seven lists")
    t.eq(g.input.calls.isAnalog, 2, "only for the names the mod doesn't know that the game does")
end)

t.test("taking the keys costs nothing a frame once they are taken: no game call, no full name; the check every "
    .. "0.5 s one HasMappingContext", function()
    -- Fails if: the context is made again every frame, or its objects checked every frame.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    d.keyCalls, d.keyNames = 0, 0
    local before = {}
    for name, n in pairs(g.input.calls) do
        before[name] = n
    end
    g.frames(60)
    t.eq(d.keyCalls, 0, "no game call in keys.watch and keys.take")
    t.eq(d.keyNames, 0, "no full name")
    for name, n in pairs(g.input.calls) do
        t.eq(n, before[name], name)
    end
    local calls, names = fake.counts.calls, fake.counts.fullNames
    m.keys.check(d.now)
    t.eq(fake.counts.calls - calls, 1, "the check: one call")
    t.eq(g.input.calls.has - before.has, 1, "HasMappingContext")
    t.eq(fake.counts.fullNames - names, 2, "and the two objects' full names")
end)

t.test("the first takes say which of the game's actions wait, and warn about an action of the game's the mod's "
    .. "keys would silence", function()
    -- Fails if: the line or the warning is missing (the owner's first test in the game reads them).
    local g, m, cfg = game()
    g.input.addGameContext("IMC_UI_Exploration", 5, { { "IA_UI_Interact", "MouseScrollDown" } })
    drive(g, m, cfg)
    g.frames(3)
    t.contains(g.log, "Keys: while the mod moves you, the game's WalkAction (LeftControl), IA_UI_Interact "
        .. "(MouseScrollDown), SprintAction (LeftShift) and JumpAction (SpaceBar, Gamepad_FaceButton_Bottom) wait; "
        .. "the game had nothing on MouseScrollUp")
    t.contains(g.log, "MouseScrollDown is also the game's IA_UI_Interact: it won't work while the mod moves you. "
        .. "Change DuckKeys in config.lua to keep it.")
    local actions = m.keys.status().gameActions
    t.eq(list(actions.LeftShift), "SprintAction")
    t.eq(list(actions.SpaceBar), "JumpAction")
    t.eq(actions.MouseScrollUp, nil)
    -- Read on the first three takes of a session only.
    for _ = 1, 4 do
        g.paused = true
        g.frame()
        g.paused = false
        g.frame()
    end
    t.eq(count(g.log, "Keys: while the mod moves you"), 1, "the same line isn't written again")
    t.eq(m.keys.status().takes, 5)
end)

t.test("no object that isn't valid is ever passed: a freed action and a subsystem that changed are found again",
    function()
    -- Fails if: the mod's input action is used after the garbage collector freed it, or at its
    -- address taken by another object (UE4SS: the old wrapper reads valid); the subsystem isn't
    -- checked by its full name.
    local g, m, cfg = game()
    local d = drive(g, m, cfg)
    g.frames(3)
    d.blocked = "battle"
    g.frames(2)
    g.collectGarbage() -- frees the context and the action: none applied uses them
    local other = fake.object({ className = "StaticMesh", props = {} })
    local old = g.input.log[1].ctx.mappings[1].action.obj
    fake.reuseAddress(old, other)
    d.blocked = nil
    g.frames(3)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN)
    t.eq(g.input.crashes, 0)
    t.eq(g.input.calls.made, 4, "a new action and a new context")
    fake.move(g.input.subsystem, "/Engine/Transient.GameEngine_2147482617:LocalPlayer_1.Subsystem_2")
    d.blocked = "battle"
    g.frames(2)
    d.blocked = nil
    g.frames(2)
    t.eq(modContexts(g), "1000000: " .. DEFAULT_TAKEN)
    t.eq(g.input.calls.subsystem, 2, "asked again")
end)

-- Hotkeys ---------------------------------------------------------------------------------

t.test("bindAll binds a hotkey plain and with Ctrl, Shift and both held, the most held first, and says which "
    .. "were held", function()
    -- (UE4SS calls a bind only with exactly its modifiers held.) Fails if: no binds
    -- with modifiers (F5 does nothing while ducking on Ctrl); Alt bound; the modifier not passed.
    local g, m, cfg = game()
    drive(g, m, cfg) -- the frames between the presses
    local calls = {}
    t.truthy(m.keys.bindAll(F5, function(modifier)
        calls[#calls + 1] = tostring(modifier)
    end))
    local ids = {}
    for _, bind in ipairs(g.input.binds) do
        ids[#ids + 1] = tostring(bind.id)
    end
    t.eq(list(ids), "116+CONTROL+SHIFT, 116+CONTROL, 116+SHIFT, 116")
    g.press(F5)
    g.press(F5, { "CONTROL" })
    g.press(F5, { "SHIFT" })
    g.press(F5, { "SHIFT", "CONTROL" })
    g.press(F5, { "ALT" })
    t.eq(list(calls), "nil, Ctrl, Shift, Ctrl+Shift", "each once; nothing with Alt")
    -- Without ModifierKey (an older UE4SS): plain binds, and one warning for all the hotkeys.
    g, m = game(nil, { noModifierKey = true })
    t.truthy(m.keys.bindAll(F5, function() end))
    t.truthy(m.keys.bindAll(F5 + 1, function() end))
    t.eq(#g.input.binds, 2)
    t.eq(count(g.log, "This UE4SS has no ModifierKey table, so the hotkeys don't work while Ctrl or Shift is held"), 1)
end)

t.test("a UE4SS that calls every bind whose modifiers are held: one press is one call, with the modifiers held; "
    .. "presses on two frames are two", function()
    -- Fails if: no de-dup (F5 would turn the mod off and on again, F7 read config.lua twice); the
    -- plain bind made first (the call would say no modifier was held); presses a frame apart
    -- taken for one.
    local g, m, cfg = game(nil, { fireEveryBind = true })
    drive(g, m, cfg)
    local calls = {}
    m.keys.bindAll(F5, function(modifier)
        calls[#calls + 1] = tostring(modifier)
    end)
    g.press(F5, { "CONTROL" })
    t.eq(list(calls), "Ctrl")
    g.press(F5, { "CONTROL", "SHIFT" })
    t.eq(list(calls), "Ctrl, Ctrl+Shift")
    g.press(F5)
    g.press(F5)
    t.eq(list(calls), "Ctrl, Ctrl+Shift, nil, nil", "two presses, a frame apart")
end)
