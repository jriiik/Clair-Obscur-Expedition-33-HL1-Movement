-- luacheck settings: run `luacheck .` from the repository root.
std = "lua54"
max_line_length = 120

-- Globals UE4SS gives every Lua mod.
read_globals = {
    "RegisterHook",
    "RegisterKeyBind",
    "ExecuteInGameThread",
    "StaticFindObject",
    "FindFirstOf",
    "FName",
    "Key",
}

files["tests/"] = {
    -- The tests stand in for UE4SS, so they set its globals.
    globals = {
        "RegisterHook",
        "RegisterKeyBind",
        "ExecuteInGameThread",
        "StaticFindObject",
        "FindFirstOf",
        "FName",
        "Key",
        "ModRef",
        "TEST_ROOT",
        "print",
        "dofile",
    },
}
