extends TestCase
## T1.3 tuning lab, data half: the shipped registry `data/god/tuning.json` (shape, ranges, every path exists in the
## shipped data), the "no shipped value changed / core.json append-only" guards, and the registry VALIDATOR
## (rejects unknown target / path, min >= max, step <= 0, duplicate ids, NaN / INF ...; accepts new rows as pure data).
## The validator tests go through the NAME TABLE in tuning_support.gd (validate()).

const TS := preload("res://tests/tuning_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const RULE_PATHS: Array[String] = ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "bite_cooldown_s"]
const BAND_PATHS: Array[String] = ["swim_speed_mps", "accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2"]
const TARGETS: Array[String] = ["rules", "band"]

## Shipped values of the tunable keys at the start of T1.3 (the task must not tune anything).
const SHIPPED_RULES: Dictionary = {
	"bite_reach_mult": 1.5, "bite_cone_deg": 60.0, "bite_buffer_s": 0.2, "bite_miss_cooldown_s": 0.4, "bite_cooldown_s": 0.5,
}
const SHIPPED_BANDS: Dictionary = {
	"swim_speed_mps": [3.0, 4.5, 6.0, 7.5], "accel_mps2": [9.0, 9.0, 8.0, 7.0], "drag_per_s": [1.5, 1.2, 1.0, 0.8],
	"turn_rate_deg_s": [220.0, 180.0, 140.0, 110.0], "brake_decel_mps2": [12.0, 12.0, 10.0, 9.0],
}
## core.json key order at the start of T1.3 (append-only: this list must stay a prefix).
const CORE_KEY_PREFIX: Array[String] = ["swallow_ratio", "hunger_max", "hunger_full_to_empty_s", "hunger_per_xp",
	"starvation_hp_frac_per_s", "regen_min_hunger_frac", "regen_hp_frac_per_s", "death_xp_loss_frac", "respawn_delay_s",
	"predator_hunt_ratio", "predator_give_up_s", "retaliate_duration_s", "player_hp_model", "grid_cell_m", "mouth_reach_mult",
	"mouth_cone_deg", "bite_cooldown_s", "bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "npc_scale",
	"spawn", "tiers", "schools", "quality", "xp_falloff", "hiding", "mutation_offer_count", "swim", "remains", "presence", "feedback"]


func _db() -> ContentDB:
	return S3.content()


## Registry entries, failing the test when the file is missing.
func _entries() -> Array[Dictionary]:
	var list: Array[Dictionary] = TS.entries()
	assert_true(not list.is_empty(), "res://data/god/tuning.json exists and holds entries")
	return list


# ======================================================================= shipped data guards (pass before T1.3 too)

func test_no_tunable_value_was_changed() -> void:
	var db: ContentDB = _db()
	for k: String in SHIPPED_RULES.keys():
		assert_almost_eq(float(S3.rule(db, k)), float(SHIPPED_RULES[k]), 1e-12, "rules/core.json %s is the shipped value" % k)
	for k: String in SHIPPED_BANDS.keys():
		var want: Array = SHIPPED_BANDS[k]
		for i in want.size():
			assert_almost_eq(float(db.get_band(i + 1)[k]), float(want[i]), 1e-12, "band %d %s is the shipped value" % [i + 1, k])


func test_core_json_stays_append_only() -> void:
	var keys: Array = (JSON.parse_string(FileAccess.get_file_as_string("res://data/rules/core.json")) as Dictionary).keys()
	for i in CORE_KEY_PREFIX.size():
		assert_true(i < keys.size() and str(keys[i]) == CORE_KEY_PREFIX[i], "core.json key #%d is still %s" % [i, CORE_KEY_PREFIX[i]])


func test_content_db_loads_clean_with_the_registry_file_present() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_eq(db.errors.size(), 0, "ContentDB ignores data/god and loads clean (got %s)" % [db.errors])


# ======================================================================= the shipped registry

func test_registry_file_exists_and_parses() -> void:
	assert_true(FileAccess.file_exists(TS.REGISTRY_PATH), "data/god/tuning.json exists")
	var doc: Variant = TS.registry_doc()
	assert_not_null(doc, "it parses as JSON")
	assert_ne(TS.entries_key(doc), "?", "an entry list (rows with an id) is found")
	assert_true(TS.entries().size() >= 10, "at least the ten initial rows (got %d)" % TS.entries().size())


func test_every_row_has_valid_fields() -> void:
	var rx := RegEx.new()
	rx.compile("^[a-z][a-z0-9_]*$")
	for e: Dictionary in _entries():
		var id: String = str(e.get("id", ""))
		assert_true(e.get("id") is String and rx.search(id) != null, "id is a snake_case string (got %s)" % id)
		assert_true(str(e.get("target", "")) in TARGETS, "%s: target is rules or band" % id)
		assert_true(e.get("path") is String and not str(e.get("path")).is_empty(), "%s: non-empty string path" % id)
		assert_true(e.get("label") is String and not str(e.get("label")).strip_edges().is_empty(), "%s: label" % id)
		assert_true(e.get("group") is String and not str(e.get("group")).strip_edges().is_empty(), "%s: group" % id)
		for f: String in ["min", "max", "step"]:
			assert_true(TS.has_num(e.get(f)) and is_finite(float(e.get(f, NAN))), "%s: %s is a finite number" % [id, f])
		assert_true(float(e.get("min", 0.0)) < float(e.get("max", 0.0)), "%s: min < max" % id)
		assert_true(float(e.get("step", 0.0)) > 0.0, "%s: step > 0" % id)
		assert_true(float(e.get("step", 0.0)) <= float(e.get("max", 0.0)) - float(e.get("min", 0.0)), "%s: step fits the range" % id)


func test_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for e: Dictionary in _entries():
		var id: String = str(e.get("id", ""))
		assert_false(seen.has(id), "duplicate id %s" % id)
		seen[id] = true
	var pairs: Dictionary = {}
	for e: Dictionary in _entries():
		var key: String = "%s:%s" % [e.get("target"), e.get("path")]
		assert_false(pairs.has(key), "two rows for the same target and path %s" % key)
		pairs[key] = true


func test_initial_rows_cover_the_bite_rules_and_the_band_movement_fields() -> void:
	for p: String in RULE_PATHS:
		assert_ne(TS.id_for("rules", p), "", "rules row for %s" % p)
	for p: String in BAND_PATHS:
		assert_ne(TS.id_for("band", p), "", "band row for %s" % p)


func test_every_path_exists_in_the_shipped_data_as_a_number() -> void:
	var db: ContentDB = _db()
	for e: Dictionary in _entries():
		var path: String = str(e.get("path", ""))
		if str(e.get("target", "")) == "rules":
			var v: Variant = S3.rule(db, path)
			assert_true(TS.has_num(v), "rules row %s: core.json has a numeric %s (got %s)" % [e.get("id"), path, v])
		else:
			for i in range(1, db.band_count() + 1):
				var bv: Variant = db.get_band(i).get(path)
				assert_true(TS.has_num(bv), "band row %s: band %d has a numeric %s (got %s)" % [e.get("id"), i, path, bv])


func test_slider_ranges_contain_the_shipped_values() -> void:
	var db: ContentDB = _db()
	for e: Dictionary in _entries():
		var lo: float = float(e.get("min", 0.0))
		var hi: float = float(e.get("max", 0.0))
		var path: String = str(e.get("path", ""))
		var values: Array[float] = []
		if str(e.get("target", "")) == "rules":
			var v: Variant = S3.rule(db, path)
			if TS.has_num(v):
				values.append(float(v))
		else:
			for i in range(1, db.band_count() + 1):
				var bv: Variant = db.get_band(i).get(path)
				if TS.has_num(bv):
					values.append(float(bv))
		for x: float in values:
			assert_true(x >= lo and x <= hi, "%s: shipped value %s inside [%s, %s]" % [e.get("id"), x, lo, hi])


func test_every_shipped_row_has_room_to_tune_away_from_the_data_value() -> void:
	var db: ContentDB = _db()
	for e: Dictionary in _entries():
		var cur: Variant = TS.data_value(e, db)
		if not TS.has_num(cur):
			continue
		var alt: float = TS.alt_value(e, db)
		assert_true(absf(alt - float(cur)) > 1e-9, "%s: a valid value different from the data value exists (alt %s, data %s)" % [e.get("id"), alt, cur])


# ======================================================================= validator (NAME TABLE: tuning_support.gd validate())

func _first(target: String, path: String) -> Dictionary:
	return TS.entry_for(target, path)


## Result of validating the shipped rows with `mutate` applied to a copy of the row (target, path) (or an extra row).
func _check_mutated(target: String, path: String, mutate: Callable) -> Dictionary:
	var list: Array = TS.entries_raw()
	for i in list.size():
		var e: Dictionary = list[i]
		if str(e.get("target", "")) == target and str(e.get("path", "")) == path:
			mutate.call(e)
			return TS.validate(list)
	# no such shipped row: reported by test_initial_rows_cover_..., nothing to validate here
	return {"found": false, "errors": [], "ok": true, "method": ""}


func _expect_rejected(res: Dictionary, what: String, needles: Array[String] = []) -> void:
	assert_true(bool(res["found"]), "a registry validator exists (NAME TABLE: %s)" % [TS.VALIDATE_METHODS])
	if not bool(res["found"]):
		return
	assert_false(bool(res["ok"]), "%s is rejected" % what)
	var text: String = "\n".join(PackedStringArray(res["errors"])).to_lower()
	assert_false(text.is_empty(), "%s: the rejection carries a message" % what)
	if not needles.is_empty():
		var any: bool = false
		for n: String in needles:
			any = any or text.contains(n.to_lower())
		assert_true(any, "%s: the message names the problem (one of %s), got: %s" % [what, needles, text])


func test_validator_accepts_the_shipped_registry() -> void:
	var res: Dictionary = TS.validate(TS.entries())
	assert_true(bool(res["found"]), "a registry validator exists (NAME TABLE: %s)" % [TS.VALIDATE_METHODS])
	assert_true(bool(res["ok"]), "the shipped rows validate clean (got %s)" % [res["errors"]])


func test_validator_rejects_an_unknown_target() -> void:
	for t: Variant in ["sim", "species", "", 3, null]:
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["target"] = t), "target %s" % [t], ["target"])


