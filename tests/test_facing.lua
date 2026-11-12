-- The body faces where the character heads while it hops (BodyFollowsHop): main.lua
-- against the fake game, whose ALS turns the body in the air towards InAirRotation.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F6, F7, F8 = 0x75, 0x76, 0x77
local SCALE = 2.5
local MAX_SPEED = 320 * SCALE
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone

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

-- The short way round from a to b, in degrees.
local function turn(a, b)
    return (b - a + 180) % 360 - 180
end

local function velocityYaw(g)
    local v = fake.props(g.cmc).Velocity
    return math.deg(math.atan(v.Y, v.X))
end

local function inAirYaw(g)
    return fake.props(g.pawn).InAirRotation.Yaw
end

-- The numbers the hop lines give for how far the body was from where it headed.
local function bodyOffsets(g)
    local offsets = {}
    for _, line in ipairs(g.log) do
        local off = line:match("body ([%+%-]%d+) deg from where it headed")
        if off then
            offsets[#offsets + 1] = tonumber(off)
        end
    end
    return offsets
end

-- Counts the mod's K2_SetActorRotation calls (camera.faceView), which still turn the body.
local function countSnaps(g)
    local counter = { n = 0 }
    fake.method(g.pawn, "K2_SetActorRotation", function(_, rotation, teleport)
        assert(type(rotation) == "table" and type(teleport) == "boolean")
        counter.n = counter.n + 1
        g.actorYaw = rotation.Yaw
        return true
    end)
    return counter
end

-- Third person: hops while holding D and turning right, as when air strafing. Returns
-- the largest gap between the body and the hop direction at the end of each hop.
local function strafeHopsInThirdPerson(config)
    local g = running(config)
    g.press(F6) -- third person
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    local worst, hops, lastMode = 0, 0, g.mode()
    g.frames(600, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 60
        local mode = g.mode()
        if lastMode == 3 and mode == 1 then
            -- Just landed: compare the body with the velocity of the landing.
            hops = hops + 1
            if hops > 1 then
                worst = t.max(worst, math.abs(turn(g.actorYaw, velocityYaw(g))))
            end
        end
        lastMode = mode
    end)
    return g, worst, hops
end

t.test("third person: hopping while turning, the body turns towards where the character heads", function()
    local g, worst, hops = strafeHopsInThirdPerson()
    t.truthy(hops >= 10, "hopped " .. hops .. " times")
    t.truthy(worst < 10, string.format("the body was at most %.1f deg off the hop direction at a landing", worst))
    t.contains(g.log, "Turning the character towards where it heads in the air (ALS's InAirRotation, yaw")
    local offsets = bodyOffsets(g)
    t.truthy(#offsets >= 10, "the hop lines say how far the body was from where it headed")
    for _, off in ipairs(offsets) do
        t.truthy(math.abs(off) <= 3, "at the top of a hop the body was " .. off .. " deg from where it headed")
    end
    noErrors(g)
end)

t.test("...and without BodyFollowsHop it keeps facing the way it took off, as before", function()
    local g, worst = strafeHopsInThirdPerson({ BodyFollowsHop = false })
    t.truthy(worst > 60, string.format("the body was up to %.1f deg off", worst))
    t.eq(fake.writes(g.pawn).InAirRotation, nil, "the mod never wrote ALS's in-air rotation")
    t.absent(g.log, "deg from where it headed")
    noErrors(g)
end)

t.test("the in-air rotation is set again after the mod's jump, which resets it", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.D = true
    g.rotation.Yaw = 90 -- the view turns away; the velocity still points along X
    g.actorYaw = 120 -- and the body faces elsewhere, as after a hop that turned
    g.keys.SpaceBar = true
    local resets = g.inAirResets
    g.frame() -- the mod's jump
    t.eq(g.mode(), 3)
    t.eq(g.inAirResets, resets + 1, "the mode change reset it")
    t.near(inAirYaw(g), velocityYaw(g), 3, "then the mod set the hop direction")
    t.near(fake.props(g.pawn).TargetRotation.Yaw, inAirYaw(g), 1e-9, "which ALS's update copied into TargetRotation")
    t.truthy(math.abs(turn(g.actorYaw, 0)) < 115, "and ALS began turning the body towards it")
    noErrors(g)
end)

t.test("third person: a jump without speed leaves ALS's in-air rotation alone", function()
    local g = running()
    g.press(F6)
    g.actorYaw = 120 -- the body faces somewhere; the character stands still
    local targetWrites = fake.writes(g.pawn).TargetRotation -- first person's, before F6
    g.keys.SpaceBar = true
    g.frame() -- the mod's jump
    g.keys.SpaceBar = false
    t.eq(g.mode(), 3)
    g.frames(10)
    t.eq(g.mode(), 3)
    t.near(inAirYaw(g), 120, 1e-9, "ALS's own: the body's rotation at take-off")
    t.near(g.actorYaw, 120, 1e-9, "so the body stays as it was")
    t.eq(fake.writes(g.pawn).InAirRotation, nil, "the mod didn't write it")
    t.eq(fake.writes(g.pawn).TargetRotation, targetWrites, "nor TargetRotation")
    noErrors(g)
end)

t.test("third person: a jump that speeds up in the air turns the body once it goes faster than 100 cm/s", function()
    local g = running()
    g.press(F6)
    g.actorYaw = 0
    g.keys.SpaceBar = true
    g.frame() -- the mod's jump, standing
    g.keys.SpaceBar = false
    g.keys.D = true -- air strafing from standing still
    local slowFrames, fastFrames = 0, 0
    for _ = 1, 30 do
        g.rotation.Yaw = g.rotation.Yaw + 360 / 60
        g.frame()
        t.eq(g.mode(), 3)
        if g.speed() <= 100 then
            slowFrames = slowFrames + 1
            t.eq(fake.writes(g.pawn).InAirRotation, nil, "too slow to head anywhere")
        else
            fastFrames = fastFrames + 1
            local lead = turn(velocityYaw(g), inAirYaw(g))
            t.truthy(lead >= 0 and lead <= 45 + 1e-9, string.format("towards where it heads (led by %.1f deg)", lead))
        end
    end
    t.truthy(slowFrames >= 3 and fastFrames >= 10, slowFrames .. " frames slow, then " .. fastFrames .. " fast")
    noErrors(g)
end)

t.test("first person faces the view in the air and in the jump frame, as in 0.2.6, and ALS's in-air rotation too",
    function()
        local g = running()
        local snaps = countSnaps(g)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.D = true
        g.keys.SpaceBar = true
        local jumps, airFrames = 0, 0
        for _ = 1, 300 do
            g.rotation.Yaw = g.rotation.Yaw + 90 / 60
            local before, n = g.mode(), snaps.n
            g.frame()
            local after = g.mode()
            if before == 3 or after == 3 then
                -- In the air, or the frame of a jump or of a landing.
                t.eq(snaps.n, n + 1, "the body was turned to the view")
                t.near(turn(inAirYaw(g), g.rotation.Yaw), 0, 1e-9, "and ALS's in-air rotation set to the view")
            end
            if after == 3 then
                if before == 3 then
                    airFrames = airFrames + 1
                else
                    jumps = jumps + 1
                end
                t.near(turn(g.actorYaw, g.rotation.Yaw), 0, 1e-9, "so ALS's update kept the body on the view")
            end
        end
        t.truthy(jumps >= 5, "hopped " .. jumps .. " times")
        t.truthy(airFrames >= 100, airFrames .. " frames in the air")
        t.contains(g.log, "Keeping the character turned to the view in the air too (ALS's InAirRotation, yaw")
        t.absent(g.log, "Turning the character towards where it heads")
        t.absent(g.log, "deg from where it headed", "the hop lines don't measure the body in first person")

        -- Paused in the air, the body still faces the view, as in 0.2.6.
        for _ = 1, 60 do
            if g.mode() == 3 then
                break
            end
            g.frame()
        end
        t.eq(g.mode(), 3)
        g.paused = true
        g.rotation.Yaw = g.rotation.Yaw + 40
        g.frame()
        t.near(turn(g.actorYaw, g.rotation.Yaw), 0, 1e-9, "paused in the air, the body faces the view")
        g.paused = false

        -- A jump without speed: the same.
        g.keys.SpaceBar, g.keys.D = false, false
        for _ = 1, 600 do
            g.frame()
            if g.mode() == 1 and g.speed() < 50 then
                break
            end
        end
        t.truthy(g.mode() == 1 and g.speed() < 50, "stopped")
        g.keys.SpaceBar = true
        g.frame()
        g.keys.SpaceBar = false
        t.eq(g.mode(), 3)
        g.rotation.Yaw = g.rotation.Yaw + 30
        g.frame()
        t.near(turn(inAirYaw(g), g.rotation.Yaw), 0, 1e-9, "ALS's in-air rotation follows the view without speed too")
        t.near(turn(g.actorYaw, g.rotation.Yaw), 0, 1e-9)
        noErrors(g)
    end)

t.test("first person: in a movement mode the mod leaves to the game (a mantle or a climb), the body isn't turned",
    function()
        local g = running()
        g.frames(30)
        local snaps = countSnaps(g)
        g.rotation.Yaw = 40
        g.frames(5)
        t.eq(snaps.n, 5, "walking, the body faces the view")
        local targets = fake.writes(g.pawn).TargetRotation
        -- None (ALS's mantle and climb), swimming, flying and a custom mode.
        for _, mode in ipairs({ 0, 4, 5, 6 }) do
            fake.props(g.cmc).MovementMode = mode
            local before = snaps.n
            g.frames(10, 1 / 60, function()
                g.rotation.Yaw = g.rotation.Yaw + 3
            end)
            t.eq(snaps.n, before, "mode " .. mode .. ": the game turns the body itself")
            t.eq(fake.writes(g.pawn).TargetRotation, targets, "mode " .. mode .. ": TargetRotation is left alone")
        end
        fake.props(g.cmc).MovementMode = 1
        g.frames(5)
        t.eq(snaps.n, 10, "back to walking, back to the view")
        noErrors(g)
    end)

t.test("first person with BodyFollowsView = false: the body isn't turned to the view, and in the air it heads where "
    .. "the character goes", function()
    local g = running({ BodyFollowsView = false })
    local snaps = countSnaps(g)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.D = true
    g.keys.SpaceBar = true
    g.frames(300, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 60
    end)
    t.eq(snaps.n, 0, "never turned to the view")
    t.contains(g.log, "Turning the character towards where it heads in the air")
    t.absent(g.log, "Keeping the character turned to the view")
    local offsets = bodyOffsets(g)
    t.truthy(#offsets >= 5, "the hop lines measure the body")
    for _, off in ipairs(offsets) do
        t.truthy(math.abs(off) <= 3, "at the top of a hop the body was " .. off .. " deg from where it headed")
    end
    noErrors(g)
end)

t.test("BodyFollowsHop = false: first person as in 0.2.6, without touching ALS's in-air rotation", function()
    local g = running({ BodyFollowsHop = false })
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.D = true
    g.keys.SpaceBar = true
    g.frames(30, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 60
    end)
    t.eq(g.mode(), 3)
    -- The mod snaps it to the view; ALS's update after it turns it a little towards
    -- the rotation it took off with.
    local off = math.abs(turn(g.actorYaw, g.rotation.Yaw))
    t.truthy(off > 0.1 and off < 10, string.format("near the view, %.2f deg off", off))
    t.eq(fake.writes(g.pawn).InAirRotation, nil, "the mod never wrote ALS's in-air rotation")
    t.absent(g.log, "Turning the character towards where it heads")
    t.absent(g.log, "Keeping the character turned to the view in the air")
    noErrors(g)
end)

t.test("with a fast grounded turn rate (40), a landing doesn't kick the body past the hop direction", function()
    -- ALS turns the body on the ground at its curve's rate times 1 to 3; a landing
    -- frame gets one such update, starting from TargetRotation.
    local g = running(nil, { groundRotationRate = 40 })
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    local dt, side, lastMode = 1 / 75, 1, g.mode()
    local worst, landings = 0, 0
    for i = 1, 75 * 12 do
        local mode = g.mode()
        if lastMode ~= 3 and mode == 3 then
            side = -side -- each hop the other way, strafing left and right in turn
        elseif lastMode == 3 and mode ~= 3 and i > 75 * 2 then
            -- Landed in the last frame, where ALS turned the body once on the ground.
            landings = landings + 1
            worst = t.max(worst, math.abs(turn(velocityYaw(g), g.actorYaw)))
        end
        lastMode = mode
        g.keys.D, g.keys.A = side > 0, side < 0
        g.rotation.Yaw = g.rotation.Yaw + side * 180 * dt
        g.frame(dt)
    end
    t.truthy(landings >= 10, landings .. " landings")
    t.truthy(worst < 5, string.format("the body was at most %.1f deg off the hop direction after a landing", worst))
    for _, off in ipairs(bodyOffsets(g)) do
        t.truthy(math.abs(off) <= 3, "at the top of a hop the body was " .. off .. " deg from where it headed")
    end
    noErrors(g)
end)

-- Third person at a steady frame rate (PhysicsRate 100 unless given): hops for 8
-- seconds while holding D and turning right at 180 degrees a second, which get faster
-- all the time (to over 800 u/s). Returns what the frames in the air showed after the
-- first second. While slower than `slow` u/s: slowStep, the biggest turn of the body's
-- target from one frame to the next, and slowOff, the furthest the body was from the
-- hop direction. Faster: fastStep. Over all of it: off, and turnGap, the biggest
-- difference in one frame between how far the body turned and how far the hop
-- direction did, from the 13th frame of a hop on (when the landing's turn has faded),
-- and uneven, the same against how far the view turned.
local function strafeHopsAt(fps, slow, physicsRate)
    local g = running(physicsRate and { PhysicsRate = physicsRate })
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    local dt = 1 / fps
    local m = { slowStep = 0, slowOff = 0, fastStep = 0, off = 0, turnGap = 0, uneven = 0, slowFrames = 0,
        fastFrames = 0 }
    local lastTarget, lastHeading, airFrames = nil, nil, 0
    for i = 1, fps * 8 do
        g.rotation.Yaw = g.rotation.Yaw + 180 * dt
        local before = g.actorYaw
        g.frame(dt)
        if g.mode() == 3 and i > fps then
            local target, heading = inAirYaw(g), velocityYaw(g)
            local off = math.abs(turn(heading, g.actorYaw))
            local kind = g.speed() < slow * SCALE and "slow" or "fast"
            airFrames = airFrames + 1
            m[kind .. "Frames"] = m[kind .. "Frames"] + 1
            m.off = t.max(m.off, off)
            if kind == "slow" then
                m.slowOff = t.max(m.slowOff, off)
            end
            if lastTarget then
                m[kind .. "Step"] = t.max(m[kind .. "Step"], math.abs(turn(lastTarget, target)))
                if airFrames > 12 then
                    m.turnGap = t.max(m.turnGap, math.abs(turn(before, g.actorYaw) - turn(lastHeading, heading)))
                    m.uneven = t.max(m.uneven, math.abs(turn(before, g.actorYaw) - 180 * dt))
                end
            end
            lastTarget, lastHeading = target, heading
        else
            lastTarget, airFrames = nil, 0
        end
    end
    return g, m
end

t.test("at 144 fps, with frames that run no Half-Life update, the body's target turns as evenly as the hop direction "
    .. "and the body keeps up", function()
    local g, m = strafeHopsAt(144, 700)
    t.truthy(m.slowFrames > 600 and m.fastFrames > 200, m.slowFrames .. " and " .. m.fastFrames .. " frames in the air")
    -- About every third frame runs no update: the hop direction stays, and in the next
    -- frame it turns as far as the view did in that update's 10 ms, 1.8 degrees. The
    -- target does the same and no more, because the turn rate is that turn over the
    -- update's time, and kept in a frame that ran none. A rate from one frame alone
    -- made the target jump about 45 degrees there and back, and the turn over the
    -- frames' time since the last update about 22.
    t.truthy(m.slowStep < 4, string.format("the target turned at most %.1f deg from one frame to the next", m.slowStep))
    t.truthy(m.slowOff < 2.5, string.format("the body was at most %.1f deg off the hop direction", m.slowOff))
    -- Faster too: one update turns the velocity as far as the view turned in it up to
    -- about 1000 u/s. (While a frame's view was shared out among its updates, the
    -- target jumped by 11 degrees from about 730 u/s.)
    t.truthy(m.fastStep < 4, string.format("faster, the target turned at most %.1f deg in a frame", m.fastStep))
    t.truthy(m.off < 5, string.format("faster, the body was at most %.1f deg off the hop direction", m.off))
    noErrors(g)
end)

t.test("with one and two Half-Life updates a frame in turn (60 fps, and 80 fps with PhysicsRate 144), the body turns "
    .. "evenly near the hop direction, and its target turns with the hop direction, slow or fast", function()
    for _, case in ipairs({ { fps = 60, slow = 580 }, { fps = 80, slow = 540, physicsRate = 144 } }) do
        local g, m = strafeHopsAt(case.fps, case.slow, case.physicsRate)
        local at = string.format("at %d fps: ", case.fps)
        local perUpdate = 180 / (case.physicsRate or 100) -- the view's turn in one update
        t.truthy(m.slowFrames > 100 and m.fastFrames > 150, at .. m.slowFrames .. " and " .. m.fastFrames
            .. " frames in the air")
        -- Each update has the view of its own time, so the hop direction turns as far
        -- in every update, and in a frame as far as its one or two updates: the target
        -- too, its lead coming from the turn over the updates' time. (While a frame's
        -- view was shared out among its updates, the hop direction fell behind and
        -- caught up from about 600 u/s, and the target jumped 20 to 25 degrees.)
        t.truthy(m.slowStep < 2.2 * perUpdate and m.fastStep < 2.2 * perUpdate, string.format("%sthe target "
            .. "turned at most %.1f deg from one frame to the next, %.1f faster", at, m.slowStep, m.fastStep))
        -- ALS turns the body evenly, as the view turns, so it is ahead of the hop
        -- direction after a frame with one update and behind after one with two.
        t.truthy(m.uneven < 0.3, string.format("%sthe body's turn was within %.2f deg of the view's in every "
            .. "frame", at, m.uneven))
        t.truthy(m.turnGap < 1.1 * perUpdate, string.format("%sand within %.2f deg of the hop direction's", at,
            m.turnGap))
        t.truthy(m.off < 5, string.format("%sthe body was at most %.1f deg off the hop direction", at, m.off))
        noErrors(g)
    end
end)

t.test("changing between A and D twice a hop, the body is back on the hop direction within moments", function()
    -- As a player strafes, at 80 fps: D while the view turns right, A while it turns
    -- left, changing at each take-off and at the top of each hop. How far off the body
    -- gets depends on the number of 1/60 s frames before the hops, and repeats every
    -- three (5.2, 5.8 and 6.3 degrees at most): so the hops are played after 0, 1 and 2
    -- more, and the limit is for the worst of the three.
    local most = 0
    for extra = 0, 2 do
        local g = running()
        g.frames(extra)
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar = true
        local dt, side, lastMode, lastRise = 1 / 80, 1, g.mode(), 0
        local sinceChange, changes, worst, sum, frames = 1000, 0, 0, 0, 0
        for i = 1, 80 * 10 do
            local mode, rise = g.mode(), fake.props(g.cmc).Velocity.Z
            if (lastMode ~= 3 and mode == 3) or (mode == 3 and lastRise > 0 and rise <= 0) then
                side, sinceChange = -side, 0
                changes = changes + 1
            end
            lastMode, lastRise = mode, rise
            g.keys.D, g.keys.A = side > 0, side < 0
            g.rotation.Yaw = g.rotation.Yaw + side * 180 * dt
            g.frame(dt)
            sinceChange = sinceChange + 1
            if g.mode() == 3 and i > 80 then
                local off = math.abs(turn(velocityYaw(g), g.actorYaw))
                worst = t.max(worst, off)
                if sinceChange <= 16 then
                    sum, frames = sum + off, frames + 1
                end
            end
        end
        local at = string.format("%d frames more before the hops: ", extra)
        t.truthy(changes >= 25, at .. changes .. " changes")
        t.truthy(sum / frames < 1.9, string.format("%s%.2f deg off on average in the 0.2 s after a change", at,
            sum / frames))
        most = math.max(most, worst)
        noErrors(g)
    end
    -- A change turns the hop direction by up to about 10 degrees within two updates,
    -- which a lead of at most 45 degrees can't make up at once. With the turn rate
    -- averaged over 20 to 50 ms the body was up to 7 to 9 degrees off, and 2.5 to 5 on
    -- average over these 0.2 s: the reason the rate isn't averaged.
    t.truthy(most < 6.6, string.format("the body was at most %.1f deg off the hop direction", most))
end)

t.test("third person: after one very long frame in the air the body is where the character heads, not ahead of it",
    function()
        local g = running()
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.D = true
        g.keys.SpaceBar = true
        local long
        for _ = 1, 400 do
            g.rotation.Yaw = g.rotation.Yaw + 180 / 60
            g.frame()
            if g.mode() == 3 and fake.props(g.cmc).Velocity.Z > 300 and g.speed() > MAX_SPEED + 100 then
                -- Early in a hop, with room for a frame of 0.3 s before the landing. ALS turns
                -- the body all the way to its target in a frame that long (5 per second), so
                -- no lead is wanted: the lead goes by the frame's real length, not by the
                -- 0.1 s the mod counts of it.
                t.truthy(math.abs(turn(velocityYaw(g), inAirYaw(g))) > 10, "led while the frames are short")
                g.rotation.Yaw = g.rotation.Yaw + 180 * 0.3
                g.frame(0.3)
                long = true
                break
            end
        end
        t.truthy(long, "a long frame in the air")
        t.eq(g.mode(), 3)
        t.near(turn(velocityYaw(g), inAirYaw(g)), 0, 1e-6, "its target wasn't led")
        local off = turn(velocityYaw(g), g.actorYaw)
        t.truthy(math.abs(off) < 2, string.format("the body is %.1f deg from where it heads", off))
        noErrors(g)
    end)

t.test("third person: back on the ground after hops, the mod writes ALS's rotations no more", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.D = true
    g.keys.SpaceBar = true
    g.frames(150, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 60
    end)
    t.truthy(fake.writes(g.pawn).InAirRotation > 50, "it turned the body in the air")
    g.keys.SpaceBar, g.keys.D = false, false
    g.keys.W = true
    for _ = 1, 120 do
        g.frame()
        if g.mode() == 1 then
            break
        end
    end
    t.eq(g.mode(), 1, "landed")
    g.frames(2)
    local inAir, target = fake.writes(g.pawn).InAirRotation, fake.writes(g.pawn).TargetRotation
    local yaw = inAirYaw(g)
    -- Running on, turning the other way: ALS turns the body on the ground by itself.
    g.frames(90, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw - 120 / 60
    end)
    t.eq(g.mode(), 1)
    t.eq(fake.writes(g.pawn).InAirRotation, inAir, "no InAirRotation writes on the ground")
    t.eq(fake.writes(g.pawn).TargetRotation, target, "no TargetRotation writes on the ground")
    t.eq(inAirYaw(g), yaw)
    t.truthy(math.abs(turn(g.actorYaw, velocityYaw(g))) < 15, "the body follows the run")
    -- Paused in the air on the next hop: nothing is written either.
    g.keys.SpaceBar = true
    g.frames(8)
    t.eq(g.mode(), 3)
    inAir = fake.writes(g.pawn).InAirRotation
    g.paused = true
    g.frames(10)
    t.eq(fake.writes(g.pawn).InAirRotation, inAir, "no writes while paused")
    g.paused = false
    noErrors(g)
end)

t.test("a sudden turn, as off a wall, is led by at most 45 degrees, and the body follows without overshooting",
    function()
        local g = running()
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar = true
        g.frame()
        g.keys.SpaceBar = false
        g.frames(5)
        t.eq(g.mode(), 3)
        g.afterMove = function(v)
            g.afterMove = nil
            v.X, v.Y = -v.Y, v.X -- a wall turns the velocity 90 degrees (to the right)
        end
        local worstLead, lastOff = 0, nil
        for i = 1, 30 do
            g.frame()
            t.eq(g.mode(), 3)
            if i > 1 then -- (the target of the first frame was set before the wall)
                worstLead = t.max(worstLead, math.abs(turn(velocityYaw(g), inAirYaw(g))))
            end
            local off = turn(velocityYaw(g), g.actorYaw)
            t.truthy(off <= 1e-9, string.format("the body hasn't gone past the new direction (%.1f deg)", off))
            t.truthy(not lastOff or off >= lastOff - 1e-9, "and only comes closer to it")
            lastOff = off
        end
        t.truthy(worstLead > 40 and worstLead <= 45 + 1e-9, string.format("led by up to %.1f deg", worstLead))
        noErrors(g)
    end)

t.test("stopped in mid-air while it turns, as by a wall hit head on, the body settles on where it last headed, not "
    .. "on the led target", function()
    for _, hopOn in ipairs({ false, true }) do -- letting go of Space, or hopping on in place
        local g = running()
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar = true
        g.keys.D = true
        -- Where the character heads in each frame: the velocity the mod hands to Unreal.
        local heading
        local move = g.moveTick
        g.moveTick = function(step)
            heading = velocityYaw(g)
            return move(step)
        end
        local dt, air = 1 / 80, 0
        for i = 1, 80 * 8 do
            g.rotation.Yaw = g.rotation.Yaw + 180 * dt
            g.frame(dt)
            air = g.mode() == 3 and air + 1 or 0
            if i > 80 * 3 and air == 12 then
                break
            end
        end
        t.eq(air, 12, "early in a hop")
        -- The wall: Unreal's move stops short, and it sets the velocity from the distance moved.
        g.rotation.Yaw = g.rotation.Yaw + 180 * dt
        g.moveShare = 0.05
        g.frame(dt)
        g.moveShare = nil
        local last = heading
        t.truthy(g.speed() < 100, string.format("the wall left %.0f cm/s", g.speed()))
        t.truthy(turn(last, inAirYaw(g)) > 30, string.format("the body's target was led by %.1f deg",
            turn(last, inAirYaw(g))))
        local writes, targetWrites = fake.writes(g.pawn).InAirRotation, fake.writes(g.pawn).TargetRotation
        g.keys.D = false
        g.keys.SpaceBar = hopOn
        g.frame(dt) -- the first frame too slow to head anywhere
        t.eq(g.mode(), 3)
        t.near(turn(last, inAirYaw(g)), 0, 1e-9, "the body's target is now where it last headed")
        t.eq(fake.writes(g.pawn).InAirRotation, writes + 1, "written once")
        t.eq(fake.writes(g.pawn).TargetRotation, targetWrites + 1, "with TargetRotation, as on the frames before")
        local landings = g.landings
        g.frames(80 * 2, dt)
        t.eq(fake.writes(g.pawn).InAirRotation, writes + 1, "and not again, hopping in place or standing")
        t.truthy(g.landings > landings and g.speed() < 100, "it landed, and stays slow")
        t.near(turn(last, g.actorYaw), 0, 3, "the body ended where it last headed")
        noErrors(g)
    end
end)

t.test("...and when it gets faster again in the same flight, the lead starts from nothing", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    local heading, speed
    local move = g.moveTick
    g.moveTick = function(step)
        heading, speed = velocityYaw(g), g.speed()
        return move(step)
    end
    local dt = 1 / 80
    g.frames(80 * 3, dt, function()
        g.rotation.Yaw = g.rotation.Yaw + 180 * dt
    end)
    for _ = 1, 80 do
        if g.mode() == 3 and fake.props(g.cmc).Velocity.Z > 400 then
            break -- just after a take-off: time enough in this flight
        end
        g.rotation.Yaw = g.rotation.Yaw + 180 * dt
        g.frame(dt)
    end
    g.moveShare = 0.05
    g.frame(dt) -- the wall
    g.moveShare = nil
    g.keys.D = false
    g.frames(3, dt) -- too slow: the body's target is where it last headed
    t.truthy(speed < 100, string.format("too slow (%.0f cm/s)", speed))
    local writes = fake.writes(g.pawn).InAirRotation
    g.keys.D = true -- to the side of what the wall left: faster than 100 cm/s again
    g.frame(dt)
    t.eq(g.mode(), 3)
    t.truthy(speed > 100, string.format("faster again (%.0f cm/s)", speed))
    t.eq(fake.writes(g.pawn).InAirRotation, writes + 1, "the body's target is set again")
    t.near(turn(heading, inAirYaw(g)), 0, 1e-9, "to where it heads now, not led by the turn rate from before the wall")
    g.frames(5, dt)
    t.near(turn(heading, inAirYaw(g)), 0, 1, "and it stays there while it heads the same way")
    noErrors(g)
end)

t.test("a new run of hops starts its lead from nothing, not from the turn rate of the last one", function()
    -- A frame that runs a Half-Life update measures the rate anew, so an old rate can only
    -- show in a frame of the new run that runs none (above PhysicsRate frames a second),
    -- and only if the last run ended while its heading still turned. So the view turns
    -- until the landing, and the new hop is at 144 fps with Half-Life's updates shifted
    -- against the frames by 0 to 8 ms: at least one of those has a frame without an update
    -- right after the jump frame, whatever phase the hop starts at.
    local dt = 1 / 144
    for shift = 0, 8, 2 do
        local at = string.format("updates %d ms later: ", shift)
        local g = running()
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar, g.keys.D = true, true
        local lead = 0
        local function turning()
            if g.mode() == 3 then
                lead = math.abs(turn(velocityYaw(g), inAirYaw(g)))
            end
            g.rotation.Yaw = g.rotation.Yaw + 180 * dt
        end
        g.frames(144, dt, turning)
        g.keys.SpaceBar = false -- the run ends at the next landing, still turning
        for _ = 1, 2 * 144 do
            turning()
            g.frame(dt)
            if g.mode() == 1 then
                break
            end
        end
        t.truthy(lead > 20, string.format("%sthe last run's target was led by %.1f deg as it ended", at, lead))
        g.keys.D = false
        g.frames(3, dt)
        t.eq(g.mode(), 1, at .. "landed")
        g.frame((10 + shift) / 1000) -- on the ground: moves the updates against the frames
        g.keys.SpaceBar = true
        g.frame(dt) -- the mod's jump: straight on, and nothing steers in the air
        g.keys.SpaceBar = false
        local worst = 0
        for _ = 1, 10 do
            t.eq(g.mode(), 3, at .. "in the air")
            worst = t.max(worst, math.abs(turn(velocityYaw(g), inAirYaw(g))))
            g.frame(dt)
        end
        t.truthy(worst < 1, string.format("%sthe body's target was at most %.2f deg from where it heads", at, worst))
        noErrors(g)
    end
end)

t.test("hopping in place on a moving platform doesn't turn the body to the platform's way", function()
    for _, firstPerson in ipairs({ false, true }) do
        local g = running()
        if not firstPerson then
            g.press(F6)
        end
        g.rotation.Yaw = 30
        g.frames(2)
        local before = g.actorYaw or 0
        g.baseVelocity = { X = 0, Y = 300, Z = 0 }
        g.keys.SpaceBar = true
        g.frames(200)
        -- (In third person ALS's update on each landing frame, which sees the velocity
        -- over the ground before the mod takes the platform's out, turns the body a
        -- couple of degrees towards the platform's way; the mod doesn't add to that.)
        t.truthy(math.abs(turn(inAirYaw(g), firstPerson and 30 or before)) < 15, "facing about as before the hops")
        t.truthy(math.abs(turn(g.actorYaw or 0, 90)) > 45, "not the platform's way")
        noErrors(g)
    end
end)

t.test("running on a moving platform, the body heads where the character runs on it", function()
    local g = running()
    g.press(F6)
    g.baseVelocity = { X = 0, Y = 300, Z = 0 }
    runTo(g, MAX_SPEED) -- along X, relative to the platform
    g.keys.W = false
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    t.truthy(math.abs(velocityYaw(g)) > 15, "over the ground it goes sideways too")
    t.near(inAirYaw(g), 0, 1, "relative to the platform it runs along X")
    noErrors(g)
end)

t.test("with bStayBasedInAir the velocity stays relative to the platform, and is the hop direction", function()
    local g = running(nil, { stayBasedInAir = true })
    g.press(F6)
    g.baseVelocity = { X = 0, Y = 300, Z = 0 }
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.mode(), 3)
    t.near(inAirYaw(g), 0, 1)
    noErrors(g)
end)

t.test("walking off a moving platform: the body heads where the character went on it", function()
    local g = running()
    g.press(F6)
    g.position.Z = 1000 -- the platform is high above the fake's ground
    g.baseVelocity = { X = 0, Y = 300, Z = 0 }
    runTo(g, MAX_SPEED)
    g.keys.W = false
    local walk = g.moveTick
    g.moveTick = function(dt)
        g.moveTick = walk
        local v, pos = fake.props(g.cmc).Velocity, g.position
        g.pending = { X = 0, Y = 0, Z = 0 }
        pos.X = pos.X + v.X * dt / 2
        g.cmc:SetMovementMode(3, 0) -- adds the platform's velocity
        g.baseVelocity = nil
        pos.X = pos.X + v.X * dt / 2
    end
    g.frames(3)
    t.eq(g.mode(), 3)
    t.truthy(math.abs(velocityYaw(g)) > 15, "over the ground it goes sideways too")
    t.near(inAirYaw(g), 0, 1)
    noErrors(g)
end)

t.test("after root motion in the air, the platform the character left is no longer taken out of where it heads",
    function()
        local g = running()
        g.press(F6)
        g.rotation.Yaw = 90
        g.frames(2)
        g.baseVelocity = { X = 300, Y = 0, Z = 0 }
        runTo(g, MAX_SPEED) -- along Y, relative to the platform
        g.keys.W = false
        g.keys.SpaceBar = true
        g.frame() -- the mod's jump keeps the platform's velocity
        g.keys.SpaceBar = false
        g.baseVelocity = nil
        t.eq(g.mode(), 3)
        t.near(inAirYaw(g), 90, 1, "relative to the platform")
        -- The game plays root motion for a moment (the mod leaves the movement alone),
        -- which sets the velocity its own way.
        g.rootMotion = true
        g.frames(3)
        local v = fake.props(g.cmc).Velocity
        v.X, v.Y = 0, 800
        g.rootMotion = false
        g.frame()
        t.eq(g.mode(), 3)
        t.near(inAirYaw(g), 90, 1, "where it goes now")
        noErrors(g)
    end)

t.test("the hop lines read the body once per logged hop, at its top, against where it headed the frame before",
    function()
        local g = running()
        g.press(F6)
        g.frames(200)
        t.contains(g.log, "diagnostics (automatic", "the automatic report, which reads the body too, came first")
        -- A body that is exactly where the mod said the character heads, after each
        -- update in the air: then the hop lines say 0, and only then.
        local als = g.alsTick
        g.alsTick = function(dt)
            local p = fake.props(g.pawn)
            if g.mode() == 3 then
                g.actorYaw = p.TargetRotation.Yaw
                p.TargetRotation.Yaw = p.InAirRotation.Yaw
            else
                als(dt)
            end
        end
        local reads = {}
        fake.method(g.pawn, "K2_GetActorRotation", fake.ufunction("K2_GetActorRotation", 0, function()
            reads[#reads + 1] = fake.props(g.cmc).Velocity.Z -- what the mod writes in the air too
            return { Pitch = 0, Yaw = g.actorYaw or 0, Roll = 0 }
        end))
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar = true
        g.keys.D = true
        local hops = 0
        g.frames(60 * 26, 1 / 60, function()
            g.rotation.Yaw = g.rotation.Yaw + 180 / 60
            if g.mode() == 1 then
                hops = hops + 1
            end
        end)
        t.truthy(hops > 32, hops .. " hops")
        t.eq(#reads, 30, "one read for each hop that is logged")
        for _, vz in ipairs(reads) do
            -- At the top: the first frame whose vertical speed (gravity takes 33 cm/s a frame) no longer goes up.
            t.truthy(vz <= 0 and vz > -34, "read at the top of the hop, vertical speed " .. vz)
        end
        local offsets = bodyOffsets(g)
        t.eq(#offsets, 30)
        for _, off in ipairs(offsets) do
            t.eq(off, 0, "against where it headed in the frame before, not led")
        end
        t.eq(count(g.log, "further hops aren't logged"), 1)
        noErrors(g)
    end)

t.test("a long test: once the hop lines ran out, F7 has third-person hops logged with the body's offset again",
    function()
        local g = running()
        runTo(g, MAX_SPEED)
        g.keys.SpaceBar = true
        g.frames(60 * 22) -- over 30 hops in first person
        t.eq(count(g.log, "] Hop "), 30)
        g.press(F6)
        g.frames(60 * 5)
        t.eq(#bodyOffsets(g), 0, "the third-person hops after the 30th have no line")
        g.press(F7)
        g.frames(60 * 8)
        local offsets = bodyOffsets(g)
        t.truthy(#offsets >= 8, #offsets .. " hop lines with the body's offset after F7")
        t.truthy(#offsets <= 30, "at most 30 again")
        noErrors(g)
    end)

t.test("the hop lines' body angle is about 0 in slow turns and behind in fast ones, where the lead stops at 45 degrees",
    function()
        -- What CLAUDE.md and docs/TESTING.md say about reading the number.
        local function offsets(rate)
            local g = running()
            g.press(F6)
            runTo(g, MAX_SPEED)
            g.keys.W = false
            g.keys.SpaceBar = true
            g.keys.D = true
            local dt = 1 / 80
            g.frames(80 * 14, dt, function()
                g.rotation.Yaw = g.rotation.Yaw + rate * dt
            end)
            noErrors(g)
            local list = bodyOffsets(g)
            t.eq(#list, 20)
            return list
        end
        -- (A run's first hop, whose lead starts from nothing at its take-off, reads -2 at
        -- one frame phase in three: every update turns the heading by the view's turn in
        -- it, so at 80 fps it turns 1.5 degrees in one frame and 3 in another.)
        for i, off in ipairs(offsets(150)) do
            t.truthy(math.abs(off) <= (i == 1 and 2 or 1), "turning 150 deg/s the body was " .. off
                .. " deg from where it headed, hop " .. i)
        end
        for _, off in ipairs(offsets(300)) do
            t.truthy(off <= -8 and off >= -15, "turning 300 deg/s to the right the body was " .. off
                .. " deg from where it headed")
        end
    end)

t.test("a character without InAirRotation: said once, nothing else changes", function()
    local g = running(nil, { noInAirRotation = true })
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frames(120)
    t.eq(count(g.log, "The character has no InAirRotation"), 1)
    t.absent(g.log, "Turning the character towards where it heads")
    t.absent(g.log, "deg from where it headed")
    t.truthy(g.landings >= 2, "it hops")
    noErrors(g)
end)

t.test("a failing InAirRotation write turns that step off, and the movement goes on", function()
    local g = running()
    g.press(F6)
    fake.breakOnWrite(g.pawn, "InAirRotation")
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.D = true
    g.keys.SpaceBar = true
    g.frames(120, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 90 / 60
    end)
    t.contains(g.log, "Error in turning the character to where it heads")
    t.contains(g.log, "Turned off turning the character to where it heads after 30 errors")
    t.absent(g.log, "Turned off the Half-Life movement")
    t.truthy(g.speed() > MAX_SPEED, "still hopping and gaining speed")
    local tries = fake.writes(g.pawn).InAirRotation
    g.frames(60)
    t.eq(fake.writes(g.pawn).InAirRotation, tries, "not tried again")
end)

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

t.test("the report shows ALS's rotation values, the body's rotation and the engine's ways of turning it", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frames(10)
    t.eq(g.mode(), 3)
    local report = reportNow(g)
    local als = t.contains(report, "  ALS: ")
    t.truthy(als:find("ViewMode=0", 1, true) and als:find("Speed=8", 1, true), als)
    local rotation = t.contains(report, "  ALS rotation: TargetRotation=(Pitch=0.0 Yaw=")
    t.truthy(rotation:find("InAirRotation=(Pitch=0.0 Yaw=", 1, true), rotation)
    t.truthy(rotation:find("LastVelocityRotation=(Pitch=0.0 Yaw=", 1, true), rotation)
    t.truthy(rotation:find("AimYawRate=0", 1, true), rotation)
    t.contains(report, "Character:K2_GetActorRotation() = (Pitch=0.0 Yaw=")
    t.contains(report, "Character.bUseControllerRotationYaw = false")
    t.contains(report, "Movement.bOrientRotationToMovement = false")
    t.contains(report, "Movement.bUseControllerDesiredRotation = false")
    t.contains(report, "Movement.CurrentMovementSettings.RotationRateCurve = CurveFloat "
        .. "/Game/ALS/Curves/C_ALS_RotationRate.C_ALS_RotationRate, at 1, 2, 3: 3.333, 6.667, 10")
    t.contains(report, "end of diagnostics")
    -- A curve that can't be read, and none at all: the report goes on.
    fake.method(g.rotationCurve, "GetFloatValue", function()
        error("GetFloatValue failed")
    end)
    report = reportNow(g)
    t.contains(report, "C_ALS_RotationRate, at 1, 2, 3: ?, ?, ?")
    t.contains(report, "end of diagnostics")
    fake.props(g.cmc).CurrentMovementSettings.RotationRateCurve = fake.INVALID
    report = reportNow(g)
    t.contains(report, "Movement.CurrentMovementSettings.RotationRateCurve = (none)")
    t.contains(report, "end of diagnostics")
    noErrors(g)
end)
