-- The player's input: movement keys, the left stick, and the duck, duck tap and jump
-- buttons.
--
-- Keys are read from the player controller every frame with IsInputKeyDown, which is the
-- only way UE4SS's Lua can tell that a key is being held, and with WasInputKeyJustPressed
-- for a press that is over before the frame hook: a mouse-wheel notch (the wheel's two
-- "keys" are pressed and let go at once, so they are never down) and, in a long frame, a
-- quick tap. The game's own jump event is watched as well, in case reading the keys
-- doesn't work.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")

local input = {}

-- In a frame longer than this (s), a quick tap of a key can begin and end between two
-- frame hooks, so the duck and jump keys are also asked whether they were pressed. A tap
-- that short is rare, and at 40 fps and more it would cost a call a frame for nothing.
local SHORT_TAP_FRAME = 1 / 40

local jump = {
    gameHeld = false, -- from the game's jump event (the JumpAction hook)
    gamePresses = 0,
    lastPressFrame = nil, -- frame of the game's latest press event
    repeats = false, -- the game sends its press every frame while the key is held
    keysSeen = false, -- reading a jump key has worked at least once
}

local seen = {} -- key name -> true once it has been seen held, for the report
local pressedSeen = {} -- key name -> true once seen pressed (a notch or a quick tap), for the report
local ignored = {} -- duck and duck tap keys held at a take-over: they count once let go (input.ignoreHeld)
local refused = {} -- names the game doesn't know as keys: never read (input.refuse, from keys.validate)
local reading = nil -- what input.buttons read this frame (see input.lastPolls)
local ctrlNoted = false -- the line about UE4SS's Keybinds mod, the first time a Control key ducks

local function isWheel(name)
    return name:find("^MouseScroll") ~= nil
end

local function isPad(name)
    return name:find("^Gamepad_") ~= nil
end

--- A mouse-wheel "key" (MouseScrollUp, MouseScrollDown): read only as pressed, never down.
input.isWheel = isWheel
--- A gamepad button (Gamepad_...): read only as held (the engine samples it every frame).
input.isPad = isPad

local function anyHeld(pc, names)
    for i = 1, #names do
        local name = names[i]
        if not refused[name] and pc:IsInputKeyDown(ue.fkey(name)) == true then
            seen[name] = true
            return true
        end
    end
    return false
end
input.anyHeld = anyHeld

local wheel = {} -- key name -> whether it is a mouse-wheel "key"

-- Like anyHeld, but a mouse-wheel key also counts on the frame of a press that is
-- already over, which is what a wheel "press" looks like. (0.3's reading, for input.jumpHeld.)
local function anyPressed(pc, names)
    for i = 1, #names do
        local name = names[i]
        local key = ue.fkey(name)
        if wheel[name] == nil then
            wheel[name] = isWheel(name)
        end
        if not refused[name]
            and (pc:IsInputKeyDown(key) == true or (wheel[name] and pc:WasInputKeyJustPressed(key) == true)) then
            seen[name] = true
            return true
        end
    end
    return false
end

-- One key's state this frame, each asked of the game once a frame (r: this frame's reading).
local function keyDown(pc, name, r)
    local down = r.down[name]
    if down == nil then
        down = pc:IsInputKeyDown(ue.fkey(name)) == true
        r.down[name] = down
        if down then
            seen[name] = true
        end
    end
    return down
end

local function keyPressed(pc, name, r)
    local pressed = r.pressed[name]
    if pressed == nil then
        pressed = pc:WasInputKeyJustPressed(ue.fkey(name)) == true
        r.pressed[name] = pressed
        if pressed then
            pressedSeen[name] = true
        end
    end
    return pressed
end

-- The first key of the list that is held (nil: none), read in the list's order up to the
-- first one down (a wheel key is never down, so it isn't asked). With ignoring (the duck and
-- duck tap lists), a key held since a take-over doesn't count, and is free again once it
-- reads up.
local function heldIn(pc, names, r, ignoring)
    for i = 1, #names do
        local name = names[i]
        if not refused[name] and not isWheel(name) then
            if keyDown(pc, name, r) then
                if not (ignoring and ignored[name]) then
                    return name
                end
            elseif ignored[name] then
                ignored[name] = nil
            end
        end
    end
    return nil
end

