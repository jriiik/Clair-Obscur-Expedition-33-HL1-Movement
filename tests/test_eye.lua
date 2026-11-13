-- First person's eye with Half-Life's duck (camera.applyEye): written after the movement
-- step, the standing eye kept for the character, CrouchedEyeHeight with the engine's
-- view, the game's camera leading a crouch that keeps the feet, and the adopt rule.
--
-- main.lua runs in the fake game with Movement = false, and the camera gets made-up
-- `info` tables of the shape movement.eyeInfo gives (see `heights`), as the movement
-- hands it after its step: these tests don't depend on the movement's ducking. A
-- main.lua with the eye step calls camera.applyEye with movement.eyeInfo, which the
-- tests replace; for one without it (before 0.4.0) the frame hook is wrapped to call it
-- after main.lua's hook, on the frames first person is on, as the eye step does. Both
-- go through the module tables, so main.lua must call them there, not through locals
-- taken at load. A small model of Unreal's crouch (`hullModel`) stands in for the
-- game's hull; the games take no extension modules (tests/fake_hull.lua isn't used).

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F7 = 0x74, 0x75, 0x76
local JOURNAL = "HL1Movement.changes"
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local S = 2.5 -- UnitScale: cm per unit
local STAND_HALF = 96 -- the fake capsule's half height, standing
local DELTA = 18 * S -- how much shorter Unreal's crouched capsule is (the mod's CrouchedHalfHeight): 45 cm
local E = 0.78 * STAND_HALF -- the standing eye: 74.88 cm above the middle of the standing capsule
local DUCKED = (12 - 28) * S -- the ducked eye against the standing one: -40 cm
local GAME_CROUCHED_EYE = 40 -- the fake character's own CrouchedEyeHeight (Unreal's default 32; E33's unknown)
local CLASS_EYE = 64 -- the BaseEyeHeight Unreal gives a character it stands up: its class's default
local DT = 1 / 80

