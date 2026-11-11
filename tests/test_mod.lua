-- Runs main.lua against the fake game in tests/fake_game.lua, frame by frame.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7, F8 = 0x74, 0x75, 0x76, 0x77
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
local JOURNAL = "HL1Movement.changes"
local SCALE = 2.5
local MAX_SPEED = 320 * SCALE
local JUMP_SPEED = math.sqrt(2 * 800 * SCALE * 45 * SCALE)
local TAKEN_BRAKING = 1 -- what the mod leaves of the braking deceleration (cm/s²)
local EYE = 96 * 0.78 -- the "auto" eye height on the fake character

local function start(config, options)
    local g = fake.newGame(options)
    fake.useConfig(config)
    fake.loadMod(root)
    return g
end

local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone

local function running(config, options)
    local g = start(config, options)
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    return g
end

local function noErrors(g)
    t.absent(g.log, "Error in", "the mod logged an error")
    t.absent(g.log, "Turned off", "the mod turned something off")
end

local function count(lines, text)
    local n = 0
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The game's own camera, on its arm with its own settings, at location (0, 0, 0)
-- on the arm unless another is given.
local function gameCameraBack(g, cam, location)
    cam = cam or g.c.cineCamera
    location = location or { X = 0, Y = 0, Z = 0 }
    local link = g.c.attach[cam]
    t.truthy(link and link.parent == g.c.springArm, "the camera is back on its arm")
    t.eq(link.socket, "SpringEndpoint")
    local p = fake.props(cam)
    t.eq(p.bUsePawnControlRotation, false)
    t.eq(p.FieldOfView, 85)
    t.eq(p.FocusSettings.FocusMethod, 1, "its focus is back on")
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        t.eq(p.RelativeLocation[axis], location[axis], "its place on the arm, " .. axis)
    end
    t.eq(p.RelativeRotation.Yaw, 0)
    t.eq(fake.props(g.c.cameraController).EnableDynamicCameraFocus, true)
    t.eq(fake.props(g.c.cameraController).EnableCameraShakeWhenMoving, true)
end

-- Checks that the camera and the body are the game's own again.
local function cameraGivenBack(g)
    local pcm = fake.props(g.pcm)
    t.eq(g.style(), "Default")
    t.eq(pcm.DefaultFOV, 90)
    t.eq(pcm.ViewPitchMin, -60)
    t.eq(pcm.ViewPitchMax, 40)
    t.eq(fake.props(g.limiterModifier).PitchMin, -50)
    t.eq(fake.props(g.pawn).BaseEyeHeight, 64)
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false, "own mesh shown")
    t.eq(fake.props(g.c.skinMesh).bOwnerNoSee, false, "skin shown")
    t.eq(fake.props(g.c.propMesh).bHiddenInGame, false, "attached actor shown")
    gameCameraBack(g)
end

local function styleOf(g)
    return g.style()
end

local function runTo(g, speed)
    g.keys.W = true
    for _ = 1, 600 do
        g.frame()
        if g.speed() >= speed - 0.5 then
            return
        end
    end
    error("never reached " .. speed)
end

-- Hops while holding the right key and turning right, as when air strafing.
local function strafeHops(g, frames, dt, turnRate)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    dt = dt or 1 / 60
    g.frames(frames, dt, function()
        g.rotation.Yaw = g.rotation.Yaw + (turnRate or 72) * dt
    end)
end

-- First person with the game's camera at the eyes, after the engine's view failed.
local function onGameCamera(config, options)
    options = options or {}
    options.cameraStyleIgnored = true
    local g = running(config, options)
    g.frames(150)
    t.contains(g.log, "Moving the game's camera to the eyes instead")
    return g
end

t.test("loads, binds its keys and waits for a save", function()
    local g = start()
    t.contains(g.log, "Version 0.2.6 loaded")
    for _, code in ipairs({ F5, F6, F7, F8 }) do
        t.truthy(g.keybinds[code], "key bind " .. code)
    end
    t.falsy(g.hooks[g.tickPath], "the frame hook needs the game's classes")
    g.frame()
    t.eq(styleOf(g), "Default")
    g.loadSave()
    t.truthy(g.hooks[g.tickPath], "frame hook after loading a save")
    t.truthy(g.hooks[g.jumpPath], "jump hook after loading a save")
    t.contains(g.log, "Running every frame from")
    noErrors(g)
end)

t.test("a hook is only asked for once the game has the function", function()
    local tried = {}
    local g = start()
    local register = _G.RegisterHook
    _G.RegisterHook = function(path, callback)
        tried[#tried + 1] = path
        return register(path, callback)
    end
    g.hooks[RESTART](fake.param(g.pc), fake.param(g.pawn)) -- a character on the title screen
    t.eq(#tried, 0, "nothing tried before the game's classes exist")
    g.loadSave()
    t.truthy(#tried >= 1)
    t.truthy(g.hooks[g.tickPath])
end)

t.test("a new level is left alone for a moment", function()
    local g = start()
    g.loadSave()
    g.frames(150)
    t.eq(styleOf(g), "Default", "still settling")
    t.falsy(fake.writes(g.cmc).BrakingDecelerationWalking)
    t.contains(g.log, "First person: waiting (the game is still setting up the character)")
    g.frames(40)
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("first person follows the camera the game shows (Main_CineCamera), not MainCamera", function()
    local g = running()
    t.eq(g.cameraActive.MainCamera, nil, "MainCamera isn't active, as in the game")
    t.eq(styleOf(g), "FirstPerson")
    t.contains(g.log, "First person: on (the engine's first-person view)")
    noErrors(g)
end)

t.test("the camera style is set through the controller (UE4SS can't see the field in Unreal 5.4)", function()
    local g = running()
    t.eq(g.cameraStyle, "FirstPerson")
    t.eq(fake.props(g.pcm).CameraStyle, nil, "no CameraStyle field")
    g.frames(12)
    t.absent(g.log, "doesn't work")
    g.inBattle = true
    g.frame()
    t.eq(g.cameraStyle, "Default", "put back to Default")
    noErrors(g)
end)

t.test("engines that show the CameraStyle field: it is set and put back directly", function()
    local g = running(nil, { cameraStyleReflected = true })
    t.eq(fake.nameOf(fake.props(g.pcm).CameraStyle), "FirstPerson")
    t.eq(g.cameraStyle, "Default", "the controller's function isn't needed")
    g.inBattle = true
    g.frame()
    t.eq(fake.nameOf(fake.props(g.pcm).CameraStyle), "Default")
    noErrors(g)
end)

t.test("hotkeys work before a save is loaded", function()
    local g = start()
    local searched = false
    _G.FindFirstOf = function()
        searched = true
    end
    g.keybinds[F8]()
    t.contains(g.log, "HL1Movement 0.2.6 diagnostics")
    t.contains(g.log, "No player controller yet. Load a save, then press the report key again.")
    t.falsy(searched, "no search of the game's objects, which can crash it while it loads")
end)

t.test("hotkeys wait for the next frame when ExecuteInGameThread fails", function()
    local g = start(nil, { executeInGameThreadBroken = true })
    g.keybinds[F5]()
    t.absent(g.log, "Half-Life movement off")
    g.loadSave()
    g.frame()
    t.contains(g.log, "Half-Life movement off")
end)

t.test("first person: camera style, field of view, pitch limits and eye height", function()
    local g = running()
    g.frames(2)
    local pcm = fake.props(g.pcm)
    t.eq(styleOf(g), "FirstPerson")
    t.eq(pcm.DefaultFOV, 100)
    t.eq(pcm.ViewPitchMin, -89)
    t.eq(pcm.ViewPitchMax, 89)
    t.eq(fake.props(g.limiterModifier).PitchMin, -89)
    t.eq(fake.props(g.limiterModifier).PitchMax, 89)
    t.falsy(fake.writes(g.shakeModifier).PitchMin, "other modifiers are left alone")
    t.near(fake.props(g.pawn).BaseEyeHeight, EYE, 1e-9)
    t.falsy(g.c.attach[g.c.cineCamera].parent == g.c.capsule, "the game's camera stays on its arm")
    noErrors(g)
end)

t.test("with the engine's view, camera shakes are cleared now and then", function()
    local g = running()
    local before = g.shakeStops
    g.frames(60)
    t.truthy(g.shakeStops >= before + 2, "stopped about twice a second")
end)

t.test("first person hides the body from the player only, and leaves lights on", function()
    local g = running()
    local c = g.c
    t.eq(fake.props(c.mesh).bOwnerNoSee, true, "own mesh")
    t.eq(fake.props(c.skinMesh).bOwnerNoSee, true, "mesh of an actor the character owns")
    t.eq(fake.props(c.propMesh).bHiddenInGame, true, "mesh of an attached actor it doesn't own")
    t.eq(fake.props(c.propMesh).bOwnerNoSee, false)
    t.falsy(fake.writes(c.torchLight).bHiddenInGame, "light untouched")
    t.contains(g.log, "Hiding the character's body")
    noErrors(g)
end)

t.test("a body part replaced at the same address is hidden and shown again correctly", function()
    local g = running()
    local c = g.c
    t.eq(fake.props(c.skinMesh).bOwnerNoSee, true)
    -- The game swaps the character's skin: the old mesh is destroyed and a new one
    -- happens to get the same address.
    fake.destroy(c.skinMesh)
    local newSkin = fake.object({ className = "SkeletalMeshComponent", name = "NewSkinMesh",
        address = fake.addressOf(c.skinMesh),
        chain = { "SkeletalMeshComponent", "PrimitiveComponent", "SceneComponent", "ActorComponent", "Object" },
        props = { AttachChildren = fake.array({}), bOwnerNoSee = false, bHiddenInGame = false },
        methods = {
            GetOwner = fake.ufunction("GetOwner", 0, function()
                return c.skinActor
            end),
            SetOwnerNoSee = fake.ufunction("SetOwnerNoSee", 1, function(self, value)
                fake.props(self).bOwnerNoSee = value
            end),
            SetHiddenInGame = fake.ufunction("SetHiddenInGame", 2, function(self, value)
                fake.props(self).bHiddenInGame = value
            end),
        } })
    fake.set(c.mesh, "AttachChildren", fake.array({ newSkin, c.propMesh }))
    g.frames(70)
    t.eq(fake.props(newSkin).bOwnerNoSee, true, "the new part is hidden too")
    g.press(F6)
    t.eq(fake.props(newSkin).bOwnerNoSee, false, "and shown again when first person turns off")
    noErrors(g)
end)

t.test("a new part at a hidden part's address waits a pass like any new part, and is shown afterwards", function()
    local g = running()
    local c = g.c
    -- In UE4SS the old part's Lua object holds only the address: once a new part
    -- has it, the old object reads as valid again, and reads and writes the new part.
    local newSkin = fake.object({ className = "SkeletalMeshComponent", name = "NewSkinMesh",
        address = fake.addressOf(c.skinMesh),
        chain = { "SkeletalMeshComponent", "PrimitiveComponent", "SceneComponent", "ActorComponent", "Object" },
        props = { AttachChildren = fake.array({}), bOwnerNoSee = false, bHiddenInGame = false },
        methods = {
            GetOwner = fake.ufunction("GetOwner", 0, function()
                return c.skinActor
            end),
            SetOwnerNoSee = fake.ufunction("SetOwnerNoSee", 1, function(self, value)
                fake.props(self).bOwnerNoSee = value
            end),
            SetHiddenInGame = fake.ufunction("SetHiddenInGame", 2, function(self, value)
                fake.props(self).bHiddenInGame = value
            end),
        } })
    fake.reuseAddress(c.skinMesh, newSkin)
    fake.set(c.mesh, "AttachChildren", fake.array({ newSkin, c.propMesh }))
    g.frames(31)
    t.eq(fake.props(newSkin).bOwnerNoSee, false, "not touched on the pass it first appears")
    g.frames(31)
    t.eq(fake.props(newSkin).bOwnerNoSee, true, "hidden on the next pass")
    g.press(F6)
    t.eq(fake.props(newSkin).bOwnerNoSee, false, "and shown again when first person turns off")
    noErrors(g)
end)

t.test("a part the game shows during first person stays shown afterwards, though it was hidden before", function()
    local g = start()
    local prop = fake.props(g.c.propMesh)
    prop.bHiddenInGame = true -- put away when first person starts
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    prop.bHiddenInGame = false -- the game shows it
    g.frames(31)
    t.eq(prop.bHiddenInGame, true, "hidden again in first person")
    g.press(F6)
    t.eq(prop.bHiddenInGame, false, "shown afterwards, as the game wanted")
    -- Shown by the game just before first person ends, with no hiding pass between.
    prop.bHiddenInGame = true
    g.press(F6)
    g.frames(40)
    prop.bHiddenInGame = false
    g.press(F6)
    t.eq(prop.bHiddenInGame, false, "left shown")
    noErrors(g)
end)

t.test("a part attached while in first person is hidden one pass later", function()
    local g = running()
    local c = g.c
    local gear = fake.object({ className = "StaticMeshComponent", name = "NewGear",
        chain = { "StaticMeshComponent", "PrimitiveComponent", "SceneComponent", "ActorComponent", "Object" },
        props = { AttachChildren = fake.array({}), bOwnerNoSee = false, bHiddenInGame = false },
        methods = {
            GetOwner = fake.ufunction("GetOwner", 0, function()
                return c.pawn
            end),
            SetOwnerNoSee = fake.ufunction("SetOwnerNoSee", 1, function(self, value)
                fake.props(self).bOwnerNoSee = value
            end),
            SetHiddenInGame = fake.ufunction("SetHiddenInGame", 2, function(self, value)
                fake.props(self).bHiddenInGame = value
            end),
        } })
    local children = fake.props(c.mesh).AttachChildren
    children[#children + 1] = gear
    g.frames(31)
    t.eq(fake.props(gear).bOwnerNoSee, false, "not touched on the pass it first appears")
    g.frames(31)
    t.eq(fake.props(gear).bOwnerNoSee, true, "hidden on the next pass")
    noErrors(g)
end)

t.test("the first-person check passes when the camera is at the eyes", function()
    local g = running()
    g.frames(200)
    t.absent(g.log, "doesn't work")
    g.press(F8)
    t.contains(g.log, "First person: working with the engine's first-person view")
end)

t.test("CameraMethod engine: if first person doesn't take effect, the mod gives up and shows the character", function()
    local g = running({ CameraMethod = "engine" }, { cameraStyleIgnored = true })
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true, "hidden while it checks")
    g.frames(150)
    t.contains(g.log, "First person doesn't work here: the camera stayed 3")
    t.absent(g.log, "Moving the game's camera")
    cameraGivenBack(g)
    g.actorYaw = nil
    g.rotation.Yaw = 45
    g.frames(40)
    t.eq(g.actorYaw, nil, "the character isn't turned to the view any more")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING, "the movement stays")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false, "and the body stays visible")
    -- The camera key tries again.
    g.press(F6)
    g.press(F6)
    g.frames(10)
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true, "trying again")
    g.frames(150)
    t.eq(count(g.log, "First person doesn't work here"), 2)
    cameraGivenBack(g)
    noErrors(g)
end)

t.test("auto: if the engine's view doesn't reach the eyes, the game's camera is moved there", function()
    local g = onGameCamera()
    local c = g.c
    local cine = fake.props(c.cineCamera)
    t.truthy(c.attach[c.cineCamera].parent == c.capsule, "attached to the capsule")
    t.near(cine.RelativeLocation.Z, EYE, 1e-9, "at eye height")
    t.eq(cine.RelativeLocation.X, 0)
    t.eq(cine.bUsePawnControlRotation, true, "turns with the mouse")
    t.eq(cine.FieldOfView, 100)
    t.eq(cine.FocusSettings.FocusMethod, 3, "its depth of field is off")
    t.eq(fake.props(c.cameraController).EnableDynamicCameraFocus, false)
    t.eq(fake.props(c.cameraController).EnableCameraShakeWhenMoving, false)
    t.eq(styleOf(g), "Default", "the engine's style is put back")
    t.eq(fake.props(c.mesh).bOwnerNoSee, true, "the body stays hidden")
    t.truthy(distance(g.cameraLocation, g.eyes()) < 1, "the view is at the eyes")
    g.frames(60)
    t.contains(g.log, "First person: on (the game's camera at the eyes), the view is at the eyes")
    t.absent(g.log, "doesn't work here:")
    noErrors(g)
end)

t.test("switching first person off puts the game's camera back as it was", function()
    local g = start(nil, { cameraStyleIgnored = true })
    local l = fake.props(g.c.cineCamera).RelativeLocation
    l.X, l.Y, l.Z = 10, 20, 30
    g.loadSave()
    g.frames(SETTLE_FRAMES + 150)
    t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule)
    g.press(F6)
    gameCameraBack(g, nil, { X = 10, Y = 20, Z = 30 })
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false)
    for _, kind in ipairs({ "attach", "hide", "style" }) do
        t.eq(g.shared[JOURNAL]:find(kind .. "\t", 1, true), nil, "no " .. kind .. " left to put back")
    end
    noErrors(g)
