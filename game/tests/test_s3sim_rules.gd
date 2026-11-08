extends TestCase
## S3 impl-A: SimRules pure formulas (eat / bite / growth / hunger maths) and ContentDB validation of the rule
## fields added in S3. Numbers come from res://data where the test is about the shipped data.

static var _db: ContentDB = null


func _content() -> ContentDB:
	if _db == null:
		_db = ContentDB.load_from_dir("res://data")
	return _db


func _bands() -> Array:
	var out: Array = []
	for i in range(1, _content().band_count() + 1):
		out.append(_content().get_band(i))
	return out


func _rules_copy() -> Dictionary:
	return _content().rules().duplicate(true)


func _rule_errors(rules: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"rules", rules, "rules/core.json")


func _has_error(errs: PackedStringArray, prefix: String) -> bool:
	for e in errs:
		if e.begins_with(prefix):
			return true
	return false


# ---- swallow / HP / bite

func test_can_swallow_is_inclusive_at_the_ratio() -> void:
	assert_true(SimRules.can_swallow(1.0, 0.1, 0.1), "exactly 10% swallows")
	assert_false(SimRules.can_swallow(1.0, 0.1001, 0.1), "above 10% does not")
	assert_true(SimRules.can_swallow(0.1, 0.008, 0.1), "a B1 fish swallows a food bit (rules remains.food_bits.length_m)")
	assert_false(SimRules.can_swallow(1.0, 1.0, 0.1), "same size never")


func test_creature_hp_and_bite_damage_formulas() -> void:
	assert_almost_eq(SimRules.creature_max_hp(100.0, 0.4), 16.0, 1e-9, "base_hp * L^2")
	assert_almost_eq(SimRules.bite_damage(25.0, 0.4, 1.0), 4.0, 1e-9, "bite_power * L^2")
	assert_almost_eq(SimRules.bite_damage(25.0, 1.5, 1.5), 84.375, 1e-9, "x species bite_mult")
	# GAME_DESIGN: same-size creature dies in about 4 bites with the shipped numbers
	var hp: float = SimRules.creature_max_hp(100.0, 0.5)
	var dmg: float = SimRules.bite_damage(float(_content().get_band(2)["bite_power"]), 0.5, 1.0)
	assert_eq(ceili(hp / dmg - 1e-9), 4, "4 bites")


# ---- XP falloff

func test_xp_gain_full_floor_and_log_linear_middle() -> void:
	var f: Dictionary = {"full_at_ratio": 0.05, "min_ratio": 0.005, "min_mult": 0.1}
	assert_almost_eq(SimRules.xp_gain(10.0, 1.0, 0.05, f), 10.0, 1e-9, "full at full_at_ratio")
	assert_almost_eq(SimRules.xp_gain(10.0, 1.0, 2.0, f), 10.0, 1e-9, "no bonus for bigger targets")
	assert_almost_eq(SimRules.xp_gain(10.0, 1.0, 0.005, f), 1.0, 1e-9, "floor at min_ratio")
	assert_almost_eq(SimRules.xp_gain(10.0, 1.0, 0.0001, f), 1.0, 1e-9, "floor below min_ratio")
	assert_almost_eq(SimRules.xp_gain(10.0, 1.0, sqrt(0.05 * 0.005), f), 5.5, 1e-9, "log midpoint = halfway between 0.1 and 1")
	assert_almost_eq(SimRules.xp_gain(10.0, 0.0, 0.01, f), 1.0, 1e-9, "zero-length eater: floor, finite")
	assert_true(is_finite(SimRules.xp_gain(10.0, 1.0, 0.0, f)), "zero-length target stays finite")


# ---- growth curve

func test_length_for_xp_band_endpoints_log_scale_and_clamps() -> void:
	var b: Array = _bands()
	assert_almost_eq(SimRules.length_for_xp(0.0, b), 0.10, 1e-9, "0 XP = B1 min")
	assert_almost_eq(SimRules.length_for_xp(100.0, b), 0.30, 1e-9, "B2 threshold")
	assert_almost_eq(SimRules.length_for_xp(300.0, b), 0.90, 1e-9, "B3 threshold")
	assert_almost_eq(SimRules.length_for_xp(700.0, b), 2.00, 1e-9, "B4 threshold")
	assert_almost_eq(SimRules.length_for_xp(1200.0, b), 3.50, 1e-9, "B4 grows to 3.5 m at 1200 XP")
	assert_almost_eq(SimRules.length_for_xp(5000.0, b), 3.50, 1e-9, "clamped above")
	assert_almost_eq(SimRules.length_for_xp(-10.0, b), 0.10, 1e-9, "clamped below")
	assert_almost_eq(SimRules.length_for_xp(50.0, b), sqrt(0.10 * 0.30), 1e-9, "log midpoint of B1")
	assert_almost_eq(SimRules.length_for_xp(99.999, b), 0.30, 1e-4, "continuous at the B1/B2 boundary")
	assert_almost_eq(SimRules.length_for_xp(10.0, []), 0.0, 1e-12, "no bands")


func test_band_for_xp_and_band_for_length() -> void:
	var b: Array = _bands()
	assert_eq(SimRules.band_for_xp(-5.0, b), 1, "negative XP")
	assert_eq(SimRules.band_for_xp(99.9, b), 1, "below B2")
	assert_eq(SimRules.band_for_xp(100.0, b), 2, "B2 at 100")
	assert_eq(SimRules.band_for_xp(700.0, b), 4, "B4 at 700")
	assert_eq(SimRules.band_for_xp(700.0, b), _content().band_for_xp(700.0), "same as ContentDB.band_for_xp")
	assert_eq(SimRules.band_for_length(0.05, b), 1, "below B1 clamps to 1")
	assert_eq(SimRules.band_for_length(0.30, b), 1, "shared boundary belongs to the lower band")
	assert_eq(SimRules.band_for_length(0.31, b), 2, "B2")
	assert_eq(SimRules.band_for_length(1.5, b), 3, "grouper 1.5 m -> B3")
	assert_eq(SimRules.band_for_length(10.0, b), 4, "giant shark clamps to B4")


