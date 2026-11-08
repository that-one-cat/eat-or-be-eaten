extends TestCase
## S5 quality tiers (game/scripts/ui/quality_settings.gd, look agent): profile table (low = Compatibility-safe set, no
## volumetric fog / refraction), default-tier detection, precedence `-- --quality=` > user://settings.cfg > detection,
## save_tier() keeping the other config sections, ambient density rule.
## user://settings.cfg is the REAL settings file of the game (the input section lives there too): every test backs it
## up in before_each and restores it in after_each. The command-line precedence test starts a second headless Godot
## (OS.execute) that runs res://tests/fixtures/quality_probe.gd, because OS.get_cmdline_user_args() cannot be faked
## in-process; the runner skips the fixtures directory.

const S5 := preload("res://tests/s5_support.gd")
const PROBE: String = "res://tests/fixtures/quality_probe.gd"

var _had_file: bool = false
var _backup: PackedByteArray = PackedByteArray()


func before_each() -> void:
	_had_file = FileAccess.file_exists(QualitySettings.SETTINGS_PATH)
	_backup = FileAccess.get_file_as_bytes(QualitySettings.SETTINGS_PATH) if _had_file else PackedByteArray()


func after_each() -> void:
	if _had_file:
		var f: FileAccess = FileAccess.open(QualitySettings.SETTINGS_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_backup)
			f.close()
	elif FileAccess.file_exists(QualitySettings.SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(QualitySettings.SETTINGS_PATH))


func _write_cfg(sections: Dictionary) -> void:
	var cfg := ConfigFile.new()
	for section: String in sections.keys():
		for key: String in (sections[section] as Dictionary).keys():
			cfg.set_value(section, key, (sections[section] as Dictionary)[key])
	cfg.save(QualitySettings.SETTINGS_PATH)


func _remove_cfg() -> void:
	if FileAccess.file_exists(QualitySettings.SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(QualitySettings.SETTINGS_PATH))


func _has_quality_arg() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(QualitySettings.ARG_PREFIX):
			return true
	return false


func _other(t: StringName) -> StringName:
	return QualitySettings.HIGH if t == QualitySettings.LOW else QualitySettings.LOW


# ======================================================== tiers and profiles

func test_the_tier_list_is_low_and_high() -> void:
	assert_eq(QualitySettings.TIERS.size(), 2, "exactly two tiers in the MVP")
	assert_has(QualitySettings.TIERS, QualitySettings.LOW)
	assert_has(QualitySettings.TIERS, QualitySettings.HIGH)
	assert_eq(String(QualitySettings.LOW), "low")
	assert_eq(String(QualitySettings.HIGH), "high")


func test_the_low_profile_drops_the_expensive_features() -> void:
	var low: Dictionary = QualitySettings.profile(QualitySettings.LOW)
	assert_false(bool(low["volumetric_fog"]), "low: no volumetric fog (Compatibility has none)")
	assert_false(bool(low["refraction"]), "low: no full-screen refraction quad")
	var high: Dictionary = QualitySettings.profile(QualitySettings.HIGH)
	assert_true(bool(high["volumetric_fog"]), "high: volumetric fog is a Forward+ extra and stays on in the table")
	assert_true(bool(high["refraction"]), "high: refraction quad on")


func test_every_tier_has_the_full_key_set_with_sane_values() -> void:
	var keys: Array[String] = ["volumetric_fog", "refraction", "light_shafts", "marine_snow", "surface_cells", "glow_levels", "fog_density_mult", "draw_distance_m"]
	for t: StringName in QualitySettings.TIERS:
		var p: Dictionary = QualitySettings.profile(t)
		for k: String in keys:
			assert_true(p.has(k), "%s profile has '%s'" % [t, k])
		assert_true(int(p.get("light_shafts", -1)) >= 0, "%s light_shafts >= 0" % t)
		assert_true(int(p.get("marine_snow", -1)) >= 0, "%s marine_snow >= 0" % t)
		assert_true(int(p.get("surface_cells", 0)) >= 1, "%s surface_cells >= 1" % t)
		assert_true(float(p.get("fog_density_mult", 0.0)) > 0.0, "%s fog_density_mult > 0" % t)
		assert_true(float(p.get("draw_distance_m", 0.0)) > 0.0, "%s draw_distance_m > 0" % t)
		var levels: Array = p.get("glow_levels", [])
		assert_true(levels.size() >= 1, "%s has at least one glow level" % t)
		for lv: Variant in levels:
			assert_true(int(lv) >= 1 and int(lv) <= 7, "%s glow level %s in 1..7" % [t, lv])


