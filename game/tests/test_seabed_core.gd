extends TestCase
## SeabedField: zone depths from GAME_DESIGN section 9, determinism, normals, obstacles, resolve(), and
## ContentDB validation of the new map / band / boost / rules fields.

static var _db: ContentDB = null


func _content() -> ContentDB:
	if _db == null:
		_db = ContentDB.load_from_dir("res://data")
	return _db


func _map() -> Dictionary:
	return _content().get_map(&"reef")


func _field() -> SeabedField:
	return SeabedField.from_map(_map())


## Seabed depth (positive) range over a strip of x at fixed z.
func _depth_range(f: SeabedField, z: float) -> Vector2:
	var lo: float = INF
	var hi: float = -INF
	for i in 61:
		var d: float = -f.height_at(-300.0 + i * 10.0, z)
		lo = minf(lo, d)
		hi = maxf(hi, d)
	return Vector2(lo, hi)


func test_height_is_inside_the_map_depth_everywhere() -> void:
	var f := _field()
	var depth_m: float = float(_map()["depth_m"])
	var min_depth: float = float(_map()["seabed"]["min_depth_m"])
	for i in 61:
		for j in 61:
			var h: float = f.height_at(-300.0 + i * 10.0, -300.0 + j * 10.0)
			assert_true(is_finite(h), "finite")
			assert_true(h <= -min_depth + 1e-6 and h >= -depth_m - 1e-6, "height %f out of [-%f, -%f]" % [h, depth_m, min_depth])


func test_zone_depths_match_game_design() -> void:
	var f := _field()
	var shallows := _depth_range(f, -250.0)
	assert_true(shallows.x > 0.0 and shallows.y <= 20.0, "shallows reef 0-20 m, got %s" % shallows)
	var kelp := _depth_range(f, -90.0)
	assert_true(kelp.x >= 10.0 and kelp.y <= 40.0, "kelp 10-40 m, got %s" % kelp)
	var arches := _depth_range(f, 40.0)
	assert_true(arches.x >= 20.0 and arches.y <= 50.0, "arches 20-50 m, got %s" % arches)
	var cliff_top := _depth_range(f, 120.0)
	assert_true(cliff_top.x >= 45.0 and cliff_top.y <= 55.0, "cliff edge around 50 m, got %s" % cliff_top)
	var abyss := _depth_range(f, 250.0)
	assert_true(abyss.x >= 75.0 and abyss.y <= 80.0, "abyss floor at 80 m, got %s" % abyss)
	var boat: float = -f.height_at(55.0, 55.0)
	assert_true(boat > 40.0 and boat < 50.0, "boat site around 45 m, got %f" % boat)


func test_cliff_is_steep() -> void:
	var f := _field()
	var steepest: float = 1.0
	for i in 61:
		for k in 9:
			steepest = minf(steepest, f.normal_at(-300.0 + i * 10.0, 126.0 + k * 3.0).y)
	assert_true(steepest < 0.6, "cliff drop must be steep (min normal.y %f)" % steepest)


func test_deterministic_and_seeded() -> void:
	var a := _field()
	var b := _field()
	var other: Dictionary = _map().duplicate(true)
	other["seabed"]["seed"] = int(other["seabed"]["seed"]) + 1
	var c := SeabedField.from_map(other)
	var differs: bool = false
	for i in 50:
		var x: float = -290.0 + i * 11.3
		var z: float = -280.0 + i * 7.9
		assert_eq(a.height_at(x, z), b.height_at(x, z), "same data -> same height")
		if absf(a.height_at(x, z) - c.height_at(x, z)) > 1e-3:
			differs = true
	assert_true(differs, "the seed changes the noise")


func test_normal_is_unit_and_up_on_the_shelf() -> void:
	var f := _field()
	var n: Vector3 = f.normal_at(0.0, -250.0)
	assert_almost_eq(n.length(), 1.0, 1e-5, "unit")
	assert_true(n.y > 0.8, "shelf is gentle: %s" % n)


