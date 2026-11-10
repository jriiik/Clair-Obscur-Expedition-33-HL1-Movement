-- The status report the mod writes to UE4SS.log: by itself a few seconds after
-- taking over a character, when first person is given up or still waits, and when
-- the diagnostics key is pressed. It lists what the mod finds in the game, so
-- problems can be fixed by someone who can't run it.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local input = require("hl1movement.input")
local view = require("hl1movement.view")
local camera = require("hl1movement.camera")
local movement = require("hl1movement.movement")

local diagnostics = {}

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
    line("First person: %s with %s (style set through %s), hidden parts=%d, camera to eyes=%s cm%s",
        cameraStatus.state, cameraStatus.methodName, cameraStatus.styleRoute, cameraStatus.hiddenParts,
        show(cameraStatus.lastDistance), mod.cameraBlock and (", waiting because: " .. mod.cameraBlock) or "")
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

    local moveStatus = movement.status()
    line("Movement: world gravity=%s, curve taken out=%s, curve failed=%s, speed limiter=%s",
        show(moveStatus.worldGravity), tostring(moveStatus.curveTaken), tostring(moveStatus.curveBroken),
        moveStatus.limiter)
    local counts = moveStatus.counts
    line("  GetMaxSpeed() after setting MaxWalkSpeed: %s; the game's own MaxWalkSpeed: %s; hops logged: %d",
        show(moveStatus.maxSpeed), show(moveStatus.gameMaxWalkSpeed), moveStatus.hops)
    line("  since taking over: speed cuts %d (undone %d), MaxWalkSpeed set by the game %d, speed limiter started "
        .. "%d, the game's input reaching Unreal %d, velocity changed at a jump %d", counts.cuts, counts.restores,
        counts.rewrites, counts.wakes, counts.leaks, counts.jumpChanges)
    line("Physics in cm: max speed %.0f, jump speed %.0f, gravity %.0f, air cap %.0f, unit scale %.2f, "
        .. "updates per second %s", P.maxSpeed, P.jumpSpeed, P.gravity, P.airSpeedCap, P.unitScale,
        P.rate > 0 and tostring(P.rate) or "one per frame")

    local pc = env.pc
    if not ue.valid(pc) then
        local ok, found = pcall(FindFirstOf, "PlayerController")
        if ok and ue.valid(found) then
            pc = found
        end
    end
    if not ue.valid(pc) then
        line("No player controller found. Load a save and try again.")
    else
        line("Controller: %s", show(pc))
        line("  class = %s", tostring(ue.className(pc)))
        result("Controller", pc, "IsInBattle")
        result("Controller", pc, "IsMoveInputIgnored")
        result("Controller", pc, "GetControlRotation")
        result("Controller", pc, "GetViewTarget")
        field("Controller", pc, "IsChangingArea")
        field("Controller", pc, "CameraOverrideActor")
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
                "JumpMaxHoldTime", "JumpMaxCount", "JumpCurrentCount", "TargetRotation", "RootComponent" }) do
                field("Character", pawn, name)
            end
            line("  ALS: %s", values(pawn, { "Gait", "DesiredGait", "RotationMode", "MovementState", "MovementAction",
                "Stance", "bHasMovementInput", "MovementInputAmount" }))
            result("Character", pawn, "CanAddMovementInput")
            result("Character", pawn, "CanJump")
            result("Character", pawn, "IsPlayingRootMotion")
            result("Character", pawn, "K2_GetActorLocation")
            result("Character", pawn, "GetPendingMovementInputVector")
            local capsule = ue.object(pawn, "CapsuleComponent")
            if capsule then
                result("Capsule", capsule, "GetScaledCapsuleHalfHeight")
                result("Capsule", capsule, "GetScaledCapsuleRadius")
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
                end
            end
            line("  Spring arms on the character:")
            each("/Script/Engine.SpringArmComponent", function(arm)
                line("    %s, attached to %s: %s", ue.describe(arm), parentOf(arm), values(arm, { "TargetArmLength",
                    "SocketOffset", "TargetOffset", "RelativeLocation", "bUsePawnControlRotation", "bDoCollisionTest",
                    "bEnableCameraLag", "CameraLagSpeed", "bEnableCameraRotationLag", "bInheritPitch", "bInheritYaw",
                    "bIgnoreX", "bIgnoreY", "bIgnoreZ" }))
            end)
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
                    "MaxStepHeight", "bRequestMovementSettingsChange", "AllowedGait", "bForceUseNavMeshWalking",
                    "bForcePositionOnNavMesh", "CustomDefaultMovementMode", "bUseMovementSettingsWhenFlying" }) do
                    field("Movement", cmc, name)
                end
                result("Movement", cmc, "GetMaxBrakingDeceleration")
                result("Movement", cmc, "GetMaxAcceleration")
                result("Movement", cmc, "GetMaxSpeed")
                result("Movement", cmc, "GetGravityZ")
                result("Movement", cmc, "GetCurrentAcceleration")
                result("Movement", cmc, "GetImpartedMovementBaseVelocity")
                local movementSettings = ue.get(cmc, "CurrentMovementSettings")
                if ue.typeOf(movementSettings) == "UScriptStruct" then
                    for _, name in ipairs({ "WalkSpeed", "RunSpeed", "SprintSpeed", "MovementCurve" }) do
                        line("  Movement.CurrentMovementSettings.%s = %s", name, show(ue.get(movementSettings, name)))
                    end
                else
                    line("  Movement.CurrentMovementSettings: not found")
                end
            end
            local limiter = ue.object(pawn, "BP_VelocityControllerComponent")
            if limiter then
                result("Speed limiter", limiter, "IsComponentTickEnabled")
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
        local helpers = ue.find("/Script/SandFall.Default__InputBlueprintHelpers")
        if helpers then
            for _, action in ipairs({ "JumpAction", "ForwardMovementAction", "RightMovementAction" }) do
                local ok, keys = ue.call(helpers, "TryFindKeysForEnhancedInputActionName", pc, FName(action))
                local found = {}
                if ok then
                    for _, key in ipairs(ue.list(keys)) do
                        found[#found + 1] = show(ue.get(key, "KeyName"))
                    end
                end
                line("Game keys for %s: %s", action, ok and (#found > 0 and table.concat(found, ", ") or "none")
                    or ("error: " .. tostring(keys)))
            end
        end

        local states = {}
        for _, list in ipairs({ cfg.JumpKeys, cfg.ForwardKeys, cfg.BackKeys, cfg.LeftKeys, cfg.RightKeys }) do
            for _, name in ipairs(list) do
                local ok, held = ue.call(pc, "IsInputKeyDown", ue.fkey(name))
                states[#states + 1] = name .. "=" .. (ok and tostring(held) or "error")
            end
        end
        line("Keys held right now: %s", table.concat(states, ", "))
    end
    line("==== end of diagnostics ====")
    for _, text in ipairs(lines) do
        log.info("%s", text)
    end
end

return diagnostics
