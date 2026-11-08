extends TestCase
## S2 swim model in SimWorld with real content: acceleration, max speed, drag, brake, turn rate, pitch clamp,
## boost stamina, boundary current + hard clamp, surface ceiling, seabed/obstacle contact, spawn_player, hashing.

static var _db: ContentDB = null


func _content() -> ContentDB:
	if _db == null:
		_db = ContentDB.load_from_dir("res://data")
	return _db


func _world() -> SimWorld:
	return SimWorld.new(7, _content())


func _band(i: int) -> Dictionary:
	return _content().get_band(i)


func _boost() -> Dictionary:
	return _content().get_ability(&"boost")


## Open water in the shallows-to-kelp slope, far from obstacles and edges; heading already -Z (FORWARD).
func _spawn_open(w: SimWorld, pos: Vector3 = Vector3(0, -6, -200)) -> int:
	return w.spawn_entity(&"small_reef_fish", pos, 0.15, true)


func _run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.step()


func test_content_is_valid() -> void:
	assert_true(_content().is_valid(), "real data must validate: %s" % "; ".join(_content().errors))


func test_brake_is_appended_to_the_command_enum() -> void:
	assert_eq(SimCommand.Type.BRAKE, 4, "BRAKE is appended at the end (S0 values unchanged)")
	var c := SimCommand.brake(3, true, 12)
	assert_eq(c.type, SimCommand.Type.BRAKE, "type")
	assert_eq(c.entity_id, 3, "entity")
	assert_true(c.active, "active")
	assert_eq(c.tick, 12, "tick")
	assert_eq(SimCommand.brake(1, false).tick, -1, "default tick")


func test_world_has_seabed_from_map() -> void:
	var w := _world()
	assert_not_null(w.seabed, "content with the reef map builds a SeabedField")
	assert_false(w.map.is_empty(), "map record exposed")
	assert_null(SimWorld.new(1).seabed, "no content -> no map collision")


func test_acceleration_is_limited_and_reaches_max_speed() -> void:
	var w := _world()
	var id := _spawn_open(w)
	var accel: float = float(_band(1)["accel_mps2"])
	var vmax: float = float(_band(1)["swim_speed_mps"])
	w.submit(SimCommand.move(id, Vector3.FORWARD, 1.0))
	w.step()
	assert_almost_eq(w.get_entity(id).speed, accel * SimWorld.TICK_DT, 1e-4, "one tick of acceleration")
	var peak: float = 0.0
	for i in 90:
		w.step()
		peak = maxf(peak, w.get_entity(id).speed)
	assert_almost_eq(w.get_entity(id).speed, vmax, 1e-3, "reaches band swim_speed_mps")
	assert_true(peak <= vmax + 1e-4, "never exceeds max speed (peak %f)" % peak)


func test_half_thrust_halves_max_speed() -> void:
	var w := _world()
	var id := _spawn_open(w)
	w.submit(SimCommand.move(id, Vector3.FORWARD, 0.5))
	_run(w, 90)
	assert_almost_eq(w.get_entity(id).speed, float(_band(1)["swim_speed_mps"]) * 0.5, 1e-3, "thrust scales max speed")


func test_coasting_decays_with_drag() -> void:
	var w := _world()
	var id := _spawn_open(w)
	w.submit(SimCommand.move(id, Vector3.FORWARD, 1.0))
	_run(w, 60)
	var v0: float = w.get_entity(id).speed
	w.submit(SimCommand.move(id, Vector3.FORWARD, 0.0))
	_run(w, 30)
	var expected: float = v0 * exp(-float(_band(1)["drag_per_s"]))
	assert_almost_eq(w.get_entity(id).speed, expected, 0.01, "1 s of drag")
	_run(w, 600)
	assert_eq(w.get_entity(id).speed, 0.0, "comes to rest eventually")


func test_brake_stops_faster_than_drag_and_beats_thrust() -> void:
	var w := _world()
	var id := _spawn_open(w)
	w.submit(SimCommand.move(id, Vector3.FORWARD, 1.0))
	_run(w, 60)
	var v0: float = w.get_entity(id).speed
	w.submit(SimCommand.brake(id, true))  # thrust still held
	var ticks_to_stop: int = ceili(v0 / float(_band(1)["brake_decel_mps2"]) / SimWorld.TICK_DT) + 1
	_run(w, ticks_to_stop)
	var e: SimEntity = w.get_entity(id)
	assert_true(e.braking, "braking flag")
	assert_eq(e.speed, 0.0, "stopped within v/brake_decel (%d ticks)" % ticks_to_stop)
	w.submit(SimCommand.brake(id, false))
	_run(w, 5)
	assert_false(w.get_entity(id).braking, "brake released")
	assert_true(w.get_entity(id).speed > 0.0, "thrust resumes after the brake")


