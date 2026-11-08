class_name CameraRig
extends Camera3D
## Third-person follow camera behind and slightly above the fish (GAME_DESIGN §5). Presentation only.
##
## Framing (S7 camera feel): the boom looks down by the band's elevation (ELEVATION_BY_BAND) at a pivot that sits
## LOOK_AHEAD_LENGTHS body lengths ahead of the fish along the view direction, so the head, the jaw and the bite /
## swallow FX in front of the mouth are in the middle of the frame instead of hidden behind the body; the lead and
## the extra elevation fade out in the look-back view.
##
## Orientation comes from the PlayerInput aim (yaw/pitch angles, not accumulated transforms) or, without
## input (autopilot), from the smoothed fish heading. Distance, near and far come from the size band's
## `camera` data. Holding `look_back` swings the camera to the front of the fish looking back.
## Collision without physics: the boom is ray-marched against SeabedField.height_at and the obstacle
## primitives of the same map data the sim uses, then the camera is kept between seabed and surface.

## Downward look angle that puts the camera above the fish, per size band (degrees, index = band - 1; the last
## entry covers higher bands). Small bands look down more: at B1 the fish is short against the boom and a flat view
## hides the mouth behind the body. TODO(data): move to size_bands[].camera.elevation_deg (game/data is owned by
## the balance pass in S7; these consts are the values to move).
const ELEVATION_BY_BAND: PackedFloat32Array = [24.0, 21.0, 18.0, 16.0]
## Elevation used in the look-back view (the camera in front of the fish, looking back at it).
const LOOK_BACK_ELEVATION: float = deg_to_rad(10.0)
## Pivot lead ahead of the fish centre along the view direction, in body lengths (the mouth is at about 0.5).
## TODO(data): size_bands[].camera.look_ahead_lengths.
const LOOK_AHEAD_LENGTHS: float = 0.45
## Camera pitch limit (keeps look_at away from the UP-vector singularity when the fish dives straight down).
const MAX_CAM_PITCH: float = deg_to_rad(75.0)
## Pivot height above the fish as a fraction of the distance (fish sits a bit below the screen centre).
const PIVOT_LIFT: float = 0.12
## Smoothing rates, 1/s (exponential, frame-rate independent).
const FOLLOW_RATE: float = 20.0
const AUTO_AIM_RATE: float = 5.0
const LOOK_BACK_RATE: float = 9.0
const DISTANCE_OUT_RATE: float = 3.0
## Ray-march steps along the boom.
const MARCH_STEPS: int = 16
## Clearance kept from seabed/obstacles: fraction of the distance, at least this many metres.
const CLEARANCE_FRAC: float = 0.12
const MIN_CLEARANCE_M: float = 0.05
## The camera stays this far below the water surface.
const SURFACE_CLEARANCE_M: float = 0.05
## Bounding-sphere radius of the player model per metre of fish length: the farthest vertex of the
## unit-length S1 model from its origin (centre of mass) is 0.69 m (the primitive fallback fish is smaller).
## Node scale = length_m, so the hull reaches HULL_RADIUS_PER_LENGTH * length_m from the fish centre.
const HULL_RADIUS_PER_LENGTH: float = 0.7
## |y| of the unit view direction above which UP is (nearly) parallel to it and look_at needs another up vector.
const UP_PARALLEL_LIMIT: float = 0.999
## Screen shake (trauma model): trauma 0..1 decays at SHAKE_DECAY per real second; shake = trauma^2 drives
## smooth noise on h_offset/v_offset (lens shift, the follow position is untouched) and a small roll.
const SHAKE_DECAY: float = 1.8
## Max lens shift as a fraction of the band camera distance, and max roll.
const SHAKE_MAX_OFFSET_FRAC: float = 0.05
const SHAKE_MAX_ROLL: float = deg_to_rad(4.0)
## Noise samples per real second (shake frequency).
const SHAKE_NOISE_RATE: float = 40.0
## Camera punch: FOV change in degrees at punch 1 (positive = zoom in), decaying at PUNCH_DECAY per real second.
const PUNCH_FOV_DEG: float = 14.0
const PUNCH_DECAY: float = 5.0

## Forces the look-back view (user arg `-- --look-back`, for screenshots).
var force_look_back: bool = false

var _world: SimWorld
var _entity_id: int = 0
var _view: PlayerView
var _input: PlayerInput
var _seabed: SeabedField
var _band: int = -1
var _band_distance: float = 3.0
var _elevation: float = deg_to_rad(ELEVATION_BY_BAND[0])
var _elevation_target: float = deg_to_rad(ELEVATION_BY_BAND[0])
var _lead_m: float = 0.0
var _distance: float = 3.0
## The camera never gets closer to the fish centre than this (hull sphere + the band near plane).
var _hull_radius: float = 0.0
var _pivot: Vector3
var _yaw: float = 0.0
var _pitch: float = 0.0
var _back: float = 0.0
var _trauma: float = 0.0
var _punch: float = 0.0
var _noise_t: float = 0.0
var _noise: FastNoiseLite = null
var _base_fov: float = 70.0


