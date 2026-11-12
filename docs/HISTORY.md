# What each version changed

The history of HL1Movement, version by version. It stood in `CLAUDE.md` until 0.3.1 and is kept here so that
`CLAUDE.md`, which every Claude session reads in full, stays shorter. The rules these versions left behind, each with
its reason, are in `CLAUDE.md` under "Decisions so far"; its "Status" has the two tests in the game, the last review
and what is open, and `docs/MEASUREMENTS.md` has the figures. Nothing here is needed to work on the mod: it tells how
the rules came about, and what an earlier version did that a rule now prevents (so that nobody goes back to it).

## 0.1 to 0.2.6

- 0.1.0 went through a review of the UE4SS API use, the engine behaviour, the logic and the docs, checked against the
  UE4SS and Unreal source and E33's SDK dump; the confirmed findings were fixed.
- First test in the game (0.1.0): see "Status" in `CLAUDE.md`.
- 0.1.1 made the log explain itself: state lines with reasons (`log.state`), a line before the first use of each kind
  of change (`log.first`), automatic reports and a status line every 10 s.
- 0.2 follows a research pass on E33's camera rig, input, the crash and other E33 mods: the camera rule from the
  engine (the likely reason first person never started), the game-camera fallback, 100 Hz movement updates, KeepSpeed
  and the limiter checked every frame, the platform-only jump velocity, safe hook registration, the 3 s settle and
  area-change wait, forgetting a destroyed level, cheaper frames, and a report that answers the open questions.
- 0.2.1 fixes what a five-part review of 0.2 (UE4SS API, engine, logic, crashes and cost, tests and docs, each finding
  checked by a second reviewer) confirmed or found likely: `GetMainCamera`'s out key, the game-camera FOV (animations,
  lens limits, moves at activation), walls taken for speed cuts, cuts below 20 %, the re-attach location, hidden parts
  at reused addresses and parts the game shows, the engine view during blends, `bStayBasedInAir`, F8 during loads,
  `PhysicsRate` above 250 and the limiter text. Refuted: registering hooks from key callbacks is a crash risk (UE4SS
  does its own object lookups, and moving them to `ExecuteInGameThread` could run `RegisterHook` inside `script_hook`
  with the ProcessEvent method).
- 0.2.2 fixes what a four-part review of 0.2.1 (its fixes, UE4SS API and engine, logic, tests and docs, each finding
  checked by a second reviewer) confirmed or found likely: a game FOV write as the camera is moved, and moves while
  paused with a lens limit; a cap at a landing's mode change hidden by the distance check, which could stop hops from
  building speed; a moving platform's motion in the distance check; `bStayBasedInAir` keeping a listener's change; a
  cut to a `MaxWalkSpeed` the game had just written; blend waits counting paused time and staying off after a long
  blend; F8 with the mod off, an unsupported character, repeated presses or after the mod turned itself off; refreshes
  and rescans on the same frame after first person starts again. Not tested in the game yet.
- 0.2.3 fixes what a three-part review of 0.2.2 (camera, movement, main code with tests and docs, each finding checked
  by a second reviewer) found, all minor: a game FOV blend easing in as the camera moved, learnt as a lens limit; the
  game's FOV at a re-attach while paused; walking off a moving platform taken for a speed cut, and the platform's
  velocity read after the move instead of when the mod wrote; F8 never reporting after the mod turned itself off and a
  new character came, and skipping the rest of a settle when the mod was switched off; the refresh stagger drifting
  with uneven frame times and after the movement alone started again; two tests that only passed at one frame phase.
  Not tested in the game yet.
- 0.2.4 fixes what a two-part review of 0.2.3 (camera and main code; movement with tests and docs; each finding checked
  by a second reviewer) found, all minor, and one older bug it noted: hopping on a moving platform gained the
  platform's speed at every hop (the velocity is now taken relative to the platform at a landing); a long frame walking
  off still ground just after a moving platform taken for a speed cut; a test of the landing cap that didn't check the
  speed; the game's own jump in the fake, which added no platform velocity; and the FOV kept during learning, now
  documented. Not tested in the game yet.
- 0.2.5 fixes what a review of 0.2.4 (one reviewer, each finding checked by a second) found, all minor: a pause on the
  frame of a landing on a moving platform, or the frame after it, lost the landing, so that hop regained the
  platform's speed; `docs/TESTING.md` promised you stay on your spot hopping on a platform, which needs the game to
  report the platform's velocity (now a question, with F8 on the platform, whose report shows the base, its velocity
  and the game's platform flag); the hop lines with `bStayBasedInAir`. Not tested in the game yet.
