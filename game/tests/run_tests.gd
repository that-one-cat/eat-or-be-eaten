extends SceneTree
## Headless test runner (no addons).
## Usage: godot --headless --path game --script res://tests/run_tests.gd [-- --filter=<substring>]
## Discovers res://tests/**/test_*.gd (skips res://tests/fixtures/ and the TestCase base), runs every
## `test_*` method of each script, prints one line per failure and a summary, exits 0 if all pass, 1 otherwise.
## The filter matches against "<file>::<method>". A script that fails to load counts as a failure.
## Script errors raised inside a test method (null access, bad call) are captured and fail that test.

const TEST_ROOT: String = "res://tests"
const FIXTURES_DIR: String = "res://tests/fixtures"
const BASE_SCRIPT_PATH: String = "res://tests/test_case.gd"
const TestCaseScript: GDScript = preload("res://tests/test_case.gd")


## Collects script errors (not push_error/push_warning) so a test that crashes mid-way is reported as failed.
class ScriptErrorCatcher extends Logger:
	var errors: Array[String] = []
	var _mutex: Mutex = Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		var text: String = rationale if not rationale.is_empty() else code
		_mutex.lock()
		errors.append("script error: %s (%s:%d in %s)" % [text, file, line, function])
		_mutex.unlock()

	func take() -> Array[String]:
		_mutex.lock()
		var out: Array[String] = errors.duplicate()
		errors.clear()
		_mutex.unlock()
		return out


var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var filter: String = _parse_filter()
	var files: Array[String] = []
	_collect(TEST_ROOT, files)
	files.sort()
	if files.is_empty():
		print("WARNING: no test files found under %s/" % TEST_ROOT)
		print("TESTS: 0 passed, 0 failed, 0 files")
		quit(0)
		return

	var catcher := ScriptErrorCatcher.new()
	OS.add_logger(catcher)
	var file_count: int = 0
	for path: String in files:
		if await _run_file(path, filter, catcher):
			file_count += 1
	OS.remove_logger(catcher)

	if not filter.is_empty() and _passed + _failed == 0:
		print("WARNING: filter '%s' matched no tests" % filter)
	print("TESTS: %d passed, %d failed, %d files" % [_passed, _failed, file_count])
	quit(0 if _failed == 0 else 1)


## Runs all matching tests in one file. Returns true if the file contributed at least one result.
func _run_file(path: String, filter: String, catcher: ScriptErrorCatcher) -> bool:
	var file_name: String = path.trim_prefix(TEST_ROOT + "/")
	var script: GDScript = load(path) as GDScript
	catcher.take()  # Load-time errors are reported via the load failure below.
	if script == null or not script.can_instantiate():
		if filter.is_empty() or file_name.contains(filter):
			_report(file_name, "<load>", "script failed to load or parse")
			return true
		return false

	var methods: Array[String] = []
	for m: Dictionary in script.get_script_method_list():
		var method_name: String = m["name"]
		if method_name.begins_with("test_") and not methods.has(method_name):
			if filter.is_empty() or ("%s::%s" % [file_name, method_name]).contains(filter):
				methods.append(method_name)
	if methods.is_empty():
		return false

	var instance: Object = script.new()
	if not (instance is TestCaseScript):
		_report(file_name, "<load>", "script does not extend TestCase")
		return true
	var test_case: TestCase = instance as TestCase

	for method_name: String in methods:
		test_case.current_test = method_name
		test_case.failures.clear()
		test_case.before_each()
		await test_case.call(method_name)
		test_case.after_each()
		var problems: Array[String] = test_case.failures.duplicate()
		for err: String in catcher.take():
			problems.append("%s: %s" % [method_name, err])
		if problems.is_empty():
			_passed += 1
		else:
			_failed += 1
			for p: String in problems:
				print("FAIL %s::%s" % [file_name, p])
	return true


func _report(file_name: String, method_name: String, message: String) -> void:
	_failed += 1
	print("FAIL %s::%s: %s" % [file_name, method_name, message])


func _collect(dir_path: String, out: Array[String]) -> void:
	if dir_path == FIXTURES_DIR:
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		if not sub.begins_with("."):
			_collect(dir_path.path_join(sub), out)
	for f: String in dir.get_files():
		var full: String = dir_path.path_join(f)
		if f.begins_with("test_") and f.get_extension() == "gd" and full != BASE_SCRIPT_PATH:
			out.append(full)


func _parse_filter() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			return arg.trim_prefix("--filter=")
	return ""
