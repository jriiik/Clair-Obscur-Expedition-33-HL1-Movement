-- First-person sounds (BodySounds): the hidden body keeps animating, so the anim
-- notifies of its animations still play the footsteps, the jump and landing sounds
-- and the rest. Runs main.lua against the fake game, as test_mod.lua does.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7, F8 = 0x74, 0x75, 0x76, 0x77
local JOURNAL = "HL1Movement.changes"
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local OPTION = "VisibilityBasedAnimTickOption"

local function start(config, options)
    local g = fake.newGame(options)
    fake.useConfig(config)
    fake.loadMod(root)
    return g
end

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

-- Footsteps over the next frames.
local function footsteps(g, frames)
    local before = g.footsteps
    g.frames(frames)
    return g.footsteps - before
end

-- Footsteps over a second of walking, after the second a hidden mesh still counts as drawn.
local function footstepsWalking(g)
    g.keys.W = true
    g.frames(90)
    return footsteps(g, 60)
end

-- The copy of camera.lua the mod loaded.
local function cameraStatus()
    return require("hl1movement.camera").status()
end

-- A second body with an animation of its own, on the character, whose tick option
-- can't be set: UE4SS raises an error (write "refused"), or the value stays ("ignored").
local function stubbornBody(g, write)
    local c = g.c
    local shown = { [OPTION] = 4 }
    local props = setmetatable({}, { __index = shown, __newindex = function(self, key, value)
        if key == OPTION then
            if write == "refused" then
                error("can't write " .. key)
            end
            return
        end
        rawset(self, key, value)
    end })
    local body = c.skeletal(function()
        return c.pawn
    end, props, c.newAnimInstance(), { name = "StubbornBody" })
    local children = fake.props(c.mesh).AttachChildren
    children[#children + 1] = body
    return body
end

t.test("in the game as it is, a body hidden from its owner stops animating a second after it was drawn (the bug)",
    function()
        local g = running({ BodySounds = false })
        local p = fake.props(g.c.mesh)
        t.eq(p.bOwnerNoSee, true)
        g.frames(70) -- standing still while the graph stops
        t.eq(footstepsWalking(g), 0, "no footsteps from a body nobody sees")
        t.eq(p[OPTION], 4)
        t.falsy(fake.writes(g.c.mesh)[OPTION], "untouched")
        -- The report shows it: ALS's copy of the speed stopped when the graph did.
        g.press(F8)
        local line = t.contains(g.log, "ALS animation: Speed=0, ")
        t.truthy(line:find("moving at 800 cm/s", 1, true), line)
        t.contains(g.log, "kept animating 0")
        -- Third person: drawn again, and counted as drawn a frame after it was.
        g.press(F6)
        t.eq(footsteps(g, 1), 0, "the frame after it was first drawn again")
        t.eq(footsteps(g, 1), 1, "and from the next on")
        t.truthy(footstepsWalking(g) > 50, "third person: footsteps again")
        noErrors(g)
    end)

t.test("first person keeps the hidden body animating, so its sounds play, and F6 puts its option back", function()
    local g = running()
    local c = g.c
    local p = fake.props(c.mesh)
    t.eq(p.bOwnerNoSee, true, "hidden")
    t.eq(p[OPTION], 0, "animated as if it were drawn")
    t.truthy(footstepsWalking(g) > 50, "footsteps go on in first person")
    t.eq(fake.props(c.skinMesh)[OPTION], 0)
    t.falsy(fake.writes(c.skinMesh)[OPTION], "a mesh that animates unseen anyway is left alone")
    t.contains(g.log, "Keeping the hidden body's animation going, so its sounds play")
    t.contains(g.log, "4 (OnlyTickPoseWhenRendered) -> 0 (AlwaysTickPoseAndRefreshBones)")
    t.truthy(g.shared[JOURNAL]:find(OPTION .. "\tn4", 1, true), "noted, for a restart of the mods")
    t.eq(cameraStatus().animatedParts, 1)
    g.press(F6)
    t.eq(p[OPTION], 4, "the game's option is back")
    t.eq(p.bOwnerNoSee, false)
    t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing left to put back")
    noErrors(g)
end)

t.test("only an option that stops the animation of a mesh that isn't drawn is changed: 2 and up", function()
    for _, case in ipairs({ { option = 1, kept = false }, { option = 2, kept = true } }) do
        local g = running(nil, { bodyTickOption = case.option })
        local p = fake.props(g.c.mesh)
        t.eq(p[OPTION], case.kept and 0 or case.option, "option " .. case.option)
        t.truthy(footstepsWalking(g) > 50, "footsteps with option " .. case.option)
        g.press(F6)
        t.eq(p[OPTION], case.option)
        noErrors(g)
    end
end)

t.test("an option the game sets during first person is the one put back", function()
    local g = running()
    local p = fake.props(g.c.mesh)
    p[OPTION] = 3 -- the game's own, for example as a cutscene ends
    g.frames(31)
    t.eq(p[OPTION], 0, "kept animating")
    t.contains(g.log, "The game set")
    t.truthy(g.shared[JOURNAL]:find(OPTION .. "\tn3", 1, true), "the game's is the one noted")
    g.press(F6)
    t.eq(p[OPTION], 3, "the game's latest")
    g.press(F6)
    g.frames(5)
    t.eq(p[OPTION], 0)
    p[OPTION] = 1 -- one that animates unseen: left as the game set it
    g.frames(31)
    t.eq(p[OPTION], 1)
    g.press(F6)
    t.eq(p[OPTION], 1, "still the game's")
    g.press(F6)
    g.frames(5)
    t.eq(p[OPTION], 1, "1 animates unseen: nothing to do")
    p[OPTION] = 4
    g.frames(31)
    t.eq(p[OPTION], 0, "kept animating again")
    -- Set by the game just before first person ends, with no pass between.
    p[OPTION] = 1
    g.press(F6)
    t.eq(p[OPTION], 1, "the game's, not the one before")
    noErrors(g)
end)

t.test("a mesh without an animation of its own (one that follows another's pose) keeps its option", function()
    local g = start()
    fake.props(g.c.skinMesh)[OPTION] = 4
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.eq(fake.props(g.c.skinMesh).bOwnerNoSee, true, "hidden")
    t.eq(fake.props(g.c.skinMesh)[OPTION], 4)
    t.falsy(fake.writes(g.c.skinMesh)[OPTION])
    t.eq(fake.props(g.c.mesh)[OPTION], 0, "the body with the animation is kept animating")
    t.absent(g.log, "Not keeping")
    noErrors(g)
end)

t.test("a part the game hides from the player itself keeps its option, also when it was kept animating before",
    function()
        local g = start()
        g.loadSave()
        local p = fake.props(g.c.mesh)
        p.bOwnerNoSee = true -- hidden by the game before first person
        g.frames(SETTLE_FRAMES)
        t.eq(p[OPTION], 4)
        t.falsy(fake.writes(g.c.mesh)[OPTION])
        g = running()
        p = fake.props(g.c.mesh)
        t.eq(p[OPTION], 0)
        g.press(F6)
        p.bOwnerNoSee = true -- the game hides it in third person
        g.press(F6)
        g.frames(40)
        t.eq(p[OPTION], 4, "left alone: the game hides it")
        g.press(F6)
        t.eq(p.bOwnerNoSee, true, "and it stays hidden, as the game wants")
        noErrors(g)
    end)

t.test("a mesh the game keeps invisible isn't started, nor is one it shows later that wasn't drawn (logged once)",
    function()
        local g = start()
        g.loadSave()
        local p = fake.props(g.c.mesh)
        p.bVisible = false -- a placeholder the game doesn't draw
        g.frames(SETTLE_FRAMES)
        t.eq(p.bOwnerNoSee, true, "hidden")
        t.eq(p[OPTION], 4)
        t.falsy(fake.writes(g.c.mesh)[OPTION])
        t.absent(g.log, "Not keeping", "the game hides it: nothing to say")
        p.bVisible = true -- shown by the game, but the mod hides it, so it isn't drawn
        g.frames(70)
        t.eq(p[OPTION], 4, "left alone: it never animated")
        t.contains(g.log, "Not keeping SkeletalMeshComponent_")
        t.eq(count(g.log, "Not keeping"), 1, "once")
        noErrors(g)
    end)

t.test("the game hiding the body itself during first person stops keeping it animating, until it shows it again",
    function()
        local g = running()
        local p = fake.props(g.c.mesh)
        for _, case in ipairs({ { flag = "bVisible", hides = false }, { flag = "bHiddenInGame", hides = true } }) do
            t.eq(p[OPTION], 0)
            p[case.flag] = case.hides -- SetVisibility(false), or hidden in game
            g.frames(31)
            t.eq(p[OPTION], 4, case.flag .. ": put back, as it would stop in third person")
            t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing left to put back")
            t.eq(cameraStatus().animatedParts, 0)
            t.eq(p.bOwnerNoSee, true, "still hidden from the player")
            p[case.flag] = not case.hides
            g.frames(31)
            t.eq(p[OPTION], 0, case.flag .. ": kept animating again once shown")
        end
        g.press(F6)
        t.eq(p[OPTION], 4)
        noErrors(g)
    end)

t.test("first person starting again keeps the body animating, though it hasn't been drawn since", function()
    local g = running()
    local p = fake.props(g.c.mesh)
    g.keys.W = true
    for _, keys in ipairs({ { F7 }, { F6, F6 }, { F5, F5 } }) do
        g.frames(120) -- two seconds of first person: the body hasn't been drawn since
        for _, key in ipairs(keys) do
            g.press(key)
        end
        t.eq(p.bOwnerNoSee, true, "hidden again")
        t.eq(p[OPTION], 0, "kept animating")
        t.truthy(footsteps(g, 60) > 50, "footsteps go on")
    end
    noErrors(g)
end)

t.test("F7 applies BodySounds both ways", function()
    local g = running({ BodySounds = false })
    local p = fake.props(g.c.mesh)
    g.keys.W = true
    g.frames(120) -- the body hasn't been drawn since first person started
    t.eq(p[OPTION], 4)
    fake.useConfig({ BodySounds = true })
    g.press(F7)
    t.eq(p[OPTION], 0, "switched on")
    t.truthy(footsteps(g, 60) > 50, "footsteps again")
    fake.useConfig({ BodySounds = false })
    g.press(F7)
    t.eq(p[OPTION], 4, "switched off")
    t.eq(p.bOwnerNoSee, true, "still hidden")
    t.eq(footsteps(g, 30), 0, "the sounds stop at once")
    noErrors(g)
end)

t.test("first person starting on the frame the game shows the body again, as a battle ends, keeps it animating",
    function()
        local g = running()
        local p = fake.props(g.c.mesh)
        g.keys.W = true
        g.frames(120)
        g.inBattle = true
        p.bVisible = false -- the game hides the exploration body in battle
        g.frames(200)
        t.eq(p[OPTION], 4, "put back in battle")
        t.eq(p.bOwnerNoSee, false)
        g.inBattle = false
        p.bVisible = true
        g.frame()
        t.eq(p.bOwnerNoSee, true, "first person again")
        t.eq(p[OPTION], 0, "kept animating from the first frame")
        t.truthy(footsteps(g, 60) > 50, "footsteps")
        -- First person starting while the game still hides the body: left alone until shown.
        g.inBattle = true
        p.bVisible = false
        g.frames(200)
        g.inBattle = false
        g.frames(40)
        t.eq(p.bOwnerNoSee, true)
        t.eq(p[OPTION], 4, "the game hides it")
        p.bVisible = true
        g.frames(31)
        t.eq(p[OPTION], 0, "shown: kept animating")
        t.absent(g.log, "Not keeping")
        noErrors(g)
    end)

t.test("first person given up puts the option back with the rest", function()
    local g = running({ CameraMethod = "engine" }, { cameraStyleIgnored = true })
    t.eq(fake.props(g.c.mesh)[OPTION], 0, "kept animating while it checks")
    g.frames(150)
    t.contains(g.log, "First person doesn't work here")
    t.eq(fake.props(g.c.mesh)[OPTION], 4)
    t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true))
    noErrors(g)
