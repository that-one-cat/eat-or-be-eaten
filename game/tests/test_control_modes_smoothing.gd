extends TestCase
## T1.4 smoothed mode, the PURE smoothing step (no window, no node): tau 0 = passthrough, convergence, about 1/e of the offset
## left after one time constant, no overshoot, frame-rate independence (several dt), unit-length output for every input, the
## optional turn-speed cap (deg/s). The step is found by CM.smoothing() (a static function with two Vector3 arguments and
## dt / tau / [cap] floats); if the implementation shaped it differently adapt the NAME TABLE in control_modes_support.gd only.
##
## Assumptions (list in the test plan): the step takes (current, target, dt, tau[, cap_deg_s]) and returns the new unit direction;
## tau <= 0 returns the target; dt <= 0 returns the current direction unchanged; a cap of 0 means none; the cap is NOT combined
## with tau = 0 in any assertion (passthrough vs cap is the implementer's call).

const CM := preload("res://tests/control_modes_support.gd")

const EPS_DEG: float = 0.05


func _need() -> bool:
	if not CM.has_smoothing():
		fail("no pure smoothing step found (static function with 2 Vector3 + dt / tau floats in a script named *smooth* or on PlayerInput)")
		return false
	var r: Variant = CM.smooth_step(Vector3.FORWARD, Vector3.RIGHT, 1.0 / 60.0, 0.1)
	if not (r is Vector3):
		fail("the smoothing step did not return a Vector3 (got %s)" % type_string(typeof(r)))
		return false
	return true


func _step(cur: Vector3, tar: Vector3, dt: float, tau: float, cap: float = 0.0) -> Vector3:
	return CM.smooth_step(cur, tar, dt, tau, cap) as Vector3


func _err(d: Vector3, tar: Vector3) -> float:
	return CM.deg_between(d, tar)


func test_a_pure_step_exists() -> void:
	assert_true(_need(), "pure smoothing step discoverable")


func test_tau_zero_is_passthrough_for_any_dt() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(80.0, 20.0)
	for dt: float in [1.0 / 240.0, 1.0 / 60.0, 1.0 / 30.0, 0.25, 3.0]:
		var r: Vector3 = _step(cur, tar, dt, 0.0)
		assert_true(r.distance_to(tar) < 1e-5, "tau 0, dt %s: output is the target (off by %s deg)" % [dt, _err(r, tar)])


func test_every_output_is_a_unit_vector() -> void:
	if not _need():
		return
	var dirs: Array[Vector3] = [CM.dir_yaw_pitch(0.0), CM.dir_yaw_pitch(90.0), CM.dir_yaw_pitch(180.0), CM.dir_yaw_pitch(45.0, 80.0),
		CM.dir_yaw_pitch(-170.0, -80.0), Vector3.UP, Vector3.DOWN]
	for a: Vector3 in dirs:
		for b: Vector3 in dirs:
			for dt: float in [1.0 / 240.0, 1.0 / 60.0, 0.5, 100.0]:
				for tau: float in [0.0, 0.05, 0.1, 2.0]:
					var r: Vector3 = _step(a, b, dt, tau)
					assert_true(r.is_finite() and absf(r.length() - 1.0) < 1e-4, "unit and finite for dt %s tau %s (got %s)" % [dt, tau, r])


func test_exactly_opposite_directions_do_not_collapse() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = -cur
	var r: Vector3 = _step(cur, tar, 1.0 / 60.0, 0.1)
	assert_true(r.is_finite() and absf(r.length() - 1.0) < 1e-4, "a 180 degree flip yields a finite unit vector (got %s)" % r)
	var steps: Array[Vector3] = CM.iterate(cur, tar, 1.0 / 60.0, 0.1, 120)
	assert_true(not steps.is_empty() and _err(steps[-1], tar) < 1.0, "and it still gets there within 2 s (error %s deg)" % [_err(steps[-1], tar) if not steps.is_empty() else -1.0])


func test_it_converges_to_a_fixed_target() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(120.0, 30.0)
	var steps: Array[Vector3] = CM.iterate(cur, tar, 1.0 / 60.0, 0.1, 60)
	assert_eq(steps.size(), 60, "60 steps ran")
	if steps.size() == 60:
		assert_true(_err(steps[-1], tar) < 0.1, "after 10 time constants the error is < 0.1 deg (got %s)" % _err(steps[-1], tar))


