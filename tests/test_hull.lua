-- hull.lua against the fake game's crouching capsule (tests/fake_hull.lua). A small driver
-- stands in for movement.lua: the frame hook's duck parts in the design's order (the answers,
-- the drop on the ground, the keys, the braking given back, the floor below, the room,
-- Half-Life's updates with duck.lua, the lift and its re-run, the mode change, the drops of the
-- frame's events, the velocity, the request), so that each rule of hull.lua shows on its own.
-- The driver moves nothing horizontally but what a test asks, and writes the vertical speed as
-- the mod does: the jump's, 0 at a lift and on the ground, Unreal's own in the air. The duck key
-- is LeftControl, read through the controller's poll; the duck tap's key and the jump key are
-- the driver's own (D.keys.tap, D.keys.jump), so the fake's game jump never fires.

local t = require("testlib")
local fake = require("fake_game")
local fakeHull = require("fake_hull")

local root = TEST_ROOT
-- Each test idles SETTLE_FRAMES - 180 frames first: the suite's settle, which the frame-phase
-- sweep changes in every test file, moves the phase of Half-Life's updates in these too.
local SETTLE_FRAMES = 190
local SCALE = 2.5
local DELTA = 18 * SCALE -- the hulls' difference, cm
local EYE = 0.78 * 96 -- a standing eye above the fake's actor location (any number does)
local FALLING = 3
local JOURNAL = "HL1Movement.changes"
local CTRL = { KeyName = fake.FName("LeftControl") }

local function modules()
    for name in pairs(package.loaded) do
        if name:match("^hl1movement%.") then
            package.loaded[name] = nil
        end
    end
    local m = {}
    for _, name in ipairs({ "ue", "log", "guard", "journal", "overrides", "duck", "hull", "settings" }) do
        m[name] = require("hl1movement." .. name)
    end
    return m
end

local function config(m, changes)
    local cfg = {}
    for k, v in pairs(m.settings.DEFAULTS) do
        cfg[k] = v
    end
    for k, v in pairs(changes or {}) do
        cfg[k] = v
    end
    return cfg
end

local function flat()
    return 0, 0, 0, 1
end

-- Half-Life's updates of one hook, as physics.simulate runs duck.lua's part of them: the
-- button with the ground as the update before left the player, the duck step, the jump after
-- it; a hook with no update tries the first on a copy and jumps at once unless it would lift.
local function runUpdates(D, d, dt, room, onGround)
    local duck, rate = D.duck, D.P.rate
    D.acc = D.acc + dt
    local n = math.min(math.floor(D.acc * rate + 1e-9), 25)
    D.acc = math.max(0, D.acc - n / rate)
    local out = { events = {}, n = n, scaled = 0 }
    if n == 0 then
        local c = duck.copy(d)
        local _, event = duck.step(c, duck.button(c, onGround), onGround, room, 0)
        if event ~= "lift" and duck.jump(d, duck.jumpButton(d, true), onGround) then
            out.jumped = 0
        end
        return out
    end
    local held = true
    for k = 1, n do
        local button = duck.button(d, onGround)
        local jumpButton = duck.jumpButton(d, k == 1)
        held = held and button
        local scale, event, after = duck.step(d, button, onGround, room, 1000 / rate)
        if scale < 1 then
            out.scaled = out.scaled + 1
        end
        if event then
            out.events[#out.events + 1] = { k = k, what = event, ground = onGround }
            if event == "lift" then
                out.lifted = out.lifted or k
            end
        end
        onGround = after
        if duck.jump(d, jumpButton, onGround) then
            out.jumped = out.jumped or k
            onGround = false
        end
    end
    d.held = held
    return out
end

local function newDriver(g, m, cfg)
    local hull, duck = m.hull, m.duck
    local D = { g = g, m = m, cfg = cfg, P = m.settings.physics(cfg), hull = hull, duck = duck,
        keys = { notch = false, tap = false, jump = false, jumpNotch = false },
        vx = 0, vy = 0, acc = 0, rows = {}, frames = 0, taken = false, active = true, nextRefresh = 0, clock = 0 }
    g.limiterTicking = false -- (paused, as the mod pauses it)
    g.terrain = g.terrain or flat -- (so that a walking capsule lifted without a mode change is pulled back)
    -- Half-Life's origin, for the eye's checks: on the ground from the floor (1/32 unit above
    -- its plane, and 36 or 18 units more), moved 18 units by the ground's hull changes and the
    -- lift, and in the air along the free path of the vertical speed written.
    local function hlRest(d, groundZ)
        return groundZ + SCALE / 32 + (d.state == duck.DUCKED and 18 or 36) * SCALE
    end
    function D.hook(dt)
        if not D.active then
            return
        end
        if g.paused then
            D.written = nil -- (movement.hold: Unreal moves nothing, and the frame before is gone)
            return
        end
        D.frames = D.frames + 1
        D.clock = D.clock + dt
        local pawn, cmc = g.pawn, g.cmc
        local p = fake.props(cmc)
        pawn:ConsumeMovementInputVector()
        -- What movement.apply does every frame besides ducking, in short.
        p.CurrentMovementSettings.MovementCurve = nil
        p.MaxWalkSpeed, p.MaxWalkSpeedCrouched = 100000, 100000
        p.GravityScale = D.P.gravity / 980
        p.bUseSeparateBrakingFriction, p.BrakingFriction = true, 0
        p.BrakingDecelerationWalking, p.BrakingDecelerationFalling = 1, 1
        if not D.taken then
            D.taken = true
            hull.takeOver(pawn, cmc, D.cfg, D.P)
            D.d = duck.new(fake.props(pawn).bIsCrouched == true)
            D.written, D.acc, D.hlZ = nil, 0, nil
            D.nextRefresh = D.clock + 0.5
        elseif D.clock >= D.nextRefresh then
            D.nextRefresh = D.nextRefresh + 0.5
            hull.refresh(pawn, cmc)
        end
        local mode = p.MovementMode
        local walking = mode == 1 or mode == 2
        local at = pawn:K2_GetActorLocation()
        local v = p.Velocity
        local d = D.d
        local crouched = hull.read(pawn, cmc, d, at, mode, D.written, D.P)
        if walking then
            duck.groundDrop(d, crouched, hull.status().delta or DELTA, SCALE)
            D.hlZ = hlRest(d, g.groundAt(g.position.X, g.position.Y))
        end
        local row = { frame = D.frames, mode = mode, crouched = crouched, answer = hull.answer(), at = at,
            stateBefore = d.state, timerBefore = d.timer, dropBefore = d.drop }
        if D.hlZ then
            row.eye = at.Z + EYE + duck.eyeOffset(d, SCALE, crouched, false)
            row.hlEye = D.hlZ + d.view * SCALE
        end
        local k = D.keys
        if D.before then
            D.before(D, d, row)
        end
        local duckKey = g.pc:IsInputKeyDown(CTRL) == true
        duck.frame(d, { held = duckKey, notch = k.notch, tap = k.tap and not hull.liftOff(), jump = k.jump,
            jumpNotch = k.jumpNotch, autoHop = D.cfg.AutoHop })
        k.notch, k.jumpNotch = false, false
        row.rx, row.ry = v.X, v.Y
        row.vx, row.vy = hull.brakeBack(D.written, v.X, v.Y)
        local roomBelow
        if d.state == duck.DUCKED and crouched and mode == FALLING and not duck.heldInAir(d) then
            roomBelow = hull.floorRoom(cmc, at)
            row.asked = true
        end
        row.roomBelow = roomBelow
        local room = hull.room(d, false, roomBelow)
        row.room = { ground = room.ground, air = room.air, lift = room.lift }
        local snapshot, acc = duck.copy(d), D.acc
        local out = runUpdates(D, d, dt, room, walking)
        local liftAt, liftH
        if out.lifted then
            liftAt, liftH = hull.lift(pawn, cmc, at, p.CurrentFloor.FloorDist)
            if not liftAt then
                row.refusedLift = true
                d = snapshot
                D.d, D.acc = d, acc
                room.lift = false
                out = runUpdates(D, d, dt, room, walking)
            end
        end
        local lifted = out.lifted ~= nil and liftAt ~= nil
        local leaving = lifted or out.jumped ~= nil
        if leaving then
            cmc:SetMovementMode(3, 0)
        end
        local groundChange = false
        for _, e in ipairs(out.events) do
            duck.eventDrop(d, e.what, e.ground, SCALE, e.what == "lift" and liftH or nil)
            if e.ground and D.hlZ then
                if e.what == "ducked" then
                    D.hlZ = D.hlZ - 18 * SCALE
                elseif e.what == "stood" or e.what == "lift" then
                    D.hlZ = D.hlZ + 18 * SCALE
                end
            end
            if e.what == "ducked" or e.what == "stood" then
                groundChange = e.ground
            end
        end
        local wz = (leaving and (lifted and 0 or D.P.jumpSpeed)) or (walking and 0) or v.Z
        local wx, wy = D.vx, D.vy
        local speed = math.sqrt(wx * wx + wy * wy)
        local ex, ey = wx, wy
        if speed > 1e-3 then
            local grow = (speed + 1 * dt) / speed -- (the tiny braking left, added back as the mod does)
            ex, ey = wx * grow, wy * grow
        end
        cmc.Velocity = { X = ex, Y = ey, Z = wz }
        if D.hlZ and (leaving or not walking) then
            D.hlZ = D.hlZ + wz * dt - 0.5 * D.P.gravity * dt * dt
        end
        local o = { state = d.state, button = d.held, falling = mode == FALLING or leaving,
            navWalking = mode == 2 and not leaving, sliding = false, roomBelow = roomBelow,
            groundChange = groundChange, leaving = leaving, duckKey = duckKey, dt = dt }
        if D.request then
            D.request(o)
        end
        hull.request(pawn, cmc, o)
        -- (As movement.step: the platform that carries the character in Unreal's update, read
        -- while it stands on it, or in the air with bStayBasedInAir.)
        local baseZ = 0
        if (walking and not leaving) or p.bStayBasedInAir then
            baseZ = cmc:GetImpartedMovementBaseVelocity().Z
        end
        D.written = { x = wx, y = wy, z = wz, mode = leaving and FALLING or mode, at = lifted and liftAt or at,
            dt = dt, baseZ = baseZ }
        row.state, row.view, row.drop, row.events, row.n, row.scaled = d.state, d.view, d.drop, out.events, out.n,
            out.scaled
        row.lifted, row.jumped, row.liftAt, row.liftH, row.leaving = lifted, out.jumped, liftAt, liftH, leaving
        row.wz, row.dt, row.duckKey = wz, dt, duckKey
        row.wish = fake.props(cmc).bWantsToCrouch
        row.base = fake.props(cmc).bCrouchMaintainsBaseLocation
        row.ahead = hull.aheadBase()
        D.rows[#D.rows + 1] = row
        m.journal.flush()
    end
    function D.last()
        return D.rows[#D.rows]
    end
    --- The mod handing back (movement.release); the next hook takes over again.
    function D.release()
        hull.release()
        m.journal.flush()
        D.taken = false
    end
    g.functions[g.tickPath] = true
    g.hooks[g.tickPath] = function(_, dt)
        D.hook(dt:get())
    end
    return D
end

-- A game with the hull and the driver: the character standing on flat ground, the mod's
-- modules fresh. changes: settings changed from the defaults.
local function hullGame(options, changes)
    local g = fake.newGame(options)
    local m = modules()
    local D = newDriver(g, m, config(m, changes))
    g.frames(SETTLE_FRAMES - 180, 1 / 60)
    return g, m, D
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

local function noErrors(g)
    t.absent(g.log, "Error in", "the mod logged an error")
    t.absent(g.log, "Turned off", "the mod turned something off")
end

-- Frames until fn(the hook's row) is true, at most limit, or an error.
local function untilRow(g, D, dt, limit, fn, what)
    for _ = 1, limit do
        g.frame(dt)
        if fn(D.last()) then
            return D.last()
        end
    end
    error("not within " .. limit .. " frames: " .. tostring(what))
end

local function crouchedRow(row)
    return row.crouched
end

local function standingRow(row)
    return not row.crouched
end

local function fallingRow(row)
    return row.mode == FALLING
end

local function walkingRow(row)
    return row.mode == 1
end

-- Ducks on the ground with the duck key until the capsule reads crouched.
local function duckOnGround(g, D, dt)
    g.keys.LeftControl = true
    return untilRow(g, D, dt or 1 / 80, 200, crouchedRow, "a crouch on the ground")
end

-- The jump key for one hook, then frames until the character falls at a hook.
local function jump(g, D, dt)
    D.keys.jump = true
    g.frame(dt or 1 / 80)
    D.keys.jump = false
    return untilRow(g, D, dt or 1 / 80, 10, fallingRow, "in the air")
end

local function rowsFrom(D, first)
    local list = {}
    for i = first, #D.rows do
        list[#list + 1] = D.rows[i]
    end
    return list
end

-- The eye the mod would write against Half-Life's (origin and view height), the same within
-- 1 cm on every row given: the drop follows every hull change.
local function eyeKept(rows, what)
    local first
    for _, row in ipairs(rows) do
        if row.eye then
            local gap = row.eye - row.hlEye
            first = first or gap
            if math.abs(gap - first) > 1 then
                error(string.format("%s: the eye moved %.2f cm against Half-Life's at frame %d (mode %d, %s)", what,
                    gap - first, row.frame, row.mode, row.crouched and "crouched" or "standing"), 2)
            end
        end
    end
    t.truthy(first ~= nil, what .. ": no row to compare")
end

-------------------------------------------------------------------------------------------
-- The fake's capsule

t.test("the fake's capsule crouches as Unreal does: on the ground the feet stay and the middle drops, in the air "
    .. "the middle stays and the feet rise; the eye height and ALS's stance follow", function()
    local g = fake.newGame()
    local p, pawn = fake.props(g.cmc), fake.props(g.pawn)
    t.eq(p.NavAgentProps.bCanCrouch, false, "Unreal's default: no crouching")
    p.bWantsToCrouch = true
    g.frame()
    t.eq(pawn.bIsCrouched, false, "not allowed")
    p.NavAgentProps.bCanCrouch = true
    p.CrouchedHalfHeight = 51
    local feet, at = g.position.Z, g.pawn:K2_GetActorLocation()
    g.frame()
    t.eq(pawn.bIsCrouched, true)
    t.near(g.c.capsule:GetScaledCapsuleHalfHeight(), 51, 1e-12)
    t.near(g.position.Z, feet, 1e-12, "walking: the feet stay")
    t.near(g.pawn:K2_GetActorLocation().Z, at.Z - 45, 1e-9, "and the middle drops 45 cm")
    t.eq(pawn.BaseEyeHeight, fakeHull.GAME_CROUCHED_EYE, "BaseEyeHeight = CrouchedEyeHeight")
    t.eq(pawn.Stance, 1, "ALS's stance")
    t.eq(p.MaxWalkSpeed, fakeHull.ALS_SPEED, "ALS's speeds written after the stance change")
    t.eq(p.MaxWalkSpeedCrouched, fakeHull.ALS_SPEED)
    t.truthy(p.CurrentMovementSettings.MovementCurve ~= nil, "and its movement curve back")
    p.bWantsToCrouch = false
    g.frame()
    t.eq(pawn.bIsCrouched, false, "stood up")
    t.near(g.position.Z, feet, 1e-12, "walking, on the same base")
    t.eq(pawn.BaseEyeHeight, fakeHull.DEFAULT_EYE, "the class default's eye height")
    t.eq(pawn.Stance, 0)
    -- In the air: the flag is false there, so the middle stays.
    g.cmc:SetMovementMode(3, 0)
    t.eq(p.bCrouchMaintainsBaseLocation, false, "set false entering the air")
    p.Velocity.Z = 600
    g.frame()
    local before = g.pawn:K2_GetActorLocation()
    local vz = p.Velocity.Z
    p.bWantsToCrouch = true
    g.frame(1 / 60)
    t.eq(pawn.bIsCrouched, true, "a crouch in the air")
    t.near(g.pawn:K2_GetActorLocation().Z, before.Z + vz / 60 - 0.5 * 980 / 3600, 1e-9, "the middle on the free path")
    t.eq(g.crouches, 2)
    g.frames(120)
    t.eq(g.mode(), 1, "landed")
    t.eq(p.bCrouchMaintainsBaseLocation, true, "set true at the landing")
    t.eq(pawn.bIsCrouched, true, "still crouched")
end)

t.test("the fake's stand-up: refused under a ceiling (also a walking gap lower), in the air in place with room "
    .. "below, and near a floor Unreal's pop-up onto it or above it", function()
    local g = fake.newGame()
    g.terrain = flat
    local p, pawn = fake.props(g.cmc), fake.props(g.pawn)
    p.NavAgentProps.bCanCrouch, p.CrouchedHalfHeight, p.bWantsToCrouch = true, 51, true
    g.frame()
    local feet = g.position.Z
    t.eq(pawn.bIsCrouched, true)
    g.ceilingAt = function()
        return feet + 192 - 1 -- 1 cm too low for the standing capsule on its base
    end
    p.bWantsToCrouch = false
    g.frames(3)
    t.eq(pawn.bIsCrouched, false, "a walking gap lower it fits")
    t.near(g.position.Z, fake.FLOOR_DIST, 1e-9, "(and the walk put it back on its gap)")
    p.bWantsToCrouch = true
    g.frame()
    g.ceilingAt = function()
        return 150
    end
    p.bWantsToCrouch = false
    local refused = g.refusedStands
    g.frames(5)
    t.eq(pawn.bIsCrouched, true, "no room: still crouched")
    t.truthy(g.refusedStands >= refused + 5, "tried at every update")
    g.ceilingAt = nil
    g.frame()
    t.eq(pawn.bIsCrouched, false, "and standing once there is room")
    -- In the air, the ducked bottom at B: in place if the standing feet (B - 45) are free.
    local function airStandUp(floorBelow)
        local game = fake.newGame()
        local gp, gpawn = fake.props(game.cmc), fake.props(game.pawn)
        gp.NavAgentProps.bCanCrouch, gp.CrouchedHalfHeight = true, 51
        game.cmc:SetMovementMode(3, 0)
        game.position.Z = 200
        gp.bWantsToCrouch = true
        game.frame(0)
        local B = game.position.Z
        game.terrain = function()
            return B - floorBelow, 0, 0, 1
        end
        local middle = game.pawn:K2_GetActorLocation().Z
        gp.bWantsToCrouch = false
        game.frame(0)
        return game.pawn:K2_GetActorLocation().Z - middle, gpawn.bIsCrouched, game.popups, game.position.Z - B
    end
    local rise, crouched, popups, feetMoved = airStandUp(60)
    t.eq(crouched, false)
    t.near(rise, 0, 1e-9, "room below: the middle stays")
    t.near(feetMoved, -45, 1e-9, "and the feet go 45 cm down")
    t.eq(popups, 0)
    rise, crouched, popups, feetMoved = airStandUp(10)
    t.eq(crouched, false)
    t.near(feetMoved, -10 + 0.951, 1e-9, "a floor 10 cm below: stood on it")
    t.near(rise, 45 - 10 + 0.951, 1e-9)
    t.eq(popups, 1, "a pop-up")
    -- (A sphere of the radius, 35 cm, from the middle down by the radius reaches 19 cm below
    -- this capsule's ducked bottom; 25 cm below the game's.)
    rise, crouched, popups, feetMoved = airStandUp(30)
    t.eq(crouched, false)
    t.near(rise, 96 - 70 + 0.951, 1e-9, "a floor 19 to 45 cm below: moved up")
    t.near(feetMoved, -19 + 0.951, 1e-9, "and standing in the air above it")
    t.eq(popups, 1)
    rise, crouched = airStandUp(44.9)
    t.eq(crouched, false)
    t.near(rise, 26.951, 1e-9, "44.9 cm: the same")
end)

t.test("the fake's ceiling: a walking capsule taller than the room under it doesn't go in, a crouched one does; a "
    .. "falling head stops under it; a swept move stops 1 cm short of it, and of the ground", function()
    local g = fake.newGame()
    g.terrain = flat
    local p = fake.props(g.cmc)
    p.CurrentMovementSettings.MovementCurve, p.BrakingDecelerationWalking = nil, 0
    g.ceilingAt = function(x)
        if x > 50 then
            return 120
        end
        return nil
    end
    p.Velocity.X = 300
    g.frames(30)
    t.truthy(g.position.X <= 50, "standing: stopped at the low part")
    t.eq(p.Velocity.X, 0)
    p.NavAgentProps.bCanCrouch, p.CrouchedHalfHeight, p.bWantsToCrouch = true, 51, true
    g.frame()
    p.CurrentMovementSettings.MovementCurve = nil
    p.Velocity.X = 300
    g.frames(30)
    t.truthy(g.position.X > 100, "crouched: under it")
    t.eq(g.ceilingStops > 0, true)
    -- A jump under the ceiling: the crouched head (102 cm above the feet) stops at 120.
    g.cmc:SetMovementMode(3, 0)
    p.bWantsToCrouch = true -- (ALS cleared it entering the air)
    p.Velocity.Z = 500
    g.frames(10)
    t.truthy(g.headHits > 0, "the head hit it")
    t.truthy(g.position.Z + 102 <= 120 + 1e-9, "and stays under it")
    -- Swept moves.
    local game = fake.newGame()
    game.terrain = flat
    local feet = game.position.Z
    game.ceilingAt = function()
        return feet + 192 + 10
    end
    local hit = {}
    game.pawn:K2_SetActorLocation({ X = 0, Y = 0, Z = feet + 45 }, true, hit, true)
    t.near(game.position.Z, feet + 9, 1e-9, "1 cm short of the ceiling")
    t.near(hit.Time, 9 / 45, 1e-9)
    game.pawn:K2_SetActorLocation({ X = 0, Y = 0, Z = feet - 30 }, true, hit, true)
    t.near(game.position.Z, 1, 1e-9, "1 cm above the ground")
    game.pawn:K2_SetActorLocation({ X = 0, Y = 0, Z = feet + 60 }, false, hit, true)
    t.near(game.position.Z, feet + 60, 1e-9, "not swept: put there")
    t.eq(game.sweeps, 2)
end)

-------------------------------------------------------------------------------------------
-- The crouch the mod asks for

local function fullName(obj)
    return obj:GetFullName()
end

t.test("a duck on the ground asks Unreal for its crouch once Half-Life's is complete: the wish the mod's (and in the "
    .. "journal), the crouched half height 18 units under the standing one, crouching allowed; the feet stay",
    function()
    local g, _, D = hullGame()
    local p, pawn = fake.props(g.cmc), fake.props(g.pawn)
    g.keys.LeftControl = true
    local asked = untilRow(g, D, 1 / 80, 200, function(row)
        return row.wish == true
    end, "the crouch asked for")
    t.eq(asked.state, D.duck.DUCKED, "asked for on the hook the duck completes")
    t.eq(asked.crouched, false, "with the capsule still standing")
    t.truthy(asked.ahead, "a crouch that keeps the feet (hull.aheadBase)")
    t.eq(p.CrouchedHalfHeight, 51, "the standing half height less 45 cm")
    t.eq(p.bCanWalkOffLedgesWhenCrouching, true)
    t.eq(p.NavAgentProps.bCanCrouch, true)
    t.contains(g.log, "Allowing the character to crouch (NavAgentProps.bCanCrouch was false)")
    t.contains(g.log, "Asking Unreal to crouch the character for the first time (bWantsToCrouch; CrouchedHalfHeight "
        .. "51.0 cm)")
    local name = fullName(g.cmc)
    local journal = g.shared[JOURNAL]
    t.truthy(journal:find("prop\t" .. name .. "\tbWantsToCrouch\tb0", 1, true), "the wish in the journal")
    t.truthy(journal:find("prop\t" .. name .. "\tCrouchedHalfHeight\tn60", 1, true), "the game's half height")
    t.truthy(journal:find("prop\t" .. name .. "\tbCanWalkOffLedgesWhenCrouching\tb0", 1, true))
    t.truthy(journal:find("field\t" .. name .. "\tNavAgentProps.bCanCrouch\tb0", 1, true), "a struct's field")
    local feet = g.position.Z
    g.frame(1 / 80)
    local row = D.last()
    t.eq(row.answer, "ducked")
    t.eq(row.crouched, true)
    t.near(g.position.Z, feet, 1e-9, "the feet stayed")
    t.eq(pawn.Stance, 1)
    t.contains(g.log, "The character crouched (Unreal's crouch, on the ground): half height 96.0 -> 51.0 cm, middle "
        .. "moved -45.0 cm")
    t.contains(g.log, "BaseEyeHeight 48 (CrouchedEyeHeight 48), the duck key still held: yes")
    g.frames(20, 1 / 80)
    t.eq(D.last().crouched, true, "stays crouched while the key is held")
    t.eq(p.bWantsToCrouch, true)
    -- Let go: Half-Life stands up at once, and the mod lets go of the wish.
    g.keys.LeftControl = false
    g.frame(1 / 80)
    t.eq(D.last().state, D.duck.STANDING, "Half-Life's stand-up")
    t.eq(p.bWantsToCrouch, false, "the wish given up")
    t.falsy(g.shared[JOURNAL]:find("bWantsToCrouch", 1, true), "and out of the journal")
    g.frame(1 / 80)
    t.eq(D.last().answer, "stood")
    t.eq(D.last().crouched, false)
    t.near(g.position.Z, feet, 1e-9, "on the same feet")
    t.contains(g.log, "The character stood up (Unreal's un-crouch, on the ground): half height 51.0 -> 96.0 cm, "
        .. "middle moved +45.0 cm")
    -- Those lines once a session, and their reads with them.
    local reads = 0
    local half = g.c.capsule.GetScaledCapsuleHalfHeight
    fake.method(g.c.capsule, "GetScaledCapsuleHalfHeight", function(self)
        reads = reads + 1
        return half(self)
    end)
    duckOnGround(g, D)
    g.keys.LeftControl = false
    untilRow(g, D, 1 / 80, 5, standingRow, "the second stand-up")
    t.eq(count(g.log, "The character crouched (Unreal's crouch, on the ground)"), 1)
    t.eq(count(g.log, "The character stood up (Unreal's un-crouch, on the ground)"), 1)
    t.eq(reads, 0, "no capsule read for the second crouch")
    noErrors(g)
end)

t.test("a crouch wish of the game's that Unreal doesn't carry out is the game's all the same: the mod doesn't take "
    .. "it over, and doesn't take the capsule standing for the game standing it up", function()
    local g, m, D = hullGame({ noCrouch = true })
    g.gameCrouch(true)
    g.keys.LeftControl = true
    untilRow(g, D, 1 / 80, 200, function(r)
        return r.state == r.stateBefore and r.state == 2
    end, "ducked")
    t.eq(m.hull.status().byGame, true, "the game's wish")
    g.frames(20, 1 / 80)
    local row = D.last()
    t.eq(row.state, D.duck.DUCKED, "Half-Life still ducked")
    t.eq(row.answer, nil)
    t.eq(fake.writes(g.cmc).bWantsToCrouch, nil, "the game's wish never written")
    g.gameCrouch(false)
    g.frames(2, 1 / 80)
    t.eq(fake.props(g.cmc).bWantsToCrouch, true, "taken over once the game let go")
    t.eq(m.hull.status().byGame, false)
end)

t.test("a duck in the air keeps the middle where it is (no flag), and the eye's drop needs no re-base", function()
    local g, _, D = hullGame()
    jump(g, D)
    g.frames(3, 1 / 80)
    g.keys.LeftControl = true
    local asked = untilRow(g, D, 1 / 80, 5, function(row)
        return row.wish == true
    end, "the crouch asked for in the air")
    t.eq(asked.state, D.duck.DUCKED, "Half-Life ducks at once in the air")
    t.falsy(asked.ahead, "a crouch that keeps the middle")
    t.eq(asked.base, false, "the flag as Unreal set it entering the air")
    local row = untilRow(g, D, 1 / 80, 2, crouchedRow, "the crouch")
    t.eq(row.mode, FALLING)
    local free = asked.at.Z + asked.wz * asked.dt - 0.5 * D.P.gravity * asked.dt * asked.dt
    t.near(row.at.Z, free, 1e-6, "the middle on the free path")
    t.near(row.dropBefore, asked.drop, 1e-6, "the drop as it was")
    t.contains(g.log, "The character crouched (Unreal's crouch, in the air): half height 96.0 -> 51.0 cm, middle "
        .. "moved +0.0 cm, feet moved +45.0 cm")
    noErrors(g)
end)

t.test("the wish is written last in the hook, after the mod's own SetMovementMode, whose ALS handler clears it: a "
    .. "ducked jump stays crouched in the air, and a clear the mod didn't make is counted", function()
    local g, m, D = hullGame()
    duckOnGround(g, D)
    local cleared = 0
    D.request = function(o)
        if o.leaving and fake.props(g.cmc).bWantsToCrouch == false then
            cleared = cleared + 1 -- ALS cleared it inside the mod's SetMovementMode, before the request
        end
    end
    local row = jump(g, D)
    t.eq(cleared, 1, "ALS's clear came before the request")
    t.eq(row.crouched, true, "still crouched in the air")
    t.eq(fake.props(g.cmc).bWantsToCrouch, true)
    t.eq(g.uncrouches, 0, "never stood up")
    t.eq(m.hull.status().counts.wishClears, 0, "the mod's own mode change isn't a clear of the game's")
    -- A clear inside Unreal's update (a walk-off's ALS handler, say), seen at the next hook.
    g.frames(3, 1 / 80)
    g.clearWishOnce = true -- (the game clears it before Unreal's next update: it stands up)
    g.frame(1 / 80)
    fake.props(g.cmc).bWantsToCrouch = false -- and once more after the update
    g.frame(1 / 80)
    t.eq(m.hull.status().counts.wishClears >= 1, true, "counted")
    t.contains(g.log, "ALS or the game cleared the crouch wish the mod holds (bWantsToCrouch); the mod asks again")
    t.eq(fake.props(g.cmc).bWantsToCrouch, true, "written again")
end)

t.test("hull.request asks for the crouch exactly while Half-Life is fully ducked and the duck button was down on "
    .. "every update of the frame, or where a stand-up wouldn't be Half-Life's (in the air with no room below known, "
    .. "sliding): every combination, from a crouch the mod holds and from none", function()
    local checked = 0
    for _, state in ipairs({ 0, 1, 2 }) do
        for _, button in ipairs({ true, false }) do
            for _, falling in ipairs({ false, true }) do
                for _, sliding in ipairs({ false, true }) do
                    for _, below in ipairs({ "unknown", true, false }) do
                        for _, owned in ipairs({ false, true }) do
                            local g, m, D = hullGame()
                            D.active = false
                            local hull = m.hull
                            if owned then
                                hull.request(g.pawn, g.cmc, { state = 2, button = true, falling = false, dt = 0 })
                                t.eq(fake.props(g.cmc).bWantsToCrouch, true, "held")
                            end
                            local roomBelow = below ~= "unknown" and below or nil
                            hull.request(g.pawn, g.cmc, { state = state, button = button, falling = falling,
                                sliding = sliding, roomBelow = roomBelow, dt = 0 })
                            local standAllowed = (not falling and not sliding) or (falling and roomBelow == true)
                            local want = state == 2 and (button or not standAllowed)
                            t.eq(fake.props(g.cmc).bWantsToCrouch, want, string.format("state %d, button %s, falling "
                                .. "%s, sliding %s, room below %s, %s", state, tostring(button), tostring(falling),
                                tostring(sliding), tostring(below), owned and "held" or "not held"))
                            checked = checked + 1
                        end
                    end
                end
            end
        end
    end
    t.eq(checked, 144)
end)

t.test("C12: a hull change of Half-Life's on the ground in an update that leaves it keeps the feet (the flag "
    .. "written after the mode change), as in nav-mesh walking; the next hook re-bases the drop by the measured move",
    function()
    -- A stand-up and a jump in one update: the middle rises 45 cm off the free path.
    local g, m, D = hullGame()
    duckOnGround(g, D)
    g.frames(5, 1 / 80)
    g.keys.LeftControl = false
    D.keys.jump = true
    g.frame(1 / 80)
    D.keys.jump = false
    local takeoff = D.last()
    t.truthy(takeoff.leaving, "jumped")
    t.eq(takeoff.events[1].what, "stood", "stood up first, on the ground")
    t.eq(takeoff.base, true, "the flag written for Unreal's update, which starts falling")
    t.eq(fake.props(g.cmc).bWantsToCrouch, false)
    g.frame(1 / 80)
    local row = D.last()
    t.eq(row.crouched, false)
    local free = takeoff.at.Z + takeoff.wz * takeoff.dt - 0.5 * D.P.gravity * takeoff.dt ^ 2
    t.near(row.at.Z - free, DELTA, 1e-6, "the middle 45 cm above the free path: the feet kept")
    t.near(row.dropBefore - takeoff.drop, DELTA, 1e-6, "the drop re-based by the move")
    t.eq(m.hull.status().counts.popups, 0, "Unreal kept the base: not a pop-up")
    t.eq(m.hull.status().counts.rebasesMeasured, 1)
    -- A duck that completes on the jump's update: the middle 45 cm below the free path.
    g, m, D = hullGame()
    g.keys.LeftControl = true
    D.before = function(driver, d)
        driver.keys.jump = d.state == driver.duck.IN_DUCK and d.timer - 1000 / driver.P.rate <= 600 + 1e-6
    end
    local jumped = untilRow(g, D, 1 / 80, 200, function(r)
        return r.leaving
    end, "the duck and the jump")
    D.before, D.keys.jump = nil, false
    t.eq(jumped.events[1].what, "ducked", "the duck completed on the jump's update")
    t.eq(jumped.events[1].ground, true)
    t.eq(jumped.base, true, "the flag written")
    t.truthy(jumped.ahead, "a crouch that keeps the feet")
    g.frame(1 / 80)
    row = D.last()
    t.eq(row.crouched, true)
    free = jumped.at.Z + jumped.wz * jumped.dt - 0.5 * D.P.gravity * jumped.dt ^ 2
    t.near(row.at.Z - free, -DELTA, 1e-6, "the middle 45 cm below the free path")
    t.near(row.dropBefore - jumped.drop, -DELTA, 1e-6, "the drop re-based")
    t.eq(m.hull.status().counts.rebasesMeasured, 1)
    -- Nav-mesh walking: Unreal's flag is false there.
    g, m, D = hullGame()
    g.changeMode(g.cmc, 2, g.pawn)
    t.eq(fake.props(g.cmc).bCrouchMaintainsBaseLocation, false)
    g.keys.LeftControl = true
    local asked = untilRow(g, D, 1 / 80, 200, function(r)
        return r.wish == true
    end, "the crouch asked for")
    t.eq(asked.mode, 2)
    t.eq(asked.base, true, "written for nav-mesh walking")
    t.truthy(asked.ahead)
    local feet = g.position.Z
    g.frame(1 / 80)
    t.eq(D.last().crouched, true)
    t.near(g.position.Z, feet, 1e-9, "the feet kept")
    t.eq(m.hull.status().counts.groundCrouches, 1)
    -- A crouch in the air writes nothing.
    g, m, D = hullGame()
    jump(g, D)
    g.keys.LeftControl = true
    asked = untilRow(g, D, 1 / 80, 5, function(r)
        return r.wish == true
    end, "the crouch asked for in the air")
    t.eq(asked.base, false, "not written in the air")
    g.frame(1 / 80)
    t.eq(m.hull.status().counts.airCrouches, 1)
    noErrors(g)
end)

t.test("whose crouch it is: a crouch the game made is never cleared (not by Half-Life's stand-up, a hand-back or F5), "
    .. "and Half-Life stays fully ducked while it lasts", function()
    local g, m, D = hullGame()
    local p = fake.props(g.cmc)
    g.gameCrouch(true)
    local row = untilRow(g, D, 1 / 80, 5, crouchedRow, "the game's crouch")
    t.eq(row.answer, "crouched by the game")
    t.eq(row.state, D.duck.DUCKED, "Half-Life fully ducked")
    t.contains(g.log, "The game crouched the character itself")
    local scaled, updates = 0, 0
    D.keys.tap = true -- +ducktap: no tap while the crouch is the game's
    g.frames(80, 1 / 80, function()
        local last = D.last()
        scaled, updates = scaled + last.scaled, updates + last.n
        t.falsy(last.lifted or last.refusedLift, "no tap")
    end)
    t.eq(scaled, updates, "every update fully ducked")
    for _, r in ipairs(D.rows) do
        for _, e in ipairs(r.events) do
            t.truthy(e.what ~= "stood" and e.what ~= "pressed" and e.what ~= "lift", "no " .. e.what)
        end
    end
    D.keys.tap = false
    g.keys.LeftControl = true
    g.frames(10, 1 / 80)
    g.keys.LeftControl = false
    g.frames(10, 1 / 80)
    t.eq(p.bWantsToCrouch, true, "the game's wish stays")
    D.release()
    g.frame(1 / 80)
    t.eq(p.bWantsToCrouch, true, "not cleared at a hand-back")
    m.hull.reset() -- F5: off and on
    D.release()
    g.frames(5, 1 / 80)
    t.eq(p.bWantsToCrouch, true, "nor at F5")
    t.eq(fake.props(g.pawn).bIsCrouched, true)
    g.gameCrouch(false)
    row = untilRow(g, D, 1 / 80, 5, standingRow, "the game's stand-up")
    t.eq(row.answer, "stood by the game")
    t.eq(row.state, D.duck.STANDING, "Half-Life standing again")
    noErrors(g)
end)

t.test("a crouch of the mod's still on when it hands back (under something low) stays the mod's: the take-over "
    .. "doesn't take it for the game's, holds the wish again with the duck key held, and learns of a refusal from "
    .. "Unreal's answer only; at F7 (a hand-back and a take-over in one hook) no refusal is made up", function()
    local g, m, D = hullGame()
    local p = fake.props(g.cmc)
    duckOnGround(g, D)
    local feet = g.position.Z
    g.ceilingAt = function()
        return feet + 120
    end
    D.release()
    D.active = false
    g.frames(5, 1 / 80)
    t.eq(fake.props(g.pawn).bIsCrouched, true, "Unreal can't stand it up under the ceiling")
    t.eq(p.bWantsToCrouch, false, "the wish handed back")
    D.active = true
    g.frame(1 / 80)
    local row = D.last()
    t.eq(row.answer, nil, "not the game's crouch, and no refusal yet")
    t.eq(m.hull.status().byGame, false)
    t.eq(row.state, D.duck.DUCKED, "Half-Life fully ducked (the duck key held)")
    t.eq(p.bWantsToCrouch, true, "the mod's own crouch: it holds the wish again")
    g.keys.LeftControl = false
    row = untilRow(g, D, 1 / 80, 3, function(r)
        return r.answer == "stand refused"
    end, "Unreal's refusal")
    t.eq(row.stateBefore, D.duck.DUCKED, "fully ducked again")
    t.eq(row.room.ground, false, "and the room known")
    g.frames(5, 1 / 80)
    t.eq(D.last().state, D.duck.DUCKED, "no room: stays ducked")
    g.ceilingAt = nil
    row = untilRow(g, D, 1 / 80, 5, standingRow, "the stand-up once there is room")
    t.eq(row.answer, "stood late")
    t.eq(row.state, D.duck.STANDING)
    -- F7 while ducked with nothing above: handed back and taken over before Unreal's update.
    duckOnGround(g, D)
    g.keys.LeftControl = false -- (a duck key held at a take-over is ignored until let go)
    D.release()
    g.frame(1 / 80)
    t.eq(D.last().answer, nil, "no refusal made up")
    t.eq(D.last().state, D.duck.STANDING, "Half-Life stands up at once")
    g.frame(1 / 80)
    t.eq(D.last().answer, "stood")
    t.eq(D.last().crouched, false)
    t.eq(count(g.log, "No room to stand up"), 1, "only the real refusal's line")
    noErrors(g)
end)

t.test("a hull change Unreal made just before a pause is re-based after it by what the request had Unreal do (the "
    .. "frame before is gone), and the eye stays Half-Life's", function()
    local g, m, D = hullGame()
    duckOnGround(g, D)
    g.frames(5, 1 / 80)
    local first = #D.rows
    g.keys.LeftControl = false
    D.keys.jump = true -- a stand-up and a jump in one update: Unreal stands it up keeping the feet
    g.frame(1 / 80)
    D.keys.jump = false
    local takeoff = D.last()
    g.paused = true
    g.frames(3, 1 / 80)
    g.paused = false
    g.frame(1 / 80)
    local row = D.last()
    t.eq(row.crouched, false)
    t.near(row.dropBefore - takeoff.drop, DELTA, 1e-9, "the stand-up's own move, 45 cm")
    t.eq(m.hull.status().counts.rebases, 1)
    t.eq(m.hull.status().counts.rebasesMeasured, 0, "nothing to measure against")
    untilRow(g, D, 1 / 80, 80, walkingRow, "the landing")
    g.frames(3, 1 / 80)
    eyeKept(rowsFrom(D, first), "across the pause")
    noErrors(g)
end)

t.test("on a platform that carries the character in the air (bStayBasedInAir), its travel isn't taken for a hull "
    .. "change: the re-base takes it out", function()
    local g, m, D = hullGame({ stayBasedInAir = true })
    g.baseVelocity = { X = 0, Y = 0, Z = 100 } -- rising
    duckOnGround(g, D)
    g.frames(5, 1 / 80)
    g.keys.LeftControl = false
    D.keys.jump = true -- a stand-up and a jump in one update: the feet kept
    g.frame(1 / 80)
    D.keys.jump = false
    local takeoff = D.last()
    t.eq(takeoff.base, true)
    g.frame(1 / 80)
    local row = D.last()
    t.eq(row.crouched, false)
    t.near(row.dropBefore - takeoff.drop, DELTA, 1e-6, "the drop re-based by the hull change alone")
    t.eq(m.hull.status().counts.popups, 0)
    t.eq(m.hull.status().counts.rebaseStandBase, 1, "a stand-up that kept the feet")
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- Standing up in the air, and the lift

-- Ducked in the air (the duck key held from a hop), dt a frame: then the floor put
-- floorBelow cm under the ducked capsule's bottom, and the duck key let go (or not).
local function duckedInTheAir(dt, options, changes, rule)
    local g, m, D = hullGame(options, changes)
    if rule ~= nil then
        m.duck.HELD_DUCK_UNDER_TAP = rule
    end
    jump(g, D, dt)
    g.keys.LeftControl = true
    untilRow(g, D, dt, 5, crouchedRow, "crouched in the air")
    g.frames(2, dt)
    return g, m, D
end

local function floorAt(g, below)
    local floor = g.position.Z - below
    g.terrain = function()
        return floor, 0, 0, 1
    end
end

t.test("standing up in the air asks for the floor below first: under 45.5 cm from the ducked capsule's bottom "
    .. "Half-Life's stand-up waits (Unreal would move the character up), from 45.5 on it stands up in place; 200 "
    .. "releases near floors make no pop-up", function()
    for _, case in ipairs({ { 30, false }, { 45.4, false }, { 45.6, true }, { 60, true } }) do
        local below, room = case[1], case[2]
        local g, m, D = duckedInTheAir(1 / 80)
        floorAt(g, below)
        g.keys.LeftControl = false
        g.frame(1 / 80)
        local row = D.last()
        t.truthy(row.asked, "asked at " .. below)
        t.eq(m.hull.status().counts.floorQueries, 1, "once, at the release")
        t.eq(row.roomBelow, room, "the answer at " .. below)
        t.eq(row.state, room and D.duck.STANDING or D.duck.DUCKED, "Half-Life at " .. below)
        g.frame(1 / 80)
        t.eq(D.last().crouched, not room, "the capsule at " .. below)
        t.eq(g.popups, 0, "no pop-up at " .. below)
        t.eq(D.last().asked == true, not room, "asked again while the stand-up waits")
        t.contains(g.log, "Asking Unreal for the floor below the character for the first time (K2_ComputeFloorDist), "
            .. "to stand up in the air")
    end
    -- Releases near floors, at three frame rates.
    local seed, releases, waits, stands = 12345, 0, 0, 0
    local function random()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for i = 1, 200 do
        local dt = ({ 1 / 60, 1 / 80, 1 / 144 })[i % 3 + 1]
        local g, _, D = duckedInTheAir(dt)
        floorAt(g, random() * 80)
        g.keys.LeftControl = false
        g.frame(dt)
        if D.last().state == D.duck.DUCKED then
            waits = waits + 1
        else
            stands = stands + 1
        end
        g.frames(60, dt)
        releases = releases + 1
        t.eq(g.popups, 0, "release " .. i)
        noErrors(g)
    end
    t.eq(releases, 200)
    t.truthy(waits > 50 and stands > 50, string.format("both kinds (%d waited, %d stood up)", waits, stands))
end)

t.test("the floor below is asked wherever an update of the hook may stand up: with OpenAG's 2020 rule a duck key "
    .. "held under +ducktap gives no button in the air, and after a notch the next update has none; 30 cm above a "
    .. "floor both stay ducked", function()
    -- (The movement asks unless duck.heldInAir: the button down on every update of the hook.)
    local g, m, D = duckedInTheAir(1 / 80, nil, nil, false)
    floorAt(g, 30)
    D.keys.tap = true
    g.frame(1 / 80)
    local row = D.last()
    t.truthy(row.asked, "asked: the duck key gives no button in the air under the ducktap key (2020)")
    t.eq(row.roomBelow, false)
    t.eq(row.state, D.duck.DUCKED, "stays ducked")
    g.frames(10, 1 / 80)
    t.eq(g.popups, 0)
    t.eq(m.duck.HELD_DUCK_UNDER_TAP, false)
    -- 2022: the duck key keeps the button down in the air: nothing to ask.
    g, m, D = duckedInTheAir(1 / 80)
    floorAt(g, 30)
    D.keys.tap = true
    g.frame(1 / 80)
    t.falsy(D.last().asked, "2022: not asked")
    t.eq(D.last().state, D.duck.DUCKED)
    t.eq(m.duck.HELD_DUCK_UNDER_TAP, true)
    -- A wheel notch at one update a frame: ducked for that update, the next one has no button.
    g, m, D = hullGame()
    jump(g, D, 1 / 250)
    g.frames(5, 1 / 250)
    D.keys.notch = true
    g.frame(1 / 250)
    t.eq(D.last().state, D.duck.DUCKED, "the notch's update ducks")
    t.eq(D.last().wish, true, "and its frame asks for the crouch")
    floorAt(g, 30) -- (under the crouched capsule, as Unreal's update left it)
    g.frame(1 / 250)
    row = D.last()
    t.eq(row.crouched, true)
    t.truthy(row.asked, "asked after the notch")
    t.eq(row.state, D.duck.DUCKED, "30 cm above the floor: stays ducked")
    g.frames(30, 1 / 250)
    t.eq(g.popups, 0)
    t.truthy(m.hull.status().counts.floorNoRoom >= 1)
    noErrors(g)
end)

-- A duck tap with +ducktap held from the ground: frames until the lift (or its refusal).
local function tapRow(g, D, dt)
    D.keys.tap = true
    return untilRow(g, D, dt or 1 / 80, 10, function(row)
        return row.lifted or row.refusedLift
    end, "a tap")
end

t.test("the duck tap's lift: swept 18 units up (Half-Life's room test), then placed 16 1/32 units less the walking "
    .. "gap up, in the air from there; where it is blocked, put back where it stood and held back 0.1 s or 10 cm",
    function()
    local g, m, D = hullGame()
    local feet = g.position.Z
    local sweeps = g.sweeps
    local row = tapRow(g, D)
    t.truthy(row.lifted, "lifted")
    t.eq(g.sweeps, sweeps + 1, "one swept move")
    local place = (16 + 1 / 32) * SCALE - fake.FLOOR_DIST
    t.near(row.liftH, place, 1e-9, "placed 37.93 cm up")
    t.near(row.liftAt.Z - row.at.Z, place, 1e-9, "the location read back, returned")
    t.near(g.position.Z, feet + place - 0.5 * D.P.gravity / 80 ^ 2, 1e-9, "the feet from there, a frame's fall")
    t.eq(g.mode(), FALLING)
    t.contains(g.log, "Lifting the character for a duck tap for the first time (K2_SetActorLocation: swept 45 cm up, "
        .. "then placed 37.9 cm up)")
    D.keys.tap = false
    local landing = untilRow(g, D, 1 / 80, 40, walkingRow, "the tap's landing")
    t.near((landing.frame - row.frame) / 80, 0.2002, 1 / 80 + 1e-9, "landing 0.2 s after the lift")
    t.eq(m.hull.status().counts.lifts, 1)
    -- 10 cm above the standing head: no room.
    g, m, D = hullGame()
    feet = g.position.Z
    g.ceilingAt = function()
        return feet + 192 + 10
    end
    row = tapRow(g, D)
    t.truthy(row.refusedLift, "refused")
    t.near(g.position.Z, feet, 1e-12, "put back where it stood")
    t.eq(g.mode(), 1, "on the ground")
    t.eq(row.state, D.duck.IN_DUCK, "Half-Life stays in the transition")
    t.contains(g.log, "No room for a duck tap (only 9 cm above the head): you stay on the ground")
    sweeps = g.sweeps
    g.frames(80, 1 / 80)
    local still = g.sweeps - sweeps
    t.truthy(still >= 8 and still <= 11, "held still: about 10 sweeps a second, not one a frame (" .. still .. ")")
    D.vx = 400 -- 5 cm a frame: 10 cm in two
    sweeps = g.sweeps
    g.frames(80, 1 / 80)
    local moving = g.sweeps - sweeps
    t.truthy(moving > still + 10, "moving 10 cm across tries again sooner (" .. moving .. ")")
    t.eq(m.hull.status().counts.lifts, 0)
    noErrors(g)
end)

t.test("a lift from a capsule that still reads crouched (the 2022 ducked landing: stood, pressed and lifted in one "
    .. "hook) sweeps 18 units and twice the hulls' difference, Half-Life's room test for the standing hull: under a "
    .. "2 m ceiling no lift, the capsule standing on the ground at the next hook; without one, a tap", function()
    local function landingTap(ceiling)
        local g, m, D = hullGame()
        duckOnGround(g, D)
        jump(g, D)
        D.keys.tap = true -- +ducktap with the duck key held: OpenAG's 2022 rule keeps the duck in the air
        untilRow(g, D, 1 / 80, 60, function(row)
            return row.wz < 0 and g.position.Z < 30
        end, "low on the way down")
        if ceiling then
            g.ceilingAt = function()
                return ceiling
            end
        end
        local landing = untilRow(g, D, 1 / 80, 20, walkingRow, "the landing")
        return g, m, D, landing
    end
    local g, m, D, landing = landingTap(200)
    t.eq(landing.crouched, true, "landed crouched")
    t.eq(landing.events[1].what, "stood")
    t.eq(landing.events[2].what, "pressed")
    t.truthy(landing.refusedLift, "the lift tried, and refused")
    t.eq(landing.state, D.duck.IN_DUCK, "Half-Life in the transition, on the ground")
    t.near(g.position.Z, fake.FLOOR_DIST, 1e-9, "put back")
    g.frame(1 / 80)
    t.eq(D.last().crouched, false, "the capsule standing on the ground (it fits under 2 m)")
    t.eq(D.last().mode, 1)
    t.eq(m.hull.status().counts.lifts, 0)
    -- Without the ceiling: the tap, swept 135 cm.
    g, m, D, landing = landingTap(nil)
    t.truthy(landing.lifted, "lifted")
    t.eq(landing.base, true, "the stand-up keeps the base at the lifted place")
    local row = untilRow(g, D, 1 / 80, 3, fallingRow, "in the air")
    t.eq(row.crouched, false, "stood up")
    local free = landing.liftAt.Z + landing.wz * landing.dt - 0.5 * D.P.gravity * landing.dt ^ 2
    t.near(row.at.Z - free, DELTA, 1e-6, "the middle 45 cm up off the free path: the feet kept")
    t.eq(m.hull.status().counts.lifts, 1)
    local again = untilRow(g, D, 1 / 80, 40, walkingRow, "the tap's landing")
    t.near((again.frame - landing.frame) / 80, 0.2002, 1 / 80 + 1e-9, "a tap's flight")
    t.contains(g.log, "swept 135 cm up, then placed 37.9 cm up")
    t.eq(g.popups, 0)
    noErrors(g)
end)

-------------------------------------------------------------------------------------------
-- The eye: the drop re-based after Unreal's hull changes in the air

t.test("after a hull change Unreal makes in the air (C12's stand-up with a jump and duck with a jump, the 2022 ducked "
    .. "landing's tap, an engine that un-crouches at take-off) the eye stays Half-Life's within 1 cm on every frame "
    .. "of the flight, and none is a pop-up", function()
    -- A stand-up and a jump in one update.
    local g, m, D = hullGame()
    duckOnGround(g, D)
    g.frames(5, 1 / 80)
    local first = #D.rows
    g.keys.LeftControl = false
    D.keys.jump = true
    g.frame(1 / 80)
    D.keys.jump = false
    untilRow(g, D, 1 / 80, 80, walkingRow, "the landing")
    g.frames(5, 1 / 80)
    eyeKept(rowsFrom(D, first), "a stand-up with a jump")
    t.eq(m.hull.status().counts.popups, 0)
    -- A duck that completes on the jump's update.
    g, m, D = hullGame()
    g.keys.LeftControl = true
    first = #D.rows + 1
    D.before = function(driver, d)
        driver.keys.jump = d.state == driver.duck.IN_DUCK and d.timer - 1000 / driver.P.rate <= 600 + 1e-6
    end
    untilRow(g, D, 1 / 80, 200, function(r)
        return r.leaving
    end, "the duck and the jump")
    D.before, D.keys.jump = nil, false
    untilRow(g, D, 1 / 80, 80, walkingRow, "the landing")
    g.frames(5, 1 / 80)
    eyeKept(rowsFrom(D, first), "a duck with a jump")
    t.eq(m.hull.status().counts.popups, 0)
    -- The 2022 ducked landing under +ducktap: stood, pressed and lifted in one hook.
    g, m, D = hullGame()
    duckOnGround(g, D)
    first = #D.rows
    jump(g, D)
    D.keys.tap = true
    local landing = untilRow(g, D, 1 / 80, 80, walkingRow, "the ducked hop's landing")
    t.truthy(landing.lifted, "the tap")
    D.keys.tap = false
    untilRow(g, D, 1 / 80, 40, walkingRow, "the tap's landing")
    g.frames(5, 1 / 80)
    eyeKept(rowsFrom(D, first), "the 2022 ducked landing's tap")
    t.eq(m.hull.status().counts.popups, 0)
    -- An engine that doesn't let a falling character crouch stands it up at take-off, on the floor.
    g, m, D = hullGame({ noAirCrouch = true })
    duckOnGround(g, D)
    first = #D.rows
    local uncrouches = g.uncrouches
    jump(g, D)
    t.eq(g.uncrouches, uncrouches + 1, "stood up at take-off")
    t.eq(D.last().crouched, false)
    untilRow(g, D, 1 / 80, 80, walkingRow, "the landing")
    g.frames(5, 1 / 80)
    t.eq(D.last().crouched, true, "crouched again on the ground")
    eyeKept(rowsFrom(D, first), "a ducked hop with no crouch in the air")
    t.eq(m.hull.status().counts.popups, 0)
    t.eq(m.hull.status().counts.gameUncrouches, 0, "the engine's take-off rule isn't the game standing it up")
    t.absent(g.log, "higher than its place in the air")
    noErrors(g)
end)

t.test("a stand-up Unreal makes in the air by moving the character up (its floor test and the mod's query "
    .. "disagree) is counted and logged, and the eye re-based all the same", function()
    local g, m, D = duckedInTheAir(1 / 80, { floorQueryMisses = true })
    local first = #D.rows
    floorAt(g, 30)
    g.keys.LeftControl = false
    g.frame(1 / 80)
    t.eq(D.last().roomBelow, true, "the query found room")
    g.frame(1 / 80)
    t.eq(g.popups, 1, "Unreal moved it up")
    t.eq(m.hull.status().counts.popups, 1)
    t.contains(g.log, "Unreal stood the character up 27.0 cm higher than its place in the air")
    g.frames(30, 1 / 80)
    eyeKept(rowsFrom(D, first), "a pop-up")
end)

-------------------------------------------------------------------------------------------
-- Unreal's answers

t.test("a stand-up Unreal refuses makes Half-Life fully ducked from the transition too: +ducktap (and +ducktap with "
    .. "the duck key) under a 120 cm ceiling, ducked: every update fully ducked from the next hook on, at 60, 80 and "
    .. "144 fps", function()
    for _, fps in ipairs({ 60, 80, 144 }) do
        for _, withCtrl in ipairs({ false, true }) do
            local what = string.format("%d fps%s", fps, withCtrl and ", the duck key held" or "")
            local g, m, D = hullGame()
            duckOnGround(g, D, 1 / fps)
            local feet = g.position.Z
            g.ceilingAt = function()
                return feet + 120
            end
            g.frames(3, 1 / fps)
            g.keys.LeftControl = withCtrl
            D.keys.tap = true
            local refused = untilRow(g, D, 1 / fps, 5, function(r)
                return r.answer == "stand refused"
            end, "the refusal, " .. what)
            t.eq(refused.stateBefore, D.duck.DUCKED, "confirmed fully ducked, " .. what)
            local start = #D.rows
            g.frames(fps, 1 / fps)
            for i = start + 1, #D.rows do
                local row = D.rows[i]
                t.eq(row.scaled, row.n, string.format("every update scaled, %s, frame %d", what, row.frame))
                t.falsy(row.lifted or row.refusedLift, "no tap under the ceiling, " .. what)
            end
            t.eq(D.last().crouched, true)
            t.eq(count(g.log, "No room to stand up (on the ground, under something)"), 1, "one line, " .. what)
            t.eq(m.hull.status().counts.standRefusals, 1)
            noErrors(g)
        end
    end
end)

t.test("a stand-up Unreal refuses in the air (something just above) leaves Half-Life fully ducked, the air closed to "
    .. "standing up, until Unreal's retry stands it up once it fell clear", function()
    local g, m, D = duckedInTheAir(1 / 80)
    untilRow(g, D, 1 / 80, 40, function(row)
        return row.wz <= 0
    end, "the top of the hop")
    local top = g.position.Z + 102 -- the crouched capsule's top
    g.ceilingAt = function()
        return top + 20 -- room for it, not for the standing capsule
    end
    g.keys.LeftControl = false
    g.frame(1 / 80)
    t.eq(D.last().roomBelow, true, "the floor far below")
    t.eq(D.last().state, D.duck.STANDING, "Half-Life stands up at once")
    local row = untilRow(g, D, 1 / 80, 3, function(r)
        return r.answer == "stand refused"
    end, "Unreal's refusal")
    t.eq(row.stateBefore, D.duck.DUCKED, "fully ducked again")
    t.eq(row.room.air, false, "the air closed")
    t.contains(g.log, "No room to stand up (in the air, under something)")
    local first = #D.rows
    row = untilRow(g, D, 1 / 80, 40, standingRow, "Unreal's retry")
    for i = first, #D.rows - 1 do
        t.eq(D.rows[i].state, D.duck.DUCKED, "ducked while Unreal refuses")
    end
    t.eq(row.mode, FALLING, "in the air, fallen clear of it")
    t.eq(row.answer, "stood late", "a stand-up Unreal had refused, made now")
    t.eq(row.state, D.duck.STANDING)
    t.eq(m.hull.status().refusedAir, false)
    t.eq(g.popups, 0)
    noErrors(g)
end)

t.test("a value the game writes while the mod acts (its own CrouchedHalfHeight) is taken at the next refresh and "
    .. "is what goes back; a bCanCrouch that doesn't take the mod's write is said once", function()
    local g, _, D = hullGame()
    local p = fake.props(g.cmc)
    p.CrouchedHalfHeight = 70 -- the game's own, written meanwhile
    g.frames(45, 1 / 80)
    t.eq(p.CrouchedHalfHeight, 51, "the mod's again at the refresh")
    D.release()
    t.eq(p.CrouchedHalfHeight, 70, "the game's latest goes back")
    g, _, D = hullGame({}, nil)
    g.frames(2, 1 / 80)
    D.release()
    fake.onRead(g.cmc, "NavAgentProps", function()
        fake.props(g.cmc).NavAgentProps.bCanCrouch = false -- an engine that ignores the write
    end)
    g.frames(45, 1 / 80)
    t.eq(count(g.log, "NavAgentProps.bCanCrouch didn't take the mod's true"), 1)
    D.release()
    t.falsy(g.shared[JOURNAL]:find("NavAgentProps", 1, true), "nothing to put back")
end)

t.test("a character first seen crouched (the game's crouch) takes its standing size from its class default, and the "
    .. "values for the mod's crouch are written at once; without the class default, once it reads standing", function()
    local g, m, D = hullGame({ crouchedAtStart = true })
    local p = fake.props(g.cmc)
    t.eq(m.hull.standHalf(), 96, "the class default's 96, not the crouched capsule's 60")
    t.eq(p.CrouchedHalfHeight, 51, "the mod's crouched half height at once")
    t.eq(D.rows[1].answer, "crouched by the game")
    t.eq(D.rows[1].state, D.duck.DUCKED)
    t.eq(p.bWantsToCrouch, true, "the game's wish, left alone")
    t.falsy(g.shared[JOURNAL]:find("NavAgentProps", 1, true), "crouching was allowed already: nothing to put back")
    g.gameCrouch(false)
    local row = untilRow(g, D, 1 / 80, 5, standingRow, "the game's stand-up")
    t.eq(row.answer, "stood by the game")
    t.eq(m.hull.standHalf(), 96)
    g.keys.LeftControl = true -- a duck of the mod's own now
    row = untilRow(g, D, 1 / 80, 200, crouchedRow, "the mod's crouch")
    t.eq(row.answer, "ducked")
    t.near(g.c.capsule:GetScaledCapsuleHalfHeight(), 51, 1e-9, "at the mod's crouched size")
    -- Without the class default: nothing known, nothing written, until the capsule stands.
    g, m, D = hullGame({ crouchedAtStart = true, noClassDefault = true })
    p = fake.props(g.cmc)
    t.eq(m.hull.standHalf(), nil)
    t.eq(p.CrouchedHalfHeight, 60, "the game's own still")
    g.gameCrouch(false)
    untilRow(g, D, 1 / 80, 5, standingRow, "the game's stand-up")
    t.eq(m.hull.standHalf(), 96, "measured standing")
    t.eq(p.CrouchedHalfHeight, 51, "and written then")
    noErrors(g)
end)

t.test("the frame of braking ALS's stance change brings back is given back on the next hook: up to 10 % of the "
    .. "speed and 5000 cm/s2 over the frame, in the same direction; not more, nor a turn, nor without the mod's hull "
    .. "change, nor without KeepSpeed", function()
    local g, m, D = hullGame()
    D.vx = 400
    g.frames(5, 1 / 80)
    local row = duckOnGround(g, D)
    t.eq(row.answer, "ducked")
    t.near(row.rx, 400 + 1 / 80 - 2000 / 80, 1e-6, "ALS's curve braked the frame of the crouch")
    t.near(row.vx, 400, 1e-9, "given back")
    t.near(row.vy, 0, 1e-12)
    t.contains(g.log, "ALS braked the character for one frame as it crouched: 10 u/s, given back")
    g.keys.LeftControl = false
    row = untilRow(g, D, 1 / 80, 5, standingRow, "the stand-up")
    t.near(row.vx, 400, 1e-9, "and as it stood up")
    t.contains(g.log, "ALS braked the character for one frame as it stood up: 10 u/s, given back")
    t.eq(m.hull.status().counts.brakeGiven, 2)
    -- More than a frame of braking: a wall, or the game.
    g.afterMove = function(v)
        if fake.props(g.pawn).bIsCrouched and g.stanceChanges > 2 and not g.walled then
            g.walled = true
            v.X = v.X - 100
        end
    end
    row = duckOnGround(g, D)
    t.near(row.vx, row.rx, 1e-12, "not given back")
    t.contains(g.log, "ALS braked the character for one frame as it crouched: 50 u/s is more than a frame of braking, "
        .. "not given back")
    -- A turn.
    g.afterMove = function(v)
        if g.stanceChanges == 4 and not g.turned then
            g.turned = true
            v.Y = 30
        end
    end
    g.keys.LeftControl = false
    row = untilRow(g, D, 1 / 80, 5, standingRow, "the stand-up")
    t.near(row.vx, row.rx, 1e-12, "a turn: not given back")
    t.eq(m.hull.status().counts.brakeKept, 1, "nor counted as braking")
    -- A drop on a hook without a hull change.
    g.afterMove = function(v)
        v.X = v.X - 20
    end
    g.frame(1 / 80)
    g.frame(1 / 80)
    t.near(D.last().vx, D.last().rx, 1e-12, "no hull change: nothing")
    g.afterMove = nil
    -- Without KeepSpeed.
    g, m, D = hullGame(nil, { KeepSpeed = false })
    D.vx = 400
    row = duckOnGround(g, D)
    t.near(row.vx, row.rx, 1e-12, "KeepSpeed off")
    t.eq(m.hull.status().counts.brakeGiven, 0)
    -- Each limit on its own, at 80 fps (10 % of 400 cm/s is 40, 5000 cm/s2 over the frame
    -- 62.5): ALS's 25 and 25 more at 400 cm/s is over the share only, 25 and 55 more at
    -- 1000 cm/s over the rate only. (Fails with: either limit alone.)
    for _, c in ipairs({ { v = 400, extra = 25, what = "over 10 %" },
        { v = 1000, extra = 55, what = "over the rate" } }) do
        g, m, D = hullGame()
        D.vx = c.v
        g.frames(5, 1 / 80)
        g.afterMove = function(v)
            if fake.props(g.pawn).bIsCrouched and not g.walled then
                g.walled = true
                v.X = v.X - c.extra
            end
        end
        row = duckOnGround(g, D)
        t.truthy(g.walled, "the extra braking came")
        t.near(row.vx, row.rx, 1e-12, c.what .. ": not given back")
        t.eq(m.hull.status().counts.brakeGiven, 0, c.what .. ": nothing given back")
        t.eq(m.hull.status().counts.brakeKept, 1, c.what .. ": counted as more than a frame of braking")
    end
end)

-------------------------------------------------------------------------------------------
-- The detectors

local function wayIs(m, way)
    return m.hull.status().way == way
end

t.test("a game that doesn't let the character crouch: after 3 ducks without a crouch the hull change is given up "
    .. "for the session (one warning, a state line), and no crouch is asked for after", function()
    local g, m, D = hullGame({ noCrouch = true })
    t.contains(g.log, "Ducking: on: Unreal's crouch")
    for i = 1, 3 do
        g.keys.LeftControl = true
        g.frames(50, 1 / 80)
        t.eq(D.last().state, D.duck.DUCKED, "ducked " .. i)
        t.eq(D.last().crouched, false, "never crouched " .. i)
        t.eq(D.last().wish, true, "asked for " .. i)
        t.truthy(wayIs(m, "crouch"), "a duck counts once it ends " .. i)
        g.keys.LeftControl = false
        g.frames(5, 1 / 80)
    end
    t.truthy(wayIs(m, "none"), "given up")
    t.contains(g.log, "The game doesn't let the character crouch (3 ducks without a crouch; NavAgentProps.bCanCrouch "
        .. "false, CanCrouch() false)")
    t.contains(g.log, "Ducking: on: no hull change (the game doesn't let the character crouch: 3 ducks without a "
        .. "crouch; NavAgentProps.bCanCrouch false, CanCrouch() false)")
    local writes = fake.writes(g.cmc).bWantsToCrouch
    g.keys.LeftControl = true
    g.frames(60, 1 / 80)
    t.eq(D.last().state, D.duck.DUCKED, "Half-Life still ducks")
    t.eq(fake.writes(g.cmc).bWantsToCrouch, writes, "no crouch asked for")
    t.eq(fake.props(g.cmc).CrouchedHalfHeight, 60, "its values put back")
    t.eq(count(g.log, "The game doesn't let the character crouch"), 1, "one warning")
end)

t.test("a game that doesn't let a falling character crouch: after 3 ducked flights without a crouch in the air the "
    .. "hull changes on the ground only; the engine standing it up at take-off isn't the game standing it up",
    function()
    local g, m, D = hullGame({ noAirCrouch = true })
    duckOnGround(g, D)
    D.keys.jump = true -- with auto hop: a ducked hop at every landing
    local landings, was = 0, nil
    for _ = 1, 400 do
        g.frame(1 / 80)
        if D.last().mode == 1 and was == FALLING then
            landings = landings + 1
        end
        was = D.last().mode
        if wayIs(m, "ground") then
            break
        end
    end
    t.truthy(wayIs(m, "ground"), "the crouch on the ground only")
    t.eq(landings, 3, "after the third flight's landing")
    t.contains(g.log, "The game doesn't let a falling character crouch (3 ducks in the air without a crouch)")
    t.contains(g.log, "Ducking: on: Unreal's crouch on the ground, no hull change in the air")
    t.eq(m.hull.status().counts.gameUncrouches, 0)
    -- Ground only: nothing asked for in the air (nor at a landing whose jump leaves at once).
    local airWrites = 0
    for _ = 1, 120 do
        local before = fake.writes(g.cmc).bWantsToCrouch or 0
        g.frame(1 / 80)
        if D.last().mode == FALLING and (fake.writes(g.cmc).bWantsToCrouch or 0) > before then
            airWrites = airWrites + 1
        end
    end
    t.eq(airWrites, 0, "nothing asked in the air")
    t.eq(m.hull.status().counts.wishClears, 0, "a wish left as it is isn't a clear of the game's")
    D.keys.jump = false
    untilRow(g, D, 1 / 80, 80, walkingRow, "the last landing")
    local row = untilRow(g, D, 1 / 80, 3, crouchedRow, "crouched on the ground again")
    t.eq(row.mode, 1)
    t.truthy(wayIs(m, "ground"))
    -- A ducked jump from there: ALS clears the wish as the crouched character leaves the
    -- ground, and the mod leaves it so in the air (it asks no crouch there): not a clear.
    jump(g, D)
    g.frames(10, 1 / 80)
    t.eq(D.last().mode, FALLING)
    t.eq(fake.props(g.cmc).bWantsToCrouch, false, "left as ALS left it")
    t.eq(m.hull.status().counts.wishClears, 0)
    untilRow(g, D, 1 / 80, 80, walkingRow, "the landing")
    g.frame(1 / 80)
    t.eq(fake.props(g.cmc).bWantsToCrouch, true, "asked again on the ground")
    noErrors(g)
end)

t.test("a game whose crouch flushes held keys: after 3 crouches after which the duck key read as let go, the hull "
    .. "change is given up; a key still read down after a crouch starts the count again", function()
    local g, m, D = hullGame({ crouchFlushesKeys = true })
    for i = 1, 3 do
        duckOnGround(g, D)
        g.frames(3, 1 / 80)
        t.eq(D.last().duckKey, false, "the key reads as let go after crouch " .. i)
        g.keys.LeftControl = false
        g.frames(10, 1 / 80)
    end
    t.truthy(wayIs(m, "none"))
    t.contains(g.log, "The duck key read as let go right after each crouch (3 times)")
    t.contains(g.log, "Ducking: on: no hull change (the duck key read as let go right after each crouch: the game "
        .. "may clear held keys when it crouches)")
    -- Without the flush, a key held after its crouch keeps the count at 0.
    g, m, D = hullGame()
    for _ = 1, 4 do
        duckOnGround(g, D)
        g.frames(3, 1 / 80)
        g.keys.LeftControl = false
        g.frames(10, 1 / 80)
    end
    t.truthy(wayIs(m, "crouch"))
    t.eq(m.hull.status().counts.flushSuspects, 0)
end)

t.test("something in the game standing the character up while the mod holds the crouch: counted, asked again, and "
    .. "3 times within 10 s give the hull change up", function()
    local g, m, D = hullGame({ gameUncrouches = 1 })
    duckOnGround(g, D)
    local row = untilRow(g, D, 1 / 80, 100, function(r)
        return r.answer == "uncrouched by the game"
    end, "the game's stand-up")
    t.eq(row.mode, 1)
    t.contains(g.log, "Something in the game stood the character up while the mod kept it ducked")
    g.frame(1 / 80)
    t.eq(D.last().crouched, true, "asked again: crouched again")
    untilRow(g, D, 1 / 80, 400, function()
        return wayIs(m, "none")
    end, "given up")
    t.eq(m.hull.status().counts.gameUncrouches, 3)
    t.contains(g.log, "Something in the game stood the character up 3 times in 10 s while the mod kept it ducked")
    t.eq(fake.props(g.cmc).bWantsToCrouch, false, "the wish given up")
end)

-------------------------------------------------------------------------------------------
-- Handing back, restarts, world changes

t.test("handing back under something low: the wish cleared, every value back as the game had it, the capsule left "
    .. "crouched for Unreal, which stands it up once out from under, without the mod", function()
    local g, m, D = hullGame()
    local p = fake.props(g.cmc)
    local game = { CrouchedHalfHeight = 60, bCanWalkOffLedgesWhenCrouching = false, bCanCrouch = false }
    duckOnGround(g, D)
    t.eq(p.CrouchedHalfHeight, 51)
    local feet = g.position.Z
    g.ceilingAt = function()
        return feet + 120
    end
    D.release()
    D.active = false
    t.eq(p.bWantsToCrouch, false, "the wish cleared")
    t.eq(p.CrouchedHalfHeight, game.CrouchedHalfHeight)
    t.eq(p.bCanWalkOffLedgesWhenCrouching, game.bCanWalkOffLedgesWhenCrouching)
    t.eq(p.NavAgentProps.bCanCrouch, game.bCanCrouch)
    t.eq(g.shared[JOURNAL], "", "nothing left in the journal")
    t.eq(m.hull.status().leftover, true, "the crouch still the mod's, for the next take-over")
    g.frames(10, 1 / 80)
    t.eq(fake.props(g.pawn).bIsCrouched, true, "no room: still crouched")
    g.ceilingAt = nil
    g.frame(1 / 80)
    t.eq(fake.props(g.pawn).bIsCrouched, false, "out from under: Unreal stands it up")
end)

t.test("a UE4SS mods restart in mid-duck: the new copy's first frame clears the wish and puts every value back "
    .. "from the journal (the field kind for NavAgentProps.bCanCrouch)", function()
    local g, _, D = hullGame()
    local p = fake.props(g.cmc)
    duckOnGround(g, D)
    local journal = g.shared[JOURNAL]
    t.truthy(journal:find("bWantsToCrouch", 1, true) and journal:find("NavAgentProps.bCanCrouch", 1, true))
    D.active = false -- the old copy is gone without handing back
    fake.useConfig(nil)
    g.restartMods(root)
    g.frame(1 / 80)
    t.contains(g.log, "Put back 4 of 4 game values the previous copy had changed")
    t.eq(p.bWantsToCrouch, false)
    t.eq(p.CrouchedHalfHeight, 60)
    t.eq(p.bCanWalkOffLedgesWhenCrouching, false)
    t.eq(p.NavAgentProps.bCanCrouch, false)
    g.frame(1 / 80)
    t.eq(fake.props(g.pawn).bIsCrouched, false, "and Unreal stood it up")
end)

t.test("a world change in mid-duck forgets everything without a game call", function()
    local g, m, D = hullGame()
    duckOnGround(g, D)
    D.active = false
    local calls, reads, writes = fake.counts.calls, fake.counts.reads, fake.counts.writes
    m.hull.forget()
    t.eq(fake.counts.calls, calls)
    t.eq(fake.counts.reads, reads)
    t.eq(fake.counts.writes, writes)
    m.journal.flush()
    t.eq(g.shared[JOURNAL], "", "nothing left to put back")
    t.eq(m.hull.status().owned, false)
    t.eq(m.hull.standHalf(), nil, "the character forgotten")
end)

t.test("the journal's field kind puts one field of a struct back, and journal.restorer adds a kind of a module's "
    .. "own (not the journal's own kinds)", function()
    local g = fake.newGame()
    local m = modules()
    local p = fake.props(g.cmc)
    p.NavAgentProps.bCanCrouch = true
    p.NavAgentProps.bCanJump = false
    local name = fullName(g.cmc)
    m.journal.note("field", name, "NavAgentProps.bCanCrouch", false)
    m.journal.note("context", name, "IMC_Fake", "Subsystem")
    m.journal.note("field", name, "NoStructHere", true) -- not a field: not put back
    m.journal.flush()
    local m2 = modules() -- a new copy of the mod
    local seen
    m2.journal.restorer("context", function(obj, id, value)
        seen = string.format("%s %s %s", tostring(fake.addressOf(obj) == fake.addressOf(g.cmc)), id, value)
    end)
    t.eq(m2.journal.load(), 3)
    local restored, total = m2.journal.restorePending()
    t.eq(total, 3)
    t.eq(restored, 2, "the field and the context")
    t.eq(p.NavAgentProps.bCanCrouch, false, "the field put back")
    t.eq(p.NavAgentProps.bCanJump, false, "the struct's other fields left alone")
    t.eq(seen, "true IMC_Fake Subsystem", "the module's restorer, with the object found by its full name")
    t.falsy(pcall(m2.journal.restorer, "prop", function() end), "the journal's own kinds can't be replaced")
    t.falsy(pcall(m2.journal.restorer, "a\tb", function() end))
end)

t.test("Overrides:adopt takes a value the engine copied from the mod's own for the mod's write, and puts back the "
    .. "game's value for it", function()
    local g = fake.newGame()
    local m = modules()
    local pawn = fake.props(g.pawn)
    local o = m.overrides.new()
    o:set(g.pawn, "BaseEyeHeight", 70.2) -- the mod's eye
    pawn.BaseEyeHeight = 30.2 -- Unreal's crouch writes the mod's CrouchedEyeHeight into it
    t.eq(o:adopt(g.pawn, "BaseEyeHeight", 30.2, 48), true)
    t.eq(o:set(g.pawn, "BaseEyeHeight", 70.2), false, "not taken for a value of the game's")
    t.eq(o:saved(g.pawn, "BaseEyeHeight"), 48, "the game's own crouched eye to put back")
    m.journal.flush()
    t.truthy(g.shared[JOURNAL]:find("BaseEyeHeight\tn48", 1, true), "and in the journal")
    o:restore()
    t.eq(pawn.BaseEyeHeight, 48, "put back")
    -- Without it, the mod's own crouched eye is what would come back.
    local plain = m.overrides.new()
    pawn.BaseEyeHeight = 64
    plain:set(g.pawn, "BaseEyeHeight", 70.2)
    pawn.BaseEyeHeight = 30.2
    plain:set(g.pawn, "BaseEyeHeight", 70.2)
    plain:restore()
    t.eq(pawn.BaseEyeHeight, 30.2, "(the bug adopt is for)")
    -- A new object at the address: a new entry.
    local again = m.overrides.new()
    again:set(g.pawn, "BaseEyeHeight", 70.2)
    fake.move(g.pawn, "/Game/Levels/Fake.Fake:PersistentLevel.Moved")
    t.eq(again:adopt(g.pawn, "BaseEyeHeight", 30.2, 50), true)
    t.eq(again:saved(g.pawn, "BaseEyeHeight"), 50)
    pawn.BaseEyeHeight = 30.2
    again:restore()
    t.eq(pawn.BaseEyeHeight, 50, "put back: its entry is the object as it is now")
    t.eq(m.overrides.new():adopt(fake.INVALID, "BaseEyeHeight", 1, 2), false, "not a usable object")
end)

-------------------------------------------------------------------------------------------
-- Ways, settings, errors

t.test("DuckHull = false changes no hull and Ducking = false does nothing at all; a way a detector chose lasts through "
    .. "a hand-back and a take-over (a battle), and F5 or F7 (hull.reset) start it again", function()
    local g, m, D = hullGame(nil, { DuckHull = false })
    local p = fake.props(g.cmc)
    t.contains(g.log, "Ducking: on: no hull change (DuckHull = false)")
    g.keys.LeftControl = true
    g.frames(60, 1 / 80)
    t.eq(D.last().state, D.duck.DUCKED, "Half-Life ducks")
    t.eq(D.last().crouched, false, "the capsule doesn't")
    t.eq(fake.writes(g.cmc).bWantsToCrouch, nil, "nothing asked")
    t.eq(fake.writes(g.cmc).CrouchedHalfHeight, nil, "nothing written")
    t.eq(p.NavAgentProps.bCanCrouch, false)
    jump(g, D)
    g.keys.LeftControl = false
    g.frame(1 / 80)
    t.eq(D.last().state, D.duck.STANDING, "no hull: the air is open to stand up in")
    t.eq(m.hull.status().way, "none")
    g, m, D = hullGame(nil, { Ducking = false })
    t.contains(g.log, "Ducking: off (Ducking = false)")
    g.keys.LeftControl = true
    g.frames(60, 1 / 80)
    t.eq(fake.writes(g.cmc).bWantsToCrouch, nil)
    t.eq(fake.writes(g.cmc).CrouchedHalfHeight, nil)
    t.eq(fake.writes(g.cmc).NavAgentProps, nil)
    t.eq(D.last().crouched, false)
    t.eq(m.hull.status().way, "off")
    -- A detector's way, through a hand-back, then F5.
    g, m, D = hullGame({ noCrouch = true })
    for _ = 1, 3 do
        g.keys.LeftControl = true
        g.frames(50, 1 / 80)
        g.keys.LeftControl = false
        g.frames(5, 1 / 80)
    end
    t.truthy(wayIs(m, "none"))
    D.release()
    g.frames(5, 1 / 80)
    t.truthy(wayIs(m, "none"), "kept through a hand-back and a take-over")
    m.hull.reset()
    D.release()
    g.frame(1 / 80)
    t.truthy(wayIs(m, "crouch"), "F5 or F7: the crouch again")
    t.eq(count(g.log, "Ducking: on: Unreal's crouch"), 2)
end)

t.test("errors: ducking the character that fails 30 hooks in a row is turned off with its clean-up (the hull handed "
    .. "back, no hull change) until F5; the lift's turn lifts off (+ducktap reads as up), the floor query's leaves "
    .. "every stand-up in the air for the ground", function()
    local g, m, D = hullGame()
    fake.breakOnWrite(g.cmc, "bWantsToCrouch")
    g.keys.LeftControl = true
    g.frames(80, 1 / 80)
    t.contains(g.log, "Error in ducking the character: ")
    t.contains(g.log, "Turned off ducking the character after 30 errors in a row")
    t.truthy(wayIs(m, "none"))
    t.contains(g.log, "Ducking: on: no hull change (ducking the character was turned off by its errors)")
    t.eq(fake.props(g.cmc).CrouchedHalfHeight, 60, "its values put back")
    t.eq(m.hull.status().stepOff, true)
    m.guard.reset()
    m.hull.reset()
    D.release()
    g.frame(1 / 80)
    t.truthy(wayIs(m, "crouch"), "F5: on again")
    -- The lift.
    g, m, D = hullGame()
    local feet = g.position.Z
    local moves = 0
    fake.method(g.pawn, "K2_SetActorLocation", fake.ufunction("K2_SetActorLocation", 4, function()
        moves = moves + 1
        error("K2_SetActorLocation broken on purpose")
    end))
    D.keys.tap = true
    g.frames(60, 1 / 80)
    t.contains(g.log, "Turned off the duck tap's lift after 30 errors in a row")
    t.eq(m.hull.liftOff(), true)
    t.eq(D.last().room.lift, false)
    t.eq(g.mode(), 1, "never lifted")
    t.near(g.position.Z, feet, 1e-12)
    local tried = moves
    g.frames(20, 1 / 80)
    t.eq(moves, tried, "no more tries: +ducktap reads as up")
    -- The floor below.
    g, m, D = duckedInTheAir(1 / 80, { floorQueryBroken = true })
    g.keys.LeftControl = false
    g.frames(34, 1 / 80)
    t.contains(g.log, "Turned off the floor below, for standing up in the air after 30 errors in a row")
    t.eq(D.last().mode, FALLING, "(still in the air)")
    t.eq(D.last().roomBelow, false, "off: no room below")
    t.eq(D.last().state, D.duck.DUCKED, "the duck waits for the ground")
    t.eq(g.popups, 0)
    t.eq(m.hull.status().floorOff, true)
    untilRow(g, D, 1 / 80, 40, walkingRow, "the landing")
    local row = untilRow(g, D, 1 / 80, 3, standingRow, "the stand-up on the ground")
    t.eq(row.answer, "stood")
end)

t.test("a ducked character walks off a ledge (the mod lets it, bCanWalkOffLedgesWhenCrouching) and stays crouched; "
    .. "without it the fake's walk keeps a crouched character on the ledge, as Unreal's does", function()
    local g = fake.newGame()
    local p = fake.props(g.cmc)
    local edge = 40
    local function ledge(x)
        if x < edge then
            return 0, 0, 0, 1
        end
        return -500, 0, 0, 1
    end
    g.terrain = ledge
    p.NavAgentProps.bCanCrouch, p.CrouchedHalfHeight, p.bWantsToCrouch = true, 51, true
    g.frame()
    p.CurrentMovementSettings.MovementCurve, p.BrakingDecelerationWalking = nil, 0 -- (no braking)
    p.Velocity.X = 300
    g.frames(30)
    t.eq(g.mode(), 1, "kept on the ledge")
    t.truthy(g.position.X < edge)
    p.bCanWalkOffLedgesWhenCrouching = true
    p.Velocity.X = 300
    g.frames(10)
    t.eq(g.mode(), FALLING, "off it with the flag")
    -- The mod's: crouched in the air after the walk-off, the wish ALS cleared asked again.
    local m, D
    g, m, D = hullGame()
    edge = g.position.X + 60
    g.terrain = ledge
    duckOnGround(g, D)
    D.vx = 300
    local row = untilRow(g, D, 1 / 80, 40, fallingRow, "off the ledge")
    t.eq(row.crouched, true, "crouched as it left")
    g.frames(5, 1 / 80)
    t.eq(D.last().crouched, true, "and in the air")
    t.eq(m.hull.status().counts.wishClears, 1, "ALS's clear at the walk-off, counted")
    noErrors(g)
end)

t.test("on a scaled capsule the crouched half height is the unscaled standing one less 18 units over the scale, so "
    .. "the hulls differ by 45 cm in the world; never under the radius and 1 cm", function()
    local g, m, D = hullGame({ capsuleScale = 1.25 })
    t.eq(m.hull.standHalf(), 120)
    t.near(m.hull.status().delta, DELTA, 1e-9)
    t.near(fake.props(g.cmc).CrouchedHalfHeight, 96 - DELTA / 1.25, 1e-9)
    local at = g.pawn:K2_GetActorLocation()
    duckOnGround(g, D)
    t.near(g.pawn:K2_GetActorLocation().Z, at.Z - DELTA, 1e-6, "the middle 45 cm lower")
    g, m = hullGame({ capsuleScale = 0.5 })
    t.near(fake.props(g.cmc).CrouchedHalfHeight, 36, 1e-9, "the radius (35) and 1")
    t.near(m.hull.status().delta, 48 - 18, 1e-9)
end)

t.test("the lines about what the game did: 3 of each kind until hull.logAgain (F7); counts for the status line "
    .. "since the last hull.takeStats, and for the report", function()
    local g, m, D = hullGame()
    D.vx = 400
    for _ = 1, 3 do
        duckOnGround(g, D)
        g.keys.LeftControl = false
        untilRow(g, D, 1 / 80, 5, standingRow, "standing")
    end
    t.eq(count(g.log, "ALS braked the character for one frame"), 3)
    t.eq(count(g.log, "(not logged again)"), 1)
    local stats = m.hull.takeStats()
    t.eq(stats.brakeGiven, 6)
    t.eq(stats.groundCrouches, 3)
    t.eq(stats.groundStands, 3)
    t.eq(m.hull.takeStats().brakeGiven, 0, "since the last call")
    m.hull.logAgain()
    duckOnGround(g, D)
    t.eq(count(g.log, "ALS braked the character for one frame"), 4, "F7 makes room")
    local status = m.hull.status()
    t.eq(status.way, "crouch")
    t.eq(status.owned, true)
    t.eq(status.standHalf, 96)
    t.eq(status.counts.brakeGiven, 7)
    t.eq(status.gameCrouchedValue, 60, "the game's crouched half height, for the report")
end)
