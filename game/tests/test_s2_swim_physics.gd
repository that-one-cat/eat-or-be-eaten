extends TestCase
## S2 swim model (sim side): speed limits, boost + stamina, brake, turn rate, pitch clamp, no roll, spawn.
## Tunables (speeds, accel, turn rate, radius) come from ContentDB; only the numbers GAME_DESIGN §4 states
## (stamina 100, drain 25/s, regen 15/s, boost x1.8) are asserted literally.
## Every test builds its own world (before_each), no real waits: the sim is stepped by hand.

const S2 := preload("res://tests/s2_support.gd")
const DT: float = SimWorld.TICK_DT

var w: SimWorld
var e: SimEntity
var pid: int = 0


func before_each() -> void:
	w = S2.make_world(11)
	e = null
	pid = 0


## Player at the open-water lane, facing `heading`, in band `b`.
func _place(b: int = 1, heading: Vector3 = Vector3.RIGHT, pos: Vector3 = Vector3.INF) -> void:
	var p: Vector3 = S2.lane_start() if not pos.is_finite() else pos
	e = S2.spawn_at(w, p, heading, b)
	pid = e.id


func _band_count() -> int:
	return S2.content().band_count()


# ======================================================== data sanity (tests below rely on it)

func test_setup_real_data_is_valid_and_lane_is_clear() -> void:
	var c: ContentDB = S2.content()
	assert_true(c.is_valid(), "real data must validate: %s" % "\n".join(c.errors))
	var sb: SeabedField = S2.seabed()
	for b in range(1, c.band_count() + 1):
		var r: float = S2.radius_for(b, S2.band_length(b))
		assert_true(r > 0.0, "band %d collision radius must be > 0" % b)
		assert_true(S2.lane_is_clear(sb, r), "test setup: abyss lane (y=%s, z=%s) must be free of seabed/obstacles for band %d" % [S2.LANE_Y, S2.LANE_Z, b])
	assert_true(S2.soft_margin() < 90.0, "test setup: soft margin must leave the abyss lane (90 m from the edge) calm")


# ======================================================== spawn

func test_spawn_player_uses_map_spawns_species_and_band_one() -> void:
	var c: ContentDB = S2.content()
	var spawns: Array = S2.map()["player_spawns"]
	var stamina_max: float = float(S2.boost()["stamina_max"])
	for i in spawns.size():
		var world: SimWorld = S2.make_world(5)
		var id: int = world.spawn_player(i)
		var pl: SimEntity = world.get_entity(id)
		assert_not_null(pl, "spawn %d: entity exists" % i)
		if pl == null:
			continue
		var s: Array = spawns[i]
		assert_true(pl.position.distance_to(Vector3(float(s[0]), float(s[1]), float(s[2]))) < 1e-3, "spawn %d position = reef.json player_spawns[%d]" % [i, i])
		assert_eq(pl.species_id, &"small_reef_fish", "player species")
		assert_true(pl.is_player, "is_player")
		assert_true(pl.alive, "alive")
		assert_eq(pl.band, 1, "starts in band 1")
		assert_almost_eq(pl.length_m, S2.band_length(1), 1e-6, "starting length = band 1 min")
		assert_almost_eq(pl.stamina, stamina_max, 1e-6, "starts with full stamina")
		assert_eq(c.band_for_xp(pl.xp), 1, "xp maps to band 1")


func test_spawn_player_default_index_is_zero() -> void:
	var a: SimWorld = S2.make_world(5)
	var b: SimWorld = S2.make_world(5)
	var pa: SimEntity = a.get_entity(a.spawn_player())
	var pb: SimEntity = b.get_entity(b.spawn_player(0))
	assert_true(pa.position.is_equal_approx(pb.position), "spawn_player() == spawn_player(0)")


func test_idle_player_stays_put_at_every_spawn() -> void:
	# Spawns must sit in calm water: no current drift, no seabed push, no ceiling push.
	var n: int = (S2.map()["player_spawns"] as Array).size()
	for i in n:
		var world: SimWorld = S2.make_world(5)
		var pl: SimEntity = world.get_entity(world.spawn_player(i))
		var start: Vector3 = pl.position
		S2.run(world, 60)
		assert_true(pl.position.distance_to(start) < 0.05, "spawn %d: idle player drifted %s m" % [i, pl.position.distance_to(start)])


