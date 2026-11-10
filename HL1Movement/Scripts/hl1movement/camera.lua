-- First-person camera.
--
-- There are two ways to look out of the character's eyes (setting CameraMethod):
--
-- "engine": Unreal's player camera manager has a built-in "FirstPerson" camera
-- style: the view from the character's eyes (its position plus BaseEyeHeight),
-- turned with the mouse, with the camera manager's DefaultFOV. It ignores the
-- game's camera rig, so nothing the game does to its cameras gets in the way, but
-- the game camera's own picture settings (exposure, colour grading, depth of
-- field) and camera shakes don't apply. The camera manager's CameraStyle field
-- isn't visible to UE4SS in Unreal 5.4, so the style is set through the player
-- controller's ClientSetCameraMode, every frame, and put back to "Default".
--
-- "game": the camera the game shows is taken off its spring arm and attached to
-- the character's capsule at eye height, turning with the mouse. The game's
-- picture settings stay. Its depth of field is switched off (it would focus on the
-- hidden body), and so is the shake while running.
--
-- "auto" starts with "engine". Whether the view really is at the eyes is checked
-- every frame until it is, then every half second. If it stays away for
-- GIVE_UP_TIME (time paused doesn't count, and a camera that is clearly getting
-- closer gets more), "auto" switches to "game", and keeps using "game" with this
-- kind of camera manager. If that doesn't work either, the mod gives up and shows
-- the game's camera and the character again, instead of leaving an invisible
-- character in third person.
--
-- Both hide the character's body from the player's view and widen the pitch
-- limits. Everything changed is put back when first person switches off.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local Overrides = require("hl1movement.overrides")

local camera = {}

local EYE_FACTOR = 0.78 -- "auto" eye height, as a share of the capsule's half height
local REFRESH = 0.5 -- seconds between re-checks of the pitch limits, the body and the shakes
local MAX_EYE_DISTANCE = 50 -- cm between the camera and the eyes that still counts as first person
local GIVE_UP_TIME = 2 -- seconds of the camera not being at the eyes before trying something else
local PRIMITIVE = "/Script/Engine.PrimitiveComponent"
local KEEP_RELATIVE, SNAP_TO_TARGET = 0, 2 -- EAttachmentRule
local FOCUS_DISABLED = 3 -- ECameraFocusMethod::Disable
local NAME_CHECK_EVERY = 4 -- hiding passes between checks of the hidden parts' full names
local MAX_MOVE_LINES = 3

local overrides = Overrides.new()
local hidden = {} -- address -> { obj, fullName, how, was }
local waiting = {} -- address -> full name of parts seen once, hidden if still there next pass
local notPrimitive = {} -- address -> true for attached components that can't be seen
local st = {
    active = false,
    method = nil, -- "engine" or "game" while active
    pawnAddr = nil,
    pcmAddr = nil,
    pcmClass = nil,
    nextRefresh = 0,
    frames = 0,
    passes = 0, -- body hiding passes since first person started
    confirmed = false, -- the camera has been seen at the eyes since this method started
    failingSince = nil, -- when the checks started failing
    failingDistance = nil, -- the distance then
    lastDistance = nil, -- cm between the camera and the eyes at the last check
    unavailable = nil, -- why first person was given up, until camera.retry()
    unavailablePcm = nil,
    engineFailed = {}, -- camera manager class -> why the engine's view didn't reach the eyes
    hasTargetRotation = false,
    styleSetter = nil, -- { pc, fullName } when the style was set with ClientSetCameraMode
    styleFailed = false,
    styleRoute = nil,
    styleFieldPcm = nil, -- the camera manager last checked for a CameraStyle field
    hasStyleField = false,
    moved = nil, -- the game camera while it is at the eyes (see moveCamera)
    moveLines = 0,
}

function camera.isActive()
    return st.active
end

local names = {}

local function fname(name)
    names[name] = names[name] or FName(name)
    return names[name]
end

-- Engine method -------------------------------------------------------------

