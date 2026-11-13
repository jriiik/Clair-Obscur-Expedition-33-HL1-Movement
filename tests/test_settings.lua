-- Tests for HL1Movement/Scripts/hl1movement/settings.lua.

local t = require("testlib")
local settings = require("hl1movement.settings")

local KEYS = { F5 = 0x74, F6 = 0x75, F7 = 0x76, F8 = 0x77, F9 = 0x78, HOME = 0x24 }

t.test("no config gives the defaults and no warnings", function()
    local cfg, warnings = settings.load(nil, KEYS)
    t.eq(#warnings, 0)
    t.eq(cfg.MaxSpeed, 320)
    t.eq(cfg.ToggleKey, "F5")
    t.eq(cfg.JumpKeys[1], "SpaceBar")
end)

-- The table the shipped config.lua gives, run with the globals env as main.lua runs it.
-- The file's text goes through load, not the global loadfile: fake.useConfig replaces
-- that for the rest of the run, and then gives the last test's settings for config.lua.
local function shippedConfig(env)
    local file = assert(io.open(TEST_ROOT .. "HL1Movement/Scripts/config.lua", "rb"))
    local text = file:read("a"):gsub("^\239\187\191", "") -- a byte order mark, which loadfile skips too
    file:close()
    return assert(load(text, "@config.lua", "t", env))()
end

t.test("the shipped config.lua loads without warnings", function()
    local env, unknown = settings.environment(_G)
    local user = shippedConfig(env)
    local cfg, warnings = settings.load(user, KEYS, unknown)
    for _, warning in ipairs(warnings) do
        error("warning: " .. warning)
    end
    for name, default in pairs(settings.DEFAULTS) do
        if type(default) ~= "table" and user[name] ~= nil then
            t.eq(cfg[name], default, "config.lua matches the default for " .. name)
        end
    end
end)

t.test("the shipped config.lua is read from the file after a test gave the fake game settings", function()
    local before = loadfile
    require("fake_game").useConfig({ MaxSpeed = 400 })
    local ok, user = pcall(shippedConfig, (settings.environment(_G)))
    _G.loadfile = before
    assert(ok, user)
    t.eq(user.MaxSpeed, 320, "config.lua's MaxSpeed, not the fake game's")
end)

t.test("defaults are copied, not shared", function()
    local cfg = settings.load(nil, KEYS)
    cfg.JumpKeys[1] = "changed"
    t.eq(settings.DEFAULTS.JumpKeys[1], "SpaceBar")
end)

t.test("valid values are used", function()
    -- (MouseScrollDown is a duck key by default: in JumpKeys too it would get a warning.)
    local cfg, warnings = settings.load({ MaxSpeed = 400, AutoHop = false, EyeHeight = 70, ToggleKey = "f9",
        JumpInput = "Keys", JumpKeys = { "MouseScrollUp" } }, KEYS)
    t.eq(#warnings, 0)
    t.eq(cfg.MaxSpeed, 400)
    t.eq(cfg.AutoHop, false)
    t.eq(cfg.EyeHeight, 70)
    t.eq(cfg.ToggleKey, "F9", "key names are upper case")
    t.eq(cfg.JumpInput, "keys")
    t.eq(cfg.JumpKeys[1], "MouseScrollUp")
end)

t.test("a hotkey can be turned off", function()
    local cfg, warnings = settings.load({ CameraKey = false, ReloadKey = "" }, KEYS)
    t.eq(#warnings, 0)
    t.eq(cfg.CameraKey, false)
    t.eq(cfg.ReloadKey, false)
end)

t.test("wrong types fall back to the default with a warning", function()
    local cfg, warnings = settings.load({ MaxSpeed = "fast", AutoHop = 1, ToggleKey = "NOPE", JumpKeys = "SpaceBar",
        JumpInput = "sometimes", EyeHeight = "high" }, KEYS)
    t.eq(cfg.MaxSpeed, 320)
    t.eq(cfg.AutoHop, true)
    t.eq(cfg.ToggleKey, "F5")
    t.eq(cfg.JumpKeys[1], "SpaceBar")
    t.eq(cfg.JumpInput, "auto")
    t.eq(cfg.EyeHeight, "auto")
    t.eq(#warnings, 6)
    t.contains(warnings, "MaxSpeed")
    t.contains(warnings, "not a UE4SS key name")
end)

t.test("numbers out of range are clamped with a warning", function()
    local cfg, warnings = settings.load({ FieldOfView = 400, PitchLimit = 1 }, KEYS)
    t.eq(cfg.FieldOfView, 150)
    t.eq(cfg.PitchLimit, 10)
    t.eq(#warnings, 2)
end)

t.test("PhysicsRate stops at 250: the most updates a frame of 0.1 s can run (25)", function()
    local cfg, warnings = settings.load({ PhysicsRate = 1000 }, KEYS)
    t.eq(cfg.PhysicsRate, 250)
    t.contains(warnings, "PhysicsRate = 1000: lowered to the highest allowed value, 250")
end)

t.test("unknown settings and non-name list entries are reported", function()
    local cfg, warnings = settings.load({ MaxSpeedd = 1, JumpKeys = { "SpaceBar", 3, "" } }, KEYS)
    t.eq(#cfg.JumpKeys, 1)
    t.contains(warnings, "Unknown setting MaxSpeedd")
    t.contains(warnings, "ignored 2 entries")
end)

t.test("words in config.lua that Lua doesn't know are noted with their lines, and reported", function()
    -- Lua reads flase, False or a name without its quotes as a global that isn't set:
    -- nil, so the entry doesn't exist and nothing else could tell.
    local text = "return {\n    BodySounds = flase,\n    AutoHop = False,\n    Gravity = math.floor(800.5),\n"
        .. "    CameraMethod = game,\n    JumpKeys = { SpaceBar, \"MouseScrollDown\" },\n    KeepSpeed = false,\n}\n"
    local plain = assert(load(text, "@config.lua", "t"))()
    t.eq(plain.BodySounds, nil, "without the environment, the entry just isn't there")
    local env, unknown = settings.environment(_G)
    local user = assert(load(text, "@config.lua", "t", env))()
    t.eq(#unknown, 4)
    for i, expected in ipairs({ { "flase", 2 }, { "False", 3 }, { "game", 5 }, { "SpaceBar", 6 } }) do
        t.eq(unknown[i].name, expected[1])
        t.eq(unknown[i].line, expected[2], "the line of " .. expected[1])
    end
    t.eq(user.Gravity, 800, "Lua's own words still work")
    local cfg, warnings = settings.load(user, KEYS, unknown)
    t.eq(#warnings, 1, "one warning for the file")
    t.contains(warnings, "config.lua has words Lua doesn't know: flase (line 2), False (line 3), game (line 5), "
        .. "SpaceBar (line 6). Each counts as \"not set\"")
    t.eq(cfg.BodySounds, true, "the default stays")
    t.eq(cfg.AutoHop, true)
    t.eq(cfg.CameraMethod, "auto")
    t.eq(cfg.KeepSpeed, false, "a word that is right is read")
    t.eq(#cfg.JumpKeys, 0, "the list ends at the unknown word: the name after it is lost too")
    -- Also when the file gives no table at all, and only so many are named.
    env, unknown = settings.environment(_G)
    user = assert(load("return flase", "@config.lua", "t", env))()
    cfg, warnings = settings.load(user, KEYS, unknown)
    t.eq(cfg.MaxSpeed, 320)
    t.contains(warnings, "config.lua has a word Lua doesn't know: flase (line 1). It counts as \"not set\"")
    env, unknown = settings.environment(_G)
    assert(load("return { a, b, c, d, e, f, g, h, i, j }", "@config.lua", "t", env))()
    local _, many = settings.load({}, KEYS, unknown)
    t.contains(many, "h (line 1), and 2 more. Each counts")
    -- With a file that isn't a table, both warnings stand: the one about the words first.
    env, unknown = settings.environment(_G)
    user = assert(load("return 5 + (ture and 1 or 0)", "@config.lua", "t", env))()
    cfg, warnings = settings.load(user, KEYS, unknown)
    t.eq(cfg.MaxSpeed, 320)
    t.eq(#warnings, 2)
    t.contains(warnings, "ture (line 1)")
    t.contains(warnings, "must return a table")
end)

t.test("a config that is not a table is reported", function()
    local cfg, warnings = settings.load(42, KEYS)
    t.eq(cfg.MaxSpeed, 320)
    t.contains(warnings, "must return a table")
end)

t.test("changes lists the settings that differ from the defaults, or from other settings, by name", function()
    local defaults = settings.load(nil, KEYS)
    t.eq(#settings.changes(defaults), 0, "the defaults differ from nothing")
    local shipped = settings.load(dofile(TEST_ROOT .. "HL1Movement/Scripts/config.lua"), KEYS)
    t.eq(#settings.changes(shipped), 0, "nor does the shipped config.lua")
    -- The same values written another way aren't changes: a key in lower case, 100.0 for 100.
    local cfg = settings.load({ PhysicsRate = 144, BodyFollowsHop = false, JumpKeys = { "SpaceBar" }, ToggleKey = "f5",
        FieldOfView = 100.0, CameraKey = false }, KEYS)
    local changes = settings.changes(cfg)
    local texts = {}
    for i, change in ipairs(changes) do
        texts[i] = change.name .. " = " .. change.value .. " (was " .. change.was .. ")"
    end
    t.eq(table.concat(texts, "; "), 'BodyFollowsHop = false (was true); CameraKey = false (was "F6"); '
        .. 'JumpKeys = { "SpaceBar" } (was { "SpaceBar", "MouseScrollUp", "Gamepad_FaceButton_Bottom" }); '
        .. 'PhysicsRate = 144 (was 250)')
    -- Against other settings: what a reload changed.
    local after = settings.load({ PhysicsRate = 144, JumpKeys = { "SpaceBar" }, CameraKey = false }, KEYS)
    changes = settings.changes(after, cfg)
    t.eq(#changes, 1)
    t.eq(changes[1].name, "BodyFollowsHop")
    t.eq(changes[1].value, "true")
    t.eq(changes[1].was, "false")
end)

t.test("physics parameters are scaled to centimetres", function()
    local P = settings.physics(settings.load({ UnitScale = 2 }, KEYS))
    t.eq(P.maxSpeed, 640)
    t.eq(P.inputSpeed, 800)
    t.eq(P.airSpeedCap, 60)
    t.eq(P.stopSpeed, 200)
    t.eq(P.gravity, 1600)
    t.eq(P.accelerate, 10, "acceleration has no length unit")
    t.near(P.jumpSpeed, math.sqrt(2 * 1600 * 90), 1e-9)
    t.eq(P.maxVelocity, 4000)
end)

t.test("like in Half-Life, less gravity jumps higher", function()
    local P = settings.physics(settings.load({ Gravity = 400 }, KEYS))
    local apex = P.jumpSpeed ^ 2 / (2 * P.gravity) / P.unitScale
    t.near(apex, 90, 1e-9, "twice the height at half the gravity")
    local normal = settings.physics(settings.load(nil, KEYS))
    t.near(normal.jumpSpeed ^ 2 / (2 * normal.gravity) / normal.unitScale, 45, 1e-9, "45 units at 800")
end)
