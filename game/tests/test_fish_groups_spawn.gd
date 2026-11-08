extends TestCase
## Fish packs, spawning (NpcSpawner, map `spawners[].group` {min, max, chance, radius_m}): on the first tick a grouped
## spawner cuts its target into packs (world RNG: chance -> range_int(min, max) members clipped to what is left, else a
## single NPC); members spawn within radius_m of the pack leader; same seed = same packs; no `group` = packs of one.
## Controlled worlds (one hand-written spawner, npc_scale 1, no caps) so the counts are exact.

const B := preload("res://tests/s3brain_support.gd")
const RULES: Dictionary = {"npc_scale": 1.0, "tiers.interactive_cap": 100000, "tiers.large_cap": 100000}
const GROUPED: Array[String] = ["puffer", "barracuda", "grouper"]


static func _rec(species: String, zone: String, count: int, group: Dictionary, respawn_s: float = 5.0) -> Dictionary:
	var r: Dictionary = B.spawner(species, zone, count, respawn_s)
	if not group.is_empty():
		r["group"] = group
	return r


func _world(world_seed: int, records: Array) -> SimWorld:
	var w: SimWorld = B.make_world(world_seed, {"spawn": true, "spawners": records, "rules": RULES})
	w.step()
	return w


## Pack sizes in pack order (all packs of the world).
func _sizes(w: SimWorld) -> Array[int]:
	var out: Array[int] = []
	for p in NpcSpawner.pack_count(w):
		out.append(NpcSpawner.pack_members(w, p).size())
	return out


func test_pack_sizes_stay_in_bounds_and_sum_to_the_target() -> void:
	for world_seed in [1, 2, 3, 4, 5]:
		var w: SimWorld = _world(world_seed, [_rec("puffer", "rock_arches", 31, {"min": 3, "max": 4, "chance": 0.6, "radius_m": 2.5})])
		var sizes: Array[int] = _sizes(w)
		var total: int = 0
		var grouped: int = 0
		for k in sizes.size():
			total += sizes[k]
			if sizes[k] > 1:
				grouped += 1
			assert_true(sizes[k] >= 1 and sizes[k] <= 4, "seed %d pack %d: size %d in 1..max" % [world_seed, k, sizes[k]])
			if k < sizes.size() - 1:
				assert_true(sizes[k] == 1 or sizes[k] >= 3, "seed %d pack %d: size %d is 1 or in min..max (only the last pack is clipped)" % [world_seed, k, sizes[k]])
		assert_eq(total, 31, "seed %d: the packs hold exactly the target" % world_seed)
		assert_eq(NpcSpawner.target_count(w, 0), 31, "the target is unchanged by grouping")
		assert_true(grouped >= 2, "seed %d: chance 0.6 forms several packs (got %d of %s)" % [world_seed, grouped, sizes])


func test_chance_one_groups_everything_and_chance_zero_nothing() -> void:
	var all: SimWorld = _world(6, [_rec("barracuda", "open_water", 12, {"min": 2, "max": 4, "chance": 1.0, "radius_m": 5})])
	var sizes: Array[int] = _sizes(all)
	for k in sizes.size() - 1:
		assert_true(sizes[k] >= 2, "chance 1: pack %d has %d members (>= min)" % [k, sizes[k]])
	var none: SimWorld = _world(6, [_rec("barracuda", "open_water", 12, {"min": 2, "max": 4, "chance": 0.0, "radius_m": 5})])
	assert_eq(_sizes(none).size(), 12, "chance 0: 12 packs of one")


func test_no_group_key_means_packs_of_one_without_a_leader() -> void:
	var w: SimWorld = _world(7, [_rec("barracuda", "open_water", 10, {}), _rec("shark", "open_water", 3, {})])
	assert_eq(NpcSpawner.pack_count(w), 13, "every NPC is its own pack")
	for e in B.npcs(w):
		assert_eq(NpcSpawner.pack_leader(w, e.id), -1, "%s %d follows nobody" % [e.species_id, e.id])
		assert_eq(NpcSpawner.pack_radius_m(w, e.id), 0.0, "and has no pack radius")


