extends Node3D
## S4 crowd benchmark (engine tripwire, GAME_DESIGN section 12), windowed, Forward+, 1080p:
##   godot --path game --resolution 1920x1080 --disable-vsync --fixed-fps 60 res://bench/bench_crowd.tscn \
##     -- --frames=<N> [--warmup=<frames>] [--quality=low] [--map=reef|greybox] [--no-gate]   (tools/bench.sh does this)
## Instances the reef (`--map=reef`, default: the dressed res://scenes/maps/reef.tscn, S5; `--map=greybox`:
## res://scenes/maps/reef_greybox.tscn) - GameLoop with spawners, schools, plankton and vitals on, the crowd renderer,
## the look stack - with world seed WORLD_SEED (999 NPC fish, as bench_sim), then
## replaces the player's input and camera: PlayerInput is idled, the CameraRig is driven along a fixed path
## (PATH_POINTS: shallows -> kelp forest -> rock arches, PATH_S seconds of sim time, holds at the end) and the
## player fish swims ahead of the camera through SimCommands (MOVE toward the path point PLAYER_LEAD_M ahead,
## BOOST when behind), so promotions to the interactive tier happen in view. The path parameter is sim time
## (world.tick + interpolation), so with --fixed-fps every frame shows the same state on every machine.
## Bench-only extras (S4 placeholders for CLAUDE.md rule 11: a projected caustics Decal following the camera and
## LIGHT_CARDS additive light-shaft cards along the path) are only added when the scene has no S5 look stack
## (UnderwaterFx node); both reef scenes have it now. `--quality=<tier>` is read by the reef itself (QualitySettings
## user arg) and recorded. Crowd counters skip the map dressing MultiMeshes (group `env_dressing`).
## Logs per measured frame: wall time between two frames (vsync off, so this is the real CPU+GPU frame cost;
## `_process` delta is fixed by --fixed-fps), Performance.TIME_PROCESS, viewport GPU/CPU render time, draw calls,
## primitives, objects; per sim tick: SimWorld.last_step_usec and school/flocking (brains + schools phases).
## Counters: sim tiers (ambient members, interactive, large) and the drawn crowd (every MultiMeshInstance3D under
## the reef: visible instances), plus any node's `bench_stats() -> Dictionary` (renderer API, optional).
## Prints one BENCH_JSON line; thresholds from res://bench/thresholds.json ("crowd"); exit 0 / 2 (tripwire) /
## 3 (invalid: headless, display asleep, no crowd renderer, or fewer NPC fish), always 0 with --no-gate.

const BenchUtil := preload("res://bench/bench_util.gd")

const MAP_SCENES: Dictionary = {
	"reef": "res://scenes/maps/reef.tscn",
	"greybox": "res://scenes/maps/reef_greybox.tscn",
}
const DEFAULT_MAP: String = "reef"
const DEFAULT_FRAMES: int = 3600
const DEFAULT_WARMUP: int = 120
const WORLD_SEED: int = 1
const PATH_S: float = 60.0
## Camera path control points (linear segments); y is lifted to at least PATH_CLEARANCE_M above the seabed.
const PATH_POINTS: Array[Vector3] = [
	Vector3(0, -6, -245), Vector3(-6, -8, -210), Vector3(-14, -10, -175), Vector3(-12, -14, -140),
	Vector3(-8, -19, -105), Vector3(-4, -23, -72), Vector3(-2, -27, -40), Vector3(-8, -31, -20),
]
## Zone label per path point (for the report).
const PATH_ZONES: PackedStringArray = ["shallows", "shallows", "shallows", "kelp_forest", "kelp_forest", "kelp_forest", "kelp_forest", "rock_arches"]
const PATH_CLEARANCE_M: float = 3.0
const CAM_HEIGHT_M: float = 1.2
const CAM_LOOK_AHEAD_M: float = 12.0
const PLAYER_LEAD_M: float = 7.0
const PLAYER_BOOST_BEHIND_M: float = 4.0
const BOOST_MIN_STAMINA: float = 25.0
const LIGHT_CARDS: int = 24
const COUNT_SAMPLE_FRAMES: int = 30

