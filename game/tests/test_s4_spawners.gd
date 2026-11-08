extends TestCase
## S4 spawners (contract "Spawners"): NpcSpawner now keeps only NON-schooling interactive and large species
## (puffer, barracuda, grouper, shark, giant shark) at count x rules.npc_scale; schooling species and plankton come from
## map.schools / map.plankton and are never spawned as entities by the spawner. Population bounds: alive <= target at
## every tick; a loss is replaced exactly respawn_s later; caps come from tiers.interactive_cap / tiers.large_cap.
## Controlled worlds: one hand-written spawner record, npc_scale 1.0 (S4.make_world), so counts are exact whatever the
## shipped balance is. The shipped-data tests assert only structural facts and the caps.

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")


func _world(world_seed: int, records: Array, opts: Dictionary = {}) -> SimWorld:
	var o: Dictionary = opts.duplicate()
	o["spawners"] = records
	return S4.make_world(world_seed, o)


func _fill(w: SimWorld, species: StringName, want: int, limit: int = 5) -> int:
	for i in limit:
		w.step()
		if S3.species_count(w, species) >= want:
			break
	return S3.species_count(w, species)


# ======================================================== bounds and respawn (controlled)

func test_alive_never_exceeds_the_target_and_a_wiped_zone_refills_to_it() -> void:
	var w: SimWorld = _world(81, [S4.spawner_rec("puffer", S4.KELP, 12, 2.0)])
	assert_eq(_fill(w, &"puffer", 12), 12, "12 puffers appear within a few ticks")
	for tick_i in 900:
		w.step()
		var n: int = S3.species_count(w, &"puffer")
		assert_true(n <= 12, "alive %d <= target 12 at tick %d" % [n, tick_i])
		if tick_i == 300:
			for e: SimEntity in S3.creatures(w):
				e.hp = 0.0
	assert_eq(S3.species_count(w, &"puffer"), 12, "refilled to exactly 12 after the wipe")


func test_a_loss_is_replaced_exactly_respawn_s_later() -> void:
	var respawn_s: float = 5.0
	var w: SimWorld = _world(82, [S4.spawner_rec("puffer", S4.KELP, 6, respawn_s)])
	assert_eq(_fill(w, &"puffer", 6), 6, "6 puffers")
	S3.step_n(w, 10)
	var doomed: Array[SimEntity] = S3.creatures(w)
	for i in 3:
		doomed[i].hp = 0.0
	var kill_tick: int = w.tick
	var delay: int = S3.ticks(respawn_s)
	var back_at: int = -1
	for i in delay + 90:
		w.step()
		if back_at < 0 and S3.species_count(w, &"puffer") == 6:
			back_at = w.tick - 1
		if back_at < 0:
			assert_true(S3.species_count(w, &"puffer") <= 3, "no early replacement at tick +%d" % (w.tick - kill_tick))
	assert_true(back_at >= 0, "the zone refilled")
	assert_true(absi((back_at - kill_tick) - delay) <= 3, "refilled %d ticks after the loss, expected %d (respawn_s %.1f)" % [back_at - kill_tick, delay, respawn_s])


func test_npc_scale_multiplies_the_count() -> void:
	var w: SimWorld = _world(83, [S4.spawner_rec("puffer", S4.KELP, 20, 2.0)], {"rules": {"npc_scale": 0.25}})
	S3.step_n(w, 120)
	assert_eq(S3.species_count(w, &"puffer"), 5, "count 20 x npc_scale 0.25 = 5")


func test_spawned_npcs_are_plain_entities_without_a_school() -> void:
	var w: SimWorld = _world(84, [S4.spawner_rec("barracuda", S4.KELP, 6, 5.0)])
	assert_eq(_fill(w, &"barracuda", 6), 6, "6 barracuda")
	for e: SimEntity in S3.creatures(w):
		assert_not_null(e.get("school_id"), "SimEntity.school_id exists (contract)")
		assert_not_null(e.get("school_member"), "SimEntity.school_member exists (contract)")
		assert_not_null(e.get("school_since_tick"), "SimEntity.school_since_tick exists (impl-A)")
		assert_eq(S4.school_id_of(e), -1, "spawner NPCs have school_id -1")
		assert_eq(S4.school_member_of(e), -1, "and school_member -1")


# ======================================================== who the spawner is allowed to spawn

