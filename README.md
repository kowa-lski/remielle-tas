# remielle-tas

Tool-assisted input for the [Remielle](https://git.xeondev.com/remielle/remielle) Zenless Zone Zero private server
client: it records every input of a battle frame by frame and plays it back against the same battle, with the
enemy AI's random rolls and timing made reproducible.

It is a separate DLL that loads next to [thaumiel](https://git.xeondev.com/remielle/thaumiel); thaumiel itself is
not modified.

> You need a working Remielle setup (client, server, thaumiel). This project doesn't cover that. The DLL is pinned
> to the **CNBetaWin3.3.4** client; on any other build it checks its pins at start-up, logs the mismatch and stays
> off.

## Build

Requirements: Windows x64 and **Zig 0.16.0** (exactly; Zig's language and standard library change between
releases). Download it from <https://ziglang.org/download/> and put `zig.exe` on your `PATH`.

```text
git clone https://github.com/kowa-lski/remielle-tas.git
cd remielle-tas
zig build -Doptimize=ReleaseFast
zig build test
```

Output in `zig-out\bin\`:

| File | What |
|---|---|
| `remielle-tas.dll` | the TAS itself, loaded into the game |
| `tas-inject.exe` | loads `remielle-tas.dll` into the running game |

## Install

`install.cmd "<game folder>"` builds and copies everything; the game folder is the one with
`ZenlessZoneZeroBeta.exe` and `remielle.exe`. It copies `packaging\tas.txt` only if the folder has none yet.

By hand: copy `zig-out\bin\remielle-tas.dll`, `zig-out\bin\tas-inject.exe` and `packaging\tas.txt` into the
game folder.

## Use

1. Start the game with `remielle.exe` as usual.
2. Run `tas-inject.exe` (it waits for the game if it isn't up yet). It reports when the DLL is loaded; details go
   to `TAS\tas-dll.log` in the game folder. Run it once per game launch.
3. Edit `tas.txt` (it's re-read at the start of every battle):
   - **Record:** `mode = record`, optionally `file = TAS\run1.inputtrace`, `seed = 42`. Play the battle; when it
     ends the recording is saved as `TAS\<name>.inputtrace` plus `.info.txt` (and `.clock` with
     `input_clock`).
   - **Play:** `mode = play`, `file = TAS\<name>.inputtrace`. Start the same battle with the same team and don't
     touch the controls. `speed = 1` plays in real time.
   - **Stop a playback:** F8 (`stop_key` in `tas.txt`). The rest of the battle is yours.
4. Every start and end is a line in `TAS\tas-log.txt`.

### Recommended settings

```text
fps = 60
speed = 1
seed = 42
sync = on
pin_team = on
pin_spawn = on
```

- Play back at the speed you recorded at. Parts of the game run on real time, and the switches above pin the
  known ones; anything not yet pinned shifts if the playback runs faster or slower than the recording.
- Let go of every key at battle start and give your first input a moment after you can move: the game unlocks
  movement about 0.75 s after battle start, on a timer that can land a frame either way.
- The switches are saved with each recording; playback always uses the recording's.

| Switch | What it does |
|---|---|
| `sync` | inputs, input clock and reseeds count from the first behaviour-tree load instead of the battle's awake (the opening load's length varies) |
| `pin_team` | the team setup (agents' passives, resources, team listeners) runs 90 frames after sync in every run (needs `sync`) |
| `pin_spawn` | the entity manager is paused from sync to frame 90, so the intro and everything tied to the team's arrival start on that frame (needs `sync`; experimental) |
| `input_clock` | saves the Input System's clock with the recording and replays it |
| `game_clocks` | Unity's clocks (`realtimeSinceStartup`, `time`, `unscaledTime`, ...) advance exactly one frame per frame and round the same in every run |
| `reseed` | `tree` (default): reseed Unity's generator before every AI tree tick; `frame`; `start` |

## Logs and analysis

Each TAS session writes `TAS\logs\<date>-<time>-<mode>\` in the game folder:

| File | One row per |
|---|---|
| `tas-frames.tsv` | frame: Unity frame, wall clock, random state, `tas_frame` (from the sync point), fixed-step phase |
| `tas-trees.tsv` | AI behaviour-tree tick: tree, tick, seed, random state after, caller |
| `tas-loads.tsv` | held/released enemy AI start, team setup, entity-manager pause |
| `tas-bt-loads.tsv` | behaviour-tree load request: owner, tree asset, random state, call stack |

`tools\` has the Python scripts used to compare a recording with its playback (`compare_runs.py`, `tree_ticks.py`,
`state_diff.py`, `rng_draws.py`; Python 3.10+, no packages). They take two folders, each holding a session's
`tas-*.tsv` files and, for the hit and state comparisons, the matching battle folder's files from thaumiel's
combat logger (copy them together).

`docs\TAS.md` explains every mechanism and the test runs behind it.

## Licence

AGPL-3.0, see `LICENSE`
