extends TestCase
## S5 map dressing DATA (game/data/maps/reef_dressing.json, wave 3): (1) the shipped file is valid and every reference
## resolves (piece ids -> GLB kit, zone ids -> reef.json zones, obstacle_ids -> reef.json obstacles); (2) the numbers
## are sane (densities >= 0, scale ranges, depth ranges, weights); (3) ContentDB rejects broken entries with
## `<source>: <field.path>: <problem>`, checked through validate_record(&"dressing", ...) (schema) and through a
## throw-away copy of res://data under user:// (cross references).
## Contract gaps are pinned in the test plan (A1: ContentDB.get_dressing + validate_record kind &"dressing"; A2: the
## dressing file must not be loaded as a map; A3: variants are 1-based; A4: required keys).

const S5 := preload("res://tests/s5_support.gd")
const SCRATCH: String = "user://s5_dressing_validation"


func _map() -> Dictionary:
	return S5.map_record()


func _copy() -> Dictionary:
	return S5.dressing().duplicate(true)


func _schema(rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"dressing", rec, S5.DRESSING_SOURCE)


# ======================================================== real data

func test_contentdb_serves_the_dressing_and_does_not_mistake_it_for_a_map() -> void:
	var db: ContentDB = S5.content()
	assert_true(db.is_valid(), "ContentDB errors: %s" % [db.errors])
	assert_eq(db.map_ids(), [&"reef"] as Array[StringName], "reef_dressing.json lives in data/maps/ but is not a map record")
	assert_true(db.has_method("get_dressing"), "S5 API missing: ContentDB.get_dressing(map_id) -> Dictionary (plan A1)")
	assert_false(S5.dressing(db).is_empty(), "the dressing of the reef is loaded")
	assert_true(FileAccess.file_exists(S5.DRESSING_PATH), "%s exists" % S5.DRESSING_PATH)


func test_the_shipped_dressing_passes_its_schema() -> void:
	var errs: PackedStringArray = _schema(S5.dressing())
	assert_eq(errs.size(), 0, "validate_record(&\"dressing\") on the shipped file: %s" % [errs])


func test_top_level_shape() -> void:
	var d: Dictionary = S5.dressing()
	assert_true(d.get("seed") is float or d.get("seed") is int, "seed is a number")
	assert_true(d.get("scatter") is Array and not (d["scatter"] as Array).is_empty(), "scatter is a non-empty array")
	assert_true(d.get("set_pieces") is Array and not (d["set_pieces"] as Array).is_empty(), "set_pieces is a non-empty array")


func test_scatter_rules_reference_real_zones_and_pieces() -> void:
	var map: Dictionary = _map()
	var rules: Array = S5.dressing().get("scatter", [])
	assert_true(rules.size() > 0, "at least one scatter rule")
	for i in rules.size():
		var r: Dictionary = rules[i]
		assert_true(S5.has_zone(map, str(r.get("zone_id", ""))), "scatter[%d].zone_id '%s' is a zone of reef.json" % [i, r.get("zone_id")])
		var pieces: Array = r.get("pieces", [])
		assert_true(pieces.size() > 0, "scatter[%d].pieces is not empty" % i)
		for j in pieces.size():
			var pe: Dictionary = pieces[j]
			var pid: String = str(pe.get("id", ""))
			assert_true(S5.piece_known(pid), "scatter[%d].pieces[%d].id '%s' has GLBs under res://assets/models/env/" % [i, j, pid])
			var avail: int = int(S5.glb_variants().get(pid, 0))
			var vs: Array[int] = S5.variant_list(pe.get("variants", 1))
			assert_true(vs.size() > 0, "scatter[%d].pieces[%d].variants lists at least one variant" % [i, j])
			for v: int in vs:
				assert_true(v >= 1 and v <= avail, "scatter[%d].pieces[%d] variant %d exists (GLBs v1..v%d)" % [i, j, v, avail])


