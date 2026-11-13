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
--- "field" (id: "<struct property>.<field>", one field of a struct property, such as
--- "NavAgentProps.bCanCrouch"), "hide" (id: "owner" or "hidden"), "tick", "curve" (value:
--- the curve's full name), "style" (value: the camera style name), "attach" (a camera
--- moved to the eyes; value: see journal.attachValue), "widget" (a widget the mod put on
--- the screen, taken off), or a kind a module registered with journal.restorer; value is
--- what to put back.
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

--- The value of an "attach" line: where a camera the mod moved to the eyes goes
--- back. move holds parentName (full name), socket, location {X, Y, Z}, rotation
--- {Pitch, Yaw, Roll}, usePawn, fov and focus (the last two may be nil).
function journal.attachValue(move)
    local function number(v)
        return v == nil and "" or string.format("%.9g", v)
    end
    return table.concat({ move.parentName or "", move.socket or "None",
        number(move.location.X), number(move.location.Y), number(move.location.Z),
        number(move.rotation.Pitch), number(move.rotation.Yaw), number(move.rotation.Roll),
        move.usePawn and "1" or "0", number(move.fov), number(move.focus) }, "|")
end

local function attachFields(value)
    local fields = {}
    for field in (value .. "|"):gmatch("([^|]*)|") do
        fields[#fields + 1] = field
    end
    return fields
end

local restorers = {
    prop = function(obj, id, value)
        obj[id] = value
    end,
    field = function(obj, id, value)
        local struct, field = id:match("^([^.]+)%.(.+)$")
        if not struct then
            error("not a field of a struct property: " .. id)
        end
        -- A table written to a struct property sets the fields it names, and only those.
        obj[struct] = { [field] = value }
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
    widget = function(obj)
        obj:RemoveFromParent() -- the speedometer
    end,
    attach = function(obj, _, value)
        local f = attachFields(value)
        local parent = f[1] ~= "" and ue.findByFullName(f[1])
        if parent then
            obj:K2_AttachToComponent(parent, FName(f[2]), 0, 0, 0, false) -- keep the relative transform
        end
        local location = { X = tonumber(f[3]) or 0, Y = tonumber(f[4]) or 0, Z = tonumber(f[5]) or 0 }
        local rotation = { Pitch = tonumber(f[6]) or 0, Yaw = tonumber(f[7]) or 0, Roll = tonumber(f[8]) or 0 }
        obj:K2_SetRelativeLocationAndRotation(location, rotation, false, {}, true)
        obj.bUsePawnControlRotation = f[9] == "1"
        if tonumber(f[10]) then
            obj:SetFieldOfView(tonumber(f[10]))
        end
        if tonumber(f[11]) then
            obj.FocusSettings = { FocusMethod = math.tointeger(tonumber(f[11])) or 0 }
        end
        if not parent then
            error("the camera's arm is gone")
        end
    end,
}

local builtIn = {}
for kind in pairs(restorers) do
    builtIn[kind] = true
end

--- Registers how a new copy of the mod puts back a kind of change of a module's own (one the
--- journal doesn't know, such as keys.lua's "context"): fn(obj, id, value), run on the game
--- thread with the object found again by its full name; an error leaves that change not put
--- back. The kinds above can't be replaced.
function journal.restorer(kind, fn)
    assert(type(kind) == "string" and kind ~= "" and not kind:find("[\t\n]"), "a kind is a name without tabs")
    assert(type(fn) == "function", "a restorer is a function")
    assert(not builtIn[kind], "the journal's own kind " .. kind .. " can't be replaced")
    restorers[kind] = fn
end

--- Puts back what a previous copy of the mod left changed. Must run on the game
--- thread. Returns how many changes were put back, and how many there were. seen, if
--- given, is called with the kind, full name and id of each change put back.
function journal.restorePending(seen)
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
            if seen then
                seen(kind, fullName, id)
            end
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
