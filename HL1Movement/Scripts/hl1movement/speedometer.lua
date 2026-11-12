-- The speedometer: the horizontal speed in Half-Life units per second, as one
-- number on the screen, like Bunnymod XT's bxt_hud_speedometer.
--
-- Shipping Unreal draws nothing for PrintString or on-screen debug messages, and
-- the HUD's ReceiveDrawHUD only runs a Blueprint: E33's HUD is the engine's plain
-- one, which has none, so a hook on it never fires. So the number is a UMG widget
-- made from Lua: a UserWidget whose widget tree holds a canvas with one text on
-- it, added to the viewport. While it is on the screen, Slate keeps it from being
-- garbage collected.
--
-- The text is CommonUI's CommonNumericTextBlock where the game has it: the number
-- is handed over as a float and the engine makes the text itself. A plain
-- TextBlock needs an FText made in Lua for every change, and UE4SS never frees a
-- call's parameters, so each change leaves a little memory behind; that fallback
-- is updated less often.
--
-- The widget is made once and then only shown and hidden. It is removed when the
-- mod switches off, the settings are reloaded or the game changes area, forgotten
-- without touching it when the level changes (the engine removes a widget with
-- its world), and noted in the journal, so a UE4SS mods restart takes it away.
-- Something in the game may also take it off the screen. The garbage collector
-- then frees it, and in UE4SS a freed object's Lua wrapper reads as valid again
-- once another object takes its address. So IsValid is checked every frame, full
-- names before each call (the widget's and the text's before each number and each
-- show or hide), and every 0.5 s also IsInViewport. A widget the game took away is
-- made again, unless the game takes each new one away soon after, several times in
-- a row (see MAX_REMAKES).

local ue = require("hl1movement.ue")
local log = require("hl1movement.log")
local journal = require("hl1movement.journal")

local speedometer = {}

local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local USER_WIDGET = "/Script/UMG.UserWidget"
local WIDGET_TREE = "/Script/UMG.WidgetTree"
local CANVAS_PANEL = "/Script/UMG.CanvasPanel"
local NUMERIC_TEXT = "/Script/CommonUI.CommonNumericTextBlock"
local TEXT_BLOCK = "/Script/UMG.TextBlock"

local COLLAPSED, HIT_TEST_INVISIBLE = 1, 3 -- ESlateVisibility
local JUSTIFY_CENTER = 1 -- ETextJustify
local Z_ORDER = 10 -- above the game's own viewport widgets; the speedometer is hidden in menus anyway
local NUMBER_INTERVAL = 0.05 -- s: a CommonNumericTextBlock is updated at most 20 times a second
local TEXT_INTERVAL = 0.1 -- s: a TextBlock at most 10 times (each change leaves its FText behind)
local CHECK_INTERVAL = 0.5 -- s between checks that the widget is still on the screen
local MAX_SHOWN = 99999
local MAX_LOST_LINES = 3
-- A widget the game took away is made again. Only when the game takes each new one
-- away within REMAKE_WINDOW seconds of its making, MAX_REMAKES times in a row, does the
-- mod stop until the next retry (see speedometer.retry): a game that clears the
-- screen now and then, as a battle or a menu opens, doesn't end it.
local MAX_REMAKES = 5
local REMAKE_WINDOW = 10

local st = {
    widget = nil,
    fullName = nil,
    text = nil,
    textName = nil, -- the text's full name
    numeric = false, -- the text is a CommonNumericTextBlock
    visible = false,
    shown = nil, -- the number on the screen
    nextUpdate = 0,
    nextCheck = 0,
    failed = nil, -- why it can't be shown; not tried again until speedometer.retry()
    made = 0,
    how = nil, -- how the last one was made
    lost = 0, -- times the game took it off the screen
    remakes = 0, -- of those, in a row, each within REMAKE_WINDOW of the widget's making
    now = 0, -- the mod's clock at the last update
    madeAt = 0, -- when the widget was made
}

-- UMG colours are linear; the setting is in sRGB, 0 to 255, like bxt_hud_color.
local function linear(c)
    c = c / 255
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

-- A new object of the class, inside outer. No name is given, so the engine picks a
-- new one: an object made with the name of a live one would replace it in place.
local function construct(class, outer)
    local ok, obj = pcall(StaticConstructObject, class, outer)
    if ok and ue.valid(obj) then
        return obj
    end
    return nil, ok and "StaticConstructObject made nothing" or tostring(obj)
end

-- Each look on its own: a setting the game's engine doesn't take only loses that look.
local function takeLooks(looks)
    for _, look in ipairs(looks) do
        local ok, problem = pcall(look[2])
        if not ok then
            log.once("speedometer-look-" .. look[1], "The speedometer can't take %s: %s", look[1], tostring(problem))
        end
    end
end

