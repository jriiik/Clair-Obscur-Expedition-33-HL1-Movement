-- Which camera the game is showing, and whether first person may be on.
--
-- Unreal takes the picture from the view target. For a character that is its
-- first active camera component (AActor::CalcCamera), or its eyes if none is
-- active. The game shows exploration through the character's main camera; dialogue,
-- cutscenes, sneaking and aiming use other cameras, or other view targets. So first
-- person is on only while the view target is the character, the camera the engine
-- picks is an exploration camera (the one the game's GetMainCamera names, or a
-- component named in CameraComponents), and the game isn't in a dialogue or a
-- cinematic.
--
-- 0.1 waited for the component called MainCamera to be active, which it may never
-- be in this game; first person then never started, without a word in the log.

local ue = require("hl1movement.ue")

local view = {}

local RESCAN = 0.5 -- seconds between full checks of the character's cameras
local ASK_EVERY = 0.25 -- seconds between questions to the game's dialogue and cinematic systems

local st = {
    pawnAddr = nil,
    cameras = {}, -- the character's camera components, in the engine's order
    index = nil, -- the one the engine shows: the first active one (nil: none is active)
    mainCamera = nil, -- what the game's GetMainCamera returns
    mainCameraError = nil,
    exploration = {}, -- address -> true for the cameras that show exploration
    findCamera = true, -- the character's bFindCameraComponentWhenViewTarget
    nextScan = 0,
    nextAsk = 0,
    dialogue = false,
    cinematic = false,
    missing = {}, -- "object address/function" -> true for functions the game doesn't have
}

--- Forgets everything about the last character, for example after a level change.
function view.reset()
    st.pawnAddr = nil
    st.cameras = {}
    st.index = nil
    st.mainCamera = nil
    st.mainCameraError = nil
    st.exploration = {}
    st.findCamera = true
    st.nextScan = 0
    st.nextAsk = 0
    st.dialogue = false
    st.cinematic = false
    st.missing = {}
end

-- Whether a component is active. The bIsActive property is read directly, which
-- is cheaper than calling IsActive, if UE4SS can read it.
local function isActive(component)
    local active = ue.bool(component, "bIsActive")
    if active ~= nil then
        return active
    end
    local ok, result = ue.call(component, "IsActive")
    return ok and result == true
end
view.isActive = isActive

-- Calls a function that answers true or false; nil if the object doesn't have it
-- (and then it isn't asked again).
local function ask(obj, name, ...)
    local key = tostring(ue.address(obj)) .. "/" .. name
    if st.missing[key] then
        return nil
    end
    local ok, result = ue.call(obj, name, ...)
    if not ok then
        st.missing[key] = true
        return nil
    end
    return result == true
end

local function scan(pawn, cfg)
    local class = ue.find("/Script/Engine.CameraComponent")
    local cameras = {}
    if class then
        local ok, list = ue.call(pawn, "K2_GetComponentsByClass", class)
        if ok then
            for _, component in ipairs(ue.list(list)) do
                if ue.valid(component) then
                    cameras[#cameras + 1] = component
                end
            end
        end
    end
    st.cameras = cameras

    -- The game's own answer to "which is the main camera", through an out parameter.
    -- UE4SS fills the table under the parameter's name, MainCamera. (SDK dumps call
    -- it MainCamera_0: the dumper renames parameters named like a member.) Any
    -- other object in the table is taken too, in case a game update renames it.
    local out = {}
    local ok, err = ue.call(pawn, "GetMainCamera", out)
    local main = out.MainCamera
    if not ue.valid(main) then
        main = nil
        for _, value in pairs(out) do
            if ue.valid(value) then
                main = value
                break
            end
        end
    end
    st.mainCamera = ok and main or nil
    st.mainCameraError = not ok and tostring(err) or nil

    local exploration = {}
    if st.mainCamera then
        exploration[ue.address(st.mainCamera)] = true
    end
    local wanted = {}
    for _, name in ipairs(cfg.CameraComponents) do
        wanted[name] = true
    end
    st.index = nil
    for i, component in ipairs(cameras) do
        if wanted[ue.name(component) or ""] then
            exploration[ue.address(component)] = true
        end
        if not st.index and isActive(component) then
            st.index = i
        end
    end
    st.exploration = exploration
    st.findCamera = ue.bool(pawn, "bFindCameraComponentWhenViewTarget") ~= false
end

-- Between full checks: the engine's pick changes when the camera it shows stops
-- being active, or one before it in the list starts.
local function pickChanged()
    local index = st.index or (#st.cameras + 1)
    for i = 1, index - 1 do
        local component = st.cameras[i]
        if not ue.valid(component) or isActive(component) then
            return true
        end
    end
    local shown = st.cameras[index]
    return shown ~= nil and (not ue.valid(shown) or not isActive(shown))
end

--- Keeps track of the character's cameras and the game's state. Called every frame.
function view.update(pc, pawn, cfg, now)
    local pawnAddr = ue.address(pawn)
    if pawnAddr ~= st.pawnAddr then
        view.reset()
        st.pawnAddr = pawnAddr
    end
    if now >= st.nextScan or pickChanged() then
        -- The second scan comes half a period after the first instead of a whole
        -- one, so that scans fall between the camera's refreshes (see view.stagger).
        st.nextScan = now + (st.nextScan == 0 and RESCAN / 2 or RESCAN)
        scan(pawn, cfg)
    end
    if now >= st.nextAsk then
        st.nextAsk = now + ASK_EVERY
        local dialogue = ue.object(pc, "BP_DialogueSystemComponent")
        st.dialogue = dialogue ~= nil and ask(dialogue, "IsInDialogue") == true
        local cinematic = ue.object(pc, "BP_CinematicSystem")
        st.cinematic = cinematic ~= nil and (ue.bool(cinematic, "IsPlayingCinematic") == true
            or ask(cinematic, "IsInCinematicTransition") == true)
    end
end

--- Called when first person starts, whose refreshes start then: the next scan
--- comes half a period later, between them.
function view.stagger(now)
    if st.nextScan ~= 0 then
        st.nextScan = now + RESCAN / 2
    end
end

--- The camera component the engine shows (nil if none is active).
function view.camera()
    local component = st.index and st.cameras[st.index]
    if component and ue.valid(component) then
        return component
    end
    return nil
end

--- Why first person has to wait: a short key and the text for the log, or nil if it
--- may be on. viewTarget is what the camera manager shows.
function view.blocker(pawn, viewTarget)
    if ue.address(viewTarget) ~= ue.address(pawn) then
        return "view-target", function()
            return "waiting (the game shows the view of " .. ue.describe(viewTarget) .. ", not your character)"
        end
    elseif st.cinematic then
        return "cinematic", "waiting (a cinematic is playing)"
    elseif st.dialogue then
        return "dialogue", "waiting (dialogue)"
    elseif not st.findCamera then
        return nil -- the engine shows the character's eyes, whatever its cameras do
    end
    local shown = view.camera()
    if shown and not st.exploration[ue.address(shown)] then
        return "camera-" .. tostring(ue.name(shown)), function()
            local main = st.mainCamera and ue.describe(st.mainCamera) or "unknown"
            return string.format("waiting (the game shows its camera %s, not the main camera %s)",
                ue.describe(shown), main)
        end
    end
    return nil
end

--- What view knows, for the diagnostics report.
function view.status()
    return {
        cameras = st.cameras,
        index = st.index,
        mainCamera = st.mainCamera,
        mainCameraError = st.mainCameraError,
        exploration = st.exploration,
        findCamera = st.findCamera,
        dialogue = st.dialogue,
        cinematic = st.cinematic,
    }
end

return view