# ======================================================== max speed

func test_reaches_but_never_exceeds_band_max_speed() -> void:
	for b in range(1, _band_count() + 1):
		w = S2.make_world(3)
		_place(b)
		var vmax: float = S2.band_speed(b)
		var accel: float = S2.band_f(b, "accel_mps2")
		assert_true(accel > 0.0, "band %d accel_mps2 > 0" % b)
		var t_reach: float = maxf(10.0, 3.0 * vmax / maxf(accel, 1e-6))
		w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
		var peak: float = 0.0
		for i in int(ceil(t_reach * 30.0)):
			w.step()
			peak = maxf(peak, e.velocity.length())
			if e.position.x > S2.LANE_X0 + 390.0:
				fail("band %d: lane exhausted before the settle time (accel too low?)" % b)
				break
		assert_true(peak <= vmax + 1e-3, "band %d: peak %s exceeds swim_speed_mps %s" % [b, peak, vmax])
		assert_true(peak >= vmax * 0.97, "band %d: peak %s never reached swim_speed_mps %s within %s s" % [b, peak, vmax, t_reach])


func test_speed_field_matches_velocity_length() -> void:
	_place(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	for i in 90:
		w.step()
		assert_almost_eq(e.speed, e.velocity.length(), 0.01, "tick %d: SimEntity.speed == |velocity|" % i)


func test_partial_thrust_never_faster_than_full_thrust() -> void:
	var half_world: SimWorld = S2.make_world(3)
	var half_e: SimEntity = S2.spawn_at(half_world, S2.lane_start(), Vector3.RIGHT, 1)
	_place(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	half_world.submit(SimCommand.move(half_e.id, Vector3.RIGHT, 0.5))
	for i in 150:
		w.step()
		half_world.step()
		assert_true(half_e.velocity.length() <= e.velocity.length() + 1e-4, "tick %d: thrust 0.5 faster than thrust 1.0" % i)
		assert_true(half_e.velocity.length() <= S2.band_speed(1) + 1e-3, "tick %d: thrust 0.5 above band max" % i)


func test_zero_thrust_at_rest_does_not_move() -> void:
	_place(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 0.0))
	S2.run(w, 60)
	assert_true(e.position.distance_to(S2.lane_start()) < 1e-4, "thrust 0 at rest: no movement")
	assert_true(e.velocity.length() < 1e-4, "thrust 0 at rest: no velocity")


func test_released_thrust_coasts_down_not_up() -> void:
	_place(1)
	var vmax: float = S2.band_speed(1)
	e.velocity = Vector3.RIGHT * vmax
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 0.0))
	var prev: float = vmax
	for i in 60:
		w.step()
		var s: float = e.velocity.length()
		assert_true(s <= prev + 1e-6, "tick %d: coasting speed must not increase (%s -> %s)" % [i, prev, s])
		prev = s
	assert_true(prev < vmax, "drag must slow a coasting fish")


# ======================================================== boost + stamina

func test_boost_raises_max_speed_to_speed_mult() -> void:
	var mult: float = float(S2.boost()["speed_mult"])
	assert_almost_eq(mult, 1.8, 1e-6, "GAME_DESIGN §4: boost x1.8")
	for b in range(1, _band_count() + 1):
		w = S2.make_world(3)
		_place(b)
		var vmax: float = S2.band_speed(b)
		e.velocity = Vector3.RIGHT * vmax  # already cruising, so only the boost headroom has to be built up
		w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
		w.submit(SimCommand.boost(pid, true))
		var peak: float = 0.0
		for i in 118:  # 100 stamina / 25 per s = 4 s = 120 ticks of boost available
			w.step()
			peak = maxf(peak, e.velocity.length())
		assert_true(peak <= vmax * mult + 1e-3, "band %d: boosted peak %s exceeds %s x %s" % [b, peak, vmax, mult])
		assert_true(peak >= vmax * mult * 0.95, "band %d: boosted peak %s never approached %s" % [b, peak, vmax * mult])


