-- Half-Life movement for Clair Obscur: Expedition 33.
-- UE4SS runs this file when the game starts. See README.md for what the mod does.

local VERSION = "0.1.0"

-- The folder this file is in, so the mod's modules and config.lua are found
-- wherever the mod is installed.
local function scriptDirectory()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local source = info and info.source or ""
    if source:sub(1, 1) ~= "@" then
        return ""
    end
    return source:sub(2):match("^(.*[/\\])") or ""
end

local DIR = scriptDirectory()
if DIR ~= "" then
    package.path = DIR .. "?.lua;" .. package.path
end

local log = require("hl1movement.log")
local settings = require("hl1movement.settings")
local ue = require("hl1movement.ue")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local input = require("hl1movement.input")
local camera = require("hl1movement.camera")
local movement = require("hl1movement.movement")
local diagnostics = require("hl1movement.diagnostics")

local MAX_ERRORS_IN_A_ROW = 30
local SETTLE_TIME = 1 -- seconds to leave a new level or character alone, while the game sets it up

-- The mod's main steps, as their names appear in the log. Each runs on its own
-- (see guard.lua), so one that keeps failing is turned off without the others.
local CAMERA_STEP = "the first-person camera"
local MOVEMENT_STEP = "the Half-Life movement"
local FACING_STEP = "turning the character to the view"

local cfg, P
local mod = {
    enabled = false,
    cameraOn = true,
    tickHook = nil,
    jumpHook = nil,
    hookError = nil,
    lateHook = false, -- the frame hook runs after the character's movement update
    pc = nil,
    pcAddr = nil,
    pawnAddr = nil,
    worldAddr = nil,
    pawnClass = nil,
    pawnAllowed = false,
    settleUntil = 0,
    missing = {}, -- functions the game's objects turned out not to have
    queue = {}, -- hotkey actions waiting for the next frame
    now = 0,
    frames = 0,
    errors = 0,
    errorsInARow = 0,
    broken = false,
}

local function loadSettings()
    local user, problem
    if DIR ~= "" then
        local ok, result = pcall(dofile, DIR .. "config.lua")
        if ok then
            user = result
        else
            problem = result
        end
    else
        local ok, result = pcall(require, "config")
        if ok then
            user = result
        else
            problem = result
        end
    end
    local warnings
    cfg, warnings = settings.load(user, rawget(_G, "Key"))
    P = settings.physics(cfg)
    log.debugEnabled = cfg.Debug
    if problem then
        log.warn("Could not read config.lua, so the default settings are used: %s", tostring(problem))
    end
    for _, warning in ipairs(warnings) do
        log.warn("%s", warning)
    end
    guard.retryHint = cfg.ToggleKey and string.format("Press %s twice to try again", cfg.ToggleKey)
        or "Restart the game to try again"
end

local function releaseAll()
    camera.release()
    movement.release()
end

-- Calls a function that answers true or false, such as IsInBattle. Returns nil
-- (and stops asking) if this object has no such function.
local function ask(obj, name)
    local address = ue.address(obj)
    if not address then
        return nil
    end
    local missing = mod.missing[address]
    if missing and missing[name] then
        return nil
    end
    local ok, result = ue.call(obj, name)
    if not ok then
        mod.missing[address] = missing or {}
        mod.missing[address][name] = true
        log.debug("%s has no usable %s: %s", tostring(ue.className(obj)), name, tostring(result))
        return nil
    end
    return result == true
end

local function supportedClass(className)
    for _, name in ipairs(cfg.PawnClasses) do
        if name == className then
            return true
        end
    end
    return false
end

local function describePawn(pawn)
    local className = ue.className(pawn)
    local allowed = className ~= nil and supportedClass(className)
    if allowed and not cfg.AllowWorldMap and ue.get(pawn, "bIsWorldMapPawn") == true then
        allowed = false
    end
    return className, allowed
end

-- False while the game shows the view from another camera on the character, for
-- example in dialogue.
local function gameCameraActive(pawn)
    local mainCamera = ue.object(pawn, "MainCamera")
    if not mainCamera then
        return true
    end
    local ok, active = ue.call(mainCamera, "IsActive")
    return not ok or active == true
end

