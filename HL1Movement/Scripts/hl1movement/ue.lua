-- Safe helpers around UE4SS's Lua objects.
--
-- In UE4SS a failed lookup gives back an invalid object instead of nil, reading a
-- name an object doesn't have gives an invalid object too, and calling something
-- on the wrong kind of object raises an error. The mod goes through these helpers
-- so that a missing property or function never stops it.

local ue = {}

--- UE4SS's own type name for a value ("UObject", "FName", "TArray", "UScriptStruct",
--- "RemoteUnrealParam" ...), or Lua's type name for plain values.
function ue.typeOf(value)
    local t = type(value)
    if t ~= "userdata" then
        return t
    end
    local ok, name = pcall(function()
        return value:type()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return "userdata"
end

--- Hook parameters and array elements arrive wrapped. Returns the value inside.
function ue.unwrap(value)
    if type(value) == "userdata" then
        local t = ue.typeOf(value)
        if t == "RemoteUnrealParam" or t == "LocalUnrealParam" then
            return value:get()
        end
    end
    return value
end

--- Whether obj is a game object that still exists.
function ue.valid(obj)
    if type(obj) ~= "userdata" then
        return false
    end
    local ok, result = pcall(function()
        return obj:IsValid()
    end)
    return ok and result == true
end

--- The object's memory address, used to tell objects apart: in older UE4SS builds
--- two Lua wrappers of the same object never compare equal.
function ue.address(obj)
    if type(obj) ~= "userdata" then
        return nil
    end
    local ok, result = pcall(function()
        return obj:GetAddress()
    end)
    if ok and type(result) == "number" then
        return result
    end
    return nil
end

function ue.same(a, b)
    local x = ue.address(a)
    return x ~= nil and x == ue.address(b)
end

--- Short class name, for example "BP_jRPG_Character_World_C". Checks first that
--- obj is valid: UE4SS's GetClass on a null object crashes the game.
function ue.className(obj)
    if not ue.valid(obj) then
        return nil
    end
    local ok, name = pcall(function()
        return obj:GetClass():GetFName():ToString()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

--- Full name: the class name, a space and the object's path, for example
--- "SkeletalMeshComponent /Game/Maps/Town.Town:PersistentLevel.Hero_C_12.Mesh".
--- Used to check that an object at a remembered address is still the same object.
function ue.fullName(obj)
    if not ue.valid(obj) then
        return nil
    end
    local ok, name = pcall(function()
        return obj:GetFullName()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

--- obj[name], or nil if reading it fails.
function ue.get(obj, name)
    local ok, value = pcall(function()
        return obj[name]
    end)
    if ok then
        return value
    end
    return nil
end

function ue.number(obj, name)
    local value = ue.get(obj, name)
    if type(value) == "number" then
        return value
    end
    return nil
end

--- obj[name] if it is a game object that exists, else nil.
function ue.object(obj, name)
    local value = ue.get(obj, name)
    if ue.valid(value) then
        return value
    end
    return nil
end

--- Calls obj:name(...). Returns true and the result, or false and the error.
function ue.call(obj, name, ...)
    local count = select("#", ...)
    local args = { ... }
    return pcall(function()
        local fn = obj[name]
        return fn(obj, table.unpack(args, 1, count))
    end)
end

--- The elements of an array: a TArray property, or the table a call returned.
--- Elements are unwrapped at once, while they still point at live memory.
function ue.list(array)
    local result = {}
    local t = ue.typeOf(array)
    if t == "table" then
        for i = 1, #array do
            result[i] = ue.unwrap(array[i])
        end
    elseif t == "TArray" then
        array:ForEach(function(_, element)
            result[#result + 1] = ue.unwrap(element)
        end)
    end
    return result
end

--- X, Y and Z of a vector, whether it came back as a table or a struct.
function ue.vector(value)
    if value == nil then
        return 0, 0, 0
    end
    return tonumber(value.X) or 0, tonumber(value.Y) or 0, tonumber(value.Z) or 0
end

local found = {}

--- An object found by its path, such as "/Script/Engine.PrimitiveComponent".
--- Kept while it stays valid.
function ue.find(path)
    local cached = found[path]
    if cached and ue.valid(cached) then
        return cached
    end
    found[path] = nil
    local ok, obj = pcall(StaticFindObject, path)
    if ok and ue.valid(obj) then
        found[path] = obj
        return obj
    end
    return nil
end

local keys = {}

--- The object with this full name (see ue.fullName), if it still exists.
function ue.findByFullName(fullName)
    local path = type(fullName) == "string" and fullName:match("^%S+ (.+)$")
    if not path then
        return nil
    end
    local ok, obj = pcall(StaticFindObject, path)
    if ok and ue.valid(obj) and ue.fullName(obj) == fullName then
        return obj
    end
    return nil
end

--- An Unreal FKey for input checks, for example ue.fkey("SpaceBar").
function ue.fkey(name)
    local key = keys[name]
    if not key then
        key = { KeyName = FName(name) }
        keys[name] = key
    end
    return key
end

return ue
