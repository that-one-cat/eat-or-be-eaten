extends TestCase
## S3 data: (1) GAME_DESIGN numbers pinned literally in game/data (sections 2, 3, 8); (2) the new rule keys the sim
## reads exist and are sane; (3) ContentDB rejects broken S3 fields with `<source>: <field.path>: <problem>`.
## Key names are the S3 contract: rules/core.json -> mouth_reach_mult, mouth_cone_deg, bite_cooldown_s, grid_cell_m,
## npc_scale (S4 rename of s3_npc_scale), tiers.interactive_cap (S4, replaces max_interactive_npcs), predator_give_up_s, remains.food_bits.{drift_mps, lifetime_s},
## feedback.chomp_min_frac; maps/reef.json -> hiding_volumes.

const S3 := preload("res://tests/s3_support.gd")
const RULES_SOURCE: String = "rules/core.json"


func _db() -> ContentDB:
	return S3.content()


func _rules_copy() -> Dictionary:
	return _db().rules().duplicate(true)


## rec["a"]["b"]["c"] = value for path "a.b.c" (creates nothing: the parents must exist).
func _set_path(rec: Dictionary, path: String, value: Variant) -> void:
	var parts: PackedStringArray = path.split(".")
	var cur: Dictionary = rec
	for i in range(parts.size() - 1):
		cur = cur[parts[i]]
	cur[parts[parts.size() - 1]] = value


func _erase_path(rec: Dictionary, path: String) -> void:
	var parts: PackedStringArray = path.split(".")
	var cur: Dictionary = rec
	for i in range(parts.size() - 1):
		cur = cur[parts[i]]
	cur.erase(parts[parts.size() - 1])


func _any_error_mentions(errs: PackedStringArray, needle: String) -> bool:
	for e in errs:
		if e.find(needle) != -1:
			return true
	return false


# ======================================================== real data

func test_real_data_is_valid_with_the_s3_additions() -> void:
	var db: ContentDB = _db()
	assert_true(db.is_valid(), "ContentDB errors: %s" % [db.errors])
	assert_eq(ContentDB.validate_record(&"rules", db.rules(), RULES_SOURCE).size(), 0, "rules/core.json passes its own schema")
	assert_eq(ContentDB.validate_record(&"map", db.get_map(&"reef"), "maps/reef.json").size(), 0, "maps/reef.json passes its own schema")


func test_the_new_rule_keys_exist_and_are_sane() -> void:
	var db: ContentDB = _db()
	var reach: float = S3.rule_f(db, "mouth_reach_mult")
	var cone: float = S3.rule_f(db, "mouth_cone_deg")
	assert_true(reach > 0.0 and reach <= 5.0, "mouth_reach_mult in (0, 5], got %s" % reach)
	assert_true(cone > 0.0 and cone < 180.0, "mouth_cone_deg is a half-angle in (0, 180), got %s" % cone)
	assert_true(S3.rule_f(db, "bite_cooldown_s") > 0.0, "bite_cooldown_s > 0")
	assert_true(S3.rule_f(db, "bite_cooldown_s") <= 5.0, "bite_cooldown_s <= 5 s (a bite game, not a siege)")
	assert_true(S3.rule_f(db, "grid_cell_m") > 0.0, "grid_cell_m > 0")
	var scale: float = S3.rule_f(db, "npc_scale")
	assert_true(scale > 0.0 and scale <= 1.0, "npc_scale in (0, 1], got %s" % scale)
	assert_true(S3.rule_f(db, "tiers.interactive_cap") >= 1.0, "tiers.interactive_cap >= 1")
	assert_true(S3.rule_f(db, "predator_give_up_s") > 0.0, "predator_give_up_s > 0")
	assert_true(S3.rule(db, "remains.food_bits.drift_mps") != null and S3.rule_f(db, "remains.food_bits.drift_mps") >= 0.0, "remains.food_bits.drift_mps >= 0")
	assert_true(S3.rule_f(db, "remains.food_bits.lifetime_s") > 3.0, "remains.food_bits.lifetime_s longer than the 3 s skeleton fade")
	var chomp: float = S3.rule_f(db, "feedback.chomp_min_frac")
	assert_true(chomp > 0.0 and chomp <= 1.0, "feedback.chomp_min_frac in (0, 1], got %s" % chomp)