end)

t.test("a part taken off the character gets its option back at once", function()
    local g = running()
    local c = g.c
    t.eq(fake.props(c.mesh)[OPTION], 0)
    fake.set(c.capsule, "AttachChildren", fake.array({ c.springArm }))
    g.frames(31)
    t.eq(fake.props(c.mesh)[OPTION], 4)
    t.eq(fake.props(c.mesh).bOwnerNoSee, false)
    t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true))
    noErrors(g)
end)

t.test("an outfit swapped in at the same address: the old body's option is forgotten, the new one kept animating",
    function()
        local g = running()
        local c = g.c
        local oldName = c.mesh:GetFullName()
        t.truthy(g.shared[JOURNAL]:find(oldName .. "\t" .. OPTION, 1, true))
        -- In UE4SS the old body's Lua object holds only the address: once the new body
        -- has it, the old object reads as valid again, and reads and writes the new one.
        local body = c.skeletal(function()
            return c.pawn
        end, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }), [OPTION] = 4 }, c.newAnimInstance(),
            { name = "NewBody", address = fake.addressOf(c.mesh) })
        fake.reuseAddress(c.mesh, body)
        fake.set(c.capsule, "AttachChildren", fake.array({ body, c.springArm }))
        g.keys.W = true
        g.frames(31)
        t.eq(fake.props(body).bOwnerNoSee, false, "not touched on the pass it first appears")
        t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "the old body's option is forgotten")
        t.falsy(fake.writes(body)[OPTION], "and not put on the new one")
        g.frames(31)
        t.eq(fake.props(body).bOwnerNoSee, true, "hidden on the next pass")
        t.eq(fake.props(body)[OPTION], 0, "kept animating: it was drawn before it was hidden")
        t.truthy(footsteps(g, 60) > 50, "footsteps go on")
        g.press(F6)
        t.eq(fake.props(body)[OPTION], 4)
        t.eq(fake.props(body).bOwnerNoSee, false)
        t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing left to put back")
        noErrors(g)
    end)

