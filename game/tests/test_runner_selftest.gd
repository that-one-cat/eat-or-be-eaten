extends TestCase
## Self-test of the TestCase assert helpers (passing cases only).

var _before_calls: int = 0


func before_each() -> void:
	_before_calls += 1


func test_bool_asserts() -> void:
	assert_true(true)
	assert_false(false)


func test_equality_asserts() -> void:
	assert_eq(2 + 2, 4)
	assert_eq(1, 1.0, "int and float compare numerically")
	assert_eq(&"id", "id", "StringName and String compare as text")
	assert_eq([1, 2, 3], [1, 2, 3])
	assert_eq({"a": 1}, {"a": 1})
	assert_ne(1, 2)
	assert_ne("1", 1, "mismatched types are not equal and do not raise")


func test_almost_eq() -> void:
	assert_almost_eq(0.1 + 0.2, 0.3)
	assert_almost_eq(1.0, 1.05, 0.1)


func test_null_asserts() -> void:
	assert_null(null)
	assert_not_null(RefCounted.new())
	assert_not_null(0, "zero is not null")


func test_has() -> void:
	assert_has([1, 2, 3], 2)
	assert_has({"key": 1}, "key")
	assert_has("sharkbait", "bait")
	assert_has(PackedInt32Array([4, 5]), 5)


func test_before_each_runs() -> void:
	assert_true(_before_calls >= 1)


func test_await_supported() -> void:
	await Engine.get_main_loop().process_frame
	assert_true(true)
