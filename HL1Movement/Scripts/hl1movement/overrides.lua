-- Remembers the value a game property had before the mod changed it, so the mod
-- can put the game back the way it was when it switches off.
--
-- The game may write its own value while the mod is active: ALS sets a new
-- walking speed when the gait changes, Unreal resets the eye height. The mod
-- writes its value again, but remembers the game's new one, so that switching off
-- puts back what the game set last, as if the mod had never been there.
--
-- Every remembered value is also noted in the journal (see journal.lua), so a new
-- copy of the mod can put it back if UE4SS restarts its mods.

local ue = require("hl1movement.ue")
local journal = require("hl1movement.journal")

local Overrides = {}
Overrides.__index = Overrides

function Overrides.new()
    return setmetatable({ entries = {} }, Overrides)
end

-- Whether a value read back now is still the one the mod wrote. Numbers are
-- compared loosely: the game stores single-precision floats.
local function unchanged(current, written)
    if type(current) == "number" and type(written) == "number" then
        local scale = math.max(1, math.abs(current), math.abs(written))
        return math.abs(current - written) <= scale * 1e-5
    end
    local currentType, writtenType = ue.typeOf(current), ue.typeOf(written)
    if currentType == "FName" and writtenType == "FName" then
        local ok, same = pcall(function()
            return current:ToString() == written:ToString()
        end)
        return not ok or same
    end
    if type(current) == "userdata" or type(written) == "userdata" then
        return true -- can't tell, so keep the value remembered first
    end
    return current == written
end

local function forgetEntry(entry)
    for _, name in ipairs(entry.order) do
        journal.forget("prop", entry.fullName, name)
    end
end

--- Sets obj[name] = value. The first time a property is set, its current value
--- is remembered; later, a value the game wrote since the mod's last write
--- replaces it. Returns false if obj is not a usable object.
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
        if entry then
            forgetEntry(entry)
        end
        entry = { obj = obj, fullName = fullName, saved = {}, order = {} }
        self.entries[address] = entry
    end
    local slot = entry.saved[name]
    local current = obj[name]
    if not slot then
        slot = { value = current }
        entry.saved[name] = slot
        entry.order[#entry.order + 1] = name
        journal.note("prop", fullName, name, current)
    elseif not unchanged(current, slot.written) then
        slot.value = current
        journal.note("prop", fullName, name, current)
    end
    obj[name] = value
    -- Read back, so the game's rounding isn't later taken for a change by the game.
    slot.written = obj[name]
    return true
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
        forgetEntry(entry)
    end
    self.entries = {}
end

return Overrides
