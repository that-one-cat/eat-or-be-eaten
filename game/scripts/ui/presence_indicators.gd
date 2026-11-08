class_name PresenceIndicators
extends Control
## Presence indicators (GAME_DESIGN §5): small neutral markers on the screen edge for creatures >= rules
## presence.min_length_ratio x the player's length within presence.radius_m that are outside the camera view.
## Coverage: a front sector of the player's presence_sector_deg (270 = the rear 90 degree wedge is not shown; Wide
## Vision makes it 360). Markers say only "something is there": every marker looks the same whatever the creature
## (no colour, size or shape by danger or size); only the opacity grows as it comes closer. Reads sim state only.
##
## visible_markers() is the pure part (tests: test_s6_presence.gd); the node calls it every frame for the creatures
## the shared grid returns around the player and draws one chevron per marker on an inset screen-edge rectangle.

## Marker inset from the screen edges, px (canvas units); top / bottom keep clear of the HUD panel rows.
const EDGE_INSET: float = 34.0
const EDGE_INSET_TOP: float = 104.0
const EDGE_INSET_BOTTOM: float = 112.0
## Chevron size, px.
const MARKER_SIZE: float = 20.0
## Opacity at the radius edge and right next to the player.
const ALPHA_FAR: float = 0.45
const ALPHA_NEAR: float = 0.95
## Fade in / out rate per marker, 1/s (real time).
const FADE_RATE: float = 8.0
## "Outside the view" without a camera: outside this cone around the player's forward axis (half angle, degrees;
## about the half FOV of the follow camera).
const NO_CAMERA_VIEW_HALF_DEG: float = 40.0
## Relative slack on the length test, so a creature of exactly the ratio counts (>=).
const LENGTH_EPS: float = 1e-6
const MARKER_COLOR: Color = Color(0.92, 0.97, 1.0)

var _world: SimWorld
var _player_id: int = 0
var _camera: Camera3D
var _min_ratio: float = 0.5
var _radius: float = 30.0
var _base_sector: float = 270.0
var _ids := PackedInt32Array()
var _creatures: Array[SimEntity] = []
## id -> [alpha, screen_dir: Vector2, target_alpha]
var _shown: Dictionary[int, Array] = {}


## Markers for `creatures` around `player`: one Dictionary {id: int, screen_dir: Vector2 (unit, screen space: +x right,
## +y down), angle_deg: float (angle between the player's forward axis -basis.z and the creature), distance_m: float}
## per creature that is
##  - not the player, a living CREATURE (food bits never count);
##  - at least `min_len_ratio` x the player's length (>=);
##  - within `radius_m` of the player;
##  - inside the front sector: angle_deg <= sector_deg / 2 (sector_deg >= 360 = every direction);
##  - outside the camera view: not inside `camera`'s frustum. With `camera` null the view is approximated by a cone
##    of NO_CAMERA_VIEW_HALF_DEG around the player's forward axis, and screen_dir is the creature direction projected
##    on the basis x / y axes.
## Pure: reads its inputs only (the camera transform and projection), writes nothing. The payload never carries size
## or danger: two creatures at the same place give the same marker apart from the id.
static func visible_markers(player: SimEntity, basis: Basis, camera: Camera3D, creatures: Array[SimEntity], sector_deg: float, min_len_ratio: float, radius_m: float) -> Array:
	var out: Array = []
	if player == null:
		return out
	var fwd: Vector3 = -basis.z.normalized()
	var half_cos: float = cos(deg_to_rad(clampf(sector_deg, 0.0, 360.0) * 0.5))
	var all_round: bool = sector_deg >= 360.0
	var view_cos: float = cos(deg_to_rad(NO_CAMERA_VIEW_HALF_DEG))
	var min_len: float = min_len_ratio * player.length_m * (1.0 - LENGTH_EPS)
	var r2: float = radius_m * radius_m
	var cam_basis_inv := Basis.IDENTITY
	var cam_pos := Vector3.ZERO
	var use_cam: bool = camera != null and camera.is_inside_tree()
	if use_cam:
		cam_basis_inv = camera.global_transform.basis.orthonormalized().inverse()
		cam_pos = camera.global_position
	for c: SimEntity in creatures:
		if c == null or c.id == player.id or not c.alive or c.kind != SimEntity.Kind.CREATURE:
			continue
		if c.length_m < min_len:
			continue
		var d: Vector3 = c.position - player.position
		var d2: float = d.length_squared()
		if d2 > r2 or d2 < 1e-8:
			continue
		var dist: float = sqrt(d2)
		var cosang: float = clampf(fwd.dot(d / dist), -1.0, 1.0)
		if not all_round and cosang < half_cos:
			continue
		var dir2 := Vector2.ZERO
		if use_cam:
			if camera.is_position_in_frustum(c.position):
				continue
			var local: Vector3 = cam_basis_inv * (c.position - cam_pos)
			dir2 = Vector2(local.x, -local.y)
		else:
			if cosang >= view_cos:
				continue
			dir2 = Vector2(d.dot(basis.x.normalized()), -d.dot(basis.y.normalized()))
		# straight behind: no lateral component, point down (toward "behind you")
		dir2 = dir2.normalized() if dir2.length_squared() > 1e-10 else Vector2.DOWN
		out.append({"id": c.id, "screen_dir": dir2, "angle_deg": rad_to_deg(acos(cosang)), "distance_m": dist})
	return out


