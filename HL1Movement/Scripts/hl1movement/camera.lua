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
-- controller's ClientSetCameraMode, every frame, and put back to "Default". It
-- starts once the camera manager has finished blending to the character.
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
local SKINNED = "/Script/Engine.SkinnedMeshComponent"
-- A skinned mesh's VisibilityBasedAnimTickOption (EVisibilityBasedAnimTickOption, in
-- Unreal 5.4's order, which E33's reflection data has too): 0 AlwaysTickPoseAndRefreshBones,
-- 1 AlwaysTickPose, 2 OnlyTickMontagesAndRefreshBonesWhenPlayingMontages,
-- 3 OnlyTickMontagesWhenNotRendered, 4 OnlyTickPoseWhenRendered. From 2 on, a mesh that
-- hasn't been drawn for a second stops running its animation graph (2 and 3 still play
-- montages, and 4 runs it only during a root-motion montage), and with the graph the
-- anim notifies of its animations, which play the footsteps, the clothes' rustle, the
-- breathing and the grunts. (What plays the game's jump sound isn't known: the mod's
-- hops aren't the game's own jump, so they skip what is tied to it in any view.) A part
-- hidden with "owner no see" isn't drawn in the player's view and casts no shadow
-- there, and one hidden in game isn't drawn at all.
local TICK_OPTION = "VisibilityBasedAnimTickOption"
local TICK_AS_IF_SEEN = 0 -- AlwaysTickPoseAndRefreshBones: what Unreal does while the part is on screen
local TICK_STOPS_UNSEEN = 2 -- this option and the ones after it stop the graph while the part isn't drawn
local TICK_NAMES = { [0] = "AlwaysTickPoseAndRefreshBones", "AlwaysTickPose",
    "OnlyTickMontagesAndRefreshBonesWhenPlayingMontages", "OnlyTickMontagesWhenNotRendered",
    "OnlyTickPoseWhenRendered" }
local KEEP_RELATIVE, SNAP_TO_TARGET = 0, 2 -- EAttachmentRule
local FOCUS_DISABLED = 3 -- ECameraFocusMethod::Disable
local NAME_CHECK_EVERY = 4 -- hiding passes between checks of the hidden parts' full names
local MAX_MOVE_LINES = 3
local MAX_MOVED_PART_LINES = 3 -- log lines for hidden parts the game moved to another actor, per session
local FOV_TOLERANCE = 0.05 -- degrees: a field of view that differs by more was changed
-- Seconds the engine's view waits for the camera manager to finish blending to
-- the character, before it starts anyway.
local BLEND_WAIT = 3
-- Frames a character's first start waits for a mesh the game has never drawn to be
-- drawn (see bodyUndrawn), before it starts anyway.
local DRAW_WAIT = 5

local overrides = Overrides.new()
local hidden = {} -- address -> { obj, fullName, how, was, skinned, tick, refused }
local waiting = {} -- address -> full name of parts seen once, hidden if still there next pass
local notPrimitive = {} -- address -> true for attached components that can't be seen
-- address -> full name of the skinned parts the game had drawn by the time the mod hid
-- them, for the character's life (drawnPawn): see keepAnimating.
local drawnBefore = {}
local drawnPawn = nil
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
    partsMoved = 0, -- hidden parts the game moved to another actor, put back by the mod (see movedByGame)
    updates = 0, -- views the camera manager has worked out: one at the end of each frame Unreal didn't pause
    lastUnpaused = false, -- the last frame wasn't paused
    waiting = nil, -- why first person isn't on yet although it may be: "camera", "blend" or "body"
    bodyWaited = 0, -- frames this start has waited for the body to be drawn (see bodyUndrawn)
    blendWaited = nil, -- seconds (not paused) the camera manager has been seen blending to the character
    blendLast = nil, -- when that was last checked
    blendStuck = false, -- a blend didn't end in BLEND_WAIT seconds: not waited for again until it ends
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
    st.styleRoute = nil
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

