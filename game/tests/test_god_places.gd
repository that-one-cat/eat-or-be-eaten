extends TestCase
## T1.2 named teleport places (`places` in data/maps/reef.json) and their ContentDB validation (positive on the shipped
## data, negative on a throw-away copy of res://data with one defect each).

const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const REQUIRED: PackedStringArray = ["spawn_0", "spawn_1", "spawn_2", "shallows", "kelp", "arches", "cave", "boat", "cliff", "abyss", "boss"]


func after_each() -> void:
	G.cleanup_temp()


func _places() -> Array:
	return S3.content().get_map(&"reef").get("places", [])


func _place(id: String) -> Dictionary:
	for p: Variant in _places():
		if (p as Dictionary).get("id") == id:
			return p
	return {}


func _vec(p: Dictionary) -> Vector3:
	var a: Array = p["pos"]
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


# ---------------------------------------------------------------- shipped data

func test_shipped_content_is_valid_with_places() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_true(db.is_valid(), "shipped data valid: %s" % [db.errors])
	assert_eq(ContentDB.validate_record(&"map", db.get_map(&"reef"), "maps/reef.json").size(), 0, "map record has no errors")


func test_all_required_place_ids_exist_once() -> void:
	var ids: Array[String] = []
	for p: Variant in _places():
		ids.append(String((p as Dictionary).get("id", "")))
	for id: String in REQUIRED:
		assert_eq(ids.count(id), 1, "place '%s' exactly once" % id)


func test_spawn_places_equal_the_player_spawns() -> void:
	var spawns: Array = S3.content().get_map(&"reef")["player_spawns"]
	for i: int in 3:
		var p: Dictionary = _place("spawn_%d" % i)
		assert_false(p.is_empty(), "spawn_%d present" % i)
		if not p.is_empty():
			assert_true(_vec(p).is_equal_approx(Vector3(float(spawns[i][0]), float(spawns[i][1]), float(spawns[i][2]))), "spawn_%d == player_spawns[%d]" % [i, i])


func test_every_place_is_inside_the_map_box() -> void:
	var map: Dictionary = S3.content().get_map(&"reef")
	var half: float = float(map["size_m"]) * 0.5
	var depth: float = float(map["depth_m"])
	for p: Variant in _places():
		var v: Vector3 = _vec(p)
		var id: String = str((p as Dictionary)["id"])
		assert_true(absf(v.x) <= half and absf(v.z) <= half, "%s inside the map footprint" % id)
		assert_true(v.y <= 0.0 and v.y >= -depth, "%s between the surface and the floor" % id)


func test_every_place_is_free_water_for_the_player() -> void:
	var rg: Dictionary = G.rig(3)
	var w: SimWorld = rg["w"]
	var e: SimEntity = rg["p"]
	w._configure()
	for p: Variant in _places():
		var v: Vector3 = _vec(p)
		var pushed: float = w._constrain(e, v).distance_to(v)
		assert_true(pushed < 0.5, "%s: _constrain moves the point by %.2f m (must be < 0.5: not inside a rock / the seabed)" % [(p as Dictionary)["id"], pushed])


func test_places_listing_helper_reads_the_map() -> void:
	var w: SimWorld = G.rig(1)["w"]
	var listed: Array[Dictionary] = GodSimCommands.places(w)
	assert_eq(listed.size(), _places().size(), "every valid record is listed")
	for id: String in REQUIRED:
		var hit: bool = false
		for d: Dictionary in listed:
			hit = hit or d["id"] == id
		assert_true(hit, "listing contains %s" % id)


func test_places_helper_skips_malformed_records_without_crashing() -> void:
	var w: SimWorld = G.rig(1)["w"]
	w.map["places"] = [{"id": "ok", "pos": [1, -5, 2]}, {"id": 5, "pos": [0, 0, 0]}, {"id": "short", "pos": [1, 2]}, "junk", {"pos": [0, 0, 0]}]
	var listed: Array[Dictionary] = GodSimCommands.places(w)
	assert_eq(listed.size(), 1, "only the well-formed record survives")
	assert_eq(listed[0]["name"], "ok", "name falls back to the id")
	w.map.erase("places")
	assert_eq(GodSimCommands.places(w).size(), 0, "a map without places gives an empty list")


# ---------------------------------------------------------------- ContentDB negative cases

func _map_with(edit: Callable) -> ContentDB:
	return G.db_with(func(root: String) -> void:
		var path: String = root.path_join("maps/reef.json")
		var data: Dictionary = G.read_json(path)
		edit.call(data)
		G.write_json(path, data))


func test_negative_duplicate_id() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "cave", "pos": [0, -10, 0]}))
	assert_false(db.is_valid(), "duplicate id invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "].id", "duplicate"]), "path-qualified duplicate error: %s" % [db.errors])


func test_negative_missing_id() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"pos": [0, -10, 0]}))
	assert_false(db.is_valid(), "missing id invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "id"]), "error names places[i].id: %s" % [db.errors])


func test_negative_non_snake_case_id() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "Bad Id", "pos": [0, -10, 0]}))
	assert_false(db.is_valid(), "bad id invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "id", "snake_case"]), "snake_case error: %s" % [db.errors])


func test_negative_bad_vec3() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "flat", "pos": [1, 2]}))
	assert_false(db.is_valid(), "2-component pos invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "pos"]), "error names pos: %s" % [db.errors])
	var db2: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "text", "pos": ["a", "b", "c"]}))
	assert_false(db2.is_valid(), "non-numeric pos invalidates")


func test_negative_missing_pos() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "nopos"}))
	assert_false(db.is_valid(), "missing pos invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "pos"]), "error names pos: %s" % [db.errors])


func test_negative_outside_the_map() -> void:
	var cases: Array[Array] = [[1000, -10, 0], [0, -10, -1000], [0, 5, 0], [0, -500, 0]]
	for c: Array in cases:
		var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "far", "pos": c}))
		assert_false(db.is_valid(), "pos %s is outside the map box" % [c])
		assert_true(G.errors_mention(db, ["reef.json", "places[", "pos", "inside the map box"]), "box error for %s: %s" % [c, db.errors])


func test_negative_far_outside_the_origin_range() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append({"id": "far", "pos": [9999, -10, 0]}))
	assert_false(db.is_valid(), "beyond +-4 km invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "pos"]), "path-qualified: %s" % [db.errors])


func test_negative_non_object_record_and_non_array_places() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"].append("cave"))
	assert_false(db.is_valid(), "string record invalidates")
	assert_true(G.errors_mention(db, ["reef.json", "places[", "must be an object"]), "object error: %s" % [db.errors])
	var db2: ContentDB = _map_with(func(d: Dictionary) -> void: d["places"] = {"id": "x"})
	assert_false(db2.is_valid(), "places must be an array")


func test_places_are_optional() -> void:
	var db: ContentDB = _map_with(func(d: Dictionary) -> void: d.erase("places"))
	assert_true(db.is_valid(), "a map without places is valid: %s" % [db.errors])
