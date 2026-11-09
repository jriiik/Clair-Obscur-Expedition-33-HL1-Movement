-- First-person camera.
--
-- Unreal's player camera manager has a built-in "FirstPerson" camera style that
-- looks out of the character's eyes (its position plus BaseEyeHeight, turned with
-- the mouse). The mod switches to that style, sets the field of view and the
-- pitch limits, and hides the character's own body from the player's view.
-- Everything it changes is put back when first person switches off.
--
-- The camera manager's CameraStyle field isn't visible to UE4SS in Unreal 5.4 (it
-- isn't a reflected property). Then the style is set through the player
-- controller's ClientSetCameraMode function instead, and put back to "Default".
--
-- Whether first person really took effect is checked every frame until the
-- camera is seen at the character's eyes. If it stays away for GIVE_UP_TIME, the
-- mod gives up and shows the game's camera and the character again, instead of
-- leaving an invisible character in third person. Time paused doesn't count, and
-- a camera that is clearly getting closer (a blend from another camera) gets more.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local guard = require("hl1movement.guard")
local journal = require("hl1movement.journal")
local Overrides = require("hl1movement.overrides")

local camera = {}

local EYE_FACTOR = 0.78 -- "auto" eye height, as a share of the capsule's half height
local REFRESH = 0.5 -- seconds between re-checks of the FOV, pitch limits and body
local MAX_EYE_DISTANCE = 50 -- cm between the camera and the eyes that still counts as first person
local GIVE_UP_TIME = 2 -- seconds of the camera not being at the eyes before giving up
local PRIMITIVE = "/Script/Engine.PrimitiveComponent"

local overrides = Overrides.new()
local hidden = {} -- address -> { obj, fullName, how, was }
local st = {
    active = false,
    pawnAddr = nil,
    pcmAddr = nil,
    nextRefresh = 0,
    frames = 0,
    confirmed = false, -- the camera has been seen at the eyes since first person started
    failingSince = nil, -- when the checks started failing
    failingDistance = nil, -- the distance then
    lastDistance = nil, -- cm between the camera and the eyes at the last check
    unavailable = nil, -- why first person was given up, until camera.retry()
    unavailablePcm = nil,
    hasTargetRotation = false,
    styleSetter = nil, -- { pc, fullName } when the style was set with ClientSetCameraMode
    styleFailed = false,
    styleRoute = nil,
}

function camera.isActive()
    return st.active
end

-- The camera manager's CameraStyle, or nil if UE4SS can't see that field.
local function styleField(pcm)
    local value = ue.get(pcm, "CameraStyle")
    if ue.typeOf(value) == "FName" then
        return value
    end
    return nil
end

local names = {}

local function styleName(name)
    names[name] = names[name] or FName(name)
    return names[name]
end

local function setStyleWithFunction(pc, name)
    local ok, err = ue.call(pc, "ClientSetCameraMode", styleName(name))
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
            overrides:set(pcm, "CameraStyle", styleName("FirstPerson"))
        end
        return
    end
    -- The field isn't visible to UE4SS (as in Expedition 33), so the controller
    -- sets it. That can't be read back, so it is set every frame: it only stores
    -- a name. After a failure it is only tried again at each refresh.
    if st.styleFailed and not refresh then
        return
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

local function hideOne(part, address, primitive, pawnAddr)
    local entry = hidden[address]
    if entry and entry.fullName ~= ue.fullName(part) then
        -- A new part where an old, now destroyed one used to be.
        journal.forget("hide", entry.fullName, entry.how)
        hidden[address] = nil
        entry = nil
    end
    if entry then
        hidePart(entry) -- hide it again if the game showed it
        return
    end
    if not part:IsA(primitive) then
        return
    end
    local ok, owner = ue.call(part, "GetOwner")
    local how = (ok and ownedByPawn(owner, pawnAddr)) and "owner" or "hidden"
    entry = { obj = part, fullName = ue.fullName(part), how = how,
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
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    local pawnAddr = ue.address(pawn)
    local seen = {}
    for _, part in ipairs(parts) do
        local address = ue.address(part)
        if address then
            seen[address] = true
            local ok, err = pcall(hideOne, part, address, primitive, pawnAddr)
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
end

local function showBody()
    for _, entry in pairs(hidden) do
        showPart(entry)
    end
    hidden = {}
end

-- Widens the pitch limits: the camera manager's own, and those of camera modifiers
-- that limit the view (the game uses one for normal play and one for climbing).
local function widenPitch(pcm, limit)
    overrides:set(pcm, "ViewPitchMin", -limit)
    overrides:set(pcm, "ViewPitchMax", limit)
    for _, modifier in ipairs(ue.list(ue.get(pcm, "ModifierList"))) do
        if ue.valid(modifier) and ue.number(modifier, "PitchMin") and ue.number(modifier, "PitchMax") then
            overrides:set(modifier, "PitchMin", -limit)
            overrides:set(modifier, "PitchMax", limit)
        end
    end
end

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

local function giveUp(pcm, cfg)
    local reason
    if st.styleFailed then
        reason = "the camera style could not be switched"
    else
        reason = string.format("the camera stayed %.0f cm away from the character's eyes", st.lastDistance or 0)
    end
    log.warn("First person doesn't work here: %s (camera manager: %s). The game's camera and your character "
        .. "are back. %s, and please report UE4SS.log.", reason, tostring(ue.className(pcm)),
        cfg.CameraKey and ("Press " .. cfg.CameraKey .. " twice to try again") or "Reload the settings to try again")
    camera.release()
    st.unavailable = reason
    st.unavailablePcm = ue.address(pcm)
end

-- Checks every frame until the camera is seen at the eyes, then at each refresh.
-- While the game is paused the camera isn't updated, so nothing is checked.
local function judgeView(pcm, pawn, cfg, now, refresh, paused)
    if paused then
        st.failingSince = nil
        return
    end
    if st.frames < 2 or (st.confirmed and not st.failingSince and not refresh) then
        return
    end
    local ok, distance = guard.run("checking the view", eyeDistance, pcm, pawn)
    if not ok or (distance == nil and not st.styleFailed) then
        return
    end
    st.lastDistance = distance
    if distance and distance <= MAX_EYE_DISTANCE and not st.styleFailed then
        if not st.confirmed then
            log.debug("First person is working (camera %.1f cm from the eyes)", distance)
        end
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
            giveUp(pcm, cfg)
        end
    end
end

--- Turns first person on, or keeps it on. Called every frame while it should be on.
--- paused: whether the game is paused (the camera isn't updated then).
function camera.apply(pc, pawn, pcm, cfg, now, paused)
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
        st.active = true
        st.pawnAddr = pawnAddr
        st.pcmAddr = pcmAddr
        st.frames = 0
        st.confirmed = false
        st.failingSince = nil
        st.lastDistance = nil
        st.nextRefresh = 0
        st.hasTargetRotation = ue.typeOf(ue.get(pawn, "TargetRotation")) == "UScriptStruct"
        log.debug("First-person camera applied")
    end
    st.frames = st.frames + 1

    local refresh = now >= st.nextRefresh
    useFirstPersonStyle(pc, pcm, refresh)
    -- Set every frame, in case the game sets its own (Unreal resets the eye height).
    local eye = eyeHeight(pawn, cfg)
    if eye then
        local current = ue.number(pawn, "BaseEyeHeight")
        if current == nil or math.abs(current - eye) > 0.01 then
            overrides:set(pawn, "BaseEyeHeight", eye)
        end
    end
    local fov = ue.number(pcm, "DefaultFOV")
    if fov == nil or math.abs(fov - cfg.FieldOfView) > 0.01 then
        overrides:set(pcm, "DefaultFOV", cfg.FieldOfView)
    end
    if refresh then
        st.nextRefresh = now + REFRESH
        guard.run("widening the pitch limits", widenPitch, pcm, cfg.PitchLimit)
        if cfg.HideBody then
            guard.run("hiding the body", hideBody, pawn)
        end
    end
    judgeView(pcm, pawn, cfg, now, refresh, paused)
end

--- Lets first person start again after it was given up (camera key, reload).
function camera.retry()
    st.unavailable = nil
    st.unavailablePcm = nil
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

--- What the camera side is doing, for the diagnostics report.
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
    return { active = st.active, state = state, styleRoute = st.styleRoute or "not set yet", hiddenParts = count,
        lastDistance = st.lastDistance }
end

--- Turns first person off and puts back everything it changed.
function camera.release()
    if not st.active and overrides:isEmpty() and next(hidden) == nil and not st.styleSetter then
        return
    end
    overrides:restore()
    putStyleBack()
    showBody()
    if st.active then
        log.debug("First-person camera released")
    end
    st.active = false
    st.pawnAddr = nil
    st.pcmAddr = nil
end

return camera
