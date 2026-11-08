extends TestCase
## Broken content must fail with readable messages in the format `<source>: <field.path>: <problem>`.
## Two techniques:
##  1. validate_record() on mutated deep copies of REAL records (single-record schema checks).
##  2. load_from_dir() on (a) static fixtures in res://tests/fixtures and (b) a throw-away copy of res://data
##     in user:// with one deliberate defect (covers cross-reference checks).
## Every assertion names the offending field, not just "errors is non-empty".

var db: ContentDB
var _tmp_roots: Array[String] = []
var _counter: int = 0


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")


func after_each() -> void:
	for root in _tmp_roots:
		_remove_tree(root)
	_tmp_roots.clear()


# ---------------------------------------------------------------- helpers

func _dump(errors: PackedStringArray) -> String:
	return "\n  " + "\n  ".join(errors) if errors.size() > 0 else "<no errors>"


## `<source>: <field.path>: <problem>` -> three non-empty parts, field path without spaces.
func _is_well_formed(err: String) -> bool:
	var parts: PackedStringArray = err.split(": ", true, 2)
	if parts.size() != 3:
		return false
	return not parts[0].strip_edges().is_empty() and not parts[1].strip_edges().is_empty() \
		and parts[1].find(" ") == -1 and not parts[2].strip_edges().is_empty()


func _all_well_formed(errors: PackedStringArray) -> bool:
	for e in errors:
		if not _is_well_formed(e):
			return false
	return true


## True if ONE error line contains every needle (so the field is tied to the right source/record).
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


func _expect_error(errors: PackedStringArray, needles: Array[String], what: String) -> void:
	assert_true(_has_error(errors, needles), "%s: expected an error containing %s, got:%s" % [what, needles, _dump(errors)])


func _species(id: StringName) -> Dictionary:
	assert_false(db.get_species(id).is_empty(), "test setup: real species %s must exist" % id)
	return db.get_species(id).duplicate(true)


func _validate_species(rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"species", rec, "species/puffer.json")


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "test setup: cannot write %s" % path)
	if f != null:
		f.store_string(text)
		f.close()


func _read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _write_json(path: String, data: Variant) -> void:
	_write_text(path, JSON.stringify(data, "\t"))


