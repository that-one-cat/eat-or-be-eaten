extends TestCase
## Species `xp_band_mult` (optional [x4], by the EATER's band at the moment of eating; default = 1 everywhere): schema,
## shipped data (only the two small prey fish carry [1.5, 1, 1, 1]), a whole swallow and the remains bits both apply it
## so a fish is worth the same swallowed or bitten apart, hunger and the bits' stored values stay unscaled, determinism.
## Swallow rule: target_len <= eater_len x swallow_ratio (0.10), so the whole-fish scenes use tiny fish lengths that a
## B1 (0.1 m) / B2 (0.3 m) player can swallow; bits (0.008 m) are swallowable by anyone.

const S3 := preload("res://tests/s3_support.gd")
const SMALL: StringName = &"small_reef_fish"
const SILVER: StringName = &"silver_schooling_fish"
const SOURCE: String = "species/test.json"
## [eater xp, eater band, fish length m] : B1 player 0.1 m swallows <= 0.01 m, B2 player (xp 100) 0.3 m swallows <= 0.03 m.
const B1_XP: float = 0.0
const B2_XP: float = 100.0
const B1_FISH_LEN: float = 0.009
const B2_FISH_LEN: float = 0.025


# ---------------------------------------------------------------- helpers

## World with the shipped content (optionally with every `xp_band_mult` removed first), no spawners.
func _world(world_seed: int = 3, strip: bool = false) -> SimWorld:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	if strip:
		for id in db.species_ids():
			db.get_species(id).erase("xp_band_mult")
	db.get_map(S3.MAP_ID)["spawners"] = []
	var w := SimWorld.new(world_seed, db)
	w.vitals_enabled = false  # no hunger drain: hunger deltas are exactly the swallow gains
	return w


func _mult(db: ContentDB, species: StringName, band: int) -> float:
	var m: Variant = db.get_species(species).get("xp_band_mult")
	return float((m as Array)[band - 1]) if m is Array else 1.0


func _falloff(w: SimWorld) -> Dictionary:
	return w.content.rules()["xp_falloff"]


## Player of `xp` swallows a pinned `species` fish of `fish_len` in front of the mouth; returns {gain, hunger_gain, fish, player}.
func _swallow(w: SimWorld, species: StringName, xp: float, fish_len: float) -> Dictionary:
	var p: SimEntity = S3.player_at(w, S3.ARENA, xp, Vector3.RIGHT)
	p.hunger = 20.0
	var spot: Vector3 = p.position + Vector3.RIGHT * (0.5 * S3.reach_m(w, p))
	var f: SimEntity = S3.npc_at(w, species, spot, fish_len)
	var xp0: float = p.xp
	S3.step_n(w, 3, {f.id: spot})
	return {"gain": p.xp - xp0, "hunger_gain": p.hunger - 20.0, "fish": f, "player": p, "len": p.length_m}


## Kills a `species` fish far from the player, then pins every bit in front of a player of `xp`; returns the XP gained.
func _eat_bits(w: SimWorld, species: StringName, xp: float, fish_len: float) -> Dictionary:
	var v: SimEntity = S3.npc_at(w, species, S3.ARENA + Vector3(0, 0, 40.0), fish_len)
	v.hp = 0.0
	w.step()
	var bits: Array[SimEntity] = S3.food_bits(w)
	var p: SimEntity = S3.player_at(w, S3.ARENA, xp, Vector3.RIGHT)
	p.hunger = 20.0
	var spot: Vector3 = p.position + Vector3.RIGHT * (0.5 * S3.reach_m(w, p))
	var pins: Dictionary = {}
	var base_sum: float = 0.0
	var expected_len: float = p.length_m
	for b in bits:
		pins[b.id] = spot
		base_sum += b.xp_value
	var xp0: float = p.xp
	S3.step_n(w, 3, pins)
	var left: int = 0
	for b in bits:
		if not S3.is_gone(w, b.id):
			left += 1
	return {"gain": p.xp - xp0, "hunger_gain": p.hunger - 20.0, "bits": bits, "base_sum": base_sum, "left": left, "len": expected_len}


# ---------------------------------------------------------------- schema