end)

t.test("the game attaching its camera to the arm again: it is moved back to the eyes", function()
    local g = onGameCamera()
    local c = g.c
    -- Attached keeping its relative location, which is still the mod's place at the eyes.
    c.attachTo(c.cineCamera, c.springArm, "SpringEndpoint")
    g.frame()
    t.truthy(c.attach[c.cineCamera].parent == c.capsule, "at the eyes again")
    t.contains(g.log, "The game attached its camera to SpringArmComponent")
    g.inBattle = true
    g.frame()
    gameCameraBack(g) -- at its own place on the arm, not the mod's
    -- Attached with a new place of its own: that is the one put back.
    g.inBattle = false
    g.frames(20)
    t.truthy(c.attach[c.cineCamera].parent == c.capsule)
    c.attachTo(c.cineCamera, c.springArm, "SpringEndpoint")
    local l = fake.props(c.cineCamera).RelativeLocation
    l.X, l.Y, l.Z = 5, 0, 10
    g.frame()
    t.truthy(c.attach[c.cineCamera].parent == c.capsule)
    g.inBattle = true
    g.frame()
    gameCameraBack(g, nil, { X = 5, Y = 0, Z = 10 })
    -- Attached with a field of view of its own: that is the one put back.
    g.inBattle = false
    g.frames(20)
    c.attachTo(c.cineCamera, c.springArm, "SpringEndpoint")
    c.cineCamera:SetFieldOfView(60)
    g.frames(3)
    t.truthy(c.attach[c.cineCamera].parent == c.capsule)
    t.eq(fake.props(c.cineCamera).FieldOfView, 100)
    g.inBattle = true
    g.frame()
    t.eq(fake.props(c.cineCamera).FieldOfView, 60)
    noErrors(g)
end)

t.test("the game's camera settings changed meanwhile are the ones put back", function()
    local g = onGameCamera()
    local cine = fake.props(g.c.cineCamera)
    cine.FieldOfView = 70 -- the game zooms its camera
    g.frame()
    g.frame()
    t.eq(cine.FieldOfView, 100, "the mod's field of view again")
    cine.RelativeLocation.X, cine.RelativeLocation.Y, cine.RelativeLocation.Z = 5, 6, 7 -- a new camera setting
    g.frame()
    t.near(cine.RelativeLocation.Z, EYE, 1e-9, "back at the eyes")
    t.eq(cine.RelativeLocation.X, 0)
    g.press(F6)
    t.eq(cine.FieldOfView, 70, "the game's latest field of view")
    t.eq(cine.RelativeLocation.X, 5, "and its latest position")
    t.eq(cine.RelativeLocation.Z, 7)
    noErrors(g)
end)

t.test("a cine camera that can't reach the field of view isn't taken for the game changing it", function()
    local g = onGameCamera(nil, { cineFovLimit = 95 })
    g.frames(30)
    t.eq(fake.props(g.c.cineCamera).FieldOfView, 95)
    g.press(F6)
    t.eq(fake.props(g.c.cineCamera).FieldOfView, 85, "the game's own field of view comes back")
end)

t.test("...nor when the camera is moved as first person starts: with CameraMethod game, or after a dialogue",
    function()
        local g = running({ CameraMethod = "game" }, { cineFovLimit = 95 })
        g.frames(30)
        local cine = fake.props(g.c.cineCamera)
        t.eq(cine.FieldOfView, 95)
        t.contains(g.log, "shows a field of view of 95.0 although the mod sets FieldOfView 100")
        g.press(F6)
        t.eq(cine.FieldOfView, 85, "CameraMethod game")
        g = onGameCamera(nil, { cineFovLimit = 95 })
        cine = fake.props(g.c.cineCamera)
        g.inDialogue = true
        g.frames(20)
        t.eq(cine.FieldOfView, 85)
        g.inDialogue = false
        g.frames(30)
        t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule, "at the eyes again after the dialogue")
        g.press(F6)
        t.eq(cine.FieldOfView, 85, "moved again after a dialogue")
        noErrors(g)
    end)

t.test("the game changing the field of view over several frames: the mod's comes back, then the game's last",
    function()
        for _, n in ipairs({ 1, 2, 3, 6, 7 }) do
            local g = onGameCamera()
            local cam = g.c.cineCamera
            local cine = fake.props(cam)
            local i = 0
            -- Written after the controller's tick, as the game's camera blends and look-ats do.
            g.afterMove = function()
                i = i + 1
                if i <= n then
                    cam:SetFieldOfView(70 + 20 * i / n)
                end
            end
            g.frames(n + 5)
            t.eq(cine.FieldOfView, 100, n .. " frames: the mod's field of view again")
            g.afterMove = nil
            g.press(F6)
            t.near(cine.FieldOfView, 90, 1e-9, n .. " frames: the game's last one comes back")
        end
        -- The game holding one value for a while.
        local g = onGameCamera()
        local cam = g.c.cineCamera
        g.afterMove = function()
            cam:SetFieldOfView(80)
        end
        g.frames(10)
        g.afterMove = nil
        g.frames(3)
        t.eq(fake.props(cam).FieldOfView, 100)
        g.press(F6)
        t.eq(fake.props(cam).FieldOfView, 80)
        noErrors(g)
    end)

t.test("the game changing the field of view as the camera is moved: the mod's still comes, the game's goes back",
    function()
        -- One write in the frame of the move, after the controller's tick.
        local g = running({ CameraMethod = "game" })
        local cam = g.c.cineCamera
        local cine = fake.props(cam)
        g.press(F6)
        local writes = 0
        g.afterMove = function()
            if writes < 1 and g.c.attach[cam].parent == g.c.capsule then
                writes = writes + 1
                cam:SetFieldOfView(70)
            end
        end
        g.press(F6)
        g.frames(30)
        t.eq(cine.FieldOfView, 100, "the mod's field of view")
        t.absent(g.log, "shows a field of view of", "the game's write isn't taken for the lens")
        g.press(F6)
        t.eq(cine.FieldOfView, 70, "the game's last one comes back")
        -- The same value written on two frames in a row looks like a lens limit at
        -- first; it is checked again at the next refresh.
        writes = -1
        g.press(F6)
        g.frames(40)
        g.afterMove = nil
        t.eq(cine.FieldOfView, 100, "the mod's field of view, within half a second")
        t.absent(g.log, "shows a field of view of")
        g.press(F6)
        t.eq(cine.FieldOfView, 70, "the game's last one comes back")
        -- An animation running when first person starts, then quiet frames.
        g = running({ CameraMethod = "game" })
        cam = g.c.cineCamera
        cine = fake.props(cam)
        g.press(F6)
        local i = 0
        g.afterMove = function()
            i = i + 1
            if i <= 10 then
                cam:SetFieldOfView(85 - 15 * i / 10)
            end
        end
        g.frames(3)
        g.press(F6)
        g.frames(20)
        g.afterMove = nil
        local sets = 0
        fake.method(cam, "SetFieldOfView", fake.ufunction("SetFieldOfView", 1, function(_, fov)
            sets = sets + 1
            cine.FieldOfView = fov
        end))
        g.frames(60)
        t.eq(sets, 0, "nothing to set again once the game stopped")
        t.eq(cine.FieldOfView, 100)
        g.press(F6)
        t.near(cine.FieldOfView, 70, 1e-9, "the game's last one comes back")
        noErrors(g)
        -- The same with a lens that can't go wider than 95.
        g = running({ CameraMethod = "game" }, { cineFovLimit = 95 })
        cam = g.c.cineCamera
        cine = fake.props(cam)
        g.press(F6)
        i = 0
        g.afterMove = function()
            if g.c.attach[cam].parent == g.c.capsule then
                i = i + 1
                if i <= 10 then
                    cam:SetFieldOfView(85 - 15 * i / 10)
                end
            end
        end
        g.press(F6)
        g.frames(60)
        g.afterMove = nil
        t.eq(cine.FieldOfView, 95)
        g.press(F6)
        t.near(cine.FieldOfView, 70, 1e-9, "the game's last one comes back, with a lens limit")
        noErrors(g)
    end)

t.test("a lens limit and a camera moved while paused: the first frame after the pause comes before the update",
    function()
        for _, key in ipairs({ F6, F7 }) do
            local g = running({ CameraMethod = "game" }, { cineFovLimit = 95 })
            local cine = fake.props(g.c.cineCamera)
            g.frames(30)
            g.paused = true
            g.frames(5)
            if key == F6 then
                g.press(F6)
                g.frames(3)
            end
            g.press(key)
            g.frames(10)
            g.paused = false
            g.frames(60)
            t.eq(cine.FieldOfView, 95)
            g.press(F6)
            t.eq(cine.FieldOfView, 85, "the game's own field of view comes back")
            noErrors(g)
        end
    end)

t.test("a lens limit and a game blend that eases in as the camera is moved: its small steps aren't the lens",
    function()
        local g = running({ CameraMethod = "game" }, { cineFovLimit = 95 })
        local cam = g.c.cineCamera
        local cine = fake.props(cam)
        g.press(F6)
        local i, frames = 0, 60
        -- VTBlend_Cubic, the engine's default blend, from 70 to 85 over a second,
        -- written after the controller's tick from the frame the camera is moved.
        g.afterMove = function()
            if i < frames then
                i = i + 1
                local x = i / frames
                cam:SetFieldOfView(70 + 15 * x * x * (3 - 2 * x))
            end
        end
        g.press(F6)
        g.frames(frames + 30)
        g.afterMove = nil
        local sets = 0
        fake.method(cam, "SetFieldOfView", fake.ufunction("SetFieldOfView", 1, function(_, fov)
            sets = sets + 1
            cine.FieldOfView = fov
        end))
        g.frames(60)
        t.eq(cine.FieldOfView, 95)
        t.truthy(sets <= 2, "the mod's field of view isn't set again every frame (" .. sets .. " sets)")
        t.contains(g.log, "shows a field of view of 95.0 although the mod sets FieldOfView 100")
        g.press(F6)
        t.near(cine.FieldOfView, 85, 1e-9, "the game's last one comes back, not the lens limit")
        noErrors(g)
    end)

