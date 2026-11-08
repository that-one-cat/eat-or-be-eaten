extends TestCase
## NpcSpawner: off by default; when enabled keeps every map spawner at max(1, round(count x npc_scale)) with the
## interactive-tier spawners capped by tiers.interactive_cap and the large-tier ones by tiers.large_cap (schooling
## and ambient species spawn nothing since S4), places NPCs inside the zone AABB above the seabed (behaviour.seabed_clearance_m) from the world RNG,
## respawns losses after respawn_s (0 = never). S4: the shipped spawners hold only the non-schooling species.

const B := preload("res://tests/s3brain_support.gd")
const TIERS: Array[String] = ["interactive", "large"]


## Reference targets from data (same formula as the class doc).
func _expected_targets(w: SimWorld) -> PackedInt32Array:
	var rules: Dictionary = w.content.rules()
	var scale: float = float(rules.get("npc_scale", 1.0))
	var out := PackedInt32Array()
	for s: Variant in (w.map["spawners"] as Array):
		var sp: Dictionary = w.content.get_species(StringName(str(s["species_id"])))
		var excluded: bool = sp.get("schooling") == true or str(sp.get("tier")) == "ambient"
		out.append(0 if excluded else maxi(1, roundi(float(s["count"]) * scale)))
	for tier: String in TIERS:
		var cap: int = int((rules.get("tiers", {}) as Dictionary).get("%s_cap" % tier, -1))
		var capped: Array[int] = []
		var total: int = 0
		for i in out.size():
			if str(w.content.get_species(StringName(str(w.map["spawners"][i]["species_id"]))).get("tier")) == tier:
				capped.append(i)
				total += out[i]
		if cap < 0 or total <= cap:
			continue
		var want: PackedInt32Array = out.duplicate()
		var rem: Dictionary = {}
		var sum: int = 0
		for i in capped:
			var exact: float = float(out[i]) * float(cap) / float(total)
			out[i] = maxi(1, floori(exact))
			rem[i] = exact - float(out[i])
			sum += out[i]
		while sum > cap:
			var big: int = capped[0]
			for i in capped:
				if out[i] > out[big]:
					big = i
			out[big] -= 1
			sum -= 1
		while sum < cap:
			var best: int = -1
			for i in capped:
				if out[i] < want[i] and (best < 0 or float(rem[i]) > float(rem[best])):
					best = i
			if best < 0:
				break
			out[best] += 1
			rem[best] = float(rem[best]) - 1.0
			sum += 1
	return out


func _count(w: SimWorld, species: StringName, zone_index: int) -> int:
	var n: int = 0
	for e in B.npcs(w):
		if e.species_id == species and NpcSpawner.home_zone_index(w, e.id) == zone_index:
			n += 1
	return n


func _zone_index(w: SimWorld, zone_id: String) -> int:
	var zones: Array = w.map["zones"]
	for i in zones.size():
		if str(zones[i]["id"]) == zone_id:
			return i
	return -1


func test_spawning_is_off_by_default() -> void:
	var w: SimWorld = B.make_world(1)
	B.step_n(w, 3)
	assert_false(NpcSpawner.is_enabled(w), "disabled")
	assert_eq(w.entity_count(), 0, "a plain world stays empty")


func test_shipped_spawners_fill_to_scaled_capped_counts() -> void:
	var w: SimWorld = B.make_world(2, {"spawn": true})
	B.step_n(w, 1)
	var want: PackedInt32Array = _expected_targets(w)
	var spawners: Array = w.map["spawners"]
	var species_seen: Dictionary = {}
	var per_tier: Dictionary = {"interactive": 0, "large": 0}
	for i in spawners.size():
		var sid := StringName(str(spawners[i]["species_id"]))
		assert_eq(NpcSpawner.target_count(w, i), want[i], "spawner %d (%s in %s) target" % [i, sid, spawners[i]["zone_id"]])
		assert_eq(_count(w, sid, _zone_index(w, str(spawners[i]["zone_id"]))), want[i], "spawner %d alive count" % i)
		assert_true(want[i] >= 1, "every spawner keeps at least one")
		species_seen[sid] = true
		var tier: String = str(w.content.get_species(sid).get("tier"))
		if per_tier.has(tier):
			per_tier[tier] += want[i]
	assert_eq(species_seen.size(), 5, "the 5 non-schooling, non-ambient species have spawners (S4)")
	for tier: String in per_tier:
		var cap: int = int((w.content.rules()["tiers"] as Dictionary).get("%s_cap" % tier, -1))
		assert_true(cap < 0 or per_tier[tier] <= cap, "%s NPCs %d <= cap %d" % [tier, per_tier[tier], cap])
	print("S3BRAIN spawner: %d NPCs (%s)" % [B.npcs(w).size(), per_tier])


