# Measurements

The figures that the rules in `CLAUDE.md` rest on, by the sections of that file. They were measured in the fake game
(`tests/fake_game.lua`) with probes, and against reference simulations of Half-Life's updates written from published
descriptions; the probes and the references stayed in the reviews' scratch folders and are not in the repository.
Nothing here was measured in the game itself. Each part says what it was measured on:

- **0.3.1**: the merged 0.3.1 tree, measured in the final review of 0.3.1 (November 2026);
- **0.3.1 candidate**: the first 0.3.1 candidate, before the final review's fixes; where the final review changed
  nothing that the figure depends on, it says so;
- **0.3 review**: during the review of 0.3.0.

Speeds are in Half-Life units per second (u/s), `PhysicsRate` 100 and the default settings unless a line says
otherwise. "The reference" is the final review's model of Half-Life's updates (with Half-Life's ground move, slide
move and edge friction), started from the same state as the mod.

## Movement

**Each update gets the view of its own time** (0.3.1, against the 0.3.1 candidate). With a frame's turn shared out
evenly among its updates, as in the candidate, a steady turn reached the updates unevenly: 1.25, 1.25, 1.25, 0.62,
0.62 updates' worth at 80 fps; 0.83 four times and 1.67 at 60 fps; 1.39 and 0.69 at 72 and 144 fps; 1.00 only at 50,
100 and 200 fps. Now every update gets 1.00 at every frame rate.

Through the whole mod, Space and D held, the view turning steadily, 6 s of hops from 320 u/s:

| Turn | 0.3.1, at 50 to 144 fps and with frames of 12.5 ms ±30 % | The candidate at 80 fps | The candidate at 60 and 120 fps |
| --- | --- | --- | --- |
| 110°/s | 613.9 u/s | 609.0 | 608.5 |
| 150°/s | 686.5 | 677.2 | 676.0 |
| 200°/s | 748.1 | 731.9 | 721.2 |

