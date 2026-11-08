extends TestCase
## T1.4 control modes, input layer and settings persistence: the PlayerInput command stream (classic = byte-identical to the
## pre-change stream, SET_CONTROL_MODE only on a change and never for classic at run start, smoothed differs from classic only
## in the MOVE direction and follows the pure step, frame-rate independence through the node), and GameSettings (default classic,
## round trip, missing / unknown / wrong-typed value = classic, scratch path only).
##
## The PlayerInput node is driven by hand (its own processing off): one _physics_process(dt) call = one physics frame, the queued
## commands are drained per frame. In a headless run the mouse is never CAPTURED; MOVE does not depend on it.
##
## The mode reaches the node through GameSettings.apply_input(input) (the way Main applies a run's settings); the GameSettings
## property is found by name (CM.settings_prop()). Assumption: the node submits SET_CONTROL_MODE from _physics_process or
## immediately in the setter, before the next sim tick either way.

const CM := preload("res://tests/control_modes_support.gd")
const G := preload("res://tests/god_support.gd")

const DT: float = 1.0 / 60.0


func after_each() -> void:
	CM.remove_scratch()
	for a: StringName in [&"bite", &"boost", &"swim_thrust", &"swim_brake", &"bite_dash", &"sonar"]:
		if InputMap.has_action(a):
			Input.action_release(a)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _need() -> bool:
	if CM.settings_prop() == "":
		fail("GameSettings has no control-mode property (looked for a variable containing 'control_mode' or 'mode')")
		return false
	return true


## Aim that holds yaw 0 for 4 frames, then jumps to `yaw` and holds.
func _jump(yaw: float) -> Callable:
	return func(i: int) -> Vector2:
		return Vector2.ZERO if i < 4 else Vector2(yaw, 0.0)


func _angle(a: Vector3, b: Vector3) -> float:
	return CM.deg_between(a, b)


# ======================================================================= classic: nothing changes

func test_classic_stream_is_byte_identical_to_the_pre_change_stream() -> void:
	var st: Dictionary = await CM.run_stream("classic")
	assert_eq(CM.stream_digest(st["frames"]), CM.BASELINE_STREAM_DIGEST, "240 frames of MOVE / BOOST / BRAKE: same commands, same order, same numbers as before T1.4")
	assert_eq(CM.count_sets(st["frames"]), 0, "no SET_CONTROL_MODE in the default stream")
	assert_eq((st["dirs"] as Array).size(), 240, "one MOVE per physics frame")
	var exact: bool = true
	for i in (st["dirs"] as Array).size():
		exact = exact and (st["dirs"] as Array[Vector3])[i] == (st["aims"] as Array[Vector3])[i]
	assert_true(exact, "classic MOVE direction is the raw aim, bit for bit")


func test_default_settings_emit_nothing_at_run_start() -> void:
	if not _need():
		return
	CM.remove_scratch()  # no file: pure defaults
	var st: Dictionary = await CM.run_stream("@settings", 60)
	assert_eq(CM.count_sets(st["frames"]), 0, "a run started with default settings sends no SET_CONTROL_MODE")
	assert_eq((st["dirs"] as Array).size(), 60, "and 60 MOVEs")
	var exact: bool = true
	for i in (st["dirs"] as Array).size():
		exact = exact and (st["dirs"] as Array[Vector3])[i] == (st["aims"] as Array[Vector3])[i]
	assert_true(exact, "raw aim")


func test_a_settings_file_that_says_classic_emits_nothing_either() -> void:
	if not _need():
		return
	var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
	CM.set_settings_mode(gs, "classic")
	gs.save_file()
	var st: Dictionary = await CM.run_stream("@settings", 30)
	assert_eq(CM.count_sets(st["frames"]), 0, "classic saved in the file: no command at run start")


# ======================================================================= the command at run start / on change

func test_assisted_at_run_start_emits_exactly_one_command() -> void:
	if not _need():
		return
	var st: Dictionary = await CM.run_stream("assisted", 60)
	assert_true(bool(st["applied"]), "the mode could be applied to the node")
	assert_eq(CM.count_sets(st["frames"]), 1, "exactly one SET_CONTROL_MODE over 60 frames")
	var first_set: int = -1
	for i in (st["frames"] as Array).size():
		for c: SimCommand in (st["frames"][i] as Array):
			if CM.is_set(c) and first_set < 0:
				first_set = i
				assert_true(CM.is_set_of(c, "assisted"), "it names assisted")
				assert_eq(c.entity_id, int(st["pid"]), "for the player entity")
	assert_true(first_set >= 0 and first_set <= 1, "and it is sent at once (frame %d)" % first_set)
	assert_eq((st["dirs"] as Array).size(), 60, "MOVE still goes out every frame")


