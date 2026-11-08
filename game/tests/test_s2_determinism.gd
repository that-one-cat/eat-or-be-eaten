extends TestCase
## S2 determinism and frame-rate independence (sim side).
## Same seed + same MOVE/BOOST/BRAKE script -> same state_hash(); BRAKE/BOOST/direction changes must change it;
## advance() with 1/30, 1/60, 1/120 and irregular deltas must land on the identical state for the same
## per-tick command script (frame-rate independence comes from the fixed 30 Hz tick).
## Scripts come from a local LCG (not SimRng, not global RNG). No real waits anywhere.

const S2 := preload("res://tests/s2_support.gd")
const TICKS: int = 600
const WORLD_SEED: int = 42


func _world() -> SimWorld:
	return S2.make_world(WORLD_SEED)


## Segmented script run with explicit target ticks (spawn -> N ticks -> hash).
func _run_segments(segs: Array[Dictionary], explicit_ticks: bool = true) -> int:
	var w: SimWorld = _world()
	var id: int = w.spawn_player(0)
	if explicit_ticks:
		S2.submit_segments(w, id, segs, true)
		S2.run(w, TICKS)
	else:
		# Just-in-time: submit each segment's commands right before its tick with tick = -1.
		for t in TICKS:
			for s: Dictionary in segs:
				if int(s["tick"]) == t:
					var one: Array[Dictionary] = [s]
					S2.submit_segments(w, id, one, false)
			w.step()
	return w.state_hash()


# ======================================================== replay

func test_same_seed_same_script_same_hash() -> void:
	var segs: Array[Dictionary] = S2.movement_script(1001, TICKS, true, true)
	var first: int = _run_segments(segs)
	for i in 3:
		assert_eq(_run_segments(segs), first, "replay #%d diverged" % i)


func test_script_actually_moves_the_player_and_uses_all_command_kinds() -> void:
	# Guards against a vacuous determinism test.
	var segs: Array[Dictionary] = S2.movement_script(1001, TICKS, true, true)
	var any_boost: bool = false
	var any_brake: bool = false
	var any_cruise: bool = false
	for s in segs:
		any_boost = any_boost or bool(s["boost"])
		any_brake = any_brake or bool(s["brake"])
		any_cruise = any_cruise or float(s["thrust"]) > 0.0
	assert_true(any_boost and any_brake and any_cruise, "script must contain MOVE, BOOST and BRAKE segments")
	assert_true(segs.size() >= 10, "script spans many segments, got %d" % segs.size())
	var w: SimWorld = _world()
	var id: int = w.spawn_player(0)
	var start: Vector3 = w.get_entity(id).position
	S2.submit_segments(w, id, segs)
	S2.run(w, TICKS)
	assert_true(w.get_entity(id).position.distance_to(start) > 2.0, "the script must really swim somewhere (moved %s m)" % w.get_entity(id).position.distance_to(start))
	var idle: SimWorld = _world()
	idle.spawn_player(0)
	S2.run(idle, TICKS)
	assert_ne(w.state_hash(), idle.state_hash(), "driven world must differ from the idle world")


func test_hash_is_independent_of_submission_time() -> void:
	var segs: Array[Dictionary] = S2.movement_script(2002, TICKS, true, true)
	assert_eq(_run_segments(segs, false), _run_segments(segs, true), "tick=-1 just before the tick must equal an explicit target tick")


func test_replay_with_different_seeds_differs() -> void:
	var segs: Array[Dictionary] = S2.movement_script(1001, TICKS, true, true)
	var w2: SimWorld = S2.make_world(WORLD_SEED + 1)
	var id2: int = w2.spawn_player(0)
	S2.submit_segments(w2, id2, segs)
	S2.run(w2, TICKS)
	assert_ne(w2.state_hash(), _run_segments(segs), "a different world seed changes the hash (rng state is hashed)")


# ======================================================== inputs that must matter

func test_brake_changes_the_hash() -> void:
	var with_brake: int = _run_segments(S2.movement_script(1001, TICKS, true, true))
	var without_brake: int = _run_segments(S2.movement_script(1001, TICKS, false, true))
	assert_ne(with_brake, without_brake, "BRAKE segments (same MOVE/thrust pattern) must alter the outcome")


