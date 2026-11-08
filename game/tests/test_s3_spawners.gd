extends TestCase
## S3 spawners (NpcSpawner.tick inside SimWorld.step): per (species, zone) records in map.spawners keep `count`
## creatures alive (scaled by rules.npc_scale, capped per tier by rules.tiers.interactive_cap / large_cap), refill after
## `respawn_s`, and place them inside the zone AABB above the seabed from the world RNG.
## S4: the shipped map lists only the non-schooling species as spawners (schooling species are SchoolSystem schools,
## plankton is the PlanktonField), so the shipped-population tests check those five species and the per-tier caps.
## Most tests run a CONTROLLED world: one hand-written spawner record, scale 1.0 and a huge cap, so the expected
## counts are exact whatever the shipped balance is. The real-data tests (end of the file) assert only what the task
## states: all 8 species present, "a few dozen" NPCs, the cap respected, never more than the data count.

const S3 := preload("res://tests/s3_support.gd")
const CONTROLLED_RULES: Dictionary = {"npc_scale": 1.0, "tiers.interactive_cap": 1000, "tiers.large_cap": 1000}


func _spawner_rec(species: String, zone: String, count: int, respawn_s: float) -> Dictionary:
	return {"species_id": species, "zone_id": zone, "count": count, "respawn_s": respawn_s}


func _world(world_seed: int, records: Array, rules: Dictionary = CONTROLLED_RULES) -> SimWorld:
	return S3.make_world(world_seed, {"spawners": records, "rules": rules})


## Steps until `species` has `want` living creatures (at most `limit` ticks); returns the count then.
func _fill(w: SimWorld, species: StringName, want: int, limit: int = 5) -> int:
	for i in limit:
		w.step()
		if S3.species_count(w, species) >= want:
			break
	return S3.species_count(w, species)


# ======================================================== count and placement

func test_a_spawner_fills_its_zone_to_the_configured_count_and_keeps_it() -> void:
	var w: SimWorld = _world(3, [_spawner_rec("puffer", "rock_arches", 12, 5.0)])
	assert_eq(_fill(w, &"puffer", 12), 12, "12 puffers appear within a few ticks")
	for sample in 10:
		S3.step_n(w, 30)
		assert_eq(S3.species_count(w, &"puffer"), 12, "still exactly 12 puffers after %d s" % (sample + 1))
	for e: SimEntity in S3.creatures(w):
		assert_eq(e.kind, SimEntity.Kind.CREATURE, "spawned entities are creatures")
		assert_false(e.is_player, "and not players")
		assert_true(w.grid.has(e.id), "and in the grid")


func test_spawn_positions_are_inside_the_zone_box_and_above_the_seabed() -> void:
	var w: SimWorld = _world(4, [_spawner_rec("puffer", "rock_arches", 120, 5.0)])
	var n: int = _fill(w, &"puffer", 120)
	assert_eq(n, 120, "120 puffers spawned")
	var box: Array[Vector3] = S3.zone_box(w, "rock_arches")
	assert_eq(box.size(), 2, "zone box found")
	if box.size() != 2:
		return
	var below: int = 0
	var outside: int = 0
	for e: SimEntity in S3.creatures(w):
		if not S3.inside_box(e.position, box[0], box[1], 0.5):
			outside += 1
		if e.position.y <= w.seabed.height_at(e.position.x, e.position.z):
			below += 1
		assert_true(e.position.y < 0.0, "below the surface")
	assert_eq(outside, 0, "no spawn outside the rock_arches AABB (%d of 120)" % outside)
	assert_eq(below, 0, "no spawn inside the seabed (%d of 120); the zone AABB reaches under the floor, so naive sampling fails" % below)


func test_spawned_creatures_have_species_lengths_and_formula_hp() -> void:
	var w: SimWorld = _world(5, [_spawner_rec("barracuda", "open_water", 10, 5.0)])
	assert_eq(_fill(w, &"barracuda", 10), 10, "10 barracuda")
	var lm: Dictionary = w.content.get_species(&"barracuda")["length_m"]
	var lengths: Dictionary = {}
	for e: SimEntity in S3.creatures(w):
		assert_true(e.length_m >= float(lm["min"]) - 1e-9 and e.length_m <= float(lm["max"]) + 1e-9, "length %s inside the species range" % e.length_m)
		assert_almost_eq(e.max_hp, 100.0 * e.length_m * e.length_m, 1e-6, "max_hp = base_hp x length^2")
		assert_almost_eq(e.hp, e.max_hp, 1e-9, "spawned at full health")
		lengths[snappedf(e.length_m, 0.0001)] = true
	assert_true(lengths.size() >= 5, "lengths vary across individuals (%d distinct of 10)" % lengths.size())