func test_boost_from_rest_never_exceeds_boosted_max() -> void:
	var mult: float = float(S2.boost()["speed_mult"])
	_place(2)
	var cap: float = S2.band_speed(2) * mult
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	for i in 118:
		w.step()
		assert_true(e.velocity.length() <= cap + 1e-3, "tick %d: speed %s above boosted cap %s" % [i, e.velocity.length(), cap])


func test_stamina_drains_25_per_second_while_boosting_and_moving() -> void:
	_place(1)
	assert_almost_eq(e.stamina, 100.0, 1e-6, "GAME_DESIGN §4: stamina 100")
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	var prev: float = e.stamina
	for i in 30:
		w.step()
		if i >= 2:  # first ticks may differ by one tick of command ordering
			assert_almost_eq(prev - e.stamina, 25.0 / 30.0, 0.05, "tick %d: drain per tick" % i)
		prev = e.stamina
	assert_almost_eq(e.stamina, 75.0, 1.0, "after 1 s of boosting stamina ~75")


func test_stamina_not_drained_while_boosting_without_thrust() -> void:
	_place(1)
	e.stamina = 50.0
	w.submit(SimCommand.boost(pid, true))
	S2.run(w, 30)
	assert_true(e.stamina >= 50.0 - 0.01, "boost without moving must not drain (got %s)" % e.stamina)


func test_stamina_regenerates_15_per_second_when_not_boosting() -> void:
	# idle
	_place(1)
	e.stamina = 40.0
	S2.run(w, 30)
	assert_almost_eq(e.stamina, 55.0, 1.0, "idle regen ~15/s")
	# moving but not boosting
	w = S2.make_world(11)
	_place(1)
	e.stamina = 40.0
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	S2.run(w, 30)
	assert_almost_eq(e.stamina, 55.0, 1.0, "regen continues while swimming without boost")


func test_stamina_is_capped_at_max() -> void:
	_place(1)
	e.stamina = 95.0
	var cap: float = float(S2.boost()["stamina_max"])
	for i in 60:
		w.step()
		assert_true(e.stamina <= cap + 1e-6, "tick %d: stamina %s above cap %s" % [i, e.stamina, cap])
	assert_almost_eq(e.stamina, cap, 1e-6, "full again")


func test_boost_cuts_at_zero_stamina_and_speed_falls_back() -> void:
	_place(1)
	var vmax: float = S2.band_speed(1)
	var mult: float = float(S2.boost()["speed_mult"])
	e.velocity = Vector3.RIGHT * vmax
	# start exactly at the restart threshold (the least stamina a boost can start with): 0.8 s of boost with the data
	var drain: float = float(S2.boost()["stamina_drain_per_s"])
	var start: float = float(S2.boost()["restart_min_stamina_frac"]) * float(S2.boost()["stamina_max"])
	e.stamina = start
	var expect_tick: int = roundi(start / drain * 30.0)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	var zero_tick: int = -1
	for i in 60:
		w.step()
		assert_true(e.stamina >= -1e-9, "tick %d: stamina below 0 (%s)" % [i, e.stamina])
		if zero_tick < 0 and e.stamina <= 1e-9:
			zero_tick = i
	assert_true(zero_tick >= expect_tick - 2 and zero_tick <= expect_tick + 2, "%s stamina at %s/s empties in ~%d ticks, got tick %d" % [start, drain, expect_tick, zero_tick])
	assert_false(e.boosting, "boost must stop by itself at 0 stamina (Shift still 'held': no new BOOST command)")
	# Speed falls back to the normal band max (no sticky boost speed). Shift is released now: a held boost would
	# restart by itself at the restart threshold (Director rule, covered by test_held_boost_restarts_by_itself...).
	w.submit(SimCommand.boost(pid, false))
	var drag: float = S2.band_f(1, "drag_per_s")
	var window_s: float = maxf(4.0, 4.0 * log(mult) / maxf(drag, 0.05))
	S2.run(w, int(ceil(window_s * 30.0)))
	assert_true(e.velocity.length() <= vmax + 1e-3, "after the cut speed %s must be back to <= %s" % [e.velocity.length(), vmax])
	assert_false(e.boosting, "boost stays off once released")