func test_validator_rejects_unknown_and_unsafe_paths() -> void:
	var rules_bad: Array = ["no_such_rule", "bite_reach_mult.x", "player_hp_model", "tiers", "spawn.min_player_distance_m_typo", "", "../x", "a/b", " bite_cone_deg"]
	for p: String in rules_bad:
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["path"] = p), "rules path '%s'" % p, ["path", "unknown", "numeric", "exist"])
	var band_bad: Array = ["no_such_field", "camera", "length_m", "lod_m", "", "../x"]
	for p2: String in band_bad:
		_expect_rejected(_check_mutated("band", "swim_speed_mps", func(e: Dictionary) -> void: e["path"] = p2), "band path '%s'" % p2, ["path", "unknown", "numeric", "exist"])
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["path"] = 5), "non-string path", ["path"])
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e.erase("path")), "missing path", ["path"])


func test_validator_rejects_a_band_path_under_the_rules_target_and_vice_versa() -> void:
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["path"] = "turn_rate_deg_s"), "a band field under target rules", ["path", "unknown", "exist"])
	_expect_rejected(_check_mutated("band", "swim_speed_mps", func(e: Dictionary) -> void: e["path"] = "bite_reach_mult"), "a rules key under target band", ["path", "unknown", "exist"])


func test_validator_rejects_a_bad_range() -> void:
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["max"] = e["min"]), "min == max", ["min", "max", "range"])
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void:
		var lo: float = float(e["min"])
		e["min"] = float(e["max"])
		e["max"] = lo), "min > max", ["min", "max", "range"])
	for f: String in ["min", "max", "step"]:
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e.erase(f)), "missing %s" % f, [f])
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e[f] = "1"), "string %s" % f, [f])
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e[f] = null), "null %s" % f, [f])


