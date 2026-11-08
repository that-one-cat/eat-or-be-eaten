extends TestCase
## T1.5 aim assist (soft lock for PLAYER bites, default OFF), sim half, end to end on real SimWorld runs:
##  - identity: with `aim_assist_strength` 0 (the shipped value) every pinned state_hash / the bot-relevant baselines are
##    bit-identical to the pre-T1.5 code, whatever the other three aim keys say; NPC bites and explicit-target bites never
##    change, with the assist on or off.
##  - behaviour: a prey swimming ACROSS the aim outside the strict bite cone is missed with the assist off and bitten with it
##    on; strength interpolates (the set of angles that land only grows with the strength); the max-distance cap, the reach,
##    the swallowable / inactive skip rules hold; stable tie-break by entity id; stickiness stops the lock flickering.
##  - live tuning: `tune aim_assist_strength 1` changes the sim on the NEXT tick; every key behaves the same through the
##    console as through an edit of the data.
## Geometry and the name table live in aim_assist_support.gd. Tests compare through events and TS.trace (entity state +
## events); only the identity tests use state_hash.

const AS := preload("res://tests/aim_assist_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const SS := preload("res://tests/species_stats_support.gd")

## Angles (deg off the heading) of the strength sweep; the strict cone half-angle is 60 in the shipped data.
const SWEEP_ANGLES: Array[float] = [0.0, 30.0, 55.0, 65.0, 75.0, -75.0, 90.0, 120.0]
const SWEEP_STRENGTHS: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
## Centre distance of the lone victim in the sweeps: well inside the strict reach (0.75 m + victim radius 0.75 m = 1.5 m).
const CENTRE_M: float = 0.95


# ======================================================================= helpers

func _wild_zero() -> Dictionary:
	return AS.opts(0.0, {AS.KEY_CONE: 170.0, AS.KEY_MAX_DIST: AS.CAP_HUGE, AS.KEY_STICKY: 1.0})


func _db_with_rules(edit: Dictionary) -> ContentDB:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for k: Variant in edit.keys():
		db.rules()[k] = edit[k]
	return db


## True when a bite pressed at a lone durable victim `centre_m` away (centre distance) and `deg` off the heading lands.
func _lands(o: Dictionary, deg: float, centre_m: float = CENTRE_M, lines: Array = []) -> bool:
	return AS.bite_at(o, deg, centre_m, lines) > 0


func _same_ids(ids: Array[int]) -> bool:
	for id: int in ids:
		if id != ids[0]:
			return false
	return true


# ======================================================================= identity at strength 0

func test_strength_zero_keeps_the_pinned_scenario_hashes() -> void:
	var got: Dictionary = AS.baseline_hashes()
	for k: String in AS.BASELINE_HASHES.keys():
		assert_eq(got[k], AS.BASELINE_HASHES[k], "pre-T1.5 state_hash of the %s scenario (strength 0, the other aim keys at extremes)" % k)


func test_the_shipped_data_gives_the_pinned_scenario_hashes() -> void:
	# no rules override at all = the numbers the game ships with (strength must be 0.0 there)
	var got: Dictionary = {
		"crossing": AS.crossing({})["hash"], "stacked": AS.stacked({})["hash"], "sticky": AS.sticky({})["hash"],
		"crowd": AS.crowd({})["hash"], "explicit": AS.explicit({})["hash"],
	}
	for k: String in AS.BASELINE_HASHES.keys():
		assert_eq(got[k], AS.BASELINE_HASHES[k], "shipped data, %s scenario" % k)


func test_strength_zero_keeps_the_five_bite_baselines_of_the_tuning_lab() -> void:
	var o: Dictionary = _wild_zero()
	var got: Dictionary = {
		"bite_composite": TS.composite(o, [])["hash"], "held_bites": TS.held_bites(o, [])["hash"],
		"held_misses": TS.held_misses(o, [])["hash"], "press_enter_6": TS.press_then_enter(o, [], 6)["hash"],
		"press_enter_9": TS.press_then_enter(o, [], 9)["hash"],
	}
	for k: String in TS.BASELINE_HASHES.keys():
		assert_eq(got[k], TS.BASELINE_HASHES[k], "pre-T1.3 state_hash of %s with the aim keys present and strength 0" % k)


func test_strength_zero_keeps_the_lane_and_shipped_spawner_baselines() -> void:
	var db: ContentDB = _db_with_rules({AS.KEY_STRENGTH: 0.0, AS.KEY_CONE: 170.0, AS.KEY_MAX_DIST: AS.CAP_HUGE, AS.KEY_STICKY: 1.0})
	for b in range(1, 5):
		assert_eq(TS.lane_run(db, b)["hash"], SS.BASELINE_HASHES["player_band_%d" % b], "band %d scripted player hash" % b)
	assert_eq(SS.hash_real_world(db, 4242, 900, 0), SS.BASELINE_HASHES["s3_real_4242_900"], "shipped spawners + schools + bites, 900 ticks")


func _scenario_hash(name: String, o: Dictionary) -> int:
	match name:
		"crossing":
			return AS.crossing(o)["hash"]
		"stacked":
			return AS.stacked(o)["hash"]
		"sticky":
			return AS.sticky(o)["hash"]
	return AS.crowd(o)["hash"]


func test_inert_keys_change_nothing_at_strength_zero() -> void:
	var a: Dictionary = AS.opts(0.0, {AS.KEY_CONE: 0.0, AS.KEY_MAX_DIST: AS.CAP_TINY, AS.KEY_STICKY: 0.0})
	var b: Dictionary = AS.opts(0.0, {AS.KEY_CONE: 180.0, AS.KEY_MAX_DIST: AS.CAP_HUGE, AS.KEY_STICKY: 1.0})
	for name: String in ["crossing", "stacked", "sticky", "crowd"]:
		assert_eq(_scenario_hash(name, a), _scenario_hash(name, b), "%s: cone / cap / stickiness do not matter while the strength is 0" % name)


func test_a_missing_strength_key_means_off() -> void:
	# old data without the keys (the rule falls back to 0): same trajectory as the shipped strength 0
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for k: String in AS.KEYS:
		db.rules().erase(k)
	assert_eq(SS.hash_real_world(db, 4242, 900, 0), SS.BASELINE_HASHES["s3_real_4242_900"], "world without the aim keys behaves like today")


func test_negative_strength_is_off() -> void:
	var neg: Dictionary = AS.crossing(AS.opts(-1.0))
	assert_eq(neg["bites"], 0, "no assisted bite at a negative strength")
	assert_eq(neg["hash"], AS.crossing(AS.opts(0.0))["hash"], "strength -1 = strength 0 (early-out on <= 0)")


func test_the_data_driven_assist_creates_no_debug_state() -> void:
	# the strength is plain data: turning it on in the rules must not need the God layer
	var rg: Dictionary = AS.crossing(AS.opts(1.0))
	assert_null((rg["w"] as SimWorld).debug, "no SimDebug state is created by a rules-driven assist")


# ======================================================================= NPC and explicit-target bites never change

func test_npc_bites_ignore_the_assist() -> void:
	var off: Dictionary = AS.npc_hunt(_wild_zero())
	var on: Dictionary = AS.npc_hunt(AS.opts(1.0, {AS.KEY_CONE: 170.0, AS.KEY_STICKY: 1.0}))
	assert_true(int(off["npc_bites"]) > 0, "guard: the shark actually bites in this scenario (got %d)" % int(off["npc_bites"]))
	assert_eq(on["trace"], off["trace"], "shark + prey, player far away and not biting: identical entity + event trace with the assist on")
	assert_eq(on["npc_bites"], off["npc_bites"], "same NPC bite count")


func test_npc_bites_in_a_shipped_spawner_world_ignore_the_assist() -> void:
	var off: Dictionary = AS.real_world_no_player_bites(_wild_zero())
	var on: Dictionary = AS.real_world_no_player_bites(AS.opts(1.0, {AS.KEY_CONE: 170.0, AS.KEY_STICKY: 1.0}))
	assert_true(int(off["npc_bites"]) > 0, "guard: NPCs bite in the 900-tick shipped world (got %d)" % int(off["npc_bites"]))
	assert_eq(on["trace"], off["trace"], "shipped spawners, player never presses BITE: the assist changes nothing")


func test_explicit_target_bites_are_not_assisted() -> void:
	var off: Dictionary = AS.explicit(_wild_zero())
	var on: Dictionary = AS.explicit(AS.opts(1.0, {AS.KEY_CONE: 170.0, AS.KEY_STICKY: 1.0}))
	for r: Dictionary in [off, on]:
		var p: SimEntity = r["p"]
		var evs: Array[SimEvent] = r["evs"]
		assert_eq(AS.bitten_by(evs, p.id, (r["a"] as SimEntity).id).size(), 0, "explicit target 75 deg off the heading is a miss (strict cone)")
		assert_eq(AS.bitten_by(evs, p.id, (r["c"] as SimEntity).id).size(), 0, "explicit target -70 deg off the heading is a miss")
		assert_eq(AS.bitten_by(evs, p.id, (r["b"] as SimEntity).id).size(), 1, "explicit target 20 deg off the heading lands once")
	assert_eq(on["trace"], off["trace"], "explicit-target presses give the same trace with the assist on and off")


# ======================================================================= the end-to-end behaviour

func test_crossing_prey_outside_the_strict_cone_is_missed_with_the_assist_off() -> void:
	var r: Dictionary = AS.crossing(AS.opts(0.0))
	assert_true(float(r["min_angle"]) > 62.0, "scenario guard: the prey stays outside the 60 deg cone for the whole press window (min %.1f)" % float(r["min_angle"]))
	assert_eq(r["bites"], 0, "strength 0: the strict cone misses the crossing prey")
	assert_true(int(r["misses"]) >= 1, "strength 0: the miss cue fires (a real miss, not a missing press)")


func test_crossing_prey_outside_the_strict_cone_is_bitten_with_the_assist_on() -> void:
	var r: Dictionary = AS.crossing(AS.opts(1.0))
	assert_true(float(r["min_angle"]) > 62.0, "scenario guard: still outside the strict cone (min %.1f)" % float(r["min_angle"]))
	assert_eq(r["bites"], 1, "strength 1: exactly one bite lands on the crossing prey")
	assert_true(int(r["first_bite_tick"]) >= 0 and int(r["first_bite_tick"]) <= 3, "the assisted bite lands at once, not at the end of the buffer (tick %d)" % int(r["first_bite_tick"]))
	assert_eq(r["misses"], 0, "no miss cue for an assisted hit")


func test_the_assisted_bite_changes_the_run_and_it_is_deterministic() -> void:
	var off: Dictionary = AS.crossing(AS.opts(0.0))
	var a: Dictionary = AS.crossing(AS.opts(1.0))
	var b: Dictionary = AS.crossing(AS.opts(1.0))
	assert_eq(a["hash"], b["hash"], "same world + same assist = same state_hash")
	assert_eq(a["trace"], b["trace"], "same world + same assist = same trace")
	assert_ne(a["hash"], off["hash"], "assist on and a lock taken: the state is not the strength-0 state")
	assert_ne(a["trace"], off["trace"], "the bite changed the entities")


func test_shipped_inert_values_plus_strength_one_assist_a_crossing_prey() -> void:
	# the Director's workflow: only the strength is turned up (tune aim_assist_strength 1); cone / cap / stickiness are the shipped ones
	var r: Dictionary = AS.crossing({}, ["tune aim_assist_strength 1"])
	assert_true(float(r["min_angle"]) > 62.0, "scenario guard (min %.1f)" % float(r["min_angle"]))
	assert_eq(r["bites"], 1, "shipped cone / distance / stickiness + strength 1 bite a prey 65-73 deg off the aim, 1 m away")


func test_tune_console_changes_the_sim_on_the_next_tick() -> void:
	var w: SimWorld = AS.world({})
	var p: SimEntity = TS.player(w)
	var pos: Vector3 = p.position + p.heading * 0.3 + AS.side_of(p) * 1.0
	var v: SimEntity = TS.victim(w, p, pos)
	var cmds: GodCommands = TS.commands()
	# 1. assist off (shipped): the press misses
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 10, {v.id: pos}, [v.id, p.id])
	assert_eq(AS.bitten_by(evs, p.id, v.id).size(), 0, "before the tune: no bite on the crossing prey")
	assert_true(TS.misses_of(evs, p.id) >= 1, "before the tune: the miss cue fired")
	# 2. tune, press again: the very next tick lands
	var ans: String = TS.tune(cmds, w, p.id, "tune aim_assist_strength 1")
	assert_false(ans.to_lower().contains("unknown") or ans.to_lower().contains("error") or ans.to_lower().contains("usage"), "the console accepts the row (answer: %s)" % ans)
	w.submit(SimCommand.bite(p.id, -1))
	evs = S3.step_n(w, 1, {v.id: pos}, [v.id, p.id])
	assert_eq(AS.bitten_by(evs, p.id, v.id).size(), 1, "tune aim_assist_strength 1: the bite lands in the next tick")
	# 3. reset: the next press (after the cooldown) misses again
	S3.step_n(w, 20, {v.id: pos}, [v.id, p.id])
	TS.tune(cmds, w, p.id, "tune reset aim_assist_strength")
	w.submit(SimCommand.bite(p.id, -1))
	evs = S3.step_n(w, 8, {v.id: pos}, [v.id, p.id])
	assert_eq(AS.bitten_by(evs, p.id, v.id).size(), 0, "after `tune reset aim_assist_strength`: strict cone again")
	assert_true(TS.misses_of(evs, p.id) >= 1, "...and the miss cue is back")


