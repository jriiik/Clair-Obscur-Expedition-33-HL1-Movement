-- A stand-in for UE4SS and for the parts of Expedition 33 the mod touches, so
-- main.lua can run in plain Lua 5.4.
--
-- Objects behave like UE4SS's: unknown names give an invalid object, writes to
-- unknown names are ignored, struct properties read as views and are written from
-- tables, reading a field a struct doesn't have raises an error, uint8 properties
-- take integers (a Lua boolean becomes 0), game functions check how many
-- parameters they get, out parameters are filled into the table passed for them,
-- and using an object after it was destroyed raises an error (in the real game
-- that would crash).
-- The fake character movement follows Unreal's closely enough (input acceleration,
-- braking, curve-driven ground values, gravity, landing) to check that the mod's
-- speeds survive it. The camera follows Unreal's rule: the view target's first
-- active camera component, in the order the components are listed, or the eyes
-- with the FirstPerson style.

local fake = {}

local realDofile = dofile
local data = setmetatable({}, { __mode = "k" })
local nextAddress = 0x10000
local byPath = {} -- path -> object, for StaticFindObject

--- Counts of what the mod asked of the fake game, for the cost test.
fake.counts = { calls = 0, fullNames = 0, reads = 0, writes = 0 }

-- UE4SS gives Lua full userdata. Pure Lua can't make one, but a closed file
-- handle is one, and debug.setmetatable gives it the behaviour wanted.
local function newUserdata(meta)
    local handle = assert(io.tmpfile())
    handle:close()
    debug.setmetatable(handle, meta)
    return handle
end

local INVALID = newUserdata({
    __index = function(_, key)
        if key == "IsValid" then
            return function()
                return false
            end
        elseif key == "type" then
            return function()
                return "UObject"
            end
        elseif key == "GetAddress" then
            return function()
                return 0
            end
        end
        error("used an invalid object: " .. tostring(key), 2)
    end,
    __newindex = function(_, key)
        error("wrote " .. tostring(key) .. " on an invalid object", 2)
    end,
})
fake.INVALID = INVALID

-- FName --------------------------------------------------------------------

local fnames = setmetatable({}, { __mode = "k" })
local fnameMeta = {
    __index = {
        type = function()
            return "FName"
        end,
        ToString = function(self)
            return fnames[self]
        end,
    },
    __eq = function(a, b)
        return fnames[a] ~= nil and fnames[a] == fnames[b]
    end,
}

function fake.FName(text)
    local name = newUserdata(fnameMeta)
    fnames[name] = text
    return name
end

function fake.nameOf(name)
    return fnames[name]
end

-- Hook parameters ----------------------------------------------------------

function fake.param(value)
    local function get()
        return value
    end
    return newUserdata({
        __index = {
            type = function()
                return "RemoteUnrealParam"
            end,
            get = get,
            Get = get,
        },
    })
end

-- Structs and arrays -------------------------------------------------------

function fake.struct(fields)
    local s = { __fields = {} }
    for name, value in pairs(fields) do
        s.__fields[name] = true
        s[name] = value
    end
    return s
end

function fake.vector(x, y, z)
    return fake.struct({ X = x or 0, Y = y or 0, Z = z or 0 })
end

function fake.array(list)
    local a = { __array = true }
    for i, v in ipairs(list) do
        a[i] = v
    end
    return a
end

local function structView(s)
    return newUserdata({
        __index = function(_, key)
            if key == "type" then
                return function()
                    return "UScriptStruct"
                end
            end
            if key == "__fields" or not s.__fields[key] then
                error("[handle_unreal_property_value]: Was unable to retrieve property '" .. tostring(key) .. "'", 2)
            end
            return s[key]
        end,
        __newindex = function(_, key, value)
            if s.__locked then
                error("[push_objectproperty] this struct can't be written", 2)
            end
            if s.__fields[key] then
                s[key] = value
            end
        end,
    })
end

local function arrayView(a)
    return newUserdata({
        __index = {
            type = function()
                return "TArray"
            end,
            GetArrayNum = function()
                return #a
            end,
            ForEach = function(_, fn)
                for i, v in ipairs(a) do
                    fn(i, fake.param(v))
                end
            end,
        },
    })
end

-- Objects --------------------------------------------------------------------

local function live(self, what)
    local d = data[self]
    if not d then
        error("not a fake object", 3)
    end
    if not d.alive then
        error("used a destroyed object: " .. d.className .. "." .. tostring(what), 3)
    end
    return d
end

local base = {}

function base.IsValid(self)
    local d = data[self]
    return d ~= nil and d.alive
end

function base.GetAddress(self)
    return data[self].address
end

function base.type(self)
    return data[self].typeName or "UObject"
end

function base.GetFullName(self)
    local d = live(self, "GetFullName")
    fake.counts.fullNames = fake.counts.fullNames + 1
    return d.className .. " " .. d.path
end

function base.GetFName(self)
    return fake.FName(live(self, "GetFName").name)
end

function base.GetClass(self)
    return fake.class(live(self, "GetClass").className)
end

function base.IsA(self, class)
    local d = live(self, "IsA")
    local wanted = data[class] and data[class].name
    for _, name in ipairs(d.chain) do
        if name == wanted then
            return true
        end
    end
    return false
end

function base.GetWorld(self)
    return live(self, "GetWorld").world or INVALID
end

local objectMeta = {}

objectMeta.__index = function(self, key)
    local d = data[self]
    if key == "IsValid" or key == "GetAddress" or key == "type" then
        return base[key]
    end
    live(self, key)
    local method = d.methods[key] or base[key]
    if method then
        return method
    end
    fake.counts.reads = fake.counts.reads + 1
    local getter = d.getters[key]
    if getter then
        return getter(self)
    end
    if d.props[key] ~= nil or d.declared[key] then
        local value = d.props[key]
        if type(value) == "table" and getmetatable(value) == nil then
            if d.breakOnRead[key] then
                error("reading " .. key .. " failed", 2)
            end
            if not d.views[key] then
                d.views[key] = value.__array and arrayView(value) or structView(value)
            end
            return d.views[key]
        end
        if d.breakOnRead[key] then
            error("reading " .. key .. " failed", 2)
        end
        return value
    end
    return INVALID
end

-- UE4SS writes a uint8 property with lua_tointeger, which gives 0 for anything
-- that isn't a whole number, true and false included.
local function toByte(value)
    local n
    if type(value) == "number" then
        n = math.tointeger(value)
    elseif type(value) == "string" then
        n = math.tointeger(tonumber(value) or 0)
    end
    return (n or 0) & 0xFF
