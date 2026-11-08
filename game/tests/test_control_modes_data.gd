extends TestCase
## T1.4 control modes, data half: game/data/controls/modes.json (three presets, validated numbers), the ContentDB checks
## (positive and negative, on throw-away data copies), nothing added to rules/core.json, and the docs (docs/data/controls.md,
## the data README row, the orchestrator-default decision). The behaviour is in test_control_modes_sim / _smoothing / _input / _ui.

const CM := preload("res://tests/control_modes_support.gd")
const G := preload("res://tests/god_support.gd")
const TS := preload("res://tests/tuning_support.gd")


func after_each() -> void:
	G.cleanup_temp()


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _read(rel: String) -> String:
	return FileAccess.get_file_as_string(_repo(rel))


# ======================================================================= modes.json

func test_the_file_exists_and_holds_the_three_ids() -> void:
	assert_true(FileAccess.file_exists(CM.MODES_PATH), "game/data/controls/modes.json exists")
	var ids: Array[String] = CM.ids_file()
	for id: String in CM.IDS:
		assert_true(ids.has(id), "mode '%s' is in the file (found %s)" % [id, ids])


func test_ids_are_unique_and_snake_case() -> void:
	assert_false(CM.ids_file().is_empty(), "the file lists modes")
	var seen: Dictionary = {}
	var rx := RegEx.new()
	rx.compile("^[a-z][a-z0-9_]*$")
	for id: String in CM.ids_file():
		assert_false(seen.has(id), "id '%s' appears once" % id)
		seen[id] = true
		assert_true(rx.search(id) != null, "id '%s' is snake_case" % id)


func test_every_mode_has_a_label_and_a_one_line_description() -> void:
	for id: String in CM.IDS:
		var nm: String = CM.name_of(id)
		assert_false(nm.strip_edges().is_empty(), "%s has a `name`" % id)
		var d: String = CM.description_of(id)
		assert_false(d.strip_edges().is_empty(), "%s has a description string" % id)
		assert_false(d.contains("\n"), "%s description is one line" % id)
	var names: Dictionary = {}
	for id: String in CM.IDS:
		names[CM.name_of(id)] = true
	assert_eq(names.size(), CM.IDS.size(), "the three labels are different (the selector shows them)")


func test_classic_is_the_zero_preset() -> void:
	var m: Dictionary = CM.mode("classic")
	assert_false(m.is_empty(), "classic exists")
	assert_eq(CM.mode_f("classic", CM.KEY_TAU), 0.0, "classic: no smoothing (tau 0)")
	assert_eq(CM.mode_f("classic", CM.KEY_AIM), 0.0, "classic: no aim assist")
	assert_eq(CM.mode_f("classic", CM.KEY_LUNGE), 0.0, "classic: no lunge")
	var ck: String = CM.cap_key()
	if ck != "":
		assert_eq(CM.mode_f("classic", ck), 0.0, "classic: no turn cap (%s)" % ck)


func test_smoothed_is_input_only_with_a_modest_time_constant() -> void:
	var tau: float = CM.mode_f("smoothed", CM.KEY_TAU)
	assert_true(tau > 0.0 and tau <= 0.5, "smoothed: tau in (0, 0.5] s (night constraint: about 0.08-0.12), got %s" % tau)
	assert_eq(CM.mode_f("smoothed", CM.KEY_AIM), 0.0, "smoothed does not touch the sim: no aim assist")
	assert_eq(CM.mode_f("smoothed", CM.KEY_LUNGE), 0.0, "smoothed does not touch the sim: no lunge")


func test_assisted_turns_both_sim_assists_on_at_modest_strengths() -> void:
	var a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var l: float = CM.mode_f("assisted", CM.KEY_LUNGE)
	assert_true(a > 0.0 and a <= 1.0, "assisted aim strength in (0, 1], got %s" % a)
	assert_true(l > 0.0 and l <= 1.0, "assisted lunge strength in (0, 1], got %s" % l)
	assert_true(a < 1.0 and l < 1.0, "modest starting values (night constraint: about 0.5), not the maximum")


