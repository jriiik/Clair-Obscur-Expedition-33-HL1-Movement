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
local MAX_STATE_LINES = 200 -- per session
local MAX_PER_STATE = 5 -- each different state text

--- Logs "<topic>: <text>" when the topic's text changes. Each different text is
--- logged at most MAX_PER_STATE times, and at most MAX_STATE_LINES in all, so a
--- state that flickers can't fill the log.
function log.state(topic, text)
    if states[topic] == text then
        return
    end
    states[topic] = text
    local line = topic .. ": " .. text
    local count = (stateCounts[line] or 0) + 1
    stateCounts[line] = count
    if count > MAX_PER_STATE then
        return
    end
    stateLines = stateLines + 1
    if stateLines < MAX_STATE_LINES then
        log.info("%s", line)
    elseif stateLines == MAX_STATE_LINES then
        log.info("(Further changes of state aren't logged in this session.)")
    end
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