func test_scatter_numbers_are_sane() -> void:
	var depth_m: float = float(_map().get("depth_m", 80.0))
	var rules: Array = S5.dressing().get("scatter", [])
	for i in rules.size():
		var r: Dictionary = rules[i]
		assert_true(float(r.get("density_per_100m2", -1.0)) >= 0.0, "scatter[%d].density_per_100m2 >= 0" % i)
		var sc: Array = r.get("scale", [])
		assert_eq(sc.size(), 2, "scatter[%d].scale is [min, max]" % i)
		if sc.size() == 2:
			assert_true(float(sc[0]) > 0.0 and float(sc[0]) <= float(sc[1]) and float(sc[1]) <= S5.MAX_SCATTER_SCALE, "scatter[%d].scale %s: 0 < min <= max <= %s" % [i, sc, S5.MAX_SCATTER_SCALE])
		var dr: Array = r.get("depth_m", [])
		assert_eq(dr.size(), 2, "scatter[%d].depth_m is [min, max]" % i)
		if dr.size() == 2:
			assert_true(float(dr[0]) >= 0.0 and float(dr[0]) < float(dr[1]) and float(dr[1]) <= depth_m, "scatter[%d].depth_m %s: 0 <= min < max <= map depth %s" % [i, dr, depth_m])
		assert_true(float(r.get("min_spacing_m", -1.0)) >= 0.0, "scatter[%d].min_spacing_m >= 0" % i)
		var rot: Variant = r.get("rot_y")
		assert_true((rot is String and rot == "random") or rot is float or rot is int, "scatter[%d].rot_y is \"random\" or degrees" % i)
		assert_true(r.get("align_to_slope") is bool, "scatter[%d].align_to_slope is a bool" % i)
		assert_true(r.get("avoid_obstacles") is bool, "scatter[%d].avoid_obstacles is a bool" % i)
		for j in (r.get("pieces", []) as Array).size():
			assert_true(float(((r["pieces"] as Array)[j] as Dictionary).get("weight", 0.0)) > 0.0, "scatter[%d].pieces[%d].weight > 0" % [i, j])


func test_some_rule_asks_to_avoid_obstacles_and_some_aligns_to_slopes() -> void:
	var rules: Array = S5.dressing().get("scatter", [])
	var avoid: int = 0
	var slope: int = 0
	for r: Variant in rules:
		avoid += 1 if bool((r as Dictionary).get("avoid_obstacles", false)) else 0
		slope += 1 if bool((r as Dictionary).get("align_to_slope", false)) else 0
	assert_true(avoid > 0, "at least one rule has avoid_obstacles = true (otherwise the avoidance tests are vacuous)")
	assert_true(slope > 0, "at least one rule has align_to_slope = true")


func test_set_pieces_reference_real_pieces_and_obstacles() -> void:
	var map: Dictionary = _map()
	var obstacles: Dictionary = S5.obstacle_by_id(map)
	var seen: Dictionary = {}
	var sets: Array = S5.dressing().get("set_pieces", [])
	for i in sets.size():
		var sp: Dictionary = sets[i]
		var sid: String = str(sp.get("id", ""))
		assert_false(sid.is_empty(), "set_pieces[%d].id is a non-empty string" % i)
		assert_false(seen.has(sid), "set_pieces[%d].id '%s' is unique" % [i, sid])
		seen[sid] = true
		var pid: String = str(sp.get("piece", ""))
		assert_true(S5.piece_known(pid), "set_pieces[%d].piece '%s' has GLBs" % [i, pid])
		var v: int = int(sp.get("variant", 1))
		assert_true(v >= 1 and v <= int(S5.glb_variants().get(pid, 0)), "set_pieces[%d].variant %d exists for '%s'" % [i, v, pid])
		assert_true(sp.get("obstacle_ids") is Array, "set_pieces[%d].obstacle_ids is an array (may be empty for small props)" % i)
		for oid: Variant in sp.get("obstacle_ids", []):
			assert_true(obstacles.has(str(oid)), "set_pieces[%d].obstacle_ids '%s' exists in reef.json obstacles" % [i, oid])