var _frames: int = DEFAULT_FRAMES
var _warmup: int = DEFAULT_WARMUP
var _gate: bool = true
var _quality: String = "high"
var _map: String = DEFAULT_MAP
var _placeholders: bool = false
var _reef: Node3D = null
var _loop: GameLoop = null
var _world: SimWorld = null
var _cam: Camera3D = null
var _curve: Curve3D = Curve3D.new()
var _caustics: Decal = null
var _player_id: int = 0
var _boosting: bool = false
var _vp_rid: RID

var _frame: int = 0
var _last_usec: int = 0
var _wall0: int = 0
var _frame_us := PackedFloat64Array()
var _process_us := PackedFloat64Array()
var _gpu_us := PackedFloat64Array()
var _render_cpu_us := PackedFloat64Array()
var _sim_frame_us := PackedFloat64Array()
var _tick_us := PackedFloat64Array()
var _school_us := PackedFloat64Array()
var _draw_calls := PackedInt32Array()
var _primitives := PackedInt32Array()
var _objects := PackedInt32Array()
var _c_ambient := PackedInt32Array()
var _c_inter := PackedInt32Array()
var _c_large := PackedInt32Array()
var _c_drawn := PackedInt32Array()
var _sim_acc_us: int = 0
var _player_lag := PackedFloat64Array()


func _ready() -> void:
	var args: Dictionary = BenchUtil.parse_args()
	_frames = maxi(1, BenchUtil.arg_int(args, "frames", DEFAULT_FRAMES))
	_warmup = maxi(0, BenchUtil.arg_int(args, "warmup", DEFAULT_WARMUP))
	_gate = not args.has("no-gate")
	_quality = String(args.get("quality", "high"))
	_map = String(args.get("map", DEFAULT_MAP))
	if not MAP_SCENES.has(_map):
		push_error("bench_crowd: unknown --map=%s (reef|greybox)" % _map)
		get_tree().quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# measure after every other node's _process of the frame
	process_priority = 1000

	var packed: PackedScene = load(MAP_SCENES[_map]) as PackedScene
	_reef = packed.instantiate() as Node3D
	_loop = _reef.get_node("GameLoop") as GameLoop
	_loop.world_seed = WORLD_SEED
	add_child(_reef)
	_world = _loop.world
	if _world == null:
		push_error("bench_crowd: the reef did not start (content invalid?)")
		get_tree().quit(1)
		return
	_player_id = _loop.player_id
	_world.profile_clock = Callable(Time, "get_ticks_usec")
	_loop.ticked.connect(_on_ticked)
	var input: Node = _reef.get_node_or_null("PlayerInput")
	if input != null:
		input.set_physics_process(false)
		input.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_cam = _reef.get_node_or_null("CameraRig") as Camera3D
	_cam.set_process(false)
	_cam.current = true
	_build_path()
	_placeholders = _reef.get_node_or_null("UnderwaterFx") == null
	if _placeholders:
		_add_caustics()
		_add_light_cards()
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_update_camera()
	_wall0 = Time.get_ticks_usec()
	_last_usec = _wall0


func _process(_delta: float) -> void:
	if _world == null:
		return
	var now: int = Time.get_ticks_usec()
	var measuring: bool = _frame >= _warmup
	if measuring and _frame > _warmup:
		_frame_us.append(float(now - _last_usec))
		_process_us.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1e6)
		_gpu_us.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid) * 1000.0)
		_render_cpu_us.append(RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid) * 1000.0)
		_sim_frame_us.append(float(_sim_acc_us))
		_draw_calls.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		_primitives.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		_objects.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
		if _frame_us.size() % COUNT_SAMPLE_FRAMES == 1:
			_sample_counts()
	_sim_acc_us = 0
	_last_usec = now
	_update_camera()
	_drive_player()
	_frame += 1
	if _frame_us.size() >= _frames:
		_finish()


