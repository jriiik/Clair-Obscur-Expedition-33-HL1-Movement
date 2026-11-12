-- A stand-in for UE4SS and for the parts of Expedition 33 the mod touches, so
-- main.lua can run in plain Lua 5.4.
--
-- Objects behave like UE4SS's: unknown names give an invalid object, writes to
-- unknown names are ignored, struct properties read as views and are written from
-- tables, reading a field a struct doesn't have raises an error, uint8 properties
-- take integers (a Lua boolean becomes 0), game functions check how many
-- parameters they get, out parameters are filled into the table passed for them,
-- and using an object after it was destroyed raises an error (in the real game
-- that would crash). A struct inside a struct reads as a view too.
-- The fake character movement follows Unreal's closely enough (input acceleration,
-- braking, curve-driven ground values, gravity, a falling move with the average of
-- the old and the new velocity as Unreal's, landing, and with g.terrain walking along
-- slopes, with the floor in CurrentFloor) to check that the mod's speeds
-- survive it. The character's position stands for the lowest point of its capsule:
-- walking, it is kept CurrentFloor.FloorDist above the ground (1.9 to 2.4 cm, as Unreal
-- keeps a walking capsule), and a flight ends where it touches the ground. Not
-- Unreal's: the character is a point (no capsule that rounds an edge), it lands on any
-- ground under the end of a frame's move, and a frame longer than
-- MaxSimulationTimeStep is moved in one step. The camera follows Unreal's rule: the
-- view target's first active camera component, in the order the components are
-- listed, or the eyes with the FirstPerson style.

local fake = {}

local realLoadfile = loadfile
local data = setmetatable({}, { __mode = "k" })
local nextAddress = 0x10000
local byPath = {} -- path -> object, for StaticFindObject