-- Unreal's crouch as the game's hull makes it for the mod, at the start of its movement
-- update, after the frame hook (the fake's beforeMove point): the test says what the
-- mod asks for (want); Unreal changes the capsule's half height, keeping the feet
-- (keepFeet: on the ground, or in a frame the mod's flag keeps them as it leaves the
-- ground) or else the middle, and sets bIsCrouched and BaseEyeHeight (CrouchedEyeHeight
-- at a crouch, the class's default at a stand-up). Something low above (ceiling)
-- refuses a stand-up. standHalf and crouchAtStart are for the next character built. It
-- also notes what the frame hook left: the eye height and the game camera's height.
local function hullModel()
    local m = { want = false, ceiling = false, keepFeet = true, crouchAtStart = false, standHalf = STAND_HALF,
        halfReads = 0, crouches = 0, standUps = 0, chars = {} }
    function m.character(_, c)
        local s = { stand = m.standHalf, crouched = m.crouchAtStart }
        s.half = s.crouched and s.stand - DELTA or s.stand
        m.chars[c] = s
        fake.set(c.pawn, "bIsCrouched", s.crouched)
        fake.set(c.pawn, "CrouchedEyeHeight", GAME_CROUCHED_EYE)
        if s.crouched then
            fake.props(c.pawn).BaseEyeHeight = GAME_CROUCHED_EYE -- Unreal holds a crouched character's there
        end
        fake.method(c.capsule, "GetScaledCapsuleHalfHeight", fake.ufunction("GetScaledCapsuleHalfHeight", 0,
            function()
                m.halfReads = m.halfReads + 1
                return s.half
            end))
    end
    function m.heightOffset(_, c)
        local s = m.chars[c]
        return s and s.half - STAND_HALF or 0
    end
    function m.beforeMove(g)
        local s, p = m.chars[g.c], fake.props(g.pawn)
        m.eyeBeforeMove = p.BaseEyeHeight
        m.cameraBeforeMove = fake.props(g.c.cineCamera).RelativeLocation.Z
        if m.want and not s.crouched then
            s.crouched, s.half = true, s.stand - DELTA
            if not m.keepFeet then
                g.position.Z = g.position.Z + DELTA
            end
            p.bIsCrouched = true
            p.BaseEyeHeight = p.CrouchedEyeHeight
            m.crouches = m.crouches + 1
        elseif not m.want and s.crouched and not m.ceiling then
            s.crouched, s.half = false, s.stand
            if not m.keepFeet then
                g.position.Z = g.position.Z - DELTA
            end
            p.bIsCrouched = false
            p.BaseEyeHeight = CLASS_EYE
            m.standUps = m.standUps + 1
        end
    end
    return m
end

-- What the movement hands the camera at a hook (movement.eyeInfo, from duck.eyeOffset).
-- view: Half-Life's view height (units); drop: cm Half-Life's origin is below the
-- capsule's middle; crouched: the capsule reads crouched at the hook; ahead: Unreal
-- crouches the character keeping its feet in this frame, so the game's camera leads it.
-- Never above the ducked eye while the capsule reads crouched.
local function heights(view, drop, crouched, ahead, standHalf)
    local offset = (view - 28) * S - drop
    if crouched then
        offset = math.min(offset, DUCKED)
    end
    return { offset = offset, aheadOffset = ahead and (view - 28) * S or nil, crouched = crouched,
        standHalf = standHalf or STAND_HALF }
end
local STANDING = heights(28, 0, false)
local CROUCH_FRAME = heights(12, DELTA, false, true) -- the duck completes on the ground; Unreal crouches now
local DUCKED_CROUCHED = heights(12, 0, true)
local STAND_UP_FRAME = heights(28, -DELTA, true) -- the physics stood up; the capsule still reads crouched
local DUCKED_NO_HULL = heights(12, DELTA, false) -- fully ducked with the capsule standing (no hull change)
local TAP_FLIGHT = heights(28, -(DELTA - 37.93), false) -- a duck tap's flight: Half-Life's origin 7.07 cm higher

-- Half-Life's view height in the duck's transition, ms after the press (duck.curve):
-- 28 easing in and out to -6 at 400 ms (the ducked 12 less the 18 the origin hasn't
-- dropped yet).
local function curve(ms)
    local u = math.min(math.max(ms / 400, 0), 1)
    return 28 - 34 * (3 * u * u - 2 * u * u * u)
end

local function has(lines, text)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

-- A game with first person on, after the settle. config: config.lua's settings
-- (Movement = false unless given). options: crouched (the character starts crouched),
-- info (what the camera gets from the start), cameraStyleIgnored, plain (no wrapper:
-- camera.applyEye only if main.lua calls it), settle (frames, else SETTLE_FRAMES), each
-- (called after each frame of the settle). Returns the game and e: e.info (what the
-- camera gets), e.hull, e.camera, e.calls (main.lua's camera.applyEye calls), e.steps
-- (the eye steps, main.lua's or the wrapper's).
local function eyeGame(config, options)
    options = options or {}
    local hull = hullModel()
    hull.crouchAtStart, hull.want = options.crouched == true, options.crouched == true
    local g = fake.newGame({ noExtensionModules = true, extensions = { hull },
        cameraStyleIgnored = options.cameraStyleIgnored })
    local settings = { Movement = false }
    for name, value in pairs(config or {}) do
        settings[name] = value
    end
    fake.useConfig(settings)
    fake.loadMod(root)
    local e = { hull = hull, info = options.info, calls = 0, steps = 0 }
    local camera = require("hl1movement.camera")
    e.camera = camera
    require("hl1movement.movement").eyeInfo = function()
        return e.info
    end
    local apply, applyEye = camera.apply, camera.applyEye
    camera.apply = function(pc, pawn, pcm, cam, cfg, ...)
        e.pawn, e.cfg = pawn, cfg
        return apply(pc, pawn, pcm, cam, cfg, ...)
    end
    camera.applyEye = function(...)
        e.calls, e.steps = e.calls + 1, e.steps + 1
        return applyEye(...)
    end
    g.loadSave()
    local tick = assert(g.hooks[g.tickPath], "main.lua's frame hook")
    if not options.plain then
        g.hooks[g.tickPath] = function(...)
            local calls = e.calls
            tick(...)
            if e.calls == calls and camera.isActive() then
                e.steps = e.steps + 1
                applyEye(e.pawn, e.cfg, e.info) -- the eye step, for a main.lua that has none
            end
        end
    end
    for _ = 1, options.settle or SETTLE_FRAMES do
        g.frame()
        if options.each then
            options.each(g, e)
        end
    end
    t.truthy(camera.isActive(), "first person is on")
    return g, e
end

local function noErrors(g)
    t.absent(g.log, "Error in", "the mod logged an error")
    t.absent(g.log, "Turned off", "the mod turned something off")
end

-- One frame of dt (DT if nil) with info for the camera; gives back the capsule's middle
-- (Z) at the hook, where Half-Life's eye is info.offset above the standing eye.
local function frame(g, e, info, dt)
    e.info = info
    local at = g.actorLocation().Z
    g.frame(dt or DT)
    return at
end

-- Ducks on the ground at 80 fps: the 0.4 s transition (the capsule stands), then the
-- frame the duck completes, in which Unreal crouches the character keeping its feet.
-- each(what, k, at, info) after each frame, at: the capsule's middle at its hook.
local function duck(g, e, each)
    for k = 1, 31 do
        local info = heights(curve(k * 1000 * DT), 0, false)
        local at = frame(g, e, info)
        if each then
            each("transition", k, at, info)
        end
    end
    e.hull.want = true
    local at = frame(g, e, CROUCH_FRAME)
    if each then
        each("crouch", 32, at, CROUCH_FRAME)
    end
end

-- Frames of 1/60 s until the automatic report has come (it reads the capsule too).
local function afterReport(g, e)
    for _ = 1, 400 do
        if has(g.log, "diagnostics (automatic") then
            break
        end
        frame(g, e, e.info, 1 / 60)
    end
    t.contains(g.log, "diagnostics (automatic", "the automatic report came")
end

local function cine(g)
    return fake.props(g.c.cineCamera).RelativeLocation.Z
end

t.test("each frame of a duck on the ground the eye height is the standing eye plus Half-Life's view change, and "
    .. "with the engine's view the crouch leaves the eye where it was (Unreal makes the mod's CrouchedEyeHeight "
    .. "the eye height)", function()
    local g, e = eyeGame(nil, { info = STANDING })
    t.eq(g.style(), "FirstPerson", "the engine's view")
    t.near(fake.props(g.pawn).BaseEyeHeight, E, 1e-6, "standing")
    duck(g, e, function(what, k, at, info)
        local where = string.format("%s frame %d", what, k)
        t.near(e.hull.eyeBeforeMove, E + info.offset, 0.1, where .. ": the eye height the frame hook wrote")
        t.near(g.cameraLocation.Z, at + E + info.offset, what == "crouch" and 1 or 0.1, where .. ": the view")
    end)
    t.eq(e.hull.crouches, 1, "Unreal crouched the character")
    for k = 1, 160 do -- 2 s fully ducked: refreshes while the capsule reads crouched
        local at = frame(g, e, DUCKED_CROUCHED)
        t.near(g.cameraLocation.Z, at + E + DUCKED, 0.01, "ducked frame " .. k .. ": the ducked eye")
    end
    local p = fake.props(g.pawn)
    t.near(p.BaseEyeHeight, E + DUCKED, 0.01, "the ducked eye above the crouched capsule's middle")
    t.near(p.CrouchedEyeHeight, E + DUCKED, 0.01, "CrouchedEyeHeight is the ducked eye")
    local eye, from = e.camera.standingEye()
    t.near(eye, E, 1e-6, "the standing eye, read off the standing capsule, not the crouched one")
    t.eq(from, "the standing capsule")
    noErrors(g)
end)

t.test("the game's camera on the capsule has the same heights, and leads the crouch Unreal makes keeping the "
    .. "feet, so the crouch leaves the eye where it was; CrouchedEyeHeight is left alone", function()
    local g, e = eyeGame({ CameraMethod = "game" }, { info = STANDING })
    t.truthy(g.c.attach[g.c.cineCamera].parent == g.c.capsule, "the game's camera is on the capsule")
    t.near(cine(g), E, 0.5, "standing")
    duck(g, e, function(what, k, at, info)
        local where = string.format("%s frame %d", what, k)
        local height = what == "crouch" and E + info.aheadOffset or E + info.offset
        t.near(e.hull.cameraBeforeMove, height, 0.5, where .. ": the camera's height on the capsule")
        t.near(e.hull.eyeBeforeMove, E + info.offset, 0.1, where .. ": the eye height")
        t.near(g.cameraLocation.Z, at + E + info.offset, what == "crouch" and 1 or 0.5, where .. ": the view")
    end)
    for k = 1, 80 do
        local at = frame(g, e, DUCKED_CROUCHED)
        t.near(g.cameraLocation.Z, at + E + DUCKED, 0.5, "ducked frame " .. k)
    end
    t.near(cine(g), E + DUCKED, 0.5, "the ducked eye above the crouched capsule's middle")
    t.eq(fake.writes(g.pawn).CrouchedEyeHeight, nil, "CrouchedEyeHeight is only set with the engine's view")
    t.eq(fake.props(g.pawn).CrouchedEyeHeight, GAME_CROUCHED_EYE)
    noErrors(g)
end)

t.test("the frame a duck completes as the character jumps, with the mod's flag that keeps the feet: the eye "
    .. "stays where it was in the world, on both methods", function()
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = STANDING })
        for k = 1, 31 do
            frame(g, e, heights(curve(k * 1000 * DT), 0, false))
        end
        -- The mod's jump in this frame's hook: falling, and Unreal crouches keeping the feet.
        e.hull.want = true
        local v = fake.props(g.cmc).Velocity
        v.Z = 670
        g.changeMode(g.cmc, 3, g.pawn)
        local standingMiddle = g.position.Z
        frame(g, e, CROUCH_FRAME)
        t.eq(e.hull.crouches, 1, method .. ": crouched")
        t.truthy(g.position.Z > standingMiddle + 5, method .. ": in the air")
        -- Half-Life's eye rose with the jump: from where the standing middle is now.
        t.near(g.cameraLocation.Z, g.position.Z + E + CROUCH_FRAME.offset, 1, method .. ": the view")
        noErrors(g)
    end
end)

t.test("a stand-up isn't led: the eye stays at the ducked eye until Unreal has stood the character up, whose "
    .. "own eye height shows for that one frame (engine's view), or the ducked eye above the standing middle "
    .. "(game's camera)", function()
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = STANDING })
        duck(g, e)
        frame(g, e, DUCKED_CROUCHED)
        e.hull.want = false
        local at = frame(g, e, STAND_UP_FRAME)
        t.eq(e.hull.standUps, 1, method .. ": Unreal stood the character up")
        t.near(e.hull.eyeBeforeMove, E + DUCKED, 0.01, method .. ": the frame hook kept the ducked eye")
        local standingMiddle = at + DELTA
        if method == "engine" then
            t.near(g.cameraLocation.Z, standingMiddle + CLASS_EYE, 0.01, "engine: Unreal's eye height that frame")
        else
            t.near(g.cameraLocation.Z, standingMiddle + E + DUCKED, 0.5, "game: the ducked eye, once")
        end
        at = frame(g, e, STANDING)
        t.near(at, standingMiddle, 1e-6)
        t.near(g.cameraLocation.Z, at + E, 0.5, method .. ": the standing eye on the next frame")
        t.near(fake.props(g.pawn).BaseEyeHeight, E, 0.01)
        noErrors(g)
    end