func test_every_number_is_finite_and_in_range() -> void:
	assert_false(CM.modes().is_empty(), "the file lists modes")
	for m: Dictionary in CM.modes():
		var id: String = str(m["id"])
		for k: Variant in m.keys():
			var v: Variant = m[k]
			if TS.has_num(v):
				assert_true(is_finite(float(v)), "%s.%s is finite" % [id, k])
		for key: String in [CM.KEY_AIM, CM.KEY_LUNGE]:
			if m.has(key):
				assert_true(TS.has_num(m[key]) and float(m[key]) >= 0.0 and float(m[key]) <= 1.0, "%s.%s within 0..1" % [id, key])
		if m.has(CM.KEY_TAU):
			assert_true(TS.has_num(m[CM.KEY_TAU]) and float(m[CM.KEY_TAU]) >= 0.0, "%s.%s >= 0" % [id, CM.KEY_TAU])
	var ck: String = CM.cap_key()
	if ck != "":
		for m: Dictionary in CM.modes():
			if m.has(ck):
				assert_true(TS.has_num(m[ck]) and float(m[ck]) >= 0.0, "%s.%s >= 0 (0 = none)" % [m["id"], ck])


func test_the_modes_are_not_rules_and_the_global_strengths_stay_off() -> void:
	var core: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/rules/core.json"))
	for k: Variant in core.keys():
		var ks: String = str(k)
		assert_false(ks.contains("control_mode") or ks.contains("mouse_smooth") or ks == "modes", "rules/core.json has no mode data (key %s)" % ks)
	assert_eq(float(core.get("aim_assist_strength", -1.0)), 0.0, "global aim_assist_strength still ships as 0.0")
	assert_eq(float(core.get("lunge_strength", -1.0)), 0.0, "global lunge_strength still ships as 0.0")


# ======================================================================= ContentDB

func test_shipped_data_loads_clean() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_true(db.is_valid(), "ContentDB loads clean: %s" % CM.errors_text(db))


func test_boundary_values_are_accepted() -> void:
	assert_true(FileAccess.file_exists(CM.MODES_PATH), "setup: modes.json exists")
	var db: ContentDB = CM.db_with_edit(func(_doc: Variant, pairs: Array[Dictionary]) -> void:
		for pr: Dictionary in pairs:
			var rec: Dictionary = pr["rec"]
			if pr["id"] == "smoothed":
				rec[CM.KEY_TAU] = 5.0
			if pr["id"] == "assisted":
				rec[CM.KEY_AIM] = 1.0
				rec[CM.KEY_LUNGE] = 1.0
			if pr["id"] == "classic":
				rec[CM.KEY_TAU] = 0.0)
	assert_true(db.is_valid(), "tau 0 / 5, strengths 1.0 are valid: %s" % CM.errors_text(db))


func test_missing_classic_is_rejected() -> void:
	var applied: Array[bool] = [true]
	var db: ContentDB = CM.db_with_edit(func(doc: Variant, _pairs: Array[Dictionary]) -> void:
		applied[0] = CM.rename_id(doc, "classic", "plain"))
	assert_true(applied[0], "test setup: classic renamed")
	assert_true(CM.rejected(db, ["classic"]), "no `classic` record is a load error naming it: %s" % CM.errors_text(db))


func test_duplicate_ids_are_rejected() -> void:
	var applied: Array[bool] = [true]
	var db: ContentDB = CM.db_with_edit(func(doc: Variant, _pairs: Array[Dictionary]) -> void:
		applied[0] = CM.locate(doc)["kind"] == "list"
		if applied[0]:
			CM.rename_id(doc, "smoothed", "assisted"))
	if not applied[0]:
		return  # id -> record layout: duplicates cannot be written
	assert_true(CM.rejected(db), "two records with one id are a load error: %s" % CM.errors_text(db))


func test_bad_ids_are_rejected() -> void:
	for bad: String in ["Fast Mode", "UPPER", "with-dash", "", "1mode"]:
		var db: ContentDB = CM.db_with_edit(func(doc: Variant, _pairs: Array[Dictionary]) -> void:
			CM.rename_id(doc, "smoothed", bad))
		assert_true(CM.rejected(db), "id '%s' is rejected: %s" % [bad, CM.errors_text(db)])


