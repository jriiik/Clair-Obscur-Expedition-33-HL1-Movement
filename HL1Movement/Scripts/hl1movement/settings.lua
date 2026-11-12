-- Settings: the defaults, checks for the values in config.lua, and the physics
-- parameters worked out from them. Pure Lua, tested in tests/test_settings.lua.

local physics = require("hl1movement.physics")

local settings = {}

-- Every setting with its default. config.lua only needs the ones you change.
settings.DEFAULTS = {
    StartEnabled = true,
    ToggleKey = "F5",
    CameraKey = "F6",
    ReloadKey = "F7",
    DiagnosticsKey = "F8",

    Speedometer = false,
    SpeedometerKey = "F9",
    SpeedometerPosition = { 0.5, 0.75 },
    SpeedometerSize = 32,
    SpeedometerColor = { 255, 160, 0 },

    FirstPerson = true,
    CameraMethod = "auto",
    FieldOfView = 100,
    EyeHeight = "auto",
    HideBody = true,
    BodySounds = true,
    PitchLimit = 89,
    BodyFollowsView = true,
    BodyFollowsHop = true,

    Movement = true,
    AutoHop = true,
    PhysicsRate = 100,
    KeepSpeed = true,
    SlopeLandings = true,
    SlopeBoosts = true,
    MaxSpeed = 320,
    InputSpeed = 400,
    Accelerate = 10,
    AirAccelerate = 10,
    AirSpeedCap = 30,
    Friction = 4,
    StopSpeed = 100,
    Gravity = 800,
    JumpHeight = 45,
    BhopCap = 0,
    MaxVelocity = 2000,
    UnitScale = 2.5,

    JumpInput = "auto",
    JumpKeys = { "SpaceBar", "Gamepad_FaceButton_Bottom" },
    ForwardKeys = { "W" },
    BackKeys = { "S" },
    LeftKeys = { "A" },
    RightKeys = { "D" },
    GamepadStick = true,
    StickDeadzone = 0.25,

    DisableSpeedLimiter = true,
    Debug = false,

    -- Advanced: where the mod hooks into the game, and the character's cameras
    -- that show exploration (besides the one the game's GetMainCamera names).
    -- Only change these if a game update renames them.
    CameraComponents = { "Main_CineCamera", "MainCamera" },
    TickFunctions = {
        "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C:ReceiveTick",
        "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_World.BP_jRPG_Character_World_C:ReceiveTick",
    },
    JumpFunctions = {
        "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_World.BP_jRPG_Character_World_C:JumpAction",
    },
    PawnClasses = { "BP_jRPG_Character_World_C" },
    AllowWorldMap = false,
}

local function number(min, max)
    return { kind = "number", min = min, max = max }
end

local BOOLEAN = { kind = "boolean" }
local HOTKEY = { kind = "hotkey" }
local NAMES = { kind = "names" }

-- A list of count numbers, each from min to max.
local function numbers(count, min, max)
    return { kind = "numbers", count = count, min = min, max = max }
end

local RULES = {
    StartEnabled = BOOLEAN,
    ToggleKey = HOTKEY,
    CameraKey = HOTKEY,
    ReloadKey = HOTKEY,
    DiagnosticsKey = HOTKEY,

    Speedometer = BOOLEAN,
    SpeedometerKey = HOTKEY,
    SpeedometerPosition = numbers(2, 0, 1),
    SpeedometerSize = number(8, 200),
    SpeedometerColor = numbers(3, 0, 255),

    FirstPerson = BOOLEAN,
    CameraMethod = { kind = "choice", choices = { auto = true, engine = true, game = true } },
    FieldOfView = number(50, 150),
    EyeHeight = { kind = "eye", min = -200, max = 300 },
    HideBody = BOOLEAN,
    BodySounds = BOOLEAN,
    PitchLimit = number(10, 89.9),
    BodyFollowsView = BOOLEAN,
    BodyFollowsHop = BOOLEAN,

    Movement = BOOLEAN,
    AutoHop = BOOLEAN,
    -- At most 25 updates run in a frame, and a frame counts as 0.1 s at most.
    PhysicsRate = number(0, 250),
    KeepSpeed = BOOLEAN,
    SlopeLandings = BOOLEAN,
    SlopeBoosts = BOOLEAN,
    MaxSpeed = number(1, 5000),
    InputSpeed = number(1, 10000),
    Accelerate = number(0, 1000),
    AirAccelerate = number(0, 10000),
    AirSpeedCap = number(0, 10000),
    Friction = number(0, 100),
    StopSpeed = number(0, 10000),
    Gravity = number(0, 20000),
    JumpHeight = number(0, 2000),
    BhopCap = number(0, 100),
    MaxVelocity = number(0, 100000),
    UnitScale = number(0.25, 10),

    JumpInput = { kind = "choice", choices = { auto = true, keys = true, game = true } },
    JumpKeys = NAMES,
    ForwardKeys = NAMES,
    BackKeys = NAMES,
    LeftKeys = NAMES,
    RightKeys = NAMES,
    GamepadStick = BOOLEAN,
    StickDeadzone = number(0, 0.95),

    DisableSpeedLimiter = BOOLEAN,
    Debug = BOOLEAN,

    CameraComponents = NAMES,
    TickFunctions = NAMES,
    JumpFunctions = NAMES,
    PawnClasses = NAMES,
    AllowWorldMap = BOOLEAN,
}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for i, v in ipairs(value) do
        result[i] = v
    end
    return result
end

local function describe(value)
    if type(value) == "table" then
        local parts = {}
        for i, v in ipairs(value) do
            parts[i] = type(v) == "number" and tostring(v) or string.format("%q", tostring(v))
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    elseif type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end
settings.describe = describe

-- Checks one value. Returns ok, value, note: when ok is false the value is an
-- error message; a note explains a change made to an accepted value.
local function check(rule, value, keyTable)
    local kind = rule.kind
    if kind == "boolean" then
        if type(value) ~= "boolean" then
            return false, "must be true or false"
        end
        return true, value
    elseif kind == "number" or kind == "eye" then
        if kind == "eye" and type(value) == "string" and value:lower() == "auto" then
            return true, "auto"
        end
        if type(value) ~= "number" or value ~= value then
            return false, kind == "eye" and 'must be "auto" or a number' or "must be a number"
        end
        if value < rule.min then
            return true, rule.min, string.format("raised to the lowest allowed value, %s", rule.min)
        elseif value > rule.max then
            return true, rule.max, string.format("lowered to the highest allowed value, %s", rule.max)
        end
        return true, value
    elseif kind == "choice" then
        if type(value) ~= "string" or not rule.choices[value:lower()] then
            local names = {}
            for name in pairs(rule.choices) do
                names[#names + 1] = string.format("%q", name)
            end
            table.sort(names)
            return false, "must be one of " .. table.concat(names, ", ")
        end
        return true, value:lower()
    elseif kind == "hotkey" then
        if value == false or value == "" then
            return true, false
        end
        if type(value) ~= "string" then
            return false, 'must be a key name such as "F5", or false for no key'
        end
        local name = value:upper()
        if keyTable and keyTable[name] == nil then
            return false, string.format("%q is not a UE4SS key name", value)
        end
        return true, name
    elseif kind == "numbers" then
        local wrong = string.format("must be a list of %d numbers from %s to %s", rule.count, rule.min, rule.max)
        if type(value) ~= "table" or #value ~= rule.count then
            return false, wrong
        end
        local result, notes = {}, {}
        for i = 1, rule.count do
            local n = value[i]
            if type(n) ~= "number" or n ~= n then
                return false, wrong
            end
            if n < rule.min then
                n = rule.min
                notes[#notes + 1] = string.format("entry %d raised to the lowest allowed value, %s", i, rule.min)
            elseif n > rule.max then
                n = rule.max
                notes[#notes + 1] = string.format("entry %d lowered to the highest allowed value, %s", i, rule.max)
            end
            result[i] = n
        end
        return true, result, #notes > 0 and table.concat(notes, "; ") or nil
    elseif kind == "names" then
        if type(value) ~= "table" then
            return false, 'must be a list such as { "SpaceBar" }'
        end
        local result, dropped = {}, 0
        for _, entry in ipairs(value) do
            if type(entry) == "string" and entry ~= "" then
                result[#result + 1] = entry
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            return true, result, string.format("ignored %d %s that %s not a name", dropped,
                dropped == 1 and "entry" or "entries", dropped == 1 and "is" or "are")
        end
        return true, result
    end
    return false, "has an unknown type"
end

local MAX_UNKNOWN_WORDS = 8 -- named in the warning; the rest are counted

--- The globals to run config.lua with: Lua's own (`globals`, read through the table
--- returned), and a note of every word that isn't one of them. Lua reads such a word
--- (flase, False, a name without its quotes) as a global that isn't set, which is nil,
--- and a table entry set to nil doesn't exist: the setting would keep its default
--- without a word in the log. Returns the table and the list of notes ({ name, line }),
--- filled while config.lua runs, for settings.load.
function settings.environment(globals)
    local unknown = {}
    local env = setmetatable({}, {
        __index = function(_, name)
            local value = globals[name]
            if value == nil then
                -- Level 2 is config.lua itself: the line the word is on.
                local info = debug and debug.getinfo and debug.getinfo(2, "l")
                local line = info and info.currentline
                unknown[#unknown + 1] = { name = tostring(name), line = line and line > 0 and line or nil }
            end
            return value
        end,
    })
    return env, unknown
end

--- Merges the table config.lua returned into the defaults. keyTable is UE4SS's
--- `Key` table, used to check hotkey names (pass nil to skip that check). unknown:
--- the words in config.lua that Lua didn't know (see settings.environment), if any.
--- Returns the settings and a list of warnings for the log.
function settings.load(user, keyTable, unknown)
    local cfg, warnings = {}, {}
    for name, default in pairs(settings.DEFAULTS) do
        cfg[name] = copy(default)
    end
    if unknown and #unknown > 0 then
        local words = {}
        for i = 1, math.min(#unknown, MAX_UNKNOWN_WORDS) do
            local word = unknown[i]
            words[i] = word.line and string.format("%s (line %d)", word.name, word.line) or word.name
        end
        if #unknown > MAX_UNKNOWN_WORDS then
            words[#words + 1] = string.format("and %d more", #unknown - MAX_UNKNOWN_WORDS)
        end
        local one = #unknown == 1
        warnings[#warnings + 1] = string.format("config.lua has %s Lua doesn't know: %s. %s counts as \"not set\", "
            .. "so the setting there keeps its default (a list ends there). Write true and false in small letters, "
            .. "and put names in quotes", one and "a word" or "words", table.concat(words, ", "),
            one and "It" or "Each")
    end
    if user == nil then
        return cfg, warnings
    end
    if type(user) ~= "table" then
        warnings[#warnings + 1] = "config.lua must return a table of settings; using the defaults"
        return cfg, warnings
    end
    local names = {}
    for name in pairs(user) do
        names[#names + 1] = tostring(name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local rule = RULES[name]
        local value = user[name]
        if not rule then
            warnings[#warnings + 1] = string.format(
                "Unknown setting %s in config.lua (check the spelling); ignored", name)
        else
            local ok, result, note = check(rule, value, keyTable)
            if ok then
                cfg[name] = result
                if note then
                    warnings[#warnings + 1] = string.format("%s = %s: %s", name, describe(value), note)
                end
            else
                warnings[#warnings + 1] = string.format("%s = %s %s; using the default, %s",
                    name, describe(value), result, describe(settings.DEFAULTS[name]))
            end
        end
    end
    return cfg, warnings
end

-- Whether two settings' values are the same (a value is a boolean, a number, a
-- string, or a list of numbers or strings).
local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- The settings in cfg that differ from those in `from` (the defaults if nil), for the
--- log: a list, sorted by name, of { name, value, was }, with value and was as texts.
function settings.changes(cfg, from)
    from = from or settings.DEFAULTS
    local names = {}
    for name in pairs(settings.DEFAULTS) do
        if not same(cfg[name], from[name]) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local changes = {}
    for i, name in ipairs(names) do
        changes[i] = { name = name, value = describe(cfg[name]), was = describe(from[name]) }
    end
    return changes
end

-- Half-Life's default sv_gravity. Its jump speed is fixed (the speed that reaches
-- 45 units at this gravity), so with less gravity you jump higher, as in Half-Life.
local HALF_LIFE_GRAVITY = 800

--- Physics parameters in centimetres, from the Half-Life values in the settings.
function settings.physics(cfg)
    local s = cfg.UnitScale
    local gravity = cfg.Gravity * s
    return {
        unitScale = s,
        maxSpeed = cfg.MaxSpeed * s,
        inputSpeed = cfg.InputSpeed * s,
        accelerate = cfg.Accelerate,
        airAccelerate = cfg.AirAccelerate,
        airSpeedCap = cfg.AirSpeedCap * s,
        friction = cfg.Friction,
        stopSpeed = cfg.StopSpeed * s,
        minSpeed = 0.1 * s,
        gravity = gravity,
        jumpSpeed = physics.jumpSpeed(HALF_LIFE_GRAVITY * s, cfg.JumpHeight * s),
        bhopCap = cfg.BhopCap,
        maxVelocity = cfg.MaxVelocity * s,
        -- Half-Life counts a player rising faster than 180 u/s as in the air, even on
        -- the ground: it is what lets slopes launch you.
        airborneSpeed = 180 * s,
        -- Half-Life's ground check looks this far below the player, once per update: a
        -- floor within it puts the player on the ground with its velocity as it is, so
        -- only a landing that no update ends this close to runs into the floor.
        groundCheck = 2 * s,
        -- Half-Life's player rests this far off a floor's plane, at right angles to it (its
        -- moves stop 1/32 unit short of a surface), and both the ground check's 2 units
        -- and whether a move reaches the floor are counted from that plane. Seen in
        -- Half-Life itself: on a level floor the player rests 0.03125 units above it.
        restHeight = s / 32,
        -- A slide up a slope flies off where the slope falls away under it, if it would
        -- rise this far above the new floor. Half-Life's ground layer is 2 units; on
        -- bumpy slopes that made strings of tiny launches and landings.
        leaveHeight = 8 * s,
        rate = cfg.PhysicsRate, -- updates per second; 0: one per frame
    }
end

return settings
