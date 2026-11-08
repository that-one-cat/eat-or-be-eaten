extends TestCase
## T1.7 per-species movement stats: schema, identity backfill of the shipped data, ContentDB validation, docs.
## Fields: swim_speed_mps (canonical, unchanged) + boost_mult, boost_stamina, turn_rate_deg_s, accel_mps2,
## drag_per_s, brake_decel_mps2, depth_range_m, plus the player species' `player_profile` multipliers.
## Layout-agnostic: stats may be flat keys or live in a `movement` block (species_stats_support.gd NAME TABLE).
## Failures read `species/<id>.json: <field.path>: <problem>`; every assertion names the field.

const SS := preload("res://tests/species_stats_support.gd")

var db: ContentDB


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")


func after_each() -> void:
	SS.cleanup()


func _rec(id: String) -> Dictionary:
	assert_false(db.get_species(StringName(id)).is_empty(), "test setup: shipped species %s must exist" % id)
	return db.get_species(StringName(id)).duplicate(true)


func _validate(id: String, rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"species", rec, "species/%s.json" % id)


func _dump(errors: PackedStringArray) -> String:
	return "\n  " + "\n  ".join(errors) if errors.size() > 0 else "<no errors>"


## True if ONE error line contains every needle.
func _has_error(errors: PackedStringArray, needles: Array[String]) -> bool:
	for e in errors:
		var ok: bool = true
		for n in needles:
			if e.find(n) == -1:
				ok = false
				break
		if ok:
			return true
	return false


# ======================================================== shipped data: identity backfill

func test_shipped_species_set_is_the_eleven_backfilled_ones() -> void:
	var ids: Array[String] = []
	for id: StringName in db.species_ids():
		ids.append(String(id))
	ids.sort()
	var want: Array[String] = SS.SHIPPED_SPECIES.duplicate()
	want.sort()
	assert_eq(ids, want, "the roster this task backfills; a new species needs its own movement stats and a new baseline")


func test_shipped_content_with_new_fields_validates_clean() -> void:
	assert_true(db.is_valid(), "shipped data must validate:%s" % _dump(db.errors))


func test_every_shipped_species_has_every_new_field() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		var rec: Dictionary = _rec(id)
		for f: String in SS.NEW_FIELDS:
			assert_true(SS.has_stat(rec, f), "species/%s.json: %s: missing (identity backfill must add it to every species)" % [id, f])


func test_scalar_fields_are_finite_positive_numbers() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		var rec: Dictionary = _rec(id)
		for f: String in SS.SCALAR_FIELDS:
			var v: Variant = SS.stat(rec, f)
			assert_true(SS.is_num(v), "species/%s.json: %s: must be a number, got %s" % [id, f, str(v)])
			if SS.is_num(v):
				assert_true(is_finite(float(v)) and float(v) > 0.0, "species/%s.json: %s: must be finite and > 0, got %s" % [id, f, str(v)])


func test_depth_range_is_an_ordered_finite_pair_for_every_species() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		var v: Variant = SS.stat(_rec(id), "depth_range_m")
		var pair: Array[float] = SS.depth_pair(v)
		assert_eq(pair.size(), 2, "species/%s.json: depth_range_m: must be [min, max] or {min, max}, got %s" % [id, str(v)])
		if pair.size() == 2:
			assert_true(is_finite(pair[0]) and is_finite(pair[1]), "species/%s.json: depth_range_m: finite numbers" % id)
			assert_true(pair[0] <= pair[1], "species/%s.json: depth_range_m: min %s must be <= max %s" % [id, pair[0], pair[1]])


func test_swim_speed_mps_stays_the_canonical_unchanged_key() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		var rec: Dictionary = _rec(id)
		assert_true(rec.has("swim_speed_mps"), "species/%s.json: swim_speed_mps: the canonical flat key must remain" % id)
		assert_almost_eq(float(rec.get("swim_speed_mps", -1.0)), float(SS.BASELINE_SPEED[id]), 1e-12, "species/%s.json: swim_speed_mps changed (identity backfill)" % id)
		var blk: Dictionary = SS.block_with(rec, "swim_speed_mps")
		if not blk.is_empty():
			assert_almost_eq(float(blk["swim_speed_mps"]), float(rec["swim_speed_mps"]), 1e-12, "species/%s.json: movement.swim_speed_mps must equal the flat swim_speed_mps" % id)


func test_no_pre_existing_key_was_dropped() -> void:
	var core: Array[String] = ["id", "temperament", "tier", "length_m", "base_hp", "xp", "swim_speed_mps", "behaviour", "zones"]
	for id: String in SS.SHIPPED_SPECIES:
		var rec: Dictionary = _rec(id)
		for k: String in core:
			assert_true(rec.has(k), "species/%s.json: %s: pre-existing key must stay in place (no renames)" % [id, k])
	var puffer: Dictionary = _rec("puffer")
	assert_true(puffer.has("inflate"), "puffer keeps its inflate block")
	assert_true((puffer["behaviour"] as Dictionary).has("wander_speed_frac"), "behaviour.wander_speed_frac untouched")
	assert_true(_rec("giant_shark").has("boss"), "giant_shark keeps its boss block")