local function isPaused(pc)
    local statics = ue.find("/Script/Engine.Default__GameplayStatics")
    if not statics then
        return false
    end
    local ok, paused = ue.call(statics, "IsGamePaused", pc)
    return ok and paused == true
end

local function cameraStep(pc, pawn, pcm, inBattle, viewingPawn, paused)
    if cfg.FirstPerson and mod.cameraOn and not inBattle and viewingPawn and pcm and gameCameraActive(pawn) then
        camera.apply(pc, pawn, pcm, cfg, mod.now, paused)
    else
        camera.release()
    end
end

local function movementStep(pc, pawn, cmc, inBattle, yaw, dt, walkingOrFalling, paused)
    -- A frame hook that runs after the character's movement update (the fallback
    -- hook) comes too late to take the game's input away, so it doesn't move.
    local canMove = cfg.Movement and not mod.lateHook and cmc ~= nil and yaw ~= nil and not inBattle
        and walkingOrFalling
        and ask(pc, "IsMoveInputIgnored") ~= true
        and ask(pawn, "CanAddMovementInput") ~= false
    if canMove then
        movement.apply(pawn, cmc, cfg, P, mod.now)
        if not paused and ask(pawn, "IsPlayingRootMotion") ~= true then
            movement.step(pc, pawn, cmc, cfg, P, dt, yaw, mod.frames)
        end
    else
        movement.release()
    end
end

local function onFrame(pc, dt)
    if not ue.valid(pc) or type(dt) ~= "number" or dt <= 0 then
        return
    end
    if dt > 0.1 then
        dt = 0.1
    end
    mod.now = mod.now + dt
    mod.frames = mod.frames + 1
    mod.pc = pc
    if not mod.enabled then
        return
    end

    local pawn = ue.object(pc, "Pawn")
    local world = pawn and pawn:GetWorld()
    local pcAddr, pawnAddr, worldAddr = ue.address(pc), ue.address(pawn), ue.address(world)
    if pcAddr ~= mod.pcAddr or pawnAddr ~= mod.pawnAddr or worldAddr ~= mod.worldAddr then
        -- New character, controller or level: put the old one back first, then
        -- give the game a moment to finish setting the new one up.
        releaseAll()
        camera.retry()
        mod.pcAddr, mod.pawnAddr, mod.worldAddr = pcAddr, pawnAddr, worldAddr
        mod.missing = {}
        mod.settleUntil = mod.now + SETTLE_TIME
        input.reset()
        if pawn then
            mod.pawnClass, mod.pawnAllowed = describePawn(pawn)
            log.debug("Controlling %s (%s)", tostring(mod.pawnClass),
                mod.pawnAllowed and "supported" or "not supported, so the mod waits")
        else
            mod.pawnClass, mod.pawnAllowed = nil, false
        end
    end
    if mod.recheck and pawn then
        mod.recheck = false
        mod.pawnClass, mod.pawnAllowed = describePawn(pawn)
    end
    if not pawn or not mod.pawnAllowed then
        releaseAll()
        return
    end
    if mod.now < mod.settleUntil then
        return
    end

    local cmc = ue.object(pawn, "CharacterMovement")
    local pcm = ue.object(pc, "PlayerCameraManager")
    local inBattle = ask(pc, "IsInBattle") or ask(pc, "IsInBattleBeginTransition") or false
    local okView, viewTarget = ue.call(pc, "GetViewTarget")
    local viewingPawn = okView and ue.address(viewTarget) == pawnAddr
    local okRotation, rotation = ue.call(pc, "GetControlRotation")
    local yaw = okRotation and type(rotation) == "table" and tonumber(rotation.Yaw) or nil
    local paused = isPaused(pc)

    guard.run(CAMERA_STEP, cameraStep, pc, pawn, pcm, inBattle, viewingPawn, paused)

    local mode = cmc and ue.number(cmc, "MovementMode") or 0
    local walkingOrFalling = mode == 1 or mode == 2 or mode == 3
    guard.run(MOVEMENT_STEP, movementStep, pc, pawn, cmc, inBattle, yaw, dt, walkingOrFalling, paused)

    if camera.isActive() and cfg.BodyFollowsView and walkingOrFalling and yaw then
        guard.run(FACING_STEP, camera.faceView, pawn, yaw)
    end
