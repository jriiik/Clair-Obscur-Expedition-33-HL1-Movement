-- A stand-in for UE4SS and for the parts of Expedition 33 the mod touches, so
-- main.lua can run in plain Lua 5.4.
--
-- Objects behave like UE4SS's: unknown names give an invalid object, writes to
-- unknown names are ignored, struct properties read as views and are written from
-- tables, reading a field a struct doesn't have raises an error, uint8 properties
-- take integers (a Lua boolean becomes 0), game functions check how many
-- parameters they get, and using an object after it was destroyed raises an error
-- (in the real game that would crash).
-- The fake character movement follows Unreal's closely enough (input acceleration,
-- braking, curve-driven ground values, gravity, landing) to check that the mod's
-- speeds survive it.

local fake = {}

local realDofile = dofile
local data = setmetatable({}, { __mode = "k" })
local nextAddress = 0x10000
local byPath = {} -- path -> object, for StaticFindObject

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

-- The game -------------------------------------------------------------------

local CHARACTER = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_World.BP_jRPG_Character_World_C"
local CONTROLLER = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C"
local RESTART = "/Script/Engine.PlayerController:ClientRestart"

local PRIMITIVE_CHAIN = { "PrimitiveComponent", "SceneComponent", "ActorComponent", "Object" }

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
        cameraLocation = { X = 0, Y = 0, Z = 0 },
        inBattle = false,
        inputLocked = false,
        moveIgnored = false,
        paused = false,
        rootMotion = false,
        mainCameraActive = true,
        limiterTicking = true,
        jumpCount = 0,
        gameJumps = 0,
        landings = 0,
        engineAccelerated = false,
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
    _G.StaticFindObject = function(path)
        local found = g.statics[path] or byPath[path]
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
    g.statics = {
        ["/Script/Engine.PlayerController"] = fake.class("PlayerController"),
        ["/Script/Engine.PrimitiveComponent"] = fake.class("PrimitiveComponent"),
        ["/Script/Engine.ActorComponent"] = fake.class("ActorComponent"),
        ["/Script/Engine.CameraComponent"] = fake.class("CameraComponent"),
        ["/Script/Engine.SpringArmComponent"] = fake.class("SpringArmComponent"),
        ["/Script/Engine.Default__GameplayStatics"] = statics,
    }

    -- Player controller and camera manager
    g.pc = fake.object({ className = "BP_jRPG_Controller_World_C", world = world,
        chain = { "BP_jRPG_Controller_World_C", "ALS_Player_Controller_C", "ALSPlayerController",
            "PlayerController", "Controller", "Actor", "Object" },
        declared = { "Pawn", "PlayerCameraManager" },
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
            bAlwaysApplyModifiers = false, ModifierList = fake.array({ g.limiterModifier, g.shakeModifier }) },
        methods = {
            GetCameraLocation = ufunction("GetCameraLocation", 0, function()
                return copyVector(g.cameraLocation)
            end),
            GetFOVAngle = ufunction("GetFOVAngle", 0, function()
                return fake.props(g.pcm).DefaultFOV
            end),
        } })
    fake.set(g.pc, "PlayerCameraManager", g.pcm)

    -- ALS's movement curve, an asset all characters share
    g.curve = fake.object({ className = "CurveVector", name = "C_ALS_Movement_Normal",
        path = "/Game/ALS/Curves/C_ALS_Movement_Normal.C_ALS_Movement_Normal" })

    -- The character, its parts and its movement component
    function g.buildCharacter()
        local c = {}
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
        c.mainCamera = scene("CameraComponent", thePawn, nil, {
            IsActive = ufunction("IsActive", 0, function()
                return g.mainCameraActive
            end),
        })
        c.springArm = scene("SpringArmComponent", thePawn, { AttachChildren = fake.array({ c.mainCamera }) })
        c.capsule = primitive("CapsuleComponent", thePawn,
            { AttachChildren = fake.array({ c.mesh, c.springArm }), bHiddenInGame = true }, {
                GetScaledCapsuleHalfHeight = ufunction("GetScaledCapsuleHalfHeight", 0, function()
                    return 96
                end),
            })
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
                    -- Velocity is relative to it).
                    local platform = g.baseVelocity
                    if mode == 3 and (was == 1 or was == 2) and platform then
                        local v = p.Velocity
                        v.X, v.Y, v.Z = v.X + platform.X, v.Y + platform.Y, v.Z + platform.Z
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
                    return fake.props(c.cmc).MaxWalkSpeed
                end),
                GetGravityZ = ufunction("GetGravityZ", 0, function()
                    return -980 * fake.props(c.cmc).GravityScale
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
                TargetRotation = fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 }),
                CharacterMovement = c.cmc,
                CapsuleComponent = c.capsule,
                RootComponent = c.capsule,
                MainCamera = c.mainCamera,
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
                K2_GetComponentsByClass = ufunction("K2_GetComponentsByClass", 1, function(_, class)
                    local result = {}
                    for _, part in ipairs({ c.capsule, c.mesh, c.springArm, c.mainCamera, c.limiter }) do
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
        if inputLength > 0 then
            g.engineAccelerated = true
            if inputLength > 1 then
                ix, iy, inputLength = ix / inputLength, iy / inputLength, 1
            end
            local accel = g.cmc:GetMaxAcceleration() * (walking and 1 or p.AirControl)
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
        -- The game's speed limiter, while it ticks, caps the speed at the sprint speed.
        if g.limiterTicking then
            local cap = p.CurrentMovementSettings.SprintSpeed
            local s = math.sqrt(hx * hx + hy * hy)
            if s > cap then
                hx, hy = hx / s * cap, hy / s * cap
            end
        end
        v.X, v.Y = hx, hy
        if mode == 3 then
            v.Z = v.Z + g.cmc:GetGravityZ() * dt
        end
        local pos = g.position
        pos.X, pos.Y, pos.Z = pos.X + v.X * dt, pos.Y + v.Y * dt, pos.Z + v.Z * dt
        if mode == 3 and pos.Z <= 0 then
            pos.Z, v.Z = 0, 0
            p.MovementMode = 1
            g.jumpCount = 0
            g.landings = g.landings + 1
            -- ALS raises the braking friction for a moment after landing.
            p.BrakingFrictionFactor = inputLength > 0 and 0.5 or 3
        end
        if p.MovementMode == 1 then
            v.Z = 0
        end
        -- ALS sets the walking speed for its gait when asked to.
        if p.bRequestMovementSettingsChange ~= 0 then
            p.MaxWalkSpeed = 375
            p.bRequestMovementSettingsChange = 0
        end
    end

    -- The camera manager's update at the end of the frame. With g.cameraSpeed set
    -- (cm/s), the camera moves to its new place at that speed, like a slow blend.
    function g.updateCamera(dt)
        local pos = g.position
        local target
        if g.style() == "FirstPerson" and not options.cameraStyleIgnored then
            target = { X = pos.X, Y = pos.Y, Z = pos.Z + fake.props(g.pawn).BaseEyeHeight }
        else
            target = { X = pos.X - 300, Y = pos.Y, Z = pos.Z + 150 }
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
        if not g.inputLocked and not g.moveIgnored then
            local f = (g.keys.W and 1 or 0) - (g.keys.S and 1 or 0)
            local r = (g.keys.D and 1 or 0) - (g.keys.A and 1 or 0)
            local yaw = math.rad(g.rotation.Yaw)
            g.pending.X = g.pending.X + math.cos(yaw) * f - math.sin(yaw) * r
            g.pending.Y = g.pending.Y + math.sin(yaw) * f + math.cos(yaw) * r
        end
        local jumpDown = g.keys.SpaceBar == true
        local jumpHook = g.hooks[g.jumpPath]
        if options.jumpEventEveryFrame then
            -- An input setup that sends the press every frame while held, and no release.
            if jumpDown and jumpHook then
                jumpHook(fake.param(g.pawn), fake.param(true))
            end
            if jumpDown and not g.jumpWasDown then
                g.pressedJump = true
            end
            g.jumpWasDown = jumpDown
        elseif jumpDown ~= (g.jumpWasDown == true) then
            g.jumpWasDown = jumpDown
            if jumpHook then
                jumpHook(fake.param(g.pawn), fake.param(jumpDown))
            end
            if jumpDown then
                g.pressedJump = true
            end
        end
        local tick = g.hooks[g.tickPath]
        if tick then
            tick(fake.param(g.pc), fake.param(dt))
        end
        if not g.paused then
            g.moveTick(dt)
            -- The character ticks after its movement component.
            local characterTick = g.hooks[g.characterTickPath]
            if characterTick then
                characterTick(fake.param(g.pawn), fake.param(dt))
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