func test_boost_mult_backfill_equals_the_boost_ability_speed_mult() -> void:
	# Inference from the identity rule: NPC panic speed = swim_speed_mps x abilities/boost.json speed_mult today.
	var want: float = float(db.get_ability(&"boost").get("speed_mult", 0.0))
	assert_true(want > 0.0, "test setup: boost ability speed_mult")
	for id: String in SS.SHIPPED_SPECIES:
		var v: Variant = SS.stat(_rec(id), "boost_mult")
		if SS.is_num(v):
			assert_almost_eq(float(v), want, 1e-9, "species/%s.json: boost_mult must reproduce today's boost x%s" % [id, want])


func test_player_profile_defaults_are_exactly_one() -> void:
	var rec: Dictionary = _rec(String(SS.player_species_id(db)))
	var prof: Variant = rec.get(SS.PROFILE_BLOCK)
	if prof == null:
		for b: String in SS.MOVEMENT_BLOCKS:
			if rec.get(b) is Dictionary:
				prof = (rec[b] as Dictionary).get(SS.PROFILE_BLOCK)
	if prof == null:
		return  # omitted block = all multipliers 1.0 (spec: default 1.0); the e2e tests prove a set block takes effect
	assert_true(prof is Dictionary, "player_profile must be an object")
	if prof is Dictionary:
		for k: Variant in (prof as Dictionary).keys():
			var v: Variant = (prof as Dictionary)[k]
			assert_true(SS.is_num(v) and absf(float(v) - 1.0) < 1e-12, "player_profile.%s: shipped default must be exactly 1.0, got %s" % [k, str(v)])


# ======================================================== validation: scalar fields

func test_missing_field_is_reported_for_every_species_and_field() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		for f: String in SS.NEW_FIELDS:
			var rec: Dictionary = _rec(id)
			SS.erase_stat(rec, f)
			var errs: PackedStringArray = _validate(id, rec)
			assert_true(_has_error(errs, ["species/%s.json: " % id, f]), "missing %s on %s: expected an error naming the field, got:%s" % [f, id, _dump(errs)])


func test_scalar_fields_reject_negative_values() -> void:
	for f: String in SS.SCALAR_FIELDS:
		var rec: Dictionary = _rec("puffer")
		SS.set_stat(rec, f, -1.0)
		var errs: PackedStringArray = _validate("puffer", rec)
		assert_true(_has_error(errs, ["species/puffer.json: ", f]), "%s = -1: expected an error, got:%s" % [f, _dump(errs)])


func test_scalar_fields_reject_nan() -> void:
	for f: String in SS.SCALAR_FIELDS:
		var rec: Dictionary = _rec("puffer")
		SS.set_stat(rec, f, NAN)
		var errs: PackedStringArray = _validate("puffer", rec)
		assert_true(_has_error(errs, ["species/puffer.json: ", f]), "%s = NaN: expected an error, got:%s" % [f, _dump(errs)])


func test_scalar_fields_reject_infinity() -> void:
	for f: String in SS.SCALAR_FIELDS:
		for bad: float in [INF, -INF]:
			var rec: Dictionary = _rec("puffer")
			SS.set_stat(rec, f, bad)
			var errs: PackedStringArray = _validate("puffer", rec)
			assert_true(_has_error(errs, ["species/puffer.json: ", f]), "%s = %s (JSON 1e999): expected an error, got:%s" % [f, bad, _dump(errs)])


func test_scalar_fields_reject_wrong_types_without_crashing() -> void:
	for f: String in SS.SCALAR_FIELDS:
		for bad: Variant in ["fast", true, null, [1.0], {"v": 1.0}]:
			var rec: Dictionary = _rec("puffer")
			SS.set_stat(rec, f, bad)
			var errs: PackedStringArray = _validate("puffer", rec)
			assert_true(_has_error(errs, ["species/puffer.json: ", f]), "%s = %s: expected a type error, got:%s" % [f, str(bad), _dump(errs)])


func test_scalar_fields_reject_zero_for_rate_like_fields() -> void:
	# A fish that cannot accelerate / turn / brake / boost would be a silent soft-lock; 0 is out of range.
	for f: String in ["accel_mps2", "turn_rate_deg_s", "brake_decel_mps2", "boost_mult"]:
		var rec: Dictionary = _rec("puffer")
		SS.set_stat(rec, f, 0.0)
		var errs: PackedStringArray = _validate("puffer", rec)
		assert_true(_has_error(errs, ["species/puffer.json: ", f]), "%s = 0: expected an error, got:%s" % [f, _dump(errs)])