func test_the_swallow_cone_is_wide_enough_for_gameplay_but_not_omnidirectional() -> void:
	var db: ContentDB = _db()
	assert_true(S3.rule_f(db, "mouth_cone_deg") >= 15.0, "half-angle >= 15 degrees, or nothing is ever swallowed")
	assert_true(S3.rule_f(db, "mouth_cone_deg") <= 90.0, "half-angle <= 90 degrees, or the mouth reaches behind the fish")
	assert_true(S3.rule_f(db, "mouth_reach_mult") >= 0.5, "reach covers at least half a body length")


func test_game_design_numbers_are_in_the_rules_data_literally() -> void:
	var db: ContentDB = _db()
	assert_almost_eq(S3.rule_f(db, "swallow_ratio"), 0.10, 1e-12, "swallow_ratio 10%")
	assert_almost_eq(S3.rule_f(db, "hunger_max"), 100.0, 1e-12, "hunger 0-100")
	assert_almost_eq(S3.rule_f(db, "hunger_full_to_empty_s"), 90.0, 1e-12, "full to empty in 90 s")
	assert_almost_eq(S3.rule_f(db, "starvation_hp_frac_per_s"), 0.02, 1e-12, "2% max HP per second at 0 hunger")
	assert_almost_eq(S3.rule_f(db, "regen_min_hunger_frac"), 0.5, 1e-12, "regen above 50% hunger")
	assert_almost_eq(S3.rule_f(db, "death_xp_loss_frac"), 0.5, 1e-12, "death loses half the XP")
	assert_almost_eq(S3.rule_f(db, "respawn_delay_s"), 3.0, 1e-12, "respawn after 3 s")
	assert_almost_eq(S3.rule_f(db, "predator_hunt_ratio"), 0.6, 1e-12, "predators hunt <= 60% of their length")
	assert_almost_eq(S3.rule_f(db, "retaliate_duration_s"), 10.0, 1e-12, "retaliation lasts 10 s")
	assert_almost_eq(S3.rule_f(db, "hiding.lose_target_s"), 2.0, 1e-12, "hidden target lost after 2 s")
	assert_almost_eq(S3.rule_f(db, "hiding.detection_mult"), 0.4, 1e-12, "detection x0.4 against hidden targets")
	assert_almost_eq(S3.rule_f(db, "remains.skeleton_fade_s"), 3.0, 1e-12, "skeleton fades in 3 s")
	assert_eq(int(S3.rule_f(db, "remains.food_bits.min")), 3, "3 food bits minimum")
	assert_eq(int(S3.rule_f(db, "remains.food_bits.max")), 6, "6 food bits maximum")
	assert_almost_eq(S3.rule_f(db, "feedback.xray_flash_s"), 0.15, 1e-12, "X-ray flash 0.15 s")
	assert_almost_eq(S3.rule_f(db, "feedback.slowmo_scale"), 0.3, 1e-12, "slow-mo 0.3x")
	assert_almost_eq(S3.rule_f(db, "feedback.slowmo_s"), 0.6, 1e-12, "for 0.6 s")
	assert_almost_eq(S3.rule_f(db, "feedback.slowmo_min_length_ratio"), 0.5, 1e-12, "kills >= 50% of the player's length")


