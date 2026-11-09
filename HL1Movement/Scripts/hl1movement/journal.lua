-- A list of what the mod has changed in the game, kept where it survives UE4SS
-- restarting its mods.
--
-- UE4SS can restart its Lua mods while the game runs (from its console, or with
-- hot reload). That drops this copy of the mod without letting it put the game
-- back, and the new copy would then take the changed values for the game's own.
-- So every change is also written to a UE4SS shared variable, which outlives the
-- restart. The new copy reads it when it loads and, on its first frame, puts those
-- values back before it does anything else.
--
-- Each change is one line of tab-separated fields: the kind of change, the object's
-- full name, an id within the object (a property name, or how a part is hidden),
-- and the value to put back.

local ue = require("hl1movement.ue")

local journal = {}

local VARIABLE = "HL1Movement.changes"

local lines = {} -- key -> line
local dirty = false
local pending = nil -- lines a previous copy of the mod left, until they are put back

local function encode(value)
    local t = ue.typeOf(value)
    if t == "number" then
        return "n" .. string.format("%.17g", value)
    elseif t == "boolean" then
        return value and "b1" or "b0"
    elseif t == "string" then
        if value:find("[\t\n]") then
            return nil
        end
        return "s" .. value
    elseif t == "FName" then
        local ok, text = pcall(function()
            return value:ToString()
        end)
        if ok and type(text) == "string" and not text:find("[\t\n]") then
            return "f" .. text
        end
    end
    return nil
end

local function decode(text)
    local tag, rest = text:sub(1, 1), text:sub(2)
    if tag == "n" then
        return tonumber(rest)
    elseif tag == "b" then
        return rest == "1"
    elseif tag == "s" then
        return rest
    elseif tag == "f" then
        return FName(rest)
    end
    return nil
end

local function keyOf(kind, fullName, id)
    return kind .. "\t" .. fullName .. "\t" .. (id or "")
end

local function parse(line)
    return line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
end

--- Notes a change the mod must put back. kind is "prop" (id: the property name),
--- "hide" (id: "owner" or "hidden"), "tick", "curve" (value: the curve's full name)
--- or "style" (value: the camera style name); value is what to put back.
function journal.note(kind, fullName, id, value)
    if type(fullName) ~= "string" or fullName:find("[\t\n]") then
        return
    end
    local key = keyOf(kind, fullName, id)
    local encoded = encode(value)
    local line = encoded and (key .. "\t" .. encoded) or nil
    if lines[key] ~= line then
        lines[key] = line
        dirty = true
    end
end

--- Forgets a change once it has been put back, or can't be any more.
function journal.forget(kind, fullName, id)
    if type(fullName) ~= "string" then
        return
    end
    local key = keyOf(kind, fullName, id)
    if lines[key] then
        lines[key] = nil
        dirty = true
    end
end

--- Writes the list to the shared variable, if it changed since the last time.
function journal.flush()
    if not dirty then
        return
    end
    dirty = false
    local ref = rawget(_G, "ModRef")
    if ref == nil then
        return
    end
    local list = {}
    for _, line in pairs(lines) do
        list[#list + 1] = line
    end
    table.sort(list)
    pcall(function()
        ref:SetSharedVariable(VARIABLE, table.concat(list, "\n"))
    end)
end

--- Reads what a previous copy of the mod left changed. Returns how many changes.
function journal.load()
    local ref = rawget(_G, "ModRef")
    if ref == nil then
        return 0
    end
    local ok, text = pcall(function()
        return ref:GetSharedVariable(VARIABLE)
    end)
    if not ok or type(text) ~= "string" or text == "" then
        return 0
    end
    local list = {}
    for line in text:gmatch("[^\n]+") do
        local kind, fullName, id = parse(line)
        if kind then
            list[#list + 1] = line
            -- Kept in the list until put back, in case UE4SS restarts the mods again first.
            lines[keyOf(kind, fullName, id)] = line
        end
    end
    pending = #list > 0 and list or nil
    return #list
end

function journal.hasPending()
    return pending ~= nil
end

local restorers = {
    prop = function(obj, id, value)
        obj[id] = value
    end,
    hide = function(obj, id, value)
        if id == "owner" then
            obj:SetOwnerNoSee(value)
        else
            obj:SetHiddenInGame(value, false)
        end
    end,
    tick = function(obj, _, value)
        obj:SetComponentTickEnabled(value)
    end,
    curve = function(obj, _, value)
        local curve = ue.findByFullName(value)
        if not curve then
            error("the movement curve is gone")
        end
        local movementSettings = obj.CurrentMovementSettings
        if not ue.valid(movementSettings.MovementCurve) then
            movementSettings.MovementCurve = curve
        end
    end,
    style = function(obj, _, value)
        obj:ClientSetCameraMode(FName(value))
    end,
}

--- Puts back what a previous copy of the mod left changed. Must run on the game
--- thread. Returns how many changes were put back, and how many there were.
function journal.restorePending()
    local list = pending
    pending = nil
    if not list then
        return 0, 0
    end
    local restored = 0
    for _, line in ipairs(list) do
        local kind, fullName, id, encoded = parse(line)
        local restore = restorers[kind]
        local obj = restore and ue.findByFullName(fullName)
        if obj and pcall(restore, obj, id, decode(encoded)) then
            restored = restored + 1
        end
        local key = keyOf(kind, fullName, id)
        if lines[key] == line then
            lines[key] = nil
        end
    end
    dirty = true
    return restored, #list
end

--- How many changes are on the list, for the diagnostics report.
function journal.size()
    local count = 0
    for _ in pairs(lines) do
        count = count + 1
    end
    return count
end

return journal
