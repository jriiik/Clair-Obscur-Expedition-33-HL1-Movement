-- Runs the mod's steps one by one, so that a step that fails can't stop the others.
--
-- Each step has a name that reads well in the log, such as "hiding the body". A
-- step that fails LIMIT times in a row is turned off until guard.reset(), and its
-- clean-up function (see guard.whenOff) puts back what it changed. Each different
-- error is written to the log once, up to MAX_LINES lines until the next reset.

local log = require("hl1movement.log")

local guard = {}

local LIMIT = 30
local MAX_LINES = 20

local steps = {} -- name -> { failures, total, off, lastError }
local cleanups = {} -- name -> function, run when the step is turned off
local logged = {} -- errors already written to the log
local lines = 0

--- What to tell the player when a step is turned off, for example
--- "Press F5 twice to try again". Set by main.lua.
guard.retryHint = "Turn the mod off and on to try again"

local function stepFor(name)
    local step = steps[name]
    if not step then
        step = { failures = 0, total = 0, off = false }
        steps[name] = step
    end
    return step
end

--- Sets the function that runs once when the step is turned off.
function guard.whenOff(name, fn)
    cleanups[name] = fn
end

--- Writes an error to the log, unless the same one is already there.
function guard.report(name, err)
    local message = tostring(err)
    local key = name .. "\0" .. message
    if logged[key] then
        return
    end
    logged[key] = true
    lines = lines + 1
    if lines <= MAX_LINES then
        log.warn("Error in %s: %s", name, message)
    elseif lines == MAX_LINES + 1 then
        log.warn("There are more errors; they aren't written to the log until the mod is turned off and on.")
    end
end

--- Runs fn(...) as the step `name`. Returns true and fn's first result, or false
--- and the error. A step that is turned off doesn't run and returns false.
function guard.run(name, fn, ...)
    local step = stepFor(name)
    if step.off then
        return false, "turned off"
    end
    local ok, result = pcall(fn, ...)
    if ok then
        step.failures = 0
        return true, result
    end
    step.failures = step.failures + 1
    step.total = step.total + 1
    step.lastError = tostring(result)
    guard.report(name, result)
    if step.failures >= LIMIT then
        step.off = true
        log.warn("Turned off %s after %d errors in a row (%s). %s, and please report UE4SS.log.",
            name, step.failures, step.lastError, guard.retryHint)
        local cleanup = cleanups[name]
        if cleanup then
            local cleaned, err = pcall(cleanup)
            if not cleaned then
                guard.report(name, err)
            end
        end
    end
    return false, result
end

--- Whether the step has been turned off.
function guard.isOff(name)
    local step = steps[name]
    return step ~= nil and step.off
end

--- Turns every step on again and forgets the errors, so they are logged again.
function guard.reset()
    steps = {}
    logged = {}
    lines = 0
end

--- The steps that have failed, for the diagnostics report.
function guard.status()
    local result = {}
    for name, step in pairs(steps) do
        if step.total > 0 then
            result[#result + 1] = { name = name, total = step.total, off = step.off, lastError = step.lastError }
        end
    end
    table.sort(result, function(a, b)
        return a.name < b.name
    end)
    return result
end

return guard
