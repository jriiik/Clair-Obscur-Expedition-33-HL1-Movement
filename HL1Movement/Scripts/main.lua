-- Half-Life movement for Clair Obscur: Expedition 33.
-- UE4SS runs this file when the game starts. See README.md for what the mod does.

local VERSION = "0.2.6"

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
local view = require("hl1movement.view")
local camera = require("hl1movement.camera")
local movement = require("hl1movement.movement")
local diagnostics = require("hl1movement.diagnostics")

local MAX_ERRORS_IN_A_ROW = 30
local SETTLE_TIME = 3 -- seconds to leave a new level or character alone, while the game sets it up
local REPORT_DELAY = 3 -- seconds after first taking over a character, before the automatic report
local CAMERA_REPORT_DELAY = 10 -- seconds after taking over: a camera report if first person still waits
local REPORT_WAIT = 10 -- seconds the report key's report waits at most for the game to finish loading
local STATUS_INTERVAL = 10 -- seconds between status lines while the mod acts
local MAX_STATUS_LINES = 30 -- per session
local MODE_NAMES = { [0] = "none", [1] = "walking", [2] = "nav-mesh walking", [3] = "falling",
    [4] = "swimming", [5] = "flying", [6] = "custom" }
-- First person waiting for these is expected, so it doesn't get a camera report.
local EXPECTED_WAITS = { settings = true, key = true, battle = true, dialogue = true, cinematic = true }
local clock = os and os.clock or function()
    return 0
end

-- The mod's main steps, as their names appear in the log. Each runs on its own
-- (see guard.lua), so one that keeps failing is turned off without the others.
local CAMERA_STEP = "the first-person camera"
local MOVEMENT_STEP = "the Half-Life movement"
local FACING_STEP = "turning the character to the view"

local function newWindow()
    return { frames = 0, time = 0, ticks = 0, cpu = 0, minDt = math.huge, maxDt = 0, turn = 0 }
end

local cfg, P
local mod = {
    enabled = false,
    cameraOn = true,
    tickHook = nil,
    jumpHook = nil,
    hookError = nil,
    hooksWanted = false, -- a hook couldn't be registered inside a hook; done at the next key press or level
    insideHook = false, -- the frame or jump hook is running
    lateHook = false, -- the frame hook runs after the character's movement update
    restarted = false, -- the controller took over a character (ClientRestart); handled on the next frame
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
    reportAt = nil, -- when to write the automatic report
    reported = false, -- the automatic report has been written this session
    cameraReportAt = nil, -- when to check that first person isn't still waiting
    cameraReported = false,
    reportWhy = nil, -- set to write a report at the end of this frame (see writeReport)
    reportAskedAt = nil, -- when the report key asked for it
    offPawnAddr = nil, -- while the mod is off: the character last seen, and the end of its settle
    offSettleUntil = 0,
    givenUpReported = false,
    cameraBlock = nil, -- why first person waits, if it does
    announceCamera = false, -- say what first person does on the next frame, even if nothing changed
    lastYaw = nil,
    nextStatus = nil,
    statusLines = 0,
    window = newWindow(), -- for the status lines
}

-- The reason last logged for each topic ("Character", "First person" ...).
local stateKeys = {}

-- Logs what a part of the mod is doing when it changes. key is a short reason
-- compared every frame; text (a string, or a function that returns one) is the
-- line for the log, worked out only when the key changes. force logs it anyway.
local function state(topic, key, text, force)
    if stateKeys[topic] == key and not force then
        return
    end
    stateKeys[topic] = key
    if type(text) == "function" then
        local ok, result = pcall(text)
        text = ok and tostring(result) or key
    end
    log.state(topic, text or key, force)
end

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

-- For a new level: its loading destroyed the objects the mod had changed, so
-- nothing old is touched.
local function forgetAll()
    camera.forget()
    movement.forget()
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