func test_members_spawn_next_to_their_leader() -> void:
	var r: float = 5.0
	var w: SimWorld = _world(8, [_rec("barracuda", "kelp_forest", 20, {"min": 2, "max": 4, "chance": 1.0, "radius_m": r})])
	var checked: int = 0
	for p in NpcSpawner.pack_count(w):
		var m: Array[int] = NpcSpawner.pack_members(w, p)
		var leader: SimEntity = w.get_entity(m[0])
		for id in m.slice(1):
			var e: SimEntity = w.get_entity(id)
			# square +-r horizontally, +-r/2 vertically, one tick of swimming and a seabed push of slack
			assert_true(e.position.distance_to(leader.position) <= r * 1.6 + 1.0, "member %d is %.2f m from its leader" % [id, e.position.distance_to(leader.position)])
			assert_eq(NpcSpawner.pack_leader(w, id), leader.id, "member %d follows the lowest-id member %d" % [id, leader.id])
			assert_almost_eq(NpcSpawner.pack_radius_m(w, id), r, 1e-9, "pack radius from the spawner record")
			assert_eq(NpcSpawner.home_zone_index(w, id), NpcSpawner.home_zone_index(w, leader.id), "same home zone as the leader")
			checked += 1
		assert_eq(NpcSpawner.pack_leader(w, leader.id), -1, "the leader follows nobody")
	assert_true(checked >= 8, "followers were checked (%d)" % checked)


func test_same_seed_same_packs_and_another_seed_differs() -> void:
	var runs: Array = []
	for world_seed in [9, 9, 10]:
		var w: SimWorld = _world(world_seed, [_rec("puffer", "shallows", 24, {"min": 2, "max": 4, "chance": 0.5, "radius_m": 2.5})])
		var pos: Array[Vector3] = []
		for e in B.npcs(w):
			pos.append(e.position)
		runs.append([_sizes(w), pos, w.state_hash()])
	assert_eq(runs[0][0], runs[1][0], "same seed: same pack sizes")
	assert_true(runs[0][1] == runs[1][1], "same seed: same positions")
	assert_eq(runs[0][2], runs[1][2], "same seed: same state hash")
	assert_true(runs[0][0] != runs[2][0] or runs[0][1] != runs[2][1], "another seed: other packs or positions")


func test_the_shipped_spawners_group_puffer_barracuda_grouper_and_never_sharks() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for s: Variant in (db.get_map(B.MAP_ID)["spawners"] as Array):
		var sid: String = str(s["species_id"])
		if GROUPED.has(sid):
			assert_true(s.get("group") is Dictionary, "%s in %s has a group block" % [sid, s["zone_id"]])
		else:
			assert_false((s as Dictionary).has("group"), "%s in %s stays solo (Director: sharks and the boss unchanged)" % [sid, s["zone_id"]])
	var formed: Dictionary = {}
	for world_seed in [1, 2, 3]:
		var w: SimWorld = B.make_world(world_seed, {"spawn": true})
		w.step()
		for p in NpcSpawner.pack_count(w):
			var m: Array[int] = NpcSpawner.pack_members(w, p)
			var sid: String = String(w.get_entity(m[0]).species_id)
			if m.size() > 1:
				formed[sid] = true
				assert_true(GROUPED.has(sid), "only grouped species form packs (%s)" % sid)
				assert_true(m.size() <= 4, "%s pack of %d <= 4" % [sid, m.size()])
				if sid == "grouper":
					assert_eq(m.size(), 2, "groupers come in pairs")
	for sid: String in GROUPED:
		assert_true(formed.has(sid), "%s forms at least one pack over seeds 1-3" % sid)