func test_set_piece_transforms_are_sane_and_inside_the_footprint() -> void:
	var sets: Array = S5.dressing().get("set_pieces", [])
	for i in sets.size():
		var sp: Dictionary = sets[i]
		var xz: Array = []
		var pos: Variant = sp.get("pos")
		if pos is Array:
			assert_eq((pos as Array).size(), 3, "set_pieces[%d].pos is [x, y, z]" % i)
			if (pos as Array).size() == 3:
				xz = [pos[0], pos[2]]
		elif pos is Dictionary:
			assert_eq(str((pos as Dictionary).get("anchor", "")), "seabed", "set_pieces[%d].pos.anchor is \"seabed\"" % i)
			xz = (pos as Dictionary).get("xz", [])
			assert_eq(xz.size(), 2, "set_pieces[%d].pos.xz is [x, z]" % i)
		else:
			fail("set_pieces[%d].pos is [x,y,z] or {anchor, xz}" % i)
		if xz.size() == 2:
			assert_true(absf(float(xz[0])) <= S5.FOOTPRINT_HALF_M and absf(float(xz[1])) <= S5.FOOTPRINT_HALF_M, "set_pieces[%d] xz %s inside the 600 x 600 m footprint" % [i, xz])
		var scale: float = float(sp.get("scale", 1.0))
		assert_true(scale > 0.0 and scale <= S5.MAX_SET_SCALE, "set_pieces[%d].scale %s in (0, %s]" % [i, scale, S5.MAX_SET_SCALE])
		assert_true(sp.get("rot_y", 0.0) is float or sp.get("rot_y", 0.0) is int, "set_pieces[%d].rot_y is a number (degrees)" % i)


func test_an_obstacle_proxy_belongs_to_one_set_piece() -> void:
	var owner_of: Dictionary = {}
	for sp: Variant in S5.dressing().get("set_pieces", []):
		for oid: Variant in (sp as Dictionary).get("obstacle_ids", []):
			assert_false(owner_of.has(str(oid)), "obstacle '%s' is claimed by '%s' and '%s'" % [oid, owner_of.get(str(oid), ""), (sp as Dictionary).get("id")])
			owner_of[str(oid)] = (sp as Dictionary).get("id")


# ======================================================== rejection: schema (validate_record)

