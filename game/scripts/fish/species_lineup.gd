extends Node3D
## Dev lineup (S7a): all 8 MVP species at TRUE relative scale, sorted by size along +X,
## juvenile (left, smaller) next to adult, swimming with the swim shader presets.
##
## Scale: node scale = body length in metres (unit-length GLBs). The 100x size range
## (0.12 m plankton cell .. 10 m giant shark) does not fit one frame, so a camera tour
## visits 6 stops; stop k is held at t = k * tour_seconds / 5, which matches the 6 evenly
## spaced frames tools/capture.sh keeps when the capture runs tour_seconds * 60 frames
## (default 1440). The last stop is the overview: the giant shark at true scale at the far
## end, the small species as specks. The tour loops when run in a window.
## Puffers toggle the `inflated` blend shape (adult and juvenile in opposite phase).

## Species table (lengths from game/data/species/*.json: adult = max, juvenile = min;
## the giant shark has min = max, its juvenile preset is shown at 0.6 x; plankton is one
## swarm cell, see tools/blender/species/plankton.json).
const SPECIES: Array[Dictionary] = [
	{"name": "Plankton", "scene": preload("res://assets/models/species/sp_swarm_plankton_s1_lod0.glb"),
		"material": preload("res://shaders/m_plankton_swim.tres"), "juvenile_m": 0.08, "adult_m": 0.12},
	{"name": "Silver schooling fish", "scene": preload("res://assets/models/species/sp_fusiform_silver_schooling_fish_s1_lod0.glb"),
		"material": preload("res://shaders/m_fish_swim.tres"), "juvenile_m": 0.08, "adult_m": 0.15},
	{"name": "Small reef fish", "scene": preload("res://assets/models/species/sp_fusiform_reef_fish_s1_lod0.glb"),
		"material": preload("res://shaders/m_fish_swim.tres"), "juvenile_m": 0.10, "adult_m": 0.20},
	{"name": "Puffer", "scene": preload("res://assets/models/species/sp_round_puffer_s1_lod0.glb"),
		"material": preload("res://shaders/m_puffer_swim.tres"), "juvenile_m": 0.30, "adult_m": 0.50},
	{"name": "Barracuda", "scene": preload("res://assets/models/species/sp_fusiform_barracuda_s1_lod0.glb"),
		"material": preload("res://shaders/m_shark_swim.tres"), "juvenile_m": 0.80, "adult_m": 1.50},
	{"name": "Grouper", "scene": preload("res://assets/models/species/sp_fusiform_grouper_s1_lod0.glb"),
		"material": preload("res://shaders/m_fish_swim.tres"), "juvenile_m": 1.00, "adult_m": 2.00},
	{"name": "Shark", "scene": preload("res://assets/models/species/sp_fusiform_shark_s1_lod0.glb"),
		"material": preload("res://shaders/m_shark_swim.tres"), "juvenile_m": 2.50, "adult_m": 3.50},
	{"name": "Giant shark (boss)", "scene": preload("res://assets/models/species/sp_fusiform_giant_shark_s1_lod0.glb"),
		"material": preload("res://shaders/m_boss_swim.tres"), "juvenile_m": 6.00, "adult_m": 10.0},
]
## Camera stops: indices into SPECIES framed together (the last one is the overview).
const STOPS: Array[Array] = [[0, 1, 2], [2, 3], [4, 5], [5, 6], [6, 7], [0, 1, 2, 3, 4, 5, 6, 7]]
## Yaw that turns the -Z nose to screen-left and a bit towards the camera (3/4 view).
const FISH_YAW: float = PI / 2.0 + 0.45
const PHASE_STEP: float = 2.1
const INFLATE_PERIOD_S: float = 4.0
## Fraction of the time between two stops spent holding still on each stop.
const HOLD: float = 0.6

## Seconds from the first to the last stop (capture: tour_seconds * 60 frames).
@export var tour_seconds: float = 24.0