func test_one_time_constant_leaves_about_a_third_of_the_offset() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(45.0)
	var tau: float = 0.1
	var steps: Array[Vector3] = CM.iterate(cur, tar, 1.0 / 240.0, tau, 24)  # 0.1 s
	assert_eq(steps.size(), 24, "24 steps ran")
	if steps.size() == 24:
		var frac: float = _err(steps[-1], tar) / 45.0
		assert_true(frac > 0.30 and frac < 0.45, "after t = tau about exp(-1) = 0.37 of the offset is left (got %.3f)" % frac)


func test_the_error_never_grows_and_never_flips_past_the_target() -> void:
	if not _need():
		return
	var tar: Vector3 = CM.dir_yaw_pitch(100.0, -20.0)
	for dt: float in [1.0 / 240.0, 1.0 / 60.0, 1.0 / 30.0, 0.1, 0.5, 2.0, 50.0]:
		for tau: float in [0.03, 0.1, 0.5]:
			var c: Vector3 = CM.dir_yaw_pitch(-30.0, 10.0)
			var prev: float = _err(c, tar)
			for i in 40:
				c = _step(c, tar, dt, tau)
				var e: float = _err(c, tar)
				assert_true(e <= prev + 1e-3, "dt %s tau %s step %d: error %s did not grow from %s" % [dt, tau, i, e, prev])
				prev = e
			# no side-swap: the smoothed direction stays on the arc between the start and the target
			assert_true(prev <= _err(CM.dir_yaw_pitch(-30.0, 10.0), tar) + 1e-3, "dt %s tau %s: ends no further than it started" % [dt, tau])


func test_frame_rate_independence_for_a_step_input() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(45.0)
	var tau: float = 0.1
	var ref: Vector3 = CM.iterate(cur, tar, 1.0 / 240.0, tau, 120)[-1]  # 0.5 s at 240 Hz
	for hz: int in [30, 60, 144]:
		var n: int = roundi(0.5 * float(hz))
		var r: Vector3 = CM.iterate(cur, tar, 1.0 / float(hz), tau, n)[-1]
		assert_true(CM.deg_between(r, ref) < 1.0, "%d Hz vs 240 Hz after 0.5 s: %s deg apart (< 1)" % [hz, CM.deg_between(r, ref)])
	var one: Vector3 = _step(cur, tar, 0.5, tau)
	assert_true(CM.deg_between(one, ref) < 1.0, "one 0.5 s step equals 120 small ones within 1 deg (got %s)" % CM.deg_between(one, ref))


func test_frame_rate_independence_for_a_moving_target() -> void:
	if not _need():
		return
	var tau: float = 0.1
	var ends: Array[Vector3] = []
	for hz: int in [30, 60, 144, 240]:
		var c: Vector3 = CM.dir_yaw_pitch(0.0)
		var n: int = 2 * hz
		var t: float = 0.0
		for i in n:
			t += 1.0 / float(hz)
			var tar: Vector3 = CM.dir_yaw_pitch(60.0 * t)  # target sweeps 60 deg/s
			c = _step(c, tar, 1.0 / float(hz), tau)
		ends.append(c)
	for i in range(1, ends.size()):
		assert_true(CM.deg_between(ends[i], ends[0]) < 3.0, "sweeping target: rate #%d ends %s deg from the 30 Hz run (< 3)" % [i, CM.deg_between(ends[i], ends[0])])


func test_huge_dt_is_the_passthrough_limit() -> void:
	if not _need():
		return
	var tar: Vector3 = CM.dir_yaw_pitch(70.0, 10.0)
	var r: Vector3 = _step(CM.dir_yaw_pitch(0.0), tar, 1000.0, 0.1)
	assert_true(CM.deg_between(r, tar) < 0.01, "dt >> tau reaches the target (off by %s deg)" % CM.deg_between(r, tar))


func test_zero_dt_keeps_the_current_direction() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(10.0, 5.0)
	var r: Vector3 = _step(cur, CM.dir_yaw_pitch(90.0), 0.0, 0.1)
	assert_true(CM.deg_between(r, cur) < 0.01, "dt 0 changes nothing (moved %s deg)" % CM.deg_between(r, cur))


func test_hostile_numbers_never_produce_nan_or_a_move_away() -> void:
	if not _need():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(90.0)
	var start: float = _err(cur, tar)
	for pair: Array in [[-0.5, 0.1], [1.0 / 60.0, -0.1], [1.0 / 60.0, 1e-12], [1e-12, 0.1], [1e9, 1e9], [1.0 / 60.0, 1e9]]:
		var r: Vector3 = _step(cur, tar, float(pair[0]), float(pair[1]))
		assert_true(r.is_finite() and absf(r.length() - 1.0) < 1e-4, "dt %s tau %s: finite unit vector (got %s)" % [pair[0], pair[1], r])
		if r.is_finite() and r.length() > 0.5 and float(pair[0]) > 0.0 and float(pair[1]) > 0.0:
			assert_true(_err(r, tar) <= start + 0.01, "dt %s tau %s: does not turn away from the target" % [pair[0], pair[1]])