- 0.2.6 fixes what a review of 0.2.5 (one reviewer, each finding checked by a second) found, all minor: a pause or
  unpause from the controller's own input, which Unreal runs differently from what `IsGamePaused` says in that frame
  (now told from the world's clock), gave a false input-leak warning after it and could make the game camera take a
  lens limit for the game's FOV; the status line's "per jump -0 u/s"; and, noticed by the second reviewer, hopping in
  place on a moving platform fell a little more behind at every hop.

What these versions did that a rule now prevents, by the rules' sections in `CLAUDE.md`:

- Movement: from 0.2 to 0.2.3 each hop on a moving platform added the platform's speed again; 0.2.4 and 0.2.5 added
  the braking back on the velocity relative to the platform, so hopping in place on a moving platform fell a little
  more behind at every hop (0.9 m in a minute at 60 fps); 0.2.1 already counted a platform that reports no velocity
  in KeepSpeed's check.
- Camera: 0.1 waited for `MainCamera:IsActive()`, which is probably never true in E33, and 0.2 read
  `out.MainCamera_0`, the dump's name, which UE4SS never fills. With the game's camera, 0.2.1 took the first FOV
  reading after a move as the mod's, so a game FOV write as first person started won, and 0.2 took the next reading
  after each re-set, so a game FOV animation of an even number of frames won; 0.2.2 skipped paused frames when it
  judged a reading after a re-attach and lost the game's FOV, took two readings within 0.05° for a lens limit (so a
  game blend easing in as the camera moved was learnt as one, and with a real lens limit the mod then set its FOV
  every frame and put back the lens value), and had an easing blend's last value a frame sooner than 0.2.3.
- When the mod acts: 0.2.4 checked what the mod wrote after a pause and lost the landing then, so that hop on a moving
  platform regained the platform's speed; 0.2.5 went by `IsGamePaused` alone (see "Paused" in `CLAUDE.md`).
- Spreading the work: 0.2.2 counted each refresh's next run from the frame it ran on, and they met within minutes.

## 0.3.0

- Second test in the game (0.2.6), and what the owner asked for after it: see "Status" in `CLAUDE.md`.
- 0.3 adds them, each researched, prototyped and reviewed (each finding checked by a second reviewer) before it was
  built: `BodySounds`, `BodyFollowsHop`, `SlopeLandings` and `SlopeBoosts`, and the F9 speedometer; for strafing,
  `config.lua` explains `AirSpeedCap` and `PhysicsRate`, whose defaults stay Half-Life's (the owner's hops already
  matched it).
- 0.3.0 was reviewed before the owner tested it. A first session went through five areas (sounds, speedometer, docs,
  facing, slopes) and stopped with 26 findings. A second session had every finding checked by a second reviewer, who
  also tried its fix, and added the integration area (2 findings); the second reviewers found 14 more, which were
  checked in turn (8 further findings came out of those checks), and two final reviewers found 6 that all had missed,
  each checked again. Every finding that was checked was confirmed, three of them only as likely; none was refuted.
  The largest: `SlopeLandings` clipped every landing on a slope, where Half-Life sets most of them down untouched, so
  W and Space up any hill ended in a crawl and hopping on the spot on a slope drifted off down it. The owner then gave
  the rule that the movement should be as close to 1:1 with Half-Life 1 as it can be, and recorded a log in
  Half-Life itself (2026-11-11, see "About Half-Life" in `CLAUDE.md`), which shows the landing rule as the published
  descriptions state it.

## 0.3.1, first candidate: what the review of 0.3.0 found

0.3.1 fixes what that review found.

