-- Half-Life's ducking, one Half-Life update at a time, and OpenAG's client rules for the
-- duck and jump buttons of an update.
--
-- Pure Lua with no game or UE4SS dependency: physics.simulate calls it for every update,
-- movement.lua keeps its state between frames (st.duck), and tests/test_duck.lua runs it
-- outside the game. It is an independent implementation, written from descriptions of
-- Half-Life's movement and of OpenAG's input code; it contains no code from the Half-Life
-- SDK or from OpenAG.
--
-- What is in it:
-- - the three states (standing, in the transition, fully ducked) with the duck timer, the
--   view height's curve, the moves' scale while fully ducked, the duck tap's lift and the
--   stand-ups (duck.step);
-- - the duck button of each update from the keys the frame hook saw: a duck key held, a
--   duck notch (the button on exactly one update), +ducktap with its memory and the 2022
--   wipe (duck.frame, duck.button);
-- - the jump of each update, after its duck step, with Half-Life's "jump is down" mark, and
--   AutoHop as Bunnymod XT's autojump, which doesn't apply while a ducktap key is held
--   (duck.jumpButton, duck.jump);
-- - where Half-Life's eye is against the capsule, for the camera (the drops, duck.eyeOffset);
-- - how much lower than the standing hull's the ducked hull's floor lies on a slope, as
--   Valve's map compiler makes the two (duck.restGap).
-- Heights are in Half-Life units and times in milliseconds, except the drops and the eye's
-- offsets, which are in centimetres (s is the centimetres per unit, UnitScale).

local duck = {}

duck.STANDING, duck.IN_DUCK, duck.DUCKED = 0, 1, 2
-- Fully ducked, the moves count this much: Half-Life's three digits, not a third (a ducked
-- walk at MaxSpeed 320 is 106.56 u/s; a third would make it 106.67).
duck.SCALE = 0.333
-- The duck timer at a press, in ms, and where the duck on the ground is complete: 400 ms of
-- updates after the press's. Exactly 600 counts.
duck.TIMER, duck.DONE = 1000, 600
-- The view height standing and fully ducked, above Half-Life's origin, and how far the
-- origin moves at a duck or a stand-up on the ground (the two hulls' lower edges): units.
duck.VIEW_STAND, duck.VIEW_DUCK, duck.SHIFT = 28, 12, 18
-- OpenAG's rule for a duck key held while a ducktap key is held. true: its 2022 rule (the
-- owner's client, OpenAG's build of May 22, 2022): the duck key keeps the player ducked in
-- the air, and when the ducktap rule takes the button out while a duck key counts, the duck
-- keys stop counting until all of them are let go. false: its 2020 rule: never ducked in the
-- air while a ducktap key is held, and nothing stops counting. This is the one place to change.
duck.HELD_DUCK_UNDER_TAP = true

-- The timer's tolerance, in ms: 400 ms of updates whose length isn't a whole number of ms
-- can add up to a hair over 400 (96 updates of 1/240 s: 3.6e-12 ms over), and the duck would
-- complete an update late.
local TIMER_TOLERANCE = 1e-6
-- Half-Life's hulls' half heights, in units: 36 standing, 18 ducked (72 and 36 tall).
local STAND_HALF, DUCK_HALF = 36, 18
-- The room every stand-up and lift has when the caller passes none.
local OPEN = {}

