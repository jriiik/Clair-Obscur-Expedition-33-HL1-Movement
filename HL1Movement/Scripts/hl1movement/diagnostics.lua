-- The status report the diagnostics key writes to UE4SS.log. It lists what the
-- mod finds in the game, so problems can be fixed by someone who can't run it.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local input = require("hl1movement.input")
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
        local ok, text = pcall(function()
            if value.X ~= nil then
                return string.format("(X=%.1f Y=%.1f Z=%.1f)", value.X, value.Y, value.Z)
            elseif value.Yaw ~= nil then
                return string.format("(Pitch=%.1f Yaw=%.1f Roll=%.1f)", value.Pitch, value.Yaw, value.Roll)
            end
            return t
        end)
        return ok and text or t
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

local function names(list)
    return table.concat(list, ", ")
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

    local mod, cfg, P = env.mod, env.cfg, env.P
    line("==== HL1Movement %s diagnostics ====", env.version)
    line("%s; UE4SS has LoopInGameThreadAfterFrames: %s; EngineTickAvailable: %s", _VERSION,
        tostring(rawget(_G, "LoopInGameThreadAfterFrames") ~= nil), tostring(rawget(_G, "EngineTickAvailable")))
    line("Mod: enabled=%s camera wanted=%s camera active=%s movement active=%s frames=%d errors=%d",
        tostring(mod.enabled), tostring(mod.cameraOn), tostring(camera.isActive()), tostring(movement.isActive()),
        mod.frames, mod.errors)
    line("Frame hook: %s", mod.tickHook or ("not registered yet (" .. tostring(mod.hookError) .. ")"))
    line("Jump hook: %s", mod.jumpHook or "not registered")
    local jump = input.status()
    line("Jump input: mode=%s, key seen=%s, game presses=%d, game held=%s, game repeats=%s", cfg.JumpInput,
        tostring(jump.keysSeen), jump.gamePresses, tostring(jump.gameHeld), tostring(jump.repeats))
    local cameraStatus = camera.status()
    line("Camera: style set through %s, hidden parts=%d", cameraStatus.styleRoute, cameraStatus.hiddenParts)
    local moveStatus = movement.status()
    line("Movement: world gravity=%s, curve taken out=%s, curve failed=%s, speed limiter=%s",
        show(moveStatus.worldGravity), tostring(moveStatus.curveTaken), tostring(moveStatus.curveBroken),
        moveStatus.limiter)
    line("Physics in cm: max speed %.0f, jump speed %.0f, gravity %.0f, air cap %.0f, unit scale %.2f",
        P.maxSpeed, P.jumpSpeed, P.gravity, P.airSpeedCap, P.unitScale)

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

        local pawn = ue.object(pc, "Pawn")
        if not pawn then
            line("No character is being controlled.")
        else
            line("Character: %s", show(pawn))
            line("  class = %s, supported = %s", tostring(ue.className(pawn)), tostring(mod.pawnAllowed))
            for _, name in ipairs({ "bIsWorldMapPawn", "BaseEyeHeight", "JumpMaxHoldTime", "JumpMaxCount",
                "RollAnimationThreshold", "TargetRotation", "RootComponent" }) do
                field("Character", pawn, name)
            end
            result("Character", pawn, "CanAddMovementInput")
            result("Character", pawn, "IsPlayingRootMotion")
            result("Character", pawn, "K2_GetActorLocation")
            result("Character", pawn, "GetPendingMovementInputVector")
            local capsule = ue.object(pawn, "CapsuleComponent")
            if capsule then
                result("Capsule", capsule, "GetScaledCapsuleHalfHeight")
                result("Capsule", capsule, "GetScaledCapsuleRadius")
            end
            local mainCamera = ue.object(pawn, "MainCamera")
            line("  MainCamera = %s", show(mainCamera))
            if mainCamera then
                result("MainCamera", mainCamera, "IsActive")
            end
            local componentClass = ue.find("/Script/Engine.ActorComponent")
            if componentClass then
                local ok, components = ue.call(pawn, "K2_GetComponentsByClass", componentClass)
                if ok then
                    local classes = {}
                    for _, component in ipairs(ue.list(components)) do
                        classes[#classes + 1] = tostring(ue.className(component))
                    end
                    line("  components: %s", names(classes))
                end
            end

            local cmc = ue.object(pawn, "CharacterMovement")
            if cmc then
                line("Movement component: %s", show(cmc))
                line("  class = %s", tostring(ue.className(cmc)))
                for _, name in ipairs({ "MovementMode", "Velocity", "MaxWalkSpeed", "MaxAcceleration",
                    "GroundFriction", "BrakingDecelerationWalking", "BrakingDecelerationFalling",
                    "BrakingFrictionFactor", "bUseSeparateBrakingFriction", "BrakingFriction",
                    "FallingLateralFriction", "GravityScale", "JumpZVelocity", "AirControl", "MaxStepHeight",
                    "bRequestMovementSettingsChange" }) do
                    field("Movement", cmc, name)
                end
                result("Movement", cmc, "GetMaxBrakingDeceleration")
                result("Movement", cmc, "GetMaxAcceleration")
                result("Movement", cmc, "GetMaxSpeed")
                result("Movement", cmc, "GetGravityZ")
                local movementSettings = ue.get(cmc, "CurrentMovementSettings")
                if ue.typeOf(movementSettings) == "UScriptStruct" then
                    for _, name in ipairs({ "WalkSpeed", "RunSpeed", "SprintSpeed", "MovementCurve" }) do
                        line("  Movement.CurrentMovementSettings.%s = %s", name, show(ue.get(movementSettings, name)))
                    end
                else
                    line("  Movement.CurrentMovementSettings: not found")
                end
            end
        end

        local pcm = ue.object(pc, "PlayerCameraManager")
        if pcm then
            line("Camera manager: %s", show(pcm))
            line("  class = %s", tostring(ue.className(pcm)))
            for _, name in ipairs({ "CameraStyle", "DefaultFOV", "ViewPitchMin", "ViewPitchMax",
                "bAlwaysApplyModifiers" }) do
                field("Camera", pcm, name)
            end
            result("Camera", pcm, "GetCameraLocation")
            result("Camera", pcm, "GetFOVAngle")
            for i, modifier in ipairs(ue.list(ue.get(pcm, "ModifierList"))) do
                line("  modifier %d: %s, PitchMin=%s, PitchMax=%s", i, tostring(ue.className(modifier)),
                    show(ue.get(modifier, "PitchMin")), show(ue.get(modifier, "PitchMax")))
            end
        end

        local states = {}
        for _, list in ipairs({ cfg.JumpKeys, cfg.ForwardKeys, cfg.BackKeys, cfg.LeftKeys, cfg.RightKeys }) do
            for _, name in ipairs(list) do
                local ok, held = ue.call(pc, "IsInputKeyDown", ue.fkey(name))
                states[#states + 1] = name .. "=" .. (ok and tostring(held) or "error")
            end
        end
        line("Keys held right now: %s", names(states))
    end
    line("==== end of diagnostics ====")
    for _, text in ipairs(lines) do
        log.info("%s", text)
    end
end

return diagnostics
