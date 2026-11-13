# Half-Life movement for Clair Obscur: Expedition 33

A mod that lets you explore Clair Obscur: Expedition 33 in first person, with
Half-Life 1's movement: fast, slippery running, air strafing, bunny hopping by
holding the jump key, ducking and duck tapping.

> **Status: version 0.4.1, early testing.** In the second test (0.2.6), first
> person, bunny hopping and air strafing worked. 0.3 added your character's
> sounds in first person, its turning to face where it hops, Half-Life's
> slopes with slope boosting and a speedometer (F9). 0.4.0 adds Half-Life's
> ducking (Left Ctrl, or a notch of the mouse wheel down), duck tapping, and
> OpenAG's +ducktap (Left Shift held: a duck tap every time you touch the
> ground), with jumping on the wheel too. While the mod moves you, the game
> no longer runs, toggles walk or jumps on those keys. The movement now runs
> 250 Half-Life updates a second, as Half-Life at `fps_max 250`, the rate
> duck tapping is played at. 0.4.1, after the first test of 0.4.0, smooths
> the view as you stand up or climb a stair, as Half-Life does, switches off the game's
> roll on landing (it took your speed), and logs a sudden loss of speed. 0.4.1
> hasn't been tested in the game yet: see [docs/TESTING.md](docs/TESTING.md) and
> [Reporting problems](#reporting-problems). If you used 0.3.1, read
> [Updating](#updating-from-031) first.

## What it does

- **First-person camera** while you walk around. Your own character is hidden so
  it doesn't block the view, and you can look straight up and down. It keeps
  animating while hidden, so you still hear its footsteps and the other sounds
  its animations make, as in third person.
- **Half-Life 1 movement**: the same acceleration, friction, gravity and jump
  height as Half-Life, scaled to the game's world.
- **Bunny hopping**: hold the jump key and you jump again the moment you land.
  On level ground a landing costs no speed. Steer in the air (air strafing) to
  build up speed. In third person (F6), your character turns in the air to face
  where it is going.
- **Ducking as in Half-Life**: hold Left Ctrl and you duck: on the ground the
  view sinks for 0.4 s at full speed, then you move at a third of the speed
  (about 107 u/s) and fit under things you can't pass standing; in the air the
  duck is at once and pulls your feet up, so a ducked jump clears 63 units
  instead of 45. Let go within those 0.4 s on the ground and you duck tap: a
  small hop of about a fifth of a second that costs only one Half-Life update
  of friction. Hold **Left Shift** for OpenAG's +ducktap: a duck tap every
  time you touch the ground, which you can air strafe like hops. A notch of the
  mouse wheel down is one Half-Life update of duck (a duck tap by hand on the
  ground; in the air one update of duck, too short to see at most frame
  rates); a notch up is one jump.
- **Slopes as in Half-Life**: on a slope most landings keep your speed too.
  Now and then one turns part of the fall into speed along the slope, in one
  step: your speed jumps up going down a hill and drops going up one. At the
  default 250 updates a second (Half-Life at `fps_max 250`) that hardly ever
  happens at running and strafing speeds; at `PhysicsRate = 100` (Half-Life at
  `fps_max 100`) it happens often going down a hill and seldom going up one,
  and on rough ground it can take a little speed at a landing and nudge your
  direction. Run very fast down a hill without jumping and you leave the
  ground, as in Half-Life, and go on down it in long low leaps (from about 1355
  u/s on a 20 degree hill, 855 on a 30 degree one; never at a run, and never
  on a 10 degree hill). A touch costs a little speed, as a landing can. Hop
  onto a steep upward slope fast enough (about 675 u/s for a 20 degree slope,
  575 for a 30 degree one) and you don't land on it: you slide up it without
  friction, and fly off its top if it ends, or rounds off, while you still
  slide (slope boosting). [docs/TESTING.md](docs/TESTING.md#slope-boosting) has
  the speeds and what a slide looks like.
- It **steps aside on its own** in battles and on the world map. When the game
  shows another camera (dialogue, cutscenes, sneaking, aiming), first person
  switches off. When the game locks your movement or moves the character itself
  (dialogue, cutscenes, climbing, ledge grabs), the game's own movement comes back.
- A **speedometer** like Bunnymod XT's, on **F9**: your speed across the ground in
  Half-Life units per second, in Half-Life's HUD orange, below the middle of the
  screen. It shows only while the mod is on, and hides itself in menus, battles,
  dialogue and cutscenes (more under
  [When the mod steps aside](#when-the-mod-steps-aside)).
- Everything can be turned on and off in the game with one key.

## What you need

- Clair Obscur: Expedition 33 for Windows. These steps are for the **Steam**
  version; see [Other versions](#other-versions-of-the-game).
- **UE4SS**, a free mod loader for Unreal Engine games. The game uses Unreal
  Engine 5.4, which the old UE4SS 3.0.1 from 2024 doesn't support: you need an
  **experimental** build (step 2 below) or UE4SS 4.0 or newer. The mod was last
  tested in the game (version 0.2.6) with the experimental build 1218
  (`UE4SS_v3.0.1-1218-g560411f1.zip`). UE4SS 4.0 came out on 12 November 2026
  and hasn't been tried with the mod yet.

Back up your saves before trying mods. They are in
`%LOCALAPPDATA%\Sandfall\Saved\SaveGames` (paste that into the File Explorer
address bar; for Game Pass see [Other versions](#other-versions-of-the-game)).
Steam Cloud keeps only one copy, so it isn't a backup.

## Installing

Everything goes into the game's folder. Nothing of the game is replaced; these are
only added files.

1. **Find the game's folder.** In Steam, right-click Clair Obscur: Expedition 33,
   choose *Manage*, then *Browse local files*. Open `Sandfall`, then `Binaries`,
   then `Win64`. This folder holds `SandFall-Win64-Shipping.exe`. The full path is
   usually `C:\Program Files (x86)\Steam\steamapps\common\Expedition 33\Sandfall\Binaries\Win64`.
2. **Install UE4SS.** Go to the UE4SS download page,
   <https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest>, and
   download the file whose name starts with `UE4SS_v` (on 12 November 2026 it
   was `UE4SS_v4.0.0-1-gf54b7332.zip`; the numbers change with every build). Not
   the files starting with `zDEV`, `zCustomGameConfigs` or `zMapGenBP`, and not
   *Source code*. Double-click the downloaded file, select everything inside it
   (`dwmapi.dll` and the `ue4ss` folder) and copy it into the `Win64` folder
   from step 1. You should now have `Win64\dwmapi.dll` and a `Win64\ue4ss`
   folder. Only download UE4SS from that GitHub page; other sites that look
   official are not.
3. **Install this mod.** On this mod's GitHub page, click the green **Code**
   button, then **Download ZIP**. Double-click the ZIP, open the folder inside it
   (`Clair-Obscur-Expedition-33-HL1-Movement-main`; if you chose another branch
   on the GitHub page first, its name ends with that branch's name instead of
   `main`), and copy the `HL1Movement` folder into `Win64\ue4ss\Mods`. You should
   end up with `Win64\ue4ss\Mods\HL1Movement\Scripts\main.lua` and
   `Win64\ue4ss\Mods\HL1Movement\enabled.txt`.
4. **Start the game from Steam** as usual and load a save. A few seconds after you
   gain control, the view switches to first person.

To check that it loaded, open `Win64\ue4ss\UE4SS.log` in a text editor. It should
have a line containing `[HL1Movement] Version` and `loaded`, and after loading a
save one containing `[HL1Movement] Running every frame from`. A few seconds after
you gain control, the mod writes a report to the log by itself.

### Updating from 0.3.1

From 0.4.0, replacing the `HL1Movement` folder is enough: an old `config.lua`
works, and lacks only `ViewSmoothing` and `LandingRoll`, which then have their
defaults. From 0.3.1:
replace the whole `HL1Movement` folder, `config.lua` too (copy out any
settings you changed first, and put them back in the new file). An old
`config.lua` still works: every setting it lacks, the duck keys among them,
comes from the defaults. But it keeps `PhysicsRate = 100`, which plays duck
tapping and air strafing as Half-Life at `fps_max 100`, and its `JumpKeys`
without the wheel up. If you followed its old advice and put
`"MouseScrollDown"` in `JumpKeys`, that key is now also a duck key: the log
says `MouseScrollDown is in DuckKeys and JumpKeys: it does both`, and a notch
then ducks and jumps. The report (F8) lists every setting that isn't at its
default, in its line `Settings not at their defaults`.

## Controls

| Key | What it does | As in Half-Life |
| --- | --- | --- |
| **F5** | Turns the mod on and off | |
| **F6** | Switches between first and third person (the movement stays) | |
| **F7** | Loads the settings file again | |
| **F8** | Writes a status report to `UE4SS.log` | |
| **F9** | Shows and hides the speedometer (it only shows while the mod is on) | |
| W A S D, mouse | Move and look, as usual | |
| **Space** (held) | Jump, and keep hopping every time you land | `+jump` |
| Mouse wheel up | One jump per notch, on the ground | `+jump` on the wheel |
| **Left Ctrl** (held) | Duck while held | `+duck` |
| Mouse wheel down | Duck for one Half-Life update per notch: a duck tap on the ground, one update of duck in the air | `+duck` on the wheel |
| **Left Shift** (held) | A duck tap every time you touch the ground | OpenAG's `+ducktap` |

F5 to F9 also work while you hold Ctrl, Shift or both. A controller works too:
the left stick moves and A jumps. On many laptops the F keys only work while
you hold the **Fn** key.

While the mod moves your character, the game's own actions on these keys
(walk, run, jump) wait. Whenever it doesn't (switched off with F5, in battles,
dialogue, cutscenes and menus that pause the game or stop your movement, and
for three seconds after a new area), they are the game's again: Left Ctrl toggles walking, Left Shift runs, Space jumps or skips a line,
and the wheel does what the game does with it. A duck or duck tap key you are
still holding when the mod takes the keys back stays the game's until you let
go of it.

### Changing the keys

The keys are lists in `config.lua`: `JumpKeys`, `DuckKeys`, `DuckTapKeys`, and
`ForwardKeys`, `BackKeys`, `LeftKeys` and `RightKeys` for moving. Any key or
mouse button can go in any of them, by Unreal's name or by Half-Life's:

| Unreal's name | Half-Life's |
| --- | --- |
| `SpaceBar`, `LeftShift`, `RightShift`, `LeftControl`, `RightControl`, `LeftAlt`, `RightAlt` | `SPACE`; `SHIFT` and `CTRL` (either key), `LSHIFT`, `RCTRL` ... ; `ALT` |
| `LeftMouseButton`, `RightMouseButton`, `MiddleMouseButton` | `MOUSE1`, `MOUSE2`, `MOUSE3` |
| `ThumbMouseButton`, `ThumbMouseButton2` (the side buttons) | `MOUSE4`, `MOUSE5` |
| `MouseScrollUp`, `MouseScrollDown` | `MWHEELUP`, `MWHEELDOWN` |
| `A` to `Z`, `Zero` to `Nine`, `F1` to `F12`, `Up`, `Down`, `Left`, `Right`, `Enter`, `Tab` | `a`, `0`, `UPARROW` ... |
| `Gamepad_FaceButton_Bottom` (A) and the other `Gamepad_` buttons | |

For example `DuckKeys = { "CTRL", "MOUSE5" }` ducks on either Ctrl key and on
the second side button. Save the file and press **F7**. The log names a name
the mod doesn't know (with what you may have meant), a key that is in two
lists (it then does both), and the keys it leaves out: Escape, the hotkeys,
and the wheel in `DuckTapKeys` (+ducktap does nothing on a single notch, as in
OpenAG: put the wheel in `DuckKeys` for duck taps by hand).

### How to bunny hop and air strafe

1. Run forward and **hold Space**. You keep hopping, and on level ground you
   lose no speed when you land.
2. While in the air, **let go of W**, hold **A or D**, and turn the mouse smoothly in
   the same direction (left with A, right with D). This is air strafing: it
   gains speed.
3. Switch between A and D as you turn left and right. The faster you turn, the
   more speed you gain, up to a point. Switch keys right when the mouse changes
   direction: switching late loses much of the gain.

Without air strafing you keep the speed you had on level ground, but don't gain
any. On a hill the landings keep it too at running and strafing speeds; with
`PhysicsRate = 100` (Half-Life at `fps_max 100`) now and then one changes it
in one step (on a 10 degree hill by about 55 u/s going down and about 35 going
up; the speedometer shows it). Standing on a slope and holding Space, you stay
where you are (with the default `PhysicsRate`). `SlopeLandings = false` (see
[Settings](#settings)) makes every landing keep your speed.

### How to duck tap

1. Standing or running, press and let go of **Left Ctrl** quickly (within 0.4
   s), or turn the mouse wheel down one notch: you hop about 15 units (37 cm)
   and land a fifth of a second later. A tap costs one Half-Life update of
   friction: 1.6 % of your speed.
2. **Hold Left Shift** instead and you duck tap every time you touch the
   ground, about five times a second, as OpenAG's `+ducktap` does. Air strafe
   with A and D and the mouse as in bunny hopping: the speed builds, more
   slowly than with hops (from 320 to about 530 to 640 u/s in 10 s at 80
   frames a second, where hops reach 850 to 960), and it stays close to the
   ground.
3. With Shift and Space held together you only duck tap; let go of Shift with
   Space still held and you hop again.
4. Hold Ctrl in the air under +ducktap and you land ducked; the next touch of
   the ground stands you up and taps at once (OpenAG's 2022 rule), and you go
   on tapping standing until you let go of Ctrl and press it again.

Under something low a tap doesn't lift you: you stay ducked and walk at the
ducked speed, also with Shift held. On a steep upward ramp taken fast (over
about 430 u/s on a 30 degree one), the tap's press runs into the ramp and you
slide up it, as Half-Life's slope boost does (see
[docs/TESTING.md](docs/TESTING.md#slope-boosting)).

## Settings

Settings are in `Win64\ue4ss\Mods\HL1Movement\Scripts\config.lua`. Open it with a
text editor (Notepad works), change a value, save, and press **F7** in the game.
Each setting has a short explanation next to it. The most useful ones:

| Setting | Default | What it does |
| --- | --- | --- |
| `FieldOfView` | `100` | How wide the first-person view is, in degrees |
| `FirstPerson` | `true` | `false` keeps the game's own camera |
| `CameraMethod` | `"auto"` | How first person is done: `"engine"` (Unreal's own first-person view), `"game"` (the game's camera moved to the eyes, which keeps its picture settings) or `"auto"` (the first, then the second if it doesn't work) |
| `BodySounds` | `true` | Keeps your hidden character animating in first person, so you still hear its footsteps and the other sounds its animations make; it costs about what third person does. `false` lets the game stop them, as it does for a character nobody sees |
| `Movement` | `true` | `false` keeps the game's own movement |
| `AutoHop` | `true` | `false`: press jump for every hop, like the original Half-Life |
| `AirSpeedCap` | `30` | Half-Life's limit on air strafing, which is what makes it work; `35` or `40` gain about 15 to 17 or 30 to 35 % more speed per hop with a slow turn (about 10 to 15 or 15 to 27 % with A and D and a fast one), but aren't Half-Life's |
| `BodyFollowsHop` | `true` | In the air, your character turns to face where it is going (you see it in third person); `false` keeps it facing the way it jumped |
| `ViewSmoothing` | `true` | As in Half-Life, on the ground your view follows a rise at 150 units a second, never more than 18 behind: standing up from a duck, a stair, a steep slope. `false` shows the rise at once, as 0.4.0 did |
| `JumpKeys` | `{ "SpaceBar", "MouseScrollUp", "Gamepad_FaceButton_Bottom" }` | The jump keys (see [Changing the keys](#changing-the-keys)); a wheel notch is one jump |
| `DuckKeys` | `{ "LeftControl", "MouseScrollDown" }` | Half-Life's `+duck`: ducked while held; a wheel notch ducks for one Half-Life update |
| `DuckTapKeys` | `{ "LeftShift" }` | OpenAG's `+ducktap`: while held, a duck tap every time you touch the ground. Not the wheel |
| `Ducking` | `true` | `false`: no ducking at all, and the duck keys stay the game's |
| `DuckHull` | `true` | `false`: the view and the speed duck, but your character keeps its full height, so it fits under nothing lower |
| `TakeKeys` | `true` | While the mod moves you, the game doesn't act on the duck, duck tap and jump keys (no walk toggle on Ctrl, no running on Shift). `false` lets it, as in 0.3 |
| `TakeJumpKeys` | `true` | `false` leaves the game its own jump on the jump keys, as in 0.3 |
| `MaxSpeed`, `Accelerate`, `AirAccelerate`, `Friction`, `Gravity` | Half-Life's values | The same as Half-Life's `sv_` console variables. Your keys ask for 400 u/s (Half-Life's `cl_forwardspeed`), so `MaxSpeed` above 400 also needs a line `InputSpeed = ...` (a setting `config.lua` doesn't list), or you still run at 400 |
| `JumpHeight` | `45` | How high a jump goes at `Gravity` 800; as in Half-Life, less gravity jumps higher |
| `UnitScale` | `2.5` | Centimetres per Half-Life unit; higher makes everything faster and higher |
| `BhopCap` | `0` | `1.7` copies later Half-Life updates, which slow you down above 1.7 × max speed |
| `PhysicsRate` | `250` | Half-Life movement updates per second, whatever the frame rate, as Half-Life at `fps_max 250`, up to `250`; `0` updates once per frame. `200` to `100` gain a little less when air strafing (about 3 to 16 % less with A and D in turn and the view swinging about 150 to 180 degrees a second, only a few per cent with one key and a slow turn), as Half-Life does at those frame rates (`100` is `fps_max 100`; at `144` today's Steam version, while the 2005 version cuts every update to whole milliseconds and gains more at 144). A duck tap costs one update of friction, 1.6 % of your speed at `250` and 4 % at `100`, so +ducktap strafing builds much less speed at `100`. From `135` on, a hop along level ground or an even rise keeps its speed when it lands (unless it starts a slide, see `SlopeBoosts`), and landings going downhill change it less often; one that comes down where the ground turns upward (the foot of a hill, the bottom of a dip) can still lose some, less often the higher the rate. At some other rates (`80`, `95`, `98` and `101` of those tried) hopping on the spot on a slope moves you off down it, as today's Steam Half-Life does at those frame rates (the 2005 version, of these four, only at 80) |
| `KeepSpeed` | `true` | Undoes the game cutting your speed (its own speed limit); `false` lets the game's cuts stand |
| `SlopeLandings` | `true` | Half-Life's landings on slopes: most keep your speed, as on level ground; one that reaches the slope inside one of Half-Life's updates turns part of the fall into speed along it in one step (a jump in speed going downhill, a drop going uphill). How often depends on your speed, the slope and `PhysicsRate`. `false` makes every landing keep your speed, as the game does |
| `SlopeBoosts` | `true` | Hopping onto a steep upward slope fast enough, or running into it, starts a slide up it without friction instead of a landing, and you fly off its top if it ends or rounds off while you still slide. Every hop slides from about 675 u/s on a 20 degree slope, 575 on 30 degrees, 850 on 15 and 1275 on 10, and on 20 to 30 degrees some from less. Running down a slope without jumping, fast enough (from about 1355 u/s on 20 degrees, 855 on 30 and 585 on 40; never at a run, and never on 10 degrees; at `PhysicsRate = 100` from 540 on 20 degrees, and at a run on slopes over 31.5 degrees), you leave the ground and go on down it in long low leaps, as in Half-Life; `false` turns both off |
| `LandingRoll` | `false` | `true` keeps the game's roll on landing with a movement key held (its "breakfall"), which takes the movement from the mod for the roll and most of your speed with it. Half-Life has no roll, so the mod switches it off while it moves you, in first and third person |
| `ForwardKeys` and so on | `{ "W" }` … | The movement keys; add `"Up"`, `"Down"`, `"Left"`, `"Right"` for the arrow keys |
| `Speedometer` | `false` | `true`: the speedometer is on when the game starts. This is only read then: F7 doesn't switch it on or off, F9 (`SpeedometerKey`) does |
| `SpeedometerPosition`, `SpeedometerSize`, `SpeedometerColor` | `{ 0.5, 0.75 }`, `32`, `{ 255, 160, 0 }` | Where the middle of the speedometer goes (across and down the screen, from 0 to 1), how big its digits are, and its colour (red, green and blue, from 0 to 255) |

New hotkeys only take effect after restarting the game.

## When the mod steps aside

Both the camera and the movement go back to the game, with everything the mod
changed, and the speedometer leaves the screen, when:

- a battle starts (they come back afterwards);
- the game changes area, and for three seconds after a new area or character
  appears;
- you are on the world map (Esquie and the world map aren't supported yet).

Otherwise each part steps aside on its own:

- **First person** switches off during dialogue and cinematics, and while the
  game shows another camera, for example when sneaking or aiming.
- **The game's own movement** comes back while the game locks your movement or
  moves the character itself: dialogue, cutscenes, climbing, ledge grabs.
- **The speedometer** hides while the game is paused (its menu) and while it
  locks your movement. With first person on, it also hides during dialogue and
  cinematics, and while the game shows the view of something other than your
  character, as it may when sneaking or aiming.

So you stay in first person while you climb, and you may keep the Half-Life
movement while aiming. While the game is paused, nothing else changes.

Whenever the movement goes back to the game, so do the duck, duck tap and jump
keys, and the mod lets go of the crouch: your character stands up as soon as
there is room. While the game shows a dialogue, a cutscene or another camera
(sneaking, aiming), the keys are the game's too, even where the Half-Life
movement goes on: Space then goes to the game and doesn't hop.

## Uninstalling

- To remove this mod, delete the `Win64\ue4ss\Mods\HL1Movement` folder.
- To remove UE4SS and all its mods, delete `Win64\dwmapi.dll` and the `Win64\ue4ss`
  folder.

Steam's *Verify integrity of game files* doesn't remove mods, because it only
checks the game's own files. It isn't needed to uninstall either.

## Is it safe?

- **No ban risk.** The game is single-player only and has no anti-cheat: no VAC and
  nothing else. Keep UE4SS in this game's folder only, though. Never copy it into
  a game that has anti-cheat, such as Counter-Strike or Half-Life's multiplayer.
- **Saves**: the mod doesn't touch your saves. Moving fast can take you places the
  game wasn't built for, though. You could get stuck, fall out of the world or
  skip a story trigger. Keep regular saves, and press **F5** to get the game's own
  movement back if something goes wrong.
- **Achievements** are not known to be blocked by mods, but that isn't guaranteed.
- **Antivirus** programs sometimes flag UE4SS by mistake, because it injects
  itself into the game.

## Troubleshooting

- **Nothing happens.** Open `Win64\ue4ss\UE4SS.log` and search (Ctrl+F) for
  `HL1Movement`. If it isn't there, the mod isn't installed in the right folder.
  If there is no `UE4SS.log` at all, or the times in it are from before you
  started the game, UE4SS didn't load: check step 2.
- **The game crashes at start** after installing UE4SS. Make sure you use an
  experimental build from the page above, or UE4SS 4.0 or newer, and that you
  don't have two copies of UE4SS from different mods.
- **The camera stays in third person.** The log says why, in lines that start
  with `First person:`. If Unreal's own first-person view doesn't reach the eyes
  within two seconds, the mod moves the game's camera to the eyes instead. If
  that doesn't work either, it switches first person off by itself, so that your
  character isn't left invisible, and the log says `First person doesn't work
  here`. Please report it. Press F6 twice to try again.
- **The speedometer doesn't show** when you press F9. It shows only while the
  mod is on (F5) and you can move your character: not in menus, battles,
  dialogue or cutscenes, and not on the world map. If you pressed F9 while the
  mod was off, that press only switched the number on or off for later: the log
  says `Speedometer on (it shows once the mod is on: F5)` or `Speedometer off`.
  After the second, press F9 once more when the mod is on. Setting
  `Speedometer = true` and pressing F7 doesn't show it either: that setting is
  only read when the game starts. If the mod couldn't put it on the screen, the
  log says why, in a line with `WARNING` and `speedometer`. Please report it.
- **Steam Deck or Linux**: add this launch option in Steam (right-click the game,
  *Properties*, *Launch options*): `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- **A key does nothing.** On a laptop, hold **Fn** with it. Another mod may use
  it too: change the keys in `config.lua` and restart the game.
- **A changed setting does nothing.** Save `config.lua` and press **F7** (the
  hotkeys, `StartEnabled` and `Speedometer` are only read when the game
  starts). If it still does nothing, search `UE4SS.log` for `WARNING`: the mod
  says there what it couldn't use in `config.lua`. The usual slips are a
  missing comma, a name without its quotes, and `true` or `false` written
  differently (`False`, `flase`).

## Other mods and Windows

- **UE4SS's Keybinds mod**, if it is on (it often is), dumps all of the
  game's objects on **Ctrl+J** and its header files on **Ctrl+H** (and more on
  Ctrl with the number pad's 5 to 9). Each freezes the game for a long time.
  So while you duck with Ctrl, don't press J or H; or turn that mod off: in
  `Win64\ue4ss\Mods\mods.txt`, change `Keybinds : 1` to `Keybinds : 0`. The log
  reminds you the first time you duck on a Ctrl key.
- **Windows' own shortcuts** with Ctrl or Shift: pressing Shift five times may
  ask to turn on Sticky Keys, Ctrl+Shift may switch the keyboard layout,
  **Ctrl+Esc** opens the Start menu and **Ctrl+Shift+Esc** the Task Manager.
  Each takes the game out of focus, and the game then lets go of every key you
  hold. Since Esc pauses the game, let go of Ctrl and Shift before you press
  Esc. If Sticky Keys or the layout switch gets in the way, they can be turned
  off in Windows' settings.
- **Another mod on the same keys**: change the mod's keys in `config.lua` (see
  [Changing the keys](#changing-the-keys)), or the hotkeys and restart the
  game.

## Reporting problems

0.3's and 0.4's new parts haven't been tested in the game yet, so reports help
a lot. [docs/TESTING.md](docs/TESTING.md) has a short list of things to try.

1. Play until the problem happens, then press **F8**. This adds a status report to
   the log (while the game is loading, a few seconds later).
2. Quit the game (or let it crash), then copy `Win64\ue4ss\UE4SS.log` somewhere
   else **before you start the game again**: UE4SS starts a new, empty log every
   time the game starts.
3. Open an issue on this GitHub page, describe what you saw, and attach the log.
   Check it first for anything private: it can contain folder names from your PC.

## Known limitations

- The view's smoothing, the landing roll switched off and the lines about
  sudden losses of speed are new in 0.4.1 and not tested in the game yet.
  Ducking, duck tapping and the wheel (0.4.0) had their first test there. If
  the game doesn't let your character crouch, the mod ducks the view and the
  speed only, and the log says so.
- If your character is silent in first person after a cutscene or a battle that
  started as soon as you entered an area, press F6 twice: the mod only keeps a
  hidden character animating once the game has shown it.
- No swimming, ladders or long jump the way Half-Life does them.
- No surfing: a slope too steep to walk on stops you like a wall, where Half-Life
  lets you slide along it. Slopes otherwise follow Half-Life's rules closely but
  not exactly: the game keeps you on the ground over small bumps and down stairs
  (Half-Life leaves the ground at every step higher than 2 units), and a leap
  down a hill or a flight off the top of a slide starts from the ground, a
  little lower than Half-Life's. While you slide up a slope, the game still
  walks your character, so it looks as if it ran up the slope until it flies
  off the top.
- Half-Life's extra friction near ledge edges isn't copied.
- While the mod moves you, the game doesn't see your jump keys, so neither its
  ledge grab on a jump press nor its double jump works, and its automatic ledge
  climbing may not trigger. Press F5 to climb, then F5 again, or set
  `TakeJumpKeys = false` in `config.lua` to give the game its jump keys back, as
  in 0.3.
- In third person (F6) with the mod's movement, the character's animations can
  look wrong, because the game doesn't see your input.
- A hop may lack the sound the game's own jump makes, in first and third person
  alike: the mod lifts the character off the ground itself, without the game's
  jump. This isn't known yet; [docs/TESTING.md](docs/TESTING.md) asks.
- With Unreal's own first-person view (`CameraMethod = "engine"`, the first one
  `"auto"` tries), the game's camera effects, such as depth of field and camera
  shake, don't apply. If the game sets brightness or colours on its own camera,
  the picture can look a little different too, and sound is heard from where the
  game's camera would be. With `"game"`, the game's picture settings stay; only
  its depth of field and its shake while running are switched off.

## Where it isn't Half-Life

The movement follows Half-Life's rules update by update, but the game, not the
mod, moves your character and finds the ground, so a few things come out a
little differently:

- **Landings**: the game lands you when you touch the ground, a moment after
  Half-Life would, so a hop lasts 0.01 to 0.03 s longer. Speeds aren't
  affected.
- **Duck taps** lift you about 15 units, not Half-Life's 18, so that the
  game's landing comes when Half-Life's would: a tap onto a ledge between 15
  and 18 units high (37 to 45 cm) fails where Half-Life's makes it. A tap
  takes 53 Half-Life updates at 80 frames a second (54 at 60, 51 at 144,
  58 at 30), where Half-Life takes 52.
- **Keys** are read once a frame: two wheel notches within one frame count as
  one, and a duck tap waits for the next frame. Duck taps by hand on the wheel
  keep a little more speed at a frame rate held steady by a cap or v-sync
  (on the same taps, about 15 % more at a steady 60 frames a second, 8 % at 80,
  and about 4 % less than Half-Life with frame times that vary by a tenth).
- **Standing up** where there turns out to be no room costs one frame at full
  speed before the duck goes on.
- **A stand-up just above the ground** (the "jump bug") lands first, and a
  held jump comes up to a frame later.
- **Letting go of Shift** on the ground with Space held hops at once; OpenAG
  waits one or two updates first.
- **If the game doesn't let your character crouch**, or only on the ground,
  the mod ducks the view and the speed but not the character's height, at
  least in the air: ducked hops land as standing ones, and a ducked jump
  clears 45 units, not 63. The log says so (`Ducking: on: no hull change ...`).
  `DuckHull = false` does the same everywhere.
- Not there at all: ducked long jumps, the extra friction near ledge edges,
  surfing, water and ladders (see [Known limitations](#known-limitations)).

## Other versions of the game

The mod itself works the same in every version; only the folders differ.
- **GOG**: the folder is also `Sandfall\Binaries\Win64`; the game file there is
  `SandFallGOG-Win64-Shipping.exe`.
- **Xbox / Game Pass for PC**: use `Sandfall\Binaries\WinGDK` wherever these steps
  say `Win64`. To find it, open the Xbox app, choose *Manage* for the game, then
  *Files* and *Browse*, and open `Content\Sandfall\Binaries\WinGDK`. The saves are
  in `%LOCALAPPDATA%\Packages\KeplerInteractive.Expedition33_ymj30pw7xe604\SystemAppData\wgs`;
  back up that whole folder, with the game closed.
- **Epic**: not checked yet.

## How it works

UE4SS loads `HL1Movement\Scripts\main.lua` when the game starts. Every frame, the
mod runs from the player controller's update, after the game reads your input
and before it moves your character:

- It takes the movement input away from the game and works out the new velocity
  with Half-Life's rules (`hl1movement/physics.lua` and, for ducking,
  `hl1movement/duck.lua`), in steps of 4 milliseconds (250 a second), as
  Half-Life does at `fps_max 250`. It then hands that velocity to Unreal's character
  movement, which still handles walls, stairs, slopes and gravity; on slopes the
  mod changes the velocity as Half-Life would (landings, slides, leaving the
  ground running down one). Unreal's own acceleration and braking are switched
  off or cancelled out, and the game's speed limiter is paused
  (`hl1movement/movement.lua`). A duck uses Unreal's own crouch, which makes
  the character's capsule 18 units shorter (`hl1movement/hull.lua`).
- While it moves the character, it gives the game an input mapping of its own
  for the duck, duck tap and jump keys, so that the game's own actions on them
  wait (`hl1movement/keys.lua`).
- It checks which camera the game shows (`hl1movement/view.lua`). While that is
  the character's main camera, it switches Unreal's camera manager to its built-in
  `FirstPerson` camera style, which looks out of the character's eyes, or moves
  the game's camera to the eyes, and hides the body (`hl1movement/camera.lua`).

Everything it changes is remembered and put back when it steps aside. If the
game sets a value of its own in the meantime, such as a new walking speed, that
is the one put back. If UE4SS restarts its mods while the game runs, the new copy
of the mod first puts back what the old one changed.

## Development

The tests run with plain Lua 5.4, against a stand-in for UE4SS and the game in
`tests/fake_game.lua`:

```
lua5.4 tests/run.lua
luacheck .
```

GitHub Actions runs both on every push and offers the mod folder as a download
(an "artifact") on each run's page.

## Credits and legal

This is a fan-made mod. It is not affiliated with or endorsed by Sandfall
Interactive, Kepler Interactive or Valve. Clair Obscur: Expedition 33 belongs to
Sandfall Interactive; Half-Life is a trademark of Valve Corporation.

The movement is an independent implementation of the publicly documented movement
model Half-Life inherited from Quake. The mod contains no code or files from
Half-Life, from the Half-Life SDK or from Clair Obscur: Expedition 33.

UE4SS is a separate project (<https://github.com/UE4SS-RE/RE-UE4SS>) and is not
included here.

Released under the [MIT License](LICENSE).