func test_low_is_strictly_lighter_than_high() -> void:
	var low: Dictionary = QualitySettings.profile(QualitySettings.LOW)
	var high: Dictionary = QualitySettings.profile(QualitySettings.HIGH)
	assert_true(int(low["light_shafts"]) < int(high["light_shafts"]), "fewer light shafts on low")
	assert_true(int(low["marine_snow"]) < int(high["marine_snow"]), "fewer marine snow flakes on low")
	assert_true(int(low["surface_cells"]) < int(high["surface_cells"]), "coarser surface mesh on low")
	assert_true((low["glow_levels"] as Array).size() < (high["glow_levels"] as Array).size(), "fewer glow levels on low")
	assert_true(float(low["draw_distance_m"]) < float(high["draw_distance_m"]), "shorter draw distance on low")
	assert_true(float(low["fog_density_mult"]) >= float(high["fog_density_mult"]), "denser fog on low (hides the shorter distance)")


func test_profile_returns_a_copy() -> void:
	var p: Dictionary = QualitySettings.profile(QualitySettings.LOW)
	p["volumetric_fog"] = true
	(p["glow_levels"] as Array).append(7)
	var fresh: Dictionary = QualitySettings.profile(QualitySettings.LOW)
	assert_false(bool(fresh["volumetric_fog"]), "editing a returned profile must not change the table")
	assert_false((fresh["glow_levels"] as Array).has(7), "nested arrays are copied too")


func test_an_unknown_tier_gets_the_high_profile() -> void:
	assert_eq(QualitySettings.profile(&"ultra"), QualitySettings.profile(QualitySettings.HIGH))


# ======================================================== GPU detection

func test_integrated_and_software_adapters_are_low() -> void:
	var weak: Array[String] = [
		"Intel(R) UHD Graphics 630", "Intel(R) HD Graphics 4000", "Intel(R) Iris(R) Xe Graphics", "AMD Radeon(TM) Graphics",
		"AMD Radeon Graphics", "AMD Radeon(TM) Vega 8 Graphics", "Mali-G78", "Adreno (TM) 730", "PowerVR Rogue GE8320",
		"llvmpipe (LLVM 15.0.7, 256 bits)", "SwiftShader Device (Subzero)", "Microsoft Basic Render Driver", "INTEL HD GRAPHICS 520",
	]
	for adapter: String in weak:
		assert_true(QualitySettings.is_integrated_gpu(adapter), "'%s' is a weak/software adapter" % adapter)


func test_discrete_and_apple_adapters_are_not_low() -> void:
	var strong: Array[String] = [
		"NVIDIA GeForce GTX 1060", "NVIDIA GeForce RTX 4070", "AMD Radeon RX 6800 XT", "AMD Radeon RX 580", "Intel(R) Arc(TM) A770 Graphics",
		"Apple M2", "Apple M1 Pro", "Apple M3 Max", "", "Unknown",
	]
	for adapter: String in strong:
		assert_false(QualitySettings.is_integrated_gpu(adapter), "'%s' must not be treated as weak" % adapter)


