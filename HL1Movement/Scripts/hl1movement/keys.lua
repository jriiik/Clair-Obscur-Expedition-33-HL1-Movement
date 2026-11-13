-- The mod's duck, duck tap and jump keys, kept from the game while the mod moves the
-- character; and the hotkeys, bound with Ctrl and Shift held too.
--
-- In E33 Left Shift runs, Left Ctrl toggles walking and Space jumps (the game's Enhanced
-- Input actions SprintAction, WalkAction and JumpAction). While the mod moves the character
-- those keys are the mod's, and the game mustn't act on them too. The way: an input mapping
-- context of the mod's own at a priority above the game's, holding one boolean input action
-- that consumes its keys and that nothing listens to. Enhanced Input then leaves the game's
-- mappings on those keys out of the player's mappings, whatever their triggers, while the
-- mod still reads the keys with IsInputKeyDown, which doesn't look at mappings. No game value
-- is written, so the game's walk and run state is what it was when the mod lets go.
--
-- - A key is taken only once it is up, key by key: a key held when the mod takes over (Shift
--   held through the end of a battle, the game's run) stays the game's until it is let go,
--   and the game sees its release. Each change of the keys taken makes a new context; the
--   old one is removed after the new one is in.
-- - The keys are given back (the context removed) on every frame the mod doesn't move the
--   character, paused frames included, and while the game shows a dialogue, a cinematic or
--   another view target. The removal asks the engine to ignore keys held until they are let
--   go, so that a held key's game action doesn't start under it; in case it does, a guard
--   puts the game's walk and run state back while such a key stays down (keys.watch).
-- - If the context can't be set up, or the game keeps dropping it, the mod falls back to
--   putting the game's walk and run state back on frames with one of its keys down (way
--   "gait"), and then to nothing (way "off"); each step is one warning. F5 and F7 try the
--   context again.
-- - A UE4SS mods restart leaves the old copy's context applied: the journal's "context" line
--   lets the new copy remove it on its first frame.
-- Every object is checked (valid, the same full name) before every call: in UE4SS an invalid
-- subsystem as the calling context crashes the game instead of raising an error. Nothing here
-- runs from a key callback or the jump hook, only from the frame hook (but bindAll's binds).

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local journal = require("hl1movement.journal")
local input = require("hl1movement.input")
local settings = require("hl1movement.settings")

local keys = {}

local IFACE = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:"
local SUBSYSTEM_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local SUBSYSTEM_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ACTION_CLASS = "/Script/EnhancedInput.InputAction"
local CONTEXT_CLASS = "/Script/EnhancedInput.InputMappingContext"
local TRANSIENT = "/Engine/Transient"
local KEY_LIBRARY = "/Script/Engine.Default__KismetInputLibrary"

-- Above every context of the game's seen (the highest known: 1000, its targeting).
keys.PRIORITY = 1000000
-- FModifyContextOptions, with all three fields every time: UE4SS zeroes the parameter, so a
-- field left out would be false. An add asks not to ignore pressed keys: the mod adds only
-- keys that are up, so that could only cut a game action held then (free aim on the right
-- mouse button). A removal that gives the keys back asks to ignore them until let go: the
-- game's mappings come back under keys that may be held. The old context's removal when a
-- new one holds its keys and more brings none of the game's back: the add's options.
keys.ADD = { bIgnoreAllPressedKeysUntilRelease = false, bForceImmediately = true, bNotifyUserSettings = false }
keys.REMOVE = { bIgnoreAllPressedKeysUntilRelease = true, bForceImmediately = true, bNotifyUserSettings = false }
keys.SWAP = keys.ADD

local GUARD_TIME = 10 -- s the hand-back guard stays at most
local GUARD_FRAMES = 3 -- the guard reads DesiredGait on its first frames,
local AFTER_RELEASE = 2 -- and on the frame a guarded key is let go and the one after
local HOT_FRAMES = 2 -- way "gait": a key down on this frame or one of the two before
local GAIT_EVERY = 1 -- s: way "gait" reads DesiredGait at least this often otherwise
local MAX_DROPS, DROP_WINDOW = 5, 60 -- the game dropping the context this often in this many s
local LIST_TAKES = 3 -- the first takes of a session read the player's mappings around the add
local MAX_LINES = 3 -- lines of each kind about what the game did, until keys.logAgain
-- A hotkey's binds called again within this long (s) with no frame in between are one press
-- (a UE4SS that calls every bind whose modifiers are held).
local HOTKEY_REPEAT = 0.05

-- The four sets of modifiers a hotkey is bound with, the most held first (a UE4SS that calls
-- every bind whose modifiers are held calls them in this order, and the first one counts).
-- Not Alt: Alt+F4 is Windows', and overlays use Alt with the function keys.
local MODIFIER_SETS = { { "Ctrl+Shift", "CONTROL", "SHIFT" }, { "Ctrl", "CONTROL" }, { "Shift", "SHIFT" } }

local clock = os and os.clock or function()
    return 0
end

local NO_POLLS = {} -- (never written)

local function newState()
    return {
        method = "context", -- "context", "gait" (the game's walk/run state kept) or "off"
        why = nil, -- why the method is what it is
        alsoGait = false, -- the context, and the game's state kept as well (a game action left on a key)
        pc = nil, -- the controller the keys were last taken or given back with
        sub = nil, subName = nil, -- the Enhanced Input subsystem and its full name
        action = nil, actionName = nil, -- the mod's input action, made once while it lives
        ctx = nil, ctxName = nil, -- the context applied now
        taken = {}, -- name -> true: the keys in it
        waiting = "", -- the keys wanted but held, for the state line
        takes = 0, remakes = 0, drops = 0, gaitPutBack = 0, guardPutBack = 0,
        dropTimes = {},
        listTakes = 0,
        guard = nil, -- the hand-back guard, while armed
        gait = nil, -- way "gait"'s values to keep
        gameActions = nil, -- key -> the game's actions on it, read at the last take that looked
        lastWaitLine = nil, -- the last line about which game actions wait
    }
end

local K = newState()
local cfgNow = nil -- the settings keys.validate (or keys.take) was given
local namesFor = { cfg = nil, names = nil } -- the keys to take, for cfgNow
local now = 0 -- the mod's clock, from keys.watch and keys.check
local serial = 0 -- frames seen by keys.watch, for the hotkeys' repeats
local lines = {} -- kind -> lines written since keys.logAgain
local warned = {} -- warnings written once a session

local function noted(kind, fmt, ...)
    local n = (lines[kind] or 0) + 1
    lines[kind] = n
    if n <= MAX_LINES then
        log.info(fmt, ...)
    end
end

local function warnOnce(key, fmt, ...)
    if not warned[key] then
        warned[key] = true
        log.warn(fmt, ...)
    end
end

local function sorted(set)
    local list = {}
    for name in pairs(set) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

local function joinAnd(list)
    if #list <= 1 then
        return list[1] or ""
    end
    return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

-- Whether obj is still the object found earlier with this full name.
local function same(obj, fullName)
    return obj ~= nil and fullName ~= nil and ue.valid(obj) and ue.fullName(obj) == fullName
end

-- The keys the mod takes: the duck and duck tap keys (with Ducking), the jump keys (with
-- TakeJumpKeys, and not with JumpInput "game", which needs the game's own jump event),
-- each name once, without names the game refused (keys.validate).
local function wantedNames(cfg)
    if namesFor.cfg == cfg and namesFor.names then
        return namesFor.names
    end
    local names, have = {}, {}
    local function add(list)
        for _, name in ipairs(list or {}) do
            if not have[name] and not input.isRefused(name) then
                have[name] = true
                names[#names + 1] = name
            end
        end
    end
    if cfg.Ducking ~= false then
        add(cfg.DuckKeys)
        add(cfg.DuckTapKeys)
    end
    if cfg.TakeJumpKeys ~= false and cfg.JumpInput ~= "game" then
        add(cfg.JumpKeys)
    end
    namesFor.cfg, namesFor.names = cfg, names
    return names
end

-- The setting a key is in, for the log.
local function listOf(cfg, name)
    for _, list in ipairs(settings.KEY_LISTS) do
        for _, key in ipairs(cfg and cfg[list] or {}) do
            if key == name then
                return list
            end
        end
    end
    return "config.lua"
end

local function interface(name)
    return ue.find(IFACE .. name)
end

local function nameText(fname)
    return fname:ToString()
end

-- The game's input actions on each of the names, from the player's mapping list (about a
-- hundred entries, so only at the first takes of a session): name -> list of action names,
-- the mod's own action left out; and name -> true for the names the mod's action is on.
-- nil if the list can't be read.
local function mappingsOn(pc, names)
    local playerInput = ue.object(pc, "PlayerInput")
    local list = playerInput and ue.get(playerInput, "EnhancedActionMappings")
    if not list then
        return nil
    end
    local wanted = {}
    for _, name in ipairs(names) do
        wanted[name:lower()] = name
    end
    local found, mine = {}, {}
    local mod = ue.address(K.action)
    for _, mapping in ipairs(ue.list(list)) do
        local key = ue.get(mapping, "Key")
        local keyName = key and ue.get(key, "KeyName")
        local ok, text = pcall(nameText, keyName)
        local name = ok and type(text) == "string" and wanted[text:lower()]
        if name then
            local action = ue.get(mapping, "Action")
            if mod and ue.address(action) == mod then
                mine[name] = true
            else
                local actionName = ue.name(action)
                if actionName then
                    found[name] = found[name] or {}
                    table.insert(found[name], actionName)
                end
            end
        end
    end
    return found, mine
end

--- What the game has on the mod's keys now, from the player's mapping list (for the report):
--- name -> list of the game's actions, and name -> true where the mod's action is.
function keys.mappings(pc)
    if not cfgNow then
        return nil
    end
    return mappingsOn(pc, wantedNames(cfgNow))
end

-- The game's actions the mod's keys silence while it moves the character: its walk, run,
-- jump and stance. Any other (a key the player put there, a menu's) gets a warning.
local EXPECTED_ACTIONS = { SprintAction = true, WalkAction = true, JumpAction = true, StanceAction = true }

-- The line after a take: which of the game's actions wait while the mod moves you.
local function waitLine(cfg, names, found)
    local byAction, order, nothing = {}, {}, {}
    for _, name in ipairs(names) do
        local actions = found[name]
        if actions then
            for _, action in ipairs(actions) do
                if not byAction[action] then
                    byAction[action] = {}
                    order[#order + 1] = action
                end
                table.insert(byAction[action], name)
                if not EXPECTED_ACTIONS[action] then
                    warnOnce("action " .. name .. " " .. action, "%s is also the game's %s: it won't work while the "
                        .. "mod moves you. Change %s in config.lua to keep it.", name, action, listOf(cfg, name))
                end
            end
        else
            nothing[#nothing + 1] = name
        end
    end
    local parts = {}
    for _, action in ipairs(order) do
        parts[#parts + 1] = string.format("%s (%s)", action, table.concat(byAction[action], ", "))
    end
    local text = #parts > 0 and string.format("while the mod moves you, the game's %s %s", joinAnd(parts),
        #parts == 1 and "waits" or "wait") or "while the mod moves you, the game has nothing on them"
    if #nothing > 0 and #parts > 0 then
        text = text .. string.format("; the game had nothing on %s", table.concat(nothing, ", "))
    end
    return "Keys: " .. text
end

-- The subsystem: the one found before while it is still that object (its full name), else
-- found again through the controller (pc, or the last one the keys were taken with; none:
-- not found again).
local function subsystem(pc)
    if same(K.sub, K.subName) then
        return K.sub
    end
    K.sub, K.subName = nil, nil
    pc = pc or K.pc
    local library, class = ue.find(SUBSYSTEM_LIBRARY), ue.find(SUBSYSTEM_CLASS)
    if not library or not class or not ue.valid(pc) then
        return nil
    end
    local ok, sub = ue.call(library, "GetLocalPlayerSubSystemFromPlayerController", pc, class)
    if ok and ue.valid(sub) then
        local name = ue.fullName(sub)
        if name then
            K.sub, K.subName = sub, name
            return sub
        end
    end
    return nil
end

-- Removes the mod's context, if it is still the one made, through the subsystem given (nil:
-- the call is left out), and forgets it.
local function giveBackContext(options, sub)
    local remove = interface("RemoveMappingContext")
    if K.ctx and remove and sub and same(K.ctx, K.ctxName) then
        pcall(remove, sub, K.ctx, options)
    end
    if K.ctxName then
        journal.forget("context", K.ctxName, "")
    end
    K.ctx, K.ctxName, K.taken = nil, nil, {}
end

-- One step down the fall-backs: the context, then keeping the game's walk/run state, then
-- nothing. Each step is one warning.
local function fallBack(why)
    if K.method == "context" then
        if K.ctx then
            giveBackContext(keys.REMOVE, subsystem())
        end
        K.method, K.why, K.gait = "gait", why, nil
        log.warn("Keys: %s, so the mod can't keep its keys from the game. Instead it puts the game's walk and "
            .. "run state back on frames with one of its keys down; the game's jump and its other actions on those "
            .. "keys still work while the mod moves you. F5 or F7 tries again.", why)
        log.state("Keys", string.format("the game's walk/run state is kept instead (%s)", why))
    elseif K.method == "gait" then
        K.method, K.why, K.gait = "off", why, nil
        log.warn("Keys: %s, so the game may toggle walk and run on the mod's keys while the mod moves you.", why)
        log.state("Keys", string.format("off (%s)", why))
    end
end

-- A new object of the class, in the transient package, with no name (a fixed name would
-- make a live object again in place).
local function make(classPath)
    local class, outer = ue.find(classPath), ue.find(TRANSIENT)
    if not class or not outer then
        return nil
    end
    local ok, obj = pcall(StaticConstructObject, class, outer)
    if ok and ue.valid(obj) then
        local name = ue.fullName(obj)
        if name then
            return obj, name
        end
    end
    return nil
end

-- Applies a new context with these keys, removes the old one, and checks the result on the
-- first takes of a session.
local function applyContext(pc, cfg, names)
    local sub = subsystem(pc)
    if not sub then
        return fallBack("the game's Enhanced Input subsystem wasn't found")
    end
    local add, has, remove = interface("AddMappingContext"), interface("HasMappingContext"),
        interface("RemoveMappingContext")
    if not (add and has and remove) then
        return fallBack("the game has no AddMappingContext, HasMappingContext or RemoveMappingContext")
    end
    log.first("keys", "Taking the mod's keys from the game while it moves your character: %s",
        table.concat(names, ", "))
    local look = K.listTakes < LIST_TAKES
    local before = look and mappingsOn(pc, names)
    if not same(K.action, K.actionName) then
        K.action, K.actionName = make(ACTION_CLASS)
        if not K.action then
            return fallBack("the mod's input action couldn't be made")
        end
    end
    local ctx, ctxName = make(CONTEXT_CLASS)
    if not ctx then
        return fallBack("the mod's input mapping context couldn't be made")
    end
    for _, name in ipairs(names) do
        local ok, err = ue.call(ctx, "MapKey", K.action, ue.fkey(name))
        if not ok then
            return fallBack(string.format("mapping %s failed (%s)", name, tostring(err)))
        end
    end
    if not same(sub, K.subName) or not same(K.action, K.actionName) then
        return fallBack("the game's input objects changed while the mod made its context")
    end
    local added = pcall(add, sub, ctx, keys.PRIORITY, keys.ADD)
    local out = {}
    local asked, applied = false, nil
    if added then
        asked, applied = pcall(has, sub, ctx, out)
    end
    if not (added and asked and applied == true and out.OutFoundPriority == keys.PRIORITY) then
        if added then
            pcall(remove, sub, ctx, keys.SWAP)
        end
        return fallBack(added and "the game didn't apply the mod's input mapping context"
            or "adding the mod's input mapping context failed")
    end
    journal.note("context", ctxName, "", K.subName)
    local old, oldName = K.ctx, K.ctxName
    K.ctx, K.ctxName, K.taken = ctx, ctxName, {}
    for _, name in ipairs(names) do
        K.taken[name] = true
    end
    if old then
        if same(old, oldName) then
            pcall(remove, sub, old, keys.SWAP)
        end
        journal.forget("context", oldName, "")
        K.remakes = K.remakes + 1
    else
        K.takes = K.takes + 1
    end
    if look then
        K.listTakes = K.listTakes + 1
        if before then
            K.gameActions = before
            local line = waitLine(cfg, names, before)
            if line ~= K.lastWaitLine then
                K.lastWaitLine = line
                log.info("%s", line)
            end
        end
        local after = mappingsOn(pc, names)
        for _, name in ipairs(names) do
            local left = after and after[name]
            if left and not K.alsoGait then
                K.alsoGait = true
                log.warn("Keys: the game's %s still answers to %s with the mod's keys taken (something of the "
                    .. "game's is above the mod's priority, or its mappings weren't rebuilt): the game's walk and run "
                    .. "state is kept as well.", table.concat(left, ", "), name)
            end
        end
    end
end

-- Way "gait": on each frame the mod moves the character, the game's walk/run state is put
-- back if it changed with one of the mod's keys down on this frame or one of the two before
-- (a release reaches the game on the frame it happens); a change on other frames is the
-- game's own (a scripted walk zone), and kept, as is one from a key held since the take-over.
-- IsSprintRequested is read on every such frame, DesiredGait (an enum: UE4SS builds a table
-- of its names at each read) only on those frames, the two after such a key's release, and
-- once a second otherwise.
local function keepGait(pc, cfg, polls)
    local pawn = ue.object(pc, "Pawn")
    if not pawn then
        return
    end
    local g = K.gait
    local names = wantedNames(cfg)
    if not g or g.pawn ~= ue.address(pawn) then
        g = { pawn = ue.address(pawn), gait = ue.number(pawn, "DesiredGait"),
            sprint = ue.bool(pawn, "IsSprintRequested"), since = HOT_FRAMES + 1, readAt = now, held = {}, adopt = 0 }
        K.gait = g
        if g.gait == nil and g.sprint == nil then
            K.gait = nil
            local why = "the game's walk and run state can't be read (DesiredGait, IsSprintRequested)"
            if K.method == "gait" then
                fallBack(why)
            else
                K.alsoGait = false -- the context stays, without the state kept as well
                warnOnce("gait-unread", "Keys: %s, so it isn't kept as well", why)
            end
        end
        for _, name in ipairs(names) do
            if input.isIgnored(name) then
                g.held[name] = true
            end
        end
        return
    end
    -- A key held since the take-over is the game's until let go: what the game does then, at
    -- its release above all, is its own, and taken in (on the frame of the release and the next).
    for name in pairs(g.held) do
        if not input.isIgnored(name) then
            g.held[name], g.adopt = nil, AFTER_RELEASE
        end
    end
    local active
    for _, name in ipairs(names) do
        local state = polls[name]
        if (state == true or state == "pressed") and not input.isIgnored(name) then
            active = name
            break
        end
    end
    if active then
        g.since, g.key = 0, active
    else
        g.since = g.since + 1
    end
    local hot = g.since <= HOT_FRAMES
    if g.sprint ~= nil then
        local sprint = ue.bool(pawn, "IsSprintRequested")
        if sprint ~= nil and sprint ~= g.sprint then
            if hot then
                pawn.IsSprintRequested = g.sprint
                K.gaitPutBack = K.gaitPutBack + 1
                noted("gait", "Keys: the game started or stopped its run on a frame with %s down; put back",
                    tostring(g.key))
            else
                g.sprint = sprint
            end
        end
    end
    if g.gait ~= nil and (hot or g.adopt > 0 or now - g.readAt >= GAIT_EVERY) then
        g.readAt = now
        local gait = ue.number(pawn, "DesiredGait")
        if gait ~= nil and gait ~= g.gait then
            if hot then
                pawn.DesiredGait = g.gait
                K.gaitPutBack = K.gaitPutBack + 1
                noted("gait", "Keys: the game changed its gait from %s to %s on a frame with %s down; put back",
                    tostring(g.gait), tostring(gait), tostring(g.key))
            else
                g.gait = gait
            end
        end
    end
    if g.adopt > 0 then
        g.adopt = g.adopt - 1
    end
end

--- Takes the keys from the game, on each frame the mod moves the character (root motion
--- included) and the keys are the mod's. polls: input.lastPolls(frame), what input.buttons
--- read this frame: a key is taken once it has read up (a wheel key always counts as up), and
--- one not read this frame isn't taken on it; taken keys stay taken. cfg: the settings
--- (keys.validate's if nil). With TakeKeys = false nothing happens: no game call at all.
--- Steady state: nothing but Lua (keys.check asks the game every 0.5 s).
function keys.take(pc, polls, cfg)
    cfg = cfg or cfgNow
    if not cfg then
        return
    end
    if cfg.TakeKeys == false then
        log.state("Keys", "off (TakeKeys = false)")
        return
    end
    cfgNow, K.pc = cfg, pc
    polls = polls or NO_POLLS
    if K.method == "gait" or (K.method == "context" and K.alsoGait) then
        keepGait(pc, cfg, polls)
    end
    if K.method ~= "context" then
        return
    end
    -- A key not taken yet that is up now (or a wheel key) changes the set; one down waits.
    local names = wantedNames(cfg)
    local changed, waiting = false, nil
    for _, name in ipairs(names) do
        if not K.taken[name] then
            local state = polls[name]
            if state == false or state == "pressed" or input.isWheel(name) then
                changed = true
            elseif state == true then
                waiting = waiting or {}
                waiting[#waiting + 1] = name
            end
        end
    end
    local waitingText = waiting and table.concat(waiting, ", ") or ""
    if changed then
        local list = {}
        for _, name in ipairs(names) do
            local state = polls[name]
            if K.taken[name] or state == false or state == "pressed" or input.isWheel(name) then
                list[#list + 1] = name
            end
        end
        applyContext(pc, cfg, list)
    end
    if (changed or waitingText ~= K.waiting) and K.method == "context" then
        K.waiting = waitingText
        local taken = sorted(K.taken)
        local text = #taken > 0 and ("taken: " .. table.concat(taken, ", ")) or "none taken yet"
        if waiting then
            text = string.format("%s; %s %s held, so %s the game's until you let go", text, waitingText,
                #waiting == 1 and "is" or "are", #waiting == 1 and "it stays" or "they stay")
        end
        log.state("Keys", text)
    end
end

-- The hand-back guard: armed when the keys are given back with a taken key held. Until every
-- such key is let go, the character changes or 10 s pass (not counting paused frames: the
-- game's actions can only come once it runs again), a change of the game's walk/run
-- state is the game acting on a key held over the hand-back (the engine's "ignore pressed
-- keys" didn't hold), and is written back; but for the end of a run: a key the game still
-- had (Shift held since the take-over, a gamepad's trigger) can be let go meanwhile, and a
-- held key of the mod's can only start a run (the game never saw it pressed), so a run that
-- ends is the game's and is kept, with the gait it sets on that frame and the next.
local function armGuard(pc)
    local held = {}
    for _, name in ipairs(sorted(K.taken)) do
        if not input.isWheel(name) then
            local ok, down = ue.call(pc, "IsInputKeyDown", ue.fkey(name))
            if ok and down == true then
                held[#held + 1] = name
            end
        end
    end
    local pawn = #held > 0 and ue.object(pc, "Pawn")
    if not pawn then
        return
    end
    K.guard = { pawn = ue.address(pawn), keys = held, released = {}, gait = ue.number(pawn, "DesiredGait"),
        sprint = ue.bool(pawn, "IsSprintRequested"), ends = now + GUARD_TIME, at = now, frames = 0, after = 0,
        adopt = 0 }
end

--- Gives the keys back to the game: on paused frames, at every movement blocker, while the
--- game shows a dialogue, a cinematic or another view target, when the mod lets go of the
--- character. why: for the log ("paused", "battle" ...); "area", "world" and "character" (a
--- new character, or none the mod works with) arm no guard (the game may be replacing the
--- character then: the controller's Pawn is the new one already).
function keys.give(pc, why)
    K.gait = nil -- way "gait" takes the game's values afresh at the next take-over
    K.waiting = ""
    if not K.ctx then
        return
    end
    local valid = ue.valid(pc)
    if valid then
        K.pc = pc
        if why ~= "area" and why ~= "world" and why ~= "character" then
            armGuard(pc)
        end
    end
    giveBackContext(keys.REMOVE, subsystem(valid and pc or nil))
    log.state("Keys", string.format("given back (%s)", tostring(why or "the mod let go")))
end

--- On every frame hook, before anything else, also with the mod switched off or turned off
--- by its errors: runs the hand-back guard while it is armed (reading the character itself),
--- and counts the frame for the hotkeys. now: the mod's clock, in s; paused: the frame before
--- was one Unreal ran as paused (its time doesn't count for the guard's 10 s).
function keys.watch(pc, nowArg, paused)
    serial = serial + 1
    if type(nowArg) == "number" then
        now = nowArg
    end
    local g = K.guard
    if not g then
        return
    end
    if paused == true then
        g.ends = g.ends + math.max(0, now - g.at)
    end
    g.at = now
    local pawn = ue.valid(pc) and ue.object(pc, "Pawn")
    if not pawn or ue.address(pawn) ~= g.pawn or now > g.ends then
        K.guard = nil
        return
    end
    g.frames = g.frames + 1
    local held = false
    for _, name in ipairs(g.keys) do
        if not g.released[name] then
            local ok, down = ue.call(pc, "IsInputKeyDown", ue.fkey(name))
            if ok and down == true then
                held = true
            else
                g.released[name] = true
                g.after = AFTER_RELEASE
            end
        end
    end
    local reacted
    if g.sprint ~= nil then
        local sprint = ue.bool(pawn, "IsSprintRequested")
        if sprint == false and g.sprint == true then
            g.sprint, g.adopt = false, AFTER_RELEASE -- the game's run ended: kept
        elseif sprint ~= nil and sprint ~= g.sprint then
            pawn.IsSprintRequested = g.sprint
            reacted = true
        end
    end
    if g.gait ~= nil and (g.frames <= GUARD_FRAMES or g.after > 0 or g.adopt > 0) then
        local gait = ue.number(pawn, "DesiredGait")
        if gait ~= nil and gait ~= g.gait and g.adopt > 0 then
            g.gait = gait -- (set with the run's end)
        elseif gait ~= nil and gait ~= g.gait then
            pawn.DesiredGait = g.gait
            reacted = true
        end
    end
    if reacted then
        K.guardPutBack = K.guardPutBack + 1
        noted("guard", "Keys: the game reacted to %s, held as the mod gave the keys back; its walk/run state is "
            .. "put back", table.concat(g.keys, ", "))
    end
    if g.after > 0 then
        g.after = g.after - 1
    end
    if g.adopt > 0 then
        g.adopt = g.adopt - 1
    end
    if not held and g.after == 0 and g.adopt == 0 then
        K.guard = nil
    end
end

--- On the movement's 0.5 s refresh: whether the game still has the mod's context. If not,
--- the game dropped it (counted, the first three logged): the keys are taken again as they
--- come up. Five drops within a minute: the mod stops trying until F5 or F7 (way "gait").
function keys.check(nowArg)
    if type(nowArg) == "number" then
        now = nowArg
    end
    if K.method ~= "context" or not K.ctx then
        return
    end
    local has, sub = interface("HasMappingContext"), subsystem()
    if has and sub and same(K.ctx, K.ctxName) then
        local out = {}
        local ok, applied = pcall(has, sub, K.ctx, out)
        if ok and applied == true and out.OutFoundPriority == keys.PRIORITY then
            return
        end
    end
    K.drops = K.drops + 1
    if K.ctxName then
        journal.forget("context", K.ctxName, "")
    end
    K.ctx, K.ctxName, K.taken = nil, nil, {}
    noted("drops", "Keys: the game dropped the mod's keys (%s so far); they are taken again as they come up",
        K.drops == 1 and "once" or (K.drops .. " times"))
    local recent = {}
    for _, at in ipairs(K.dropTimes) do
        if now - at < DROP_WINDOW then
            recent[#recent + 1] = at
        end
    end
    recent[#recent + 1] = now
    K.dropTimes = recent
    if #recent >= MAX_DROPS then
        fallBack(string.format("the game dropped the mod's keys %d times in a minute", #recent))
    end
end

--- At a world change: removes the context if it and the subsystem are still the objects
--- they were (safe either way: both outlive a level), and forgets the old level's controller
--- and character: no guard, and no hand-back.
function keys.forget()
    giveBackContext(keys.REMOVE, same(K.sub, K.subName) and K.sub or nil)
    K.guard, K.gait, K.waiting, K.pc = nil, nil, "", nil
end

--- F5 and F7: the context is tried again, and the drops counted afresh.
function keys.retry()
    if K.method ~= "context" then
        log.state("Keys", "trying again")
    end
    K.method, K.why, K.alsoGait, K.dropTimes = "context", nil, false, {}
end

--- On the first frame the mod acts after a load or F7: asks the game whether each name of the
--- key lists the mod reads is a key (KismetInputLibrary.Key_IsValid; for a name the mod
--- doesn't know, also Key_IsAnalog). One the game refuses is left out of every reading, with
--- one warning. Also the settings keys.take uses from now on, and F7's retry.
function keys.validate(pc, cfg)
    cfgNow = cfg
    keys.retry()
    local refused = {}
    local library = ue.find(KEY_LIBRARY)
    if library and ue.valid(pc) then
        local asked = {}
        for _, list in ipairs(settings.KEY_LISTS) do
            local read = (cfg.Ducking ~= false or (list ~= "DuckKeys" and list ~= "DuckTapKeys"))
                and (list ~= "JumpKeys" or cfg.JumpInput ~= "game")
            for _, name in ipairs(read and cfg[list] or {}) do
                if not asked[name] then
                    asked[name] = true
                    local ok, valid = ue.call(library, "Key_IsValid", ue.fkey(name))
                    if ok and valid == false then
                        refused[name] = true
                        log.warn('%s: "%s" is not a key the game knows, so it is left out', list, name)
                    elseif ok and valid == true and not settings.isKnownKey(name) then
                        local okAnalog, analog = ue.call(library, "Key_IsAnalog", ue.fkey(name))
                        if okAnalog and analog == true then
                            refused[name] = true
                            log.warn('%s: "%s" is an axis for the game, not a key, so it is left out', list, name)
                        end
                    end
                end
            end
        end
    end
    input.refuse(refused)
    namesFor.cfg, namesFor.names = nil, nil
end

--- F7: the lines about what the game did start again.
function keys.logAgain()
    lines = {}
end

local reported = { takes = 0, remakes = 0, drops = 0, putBack = 0 }

--- What the keys did since the last call, for the status line: the counts, and their text
--- (nil when nothing happened).
function keys.takeStats()
    local counts = { takes = K.takes, remakes = K.remakes, drops = K.drops, putBack = K.gaitPutBack + K.guardPutBack }
    local since = {}
    for name, n in pairs(counts) do
        since[name] = n - reported[name]
    end
    reported = counts
    if since.takes + since.remakes + since.drops + since.putBack == 0 then
        return since, nil
    end
    return since, string.format("keys taken %d %s, re-made %d, dropped by the game %d, the game's gait put back %d",
        since.takes, since.takes == 1 and "time" or "times", since.remakes, since.drops, since.putBack)
end

--- The keys' state, for the report and the status line.
function keys.status()
    local guardKeys
    if K.guard then
        guardKeys = {}
        for i, name in ipairs(K.guard.keys) do
            guardKeys[i] = name
        end
    end
    return {
        method = K.method, why = K.why, alsoGait = K.alsoGait, taken = sorted(K.taken),
        waiting = K.waiting ~= "" and K.waiting or nil, subsystem = K.subName, context = K.ctxName,
        priority = keys.PRIORITY, takes = K.takes, remakes = K.remakes, drops = K.drops,
        gaitPutBack = K.gaitPutBack, guardPutBack = K.guardPutBack, guard = guardKeys,
        gameActions = K.gameActions,
    }
end

--- A UE4SS mods restart: the journal's "context" line (the context's full name, and the
--- subsystem's as the value) has the new copy remove the old copy's context on its first
--- frame, ignoring held keys until they are let go.
function keys.restoreContext(ctx, _, subName)
    local sub = ue.findByFullName(subName)
    if not sub then
        error("the input subsystem is gone")
    end
    local remove = interface("RemoveMappingContext")
    if not remove then
        error("the game has no RemoveMappingContext")
    end
    remove(sub, ctx, keys.REMOVE)
end

if type(journal.restorer) == "function" then
    journal.restorer("context", keys.restoreContext)
end

--- Binds a hotkey (UE4SS's key code) plain and, when UE4SS has its ModifierKey table, with
--- Ctrl, Shift and Ctrl+Shift held too, each in its own pcall: UE4SS calls a bind only when
--- exactly its modifiers are held, so a hotkey bound plain does nothing while the player
--- ducks on Ctrl or holds duck tap on Shift. callback(modifier) gets "Ctrl", "Shift",
--- "Ctrl+Shift" or nil. A second call of the hotkey's binds with no frame in between and
--- within 0.05 s is the same press (a UE4SS that calls every bind whose modifiers are held),
--- and dropped. Returns what the plain bind's RegisterKeyBind gave (true, or false and the
--- error).
function keys.bindAll(code, callback)
    local last -- this hotkey's last call: { serial, time }
    local function bound(modifier)
        return function()
            local t = clock()
            if last and last.serial == serial and t - last.time < HOTKEY_REPEAT then
                return
            end
            last = { serial = serial, time = t }
            callback(modifier)
        end
    end
    local modifierKey = rawget(_G, "ModifierKey")
    if type(modifierKey) == "table" and modifierKey.CONTROL ~= nil and modifierKey.SHIFT ~= nil then
        for _, set in ipairs(MODIFIER_SETS) do
            local held = {}
            for i = 2, #set do
                held[#held + 1] = modifierKey[set[i]]
            end
            local ok, err = pcall(RegisterKeyBind, code, held, bound(set[1]))
            if not ok then
                warnOnce("modifier-binds", "Could not bind the hotkeys with Ctrl or Shift held (%s), so they don't "
                    .. "work while Ctrl or Shift is held", tostring(err))
            end
        end
    else
        warnOnce("no-modifier-key", "This UE4SS has no ModifierKey table, so the hotkeys don't work while Ctrl or "
            .. "Shift is held")
    end
    return pcall(RegisterKeyBind, code, bound(nil))
end

return keys