func setup(world: SimWorld, player_id: int, camera: Camera3D) -> void:
	_world = world
	_player_id = player_id
	_camera = camera
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pr: Variant = world.content.rules().get("presence") if world.content != null else null
	if pr is Dictionary:
		_min_ratio = float((pr as Dictionary).get("min_length_ratio", _min_ratio))
		_radius = float((pr as Dictionary).get("radius_m", _radius))
		_base_sector = float((pr as Dictionary).get("sector_deg", _base_sector))


func _process(delta: float) -> void:
	if _world == null:
		return
	var p: SimEntity = _world.get_entity(_player_id)
	for id: int in _shown.keys():
		_shown[id][2] = 0.0
	if p != null and p.alive and visible and _world.grid != null:
		_creatures.clear()
		_world.grid.query_radius_into(p.position, _radius, _ids)
		for id: int in _ids:
			var e: SimEntity = _world.get_entity(id)
			if e != null:
				_creatures.append(e)
		var sector: float = p.presence_sector_deg if p.presence_sector_deg > 0.0 else _base_sector
		var fwd: Vector3 = p.heading if not p.heading.is_zero_approx() else Vector3.FORWARD
		var up: Vector3 = Vector3.UP if absf(fwd.normalized().y) < 0.999 else Vector3.BACK
		var basis := Basis.looking_at(fwd, up)
		for m: Dictionary in visible_markers(p, basis, _camera, _creatures, sector, _min_ratio, _radius):
			var id: int = m["id"]
			var target: float = lerpf(ALPHA_NEAR, ALPHA_FAR, clampf(float(m["distance_m"]) / _radius, 0.0, 1.0))
			if _shown.has(id):
				_shown[id][1] = m["screen_dir"]
				_shown[id][2] = target
			else:
				_shown[id] = [0.0, m["screen_dir"], target]
	var real_dt: float = delta / maxf(Engine.time_scale, 0.001)
	var k: float = 1.0 - exp(-FADE_RATE * real_dt)
	for id: int in _shown.keys():
		var s: Array = _shown[id]
		s[0] = lerpf(float(s[0]), float(s[2]), k)
		if float(s[2]) <= 0.0 and float(s[0]) < 0.02:
			_shown.erase(id)
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2(EDGE_INSET, EDGE_INSET_TOP), size - Vector2(EDGE_INSET * 2.0, EDGE_INSET_TOP + EDGE_INSET_BOTTOM))
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var c: Vector2 = rect.get_center()
	var half: Vector2 = rect.size * 0.5
	for id: int in _shown.keys():
		var s: Array = _shown[id]
		var dir: Vector2 = s[1]
		var a: float = float(s[0])
		# ray from the centre to the inset rectangle
		var tx: float = half.x / absf(dir.x) if absf(dir.x) > 1e-6 else INF
		var ty: float = half.y / absf(dir.y) if absf(dir.y) > 1e-6 else INF
		var at: Vector2 = c + dir * minf(tx, ty)
		var side: Vector2 = Vector2(-dir.y, dir.x)
		var tip: Vector2 = at + dir * MARKER_SIZE * 0.6
		var pts := PackedVector2Array([tip, at - dir * MARKER_SIZE * 0.4 + side * MARKER_SIZE * 0.55, at - dir * MARKER_SIZE * 0.1, at - dir * MARKER_SIZE * 0.4 - side * MARKER_SIZE * 0.55])
		# dark disc behind a white chevron: readable on bright shallows and in the dark abyss alike
		draw_circle(at - dir * MARKER_SIZE * 0.05, MARKER_SIZE * 0.95, Color(0.02, 0.06, 0.11, 0.45 * a))
		draw_colored_polygon(pts, Color(MARKER_COLOR, a))
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(0.02, 0.06, 0.11, 0.8 * a), 2.0, true)
