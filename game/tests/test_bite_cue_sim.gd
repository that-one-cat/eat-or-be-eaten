extends TestCase
## T1.11 "can bite" cue, sim side: `SimWorld.peek_bite_target(player_id) -> int` is a READ-ONLY copy of the player bite
## selection. Real worlds, no mocks: the peek is called hundreds of times (assist off, assist on through `tune
## aim_assist_strength 1`, assisted control mode) and must never change the state hash, the RNG, the event log, the bite / lock
## memory of the player, and must name exactly the creature the real bite press hits afterwards (several geometries incl. a prey
## crossing outside the strict cone). Twin runs (same scenario with and without peeks) must be byte-identical.
##
## Assumptions (test plan): the peek ignores the bite cooldown / buffer, skips what the real strict path skips (swallowable,
## inactive), answers -1 for an unknown / dead player, ignores food sites, and READS the aim-lock memory without writing it.
## The refactor guard for the real path is the existing suites test_aim_assist_*, test_bite_lunge_*, test_control_modes_*.

const K := preload("res://tests/bite_cue_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const F := preload("res://tests/food_support.gd")


# ======================================================================= contract

func test_the_query_exists_and_answers_minus_one_for_nobody() -> void:
	var rg: Dictionary = K.build(K.GEOMETRIES[0], "off")
	var w: SimWorld = rg["w"]
	if not K.require(self, w):
		return
	assert_eq(K.peek(w, 99999), -1, "unknown entity id")
	assert_eq(K.peek(w, -1), -1, "id -1")
	assert_eq(K.peek(w, (rg["vs"][0] as SimEntity).id) >= -1, true, "a non-player id answers an int without crashing")


func test_a_dead_player_has_no_target() -> void:
	var rg: Dictionary = K.build(K.GEOMETRIES[0], "off")
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	if not K.require(self, w):
		return
	assert_eq(K.peek(w, p.id), (rg["vs"][0] as SimEntity).id, "alive: the victim ahead")
	p.alive = false
	assert_eq(K.peek(w, p.id), -1, "dead player: the real press would be dropped, so no target")
	p.alive = true
	p.hp = 0.0
	assert_eq(K.peek(w, p.id), -1, "hp 0 is inactive too")


# ======================================================================= pinned answers (derived from the T1.5 score)

func test_pinned_answers_for_off_and_global_assist() -> void:
	for geom: Dictionary in K.GEOMETRIES:
		for m: int in 2:
			var mode: String = K.MODES[m]
			var rg: Dictionary = K.build(geom, mode)
			var w: SimWorld = rg["w"]
			if not K.require(self, w):
				return
			var want_idx: int = int((K.EXPECT[geom["name"]] as Array)[m])
			var want: int = (rg["vs"][want_idx] as SimEntity).id if want_idx >= 0 else -1
			assert_eq(K.peek(w, (rg["p"] as SimEntity).id), want, "%s / %s: victim index %d" % [geom["name"], mode, want_idx])


func test_assisted_mode_sees_the_crossing_prey_and_classic_does_not() -> void:
	var off: Dictionary = K.build(K.GEOMETRIES[1], "off")
	var asd: Dictionary = K.build(K.GEOMETRIES[1], "assisted")
	if not K.require(self, off["w"]):
		return
	assert_eq(K.peek(off["w"], (off["p"] as SimEntity).id), -1, "classic: the prey at 75 deg is outside the strict cone")
	assert_eq(K.peek(asd["w"], (asd["p"] as SimEntity).id), (asd["vs"][0] as SimEntity).id, "assisted mode: the same prey is the target")


# ======================================================================= read-only + equals the real bite

func _equals_the_real_bite(mode: String) -> void:
	var peeks: int = 0
	for geom: Dictionary in K.GEOMETRIES:
		var a: Dictionary = K.build(geom, mode)
		var b: Dictionary = K.build(geom, mode)  # twin: never peeked
		var w: SimWorld = a["w"]
		if not K.require(self, w):
			return
		var h: Dictionary = K.hammer(w, (a["p"] as SimEntity).id, 300)
		peeks += 301
		var tag: String = "%s / %s" % [geom["name"], mode]
		assert_true(h["stable"], "%s: 300 peeks, one answer" % tag)
		assert_true(h["same_state"], "%s: tick / RNG / events / bite + lock memory / trace untouched by 300 peeks" % tag)
		assert_true(h["same_hash"], "%s: state_hash untouched" % tag)
		assert_true(h["no_debug"], "%s: no SimDebug state created" % tag)
		var ra: Dictionary = K.press(a)
		var rb: Dictionary = K.press(b)
		var landed: int = -1 if (ra["ids"] as Array).is_empty() else int((ra["ids"] as Array)[0])
		assert_eq(int(h["answer"]), landed, "%s: the peek names the creature the real press hits (-1 = a miss)" % tag)
		if landed < 0:
			assert_true(int(ra["misses"]) >= 1, "%s: no target = a BITE_MISSED on the real press" % tag)
		assert_eq(ra["trace"], rb["trace"], "%s: the peeked world and the never-peeked twin have the same trace" % tag)
		assert_eq(ra["hash"], rb["hash"], "%s: ... and the same state_hash after the press" % tag)
	assert_true(peeks >= 2400, "non-vacuity: %d peeks" % peeks)


func test_peek_is_read_only_and_equals_the_real_bite_with_the_assist_off() -> void:
	_equals_the_real_bite("off")


func test_peek_is_read_only_and_equals_the_real_bite_with_the_global_assist() -> void:
	_equals_the_real_bite("tune")


func test_peek_is_read_only_and_equals_the_real_bite_in_assisted_mode() -> void:
	_equals_the_real_bite("assisted")


func test_peek_ignores_the_bite_cooldown() -> void:
	for mode: String in ["off", "tune"]:
		var rg: Dictionary = K.build(K.GEOMETRIES[0], mode)
		var w: SimWorld = rg["w"]
		var p: SimEntity = rg["p"]
		if not K.require(self, w):
			return
		var v: SimEntity = rg["vs"][0]
		var r: Dictionary = K.press(rg)
		assert_eq((r["ids"] as Array).size(), 1, "%s: the first press lands" % mode)
		assert_true(p.bite_ready_tick > w.tick, "%s: the bite is on cooldown (ready at %d, now %d)" % [mode, p.bite_ready_tick, w.tick])
		assert_eq(K.peek(w, p.id), v.id, "%s: the peek still names the target during the cooldown" % mode)
		S3.step_n(w, 120, rg["pins"], rg["keep"])
		assert_true(w.tick >= p.bite_ready_tick, "%s: cooldown over" % mode)
		assert_eq(K.peek(w, p.id), v.id, "%s: and when ready" % mode)


# ======================================================================= skip rules

func test_peek_skips_swallowable_and_inactive_creatures() -> void:
	var w: SimWorld = AS.world(AS.opts(0.0))
	var p: SimEntity = TS.player(w)
	if not K.require(self, w):
		return
	var tiny: SimEntity = S3.npc_at(w, &"small_reef_fish", TS.at(p, 0.5, 0.0), 0.04, -p.heading)
	assert_true(SimRules.can_swallow(p.length_m, tiny.length_m, 0.10), "precondition: the tiny fish is swallowable")
	assert_eq(K.peek(w, p.id), -1, "a swallowable creature is no bite target")
	var big: SimEntity = TS.victim(w, p, TS.at(p, 1.2, 10.0))
	assert_eq(K.peek(w, p.id), big.id, "the big one behind it is")
	var dead: SimEntity = TS.victim(w, p, TS.at(p, 0.6, 0.0))
	assert_eq(K.peek(w, p.id), dead.id, "nearer big one wins")
	dead.hp = 0.0
	assert_eq(K.peek(w, p.id), big.id, "hp 0 is skipped")
	dead.hp = dead.max_hp
	dead.alive = false
	assert_eq(K.peek(w, p.id), big.id, "dead is skipped")
	TS.tune_all(TS.commands(), w, p.id, [AS.tune_line(AS.KEY_STRENGTH, 1.0)])
	assert_eq(K.peek(w, p.id), big.id, "same skip rules with the assist on")
	assert_false(K.peek(w, p.id) == tiny.id, "the swallowable one is never picked, assist or not")


func test_peek_ignores_food_sites() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}, "length": 0.3})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	if not K.require(self, w):
		return
	assert_eq(K.peek(w, p.id), -1, "a site in the cone and no creature: no target (sites are not entities)")
	var sdist: float = p.position.distance_to(sc["site"]["pos"])
	var grouper: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (sdist * 0.5), p.length_m * 3.0, -p.heading)
	var calm: Array[int] = [grouper.id]
	assert_eq(K.peek(w, p.id), grouper.id, "a creature nearer than the site: the creature")
	var snap: String = K.snapshot(w, p)
	for i in 50:
		K.peek(w, p.id)
	assert_eq(K.snapshot(w, p), snap, "no site state or event touched")
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 4, {p.id: sc["pos"], grouper.id: grouper.position}, [p.id], calm)
	assert_false(F.named(evs, "BITTEN").is_empty(), "and the real press bites that creature")