# ---- hunger

func test_hunger_drain_and_restore() -> void:
	var per_tick: float = SimRules.hunger_drain_per_tick(100.0, 90.0, 1.0, 1.0 / 30.0)
	assert_almost_eq(per_tick * 90.0 * 30.0, 100.0, 1e-9, "full to empty in 90 s at x1")
	assert_almost_eq(SimRules.hunger_drain_per_tick(100.0, 90.0, 2.0, 1.0 / 30.0), per_tick * 2.0, 1e-12, "band multiplier")
	assert_almost_eq(SimRules.hunger_drain_per_tick(100.0, 0.0, 1.0, 1.0 / 30.0), 0.0, 1e-12, "no drain without a duration")
	assert_almost_eq(SimRules.hunger_from_xp(15.0, 2.0), 30.0, 1e-12, "proportional to XP")


# ---- mouth cone

func test_in_cone_and_bite_cone() -> void:
	var o := Vector3.ZERO
	var h := Vector3.RIGHT
	var cos45: float = cos(deg_to_rad(45.0))
	assert_true(SimRules.in_cone(o, h, Vector3(0.5, 0, 0), 1.0, cos45), "straight ahead in reach")
	assert_false(SimRules.in_cone(o, h, Vector3(1.01, 0, 0), 1.0, cos45), "beyond reach")
	assert_false(SimRules.in_cone(o, h, Vector3(-0.5, 0, 0), 1.0, cos45), "behind")
	assert_true(SimRules.in_cone(o, h, Vector3(0.5, 0.45, 0), 1.0, cos45), "inside 45 deg")
	assert_false(SimRules.in_cone(o, h, Vector3(0.5, 0.55, 0), 1.0, cos45), "outside 45 deg")
	assert_true(SimRules.in_cone(o, h, o, 1.0, cos45), "coincident centre counts")
	assert_true(SimRules.sphere_in_cone(o, h, Vector3(1.4, 0, 0), 0.5, 1.0, deg_to_rad(45.0)), "bite reach includes the target radius")
	assert_false(SimRules.sphere_in_cone(o, h, Vector3(-0.2, 0, 0), 0.5, 1.0, deg_to_rad(45.0)), "a big body behind the mouth is not bitten")


# ---- ContentDB validation of the S3 rule fields

func test_shipped_rules_validate_and_carry_the_s3_fields() -> void:
	var r: Dictionary = _content().rules()
	assert_eq(_rule_errors(r).size(), 0, "shipped rules are valid: %s" % [_rule_errors(r)])
	for key in ["grid_cell_m", "mouth_reach_mult", "mouth_cone_deg", "bite_cooldown_s", "predator_give_up_s", "npc_scale", "tiers", "player_hp_model"]:
		assert_true(r.has(key), "rules/core.json has %s" % key)
	assert_true(ContentDB.PLAYER_HP_MODELS.has(str(r["player_hp_model"])), "player_hp_model is one of %s" % [ContentDB.PLAYER_HP_MODELS])
	var bits: Dictionary = r["remains"]["food_bits"]
	for key in ["min", "max", "length_m", "drift_mps", "lifetime_s"]:
		assert_true(bits.has(key), "remains.food_bits.%s" % key)


func test_missing_or_bad_s3_rule_fields_are_reported() -> void:
	var cases: Array = [
		["grid_cell_m", 0, "rules/core.json: grid_cell_m: must be > 0"],
		["mouth_cone_deg", 200, "rules/core.json: mouth_cone_deg: must be <= 180"],
		["mouth_reach_mult", "far", "rules/core.json: mouth_reach_mult: must be a number"],
		["bite_cooldown_s", -1, "rules/core.json: bite_cooldown_s: must be >= 0"],
		["tiers", {"interactive_cap": 2.5, "large_cap": 20, "promote_radius_m": 40, "demote_radius_m": 55, "min_interactive_s": 2, "update_every_ticks": 6}, "rules/core.json: tiers.interactive_cap: must be an integer"],
		["player_hp_model", "mass", "rules/core.json: player_hp_model: must be one of band|length2"],
	]
	for c in cases:
		var r: Dictionary = _rules_copy()
		r[c[0]] = c[1]
		assert_true(_has_error(_rule_errors(r), c[2]), "%s = %s -> '%s', got %s" % [c[0], c[1], c[2], _rule_errors(r)])
	var missing: Dictionary = _rules_copy()
	missing.erase("mouth_reach_mult")
	assert_true(_has_error(_rule_errors(missing), "rules/core.json: mouth_reach_mult: is required"), "required")


func test_bad_food_bit_and_falloff_rules_are_reported() -> void:
	var r: Dictionary = _rules_copy()
	r["remains"]["food_bits"]["min"] = 2.5
	r["remains"]["food_bits"]["lifetime_s"] = 0
	r["xp_falloff"]["min_ratio"] = 0.5
	var errs: PackedStringArray = _rule_errors(r)
	assert_true(_has_error(errs, "rules/core.json: remains.food_bits.min: must be an integer"), "integer bit count: %s" % [errs])
	assert_true(_has_error(errs, "rules/core.json: remains.food_bits.lifetime_s: must be > 0"), "positive lifetime: %s" % [errs])
	assert_true(_has_error(errs, "rules/core.json: xp_falloff.min_ratio: must be < xp_falloff.full_at_ratio"), "falloff order: %s" % [errs])