end)

t.test("while the capsule reads crouched the eye never goes above the ducked eye, whatever the offset: a "
    .. "stand-up Unreal refuses under something low keeps the view down until there is room", function()
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = STANDING })
        duck(g, e)
        e.hull.ceiling, e.hull.want = true, false
        -- What a caller that left the clamp out would hand over: the stand-up's 45 cm up, or standing.
        local unclamped = { { offset = DELTA, crouched = true, standHalf = STAND_HALF },
            { offset = 0, crouched = true, standHalf = STAND_HALF } }
        for k = 1, 80 do
            local at = frame(g, e, unclamped[k % 2 + 1])
            local where = string.format("%s, frame %d under the ceiling", method, k)
            t.truthy(e.hull.eyeBeforeMove <= E + DUCKED + 0.01, where .. ": eye height " .. e.hull.eyeBeforeMove)
            t.truthy(g.cameraLocation.Z <= at + E + DUCKED + 0.5, where .. ": the view")
            if method == "game" then
                t.truthy(e.hull.cameraBeforeMove <= E + DUCKED + 0.5, where .. ": the camera's height")
            end
        end
        t.eq(e.hull.standUps, 0, "still crouched")
        e.hull.ceiling = false -- out from under it
        frame(g, e, { offset = DELTA, crouched = true, standHalf = STAND_HALF })
        t.eq(e.hull.standUps, 1, "Unreal found room")
        local at = frame(g, e, STANDING)
        t.near(g.cameraLocation.Z, at + E, 0.5, method .. ": standing up once out")
        noErrors(g)
    end
