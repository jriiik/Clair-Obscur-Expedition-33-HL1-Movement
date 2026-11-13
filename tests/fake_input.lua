-- The game's input for tests/fake_game.lua (one of its extensions, see "Extensions" there):
-- UE4SS's key binds with modifier keys, mouse-wheel notches, and Enhanced Input, with the
-- game's own locomotion context acting as ALS and E33 do. Loaded once a run by fake.newGame;
-- each game's state is in g.input.
--
-- - RegisterKeyBind(code, callback) and RegisterKeyBind(code, modifiers, callback), and the
--   ModifierKey table (SHIFT, CONTROL, ALT; options.noModifierKey: none, and no binds with
--   modifiers). g.press(code, modifiers) calls the bind with exactly the modifiers held, as
--   UE4SS does (options.fireEveryBind: every bind of the key whose modifiers are all held, in
--   the order they were made, as an older rule might), then runs a frame. The plain binds
--   stay in g.keybinds[code], the others under "code+CONTROL" and so on (g.bindFor).
-- - g.notch(name): a key pressed and let go before the frame hook (a wheel notch, a quick
--   tap): just pressed on the next frame, never down. A key that goes down in g.keys reads as
--   just pressed on that frame too. The mod's polls take key names without case, as FNames.
-- - Enhanced Input: the subsystem (SubsystemBlueprintLibrary), InputAction and
--   InputMappingContext for StaticConstructObject (with MapKey), the interface functions
--   AddMappingContext, RemoveMappingContext and HasMappingContext as UFunction objects called
--   with the subsystem first, and KismetInputLibrary's Key_IsValid and Key_IsAnalog. Passing
--   an object that isn't valid (the subsystem as the calling context too) is what crashes the
--   game: the call fails the test (g.extensionError). Each player controller has its
--   PlayerInput, whose EnhancedActionMappings is rebuilt at every add and removal: contexts
--   by priority, and a key that a context's consuming action holds is left out of every lower
--   context. With "ignore pressed keys until released", every mapping whose key is down then
--   is ignored until the key is up (g.input.losesIgnoreFlag, or options.inputLosesIgnoreFlag:
--   never, as an engine that loses the flag).
-- - The game: IMC_Locomotion_Default_ALS at priority 1, with SprintAction on LeftShift and the
--   right trigger (pressed: DesiredGait 2 and IsSprintRequested; released: 1 and false),
--   WalkAction on LeftControl and the left shoulder (pressed: walk and run in turn),
--   JumpAction on SpaceBar and the pad's A (the fake's own jump, through the point gameKey),
--   AimAction on the right mouse button (g.input.aiming while held). Events come from the
--   mappings in the list only: a mapping that goes while its key is held sends no release
--   (the action stays down until one of its mappings is pressed and let go), and so the
--   game's jump (g.jumpWasDown). A new controller has an empty list with the game's context
--   in it; options.battleRemovesLocomotion takes that away during a battle; g.input.dropAll()
--   drops every context, and the game adds its own again. g.collectGarbage frees the contexts
--   and actions StaticConstructObject made that no applied context uses.
-- - No object is made until the mod looks one of these up (StaticFindObject) or a test asks
--   (g.input.objects()): the fake's addresses, and with them its objects' names, stay those of
--   a game without this file, and so does every test that doesn't use it.
-- - Counts: g.input.calls (each function above), g.input.enumReads (the mod's reads of
--   DesiredGait), g.input.log (every add and removal with its options), g.input.fired (the
--   game's actions pressed).

local fake = require("fake_game")

local ext = {}

local IFACE = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:"
local MODIFIER_KEY = { SHIFT = 0x10, CONTROL = 0x11, ALT = 0x12 }
local MODIFIER_NAMES = { [0x10] = "SHIFT", [0x11] = "CONTROL", [0x12] = "ALT" }

-- The game's locomotion context: { action, key }, in the context's order.
local LOCOMOTION = {
    { "SprintAction", "LeftShift" }, { "SprintAction", "Gamepad_RightTrigger" },
    { "WalkAction", "LeftControl" }, { "WalkAction", "Gamepad_LeftShoulder" },
    { "JumpAction", "SpaceBar" }, { "JumpAction", "Gamepad_FaceButton_Bottom" },
    { "AimAction", "RightMouseButton" },
}
local EVENT_ACTIONS = { "SprintAction", "WalkAction", "AimAction" }

-- The paths the fake answers for (StaticFindObject), each built at the first lookup of any.
local PATHS = {
    ["/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"] = true,
    ["/Script/EnhancedInput.InputAction"] = true,
    ["/Script/EnhancedInput.InputMappingContext"] = true,
    ["/Engine/Transient"] = true,
    ["/Script/Engine.Default__SubsystemBlueprintLibrary"] = true,
    ["/Script/Engine.Default__KismetInputLibrary"] = true,
    [IFACE .. "AddMappingContext"] = true,
    [IFACE .. "RemoveMappingContext"] = true,
    [IFACE .. "HasMappingContext"] = true,
}

-- Unreal's key table (InputCoreTypes), lower case: what Key_IsValid accepts. Written out here
-- on its own, not taken from the mod's list, so that a slip in either shows.
local ENGINE_KEYS, ENGINE_AXES = {}, {}
do
    local digits = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
    local names = {}
    for _, digit in ipairs(digits) do
        names[#names + 1] = digit
        names[#names + 1] = "NumPad" .. digit
    end
    for c = string.byte("A"), string.byte("Z") do
        names[#names + 1] = string.char(c)
    end
    for i = 1, 12 do
        names[#names + 1] = "F" .. i
    end
    for _, name in ipairs({ "Up", "Down", "Left", "Right", "LeftShift", "RightShift", "LeftControl", "RightControl",
        "LeftAlt", "RightAlt", "LeftCommand", "RightCommand", "SpaceBar", "Enter", "Tab", "BackSpace", "CapsLock",
        "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Escape", "Pause", "NumLock", "ScrollLock",
        "Multiply", "Add", "Subtract", "Decimal", "Divide", "Semicolon", "Equals", "Comma", "Underscore", "Hyphen",
        "Period", "Slash", "Tilde", "LeftBracket", "Backslash", "RightBracket", "Apostrophe", "Ampersand",
        "Asterix", "Caret", "Colon", "Dollar", "Exclamation", "LeftParantheses", "RightParantheses", "Quote",
        "Section", "LeftMouseButton", "RightMouseButton", "MiddleMouseButton", "ThumbMouseButton",
        "ThumbMouseButton2", "MouseScrollUp", "MouseScrollDown", "Gamepad_FaceButton_Bottom",
        "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top", "Gamepad_LeftShoulder",
        "Gamepad_RightShoulder", "Gamepad_LeftTrigger", "Gamepad_RightTrigger", "Gamepad_LeftThumbstick",
        "Gamepad_RightThumbstick", "Gamepad_Special_Left", "Gamepad_Special_Right", "Gamepad_DPad_Up",
        "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right", "Gamepad_LeftStick_Up",
        "Gamepad_LeftStick_Down", "Gamepad_LeftStick_Left", "Gamepad_LeftStick_Right", "Gamepad_RightStick_Up",
        "Gamepad_RightStick_Down", "Gamepad_RightStick_Left", "Gamepad_RightStick_Right" }) do
        names[#names + 1] = name
    end
    for _, name in ipairs(names) do
        ENGINE_KEYS[name:lower()] = true
    end
    for _, name in ipairs({ "MouseX", "MouseY", "Mouse2D", "MouseWheelAxis", "Gamepad_LeftX", "Gamepad_LeftY",
        "Gamepad_Left2D", "Gamepad_RightX", "Gamepad_RightY", "Gamepad_Right2D", "Gamepad_LeftTriggerAxis",
        "Gamepad_RightTriggerAxis", "Gamepad_Special_Left_X", "Gamepad_Special_Left_Y" }) do
        ENGINE_KEYS[name:lower()] = true
        ENGINE_AXES[name:lower()] = true
    end
end

local function keyNameOf(key)
    assert(type(key) == "table" and key.KeyName ~= nil, "an FKey must be a table with KeyName")
    return assert(fake.nameOf(key.KeyName), "KeyName must be an FName")
end

local function isValidObject(obj)
    return obj:IsValid()
end

-- Whether the fake object is valid, without counting a read of the mod's.
local function valid(obj)
    if type(obj) ~= "userdata" then
        return false
    end
    local ok, result = pcall(isValidObject, obj)
    return ok and result == true
end

local function isDown(g, name)
    if g.keys[name] == true then
        return true
    end
    local lower = name:lower()
    for key, down in pairs(g.keys) do
        if down == true and key:lower() == lower then
            return true
        end
    end
    return false
end

-- What the game would do with an object that isn't valid: crash. Fails the test.
local function crash(g, what)
    g.input.crashes = g.input.crashes + 1
    local message = "the game would crash: " .. what
    g.extensionError = g.extensionError or message
    error(message, 0)
end

-- Records: an action { name, game, obj }, a context { name, path, mappings = { { action,
-- key } }, game, obj }, a player (one per controller) { applied = { { ctx, priority, order } },
-- list = the live mapping array, pi = its PlayerInput once made }.

local function sortedApplied(player)
    local list = {}
    for _, entry in ipairs(player.applied) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.order < b.order
    end)
    return list
end

local function fnameOf(g, name)
    local names = g.input.fnames
    names[name] = names[name] or fake.FName(name)
    return names[name]
end

-- Rebuilds a player's mapping list from its contexts (RebuildControlMappings).
local function rebuild(g, player, ignorePressed)
    local s = g.input
    local before = {}
    for _, m in ipairs(player.list) do
        before[m.id] = m
    end
    local list, blocked, now = {}, {}, {}
    for _, entry in ipairs(sortedApplied(player)) do
        local consumed = {}
        for i, m in ipairs(entry.ctx.mappings) do
            local lower = m.key:lower()
            if not blocked[lower] then
                local id = entry.ctx.id .. "|" .. i
                local was = before[id]
                local ignore = was and was.bShouldBeIgnored or false
                if ignorePressed and not s.losesIgnoreFlag and isDown(g, m.key) then
                    ignore = true
                end
                list[#list + 1] = { Key = { KeyName = fnameOf(g, m.key) }, Action = m.action.obj,
                    bShouldBeIgnored = ignore, id = id, name = m.key, action = m.action }
                now[id] = true
                consumed[#consumed + 1] = lower
            end
        end
        for _, lower in ipairs(consumed) do
            blocked[lower] = true
        end
    end
    -- A mapping that went while its key was held sends no release: its action stays down.
    for id, m in pairs(before) do
        if not now[id] and m.action.game and s.active[m.action.name] and isDown(g, m.name) then
            s.stuck[m.action.name] = true
        end
    end
    for i = #player.list, 1, -1 do
        player.list[i] = nil
    end
    for i, m in ipairs(list) do
        player.list[i] = m
    end
end

local function newContext(g, name, path, game)
    local s = g.input
    s.contexts = s.contexts + 1
    return { id = "ctx" .. s.contexts, name = name, path = path, mappings = {}, game = game }
end

local function newAction(name, path, game)
    return { name = name, path = path, game = game }
end

local function applied(player, ctx)
    for i, entry in ipairs(player.applied) do
        if entry.ctx == ctx then
            return entry, i
        end
    end
    return nil
end

local function playerOf(g)
    return g.input.players[fake.addressOf(g.pc)]
end

-- What the game does itself: adds or removes one of its contexts, with ALS's options
-- (ignore pressed keys until released: the 5.4 default).
local function gameAdd(g, player, ctx, priority)
    if not applied(player, ctx) then
        g.input.order = g.input.order + 1
        player.applied[#player.applied + 1] = { ctx = ctx, priority = priority, order = g.input.order }
    end
    rebuild(g, player, true)
end

local function gameRemove(g, player, ctx)
    local _, i = applied(player, ctx)
    if i then
        table.remove(player.applied, i)
    end
    rebuild(g, player, true)
end

-- The fake objects of a record: made once Enhanced Input is built (see build).
local function actionObject(g, action)
    if not action.obj then
        action.obj = fake.object({ className = "InputAction", name = action.name, path = action.path,
            props = { bConsumeInput = true, ValueType = 0, bTriggerWhenPaused = false,
                bConsumesActionAndAxisMappings = false } })
        g.input.records[action.obj] = action
    end
    return action.obj
end

local function contextObject(g, ctx)
    local s = g.input
    if not ctx.obj then
        ctx.obj = fake.object({ className = "InputMappingContext", name = ctx.name, path = ctx.path,
            props = { Mappings = fake.array({}) },
            methods = {
                MapKey = fake.ufunction("MapKey", 2, function(_, action, key)
                    s.calls.mapKey = s.calls.mapKey + 1
                    -- (At a reused address the object is another, which has no bConsumeInput.)
                    local record = s.records[action]
                    if not valid(action) or not record or not record.path
                        or fake.props(action).bConsumeInput == nil then
                        crash(g, "MapKey with an action that isn't valid")
                    end
                    local name = keyNameOf(key)
                    if s.mapKeyFails then
                        error("MapKey failed", 2)
                    end
                    ctx.mappings[#ctx.mappings + 1] = { action = record, key = name }
                    local mappings = fake.props(ctx.obj).Mappings
                    mappings[#mappings + 1] = { Action = action, Key = { KeyName = fnameOf(g, name) } }
                end),
            } })
        s.records[ctx.obj] = ctx
        for _, m in ipairs(ctx.mappings) do
            local mappings = fake.props(ctx.obj).Mappings
            mappings[#mappings + 1] = { Action = actionObject(g, m.action), Key = { KeyName = fnameOf(g, m.key) } }
        end
    end
    return ctx.obj
end

local function playerInput(player, pc)
    if not player.pi then
        local address = fake.addressOf(pc)
        player.pi = fake.object({ className = "EnhancedPlayerInput", name = "EnhancedPlayerInput_" .. address,
            path = "/Engine/Transient.GameEngine_2147482617:EnhancedPlayerInput_" .. address,
            props = { EnhancedActionMappings = player.list } })
        fake.set(pc, "PlayerInput", player.pi)
    end
end

-- A new controller (a new level): its own mapping list, with the game's context in it.
local function newPlayer(g)
    local s = g.input
    s.pcAddr = fake.addressOf(g.pc)
    local player = { applied = {}, list = fake.array({}) }
    s.players[s.pcAddr] = player
    if s.built then
        playerInput(player, g.pc)
    end
    gameAdd(g, player, s.locomotion, 1)
    return player
end

local function checkCall(g, sub, ctx, what)
    local s = g.input
    if not valid(sub) or sub ~= s.subsystem then
        crash(g, what .. " with a subsystem that isn't valid")
    end
    local record = valid(ctx) and s.records[ctx]
    if not record or not record.mappings or fake.props(ctx).Mappings == nil then
        crash(g, what .. " with a mapping context that isn't valid")
    end
    return record
end

local function logOptions(g, call, ctx, options)
    assert(type(options) == "table", call .. " needs FModifyContextOptions as a table")
    local entry = { call = call, ctx = ctx, mine = not ctx.game,
        ignore = options.bIgnoreAllPressedKeysUntilRelease == true,
        force = options.bForceImmediately == true, notify = options.bNotifyUserSettings == true,
        allThree = options.bIgnoreAllPressedKeysUntilRelease ~= nil and options.bForceImmediately ~= nil
            and options.bNotifyUserSettings ~= nil }
    local log = g.input.log
    log[#log + 1] = entry
    return entry
end

-- Makes the objects (once a game): the classes, the libraries, the subsystem, the interface's
-- functions, the game's context and actions, the controllers' PlayerInput.
local function build(g)
    local s = g.input
    if s.built then
        return
    end
    s.built = true
    local statics = g.statics
    local classes = {}
    for _, name in ipairs({ "EnhancedInputLocalPlayerSubsystem", "InputAction", "InputMappingContext" }) do
        classes[name] = fake.class(name)
        rawset(statics, "/Script/EnhancedInput." .. name, classes[name])
    end
    s.classes = classes
    s.transient = fake.object({ className = "Package", name = "Transient", path = "/Engine/Transient" })
    rawset(statics, "/Engine/Transient", s.transient)
    s.subsystem = fake.object({ className = "EnhancedInputLocalPlayerSubsystem",
        name = "EnhancedInputLocalPlayerSubsystem_2147482419",
        path = "/Engine/Transient.GameEngine_2147482617:LocalPlayer_2147482420."
            .. "EnhancedInputLocalPlayerSubsystem_2147482419" })
    rawset(statics, "/Script/Engine.Default__SubsystemBlueprintLibrary", fake.object({
        className = "SubsystemBlueprintLibrary", name = "Default__SubsystemBlueprintLibrary",
        path = "/Script/Engine.Default__SubsystemBlueprintLibrary", methods = {
            GetLocalPlayerSubSystemFromPlayerController = fake.ufunction("GetLocalPlayerSubSystemFromPlayerController",
                2, function(_, pc, class)
                    s.calls.subsystem = s.calls.subsystem + 1
                    if g.options.noInputSubsystem or not valid(pc) or class ~= classes.EnhancedInputLocalPlayerSubsystem
                    then
                        return fake.INVALID
                    end
                    return s.subsystem
                end),
        } }))
    rawset(statics, "/Script/Engine.Default__KismetInputLibrary", fake.object({ className = "KismetInputLibrary",
        name = "Default__KismetInputLibrary", path = "/Script/Engine.Default__KismetInputLibrary", methods = {
            Key_IsValid = fake.ufunction("Key_IsValid", 1, function(_, key)
                s.calls.isValid = s.calls.isValid + 1
                return ENGINE_KEYS[keyNameOf(key):lower()] == true
            end),
            Key_IsAnalog = fake.ufunction("Key_IsAnalog", 1, function(_, key)
                s.calls.isAnalog = s.calls.isAnalog + 1
                return ENGINE_AXES[keyNameOf(key):lower()] == true
            end),
        } }))

    -- The interface's functions, called with the subsystem first.
    local function interface(name, count, impl)
        local path = IFACE .. name
        rawset(statics, path, fake.object({ className = "Function", name = name, path = path,
            call = fake.ufunction(name, count, impl) }))
    end
    interface("AddMappingContext", 4, function(_, sub, ctx, priority, options)
        s.calls.add = s.calls.add + 1
        local record = checkCall(g, sub, ctx, "AddMappingContext")
        assert(math.type(priority) == "integer", "the priority is an int32")
        local entry = logOptions(g, "add", record, options)
        if s.addIgnored then
            return
        end
        local player = playerOf(g)
        local found = applied(player, record)
        if found then
            found.priority = priority
        else
            s.order = s.order + 1
            player.applied[#player.applied + 1] = { ctx = record, priority = priority, order = s.order }
        end
        rebuild(g, player, entry.ignore)
    end)
    interface("RemoveMappingContext", 3, function(_, sub, ctx, options)
        s.calls.remove = s.calls.remove + 1
        local record = checkCall(g, sub, ctx, "RemoveMappingContext")
        local entry = logOptions(g, "remove", record, options)
        local player = playerOf(g)
        local _, i = applied(player, record)
        if i then
            table.remove(player.applied, i)
        end
        rebuild(g, player, entry.ignore)
    end)
    interface("HasMappingContext", 3, function(_, sub, ctx, out)
        s.calls.has = s.calls.has + 1
        local record = checkCall(g, sub, ctx, "HasMappingContext")
        assert(type(out) == "table", "an out parameter needs a table")
        local entry = applied(playerOf(g), record)
        if s.hasLies or not entry then
            out.OutFoundPriority = -1
            return false
        end
        out.OutFoundPriority = entry.priority
        return true
    end)

    contextObject(g, s.locomotion)
    for _, player in pairs(s.players) do
        for _, m in ipairs(player.list) do
            m.Action = actionObject(g, m.action)
        end
    end
    local player = playerOf(g)
    if player then
        playerInput(player, g.pc)
    end
end

function ext.install(g)
    local s = {
        calls = { add = 0, remove = 0, has = 0, subsystem = 0, mapKey = 0, isValid = 0, isAnalog = 0, made = 0 },
        log = {}, -- every add and removal: { call, ctx (its record), mine, ignore, force, notify, allThree }
        players = {}, -- controller address -> { applied, list, pi }
        records = setmetatable({}, { __mode = "k" }), -- fake object -> its action's or context's record
        made = {}, -- the records of what StaticConstructObject made
        fnames = {},
        binds = {}, -- every RegisterKeyBind: { code, modifiers, id }, in order
        active = {}, -- the game's action name -> true while it is down
        stuck = {}, -- the game's action name -> true: down, its release lost
        fired = {}, -- the game's action name -> how many times it was pressed
        order = 0,
        contexts = 0,
        crashes = 0,
        enumReads = 0,
        aiming = false,
        losesIgnoreFlag = g.options.inputLosesIgnoreFlag == true,
        keysBefore = {},
        battle = false,
        built = false,
    }
    g.input = s
    rawset(_G, "ModifierKey", not g.options.noModifierKey and MODIFIER_KEY or nil)

    -- The game's context and actions (records; their objects come with build).
    s.locomotion = newContext(g, "IMC_Locomotion_Default_ALS",
        "/Game/ALS/Input/IMC_Locomotion_Default_ALS.IMC_Locomotion_Default_ALS", true)
    s.gameKeys = {}
    s.actions = {}
    for _, pair in ipairs(LOCOMOTION) do
        local name, key = pair[1], pair[2]
        s.actions[name] = s.actions[name] or newAction(name, "/Game/ALS/Input/" .. name .. "." .. name, true)
        s.locomotion.mappings[#s.locomotion.mappings + 1] = { action = s.actions[name], key = key }
        s.gameKeys[key] = name
    end
    g.gameJumpKeys = { "SpaceBar", "Gamepad_FaceButton_Bottom" }
    setmetatable(g.statics, { __index = function(statics, path)
        if PATHS[path] and not s.built then
            build(g)
            return rawget(statics, path)
        end
        return nil
    end })

    --- The objects, made now if they weren't (for tests that look at them first).
    function s.objects()
        build(g)
        return s
    end

    -- UE4SS's key binds, with modifier keys.
    _G.RegisterKeyBind = function(code, second, third)
        local modifiers, callback = {}, second
        if third ~= nil then
            assert(not g.options.noModifierKey, "RegisterKeyBind: this UE4SS takes no modifier keys")
            modifiers, callback = second, third
        end
        assert(type(code) == "number", "key code must be a number")
        assert(type(callback) == "function", "RegisterKeyBind needs a function")
        assert(type(modifiers) == "table", "the modifier keys must be a table")
        local names = {}
        for _, modifier in ipairs(modifiers) do
            names[#names + 1] = assert(MODIFIER_NAMES[modifier], "not a ModifierKey: " .. tostring(modifier))
        end
        table.sort(names)
        local id = #names == 0 and code or (code .. "+" .. table.concat(names, "+"))
        g.keybinds[id] = callback
        s.binds[#s.binds + 1] = { code = code, modifiers = names, id = id }
    end

    local function heldNames(held)
        local names = {}
        for _, modifier in ipairs(held or {}) do
            names[#names + 1] = MODIFIER_NAMES[modifier] or modifier
        end
        table.sort(names)
        return names
    end

    --- The bind for the key with exactly these modifiers (names or ModifierKey values).
    function g.bindFor(code, held)
        local names = heldNames(held)
        return g.keybinds[#names == 0 and code or (code .. "+" .. table.concat(names, "+"))]
    end

    --- Presses a hotkey with the modifiers held, then runs one frame.
    function g.press(code, held)
        local names = heldNames(held)
        if #names == 0 then
            local bind = assert(g.keybinds[code], "no key bind for " .. tostring(code))
            bind()
        elseif g.options.fireEveryBind then
            local isHeld, done = {}, {}
            for _, name in ipairs(names) do
                isHeld[name] = true
            end
            for _, bind in ipairs(s.binds) do
                local all = true
                for _, name in ipairs(bind.modifiers) do
                    all = all and isHeld[name] == true
                end
                local callback = g.keybinds[bind.id]
                if bind.code == code and all and callback and not done[bind.id] then
                    done[bind.id] = true
                    callback()
                end
            end
        else
            local bind = g.bindFor(code, names)
            if bind then
                bind()
            end
        end
        g.frame()
    end

    --- A key pressed and let go before the next frame hook: a wheel notch, or a quick tap.
    function g.notch(name)
        g.justPressed[name] = true
    end

    --- The game drops every context (as ClearAllMappings), then adds its own again.
    function s.dropAll()
        local player = playerOf(g)
        player.applied = {}
        rebuild(g, player, false)
        gameAdd(g, player, s.locomotion, 1)
    end

    --- A context of the game's own, applied now: { { action, key } ... }.
    function s.addGameContext(name, priority, list)
        build(g)
        local ctx = newContext(g, name, "/Game/Input/" .. name .. "." .. name, true)
        for _, pair in ipairs(list) do
            local action = s.actions[pair[1]] or newAction(pair[1], "/Game/Input/" .. pair[1] .. "." .. pair[1], true)
            s.actions[pair[1]] = action
            ctx.mappings[#ctx.mappings + 1] = { action = action, key = pair[2] }
            s.gameKeys[pair[2]] = s.gameKeys[pair[2]] or pair[1]
        end
        contextObject(g, ctx)
        gameAdd(g, playerOf(g), ctx, priority)
        for _, m in ipairs(playerOf(g).list) do
            m.Action = actionObject(g, m.action)
        end
        return ctx.obj
    end

    --- The contexts applied now, highest first: { name, priority, mine, obj }.
    function s.applied()
        local list = {}
        for _, entry in ipairs(sortedApplied(playerOf(g))) do
            list[#list + 1] = { name = entry.ctx.name, priority = entry.priority, mine = not entry.ctx.game,
                obj = entry.ctx.obj }
        end
        return list
    end

    --- The mapping list now: { key, action (the game's action's name, or "mod"), ignored }.
    function s.mappings()
        local list = {}
        for _, m in ipairs(playerOf(g).list) do
            list[#list + 1] = { key = m.name, action = m.action.game and m.action.name or "mod",
                ignored = m.bShouldBeIgnored }
        end
        return list
    end

    -- Garbage collection also frees the contexts and actions StaticConstructObject made that no
    -- applied context uses.
    local collect = g.collectGarbage
    function g.collectGarbage()
        collect()
        local used = {}
        for _, player in pairs(s.players) do
            for _, entry in ipairs(player.applied) do
                used[entry.ctx] = true
                for _, m in ipairs(entry.ctx.mappings) do
                    used[m.action] = true
                end
            end
        end
        for _, record in ipairs(s.made) do
            if record.obj and valid(record.obj) and not used[record] then
                fake.destroy(record.obj)
            end
        end
    end

    newPlayer(g)
end

function ext.character(g, c)
    if g.options.noGaitFields then
        return
    end
    -- ALS's EALSGait: Walking 0, Running 1, Sprinting 2; and E33's request to run. (The
    -- report reads DesiredGait: it shows 1 now, where the fake without this file has none.)
    fake.set(c.pawn, "DesiredGait", 1)
    fake.set(c.pawn, "IsSprintRequested", false)
    fake.onRead(c.pawn, "DesiredGait", function()
        g.input.enumReads = g.input.enumReads + 1
    end)
end

function ext.construct(g, className, outer)
    local s = g.input
    if className ~= "InputAction" and className ~= "InputMappingContext" then
        return nil
    end
    if s.constructFails and s.constructFails[className] then
        return false
    end
    s.calls.made = s.calls.made + 1
    local name = string.format("%s_%d", className, 2147480000 + s.calls.made)
    -- In the transient package (the outer the mod passes), or under another outer.
    local path = (outer == s.transient and "/Engine/Transient" or "/Engine/Transient.Other") .. "." .. name
    local record, obj
    if className == "InputAction" then
        record = newAction(name, path, false)
        obj = actionObject(g, record)
    else
        record = newContext(g, name, path, false)
        obj = contextObject(g, record)
    end
    s.made[#s.made + 1] = record
    return obj
end

-- The game's actions on its mappings, as ALS's controller and E33's character answer them.
local function actionEvent(g, action, pressed)
    local s = g.input
    local pawn = fake.props(g.pawn)
    if pressed then
        s.fired[action] = (s.fired[action] or 0) + 1
    end
    if action == "SprintAction" then
        if pawn.DesiredGait ~= nil then
            pawn.DesiredGait = pressed and 2 or 1
            pawn.IsSprintRequested = pressed
        end
    elseif action == "WalkAction" and pressed then
        if pawn.DesiredGait == 0 then
            pawn.DesiredGait = 1
        elseif pawn.DesiredGait == 1 then
            pawn.DesiredGait = 0
        end
    elseif action == "AimAction" then
        s.aiming = pressed
    end
end

-- Whether a mapping of the game's on the key is in the list and not ignored.
local function liveGameMapping(g, name)
    local lower = name:lower()
    for _, m in ipairs(playerOf(g).list) do
        if m.action.game and not m.bShouldBeIgnored and m.name:lower() == lower then
            return true
        end
    end
    return false
end

function ext.input(g)
    local s = g.input
    if fake.addressOf(g.pc) ~= s.pcAddr then
        newPlayer(g)
    end
    local player = playerOf(g)
    if g.options.battleRemovesLocomotion and (g.inBattle == true) ~= s.battle then
        s.battle = g.inBattle == true
        if s.battle then
            gameRemove(g, player, s.locomotion)
        else
            gameAdd(g, player, s.locomotion, 1)
        end
    end
    -- A key that went down since the last frame was just pressed too.
    local keysNow = {}
    for name, down in pairs(g.keys) do
        if down == true then
            keysNow[name] = true
            if not s.keysBefore[name] then
                g.justPressed[name] = true
            end
        end
    end
    s.keysBefore = keysNow
    -- Ignored mappings are free again once their key is up.
    for _, m in ipairs(player.list) do
        if m.bShouldBeIgnored and not isDown(g, m.name) then
            m.bShouldBeIgnored = false
        end
    end
    -- The game's actions, from the mappings in the list.
    for _, action in ipairs(EVENT_ACTIONS) do
        local down = false
        for _, m in ipairs(player.list) do
            if m.action.game and m.action.name == action and not m.bShouldBeIgnored and isDown(g, m.name) then
                down = true
            end
        end
        if s.stuck[action] then
            if down then
                s.stuck[action] = nil -- pressed on a mapping that is there: down, as it was
            end
        elseif down ~= (s.active[action] == true) then
            s.active[action] = down or nil
            actionEvent(g, action, down)
        end
    end
    -- The game's jump: a jump mapping that went while its key is held sends no release.
    if g.jumpWasDown then
        local live, held = false, false
        for _, name in ipairs(g.gameJumpKeys) do
            held = held or isDown(g, name)
            live = live or (isDown(g, name) and liveGameMapping(g, name))
        end
        if held and not live then
            g.jumpWasDown = false
        end
    end
end

function ext.gameKey(g, name, down)
    if not down or not g.input.gameKeys[name] then
        return down
    end
    return liveGameMapping(g, name)
end

function ext.poll(g, how, name, value)
    if value == true or (how == "analog" and value ~= 0) then
        return value
    end
    local lower = name:lower()
    local source = how == "down" and g.keys or (how == "pressed" and g.justPressed or g.analog)
    for key, v in pairs(source) do
        if key ~= name and type(key) == "string" and key:lower() == lower then
            if how == "analog" then
                return tonumber(v) or 0
            end
            return v == true
        end
    end
    return value
end

return ext
