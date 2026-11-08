extends TestCase
## SimWorld: entities, commands -> movement, fixed-step accumulator, event log, hash sanity.
## With content == null the S0 base speed is 1.0 m/s (documented in the contract).


func _world() -> SimWorld:
	return SimWorld.new(42)


func _spawn(w: SimWorld, species: StringName = &"small_reef_fish", pos: Vector3 = Vector3.ZERO) -> int:
	return w.spawn_entity(species, pos, 0.15)


func _run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.step()


# ---- construction ----

func test_constants() -> void:
	assert_eq(SimWorld.TICK_RATE, 30, "TICK_RATE")
	assert_almost_eq(SimWorld.TICK_DT, 1.0 / 30.0, 1e-9, "TICK_DT")


func test_new_world_is_empty() -> void:
	var w := _world()
	assert_eq(w.tick, 0, "tick starts at 0")
	assert_eq(w.entity_count(), 0, "no entities")
	assert_eq(w.entity_ids().size(), 0, "no ids")
	assert_not_null(w.rng, "rng exposed")
	assert_true(w.rng is SimRng, "rng is a SimRng")


func test_world_is_not_a_node() -> void:
	var o: Object = _world()
	assert_false(o is Node, "SimWorld must not be a Node (sim is node-free)")
	assert_true(o is RefCounted, "SimWorld is RefCounted")


# ---- entities ----

func test_spawn_ids_start_at_one_and_are_monotonic() -> void:
	var w := _world()
	assert_eq(_spawn(w), 1, "first id is 1")
	assert_eq(_spawn(w), 2, "second id is 2")
	assert_eq(_spawn(w), 3, "third id is 3")
	assert_eq(w.entity_count(), 3, "count")


func test_ids_are_never_reused() -> void:
	var w := _world()
	var a := _spawn(w)
	var b := _spawn(w)
	var c := _spawn(w)
	assert_true(w.remove_entity(b), "remove existing returns true")
	assert_false(w.remove_entity(b), "remove again returns false")
	assert_false(w.remove_entity(999), "remove unknown returns false")
	var d := _spawn(w)
	assert_eq(d, 4, "new id continues the counter, the freed id %d is not reused" % b)
	assert_eq(Array(w.entity_ids()), [a, c, d], "entity_ids ascending, without the removed one")
	assert_eq(w.entity_count(), 3, "count after remove + spawn")


func test_get_entity() -> void:
	var w := _world()
	var id: int = w.spawn_entity(&"puffer", Vector3(1, 2, 3), 0.4, true)
	var e: SimEntity = w.get_entity(id)
	assert_not_null(e, "spawned entity is retrievable")
	assert_eq(e.id, id, "id")
	assert_eq(e.species_id, &"puffer", "species_id")
	assert_eq(e.position, Vector3(1, 2, 3), "position")
	assert_almost_eq(e.length_m, 0.4, 1e-5, "length_m")
	assert_true(e.is_player, "is_player")
	assert_true(e.alive, "alive on spawn")
	assert_true(e.band >= 1 and e.band <= 4, "band within 1..4, got %d" % e.band)
	assert_true(e.hp <= e.max_hp, "hp <= max_hp")
	assert_almost_eq(e.heading.length(), 1.0, 1e-4, "heading is a unit vector")
	assert_null(w.get_entity(999), "absent id returns null")


func test_non_player_default() -> void:
	var w := _world()
	var id := _spawn(w)
	assert_false(w.get_entity(id).is_player, "is_player defaults to false")


func test_removed_entity_is_gone() -> void:
	var w := _world()
	var id := _spawn(w)
	w.remove_entity(id)
	assert_null(w.get_entity(id), "removed entity returns null")
	assert_eq(w.entity_count(), 0, "count")


# ---- events ----

func test_spawn_emits_entity_spawned_event() -> void:
	var w := _world()
	var id := _spawn(w)
	var evs: Array[SimEvent] = w.events_since(0)
	assert_eq(evs.size(), 1, "one event after one spawn")
	assert_eq(evs[0].type, SimEvent.Type.ENTITY_SPAWNED, "event type")
	assert_eq(evs[0].entity_id, id, "event entity")
	assert_eq(evs[0].tick, 0, "event tick")


func test_events_since_filters_by_tick() -> void:
	var w := _world()
	_spawn(w)
	_run(w, 5)
	var late := _spawn(w)
	assert_eq(w.events_since(0).size(), 2, "both spawn events since tick 0")
	var recent: Array[SimEvent] = w.events_since(5)
	assert_eq(recent.size(), 1, "only the tick-5 spawn since tick 5")
	assert_eq(recent[0].entity_id, late, "it is the late entity")
	assert_eq(w.events_since(6).size(), 0, "nothing since tick 6")