func _on_ticked(_tick: int) -> void:
	if _frame < _warmup:
		return
	_tick_us.append(float(_world.last_step_usec))
	_school_us.append(float(_world.phase_usec[SimWorld.Phase.BRAINS] + _world.phase_usec[SimWorld.Phase.SCHOOLS]))
	_sim_acc_us += _world.last_step_usec


# ------------------------------------------------------------------ path, camera, player

func _build_path() -> void:
	for p in PATH_POINTS:
		var q: Vector3 = p
		if _world.seabed != null:
			q.y = maxf(q.y, _world.seabed.height_at(q.x, q.z) + PATH_CLEARANCE_M)
		_curve.add_point(q)
	_curve.bake_interval = 0.5


func _path_distance() -> float:
	var t: float = (float(_world.tick) + _world.interpolation_alpha()) / float(SimWorld.TICK_RATE)
	return clampf(t / PATH_S, 0.0, 1.0) * _curve.get_baked_length()


func _update_camera() -> void:
	var d: float = _path_distance()
	var pos: Vector3 = _curve.sample_baked(d) + Vector3.UP * CAM_HEIGHT_M
	var look: Vector3 = _curve.sample_baked(minf(d + CAM_LOOK_AHEAD_M, _curve.get_baked_length()))
	if look.distance_squared_to(pos) < 0.01:
		look = pos + Vector3.FORWARD
	_cam.global_position = pos
	_cam.look_at(look, Vector3.UP)
	if _caustics != null:
		_caustics.global_position = Vector3(pos.x, pos.y - 10.0, pos.z)
		_caustics.rotation.y = float(_world.tick) / float(SimWorld.TICK_RATE) * 0.03


# Input stand-in: SimCommands only (rule 2), like PlayerInput would send them.
func _drive_player() -> void:
	var e: SimEntity = _world.get_entity(_player_id)
	if e == null or not e.alive:
		return
	var d: float = _path_distance()
	var aim: Vector3 = _curve.sample_baked(minf(d + PLAYER_LEAD_M, _curve.get_baked_length()))
	var to: Vector3 = aim - e.position
	var dir: Vector3 = to.normalized() if to.length_squared() > 1e-6 else e.heading
	_world.submit(SimCommand.move(_player_id, dir, clampf(to.length() / 3.0, 0.0, 1.0)))
	var want: bool = to.length() > PLAYER_BOOST_BEHIND_M and e.stamina > (0.0 if _boosting else BOOST_MIN_STAMINA)
	if want != _boosting:
		_boosting = want
		_world.submit(SimCommand.boost(_player_id, want))
	if _frame >= _warmup:
		_player_lag.append(e.position.distance_to(_curve.sample_baked(d)))


# ------------------------------------------------------------------ bench-only visuals

# Caustics placeholder: a cellular-noise pattern projected down onto the seabed around the camera.
func _add_caustics() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	noise.frequency = 0.035
	noise.seed = 7
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0, 0, 0, 0))
	ramp.set_color(1, Color(1, 1, 1, 1))
	ramp.set_offset(0, 0.25)
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	_caustics = Decal.new()
	_caustics.name = "BenchCaustics"
	_caustics.size = Vector3(70.0, 40.0, 70.0)
	_caustics.texture_albedo = tex
	_caustics.texture_emission = tex
	_caustics.emission_energy = 0.5
	_caustics.albedo_mix = 0.35
	_caustics.modulate = Color(0.75, 0.95, 1.0, 0.6)
	_caustics.upper_fade = 0.2
	_caustics.lower_fade = 0.4
	add_child(_caustics)


# Light cards: vertical additive quads from the surface down, billboarded around Y, seeded along the path.
func _add_light_cards() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.0))
	grad.set_color(1, Color(1, 1, 1, 1.0))
	var fade := GradientTexture2D.new()
	fade.gradient = grad
	fade.fill_from = Vector2(0.5, 1.0)
	fade.fill_to = Vector2(0.5, 0.0)
	fade.width = 8
	fade.height = 128
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.albedo_color = Color(0.7, 0.95, 1.0, 0.10)
	mat.albedo_texture = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(3.0, 24.0)
	quad.material = mat
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var length: float = _curve.get_baked_length()
	for i in LIGHT_CARDS:
		var p: Vector3 = _curve.sample_baked(length * (float(i) + 0.5) / float(LIGHT_CARDS))
		var card := MeshInstance3D.new()
		card.name = "BenchLightCard%d" % i
		card.mesh = quad
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		card.position = Vector3(p.x + rng.randf_range(-18.0, 18.0), -1.0 - quad.size.y * 0.5, p.z + rng.randf_range(-10.0, 10.0))
		add_child(card)