func test_turn_rate_is_limited() -> void:
	var w := _world()
	var id := _spawn_open(w)
	var max_step: float = deg_to_rad(float(_band(1)["turn_rate_deg_s"])) * SimWorld.TICK_DT
	w.submit(SimCommand.move(id, Vector3.BACK, 1.0))  # 180 degree turn
	var prev: Vector3 = w.get_entity(id).heading
	for i in 40:
		w.step()
		var h: Vector3 = w.get_entity(id).heading
		assert_true(prev.angle_to(h) <= max_step + 1e-4, "tick %d turned %f rad > %f" % [i, prev.angle_to(h), max_step])
		assert_almost_eq(h.length(), 1.0, 1e-4, "heading stays unit")
		prev = h
	assert_true(prev.dot(Vector3.BACK) > 0.999, "finishes the turn, got %s" % prev)


func test_pitch_is_clamped_and_yaw_derived() -> void:
	var w := _world()
	var id := _spawn_open(w, Vector3(0, -30, -80))
	var max_pitch: float = float(_content().rules()["swim"]["max_pitch_deg"])
	w.submit(SimCommand.move(id, Vector3.UP, 1.0))
	_run(w, 30)
	var e: SimEntity = w.get_entity(id)
	assert_true(e.heading.is_finite(), "no NaN for a vertical aim")
	assert_almost_eq(e.pitch_deg, max_pitch, 0.01, "pitch clamped")
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	_run(w, 30)
	e = w.get_entity(id)
	assert_almost_eq(e.yaw_deg, -90.0, 0.01, "facing +X = yaw -90 (rotation.y convention)")
	assert_almost_eq(e.pitch_deg, 0.0, 0.01, "level")


func test_heading_turns_without_thrust() -> void:
	var w := _world()
	var id := _spawn_open(w)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 0.0))
	_run(w, 30)
	var e: SimEntity = w.get_entity(id)
	assert_true(e.heading.dot(Vector3.RIGHT) > 0.999, "the fish faces the aim while idle")
	assert_eq(e.speed, 0.0, "but does not move")


func test_boost_raises_speed_and_drains_stamina() -> void:
	var w := _world()
	var id: int = w.spawn_player()
	var e: SimEntity = w.get_entity(id)
	e.position = Vector3(0, -6, -150)  # interior: the whole run stays clear of the edge current
	var smax: float = float(_boost()["stamina_max"])
	var drain: float = float(_boost()["stamina_drain_per_s"])
	assert_almost_eq(e.stamina, smax, 1e-6, "player starts with full stamina")
	w.submit(SimCommand.move(id, Vector3.FORWARD, 1.0))
	w.submit(SimCommand.boost(id, true))
	_run(w, 30)
	assert_almost_eq(e.stamina, smax - drain, 0.01, "1 s of boost drains drain_per_s")
	assert_almost_eq(e.speed, float(_band(1)["swim_speed_mps"]) * float(_boost()["speed_mult"]), 1e-3, "boosted max speed")
	_run(w, ceili((smax - drain) / drain * SimWorld.TICK_RATE) + 1)
	assert_almost_eq(e.stamina, 0.0, float(_boost()["stamina_regen_per_s"]) * SimWorld.TICK_DT + 1e-6, "empty (at most one tick of regen since)")
	assert_false(e.boosting, "boost stops at 0 stamina")
	w.submit(SimCommand.boost(id, false))  # released: a held boost restarts by itself at the restart threshold
	_run(w, 60)
	assert_almost_eq(e.speed, float(_band(1)["swim_speed_mps"]), 1e-3, "back to normal max speed")


