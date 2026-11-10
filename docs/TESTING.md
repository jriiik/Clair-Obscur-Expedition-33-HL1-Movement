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
   `[HL1Movement] Version 0.2` and `loaded`? After loading a save, one containing
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
5. **Air strafing.** Run, hold Space for about 10 hops, let go of W, hold D and
   turn the mouse slowly and smoothly to the right. Do you get faster?
6. **Keys.** Does F6 switch between first and third person? Does F5 turn the mod
   off and back on?
7. **The game's own systems.**
   - Talk to someone: does the game's camera come back, and first person after
     the dialogue?
   - Climb something: does climbing work? (Staying in first person while
     climbing is expected.)
   - Start a battle: does it use the game's camera and controls, and does first
     person come back afterwards?
   - Go to another area: does first person come back a few seconds after it
     loads?
   - If you can aim or sneak, try that too.
8. **Things that move you.** If you find a moving platform, a grapple point, a
   rope or anything else that throws or pulls the character, try it. On a moving
   platform, hold Space without moving: do you stay on the same spot of it, fall
   behind or move ahead? Then let go and press **F8** while standing on it (the
   report then shows the platform's speed as the game reports it). If you fell
   behind, press **F5** and try the game's own jump there: does it fall behind
   too? Press **F5** again afterwards.
9. **Report.** Press **F8**, then quit the game from its menu.

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