- Slopes: each landing on a slope is decided as Half-Life would decide it, from the locations the mod reads anyway:
  set down with its speed if one of Half-Life's updates ends within 2 units above the floor, clipped only if it runs
  into the floor. It was checked against Half-Life itself (the owner's log: all 100 hops the mod can do land as in the
  log, to the same velocity) and against an independent reference simulation (17,856 of 17,856 landings the same):
  Half-Life's player rests 1/32 unit above the floor, which decided 9 runs in 496; the walking height Unreal keeps (1.9
  to 2.4 cm) is read at the take-off and the landing, since a difference of half a centimetre is what a hop on the
  spot has to spare; a walk off a ledge counts Half-Life's updates from where the fall starts; a landing in a frame
  longer than `MaxSimulationTimeStep`, which was left alone, is decided like any other. A landing that is set down on a
  steep slope no longer slides with what a clip would have left: the held jump runs into the slope and slides with
  nearly all the speed. A slide up a slope ended later and 9 to 13 u/s slower than Half-Life's on 20° (a frame's
  gravity and one more clip before the 180 u/s test); it now runs update by update and ends at Half-Life's ground
  check, and a rise of 180 to 184 u/s starts none. Flights off a slope started one frame of gravity short (about 7 cm
  of 116 at 80 fps), and a stutter during a slide stretched it (the slide's gravity counted at most 0.1 s of a frame).
  A hop the game lands in mid-rise on a ledge was logged as "sliding up it" with nothing clipped: it has its own line
  (the behaviour stays). A jump that the game lands again within the frame it started in (a steep slope taken fast:
  from 575 u/s on 30° at 80 fps) was a hop with a line of its own, on every frame where no slide starts; it is counted
  apart, in the status line and the report. The log and the report tell the kinds of landing apart and count them,
  the report sums what landings on slopes gained and lost and counts the landings by how far their floor leaned (to
  measure how rough E33's ground is), and the slide lines say after how many frames on an edge a slide left a slope
  that stops at a drop (Unreal's capsule may round it, and the flight then starts low: 91 cm instead of 112 at 80 fps
  in a model; not changed before the game shows it).
- Facing: the body was left turned up to 45° past where it headed when it was stopped in mid-air while turning (a
  wall hit head on); it now gets the last heading once. The rule for reading the hop lines' body angle ignored the
  lead's 45° limit; it now says which hops count, and a test holds its numbers. The 144 fps facing test's limit only
  held because its run stopped at 812 u/s (the target's steps are now checked below 700 u/s, with cases at 60 fps and
  at 80 fps with `PhysicsRate` 144 and one for changes between A and D), and the jumps of the body's target at high
  speed were recorded under "Facing". Above `PhysicsRate` frames per second the turn rate behind the body's lead read
  up to 25 % too high in fast hops (the body up to 7° ahead): recorded, and left until the owner's test (fixed in the
  final review, below).
- Sounds and hiding: a character's first start right after the game showed its body again (after a cinematic or a
  battle), or before it did, left that body silent in first person: the mod now asks whether the game has ever drawn
  it, and a character's first start waits up to 5 frames for a body that has never been drawn, whatever the game's own
  flags say; what stays (a body shown later than that, for the first time) is logged with how it ends. A hidden part
  the game moved to another actor kept the mod's hide flag and tick option, and back on the character it read as
  hidden by the game, so it stayed invisible in third person, with the mod off too; such a part is now recognised and
  put back. A new mesh the game had made already hidden, at the address of a part the mod hid, got the mod's tick
  option for good, and a component that can't be hidden, at such an address, got a `SetOwnerNoSee` call and an
  `Error in hiding ...` line (since 0.2.1). The report left out the skinned meshes of actors attached to the
  character, and counted a body the game had set to an option that animates unseen as kept by the mod.
- Speedometer: it stayed hidden after the camera step was turned off by its errors while first person waited; the log
  line before it is made was written only at a session's first build, with nothing after a build that worked, so that
  a later crash would have read as the speedometer's (now a line before every build, and one after the number's first
  value and first show); F9 with the mod off showed nothing and didn't say why; the fallback hook's warning didn't say
  that the mod doesn't run while the game is paused; it gave up once the game had taken it off the screen six times in
  all, however far apart (now only when each new one is taken away within 10 s, 5 times in a row).