# ======================================================================= moving scenarios: first-hit timing, twins

func test_crossing_prey_the_first_peek_is_the_first_real_bite_with_the_assist_off() -> void:
	var r: Dictionary = K.crossing_held(AS.opts(0.0), [], "", 1)
	if not K.require(self, r["w"]):
		return
	assert_true(int(r["first_bite_tick"]) > 6, "the prey is outside the strict cone at first (bite at tick %d)" % int(r["first_bite_tick"]))
	assert_eq(int(r["first_peek_tick"]), int(r["first_bite_tick"]), "the peek turns positive on the very tick the real bite lands")
	assert_eq(int(r["first_peek_id"]), (r["v"] as SimEntity).id, "and names the prey")
	assert_eq(int(r["mismatch"]), 0, "every landed bite hit the creature peeked just before")


func test_crossing_prey_the_first_peek_is_the_first_real_bite_with_the_global_assist() -> void:
	var r: Dictionary = K.crossing_held(AS.opts(0.0), [AS.tune_line(AS.KEY_STRENGTH, 1.0)], "", 1)
	if not K.require(self, r["w"]):
		return
	assert_eq(int(r["first_bite_tick"]), 0, "assist on: the prey outside the cone is bitten at once")
	assert_eq(int(r["first_peek_tick"]), 0, "and the peek says so before the press")
	assert_eq(int(r["mismatch"]), 0, "every landed bite hit the creature peeked just before")
	assert_true(int(r["landed"]) >= 2, "non-vacuity: several bites (%d)" % int(r["landed"]))