-- The field of view --------------------------------------------------------------
--
-- A plain camera shows the field of view it is given. A cine camera works its
-- field of view out again from a focal length that its lens limits, when the view
-- is worked out at the end of a frame (not while the game is paused). So for a
-- cine camera, what the mod's FieldOfView becomes (m.fovSeen) is learnt from
-- readings taken after that: FieldOfView itself, or exactly the same other reading
-- twice with the mod's set again in between (its lens can't go further: the lens
-- gives the same value each time, while the steps of a game blend that eases in or
-- out can be tiny). A reading that changed in between was the game's own, to put
-- back. A limit learnt that way is checked again at each refresh, in case it was
-- the game holding its own value, which readings can't tell from a lens limit.
-- Until the next reading judges it, the newest isn't what release puts back: while
-- the value is learnt (after a move or a recheck), a release within two frames of
-- the game's last change, or in the pause it was read in, puts back an earlier one
-- (with a lens limit, it can be the lens's own).

local function nearFov(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) <= FOV_TOLERANCE
end

-- The same value: a lens limit is worked out the same way each time.
local function sameFov(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) <= 1e-6
end

local function setFov(m, fov)
    m.cam:SetFieldOfView(fov)
    m.fovSetAt = st.updates -- read again once the camera manager has worked the view out
end

-- Takes in a reading of the camera's field of view, from after the view was
-- worked out. Returns true if the mod's has to be set again.
local function judgeFov(m, cfg, fov)
    local want = cfg.FieldOfView
    if m.fovSeen ~= nil then
        if nearFov(fov, m.fovSeen) then
            return false
        elseif nearFov(fov, want) then
            m.fovSeen = want -- the lens lets it through now
            return false
        end
        m.fov = fov -- the game's own, to put back
        noteMove(m)
        return true
    end
    local try = m.fovTry
    if nearFov(fov, want) then
        if try then
            m.fov = try -- the game's, from before the mod's came through
            noteMove(m)
        end
        m.fovSeen, m.fovTry, m.fovRecheck = want, nil, nil
        return false
    elseif sameFov(fov, try) then
        if m.fovRecheck then
            log.once("fov-limit", "The game's camera %s shows a field of view of %.1f although the mod sets "
                .. "FieldOfView %s: its lens can't go wider (or narrower), or the game keeps setting its own.",
                ue.describe(m.cam), fov, tostring(want))
        end
        m.fovSeen, m.fovTry, m.fovRecheck = fov, nil, nil
        return false
    end
    if try and not m.fovRecheck then
        m.fov = try -- it changed since, so it was the game's
        noteMove(m)
    end
    m.fovTry, m.fovRecheck = fov, nil
    return true
end

-- The camera's field of view, every frame the game isn't paused: what the game
-- set meanwhile is remembered to put back, and the mod's is set again.
local function keepFov(m, cfg, paused, refresh)
    if paused or m.fovSetAt == st.updates then
        return -- the view hasn't been worked out since the mod last set it
    end
    local fov = ue.number(m.cam, "FieldOfView")
    if not fov then
        return
    end
    if judgeFov(m, cfg, fov) then
        setFov(m, cfg.FieldOfView)
    elseif refresh and m.cine and m.fovSeen ~= nil and not nearFov(m.fovSeen, cfg.FieldOfView) then
        m.fovTry, m.fovRecheck, m.fovSeen = m.fovSeen, true, nil
        setFov(m, cfg.FieldOfView)
    end
end

-- Attaches the camera to the capsule at the eyes. Returns false if Unreal refused
-- the attachment.
local function attachToEyes(m, eye, cfg)
    local cam = m.cam
    log.first("attach", "Attaching the game's camera %s to the character's capsule at the eyes", ue.describe(cam))
    -- Snapped to the capsule, keeping its own scale.
    local attached = cam:K2_AttachToComponent(m.capsule, fname("None"), SNAP_TO_TARGET, SNAP_TO_TARGET,
        KEEP_RELATIVE, false)
    if attached == false then
        return false
    end
    placeAtEyes(m, eye)
    -- The camera then turns with the control rotation when the view is worked out.
    cam.bUsePawnControlRotation = true
    setFov(m, cfg.FieldOfView)
    if m.focus ~= nil then
        cam.FocusSettings = { FocusMethod = FOCUS_DISABLED }
    end
    return true
end

-- The camera controller's depth of field would focus on the hidden body, and its
-- shake while running is in the way. Set again at each refresh, so a value the
-- game sets meanwhile is the one put back.
local function quietController(m)
    local controller = m.controller
    if controller and ue.valid(controller) then
        overrides:set(controller, "EnableDynamicCameraFocus", false)
        overrides:set(controller, "EnableCameraShakeWhenMoving", false)
    end
end

-- Takes the camera the game shows off its arm and puts it at the eyes. What it was
-- attached to and how is remembered, and noted in the journal.
local function moveCamera(pawn, pcm, cam, cfg, eye)
    local capsule = ue.object(pawn, "CapsuleComponent")
    if not capsule then
        error("the character has no capsule to attach the camera to", 0)
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
        cine = ue.number(cam, "CurrentFocalLength") ~= nil,
        capsule = capsule,
        capsuleAddr = ue.address(capsule),
        reattached = 0,
        controller = ue.object(pawn, "BP_CameraControllerComponent"),
    }
    m.parentName = ue.fullName(m.parent)
    -- A plain camera shows the mod's field of view as set; a cine camera's is learnt
    -- (see judgeFov).
    m.fovSeen = not m.cine and cfg.FieldOfView or nil
    st.moved = m
    noteMove(m)
    if not attachToEyes(m, eye, cfg) then
        error("Unreal refused to attach the camera to the character's capsule", 0)
    end
    quietController(m)
    pcall(stopShakes, pcm)