func test_boost_cannot_start_at_zero_stamina() -> void:
	_place(1)
	e.stamina = 0.0
	e.boosting = false
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	w.step()
	assert_false(e.boosting, "BOOST(true) with stamina 0 must be refused")
	assert_true(e.stamina >= 0.0, "stamina stays >= 0")


func test_boost_can_restart_after_stamina_regenerates() -> void:
	_place(1)
	e.stamina = 0.0
	e.boosting = false
	var threshold: float = float(S2.boost()["restart_min_stamina_frac"]) * float(S2.boost()["stamina_max"])
	S2.run(w, ceili(threshold / float(S2.boost()["stamina_regen_per_s"]) * 30.0) + 1)
	assert_true(e.stamina >= threshold, "regen while idle up to the restart threshold %s (got %s)" % [threshold, e.stamina])
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	w.step()
	assert_true(e.boosting, "boost restarts once stamina >= the restart threshold")


func test_boost_below_the_restart_threshold_is_refused() -> void:
	# Director rule: a boost (re)starts only at stamina >= restart_min_stamina_frac x stamina_max.
	_place(1)
	var threshold: float = float(S2.boost()["restart_min_stamina_frac"]) * float(S2.boost()["stamina_max"])
	assert_true(threshold > 1.0, "data: restart threshold %s is above 1 stamina" % threshold)
	e.stamina = threshold - 1.0
	e.boosting = false
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	w.step()
	assert_false(e.boosting, "stamina %s < threshold %s: BOOST(true) does not start a boost" % [threshold - 1.0, threshold])
	assert_true(e.boost_held, "the intent is kept while Shift is held")


func test_held_boost_restarts_by_itself_at_the_threshold() -> void:
	# Director rule: with Shift held through the cut, the boost comes back once stamina regenerates to the threshold,
	# without a new BOOST command; then it drains to 0 and cuts again.
	_place(1)
	var threshold: float = float(S2.boost()["restart_min_stamina_frac"]) * float(S2.boost()["stamina_max"])
	e.stamina = 0.0
	e.boosting = false
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))  # the only BOOST command in this test
	var reached_tick: int = -1
	var restart_tick: int = -1
	for i in 120:
		var before: float = e.stamina
		w.step()
		if restart_tick < 0 and e.boosting:
			restart_tick = i
			assert_true(before >= threshold, "restart at tick %d with stamina %s >= threshold %s" % [i, before, threshold])
			break
		if reached_tick < 0 and e.stamina >= threshold:
			reached_tick = i
	assert_true(reached_tick >= 0, "stamina regenerated to the threshold while held")
	assert_eq(restart_tick, reached_tick + 1, "the held boost restarts on the tick after stamina reaches the threshold")
	# it drains back to 0 and cuts again, still held
	var cut: bool = false
	for i in 120:
		w.step()
		if not e.boosting:
			cut = true
			break
	assert_true(cut, "the restarted boost cuts again at 0 stamina")
	assert_true(e.stamina <= 1e-9, "cut at 0 stamina (got %s)" % e.stamina)
	assert_true(e.boost_held, "Shift is still held")


func test_boost_off_command_stops_drain() -> void:
	_place(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(pid, true))
	S2.run(w, 30)
	var low: float = e.stamina
	w.submit(SimCommand.boost(pid, false))
	S2.run(w, 30)
	assert_false(e.boosting, "boosting off")
	assert_true(e.stamina > low, "stamina recovers after BOOST(false)")


func test_stamina_always_within_bounds_under_scripted_play() -> void:
	_place(1)
	var cap: float = float(S2.boost()["stamina_max"])
	var segs: Array[Dictionary] = S2.movement_script(77, 600, true, true)
	S2.submit_segments(w, pid, segs)
	for i in 600:
		w.step()
		assert_true(e.stamina >= -1e-9 and e.stamina <= cap + 1e-6, "tick %d: stamina %s outside [0, %s]" % [i, e.stamina, cap])
		assert_true(e.velocity.is_finite() and e.position.is_finite(), "tick %d: state finite" % i)


