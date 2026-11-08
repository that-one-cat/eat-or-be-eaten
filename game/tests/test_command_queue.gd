extends TestCase
## SimCommand constructors + SimCommandQueue ordering: (target tick asc, entity_id asc, seq asc).
## Commands carry a numeric tag in dir.x so the popped order can be asserted compactly.


class _Lcg:
	var s: int
	func _init(p_seed: int) -> void:
		s = p_seed & 0x7FFFFFFF
	func next() -> int:
		s = (s * 1103515245 + 12345) & 0x7FFFFFFF
		return s


func _mk(entity: int, tag: int, tick: int = -1) -> SimCommand:
	return SimCommand.move(entity, Vector3(float(tag), 0.0, 0.0), 1.0, tick)


func _tags(cmds: Array[SimCommand]) -> Array[int]:
	var out: Array[int] = []
	for c in cmds:
		out.append(int(c.dir.x))
	return out


# ---- SimCommand constructors ----

func test_move_constructor_fields() -> void:
	var c := SimCommand.move(3, Vector3(0, 0, 1), 0.5)
	assert_eq(c.type, SimCommand.Type.MOVE, "type")
	assert_eq(c.entity_id, 3, "entity_id")
	assert_eq(c.dir, Vector3(0, 0, 1), "dir")
	assert_almost_eq(c.thrust, 0.5, 1e-5, "thrust")
	assert_eq(c.tick, -1, "default tick must be -1 (next tick to run)")


func test_move_constructor_explicit_tick() -> void:
	var c := SimCommand.move(1, Vector3.RIGHT, 1.0, 12)
	assert_eq(c.tick, 12, "explicit tick must be stored")


func test_boost_bite_ability_constructors() -> void:
	var b := SimCommand.boost(2, true)
	assert_eq(b.type, SimCommand.Type.BOOST, "boost type")
	assert_eq(b.entity_id, 2, "boost entity")
	assert_true(b.active, "boost active")
	assert_eq(b.tick, -1, "boost default tick")

	var t := SimCommand.bite(5, 9, 40)
	assert_eq(t.type, SimCommand.Type.BITE, "bite type")
	assert_eq(t.entity_id, 5, "bite entity")
	assert_eq(t.target_id, 9, "bite target")
	assert_eq(t.tick, 40, "bite explicit tick")

	var none := SimCommand.bite(5, -1)
	assert_eq(none.target_id, -1, "bite with no target keeps -1")

	var a := SimCommand.ability(4, &"sonar")
	assert_eq(a.type, SimCommand.Type.ABILITY, "ability type")
	assert_eq(a.entity_id, 4, "ability entity")
	assert_eq(a.ability_id, &"sonar", "ability id")


# ---- Queue basics ----

func test_empty_queue() -> void:
	var q := SimCommandQueue.new()
	assert_eq(q.size(), 0, "new queue is empty")
	var out: Array[SimCommand] = q.pop_for_tick(100)
	assert_eq(out.size(), 0, "pop on empty queue returns empty array")


func test_push_assigns_monotonic_seq() -> void:
	var q := SimCommandQueue.new()
	var a := _mk(1, 1)
	var b := _mk(1, 2)
	var c := _mk(2, 3)
	q.push(a)
	q.push(b)
	q.push(c)
	assert_true(b.seq > a.seq, "seq must grow with each push (a=%d b=%d)" % [a.seq, b.seq])
	assert_true(c.seq > b.seq, "seq must grow across entities (b=%d c=%d)" % [b.seq, c.seq])
	assert_eq(q.size(), 3, "size after 3 pushes")


func test_pop_removes_commands() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 2))
	q.push(_mk(1, 2, 2))
	assert_eq(_tags(q.pop_for_tick(2)), [1, 2], "first pop returns both")
	assert_eq(q.size(), 0, "queue empty after pop")
	assert_eq(q.pop_for_tick(2).size(), 0, "second pop returns nothing")


func test_clear() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 2))
	q.push(_mk(2, 2, 9))
	q.clear()
	assert_eq(q.size(), 0, "clear empties the queue")
	assert_eq(q.pop_for_tick(100).size(), 0, "nothing to pop after clear")


# ---- Ordering ----

func _fill_reference(q: SimCommandQueue) -> void:
	q.push(_mk(3, 1, 5))
	q.push(_mk(1, 2, 5))
	q.push(_mk(2, 3, 3))
	q.push(_mk(1, 4, 5))
	q.push(_mk(2, 5, 5))


func test_order_tick_then_entity_then_seq() -> void:
	var q := SimCommandQueue.new()
	_fill_reference(q)
	# tick 3 first (e2:3), then tick 5 by entity: e1 (FIFO 2,4), e2 (5), e3 (1)
	assert_eq(_tags(q.pop_for_tick(5)), [3, 2, 4, 5, 1], "order must be (tick, entity_id, seq)")


