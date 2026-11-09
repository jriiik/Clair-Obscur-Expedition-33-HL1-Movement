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

local function start(config, options)
    local g = fake.newGame(options)
    fake.useConfig(config)
    fake.loadMod(root)
    return g
end

local SETTLE_FRAMES = 70 -- a little over the second the mod leaves a new character alone

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

t.test("loads, binds its keys and waits for a save", function()
    local g = start()
    t.contains(g.log, "Version 0.1.0 loaded")
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

t.test("a new level is left alone for a moment", function()
    local g = start()
    g.loadSave()
    g.frames(30)
    t.eq(styleOf(g), "Default", "still settling")
    t.falsy(fake.writes(g.cmc).BrakingDecelerationWalking)
    g.frames(40)
    t.eq(styleOf(g), "FirstPerson")
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
    g.keybinds[F8]()
    t.contains(g.log, "HL1Movement 0.1.0 diagnostics")
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
    t.near(fake.props(g.pawn).BaseEyeHeight, 96 * 0.78, 1e-9)
    noErrors(g)
end)

t.test("first person hides the body from the player only, and leaves lights on", function()
    local g = running()
    local c = g.c
    t.eq(fake.props(c.mesh).bOwnerNoSee, true, "own mesh")
    t.eq(fake.props(c.skinMesh).bOwnerNoSee, true, "mesh of an actor the character owns")
    t.eq(fake.props(c.propMesh).bHiddenInGame, true, "mesh of an attached actor it doesn't own")
    t.eq(fake.props(c.propMesh).bOwnerNoSee, false)
    t.falsy(fake.writes(c.torchLight).bHiddenInGame, "light untouched")
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
    g.frames(40)
    t.eq(fake.props(newSkin).bOwnerNoSee, true, "the new part is hidden too")
    g.press(F6)
    t.eq(fake.props(newSkin).bOwnerNoSee, false, "and shown again when first person turns off")
    noErrors(g)
end)

t.test("the first-person check passes when the camera is at the eyes", function()
    local g = running()
    g.frames(200)
    t.absent(g.log, "doesn't work")
    g.press(F8)
    t.contains(g.log, "Camera: working")
end)

t.test("if first person doesn't take effect, the mod gives up and shows the character again", function()
    local g = running(nil, { cameraStyleIgnored = true })
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true, "hidden while it checks")
    g.frames(150)
    t.contains(g.log, "First person doesn't work here: the camera stayed 3")
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

t.test("a slow camera blend to the eyes isn't taken for first person not working", function()
    local g = start()
    g.cameraLocation = { X = -300, Y = 0, Z = 150 }
    g.cameraSpeed = 100 -- over three seconds to reach the eyes
    g.loadSave()
    g.frames(SETTLE_FRAMES + 360)
    t.absent(g.log, "doesn't work")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true)
    g.press(F8)
    t.contains(g.log, "Camera: working")
end)

t.test("while the game is paused, first person isn't given up", function()
    local g = start()
    g.loadSave()
    g.frames(50)
    g.paused = true -- paused just before first person starts, so the camera can't follow
    g.frames(300)
    t.absent(g.log, "doesn't work")
    t.eq(fake.props(g.c.mesh).bOwnerNoSee, true)
    g.paused = false
    g.frames(150)
    t.absent(g.log, "doesn't work")
    t.eq(styleOf(g), "FirstPerson")
    noErrors(g)
end)

t.test("if the camera style can't be switched, the mod gives up and shows the character again", function()
    local g = start()
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
    local g = running()
    runTo(g, MAX_SPEED)
    local before = g.speed()
    g.keys.W = false
    g.frame()
    t.near(g.speed(), before - before * 4 / 60, 0.5, "one frame of friction 4")
    g.frames(60)
    t.eq(g.speed(), 0, "stopped after a second")
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
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    g.frames(300, nil, function()
        g.rotation.Yaw = g.rotation.Yaw + 1.2
    end)
    t.truthy(g.speed() > MAX_SPEED * 1.2, string.format("speed %.0f should be well above %.0f", g.speed(), MAX_SPEED))
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

t.test("the speed limiter is paused again if the game starts it", function()
    local g = running()
    t.eq(g.limiterTicking, false)
    g.limiterTicking = true
    g.frames(40)
    t.eq(g.limiterTicking, false, "paused again")
    g.inBattle = true
    g.frame()
    t.eq(g.limiterTicking, true, "on again after the mod hands back")
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
end)

t.test("dialogue cameras: first person steps aside, movement stays", function()
    local g = running()
    g.mainCameraActive = false
    g.frame()
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
    g.mainCameraActive = true
    g.frame()
    t.eq(styleOf(g), "FirstPerson")
end)

t.test("another view target: first person steps aside", function()
    local g = running()
    g.viewTarget = fake.object({ className = "CineCameraActor", chain = { "CineCameraActor", "CameraActor", "Actor" } })
    g.frame()
    t.eq(styleOf(g), "Default")
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

t.test("F7 hooks the game's jump event when JumpInput needs it", function()
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
    t.contains(g.log, "HL1Movement 0.1.0 diagnostics")
    t.contains(g.log, "Movement component:")
    t.contains(g.log, "Camera manager:")
    t.contains(g.log, "BP_VelocityControllerComponent_C")
    t.contains(g.log, "Character.TargetRotation = (Pitch=0.0 Yaw=0.0 Roll=0.0)")
    t.contains(g.log, "Movement.Velocity = (X=")
    t.contains(g.log, "Errors: none")
    t.contains(g.log, "end of diagnostics")
    noErrors(g)
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

t.test("if the curve can't be taken out, its braking is cancelled out instead", function()
    local g = running(nil, { curveLocked = true })
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

t.test("a new level: nothing old is touched, the new one is set up after a moment", function()
    local g = running()
    local old = g.c
    local newWorld = fake.object({ className = "World", name = "Level_Other", path = "/Game/Levels/Other.Level_Other" })
    -- Loading the level destroys the old character and everything on it.
    for _, obj in ipairs({ old.pawn, old.cmc, old.capsule, old.mesh, old.skinMesh, old.propMesh, old.limiter }) do
        fake.destroy(obj)
    end
    local c = g.buildCharacter()
    fake.setWorld(c.pawn, newWorld)
    g.useCharacter(c)
    g.frame()
    noErrors(g)
    t.eq(styleOf(g), "Default", "first person waits while the level settles")
    t.falsy(fake.writes(c.cmc).BrakingDecelerationWalking)
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
    t.eq(fake.props(c.cmc).BrakingDecelerationWalking, TAKEN_BRAKING)
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
    g.frames(40)
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
    t.contains(g.log, "Half-Life movement on")
    g.frames(SETTLE_FRAMES)
    t.eq(styleOf(g), "FirstPerson")
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