func test_clear_events_before() -> void:
	var w := _world()
	_spawn(w)
	_run(w, 5)
	var late := _spawn(w)
	w.clear_events_before(5)
	var left: Array[SimEvent] = w.events_since(0)
	assert_eq(left.size(), 1, "tick-0 event dropped, tick-5 event kept")
	assert_eq(left[0].entity_id, late, "the kept event is the late spawn")


# ---- step: commands -> movement ----

func test_step_advances_tick() -> void:
	var w := _world()
	_run(w, 7)
	assert_eq(w.tick, 7, "tick counts completed steps")


func test_move_command_moves_entity_at_base_speed() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	_run(w, 30)
	var p: Vector3 = w.get_entity(id).position
	assert_almost_eq(p.x, 1.0, 0.05, "30 ticks at 1 m/s moves about 1 m, got %s" % p)
	assert_almost_eq(p.y, 0.0, 1e-4, "no drift on y")
	assert_almost_eq(p.z, 0.0, 1e-4, "no drift on z")


func test_move_direction_is_normalized_and_thrust_scales_speed() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3(2, 0, 0), 0.5))  # non-unit dir, half thrust
	_run(w, 30)
	var p: Vector3 = w.get_entity(id).position
	assert_almost_eq(p.x, 0.5, 0.03, "velocity = dir.normalized() * thrust * base_speed -> about 0.5 m in 1 s, got %s" % p)


func test_zero_thrust_does_not_move() -> void:
	var w := _world()
	var id := _spawn(w, &"small_reef_fish", Vector3(4, 4, 4))
	w.submit(SimCommand.move(id, Vector3.RIGHT, 0.0))
	_run(w, 30)
	assert_eq(w.get_entity(id).position, Vector3(4, 4, 4), "thrust 0 keeps the entity in place")


func test_no_command_no_movement() -> void:
	var w := _world()
	var id := _spawn(w, &"small_reef_fish", Vector3(1, 1, 1))
	_run(w, 30)
	assert_eq(w.get_entity(id).position, Vector3(1, 1, 1), "idle entity stays put")


func test_move_intent_persists_until_changed() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	_run(w, 15)
	var half: float = w.get_entity(id).position.x
	_run(w, 15)
	var full: float = w.get_entity(id).position.x
	assert_true(full > half + 0.3, "entity keeps moving without re-sending MOVE (half=%f full=%f)" % [half, full])
	w.submit(SimCommand.move(id, Vector3.RIGHT, 0.0))
	_run(w, 1)
	var stopped_at: float = w.get_entity(id).position.x
	_run(w, 10)
	assert_almost_eq(w.get_entity(id).position.x, stopped_at, 1e-4, "thrust 0 command stops the entity")


func test_same_entity_commands_apply_fifo_last_wins() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.move(id, Vector3.LEFT, 1.0))
	_run(w, 30)
	assert_true(w.get_entity(id).position.x < -0.9, "later command wins within one tick, got %s" % w.get_entity(id).position)


func test_future_tick_command_is_not_applied_early() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0, 10))
	_run(w, 10)
	assert_almost_eq(w.get_entity(id).position.x, 0.0, 1e-4, "command for tick 10 must not move the entity during ticks 0..9")
	_run(w, 30)
	assert_true(w.get_entity(id).position.x > 0.9, "after tick 10 the entity moves")


func test_command_with_minus_one_applies_on_next_step() -> void:
	var w := _world()
	var id := _spawn(w)
	_run(w, 5)
	w.submit(SimCommand.move(id, Vector3.RIGHT, 1.0))  # tick -1
	_run(w, 1)
	assert_true(w.get_entity(id).position.x > 0.0, "a -1 command is applied in the very next step")


func test_commands_target_their_own_entity() -> void:
	var w := _world()
	var a := _spawn(w)
	var b := _spawn(w, &"puffer")
	w.submit(SimCommand.move(a, Vector3.FORWARD, 1.0))
	_run(w, 30)
	assert_true(w.get_entity(a).position.length() > 0.5, "target moved")
	assert_eq(w.get_entity(b).position, Vector3.ZERO, "bystander did not move")


