-- The fake game's extension points (tests/fake_game.lua, "Extensions"): where and when
-- the fake calls them, with what, and what it does with their answers. The other files
-- that stand in for parts of the game (the Enhanced Input subsystem, a capsule that
-- crouches) rest on them. Every game here leaves the extension files out
-- (noExtensionModules), so that these tests don't change when those files come.

local t = require("testlib")
local fake = require("fake_game")

local root = TEST_ROOT
local SETTLE_FRAMES = 190 -- a little over the 3 seconds the mod leaves a new character alone
local F6, F8 = 0x75, 0x77

local function game(extensions, options)
    options = options or {}
    options.noExtensionModules = true
    options.extensions = extensions
    return fake.newGame(options)
end

local function key(name)
    return { KeyName = fake.FName(name) }
end

local function same(a, b)
    return fake.addressOf(a) == fake.addressOf(b)
end

-- Runs fn with fake.EXTENSION_MODULES as names and package.preload holding the modules
-- given, and puts the fake's search back afterwards, whatever fn does.
local function withModules(names, preload, fn)
    local oldNames, oldFound = fake.EXTENSION_MODULES, fake.extensions
    fake.EXTENSION_MODULES, fake.extensions = names, nil
    for name, loader in pairs(preload) do
        package.preload[name] = loader
    end
    local ok, err = pcall(fn)
    for name in pairs(preload) do
        package.preload[name], package.loaded[name] = nil, nil
    end
    fake.EXTENSION_MODULES, fake.extensions = oldNames, oldFound
    assert(ok, err)
end

