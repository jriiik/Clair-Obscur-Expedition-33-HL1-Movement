-- The status report the mod writes to UE4SS.log: by itself a few seconds after
-- taking over a character, when first person is given up or still waits, and when
-- the diagnostics key is pressed. It lists what the mod finds in the game, so
-- problems can be fixed by someone who can't run it.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local settings = require("hl1movement.settings")
local input = require("hl1movement.input")
local view = require("hl1movement.view")
local camera = require("hl1movement.camera")
local movement = require("hl1movement.movement")
local speedometer = require("hl1movement.speedometer")
local duck = require("hl1movement.duck")
local hull = require("hl1movement.hull")
local keys = require("hl1movement.keys")

local diagnostics = {}

-- The names the report reads for ducking and the keys, by the object they are read on: the
-- report's test reads every one of them (tests/test_duck_report.lua).
diagnostics.CROUCH_MOVEMENT = { "bWantsToCrouch", "bCrouchMaintainsBaseLocation", "bCanWalkOffLedgesWhenCrouching",
    "CrouchedHalfHeight", "MaxWalkSpeedCrouched" }
diagnostics.CROUCH_CHARACTER = { "bIsCrouched", "CrouchedEyeHeight", "BaseEyeHeight", "Stance", "DesiredStance",
    "IsSprintRequested" }
diagnostics.CLASS_DEFAULT = { "BaseEyeHeight", "CrouchedEyeHeight" }
diagnostics.ROTATION_MODES = { "VelocityDirection", "LookingDirection", "Aiming" } -- ALS's MovementData
diagnostics.MOVEMENT_SETTINGS = { "WalkSpeed", "RunSpeed", "SprintSpeed", "MovementCurve" }
-- The game's Enhanced Input actions whose keys the report asks for besides the jump and the
-- movement: ALS's run, walk toggle, stance and free aim, which share keys with the mod's.
diagnostics.MORE_ACTIONS = { "SprintAction", "WalkAction", "StanceAction", "AimAction" }
diagnostics.INPUT_SETTINGS = "/Script/Engine.Default__InputSettings"

local STATE_NAMES = { [duck.STANDING] = "standing", [duck.IN_DUCK] = "in the transition",
    [duck.DUCKED] = "fully ducked" }

local function listText(list)
    return list and #list > 0 and table.concat(list, ", ") or "none"
end

local function keyList(list)
    return "{" .. table.concat(list or {}, ", ") .. "}"
end

local function number(value, fmt)
    return type(value) == "number" and string.format(fmt or "%.1f", value) or "?"
end

-- obj's class default object (Default__ of its class, which the class's own path names), or
-- nil; and its path. Only for a valid obj: GetClass on a null object crashes the game.
local function classDefault(obj)
    if not ue.valid(obj) then
        return nil, nil
    end
    local okClass, class = pcall(function()
        return obj:GetClass()
    end)
    local name = okClass and ue.valid(class) and ue.fullName(class)
    local path = type(name) == "string" and name:match("^%S+ (.+)$")
    local outer, short = (path or ""):match("^(.*)%.([^.:]+)$")
    if not outer then
        return nil, nil
    end
    local default = outer .. ".Default__" .. short
    return ue.find(default), default
end

local function show(value)
    local t = ue.typeOf(value)
    if t == "number" then
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return string.format("%.3f", value)
    elseif t == "boolean" or t == "nil" or t == "string" then
        return tostring(value)
    elseif t == "table" or t == "UScriptStruct" then
        -- One field at a time: in UE4SS, reading a field a struct doesn't have raises an error.
        local x, y, z = ue.number(value, "X"), ue.number(value, "Y"), ue.number(value, "Z")
        if x and y and z then
            return string.format("(X=%.1f Y=%.1f Z=%.1f)", x, y, z)
        end
        local pitch, yaw, roll = ue.number(value, "Pitch"), ue.number(value, "Yaw"), ue.number(value, "Roll")
        if pitch and yaw and roll then
            return string.format("(Pitch=%.1f Yaw=%.1f Roll=%.1f)", pitch, yaw, roll)
        end
        return t
    elseif t == "FName" then
        local ok, text = pcall(function()
            return value:ToString()
        end)
        return ok and text or "FName"
    elseif ue.valid(value) then
        return tostring(ue.fullName(value))
    end
    return "(none)"
end