t.test("a re-attach while paused, or before the view was worked out, takes in the game's field of view",
    function()
        for _, lens in ipairs({ false, 95 }) do
            -- Paused, long after the move.
            local g = running({ CameraMethod = "game" }, { cineFovLimit = lens or nil })
            local cam = g.c.cineCamera
            local cine = fake.props(cam)
            g.frames(60)
            g.paused = true
            g.frame()
            g.c.attachTo(cam, g.c.springArm, "SpringEndpoint")
            cam:SetFieldOfView(70)
            g.frames(5)
            g.paused = false
            g.frames(60)
            t.truthy(g.c.attach[cam].parent == g.c.capsule, "back at the eyes")
            g.press(F6)
            t.eq(cine.FieldOfView, 70, "paused: the game's field of view comes back")
            -- Moved while paused; the game re-attaches as it unpauses.
            g.frames(10)
            g.paused = true
            g.frames(3)
            g.press(F6)
            g.frames(3)
            g.c.attachTo(cam, g.c.springArm, "SpringEndpoint")
            cam:SetFieldOfView(75)
            g.paused = false
            g.frames(60)
            g.press(F6)
            t.eq(cine.FieldOfView, 75, "before the view was worked out: the game's field of view comes back")
            -- Re-attached without a field of view of its own, right after the move, then
            -- paused: what the lens made of the mod's isn't taken for the game's.
            g.frames(10)
            g.press(F6)
            g.c.attachTo(cam, g.c.springArm, "SpringEndpoint")
            g.paused = true
            g.frames(5)
            g.paused = false
            g.frames(60)
            g.press(F6)
            t.eq(cine.FieldOfView, 75, "no field of view of the game's: its last one comes back")
            -- Moved while paused and re-attached before the view was worked out, without a
            -- field of view of the game's: the mod's own value isn't taken for the game's.
            g.frames(10)
            g.paused = true
            g.frame()
            g.press(F6)
            g.c.attachTo(cam, g.c.springArm, "SpringEndpoint")
            g.frames(3)
            g.paused = false
            g.frames(60)
            g.press(F6)
            t.eq(cine.FieldOfView, 75, "before the view was worked out, without a field of view of the game's")
            noErrors(g)
        end
    end)

t.test("once the engine's view didn't work, the next character starts with the game's camera", function()
    local g = onGameCamera()
    g.useCharacter(g.buildCharacter())
    local c = g.c
    g.frames(SETTLE_FRAMES)
    t.truthy(c.attach[c.cineCamera].parent == c.capsule, "moved straight away")
    t.eq(count(g.log, "Moving the game's camera to the eyes instead"), 1, "without trying the engine's view first")
    noErrors(g)
end)

t.test("CameraMethod game uses the game's camera from the start", function()
    local g = running({ CameraMethod = "game" })
    t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule)
    t.eq(styleOf(g), "Default", "the engine's style isn't used")
    t.truthy(distance(g.cameraLocation, g.eyes()) < 1)
    noErrors(g)
end)

t.test("a game camera that can't be moved: first person is given up and everything put back", function()
    local g = running(nil, { cameraStyleIgnored = true, attachIgnored = true })
    g.frames(400)
    local line = t.contains(g.log, "First person doesn't work here: the camera stayed")
    t.truthy(line:find("with the engine's first-person view, and the game's camera couldn't be moved to the eyes "
        .. "(", 1, true), line)
    t.truthy(line:find("Unreal refused to attach the camera to the character's capsule", 1, true), line)
    t.absent(g.log, "The game attached its camera", "the mod's own failed attachment isn't blamed on the game")
    cameraGivenBack(g)
    t.eq(g.shared[JOURNAL]:find("attach", 1, true), nil, "nothing left in the journal")
end)

t.test("auto: if the camera style can't be switched, the game's camera is moved to the eyes", function()
    local g = start()
    fake.method(g.pc, "ClientSetCameraMode", function()
        error("ClientSetCameraMode isn't available")
    end)
    g.loadSave()
    g.frames(SETTLE_FRAMES + 150)
    t.contains(g.log, "Could not switch the camera style")
    t.contains(g.log, "the camera style could not be switched). Moving the game's camera")
    t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule)
    t.truthy(distance(g.cameraLocation, g.eyes()) < 1)
end)

t.test("CameraMethod engine: if the camera style can't be switched, the mod gives up", function()
    local g = start({ CameraMethod = "engine" })
    fake.method(g.pc, "ClientSetCameraMode", function()
        error("ClientSetCameraMode isn't available")
    end)
    g.loadSave()
    g.frames(SETTLE_FRAMES + 150)
    t.contains(g.log, "Could not switch the camera style")
    t.contains(g.log, "First person doesn't work here: the camera style could not be switched")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false)
    t.eq(fake.props(g.c.propMesh).bHiddenInGame, false)
    t.eq(fake.props(g.pawn).BaseEyeHeight, 64)
    t.eq(fake.props(g.pcm).DefaultFOV, 90)
end)

t.test("a slow camera blend to the eyes isn't taken for first person not working", function()
    local g = start()
    g.cameraLocation = { X = -300, Y = 0, Z = 150 }
    g.cameraSpeed = 100 -- over three seconds to reach the eyes
    g.loadSave()
    g.frames(SETTLE_FRAMES + 360)
    t.absent(g.log, "doesn't work")
    t.absent(g.log, "Moving the game's camera")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true)
    g.press(F8)
    t.contains(g.log, "First person: working")
end)

t.test("while the game is paused, first person isn't given up", function()
    local g = start()
    g.loadSave()
    g.frames(SETTLE_FRAMES - 20)
    g.paused = true -- paused just before first person starts, so the camera can't follow
    g.frames(300)
    t.absent(g.log, "doesn't work")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true)
    g.paused = false
    g.frames(150)
    t.absent(g.log, "doesn't work")
    t.absent(g.log, "Moving the game's camera")
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("body follows the view yaw", function()
    local g = running()
    g.rotation.Yaw = 123
    g.frame()
    t.eq(g.actorYaw, 123)
    t.eq(fake.props(g.pawn).TargetRotation.Yaw, 123)
end)

t.test("movement takes over the game's values", function()
    local g = running()
    local p = fake.props(g.cmc)
    t.eq(p.bUseSeparateBrakingFriction, true)
    t.eq(p.BrakingFriction, 0)
    t.eq(p.BrakingDecelerationWalking, TAKEN_BRAKING)
    t.eq(p.BrakingDecelerationFalling, TAKEN_BRAKING)
    t.eq(p.CurrentMovementSettings.MovementCurve, nil, "movement curve taken out")
    t.eq(p.MaxWalkSpeed, 100000)
    t.near(p.GravityScale, 800 * SCALE / 980, 1e-9)
    t.near(p.JumpZVelocity, JUMP_SPEED, 1e-9)
    t.eq(fake.props(g.pawn).JumpMaxHoldTime, 0)
    t.eq(g.limiterTicking, false, "the game's speed limiter is paused")
    noErrors(g)
end)

t.test("walking reaches Half-Life's max speed and the game doesn't accelerate on its own", function()
    local g = running()
    g.keys.W = true
    g.frames(30)
    t.near(g.speed(), MAX_SPEED, 1, "max speed after half a second")
    t.falsy(g.engineAccelerated, "the game got no movement input")
    local v = fake.props(g.cmc).Velocity
    t.near(v.Y, 0, 1e-6, "straight ahead at yaw 0")
    noErrors(g)
end)

t.test("walking follows the view", function()
    local g = running()
    g.rotation.Yaw = 90
    g.frame() -- turned before walking: a turn during a frame is spread over its updates
    g.keys.W = true
    g.frames(30)
    local v = fake.props(g.cmc).Velocity
    t.near(v.X, 0, 1e-6)
    t.near(v.Y, MAX_SPEED, 1)
end)

t.test("letting go slows down with Half-Life friction", function()
    local g = running({ PhysicsRate = 0 })
    runTo(g, MAX_SPEED)
    local before = g.speed()
    g.keys.W = false
    g.frame()
    t.near(g.speed(), before - before * 4 / 60, 0.5, "one frame of friction 4")
    g.frames(60)
    t.eq(g.speed(), 0, "stopped after a second")
end)

t.test("with updates at 100 a second, friction is Half-Life's whatever the frame rate", function()
    local speeds = {}
    for _, dt in ipairs({ 1 / 30, 1 / 100 }) do
        local g = running()
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.frames(math.floor(0.2 / dt + 0.5), dt)
        speeds[#speeds + 1] = g.speed()
    end
    t.near(speeds[1], speeds[2], 1, "after 0.2 s at 30 and at 100 fps")
    t.near(speeds[2], MAX_SPEED * 0.96 ^ 20, 1, "20 updates of friction 4")
end)

t.test("holding jump hops on every landing and keeps the speed", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    local landings = g.landings
    g.frame()
    t.eq(g.mode(), 3, "jumping")
    t.near(fake.props(g.cmc).Velocity.Z, JUMP_SPEED + -980 * fake.props(g.cmc).GravityScale / 60, 1e-6)
    g.frames(180)
    t.truthy(g.landings - landings >= 3, "landed " .. (g.landings - landings) .. " times")
    t.near(g.speed(), MAX_SPEED, 1, "no speed lost over the hops")
    t.eq(g.gameJumps, 0, "the mod's jump comes first")
    noErrors(g)
end)

t.test("air strafing builds speed past the max speed", function()
    local g = running()
    strafeHops(g, 300)
    t.truthy(g.speed() > MAX_SPEED * 1.2, string.format("speed %.0f should be well above %.0f", g.speed(), MAX_SPEED))
    noErrors(g)
end)

t.test("air strafing at 30 fps gains about as much as at 100 fps", function()
    local gains = {}
    for _, dt in ipairs({ 1 / 30, 1 / 100 }) do
        local g = running()
        strafeHops(g, math.floor(3 / dt + 0.5), dt, 200)
        gains[#gains + 1] = g.speed() - MAX_SPEED
    end
    t.truthy(gains[2] > 100, string.format("gain at 100 fps: %.0f", gains[2]))
    t.truthy(gains[1] >= gains[2] * 0.9, string.format("gain at 30 fps %.0f, at 100 fps %.0f", gains[1], gains[2]))
end)

t.test("each hop is logged with its speeds, and the status line with the updates", function()
    local g = running()
    strafeHops(g, 600)
    local line = t.contains(g.log, "Hop 1 (")
    t.truthy(line:find("take-off", 1, true) and line:find("landing", 1, true) and line:find("keys D", 1, true), line)
    t.contains(g.log, "Half-Life updates each")
    t.contains(g.log, "the view turned")
    noErrors(g)
end)

t.test("without auto hop, holding jump doesn't hop again", function()
    local g = running({ AutoHop = false })
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    g.frames(90)
    t.eq(g.mode(), 1, "stays on the ground while held")
    g.keys.SpaceBar = false
    g.frame()
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3, "jumps on a new press")
end)

t.test("a scroll-wheel press counts as a jump", function()
    local g = running({ AutoHop = false, JumpKeys = { "MouseScrollDown" } })
    g.justPressed.MouseScrollDown = true
    g.frame()
    t.eq(g.mode(), 3)
end)

t.test("battle gives the camera and the movement back", function()
    local g = running()
    g.keys.W = true
    g.frames(5)
    g.inBattle = true
    g.frame()
    local pcm, p = fake.props(g.pcm), fake.props(g.cmc)
    t.eq(styleOf(g), "Default")
    t.eq(pcm.DefaultFOV, 90)
    t.eq(pcm.ViewPitchMin, -60)
    t.eq(pcm.ViewPitchMax, 40)
    t.eq(fake.props(g.limiterModifier).PitchMin, -50)
    t.eq(fake.props(g.pawn).BaseEyeHeight, 64)
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false)
    t.eq(fake.props(g.c.propMesh).bHiddenInGame, false)
    t.eq(p.bUseSeparateBrakingFriction, false)
    t.eq(p.BrakingDecelerationWalking, 2048)
    t.eq(p.GravityScale, 1)
    t.eq(p.JumpZVelocity, 450)
    t.eq(p.CurrentMovementSettings.MovementCurve, g.c.curve, "curve put back")
    t.eq(fake.props(g.pawn).JumpMaxHoldTime, 0.2)
    t.eq(g.limiterTicking, true)
    t.eq(p.MaxWalkSpeed, 600, "the game's own walking speed")
    t.falsy(fake.writes(g.cmc).bRequestMovementSettingsChange, "ALS's uint8 flag is left alone")
    g.inBattle = false
    g.frame()
    t.eq(styleOf(g), "FirstPerson", "back after the battle")
    t.eq(p.BrakingDecelerationWalking, TAKEN_BRAKING)
    noErrors(g)
end)

