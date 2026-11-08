class_name TestCase
extends RefCounted
## Base class for headless tests run by res://tests/run_tests.gd.
## Test files are res://tests/**/test_*.gd, `extends TestCase`, with methods `func test_<name>() -> void`.
## Assert helpers record a failure and return; they never abort the run.

## Failures recorded during the current test, as "<method>: <message>". Read and cleared by the runner.
var failures: Array[String] = []
## Name of the test method being run; set by the runner.
var current_test: String = ""


## Called before every test method. Override in test files.
func before_each() -> void:
	pass


## Called after every test method. Override in test files.
func after_each() -> void:
	pass


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		_record("expected true", msg)


func assert_false(cond: bool, msg: String = "") -> void:
	if cond:
		_record("expected false", msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	if not _equal(actual, expected):
		_record("expected %s, got %s" % [_str(expected), _str(actual)], msg)


func assert_ne(actual: Variant, expected: Variant, msg: String = "") -> void:
	if _equal(actual, expected):
		_record("expected value different from %s" % _str(expected), msg)


func assert_almost_eq(a: float, b: float, eps: float = 1e-5, msg: String = "") -> void:
	if absf(a - b) > eps:
		_record("expected %s ~= %s (eps %s)" % [a, b, eps], msg)


func assert_null(value: Variant, msg: String = "") -> void:
	if value != null:
		_record("expected null, got %s" % _str(value), msg)


func assert_not_null(value: Variant, msg: String = "") -> void:
	if value == null:
		_record("expected non-null value", msg)


## Works for Array, Dictionary (key), String (substring) and packed arrays.
func assert_has(container: Variant, item: Variant, msg: String = "") -> void:
	var t: int = typeof(container)
	var supported: bool = t == TYPE_ARRAY or t == TYPE_DICTIONARY or t == TYPE_STRING or (t >= TYPE_PACKED_BYTE_ARRAY and t <= TYPE_PACKED_VECTOR4_ARRAY)
	if not supported:
		_record("assert_has: unsupported container type %s" % type_string(t), msg)
		return
	if t == TYPE_STRING and typeof(item) != TYPE_STRING:
		_record("assert_has: String container needs a String item, got %s" % type_string(typeof(item)), msg)
		return
	if not (item in container):
		_record("expected %s to contain %s" % [_str(container), _str(item)], msg)


func fail(msg: String) -> void:
	_record("fail", msg)


## Type-safe equality: GDScript `==` raises a script error on mismatched types (e.g. String vs int).
func _equal(a: Variant, b: Variant) -> bool:
	var ta: int = typeof(a)
	var tb: int = typeof(b)
	var numeric_a: bool = ta == TYPE_INT or ta == TYPE_FLOAT
	var numeric_b: bool = tb == TYPE_INT or tb == TYPE_FLOAT
	if numeric_a and numeric_b:
		return a == b
	if (ta == TYPE_STRING or ta == TYPE_STRING_NAME) and (tb == TYPE_STRING or tb == TYPE_STRING_NAME):
		return String(a) == String(b)
	if ta != tb:
		return false
	return a == b


func _str(value: Variant) -> String:
	if typeof(value) == TYPE_STRING:
		return "\"%s\"" % value
	return var_to_str(value)


func _record(what: String, msg: String) -> void:
	var text: String = what if msg.is_empty() else "%s (%s)" % [msg, what]
	failures.append("%s: %s" % [current_test, text])