func test_the_settings_file_mode_is_applied_at_run_start() -> void:
	if not _need():
		return
	var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
	assert_true(CM.set_settings_mode(gs, "assisted"), "setup: settings mode set")
	gs.save_file()
	var st: Dictionary = await CM.run_stream("@settings", 30)
	assert_eq(CM.count_sets(st["frames"]), 1, "assisted persisted in the file: one SET at run start")
	var found: bool = false
	for c: SimCommand in CM.flat(st["frames"]):
		found = found or CM.is_set_of(c, "assisted")
	assert_true(found, "and it names assisted")


func test_assisted_sends_the_raw_aim_unless_its_data_asks_for_smoothing() -> void:
	if not _need():
		return
	if CM.mode_f("assisted", CM.KEY_TAU) > 0.0:
		return  # the preset smooths too: covered by the smoothed tests
	var ck: String = CM.cap_key()
	if ck != "" and CM.mode_f("assisted", ck) > 0.0:
		return
	var st: Dictionary = await CM.run_stream("assisted", 120)
	var exact: bool = true
	for i in (st["dirs"] as Array).size():
		exact = exact and (st["dirs"] as Array[Vector3])[i] == (st["aims"] as Array[Vector3])[i]
	assert_true(exact, "assisted (tau 0, no cap in the data): MOVE direction is the raw aim")


func test_a_change_emits_once_and_the_same_mode_again_emits_nothing() -> void:
	if not _need():
		return
	var st: Dictionary = await CM.run_stream("smoothed", 120, DT, Callable(), {"frame": 60, "mode": "smoothed"})
	assert_eq(CM.count_sets(st["frames"]), 1, "smoothed at the start, smoothed again at frame 60: one command")
	var st2: Dictionary = await CM.run_stream("classic", 120, DT, Callable(), {"frame": 60, "mode": "smoothed"})
	assert_eq(CM.count_sets(st2["frames"]), 1, "classic at the start (no command), smoothed at frame 60: one command")
	var sets: Array[SimCommand] = []
	for c: SimCommand in CM.flat(st2["frames"]):
		if CM.is_set(c):
			sets.append(c)
	if sets.size() == 1:
		assert_true(CM.is_set_of(sets[0], "smoothed"), "naming smoothed")
	# the SET shows up at or right after the switching frame, never earlier
	for i in 60:
		for c: SimCommand in (st2["frames"][i] as Array):
			assert_false(CM.is_set(c), "no SET before the switch (frame %d)" % i)


func test_switching_back_to_classic_is_announced_and_the_aim_is_raw_again() -> void:
	if not _need():
		return
	var st: Dictionary = await CM.run_stream("smoothed", 240, DT, Callable(), {"frame": 120, "mode": "classic"})
	assert_eq(CM.count_sets(st["frames"]), 2, "smoothed at the start + classic on change: two commands")
	var last: SimCommand = null
	for c: SimCommand in CM.flat(st["frames"]):
		if CM.is_set(c):
			last = c
	assert_true(CM.is_set_of(last, "classic"), "the last one names classic (an explicit switch back is sent, only the run-start classic is silent)")
	var dirs: Array[Vector3] = st["dirs"]
	var aims: Array[Vector3] = st["aims"]
	var smoothed_before: bool = false
	for i in range(0, 120):
		smoothed_before = smoothed_before or dirs[i] != aims[i]
	assert_true(smoothed_before, "before the switch the smoothed direction lags the raw aim")
	var raw_after: bool = true
	for i in range(121, 240):
		raw_after = raw_after and dirs[i] == aims[i]
	assert_true(raw_after, "from the frame after the switch on, MOVE is the raw aim again (bit-exact)")


# ======================================================================= smoothed: the stream