func test_stamina_regenerates_and_gates_restart() -> void:
	var w := _world()
	var id: int = w.spawn_player()
	var e: SimEntity = w.get_entity(id)
	e.stamina = 0.0
	w.submit(SimCommand.move(id, Vector3.FORWARD, 1.0))
	w.submit(SimCommand.boost(id, true))
	w.step()
	assert_false(e.boosting, "cannot start a boost with 0 stamina")
	_run(w, 29)
	assert_almost_eq(e.stamina, float(_boost()["stamina_regen_per_s"]), 0.01, "1 s of regen")
	var threshold: float = float(_boost()["restart_min_stamina_frac"]) * float(_boost()["stamina_max"])
	var regen: float = float(_boost()["stamina_regen_per_s"])
	if e.stamina < threshold:
		w.submit(SimCommand.boost(id, true))
		w.step()
		assert_false(e.boosting, "no restart below the restart threshold (%s < %s)" % [e.stamina, threshold])
		_run(w, ceili((threshold - e.stamina) / regen * SimWorld.TICK_RATE) + 1)
	w.submit(SimCommand.boost(id, true))
	w.step()
	assert_true(e.boosting, "restart works once stamina >= the restart threshold")


func test_boosting_without_moving_neither_drains_nor_regens() -> void:
	var w := _world()
	var id: int = w.spawn_player()
	var e: SimEntity = w.get_entity(id)
	e.stamina = 50.0
	w.submit(SimCommand.boost(id, true))
	_run(w, 30)
	assert_true(e.boosting, "still boosting")
	assert_almost_eq(e.stamina, 50.0, 1e-6, "no drain while not moving")


func test_spawn_player() -> void:
	var w := _world()
	var id: int = w.spawn_player()
	var e: SimEntity = w.get_entity(id)
	var sp: Array = w.map["player_spawns"][0]
	assert_true(e.is_player, "is_player")
	assert_eq(e.species_id, SimWorld.PLAYER_SPECIES_ID, "player species")
	assert_almost_eq(e.length_m, float(_band(1)["length_m"]["min"]), 1e-6, "band 1 minimum length")
	assert_true(e.position.distance_to(Vector3(sp[0], sp[1], sp[2])) < 1e-4, "at player_spawns[0]")
	var n: int = (w.map["player_spawns"] as Array).size()
	var id2: int = w.spawn_player(n + 1)
	var sp1: Array = w.map["player_spawns"][1]
	assert_true(w.get_entity(id2).position.distance_to(Vector3(sp1[0], sp1[1], sp1[2])) < 1e-4, "index wraps")


func test_surface_is_a_ceiling() -> void:
	var w := _world()
	var id := _spawn_open(w, Vector3(0, -1, -200))
	var r: float = w.collision_radius(w.get_entity(id))
	assert_true(r > 0.0, "radius from band data")
	w.submit(SimCommand.move(id, Vector3(0, 1, -1), 1.0))
	for i in 120:
		w.step()
		assert_true(w.get_entity(id).position.y <= -r + 1e-6, "y <= -radius at tick %d: %f" % [i, w.get_entity(id).position.y])
	assert_true(w.get_entity(id).velocity.y <= 1e-6, "no velocity into the ceiling")


func test_seabed_is_a_floor() -> void:
	var w := _world()
	var id := _spawn_open(w, Vector3(10, -6, -220))
	var e: SimEntity = w.get_entity(id)
	var r: float = w.collision_radius(e)
	w.submit(SimCommand.move(id, Vector3(0, -1, -0.2), 1.0))
	w.submit(SimCommand.boost(id, true))
	for i in 150:
		w.step()
		var floor_y: float = w.seabed.height_at(e.position.x, e.position.z)
		assert_true(e.position.y >= floor_y, "centre above the seabed at tick %d (y %f, floor %f)" % [i, e.position.y, floor_y])
	assert_true(e.position.y - w.seabed.height_at(e.position.x, e.position.z) < r * 2.0, "the dive actually reached the floor")


func test_obstacle_blocks_the_fish() -> void:
	var w := _world()
	var hull: Dictionary = {}
	for o in w.seabed.obstacles():
		if o["id"] == "boat_hull":
			hull = o
	assert_false(hull.is_empty(), "boat hull in map data")
	var c: Vector3 = hull["center"]
	var half: Vector3 = (hull["size"] as Vector3) * 0.5
	var id := _spawn_open(w, Vector3(c.x - half.x - 3.0, c.y, c.z))
	var e: SimEntity = w.get_entity(id)
	e.heading = Vector3.RIGHT
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	for i in 90:
		w.step()
		var inside: bool = absf(e.position.x - c.x) < half.x and absf(e.position.y - c.y) < half.y and absf(e.position.z - c.z) < half.z
		assert_false(inside, "fish centre inside the boat at tick %d: %s" % [i, e.position])


