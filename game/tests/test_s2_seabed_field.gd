extends TestCase
## SeabedField (sim side): deterministic analytic/value-noise height, normals, per-zone depth ranges from
## GAME_DESIGN §9, cliff drop, obstacles, resolve(). Ranges allow TOL metres of relief noise.
## GAME_DESIGN §9 numbers asserted literally: shallows 0-20 m, kelp 10-40 m, arches 20-50 m, boat ~45 m,
## cliff ~50 m dropping into the abyss, abyss floor ~80 m.

const S2 := preload("res://tests/s2_support.gd")
const TOL: float = 2.0

var sb: SeabedField


func before_each() -> void:
	sb = S2.seabed()


func _depth(x: float, z: float) -> float:
	return -sb.height_at(x, z)


## Depth statistics over a rectangle: [min, max, mean].
func _depth_stats(x0: float, x1: float, z0: float, z1: float, step: float = 20.0) -> Array[float]:
	var lo: float = INF
	var hi: float = -INF
	var sum: float = 0.0
	var n: int = 0
	var x: float = x0
	while x <= x1:
		var z: float = z0
		while z <= z1:
			var d: float = _depth(x, z)
			lo = minf(lo, d)
			hi = maxf(hi, d)
			sum += d
			n += 1
			z += step
		x += step
	return [lo, hi, sum / float(maxi(n, 1))]


# ======================================================== construction + determinism

func test_from_map_returns_a_field() -> void:
	assert_not_null(sb, "SeabedField.from_map(reef) must return an object")
	assert_true(sb is RefCounted, "RefCounted, not a node")
	assert_false((sb as Object) is Node, "no SceneTree dependency")


func test_height_is_deterministic_across_instances_and_call_order() -> void:
	var other: SeabedField = S2.seabed()
	var lcg := S2.Lcg.new(5)
	var pts: Array[Vector2] = []
	for i in 400:
		pts.append(Vector2((lcg.unit() - 0.5) * 600.0, (lcg.unit() - 0.5) * 600.0))
	var first: Array[float] = []
	for p in pts:
		first.append(sb.height_at(p.x, p.y))
	# same instance, reverse order, then another instance: identical bit-for-bit (no hidden state, no RNG)
	for i in range(pts.size() - 1, -1, -1):
		assert_eq(sb.height_at(pts[i].x, pts[i].y), first[i], "reverse-order re-query differs at %s" % pts[i])
		assert_eq(other.height_at(pts[i].x, pts[i].y), first[i], "second instance differs at %s" % pts[i])


func test_different_seed_gives_a_different_seabed() -> void:
	var m: Dictionary = S2.map().duplicate(true)
	var seabed_data: Dictionary = m["seabed"]
	assert_true(seabed_data.has("seed"), "reef.json seabed.seed (contract)")
	seabed_data["seed"] = int(seabed_data.get("seed", 0)) + 12345
	var other: SeabedField = SeabedField.from_map(m)
	var differing: int = 0
	for ix in 20:
		for iz in 20:
			var x: float = -290.0 + 29.0 * float(ix)
			var z: float = -290.0 + 29.0 * float(iz)
			if absf(sb.height_at(x, z) - other.height_at(x, z)) > 1e-4:
				differing += 1
	assert_true(differing > 40, "seed must drive the relief (only %d/400 samples differ)" % differing)


# ======================================================== global properties

func test_height_is_finite_non_positive_and_within_map_depth() -> void:
	var depth_m: float = float(S2.map()["depth_m"])
	var half: float = S2.half_size()
	var n: int = 61
	for ix in n:
		for iz in n:
			var x: float = -half + 2.0 * half * float(ix) / float(n - 1)
			var z: float = -half + 2.0 * half * float(iz) / float(n - 1)
			var h: float = sb.height_at(x, z)
			if not is_finite(h) or h > 1e-6 or h < -depth_m - TOL:
				fail("height_at(%s, %s) = %s outside [-%s, 0] or not finite" % [x, z, h, depth_m + TOL])
				return


func test_height_is_finite_far_outside_the_map() -> void:
	for p in [Vector2(1000.0, 1000.0), Vector2(-4000.0, 0.0), Vector2(1.0e6, -1.0e6), Vector2(0.0, 0.0)]:
		var h: float = sb.height_at(p.x, p.y)
		assert_true(is_finite(h), "height_at(%s) must be finite, got %s" % [p, h])
		assert_true(h <= 1e-6, "height_at(%s) must be <= 0, got %s" % [p, h])