end

-- Whether a relative location is something other than the mod's own place at the
-- eyes, (0, 0, eye).
local function awayFromEyes(m, x, y, z)
    return math.abs(x) > 1 or math.abs(y) > 1 or math.abs(z - m.eye) > 1
end

-- Every frame: undoes what the game did to its camera meanwhile, and remembers
-- the game's values to put back. Returns false if the camera can't be put back
-- at the eyes.
local function keepAtEyes(m, eye, cfg, refresh, paused)
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
            -- Where the game put it on its arm, unless an attachment that kept the
            -- relative location left it at the mod's place.
            local at = vectorOf(ue.get(cam, "RelativeLocation"))
            if awayFromEyes(m, at.X, at.Y, at.Z) then
                m.location = at
            end
        end
        -- The game's field of view, if it set one (attachToEyes sets the mod's again).
        -- Read after the view was worked out, paused or not, it is judged as usual;
        -- before that, the camera has the mod's own value unless the game set one.
        local fov = ue.number(cam, "FieldOfView")
        if fov and m.fovSetAt ~= st.updates then
            judgeFov(m, cfg, fov)
        elseif fov and not nearFov(fov, cfg.FieldOfView) and not nearFov(fov, m.fovSeen) then
            m.fov = fov
        end
        noteMove(m)
        return attachToEyes(m, eye, cfg)
    end
    local at = ue.get(cam, "RelativeLocation")
    local x, y, z = ue.number(at, "X"), ue.number(at, "Y"), ue.number(at, "Z")
    if x and y and z then
        local moved = awayFromEyes(m, x, y, z)
        if moved then
            -- A new camera setting from the game, meant for its arm: that is what to put back.
            m.location = { X = x, Y = y, Z = z }
            noteMove(m)
        end
        if moved or math.abs(eye - m.eye) > 0.5 then
            placeAtEyes(m, eye)
        end
    end
    keepFov(m, cfg, paused, refresh)
    if refresh then
        quietController(m)
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
    return true
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

local function hiddenFlag(entry)
    return entry.how == "owner" and "bOwnerNoSee" or "bHiddenInGame"
end

local function tickName(option)
    return string.format("%s (%s)", tostring(option), TICK_NAMES[option] or "unknown")
end

-- Whether Unreal has drawn a part at any time since its world began. The engine keeps
-- each part's last render time (WasRecentlyRendered compares it with the world's
-- clock), also while the game or the mod hides the part, and a part never drawn has a
-- time from before the world began (-1000 s in Unreal 5.4). So: drawn within the
-- world's age, less a second, so that no starting value up to 0 counts as drawn.
-- Without the world's clock, or in a world's first two seconds: drawn in the last
-- second, which is Unreal's own test of whether to animate it.
local function everDrawn(part)
    local tolerance = 1
    local statics = ue.find("/Script/Engine.Default__GameplayStatics")
    if statics then
        local okTime, time = ue.call(statics, "GetTimeSeconds", part)
        if okTime and type(time) == "number" and time - 1 > tolerance then
            tolerance = time - 1
        end
    end
    local ok, drawn = ue.call(part, "WasRecentlyRendered", tolerance)
    return ok and drawn == true
end

-- The tick option of a skinned mesh whose animation stops while it isn't drawn: one
-- with an animation of its own (a mesh that follows another's pose doesn't run one)
-- and an option from TICK_STOPS_UNSEEN on. nil for any other mesh.
local function stoppingOption(part)
    local option = ue.number(part, TICK_OPTION)
    if not option or option < TICK_STOPS_UNSEEN then
        return nil
    end
    local ok, anim = ue.call(part, "GetAnimInstance")
    return ok and ue.valid(anim) and option or nil
end