end

objectMeta.__newindex = function(self, key, value)
    local d = live(self, key)
    fake.counts.writes = fake.counts.writes + 1
    if d.props[key] == nil and not d.declared[key] then
        d.unknownWrites[key] = true -- UE4SS ignores writes to names an object doesn't have
        return
    end
    d.writes[key] = (d.writes[key] or 0) + 1
    if d.bytes[key] then
        value = toByte(value)
    end
    local current = d.props[key]
    if type(current) == "table" and getmetatable(current) == nil and not current.__array then
        if type(value) ~= "table" then
            error("struct property " .. key .. " needs a table", 2)
        end
        for field, v in pairs(value) do
            if current.__fields[field] then
                current[field] = v
            end
        end
    else
        d.props[key] = value
    end
end

local classes = {}

function fake.object(spec)
    local obj = newUserdata(objectMeta)
    nextAddress = nextAddress + 0x100
    local declared = {}
    for _, name in ipairs(spec.declared or {}) do
        declared[name] = true
    end
    local bytes = {}
    for _, name in ipairs(spec.bytes or {}) do
        bytes[name] = true
    end
    local name = spec.name or string.format("%s_%X", spec.className, nextAddress)
    local path = spec.path or ("/Game/Levels/Fake.Fake:PersistentLevel." .. name)
    byPath[path] = obj
    data[obj] = {
        className = spec.className,
        name = name,
        path = path,
        chain = spec.chain or { spec.className },
        typeName = spec.typeName,
        props = spec.props or {},
        getters = spec.getters or {},
        declared = declared,
        bytes = bytes,
        methods = spec.methods or {},
        world = spec.world,
        alive = true,
        address = spec.address or nextAddress,
        writes = {},
        unknownWrites = {},
        views = {},
        breakOnRead = {},
    }
    return obj
end

function fake.class(name)
    if not classes[name] then
        classes[name] = fake.object({ className = "Class", name = name, typeName = "UClass",
            path = "/Script/Fake." .. name })
    end
    return classes[name]
end

function fake.props(obj)
    return data[obj].props
end

function fake.writes(obj)
    return data[obj].writes
end

function fake.set(obj, key, value)
    local d = data[obj]
    d.props[key] = value
    d.views[key] = nil
end

function fake.destroy(obj)
    data[obj].alive = false
end

--- A new object at the address of a destroyed one: in UE4SS a Lua object holds
--- only the address, so from now on old reads and writes the new object.
function fake.reuseAddress(old, new)
    data[old] = data[new]
end

--- A new object like obj, with the same class, values and functions, at a new
--- address: for example the player controller of a new level.
function fake.copy(obj)
    local d = data[obj]
    local props = {}
    for key, value in pairs(d.props) do
        props[key] = value
    end
    local copy = fake.object({ className = d.className, name = d.name .. "_Copy", chain = d.chain,
        typeName = d.typeName, props = props, getters = d.getters, methods = d.methods, world = d.world })
    data[copy].declared, data[copy].bytes = d.declared, d.bytes
    return copy
end

function fake.addressOf(obj)
    return data[obj].address
end

function fake.setWorld(obj, world)
    data[obj].world = world
end

function fake.breakOnRead(obj, key)
    data[obj].breakOnRead[key] = true
end

--- Replaces one of the object's game functions, for example to make it fail.
function fake.method(obj, name, fn)
    data[obj].methods[name] = fn
end

-- A game function: checks the parameter count, like UE4SS does.
local function ufunction(name, count, impl)
    return function(self, ...)
        local got = select("#", ...)
        if got ~= count then
            error(string.format("UFunction %s expected %d parameters, received %d", name, count, got), 2)
        end
        live(self, name)
        fake.counts.calls = fake.counts.calls + 1
        return impl(self, ...)
    end
end
fake.ufunction = ufunction

local function keyName(key)
    assert(type(key) == "table" and key.KeyName, "an FKey must be a table with KeyName")
    return assert(fake.nameOf(key.KeyName), "KeyName must be an FName")
end

local function copyVector(v)
    return { X = v.X, Y = v.Y, Z = v.Z }
end

local function same(a, b)
    return a ~= nil and b ~= nil and data[a] ~= nil and data[b] ~= nil and data[a].address == data[b].address
end

-- Attaching: AttachChildren arrays are changed in place, so the views UE4SS-style
-- reads hand out stay current.
local function detachChild(parent, child)
    local children = fake.props(parent).AttachChildren
    for i = #children, 1, -1 do
        if same(children[i], child) then
            table.remove(children, i)
        end
    end
end