func test_crossing_prey_the_first_peek_is_the_first_real_bite_in_assisted_mode() -> void:
	var off: Dictionary = K.crossing_held(AS.opts(0.0), [], "", 1)
	var r: Dictionary = K.crossing_held(AS.opts(0.0), [], "assisted", 1)
	if not K.require(self, r["w"]):
		return
	assert_true(int(r["first_bite_tick"]) >= 0 and int(r["first_bite_tick"]) < int(off["first_bite_tick"]), "assisted bites earlier than classic (%d vs %d)" % [int(r["first_bite_tick"]), int(off["first_bite_tick"])])
	assert_eq(int(r["first_peek_tick"]), int(r["first_bite_tick"]), "first peek tick == first bite tick")
	assert_eq(int(r["mismatch"]), 0, "every landed bite hit the creature peeked just before")


func test_crossing_run_with_hundreds_of_peeks_equals_the_run_without() -> void:
	var cases: Array[Dictionary] = [
		{"lines": [], "mode": ""}, {"lines": [AS.tune_line(AS.KEY_STRENGTH, 1.0)], "mode": ""}, {"lines": [], "mode": "assisted"},
	]
	for c: Dictionary in cases:
		var plain: Dictionary = K.crossing_held(AS.opts(0.0), c["lines"], c["mode"], 0)
		var peeked: Dictionary = K.crossing_held(AS.opts(0.0), c["lines"], c["mode"], 12)
		if not K.require(self, peeked["w"]):
			return
		assert_true(int(peeked["peeks_total"]) >= 288, "non-vacuity: %d peeks" % int(peeked["peeks_total"]))
		assert_eq(peeked["trace"], plain["trace"], "case %s: same trace" % [c])
		assert_eq(peeked["hash"], plain["hash"], "case %s: same state_hash" % [c])