func test_tuning_one_key_through_the_console_equals_editing_it_in_the_data() -> void:
	# strength 1 + one key moved to a value far from the explicit default; the console run and the data-edit run must follow
	# the same trajectory (the key is read through _rule_f and re-cached on the next tick)
	var wanted: Dictionary = {AS.KEY_STRENGTH: 0.5, AS.KEY_CONE: 20.0, AS.KEY_MAX_DIST: 0.3, AS.KEY_STICKY: 0.0}
	for key: String in wanted.keys():
		var row: Dictionary = TS.entry_for("rules", key)
		assert_false(row.is_empty(), "registry row for %s" % key)
		if row.is_empty():
			continue
		var v: float = snappedf(clampf(float(wanted[key]), float(row["min"]), float(row["max"])), 0.000001)
		var line: String = AS.tune_line(key, v)
		var via_console_x: Dictionary = AS.crossing(AS.opts(1.0), [line])
		var via_data_x: Dictionary = AS.crossing(AS.opts(1.0, {key: v}))
		assert_eq(via_console_x["trace"], via_data_x["trace"], "%s via `%s` equals the data edit (crossing prey)" % [key, line])
		var via_console_s: Dictionary = AS.sticky(AS.opts(1.0), 0.05, 150, [line])
		var via_data_s: Dictionary = AS.sticky(AS.opts(1.0, {key: v}))
		assert_eq(via_console_s["trace"], via_data_s["trace"], "%s via `%s` equals the data edit (two fish)" % [key, line])