func test_smoothed_differs_from_classic_only_in_the_move_direction() -> void:
	if not _need():
		return
	var c: Dictionary = await CM.run_stream("classic")
	var s: Dictionary = await CM.run_stream("smoothed")
	assert_true(bool(s["applied"]), "the mode could be applied")
	assert_eq(CM.count_sets(s["frames"]), 1, "one SET_CONTROL_MODE")
	var sc: Array = CM.without_sets(s["frames"])
	var cc: Array = c["frames"]
	assert_eq(sc.size(), cc.size(), "same number of frames")
	var diff_moves: int = 0
	for i in mini(sc.size(), cc.size()):
		var a: Array = sc[i]
		var b: Array = cc[i]
		assert_eq(a.size(), b.size(), "frame %d: same number of commands" % i)
		if a.size() != b.size():
			continue
		for k in a.size():
			var x: SimCommand = a[k]
			var y: SimCommand = b[k]
			assert_eq(int(x.type), int(y.type), "frame %d cmd %d: type" % [i, k])
			assert_eq(x.entity_id, y.entity_id, "frame %d cmd %d: entity" % [i, k])
			assert_eq(x.tick, y.tick, "frame %d cmd %d: tick" % [i, k])
			assert_eq(x.thrust, y.thrust, "frame %d cmd %d: thrust" % [i, k])
			assert_eq(x.active, y.active, "frame %d cmd %d: active" % [i, k])
			assert_eq(x.target_id, y.target_id, "frame %d cmd %d: target" % [i, k])
			assert_eq(str(x.ability_id), str(y.ability_id), "frame %d cmd %d: ability" % [i, k])
			if int(x.type) == int(SimCommand.Type.MOVE):
				if x.dir != y.dir:
					diff_moves += 1
				assert_true(absf(x.dir.length() - 1.0) < 1e-4, "frame %d: smoothed direction is a unit vector" % i)
			else:
				assert_eq(x.dir, y.dir, "frame %d cmd %d: non-MOVE direction" % [i, k])
	assert_true(diff_moves >= 20, "the aim sweep makes the smoothed MOVE direction differ from the raw one on many frames (%d)" % diff_moves)


func test_smoothed_directions_follow_the_pure_step() -> void:
	if not _need():
		return
	if not CM.has_smoothing():
		fail("no pure smoothing step found")
		return
	var tau: float = CM.mode_f("smoothed", CM.KEY_TAU)
	var ck: String = CM.cap_key()
	var cap: float = CM.mode_f("smoothed", ck) if ck != "" else 0.0
	var s: Dictionary = await CM.run_stream("smoothed", 240, DT)
	var dirs: Array[Vector3] = s["dirs"]
	var aims: Array[Vector3] = s["aims"]
	var cur: Vector3 = aims[0]
	var worst: float = 0.0
	for i in dirs.size():
		var r: Variant = CM.smooth_step(cur, aims[i], DT, tau, cap)
		if not (r is Vector3):
			fail("the pure step returned no Vector3")
			return
		cur = r
		worst = maxf(worst, _angle(dirs[i], cur))
	assert_true(worst < 0.05, "every MOVE direction equals the pure step applied frame by frame with the data's tau %s / cap %s (worst %.4f deg)" % [tau, cap, worst])


func test_smoothed_directions_converge_without_overshoot() -> void:
	if not _need():
		return
	var s: Dictionary = await CM.run_stream("smoothed", 4 + 180, DT, _jump(1.2))
	var dirs: Array[Vector3] = s["dirs"]
	var aims: Array[Vector3] = s["aims"]
	var target: Vector3 = aims[aims.size() - 1]
	assert_true(_angle(dirs[4], target) > 3.0, "right after the jump the sent direction has NOT jumped (still %.1f deg away)" % _angle(dirs[4], target))
	var prev: float = _angle(dirs[4], target)
	var ok: bool = true
	for i in range(5, dirs.size()):
		var e: float = _angle(dirs[i], target)
		ok = ok and e <= prev + 0.01
		prev = e
	assert_true(ok, "the error to the held aim never grows (no overshoot)")
	assert_true(prev < 1.0, "and after 3 s it has converged (%.3f deg left)" % prev)