func test_xp_values_and_temperaments_per_species_match_game_design() -> void:
	var db: ContentDB = _db()
	# XP: GAME_DESIGN order (rising with prey size, the boss 0); the values themselves are tuned (S7 balance pass)
	var table: Dictionary = {
		"plankton": "passive",
		"silver_schooling_fish": "passive",
		"small_reef_fish": "passive",
		"puffer": "retaliate",
		"barracuda": "predator",
		"grouper": "retaliate",
		"shark": "predator",
		"giant_shark": "predator",
	}
	var prev_xp: float = 0.0
	for sid: String in table.keys():
		var sp: Dictionary = db.get_species(StringName(sid))
		assert_false(sp.is_empty(), "species %s exists" % sid)
		if sp.is_empty():
			continue
		if sid == "giant_shark":
			assert_almost_eq(float(sp["xp"]), 0.0, 1e-12, "giant_shark XP 0 (win instead)")
		else:
			assert_true(float(sp["xp"]) > prev_xp, "%s XP %s > the smaller prey's %s" % [sid, str(sp["xp"]), str(prev_xp)])
			prev_xp = float(sp["xp"])
		assert_eq(String(sp["temperament"]), String(table[sid]), "%s temperament" % sid)
		assert_true(float(sp["base_hp"]) > 0.0, "%s has HP data" % sid)
	for sid2 in ["barracuda", "shark", "giant_shark"]:
		assert_true(S3.species_f(db, StringName(sid2), "detection_radius_m") > 0.0, "%s (predator) has a detection radius" % sid2)
	for sid3 in ["plankton", "silver_schooling_fish", "small_reef_fish"]:
		assert_true(S3.species_f(db, StringName(sid3), "flee_radius_m") > 0.0, "%s (passive) has a flee radius" % sid3)
	assert_almost_eq(S3.species_f(db, &"grouper", "bite_mult"), 1.5, 1e-12, "grouper: big bite")


func test_puffer_inflate_numbers_match_game_design() -> void:
	var inflate: Dictionary = _db().get_species(&"puffer")["inflate"]
	assert_almost_eq(float(inflate["scale"]), 1.8, 1e-12, "x1.8")
	assert_almost_eq(float(inflate["duration_s"]), 5.0, 1e-12, "for 5 s")
	assert_almost_eq(float(inflate["spike_damage_frac_of_biter_max_hp"]), 0.10, 1e-12, "10% of the biter's max HP")


func test_band_numbers_match_game_design() -> void:
	var db: ContentDB = _db()
	assert_eq(db.band_count(), 4, "4 size bands")
	var reach_xp: Array[float] = [0.0, 100.0, 300.0, 700.0]
	var full_xp: Array[float] = [100.0, 300.0, 700.0, 1200.0]
	var lo: Array[float] = [0.10, 0.30, 0.90, 2.0]
	var hi: Array[float] = [0.30, 0.90, 2.0, 3.5]
	for i in 4:
		var b: Dictionary = db.get_band(i + 1)
		assert_almost_eq(float(b["xp_to_reach"]), reach_xp[i], 1e-12, "band %d xp_to_reach" % (i + 1))
		assert_almost_eq(float(b["xp_full_length"]), full_xp[i], 1e-12, "band %d xp_full_length (B4 reaches 3.5 m at 1200 XP)" % (i + 1))
		var lm: Dictionary = b["length_m"]
		assert_almost_eq(float(lm["min"]), lo[i], 1e-12, "band %d min length" % (i + 1))
		assert_almost_eq(float(lm["max"]), hi[i], 1e-12, "band %d max length" % (i + 1))
		assert_true(float(b["max_hp"]) > 0.0 and float(b["bite_power"]) > 0.0 and float(b["hunger_drain_mult"]) > 0.0, "band %d: max_hp, bite_power, hunger_drain_mult positive" % (i + 1))
	assert_almost_eq(float(db.get_band(1)["hunger_drain_mult"]), 1.0, 1e-12, "multiplier 1 at band 1 (full to empty in 90 s)")
	for i in 3:
		assert_almost_eq(float(db.get_band(i + 1)["xp_full_length"]), float(db.get_band(i + 2)["xp_to_reach"]), 1e-12, "band %d fills exactly at the next band's threshold" % (i + 1))


func test_xp_falloff_numbers_make_b4_unable_to_farm_plankton() -> void:
	var f: Dictionary = _db().rules()["xp_falloff"]
	assert_true(float(f["min_ratio"]) < float(f["full_at_ratio"]), "min_ratio < full_at_ratio")
	assert_true(float(f["min_mult"]) > 0.0 and float(f["min_mult"]) < 1.0, "min_mult in (0, 1)")
	# 0.02 m plankton eaten by a 3.5 m fish: ratio 0.0057 -> close to the floor.
	assert_true(0.02 / 3.5 < 2.0 * float(f["min_ratio"]), "a B4 fish sits near the floor when eating plankton")


# ======================================================== validation of broken rules

