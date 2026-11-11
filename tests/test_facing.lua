-- The body faces where the character heads while it hops (BodyFollowsHop): main.lua
-- against the fake game, whose ALS turns the body in the air towards InAirRotation.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F6, F8 = 0x75, 0x77
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
                worst = math.max(worst, math.abs(turn(g.actorYaw, velocityYaw(g))))
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
            worst = math.max(worst, math.abs(turn(velocityYaw(g), g.actorYaw)))
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

t.test("at 144 fps, with frames that run no Half-Life update, the body's target turns smoothly and the body keeps up",
    function()
        local g = running() -- PhysicsRate 100
        g.press(F6)
        runTo(g, MAX_SPEED)
        g.keys.W = false
        g.keys.SpaceBar = true
        g.keys.D = true
        local dt = 1 / 144
        local last, biggestStep, worst, frames = nil, 0, 0, 0
        for i = 1, 144 * 8 do
            g.rotation.Yaw = g.rotation.Yaw + 180 * dt
            g.frame(dt)
            if g.mode() == 3 and i > 144 then
                local target = inAirYaw(g)
                if last then
                    biggestStep = math.max(biggestStep, math.abs(turn(last, target)))
                end
                last = target
                worst = math.max(worst, math.abs(turn(velocityYaw(g), g.actorYaw)))
                frames = frames + 1
            else
                last = nil
            end
        end
        t.truthy(frames > 600, frames .. " frames in the air")
        -- The heading turns up to about 3 degrees in a frame, and the lead varies by a
        -- few as frames with and without an update take turns. A rate measured over
        -- one frame alone made the target jump about 45 degrees there and back.
        t.truthy(biggestStep < 20, string.format("the target turned at most %.1f deg from one frame to the next",
            biggestStep))
        t.truthy(worst < 5, string.format("the body was at most %.1f deg off the hop direction", worst))
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
                worstLead = math.max(worstLead, math.abs(turn(velocityYaw(g), inAirYaw(g))))
            end
            local off = turn(velocityYaw(g), g.actorYaw)
            t.truthy(off <= 1e-9, string.format("the body hasn't gone past the new direction (%.1f deg)", off))
            t.truthy(not lastOff or off >= lastOff - 1e-9, "and only comes closer to it")
            lastOff = off
        end
        t.truthy(worstLead > 40 and worstLead <= 45 + 1e-9, string.format("led by up to %.1f deg", worstLead))
        noErrors(g)
    end)

t.test("a new run of hops starts its lead from nothing, not from the turn rate of the last one", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.keys.D = true
    g.frames(240, 1 / 60, function()
        g.rotation.Yaw = g.rotation.Yaw + 180 / 60
    end)
    -- Land, slow down and run off the other way.
    g.keys.SpaceBar, g.keys.D = false, false
    for _ = 1, 300 do
        g.frame()
        if g.mode() == 1 and g.speed() < 300 then
            break
        end
    end
    t.eq(g.mode(), 1)
    g.rotation.Yaw = g.rotation.Yaw + 120
    runTo(g, MAX_SPEED)
    g.frames(30)
    g.keys.W = false
    g.keys.SpaceBar = true
    g.frame() -- the mod's jump: straight on, and nothing steers in the air
    g.keys.SpaceBar = false
    local worst = 0
    for _ = 1, 10 do
        t.eq(g.mode(), 3)
        worst = math.max(worst, math.abs(turn(velocityYaw(g), inAirYaw(g))))
        g.frame()
    end
    t.truthy(worst < 1, string.format("the body's target was at most %.2f deg from where it heads", worst))
    noErrors(g)
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
        g.frames(60 * 20, 1 / 60, function()
            g.rotation.Yaw = g.rotation.Yaw + 180 / 60
            if g.mode() == 1 then
                hops = hops + 1
            end
        end)
        t.truthy(hops > 22, hops .. " hops")
        t.eq(#reads, 20, "one read for each hop that is logged")
        for _, vz in ipairs(reads) do
            -- At the top: the first frame whose vertical speed (gravity takes 33 cm/s a frame) no longer goes up.
            t.truthy(vz <= 0 and vz > -34, "read at the top of the hop, vertical speed " .. vz)
        end
        local offsets = bodyOffsets(g)
        t.eq(#offsets, 20)
        for _, off in ipairs(offsets) do
            t.eq(off, 0, "against where it headed in the frame before, not led")
        end
        t.eq(count(g.log, "further hops aren't logged"), 1)
        noErrors(g)
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

t.test("the report shows ALS's rotation values, the body's rotation and the engine's ways of turning it", function()
    local g = running()
    g.press(F6)
    runTo(g, MAX_SPEED)
    g.keys.SpaceBar = true
    g.frames(10)
    t.eq(g.mode(), 3)
    g.press(F8)
    local als = t.contains(g.log, "  ALS: ")
    t.truthy(als:find("ViewMode=0", 1, true) and als:find("Speed=8", 1, true), als)
    local rotation = t.contains(g.log, "  ALS rotation: TargetRotation=(Pitch=0.0 Yaw=")
    t.truthy(rotation:find("InAirRotation=(Pitch=0.0 Yaw=", 1, true), rotation)
    t.truthy(rotation:find("LastVelocityRotation=(Pitch=0.0 Yaw=", 1, true), rotation)
    t.truthy(rotation:find("AimYawRate=0", 1, true), rotation)
    t.contains(g.log, "Character:K2_GetActorRotation() = (Pitch=0.0 Yaw=")
    t.contains(g.log, "Character.bUseControllerRotationYaw = false")
    t.contains(g.log, "Movement.bOrientRotationToMovement = false")
    t.contains(g.log, "Movement.bUseControllerDesiredRotation = false")
    t.contains(g.log, "Movement.CurrentMovementSettings.RotationRateCurve = CurveFloat "
        .. "/Game/ALS/Curves/C_ALS_RotationRate.C_ALS_RotationRate, at 1, 2, 3: 3.333, 6.667, 10")
    -- A curve that can't be read, and none at all: the report goes on.
    fake.method(g.rotationCurve, "GetFloatValue", function()
        error("GetFloatValue failed")
    end)
    g.press(F8)
    t.contains(g.log, "C_ALS_RotationRate, at 1, 2, 3: ?, ?, ?")
    fake.props(g.cmc).CurrentMovementSettings.RotationRateCurve = fake.INVALID
    g.press(F8)
    t.contains(g.log, "Movement.CurrentMovementSettings.RotationRateCurve = (none)")
    t.eq(count(g.log, "end of diagnostics"), 3)
    noErrors(g)
end)