-- The camera manager's CameraStyle, or nil if UE4SS can't see that field. Looked
-- for once per camera manager.
local function styleField(pcm)
    local address = ue.address(pcm)
    if st.styleFieldPcm == address and not st.hasStyleField then
        return nil
    end
    local value = ue.get(pcm, "CameraStyle")
    st.styleFieldPcm = address
    st.hasStyleField = ue.typeOf(value) == "FName"
    return st.hasStyleField and value or nil
end

local function setStyleWithFunction(pc, name)
    local ok, err = ue.call(pc, "ClientSetCameraMode", fname(name))
    st.styleFailed = not ok
    if not ok then
        log.once("camera-style-set", "Could not switch the camera style: %s", tostring(err))
    end
    return ok
end

-- Switches the camera manager to the FirstPerson style. Called every frame.
local function useFirstPersonStyle(pc, pcm, refresh)
    local current = styleField(pcm)
    if current then
        st.styleRoute = "CameraStyle field"
        if current:ToString() ~= "FirstPerson" then
            overrides:set(pcm, "CameraStyle", fname("FirstPerson"))
        end
        return
    end
    -- The field isn't visible to UE4SS (as in Expedition 33), so the controller
    -- sets it. That can't be read back, so it is set every frame: it only stores
    -- a name. After a failure it is only tried again at each refresh.
    if st.styleFailed and not refresh then
        return
    end
    if not st.styleSetter then
        log.first("style", "Switching the camera manager to the FirstPerson style with ClientSetCameraMode")
    end
    if setStyleWithFunction(pc, "FirstPerson") then
        st.styleRoute = "ClientSetCameraMode"
        if not st.styleSetter then
            st.styleSetter = { pc = pc, fullName = ue.fullName(pc) }
            journal.note("style", st.styleSetter.fullName, "", "Default")
        end
    end
end

local function putStyleBack()
    local setter = st.styleSetter
    st.styleSetter = nil
    if not setter then
        return
    end
    journal.forget("style", setter.fullName, "")
    if ue.valid(setter.pc) and ue.fullName(setter.pc) == setter.fullName then
        setStyleWithFunction(setter.pc, "Default")
    end
end

local function stopShakes(pcm)
    pcm:StopAllCameraShakes(true)
end

-- Game method ---------------------------------------------------------------

local function vectorOf(value)
    return { X = ue.number(value, "X") or 0, Y = ue.number(value, "Y") or 0, Z = ue.number(value, "Z") or 0 }
end

local function rotatorOf(value)
    return { Pitch = ue.number(value, "Pitch") or 0, Yaw = ue.number(value, "Yaw") or 0,
        Roll = ue.number(value, "Roll") or 0 }
end

-- A cine camera's focus method, or nil for a plain camera.
local function focusMethod(cam)
    local focus = ue.get(cam, "FocusSettings")
    if ue.typeOf(focus) ~= "UScriptStruct" then
        return nil
    end
    return ue.number(focus, "FocusMethod")
end

local function noteMove(m)
    journal.note("attach", m.fullName, "", journal.attachValue(m))
end

local function placeAtEyes(m, eye)
    m.cam:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = eye }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {},
        true)
    m.eye = eye
end

local function attachToEyes(m, eye, cfg)
    local cam = m.cam
    log.first("attach", "Attaching the game's camera %s to the character's capsule at the eyes", ue.describe(cam))
    -- Snapped to the capsule, keeping its own scale.
    cam:K2_AttachToComponent(m.capsule, fname("None"), SNAP_TO_TARGET, SNAP_TO_TARGET, KEEP_RELATIVE, false)
    placeAtEyes(m, eye)
    -- The camera then turns with the control rotation when the view is worked out.
    cam.bUsePawnControlRotation = true
    cam:SetFieldOfView(cfg.FieldOfView)
    m.fovPending = true
    if m.focus ~= nil then
        cam.FocusSettings = { FocusMethod = FOCUS_DISABLED }
    end
end

