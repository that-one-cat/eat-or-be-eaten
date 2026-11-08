extends TestCase
## S3 remains: a creature that dies is replaced by 3-6 glowing food bits (SimEntity.Kind.FOOD_BIT) that carry its
## XP and hunger value, drift slowly, expire, sit in the shared grid and can be swallowed.
## Deaths are produced with hp = 0 (the sim must turn HP <= 0 into DIED) in worlds without spawners and without
## other creatures, so bits are never eaten or hunted unless a test adds an eater.

const S3 := preload("res://tests/s3_support.gd")
const SPECIES: Array[StringName] = [&"plankton", &"silver_schooling_fish", &"small_reef_fish", &"puffer", &"barracuda", &"grouper", &"shark"]


func _kill(w: SimWorld, species: StringName, pos: Vector3 = S3.ARENA) -> Dictionary:
	var v: SimEntity = S3.npc_at(w, species, pos)
	v.hp = 0.0
	var t0: int = w.tick
	w.step()
	return {"victim": v, "tick": t0}


func _bits_min() -> int:
	return int(S3.rule_f(S3.content(), "remains.food_bits.min"))


func _bits_max() -> int:
	return int(S3.rule_f(S3.content(), "remains.food_bits.max"))


# ======================================================== creation

func test_a_dead_creature_becomes_three_to_six_food_bits() -> void:
	for species in SPECIES:
		var w: SimWorld = S3.make_world(5)
		var r: Dictionary = _kill(w, species)
		var v: SimEntity = r["victim"]
		assert_eq(S3.events_of(w, SimEvent.Type.DIED, int(r["tick"])).size(), 1, "%s: one DIED event" % species)
		assert_true(S3.is_gone(w, v.id), "%s: the creature is gone" % species)
		assert_false(w.grid.has(v.id), "%s: and out of the grid" % species)
		var bits: Array[SimEntity] = S3.food_bits(w)
		assert_true(bits.size() >= _bits_min() and bits.size() <= _bits_max(), "%s: %d food bits (data range %d-%d)" % [species, bits.size(), _bits_min(), _bits_max()])
		assert_true(S3.events_of(w, SimEvent.Type.FOOD_SPAWNED, int(r["tick"])).size() >= 1, "%s: FOOD_SPAWNED reported" % species)


func test_food_bit_count_uses_the_whole_inclusive_range_and_stays_inside_it() -> void:
	var seen: Dictionary = {}
	for world_seed in range(1, 41):
		var w: SimWorld = S3.make_world(world_seed)
		_kill(w, &"puffer")
		var n: int = S3.food_bits(w).size()
		seen[n] = true
		assert_true(n >= _bits_min() and n <= _bits_max(), "seed %d: %d bits outside %d-%d" % [world_seed, n, _bits_min(), _bits_max()])
	assert_true(seen.has(_bits_min()), "the minimum (%d) occurs over 40 seeds; seen %s" % [_bits_min(), seen.keys()])
	assert_true(seen.has(_bits_max()), "the maximum (%d) occurs over 40 seeds; seen %s" % [_bits_max(), seen.keys()])


func test_food_bit_count_is_deterministic_for_a_seed() -> void:
	var counts: Array[int] = []
	for i in 3:
		var w: SimWorld = S3.make_world(77)
		_kill(w, &"grouper")
		counts.append(S3.food_bits(w).size())
	assert_eq(counts[0], counts[1], "same seed, same count")
	assert_eq(counts[1], counts[2], "same seed, same count (third run)")


func test_bits_carry_the_creatures_xp_and_hunger_value() -> void:
	var per_xp: float = S3.rule_f(S3.content(), "hunger_per_xp")
	for species in SPECIES:
		var w: SimWorld = S3.make_world(9)
		_kill(w, species)
		var xp_sum: float = 0.0
		var hunger_sum: float = 0.0
		for b: SimEntity in S3.food_bits(w):
			assert_true(b.xp_value > 0.0, "%s: every bit carries XP" % species)
			assert_true(b.hunger_value > 0.0, "%s: every bit carries hunger" % species)
			xp_sum += b.xp_value
			hunger_sum += b.hunger_value
		var xp: float = float(w.content.get_species(species)["xp"])
		assert_almost_eq(xp_sum, xp, 1e-6, "%s: bits sum to the species XP (%s)" % [species, xp])
		assert_almost_eq(hunger_sum, xp * per_xp, 1e-6, "%s: bits sum to XP x hunger_per_xp" % species)


