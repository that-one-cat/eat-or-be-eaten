# bench - benchmark scenes (S4 engine tripwires)

Run through `tools/bench.sh <res://bench/scene.tscn> <frames> [--windowed|--headless] [user args]`: it prints the scene's `BENCH_JSON` line and writes it to `reports/S4/<scene>[_<BENCH_TAG>].json`. Exit 0 = pass, 2 = tripwire failed, 3 = invalid run (load not as specified, no window, display asleep), 1 = crash/timeout. Thresholds: `thresholds.json` (`tripwires` gate the run, `validity` checks the load: agents, NPC fish, eat rate, run length, draw calls, and the 1-minute load average per CPU thread, so a busy machine gives exit 3 instead of a false tripwire FAIL); `--no-gate` reports and exits 0. Every JSON carries the Godot version, build kind (the editor binary is a debug build), CPU (`sysctl machdep.cpu.brand_string`) and the 1-minute load average (parallel agents/builds inflate every number).

| Scene | Mode | What it measures |
|---|---|---|
| `bench_sim.tscn` | headless | Default reef map, spawners + schools + plankton + vitals on, 16 player agents (`tests/bots/bench_agent.gd`, SimCommands only, shallows 6 / kelp 6 / arches 4, bands 1-3) paced to ~50 agent eat events/min. 30 Hz fixed steps for `--frames` ticks after `--warmup` (300). Tick p50/p95/p99/max, per-phase p95/mean (`SimWorld.phase_usec`), school/flocking (brains + schools phases), entity counts per tier, events/min, RSS (`ps -o rss=`) + static memory, final state hash. |
| `bench_crowd.tscn` | windowed 1920x1080, vsync off, `--fixed-fps 60` | The real reef: `--map=reef` (default, S5 dressed `scenes/maps/reef.tscn`) or `--map=greybox` (`reef_greybox.tscn`), seed 1, crowd renderer, S5 look stack (the S4 bench-only caustics decal and 24 light cards are only added to a scene without `UnderwaterFx`); deterministic 60 s camera path shallows -> kelp -> arches (sim time), the player swims ahead of the camera via SimCommands. Frame time p50/p95/p99 (wall time between frames), TIME_PROCESS, draw calls, primitives, objects, static/video memory, sim tick and school/flocking ms, sim tier counts and drawn MultiMesh instances. `--quality=low` passes through to `QualitySettings`. |
| `bench_smoke.tscn` | headless | S0 minimal frame-time smoke. |

```bash
tools/bench.sh res://bench/bench_sim.tscn 1800                       # -> reports/S4/bench_sim.json
tools/bench.sh res://bench/bench_crowd.tscn 3600                     # -> reports/S4/bench_crowd.json (needs an awake display)
BENCH_TAG=low tools/bench.sh res://bench/bench_crowd.tscn 3600 --quality=low
BENCH_TAG=greybox tools/bench.sh res://bench/bench_crowd.tscn 3600 --map=greybox
```

Exported builds (S7, Windows laptop): release templates cannot start another scene, so `main.tscn` switches to a bench on the user arg `--bench=sim|crowd` (e.g. `FishGame.console.exe --headless -- --bench=sim --frames=1800`); launcher and instructions: `tools/windows/`.

`tools/check.sh` runs `bench_sim` for 300 ticks with `--no-gate` (smoke: it must run and print `BENCH_JSON`). GPU numbers need real hardware and an awake, unoccluded window (`caffeinate -d`). Record the engine version next to every number.