-- Whether a key of the list was pressed and is up again at the hook: a wheel key's notch
-- (always asked), or with quickTaps a keyboard key's or mouse button's quick tap (a gamepad
-- button is sampled every frame, so it can't be).
local function notchIn(pc, names, r, quickTaps)
    for i = 1, #names do
        local name = names[i]
        if not refused[name] and (isWheel(name) or (quickTaps and not isPad(name) and not ignored[name])) then
            if keyPressed(pc, name, r) then
                return true
            end
        end
    end
    return false
end

-- The ignored keys that no list read this frame, so that each is seen let go.
local function readIgnored(pc, r)
    local names = {}
    for name in pairs(ignored) do
        if r.down[name] == nil then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if not keyDown(pc, name, r) then
            ignored[name] = nil
        end
    end
end

--- The keys seen held so far, for the report.
function input.keysSeen()
    local list = {}
    for name in pairs(seen) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

--- The keys seen pressed so far (wheel notches and quick taps), for the report.
function input.pressesSeen()
    local list = {}
    for name in pairs(pressedSeen) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

--- Movement axes from the keys, or else from the left stick: forward and right,
--- each from -1 to 1, and where they came from ("keys", "stick" or nil).
function input.moveAxes(pc, cfg)
    local forward, right = 0, 0
    if anyHeld(pc, cfg.ForwardKeys) then
        forward = forward + 1
    end
    if anyHeld(pc, cfg.BackKeys) then
        forward = forward - 1
    end
    if anyHeld(pc, cfg.RightKeys) then
        right = right + 1
    end
    if anyHeld(pc, cfg.LeftKeys) then
        right = right - 1
    end
    if forward ~= 0 or right ~= 0 then
        return forward, right, "keys"
    end
    if cfg.GamepadStick then
        local x = tonumber(pc:GetInputAnalogKeyState(ue.fkey("Gamepad_LeftX"))) or 0
        local y = tonumber(pc:GetInputAnalogKeyState(ue.fkey("Gamepad_LeftY"))) or 0
        local length = math.sqrt(x * x + y * y)
        local dead = cfg.StickDeadzone
        if length > dead then
            local amount = math.min(1, (length - dead) / (1 - dead))
            return y / length * amount, x / length * amount, "stick"
        end
    end
    return 0, 0, nil
end

--- Called from the hook on the game's jump input. Depending on how the game's
--- input is set up, it comes as true on press and false on release, or as true
--- on every frame while the key is held (with no release at all).
function input.onGameJump(pressed, frame)
    if pressed then
        local last = jump.lastPressFrame
        if last and frame - last == 1 and jump.gameHeld then
            jump.repeats = true
        end
        if not last or frame - last > 1 or not jump.gameHeld then
            jump.gamePresses = jump.gamePresses + 1
        end
        jump.lastPressFrame = frame
    end
    jump.gameHeld = pressed
end

local function gameHeld(frame)
    if jump.repeats then
        return jump.lastPressFrame ~= nil and frame - jump.lastPressFrame <= 1
    end
    return jump.gameHeld
end

--- Forgets the game's jump state, the keys ignored until let go and this frame's
--- readings, for example when the character changes.
function input.reset()
    jump.gameHeld = false
    jump.lastPressFrame = nil
    ignored = {}
    reading = nil
end

local function warnGameJump(cfg)
    if jump.gamePresses >= 3 then
        log.once("jump-keys", "The game saw jump presses, but none of the JumpKeys (%s) showed up as held, "
            .. "so the game's jump event is used instead. If holding jump doesn't keep you hopping, "
            .. "set JumpKeys in config.lua to your jump key.", table.concat(cfg.JumpKeys, ", "))
    end
end

--- Whether jump is held this frame. JumpInput "keys" reads JumpKeys, "game" uses
--- the game's jump event, and "auto" reads the keys once that has been seen to
--- work, and also accepts the game's event until then. (0.3's reading: a wheel
--- notch counts as held for its frame. input.buttons replaces it.)
function input.jumpHeld(pc, cfg, frame)
    local mode = cfg.JumpInput
    if mode == "game" then
        return gameHeld(frame)
    end
    local keys = anyPressed(pc, cfg.JumpKeys)
    if keys then
        jump.keysSeen = true
    end
    if mode == "keys" or jump.keysSeen then
        return keys
    end
    warnGameJump(cfg)
    return keys or gameHeld(frame)
end

-- The jump keys of one frame: held, and a notch (a wheel jump key, or a quick tap in a long
-- frame), asked only while no jump key is held; with JumpInput's modes as input.jumpHeld.
local function jumpButtons(pc, cfg, frame, r, quickTaps)
    local mode = cfg.JumpInput
    if mode == "game" then
        return gameHeld(frame), false
    end
    local held = heldIn(pc, cfg.JumpKeys, r, false) ~= nil
    local notch = not held and notchIn(pc, cfg.JumpKeys, r, quickTaps)
    if held or notch then
        jump.keysSeen = true
    end
    if mode == "keys" or jump.keysSeen then
        return held, notch
    end
    warnGameJump(cfg)
    return held or gameHeld(frame), notch
end