# ======================================================================= strength, reach, cap

func test_strength_sweep_lands_a_growing_set_of_angles() -> void:
	var landed: Dictionary = {}  # strength -> Array[bool] per angle
	for s: float in SWEEP_STRENGTHS:
		var row: Array[bool] = []
		for deg: float in SWEEP_ANGLES:
			row.append(_lands(AS.opts(s), deg))
		landed[s] = row
	var strict: Array[bool] = landed[0.0]
	for i in SWEEP_ANGLES.size():
		assert_eq(strict[i], absf(SWEEP_ANGLES[i]) <= 60.0, "strength 0 = the strict 60 deg cone (%.0f deg)" % SWEEP_ANGLES[i])
	for k in range(1, SWEEP_STRENGTHS.size()):
		var lo: Array[bool] = landed[SWEEP_STRENGTHS[k - 1]]
		var hi: Array[bool] = landed[SWEEP_STRENGTHS[k]]
		for i in SWEEP_ANGLES.size():
			if lo[i]:
				assert_true(hi[i], "a bite that lands at strength %.2f still lands at %.2f (%.0f deg)" % [SWEEP_STRENGTHS[k - 1], SWEEP_STRENGTHS[k], SWEEP_ANGLES[i]])
	var full: Array[bool] = landed[1.0]
	assert_true(full[SWEEP_ANGLES.find(65.0)] and full[SWEEP_ANGLES.find(75.0)] and full[SWEEP_ANGLES.find(-75.0)], "strength 1 with a 90 deg extra cone lands at +-65..75 deg, both sides")
	assert_ne(landed[0.25], landed[1.0], "strength interpolates: 0.25 is not already the full lock (angles landed differ from strength 1)")
	assert_ne(landed[0.25], landed[0.0], "...and not yet the strict cone either")


