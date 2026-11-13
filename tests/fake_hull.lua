-- A capsule that crouches, for tests/fake_game.lua (an extension: see "Extensions" there).
-- Every game the fake makes loads it (fake.EXTENSION_MODULES); while nothing asks for a
-- crouch it changes nothing, so a game that never crouches plays as one without it.
--
-- What it stands in for, from descriptions of Unreal 5.4's character movement (the design's
-- research; no engine code is in it), on the fake character (a capsule 96 cm half tall and
-- 35 cm round, its lowest point at g.position):
-- - the crouch wish (the movement component's bWantsToCrouch) is taken up at the start of
--   each movement update, before the move (UpdateCharacterStateBeforeMovement): a crouch if
--   allowed (NavAgentProps.bCanCrouch, walking, nav-walking or falling), with the capsule
--   CrouchedHalfHeight (at least its radius) half tall; with bCrouchMaintainsBaseLocation
--   (set at each movement mode change: true walking, false otherwise) the feet stay and the
--   middle drops, else the middle stays and the feet rise;
-- - an un-crouch when the wish is let go or the crouch is no longer allowed, back to the class
--   default's size: with the flag, standing on the same base if the standing capsule fits (on
--   the ground also a walking gap lower); without, standing at the same middle if it fits,
--   else on what a sphere of the radius swept down from the middle by the radius finds below
--   (Unreal's pop-up near a floor: the character moves up); refused under g.ceilingAt; tried
--   again after the move if the movement mode allows no crouch any more
--   (UpdateCharacterStateAfterMovement);
-- - at a crouch BaseEyeHeight becomes CrouchedEyeHeight, at a stand-up the class default's;
-- - ALS: the stance changes with the crouch, which brings the movement curve back for that
--   update and has ALS write MaxWalkSpeed and MaxWalkSpeedCrouched after it; entering the air
--   while crouched clears the wish (ALS's UnCrouch), and so does the game's jump action while
--   crouched on the ground (instead of Jump());
-- - a crouched character can't walk off a ledge without bCanWalkOffLedgesWhenCrouching;
-- - g.ceilingAt(x, y): the height of a ceiling's underside, or nil: it stops a walking
--   capsule taller than the room under it, a falling head, a stand-up and a swept move;
-- - the pawn's K2_SetActorLocation (a swept move stops 1 cm short of a ceiling or the
--   ground) and the movement component's K2_ComputeFloorDist (from the current capsule's
--   bottom, or the sweep distance if nothing is that close), CanCrouch, GetCrouchedHalfHeight,
--   the capsule's half heights and radius, and the character class's default object (looked
--   up by its path, made at the first lookup).
-- Options (fake.newGame's): noCrouch (no crouch at all; bCanCrouch kept false), noAirCrouch
-- (no crouch while falling: a crouched character that starts an update falling is
-- un-crouched), crouchFlushesKeys (keys held at a crouch read as up until pressed again),
-- gameUncrouches (seconds: the game clears the wish of a crouched character that often),
-- crouchedAtStart (the first character starts crouched by the game), capsuleScale,
-- noClassDefault, floorQueryBroken (it raises), floorQueryEmpty (it fills nothing),
-- floorQueryMisses (it finds nothing below, whatever is there).
-- Not Unreal's: the capsule is tested against the ground under its middle and g.ceilingAt
-- only (no walls, no edges), a swept move only goes straight, and nothing models the game's
-- own crouch handlers (its spring arm, input context or sounds).

local fake = require("fake_game")

local hull = {}

hull.STAND_HALF = 96 -- the class default's capsule half height (cm, unscaled)
hull.RADIUS = 35
-- CrouchedHalfHeight and CrouchedEyeHeight as the game has them before the mod writes its own
-- (ALS's character Blueprint's 60; Unreal's rule of 0.8 of it for the eye).
hull.GAME_CROUCHED_HALF = 60
hull.GAME_CROUCHED_EYE = 48
hull.DEFAULT_EYE = 64 -- the class default's BaseEyeHeight
hull.CLASS_DEFAULT = "/Script/Fake.Default__BP_jRPG_Character_World_C" -- (fake.class's path, Default__)
hull.ALS_SPEED = 375 -- what ALS writes into MaxWalkSpeed and MaxWalkSpeedCrouched (see fake_game)

local INFLATION = 0.001 -- Unreal tests a standing capsule this much taller
local STAND_GAP = 0.95 -- and puts it this far above what the sweep found below (half the least floor gap)
local SWEEP_BACK = 1 -- a blocked swept move stops this far short (cm)

local props = fake.props

local function offsetOf(c)
    local h = c.hull
    if not h then
        return 0
    end
    return (h.half - hull.STAND_HALF) * h.scale
end
hull.offsetOf = offsetOf

-- Unreal's CanCrouchInCurrentState for character c.
local function crouchAllowed(g, c)
    local p = props(c.cmc)
    if g.options.noCrouch or p.NavAgentProps.bCanCrouch ~= true then
        return false
    end
    local mode = p.MovementMode
    return mode == 1 or mode == 2 or (mode == 3 and not g.options.noAirCrouch)
end

-- Whether the standing capsule fits with its lowest point at feet, under the current place.
local function standingFits(g, c, feet)
    local tall = 2 * hull.STAND_HALF * c.hull.scale + INFLATION
    local x, y = g.position.X, g.position.Y
    local ceiling = g.ceilingAt and g.ceilingAt(x, y)
    if ceiling and feet + tall > ceiling then
        return false
    end
    return feet >= g.groundAt(x, y)
end

local function classDefaultEye(g)
    local cdo = rawget(g.statics, hull.CLASS_DEFAULT)
    return cdo and props(cdo).BaseEyeHeight or hull.DEFAULT_EYE
end

-- ALS's stance change: the new stance's movement settings, the curve back for this update and
-- the speeds written after it (bRequestMovementSettingsChange).
local function stance(g, c, crouching)
    local p = props(c.cmc)
    props(c.pawn).Stance = crouching and 1 or 0
    p.CurrentMovementSettings.MovementCurve = c.curve
    p.bRequestMovementSettingsChange = 1
    c.hull.stanceChanged = true
    g.stanceChanges = g.stanceChanges + 1
end

local function crouch(g, c)
    local h, p, pawn = c.hull, props(c.cmc), props(c.pawn)
    local half = math.max(p.CrouchedHalfHeight, hull.RADIUS)
    local delta = (h.half - half) * h.scale
    h.half = half
    if p.bCrouchMaintainsBaseLocation ~= true then
        g.position.Z = g.position.Z + delta -- the middle stays: the feet rise
    end
    pawn.bIsCrouched = true
    pawn.BaseEyeHeight = pawn.CrouchedEyeHeight
    stance(g, c, true)
    g.crouches = g.crouches + 1
    if g.options.crouchFlushesKeys then
        for name, down in pairs(g.keys) do
            if down == true then
                g.flushed[name] = true
            end
        end
    end
end

-- Back to the class default's size, if there is room. Returns whether it stood up.
local function uncrouch(g, c)
    local h, p, pawn = c.hull, props(c.cmc), props(c.pawn)
    local s = h.scale
    local delta = (hull.STAND_HALF - h.half) * s
    local feet = g.position.Z
    local stood
    if p.bCrouchMaintainsBaseLocation == true then
        if standingFits(g, c, feet) then
            stood = feet
        else
            local floor = p.CurrentFloor
            local walking = p.MovementMode == 1 or p.MovementMode == 2
            if walking and floor.bBlockingHit and floor.FloorDist > INFLATION then
                -- Something just overhead: once more, down by the walking gap.
                local lower = feet - (floor.FloorDist - INFLATION)
                if standingFits(g, c, lower) then
                    stood = lower
                end
            end
        end
    elseif standingFits(g, c, feet - delta) then
        stood = feet - delta -- in place: the same middle
    elseif delta > 0 then
        -- A sphere of the radius swept down from the middle by the radius: the standing
        -- capsule is tried on what it found, or where it ended.
        local r = hull.RADIUS * s
        local middle = feet + h.half * s
        local base = math.max(g.groundAt(g.position.X, g.position.Y), middle - 2 * r)
        local try = base + STAND_GAP + INFLATION
        if base <= middle - r and standingFits(g, c, try) then
            stood = try
            g.popups = g.popups + 1
        end
    end
    if not stood then
        g.refusedStands = g.refusedStands + 1
        return false
    end
    g.position.Z = stood
    h.half = hull.STAND_HALF
    pawn.bIsCrouched = false
    pawn.BaseEyeHeight = classDefaultEye(g)
    stance(g, c, false)
    g.uncrouches = g.uncrouches + 1
    return true
end
hull.uncrouch = uncrouch

local function makeClassDefault()
    local path = hull.CLASS_DEFAULT
    local capsule = fake.object({ className = "CapsuleComponent", name = "CollisionCylinder",
        path = path .. ".CollisionCylinder", props = { CapsuleHalfHeight = hull.STAND_HALF,
            CapsuleRadius = hull.RADIUS } })
    return fake.object({ className = "BP_jRPG_Character_World_C", name = "Default__BP_jRPG_Character_World_C",
        path = path, props = { BaseEyeHeight = hull.DEFAULT_EYE, CrouchedEyeHeight = hull.GAME_CROUCHED_EYE,
            CapsuleComponent = capsule } })
end

function hull.install(g)
    g.ceilingAt = nil
    g.crouches, g.uncrouches, g.popups, g.refusedStands, g.stanceChanges = 0, 0, 0, 0, 0
    g.sweeps, g.floorQueries, g.crouchedJumps, g.ceilingStops, g.headHits = 0, 0, 0, 0, 0
    g.flushed = {} -- keys a crouch flushed: they read as up until let go (crouchFlushesKeys)
    --- The game's own crouch wish, as its stance action sets it.
    function g.gameCrouch(on)
        props(g.cmc).bWantsToCrouch = on and true or false
    end
    -- The class default object is made when it is first looked up, so that a game that
    -- never needs it makes no object more (the objects' addresses stay as they were).
    local meta = getmetatable(g.statics) or {}
    local before = meta.__index
    meta.__index = function(statics, path)
        if path == hull.CLASS_DEFAULT and not g.options.noClassDefault then
            local cdo = makeClassDefault()
            rawset(statics, path, cdo)
            return cdo
        end
        if type(before) == "function" then
            return before(statics, path)
        elseif type(before) == "table" then
            return before[path]
        end
        return nil
    end
    setmetatable(g.statics, meta)
end

function hull.character(g, c)
    local o = g.options
    c.hull = { half = hull.STAND_HALF, scale = o.capsuleScale or 1, stanceChanged = false, sinceGameUncrouch = 0 }
    local h = c.hull
    fake.method(c.capsule, "GetScaledCapsuleHalfHeight", fake.ufunction("GetScaledCapsuleHalfHeight", 0, function()
        return h.half * h.scale
    end))
    fake.method(c.capsule, "GetUnscaledCapsuleHalfHeight",
        fake.ufunction("GetUnscaledCapsuleHalfHeight", 0, function()
            return h.half
        end))
    fake.method(c.capsule, "GetScaledCapsuleRadius", fake.ufunction("GetScaledCapsuleRadius", 0, function()
        return hull.RADIUS * h.scale
    end))
    fake.method(c.capsule, "GetUnscaledCapsuleRadius", fake.ufunction("GetUnscaledCapsuleRadius", 0, function()
        return hull.RADIUS
    end))
    fake.set(c.cmc, "CrouchedHalfHeight", hull.GAME_CROUCHED_HALF)
    fake.set(c.cmc, "bWantsToCrouch", false)
    fake.set(c.cmc, "bCrouchMaintainsBaseLocation", props(c.cmc).MovementMode == 1)
    fake.set(c.cmc, "bCanWalkOffLedgesWhenCrouching", false)
    fake.set(c.cmc, "NavAgentProps", fake.struct({ bCanCrouch = false, bCanJump = true, bCanWalk = true,
        bCanSwim = true, bCanFly = false }))
    fake.method(c.cmc, "GetCrouchedHalfHeight", fake.ufunction("GetCrouchedHalfHeight", 0, function()
        return props(c.cmc).CrouchedHalfHeight
    end))
    fake.method(c.cmc, "K2_ComputeFloorDist", fake.ufunction("K2_ComputeFloorDist", 5,
        function(_, location, lineDistance, sweepDistance, sweepRadius, out)
            assert(type(location) == "table" and type(location.X) == "number" and type(location.Y) == "number"
                and type(location.Z) == "number", "CapsuleLocation is a vector, given as a table")
            assert(type(lineDistance) == "number" and type(sweepDistance) == "number"
                and type(sweepRadius) == "number", "the distances and the radius are numbers")
            assert(type(out) == "table", "FloorResult is an out parameter: it needs a table")
            g.floorQueries = g.floorQueries + 1
            if o.floorQueryBroken then
                error("K2_ComputeFloorDist broken on purpose")
            end
            if o.floorQueryEmpty then
                return -- (UE4SS filled nothing)
            end
            local dist = location.Z - offsetOf(c) - g.groundAt(location.X, location.Y)
            if o.floorQueryMisses then
                dist = sweepDistance -- (a query that misses what Unreal's own test will hit)
            end
            dist = math.min(math.max(dist, 0), sweepDistance)
            out.FloorDist = dist
            out.bBlockingHit = dist < sweepDistance
        end))
    fake.set(c.pawn, "bIsCrouched", false)
    fake.set(c.pawn, "CrouchedEyeHeight", hull.GAME_CROUCHED_EYE)
    fake.method(c.pawn, "CanCrouch", fake.ufunction("CanCrouch", 0, function()
        return props(c.pawn).bIsCrouched ~= true and props(c.cmc).NavAgentProps.bCanCrouch == true
            and not o.noCrouch
    end))
    fake.method(c.pawn, "K2_SetActorLocation", fake.ufunction("K2_SetActorLocation", 4,
        function(_, location, sweep, hit, teleport)
            assert(type(location) == "table" and type(location.X) == "number" and type(location.Y) == "number"
                and type(location.Z) == "number", "NewLocation is a vector, given as a table")
            assert(type(sweep) == "boolean" and type(teleport) == "boolean", "bSweep and bTeleport are booleans")
            assert(type(hit) == "table", "SweepHitResult is an out parameter: it needs a table")
            assert(c == g.c, "the fake moves only the character in use")
            local pos = g.position
            local x, y, z = location.X, location.Y, location.Z - offsetOf(c)
            if sweep then
                g.sweeps = g.sweeps + 1
                local time = 1
                local tall = 2 * h.half * h.scale
                if z > pos.Z then
                    local ceiling = g.ceilingAt and g.ceilingAt(x, y)
                    if ceiling and z + tall > ceiling then
                        local reach = math.max(pos.Z, ceiling - tall - SWEEP_BACK)
                        time = (reach - pos.Z) / (z - pos.Z)
                        z = reach
                    end
                elseif z < pos.Z then
                    local ground = g.groundAt(x, y)
                    if z < ground then
                        local reach = math.min(pos.Z, ground + SWEEP_BACK)
                        time = (pos.Z - reach) / (pos.Z - z)
                        z = reach
                    end
                end
                hit.Time = time
                hit.bBlockingHit = time < 1
            end
            pos.X, pos.Y, pos.Z = x, y, z
            return true
        end))
    if o.crouchedAtStart and c == g.c then
        -- The game's own crouch, from before the mod looks: its wish, its crouched height.
        local p = props(c.cmc)
        p.NavAgentProps.bCanCrouch = true
        p.bWantsToCrouch = true
        h.half = math.max(p.CrouchedHalfHeight, hull.RADIUS)
        props(c.pawn).bIsCrouched = true
        props(c.pawn).BaseEyeHeight = props(c.pawn).CrouchedEyeHeight
        props(c.pawn).Stance = 1
    end
end

function hull.input(g)
    for name in pairs(g.flushed) do
        if g.keys[name] ~= true then
            g.flushed[name] = nil
        end
    end
end

function hull.poll(g, how, name, value)
    if how == "down" and value and g.flushed[name] then
        return false
    end
    return value
end

function hull.gameJump(g)
    if props(g.pawn).bIsCrouched ~= true then
        return true
    end
    local p = props(g.cmc)
    if p.MovementMode == 1 or p.MovementMode == 2 then
        p.bWantsToCrouch = false -- ALS's jump action while crouched: UnCrouch() instead of Jump()
        g.crouchedJumps = g.crouchedJumps + 1
    end
    return false
end

function hull.beforeMove(g, dt)
    local c = g.c
    local h = c.hull
    local p, pawn = props(c.cmc), props(c.pawn)
    if g.options.noCrouch then
        p.NavAgentProps.bCanCrouch = false -- (an engine that keeps it off, whatever is written)
    end
    local crouched = pawn.bIsCrouched == true
    if crouched and g.options.gameUncrouches then
        h.sinceGameUncrouch = h.sinceGameUncrouch + dt
        if h.sinceGameUncrouch >= g.options.gameUncrouches then
            h.sinceGameUncrouch = 0
            p.bWantsToCrouch = false -- something in the game calls UnCrouch()
        end
    end
    if g.clearWishOnce then
        g.clearWishOnce = nil
        p.bWantsToCrouch = false
    end
    local allowed = crouchAllowed(g, c)
    if crouched and (p.bWantsToCrouch ~= true or not allowed) then
        uncrouch(g, c)
    elseif not crouched and p.bWantsToCrouch == true and allowed then
        crouch(g, c)
    end
end

function hull.moveShare(g, dt, share)
    if not g.ceilingAt then
        return share
    end
    local c = g.c
    local p = props(c.cmc)
    if p.MovementMode ~= 1 and p.MovementMode ~= 2 then
        return share
    end
    local pos, v = g.position, p.Velocity
    local x, y = pos.X + v.X * dt * share, pos.Y + v.Y * dt * share
    local ceiling = g.ceilingAt(x, y)
    if ceiling then
        local feet = g.groundAt(x, y) + (pos.Z - g.groundAt(pos.X, pos.Y))
        if feet + 2 * c.hull.half * c.hull.scale > ceiling then
            g.ceilingStops = g.ceilingStops + 1
            return 0 -- too tall to go under it
        end
    end
    return share
end

function hull.afterMove(g)
    local c = g.c
    local h = c.hull
    local p, pawn = props(c.cmc), props(c.pawn)
    if pawn.bIsCrouched == true and not crouchAllowed(g, c) then
        uncrouch(g, c) -- after the move: a movement mode that allows no crouch
    end
    if h.stanceChanged then
        h.stanceChanged = false
        if p.bRequestMovementSettingsChange ~= 0 then
            p.MaxWalkSpeedCrouched = hull.ALS_SPEED -- (fake_game writes MaxWalkSpeed after this)
        end
    end
    if p.MovementMode == 3 and g.ceilingAt then
        local ceiling = g.ceilingAt(g.position.X, g.position.Y)
        local tall = 2 * h.half * h.scale
        if ceiling and g.position.Z + tall > ceiling then
            g.position.Z = ceiling - tall
            if p.Velocity.Z > 0 then
                p.Velocity.Z = 0
            end
            g.headHits = g.headHits + 1
        end
    end
end

function hull.modeChanged(_, cmc, pawn, was, mode)
    if was == mode then
        return -- (Unreal changes nothing then)
    end
    local p = props(cmc)
    p.bCrouchMaintainsBaseLocation = mode == 1
    if mode == 3 and pawn and props(pawn).bIsCrouched == true then
        p.bWantsToCrouch = false -- ALS: into the air crouched, UnCrouch()
    end
end

function hull.heightOffset(_, c)
    return offsetOf(c)
end

function hull.canWalkOff(g)
    return not (props(g.pawn).bIsCrouched == true and props(g.cmc).bCanWalkOffLedgesWhenCrouching ~= true)
end

return hull
