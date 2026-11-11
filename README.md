# Half-Life movement for Clair Obscur: Expedition 33

A mod that lets you explore Clair Obscur: Expedition 33 in first person, with
Half-Life 1's movement: fast, slippery running, air strafing and bunny hopping
by holding the jump key.

> **Status: version 0.2.6, early testing.** In the first test, first person never
> started and air strafing gained no speed. 0.2 fixes the most likely causes:
> first person now follows the camera the game really shows, with a second way to
> get to the eyes if the first doesn't work, and the Half-Life movement runs 100
> times a second whatever the frame rate. If the game cuts your speed, the mod
> undoes it and notes it in `UE4SS.log`. 0.2.1 to 0.2.6 fix what six code
> reviews found. It hasn't been tested in the game yet:
> see [docs/TESTING.md](docs/TESTING.md) and [Reporting problems](#reporting-problems).

## What it does

- **First-person camera** while you walk around. Your own character is hidden so
  it doesn't block the view, and you can look straight up and down.
- **Half-Life 1 movement**: the same acceleration, friction, gravity and jump
  height as Half-Life, scaled to the game's world.
- **Bunny hopping**: hold the jump key and you jump again the moment you land,
  without losing speed. Steer in the air (air strafing) to build up speed. In
  third person (F6), your character turns in the air to face where it is going.
- **Slopes as in Half-Life**: landing on a slope turns part of the fall into speed
  along it, so hopping down a hill speeds you up and hopping up one slows you
  down. Run or land fast against an upward slope and it lifts you off the
  ground: you slide up it and fly off the top (slope boosting).
- It **steps aside on its own** in battles and on the world map. When the game
  shows another camera (dialogue, cutscenes, sneaking, aiming), first person
  switches off. When the game locks your movement or moves the character itself
  (dialogue, cutscenes, climbing, ledge grabs), the game's own movement comes back.
- Everything can be turned on and off in the game with one key.

## What you need

- Clair Obscur: Expedition 33 for Windows. These steps are for the **Steam**
  version; see [Other versions](#other-versions-of-the-game).
- **UE4SS**, a free mod loader for Unreal Engine games. You need an
  **experimental** build, because the game uses Unreal Engine 5.4 and the older
  "stable" UE4SS 3.0.1 from 2024 doesn't support it.

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
   download the file whose name starts with `UE4SS_v` (in November 2026 it was
   `UE4SS_v3.0.1-1218-g560411f1.zip`). Not the files starting with `zDEV`,
   `zCustomGameConfigs` or `zMapGenBP`, and not *Source code*. Double-click the
   downloaded file, select everything inside it (`dwmapi.dll` and the `ue4ss`
   folder) and copy it into the `Win64` folder from step 1. You should now have
   `Win64\dwmapi.dll` and a `Win64\ue4ss` folder. Only download UE4SS from that
   GitHub page; other sites that look official are not.
3. **Install this mod.** On this mod's GitHub page, click the green **Code**
   button, then **Download ZIP**. Double-click the ZIP, open the
   `Clair-Obscur-Expedition-33-HL1-Movement-main` folder inside it, and copy the
   `HL1Movement` folder into `Win64\ue4ss\Mods`. You should end up with
   `Win64\ue4ss\Mods\HL1Movement\Scripts\main.lua` and
   `Win64\ue4ss\Mods\HL1Movement\enabled.txt`.
4. **Start the game from Steam** as usual and load a save. A few seconds after you
   gain control, the view switches to first person.

To check that it loaded, open `Win64\ue4ss\UE4SS.log` in a text editor. It should
have a line containing `[HL1Movement] Version` and `loaded`, and after loading a
save one containing `[HL1Movement] Running every frame from`. A few seconds after
you gain control, the mod writes a report to the log by itself.

## Controls

| Key | What it does |
| --- | --- |
| **F5** | Turns the mod on and off |
| **F6** | Switches between first and third person (the movement stays) |
| **F7** | Loads the settings file again |
| **F8** | Writes a status report to `UE4SS.log` |
| W A S D, mouse | Move and look, as usual |
| **Space** (held) | Jump, and keep hopping every time you land |

A controller works too: the left stick moves and A jumps. On many laptops the F
keys only work while you hold the **Fn** key.

### How to bunny hop and air strafe

1. Run forward and **hold Space**. You keep hopping and lose no speed when you land.
2. While in the air, **let go of W**, hold **A or D**, and turn the mouse smoothly in
   the same direction (left with A, right with D). This is air strafing: it
   gains speed.
3. Switch between A and D as you turn left and right. The faster you turn, the
   more speed you gain, up to a point. Switch keys right when the mouse changes
   direction: switching late loses much of the gain.

Without air strafing you keep the speed you had, but don't gain any.

## Settings

Settings are in `Win64\ue4ss\Mods\HL1Movement\Scripts\config.lua`. Open it with a
text editor (Notepad works), change a value, save, and press **F7** in the game.
Each setting has a short explanation next to it. The most useful ones:

| Setting | Default | What it does |
| --- | --- | --- |
| `FieldOfView` | `100` | How wide the first-person view is, in degrees |
| `FirstPerson` | `true` | `false` keeps the game's own camera |
| `CameraMethod` | `"auto"` | How first person is done: `"engine"` (Unreal's own first-person view), `"game"` (the game's camera moved to the eyes, which keeps its picture settings) or `"auto"` (the first, then the second if it doesn't work) |
| `Movement` | `true` | `false` keeps the game's own movement |
| `AutoHop` | `true` | `false`: press jump for every hop, like the original Half-Life |
| `BodyFollowsHop` | `true` | In the air, your character turns to face where it is going (you see it in third person); `false` keeps it facing the way it jumped |
| `JumpKeys` | `{ "SpaceBar", "Gamepad_FaceButton_Bottom" }` | Add `"MouseScrollDown"` to hop with the mouse wheel |
| `MaxSpeed`, `Accelerate`, `AirAccelerate`, `Friction`, `Gravity` | Half-Life's values | The same as Half-Life's `sv_` console variables |
| `JumpHeight` | `45` | How high a jump goes at `Gravity` 800; as in Half-Life, less gravity jumps higher |
| `UnitScale` | `2.5` | Centimetres per Half-Life unit; higher makes everything faster and higher |
| `BhopCap` | `0` | `1.7` copies later Half-Life updates, which slow you down above 1.7 × max speed |
| `PhysicsRate` | `100` | Half-Life movement updates per second, whatever the frame rate, as Half-Life at `fps_max 100`, up to `250`; `0` updates once per frame. `144` to `250` gain a little more when air strafing (about 15 to 28 %), as Half-Life does at those frame rates |
| `KeepSpeed` | `true` | Undoes the game cutting your speed (its own speed limit); `false` lets the game's cuts stand |
| `SlopeLandings` | `true` | Landing on a slope turns part of the fall into speed along it: faster downhill, slower uphill, as in Half-Life; `false` keeps your speed at landings, as the game does |
| `SlopeBoosts` | `true` | Running or landing fast against an upward slope lifts you off the ground: you slide up it without friction and fly off the top; `false` turns this off |
| `ForwardKeys` and so on | `{ "W" }` … | The movement keys; add `"Up"`, `"Down"`, `"Left"`, `"Right"` for the arrow keys |

New hotkeys only take effect after restarting the game.

## When the mod steps aside

Both the camera and the movement go back to the game, with everything the mod
changed, when:

- a battle starts (they come back afterwards);
- the game changes area, and for three seconds after a new area or character
  appears;
- you are on the world map (Esquie and the world map aren't supported yet).

Otherwise each part steps aside on its own:

- **First person** switches off during dialogue and cinematics, and while the
  game shows another camera, for example when sneaking or aiming.
- **The game's own movement** comes back while the game locks your movement or
  moves the character itself: dialogue, cutscenes, climbing, ledge grabs.

So you stay in first person while you climb, and you may keep the Half-Life
movement while aiming. While the game is paused, nothing changes.

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
  experimental build from the page above, and that you don't have two copies of
  UE4SS from different mods.
- **The camera stays in third person.** The log says why, in lines that start
  with `First person:`. If Unreal's own first-person view doesn't reach the eyes
  within two seconds, the mod moves the game's camera to the eyes instead. If
  that doesn't work either, it switches first person off by itself, so that your
  character isn't left invisible, and the log says `First person doesn't work
  here`. Please report it. Press F6 twice to try again.
- **Steam Deck or Linux**: add this launch option in Steam (right-click the game,
  *Properties*, *Launch options*): `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- **A key does nothing.** On a laptop, hold **Fn** with it. Another mod may use
  it too: change the keys in `config.lua` and restart the game.

## Reporting problems

This version hasn't been tested in the game yet, so reports help a lot.
[docs/TESTING.md](docs/TESTING.md) has a short list of things to try.

1. Play until the problem happens, then press **F8**. This adds a status report to
   the log (while the game is loading, a few seconds later).
2. Quit the game (or let it crash), then copy `Win64\ue4ss\UE4SS.log` somewhere
   else **before you start the game again**: UE4SS starts a new, empty log every
   time the game starts.
3. Open an issue on this GitHub page, describe what you saw, and attach the log.
   Check it first for anything private: it can contain folder names from your PC.

## Known limitations

- Not tested in the game yet (see the top).
- No crouch jumping, ducking, swimming or ladders the way Half-Life does them.
- No surfing: a slope too steep to walk on stops you like a wall, where Half-Life
  lets you slide along it. Slopes otherwise follow Half-Life's rules closely but
  not exactly: the game keeps you on the ground over small bumps.
- Half-Life's extra friction near ledge edges isn't copied.
- While the mod moves you, the game's automatic ledge climbing may not trigger.
  Press F5 to climb, then F5 again.
- In third person (F6) with the mod's movement, the character's animations can
  look wrong, because the game doesn't see your input.
- With Unreal's own first-person view (`CameraMethod = "engine"`, the first one
  `"auto"` tries), the game's camera effects, such as depth of field and camera
  shake, don't apply. If the game sets brightness or colours on its own camera,
  the picture can look a little different too, and sound is heard from where the
  game's camera would be. With `"game"`, the game's picture settings stay; only
  its depth of field and its shake while running are switched off.

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
  with Half-Life's rules (`hl1movement/physics.lua`), in steps of a hundredth of
  a second, as Half-Life does. It then hands that velocity to Unreal's character
  movement, which still handles walls, stairs, slopes and gravity; on slopes the
  mod changes the velocity as Half-Life would (landings, slides). Unreal's own
  acceleration and braking are switched off or cancelled out, and the game's
  speed limiter is paused (`hl1movement/movement.lua`).
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
