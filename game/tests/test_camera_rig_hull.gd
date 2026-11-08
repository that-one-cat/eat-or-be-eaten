extends TestCase
## CameraRig hull guard: terrain may pull the boom in, but the camera must never end up inside the fish.
## Pure geometry of _outside_hull() / _push_out_of_hull() (no scene tree, no SimWorld needed).

const HULL: float = 1.0
## Boom length that starts inside the hull for every direction used below.
const MIN_D: float = 0.05


func _rig(pivot: Vector3) -> CameraRig:
	var rig := CameraRig.new()
	rig._pivot = pivot
	rig._hull_radius = HULL
	return rig


func test_camera_point_inside_the_hull_moves_to_the_exit_point() -> void:
	var rig: CameraRig = _rig(Vector3(0.0, 0.3, 0.0))
	# boom straight down through the fish centre: the sphere spans d in (-0.7, 1.3)
	assert_almost_eq(rig._outside_hull(0.05, Vector3.DOWN, Vector3.ZERO), 1.3, 1e-6, "exit below the fish")
	assert_almost_eq(rig._outside_hull(1.0, Vector3.DOWN, Vector3.ZERO), 1.3, 1e-6, "still inside at d = 1")
	rig.free()


func test_camera_point_outside_the_hull_is_unchanged() -> void:
	var rig: CameraRig = _rig(Vector3(0.0, 0.3, 0.0))
	assert_almost_eq(rig._outside_hull(1.5, Vector3.DOWN, Vector3.ZERO), 1.5, 1e-9, "beyond the exit point")
	assert_almost_eq(rig._outside_hull(2.0, Vector3.UP, Vector3.ZERO), 2.0, 1e-9, "boom away from the fish")
	rig.free()


func test_boom_missing_the_hull_is_unchanged() -> void:
	var rig: CameraRig = _rig(Vector3(5.0, 0.0, 0.0))
	for d in [0.0, 0.05, 3.0]:
		assert_almost_eq(rig._outside_hull(d, Vector3.UP, Vector3.ZERO), d, 1e-9, "d = %s" % d)
	rig.free()


func test_exit_point_lies_on_the_hull_surface_for_any_boom_direction() -> void:
	var rig: CameraRig = _rig(Vector3(0.0, 0.12, 0.0))
	for i in 24:
		var yaw: float = TAU * i / 24.0
		for pitch in [-1.2, -0.4, 0.0, 0.4, 1.2]:
			var boom := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
			var d: float = rig._outside_hull(MIN_D, boom, Vector3.ZERO)
			var dist: float = (rig._pivot + boom * d).length()
			assert_true(dist >= HULL - 1e-6, "outside the hull: yaw %.2f pitch %.2f dist %.4f" % [yaw, pitch, dist])
	rig.free()


func test_push_out_keeps_the_height_and_reaches_the_surface() -> void:
	var rig: CameraRig = _rig(Vector3.ZERO)
	var pos := Vector3(0.1, 0.2, 0.0)
	var out: Vector3 = rig._push_out_of_hull(pos, Vector3.ZERO, Vector3.BACK)
	assert_almost_eq(out.y, pos.y, 1e-9, "height kept (seabed and surface clamps stay valid)")
	assert_almost_eq(out.length(), HULL, 1e-6, "on the hull surface")
	rig.free()


func test_push_out_leaves_a_camera_outside_the_hull_alone() -> void:
	var rig: CameraRig = _rig(Vector3.ZERO)
	var pos := Vector3(0.0, 0.4, 1.2)
	assert_eq(rig._push_out_of_hull(pos, Vector3.ZERO, Vector3.BACK), pos)
	rig.free()


func test_push_out_handles_a_camera_exactly_above_the_fish() -> void:
	var rig: CameraRig = _rig(Vector3.ZERO)
	var out: Vector3 = rig._push_out_of_hull(Vector3(0.0, 0.5, 0.0), Vector3.ZERO, Vector3(0.0, 1.0, 0.0))
	assert_true(out.is_finite(), "finite when boom and offset are both vertical")
	assert_true(out.length() >= HULL - 1e-6, "outside the hull")
	rig.free()