--- A character's duck state: fully ducked when its capsule reads crouched (a crouch the
--- game made, or one left from before), else standing.
function duck.new(crouched)
    return {
        state = crouched and duck.DUCKED or duck.STANDING,
        timer = 0, -- ms
        view = crouched and duck.VIEW_DUCK or duck.VIEW_STAND, -- Half-Life's view height, units
        wasDown = false, -- the duck button of the update before
        tapHad = false, -- the last update under the ducktap rule had the duck button (kept between holds)
        wiped = false, -- the 2022 wipe: the duck keys don't count until all are let go
        notch = false, -- a duck notch waiting for its update
        -- this hook's keys, set by duck.frame
        keyHeld = false, tap = false, jumpKey = false, jumpNotch = false, autoHop = false,
        jumpWait = false, -- a jump notch from a hook that ran no update, waiting for the first that runs
        jumpWas = false, -- Half-Life's "jump is down" mark: a jump held at a take-over hops at once
        drop = 0, -- cm: how far Half-Life's origin is below the capsule's middle
        -- The duck button was down on every update of the last frame that ran one (the hull
        -- request reads it): physics.simulate writes it at the end of such a frame, and a frame
        -- with no update leaves it, so it lives here, with the state, and not in st.sim.
        held = false,
        -- The update before ended in the air for OpenAG's client, which builds the next duck
        -- button from it (duck.button's onGround), though the next update's first ground check
        -- finds the floor: running into a slope, the clip's rise was over 180 u/s at the
        -- update's last ground check and not half an update of gravity later. Kept here too,
        -- as that update can be a frame's last (physics.simulate writes and reads it).
        airSeen = false,
    }
end

--- A copy of the state (every field is a plain value), to run a frame's updates again.
function duck.copy(d)
    local c = {}
    for k, v in pairs(d) do
        c[k] = v
    end
    return c
end

--- The view height in the transition, from the timer: an ease-in, ease-out curve from 28 at
--- the press to -6 after 400 ms. -6 is the ducked 12 less the 18 the origin hasn't dropped
--- yet, so the eye ends where the full duck puts it.
function duck.curve(timer)
    local s = (duck.TIMER - timer) / (duck.TIMER - duck.DONE)
    if s > 1 then
        s = 1
    elseif s < 0 then
        s = 0
    end
    local f = 3 * s * s - 2 * s * s * s
    return duck.VIEW_STAND - (duck.VIEW_STAND - duck.VIEW_DUCK + duck.SHIFT) * f
end

--- Once per frame hook, before its updates, with the keys the hook saw: keys = { held (a
--- duck key is down), notch (a duck notch: a wheel duck key, or a duck key pressed and let
--- go within the frame), tap (a ducktap key is down), jump (a jump key is down), jumpNotch
--- (a jump notch), autoHop (the setting) }.
--- A notch is the button "went down", which OpenAG keeps until a command is built: it waits
--- for the first update that runs, at this hook or a later one, and that update spends it
--- (duck.button), for nothing if the update is under the ducktap rule. It isn't dropped at a
--- hook, not even under a ducktap key: a hook may run no update, and the key may be let go
--- before the next one runs.
function duck.frame(d, keys)
    if not keys.held then
        d.wiped = false -- every duck key let go: they count again at their next press
    end
    if keys.notch then
        if not keys.held then
            d.notch = true -- waits for the first update that runs; more notches before it are one
        elseif d.wiped then
            -- After a wipe, a notch is a second key going down on a button the client takes for
            -- idle: the keys count again (2022), and the button went down, so the first update
            -- has it even if the key is let go before that update runs.
            d.wiped, d.notch = false, true
        end
        -- With a counting duck key held a notch does nothing: the button is down already.
    end
    d.keyHeld = (keys.held and not d.wiped) and true or false
    d.tap = keys.tap and true or false
    d.jumpKey = keys.jump and true or false
    d.jumpNotch = (keys.jumpNotch or d.jumpWait) and true or false
    d.jumpWait = false
    d.autoHop = keys.autoHop and true or false
end

--- The duck button of one update. onGround: on the ground as the update before left the
--- player (for a hook's first update, what the mod knows at the hook). Spends a waiting notch:
--- under the ducktap rule for nothing (the rule alone decides; a notch is lost there).
function duck.button(d, onGround)
    local fromKeys = d.keyHeld or d.notch
    d.notch = false
    if not d.tap then
        return fromKeys
    end
    -- The ducktap rule: on the ground down if the last update under the rule had it up, and
    -- up if it had it down; in the air up, unless a duck key counts (2022).
    local down
    if onGround then
        down = not d.tapHad
    else
        down = duck.HELD_DUCK_UNDER_TAP and d.keyHeld
    end
    if not down and duck.HELD_DUCK_UNDER_TAP and d.keyHeld then
        d.wiped, d.keyHeld = true, false -- the 2022 wipe
    end
    d.tapHad = down
    return down
end

--- Whether the duck button is down on every update of this hook while in the air, without
--- changing anything: a counting duck key, under a ducktap key only with the 2022 rule. A
--- notch alone gives false: an update of the hook may then stand up.
function duck.heldInAir(d)
    return d.keyHeld and (not d.tap or duck.HELD_DUCK_UNDER_TAP)
end

--- The jump button of one update: a held jump key on every update, a jump notch on the
--- hook's first update only (first: this is that update, or the hook runs none).
function duck.jumpButton(d, first)
    if d.jumpKey then
        return true
    end
    return (first and d.jumpNotch) and true or false
end

--- Half-Life's jump of one update, after its duck step (onGround as the duck step left the
--- player). Returns true to jump. Without the button the mark "jump is down" is cleared; in
--- the air the button sets it; on the ground the button jumps if the mark is clear, and sets
--- it. With AutoHop, and no ducktap key held, the mark stays clear, so a held key jumps on
--- every update that is on the ground (Bunnymod XT's autojump).
function duck.jump(d, button, onGround)
    if not button then
        d.jumpWas = false
        return false
    end
    if d.autoHop and not d.tap then
        d.jumpWas = false
        return onGround and true or false
    end
    if not onGround then
        d.jumpWas = true -- a press in the air is used up
        return false
    end
    if d.jumpWas then
        return false
    end
    d.jumpWas = true
    return true
end

local function standUp(d)
    d.state, d.view, d.timer = duck.STANDING, duck.VIEW_STAND, 0
end

--- Half-Life's duck step of one update. button: this update's duck button; onGround: what
--- the update's first ground check finds (the update before's, or the caller's for a
--- hook's first update); room: { ground, air, lift }, each false where Unreal can't (a
--- stand-up on the ground, in the air, the tap's lift), nil or anything else where it can
--- (no room table: room everywhere); ms: the update's length.
--- Returns the scale of this update's moves (by the state the update begins in), the event
--- ("pressed", "ducked", "lift", "dropped", "stood", "refused" or nil), and onGround after
--- the step: false after a lift, which puts the player in the air.
function duck.step(d, button, onGround, room, ms)
    room = room or OPEN
    d.timer = math.max(0, d.timer - ms) -- the count-down comes before a press sets 1000
    local pressed = button and not d.wasDown
    d.wasDown = button and true or false
    local scale = d.state == duck.DUCKED and duck.SCALE or 1
    local event
    if button then
        if pressed and d.state ~= duck.DUCKED then
            -- A new press from standing or from a refused tap starts the transition again; a
            -- press fully ducked does nothing.
            d.state, d.timer, event = duck.IN_DUCK, duck.TIMER, "pressed"
        end
        if d.state == duck.IN_DUCK then
            if not onGround or d.timer <= duck.DONE + TIMER_TOLERANCE then
                d.state, d.view, event = duck.DUCKED, duck.VIEW_DUCK, "ducked"
            else
                d.view = duck.curve(d.timer)
            end
        end
    elseif d.state == duck.IN_DUCK then
        if not onGround then
            standUp(d) -- standing again where it is
            event = "dropped"
        elseif room.lift == false then
            event = "refused" -- the view stays where the curve left it, the timer runs on
        else
            standUp(d) -- the duck tap: 18 units up, and in the air
            return scale, "lift", false
        end
    elseif d.state == duck.DUCKED then
        if (onGround and room.ground ~= false) or (not onGround and room.air ~= false) then
            standUp(d)
            event = "stood"
        else
            event = "refused" -- stays fully ducked; asked again on the next update without the button
        end
    end
    return scale, event, onGround
end

--- What the game answered the mod's hull request with: "stood" stands the physics up;
--- "refused" (a stand-up Unreal had no room for) and "crouched" (the game's own crouch) make
--- it fully ducked, from standing or from the transition alike, keeping the timer.
function duck.confirm(d, answer)
    if answer == "stood" then
        standUp(d)
    elseif answer == "refused" or answer == "crouched" then
        d.state, d.view = duck.DUCKED, duck.VIEW_DUCK
    else
        error("duck.confirm: unknown answer " .. tostring(answer), 2)
    end
end

--- After a hull change Unreal made in the air: Half-Life's origin didn't move with the
--- capsule's middle, so it is cm further below it (cm: the middle's measured rise).
function duck.rebase(d, cm)
    d.drop = d.drop + cm
end

--- At a hook where Unreal walks (no slide): the drop from the state and the capsule alone.
--- On the ground Half-Life's origin is 18 units lower fully ducked, and Unreal's crouched
--- capsule has its middle delta cm lower (both keep the feet). crouched: the capsule reads
--- crouched; delta: its standing less its crouched half height, cm; s: cm per unit.
function duck.groundDrop(d, crouched, delta, s)
    d.drop = (d.state == duck.DUCKED and duck.SHIFT * s or 0) - (crouched and delta or 0)
end

--- The drop after one event of the frame's updates (event and onGround as the update had
--- them before its duck step; s: cm per unit; lifted: cm the game lifted the character for
--- a lift). On the ground a duck moves Half-Life's origin 18 units down and a stand-up 18 up,
--- before Unreal changes the capsule; a lift raises it 18 units where the game raised the
--- character by lifted. In the air ducks and stand-ups keep the origin, as Unreal keeps the
--- middle (where it doesn't, the next hook's duck.rebase puts it right).
function duck.eventDrop(d, event, onGround, s, lifted)
    if event == "lift" then
        d.drop = d.drop - (duck.SHIFT * s - (lifted or 0))
    elseif onGround and event == "ducked" then
        d.drop = d.drop + duck.SHIFT * s
    elseif onGround and event == "stood" then
        d.drop = d.drop - duck.SHIFT * s
    end
end

--- Centimetres to add to the standing eye for Half-Life's: the view height's change and the
--- origin's drop. crouched: the capsule reads crouched, and then the eye is never above the
--- ducked eye (16 units below the standing one). ahead: the game camera's anticipation of a
--- crouch the mod asks for this frame that Unreal makes keeping the base (it lowers the
--- middle before the view is built, and the camera hangs on the capsule): the drop is left out.
function duck.eyeOffset(d, s, crouched, ahead)
    local offset = (d.view - duck.VIEW_STAND) * s - (ahead and 0 or d.drop)
    if crouched then
        local ducked = (duck.VIEW_DUCK - duck.VIEW_STAND) * s
        if offset > ducked then
            offset = ducked
        end
    end
    return offset
end

-- A coordinate kept whole as Valve's map compiler keeps it: the fraction dropped towards zero.
local function whole(v)
    if v < 0 then
        return math.ceil(v)
    end
    return math.floor(v)
end

--- How much lower than the standing hull's resting place the ducked hull's lies, straight
--- up, in units, on a floor whose unit normal has the z part nz (Half-Life on Valve's maps).
--- Half-Life's two hulls collide with floors its map compiler makes, one set for each hull,
--- and the compiler works in whole units: it moves the whole-number point that defines a
--- face upwards by nz times each hull's half height (36 standing, 18 ducked) and drops the
--- fraction of the moved height towards zero. On level ground that is 18, the hulls' own
--- difference; on a slope it comes out as 18 nz rounded to a whole unit, halves up: 18 up to
--- 13.5 degrees, 17 to 23.6, 16 to 30.6, 15 to 36.3, 14 to 41.4, 13 to the steepest floor.
--- In 115 of Valve's maps 6,441 of 6,520 slope faces have that gap, and 75 have one less;
--- the owner's 17.7 degree ramp has 17, and a ducked hop on the spot there gains 90.47 u/s.
--- h, the height of the face's defining point in the map (whole units), gives the compiler's
--- rule exactly: the gap is the rounded one when h is -18 nz or more (halves up) or below
--- -36 nz (halves down), and one less in the band between, unless 18 nz is whole. Which faces
--- lie in the band can't be told from a map's collision data, and Unreal's floors have no
--- such point: the mod passes no h. nz above 1 counts as 1, below 0 as 0; nil is level.
function duck.restGap(nz, h)
    if nz == nil or nz ~= nz then
        nz = 1
    elseif nz > 1 then
        nz = 1
    elseif nz < 0 then
        nz = 0
    end
    local reach = (STAND_HALF - DUCK_HALF) * nz
    if h == nil then
        return math.floor(reach + 0.5)
    end
    return whole(h + STAND_HALF * nz) - whole(h + DUCK_HALF * nz)
end

return duck