end

local function safeFrame(pc, dt)
    if mod.broken then
        return
    end
    local ok, err = pcall(onFrame, pc, dt)
    if ok then
        mod.errorsInARow = 0
        return
    end
    mod.errors = mod.errors + 1
    mod.errorsInARow = mod.errorsInARow + 1
    guard.report("the mod's frame update", err)
    if mod.errorsInARow >= MAX_ERRORS_IN_A_ROW then
        mod.broken = true
        mod.enabled = false
        pcall(releaseAll)
        log.warn("Turned off after %d errors in a row. Press %s to try again, and please report UE4SS.log.",
            mod.errorsInARow, tostring(cfg.ToggleKey))
    end
end

local function runAction(action)
    local ok, err = pcall(action)
    if not ok then
        guard.report("a hotkey action", err)
    end
    journal.flush()
end

-- Hotkey actions wait here and run at the start of the next frame, on the game
-- thread, never in the middle of something the game is doing (such as a level load).
local function runQueued()
    if #mod.queue == 0 then
        return
    end
    local queue = mod.queue
    mod.queue = {}
    for _, action in ipairs(queue) do
        runAction(action)
    end
end

-- After UE4SS restarts its mods, the previous copy of this mod is gone without
-- having put the game back. Its changes are in the journal: put them back first.
local function restoreLeftovers()
    local restored, total = journal.restorePending()
    log.info("UE4SS restarted its mods while this mod was active. Put back %d of %d game values "
        .. "the previous copy had changed.", restored, total)
    if restored < total then
        log.warn("The other %d could not be found. If something feels wrong, load a save.", total - restored)
    end
end

local function tick(context, deltaSeconds)
    if journal.hasPending() then
        restoreLeftovers()
    end
    runQueued()
    local obj = ue.unwrap(context)
    local controllerClass = ue.find("/Script/Engine.PlayerController")
    local late = false
    if controllerClass and ue.valid(obj) and not obj:IsA(controllerClass) then
        -- Hooked on the character's tick instead: use its controller.
        obj = ue.object(obj, "Controller")
        if not obj or not obj:IsA(controllerClass) then
            return
        end
        late = true
    end
    if late and not mod.lateHook then
        log.warn("Only the character's update could be hooked. It runs after the game has moved the character, "
            .. "so the Half-Life movement stays off; first person still works. Please report UE4SS.log.")
    end
    mod.lateHook = late
    safeFrame(obj, ue.unwrap(deltaSeconds))
end

-- Runs every frame. The hook is on the player controller's tick, which comes after
-- the frame's input and before the character's movement update.
local function onTick(context, deltaSeconds)
    tick(context, deltaSeconds)
    journal.flush()
end

-- The game's jump event comes during input handling, before this frame's tick,
-- so it belongs to the next frame number.
local function onGameJump(_, pressed)
    input.onGameJump(ue.unwrap(pressed) == true, mod.frames + 1)
end

local function tryHook(paths, callback)
    local lastError
    for _, path in ipairs(paths) do
        local ok, err = pcall(RegisterHook, path, callback)
        if ok then
            return path
        end
        lastError = err
    end
    return nil, lastError
end

-- The game's classes only exist once a save is loaded, so this is tried again
-- each time the player controller takes over a character.
local function ensureHooks()
    if not mod.tickHook then
        local path, err = tryHook(cfg.TickFunctions, onTick)
        if path then
            mod.tickHook = path
            mod.hookError = nil
            log.info("Running every frame from %s", path)
        else
            mod.hookError = tostring(err)
        end
    end
    if not mod.jumpHook and cfg.JumpInput ~= "keys" then
        local path, err = tryHook(cfg.JumpFunctions, onGameJump)
        if path then
            mod.jumpHook = path
            log.debug("Watching the game's jump input: %s", path)
        elseif cfg.JumpInput == "game" and mod.tickHook then
            log.once("no-jump-hook", 'JumpInput is "game", but the game\'s jump event could not be hooked (%s), '
                .. 'so holding jump won\'t hop. Remove JumpInput from config.lua to use the keys.', tostring(err))
        end
    end
