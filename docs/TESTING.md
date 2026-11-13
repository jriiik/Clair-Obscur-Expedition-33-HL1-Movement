# Testing the mod in the game

This list goes through what to try on a test and what to send back. Install
the mod first as described in the [README](../README.md); for an update, replace
the whole `HL1Movement` folder, `config.lua` too: an old `config.lua` keeps
`PhysicsRate = 100` and the old jump keys (the README's
[Updating](../README.md#updating-from-031) says what it gives). If the README on
the GitHub front page names an older version than the one you mean to test,
that version is on a branch: on the GitHub page, click the button that says
`main` above the list of files and choose the branch before **Code** and
**Download ZIP**; the folder inside the ZIP then ends in the branch's name
instead of `-main`. If you still have the UE4SS of the last test (build 1218),
keep it: then only the mod has changed. The mod writes in `UE4SS.log` what it does and why, a report a few
seconds after you gain control, a line for each hop and a status line for every
10 seconds in which something happened. To keep the log short it takes 30 lines
of each kind and then waits: pressing **F7** makes room for the next 30. So the
steps below say where to press F7. Press it while you stand on the ground: in
the middle of a hop or a slide it loses that one's line. If you forget one,
nothing breaks: the log just has less in it. The log is the most useful thing
to send.

## Before you start

- Back up `%LOCALAPPDATA%\Sandfall\Saved\SaveGames` (Game Pass: see
  [Other versions](../README.md#other-versions-of-the-game)).
- Load a save in a place where you can walk around freely, such as a town or a
  field, not the world map.
- Test at the PC if you can. Over Remote Desktop, see the section below.

## A 30-second check, if first person doesn't start

In the second test (0.2.6) first person started, with Unreal's own
first-person view. If it doesn't start for you, this shows whether that view
works in the game at all, without the mod doing anything:

1. Load the save, press **F5** (the mod switches off), then **F10** (or the key
   left of 1) to open the game's console, which UE4SS switches on.
2. Type `camera firstperson`, press Enter, close the console, and look around.
   Is the view now from the character's eyes? You may see the inside of the head
   or hair. Does the picture get brighter, darker or less blurry?
3. Open the console again, type `camera default`, press Enter, then press **F5**
   to switch the mod back on.

## Things to try

Write down what happens for each one. "Nothing happened" is useful too.

Some steps change a setting in `config.lua` (in
`Win64\ue4ss\Mods\HL1Movement\Scripts`): write `true` and `false` in small
letters, save the file, and press **F7** in the game. The log then has a line
such as `Settings reloaded ... Changed: BodySounds = false (was true)`. If a
change seems to do nothing, search `UE4SS.log` for `WARNING`: a slip in the file
(a misspelt `false`, a lost comma) shows there, right before that line.

1. **Loading.** In `Win64\ue4ss\UE4SS.log`, is there a line containing
   `[HL1Movement] Version 0.4.0` and `loaded`? After loading a save, one
   containing `[HL1Movement] Running every frame from`?
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
   table? Run and hold Space: do you keep hopping? On level ground (a floor or
   a paved square rather than a field), do you keep your speed between hops?
   (Where the ground tilts or is rough, the landings should keep it too at
   these speeds: step 9 looks at that.)
   - **Sounds.** In first person, walk, run and hop for a while, on stone, grass
     or water if you can. Do you hear your footsteps and the landings (and
     breathing or the rustle of clothes) as in third person? Press **F6** to
     compare in third person, then **F6** again. While walking in first person,
     press **F8**: the report then shows whether your hidden character still
     animates.
   - **The jump sound.** The mod's hops don't use the game's own jump, so a
     sound the game makes only for that jump would be missing in first and
     third person alike. To find out, press **F6** (third person) and hold
     Space for a few hops: does every hop make a jump sound (a grunt, feet
     pushing off), only the first one after you press Space, or none? Then
     press **F5** (the mod switches off) and jump a few times: does the game's
     own jump make a sound the hops didn't? Press **F5** again, then **F6** for
     first person, and hop: is it the same there as it was in third person?
   - Then open `config.lua`, change `BodySounds = true` to
     `BodySounds = false`, save it, press **F7** in the game, and walk and hop
     in first person again for at least 10 seconds. Do the footsteps and the
     other sounds stop? Press **F8** while walking. Then set it back to `true`,
     save, and press **F7**. Write down what you heard each time, and whether
     pressing F7 itself does anything you can see (a flicker, your character
     showing for a moment).
5. **Air strafing.** Press **F7** first, so that the log has a line for each of
   the next 30 hops. Run, hold Space for about 10 hops, then let go of W, hold D
   and turn the mouse slowly and smoothly to the right for about 20 more. Do you
   get faster? Judge it on level ground: on a hill some landings change your
   speed too (step 9).
   - **In third person.** Press **F7** again, then **F6**, and do the same hops,
     also switching between A and D as you turn left and right. While it hops,
     does your character turn to face where it is going, instead of flying
     sideways or backwards? Press **F8** during the hops, then F6 again for
     first person.
   - In the log, the lines of those third-person hops (not the first-person
     ones) end with something like `body +2 deg from where it headed`: how
     far, at the top of that hop, the character was turned away from the way it
     was going (+ to the right, - to the left). The number counts on hops where
     you turned slowly: the same line gives your turning speed, such as
     `(120 deg/s)`, and below about 240 close to 0 (within about 3) is right.
     Note it if the numbers of those hops are often above about 10. On faster
     turns the character falls behind on purpose (9 to 15 at 300 deg/s and 18
     to 27 at 360), and the hop during which you pressed F6 doesn't count.
   - If hopping looks worse than before in third person, set
     `BodyFollowsHop = false` in `config.lua`, save, press **F7**, and compare.
     Then set it back to `true`, save, and press **F7**.
   - To compare with Half-Life at 100 frames a second, try `PhysicsRate = 100`
     (Half-Life at fps_max 100) in `config.lua`: save, press **F7**, and do the
     same hops again, switching between A and D as you turn left and right.
     Then set it back to 250 and try `AirSpeedCap = 35` (not Half-Life's) the
     same way; one at a time, or the hop lines can't tell the two apart. The
     hop lines in the log give the speeds from before and after, and how fast
     you turned: with the view swinging about 150 to 180 degrees a second,
     `PhysicsRate = 100` gains about a sixth less per hop (about 7 u/s a hop)
     and `AirSpeedCap = 35` about an eighth more (about 6 u/s); with D held and
     a slow turn, `PhysicsRate = 100` loses only a few per cent, too little to
     see. Set `AirSpeedCap` back to 30 after, save, and press **F7**.
   - Now do the steps D1 to D13 under [Ducking and the keys](#ducking-and-the-keys)
     below, then come back here for step 6.
6. **Keys.** Does F6 switch between first and third person? Does F5 turn the mod
   off and back on?
   - **Speedometer.** With the mod on, press **F9**. An orange number should
     appear, centred across the screen, a quarter of the way up from the bottom:
     your speed. It shows 0 standing still and about 320 running, and goes higher
     as you air strafe. Does it follow your speed? Is it easy to read, and does it
     cover anything (subtitles, prompts, the game's own displays)? Does F9 do
     anything else in the game? Open the game's menu, talk to someone and start a
     battle: does the number go away and come back afterwards? Press **F8** while
     it shows, then **F9** again: does it go away?
   - The number only shows while the mod is on: **F5** takes it away with the
     rest of the mod and brings it back. F9 pressed while the mod is off shows
     nothing: it only switches the number on or off for when the mod is on
     again (off, if it was on when you pressed F5), and the log says which:
     `Speedometer on (it shows once the mod is on: F5)` or `Speedometer off`.
     In first person it may also go away while the game shows another camera
     of its own (sneaking, aiming).
   - If the game crashes right after you press F9 (or, with `Speedometer = true`
     in `config.lua`, a few seconds after you gain control, as first person
     starts), look at the last lines from `[HL1Movement]` in `UE4SS.log`. Each
     time the mod makes the number (after F9, F5 and F7, and a few seconds
     after a new area loads) it writes `Putting the speedometer on the screen`,
     and `The speedometer is on the screen` once the number shows. A log that
     ends with the first line means the game crashed while the mod made the
     number. One that ends with the second means that only if the crash came
     at that same moment (each line starts with its time). In both cases send
     the log and the crash files (see below); to play on, leave
     `Speedometer = false` in `config.lua` and don't press F9.
7. **The game's own systems.** Press **F7** first.
   - Talk to someone: does the game's camera come back, and first person after
     the dialogue?
   - Climb something: does climbing work? (Staying in first person while
     climbing is expected.) Jump at a ledge you could grab: does the character
     climb it? Then set `TakeJumpKeys = false` in `config.lua`, press **F7**,
     and jump at it again; set it back to `true` (and **F7**) afterwards.
   - Start a battle: does it use the game's camera and controls, and does first
     person come back afterwards?
   - Go to another area: does first person come back a few seconds after it
     loads?
   - After a cutscene, and after a battle or a cutscene that starts as soon as
     you enter an area: in first person, do you still hear your footsteps? If
     not, press **F6** twice: do they come back? Write down where it happened.
   - If the game lets you change your outfit or haircut, or the character you
     walk around as: in first person, change it, walk for a few seconds, then
     change back. (For up to a second after a change you may see the inside of
     the new body: that is expected.)
   - Press **F7**, then open the game's menu while running, and again while
     hopping, and close it: once with Esc and once with the menu's own button to
     go back to the game. Does the movement go on as before each time?
   - If you can aim or sneak, try that too.
   - At the end, press **F6**: is your whole character there in third person,
     head and hair too? Press **F8**, then **F6** again.
8. **Things that move you.** If you find a moving platform, a grapple point, a
   rope or anything else that throws or pulls the character, try it. On a moving
   platform, press **F7** (for the hop lines), then hold Space without moving: do
   you stay on the same spot of it, fall behind or move ahead? Then let go and
   press **F8** while standing on it (the report then shows the platform's speed
   as the game reports it). If you fell behind, press **F5** and try the game's
   own jump there: does it fall behind too? Press **F5** again afterwards.
9. **Slopes.** Switch the speedometer on (**F9**). Find a long hill or ramp (a
   street, a path, a slope in a field). Press **F8** once standing on flat
   ground and once standing on the slope: in the report, the line containing
   `Movement.CurrentFloor` shows how steep the ground under you is, such as
   `10.0 deg`.
   - Press **F7**. Run down the hill, then hold Space and air strafe as in
     step 5, and then hop up the hill the same way. Every landing should keep
     your speed, going down and going up. That is how Half-Life does it at 250
     frames a second: a landing changes your speed only if it runs into the
     slope, not if one of Half-Life's updates ends within 2 units above it,
     which sets you down first, and 250 updates a second nearly always have
     one that does at these speeds. The hop lines say so:
     `slope: speed kept (set down from 1.5 u up)`. Write down if your speed
     changes at landings, or creeps.
   - Now see Half-Life at 100 frames a second: set `PhysicsRate = 100` in
     `config.lua`, save, press **F7**, and do the same down the hill and up it.
     Now some landings should change your speed in one step: strafing down a
     10 degree hill, at about every second landing, by about 55 u/s from a run
     (more the faster you go); going up, now and then one costs some (about
     9 u/s on a gentle slope of 2 degrees, 20 on a 5 degree hill; hardly ever
     on a hill of 10 degrees or more). Such a hop line says
     `slope +54 (ran into it from 2.3 u up)`. Then set `PhysicsRate = 250`
     again, save, and press **F7**.
   - Now run and hold only W and Space, without strafing, down the same hill
     and up it: your speed should stay as it was. Does it? Then stand still on
     the slope and hold Space without any other key: you should stay on your
     spot. Do you?
   - Press **F8** when you are done with the hill: the report's `slopes` line
     then says how many landings ran into a slope, how many were set down first
     and how many the mod couldn't tell, and how much speed the first kind gave
     and took in all.
   - Press **F7** and **F8**. Run onto ground that is rough but level on the
     whole (a rocky field, roots, uneven earth), let go of W and hop across it
     holding only Space. Do you lose speed, or drift to one side? Press **F8**
     when you stop: the report's `floors at landings` line counts your landings
     by how far the floor leaned where you came down.
   - Find a drop that is knee-high or more (the edge of a ledge or a low wall,
     best of all the top end of a ramp that stops at a drop). Walk over its
     edge a tap of W at a time. Just before you fall, does your view sink, as
     if you slid down round the edge? Stop as far out as you can without
     falling and press **F8** there. If you fall first, climb back and press
     **F8** as close to the edge as you got.
   - **Slope boosting** needs a much steeper slope than that hill, and a lot of
     speed: read [Slope boosting](#slope-boosting) below first (it also says
     what to do if you can't get that fast). Then press **F7**, get fast (hop
     down a hill, or air strafe for a while), keep Space held and hop straight
     up the steepest slope you can walk on. Do the hops stop on the slope, as
     if your character ran up it? Where the slope ends or flattens, are you
     thrown off it without a jump? Write down what the speedometer showed
     before the slope, and press **F8** standing on that slope afterwards. Try
     it a few times, also in third person (**F6**), and press **F7** before
     each try. If you find a slope that stops at a drop, slide off that one
     too.
   - Press **F7**. On a long steep slope, well above the speed in the table (a
     slide then lasts up to a second or so): once the hops have stopped, let go
     of Space and tap it a few times. You should not jump until the slide ends
     (Half-Life doesn't jump in the air).
   - Press **F7**, then slide up a rough slope (rocks, uneven ground). Note how
     fast you were when the slide began, and count how often you fly off and
     land again on the way up.
   - Press **F7**. Running down a slope very fast without jumping, you leave
     the ground and go on down it in long low leaps, as in Half-Life: from
     about 1355 u/s on a 20 degree slope, 855 on 30 degrees and 705 on 35, never
     on 10 degrees and never at a plain run. With the shortcut from
     [Slope boosting](#slope-boosting) (800 u/s), run with W, Space let go, down
     the steepest slope you can walk down (35 degrees or so). You should bound
     down it, each touch costing a little speed (from 800 u/s about 13 u/s).
     The log has a line
     `Slope: flew off a 35 degree slope going down it at ... u/s` for each leap.
     Does it look right, also in third person (**F6**)? With
     `PhysicsRate = 100` (Half-Life at 100 frames a second) the same happens
     from about 540 u/s on 20 degrees, and on slopes over about 31.5 degrees
     even at a plain run: try that too if you like, and set it back to 250.
   - After a long flight, fast hops down a hill or leaps down one, does the game
     kill you, put you back somewhere, or make your character fall over
     limply?
   - Set `SlopeBoosts = false` in `config.lua`, save, and press **F7**. Hop up
     the same steep slope at the same speed. Now there should be no slide: you
     go on hopping up it (if you are fast, in hops so quick and low that you
     seem to run), and the hops go on over its top. Then also set
     `SlopeLandings = false`, save, and press **F7** again. With both off, hop
     fast up the steepest slope you can walk on once more, Space held (on a 30
     degree slope from about 580 u/s at 80 frames a second; a steeper one needs
     less, a 40 degree one 400): where the slope rises faster than the jump,
     the game lands you again at once and the mod jumps you again on every
     frame, as 0.2.6 did. Does that look or sound wrong (a buzz of landing
     sounds, dust at your feet, stutter)? Press **F8** afterwards. Then go back
     to the hill, press **F7**, and strafe down it and up it: now no landing on
     the hill should change your speed. Which do you prefer? Set both back to
     `true` (and, if you used the shortcut from
     [Slope boosting](#slope-boosting), `MaxSpeed` back to 320 and the
     `InputSpeed` line out), save, and press **F7**.
10. **Report.** Press **F8**, then quit the game from its menu.

## Slope boosting

Half-Life counts a player who rises faster than 180 u/s as being in the air,
even with the feet on the ground. So when you come onto an upward slope fast
enough, you don't land on it: you slide up it without friction, and where the
slope ends you fly off it. How fast you have to be depends on how steep the
slope is. The speeds are what the speedometer shows in your last hop before
the slope, at 80 frames a second:

| Slope | Every hop onto it slides from | Some hops onto it slide from | Running into it without Space slides from | A slide ends at |
| --- | --- | --- | --- | --- |
| 10 degrees | 1275 u/s | 1275 u/s | 1080 u/s | 1030 u/s |
| 15 degrees | 850 u/s | 850 u/s | 739 u/s | 677 u/s |
| 20 degrees | 675 u/s | 625 u/s | 575 u/s | 499 u/s |
| 25 degrees | 600 u/s | 500 u/s | 482 u/s | 389 u/s |
| 30 degrees, about as steep as stairs | 575 u/s | 400 u/s | 427 u/s | 314 u/s |

A hop that comes down on the slope slides at once only if its landing runs
into the slope, which at 250 updates a second hardly any landing does at these
speeds. Nearly always Half-Life's ground check sets you down first, with your
speed, and the held jump starts a short hop along the slope. That hop slides
when it comes back to the slope, if you are fast enough for the slope to rise
under you by about 225 u/s (on 25 and 30 degrees the jump's own first update
often runs into the slope and slides at once). From the speed in the second
column on, one or the other happens every time on a slope that is long
enough; below it you may climb the slope in quick short hops instead and keep
your speed. On 10 and 15 degrees the two columns are the same: there nothing
slides below the speed from which everything does.

- **Find a steep slope**: 20 degrees or more, as steep as you can still walk
  up, with a smooth surface and a few metres long, such as a ramp, a steep bank
  or a rock. Stand on it and press **F8**: the report shows its angle (see
  step 9). You only see that in the log, so try the steepest slopes you can
  walk up and press F8 on each. Stairs only count if the game treats them as a
  ramp: then their angle isn't 0. Hills and streets are too gentle: at 10
  degrees you would need 1275 u/s.
- **Hop onto it with Space held**, straight up the slope, so that one of your
  hops lands on it. Running into it works too, but only with Space let go, and
  you must still have the speed in the fourth column when you reach the slope.
  On the ground every metre costs you about 160 u/s, so you would have to land
  within about half a metre of its foot.
- **If you can't get that fast**, or the slope has no long run before it, write
  down how fast you got and what happened. Then make yourself fast for the rest
  of step 9: in `config.lua` set `MaxSpeed = 800` and add a line
  `InputSpeed = 800,` below it (a setting the file doesn't list: the speed your
  keys ask for, Half-Life's 400), save, and press **F7**. Now you run at
  800 u/s, and the speedometer should show it. Run first, then hold Space and
  hop onto the slope as above (W and Space pressed together from a standstill
  only give the 30 u/s Half-Life allows in the air). With Space let go you run
  into the slope instead, and while you hold W a new slide begins each time one
  ends. When you are done with step 9, set `MaxSpeed = 320` again, take the
  `InputSpeed` line out, save, and press **F7**.
- **What a slide looks like.** Your character doesn't leave the ground, because
  the game still walks it along the slope. So although you hold Space, the hops
  stop: your character stays on the slope as if it ran up it. The speedometer
  drops a little as the slide begins (by 5 to 35 u/s; in the rare slide that
  begins where a landing ran into the slope, by about 180 u/s on a 20 degree
  slope up to about 250 on a 30 degree one). Then it falls steadily: by about
  260 u/s each second on a 20 degree slope, 350 on a 30 degree one.
- **How it ends.** If the slope ends or flattens while you still slide, you fly
  off it without a jump, rising as fast as the slide did: lower than a hop off
  a 20 degree slope at 700 u/s, higher than one off a 30 degree slope at 600,
  and higher the faster you are. That is the boost. If you get slower than the
  speed in the last column first, the slide just ends, and with Space held you
  go on up the slope in quick short hops. But where the top has already begun
  to round off under you (a hill's top, a bank that flattens out), you can be
  above the ground by then, and you still fly off. A slide is short unless you
  are well above the speed needed: on a 20 degree slope it lasts about three
  quarters of a second and goes 10 to 11 metres from 700 u/s, and half a second
  to a second or so and 7 to 18 metres from 800 u/s. So pick a slope shorter than
  that, or come faster. On a ramp of only a few metres a hop can also carry you
  over the top before a slide begins: try it a few times.

The log has a line starting with `Slope:` for every slide, every flight off a
slope (a leap down one too: it takes two lines, with its landing's) and every
landing on a slope of 3 degrees or more: up to 30 lines for slides and
flights, 30 for landings that ran into a slope and 30 for landings that kept
their speed, and the same again after each **F7**. The report (**F8**) counts
all of them, in its line containing `slopes (SlopeLandings`. What the lines
mean:

- `Slope: landed on a 20 degree slope at 625 u/s, rising 187 u/s: sliding up it
  at 612 u/s, rising 223 u/s (Half-Life keeps you in the air above 180)`: a hop
  met the slope fast enough, and a slide began. The numbers are how steep the
  slope is, your speed as you met it and how fast you rose (or fell), then your
  speed in the slide and how fast you rise with it. This one is the usual kind:
  the landing before it was set down, and the short hop after it met the slope
  on its way up. With `rising 267 u/s` it was the jump's own first update that
  ran into the slope (`... at 575 u/s, rising 267 u/s: sliding up it at 547
  u/s, rising 316 u/s`). Both keep nearly all your speed. With `falling` the
  landing itself ran into the slope, which costs much more
  (`... a 30 degree slope at 575 u/s, falling 261 u/s: sliding up it at 318
  u/s, rising 184 u/s`).
- `Slope: ran into a 30 degree slope at 430 u/s: sliding up it, rising 186 u/s
  (Half-Life keeps you in the air above 180)`: a slide began while you ran on
  the ground.
- `Slope: flew off the slope at 616 u/s, rising 224 u/s`: the slope ended or
  bent away under the slide, and you flew off it. This is the boost.
- `Slope: flew off the slope at 898 u/s, rising 176 u/s: the slide ended 6.1
  units above it, out of the ground check's reach of 2`: the top rounded off
  under the slide (or it slid over a bump or a step), and by the time your
  rise was down to 180 u/s you were above the ground, so you fly on. Over a
  rounded top this is the boost too; on rough ground it is a hop of a few
  hundredths of a second.
- `Slope: off the end of the slope at 495 u/s, rising 286 u/s`: the same, where
  the slope ends in a drop. Either line can end with
  `, after 2 frames on its edge`: the game held you on the edge of the drop
  for that long first, and the flight may then start lower.
- `Slope: flew off a 35 degree slope going down it at 800 u/s (the floor falls
  2.2 units in one Half-Life update, out of the ground check's reach of 2)`: you
  ran down a slope too fast for Half-Life's ground check to keep you on it, and
  left the ground: a leap down the slope. Its landing has the
  `landed ... s after flying off the slope` line (and, on a slope of 3 degrees
  or more, a landing line).
- `Slope: landed 0.56 s after flying off the slope, at 616 u/s (+0)`: the
  landing after that flight, with the time in the air and what you gained or
  lost in it.
- `Slope: the slide up the slope ended at 498 u/s (rising 181 u/s, not more
  than 180 at Half-Life's next ground check)`: you got too slow while still on
  the slope (within 2 units of it), so there was no flight.
- `Slope: the game jumped while sliding up the slope, at ... u/s, rising
  ... u/s`: the game's own jump got through during a slide, which the mod
  tries to stop. Please note when it happened.
- `Slope: the game landed you on a ... degree slope at ... u/s while still
  rising ... u/s, away from it: Half-Life keeps you in the air above 180`: the
  game set you down on a ledge or a bump in the middle of a hop. You fly on, or
  hop a moment later.
- `Slope: landed on a 10 degree slope at 320 u/s: the speed stays. A Half-Life
  update ended 1.5 units above the slope, within the ground check's reach of 2,
  which sets you down before you run into it`: a landing that Half-Life's
  ground check set down first. It keeps its speed, and with Space held you hop
  on at once. At 250 updates a second nearly every landing is this kind.
- `Slope: landed on a 10 degree slope at 320 u/s, falling 152 u/s: 284 u/s
  (-36). It ran into the slope: the Half-Life update before it ended 2.1 units
  above the slope, out of the ground check's reach of 2`: a landing that ran
  into a slope without a slide, with your speed before and after it. At 250
  you see it only going down a slope very fast (on 10 degrees from about
  1310 u/s), or with `PhysicsRate = 100`, which this example is from.
- `Slope: landed on a ... degree slope at ... u/s: the speed stays. The mod
  can't tell whether a Half-Life update would have run into it (...)`: after a
  pause or a stutter, or where the ground under the landing wasn't one even
  slope (a step, a ledge, a crest). Please note it if there are many.

## Ducking and the keys

New in 0.4.0: Left Ctrl ducks (and a notch of the mouse wheel down ducks for
one Half-Life update), Left Shift is OpenAG's +ducktap, a notch of the wheel up
jumps, and while the mod moves your character the game doesn't act on these
keys itself (no walk toggle on Ctrl, no running on Shift, no jump of its own on
Space). Play these steps in order, after step 5, at your usual frame rate
(about 80 frames a second is fine). Start each one with **F7**, standing on
the ground: the log keeps 30 lines of duck taps and 30 of ducks and stand-ups,
and F7 makes room again. Switch the speedometer on (**F9**) for all of them.
Write down what you see, and roughly the time of anything odd.

**D1. The game's keys, with the mod off and on.** Press **F5** (the mod
switches off; the log says `Keys: given back (off)`). Press Ctrl once and walk
with W: does your character walk slowly (the game's walk toggle)? Press Ctrl
again: running again? Hold Shift and W: does it sprint? Turn the mouse wheel a
few notches: what does the game do (zoom the camera, nothing)? Now press
**F5** (the mod on; the log says `Keys: taken: ...`) and do the same: Ctrl
should only duck (a duck tap if you press it quickly), Shift should only duck
tap, and after that W should run at about 320 on the speedometer, never at the
game's walking speed and never sprinting. Then **F5** once more: do Ctrl and
Shift walk and sprint again, as at the start? Press **F5** to switch the mod
back on.

**D2. Duck on the spot and walking.** Press **F7**. Hold Ctrl for 2 seconds:
does the view sink for under half a second, then stay low? Keep holding it and
walk with W: does the speedometer show about 107? Still holding Ctrl and W,
press **F8** (the report's first line then says `asked for with F8, Ctrl
held`). Let go of Ctrl: are you up at once? Press **F6** and do the same in
third person: does your character crouch, and walk crouched? Then **F6**
again. In the log, `The character crouched (Unreal's crouch, on the ground)`
means the game let the mod crouch your character; `Ducking: on: no hull change
(...)` means it didn't, and says why.

**D3. Ducking at speed.** Press **F7**. Run with W, hold Ctrl for a second, let
go, and do that three times. Does the speedometer dip below about 107 as you
duck, or as you stand up? Lines such as `ALS braked the character for one
frame as it crouched: 10 u/s, given back` say what the game took and the mod
gave back.

**D4. Under something low.** Find a passage, a table or a beam your character
doesn't fit under standing (in third person, **F6**, it would bump its head).
Press **F7**. Duck, walk under it, and let go of Ctrl under it: are you still
ducked (the log: `No room to stand up (on the ground, under something)`)? Walk
out without Ctrl: do you stand up by yourself as soon as there is room
(`Duck: stood up late, once Unreal found room`)? In first person, does the view
ever go into the ceiling?

**D4b. F5 under it.** Ducked under the low thing again, press **F5** (the mod
off) and let go of Ctrl. Are you still ducked (with the mod off you see your
character from the game's camera)? Walk out:
do you stand up by yourself? Press **F5** (the mod on): standing, running
normally at about 320, not walking?

**D4c. Shift under it.** Press **F7**. Ducked under the low thing, hold Shift,
then Shift and Ctrl, and walk with W. Does the speedometer stay at about 107,
never 320? Are there no `Tap` lines while you are under it?

**D5. In the air.** Press **F7**. Tap Space and hold Ctrl right after: does the
view drop at once, and do you land a little later than without Ctrl? Jump,
press Ctrl at the top and let go high up: do you stand up in the air
(`Duck: stood up in the air`)? Jump, hold Ctrl, and let go just before you
land: are you ducked until the landing (`Duck: can't stand up in the air yet`)
and standing right after it? Do all of it once in third person (**F6**): how
does it look? Then **F6** again.

**D6. The mouse wheel.** Press **F7**. Standing, turn the wheel down one notch:
a small hop, your feet about a third of a metre up? Jump and turn it down one
notch at the top: below about 125 fps you won't see anything (it is one
Half-Life update of duck, and the stand-up comes in the same frame); the log
should have `Duck: ducked in the air for a wheel notch` and then `Duck: stood
up in the air`. Turn the wheel up one notch at a time, standing and then
running: one jump per notch? Press **F8**: in the report, the line that starts
with `Keys as loaded` has a part `seen pressed so far (wheel notches and quick
taps):`; it should name `MouseScrollDown` and `MouseScrollUp`. If that part
doesn't name them, the mod couldn't read the wheel (the `ignored now` part
after it is `none` in normal play).

**D7. Duck tap held (+ducktap).** Press **F7**. Hold Shift for 3 seconds
standing still: steady small hops, about five a second? The log has a `Tap`
line for each (`... 0.20 s and 52 updates in the air ...`). Listen too:
does every landing make a sound, and does anything sound wrong at five landings
a second? Press **F7**. Run, hold Shift, let go of W, and air strafe with A, D
and the mouse as in step 5 for about 6 seconds (the log has 30 taps, about
6 s): does the speed build, and to what (the speedometer; each tap line has
the speed at its landing, `landing ... u/s`)? From 320 it should reach about
470 to 550 in 6 seconds, less than hops do. Then land, press **F7**, and hold
Space as well, with Shift: only taps, no high hops? Let go of Shift with Space
still held: hops again? If you like, set `PhysicsRate = 100` (Half-Life at 100
frames a second), save, press **F7**, strafe with Shift again for about 6
seconds (it should build much less: about 320 to 370 in 6 seconds), and set it
back to 250, save, **F7**. Which feels more like your Adrenaline Gamer?

**D8. Duck tap with duck.** Press **F7**. Hold Shift, and while a tap is in the
air also hold Ctrl: are you ducked in the air (`Duck: ducked in the air`)? At
the landing: one tap, and then standing taps although Ctrl is still held? Let
go of Ctrl and press it again in the air: ducked again? Do it once in third
person (**F6**): does the landing look and sound right, and does the view stay
steady through it? Then **F6** again.

**D9. A ducked jump, and taps on slopes and a platform.** Press **F7**. Find
something about 1.4 metres high (55 units: a crate, a ledge, a wall) that a
plain jump doesn't get onto, then jump and hold Ctrl at once: do you get onto
it? Hold Shift and W and tap up a slope, and up stairs: do you get up? Press
**F7**. Get fast (over about 430 u/s), hold Shift and run straight onto a
steep ramp (30 degrees or more, see [Slope boosting](#slope-boosting)): the log
should have a line `Slope: ran into a ... degree slope at ... u/s: sliding up
it ... on a duck tap's press (no tap: Half-Life's slope boost)` and you slide
up the ramp instead of tapping. Does that happen? If you find a moving
platform, press **F7**, stand on it and hold Shift: do you stay with it?

**D10. Battles and dialogue while ducked.** Press **F7**. Hold Ctrl (ducked) as
a battle starts, and let go during the battle: afterwards, are you standing
and running normally, not stuck walking? Do the same as a dialogue starts.
Then hold Shift through the end of a battle and keep holding it: the log should
say `LeftShift is held, so it stays the game's until you let go`. Does
anything odd happen (sprinting, taps) before you let go?

**D11. The hotkeys with Ctrl or Shift held.** Hold Ctrl (ducked) and press
**F9** twice: does the speedometer go off and on again, once each? Hold Shift
and press **F8** once: is there exactly one report, whose first line says
`asked for with F8, Shift held`?

**D12 (if you have time). No crouch.** In `config.lua` set `DuckHull = false`,
save, and press **F7** (the log: `Ducking: on: no hull change (DuckHull =
false)`). Do D2 and D4 again: in third person your character should not
crouch, and the low passage should stop you. Set `DuckHull = true` again,
save, and press **F7** (`Ducking: on: Unreal's crouch`).

**D13. Menus and pauses with the mod on.** Press **F7**. Open the pause menu,
the map, the camp and the photo mode if the game has one: do the wheel's
scrolling and Space's (or A's) confirm work there as they do with the mod off
(the log: `Keys: given back (paused)`, or `(input-ignored)` / `(input-blocked)`
if the game locks your movement there)? Hold Ctrl (ducked) and press Esc. If
Windows' Start menu opens instead, tell us, and from then on let go of Ctrl
before Esc. Unpause still holding Ctrl, let go, and walk: running, not
walking? Then press **F5** and walk: running? Press **F5** again. In third
person (**F6**), talk to someone and press Space: does it skip the lines, and
does your character hop meanwhile (it shouldn't; the log: `Keys: given back
(dialogue)`, or `(input-ignored)` / `(input-blocked)` if the game locks your
movement there)? Then **F6** again.

## What to send back

- Your notes from the list above (and from the ducking steps), with roughly
  the time of anything odd, and the frame rate you usually get.
- The file `Win64\ue4ss\UE4SS.log`. Copy it somewhere else right after the
  test: UE4SS starts a new, empty log every time the game starts. Check it for
  anything private first: it can contain folder names from your PC.
- Which UE4SS build you used: the name of the zip you downloaded (or that you
  kept build 1218 from the last test).
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
line with `WARNING` or `Not keeping` in the log.

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
