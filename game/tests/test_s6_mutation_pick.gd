extends TestCase
## S6 mutation pick (GAME_DESIGN section 4, contract "Mutation pick"): the offer on band-up (count, tier order,
## owned nodes excluded, seeded), the world pause while an offer is open, PICK_MUTATION (valid / invalid), no second
## offer for a band regained after a death, at most 3 picks per run.
## The shipped tree exposes only 2 available nodes at every pick (two branches, one next node each), so the tests that
## need a 3-node offer use a patched data copy with extra tier-1 nodes (S6.db_with_nodes).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const HUNTER_1: String = "hunter_bite_power"
const SURVIVOR_1: String = "survivor_efficient_metabolism"
const EXTRAS: Array[String] = ["hunter_x1", "hunter_x2", "hunter_x3", "hunter_x4", "hunter_x5", "hunter_x6"]


func _extra_db(n: int) -> ContentDB:
	var nodes: Array = []
	for i in n:
		nodes.append(S6.extra_node(EXTRAS[i]))
	return S6.db_with_nodes(nodes)


## World + player at the start of B1 on the given data, level-up to B2 done; returns {"w","p","evs"}.
func _first_offer(world_seed: int, db: ContentDB = null) -> Dictionary:
	var opts: Dictionary = {}
	if db != null:
		opts["db"] = db
	var r: Dictionary = S6.arena_player(world_seed, 0.0, opts)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	var evs: Array[SimEvent] = S6.level_to(w, p, 2)
	return {"w": w, "p": p, "evs": evs}


func _node(db: ContentDB, id: String) -> Dictionary:
	return db.get_mutation(StringName(id))


## True when node `id` may be offered to a player owning `owned`: not owned, prerequisite null or owned.
func _available(db: ContentDB, id: String, owned: PackedStringArray) -> bool:
	if owned.has(id):
		return false
	var req: Variant = _node(db, id).get("requires")
	return req == null or owned.has(str(req))


func _available_count(db: ContentDB, owned: PackedStringArray) -> int:
	var n: int = 0
	for id: StringName in db.mutation_ids():
		if _available(db, String(id), owned):
			n += 1
	return n


# ======================================================== the offer

func test_band_up_makes_an_offer_in_the_same_step() -> void:
	var r: Dictionary = _first_offer(11)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	var evs: Array[SimEvent] = r["evs"]
	if not S6.require_api(self, w):
		return
	var up: Array[SimEvent] = S6.events_named(evs, "BAND_UP")
	var offered: Array[SimEvent] = S6.events_named(evs, "MUTATION_OFFERED")
	assert_eq(up.size(), 1, "exactly one BAND_UP")
	assert_eq(offered.size(), 1, "exactly one MUTATION_OFFERED")
	if offered.size() == 1 and up.size() == 1:
		assert_eq(offered[0].entity_id, p.id, "the offer event is about the player")
		assert_eq(offered[0].tick, up[0].tick, "the offer comes in the tick of the band-up")
		assert_eq(Array(S6.offer_ids(offered[0])), Array(S6.offer_of(p)), "event data.offer equals player.pending_offer")
	assert_true(S6.paused(w), "world is paused for the pick")
	assert_true(S6.offer_of(p).size() > 0, "an offer is pending")


func test_shipped_tree_offers_both_tier_one_nodes_at_the_first_pick() -> void:
	var r: Dictionary = _first_offer(12)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var offer: PackedStringArray = S6.offer_of(p)
	var want: Array = [HUNTER_1, SURVIVOR_1]
	want.sort()
	var got: Array = Array(offer)
	got.sort()
	assert_eq(got, want, "only tier-1 nodes are available at the first pick; fewer than %d offered when fewer exist" % S6.offer_count(w.content))


func test_offer_is_three_nodes_when_enough_are_available() -> void:
	var db: ContentDB = _extra_db(4)
	assert_not_null(db, "test setup: patched data copy")
	if db == null:
		return
	assert_true(db.is_valid(), "test setup: patched data valid: %s" % ", ".join(db.errors))
	var r: Dictionary = _first_offer(13, db)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var offer: PackedStringArray = S6.offer_of(p)
	assert_eq(offer.size(), S6.offer_count(w.content), "mutation_offer_count nodes are offered")
	var seen: Dictionary = {}
	for id: String in offer:
		assert_false(seen.has(id), "no duplicate in the offer: %s" % id)
		seen[id] = true
		assert_true(_available(db, id, PackedStringArray()), "offered node %s is available (tier 1)" % id)