func test_height_is_continuous() -> void:
	# No cracks between neighbouring samples (1 m apart): max slope well below vertical outside the cliff.
	var lcg := S2.Lcg.new(8)
	for i in 300:
		var x: float = (lcg.unit() - 0.5) * 580.0
		var z: float = (lcg.unit() - 0.5) * 580.0
		if z > 95.0 and z < 185.0:
			continue  # the cliff may be steep by design
		var d: float = absf(sb.height_at(x + 1.0, z) - sb.height_at(x, z))
		assert_true(d < 3.0, "height jumps %s m over 1 m at (%s, %s)" % [d, x, z])
		d = absf(sb.height_at(x, z + 1.0) - sb.height_at(x, z))
		assert_true(d < 3.0, "height jumps %s m over 1 m at (%s, %s)" % [d, x, z])


# ======================================================== depth per zone (GAME_DESIGN §9)

func test_shallows_are_at_most_20_m_deep() -> void:
	var st: Array[float] = _depth_stats(-280.0, 280.0, -290.0, -170.0, 15.0)
	assert_true(st[1] <= 20.0 + TOL, "shallows max depth %s > 20 m" % st[1])
	assert_true(st[1] >= 5.0, "shallows should not be a flat beach at the surface (max depth %s)" % st[1])


func test_player_spawns_are_not_buried() -> void:
	var spawns: Array = S2.map()["player_spawns"]
	for i in spawns.size():
		var p: Vector3 = S2.map_spawn(i)
		assert_true(sb.height_at(p.x, p.z) < p.y - 0.5, "spawn %d at y=%s sits on/below the seabed (height %s)" % [i, p.y, sb.height_at(p.x, p.z)])


func test_kelp_forest_floor_is_10_to_40_m_deep() -> void:
	var st: Array[float] = _depth_stats(-280.0, 280.0, -100.0, -30.0, 15.0)
	assert_true(st[0] >= 10.0 - TOL, "kelp forest min depth %s < 10 m" % st[0])
	assert_true(st[1] <= 40.0 + TOL, "kelp forest max depth %s > 40 m" % st[1])


func test_rock_arches_floor_is_20_to_50_m_deep() -> void:
	var st: Array[float] = _depth_stats(-280.0, 280.0, 0.0, 95.0, 15.0)
	assert_true(st[0] >= 20.0 - TOL, "arches zone min depth %s < 20 m" % st[0])
	assert_true(st[1] <= 50.0 + TOL, "arches zone max depth %s > 50 m" % st[1])


func test_sunken_boat_rests_around_45_m() -> void:
	var st: Array[float] = _depth_stats(40.0, 70.0, 40.0, 70.0, 5.0)
	assert_true(st[2] >= 38.0 and st[2] <= 52.0, "boat area mean depth %s, GAME_DESIGN says ~45 m" % st[2])


func test_abyss_floor_is_about_80_m() -> void:
	var st: Array[float] = _depth_stats(-280.0, 280.0, 185.0, 290.0, 15.0)
	assert_true(st[0] >= 75.0, "abyss min depth %s, floor should be ~80 m" % st[0])
	assert_true(st[1] <= 80.0 + TOL, "abyss max depth %s beyond the 80 m map depth" % st[1])


func test_cliff_drops_from_about_50_m_into_the_abyss() -> void:
	for x in [-200.0, -100.0, 0.0, 100.0, 200.0]:
		var before: float = _depth(x, 105.0)
		var after: float = _depth(x, 185.0)
		assert_true(after - before >= 20.0, "x=%s: depth %s (z=105) -> %s (z=185): the cliff must drop >= 20 m" % [x, before, after])
		# the steepest stretch of the whole z-profile lies in/near the cliff zone (aabb z 120..160)
		var best_z: float = 0.0
		var best_slope: float = -1.0
		var z: float = -290.0
		while z < 288.0:
			var slope: float = absf(sb.height_at(x, z + 2.0) - sb.height_at(x, z)) / 2.0
			if slope > best_slope:
				best_slope = slope
				best_z = z
			z += 2.0
		assert_true(best_z >= 100.0 and best_z <= 180.0, "x=%s: steepest slope %s at z=%s, expected within the cliff zone 100..180" % [x, best_slope, best_z])


# ======================================================== normals

func test_normal_is_unit_length_and_points_up() -> void:
	var half: float = S2.half_size()
	var n: int = 41
	for ix in n:
		for iz in n:
			var x: float = -half + 2.0 * half * float(ix) / float(n - 1)
			var z: float = -half + 2.0 * half * float(iz) / float(n - 1)
			var nv: Vector3 = sb.normal_at(x, z)
			if not nv.is_finite() or absf(nv.length() - 1.0) > 1e-4 or nv.y <= 0.0:
				fail("normal_at(%s, %s) = %s: must be finite, unit length, y > 0" % [x, z, nv])
				return


