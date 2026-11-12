-- Settings for the Half-Life movement mod.
--
-- Change a value, save the file, and press F7 in the game to load it again.
-- New keys for the five hotkeys below only work after restarting the game.
-- Keep the commas at the ends of lines and the quotes around names, and write
-- true and false in small letters. A slip in this file is named in UE4SS.log,
-- in a line with WARNING.
-- Speeds and distances are in Half-Life units, so the numbers match Half-Life's.

return {
    -- Hotkeys, as UE4SS key names: F1 to F12, HOME, END, PAGE_UP, INS, NUM_ZERO ...
    -- Use false for no key.
    ToggleKey = "F5",       -- turns the mod on and off
    CameraKey = "F6",       -- switches between first and third person
    ReloadKey = "F7",       -- loads this file again
    DiagnosticsKey = "F8",  -- writes a status report to UE4SS.log

    StartEnabled = true,    -- false: the mod starts switched off until you press ToggleKey

    -- Speedometer: your speed across the ground in Half-Life units per second, like Bunnymod XT's
    Speedometer = false,    -- true: the speedometer is on when the game starts. Only read then: F7 doesn't
                            -- switch it on or off, SpeedometerKey does. It shows only while the mod is on
    SpeedometerKey = "F9",  -- a hotkey like those above: shows and hides the speedometer
    SpeedometerPosition = { 0.5, 0.75 }, -- where its middle goes, from 0 to 1: { across, down } the screen
    SpeedometerSize = 32,   -- how big its digits are, from 8 to 200
    SpeedometerColor = { 255, 160, 0 }, -- red, green and blue, from 0 to 255: Half-Life's HUD orange

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
    MaxSpeed = 320,         -- sv_maxspeed. Your keys ask for 400 (Half-Life's cl_forwardspeed), so above 400
                            -- also add a line InputSpeed = ... (a setting this file doesn't list)
    Accelerate = 10,        -- sv_accelerate
    AirAccelerate = 10,     -- sv_airaccelerate
    AirSpeedCap = 30,       -- the air strafing limit; keep it low, it is what makes air strafing work.
                            -- 35 or 40 gain about 17 or 33 % more speed per hop when air strafing, but
                            -- aren't Half-Life's
    Friction = 4,           -- sv_friction
    StopSpeed = 100,        -- sv_stopspeed
    Gravity = 800,          -- sv_gravity; as in Half-Life, less gravity also means higher jumps
    JumpHeight = 45,        -- how high a jump goes at Gravity 800 (Half-Life's is 45 units)
    BhopCap = 0,            -- 0: no speed limit. 1.7: like later Half-Life updates,
                            -- which slow you down when you jump above 1.7 x MaxSpeed
    MaxVelocity = 2000,     -- sv_maxvelocity
    UnitScale = 2.5,        -- centimetres per Half-Life unit; higher makes everything faster and jumps higher
    PhysicsRate = 100,      -- Half-Life updates per second, whatever the frame rate (Half-Life at fps_max 100);
                            -- up to 250; 0: one update per frame. 144, 200 or 250 gain about 10, 15 or 20 %
                            -- more speed per hop when air strafing with A and D in turn and the view swinging
                            -- about 150 to 180 degrees a second, as today's Steam Half-Life does at that frame
                            -- rate (the 2005 version cuts every update to whole milliseconds, 6 at 144 fps, and
                            -- gains more there); with one key and a slow turn only a few per cent. From 135 on,
                            -- landings on slopes change your speed less often (see SlopeLandings)
    KeepSpeed = true,       -- undo the game cutting your speed (its speed limit), so it takes none from your hops
    SlopeLandings = true,   -- Half-Life's landings on slopes. Most keep your speed, as on level ground. One that
                            -- reaches the slope inside one of Half-Life's updates turns part of the fall into
                            -- speed along it, in one step: on a 10 degree hill about 55 u/s gained going down
                            -- from a run (more the faster you go) and about 35 lost going up. How often depends
                            -- on your speed, the slope and PhysicsRate: at 100, about every second landing
                            -- going down a 10 degree hill while strafing, and few going up one.
                            -- false: every landing keeps your speed, as the game's do
    SlopeBoosts = true,     -- slope boosting: hop onto a steep upward slope fast enough (or run into it) and you
                            -- slide up it without friction instead of landing, and fly off its top if it ends
                            -- or rounds off while you still slide. Every hop slides from about 675 u/s on a 20
                            -- degree slope, 600 on 30 degrees, 825 on 15 and 1275 on 10, and some from less.
                            -- Running down a slope without jumping, fast enough (about 540 u/s on 20 degrees,
                            -- 1120 on 10, and at a run on slopes steeper than about 31.5 degrees), you leave the
                            -- ground and go on down it in long low leaps, as in Half-Life; false: neither

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