func test_obstacles_from_map_data() -> void:
	var obs: Array[Dictionary] = _field().obstacles()
	assert_eq(obs.size(), (_map()["obstacles"] as Array).size(), "one primitive per data entry")
	var tags: Dictionary = {}
	var kinds: Dictionary = {}
	for o in obs:
		tags[o["tag"]] = true
		kinds[o["kind"]] = true
	for t in ["arch", "boat", "rock"]:
		assert_has(tags, t, "tag %s present" % t)
	for k in ["sphere", "capsule", "box"]:
		assert_has(kinds, k, "kind %s present" % k)


func test_resolve_lifts_out_of_the_seabed() -> void:
	var f := _field()
	var h: float = f.height_at(0.0, -200.0)
	var p: Vector3 = f.resolve(Vector3(0.0, h - 2.0, -200.0), 0.1)
	assert_true(p.y >= f.height_at(p.x, p.z), "centre above the seabed: %s" % p)
	var free := Vector3(0.0, h + 3.0, -200.0)
	assert_eq(f.resolve(free, 0.1), free, "a sphere in open water is untouched")


func test_resolve_pushes_out_of_each_primitive() -> void:
	var map := {"depth_m": 80, "obstacles": [
		{"id": "s", "kind": "sphere", "center": [0, -40, 0], "radius": 3},
		{"id": "c", "kind": "capsule", "a": [20, -60, 0], "b": [20, -20, 0], "radius": 2},
		{"id": "b", "kind": "box", "center": [-20, -40, 0], "size": [4, 4, 4]},
	]}
	var f := SeabedField.from_map(map)
	var r: float = 0.5
	var ps: Vector3 = f.resolve(Vector3(1, -40, 0), r)
	assert_almost_eq(ps.distance_to(Vector3(0, -40, 0)), 3.0 + r, 1e-4, "sphere: on the surface + radius")
	var pc: Vector3 = f.resolve(Vector3(20.5, -40, 0), r)
	assert_almost_eq(Vector2(pc.x - 20.0, pc.z).length(), 2.0 + r, 1e-4, "capsule: pushed radially")
	var pb: Vector3 = f.resolve(Vector3(-21.5, -40, 0), r)
	assert_almost_eq(pb.x, -22.0 - r, 1e-4, "box: centre inside leaves through the nearest face")
	var pb2: Vector3 = f.resolve(Vector3(-17.8, -40, 0), r)
	assert_almost_eq(pb2.x, -18.0 + r, 1e-4, "box: touching from outside")


func test_fish_fits_under_an_arch() -> void:
	var f := _field()
	var left: Dictionary = {}
	var top: Dictionary = {}
	for o in f.obstacles():
		if o["id"] == "arch_a_left":
			left = o
		elif o["id"] == "arch_a_top":
			top = o
	assert_false(left.is_empty() or top.is_empty(), "arch_a in data")
	var mid_x: float = ((top["a"] as Vector3).x + (top["b"] as Vector3).x) * 0.5
	var z: float = (top["a"] as Vector3).z
	var floor_y: float = f.height_at(mid_x, z)
	var under_y: float = ((top["a"] as Vector3).y - float(top["radius"]) + floor_y) * 0.5
	var biggest_radius: float = 3.5 * float(_content().get_band(4)["collision_radius_mult"])
	var p := Vector3(mid_x, under_y, z)
	assert_eq(f.resolve(p, biggest_radius), p, "a band-4 fish passes under the arch untouched")


func test_partial_map_does_not_crash() -> void:
	var f := SeabedField.from_map({"depth_m": 30})
	assert_almost_eq(f.height_at(5.0, 5.0), -30.0, 1e-6, "flat floor at -depth_m")
	assert_eq(f.obstacles().size(), 0, "no obstacles")
	assert_eq(SeabedField.from_map({}).height_at(1.0, 2.0), 0.0, "empty record -> floor at 0, no crash")


# ---- validation of the S2 data ----

func _map_errors(mutate: Callable) -> PackedStringArray:
	var rec: Dictionary = _map().duplicate(true)
	mutate.call(rec)
	return ContentDB.validate_record(&"map", rec, "maps/reef.json")


