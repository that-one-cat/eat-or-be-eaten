extends TestCase
## S3 determinism with NPCs, and the shared spatial grid.
## Same seed + same player commands (explicit ticks) over 900 ticks with brains and the SHIPPED spawners must give
## the same state_hash() and the same event log; frame slicing (advance) and the global RNG must not matter; every
## new SimEntity field is hashed; every living creature / food bit sits in SimWorld.grid at its current position.
## Player input comes from the S2 helpers (own LCG, never SimRng or global RNG).

const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const TICKS: int = 900
const WORLD_SEED: int = 4242


## Real world (shipped spawners), player at spawn 0 with a scripted swim + a BITE every 45 ticks, all commands
## carry explicit ticks. deltas empty = step() per tick; otherwise advance() with the cycled frame deltas.
func _run(world_seed: int, deltas: Array[float] = []) -> SimWorld:
	var w: SimWorld = S3.make_world(world_seed, {"real_spawners": true})
	var id: int = w.spawn_player(0)
	S2.submit_segments(w, id, S2.movement_script(1001, TICKS, true, true), true)
	var t: int = 40
	while t < TICKS:
		w.submit(SimCommand.bite(id, -1, t))
		t += 45
	if deltas.is_empty():
		S2.run(w, TICKS)
	else:
		var frame: int = 0
		while w.tick < TICKS and frame < 200000:
			w.advance(deltas[frame % deltas.size()])
			frame += 1
	return w


func _event_signature(w: SimWorld) -> int:
	var parts: PackedStringArray = PackedStringArray()
	for ev: SimEvent in w.events_since(0):
		parts.append("%d:%d:%d:%d:%d" % [int(ev.type), ev.tick, ev.entity_id, ev.other_id, int(round(ev.value * 1000.0))])
	return ",".join(parts).hash()


# ======================================================== replay

func test_same_seed_same_commands_same_hash_and_events() -> void:
	var first: SimWorld = _run(WORLD_SEED)
	var h: int = first.state_hash()
	var sig: int = _event_signature(first)
	for i in 2:
		var again: SimWorld = _run(WORLD_SEED)
		assert_eq(again.state_hash(), h, "replay #%d: state_hash diverged" % i)
		assert_eq(_event_signature(again), sig, "replay #%d: event log diverged" % i)
		assert_eq(again.entity_count(), first.entity_count(), "replay #%d: entity count" % i)


func test_the_replayed_world_is_not_vacuous() -> void:
	var w: SimWorld = _run(WORLD_SEED)
	assert_true(S3.creatures(w).size() >= 24, "the shipped spawners put 'a few dozen' NPCs in the world (got %d)" % S3.creatures(w).size())
	var start: SimWorld = S3.make_world(WORLD_SEED, {"real_spawners": true})
	start.spawn_player(0)
	S3.step_n(start, 3)
	var initial: Dictionary = {}
	for e: SimEntity in S3.creatures(start):
		initial[e.id] = e.position
	var moved: int = 0
	for id: int in initial.keys():
		var e2: SimEntity = w.get_entity(id)
		if e2 != null and e2.position.distance_to(initial[id]) > 0.5:
			moved += 1
	assert_true(moved >= 5, "at least 5 NPCs swam somewhere in 30 s (%d moved)" % moved)
	assert_ne(w.state_hash(), start.state_hash(), "the 900-tick world differs from the 3-tick world")


func test_a_different_world_seed_changes_placements_and_hash() -> void:
	var a: SimWorld = S3.make_world(WORLD_SEED, {"real_spawners": true})
	var b: SimWorld = S3.make_world(WORLD_SEED + 1, {"real_spawners": true})
	S3.step_n(a, 5)
	S3.step_n(b, 5)
	var pa: Array = []
	var pb: Array = []
	for e: SimEntity in S3.creatures(a):
		pa.append(e.position)
	for e2: SimEntity in S3.creatures(b):
		pb.append(e2.position)
	assert_true(pa.size() > 0 and pb.size() > 0, "both worlds are populated")
	assert_true(pa != pb, "different seeds place NPCs differently")
	assert_ne(_run(WORLD_SEED).state_hash(), _run(WORLD_SEED + 1).state_hash(), "and the 900-tick hashes differ")


func test_global_rng_state_does_not_leak_into_the_sim() -> void:
	seed(1)
	var h1: int = _run(WORLD_SEED).state_hash()
	seed(987654321)
	randi()
	randf()
	var h2: int = _run(WORLD_SEED).state_hash()
	assert_eq(h1, h2, "the sim uses only its own SimRng (no randf/randi/shuffle/pick_random)")


func test_frame_slicing_does_not_change_the_result() -> void:
	var reference: int = _run(WORLD_SEED).state_hash()
	var d60: Array[float] = [1.0 / 60.0]
	var irregular: Array[float] = [0.0137, 0.009, 0.0211, 0.0166, 0.0049, 0.0302]
	assert_eq(_run(WORLD_SEED, d60).state_hash(), reference, "60 fps frames")
	assert_eq(_run(WORLD_SEED, irregular).state_hash(), reference, "irregular frames")


# ======================================================== new fields are hashed

func _two_creature_world() -> SimWorld:
	var w: SimWorld = S3.make_world(5)
	S3.player_at(w, S3.ARENA, 100.0)
	S3.npc_at(w, &"grouper", S3.ARENA + Vector3(30.0, 0.0, 0.0), 1.5)
	return w


func _mutate(e: SimEntity, field: String) -> void:
	var cur: Variant = e.get(field)
	if typeof(cur) == TYPE_BOOL:
		e.set(field, not bool(cur))
	elif typeof(cur) == TYPE_FLOAT:
		e.set(field, float(cur) + 1.5)
	else:
		e.set(field, int(cur) + 7)