func test_shipped_data_only_the_two_small_prey_fish_carry_the_multiplier() -> void:
	var db: ContentDB = S3.content()
	for id in db.species_ids():
		var rec: Dictionary = db.get_species(id)
		if id == SMALL or id == SILVER:
			assert_eq(Array(rec.get("xp_band_mult", [])).map(func(x: Variant) -> float: return float(x)), [1.5, 1.0, 1.0, 1.0], "%s: 1.5x in B1 only" % id)
		else:
			assert_false(rec.has("xp_band_mult"), "%s: no multiplier (unchanged)" % id)
		assert_eq(ContentDB.validate_record(&"species", rec, SOURCE).size(), 0, "%s: valid" % id)


func test_validation_accepts_the_default_and_rejects_bad_shapes() -> void:
	var db: ContentDB = S3.content()
	var good: Dictionary = db.get_species(&"puffer").duplicate(true)
	assert_eq(ContentDB.validate_record(&"species", good, SOURCE).size(), 0, "no key is valid (default)")
	good["xp_band_mult"] = [1, 1, 1, 1]
	assert_eq(ContentDB.validate_record(&"species", good, SOURCE).size(), 0, "[1,1,1,1] is valid")
	good["xp_band_mult"] = [1.5, 0.25, 2, 10]
	assert_eq(ContentDB.validate_record(&"species", good, SOURCE).size(), 0, "any positive numbers are valid")
	var bad: Array = [[1, 1, 1], [1, 1, 1, 1, 1], 1.5, "1.5", {}, [1, 1, 1, 0], [1, -1, 1, 1], ["a", 1, 1, 1], [1, 1, null, 1], []]
	for v: Variant in bad:
		var rec: Dictionary = db.get_species(&"puffer").duplicate(true)
		rec["xp_band_mult"] = v
		var errs: PackedStringArray = ContentDB.validate_record(&"species", rec, SOURCE)
		assert_true(errs.size() >= 1, "rejected: %s" % str(v))
		for e in errs:
			assert_true(e.begins_with(SOURCE) and e.find("xp_band_mult") != -1, "error names the source and field: %s" % e)


# ---------------------------------------------------------------- whole swallow

func test_a_b1_eater_gets_one_and_a_half_times_xp_for_a_swallowed_small_prey_fish() -> void:
	for species in [SMALL, SILVER]:
		var w: SimWorld = _world()
		var r: Dictionary = _swallow(w, species, B1_XP, B1_FISH_LEN)
		assert_true(S3.is_gone(w, (r["fish"] as SimEntity).id), "%s: swallowed" % species)
		assert_eq((r["player"] as SimEntity).band, 1, "%s: eater is B1" % species)
		var base: float = float(w.content.get_species(species)["xp"])
		var expected: float = SimRules.xp_gain(base * 1.5, 0.1, B1_FISH_LEN, _falloff(w))
		assert_almost_eq(float(r["gain"]), expected, 1e-6, "%s: B1 gain = 1.5 x xp (%s)" % [species, expected])
		assert_almost_eq(float(r["gain"]), SimRules.xp_gain(base, 0.1, B1_FISH_LEN, _falloff(w)) * 1.5, 1e-6, "%s: exactly 1.5 x the unscaled gain" % species)
		assert_almost_eq(float(r["hunger_gain"]), SimRules.hunger_from_xp(base, w.content.rules()["hunger_per_xp"]), 1e-6, "%s: hunger is NOT scaled" % species)


func test_a_b2_eater_gets_the_plain_xp_for_the_same_fish() -> void:
	for species in [SMALL, SILVER]:
		var w: SimWorld = _world()
		var r: Dictionary = _swallow(w, species, B2_XP, B2_FISH_LEN)
		assert_true(S3.is_gone(w, (r["fish"] as SimEntity).id), "%s: swallowed" % species)
		assert_eq((r["player"] as SimEntity).band, 2, "%s: eater is B2" % species)
		var base: float = float(w.content.get_species(species)["xp"])
		assert_almost_eq(float(r["gain"]), SimRules.xp_gain(base, 0.3, B2_FISH_LEN, _falloff(w)), 1e-6, "%s: B2 gain = unscaled" % species)