t.test("the walking speed the game sets while the mod runs is the one put back", function()
    local g = running()
    local p = fake.props(g.cmc)
    p.bRequestMovementSettingsChange = 1 -- ALS asks for its gait's speed, as on a gait change
    g.frame()
    t.eq(p.MaxWalkSpeed, 375, "ALS wrote its speed during the game's movement update")
    g.frame()
    t.eq(p.MaxWalkSpeed, 100000, "the mod's value again")
    t.contains(g.log, "The game set MaxWalkSpeed to 375")
    g.inBattle = true
    g.frame()
    t.eq(p.MaxWalkSpeed, 375, "ALS's latest speed comes back")
    g.inBattle = false
    g.frame()
    p.MaxWalkSpeed = 200 -- the game slows the character down in some area
    g.frames(3)
    g.press(F5)
    t.eq(p.MaxWalkSpeed, 200, "the game's latest speed comes back")
    t.eq(p.BrakingDecelerationWalking, 2048, "values the game didn't touch come back as they were")
    noErrors(g)
end)

t.test("the speed limiter is checked every frame and paused again if the game starts it", function()
    local g = running()
    t.eq(g.limiterTicking, false)
    g.limiterTicking = true
    g.frame()
    t.eq(g.limiterTicking, false, "paused again on the next frame")
    t.contains(g.log, "The game turned its speed limiter on again")
    g.inBattle = true
    g.frame()
    t.eq(g.limiterTicking, true, "on again after the mod hands back")
end)

t.test("without the limiter property, the limiter is found among the components", function()
    local g = running(nil, { noLimiterProperty = true })
    t.eq(g.limiterTicking, false)
    noErrors(g)
end)

t.test("KeepSpeed: the game's speed limiter cutting the speed at jumps and landings is undone", function()
    local g = running(nil, { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true })
    strafeHops(g, 300)
    t.truthy(g.speed() > MAX_SPEED * 1.2, string.format("speed %.0f should be well above %.0f", g.speed(), MAX_SPEED))
    local line = t.contains(g.log, "The game cut the speed from ")
    t.truthy(line:find("to 260 u/s (in the air", 1, true), line)
    t.truthy(line:find("speed limiter started again by the game", 1, true), line)
    t.contains(g.log, "to 260 u/s (on landing")
    t.contains(g.log, "the speed is kept")
    t.contains(g.log, "The game turned its speed limiter on again")
    t.contains(g.log, "GetMaxSpeed() is 650 cm/s although the mod set MaxWalkSpeed")
    noErrors(g)
end)

t.test("KeepSpeed off: the game's cuts stay, and the log says so", function()
    local g = running({ KeepSpeed = false }, { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true })
    strafeHops(g, 300)
    t.truthy(g.speed() < MAX_SPEED, string.format("speed %.0f stays below %.0f", g.speed(), MAX_SPEED))
    t.contains(g.log, "KeepSpeed is off, so the cut stays")
end)

t.test("a wall turning the velocity, or a stop, isn't taken for a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    local angle = math.rad(30)
    g.afterMove = function(v)
        -- Sliding along a wall: turned by 30 degrees and shortened to match.
        local x, y = v.X, v.Y
        v.X = (x * math.cos(angle) - y * math.sin(angle)) * math.cos(angle)
        v.Y = (x * math.sin(angle) + y * math.cos(angle)) * math.cos(angle)
        g.afterMove = nil
    end
    g.keys.W = false
    g.frame()
    local slid = g.speed()
    g.frame()
    t.truthy(g.speed() <= slid, "not put back to the speed before the wall")
    g.afterMove = function(v)
        v.X, v.Y = 0, 0
        g.afterMove = nil
    end
    g.frame()
    g.frame()
    t.eq(g.speed(), 0)
    t.absent(g.log, "The game cut the speed")
end)

t.test("a wall or a step that stops the move part of the way isn't taken for a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.moveShare = 0.5 -- running into something: half of each move happens
    g.frames(5)
    t.absent(g.log, "The game cut the speed")
    t.truthy(g.speed() < MAX_SPEED * 0.6, "the speed isn't put back")
    g.moveShare = nil
    noErrors(g)
end)

t.test("KeepSpeed: a cut by the speed limiter to under a fifth of the speed is undone too", function()
    local g = running(nil, { limiterWakesOnModeChange = true, maxSpeedIgnoresWalkSpeed = true })
    fake.props(g.cmc).CurrentMovementSettings.SprintSpeed = 100 -- the limiter caps at 100 cm/s
    strafeHops(g, 300)
    t.truthy(g.speed() > MAX_SPEED, string.format("speed %.0f should stay above %.0f", g.speed(), MAX_SPEED))
    t.contains(g.log, "to 40 u/s (")
    noErrors(g)
end)