func test_bad_numbers_are_rejected_with_the_field_name() -> void:
	var cases: Array = [
		["smoothed", CM.KEY_TAU, -0.1, "negative tau"],
		["smoothed", CM.KEY_TAU, "slow", "text tau"],
		["smoothed", CM.KEY_TAU, null, "removed tau is handled below"],
		["assisted", CM.KEY_AIM, 1.5, "aim strength above 1"],
		["assisted", CM.KEY_AIM, -0.1, "negative aim strength"],
		["assisted", CM.KEY_AIM, "high", "text aim strength"],
		["assisted", CM.KEY_LUNGE, 2.0, "lunge strength above 1"],
		["assisted", CM.KEY_LUNGE, -1.0, "negative lunge strength"],
		["assisted", CM.KEY_LUNGE, [0.5], "array lunge strength"],
	]
	for c: Array in cases:
		if c[2] == null:
			continue  # a missing optional field is the implementer's call (default 0); not asserted
		var db: ContentDB = CM.db_with_field(str(c[0]), str(c[1]), c[2])
		assert_true(CM.rejected(db, [str(c[1])]), "%s is a load error naming %s: %s" % [c[3], c[1], CM.errors_text(db)])


func test_a_negative_turn_cap_is_rejected_when_the_data_has_one() -> void:
	var ck: String = CM.cap_key()
	if ck == "":
		return  # the cap is optional in the spec
	var db: ContentDB = CM.db_with_field("smoothed", ck, -5.0)
	assert_true(CM.rejected(db, [ck]), "negative %s is a load error: %s" % [ck, CM.errors_text(db)])


func test_a_non_object_record_is_rejected() -> void:
	var applied: Array[bool] = [false]
	var db: ContentDB = CM.db_with_edit(func(doc: Variant, _pairs: Array[Dictionary]) -> void:
		var loc: Dictionary = CM.locate(doc)
		if loc["kind"] == "list":
			(loc["container"] as Array).append("not an object")
			applied[0] = true
		elif loc["kind"] == "keyed":
			(loc["container"] as Dictionary)["junk_mode"] = 5
			applied[0] = true)
	assert_true(applied[0], "test setup: junk record appended")
	assert_true(CM.rejected(db), "a record that is not an object is a load error: %s" % CM.errors_text(db))


# ======================================================================= docs

func test_the_schema_page_documents_the_presets() -> void:
	var path: String = "docs/data/controls.md"
	assert_true(FileAccess.file_exists(_repo(path)), "docs/data/controls.md exists")
	var text: String = _read(path)
	assert_true(text.begins_with("---"), "R-protocol frontmatter")
	for needle: String in ["area:", "mirrors:", "verified:"]:
		assert_has(text, needle, "frontmatter key %s" % needle)
	for needle: String in ["controls/modes.json", CM.KEY_TAU, CM.KEY_AIM, CM.KEY_LUNGE, "SET_CONTROL_MODE", "state_hash", "classic",
			"smoothed", "assisted", "GameSettings"]:
		assert_has(text, needle, "the page covers: %s" % needle)
	assert_true(text.to_lower().contains("max("), "the page states effective strength = max(global rule, mode value)")


func test_the_data_readme_has_a_row_for_the_modes() -> void:
	assert_true(_read("game/data/README.md").contains("modes.json"), "game/data/README.md lists controls/modes.json")


func test_the_starting_values_are_logged_as_an_orchestrator_default() -> void:
	var dir: String = _repo("docs/decisions")
	var found: bool = false
	for f: String in TS.files_below(dir):
		if not f.ends_with(".md"):
			continue
		var t: String = FileAccess.get_file_as_string(dir.path_join(f))
		if t.contains("decided_by: orchestrator-default") and t.contains(CM.KEY_TAU) and t.contains("assisted"):
			found = true
	assert_true(found, "a decision with `decided_by: orchestrator-default` names mouse_smooth_tau_s and the assisted strengths")