# ------------------------------------------------------------------ counters, result

func _sample_counts() -> void:
	_c_ambient.append(_ambient_members())
	_c_inter.append(_world.npc_count(SimWorld.TIER_INTERACTIVE))
	_c_large.append(_world.npc_count(SimWorld.TIER_LARGE))
	_c_drawn.append(int(_multimesh_stats(_reef)["visible_instances"]))


func _ambient_members() -> int:
	if _world.schools == null:
		return 0
	var total: int = 0
	for s in _world.schools.school_count():
		total += _world.schools.alive_count(_world.schools.get_school(s))
	return total


# MultiMeshInstance3D nodes under `root` (visible in tree) and their drawn instances.
func _multimesh_stats(root: Node) -> Dictionary:
	var nodes: int = 0
	var visible_nodes: int = 0
	var instances: int = 0
	for n in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi: MultiMeshInstance3D = n as MultiMeshInstance3D
		if mmi.is_in_group(&"env_dressing"):
			continue
		nodes += 1
		if mmi.multimesh == null or not mmi.is_visible_in_tree():
			continue
		visible_nodes += 1
		var mm: MultiMesh = mmi.multimesh
		instances += mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	return {"nodes": nodes, "visible_nodes": visible_nodes, "visible_instances": instances}


# `bench_stats() -> Dictionary` of every node under the reef that has it (crowd renderer API, optional).
func _renderer_stats() -> Dictionary:
	var out: Dictionary = {}
	for n in _reef.find_children("*", "", true, false):
		if n.has_method(&"bench_stats"):
			out[String(n.name)] = n.call(&"bench_stats")
	return out