func test_every_new_creature_field_is_part_of_the_hash() -> void:
	var base: int = _two_creature_world().state_hash()
	var fields: Array[String] = ["deaths", "respawn_tick", "bite_ready_tick", "bite_until_tick", "bite_miss_ready_tick", "inflated_until_tick", "aggro_target", "aggro_until_tick", "brain_state", "hidden", "hidden_since_tick"]
	for field in fields:
		for target in [1, 2]:
			var w: SimWorld = _two_creature_world()
			_mutate(w.get_entity(int(target)), field)
			assert_ne(w.state_hash(), base, "SimEntity.%s of entity %d must be hashed (contract: all new fields hashed)" % [field, target])


func _world_with_remains() -> SimWorld:
	var w: SimWorld = S3.make_world(5)
	var v: SimEntity = S3.npc_at(w, &"grouper", S3.ARENA)
	v.hp = 0.0
	w.step()
	return w


func test_food_bit_fields_and_kind_are_part_of_the_hash() -> void:
	var base_world: SimWorld = _world_with_remains()
	var base: int = base_world.state_hash()
	assert_ne(S3.food_bits(base_world).size(), 0, "precondition: the kill left bits")
	for field in ["xp_value", "hunger_value", "expire_tick"]:
		var w: SimWorld = _world_with_remains()
		_mutate(S3.food_bits(w)[0], field)
		assert_ne(w.state_hash(), base, "food bit field %s must be hashed" % field)
	var w2: SimWorld = _two_creature_world()
	var base2: int = w2.state_hash()
	w2.get_entity(2).kind = SimEntity.Kind.FOOD_BIT
	assert_ne(w2.state_hash(), base2, "SimEntity.kind must be hashed")


# ======================================================== one grid for everything

func _check_grid(w: SimWorld, seen: Dictionary, label: String) -> void:
	assert_not_null(w.grid, "%s: grid exists" % label)
	assert_almost_eq(w.grid.cell_size, S3.rule_f(w.content, "grid_cell_m"), 1e-9, "%s: cell size from rules.grid_cell_m" % label)
	var in_grid: int = 0
	for id: int in w.entity_ids():
		seen[id] = true
		var e: SimEntity = w.get_entity(id)
		if e.alive or e.kind == SimEntity.Kind.FOOD_BIT:
			in_grid += 1
			assert_true(w.grid.has(id), "%s: entity %d (%s) is in the grid" % [label, id, e.species_id])
			if w.grid.has(id):
				assert_true(w.grid.position_of(id).distance_to(e.position) < 1e-3, "%s: entity %d grid position %s vs entity position %s" % [label, id, w.grid.position_of(id), e.position])
				assert_true(w.grid.query_radius(e.position, 0.05).has(id), "%s: query_radius at its own position finds entity %d" % [label, id])
	for id2: int in seen.keys():
		if w.get_entity(id2) == null:
			assert_false(w.grid.has(id2), "%s: removed entity %d must leave the grid" % [label, id2])
	assert_true(w.grid.count() >= in_grid and w.grid.count() <= w.entity_count(), "%s: grid holds %d, expected between %d and %d" % [label, w.grid.count(), in_grid, w.entity_count()])


func test_the_grid_matches_every_entity_through_kills_expiry_and_respawn() -> void:
	var w: SimWorld = S3.make_world(WORLD_SEED, {"real_spawners": true})
	var id: int = w.spawn_player(0)
	S2.submit_segments(w, id, S2.movement_script(1001, TICKS, true, true), true)
	var seen: Dictionary = {}
	_check_grid(w, seen, "t0")
	for t in TICKS:
		if t == 300:
			var n: int = 0
			for e: SimEntity in S3.creatures(w):
				if n < 6:
					e.hp = 0.0
					n += 1
		if t == 450:
			w.get_entity(id).hp = 0.0
		w.step()
		if t % 100 == 99:
			_check_grid(w, seen, "t%d" % (t + 1))
	assert_true(w.get_entity(id).deaths >= 1, "the scripted death happened (the run exercised respawn)")
	assert_true(seen.size() > 24, "many entities were tracked (%d)" % seen.size())


# ======================================================== purity of the new sim files

func test_new_sim_files_exist_are_ref_counted_and_use_no_global_rng_or_clock() -> void:
	var bad := RegEx.new()
	assert_eq(bad.compile("\\brandf\\s*\\(|\\brandi\\s*\\(|\\brandf_range\\s*\\(|\\brandi_range\\s*\\(|\\brandomize\\s*\\(|\\.shuffle\\s*\\(|\\.pick_random\\s*\\(|\\bget_tree\\s*\\(|Time\\.get_|OS\\.get_ticks|extends\\s+Node"), OK, "test regex")
	for entry in [["sim_rules.gd", "SimRules"], ["npc_brain.gd", "NpcBrain"], ["npc_spawner.gd", "NpcSpawner"]]:
		var path: String = "res://scripts/sim/%s" % entry[0]
		assert_true(FileAccess.file_exists(path), "contract file missing: %s" % path)
		if not FileAccess.file_exists(path):
			continue
		var lines: Array[String] = []
		for raw in FileAccess.get_file_as_string(path).split("\n"):
			lines.append(raw.split("#")[0])
		var code: String = "\n".join(lines)
		assert_true(code.find("class_name %s" % entry[1]) != -1, "%s declares class_name %s" % [entry[0], entry[1]])
		assert_true(code.find("extends RefCounted") != -1, "%s extends RefCounted" % entry[0])
		var hit: RegExMatch = bad.search(code)
		assert_null(hit, "%s must be pure and deterministic (found '%s')" % [entry[0], hit.get_string() if hit != null else ""])