(The candidate gave 0.3.1's speeds at 50 and 100 fps.) Against Half-Life over 0.6 s, from 320 to 700 u/s at 110 to
344°/s, at 60 to 240 fps and with uneven frames: 0.3.1 gains 100 % of Half-Life's in every case; the candidate gained
65 to 90 % of it from 500 u/s at 300°/s and 22 to 70 % at 344°/s. With A and D swinging (the owner's way), the
candidate gained about a tenth less per hop than 0.3.1 at 60, 80 and 144 fps (see "Strafe gain").

## The log

**What a hop is** (0.3.1). The lowest speed from which the mod's jump lands again within its own frame, hopping up a
slope with Space held and both slope settings off, in steps of 5 u/s: 580 u/s on 30° and 400 on 40° at 80 fps, 545
and 375 at 60 fps, 675 and 465 at 144 fps (the formula in `CLAUDE.md` gives 575 and 396 at 80 fps). Just below that
speed the jump lands one to three frames later (0.3.1 candidate, at 80 fps on 30° with both slope settings off: 40 hops
a second from 510 u/s, 27 from 480, 20 from 460; on 40°, 20 a second at running speed). With `SlopeBoosts = false`
alone, on 30° at 80 fps from 600 to 1000 u/s, 0 to 4 of the 10 to 24 jumps of the first second land again in their
frame, and the speed is 370 to 450 u/s after it (0.3.1 candidate).

**Line counts.** Without F7, five minutes of strafing hops leave 221 lines, 145 of them the automatic report, at 60
and at 30 fps (0.3.1). A play of `docs/TESTING.md` in the fake game, as the 0.3 review proposed the text (a typical
owner at 80 fps: 24 minutes, 326 hops, 16 presses of F7): every part's lines were in the log but 27 hop lines on the
way between step 7's activities and to the platform: 299 of 326 hop lines, 84 of 84 landing lines, 28 of 28 for
slides and flights, 59 of 59 status lines, none of which said nothing, 80 of 80 state lines, 1898 log lines in all;
an owner who does twice as much of everything loses the hops after the 30th of a part. In that play a hill hopped
down had 12 landings that all kept their speed, and hopped up 13 that all ran into it (from standing with W and
Space pressed together, at the air cap's 30 u/s, every landing going up a 10° hill ends 2.0 units above it and loses
15 u/s). The text has more parts since, each with its own F7, and wasn't played again as a whole; the reordered last
part of step 9 keeps every hop line at 60, 80 and 144 fps with 3 to 13 landings each way on the hill (0.3.1).

## Facing

**The body against the view and the heading** (0.3.1, D held, the view turning 180°/s for 8 s, up to 838 u/s):

| Frame rate | Target's largest step in a frame | Body off the heading, at most | Body's turn against the view's, at most |
| --- | --- | --- | --- |
| 100 fps | 1.80° | 1.58° | 0.04° |
| 60 fps | 3.60° | 2.91° | 0.12° |
| 72 fps | 3.60° | 2.88° | 0.12° |
| 80 fps | 3.60° | 2.46° | 0.10° |
| 120 fps | 1.80° | 1.96° | 0.06° |
| 144 fps | 1.80° | 1.98° | 0.05° |
| 80 fps, `PhysicsRate` 144 | 2.50° | 2.35° | 0.09° |
| 80 fps, 250°/s | 5.10° | 5.04° | 0.16° |

The 0.3.1 candidate's target jumped by up to 19.5° in a frame at 60 fps, 12.2 at 72, 21.0 at 120, 11.4 at 144 and
25.4 at 80 fps with `PhysicsRate` 144 (12.5° at 80 fps turning 250°/s, with the body up to 9.5° off the heading). A
view that turns in steps of 125 a second (a mouse that reports that often) makes the target jump by up to 18.0, 20.4
and 29.9° at 60, 80 and 144 fps; the body's turn in a frame then stays within 1.07, 0.81 and 0.83° of an even turn,
and at most 3.2, 3.3 and 2.9° off the heading (0.3.1).

**The hop lines' N** (0.3.1, third person, 20 hop lines a case):

| | 150°/s | 200°/s | 240°/s | 300°/s | 360°/s |
| --- | --- | --- | --- | --- | --- |
| D held, 80 fps | 0 to 0 | −1 to 0 | −1 to 0 | −13 to −9 | −24 to −18 |
| D held, 60 fps | −2 to 0 | −2 to 0 | −2 to 0 | −12 to −9 | −24 to −20 |
| D held, 144 fps | −1 to +1 | −2 to +1 | −3 to −1 | −15 to −11 | −27 to −22 |
| A and D every hop, 80 fps | −1 to +1 | | −1 to 0 | −9 to −7 | −18 to −15 |
| A and D every hop, 60 fps | −2 to +1 | | −2 to +1 | −10 to −6 | −20 to −13 |
| A and D every hop, 144 fps | −2 to +1 | | −4 to +1 | −13 to −6 | −23 to −14 |

At 150°/s and 80 fps a run's first hop, whose lead starts from nothing at its take-off, reads −2 at one settle length
in three (31 lengths from 185 to 215), the other 19 hops 0 or −1; at 300°/s −9 to −13 at every length (0.3.1). The
0.3.1 candidate read −7 to 0 at 240°/s and 80 fps.

**Trials of the 0.3 review, not measured again.** Averaging the rate over 20 to 50 ms kept the body within about 0.5°
of an even turn (and up to 0.65° off against an unevenly turning view), but left it 2.5-5° from the heading on average, instead of 1.4°, in the 0.2 s after each change
between A and D at 180°/s, and added up to 2-3 to the hop lines' N. Without the one write of the last heading after a
stop (see `CLAUDE.md`), the body stayed about 30° past where it headed after a wall hit head on in mid-air with the
view turning 180°/s at 80 fps (0.3.1 candidate: −0.1° with it; 31° with one paused frame right after the wall).

## Slopes

### The landing rule against Half-Life

0.3.1 candidate; the final review's changes don't touch hops with the jump key held, and its walk-off change is below.

- The owner's Bunnymod XT log, fed its update lengths as frame times (`PhysicsRate` 0): the mod lands 100 of the 100
  hops it can do (no duck, no move key, no wall) as the log has them, the same kind, the same velocity after it (0 to
  77.23 u/s after updates of 11 ms; 0 to 78.05, to 160.69, to 250.40 at 31 fps), decided at the same update, set down
  from the same height within 0.006 units. At `PhysicsRate` 100 and 60, 80 or 144 fps, 79 of the 79 whose updates are
  all 10 ms (on the spot: 67 updates, 0.220 units, never clipped; down the ramp at 90.47 u/s: 74 updates, 0.946 units,
  speed kept), and the log's hop from the level floor onto the ramp at 498 u/s, flown without its strafe key, is set
  down from 1.59 units after 42 updates as in the log.
- Two reference simulations of the 0.3 review give all 138 of the log's landings they can fly (ducked hops with the
  floor lowered by what the log shows: 18 units on the level floor, 17.0 on the ramp). Hop by hop against the second,
  which has the 1/32 unit: 17,856 of 17,856 landings the same kind with the same speed after it (2 to 20° up and down,
  320 to 800 u/s, 60 to 144 fps, `PhysicsRate` 100, 144 and 0), slides included with their end speed within 0.01 u/s.
  The first has no 1/32 unit and differs in 9 of 496 runs, each first at a landing within 0.03 units of the other
  kind; the log has no landing that close.
- With air strafing the mod and a reference can't be laid over each other hop for hop (the mod's hops are a frame or
  two longer); the shares and speeds agree within what seeded draws give. The log's four strafed hops were flown by
  the references, not by the mod's own air strafing.

**Walk-offs** (0.3.1). 408 walk-offs from a level ledge onto slopes of 30° and 40°, up and down, drops of 120 to 220 cm,
at 60 and 144 fps, against the test's model of Half-Life's updates (the update that walks off a level ledge ends at
−4.0000 u/s with 10 ms updates, −2.8000 with 7 ms, in the reference): 404 land as the model has them; the other 4 by
Half-Life's resting height (two set down 1.998 and 1.9998 units up in the model run into the slope in the mod, and two
whose update ends 0.0003 units into the floor in the model are set down 0.0045 above it in the mod). The 0.3.1
candidate, whose fall started at 0 u/s, landed 228 of the 408 as the model.

**`PhysicsRate` 0** (0.3.1). Against the step-by-step model, 8 slopes, 4 speeds and 8 frame rates from 100 to 250 fps,
4 landings each: all 1024 landings the same kind and speed; 388 of the 999 set down name a height in the hop line more
than 1/32 unit off the model's, by up to 1.99 units (the worst: 165 fps, 15°, 576 u/s: the line says 0.0, the model's
player was set down from 1.985). The next hop's resting height differs by 0.0305 units at most (360 landings at 144 to
250 fps).

**A bend where the ground turns upward** (0.3.1). W and Space held at 80 fps, the bend at 96 places along the first hop,
3 hops each; landings that changed the speed out of 96, the mod against a model of Half-Life's updates over the two
planes:

