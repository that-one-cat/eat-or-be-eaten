extends TestCase
## SimRules (res://scripts/sim/sim_rules.gd): static pure functions for the S3 eat/bite/grow maths.
## Pure unit tests: no SimWorld, no stepping. Numbers come from ContentDB; GAME_DESIGN literals are pinned in
## test_s3_content_validation.gd. Contract: can_swallow, creature_max_hp, bite_damage, xp_gain, length_for_xp,
## hunger_from_xp (hunger_drain_per_tick has no pinned signature; the drain rate is tested through the world).

const S3 := preload("res://tests/s3_support.gd")

var _db: ContentDB = null


func before_each() -> void:
	_db = S3.content()


func _falloff() -> Dictionary:
	return _db.rules()["xp_falloff"]


# ======================================================== source shape

func test_sim_rules_source_is_stateless_static_and_pure() -> void:
	var path: String = "res://scripts/sim/sim_rules.gd"
	assert_true(FileAccess.file_exists(path), "contract file missing: %s" % path)
	if not FileAccess.file_exists(path):
		return
	var lines: Array[String] = []
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		lines.append(raw.split("#")[0])
	var has_class: bool = false
	var has_extends: bool = false
	for l in lines:
		if l.begins_with("class_name SimRules"):
			has_class = true
		if l.strip_edges() == "extends RefCounted":
			has_extends = true
		assert_false(l.begins_with("func "), "SimRules must only have static functions (found '%s')" % l.strip_edges())
		assert_false(l.begins_with("var ") or l.begins_with("static var "), "SimRules holds no state (found '%s')" % l.strip_edges())
	assert_true(has_class, "class_name SimRules")
	assert_true(has_extends, "SimRules extends RefCounted")
	var bad := RegEx.new()
	assert_eq(bad.compile("\\brandf\\s*\\(|\\brandi\\s*\\(|\\brandomize\\s*\\(|\\bget_tree\\s*\\(|Time\\.get_|OS\\.get_ticks|extends\\s+Node"), OK, "test regex")
	var hit: RegExMatch = bad.search("\n".join(lines))
	assert_null(hit, "sim_rules.gd must be pure (found '%s')" % (hit.get_string() if hit != null else ""))


# ======================================================== swallow rule

func test_can_swallow_threshold_edges() -> void:
	var ratio: float = float(_db.rules()["swallow_ratio"])
	for eater in [0.1, 0.5, 1.0, 2.0, 3.5, 10.0]:
		var e: float = eater
		var limit: float = e * ratio
		assert_true(SimRules.can_swallow(e, limit, ratio), "exactly %s of an eater of %s is swallowable" % [ratio, e])
		assert_true(SimRules.can_swallow(e, limit * 0.9999, ratio), "just below the limit swallows (eater %s)" % e)
		assert_false(SimRules.can_swallow(e, limit * 1.0001, ratio), "just above the limit does not (eater %s)" % e)
		assert_false(SimRules.can_swallow(e, e, ratio), "same size is never swallowed (eater %s)" % e)
		assert_false(SimRules.can_swallow(e, e * 2.0, ratio), "bigger is never swallowed (eater %s)" % e)
		assert_true(SimRules.can_swallow(e, 0.0, ratio), "a zero-length target is trivially swallowable (eater %s)" % e)


func test_can_swallow_uses_the_ratio_argument() -> void:
	assert_true(SimRules.can_swallow(1.0, 0.25, 0.25), "0.25 of 1.0 at ratio 0.25")
	assert_false(SimRules.can_swallow(1.0, 0.2501, 0.25), "just above ratio 0.25")
	assert_false(SimRules.can_swallow(1.0, 0.11, 0.10), "0.11 at ratio 0.10")
	assert_true(SimRules.can_swallow(1.0, 0.11, 0.12), "0.11 at ratio 0.12")