func test_smoothed_is_frame_rate_independent_through_the_node() -> void:
	if not _need():
		return
	var ends: Array[Vector3] = []
	for hz: int in [30, 60, 144]:
		var s: Dictionary = await CM.run_stream("smoothed", 4 + hz / 4, 1.0 / float(hz), _jump(1.2))  # 0.25 s after the jump
		ends.append((s["dirs"] as Array[Vector3])[-1])
	assert_true(_angle(ends[0], ends[2]) < 1.5, "30 Hz vs 144 Hz, 0.25 s after a jump: %.2f deg apart" % _angle(ends[0], ends[2]))
	assert_true(_angle(ends[1], ends[2]) < 1.5, "60 Hz vs 144 Hz, 0.25 s after a jump: %.2f deg apart" % _angle(ends[1], ends[2]))


# ======================================================================= settings persistence

func test_the_default_mode_is_classic_without_a_file() -> void:
	if not _need():
		return
	CM.remove_scratch()
	var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
	assert_eq(CM.settings_mode(gs), "classic", "a new GameSettings is classic")
	gs.load_file()
	assert_eq(CM.settings_mode(gs), "classic", "and so is one loaded from a missing file")


func test_every_mode_round_trips_through_the_file() -> void:
	if not _need():
		return
	for id: String in CM.IDS:
		var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
		gs.sensitivity = 0.004
		assert_true(CM.set_settings_mode(gs, id), "set %s" % id)
		assert_eq(gs.save_file(), OK, "saved")
		var back := GameSettings.new(CM.SCRATCH_SETTINGS)
		back.load_file()
		assert_eq(CM.settings_mode(back), id, "%s survives save + load" % id)
		assert_almost_eq(back.sensitivity, 0.004, 1e-9, "other keys are kept next to it")


func test_missing_unknown_and_wrong_typed_values_read_as_classic() -> void:
	if not _need():
		return
	var key: Array = CM.cfg_key()
	assert_eq(key.size(), 2, "setup: the config key of the mode was found by diffing a classic and an assisted save")
	if key.size() != 2:
		return
	var bad_values: Array = ["bogus", "", 99, -1, 3.5, true, [1, 2], {"a": 1}]
	for bad: Variant in bad_values:
		var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
		CM.set_settings_mode(gs, "assisted")
		gs.save_file()
		var cfg := ConfigFile.new()
		cfg.load(CM.SCRATCH_SETTINGS)
		cfg.set_value(str(key[0]), str(key[1]), bad)
		cfg.save(CM.SCRATCH_SETTINGS)
		var back := GameSettings.new(CM.SCRATCH_SETTINGS)
		back.load_file()
		assert_eq(CM.settings_mode(back), "classic", "[%s] %s = %s reads as classic" % [key[0], key[1], var_to_str(bad)])
	var gs2 := GameSettings.new(CM.SCRATCH_SETTINGS)
	CM.set_settings_mode(gs2, "assisted")
	gs2.save_file()
	var cfg2 := ConfigFile.new()
	cfg2.load(CM.SCRATCH_SETTINGS)
	cfg2.erase_section_key(str(key[0]), str(key[1]))
	cfg2.save(CM.SCRATCH_SETTINGS)
	var back2 := GameSettings.new(CM.SCRATCH_SETTINGS)
	back2.load_file()
	assert_eq(CM.settings_mode(back2), "classic", "the key removed from the file reads as classic")


func test_a_corrupt_settings_file_reads_as_classic() -> void:
	if not _need():
		return
	var f: FileAccess = FileAccess.open(CM.SCRATCH_SETTINGS, FileAccess.WRITE)
	f.store_string("[input\nthis is = not a config {{{")
	f.close()
	var back := GameSettings.new(CM.SCRATCH_SETTINGS)
	back.load_file()
	assert_eq(CM.settings_mode(back), "classic", "garbage file: classic, no crash")


func test_the_other_settings_keep_working_next_to_the_mode_key() -> void:
	if not _need():
		return
	# PlayerInput keeps reading [input] sensitivity / invert_y from user://settings.cfg on its own; the new key must not
	# change what a settings file without it means
	var gs := GameSettings.new(CM.SCRATCH_SETTINGS)
	gs.sensitivity = 0.003
	gs.invert_y = true
	gs.save_file()
	var back := GameSettings.new(CM.SCRATCH_SETTINGS)
	back.load_file()
	assert_eq(CM.settings_mode(back), "classic", "a file written before T1.4 (no mode key) is classic")
	assert_almost_eq(back.sensitivity, 0.003, 1e-9, "sensitivity kept")
	assert_true(back.invert_y, "invert_y kept")
