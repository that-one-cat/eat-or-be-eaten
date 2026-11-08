extends TestCase
## T1.3 tuning lab, presets and the `tune` console command surface: save / load round trip, all-or-nothing load,
## name sanitising (no path escapes), export, `tune list` / usage answers. Every file goes to an INJECTED temp tree
## (TS.inject_dirs(); NAME TABLE in tuning_support.gd): the real user://tuning is never written. A test that cannot
## inject FAILS (it does not fall back to the real directory).

const TS := preload("res://tests/tuning_support.gd")
const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const RULE_PATHS: Array[String] = ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "bite_cooldown_s"]
const BAND_PATHS: Array[String] = ["swim_speed_mps", "accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2"]
const EVIL: String = "tlevil"
const PROBE_EXPORT: String = "zz_tl_export_probe"

var _inj: String = ""
var _cmds: GodCommands = null


func before_each() -> void:
	_cmds = TS.commands()
	_inj = TS.inject_dirs()


func after_each() -> void:
	TS.restore_dirs()
	TS.cleanup_tmp()
	_remove_probe_export()


## False (and a recorded failure) when the preset / export dirs could not be injected.
func _ok() -> bool:
	if _inj != "":
		fail(_inj)
		return false
	return true


func _target(path: String) -> String:
	return "band" if path in BAND_PATHS else "rules"


func _id(path: String) -> String:
	return TS.id_for(_target(path), path)


func _alt(path: String) -> float:
	return TS.alt_value(TS.entry_for(_target(path), path), S3.content())


func _set_line(path: String) -> String:
	return "tune %s %s" % [_id(path), TS.fmt(_alt(path))]


## Rig with the five bite rules and a band field overridden by console lines; returns the rig of TS.composite_rig.
func _rig(lines: Array) -> Dictionary:
	return TS.composite_rig({}, lines)


func _x(rg: Dictionary, line: String) -> String:
	return TS.tune(_cmds, rg["w"], (rg["p"] as SimEntity).id, line)