func test_boost_toggles_flag() -> void:
	var w := _world()
	var id := _spawn(w)
	assert_false(w.get_entity(id).boosting, "not boosting by default")
	w.submit(SimCommand.boost(id, true))
	_run(w, 1)
	assert_true(w.get_entity(id).boosting, "BOOST active=true sets boosting")
	w.submit(SimCommand.boost(id, false))
	_run(w, 1)
	assert_false(w.get_entity(id).boosting, "BOOST active=false clears boosting")


func test_bite_and_ability_are_recorded_without_gameplay() -> void:
	var w := _world()
	var a := _spawn(w)
	var b := _spawn(w, &"puffer", Vector3(0.1, 0, 0))
	w.submit(SimCommand.bite(a, b))
	w.submit(SimCommand.bite(a, -1))
	w.submit(SimCommand.ability(a, &"sonar"))
	_run(w, 5)
	assert_eq(w.tick, 5, "ticks advance normally")
	assert_eq(w.entity_count(), 2, "no gameplay in S0: nobody is eaten or removed")
	assert_eq(w.get_entity(a).position, Vector3.ZERO, "BITE/ABILITY do not move anyone")


func test_commands_for_unknown_entity_do_not_crash_or_move_others() -> void:
	# Robustness expectation beyond the contract text: the sim ignores commands whose entity does not exist.
	var w := _world()
	var a := _spawn(w)
	w.submit(SimCommand.move(999, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.bite(999, a))
	w.submit(SimCommand.boost(999, true))
	w.submit(SimCommand.ability(999, &"sonar"))
	_run(w, 3)
	assert_eq(w.tick, 3, "ticks advance")
	assert_eq(w.get_entity(a).position, Vector3.ZERO, "unrelated entity untouched")


func test_commands_for_removed_entity_are_ignored() -> void:
	var w := _world()
	var a := _spawn(w)
	w.submit(SimCommand.move(a, Vector3.RIGHT, 1.0, 5))
	w.remove_entity(a)
	_run(w, 10)
	assert_eq(w.tick, 10, "no crash, ticks advance")
	assert_eq(w.entity_count(), 0, "entity stays removed")


# ---- advance(): fixed-step accumulator ----

func test_advance_one_second_runs_30_ticks() -> void:
	var w := _world()
	var ran: int = w.advance(1.0)
	assert_eq(ran, 30, "advance(1.0) must run 30 steps")
	assert_eq(w.tick, 30, "tick == 30")


func test_advance_sub_tick_delta_runs_nothing_then_accumulates() -> void:
	var w := _world()
	assert_eq(w.advance(SimWorld.TICK_DT * 0.5), 0, "half a tick runs nothing")
	assert_eq(w.tick, 0, "tick still 0")
	assert_eq(w.advance(SimWorld.TICK_DT * 0.6), 1, "second half-tick tips the accumulator over")
	assert_eq(w.tick, 1, "tick 1")


func test_advance_fractional_deltas_accumulate() -> void:
	var w := _world()
	var total: int = 0
	var per_call: Array[int] = []
	for i in 4:
		var n: int = w.advance(0.02)  # 4 * 0.02 = 0.08 s = 2.4 ticks
		per_call.append(n)
		total += n
	assert_eq(total, 2, "0.08 s of frames must produce exactly 2 ticks, calls ran %s" % [per_call])
	assert_eq(w.tick, 2, "tick == 2")
	# 0.0133 s (0.4 tick) is left in the accumulator
	assert_almost_eq(w.interpolation_alpha(), 0.4, 0.01, "alpha is the leftover fraction of a tick")


func test_advance_exact_tick_deltas() -> void:
	var w := _world()
	for i in 30:
		assert_eq(w.advance(SimWorld.TICK_DT), 1, "an exact TICK_DT delta runs exactly one step (frame %d)" % i)
	assert_eq(w.tick, 30, "30 frames at 30 Hz = 30 ticks")


func test_advance_large_delta_runs_many_steps() -> void:
	var w := _world()
	assert_eq(w.advance(0.5), 15, "0.5 s = 15 ticks")
	assert_eq(w.tick, 15, "tick == 15")


func test_advance_zero_delta() -> void:
	var w := _world()
	assert_eq(w.advance(0.0), 0, "zero delta runs nothing")
	assert_eq(w.tick, 0, "tick unchanged")


func test_interpolation_alpha_range() -> void:
	var w := _world()
	assert_almost_eq(w.interpolation_alpha(), 0.0, 1e-6, "alpha is 0 at start")
	for i in 100:
		w.advance(0.0117)
		var a: float = w.interpolation_alpha()
		assert_true(a >= 0.0 and a < 1.0, "alpha must stay in [0, 1), got %f" % a)


func test_advance_ignores_non_finite_and_negative_delta() -> void:
	var w := _world()
	assert_eq(w.advance(INF), 0, "INF delta runs nothing (and must not hang)")
	assert_eq(w.advance(NAN), 0, "NaN delta runs nothing")
	assert_eq(w.advance(-1.0), 0, "negative delta runs nothing")
	assert_eq(w.tick, 0, "tick unchanged")
	assert_eq(w.advance(1.0), 30, "accumulator still healthy afterwards")


func test_move_with_non_finite_numbers_is_ignored() -> void:
	var w := _world()
	var id := _spawn(w)
	w.submit(SimCommand.move(id, Vector3(1, 0, 0), 1.0))
	w.step()
	var before: Vector3 = w.get_entity(id).position
	w.submit(SimCommand.move(id, Vector3(NAN, 0, 0), 1.0))
	w.step()
	w.submit(SimCommand.move(id, Vector3(1, 0, 0), NAN))
	w.step()
	w.submit(SimCommand.move(id, Vector3(INF, 0, 0), 1.0))
	w.step()
	var e: SimEntity = w.get_entity(id)
	assert_true(e.position.is_finite() and e.velocity.is_finite(), "position/velocity must stay finite")
	assert_true(e.position.x > before.x, "the previous valid MOVE intent stays in force")


# ---- state_hash sanity ----

func test_state_hash_includes_pending_commands() -> void:
	var a := _world()
	var b := _world()
	var ia := _spawn(a)
	var ib := _spawn(b)
	assert_eq(a.state_hash(), b.state_hash(), "identical worlds hash equal")
	a.submit(SimCommand.move(ia, Vector3.RIGHT, 1.0))
	assert_ne(a.state_hash(), b.state_hash(), "a queued command is part of the state")
	b.submit(SimCommand.move(ib, Vector3.RIGHT, 1.0))
	assert_eq(a.state_hash(), b.state_hash(), "same pending commands hash equal")


func test_state_hash_pending_does_not_depend_on_push_interleaving() -> void:
	var a := _world()
	var b := _world()
	for w: SimWorld in [a, b]:
		_spawn(w)
		_spawn(w)
	a.submit(SimCommand.move(1, Vector3.RIGHT, 1.0))
	a.submit(SimCommand.move(2, Vector3.UP, 0.5))
	b.submit(SimCommand.move(2, Vector3.UP, 0.5))
	b.submit(SimCommand.move(1, Vector3.RIGHT, 1.0))
	assert_eq(a.state_hash(), b.state_hash(), "interleaving of pushes from different entities must not change the hash")


func test_hash_is_stable_between_calls() -> void:
	var w := _world()
	_spawn(w)
	_run(w, 10)
	assert_eq(w.state_hash(), w.state_hash(), "state_hash must be pure")


func test_hash_depends_on_tick() -> void:
	var w := _world()
	_spawn(w)
	var h0: int = w.state_hash()
	_run(w, 1)
	assert_ne(w.state_hash(), h0, "stepping changes the hash (tick is part of it)")


func test_hash_depends_on_entity_fields() -> void:
	var a := _world()
	var b := _world()
	_spawn(a, &"small_reef_fish", Vector3(0, 0, 0))
	_spawn(b, &"small_reef_fish", Vector3(0.5, 0, 0))
	assert_ne(a.state_hash(), b.state_hash(), "different positions -> different hash")
	var c := _world()
	var d := _world()
	c.spawn_entity(&"puffer", Vector3.ZERO, 0.30)
	d.spawn_entity(&"puffer", Vector3.ZERO, 0.45)
	assert_ne(c.state_hash(), d.state_hash(), "different length -> different hash")


func test_hash_depends_on_rng_state() -> void:
	var a := _world()
	var b := _world()
	assert_eq(a.state_hash(), b.state_hash(), "identical empty worlds hash equally")
	a.rng.next_u32()
	assert_ne(a.state_hash(), b.state_hash(), "consuming rng changes the hash")


func test_hash_depends_on_seed() -> void:
	assert_ne(SimWorld.new(1).state_hash(), SimWorld.new(2).state_hash(), "seed is observable through the rng state in the hash")


func test_same_seed_same_rng_state() -> void:
	assert_eq(SimWorld.new(77).rng.get_state(), SimWorld.new(77).rng.get_state(), "world rng is seeded from the seed argument")
