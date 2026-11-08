extends TestCase
## S4 data: (1) the shipped data is valid with the S4 additions (species.schooling, map.schools, map.plankton,
## rules.tiers, rules.schools, rules.quality.low); (2) invariants of the tuned numbers (never their values): promote <
## demote radius, caps >= 1, schools reference real species/zones; (3) ContentDB rejects broken S4 entries with
## `<source>: <field.path>: <problem>`, checked through validate_record (schema) and through a throw-away copy of the
## data directory under user:// (cross references).
## Where the contract does not pin a key location the tests use the path the contract text implies:
## rules/core.json -> tiers.{promote_radius_m, demote_radius_m, min_interactive_s, update_every_ticks, interactive_cap,
## large_cap}, schools.radius_per_sqrt_member_m, quality.low.ambient_density_mult, npc_scale (see test plan A1).

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const MAP_SOURCE: String = "maps/reef.json"
const RULES_SOURCE: String = "rules/core.json"
const SCRATCH: String = "user://s4_content_validation"


func _db() -> ContentDB:
	return S3.content()


func _map_copy() -> Dictionary:
	return _db().get_map(S3.MAP_ID).duplicate(true)


func _rules_copy() -> Dictionary:
	return _db().rules().duplicate(true)


func _mentions(errs: PackedStringArray, a: String, b: String = "") -> bool:
	for e: String in errs:
		if e.find(a) != -1 and (b.is_empty() or e.find(b) != -1):
			return true
	return false


# ======================================================== real data

func test_real_data_is_valid_with_the_s4_additions() -> void:
	var db: ContentDB = _db()
	assert_true(db.is_valid(), "ContentDB errors: %s" % [db.errors])
	assert_eq(ContentDB.validate_record(&"rules", db.rules(), RULES_SOURCE).size(), 0, "rules/core.json passes its schema")
	assert_eq(ContentDB.validate_record(&"map", db.get_map(S3.MAP_ID), MAP_SOURCE).size(), 0, "maps/reef.json passes its schema")
	for sid: StringName in db.species_ids():
		assert_eq(ContentDB.validate_record(&"species", db.get_species(sid), "species/%s.json" % sid).size(), 0, "%s passes the species schema" % sid)


func test_tier_and_school_rules_are_present_and_sane() -> void:
	var db: ContentDB = _db()
	var promote: float = S3.rule_f(db, "tiers.promote_radius_m")
	var demote: float = S3.rule_f(db, "tiers.demote_radius_m")
	assert_true(promote > 0.0, "tiers.promote_radius_m > 0 (got %s)" % promote)
	assert_true(demote > promote, "hysteresis needs tiers.demote_radius_m (%s) > promote_radius_m (%s)" % [demote, promote])
	assert_true(S3.rule_f(db, "tiers.min_interactive_s") > 0.0, "tiers.min_interactive_s > 0")
	assert_true(S3.rule_f(db, "tiers.update_every_ticks") >= 1.0, "tiers.update_every_ticks >= 1")
	assert_true(S3.rule_f(db, "tiers.interactive_cap") >= 1.0, "tiers.interactive_cap >= 1")
	assert_true(S3.rule_f(db, "tiers.large_cap") >= 1.0, "tiers.large_cap >= 1")
	assert_true(S3.rule_f(db, "schools.radius_per_sqrt_member_m") > 0.0, "schools.radius_per_sqrt_member_m > 0")
	var mult: float = S3.rule_f(db, "quality.low.ambient_density_mult")
	assert_true(S3.rule(db, "quality.low.ambient_density_mult") != null and mult > 0.0 and mult <= 1.0, "quality.low.ambient_density_mult in (0, 1], got %s" % mult)
	assert_true(S3.rule(db, "npc_scale") != null, "rules.npc_scale exists (renamed from s3_npc_scale)")
	assert_true(S3.rule_f(db, "grid_cell_m") > 0.0, "grid_cell_m still defined")


func test_species_tier_and_schooling_flags() -> void:
	var db: ContentDB = _db()
	var schooling: Array[String] = ["silver_schooling_fish", "small_reef_fish"]
	for sid: StringName in db.species_ids():
		var sp: Dictionary = db.get_species(sid)
		var want: bool = schooling.has(String(sid))
		assert_eq(bool(sp.get("schooling", false)), want, "%s.schooling" % sid)
		assert_true(sp.get("schooling", false) is bool, "%s.schooling is a bool (present on every species)" % sid)
	var tiers: Dictionary = {"plankton": "ambient", "silver_schooling_fish": "interactive", "small_reef_fish": "interactive", "puffer": "interactive", "barracuda": "interactive", "grouper": "large", "shark": "large", "giant_shark": "large"}
	for sid2: String in tiers.keys():
		assert_eq(String(db.get_species(StringName(sid2)).get("tier", "")), String(tiers[sid2]), "%s.tier" % sid2)