# ======================================================== brake

## Speeds per tick for a fish cruising at band max that lets go of thrust (and optionally brakes).
func _speeds_after_cruise(brake: bool, ticks: int) -> Array[float]:
	w = S2.make_world(3)
	_place(1)
	e.velocity = Vector3.RIGHT * S2.band_speed(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 0.0))
	if brake:
		w.submit(SimCommand.brake(pid, true))
	var out: Array[float] = []
	for i in ticks:
		w.step()
		out.append(e.velocity.length())
	return out


func test_brake_decelerates_faster_than_coasting() -> void:
	var coast: Array[float] = _speeds_after_cruise(false, 30)
	var braked: Array[float] = _speeds_after_cruise(true, 30)
	for i in range(2, 15):
		if coast[i] > 0.05:
			assert_true(braked[i] < coast[i], "tick %d: braked %s must be slower than coasting %s" % [i, braked[i], coast[i]])


func test_brake_deceleration_matches_data() -> void:
	var v0: float = S2.band_speed(1)
	var decel: float = S2.band_f(1, "brake_decel_mps2")
	assert_true(decel > 0.0, "brake_decel_mps2 > 0")
	var ticks: int = 8
	var braked: Array[float] = _speeds_after_cruise(true, ticks)
	var t: float = float(ticks) * DT
	var expected_max: float = maxf(0.0, v0 - 0.8 * decel * t)
	assert_true(braked[ticks - 1] <= expected_max + 1e-3, "after %s s braking speed %s should be <= %s (brake_decel_mps2 %s)" % [t, braked[ticks - 1], expected_max, decel])


func test_brake_stops_the_fish_without_reversing() -> void:
	var decel: float = S2.band_f(1, "brake_decel_mps2")
	var stop_ticks: int = int(ceil((S2.band_speed(1) / maxf(decel, 1e-6) + 1.0) * 30.0))
	_place(1)
	e.velocity = Vector3.RIGHT * S2.band_speed(1)
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 0.0))
	w.submit(SimCommand.brake(pid, true))
	for i in stop_ticks + 30:
		w.step()
		assert_true(e.velocity.dot(Vector3.RIGHT) >= -1e-4, "tick %d: braking must never reverse the fish (v.x=%s)" % [i, e.velocity.x])
	assert_true(e.velocity.length() < 0.01, "fish is at rest after braking, speed %s" % e.velocity.length())
	var rest_pos: Vector3 = e.position
	S2.run(w, 30)
	assert_true(e.position.distance_to(rest_pos) < 0.01, "a stopped, braking fish stays put")


func test_braking_flag_follows_commands() -> void:
	_place(1)
	assert_false(e.braking, "not braking initially")
	w.submit(SimCommand.brake(pid, true))
	w.step()
	assert_true(e.braking, "BRAKE(true) sets braking")
	w.submit(SimCommand.brake(pid, false))
	w.step()
	assert_false(e.braking, "BRAKE(false) clears braking")


func test_fish_can_accelerate_again_after_brake_release() -> void:
	_place(1)
	w.submit(SimCommand.brake(pid, true))
	S2.run(w, 15)
	w.submit(SimCommand.brake(pid, false))
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	S2.run(w, 60)
	assert_true(e.velocity.length() > S2.band_speed(1) * 0.5, "after releasing the brake the fish accelerates again (speed %s)" % e.velocity.length())


func test_command_enum_keeps_s0_values_and_appends_brake() -> void:
	assert_eq(int(SimCommand.Type.MOVE), 0, "MOVE")
	assert_eq(int(SimCommand.Type.BOOST), 1, "BOOST")
	assert_eq(int(SimCommand.Type.BITE), 2, "BITE")
	assert_eq(int(SimCommand.Type.ABILITY), 3, "ABILITY")
	assert_eq(int(SimCommand.Type.BRAKE), 4, "BRAKE appended at the END of the enum")
	var c: SimCommand = SimCommand.brake(3, true, 7)
	assert_eq(c.type, SimCommand.Type.BRAKE, "type")
	assert_eq(c.entity_id, 3, "entity")
	assert_true(c.active, "active")
	assert_eq(c.tick, 7, "tick")
	assert_eq(SimCommand.brake(3, false).tick, -1, "default tick -1")