func _read(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


# ======================================================================= injection and defaults

func test_preset_and_export_dirs_are_injectable() -> void:
	assert_eq(_inj, "", "the preset and export base directories can be redirected for tests")


func test_default_preset_dir_is_user_tuning_and_export_dir_is_reports_tuning() -> void:
	var src: String = FileAccess.get_file_as_string(TS.OVERRIDES_SCRIPT)
	assert_false(src.is_empty(), "res://scripts/sim/tuning_overrides.gd exists")
	assert_has(src, "user://tuning", "presets default to user://tuning")
	assert_has(src, "reports/tuning", "exports default to reports/tuning")


func test_setting_listing_and_resetting_writes_no_files() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([])
	_x(rg, _set_line("bite_reach_mult"))
	_x(rg, "tune list")
	_x(rg, "tune reset")
	assert_eq(TS.files_below(TS.TMP_ROOT).size(), 0, "no preset or export file appears without `save` / `export`")


# ======================================================================= save / load

func test_save_writes_a_versioned_document_with_only_the_overridden_ids() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult"), _set_line("turn_rate_deg_s")])
	var ans: String = _x(rg, "tune save my_preset")
	assert_true(FileAccess.file_exists(TS.preset_file("my_preset")), "save wrote <preset dir>/my_preset.json (answer: %s)" % ans)
	var doc: Variant = _read(TS.preset_file("my_preset"))
	assert_true(doc is Dictionary, "the file is a JSON object")
	if not (doc is Dictionary):
		return
	assert_true(TS.has_num((doc as Dictionary).get(TS.PRESET_VERSION_KEY)), "has a numeric `%s`" % TS.PRESET_VERSION_KEY)
	var ov: Variant = (doc as Dictionary).get(TS.PRESET_OVERRIDES_KEY)
	assert_true(ov is Dictionary, "has an `%s` object" % TS.PRESET_OVERRIDES_KEY)
	if not (ov is Dictionary):
		return
	var reach_id: String = _id("bite_reach_mult")
	var turn_id: String = _id("turn_rate_deg_s")
	assert_eq((ov as Dictionary).size(), 2, "exactly the two overridden ids (got %s)" % [ov])
	assert_almost_eq(float((ov as Dictionary).get(reach_id, -1.0)), _alt("bite_reach_mult"), 1e-6, "reach value")
	assert_almost_eq(float((ov as Dictionary).get(turn_id, -1.0)), _alt("turn_rate_deg_s"), 1e-6, "turn value")


func test_save_load_round_trip_restores_the_same_sim() -> void:
	if not _ok():
		return
	var lines: Array = []
	for p: String in RULE_PATHS:
		lines.append(_set_line(p))
	var direct: Dictionary = TS.composite({}, lines)
	var base: Dictionary = TS.composite({}, [])
	assert_ne(direct["trace"], base["trace"], "the override set changes the sim (self-check)")
	var first: Dictionary = _rig(lines)
	_x(first, "tune save round_trip")
	# 1) same world: reset, then load
	_x(first, "tune reset")
	var ans: String = _x(first, "tune load round_trip")
	assert_false(ans.is_empty(), "load answers")
	assert_eq(TS.composite_run(first)["trace"], direct["trace"], "reset + load in the same world == the original override set")
	# 2) another, fresh world loads the preset
	var second: Dictionary = _rig([])
	_x(second, "tune load round_trip")
	assert_eq(TS.composite_run(second)["trace"], direct["trace"], "a fresh world that loads the preset runs identically")


func test_load_lists_the_loaded_values() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_cone_deg")])
	_x(rg, "tune save listed")
	var other: Dictionary = _rig([])
	_x(other, "tune load listed")
	var text: String = _x(other, "tune list")
	assert_has(text, _id("bite_cone_deg"), "`tune list` shows the id")
	assert_has(text, TS.fmt(_alt("bite_cone_deg")), "`tune list` shows the loaded value")


func _bad_preset_cases() -> Array:
	var reach: String = _id("bite_reach_mult")
	var e: Dictionary = TS.entry_for("rules", "bite_reach_mult")
	var hi: float = float(e.get("max", 1.0))
	var lo: float = float(e.get("min", 0.0))
	var good: float = _alt("bite_cone_deg")
	var cone: String = _id("bite_cone_deg")
	var ok_part: Dictionary = {cone: good}
	return [
		["unknown id next to a valid one", {"version": 1, "overrides": {cone: good, "no_such_id_zz": 1.0}}, "no_such_id_zz"],
		["value above max", {"version": 1, "overrides": {cone: good, reach: hi * 10.0 + 1.0}}, reach],
		["value below min", {"version": 1, "overrides": {cone: good, reach: lo - 1.0}}, reach],
		["string value", {"version": 1, "overrides": {cone: good, reach: "2.0"}}, reach],
		["null value", {"version": 1, "overrides": {cone: good, reach: null}}, reach],
		["bool value", {"version": 1, "overrides": {cone: good, reach: true}}, reach],
		["overrides is an array", {"version": 1, "overrides": [1, 2]}, ""],
		["overrides missing", {"version": 1}, ""],
		["not an object", [1, 2, 3], ""],
		["empty id key", {"version": 1, "overrides": {"": 1.0, cone: good}}, ""],
		["id of the wrong type is impossible in JSON: nested object value", {"version": 1, "overrides": ok_part.merged({reach: {"x": 1}})}, reach],
	]


func test_a_bad_preset_is_rejected_whole_and_changes_nothing() -> void:
	if not _ok():
		return
	var pre_line: String = _set_line("bite_reach_mult")
	var expected: Dictionary = TS.composite({}, [pre_line])
	for c: Array in _bad_preset_cases():
		TS.write_preset("bad", c[1])
		var rg: Dictionary = _rig([pre_line])
		var ans: String = _x(rg, "tune load bad")
		assert_false(ans.is_empty(), "%s: a message is shown" % c[0])
		if str(c[2]) != "":
			assert_has(ans, str(c[2]), "%s: the message names the offender" % c[0])
		assert_eq(TS.composite_run(rg)["trace"], expected["trace"], "%s: nothing was applied (the earlier override is intact, no partial apply)" % c[0])


func test_unparsable_and_non_finite_preset_files_are_rejected() -> void:
	if not _ok():
		return
	var reach: String = _id("bite_reach_mult")
	var base: Dictionary = TS.composite({}, [])
	var texts: Dictionary = {
		"garbage": "this is not json",
		"empty file": "",
		"truncated": "{\"version\": 1, \"overrides\": {",
		"nan literal": "{\"version\": 1, \"overrides\": {\"%s\": NaN}}" % reach,
		"overflow": "{\"version\": 1, \"overrides\": {\"%s\": 1e999}}" % reach,
	}
	for k: String in texts.keys():
		DirAccess.make_dir_recursive_absolute(TS.PRESET_DIR)
		var f: FileAccess = FileAccess.open(TS.preset_file("broken"), FileAccess.WRITE)
		f.store_string(texts[k])
		f.close()
		var rg: Dictionary = _rig([])
		var ans: String = _x(rg, "tune load broken")
		assert_false(ans.is_empty(), "%s: a message is shown" % k)
		assert_eq(TS.composite_run(rg)["trace"], base["trace"], "%s: nothing applied" % k)


func test_loading_a_missing_preset_says_so_and_changes_nothing() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([])
	var ans: String = _x(rg, "tune load does_not_exist")
	assert_has(ans, "does_not_exist", "the message names the preset")
	assert_eq(TS.composite_run(rg)["trace"], TS.composite({}, [])["trace"], "nothing applied")
	assert_eq(TS.files_below(TS.TMP_ROOT).size(), 0, "and nothing was created")


func test_save_and_load_without_a_name_print_usage() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	for sub: String in ["save", "load", "export"]:
		var ans: String = _x(rg, "tune " + sub)
		assert_has(ans.to_lower(), "usage", "tune %s without a name prints usage (got: %s)" % [sub, ans])
	assert_eq(TS.files_below(TS.TMP_ROOT).size(), 0, "no file written")


# ======================================================================= names

func test_good_names_map_to_their_file() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	for n: String in ["a", "abc", "my-preset_1", "0"]:
		_x(rg, "tune save " + n)
		assert_true(FileAccess.file_exists(TS.preset_file(n)), "'%s' is saved as %s.json" % [n, n])


func test_hostile_names_never_escape_the_preset_dir() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	var names: Array[String] = [
		"../" + EVIL, "../../" + EVIL, "../../../" + EVIL, "..\\" + EVIL, "/" + EVIL, "a/../../" + EVIL, "....//" + EVIL,
		"..", ".", "./" + EVIL, "user://" + EVIL, "res://" + EVIL, EVIL + "/../..", "%2e%2e/" + EVIL, "a b/" + EVIL, "C:\\" + EVIL,
		"\"my preset " + EVIL + "\"", "UPPER" + EVIL, "tab\t" + EVIL, "é" + EVIL, "x.json", "x.json.json", "x.y",
	]
	for n: String in names:
		_x(rg, "tune save \"%s\"" % n.replace("\"", ""))
	var rx := RegEx.new()
	rx.compile("^[a-z0-9_-]+\\.json$")
	var preset_prefix: String = "a/b/presets/"
	for f: String in TS.files_below(TS.TMP_ROOT):
		assert_true(f.begins_with(preset_prefix), "'%s' is inside the preset dir (nothing escaped to the temp tree)" % f)
		assert_true(rx.search(f.get_file()) != null, "the saved name '%s' only uses [a-z0-9_-]" % f.get_file())
		assert_false(f.trim_prefix(preset_prefix).contains("/"), "no sub-directories are created ('%s')" % f)
	for gone: String in ["user://%s.json" % EVIL, "user://%s" % EVIL, "res://%s.json" % EVIL, "res://%s" % EVIL]:
		assert_false(FileAccess.file_exists(gone) or DirAccess.dir_exists_absolute(gone), "%s was not created" % gone)
	assert_eq(_stray().size(), 0, "no file with the hostile token exists outside the preset dir (got %s)" % [_stray()])


## Files whose name contains the hostile token anywhere under user:// except the preset / export dirs (those would be escapes).
func _stray() -> Array[String]:
	var out: Array[String] = []
	for f: String in TS.files_below("user://"):
		if f.to_lower().contains(EVIL) and not f.begins_with("test_tuning_tmp/a/b/presets/") and not f.begins_with("test_tuning_tmp/a/b/export/"):
			out.append(f)
	return out


func test_hostile_names_never_load_files_from_outside() -> void:
	if not _ok():
		return
	# a preset sits one directory above the preset dir: a traversal name must not reach it
	var reach: String = _id("bite_reach_mult")
	G.write_json(TS.TMP_ROOT.path_join("a/b/%s.json" % EVIL), {"version": 1, "overrides": {reach: _alt("bite_reach_mult")}})
	var rg: Dictionary = _rig([])
	for n: String in ["../" + EVIL, "..\\" + EVIL, "/a/b/" + EVIL]:
		_x(rg, "tune load \"%s\"" % n)
	assert_eq(TS.composite_run(rg)["trace"], TS.composite({}, [])["trace"], "no hostile load applied anything")


# ======================================================================= export

func test_export_writes_the_same_document_into_the_export_dir() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult"), _set_line("brake_decel_mps2")])
	_x(rg, "tune save same")
	var ans: String = _x(rg, "tune export handoff")
	assert_true(FileAccess.file_exists(TS.export_file("handoff")), "export wrote <export dir>/handoff.json (answer: %s)" % ans)
	assert_false(FileAccess.file_exists(TS.preset_file("handoff")), "export does not write into the preset dir")
	assert_eq(_read(TS.export_file("handoff")), _read(TS.preset_file("same")), "same {version, overrides} document as `save`")
	# the exported file is a valid preset: copy it into the preset dir and load it into a fresh world
	G.write_json(TS.preset_file("from_export"), _read(TS.export_file("handoff")))
	var fresh: Dictionary = _rig([])
	_x(fresh, "tune load from_export")
	assert_eq(TS.composite_run(fresh)["trace"], TS.composite({}, [_set_line("bite_reach_mult"), _set_line("brake_decel_mps2")])["trace"], "export -> load round trip")


func test_hostile_export_names_never_escape_the_export_dir() -> void:
	if not _ok():
		return
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	for n: String in ["../" + EVIL, "../../" + EVIL, "../../../" + EVIL, "/" + EVIL, "..", "UPPER" + EVIL, "a/b/" + EVIL]:
		_x(rg, "tune export \"%s\"" % n)
	var rx := RegEx.new()
	rx.compile("^[a-z0-9_-]+\\.json$")
	for f: String in TS.files_below(TS.TMP_ROOT):
		assert_true(f.begins_with("a/b/export/"), "'%s' is inside the export dir" % f)
		assert_true(rx.search(f.get_file()) != null, "'%s' only uses [a-z0-9_-]" % f.get_file())
	assert_eq(_stray().size(), 0, "no stray export outside the export dir (got %s)" % [_stray()])


func _repo_export_dir() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join("reports/tuning").simplify_path()


func _remove_probe_export() -> void:
	var f: String = _repo_export_dir().path_join(PROBE_EXPORT + ".json")
	if FileAccess.file_exists(f):
		DirAccess.remove_absolute(f)


func test_default_export_goes_to_reports_tuning_inside_the_project() -> void:
	TS.restore_dirs()  # use the real default export dir, with a unique probe name that is removed afterwards
	var dir_existed: bool = DirAccess.dir_exists_absolute(_repo_export_dir())
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	var ans: String = _x(rg, "tune export " + PROBE_EXPORT)
	var target: String = _repo_export_dir().path_join(PROBE_EXPORT + ".json")
	assert_true(FileAccess.file_exists(target), "export wrote %s (answer: %s)" % [target, ans])
	var doc: Variant = _read(target) if FileAccess.file_exists(target) else null
	assert_true(doc is Dictionary and ((doc as Dictionary).get(TS.PRESET_OVERRIDES_KEY) is Dictionary), "it is a preset document")
	_remove_probe_export()
	if not dir_existed:
		DirAccess.remove_absolute(_repo_export_dir())  # only removes an empty directory


# ======================================================================= the `tune` command surface

func test_tune_is_registered_with_a_usage_line() -> void:
	assert_true(_cmds.has_command(&"tune"), "tune is registered by GodSimCommands.register_all")
	assert_has(_cmds.help_text(), "tune", "help lists tune")
	var usage: String = _cmds.help_text("tune").to_lower()
	for sub: String in ["list", "reset", "save", "load", "export"]:
		assert_has(usage, sub, "the usage mentions `%s`" % sub)


func test_plain_command_registry_has_no_tune() -> void:
	assert_false(GodCommands.with_builtins().has_command(&"tune"), "tune exists only where the God registry registers it")


func test_tune_list_names_every_registry_row_and_marks_the_overridden_one() -> void:
	var rg: Dictionary = _rig([])
	var text: String = _x(rg, "tune list")
	for e: Dictionary in TS.entries():
		assert_has(text, str(e.get("id")), "`tune list` shows %s" % e.get("id"))
	var alt: float = _alt("bite_reach_mult")
	_x(rg, _set_line("bite_reach_mult"))
	var line_after: String = _line_of(_x(rg, "tune list"), _id("bite_reach_mult"))
	assert_true(_numbers_in(line_after).any(func(n: float) -> bool: return absf(n - alt) < 1e-3), "the overridden row shows the new value %s (line: %s)" % [alt, line_after])
	_x(rg, "tune reset %s" % _id("bite_reach_mult"))
	var line_reset: String = _line_of(_x(rg, "tune list"), _id("bite_reach_mult"))
	assert_false(_numbers_in(line_reset).any(func(n: float) -> bool: return absf(n - alt) < 1e-3), "after `tune reset <id>` the value is gone (line: %s)" % line_reset)


func test_setting_a_value_answers_with_the_id_and_the_value() -> void:
	var rg: Dictionary = _rig([])
	var ans: String = _x(rg, _set_line("bite_cone_deg"))
	assert_has(ans, _id("bite_cone_deg"), "the answer names the id")
	assert_has(ans, TS.fmt(_alt("bite_cone_deg")), "and the value")


func test_reset_of_an_unknown_id_is_an_error_not_a_reset_all() -> void:
	var rg: Dictionary = _rig([_set_line("bite_reach_mult")])
	var expected: Dictionary = TS.composite({}, [_set_line("bite_reach_mult")])
	var ans: String = _x(rg, "tune reset no_such_id_zz")
	assert_has(ans, "no_such_id_zz", "the message names the unknown id")
	assert_eq(TS.composite_run(rg)["trace"], expected["trace"], "the existing override survived")


func _line_of(text: String, id: String) -> String:
	for l: String in text.split("\n"):
		if l.contains(id):
			return l
	return ""


func _numbers_in(text: String) -> Array[float]:
	var out: Array[float] = []
	var rx := RegEx.new()
	rx.compile("-?\\d+(?:\\.\\d+)?(?:[eE][-+]?\\d+)?")
	for m: RegExMatch in rx.search_all(text):
		out.append(m.get_string().to_float())
	return out