func test_a_species_without_the_key_is_unchanged_in_every_band() -> void:
	for xp in [B1_XP, B2_XP]:
		var w: SimWorld = _world()
		var len_fish: float = B1_FISH_LEN if xp == B1_XP else B2_FISH_LEN
		var r: Dictionary = _swallow(w, &"puffer", xp, len_fish)
		var base: float = float(w.content.get_species(&"puffer")["xp"])
		assert_almost_eq(float(r["gain"]), SimRules.xp_gain(base, float(r["len"]), len_fish, _falloff(w)), 1e-6, "puffer at xp %s: unscaled" % xp)
	# the shipped small fish with the key stripped from the data behaves as the unscaled value in B1
	var ws: SimWorld = _world(3, true)
	var rs: Dictionary = _swallow(ws, SMALL, B1_XP, B1_FISH_LEN)
	var base_s: float = float(ws.content.get_species(SMALL)["xp"])
	assert_almost_eq(float(rs["gain"]), SimRules.xp_gain(base_s, 0.1, B1_FISH_LEN, _falloff(ws)), 1e-6, "stripped key: unscaled in B1")


# ---------------------------------------------------------------- bitten apart

func test_remains_bits_carry_the_base_xp_and_the_source_species() -> void:
	var w: SimWorld = _world()
	var v: SimEntity = S3.npc_at(w, SMALL, S3.ARENA, B1_FISH_LEN)
	v.hp = 0.0
	w.step()
	var sum: float = 0.0
	var bits: Array[SimEntity] = S3.food_bits(w)
	assert_true(bits.size() >= 3, "bits exist")
	for b in bits:
		sum += b.xp_value
		assert_eq(b.source_species, SMALL, "the bit remembers its species")
	assert_almost_eq(sum, float(w.content.get_species(SMALL)["xp"]), 1e-6, "bits carry the unscaled species XP")


func test_bitten_apart_total_equals_swallowed_total_in_b1_and_b2() -> void:
	for species in [SMALL, SILVER]:
		for xp in [B1_XP, B2_XP]:
			var fish_len: float = B1_FISH_LEN if xp == B1_XP else B2_FISH_LEN
			var whole: Dictionary = _swallow(_world(), species, xp, fish_len)
			var w: SimWorld = _world()
			var bits: Dictionary = _eat_bits(w, species, xp, fish_len)
			assert_eq(int(bits["left"]), 0, "%s xp %s: every bit eaten" % [species, xp])
			assert_almost_eq(float(bits["gain"]), float(whole["gain"]), 1e-6, "%s xp %s: bits total == swallowed (%s)" % [species, xp, whole["gain"]])
			assert_almost_eq(float(bits["hunger_gain"]), float(whole["hunger_gain"]), 1e-6, "%s xp %s: hunger the same too" % [species, xp])
	var w1: SimWorld = _world()
	var b1: Dictionary = _eat_bits(w1, SMALL, B1_XP, B1_FISH_LEN)
	assert_almost_eq(float(b1["gain"]), float(b1["base_sum"]) * 1.5, 1e-6, "B1 bits: 1.5 x the stored bit XP")
	var w2: SimWorld = _world()
	var b2: Dictionary = _eat_bits(w2, SMALL, B2_XP, B2_FISH_LEN)
	assert_almost_eq(float(b2["gain"]), float(b2["base_sum"]), 1e-6, "B2 bits: the stored bit XP")


# ---------------------------------------------------------------- determinism

func test_runs_are_deterministic_and_the_multiplier_only_changes_xp_and_what_follows() -> void:
	var hashes: Array[int] = []
	for i in 2:
		var w: SimWorld = _world(11)
		_eat_bits(w, SMALL, B1_XP, B1_FISH_LEN)
		hashes.append(w.state_hash())
	assert_eq(hashes[0], hashes[1], "same seed and script: same hash")
	var a: SimWorld = _world(11)
	var b: SimWorld = _world(11, true)
	assert_eq(a.state_hash(), b.state_hash(), "before any eating the data key does not change the state hash")
	var ra: Dictionary = _eat_bits(a, SMALL, B1_XP, B1_FISH_LEN)
	var rb: Dictionary = _eat_bits(b, SMALL, B1_XP, B1_FISH_LEN)
	assert_almost_eq(float(ra["gain"]), float(rb["gain"]) * 1.5, 1e-6, "same run: 1.5x the XP with the key")
	assert_eq(a.tick, b.tick, "same tick count")
	assert_eq((ra["bits"] as Array).size(), (rb["bits"] as Array).size(), "same RNG draws: same number of bits")
