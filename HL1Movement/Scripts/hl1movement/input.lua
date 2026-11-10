-- The player's input: movement keys, the left stick and the jump button.
--
-- Keys are read from the player controller every frame with IsInputKeyDown, which
-- is the only way UE4SS's Lua can tell that a key is being held. The game's own
-- jump event is watched as well, in case reading the keys doesn't work.

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")

local input = {}

local jump = {
    gameHeld = false, -- from the game's jump event (the JumpAction hook)
    gamePresses = 0,
    lastPressFrame = nil, -- frame of the game's latest press event
    repeats = false, -- the game sends its press every frame while the key is held
    keysSeen = false, -- reading a jump key has worked at least once
}

local function anyHeld(pc, names)
    for i = 1, #names do
        if pc:IsInputKeyDown(ue.fkey(names[i])) == true then
            return true
        end
    end
    return false
end
input.anyHeld = anyHeld

-- Like anyHeld, but also true on the frame of a press that is already over,
-- which is what a mouse-wheel "press" looks like.
local function anyPressed(pc, names)
    for i = 1, #names do
        local key = ue.fkey(names[i])
        if pc:IsInputKeyDown(key) == true or pc:WasInputKeyJustPressed(key) == true then
            return true
        end
    end
    return false
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

--- Forgets the game's jump state, for example when the character changes.
function input.reset()
    jump.gameHeld = false
    jump.lastPressFrame = nil
end

--- Whether jump is held this frame. JumpInput "keys" reads JumpKeys, "game" uses
--- the game's jump event, and "auto" reads the keys once that has been seen to
--- work, and also accepts the game's event until then.
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
    if jump.gamePresses >= 3 then
        log.once("jump-keys", "The game saw jump presses, but none of the JumpKeys (%s) showed up as held, "
            .. "so the game's jump event is used instead. If holding jump doesn't keep you hopping, "
            .. "set JumpKeys in config.lua to your jump key.", table.concat(cfg.JumpKeys, ", "))
    end
    return keys or gameHeld(frame)
end

--- The jump input state, for the diagnostics report.
function input.status()
    return { gameHeld = jump.gameHeld, gamePresses = jump.gamePresses, keysSeen = jump.keysSeen,
        repeats = jump.repeats }
end

return input