func _finish() -> void:
	set_process(false)
	_sample_counts()
	var frame_stats: Dictionary = BenchUtil.stats_ms(_frame_us)
	var school_stats: Dictionary = BenchUtil.stats_ms(_school_us)
	var npc_fish_min: int = 0
	for j in _c_ambient.size():
		var total: int = _c_ambient[j] + _c_inter[j] + _c_large[j]
		npc_fish_min = total if j == 0 else mini(npc_fish_min, total)
	var drawn: Dictionary = BenchUtil.count_stats(_c_drawn)
	var mm_end: Dictionary = _multimesh_stats(_reef)
	var env: Environment = (_reef.get_node_or_null("WorldEnvironment") as WorldEnvironment).environment
	var headless: bool = DisplayServer.get_name() == "headless"
	var lag := PackedFloat64Array(_player_lag)
	lag.sort()
	var result: Dictionary = {"bench": "bench_crowd"}
	result.merge(BenchUtil.machine())
	result.merge({
		"quality": _quality,
		"map": _map,
		"window": {
			"display_server": DisplayServer.get_name(),
			"size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
			"viewport": [int(get_viewport().get_visible_rect().size.x), int(get_viewport().get_visible_rect().size.y)],
			"screen_scale": DisplayServer.screen_get_scale(),
			"vsync": DisplayServer.window_get_vsync_mode(),
			"focused": get_window().has_focus(),
		},
		"seed": WORLD_SEED,
		"frames_measured": _frame_us.size(),
		"warmup_frames": _warmup,
		"sim_ticks_measured": _tick_us.size(),
		"wall_s": snappedf(float(Time.get_ticks_usec() - _wall0) / 1e6, 0.01),
		"path": {"seconds": PATH_S, "length_m": snappedf(_curve.get_baked_length(), 0.1), "zones": PATH_ZONES,
			"player_lag_m_p50": snappedf(BenchUtil.percentile(lag, 0.5), 0.1), "player_lag_m_p95": snappedf(BenchUtil.percentile(lag, 0.95), 0.1)},
		"frame_ms": frame_stats,
		"frame_ms_definition": "wall time between two frames, vsync off (fixed-fps delta is constant)",
		"process_ms": BenchUtil.stats_ms(_process_us),
		"process_ms_definition": "Performance.TIME_PROCESS (the engine refreshes this monitor only about once per second: coarse)",
		"gpu_render_ms": BenchUtil.stats_ms(_gpu_us),
		"cpu_render_ms": BenchUtil.stats_ms(_render_cpu_us),
		"render_time_definition": "RenderingServer.viewport_get_measured_render_time_gpu/cpu of the root viewport (0 = not reported by the driver)",
		"sim_ms_per_frame": BenchUtil.stats_ms(_sim_frame_us),
		"sim_tick_ms": BenchUtil.stats_ms(_tick_us),
		"school_flocking_ms": school_stats,
		"school_flocking_definition": "per sim tick: brains phase (every NPC brain think) + schools phase (TierManager); at 60 fps at most one tick per frame",
		"draw_calls": BenchUtil.count_stats(_draw_calls),
		"primitives": BenchUtil.count_stats(_primitives),
		"objects": BenchUtil.count_stats(_objects),
		"memory": {
			"static_mb": snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1),
			"static_peak_mb": snappedf(float(OS.get_static_memory_peak_usage()) / 1048576.0, 0.1),
			"video_mb": snappedf(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0, 0.1),
			"texture_mb": snappedf(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0, 0.1),
			"buffer_mb": snappedf(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)) / 1048576.0, 0.1),
			"rss_mb": BenchUtil.rss_mb(),
		},
		"entities": {
			"ambient_members": BenchUtil.count_stats(_c_ambient),
			"interactive": BenchUtil.count_stats(_c_inter),
			"large": BenchUtil.count_stats(_c_large),
			"npc_fish_min": npc_fish_min,
		},
		"crowd_drawn": {"multimesh_nodes": mm_end["nodes"], "multimesh_visible_nodes": mm_end["visible_nodes"], "visible_instances": drawn},
		"renderer_stats": _renderer_stats(),
		"pre_renderer": int(mm_end["nodes"]) == 0,
		"effects": {"depth_fog": env != null and env.fog_enabled, "look_stack": not _placeholders,
			"caustics": "bench decal placeholder" if _placeholders else "env/terrain shaders",
			"light_cards": LIGHT_CARDS if _placeholders else 0},
	})
	var th: Dictionary = BenchUtil.load_thresholds("crowd")
	var tw: Dictionary = th.get("tripwires", {})
	var va: Dictionary = th.get("validity", {})
	var tripwires: Dictionary = {
		"frame_p95_ms": BenchUtil.at_most(frame_stats["p95"], float(tw.get("frame_p95_ms", 16.7))),
		"school_flocking_p95_ms": BenchUtil.at_most(school_stats["p95"], float(tw.get("school_flocking_p95_ms", 3.0))),
	}
	var validity: Dictionary = {
		"windowed": {"value": not headless, "pass": not headless},
		"display_awake": BenchUtil.at_most(frame_stats["p50"], float(va.get("frame_p50_max_ms", 250.0))),
		"npc_fish": BenchUtil.at_least(npc_fish_min, float(va.get("npc_fish_min", 900))),
		"crowd_renderer": BenchUtil.at_least(float(drawn["min"]), float(va.get("drawn_instances_min", 250))),
		# a window that is not drawing (asleep, occluded) also yields fast frames: require real draw calls
		"draw_calls": BenchUtil.at_least(float(BenchUtil.count_stats(_draw_calls)["min"]), float(va.get("draw_calls_min", 10))),
		"frames_measured": BenchUtil.at_least(float(_frame_us.size()), float(va.get("frames_measured_min", 3600))),
		"load_avg_per_thread": BenchUtil.load_check(result, float(va.get("load_avg_per_thread_max", 1.0))),
	}
	var code: int = BenchUtil.finish(result, tripwires, validity, _gate)
	get_tree().quit(code)