func test_b1_can_swallow_plankton_but_never_a_puffer() -> void:
	var ratio: float = float(_db.rules()["swallow_ratio"])
	var plankton: Dictionary = (_db.get_species(&"plankton")["length_m"] as Dictionary)
	var puffer: Dictionary = (_db.get_species(&"puffer")["length_m"] as Dictionary)
	for player_len in [0.25, 0.3]:
		for plankton_len in [float(plankton["min"]), float(plankton["max"])]:
			assert_true(SimRules.can_swallow(player_len, plankton_len, ratio), "B1 %s m swallows plankton %s m" % [player_len, plankton_len])
	var b1: Dictionary = _db.get_band(1)["length_m"]
	for player_len in [float(b1["min"]), 0.2, float(b1["max"])]:
		for puffer_len in [float(puffer["min"]), 0.4, float(puffer["max"])]:
			assert_false(SimRules.can_swallow(player_len, puffer_len, ratio), "B1 %s m must not swallow a puffer of %s m" % [player_len, puffer_len])


# ======================================================== HP and bite damage

func test_creature_max_hp_is_base_hp_times_length_squared() -> void:
	assert_almost_eq(SimRules.creature_max_hp(100.0, 0.5), 25.0, 1e-9)
	assert_almost_eq(SimRules.creature_max_hp(100.0, 1.0), 100.0, 1e-9)
	assert_almost_eq(SimRules.creature_max_hp(100.0, 2.0), 400.0, 1e-9)
	assert_almost_eq(SimRules.creature_max_hp(50.0, 3.0), 450.0, 1e-9)
	assert_almost_eq(SimRules.creature_max_hp(100.0, 0.0), 0.0, 1e-12)


func test_bite_damage_is_power_times_length_squared_times_multiplier() -> void:
	assert_almost_eq(SimRules.bite_damage(25.0, 2.0, 1.0), 100.0, 1e-9)
	assert_almost_eq(SimRules.bite_damage(25.0, 2.0, 1.5), 150.0, 1e-9)
	assert_almost_eq(SimRules.bite_damage(25.0, 0.1, 1.0), 0.25, 1e-9)
	assert_almost_eq(SimRules.bite_damage(25.0, 1.0, 0.0), 0.0, 1e-12)
	assert_almost_eq(SimRules.bite_damage(10.0, 3.0, 2.0), 180.0, 1e-9)


func test_same_size_creature_dies_in_about_four_bites_with_real_data() -> void:
	var checked: int = 0
	for sid: StringName in _db.species_ids():
		var sp: Dictionary = _db.get_species(sid)
		if sp.has("hp_override"):
			continue  # the boss has an explicit HP override (S6)
		for bi in range(1, _db.band_count() + 1):
			var lm: Dictionary = _db.get_band(bi)["length_m"]
			var length: float = sqrt(float(lm["min"]) * float(lm["max"]))
			var power: float = float(_db.get_band(bi)["bite_power"])
			var hp: float = SimRules.creature_max_hp(float(sp["base_hp"]), length)
			var dmg: float = SimRules.bite_damage(power, length, 1.0)
			assert_true(dmg > 0.0, "damage must be positive (%s, band %d)" % [sid, bi])
			var bites: int = int(ceil(hp / dmg - 1e-9))
			assert_true(bites >= 3 and bites <= 5, "GAME_DESIGN: same-size dies in about 4 bites; %s at band %d needs %d (hp %s / dmg %s)" % [sid, bi, bites, hp, dmg])
			checked += 1
	assert_true(checked >= 28, "7 species x 4 bands checked, got %d" % checked)


# ======================================================== XP falloff

func test_xp_gain_is_full_at_and_above_the_full_ratio() -> void:
	var f: Dictionary = _falloff()
	var full: float = float(f["full_at_ratio"])
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, full, f), 40.0, 1e-9, "exactly at full_at_ratio")
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, full * 10.0, f), 40.0, 1e-9, "above the ratio")
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, 0.5, f), 40.0, 1e-9, "a half-size target (bitten and killed)")
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, 5.0, f), 40.0, 1e-9, "a bigger target never gives a bonus")


