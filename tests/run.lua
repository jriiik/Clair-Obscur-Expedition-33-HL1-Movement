-- Runs the tests with plain Lua 5.4, from the repository root:
--   lua5.4 tests/run.lua

local dofile = dofile -- the mod tests replace the global one
local root = (arg and arg[0] or ""):match("^(.-)tests[/\\]run%.lua$") or ""
package.path = root .. "HL1Movement/Scripts/?.lua;" .. root .. "tests/?.lua;" .. package.path

local t = require("testlib")
_G.TEST_ROOT = root

for _, name in ipairs({ "test_physics", "test_settings", "test_mod", "test_facing", "test_slopes" }) do
    t.section(name)
    local ok, err = pcall(dofile, root .. "tests/" .. name .. ".lua")
    if not ok then
        t.failed = t.failed + 1
        io.write("  FAIL could not run ", name, ": ", tostring(err), "\n")
    end
end

os.exit(t.finish() and 0 or 1)