func test_offer_is_two_nodes_when_only_two_exist_even_if_three_are_asked() -> void:
	var r: Dictionary = S6.arena_player(14, 0.0, {"rules": {"mutation_offer_count": 5}})
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	assert_eq(S6.offer_of(p).size(), 2, "offer is capped by the available nodes (2 tier-1 nodes), not padded")


func test_offer_respects_tier_order_and_owned_nodes_over_a_whole_run() -> void:
	# 12 seeds x 3 picks, random branch choice by a test-side LCG. Every offered node: not owned, prerequisite owned.
	for s in range(1, 13):
		var r: Dictionary = S6.arena_player(100 + s, 0.0)
		var w: SimWorld = r["w"]
		var p: SimEntity = r["p"]
		if not S6.require_api(self, w):
			return
		var db: ContentDB = w.content
		var lcg_state: int = s * 7919
		for band in range(2, 5):
			S6.level_to(w, p, band)
			var offer: PackedStringArray = S6.offer_of(p)
			assert_true(offer.size() > 0, "seed %d band %d: an offer exists" % [s, band])
			if offer.is_empty():
				break
			var owned: PackedStringArray = S6.mutations_of(p)
			for id: String in offer:
				assert_true(_available(db, id, owned), "seed %d band %d: offered %s needs %s, owned %s" % [s, band, id, str(_node(db, id).get("requires")), str(owned)])
			assert_eq(offer.size(), mini(S6.offer_count(db), _available_count(db, owned)), "seed %d band %d: offer size" % [s, band])
			lcg_state = (lcg_state * 1103515245 + 12345) & 0x7FFFFFFF
			var choice: String = offer[lcg_state % offer.size()]
			S6.resolve_pick(w, p.id, choice)
			assert_true(S6.mutations_of(p).has(choice), "seed %d band %d: %s owned after the pick" % [s, band, choice])
		assert_eq(S6.mutations_of(p).size(), 3, "seed %d: three picks in a run" % s)
		# the owned set is prerequisite-closed: every owned node's prerequisite is owned too
		for id2: String in S6.mutations_of(p):
			var req: Variant = _node(db, id2).get("requires")
			assert_true(req == null or S6.mutations_of(p).has(str(req)), "seed %d: owned %s without its prerequisite" % [s, id2])


# ======================================================== seeding

func test_same_seed_same_offers() -> void:
	var db_a: ContentDB = _extra_db(6)
	var db_b: ContentDB = _extra_db(6)
	if db_a == null or db_b == null:
		fail("test setup: patched data copy")
		return
	var a: Dictionary = _first_offer(77, db_a)
	var b: Dictionary = _first_offer(77, db_b)
	if not S6.require_api(self, a["w"]):
		return
	assert_eq(Array(S6.offer_of(a["p"])), Array(S6.offer_of(b["p"])), "same seed + same history = same offer (order included)")
	assert_eq(S6.offer_of(a["p"]).size(), 3, "test is not vacuous: a 3-of-8 draw")


func test_different_seeds_give_different_offers() -> void:
	var variety: Dictionary = {}
	for s in range(1, 17):
		var db: ContentDB = _extra_db(6)
		if db == null:
			fail("test setup: patched data copy")
			return
		var r: Dictionary = _first_offer(s, db)
		if not S6.require_api(self, r["w"]):
			return
		var o: Array = Array(S6.offer_of(r["p"]))
		variety[str(o)] = true
	assert_true(variety.size() >= 3, "16 seeds over a 3-of-8 draw give at least 3 distinct offers, got %d" % variety.size())


func test_offer_ignores_the_global_rng() -> void:
	var db_a: ContentDB = _extra_db(6)
	var db_b: ContentDB = _extra_db(6)
	if db_a == null or db_b == null:
		fail("test setup: patched data copy")
		return
	seed(1)
	var a: Dictionary = _first_offer(5, db_a)
	randi()
	seed(987654)
	var b: Dictionary = _first_offer(5, db_b)
	if not S6.require_api(self, a["w"]):
		return
	assert_eq(Array(S6.offer_of(a["p"])), Array(S6.offer_of(b["p"])), "global randi()/seed() must not influence the pick offer")


func test_identical_history_gives_the_identical_offer() -> void:
	# 40 idle ticks first (guards a hidden dependency on object ids / dictionary order / history length).
	for s in [3, 4, 5]:
		var da: ContentDB = _extra_db(6)
		var db2: ContentDB = _extra_db(6)
		if da == null or db2 == null:
			fail("test setup: patched data copy")
			return
		var ra: Dictionary = S6.arena_player(s, 0.0, {"db": da})
		var rb: Dictionary = S6.arena_player(s, 0.0, {"db": db2})
		if not S6.require_api(self, ra["w"]):
			return
		S6.run(ra["w"], 40)
		S6.run(rb["w"], 40)
		S6.level_to(ra["w"], ra["p"], 2)
		S6.level_to(rb["w"], rb["p"], 2)
		assert_eq(Array(S6.offer_of(ra["p"])), Array(S6.offer_of(rb["p"])), "seed %d: identical history gives the identical offer" % s)