func test_sticky_lock_the_peek_reads_the_memory_and_never_writes_it() -> void:
	if not K.require(self, AS.world(AS.opts(0.0))):
		return
	for sticky: float in [0.0, 0.5, 1.0]:
		var plain: Dictionary = K.sticky_run(sticky, 0)
		var peeked: Dictionary = K.sticky_run(sticky, 40)
		var tag: String = "stickiness %.1f" % sticky
		assert_true(int(peeked["landed"]) >= 5, "%s: non-vacuity, %d bites landed" % [tag, int(peeked["landed"])])
		assert_eq(int(peeked["mismatch"]), 0, "%s: every landed bite hit the creature peeked just before (lock included)" % tag)
		assert_eq(peeked["ids"], plain["ids"], "%s: same victims in the same order with and without peeks" % tag)
		assert_eq(peeked["trace"], plain["trace"], "%s: same trace" % tag)
		assert_eq(peeked["hash"], plain["hash"], "%s: same state_hash" % tag)


func test_the_peek_neither_drops_nor_refreshes_the_aim_lock() -> void:
	var rg: Dictionary = K.build(K.GEOMETRIES[0], "tune")
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	if not K.require(self, w):
		return
	var v: SimEntity = rg["vs"][0]
	var r: Dictionary = K.press(rg)
	assert_eq((r["ids"] as Array).size(), 1, "the first press lands")
	assert_eq(p.aim_lock_target, v.id, "precondition: the real selection remembers its target")
	var until: int = p.aim_lock_until_tick
	# the remembered target swims away: a REAL selection would reset the memory, the peek must not
	var far: Vector3 = TS.at(p, 8.0, 0.0)
	v.position = far
	rg["pins"][v.id] = far
	for i in 60:
		assert_eq(K.peek(w, p.id), -1, "out of reach: no target")
	assert_eq(p.aim_lock_target, v.id, "the lock is still there after 60 peeks")
	assert_eq(p.aim_lock_until_tick, until, "and its expiry did not move")
	S3.step_n(w, 20, rg["pins"], rg["keep"])
	for i in 20:
		K.peek(w, p.id)
	assert_eq(p.aim_lock_until_tick, until, "later peeks do not refresh the expiry either")


func test_crowd_run_with_peeks_equals_the_run_without() -> void:
	for strength: float in [0.0, 1.0]:
		var o: Dictionary = AS.opts(strength)
		var plain: Dictionary = AS.crowd(o)
		var peeked: Dictionary = K.crowd_peeked(o, 2)
		if not K.require(self, peeked["w"]):
			return
		assert_eq((peeked["ids"] as Array).size(), (plain["ids"] as Array).size(), "strength %.0f: same number of bites" % strength)
		assert_eq(peeked["trace"], plain["trace"], "strength %.0f: same trace (600 peeks)" % strength)
		assert_eq(peeked["hash"], plain["hash"], "strength %.0f: same state_hash" % strength)


func test_shipped_world_with_spawners_and_schools_is_unchanged_by_peeks() -> void:
	if not K.require(self, S3.make_world(1, {})):
		return
	for strength: float in [0.0, 1.0]:
		var o: Dictionary = AS.opts(strength)
		var plain: Dictionary = AS.real_world_with_player_bites(o)
		var peeked: Dictionary = K.real_world_peeked(o, 3)
		assert_eq(peeked["player_bites"], plain["player_bites"], "strength %.0f: same player bites" % strength)
		assert_eq(peeked["trace"], plain["trace"], "strength %.0f: same trace over 900 ticks (2700 peeks)" % strength)
		assert_eq(peeked["hash"], plain["hash"], "strength %.0f: same state_hash" % strength)


# ======================================================================= refactor guard (reference only)

func test_the_refactor_guard_suites_exist() -> void:
	# The real-path guard is NOT duplicated here: Phase B runs these suites (filters in TESTING.md) after the refactor of
	# `_bite_target` / `_assisted_bite_target`: test_aim_assist_ (T1.5), test_bite_lunge_ (T1.6), test_control_modes_ (T1.4).
	for f: String in ["test_aim_assist_sim", "test_aim_assist_data", "test_bite_lunge_identity", "test_bite_lunge_sim", "test_control_modes_sim", "test_control_modes_god"]:
		assert_true(FileAccess.file_exists("res://tests/%s.gd" % f), "guard suite present: %s" % f)
