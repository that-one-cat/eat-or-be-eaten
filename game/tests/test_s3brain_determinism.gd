extends TestCase
## Brains and spawners are deterministic: same seed -> same state, different seed -> different spawns; brains draw
## nothing from the world RNG. Also measures the think() budget for 60 NPCs (target <= 0.5 ms per tick).

const B := preload("res://tests/s3brain_support.gd")
## Loose CI bound for the think budget (the target is 0.5 ms; machines and debug builds vary).
const BUDGET_GUARD_MS: float = 3.0


func _run(world_seed: int, n_ticks: int) -> SimWorld:
	var w: SimWorld = B.make_world(world_seed, {"spawn": true})
	var p: int = w.spawn_player(0)
	for t in n_ticks:
		w.submit(SimCommand.move(p, Vector3(0.3, -0.1, 1.0).normalized(), 1.0, t))
		w.step()
	return w


func test_same_seed_same_state_and_other_seed_differs() -> void:
	var a: SimWorld = _run(31, 300)
	var b: SimWorld = _run(31, 300)
	var c: SimWorld = _run(32, 300)
	assert_eq(a.state_hash(), b.state_hash(), "same seed: identical state after 300 ticks with brains + spawners")
	assert_ne(a.state_hash(), c.state_hash(), "another seed: different state")
	var states_a: PackedInt32Array = PackedInt32Array()
	var states_b: PackedInt32Array = PackedInt32Array()
	for e in B.npcs(a):
		states_a.append(e.brain_state)
	for e in B.npcs(b):
		states_b.append(e.brain_state)
	assert_eq(states_a, states_b, "same brain states")


func test_spawner_bookkeeping_is_written_for_the_state_hash() -> void:
	var w: SimWorld = _run(33, 30)
	var before := StreamPeerBuffer.new()
	NpcSpawner.write_state(w, before)
	assert_true(before.data_array.size() > 0, "write_state writes the spawner bookkeeping")
	w.remove_entity(B.npcs(w)[0].id)
	w.step()  # the loss is noticed and a respawn is scheduled
	var after := StreamPeerBuffer.new()
	NpcSpawner.write_state(w, after)
	assert_ne(after.data_array, before.data_array, "a pending respawn changes the written state")


func test_brains_draw_nothing_from_the_world_rng() -> void:
	var w: SimWorld = B.make_world(9)
	B.npc(w, &"barracuda", B.ARENA, 1.0)
	B.npc(w, &"grouper", B.ARENA + Vector3(6.0, 0.0, 0.0), 1.5)
	B.npc(w, &"small_reef_fish", B.ARENA + Vector3(0.0, 0.0, 30.0), 0.15)
	B.npc(w, &"plankton", B.ARENA + Vector3(0.0, 5.0, -30.0), 0.015)
	var s0: int = w.rng.get_state()
	B.step_n(w, 60)
	assert_eq(w.rng.get_state(), s0, "60 ticks of brains without deaths leave the RNG untouched")


func test_think_budget_for_sixty_npcs() -> void:
	# S4: schooling species are not spawner species any more; mark them non-schooling here to keep the 60-NPC mix
	var w: SimWorld = B.make_world(10, {"spawn": true, "schools": [], "rules": {"npc_scale": 1.0, "tiers.interactive_cap": 1000},
		"species": {"small_reef_fish": {"schooling": false}, "silver_schooling_fish": {"schooling": false}},
		"spawners": [B.spawner("small_reef_fish", "shallows", 24, 5.0), B.spawner("silver_schooling_fish", "shallows", 20, 5.0),
			B.spawner("puffer", "shallows", 8, 5.0), B.spawner("barracuda", "shallows", 5, 5.0), B.spawner("shark", "open_water", 3, 5.0)]})
	w.spawn_player(0)
	B.step_n(w, 1)
	assert_eq(B.npcs(w).size(), 60, "60 NPCs")
	w.brains_enabled = false  # think() is timed by hand below, once per NPC per tick, ascending id
	var total_us: int = 0
	var worst_us: int = 0
	var n_ticks: int = 300
	for t in n_ticks:
		var t0: int = Time.get_ticks_usec()
		for id in w.entity_ids():
			var e: SimEntity = w.get_entity(id)
			if e.alive and e.kind == SimEntity.Kind.CREATURE and not e.is_player:
				NpcBrain.think(w, e)
		var dt: int = Time.get_ticks_usec() - t0
		total_us += dt
		worst_us = maxi(worst_us, dt)
		w.step()
	var avg_ms: float = float(total_us) / float(n_ticks) / 1000.0
	print("S3BRAIN think budget: 60 NPCs, avg %.3f ms/tick, worst %.3f ms (Godot %s)" % [avg_ms, worst_us / 1000.0, Engine.get_version_info()["string"]])
	assert_true(avg_ms < BUDGET_GUARD_MS, "average think time %.3f ms per tick for 60 NPCs (target 0.5 ms)" % avg_ms)