func test_bits_are_entities_in_the_grid_near_the_death_position() -> void:
	var w: SimWorld = S3.make_world(5)
	var r: Dictionary = _kill(w, &"grouper")
	var v: SimEntity = r["victim"]
	var tick_of_death: int = int(r["tick"])
	var lifetime: int = S3.ticks(S3.rule_f(w.content, "remains.food_bits.lifetime_s"))
	for b: SimEntity in S3.food_bits(w):
		assert_eq(b.kind, SimEntity.Kind.FOOD_BIT, "kind")
		assert_true(b.alive, "bits are alive entities")
		assert_true(w.grid.has(b.id), "bit %d is in the spatial grid" % b.id)
		if w.grid.has(b.id):
			assert_true(w.grid.position_of(b.id).distance_to(b.position) < 1e-4, "bit %d: grid position equals entity position" % b.id)
		assert_true(b.position.distance_to(S3.ARENA) <= 5.0 + v.length_m, "bit %d appears at the remains (%s m away)" % [b.id, b.position.distance_to(S3.ARENA)])
		assert_true(b.expire_tick >= tick_of_death + lifetime - 2 and b.expire_tick <= tick_of_death + lifetime + 3, "expire_tick %d is death tick %d + lifetime %d ticks" % [b.expire_tick, tick_of_death, lifetime])


# ======================================================== drift and expiry

func test_bits_drift_no_faster_than_the_data_speed() -> void:
	var w: SimWorld = S3.make_world(5)
	_kill(w, &"grouper")
	var start: Dictionary = {}
	for b: SimEntity in S3.food_bits(w):
		start[b.id] = b.position
	assert_true(start.size() >= _bits_min(), "bits exist")
	var drift: float = S3.rule_f(w.content, "remains.food_bits.drift_mps")
	assert_true(drift >= 0.0, "drift speed in data")
	S3.step_n(w, 60)
	for id: int in start.keys():
		var b: SimEntity = w.get_entity(id)
		assert_not_null(b, "bit %d still exists after 2 s" % id)
		if b != null:
			var moved: float = b.position.distance_to(start[id])
			assert_true(moved <= drift * 2.0 * 1.05 + 0.02, "bit %d moved %s m in 2 s, drift_mps %s" % [id, moved, drift])


func test_bits_expire_after_the_lifetime_and_leave_the_grid() -> void:
	var w: SimWorld = S3.make_world(5)
	_kill(w, &"puffer")
	var ids: Array[int] = []
	for b: SimEntity in S3.food_bits(w):
		ids.append(b.id)
	var lifetime: int = S3.ticks(S3.rule_f(w.content, "remains.food_bits.lifetime_s"))
	assert_true(lifetime > 60, "lifetime_s must be longer than 2 s (got %d ticks)" % lifetime)
	S3.step_n(w, lifetime - 6)
	assert_eq(S3.food_bits(w).size(), ids.size(), "all bits still there shortly before the lifetime ends")
	S3.step_n(w, 12)
	assert_eq(S3.food_bits(w).size(), 0, "all bits expired shortly after the lifetime")
	for id in ids:
		assert_null(w.get_entity(id), "bit %d removed" % id)
		assert_false(w.grid.has(id), "bit %d out of the grid" % id)
	assert_eq(w.entity_count(), 0, "nothing is left in the world")
	assert_eq(w.grid.count(), 0, "nothing is left in the grid")


# ======================================================== eating the remains

func test_swallowing_a_food_bit_gives_xp_and_hunger() -> void:
	var w: SimWorld = S3.make_world(5)
	_kill(w, &"grouper")
	var bits: Array[SimEntity] = S3.food_bits(w)
	assert_true(bits.size() >= 1, "bits exist")
	if bits.is_empty():
		return
	# The rule swallows every bit in the mouth at once: take the most isolated bit and size the eater so its reach
	# is half that bit's nearest-neighbour distance, so exactly one bit is in reach.
	var target: SimEntity = bits[0]
	var gap: float = INF
	for a: SimEntity in bits:
		var nn: float = INF
		for b: SimEntity in bits:
			if b != a:
				nn = minf(nn, a.position.distance_to(b.position))
		if gap == INF or nn > gap:
			gap = nn
			target = a
	var value: float = target.xp_value
	var reach_mult: float = S3.rule_f(w.content, "mouth_reach_mult")
	var band1_min: float = float((w.content.get_band(1)["length_m"] as Dictionary)["min"])
	var xp: float = S3.xp_for_length(w.content, clampf(0.5 * gap / reach_mult, band1_min, 1.2))
	var length: float = S3.length_ref(w.content, xp)
	var reach: float = length * reach_mult
	assert_true(bits.size() == 1 or 1.5 * reach < gap, "precondition: only the target bit is within reach (reach %s, gap %s)" % [reach, gap])
	var p: SimEntity = S3.player_at(w, target.position - Vector3.RIGHT * (0.5 * reach), xp, Vector3.RIGHT)
	p.hunger = 20.0
	var xp0: float = p.xp
	var t0: int = w.tick
	S3.step_n(w, 3, {target.id: target.position})
	assert_true(S3.is_gone(w, target.id), "the bit in front of the mouth is swallowed")
	assert_true(S3.count_between(w, SimEvent.Type.EATEN, p.id, target.id, t0) >= 1, "EATEN names the eater and the bit")
	var gained: float = p.xp - xp0
	assert_true(gained > 0.0 and gained <= value + 1e-6, "XP gained %s is positive and at most the bit's %s" % [gained, value])
	assert_true(p.hunger > 20.0, "hunger restored (%s)" % p.hunger)
	assert_false(w.grid.has(target.id), "eaten bit left the grid")