end)

t.test("the standing eye is read off the capsule only at first person's refreshes, and only while it stands",
    function()
        local g, e = eyeGame(nil, { info = STANDING })
        afterReport(g, e)
        local reads = e.hull.halfReads
        for _ = 1, 120 do
            frame(g, e, STANDING, 1 / 60)
        end
        local n = e.hull.halfReads - reads
        t.truthy(n >= 3 and n <= 5, n .. " readings in 2 s standing: one at each refresh, every 0.5 s")
        duck(g, e)
        reads = e.hull.halfReads
        for _ = 1, 160 do
            frame(g, e, DUCKED_CROUCHED)
        end
        t.eq(e.hull.halfReads, reads, "none while the capsule reads crouched")
        noErrors(g)
    end)

t.test("F6 off and on again while ducked, and F5, keep the standing eye: the ducked eye is still 16 units "
    .. "below it", function()
    local g, e = eyeGame(nil, { info = STANDING })
    duck(g, e)
    -- From now on the movement knows another standing half height, as if it were the class
    -- default's: an eye taken from it would show.
    local ducked = heights(12, 0, true, false, 90)
    for _ = 1, 20 do
        frame(g, e, ducked)
    end
    g.press(F6)
    t.falsy(e.camera.isActive(), "first person off")
    g.frames(10)
    g.press(F6)
    g.frames(10)
    t.truthy(e.camera.isActive(), "first person on again, the capsule crouched")
    t.near(fake.props(g.pawn).BaseEyeHeight, E + DUCKED, 0.01, "the ducked eye from the standing eye kept")
    local eye, from = e.camera.standingEye()
    t.near(eye, E, 1e-6)
    t.eq(from, "the standing capsule")
    g.press(F5)
    g.frames(5)
    g.press(F5)
    g.frames(10)
    t.truthy(e.camera.isActive(), "first person on again after F5")
    t.near(fake.props(g.pawn).BaseEyeHeight, E + DUCKED, 0.01, "after F5 too")
    noErrors(g)
end)