func test_rules_validation_rejects_negative_and_wrong_typed_s3_keys() -> void:
	var keys: Array[String] = [
		"mouth_reach_mult", "mouth_cone_deg", "bite_cooldown_s", "grid_cell_m", "npc_scale",
		"tiers.interactive_cap", "predator_give_up_s", "remains.food_bits.drift_mps",
		"remains.food_bits.lifetime_s", "feedback.chomp_min_frac",
	]
	for key in keys:
		var leaf: String = key.split(".")[-1]
		var neg: Dictionary = _rules_copy()
		_set_path(neg, key, -1.0)
		var errs_neg: PackedStringArray = ContentDB.validate_record(&"rules", neg, RULES_SOURCE)
		assert_true(errs_neg.size() > 0 and _any_error_mentions(errs_neg, leaf), "%s = -1 must be rejected with an error naming '%s' (got %s)" % [key, leaf, errs_neg])
		var bad_type: Dictionary = _rules_copy()
		_set_path(bad_type, key, "fast")
		var errs_type: PackedStringArray = ContentDB.validate_record(&"rules", bad_type, RULES_SOURCE)
		assert_true(errs_type.size() > 0 and _any_error_mentions(errs_type, leaf), "%s = \"fast\" must be rejected with an error naming '%s' (got %s)" % [key, leaf, errs_type])


func test_rules_validation_reports_missing_s3_keys() -> void:
	var keys: Array[String] = [
		"mouth_reach_mult", "mouth_cone_deg", "bite_cooldown_s", "grid_cell_m", "npc_scale",
		"tiers.interactive_cap", "predator_give_up_s", "remains.food_bits.drift_mps", "remains.food_bits.lifetime_s",
	]
	for key in keys:
		var leaf: String = key.split(".")[-1]
		var rec: Dictionary = _rules_copy()
		_erase_path(rec, key)
		var errs: PackedStringArray = ContentDB.validate_record(&"rules", rec, RULES_SOURCE)
		assert_true(errs.size() > 0 and _any_error_mentions(errs, leaf), "missing %s must be an error naming '%s' (no rule numbers in code), got %s" % [key, leaf, errs])


func test_rules_validation_messages_start_with_the_source() -> void:
	var rec: Dictionary = _rules_copy()
	rec["mouth_reach_mult"] = -2.0
	for e in ContentDB.validate_record(&"rules", rec, RULES_SOURCE):
		assert_true(e.begins_with(RULES_SOURCE + ": "), "error format '<source>: <field.path>: <problem>', got '%s'" % e)


func test_cone_half_angle_of_180_or_more_is_rejected() -> void:
	var rec: Dictionary = _rules_copy()
	rec["mouth_cone_deg"] = 200.0
	var errs: PackedStringArray = ContentDB.validate_record(&"rules", rec, RULES_SOURCE)
	assert_true(errs.size() > 0 and _any_error_mentions(errs, "mouth_cone_deg"), "a half-angle above 180 degrees is nonsense (got %s)" % [errs])


# ======================================================== validation of hiding volumes

func test_map_validation_rejects_broken_hiding_volumes() -> void:
	var good: Dictionary = _db().get_map(&"reef")
	var vols: Array = good.get("hiding_volumes", [])
	assert_true(vols.size() >= 1, "precondition: the real map has hiding volumes")
	if vols.is_empty():
		return
	var inverted: Dictionary = good.duplicate(true)
	var inverted_vols: Array = inverted["hiding_volumes"]
	var first: Dictionary = inverted_vols[0]
	var mm: Array[Vector3] = S3.box_min_max(first)
	inverted_vols[0] = S3.volume_with_box(first, mm[1], mm[0])
	var errs: PackedStringArray = ContentDB.validate_record(&"map", inverted, "maps/reef.json")
	assert_true(errs.size() > 0 and _any_error_mentions(errs, "hiding_volumes"), "min > max in a hiding volume must be an error naming hiding_volumes (got %s)" % [errs])
	var not_array: Dictionary = good.duplicate(true)
	not_array["hiding_volumes"] = "kelp"
	var errs2: PackedStringArray = ContentDB.validate_record(&"map", not_array, "maps/reef.json")
	assert_true(errs2.size() > 0 and _any_error_mentions(errs2, "hiding_volumes"), "hiding_volumes must be an array (got %s)" % [errs2])