- Log and settings: the log's line counts were used up early in a test by `docs/TESTING.md` and nothing started most
  of them again: the log now takes 30 lines of each kind (hops, landings that ran into a slope, landings that kept
  their speed, slides and flights, status lines) and each state text 10 times, F7 starts every one of these counts
  again, the lines about the game's speed cuts and its limiter too (two other counts still run for the session: see
  "Seen and not changed" in `CLAUDE.md`'s "Status"), and the steps say where to press it. Ten seconds in which nothing
  happens get no status line (two thirds of 0.3.0's 30 status lines said nothing but the frame rate). The report
  names every setting that isn't at its default, and F7's line says what the reload changed. A misspelt `true` or
  `false` or a name without its quotes in `config.lua` was read as "not set" without a word in the log; the file is
  now run with globals that note such words, and a warning names each with its line, at load and at F7.
- Docs: `docs/TESTING.md` is rewritten around what the code now does: hills with the landing rule (0.3.0's "65 u/s
  gained per hop going down and 30 lost going up" on a 10° hill only held at about 550 to 700 u/s, and with every
  landing clipped), a slope boost with the speeds by steepness, what a slide looks like and what each `Slope:` line
  means (0.3.0's gave no speeds, suggested gentle slopes and promised a lift-off the owner wouldn't see), F7 before
  each part that needs fresh lines, save and F7 at each change of a setting, and the checks the review asked for (the
  jump sound against the game's own jump, a change of outfit and back, rough but level ground, the edge of a drop,
  hopping on the spot on a slope, the speedometer's two log lines). The README no longer promises jump sounds or speed
  kept at every landing, says what the test's strafing request came to, and says when the speedometer shows. The
  record's statements about what the keys try again (0.3.0's said "F5, F6 and F7 retry everything", which was never
  so), the skin's hiding route (0.3.0's had the skin and face meshes on the `SetHiddenInGame` route) and the ground
  launch's sources (0.3.0's said no public Half-Life source confirms it, which was too strong) were wrong or too
  strong, and were put right.
- Tests: 392 (300 in 0.3.0), among them a step-by-step model of Half-Life's updates that the landings and slides are
  compared with, eleven tests for rules no test could fail, and one that reads the slope boosting table from
  `docs/TESTING.md`. The fake game's flights were lower than Unreal's (it moved a falling character with the speed
  after gravity) and it stood on the floor while `FloorDist` said 2.15: it now falls, walks and lands as Unreal does,
  keeps Unreal's gap, and presses a repeating jump on every frame.

What 0.3.0 did that a rule now prevents, by the rules' sections in `CLAUDE.md`:

