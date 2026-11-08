extends TestCase
## fix-rock-collision: the rounded oriented box primitive (`obb`) of SeabedField, the cell-indexed narrow phase
## (resolve() vs resolve_reference()), obstacle_clear() (camera query), the `baked` flag of from_map() and the
## ContentDB schema of obb records and proxies files.

const S5 := preload("res://tests/s5_support.gd")

const FLOOR_DEPTH_M: float = 100.0


# Flat-floored test map (seabed at y = -FLOOR_DEPTH_M) with the given obstacle records.
func _map(obstacles: Array, size_m: float = 400.0) -> Dictionary:
	return {
		"id": "obb_test", "size_m": size_m, "depth_m": FLOOR_DEPTH_M + 20.0,
		"seabed": {"seed": 3, "min_depth_m": 1.0, "profile": [[0.0, FLOOR_DEPTH_M]], "noise": {"amplitude_m": 0.0, "cell_m": 10.0}},
		"obstacles": obstacles,
	}


func _obb(id: String, c: Vector3, size: Vector3, rot: Quaternion, rnd: float) -> Dictionary:
	return {"id": id, "tag": "rock", "kind": "obb", "center": [c.x, c.y, c.z], "size": [size.x, size.y, size.z],
		"rot": [rot.x, rot.y, rot.z, rot.w], "round": rnd}


func _tilted() -> Quaternion:
	return Quaternion(Vector3(0.3, 1.0, -0.2).normalized(), 0.9)


func _rand_dir(rng: RandomNumberGenerator) -> Vector3:
	return Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()


