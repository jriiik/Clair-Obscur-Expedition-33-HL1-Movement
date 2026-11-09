-- First-person camera.
--
-- Unreal's player camera manager has a built-in "FirstPerson" camera style that
-- looks out of the character's eyes (its position plus BaseEyeHeight, turned with
-- the mouse). The mod switches to that style, sets the field of view and the
-- pitch limits, and hides the character's own body from the player's view.
-- Everything it changes is put back when first person switches off.
--
-- The camera manager's CameraStyle field may not be visible to UE4SS (in older
-- engine versions it isn't). Then the style is set through the player
-- controller's ClientSetCameraMode function instead, and put back to "Default".

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local Overrides = require("hl1movement.overrides")

local camera = {}

local EYE_FACTOR = 0.78 -- "auto" eye height, as a share of the capsule's half height
local REFRESH = 0.5 -- seconds between re-checks of the FOV, pitch limits and body
local PRIMITIVE = "/Script/Engine.PrimitiveComponent"

local overrides = Overrides.new()
local hidden = {} -- address -> { obj, fullName, how, was }
local st = {
    active = false,
    pawnAddr = nil,
    nextRefresh = 0,
    frames = 0,
    checked = false,
    hasTargetRotation = false,
    styleSetter = nil, -- { pc, fullName } when the style was set with ClientSetCameraMode
    styleFailed = false,
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
        end
    end
end

local function putStyleBack()
    local setter = st.styleSetter
    st.styleSetter = nil
    if setter and ue.valid(setter.pc) and ue.fullName(setter.pc) == setter.fullName then
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

-- Hides everything visible that is attached to the character: its meshes and those
-- of attached actors, such as the swappable body, face, hair and gear. Parts the
-- character owns get "owner no see", which hides them only from the player's own
-- view; other parts are hidden in game. Lights are separate components and stay on.
local function hideBody(pawn)
    local primitive = ue.find(PRIMITIVE)
    if not primitive then
        return
    end
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    local pawnAddr = ue.address(pawn)
    for _, part in ipairs(parts) do
        local address = ue.address(part)
        local entry = address and hidden[address]
        if entry and entry.fullName ~= ue.fullName(part) then
            entry = nil -- a new part where an old, now destroyed one used to be
        end
        if entry then
            -- already hidden: hide it again if the game showed it
            if entry.how == "owner" then
                if ue.get(part, "bOwnerNoSee") ~= true then
                    part:SetOwnerNoSee(true)
                end
            elseif ue.get(part, "bHiddenInGame") ~= true then
                part:SetHiddenInGame(true, false)
            end
        elseif address and part:IsA(primitive) then
            local ok, owner = ue.call(part, "GetOwner")
            if ok and ownedByPawn(owner, pawnAddr) then
                hidden[address] = { obj = part, fullName = ue.fullName(part), how = "owner",
                    was = ue.get(part, "bOwnerNoSee") == true }
                part:SetOwnerNoSee(true)
            else
                hidden[address] = { obj = part, fullName = ue.fullName(part), how = "hidden",
                    was = ue.get(part, "bHiddenInGame") == true }
                part:SetHiddenInGame(true, false)
            end
        end
    end
end

local function showBody()
    for _, entry in pairs(hidden) do
        local part = entry.obj
        if ue.valid(part) and ue.fullName(part) == entry.fullName then
            if entry.how == "owner" then
                pcall(function()
                    part:SetOwnerNoSee(entry.was)
                end)
            else
                pcall(function()
                    part:SetHiddenInGame(entry.was, false)
                end)
            end
        end
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

-- The camera position is from the end of the last frame, and the character hasn't
-- moved since, so in first person the camera should sit at the character's eyes.
local function checkView(pcm, pawn)
    local okCamera, cameraAt = ue.call(pcm, "GetCameraLocation")
    local okPawn, pawnAt = ue.call(pawn, "K2_GetActorLocation")
    local eye = ue.number(pawn, "BaseEyeHeight")
    if not (okCamera and okPawn and eye and type(cameraAt) == "table" and type(pawnAt) == "table") then
        return
    end
    local dx = cameraAt.X - pawnAt.X
    local dy = cameraAt.Y - pawnAt.Y
    local dz = cameraAt.Z - (pawnAt.Z + eye)
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    if distance > 50 then
        log.once("camera-style", "The first-person camera doesn't seem to work: the camera is %.0f cm "
            .. "from the character's eyes. Camera manager class: %s. Please report this with UE4SS.log.",
            distance, tostring(ue.className(pcm)))
    else
        log.debug("First-person camera check passed (camera %.1f cm from the eyes)", distance)
    end
end

--- Turns first person on, or keeps it on. Called every frame while it should be on.
function camera.apply(pc, pawn, pcm, cfg, now)
    local pawnAddr = ue.address(pawn)
    if st.active and st.pawnAddr ~= pawnAddr then
        camera.release()
    end
    if not st.active then
        st.active = true
        st.pawnAddr = pawnAddr
        st.frames = 0
        st.checked = false
        st.nextRefresh = 0
        st.hasTargetRotation = ue.typeOf(ue.get(pawn, "TargetRotation")) == "UScriptStruct"
        log.debug("First-person camera applied")
    end
    st.frames = st.frames + 1

    local refresh = now >= st.nextRefresh
    useFirstPersonStyle(pc, pcm, refresh)
    local eye = eyeHeight(pawn, cfg)
    if eye then
        local current = ue.number(pawn, "BaseEyeHeight")
        if current == nil or math.abs(current - eye) > 0.01 then
            overrides:set(pawn, "BaseEyeHeight", eye)
        end
    end
    if refresh then
        st.nextRefresh = now + REFRESH
        overrides:set(pcm, "DefaultFOV", cfg.FieldOfView)
        widenPitch(pcm, cfg.PitchLimit)
        if cfg.HideBody then
            hideBody(pawn)
        end
    end
    if not st.checked and st.frames >= 10 then
        st.checked = true
        checkView(pcm, pawn)
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

--- What the camera side is doing, for the diagnostics report.
function camera.status()
    local count = 0
    for _ in pairs(hidden) do
        count = count + 1
    end
    return { active = st.active, styleRoute = st.styleRoute or "not set yet", hiddenParts = count }
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
end

return camera
