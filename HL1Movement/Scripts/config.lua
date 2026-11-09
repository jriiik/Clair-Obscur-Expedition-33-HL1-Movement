-- Settings for the Half-Life movement mod.
--
-- Change a value, save the file, and press F7 in the game to load it again.
-- New keys for the four hotkeys below only work after restarting the game.
-- Keep the commas at the ends of lines and the quotes around names.
-- Speeds and distances are in Half-Life units, so the numbers match Half-Life's.

return {
    -- Hotkeys, as UE4SS key names: F1 to F12, HOME, END, PAGE_UP, INS, NUM_ZERO ...
    -- Use false for no key.
    ToggleKey = "F5",       -- turns the mod on and off
    CameraKey = "F6",       -- switches between first and third person
    ReloadKey = "F7",       -- loads this file again
    DiagnosticsKey = "F8",  -- writes a status report to UE4SS.log

    StartEnabled = true,    -- false: the mod starts switched off until you press ToggleKey

    -- Camera
    FirstPerson = true,     -- false: keep the game's camera and only change the movement
    FieldOfView = 100,      -- horizontal, in degrees (Half-Life's 90 on a 4:3 screen is about 106 on 16:9)
    EyeHeight = "auto",     -- "auto", or centimetres above the middle of the character
    HideBody = true,        -- hide your own character so it doesn't block the view
    PitchLimit = 89,        -- how far up and down you can look, in degrees
    BodyFollowsView = true, -- turn the character to face where you look

    -- Movement. These are Half-Life 1's default values.
    Movement = true,        -- false: first person with the game's own movement
    AutoHop = true,         -- hold jump to keep hopping; false: press jump for every hop, as in Half-Life 1
    MaxSpeed = 320,         -- sv_maxspeed
    Accelerate = 10,        -- sv_accelerate
    AirAccelerate = 10,     -- sv_airaccelerate
    AirSpeedCap = 30,       -- the air strafing limit; keep it low, it is what makes air strafing work
    Friction = 4,           -- sv_friction
    StopSpeed = 100,        -- sv_stopspeed
    Gravity = 800,          -- sv_gravity
    JumpHeight = 45,        -- Half-Life's jump is 45 units high
    BhopCap = 0,            -- 0: no speed limit. 1.7: like later Half-Life updates,
                            -- which slow you down when you jump above 1.7 x MaxSpeed
    MaxVelocity = 2000,     -- sv_maxvelocity
    UnitScale = 2.5,        -- centimetres per Half-Life unit; higher makes everything faster and jumps higher

    -- Input, as Unreal key names: W, A, S, D, SpaceBar, LeftShift, MouseScrollDown,
    -- Gamepad_FaceButton_Bottom (the A button) ...
    JumpKeys = { "SpaceBar", "Gamepad_FaceButton_Bottom" }, -- add "MouseScrollDown" to hop with the mouse wheel
    ForwardKeys = { "W", "Up" },
    BackKeys = { "S", "Down" },
    LeftKeys = { "A", "Left" },
    RightKeys = { "D", "Right" },
    GamepadStick = true,    -- move with the left stick
    StickDeadzone = 0.25,

    Debug = false,          -- true: more messages in UE4SS.log
}