-- Takes the camera the game shows off its arm and puts it at the eyes. What it was
-- attached to and how is remembered, and noted in the journal.
local function moveCamera(pawn, pcm, cam, cfg, eye)
    local capsule = ue.object(pawn, "CapsuleComponent")
    if not capsule then
        error("the character has no capsule to attach the camera to")
    end
    local okParent, parent = ue.call(cam, "GetAttachParent")
    local okSocket, socket = ue.call(cam, "GetAttachSocketName")
    local m = {
        cam = cam,
        fullName = ue.fullName(cam),
        parent = okParent and ue.valid(parent) and parent or nil,
        socket = okSocket and ue.typeOf(socket) == "FName" and socket:ToString() or "None",
        location = vectorOf(ue.get(cam, "RelativeLocation")),
        rotation = rotatorOf(ue.get(cam, "RelativeRotation")),
        usePawn = ue.get(cam, "bUsePawnControlRotation") == true,
        fov = ue.number(cam, "FieldOfView"),
        focus = focusMethod(cam),
        capsule = capsule,
        capsuleAddr = ue.address(capsule),
        reattached = 0,
    }
    m.parentName = ue.fullName(m.parent)
    st.moved = m
    noteMove(m)
    attachToEyes(m, eye, cfg)
    local controller = ue.object(pawn, "BP_CameraControllerComponent")
    if controller then
        -- Its depth of field would focus on the hidden body, and its shake while
        -- running is in the way.
        overrides:set(controller, "EnableDynamicCameraFocus", false)
        overrides:set(controller, "EnableCameraShakeWhenMoving", false)
    end
    pcall(stopShakes, pcm)
end

-- Every frame: undoes what the game did to its camera meanwhile, and remembers
-- the game's values to put back.
local function keepAtEyes(m, eye, cfg, refresh)
    local cam = m.cam
    local ok, parent = ue.call(cam, "GetAttachParent")
    if not ok or ue.address(parent) ~= m.capsuleAddr then
        m.reattached = m.reattached + 1
        st.moveLines = st.moveLines + 1
        if st.moveLines <= MAX_MOVE_LINES then
            log.info("The game attached its camera to %s again; moving it back to the eyes", ue.describe(parent))
        end
        if ok and ue.valid(parent) then
            m.parent, m.parentName = parent, ue.fullName(parent)
            local okSocket, socket = ue.call(cam, "GetAttachSocketName")
            if okSocket and ue.typeOf(socket) == "FName" then
                m.socket = socket:ToString()
            end
        end
        m.location = vectorOf(ue.get(cam, "RelativeLocation"))
        noteMove(m)
        attachToEyes(m, eye, cfg)
        return
    end
    local at = ue.get(cam, "RelativeLocation")
    local x, y, z = ue.number(at, "X"), ue.number(at, "Y"), ue.number(at, "Z")
    if x and y and z then
        local moved = math.abs(x) > 1 or math.abs(y) > 1 or math.abs(z - m.eye) > 1
        if moved then
            -- A new camera setting from the game, meant for its arm: that is what to put back.
            m.location = { X = x, Y = y, Z = z }
            noteMove(m)
        end
        if moved or math.abs(eye - m.eye) > 0.5 then
            placeAtEyes(m, eye)
        end
    end
    local fov = ue.number(cam, "FieldOfView")
    if fov then
        if m.fovPending then
            -- A cine camera works its field of view out again from the focal length,
            -- so the first reading after setting it is what the mod's value became.
            m.fovSeen = fov
            m.fovPending = false
        elseif math.abs(fov - m.fovSeen) > 0.05 then
            m.fov = fov -- the game's own, to put back
            noteMove(m)
            cam:SetFieldOfView(cfg.FieldOfView)
            m.fovPending = true
        end
    end
    if refresh then
        if ue.get(cam, "bUsePawnControlRotation") ~= true then
            cam.bUsePawnControlRotation = true
        end
        if m.focus ~= nil then
            local focus = focusMethod(cam)
            if focus and focus ~= FOCUS_DISABLED then
                m.focus = focus
                noteMove(m)
                cam.FocusSettings = { FocusMethod = FOCUS_DISABLED }
            end
        end
    end
end