-- A UserWidget with a widget tree. CreateWidget sets the player and makes the
-- tree; in shipping builds it doesn't refuse the abstract UserWidget class.
local function makeWidget(pc)
    local userWidgetClass = ue.find(USER_WIDGET)
    if not userWidgetClass then
        return nil, "the game has no " .. USER_WIDGET
    end
    local library = ue.find(WIDGET_LIBRARY)
    if library then
        local ok, widget = ue.call(library, "Create", pc, userWidgetClass, pc)
        if ok and ue.valid(widget) and ue.valid(ue.get(widget, "WidgetTree")) then
            return widget, "WidgetBlueprintLibrary.Create"
        end
    end
    -- As other E33 mods do: the widget, then its tree, by hand.
    local treeClass = ue.find(WIDGET_TREE)
    if not treeClass then
        return nil, "the game has no " .. WIDGET_TREE
    end
    local widget, err = construct(userWidgetClass, pc)
    if not widget then
        return nil, err
    end
    local tree
    tree, err = construct(treeClass, widget)
    if not tree then
        return nil, err
    end
    widget.WidgetTree = tree
    ue.call(widget, "SetOwningPlayer", pc)
    return widget, "StaticConstructObject"
end

local function makeText(tree, cfg)
    local numericClass = ue.find(NUMERIC_TEXT)
    local class = numericClass
    if not class then
        if rawget(_G, "FText") == nil then
            return nil, "the game has no " .. NUMERIC_TEXT .. ", and this UE4SS can't make text for a TextBlock"
        end
        class = ue.find(TEXT_BLOCK)
        if not class then
            return nil, "the game has no text widget class"
        end
    end
    local text, err = construct(class, tree)
    if not text then
        return nil, err
    end
    -- Struct fields are written in place, before Slate builds the text.
    local size = math.floor(cfg.SpeedometerSize + 0.5) -- a float in Unreal 5.4, an int32 before
    local c = cfg.SpeedometerColor
    takeLooks({
        { "its size", function()
            text.Font.Size = size
        end },
        { "its outline", function()
            local outline = text.Font.OutlineSettings
            outline.OutlineSize = 2
            local color = outline.OutlineColor
            color.R, color.G, color.B, color.A = 0, 0, 0, 0.85
        end },
        { "its colour", function()
            text:SetColorAndOpacity({ SpecifiedColor = { R = linear(c[1]), G = linear(c[2]), B = linear(c[3]), A = 1 },
                ColorUseRule = 0 })
        end },
        { "its shadow", function()
            text:SetShadowOffset({ X = 2, Y = 2 })
            text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.6 })
        end },
        { "its centring", function()
            text:SetJustification(JUSTIFY_CENTER)
        end },
        { "its digits without grouping", function()
            if numericClass then
                text.FormattingSpecification.UseGrouping = false -- 1234, not 1,234
            end
        end },
    })
    return text, numericClass ~= nil
end

local function forgetWidget()
    if st.fullName then
        journal.forget("widget", st.fullName, "speedometer")
    end
    st.widget, st.fullName, st.text, st.textName = nil, nil, nil, nil
    st.visible, st.shown = false, nil
end

local function build(pc, cfg)
    local widget, how = makeWidget(pc)
    if not widget then
        return false, how
    end
    local tree = ue.object(widget, "WidgetTree")
    local canvasClass = ue.find(CANVAS_PANEL)
    if not tree then
        return false, "the widget has no widget tree"
    elseif not canvasClass then
        return false, "the game has no " .. CANVAS_PANEL
    end
    local canvas, err = construct(canvasClass, tree)
    if not canvas then
        return false, err
    end
    tree.RootWidget = canvas -- before AddToViewport: Slate builds the widget from it
    local text, numeric = makeText(tree, cfg)
    if not text then
        return false, numeric
    end
    local slot = canvas:AddChildToCanvas(text)
    if not ue.valid(slot) then
        return false, "the text couldn't be put on the canvas"
    end
    local x, y = cfg.SpeedometerPosition[1], cfg.SpeedometerPosition[2]
    takeLooks({
        { "its place", function()
            slot:SetAnchors({ Minimum = { X = x, Y = y }, Maximum = { X = x, Y = y } })
            slot:SetPosition({ X = 0, Y = 0 })
        end },
        { "its middle at its place", function()
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
        end },
        { "the size of its text", function()
            slot:SetAutoSize(true)
        end },
    })
    widget:SetVisibility(COLLAPSED) -- a widget that can't be hidden isn't put on the screen
    local okAdd, addError = ue.call(widget, "AddToViewport", Z_ORDER)
    local okIn, inViewport = ue.call(widget, "IsInViewport")
    if not okAdd or not okIn or inViewport ~= true then
        ue.call(widget, "RemoveFromParent")
        return false, "the game didn't put it on the screen ("
            .. (not okAdd and ("AddToViewport: " .. tostring(addError)) or ("IsInViewport: " .. tostring(inViewport)))
            .. ")"
    end
    local fullName, textName = ue.fullName(widget), ue.fullName(text)
    if not fullName or not textName then
        ue.call(widget, "RemoveFromParent")
        return false, "its name can't be read"
    end
    st.widget, st.fullName, st.text, st.textName = widget, fullName, text, textName
    st.numeric, st.how = numeric, how
    st.visible, st.shown, st.nextUpdate = false, nil, 0
    st.made = st.made + 1
    journal.note("widget", fullName, "speedometer", true)
    return true
