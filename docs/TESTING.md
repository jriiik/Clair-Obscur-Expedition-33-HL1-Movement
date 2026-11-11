# Testing the mod in the game

This list goes through what to try on a test and what to send back. Install
the mod first as described in the [README](../README.md); for an update, replace
the whole `HL1Movement` folder. The mod writes in `UE4SS.log` what it does and
why, a report a few seconds after you gain control, a line for each of your
first 20 hops and a status line every 10 seconds. The log is the most useful
thing to send.

## Before you start

- Back up `%LOCALAPPDATA%\Sandfall\Saved\SaveGames` (Game Pass: see
  [Other versions](../README.md#other-versions-of-the-game)).
- Load a save in a place where you can walk around freely, such as a town or a
  field, not the world map.
- Test at the PC if you can. Over Remote Desktop, see the section below.

## A 30-second check, with any version

This shows whether Unreal's own first-person view works in this game, without
the mod doing anything:

1. Load the save, press **F5** (the mod switches off), then **F10** (or the key
   left of 1) to open the game's console, which UE4SS switches on.
2. Type `camera firstperson`, press Enter, close the console, and look around.
   Is the view now from the character's eyes? You may see the inside of the head
   or hair. Does the picture get brighter, darker or less blurry?
3. Open the console again, type `camera default`, press Enter, then press **F5**
   to switch the mod back on.

## Things to try

Write down what happens for each one. "Nothing happened" is useful too.

1. **Loading.** In `Win64\ue4ss\UE4SS.log`, is there a line containing
   `[HL1Movement] Version 0.3` and `loaded`? After loading a save, one containing
   `[HL1Movement] Running every frame from`?
2. **Camera.** Leave the controls alone for 10 seconds after you gain control:
   the mod waits three seconds, then switches to first person and writes its
   report. Is the view first person? Can you see any part of your character's
   body, hair or gear? Can you look straight up and down? Press F6 twice to
   compare with third person: does the picture look the same (brightness,
   colours, blur)?
3. **Walking.** Hold W for 3 seconds. Is it faster than the game's normal
   running? Does letting go stop you quickly but smoothly? Does walking follow
   where you look?
4. **Jumping.** Tap Space. Do your feet rise a little over a metre, well above a
   table? Hold Space: do you keep hopping? Do you keep your speed between hops?
   - **Sounds.** In first person, walk, run and hop for a while, on stone, grass
     or water if you can. Do you hear your footsteps, the jumps and the landings
     (and breathing or the rustle of clothes) as in third person? Press **F6** to
     compare in third person, then **F6** again. While walking in first person,
     press **F8**: the report then shows whether your hidden character still
     animates.
   - Then open `config.lua` (in `Win64\ue4ss\Mods\HL1Movement\Scripts`), change
     `BodySounds = true` to `BodySounds = false`, save it, press **F7** in the
     game, and walk and hop in first person again for at least 10 seconds. Do
     those sounds stop? Press **F8** while walking. Then set it back to `true`,
     save, and press **F7**. Write down what you heard each time.
5. **Air strafing.** Run, hold Space for about 10 hops, let go of W, hold D and
   turn the mouse slowly and smoothly to the right. Do you get faster?
   - **In third person.** Press **F6** and do the same, also switching between A
     and D as you turn left and right. While it hops, does your character turn to
     face where it is going, instead of flying sideways or backwards? Press **F8**
     during the hops, then F6 again for first person.
   - In the log, the hop lines now end with something like
     `body +2 deg from where it headed`: how far, at the top of that hop, the
     character was turned away from the way it was going (+ to the right, - to
     the left). Close to 0 is right. Note it if the numbers are often above
     about 10.
   - If hopping looks worse than before in third person, set
     `BodyFollowsHop = false` in `config.lua`, press **F7**, and compare.
   - For a little more speed per hop, try `PhysicsRate = 144` (Half-Life at a
     higher frame rate) or `AirSpeedCap = 35` (not Half-Life's) in `config.lua`,
     press **F7**, and compare the hop lines. Set them back to 100 and 30 after.
6. **Keys.** Does F6 switch between first and third person? Does F5 turn the mod
   off and back on?
   - **Speedometer.** Press **F9**. An orange number should appear, centred
     across the screen, a quarter of the way up from the bottom: your speed.
     It shows 0 standing still and about 320 running, and goes higher as you air
     strafe. Does it follow your speed? Is it easy to read, and does it cover
     anything (subtitles, prompts, the game's own displays)? Open the game's menu,
     talk to someone and start a battle: does the number go away and come back
     afterwards? Press **F8** while it shows, then **F9** again: does it go away?
   - If the game crashes right after you press F9 (or right after the game
     loads, with `Speedometer = true` in `config.lua`), look at the last lines
     from `[HL1Movement]` in `UE4SS.log`. If the last one says `Putting the
     speedometer on the screen`, send the log and the crash files (see below).
     To play on, leave `Speedometer = false` in `config.lua` and don't press F9.
7. **The game's own systems.**
   - Talk to someone: does the game's camera come back, and first person after
     the dialogue?
   - Climb something: does climbing work? (Staying in first person while
     climbing is expected.)
   - Start a battle: does it use the game's camera and controls, and does first
     person come back afterwards?
   - Go to another area: does first person come back a few seconds after it
     loads?
   - Open the game's menu while running, and again while hopping, then close
     it: once with Esc and once with the menu's own button to go back to the
     game. Does the movement go on as before each time?
   - If you can aim or sneak, try that too.
8. **Things that move you.** If you find a moving platform, a grapple point, a
   rope or anything else that throws or pulls the character, try it. On a moving
   platform, hold Space without moving: do you stay on the same spot of it, fall
   behind or move ahead? Then let go and press **F8** while standing on it (the
   report then shows the platform's speed as the game reports it). If you fell
   behind, press **F5** and try the game's own jump there: does it fall behind
   too? Press **F5** again afterwards.
9. **Slopes.** Find a long hill or ramp (a street, a path, a slope in a field).
   Press **F8** once standing on flat ground and once standing on the slope.
   - Hold Space and hop down the hill: do you get faster with each hop? Then hop
     up it: do you slow down? Both are as in Half-Life (on a 10 degree hill, about
     65 u/s gained per hop going down and 30 lost going up).
   - Get fast (hop down a hill, or air strafe for a while), then run or hop
     straight at a slope going up. Do you slide up it and fly off the top? The log
     then has lines starting with `Slope:`, such as `ran into a 20 degree slope`
     and `flew off the slope`.
   - While sliding up a slope, tap Space once: you should keep sliding without a
     jump (Half-Life doesn't jump in the air).
   - Slide up a rough slope (rocks, uneven ground) and count how often you fly
     off and land again on the way up.
   - After a long flight or fast hops down a hill, does the game kill you, put you
     back somewhere, or make your character fall over limply?
   - Set `SlopeBoosts = false` in `config.lua` and press **F7**: running fast at
     the same slope should just walk up it. Then also set `SlopeLandings = false`:
     hopping up and down the hill should keep your speed. Which feels better? Set
     both back to `true` and press **F7**.
10. **Report.** Press **F8**, then quit the game from its menu.

## What to send back

- Your notes from the list above, and the frame rate you usually get.
- The file `Win64\ue4ss\UE4SS.log`. Copy it somewhere else right after the
  test: UE4SS starts a new, empty log every time the game starts. Check it for
  anything private first: it can contain folder names from your PC.
- Which UE4SS build you used: the name of the zip you downloaded.
- If the game crashed, before starting it again:
  - every `crash_....dmp` file in `Win64\ue4ss` (UE4SS writes one on a crash);
  - the newest folder in `%LOCALAPPDATA%\Sandfall\Saved\Crashes` (type that
    path into the File Explorer address bar), zipped;
  - the text of the crash message (click it, press Ctrl+C and paste it into
    Notepad), or a photo;
  - from the Event Viewer (Win+R, `eventvwr.msc`, then *Windows Logs* and
    *Application*), the text of the *Application Error* entry from the time of
    the crash: it names the part that crashed.

  Crash dumps contain part of the game's memory: send them privately, not in a
  public issue.

Things worth mentioning even if they seem small: the view drifting on its own,
stuttering, the camera snapping back to third person, getting stuck, and any
line with `WARNING` in the log.

## Over Remote Desktop

Windows Remote Desktop limits a session to 30 frames a second, compresses every
frame, sends the mouse in a way games handle badly, and may draw the game
without the graphics card. So over Remote Desktop:

- Judge only whether first person starts, whether the body is hidden, whether
  hopping works and whether the game is stable. The log measures the speeds and
  the frame rate for you.
- Don't judge mouse feel, smoothness or how air strafing feels.
- Start the game from inside the Remote Desktop session, and don't resize,
  minimize or disconnect the window while the game runs.
- Steam Remote Play (the Steam Link app) or Parsec work better for games, if you
  can use them.

If the game crashes, try the same save once with the mod switched off (rename
`HL1Movement\enabled.txt` to `enabled.txt.off`), and tell which of the two
crashed.