func test_schooling_species_and_plankton_in_spawner_records_are_not_spawned() -> void:
	var recs: Array = [
		S4.spawner_rec("silver_schooling_fish", S4.SHALLOWS, 50, 5.0),
		S4.spawner_rec("small_reef_fish", S4.SHALLOWS, 20, 5.0),
		S4.spawner_rec("plankton", S4.SHALLOWS, 30, 5.0),
		S4.spawner_rec("puffer", S4.KELP, 3, 5.0),
	]
	var w: SimWorld = _world(85, recs)
	S3.step_n(w, 90)
	assert_eq(S3.species_count(w, S4.SILVER), 0, "NpcSpawner does not spawn silver fish (schools do)")
	assert_eq(S3.species_count(w, S4.REEF_FISH), 0, "nor small reef fish")
	assert_eq(S3.species_count(w, &"plankton"), 0, "nor plankton entities (map.plankton does)")
	assert_eq(S3.species_count(w, &"puffer"), 3, "the non-schooling record is honoured")


func test_the_shipped_spawner_records_hold_only_non_schooling_interactive_and_large_species() -> void:
	var db: ContentDB = S3.content()
	var recs: Array = db.get_map(S3.MAP_ID)["spawners"]
	assert_true(recs.size() > 0, "the map still has spawners (puffers, predators, boss)")
	var seen: Dictionary = {}
	for r_v: Variant in recs:
		var r: Dictionary = r_v
		var sid: StringName = StringName(String(r["species_id"]))
		seen[String(sid)] = true
		var sp: Dictionary = db.get_species(sid)
		assert_false(sp.is_empty(), "%s exists" % sid)
		assert_false(bool(sp.get("schooling", false)), "%s is not a schooling species" % sid)
		assert_true(["interactive", "large"].has(String(sp.get("tier", ""))), "%s has tier interactive or large, not ambient" % sid)
	for must: String in ["puffer", "barracuda", "grouper", "shark", "giant_shark"]:
		assert_true(seen.has(must), "%s is still spawner-driven" % must)
	# Every schooling species lives in map.schools instead.
	var in_schools: Dictionary = {}
	for s_v: Variant in db.get_map(S3.MAP_ID).get("schools", []):
		in_schools[String((s_v as Dictionary)["species_id"])] = true
	for sid2: StringName in db.species_ids():
		if bool(db.get_species(sid2).get("schooling", false)):
			assert_true(in_schools.has(String(sid2)), "schooling species %s has a map.schools record" % sid2)


# ======================================================== caps

func test_interactive_and_large_caps_bound_the_spawners() -> void:
	var recs: Array = [S4.spawner_rec("puffer", S4.KELP, 50, 2.0), S4.spawner_rec("grouper", "rock_arches", 30, 2.0), S4.spawner_rec("shark", "open_water", 20, 2.0)]
	var w: SimWorld = _world(86, recs, {"tiers": {"interactive_cap": 10, "large_cap": 4}})
	var worst_i: int = 0
	var worst_l: int = 0
	for i in 240:
		w.step()
		worst_i = maxi(worst_i, S4.creatures_of_tier(w, "interactive").size())
		worst_l = maxi(worst_l, S4.creatures_of_tier(w, "large").size())
	assert_true(worst_i <= 10, "interactive entities never above tiers.interactive_cap (10), saw %d" % worst_i)
	assert_true(worst_l <= 4, "large actors never above tiers.large_cap (4), saw %d" % worst_l)
	assert_eq(worst_i, 10, "and the interactive cap is actually reached (50 puffers wanted)")
	assert_eq(worst_l, 4, "and the large cap is actually reached (50 large wanted)")


# ======================================================== shipped population

func test_the_shipped_world_splits_into_schools_and_a_capped_set_of_entities() -> void:
	var w: SimWorld = S4.make_world(87, {"real": true})
	S4.run(w, 90)
	var interactive_cap: int = int(S4.tier_f(w, "interactive_cap"))
	var large_cap: int = int(S4.tier_f(w, "large_cap"))
	assert_true(interactive_cap >= 1 and large_cap >= 1, "data: tiers.interactive_cap %d and tiers.large_cap %d" % [interactive_cap, large_cap])
	var allowed: Dictionary = {}
	for r_v: Variant in (w.map["spawners"] as Array):
		var r: Dictionary = r_v
		allowed[String(r["species_id"])] = int(allowed.get(String(r["species_id"]), 0)) + int(r["count"])
	var counts: Dictionary = {}
	for e: SimEntity in S3.creatures(w):
		counts[String(e.species_id)] = int(counts.get(String(e.species_id), 0)) + 1
		assert_ne(String(e.species_id), "plankton", "no plankton entity")
		assert_false(S4.species_schooling(w.content, e.species_id), "no schooling-species entity without a player (members stay ambient)")
	for sid: String in counts.keys():
		assert_true(int(counts[sid]) <= int(allowed.get(sid, 0)), "%s: %d alive <= data count %d" % [sid, counts[sid], allowed.get(sid, 0)])
	assert_true(S4.creatures_of_tier(w, "interactive").size() <= interactive_cap, "interactive entities within the cap")
	assert_true(S4.creatures_of_tier(w, "large").size() <= large_cap, "large actors within the cap")
	assert_true(S3.species_count(w, &"giant_shark") == 1, "the boss spawns")
	assert_true(S4.school_count(w) >= 1, "schools exist")