func _copy_json_tree(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	assert_not_null(d, "test setup: cannot open %s" % src)
	if d == null:
		return
	for sub in d.get_directories():
		_copy_json_tree(src.path_join(sub), dst.path_join(sub))
	for f in d.get_files():
		if f.ends_with(".json"):
			_write_text(dst.path_join(f), FileAccess.get_file_as_string(src.path_join(f)))


func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_tree(path.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


## Fresh copy of res://data (JSON only) under user://; removed in after_each().
func _clone_data() -> String:
	_counter += 1
	var root: String = "user://s0_validation_%d_%d" % [Time.get_ticks_usec(), _counter]
	_tmp_roots.append(root)
	_copy_json_tree("res://data", root)
	return root


func _find_by_id(items: Array, id: String) -> Dictionary:
	for it in items:
		if str((it as Dictionary).get("id")) == id:
			return it
	return {}


# ======================================================== validate_record: species

func test_valid_species_has_no_errors() -> void:
	var errs := _validate_species(_species(&"puffer"))
	assert_eq(errs.size(), 0, "unmodified real record is clean:%s" % _dump(errs))


func test_species_missing_required_field_base_hp() -> void:
	var rec := _species(&"puffer")
	rec.erase("base_hp")
	var errs := _validate_species(rec)
	_expect_error(errs, ["species/puffer.json: ", "base_hp"], "missing base_hp")
	assert_true(_all_well_formed(errs), "format `<source>: <field.path>: <problem>`:%s" % _dump(errs))


func test_species_length_min_greater_than_max() -> void:
	var rec := _species(&"puffer")
	rec["length_m"] = {"min": 2.0, "max": 1.0}
	var errs := _validate_species(rec)
	# Contract example: `species/puffer.json: length_m.max: must be >= length_m.min`
	_expect_error(errs, ["species/puffer.json: length_m.max: "], "min > max")
	assert_true(_all_well_formed(errs), "format:%s" % _dump(errs))


func test_species_temperament_not_in_enum() -> void:
	var rec := _species(&"puffer")
	rec["temperament"] = "friendly"
	var errs := _validate_species(rec)
	_expect_error(errs, ["species/puffer.json: temperament: "], "temperament outside enum")
	assert_true(_all_well_formed(errs), "format:%s" % _dump(errs))


func test_species_tier_not_in_enum() -> void:
	var rec := _species(&"puffer")
	rec["tier"] = "gigantic"
	_expect_error(_validate_species(rec), ["tier"], "tier outside enum")


func test_species_non_positive_base_hp() -> void:
	for bad in [0, -5]:
		var rec := _species(&"puffer")
		rec["base_hp"] = bad
		_expect_error(_validate_species(rec), ["base_hp"], "base_hp = %s" % bad)


func test_species_negative_xp() -> void:
	var rec := _species(&"puffer")
	rec["xp"] = -1
	_expect_error(_validate_species(rec), ["xp"], "negative xp")


func test_species_non_positive_length_min() -> void:
	var rec := _species(&"puffer")
	rec["length_m"] = {"min": 0.0, "max": 0.5}
	_expect_error(_validate_species(rec), ["length_m.min"], "length min = 0")


func test_species_wrong_type_is_reported_not_crashed() -> void:
	var rec := _species(&"puffer")
	rec["xp"] = "ten"
	rec["zones"] = "reef"
	var errs := _validate_species(rec)
	_expect_error(errs, ["xp"], "string instead of number")
	_expect_error(errs, ["zones"], "string instead of array")


func test_species_non_finite_number_is_rejected() -> void:
	var rec := _species(&"puffer")
	rec["base_hp"] = INF  # what JSON 1e999 parses to
	_expect_error(_validate_species(rec), ["species/puffer.json: base_hp: "], "infinite base_hp")


func test_species_inflate_block_is_validated() -> void:
	var rec := _species(&"puffer")
	rec["inflate"] = {"scale": "big", "duration_s": -1, "spike_damage_frac_of_biter_max_hp": 2}
	var errs := _validate_species(rec)
	_expect_error(errs, ["inflate.scale"], "string scale")
	_expect_error(errs, ["inflate.duration_s"], "negative duration")
	_expect_error(errs, ["inflate.spike_damage_frac_of_biter_max_hp"], "fraction above 1")
	rec["inflate"] = 5
	_expect_error(_validate_species(rec), ["inflate"], "inflate is not an object")


func test_species_boss_block_is_validated() -> void:
	var rec := _species(&"giant_shark")
	assert_eq(_validate_species(rec).size(), 0, "real boss record is clean")
	rec["boss"]["engage_radius_m"] = 0
	rec["boss"].erase("dash_windup_s")
	var errs := _validate_species(rec)
	_expect_error(errs, ["boss.engage_radius_m"], "zero engage radius")
	_expect_error(errs, ["boss.dash_windup_s"], "missing windup")


func test_species_length_block_missing_max() -> void:
	var rec := _species(&"puffer")
	rec["length_m"] = {"min": 0.3}
	_expect_error(_validate_species(rec), ["length_m.max"], "length_m without max")


func test_species_multiple_defects_all_reported() -> void:
	var rec := _species(&"puffer")
	rec.erase("base_hp")
	rec["temperament"] = "friendly"
	rec["xp"] = -3
	var errs := _validate_species(rec)
	_expect_error(errs, ["base_hp"], "defect 1")
	_expect_error(errs, ["temperament"], "defect 2")
	_expect_error(errs, ["xp"], "defect 3")
	assert_true(errs.size() >= 3, "validator reports all problems of a record, not only the first:%s" % _dump(errs))


func test_empty_species_record_names_every_required_field() -> void:
	var errs := ContentDB.validate_record(&"species", {}, "species/empty.json")
	for field in ["id", "temperament", "length_m", "base_hp", "xp", "zones", "tier"]:
		_expect_error(errs, ["species/empty.json: ", field], "empty record, field '%s'" % field)
	assert_true(_all_well_formed(errs), "format:%s" % _dump(errs))


func test_error_messages_do_not_leak_engine_noise() -> void:
	var rec := _species(&"puffer")
	rec["length_m"] = {"min": 2.0, "max": 1.0}
	rec["temperament"] = "friendly"
	for e in _validate_species(rec):
		assert_eq(e.find("<null>"), -1, "no <null> placeholders in message: %s" % e)
		assert_eq(e.find("Object#"), -1, "no object dumps in message: %s" % e)


# ======================================================== validate_record: other kinds

func test_valid_records_of_every_kind_have_no_errors() -> void:
	assert_eq(ContentDB.validate_record(&"size_band", db.get_band(1), "size_bands/size_bands.json").size(), 0, "band")
	assert_eq(ContentDB.validate_record(&"mutation", db.get_mutation(&"hunter_bite_power"), "mutations/mutations.json").size(), 0, "mutation")
	assert_eq(ContentDB.validate_record(&"ability", db.get_ability(&"boost"), "abilities/boost.json").size(), 0, "ability")
	assert_eq(ContentDB.validate_record(&"map", db.get_map(&"reef"), "maps/reef.json").size(), 0, "map")
	assert_eq(ContentDB.validate_record(&"rules", db.rules(), "rules/core.json").size(), 0, "rules")


func test_band_missing_camera_block() -> void:
	var rec: Dictionary = db.get_band(2).duplicate(true)
	rec.erase("camera")
	var errs := ContentDB.validate_record(&"size_band", rec, "size_bands/size_bands.json")
	_expect_error(errs, ["size_bands/size_bands.json: ", "camera"], "band without camera")
	assert_true(_all_well_formed(errs), "format:%s" % _dump(errs))


func test_band_index_out_of_range() -> void:
	var rec: Dictionary = db.get_band(2).duplicate(true)
	rec["index"] = 5
	_expect_error(ContentDB.validate_record(&"size_band", rec, "size_bands/size_bands.json"), ["index"], "band index 5")


func test_band_length_range_inverted() -> void:
	var rec: Dictionary = db.get_band(3).duplicate(true)
	rec["length_m"] = {"min": 3.0, "max": 1.0}
	_expect_error(ContentDB.validate_record(&"size_band", rec, "size_bands/size_bands.json"), ["length_m.max"], "band min > max")


func test_band_non_positive_grid_cell() -> void:
	var rec: Dictionary = db.get_band(1).duplicate(true)
	rec["grid_cell_m"] = 0
	_expect_error(ContentDB.validate_record(&"size_band", rec, "size_bands/size_bands.json"), ["grid_cell_m"], "grid_cell_m = 0")


func test_mutation_branch_not_in_enum() -> void:
	var rec: Dictionary = db.get_mutation(&"hunter_bite_power").duplicate(true)
	rec["branch"] = "wizard"
	var errs := ContentDB.validate_record(&"mutation", rec, "mutations/mutations.json")
	_expect_error(errs, ["mutations/mutations.json: ", "branch"], "branch outside enum")
	assert_true(_all_well_formed(errs), "format:%s" % _dump(errs))


func test_mutation_tier_out_of_range() -> void:
	for bad in [0, 5]:
		var rec: Dictionary = db.get_mutation(&"hunter_bite_power").duplicate(true)
		rec["tier"] = bad
		_expect_error(ContentDB.validate_record(&"mutation", rec, "mutations/mutations.json"), ["tier"], "mutation tier %d" % bad)


func test_mutation_missing_id() -> void:
	var rec: Dictionary = db.get_mutation(&"hunter_bite_power").duplicate(true)
	rec.erase("id")
	_expect_error(ContentDB.validate_record(&"mutation", rec, "mutations/mutations.json"), ["id"], "mutation without id")


func test_ability_negative_cooldown() -> void:
	var rec: Dictionary = db.get_ability(&"sonar").duplicate(true)
	rec["cooldown_s"] = -1
	var errs := ContentDB.validate_record(&"ability", rec, "abilities/sonar.json")
	_expect_error(errs, ["abilities/sonar.json: cooldown_s: "], "negative cooldown")


func test_ability_missing_input_action() -> void:
	var rec: Dictionary = db.get_ability(&"sonar").duplicate(true)
	rec.erase("input_action")
	_expect_error(ContentDB.validate_record(&"ability", rec, "abilities/sonar.json"), ["input_action"], "ability without input_action")


# ======================================================== load_from_dir: static fixtures

func test_fixture_species_with_several_defects() -> void:
	var broken := ContentDB.load_from_dir("res://tests/fixtures/bad_missing_field")
	assert_not_null(broken, "loader returns a ContentDB even for broken input")
	assert_false(broken.is_valid(), "broken fixture must not validate")
	assert_true(broken.errors.size() > 0, "errors are collected")
	_expect_error(broken.errors, ["nameless.json", "base_hp"], "fixture: missing base_hp")
	_expect_error(broken.errors, ["nameless.json", "temperament"], "fixture: temperament 'friendly'")
	_expect_error(broken.errors, ["nameless.json", "length_m.max"], "fixture: length min > max")
	_expect_error(broken.errors, ["nameless.json", "xp"], "fixture: negative xp")
	_expect_error(broken.errors, ["nameless.json", "tier"], "fixture: tier 'huge'")


func test_fixture_malformed_json_is_reported_with_file_name() -> void:
	var broken := ContentDB.load_from_dir("res://tests/fixtures/bad_malformed_json")
	assert_not_null(broken, "loader must not crash on a malformed file")
	assert_false(broken.is_valid(), "malformed JSON makes the database invalid")
	assert_true(_has_error(broken.errors, ["broken.json"]), "the malformed file is named in the errors:%s" % _dump(broken.errors))


func test_missing_root_directory_is_reported() -> void:
	var missing := ContentDB.load_from_dir("user://s0_this_directory_does_not_exist")
	assert_not_null(missing, "loader must not crash on a missing root")
	assert_false(missing.is_valid(), "a missing data root is an error, not an empty valid database")
	assert_true(missing.errors.size() > 0, "an explanatory error is produced")


# ======================================================== load_from_dir: cloned real data with ONE defect

func test_clone_of_real_data_is_valid() -> void:
	var root := _clone_data()
	var copy := ContentDB.load_from_dir(root)
	assert_true(copy.is_valid(), "control: an unmodified copy of res://data validates:%s" % _dump(copy.errors))
	assert_eq(copy.species_ids().size(), 11, "control: 11 species in the copy (8 + 3 krill)")


func test_broken_reference_mutation_requires_unknown_id() -> void:
	var root := _clone_data()
	var path: String = root.path_join("mutations/mutations.json")
	var data: Dictionary = _read_json(path)
	var node: Dictionary = _find_by_id(data["nodes"], "hunter_bite_dash")
	assert_false(node.is_empty(), "test setup: node hunter_bite_dash exists")
	node["requires"] = "no_such_node"
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "dangling `requires` must invalidate the database")
	_expect_error(copy.errors, ["mutations", "requires"], "mutation requires unknown id")


func test_broken_reference_mutation_requires_wrong_branch() -> void:
	var root := _clone_data()
	var path: String = root.path_join("mutations/mutations.json")
	var data: Dictionary = _read_json(path)
	var node: Dictionary = _find_by_id(data["nodes"], "hunter_bite_dash")
	node["requires"] = "survivor_efficient_metabolism"  # exists, but other branch
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "requires across branches must be rejected")
	_expect_error(copy.errors, ["requires"], "cross-branch requires")


