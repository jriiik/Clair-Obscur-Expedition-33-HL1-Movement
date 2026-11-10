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
    t.contains(g.log, "Version 0.2.1 loaded")
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
    t.contains(g.log, "HL1Movement 0.2.1 diagnostics")
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
    -- In UE4SS the old part's object reads as valid again once a new one has its
    -- address, so the old one isn't destroyed here.
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
        t.contains(g.log, "shows a field of view of 95.0 instead of FieldOfView 100")
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

t.test("with DisableSpeedLimiter = false, the cut lines say the limiter isn't paused", function()
    local g = running({ DisableSpeedLimiter = false }, { maxSpeedIgnoresWalkSpeed = true })
    g.keys.W = true
    g.frames(60)
    t.contains(g.log, "speed limiter not paused (DisableSpeedLimiter = false)")
    t.absent(g.log, "speed limiter not found")
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
    t.contains(g.log, "HL1Movement 0.2.1 diagnostics")
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
    local g = running()
    g.keys.W = true
    g.frames(70)
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
    t.truthy(withNames <= 4, string.format("full names on %d of %d frames", withNames, frames))
    t.truthy(names <= 60, string.format("%d full names in %d frames", names, frames))
end)

t.test("five minutes of play don't fill the log", function()
    local g = running()
    strafeHops(g, 18000)
    t.truthy(#g.log < 250, #g.log .. " lines")
    t.eq(count(g.log, "Status (10s)"), 30, "at most 30 status lines")
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
