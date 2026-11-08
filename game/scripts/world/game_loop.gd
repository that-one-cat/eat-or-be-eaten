class_name GameLoop
extends Node
## Owns the SimWorld and is the only node that steps it. Views read `world` and never mutate it.
##
## Steps the sim one tick at a time from _process (fixed 30 Hz, frame-rate independent via the sim
## accumulator) so per-tick hooks are exact: the autopilot is asked for commands right before each step,
## and `ticked` is emitted right after it (views snapshot state there for interpolation).
## User arg `-- --autopilot`: SwimTourAutopilot (res://tests/scenarios) feeds the commands each tick
## instead of PlayerInput (captures and visual QA). With `--autopilot-skip-ticks=<N>` (needs `--autopilot`)
## start() fast-forwards the sim N ticks headlessly with the same autopilot commands, before any view is set
## up, so the views snap to that state and captures can start anywhere on the tour (deterministic).
## Normal play turns on the S3 vitals (hunger/starvation/regen) and the NPC spawners. The `--autopilot` path keeps
## both off (S2 swim tour, empty world). User arg `-- --demo-fx`: DemoFx (scripts/world/demo_fx.gd) sets up a
## scripted feedback situation and drives the player instead of PlayerInput (vitals on, spawners and brains off).
## Both are dev fixtures: honoured only in debug builds (the editor binary used by check.sh, captures and benches;
## debug export templates), never in a release export (OS.is_debug_build()).
##
## Slow-mo: FeedbackFx sets Engine.time_scale. _process gets the scaled delta, so fewer fixed ticks run per real
## second (views keep interpolating with interpolation_alpha) while every tick is still 1/30 s of sim time: sim
## results and determinism do not depend on time_scale (MAX_FRAME_DT applies to the scaled delta).
## God tools (`world.debug`, SimDebug): `world.debug.time_scale` multiplies the delta the same way (Engine.time_scale stays
## FeedbackFx's); `world.debug == null` (every normal run) changes nothing.

## Emitted right after a sim step; `tick` is world.tick after the step.
signal ticked(tick: int)

const AUTOPILOT_SCRIPT_PATH: String = "res://tests/scenarios/swim_tour_autopilot.gd"
const SKIP_TICKS_ARG: String = "--autopilot-skip-ticks="
const DEMO_FX_ARG: String = "--demo-fx"
## Longest frame time fed to the sim at once (a hitch must not turn into a burst of hundreds of ticks).
const MAX_FRAME_DT: float = 0.25
## Same unit as the SimWorld accumulator: 1 tick = 1_000_000 units.
const _UNITS_PER_TICK: int = 1000000
const _UNITS_PER_SECOND: float = SimWorld.TICK_RATE * 1000000.0

@export var world_seed: int = 1103

var content: ContentDB
var world: SimWorld
var player_id: int = 0
var autopilot_enabled: bool = false
## `--demo-fx`: DemoFx drives the player (no PlayerInput).
var demo_fx_enabled: bool = false

var _autopilot: RefCounted = null
var _autopilot_reported: bool = false


func _ready() -> void:
	# step the sim before any view reads it this frame
	process_priority = -100


## Loads content, creates the world and spawns the player. Returns false (with an error) when content
## is invalid. Called by the scene root before the views are set up.
func start() -> bool:
	content = ContentDB.load_from_dir()
	if not content.is_valid():
		push_error("game_loop: content is invalid, see the errors above")
		return false
	world = SimWorld.new(world_seed, content)
	player_id = world.spawn_player()
	var dev: bool = OS.is_debug_build()  # capture / QA fixtures are not reachable from a release export
	autopilot_enabled = dev and OS.get_cmdline_user_args().has("--autopilot")
	demo_fx_enabled = dev and not autopilot_enabled and OS.get_cmdline_user_args().has(DEMO_FX_ARG)
	if not autopilot_enabled:
		world.vitals_enabled = true
		NpcSpawner.set_enabled(world, not demo_fx_enabled)
	if demo_fx_enabled:
		_autopilot = DemoFx.new(world, player_id)
		_fast_forward(1)  # derive the demo's start growth before the views snapshot it
	if autopilot_enabled:
		var script: GDScript = load(AUTOPILOT_SCRIPT_PATH) as GDScript
		if script == null:
			push_error("game_loop: --autopilot needs %s" % AUTOPILOT_SCRIPT_PATH)
			autopilot_enabled = false
		else:
			_autopilot = script.new(world, player_id)
			_fast_forward(_skip_ticks_arg())
	return true


## Value of `--autopilot-skip-ticks=<N>` (0 when absent or not a non-negative integer).
static func _skip_ticks_arg() -> int:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(SKIP_TICKS_ARG):
			var value: String = arg.trim_prefix(SKIP_TICKS_ARG)
			if value.is_valid_int() and value.to_int() >= 0:
				return value.to_int()
			push_warning("game_loop: ignoring %s (expected a non-negative integer)" % arg)
	return 0


# Steps the sim `ticks` times with the autopilot commands (no `ticked` signal: no view is bound yet).
func _fast_forward(ticks: int) -> void:
	for i in ticks:
		for cmd: SimCommand in _autopilot.call(&"next_commands"):
			world.submit(cmd)
		world.step()
	if ticks > 0 and autopilot_enabled:
		print("game_loop: autopilot fast-forwarded %d ticks, zones %s" % [ticks, _autopilot.call(&"zones_visited")])


func _process(delta: float) -> void:
	if world == null or not is_finite(delta) or delta <= 0.0:
		return
	var left: int = roundi(minf(delta * (world.debug.time_scale if world.debug != null else 1.0), MAX_FRAME_DT) * _UNITS_PER_SECOND)
	while left > 0:
		# integer units until the accumulator completes the next tick
		var to_tick: int = _UNITS_PER_TICK - roundi(world.interpolation_alpha() * _UNITS_PER_TICK)
		if left < to_tick:
			world.advance(left / _UNITS_PER_SECOND)
			break
		if _autopilot != null:
			for cmd: SimCommand in _autopilot.call(&"next_commands"):
				world.submit(cmd)
		world.advance(to_tick / _UNITS_PER_SECOND)
		left -= to_tick
		ticked.emit(world.tick)
	if _autopilot != null and not _autopilot_reported and bool(_autopilot.call(&"is_finished")):
		_autopilot_reported = true
		if autopilot_enabled:
			print("game_loop: autopilot finished at tick %d, zones %s" % [world.tick, _autopilot.call(&"zones_visited")])
		else:
			print("game_loop: demo finished at tick %d" % world.tick)
