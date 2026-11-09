-- A very small test library: t.test(name, fn) plus a few checks.

local t = { passed = 0, failed = 0, current = "" }

function t.section(name)
    t.current = name
    io.write("\n", name, "\n")
end

function t.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        t.passed = t.passed + 1
        io.write("  ok   ", name, "\n")
    else
        t.failed = t.failed + 1
        io.write("  FAIL ", name, "\n", "       ", (tostring(err):gsub("\n", "\n       ")), "\n")
    end
end

local function show(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

function t.eq(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "values differ", show(expected), show(actual)), 2)
    end
end

function t.near(actual, expected, tolerance, message)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-9) then
        error(string.format("%s: expected %s (+-%s), got %s", message or "numbers differ", show(expected),
            show(tolerance), show(actual)), 2)
    end
end

function t.truthy(value, message)
    if not value then
        error(message or "expected a true value", 2)
    end
end

function t.falsy(value, message)
    if value then
        error(message or "expected a false value", 2)
    end
end

--- Checks that some string in the list contains the text, and returns it.
function t.contains(lines, text, message)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return line
        end
    end
    error(string.format("%s: no line contains %q", message or "text not found", text), 2)
end

function t.absent(lines, text, message)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            error(string.format("%s: unexpected line %q", message or "text found", line), 2)
        end
    end
end

function t.finish()
    io.write(string.format("\n%d passed, %d failed\n", t.passed, t.failed))
    return t.failed == 0
end

return t
