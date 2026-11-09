-- Runs main.lua against the fake game in tests/fake_game.lua, frame by frame.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7, F8 = 0x74, 0x75, 0x76, 0x77
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
    t.absent(g.log, "Error:", "the mod logged an error")
    t.absent(g.log, "Turned off after", "the mod turned itself off")
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

t.test("the camera style is set through the controller when UE4SS can't see the field", function()
    local g = running(nil, { cameraStyleNotReflected = true })
    t.eq(styleOf(g), "FirstPerson")
    g.frames(12)
    t.absent(g.log, "doesn't seem to work")
    g.inBattle = true
    g.frame()
    t.eq(styleOf(g), "Default", "put back to Default")
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
    g.frames(12)
    t.absent(g.log, "doesn't seem to work")
end)

t.test("a camera manager that ignores the camera style is reported", function()
    local g = running(nil, { cameraStyleIgnored = true })
    g.frames(12)
    t.contains(g.log, "The first-person camera doesn't seem to work")
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
    t.eq(p.MaxWalkSpeed, 375, "ALS set its own walking speed again")
    g.inBattle = false
    g.frame()
    t.eq(styleOf(g), "FirstPerson", "back after the battle")
    t.eq(p.BrakingDecelerationWalking, TAKEN_BRAKING)
    noErrors(g)
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

t.test("F8 writes a diagnostics report", function()
    local g = running()
    g.press(F8)
    t.contains(g.log, "HL1Movement 0.1.0 diagnostics")
    t.contains(g.log, "Movement component:")
    t.contains(g.log, "Camera manager:")
    t.contains(g.log, "BP_VelocityControllerComponent_C")
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

t.test("an error every frame turns the mod off after 30 frames and puts the game back", function()
    local g = start(nil, { breakVelocity = true })
    g.loadSave()
    g.frames(SETTLE_FRAMES + 40)
    t.contains(g.log, "Turned off after 30 errors in a row")
    t.eq(styleOf(g), "Default")
    t.eq(fake.props(g.cmc).BrakingDecelerationWalking, 2048)
    local count = #g.log
    g.frames(10)
    t.eq(#g.log, count, "quiet once off")
    g.press(F5)
    t.contains(g.log, "Half-Life movement on")
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
