class_name SonarFx
extends Node3D
## Sonar presentation (GAME_DESIGN §4): on the player's SONAR_PULSE an expanding wave (sphere shell + flat ring) runs
## out to the pulse radius, and every contact of the event gets a camera-facing ring that follows the creature for the
## pulse duration (3 s from data). Rings are tinted by the event's `rel` with a colour-blind-safe pair + neutral
## (smaller = blue, similar = pale neutral, bigger = orange) and the shape repeats it (thin ring / ring + dot / thick
## ring with ticks), so it never depends on colour alone. A ring appears when the wave reaches the contact. Reads
## events and entity positions only. One MultiMeshInstance3D for all rings (one draw call).

const CONTACT_SHADER: Shader = preload("res://shaders/fx_sonar_contact.gdshader")
const WAVE_SHADER: Shader = preload("res://shaders/fx_sonar_wave.gdshader")
const REL_COLORS: Dictionary[String, Color] = {
	"smaller": Color(0.25, 0.6, 1.0),
	"similar": Color(0.95, 0.96, 0.92),
	"bigger": Color(1.0, 0.55, 0.1),
}
const REL_SHAPES: Dictionary[String, float] = {"smaller": 0.0, "similar": 1.0, "bigger": 2.0}
## Wave travel time to the full radius (s, game time).
const WAVE_S: float = 0.9
## Ring diameter: creature length x this, at least this fraction of the camera distance (stays visible far away).
const RING_PER_LENGTH: float = 1.6
const RING_MIN_SCREEN_FRAC: float = 0.05
const FADE_IN_S: float = 0.15
const FADE_OUT_S: float = 0.6
const CAPACITY: int = 256

var _world: SimWorld
var _player_id: int = 0
var _camera: Camera3D
var _event_tick: int = 0
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _wave: MeshInstance3D
var _wave_mat: ShaderMaterial
var _ring: MeshInstance3D
var _wave_age: float = -1.0
var _wave_radius: float = 40.0
var _wave_origin := Vector3.ZERO
## Contacts of the running pulse: [id, rel, appear_s, prev_pos, cur_pos, alive]
var _contacts: Array[Array] = []
var _age: float = 0.0
var _duration: float = 3.0


func setup(loop: GameLoop, player_id: int, camera: Camera3D) -> void:
	_world = loop.world
	_player_id = player_id
	_camera = camera
	_event_tick = _world.tick
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = CONTACT_SHADER
	quad.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = quad
	_mm.instance_count = CAPACITY
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.extra_cull_margin = 16384.0  # instances follow creatures anywhere within the radius
	add_child(_mmi)
	_wave_mat = ShaderMaterial.new()
	_wave_mat.shader = WAVE_SHADER
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	_wave = MeshInstance3D.new()
	_wave.mesh = sphere
	_wave.material_override = _wave_mat
	_wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wave.visible = false
	add_child(_wave)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.97
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 4
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = _wave_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)
	loop.ticked.connect(_on_ticked)


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		if ev.type == SimEvent.Type.SONAR_PULSE and ev.entity_id == _player_id:
			_start(ev)
	_event_tick = _world.tick
	for c: Array in _contacts:
		var e: SimEntity = _world.get_entity(int(c[0]))
		c[3] = c[4]
		if e != null and e.alive:
			c[4] = e.position
		else:
			c[5] = false


func _start(ev: SimEvent) -> void:
	var p: SimEntity = _world.get_entity(_player_id)
	if p == null:
		return
	_wave_radius = float(ev.data.get("radius", ev.value))
	_duration = float(ev.data.get("duration", _duration))
	_wave_origin = p.position
	_wave_age = 0.0
	_age = 0.0
	_contacts.clear()
	for c_v: Variant in ev.data.get("contacts", []):
		var c: Dictionary = c_v
		var e: SimEntity = _world.get_entity(int(c.get("id", -1)))
		if e == null or _contacts.size() >= CAPACITY:
			continue
		var appear: float = WAVE_S * clampf(e.position.distance_to(_wave_origin) / maxf(_wave_radius, 0.01), 0.0, 1.0)
		_contacts.append([e.id, str(c.get("rel", "similar")), appear, e.position, e.position, true])


func _process(delta: float) -> void:
	if _world == null:
		return
	if _wave_age >= 0.0:
		_wave_age += delta
		var f: float = clampf(_wave_age / WAVE_S, 0.0, 1.0)
		var r: float = maxf(_wave_radius * (1.0 - pow(1.0 - f, 2.0)), 0.05)
		_wave.visible = true
		_ring.visible = true
		_wave.global_position = _wave_origin
		_ring.global_position = _wave_origin
		_wave.scale = Vector3.ONE * r
		_ring.scale = Vector3.ONE * r
		_wave_mat.set_shader_parameter(&"fade", (1.0 - f) * 0.9)
		if f >= 1.0:
			_wave_age = -1.0
			_wave.visible = false
			_ring.visible = false
	if _contacts.is_empty():
		return
	_age += delta
	var a: float = _world.interpolation_alpha()
	var cam_pos: Vector3 = _camera.global_position if _camera != null else _wave_origin
	var n: int = 0
	for c: Array in _contacts:
		var e: SimEntity = _world.get_entity(int(c[0]))
		var t: float = _age - float(c[2])
		if not bool(c[5]) or t < 0.0 or _age > _duration:
			continue
		var fade: float = clampf(t / FADE_IN_S, 0.0, 1.0) * clampf((_duration - _age) / FADE_OUT_S, 0.0, 1.0)
		var pos: Vector3 = (c[3] as Vector3).lerp(c[4] as Vector3, a)
		var len: float = e.length_m if e != null else 1.0
		var d: float = maxf(len * RING_PER_LENGTH, pos.distance_to(cam_pos) * RING_MIN_SCREEN_FRAC)
		_mm.set_instance_transform(n, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * d), pos))
		var rel: String = c[1]
		_mm.set_instance_color(n, Color(REL_COLORS.get(rel, REL_COLORS["similar"]), fade))
		_mm.set_instance_custom_data(n, Color(REL_SHAPES.get(rel, 1.0), 0.0, 0.0, 0.0))
		n += 1
	_mm.visible_instance_count = n
	if _age > _duration:
		_contacts.clear()
		_mm.visible_instance_count = 0