t.test("KeepSpeed: a cap at the landing's mode change, part of the way through the move, is undone too", function()
    -- A listener of the landing (the game's speed limiter may be one) caps the speed
    -- inside Unreal's update, and the rest of that frame is walked at the capped speed.
    local g = running(nil, { landingListenerClamps = true, maxSpeedIgnoresWalkSpeed = true })
    strafeHops(g, 300)
    t.truthy(g.landingClamps >= 5, "the game capped the speed at landings")
    t.truthy(g.speed() > MAX_SPEED * 1.2, string.format("speed %.0f should be well above %.0f", g.speed(), MAX_SPEED))
    t.contains(g.log, "to 260 u/s (on landing")
    noErrors(g)
end)

t.test("on a moving platform, the platform's own motion isn't taken for the character's", function()
    local g = running()
    runTo(g, MAX_SPEED)
    -- A railing on a platform moving along the run stops part of each move: no cut.
    g.baseVelocity = { X = 300, Y = 0, Z = 0 }
    g.frames(3)
    g.moveShare = 0.7
    g.frames(5)
    t.absent(g.log, "The game cut the speed")
    g.moveShare = nil
    g.frames(30)
    -- A cap after the move, on a platform moving the other way, is undone.
    g.baseVelocity = { X = -300, Y = 0, Z = 0 }
    g.frames(3)
    g.afterMove = function(v)
        local s = math.sqrt(v.X * v.X + v.Y * v.Y)
        if s > 650 then
            v.X, v.Y = v.X / s * 650, v.Y / s * 650
        end
    end
    g.frames(5)
    g.afterMove = nil
    g.frame()
    t.near(g.speed(), MAX_SPEED, 1, "the speed is back on the next frame")
    t.contains(g.log, "The game cut the speed from 320 to 260 u/s (on the ground")
    noErrors(g)
end)

t.test("walking off a moving platform keeps its velocity, as a jump does, and isn't a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.position.Z = 1000 -- the platform is high above the fake's ground
    g.baseVelocity = { X = -300, Y = 0, Z = 0 } -- moving against the run
    g.frames(3)
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        -- Carried by the platform, Unreal walks half the frame to the edge. There its
        -- StartFalling sets the mode to Falling, which adds the velocity of the platform
        -- left behind (ApplyImpartedMovementBaseVelocity), and the rest is a fall.
        local v, pos = fake.props(g.cmc).Velocity, g.position
        g.pending = { X = 0, Y = 0, Z = 0 }
        pos.X = pos.X + g.baseVelocity.X * dt + v.X * dt / 2
        g.cmc:SetMovementMode(3, 0)
        g.baseVelocity = nil
        pos.X = pos.X + v.X * dt / 2
    end
    g.frames(3)
    t.eq(g.mode(), 3)
    t.near(g.speed(), MAX_SPEED - 300, 5, "the platform's velocity is kept")
    t.absent(g.log, "The game cut the speed")
    noErrors(g)
end)

t.test("with bStayBasedInAir, walking off a moving platform adds nothing, and isn't a speed cut", function()
    local g = running(nil, { stayBasedInAir = true })
    runTo(g, MAX_SPEED)
    g.position.Z = 1000 -- the platform is high above the fake's ground
    g.baseVelocity = { X = 300, Y = 0, Z = 0 } -- moving along the run
    g.frames(3)
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        -- Unreal walks half the frame to the edge and starts falling. With
        -- bStayBasedInAir the platform stays the character's base and goes on carrying
        -- it, and nothing is added to its velocity.
        local v, pos = fake.props(g.cmc).Velocity, g.position
        g.pending = { X = 0, Y = 0, Z = 0 }
        pos.X = pos.X + g.baseVelocity.X * dt + v.X * dt / 2
        g.cmc:SetMovementMode(3, 0)
        pos.X = pos.X + v.X * dt / 2
    end
    g.frames(3)
    t.eq(g.mode(), 3)
    t.near(g.speed(), MAX_SPEED, 5, "relative to the platform, which still carries the character")
    -- Carried in the air, something in the way stops part of each move: no cut either.
    g.moveShare = 0.7
    g.frames(3)
    g.moveShare = nil
    t.absent(g.log, "The game cut the speed")
    noErrors(g)
end)

t.test("with bStayBasedInAir, a cap as the character walks off a moving platform is undone to its speed on it",
    function()
        for _, platform in ipairs({ 300, -300 }) do
            local g = running(nil, { stayBasedInAir = true, jumpListenerClamps = true })
            runTo(g, MAX_SPEED)
            g.position.Z = 1000 -- the platform is high above the fake's ground
            g.baseVelocity = { X = platform, Y = 0, Z = 0 }
            g.frames(3)
            local walk = g.moveTick
            g.moveTick = function(dt)
                g.moveTick = walk
                -- Unreal walks half the frame to the edge and starts falling; nothing is
                -- added to the velocity, and a listener of the mode change caps it at 650 cm/s.
                local v, pos = fake.props(g.cmc).Velocity, g.position
                g.pending = { X = 0, Y = 0, Z = 0 }
                pos.X = pos.X + g.baseVelocity.X * dt + v.X * dt / 2
                g.cmc:SetMovementMode(3, 0)
                pos.X = pos.X + v.X * dt / 2
            end
            g.frames(2)
            t.eq(g.mode(), 3)
            t.contains(g.log, "The game cut the speed from 320 to 260 u/s (in the air")
            t.near(g.speed(), MAX_SPEED, 5, string.format("platform at %d cm/s: the speed relative to it, which "
                .. "still carries the character", platform))
            noErrors(g)
        end
    end)

t.test("walking off a platform that moves sideways, a cap at the mode change is still undone", function()
    local g = running(nil, { jumpListenerClamps = true })
    runTo(g, MAX_SPEED)
    g.position.Z = 1000 -- the platform is high above the fake's ground
    g.baseVelocity = { X = 0, Y = 300, Z = 0 }
    g.frames(3)
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        -- Walking off the edge adds the platform's velocity, and a listener of the
        -- mode change (the game's speed limiter may be one) caps the speed at 650 cm/s.
        local v, pos = fake.props(g.cmc).Velocity, g.position
        g.pending = { X = 0, Y = 0, Z = 0 }
        pos.Y = pos.Y + g.baseVelocity.Y * dt
        pos.X = pos.X + v.X * dt / 2
        g.cmc:SetMovementMode(3, 0)
        g.baseVelocity = nil
        pos.X, pos.Y = pos.X + v.X * dt / 2, pos.Y + v.Y * dt / 2
    end
    g.frames(2)
    t.eq(g.mode(), 3)
    t.contains(g.log, "The game cut the speed from 342 to 260 u/s (in the air, movement mode 1 then 3")
    t.near(g.speed(), math.sqrt(MAX_SPEED ^ 2 + 300 ^ 2), 5, "the run and the platform's velocity are kept")
    noErrors(g)
end)

t.test("in a long frame, walking off still ground just after leaving a moving platform isn't a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.position.Z = 1000 -- the platform is high above the fake's ground
    g.baseVelocity = { X = 300, Y = 0, Z = 0 } -- moving along the run
    g.frames(3)
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        -- Unreal walks a frame over 0.05 s in several moves. The first, carried by the
        -- platform, ends on still ground, which becomes the base; the next walks off that
        -- ground's ledge, and StartFalling adds the velocity of the base it has then: none.
        local v, pos = fake.props(g.cmc).Velocity, g.position
        g.pending = { X = 0, Y = 0, Z = 0 }
        pos.X = pos.X + g.baseVelocity.X * dt + v.X * dt / 2
        g.baseVelocity = nil
        g.cmc:SetMovementMode(3, 0)
        pos.X = pos.X + v.X * dt / 2
    end
    g.frames(2, 1 / 15)
    t.eq(g.mode(), 3)
    t.near(g.speed(), MAX_SPEED, 5, "Unreal added no platform velocity, and the mod adds none")
    t.absent(g.log, "The game cut the speed")
    noErrors(g)
end)

t.test("the game's own jump from a moving platform keeps the platform's velocity, and isn't a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.baseVelocity = { X = -300, Y = 0, Z = 0 } -- moving against the run
    g.frames(3)
    g.pressedJump = true -- the game's jump, from an input the mod doesn't read
    g.frame()
    t.eq(g.gameJumps, 1, "the game jumped")
    g.frame()
    t.near(g.speed(), MAX_SPEED - 300, 5, "the platform's velocity is kept")
    t.absent(g.log, "The game cut the speed")
    noErrors(g)
end)

t.test("hopping on a moving platform doesn't add its speed again at every hop", function()
    for _, stay in ipairs({ false, true }) do
        local g = running(nil, { stayBasedInAir = stay })
        g.baseVelocity = { X = 200, Y = 0, Z = 0 }
        g.frames(3)
        -- Jump in place, holding the key: the character should stay where it stood on
        -- the platform. (Unreal leaves the velocity as it was in the air at a landing,
        -- and also carries the character with the platform from then on.)
        local startX, frames, landings, lastMode = g.position.X, 0, 0, g.mode()
        g.keys.SpaceBar = true
        while landings < 6 and frames < 600 do
            g.frame()
            frames = frames + 1
            if lastMode == 3 and g.mode() == 1 then
                landings = landings + 1
            end
            lastMode = g.mode()
        end
        g.keys.SpaceBar = false
        t.eq(landings, 6, "hopped")
        if stay then
            t.contains(g.log, "take-off 0 u/s, landing 0 u/s (+0)", "with bStayBasedInAir, the hop lines are relative "
                .. "to the platform, which still carries the character")
        else
            t.contains(g.log, "take-off 80 u/s, landing 80 u/s (+0)", "the hop lines count the platform's velocity")
        end
        local drift = g.position.X - startX - 200 * frames / 60
        t.near(drift, 0, 5, string.format("bStayBasedInAir %s: the character stays on its spot", tostring(stay)))
        noErrors(g)
    end
    -- From a moving platform onto still ground, the platform's velocity is kept.
    local g = running()
    g.baseVelocity = { X = 200, Y = 0, Z = 0 }
    g.frames(3)
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    t.eq(g.mode(), 3, "jumped")
    g.baseVelocity = nil -- still ground below
    while g.mode() == 3 do
        g.frame()
    end
    g.frame() -- the mod's first frame on the ground, with Half-Life friction
    t.truthy(g.speed() > 150, string.format("landing on still ground keeps the platform's velocity (%.0f cm/s)",
        g.speed()))
    noErrors(g)
end)

t.test("hopping in place on a moving platform for a minute stays on the spot", function()
    -- Unreal brakes the velocity it moves with, which after a jump has the platform's
    -- in it. If the mod added back only the braking of the velocity relative to the
    -- platform, each hop would fall a little more behind (0.9 m in a minute at 60 fps).
    for _, fps in ipairs({ 30, 144 }) do
        local dt = 1 / fps
        local g = running()
        g.baseVelocity = { X = 200, Y = 0, Z = 0 }
        g.frames(3, dt)
        local startX, startT = g.position.X, g.time
        g.keys.SpaceBar = true
        while g.time - startT < 60 do
            g.frame(dt)
        end
        g.keys.SpaceBar = false
        t.truthy(g.landings > 60, "hopped")
        local drift = g.position.X - startX - 200 * (g.time - startT)
        t.near(drift, 0, 2, string.format("%d fps: the character stays on its spot (%.1f cm)", fps, drift))
        noErrors(g)
    end
end)

t.test("the status line's gain per jump reads +0 when it is under 0.5 u/s, as the hop lines do", function()
    -- At under 10 fps the mod adds back the braking of the 0.1 s it simulates, while
    -- Unreal brakes the whole frame: each hop ends a hair slower than it started.
    local g = running()
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frames(120, 0.15)
    t.contains(g.log, "per jump +0 u/s in the air", "the status line")
    t.absent(g.log, "per jump -0", "not -0")
    t.contains(g.log, "(+0), ", "the hop lines")
    noErrors(g)
end)

-- A pause the game starts from the controller's own input: IsGamePaused already says
-- so in the mod's frame hook, but Unreal had started the world's tick unpaused, so
-- the character's movement and the camera still run once, and the world's clock goes
-- on. moveShare: the share of that move a wall lets through.
local function pauseFromInput(g, moveShare)
    g.paused, g.worldPaused, g.moveShare = true, false, moveShare
    g.frame()
    g.worldPaused, g.moveShare = nil, nil
end

-- The game unpausing from the controller's own input: IsGamePaused says it runs in the
-- mod's frame hook, but Unreal had started the world's tick paused, so nothing moves
-- in that frame, the camera isn't updated and the world's clock stands still.
local function unpauseFromInput(g)
    g.paused, g.worldPaused = false, true
    g.frame()
    g.worldPaused = nil
end

t.test("a pause around a landing on a moving platform doesn't add its speed", function()
    -- fromInput: the game pauses from the controller's input on the landing frame;
    -- otherwise the whole frame after the landing (the mod's first on the ground) is paused.
    for _, fromInput in ipairs({ false, true }) do
        local g = running()
        g.baseVelocity = { X = 200, Y = 0, Z = 0 }
        g.frames(3)
        local startX, moved, landings, lastMode, paused = g.position.X, 0, 0, g.mode(), false
        g.keys.SpaceBar = true
        while landings < 6 and moved < 600 do
            local v = fake.props(g.cmc).Velocity
            local landsNow = g.mode() == 3 and g.position.Z + (v.Z + g.cmc:GetGravityZ() / 60) / 60 <= 0
            if not paused and landings == 2 and (fromInput and landsNow or not fromInput and lastMode == 1) then
                paused = true
                if fromInput then
                    pauseFromInput(g)
                    moved = moved + 1
                else
                    g.paused = true
                    g.frame()
                end
                g.frames(9)
                g.paused = false
            else
                g.frame()
                moved = moved + 1
            end
            if lastMode == 3 and g.mode() == 1 then
                landings = landings + 1
            end
            lastMode = g.mode()
        end
        g.keys.SpaceBar = false
        t.truthy(paused, "paused")
        local drift = g.position.X - startX - 200 * moved / 60
        t.near(drift, 0, 5, string.format("%s: the character stays on its spot",
            fromInput and "paused from the controller's input" or "paused"))
        noErrors(g)
    end
end)

t.test("a pause the game starts from the controller's input: the mod moves the character that frame, not the game",
    function()
        local g = running()
        runTo(g, MAX_SPEED)
        g.engineAccelerated = false
        pauseFromInput(g) -- W still held
        t.falsy(g.engineAccelerated, "the game's input didn't move the character")
        t.near(g.speed(), MAX_SPEED, 1, "the mod's speed")
        g.frames(9)
        g.paused = false
        g.frames(3)
        t.absent(g.log, "movement input still reaches", "no input leak")
        -- A wall that stops that last move halfway: Unreal sets the velocity from the
        -- distance moved, which isn't a cut.
        g.keys.W = false
        g.frames(2)
        pauseFromInput(g, 0.5)
        g.frames(9)
        g.paused = false
        g.frame()
        t.absent(g.log, "The game cut the speed")
        t.truthy(g.speed() < MAX_SPEED * 0.6, string.format("the wall's slowdown stays (%.0f cm/s)", g.speed()))
        t.absent(g.log, "world's clock", "the clock follows the pauses")
        noErrors(g)
    end)

t.test("without the world's clock, a pause from the controller's input isn't an input leak or a speed cut", function()
    -- IsGamePaused already says paused in that frame, so the mod holds, and Unreal
    -- moves the character once with the game's input.
    local g = running()
    g.clock = "error"
    runTo(g, MAX_SPEED)
    t.contains(g.log, "Can't read the world's clock (GetTimeSeconds:", "logged")
    t.contains(g.log, "so pauses are told from IsGamePaused alone")
    pauseFromInput(g) -- W still held
    t.truthy(g.engineAccelerated, "the game's input moved the character once")
    g.frames(9)
    g.paused = false
    g.frames(3)
    t.absent(g.log, "movement input still reaches", "no input leak")
    g.keys.W = false
    g.frames(2)
    pauseFromInput(g, 0.5)
    g.frames(9)
    g.paused = false
    g.frame()
    t.absent(g.log, "The game cut the speed")
    t.truthy(g.speed() < MAX_SPEED * 0.6, string.format("the wall's slowdown stays (%.0f cm/s)", g.speed()))
    noErrors(g)
end)

t.test("pausing and unpausing from the controller's input isn't an input leak", function()
    for _, clock in ipairs({ "normal", "error" }) do
        for _, case in ipairs({ "a pause", "a one-frame pause", "a pause that ignores move input" }) do
            local g = running()
            g.clock = clock ~= "normal" and clock or nil
            runTo(g, MAX_SPEED)
            local what = string.format("%s (clock %s)", case, clock)
            if case == "a pause that ignores move input" then
                -- The mod gives the movement back while the pause lasts. In the frame the
                -- game pauses, Unreal moves the character once with what the game added
                -- before it ignored move input.
                g.moveIgnored = true
                g.pending.X = 1
                pauseFromInput(g)
                t.truthy(g.engineAccelerated, what .. ": the game's input moved the character")
            else
                pauseFromInput(g) -- W still held
            end
            g.frames(case == "a one-frame pause" and 0 or 9)
            g.moveIgnored = false
            unpauseFromInput(g)
            g.frames(5)
            t.absent(g.log, "movement input still reaches", what .. ": no input leak")
            t.near(g.speed(), MAX_SPEED, 1, what .. ": the speed goes on")
            if clock == "normal" then
                t.absent(g.log, "world's clock", what .. ": the clock follows the pauses")
            end
            noErrors(g)
        end
        -- A real leak right after such a pause is still found.
        local g = running()
        g.clock = clock ~= "normal" and clock or nil
        runTo(g, MAX_SPEED)
        pauseFromInput(g)
        g.frames(9)
        g.options.lateInput = true
        unpauseFromInput(g)
        t.absent(g.log, "movement input still reaches", "no leak before the pause")
        g.frames(3)
        t.contains(g.log, "The game's movement input still reaches Unreal's movement", "clock " .. clock)
    end
end)

t.test("an unpause from the controller's input: the camera's view isn't counted as worked out in that frame",
    function()
        -- With a lens limit, the field of view the mod sets in that frame (a refresh,
        -- at any phase) or in the pause (the camera moved again) is only read once the
        -- camera has worked it out; read before, it would pass for the lens letting it
        -- through, and every frame's lens value for the game's.
        for phase = 0, 32 do
            local g = running({ CameraMethod = "game" }, { cineFovLimit = 95 })
            local cam = g.c.cineCamera
            local cine = fake.props(cam)
            g.frames(30)
            pauseFromInput(g)
            if phase < 32 then
                g.frames(phase)
            else
                g.press(F6)
                g.press(F6)
            end
            unpauseFromInput(g)
            local sets = 0
            fake.method(cam, "SetFieldOfView", fake.ufunction("SetFieldOfView", 1, function(_, fov)
                sets = sets + 1
                cine.FieldOfView = fov
            end))
            g.frames(60)
            local how = phase < 32 and ("phase " .. phase) or "moved in the pause"
            t.eq(cine.FieldOfView, 95, how .. ": the lens's field of view is shown")
            t.truthy(sets <= 5, string.format("%s: the mod's field of view isn't set every frame (%d sets)", how, sets))
            g.press(F6)
            t.eq(cine.FieldOfView, 85, how .. ": the game's own field of view comes back")
            noErrors(g)
        end
    end)

t.test("a wait that ends while the game is paused: nothing moves until it runs again", function()
    -- The world's clock last read before the wait went on since, but that tells
    -- nothing about this frame.
    local g = running()
    g.changingArea = true
    g.frames(10)
    g.changingArea = false
    g.frames(30) -- part of the settle, with the game running
    g.paused = true
    g.keys.SpaceBar = true
    g.frames(240) -- the rest of the settle and more, paused
    t.eq(g.mode(), 1, "no jump while paused")
    g.paused = false
    g.frames(2)
    t.eq(g.mode(), 3, "the jump once the game runs again")
    t.absent(g.log, "world's clock", "the clock follows the pauses")
    noErrors(g)
end)

t.test("if the world's clock doesn't follow the pauses, IsGamePaused tells them", function()
    for _, clock in ipairs({ "stuck", "running" }) do
        local g = start()
        g.clock = clock -- from the first time the mod reads it
        g.loadSave()
        g.frames(SETTLE_FRAMES)
        -- Hopping on a moving platform, with a few pauses.
        g.baseVelocity = { X = 200, Y = 0, Z = 0 }
        g.frames(3)
        local startX, moved = g.position.X, 0
        g.keys.SpaceBar = true
        for i = 1, 400 do
            if i % 100 == 50 then
                g.paused = true
                g.frames(6)
                g.paused = false
            end
            g.frame()
            moved = moved + 1
        end
        g.keys.SpaceBar = false
        t.contains(g.log, string.format("The world's clock (GetTimeSeconds) %s, so pauses are told from "
            .. "IsGamePaused alone", clock == "stuck" and "stood still while the game ran"
            or "went on while the game was paused"), clock .. ": logged")
        t.eq(count(g.log, "so pauses are told from IsGamePaused alone"), 1, clock .. ": once, and not asked again")
        local drift = g.position.X - startX - 200 * moved / 60
        t.near(drift, 0, 5, string.format("%s: the character stays on its spot on the platform", clock))
        t.truthy(g.landings >= 4, clock .. ": hopped")
        noErrors(g)
    end
end)

t.test("a pause after root motion doesn't bring back the movement's state from before it", function()
    local g = running()
    g.baseVelocity = { X = 200, Y = 0, Z = 0 }
    g.frames(3)
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    t.eq(g.mode(), 3, "jumped")
    -- The game plays root motion (a landing roll, say), which sets the character down
    -- on the platform, standing still on it; then the game pauses.
    g.rootMotion = true
    g.frame()
    local p = fake.props(g.cmc)
    p.MovementMode = 1
    p.Velocity.X, p.Velocity.Y, p.Velocity.Z = 0, 0, 0
    g.position.Z = 0
    g.rootMotion = false
    g.paused = true
    g.frames(5)
    g.paused = false
    g.frame()
    t.near(g.speed(), 0, 1, "no landing is left over from before the root motion")
    noErrors(g)
end)

t.test("F8 on a moving platform reports what docs/TESTING.md asks for there", function()
    local g = running()
    g.baseVelocity = { X = 200, Y = 0, Z = 0 }
    g.frames(3)
    g.press(F8)
    t.contains(g.log, "Movement:GetImpartedMovementBaseVelocity() = (X=200.0 Y=0.0 Z=0.0)")
    t.contains(g.log, "Movement.bStayBasedInAir = false")
    t.contains(g.log, "Character.IsAttachedToMovingPlatform = false")
    t.contains(g.log, "Movement:GetMovementBase() = ")
    noErrors(g)
end)

t.test("stepping onto a moving platform in a move cut short isn't a speed cut", function()
    local g = running()
    runTo(g, MAX_SPEED)
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        -- A lip at the platform's edge stops part of the move. Unreal's update started
        -- on still ground, so it isn't carried; the platform is its base from now on.
        g.moveShare = 0.7
        walk(dt)
        g.moveShare = nil
        g.baseVelocity = { X = -300, Y = 0, Z = 0 } -- coming towards the character
    end
    g.frames(3)
    t.absent(g.log, "The game cut the speed")
    noErrors(g)
end)

t.test("KeepSpeed: a mild cap at a landing early in the frame is undone too", function()
    -- A listener of the landing caps the speed a twentieth of the way through Unreal's
    -- update, to 650 cm/s from 800: the distance moved then is close to what the capped
    -- speed alone would give, so only the mode change tells it apart from a wall.
    local g = running(nil, { landingListenerClamps = true, maxSpeedIgnoresWalkSpeed = true })
    runTo(g, MAX_SPEED)
    local walk, early = g.moveTick, false
    g.moveTick = function(dt)
        local p = fake.props(g.cmc)
        if not early and p.MovementMode == 3 and p.Velocity.Z < 0 then
            local fall = (p.Velocity.Z + g.cmc:GetGravityZ() * dt) * dt
            if g.position.Z + fall <= 0 then
                g.position.Z = -0.05 * fall -- touchdown a twentieth of the way through
                early = true
            end
        end
        walk(dt)
    end
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    t.eq(g.mode(), 3, "jumped")
    local after -- the speed a frame after the landing (W is held, so it comes back anyway after that)
    for _ = 1, 120 do
        local landed = g.landingClamps > 0
        g.frame()
        if landed and not after then
            after = g.speed()
        end
    end
    t.truthy(early and g.landingClamps == 1, "the game capped the speed early in the landing's update")
    t.contains(g.log, "The game cut the speed from 320 to 260 u/s (on landing")
    t.near(after, MAX_SPEED, 1, "the speed is back on the frame after the landing")
    noErrors(g)
end)

t.test("with DisableSpeedLimiter = false, the cut lines say the limiter isn't paused", function()
    local g = running({ DisableSpeedLimiter = false }, { maxSpeedIgnoresWalkSpeed = true })
    g.keys.W = true
    g.frames(60)
    t.contains(g.log, "speed limiter not paused (DisableSpeedLimiter = false)")
    t.absent(g.log, "speed limiter not found")
end)

t.test("with DisableSpeedLimiter = false, a cut to a MaxWalkSpeed the game just wrote counts, even under a fifth",
    function()
        local g = running({ DisableSpeedLimiter = false })
        g.keys.SpaceBar = true
        g.frame()
        g.keys.SpaceBar = false
        local p = fake.props(g.cmc)
        p.Velocity.X, p.Velocity.Y = 2000, 0
        g.frames(3)
        p.bRequestMovementSettingsChange = 1 -- ALS asks for its gait speed (375 cm/s); the limiter caps to it
        g.frames(3)
        t.truthy(g.speed() > 1900, string.format("the speed is kept (%.0f cm/s)", g.speed()))
        t.contains(g.log, "MaxWalkSpeed 100000 (the game had set 375)")
        noErrors(g)
    end)

t.test("a jump keeps the velocity of a moving platform", function()
    local g = running()
    g.baseVelocity = { X = 200, Y = 0, Z = 50 }
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    local v = fake.props(g.cmc).Velocity
    t.near(v.X, 200, 0.1, "the platform's speed is kept")
    t.near(v.Z, JUMP_SPEED + 50 - 980 * fake.props(g.cmc).GravityScale / 60, 1e-6)
    t.absent(g.log, "changed the velocity")
end)

t.test("with bStayBasedInAir, a jump from a moving platform doesn't add the platform's velocity", function()
    local g = running(nil, { stayBasedInAir = true })
    g.baseVelocity = { X = 200, Y = 0, Z = 50 }
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    t.near(fake.props(g.cmc).Velocity.X, 0, 0.1, "Unreal keeps carrying the character with the platform itself")
    t.absent(g.log, "changed the velocity")
end)

t.test("a jump ignores what else the game does to the velocity when it starts", function()
    local g = running(nil, { jumpListenerClamps = true })
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    t.near(g.speed(), MAX_SPEED, 1, "the Half-Life take-off speed, not the game's 650")
    t.contains(g.log, "Something in the game changed the velocity by")
end)

t.test("with bStayBasedInAir too, a jump ignores what else the game does to the velocity when it starts", function()
    local g = running(nil, { stayBasedInAir = true, jumpListenerClamps = true })
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    t.near(g.speed(), MAX_SPEED, 1, "the Half-Life take-off speed, not the game's 650")
    t.contains(g.log, "Something in the game changed the velocity by")
end)

t.test("the game's movement input reaching Unreal after the mod took it is logged", function()
    local g = running(nil, { lateInput = true })
    g.keys.W = true
    g.frames(10)
    t.contains(g.log, "The game's movement input still reaches Unreal's movement")
end)

t.test("dialogue cameras: first person steps aside, movement stays", function()
    local g = running()
    g.cameraActive.CineCamera_Dialogue1 = true -- listed before the main camera, so the engine shows it
    g.frame()
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
    t.contains(g.log, "First person: waiting (the game shows its camera CineCamera_Dialogue1")
    g.cameraActive.CineCamera_Dialogue1 = nil
    g.frame()
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("a camera after the main one in the list doesn't count: the engine shows the first", function()
    local g = running()
    g.cameraActive.MainCamera = true
    g.frames(40)
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("the game's dialogue and cinematic systems put first person aside", function()
    local g = running()
    g.inDialogue = true
    g.frames(20)
    t.eq(styleOf(g), "Default")
    t.contains(g.log, "First person: waiting (dialogue)")
    g.inDialogue = false
    g.frames(20)
    t.eq(styleOf(g), "FirstPerson")
    g.inCinematic = true
    g.frames(20)
    t.eq(styleOf(g), "Default")
    t.contains(g.log, "First person: waiting (a cinematic is playing)")
    g.inCinematic = false
    g.frames(20)
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("the camera the game's GetMainCamera names shows exploration, whatever CameraComponents says", function()
    local g = running({ CameraComponents = {} })
    t.eq(styleOf(g), "FirstPerson", "Main_CineCamera, named by GetMainCamera")
    g.press(F8)
    t.contains(g.log, "the game's GetMainCamera: Main_CineCamera (CineCameraComponent);")
    noErrors(g)
end)

t.test("the engine's view waits for the camera manager to finish blending over to the character", function()
    local g = start()
    g.loadSave()
    local pending = fake.props(g.pcm).PendingViewTarget
    pending.Target = g.pawn -- the game blends back to the character, from a sneaking camera for example
    g.frames(SETTLE_FRAMES + 60)
    t.eq(styleOf(g), "Default", "not during the blend")
    t.contains(g.log, "First person: waiting (the game's camera is still blending over to your character)")
    pending.Target = fake.INVALID
    g.frame()
    t.eq(styleOf(g), "FirstPerson", "once it is over")
    -- A blend that never ends doesn't keep first person off for long.
    g.press(F6)
    pending.Target = g.pawn
    g.press(F6)
    g.frames(170)
    t.eq(styleOf(g), "Default")
    g.frames(30)
    t.eq(styleOf(g), "FirstPerson", "after 3 s at most")
    t.contains(g.log, "first person starts anyway")
    g.inDialogue = true
    g.frames(20)
    g.inDialogue = false
    g.frames(20)
    t.eq(styleOf(g), "FirstPerson", "and the blend that doesn't end isn't waited for again")
    noErrors(g)
end)

t.test("a pause during the blend doesn't use up the wait, and a blend that went on too long is waited for next time",
    function()
        local g = running()
        local pending = fake.props(g.pcm).PendingViewTarget
        g.press(F6)
        pending.Target = g.pawn
        g.press(F6)
        g.frames(20)
        g.paused = true -- the camera manager's blend stops while the game is paused
        g.frames(240)
        t.eq(styleOf(g), "Default", "still waiting after 4 s in the pause menu")
        t.absent(g.log, "first person starts anyway")
        g.paused = false
        g.frames(20)
        t.eq(styleOf(g), "Default")
        pending.Target = fake.INVALID
        g.frame()
        t.eq(styleOf(g), "FirstPerson")
        -- A blend that went on too long, then ended while first person was on.
        g.press(F6)
        pending.Target = g.pawn
        g.press(F6)
        g.frames(200)
        t.eq(styleOf(g), "FirstPerson")
        t.contains(g.log, "first person starts anyway")
        pending.Target = fake.INVALID
        g.frames(5)
        g.press(F6)
        pending.Target = g.pawn
        g.press(F6)
        g.frames(20)
        t.eq(styleOf(g), "Default", "the next blend is waited for again")
        -- Again, and this time a dialogue starts with a blend to its own camera.
        g.frames(200)
        t.eq(styleOf(g), "FirstPerson")
        g.inDialogue = true
        pending.Target = g.dialogueSystem -- any other view target
        g.frames(20)
        pending.Target = g.pawn -- the dialogue ends with a blend back to the character
        g.inDialogue = false
        g.frames(20)
        t.eq(styleOf(g), "Default", "the blend after the dialogue is waited for")
        pending.Target = fake.INVALID
        g.frame()
        t.eq(styleOf(g), "FirstPerson")
        noErrors(g)
    end)

t.test("the game's camera at the eyes doesn't wait for a blend", function()
    local g = start({ CameraMethod = "game" })
    fake.props(g.pcm).PendingViewTarget.Target = g.pawn
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule)
    noErrors(g)
end)

t.test("without the game's GetMainCamera, the cameras named in CameraComponents count", function()
    local g = running(nil, { noGetMainCamera = true })
    t.eq(styleOf(g), "FirstPerson")
    g = running({ CameraComponents = {} }, { noGetMainCamera = true })
    t.eq(styleOf(g), "Default")
    t.contains(g.log, "not the main camera unknown")
end)

t.test("if UE4SS can't read bIsActive, IsActive is asked", function()
    local g = running(nil, { noIsActiveProperty = true })
    t.eq(styleOf(g), "FirstPerson")
    g.cameraActive.CineCamera_Dialogue1 = true
    g.frame()
    t.eq(styleOf(g), "Default")
end)

t.test("no camera active: first person is on", function()
    local g = start()
    g.cameraActive = {}
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("F6 always says what first person does", function()
    local g = running()
    g.cameraActive.CineCamera_Dialogue1 = true
    g.frame()
    local waiting = "First person: waiting (the game shows its camera CineCamera_Dialogue1"
    t.eq(count(g.log, waiting), 1)
    g.press(F6)
    g.press(F6)
    t.eq(count(g.log, waiting), 2, "said again after the key, though nothing changed")
end)

t.test("another view target: first person steps aside", function()
    local g = running()
    g.viewTarget = fake.object({ className = "CineCameraActor", chain = { "CineCameraActor", "CameraActor", "Actor" } })
    g.frame()
    t.eq(styleOf(g), "Default")
end)

t.test("while the game changes area, everything is given back and the mod waits", function()
    local g = running()
    g.changingArea = true
    g.frame()
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048)
    t.contains(g.log, "First person: waiting (the game is changing area)")
    g.frames(30)
    g.changingArea = false
    g.frames(150)
    t.eq(styleOf(g), "Default", "settling after the change")
    g.frames(40)
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("locked input gives the movement back; pausing leaves it alone", function()
    local g = running()
    g.inputLocked = true
    g.frame()
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048, "given back while input is locked")
    g.inputLocked = false
    g.frame()
    runTo(g, MAX_SPEED)
    g.paused = true
    g.keys.W = false
    local before = g.speed()
    g.frames(10)
    t.eq(g.speed(), before, "no friction while paused")
end)

t.test("F5 turns everything off and on again", function()
    local g = running()
    g.press(F5)
    t.contains(g.log, "Half-Life movement off")
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048)
    g.keys.W = true
    g.frames(30)
    t.truthy(g.engineAccelerated, "the game moves the character itself")
    t.eq(styleOf(g), "Default")
    g.press(F5)
    g.frame()
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("F6 switches first person off and keeps the movement", function()
    local g = running()
    g.press(F6)
    g.frame()
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, false)
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
    g.press(F6)
    g.frame()
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("F7 reloads the settings", function()
    local g = running()
    fake.useConfig({ FieldOfView = 110 })
    g.press(F7)
    g.frame()
    t.eq(fake.props(g.pcm).DefaultFOV, 110)
    t.contains(g.log, "Settings reloaded")
end)

t.test("F7 keeps the camera switched off with F6", function()
    local g = running()
    g.press(F6)
    g.press(F7)
    g.frames(5)
    t.eq(styleOf(g), "Default")
end)

t.test("F7 hooks the game's jump event when JumpInput needs it, outside the game's hooks", function()
    local g = running({ JumpInput = "keys" })
    t.falsy(g.hooks[g.jumpPath], "not needed for the keys")
    fake.useConfig({ JumpInput = "game" })
    g.press(F7)
    t.truthy(g.hooks[g.jumpPath], "hooked after F7")
    g.keys.SpaceBar = true
    local landings = g.landings
    g.frames(120)
    t.truthy(g.landings - landings >= 2, "holding jump keeps hopping")
    noErrors(g)
end)

t.test("F8 writes a diagnostics report", function()
    local g = running()
    g.press(F8)
    t.contains(g.log, "HL1Movement 0.2.6 diagnostics")
    t.contains(g.log, "Movement component:")
    t.contains(g.log, "Camera manager:")
    t.contains(g.log, "BP_VelocityControllerComponent_C")
    t.contains(g.log, "Character.TargetRotation = (Pitch=0.0 Yaw=0.0 Roll=0.0)")
    t.contains(g.log, "Movement.Velocity = (X=")
    t.contains(g.log, "Main_CineCamera (CineCameraComponent) [engine view] [GetMainCamera] [exploration]")
    t.contains(g.log, "the game's GetMainCamera: Main_CineCamera")
    t.contains(g.log, "GetMaxSpeed() after setting MaxWalkSpeed: 100000")
    t.contains(g.log, "Game keys for JumpAction: SpaceBar, Gamepad_FaceButton_Bottom")
    t.contains(g.log, "Controller:HasCameraOverride() = false")
    t.contains(g.log, "Errors: none")
    t.contains(g.log, "end of diagnostics")
    noErrors(g)
end)

t.test("the report key waits while the game sets up a character or changes area, but not forever", function()
    local g = running()
    g.useCharacter(g.buildCharacter())
    g.frame() -- the mod sees the new character and leaves it alone for a moment
    g.press(F8)
    g.frames(5)
    t.absent(g.log, "diagnostics (asked for with F8)", "nothing read while the game sets the character up")
    g.frames(SETTLE_FRAMES)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "written once that is over")
    t.contains(g.log, "the game's GetMainCamera: Main_CineCamera")
    -- An area change that doesn't end still gets its report.
    g.changingArea = true
    g.press(F8)
    g.frames(580)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1)
    g.frames(30)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 2, "after 10 s")
    noErrors(g)
end)

t.test("with the mod switched off, the report key still writes its report", function()
    local g = running()
    g.press(F5)
    g.press(F8)
    t.contains(g.log, "diagnostics (asked for with F8)")
    t.contains(g.log, "Mod: enabled=false")
end)

t.test("with the mod switched off, the report key waits for an area change or a new character too", function()
    local g = running()
    g.press(F5)
    g.changingArea = true
    g.press(F8)
    g.frames(30)
    t.absent(g.log, "diagnostics (asked for with F8)", "not while the game changes area")
    g.changingArea = false
    g.frame()
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "once that is over")
    g.useCharacter(g.buildCharacter())
    g.press(F8)
    g.frames(5)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "nothing read while the game sets the character up")
    g.frames(SETTLE_FRAMES)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 2)
    noErrors(g)