func test_the_assist_never_removes_a_bite_the_strict_cone_lands() -> void:
	for deg: float in [0.0, 20.0, 45.0, 58.0, -58.0]:
		for centre: float in [0.8, 0.95, 1.2, 1.45]:
			if _lands(AS.opts(0.0), deg, centre):
				assert_true(_lands(AS.opts(1.0), deg, centre), "strict hit at %.0f deg / %.2f m still lands with the assist" % [deg, centre])


func test_the_assist_never_extends_the_reach() -> void:
	# centre distance 0.75 + 2.0 x 0.5 = 1.75 m > strict reach 0.75 + 0.75: out of reach at any angle
	for deg: float in [0.0, 30.0, 75.0, -75.0, 120.0]:
		assert_false(_lands(AS.opts(1.0), deg, 1.75), "centre 1.75 m away (reach + radius = 1.5 m) at %.0f deg: no bite, assist or not" % deg)


func test_the_max_distance_cap_stops_the_assist() -> void:
	assert_eq(AS.crossing(AS.opts(1.0, {AS.KEY_MAX_DIST: AS.CAP_TINY}))["bites"], 0, "cap ~0: the crossing prey outside the cone is not assisted")
	assert_eq(AS.crossing(AS.opts(1.0, {AS.KEY_MAX_DIST: AS.CAP_HUGE}))["bites"], 1, "cap huge: the same prey is bitten")
	var r: Dictionary = AS.crossing(AS.opts(1.0, {AS.KEY_MAX_DIST: AS.CAP_TINY}))
	assert_true(int(r["misses"]) >= 1, "capped: the miss cue fires like with the assist off")