func test_validator_rejects_a_non_positive_step() -> void:
	for s: float in [0.0, -0.1, -1.0]:
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["step"] = s), "step %s" % s, ["step"])


func test_validator_rejects_nan_and_inf() -> void:
	for f: String in ["min", "max", "step"]:
		for bad: float in [NAN, INF, -INF]:
			_expect_rejected(_check_mutated("rules", "bite_cone_deg", func(e: Dictionary) -> void: e[f] = bad), "%s = %s" % [f, bad], [f, "finite", "nan", "inf"])


func test_validator_rejects_duplicate_ids_and_bad_ids() -> void:
	var list: Array = TS.entries_raw()
	if list.size() < 2:
		fail("the shipped registry has at least two rows")
		return
	var dup: Dictionary = (list[1] as Dictionary).duplicate(true)
	dup["id"] = (list[0] as Dictionary)["id"]
	dup["path"] = (list[1] as Dictionary)["path"]
	list[1] = dup
	_expect_rejected(TS.validate(list), "a duplicate id", ["duplicate", "unique", "already"])
	for bad_id: Variant in ["", 7, null, "Has Space", "UPPER"]:
		_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e["id"] = bad_id), "id %s" % [bad_id], ["id"])
	_expect_rejected(_check_mutated("rules", "bite_reach_mult", func(e: Dictionary) -> void: e.erase("id")), "missing id", ["id"])


func test_validator_rejects_a_row_that_is_not_an_object() -> void:
	var list: Array = TS.entries_raw()
	list.append("not a row")
	_expect_rejected(TS.validate(list), "a string row")
	var list2: Array = TS.entries_raw()
	list2.append([1, 2])
	_expect_rejected(TS.validate(list2), "an array row")


func test_new_rows_are_pure_data() -> void:
	# Later subtasks (T1.4 .. T2.1) ADD rows: a row for any numeric rules key or band field validates without code changes.
	var list: Array = TS.entries_raw()
	list.append({"id": "tl_probe_swallow", "target": "rules", "path": "swallow_ratio", "label": "Swallow ratio", "group": "Probe", "min": 0.02, "max": 0.3, "step": 0.01})
	list.append({"id": "tl_probe_nested", "target": "rules", "path": "hiding.detection_mult", "label": "Detection", "group": "Probe", "min": 0.1, "max": 1.0, "step": 0.05})
	list.append({"id": "tl_probe_hp", "target": "band", "path": "bite_power", "label": "Bite power", "group": "Probe", "min": 1.0, "max": 100.0, "step": 1.0})
	var res: Dictionary = TS.validate(list)
	assert_true(bool(res["found"]), "a registry validator exists (NAME TABLE: %s)" % [TS.VALIDATE_METHODS])
	assert_true(bool(res["ok"]), "extra rows over existing numeric keys (flat, nested, band) validate (got %s)" % [res["errors"]])