func test_broken_reference_mutation_requires_wrong_tier() -> void:
	var root := _clone_data()
	var path: String = root.path_join("mutations/mutations.json")
	var data: Dictionary = _read_json(path)
	var node: Dictionary = _find_by_id(data["nodes"], "hunter_turbo_boost")
	node["requires"] = "hunter_bite_power"  # tier 1, but a tier 4 node needs tier 3
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "requires must point at tier - 1")
	_expect_error(copy.errors, ["requires"], "requires skips a tier")


func test_broken_reference_grants_unknown_ability() -> void:
	var root := _clone_data()
	var path: String = root.path_join("mutations/mutations.json")
	var data: Dictionary = _read_json(path)
	var node: Dictionary = _find_by_id(data["nodes"], "survivor_sonar")
	node["grants_ability"] = "teleport"
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "grants_ability must reference an existing ability")
	_expect_error(copy.errors, ["grants_ability"], "unknown granted ability")


func test_broken_reference_species_zone_missing_from_map() -> void:
	var root := _clone_data()
	var path: String = root.path_join("species/puffer.json")
	var rec: Dictionary = _read_json(path)
	rec["zones"] = ["atlantis"]
	_write_json(path, rec)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "species zone unknown to the map must invalidate")
	_expect_error(copy.errors, ["puffer.json", "zones"], "species references unknown zone")