| | `PhysicsRate` 100 | 135 | 144 | 200 | 250 |
| --- | --- | --- | --- | --- | --- |
| level onto 5°, 320 u/s | 24 | 2 | 0 | 0 | 0 |
| level onto 10°, 320 u/s | 23 | 5 | 2 | 0 | 0 |
| level onto 10°, 600 u/s | 27 | 11 | 8 | 0 | 0 |
| level onto 15°, 400 u/s | 26 | 7 | 3 | 0 | 0 |
| level onto 20°, 400 u/s | 27 | 13 | 10 | 0 | 0 |
| 10° down onto 10° up, 400 u/s | | 21 | 24 | 3 | 0 |
| 5° onto 20°, 400 u/s | | 4 | 3 | 0 | 0 |

The mod and the model agree in every case but one: at `PhysicsRate` 144, 5° onto 20° at 400 u/s, the bend 99.5 % of
a hop ahead, the mod clips the landing (290 u/s) where the model sets it down (the last update began 3.19 units up):
the mod extends the steeper plane back under the update (see "What the mod can't tell" in `CLAUDE.md`). The hops along
the hill after the bend keep their speed from 135 on.

**Hopping on the spot** (0.3.1, 10°, Space held for 8 s, at 80 and at 144 fps): nothing moves at `PhysicsRate` 60, 72,
90, 99, 100, 110, 120, 125, 135, 144, 200 and 250; at 80 and 95 the character moves 334 units with one landing run
into the slope (then 46 u/s), at 98 1411 units with five (242 u/s), at 101 928 units with three (141 u/s). At 100 a
hop on the spot takes 67 updates and ends 0.22 units above where it started; at 144, 96 updates and 1.11 units. At
100 it stays put (0.0 units in 20 s) on 2° to 40° in steps of 5° at 60, 80 and 144 fps. The 2005 version's whole
milliseconds as `PhysicsRate`: its 12 ms at 80 fps (1000/12) moves 331 units with one landing run into the slope, as
80 does, and its 9 ms at 101 fps (1000/9) stays put (the 10 ms of 95 and 98 fps is 100).

**The fake game's ground** (0.3.1 candidate). A hop on level ground lasts 3 ms longer than Half-Life's 0.671 s (98
frames at 144 fps, not 97): the fake, like Unreal, lands the character when it touches the floor, and stands it 2.15
cm above it. A jump into a slope lands in its own frame only once the slope out-rises the jump's first frame and the
gap as well. Before 0.3.1 the fake moved a falling character with the speed after gravity, kept its height in the
frame it walked off, and stood on the floor itself while `FloorDist` said 2.15 (the mod's jump topped out at 40.6 to
44.4 units instead of 45).

### What hills do

0.3.1 candidate, `PhysicsRate` 100, the same at 60, 80 and 144 fps. Hops with W and Space only aren't touched by the
final review's changes; its strafing change makes air strafing gain a little more at frame rates other than 100, so
the strafing figures may now be a little higher.

- A landing that runs into the hill changes the speed from a run by −9 u/s on 2°, −21 on 5°, −36 on 10° going up, and
  +10, +25, +55 going down, +123 down 20° (more going down the faster you go: +70 down 10° at 800 u/s, +179 down 20°).
- With hops that differ a little, these landings in 96 run into it: up 2° 21 at 320 u/s (17 at 576, 15 at 800); up 5°
  14 (7 at 576 u/s, none at 800); up 10° 3 (none from 576); up 20° none; down 2° 26; down 5° 31; down 10° 36 (49 at
  800 u/s); down 20° 46 (62). At 144 no landing of a plain hop along an even rise runs into it, and going down 2 to 14
  in 96 do on 5°, 11 to 28 on 10°.
- With W and jump only on an even slope: up 10° from 320 u/s 284 after one landing; down 2°: 339 after two; down 5°
  from 576: 604 after one; down 20° from 576: 730, 901, then it stays; down 5°, 10° or 20° from 320: nothing.
- Air strafing (the view swinging 85°/s, about 26 u/s gained a hop on level ground), from 320 u/s: 2 to 3 landings in
  10 clipped going up 2° or 5°, none up 10°, 3 in 10 down 2°, 6 in 10 down 5°, 7 in 10 down 10° and 20°; after 10 s
  647, 588 and 679 u/s going up 2°, 5° and 10° against 679 on level ground, and 716, 856, 1095 and 1483 going down 2°
  to 20° (the 0.3 review's reference with the same player: 653, 571, 681; 719, 861, 1039, 1490). With A and D in
  turn, swings of 0.335 s at 85 to 150°/s, 10 s from 320 u/s at 80 fps and 6 starts each (0.3.1): 34 to 50 % of the
  landings run into the hill going down 10° (fewer the faster the turn), 35 to 40 % down 5°, 50 to 55 % down 20°, 0
  to 2 % up 10° and 9 to 16 % up 5°. With this strafer the 0.3.1 candidate's code gives similar shares (32 to 40 %
  down 10°, by the check of the merged docs), so the gap to the 7 in 10 above comes from the strafing, not from the
  code. The player docs' "about every second landing" down 10° is the slow-turn end of this.
- Hopping on the spot at `PhysicsRate` 80: 334 units in 8 s on 10°, then 46 u/s (also 0.3.1, above). Hops along a
  slope that rises under them by 68 to about 220 u/s climb in short hops (0.21 s each at 503 u/s on 20°); on 20°
  strafing hops settle at about 570 to 610 u/s.

### Slides

**Where a slide ends** (0.3.1 candidate; at `PhysicsRate` 100 the final review's slide code gives the same on a plain
slope). A slide ends at the reference's speed within 0.01 u/s at `PhysicsRate` 100, 144, 200, 250 and 0. The 0.3.0
slide took a whole frame's gravity off, clipped again and compared with 180 u/s, so it ended later and 9 to 13 u/s
slower than Half-Life's on 20° (491 to 495 u/s, where the reference has 503 to 505).