func test_spawn_positions_are_inside_the_zone_and_above_the_seabed() -> void:
	var w: SimWorld = B.make_world(3, {"spawn": true, "rules": {"npc_scale": 1.0, "tiers.interactive_cap": 100000, "tiers.large_cap": 100000}})
	B.step_n(w, 1)
	var zones: Array = w.map["zones"]
	var bad: Array[String] = []
	for e in B.npcs(w):
		var zi: int = NpcSpawner.home_zone_index(w, e.id)
		var box: AABB = B.zone_box(w, str(zones[zi]["id"]))
		var c: float = B.behaviour_f(w, e.species_id, "seabed_clearance_m")
		# positions after one tick of swimming: allow the distance swum in one tick
		var slack: float = 0.5
		if not box.grow(slack).has_point(e.position):
			bad.append("%s %d outside %s at %s" % [e.species_id, e.id, zones[zi]["id"], e.position])
		if e.position.y < w.seabed.height_at(e.position.x, e.position.z) + c - slack:
			bad.append("%s %d below the clearance at %s" % [e.species_id, e.id, e.position])
		if e.position.y > -c + slack:
			bad.append("%s %d too close to the surface at %s" % [e.species_id, e.id, e.position])
	assert_eq(bad.size(), 0, "%d of %d misplaced:\n  %s" % [bad.size(), B.npcs(w).size(), "\n  ".join(bad.slice(0, 10))])


func test_a_lost_npc_comes_back_after_respawn_s_in_its_zone() -> void:
	var respawn_s: float = 2.0
	var w: SimWorld = B.make_world(4, {"spawn": true, "spawners": [B.spawner("puffer", "rock_arches", 4, respawn_s)], "rules": {"npc_scale": 1.0}})
	B.step_n(w, 1)
	assert_eq(B.npcs(w).size(), 4, "4 puffers")
	w.remove_entity(B.npcs(w)[0].id)
	B.step_n(w, 1)
	var t0: int = w.tick - 1  # the loss was noticed in the last step
	var back: int = B.step_until(w, func() -> bool: return B.npcs(w).size() == 4, B.ticks(respawn_s) + 5)
	assert_true(back >= 0, "refilled within respawn_s")
	var at: int = w.tick - 1
	assert_true(at - t0 >= B.ticks(respawn_s) - 1, "not before respawn_s (lost at tick %d, back at %d)" % [t0, at])
	var newest: SimEntity = B.npcs(w)[3]
	assert_eq(NpcSpawner.home_zone_index(w, newest.id), _zone_index(w, "rock_arches"), "the newcomer belongs to rock_arches")


func test_respawn_s_zero_never_respawns() -> void:
	var w: SimWorld = B.make_world(5, {"spawn": true, "spawners": [B.spawner("giant_shark", "abyss", 1, 0.0)]})
	B.step_n(w, 1)
	assert_eq(B.npcs(w).size(), 1, "the giant shark spawns")
	w.remove_entity(B.npcs(w)[0].id)
	B.step_n(w, 300)
	assert_eq(B.npcs(w).size(), 0, "and never comes back")


func test_cap_applies_to_interactive_spawners_only() -> void:
	# S4: plankton is no spawner species any more (PlanktonField); the interactive cap must not touch large actors
	var w: SimWorld = B.make_world(6, {"spawn": true, "rules": {"npc_scale": 1.0, "tiers.interactive_cap": 10, "tiers.large_cap": 1000},
		"spawners": [B.spawner("puffer", "rock_arches", 50, 5.0), B.spawner("shark", "open_water", 30, 5.0)]})
	B.step_n(w, 1)
	assert_eq(NpcSpawner.target_count(w, 0), 10, "50 puffers capped to 10")
	assert_eq(NpcSpawner.target_count(w, 1), 30, "the large-tier sharks are not capped by the interactive cap")


func test_scale_multiplies_counts() -> void:
	var w: SimWorld = B.make_world(7, {"spawn": true, "rules": {"npc_scale": 0.25, "tiers.interactive_cap": 1000, "tiers.large_cap": 1000},
		"spawners": [B.spawner("puffer", "rock_arches", 20, 5.0), B.spawner("grouper", "rock_arches", 1, 5.0)]})
	B.step_n(w, 1)
	assert_eq(NpcSpawner.target_count(w, 0), 5, "20 x 0.25 = 5")
	assert_eq(NpcSpawner.target_count(w, 1), 1, "a scaled count never drops below 1")


func test_wandering_npcs_stay_in_their_home_zone() -> void:
	var w: SimWorld = B.make_world(8, {"spawn": true, "rules": {"npc_scale": 1.0, "tiers.large_cap": 1000},
		"spawners": [B.spawner("puffer", "rock_arches", 12, 5.0), B.spawner("grouper", "rock_arches", 6, 5.0)]})
	B.step_n(w, 900)
	var box: AABB = B.zone_box(w, "rock_arches").grow(2.0)
	var outside: int = 0
	for e in B.npcs(w):
		if not box.has_point(e.position):
			outside += 1
	assert_eq(outside, 0, "after 30 s of wandering no NPC left rock_arches (+2 m)")