t.test("first person that starts with the character crouched takes the standing eye from the standing half "
    .. "height at once, not from the crouched character's eye height", function()
    local first -- the eye height the frame hook left on first person's first frame
    local function onFirstFrame(_, game)
        if first == nil and game.camera.isActive() then
            first = game.hull.eyeBeforeMove
        end
    end
    local g, e = eyeGame(nil, { crouched = true, info = DUCKED_CROUCHED, each = onFirstFrame })
    t.near(first, E + DUCKED, 0.01, "the ducked eye on the first frame")
    local eye, from = e.camera.standingEye()
    t.near(eye, E, 1e-6, "0.78 of the standing half height")
    t.eq(from, "the standing half height")
    t.near(fake.props(g.pawn).CrouchedEyeHeight, E + DUCKED, 0.01)
    -- Standing up: the capsule is read at the next refresh.
    e.hull.want = false
    frame(g, e, STAND_UP_FRAME)
    for _ = 1, 48 do -- 0.6 s
        frame(g, e, STANDING)
    end
    eye, from = e.camera.standingEye()
    t.near(eye, E, 1e-6)
    t.eq(from, "the standing capsule", "read off the capsule once it stood")
    t.near(fake.props(g.pawn).BaseEyeHeight, E, 0.01)
    noErrors(g)
end)

t.test("with nothing from the movement, the eye follows the game's hull: the ducked eye while the capsule reads "
    .. "crouched; a character crouched from the start with no standing eye known keeps the game's own", function()
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = nil })
        t.near(fake.props(g.pawn).BaseEyeHeight, E, 1e-6, method .. ": standing")
        e.hull.want = true -- the game crouches the character
        frame(g, e, nil)
        for _ = 1, 10 do
            frame(g, e, nil)
        end
        local at = frame(g, e, nil)
        t.near(fake.props(g.pawn).BaseEyeHeight, E + DUCKED, 0.01, method .. ": the ducked eye")
        t.near(g.cameraLocation.Z, at + E + DUCKED, 0.5, method .. ": the view")
        if method == "game" then
            t.near(cine(g), E + DUCKED, 0.5, "game: the camera's height")
        end
        noErrors(g)
    end
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { crouched = true, info = nil })
        local p = fake.props(g.pawn)
        t.eq(p.BaseEyeHeight, GAME_CROUCHED_EYE, method .. ": the game's crouched eye height stays")
        t.eq(fake.writes(g.pawn).BaseEyeHeight, nil, method .. ": not written")
        t.eq(fake.writes(g.pawn).CrouchedEyeHeight, nil, method .. ": nor CrouchedEyeHeight")
        t.eq(e.camera.standingEye(), nil, method .. ": no standing eye known")
        if method == "game" then
            t.near(cine(g), GAME_CROUCHED_EYE, 1e-6, "game: the camera at the game's own eye height")
        end
        -- The game stands the character up right after a refresh: until the next one reads the
        -- capsule, the standing eye is the game's eye height.
        local due = e.camera.nextRefresh()
        repeat
            frame(g, e, nil)
        until e.camera.nextRefresh() ~= due
        e.hull.want = false
        frame(g, e, nil)
        t.eq(e.hull.standUps, 1, method .. ": stood up")
        frame(g, e, nil)
        local eye, from = e.camera.standingEye()
        t.eq(eye, CLASS_EYE, method .. ": the standing eye before the capsule is read")
        t.eq(from, "the game's eye height", method)
        for _ = 1, 48 do
            frame(g, e, nil)
        end
        eye, from = e.camera.standingEye()
        t.near(eye, E, 1e-6, method)
        t.eq(from, "the standing capsule", method .. ": read off the capsule at the next refresh")
        t.near(p.BaseEyeHeight, E, 0.01, method)
        -- An offset that isn't a number counts as none.
        frame(g, e, { offset = 0 / 0, aheadOffset = 0 / 0, crouched = false, standHalf = STAND_HALF })
        t.near(p.BaseEyeHeight, E, 0.01, method .. ": a NaN offset")
        if method == "game" then
            t.near(cine(g), E, 0.5, "game: a NaN offset")
        end
        noErrors(g)
    end
end)