# ======================================================================= turn-speed cap

func _need_cap() -> bool:
	if not _need():
		return false
	if not CM.smoothing_has_cap():
		fail("the pure step has no turn-cap argument (a float named cap / max / limit / rate / turn, or a record Dictionary)")
		return false
	return true


func test_the_cap_limits_every_step() -> void:
	if not _need_cap():
		return
	var tar: Vector3 = CM.dir_yaw_pitch(150.0)
	for hz: int in [30, 60, 240]:
		var c: Vector3 = CM.dir_yaw_pitch(0.0)
		var limit: float = 90.0 / float(hz)
		for i in hz:  # 1 s
			var n: Vector3 = _step(c, tar, 1.0 / float(hz), 0.01, 90.0)
			assert_true(CM.deg_between(c, n) <= limit + 0.01, "%d Hz step %d turned %s deg (cap %s deg per step)" % [hz, i, CM.deg_between(c, n), limit])
			c = n


func test_the_cap_is_frame_rate_independent_and_stops_at_the_target() -> void:
	if not _need_cap():
		return
	var tar: Vector3 = CM.dir_yaw_pitch(150.0)
	for hz: int in [30, 60, 240]:
		var c: Vector3 = CM.dir_yaw_pitch(0.0)
		for i in roundi(0.5 * float(hz)):
			c = _step(c, tar, 1.0 / float(hz), 0.01, 90.0)
		var moved: float = CM.deg_between(c, CM.dir_yaw_pitch(0.0))
		assert_true(absf(moved - 45.0) < 1.5, "%d Hz: 0.5 s at 90 deg/s moved %s deg (about 45)" % [hz, moved])
	var near: Vector3 = CM.dir_yaw_pitch(10.0)
	var c2: Vector3 = CM.dir_yaw_pitch(0.0)
	for i in 120:
		c2 = _step(c2, near, 1.0 / 60.0, 0.01, 90.0)
	assert_true(CM.deg_between(c2, near) < 0.1, "a small offset is reached and held, no overshoot (error %s deg)" % CM.deg_between(c2, near))


func test_cap_zero_means_no_cap() -> void:
	if not _need_cap():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(90.0)
	var free_step: Vector3 = _step(cur, tar, 1.0 / 60.0, 0.1, 0.0)
	var capped: Vector3 = _step(cur, tar, 1.0 / 60.0, 0.1, 10.0)
	assert_true(CM.deg_between(cur, free_step) > CM.deg_between(cur, capped) + 1.0, "cap 0 turns more than a 10 deg/s cap (%s vs %s deg)" % [CM.deg_between(cur, free_step), CM.deg_between(cur, capped)])
	var moved: float = CM.deg_between(cur, free_step)
	assert_true(moved > 8.0 and moved < 16.0, "cap 0 is the plain exponential step: about 10 (nlerp) .. 14 (slerp) deg of 90 for dt/tau = 1/6 (got %s)" % moved)


func test_a_cap_above_the_natural_speed_changes_nothing() -> void:
	if not _need_cap():
		return
	var cur: Vector3 = CM.dir_yaw_pitch(0.0)
	var tar: Vector3 = CM.dir_yaw_pitch(20.0)
	var free_step: Vector3 = _step(cur, tar, 1.0 / 60.0, 0.5, 0.0)
	var capped: Vector3 = _step(cur, tar, 1.0 / 60.0, 0.5, 10000.0)
	assert_true(CM.deg_between(free_step, capped) < 0.01, "a huge cap does not bind (differs by %s deg)" % CM.deg_between(free_step, capped))


func test_cap_and_tau_together_still_converge() -> void:
	if not _need_cap():
		return
	var tar: Vector3 = CM.dir_yaw_pitch(120.0)
	var steps: Array[Vector3] = CM.iterate(CM.dir_yaw_pitch(0.0), tar, 1.0 / 60.0, 0.1, 360, 180.0)  # 6 s
	assert_eq(steps.size(), 360, "360 steps ran")
	if steps.size() == 360:
		assert_true(_err(steps[-1], tar) < 0.1, "capped and smoothed still lands on the target (error %s deg)" % _err(steps[-1], tar))
