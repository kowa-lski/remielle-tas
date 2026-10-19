# TAS input record and playback: design notes

How `remielle-tas.dll` records and replays a battle, and why each mechanism exists. The README covers building and
use; this file is the reference for what the DLL does inside the game. Most sections come from test runs against
the Deadly Assault "Butcher" stage on CNBetaWin3.3.4, and name the run that showed each problem.

The DLL is loaded into the running game by `tas-inject.exe`, next to thaumiel. It hooks only methods thaumiel
leaves alone; see "Battle lifecycle" below. It writes:

- `TAS\tas-log.txt`: one line per recording or playback start and end;
- `TAS\tas-dll.log`: install details and errors;
- `TAS\logs\<date>-<time>-<mode>\`: the per-session diagnostics (`tas-frames.tsv`, `tas-trees.tsv`,
  `tas-loads.tsv`, `tas-bt-loads.tsv`).

**Battle lifecycle.** thaumiel's combat-logger build hooks `BattleStatsSubsystem.OnAwake` / `OnDestroy` and the
level time manager's step. So a session starts at the first `BattleStatsSubsystem.OnUpdate` of a battle (RVA
`0x16A61F70`). Every later call is the per-frame step (`frame()`). The session ends at the AI subsystem's
`OnDestroy` (`IOMGMDHDGON`, RVA `0x17C51B30`). A battle that ends without that is closed when the next one starts.
When the installed thaumiel exports `thaumiel_log_next_order` (the combat-logger fork does), `tas-frames.tsv`
carries a value of that counter per frame, so the logger's damage and state rows can be placed on exact frames.

With a seed, the generator is by default **re-seeded every game frame** (`reseed = frame`), from the seed and the
game's frame counter. Unity's generator is shared with code whose timing follows real time (asset loading,
effects). `tas-frames.tsv` showed the same random bursts landing a few frames apart between recording and
playback, and other bursts differing outright. A seed applied once had drifted by 100 draws 8 s into the fight,
so the Butcher's opening attack differed. Per-frame reseeding keeps such a burst inside its own frame.
That was not enough on its own. The next test still diverged: inside a frame, other code drew different amounts
before the Butcher's roll, and its first attack came one 0.4 s stand-off wait later. So the default is now
**`reseed = tree`**. It keeps the per-frame reseed, and `BehaviorManager.Tick(BehaviorTree)` (RVA `0x6913EB0`,
detoured through `detour.zig`) reseeds right before every tree tick. The value mixes the seed, the tree's identity,
the frame and the tree's tick count that frame. Identity is the FNV-1a hash of `BehaviorSource.behaviorName` and
the task count, plus an occurrence index for identical trees, so it doesn't depend on pointers or load order.
`reseed = frame` is the per-frame reseed alone, and `reseed = start` is the original behaviour. The mode is saved with each recording; playback uses the recording's.

**Tree loading.** Enemy AI runs once every 4 frames, on a countdown that starts when the enemy's AI starts. The AI
starts in the callback of its behaviour tree's load, and Behavior Designer deserialises trees on worker threads and
hands finished ones back in `BehaviorAsyncLoadManager.ForegroundTick` (RVA `0x6947B80`). Which frame a load lands on
therefore depended on thread timing, and `tas-trees.tsv` showed an AI's 4-frame cadence a frame apart between
recording and playback. Making the game thread wait for the workers hung (a worker stayed busy for 5 s): some loads
need the game thread to finish. Instead, during a session the AI-start callback (`BKOBIBDGHFD::BCLGCCJAAEB`, RVA
`0x13DE0FE0`) is held back and released 20 frames after the load was requested. The request frame is the load
item's `StartFrame` (+0xA0, `Time.frameCount` at the request), read by a hook on `_NotifyOneLoadItem` (RVA
`0x6948590`), which is on the stack when the callback runs. Release happens in the per-frame step (`frame()`), so
every enemy AI starts on a fixed frame however long its load took. No AI starts before session frame 60: loads
requested during the battle's opening load (run 11: frame 15 vs 16) land a frame apart between runs, so they all
release on frame 60. A load still unfinished after 20 frames starts
when it finishes, as before, and `tas-log.txt` gets an `ai ... late` line. `tas-loads.tsv` lists every AI start
(`start` = held and released, `late`, `direct` = a cached tree with no load, `before-session`).

**Recommended (run 19, a full replay with the same boss attacks): `sync = on`, the other two off.** Let go of
every key at battle start and give the first input a moment after the character can move. The game unlocks movement
about 0.75 s after battle start, and that moment varies by a frame between runs for a reason not found yet (making
every Unity clock deterministic did not change it). An input waiting on the unlock (a key held through it) then
lands a frame apart.

**Switches.** Run 11 was the best replay before run 19. Its setup was per-tree reseeds plus the AI-start hold of 20 frames
after the request. The sync point, input clock and game clocks below came after it, and each is now a `tas.txt`
switch, off by default: `sync`, `input_clock`, `game_clocks` (`on`/`off`). A recording saves the ones it used
(`sync=bt-load`, `input_clock=1`, `game_clocks=1` in its info file), and playback uses those. Recordings older than
the switches: `input_clock` follows `sync=`.

**Team setup** (`pin_team = on`, needs `sync`). A second setup step follows the sync point: the team system
(`KLHKKPJMGLL::ICCDKMJBFGB`, RVA `0x16118970`) creates every agent's default modifiers, stat slots, passives and
team listeners in one frame once the team's entities are ready. That waits on real-time asset loading, so it came
4 to 50 frames after sync (run 21-3: 34 in the recording, 32 and 50 in playbacks). Agent resource and passive
timers moved with it against the inputs. The call chain (captured once, from the first frame with 40 modifier inits) runs from a coroutine-driven frame phase, through an ECS system's handler,
to `ICCDKMJBFGB` and then `FBGCHIJBJKC(team list)` and the level graph. With `pin_team = on` that call is held
until 90 frames after the sync point and made from the per-frame step. `ICCDKMJBFGB` is static, takes no arguments
and reads the team lists when it runs, so nothing has to be saved. `tas-loads.tsv` gets `team-held` and
`team-start` rows. A setup arriving after frame 90 runs at once, and `tas-log.txt` gets a `team ... late` line.

**Entity manager pause** (`pin_spawn = on`, needs `sync`, experimental). In run 23, `pin_team` put the team setup on
frame 90, but the intro and its timers still ran a frame apart, because they hang off the same moment. The entity
manager's per-frame tick (`IDBODLAJBDJ::HFOHNJIKEAH`, RVA `0x16823E60`) activates the team's entities once their
assets have loaded. That hands an entity event to every listener: `CGACLGJNHGA::AJGKIGJBCOI`, then a callback
wrapper, then the team system, the intro and others. With `pin_spawn` that tick is skipped from the sync point
until frame 90, and its first run there activates whatever finished loading meanwhile. `tas-loads.tsv` gets
`spawn-hold` and `spawn-resume` rows. If the tick also starts those loads, they start late instead: the team setup
then arrives after frame 90 (`team-late`), and this approach doesn't work.

**`tas-bt-loads.tsv`** (diagnostic, with the sync hook installed) has one row per behaviour-tree load request:
the synced frame, the requesting object's name, its external tree asset, `UnityEngine.Random.state` at that moment,
and the call stack as GameAssembly RVAs. In run 24 one AI (first tick on frame 472) came up with a different object
and tree in a playback. These rows show where that choice is made, and whether the random state differed when it was.

**Sync point** (`sync = on`). Recording and playback used to start at the battle subsystem's awake, which comes before the
battle's loading. How many frames that loading takes follows real time. In run 13-2 the playback finished loading 2
frames sooner than the recording, and the intro, battle start and AI loads all came 2 frames sooner, while the
inputs replayed on frames counted from the awake. Everything after loading kept identical frame offsets. So the
trace now starts recording, and the replay starts feeding frames, at the end of the frame of the first
behaviour-tree load request (`BehaviorManager.TryLoadBehavior`, RVA `0x6908680`). The input clock table, the
per-frame and per-tree reseeds, and `tas_frame` in `tas-frames.tsv` count from that frame too. With no request by
game frame 600, inputs start there and `tas-log.txt` says so. New recordings get `sync=bt-load` in their info file.
Recordings without it still count from the awake.

**Input clock.** Run 12 matched until the first move, which started a frame later in the playback (frame 306 vs
307), and earlier runs jittered the same way. The Input System compares event timestamps with its own clock, which is
real time: `NativeInputSystem.currentTime`, plus `currentTimeOffsetToRealtimeSinceStartup` on top of
`Time.fixedUnscaledTime` for fixed updates. That comparison decides which update an event is due in and hold/tap
timing. `ReplayController.QueueEvent` also re-stamps replayed events as replay start + (event time - first event
time), in the playback's real time. During a session both clock calls are frozen per frame, by swapping their
icall slots (the `jmp [rip+disp32]` in `NativeInputRuntime.get_currentTime` and
`get_currentTimeOffsetToRealtimeSinceStartup`). When recording, each frame's values are saved to
`<recording>.clock`. When playing, those values are returned instead, and a hook on `QueueEvent` (RVA `0x1F5AD580`)
sets `m_StartTimeAsPerRuntime` (+0x80) to `m_StartTimeAsPerFirstEvent` (+0x70) plus a shift, so every replayed event
keeps its recorded timestamp plus that shift. The clock values get the same shift. Unshifted, the replay broke
input (run 13: WASD and other keys did nothing). A recording's times are from earlier in real time, and the Input
System drops state events older than their device's `m_LastUpdateTimeInternal` (+0x148). The shift puts the first
replayed time 1 s after the real time when the replay starts. Every time difference stays exactly as recorded, so
the playback's input system acts as the recording's did, at any playback speed. When the replay stops (F8), the
recording's clock runs out or the battle ends, the real clock comes back and the keyboard, mouse and gamepad get
their last-update time cleared, so your own input works at once.

The fixed-update input clock is `Time.fixedUnscaledTime` plus the offset, and `fixedUnscaledTime` counts from the
game's start, so it differs between the recording's game session and the playback's. In run 15 an AI started 3
frames apart, with real time, inputs and every earlier state row identical. Version 2 `.clock` files
(`TASCLK2`) also keep `fixedUnscaledTime` at each frame's first offset read, and the replayed offset absorbs the
difference. Version 1 files still load, without that correction. The play/record start is followed by a line with
the input update mode and the fixed step. `tas-frames.tsv` has `fixed_phase` (`unscaledTime - fixedUnscaledTime`):
if it differs between two runs, fixed updates fall on different frames. The
start line in `tas-log.txt` says `clock=recorded`, `clock=replayed` or `clock=real` (a recording without a `.clock`
file).

**Unity clocks.** Run 16 recorded input update mode 3 (manual) and a fixed step of 1/60 s, so neither fixed-update
slicing nor fixed-step phase was the issue. The first move still came 45 or 46 frames (a 0.75 s unlock) after battle
start, run to run, in plain recordings too. `Time.realtimeSinceStartup` is read at 638 call sites in 414 methods,
among them DOTween's timescale-independent tweens and `Foundation.Coroutine.CoroutineManager`. `Time.time`,
`unscaledTime`, `fixedTime` and `fixedUnscaledTime` count from the game's launch, so their float values round
differently in another game session. All ten getters (and their `AsDouble` versions) are swapped at their icall
slots. From the sync point on, `realtimeSinceStartup` advances exactly one frame per frame and is frozen within a
frame. Every clock is moved forward to start on the float grid of the binade [16384, 32768): multiples of 2^-9,
16384 unless a clock is already past it. Rounding is then identical in every recording and playback. After the
session, realtime follows real time again from where it was, and the game-time clocks keep their offset, so nothing
jumps back. A game kept running for more than ~4.5 h gets a warning in `tas-log.txt`.

`seed` in play mode overrides the recording's seed. This is how to look for enemy behaviour: the same inputs
against different seeds.

## Checking determinism

thaumiel's combat logger, if installed, already writes every hit (`hits.tsv`, `damage-result-*.tsv`, `state.tsv`
in its battle folder). Two playbacks of one recording should give the same rows: same hits, same frames, same damage, same
crits. The first row that differs shows where they drift.

Suggested order:

1. Same seed, two playbacks of one recording: the enemy side should replay exactly.
2. Different seeds: the enemy should behave differently against the same inputs.

`tas-log.txt` also compares the frame count of each playback with the recording's.

During every TAS session the session folder gets **`tas-frames.tsv`**, one row per game frame:

- the Unity frame, counted from the session start (twice: the second column is kept for the scripts);
- the wall-clock ms since the session started;
- a value of thaumiel's process-wide `order` counter when it exports one, else 0 (damage-result and `state.tsv`
  rows with an order between two frame rows happened in the later frame);
- `UnityEngine.Random.state` after the step.

When the tree-tick hook is installed, the session folder also gets **`tas-trees.tsv`**, one row per Behavior
Designer tree tick: the game frame, the tree's slot and id, the tick number within the frame, the seed it was given
(`-` unless `reseed = tree`) and `UnityEngine.Random.state` after the tick (from the seed, the number of draws the
tick made). The tree's behaviour name is on its first row. `tools/tree_ticks.py`
compares two of these: a different seed means the tick counting differs, the same seed with different draws means
the tree took another path (a non-random input differed).

Comparing a recording's file with its playback's gives the exact first frame where the random stream or the world
clock differs. `tools/compare_runs.py` does this, plus the game-clock and
per-attacker hit-order comparisons.

## How it works (`src/tas.zig`)

| Step | Call |
|---|---|
| session | first `MoleMole.BattleStatsSubsystem::OnUpdate` of a battle to the AI subsystem's `OnDestroy`, game thread |
| fixed timestep | `UnityEngine.Time.set_captureDeltaTime(1/fps)`; restored to 0 (Unity's default) at the end |
| real-time speed | `QualitySettings.set_vSyncCount(0)`, `Application.set_targetFrameRate(fps * speed)`; both restored |
| seed | `UnityEngine.Random.InitState(seed)` at awake, and with `reseed = frame` after every game step, with a mix of the seed and the time manager's frame counter |
| record | `new InputEventTrace(16 MB, grow, 1 GB max, 16 MB steps)`, `recordFrameMarkers = true`, `Enable()`; at the end `Disable()`, `WriteTo(path)`, `Dispose()` |
| play | `InputEventTrace.LoadFrom(path)`, `Replay()`, optionally `WithAllDevicesMappedToNewInstances()`, `PlayAllFramesOneByOne()`; at the end `Dispose()` both |
| liveness | strong GC handles (`GCHandle.GetTargetHandle` / `FreeHandle`) on the trace and the controller while native code holds them |

Every managed call goes through `il2cpp_runtime_invoke` (API slot 138), which returns managed exceptions (missing
file, bad trace) instead of unwinding through the DLL. Objects come from `il2cpp_object_new` (slot 128) and
strings from `il2cpp_string_new` (slot 145).

Pins, all CNBetaWin3.3.4, checked at install; any mismatch logs and leaves the TAS off:

- **API slots:** RVA and the first code bytes.
  - 128 `object_new`: `0x927A20`, a `try { Object::New } catch` wrapper calling the allocator compiled `new`
    uses.
  - 138 `runtime_invoke`: `0x927B30`.
  - 145 `string_new`: `0x927CE0`. It follows `string_length` (143) and `string_chars` (144), and shares its
    code with `string_new_wrapper` (148).
- **Methods:** name, parameter count and code RVA, through `il2cpp.zig`'s `findMethodInfoAt` (it returns the
  `MethodInfo*` that `runtime_invoke` takes).
- **Layouts:** `System.Exception._message` (+0x18) and `System.String` length/chars (+0x10/+0x14), for
  exception messages.

## Known risks (what the first tests answer)

- **Input timing in real time.** The Input System timestamps events in real time. Frame replay ignores
  timestamps, but an input interaction that measures a hold in real time could time out differently in a slow
  recording and a fast playback.
- **Loading.** Battle loading follows real time. `sync`, `pin_team` and `pin_spawn` (above) put the
  stages known so far on fixed frames. A new stage with its own real-time wait would show up as a constant frame
  offset between a recording and its playback.
- **The game's own frame limiter** may set `Application.targetFrameRate` itself. If recording doesn't slow
  down, that is why.
- **Device ids.** `devices = same` replays into the device ids recorded. If they change between launches, try
  `devices = new`. Either way, real input still arrives during playback, so don't touch the controls.
- **Other random generators.** Only Unity's shared generator is seeded. The game has others (`Share.CRandom`,
  `XorShift64Rng`, `RngSequence`, StateTree random tasks). If enemies or crits still drift with a fixed seed, one
  of these is the cause.
