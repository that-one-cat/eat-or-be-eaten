class_name BossFx
extends Node3D
## Giant shark boss presentation (GAME_DESIGN §7): the telegraph, the charge streak and the stunned wobble on the
## boss node that NpcViews draws (NpcViews.view_node). Reads events and entity state only, never writes the sim.
##  - BOSS_TELL (value = wind-up seconds): for the wind-up the shark rears its nose up (ARCH_DEG, with a rising
##    tremble), squashes along its length, and its rim/glow flashes warm (a duplicate of its swim material, the shared
##    .tres is never touched); when the tell targets the player, an edge vignette (Hud.vignette) runs for the wind-up.
##  - BOSS_DASH: the arch snaps back, a bubble/streak trail (CPUParticles3D, global coords, velocity-aligned capsules)
##    follows the tail for the charge, and the camera shakes when the charge passes close to the player.
##  - STUNNED (boss_state): slow roll wobble + a cool rim pulse until the finisher (FeedbackFx does the finisher
##    slow-mo / punch / CHOMP on BOSS_DEFEATED; the boss node goes to its X-ray kill flash, the giant remains are
##    NpcViews food bits).
## Wind-up / charge timers run on game time (scaled delta), like the sim seconds they mirror. process_priority 20:
## the pose tweak is applied after NpcViews wrote the interpolated transform of the frame.
## S7: the boss node is the rigged GLB; its skeleton (gape + coil on the tell, burst stroke on the charge, bite snap)
## is BossView's, a child created in setup(). The node-level nose-up arch / squash here is kept on top of it.

const ARCH_DEG: float = 16.0
const TREMBLE_DEG: float = 1.8
const TREMBLE_HZ: float = 9.0
const SQUASH: float = 0.07
const FLASH_HZ: float = 3.0
const TELL_RIM: float = 2.4
const TELL_GLOW_MULT: float = 2.6
const TELL_RIM_COLOR: Color = Color(1.0, 0.86, 0.62)
const STUN_RIM_COLOR: Color = Color(0.6, 0.95, 1.0)
const STUN_ROLL_DEG: float = 14.0
const STUN_HZ: float = 0.45
const TELL_VIGNETTE: Color = Color(1.0, 0.42, 0.22, 0.7)
## Camera shake when the charging boss passes within this distance of the player.
const DASH_SHAKE_RANGE_M: float = 14.0
const DASH_SHAKE: float = 0.04

var _world: SimWorld
var _player_id: int = 0
var _npc_views: NpcViews
var _camera: CameraRig
var _hud: Hud
var _event_tick: int = 0
var _boss_id: int = -1
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _base_rim: float = 0.15
var _base_glow: float = 2.5
var _base_rim_color: Color = Color(0.72, 0.95, 1.0)
var _tell_total: float = 0.0
var _tell_left: float = 0.0
var _dash_left: float = 0.0
var _time: float = 0.0
var _trail: CPUParticles3D


func setup(loop: GameLoop, player_id: int, npc_views: NpcViews, camera: CameraRig, hud: Hud) -> void:
	_world = loop.world
	_player_id = player_id
	_npc_views = npc_views
	_camera = camera
	_hud = hud
	_event_tick = _world.tick
	_trail = _make_trail()
	loop.ticked.connect(_on_ticked)
	var view := BossView.new()
	view.name = &"BossView"
	add_child(view)
	view.setup(loop, npc_views)


func _ready() -> void:
	process_priority = 20


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.BOSS_TELL:
				_boss_id = ev.entity_id
				_tell_total = maxf(ev.value, 0.05)
				_tell_left = _tell_total
				if ev.other_id == _player_id:
					_hud.vignette(TELL_VIGNETTE, _tell_total)
			SimEvent.Type.BOSS_DASH:
				_boss_id = ev.entity_id
				_tell_left = 0.0
				_dash_left = float(ev.data.get("duration", 1.0))
				var dir: Vector3 = ev.data.get("dir", Vector3.FORWARD)
				_trail.direction = -dir
				_trail.emitting = true
			SimEvent.Type.DASH_ENDED:
				if ev.entity_id == _boss_id:
					_dash_left = 0.0
					_trail.emitting = false
			SimEvent.Type.BOSS_DEFEATED:
				_tell_left = 0.0
				_dash_left = 0.0
				_trail.emitting = false
	_event_tick = _world.tick


