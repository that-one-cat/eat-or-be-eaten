extends TestCase
## Fish packs, data (ContentDB): map `spawners[].group` is optional; when present {min, max: integers 2..16 with
## max >= min, chance: 0..1, radius_m: > 0}, all required. A group on a spawner of a schooling or ambient species is
## a cross-reference error (that spawner spawns nothing). Errors read `<source>: <field.path>: <problem>`.

const MAP_SOURCE: String = "maps/reef.json"
const SCRATCH: String = "user://fish_groups_validation"
const GOOD: Dictionary = {"min": 2, "max": 4, "chance": 0.5, "radius_m": 3.0}


func _map_with_group(group: Variant) -> Dictionary:
	var map: Dictionary = ContentDB.load_from_dir("res://data").get_map(&"reef").duplicate(true)
	var rec: Dictionary = (map["spawners"] as Array)[0]
	rec["group"] = group
	return map


func _errors_for(group: Variant) -> PackedStringArray:
	return ContentDB.validate_record(&"map", _map_with_group(group), MAP_SOURCE)


func _mentions(errs: PackedStringArray, a: String) -> bool:
	for e: String in errs:
		if e.find(a) != -1:
			return true
	return false


func test_the_shipped_data_is_valid_with_groups() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_eq(db.errors.size(), 0, "shipped data loads clean: %s" % [db.errors])
	var groups: int = 0
	for s: Variant in (db.get_map(&"reef")["spawners"] as Array):
		if (s as Dictionary).has("group"):
			groups += 1
			var g: Dictionary = s["group"]
			assert_true(int(g["min"]) >= 2 and int(g["max"]) <= 4 and int(g["max"]) >= int(g["min"]), "%s group size %s..%s within the 2-4 design" % [s["species_id"], g["min"], g["max"]])
	assert_eq(groups, 5, "5 grouped spawner records (puffer x2, barracuda x2, grouper)")


func test_a_valid_group_block_has_no_errors() -> void:
	assert_eq(_errors_for(GOOD).size(), 0, "valid group: %s" % [_errors_for(GOOD)])
	var pair: Dictionary = GOOD.duplicate()
	pair["max"] = 2
	assert_eq(_errors_for(pair).size(), 0, "min == max is a fixed size")


func test_bad_group_blocks_are_rejected_with_the_field_path() -> void:
	var cases: Array = [
		["min", 1, "spawners[0].group.min"],
		["min", 2.5, "spawners[0].group.min"],
		["max", 17, "spawners[0].group.max"],
		["max", 1, "spawners[0].group.max"],
		["chance", 1.5, "spawners[0].group.chance"],
		["chance", -0.1, "spawners[0].group.chance"],
		["chance", "often", "spawners[0].group.chance"],
		["radius_m", 0.0, "spawners[0].group.radius_m"],
		["radius_m", -2.0, "spawners[0].group.radius_m"],
	]
	for c: Array in cases:
		var g: Dictionary = GOOD.duplicate()
		g[c[0]] = c[1]
		var errs: PackedStringArray = _errors_for(g)
		assert_true(_mentions(errs, MAP_SOURCE + ": " + str(c[2])), "%s = %s is rejected at %s: %s" % [c[0], c[1], c[2], errs])


func test_max_below_min_and_missing_keys_are_rejected() -> void:
	var g: Dictionary = GOOD.duplicate()
	g["min"] = 4
	g["max"] = 3
	assert_true(_mentions(_errors_for(g), "spawners[0].group.max: must be >= group.min"), "max < min: %s" % [_errors_for(g)])
	for key: String in ["min", "max", "chance", "radius_m"]:
		var miss: Dictionary = GOOD.duplicate()
		miss.erase(key)
		assert_true(_mentions(_errors_for(miss), "spawners[0].group.%s: is required" % key), "missing %s: %s" % [key, _errors_for(miss)])


func test_a_group_that_is_not_an_object_is_rejected() -> void:
	for bad: Variant in ["pack", 3, [2, 4]]:
		assert_true(_mentions(_errors_for(bad), "spawners[0].group: must be an object"), "group %s: %s" % [bad, _errors_for(bad)])


func test_a_group_on_a_schooling_species_spawner_is_rejected() -> void:
	_remove_dir(SCRATCH)
	_copy_dir("res://data", SCRATCH)
	var path: String = SCRATCH.path_join("maps/reef.json")
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	(map["spawners"] as Array).append({"species_id": "silver_schooling_fish", "zone_id": "shallows", "count": 4, "respawn_s": 30, "group": GOOD})
	var out: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(map, "\t"))
	out.close()
	var errs: PackedStringArray = ContentDB.load_from_dir(SCRATCH).errors
	_remove_dir(SCRATCH)
	var i: int = (map["spawners"] as Array).size() - 1
	assert_true(_mentions(errs, "maps/reef.json: spawners[%d].group: species 'silver_schooling_fish' is schooling" % i), "cross-reference error: %s" % [errs])
	assert_eq(errs.size(), 1, "and nothing else: %s" % [errs])


func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		if not sub.begins_with("."):
			_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "json":
			var o: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
			o.store_string(FileAccess.get_file_as_string(src.path_join(f)))
			o.close()


func _remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)