func test_school_records_reference_real_species_and_zones() -> void:
	var db: ContentDB = _db()
	var map: Dictionary = db.get_map(S3.MAP_ID)
	var zones: Dictionary = {}
	for z: Variant in map["zones"]:
		zones[String((z as Dictionary)["id"])] = true
	var recs: Array = map.get("schools", [])
	assert_true(recs.size() > 0, "map.schools is not empty")
	for i in recs.size():
		var r: Dictionary = recs[i]
		var sp: Dictionary = db.get_species(StringName(String(r["species_id"])))
		assert_false(sp.is_empty(), "schools[%d] species %s exists" % [i, r["species_id"]])
		assert_true(bool(sp.get("schooling", false)), "schools[%d] species %s is a schooling species" % [i, r["species_id"]])
		assert_true(zones.has(String(r["zone_id"])), "schools[%d] zone %s exists" % [i, r["zone_id"]])
		assert_true(int(r["count"]) >= 1, "schools[%d].count >= 1" % i)
		assert_true(int(r["size_min"]) >= 1 and int(r["size_max"]) >= int(r["size_min"]), "schools[%d] 1 <= size_min <= size_max" % i)
		assert_true(float(r["respawn_s"]) >= 0.0, "schools[%d].respawn_s >= 0" % i)


func test_the_plankton_record_is_consistent_with_the_grid() -> void:
	var db: ContentDB = _db()
	var map: Dictionary = db.get_map(S3.MAP_ID)
	assert_true(map.get("plankton") is Dictionary, "map.plankton exists")
	var cfg: Dictionary = map.get("plankton", {})
	var zones: Dictionary = {}
	for z: Variant in map["zones"]:
		zones[String((z as Dictionary)["id"])] = true
	assert_true((cfg.get("zones", []) as Array).size() > 0, "plankton lists at least one zone")
	for zid: Variant in cfg.get("zones", []):
		assert_true(zones.has(String(zid)), "plankton zone %s exists" % zid)
	var cell: float = float(cfg.get("cell_m", 0.0))
	var grid: float = S3.rule_f(db, "grid_cell_m")
	assert_true(cell > 0.0, "plankton.cell_m > 0")
	assert_true(is_zero_approx(fmod(cell, grid)) or is_zero_approx(fmod(grid, cell)), "plankton.cell_m (%s) is aligned with rules.grid_cell_m (%s)" % [cell, grid])
	assert_true(float(cfg.get("density_max", 0.0)) > 0.0, "plankton.density_max > 0")
	assert_true(float(cfg.get("regrow_per_s", -1.0)) > 0.0, "plankton.regrow_per_s > 0")


# ======================================================== rejection: map.schools