**Just over the threshold** (0.3.1). Above about 160 updates a second the update after a clip can fall short of the
slope (one update's gravity closes less than the 1/32 unit; at 144 on slopes over about 36°), so a slide that starts
within one and a half updates of gravity of 180 u/s, a clip rise of 182 to 186 u/s at `PhysicsRate` 200 and 181.6 to
184.8 at 250, is on the ground again an update or a few later. Run-ins without keys onto endless slopes of 5 to 40° rising 180.3 to about 220 u/s,
`PhysicsRate` 100, 144, 200 and 250 at 60, 144 and 250 fps, the reference from the mod's slide start: 531 slides. No
slide end differs from the reference's by more than 0.01 u/s, but for two exact ties at 180 u/s (30° at 250 fps,
`PhysicsRate` 100 and 144, also in the 0.3.1 candidate). The candidate's ended up to 36.7 u/s off at 200 and 250 (8°
at 250 fps and 250 updates a second: 1291.8 u/s where the reference is on the ground at once at 1328.5; 25.4 u/s at
200 and 60 fps).

**Over a top that rounds off** (0.3.1). 240 slides onto rounded tops (20° and 30°, a ramp of 160 units, then a top of
radius 200, 400, 800 or 2000 units in faces of 2°; 650 to 1400 u/s on 20° and 500 to 1100 on 30° in steps of 75; 60,
80 and 144 fps), the reference started from the mod's first slide update: the mod and the reference agree on whether
the slide ends in a flight in 237 (the 0.3.1 candidate 203, which never flew at a slide's end: where it walked on, the
reference flew 2.6 to 33 units high; without the take-back of the clips 235). The 3 left: twice (20°, radius 800, 950
u/s at 60 and 80 fps) the mod flies 7.1 units where the reference's path peaks 1.7 to 1.8 units up; once (radius 2000,
1325 u/s at 60 fps) it walks where the reference flies 3.6 units. Where both fly, the mod's flight tops out 3.4 units
lower on average (from 6 higher to 18.8 lower): it starts from the floor. On the tests' top (20° for 4 m, then 20 m of
radius in faces of 2°) the mod flies from 950 u/s at 60 and 80 fps and 900 at 144 (the reference: 950, 925, 900); run
into at 1000 u/s at 80 fps it logs "flew off the slope at 905 u/s, rising 178 u/s: the slide ended 5.8 units above
it, out of the ground check's reach of 2", tops out 14.0 units above the floor and lands 0.40 s later.

**More frame rates and rates over a top** (0.3.1; the matrix of the check of the merged code, re-run on 0.3.1: 20° and
30°, the ramp, then a top of radius 200, 400, 800 or 2000 units, speeds in steps of 150 u/s, `PhysicsRate` 0, 60, 100,
144 and 250 × 30, 60, 100, 144 and 300 fps, for `PhysicsRate` 0 the reference at one update a frame). 1051 of 1076
slides fly or walk on as the reference does (the 0.3.1 candidate 920). Of the 25 left, the one of the two that flies
goes up at most 4 units in 9, 4 to 8 units in 6, and 9.2 to 16.2 units in 10: 6 at 30 fps (`PhysicsRate` 0, 60, 144
and 250), 3 at 60 updates a second (`PhysicsRate` 60 at 60 and 144 fps, 0 at 60 fps) and 1 with `PhysicsRate` 250 at
60 fps; none at `PhysicsRate` 100 above 30 fps. Traced at 144 fps with `PhysicsRate` 60 (20°, radius 400, 800 u/s,
where the reference flies 14.6 units and the mod walks on): Half-Life's path is up to an update (about 11 units)
behind the character, and at the top's bends the frame's update and the floor measured under the path already use the
face under the character, so the measurement sets `slide.h` to 0 twice and the clips the path would still make on the
face before the bend are lost; the slide ends at 681 u/s, rising 181 u/s, 1.0 unit above the floor. A trial that kept
the old face for a path behind the character fixed about as many slides as it broke.

**The 8 units** (0.3 review and 0.3.1 candidate). A slope with bumps of ±4° in 1 m segments is slid up without a launch
at up to 800 u/s at 60, 80, 144 and 240 fps; with 7 units the slide launched at 240 fps and, depending on how it
enters the slope, at 144, and with 6 units from 80 fps up. Faster, a slide flies off bumps and lands again, a few
times on the way up: on 20° and 25° from about 960 to 1000 u/s at 60 fps, 920 at 80, 880 at 144 and 840 at 240 (on
15° from 1000 to 1040). 8 units stand for about 10 units of real rise at 60 fps, 9.4 at 80 and 8.5 at 240. Bumps of
±6° or ±8° launch from about 600 to 800 u/s. Where a slide's rise is down to 180 u/s just past a bump, the reference's
path is out of reach and flies on for 0.01 to 0.03 s (on the ±4° slope at 800 u/s, once at 60, 80 and 144 fps and
twice at 240, 2.1 to 3.3 units up; 0.3.1), and the mod does too.

**Flights** (0.3.1 candidate). A flight off a slope starts with the rise the slide had (0.3.0 took a frame's gravity
off first: about 7 cm lower at 80 fps and 19 cm at 30 fps where it should top out at 116 cm; now 2 cm high at every
frame rate). Walking off the end, the rise handed over is about half a frame of gravity high: 4 to 6 cm too high at
80 fps and 10 to 13 cm at 30 fps where it should top out at 112 cm. A frame of 0.3 s in a slide entered at 800 u/s:
the slide ends within 0.3 m of where it would have (0.3.0 ran 3.5 m further).