t.test("CrouchedEyeHeight is the ducked eye only while the engine's view runs: the game's own is back as soon "
    .. "as it stops (F6, and where auto moves on to the game's camera), and a value the game writes is the one "
    .. "put back", function()
    local g, e = eyeGame(nil, { info = STANDING })
    local p = fake.props(g.pawn)
    t.near(p.CrouchedEyeHeight, E + DUCKED, 0.01, "set standing too")
    p.CrouchedEyeHeight = 50 -- the game writes its own
    frame(g, e, STANDING)
    t.near(p.CrouchedEyeHeight, E + DUCKED, 0.01, "set again")
    g.press(F6)
    t.eq(p.CrouchedEyeHeight, 50, "the game's latest, at once")
    g.press(F6)
    g.frames(5)
    t.near(p.CrouchedEyeHeight, E + DUCKED, 0.01, "set again with first person")

    g, e = eyeGame(nil, { info = STANDING, cameraStyleIgnored = true })
    p = fake.props(g.pawn)
    t.near(p.CrouchedEyeHeight, E + DUCKED, 0.01, "set while auto tries the engine's view")
    local moved = false
    for _ = 1, 300 do
        frame(g, e, STANDING, 1 / 60)
        if has(g.log, "Moving the game's camera to the eyes instead") then
            moved = true
            break
        end
    end
    t.truthy(moved, "auto moved on to the game's camera")
    t.eq(p.CrouchedEyeHeight, GAME_CROUCHED_EYE, "the game's own back in the same frame")
    local writes = fake.writes(g.pawn).CrouchedEyeHeight
    duck(g, e)
    for _ = 1, 40 do
        frame(g, e, DUCKED_CROUCHED)
    end
    t.eq(fake.writes(g.pawn).CrouchedEyeHeight, writes, "not set again with the game's camera")
    t.near(cine(g), E + DUCKED, 0.5, "the game's camera has the ducked eye")
    noErrors(g)
end)

t.test("the adopt rule: released while crouched, under something low, the character gets its own crouched eye "
    .. "height back, not the mod's CrouchedEyeHeight that Unreal copied into it; after a stand-up, the class's",
    function()
        -- Released in the frame right after Unreal crouched it (F6), and by a battle later.
        for _, how in ipairs({ "F6 right after the crouch", "a battle, ducked" }) do
            local g, e = eyeGame(nil, { info = STANDING })
            duck(g, e)
            e.hull.ceiling = true
            e.info = DUCKED_CROUCHED
            if how == "F6 right after the crouch" then
                g.press(F6)
            else
                for _ = 1, 30 do
                    frame(g, e, DUCKED_CROUCHED)
                end
                g.inBattle = true
                g.frame(DT)
            end
            t.falsy(e.camera.isActive(), how .. ": first person off")
            local p = fake.props(g.pawn)
            t.eq(p.bIsCrouched, true, how .. ": still crouched")
            t.eq(p.BaseEyeHeight, GAME_CROUCHED_EYE, how .. ": the game's own crouched eye height")
            t.eq(p.CrouchedEyeHeight, GAME_CROUCHED_EYE, how .. ": its own CrouchedEyeHeight")
            noErrors(g)
        end
        -- A UE4SS mods restart while ducked: the journal has the game's crouched eye height.
        local g, e = eyeGame(nil, { info = STANDING })
        duck(g, e)
        e.hull.ceiling = true
        for _ = 1, 10 do
            frame(g, e, DUCKED_CROUCHED)
        end
        local line = "prop\t" .. g.pawn:GetFullName() .. "\tBaseEyeHeight\tn" .. GAME_CROUCHED_EYE
        local noted = false
        for each in (g.shared[JOURNAL] .. "\n"):gmatch("([^\n]*)\n") do
            noted = noted or each == line
        end
        t.truthy(noted, "the journal puts back the game's crouched eye height: " .. g.shared[JOURNAL])
        g.restartMods(root)
        g.frame(DT)
        t.eq(fake.props(g.pawn).BaseEyeHeight, GAME_CROUCHED_EYE, "put back by the new copy")
        t.eq(fake.props(g.pawn).CrouchedEyeHeight, GAME_CROUCHED_EYE)
        -- Crouched in the air (Unreal keeps the middle), where the mod had written the ducked
        -- eye before Unreal crouched: the same, once per crouch.
        g, e = eyeGame(nil, { info = STANDING })
        fake.props(g.cmc).Velocity.Z = 670
        g.changeMode(g.cmc, 3, g.pawn)
        frame(g, e, STANDING)
        e.hull.want, e.hull.keepFeet = true, false
        frame(g, e, heights(12, 0, false))
        t.eq(e.hull.crouches, 1, "crouched in the air")
        frame(g, e, DUCKED_CROUCHED)
        frame(g, e, DUCKED_CROUCHED)
        g.press(F6)
        t.eq(fake.props(g.pawn).BaseEyeHeight, GAME_CROUCHED_EYE, "crouched in the air: its own crouched eye")
        -- A value the game writes while crouched is the game's, though the mod's ducked eye
        -- is the mod's CrouchedEyeHeight too: later in the crouch, or right after Unreal's.
        for _, when in ipairs({ "later", "right after Unreal's" }) do
            g, e = eyeGame(nil, { info = STANDING })
            duck(g, e)
            e.hull.ceiling = true
            if when == "later" then
                for _ = 1, 10 do
                    frame(g, e, DUCKED_CROUCHED)
                end
            end
            fake.props(g.pawn).BaseEyeHeight = 50
            for _ = 1, 10 do
                frame(g, e, DUCKED_CROUCHED)
            end
            t.near(fake.props(g.pawn).BaseEyeHeight, E + DUCKED, 0.01, when .. ": the mod's ducked eye again")
            g.press(F6)
            t.eq(fake.props(g.pawn).BaseEyeHeight, 50, when .. ": the game's own, written while crouched")
        end
        -- Stood up: Unreal's class default is the game's.
        g, e = eyeGame(nil, { info = STANDING })
        duck(g, e)
        frame(g, e, DUCKED_CROUCHED)
        e.hull.want = false
        frame(g, e, STAND_UP_FRAME)
        for _ = 1, 5 do
            frame(g, e, STANDING)
        end
        e.info = STANDING
        g.press(F6)
        t.eq(fake.props(g.pawn).BaseEyeHeight, CLASS_EYE, "after a stand-up: Unreal's value is the game's")
        t.eq(fake.props(g.pawn).CrouchedEyeHeight, GAME_CROUCHED_EYE)
        noErrors(g)
    end)