# ======================================================== turning

func test_turn_rate_limits_heading_change_per_tick() -> void:
	var targets: Array[Vector3] = [
		Vector3.RIGHT,                              # 90 deg yaw
		Vector3(0.5, 0.0, 0.866025),                # 150 deg yaw (turns away from the initial -Z)
		Vector3(0.0, 0.7071, -0.7071),              # 45 deg pitch up
	]
	for b in range(1, _band_count() + 1):
		var limit: float = S2.band_f(b, "turn_rate_deg_s") * DT
		assert_true(limit > 0.0, "band %d turn_rate_deg_s > 0" % b)
		for target in targets:
			w = S2.make_world(3)
			_place(b, Vector3.FORWARD)
			var angle_total: float = S2.angle_deg(Vector3.FORWARD, target)
			w.submit(SimCommand.move(pid, target, 1.0))
			var prev: Vector3 = e.heading
			var settle: int = mini(int(ceil(angle_total / maxf(limit, 1e-6))) * 3 + 10, 900)
			for i in settle:
				w.step()
				var d: float = S2.angle_deg(prev, e.heading)
				assert_true(d <= limit + 0.05, "band %d target %s tick %d: turned %s deg > limit %s deg/tick" % [b, target, i, d, limit])
				assert_true(absf(e.heading.length() - 1.0) < 1e-4, "heading stays unit length")
				prev = e.heading
			assert_true(S2.angle_deg(e.heading, target) < 1.0, "band %d: heading converges to the commanded direction (off by %s deg)" % [b, S2.angle_deg(e.heading, target)])


func test_turn_is_not_instant() -> void:
	# Only meaningful when one tick of turning is clearly less than the requested 90 deg.
	_place(1, Vector3.FORWARD)
	var limit: float = S2.band_f(1, "turn_rate_deg_s") * DT
	if limit >= 80.0:
		return
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	w.step()
	assert_true(S2.angle_deg(e.heading, Vector3.RIGHT) > 90.0 - limit - 0.1, "no snap turn on the first tick")


func test_antiparallel_direction_turns_without_nan() -> void:
	# 180 deg flip: the rotation axis is undefined, a naive slerp yields NaN or never turns.
	_place(1, Vector3.RIGHT)
	var limit: float = S2.band_f(1, "turn_rate_deg_s") * DT
	w.submit(SimCommand.move(pid, Vector3.LEFT, 1.0))
	var prev: Vector3 = e.heading
	for i in int(ceil(180.0 / maxf(limit, 1e-6))) * 3 + 10:
		w.step()
		assert_true(e.heading.is_finite() and absf(e.heading.length() - 1.0) < 1e-4, "tick %d: heading finite and unit" % i)
		assert_true(e.position.is_finite() and e.velocity.is_finite(), "tick %d: position/velocity finite" % i)
		assert_true(S2.angle_deg(prev, e.heading) <= limit + 0.05, "tick %d: per-tick turn within limit" % i)
		prev = e.heading
	assert_true(S2.angle_deg(e.heading, Vector3.LEFT) < 1.0, "flip completes (off by %s deg)" % S2.angle_deg(e.heading, Vector3.LEFT))


func test_degenerate_move_directions_do_not_break_heading() -> void:
	_place(1, Vector3.RIGHT)
	var cases: Array[Vector3] = [Vector3.ZERO, Vector3(1e-9, 0.0, 0.0), Vector3(0.0, 1e-12, 0.0), Vector3.UP, Vector3.DOWN, Vector3(300.0, 0.0, 0.0)]
	for d in cases:
		w.submit(SimCommand.move(pid, d, 1.0))
		for i in 10:
			w.step()
			assert_true(e.heading.is_finite() and absf(e.heading.length() - 1.0) < 1e-4, "dir %s: heading finite and unit" % d)
			assert_true(e.position.is_finite() and e.velocity.is_finite(), "dir %s: state finite" % d)


# ======================================================== pitch, yaw, roll