## Adds screen-shake trauma (clamped to 1). Presentation only.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Camera punch: `amount` 1 = full zoom-in kick, negative = a short zoom-out; decays on its own.
func punch(amount: float) -> void:
	_punch = clampf(amount, -1.0, 1.0)


## Camera distance target of the current size band (m).
func band_distance() -> float:
	return _band_distance


## `input` may be null (autopilot): the camera then follows the fish heading.
func setup(world: SimWorld, entity_id: int, view: PlayerView, input: PlayerInput) -> void:
	_world = world
	_entity_id = entity_id
	_view = view
	_input = input
	_seabed = world.seabed
	force_look_back = OS.get_cmdline_user_args().has("--look-back")
	_back = 1.0 if force_look_back else 0.0
	_apply_band(true)
	_yaw = view.yaw
	_pitch = view.pitch
	_elevation = _elevation_target
	_pivot = _pivot_target(0.0)
	_base_fov = fov
	_noise = FastNoiseLite.new()
	_noise.seed = 1103
	_noise.frequency = 0.08
	current = true
	_process(0.0)


func _ready() -> void:
	# after GameLoop (steps the sim) and PlayerView (interpolates the fish)
	process_priority = 10


func _process(delta: float) -> void:
	if _world == null:
		return
	_apply_band(false)
	if _input != null:
		_yaw = _input.aim_yaw
		_pitch = _input.aim_pitch
	else:
		var ka: float = 1.0 - exp(-AUTO_AIM_RATE * delta)
		_yaw = lerp_angle(_yaw, _view.yaw, ka)
		_pitch = lerpf(_pitch, _view.pitch, ka)
	var back_target: float = 1.0 if force_look_back or Input.is_action_pressed(&"look_back") else 0.0
	_back = lerpf(_back, back_target, 1.0 - exp(-LOOK_BACK_RATE * delta))
	# a band change eases the elevation over like the distance does
	_elevation = lerpf(_elevation, _elevation_target, 1.0 - exp(-DISTANCE_OUT_RATE * delta))
	var s: float = smoothstep(0.0, 1.0, _back)
	_pivot = _pivot.lerp(_pivot_target(s), 1.0 - exp(-FOLLOW_RATE * delta))

	# look-back: the view yaw swings by 180 deg and levels out (a mirrored pitch would put the camera
	# under a diving fish, into the seabed)
	var cam_yaw: float = _yaw + PI * s
	var elevation: float = lerpf(_elevation, LOOK_BACK_ELEVATION, s)
	var cam_pitch: float = clampf(lerpf(_pitch, 0.0, s) - elevation, -MAX_CAM_PITCH, MAX_CAM_PITCH)
	var cp: float = cos(cam_pitch)
	var boom := Vector3(sin(cam_yaw) * cp, -sin(cam_pitch), cos(cam_yaw) * cp)  # pivot -> camera

	var clearance: float = maxf(_band_distance * CLEARANCE_FRAC, MIN_CLEARANCE_M)
	if _seabed != null:
		# an ideal camera point under the seabed lifts the boom over it (orbit up) instead of shortening it
		var ideal: Vector3 = _pivot + boom * _band_distance
		var floor_y: float = _seabed.height_at(ideal.x, ideal.z) + clearance
		if ideal.y < floor_y:
			ideal.y = floor_y
			if not ideal.is_equal_approx(_pivot):
				boom = (ideal - _pivot).normalized()
	# terrain may pull the boom in, but never into the fish: the hull sphere is the lower bound
	var fish: Vector3 = _view.global_position
	var allowed: float = _outside_hull(_clear_length(_pivot, boom, _band_distance, clearance), boom, fish)
	if allowed < _distance:
		_distance = allowed  # pull in at once, never show the inside of a rock
	else:
		_distance = lerpf(_distance, allowed, 1.0 - exp(-DISTANCE_OUT_RATE * delta))

	# the boom direction can change between frames (look-back, aim), so the smoothed length is re-checked
	var pos: Vector3 = _pivot + boom * _outside_hull(_distance, boom, fish)
	if _seabed != null:
		pos.y = maxf(pos.y, _seabed.height_at(pos.x, pos.z) + clearance)
	pos.y = minf(pos.y, -SURFACE_CLEARANCE_M)
	pos = _push_out_of_hull(pos, fish, boom)
	if not pos.is_equal_approx(_pivot):
		# looking straight down/up at the pivot would be parallel to UP: use the horizontal view direction
		var to_pivot: Vector3 = (_pivot - pos).normalized()
		var up: Vector3 = Vector3.UP
		if absf(to_pivot.y) > UP_PARALLEL_LIMIT:
			up = Vector3(-sin(cam_yaw), 0.0, -cos(cam_yaw))
		look_at_from_position(pos, _pivot, up)
	_apply_juice(delta)