func test_two_zones_of_one_species_get_their_own_counts() -> void:
	var w: SimWorld = _world(6, [_spawner_rec("puffer", "shallows", 5, 5.0), _spawner_rec("puffer", "rock_arches", 7, 5.0)])
	assert_eq(_fill(w, &"puffer", 12), 12, "12 puffers in total")
	var shallows: Array[Vector3] = S3.zone_box(w, "shallows")
	var arches: Array[Vector3] = S3.zone_box(w, "rock_arches")
	var in_shallows: int = 0
	var in_arches: int = 0
	for e: SimEntity in S3.creatures(w):
		if S3.inside_box(e.position, shallows[0], shallows[1], 0.5):
			in_shallows += 1
		if S3.inside_box(e.position, arches[0], arches[1], 0.5):
			in_arches += 1
	assert_eq(in_shallows, 5, "5 in the shallows")
	assert_eq(in_arches, 7, "7 in the rock arches")


func test_the_same_seed_gives_the_same_placements_and_another_seed_differs() -> void:
	var positions: Array = []
	for world_seed in [8, 8, 9]:
		var w: SimWorld = _world(int(world_seed), [_spawner_rec("puffer", "rock_arches", 20, 5.0)])
		_fill(w, &"puffer", 20)
		var list: Array = []
		for e: SimEntity in S3.creatures(w):
			list.append(e.position)
		positions.append(list)
	assert_eq(positions[0].size(), 20, "20 spawned")
	assert_true(positions[0] == positions[1], "same seed, identical positions (world RNG only)")
	assert_true(positions[0] != positions[2], "different seed, different positions")


# ======================================================== respawn, scale, cap

func test_killed_creatures_come_back_after_respawn_s_and_not_before() -> void:
	var respawn_s: float = 5.0
	var w: SimWorld = _world(7, [_spawner_rec("puffer", "rock_arches", 6, respawn_s)])
	assert_eq(_fill(w, &"puffer", 6), 6, "6 puffers")
	S3.step_n(w, 10)
	var doomed: Array[SimEntity] = S3.creatures(w)
	for i in 3:
		doomed[i].hp = 0.0
	S3.step_n(w, 2)
	assert_eq(S3.species_count(w, &"puffer"), 3, "3 died and are not replaced at once")
	var kill_tick: int = w.tick
	var delay: int = S3.ticks(respawn_s)
	S3.step_n(w, delay - 30)
	assert_eq(S3.species_count(w, &"puffer"), 3, "one second before respawn_s the zone is still short")
	S3.step_n(w, 90)
	assert_eq(S3.species_count(w, &"puffer"), 6, "a second after respawn_s all 3 are back (tick %d, killed at %d)" % [w.tick, kill_tick])
	S3.step_n(w, 300)
	assert_eq(S3.species_count(w, &"puffer"), 6, "and the count stays at 6")


func test_the_population_never_exceeds_the_configured_count() -> void:
	var w: SimWorld = _world(11, [_spawner_rec("puffer", "rock_arches", 12, 2.0)])
	for sample in 30:
		S3.step_n(w, 30)
		var n: int = S3.species_count(w, &"puffer")
		assert_true(n <= 12, "never more than 12 puffers (got %d at second %d)" % [n, sample])
		if sample == 10:
			for e: SimEntity in S3.creatures(w):
				e.hp = 0.0  # wipe the zone: the next spawns must refill to exactly 12
	assert_eq(S3.species_count(w, &"puffer"), 12, "refilled to exactly 12 after a wipe")


func test_the_interactive_cap_limits_the_population() -> void:
	var w: SimWorld = _world(12, [_spawner_rec("puffer", "rock_arches", 50, 2.0)], {"npc_scale": 1.0, "tiers.interactive_cap": 10})
	S3.step_n(w, 120)
	assert_eq(S3.species_count(w, &"puffer"), 10, "count 50 with tiers.interactive_cap 10 gives 10")