func test_pitch_is_clamped_to_80_degrees_up_and_down() -> void:
	for b in range(1, _band_count() + 1):
		var rate: float = S2.band_f(b, "turn_rate_deg_s")
		var ticks: int = int(ceil((80.0 / maxf(rate, 1e-6) + 1.0) * 30.0))
		for sgn in [1.0, -1.0]:
			w = S2.make_world(3)
			_place(b, Vector3.RIGHT, Vector3(0.0, S2.LANE_Y, S2.LANE_Z))
			w.submit(SimCommand.move(pid, Vector3(0.0, sgn, 0.0), 1.0))
			var extreme: float = 0.0
			for i in ticks:
				w.step()
				extreme = maxf(extreme, absf(e.pitch_deg))
				assert_true(absf(e.pitch_deg) <= 80.0 + 0.01, "band %d: |pitch_deg| %s > 80" % [b, e.pitch_deg])
				assert_true(absf(e.heading.y) <= sin(deg_to_rad(80.0)) + 1e-4, "band %d: heading.y %s steeper than 80 deg" % [b, e.heading.y])
			assert_true(extreme >= 79.0, "band %d dir %s: straight up/down must reach the clamp, got %s" % [b, sgn, extreme])
			assert_true(signf(e.pitch_deg) == sgn, "band %d: pitch sign (nose up positive)" % b)


func test_yaw_pitch_fields_are_consistent_with_heading() -> void:
	_place(1, Vector3.FORWARD)
	var lcg := S2.Lcg.new(4242)
	for i in 300:
		if i % 10 == 0:
			var d := Vector3(lcg.unit() - 0.5, lcg.unit() - 0.5, lcg.unit() - 0.5)
			if d.length() < 0.05:
				d = Vector3.RIGHT
			w.submit(SimCommand.move(pid, d, 0.3 + 0.7 * lcg.unit()))
		w.step()
		assert_true(e.heading.is_finite() and absf(e.heading.length() - 1.0) < 1e-4, "tick %d: heading unit" % i)
		assert_true(absf(e.pitch_deg) <= 80.0 + 0.01, "tick %d: pitch %s within clamp" % [i, e.pitch_deg])
		var rebuilt: Vector3 = S2.dir_from_yaw_pitch(e.yaw_deg, e.pitch_deg)
		assert_true(rebuilt.distance_to(e.heading) < 2e-3, "tick %d: yaw_deg/pitch_deg %s/%s do not rebuild heading %s (got %s)" % [i, e.yaw_deg, e.pitch_deg, e.heading, rebuilt])


func test_pitch_sign_is_nose_up_positive() -> void:
	_place(1, Vector3.RIGHT, Vector3(0.0, S2.LANE_Y, S2.LANE_Z))
	w.submit(SimCommand.move(pid, Vector3(1.0, 1.0, 0.0), 1.0))
	S2.run(w, 60)
	assert_true(e.pitch_deg > 0.0, "heading with +Y component has positive pitch_deg (got %s)" % e.pitch_deg)


func test_sim_state_has_no_roll() -> void:
	_place(1)
	for p: Dictionary in e.get_property_list():
		assert_eq(String(p["name"]).to_lower().find("roll"), -1, "SimEntity has no roll state (found '%s')" % p["name"])


func test_per_tick_turn_never_exceeds_limit_under_random_steering() -> void:
	# Mouse jitter: a new random direction every few ticks, heading must stay within the per-tick limit throughout.
	_place(1, Vector3.FORWARD)
	var limit: float = S2.band_f(1, "turn_rate_deg_s") * DT
	var lcg := S2.Lcg.new(99)
	var prev: Vector3 = e.heading
	for i in 300:
		if i % 3 == 0:
			var d := Vector3(lcg.unit() - 0.5, lcg.unit() - 0.5, lcg.unit() - 0.5)
			if d.length() > 0.05:
				w.submit(SimCommand.move(pid, d, 1.0))
		w.step()
		assert_true(S2.angle_deg(prev, e.heading) <= limit + 0.05, "tick %d: heading jumped %s deg (limit %s)" % [i, S2.angle_deg(prev, e.heading), limit])
		prev = e.heading