end)

t.test("with a character the mod leaves alone, the report key waits for an area change too", function()
    local g = running(nil, { worldMap = true })
    g.changingArea = true
    g.press(F8)
    g.frames(30)
    t.absent(g.log, "diagnostics (asked for with F8)", "not while the game changes area")
    g.changingArea = false
    g.frame()
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "once that is over")
    noErrors(g)
end)

t.test("pressing the report key again while its report waits doesn't start the wait again", function()
    local g = running()
    g.changingArea = true
    g.press(F8)
    g.frames(300)
    g.press(F8) -- again, 5 s later, as nothing came
    g.frames(285)
    t.absent(g.log, "diagnostics (asked for with F8)")
    g.frames(30)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "10 s after the first press")
    noErrors(g)
end)

t.test("after the mod turned itself off, the report key reports on the controller of the moment", function()
    local g = running()
    local camera = package.loaded["hl1movement.camera"]
    local isActive = camera.isActive
    camera.isActive = function()
        error("broken on purpose")
    end
    g.frames(31)
    camera.isActive = isActive
    t.contains(g.log, "Turned off after 30 errors in a row")
    local old = g.pc
    g.pc = fake.copy(old) -- a new level brings a new controller
    fake.destroy(old)
    g.press(F8)
    t.contains(g.log, "diagnostics (asked for with F8)")
    t.absent(g.log, "No player controller yet")
    t.contains(g.log, "Controller: BP_jRPG_Controller_World_C")
end)

