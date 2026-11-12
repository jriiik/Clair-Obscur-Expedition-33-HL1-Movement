-- First-person sounds (BodySounds): the hidden body keeps animating, so the anim
-- notifies of its animations still play the footsteps and the rest (the fake counts
-- the footsteps). Runs main.lua against the fake game, as test_mod.lua does.

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

-- Runs frames up to and with first person's next half-second refresh, which goes over
-- the body. (31 frames hold one at most frame phases, but two when they start on one.)
local function untilPass(g)
    local camera = package.loaded["hl1movement.camera"]
    local due = camera.nextRefresh()
    for _ = 1, 40 do
        g.frame()
        if camera.nextRefresh() ~= due then
            return
        end
    end
    error("no pass over the body in 40 frames")
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

-- Presses the report key, and returns the lines of that report.
local function reportNow(g)
    local before = #g.log
    g.press(F8)
    local lines = {}
    for i = before + 1, #g.log do
        lines[#lines + 1] = g.log[i]
    end
    return lines
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
        local report = reportNow(g)
        local line = t.contains(report, "ALS animation: Speed=0, ")
        t.truthy(line:find("moving at 800 cm/s", 1, true), line)
        t.contains(report, "kept animating 0")
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

t.test("a body the game gives an option that animates unseen is no longer counted or noted as kept by the mod",
    function()
        local g = running()
        local p = fake.props(g.c.mesh)
        g.keys.W = true
        t.eq(cameraStatus().animatedParts, 1)
        p[OPTION] = 1 -- AlwaysTickPose: the game's own, and it animates unseen
        g.frames(31)
        t.eq(p[OPTION], 1, "left as the game set it")
        t.eq(cameraStatus().animatedParts, 0, "nothing of the mod's is left on it")
        t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing to put back")
        g.frames(60)
        g.press(F8)
        t.contains(g.log, "(kept animating 0)")
        t.contains(g.log, "tick option 1 (AlwaysTickPose), seen recently=false")
        t.absent(g.log, "[kept animating by the mod, was 1")
        t.truthy(footsteps(g, 60) > 50, "it animates all the same")
        p[OPTION] = 4 -- the game's again: kept animating again, and 4 is what comes back
        g.frames(31)
        t.eq(p[OPTION], 0)
        t.eq(cameraStatus().animatedParts, 1)
        t.truthy(g.shared[JOURNAL]:find(OPTION .. "\tn4", 1, true), "noted again")
        g.press(F6)
        t.eq(p[OPTION], 4)
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

t.test("a mesh the game keeps invisible isn't started, nor is one it shows later that it had never drawn (logged "
    .. "once)", function()
    local g = start()
    g.loadSave()
    local p = fake.props(g.c.mesh)
    p.bVisible = false -- a placeholder the game doesn't draw, from the character's first frame
    g.frames(SETTLE_FRAMES)
    t.eq(p.bOwnerNoSee, true, "hidden")
    t.eq(p[OPTION], 4)
    t.falsy(fake.writes(g.c.mesh)[OPTION])
    t.absent(g.log, "Not keeping", "the game hides it: nothing to say")
    p.bVisible = true -- shown by the game, but the mod hides it, so it isn't drawn
    g.frames(70)
    t.eq(p[OPTION], 4, "left alone: it never animated")
    local line = t.contains(g.log, "Not keeping SkeletalMeshComponent_")
    t.truthy(line:find("until first person next starts after it was in view", 1, true), "how it ends: " .. line)
    t.eq(count(g.log, "Not keeping"), 1, "once")
    -- The same goes for a body the game shows for the first time after first person
    -- started (an area that opens with a battle): the mod can't tell the two apart. It
    -- ends when first person next starts after the body was in view.
    g.press(F6)
    g.frames(12)
    g.press(F6)
    t.eq(p[OPTION], 0, "drawn in third person meanwhile: kept animating")
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

t.test("a character's first start right after the game shows its body again keeps it animating, if it was drawn "
    .. "before", function()
    for lead = 0, 1 do
        local g = start()
        g.loadSave()
        local p = fake.props(g.c.mesh)
        g.frames(120) -- drawn for two seconds, while the mod still leaves the character alone
        g.inBattle = true
        p.bVisible = false -- then a battle, in which the game hides the exploration body
        g.frames(240)
        t.eq(p.bOwnerNoSee, false, "no first person in battle")
        p.bVisible = true -- shown again as the battle ends, `lead` frames before the game says it is over
        g.frames(lead)
        g.inBattle = false
        g.frame()
        t.eq(p.bOwnerNoSee, true, "first person, " .. lead .. " frame(s) after the body was shown")
        t.eq(p[OPTION], 0, "kept animating: the game had drawn it before the battle")
        g.keys.W = true
        g.frames(90)
        t.truthy(footsteps(g, 60) > 50, "footsteps")
        t.absent(g.log, "Not keeping")
        t.absent(g.log, "hasn't drawn your character's body yet", "nothing to wait for")
        noErrors(g)
    end
end)

t.test("a body the game shows only after first person's first start is kept animating once shown, if the game "
    .. "had drawn it before", function()
    -- The game says the battle (or the cinematic) is over, first person starts for the
    -- first time for this character, and the game shows the body some frames later.
    -- hides: how the game hides it meanwhile.
    for _, hides in ipairs({ { flag = "bVisible", hidden = false }, { flag = "bHiddenInGame", hidden = true } }) do
        for _, late in ipairs({ 1, 3, 60 }) do
            local what = string.format("%s, shown %d frame(s) late", hides.flag, late)
            local g = start()
            g.loadSave()
            local p = fake.props(g.c.mesh)
            g.frames(120) -- drawn for two seconds, while the mod still leaves the character alone
            g.inBattle = true
            p[hides.flag] = hides.hidden -- a battle, in which the game hides the exploration body
            g.frames(240)
            t.eq(p.bOwnerNoSee, false, "no first person in battle")
            g.inBattle = false
            g.frames(late)
            t.eq(p.bOwnerNoSee, true, "first person, while the game still hides the body: " .. what)
            t.eq(p[OPTION], 4, "the game hides it: left alone")
            p[hides.flag] = not hides.hidden
            g.frames(31)
            t.eq(p[OPTION], 0, "kept animating once the game shows it: it had drawn it before the battle: " .. what)
            g.keys.W = true
            g.frames(90)
            t.truthy(footsteps(g, 60) > 50, "footsteps: " .. what)
            t.absent(g.log, "Not keeping")
            noErrors(g)
        end
    end
end)

t.test("a body the game shows for the first time as first person may start: the character's first start waits "
    .. "for it to be drawn", function()
    for lead = 0, 1 do
        local g = start()
        g.loadSave()
        local p = fake.props(g.c.mesh)
        g.inBattle = true
        p.bVisible = false -- hidden from the character's first frame: an area that opens with a battle
        g.frames(360)
        p.bVisible = true
        g.frames(lead)
        g.inBattle = false
        g.frame()
        t.eq(p.bOwnerNoSee, false, "not hidden yet: the renderer hasn't said it drew the body")
        t.contains(g.log, "First person: waiting (the game hasn't drawn your character's body yet")
        g.frames(2)
        t.eq(p.bOwnerNoSee, true, "first person, once the body was drawn")
        t.eq(p[OPTION], 0, "kept animating")
        g.keys.W = true
        g.frames(90)
        t.truthy(footsteps(g, 60) > 50, "footsteps")
        t.absent(g.log, "Not keeping")
        noErrors(g)
    end
end)

t.test("the wait for a body to be drawn goes on through a pause, in which the renderer still draws", function()
    local g = start()
    g.loadSave()
    local p = fake.props(g.c.mesh)
    g.inBattle = true
    p.bVisible = false -- never drawn before
    g.frames(360)
    p.bVisible = true
    g.inBattle = false
    g.paused = true -- the game's menu, opened on the frame the battle ends
    g.frame()
    t.eq(p.bOwnerNoSee, false, "waiting for the body to be drawn")
    g.frames(2)
    t.eq(p.bOwnerNoSee, true, "first person, once the body was drawn")
    t.eq(p[OPTION], 0, "kept animating")
    g.paused = false
    g.keys.W = true
    g.frames(90)
    t.truthy(footsteps(g, 60) > 50, "footsteps")
    t.absent(g.log, "Not keeping")
    noErrors(g)
end)

t.test("a body the game shows a few frames after its battle flag clears: the character's first start waits for it "
    .. "all the same", function()
    for late = 1, 3 do
        local what = "shown " .. late .. " frame(s) after the battle flag clears"
        local g = start()
        g.loadSave()
        local p = fake.props(g.c.mesh)
        g.inBattle = true
        p.bVisible = false -- hidden from the character's first frame: an area that opens with a battle
        g.frames(360)
        g.inBattle = false -- the game says the battle is over ...
        g.frames(late)
        t.eq(p.bOwnerNoSee, false, "not hidden yet, though the game still hides the body itself: " .. what)
        p.bVisible = true -- ... and shows the body a little later
        g.frames(3)
        t.eq(p.bOwnerNoSee, true, "first person, once the body was drawn: " .. what)
        t.eq(p[OPTION], 0, "kept animating: " .. what)
        g.keys.W = true
        g.frames(90)
        t.truthy(footsteps(g, 60) > 50, "footsteps: " .. what)
        t.absent(g.log, "Not keeping")
        noErrors(g)
    end
end)

t.test("a mesh the game never draws, though none of its own flags says so, isn't started; a character's first "
    .. "start waits five frames for it, once", function()
    local function firstPersonAfter(g)
        local p = fake.props(g.c.mesh)
        for frame = 1, 400 do
            g.frame()
            if p.bOwnerNoSee == true then
                return frame
            end
        end
        return nil
    end
    local plain = start()
    plain.loadSave()
    local usual = firstPersonAfter(plain)
    local g = start()
    local c = g.c
    local unseen = c.skeletal(function()
        return c.pawn
    end, { [OPTION] = 4 }, c.newAnimInstance(), { name = "UnseenBody" })
    local children = fake.props(c.mesh).AttachChildren
    children[#children + 1] = unseen
    fake.setUndrawn(unseen, true) -- for example a part of an actor the game hides
    g.loadSave()
    t.eq(firstPersonAfter(g), usual + 5, "five frames later than without it")
    t.eq(count(g.log, "hasn't drawn your character's body yet"), 1, "said once")
    t.eq(fake.props(unseen).bOwnerNoSee, true, "hidden with the rest")
    t.eq(fake.props(unseen)[OPTION], 4, "left alone: it never animated")
    t.falsy(fake.writes(unseen)[OPTION])
    t.eq(fake.props(c.mesh)[OPTION], 0, "the body the game draws is kept animating")
    t.contains(g.log, "Not keeping UnseenBody (SkeletalMeshComponent) animating")
    g.keys.W = true
    g.frames(90)
    local steps = footsteps(g, 60)
    t.truthy(steps > 50 and steps < 90, "one mesh plays the footsteps, not two: " .. steps)
    g.keys.W = false
    -- First person starting again for this character doesn't wait again.
    g.press(F6)
    g.frames(12)
    g.press(F6)
    t.eq(fake.props(c.mesh).bOwnerNoSee, true, "first person again at once")
    t.eq(count(g.log, "hasn't drawn your character's body yet"), 1, "no second wait")
    noErrors(g)
end)

-- A skinned mesh on the character that the game never draws (a part of an actor it
-- hides, say): with anim, one with an animation of its own.
local function undrawnMesh(g, anim, option)
    local c = g.c
    local mesh = c.skeletal(function()
        return c.pawn
    end, { [OPTION] = option or 4 }, anim and c.newAnimInstance() or nil, { name = "UnseenBody" })
    local children = fake.props(c.mesh).AttachChildren
    children[#children + 1] = mesh
    fake.setUndrawn(mesh, true)
    return mesh
end

t.test("the wait for a body to be drawn starts again for the next character, in the same level and in a new one",
    function()
    for _, newLevel in ipairs({ false, true }) do
        local what = newLevel and "a new level" or "the same level"
        -- A first character whose first start uses the whole wait up: it carries a
        -- mesh the game never draws.
        local g = start()
        local c = g.c
        undrawnMesh(g, true)
        g.loadSave()
        g.frames(SETTLE_FRAMES + 10)
        t.eq(count(g.log, "hasn't drawn your character's body yet"), 1, what .. ": the first character waited")
        t.eq(fake.props(c.mesh).bOwnerNoSee, true, what .. ": and started, after the whole wait")
        -- The next character's body is hidden from its first frame, and the game shows it
        -- at the end of the first frame the mod may act on that character.
        local b = g.buildCharacter()
        local p = fake.props(b.mesh)
        p.bVisible = false
        if newLevel then
            local world = fake.object({ className = "World", name = "Level_Other",
                path = "/Game/Levels/Other.Level_Other" })
            fake.setWorld(b.pawn, world)
            fake.setWorld(g.pc, world)
        end
        g.useCharacter(b)
        local frames = 0
        repeat
            g.frame()
            frames = frames + 1
        until cameraStatus().state ~= "off" or frames > 400
        p.bVisible = true
        t.eq(cameraStatus().waiting, "body", what .. ": its first start waits for the body too")
        g.frames(5)
        t.eq(p.bOwnerNoSee, true, what .. ": first person, once the body was drawn")
        t.eq(p[OPTION], 0, what .. ": kept animating")
        t.eq(count(g.log, "hasn't drawn your character's body yet"), 2, what .. ": said again")
        g.keys.W = true
        g.frames(90)
        t.truthy(footsteps(g, 60) > 50, what .. ": footsteps")
        t.eq(count(g.log, "Not keeping"), 1, what .. ": only the first character's mesh the game never draws")
        noErrors(g)
    end
end)

t.test("only a mesh the mod would keep animating holds up a first start, and only with HideBody and BodySounds on",
    function()
        local function firstPersonAfter(config, add)
            local g = start(config)
            if add then
                add(g)
            end
            g.loadSave()
            for frame = 1, 400 do
                g.frame()
                if cameraStatus().active then
                    return frame, g
                end
            end
            return nil, g
        end
        for _, case in ipairs({
            { "a mesh that follows another's pose", nil, function(g) undrawnMesh(g, false) end },
            { "a mesh whose option animates it unseen", nil, function(g) undrawnMesh(g, true, 1) end },
            { "BodySounds off", { BodySounds = false }, function(g) undrawnMesh(g, true) end },
            { "HideBody off", { HideBody = false }, function(g) undrawnMesh(g, true) end },
        }) do
            local usual = firstPersonAfter(case[2])
            local frame, g = firstPersonAfter(case[2], case[3])
            t.truthy(usual, "first person starts: " .. case[1])
            t.eq(frame, usual, "on the usual frame: " .. case[1])
            t.absent(g.log, "hasn't drawn your character's body yet", "no wait: " .. case[1])
            noErrors(g)
        end
    end)

t.test("without the world's clock, a body drawn in the last second counts as drawn, as before", function()
    local g = start()
    g.clock = "error" -- GetTimeSeconds fails
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    local p = fake.props(g.c.mesh)
    t.eq(p[OPTION], 0, "drawn until the mod hid it")
    g.keys.W = true
    g.frames(120)
    g.press(F7)
    t.eq(p[OPTION], 0, "starting again: remembered")
    t.truthy(footsteps(g, 60) > 50, "footsteps")
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
        untilPass(g)
        t.eq(fake.props(body).bOwnerNoSee, false, "not touched on the pass it first appears")
        t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "the old body's option is forgotten")
        t.falsy(fake.writes(body)[OPTION], "and not put on the new one")
        untilPass(g)
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

t.test("a mesh the game made hidden from its owner, at the address of a body the mod hides, keeps its own option "
    .. "on every pass", function()
    -- The full names are compared on every 4th pass (and at once for a part that reads as
    -- shown), so the swap is tried before each of four passes in a row. old: the old
    -- body's option (4: the mod kept it animating; 1: it animated unseen anyway).
    for _, case in ipairs({ { old = 4, anim = true }, { old = 4, anim = false }, { old = 1, anim = true } }) do
        for wait = 0, 3 do
            local what = string.format("old option %d, an animation of its own: %s, %d passes before the swap",
                case.old, tostring(case.anim), wait)
            local g = running(nil, { bodyTickOption = case.old })
            local c = g.c
            g.frames(30 * wait)
            local body = c.skeletal(function()
                return c.pawn
            end, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }), [OPTION] = 4, bOwnerNoSee = true },
                case.anim and c.newAnimInstance() or nil, { name = "NewBody", address = fake.addressOf(c.mesh) })
            fake.reuseAddress(c.mesh, body)
            fake.set(c.capsule, "AttachChildren", fake.array({ body, c.springArm }))
            g.frames(31)
            t.falsy(fake.writes(body)[OPTION], "untouched on the first pass: " .. what)
            g.frames(150) -- five more passes, at least one of them with the names
            t.eq(fake.props(body)[OPTION], 4, what)
            t.falsy(fake.writes(body)[OPTION], "untouched: " .. what)
            t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing to put back: " .. what)
            t.absent(g.log, "The game set", "not taken for an option the game wrote")
            t.absent(g.log, "Not keeping NewBody", "the game hides it: nothing to say")
            g.press(F6)
            t.falsy(fake.writes(body)[OPTION], "untouched as first person ends: " .. what)
            t.eq(fake.props(body).bOwnerNoSee, true, "still hidden from its owner, as the game made it")
            noErrors(g)
        end
    end
end)

t.test("the same for an attached actor's mesh: one the game made hidden in game, at its address, keeps its option",
    function()
        for wait = 0, 3 do
            local g = start()
            local c = g.c
            local weapon = c.skeletal(function()
                return c.propActor
            end, { [OPTION] = 4 }, c.newAnimInstance(), { name = "WeaponMesh" })
            local children = fake.props(c.mesh).AttachChildren
            children[#children + 1] = weapon
            g.loadSave()
            g.frames(SETTLE_FRAMES + 30 * wait)
            t.eq(fake.props(weapon)[OPTION], 0, "the weapon the game shows is kept animating")
            local put = c.skeletal(function()
                return c.propActor
            end, { [OPTION] = 4, bHiddenInGame = true }, c.newAnimInstance(),
                { name = "PutAwayWeaponMesh", address = fake.addressOf(weapon) })
            fake.reuseAddress(weapon, put)
            children[#children] = put
            g.frames(181)
            t.eq(fake.props(put)[OPTION], 4, wait .. " passes before the swap")
            t.falsy(fake.writes(put)[OPTION], "untouched")
            g.press(F6)
            t.falsy(fake.writes(put)[OPTION], "untouched as first person ends")
            t.eq(fake.props(put).bHiddenInGame, true, "still hidden in game, as the game made it")
            t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing left to put back")
            noErrors(g)
        end
    end)

t.test("another mesh at a kept body's address, which the game made invisible, keeps its option, and the old body is "
    .. "let go on that pass", function()
    -- As above, the swap before each of four passes in a row; on the passes that don't
    -- compare the names, the kept body's own check finds the new mesh.
    for wait = 0, 3 do
        local what = wait .. " passes before the swap"
        local g = running()
        local c = g.c
        local oldName = c.mesh:GetFullName()
        g.frames(30 * wait)
        t.eq(fake.props(c.mesh)[OPTION], 0, "the old body is kept animating: " .. what)
        local body = c.skeletal(function()
            return c.pawn
        end, { AttachChildren = fake.array({ c.skinMesh, c.propMesh }), [OPTION] = 0, bOwnerNoSee = true,
            bVisible = false }, c.newAnimInstance(), { name = "OtherBody", address = fake.addressOf(c.mesh) })
        fake.reuseAddress(c.mesh, body)
        fake.set(c.capsule, "AttachChildren", fake.array({ body, c.springArm }))
        g.frames(31)
        t.falsy(fake.writes(body)[OPTION], "the old body's option isn't put on it: " .. what)
        t.falsy(g.shared[JOURNAL]:find(oldName, 1, true), "the old body is let go on that pass: " .. what)
        g.frames(150)
        g.press(F6)
        t.falsy(fake.writes(body)[OPTION], "untouched as first person ends: " .. what)
        t.eq(fake.props(body).bOwnerNoSee, true, "still hidden from its owner, as the game made it: " .. what)
        noErrors(g)
    end
end)

-- The game moving a part to another actor (fake.move): the same object at the same
-- address, with its class and own name, under another path. Returns the part's
-- path on the character and its own name.
local LEVEL = "/Game/Levels/Fake.Fake:PersistentLevel."

local function pathOf(part)
    local path = part:GetFullName():match("^%S+ (.+)$")
    return path, path:match("[^.:]+$")
end

t.test("a body the game moves to another actor (a skin put away) is put back as it leaves; back, F6 shows it",
    function()
        local g = running()
        local c = g.c
        local p = fake.props(c.mesh)
        local home, own = pathOf(c.mesh)
        t.eq(p.bOwnerNoSee, true, "hidden")
        t.eq(p[OPTION], 0, "kept animating")
        -- Put away: off the character, and inside its skin actor.
        fake.move(c.mesh, LEVEL .. "BP_CharacterSkin_C_1." .. own)
        fake.set(c.capsule, "AttachChildren", fake.array({ c.springArm }))
        g.frames(31)
        t.eq(p.bOwnerNoSee, false, "shown again as it leaves: nobody else would")
        t.eq(p[OPTION], 4, "and its option is back")
        t.eq(fake.writes(c.mesh)[OPTION], 2, "set once, put back once")
        t.falsy(g.shared[JOURNAL]:find(own, 1, true), "nothing of it left to put back")
        t.eq(count(g.log, "The game moved a part the mod had hidden"), 1)
        -- Back in the character: hidden and kept animating as any new part.
        fake.move(c.mesh, home)
        fake.set(c.capsule, "AttachChildren", fake.array({ c.mesh, c.springArm }))
        g.keys.W = true
        g.frames(70)
        t.eq(p.bOwnerNoSee, true, "hidden again")
        t.eq(p[OPTION], 0, "kept animating again")
        t.truthy(footsteps(g, 60) > 50, "footsteps go on")
        g.press(F6)
        t.eq(p.bOwnerNoSee, false, "third person: the character shows")
        t.eq(p[OPTION], 4)
        g.press(F5)
        t.eq(p.bOwnerNoSee, false)
        t.eq(g.shared[JOURNAL], "", "nothing left to put back")
        t.absent(g.log, "can't tell whether")
        noErrors(g)
    end)

t.test("the report counts every hidden part the game moved to another actor, past the log's 3 lines", function()
    local g = start()
    local c = g.c
    local children = fake.props(c.capsule).AttachChildren
    local skin = {}
    for i = 1, 4 do
        skin[i] = c.skeletal(function()
            return c.pawn
        end, nil, nil, { name = "SkinPart" .. i })
        children[#children + 1] = skin[i]
    end
    g.loadSave()
    g.frames(SETTLE_FRAMES)
    t.contains(reportNow(g), "hidden parts the game moved to another actor this session=0")
    -- The game takes the whole skin off the character, into another actor, and puts it
    -- back: twice (an outfit changed, and changed back).
    for _ = 1, 2 do
        local homes = {}
        for i, part in ipairs(skin) do
            t.eq(fake.props(part).bOwnerNoSee, true, "hidden")
            local home, own = pathOf(part)
            homes[i] = home
            fake.move(part, LEVEL .. "BP_CharacterSkin_C_1." .. own)
            for j = #children, 1, -1 do
                if fake.addressOf(children[j]) == fake.addressOf(part) then
                    table.remove(children, j)
                end
            end
        end
        g.frames(31)
        for i, part in ipairs(skin) do
            t.eq(fake.props(part).bOwnerNoSee, false, "put back as it leaves")
            fake.move(part, homes[i])
            children[#children + 1] = part
        end
        g.frames(70) -- hidden again as new parts
    end
    t.eq(count(g.log, "The game moved a part the mod had hidden"), 3, "3 lines a session")
    t.eq(cameraStatus().partsMoved, 8)
    t.contains(reportNow(g), "hidden parts the game moved to another actor this session=8")
    noErrors(g)
end)

t.test("the game moving the body to another actor as a battle starts: first person ends with it shown", function()
    local g = running()
    local c = g.c
    local p = fake.props(c.mesh)
    local home, own = pathOf(c.mesh)
    g.inBattle = true -- and, before the mod's next frame:
    fake.move(c.mesh, LEVEL .. "BP_BattleCharacter_C_1." .. own)
    fake.set(c.capsule, "AttachChildren", fake.array({ c.springArm }))
    g.frame()
    t.eq(p.bOwnerNoSee, false, "first person ended: shown")
    t.eq(p[OPTION], 4)
    t.falsy(g.shared[JOURNAL]:find(own, 1, true), "nothing of it left to put back")
    g.frames(120)
    g.inBattle = false
    fake.move(c.mesh, home)
    fake.set(c.capsule, "AttachChildren", fake.array({ c.mesh, c.springArm }))
    g.keys.W = true
    g.frames(70)
    t.eq(p.bOwnerNoSee, true, "first person again")
    t.eq(p[OPTION], 0, "kept animating: not taken for hidden by the game")
    g.press(F6)
    t.eq(p.bOwnerNoSee, false, "third person: the character shows")
    t.eq(p[OPTION], 4)
    noErrors(g)
end)

t.test("a hidden body whose full name changes while it stays on the character is put back, then hidden as new",
    function()
        local g = running()
        local c = g.c
        local p = fake.props(c.mesh)
        local _, own = pathOf(c.mesh)
        fake.move(c.mesh, LEVEL .. "BP_jRPG_Character_World_C_1." .. own)
        local shown = false
        g.frames(31 * 6, nil, function() -- full names are compared on every 4th pass
            shown = shown or p.bOwnerNoSee == false
        end)
        t.truthy(shown, "put back first")
        t.eq(p.bOwnerNoSee, true, "hidden again")
        t.eq(p[OPTION], 0, "kept animating again")
        t.truthy(g.shared[JOURNAL]:find("BP_jRPG_Character_World_C_1." .. own .. "\towner\tb0", 1, true),
            "noted under its new name, as shown before")
        g.press(F6)
        t.eq(p.bOwnerNoSee, false, "third person: the character shows")
        t.eq(p[OPTION], 4)
        t.eq(fake.writes(c.mesh)[OPTION], 4, "set and put back twice")
        noErrors(g)
    end)

t.test("a kept body the game moves while it stays on the character, and hides itself, gets its option back on "
    .. "every pass", function()
    -- The full names are compared on every 4th pass, so the move is tried before each of
    -- four passes in a row.
    for _, hide in ipairs({ { flag = "bVisible", value = false }, { flag = "bHiddenInGame", value = true } }) do
        for wait = 0, 3 do
            local what = string.format("%s, %d pass(es) before the move", hide.flag, wait)
            local g = running()
            local c = g.c
            local p = fake.props(c.mesh)
            local _, own = pathOf(c.mesh)
            g.frames(30 * wait)
            t.eq(p[OPTION], 0, "kept animating: " .. what)
            fake.move(c.mesh, LEVEL .. "BP_CharacterSkin_C_1." .. own)
            p[hide.flag] = hide.value
            g.frames(31)
            t.eq(p[OPTION], 4, "the game hides it: its own option is back: " .. what)
            t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), "nothing of the option left to put back: " .. what)
            t.eq(count(g.log, "The game moved a part the mod had hidden"), 1, what)
            g.frames(31 * 5)
            t.eq(p[OPTION], 4, "and it stays the game's: " .. what)
            g.press(F6)
            t.eq(p.bOwnerNoSee, false, "third person: " .. what)
            t.eq(p[OPTION], 4, "after F6: " .. what)
            g.press(F5)
            t.eq(g.shared[JOURNAL], "", "nothing left to put back: " .. what)
            noErrors(g)
        end
    end
end)

t.test("an object at a hidden part's address that may not be that part is left as it is, with one warning",
    function()
        local chain = { "StaticMeshComponent", "MeshComponent", "PrimitiveComponent", "SceneComponent",
            "ActorComponent", "Object" }
        -- Another object at the body's address, off the character, hidden from its owner.
        for _, case in ipairs({ { what = "another own name", name = "Other" }, { what = "another class", class = true },
            { what = "one that reads as shown", shown = true } }) do
            local g = running()
            local c = g.c
            local _, own = pathOf(c.mesh)
            local name = case.name or own
            local props = { bOwnerNoSee = not case.shown, [OPTION] = 0 }
            local calls = 0
            local other
            if case.class then
                other = fake.object({ className = "StaticMeshComponent", name = name, chain = chain, props = props,
                    address = fake.addressOf(c.mesh), path = LEVEL .. "Elsewhere." .. name, methods = {
                        SetOwnerNoSee = fake.ufunction("SetOwnerNoSee", 1, function()
                            calls = calls + 1
                        end) } })
            else
                other = c.skeletal(function()
                    return c.skinActor
                end, props, nil, { name = name, address = fake.addressOf(c.mesh) })
                fake.move(other, LEVEL .. "Elsewhere." .. name)
                fake.method(other, "SetOwnerNoSee", fake.ufunction("SetOwnerNoSee", 1, function()
                    calls = calls + 1
                end))
            end
            fake.destroy(c.mesh)
            fake.reuseAddress(c.mesh, other)
            fake.set(c.capsule, "AttachChildren", fake.array({ c.springArm }))
            g.frames(31)
            t.eq(calls, 0, case.what .. ": its flag isn't touched")
            t.eq(props[OPTION], 0, case.what .. ": its option is its own")
            t.falsy(fake.writes(other)[OPTION], case.what .. ": not written")
            t.falsy(g.shared[JOURNAL]:find(OPTION, 1, true), case.what .. ": the old body's line is forgotten")
            t.absent(g.log, "The game moved a part")
            t.eq(count(g.log, "can't tell whether it is the same part"), case.shown and 0 or 1,
                case.what .. ": a warning only if it is hidden the way the mod hid the body")
            noErrors(g)
        end
        -- A part the mod hides in game (of an actor the character doesn't own), moved: not judged.
        local g = running()
        local c = g.c
        local p = fake.props(c.propMesh)
        local _, own = pathOf(c.propMesh)
        t.eq(p.bHiddenInGame, true, "hidden in game")
        p.bOwnerNoSee = true -- and hidden from its owner by the game itself
        fake.move(c.propMesh, LEVEL .. "Pool_C_1." .. own)
        fake.set(c.mesh, "AttachChildren", fake.array({ c.skinMesh }))
        g.frames(31)
        t.eq(p.bHiddenInGame, true, "left as it is")
        t.absent(g.log, "The game moved a part")
        t.eq(count(g.log, "can't tell whether it is the same part"), 1)
        noErrors(g)
        -- A body the game itself hid from the player before the mod did, moved: nothing to say.
        g = start()
        g.loadSave()
        p = fake.props(g.c.mesh)
        p.bOwnerNoSee = true
        g.frames(SETTLE_FRAMES)
        _, own = pathOf(g.c.mesh)
        fake.move(g.c.mesh, LEVEL .. "BP_CharacterSkin_C_1." .. own)
        fake.set(g.c.capsule, "AttachChildren", fake.array({ g.c.springArm }))
        g.frames(31)
        t.eq(p.bOwnerNoSee, true, "the game's own flag stays")
        t.absent(g.log, "The game moved a part")
        t.absent(g.log, "can't tell whether")
        noErrors(g)
    end)

-- A new skin attached to the character while its body is still the skin actor's, an
-- actor the character doesn't own (a ChildActorComponent's has none): the mod hides
-- the body in game. Then the game moves the body into the character (the swap).
t.test("a skin's body hidden in game while still its skin actor's, then moved into the character, is put back",
    function()
        for _, when in ipairs({ "on a pass", "as first person ends" }) do
            local g = running()
            local c = g.c
            local skin = fake.object({ className = "BP_CharacterSkin_New_C", name = "BP_CharacterSkin_New_C_7",
                chain = { "BP_CharacterSkin_New_C", "Actor", "Object" },
                methods = { GetOwner = fake.ufunction("GetOwner", 0, function()
                    return fake.INVALID
                end) } })
            local owner = skin
            local body = c.skeletal(function()
                return owner
            end, { [OPTION] = 4 }, c.newAnimInstance(), { name = "Body" })
            fake.move(body, LEVEL .. "BP_CharacterSkin_New_C_7.Body")
            local skinRoot = fake.object({ className = "SceneComponent", name = "DefaultSceneRoot",
                chain = { "SceneComponent", "ActorComponent", "Object" },
                props = { AttachChildren = fake.array({ body }) } })
            fake.set(c.capsule, "AttachChildren", fake.array({ c.mesh, c.springArm, skinRoot }))
            g.frames(70) -- two passes
            local p = fake.props(body)
            t.eq(p.bHiddenInGame, true, when .. ": hidden in game while it is the skin actor's")
            t.eq(p[OPTION], 0, when .. ": kept animating")
            -- The swap: the same object, now the character's own, on the character.
            owner = c.pawn
            fake.move(body, LEVEL .. "BP_jRPG_Character_World_C_1.Body")
            fake.set(skinRoot, "AttachChildren", fake.array({}))
            fake.set(c.capsule, "AttachChildren", fake.array({ c.mesh, c.springArm, body }))
            g.keys.W = true
            if when == "on a pass" then
                g.frames(31 * 6) -- full names are compared on every 4th pass
                t.eq(p.bHiddenInGame, false, when .. ": put back")
                t.eq(p.bOwnerNoSee, true, when .. ": hidden again, as the character's own")
                t.eq(p[OPTION], 0, when .. ": kept animating again")
                g.press(F6)
            else
                g.inBattle = true
                g.frame()
            end
            t.eq(p.bHiddenInGame, false, when .. ": shown in third person")
            t.eq(p.bOwnerNoSee, false, when .. ": shown in third person, to the player too")
            t.eq(p[OPTION], 4, when .. ": its own option")
            t.eq(count(g.log, "The game moved a part the mod had hidden"), 1, when)
            t.absent(g.log, "can't tell whether", when)
            g.inBattle = false
            g.press(F5)
            t.eq(p.bHiddenInGame, false, when .. ": the mod off")
            t.eq(g.shared[JOURNAL], "", when .. ": nothing left to put back")
            noErrors(g)
        end
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
    local report = reportNow(g)
    t.contains(report, "hidden parts=")
    t.contains(report, "(kept animating 1)")
    t.contains(report, "Character.Mesh = ")
    t.contains(report, "Skinned meshes on the character (BodySounds=true):")
    t.contains(report, "tick option 0 (AlwaysTickPoseAndRefreshBones) [kept animating by the mod, was 4 "
        .. "(OnlyTickPoseWhenRendered)], seen recently=false")
    t.contains(report, "anim instance ALS_UE5_AnimBP_C")
    t.contains(report, "bVisible=")
    local line = t.contains(report, "ALS animation: Speed=")
    local speed, moving = line:match("Speed=([%d%.]+), .-moving at (%d+) cm/s")
    t.truthy(speed and moving, line)
    t.near(tonumber(speed), tonumber(moving), 20, "ALS's copy follows the speed: the graph runs")
    t.truthy(tonumber(moving) > 500, line)
    t.contains(report, "end of diagnostics")
    noErrors(g)
end)

t.test("the report also lists the skinned meshes of actors attached to the character, kept animating or not",
    function()
        local g = start()
        local c = g.c
        -- A weapon on an attached actor (not the character's own component, so the mod hides
        -- it in game), whose mesh runs an animation of its own.
        local weapon = c.skeletal(function()
            return c.propActor
        end, { [OPTION] = 4 }, c.newAnimInstance(), { name = "WeaponMesh" })
        local children = fake.props(c.mesh).AttachChildren
        children[#children + 1] = weapon
        g.loadSave()
        g.frames(SETTLE_FRAMES)
        g.keys.W = true
        g.frames(90)
        t.eq(fake.props(weapon).bHiddenInGame, true, "hidden in game")
        t.eq(fake.props(weapon)[OPTION], 0, "kept animating")
        local report = reportNow(g)
        t.contains(report, "(kept animating 2)")
        t.contains(report, "Skinned meshes on the character (BodySounds=true):")
        t.contains(report, "Skinned meshes of actors attached to the character:")
        local line = t.contains(report, "WeaponMesh (SkeletalMeshComponent), owner BP_Torch_C")
        t.truthy(line:find("tick option 0 (AlwaysTickPoseAndRefreshBones) [kept animating by the mod, was 4 "
            .. "(OnlyTickPoseWhenRendered)]", 1, true), line)
        t.truthy(line:find("bHiddenInGame=true", 1, true), line)
        t.eq(count(report, "[kept animating by the mod"), 2, "as many lines say so as the count")
        -- The skin's mesh follows the body's pose: listed too, and not kept animating.
        line = t.contains(report, "owner BP_CharacterSkinBase_C")
        t.truthy(line:find("anim instance nothing", 1, true), line)
        t.falsy(line:find("kept animating", 1, true), line)
        t.eq(count(report, ": tick option "), 3, "each skinned mesh once")
        -- In third person the list is the same, with the game's own values.
        g.press(F6)
        report = reportNow(g)
        t.contains(report, "(kept animating 0)")
        line = t.contains(report, "WeaponMesh (SkeletalMeshComponent), owner BP_Torch_C")
        t.truthy(line:find("tick option 4 (OnlyTickPoseWhenRendered), seen recently=", 1, true), line)
        t.eq(count(report, ": tick option "), 3)
        noErrors(g)
    end)

t.test("the report says so when no attached actor has a skinned mesh", function()
    local g = start()
    local c = g.c
    fake.set(c.mesh, "AttachChildren", fake.array({ c.propMesh })) -- no skin actor's mesh
    g.loadSave()
    g.frames(SETTLE_FRAMES + 30)
    local report = reportNow(g)
    t.contains(report, "Skinned meshes of actors attached to the character: none")
    t.eq(count(report, ": tick option "), 1, "the body")
    noErrors(g)
end)

-- What the docs say about the jump sound rests on this: a sound (or an animation with a
-- notify) the game ties to its own jump isn't started by the mod's hops, in any view.
t.test("the mod's hops aren't the game's own jump, in first or third person; with the mod off, the game jumps",
    function()
        local g = running()
        g.keys.W = true
        g.frames(60)
        g.keys.SpaceBar = true
        g.frames(240)
        t.truthy(g.landings >= 3, "hopped in first person: " .. g.landings)
        t.eq(g.gameJumps, 0, "none of the hops was the game's own jump")
        g.press(F6)
        local landings = g.landings
        g.frames(240)
        t.truthy(g.landings - landings >= 3, "hopped in third person")
        t.eq(g.gameJumps, 0, "nor in third person")
        g.keys.SpaceBar = false
        g.frames(120)
        t.eq(g.mode(), 1, "on the ground again")
        -- docs/TESTING.md compares the hops with the game's own jump: F5, then jump.
        g.press(F5)
        g.keys.SpaceBar = true
        g.frames(5)
        g.keys.SpaceBar = false
        t.eq(g.gameJumps, 1, "with the mod switched off, the jump is the game's own")
        noErrors(g)
    end)