t.test("an extension is installed at the end of fake.newGame, then told of the first character, and of each later "
    .. "one before g.buildCharacter returns", function()
    local events = {}
    local function extension(tag)
        return {
            install = function(g)
                events[#events + 1] = string.format("%s install: character %s, controller %s, frame %s, press %s",
                    tag, tostring(g.c ~= nil), tostring(g.pc:IsValid()), type(g.frame), type(g.press))
            end,
            character = function(g, c)
                events[#events + 1] = string.format("%s character: in use %s", tag, tostring(c == g.c))
            end,
            ownField = 42, -- an extension's own fields are left alone
        }
    end
    local a, b = extension("A"), extension("B")
    local g = game({ a, b })
    t.eq(table.concat(events, "; "), "A install: character true, controller true, frame function, press function; "
        .. "B install: character true, controller true, frame function, press function; "
        .. "A character: in use true; B character: in use true")
    t.eq(#g.extensions, 2, "the game's extensions")
    t.truthy(g.extensions[1] == a and g.extensions[2] == b, "in the order given")
    events = {}
    local c = g.buildCharacter()
    t.eq(table.concat(events, "; "), "A character: in use false; B character: in use false",
        "a later character, before the test uses it")
    g.useCharacter(c)
    events = {}
    g.frames(3)
    t.eq(#events, 0, "nothing more")
end)

t.test("the modules of fake.EXTENSION_MODULES that require can find are each game's first extensions, loaded once "
    .. "in a run; options.noExtensionModules leaves them out", function()
    local loads = 0
    local module = {
        install = function(g)
            g.installedBy = (g.installedBy or "") .. "module "
        end,
        helper = function() end, -- not a point: the module's own
    }
    local own = {
        install = function(g)
            g.installedBy = (g.installedBy or "") .. "own "
        end,
    }
    withModules({ "fake_h0_absent", "fake_h0_present" }, {
        fake_h0_present = function()
            loads = loads + 1
            return module
        end,
    }, function()
        local g = fake.newGame({ extensions = { own } })
        t.eq(g.installedBy, "module own ", "the module's first, then the game's own")
        t.eq(#fake.extensions, 1, "the module there, not the one that isn't")
        t.truthy(fake.extensions[1] == module and g.extensions[1] == module, "the module's table")
        local again = fake.newGame()
        t.eq(again.installedBy, "module ", "in every game")
        t.eq(loads, 1, "loaded once in a run")
        local without = fake.newGame({ noExtensionModules = true, extensions = { own } })
        t.eq(without.installedBy, "own ", "noExtensionModules")
        t.eq(#without.extensions, 1)
    end)
end)

t.test("an extension module that is there but fails to load fails every game, and a point that isn't a function "
    .. "is refused", function()
    withModules({ "fake_h0_broken" }, {
        fake_h0_broken = function()
            error("broken on purpose")
        end,
    }, function()
        for attempt = 1, 2 do
            local ok, err = pcall(fake.newGame)
            t.falsy(ok, "game " .. attempt .. " made with a broken module")
            t.truthy(tostring(err):find("broken on purpose", 1, true), tostring(err))
        end
    end)
    withModules({ "fake_h0_wrong" }, {
        fake_h0_wrong = function()
            return { beforeMove = 3 }
        end,
    }, function()
        local ok, err = pcall(fake.newGame)
        t.falsy(ok, "a number for a point")
        t.truthy(tostring(err):find("fake_h0_wrong: its beforeMove is a number, not a function", 1, true),
            tostring(err))
    end)
    local ok, err = pcall(game, { { input = "no" } })
    t.falsy(ok)
    t.truthy(tostring(err):find("options.extensions[1]: its input is a string, not a function", 1, true),
        tostring(err))
    ok, err = pcall(game, { "not a table" })
    t.falsy(ok)
    t.truthy(tostring(err):find("options.extensions[1] is not a table", 1, true), tostring(err))
end)

t.test("construct makes what StaticConstructObject's fake can't, after the fake's own widgets: the first extension "
    .. "that gives an object; false makes it fail", function()
    local asked = {}
    local made
    local g = game({
        {
            construct = function(g, className, outer)
                asked[#asked + 1] = "first " .. className .. (same(outer, g.gameInstance) and " (outer)" or "")
                if className == "InputAction" then
                    made = fake.object({ className = "InputAction" })
                    return made
                end
                return nil
            end,
        },
        {
            construct = function(_, className)
                asked[#asked + 1] = "second " .. className
                if className == "InputMappingContext" then
                    return false
                end
            end,
        },
    })
    local action = StaticConstructObject(fake.class("InputAction"), g.gameInstance)
    t.truthy(action == made, "the first extension's object")
    t.eq(table.concat(asked, ", "), "first InputAction (outer)", "the second isn't asked then")
    asked = {}
    local ok, err = pcall(StaticConstructObject, fake.class("InputMappingContext"), g.gameInstance)
    t.falsy(ok, "false: StaticConstructObject fails")
    t.truthy(tostring(err):find("StaticConstructObject couldn't make a InputMappingContext", 1, true), tostring(err))
    t.eq(table.concat(asked, ", "), "first InputMappingContext (outer), second InputMappingContext")
    t.eq(g.extensionError, nil, "a failure the extension asked for isn't an extension's error")
    asked = {}
    ok, err = pcall(StaticConstructObject, fake.class("Nothing"), g.gameInstance)
    t.falsy(ok)
    t.truthy(tostring(err):find("the fake can't make a Nothing", 1, true), tostring(err))
    t.eq(#asked, 2, "both asked")
    asked = {}
    local widget = StaticConstructObject(fake.class("UserWidget"), g.gameInstance)
    t.truthy(widget:IsValid(), "the fake's own widget")
    t.eq(#asked, 0, "not asked for the fake's own classes")
    ok = pcall(StaticConstructObject, fake.class("InputAction"), g.gameInstance, "FixedName")
    t.falsy(ok, "the fake's own checks first")
    t.eq(#asked, 0, "not asked when the fake's checks refuse")
end)

t.test("an object made with spec.call can be called as UE4SS's UFunction objects are, with the context first; "
    .. "no other object can", function()
    local g = game({})
    local got
    local path = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:AddMappingContext"
    local fn = fake.object({ className = "Function", path = path,
        call = fake.ufunction("AddMappingContext", 3, function(self, context, ctx, priority)
            got = { self = self, context = context, ctx = ctx, priority = priority }
            return true
        end) })
    g.statics[path] = fn
    local found = StaticFindObject(path)
    t.truthy(found == fn, "found as the game function")
    local calls = fake.counts.calls
    t.eq(found(g.pawn, g.cmc, 5), true, "called")
    t.truthy(got.self == fn and got.context == g.pawn and got.ctx == g.cmc and got.priority == 5, "with what")
    t.eq(fake.counts.calls - calls, 1, "a call of the mod's")
    local ok, err = pcall(fn, g.pawn, g.cmc)
    t.falsy(ok, "a parameter short")
    t.truthy(tostring(err):find("expected 3 parameters, received 2", 1, true), tostring(err))
    t.truthy(fake.copy(fn)(g.pawn, g.cmc, 6) and got.priority == 6, "a copy can be called too")
    ok, err = pcall(g.cmc, 1)
    t.falsy(ok, "an object without spec.call")
    t.truthy(tostring(err):find("attempt to call a userdata value", 1, true), tostring(err))
    local plain = fake.object({ className = "Function", call = function(_, a, b)
        return a + b
    end })
    t.eq(plain(2, 3), 5, "any function, without fake.ufunction's checks")
    for _, obj in ipairs({ fn, plain }) do
        fake.destroy(obj)
        ok, err = pcall(obj, g.pawn, g.cmc, 5)
        t.falsy(ok, "a destroyed one")
        t.truthy(tostring(err):find("used a destroyed object", 1, true), tostring(err))
    end
end)

t.test("poll changes what the mod's polls of keys give, after g.keys, g.justPressed and g.analog; the polls are "
    .. "counted once", function()
    local asked = {}
    local g = game({
        {
            poll = function(_, how, name, value)
                asked[#asked + 1] = string.format("%s %s %s", how, name, tostring(value))
                if how == "down" and name == "LeftControl" then
                    return not value
                elseif how == "analog" then
                    return value * 2
                end
                return value
            end,
        },
        {
            poll = function(_, how, name, value)
                asked[#asked + 1] = string.format("then %s %s %s", how, name, tostring(value))
                return value
            end,
        },
    })
    g.keys.SpaceBar = true
    g.justPressed.MouseScrollDown = true
    g.analog.Gamepad_LeftY = 0.25
    local calls = fake.counts.calls
    t.eq(g.pc:IsInputKeyDown(key("LeftControl")), true, "turned round by the first")
    t.eq(g.pc:IsInputKeyDown(key("SpaceBar")), true)
    t.eq(g.pc:WasInputKeyJustPressed(key("MouseScrollDown")), true)
    t.eq(g.pc:WasInputKeyJustPressed(key("MouseScrollUp")), false)
    t.eq(g.pc:GetInputAnalogKeyState(key("Gamepad_LeftY")), 0.5)
    t.eq(fake.counts.calls - calls, 5, "one call each")
    t.eq(table.concat(asked, "; "), "down LeftControl false; then down LeftControl true; down SpaceBar true; "
        .. "then down SpaceBar true; pressed MouseScrollDown true; then pressed MouseScrollDown true; "
        .. "pressed MouseScrollUp false; then pressed MouseScrollUp false; analog Gamepad_LeftY 0.25; "
        .. "then analog Gamepad_LeftY 0.5")
    asked = {}
    local broken = game({ { poll = function(_, _, _, value)
        asked[#asked + 1] = "asked"
        return not value
    end } }, { keyPollingBroken = true })
    t.eq(broken.pc:IsInputKeyDown(key("LeftControl")), false, "keyPollingBroken wins")
    t.eq(broken.pc:WasInputKeyJustPressed(key("LeftControl")), false)
    t.eq(#asked, 0)
end)

t.test("input comes first in every frame, paused ones too; gameKey decides what the game's own movement and jump "
    .. "see, not what the mod's polls read", function()
    local events = {}
    local hide = { W = true, SpaceBar = true }
    local g = game({
        {
            input = function(g, dt, paused)
                events[#events + 1] = string.format("input %.4f %s %.4f", dt, tostring(paused), g.worldTime)
            end,
            gameKey = function(_, name, down)
                events[#events + 1] = string.format("gameKey %s %s", name, tostring(down))
                return down and not hide[name]
            end,
        },
    })
    g.hooks[g.jumpPath] = function(_, pressed)
        events[#events + 1] = "jump hook " .. tostring(pressed:get())
    end
    local spaceRead
    g.hooks[g.tickPath] = function(pc)
        events[#events + 1] = "tick"
        spaceRead = pc:get():IsInputKeyDown(key("SpaceBar"))
    end
    g.keys.W, g.keys.D, g.keys.SpaceBar = true, true, true
    g.frame(1 / 50)
    t.eq(table.concat(events, "; "), "input 0.0200 false 0.0200; gameKey W true; gameKey S false; gameKey D true; "
        .. "gameKey A false; gameKey SpaceBar true; tick", "the frame's input phase, in order")
    t.eq(spaceRead, true, "the mod's poll still reads the key")
    t.eq(g.gameJumps, 0, "the game didn't jump")
    t.eq(g.lastAcceleration.X, 0, "W hidden from the game's movement")
    t.truthy(g.lastAcceleration.Y > 0, "D not")
    hide = {}
    events = {}
    g.keys.SpaceBar = false
    g.frame(1 / 50)
    g.keys.SpaceBar = true
    g.frame(1 / 50)
    t.contains(events, "jump hook true")
    t.eq(g.gameJumps, 1, "the game jumps when its input sees the key")
    t.truthy(g.lastAcceleration.X > 0, "W reaches the game's movement")
    events = {}
    g.paused = true
    g.frame(1 / 50)
    t.eq(events[1], string.format("input 0.0200 true %.4f", g.worldTime), "paused: still the input phase")
    t.truthy(#events >= 5, "the keys read in a paused frame too")
    -- The keys of the game's jump that the fake reads.
    local pad = game({})
    pad.keys.Gamepad_FaceButton_Bottom = true
    pad.frame()
    t.eq(pad.gameJumps, 0, "not one of the game's jump keys")
    pad.gameJumpKeys = { "SpaceBar", "Gamepad_FaceButton_Bottom" }
    pad.keys.Gamepad_FaceButton_Bottom = false
    pad.frame()
    pad.keys.Gamepad_FaceButton_Bottom = true
    pad.frame()
    t.eq(pad.gameJumps, 1, "once it is")
    -- With input that comes after the controller's tick, the movement keys are read twice.
    local reads = 0
    local late = game({ { gameKey = function(_, name, down)
        reads = reads + (name == "W" and 1 or 0)
        return down
    end } }, { lateInput = true })
    late.frame()
    t.eq(reads, 2, "each time the fake reads them")
    -- A gameKey that gives no boolean
    local wrong = game({ { gameKey = function() end } })
    local ok, err = pcall(wrong.frame)
    t.falsy(ok)
    t.truthy(tostring(err):find("the extension point gameKey gave a nil, not a boolean", 1, true), tostring(err))
end)

t.test("gameJump can keep a press of the game's jump from calling Unreal's Jump(), after the jump hook; every "
    .. "extension is asked", function()
    local events = {}
    local answers = { false, true }
    local extensions = {}
    for i = 1, 2 do
        extensions[i] = { gameJump = function(g)
            events[#events + 1] = string.format("gameJump %d (pressed %s)", i, tostring(g.pressedJump == true))
            return answers[i]
        end }
    end
    local g = game(extensions)
    g.hooks[g.jumpPath] = function(_, pressed)
        events[#events + 1] = "jump hook " .. tostring(pressed:get())
    end
    g.keys.SpaceBar = true
    g.frame()
    t.eq(table.concat(events, "; "), "jump hook true; gameJump 1 (pressed false); gameJump 2 (pressed false)")
    t.eq(g.gameJumps, 0, "no jump")
    t.eq(g.mode(), 1, "still walking")
    events = {}
    g.frames(3)
    g.keys.SpaceBar = false
    g.frame()
    t.eq(table.concat(events, "; "), "jump hook false", "not asked while held or at the release")
    answers = { true, true }
    events = {}
    g.keys.SpaceBar = true
    g.frame()
    t.eq(g.gameJumps, 1, "both say yes: Jump()")
    t.eq(g.mode(), 3)
    -- A game whose jump event comes every frame while the key is held
    answers = { false, true }
    local every = game(extensions, { jumpEventEveryFrame = true })
    every.keys.SpaceBar = true
    every.frames(5)
    t.eq(every.gameJumps, 0, "every frame's press kept from calling Jump()")
end)

t.test("beforeMove and afterMove come around each move, after the game's jump; the move takes the movement mode "
    .. "and velocity as beforeMove leaves them; with root motion back to back; not in mode None or paused",
    function()
    local events = {}
    local change
    local g = game({
        {
            beforeMove = function(g, dt, rootMotion)
                local p = fake.props(g.cmc)
                events[#events + 1] = string.format("before %.4f %s mode %d vz %.1f z %.2f", dt, tostring(rootMotion),
                    p.MovementMode, p.Velocity.Z, g.position.Z)
                if change then
                    change(p)
                    change = nil
                end
            end,
            afterMove = function(g, dt, rootMotion)
                local p = fake.props(g.cmc)
                events[#events + 1] = string.format("after %.4f %s mode %d z %.2f settings %d", dt,
                    tostring(rootMotion), p.MovementMode, g.position.Z, p.bRequestMovementSettingsChange)
            end,
        },
    })
    g.afterMove = function()
        events[#events + 1] = "the test's afterMove"
    end
    g.keys.SpaceBar = true
    fake.props(g.cmc).bRequestMovementSettingsChange = 1
    g.frame(1 / 50)
    t.eq(table.concat(events, "; "), string.format("before 0.0200 false mode 3 vz 450.0 z %.2f; "
        .. "after 0.0200 false mode 3 z %.2f settings 1; the test's afterMove", fake.FLOOR_DIST,
        fake.FLOOR_DIST + (450 + 450 - 980 / 50) / 2 / 50), "after the jump, around the move, before ALS's write")
    t.eq(fake.props(g.cmc).bRequestMovementSettingsChange, 0, "ALS's write after afterMove")
    t.eq(fake.props(g.cmc).MaxWalkSpeed, 375)
    -- The move goes on from what beforeMove left.
    local h = game({ { beforeMove = function(other)
        if change then
            change(fake.props(other.cmc))
            change = nil
        end
    end } })
    change = function(p)
        p.MovementMode = 3
        fake.set(h.cmc, "Velocity", fake.vector(120, 0, 0))
        t.truthy(p.Velocity.X == 120, "a new velocity table")
    end
    h.frame(1 / 60)
    t.near(h.position.X, 2, 1e-9, "moved with the velocity beforeMove left")
    t.near(fake.props(h.cmc).Velocity.Z, -980 / 60, 1e-9, "falling, as beforeMove left it")
    -- Root motion, mode None, a paused frame
    events = {}
    g.afterMove = nil
    g.rootMotion = true
    local z = g.position.Z
    g.frame(1 / 50)
    t.eq(table.concat(events, "; "), string.format("before 0.0200 true mode 3 vz %.1f z %.2f; "
        .. "after 0.0200 true mode 3 z %.2f settings 0", fake.props(g.cmc).Velocity.Z, z, z), "root motion")
    g.rootMotion = false
    events = {}
    g.paused = true
    g.frames(2)
    g.paused = false
    fake.props(g.cmc).MovementMode = 0
    g.frames(2)
    t.eq(#events, 0, "not while paused or in mode None")
end)

t.test("moveShare gives the share of the frame's horizontal move that happens, after g.moveShare", function()
    local seen = {}
    local g = game({
        { moveShare = function(_, dt, share)
            seen[#seen + 1] = string.format("%.4f %.2f", dt, share)
            return share * 0.5
        end },
    })
    local p = fake.props(g.cmc)
    p.MovementMode = 3
    p.Velocity.X = 600
    g.moveShare = 0.5
    g.frame(1 / 60)
    t.eq(table.concat(seen, ", "), "0.0167 0.50", "g.moveShare's share")
    t.near(g.position.X, 600 / 60 * 0.25, 1e-9, "a quarter of the move")
    t.near(p.Velocity.X, 150, 1e-9, "and of the velocity, from the distance moved")
    g.moveShare = nil
    seen = {}
    g.frame(1 / 60)
    t.eq(table.concat(seen, ", "), "0.0167 1.00", "1 without g.moveShare")
    local wrong = game({ { moveShare = function() return "all" end } })
    local ok, err = pcall(wrong.frame)
    t.falsy(ok)
    t.truthy(tostring(err):find("the extension point moveShare gave a string, not a number", 1, true), tostring(err))
end)

t.test("modeChanged follows every movement mode change the fake makes: SetMovementMode, the game's jump, a landing, "
    .. "walking off a ledge, g.changeMode", function()
    local changes = {}
    local g
    g = game({ { modeChanged = function(_, cmc, pawn, was, mode)
        changes[#changes + 1] = string.format("%d>%d%s", was, mode,
            (same(cmc, g.cmc) and same(pawn, g.pawn)) and "" or " (another character)")
    end } })
    g.cmc:SetMovementMode(3, 0)
    g.cmc:SetMovementMode(3, 0) -- one that keeps the mode
    g.frames(30) -- falls the 2 cm to the ground
    t.eq(table.concat(changes, ", "), "1>3, 3>3, 3>1", "the mod's, and the landing")
    changes = {}
    g.keys.SpaceBar = true
    g.frame()
    g.keys.SpaceBar = false
    g.frames(60)
    t.eq(table.concat(changes, ", "), "1>3, 3>1", "the game's jump and its landing")
    changes = {}
    local calls = fake.counts.calls
    g.changeMode(g.cmc, 2, g.pawn)
    g.changeMode(g.cmc, 1, g.pawn)
    t.eq(table.concat(changes, ", "), "1>2, 2>1", "g.changeMode")
    t.eq(fake.counts.calls, calls, "g.changeMode isn't a call of the mod's")
    t.eq(g.mode(), 1)
    changes = {}
    local edge = g.position.X + 20
    g.terrain = function(x)
        if x < edge then
            return 0, 0, 0, 1
        end
        return -1000, 0, 0, 1
    end
    fake.props(g.cmc).Velocity.X = 600
    fake.props(g.cmc).BrakingFrictionFactor = 0 -- (ALS raised it at the landing)
    g.frames(10)
    t.eq(changes[1], "1>3", "walking off the ledge")
    local other = g.buildCharacter()
    changes = {}
    other.cmc:SetMovementMode(3, 0)
    t.eq(table.concat(changes, ", "), "1>3 (another character)", "with the character whose mode changed")
end)

t.test("canWalkOff lets the walk leave a ledge or keeps the character on it (the move taken back but for the "
    .. "platform's part, the velocity 0), every extension asked", function()
    local asked, answer = {}, false
    local g = game({
        { canWalkOff = function()
            asked[#asked + 1] = "A"
            return true
        end },
        { canWalkOff = function()
            asked[#asked + 1] = "B"
            return answer
        end },
    })
    local edge = g.position.X + 20
    g.terrain = function(x)
        if x < edge then
            return 0, 0, 0, 1
        end
        return -1000, 0, 0, 1
    end
    local p = fake.props(g.cmc)
    g.baseVelocity = { X = 0, Y = 60, Z = 0 } -- on a moving platform, which carries the character sideways
    p.Velocity.X = 600
    local x, y, z
    for _ = 1, 10 do
        x, y, z = g.position.X, g.position.Y, g.position.Z
        g.frame(1 / 60)
        if #asked > 0 then
            break
        end
    end
    t.eq(table.concat(asked, " "), "A B", "asked once the walk found no floor within reach, every extension")
    t.eq(g.mode(), 1, "still walking: the ledge kept it")
    t.near(g.position.X, x, 1e-9, "the move taken back")
    t.near(g.position.Y, y + 1, 1e-9, "but the platform still carried it")
    t.near(g.position.Z, z, 1e-9)
    t.eq(p.Velocity.X, 0, "no velocity: none worked out from a move of nothing")
    t.truthy(g.position.X < edge, "on the ledge")
    asked, answer = {}, true
    p.Velocity.X = 600
    g.frames(10, 1 / 60, function()
        if g.mode() == 3 then
            g.baseVelocity = nil
        end
    end)
    t.eq(asked[1], "A", "asked again")
    t.eq(g.mode(), 3, "allowed: off the ledge")
    t.truthy(g.position.X > edge, "past the edge")
    local wrong = game({ { canWalkOff = function() end } })
    wrong.terrain = g.terrain
    fake.props(wrong.cmc).Velocity.X = 3000
    local ok, err = pcall(wrong.frames, 10)
    t.falsy(ok)
    t.truthy(tostring(err):find("the extension point canWalkOff gave a nil, not a boolean", 1, true), tostring(err))
end)

t.test("heightOffset raises the actor's location, its eyes and the cameras on it above g.position, the extensions' "
    .. "numbers added up", function()
    local told = {}
    local g = game({
        { heightOffset = function(_, c)
            told[#told + 1] = c
            return -45
        end },
        { heightOffset = function()
            return 1.5
        end },
    })
    local z = g.position.Z
    local at = g.pawn:K2_GetActorLocation()
    t.near(at.Z, z - 43.5, 1e-9, "the actor's location")
    t.eq(at.X, g.position.X)
    t.eq(g.position.Z, z, "g.position stays the capsule's lowest point")
    t.truthy(told[#told] == g.c, "asked for the character whose location it is")
    t.near(g.eyes().Z, z - 43.5 + 64, 1e-9, "the eyes")
    t.near(g.c.dialogueCamera:K2_GetComponentLocation().Z, z - 43.5, 1e-9, "a camera on the capsule")
    t.near(g.c.cineCamera:K2_GetComponentLocation().Z, z - 43.5 + 150, 1e-9, "a camera on the spring arm")
    t.truthy(g.actorLocation() ~= g.actorLocation(), "a new table each time")
    g.cameraStyle = "FirstPerson"
    g.frame()
    t.near(g.cameraLocation.Z, z - 43.5 + 64, 1e-9, "the engine's first-person view, at the eyes")
    local other = g.buildCharacter()
    other.pawn:K2_GetActorLocation()
    t.truthy(told[#told] == other, "another character's location is asked for that character")
    local wrong = game({ { heightOffset = function() end } })
    local ok, err = pcall(wrong.pawn.K2_GetActorLocation, wrong.pawn)
    t.falsy(ok)
    t.truthy(tostring(err):find("the extension point heightOffset gave a nil, not a number", 1, true),
        tostring(err))
end)

t.test("an error in an extension point that the mod's pcall catches still fails the frame", function()
    local g = game({ { poll = function()
        error("poll broken on purpose")
    end } })
    local ok = pcall(g.pc.IsInputKeyDown, g.pc, key("SpaceBar")) -- as the mod's safe calls do
    t.falsy(ok, "the poll raised")
    t.truthy(g.extensionError and g.extensionError:find("poll broken on purpose", 1, true), "kept")
    local time = g.time
    local okFrame, err = pcall(g.frame)
    t.falsy(okFrame, "the frame raises it")
    t.truthy(tostring(err):find("an extension point failed: ", 1, true)
        and tostring(err):find("poll broken on purpose", 1, true), tostring(err))
    t.truthy(g.time > time, "at the end of the frame")
    t.falsy(pcall(g.frame), "and at the end of every frame after it")
end)

-- A game with the mod, played through hops, strafing, a slope, a pause, root motion, first
-- person and the report: each frame's state and the log, as lines.
local function play(extensions)
    local g = game(extensions)
    fake.useConfig(nil)
    fake.loadMod(root)
    g.loadSave()
    local lines = {}
    local frame = 0
    local function step(dt)
        g.frame(dt)
        frame = frame + 1
        local p, pos, cam, eyes = fake.props(g.cmc), g.position, g.cameraLocation, g.eyes()
        local at = g.actorLocation()
        lines[#lines + 1] = string.format("%d %.17g %.17g %.17g | %.17g %.17g %.17g | %d | %.17g %.17g %.17g | "
            .. "%.17g %.17g | %.17g | %s | %d %d %d %d %d | %d", frame, pos.X, pos.Y, pos.Z, p.Velocity.X,
            p.Velocity.Y, p.Velocity.Z, p.MovementMode, cam.X, cam.Y, cam.Z, eyes.Z, at.Z, g.actorYaw or 0,
            g.style(), fake.counts.calls, fake.counts.reads, fake.counts.writes, fake.counts.fields,
            fake.counts.fullNames, #g.log)
    end
    local function steps(count, dt, each)
        for i = 1, count do
            if each then
                each(i)
            end
            step(dt)
        end
    end
    steps(SETTLE_FRAMES, 1 / 60)
    g.keys.W = true
    steps(60, 1 / 60)
    g.keys.SpaceBar, g.keys.D = true, true
    steps(120, 1 / 80, function()
        g.rotation.Yaw = g.rotation.Yaw + 2
    end)
    g.keys.D, g.keys.A = false, true
    steps(60, 1 / 144, function(i)
        g.rotation.Yaw = g.rotation.Yaw - 2
        if i % 20 == 0 then
            step(0.05)
        end
    end)
    g.keys.SpaceBar, g.keys.A = false, false
    g.paused = true
    steps(10, 1 / 60)
    g.paused = false
    steps(10, 1 / 60)
    g.rootMotion = true
    steps(10, 1 / 60)
    g.rootMotion = false
    g.press(F6)
    local x = g.position.X
    g.terrain = function(px)
        if px < x + 200 then
            return 0, 0, 0, 1
        end
        local s, c = math.sin(math.rad(30)), math.cos(math.rad(30))
        return (px - x - 200) * s / c, -s, 0, c
    end
    g.rotation.Yaw = 0
    fake.props(g.cmc).Velocity.X, fake.props(g.cmc).Velocity.Y = 2000, 0
    g.keys.W, g.keys.SpaceBar = true, true
    steps(120, 1 / 80)
    g.press(F6)
    g.press(F8)
    steps(30, 1 / 60)
    for _, line in ipairs(g.log) do
        -- (The CPU time changes from run to run; the objects' names carry their addresses,
        -- which the games before this one moved on.)
        line = line:gsub("the mod took [%d%.]+ ms per frame", "the mod took N ms per frame")
        lines[#lines + 1] = (line:gsub("_%x%x%x%x%x+", "_ADDRESS"))
    end
    return lines
end

t.test("extensions that change nothing change nothing: a game with one at every point plays as a game without",
    function()
    local calls = {}
    local function seen(name)
        calls[name] = (calls[name] or 0) + 1
    end
    local idle = {
        install = function() seen("install") end,
        character = function() seen("character") end,
        construct = function() seen("construct") end,
        input = function() seen("input") end,
        gameKey = function(_, _, down)
            seen("gameKey")
            return down
        end,
        gameJump = function()
            seen("gameJump")
            return true
        end,
        poll = function(_, _, _, value)
            seen("poll")
            return value
        end,
        beforeMove = function() seen("beforeMove") end,
        moveShare = function(_, _, share)
            seen("moveShare")
            return share
        end,
        afterMove = function() seen("afterMove") end,
        modeChanged = function() seen("modeChanged") end,
        heightOffset = function()
            seen("heightOffset")
            return 0
        end,
        canWalkOff = function()
            seen("canWalkOff")
            return true
        end,
    }
    local without = play({})
    local with = play({ idle })
    t.eq(#with, #without, "as many frames and log lines")
    for i = 1, #without do
        if with[i] ~= without[i] then
            error(string.format("line %d differs:\n  without: %s\n  with:    %s", i, without[i], with[i]))
        end
    end
    -- (The mod makes only widgets, which the fake makes itself, and the play walks off no
    -- ledge: "canWalkOff lets the walk leave a ledge ..." has those two.)
    local notReached = { construct = true, canWalkOff = true }
    for _, name in ipairs(fake.EXTENSION_POINTS) do
        if not notReached[name] then
            t.truthy((calls[name] or 0) > 0, name .. " was called")
        end
    end
    t.eq(calls.install, 1)
    t.truthy(#without > SETTLE_FRAMES + 400, "the whole play")
end)