func test_xp_gain_is_clamped_to_min_mult_at_and_below_min_ratio() -> void:
	var f: Dictionary = _falloff()
	var mn: float = float(f["min_ratio"])
	var floor_mult: float = float(f["min_mult"])
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, mn, f), 40.0 * floor_mult, 1e-9, "exactly at min_ratio")
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, mn * 0.1, f), 40.0 * floor_mult, 1e-9, "far below min_ratio")
	var tiny: float = SimRules.xp_gain(40.0, 1.0, 0.0, f)
	assert_true(is_finite(tiny), "a zero-length target must not produce NaN/INF")
	assert_almost_eq(tiny, 40.0 * floor_mult, 1e-9, "zero-length target = floor")


func test_xp_gain_is_linear_in_log_ratio_between_the_endpoints() -> void:
	var f: Dictionary = _falloff()
	var mn: float = float(f["min_ratio"])
	var full: float = float(f["full_at_ratio"])
	var floor_mult: float = float(f["min_mult"])
	var mid: float = sqrt(mn * full)  # geometric middle = halfway in log-ratio
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, mid, f), 40.0 * 0.5 * (1.0 + floor_mult), 1e-6, "midpoint in log space")
	var quarter: float = mn * pow(full / mn, 0.25)
	assert_almost_eq(SimRules.xp_gain(40.0, 1.0, quarter, f), 40.0 * (floor_mult + 0.25 * (1.0 - floor_mult)), 1e-6, "quarter point in log space")


func test_xp_gain_is_monotonic_and_bounded_over_a_ratio_sweep() -> void:
	var f: Dictionary = _falloff()
	var floor_mult: float = float(f["min_mult"])
	var lo: float = float(f["min_ratio"]) * 0.1
	var hi: float = float(f["full_at_ratio"]) * 10.0
	var prev: float = -1.0
	for i in 61:
		var ratio: float = lo * pow(hi / lo, float(i) / 60.0)
		var g: float = SimRules.xp_gain(10.0, 1.0, ratio, f)
		assert_true(g >= prev - 1e-9, "non-decreasing at ratio %s" % ratio)
		assert_true(g >= 10.0 * floor_mult - 1e-9 and g <= 10.0 + 1e-9, "within [floor, full] at ratio %s (got %s)" % [ratio, g])
		prev = g


func test_xp_gain_scales_linearly_with_target_xp_and_uses_the_length_ratio() -> void:
	var f: Dictionary = _falloff()
	var a: float = SimRules.xp_gain(1.0, 1.0, 0.015, f)
	assert_almost_eq(SimRules.xp_gain(60.0, 1.0, 0.015, f), 60.0 * a, 1e-9, "linear in target xp")
	assert_almost_eq(SimRules.xp_gain(0.0, 1.0, 0.015, f), 0.0, 1e-12, "zero-xp target gives nothing")
	# Only the ratio matters, not the absolute sizes.
	assert_almost_eq(SimRules.xp_gain(1.0, 3.0, 0.045, f), a, 1e-9, "ratio-only: 0.045/3.0 == 0.015/1.0")


func test_b4_cannot_farm_plankton_but_b1_gets_full_xp() -> void:
	var f: Dictionary = _falloff()
	var plankton_xp: float = float(_db.get_species(&"plankton")["xp"])
	assert_almost_eq(SimRules.xp_gain(plankton_xp, 0.25, 0.02, f), plankton_xp, 1e-9, "B1 0.25 m eating 0.02 m plankton: full XP")
	var b4: float = SimRules.xp_gain(plankton_xp, 3.5, 0.02, f)
	assert_true(b4 <= 0.25 * plankton_xp, "B4 3.5 m eating plankton must be heavily reduced (got %s of %s)" % [b4, plankton_xp])
	assert_true(b4 >= float(f["min_mult"]) * plankton_xp - 1e-9, "never below the floor")


# ======================================================== growth curve

