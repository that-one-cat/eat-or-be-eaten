extends TestCase
## ContentDB validation of the S2 fields: size_bands (accel_mps2, drag_per_s, turn_rate_deg_s, brake_decel_mps2,
## collision_radius_mult) and reef.json (bounds.soft_margin_m, bounds.current_mps, obstacles[].kind).
## Every broken record must produce a message `<source>: <field.path>: <problem>` that names the field.

const S2 := preload("res://tests/s2_support.gd")
const BAND_SRC: String = "size_bands/size_bands.json"
const MAP_SRC: String = "maps/reef.json"
const BAND_FIELDS: Array[String] = ["accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2", "collision_radius_mult"]


func _band(index: int = 1) -> Dictionary:
	return S2.content().get_band(index).duplicate(true)


func _map() -> Dictionary:
	return S2.content().get_map(&"reef").duplicate(true)


func _band_errors(rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"size_band", rec, BAND_SRC)


func _map_errors(rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(&"map", rec, MAP_SRC)


func _dump(errors: PackedStringArray) -> String:
	return "\n  " + "\n  ".join(errors) if errors.size() > 0 else "<no errors>"


func _is_well_formed(err: String) -> bool:
	var parts: PackedStringArray = err.split(": ", true, 2)
	if parts.size() != 3:
		return false
	return not parts[0].strip_edges().is_empty() and not parts[1].strip_edges().is_empty() \
		and parts[1].find(" ") == -1 and not parts[2].strip_edges().is_empty()


func _expect_field_error(errors: PackedStringArray, source: String, field: String, what: String) -> void:
	var found: bool = false
	for e in errors:
		if e.begins_with(source + ": ") and e.find(field) != -1:
			found = true
			assert_true(_is_well_formed(e), "%s: message not in `<source>: <field.path>: <problem>` form: %s" % [what, e])
	assert_true(found, "%s: expected an error from %s naming '%s', got:%s" % [what, source, field, _dump(errors)])


# ======================================================== real data

func test_real_data_is_valid_with_s2_fields() -> void:
	var c: ContentDB = S2.content()
	assert_true(c.is_valid(), "res://data must load clean:%s" % _dump(c.errors))
	for i in range(1, c.band_count() + 1):
		var b: Dictionary = c.get_band(i)
		for f in BAND_FIELDS:
			assert_true(b.has(f), "band %d lacks %s" % [i, f])
			assert_true(float(b.get(f, 0.0)) > 0.0, "band %d: %s must be > 0" % [i, f])
		assert_eq(_band_errors(b).size(), 0, "band %d validates clean:%s" % [i, _dump(_band_errors(b))])
	var m: Dictionary = c.get_map(&"reef")
	assert_true(m.has("bounds") and m.has("seabed") and m.has("obstacles"), "reef.json needs bounds, seabed and obstacles")
	assert_eq(_map_errors(m).size(), 0, "reef map validates clean:%s" % _dump(_map_errors(m)))


# ======================================================== broken band fields

func test_band_missing_new_field_is_reported() -> void:
	for f in BAND_FIELDS:
		var rec: Dictionary = _band()
		rec.erase(f)
		_expect_field_error(_band_errors(rec), BAND_SRC, f, "missing %s" % f)


func test_band_negative_new_field_is_reported() -> void:
	for f in BAND_FIELDS:
		var rec: Dictionary = _band(2)
		rec[f] = -1.0
		_expect_field_error(_band_errors(rec), BAND_SRC, f, "negative %s" % f)


func test_band_wrong_type_new_field_is_reported_not_crashed() -> void:
	for f in BAND_FIELDS:
		var rec: Dictionary = _band(3)
		rec[f] = "fast"
		_expect_field_error(_band_errors(rec), BAND_SRC, f, "string %s" % f)


func test_band_non_finite_new_field_is_rejected() -> void:
	var rec: Dictionary = _band()
	rec["turn_rate_deg_s"] = INF
	_expect_field_error(_band_errors(rec), BAND_SRC, "turn_rate_deg_s", "infinite turn rate")
	rec = _band()
	rec["accel_mps2"] = NAN
	_expect_field_error(_band_errors(rec), BAND_SRC, "accel_mps2", "NaN accel")


func test_band_zero_for_required_positive_fields() -> void:
	for f in ["accel_mps2", "turn_rate_deg_s", "brake_decel_mps2", "collision_radius_mult"]:
		var rec: Dictionary = _band()
		rec[f] = 0.0
		_expect_field_error(_band_errors(rec), BAND_SRC, f, "zero %s" % f)


# ======================================================== broken map fields

func test_map_missing_bounds_is_reported() -> void:
	var rec: Dictionary = _map()
	rec.erase("bounds")
	_expect_field_error(_map_errors(rec), MAP_SRC, "bounds", "missing bounds block")


func test_map_negative_soft_margin_is_reported() -> void:
	var rec: Dictionary = _map()
	var bounds: Dictionary = rec["bounds"]
	bounds["soft_margin_m"] = -5.0
	_expect_field_error(_map_errors(rec), MAP_SRC, "bounds.soft_margin_m", "negative margin")


func test_map_negative_current_is_reported() -> void:
	var rec: Dictionary = _map()
	var bounds: Dictionary = rec["bounds"]
	bounds["current_mps"] = -1.0
	_expect_field_error(_map_errors(rec), MAP_SRC, "bounds.current_mps", "negative current")


func test_map_missing_bounds_fields_are_reported_individually() -> void:
	for f in ["soft_margin_m", "current_mps"]:
		var rec: Dictionary = _map()
		var bounds: Dictionary = rec["bounds"]
		bounds.erase(f)
		_expect_field_error(_map_errors(rec), MAP_SRC, "bounds.%s" % f, "missing bounds.%s" % f)


func test_map_wrong_type_bounds_is_reported_not_crashed() -> void:
	var rec: Dictionary = _map()
	var bounds: Dictionary = rec["bounds"]
	bounds["soft_margin_m"] = "wide"
	_expect_field_error(_map_errors(rec), MAP_SRC, "bounds.soft_margin_m", "string margin")


func test_map_unknown_obstacle_kind_is_reported() -> void:
	var rec: Dictionary = _map()
	var obs: Array = rec["obstacles"]
	assert_true(obs.size() > 0, "test setup: reef.json has obstacles")
	if obs.is_empty():
		return
	var first: Dictionary = obs[0]
	first["kind"] = "torus"
	_expect_field_error(_map_errors(rec), MAP_SRC, "obstacles[0].kind", "unknown obstacle kind")


func test_map_obstacle_not_an_object_is_reported() -> void:
	var rec: Dictionary = _map()
	var obs: Array = rec["obstacles"]
	obs[0] = 42
	_expect_field_error(_map_errors(rec), MAP_SRC, "obstacles[0]", "obstacle is a number")


func test_map_limits_are_sane() -> void:
	# CLAUDE.md rule 6: the map fits well inside +-4 km, and the margin leaves a calm interior.
	var m: Dictionary = S2.map()
	assert_true(float(m["size_m"]) <= 8000.0, "map within +-4 km")
	assert_true(S2.soft_margin() * 2.0 < float(m["size_m"]), "margin leaves a calm interior")
