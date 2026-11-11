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
    CameraMethod = "auto",  -- "engine": Unreal's own first-person view; "game": the game's camera,
                            -- moved to the eyes; "auto": "engine", and "game" if that doesn't work
    FieldOfView = 100,      -- horizontal, in degrees (Half-Life's 90 on a 4:3 screen is about 106 on 16:9)
    EyeHeight = "auto",     -- "auto", or centimetres above the middle of the character
    HideBody = true,        -- hide your own character so it doesn't block the view
    BodySounds = true,      -- keep the hidden character animating, so its footsteps and other sounds play
    PitchLimit = 89,        -- how far up and down you can look, in degrees
    BodyFollowsView = true, -- turn the character to face where you look
    BodyFollowsHop = true,  -- in the air, turn the character towards where it is going (seen in third person)

    -- Movement. These are Half-Life 1's default values.
    Movement = true,        -- false: first person with the game's own movement
    AutoHop = true,         -- hold jump to keep hopping; false: press jump for every hop, as in Half-Life 1
    MaxSpeed = 320,         -- sv_maxspeed
    Accelerate = 10,        -- sv_accelerate
    AirAccelerate = 10,     -- sv_airaccelerate
    AirSpeedCap = 30,       -- the air strafing limit; keep it low, it is what makes air strafing work.
                            -- 35 or 40 gain about 20 or 40 % more speed per hop (strafing with two or
                            -- three turns a hop), but aren't Half-Life's
    Friction = 4,           -- sv_friction
    StopSpeed = 100,        -- sv_stopspeed
    Gravity = 800,          -- sv_gravity; as in Half-Life, less gravity also means higher jumps
    JumpHeight = 45,        -- how high a jump goes at Gravity 800 (Half-Life's is 45 units)
    BhopCap = 0,            -- 0: no speed limit. 1.7: like later Half-Life updates,
                            -- which slow you down when you jump above 1.7 x MaxSpeed
    MaxVelocity = 2000,     -- sv_maxvelocity
    UnitScale = 2.5,        -- centimetres per Half-Life unit; higher makes everything faster and jumps higher
    PhysicsRate = 100,      -- Half-Life updates per second, whatever the frame rate (Half-Life at fps_max 100);
                            -- up to 250; 0: one update per frame. 144, 200 or 250 gain about 15, 24 or 28 %
                            -- more speed per hop when air strafing, as Half-Life does at that frame rate
    KeepSpeed = true,       -- undo the game cutting your speed (its speed limit), so hops keep their speed
    SlopeLandings = true,   -- Half-Life's landings on slopes: part of the fall turns into speed along the slope,
                            -- so hopping down a 10 degree hill gains about 65 u/s a hop, and up it loses
                            -- about 30; false: landings keep your speed, as the game's do
    SlopeBoosts = true,     -- slope boosting: running or landing fast against an upward slope lifts you off
                            -- the ground, you slide up it without friction and fly off the top; false: never

    -- Input, as Unreal key names: W, A, S, D, Up, Down, Left, Right, SpaceBar,
    -- LeftShift, MouseScrollDown, Gamepad_FaceButton_Bottom (the A button) ...
    JumpKeys = { "SpaceBar", "Gamepad_FaceButton_Bottom" }, -- add "MouseScrollDown" to hop with the mouse wheel
    ForwardKeys = { "W" },  -- for example { "W", "Up" } to use the arrow keys too
    BackKeys = { "S" },
    LeftKeys = { "A" },
    RightKeys = { "D" },
    GamepadStick = true,    -- move with the left stick
    StickDeadzone = 0.25,

    Debug = false,          -- true: more messages in UE4SS.log
}