t.test("a new body at a drawn body's address, which the game kept invisible, doesn't count as drawn", function()
    local g = running()
    local c = g.c
    local body = c.skeletal(function()
        return c.pawn
    end, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }), [OPTION] = 4, bVisible = false },
        c.newAnimInstance(), { name = "NewBody", address = fake.addressOf(c.mesh) })
    fake.reuseAddress(c.mesh, body)
    fake.set(c.capsule, "AttachChildren", fake.array({ body, c.springArm }))
    g.frames(70)
    t.eq(fake.props(body).bOwnerNoSee, true, "hidden")
    fake.props(body).bVisible = true -- shown by the game while the mod hides it: never drawn
    g.frames(31)
    t.eq(fake.props(body)[OPTION], 4, "left alone: it never animated")
    t.contains(g.log, "Not keeping NewBody (SkeletalMeshComponent) animating")
    noErrors(g)
end)

t.test("a mesh that animates unseen, swapped in at a kept body's address, isn't given the old body's option",
    function()
        local g = running()
        local c = g.c
        local follower = c.skeletal(function()
            return c.pawn
        end, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }) }, nil,
            { name = "NewFollower", address = fake.addressOf(c.mesh) })
        fake.reuseAddress(c.mesh, follower)
        fake.set(c.capsule, "AttachChildren", fake.array({ follower, c.springArm }))
        g.frames(70)
        t.eq(fake.props(follower).bOwnerNoSee, true, "hidden")
        t.eq(fake.props(follower)[OPTION], 0)
        t.falsy(fake.writes(follower)[OPTION], "untouched")
        g.press(F6)
        t.falsy(fake.writes(follower)[OPTION], "untouched")
        noErrors(g)
    end)

