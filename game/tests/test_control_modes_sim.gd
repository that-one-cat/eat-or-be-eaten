extends TestCase
## T1.4 control modes, sim end to end: the SET_CONTROL_MODE command (appended after PICK_MUTATION), the per-player mode in
## entity state, effective strengths = max(global rule, mode value) for the PLAYER only, classic = bit-identical (pinned
## pre-change hashes, explicit classic command, switching back), non-classic modes in state_hash, determinism, NPCs unaffected,
## the bot never emits the command. Real SimWorld runs only: a crossing prey that only the assist can bite, a resting player
## that only the lunge can move, with the GLOBAL strengths at 0 (the shipped values).
##
## The tests drive the world through SimWorld.submit / step / events and the kit's make_set() (control_modes_support.gd), never
## through private sim names. Entity state is read as `control_mode` (string / StringName id, or an int index) and only compared
## through CM.in_mode().
##
## Assumptions (listed in the test plan): classic is the default of every entity; a command for an NPC / dead entity / unknown
## mode is ignored; the mode survives death and respawn of the player entity; the data values of `assisted` are read from
## game/data/controls/modes.json (tests never hard-code 0.5).

const CM := preload("res://tests/control_modes_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const G := preload("res://tests/god_support.gd")
const LS := preload("res://tests/lunge_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const TS := preload("res://tests/tuning_support.gd")

## Lunge travel tolerance (same as the T1.6 tests: the impulse model is the implementation's choice).
const TOL: float = LS.TOL_FRAC
## "No lunge" bound on the travel (m).
const STILL_M: float = 0.02


func after_each() -> void:
	G.cleanup_temp()


func _need() -> bool:
	if not CM.has_type():
		fail("SimCommand.Type.SET_CONTROL_MODE does not exist")
		return false
	var probe: SimCommand = CM.make_set(1, "assisted")
	if probe == null:
		fail("cannot build a SET_CONTROL_MODE command (no factory %s on SimCommand and no payload property %s)" % [CM.SET_FACTORIES, CM.SET_PAYLOAD_PROPS])
		return false
	return true


## Expected lunge travel of the assisted preset at the explicit band-2 distance.
func _lunge_expect(strength: float) -> float:
	return LS.BAND_M_TEST[1] * strength


## Victim angle just outside the assisted cone (inside the strict cone's complement), capped below 150 deg.
func _outside_assisted_deg() -> float:
	return minf(CM.widened_deg(CM.mode_f("assisted", CM.KEY_AIM)) + 8.0, 148.0)


# ======================================================================= the command

func test_the_type_is_appended_after_pick_mutation() -> void:
	var t: Dictionary = SimCommand.Type
	assert_eq(int(t["MOVE"]), 0, "MOVE keeps 0")
	assert_eq(int(t["BOOST"]), 1, "BOOST keeps 1")
	assert_eq(int(t["BITE"]), 2, "BITE keeps 2")
	assert_eq(int(t["ABILITY"]), 3, "ABILITY keeps 3")
	assert_eq(int(t["BRAKE"]), 4, "BRAKE keeps 4")
	assert_eq(int(t["PICK_MUTATION"]), 5, "PICK_MUTATION keeps 5")
	assert_true(t.has("SET_CONTROL_MODE"), "SET_CONTROL_MODE exists")
	if t.has("SET_CONTROL_MODE"):
		assert_eq(int(t["SET_CONTROL_MODE"]), 6, "and comes right after PICK_MUTATION")


func test_the_command_carries_entity_tick_and_a_mode() -> void:
	if not _need():
		return
	var c: SimCommand = CM.make_set(7, "assisted", 12)
	assert_eq(int(c.type), CM.set_type(), "type")
	assert_eq(c.entity_id, 7, "entity")
	assert_eq(c.tick, 12, "tick")
	assert_true(CM.is_set_of(c, "assisted"), "payload says assisted")
	assert_false(CM.is_set_of(c, "classic"), "and not classic")
	assert_false(CM.is_set_of(CM.make_set(7, "smoothed", 12), "assisted"), "different modes carry different payloads")


# ======================================================================= identity in classic

func test_classic_without_any_command_matches_the_pre_change_baselines() -> void:
	var c: Dictionary = CM.crossing("")
	assert_eq(c["hash"], CM.BASELINE_HASHES["crossing"], "crossing scenario state_hash")
	assert_eq(c["trace"], CM.BASELINE_TRACES["crossing"], "crossing scenario trace")
	assert_eq(c["bites"], 0, "classic: the crossing prey outside the strict cone is missed")
	var w: SimWorld = CM.lunge_world()
	var r: Dictionary = CM.lunge_once(w, "")
	assert_eq(w.state_hash(), CM.BASELINE_HASHES["lunge"], "resting-lunge scenario state_hash")
	assert_eq(TS.trace(w), CM.BASELINE_TRACES["lunge"], "resting-lunge scenario trace")
	assert_true(float(r["travel"]) < STILL_M, "classic + global lunge 0: the landed bite does not move the player (%s m)" % r["travel"])
	var s: Dictionary = CM.swim()
	assert_eq(s["hash"], CM.BASELINE_HASHES["swim"], "free-swim scenario state_hash")
	assert_eq(s["trace"], CM.BASELINE_TRACES["swim"], "free-swim scenario trace")


func test_an_explicit_classic_command_changes_nothing() -> void:
	if not _need():
		return
	var c: Dictionary = CM.crossing("classic")
	assert_eq(c["hash"], CM.BASELINE_HASHES["crossing"], "crossing: classic command, same state_hash")
	assert_eq(c["trace"], CM.BASELINE_TRACES["crossing"], "crossing: classic command, same trace")
	var w: SimWorld = CM.lunge_world()
	CM.lunge_once(w, "classic")
	assert_eq(w.state_hash(), CM.BASELINE_HASHES["lunge"], "lunge: classic command, same state_hash")
	var s: Dictionary = CM.swim([{"tick": 0, "mode": "classic"}, {"tick": 77, "mode": "classic"}])
	assert_eq(s["hash"], CM.BASELINE_HASHES["swim"], "swim: two classic commands, same state_hash")
	assert_eq(s["trace"], CM.BASELINE_TRACES["swim"], "swim: two classic commands, same trace")


func test_the_shipped_world_with_an_explicit_classic_command_has_the_same_hash() -> void:
	if not _need():
		return
	var a: Dictionary = CM.real_world("", 4242, 600)
	var b: Dictionary = CM.real_world("classic", 4242, 600)
	assert_eq(b["hash"], a["hash"], "spawners + schools + player bites: classic command = no command (state_hash)")
	assert_eq(b["trace"], a["trace"], "and the same trace")
	assert_true(int(a["npc_bites"]) > 0, "non-vacuous: the world is busy (%d NPC bites; the scripted player rarely lands one in 600 ticks, the identity is what counts)" % a["npc_bites"])


func test_unknown_payloads_are_ignored() -> void:
	if not _need():
		return
	var base: Dictionary = {}
	for kind in 4:
		var w: SimWorld = AS.world({})
		var p: SimEntity = TS.player(w)
		if kind > 0:
			var bad: SimCommand = CM.make_bad_set(p.id, kind - 1)
			assert_not_null(bad, "bad command #%d built" % kind)
			if bad == null:
				return
			w.submit(bad)
		S3.step_n(w, 6, {}, [p.id])
		var h: int = w.state_hash()
		if kind == 0:
			base = {"hash": h}
		else:
			assert_eq(h, base["hash"], "bad payload #%d (unknown id / out-of-range index) changes nothing" % kind)
			assert_true(CM.in_mode(p, "classic") or CM.mode_value(p) == null, "bad payload #%d leaves the player in classic" % kind)


func test_a_command_for_an_unknown_entity_is_ignored() -> void:
	if not _need():
		return
	var a: SimWorld = AS.world({})
	var b: SimWorld = AS.world({})
	TS.player(a)
	TS.player(b)
	b.submit(CM.make_set(9999, "assisted"))
	S3.step_n(a, 5)
	S3.step_n(b, 5)
	assert_eq(b.state_hash(), a.state_hash(), "SET_CONTROL_MODE for an entity that does not exist is dropped")


# ======================================================================= entity state and hash

func test_the_mode_lives_in_entity_state_and_follows_the_commands() -> void:
	if not _need():
		return
	var w: SimWorld = AS.world({})
	var p: SimEntity = TS.player(w)
	assert_true(CM.in_mode(p, "classic"), "a fresh player is in classic (value %s)" % str(CM.mode_value(p)))
	for id: String in ["assisted", "smoothed", "assisted", "classic"]:
		w.submit(CM.make_set(p.id, id))
		S3.step_n(w, 2, {}, [p.id])
		assert_true(CM.in_mode(p, id), "after SET %s the player is in %s (value %s)" % [id, id, str(CM.mode_value(p))])


func test_a_pending_command_is_part_of_the_hash() -> void:
	if not _need():
		return
	var hashes: Array[int] = []
	for id: String in ["", "assisted", "smoothed"]:
		var w: SimWorld = AS.world({})
		var p: SimEntity = TS.player(w)
		if id != "":
			w.submit(CM.make_set(p.id, id, 50))  # due later: it stays queued
		hashes.append(w.state_hash())
	assert_ne(hashes[1], hashes[0], "a queued SET assisted changes the hash")
	assert_ne(hashes[2], hashes[0], "a queued SET smoothed changes the hash")
	assert_ne(hashes[1], hashes[2], "and the two payloads hash differently")


func test_non_classic_modes_add_hash_bytes_and_classic_adds_none() -> void:
	if not _need():
		return
	var assisted: Dictionary = CM.swim([{"tick": 0, "mode": "assisted"}])
	var smoothed: Dictionary = CM.swim([{"tick": 0, "mode": "smoothed"}])
	assert_ne(assisted["hash"], CM.BASELINE_HASHES["swim"], "assisted: state_hash differs from classic")
	assert_ne(smoothed["hash"], CM.BASELINE_HASHES["swim"], "smoothed: state_hash differs from classic")
	assert_ne(assisted["hash"], smoothed["hash"], "and the two modes differ from each other")
	assert_eq(assisted["trace"], CM.BASELINE_TRACES["swim"], "but an assisted player that never lands a bite moves exactly like classic")
	assert_eq(smoothed["trace"], CM.BASELINE_TRACES["swim"], "and so does smoothed (the sim has no smoothing)")


func test_switching_back_to_classic_leaves_no_trace_in_the_hash() -> void:
	if not _need():
		return
	var s: Dictionary = CM.swim([{"tick": 20, "mode": "assisted"}, {"tick": 120, "mode": "classic"}])
	assert_eq(s["hash"], CM.BASELINE_HASHES["swim"], "assisted for 100 ticks and back: state_hash equals the never-switched run")
	var t: Dictionary = CM.swim([{"tick": 20, "mode": "smoothed"}, {"tick": 120, "mode": "classic"}])
	assert_eq(t["hash"], CM.BASELINE_HASHES["swim"], "smoothed for 100 ticks and back: state_hash equals the never-switched run")


func test_mode_runs_are_deterministic() -> void:
	if not _need():
		return
	var a: Dictionary = CM.crossing("assisted")
	var b: Dictionary = CM.crossing("assisted")
	assert_eq(a["hash"], b["hash"], "crossing, assisted, twice: same state_hash")
	assert_eq(a["trace"], b["trace"], "and the same trace")
	var la: SimWorld = CM.lunge_world()
	var lb: SimWorld = CM.lunge_world()
	CM.lunge_once(la, "assisted")
	CM.lunge_once(lb, "assisted")
	assert_eq(la.state_hash(), lb.state_hash(), "lunge, assisted, twice: same state_hash")


func test_the_shipped_world_in_assisted_mode_is_deterministic() -> void:
	if not _need():
		return
	var a: Dictionary = CM.real_world("assisted", 4242, 600)
	var b: Dictionary = CM.real_world("assisted", 4242, 600)
	assert_eq(a["hash"], b["hash"], "spawners + schools + assisted player bites: same state_hash twice")
	assert_eq(a["trace"], b["trace"], "and the same trace")
	assert_true(int(a["npc_bites"]) > 0, "non-vacuous: the world is busy (%d NPC bites)" % a["npc_bites"])


func test_the_mode_survives_death_and_respawn() -> void:
	if not _need():
		return
	var w: SimWorld = AS.world({})
	var p: SimEntity = TS.player(w)
	w.submit(CM.make_set(p.id, "assisted"))
	S3.step_n(w, 2, {}, [p.id])
	p.hp = 0.0
	var died: bool = false
	var respawned: bool = false
	var guard: int = 0
	while guard < 600 and not respawned:
		w.step()
		guard += 1
		if not p.alive:
			died = true
		elif died:
			respawned = true
	assert_true(died and respawned, "test setup: the player died and respawned as the same entity (died %s, respawned %s)" % [died, respawned])
	if respawned:
		assert_true(CM.in_mode(p, "assisted"), "the chosen mode is not reset by a respawn (value %s)" % str(CM.mode_value(p)))


# ======================================================================= assisted: aim assist

func test_assisted_lands_a_bite_on_a_crossing_prey_that_classic_misses() -> void:
	if not _need():
		return
	var s_a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var classic: Dictionary = CM.crossing("classic")
	var assisted: Dictionary = CM.crossing("assisted")
	assert_true(float(classic["min_angle"]) > CM.strict_cone_deg(), "setup: the prey stays outside the strict %s deg cone (closest %.1f deg)" % [CM.strict_cone_deg(), classic["min_angle"]])
	assert_true(float(classic["min_angle"]) < CM.widened_deg(s_a), "setup: but inside the cone widened by the assisted strength %s (%.1f deg); raise the scenario angle if the shipped strength is smaller" % [s_a, CM.widened_deg(s_a)])
	assert_eq(classic["bites"], 0, "classic (global strengths 0): no bite on the crossing prey")
	assert_true(int(classic["misses"]) >= 1, "classic: the press is a miss")
	assert_true(int(assisted["bites"]) >= 1, "assisted (global strengths 0): the press lands on the crossing prey (%d bites)" % assisted["bites"])
	var first: Array[SimEvent] = TS.bites_by(assisted["evs"], (assisted["p"] as SimEntity).id, (assisted["v"] as SimEntity).id)
	assert_false(first.is_empty(), "and the BITTEN event names the player and the prey")


func test_switching_the_mode_back_restores_the_miss_and_forward_restores_the_bite() -> void:
	if not _need():
		return
	var s_a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var deg: float = (CM.strict_cone_deg() + CM.widened_deg(s_a)) * 0.5
	var got: Array[int] = CM.phases_on(["classic", "assisted", "classic", "assisted", "classic"], deg)
	assert_eq(got.size(), 5, "five phases ran")
	if got.size() == 5:
		assert_eq(got[0], 0, "phase 1 classic: miss at %.1f deg" % deg)
		assert_true(got[1] >= 1, "phase 2 assisted: bite at %.1f deg (%d)" % [deg, got[1]])
		assert_eq(got[2], 0, "phase 3 back to classic: the miss is back")
		assert_true(got[3] >= 1, "phase 4 assisted again: bite")
		assert_eq(got[4], 0, "phase 5 classic: miss")


func test_the_assisted_aim_strength_comes_from_the_data_file() -> void:
	if not _need():
		return
	var deg: float = CM.strict_cone_deg() + CM.assist_cone_deg() * 0.6  # needs a strength of 0.6 or more
	var expect: Array = [[1.0, true], [0.2, false], [0.0, false]]
	for row: Array in expect:
		var db: ContentDB = CM.db_with_field("assisted", CM.KEY_AIM, float(row[0]))
		assert_true(db.is_valid(), "edited copy loads: %s" % CM.errors_text(db))
		var got: Array[int] = CM.phases(CM.world_on(db), ["assisted"], deg)
		if bool(row[1]):
			assert_true(got[0] >= 1, "assisted.aim_assist_strength = %s in the data: bite at %.0f deg" % [row[0], deg])
		else:
			assert_eq(got[0], 0, "assisted.aim_assist_strength = %s in the data: miss at %.0f deg" % [row[0], deg])


func test_the_effective_aim_strength_is_the_max_of_global_and_mode() -> void:
	if not _need():
		return
	var s_a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var deg_out: float = _outside_assisted_deg()
	assert_true(deg_out > CM.widened_deg(s_a), "setup: %.1f deg is outside the assisted cone (%.1f)" % [deg_out, CM.widened_deg(s_a)])
	assert_eq(CM.phases_on(["assisted"], deg_out)[0], 0, "global 0 + assisted: a prey outside the assisted cone is missed")
	assert_eq(CM.phases_on(["classic"], deg_out)[0], 0, "global 0 + classic: missed")
	assert_true(CM.phases_on(["classic"], deg_out, {CM.KEY_AIM: 1.0})[0] >= 1, "global 1.0 + classic: the global assist alone still works (the mode never lowers it)")
	assert_true(CM.phases_on(["assisted"], deg_out, {CM.KEY_AIM: 1.0})[0] >= 1, "global 1.0 + assisted: max(1.0, mode) = 1.0, bite")
	# max, not sum: a global value below the mode value adds nothing
	var s_g: float = s_a * 0.8
	var deg_sum: float = CM.widened_deg(s_a) + 0.5 * (CM.widened_deg(s_a + s_g) - CM.widened_deg(s_a))
	if deg_sum < 170.0:
		assert_eq(CM.phases_on(["assisted"], deg_sum, {CM.KEY_AIM: s_g})[0], 0, "global %.2f + assisted %.2f: effective = the larger one, NOT the sum (%.1f deg is missed)" % [s_g, s_a, deg_sum])


func test_assisted_equals_the_same_edit_in_the_global_rules() -> void:
	if not _need():
		return
	var s_a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var s_l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	var by_rules: Dictionary = CM.crossing("", {CM.KEY_AIM: s_a, CM.KEY_LUNGE: s_l})
	var by_mode: Dictionary = CM.crossing("assisted")
	assert_true(int(by_mode["bites"]) >= 1, "setup: the assisted run bites")
	assert_eq(by_mode["bites"], by_rules["bites"], "same number of bites")
	assert_eq(by_mode["trace"], by_rules["trace"], "whole trajectory and event trace = the global rules with the preset's numbers (classic, strengths %s / %s)" % [s_a, s_l])


# ======================================================================= assisted: lunge

func test_assisted_lunges_on_a_landed_bite_and_classic_does_not() -> void:
	if not _need():
		return
	var s_l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	var classic: Dictionary = CM.lunge_once(CM.lunge_world(), "classic")
	var assisted: Dictionary = CM.lunge_once(CM.lunge_world(), "assisted")
	assert_eq(classic["landed"], 1, "setup: one landed bite (classic)")
	assert_eq(assisted["landed"], 1, "setup: one landed bite (assisted)")
	assert_true(float(classic["travel"]) < STILL_M, "classic, global lunge 0: no movement (%s m)" % classic["travel"])
	var want: float = _lunge_expect(s_l)
	assert_true(absf(float(assisted["travel"]) - want) <= want * TOL, "assisted: travel %.3f m = band distance %.1f m x strength %.2f = %.3f m (+-30%%)" % [assisted["travel"], LS.BAND_M_TEST[1], s_l, want])
	assert_true(float(assisted["along"]) >= 0.9 * float(assisted["travel"]), "the lunge goes forward along the heading")
	assert_true(float(assisted["angle_deg"]) < 10.0, "and the heading is not turned (%.1f deg)" % assisted["angle_deg"])


func test_the_assisted_lunge_strength_comes_from_the_data_file() -> void:
	if not _need():
		return
	var travels: Array[float] = []
	for s: float in [1.0, 0.25]:
		var db: ContentDB = CM.db_with_field("assisted", CM.KEY_LUNGE, s)
		assert_true(db.is_valid(), "edited copy loads: %s" % CM.errors_text(db))
		var r: Dictionary = CM.lunge_once(CM.lunge_world_on(db), "assisted")
		var want: float = _lunge_expect(s)
		assert_true(absf(float(r["travel"]) - want) <= want * TOL, "assisted.lunge_strength = %s in the data: travel %.3f m, expected %.3f m (+-30%%)" % [s, r["travel"], want])
		travels.append(float(r["travel"]))
	if travels.size() == 2 and travels[1] > 0.0:
		assert_true(travels[0] / travels[1] > 2.8 and travels[0] / travels[1] < 5.5, "strength 1.0 travels about 4x as far as 0.25 (ratio %.2f)" % (travels[0] / travels[1]))


func test_the_effective_lunge_strength_is_the_max_of_global_and_mode() -> void:
	if not _need():
		return
	var s_l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	var d: float = LS.BAND_M_TEST[1]
	var g_hi: Dictionary = CM.lunge_once(CM.lunge_world(1.0), "classic")
	assert_true(absf(float(g_hi["travel"]) - d) <= d * TOL, "global 1.0 + classic: the global lunge still works (%.3f m of %.1f)" % [g_hi["travel"], d])
	var both: Dictionary = CM.lunge_once(CM.lunge_world(1.0), "assisted")
	assert_true(absf(float(both["travel"]) - d) <= d * TOL, "global 1.0 + assisted: max(1.0, %.2f) = 1.0, travel %.3f m (NOT %.2f m: no adding)" % [s_l, both["travel"], d * (1.0 + s_l)])
	var g_lo: float = s_l * 0.4
	var low: Dictionary = CM.lunge_once(CM.lunge_world(g_lo), "assisted")
	var want: float = d * s_l
	assert_true(absf(float(low["travel"]) - want) <= want * TOL, "global %.2f + assisted %.2f: travel %.3f m = the larger value (%.3f m), not the sum" % [g_lo, s_l, low["travel"], want])


func test_switching_the_mode_back_restores_no_lunge() -> void:
	if not _need():
		return
	var s_l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	var want: float = _lunge_expect(s_l)
	var r1: Dictionary = CM.lunge_once(CM.lunge_world(), "assisted")
	assert_true(absf(float(r1["travel"]) - want) <= want * TOL, "assisted: lunges (%.3f m)" % r1["travel"])
	var r2: Dictionary = CM.lunge_again(r1, "classic")
	assert_eq(r2["landed"], 1, "setup: the second bite lands")
	assert_true(float(r2["travel"]) < STILL_M, "back to classic: the next landed bite does not lunge (%.3f m)" % r2["travel"])
	var r3: Dictionary = CM.lunge_again(r2, "assisted")
	assert_true(absf(float(r3["travel"]) - want) <= want * TOL, "assisted again: lunges again (%.3f m)" % r3["travel"])


func test_switching_to_classic_in_the_middle_of_a_lunge_is_safe() -> void:
	if not _need():
		return
	var s_l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	var w: SimWorld = CM.lunge_world()
	var p: SimEntity = LS.player(w, 2, LS.HEADING_YAW)
	var v: SimEntity = LS.victim(w, p)
	w.submit(CM.make_set(p.id, "assisted"))
	var part: Dictionary = LS.run(w, p, v, 5, [{"tick": 2, "bite": true}])  # the lunge window is open
	w.submit(CM.make_set(p.id, "classic"))
	var rest: Dictionary = LS.run(w, p, v, LS.SETTLE)
	var total: float = (rest["end"] as Vector3).distance_to(part["start"] as Vector3)
	assert_true(p.position.is_finite() and p.velocity.is_finite(), "state stays finite")
	assert_true(total <= _lunge_expect(s_l) * (1.0 + TOL) + 0.05, "the interrupted lunge never travels more than a full one (%.3f m)" % total)
	assert_true(p.velocity.length() < 0.05, "and the player comes to rest (%.3f m/s)" % p.velocity.length())
	var again: Dictionary = CM.lunge_again({"w": w, "p": p, "v": v}, "")
	assert_true(float(again["travel"]) < STILL_M, "the next landed bite in classic does not lunge (%.3f m)" % again["travel"])


# ======================================================================= smoothed: no sim effect

func test_smoothed_leaves_the_sim_trajectory_alone() -> void:
	if not _need():
		return
	var s: Dictionary = CM.crossing("smoothed")
	assert_eq(s["trace"], CM.BASELINE_TRACES["crossing"], "smoothed: the crossing scenario plays out exactly like classic (miss included)")
	assert_eq(s["bites"], 0, "smoothed does not assist the aim")
	var w: SimWorld = CM.lunge_world()
	var r: Dictionary = CM.lunge_once(w, "smoothed")
	assert_true(float(r["travel"]) < STILL_M, "smoothed does not lunge (%s m)" % r["travel"])
	assert_eq(TS.trace(w), CM.BASELINE_TRACES["lunge"], "and its lunge scenario trace equals classic")


# ======================================================================= NPCs

func test_npcs_never_get_the_assists_whatever_the_player_mode() -> void:
	if not _need():
		return
	var base: Dictionary = CM.npc_hunt("")
	assert_true(int(base["npc_bites"]) > 0, "setup: the shark bites (%d)" % base["npc_bites"])
	var with_player: Dictionary = CM.npc_hunt("assisted")
	assert_eq(with_player["trace"], base["trace"], "an assisted player 40 m away changes no NPC bite or movement")
	assert_eq(with_player["npc_bites"], base["npc_bites"], "same NPC bite count")


func test_a_command_aimed_at_an_npc_is_ignored() -> void:
	if not _need():
		return
	var base: Dictionary = CM.npc_hunt("")
	var hit: Dictionary = CM.npc_hunt("", "assisted")
	assert_eq(hit["trace"], base["trace"], "SET_CONTROL_MODE assisted for the shark changes nothing")
	var shark: SimEntity = (hit["w"] as SimWorld).get_entity(int(hit["shark_id"]))
	assert_false(CM.in_mode(shark, "assisted"), "and the shark is not in assisted mode (value %s)" % str(CM.mode_value(shark)))


func test_npc_bites_in_the_shipped_world_do_not_depend_on_the_player_mode() -> void:
	if not _need():
		return
	var a: Dictionary = CM.real_world("", 4242, 600, false)
	var b: Dictionary = CM.real_world("assisted", 4242, 600, false)
	assert_true(int(a["npc_bites"]) > 0, "setup: NPCs bite in the shipped world (%d)" % a["npc_bites"])
	assert_eq(b["npc_bites"], a["npc_bites"], "same NPC bite count with an assisted (non-biting) player")
	assert_eq(b["trace"], a["trace"], "and the same whole trace")


# ======================================================================= bots

func test_the_bot_never_emits_the_command_and_its_stream_is_unchanged() -> void:
	var b: Dictionary = CM.bot_stream()
	assert_eq(b["set_count"], 0, "the v1 bot submitted no SET_CONTROL_MODE")
	assert_true(int(b["max_type"]) <= 5, "and no command type beyond PICK_MUTATION (max %d)" % b["max_type"])
	assert_eq(b["digest"], CM.BASELINE_BOT_DIGEST, "the bot's whole command stream over %d ticks is byte-identical to the pre-change one" % CM.BOT_TICKS)
	assert_eq(b["hash"], CM.BASELINE_HASHES["bot"], "and so is the final state_hash (acceptance bot seed 1: full 10-minute hash is in the test plan)")