-- Whether part is a mesh the mod would keep animating that has never been drawn,
-- whatever the game's own flags say: a mesh they still hide may be shown a frame or
-- two from now.
local function undrawnMesh(part, skinned)
    return part:IsA(skinned) and stoppingOption(part) ~= nil and not everDrawn(part)
end

-- Before a character's first start: whether one of its meshes that the mod would keep
-- animating has never been drawn. The game may have shown it only on this frame or
-- the one before (a new area that opens with a cinematic or a battle, which hid the
-- character from its first frame), or may show it a frame or two after its battle or
-- cinematic flag clears: the renderer's word reaches the game a frame or two late,
-- and once the mod hides the mesh it never comes. So first person waits for it,
-- DRAW_WAIT frames at most: a mesh the game never draws stays undrawn.
local function bodyUndrawn(pawn)
    local skinned = ue.find(SKINNED)
    if not skinned then
        return false
    end
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    for _, part in ipairs(parts) do
        local ok, undrawn = pcall(undrawnMesh, part, skinned)
        if ok and undrawn then
            return true
        end
    end
    return false
end

-- Whether the game itself hides a part the mod hides, so that it isn't drawn in third
-- person either: it hid it before the mod did, made it invisible, or (for a part
-- hidden from the player only) hid it in game.
local function hiddenByGame(entry)
    local part = entry.obj
    return entry.was or ue.get(part, "bVisible") == false
        or (entry.how == "owner" and ue.get(part, "bHiddenInGame") == true)
end

local function writeTick(part, option)
    part[TICK_OPTION] = option
end

-- Puts the tick option back, unless the game set one of its own since the last pass.
-- same: whether the part is still the one the mod changed.
local function stopAnimating(entry, part, same)
    if entry.tick == nil then
        return
    end
    journal.forget("prop", entry.fullName, TICK_OPTION)
    if same and ue.number(part, TICK_OPTION) == TICK_AS_IF_SEEN then
        pcall(writeTick, part, entry.tick)
    end
    entry.tick = nil
end

-- Sets the mod's tick option and reads it back. If it didn't take (UE4SS couldn't write
-- it, or something put another value back at once), there is nothing to put back, and
-- the part isn't tried again until the mod hides it anew. Returns whether it took.
local function setTick(entry)
    local part = entry.obj
    local ok, err = pcall(writeTick, part, TICK_AS_IF_SEEN)
    local option = ue.number(part, TICK_OPTION)
    if ok and option == TICK_AS_IF_SEEN then
        return true
    end
    journal.forget("prop", entry.fullName, TICK_OPTION)
    entry.tick, entry.refused = nil, true
    log.once("animate-refused", "Could not keep %s animating, so its sounds may stop in first person: its tick "
        .. "option reads %s after setting %d%s", ue.describe(part), tostring(option), TICK_AS_IF_SEEN,
        ok and "" or (" (" .. tostring(err) .. ")"))
    return false
end

-- Whether the object at the entry's address is still the entry's part. hideOne compares
-- the full names on some passes only, and between them a new mesh can have taken the
-- address of a destroyed one. So this is asked before the mod sets a tick option, or
-- takes one it reads for the game's: a new mesh the game made already hidden would
-- otherwise get the mod's option, and nothing would put its own back.
local function stillThePart(entry)
    return ue.fullName(entry.obj) == entry.fullName
end

-- Keeps the animation of a skinned mesh the mod hides running as if the player saw
-- it, so that its anim notifies still play their sounds. entry.tick is the option to
-- put back. Only for a mesh with an animation of its own (one that follows another
-- mesh's pose doesn't run it), whose option would stop it, that the game doesn't hide
-- itself, and that the game had drawn at some time before the mod hid it, at this
-- hide or an earlier one in the character's life (everDrawn, kept in drawnBefore).
-- One the game never draws never ran its animation, and starting it could double
-- the sounds. That also leaves out a body the game shows for the first time only
-- after the mod hid it (an area that opens with a cinematic or a battle): it is
-- logged, and kept animating from the next time first person starts after it was in
-- view. Returns true if another part has taken the address.
local function keepAnimating(entry)
    local part = entry.obj
    local option = stoppingOption(part)
    if not option or hiddenByGame(entry) then
        return false
    end
    if not entry.fullName or drawnBefore[ue.address(part) or false] ~= entry.fullName then
        log.once("animate-unseen:" .. tostring(entry.fullName), "Not keeping %s animating: the game hadn't drawn it "
            .. "when the mod hid it, so its sounds stop in first person, until first person next starts after it "
            .. "was in view (tick option %s)", ue.describe(part), tickName(option))
        return false
    end
    if not stillThePart(entry) then
        return true
    end
    log.first("animate", "Keeping the hidden body's animation going, so its sounds play: %s, %s -> %s",
        ue.describe(part), tickName(option), tickName(TICK_AS_IF_SEEN))
    entry.tick = option
    journal.note("prop", entry.fullName, TICK_OPTION, option)
    setTick(entry)
    return false
