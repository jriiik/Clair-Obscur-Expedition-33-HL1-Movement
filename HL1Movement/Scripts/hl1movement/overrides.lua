-- Remembers the value a game property had before the mod changed it, so the mod
-- can put the game back the way it was when it switches off.

local ue = require("hl1movement.ue")

local Overrides = {}
Overrides.__index = Overrides

function Overrides.new()
    return setmetatable({ entries = {} }, Overrides)
end

--- Sets obj[name] = value. The first time a property is set, its current value
--- is remembered. Returns false if obj is not a usable object.
function Overrides:set(obj, name, value)
    local address = ue.address(obj)
    if not address then
        return false
    end
    local entry = self.entries[address]
    local fullName = ue.fullName(obj)
    if not entry or entry.fullName ~= fullName then
        -- New object, or a new object where an old one used to be: the old
        -- one is gone, so its values can't be put back anyway.
        entry = { obj = obj, fullName = fullName, saved = {}, order = {} }
        self.entries[address] = entry
    end
    if not entry.saved[name] then
        entry.saved[name] = { value = obj[name] }
        entry.order[#entry.order + 1] = name
    end
    obj[name] = value
    return true
end

--- Whether obj[name] has been set through this store.
function Overrides:has(obj, name)
    local entry = self.entries[ue.address(obj) or false]
    return entry ~= nil and entry.saved[name] ~= nil
end

function Overrides:isEmpty()
    return next(self.entries) == nil
end

--- Puts every remembered value back, newest change first. Objects that no longer
--- exist, or whose address now belongs to a different object, are skipped.
function Overrides:restore()
    for _, entry in pairs(self.entries) do
        local obj = entry.obj
        if ue.valid(obj) and ue.fullName(obj) == entry.fullName then
            for i = #entry.order, 1, -1 do
                local name = entry.order[i]
                pcall(function()
                    obj[name] = entry.saved[name].value
                end)
            end
        end
    end
    self.entries = {}
end

return Overrides