func test_the_npc_scale_multiplies_the_count() -> void:
	var w: SimWorld = _world(13, [_spawner_rec("puffer", "rock_arches", 20, 2.0)], {"npc_scale": 0.25, "tiers.interactive_cap": 1000})
	S3.step_n(w, 120)
	assert_eq(S3.species_count(w, &"puffer"), 5, "count 20 x scale 0.25 = 5")


# ======================================================== shipped population (task statement level)

func test_the_shipped_map_populates_all_eight_species_within_the_cap() -> void:
	# S4: the five spawner species are entities, the two schooling species are schools, plankton is the field.
	var w: SimWorld = S3.make_world(21, {"real_spawners": true})
	S3.step_n(w, 60)
	var caps: Dictionary = {"interactive": int(S3.rule_f(w.content, "tiers.interactive_cap")), "large": int(S3.rule_f(w.content, "tiers.large_cap"))}
	assert_true(caps["interactive"] >= 1 and caps["large"] >= 1, "rules.tiers caps are set (got %s)" % caps)
	var total: int = S3.creatures(w).size()
	assert_true(total >= 24, "'a few dozen' NPCs exist (got %d)" % total)
	var counts: Dictionary = {}
	var per_tier: Dictionary = {"interactive": 0, "large": 0}
	for e: SimEntity in S3.creatures(w):
		var key: String = String(e.species_id)
		counts[key] = int(counts.get(key, 0)) + 1
		var tier: String = String(w.content.get_species(e.species_id).get("tier", ""))
		if per_tier.has(tier):
			per_tier[tier] += 1
	var school_species: Dictionary = {}
	for i in w.schools.school_count():
		school_species[String(w.schools.get_school(i).species_id)] = true
	for sid: StringName in w.content.species_ids():
		var present: bool = int(counts.get(String(sid), 0)) >= 1 or school_species.has(String(sid)) or (w.plankton != null and w.plankton.species_id == sid)
		for kf: PlanktonField in w.krill:
			present = present or kf.species_id == sid
		assert_true(present, "species %s is present in the shipped population (entity, school, plankton or krill field)" % sid)
	for tier: String in per_tier:
		assert_true(per_tier[tier] <= caps[tier], "%s NPCs: %d <= cap %d" % [tier, per_tier[tier], caps[tier]])
	# Never more of a species than the data allows (unscaled sum of its records).
	var allowed: Dictionary = {}
	for rec_v: Variant in (w.map["spawners"] as Array):
		var rec: Dictionary = rec_v
		var sid2: String = String(rec["species_id"])
		allowed[sid2] = int(allowed.get(sid2, 0)) + int(rec["count"])
	for sid_v: Variant in counts.keys():
		assert_true(int(counts[sid_v]) <= int(allowed.get(String(sid_v), 0)), "%s: %d alive <= data total %d" % [sid_v, counts[sid_v], allowed.get(String(sid_v), 0)])


func test_the_boss_spawns_in_the_abyss() -> void:
	var w: SimWorld = S3.make_world(21, {"real_spawners": true})
	_fill(w, &"giant_shark", 1, 10)
	assert_eq(S3.species_count(w, &"giant_shark"), 1, "exactly one giant shark")
	var abyss: Array[Vector3] = S3.zone_box(w, "abyss")
	for e: SimEntity in S3.creatures(w):
		if e.species_id == &"giant_shark":
			assert_true(S3.inside_box(e.position, abyss[0], abyss[1], 1.0), "the boss starts inside the abyss zone (at %s)" % e.position)


func test_the_shipped_population_stays_within_the_cap_over_time() -> void:
	var w: SimWorld = S3.make_world(22, {"real_spawners": true})
	var caps: Dictionary = {"interactive": int(S3.rule_f(w.content, "tiers.interactive_cap")), "large": int(S3.rule_f(w.content, "tiers.large_cap"))}
	for sample in 10:
		S3.step_n(w, 60)
		var per_tier: Dictionary = {"interactive": 0, "large": 0}
		for e: SimEntity in S3.creatures(w):
			var tier: String = String(w.content.get_species(e.species_id).get("tier", ""))
			if per_tier.has(tier):
				per_tier[tier] += 1
		for tier: String in per_tier:
			assert_true(per_tier[tier] <= caps[tier], "%s NPCs %d <= cap %d at second %d" % [tier, per_tier[tier], caps[tier], (sample + 1) * 2])