- Movement: it wrote a status line every 10 s whenever first person was on or the movement ran (played by
  `docs/TESTING.md` on the fake game, 20 of its 30 status lines said nothing but the frame rate, and the 30th came in
  the game's menu, five minutes after gaining control).
- The log: a jump the game landed again within its own frame was a hop, as in 0.2.6: a hop line a frame that read "0
  fps ... 0.00 s in the air" until the 20 lines were used up, and per-jump numbers shared out among a frame rate's
  worth of empty hops a second. Its counts were 20 hops, 5 landings, 10 slides and flights, 30 status lines and each
  state text 5 times, all for the session: played in the order of TESTING.md, the hop lines ended in step 4, the
  status lines five minutes after gaining control (also while paused), the slide lines with the first line of the
  first rough slope, and after four dialogues, battles or presses of F5 or F7 the log no longer said that first person
  or the movement came back on.
- Facing: it wrote nothing below 100 cm/s, so a stop in mid-air while turning left `InAirRotation` at the led target
  and the body turned (about 30° past where it headed in the fake game).
- Slopes: it clipped every landing, with the fall at the end of the landing's frame, which is Half-Life's collision at
  each one: from a run that took 36 u/s at every hop up a 10° hill (a crawl within 4 s) and gave 55 or more at every
  hop down it, and hopping on the spot on a slope drifted off down it; it left a landing in a frame over
  `MaxSimulationTimeStep` alone; it started a slide from a rise of 180 u/s; it clipped a landing that Half-Life sets
  down on a steep slope and slid with what the clip left, so the best of Half-Life's slope boosts were missing; it
  left a long frame's gravity out of a slide (a stutter made a slide run on too far and too fast: 3.5 m further after
  one frame of 0.3 s in a slide entered at 800 u/s); a flight off a slope started one frame of gravity short (about 7
  cm lower at 80 fps and 19 cm at 30 fps), and off the end 4 and 7 cm low; its slides took a whole frame's gravity off,
  clipped again and compared with 180 u/s, so they ended later and 9 to 13 u/s slower than Half-Life's on 20°; it
  logged a landing in mid-rise as "sliding up it" with nothing clipped. Its fake game moved a falling character with
  the speed after gravity, kept its height in the frame it walked off, and stood on the floor itself while `FloorDist`
  said 2.15 (the mod's jump topped out at 40.6 to 44.4 units instead of 45), and it pressed a repeating jump once, so
  nothing could show a mod that held the game's jump back less often than on every frame of a slide.
- Camera: a hidden part the game moved to another actor kept the mod's flag and tick option and, back on the
  character, read as hidden by the game itself, so it stayed hidden when first person ended, invisible in third person
  with the mod off too, until the game made it anew; it compared a known part's names at once only when the flag read
  false, so on 3 of 4 passes it called `SetOwnerNoSee` on another component at a destroyed part's address and logged
  `Error in hiding ...` (nothing was written); `BodySounds` asked whether the body was drawn in the last second only,
  so a body the game had hidden for longer (a cinematic, a battle) and shown again within two frames before a
  character's first start, or only after it, read as never drawn, and the character stayed silent until first person
  next started with the body in view; it gave a new mesh the game had made already hidden, at a destroyed part's
  address, the mod's tick option 0 for good; the report left out the skinned meshes of actors attached to the
  character, so `kept animating N` could count more parts than were listed.
- Speedometer: its first line was a `log.first`, so only a session's first build had it, and nothing followed a build
  that worked: once the status and hop lines had run out the line stayed the log's last for minutes, so a later crash
  for any other reason read as the speedometer's; a camera step turned off during a dialogue, or while the game
  showed another view target, left the speedometer hidden until F5 twice or F7, and the report went on giving that
  reason; it stopped after 5 widgets taken away in all since the last retry, however far apart.
- Report: it couldn't tell that `BodyFollowsHop` was off.
- Reading config.lua: a misspelt word kept its setting's default without a word in the log, and a list ended at that
  entry (`JumpKeys = { SpaceBar, "MouseScrollDown" }` gave no jump keys at all).
- About the game: the README promised jump sounds.

## 0.3.1: what the final review found

A final review of the 0.3.1 candidate, before the owner's test: twelve areas (landings, slides, the rest of the
movement, regressions against 0.3.0, the camera, the main code, the UE4SS API, the tests, the player docs, the
developer docs, Half-Life against the owner's log, and traces through the code), 52 findings, every one checked by a
second reviewer: 50 confirmed, 1 refuted (the speedometer's count of removals, whose two wordings count different
things), 1 not worth changing (the one line a session about a tick option the game wrote, a choice); none high, 11
medium. The fixes were built in four lanes (movement A and B, the camera and settings, the tests), merged, and the
docs written last. The figures are in `docs/MEASUREMENTS.md`.

- Strafing (medium): each Half-Life update gets the view of its own time. A frame's turn was shared out evenly among
  its updates, so at frame rates other than 50, 100 and 200 a steady turn reached them unevenly, and air strafing
  gained less than Half-Life's: holding one key 1 to 6 % less at turns of 110 to 200°/s, up to a third less at
  300°/s, and with A and D about a tenth less per hop at 60, 80 and 144 fps. The body's lead takes the heading's turn
  over the updates' time, so its target no longer jumps by up to 25° from frame to frame, and the body turns evenly
  with the view. `PhysicsRate` 144, 200 and 250 now add about 10, 15 and 20 % with A and D (the docs said 15, 24 and
  28 %, measured while the even split cost the default rate more), and `AirSpeedCap` 35 and 40 about 17 and 33 % (the
  docs said 20 and 40).
- Running down a slope (medium): without the jump key, Half-Life's player leaves the ground where the floor falls away
  further than its ground check reaches, and leaps down the slope without friction; the mod walked and braked (from
  700 u/s on 20° to 0 within a second). It now leaves the ground as Half-Life does, at any frame rate, also at a run
  on slopes over 31.5°.
- Slides (medium and low): a slide over a top that rounds off ended on the floor where Half-Life flies off; the slide
  now follows Half-Life's path above the floor and flies on where it ends out of reach. At `PhysicsRate` 200 and 250 a
  slide just over the threshold slid on where Half-Life's player is on the ground an update later (it rests 1/32 unit
  off the slope): a move now clips only where it reaches the slope. On a moving platform the "flew off the slope" line
  gave its speed relative to the platform, its landing line over the ground; both now give it over the ground.
- Landings (low): a walk-off's fall starts with the half update of gravity Half-Life's update that walked off ended
  with (−4 u/s at 100); with `bStayBasedInAir`, a landing on a platform that moves up or down is decided with its
  vertical travel; the heights in the landing lines read to 0.01 where 0.1 would read 2.0, so a line never says 2.0 is
  both in and out of reach; a frame over 0.1 s counts in full in the hop lines' air time, fps and turn rate and in a
  flight's landing line; an unreadable floor is reported after 30 reads in a row whatever happens in between (a
  take-over started the count again). Ten of 25 one-line breaks of the landing rule passed every test (medium): the
  tests now hold a moving platform's travel, a `FloorDist` that can't be the walking gap, a stutter in mid-hop, a floor
  below the plane the hop came down on, a clipped rise of 180 to 184 u/s at a landing, and `PhysicsRate` 0 with uneven
  frames and at 240 fps.