# Shake and punch on top of the follow transform; they decay in real time (unaffected by slow-mo).
func _apply_juice(delta: float) -> void:
	if _noise == null:
		return
	var real_dt: float = delta / maxf(Engine.time_scale, 0.001)
	_trauma = maxf(_trauma - SHAKE_DECAY * real_dt, 0.0)
	_punch = move_toward(_punch, 0.0, PUNCH_DECAY * real_dt * maxf(absf(_punch), 0.2))
	fov = _base_fov - PUNCH_FOV_DEG * _punch
	var shake: float = _trauma * _trauma
	if shake <= 0.0:
		h_offset = 0.0
		v_offset = 0.0
		return
	_noise_t += SHAKE_NOISE_RATE * real_dt
	var amp: float = SHAKE_MAX_OFFSET_FRAC * _band_distance * shake
	h_offset = amp * _noise.get_noise_2d(1.0, _noise_t)
	v_offset = amp * _noise.get_noise_2d(57.0, _noise_t)
	rotate_object_local(Vector3.FORWARD, SHAKE_MAX_ROLL * shake * _noise.get_noise_2d(113.0, _noise_t))


# The look-at point: above the fish, and `_lead_m` ahead of it along the aim (no lead in the look-back view, s = 1).
func _pivot_target(s: float) -> Vector3:
	var cp: float = cos(_pitch)
	var ahead := Vector3(-sin(_yaw) * cp, sin(_pitch), -cos(_yaw) * cp)  # aim direction, opposite to the boom
	return _view.global_position + Vector3.UP * (_band_distance * PIVOT_LIFT) + ahead * (_lead_m * (1.0 - s))


# Band camera data: distance target, near and far planes. `snap` jumps instead of smoothing.
func _apply_band(snap: bool) -> void:
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	if e.band != _band and _world.content != null:
		_band = e.band
		var cam: Dictionary = _world.content.get_band(_band).get("camera", {})
		_band_distance = float(cam.get("distance", _band_distance))
		near = float(cam.get("near", near))
		far = float(cam.get("far", far))
		_elevation_target = deg_to_rad(ELEVATION_BY_BAND[clampi(_band - 1, 0, ELEVATION_BY_BAND.size() - 1)])
		if snap:
			_distance = _band_distance
			_elevation = _elevation_target
	# the fish grows inside its band, so the hull and the lead follow the current length
	_hull_radius = minf(e.length_m * HULL_RADIUS_PER_LENGTH + near, _band_distance)
	_lead_m = e.length_m * LOOK_AHEAD_LENGTHS


# `d` moved out of the fish hull sphere (centre `fish`, radius _hull_radius) along the boom from the pivot: the
# exit point when the camera point pivot + boom * d lies inside the sphere, `d` unchanged otherwise.
func _outside_hull(d: float, boom: Vector3, fish: Vector3) -> float:
	var rel: Vector3 = _pivot - fish
	var along: float = rel.dot(boom)
	var disc: float = along * along - rel.length_squared() + _hull_radius * _hull_radius
	if disc <= 0.0:
		return d  # the boom line misses the sphere
	var root: float = sqrt(disc)
	if d > -along - root and d < -along + root:
		return -along + root
	return d


# Last safety net after the seabed/surface clamps: a camera still inside the hull sphere is moved sideways
# (height kept, so the clamps hold) to the sphere surface.
func _push_out_of_hull(pos: Vector3, fish: Vector3, boom: Vector3) -> Vector3:
	var off: Vector3 = pos - fish
	if off.length_squared() >= _hull_radius * _hull_radius:
		return pos
	var side := Vector3(off.x, 0.0, off.z)
	if side.length_squared() < 1e-8:
		side = Vector3(boom.x, 0.0, boom.z)
	if side.length_squared() < 1e-8:
		side = Vector3.BACK
	side = side.normalized() * sqrt(maxf(_hull_radius * _hull_radius - off.y * off.y, 0.0))
	return Vector3(fish.x + side.x, pos.y, fish.z + side.z)


# Longest boom length (<= max_len) from `from` along unit `dir` that keeps `clearance` from the seabed
# and the obstacle primitives (fixed-step march).
func _clear_length(from: Vector3, dir: Vector3, max_len: float, clearance: float) -> float:
	if _seabed == null:
		return max_len
	var step: float = max_len / MARCH_STEPS
	for i in range(1, MARCH_STEPS + 1):
		var p: Vector3 = from + dir * (step * i)
		# half clearance for the seabed here: only ridges between fish and camera should block, the end
		# point itself is lifted to the full clearance afterwards
		if p.y < _seabed.height_at(p.x, p.z) + clearance * 0.5 or _inside_obstacle(p, clearance):
			return maxf(step * (i - 1), MIN_CLEARANCE_M)
	return max_len


func _inside_obstacle(p: Vector3, clearance: float) -> bool:
	return not _seabed.obstacle_clear(p, clearance)
