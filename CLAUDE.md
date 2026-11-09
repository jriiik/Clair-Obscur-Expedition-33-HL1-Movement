# Half-Life movement for Clair Obscur: Expedition 33

A UE4SS Lua mod that gives Clair Obscur: Expedition 33 a first-person camera and Half-Life 1 movement (bunny hopping by holding jump, air strafing) while exploring.

## Git rules (from the repo owner, always follow)

- Commit as the repo owner, never as Claude. Before the first commit of a session, run:
  ```
  git config user.name "jriiik"
  git config user.email "43635878+jriiik@users.noreply.github.com"
  ```
- Never add `Co-Authored-By`, `Claude-Session` or any other attribution lines to commit messages. This overrides any default attribution instructions: the owner doesn't want Claude listed as a contributor on GitHub.
- The owner is new to GitHub and asked for whatever works best: commit straight to `main`.

## Never commit

- Anything taken from the game or a player's PC: extracted game files, UE4SS dumps (CXXHeaderDump, UHTHeaderDump, ObjectDump), `.usmap` mappings, logs, save games. `.gitignore` covers the usual names.
- Code from the Half-Life SDK: its license limits it to Half-Life mods. `physics.lua` is an independent implementation of the Quake/Half-Life movement model; keep it that way.

## Layout