- Camera and body (low): an error in the walk of the attached parts before a character's first start turned first
  person off, where 0.3.0 only lost hiding the body (it now costs only the wait, and a pass whose walk failed no longer
  counts as the first); a kept mesh the game moves while it stays attached, and hides, kept tick option 0 for good on 3
  passes of 4 while the log said it was put back; a skin's part hidden in game while still its skin actor's stayed
  hidden in every view after the game moved it into the character; the report didn't count the hidden parts the game
  moved (`CLAUDE.md` said it did); and tests for rules none held (the wait for the body for the next character, which
  meshes the wait is for, a new mesh at a kept body's address that the game hides).
- Settings and restoring (low): a `config.lua` that gives no settings (empty, only comments, a table not returned) got
  no warning; a value the game wrote in the frame before the mod handed back was overwritten at the release (in 0.3.0
  too).
- Speedometer (low): tests that couldn't notice a use of the freed widget; `CLAUDE.md`'s rate for endless remakes was
  five times too low (it is 24 to 29 builds a minute for a game that leaves each widget 10 s and takes the next four
  at once).
- Tests (medium and low): the slope boosting table test held 6 of the table's 20 numbers and hardly any of the docs'
  quotes; it now holds every number, every row in the fake game and the quotes word for word, and it found the table's
  "every hop" speeds 5 u/s too low on 25° and 30° (600 and 575 became 625 and 600) and 15°'s "some hops" speed 25 u/s
  too high (775 became 750). Seven tests passed only at the suite's frame phase and eight only because the automatic
  report came after the window they counted in; none does now. A test of the lead's restart couldn't fail; `t.near`
  passed a NaN, and so did the running maximums; the shipped `config.lua` test read the file only while
  `test_settings` ran first; loading the mod for every game took a quarter to two fifths of the suite (now compiled
  once: about 20 s by the clock against 54 s on WSL's mount of the Windows disk). Tests: 392 to 418, and 422 after
  the checks of the merged tree (below).
- Docs (medium and low): `CLAUDE.md`'s Git rule and the README said `main`, where 0.3 lives on `wip-0.3` (a fact noted
  under the rule, the owner's answer pending); `CLAUDE.md` had grown to 2.3 times its size (its history and figures
  moved here and to `docs/MEASUREMENTS.md`); `docs/TESTING.md` asked for speeds the owner hadn't reached without a way
  there (a shortcut, `MaxSpeed = 800` with `InputSpeed = 800`), sent him once too often between the steep slope and
  the hill, and told F9 with the mod off half of what it does; the README named a UE4SS build that had left the page
  and didn't know UE4SS 4.0, said `PhysicsRate` from 135 on never changes a landing's speed on rising ground (not where
  the ground turns upward), and called `PhysicsRate` 144, 95, 98 and 101 "Half-Life at that frame rate" (true of
  today's Steam version, not of the 2005 one, whose updates are whole milliseconds); a `probes/` folder that a review
  leaves in its tree was neither ignored by git nor left out of `luacheck .`; and several of `CLAUDE.md`'s sentences
  were wrong or out of date (a jump on the step a slide ends on, the debug library, a file whose `return` is lost, the
  `PhysicsRate` 0 height, two tests called older, what the tests read of `config.lua`).
- After the merge, two checks of the merged tree (its code and tests; its docs) found 14 problems, each then checked
  again and fixed where it held. A leap down a slope came down without the half update of gravity Half-Life's leaving
  update ended with, so its landings that ran into the slope gained 1 to 2 u/s less than Half-Life's and within a few
  leaps one landed the other way (medium; 190 of 360 runs down even slopes had their first six take-offs within 0.3
  u/s of the reference, 350 now). The tests that the checks of three player-docs findings had made part of their fixes
  were in no tree (medium): the shortcut to the slope boosting speeds, what `PhysicsRate` adds to air strafing, and F9
  with the mod off. The rest were sentences of `CLAUDE.md` that the split had changed or dropped (which keys try first
  person again, the pause fallback's warning, five verdicts and limits), a formula's numbers, the speedometer's drop at
  a slide, the 2005 version at 80 fps, `docs/TESTING.md` step 5 changing two settings at once, a test comment naming
  a review folder, and the measurement behind "about every second landing" down a hill.
- Not changed: see "Seen and not changed" in `CLAUDE.md`'s "Status".