end

-- Each pass while the mod keeps a part animating. If the game hides the part itself,
-- its animation would stop in third person too, so its option goes back. An option
-- the game wrote since the last pass is the one to put back, and if it would stop the
-- animation, the mod's is set again; one that animates the part unseen is the game's
-- to keep, and the mod has nothing left on the part (keepAnimating takes it up again
-- if the game later writes one that would stop it). Returns true if another part has
-- taken the address: what reads like the game's doing is then the new part's own.
local function checkAnimating(entry)
    local part = entry.obj
    if hiddenByGame(entry) then
        if not stillThePart(entry) then
            -- Another part, or this one under another full name: showPart tells which,
            -- and puts the option back on a part the game only moved.
            return true
        end
        stopAnimating(entry, part, true)
        return false
    end
    local option = ue.number(part, TICK_OPTION)
    if option == nil or option == TICK_AS_IF_SEEN then
        return false
    end
    if not stillThePart(entry) then
        return true
    end
    if option < TICK_STOPS_UNSEEN then
        journal.forget("prop", entry.fullName, TICK_OPTION)
        entry.tick = nil
        log.once("animate-again", "The game set %s's animation tick option to %s, which animates it unseen: the mod "
            .. "leaves it", ue.describe(part), tickName(option))
        return false
    end
    entry.tick = option
    journal.note("prop", entry.fullName, TICK_OPTION, option)
    if setTick(entry) then
        log.once("animate-again", "The game set %s's animation tick option to %s; it is kept animating",
            ue.describe(part), tickName(option))
    end
    return false
end

-- On each hiding pass, for a skinned part: keeps it animating, or checks on it while
-- it does. Returns true if it found another part at the entry's address (before
-- touching its tick option): hideOne then takes that one for a new part.
local function animate(entry, cfg)
    if not entry.skinned then
        return false
    end
    if entry.tick ~= nil then
        return checkAnimating(entry)
    elseif cfg.BodySounds and not entry.refused then
        return keepAnimating(entry)
    end
    return false
end

-- The class and the object's own name in a full name: "SkeletalMeshComponent" and
-- "Body" for "SkeletalMeshComponent /Game/Maps/Town.Town:PersistentLevel.Hero_C_12.Body".
local function classAndName(fullName)
    return fullName:match("^(%S+) "), fullName:match("([^.:]+)$")
end