func test_soft_current_pushes_back_from_the_edge() -> void:
	var w := _world()
	var half: float = float(w.map["size_m"]) * 0.5
	var margin: float = float(w.map["bounds"]["soft_margin_m"])
	var cap: float = float(w.map["bounds"]["current_mps"])
	var id := _spawn_open(w, Vector3(half - margin * 0.25, -8, -200))
	var e: SimEntity = w.get_entity(id)
	var x0: float = e.position.x
	var peak: float = 0.0
	for i in 60:
		w.step()
		peak = maxf(peak, -e.velocity.x)
	assert_true(e.position.x < x0 - 1.0, "idle fish drifts toward the centre (x %f -> %f)" % [x0, e.position.x])
	assert_true(peak > cap * 0.5 and peak <= cap * 0.75 + 1e-4, "drift speed follows the ramped current (peak %f, cap %f)" % [peak, cap])
	var id2 := _spawn_open(w, Vector3(0, -8, -200))
	w.step()
	assert_almost_eq(w.get_entity(id2).position.x, 0.0, 1e-6, "no current in the interior")


func test_edge_is_a_hard_clamp_even_when_boosting() -> void:
	var w := _world()
	var half: float = float(w.map["size_m"]) * 0.5
	var id: int = w.spawn_player()
	var e: SimEntity = w.get_entity(id)
	e.position = Vector3(half - 50.0, -8, -200)
	e.heading = Vector3.RIGHT
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(id, true))
	var r: float = w.collision_radius(e)
	for i in 600:
		w.step()
		assert_true(e.position.x <= half - r + 1e-6, "hard clamp at tick %d: %f" % [i, e.position.x])
	# teleported outside -> clamped back in one tick
	e.position = Vector3(half + 30.0, -8, -half - 30.0)
	w.step()
	assert_true(absf(e.position.x) <= half and absf(e.position.z) <= half, "clamped into the map: %s" % e.position)


func test_movement_is_deterministic_and_new_state_is_hashed() -> void:
	var a := _world()
	var b := _world()
	for w: SimWorld in [a, b]:
		var id: int = w.spawn_player()
		w.submit(SimCommand.move(id, Vector3(0.3, -0.4, -1.0), 1.0, 0))
		w.submit(SimCommand.boost(id, true, 10))
		w.submit(SimCommand.brake(id, true, 40))
		w.submit(SimCommand.brake(id, false, 55))
		w.submit(SimCommand.move(id, Vector3(-1, 0.2, 0), 0.7, 70))
		_run(w, 200)
	assert_eq(a.state_hash(), b.state_hash(), "same commands -> same hash")
	var e: SimEntity = a.get_entity(1)
	e.braking = not e.braking
	assert_ne(a.state_hash(), b.state_hash(), "braking is hashed")
	e.braking = not e.braking
	e.pitch_deg += 1.0
	assert_ne(a.state_hash(), b.state_hash(), "pitch_deg is hashed")
	e.pitch_deg -= 1.0
	e.speed += 0.5
	assert_ne(a.state_hash(), b.state_hash(), "speed is hashed")


func test_frame_pacing_does_not_change_movement() -> void:
	var a := _world()
	var b := _world()
	var ia: int = a.spawn_player()
	var ib: int = b.spawn_player()
	a.submit(SimCommand.move(ia, Vector3(1, -0.2, -1), 1.0, 0))
	b.submit(SimCommand.move(ib, Vector3(1, -0.2, -1), 1.0, 0))
	for i in 300:  # 10 s at 30 fps
		a.advance(1.0 / 30.0)
	for i in 1200:  # 10 s at 120 fps
		b.advance(1.0 / 120.0)
	assert_eq(a.tick, b.tick, "same tick count")
	assert_eq(a.get_entity(ia).position, b.get_entity(ib).position, "identical position at 30 and 120 fps")


func test_non_finite_move_ignored_with_content() -> void:
	var w := _world()
	var id: int = w.spawn_player()
	w.submit(SimCommand.move(id, Vector3(NAN, 0, -1), 1.0))
	w.submit(SimCommand.move(id, Vector3(0, 0, -1), INF))
	_run(w, 10)
	var e: SimEntity = w.get_entity(id)
	assert_true(e.position.is_finite() and e.velocity.is_finite() and e.heading.is_finite(), "state stays finite")
