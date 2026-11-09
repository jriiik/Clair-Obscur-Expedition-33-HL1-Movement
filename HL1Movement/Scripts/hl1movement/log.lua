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

function log.reset()
    seen = {}
end

return log