-- Whether the object at a hidden part's address, which now has another full name
-- (nowName), is still that part: the game moved it to another actor, as it may do
-- with a skin's body (the path in its full name changes; its class and own name
-- stay). Only for a part the mod itself hid, while its flag is still set: a new
-- object at a freed address starts shown. A part the mod hid in game is judged only
-- if the character owns it now (a skin's body hidden while it was still its skin
-- actor's, then moved into the character): otherwise hidden in game is ordinary for
-- a new object that was put away.
local function movedByGame(entry, part, nowName)
    if entry.was or not entry.fullName or ue.get(part, hiddenFlag(entry)) ~= true then
        return false
    end
    if entry.how ~= "owner" then
        local ok, owner = ue.call(part, "GetOwner")
        if not (ok and st.pawnAddr and ownedByPawn(owner, st.pawnAddr)) then
            return false
        end
    end
    local class, name = classAndName(entry.fullName)
    local nowClass, nowOwnName = classAndName(nowName)
    if class == nil or name == nil or class ~= nowClass or name ~= nowOwnName then
        return false
    end
    st.partsMoved = st.partsMoved + 1
    if st.partsMoved <= MAX_MOVED_PART_LINES then
        log.info("The game moved a part the mod had hidden (%s is now %s); it is put back as it was",
            entry.fullName, nowName)
    end
    return true
end

-- Shows a part the way it was before (if it is still the same part) and forgets it.
-- A part the game has shown since the last pass stays shown. A part the game moved
-- to another actor meanwhile is put back too (see movedByGame): left hidden, it
-- would look hidden by the game itself if it came back, and stay hidden for good.
local function showPart(entry)
    journal.forget("hide", entry.fullName, entry.how)
    local part = entry.obj
    local nowName = ue.fullName(part) -- nil if it is gone
    local same = ue.valid(part)
        and (nowName == entry.fullName or (nowName ~= nil and movedByGame(entry, part, nowName)))
    if nowName ~= nil and not same and not entry.was and ue.get(part, hiddenFlag(entry)) == true then
        log.once("left-hidden", "A part the mod had hidden (%s) is now %s, still hidden: the mod can't tell whether "
            .. "it is the same part, so it is left as it is. If a part of your character stays invisible in third "
            .. "person, load a save, and please report UE4SS.log.", tostring(entry.fullName), nowName)
    end
    stopAnimating(entry, part, same)
    if same and ue.get(part, hiddenFlag(entry)) ~= false then
        pcall(function()
            if entry.how == "owner" then
                part:SetOwnerNoSee(entry.was)
            else
                part:SetHiddenInGame(entry.was, false)
            end
        end)
    end
end

local function hideOne(part, address, primitive, pawnAddr, checkNames, firstPass, cfg)
    local entry = hidden[address]
    if entry then
        -- A known part that doesn't read as hidden was shown by the game, or is a new
        -- part at the address of a destroyed one (UE4SS tells objects apart by their
        -- address only), so then its full name is compared too, before the mod hides
        -- it again. "Doesn't read as hidden" and not "reads as shown": the new object
        -- may not be a primitive, and then it has no bOwnerNoSee to read (UE4SS gives
        -- an invalid object or nil for a name an object doesn't have) and no
        -- SetOwnerNoSee to call. (Before its tick option is touched, animate compares
        -- the names.)
        local flag = ue.get(part, hiddenFlag(entry))
        if ue.valid(entry.obj) and not ((checkNames or flag ~= true) and entry.fullName ~= ue.fullName(part)) then
            if flag ~= true then
                if flag == false and entry.was then
                    -- The game showed it: shown is what to put back.
                    entry.was = false
                    journal.note("hide", entry.fullName, entry.how, false)
                end
                hidePart(entry)
            end
            if not animate(entry, cfg) then
                return
            end
        end
        -- A new part where an old, now destroyed one used to be: the old one is
        -- forgotten. Or the old one under another full name (see movedByGame): it is
        -- put back, and hidden again as a new part.
        showPart(entry)
        hidden[address] = nil
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
    local skinned = ue.find(SKINNED)
    entry = { obj = part, fullName = fullName, how = how,
        was = ue.get(part, how == "owner" and "bOwnerNoSee" or "bHiddenInGame") == true,
        skinned = skinned ~= nil and part:IsA(skinned) }
    if entry.skinned and everDrawn(part) then
        -- The game has drawn it, now or before it hid it for a while (a cinematic, a
        -- battle). Asked before the mod hides it, and whatever BodySounds says, so that
        -- F7 can switch it on.
        drawnBefore[address] = fullName
    end
    hidden[address] = entry
    journal.note("hide", entry.fullName, how, entry.was)
    hidePart(entry)
    animate(entry, cfg)
end

-- Hides everything visible that is attached to the character: its own meshes (in
-- Expedition 33 also the skin's body, face and hair, which the game moves into the
-- character) and those of attached actors, such as gear. Parts the character owns
-- get "owner no see", which hides them only from the player's own view; other parts
-- are hidden in game. Lights are separate components and stay on.
-- Parts that are no longer attached (dropped, or detached by the game) are shown.
-- Skinned meshes keep animating with BodySounds (see keepAnimating).
local function hideBody(pawn, cfg)
    local primitive = ue.find(PRIMITIVE)
    if not primitive then
        return
    end
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    -- Counted once the parts are listed: a pass whose walk failed hid nothing, so the
    -- next one is still the first, which hides every part at once.
    st.passes = st.passes + 1
    local firstPass = st.passes == 1
    local checkNames = st.passes % NAME_CHECK_EVERY == 0
    if checkNames then
        notPrimitive = {} -- addresses can be reused, so this is worked out again now and then
    end
    if firstPass then
        log.first("hide", "Hiding the character's body (%d attached parts)", #parts)
    end
    local pawnAddr = ue.address(pawn)
    local seen = {}
    for _, part in ipairs(parts) do
        local address = ue.address(part)
        if address then
            seen[address] = true
            local ok, err = pcall(hideOne, part, address, primitive, pawnAddr, checkNames, firstPass, cfg)
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
    notPrimitive = {} -- the next character's parts may have these addresses
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

-- reason says what went wrong, and with which method.
local function giveUp(pcm, cfg, reason)
    log.warn("First person doesn't work here: %s (camera manager: %s). The game's camera and your character are "
        .. "back. %s, and please report UE4SS.log.", reason, tostring(ue.className(pcm)),
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
    local how = METHOD_NAMES[st.method] or "?"
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
        how = how .. ", and the game's camera couldn't be moved to the eyes (" .. tostring(err) .. ")"
    end
    giveUp(pcm, cfg, reason .. " with " .. how)
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

-- Whether the camera manager is still blending from another view target to the
-- character. GetViewTarget names the character as soon as such a blend starts,
-- but the camera style applies to the old view target too, for the rest of the
-- blend: with FirstPerson, an actor that holds a camera (for sneaking, aiming or a
-- cutscene) would be shown from its own position instead. So the engine's view
-- waits for the blend to end, BLEND_WAIT seconds at most, not counting time paused:
-- the camera manager doesn't blend then. (The game's camera at the eyes doesn't
-- need to wait: it blends there smoothly.)
local function pendingTarget(pcm)
    local pending = ue.get(pcm, "PendingViewTarget")
    local target = ue.typeOf(pending) == "UScriptStruct" and ue.get(pending, "Target") or nil
    return ue.valid(target) and target or nil
end

local function blending(pcm, now, paused)
    local target = pendingTarget(pcm)
    if not target then
        st.blendWaited, st.blendLast, st.blendStuck = nil, nil, false
        return false
    end
    if st.blendStuck then
        return false
    end
    if st.blendLast and not paused then
        st.blendWaited = (st.blendWaited or 0) + (now - st.blendLast)
    end
    st.blendLast = now
    if (st.blendWaited or 0) < BLEND_WAIT then
        return true
    end
    st.blendStuck = true -- until the camera manager has no blend to the character (see camera.watchBlend)
    log.once("blend-stuck", "The camera manager has been blending to %s for %d s; first person starts anyway.",
        ue.describe(target), BLEND_WAIT)
    return false
end

--- Called on every frame the mod acts, whether first person is on or not: once a
--- blend that went on for BLEND_WAIT seconds has ended, the next one is waited for
--- again.
function camera.watchBlend(pcm, pawn)
    if not st.blendStuck then
        return
    end
    local target = pcm and pendingTarget(pcm)
    if not target or ue.address(target) ~= ue.address(pawn) then
        st.blendStuck = false
    end
end

local function startOrGiveUp(method, pawn, pcm, cam, cfg)
    local ok, err = pcall(startMethod, method, pawn, pcm, cam, cfg)
    if not ok then
        guard.report("moving the game's camera to the eyes", err)
        giveUp(pcm, cfg, "the game's camera couldn't be moved to the eyes: " .. tostring(err))
    end
    return ok
end

--- Turns first person on, or keeps it on. Called every frame while it should be on.
--- cam is the camera component the engine shows (nil if none); paused: whether
--- Unreal runs this frame as paused (see main.lua's isPaused; the camera isn't
--- updated then). Returns true if first person started in this call (its refreshes
--- start then, see camera.nextRefresh).
function camera.apply(pc, pawn, pcm, cam, cfg, now, paused)
    -- The camera manager works the view out at the end of each frame that isn't
    -- paused: counted, to tell when what the mod set has been taken in.
    if st.lastUnpaused then
        st.updates = st.updates + 1
    end
    st.lastUnpaused = not paused
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
    -- Whether the game's camera was moved to the eyes in this call: then there is
    -- nothing the game could have changed yet.
    local justMoved, started = false, false
    if not st.active then
        st.pcmClass = ue.className(pcm)
        local method = chooseMethod(cfg)
        if method == "game" and not cam then
            st.waiting = "camera" -- nothing to move; waits for the game to show its camera
            return
        end
        if method == "engine" and blending(pcm, now, paused) then
            st.waiting = "blend"
            return
        end
        if drawnPawn ~= pawnAddr and cfg.HideBody and cfg.BodySounds and st.bodyWaited < DRAW_WAIT then
            -- An error in going through the parts costs the wait, not first person: hiding
            -- the body, its own step, goes through them on this frame too and logs it.
            local looked, undrawn = pcall(bodyUndrawn, pawn)
            if looked and undrawn then
                st.bodyWaited = st.bodyWaited + 1
                st.waiting = "body" -- the game has never drawn the body: waits a few frames for it to be
                return
            end
        end
        st.waiting = nil
        st.active = true
        st.pawnAddr = pawnAddr
        st.pcmAddr = pcmAddr
        if drawnPawn ~= pawnAddr then
            drawnBefore, drawnPawn = {}, pawnAddr -- another character: what was drawn of the last one is gone
        end
        st.passes = 0
        st.moveLines = 0
        st.nextRefresh = 0
        st.hasTargetRotation = ue.typeOf(ue.get(pawn, "TargetRotation")) == "UScriptStruct"
        if not startOrGiveUp(method, pawn, pcm, cam, cfg) then
            return
        end
        justMoved, started = method == "game", true
    elseif st.method == "game" and cam and st.moved and not ue.same(cam, st.moved.cam) then
        -- The game shows another of its exploration cameras now: move that one.
        putCameraBack()
        if not startOrGiveUp("game", pawn, pcm, cam, cfg) then
            return
        end
        justMoved = true
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
    elseif st.moved and not justMoved then
        if not keepAtEyes(st.moved, eye or st.moved.eye, cfg, refresh, paused) then
            giveUp(pcm, cfg, "Unreal refused to attach the game's camera to the character's capsule again, after "
                .. "the game had attached it elsewhere, with " .. METHOD_NAMES.game)
            return
        end
    end
    if refresh then
        -- Counted from when it was due, not from this frame: counted from the frame,
        -- it would drift with the frame times onto the frames of the camera list's
        -- scans and the movement's refreshes, which are put between these.
        local due = st.nextRefresh > 0 and st.nextRefresh or now
        repeat
            due = due + REFRESH
        until due > now
        st.nextRefresh = due
        guard.run("widening the pitch limits", widenPitch, pcm, cfg.PitchLimit)
        if cfg.HideBody then
            guard.run("hiding the body", hideBody, pawn, cfg)
        end
        if st.method == "engine" then
            -- The FirstPerson style skips the camera modifiers, which play the
            -- shakes, so shakes the game starts would pile up until it ends.
            pcall(stopShakes, pcm)
        end
    end
    judgeView(pawn, pcm, cam, cfg, now, refresh, paused)
    return started
end

--- When first person's next refresh is due (nil while it is off).
function camera.nextRefresh()
    return st.active and st.nextRefresh or nil
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
    local count, animated = 0, 0
    for _, entry in pairs(hidden) do
        count = count + 1
        if entry.tick ~= nil then
            animated = animated + 1
        end
    end
    local state
    if st.unavailable then
        state = "given up: " .. st.unavailable
    elseif not st.active then
        state = st.waiting and "waiting" or "off"
    elseif st.confirmed then
        state = "working"
    else
        state = "checking"
    end
    local engineFailed = {}
    for class, reason in pairs(st.engineFailed) do
        engineFailed[#engineFailed + 1] = class .. ": " .. reason
    end
    return { active = st.active, state = state, method = st.method, waiting = st.waiting,
        methodName = st.method and METHOD_NAMES[st.method] or "none",
        styleRoute = st.styleRoute or "not set", hiddenParts = count, animatedParts = animated,
        partsMoved = st.partsMoved, -- all of them: the log has a line for the first few only
        lastDistance = st.lastDistance,
        moved = st.moved and ue.describe(st.moved.cam) or nil, reattached = st.moved and st.moved.reattached or 0,
        engineFailed = table.concat(engineFailed, "; ") }
end

--- For the report: the tick option the mod will put back on a part it keeps
--- animating, or nil.
function camera.tickToPutBack(part)
    local entry = hidden[ue.address(part) or false]
    return entry and entry.tick
end

--- "4 (OnlyTickPoseWhenRendered)", for the report.
camera.tickName = tickName

--- For the report: every component attached to the character, directly or through
--- others, as the body hiding walks them: the character's own parts and those of
--- actors attached to it.
function camera.attachedParts(pawn)
    local parts = {}
    collect(ue.get(pawn, "RootComponent"), parts, 0)
    return parts
end

--- Turns first person off and puts back everything it changed.
function camera.release()
    st.waiting = nil
    st.bodyWaited = 0 -- the next start gets the whole wait for the body again
    st.blendWaited, st.blendLast = nil, nil -- a blend seen from now on gets the whole wait again
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
        if entry.tick ~= nil then
            journal.forget("prop", entry.fullName, TICK_OPTION)
        end
    end
    hidden = {}
    waiting = {}
    notPrimitive = {}
    drawnBefore, drawnPawn = {}, nil
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
    st.styleRoute = nil
    st.waiting = nil
    st.bodyWaited = 0
    st.blendWaited, st.blendLast, st.blendStuck = nil, nil, false
end

return camera