--- Counts of what the mod asked of the fake game, for the cost test. reads: of an
--- object's properties; fields: of a struct's fields (those of a struct inside it too).
--- destroyed: uses of an object after it was destroyed (each raises an error too, but
--- the mod's safe calls catch errors, so a test that wants none of them counts them).
fake.counts = { calls = 0, fullNames = 0, reads = 0, fields = 0, writes = 0, destroyed = 0 }

-- Unreal keeps a walking capsule a little above the floor: between MIN_FLOOR_DIST and
-- MAX_FLOOR_DIST (cm, measured straight down), and at their middle whenever it finds
-- it outside that (AdjustFloorHeight). The distance is in CurrentFloor.FloorDist. A
-- flight starts from there and ends where the capsule touches the floor.
local MIN_FLOOR_DIST, MAX_FLOOR_DIST = 1.9, 2.4
--- How far above the ground a character stands after a landing (cm).
fake.FLOOR_DIST = (MIN_FLOOR_DIST + MAX_FLOOR_DIST) / 2

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

local function isStruct(value)
    return type(value) == "table" and getmetatable(value) == nil and value.__fields ~= nil
end

local function structView(s)
    local views = {} -- views of the structs inside this one, by struct
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
            fake.counts.fields = fake.counts.fields + 1
            local value = s[key]
            if isStruct(value) then
                -- A struct inside a struct reads as a view too, onto the same memory, as in UE4SS.
                views[value] = views[value] or structView(value)
                return views[value]
            end
            return value
        end,
        __newindex = function(_, key, value)
            if s.__locked then
                error("[push_objectproperty] this struct can't be written", 2)
            end
            if s.__fields[key] then
                if isStruct(s[key]) and type(value) == "table" then
                    for field, v in pairs(value) do
                        if s[key].__fields[field] then
                            s[key][field] = v
                        end
                    end
                else
                    s[key] = value
                end
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
        fake.counts.destroyed = fake.counts.destroyed + 1
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
    if d.onRead and d.onRead[key] then
        d.onRead[key]()
    end
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
    if d.breakOnWrite and d.breakOnWrite[key] then
        error("writing " .. key .. " failed", 2)
    end
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

--- Stops the renderer drawing a part whatever its own flags say (see g.animTick), as
--- when the game hides the actor that owns it: SetActorHiddenInGame sets no flag on
--- the actor's parts.
function fake.setUndrawn(obj, undrawn)
    data[obj].undrawn = undrawn or nil
end

--- A new object at the address of a destroyed one: in UE4SS a Lua object holds
--- only the address, so from now on old reads and writes the new object.
function fake.reuseAddress(old, new)
    data[old] = data[new]
end

--- The game moving an object into another outer, as UObject::Rename does (a skin's
--- body moved out of the character, say): the same object at the same address, with
--- another path in its full name. Its own name is the last part of the path.
function fake.move(obj, path)
    local d = data[obj]
    if byPath[d.path] == obj then
        byPath[d.path] = nil
    end
    d.path, d.name = path, path:match("[^.:]+$")
    byPath[path] = obj
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

--- Calls fn whenever obj[key] is read, which then reads as usual (to count reads).
function fake.onRead(obj, key, fn)
    data[obj].onRead = data[obj].onRead or {}
    data[obj].onRead[key] = fn
end

--- Makes writes of obj[key] fail, as a write UE4SS can't do.
function fake.breakOnWrite(obj, key)
    data[obj].breakOnWrite = data[obj].breakOnWrite or {}
    data[obj].breakOnWrite[key] = true
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
local SKINNED_CHAIN = { "SkinnedMeshComponent", "MeshComponent", "PrimitiveComponent", "SceneComponent",
    "ActorComponent", "Object" }
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
    fake.counts = { calls = 0, fullNames = 0, reads = 0, fields = 0, writes = 0, destroyed = 0 }
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
        position = { X = 0, Y = 0, Z = fake.FLOOR_DIST }, -- standing on the ground at Z = 0
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
        paused = false, -- what IsGamePaused says in the controller's tick (where the mod runs)
        -- Whether Unreal runs the next frame as paused, if not as g.paused says: it
        -- decides that at the start of the world's tick, and the game can pause or
        -- unpause later in the frame, from the controller's input (see g.frame).
        worldPaused = nil,
        worldTime = 0, -- UWorld::TimeSeconds: goes on only in frames Unreal doesn't run as paused
        clock = nil, -- GetTimeSeconds when it misbehaves: "stuck", "running" (real time) or "error"
        rootMotion = false,
        limiterTicking = true,
        jumpCount = 0,
        gameJumps = 0,
        stoppedJumps = 0, -- the mod taking back the game's jump press (StopJumping)
        landings = 0,
        landingClamps = 0, -- speed caps at a landing (options.landingListenerClamps)
        inAirResets = 0, -- ALS setting the in-air rotation to the body's as the character left the ground
        -- How fast ALS turns the body on the ground (RInterpTo's speed): the game's curve
        -- at the mapped speed times 1 to 3 (more while the view turns fast).
        groundRotationRate = options.groundRotationRate or 10,
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
            GetTimeSeconds = ufunction("GetTimeSeconds", 1, function()
                if g.clock == "error" then
                    error("GetTimeSeconds: no such function", 2)
                elseif g.clock == "stuck" then
                    return 0
                elseif g.clock == "running" then
                    return g.time
                end
                return g.worldTime
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
        ["/Script/Engine.SkinnedMeshComponent"] = fake.class("SkinnedMeshComponent"),
        ["/Script/Engine.ActorComponent"] = fake.class("ActorComponent"),
        ["/Script/Engine.CameraComponent"] = fake.class("CameraComponent"),
        ["/Script/Engine.SpringArmComponent"] = fake.class("SpringArmComponent"),
        ["/Script/Engine.Default__GameplayStatics"] = statics,
        ["/Script/SandFall.Default__InputBlueprintHelpers"] = helpers,
    }

    -- UMG and CommonUI, for the widget the mod puts on the screen. As in the engine,
    -- a widget on the screen stays alive, one taken off is destroyed by the next
    -- garbage collection (g.collectGarbage), and a level change takes the old
    -- level's widgets off the screen (g.removeWorldWidgets).
    g.viewport = {} -- widgets on the screen, in the order they were added
    g.umg = { made = 0, ftexts = 0, textSets = 0, valueSets = 0, offScreen = {} }
    g.gameInstance = fake.object({ className = "BP_GameInstance_C", name = "BP_GameInstance_C_1",
        path = "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1" })
    for name, path in pairs({ UserWidget = "/Script/UMG.UserWidget", WidgetTree = "/Script/UMG.WidgetTree",
        CanvasPanel = "/Script/UMG.CanvasPanel", TextBlock = "/Script/UMG.TextBlock",
        CommonNumericTextBlock = "/Script/CommonUI.CommonNumericTextBlock" }) do
        if not (name == "CommonNumericTextBlock" and options.noCommonUI) then
            g.statics[path] = fake.class(name)
        end
    end
    local ftexts = setmetatable({}, { __mode = "k" })
    local ftextMeta = { __index = {
        type = function()
            return "FText"
        end,
        ToString = function(self)
            return ftexts[self]
        end,
    } }
    -- UE4SS's FText(string), which builds 848 and later have.
    _G.FText = not options.noFText and function(text)
        assert(type(text) == "string", "FText takes a string")
        local ftext = newUserdata(ftextMeta)
        ftexts[ftext] = text
        g.umg.ftexts = g.umg.ftexts + 1
        return ftext
    end or nil
    local function onScreen(widget)
        for _, w in ipairs(g.viewport) do
            if same(w, widget) then
                return true
            end
        end
        return false
    end
    local function newWidget(className, outer, spec)
        g.umg.made = g.umg.made + 1
        spec.className = className
        spec.name = string.format("%s_%d", className, 2147470000 + g.umg.made)
        spec.path = data[outer].path .. "." .. spec.name
        spec.world = world
        return fake.object(spec)
    end
    local function makeTree(outer)
        return newWidget("WidgetTree", outer, { declared = { "RootWidget" } })
    end
    local function makeUserWidget(outer)
        return newWidget("UserWidget", outer, { chain = { "UserWidget", "Widget", "Visual", "Object" },
            declared = { "WidgetTree" }, props = { Visibility = 4 }, methods = {
            AddToViewport = ufunction("AddToViewport", 1, function(self, z)
                assert(math.type(z) == "integer", "ZOrder is an int32")
                if options.addFails then
                    return -- AddToScreen refused (no world, no viewport client ...): a Kismet warning only
                end
                assert(not onScreen(self), "AddToViewport: the widget is already on the screen")
                local tree = assert(fake.props(self).WidgetTree, "a widget tree")
                assert(fake.props(tree).RootWidget, "a root widget, before Slate builds the widget")
                g.viewport[#g.viewport + 1] = self
                fake.props(self).ZOrder = z
            end),
            RemoveFromParent = ufunction("RemoveFromParent", 0, function(self)
                for i = #g.viewport, 1, -1 do
                    if same(g.viewport[i], self) then
                        g.umg.offScreen[#g.umg.offScreen + 1] = table.remove(g.viewport, i)
                    end
                end
            end),
            SetVisibility = ufunction("SetVisibility", 1, function(self, visibility)
                assert(math.type(visibility) == "integer", "ESlateVisibility is a number")
                fake.props(self).Visibility = visibility
            end),
            IsInViewport = ufunction("IsInViewport", 0, function(self)
                return onScreen(self)
            end),
            SetOwningPlayer = ufunction("SetOwningPlayer", 1, function(_, player)
                assert(data[player], "SetOwningPlayer needs a player controller")
            end),
        } })
    end
    local function makeCanvas(outer)
        return newWidget("CanvasPanel", outer, { declared = { "Child", "Slot" }, methods = {
            AddChildToCanvas = ufunction("AddChildToCanvas", 1, function(self, content)
                assert(data[content] and data[content].alive, "AddChildToCanvas needs a widget")
                fake.props(self).Child = content
                local function set(field, check)
                    return ufunction("Set" .. field, 1, function(slot, value)
                        assert(check(value), "Set" .. field .. ": wrong kind of value")
                        fake.props(slot)[field] = value
                    end)
                end
                local function isTable(v)
                    return type(v) == "table"
                end
                local slot = newWidget("CanvasPanelSlot", self, { props = {}, methods = {
                    SetAnchors = set("Anchors", function(v)
                        return isTable(v) and isTable(v.Minimum) and isTable(v.Maximum)
                    end),
                    SetAlignment = set("Alignment", isTable),
                    SetPosition = set("Position", isTable),
                    SetAutoSize = set("AutoSize", function(v)
                        return type(v) == "boolean"
                    end),
                } })
                fake.props(self).Slot = slot
                return slot
            end),
        } })
    end
    local function makeText(className, outer)
        local numeric = className == "CommonNumericTextBlock"
        local props = {
            Font = fake.struct({ Size = 24, LetterSpacing = 0, OutlineSettings = fake.struct({ OutlineSize = 0,
                OutlineColor = fake.struct({ R = 0, G = 0, B = 0, A = 1 }) }) }),
            Visibility = 4,
            Shown = "", -- what Slate draws
        }
        if options.textWithoutOutline then
            -- An engine whose font settings have no outline: reading it raises, as in UE4SS.
            props.Font = fake.struct({ Size = 24, LetterSpacing = 0 })
        end
        if numeric then
            props.FormattingSpecification = fake.struct({ RoundingMode = 0, UseGrouping = true,
                MinimumIntegralDigits = 1, MaximumIntegralDigits = 324, MinimumFractionalDigits = 0,
                MaximumFractionalDigits = 0 })
        end
        local function isTable(v)
            return type(v) == "table"
        end
        local function setter(name, check)
            return ufunction(name, 1, function(self, value)
                assert(check(value), name .. ": wrong kind of value")
                fake.props(self)[name] = value
            end)
        end
        local methods = {
            SetText = ufunction("SetText", 1, function(self, text)
                assert(ftexts[text], "SetText takes an FText")
                fake.props(self).Shown = ftexts[text]
                g.umg.textSets = g.umg.textSets + 1
            end),
            SetColorAndOpacity = setter("SetColorAndOpacity", function(v)
                return isTable(v) and isTable(v.SpecifiedColor) and math.type(v.ColorUseRule) == "integer"
            end),
            SetShadowOffset = setter("SetShadowOffset", isTable),
            SetShadowColorAndOpacity = setter("SetShadowColorAndOpacity", isTable),
            SetJustification = setter("SetJustification", function(v)
                return math.type(v) == "integer"
            end),
        }
        if numeric then
            -- FText::AsNumber with the formatting options: HalfFromZero, no fraction.
            methods.SetCurrentValue = ufunction("SetCurrentValue", 1, function(self, value)
                assert(type(value) == "number", "SetCurrentValue takes a float")
                local p = fake.props(self)
                local n = math.floor(math.abs(value) + 0.5) * (value < 0 and -1 or 1)
                local text = string.format("%d", n)
                if p.FormattingSpecification.UseGrouping then
                    text = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
                end
                p.Shown = text
                g.umg.valueSets = g.umg.valueSets + 1
            end)
        end
        return newWidget(className, outer, { props = props, methods = methods })
    end
    _G.StaticConstructObject = function(class, outer, ...)
        local d = data[class]
        assert(d and d.typeName == "UClass", "StaticConstructObject needs a class")
        assert(data[outer] and data[outer].alive, "StaticConstructObject needs an outer that exists")
        -- With a name, the engine would make the object again in place of a live one of that name.
        assert(select("#", ...) == 0, "StaticConstructObject with a fixed name")
        if d.name == "UserWidget" then
            return makeUserWidget(outer)
        elseif d.name == "WidgetTree" then
            return makeTree(outer)
        elseif d.name == "CanvasPanel" then
            return makeCanvas(outer)
        elseif d.name == "TextBlock" or d.name == "CommonNumericTextBlock" then
            return makeText(d.name, outer)
        end
        error("the fake can't make a " .. tostring(d.name))
    end
    if not options.noWidgetLibrary then
        g.statics["/Script/UMG.Default__WidgetBlueprintLibrary"] = fake.object({ className = "WidgetBlueprintLibrary",
            name = "Default__WidgetBlueprintLibrary", path = "/Script/UMG.Default__WidgetBlueprintLibrary", methods = {
            Create = ufunction("Create", 3, function(_, context, class, owner)
                assert(data[context] and data[class] and data[owner], "Create(context, class, owning player)")
                if options.createFails then
                    return INVALID
                end
                -- CreateWidget for a player controller: the game instance is the outer.
                local widget = makeUserWidget(g.gameInstance)
                fake.set(widget, "WidgetTree", makeTree(widget))
                return widget
            end),
        } })
    end

    --- What the speedometer shows: the text of the shown widget on the screen, or nil.
    function g.shownText()
        for _, w in ipairs(g.viewport) do
            local p = fake.props(w)
            if p.Visibility ~= 1 and p.Visibility ~= 2 then
                local canvas = fake.props(p.WidgetTree).RootWidget
                local text = canvas and fake.props(canvas).Child
                return text and fake.props(text).Shown
            end
        end
        return nil
    end

    --- Garbage collection: widgets taken off the screen are destroyed, with their tree.
    function g.collectGarbage()
        local function destroy(obj)
            if obj and data[obj] and data[obj].alive then
                fake.destroy(obj)
                local p = data[obj].props
                destroy(p.WidgetTree)
                destroy(p.RootWidget)
                destroy(p.Child)
                destroy(p.Slot)
            end
        end
        for _, w in ipairs(g.umg.offScreen) do
            destroy(w)
        end
        g.umg.offScreen = {}
    end

    --- The engine removing the old level's widgets from the screen (HandleRemoveWorld),
    --- or something in the game removing every widget (RemoveAllViewportWidgets).
    function g.removeWorldWidgets()
        for i = #g.viewport, 1, -1 do
            g.umg.offScreen[#g.umg.offScreen + 1] = table.remove(g.viewport, i)
        end
    end

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
    -- ALS's grounded turn rate by mapped speed (1 walking, 2 running, 3 sprinting or
    -- faster, as the mod's speeds are): at 3 the fake's grounded rate.
    g.rotationCurve = fake.object({ className = "CurveFloat", name = "C_ALS_RotationRate",
        path = "/Game/ALS/Curves/C_ALS_RotationRate.C_ALS_RotationRate", methods = {
            GetFloatValue = ufunction("GetFloatValue", 1, function(_, time)
                assert(type(time) == "number")
                return g.groundRotationRate * time / 3
            end),
        } })

    -- The ground under (x, y): its height and the unit normal of its surface. Flat at
    -- Z = 0 unless a test sets g.terrain, a function of (x, y) that returns them.
    function g.groundAt(x, y)
        if g.terrain then
            return g.terrain(x, y)
        end
        return 0, 0, 0, 1
    end

    -- The movement component's CurrentFloor: the floor under the character while it
    -- walks, cleared (zeros) otherwise, as Unreal does. dist: how far above it the
    -- character is (nil: where a landing puts it). g.contactNormal, if set, gives
    -- the capsule's contact normal from the surface's (they differ where the capsule
    -- rests on an edge).
    local function setFloor(cmc, nx, ny, nz, dist)
        local p = fake.props(cmc)
        local floor = p.CurrentFloor
        if not floor then
            return
        end
        floor.bBlockingHit = nz ~= nil
        floor.bWalkableFloor = nz ~= nil and nz >= p.WalkableFloorZ
        floor.bLineTrace = false
        floor.FloorDist = nz and (dist or fake.FLOOR_DIST) or 0
        local surface, contact = floor.HitResult.ImpactNormal, floor.HitResult.Normal
        surface.X, surface.Y, surface.Z = nx or 0, ny or 0, nz or 0
        if nz and g.contactNormal then
            contact.X, contact.Y, contact.Z = g.contactNormal(nx, ny, nz)
        else
            contact.X, contact.Y, contact.Z = nx or 0, ny or 0, nz or 0
        end
    end
    g.setFloor = setFloor

    -- A movement mode change, as SetMovementMode makes it (the game's own jump too).
    local function changeMode(cmc, mode, pawn)
        local p = fake.props(cmc)
        local was = p.MovementMode
        p.MovementMode = mode
        if mode ~= 1 then
            setFloor(cmc, nil) -- Unreal keeps CurrentFloor only while walking
        end
        -- ALS (OnMovementModeChanged, then OnMovementStateChanged): entering the air,
        -- the in-air rotation starts as the character's own rotation.
        local inAir = pawn and fake.props(pawn).InAirRotation
        if mode == 3 and was ~= 3 and inAir then
            inAir.Pitch, inAir.Yaw, inAir.Roll = 0, g.actorYaw or 0, 0
            g.inAirResets = g.inAirResets + 1
        end
        -- Leaving a moving platform adds its velocity (while walking, Velocity is
        -- relative to it), unless the character stays based on it in the air.
        local platform = g.baseVelocity
        local v = p.Velocity
        if mode == 3 and (was == 1 or was == 2) and platform and not p.bStayBasedInAir then
            v.X, v.Y, v.Z = v.X + platform.X, v.Y + platform.Y, v.Z + platform.Z
        end
        -- Entering mode None stops the character (Unreal's OnMovementModeChanged calls
        -- StopMovementKeepPathing, which zeroes the velocity). ALS's mantle starts that
        -- way and then moves the character by setting its location, without a velocity.
        if mode == 0 and was ~= 0 then
            v.X, v.Y, v.Z = 0, 0, 0
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
    end

    -- The character, its parts and its movement component
    function g.buildCharacter()
        local c = { attach = {} }
        -- spec: chain, bytes, name, address and getters, as for fake.object.
        local function primitive(className, owner, props, methods, spec)
            spec = spec or {}
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
            -- Drawn within the tolerance, in seconds of the world's time (see g.animTick).
            -- A part never drawn has Unreal's starting value: 1000 s before the world began.
            methods.WasRecentlyRendered = ufunction("WasRecentlyRendered", 1, function(_, tolerance)
                assert(type(tolerance) == "number")
                return g.worldTime - (data[obj].lastRender or -1000) <= tolerance
            end)
            obj = fake.object({ className = className, name = spec.name, address = spec.address, world = world,
                chain = chainOf(className, spec.chain or PRIMITIVE_CHAIN), props = props, methods = methods,
                bytes = spec.bytes, getters = spec.getters })
            return obj
        end
        --- An anim instance of E33's AnimBP, built on ALS's, which copies the character's
        --- speed into CharacterInformation when its graph runs.
        function c.newAnimInstance()
            return fake.object({ className = "ALS_UE5_AnimBP_C", world = world,
                chain = { "ALS_UE5_AnimBP_C", "ALSCharacterAnimInstance", "AnimInstance", "Object" },
                props = { CharacterInformation = fake.struct({ Speed = 0, bIsMoving = false }) } })
        end
        --- A skeletal mesh. With anim (an anim instance) it runs an animation of its own,
        --- as E33's Body does; without, it follows another mesh's pose. Its tick option
        --- is an enum, which UE4SS writes as a byte. spec: name, address and getters, as
        --- for fake.object (tests use them for new parts).
        function c.skeletal(owner, props, anim, spec)
            spec = spec or {}
            props = props or {}
            if props.VisibilityBasedAnimTickOption == nil then
                props.VisibilityBasedAnimTickOption = 0 -- a plain skeletal mesh's default
            end
            local obj = primitive("SkeletalMeshComponent", owner, props, {
                GetAnimInstance = ufunction("GetAnimInstance", 0, function()
                    return anim or INVALID
                end),
            }, { chain = SKINNED_CHAIN, bytes = { "VisibilityBasedAnimTickOption" }, name = spec.name,
                address = spec.address, getters = spec.getters })
            data[obj].anim = anim
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
        c.skinMesh = c.skeletal(function()
            return c.skinActor
        end)
        c.propMesh = primitive("StaticMeshComponent", function()
            return c.propActor
        end, { AttachChildren = fake.array({ c.torchLight }) })
        -- The body that runs the character's AnimBP (E33's "Body"). Its tick option is a
        -- guess at E33's: OnlyTickPoseWhenRendered, so it stops animating, and its
        -- sounds with it, a second after it was last drawn (see g.animTick).
        c.animInstance = c.newAnimInstance()
        c.mesh = c.skeletal(thePawn, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }),
            VisibilityBasedAnimTickOption = options.bodyTickOption or 4 }, c.animInstance)
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
            MovementCurve = c.curve, RotationRateCurve = g.rotationCurve })
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
                MaxSimulationTimeStep = 0.05,
                -- Unreal's floor settings (its defaults), and the floor its walking found
                -- (cleared in any other movement mode).
                WalkableFloorAngle = 44.765,
                WalkableFloorZ = 0.71,
                PerchRadiusThreshold = 0,
                bUseFlatBaseForFloorChecks = false,
                LedgeCheckThreshold = 4,
                bCanWalkOffLedges = true,
                CurrentFloor = fake.struct({ bBlockingHit = true, bWalkableFloor = true, bLineTrace = false,
                    FloorDist = fake.FLOOR_DIST, LineDist = 0, HitResult = fake.struct({
                        -- (options.floorNormalUnreadable: as if UE4SS couldn't find the
                        -- vector's fields, which FVector_NetQuantizeNormal inherits.)
                        ImpactNormal = options.floorNormalUnreadable and fake.struct({}) or fake.vector(0, 0, 1),
                        Normal = fake.vector(0, 0, 1) }) }),
                bStayBasedInAir = options.stayBasedInAir == true,
                bRequestMovementSettingsChange = 0, -- a uint8 in ALS
                CurrentMovementSettings = movementSettings,
                -- The engine's own ways of turning the character, which ALS leaves off.
                bOrientRotationToMovement = false,
                bUseControllerDesiredRotation = false,
            },
            methods = {
                SetMovementMode = ufunction("SetMovementMode", 2, function(_, mode, custom)
                    assert(math.type(mode) == "integer" and math.type(custom) == "integer")
                    changeMode(c.cmc, mode, c.pawn)
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
                GetMovementBase = ufunction("GetMovementBase", 0, function()
                    return nil -- the fake models a platform by its velocity only
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

        -- The game's fall detector, which "kills" the character after a fall that went too
        -- far or lasted too long (its values here are made up).
        c.fallDetector = fake.object({ className = "BP_FallDetectorComponent_C", world = world,
            chain = { "BP_FallDetectorComponent_C", "ActorComponent", "Object" },
            props = { EnableKillDetection = true, KillDistance = 3000, KillTime = 4 } })

        c.pawn = fake.object({ className = "BP_jRPG_Character_World_C",
            name = "BP_jRPG_Character_World_C_" .. nextAddress, world = world,
            chain = { "BP_jRPG_Character_World_C", "ALS_CharacterBP_C", "ALSCharacter", "ALSBaseCharacter",
                "Character", "Pawn", "Actor", "Object" },
            -- Unreal's Jump sets bPressedJump during the game's input; the movement update
            -- jumps then (options.noPressedJump: UE4SS can't read it).
            getters = { bPressedJump = not options.noPressedJump and function()
                return g.pressedJump == true
            end or nil },
            props = {
                BaseEyeHeight = 64,
                JumpMaxHoldTime = 0.2,
                JumpMaxCount = 1,
                bIsWorldMapPawn = options.worldMap == true,
                bFindCameraComponentWhenViewTarget = true,
                TargetRotation = fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 }),
                -- ALS's rotation: what the body turns towards in the air, and the
                -- velocity's direction and speed as its last update saw them.
                InAirRotation = not options.noInAirRotation and fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 }) or nil,
                LastVelocityRotation = fake.struct({ Pitch = 0, Yaw = 0, Roll = 0 }),
                Speed = 0,
                AimYawRate = 0,
                RotationMode = 0, -- VelocityDirection, as in E33
                ViewMode = 0, -- ThirdPerson
                bUseControllerRotationYaw = false,
                CharacterMovement = c.cmc,
                CapsuleComponent = c.capsule,
                RootComponent = c.capsule,
                MainCamera = c.mainCamera,
                Main_CineCamera = c.cineCamera,
                BP_CameraControllerComponent = c.cameraController,
                BP_VelocityControllerComponent = not options.noLimiterProperty and c.limiter or nil,
                Controller = g.pc,
                IsAttachedToMovingPlatform = false, -- the game's own flag (it scales cloth then)
                BP_FallDetectorComponent = c.fallDetector,
                -- ALS's reactions to a hard landing (ALS-Community's defaults).
                bRagdollOnLand = false,
                RagdollOnLandVelocity = 1000,
                bBreakfallOnLand = true,
                BreakfallOnLandVelocity = 700,
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
                StopJumping = ufunction("StopJumping", 0, function()
                    g.pressedJump = false
                    g.stoppedJumps = g.stoppedJumps + 1
                end),
                K2_GetActorLocation = ufunction("K2_GetActorLocation", 0, function()
                    return copyVector(g.position)
                end),
                K2_GetActorRotation = ufunction("K2_GetActorRotation", 0, function()
                    return { Pitch = 0, Yaw = g.actorYaw or 0, Roll = 0 }
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
                -- Unreal's DoJump: the jump speed, then SetMovementMode(Falling).
                v.Z = math.max(v.Z, p.JumpZVelocity)
                changeMode(g.cmc, 3, g.pawn)
                mode = 3
                g.jumpCount = g.jumpCount + 1
                g.gameJumps = g.gameJumps + 1
                -- Then OnJumped: ALS's EventOnJumped turns the body in the air towards
                -- the velocity's direction, if its last update saw some speed.
                local als = fake.props(g.pawn)
                if als.InAirRotation then
                    als.InAirRotation.Yaw = als.Speed > 100 and als.LastVelocityRotation.Yaw or (g.actorYaw or 0)
                end
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
        -- Unreal's falling update takes the frame's gravity off the velocity first and then
        -- moves with the average of the old and the new velocity, so a flight is the same
        -- at any frame rate.
        local moveZ = v.Z
        if mode == 3 then
            v.Z = v.Z + g.cmc:GetGravityZ() * dt
            moveZ = (moveZ + v.Z) / 2
        end
        local pos = g.position
        local share = g.moveShare or 1
        local startZ = pos.Z
        -- Walking, Unreal moves along the line of the floor the move starts on
        -- (MoveAlongFloor) for the whole frame, also where that floor ends. (The terrain
        -- under the character, not CurrentFloor: options.floorNormalUnreadable empties
        -- that for what UE4SS can read of it, not for what the engine knows.)
        local rise = 0
        if mode == 1 and g.terrain then
            local _, nx, ny, nz = g.groundAt(pos.X, pos.Y)
            if nz >= p.WalkableFloorZ then
                rise = -(nx * v.X + ny * v.Y) * dt * share / nz
            end
        end
        pos.X, pos.Y, pos.Z = pos.X + v.X * dt * share, pos.Y + v.Y * dt * share, pos.Z + moveZ * dt
        local platform = g.baseVelocity
        if platform and (walking or p.bStayBasedInAir) then
            -- Unreal moves a character on a moving platform along with it, apart from
            -- its velocity (which is relative to the platform).
            pos.X, pos.Y = pos.X + platform.X * dt, pos.Y + platform.Y * dt
            if not walking then
                -- In the air nothing follows the floor up or down: Unreal's based movement
                -- carries the character with all of the platform's motion, Z too.
                pos.Z = pos.Z + platform.Z * dt
            end
        end
        if share < 1 then
            -- Something in the way stopped the move part of the way (a wall hit head
            -- on, a step too high): Unreal works the velocity out from the distance moved.
            v.X, v.Y = v.X * share, v.Y * share
        end
        local ground, gnx, gny, gnz = g.groundAt(pos.X, pos.Y)
        if walking and g.terrain then
            -- (Without a terrain the fake's ground is wherever the character walks: a test
            -- may put a platform high above Z = 0.)
            local dist = pos.Z + rise - ground -- how far above the floor the move left it
            if dist <= p.MaxStepHeight + MAX_FLOOR_DIST then
                -- A floor within reach below where the move led: Unreal walks along it (up
                -- and down slopes and steps), keeping the horizontal velocity
                -- (bMaintainHorizontalGroundVelocity), with its gap above the floor.
                if mode == 1 then
                    if dist < MIN_FLOOR_DIST or dist > MAX_FLOOR_DIST then
                        dist = fake.FLOOR_DIST
                    end
                    pos.Z = ground + dist
                    setFloor(g.cmc, gnx, gny, gnz, dist)
                else
                    -- Nav-mesh walking puts the feet on the nav mesh, and doesn't look for a floor.
                    pos.Z = ground
                    setFloor(g.cmc, nil)
                end
            else
                -- No floor within reach: walking off a ledge, from where the floor's line led.
                pos.Z = pos.Z + rise
                changeMode(g.cmc, 3, g.pawn)
            end
        end
        if mode == 3 and pos.Z <= ground then
            if options.landingListenerClamps then
                -- A listener of the landing's mode change (the game's speed limiter may
                -- be one) caps the speed there, and the rest of the frame is walked at
                -- that speed: Unreal lands part of the way through its update.
                local cap = g.cmc:GetMaxSpeed()
                local s = math.sqrt(v.X * v.X + v.Y * v.Y)
                if s > cap then
                    -- the share before touchdown
                    local fell = startZ > pos.Z and (startZ - ground) / (startZ - pos.Z) or 1
                    local r = cap / s
                    -- (v already has a shortened move's share in it.)
                    pos.X = pos.X - v.X * dt * (1 - fell) * (1 - r)
                    pos.Y = pos.Y - v.Y * dt * (1 - fell) * (1 - r)
                    v.X, v.Y = v.X * r, v.Y * r
                    g.landingClamps = g.landingClamps + 1
                end
            end
            -- It touched the ground: Unreal lands it there, walks the rest of the frame
            -- along the floor, and lifts it to its gap above the floor.
            pos.Z, v.Z = ground + fake.FLOOR_DIST, 0
            setFloor(g.cmc, gnx, gny, gnz)
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

    -- ALS's rotation, in the character's update after Unreal's movement (its Tick:
    -- the Blueprint's ReceiveTick, then SetEssentialValues, then UpdateGroundedRotation
    -- or UpdateInAirRotation), in its VelocityDirection mode. FMath::RInterpTo turns
    -- the short way round by a share of the difference.
    local function normalized(yaw)
        return (yaw + 180) % 360 - 180
    end
    local function interpTo(from, to, dt, speed)
        return normalized(from + normalized(to - from) * math.min(math.max(dt * speed, 0), 1))
    end
    function g.alsTick(dt)
        local p = fake.props(g.pawn)
        local v = fake.props(g.cmc).Velocity
        local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        p.Speed = speed
        if speed > 1 then
            p.LastVelocityRotation.Yaw = math.deg(math.atan(v.Y, v.X))
        end
        local yaw = g.actorYaw or 0
        local mode = fake.props(g.cmc).MovementMode
        if mode == 3 then
            local target = p.InAirRotation and p.InAirRotation.Yaw or yaw
            p.TargetRotation.Yaw = normalized(target)
            g.actorYaw = interpTo(yaw, target, dt, 5)
        elseif (mode == 1 or mode == 2) and speed > 150 then
            local delta = normalized(p.LastVelocityRotation.Yaw - p.TargetRotation.Yaw)
            local step = 800 * dt
            p.TargetRotation.Yaw = normalized(p.TargetRotation.Yaw + math.max(-step, math.min(step, delta)))
            g.actorYaw = interpTo(yaw, p.TargetRotation.Yaw, dt, g.groundRotationRate)
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

    -- The end of a frame for the character's parts (see g.animTick).
    g.footsteps = 0
    local function endFrame(part, depth, paused)
        local d = data[part]
        if depth > 24 or not d or not d.alive then
            return
        end
        local p = d.props
        if d.anim and not paused then
            local drawn = d.lastRender ~= nil and d.lastRender > g.worldTime - 1
            if p.VisibilityBasedAnimTickOption < 2 or drawn then
                local info = fake.props(d.anim).CharacterInformation
                info.Speed = g.speed()
                info.bIsMoving = info.Speed > 1
                if info.bIsMoving then
                    g.footsteps = g.footsteps + 1
                end
            end
        end
        if d.drawnAt then
            d.lastRender, d.drawnAt = d.drawnAt, nil
        end
        if not d.undrawn and p.bOwnerNoSee == false and p.bHiddenInGame == false and p.bVisible ~= false then
            d.drawnAt = g.worldTime
        end
        for _, child in ipairs(p.AttachChildren or {}) do
            endFrame(child, depth + 1, paused)
        end
    end

    --- The end of a frame the world ticks. Each mesh with an animation of its own runs
    --- its graph, as Unreal 5.4 ticks it: always with the tick option 0 or 1, and from
    --- 2 on only if it was drawn in the last second (bRecentlyRendered; an unseen mesh
    --- then plays at most montages, none in the fake). The graph's anim notifies play
    --- the footsteps, counted in g.footsteps while the character moves. Then the
    --- renderer draws what the player's view shows: not what is hidden in game,
    --- invisible, or hidden from its owner (the view, shadows included, is the
    --- character's own), nor a part of a hidden actor (fake.setUndrawn). It draws a
    --- frame while the game thread works on the next one, so what it draws counts as
    --- drawn (LastRenderTime, which WasRecentlyRendered reads) only from the end of the
    --- next frame. On a frame Unreal runs as paused nothing animates, but the renderer
    --- still draws (at the world's time, which stands still).
    function g.animTick(paused)
        endFrame(fake.props(g.pawn).RootComponent, 0, paused)
    end

    --- One frame: input, the controller's tick (where the mod runs), the character's
    --- movement and the camera. Unreal decides at the start of the world's tick
    --- whether the frame runs paused (g.worldPaused, or else g.paused): then only the
    --- controller ticks, the world's time stays, and nothing moves.
    function g.frame(dt)
        dt = dt or 1 / 60
        local worldPaused = g.worldPaused
        if worldPaused == nil then
            worldPaused = g.paused
        end
        if not worldPaused then
            g.worldTime = g.worldTime + dt
        end
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
            -- ALS's JumpAction calls Jump() on each such event while the character is on
            -- the ground (its MovementState is Grounded while Unreal walks it), so
            -- bPressedJump is set again on every frame the key is held there.
            local mode = fake.props(g.cmc).MovementMode
            if jumpDown and (not g.jumpWasDown or mode == 1 or mode == 2) then
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
        if not worldPaused then
            g.moveTick(dt)
            -- The character ticks after its movement component.
            local characterTick = g.hooks[g.characterTickPath]
            if characterTick then
                g.inHook = true
                local ok, err = pcall(characterTick, fake.param(g.pawn), fake.param(dt))
                g.inHook = false
                assert(ok, err)
            end
            g.alsTick(dt) -- in the character's update, after its ReceiveTick
            g.updateCamera(dt) -- Unreal doesn't update the camera while the game is paused
            g.animTick()
        else
            g.animTick(true) -- the renderer goes on drawing
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

--- Makes main.lua's loadfile of config.lua give this table (nil: the real file). A
--- string is config.lua's text instead, which Lua then reads as it would the file:
--- for what a slip in the file does (a misspelt word, a lost comma).
function fake.useConfig(config)
    _G.loadfile = function(path, ...)
        if config ~= nil and tostring(path):match("config%.lua$") then
            if type(config) == "string" then
                return load(config, "@config.lua", ...)
            end
            return function()
                return config
            end
        end
        return realLoadfile(path, ...)
    end
end

-- main.lua and its modules as Lua compiled them, by path: each file is read and compiled
-- once in a run of the tests, and run again for every load. A compiled file is a
-- function, and running it again makes its locals and functions anew, so each game still
-- gets fresh copies. (Read and compiled for every game, loading took a quarter to two
-- fifths of the suite's CPU time, and with the tree on the Windows side of WSL, where
-- each file opened is slow, over half of its time on the clock.)
local compiled = {}
local scripts -- the folder of the main.lua fake.loadMod loads
fake.compiles = 0 -- the files compiled so far in this run

local function compiledFile(path)
    local chunk = compiled[path]
    if not chunk then
        chunk = assert(realLoadfile(path))
        compiled[path] = chunk
        fake.compiles = fake.compiles + 1
    end
    return chunk
end

-- Asked before Lua's own search: the mod's modules, from the folder main.lua puts first
-- in package.path (its own), compiled once and not opened again.
table.insert(package.searchers, 2, function(name)
    if not scripts or not name:match("^hl1movement%.") then
        return nil
    end
    local path = scripts .. name:gsub("%.", "/") .. ".lua"
    return compiledFile(path), path
end)

--- Loads main.lua afresh, with fresh copies of its modules.
function fake.loadMod(root)
    for name in pairs(package.loaded) do
        if name:match("^hl1movement%.") then
            package.loaded[name] = nil
        end
    end
    scripts = root .. "HL1Movement/Scripts/"
    compiledFile(scripts .. "main.lua")()
end

return fake