func test_normal_matches_the_height_gradient() -> void:
	var lcg := S2.Lcg.new(31)
	var checked: int = 0
	for i in 200:
		var x: float = (lcg.unit() - 0.5) * 560.0
		var z: float = -290.0 + lcg.unit() * 380.0  # up to z=90: smooth terrain, the cliff slope is checked separately
		var e: float = 0.2
		var gx: float = (sb.height_at(x + e, z) - sb.height_at(x - e, z)) / (2.0 * e)
		var gz: float = (sb.height_at(x, z + e) - sb.height_at(x, z - e)) / (2.0 * e)
		var expected: Vector3 = Vector3(-gx, 1.0, -gz).normalized()
		var got: Vector3 = sb.normal_at(x, z)
		if expected.dot(got) < 0.98:
			fail("normal_at(%s, %s) = %s disagrees with the height gradient %s (dot %s)" % [x, z, got, expected, expected.dot(got)])
			return
		checked += 1
	assert_eq(checked, 200, "all samples checked")


func test_normal_is_finite_far_outside_the_map() -> void:
	for p in [Vector2(5000.0, 5000.0), Vector2(-1.0e6, 3.0)]:
		var nv: Vector3 = sb.normal_at(p.x, p.y)
		assert_true(nv.is_finite() and absf(nv.length() - 1.0) < 1e-4, "normal_at(%s) = %s" % [p, nv])


# ======================================================== obstacles

func test_obstacles_have_valid_kinds_and_cover_arches_and_boat() -> void:
	var obs: Array[Dictionary] = sb.obstacles()
	assert_true(obs.size() >= 2, "arches + boat placeholder expected, got %d" % obs.size())
	var near_boat: bool = false
	var in_arch_zone: bool = false
	for o in obs:
		assert_true(["sphere", "capsule", "box", "obb"].has(String(o.get("kind", ""))), "obstacle kind must be sphere|capsule|box|obb, got %s" % [o])
		for v in S2.vec_values(o):
			if v.x >= 25.0 and v.x <= 85.0 and v.z >= 25.0 and v.z <= 85.0:
				near_boat = true
			if v.z >= -40.0 and v.z <= 120.0:
				in_arch_zone = true
	assert_true(near_boat, "an obstacle must sit in the sunken_boat zone (x 40..70, z 40..70)")
	assert_true(in_arch_zone, "obstacles must sit in the rock_arches zone (z -40..120)")


func test_obstacles_returns_a_stable_list() -> void:
	assert_eq(sb.obstacles().size(), sb.obstacles().size(), "same count on every call")
	assert_eq(S2.seabed().obstacles().size(), sb.obstacles().size(), "same count from a second instance")


# ======================================================== resolve()

func test_resolve_leaves_free_points_untouched() -> void:
	var lcg := S2.Lcg.new(12)
	for i in 100:
		var x: float = (lcg.unit() - 0.5) * 400.0
		var z: float = 190.0 + lcg.unit() * 90.0  # abyss
		var p := Vector3(x, -40.0, z)
		assert_true(sb.resolve(p, 0.3).is_equal_approx(p), "free point %s must not move" % p)


func test_resolve_lifts_points_out_of_the_seabed() -> void:
	for spot in [Vector2(0.0, 250.0), Vector2(-120.0, -250.0), Vector2(60.0, -90.0), Vector2(0.0, 150.0)]:
		for r in [0.0, 0.2, 5.0]:
			var h: float = sb.height_at(spot.x, spot.y)
			var p := Vector3(spot.x, h - 3.0, spot.y)
			var q: Vector3 = sb.resolve(p, r)
			assert_true(q.is_finite(), "spot %s r %s: resolved point finite" % [spot, r])
			var floor_y: float = sb.height_at(q.x, q.z) + r
			assert_true(q.y >= floor_y - 1e-3, "spot %s r %s: resolved y %s still below height_at + radius %s" % [spot, r, q.y, floor_y])
			assert_true(sb.resolve(q, r).distance_to(q) < 1e-3, "spot %s r %s: resolve is idempotent" % [spot, r])


func test_resolve_pushes_probe_points_out_of_every_obstacle() -> void:
	var r: float = 0.2
	var tested: int = 0
	for o in sb.obstacles():
		var p: Vector3 = S2.penetrating_probe(sb, o, r)
		if not p.is_finite():
			continue
		var q: Vector3 = sb.resolve(p, r)
		assert_true(q.is_finite(), "obstacle %s: resolved point finite (degenerate centre?)" % [o])
		assert_true(sb.resolve(q, r).distance_to(q) < 1e-3, "obstacle %s: resolve must leave a non-penetrating point" % [o])
		assert_true(q.distance_to(p) > 1e-4, "obstacle %s: the point actually moved" % [o])
		tested += 1
	assert_true(tested >= 1, "no obstacle record could be probed (need a Vector3-like entry such as a centre)")
