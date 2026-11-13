-- luacheck settings: run `luacheck .` from the repository root.
std = "lua54"
max_line_length = 120

-- A review's scratch folder, if one is here: not part of the repository (.gitignore has it too).
exclude_files = { "probes/" }

-- Globals UE4SS gives every Lua mod.
read_globals = {
    "RegisterHook",
    "RegisterKeyBind",
    "ExecuteInGameThread",
    "StaticFindObject",
    "StaticConstructObject",
    "FindFirstOf",
    "FName",
    "FText",
    "Key",
    "ModifierKey", -- (the hotkeys' Ctrl and Shift; keys.lua reads it with rawget, as older UE4SS lack it)
}

files["tests/"] = {
    -- The tests stand in for UE4SS, so they set its globals.
    globals = {
        "RegisterHook",
        "RegisterKeyBind",
        "ExecuteInGameThread",
        "StaticFindObject",
        "StaticConstructObject",
        "FindFirstOf",
        "FName",
        "FText",
        "Key",
        "ModifierKey",
        "ModRef",
        "TEST_ROOT",
        "print",
        "loadfile",
    },
}