func _expect(errs: PackedStringArray, needle: String) -> void:
	var hit: bool = false
	for e in errs:
		if e.begins_with("maps/reef.json: ") or e.begins_with("size_bands/") or e.begins_with("abilities/") or e.begins_with("rules/"):
			if e.find(needle) != -1:
				hit = true
	assert_true(hit, "expected an error naming %s, got: %s" % [needle, "; ".join(errs)])


func test_real_s2_data_validates() -> void:
	assert_true(_content().is_valid(), "; ".join(_content().errors))


func test_map_requires_seabed_bounds_and_obstacles() -> void:
	_expect(_map_errors(func(r: Dictionary) -> void: r.erase("seabed")), "seabed: is required")
	_expect(_map_errors(func(r: Dictionary) -> void: r.erase("bounds")), "bounds: is required")
	_expect(_map_errors(func(r: Dictionary) -> void: r.erase("obstacles")), "obstacles: is required")


func test_map_seabed_and_bounds_values_are_checked() -> void:
	_expect(_map_errors(func(r: Dictionary) -> void: r["seabed"]["profile"][1][0] = -400), "seabed.profile[1][0]: must be > the previous")
	_expect(_map_errors(func(r: Dictionary) -> void: r["seabed"]["profile"][0][1] = 120), "seabed.profile[0][1]")
	_expect(_map_errors(func(r: Dictionary) -> void: r["seabed"]["abyss_floor_depth_m"] = 95), "seabed.abyss_floor_depth_m")
	_expect(_map_errors(func(r: Dictionary) -> void: r["seabed"]["noise"]["cell_m"] = 0), "seabed.noise.cell_m")
	_expect(_map_errors(func(r: Dictionary) -> void: r["bounds"]["soft_margin_m"] = 400), "bounds.soft_margin_m: must be < size_m / 2")
	_expect(_map_errors(func(r: Dictionary) -> void: r["bounds"]["current_mps"] = -1), "bounds.current_mps")


func test_obstacle_records_are_checked() -> void:
	_expect(_map_errors(func(r: Dictionary) -> void: r["obstacles"][0]["kind"] = "torus"), "obstacles[0].kind")
	_expect(_map_errors(func(r: Dictionary) -> void: r["obstacles"][0]["radius"] = 0), "obstacles[0].radius")
	_expect(_map_errors(func(r: Dictionary) -> void: r["obstacles"][1]["id"] = r["obstacles"][0]["id"]), "obstacles[1].id: duplicate")
	var box_index: int = -1
	for i in (_map()["obstacles"] as Array).size():
		if _map()["obstacles"][i]["kind"] == "box":
			box_index = i
			break
	var path: String = "obstacles[%d].size" % box_index
	_expect(_map_errors(func(r: Dictionary) -> void: r["obstacles"][box_index]["size"] = [1, 0, 1]), path)


func test_band_boost_and_rules_fields_are_checked() -> void:
	for field in ["accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2", "collision_radius_mult"]:
		var band: Dictionary = _content().get_band(2).duplicate(true)
		band.erase(field)
		_expect(ContentDB.validate_record(&"size_band", band, "size_bands/size_bands.json"), field)
	var boost: Dictionary = _content().get_ability(&"boost").duplicate(true)
	boost["stamina_drain_per_s"] = 0
	_expect(ContentDB.validate_record(&"ability", boost, "abilities/boost.json"), "stamina_drain_per_s")
	for bad: Variant in [-0.1, 1.5, "0.2"]:
		var b2: Dictionary = _content().get_ability(&"boost").duplicate(true)
		b2["restart_min_stamina_frac"] = bad
		_expect(ContentDB.validate_record(&"ability", b2, "abilities/boost.json"), "restart_min_stamina_frac")
	var b3: Dictionary = _content().get_ability(&"boost").duplicate(true)
	b3.erase("restart_min_stamina_frac")
	_expect(ContentDB.validate_record(&"ability", b3, "abilities/boost.json"), "restart_min_stamina_frac")
	var rules: Dictionary = _content().rules().duplicate(true)
	rules["swim"]["max_pitch_deg"] = 90
	_expect(ContentDB.validate_record(&"rules", rules, "rules/core.json"), "swim.max_pitch_deg")