func test_the_default_tier_follows_the_renderer_and_the_adapter() -> void:
	var method: String = RenderingServer.get_current_rendering_method()
	var adapter: String = RenderingServer.get_video_adapter_name()
	var got: StringName = QualitySettings.detect_default_tier()
	if method == "gl_compatibility":
		assert_eq(String(got), "low", "the Compatibility renderer always defaults to low (adapter '%s')" % adapter)
	else:
		var want: String = "low" if QualitySettings.is_integrated_gpu(adapter) else "high"
		assert_eq(String(got), want, "renderer '%s', adapter '%s'" % [method, adapter])


func test_is_forward_plus_matches_the_renderer() -> void:
	assert_eq(QualitySettings.is_forward_plus(), RenderingServer.get_current_rendering_method() == "forward_plus")


# ======================================================== precedence: file > detection (in-process)

func test_the_settings_file_beats_detection() -> void:
	if _has_quality_arg():
		return  # the runner itself was started with --quality=: that arg wins by design, nothing to compare
	for want: StringName in QualitySettings.TIERS:
		_write_cfg({"graphics": {"quality_tier": String(want)}})
		assert_eq(String(QualitySettings.tier()), String(want), "[graphics] quality_tier=%s must win over detection (default %s)" % [want, QualitySettings.detect_default_tier()])


func test_without_a_usable_value_detection_decides() -> void:
	if _has_quality_arg():
		return
	var detected: String = String(QualitySettings.detect_default_tier())
	_remove_cfg()
	assert_eq(String(QualitySettings.tier()), detected, "no settings file")
	_write_cfg({"input": {"sensitivity": 0.0025}})
	assert_eq(String(QualitySettings.tier()), detected, "a file without the [graphics] section")
	_write_cfg({"graphics": {"vsync": true}})
	assert_eq(String(QualitySettings.tier()), detected, "a [graphics] section without quality_tier")
	_write_cfg({"graphics": {"quality_tier": ""}})
	assert_eq(String(QualitySettings.tier()), detected, "an empty quality_tier")


func test_an_unknown_value_in_the_file_falls_back_to_detection() -> void:
	if _has_quality_arg():
		return
	var detected: String = String(QualitySettings.detect_default_tier())
	for bad: String in ["ultra", "medium", "3", "lo w"]:
		_write_cfg({"graphics": {"quality_tier": bad}})
		assert_eq(String(QualitySettings.tier()), detected, "quality_tier '%s' is not a tier: detection decides" % bad)


# ======================================================== save_tier

func test_save_tier_round_trips_and_keeps_other_sections() -> void:
	_write_cfg({"input": {"sensitivity": 0.0025, "invert_y": true}, "graphics": {"fov": 80.0}, "audio": {"master": 0.5}})
	for t: StringName in QualitySettings.TIERS:
		assert_eq(QualitySettings.save_tier(t), OK, "save_tier(%s)" % t)
		var cfg := ConfigFile.new()
		assert_eq(cfg.load(QualitySettings.SETTINGS_PATH), OK)
		assert_eq(str(cfg.get_value("graphics", "quality_tier", "")), String(t), "stored value")
		assert_almost_eq(float(cfg.get_value("input", "sensitivity", 0.0)), 0.0025, 1e-9, "[input] sensitivity kept")
		assert_eq(bool(cfg.get_value("input", "invert_y", false)), true, "[input] invert_y kept")
		assert_almost_eq(float(cfg.get_value("graphics", "fov", 0.0)), 80.0, 1e-9, "other [graphics] keys kept")
		assert_almost_eq(float(cfg.get_value("audio", "master", 0.0)), 0.5, 1e-9, "[audio] kept")
		if not _has_quality_arg():
			assert_eq(String(QualitySettings.tier()), String(t), "tier() reads what save_tier() wrote")


func test_save_tier_creates_the_file_when_missing() -> void:
	_remove_cfg()
	assert_eq(QualitySettings.save_tier(QualitySettings.LOW), OK)
	assert_true(FileAccess.file_exists(QualitySettings.SETTINGS_PATH), "settings.cfg created")
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(QualitySettings.SETTINGS_PATH), OK)
	assert_eq(str(cfg.get_value("graphics", "quality_tier", "")), "low")


