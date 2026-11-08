class_name PlayerView
extends Node3D
## Presentation of the player fish: reads SimEntity state, never writes it.
##
## Keeps the state of the previous and the current tick (snapshotted on GameLoop.ticked) and interpolates
## between them with SimWorld.interpolation_alpha(). Visual-only juice on top: bank into turns and a small
## tilt from the pitch rate, tail-beat rate from speed (swim shader phase), juvenile/adult blend shapes from
## growth within the band. The model is unit length (S1 convention), so node scale = length_m; the shown length
## follows the sim length smoothly (growth after a meal, shrink after a death show as a short scale change) and
## pulse() adds a decaying scale kick (gulp, band change). Hidden while the player is dead (waiting to respawn).
## S7 hero rig: the model is the rigged GLB (spine + jaw, FishRig AnimationTree) with the rig material (vertex swim
## off). The tree is fed from sim state and events only: swim rate from speed (same beat curve as the shader swim),
## turn bend from the yaw rate, bite snap on the player's BITTEN / EATEN (as biter / eater), burst stroke on
## DASH_STARTED (Bite-Dash) and on boost start. Without the rig GLB it falls back to the S1 model + shader swim.

const RIG_MODEL_PATH: String = "res://assets/models/species/sp_fusiform_reef_fish_s1_rig_lod0.glb"
const RIG_MATERIAL: ShaderMaterial = preload("res://shaders/m_fish_rig.tres")
const MODEL_PATH: String = "res://assets/models/species/sp_fusiform_reef_fish_s1_lod0.glb"
const SWIM_MATERIAL: ShaderMaterial = preload("res://shaders/m_fish_swim.tres")
## Yaw rate (rad/s) that gives the full turn bend of the rig.
const TURN_FULL_RATE: float = 3.0
## Bank angle per unit of yaw rate (rad per rad/s) and its limit.
const BANK_PER_YAW_RATE: float = 0.22
const MAX_BANK: float = deg_to_rad(40.0)
## Extra nose tilt per unit of pitch rate (rad per rad/s) and its limit.
const TILT_PER_PITCH_RATE: float = 0.08
const MAX_TILT: float = deg_to_rad(12.0)
## Exponential smoothing rate of bank/tilt, 1/s.
const JUICE_SMOOTHING: float = 8.0
## Tail-beat rate (rad/s) at rest and at full boost speed.
const BEAT_IDLE: float = 3.0
const BEAT_MAX: float = 16.0
const BOOST_MULT_FALLBACK: float = 1.8
## Shown length follows the sim length at this rate, 1/s; the pulse decays at PULSE_DECAY, 1/s.
const GROWTH_RATE: float = 5.0
const PULSE_DECAY: float = 7.0

## Interpolated yaw/pitch of the fish this frame (radians), for the camera.
var yaw: float = 0.0
var pitch: float = 0.0

var _world: SimWorld
var _entity_id: int = 0
var _prev_pos: Vector3
var _cur_pos: Vector3
var _prev_yaw: float = 0.0
var _cur_yaw: float = 0.0
var _prev_pitch: float = 0.0
var _cur_pitch: float = 0.0
var _yaw_rate: float = 0.0
var _pitch_rate: float = 0.0
var _bank: float = 0.0
var _tilt: float = 0.0
var _phase: float = 0.0
var _top_speed: float = 1.0
var _mesh: MeshInstance3D = null
var _model: Node3D = null
var _shown_len: float = 0.0
var _pulse: float = 0.0
var _pulse_t: float = 1.0
var _rig: FishRig = null
var _turn: float = 0.0
var _event_tick: int = 0
var _was_boosting: bool = false


## Short scale kick: `amount` 0.2 = +20% at the peak (negative = squash), decays on its own.
func pulse(amount: float) -> void:
	_pulse = amount
	_pulse_t = 0.0


## World orientation of the fish model (no scale), e.g. for death effects.
func model_basis() -> Basis:
	return _model.global_transform.basis.orthonormalized() if _model != null else Basis.IDENTITY


## Binds the view to `entity_id`; `loop.ticked` drives the per-tick snapshots.
func setup(loop: GameLoop, entity_id: int) -> void:
	_world = loop.world
	_entity_id = entity_id
	_event_tick = _world.tick
	_build_model()
	_snapshot()
	_snapshot()
	var e: SimEntity = _world.get_entity(_entity_id)
	_shown_len = e.length_m if e != null else 0.0
	loop.ticked.connect(_on_ticked)
	_update_growth()
	_process(0.0)


func _on_ticked(_tick: int) -> void:
	_snapshot()
	_update_growth()
	_rig_events()