--- The duck, duck tap and jump buttons of one frame hook: { duckHeld, duckNotch, tapHeld,
--- jumpHeld, jumpNotch }. Each list is read in its order up to its first key down:
--- - a wheel key only with WasInputKeyJustPressed (a notch), a gamepad button only with
---   IsInputKeyDown (held), a keyboard key or mouse button with IsInputKeyDown (held), and
---   in a frame longer than 1/40 s with no key of its list down also WasInputKeyJustPressed
---   (a quick tap that was over before the hook: a notch). DuckTapKeys are only held:
---   OpenAG's +ducktap asks whether the key is down when it builds a command.
--- - The duck notch is asked only while no duck key is held, or one is held and wiped (the
---   2022 rule's wipe: a notch makes the held keys count again); the jump notch only while
---   no jump key is held.
--- - A duck or duck tap key held at a take-over (input.ignoreHeld) doesn't count until it
---   has read up; it is read every frame until then, owned or not.
--- - owned false (the keys are the game's this frame while the movement runs): the duck,
---   duck tap and jump buttons read as up, and nothing else is asked. With Ducking = false
---   the duck and duck tap parts are false and not asked.
--- frame: the mod's frame number; frameDt: the frame's length in s (not cut to 0.1);
--- wiped: the duck state's wipe (duck.lua's d.wiped).
function input.buttons(pc, cfg, frame, frameDt, owned, wiped)
    local r = { frame = frame, down = {}, pressed = {} }
    reading = r
    local k = { duckHeld = false, duckNotch = false, tapHeld = false, jumpHeld = false, jumpNotch = false }
    if owned ~= false then
        local quickTaps = type(frameDt) == "number" and frameDt > SHORT_TAP_FRAME
        if cfg.Ducking ~= false then
            local duckKey = heldIn(pc, cfg.DuckKeys, r, true)
            k.duckHeld = duckKey ~= nil
            if duckKey and not ctrlNoted and duckKey:find("Control$") then
                ctrlNoted = true
                log.first("keybinds-ctrl", "Ducking on %s: UE4SS's Keybinds mod, if it is on, starts a long dump on "
                    .. "Ctrl+J and Ctrl+H; don't press J or H while ducked, or turn that mod off in "
                    .. "ue4ss\\Mods\\mods.txt", duckKey)
            end
            if not k.duckHeld or wiped then
                k.duckNotch = notchIn(pc, cfg.DuckKeys, r, quickTaps and not k.duckHeld)
            end
            k.tapHeld = heldIn(pc, cfg.DuckTapKeys, r, true) ~= nil
        end
        k.jumpHeld, k.jumpNotch = jumpButtons(pc, cfg, frame, r, quickTaps)
    end
    if next(ignored) then
        readIgnored(pc, r)
    end
    return k
end

--- Ignores each duck and duck tap key that is down now until it reads up (jump keys are
--- never ignored): called when the mod takes the keys over (a take-over, and the frame the
--- keys are the mod's again after a dialogue, a cinematic or another view target). A key
--- held then was the game's, and the game has acted on its press. Returns the keys ignored.
function input.ignoreHeld(pc, cfg)
    local list = {}
    if cfg.Ducking == false then
        return list
    end
    for _, names in ipairs({ cfg.DuckKeys, cfg.DuckTapKeys }) do
        for _, name in ipairs(names) do
            if not ignored[name] and not refused[name] and not isWheel(name)
                and pc:IsInputKeyDown(ue.fkey(name)) == true then
                ignored[name] = true
                list[#list + 1] = name
            end
        end
    end
    return list
end

--- Whether the key is ignored now (held since a take-over: the game's until let go).
function input.isIgnored(name)
    return ignored[name] == true
end

--- The keys ignored now (held since a take-over), sorted, for the report.
function input.ignoredKeys()
    local list = {}
    for name in pairs(ignored) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

local NOTHING = {}

--- What input.buttons read on the given frame: key name -> true (down), false (up) or
--- "pressed" (up, and pressed during the frame: a notch or a quick tap); a key it didn't
--- read is absent. For another frame (or none read yet), an empty table, so that a frame
--- that didn't read the keys (root motion) takes none of them. Not to be changed.
function input.lastPolls(frame)
    local r = reading
    if not r or (frame ~= nil and r.frame ~= frame) then
        return NOTHING
    end
    if not r.merged then
        local merged = {}
        for name, down in pairs(r.down) do
            merged[name] = down
        end
        for name, pressed in pairs(r.pressed) do
            if pressed and not merged[name] then
                merged[name] = "pressed"
            elseif merged[name] == nil then
                merged[name] = false
            end
        end
        r.merged = merged
    end
    return r.merged
end

--- Leaves out the names in the set (name -> true) from every reading from now on: names
--- the game said aren't keys (keys.validate). A new set replaces the last.
function input.refuse(names)
    refused = {}
    for name, yes in pairs(names or {}) do
        if yes then
            refused[name] = true
        end
    end
end

function input.isRefused(name)
    return refused[name] == true
end

--- The jump input state, for the diagnostics report.
function input.status()
    return { gameHeld = jump.gameHeld, gamePresses = jump.gamePresses, keysSeen = jump.keysSeen,
        repeats = jump.repeats }
end

return input