local function attachChild(parent, child)
    local children = fake.props(parent).AttachChildren
    children[#children + 1] = child
end

-- The game -------------------------------------------------------------------

local CHARACTER = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_World.BP_jRPG_Character_World_C"
local CONTROLLER = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C"
local RESTART = "/Script/Engine.PlayerController:ClientRestart"

local PRIMITIVE_CHAIN = { "PrimitiveComponent", "SceneComponent", "ActorComponent", "Object" }
local CAMERA_CHAIN = { "CameraComponent", "SceneComponent", "ActorComponent", "Object" }
local CINE_CHAIN = { "CineCameraComponent", "CameraComponent", "SceneComponent", "ActorComponent", "Object" }

local function chainOf(first, rest)
    local chain = { first }
    for _, name in ipairs(rest) do
        chain[#chain + 1] = name
    end
    return chain
end

function fake.newGame(options)
    options = options or {}
    byPath = {}
    fake.counts = { calls = 0, fullNames = 0, reads = 0, writes = 0 }
    local g = {
        options = options,
        hooks = {},
        keybinds = {},
        shared = {}, -- UE4SS's shared variables, which outlive a restart of the mods
        functions = { [RESTART] = true },
        log = {},
        keys = {},
        justPressed = {},
        analog = {},
        position = { X = 0, Y = 0, Z = 0 },
        rotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        pending = { X = 0, Y = 0, Z = 0 },
        lastAcceleration = { X = 0, Y = 0, Z = 0 },
        cameraLocation = { X = 0, Y = 0, Z = 0 },
        -- In exploration the game shows Main_CineCamera; MainCamera stays inactive.
        cameraActive = { Main_CineCamera = true },
        inBattle = false,
        inDialogue = false,
        inCinematic = false,
        changingArea = false,
        inputLocked = false,
        moveIgnored = false,
        paused = false,
        rootMotion = false,
        limiterTicking = true,
        jumpCount = 0,
        gameJumps = 0,
        landings = 0,
        landingClamps = 0, -- speed caps at a landing (options.landingListenerClamps)
        shakeStops = 0,
        attachCalls = 0,
        engineAccelerated = false,
        inHook = false,
        time = 0,
        tickPath = CONTROLLER .. ":ReceiveTick",
        characterTickPath = CHARACTER .. ":ReceiveTick",
        jumpPath = CHARACTER .. ":JumpAction",
    }

    -- UE4SS's globals
    _G.print = function(text)
        g.log[#g.log + 1] = (tostring(text):gsub("\n$", ""))
    end
    _G.Key = { F5 = 0x74, F6 = 0x75, F7 = 0x76, F8 = 0x77, F9 = 0x78, SPACE = 0x20 }
    _G.FName = fake.FName
    _G.RegisterHook = function(path, callback)
        if g.inHook then
            -- In UE4SS this changes the list of hooks while it is being run.
            error("RegisterHook inside a hook", 2)
        end
        if not g.functions[path] then
            error("Tried to register a hook with Lua function 'RegisterHook' but no UFunction with the "
                .. "specified name was found.\nFunction Name: " .. path, 2)
        end
        g.hooks[path] = callback
        return 1, 2
    end
    _G.RegisterKeyBind = function(code, callback)
        assert(type(code) == "number", "key code must be a number")
        g.keybinds[code] = callback
    end
    _G.ExecuteInGameThread = function(fn)
        if options.executeInGameThreadBroken then
            error("ExecuteInGameThread: EngineTick method requested but EngineTick hook is not available "
                .. "(AOB scan failed)", 2)
        end
        fn()
    end
    local functionObjects = {}
    _G.StaticFindObject = function(path)
        local found = g.statics[path] or byPath[path]
        if not found and g.functions[path] then
            functionObjects[path] = functionObjects[path] or fake.object({ className = "Function",
                name = path:match("[^:]+$"), path = path })
            found = functionObjects[path]
        end
        if found and data[found].alive then
            return found
        end
        return INVALID
    end
    _G.ModRef = {
        SetSharedVariable = function(_, name, value)
            assert(type(name) == "string")
            assert(value == nil or type(value) == "string" or type(value) == "number" or type(value) == "boolean",
                "shared variables take only nil, booleans, numbers, strings and objects")
            g.shared[name] = value
        end,
        GetSharedVariable = function(_, name)
            return g.shared[name]
        end,
    }
    _G.FindFirstOf = function(name)
        if name == "PlayerController" then
            return g.pc
        end
        return INVALID
    end

    g.world = fake.object({ className = "World", name = "Level_Fake", path = "/Game/Levels/Fake.Level_Fake" })
    local world = g.world

    local statics = fake.object({ className = "GameplayStatics", name = "Default__GameplayStatics",
        path = "/Script/Engine.Default__GameplayStatics", methods = {
            IsGamePaused = ufunction("IsGamePaused", 1, function()
                return g.paused
            end),
        } })
    local GAME_KEYS = { JumpAction = { "SpaceBar", "Gamepad_FaceButton_Bottom" }, ForwardMovementAction = { "W" },
        RightMovementAction = { "D" } }
    local helpers = fake.object({ className = "InputBlueprintHelpers", name = "Default__InputBlueprintHelpers",
        path = "/Script/SandFall.Default__InputBlueprintHelpers", methods = {
            TryFindKeysForEnhancedInputActionName = ufunction("TryFindKeysForEnhancedInputActionName", 2,
                function(_, context, name)
                    assert(data[context], "needs a world context object")
                    local result = {}
                    for _, key in ipairs(GAME_KEYS[fake.nameOf(name)] or {}) do
                        result[#result + 1] = fake.param({ KeyName = fake.FName(key) })
                    end
                    return result
                end),
        } })
    g.statics = {
        ["/Script/Engine.PlayerController"] = fake.class("PlayerController"),
        ["/Script/Engine.PrimitiveComponent"] = fake.class("PrimitiveComponent"),
        ["/Script/Engine.ActorComponent"] = fake.class("ActorComponent"),
        ["/Script/Engine.CameraComponent"] = fake.class("CameraComponent"),
        ["/Script/Engine.SpringArmComponent"] = fake.class("SpringArmComponent"),
        ["/Script/Engine.Default__GameplayStatics"] = statics,
        ["/Script/SandFall.Default__InputBlueprintHelpers"] = helpers,
    }

    -- The game's dialogue and cinematic systems, on the controller
    g.dialogueSystem = fake.object({ className = "BP_DialogueSystemComponent_C", world = world, methods = {
        IsInDialogue = ufunction("IsInDialogue", 0, function()
            return g.inDialogue
        end),
    } })
    g.cinematicSystem = fake.object({ className = "BP_CinematicSystem_C", world = world,
        getters = { IsPlayingCinematic = function()
            return g.inCinematic
        end },
        methods = { IsInCinematicTransition = ufunction("IsInCinematicTransition", 0, function()
            return false
        end) } })

    -- Player controller and camera manager
    g.pc = fake.object({ className = "BP_jRPG_Controller_World_C", world = world,
        chain = { "BP_jRPG_Controller_World_C", "ALS_Player_Controller_C", "ALSPlayerController",
            "PlayerController", "Controller", "Actor", "Object" },
        declared = { "Pawn", "PlayerCameraManager", "CameraOverrideActor" },
        props = { BP_DialogueSystemComponent = g.dialogueSystem, BP_CinematicSystem = g.cinematicSystem },
        getters = { IsChangingArea = function()
            return g.changingArea
        end },
        methods = {
            IsInBattle = not options.noBattleFunctions and ufunction("IsInBattle", 0, function()
                return g.inBattle
            end) or nil,
            IsInBattleBeginTransition = not options.noBattleFunctions
                and ufunction("IsInBattleBeginTransition", 0, function()
                    return false
                end) or nil,
            IsMoveInputIgnored = ufunction("IsMoveInputIgnored", 0, function()
                return g.moveIgnored
            end),
            GetViewTarget = ufunction("GetViewTarget", 0, function()
                return g.viewTarget or g.pawn
            end),
            GetControlRotation = ufunction("GetControlRotation", 0, function()
                return { Pitch = g.rotation.Pitch, Yaw = g.rotation.Yaw, Roll = 0 }
            end),
            HasCameraOverride = ufunction("HasCameraOverride", 1, function(_, out)
                assert(type(out) == "table", "an out parameter needs a table")
                out.HasOverride = g.viewTarget ~= nil
            end),
            IsInputKeyDown = ufunction("IsInputKeyDown", 1, function(_, key)
                return not options.keyPollingBroken and g.keys[keyName(key)] == true
            end),
            WasInputKeyJustPressed = ufunction("WasInputKeyJustPressed", 1, function(_, key)
                return not options.keyPollingBroken and g.justPressed[keyName(key)] == true
            end),
            GetInputAnalogKeyState = ufunction("GetInputAnalogKeyState", 1, function(_, key)
                return g.analog[keyName(key)] or 0
            end),
            ClientSetCameraMode = ufunction("ClientSetCameraMode", 1, function(_, name)
                g.cameraStyle = assert(fake.nameOf(name), "ClientSetCameraMode needs an FName")
                if options.cameraStyleReflected then
                    fake.props(g.pcm).CameraStyle = name
                end
            end),
        } })
    g.cameraStyle = "Default"

    g.limiterModifier = fake.object({ className = "BP_CameraModifier_RotationLimiter_Default_C",
        chain = { "BP_CameraModifier_RotationLimiter_Default_C", "CameraModifier_RotationLimiter",
            "CameraModifier", "Object" },
        props = { PitchMin = -50, PitchMax = 30 } })
    g.shakeModifier = fake.object({ className = "CameraModifier_CameraShake",
        chain = { "CameraModifier_CameraShake", "CameraModifier", "Object" }, props = { Alpha = 1 } })
    g.pcm = fake.object({ className = "BP_PlayerCameraManager_C", world = world,
        chain = { "BP_PlayerCameraManager_C", "ExtendedPlayerCameraManager", "PlayerCameraManager", "Actor", "Object" },
        props = { CameraStyle = options.cameraStyleReflected and fake.FName("Default") or nil,
            DefaultFOV = 90, ViewPitchMin = -60, ViewPitchMax = 40,
            bAlwaysApplyModifiers = false, ModifierList = fake.array({ g.limiterModifier, g.shakeModifier }),
            -- While the camera manager blends to a new view target, that one is the
            -- pending view target (tests set PendingViewTarget.Target); the game's view
            -- target is in g.viewTarget.
            ViewTarget = fake.struct({ Target = INVALID }), PendingViewTarget = fake.struct({ Target = INVALID }) },
        methods = {
            GetCameraLocation = ufunction("GetCameraLocation", 0, function()
                return copyVector(g.cameraLocation)
            end),
            GetFOVAngle = ufunction("GetFOVAngle", 0, function()
                return fake.props(g.pcm).DefaultFOV
            end),
            StopAllCameraShakes = ufunction("StopAllCameraShakes", 1, function(_, immediately)
                assert(type(immediately) == "boolean")
                g.shakeStops = g.shakeStops + 1
            end),
        } })
    fake.set(g.pc, "PlayerCameraManager", g.pcm)

    -- ALS's movement curve, an asset all characters share
    g.curve = fake.object({ className = "CurveVector", name = "C_ALS_Movement_Normal",
        path = "/Game/ALS/Curves/C_ALS_Movement_Normal.C_ALS_Movement_Normal" })

    -- The character, its parts and its movement component
    function g.buildCharacter()
        local c = { attach = {} }
        local function primitive(className, owner, props, methods)
            props = props or {}
            props.AttachChildren = props.AttachChildren or fake.array({})
            if props.bOwnerNoSee == nil then
                props.bOwnerNoSee = false
            end
            if props.bHiddenInGame == nil then
                props.bHiddenInGame = false
            end
            methods = methods or {}
            local obj
            methods.GetOwner = ufunction("GetOwner", 0, function()
                return owner() or INVALID
            end)
            methods.SetOwnerNoSee = ufunction("SetOwnerNoSee", 1, function(_, value)
                assert(type(value) == "boolean")
                fake.props(obj).bOwnerNoSee = value
            end)
            methods.SetHiddenInGame = ufunction("SetHiddenInGame", 2, function(_, value)
                assert(type(value) == "boolean")
                fake.props(obj).bHiddenInGame = value
            end)
            obj = fake.object({ className = className, world = world, chain = chainOf(className, PRIMITIVE_CHAIN),
                props = props, methods = methods })
            return obj
        end
        local function scene(className, owner, props, methods)
            props = props or {}
            props.AttachChildren = props.AttachChildren or fake.array({})
            methods = methods or {}
            methods.GetOwner = ufunction("GetOwner", 0, function()
                return owner() or INVALID
            end)
            return fake.object({ className = className, world = world,
                chain = { className, "SceneComponent", "ActorComponent", "Object" }, props = props, methods = methods })
        end
        local function thePawn()
            return c.pawn
        end

        -- Where a camera is in the world: on the spring arm, behind the character;
        -- attached to the capsule, at the capsule plus its relative location.
        function c.cameraAt(cam)
            local pos = g.position
            local link = c.attach[cam]
            local relative = fake.props(cam).RelativeLocation
            if link and same(link.parent, c.capsule) then
                return { X = pos.X + relative.X, Y = pos.Y + relative.Y, Z = pos.Z + relative.Z }
            elseif link and same(link.parent, c.springArm) then
                return { X = pos.X - 300, Y = pos.Y, Z = pos.Z + 150 }
            end
            return { X = pos.X, Y = pos.Y, Z = pos.Z }
        end

        --- The game attaching one of its cameras somewhere (also used to set them up).
        function c.attachTo(cam, parent, socket)
            local link = c.attach[cam]
            if link then
                detachChild(link.parent, cam)
            end
            attachChild(parent, cam)
            c.attach[cam] = { parent = parent, socket = socket or "None" }
        end

        local function camera(className, name, chain, props)
            local obj
            props = props or {}
            props.AttachChildren = fake.array({})
            props.RelativeLocation = fake.struct({ X = 0, Y = 0, Z = 0 })
            props.RelativeRotation = fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 })
            props.FieldOfView = props.FieldOfView or 85
            props.bUsePawnControlRotation = false
            props.bAutoActivate = true
            props.PostProcessBlendWeight = 1
            local getters = {}
            if not options.noIsActiveProperty then
                getters.bIsActive = function()
                    return g.cameraActive[name] == true
                end
            end
            obj = fake.object({ className = className, name = name, world = world, chain = chain, props = props,
                getters = getters,
                path = string.format("/Game/Levels/Fake.Fake:PersistentLevel.Character_%X.%s", nextAddress, name),
                methods = {
                    IsActive = ufunction("IsActive", 0, function()
                        return g.cameraActive[name] == true
                    end),
                    GetOwner = ufunction("GetOwner", 0, thePawn),
                    GetAttachParent = ufunction("GetAttachParent", 0, function()
                        local link = c.attach[obj]
                        return link and link.parent or INVALID
                    end),
                    GetAttachSocketName = ufunction("GetAttachSocketName", 0, function()
                        local link = c.attach[obj]
                        return fake.FName(link and link.socket or "None")
                    end),
                    K2_AttachToComponent = ufunction("K2_AttachToComponent", 6,
                        function(_, parent, socket, locationRule, rotationRule, scaleRule, weld)
                            assert(data[parent], "attach to a component")
                            assert(fake.nameOf(socket), "the socket must be an FName")
                            assert(math.type(locationRule) == "integer" and math.type(rotationRule) == "integer"
                                and math.type(scaleRule) == "integer", "attachment rules are integers")
                            assert(type(weld) == "boolean")
                            if options.attachIgnored then
                                return false
                            end
                            g.attachCalls = g.attachCalls + 1
                            c.attachTo(obj, parent, fake.nameOf(socket))
                            local p = fake.props(obj)
                            if locationRule == 2 then
                                p.RelativeLocation.X, p.RelativeLocation.Y, p.RelativeLocation.Z = 0, 0, 0
                            end
                            if rotationRule == 2 then
                                local r = p.RelativeRotation
                                r.Pitch, r.Yaw, r.Roll = 0, 0, 0
                            end
                            return true
                        end),
                    K2_SetRelativeLocationAndRotation = ufunction("K2_SetRelativeLocationAndRotation", 5,
                        function(_, location, rotation, sweep, hit, teleport)
                            assert(type(location) == "table" and type(rotation) == "table")
                            assert(type(sweep) == "boolean" and type(teleport) == "boolean")
                            assert(type(hit) == "table", "the hit result is an out parameter: it needs a table")
                            local p = fake.props(obj)
                            local l, r = p.RelativeLocation, p.RelativeRotation
                            l.X, l.Y, l.Z = location.X or 0, location.Y or 0, location.Z or 0
                            r.Pitch, r.Yaw, r.Roll = rotation.Pitch or 0, rotation.Yaw or 0, rotation.Roll or 0
                        end),
                    SetFieldOfView = ufunction("SetFieldOfView", 1, function(_, fov)
                        assert(type(fov) == "number")
                        fake.props(obj).FieldOfView = fov
                    end),
                    K2_GetComponentLocation = ufunction("K2_GetComponentLocation", 0, function()
                        return c.cameraAt(obj)
                    end),
                } })
            return obj
        end

        c.skinActor = fake.object({ className = "BP_CharacterSkinBase_C", world = world,
            chain = { "BP_CharacterSkinBase_C", "Actor", "Object" },
            methods = { GetOwner = ufunction("GetOwner", 0, function()
                return c.pawn
            end) } })
        c.propActor = fake.object({ className = "BP_Torch_C", world = world,
            chain = { "BP_Torch_C", "Actor", "Object" },
            methods = { GetOwner = ufunction("GetOwner", 0, function()
                return INVALID
            end) } })

        c.torchLight = fake.object({ className = "PointLightComponent", world = world,
            chain = { "PointLightComponent", "LightComponent", "SceneComponent", "ActorComponent", "Object" },
            props = { AttachChildren = fake.array({}), bHiddenInGame = false } })
        c.skinMesh = primitive("SkeletalMeshComponent", function()
            return c.skinActor
        end)
        c.propMesh = primitive("StaticMeshComponent", function()
            return c.propActor
        end, { AttachChildren = fake.array({ c.torchLight }) })
        c.mesh = primitive("SkeletalMeshComponent", thePawn,
            { AttachChildren = fake.array({ c.skinMesh, c.propMesh }) })
        c.dialogueCamera = camera("CineCameraComponent", "CineCamera_Dialogue1", CINE_CHAIN,
            { FocusSettings = fake.struct({ FocusMethod = 1, ManualFocusDistance = 200 }), CurrentFocalLength = 35 })
        c.cineCamera = camera("CineCameraComponent", "Main_CineCamera", CINE_CHAIN,
            { FocusSettings = fake.struct({ FocusMethod = 1, ManualFocusDistance = 300 }), CurrentFocalLength = 20,
                bOverride_CustomNearClippingPlane = false, CustomNearClippingPlane = 10 })
        c.mainCamera = camera("CameraComponent", "MainCamera", CAMERA_CHAIN)
        c.springArm = scene("SpringArmComponent", thePawn, { TargetArmLength = 300 })
        c.capsule = primitive("CapsuleComponent", thePawn, { bHiddenInGame = true }, {
            GetScaledCapsuleHalfHeight = ufunction("GetScaledCapsuleHalfHeight", 0, function()
                return 96
            end),
            GetScaledCapsuleRadius = ufunction("GetScaledCapsuleRadius", 0, function()
                return 35
            end),
        })
        fake.props(c.capsule).AttachChildren = fake.array({ c.mesh, c.springArm })
        c.attachTo(c.dialogueCamera, c.capsule)
        c.attachTo(c.cineCamera, c.springArm, "SpringEndpoint")
        c.attachTo(c.mainCamera, c.springArm, "SpringEndpoint")
        c.cameras = { c.dialogueCamera, c.cineCamera, c.mainCamera } -- in the engine's order

        c.limiter = fake.object({ className = "BP_VelocityControllerComponent_C", world = world,
            chain = { "BP_VelocityControllerComponent_C", "ActorComponent", "Object" },
            methods = {
                IsComponentTickEnabled = ufunction("IsComponentTickEnabled", 0, function()
                    return g.limiterTicking
                end),
                SetComponentTickEnabled = ufunction("SetComponentTickEnabled", 1, function(_, value)
                    assert(type(value) == "boolean")
                    g.limiterTicking = value
                end),
            } })
        c.cameraController = fake.object({ className = "BP_CameraControllerComponent_C", world = world,
            chain = { "BP_CameraControllerComponent_C", "ActorComponent", "Object" },
            props = { ApplyCameraConfigs = true, IsCameraRecentering = false, EnableDynamicCameraFocus = true,
                EnableCameraShakeWhenMoving = true },
            methods = { IsComponentTickEnabled = ufunction("IsComponentTickEnabled", 0, function()
                return true
            end) } })
        c.curve = g.curve

        local movementSettings = fake.struct({ WalkSpeed = 175, RunSpeed = 375, SprintSpeed = 650,
            MovementCurve = c.curve, RotationRateCurve = false })
        movementSettings.__locked = options.curveLocked
        c.cmc = fake.object({ className = "ALSCharacterMovementComponent", name = "CharMoveComp", world = world,
            path = string.format("/Game/Levels/Fake.Fake:PersistentLevel.Character_%X.CharMoveComp", nextAddress),
            bytes = { "bRequestMovementSettingsChange" },
            chain = { "ALSCharacterMovementComponent", "CharacterMovementComponent", "PawnMovementComponent",
                "NavMovementComponent", "MovementComponent", "ActorComponent", "Object" },
            props = {
                MovementMode = 1,
                Velocity = fake.vector(0, 0, 0),
                MaxWalkSpeed = 600,
                MaxWalkSpeedCrouched = 300,
                MaxAcceleration = 1500,
                GroundFriction = 8,
                BrakingDecelerationWalking = 2048,
                BrakingDecelerationFalling = 0,
                BrakingFrictionFactor = 0,
                bUseSeparateBrakingFriction = false,
                BrakingFriction = 0,
                FallingLateralFriction = 0,
                GravityScale = 1,
                JumpZVelocity = 450,
                AirControl = 0.35,
                MaxStepHeight = 45,
                bStayBasedInAir = options.stayBasedInAir == true,
                bRequestMovementSettingsChange = 0, -- a uint8 in ALS
                CurrentMovementSettings = movementSettings,
            },
            methods = {
                SetMovementMode = ufunction("SetMovementMode", 2, function(_, mode, custom)
                    assert(math.type(mode) == "integer" and math.type(custom) == "integer")
                    local p = fake.props(c.cmc)
                    local was = p.MovementMode
                    p.MovementMode = mode
                    -- Leaving a moving platform adds its velocity (while walking,
                    -- Velocity is relative to it), unless the character stays based on
                    -- it in the air.
                    local platform = g.baseVelocity
                    local v = p.Velocity
                    if mode == 3 and (was == 1 or was == 2) and platform and not p.bStayBasedInAir then
                        v.X, v.Y, v.Z = v.X + platform.X, v.Y + platform.Y, v.Z + platform.Z
                    end
                    -- Listeners of the movement mode change, such as the game's speed limiter.
                    if options.limiterWakesOnModeChange then
                        g.limiterTicking = true
                    end
                    if options.jumpListenerClamps then
                        local s = math.sqrt(v.X * v.X + v.Y * v.Y)
                        if s > 650 then
                            v.X, v.Y = v.X / s * 650, v.Y / s * 650
                        end
                    end
                end),
                GetMaxBrakingDeceleration = ufunction("GetMaxBrakingDeceleration", 0, function()
                    local p = fake.props(c.cmc)
                    local walking = p.MovementMode == 1 or p.MovementMode == 2
                    if walking and p.CurrentMovementSettings.MovementCurve then
                        return 2000
                    end
                    return walking and p.BrakingDecelerationWalking or p.BrakingDecelerationFalling
                end),
                GetMaxAcceleration = ufunction("GetMaxAcceleration", 0, function()
                    local p = fake.props(c.cmc)
                    if p.MovementMode == 1 and p.CurrentMovementSettings.MovementCurve then
                        return 1200
                    end
                    return p.MaxAcceleration
                end),
                GetMaxSpeed = ufunction("GetMaxSpeed", 0, function()
                    local p = fake.props(c.cmc)
                    if options.maxSpeedIgnoresWalkSpeed then
                        return p.CurrentMovementSettings.SprintSpeed
                    end
                    return p.MaxWalkSpeed
                end),
                GetGravityZ = ufunction("GetGravityZ", 0, function()
                    return -980 * fake.props(c.cmc).GravityScale
                end),
                GetCurrentAcceleration = ufunction("GetCurrentAcceleration", 0, function()
                    return copyVector(g.lastAcceleration)
                end),
                GetImpartedMovementBaseVelocity = ufunction("GetImpartedMovementBaseVelocity", 0, function()
                    -- The platform's velocity, while the character is based on it: on the
                    -- ground, and in the air with bStayBasedInAir.
                    local p = fake.props(c.cmc)
                    local mode = p.MovementMode
                    if (mode == 1 or mode == 2 or (mode == 3 and p.bStayBasedInAir)) and g.baseVelocity then
                        return copyVector(g.baseVelocity)
                    end
                    return { X = 0, Y = 0, Z = 0 }
                end),
            } })
        if options.breakVelocity then
            fake.breakOnRead(c.cmc, "Velocity")
        end

        c.pawn = fake.object({ className = "BP_jRPG_Character_World_C",
            name = "BP_jRPG_Character_World_C_" .. nextAddress, world = world,
            chain = { "BP_jRPG_Character_World_C", "ALS_CharacterBP_C", "ALSCharacter", "ALSBaseCharacter",
                "Character", "Pawn", "Actor", "Object" },
            props = {
                BaseEyeHeight = 64,
                JumpMaxHoldTime = 0.2,
                JumpMaxCount = 1,
                bIsWorldMapPawn = options.worldMap == true,
                bFindCameraComponentWhenViewTarget = true,
                TargetRotation = fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 }),
                CharacterMovement = c.cmc,
                CapsuleComponent = c.capsule,
                RootComponent = c.capsule,
                MainCamera = c.mainCamera,
                Main_CineCamera = c.cineCamera,
                BP_CameraControllerComponent = c.cameraController,
                BP_VelocityControllerComponent = not options.noLimiterProperty and c.limiter or nil,
                Controller = g.pc,
            },
            methods = {
                ConsumeMovementInputVector = ufunction("ConsumeMovementInputVector", 0, function()
                    local v = g.pending
                    g.pending = { X = 0, Y = 0, Z = 0 }
                    return v
                end),
                GetPendingMovementInputVector = ufunction("GetPendingMovementInputVector", 0, function()
                    return copyVector(g.pending)
                end),
                CanAddMovementInput = ufunction("CanAddMovementInput", 0, function()
                    return not g.inputLocked
                end),
                IsPlayingRootMotion = ufunction("IsPlayingRootMotion", 0, function()
                    return g.rootMotion
                end),
                K2_GetActorLocation = ufunction("K2_GetActorLocation", 0, function()
                    return copyVector(g.position)
                end),
                K2_SetActorRotation = ufunction("K2_SetActorRotation", 2, function(_, rotation, teleport)
                    assert(type(rotation) == "table" and type(rotation.Yaw) == "number")
                    assert(type(teleport) == "boolean")
                    g.actorYaw = rotation.Yaw
                    return true
                end),
                GetMainCamera = not options.noGetMainCamera and ufunction("GetMainCamera", 1, function(_, out)
                    assert(type(out) == "table", "an out parameter needs a table")
                    -- UE4SS fills it under the parameter's own name (SDK dumps show MainCamera_0).
                    out.MainCamera = c.cineCamera
                end) or nil,
                K2_GetComponentsByClass = ufunction("K2_GetComponentsByClass", 1, function(_, class)
                    local result = {}
                    for _, part in ipairs({ c.capsule, c.mesh, c.springArm, c.dialogueCamera, c.cineCamera,
                        c.mainCamera, c.limiter, c.cameraController }) do
                        if part:IsA(class) then
                            result[#result + 1] = fake.param(part)
                        end
                    end
                    return result
                end),
                GetOwner = ufunction("GetOwner", 0, function()
                    return INVALID
                end),
            } })
        return c
    end

    function g.useCharacter(c)
        g.c = c
        g.pawn, g.cmc = c.pawn, c.cmc
        fake.set(g.pc, "Pawn", c.pawn)
    end

    g.useCharacter(g.buildCharacter())

    --- Loads a save: the game's classes now exist and the controller takes over
    --- the character.
    function g.loadSave()
        if not options.noControllerTick then
            g.functions[g.tickPath] = true
        end
        g.functions[g.characterTickPath] = true
        g.functions[g.jumpPath] = true
        local restart = g.hooks[RESTART]
        if restart then
            restart(fake.param(g.pc), fake.param(g.pawn))
        end
    end

    --- UE4SS restarting its mods: the old copy's hooks and keys are dropped without
    --- warning, and main.lua is loaded again.
    function g.restartMods(root)
        g.hooks = {}
        g.keybinds = {}
        fake.loadMod(root)
    end

    --- Presses a hotkey, then runs one frame (hotkey actions run on the next frame).
    function g.press(code)
        local bind = assert(g.keybinds[code], "no key bind for " .. tostring(code))
        bind()
        g.frame()
    end

    --- The camera style in use, whichever way it was set.
    function g.style()
        if options.cameraStyleReflected then
            return fake.nameOf(fake.props(g.pcm).CameraStyle)
        end
        return g.cameraStyle
    end

    function g.speed()
        local v = fake.props(g.cmc).Velocity
        return math.sqrt(v.X * v.X + v.Y * v.Y)
    end

    function g.mode()
        return fake.props(g.cmc).MovementMode
    end

    --- The camera component Unreal shows: the first active one, in the engine's order.
    function g.viewCamera()
        for _, cam in ipairs(g.c.cameras) do
            if g.cameraActive[fake.nameOf(cam:GetFName())] then
                return cam
            end
        end
        return nil
    end

    --- The character's eyes, where a first-person camera should be.
    function g.eyes()
        local pos = g.position
        return { X = pos.X, Y = pos.Y, Z = pos.Z + fake.props(g.pawn).BaseEyeHeight }
    end

    local function wake()
        if options.limiterWakesOnModeChange then
            g.limiterTicking = true
        end
    end

    -- Unreal's character movement, simplified.
    function g.moveTick(dt)
        local p = fake.props(g.cmc)
        local input = g.pending
        g.pending = { X = 0, Y = 0, Z = 0 }
        local mode = p.MovementMode
        if mode == 0 or g.rootMotion then
            return
        end
        local v = p.Velocity
        if g.pressedJump then
            g.pressedJump = false
            if (mode == 1 or mode == 2) and g.jumpCount < fake.props(g.pawn).JumpMaxCount then
                v.Z = math.max(v.Z, p.JumpZVelocity)
                p.MovementMode = 3
                mode = 3
                g.jumpCount = g.jumpCount + 1
                g.gameJumps = g.gameJumps + 1
                wake()
            end
        end
        local walking = mode == 1 or mode == 2
        local hasCurve = p.CurrentMovementSettings.MovementCurve ~= nil
        local groundFriction = hasCurve and 8 or p.GroundFriction
        local ix, iy = input.X, input.Y
        local inputLength = math.sqrt(ix * ix + iy * iy)
        local hx, hy = v.X, v.Y
        if walking then
            v.Z = 0
        end
        g.lastAcceleration = { X = 0, Y = 0, Z = 0 }
        if inputLength > 0 then
            g.engineAccelerated = true
            if inputLength > 1 then
                ix, iy, inputLength = ix / inputLength, iy / inputLength, 1
            end
            local accel = g.cmc:GetMaxAcceleration() * (walking and 1 or p.AirControl)
            g.lastAcceleration = { X = ix * accel, Y = iy * accel, Z = 0 }
            local friction = walking and groundFriction or p.FallingLateralFriction
            local speed = math.sqrt(hx * hx + hy * hy)
            local k = math.min(dt * friction, 1)
            hx = hx - (hx - ix / inputLength * speed) * k
            hy = hy - (hy - iy / inputLength * speed) * k
            hx, hy = hx + ix * accel * dt, hy + iy * accel * dt
            local limit = math.max(p.MaxWalkSpeed * inputLength, speed)
            local s = math.sqrt(hx * hx + hy * hy)
            if s > limit then
                hx, hy = hx / s * limit, hy / s * limit
            end
        else
            local friction = p.bUseSeparateBrakingFriction and p.BrakingFriction
                or (walking and groundFriction or p.FallingLateralFriction)
            friction = friction * p.BrakingFrictionFactor
            local decel = g.cmc:GetMaxBrakingDeceleration()
            local speed = math.sqrt(hx * hx + hy * hy)
            if speed > 0 and (friction > 0 or decel > 0) then
                local ox, oy = hx, hy
                hx = hx + (-friction * hx - decel * hx / speed) * dt
                hy = hy + (-friction * hy - decel * hy / speed) * dt
                if hx * ox + hy * oy <= 0 then
                    hx, hy = 0, 0
                end
                if decel > 0 and math.sqrt(hx * hx + hy * hy) <= 10 then
                    hx, hy = 0, 0
                end
            end
        end
        v.X, v.Y = hx, hy
        if mode == 3 then
            v.Z = v.Z + g.cmc:GetGravityZ() * dt
        end
        local pos = g.position
        local share = g.moveShare or 1
        local startZ = pos.Z
        pos.X, pos.Y, pos.Z = pos.X + v.X * dt * share, pos.Y + v.Y * dt * share, pos.Z + v.Z * dt
        local platform = g.baseVelocity
        if platform and (walking or p.bStayBasedInAir) then
            -- Unreal moves a character on a moving platform along with it, apart from
            -- its velocity (which is relative to the platform).
            pos.X, pos.Y = pos.X + platform.X * dt, pos.Y + platform.Y * dt
        end
        if share < 1 then
            -- Something in the way stopped the move part of the way (a wall hit head
            -- on, a step too high): Unreal works the velocity out from the distance moved.
            v.X, v.Y = v.X * share, v.Y * share
        end
        if mode == 3 and pos.Z <= 0 then
            if options.landingListenerClamps then
                -- A listener of the landing's mode change (the game's speed limiter may
                -- be one) caps the speed there, and the rest of the frame is walked at
                -- that speed: Unreal lands part of the way through its update.
                local cap = g.cmc:GetMaxSpeed()
                local s = math.sqrt(v.X * v.X + v.Y * v.Y)
                if s > cap then
                    local fell = startZ > pos.Z and startZ / (startZ - pos.Z) or 1 -- the share before touchdown
                    local r = cap / s
                    pos.X = pos.X - v.X * dt * share * (1 - fell) * (1 - r)
                    pos.Y = pos.Y - v.Y * dt * share * (1 - fell) * (1 - r)
                    v.X, v.Y = v.X * r, v.Y * r
                    g.landingClamps = g.landingClamps + 1
                end
            end
            pos.Z, v.Z = 0, 0
            p.MovementMode = 1
            g.jumpCount = 0
            g.landings = g.landings + 1
            -- ALS raises the braking friction for a moment after landing.
            p.BrakingFrictionFactor = inputLength > 0 and 0.5 or 3
            wake()
        end
        if p.MovementMode == 1 then
            v.Z = 0
        end
        -- ALS sets the walking speed for its gait when asked to.
        if p.bRequestMovementSettingsChange ~= 0 then
            p.MaxWalkSpeed = 375
            p.bRequestMovementSettingsChange = 0
        end
        -- The game's speed limiter ticks after the movement, while it is enabled,
        -- and caps the speed at the movement component's maximum.
        if g.limiterTicking then
            local cap = g.cmc:GetMaxSpeed()
            local s = math.sqrt(v.X * v.X + v.Y * v.Y)
            if s > cap then
                v.X, v.Y = v.X / s * cap, v.Y / s * cap
            end
        end
        if g.afterMove then
            g.afterMove(v)
        end
    end

    -- The camera manager's update at the end of the frame. With g.cameraSpeed set
    -- (cm/s), the camera moves to its new place at that speed, like a slow blend.
    function g.updateCamera(dt)
        local pos = g.position
        local target
        if g.viewTarget and not same(g.viewTarget, g.pawn) then
            target = { X = pos.X + 500, Y = pos.Y + 500, Z = pos.Z + 200 } -- another actor's camera
        elseif g.style() == "FirstPerson" and not options.cameraStyleIgnored then
            target = g.eyes()
        else
            local cam = g.viewCamera()
            target = cam and g.c.cameraAt(cam) or g.eyes()
        end
        for _, cam in ipairs(g.c.cameras) do
            local p = fake.props(cam)
            if options.cineFovLimit and p.FocusSettings then
                -- A cine camera works its field of view out from a focal length that has limits.
                p.FieldOfView = math.min(p.FieldOfView, options.cineFovLimit)
            end
        end
        if g.cameraSpeed then
            local c = g.cameraLocation
            local dx, dy, dz = target.X - c.X, target.Y - c.Y, target.Z - c.Z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            local step = g.cameraSpeed * dt
            if distance > step then
                target = { X = c.X + dx / distance * step, Y = c.Y + dy / distance * step,
                    Z = c.Z + dz / distance * step }
            end
        end
        g.cameraLocation = target
    end

    --- One frame: input, the controller's tick (where the mod runs), the character's
    --- movement and the camera.
    function g.frame(dt)
        dt = dt or 1 / 60
        local function keyDirection()
            local f = (g.keys.W and 1 or 0) - (g.keys.S and 1 or 0)
            local r = (g.keys.D and 1 or 0) - (g.keys.A and 1 or 0)
            local yaw = math.rad(g.rotation.Yaw)
            return math.cos(yaw) * f - math.sin(yaw) * r, math.sin(yaw) * f + math.cos(yaw) * r
        end
        if not g.inputLocked and not g.moveIgnored then
            local x, y = keyDirection()
            g.pending.X = g.pending.X + x
            g.pending.Y = g.pending.Y + y
        end
        local jumpDown = g.keys.SpaceBar == true
        local jumpHook = g.hooks[g.jumpPath]
        local function callJumpHook(pressed)
            g.inHook = true
            local ok, err = pcall(jumpHook, fake.param(g.pawn), fake.param(pressed))
            g.inHook = false
            assert(ok, err)
        end
        if options.jumpEventEveryFrame then
            -- An input setup that sends the press every frame while held, and no release.
            if jumpDown and jumpHook then
                callJumpHook(true)
            end
            if jumpDown and not g.jumpWasDown then
                g.pressedJump = true
            end
            g.jumpWasDown = jumpDown
        elseif jumpDown ~= (g.jumpWasDown == true) then
            g.jumpWasDown = jumpDown
            if jumpHook then
                callJumpHook(jumpDown)
            end
            if jumpDown then
                g.pressedJump = true
            end
        end
        local tick = g.hooks[g.tickPath]
        if tick then
            g.inHook = true
            local ok, err = pcall(tick, fake.param(g.pc), fake.param(dt))
            g.inHook = false
            assert(ok, err)
        end
        if options.lateInput and not g.inputLocked then
            -- Something adds movement input after the controller's tick, before the movement.
            local x, y = keyDirection()
            g.pending.X = g.pending.X + x
            g.pending.Y = g.pending.Y + y
        end
        if not g.paused then
            g.moveTick(dt)
            -- The character ticks after its movement component.
            local characterTick = g.hooks[g.characterTickPath]
            if characterTick then
                g.inHook = true
                local ok, err = pcall(characterTick, fake.param(g.pawn), fake.param(dt))
                g.inHook = false
                assert(ok, err)
            end
            g.updateCamera(dt) -- Unreal doesn't update the camera while the game is paused
        end
        g.justPressed = {}
        g.time = g.time + dt
    end

    function g.frames(count, dt, each)
        for i = 1, count do
            if each then
                each(i)
            end
            g.frame(dt)
        end
    end

    return g
end

--- Makes main.lua's dofile of config.lua return this table (nil: the real file).
function fake.useConfig(config)
    _G.dofile = function(path, ...)
        if config ~= nil and tostring(path):match("config%.lua$") then
            return config
        end
        return realDofile(path, ...)
    end
end

--- Loads main.lua afresh, with fresh copies of its modules.
function fake.loadMod(root)
    for name in pairs(package.loaded) do
        if name:match("^hl1movement%.") then
            package.loaded[name] = nil
        end
    end
    realDofile(root .. "HL1Movement/Scripts/main.lua")
end

return fake