func _process(delta: float) -> void:
	if _world == null:
		return
	_time += delta
	var bid: int = _world.boss_id()
	var boss: SimEntity = _world.get_entity(bid)
	var node: Node3D = _npc_views.view_node(bid) if boss != null else null
	if node == null:
		_mesh = null
		_trail.emitting = false
		return
	_bind(node)
	_tell_left = maxf(_tell_left - delta, 0.0)
	_dash_left = maxf(_dash_left - delta, 0.0)
	var rim: float = _base_rim
	var glow: float = _base_glow
	var rim_color: Color = _base_rim_color
	if _tell_left > 0.0:
		var t: float = 1.0 - _tell_left / _tell_total
		var arch: float = smoothstep(0.0, 0.3, t)
		var tremble: float = deg_to_rad(TREMBLE_DEG) * t * sin(_time * TAU * TREMBLE_HZ)
		node.quaternion = node.quaternion * Quaternion(Vector3.RIGHT, deg_to_rad(ARCH_DEG) * arch + tremble)
		node.scale = Vector3.ONE * boss.length_m * Vector3(1.0 + SQUASH * 0.5 * arch, 1.0 + SQUASH * 0.5 * arch, 1.0 - SQUASH * arch)
		var flash: float = arch * (0.55 + 0.45 * cos(t * TAU * FLASH_HZ))
		rim = lerpf(_base_rim, TELL_RIM, flash)
		glow = _base_glow * lerpf(1.0, TELL_GLOW_MULT, flash)
		rim_color = _base_rim_color.lerp(TELL_RIM_COLOR, arch)
	else:
		node.scale = Vector3.ONE * boss.length_m
		if boss.boss_state == BossBrain.State.STUNNED:
			var w: float = sin(_time * TAU * STUN_HZ)
			node.quaternion = node.quaternion * Quaternion(Vector3.FORWARD, deg_to_rad(STUN_ROLL_DEG) * w)
			var pulse: float = 0.5 + 0.5 * sin(_time * TAU * STUN_HZ * 2.0)
			rim = lerpf(_base_rim, 1.4, pulse)
			rim_color = STUN_RIM_COLOR
		elif _dash_left > 0.0:
			rim = lerpf(_base_rim, TELL_RIM * 0.6, clampf(_dash_left, 0.0, 1.0))
			rim_color = TELL_RIM_COLOR
	if _mat != null:
		_mat.set_shader_parameter(&"rim_strength", rim)
		_mat.set_shader_parameter(&"glow_strength", glow)
		_mat.set_shader_parameter(&"rim_color", rim_color)
	if _dash_left > 0.0:
		_trail.global_position = node.global_position - boss.heading * (boss.length_m * 0.3)
		var p: SimEntity = _world.get_entity(_player_id)
		if p != null and p.position.distance_to(boss.position) < DASH_SHAKE_RANGE_M + boss.length_m * 0.5:
			_camera.add_trauma(DASH_SHAKE)
	else:
		_trail.emitting = false


# Gives the boss node its own copy of the swim material (once per node) and remembers the base look.
func _bind(node: Node3D) -> void:
	var mesh: MeshInstance3D = CrowdAssets.find_mesh(node)
	if mesh == _mesh:
		return
	_mesh = mesh
	_mat = null
	if mesh == null or not (mesh.material_override is ShaderMaterial):
		return
	_mat = (mesh.material_override as ShaderMaterial).duplicate() as ShaderMaterial
	mesh.material_override = _mat
	_base_rim = float(_mat.get_shader_parameter(&"rim_strength")) if _mat.get_shader_parameter(&"rim_strength") != null else _base_rim
	_base_glow = float(_mat.get_shader_parameter(&"glow_strength")) if _mat.get_shader_parameter(&"glow_strength") != null else _base_glow
	var rc: Variant = _mat.get_shader_parameter(&"rim_color")
	if rc is Vector3:
		_base_rim_color = Color((rc as Vector3).x, (rc as Vector3).y, (rc as Vector3).z)
	elif rc is Color:
		_base_rim_color = rc


# Charge trail: bubbles + streaks left in world space behind the tail, aligned to their velocity.
func _make_trail() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.local_coords = false
	p.amount = 90
	p.lifetime = 0.9
	p.explosiveness = 0.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 1.6
	p.spread = 12.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 7.0
	p.gravity = Vector3(0.0, 0.6, 0.0)
	p.damping_min = 2.0
	p.damping_max = 4.0
	p.particle_flag_align_y = true
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.2))
	p.scale_amount_curve = curve
	var fade := Gradient.new()
	fade.set_color(0, Color(0.9, 0.98, 1.0, 0.75))
	fade.set_color(1, Color(0.9, 0.98, 1.0, 0.0))
	p.color_ramp = fade
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.06
	mesh.height = 1.1
	mesh.radial_segments = 6
	mesh.rings = 1
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/fx_bubble.gdshader")
	mesh.material = mat
	p.mesh = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p