func test_broken_reference_spawner_unknown_species() -> void:
	var root := _clone_data()
	var path: String = root.path_join("maps/reef.json")
	var data: Dictionary = _read_json(path)
	var spawners: Array = data["spawners"]
	var key: String = ""
	for candidate in ["species", "species_id"]:
		if (spawners[0] as Dictionary).has(candidate):
			key = candidate
	assert_false(key.is_empty(), "test setup: spawner entries reference their species under `species` (or `species_id`); got keys %s" % [(spawners[0] as Dictionary).keys()])
	(spawners[0] as Dictionary)[key] = "kraken"
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "spawner with unknown species must invalidate")
	_expect_error(copy.errors, ["reef.json", "spawners"], "spawner references unknown species")


func test_broken_reference_spawner_unknown_zone() -> void:
	var root := _clone_data()
	var path: String = root.path_join("maps/reef.json")
	var data: Dictionary = _read_json(path)
	var spawners: Array = data["spawners"]
	var key: String = ""
	for candidate in ["zone", "zone_id"]:
		if (spawners[0] as Dictionary).has(candidate):
			key = candidate
	assert_false(key.is_empty(), "test setup: spawner entries reference their zone under `zone` (or `zone_id`)")
	(spawners[0] as Dictionary)[key] = "atlantis"
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "spawner with unknown zone must invalidate")
	_expect_error(copy.errors, ["reef.json", "spawners"], "spawner references unknown zone")


