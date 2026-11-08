# tools/windows - Windows build and laptop benchmarks

> **Building and delivering the game to Robert's laptop: `docs/WINDOWS_BUILD.md`** (one command: `tools/windows/deploy_to_robert.sh`). The section 1 below is the older Mac-side route and is superseded by it; section 2 (benchmarks) is still current.

Prepared in S7 (no export was run here: the Windows export templates are not installed on the Mac, and installing them
is the Director's call). Everything below is what the Director and Robert do by hand.

## 1. Export (Director, on the Mac)

1. Install the **Godot 4.7.2 standard** export templates (Editor -> Manage Export Templates -> Download, or the
   official `Godot_v4.7.2-stable_export_templates.tpz` -> Install from File). They must match the editor version
   exactly. Today `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` holds only the web templates.
2. Export the preset `Windows Desktop` (`game/export_presets.cfg`: x86_64, PCK embedded in the exe, console wrapper
   for debug and release, no code signing):

   ```bash
   mkdir -p build/windows
   godot --headless --path game --export-release "Windows Desktop" ../build/windows/FishGame.exe
   ```

   The output path is relative to `game/`, so the files land in `<repo>/build/windows/` (git-ignored):
   `FishGame.exe` (game + data) and `FishGame.console.exe` (console wrapper: same game, but prints to the console and
   forwards the exit code; the benchmark script uses it). Not code-signed: Windows SmartScreen asks once ("More info"
   -> "Run anyway").
3. Copy the folder with both exes plus `tools/windows/run_benchmarks.bat` to the laptop (USB stick or a shared folder).

Release builds ignore the capture fixtures (`--autopilot`, `--demo-fx`, `--s6-demo`, `--s6-screen`); a debug export
(`--export-debug`) keeps them.

## 2. Benchmarks (Robert's laptop)

Before starting: mains power, Windows power mode "Best performance", close other programs, screen awake (no screen
saver), the game window in front; do not touch mouse/keyboard while the crowd benches run.

Double-click `run_benchmarks.bat` next to `FishGame.exe`, or from a terminal:

```bat
run_benchmarks.bat C:\path\to\FishGame.exe
```

It runs four benches one after another (about 5-8 minutes):

| Name | What | Command it runs |
|---|---|---|
| `sim` | headless sim tick (16 bot players, ~1000 NPC fish), 1800 ticks | `FishGame.console.exe --headless -- --bench=sim --frames=1800` |
| `crowd_high` | windowed reef camera path, high tier, 3600 frames | `FishGame.console.exe --resolution 1920x1080 --disable-vsync --fixed-fps 60 -- --bench=crowd --frames=3600 --quality=high` |
| `crowd_low` | same, low tier | `... -- --bench=crowd --frames=3600 --quality=low` |
| `crowd_low_compat` | low tier on the Compatibility (OpenGL) renderer | `FishGame.console.exe --rendering-method gl_compatibility ... -- --bench=crowd --frames=3600 --quality=low` |

- Everything after `--` is a user arg for the game. `--bench=sim|crowd` makes `main.tscn` switch to
  `res://bench/bench_sim.tscn` / `bench_crowd.tscn` (release templates cannot start another scene directly);
  `--frames`, `--warmup`, `--quality=low|high`, `--map=reef|greybox`, `--no-gate` are the bench's own args
  (`game/bench/README.md`). Engine args (`--headless`, `--resolution`, `--rendering-method`, `--rendering-driver`)
  go before `--`.
- Overrides: `set CROWD_FRAMES=1800`, `set SIM_TICKS=900`, `set RESOLUTION=1600x900` before running the script.
- Try the other GPU API by hand when a number looks odd: add `--rendering-driver vulkan` or
  `--rendering-driver d3d12` before `--`.

### Where the results go

`bench_results\<yyyyMMdd-HHmmss>\` next to the exe:

- `<name>.json` - the bench's `BENCH_JSON` line (same format as `reports/S4/*.json`: frame / tick percentiles,
  counts, `machine` block with Godot version, build kind `release`, CPU, renderer, `verdict`);
- `<name>.log` - the full engine output (look here when a JSON is missing);
- `machine.txt` - CPU, RAM, Windows version, GPU name + driver + desktop resolution, battery status.

Copy the whole timestamped folder back into the repo as `reports/S7/windows/` (or send it to the Director).

### Reading the verdicts

The script prints each bench's exit code and verdict line: `0` pass, `2` tripwire failed (a real budget miss:
`frame_p95_ms` > 16.7 or a sim/flocking tick over budget), `3` invalid run, anything else = crash (see the `.log`).
The thresholds are in `game/bench/thresholds.json`; on Windows the 1-minute load average is not available, so that
validity check is skipped (`load_avg_1m: -1`), and the process RSS is not measured either (`rss_mb_max: -1`, the sim bench's
RSS tripwire cannot fail there). `INVALID` with `frame_p50_max_ms` failing means the window was not
drawn (screen asleep, minimised, covered) - rerun with the window in front. The numbers are recorded either way; a
weak iGPU missing the high tier is expected (`CLAUDE.md` hard rule 12 budgets: iGPU 300-500 fish -> the low tier).
