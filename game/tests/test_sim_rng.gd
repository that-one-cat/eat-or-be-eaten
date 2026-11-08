extends TestCase
## SimRng: seeded, reproducible, own algorithm (contract: s0-api-contract.md, SimRng).


func _draw_u32(rng: SimRng, n: int) -> Array[int]:
	var out: Array[int] = []
	for i in n:
		out.append(rng.next_u32())
	return out


func test_same_seed_same_sequence() -> void:
	var a := SimRng.new(12345)
	var b := SimRng.new(12345)
	assert_eq(_draw_u32(a, 200), _draw_u32(b, 200), "two SimRng with the same seed must produce the same u32 sequence")


func test_different_seeds_differ() -> void:
	var a := SimRng.new(1)
	var b := SimRng.new(2)
	assert_ne(_draw_u32(a, 20), _draw_u32(b, 20), "different seeds must produce different sequences")


func test_seed_zero_is_not_degenerate() -> void:
	var rng := SimRng.new(0)
	var seen: Dictionary = {}
	for v in _draw_u32(rng, 50):
		seen[v] = true
	assert_true(seen.size() > 40, "seed 0 must not produce a stuck or near-constant sequence (distinct=%d/50)" % seen.size())


func test_negative_and_large_seeds_are_deterministic() -> void:
	for s in [-1, -987654321, 0x7FFFFFFFFFFFFFFF, 4294967296]:
		var a := SimRng.new(s)
		var b := SimRng.new(s)
		assert_eq(_draw_u32(a, 30), _draw_u32(b, 30), "seed %d must be reproducible" % s)


func test_next_u32_range() -> void:
	var rng := SimRng.new(77)
	for i in 2000:
		var v: int = rng.next_u32()
		assert_true(v >= 0 and v <= 0xFFFFFFFF, "next_u32 out of [0, 2^32-1]: %d" % v)


func test_next_float_in_unit_interval_and_roughly_uniform() -> void:
	var rng := SimRng.new(2024)
	var sum: float = 0.0
	var n: int = 10000
	for i in n:
		var f: float = rng.next_float()
		assert_true(f >= 0.0 and f < 1.0, "next_float out of [0, 1): %f" % f)
		sum += f
	var mean: float = sum / n
	assert_true(mean > 0.47 and mean < 0.53, "mean of next_float should be near 0.5, got %f" % mean)


func test_range_int_is_inclusive_and_covers_all_values() -> void:
	var rng := SimRng.new(5)
	var seen: Dictionary = {}
	for i in 2000:
		var v: int = rng.range_int(3, 6)
		assert_true(v >= 3 and v <= 6, "range_int(3, 6) out of bounds: %d" % v)
		seen[v] = true
	for expected in [3, 4, 5, 6]:
		assert_true(seen.has(expected), "range_int(3, 6) never produced %d in 2000 draws (hi must be inclusive)" % expected)


func test_range_int_degenerate_and_negative() -> void:
	var rng := SimRng.new(9)
	for i in 50:
		assert_eq(rng.range_int(7, 7), 7, "range_int(lo, lo) must return lo")
	for i in 500:
		var v: int = rng.range_int(-5, -2)
		assert_true(v >= -5 and v <= -2, "range_int(-5, -2) out of bounds: %d" % v)
	var seen_zero_crossing: Dictionary = {}
	for i in 500:
		seen_zero_crossing[rng.range_int(-1, 1)] = true
	assert_eq(seen_zero_crossing.size(), 3, "range_int(-1, 1) must produce -1, 0 and 1")


func test_range_float_bounds() -> void:
	var rng := SimRng.new(31)
	for i in 2000:
		var v: float = rng.range_float(-2.5, 4.0)
		assert_true(v >= -2.5 and v < 4.0, "range_float(-2.5, 4.0) out of bounds: %f" % v)


func test_get_state_returns_int_and_changes_on_draw() -> void:
	var rng := SimRng.new(11)
	var before: int = rng.get_state()
	rng.next_u32()
	var after: int = rng.get_state()
	assert_ne(after, before, "state must advance after a draw")


func test_set_state_reproduces_following_sequence() -> void:
	var a := SimRng.new(999)
	_draw_u32(a, 10)
	var saved: int = a.get_state()
	var expected: Array[int] = _draw_u32(a, 25)
	var b := SimRng.new(1)  # deliberately different seed
	b.set_state(saved)
	assert_eq(_draw_u32(b, 25), expected, "set_state(get_state()) must reproduce the following sequence on any instance")
	# restoring on the same instance rewinds it
	a.set_state(saved)
	assert_eq(_draw_u32(a, 25), expected, "set_state on the same instance must rewind the sequence")


func test_state_restore_works_across_mixed_methods() -> void:
	var a := SimRng.new(4242)
	a.next_float()
	a.range_int(0, 100)
	var saved: int = a.get_state()
	var seq_a: Array = [a.next_float(), a.range_int(0, 100), a.range_float(1.0, 2.0), a.next_u32()]
	var b := SimRng.new(0)
	b.set_state(saved)
	var seq_b: Array = [b.next_float(), b.range_int(0, 100), b.range_float(1.0, 2.0), b.next_u32()]
	assert_eq(seq_a, seq_b, "mixed-method sequence must be reproducible from a restored state")


func test_mixed_method_sequence_same_seed() -> void:
	var a := SimRng.new(8)
	var b := SimRng.new(8)
	for i in 100:
		assert_eq(a.next_float(), b.next_float(), "next_float diverged at draw %d" % i)
		assert_eq(a.range_int(-10, 10), b.range_int(-10, 10), "range_int diverged at draw %d" % i)
		assert_eq(a.range_float(0.0, 5.0), b.range_float(0.0, 5.0), "range_float diverged at draw %d" % i)


func test_pcg32_known_vectors() -> void:
	# Reference values from an independent PCG32 implementation (unsigned 64-bit arithmetic, XSH-RR,
	# default stream, seed -> step, add seed, step). Guards against 64-bit wrap / logical-shift mistakes.
	var cases: Array = [
		[0, [3894649422, 2055130073, 2315086854, 2925816488, 3443325253], 1459328389850446429],
		[42, [3270867926, 1795671209, 1924641435, 1143034755, 4121910957], -8402867724520795593],
		[-1, [3643879478, 3444271506, 2072954526, 2577256464, 1548663211], 2572558967512121316],
		[0x7FFFFFFFFFFFFFFF, [808901937, 2039663947, 3323886478, 3494943133, 4188757070], -6650813069342654492],
	]
	for c: Array in cases:
		var rng := SimRng.new(c[0])
		var got: Array = []
		for i in 5:
			got.append(rng.next_u32())
		assert_eq(got, c[1], "u32 sequence for seed %d" % c[0])
		assert_eq(rng.get_state(), c[2], "state after 5 draws for seed %d" % c[0])