local function putCameraBack()
    local m = st.moved
    st.moved = nil
    if not m then
        return
    end
    journal.forget("attach", m.fullName, "")
    local cam = m.cam
    if not (ue.valid(cam) and ue.fullName(cam) == m.fullName) then
        return
    end
    if m.parent and ue.valid(m.parent) and ue.fullName(m.parent) == m.parentName then
        pcall(function()
            cam:K2_AttachToComponent(m.parent, fname(m.socket), KEEP_RELATIVE, KEEP_RELATIVE, KEEP_RELATIVE, false)
        end)
    end
    pcall(function()
        cam:K2_SetRelativeLocationAndRotation(m.location, m.rotation, false, {}, true)
    end)
    pcall(function()
        cam.bUsePawnControlRotation = m.usePawn
    end)
    if m.fov then
        pcall(function()
            cam:SetFieldOfView(m.fov)
        end)
    end
    if m.focus ~= nil then
        pcall(function()
            cam.FocusSettings = { FocusMethod = m.focus }
        end)
    end
end

-- The body ------------------------------------------------------------------

local function eyeHeight(pawn, cfg)
    if type(cfg.EyeHeight) == "number" then
        return cfg.EyeHeight
    end
    local capsule = ue.object(pawn, "CapsuleComponent")
    if capsule then
        local ok, half = ue.call(capsule, "GetScaledCapsuleHalfHeight")
        if ok and type(half) == "number" and half > 0 then
            return half * EYE_FACTOR
        end
    end
    return nil -- keep the game's eye height
end

-- Whether actor is the character, or is owned by it directly or through others.
local function ownedByPawn(actor, pawnAddr)
    for _ = 1, 8 do
        if not ue.valid(actor) then
            return false
        end
        if ue.address(actor) == pawnAddr then
            return true
        end
        local ok, owner = ue.call(actor, "GetOwner")
        if not ok then
            return false
        end
        actor = owner
    end
    return false
end

