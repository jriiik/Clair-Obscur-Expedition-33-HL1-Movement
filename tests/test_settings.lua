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

t.test("the shipped config.lua loads without warnings", function()
    local user = dofile(TEST_ROOT .. "HL1Movement/Scripts/config.lua")
    local cfg, warnings = settings.load(user, KEYS)
    for _, warning in ipairs(warnings) do
        error("warning: " .. warning)
    end
    for name, default in pairs(settings.DEFAULTS) do
        if type(default) ~= "table" and user[name] ~= nil then
            t.eq(cfg[name], default, "config.lua matches the default for " .. name)
        end
    end
end)

t.test("defaults are copied, not shared", function()
    local cfg = settings.load(nil, KEYS)
    cfg.JumpKeys[1] = "changed"
    t.eq(settings.DEFAULTS.JumpKeys[1], "SpaceBar")
end)

t.test("valid values are used", function()
    local cfg, warnings = settings.load({ MaxSpeed = 400, AutoHop = false, EyeHeight = 70, ToggleKey = "f9",
        JumpInput = "Keys", JumpKeys = { "MouseScrollDown" } }, KEYS)
    t.eq(#warnings, 0)
    t.eq(cfg.MaxSpeed, 400)
    t.eq(cfg.AutoHop, false)
    t.eq(cfg.EyeHeight, 70)
    t.eq(cfg.ToggleKey, "F9", "key names are upper case")
    t.eq(cfg.JumpInput, "keys")
    t.eq(cfg.JumpKeys[1], "MouseScrollDown")
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

t.test("unknown settings and non-name list entries are reported", function()
    local cfg, warnings = settings.load({ MaxSpeedd = 1, JumpKeys = { "SpaceBar", 3, "" } }, KEYS)
    t.eq(#cfg.JumpKeys, 1)
    t.contains(warnings, "Unknown setting MaxSpeedd")
    t.contains(warnings, "ignored 2 entries")
end)

t.test("a config that is not a table is reported", function()
    local cfg, warnings = settings.load(42, KEYS)
    t.eq(cfg.MaxSpeed, 320)
    t.contains(warnings, "must return a table")
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