t.test("after the mod turned itself off, the report key's waits still end", function()
    local g = running()
    local camera = package.loaded["hl1movement.camera"]
    local isActive = camera.isActive
    camera.isActive = function()
        error("broken on purpose")
    end
    g.frames(31)
    camera.isActive = isActive
    t.contains(g.log, "Turned off after 30 errors in a row")
    local old = g.pc
    g.pc = fake.copy(old) -- a new level brings a new controller...
    fake.destroy(old)
    g.useCharacter(g.buildCharacter()) -- ...and a new character
    g.press(F8)
    g.frames(5)
    t.absent(g.log, "diagnostics (asked for with F8)", "nothing read while the game sets the character up")
    g.frames(SETTLE_FRAMES)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "written once that is over")
    t.contains(g.log, "Controller: BP_jRPG_Controller_World_C")
    -- An area change that doesn't end still gets its report.
    g.changingArea = true
    g.press(F8)
    g.frames(580)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1)
    g.frames(30)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 2, "after 10 s")
end)

t.test("switched off during a new character's first seconds, the report key waits for the rest of them", function()
    local g = running()
    g.useCharacter(g.buildCharacter())
    g.frames(12) -- the mod leaves the new character alone for a moment
    g.press(F5)
    g.press(F8)
    g.frames(5)
    t.absent(g.log, "diagnostics (asked for with F8)", "nothing read while the game sets the character up")
    g.frames(SETTLE_FRAMES)
    t.eq(count(g.log, "diagnostics (asked for with F8)"), 1, "written once that is over")
    noErrors(g)
end)

t.test("a value that can't be read doesn't stop the report", function()
    local g = running()
    fake.breakOnRead(g.cmc, "MaxAcceleration")
    g.press(F8)
    t.contains(g.log, "Movement.MaxAcceleration = nil")
    t.contains(g.log, "end of diagnostics")
    noErrors(g)
end)

t.test("the automatic report comes a few seconds after taking over", function()
    local g = running()
    g.frames(200)
    t.contains(g.log, "diagnostics (automatic, 3 s after taking over the character)")
    t.absent(g.log, "still waiting")
end)

t.test("a camera report comes if first person still waits after 10 seconds", function()
    local g = running({ CameraComponents = {} }, { noGetMainCamera = true })
    g.frames(700)
    t.eq(count(g.log, "diagnostics (first person is still waiting 10 s after taking over)"), 1)
end)

t.test("a new character: the old one is never touched once it's gone", function()
    local g = running()
    g.keys.W = true
    g.frames(5)
    local old = g.c
    fake.destroy(old.pawn)
    fake.destroy(old.cmc)
    fake.destroy(old.mesh)
    fake.destroy(old.capsule)
    g.useCharacter(g.buildCharacter())
    g.frames(SETTLE_FRAMES)
    noErrors(g)
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true, "new character set up")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
end)

t.test("a new character while the old one still exists: the old one is put back", function()
    local g = running()
    local old = g.c
    g.useCharacter(g.buildCharacter())
    g.frame()
    t.eq(fake.props(old.cmc).BrakingDecelerationWalking, 2048)
    t.eq(fake.props(old.mesh).bOwnerNoSee, false)
    g.frames(SETTLE_FRAMES)
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
    noErrors(g)
end)

t.test("taking over a character puts the old one back on the next frame, not in the hook", function()
    local g = running()
    g.hooks[RESTART](fake.param(g.pc), fake.param(g.pawn))
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING, "nothing touched in the hook")
    g.frame()
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048, "put back on the next frame")
    t.eq(styleOf(g), "Default")
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("the world map character is left alone", function()
    local g = running(nil, { worldMap = true })
    g.frames(5)
    t.eq(styleOf(g), "Default")
    t.falsy(fake.writes(g.cmc).Velocity)
    t.falsy(fake.writes(g.cmc).BrakingDecelerationWalking)
end)

t.test("ALS putting its movement curve back is undone", function()
    local g = running()
    local p = fake.props(g.cmc)
    p.CurrentMovementSettings.MovementCurve = g.c.curve
    g.frame()
    t.eq(p.CurrentMovementSettings.MovementCurve, nil)
end)

t.test("a movement curve replaced at the same address isn't written back", function()
    local g = running()
    local p = fake.props(g.cmc)
    fake.destroy(g.curve)
    local other = fake.object({ className = "CurveFloat", name = "SomethingElse", address = fake.addressOf(g.curve) })
    t.truthy(other)
    g.inBattle = true
    g.frame()
    t.eq(p.CurrentMovementSettings.MovementCurve, nil, "not the other object at the curve's old address")
    noErrors(g)
end)

t.test("if the curve can't be taken out, its braking is cancelled out instead", function()
    local g = running({ PhysicsRate = 0 }, { curveLocked = true })
    t.contains(g.log, "Could not take out the character's movement curve")
    runTo(g, MAX_SPEED)
    g.frames(60)
    t.near(g.speed(), MAX_SPEED, 1, "the game's braking doesn't slow the run")
    g.keys.W = false
    g.keys.SpaceBar = false
    local before = g.speed()
    g.frame()
    t.near(g.speed(), before - before * 4 / 60, 0.5, "only Half-Life friction when letting go")
end)

t.test("if the keys can't be read, the game's input and jump event are used", function()
    local g = running(nil, { keyPollingBroken = true })
    g.keys.W = true
    g.frames(30)
    t.near(g.speed(), MAX_SPEED, 1, "direction from the game's movement input")
    g.keys.SpaceBar = true
    local landings = g.landings
    g.frames(120)
    t.truthy(g.landings - landings >= 2, "hopping from the game's jump event")
    noErrors(g)
end)

t.test("the left stick moves the character", function()
    local g = running()
    g.analog.Gamepad_LeftY = 1
    g.frames(30)
    t.near(g.speed(), MAX_SPEED, 1)
    g.analog.Gamepad_LeftY = 0.1 -- inside the dead zone
    g.analog.Gamepad_LeftX = 0
    local before = g.speed()
    g.frame()
    t.truthy(g.speed() < before, "dead zone: no input, so friction slows you")
end)

t.test("root motion pauses the mod's movement", function()
    local g = running()
    runTo(g, MAX_SPEED)
    g.rootMotion = true
    local writes = fake.writes(g.cmc).Velocity
    g.frames(5)
    t.eq(fake.writes(g.cmc).Velocity, writes, "no velocity written during root motion")
    g.rootMotion = false
    g.frame()
    t.truthy(fake.writes(g.cmc).Velocity > writes)
end)

t.test("a game jump event that repeats every frame and never releases", function()
    local g = running({ JumpInput = "game" }, { jumpEventEveryFrame = true })
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3, "jumped")
    local landings = g.landings
    g.frames(120)
    t.truthy(g.landings - landings >= 2, "kept hopping while held")
    g.keys.SpaceBar = false
    g.frames(60) -- lands and stays down
    local after = g.landings
    g.frames(60)
    t.eq(g.landings, after, "no more hops after letting go")
    t.eq(g.mode(), 1)
end)

t.test("JumpInput = game uses only the game's jump event", function()
    local g = running({ JumpInput = "game" })
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3, "jumped from the game's event")
    local landings = g.landings
    g.frames(120)
    t.truthy(g.landings - landings >= 2, "kept hopping while held")
end)