func test_a_zero_extra_cone_leaves_only_the_strict_cone() -> void:
	assert_eq(AS.crossing(AS.opts(1.0, {AS.KEY_CONE: 0.0}))["bites"], 0, "aim_assist_cone_deg 0: no extra angle, the crossing prey is missed")


# ======================================================================= scoring: centred / nearer wins, tie-break, stickiness

func test_a_centred_target_beats_an_off_axis_one_at_the_same_distance() -> void:
	var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: 0.0}))
	var p: SimEntity = TS.player(w)
	var off_axis: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 75.0))   # spawned FIRST: lower id
	var centred: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 0.0))
	var pins: Dictionary = {off_axis.id: off_axis.position, centred.id: centred.position}
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 3, pins, [off_axis.id, centred.id, p.id])
	assert_eq(AS.landed_ids(evs, p.id), [centred.id] as Array[int], "centred target, same distance, higher id: it wins")


func test_the_nearer_of_two_off_axis_targets_wins() -> void:
	for near_first: bool in [true, false]:
		var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: 0.0}))
		var p: SimEntity = TS.player(w)
		var pn: Vector3 = TS.at(p, 0.8, 75.0)
		var pf: Vector3 = TS.at(p, 1.2, 75.0)
		var first: SimEntity = TS.victim(w, p, pn if near_first else pf)
		var second: SimEntity = TS.victim(w, p, pf if near_first else pn)
		var near_e: SimEntity = first if near_first else second
		var pins: Dictionary = {first.id: first.position, second.id: second.position}
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = S3.step_n(w, 3, pins, [first.id, second.id, p.id])
		assert_eq(AS.landed_ids(evs, p.id), [near_e.id] as Array[int], "the nearer target wins whichever was spawned first (near_first=%s)" % near_first)