func test_boost_changes_the_hash() -> void:
	var with_boost: int = _run_segments(S2.movement_script(1001, TICKS, true, true))
	var without_boost: int = _run_segments(S2.movement_script(1001, TICKS, true, false))
	assert_ne(with_boost, without_boost, "BOOST segments must alter the outcome (speed + stamina)")


func test_changed_move_direction_changes_the_hash() -> void:
	var base: int = _run_segments(S2.movement_script(1001, TICKS, true, true))
	var tweaked: Array[Dictionary] = S2.movement_script(1001, TICKS, true, true)
	var d: Vector3 = tweaked[1]["dir"]
	tweaked[1]["dir"] = Vector3(-d.x, d.y, -d.z)
	assert_ne(_run_segments(tweaked), base, "mirroring one MOVE direction must change the hash")


func test_shifted_command_tick_changes_the_hash() -> void:
	var base: int = _run_segments(S2.movement_script(1001, TICKS, true, true))
	var shifted: Array[Dictionary] = S2.movement_script(1001, TICKS, true, true)
	shifted[2]["tick"] = int(shifted[2]["tick"]) + 9
	assert_ne(_run_segments(shifted), base, "executing a segment 9 ticks later must change the hash")


func test_brake_alone_changes_a_cruising_fish() -> void:
	# Minimal pair: identical commands except one BRAKE window.
	var a: SimWorld = _world()
	var b: SimWorld = _world()
	var ia: int = a.spawn_player(0)
	var ib: int = b.spawn_player(0)
	a.submit(SimCommand.move(ia, Vector3.RIGHT, 1.0, 0))
	a.submit(SimCommand.move(ia, Vector3.RIGHT, 0.0, 90))
	b.submit(SimCommand.move(ib, Vector3.RIGHT, 1.0, 0))
	b.submit(SimCommand.move(ib, Vector3.RIGHT, 0.0, 90))
	b.submit(SimCommand.brake(ib, true, 90))
	b.submit(SimCommand.brake(ib, false, 120))
	S2.run(a, 150)
	S2.run(b, 150)
	assert_ne(a.state_hash(), b.state_hash(), "braking from cruise speed must change the state")
	assert_true(b.get_entity(ib).position.distance_to(a.get_entity(ia).position) > 0.01, "and the braked fish ends up elsewhere")


func test_brake_for_unknown_entity_is_ignored() -> void:
	var a: SimWorld = _world()
	var b: SimWorld = _world()
	a.spawn_player(0)
	b.spawn_player(0)
	b.submit(SimCommand.brake(9999, true))
	b.submit(SimCommand.boost(9999, true))
	S2.run(a, 30)
	S2.run(b, 30)
	assert_eq(a.state_hash(), b.state_hash(), "commands for unknown entities leave no trace")


# ======================================================== new entity fields are hashed

func test_new_entity_fields_are_part_of_the_hash() -> void:
	var base_world: SimWorld = _world()
	base_world.spawn_player(0)
	var base: int = base_world.state_hash()
	for field in ["pitch_deg", "yaw_deg", "braking", "speed"]:
		var w: SimWorld = _world()
		var en: SimEntity = w.get_entity(w.spawn_player(0))
		match field:
			"pitch_deg":
				en.pitch_deg += 1.0
			"yaw_deg":
				en.yaw_deg += 1.0
			"braking":
				en.braking = not en.braking
			_:
				en.speed += 1.0
		assert_ne(w.state_hash(), base, "SimEntity.%s must be hashed (contract: all new fields hashed)" % field)


# ======================================================== frame-rate independence (sim side)

func _end_state(w: SimWorld, id: int) -> Dictionary:
	var en: SimEntity = w.get_entity(id)
	return {"hash": w.state_hash(), "pos": en.position, "stamina": en.stamina, "tick": w.tick}


## Drive a freshly built world with the dense per-tick script using frame deltas from `deltas` (cycled)
## until exactly TICKS ticks ran.
func _run_with_frames(deltas: Array[float]) -> Dictionary:
	var w: SimWorld = _world()
	var id: int = w.spawn_player(0)
	S2.submit_per_tick_script(w, id, TICKS)
	var frame: int = 0
	var guard: int = 0
	while w.tick < TICKS and guard < 100000:
		w.advance(deltas[frame % deltas.size()])
		frame += 1
		guard += 1
	return _end_state(w, id)