t.test("the view check never fails through ducks, stand-ups, ducks without a hull change and duck taps, with "
    .. "either method", function()
    for _, method in ipairs({ "auto", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = STANDING })
        local wanted = e.camera.status().method
        for _ = 1, 3 do
            duck(g, e)
            for _ = 1, 80 do
                frame(g, e, DUCKED_CROUCHED)
            end
            e.hull.want = false
            frame(g, e, STAND_UP_FRAME)
            for _ = 1, 20 do
                frame(g, e, STANDING)
            end
            for _ = 1, 200 do -- 2.5 s ducked where the game makes no hull change
                frame(g, e, DUCKED_NO_HULL)
            end
            for _ = 1, 4 do -- duck taps: lifted 37.93 cm, a flight, a landing
                g.position.Z = g.position.Z + 37.93
                g.changeMode(g.cmc, 3, g.pawn)
                for _ = 1, 40 do
                    frame(g, e, g.mode() == 3 and TAP_FLIGHT or STANDING)
                end
            end
        end
        t.absent(g.log, "doesn't work here", method .. ": never given up")
        t.absent(g.log, "Moving the game's camera to the eyes instead", method .. ": the method kept")
        local status = e.camera.status()
        t.eq(status.method, wanted, method)
        t.eq(status.state, "working", method)
        noErrors(g)
    end
end)

t.test("once a caller writes the eye after the movement step, camera.apply writes none: one eye height write "
    .. "a frame; with none, camera.apply still writes it", function()
    for _, method in ipairs({ "engine", "game" }) do
        local g, e = eyeGame({ CameraMethod = method }, { info = STANDING })
        t.truthy(e.steps > 0, "the eye step ran")
        local writes = fake.writes(g.pawn)
        local reads = 0
        fake.onRead(g.pawn, "bIsCrouched", function()
            reads = reads + 1
        end)
        for k = 1, 31 do
            local before = writes.BaseEyeHeight
            frame(g, e, heights(curve(k * 1000 * DT), 0, false))
            t.eq(writes.BaseEyeHeight, before + 1, method .. ", transition frame " .. k .. ": one write")
        end
        -- The movement's info says whether the capsule reads crouched: read only at a refresh.
        t.truthy(reads <= 1, method .. ": bIsCrouched read " .. reads .. " times in 31 frames with the info")
        reads = 0
        for _ = 1, 31 do
            frame(g, e, nil)
        end
        t.truthy(reads >= 31, method .. ": read on every frame without it (" .. reads .. ")")
    end
    local g = eyeGame(nil, { plain = true })
    t.near(fake.props(g.pawn).BaseEyeHeight, E, 1e-6, "written by camera.apply, or main.lua's eye step")
    noErrors(g)
end)

t.test("camera.applyEye writes nothing while first person is off, nor for a character first person isn't on",
    function()
        local g, e = eyeGame(nil, { info = STANDING })
        local other = g.buildCharacter()
        e.camera.applyEye(other.pawn, e.cfg, DUCKED_CROUCHED)
        t.eq(fake.writes(other.pawn).BaseEyeHeight, nil, "another character's eye height")
        g.press(F6)
        t.falsy(e.camera.isActive(), "first person off")
        local p = fake.props(g.pawn)
        t.eq(p.BaseEyeHeight, CLASS_EYE, "the game's eye height is back")
        e.camera.applyEye(g.pawn, e.cfg, DUCKED_CROUCHED)
        t.eq(p.BaseEyeHeight, CLASS_EYE, "not written with first person off: nothing would put it back")
        t.eq(p.CrouchedEyeHeight, GAME_CROUCHED_EYE)
        local eye, from = e.camera.standingEye()
        e.camera.applyEye(nil, e.cfg, heights(12, 0, true, false, 90))
        t.eq(select(1, e.camera.standingEye()), eye, "no character: nothing worked out")
        t.eq(select(2, e.camera.standingEye()), from)
        noErrors(g)
    end)