end

local function turnOn()
    mod.enabled = true
    mod.broken = false
    mod.errorsInARow = 0
    guard.reset()
    camera.retry()
    log.info("Half-Life movement on")
end

local function toggleMod()
    if not mod.tickHook then
        -- No frame hook yet, for example because the hook on the controller taking
        -- over a character failed: hook in now, and then the key starts the mod.
        ensureHooks()
        if mod.tickHook then
            turnOn()
            return
        end
    end
    if mod.enabled then
        mod.enabled = false
        releaseAll()
        log.info("Half-Life movement off")
    else
        ensureHooks()
        turnOn()
    end
end

local function toggleCamera()
    mod.cameraOn = not mod.cameraOn
    if mod.cameraOn then
        camera.retry()
    else
        camera.release()
    end
    log.info("First-person camera %s", mod.cameraOn and "on" or "off")
end

local function reloadSettings()
    releaseAll()
    loadSettings()
    mod.recheck = true -- check the character again with the new settings
    guard.reset()
    camera.retry()
    ensureHooks() -- JumpInput may need the jump hook now
    log.info("Settings reloaded (new hotkeys take effect after restarting the game)")
end

local function report()
    diagnostics.report({ version = VERSION, mod = mod, cfg = cfg, P = P, pc = mod.pc })
end

-- Key presses arrive on UE4SS's input thread. The action is queued for the next
-- frame. Before the frame hook exists (no save loaded yet), it is handed to
-- ExecuteInGameThread instead, which some UE4SS setups don't support.
local function bindKey(name, action)
    if not name then
        return
    end
    local code = Key[name]
    if code == nil then
        log.warn("Unknown key %s in config.lua", name)
        return
    end
    local ok, err = pcall(RegisterKeyBind, code, function()
        if mod.tickHook then
            mod.queue[#mod.queue + 1] = action
            return
        end
        local handed = pcall(ExecuteInGameThread, function()
            runAction(action)
        end)
        if not handed then
            mod.queue[#mod.queue + 1] = action
        end
    end)
    if not ok then
        log.warn("Could not use key %s: %s", name, tostring(err))
    end
end

loadSettings()
mod.enabled = cfg.StartEnabled
mod.cameraOn = true

guard.whenOff(CAMERA_STEP, camera.release)
guard.whenOff(MOVEMENT_STEP, movement.release)
journal.load() -- what a previous copy of the mod left changed, if UE4SS restarted the mods

bindKey(cfg.ToggleKey, toggleMod)
bindKey(cfg.CameraKey, toggleCamera)
bindKey(cfg.ReloadKey, reloadSettings)
bindKey(cfg.DiagnosticsKey, report)

-- Hooks in straight away if the game is already running, for example after UE4SS
-- restarted its mods. The first frame then puts back what the previous copy of the
-- mod had changed (see journal.lua).
ensureHooks()

local function onRestart(_, newPawn)
    ensureHooks()
    if not mod.tickHook then
        local className = ue.className(ue.unwrap(newPawn))
        if className and supportedClass(className) then
            log.once("no-tick-hook", "Could not hook the game's frame update, so the mod can't run: %s",
                tostring(mod.hookError))
        else
            -- The title screen: the game's classes load with a save.
            log.debug("No frame hook yet (%s); waiting for a save", tostring(mod.hookError))
        end
    end
    -- The controller is taking over a character: put the old one back.
    releaseAll()
    mod.pawnAddr = nil
end

local restartHooked, restartError = pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart",
    function(context, newPawn)
        local ok, err = pcall(onRestart, context, newPawn)
        if not ok then
            guard.report("taking over a new character", err)
        end
        journal.flush()
    end)
if not restartHooked then
    log.warn("Could not hook PlayerController:ClientRestart (%s). After loading a save, press %s to start the "
        .. "mod. If nothing happens, please report UE4SS.log.", tostring(restartError), tostring(cfg.ToggleKey))
end

log.info("Version %s loaded. %s turns it on and off, %s switches the camera, %s writes a report to this log.",
    VERSION, tostring(cfg.ToggleKey), tostring(cfg.CameraKey), tostring(cfg.DiagnosticsKey))