func _process(delta: float) -> void:
	if _world == null:
		return
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	if visible != e.alive:
		visible = e.alive
		_shown_len = e.length_m  # the respawned fish appears at its new size
		_prev_pos = e.position
		_cur_pos = e.position
	if not e.alive:
		return
	var a: float = _world.interpolation_alpha()
	position = _prev_pos.lerp(_cur_pos, a)
	yaw = lerp_angle(_prev_yaw, _cur_yaw, a)
	pitch = lerpf(_prev_pitch, _cur_pitch, a)
	var k: float = 1.0 - exp(-JUICE_SMOOTHING * delta)
	_bank = lerpf(_bank, clampf(_yaw_rate * BANK_PER_YAW_RATE, -MAX_BANK, MAX_BANK), k)
	_tilt = lerpf(_tilt, clampf(_pitch_rate * TILT_PER_PITCH_RATE, -MAX_TILT, MAX_TILT), k)
	# YXZ: roll (bank) in the fish frame, then pitch, then yaw; positive z rolls the left side down.
	# Rotation only (quaternion keeps the length scale set in _update_growth).
	_model.quaternion = Quaternion.from_euler(Vector3(pitch + _tilt, yaw, _bank))
	_shown_len = lerpf(_shown_len, e.length_m, 1.0 - exp(-GROWTH_RATE * delta))
	_pulse_t += delta
	var kick: float = _pulse * exp(-PULSE_DECAY * _pulse_t) * sin(minf(_pulse_t * 18.0, PI * 0.5))
	_model.scale = Vector3.ONE * _shown_len * (1.0 + kick)
	var beat: float = lerpf(BEAT_IDLE, BEAT_MAX, clampf(e.speed / _top_speed, 0.0, 1.0))
	if _rig != null:
		_turn = lerpf(_turn, clampf(_yaw_rate / TURN_FULL_RATE, -1.0, 1.0), k)
		_rig.set_swim_rate(beat / TAU)
		_rig.set_turn(_turn)
	elif _mesh != null:
		_phase = fmod(_phase + delta * beat, TAU * 64.0)
		_mesh.set_instance_shader_parameter(&"swim_phase", _phase)


func _snapshot() -> void:
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	_prev_pos = _cur_pos
	_prev_yaw = _cur_yaw
	_prev_pitch = _cur_pitch
	_cur_pos = e.position
	_cur_yaw = deg_to_rad(e.yaw_deg)
	_cur_pitch = deg_to_rad(e.pitch_deg)
	_yaw_rate = angle_difference(_prev_yaw, _cur_yaw) / SimWorld.TICK_DT
	_pitch_rate = (_cur_pitch - _prev_pitch) / SimWorld.TICK_DT


# Top speed of the band for the beat rate, juvenile/adult blend from growth in the band (scale: _process).
func _update_growth() -> void:
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	if _world.content == null:
		return
	var band: Dictionary = _world.content.get_band(e.band)
	var boost_mult: float = float(_world.content.get_ability(&"boost").get("speed_mult", BOOST_MULT_FALLBACK))
	_top_speed = maxf(float(band.get("swim_speed_mps", 1.0)) * boost_mult, 0.01)
	if _mesh == null:
		return
	var len_range: Dictionary = band.get("length_m", {}) if band.get("length_m") is Dictionary else {}
	var lo: float = float(len_range.get("min", e.length_m))
	var hi: float = float(len_range.get("max", e.length_m))
	var g: float = clampf((e.length_m - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 0.0
	_set_shape(&"juvenile", 1.0 - g)
	_set_shape(&"adult", g)


# Rig one-shots from this tick's events: bite snap when the player bit or swallowed something or its bite missed
# (BITE_MISSED: jaw snap in empty water), burst stroke on its Bite-Dash lunge and when a boost starts.
func _rig_events() -> void:
	if _world.tick == _event_tick:
		return
	if _rig != null:
		for ev: SimEvent in _world.events_since(_event_tick):
			match ev.type:
				SimEvent.Type.BITTEN, SimEvent.Type.EATEN:
					if ev.other_id == _entity_id:
						_rig.bite()
				SimEvent.Type.BITE_MISSED:
					if ev.entity_id == _entity_id:
						_rig.bite()
				SimEvent.Type.DASH_STARTED:
					if ev.entity_id == _entity_id:
						_rig.dash()
		var e: SimEntity = _world.get_entity(_entity_id)
		var boosting: bool = e != null and e.alive and e.boosting
		if boosting and not _was_boosting:
			_rig.dash()
		_was_boosting = boosting
	_event_tick = _world.tick


func _set_shape(shape: StringName, weight: float) -> void:
	var idx: int = _mesh.find_blend_shape_by_name(shape)
	if idx >= 0:
		_mesh.set_blend_shape_value(idx, weight)


# S7 rigged GLB with the shared rig material (vertex swim off) and a FishRig tree; else the S1 GLB with its own
# copy of the swim material (beat driven by the swim_phase instance uniform, so the material's own TIME-based
# speed is 0); a primitive fish (capsule body + cone tail) if neither GLB exists.
func _build_model() -> void:
	var rigged: bool = ResourceLoader.exists(RIG_MODEL_PATH)
	var path: String = RIG_MODEL_PATH if rigged else MODEL_PATH
	var scene: PackedScene = load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		_model = scene.instantiate() as Node3D
		var meshes: Array[Node] = _model.find_children("*", "MeshInstance3D", true, false)
		if not meshes.is_empty():
			_mesh = meshes[0] as MeshInstance3D
			if rigged:
				_mesh.material_override = RIG_MATERIAL
			else:
				var mat: ShaderMaterial = SWIM_MATERIAL.duplicate() as ShaderMaterial
				mat.set_shader_parameter(&"swim_speed", 0.0)
				_mesh.material_override = mat
		if rigged:
			_rig = FishRig.attach(_model)
	if _model == null:
		push_warning("player_view: %s missing, using a primitive fish" % MODEL_PATH)
		_model = _primitive_fish()
	_model.name = &"Model"
	add_child(_model)


static func _primitive_fish() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.15)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.14
	capsule.height = 0.75
	capsule.material = mat
	body.mesh = capsule
	body.rotation.x = PI * 0.5  # capsule axis Y -> Z
	body.position.z = -0.1
	root.add_child(body)
	var tail := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.16
	cone.height = 0.3
	cone.material = mat
	tail.mesh = cone
	tail.rotation.x = -PI * 0.5  # cone tip toward -Z (into the body), wide end at the tail
	tail.position.z = 0.35
	root.add_child(tail)
	return root