func test_frame_rate_independence_30_60_120_fps_and_irregular() -> void:
	var by_step: SimWorld = _world()
	var sid: int = by_step.spawn_player(0)
	S2.submit_per_tick_script(by_step, sid, TICKS)
	S2.run(by_step, TICKS)
	var reference: Dictionary = _end_state(by_step, sid)
	assert_true((reference["pos"] as Vector3).distance_to(S2.map_spawn(0)) > 20.0, "script must really swim (otherwise this test is vacuous)")

	var d30: Array[float] = [1.0 / 30.0]
	var d60: Array[float] = [1.0 / 60.0]
	var d120: Array[float] = [1.0 / 120.0]
	var irregular: Array[float] = [0.0137, 0.009, 0.0211, 0.0166, 0.0049, 0.0302]
	var labels: Array[String] = ["30 fps", "60 fps", "120 fps", "irregular"]
	var all_deltas: Array = [d30, d60, d120, irregular]
	for i in labels.size():
		var label: String = labels[i]
		var deltas: Array[float] = all_deltas[i]
		var got: Dictionary = _run_with_frames(deltas)
		assert_eq(got["tick"], TICKS, "%s: exactly %d ticks" % [label, TICKS])
		assert_eq(got["hash"], reference["hash"], "%s: state hash differs from the 30 Hz step() reference" % label)
		assert_true((got["pos"] as Vector3).distance_to(reference["pos"] as Vector3) < 1e-6, "%s: end position %s vs reference %s" % [label, got["pos"], reference["pos"]])
		assert_almost_eq(float(got["stamina"]), float(reference["stamina"]), 1e-9, "%s: stamina" % label)


func test_frame_rate_independence_with_one_long_frame() -> void:
	# A hitch (one 0.5 s frame) must catch up with exactly the same ticks, not skip or double-step.
	var d30: Array[float] = [1.0 / 30.0]
	var reference: Dictionary = _run_with_frames(d30)
	var w: SimWorld = _world()
	var id: int = w.spawn_player(0)
	S2.submit_per_tick_script(w, id, TICKS)
	var ran: int = w.advance(0.5)
	assert_eq(ran, 15, "0.5 s = 15 ticks")
	while w.tick < TICKS:
		w.advance(1.0 / 30.0)  # accumulator is empty after the hitch: exactly one tick per call
	assert_eq(_end_state(w, id)["hash"], reference["hash"], "hitch frame must not change the result")


func test_advance_does_not_run_extra_ticks_for_tiny_deltas() -> void:
	var w: SimWorld = _world()
	w.spawn_player(0)
	var total: int = 0
	for i in 120:
		total += w.advance(1.0 / 120.0)
	assert_eq(total, 30, "120 frames of 1/120 s = exactly 30 ticks")
	assert_eq(w.tick, 30, "tick counter")


# ======================================================== static sim purity for the new file

func test_seabed_field_source_is_pure_and_noise_texture_free() -> void:
	var path: String = "res://scripts/sim/seabed_field.gd"
	assert_true(FileAccess.file_exists(path), "contract file missing: %s" % path)
	if not FileAccess.file_exists(path):
		return
	var lines: Array[String] = []
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		lines.append(raw.split("#")[0])
	var code: String = "\n".join(lines)
	assert_true(code.find("class_name SeabedField") != -1, "class_name SeabedField")
	var rx := RegEx.new()
	assert_eq(rx.compile("^\\s*extends\\s+RefCounted\\b"), OK, "test regex")
	var extends_ok: bool = false
	for l in lines:
		if rx.search(l) != null:
			extends_ok = true
	assert_true(extends_ok, "SeabedField extends RefCounted")
	var bad := RegEx.new()
	assert_eq(bad.compile("FastNoiseLite|NoiseTexture|\\brandf\\s*\\(|\\brandi\\s*\\(|\\brandomize\\s*\\(|\\bget_tree\\s*\\(|Time\\.get_|OS\\.get_ticks|extends\\s+Node"), OK, "test regex")
	var hit: RegExMatch = bad.search(code)
	assert_null(hit, "seabed_field.gd must be a pure function of data (found '%s')" % (hit.get_string() if hit != null else ""))