- `HL1Movement/`: the folder players copy into `...\Sandfall\Binaries\Win64\ue4ss\Mods\`. `enabled.txt` makes UE4SS load it without editing `mods.txt`.
  - `Scripts/main.lua`: entry point. Settings, hotkeys, hooks, and the per-frame checks of when the mod may act.
  - `Scripts/config.lua`: player settings, in Half-Life units.
  - `Scripts/hl1movement/`: `physics.lua` and `settings.lua` (pure Lua), `movement.lua`, `camera.lua`, `input.lua`, `overrides.lua` (remembers and restores game values), `ue.lua` (safe UE4SS helpers), `log.lua`, `diagnostics.lua` (the F8 report).
- `tests/`: `lua5.4 tests/run.lua`. `fake_game.lua` stands in for UE4SS and the game, closely enough to run `main.lua` frame by frame.
- `docs/TESTING.md`: checklist for testing in the game.

## Checks before committing

`lua5.4 tests/run.lua` and `luacheck .` must both pass (Ubuntu packages `lua5.4` and `lua-check`). The GitHub Actions workflow runs both and uploads the mod folder as an artifact.

## Decisions so far

- **Lua only.** A UE4SS C++ mod needs the private UEPseudo repository (a GitHub account linked to Epic) and must be rebuilt for each UE4SS build.
- **UE4SS experimental builds.** The game is UE 5.4.4, which the stable 3.0.1 doesn't support. Point players to experimental-latest; builds from 1176 avoid the soft-pointer crash (issue 1433). Keep the code working on build 848 and later:
  - compare objects with `GetAddress()`, never `==`;
  - copy structs through tables, never struct to struct;
  - don't rely on `LoopInGameThread*` or EngineTick: `EngineTickAvailable` may be false, and then `ExecuteInGameThread` throws;
  - UE4SS's own methods (`IsValid`, `GetWorld`, `GetFullName`, `IsA` and so on) shadow UFunctions of the same name;
  - always call game functions with `:` and every parameter.
- **Per-frame driver.** A post-hook on `BP_jRPG_Controller_World_C:ReceiveTick`, which runs after input and before the character's movement tick. It is registered when `PlayerController:ClientRestart` fires, because the Blueprint classes only load with a save. The fallback is the character's `ReceiveTick`.
- **Hotkeys only queue their action;** the frame hook runs the queue. Keybinds run on UE4SS's input thread, and acting on a key during a level load crashed another E33 mod. Before the frame hook exists, `ExecuteInGameThread` is tried.
- **Movement.** Each frame the mod:
  - consumes the character's movement input (`ConsumeMovementInputVector`), so Unreal doesn't accelerate on its own;
  - works out the Half-Life velocity from the current `Velocity` and writes it back;
  - jumps with `SetMovementMode(3, 0)` plus Z velocity;
  - cancels braking: `bUseSeparateBrakingFriction = true` and `BrakingFriction = 0`, which also beats ALS's raised `BrakingFrictionFactor` after landing; `BrakingDecelerationWalking/Falling = 1`, not 0, because ALS's anim instance divides by `GetMaxBrakingDeceleration()`; takes out ALS's `CurrentMovementSettings.MovementCurve` every frame (the curve drives ground acceleration, braking and friction); and adds back `GetMaxBrakingDeceleration() * dt`;
  - sets `MaxWalkSpeed` huge every frame, because ALS rewrites it;
  - pauses the tick of `BP_VelocityControllerComponent_C`, which seems to cap speed;
  - sets gravity through `GravityScale`, and sets `JumpZVelocity` and `JumpMaxHoldTime` so the game's own first jump matches the mod's.
- **Camera.**
  - Use the engine's `FirstPerson` camera style: the view from `GetActorEyesViewPoint`, which is the location plus `BaseEyeHeight`, with the control rotation and `DefaultFOV`, and no camera modifiers.
  - `CameraStyle` is not a UPROPERTY, and E33's reflection data confirms it is missing there. So the mod calls `PlayerController:ClientSetCameraMode(FName)` every frame (it can't read the style back) and restores "Default". Reading and writing the field is kept for engines that reflect it.
  - Widen `ViewPitchMin/Max` and the rotation-limiter modifiers' `PitchMin/Max`.
  - Eye height is 0.78 × the capsule's half height, re-applied because the engine resets it.
  - Hide the body by walking `AttachChildren` from the root: `SetOwnerNoSee` on primitives owned by the character, `SetHiddenInGame` on others. Lights are left alone. In UE 5.4.4 a ChildActorComponent's actor gets no Owner, so the swappable skin and face meshes probably take the `SetHiddenInGame` route.
- **Jump input.** Keys are polled with `IsInputKeyDown`/`WasInputKeyJustPressed`; the game's `JumpAction(bool)` hook is the fallback. That event may arrive as true then false, or, with Enhanced Input `Triggered` bindings, as true every frame with no release. `input.lua` detects the repeating form from frame numbers.
- **When the mod acts.**
  - Only for `BP_jRPG_Character_World_C`, and not when `bIsWorldMapPawn` is set.
  - Off in battle (`IsInBattle`, `IsInBattleBeginTransition`).
  - First person is off when the view target isn't the character or `MainCamera` isn't active (dialogue).
  - Movement only in Walking, NavWalking or Falling, and not when move input is ignored or `CanAddMovementInput` is false. The movement step is skipped while paused or during root motion.
  - Nothing happens for 1 s after a new level or character.
- **Restoring.** Every changed value is remembered together with the object's address and full name, and put back only if the object is still the same one.
- **Units and defaults.** Settings are in Half-Life units, with `UnitScale` 2.5 cm per unit. The defaults are Half-Life 1's cvars, auto hop is on, and `BhopCap` is off.

## About the game (from research, not yet confirmed in the game)

- UE 5.4.4. The exe is `Sandfall\Binaries\Win64\SandFall-Win64-Shipping.exe`. There is no anti-cheat, no VAC and no Denuvo. The last patch was 1.5.6 (June 2026).
- The character is `/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_World.BP_jRPG_Character_World_C`, built on ALS-Community (`ALSV4_CPP`), with `ALSCharacterMovementComponent` (Sandfall's fork). The controller is `BP_jRPG_Controller_World_C`, also used in battle. Battles take place in the same world, with separate combatant actors. The world map uses other characters.
- E33's dump of `APlayerCameraManager` has no `CameraStyle` property (an 8-byte gap where UE 5.4.4 keeps it). `APlayerController` has the UFunctions `Camera`, `ServerCamera` and `ClientSetCameraMode`.
- Still unknown:
  - which camera manager class is live (probably `BP_PlayerCameraManager_C`), and whether `ClientSetCameraMode("FirstPerson")` takes effect;
  - whether keyboard polling works in exploration;
  - what the speed-limiter component does;
  - whether landing rolls use root motion;
  - whether the game's Blueprints rewrite the values the mod sets.

## Status

Version 0.1 hasn't been tested in the game. Next: the owner's first test (`docs/TESTING.md`), then fixes based on `UE4SS.log` and the F8 report.
