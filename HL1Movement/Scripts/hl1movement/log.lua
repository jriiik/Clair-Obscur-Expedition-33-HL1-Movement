-- Messages for UE4SS.log and the UE4SS console, all starting with the mod's name.

local log = {}

local PREFIX = "[HL1Movement] "
local seen = {}

log.debugEnabled = false

-- UE4SS's print doesn't end the line itself. Tests swap this function out.
local output = print

function log.setOutput(fn)
    output = fn
end

local function write(text)
    output(PREFIX .. text .. "\n")
end

function log.info(fmt, ...)
    write(string.format(fmt, ...))
end

function log.warn(fmt, ...)
    write("WARNING: " .. string.format(fmt, ...))
end

function log.debug(fmt, ...)
    if log.debugEnabled then
        write("debug: " .. string.format(fmt, ...))
    end
end

--- Logs a warning only the first time this key is used, so a problem that comes
--- back every frame doesn't fill the log.
function log.once(key, fmt, ...)
    if seen[key] then
        return
    end
    seen[key] = true
    log.warn(fmt, ...)
end

--- Logs a plain line only the first time this key is used. Used before the first
--- use of each kind of change to the game, so that if the game crashes, the last
--- line in UE4SS.log shows how far the mod got.
function log.first(key, fmt, ...)
    local id = "first:" .. key
    if seen[id] then
        return
    end
    seen[id] = true
    log.info(fmt, ...)
end

-- What each part of the mod is doing ("First person", "Half-Life movement" ...),
-- so that only changes are logged.
local states = {}
local stateLines = 0
local stateCounts = {}
local MAX_STATE_LINES = 200 -- until log.again()
local MAX_PER_STATE = 10 -- each different state text, until log.again()

--- Logs "<topic>: <text>" when the topic's text changes. Each different text is
--- logged at most MAX_PER_STATE times, and at most MAX_STATE_LINES in all, so a
--- state that flickers can't fill the log; log.again() starts both counts again.
--- force logs it even if it is the same as before, or has been logged often
--- (answering a key press, for example).
function log.state(topic, text, force)
    if states[topic] == text and not force then
        return
    end
    states[topic] = text
    local line = topic .. ": " .. text
    local count = (stateCounts[line] or 0) + 1
    stateCounts[line] = count
    if count > MAX_PER_STATE and not force then
        return
    end
    stateLines = stateLines + 1
    if stateLines < MAX_STATE_LINES then
        log.info("%s", line)
    elseif stateLines == MAX_STATE_LINES then
        log.info("(Further changes of state aren't logged.)")
    end
end

--- Starts the counts of the state lines again, for the reload key: in 0.3.0 the log
--- stopped saying that first person or the movement came back on after the fifth
--- time in a session. What each topic last said stays, so nothing is said twice.
function log.again()
    stateLines = 0
    stateCounts = {}
end

--- The last state text logged for a topic, or nil.
function log.stateOf(topic)
    return states[topic]
end

function log.reset()
    seen = {}
    states = {}
    stateLines = 0
    stateCounts = {}
end

return log