local function values(obj, list)
    local parts = {}
    for _, name in ipairs(list) do
        parts[#parts + 1] = name .. "=" .. show(ue.get(obj, name))
    end
    return table.concat(parts, ", ")
end

-- A surface's normal, with 3 decimals and how far it leans from straight up.
local function normal(value)
    local x, y, z = ue.number(value, "X"), ue.number(value, "Y"), ue.number(value, "Z")
    if not (x and y and z) then
        return show(value)
    end
    local length = math.sqrt(x * x + y * y + z * z)
    local angle = length > 1e-6 and string.format(", %.1f deg", math.deg(math.acos(math.max(-1, math.min(1,
        z / length))))) or ""
    return string.format("(X=%.3f Y=%.3f Z=%.3f%s)", x, y, z, angle)
end

-- The class and the classes it is built on, if UE4SS can tell.
local function classChain(obj)
    local names = { tostring(ue.className(obj)) }
    pcall(function()
        local class = obj:GetClass()
        for _ = 1, 8 do
            class = class:GetSuperStruct()
            if not ue.valid(class) then
                break
            end
            names[#names + 1] = class:GetFName():ToString()
        end
    end)
    return table.concat(names, " < ")
end

local function distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return nil
    end
    local dx, dy, dz = (a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0), (a.Z or 0) - (b.Z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Writes the report. env holds version, mod (main.lua's state), cfg, P and pc.
function diagnostics.report(env)
    local lines = {}
    local function line(fmt, ...)
        lines[#lines + 1] = string.format(fmt, ...)
    end
    local function field(label, obj, name)
        line("  %s.%s = %s", label, name, show(ue.get(obj, name)))
    end
    local function result(label, obj, name, ...)
        local ok, value = ue.call(obj, name, ...)
        line("  %s:%s() = %s", label, name, ok and show(value) or ("error: " .. tostring(value)))
    end
    -- A function with one out parameter: UE4SS fills the table passed for it.
    local function outResult(label, obj, name, outName)
        local out = {}
        local ok, err = ue.call(obj, name, out)
        line("  %s:%s() = %s", label, name, ok and show(out[outName]) or ("error: " .. tostring(err)))
    end

    local mod, cfg, P = env.mod, env.cfg, env.P
    line("==== HL1Movement %s diagnostics (%s) ====", env.version, tostring(env.title or "report"))
    line("%s; UE4SS has LoopInGameThreadAfterFrames: %s; EngineTickAvailable: %s", _VERSION,
        tostring(rawget(_G, "LoopInGameThreadAfterFrames") ~= nil), tostring(rawget(_G, "EngineTickAvailable")))
    line("Mod: enabled=%s camera wanted=%s camera active=%s movement active=%s frames=%d errors=%d",
        tostring(mod.enabled), tostring(mod.cameraOn), tostring(camera.isActive()), tostring(movement.isActive()),
        mod.frames, mod.errors)
    line("Settings: CameraMethod=%s, FieldOfView=%s, PhysicsRate=%s, KeepSpeed=%s, AutoHop=%s, JumpInput=%s",
        tostring(cfg.CameraMethod), tostring(cfg.FieldOfView), tostring(cfg.PhysicsRate), tostring(cfg.KeepSpeed),
        tostring(cfg.AutoHop), tostring(cfg.JumpInput))
    -- Every setting config.lua changed, whichever it is: what a test was played with.
    local changed = {}
    for i, change in ipairs(settings.changes(cfg)) do
        changed[i] = change.name .. "=" .. change.value
    end
    line("Settings not at their defaults: %s", #changed > 0 and table.concat(changed, ", ") or "none")
    line("Frame hook: %s%s", mod.tickHook or ("not registered yet (" .. tostring(mod.hookError) .. ")"),
        mod.lateHook and " (runs after the character's movement, so the movement is off)" or "")
    line("Jump hook: %s%s", mod.jumpHook or "not registered", mod.hooksWanted and " (a hook is waiting to be added)"
        or "")
    local failed = guard.status()
    if #failed == 0 then
        line("Errors: none")
    end
    for _, step in ipairs(failed) do
        line("Errors in %s: %d%s, last: %s", step.name, step.total, step.off and " (turned off)" or "",
            tostring(step.lastError))
    end
    line("Game values the mod has changed and will put back: %d", journal.size())
    local jump = input.status()
    line("Jump input: mode=%s, key seen=%s, game presses=%d, game held=%s, game repeats=%s", cfg.JumpInput,
        tostring(jump.keysSeen), jump.gamePresses, tostring(jump.gameHeld), tostring(jump.repeats))
    local seen = input.keysSeen()
    line("Keys seen held so far: %s", #seen > 0 and table.concat(seen, ", ") or "none")

    local cameraStatus = camera.status()
    local waitingFor = mod.cameraBlock or cameraStatus.waiting
    line("First person: %s with %s%s, hidden parts=%d (kept animating %d), hidden parts the game moved to another "
        .. "actor this session=%d, camera to eyes=%s cm%s", cameraStatus.state, cameraStatus.methodName,
        cameraStatus.method == "engine" and (" (style set through " .. cameraStatus.styleRoute .. ")") or "",
        cameraStatus.hiddenParts, cameraStatus.animatedParts, cameraStatus.partsMoved,
        show(cameraStatus.lastDistance), waitingFor and (", waiting because: " .. waitingFor) or "")
    if cameraStatus.moved then
        line("  game camera at the eyes: %s, put back on its arm by the game %d times", cameraStatus.moved,
            cameraStatus.reattached)
    end
    if cameraStatus.engineFailed ~= "" then
        line("  the engine's first-person view didn't work with: %s", cameraStatus.engineFailed)
    end
    local seenView = view.status()
    line("  the game's GetMainCamera: %s%s; in dialogue: %s; cinematic: %s; the engine looks for cameras: %s",
        seenView.mainCamera and ue.describe(seenView.mainCamera) or "unknown",
        seenView.mainCameraError and (" (" .. seenView.mainCameraError .. ")") or "", tostring(seenView.dialogue),
        tostring(seenView.cinematic), tostring(seenView.findCamera))

    local meter = speedometer.status()
    line("Speedometer: wanted=%s, on the screen=%s, shown=%s, number=%s u/s, made %d times%s, taken off the screen "
        .. "by the game %d times%s", tostring(mod.speedometerOn), tostring(meter.onScreen), tostring(meter.visible),
        tostring(meter.shown), meter.made, meter.made > 0 and string.format(" (the last with %s, a %s)", meter.how,
            meter.numeric and "CommonNumericTextBlock" or "TextBlock") or "", meter.lost,
        meter.failed and (", can't be shown: " .. meter.failed) or "")

    local moveStatus = movement.status()
    line("Movement: world gravity=%s, curve taken out=%s, curve failed=%s, speed limiter=%s, stays based in the "
        .. "air=%s", show(moveStatus.worldGravity), tostring(moveStatus.curveTaken), tostring(moveStatus.curveBroken),
        moveStatus.limiter, tostring(moveStatus.stayBasedInAir))
    local counts = moveStatus.counts
    line("  GetMaxSpeed() after setting MaxWalkSpeed: %s; the game's own MaxWalkSpeed: %s; hops so far: %d (the "
        .. "next %d get a line in the log)", show(moveStatus.maxSpeed), show(moveStatus.gameMaxWalkSpeed),
        moveStatus.hops, moveStatus.hopLinesLeft)
    line("  since taking over: speed cuts %d (undone %d), MaxWalkSpeed set by the game %d, speed limiter started "
        .. "%d, the game's input reaching Unreal %d, velocity changed at a jump %d, jumps that landed again within "
        .. "their own frame %d", counts.cuts, counts.restores, counts.rewrites, counts.wakes, counts.leaks,
        counts.jumpChanges, counts.groundedJumps)
    -- The landings on slopes by kind: those a Half-Life update ran into, with what they
    -- gained and lost in all, apart (hopping down a hill and up it again cancels out);
    -- those Half-Life's ground check set down first, which keep their speed; and those
    -- the mod couldn't tell, which keep it too. The hop lines and status lines that say
    -- so run out.
    local slopeTotals = ""
    if counts.slopeLandings > 0 then
        slopeTotals = string.format(" (%d ran into it: +%.0f and -%.0f u/s in all; %d set down first by the ground "
            .. "check, speed kept; %d not told apart, speed kept)", counts.slopeHits,
            moveStatus.slopeGained / P.unitScale, moveStatus.slopeLost / P.unitScale,
            counts.slopeLandings - counts.slopeHits - counts.slopeUnknown, counts.slopeUnknown)
    end
    line("  slopes (SlopeLandings=%s, SlopeBoosts=%s): landings on one %d%s, slides up one %d, flights off one %d, "
        .. "the game's jumps held back while sliding %d%s", tostring(cfg.SlopeLandings),
        tostring(cfg.SlopeBoosts), counts.slopeLandings, slopeTotals, counts.slides, counts.launches,
        counts.stoppedJumps, moveStatus.slopeBroken
            and "; off: the floor's normal can't be read" or (moveStatus.sliding and "; sliding up a slope now" or ""))
    -- How rough the game's ground is: a landing on a floor that leans can change the
    -- speed and the direction, also on ground that is level on the whole. Counts since
    -- the mod loaded, so two reports give what lay between them.
    local floors, bands, read = moveStatus.floors, {}, 0
    for i = 1, #floors.bands + 1 do
        local label
        if i == 1 then
            label = string.format("under %d deg", floors.bands[1])
        elseif i > #floors.bands then
            label = string.format("%d or more", floors.bands[i - 1])
        else
            label = string.format("%d to %d", floors.bands[i - 1], floors.bands[i])
        end
        bands[i] = string.format("%s: %d", label, floors[i])
        read = read + floors[i]
    end
    line("  floors at landings: %d read (leaning %s); no usable floor at %d landings (found by a line trace, touched "
        .. "with an edge, or not walkable)", read, table.concat(bands, ", "), floors.unusable)
    -- Ducking: the settings and the way the hull follows Half-Life's duck (does E33 let the
    -- character crouch, and while falling: Q1, Q2), the duck now, and the counts since loading
    -- (the game's crouch handlers and its own crouches, refusals, pop-ups, ALS's braking, the
    -- taps, the re-bases of a 2022 ducked landing: Q3, Q4, Q6-Q9, Q14, Q19, Q26).
    local h, dk = hull.status(), movement.duckStatus()
    local hc, u = h.counts, P.unitScale
    line("Ducking (Half-Life's duck, Unreal's crouch): Ducking=%s, DuckHull=%s, OpenAG's %s rule for a duck key "
        .. "under duck tap (HELD_DUCK_UNDER_TAP=%s); the hull: %s (%s)", tostring(cfg.Ducking), tostring(cfg.DuckHull),
        duck.HELD_DUCK_UNDER_TAP and "2022" or "2020", tostring(duck.HELD_DUCK_UNDER_TAP),
        tostring(h.way or "not set up yet"), tostring(h.why or "the mod hasn't taken over a character"))
    if dk.state ~= nil then
        line("  Half-Life's duck now: %s, timer %s ms, view %s units, origin %s cm below the capsule's middle, "
            .. "button down on every update of the last frame=%s, a notch waiting=%s, duck keys wiped (2022 rule)=%s, "
            .. "the last update had the duck button under duck tap=%s, jump down=%s",
            STATE_NAMES[dk.state] or tostring(dk.state), number(dk.timer, "%.0f"), number(dk.view), number(dk.drop),
            tostring(dk.held), tostring(dk.notch), tostring(dk.wiped), tostring(dk.tapHad), tostring(dk.jumpWas))
    else
        line("  Half-Life's duck now: none (the mod doesn't move the character)")
    end
    local eye, eyeFrom = camera.standingEye()
    line("  Unreal's crouch now: crouched at the last hook=%s, the mod holds the crouch wish=%s, a stand-up of the "
        .. "mod's pending=%s, a crouch of the mod's left from before=%s, the crouch is the game's=%s, last asked of "
        .. "Unreal=%s, stand-up refused on the ground=%s, in the air=%s, a refused lift waiting=%s; standing eye %s cm "
        .. "(from %s)", tostring(h.crouched), tostring(h.owned), tostring(h.pendingStand), tostring(h.leftover),
        tostring(h.byGame), tostring(h.lastAsk or "nothing"), tostring(h.refusedGround), tostring(h.refusedAir),
        tostring(h.liftHeld), number(eye), tostring(eyeFrom or "nothing yet"))
    line("  Half-Life's ducks since loading: %d on the ground and %d in the air, stand-ups %d on the ground and %d "
        .. "in the air; duck taps %d (landed %d; lifts %d, refused for lack of room %d; presses that ran into an "
        .. "upward slope, Half-Life's slope boost instead, %d); the next %d duck lines and %d tap lines get a line in "
        .. "the log", dk.groundDucks, dk.airDucks, dk.groundStands, dk.airStands, dk.taps, dk.tapLandings, hc.lifts,
        hc.refusedLifts, dk.runInPresses, dk.duckLinesLeft, dk.tapLinesLeft)
    line("  Unreal's crouch since loading: crouches %d on the ground and %d in the air, stand-ups %d and %d; "
        .. "ducks it never crouched for %d on the ground and %d in the air; stand-ups refused %d, made late %d; "
        .. "pop-ups %d; crouches of the game's own %d (ended by the game %d); stand-ups by the game while the mod "
        .. "held the crouch %d; the duck key read as let go right after a crouch %d; ALS cleared the crouch wish %d",
        hc.groundCrouches, hc.airCrouches, hc.groundStands, hc.airStands, hc.refusedGroundDucks, hc.refusedAirDucks,
        hc.standRefusals, hc.lateStands, hc.popups, hc.gameCrouches, hc.gameStands, hc.gameUncrouches,
        hc.flushSuspects, hc.wishClears)
    line("  ALS's braking at a crouch or stand-up: frames given back %d (%.0f u/s in all, the largest %.0f), too much "
        .. "to give back %d; the floor below, asked to stand up in the air: %d (room %d, no room %d); hull "
        .. "changes in the air re-based %d (stand-ups keeping the feet %d, crouches keeping the feet %d, the middle "
        .. "kept %d, not asked for %d; measured %d, the largest gap from the expected rise %.1f cm)", hc.brakeGiven,
        hc.brakeTotal / u, hc.brakeLargest / u, hc.brakeKept, hc.floorQueries, hc.floorRoom, hc.floorNoRoom,
        hc.rebases, hc.rebaseStandBase, hc.rebaseCrouchBase, hc.rebaseMiddleKept, hc.rebaseUnasked,
        hc.rebasesMeasured, hc.rebaseLargest)
    line("  the hull's detectors: crouches refused in a row %d on the ground and %d in the air, key flushes in a row "
        .. "%d; turned off by errors: the hull %s, the lift %s, the floor query %s; the mod's capsule: standing half "
        .. "height %s cm (unscaled %s, scale %s), radius %s, crouched half height %s (unscaled), %s cm shorter",
        h.refusedInARow.ground, h.refusedInARow.air, h.flushesInARow, tostring(h.stepOff), tostring(h.liftOff),
        tostring(h.floorOff), number(h.standHalf), number(h.standHalfUnscaled), number(h.scale, "%.3f"),
        number(h.radius), number(h.crouchedHalf), number(h.delta))
    line("Physics in cm: max speed %.0f, jump speed %.0f, gravity %.0f, air cap %.0f, unit scale %.2f, "
        .. "updates per second %s", P.maxSpeed, P.jumpSpeed, P.gravity, P.airSpeedCap, P.unitScale,
        P.rate > 0 and tostring(P.rate) or "one per frame")

    -- Only the controller the frame hook got: searching the game's objects while it
    -- loads a save can crash it.
    local pc = env.pc
    if not ue.valid(pc) then
        line("No player controller yet. Load a save, then press the report key again.")
    else
        line("Controller: %s", show(pc))
        line("  class = %s", tostring(ue.className(pc)))
        result("Controller", pc, "IsInBattle")
        result("Controller", pc, "IsMoveInputIgnored")
        result("Controller", pc, "GetControlRotation")
        result("Controller", pc, "GetViewTarget")
        field("Controller", pc, "IsChangingArea")
        field("Controller", pc, "CameraOverrideActor")
        field("Controller", pc, "MyHUD") -- class HUD: the engine's plain one, nothing to hook (see speedometer.lua)
        outResult("Controller", pc, "HasCameraOverride", "HasOverride")
        local dialogue = ue.object(pc, "BP_DialogueSystemComponent")
        if dialogue then
            result("Dialogue", dialogue, "IsInDialogue")
        end
        local cinematic = ue.object(pc, "BP_CinematicSystem")
        if cinematic then
            field("Cinematic", cinematic, "IsPlayingCinematic")
            result("Cinematic", cinematic, "IsInCinematicTransition")
        end

        local pcm = ue.object(pc, "PlayerCameraManager")
        local okCamera, cameraAt = false, nil
        if pcm then
            okCamera, cameraAt = ue.call(pcm, "GetCameraLocation")
        end

        local pawn = ue.object(pc, "Pawn")
        if not pawn then
            line("No character is being controlled.")
        else
            line("Character: %s", show(pawn))
            line("  class = %s, supported = %s", tostring(ue.className(pawn)), tostring(mod.pawnAllowed))
            for _, name in ipairs({ "bIsWorldMapPawn", "BaseEyeHeight", "bFindCameraComponentWhenViewTarget",
                "JumpMaxHoldTime", "JumpMaxCount", "JumpCurrentCount", "TargetRotation", "RootComponent",
                "IsAttachedToMovingPlatform" }) do
                field("Character", pawn, name)
            end
            line("  ALS: %s", values(pawn, { "Gait", "DesiredGait", "RotationMode", "MovementState", "MovementAction",
                "Stance", "ViewMode", "bHasMovementInput", "MovementInputAmount", "Speed" }))
            -- Where ALS turns the body (in the air towards InAirRotation), the body's
            -- rotation, and the engine's own way of turning it, which ALS leaves off.
            line("  ALS rotation: %s", values(pawn, { "TargetRotation", "InAirRotation", "LastVelocityRotation",
                "AimYawRate" }))
            result("Character", pawn, "K2_GetActorRotation")
            field("Character", pawn, "bUseControllerRotationYaw")
            result("Character", pawn, "CanAddMovementInput")
            result("Character", pawn, "CanJump")
            result("Character", pawn, "IsPlayingRootMotion")
            result("Character", pawn, "K2_GetActorLocation")
            result("Character", pawn, "GetPendingMovementInputVector")
            -- The crouch on the character, and what its class has by default: the eye height
            -- Unreal gives a character that stands up (Q13), the crouched eye (Q15).
            local okCrouch, canCrouch = ue.call(pawn, "CanCrouch")
            line("  Character crouch: %s, CanCrouch()=%s", values(pawn, diagnostics.CROUCH_CHARACTER),
                okCrouch and show(canCrouch) or "?")
            local default, defaultPath = classDefault(pawn)
            if default then
                local defaultCapsule = ue.object(default, "CapsuleComponent")
                local defaultCmc = ue.object(default, "CharacterMovement")
                local nav = defaultCmc and ue.get(defaultCmc, "NavAgentProps")
                line("  class default %s: %s, capsule %s, CharacterMovement %s, NavAgentProps.bCanCrouch=%s",
                    defaultPath, values(default, diagnostics.CLASS_DEFAULT),
                    defaultCapsule and values(defaultCapsule, { "CapsuleHalfHeight", "CapsuleRadius" }) or "(none)",
                    defaultCmc and values(defaultCmc, { "CrouchedHalfHeight", "bCanWalkOffLedgesWhenCrouching",
                        "MaxWalkSpeedCrouched" }) or "(none)",
                    ue.typeOf(nav) == "UScriptStruct" and show(ue.get(nav, "bCanCrouch")) or "(none)")
            else
                line("  class default %s: not found", tostring(defaultPath or "(its class can't be read)"))
            end
            local capsule = ue.object(pawn, "CapsuleComponent")
            if capsule then
                result("Capsule", capsule, "GetScaledCapsuleHalfHeight")
                result("Capsule", capsule, "GetScaledCapsuleRadius")
                -- The unscaled sizes Unreal's crouch works with, and the collision profile a
                -- capsule test would need (Q15).
                local parts = {}
                for _, name in ipairs({ "GetUnscaledCapsuleHalfHeight", "GetUnscaledCapsuleRadius",
                    "GetCollisionProfileName" }) do
                    local ok, value = ue.call(capsule, name)
                    parts[#parts + 1] = name .. "()=" .. (ok and show(value) or "?")
                end
                line("  Capsule: %s", table.concat(parts, ", "))
            end
            local function each(classPath, fn)
                local class = ue.find(classPath)
                local ok, list = false, "class not found"
                if class then
                    ok, list = ue.call(pawn, "K2_GetComponentsByClass", class)
                end
                if not ok then
                    line("    (could not list them: %s)", tostring(list))
                    return
                end
                local index = 0
                for _, component in ipairs(ue.list(list)) do
                    if ue.valid(component) then
                        index = index + 1
                        fn(component, index)
                    end
                end
            end
            local function parentOf(component)
                local ok, parent = ue.call(component, "GetAttachParent")
                local okSocket, socket = ue.call(component, "GetAttachSocketName")
                local text = ok and ue.describe(parent) or "?"
                if okSocket and ue.typeOf(socket) == "FName" and socket:ToString() ~= "None" then
                    text = text .. " at " .. socket:ToString()
                end
                return text
            end

            -- The cameras, in the order the engine looks at them: it shows the
            -- first active one.
            local shown = view.camera()
            local closest, closestDistance = nil, math.huge
            local cameras = {}
            each("/Script/Engine.CameraComponent", function(component)
                local okAt, at = ue.call(component, "K2_GetComponentLocation")
                local d = okCamera and okAt and distance(at, cameraAt) or nil
                if d and d < closestDistance then
                    closest, closestDistance = ue.address(component), d
                end
                cameras[#cameras + 1] = { component = component, at = okAt and at or nil, distance = d }
            end)
            line("  Cameras on the character, in the engine's order (%d):", #cameras)
            for index, entry in ipairs(cameras) do
                local component = entry.component
                local address = ue.address(component)
                local tags = {}
                if shown and ue.same(component, shown) then
                    tags[#tags + 1] = "[engine view]"
                end
                if seenView.mainCamera and ue.same(component, seenView.mainCamera) then
                    tags[#tags + 1] = "[GetMainCamera]"
                end
                if seenView.exploration[address] then
                    tags[#tags + 1] = "[exploration]"
                end
                if address == closest then
                    tags[#tags + 1] = "[closest to the view]"
                end
                line("    %d. %s %s: active=%s, %s, attached to %s, at %s, %s cm from the view", index,
                    ue.describe(component), table.concat(tags, " "), tostring(view.isActive(component)),
                    values(component, { "bAutoActivate", "FieldOfView", "bUsePawnControlRotation",
                        "PostProcessBlendWeight" }), parentOf(component), show(entry.at),
                    entry.distance and string.format("%.0f", entry.distance) or "?")
                local post = ue.get(component, "PostProcessSettings")
                if ue.typeOf(post) == "UScriptStruct" then
                    line("       picture: %s", values(post, { "bOverride_AutoExposureBias", "AutoExposureBias",
                        "bOverride_ColorSaturation", "bOverride_BloomIntensity", "bOverride_VignetteIntensity",
                        "bOverride_DepthOfFieldFocalDistance" }))
                end
                local focus = ue.get(component, "FocusSettings")
                if ue.typeOf(focus) == "UScriptStruct" then
                    line("       cine camera: FocusMethod=%s, %s", show(ue.get(focus, "FocusMethod")),
                        values(component, { "CurrentFocalLength", "CurrentAperture",
                            "bOverride_CustomNearClippingPlane", "CustomNearClippingPlane" }))
                    -- The lens limits the focal length, and so the field of view.
                    local lens, filmback = ue.get(component, "LensSettings"), ue.get(component, "Filmback")
                    line("       lens: %s; filmback: %s",
                        ue.typeOf(lens) == "UScriptStruct" and values(lens, { "MinFocalLength", "MaxFocalLength",
                            "SqueezeFactor" }) or "?",
                        ue.typeOf(filmback) == "UScriptStruct" and values(filmback, { "SensorWidth", "SensorHeight" })
                            or "?")
                end
            end
            line("  Spring arms on the character:")
            each("/Script/Engine.SpringArmComponent", function(arm)
                line("    %s, attached to %s: %s", ue.describe(arm), parentOf(arm), values(arm, { "TargetArmLength",
                    "SocketOffset", "TargetOffset", "RelativeLocation", "bUsePawnControlRotation", "bDoCollisionTest",
                    "bEnableCameraLag", "CameraLagSpeed", "bEnableCameraRotationLag", "bInheritPitch", "bInheritYaw",
                    "bIgnoreX", "bIgnoreY", "bIgnoreZ" }))
            end)
            -- The animated meshes: a mesh that isn't drawn stops its animation graph,
            -- and its sounds, unless its tick option says otherwise (see camera.lua).
            -- No weak or soft pointers are read (such as LeaderPoseComponent).
            -- The engine's own mesh, which Unreal moves at a crouch (the skin's body is
            -- what is seen; the game's crouch handler moves CharacterSpringArm: Q3, Q5).
            local ownMesh = ue.object(pawn, "Mesh")
            line("  Character.Mesh = %s%s", show(ue.get(pawn, "Mesh")), ownMesh and string.format(", attached to %s, "
                .. "RelativeLocation=%s", parentOf(ownMesh), show(ue.get(ownMesh, "RelativeLocation"))) or "")
            local skin = ue.object(pawn, "BP_CharacterSkinComponent")
            if skin then
                line("  Skin: %s", values(skin, { "AttachedBodyOnCharacter", "AttachedFaceOnCharacter",
                    "AnimInstanceClass" }))
            end
            local function skinnedMesh(mesh)
                local option = ue.number(mesh, "VisibilityBasedAnimTickOption")
                local was = camera.tickToPutBack(mesh)
                local okSeen, onScreen = ue.call(mesh, "WasRecentlyRendered", 0.2)
                local okAnim, anim = ue.call(mesh, "GetAnimInstance")
                local okLod, lod = ue.call(mesh, "GetPredictedLODLevel")
                local okTick, ticking = ue.call(mesh, "IsComponentTickEnabled")
                line("    %s, owner %s, attached to %s: tick option %s%s, seen recently=%s, ticking=%s, anim instance "
                    .. "%s, %s, predicted LOD %s", ue.describe(mesh),
                    ue.describe(select(2, ue.call(mesh, "GetOwner"))), parentOf(mesh),
                    option and camera.tickName(option) or "?",
                    was and (" [kept animating by the mod, was " .. camera.tickName(was) .. "]") or "",
                    okSeen and tostring(onScreen) or "?", okTick and tostring(ticking) or "?",
                    okAnim and ue.describe(anim) or "?",
                    values(mesh, { "AnimClass", "AnimationMode", "bVisible", "bOwnerNoSee", "bHiddenInGame",
                        "CastShadow", "bCastHiddenShadow", "bEnableUpdateRateOptimizations", "bPauseAnims",
                        "bNoSkeletonUpdate" }),
                    okLod and show(lod) or "?")
                -- ALS's anim instance copies the character's speed when its graph runs:
                -- a stale copy while moving means the graph isn't running.
                local info = okAnim and ue.valid(anim) and ue.get(anim, "CharacterInformation")
                if ue.typeOf(info) == "UScriptStruct" then
                    local cmc = ue.object(pawn, "CharacterMovement")
                    local x, y = ue.vector(cmc and ue.get(cmc, "Velocity"))
                    line("       ALS animation: Speed=%s, the character's ALS Speed=%s, moving at %.0f cm/s, "
                        .. "bIsMoving=%s", show(ue.get(info, "Speed")), show(ue.get(pawn, "Speed")),
                        math.sqrt(x * x + y * y), show(ue.get(info, "bIsMoving")))
                end
            end
            line("  Skinned meshes on the character (BodySounds=%s):", tostring(cfg.BodySounds))
            local listed = {}
            each("/Script/Engine.SkinnedMeshComponent", function(mesh)
                listed[ue.address(mesh) or false] = true
                skinnedMesh(mesh)
            end)
            -- The meshes of actors attached to the character aren't its components, but the
            -- mod hides them with the rest, and keeps them animating too: they are found as
            -- the hiding finds them, through the attached parts.
            local skinnedClass = ue.find("/Script/Engine.SkinnedMeshComponent")
            local okParts, parts = pcall(camera.attachedParts, pawn)
            local others = {}
            for _, part in ipairs(okParts and parts or {}) do
                local address = ue.address(part)
                if skinnedClass and address and not listed[address] then
                    listed[address] = true
                    local okIs, skinned = ue.call(part, "IsA", skinnedClass)
                    if okIs and skinned == true then
                        others[#others + 1] = part
                    end
                end
            end
            line("  Skinned meshes of actors attached to the character:%s", okParts and (#others == 0 and " none" or "")
                or (" could not look for them: " .. tostring(parts)))
            for _, mesh in ipairs(others) do
                skinnedMesh(mesh)
            end
            local controller = ue.object(pawn, "BP_CameraControllerComponent")
            if controller then
                local okTick, ticking = ue.call(controller, "IsComponentTickEnabled")
                line("  BP_CameraControllerComponent: ticking=%s, %s", okTick and tostring(ticking) or "?",
                    values(controller, { "ApplyCameraConfigs", "IsCameraRecentering", "EnableDynamicCameraFocus",
                        "EnableCameraShakeWhenMoving", "CachedControllerRotation" }))
            end
            local componentClass = ue.find("/Script/Engine.ActorComponent")
            if componentClass then
                local ok, components = ue.call(pawn, "K2_GetComponentsByClass", componentClass)
                if ok then
                    local classes = {}
                    for _, component in ipairs(ue.list(components)) do
                        classes[#classes + 1] = tostring(ue.className(component))
                    end
                    line("  components: %s", table.concat(classes, ", "))
                end
            end

            local cmc = ue.object(pawn, "CharacterMovement")
            if cmc then
                line("Movement component: %s", show(cmc))
                line("  class = %s", classChain(cmc))
                for _, name in ipairs({ "MovementMode", "CustomMovementMode", "DefaultLandMovementMode", "Velocity",
                    "MaxWalkSpeed", "MaxAcceleration", "GroundFriction", "BrakingDecelerationWalking",
                    "BrakingDecelerationFalling", "BrakingFrictionFactor", "bUseSeparateBrakingFriction",
                    "BrakingFriction", "FallingLateralFriction", "GravityScale", "JumpZVelocity", "AirControl",
                    "MaxStepHeight", "bStayBasedInAir", "bMaintainHorizontalGroundVelocity", "MaxSimulationTimeStep",
                    "MaxSimulationIterations", "bRequestMovementSettingsChange", "AllowedGait",
                    "bForceUseNavMeshWalking", "bForcePositionOnNavMesh", "CustomDefaultMovementMode",
                    "bUseMovementSettingsWhenFlying", "bOrientRotationToMovement", "bUseControllerDesiredRotation",
                    "WalkableFloorAngle", "WalkableFloorZ", "PerchRadiusThreshold", "bUseFlatBaseForFloorChecks",
                    "LedgeCheckThreshold", "bCanWalkOffLedges" }) do
                    field("Movement", cmc, name)
                end
                -- The floor Unreal's walking found, which the slopes read, field by field.
                local floor = ue.get(cmc, "CurrentFloor")
                if ue.typeOf(floor) == "UScriptStruct" then
                    local hit = ue.get(floor, "HitResult")
                    line("  Movement.CurrentFloor: %s, HitResult.ImpactNormal=%s, HitResult.Normal=%s", values(floor,
                        { "bBlockingHit", "bWalkableFloor", "bLineTrace", "FloorDist", "LineDist" }),
                        normal(ue.get(hit, "ImpactNormal")), normal(ue.get(hit, "Normal")))
                else
                    line("  Movement.CurrentFloor: not found")
                end
                -- Unreal's crouch on the movement component, now (the mod's values while it acts)
                -- and the game's own (Q1, Q15, Q16).
                local nav = ue.get(cmc, "NavAgentProps")
                local okHalf, crouchedHalf = ue.call(cmc, "GetCrouchedHalfHeight")
                line("  Movement crouch: %s, GetCrouchedHalfHeight()=%s, NavAgentProps.bCanCrouch=%s (at the take-over "
                    .. "%s%s); the game's own CrouchedHalfHeight %s, MaxWalkSpeedCrouched %s",
                    values(cmc, diagnostics.CROUCH_MOVEMENT), okHalf and show(crouchedHalf) or "?",
                    ue.typeOf(nav) == "UScriptStruct" and show(ue.get(nav, "bCanCrouch")) or "(none)",
                    tostring(h.canCrouchSeen), h.canCrouchWritten and ", set true by the mod" or "",
                    show(h.gameCrouchedValue), show(moveStatus.gameMaxWalkSpeedCrouched))
                result("Movement", cmc, "GetMaxBrakingDeceleration")
                result("Movement", cmc, "GetMaxAcceleration")
                result("Movement", cmc, "GetMaxSpeed")
                result("Movement", cmc, "GetGravityZ")
                result("Movement", cmc, "GetCurrentAcceleration")
                result("Movement", cmc, "GetImpartedMovementBaseVelocity")
                result("Movement", cmc, "GetMovementBase") -- what Unreal carries the character with
                local movementSettings = ue.get(cmc, "CurrentMovementSettings")
                if ue.typeOf(movementSettings) == "UScriptStruct" then
                    for _, name in ipairs({ "WalkSpeed", "RunSpeed", "SprintSpeed", "MovementCurve" }) do
                        line("  Movement.CurrentMovementSettings.%s = %s", name, show(ue.get(movementSettings, name)))
                    end
                    -- How fast ALS turns the body on the ground: this curve at the mapped
                    -- speed (1 walking, 2 running, 3 sprinting or faster), times 1 to 3 as
                    -- the view turns faster (AimYawRate).
                    local rotationCurve = ue.get(movementSettings, "RotationRateCurve")
                    local rates = {}
                    if ue.valid(rotationCurve) then
                        for _, speed in ipairs({ 1.0, 2.0, 3.0 }) do
                            local ok, rate = ue.call(rotationCurve, "GetFloatValue", speed)
                            rates[#rates + 1] = ok and show(rate) or "?"
                        end
                    end
                    line("  Movement.CurrentMovementSettings.RotationRateCurve = %s%s", show(rotationCurve),
                        #rates > 0 and (", at 1, 2, 3: " .. table.concat(rates, ", ")) or "")
                else
                    line("  Movement.CurrentMovementSettings: not found")
                end
            end
            local limiter = ue.object(pawn, "BP_VelocityControllerComponent")
            if limiter then
                result("Speed limiter", limiter, "IsComponentTickEnabled")
            end
            -- What may react to the long, fast flights slopes make: the game's fall
            -- detector, and ALS's ragdoll or breakfall on landing.
            local fallDetector = ue.object(pawn, "BP_FallDetectorComponent")
            line("  BP_FallDetectorComponent: %s", fallDetector and values(fallDetector, { "EnableKillDetection",
                "KillDistance", "KillTime" }) or "not found")
            line("  ALS on landing: %s", values(pawn, { "bRagdollOnLand", "RagdollOnLandVelocity", "bBreakfallOnLand",
                "BreakfallOnLandVelocity" }))
            -- ALS's crouching settings, which it hands the movement component at each stance
            -- change: a movement curve there brakes the character for a frame (Q7).
            local data = ue.get(pawn, "MovementData")
            if ue.typeOf(data) == "UScriptStruct" then
                local modes = {}
                for _, mode in ipairs(diagnostics.ROTATION_MODES) do
                    local stance = ue.get(data, mode)
                    local crouching = ue.typeOf(stance) == "UScriptStruct" and ue.get(stance, "Crouching")
                    modes[#modes + 1] = mode .. ": " .. (ue.typeOf(crouching) == "UScriptStruct"
                        and values(crouching, diagnostics.MOVEMENT_SETTINGS) or "(none)")
                end
                line("  ALS crouching settings (MovementData): %s", table.concat(modes, "; "))
            else
                line("  ALS crouching settings (MovementData): not found")
            end
        end

        if pcm then
            line("Camera manager: %s", show(pcm))
            line("  class = %s", classChain(pcm))
            for _, name in ipairs({ "CameraStyle", "DefaultFOV", "ViewPitchMin", "ViewPitchMax",
                "bAlwaysApplyModifiers" }) do
                field("Camera", pcm, name)
            end
            line("  Camera:GetCameraLocation() = %s", okCamera and show(cameraAt) or "error")
            result("Camera", pcm, "GetCameraRotation")
            result("Camera", pcm, "GetFOVAngle")
            for _, name in ipairs({ "ViewTarget", "PendingViewTarget" }) do
                local target = ue.get(pcm, name)
                if ue.typeOf(target) == "UScriptStruct" then
                    line("  Camera.%s.Target = %s", name, show(ue.get(target, "Target")))
                end
            end
            for i, modifier in ipairs(ue.list(ue.get(pcm, "ModifierList"))) do
                if ue.valid(modifier) then
                    line("  modifier %d: %s, PitchMin=%s, PitchMax=%s, YawMin=%s, YaxMax=%s", i,
                        tostring(ue.className(modifier)), show(ue.get(modifier, "PitchMin")),
                        show(ue.get(modifier, "PitchMax")), show(ue.get(modifier, "YawMin")),
                        show(ue.get(modifier, "YaxMax")))
                else
                    line("  modifier %d: (none)", i)
                end
            end
        end

        -- The keys the game itself uses for its actions (they can be changed in its settings).
        -- While the mod holds its keys, the game's actions on them are left out of the player's
        -- mappings, so these may miss them then (Q12, Q22).
        local keyStatus = keys.status()
        local holding = keyStatus.context ~= nil
        local marked = holding and " (read while the mod holds its keys)" or ""
        local helpers = ue.find("/Script/SandFall.Default__InputBlueprintHelpers")
        if helpers then
            local function gameKeys(action)
                local ok, list = ue.call(helpers, "TryFindKeysForEnhancedInputActionName", pc, FName(action))
                local found = {}
                if not ok then
                    return "error: " .. tostring(list)
                end
                for _, key in ipairs(ue.list(list)) do
                    found[#found + 1] = show(ue.get(key, "KeyName"))
                end
                return listText(found)
            end
            for _, action in ipairs({ "JumpAction", "ForwardMovementAction", "RightMovementAction" }) do
                line("Game keys for %s: %s%s", action, gameKeys(action), marked)
            end
            local more = {}
            for _, action in ipairs(diagnostics.MORE_ACTIONS) do
                more[#more + 1] = action .. ": " .. gameKeys(action)
            end
            line("Game keys for %s%s", table.concat(more, "; "), marked)
        end

        -- The mod's keys: whether the game has them now, and if not why (a dialogue, a
        -- cinematic or another view target the game shows, a pause, a battle ...: Q22, Q23).
        local why
        if not mod.enabled then
            why = "the mod is switched off"
        elseif cfg.TakeKeys == false then
            why = "TakeKeys = false: the game acts on them too"
        elseif keyStatus.method ~= "context" then
            why = "the mod can't take them: " .. tostring(keyStatus.why)
        else
            why = mod.moveWhy or mod.gameShows or (not mod.moved and "the mod doesn't move the character") or nil
        end
        line("Keys now: %s; the method %s%s%s; the input subsystem %s, the mod's context %s at priority %d; taken %d "
            .. "times, re-made %d, dropped by the game %d, the game's gait put back %d (and by the hand-back guard %d)",
            holding and ("the mod's (" .. listText(keyStatus.taken) .. ")") or ("the game's (" .. tostring(why or
                "none taken yet") .. ")"), keyStatus.method, keyStatus.why and (" (" .. keyStatus.why .. ")") or "",
            keyStatus.alsoGait and ", and the game's walk/run state kept too" or "",
            tostring(keyStatus.subsystem or "not found yet"), tostring(keyStatus.context or "not applied"),
            keyStatus.priority, keyStatus.takes, keyStatus.remakes, keyStatus.drops, keyStatus.gaitPutBack,
            keyStatus.guardPutBack)
        local shown = mod.movedWhileShown or {}
        line("  waiting until let go: %s; the hand-back guard on: %s; frames the mod moved the character while the "
            .. "game showed a dialogue %d, a cinematic %d, another view target %d", tostring(keyStatus.waiting or
                "none"), keyStatus.guard and listText(keyStatus.guard) or "no", shown.dialogue or 0,
            shown.cinematic or 0, shown["view-target"] or 0)
        -- The game's actions on each of the mod's keys, when the keys were last taken and now
        -- (the mod's own action marked): only the mod's means the game waits (Q12).
        local function actionsText(found, mine)
            if not found then
                return "can't be read"
            end
            local parts = {}
            for _, list in ipairs({ cfg.DuckKeys, cfg.DuckTapKeys, cfg.JumpKeys }) do
                for _, name in ipairs(list or {}) do
                    local on = {}
                    for _, action in ipairs(found[name] or {}) do
                        on[#on + 1] = action
                    end
                    if mine and mine[name] then
                        on[#on + 1] = "the mod's"
                    end
                    parts[#parts + 1] = name .. " " .. (#on > 0 and table.concat(on, "+") or "nothing")
                end
            end
            return table.concat(parts, ", ")
        end
        local foundNow, mineNow = keys.mappings(pc)
        line("  the game's actions on the mod's keys at the last take that read them: %s; now: %s",
            keyStatus.gameActions and actionsText(keyStatus.gameActions) or "not read yet",
            foundNow and actionsText(foundNow, mineNow) or "can't be read")
        -- The old-style action mappings on the mod's keys and the wheel, which the mod's
        -- context doesn't hide (is ZoomIn or ZoomOut on the wheel? Q18).
        local inputSettings = ue.find(diagnostics.INPUT_SETTINGS)
        if inputSettings then
            local wanted = { MouseScrollUp = true, MouseScrollDown = true }
            for _, list in ipairs({ cfg.DuckKeys, cfg.DuckTapKeys, cfg.JumpKeys }) do
                for _, name in ipairs(list or {}) do
                    wanted[name] = true
                end
            end
            local found, total = {}, 0
            for _, mapping in ipairs(ue.list(ue.get(inputSettings, "ActionMappings"))) do
                total = total + 1
                local action = show(ue.get(mapping, "ActionName"))
                local key = show(ue.get(ue.get(mapping, "Key"), "KeyName"))
                if wanted[key] or action:find("Zoom", 1, true) then
                    found[#found + 1] = action .. " on " .. key
                end
            end
            line("Legacy action mappings (InputSettings, %d in all) on the mod's keys, the wheel and zoom: %s", total,
                listText(found))
        else
            line("Legacy action mappings: %s not found", diagnostics.INPUT_SETTINGS)
        end

        -- Every key the mod reads, held now; and the keys seen pressed in a frame (the wheel's
        -- notches, quick taps) and the keys ignored until let go (Q10).
        local states = {}
        for _, list in ipairs({ cfg.DuckKeys, cfg.DuckTapKeys, cfg.JumpKeys, cfg.ForwardKeys, cfg.BackKeys,
            cfg.LeftKeys, cfg.RightKeys }) do
            for _, name in ipairs(list or {}) do
                local ok, held = ue.call(pc, "IsInputKeyDown", ue.fkey(name))
                states[#states + 1] = name .. "=" .. (ok and tostring(held) or "error")
            end
        end
        line("Keys held right now: %s", table.concat(states, ", "))
    end
    line("Keys as loaded: DuckKeys=%s, DuckTapKeys=%s, JumpKeys=%s, TakeKeys=%s, TakeJumpKeys=%s; seen pressed so "
        .. "far (wheel notches and quick taps): %s; ignored now (held when the mod took them, the game's until let "
        .. "go): %s", keyList(cfg.DuckKeys), keyList(cfg.DuckTapKeys), keyList(cfg.JumpKeys), tostring(cfg.TakeKeys),
        tostring(cfg.TakeJumpKeys), listText(input.pressesSeen()), listText(input.ignoredKeys()))
    line("==== end of diagnostics ====")
    for _, text in ipairs(lines) do
        log.info("%s", text)
    end
end

return diagnostics