-- The character's class, whether the mod works with it, and why not.
local function describePawn(pawn)
    local className = ue.className(pawn)
    if className == nil or not supportedClass(className) then
        return className, false, "not supported: the mod works with " .. table.concat(cfg.PawnClasses, ", ")
    end
    if not cfg.AllowWorldMap and ue.get(pawn, "bIsWorldMapPawn") == true then
        return className, false, "not supported: a world map character"
    end
    return className, true, "supported"
end

-- The world's clock as last read (see isPaused).
local worldClock = {
    time = nil, -- GetTimeSeconds
    frame = nil, -- the frame it was read on
    paused = nil, -- what IsGamePaused said then
    off = false, -- the clock doesn't follow the pauses, so it isn't asked again
}

-- Whether Unreal runs this frame as paused: then nothing moves, and the camera
-- manager doesn't work the view out at the end of the frame. Unreal decides that
-- once, at the start of the world's tick, and only then moves the world's clock on
-- (GetTimeSeconds). The game can pause or unpause later in the frame, before this
-- hook, from the controller's own input, and IsGamePaused already says so then.
-- So when IsGamePaused changed since the last frame, the clock tells. It can't
-- disagree with IsGamePaused otherwise; if it does, it doesn't follow the pauses
-- (or doesn't read), and IsGamePaused tells from then on. IsGamePaused also tells
-- when the clock wasn't read on the last frame.
local function isPaused(pc)
    local statics = ue.find("/Script/Engine.Default__GameplayStatics")
    if not statics then
        return false
    end
    local ok, paused = ue.call(statics, "IsGamePaused", pc)
    if not ok then
        return false
    end
    paused = paused == true
    if worldClock.off then
        return paused
    end
    local okTime, time = ue.call(statics, "GetTimeSeconds", pc)
    if not okTime or type(time) ~= "number" then
        worldClock.off = true
        log.info("Can't read the world's clock (GetTimeSeconds: %s), so pauses are told from IsGamePaused alone",
            tostring(time))
        return paused
    end
    local last, lastFrame, lastPaused = worldClock.time, worldClock.frame, worldClock.paused
    worldClock.time, worldClock.frame, worldClock.paused = time, mod.frames, paused
    local stopped = time == last
    if last == nil or lastFrame ~= mod.frames - 1 or stopped == paused then
        return paused
    elseif paused ~= lastPaused then
        -- The game paused or unpaused since this frame started: Unreal runs it as before.
        return stopped
    end
    worldClock.off = true
    log.info("The world's clock (GetTimeSeconds) %s, so pauses are told from IsGamePaused alone",
        stopped and "stood still while the game ran" or "went on while the game was paused")
    return paused
end

-- Why first person can't be on right now: a short key and the text for the log.
local function cameraBlocker(pc, pawn, pcm, inBattle, viewTarget)
    if not cfg.FirstPerson then
        return "settings", "off (FirstPerson = false in config.lua)"
    elseif not mod.cameraOn then
        return "key", "off (switched off with " .. tostring(cfg.CameraKey) .. ")"
    elseif inBattle then
        return "battle", "off (battle)"
    elseif not pcm then
        return "no-camera-manager", "waiting (the controller has no camera manager)"
    end
    view.update(pc, pawn, cfg, mod.now)
    return view.blocker(pawn, viewTarget)
end

local function cameraStep(pc, pawn, pcm, inBattle, viewTarget, paused)
    local force = mod.announceCamera
    mod.announceCamera = false
    camera.watchBlend(pcm, pawn)
    local key, text = cameraBlocker(pc, pawn, pcm, inBattle, viewTarget)
    mod.cameraBlock = key
    if key then
        camera.release()
        state("First person", key, text, force)
        return
    end
    if camera.apply(pc, pawn, pcm, view.camera(), cfg, mod.now, paused) and camera.isActive() then
        -- First person's refreshes start now: the camera list's scans and the
        -- movement's refreshes go between them, on other frames.
        view.stagger(mod.now)
        movement.stagger(mod.now, camera.nextRefresh())
    end
    local status = camera.status()
    state("First person", status.state .. "/" .. tostring(status.method) .. "/" .. tostring(status.waiting), function()
        if status.state == "checking" then
            return "on (" .. status.methodName .. "), checking that the view moved to the eyes"
        elseif status.state == "working" then
            return string.format("on (%s), the view is at the eyes (%.0f cm away)", status.methodName,
                status.lastDistance or 0)
        elseif status.state == "waiting" and status.waiting == "blend" then
            return "waiting (the game's camera is still blending over to your character)"
        elseif status.state == "waiting" or status.state == "off" then
            return "waiting (the game shows no camera to move to the eyes)"
        end
        return status.state
    end, force)
    if status.state:find("^given up") and not mod.givenUpReported then
        mod.givenUpReported = true
        mod.reportWhy = "first person was given up"
    end
end

-- Why the Half-Life movement can't run right now: a short key and the text for the log.
local function movementBlocker(pc, pawn, cmc, inBattle, yaw, mode)
    if not cfg.Movement then
        return "settings", "off (Movement = false in config.lua)"
    elseif mod.lateHook then
        -- The fallback hook runs after the character's movement update: too late
        -- to take the game's input away.
        return "late-hook", "off (only the character's update could be hooked, and it comes too late)"
    elseif not cmc then
        return "no-movement-component", "off (the character has no movement component)"
    elseif yaw == nil then
        return "no-view", "off (can't read the view direction)"
    elseif inBattle then
        return "battle", "off (battle)"
    elseif mode ~= 1 and mode ~= 2 and mode ~= 3 then
        return "mode-" .. tostring(mode), function()
            local custom = mode == 6 and (" " .. tostring(ue.number(cmc, "CustomMovementMode"))) or ""
            return string.format("off (the game's movement mode is %s, %s%s)", tostring(mode),
                MODE_NAMES[mode] or "unknown", custom)
        end
    elseif ask(pc, "IsMoveInputIgnored") == true then
        return "input-ignored", "off (the game ignores movement input)"
    elseif ask(pawn, "CanAddMovementInput") == false then
        return "input-blocked", "off (the game doesn't let the character take movement input)"
    end
    return nil
end

local function movementStep(pc, pawn, cmc, inBattle, yaw, dt, mode, paused, frameDt)
    local key, text = movementBlocker(pc, pawn, cmc, inBattle, yaw, mode)
    if key then
        movement.release()
        state("Half-Life movement", key, text)
        return
    end
    if movement.apply(pawn, cmc, cfg, P, mod.now) and camera.isActive() then
        -- Taken over while first person is on: its refreshes go between first person's.
        movement.stagger(mod.now, camera.nextRefresh())
    end
    state("Half-Life movement", "on", function()
        return string.format("on (movement mode %s, %s)", tostring(mode), MODE_NAMES[mode] or "unknown")
    end)
    if paused then
        movement.hold(mod.frames)
    elseif ask(pawn, "IsPlayingRootMotion") ~= true then
        movement.step(pc, pawn, cmc, cfg, P, dt, yaw, mod.frames, frameDt)
    end
end

local function report(title)
    diagnostics.report({ version = VERSION, mod = mod, cfg = cfg, P = P, pc = mod.pc, title = title })
end

-- Writes the report asked for (mod.reportWhy), at the end of a frame. Not while
-- the game loads or sets up a character (waitingForGame: a boolean, or a function
-- that tells, only asked while a report waits), unless that has gone on for
-- REPORT_WAIT seconds since the report key was first pressed: a wait that doesn't
-- end is worth a report too.
local function writeReport(waitingForGame)
    if not mod.reportWhy then
        return
    end
    if type(waitingForGame) == "function" then
        waitingForGame = waitingForGame()
    end
    if waitingForGame and mod.now - (mod.reportAskedAt or mod.now) < REPORT_WAIT then
        return
    end
    local why = mod.reportWhy
    mod.reportWhy, mod.reportAskedAt = nil, nil
    guard.run("writing the report", report, why)
end

-- While the mod is switched off (or turned itself off), whether a report has to
-- wait as it would with the mod on: for an area change, or a new character's
-- first seconds. Only asked while a report waits.
local function waitingWhileOff(pc)
    local pawnAddr = ue.address(ue.object(pc, "Pawn"))
    if pawnAddr ~= mod.offPawnAddr then
        mod.offPawnAddr = pawnAddr
        mod.offSettleUntil = mod.now + SETTLE_TIME
    end
    return ue.bool(pc, "IsChangingArea") == true or mod.now < mod.offSettleUntil
end

-- One line every STATUS_INTERVAL seconds with the frame rate, the mod's own time
-- per frame and what the movement did, so a test's log shows how it went.
local function statusLine()
    local window = mod.window
    mod.window = newWindow()
    local moved = movement.takeStats()
    if mod.statusLines >= MAX_STATUS_LINES or (moved.frames == 0 and not camera.isActive()) then
        return
    end
    mod.statusLines = mod.statusLines + 1
    local u = P.unitScale
    local fps = window.frames / math.max(window.time, 1e-6)
    local ms = window.ticks > 0 and window.cpu / window.ticks * 1000 or 0
    local parts = { string.format("%.0f fps (%.0f to %.0f), the mod took %.2f ms per frame", fps,
        1 / math.max(window.maxDt, 1e-6), window.minDt < math.huge and 1 / window.minDt or 0, ms) }
    if moved.frames > 0 then
        parts[#parts + 1] = string.format("moved on %d frames with %.1f Half-Life updates each (input from keys %d, "
            .. "stick %d, game %d, none %d)", moved.frames, moved.steps / moved.frames, moved.keys, moved.stick,
            moved.game, moved.none)
        parts[#parts + 1] = string.format("%d hops, top speed %.0f u/s (%.0f on the ground)", moved.hops,
            moved.top / u, moved.topGround / u)
        if moved.airHops > 0 then
            local gain = moved.airGain / moved.airHops / u
            if math.abs(gain) <= 0.5 then
                gain = 0 -- not "-0", as in the hop lines
            end
            parts[#parts + 1] = string.format("per jump %+.0f u/s in the air while the view turned %.0f deg", gain,
                moved.airTurn / moved.airHops)
        end
        if moved.landings > 0 then
            parts[#parts + 1] = string.format("at landing the game took %.0f u/s on average%s",
                moved.landingLoss / moved.landings / u, cfg.KeepSpeed and " (before KeepSpeed)" or "")
        end
        if moved.cuts + moved.wakes + moved.rewrites + moved.leaks > 0 then
            parts[#parts + 1] = string.format("the game cut the speed %d times (%d undone), started its speed limiter "
                .. "%d times, set MaxWalkSpeed %d times; its input reached Unreal on %d frames", moved.cuts,
                moved.restores, moved.wakes, moved.rewrites, moved.leaks)
        end
    end
    parts[#parts + 1] = string.format("the view turned %.0f deg", window.turn)
    log.info("Status (%ds)%s: %s", STATUS_INTERVAL, mod.statusLines == MAX_STATUS_LINES and ", the last one" or "",
        table.concat(parts, "; "))
end

local function onFrame(pc, dt)
    if not ue.valid(pc) or type(dt) ~= "number" or dt <= 0 then
        return
    end
    local window = mod.window
    window.frames = window.frames + 1
    window.time = window.time + dt
    window.minDt = math.min(window.minDt, dt)
    window.maxDt = math.max(window.maxDt, dt)
    local frameDt = dt
    if dt > 0.1 then
        dt = 0.1
    end
    mod.now = mod.now + dt
    mod.frames = mod.frames + 1
    mod.pc = pc
    if not mod.enabled then
        writeReport(function()
            return waitingWhileOff(pc)
        end)
        return
    end

    local pawn = ue.object(pc, "Pawn")
    local world = pc:GetWorld()
    local pcAddr, pawnAddr, worldAddr = ue.address(pc), ue.address(pawn), ue.address(world)
    if mod.restarted or pcAddr ~= mod.pcAddr or pawnAddr ~= mod.pawnAddr or worldAddr ~= mod.worldAddr then
        -- New character, controller or level: put the old one back first, then
        -- give the game a moment to finish setting the new one up.
        if mod.worldAddr and worldAddr ~= mod.worldAddr then
            forgetAll()
        else
            releaseAll()
        end
        camera.retry()
        view.reset()
        mod.restarted = false
        mod.pcAddr, mod.pawnAddr, mod.worldAddr = pcAddr, pawnAddr, worldAddr
        mod.missing = {}
        mod.settleUntil = mod.now + SETTLE_TIME
        mod.lastYaw = nil
        input.reset()
        if pawn then
            local why
            mod.pawnClass, mod.pawnAllowed, why = describePawn(pawn)
            state("Character", tostring(pawnAddr), ue.describe(pawn) .. ", " .. why)
        else
            mod.pawnClass, mod.pawnAllowed = nil, false
            state("Character", "none", "none")
        end
    end
    if mod.recheck and pawn then
        mod.recheck = false
        mod.pawnClass, mod.pawnAllowed = describePawn(pawn)
    end
    if not pawn or not mod.pawnAllowed then
        releaseAll()
        state("First person", "no-character", "off (no supported character)")
        state("Half-Life movement", "no-character", "off (no supported character)")
        writeReport(function()
            return mod.now < mod.settleUntil or ue.bool(pc, "IsChangingArea") == true
        end)
        return
    end
    -- While the game changes area (loads another level), everything is given back
    -- while its objects still exist, and the mod waits.
    if ue.bool(pc, "IsChangingArea") == true then
        releaseAll()
        state("First person", "changing-area", "waiting (the game is changing area)")
        state("Half-Life movement", "changing-area", "waiting (the game is changing area)")
        mod.settleUntil = mod.now + SETTLE_TIME
        writeReport(true)
        return
    end
    if mod.now < mod.settleUntil then
        state("First person", "settling", "waiting (the game is still setting up the character)")
        state("Half-Life movement", "settling", "waiting (the game is still setting up the character)")
        writeReport(true)
        return
    end
    if not mod.reported and not mod.reportAt then
        mod.reportAt = mod.now + REPORT_DELAY
    end
    if not mod.cameraReported and not mod.cameraReportAt then
        mod.cameraReportAt = mod.now + CAMERA_REPORT_DELAY
    end
    mod.nextStatus = mod.nextStatus or (mod.now + STATUS_INTERVAL)

    local cmc = ue.object(pawn, "CharacterMovement")
    local pcm = ue.object(pc, "PlayerCameraManager")
    local inBattle = ask(pc, "IsInBattle") or ask(pc, "IsInBattleBeginTransition") or false
    local okView, viewTarget = ue.call(pc, "GetViewTarget")
    if not okView then
        viewTarget = nil
    end
    local okRotation, rotation = ue.call(pc, "GetControlRotation")
    local yaw = okRotation and type(rotation) == "table" and tonumber(rotation.Yaw) or nil
    if yaw and mod.lastYaw then
        window.turn = window.turn + math.abs((yaw - mod.lastYaw + 180) % 360 - 180)
    end
    mod.lastYaw = yaw
    local paused = isPaused(pc)

    guard.run(CAMERA_STEP, cameraStep, pc, pawn, pcm, inBattle, viewTarget, paused)

    local mode = cmc and ue.number(cmc, "MovementMode") or 0
    guard.run(MOVEMENT_STEP, movementStep, pc, pawn, cmc, inBattle, yaw, dt, mode, paused, frameDt)

    if camera.isActive() and cfg.BodyFollowsView and (mode == 1 or mode == 2 or mode == 3) and yaw then
        guard.run(FACING_STEP, camera.faceView, pawn, yaw)
    end

    if mod.reportAt and mod.now >= mod.reportAt then
        mod.reportAt = nil
        mod.reported = true
        mod.reportWhy = mod.reportWhy or string.format("automatic, %d s after taking over the character",
            REPORT_DELAY)
    end
    if mod.cameraReportAt and mod.now >= mod.cameraReportAt then
        mod.cameraReportAt = nil
        mod.cameraReported = true
        if not camera.isActive() and not EXPECTED_WAITS[mod.cameraBlock or ""] and not mod.givenUpReported then
            mod.reportWhy = mod.reportWhy or string.format("first person is still waiting %d s after taking over",
                CAMERA_REPORT_DELAY)
        end
    end
    writeReport(false)
    if mod.now >= mod.nextStatus then
        mod.nextStatus = mod.now + STATUS_INTERVAL
        guard.run("writing the status line", statusLine)
    end
end

local function safeFrame(pc, dt)
    if mod.broken then
        -- The frame update is off, but the mod's clock goes on, so that the report
        -- key's waits end (see tick).
        if type(dt) == "number" and dt > 0 then
            mod.now = mod.now + math.min(dt, 0.1)
        end
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
        mod.offPawnAddr, mod.offSettleUntil = mod.pawnAddr, mod.settleUntil -- a settle under way goes on
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
    local started = clock()
    safeFrame(obj, ue.unwrap(deltaSeconds))
    if mod.broken and mod.reportWhy and ue.valid(obj) then
        -- The frame update is off, so the report key still gets its report here,
        -- about this frame's controller.
        mod.pc = obj
        writeReport(function()
            return waitingWhileOff(obj)
        end)
    end
    mod.window.ticks = mod.window.ticks + 1
    mod.window.cpu = mod.window.cpu + (clock() - started)
end

-- Runs every frame. The hook is on the player controller's tick, which comes after
-- the frame's input and before the character's movement update.
local function onTick(context, deltaSeconds)
    local outer = mod.insideHook
    mod.insideHook = true
    local ok, err = pcall(tick, context, deltaSeconds)
    mod.insideHook = outer
    if not ok then
        guard.report("the frame hook", err)
    end
    journal.flush()
end

-- The game's jump event comes during input handling, before this frame's tick,
-- so it belongs to the next frame number.
local function onGameJump(_, pressed)
    local outer = mod.insideHook
    mod.insideHook = true
    pcall(input.onGameJump, ue.unwrap(pressed) == true, mod.frames + 1)
    mod.insideHook = outer
end

-- The function is looked up first: a RegisterHook that fails leaves things behind
-- in UE4SS.
local function tryHook(paths, callback)
    local lastError
    for _, path in ipairs(paths) do
        if not ue.find(path) then
            lastError = "the game has no function " .. path .. " (yet)"
        else
            local ok, err = pcall(RegisterHook, path, callback)
            if ok then
                return path
            end
            lastError = err
        end
    end
    return nil, lastError
end

-- The game's classes only exist once a save is loaded, so this is tried again
-- each time the player controller takes over a character, and on key presses
-- while a hook is missing. Never from inside a hook: registering one while UE4SS
-- runs a hook can corrupt its list of hooks.
local function ensureHooks()
    if mod.insideHook then
        mod.hooksWanted = true
        return
    end
    mod.hooksWanted = false
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
    camera.retry(true)
    log.info("Half-Life movement on")
end

local function toggleMod()
    if mod.enabled then
        mod.enabled = false
        mod.offPawnAddr, mod.offSettleUntil = mod.pawnAddr, mod.settleUntil -- a settle under way goes on
        releaseAll()
        log.info("Half-Life movement off")
        state("First person", "mod-off", "off (the mod is switched off)")
        state("Half-Life movement", "mod-off", "off (the mod is switched off)")
    else
        turnOn()
    end
end

local function toggleCamera()
    mod.cameraOn = not mod.cameraOn
    if mod.cameraOn then
        camera.retry(true)
    else
        camera.release()
    end
    log.info("First-person camera %s", mod.cameraOn and "on" or "off")
    mod.announceCamera = true
end

-- The part of reloading the settings that touches the game, on the next frame.
local function applyReloadedSettings()
    releaseAll()
    mod.recheck = true -- check the character again with the new settings
    guard.reset()
    camera.retry(true)
    log.info("Settings reloaded (new hotkeys take effect after restarting the game)")
end

local function reportKey()
    local why = "asked for with " .. tostring(cfg.DiagnosticsKey)
    if mod.tickHook then
        -- Written at the end of this frame, once the mod has looked at the game
        -- (see writeReport). Pressing the key again doesn't start the wait again.
        mod.reportWhy, mod.reportAskedAt = why, mod.reportAskedAt or mod.now
    else
        report(why) -- no save loaded yet, so there is nothing of the game to read
    end
end

-- What each key does when pressed: work that doesn't touch the game, and the
-- action for the next frame. wasHooked: whether the frame hook existed before.
local KEYS = {
    toggle = function(wasHooked)
        if not wasHooked and mod.tickHook then
            -- The frame hook was missing, for example because the hook on the
            -- controller taking over a character failed: now hooked, the key starts the mod.
            return turnOn
        end
        return toggleMod
    end,
    camera = function()
        return toggleCamera
    end,
    reload = function()
        loadSettings() -- only reads config.lua
        ensureHooks() -- JumpInput may need the jump hook now
        return applyReloadedSettings
    end,
    report = function()
        return reportKey
    end,
}

-- Key presses arrive on UE4SS's input thread, while UE4SS holds its Lua lock, so
-- no hook of this mod runs meanwhile, and registering hooks is safe. The game isn't
-- touched there: the action waits for the next frame. Before the frame hook exists
-- (no save loaded yet), it is handed to ExecuteInGameThread instead, which some
-- UE4SS setups don't support.
local function bindKey(name, prepare)
    if not name then
        return
    end
    local code = Key[name]
    if code == nil then
        log.warn("Unknown key %s in config.lua", name)
        return
    end
    local ok, err = pcall(RegisterKeyBind, code, function()
        local wasHooked = mod.tickHook ~= nil
        if not wasHooked or mod.hooksWanted then
            ensureHooks()
        end
        local action = prepare(wasHooked)
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

bindKey(cfg.ToggleKey, KEYS.toggle)
bindKey(cfg.CameraKey, KEYS.camera)
bindKey(cfg.ReloadKey, KEYS.reload)
bindKey(cfg.DiagnosticsKey, KEYS.report)

-- Hooks in straight away if the game is already running, for example after UE4SS
-- restarted its mods. The first frame then puts back what the previous copy of the
-- mod had changed (see journal.lua).
ensureHooks()

-- Kept short: UE4SS runs this without its Lua lock. The old character is put back
-- on the next frame.
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
    mod.restarted = true
end

local restartHooked, restartError = pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart",
    function(context, newPawn)
        local ok, err = pcall(onRestart, context, newPawn)
        if not ok then
            guard.report("taking over a new character", err)
        end
    end)
if not restartHooked then
    log.warn("Could not hook PlayerController:ClientRestart (%s). After loading a save, press %s to start the "
        .. "mod. If nothing happens, please report UE4SS.log.", tostring(restartError), tostring(cfg.ToggleKey))
end

log.info("Version %s loaded. %s turns it on and off, %s switches the camera, %s writes a report to this log.",
    VERSION, tostring(cfg.ToggleKey), tostring(cfg.CameraKey), tostring(cfg.DiagnosticsKey))