t.test("a new level: nothing old is touched or kept, the new one is set up after a moment", function()
    local g = running()
    local old = g.c
    local newWorld = fake.object({ className = "World", name = "Level_Other", path = "/Game/Levels/Other.Level_Other" })
    -- Loading the level destroys the old character and everything on it, and the
    -- controller is in the new level.
    for _, obj in ipairs({ old.pawn, old.cmc, old.capsule, old.mesh, old.skinMesh, old.propMesh, old.limiter,
        old.cineCamera, old.mainCamera, old.dialogueCamera, old.springArm, old.cameraController, g.curve }) do
        fake.destroy(obj)
    end
    local c = g.buildCharacter()
    fake.setWorld(c.pawn, newWorld)
    fake.setWorld(g.pc, newWorld)
    g.useCharacter(c)
    g.frame()
    noErrors(g)
    t.eq(g.shared[JOURNAL], "", "nothing of the old level left to put back")
    t.falsy(fake.writes(c.cmc).BrakingDecelerationWalking)
    g.frames(SETTLE_FRAMES)
    t.eq(fake.props(c.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
    t.eq(styleOf(g), "FirstPerson")
    g.inBattle = true
    g.frame()
    t.eq(styleOf(g), "Default")
    noErrors(g)
end)

t.test("missing game functions don't stop the mod", function()
    local g = running(nil, { noBattleFunctions = true })
    g.keys.W = true
    g.frames(30)
    t.near(g.speed(), MAX_SPEED, 1)
    noErrors(g)
end)

t.test("a step that fails every frame is turned off on its own and puts the game back", function()
    local g = start(nil, { breakVelocity = true })
    g.loadSave()
    g.frames(SETTLE_FRAMES + 40)
    local line = t.contains(g.log, "Turned off the Half-Life movement after 30 errors in a row")
    t.truthy(line:find("reading Velocity failed", 1, true), "with the error: " .. line)
    t.eq(count(g.log, "Error in the Half-Life movement"), 1, "the error is logged once")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048, "the movement is put back")
    t.eq(styleOf(g), "FirstPerson", "first person keeps working")
    local lines = #g.log
    g.frames(10)
    t.eq(#g.log, lines, "quiet once off")
    g.press(F5)
    g.press(F5)
    t.contains(g.log, "Half-Life movement on")
    g.frames(40)
    t.eq(count(g.log, "Turned off the Half-Life movement"), 2, "tried again after F5")
end)

t.test("an error in an optional step leaves the camera and the movement running", function()
    local g = running()
    fake.method(g.pawn, "K2_SetActorRotation", function()
        error("K2_SetActorRotation failed")
    end)
    g.frames(40)
    t.contains(g.log, "Turned off turning the character to the view after 30 errors")
    t.eq(styleOf(g), "FirstPerson")
    runTo(g, MAX_SPEED)
    t.absent(g.log, "Turned off the first-person camera")
    t.absent(g.log, "Turned off the Half-Life movement")
end)

t.test("a body part that can't be hidden doesn't hold up the movement", function()
    local g = start()
    fake.method(g.c.skinMesh, "SetOwnerNoSee", function()
        error("SetOwnerNoSee failed")
    end)
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true, "the other parts are hidden")
    local writes = fake.writes(g.cmc).Velocity
    g.keys.W = true
    g.frames(300)
    t.eq(fake.writes(g.cmc).Velocity - writes, 300, "the movement ran every frame")
    t.falsy(g.engineAccelerated, "the game never moved the character itself")
    t.eq(count(g.log, "Error in hiding SkeletalMeshComponent"), 1, "logged once")
end)

t.test("a body part that leaves the character is shown again", function()
    local g = running()
    local c = g.c
    t.eq(fake.props(c.propMesh).bHiddenInGame, true)
    fake.set(c.mesh, "AttachChildren", fake.array({ c.skinMesh })) -- the torch is put away
    g.frames(40)
    t.eq(fake.props(c.propMesh).bHiddenInGame, false, "shown once it isn't attached")
    t.eq(fake.props(c.skinMesh).bOwnerNoSee, true, "the rest stays hidden")
    fake.set(c.mesh, "AttachChildren", fake.array({ c.skinMesh, c.propMesh }))
    g.frames(70)
    t.eq(fake.props(c.propMesh).bHiddenInGame, true, "hidden again when it comes back")
    noErrors(g)
end)

t.test("the fallback hook on the character keeps the camera and leaves the movement to the game", function()
    local g = running(nil, { noControllerTick = true })
    t.eq(g.hooks[g.tickPath], nil)
    t.truthy(g.hooks[g.characterTickPath])
    t.contains(g.log, "Only the character's update could be hooked")
    t.eq(styleOf(g), "FirstPerson")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048, "the movement isn't taken over")
    g.keys.W = true
    g.frames(30)
    t.truthy(g.engineAccelerated, "the game moves the character")
    t.falsy(fake.writes(g.cmc).Velocity, "the mod doesn't")
end)

t.test("if the hook on taking over a character fails, F5 starts the mod after loading a save", function()
    local g = fake.newGame()
    g.functions[RESTART] = nil
    fake.useConfig(nil)
    fake.loadMod(root)
    t.contains(g.log, "Could not hook PlayerController:ClientRestart")
    t.contains(g.log, "After loading a save, press F5 to start the mod")
    g.loadSave()
    g.frame()
    t.falsy(g.hooks[g.tickPath], "nothing hooked yet")
    g.keybinds[F5]()
    t.truthy(g.hooks[g.tickPath], "hooked by the key")
    g.frame()
    t.contains(g.log, "Half-Life movement on")
    t.absent(g.log, "Half-Life movement off")
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("a character on the title screen is not reported as a problem", function()
    local g = start()
    local menuPawn = fake.object({ className = "BP_TitleScreenPawn_C", chain = { "BP_TitleScreenPawn_C", "Pawn" } })
    g.hooks[RESTART](fake.param(g.pc), fake.param(menuPawn))
    t.absent(g.log, "WARNING")
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("UE4SS restarting its mods: the new copy puts the game back first", function()
    local g = running()
    g.keys.W = true
    g.frames(10)
    local noted = g.shared[JOURNAL]
    t.truthy(noted and noted ~= "", "the changes are noted")
    local _, newlines = noted:gsub("\n", "")
    g.restartMods(root)
    g.frame()
    t.contains(g.log, string.format("Put back %d of %d game values", newlines + 1, newlines + 1))
    local p = fake.props(g.cmc)
    t.eq(p.BrakingDecelerationWalking, 2048)
    t.eq(p.MaxWalkSpeed, 600)
    t.eq(p.CurrentMovementSettings.MovementCurve, g.c.curve, "curve put back")
    t.eq(g.limiterTicking, true)
    cameraGivenBack(g)
    -- The new copy then takes over as usual, with the game's own values to put back.
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
    t.eq(p.BrakingDecelerationWalking, TAKEN_BRAKING)
    g.press(F5)
    t.eq(p.BrakingDecelerationWalking, 2048)
    t.eq(p.MaxWalkSpeed, 600)
    cameraGivenBack(g)
    t.eq(g.shared[JOURNAL], "", "nothing left to put back")
    noErrors(g)
end)

t.test("UE4SS restarting its mods while the game's camera is at the eyes: it goes back on its arm", function()
    local g = onGameCamera()
    t.truthy(g.shared[JOURNAL]:find("attach", 1, true), "the move is noted")
    g.restartMods(root)
    g.frame()
    t.contains(g.log, "Put back")
    t.absent(g.log, "could not be found")
    cameraGivenBack(g)
end)

t.test("hooks are never registered while one of the game's hooks runs", function()
    local g = running({ JumpInput = "keys" })
    fake.useConfig({ JumpInput = "game" })
    g.press(F7)
    g.press(F5)
    g.press(F5)
    g.frames(5)
    t.truthy(g.hooks[g.jumpPath])
    t.absent(g.log, "RegisterHook inside a hook")
    noErrors(g)
end)

t.test("the guard logs each different error once, and turns a failing step off", function()
    local g = start()
    local guard = require("hl1movement.guard") -- the copy the mod loaded
    for i = 1, 25 do
        guard.run("a test step", error, "problem " .. (i % 22))
    end
    t.eq(count(g.log, "Error in a test step"), 20, "20 lines at most")
    t.eq(count(g.log, "There are more errors"), 1)
    t.falsy(guard.isOff("a test step"), "25 failures are fewer than the 30 that turn a step off")
    local cleaned = false
    guard.whenOff("another step", function()
        cleaned = true
    end)
    for _ = 1, 30 do
        guard.run("another step", error, "always")
    end
    t.truthy(guard.isOff("another step"))
    t.truthy(cleaned, "its clean-up ran")
    local ran = false
    guard.run("another step", function()
        ran = true
    end)
    t.falsy(ran, "a step that is off doesn't run")
    guard.reset()
    guard.run("another step", function()
        ran = true
    end)
    t.truthy(ran, "on again after a reset")
end)

t.test("a steady frame is cheap: few game calls, and full names only on the half-second refresh", function()
    -- With the speedometer on: at a steady speed it sends nothing, and only checks its
    -- widget every 0.5 s (one IsInViewport and two full names), on frames of its own,
    -- hence 6 frames with full names in a second instead of 4.
    local g = running({ Speedometer = true })
    g.keys.W = true
    g.frames(70)
    t.eq(#g.viewport, 1, "the speedometer is on the screen")
    local calls, reads = fake.counts.calls, fake.counts.reads
    local frames, withNames, names = 60, 0, 0
    for _ = 1, frames do
        local before = fake.counts.fullNames
        g.frame()
        local n = fake.counts.fullNames - before
        if n > 0 then
            withNames = withNames + 1
            names = names + n
        end
    end
    local perFrame = (fake.counts.calls - calls) / frames
    local readsPerFrame = (fake.counts.reads - reads) / frames
    t.truthy(perFrame <= 30, string.format("%.1f game function calls per frame", perFrame))
    t.truthy(readsPerFrame <= 45, string.format("%.1f property reads per frame", readsPerFrame))
    t.truthy(withNames <= 6, string.format("full names on %d of %d frames", withNames, frames))
    t.truthy(names <= 60, string.format("%d full names in %d frames", names, frames))
end)

t.test("the camera's refreshes, the camera list's scans and the movement's refreshes start on different frames",
    function()
        local g = running()
        local scans, frame = {}, 0
        fake.method(g.pawn, "GetMainCamera", fake.ufunction("GetMainCamera", 1, function(_, out)
            scans[frame] = true
            out.MainCamera = g.c.cineCamera
        end))
        local function check(what, frames)
            local shared, refreshes = 0, 0
            scans = {}
            for i = 1, frames or 120 do
                frame = i
                local stops, writes = g.shakeStops, fake.writes(g.cmc).JumpZVelocity or 0
                g.frame()
                local cam = g.shakeStops > stops
                local moved = (fake.writes(g.cmc).JumpZVelocity or 0) > writes
                if cam then
                    refreshes = refreshes + 1
                end
                if (cam and scans[i]) or (cam and moved) or (moved and scans[i]) then
                    shared = shared + 1
                end
            end
            frame = 0 -- scans between the checks don't count
            t.truthy(refreshes >= 2, what .. ": the camera refreshed")
            t.eq(shared, 0, what)
        end
        check("after loading")
        g.press(F6)
        g.press(F6)
        check("after F6 twice")
        g.inBattle = true
        g.frames(37)
        g.inBattle = false
        g.frame() -- everything starts again on this frame
        check("after a battle")
        noErrors(g)
        -- First person starting again at any point between the movement's refreshes:
        -- after F6 twice, or with a new camera manager under the same character, which
        -- first person moves to within one frame.
        for offset = 0, 31 do
            for _, how in ipairs({ "F6", "camera manager" }) do
                g = running()
                fake.method(g.pawn, "GetMainCamera", fake.ufunction("GetMainCamera", 1, function(_, out)
                    scans[frame] = true
                    out.MainCamera = g.c.cineCamera
                end))
                if how == "F6" then
                    g.press(F6)
                    g.frames(offset)
                    g.press(F6)
                else
                    g.frames(offset)
                    local pcm = fake.copy(g.pcm)
                    fake.set(g.pc, "PlayerCameraManager", pcm)
                    g.pcm = pcm
                    g.frame() -- first person starts again on this frame
                end
                check(string.format("after %s, %d frames on", how, offset + 1), 70)
            end
        end
        noErrors(g)
    end)

t.test("the refreshes stay on different frames when the frame times vary, and after the movement alone came back",
    function()
        local g, scanned = nil, false
        local function sharedFrames(frames, nextDt)
            local shared = 0
            for _ = 1, frames do
                scanned = false
                local stops, writes = g.shakeStops, fake.writes(g.cmc).JumpZVelocity or 0
                g.frame(nextDt and nextDt())
                local cam = g.shakeStops > stops
                local moved = (fake.writes(g.cmc).JumpZVelocity or 0) > writes
                if (cam and moved) or (cam and scanned) or (moved and scanned) then
                    shared = shared + 1
                end
            end
            return shared
        end
        local function setup()
            g = running()
            fake.method(g.pawn, "GetMainCamera", fake.ufunction("GetMainCamera", 1, function(_, out)
                scanned = true
                out.MainCamera = g.c.cineCamera
            end))
        end
        -- A minute between 24 and 36 fps.
        setup()
        local seed = 12345
        t.eq(sharedFrames(1800, function()
            seed = (seed * 1103515245 + 12345) % 2147483648
            return 1 / (24 + 12 * seed / 2147483648)
        end), 0, "a minute of varying frame times")
        -- The game locks the input for a moment (a menu, an interaction): the movement
        -- is handed back and taken again while first person stays on.
        for frames = 1, 30 do
            setup()
            g.inputLocked = true
            g.frames(frames)
            g.inputLocked = false
            g.frame() -- the movement is taken again on this frame
            t.eq(sharedFrames(120), 0, string.format("after the input was locked for %d frames", frames))
        end
        noErrors(g)
    end)

t.test("five minutes of play don't fill the log", function()
    local g = running()
    strafeHops(g, 19000) -- over 31 status intervals
    t.truthy(#g.log < 250, #g.log .. " lines")
    t.eq(count(g.log, "Status (10s)"), 30, "at most 30 status lines")
    t.eq(count(g.log, "Status (10s), the last one"), 1)
    t.eq(count(g.log, "Hop "), 20, "at most 20 hop lines")
end)

t.test("bad settings are reported and the defaults used", function()
    local g = start({ MaxSpeed = "fast", Bogus = true })
    t.contains(g.log, "MaxSpeed")
    t.contains(g.log, "Unknown setting Bogus")
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    g.keys.W = true
    g.frames(30)
    t.near(g.speed(), MAX_SPEED, 1)
end)

t.test("a broken config.lua is reported and the defaults used", function()
    local g = fake.newGame()
    _G.dofile = function()
        error("config.lua:12: '}' expected near 'MaxSpeed'")
    end
    fake.loadMod(root)
    t.contains(g.log, "Could not read config.lua")
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
end)