end

-- Whether the widget is still the object the mod made: valid, with the same full
-- name (a new object at a freed address reads as valid).
local function widgetOurs()
    return st.widget ~= nil and ue.fullName(st.widget) == st.fullName
end

-- The same for the widget and its text.
local function ours()
    return widgetOurs() and ue.fullName(st.text) == st.textName
end

local function inViewport()
    local ok, result = ue.call(st.widget, "IsInViewport")
    return ok and result == true
end

-- The game took the widget off the screen, or it or its text was freed: it is
-- forgotten (the garbage collector frees it), and made again next time. Nothing is
-- called on it unless it is still the mod's own: then it is taken off the screen.
local function lost()
    if widgetOurs() then
        ue.call(st.widget, "RemoveFromParent")
    end
    st.lost = st.lost + 1
    if st.now - st.madeAt >= REMAKE_WINDOW then
        st.remakes = 0 -- this one had stayed a while: the game doesn't take each new one away
    end
    st.remakes = st.remakes + 1
    forgetWidget()
    if st.remakes > MAX_REMAKES then
        st.failed = "the game keeps taking it off the screen"
        log.warn("Can't show the speedometer: %s", st.failed)
    elseif st.lost <= MAX_LOST_LINES then
        log.info("The speedometer was taken off the screen by the game; it is made again")
    end
end

local function setValue(value)
    if st.numeric then
        st.text:SetCurrentValue(value)
    else
        st.text:SetText(FText(string.format("%d", value)))
    end
end

--- Hides the number (no game call unless it is shown).
function speedometer.hide()
    if not st.visible then
        return
    end
    st.visible = false
    if not ours() then
        lost()
    elseif not ue.call(st.widget, "SetVisibility", COLLAPSED) then
        speedometer.release() -- a number that can't be hidden doesn't stay on the screen
    end
end

--- Shows speed (Half-Life units per second) when visible is true, else hides the
--- number. Runs every frame from the frame hook; makes the widget when it has none.
function speedometer.update(pc, visible, speed, now, cfg)
    st.now = now
    if not visible or type(speed) ~= "number" then
        speedometer.hide()
        return
    end
    if st.failed then
        return
    end
    if not (speed >= 0 and speed < math.huge) then
        speed = 0 -- not a number, or infinite
    end
    local value = math.min(math.floor(speed + 0.5), MAX_SHOWN)
    local change = value ~= st.shown and (now >= st.nextUpdate or not st.visible)
    if st.widget then
        -- A freed widget reads as invalid, until another object takes its address.
        local due = now >= st.nextCheck or not ue.valid(st.widget) or not ue.valid(st.text)
        if due or change or not st.visible then
            if due then
                st.nextCheck = now + CHECK_INTERVAL
            end
            if not ours() or (due and not inViewport()) then
                lost()
                if st.failed then
                    return
                end
            end
        end
    end
    local made = false
    if not st.widget then
        -- A line before every build, not only the first, and one once the new widget has
        -- its number and is shown (below): if making or first showing it crashes the
        -- game, UE4SS.log ends with the first of the two; if not, it never does, however
        -- little is logged afterwards. (Builds are rare: a key press, a new area or
        -- character, or the game taking the widget away.)
        log.info("Putting the speedometer on the screen (a %s in a UserWidget)",
            ue.find(NUMERIC_TEXT) and "CommonNumericTextBlock" or "TextBlock")
        local ok, built, err = pcall(build, pc, cfg)
        if not ok or not built then
            st.failed = tostring(ok and err or built)
            log.warn("Can't show the speedometer: %s", st.failed)
            return
        end
        made = true
        st.nextCheck = now + CHECK_INTERVAL
        st.madeAt = now
        change = true
    end
    if change then
        setValue(value)
        st.shown = value
        st.nextUpdate = now + (st.numeric and NUMBER_INTERVAL or TEXT_INTERVAL)
    end
    if not st.visible then
        st.widget:SetVisibility(HIT_TEST_INVISIBLE) -- never takes the mouse or the keyboard
        st.visible = true
    end
    if made then
        log.info("The speedometer is on the screen (made with %s)", tostring(st.how))
    end
end

--- Takes the widget off the screen and forgets it (it is made again when needed).
function speedometer.release()
    if not st.widget then
        return
    end
    if widgetOurs() then
        ue.call(st.widget, "RemoveFromParent")
    end
    forgetWidget()
end

--- For a new level: the engine removed the widget with its world; don't touch it.
function speedometer.forget()
    forgetWidget()
end

--- Tries again after a failure: main.lua calls this for F9, F5 and F7, and when the
--- controller takes over a character or the character, controller or level changes.
function speedometer.retry()
    st.failed = nil
    st.remakes = 0
end

--- For the report. Asks the game whether the widget is on the screen.
function speedometer.status()
    return { made = st.made, how = st.how, numeric = st.numeric, visible = st.visible, shown = st.shown,
        failed = st.failed, lost = st.lost, onScreen = st.widget ~= nil and ours() and inViewport() }
end

return speedometer