# ======================================================== the pause

func test_world_is_frozen_while_an_offer_is_open() -> void:
	var r: Dictionary = S6.arena_player(21, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	# an NPC that would wander: its position must not change while paused
	var npc: SimEntity = S3.npc_at(w, &"grouper", S3.ARENA + Vector3(15.0, 0.0, 0.0), 1.5)
	if not S6.require_api(self, w):
		return
	S6.run(w, 10)
	S6.level_to(w, p, 2)
	assert_true(S6.paused(w), "paused after the band-up")
	var tick0: int = w.tick
	var run0: int = w.run_ticks
	var pos0: Vector3 = npc.position
	var hunger0: float = p.hunger
	w.vitals_enabled = true
	S6.run(w, 90)
	assert_eq(w.tick, tick0, "tick does not advance while paused")
	assert_eq(w.run_ticks, run0, "the run timer is frozen while paused")
	assert_eq(npc.position, pos0, "NPCs do not move while paused")
	assert_eq(p.hunger, hunger0, "vitals do not run while paused")
	assert_true(S6.paused(w), "still paused (no pick yet)")
	# advance() (frame-driven loop) must not run ticks either
	w.advance(1.0)
	assert_eq(w.tick, tick0, "tick still frozen after advance()")


func test_pick_applies_resumes_and_clears_the_offer() -> void:
	var r: Dictionary = S6.arena_player(22, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	var offer: PackedStringArray = S6.offer_of(p)
	if offer.is_empty():
		fail("no offer to pick from")
		return
	var choice: String = offer[0]
	var evs: Array[SimEvent] = S6.resolve_pick(w, p.id, choice)
	var picked: Array[SimEvent] = S6.events_named(evs, "MUTATION_PICKED")
	assert_eq(picked.size(), 1, "exactly one MUTATION_PICKED")
	if picked.size() == 1:
		assert_eq(picked[0].entity_id, p.id, "picked event is about the player")
		assert_eq(S6.picked_id(picked[0]), choice, "picked event carries the node id (assumption A2: data.node_id)")
	assert_false(S6.paused(w), "world resumed")
	assert_eq(S6.offer_of(p).size(), 0, "offer cleared")
	assert_eq(Array(S6.mutations_of(p)), [choice], "mutations hold the pick")
	var tick0: int = w.tick
	S6.run(w, 30)
	assert_true(w.tick >= tick0 + 30, "ticks advance again after the pick")
	assert_true(w.run_ticks >= 30, "run timer runs again")


func test_a_grant_node_gives_its_ability_through_the_pick_path() -> void:
	# H1 then H2 (Bite-Dash): the pick path (not a field write) grants the ability.
	var r: Dictionary = S6.arena_player(23, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	S6.resolve_pick(w, p.id, HUNTER_1)
	assert_false(S6.abilities_of(p).has("bite_dash"), "tier 1 does not grant Bite-Dash")
	S6.level_to(w, p, 3)
	assert_true(S6.offer_of(p).has("hunter_bite_dash"), "H2 is available once H1 is owned")
	S6.resolve_pick(w, p.id, "hunter_bite_dash")
	assert_true(S6.abilities_of(p).has("bite_dash"), "hunter_bite_dash grants the bite_dash ability")
	assert_false(S6.abilities_of(p).has("sonar"), "and not sonar")


func test_invalid_picks_are_ignored() -> void:
	var r: Dictionary = S6.arena_player(24, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	var offer0: PackedStringArray = S6.offer_of(p)
	for bad: String in ["no_such_node", "", "hunter_swim_speed", "survivor_wide_vision"]:
		# hunter_swim_speed / survivor_wide_vision exist but are not in the offer
		w.submit(S6.pick_cmd(p.id, bad))
		var out: Array[SimEvent] = []
		var seen: Dictionary = {}
		for i in 2:
			S6.step_collect(w, out, seen)
		assert_eq(S6.count_named(out, "MUTATION_PICKED"), 0, "'%s' does not produce MUTATION_PICKED" % bad)
		assert_true(S6.paused(w), "'%s' does not resume the world" % bad)
		assert_eq(Array(S6.offer_of(p)), Array(offer0), "'%s' leaves the offer untouched" % bad)
		assert_eq(S6.mutations_of(p).size(), 0, "'%s' grants nothing" % bad)


func test_a_pick_without_an_open_offer_is_ignored() -> void:
	var r: Dictionary = S6.arena_player(25, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	w.submit(S6.pick_cmd(p.id, HUNTER_1))
	var evs: Array[SimEvent] = S6.run(w, 5)
	assert_eq(S6.count_named(evs, "MUTATION_PICKED"), 0, "no offer, no pick")
	assert_eq(S6.mutations_of(p).size(), 0, "nothing granted without an offer")
	assert_false(S6.paused(w), "not paused")


func test_an_owned_node_cannot_be_picked_twice() -> void:
	var r: Dictionary = S6.arena_player(26, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	S6.resolve_pick(w, p.id, HUNTER_1)
	S6.level_to(w, p, 3)
	w.submit(S6.pick_cmd(p.id, HUNTER_1))
	var out: Array[SimEvent] = []
	var seen: Dictionary = {}
	for i in 2:
		S6.step_collect(w, out, seen)
	assert_eq(S6.count_named(out, "MUTATION_PICKED"), 0, "an owned node is not in the offer, so the pick is ignored")
	assert_eq(S6.mutations_of(p).count(HUNTER_1), 1, "owned once")


# ======================================================== once per band, at most three per run

func test_a_band_regained_after_a_death_does_not_offer_again() -> void:
	var r: Dictionary = S6.arena_player(31, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	S6.resolve_pick(w, p.id, HUNTER_1)
	# die: death_xp_loss_frac of the XP is lost, the player falls back to B1
	p.hp = 0.0
	var evs: Array[SimEvent] = S6.run(w, 3)
	assert_eq(S6.count_named(evs, "DIED"), 1, "test setup: the player died")
	assert_eq(p.band, 1, "test setup: back at B1 (xp loss %s)" % str(S3.rule_f(w.content, "death_xp_loss_frac")))
	# respawn, then regain B2
	S6.run(w, S3.ticks(S3.rule_f(w.content, "respawn_delay_s")) + 5)
	assert_true(p.alive, "test setup: respawned")
	var again: Array[SimEvent] = S6.level_to(w, p, 2)
	assert_eq(S6.count_named(again, "BAND_UP"), 1, "test setup: BAND_UP B1->B2 again")
	assert_eq(S6.count_named(again, "MUTATION_OFFERED"), 0, "no second offer for a band already offered")
	assert_false(S6.paused(w), "the world does not pause for a regained band")
	assert_eq(S6.offer_of(p).size(), 0, "no pending offer")
	# the next new band still offers
	var b3: Array[SimEvent] = S6.level_to(w, p, 3)
	assert_eq(S6.count_named(b3, "MUTATION_OFFERED"), 1, "B3 is a new band: offered")
	assert_true(S6.paused(w), "paused for B3")


func test_at_most_three_picks_per_run() -> void:
	var r: Dictionary = S6.arena_player(32, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var offers: int = 0
	var picks: int = 0
	for band in range(2, 5):
		var evs: Array[SimEvent] = S6.level_to(w, p, band)
		offers += S6.count_named(evs, "MUTATION_OFFERED")
		var offer: PackedStringArray = S6.offer_of(p)
		if offer.is_empty():
			break
		var pk: Array[SimEvent] = S6.resolve_pick(w, p.id, offer[0])
		picks += S6.count_named(pk, "MUTATION_PICKED")
	assert_eq(offers, 3, "one offer per band-up B1->B2, B2->B3, B3->B4")
	assert_eq(picks, 3, "three picks")
	# more XP, deaths and regained bands: nothing more is offered
	p.xp = 5000.0
	var later: Array[SimEvent] = S6.run(w, 30)
	assert_eq(S6.count_named(later, "MUTATION_OFFERED"), 0, "no offer beyond B4")
	for i in 2:
		p.hp = 0.0
		S6.run(w, 3)
		S6.run(w, S3.ticks(S3.rule_f(w.content, "respawn_delay_s")) + 5)
		for band in range(2, 5):
			later.append_array(S6.level_to(w, p, band))
	assert_eq(S6.count_named(later, "MUTATION_OFFERED"), 0, "no offer after deaths and regained bands")
	assert_eq(S6.mutations_of(p).size(), 3, "three mutations at the end of the run")
	assert_false(S6.paused(w), "not paused")


func test_a_pending_offer_survives_to_the_pick_even_if_the_player_is_idle_for_long() -> void:
	var r: Dictionary = S6.arena_player(33, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	var offer: PackedStringArray = S6.offer_of(p)
	S6.run(w, 3000)
	assert_eq(Array(S6.offer_of(p)), Array(offer), "the offer is not re-rolled or dropped while waiting")
	assert_true(S6.paused(w), "still paused")
