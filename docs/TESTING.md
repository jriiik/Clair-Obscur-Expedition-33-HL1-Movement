# Testing the mod in the game

Version 0.1 hasn't been run in the game yet. This list goes through what to try
on a first test and what to send back. Install it first as described in the
[README](../README.md).

## Before you start

- Back up `%LOCALAPPDATA%\Sandfall\Saved\SaveGames` (Game Pass: see
  [Other versions](../README.md#other-versions-of-the-game)).
- Load a save in a place where you can walk around freely, such as a town or a
  field, not the world map.

## Things to try

Write down what happens for each one. "Nothing happened" is useful too.

1. **Loading.** Open `Win64\ue4ss\UE4SS.log`. Is there a line containing
   `[HL1Movement] Version 0.1.0 loaded`? After loading a save, is there one
   containing `[HL1Movement] Running every frame from`?
2. **Camera.** About a second after the save loads, does the view switch to first
   person? Can you see any part of your character's body, hair or gear? Can you
   look straight up and down? Press F6 to compare with third person: does the
   picture look the same (brightness, colours)?
3. **Walking.** Hold W. Is it faster than the game's normal running? Does letting
   go stop you quickly but smoothly? Does walking follow where you look?
4. **Jumping.** Tap Space. Do your feet rise a little over a metre, well above a
   table? Hold Space: do you keep hopping? Do you keep your speed between hops?
5. **Air strafing.** Run, hold Space, let go of W, hold D and turn the mouse right.
   Do you get faster?
6. **Keys.** Does F6 switch between first and third person? Does F5 turn the mod
   off and back on?
7. **The game's own systems.**
   - Talk to someone: does the game's camera come back, and first person after
     the dialogue?
   - Climb something: does climbing work? (Staying in first person while
     climbing is expected.)
   - Start a battle: does it use the game's camera and controls, and does first
     person come back afterwards?
   - If you can aim or sneak, try that too.
8. **Things that move you.** If you find a moving platform, a grapple point, a
   rope or anything else that throws or pulls the character, try it.
9. **Report.** Press **F8**, then quit the game.

## What to send back

- Your notes from the list above.
- The file `Win64\ue4ss\UE4SS.log`. Copy it somewhere else before you start the
  game again: UE4SS starts a new, empty log every time the game starts. Check it
  for anything private first: it can contain folder names from your PC.
- Which UE4SS build you used: the name of the zip you downloaded.

Things worth mentioning even if they seem small: the view drifting on its own,
stuttering, the camera snapping back to third person, getting stuck, and any
line with `WARNING` in the log.
