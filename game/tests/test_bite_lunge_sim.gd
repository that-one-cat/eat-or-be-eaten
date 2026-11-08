extends TestCase
## T1.6 bite lunge, behaviour end to end on a real SimWorld (the geometry cases are in test_bite_lunge_geometry.gd, the
## strength-0 hash identity in test_bite_lunge_identity.gd, the data in test_bite_lunge_data.gd).
##
## Measuring method (independent of the internal impulse model): the player idles at S3.ARENA, ONE press lands on a durable
## victim in reach, the run goes on until the player has settled (SETTLE ticks, speed < 0.01 m/s) and the TRAVEL (end minus start)
## is compared with lunge_distance_m x lunge_strength within TOL_FRAC = +-30 %. Direction: within 3 degrees of the heading.
##
## Assumptions the implementation could not know (see the test plan): swallows are not bites (no lunge); a press eaten by the
## cooldown never lunges; a cruising player (thrust held) is carried about the data distance as well (spec gap if this one
## fails, not necessarily a code bug); the hard-site (starfish) bite may or may not lunge (only "not backwards, never more
## than the data distance" is asserted).

const LS := preload("res://tests/lunge_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const F := preload("res://tests/food_support.gd")

const ANGLE_TOL_DEG: float = 3.0


## Asserts one rest lunge result `r` (LS.rest_lunge) travelled `expected` metres +-30 % forward along the heading.
func _expect_travel(r: Dictionary, expected: float, label: String) -> void:
	assert_eq(r["landed"], 1, "%s: exactly one bite landed" % label)
	assert_true(float(r["speed"]) < LS.SETTLED_SPEED_MPS, "%s: the player has settled (speed %.4f m/s)" % [label, float(r["speed"])])
	var travel: float = r["travel"]
	assert_true(absf(travel - expected) <= LS.TOL_FRAC * expected, "%s: travel %.4f m is within +-30%% of %.4f m" % [label, travel, expected])
	assert_true(float(r["angle_deg"]) <= ANGLE_TOL_DEG and float(r["along"]) > 0.0, "%s: forward along the heading (off by %.2f deg)" % [label, float(r["angle_deg"])])


# ======================================================================= distance, per band, from data

func test_a_landed_bite_moves_a_resting_player_by_the_shipped_band_distance_in_every_band() -> void:
	for b in range(1, 5):
		var w: SimWorld = LS.world(1.0)  # shipped lunge_distance_m
		var d: float = LS.shipped_band_m(w.content, b)
		if not is_finite(d) or d <= 0.0:
			assert_true(false, "band %d: the shipped lunge_distance_m must be a positive number (got %s)" % [b, d])
			continue
		_expect_travel(LS.rest_lunge(w, b), d, "band %d, shipped %.3f m" % [b, d])


func test_the_lunge_follows_the_heading_also_when_it_points_up_and_does_not_turn_the_fish() -> void:
	for b in [2, 4]:
		var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
		var r: Dictionary = LS.rest_lunge(w, b, LS.heading_pitched())
		_expect_travel(r, LS.BAND_M_TEST[b - 1], "band %d pitched" % b)
		var p: SimEntity = r["p"]
		assert_true(p.heading.angle_to(LS.heading_pitched()) < 1e-6, "band %d: the heading is untouched by the lunge" % b)


func test_each_band_reads_its_own_data_distance() -> void:
	for b in range(1, 5):
		var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
		_expect_travel(LS.rest_lunge(w, b), LS.BAND_M_TEST[b - 1], "band %d, data %.1f m" % [b, LS.BAND_M_TEST[b - 1]])


func test_only_the_band_of_the_player_counts() -> void:
	# band 1 and 3 carry 0 m, band 2 carries 3 m: a band-2 player lunges, a band-1 / band-3 / band-4 one does not
	var dist: Array[float] = [0.0, 3.0, 0.0, 0.0]
	for b in range(1, 5):
		var r: Dictionary = LS.rest_lunge(LS.world(1.0, dist), b)
		if b == 2:
			_expect_travel(r, 3.0, "band 2 with 3 m")
		else:
			assert_true(float(r["travel"]) < 1e-6, "band %d with 0 m does not move (moved %.6f m)" % [b, float(r["travel"])])


func test_travel_is_linear_in_the_data_distance() -> void:
	var small: Dictionary = LS.rest_lunge(LS.world(1.0, 1.5), 3)
	var big: Dictionary = LS.rest_lunge(LS.world(1.0, 3.0), 3)
	_expect_travel(small, 1.5, "band 3, 1.5 m")
	_expect_travel(big, 3.0, "band 3, 3.0 m")
	assert_true(float(small["travel"]) > 0.0 and float(big["travel"]) / float(small["travel"]) > 1.4 and float(big["travel"]) / float(small["travel"]) < 2.6, "doubling the data distance roughly doubles the travel")


func test_a_zero_band_distance_means_no_lunge() -> void:
	var r: Dictionary = LS.rest_lunge(LS.world(1.0, 0.0), 2)
	assert_eq(r["landed"], 1, "the bite lands")
	assert_true(float(r["travel"]) < 1e-6, "0 m: the player does not move (moved %.8f m)" % float(r["travel"]))


# ======================================================================= strength

func test_the_travel_scales_with_the_strength() -> void:
	for b in [2, 4]:
		var prev: float = -1.0
		for s: float in [0.25, 0.5, 1.0]:
			var r: Dictionary = LS.rest_lunge(LS.world(s, LS.BAND_M_TEST), b)
			_expect_travel(r, s * LS.BAND_M_TEST[b - 1], "band %d strength %.2f" % [b, s])
			assert_true(float(r["travel"]) > prev, "band %d: more strength, more travel" % b)
			prev = r["travel"]


func test_strength_zero_never_lunges_whatever_the_distance() -> void:
	for b in range(1, 5):
		var r: Dictionary = LS.rest_lunge(LS.world(0.0, LS.BAND_M_HUGE), b)
		assert_eq(r["landed"], 1, "band %d: the bite lands" % b)
		assert_eq(r["travel"], 0.0, "band %d: strength 0 does not move the player at all" % b)


func test_a_negative_strength_never_moves_the_player_backwards() -> void:
	var r: Dictionary = LS.rest_lunge(LS.world(-1.0, LS.BAND_M_TEST), 2)
	assert_true(float(r["along"]) > -1e-9, "no backward lunge (along %.6f)" % float(r["along"]))
	assert_true(float(r["travel"]) < 1e-9, "negative strength = off (moved %.6f m)" % float(r["travel"]))


# ======================================================================= what counts as a landed bite

func test_a_missed_bite_never_lunges() -> void:
	for b in range(1, 5):
		var r: Dictionary = LS.empty_water_bites(LS.world(1.0, LS.BAND_M_TEST), b)
		assert_true(int(r["misses"]) >= 3, "band %d: the held bite cues the jaw snap (%d misses)" % [b, int(r["misses"])])
		assert_eq(LS.max_step(r), 0.0, "band %d: the player never moves during misses" % b)
		assert_eq((r["p"] as SimEntity).velocity, Vector3.ZERO, "band %d: velocity stays zero" % b)


func test_a_victim_outside_the_cone_or_the_reach_is_a_miss_without_lunge() -> void:
	var cases: Dictionary = {"behind": -0.5, "far ahead": 12.0}  # body lengths in front of the mouth
	for name: String in cases.keys():
		var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
		var p: SimEntity = LS.player(w, 2)
		var v: SimEntity = LS.victim(w, p, float(cases[name]))
		var r: Dictionary = LS.run(w, p, v, 90, [{"tick": 0, "bite": true}, {"tick": 20, "bite": true}], false)
		assert_eq(r["landed"], 0, "%s: no bite lands" % name)
		assert_eq(LS.max_step(r), 0.0, "%s: the player does not move" % name)


func test_a_press_that_waits_in_the_buffer_lunges_when_it_lands_not_when_it_is_pressed() -> void:
	var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	var p: SimEntity = LS.player(w, 2)
	var v: SimEntity = LS.victim(w, p, -0.5)  # behind the mouth: outside the cone
	var ahead: Vector3 = p.position + p.heading * (p.length_m * 0.5)
	var behind: Vector3 = v.position
	var start: Vector3 = p.position
	var pending_exact: bool = true
	var evs: Array[SimEvent] = []
	w.submit(SimCommand.bite(p.id, -1))
	for i in LS.SETTLE:
		v.position = ahead if i >= 4 else behind
		v.velocity = Vector3.ZERO
		w.step()
		evs.append_array(w.events_since(w.tick - 1))
		v.position = ahead if i >= 4 else behind
		v.hp = v.max_hp
		if i < 3 and p.position != start:
			pending_exact = false
	var landed: Array[SimEvent] = TS.bites_by(evs, p.id, v.id)
	assert_eq(landed.size(), 1, "the buffered press lands once the victim is in the cone")
	assert_true(pending_exact, "no movement while the press is still waiting for its target")
	var travel: float = p.position.distance_to(start)
	assert_true(absf(travel - LS.BAND_M_TEST[1]) <= LS.TOL_FRAC * LS.BAND_M_TEST[1], "then the lunge covers ~%.1f m (got %.3f)" % [LS.BAND_M_TEST[1], travel])


func test_a_press_eaten_by_the_cooldown_does_not_lunge_again() -> void:
	# bite cooldown 0.5 s > the 0.2 s press buffer: the second press at tick 3 is dropped, so exactly one lunge
	var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	var p: SimEntity = LS.player(w, 2)
	var v: SimEntity = LS.victim(w, p)
	var r: Dictionary = LS.run(w, p, v, LS.SETTLE, [{"tick": 0, "bite": true}, {"tick": 3, "bite": true}])
	r.merge(LS.motion(r, p.heading))
	_expect_travel(r, LS.BAND_M_TEST[1], "two presses inside one cooldown")


func test_every_landed_bite_lunges_after_the_player_has_settled() -> void:
	var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	var p: SimEntity = LS.player(w, 2)
	var v: SimEntity = LS.victim(w, p)
	var gap: int = 240
	var r: Dictionary = LS.run(w, p, v, gap * 3, [{"tick": 0, "bite": true}, {"tick": gap, "bite": true}, {"tick": 2 * gap, "bite": true}])
	assert_eq(r["landed"], 3, "three bites landed")
	var d: float = LS.BAND_M_TEST[1]
	for k in 3:
		var at: Vector3 = (r["pos"] as Array[Vector3])[gap * (k + 1) - 1]
		var travelled: float = at.distance_to(r["start"])
		var want: float = d * float(k + 1)
		assert_true(absf(travelled - want) <= LS.TOL_FRAC * want, "after bite %d the player has moved ~%.1f m (got %.3f)" % [k + 1, want, travelled])


func test_a_swallow_is_not_a_bite_and_does_not_lunge() -> void:
	for pressing: bool in [false, true]:
		var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
		var p: SimEntity = LS.player(w, 3)
		var snack_pos: Vector3 = p.position + p.heading * (p.length_m * 0.3)
		var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", snack_pos, p.length_m * 0.05, -p.heading)
		var evs: Array[SimEvent] = []
		for i in 60:
			if pressing and i == 0:
				w.submit(SimCommand.bite(p.id, -1))
			snack.position = snack_pos
			w.step()
			evs.append_array(w.events_since(w.tick - 1))
			p.hp = p.max_hp
		assert_eq(S3.count_between(w, SimEvent.Type.EATEN, p.id, snack.id), 1, "test setup (pressing %s): the snack is swallowed" % pressing)
		assert_true(p.position.distance_to(S3.ARENA) < 1e-9, "pressing %s: a swallow does not lunge (moved %.6f m)" % [pressing, p.position.distance_to(S3.ARENA)])


func test_the_bite_itself_is_unchanged_by_the_lunge() -> void:
	var off: Dictionary = LS.rest_lunge(LS.world(0.0, LS.BAND_M_TEST), 3)
	var on: Dictionary = LS.rest_lunge(LS.world(1.0, LS.BAND_M_TEST), 3)
	var bo: Array[SimEvent] = TS.bites_by(off["evs"], (off["p"] as SimEntity).id)
	var bn: Array[SimEvent] = TS.bites_by(on["evs"], (on["p"] as SimEntity).id)
	assert_eq(bn.size(), bo.size(), "same number of bites")
	if bn.size() == 1 and bo.size() == 1:
		assert_eq(bn[0].tick, bo[0].tick, "same tick")
		assert_eq(bn[0].value, bo[0].value, "same damage")
		assert_eq(bn[0].entity_id, bo[0].entity_id, "same victim")


# ======================================================================= NPC bites never lunge

func _npc_trace(strength: float, scenario: String) -> Dictionary:
	var w: SimWorld = LS.world(strength, LS.BAND_M_HUGE, {}, true)
	var p: SimEntity = TS.player(w, 0.5)
	var c: Vector3 = S3.ARENA
	if scenario == "hunt":
		p.position += Vector3(40.0, 0.0, 0.0)
		S3.npc_at(w, &"shark", c, 3.0, Vector3.RIGHT)
		for k in 4:
			S3.npc_at(w, &"small_reef_fish", c + Vector3(2.5 + 0.4 * float(k), 0.0, 0.6 * float(k) - 1.0), 0.9, Vector3.RIGHT)
	else:  # a shark right next to the idle small player: the shark bites the PLAYER
		S3.npc_at(w, &"shark", c + Vector3(2.0, 0.0, 0.0), 3.0, Vector3.LEFT)
	var evs: Array[SimEvent] = S3.step_n(w, 600)
	var npc_bites: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id != p.id:
			npc_bites += 1
	return {"trace": TS.trace_with(w, evs), "npc_bites": npc_bites}


func test_npc_bites_never_lunge() -> void:
	for scenario: String in ["hunt", "on_player"]:
		var off: Dictionary = _npc_trace(0.0, scenario)
		var on: Dictionary = _npc_trace(1.0, scenario)
		assert_true(int(off["npc_bites"]) > 0, "%s: test setup, NPCs bite (%d)" % [scenario, int(off["npc_bites"])])
		assert_eq(on["trace"], off["trace"], "%s: every entity moves exactly as with the lunge off (NPC bites carry no lunge)" % scenario)


func test_a_world_full_of_npc_bites_is_the_same_with_the_lunge_on() -> void:
	var off: Dictionary = AS.real_world_no_player_bites({"rules": {LS.KEY_STRENGTH: 0.0}}, 4242, 900)
	var on: Dictionary = AS.real_world_no_player_bites({"rules": {LS.KEY_STRENGTH: 1.0}}, 4242, 900)
	assert_true(int(off["npc_bites"]) > 0, "test setup: NPCs bite in the shipped world")
	assert_eq(on["trace"], off["trace"], "shipped spawners + schools, no player bites: identical trace at strength 1")
	assert_eq(on["hash"], off["hash"], "...and identical state_hash")


# ======================================================================= swimming player: cruise, boost, cap, stamina

func test_a_cruising_player_is_carried_about_the_data_distance_too() -> void:
	# The Director bites while swimming: thrust 1 held, ONE press. Extra travel vs the same run at strength 0.
	var d: float = 1.5
	var x: Dictionary = LS.cruise_extra(1.0, d)
	assert_eq((x["on"] as Dictionary)["landed"], 1, "test setup: the cruising player lands its bite")
	var forward: float = x["forward"]
	assert_true(forward >= 0.5 * d and forward <= (1.0 + LS.TOL_FRAC) * d, "extra travel %.3f m is within [0.5, 1.3] x %.1f m (SPEC-SENSITIVE: a lunge that thrust/accel eats within a few ticks fails here)" % [forward, d])
	assert_true(float(x["lateral"]) < 0.05 * d, "the extra travel is straight ahead (lateral %.4f m)" % float(x["lateral"]))


func test_the_speed_never_exceeds_max_speed_times_the_boost_multiplier_and_comes_back() -> void:
	var cap: float = S2.band_speed(2) * float(S2.boost()["speed_mult"])
	# at rest, absurd distance
	var rest: Dictionary = LS.rest_lunge(LS.world(1.0, 50.0), 2)
	var peak: float = 0.0
	for vv: Vector3 in (rest["vel"] as Array[Vector3]):
		peak = maxf(peak, vv.length())
	assert_true(peak <= cap * (1.0 + 1e-6), "rest lunge of 50 m: peak speed %.3f <= cap %.3f (band max x boost mult)" % [peak, cap])
	assert_true(float(rest["travel"]) > 1.0, "...the lunge still happens (travel %.2f m)" % float(rest["travel"]))
	# cruising and boosting
	for boost: bool in [false, true]:
		var r: Dictionary = LS.cruise(1.0, 20.0, 45, 100, boost)
		var peak2: float = 0.0
		for vv2: Vector3 in (r["vel"] as Array[Vector3]):
			peak2 = maxf(peak2, vv2.length())
		assert_true(peak2 <= cap * (1.0 + 1e-6), "cruise (boost %s) with 20 m: peak speed %.3f <= cap %.3f" % [boost, peak2, cap])
	# transient: back to the normal max a few seconds after the lunge
	var long_run: Dictionary = LS.cruise(1.0, 3.0, 25, 160)
	var final_speed: float = (long_run["p"] as SimEntity).velocity.length()
	assert_true(absf(final_speed - S2.band_speed(2)) <= 0.01 * S2.band_speed(2), "the speed is back at the normal max %.2f after the lunge (got %.4f)" % [S2.band_speed(2), final_speed])


func test_the_lunge_costs_no_stamina_and_does_not_touch_the_boost_state() -> void:
	var on: Dictionary = LS.cruise(1.0, 3.0, 45, 100, true)
	var off: Dictionary = LS.cruise(0.0, 3.0, 45, 100, true)
	assert_eq(on["landed"], 1, "test setup: the bite lands")
	var so: Array[float] = on["stamina"]
	var sf: Array[float] = off["stamina"]
	var bo: Array[bool] = on["boosting"]
	var bf: Array[bool] = off["boosting"]
	var worst: float = 0.0
	var flag_diffs: int = 0
	for i in so.size():
		worst = maxf(worst, absf(so[i] - sf[i]))
		if bo[i] != bf[i]:
			flag_diffs += 1
	assert_true(worst < 1e-9, "stamina identical tick by tick with and without the lunge (max difference %.9f)" % worst)
	assert_eq(flag_diffs, 0, "the boosting flag identical tick by tick")


# ======================================================================= death

func test_a_death_cancels_the_lunge() -> void:
	var on: Dictionary = LS.death_after_bite(1.0, LS.BAND_M_TEST)
	var off: Dictionary = LS.death_after_bite(0.0, LS.BAND_M_TEST)
	assert_true(bool(on["died"]) and bool(on["respawned"]), "test setup: the player died and respawned")
	if not (bool(on["died"]) and bool(on["respawned"]) and bool(off["respawned"])):
		return
	assert_eq(on["vel_a"], Vector3.ZERO, "the respawned player starts at rest")
	assert_true((on["pos_b"] as Vector3).distance_to(on["pos_a"]) < 1e-6, "no leftover lunge drags the respawned player (moved %.6f m)" % (on["pos_b"] as Vector3).distance_to(on["pos_a"]))
	assert_true((on["pos_a"] as Vector3).distance_to(off["pos_a"]) < 1e-6, "it respawns where a run without the lunge respawns")


# ======================================================================= the God test kit: tune

func _tuned_second_bite(strength: float, band_m: Variant, lines_at_41: Array, first_lines: Array = []) -> Dictionary:
	# first press at tick 0 (lunge off or on by `strength`), console lines + second press at tick 41
	var w: SimWorld = LS.world(strength, band_m)
	var p: SimEntity = LS.player(w, 2)
	var v: SimEntity = LS.victim(w, p)
	var script: Array = []
	if not first_lines.is_empty():
		script.append({"tick": 0, "lines": first_lines})
	script.append({"tick": 0, "bite": true})
	if not lines_at_41.is_empty():
		script.append({"tick": 41, "lines": lines_at_41})
	script.append({"tick": 41, "bite": true})
	return LS.run(w, p, v, LS.SETTLE, script)


func test_tune_lunge_strength_changes_the_sim_on_the_next_tick() -> void:
	var id: String = TS.id_for("rules", LS.KEY_STRENGTH)
	assert_false(id.is_empty(), "registry row for lunge_strength")
	var r: Dictionary = _tuned_second_bite(0.0, LS.BAND_M_TEST, ["tune %s 1" % id])
	assert_eq(r["landed"], 2, "both presses land")
	var pos: Array[Vector3] = r["pos"]
	assert_true(pos[40].distance_to(r["start"]) < 1e-9, "the first bite (strength 0) did not move the player")
	var travel: float = (r["end"] as Vector3).distance_to(r["start"])
	var d: float = LS.BAND_M_TEST[1]
	assert_true(absf(travel - d) <= LS.TOL_FRAC * d, "`tune lunge_strength 1` made the very next landed bite lunge ~%.1f m (got %.3f)" % [d, travel])
	var ctrl: Dictionary = _tuned_second_bite(0.0, LS.BAND_M_TEST, [])
	assert_true((ctrl["end"] as Vector3).distance_to(ctrl["start"]) < 1e-9, "control without the tune line: no lunge at all")


func test_tune_reset_and_tune_zero_turn_the_lunge_off_again() -> void:
	var id: String = TS.id_for("rules", LS.KEY_STRENGTH)
	var d: float = LS.BAND_M_TEST[1]
	for off_line: String in ["tune reset", "tune %s 0" % id]:
		var w: SimWorld = LS.world(0.0, LS.BAND_M_TEST)
		var p: SimEntity = LS.player(w, 2)
		var v: SimEntity = LS.victim(w, p)
		var script: Array = [{"tick": 0, "lines": ["tune %s 1" % id]}, {"tick": 0, "bite": true}, {"tick": 300, "lines": [off_line]}, {"tick": 301, "bite": true}]
		var r: Dictionary = LS.run(w, p, v, 600, script)
		assert_eq(r["landed"], 2, "%s: both presses land" % off_line)
		var pos: Array[Vector3] = r["pos"]
		var first: float = pos[299].distance_to(r["start"])
		assert_true(absf(first - d) <= LS.TOL_FRAC * d, "%s: the first bite lunged ~%.1f m (got %.3f)" % [off_line, d, first])
		assert_true(pos[599].distance_to(pos[299]) < 1e-9, "%s: after it the second bite does not move the player (moved %.6f m)" % [off_line, pos[599].distance_to(pos[299])])


func test_tuned_strength_equals_the_same_edit_in_the_data() -> void:
	var id: String = TS.id_for("rules", LS.KEY_STRENGTH)
	var tuned: Dictionary = LS.rest_lunge(LS.world(0.0, LS.BAND_M_TEST), 3, LS.HEADING_YAW, ["tune %s 0.5" % id])
	var edited: Dictionary = LS.rest_lunge(LS.world(0.5, LS.BAND_M_TEST), 3)
	assert_true(float(edited["travel"]) > 0.0, "test setup: the data edit lunges")
	assert_eq(TS.trace(tuned["w"]), TS.trace(edited["w"]), "`tune lunge_strength 0.5` = strength 0.5 in the data (entity state, whole trajectory)")


func test_tuned_distance_applies_to_every_band_and_equals_the_data_edit() -> void:
	var id: String = TS.id_for("band", LS.KEY_BAND_M)
	assert_false(id.is_empty(), "registry row for lunge_distance_m")
	for b in range(1, 5):
		var tuned: Dictionary = LS.rest_lunge(LS.world(1.0, 3.0), b, LS.HEADING_YAW, ["tune %s 1.5" % id])
		var edited: Dictionary = LS.rest_lunge(LS.world(1.0, 1.5), b)
		_expect_travel(tuned, 1.5, "band %d tuned to 1.5 m" % b)
		assert_eq(TS.trace(tuned["w"]), TS.trace(edited["w"]), "band %d: `tune lunge_distance_m 1.5` = 1.5 m in the data" % b)


func test_a_slider_move_applies_while_a_lunge_is_not_running_and_reads_the_current_value_each_bite() -> void:
	# two bites, the distance changed between them: each lunge uses the value of ITS tick
	var id: String = TS.id_for("band", LS.KEY_BAND_M)
	var w: SimWorld = LS.world(1.0, 1.5)
	var p: SimEntity = LS.player(w, 2)
	var v: SimEntity = LS.victim(w, p)
	var gap: int = 240
	var r: Dictionary = LS.run(w, p, v, 2 * gap, [{"tick": 0, "bite": true}, {"tick": gap - 5, "lines": ["tune %s 3.0" % id]}, {"tick": gap, "bite": true}])
	var pos: Array[Vector3] = r["pos"]
	var first: float = pos[gap - 6].distance_to(r["start"])
	var second: float = pos[2 * gap - 1].distance_to(pos[gap - 6])
	assert_true(absf(first - 1.5) <= LS.TOL_FRAC * 1.5, "first lunge ~1.5 m (got %.3f)" % first)
	assert_true(absf(second - 3.0) <= LS.TOL_FRAC * 3.0, "second lunge ~3.0 m after the slider move (got %.3f)" % second)


# ======================================================================= determinism, Bite-Dash, hard sites

func test_two_runs_with_the_lunge_on_are_identical_and_differ_from_the_lunge_off() -> void:
	var a: int = LS.chase_hash(LS.world(1.0, LS.BAND_M_TEST), 2)
	var b: int = LS.chase_hash(LS.world(1.0, LS.BAND_M_TEST), 2)
	assert_eq(a, b, "same inputs, same state_hash with the lunge on")
	assert_ne(a, LS.BASELINE_HASHES["chase_b2"], "the lunge changes the run (ten landed bites)")


func test_a_bite_dash_that_ends_in_its_bite_stays_finite_and_deterministic_with_the_lunge_on() -> void:
	var h1: int = LS.dash_bite_hash(LS.world(1.0, LS.BAND_M_TEST, {}, true))
	var h2: int = LS.dash_bite_hash(LS.world(1.0, LS.BAND_M_TEST, {}, true))
	assert_eq(h1, h2, "two runs agree")
	var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST, {}, true)
	LS.dash_bite_hash(w)
	var p: SimEntity = w.players()[0]
	assert_true(p.position.is_finite() and p.velocity.is_finite(), "no NaN / INF after dash + lunge")
	assert_true(absf(p.position.x) < 290.0 and p.position.y < 0.0, "the player is still inside the map")


func test_a_hard_site_bite_lunges_at_most_the_data_distance_and_never_backwards() -> void:
	# food-site bites are implementation-defined (task: "lunges only if you decide so"); both choices pass this test
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"length": 1.2})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var id: String = TS.id_for("rules", LS.KEY_STRENGTH)
	TS.tune(TS.commands(), w, p.id, "tune %s 1" % id)
	var start: Vector3 = p.position
	var heading: Vector3 = p.heading
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = F.run(w, LS.SETTLE)
	assert_true(F.named(evs, F.EV_BITTEN).size() + F.named(evs, F.EV_EATEN).size() >= 1, "test setup: the site was bitten")
	var along: float = (p.position - start).dot(heading)
	var d: float = LS.shipped_band_m(w.content, p.band)
	assert_true(along >= -1e-6, "not backwards (along %.4f)" % along)
	assert_true(along <= d * (1.0 + LS.TOL_FRAC) + 1e-6, "never more than the band distance %.3f m (got %.4f m)" % [d, along])