**A ledge's edge** (a model of the 0.3 review, an assumption about the engine). With a 35 cm capsule, a 20° ramp 4 m
long run into at 800 u/s, where the flight should top out 112 cm above the ramp's end: it tops out at 95 cm at 60 fps,
91 at 80 fps and 86 at 144 fps, after 1 to 2, 2 to 3 and 3 to 4 frames on the edge and 18 to 26 cm below the ramp's
line; with a 30 cm capsule 98 cm at 80 fps, with 42 cm 84, and with a 30 cm capsule and a `PerchRadiusThreshold` of 20
it is 113 (106 at 144 fps).

### How fast

**The table in `docs/TESTING.md`** (0.3.1). At the table's "every hop" speeds (1275, 825, 675, 625 and 600 u/s on 10°,
15°, 20°, 25° and 30°), with the slope's foot at 200 places along the hop at 80 fps, every approach slides: 72, 69,
75, 93 and 105 of 200 at the landing, the rest in the hop after it. In steps of 5 u/s (measured on the final review's
tests lane, whose slides are the candidate's; at `PhysicsRate` 100 the merged slide code gives the same on a plain
slope): every approach slides from 1255, 825, 670, 605 and 580 u/s; at 600 u/s on 25° and 575 on 30°, 4 approaches of
200 don't (the foot 98 to 99.5 % of a hop ahead: they land falling 264 u/s, the clip leaves a rise of 182.7 or 183.0
u/s, under the 184 a slide needs, and 392 or 317 u/s, too slow for the hop after it to slide); some slide from 1085,
745, 580, 475 and 385 u/s (on the table's 25 u/s steps 1100, 750, 600, 475 and 400; at 750 u/s on 15° 2 approaches of
200 slide, at 725 none of 400); running into the slope slides from 1076, 737, 573, 481 and 425 u/s; the log's slide
ends read 1042 to 1044, 685 to 687, 503 to 505, 392 to 395 and 315 to 319 u/s. The table had 600 and 575 for 25° and
30°, and 775 for 15°'s "some hops", until the final review: its 25 places along a hop stopped at 96 % of the hop.

**On paper.** A landing that runs into the slope slides from 1058, 706, 530, 422 and 348 u/s (it took off at the foot)
to 1123, 808, 670, 606 and 580 u/s (it falls at the full 268 u/s); the held jump's own first update runs into the slope
from 1499, 986, 726, 567 and 458 u/s; at `PhysicsRate` 144 the run-in speeds are 1069, 732, 569, 478 and 423. A slide
loses g sin θ cos θ a second: 137, 200, 257, 306 and 346 u/s.