func test_equal_score_ties_go_to_the_lower_entity_id_and_are_stable() -> void:
	for sticky: float in [0.0, 0.5, 1.0]:
		var r: Dictionary = AS.stacked(AS.opts(1.0, {AS.KEY_STICKY: sticky}))
		var ids: Array[int] = r["ids"]
		var a: SimEntity = r["a"]
		var b: SimEntity = r["b"]
		assert_true(a.id < b.id, "scenario guard: a spawned before b")
		assert_true(ids.size() >= 6, "held bite lands every cooldown (stickiness %.1f, got %d bites)" % [sticky, ids.size()])
		for id: int in ids:
			assert_eq(id, a.id, "two victims on the same point: the lower id gets every bite (stickiness %.1f)" % sticky)
	var x: Dictionary = AS.stacked(AS.opts(1.0))
	var y: Dictionary = AS.stacked(AS.opts(1.0))
	assert_eq(x["trace"], y["trace"], "same state = same target = same trace, run twice")
	assert_eq(x["hash"], y["hash"], "...and the same hash")


func test_stickiness_zero_follows_the_nearer_target() -> void:
	var r: Dictionary = AS.sticky(AS.opts(1.0, {AS.KEY_STICKY: 0.0}))
	var ids: Array[int] = r["ids"]
	assert_true(ids.size() >= 6, "bites landed (got %d)" % ids.size())
	if ids.is_empty():
		return
	assert_eq(ids[0], (r["a"] as SimEntity).id, "the first bite goes to the nearer A")
	for i in range(1, ids.size()):
		assert_ne(ids[i], ids[i - 1], "bite %d follows the target that became nearer (no stickiness)" % i)


func test_full_stickiness_keeps_the_lock_on_the_first_target() -> void:
	var r: Dictionary = AS.sticky(AS.opts(1.0, {AS.KEY_STICKY: 1.0}))
	var ids: Array[int] = r["ids"]
	assert_true(ids.size() >= 6, "bites landed (got %d)" % ids.size())
	if ids.is_empty():
		return
	assert_eq(ids[0], (r["a"] as SimEntity).id, "the first bite goes to the nearer A")
	assert_true(_same_ids(ids), "stickiness 1: the lock never jumps to the other fish although it keeps getting 5 cm nearer (%s)" % [ids])


func test_a_locked_target_that_left_reach_is_dropped() -> void:
	# the locked target leaves reach: the bite must go to the other one or miss, never to the far one
	var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: 1.0}))
	var p: SimEntity = TS.player(w)
	var a: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 75.0))
	var b: SimEntity = TS.victim(w, p, TS.at(p, 1.0, -75.0))
	var far: Vector3 = TS.at(p, 4.0, 75.0)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 3, {a.id: a.position, b.id: b.position}, [a.id, b.id, p.id])
	assert_eq(AS.landed_ids(evs, p.id), [a.id] as Array[int], "first lock: nearer A")
	S3.step_n(w, 20, {a.id: far, b.id: b.position}, [a.id, b.id, p.id])
	w.submit(SimCommand.bite(p.id, -1))
	evs = S3.step_n(w, 3, {a.id: far, b.id: b.position}, [a.id, b.id, p.id])
	assert_eq(AS.landed_ids(evs, p.id), [b.id] as Array[int], "the locked A is 4 m away: the bite goes to B, stickiness cannot pull A back")


# ======================================================================= skip rules stay

func test_a_swallowable_fish_is_never_the_assisted_target() -> void:
	var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: 0.0}))
	var p: SimEntity = TS.player(w)
	var tiny_pos: Vector3 = TS.at(p, 0.5, 75.0)
	var big_pos: Vector3 = TS.at(p, 1.0, 75.0)
	var tiny: SimEntity = S3.npc_at(w, &"small_reef_fish", tiny_pos, 0.04, -p.heading)  # 0.04 <= 0.5 x swallow_ratio 0.1: swallowable
	assert_true(SimRules.can_swallow(p.length_m, tiny.length_m, S3.rule_f(w.content, "swallow_ratio")), "scenario guard: the tiny fish is swallowable")
	var big: SimEntity = TS.victim(w, p, big_pos)
	var pins: Dictionary = {tiny.id: tiny_pos, big.id: big_pos}
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 3, pins, [big.id, p.id])
	assert_eq(AS.bitten_by(evs, p.id, tiny.id).size(), 0, "the swallowable fish is not bitten although it is nearer and equally off-axis")
	assert_eq(AS.landed_ids(evs, p.id), [big.id] as Array[int], "the bite goes to the durable victim")
	assert_true(w.get_entity(tiny.id) != null and w.get_entity(tiny.id).alive, "the tiny fish is still alive (no swallow outside the 45 deg mouth cone)")