func _school_case(field: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rec: Dictionary = _map_copy()
	if not (rec.get("schools") is Array) or (rec["schools"] as Array).is_empty():
		return PackedStringArray(["setup: map.schools is missing or empty"])
	var s: Dictionary = (rec["schools"] as Array)[0]
	if erase:
		s.erase(field)
	else:
		s[field] = value
	return ContentDB.validate_record(&"map", rec, MAP_SOURCE)


func test_bad_school_counts_and_sizes_are_rejected() -> void:
	for bad: Variant in [0, -3, 2.5, "ten"]:
		assert_true(_mentions(_school_case("count", bad), "schools[0]", "count"), "count %s must be rejected, naming schools[0].count" % [bad])
	for bad2: Variant in [0, -1, 1.5, "x"]:
		assert_true(_mentions(_school_case("size_min", bad2), "schools[0]", "size_min"), "size_min %s must be rejected" % [bad2])
	for bad3: Variant in [0, -2, "x"]:
		assert_true(_mentions(_school_case("size_max", bad3), "schools[0]", "size_max"), "size_max %s must be rejected" % [bad3])
	var rec: Dictionary = _map_copy()
	if not (rec.get("schools") is Array) or (rec["schools"] as Array).is_empty():
		fail("setup: map.schools is missing or empty")
		return
	var s: Dictionary = (rec["schools"] as Array)[0]
	s["size_min"] = 20
	s["size_max"] = 10
	assert_true(_mentions(ContentDB.validate_record(&"map", rec, MAP_SOURCE), "schools[0]"), "size_min > size_max must be rejected")


func test_bad_school_respawn_and_missing_fields_are_rejected() -> void:
	for bad: Variant in [-1.0, "x"]:
		assert_true(_mentions(_school_case("respawn_s", bad), "schools[0]", "respawn_s"), "respawn_s %s must be rejected" % [bad])
	for field: String in ["species_id", "zone_id", "count", "size_min", "size_max"]:
		assert_true(_mentions(_school_case(field, null, true), "schools[0]", field), "a school record without %s must be rejected, naming the field" % field)
	assert_true(_mentions(_school_case("species_id", 5), "schools[0]", "species_id"), "a non-string species_id must be rejected")


func test_malformed_schools_containers_are_rejected() -> void:
	var rec: Dictionary = _map_copy()
	rec["schools"] = {"a": 1}
	assert_true(_mentions(ContentDB.validate_record(&"map", rec, MAP_SOURCE), "schools"), "schools must be an array")
	var rec2: Dictionary = _map_copy()
	if not (rec2.get("schools") is Array) or (rec2["schools"] as Array).is_empty():
		fail("setup: map.schools is missing or empty")
		return
	(rec2["schools"] as Array)[0] = 5
	assert_true(_mentions(ContentDB.validate_record(&"map", rec2, MAP_SOURCE), "schools[0]"), "a school record must be an object")


# ======================================================== rejection: map.plankton

func _plankton_case(field: String, value: Variant) -> PackedStringArray:
	var rec: Dictionary = _map_copy()
	if not (rec.get("plankton") is Dictionary):
		return PackedStringArray(["setup: map.plankton is missing"])
	(rec["plankton"] as Dictionary)[field] = value
	return ContentDB.validate_record(&"map", rec, MAP_SOURCE)


func test_bad_plankton_entries_are_rejected() -> void:
	for bad: Variant in [0, -8, "x"]:
		assert_true(_mentions(_plankton_case("cell_m", bad), "plankton", "cell_m"), "plankton.cell_m %s must be rejected" % [bad])
	for bad2: Variant in [0, -1.0, "x"]:
		assert_true(_mentions(_plankton_case("density_max", bad2), "plankton", "density_max"), "plankton.density_max %s must be rejected" % [bad2])
	for bad3: Variant in [-0.1, "x"]:
		assert_true(_mentions(_plankton_case("regrow_per_s", bad3), "plankton", "regrow_per_s"), "plankton.regrow_per_s %s must be rejected" % [bad3])
	assert_true(_mentions(_plankton_case("zones", "shallows"), "plankton", "zones"), "plankton.zones must be an array")
	assert_true(_mentions(_plankton_case("zones", [5]), "plankton", "zones"), "plankton.zones entries must be strings")
	var rec: Dictionary = _map_copy()
	rec["plankton"] = 3
	assert_true(_mentions(ContentDB.validate_record(&"map", rec, MAP_SOURCE), "plankton"), "plankton must be an object")


# ======================================================== rejection: rules.tiers and species.schooling

func _tiers_case(field: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rules: Dictionary = _rules_copy()
	if not (rules.get("tiers") is Dictionary):
		return PackedStringArray(["setup: rules.tiers is missing"])
	var t: Dictionary = rules["tiers"]
	if erase:
		t.erase(field)
	else:
		t[field] = value
	return ContentDB.validate_record(&"rules", rules, RULES_SOURCE)


func test_bad_tier_rules_are_rejected() -> void:
	for bad: Variant in [0, -1.0, "x"]:
		assert_true(_mentions(_tiers_case("promote_radius_m", bad), "tiers", "promote_radius_m"), "promote_radius_m %s" % [bad])
	for bad2: Variant in [-1.0, "x"]:
		assert_true(_mentions(_tiers_case("min_interactive_s", bad2), "tiers", "min_interactive_s"), "min_interactive_s %s" % [bad2])
	for bad3: Variant in [0, -5, 2.5, "x"]:
		assert_true(_mentions(_tiers_case("interactive_cap", bad3), "tiers", "interactive_cap"), "interactive_cap %s" % [bad3])
	for bad4: Variant in [-1, 2.5, "x"]:
		assert_true(_mentions(_tiers_case("large_cap", bad4), "tiers", "large_cap"), "large_cap %s" % [bad4])
	for bad5: Variant in [0, -2, 1.5, "x"]:
		assert_true(_mentions(_tiers_case("update_every_ticks", bad5), "tiers", "update_every_ticks"), "update_every_ticks %s" % [bad5])
	for field: String in ["promote_radius_m", "demote_radius_m", "min_interactive_s", "update_every_ticks", "interactive_cap", "large_cap"]:
		assert_true(_mentions(_tiers_case(field, null, true), "tiers", field), "missing tiers.%s must be reported" % field)


func test_demote_radius_must_exceed_the_promote_radius() -> void:
	var promote: float = S3.rule_f(_db(), "tiers.promote_radius_m")
	assert_true(_mentions(_tiers_case("demote_radius_m", promote), "demote_radius_m"), "demote == promote has no hysteresis: rejected")
	assert_true(_mentions(_tiers_case("demote_radius_m", promote * 0.5), "demote_radius_m"), "demote < promote: rejected")
	assert_true(_mentions(_tiers_case("demote_radius_m", "x"), "tiers", "demote_radius_m"), "non-numeric demote radius: rejected")


func test_tiers_must_be_an_object() -> void:
	var rules: Dictionary = _rules_copy()
	rules["tiers"] = [1, 2]
	assert_true(_mentions(ContentDB.validate_record(&"rules", rules, RULES_SOURCE), "tiers"), "tiers must be an object")
	var rules2: Dictionary = _rules_copy()
	rules2.erase("tiers")
	assert_true(_mentions(ContentDB.validate_record(&"rules", rules2, RULES_SOURCE), "tiers"), "a missing tiers block is reported")


func test_a_non_boolean_schooling_flag_is_rejected() -> void:
	for bad: Variant in ["yes", 1, 0.5]:
		var sp: Dictionary = _db().get_species(S4.SILVER).duplicate(true)
		sp["schooling"] = bad
		assert_true(_mentions(ContentDB.validate_record(&"species", sp, "species/silver_schooling_fish.json"), "schooling"), "schooling %s must be rejected" % [bad])


# ======================================================== rejection: cross references (throw-away data copy)

func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		if not sub.begins_with("."):
			_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "json":
			var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
			out.store_string(FileAccess.get_file_as_string(src.path_join(f)))
			out.close()


func _remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


## Loads a copy of res://data whose reef.json was edited by `edit` and returns its error list.
func _load_with_map_edit(edit: Callable) -> PackedStringArray:
	_remove_dir(SCRATCH)
	_copy_dir("res://data", SCRATCH)
	var path: String = SCRATCH.path_join("maps/reef.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return PackedStringArray(["setup: could not read the copied reef.json"])
	edit.call(parsed)
	var out: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed, "\t"))
	out.close()
	var db: ContentDB = ContentDB.load_from_dir(SCRATCH)
	var errs: PackedStringArray = db.errors
	_remove_dir(SCRATCH)
	return errs


func _edit_school(m: Dictionary, field: String, value: Variant) -> void:
	if m.get("schools") is Array and not (m["schools"] as Array).is_empty():
		((m["schools"] as Array)[0] as Dictionary)[field] = value


func _edit_plankton_zone(m: Dictionary) -> void:
	if m.get("plankton") is Dictionary and (m["plankton"] as Dictionary).get("zones") is Array:
		((m["plankton"] as Dictionary)["zones"] as Array).append("no_such_zone")


func test_a_data_copy_without_edits_loads_clean() -> void:
	var errs: PackedStringArray = _load_with_map_edit(func(_m: Dictionary) -> void: pass)
	assert_eq(errs.size(), 0, "control: the unmodified copy has no errors: %s" % [errs])


func test_school_and_plankton_references_to_unknown_species_or_zones_are_rejected() -> void:
	var errs: PackedStringArray = _load_with_map_edit(func(m: Dictionary) -> void: _edit_school(m, "species_id", "no_such_fish"))
	assert_true(_mentions(errs, "schools", "no_such_fish") or _mentions(errs, "schools[0]"), "unknown school species: %s" % [errs])
	var errs2: PackedStringArray = _load_with_map_edit(func(m: Dictionary) -> void: _edit_school(m, "zone_id", "no_such_zone"))
	assert_true(_mentions(errs2, "schools", "no_such_zone") or _mentions(errs2, "schools[0]"), "unknown school zone: %s" % [errs2])
	var errs3: PackedStringArray = _load_with_map_edit(func(m: Dictionary) -> void: _edit_plankton_zone(m))
	assert_true(_mentions(errs3, "plankton"), "unknown plankton zone: %s" % [errs3])


func test_a_school_of_a_non_schooling_species_is_rejected() -> void:
	var errs: PackedStringArray = _load_with_map_edit(func(m: Dictionary) -> void: _edit_school(m, "species_id", "puffer"))
	assert_true(_mentions(errs, "schools[0]"), "a school of puffers (schooling == false) is rejected: %s" % [errs])
