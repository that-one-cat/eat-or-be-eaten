extends TestCase
## T1.1 build gate: the dev tools (God menu, console, SimDebug-backed commands) exist only in debug / test builds or
## in an export carrying the `god_menu` feature tag. The flag is a pure function with injectable inputs; the shipping
## export preset must not carry the tag; main.gd must reach the host only through the gate (load() by path).


func test_allowed_truth_table() -> void:
	assert_false(GodBuild.allowed(false, false), "release export without the tag: off")
	assert_true(GodBuild.allowed(true, false), "debug build: on")
	assert_true(GodBuild.allowed(false, true), "release export with the god_menu tag: on")
	assert_true(GodBuild.allowed(true, true), "both: on")


func test_default_in_the_editor_binary_runner_is_on() -> void:
	assert_true(OS.is_debug_build(), "test setup: the headless runner is a debug build")
	assert_true(GodBuild.allowed(), "the runner (debug build) allows the dev tools")


func test_script_arg_is_read_only_when_dev_tools_are_allowed() -> void:
	var args: PackedStringArray = ["--filter=x", "--god-script=res://a/b.txt"]
	assert_eq(GodBuild.script_arg(args, true), "res://a/b.txt", "debug: the path")
	assert_eq(GodBuild.script_arg(args, false), "", "release: --god-script is ignored")


func test_script_arg_edge_cases() -> void:
	assert_eq(GodBuild.script_arg(PackedStringArray(), true), "", "no args")
	assert_eq(GodBuild.script_arg(PackedStringArray(["--god-script="]), true), "", "empty value")
	assert_eq(GodBuild.script_arg(PackedStringArray(["--god-script=   "]), true), "", "blank value")
	assert_eq(GodBuild.script_arg(PackedStringArray(["--god-script= /tmp/s.txt "]), true), "/tmp/s.txt", "edges stripped")
	assert_eq(GodBuild.script_arg(PackedStringArray(["--god-scripts=/x", "--other=--god-script=/y"]), true), "", "only the exact prefix counts")


func test_no_export_preset_carries_the_god_menu_feature() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://export_presets.cfg"), OK, "export_presets.cfg loads")
	var presets: int = 0
	var shipping: bool = false
	for section: String in cfg.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		presets += 1
		var features: String = str(cfg.get_value(section, "custom_features", ""))
		assert_false(features.contains("god_menu"), "%s (%s): custom_features must not enable the God tools" % [section, cfg.get_value(section, "name", "?")])
		if str(cfg.get_value(section, "name", "")) == "Windows Desktop":
			shipping = true
	assert_true(presets >= 1, "at least one preset parsed")
	assert_true(shipping, "the shipping preset 'Windows Desktop' exists (the deploy script uses that name)")


func test_main_reaches_the_host_only_through_the_gate() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/main.gd")
	assert_false(src.is_empty(), "main.gd readable")
	assert_true(src.contains("GodBuild.allowed()"), "main.gd creates the host behind GodBuild.allowed()")
	assert_true(src.contains("load(\"res://scripts/ui/god_host.gd\")"), "the host is loaded by path, not referenced by class name")
	for line: String in src.split("\n"):
		var code: String = line.get_slice("#", 0).strip_edges()  # comments may name the host
		if code.is_empty():
			continue
		for banned: String in ["GodHost", "GodMenu", "GodConsole", "GodSimCommands", "GodScript"]:
			assert_false(code.contains(banned), "main.gd code must not name %s outside the gate (stripping a release export would break the parse): %s" % [banned, code])


func test_typed_word_records_of_kind_dev_are_the_only_shipped_words() -> void:
	# kind "cheat" words are for T7.2 and stay in release; the shipped T1.1 file must contain dev words only.
	var tw: TypedWords = TypedWords.load_file()
	assert_eq(tw.errors.size(), 0, "shipped file valid: %s" % [tw.errors])
	for rec: Dictionary in tw.words:
		assert_eq(rec["kind"], "dev", "word %s is a dev word (needs the build gate)" % rec["word"])