t.test("the eye heights' full names are checked at first person's refreshes: another object at the character's "
    .. "address is a new one for them, and the journal names it", function()
    local g, e = eyeGame(nil, { info = STANDING })
    local old = g.pawn:GetFullName()
    fake.move(g.pawn, "/Game/Levels/Fake.Fake:PersistentLevel.BP_jRPG_Character_World_C_Moved")
    local new = g.pawn:GetFullName()
    for _ = 1, 48 do -- 0.6 s: a refresh
        frame(g, e, STANDING)
    end
    local journal = g.shared[JOURNAL]
    for _, name in ipairs({ "BaseEyeHeight", "CrouchedEyeHeight" }) do
        t.truthy(journal:find("prop\t" .. new .. "\t" .. name .. "\t", 1, true), name .. " under the new name")
        t.falsy(journal:find("prop\t" .. old .. "\t" .. name .. "\t", 1, true), name .. " not under the old one")
    end
    noErrors(g)
end)

t.test("EyeHeight as a number is the standing eye; changing EyeHeight with F7 forgets the one read off the "
    .. "capsule", function()
    local g, e = eyeGame({ EyeHeight = 60 }, { info = STANDING })
    local p = fake.props(g.pawn)
    t.near(p.BaseEyeHeight, 60, 1e-6, "standing")
    duck(g, e)
    for _ = 1, 10 do
        frame(g, e, DUCKED_CROUCHED)
    end
    t.near(p.BaseEyeHeight, 60 + DUCKED, 0.01, "ducked")
    t.near(p.CrouchedEyeHeight, 60 + DUCKED, 0.01)
    local eye, from = e.camera.standingEye()
    t.eq(eye, 60)
    t.eq(from, "EyeHeight")

    g, e = eyeGame(nil, { info = STANDING })
    p = fake.props(g.pawn)
    duck(g, e)
    local ducked = heights(12, 0, true, false, 90) -- another standing half height, as above
    for _ = 1, 10 do
        frame(g, e, ducked)
    end
    fake.useConfig({ Movement = false, EyeHeight = 60 })
    g.press(F7)
    g.frames(5)
    t.near(p.BaseEyeHeight, 60 + DUCKED, 0.01, "EyeHeight 60")
    fake.useConfig({ Movement = false })
    g.press(F7)
    g.frames(5)
    t.near(p.BaseEyeHeight, 0.78 * 90 + DUCKED, 0.01, "auto again, the capsule crouched: the reading was forgotten")
    t.eq(select(2, e.camera.standingEye()), "the standing half height")
    noErrors(g)
end)

t.test("another character forgets the standing eye: a new one, and another at the same address", function()
    local g, e = eyeGame(nil, { info = STANDING })
    duck(g, e)
    for _ = 1, 10 do
        frame(g, e, DUCKED_CROUCHED)
    end
    -- A new character, crouched from the start, with a taller standing capsule.
    e.hull.standHalf, e.hull.crouchAtStart = 100, true
    local c = g.buildCharacter()
    g.useCharacter(c)
    e.info = heights(12, 0, true, false, 100)
    g.frames(SETTLE_FRAMES + 10)
    t.truthy(e.camera.isActive(), "first person on the new character")
    t.near(fake.props(c.pawn).BaseEyeHeight, 0.78 * 100 + DUCKED, 0.01, "its own standing eye")

    -- Another character at the old one's address, which its full name tells (the movement
    -- now knows another standing half height, so an eye taken from it would show). Seen
    -- standing, it is read as any character, and that reading is its own...
    local PATH = "/Game/Levels/Fake.Fake:PersistentLevel.BP_jRPG_Character_World_C_"
    g, e = eyeGame(nil, { info = STANDING })
    e.info = heights(28, 0, false, false, 90)
    g.press(F6)
    fake.move(g.pawn, PATH .. "Another")
    g.press(F6)
    g.frames(5)
    duck(g, e)
    local ducked = heights(12, 0, true, false, 90)
    for _ = 1, 10 do
        frame(g, e, ducked)
    end
    g.press(F6)
    g.press(F6)
    g.frames(5)
    t.truthy(e.camera.isActive(), "first person on again, crouched")
    t.near(fake.props(g.pawn).BaseEyeHeight, E + DUCKED, 0.01, "its own standing eye, read while it stood")
    -- ...first seen crouched, the old character's reading isn't used for it.
    g.press(F6)
    fake.move(g.pawn, PATH .. "YetAnother")
    g.press(F6)
    g.frames(5)
    t.truthy(e.camera.isActive(), "first person on again")
    t.near(fake.props(g.pawn).BaseEyeHeight, 0.78 * 90 + DUCKED, 0.01, "not the old character's standing eye")
    noErrors(g)
end)