func test_a_player_among_the_schools_never_pushes_the_shipped_world_past_the_caps() -> void:
	var w: SimWorld = S4.make_world(88, {"real": true})
	var school: Object = S4.get_school(w, 0)
	if school == null:
		fail("S4 API missing: SimWorld.schools / get_school")
		return
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(school, world.tick))
	var interactive_cap: int = int(S4.tier_f(w, "interactive_cap"))
	var large_cap: int = int(S4.tier_f(w, "large_cap"))
	var peak_promoted: int = 0
	for sample in 20:
		S4.run(w, 45, pre)
		var i_n: int = S4.creatures_of_tier(w, "interactive").size()
		var l_n: int = S4.creatures_of_tier(w, "large").size()
		peak_promoted = maxi(peak_promoted, S4.promoted_entities(w).size())
		assert_true(i_n <= interactive_cap, "interactive %d <= cap %d at second %d" % [i_n, interactive_cap, (sample + 1) * 3 / 2])
		assert_true(l_n <= large_cap, "large %d <= cap %d at second %d" % [l_n, large_cap, (sample + 1) * 3 / 2])
	assert_true(peak_promoted >= 1, "the player pulled members out of the school form during the run")
	assert_eq(S4.invariants(w), "", "school bookkeeping consistent in the full world")


# ======================================================== the population switch (impl-A contract delta 2)

## NpcSpawner.set_enabled(world, true) is the ONE switch of the population: spawners, the schools phase (promotion,
## respawns) and plankton grazing. Without it the world is the bare map: schools exist (static, hashed) but nothing is
## promoted, nothing respawns, nobody grazes, nothing is spawned.
func test_without_the_population_switch_schools_are_static_and_nobody_grazes() -> void:
	var w: SimWorld = S4.make_world(89, {"real": true, "population": false})
	assert_true(S4.school_count(w) >= 1, "schools exist in a world without the population switch")
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(school, world.tick))
	var evs: Array[SimEvent] = S4.run(w, 120, pre)
	assert_eq(S4.school_events(evs).size(), 0, "no promotion without the switch, although a player sits in the school")
	assert_eq(S4.events_named(evs, "PLANKTON_EATEN").size(), 0, "and no grazing")
	assert_eq(w.entity_count(), 1, "and no spawner NPC: only the player exists")
	assert_eq(S4.ambient_count(school), S4.size_of(school), "every member is in the school form")
	# Switching it on starts the population.
	NpcSpawner.set_enabled(w, true)
	var evs2: Array[SimEvent] = S4.run(w, S4.period(w) + 4, pre)
	assert_true(S4.events_named(evs2, "SCHOOL_MEMBER_PROMOTED").size() >= 1, "the switch turns promotion on")
	assert_true(w.entity_count() > 2, "and the spawners")


func test_the_population_counts_by_tier_follow_the_entities() -> void:
	var w: SimWorld = S4.make_world(90, {"real": true})
	var pid: int = S4.player_at_school(w, 0).id
	var school: Object = S4.get_school(w, 0)
	S4.run(w, 120, func(world: SimWorld) -> void: S4.pin(world, pid, S4.center_at(school, world.tick)))
	assert_eq(w.npc_count(SimWorld.TIER_INTERACTIVE), S4.creatures_of_tier(w, "interactive").size(), "npc_count(TIER_INTERACTIVE) = living interactive creatures")
	assert_eq(w.npc_count(SimWorld.TIER_LARGE), S4.creatures_of_tier(w, "large").size(), "npc_count(TIER_LARGE) = living large creatures")
	assert_eq((w.schools as Object).call("promoted_count"), S4.promoted_entities(w).size(), "SchoolSystem.promoted_count() = entities with a school back-reference")