func test_swim_speed_mps_validation_is_unchanged() -> void:
	for bad: Variant in [0.0, -2.0, NAN, INF, "x"]:
		var rec: Dictionary = _rec("puffer")
		rec["swim_speed_mps"] = bad
		var errs: PackedStringArray = _validate("puffer", rec)
		assert_true(_has_error(errs, ["species/puffer.json: swim_speed_mps: "]), "swim_speed_mps = %s: expected an error, got:%s" % [str(bad), _dump(errs)])


# ======================================================== validation: depth_range_m

func test_depth_range_rejects_reversed_pair() -> void:
	var rec: Dictionary = _rec("puffer")
	var shaped: Variant = SS.stat(rec, "depth_range_m")
	var pair: Array[float] = SS.depth_pair(shaped)
	assert_eq(pair.size(), 2, "test setup: shipped depth_range_m has a readable shape")
	if pair.size() != 2:
		return
	SS.set_stat(rec, "depth_range_m", SS.depth_like(shaped, pair[1] + 5.0, pair[0] - 5.0))
	var errs: PackedStringArray = _validate("puffer", rec)
	assert_true(_has_error(errs, ["species/puffer.json: ", "depth_range_m"]), "min > max: expected an error, got:%s" % _dump(errs))


func test_depth_range_rejects_non_finite_numbers() -> void:
	var shaped: Variant = SS.stat(_rec("puffer"), "depth_range_m")
	for bad: float in [NAN, INF, -INF]:
		for slot in 2:
			var rec: Dictionary = _rec("puffer")
			SS.set_stat(rec, "depth_range_m", SS.depth_like(shaped, bad if slot == 0 else -10.0, bad if slot == 1 else 0.0))
			var errs: PackedStringArray = _validate("puffer", rec)
			assert_true(_has_error(errs, ["species/puffer.json: ", "depth_range_m"]), "depth_range_m with %s in slot %d: expected an error, got:%s" % [bad, slot, _dump(errs)])


func test_depth_range_rejects_wrong_shapes_and_types() -> void:
	for bad: Variant in ["deep", 5, true, null, [], [1.0], [1.0, 2.0, 3.0], ["a", "b"], [null, 1.0], {}, {"min": 1.0}, {"min": "a", "max": "b"}]:
		var rec: Dictionary = _rec("puffer")
		SS.set_stat(rec, "depth_range_m", bad)
		var errs: PackedStringArray = _validate("puffer", rec)
		assert_true(_has_error(errs, ["species/puffer.json: ", "depth_range_m"]), "depth_range_m = %s: expected an error, got:%s" % [str(bad), _dump(errs)])


# ======================================================== validation: loader level and profile

func test_load_from_dir_reports_a_bad_movement_field_and_marks_content_invalid() -> void:
	var bad_db: ContentDB = SS.db_with(func(root: String) -> void:
		var path: String = root.path_join("species/shark.json")
		var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		SS.set_stat(rec, "accel_mps2", -3.0)
		SS.write_text(path, JSON.stringify(rec, "\t")))
	assert_false(bad_db.is_valid(), "a negative accel_mps2 must invalidate the whole content set")
	assert_true(_has_error(bad_db.errors, ["shark.json", "accel_mps2"]), "error names file and field, got:%s" % _dump(bad_db.errors))


func test_player_profile_rejects_bad_multipliers() -> void:
	var pid: String = String(SS.player_species_id(db))
	for what: String in SS.PROFILE_KEYS.keys():
		for bad: Variant in [-1.0, NAN, INF, "big", true, null]:
			var rec: Dictionary = _rec(pid)
			var prof: Dictionary = SS.profile_of(rec)
			var key: String = SS.profile_key(prof, what)
			prof[key] = bad
			var errs: PackedStringArray = _validate(pid, rec)
			assert_true(_has_error(errs, ["species/%s.json: " % pid, key]), "player_profile.%s = %s: expected an error naming the key, got:%s" % [key, str(bad), _dump(errs)])


func test_player_profile_accepts_sane_multipliers() -> void:
	var pid: String = String(SS.player_species_id(db))
	for mult: float in [0.5, 1.0, 1.5, 2.0]:
		var rec: Dictionary = _rec(pid)
		var prof: Dictionary = SS.profile_of(rec)
		for what: String in SS.PROFILE_KEYS.keys():
			prof[SS.profile_key(prof, what)] = mult
		var errs: PackedStringArray = _validate(pid, rec)
		assert_eq(errs.size(), 0, "all player_profile multipliers = %s must validate:%s" % [mult, _dump(errs)])


# ======================================================== docs

func test_docs_data_species_documents_the_schema() -> void:
	var path: String = ProjectSettings.globalize_path("res://").path_join("../docs/data/species.md").simplify_path()
	var text: String = FileAccess.get_file_as_string(path)
	assert_false(text.is_empty(), "docs/data/species.md must be readable at %s" % path)
	for f: String in SS.NEW_FIELDS + ["swim_speed_mps", SS.PROFILE_BLOCK]:
		assert_true(text.contains(f), "docs/data/species.md must document `%s`" % f)
