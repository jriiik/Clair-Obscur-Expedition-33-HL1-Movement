-- What the report says about ducking and the keys (diagnostics.lua), through main.lua in the
-- fake game: every name the report reads for them, what it says where the game lacks one
-- ("(none)", "not found", "?"), whose the keys are and why, and its length. Each test's comment
-- says what breaks it (each was run once against that broken variant, in a scratch copy, and
-- failed).

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local F5, F6, F8 = 0x74, 0x75, 0x77
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local DT = 1 / 80
local CLASS_DEFAULT = "/Script/Fake.Default__BP_jRPG_Character_World_C" -- (fake_hull's)
local INPUT_SETTINGS = "/Script/Engine.Default__InputSettings"
local HELPERS = "/Script/SandFall.Default__InputBlueprintHelpers"
local MOST_LINES = 199 -- the report stays under 200 lines

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

local function untilTrue(g, limit, fn, what)
    for i = 1, limit do
        g.frame(DT)
        if fn(g) then
            return i
        end
    end
    error("not within " .. limit .. " frames: " .. what, 2)
end

local function crouched(g)
    return fake.props(g.pawn).bIsCrouched == true
end

local function short(lines)
    t.truthy(#lines <= MOST_LINES, string.format("the report has %d lines, more than %d", #lines, MOST_LINES))
end

-- Presses the report key (with modifiers, a list of UE4SS's names) and returns the lines of the
-- report it wrote, from its title to its last line.
local function reportNow(g, modifiers)
    local from = #g.log
    g.press(F8, modifiers)
    for _ = 1, 10 do
        local lines, inside = {}, false
        for i = from + 1, #g.log do
            local text = g.log[i]
            if text:find("==== HL1Movement ", 1, true) then
                lines, inside = {}, true
            end
            if inside then
                lines[#lines + 1] = text
                if text:find("==== end of diagnostics ====", 1, true) then
                    return lines
                end
            end
        end
        g.frame(DT)
    end
    error("no report within 10 frames of the report key", 2)
end

-- The number after `label` (a pattern) in line.
local function numberAfter(line, label)
    local n = line:match(label .. " (%-?[%d.]+)")
    t.truthy(n, "no number after '" .. label .. "' in: " .. line)
    return tonumber(n)
end

local function mapping(action, key)
    return fake.struct({ ActionName = fake.FName(action), Key = fake.struct({ KeyName = fake.FName(key) }) })
end

-- Everything 6.2 names that the default fake game lacks, on the character, its capsule, its
-- class default, the movement component, the game's input settings and its key helper; and
-- a record of the property reads of each name the report reads for ducking (read["pawn.Mesh"]).
local function withEverything(g)
    local read = {}
    local function watch(label, obj, names)
        for _, name in ipairs(names) do
            fake.onRead(obj, name, function()
                read[label .. "." .. name] = (read[label .. "." .. name] or 0) + 1
            end)
        end
    end
    local function stances(walk, run)
        return fake.struct({ Standing = fake.struct({ WalkSpeed = 175, RunSpeed = 375, SprintSpeed = 650,
            MovementCurve = false, RotationRateCurve = false }), Crouching = fake.struct({ WalkSpeed = walk,
            RunSpeed = run, SprintSpeed = run, MovementCurve = false, RotationRateCurve = false }) })
    end
    fake.set(g.pawn, "Mesh", g.c.mesh)
    fake.set(g.c.mesh, "RelativeLocation", fake.vector(0, 0, -90))
    fake.set(g.pawn, "DesiredStance", 0)
    fake.set(g.pawn, "MovementData", fake.struct({ VelocityDirection = stances(150, 200),
        LookingDirection = stances(151, 201), Aiming = stances(152, 202) }))
    fake.method(g.c.capsule, "GetCollisionProfileName", function()
        return fake.FName("Pawn")
    end)
    local cdo = g.statics[CLASS_DEFAULT]
    fake.set(cdo, "CharacterMovement", fake.object({ className = "ALSCharacterMovementComponent",
        name = "CharMoveComp", path = CLASS_DEFAULT .. ".CharMoveComp", props = { CrouchedHalfHeight = 40,
            bCanWalkOffLedgesWhenCrouching = false, MaxWalkSpeedCrouched = 300,
            NavAgentProps = fake.struct({ bCanCrouch = true }) } }))
    g.statics[INPUT_SETTINGS] = fake.object({ className = "InputSettings", name = "Default__InputSettings",
        path = INPUT_SETTINGS, props = { ActionMappings = fake.array({ mapping("ZoomIn", "MouseScrollUp"),
            mapping("ZoomOut", "MouseScrollDown"), mapping("Interact", "E"), mapping("Crouch", "LeftControl") }) } })
    local more = { SprintAction = "LeftShift", WalkAction = "LeftControl", StanceAction = "LeftAlt",
        AimAction = "RightMouseButton" }
    local before = g.statics[HELPERS].TryFindKeysForEnhancedInputActionName
    fake.method(g.statics[HELPERS], "TryFindKeysForEnhancedInputActionName", function(self, context, name)
        local key = more[fake.nameOf(name)]
        if key then
            return { fake.param({ KeyName = fake.FName(key) }) }
        end
        return before(self, context, name)
    end)
    local diagnostics = require("hl1movement.diagnostics")
    watch("pawn", g.pawn, diagnostics.CROUCH_CHARACTER)
    watch("pawn", g.pawn, { "Mesh", "MovementData" })
    watch("cmc", g.cmc, diagnostics.CROUCH_MOVEMENT)
    watch("cmc", g.cmc, { "NavAgentProps" })
    watch("cdo", cdo, diagnostics.CLASS_DEFAULT)
    watch("cdo", cdo, { "CapsuleComponent", "CharacterMovement" })
    watch("settings", g.statics[INPUT_SETTINGS], { "ActionMappings" })
    return read
end

-------------------------------------------------------------------------------------------

t.test("the ducking lines: the settings, Half-Life's duck now, and every count since loading from its own count",
    function()
        -- Fails with: two counts of a line swapped (Half-Life's ducks on the ground and in the
        -- air, Unreal's crouches on the ground and in the air, the taps and their landings); the
        -- duck state's name not the duck's; the braking in cm/s instead of u/s.
        local g = running()
        local hull = require("hl1movement.hull")
        local movement = require("hl1movement.movement")
        -- A duck on the ground, a jump with a duck in the air (a crouch in the air, re-based),
        -- then duck taps, all running (ALS's braking frame at the ground crouch and stand-up).
        g.keys.W = true
        g.frames(60, DT)
        g.keys.LeftControl = true
        untilTrue(g, 60, crouched, "a crouch")
        g.frames(20, DT)
        g.keys.LeftControl = false
        untilTrue(g, 20, function()
            return not crouched(g)
        end, "a stand-up")
        g.frames(10, DT)
        g.keys.SpaceBar = true
        untilTrue(g, 10, function()
            return g.mode() == 3
        end, "a jump")
        g.keys.SpaceBar = false
        g.frames(5, DT)
        g.keys.LeftControl = true
        untilTrue(g, 10, crouched, "a crouch in the air")
        untilTrue(g, 120, function()
            return g.mode() == 1
        end, "the landing")
        g.keys.LeftControl = false
        g.frames(20, DT)
        g.keys.LeftShift = true
        g.frames(100, DT)
        g.keys.LeftShift = false
        g.keys.LeftControl = true -- (ducked when the report is written)
        untilTrue(g, 60, crouched, "a crouch")
        local report = reportNow(g)
        local h, dk = hull.status(), movement.duckStatus()
        local hc = h.counts
        t.contains(report, "Ducking (Half-Life's duck, Unreal's crouch): Ducking=true, DuckHull=true, OpenAG's 2022 "
            .. "rule for a duck key under duck tap (HELD_DUCK_UNDER_TAP=true); the hull: crouch (on: Unreal's crouch)")
        local now = t.contains(report, "  Half-Life's duck now: ")
        t.truthy(now:find("Half-Life's duck now: fully ducked, timer " .. string.format("%.0f", dk.timer)
            .. " ms, view 12.0 units", 1, true), now)
        t.truthy(now:find("button down on every update of the last frame=true", 1, true), now)
        local hullNow = t.contains(report, "  Unreal's crouch now: crouched at the last hook=true, the mod holds the "
            .. "crouch wish=true")
        t.truthy(hullNow:find("standing eye 74.9 cm (from the standing capsule)", 1, true), hullNow)
        local ducks = t.contains(report, "  Half-Life's ducks since loading: ")
        -- (Each pair below differs, so a swap shows.)
        t.truthy(dk.groundDucks >= 1 and dk.airDucks >= 1 and dk.groundDucks ~= dk.airDucks and dk.taps >= 3
            and dk.taps ~= dk.tapLandings, string.format("ducks %d and %d, taps %d, landed %d", dk.groundDucks,
                dk.airDucks, dk.taps, dk.tapLandings))
        t.eq(numberAfter(ducks, "since loading:"), dk.groundDucks, ducks)
        t.eq(numberAfter(ducks, "on the ground and"), dk.airDucks, ducks)
        t.eq(numberAfter(ducks, "duck taps"), dk.taps, ducks)
        t.eq(numberAfter(ducks, "%(landed"), dk.tapLandings, ducks)
        t.eq(numberAfter(ducks, "lifts"), hc.lifts, ducks)
        t.eq(numberAfter(ducks, "the next"), dk.duckLinesLeft, ducks)
        local unreal = t.contains(report, "  Unreal's crouch since loading: ")
        t.truthy(hc.groundCrouches >= 1 and hc.airCrouches >= 1 and hc.groundCrouches ~= hc.airCrouches,
            string.format("crouches %d on the ground and %d in the air", hc.groundCrouches, hc.airCrouches))
        t.eq(numberAfter(unreal, "since loading: crouches"), hc.groundCrouches, unreal)
        t.eq(numberAfter(unreal, "on the ground and"), hc.airCrouches, unreal)
        t.eq(numberAfter(unreal, "in the air, stand%-ups"), hc.groundStands, unreal)
        local more = t.contains(report, "  ALS's braking at a crouch or stand-up: ")
        t.truthy(hc.brakeGiven >= 1 and hc.rebases >= 1 and hc.rebasesMeasured >= 1, "braking given back, re-bases")
        t.eq(numberAfter(more, "frames given back"), hc.brakeGiven, more)
        t.near(numberAfter(more, "u/s in all, the largest"), hc.brakeLargest / 2.5, 0.5, more)
        t.eq(numberAfter(more, "re%-based"), hc.rebases, more)
        t.eq(numberAfter(more, "not asked for %d+; measured"), hc.rebasesMeasured, more)
        t.eq(numberAfter(more, "the middle kept"), hc.rebaseMiddleKept, more)
        t.contains(report, "  the hull's detectors: crouches refused in a row 0 on the ground and 0 in the air, key "
            .. "flushes in a row 0; turned off by errors: the hull false, the lift false, the floor query false; the "
            .. "mod's capsule: standing half height 96.0 cm (unscaled 96.0, scale 1.000), radius 35.0, crouched half "
            .. "height 51.0 (unscaled), 45.0 cm shorter")
        noErrors(g)
    end)

t.test("the character, capsule, movement component and ALS lines read every name 6.2 names, where the game has "
    .. "them; the report stays under 200 lines", function()
    -- Fails with: a name of 6.2 left out of the report (a read missing below); the class default
    -- looked for at the wrong path; MovementData's stances not read through Crouching; the
    -- game's own MaxWalkSpeedCrouched not kept (movement.status) or not shown.
    local g = running()
    local read = withEverything(g)
    g.keys.LeftControl = true
    untilTrue(g, 60, crouched, "a crouch")
    g.frames(5, DT)
    for name in pairs(read) do
        read[name] = nil
    end
    local report = reportNow(g)
    local diagnostics = require("hl1movement.diagnostics")
    for _, list in ipairs({ { "pawn", diagnostics.CROUCH_CHARACTER }, { "pawn", { "Mesh", "MovementData" } },
        { "cmc", diagnostics.CROUCH_MOVEMENT }, { "cmc", { "NavAgentProps" } }, { "cdo", diagnostics.CLASS_DEFAULT },
        { "cdo", { "CapsuleComponent", "CharacterMovement" } }, { "settings", { "ActionMappings" } } }) do
        for _, name in ipairs(list[2]) do
            t.truthy(read[list[1] .. "." .. name], list[1] .. "." .. name .. " read by the report")
        end
    end
    t.contains(report, "  Character crouch: bIsCrouched=true, CrouchedEyeHeight=34.880, BaseEyeHeight=34.880, "
        .. "Stance=1, DesiredStance=0, IsSprintRequested=false, CanCrouch()=false")
    t.contains(report, "  class default " .. CLASS_DEFAULT .. ": BaseEyeHeight=64, CrouchedEyeHeight=48, capsule "
        .. "CapsuleHalfHeight=96, CapsuleRadius=35, CharacterMovement CrouchedHalfHeight=40, "
        .. "bCanWalkOffLedgesWhenCrouching=false, MaxWalkSpeedCrouched=300, NavAgentProps.bCanCrouch=true")
    t.contains(report, "  Capsule: GetUnscaledCapsuleHalfHeight()=51, GetUnscaledCapsuleRadius()=35, "
        .. "GetCollisionProfileName()=Pawn")
    local mesh = t.contains(report, "  Character.Mesh = SkeletalMeshComponent ")
    t.truthy(mesh:find(", attached to ", 1, true) and mesh:find("RelativeLocation=(X=0.0 Y=0.0 Z=-90.0)", 1, true),
        mesh)
    t.contains(report, "  Movement crouch: bWantsToCrouch=true, bCrouchMaintainsBaseLocation=true, "
        .. "bCanWalkOffLedgesWhenCrouching=true, CrouchedHalfHeight=51, MaxWalkSpeedCrouched=100000, "
        .. "GetCrouchedHalfHeight()=51, NavAgentProps.bCanCrouch=true (at the take-over false, set true by the mod); "
        .. "the game's own CrouchedHalfHeight 60, MaxWalkSpeedCrouched 375")
    t.contains(report, "  ALS crouching settings (MovementData): VelocityDirection: WalkSpeed=150, RunSpeed=200, "
        .. "SprintSpeed=200, MovementCurve=false; LookingDirection: WalkSpeed=151, RunSpeed=201, SprintSpeed=201, "
        .. "MovementCurve=false; Aiming: WalkSpeed=152, RunSpeed=202, SprintSpeed=202, MovementCurve=false")
    t.contains(report, "Game keys for SprintAction: LeftShift; WalkAction: LeftControl; StanceAction: LeftAlt; "
        .. "AimAction: RightMouseButton (read while the mod holds its keys)")
    t.contains(report, "Game keys for JumpAction: SpaceBar, Gamepad_FaceButton_Bottom (read while the mod holds its "
        .. "keys)")
    t.contains(report, "Legacy action mappings (InputSettings, 4 in all) on the mod's keys, the wheel and zoom: ZoomIn "
        .. "on MouseScrollUp, ZoomOut on MouseScrollDown, Crouch on LeftControl")
    short(report)
    noErrors(g)
end)

t.test("where the game lacks a name, the report says (none), not found or ?, and goes on to its end", function()
    -- Fails with: a read or a call of the new lines not through ue.get or ue.call (the report
    -- stops at the broken read with an error); the class default's lookup not guarded.
    local g = running(nil, { noClassDefault = true })
    fake.set(g.pawn, "MovementData", fake.struct({})) -- (there, and its read raises an error)
    fake.breakOnRead(g.pawn, "MovementData")
    fake.breakOnRead(g.cmc, "NavAgentProps")
    fake.method(g.cmc, "GetCrouchedHalfHeight", function()
        error("GetCrouchedHalfHeight broken on purpose")
    end)
    fake.method(g.pawn, "CanCrouch", function()
        error("CanCrouch broken on purpose")
    end)
    local report = reportNow(g)
    t.contains(report, "  class default " .. CLASS_DEFAULT .. ": not found")
    t.contains(report, ", DesiredStance=(none), IsSprintRequested=false, CanCrouch()=?")
    t.contains(report, ", CanCrouch()=?")
    t.contains(report, ", GetCollisionProfileName()=?")
    t.contains(report, "  ALS crouching settings (MovementData): not found")
    t.contains(report, ", GetCrouchedHalfHeight()=?, NavAgentProps.bCanCrouch=(none) (at the take-over ")
    t.contains(report, "Legacy action mappings: " .. INPUT_SETTINGS .. " not found")
    t.contains(report, "Game keys for SprintAction: none; WalkAction: none; StanceAction: none; AimAction: none")
    t.contains(report, "==== end of diagnostics ====")
    short(report)
    noErrors(g)
end)

t.test("before the mod moves a character: the duck and the hull say so, and the report has its keys lines",
    function()
        -- Fails with: the duck's line written from a duck that isn't there ("timer ? ms").
        local g = start()
        local report = reportNow(g)
        t.contains(report, "the hull: not set up yet (the mod hasn't taken over a character)")
        t.contains(report, "  Half-Life's duck now: none (the mod doesn't move the character)")
        t.contains(report, "Keys as loaded: DuckKeys={LeftControl, MouseScrollDown}, DuckTapKeys={LeftShift}, "
            .. "JumpKeys={SpaceBar, MouseScrollUp, Gamepad_FaceButton_Bottom}, TakeKeys=true, TakeJumpKeys=true; "
            .. "seen pressed so far (wheel notches and quick taps): none; ignored now")
        t.contains(report, "==== end of diagnostics ====")
    end)

t.test("the keys now: the mod's while it moves you; the game's in a dialogue (with the frames the movement ran "
    .. "meanwhile), paused, and with the mod off", function()
    -- Fails with: the frames moved while the game showed a dialogue not counted (main.lua);
    -- the reason left out of the keys-now line; the mod's keys read as the game's while taken.
    local g = running()
    local report = reportNow(g)
    local now = t.contains(report, "Keys now: the mod's (Gamepad_FaceButton_Bottom, LeftControl, LeftShift, "
        .. "MouseScrollDown, MouseScrollUp, SpaceBar); the method context;")
    t.truthy(now:find("the mod's context InputMappingContext ", 1, true) and now:find("at priority 1000000; taken 1 "
        .. "times, re-made 0, dropped by the game 0", 1, true), now)
    t.contains(report, "  the game's actions on the mod's keys at the last take that read them: LeftControl "
        .. "WalkAction, MouseScrollDown nothing, LeftShift SprintAction, SpaceBar JumpAction, MouseScrollUp nothing, "
        .. "Gamepad_FaceButton_Bottom JumpAction; now: LeftControl the mod's, MouseScrollDown the mod's, LeftShift the "
        .. "mod's, SpaceBar the mod's, MouseScrollUp the mod's, Gamepad_FaceButton_Bottom the mod's")
    t.contains(report, "frames the mod moved the character while the game showed a dialogue 0, a cinematic 0, another "
        .. "view target 0")
    -- Third person, a dialogue that leaves the movement input on.
    g.press(F6)
    g.inDialogue = true
    g.keys.W = true
    g.frames(40, DT)
    report = reportNow(g)
    t.contains(report, "Keys now: the game's (dialogue); the method context;")
    local moved = t.contains(report, "frames the mod moved the character while the game showed a dialogue ")
    -- (The game's dialogue is asked every 0.25 s: most of the 40 frames.)
    t.truthy(numberAfter(moved, "showed a dialogue") >= 20, moved)
    t.contains(report, "Game keys for JumpAction: SpaceBar, Gamepad_FaceButton_Bottom")
    t.absent(report, "(read while the mod holds its keys)", "the game's keys read with the keys given back")
    g.inDialogue = false
    g.keys.W = false
    g.frames(20, DT)
    g.paused = true
    g.frames(5, DT)
    report = reportNow(g)
    t.contains(report, "Keys now: the game's (paused)")
    g.paused = false
    g.frames(5, DT)
    g.press(F5)
    g.frames(5, DT)
    report = reportNow(g)
    t.contains(report, "Keys now: the game's (the mod is switched off)")
    noErrors(g)
end)

t.test("the keys seen pressed (the wheel's notches) and the keys ignored until let go, held at the take-over",
    function()
        -- Fails with: input.pressesSeen or input.ignoredKeys not in the report; the waiting keys
        -- left out.
        local g = start()
        g.keys.LeftShift = true -- held through the take-over: the game's until let go
        g.loadSave()
        g.frames(SETTLE_FRAMES)
        g.frames(5, DT)
        local report = reportNow(g)
        local keysLine = t.contains(report, "Keys as loaded: ")
        t.truthy(keysLine:find("ignored now (held when the mod took them, the game's until let go): LeftShift", 1,
            true), keysLine)
        t.contains(report, "  waiting until let go: LeftShift;")
        t.contains(report, "LeftShift=true")
        g.keys.LeftShift = false
        g.frames(5, DT)
        g.notch("MouseScrollUp")
        g.frames(2, DT)
        g.notch("MouseScrollDown")
        g.frames(60, DT)
        report = reportNow(g)
        keysLine = t.contains(report, "Keys as loaded: ")
        t.truthy(keysLine:find("seen pressed so far (wheel notches and quick taps): MouseScrollDown, MouseScrollUp; "
            .. "ignored now (held when the mod took them, the game's until let go): none", 1, true), keysLine)
        noErrors(g)
    end)

t.test("a report asked for with Ctrl held while ducked says so, has the duck and stays under 200 lines", function()
    -- Fails with: a line of its own per key or count that makes the report longer than 199
    -- lines with everything 6.2 reads.
    local g = running(nil, { fireEveryBind = true })
    withEverything(g)
    g.keys.LeftControl = true
    untilTrue(g, 60, crouched, "a crouch")
    local report = reportNow(g, { "CONTROL" })
    t.truthy(report[1]:find("diagnostics (asked for with F8, Ctrl held)", 1, true), report[1])
    t.contains(report, "  Half-Life's duck now: fully ducked")
    t.contains(report, "LeftControl=true")
    short(report)
    noErrors(g)
end)