func _rule_case(field: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rec: Dictionary = _copy()
	if not (rec.get("scatter") is Array) or (rec["scatter"] as Array).is_empty():
		return PackedStringArray(["setup: dressing.scatter is missing or empty"])
	var r: Dictionary = (rec["scatter"] as Array)[0]
	if erase:
		r.erase(field)
	else:
		r[field] = value
	return _schema(rec)


func _piece_entry_case(field: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rec: Dictionary = _copy()
	if not (rec.get("scatter") is Array) or (rec["scatter"] as Array).is_empty():
		return PackedStringArray(["setup: dressing.scatter is missing or empty"])
	var pe: Dictionary = (((rec["scatter"] as Array)[0] as Dictionary)["pieces"] as Array)[0]
	if erase:
		pe.erase(field)
	else:
		pe[field] = value
	return _schema(rec)


func _set_case(field: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rec: Dictionary = _copy()
	if not (rec.get("set_pieces") is Array) or (rec["set_pieces"] as Array).is_empty():
		return PackedStringArray(["setup: dressing.set_pieces is missing or empty"])
	var sp: Dictionary = (rec["set_pieces"] as Array)[0]
	if erase:
		sp.erase(field)
	else:
		sp[field] = value
	return _schema(rec)


func test_a_zero_density_rule_is_legal() -> void:
	assert_eq(_rule_case("density_per_100m2", 0).size(), 0, "density 0 switches a rule off, it is not an error")


func test_bad_scatter_numbers_are_rejected() -> void:
	for bad: Variant in [-1.0, -0.001, "x", null]:
		assert_true(S5.mentions(_rule_case("density_per_100m2", bad), "scatter[0]", "density_per_100m2"), "density %s" % [bad])
	for bad2: Variant in [[2.0, 1.0], [0.0, 1.0], [-1.0, 2.0], [1.0], [1.0, 2.0, 3.0], "x", [1.0, "x"]]:
		assert_true(S5.mentions(_rule_case("scale", bad2), "scatter[0]", "scale"), "scale %s" % [bad2])
	for bad3: Variant in [[30.0, 10.0], [-5.0, 10.0], [10.0], "x", [5.0, 500.0]]:
		assert_true(S5.mentions(_rule_case("depth_m", bad3), "scatter[0]", "depth_m"), "depth_m %s" % [bad3])
	for bad4: Variant in [-1.0, "x"]:
		assert_true(S5.mentions(_rule_case("min_spacing_m", bad4), "scatter[0]", "min_spacing_m"), "min_spacing_m %s" % [bad4])


func test_bad_scatter_flags_and_rotation_are_rejected() -> void:
	for bad: Variant in ["yes", 1, 0.5]:
		assert_true(S5.mentions(_rule_case("align_to_slope", bad), "scatter[0]", "align_to_slope"), "align_to_slope %s" % [bad])
		assert_true(S5.mentions(_rule_case("avoid_obstacles", bad), "scatter[0]", "avoid_obstacles"), "avoid_obstacles %s" % [bad])
	assert_true(S5.mentions(_rule_case("rot_y", "sideways"), "scatter[0]", "rot_y"), "rot_y must be \"random\" or a number")
	assert_eq(_rule_case("rot_y", "random").size(), 0, "rot_y \"random\" is legal")
	assert_eq(_rule_case("rot_y", 90).size(), 0, "rot_y 90 (degrees) is legal")


func test_missing_required_scatter_fields_are_reported() -> void:
	for field: String in ["zone_id", "pieces", "density_per_100m2", "scale"]:
		assert_true(S5.mentions(_rule_case(field, null, true), "scatter[0]", field), "a rule without %s must be rejected, naming the field" % field)
	assert_true(S5.mentions(_rule_case("zone_id", 5), "scatter[0]", "zone_id"), "a non-string zone_id")


func test_bad_piece_entries_are_rejected() -> void:
	assert_true(S5.mentions(_rule_case("pieces", []), "scatter[0]", "pieces"), "an empty pieces list")
	assert_true(S5.mentions(_rule_case("pieces", "x"), "scatter[0]", "pieces"), "pieces must be an array")
	for bad: Variant in [0.0, -1.0, "x"]:
		assert_true(S5.mentions(_piece_entry_case("weight", bad), "pieces[0]", "weight"), "weight %s" % [bad])
	for bad2: Variant in [0, -1, "x", []]:
		assert_true(S5.mentions(_piece_entry_case("variants", bad2), "pieces[0]", "variants"), "variants %s" % [bad2])
	assert_true(S5.mentions(_piece_entry_case("id", null, true), "pieces[0]", "id"), "a piece entry without id")
	assert_true(S5.mentions(_piece_entry_case("id", 7), "pieces[0]", "id"), "a non-string piece id")


func test_bad_set_piece_entries_are_rejected() -> void:
	for field: String in ["id", "piece"]:
		assert_true(S5.mentions(_set_case(field, null, true), "set_pieces[0]", field), "a set piece without %s" % field)
	for bad: Variant in [[1.0, 2.0], "x", [1.0, 2.0, "z"], [99999.0, -10.0, 0.0]]:
		assert_true(S5.mentions(_set_case("pos", bad), "set_pieces[0]", "pos"), "pos %s" % [bad])
	assert_true(S5.mentions(_set_case("pos", {"anchor": "sky", "xz": [0.0, 0.0]}), "set_pieces[0]", "anchor"), "an unknown anchor")
	assert_true(S5.mentions(_set_case("pos", {"anchor": "seabed", "xz": [0.0]}), "set_pieces[0]", "xz"), "xz needs two numbers")
	for bad2: Variant in [0.0, -1.0, "x"]:
		assert_true(S5.mentions(_set_case("scale", bad2), "set_pieces[0]", "scale"), "scale %s" % [bad2])
	for bad3: Variant in ["a", 5, {"a": 1}, [1, 2]]:
		assert_true(S5.mentions(_set_case("obstacle_ids", bad3), "set_pieces[0]", "obstacle_ids"), "obstacle_ids %s must be an array of strings" % [bad3])


func _have_data() -> bool:
	if S5.dressing().is_empty():
		fail("S5 data missing: %s (empty or unreadable)" % S5.DRESSING_PATH)
		return false
	return true


func test_malformed_containers_are_rejected() -> void:
	if not _have_data():
		return
	var rec: Dictionary = _copy()
	rec["scatter"] = {"a": 1}
	assert_true(S5.mentions(_schema(rec), "scatter"), "scatter must be an array")
	var rec2: Dictionary = _copy()
	rec2["set_pieces"] = "none"
	assert_true(S5.mentions(_schema(rec2), "set_pieces"), "set_pieces must be an array")
	var rec3: Dictionary = _copy()
	rec3["seed"] = "x"
	assert_true(S5.mentions(_schema(rec3), "seed"), "seed must be a number")
	var rec4: Dictionary = _copy()
	rec4.erase("seed")
	assert_true(S5.mentions(_schema(rec4), "seed"), "a missing seed is reported")
	var rec5: Dictionary = _copy()
	(rec5["scatter"] as Array)[0] = 5
	assert_true(S5.mentions(_schema(rec5), "scatter[0]"), "a scatter rule must be an object")
	var rec6: Dictionary = _copy()
	(rec6["set_pieces"] as Array)[0] = "boat"
	assert_true(S5.mentions(_schema(rec6), "set_pieces[0]"), "a set piece must be an object")


func test_duplicate_set_piece_ids_are_rejected() -> void:
	if not _have_data():
		return
	var rec: Dictionary = _copy()
	var sets: Array = rec["set_pieces"]
	if sets.size() < 2:
		fail("setup: need at least two set pieces")
		return
	(sets[1] as Dictionary)["id"] = (sets[0] as Dictionary)["id"]
	assert_true(S5.mentions(_schema(rec), "set_pieces[1]", "id"), "duplicate set piece id")


# ======================================================== rejection: cross references (throw-away data copy)

func _load_with_edit(edit: Callable) -> PackedStringArray:
	return S5.load_with_edit(SCRATCH, S5.DRESSING_SOURCE, edit)


func _edit_rule0(d: Dictionary, field: String, value: Variant) -> void:
	((d["scatter"] as Array)[0] as Dictionary)[field] = value


func _edit_entry0(d: Dictionary, field: String, value: Variant) -> void:
	((((d["scatter"] as Array)[0] as Dictionary)["pieces"] as Array)[0] as Dictionary)[field] = value


func _edit_set0(d: Dictionary, field: String, value: Variant) -> void:
	((d["set_pieces"] as Array)[0] as Dictionary)[field] = value


func _no_edit(_d: Dictionary) -> void:
	pass


func test_a_data_copy_without_edits_loads_clean() -> void:
	var errs: PackedStringArray = _load_with_edit(_no_edit)
	assert_eq(errs.size(), 0, "control: the unmodified copy has no errors: %s" % [errs])


func test_unknown_piece_ids_are_rejected() -> void:
	var errs: PackedStringArray = _load_with_edit(_edit_entry0.bind("id", "no_such_piece"))
	assert_true(S5.mentions(errs, "scatter[0]", "no_such_piece"), "unknown scatter piece id: %s" % [errs])
	var errs2: PackedStringArray = _load_with_edit(_edit_set0.bind("piece", "no_such_piece"))
	assert_true(S5.mentions(errs2, "set_pieces[0]", "no_such_piece"), "unknown set piece id: %s" % [errs2])


func test_a_variant_beyond_the_available_glbs_is_rejected() -> void:
	var errs: PackedStringArray = _load_with_edit(_edit_set0.bind("variant", 99))
	assert_true(S5.mentions(errs, "set_pieces[0]", "variant"), "variant 99 does not exist: %s" % [errs])
	var errs2: PackedStringArray = _load_with_edit(_edit_entry0.bind("variants", 99))
	assert_true(S5.mentions(errs2, "scatter[0]", "variants"), "variants 99 does not exist: %s" % [errs2])


func test_unknown_zone_ids_are_rejected() -> void:
	var errs: PackedStringArray = _load_with_edit(_edit_rule0.bind("zone_id", "no_such_zone"))
	assert_true(S5.mentions(errs, "scatter[0]", "no_such_zone"), "unknown zone: %s" % [errs])


func test_unknown_obstacle_ids_are_rejected() -> void:
	var errs: PackedStringArray = _load_with_edit(_edit_set0.bind("obstacle_ids", ["no_such_obstacle"]))
	assert_true(S5.mentions(errs, "set_pieces[0]", "no_such_obstacle"), "unknown obstacle id: %s" % [errs])
