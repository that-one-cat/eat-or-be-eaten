extends TestCase
## Fish packs, respawn and hashing (NpcSpawner): a lost member comes back respawn_s later into its pack, next to the
## leader; a wiped pack comes back at a zone position and regroups; a member respawn waits while a living player is
## within rules.spawn.min_player_distance_m of the leader; the population never exceeds the target; pack membership
## and the pending pack of each respawn are part of the state hash.

const B := preload("res://tests/s3brain_support.gd")
const RULES: Dictionary = {"npc_scale": 1.0, "tiers.interactive_cap": 100000, "tiers.large_cap": 100000}
const RESPAWN_S: float = 2.0


func _world(world_seed: int, species: String, zone: String, count: int, size: int, radius_m: float) -> SimWorld:
	var rec: Dictionary = B.spawner(species, zone, count, RESPAWN_S)
	rec["group"] = {"min": size, "max": size, "chance": 1.0, "radius_m": radius_m}
	var w: SimWorld = B.make_world(world_seed, {"spawn": true, "spawners": [rec], "rules": RULES})
	w.step()
	return w


func test_a_lost_member_respawns_into_its_pack_next_to_the_leader() -> void:
	var w: SimWorld = _world(31, "barracuda", "open_water", 3, 3, 5.0)
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	w.get_entity(m[1]).hp = 0.0
	w.step()
	var lost_at: int = w.tick - 1
	assert_eq(NpcSpawner.pack_members(w, 0).size(), 2, "one member lost")
	var back: int = B.step_until(w, func() -> bool: return NpcSpawner.pack_members(w, 0).size() == 3, B.ticks(RESPAWN_S) + 5)
	assert_true(back >= 0, "the pack is full again within respawn_s")
	assert_true(w.tick - 1 - lost_at >= B.ticks(RESPAWN_S) - 1, "not before respawn_s")
	var now: Array[int] = NpcSpawner.pack_members(w, 0)
	var newcomer: SimEntity = w.get_entity(now[2])
	assert_true(now[2] > m[2], "the newcomer is a new entity")
	assert_eq(NpcSpawner.pack_index(w, newcomer.id), 0, "and belongs to the same pack")
	assert_eq(NpcSpawner.pack_leader(w, newcomer.id), m[0], "and follows the old leader")
	assert_true(newcomer.position.distance_to(w.get_entity(m[0]).position) <= 5.0 * 1.6 + 1.0, "spawned next to the leader (%.1f m)" % newcomer.position.distance_to(w.get_entity(m[0]).position))


func test_a_wiped_pack_respawns_in_its_zone_and_regroups() -> void:
	var w: SimWorld = _world(32, "puffer", "rock_arches", 3, 3, 2.5)
	for id in NpcSpawner.pack_members(w, 0):
		w.get_entity(id).hp = 0.0
	w.step()
	assert_eq(B.npcs(w).size(), 0, "the whole pack died")
	var back: int = B.step_until(w, func() -> bool: return NpcSpawner.pack_members(w, 0).size() == 3, B.ticks(RESPAWN_S) + 5)
	assert_true(back >= 0, "all three are back")
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	var leader: SimEntity = w.get_entity(m[0])
	assert_true(B.zone_box(w, "rock_arches").grow(0.5).has_point(leader.position), "the new leader spawned inside the zone")
	for id in m.slice(1):
		assert_true(w.get_entity(id).position.distance_to(leader.position) <= 2.5 * 1.6 + 1.0, "member %d spawned next to the new leader" % id)
	assert_eq(NpcSpawner.pack_count(w), 1, "no new pack was created")


func test_a_member_respawn_waits_while_a_player_is_near_the_leader() -> void:
	var w: SimWorld = _world(33, "grouper", "rock_arches", 2, 2, 4.0)
	var min_d: float = B.rule_f(w, "spawn.min_player_distance_m")
	assert_true(min_d > 0.0, "precondition: rules.spawn.min_player_distance_m is set")
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	var leader: SimEntity = w.get_entity(m[0])
	var p: SimEntity = B.player(w, leader.position + Vector3(6.0, 0.0, 0.0))
	B.tough(p)
	w.get_entity(m[1]).hp = 0.0
	for i in B.ticks(RESPAWN_S) + 60:
		p.position = leader.position + Vector3(6.0, 0.0, 0.0)
		p.velocity = Vector3.ZERO
		w.step()
	assert_eq(NpcSpawner.pack_members(w, 0).size(), 1, "2 s after respawn_s the member is still waiting (player 6 m from the leader)")
	assert_eq(B.npcs(w).size(), 1, "nobody popped in next to the player")
	w.remove_entity(p.id)
	B.step_n(w, 2)
	assert_eq(NpcSpawner.pack_members(w, 0).size(), 2, "the player is gone: the member respawns at once")


func test_the_population_never_exceeds_the_target_with_packs() -> void:
	var rec: Dictionary = B.spawner("puffer", "shallows", 14, 1.0)
	rec["group"] = {"min": 2, "max": 4, "chance": 0.7, "radius_m": 2.5}
	var w: SimWorld = B.make_world(34, {"spawn": true, "spawners": [rec], "rules": RULES})
	for sample in 30:
		B.step_n(w, 15)
		assert_true(B.npcs(w).size() <= 14, "alive %d <= 14 at sample %d" % [B.npcs(w).size(), sample])
		if sample % 7 == 3:
			var all: Array[SimEntity] = B.npcs(w)
			for k in range(0, all.size(), 2):
				all[k].hp = 0.0
	B.step_n(w, B.ticks(3.0))
	assert_eq(B.npcs(w).size(), 14, "refilled to exactly the target")
	var in_packs: int = 0
	for p in NpcSpawner.pack_count(w):
		in_packs += NpcSpawner.pack_members(w, p).size()
	assert_eq(in_packs, 14, "every NPC is in exactly one pack")


func _run(world_seed: int) -> SimWorld:
	var rec: Dictionary = B.spawner("barracuda", "open_water", 9, RESPAWN_S)
	rec["group"] = {"min": 2, "max": 4, "chance": 0.6, "radius_m": 5.0}
	var w: SimWorld = B.make_world(world_seed, {"spawn": true, "spawners": [rec], "rules": RULES})
	B.step_n(w, 90)
	for id in NpcSpawner.pack_members(w, 0):
		w.get_entity(id).hp = 0.0
	B.step_n(w, 120)
	return w


func test_the_state_hash_is_deterministic_and_covers_pack_membership() -> void:
	var a: SimWorld = _run(35)
	var b: SimWorld = _run(35)
	assert_eq(a.state_hash(), b.state_hash(), "same seed, same kills: identical hash after deaths and pack respawns")
	assert_ne(a.state_hash(), _run(36).state_hash(), "another seed differs")
	var before := StreamPeerBuffer.new()
	NpcSpawner.write_state(a, before)
	var st: Object = a.get_meta(&"npc_spawner_state")
	var last: int = NpcSpawner.pack_count(a) - 1
	assert_true(last >= 1 and not NpcSpawner.pack_members(a, last).is_empty(), "precondition: a second, living pack")
	if last < 1 or NpcSpawner.pack_members(a, last).is_empty():
		return
	(st.get("pack_of") as Dictionary)[NpcSpawner.pack_members(a, last)[0]] = 0
	var after := StreamPeerBuffer.new()
	NpcSpawner.write_state(a, after)
	assert_ne(before.data_array, after.data_array, "the pack of an NPC is written for the hash")