func test_length_for_xp_hits_the_band_endpoints() -> void:
	var bands: Array = S3.bands(_db)
	assert_almost_eq(SimRules.length_for_xp(0.0, bands), 0.10, 1e-6, "0 XP = band 1 minimum")
	assert_almost_eq(SimRules.length_for_xp(100.0, bands), 0.30, 1e-6, "100 XP = B1 max = B2 min")
	assert_almost_eq(SimRules.length_for_xp(300.0, bands), 0.90, 1e-6, "300 XP = B3 min")
	assert_almost_eq(SimRules.length_for_xp(700.0, bands), 2.00, 1e-6, "700 XP = B4 min")
	assert_almost_eq(SimRules.length_for_xp(1200.0, bands), 3.50, 1e-6, "GAME_DESIGN: B4 reaches 3.5 m at 1200 XP")


func test_length_for_xp_is_clamped_below_zero_and_above_the_last_threshold() -> void:
	var bands: Array = S3.bands(_db)
	assert_almost_eq(SimRules.length_for_xp(-50.0, bands), 0.10, 1e-6, "negative XP clamps to the minimum")
	assert_almost_eq(SimRules.length_for_xp(1500.0, bands), 3.50, 1e-6, "above 1200 XP stays at 3.5 m")
	assert_almost_eq(SimRules.length_for_xp(1.0e9, bands), 3.50, 1e-6, "huge XP stays at 3.5 m")


func test_length_for_xp_interpolates_on_a_log_scale_inside_each_band() -> void:
	var bands: Array = S3.bands(_db)
	# Halfway through each band's XP span: the geometric mean of the band's length range.
	assert_almost_eq(SimRules.length_for_xp(50.0, bands), sqrt(0.10 * 0.30), 1e-6, "B1 midpoint")
	assert_almost_eq(SimRules.length_for_xp(200.0, bands), sqrt(0.30 * 0.90), 1e-6, "B2 midpoint")
	assert_almost_eq(SimRules.length_for_xp(500.0, bands), sqrt(0.90 * 2.00), 1e-6, "B3 midpoint")
	assert_almost_eq(SimRules.length_for_xp(950.0, bands), sqrt(2.00 * 3.50), 1e-6, "B4 midpoint")
	# Quarter points.
	assert_almost_eq(SimRules.length_for_xp(25.0, bands), 0.10 * pow(3.0, 0.25), 1e-6, "B1 quarter")
	assert_almost_eq(SimRules.length_for_xp(825.0, bands), 2.00 * pow(1.75, 0.25), 1e-6, "B4 quarter")


func test_length_for_xp_matches_the_reference_for_every_band_and_is_monotonic() -> void:
	var bands: Array = S3.bands(_db)
	var prev: float = 0.0
	var xp: float = 0.0
	while xp <= 1300.0:
		var l: float = SimRules.length_for_xp(xp, bands)
		assert_almost_eq(l, S3.length_ref(_db, xp), 1e-6, "reference at %s XP" % xp)
		assert_true(l >= prev - 1e-9, "non-decreasing at %s XP" % xp)
		if prev > 0.0:
			assert_true(l / prev <= 1.07, "no jump larger than 7%% per 5 XP at %s XP (got x%s)" % [xp, l / prev])
		prev = l
		xp += 5.0


func test_xp_for_length_reference_round_trips() -> void:
	for length_m in [0.12, 0.25, 0.5, 0.75, 1.2, 1.8, 2.5, 3.0]:
		var l: float = length_m
		assert_almost_eq(S3.length_ref(_db, S3.xp_for_length(_db, l)), l, 1e-6, "round trip at %s m" % l)


# ======================================================== hunger conversion

func test_hunger_from_xp_is_proportional() -> void:
	var per_xp: float = float(_db.rules()["hunger_per_xp"])
	assert_almost_eq(SimRules.hunger_from_xp(3.0, per_xp), 3.0 * per_xp, 1e-9)
	assert_almost_eq(SimRules.hunger_from_xp(0.0, per_xp), 0.0, 1e-12)
	assert_almost_eq(SimRules.hunger_from_xp(10.0, 2.0), 20.0, 1e-9)
	assert_almost_eq(SimRules.hunger_from_xp(2.0, 0.5), 1.0, 1e-9)