**Slides and flights.** Slides start at the landing in about a third to a half of the approaches from the "every hop"
speed on (above), and in 5 to 6 in 10 from 950 u/s on 20° (0.3.1). The rest is the 0.3.1 candidate's, at
`PhysicsRate` 100 on plain slopes, which the final review's slide code leaves as they were. On a long 20° slope a slide lasts 0.15 to
0.74 s and goes 1.9 to 11 m along the ground from 700 u/s, 0.5 to 1.1 s and 7 to 18 m from 800 u/s; on 30°, 0.16 to
0.71 s and 1.4 to 7.7 m from 600 u/s, 0.54 to 1.15 s and 5 to 15 m from 800. Off a 4 m ramp of 20° at 700 u/s the
flight rises 203 to 249 u/s and is 0.51 to 0.62 s in the air, in 4 of 6 approaches (in the other two a set-down
landing's next hop cleared the ramp). On 30° at 600 u/s a set-down landing's jump slides at 564 u/s rising 326, where a
landing that ran into the slope slides at 346 to 426 u/s; both end at 319. With `SlopeBoosts = false`, from 800 u/s
onto 20°: 729 u/s a second later, against 532 sliding.

**The shortcut** (0.3.1, `MaxSpeed = 800` with `InputSpeed = 800` set in `config.lua` and F7 pressed in a running
game, 80 fps). `MaxSpeed = 800` alone runs at 400 u/s (566 with W and D). Both: `Changed: InputSpeed = 800 (was 400),
MaxSpeed = 800 (was 320)`, no warning, 800 u/s after 0.15 s and 1.9 m, the report's `Settings not at their defaults:
InputSpeed=800, MaxSpeed=800`; the shipped file and F7 give 320 again. W and Space pressed together from a standstill
stay at 30 u/s. A 6 m ramp of 20°: running in slides and flies off at 714 u/s, hopping on slides and flies off at 629;
on 30° off at 486 u/s rising 280. A long 20° slope with W and Space held: one slide, then hops at 503 u/s that keep
their speed. With W held and no Space a new slide begins each time one ends: 10 slides in 6 s on 20°, 11 on 30°, 15 on
15°. Running with W down a hill of 14° or more leaps down it (12° or less: no).

### Running down a slope

0.3.1, against the reference from the same speed. 20° from 700 u/s without keys: the leaps take off at 700, 672, 645,
619 and 595 u/s at 30, 60, 80, 100 and 144 fps, the reference at 700, 672, 645, 619, 595 and 571 (its sixth falls just
inside 3 s: the mod's cycle is a frame or so longer, Unreal landing later); in the air 96 to 98 % of the frames; each
flight 0.64 s long at 700 u/s. 10° from 1300 u/s: 1300, 1248, 1198, 1150; 15° from 800: 800, 768, 737 (the same as the
reference). 20° from 800 u/s with W: 800, 858, 824, 884, as the reference (two landings clipped). `PhysicsRate` 144,
20° from 1000 u/s at 60 and 80 fps: 1000, 972, 945, 1027, as the reference; `PhysicsRate` 250, 30° from 1600 at 144
fps: 1600 and 1574, the same. (As first merged, without the leap's half update of gravity at its landing: 857, 823,
881 and 1026; see below.) A run at 320 u/s with W down 35° at 80 fps: in the air 96 % of the time, the reference
98 %. Hopping down 20° from 650 u/s and letting go of Space at 2 s: 624 and 575 u/s at 3 and 4 s at 60, 80 and 144
fps, as the reference; 15° from 850: 816 and 752; 10° from 1200: 1311 and 1208.

**The leap's landing against the reference** (0.3.1; the probes of the check of the merged code, re-run after its
fix). Half-Life's update that leaves the slope moves straight ahead and ends in the air, c/rate above the slope (c:
how fast the floor falls under the velocity) and falling g/(2 · rate) (the reference model, 30° from 600 u/s: 3.500
units up, −4.000 u/s); the mod's flight starts from the floor at 0 u/s. On an even slope the heights differ by
(c − g t/2)/rate, nothing where they come down (t = 2c/g), so the last update above the slope is as high as
Half-Life's (within g/(2 · rate²)) and the landing comes out the same kind, but Half-Life's player comes down
g/(2 · rate) faster (4 u/s at 100), and a landing that runs into the slope clips that fall: the leap keeps that half
update and its landing takes it off the fall. The take-offs to 3 decimals (no keys): 30° from 600 u/s at 30, 60, 80
and 144 fps, `PhysicsRate` 100: 600, 721.322, 692.469, 831.131, as the reference (its second landing is set down);
20° from 700, `PhysicsRate` 0 at 60 fps: 700, 653.333, 682.432, 636.936, 664.919, as the reference. As first merged,
without the half update, the mod had 719.659, 862.348 and 1034.920 on 30° (the second landing ran into the slope)
and 680.432, 635.070, 661.380 on 20°: a clipped landing gained g/(2 · rate) sin θ cos θ less (1.7 u/s on 30° and 1.2
on 20° at 100), and within a few leaps one landed the other way.

Over 9 cases (20° from 700 and from 800 with W, 10° from 1300, 15° from 900, 30° from 600, 25° from 650, 40° from 450
with W, 35° from 320 with W, 32° from 300) × `PhysicsRate` 0, 60, 100, 144 and 250 × 30, 45, 60, 80, 100, 144, 200 and
300 fps, 350 of 360 runs have each of the first six take-offs within 0.3 u/s of the reference's (190 as first merged).
Of the 10 left, 9 are 32° from 300 u/s, where the mod's take-offs are the reference's shifted by one: the probe sets
the speed on the slope from nowhere, and below 360 u/s a first leave comes a frame late (see the thresholds below).
The tenth is 30° from 600 at 30 fps with `PhysicsRate` 0: the reference's second landing ends its last update 0.44
units (g/(2 · rate²) at 30 updates a second) higher than the mod puts it, out of the 2-unit reach, where the mod's is
within it.

**Correcting the height too** (tried in the fix-up after the merge, not kept). Two more leaps were compared: a slope
that turns into one of another angle (10° to 25°, 20° to 30°, 30° to 20° and others, the bend 100 to 300 units down,
so that the first leap crosses it; 200 runs, 140 with leaps) and the same with the bend 700 to 1300 units down, where
a later leap crosses it (288 runs, 204 with leaps). Out of the even-slope, first-bend and later-bend runs with leaps,
the reference's take-offs within 0.3 u/s: as first merged 190, 44 and 60; with the fall only (kept) 350, 115 and 152;
with Half-Life's height as if the flight began at the end of the leaving update (c/rate higher, falling g/(2 · rate)
faster) 351, 50 and 146; with the flight started at +g/(2 · rate), as if it began with that update, 351, 139 and 137;
with the first for a leave at a frame's start and the second for one at a frame's update, 351, 50 and 150. Where
along the slope the mod's flight starts against Half-Life's leaving update varies with how the updates fall in the
frames and when Unreal lands the character (in the traces, from just before it to an update after its end; with it in
the probes' first leap from a set speed), so neither height is right everywhere. The landing rule's limit at a bend
(see "What the mod can't tell" in `CLAUDE.md`) applies to the bend runs too. Walk-offs (4646 of 4650 as the
reference) and slides over rounded tops (1051 of 1076) are the same with and without the fix.

Thresholds (100 updates a second, the speed set on the slope): 1121 u/s leaps and 1111 doesn't on 10°, 740 and 730 on
15°, 545 and 535 on 20° (the rule: 540.4), 425 and 415 on 25°. On 30° the mod leaves from 360 u/s (from a standstill on
the slope at 345 it doesn't, as the floor is read below 360 u/s only after a steep descent in the frame before), where
the rule gives 340. At `PhysicsRate` 0 and 30 fps the mod is in the air 84 % of the time at 500 u/s on 20°, the
reference 92 %, whose flights start up to 6 units higher.

The 0.3.1 candidate walked and braked: down 20° from 700 u/s 465, 252, 91 and 0 u/s at 0.1, 0.25, 0.5 and 1 s (320
with W), and in the case of letting go of Space 104 u/s a second later where the reference has 624. The first fix (a
launch only at a frame's start, above 360 u/s, and not where a jump would start) lost 8 % a leap at 60 fps (700, 645,
595, 571, 548), stopped within 3 s at 30 fps (700, 619, 548), and left a run down 35° on the ground.

### Rough but level ground

0.3 review (per hop and per degree) and 0.3.1 candidate (the 40-hop runs). Flat triangles 0.5 to 2 m across or smooth
waves 1.7 to 4.5 m long, Space only, 80 fps, 320 landings a number. Floors leaning 2° (root mean square) change the
speed by 1 u/s a hop at most; 4° take up to 1 u/s a hop at 320 u/s and 1 to 5 from 600 to 1500 u/s, and turn the
direction 0.5 to 0.6° a hop at 320 u/s and 0.1 to 0.4° from 600; 7° take 2 u/s a hop at 320 u/s and 3 to 10 from 600 to
1500, turning it 1 to 1.3° and 0.3 to 0.8°; 10° take 2 to 4 at 320 u/s and 5 to 18 from 600 to 1500, turning it 1.6 to
2.9° and 0.6 to 1.3°. 3 to 5 in 10 landings run into a floor that leans against the way of travel, 1 to 2 in 10 into
one leaning away, fewer the faster you go. A plain 320 u/s run is at 274 u/s on average after 40 hops on triangles
leaning 4° (221 to 338 in 24 runs), 258 on 7° (127 to 368) and 189 on 10° (68 to 337, under 100 in 4 of 24); on smooth
waves 287, 231 and 155 (under 100 in 6 of 24 on 10°). With `SlopeLandings = false`, at 1500 u/s on 7° floors: 2 u/s a
hop, 13 slides in 320 landings. `SlopeBoosts = false` alone is as the default up to 1000 u/s.

### The log's lines

0.3.1. On a platform moving (150, 200) u/s, a slide off a 20° ramp: "flew off the slope at 830 u/s" and "landed 0.58 s
after flying off the slope, at 830 u/s (+0)" (the 0.3.1 candidate: 655 and 830). Hops down 20° on a platform moving
(120, 64) u/s: "landed on a 20 degree slope at 576 u/s, falling 688 u/s: 730 u/s (+154)" (relative to the platform),
then "Hop 1 ...: take-off 699 u/s, landing 699 u/s (+0), slope +154" (over the ground). Up a 10° hill with only Space
held, from 29.84 u/s "ran into it from 2.02 u up", from 30.10 u/s "set down from 1.99 u up" (the candidate printed 2.0
for both). A hop at 60 fps with one frame of 0.25 s reads "48 fps ... 1.19 s in the air" (the candidate "55 fps ...
1.03 s").

## Strafe gain

**What the settings add** (0.3.1, the mod in the fake game at 80 fps, level ground, a run and three straight hops, then
11 strafing hops with A and D, or 20 with D held; gain per strafing hop, and each setting against the defaults):

| How the view turns | Defaults | `PhysicsRate` 144 | 200 | 250 | `AirSpeedCap` 35 | 40 |
| --- | --- | --- | --- | --- | --- | --- |
| A and D, swings of 0.25 to 0.42 s, 85°/s | +24.7 u/s | +4 % | +6 % | +8 % | +17 % | +33 % |
| the same, 120°/s | +32.1 | +7 % | +10 % | +13 % | +17 % | +33 % |
| the same, 150°/s | +36.8 | +9 % | +13 % | +17 % | +17 % | +32 % |
| the same, 180°/s | +39.8 | +11 % | +16 % | +21 % | +15 % | +27 % |
| A and D, two turns a hop, 165°/s | +38.4 | +10 % | +14 % | +19 % | +16 % | +31 % |
| the owner's 0.2.6 turns, hop by hop | +37.7 | +11 % | +15 % | +19 % | +17 % | +32 % |
| the same with a human's spread (10 runs) | +32.1 | +10 % | +15 % | +20 % | +18 % | +34 % |
| D held, 30°/s | +10.2 | +1 % | +2 % | +2 % | +17 % | +34 % |
| D held, 60°/s | +19.3 | +3 % | +5 % | +6 % | +18 % | +35 % |
| D held, 120°/s | +32.6 | +8 % | +14 % | +17 % | +19 % | +38 % |

At 60 fps the same within 2 points (A and D at 150 and 180°/s: +10 and +12 % for 144, +18 and +21 % for 250). The
0.3.1 candidate, with a frame's turn shared out evenly among its updates, gained less with the defaults at 80 fps (A
and D at 150 and 180°/s: +33.4 and +35.0 u/s a hop; the owner's turns +33.8) and less of that at `PhysicsRate` 100
than at the higher rates, so it gave 12 to 15 % for 144, 20 to 26 % for 200 and 25 to 31 % for 250 (the 15, 24 and
28 % 0.3.0's docs quoted, from a strafe bot of the 0.3 review).

**Where the reversal falls.** With A and D the gain depends on where the view's reversal (and the key's) falls between
two updates, in Half-Life as in the mod. At 100 fps with `PhysicsRate` 100, A and D at 150°/s, the frames shifted
against the updates by 0, 2.5, 5 and 7.5 ms: +34.2, +36.1, +37.6 and +39.0 u/s a hop (at 180°/s: +35.9, +38.6, +41.0
at 0, 2.5 and 5 ms): a reversal right on an update gains about an eighth less than one just before the next. A probe
that reverses on frame boundaries at `PhysicsRate` frames a second always hits the worst case, so it shows the rate it
runs at worse than the others (at 100 fps `PhysicsRate` 144 then reads +17 to +23 %, at 144 fps only +1 to +2 %). At
60 and 80 fps the reversals fall at every phase, which is what a player's hand does.

**One hop** (0.3.1, `physics.step`, D held, the view turning; gain against `PhysicsRate` 100): from 320 u/s at 120°/s
144 adds 4 %, 200 6 %, 250 8 %; from 500 u/s at 200°/s 13, 22 and 26 %; from 700 u/s at 200°/s 22, 37 and 44 %. Half-
Life's 2005 version, whose updates at 144 fps are 6 ms, gains 19, 30 and 35 % at 144 there; today's Steam version
(updates of 7 and 6 ms) within 0.3 u/s a hop of `PhysicsRate` 144.

## Camera

**`BodySounds`** (0.3.1 candidate, unless it says 0.3.1). A character that carries a mesh the game keeps hidden for good
starts first person 187 frames after a save loads, against 182. In the fake game, whose renderer reports a draw two
frames after the show, a body shown up to 3 frames after its battle flag clears is kept animating, and one shown 4 or
more frames after it is not. An error in the walk of the attached parts from the save's load on (0.3.1): first person
on at frame 182, `Error in hiding the body` at 182, `Turned off hiding the body` at frame 1052 (30 failed passes, 14.5
s later); the candidate turned the camera step off at frame 211 and first person stayed off.

**Moved parts** (0.3.1). A kept body the game moves while it stays attached, and hides (either flag, the move at each
of four hiding passes): its tick option is back on the next pass in 8 of 8 cases (the candidate left 0 in 6 of 8). A
skin's body hidden in game while still its skin actor's and then moved into the character: visible after F6 and F5 in
every case tried (the candidate left it invisible when the skin was attached 70 or 300 frames before the move, when F6
was pressed twice 12 frames before it, and when the move came in the frame a battle starts). A skin of four parts
taken off and put back twice: 3 log lines, and the report counts 8.

**The report** is 145 lines long in the fake game (0.3.1).

## Speedometer

0.3.1, ten minutes at 60 fps for each pattern of the game taking the widget away:

| The game | Builds a minute | Build lines a minute | Stopped |
| --- | --- | --- | --- |
| takes it every 11 s, frees it at once | 5.4 | 10.8 | never |
| takes it every 11 s, frees it at the next 60 s purge | 5.2 | 10.4 | never |
| leaves it 10.1 s, then takes the next four at once, frees at once | 29.0 | 58.0 | never |
| the same, freed at the purge | 24.0 | 48.0 | never |
| the same with five quick ones | | | after 10.2 s (purge: 12.8 s) |
| takes it every 9 s | | | after 54.1 s (purge: 55.7 s) |
| leaves it 9.9 s, then four quick, freed at the purge | 24.0 | 48.0 | never (a widget left 9.9 s counts as 10 there) |
| leaves it 9.5 to 9.8 s, then four quick, freed at the purge | | | after 21.6 to 34.0 s |

A build costs 42 game calls on its frame (with the rest of the mod's frame, which costs about 27 a frame without the
speedometer), 5 objects and no FText with CommonUI (1 with the `TextBlock` fallback); a new one after the game took
the old one costs 45 calls. Cost while the number shows (0.3.1 candidate): +0.03 game calls a frame at a steady speed,
+0.37 strafe-hopping.

## Restoring

0.3.1. A value the game writes in the frame before the mod hands back stays: ALS's walking speed 375 written by a gait
change, then a battle on the next frame (the candidate put back the older 600). At a UE4SS mods restart a
`MaxWalkSpeed` of 200 the game wrote in the frame of the restart comes back as the older 600; written a frame or two
before it, 200 stays (not changed, see `CLAUDE.md`).

## Tests

0.3.1.

- The suite: 422 tests, about 17 to 23 s by the clock on WSL's mount of the Windows disk (the 0.3.1 candidate's 392,
  which loaded the mod for every game: 54 s).
- The shipped `config.lua` with one value changed: `PhysicsRate = 144` fails 31 tests, `Speedometer = true` 13,
  `FieldOfView = 106` 9, `Debug = true` 4, `JumpKeys = { "SpaceBar" }` 3; the first failure is always `test_settings`'
  check of the file.
- The frame phase: all 422 pass with the 190 frames before each test made 187 to 215, 225, 250 or 300; at 185 and 186
  "a mesh the game keeps invisible isn't started, ..." fails (as in the 0.3.1 candidate).
- The three tests of the player docs' other promises each fail on the break their findings' checks named: the
  shortcut written as 700, `InputSpeed` held at 400 in `settings.lua`, the words "or `Speedometer off`" taken out of
  step 6, `config.lua`'s figures put back to 15, 24 and 28, the README's to 15 to 28, and step 5's "about a tenth"
  made "about 15 %".
- The slope boosting table test: on paper the run-in and slide-end speeds against their formulas (within 1.5 and 6
  u/s), the "some hops" speed against its band (75 to 240 u/s wide), and the "every hop" speed at least that of a
  landing falling at the full 268 u/s (1123, 808, 670, 606 and 580 u/s); in the fake game at 80 fps, every row:
  running into the slope at the table's speed slides and 1 u/s slower doesn't; every hop slides at 15 places of the
  slope's foot (13 of the 25 the table was first made with, and 0.98 and 0.99 of a hop), its slide ending within 4.5
  u/s of the table, and 25 u/s slower some place doesn't; at the "some hops" speed one of 200 places slides, and 25
  u/s slower none of 50. Its games settle in 31 frames of 0.1 s and 10 of 1/60 s, which gives the same slides as the
  other tests' 190 frames of 1/60 s (4,000 approaches compared) in about two thirds of the time; it takes about 2.5 s.
  It catches each of 36 wrong edits of 0.3.1's docs, one at a time (every "every hop" speed 25 u/s up and down, 9999,
  every "some hops" speed 25 u/s up and down, run-in speeds 1 u/s up and down, end speeds 5 to 7 off, the quotes in
  the README, `config.lua` and `docs/TESTING.md`, a swapped and a reworded quote). Not held by design: a "some hops" speed set 25 u/s too high is caught only where one of those 50
  places slides at the right speed (so in every row today); and a change that moves the narrow places where the first
  slides happen can fail the test without the table being wrong (then measure the row again).
