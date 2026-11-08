extends TestCase
## Fish packs, brains (NpcBrain._follow_leader): a pack follower wanders by following its leader (lowest-id living
## member) and stays within a few body lengths; when the leader dies the next member leads. Every member keeps its
## own hp, temperament and pursuit: a bite on one puffer makes only that one retaliate, a barracuda follower hunts
## prey on its own. A pack is not a shared entity.

const B := preload("res://tests/s3brain_support.gd")
const RULES: Dictionary = {"npc_scale": 1.0, "tiers.interactive_cap": 100000, "tiers.large_cap": 100000}


func _world(world_seed: int, species: String, zone: String, count: int, size: int, radius_m: float) -> SimWorld:
	var rec: Dictionary = B.spawner(species, zone, count, 5.0)
	rec["group"] = {"min": size, "max": size, "chance": 1.0, "radius_m": radius_m}
	var w: SimWorld = B.make_world(world_seed, {"spawn": true, "spawners": [rec], "rules": RULES})
	w.step()
	return w


## Largest follower-to-leader distance over all packs of `w`.
func _worst_spread(w: SimWorld) -> float:
	var worst: float = 0.0
	for p in NpcSpawner.pack_count(w):
		var m: Array[int] = NpcSpawner.pack_members(w, p)
		if m.size() < 2:
			continue
		var leader: SimEntity = w.get_entity(m[0])
		for id in m.slice(1):
			worst = maxf(worst, w.get_entity(id).position.distance_to(leader.position))
	return worst


func test_followers_stay_close_to_their_leader_while_wandering() -> void:
	for c in [["barracuda", "open_water", 5.0], ["puffer", "rock_arches", 2.5], ["grouper", "rock_arches", 4.0]]:
		var r: float = c[2]
		var w: SimWorld = _world(21, c[0], c[1], 12, 3 if c[0] != "grouper" else 2, r)
		B.step_n(w, B.ticks(5.0))
		var worst: float = 0.0
		for sample in 20:
			B.step_n(w, B.ticks(3.0))
			worst = maxf(worst, _worst_spread(w))
			for e in B.npcs(w):
				assert_eq(e.brain_state, NpcBrain.State.WANDER, "%s %d wanders (no prey, no player)" % [c[0], e.id])
		assert_true(worst <= 2.0 * r, "%s: followers stay within 2 x radius_m (%.1f m) of the leader over 60 s, worst %.2f m" % [c[0], 2.0 * r, worst])


func test_the_leader_wanders_away_and_the_pack_moves_with_it() -> void:
	var w: SimWorld = _world(22, "barracuda", "open_water", 3, 3, 5.0)
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	var start: Vector3 = w.get_entity(m[2]).position
	B.step_n(w, B.ticks(40.0))
	var leader: SimEntity = w.get_entity(m[0])
	var follower: SimEntity = w.get_entity(m[2])
	assert_true(follower.position.distance_to(start) > 15.0, "the follower travelled (%.1f m)" % follower.position.distance_to(start))
	assert_true(follower.position.distance_to(leader.position) <= 10.0, "and is still with its leader (%.1f m)" % follower.position.distance_to(leader.position))


func test_when_the_leader_dies_the_next_member_leads() -> void:
	var w: SimWorld = _world(23, "barracuda", "open_water", 3, 3, 5.0)
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	assert_eq(NpcSpawner.pack_leader(w, m[2]), m[0], "precondition: the lowest id leads")
	w.get_entity(m[0]).hp = 0.0
	w.step()
	assert_null(w.get_entity(m[0]), "the leader died")
	assert_eq(NpcSpawner.pack_leader(w, m[2]), m[1], "the next lowest id leads")
	assert_eq(NpcSpawner.pack_leader(w, m[1]), -1, "and follows nobody")
	assert_eq(NpcSpawner.pack_members(w, 0), [m[1], m[2]] as Array[int], "the dead member left the pack")
	B.step_n(w, B.ticks(20.0))
	assert_true(_worst_spread(w) <= 10.0, "the pack keeps together around the new leader (%.1f m)" % _worst_spread(w))


func test_a_bitten_member_retaliates_alone_and_keeps_its_own_hp() -> void:
	var w: SimWorld = _world(24, "puffer", "rock_arches", 3, 3, 2.5)
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	var target: SimEntity = w.get_entity(m[1])
	var p: SimEntity = B.player(w, target.position - target.heading * 0.2, target.heading)
	B.tough(p)
	w.submit(SimCommand.bite(p.id, target.id, w.tick))
	var tb: int = w.tick
	B.step_n(w, 1)
	assert_eq(B.bites(w, p.id, target.id, tb), 1, "precondition: the bite landed on the follower")
	B.step_n(w, 3)
	assert_eq(target.brain_state, NpcBrain.State.RETALIATE, "the bitten member retaliates")
	assert_true(target.hp < target.max_hp, "and lost hp")
	for id in [m[0], m[2]]:
		var e: SimEntity = w.get_entity(id)
		assert_ne(e.brain_state, NpcBrain.State.RETALIATE, "pack mate %d does not retaliate" % id)
		assert_eq(e.aggro_target, -1, "pack mate %d has no aggro" % id)
		assert_almost_eq(e.hp, e.max_hp, 1e-9, "pack mate %d keeps full hp" % id)


func test_a_follower_hunts_prey_on_its_own() -> void:
	var w: SimWorld = _world(25, "barracuda", "open_water", 3, 3, 5.0)
	var m: Array[int] = NpcSpawner.pack_members(w, 0)
	var follower: SimEntity = w.get_entity(m[2])
	var p: SimEntity = B.player(w, follower.position + Vector3(8.0, 0.0, 0.0))
	B.tough(p)
	B.step_n(w, 6)
	assert_eq(follower.brain_state, NpcBrain.State.CHASE, "the follower leaves the formation to chase")
	assert_eq(follower.aggro_target, p.id, "its own target is the player")