func test_obb_push_ends_exactly_on_the_rounded_surface() -> void:
	var c := Vector3(10.0, -50.0, -20.0)
	var rec: Dictionary = _obb("r", c, Vector3(6.0, 2.0, 4.0), _tilted(), 0.7)
	var f := SeabedField.from_map(_map([rec]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var checked: int = 0
	for i in 2000:
		var radius: float = rng.randf_range(0.03, 2.5)
		var p: Vector3 = c + _rand_dir(rng) * rng.randf_range(0.0, 6.0)
		var sd: float = S5.obstacle_sdf(rec, p)
		if sd <= 1e-3 or sd >= radius:
			continue  # only starts outside the solid but inside the push reach (face, edge and corner regions)
		checked += 1
		var q: Vector3 = f.resolve(p, radius)
		assert_almost_eq(S5.obstacle_sdf(rec, q), radius, 2e-5, "start %s r %s: pushed onto the surface + radius (float32 world coordinates)" % [p, radius])
	assert_true(checked > 300, "enough face/edge/corner starts were checked (%d)" % checked)


func test_obb_centre_inside_exits_above_the_seabed_and_outside() -> void:
	# a slab resting on the floor, slightly yawed and tilted: inside starts must never exit downwards
	var c := Vector3(0.0, -FLOOR_DEPTH_M + 0.6, 0.0)
	var rec: Dictionary = _obb("slab", c, Vector3(8.0, 2.0, 5.0), Quaternion(Vector3(0.1, 1.0, 0.05).normalized(), 0.4), 0.5)
	var f := SeabedField.from_map(_map([rec]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 400:
		var radius: float = rng.randf_range(0.03, 1.0)
		var p: Vector3 = c + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-0.4, 0.4), rng.randf_range(-1.8, 1.8))
		if S5.obstacle_sdf(rec, p) >= 0.0:
			continue
		var q: Vector3 = f.resolve(p, radius)
		assert_true(S5.obstacle_sdf(rec, q) >= radius - 1e-4, "inside start %s r %s: outside after resolve (sdf %s)" % [p, radius, S5.obstacle_sdf(rec, q)])
		assert_true(q.y - radius >= -FLOOR_DEPTH_M - 1e-4, "inside start %s: exit is not under the seabed (y %s)" % [p, q.y])


func test_obb_resolve_is_idempotent() -> void:
	var c := Vector3(-40.0, -60.0, 30.0)
	var rec: Dictionary = _obb("r", c, Vector3(5.0, 3.0, 5.0), _tilted(), 1.0)
	var f := SeabedField.from_map(_map([rec]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	for i in 500:
		var radius: float = rng.randf_range(0.03, 2.5)
		var p: Vector3 = c + _rand_dir(rng) * rng.randf_range(0.0, 5.0)
		var q: Vector3 = f.resolve(p, radius)
		assert_true(f.resolve(q, radius).distance_to(q) < 1e-5, "resolve(resolve(%s)) == resolve(%s)" % [p, p])


func test_obb_with_identity_rotation_and_no_round_equals_the_box() -> void:
	var c := Vector3(5.0, -70.0, 5.0)
	var size := Vector3(4.0, 3.0, 6.0)
	var box: Dictionary = {"id": "b", "tag": "rock", "kind": "box", "center": [c.x, c.y, c.z], "size": [size.x, size.y, size.z]}
	var fb := SeabedField.from_map(_map([box]))
	var fo := SeabedField.from_map(_map([_obb("o", c, size, Quaternion.IDENTITY, 0.0)]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	for i in 1000:
		var radius: float = rng.randf_range(0.03, 2.5)
		var p: Vector3 = c + Vector3(rng.randf_range(-5.0, 5.0), rng.randf_range(-4.0, 4.0), rng.randf_range(-6.0, 6.0))
		var a: Vector3 = fb.resolve(p, radius)
		var b: Vector3 = fo.resolve(p, radius)
		assert_true(a.distance_to(b) < 1e-5, "start %s r %s: box %s vs obb %s" % [p, radius, a, b])


func test_cell_lists_reproduce_the_full_pass_on_dense_random_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var recs: Array = []
	for i in 400:
		var c := Vector3(rng.randf_range(-180.0, 180.0), -FLOOR_DEPTH_M + rng.randf_range(0.0, 3.0), rng.randf_range(-180.0, 180.0))
		var size := Vector3(rng.randf_range(1.0, 12.0), rng.randf_range(0.6, 6.0), rng.randf_range(1.0, 9.0))
		var rot := Quaternion(_rand_dir(rng), rng.randf_range(0.0, PI))
		recs.append(_obb("o%d" % i, c, size, rot, rng.randf_range(0.0, 0.5) * minf(size.x, minf(size.y, size.z))))
	for i in 60:
		var c2 := Vector3(rng.randf_range(-180.0, 180.0), -FLOOR_DEPTH_M + 1.0, rng.randf_range(-180.0, 180.0))
		recs.append({"id": "s%d" % i, "tag": "rock", "kind": "sphere", "center": [c2.x, c2.y, c2.z], "radius": rng.randf_range(0.5, 4.0)})
	var f := SeabedField.from_map(_map(recs))
	var outside: int = 0
	for i in 6000:
		var radius: float = rng.randf_range(0.025, 4.0)
		var p := Vector3(rng.randf_range(-200.0, 200.0), -FLOOR_DEPTH_M + rng.randf_range(0.0, 12.0), rng.randf_range(-200.0, 200.0))
		var free: bool = true
		for o: Dictionary in recs:
			if S5.obstacle_sdf(o, p) < 0.0:
				free = false
				break
		var q: Vector3 = f.resolve(p, radius)
		if free:
			outside += 1
			var ref: Vector3 = f.resolve_reference(p, radius)
			if q.distance_to(ref) > 1e-9:
				fail("start %s r %s: cell-indexed %s != reference %s" % [p, radius, q, ref])
				return
	assert_true(outside > 3000, "enough outside starts (%d)" % outside)


func test_obstacle_clear_matches_the_signed_distance_of_every_obstacle() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var recs: Array = []
	for i in 120:
		var c := Vector3(rng.randf_range(-150.0, 150.0), -FLOOR_DEPTH_M + 2.0, rng.randf_range(-150.0, 150.0))
		recs.append(_obb("o%d" % i, c, Vector3(4.0, 3.0, 2.0), Quaternion(_rand_dir(rng), 1.0), 0.4))
	recs.append({"id": "cap", "tag": "arch", "kind": "capsule", "a": [0, -95, 0], "b": [10, -90, 0], "radius": 2.0})
	recs.append({"id": "box", "tag": "boat", "kind": "box", "center": [20, -96, 20], "size": [3, 4, 9]})
	var f := SeabedField.from_map(_map(recs))
	for i in 3000:
		var p := Vector3(rng.randf_range(-160.0, 160.0), -FLOOR_DEPTH_M + rng.randf_range(0.0, 10.0), rng.randf_range(-160.0, 160.0))
		var clearance: float = rng.randf_range(0.3, 6.0)
		var want: bool = true
		for o: Dictionary in recs:
			if S5.obstacle_sdf(o, p) < clearance:
				want = false
				break
		assert_eq(f.obstacle_clear(p, clearance), want, "obstacle_clear(%s, %s)" % [p, clearance])


func test_cell_index_matches_the_full_pass_on_the_authored_reef() -> void:
	var f := SeabedField.from_map(S5.map_record())
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	for i in 4000:
		var radius: float = rng.randf_range(0.025, 4.0)
		var x: float = rng.randf_range(-300.0, 300.0)
		var z: float = rng.randf_range(-300.0, 300.0)
		var p := Vector3(x, f.height_at(x, z) + rng.randf_range(0.0, 20.0), z)
		var a: Vector3 = f.resolve(p, radius)
		var b: Vector3 = f.resolve_reference(p, radius)
		if a.distance_to(b) > 1e-6:
			fail("start %s r %s: resolve %s != reference %s" % [p, radius, a, b])
			return


func test_baked_records_are_flagged_and_follow_the_map_obstacles() -> void:
	var own: Dictionary = {"id": "own", "tag": "rock", "kind": "sphere", "center": [0, -95, 0], "radius": 2.0}
	var baked: Array = [_obb("baked_1", Vector3(30, -98, 0), Vector3(3, 2, 3), Quaternion.IDENTITY, 0.5)]
	var f := SeabedField.from_map(_map([own]), baked)
	var obs: Array[Dictionary] = f.obstacles()
	assert_eq(obs.size(), 2, "map obstacle + baked record")
	assert_eq(obs[0]["id"], "own", "map obstacles first")
	assert_false(bool(obs[0]["baked"]), "map obstacle is not baked")
	assert_eq(obs[1]["id"], "baked_1", "baked record second")
	assert_true(bool(obs[1]["baked"]), "baked record is flagged")
	assert_true(obs[1]["rot"] is Quaternion and obs[1]["center"] is Vector3, "obb record holds typed values")
	var p := Vector3(30, -96.5, 0)
	assert_true(S5.obstacle_sdf(baked[0], f.resolve(p, 0.3)) >= 0.3 - 1e-6, "a baked obb collides")
	assert_eq(SeabedField.from_map(_map([own])).obstacles().size(), 1, "without baked records only the map's own")


func test_obb_records_are_checked_by_content_db() -> void:
	var good: Dictionary = _obb("g", Vector3(0, -10, 0), Vector3(2, 1, 3), _tilted(), 0.4)
	var no_rot: Dictionary = {"id": "n", "kind": "obb", "center": [0, -10, 0], "size": [1, 1, 1]}
	var cases: Dictionary = {
		"round": _with(good, "round", 0.6),
		"size": _with(good, "size", [2, 0, 3]),
		"rot": _with(good, "rot", [0, 0, 1]),
		"rot ": _with(good, "rot", [0, 0, 0, 2]),
		"rot[1]": _with(good, "rot", [0, "x", 0, 1]),
		"round ": _with(good, "round", -0.1),
		"center": _with(good, "center", [0, 0]),
	}
	var ok: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [good, no_rot]}, "maps/x_proxies.json")
	assert_eq(ok.size(), 0, "valid obb records pass: %s" % [ok])
	for field: String in cases:
		var errs: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [cases[field]]}, "maps/x_proxies.json")
		assert_true(S5.mentions(errs, field.strip_edges()), "bad obb '%s' is rejected: %s" % [field, errs])
	var dup: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [good, good]}, "maps/x_proxies.json")
	assert_true(S5.mentions(dup, "duplicate"), "duplicate ids are rejected: %s" % [dup])
	assert_true(ContentDB.OBSTACLE_KINDS.has("obb"), "obb is a map obstacle kind too")


func _with(rec: Dictionary, key: String, value: Variant) -> Dictionary:
	var out: Dictionary = rec.duplicate(true)
	out[key] = value
	return out
