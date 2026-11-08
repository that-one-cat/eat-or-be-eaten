class_name TargetHealthBars
extends Node3D
## Target health bars (Director request, 2026-11-04 playtest): the player's first bite on an NPC puts a slim world-space
## bar above it showing its HP fraction; it follows the target and fades out HOLD_S after the player's last hit, or
## goes at once when the target dies / is eaten / leaves the interactive tier / is out of range. Which targets have a
## bar is TargetBarTracker (node-free, tests: test_target_health_bars.gd); this node draws them. Reads sim events and
## entity state only, never writes the sim. The boss is excluded (HUD boss bar).
##
## Look: a pooled MeshInstance3D per bar (TargetBarTracker.CAP of them, created at setup, hidden when unused) sharing
## one unit QuadMesh and one ShaderMaterial (fx_target_bar.gdshader: billboard, `frac` / `fade` instance uniforms,
## HUD palette colours). No viewport, no text. Size scales with the target's visual length, clamped to a fraction of
## the camera distance so it reads the same at every size band. Positions follow the sim state between ticks like the
## views (current position minus the remaining part of the tick's velocity step).
## Food sites (food task): the player's bite on a hard site that leaves it alive gets a bar too (static site centre,
## size from the site radius, frac = site HP / max HP; TargetBarTracker site keys).

const SHADER: Shader = preload("res://shaders/fx_target_bar.gdshader")
const THEME: Theme = preload("res://ui/theme/main_theme.tres")
## Bar width = visual length x WIDTH_PER_LENGTH, clamped to [WIDTH_MIN_FRAC, WIDTH_MAX_FRAC] x the camera distance.
const WIDTH_PER_LENGTH: float = 0.8
const WIDTH_MIN_FRAC: float = 0.07
const WIDTH_MAX_FRAC: float = 0.2
## Bar height = width x HEIGHT_PER_WIDTH, at least HEIGHT_MIN_FRAC x the camera distance.
const HEIGHT_PER_WIDTH: float = 0.14
const HEIGHT_MIN_FRAC: float = 0.012
## Bar centre above the body centre: visual length x LIFT_PER_LENGTH + half the bar height + GAP_FRAC x camera distance.
const LIFT_PER_LENGTH: float = 0.4
const GAP_FRAC: float = 0.015
## Range around the player: band camera distance x RANGE_PER_CAMERA_DISTANCE, clamped to [RANGE_MIN_M, RANGE_MAX_M]
## (no camera: RANGE_MAX_M, the FeedbackFx range).
const RANGE_PER_CAMERA_DISTANCE: float = 15.0
const RANGE_MIN_M: float = 8.0
const RANGE_MAX_M: float = FeedbackFx.FX_RANGE_M
## Backing opacity (colour: the HUD palette outline).
const BACKING_ALPHA: float = 0.78

var _world: SimWorld
var _player_id: int = 0
var _camera: CameraRig
var _event_tick: int = 0
var _tracker := TargetBarTracker.new()
var _bars: Array[MeshInstance3D] = []
var _shown: int = 0


## Binds to the loop's world; `camera` (may be null) gives the view distance for the bar size and the range.
func setup(loop: GameLoop, player_id: int, camera: CameraRig) -> void:
	_world = loop.world
	_player_id = player_id
	_camera = camera
	_event_tick = _world.tick
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"backing_color", Color(THEME.get_color(&"outline", &"Palette"), BACKING_ALPHA))
	mat.set_shader_parameter(&"high_color", THEME.get_color(&"health", &"Palette"))
	mat.set_shader_parameter(&"mid_color", THEME.get_color(&"hunger", &"Palette"))
	mat.set_shader_parameter(&"low_color", THEME.get_color(&"boss", &"Palette"))
	for i in TargetBarTracker.CAP:
		var bar := MeshInstance3D.new()
		bar.mesh = quad
		bar.material_override = mat
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bar.extra_cull_margin = 1.0  # the billboard turns the flat quad out of its own AABB
		bar.visible = false
		add_child(bar)
		_bars.append(bar)
	loop.ticked.connect(_on_ticked)


## Entity ids (food sites: TargetBarTracker.site_key) that have a bar now (slot order).
func tracked_ids() -> PackedInt32Array:
	return _tracker.ids


## Pool nodes drawn in the last frame.
func shown_count() -> int:
	return _shown


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		if TargetBarTracker.is_player_hit(ev, _world.get_entity(ev.entity_id), _player_id):
			_tracker.note_hit(ev.entity_id, ev.tick)
		elif TargetBarTracker.is_player_site_hit(ev, _player_id):
			_tracker.note_hit(TargetBarTracker.site_key(int(ev.data.get("site", 0))), ev.tick)
	_event_tick = _world.tick


func _process(_delta: float) -> void:
	if _world == null:
		return
	var a: float = _world.interpolation_alpha()
	var now: float = float(_world.tick) + a
	var p: SimEntity = _world.get_entity(_player_id)
	var centre: Vector3 = p.position if p != null else Vector3.ZERO
	var has_cam: bool = _camera != null and _camera.is_inside_tree()
	var cam_pos: Vector3 = _camera.global_position if has_cam else centre
	var range_m: float = clampf(_camera.band_distance() * RANGE_PER_CAMERA_DISTANCE, RANGE_MIN_M, RANGE_MAX_M) if has_cam else RANGE_MAX_M
	_tracker.prune(_world, centre, range_m, now)
	var n: int = _tracker.ids.size()
	for i in n:
		var length: float
		var pos: Vector3
		var frac: float
		var site: int = TargetBarTracker.key_site(_tracker.ids[i])
		if site >= 0:
			length = _world.food.site_radius(site) * 2.0
			pos = _world.food.site_pos(site)
			var max_hp: float = _world.food.site_max_hp(site)
			frac = clampf(_world.food.site_hp(site) / max_hp, 0.0, 1.0) if max_hp > 0.0 else 0.0
		else:
			var e: SimEntity = _world.get_entity(_tracker.ids[i])
			length = _world.effective_length(e)
			pos = e.position - e.velocity * (SimWorld.TICK_DT * (1.0 - a))
			frac = clampf(e.hp / e.max_hp, 0.0, 1.0) if e.max_hp > 0.0 else 0.0
		var d: float = maxf(pos.distance_to(cam_pos), 0.01)
		var w: float = clampf(length * WIDTH_PER_LENGTH, d * WIDTH_MIN_FRAC, d * WIDTH_MAX_FRAC)
		var h: float = maxf(w * HEIGHT_PER_WIDTH, d * HEIGHT_MIN_FRAC)
		var bar: MeshInstance3D = _bars[i]
		bar.position = pos + Vector3.UP * (length * LIFT_PER_LENGTH + h * 0.5 + d * GAP_FRAC)
		bar.scale = Vector3(w, h, 1.0)
		bar.set_instance_shader_parameter(&"frac", frac)
		bar.set_instance_shader_parameter(&"fade", _tracker.alpha(i, now))
		bar.visible = true
	for i in range(n, _shown):
		_bars[i].visible = false
	_shown = n