local function collect(component, out, depth)
    if depth > 24 or not ue.valid(component) then
        return
    end
    out[#out + 1] = component
    for _, child in ipairs(ue.list(ue.get(component, "AttachChildren"))) do
        collect(child, out, depth + 1)
    end
end

local function hidePart(entry)
    local part = entry.obj
    if entry.how == "owner" then
        if ue.get(part, "bOwnerNoSee") ~= true then
            part:SetOwnerNoSee(true)
        end
    elseif ue.get(part, "bHiddenInGame") ~= true then
        part:SetHiddenInGame(true, false)
    end
end

-- Shows a part the way it was before (if it is still the same part) and forgets it.
local function showPart(entry)
    journal.forget("hide", entry.fullName, entry.how)
    local part = entry.obj
    if ue.valid(part) and ue.fullName(part) == entry.fullName then
        pcall(function()
            if entry.how == "owner" then
                part:SetOwnerNoSee(entry.was)
            else
                part:SetHiddenInGame(entry.was, false)
            end
        end)
    end
end

local function hideOne(part, address, primitive, pawnAddr, checkNames, firstPass)
    local entry = hidden[address]
    if entry and (not ue.valid(entry.obj) or (checkNames and entry.fullName ~= ue.fullName(part))) then
        -- A new part where an old, now destroyed one used to be.
        journal.forget("hide", entry.fullName, entry.how)
        hidden[address] = nil
        entry = nil
    end
    if entry then
        hidePart(entry) -- hide it again if the game showed it
        return
    end
    if notPrimitive[address] then
        return
    end
    if not part:IsA(primitive) then
        notPrimitive[address] = true
        return
    end
    local fullName = ue.fullName(part)
    if not firstPass and waiting[address] ~= fullName then
        -- New since the last pass: the game may still be setting it up, so it is
        -- hidden on the next pass if it is still there.
        waiting[address] = fullName
        return
    end
    waiting[address] = nil
    local ok, owner = ue.call(part, "GetOwner")
    if ok and ue.valid(owner) then
        local okGone, gone = ue.call(owner, "IsActorBeingDestroyed")
        if okGone and gone == true then
            return
        end
    end
    local how = (ok and ownedByPawn(owner, pawnAddr)) and "owner" or "hidden"
    entry = { obj = part, fullName = fullName, how = how,
        was = ue.get(part, how == "owner" and "bOwnerNoSee" or "bHiddenInGame") == true }
    hidden[address] = entry
    journal.note("hide", entry.fullName, how, entry.was)
    hidePart(entry)
end

-- Hides everything visible that is attached to the character: its meshes and those
-- of attached actors, such as the swappable body, face, hair and gear. Parts the
-- character owns get "owner no see", which hides them only from the player's own
-- view; other parts are hidden in game. Lights are separate components and stay on.
-- Parts that are no longer attached (dropped, or detached by the game) are shown.
local function hideBody(pawn)
    local primitive = ue.find(PRIMITIVE)
    if not primitive then
        return
    end
    st.passes = st.passes + 1
    local firstPass = st.passes == 1
    local checkNames = st.passes % NAME_CHECK_EVERY == 0
    if checkNames then
        notPrimitive = {} -- addresses can be reused, so this is worked out again now and then
    end
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    if firstPass then
        log.first("hide", "Hiding the character's body (%d attached parts)", #parts)
    end
    local pawnAddr = ue.address(pawn)
    local seen = {}
    for _, part in ipairs(parts) do
        local address = ue.address(part)
        if address then
            seen[address] = true
            local ok, err = pcall(hideOne, part, address, primitive, pawnAddr, checkNames, firstPass)
            if not ok then
                guard.report("hiding " .. tostring(ue.className(part)), err)
            end
        end
    end
    for address, entry in pairs(hidden) do
        if not seen[address] then
            showPart(entry)
            hidden[address] = nil
        end
    end
    for address in pairs(waiting) do
        if not seen[address] then
            waiting[address] = nil
        end
    end
end

local function showBody()
    for _, entry in pairs(hidden) do
        showPart(entry)
    end
    hidden = {}
    waiting = {}
end

-- Widens the pitch limits: the camera manager's own, and those of camera modifiers
-- that limit the view (the game uses one for normal play and one for climbing).
local function widenPitch(pcm, limit)
    overrides:set(pcm, "ViewPitchMin", -limit, true)
    overrides:set(pcm, "ViewPitchMax", limit, true)
    for _, modifier in ipairs(ue.list(ue.get(pcm, "ModifierList"))) do
        if ue.valid(modifier) and ue.number(modifier, "PitchMin") and ue.number(modifier, "PitchMax") then
            overrides:set(modifier, "PitchMin", -limit, true)
            overrides:set(modifier, "PitchMax", limit, true)
        end
    end
end

-- Checking the view ------------------------------------------------------------

-- The distance in cm between the camera and the character's eyes, or nil if it
-- can't be told. The camera position is from the end of the last frame, and the
-- character hasn't moved since, so in first person the two should match.
local function eyeDistance(pcm, pawn)
    local okCamera, cameraAt = ue.call(pcm, "GetCameraLocation")
    local okPawn, pawnAt = ue.call(pawn, "K2_GetActorLocation")
    local eye = ue.number(pawn, "BaseEyeHeight")
    if not (okCamera and okPawn and eye and type(cameraAt) == "table" and type(pawnAt) == "table") then
        return nil
    end
    local dx = cameraAt.X - pawnAt.X
    local dy = cameraAt.Y - pawnAt.Y
    local dz = cameraAt.Z - (pawnAt.Z + eye)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local METHOD_NAMES = { engine = "the engine's first-person view", game = "the game's camera at the eyes" }

local function failureReason()
    if st.method == "engine" and st.styleFailed then
        return "the camera style could not be switched"
    end
    return string.format("the camera stayed %.0f cm away from the character's eyes", st.lastDistance or 0)
end

local function giveUp(pcm, cfg, reason)
    log.warn("First person doesn't work here: %s with %s (camera manager: %s). The game's camera and your "
        .. "character are back. %s, and please report UE4SS.log.", reason, METHOD_NAMES[st.method] or "?",
        tostring(ue.className(pcm)),
        cfg.CameraKey and ("Press " .. cfg.CameraKey .. " twice to try again") or "Reload the settings to try again")
    camera.release()
    st.unavailable = reason
    st.unavailablePcm = ue.address(pcm)
end

local function resetCheck()
    st.frames = 0
    st.confirmed = false
    st.failingSince = nil
    st.failingDistance = nil
    st.lastDistance = nil
end

local function startMethod(method, pawn, pcm, cam, cfg)
    st.method = method
    resetCheck()
    if method == "game" then
        local eye = eyeHeight(pawn, cfg) or ue.number(pawn, "BaseEyeHeight") or 0
        moveCamera(pawn, pcm, cam, cfg, eye)
    end
end

-- The view didn't reach the eyes: with "auto", the engine's view makes way for the
-- game's camera; otherwise first person is given up.
local function failed(pawn, pcm, cam, cfg)
    local reason = failureReason()
    if st.method == "engine" and cfg.CameraMethod == "auto" and cam then
        st.engineFailed[st.pcmClass or "?"] = reason
        log.info("First person: the engine's first-person view doesn't work here (%s). Moving the game's camera "
            .. "to the eyes instead.", reason)
        putStyleBack()
        local ok, err = pcall(startMethod, "game", pawn, pcm, cam, cfg)
        if ok then
            return
        end
        guard.report("moving the game's camera to the eyes", err)
        reason = reason .. "; the game's camera couldn't be moved: " .. tostring(err)
    end
    giveUp(pcm, cfg, reason)
end

-- Checks every frame until the camera is seen at the eyes, then at each refresh.
-- While the game is paused the camera isn't updated, so nothing is checked.
local function judgeView(pawn, pcm, cam, cfg, now, refresh, paused)
    if paused then
        st.failingSince = nil
        return
    end
    if st.frames < 2 or (st.confirmed and not st.failingSince and not refresh) then
        return
    end
    local ok, distance = guard.run("checking the view", eyeDistance, pcm, pawn)
    local styleFailed = st.method == "engine" and st.styleFailed
    if not ok or (distance == nil and not styleFailed) then
        return
    end
    st.lastDistance = distance
    if distance and distance <= MAX_EYE_DISTANCE and not styleFailed then
        st.confirmed = true
        st.failingSince = nil
        return
    end
    if not st.failingSince then
        st.failingSince, st.failingDistance = now, distance
    elseif now - st.failingSince >= GIVE_UP_TIME then
        if distance and st.failingDistance and distance < st.failingDistance * 0.75 then
            -- Still on its way to the eyes (a blend from another camera): wait longer.
            st.failingSince, st.failingDistance = now, distance
        else
            failed(pawn, pcm, cam, cfg)
        end
    end
end

-- Turning on and off ---------------------------------------------------------------

local function chooseMethod(cfg)
    if cfg.CameraMethod == "auto" then
        return st.engineFailed[st.pcmClass or "?"] and "game" or "engine"
    end
    return cfg.CameraMethod
end

--- Turns first person on, or keeps it on. Called every frame while it should be on.
--- cam is the camera component the engine shows (nil if none); paused: whether the
--- game is paused (the camera isn't updated then).
function camera.apply(pc, pawn, pcm, cam, cfg, now, paused)
    local pcmAddr = ue.address(pcm)
    if st.unavailable then
        if pcmAddr == st.unavailablePcm then
            return
        end
        st.unavailable = nil -- a new camera manager: try again
    end
    local pawnAddr = ue.address(pawn)
    if st.active and (st.pawnAddr ~= pawnAddr or st.pcmAddr ~= pcmAddr) then
        camera.release()
    end
    if not st.active then
        st.pcmClass = ue.className(pcm)
        local method = chooseMethod(cfg)
        if method == "game" and not cam then
            return -- nothing to move; waits for the game to show its camera
        end
        st.active = true
        st.pawnAddr = pawnAddr
        st.pcmAddr = pcmAddr
        st.passes = 0
        st.moveLines = 0
        st.nextRefresh = 0
        st.hasTargetRotation = ue.typeOf(ue.get(pawn, "TargetRotation")) == "UScriptStruct"
        local ok, err = pcall(startMethod, method, pawn, pcm, cam, cfg)
        if not ok then
            guard.report("moving the game's camera to the eyes", err)
            giveUp(pcm, cfg, "the game's camera couldn't be moved: " .. tostring(err))
            return
        end
    elseif st.method == "game" and cam and st.moved and not ue.same(cam, st.moved.cam) then
        -- The game shows another of its exploration cameras now: move that one.
        putCameraBack()
        local ok, err = pcall(startMethod, "game", pawn, pcm, cam, cfg)
        if not ok then
            guard.report("moving the game's camera to the eyes", err)
            giveUp(pcm, cfg, "the game's camera couldn't be moved: " .. tostring(err))
            return
        end
    end
    st.frames = st.frames + 1

    local refresh = now >= st.nextRefresh
    -- Set every frame, in case the game sets its own (Unreal resets the eye height).
    local eye = eyeHeight(pawn, cfg)
    if eye then
        overrides:set(pawn, "BaseEyeHeight", eye, refresh)
    end
    if st.method == "engine" then
        useFirstPersonStyle(pc, pcm, refresh)
        overrides:set(pcm, "DefaultFOV", cfg.FieldOfView, refresh)
    elseif st.moved then
        keepAtEyes(st.moved, eye or st.moved.eye, cfg, refresh)
    end
    if refresh then
        st.nextRefresh = now + REFRESH
        guard.run("widening the pitch limits", widenPitch, pcm, cfg.PitchLimit)
        if cfg.HideBody then
            guard.run("hiding the body", hideBody, pawn)
        end
        if st.method == "engine" then
            -- The FirstPerson style skips the camera modifiers, which play the
            -- shakes, so shakes the game starts would pile up until it ends.
            pcall(stopShakes, pcm)
        end
    end
    judgeView(pawn, pcm, cam, cfg, now, refresh, paused)
end

--- Lets first person start again after it was given up (a new character, the
--- camera key, a reload). With full (the keys), the engine's view is tried again
--- too, even where it didn't work before.
function camera.retry(full)
    st.unavailable = nil
    st.unavailablePcm = nil
    if full then
        st.engineFailed = {}
    end
end

--- Turns the character to face where the camera looks (yaw only), so that the
--- game's actions, such as hitting things, go where you look.
function camera.faceView(pawn, yaw)
    local rotation = { Pitch = 0, Yaw = yaw, Roll = 0 }
    pawn:K2_SetActorRotation(rotation, false)
    if st.hasTargetRotation then
        -- ALS, the game's locomotion system, turns the character towards this.
        pawn.TargetRotation = rotation
    end
end

--- What the camera side is doing, for the log and the diagnostics report.
function camera.status()
    local count = 0
    for _ in pairs(hidden) do
        count = count + 1
    end
    local state
    if st.unavailable then
        state = "given up: " .. st.unavailable
    elseif not st.active then
        state = "off"
    elseif st.confirmed then
        state = "working"
    else
        state = "checking"
    end
    local engineFailed = {}
    for class, reason in pairs(st.engineFailed) do
        engineFailed[#engineFailed + 1] = class .. ": " .. reason
    end
    return { active = st.active, state = state, method = st.method,
        methodName = st.method and METHOD_NAMES[st.method] or "none",
        styleRoute = st.styleRoute or "not set yet", hiddenParts = count, lastDistance = st.lastDistance,
        moved = st.moved and ue.describe(st.moved.cam) or nil, reattached = st.moved and st.moved.reattached or 0,
        engineFailed = table.concat(engineFailed, "; ") }
end

--- Turns first person off and puts back everything it changed.
function camera.release()
    if not st.active and overrides:isEmpty() and next(hidden) == nil and not st.styleSetter and not st.moved then
        return
    end
    overrides:restore()
    putStyleBack()
    putCameraBack()
    showBody()
    st.active = false
    st.method = nil
    st.pawnAddr = nil
    st.pcmAddr = nil
end

--- Forgets everything without touching the game: for a new level, whose loading
--- destroyed the objects the mod had changed.
function camera.forget()
    overrides:forget()
    for _, entry in pairs(hidden) do
        journal.forget("hide", entry.fullName, entry.how)
    end
    hidden = {}
    waiting = {}
    notPrimitive = {}
    if st.styleSetter then
        journal.forget("style", st.styleSetter.fullName, "")
        st.styleSetter = nil
    end
    if st.moved then
        journal.forget("attach", st.moved.fullName, "")
        st.moved = nil
    end
    st.active = false
    st.method = nil
    st.pawnAddr = nil
    st.pcmAddr = nil
    st.styleFieldPcm = nil
end

return camera