func test_only_a_swallowable_fish_in_the_assist_cone_is_a_miss() -> void:
	var w: SimWorld = AS.world(AS.opts(1.0))
	var p: SimEntity = TS.player(w)
	var tiny_pos: Vector3 = TS.at(p, 0.5, 75.0)
	var tiny: SimEntity = S3.npc_at(w, &"small_reef_fish", tiny_pos, 0.04, -p.heading)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 3, {tiny.id: tiny_pos}, [p.id])
	assert_eq(AS.bitten_by(evs, p.id).size(), 0, "nothing to bite: no BITTEN")
	assert_true(TS.misses_of(evs, p.id) >= 1, "the miss cue fires")


func test_an_inactive_creature_is_never_the_assisted_target() -> void:
	var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: 0.0}))
	var p: SimEntity = TS.player(w)
	var dead_pos: Vector3 = TS.at(p, 0.7, 75.0)
	var live_pos: Vector3 = TS.at(p, 1.0, 75.0)
	var decoy: SimEntity = TS.victim(w, p, dead_pos)   # lower id, nearer
	var live: SimEntity = TS.victim(w, p, live_pos)
	decoy.hp = 0.0   # inactive (hp <= 0) for the bite phase of the next tick
	w.submit(SimCommand.bite(p.id, -1))
	w.step()
	var evs: Array[SimEvent] = w.events_since(w.tick - 1)
	assert_eq(AS.bitten_by(evs, p.id, decoy.id).size(), 0, "the creature with hp 0 is not bitten")
	assert_eq(AS.bitten_by(evs, p.id, live.id).size(), 1, "the live one farther away takes the assisted bite")


func test_the_assist_cannot_bite_through_a_dead_player() -> void:
	var w: SimWorld = AS.world(AS.opts(1.0))
	var p: SimEntity = TS.player(w)
	var v: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 75.0))
	p.hp = 0.0
	w.submit(SimCommand.bite(p.id, -1))
	w.step()
	assert_eq(AS.bitten_by(w.events_since(w.tick - 1), p.id).size(), 0, "a player with hp 0 does not bite (assist or not)")
	assert_true(v.hp > 0.0, "victim untouched")


# ======================================================================= many candidates

func test_a_crowd_run_with_the_assist_is_deterministic_and_different_from_off() -> void:
	var off: Dictionary = AS.crowd(AS.opts(0.0))
	var a: Dictionary = AS.crowd(AS.opts(1.0))
	var b: Dictionary = AS.crowd(AS.opts(1.0))
	assert_eq(a["trace"], b["trace"], "eight prey around a turning player, assist on: run twice = same trace")
	assert_eq(a["hash"], b["hash"], "...and same hash")
	assert_ne(a["trace"], off["trace"], "the assist changes which fish are bitten")
	assert_true((a["ids"] as Array).size() >= (off["ids"] as Array).size(), "the assist does not bite less often than the strict cone (%d vs %d bites)" % [(a["ids"] as Array).size(), (off["ids"] as Array).size()])


func test_real_world_with_player_bites_is_deterministic_with_the_assist() -> void:
	var o: Dictionary = AS.opts(1.0)
	var a: Dictionary = AS.real_world_with_player_bites(o)
	var b: Dictionary = AS.real_world_with_player_bites(o)
	assert_eq(a["trace"], b["trace"], "shipped spawners, assist 1: two runs, same trace")
	assert_eq(a["hash"], b["hash"], "...same hash")
	var off: Dictionary = AS.real_world_with_player_bites(AS.opts(0.0))
	assert_eq(off["hash"], SS.BASELINE_HASHES["s3_real_4242_900"], "the same world at strength 0 is the pre-change baseline")