func test_order_independent_of_cross_entity_push_interleaving() -> void:
	# Per-entity order is fixed: e1 -> [2, 4], e2 -> [3, 5], e3 -> [1]. Only the interleaving changes.
	var orders: Array = [
		[[3, 1], [1, 2], [2, 3], [1, 4], [2, 5]],  # original
		[[3, 1], [2, 3], [2, 5], [1, 2], [1, 4]],  # entity-major, e3 first
		[[1, 2], [1, 4], [2, 3], [2, 5], [3, 1]],  # entity-major, ascending
		[[2, 3], [1, 2], [3, 1], [2, 5], [1, 4]],  # round robin-ish
	]
	for order in orders:
		var q := SimCommandQueue.new()
		for pair in order:
			var entity: int = pair[0]
			var tag: int = pair[1]
			var tick: int = 3 if tag == 3 else 5
			q.push(_mk(entity, tag, tick))
		assert_eq(_tags(q.pop_for_tick(5)), [3, 2, 4, 5, 1], "interleaving %s changed the popped order" % [order])


func test_order_independent_of_random_interleavings() -> void:
	var lcg := _Lcg.new(777)
	var per_entity: Dictionary = {
		1: [[2, 5], [4, 5]],
		2: [[3, 3], [5, 5]],
		3: [[1, 5]],
	}
	for iteration in 60:
		var remaining: Dictionary = {}
		for key in per_entity:
			remaining[key] = (per_entity[key] as Array).duplicate()
		var q := SimCommandQueue.new()
		while not remaining.is_empty():
			var keys: Array = remaining.keys()
			var e: int = keys[lcg.next() % keys.size()]
			var item: Array = (remaining[e] as Array).pop_front()
			q.push(_mk(e, item[0], item[1]))
			if (remaining[e] as Array).is_empty():
				remaining.erase(e)
		assert_eq(_tags(q.pop_for_tick(5)), [3, 2, 4, 5, 1], "random interleaving %d changed the order" % iteration)


func test_fifo_within_one_entity() -> void:
	var q := SimCommandQueue.new()
	for i in 20:
		q.push(_mk(7, i, 4))
	var expected: Array[int] = []
	for i in 20:
		expected.append(i)
	assert_eq(_tags(q.pop_for_tick(4)), expected, "same entity + same tick must be FIFO")


func test_fifo_across_pushes_between_pops() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 9))
	assert_eq(q.pop_for_tick(3).size(), 0, "nothing due at tick 3")
	q.push(_mk(1, 2, 9))
	q.push(_mk(1, 3, 9))
	assert_eq(_tags(q.pop_for_tick(9)), [1, 2, 3], "push order must survive intermediate empty pops")


func test_target_tick_beats_seq_for_same_entity() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 9))  # pushed first, due later
	q.push(_mk(1, 2, 2))  # pushed second, due earlier
	assert_eq(_tags(q.pop_for_tick(9)), [2, 1], "earlier target tick must come first even when pushed later")


func test_stale_commands_are_still_popped() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 2))
	q.push(_mk(1, 2, 8))
	assert_eq(_tags(q.pop_for_tick(10)), [1, 2], "commands with tick <= popped tick are all returned")


# ---- Future ticks ----

func test_future_tick_commands_stay_queued() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1, 5))
	q.push(_mk(2, 2, 7))
	assert_eq(q.pop_for_tick(4).size(), 0, "nothing is due at tick 4")
	assert_eq(q.size(), 2, "future commands stay queued")
	assert_eq(_tags(q.pop_for_tick(5)), [1], "only the tick-5 command is due at tick 5")
	assert_eq(q.size(), 1, "tick-7 command still queued")
	assert_eq(_tags(q.pop_for_tick(7)), [2], "tick-7 command released at tick 7")
	assert_eq(q.size(), 0, "queue drained")


# ---- tick == -1 (current) ----

func test_minus_one_counts_as_current_tick() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(2, 1))
	q.push(_mk(1, 2))
	assert_eq(_tags(q.pop_for_tick(7)), [2, 1], "-1 commands are due at the popped tick, ordered by entity_id")


func test_minus_one_is_due_even_at_tick_zero() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1))
	assert_eq(_tags(q.pop_for_tick(0)), [1], "-1 command is due at tick 0")


func test_minus_one_mixed_with_explicit_ticks() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 3, 7))   # explicit, due at 7
	q.push(_mk(2, 4))      # -1, resolves to 7
	q.push(_mk(1, 5, 3))   # explicit, earlier
	q.push(_mk(3, 6, 9))   # future, must stay
	assert_eq(_tags(q.pop_for_tick(7)), [5, 3, 4], "effective ticks: 3 first, then 7 by entity (e1 then e2)")
	assert_eq(q.size(), 1, "tick-9 command remains")


func test_minus_one_and_explicit_same_entity_keep_fifo() -> void:
	var q := SimCommandQueue.new()
	q.push(_mk(1, 1))      # -1 -> resolves to 7
	q.push(_mk(1, 2, 7))   # explicit 7
	assert_eq(_tags(q.pop_for_tick(7)), [1, 2], "same effective tick + same entity -> push order")