func test_save_tier_refuses_an_unknown_tier_and_leaves_the_file_alone() -> void:
	_write_cfg({"graphics": {"quality_tier": "high"}})
	var before: PackedByteArray = FileAccess.get_file_as_bytes(QualitySettings.SETTINGS_PATH)
	for bad: StringName in [&"ultra", &"", &"HIGH"]:
		assert_eq(QualitySettings.save_tier(bad), ERR_INVALID_PARAMETER, "save_tier('%s')" % bad)
	assert_eq(FileAccess.get_file_as_bytes(QualitySettings.SETTINGS_PATH), before, "file unchanged after refused saves")


# ======================================================== precedence: arg > file > detection (second process)

## Runs the probe with `-- <arg>` and returns {"tier": "...", "default": "..."} ({} when the process failed).
func _probe(arg: String) -> Dictionary:
	var out: Array = []
	var args: PackedStringArray = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", PROBE]
	if not arg.is_empty():
		args.append("--")
		args.append(arg)
	var code: int = OS.execute(OS.get_executable_path(), args, out, true)
	if code != 0 or out.is_empty():
		return {}
	var res: Dictionary = {}
	for line: String in str(out[0]).split("\n"):
		if line.begins_with("S5_TIER="):
			res["tier"] = line.trim_prefix("S5_TIER=").strip_edges()
		elif line.begins_with("S5_DEFAULT="):
			res["default"] = line.trim_prefix("S5_DEFAULT=").strip_edges()
	return res


func test_the_command_line_arg_beats_the_file_and_detection() -> void:
	if not FileAccess.file_exists(PROBE):
		fail("fixture missing: %s" % PROBE)
		return
	for want: StringName in QualitySettings.TIERS:
		_write_cfg({"graphics": {"quality_tier": String(_other(want))}})  # the file says the opposite
		var r: Dictionary = _probe("--quality=%s" % want)
		if r.is_empty():
			fail("the probe process failed (OS.execute of %s)" % OS.get_executable_path())
			return
		assert_eq(str(r.get("tier", "")), String(want), "-- --quality=%s must beat a file saying %s" % [want, _other(want)])


func test_the_file_beats_detection_in_a_fresh_process_and_a_junk_arg_falls_back() -> void:
	if not FileAccess.file_exists(PROBE):
		fail("fixture missing: %s" % PROBE)
		return
	var base: Dictionary = _probe("")
	if base.is_empty():
		fail("the probe process failed (OS.execute of %s)" % OS.get_executable_path())
		return
	var detected: String = str(base.get("default", ""))
	_write_cfg({"graphics": {"quality_tier": String(_other(StringName(detected)))}})
	var from_file: Dictionary = _probe("")
	assert_eq(str(from_file.get("tier", "")), String(_other(StringName(detected))), "file value beats the detected default '%s'" % detected)
	var junk: Dictionary = _probe("--quality=ultra")
	assert_eq(str(junk.get("tier", "")), detected, "an unknown --quality value falls back to detection (not to the file)")
	_remove_cfg()
	var none: Dictionary = _probe("")
	assert_eq(str(none.get("tier", "")), detected, "no arg, no file: detection")


# ======================================================== ambient density rule (S4 hook used by the tiers)

func test_ambient_density_mult_reads_the_rules() -> void:
	var db: ContentDB = S5.content()
	var low: float = QualitySettings.ambient_density_mult(db, QualitySettings.LOW)
	var high: float = QualitySettings.ambient_density_mult(db, QualitySettings.HIGH)
	assert_true(low > 0.0 and low <= 1.0, "low multiplier in (0, 1], got %s" % low)
	assert_true(high >= low and high <= 1.0, "high multiplier >= low and <= 1, got %s" % high)
	assert_almost_eq(QualitySettings.ambient_density_mult(null, QualitySettings.LOW), 1.0, 1e-9, "no ContentDB = 1")