t.test("UE4SS restarting its mods: the new copy puts the option back first", function()
    local g = running()
    t.eq(fake.props(g.c.mesh)[OPTION], 0)
    g.restartMods(root)
    g.frame()
    t.eq(fake.props(g.c.mesh)[OPTION], 4, "put back before anything else")
    g.frames(SETTLE_FRAMES)
    t.eq(fake.props(g.c.mesh)[OPTION], 0, "and the new copy keeps it animating again")
    g.press(F5)
    t.eq(fake.props(g.c.mesh)[OPTION], 4)
    t.eq(g.shared[JOURNAL], "", "nothing left to put back")
    noErrors(g)
end)

for _, write in ipairs({ "ignored", "refused" }) do
    t.test("a tick option whose write is " .. write .. " isn't counted, noted or tried again on every pass", function()
        local g = start()
        local body = stubbornBody(g, write)
        g.loadSave()
        g.frames(SETTLE_FRAMES + 120)
        t.eq(fake.props(body).bOwnerNoSee, true, "hidden")
        t.eq(fake.props(body)[OPTION], 4)
        t.eq(fake.writes(body)[OPTION], 1, "tried once")
        local line = t.contains(g.log, "Could not keep StubbornBody (SkeletalMeshComponent) animating")
        t.truthy(line:find("reads 4 after setting 0", 1, true), line)
        if write == "refused" then
            t.truthy(line:find("can't write", 1, true), "with the error: " .. line)
        end
        t.eq(count(g.log, "Could not keep"), 1)
        t.falsy(g.shared[JOURNAL]:find("StubbornBody\t" .. OPTION, 1, true), "nothing to put back")
        t.eq(cameraStatus().animatedParts, 1, "only the body that took it")
        t.eq(fake.props(g.c.mesh)[OPTION], 0)
        g.press(F6)
        t.eq(fake.writes(body)[OPTION], 1, "nothing put back")
        t.eq(fake.props(g.c.mesh)[OPTION], 4)
        noErrors(g)
    end)
end

t.test("the report lists the skinned meshes, their tick options and whether their animation runs", function()
    local g = running()
    g.keys.W = true
    g.frames(90)
    g.press(F8)
    t.contains(g.log, "hidden parts=")
    t.contains(g.log, "(kept animating 1)")
    t.contains(g.log, "Character.Mesh = ")
    t.contains(g.log, "Skinned meshes on the character (BodySounds=true):")
    t.contains(g.log, "tick option 0 (AlwaysTickPoseAndRefreshBones) [kept animating by the mod, was 4 "
        .. "(OnlyTickPoseWhenRendered)], seen recently=false")
    t.contains(g.log, "anim instance ALS_UE5_AnimBP_C")
    t.contains(g.log, "bVisible=")
    local line = t.contains(g.log, "ALS animation: Speed=")
    local speed, moving = line:match("Speed=([%d%.]+), .-moving at (%d+) cm/s")
    t.truthy(speed and moving, line)
    t.near(tonumber(speed), tonumber(moving), 20, "ALS's copy follows the speed: the graph runs")
    t.truthy(tonumber(moving) > 500, line)
    t.contains(g.log, "end of diagnostics")
    noErrors(g)
end)