var _elapsed: float = 0.0
var _stop_pos: Array[Vector3] = []
var _stop_target: Array[Vector3] = []
var _puffers: Array[MeshInstance3D] = []

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	var extents: Array[Vector2] = []
	var x: float = 0.0
	var prev_adult: float = 0.0
	for i: int in SPECIES.size():
		var entry: Dictionary = SPECIES[i]
		var adult_m: float = entry["adult_m"]
		var juvenile_m: float = entry["juvenile_m"]
		# adult centre at x; juvenile to its left, slightly lower and nearer the camera
		x += 0.5 * prev_adult + 0.35 * (prev_adult + adult_m) + juvenile_m + 0.75 * adult_m
		var juvenile_pos: Vector3 = Vector3(x - 0.75 * adult_m, -0.2 * adult_m, 0.15 * adult_m)
		_add_fish(entry, juvenile_m, 0.0, juvenile_pos, 2 * i)
		_add_fish(entry, adult_m, 1.0, Vector3(x, 0.0, 0.0), 2 * i + 1)
		_add_label(entry, Vector3(x - 0.3 * adult_m, 0.42 * adult_m, 0.0), adult_m)
		extents.append(Vector2(juvenile_pos.x - 0.6 * juvenile_m, x + 0.6 * adult_m))
		prev_adult = adult_m
	for stop: Array in STOPS:
		var lo: float = INF
		var hi: float = -INF
		var tallest: float = 0.0
		for idx: int in stop:
			lo = minf(lo, extents[idx].x)
			hi = maxf(hi, extents[idx].y)
			tallest = maxf(tallest, SPECIES[idx]["adult_m"])
		var centre: Vector3 = Vector3(0.5 * (lo + hi), 0.05 * tallest, 0.0)
		var half_hfov: float = atan(tan(deg_to_rad(_camera.fov) * 0.5) * 16.0 / 9.0)
		var dist: float = maxf(0.5 * (hi - lo) * 1.1 / tan(half_hfov), 1.6 * tallest)
		_stop_target.append(centre)
		_stop_pos.append(centre + Vector3(0.0, 0.18 * dist, dist))
	_camera.far = maxf(_camera.far, 2.0 * _stop_pos[-1].z)
	_update(0.0)


func _process(delta: float) -> void:
	_elapsed += delta
	_update(_elapsed)


func _update(t: float) -> void:
	var leg: float = tour_seconds / float(STOPS.size() - 1)
	var s: float = fmod(t / leg, float(STOPS.size()))
	var k: int = int(s) % STOPS.size()
	var k1: int = (k + 1) % STOPS.size()
	# hold around each stop (stop k sits at s = k), smooth move in between
	var f: float = s - floorf(s)
	var w: float = smoothstep(0.5 * HOLD, 1.0 - 0.5 * HOLD, f)
	var pos: Vector3 = _stop_pos[k].lerp(_stop_pos[k1], w)
	var target: Vector3 = _stop_target[k].lerp(_stop_target[k1], w)
	_camera.look_at_from_position(pos, target)

	for i: int in _puffers.size():
		var wave: float = sin(TAU * t / INFLATE_PERIOD_S + PI * float(i))
		_set_shape(_puffers[i], &"inflated", smoothstep(-0.3, 0.3, wave))


func _add_fish(entry: Dictionary, length_m: float, growth: float, pos: Vector3, index: int) -> void:
	var fish: Node3D = (entry["scene"] as PackedScene).instantiate() as Node3D
	add_child(fish)
	fish.position = pos
	fish.rotation = Vector3(0.0, FISH_YAW, 0.0)
	fish.scale = Vector3.ONE * length_m
	var mesh_instance: MeshInstance3D = _find_mesh(fish)
	if mesh_instance == null:
		push_error("species_lineup: %s has no MeshInstance3D" % entry["name"])
		return
	_set_shape(mesh_instance, &"juvenile", 1.0 - growth)
	_set_shape(mesh_instance, &"adult", growth)
	mesh_instance.material_override = entry["material"]
	mesh_instance.set_instance_shader_parameter(&"swim_phase", PHASE_STEP * float(index))
	if mesh_instance.find_blend_shape_by_name(&"inflated") >= 0:
		_puffers.append(mesh_instance)


func _add_label(entry: Dictionary, pos: Vector3, adult_m: float) -> void:
	var label: Label3D = Label3D.new()
	label.text = "%s\n%.2f-%.2f m" % [entry["name"], entry["juvenile_m"], adult_m]
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 40
	label.outline_size = 10
	label.pixel_size = 0.0012 * adult_m
	label.position = pos
	add_child(label)


func _set_shape(mesh_instance: MeshInstance3D, shape: StringName, weight: float) -> void:
	var idx: int = mesh_instance.find_blend_shape_by_name(shape)
	if idx < 0:
		push_error("species_lineup: %s has no blend shape %s" % [mesh_instance.name, shape])
		return
	mesh_instance.set_blend_shape_value(idx, weight)


func _find_mesh(node: Node) -> MeshInstance3D:
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
	return null