func test_species_id_must_match_file_name() -> void:
	var root := _clone_data()
	var path: String = root.path_join("species/puffer.json")
	var rec: Dictionary = _read_json(path)
	rec["id"] = "pufferfish"
	_write_json(path, rec)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "id != file stem must be rejected")
	_expect_error(copy.errors, ["puffer.json", "id"], "id differs from file stem")


func test_out_of_range_value_in_cloned_species_file() -> void:
	var root := _clone_data()
	var path: String = root.path_join("species/barracuda.json")
	var rec: Dictionary = _read_json(path)
	rec["length_m"] = {"min": 1.5, "max": 0.8}
	_write_json(path, rec)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "min > max must invalidate the database")
	_expect_error(copy.errors, ["barracuda.json", "length_m.max"], "out-of-range length in a file on disk")
	assert_true(_all_well_formed(copy.errors), "all schema errors follow the format:%s" % _dump(copy.errors))


func test_malformed_json_in_cloned_data() -> void:
	var root := _clone_data()
	_write_text(root.path_join("species/zz_broken.json"), "{ \"id\": \"zz_broken\", ")
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "one unparsable file invalidates the database")
	_expect_error(copy.errors, ["zz_broken.json"], "unparsable file is named")


func test_size_bands_must_be_contiguous() -> void:
	var root := _clone_data()
	var path: String = root.path_join("size_bands/size_bands.json")
	var data: Dictionary = _read_json(path)
	(data["bands"][1] as Dictionary)["length_m"]["min"] = 0.5  # B1 max is 0.30 -> gap
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "gap between band 1 max and band 2 min must be rejected")
	assert_true(_has_error(copy.errors, ["length_m"]) or _has_error(copy.errors, ["bands"]), "error names the band length field:%s" % _dump(copy.errors))


func test_band_thresholds_must_ascend() -> void:
	var root := _clone_data()
	var path: String = root.path_join("size_bands/size_bands.json")
	var data: Dictionary = _read_json(path)
	(data["bands"][2] as Dictionary)["xp_to_reach"] = 50  # B3 below B2 (100)
	_write_json(path, data)
	var copy := ContentDB.load_from_dir(root)
	assert_false(copy.is_valid(), "non-ascending xp_to_reach must be rejected")
	_expect_error(copy.errors, ["xp_to_reach"], "xp thresholds out of order")
