extends TestCase
## T1.6 bite lunge, no tunnelling: a landed bite whose lunge points at the seabed, a baked rock, an arch pillar / lintel, the
## surface or the map box never leaves the player inside solid geometry. The lunge must run through the normal movement path
## (_substep / _constrain); a teleport by lunge_distance_m would fail these tests.
##
## Method: strength 1 with explicit band distances (LS.BAND_M_TEST = 2 / 3 / 4 / 6 m, far more than the 0.35 m start gap),
## ONE bite landed on a victim pinned just ahead of the mouth, then 120 ticks watched. Per tick: the player sphere must not
## overlap the sim's seabed / obstacle model (SeabedField.resolve), must stay >= r - 1 mm outside every analytic obstacle SDF
## of the neighbourhood, and the straight centre path of the tick must not cross a solid (sampled every 5 cm). Non-vacuity:
## most runs must actually reach the surface within 5 cm (otherwise the lunge never met the geometry).

const LS := preload("res://tests/lunge_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S5 := preload("res://tests/s5_support.gd")

const GAP_M: float = 0.35
const APPROACH_M: float = 10.0
const ABYSS_ROCKS: int = 6
const SHALLOW_ROCKS: int = 3


func _radius(w: SimWorld, band: int) -> float:
	var lm: Dictionary = w.content.get_band(band)["length_m"]
	return sqrt(float(lm["min"]) * float(lm["max"])) * float(w.content.get_band(band)["collision_radius_mult"])


## Summary text of the failing flags of a probe result.
func _flags(res: Dictionary) -> String:
	return "inside_seabed=%s pen=%s tunnel=%s above_surface=%s end=%s" % [res["inside_seabed"], res["pen"], res["tunnel"], res["above_surface"], res["end"]]


## Asserts the invariants over `cases` ([{"label", "res"}]) and the non-vacuity (>= `min_touch` of the landed runs touched).
func _check(cases: Array, min_valid: int, min_touch: float, group: String) -> void:
	assert_true(cases.size() >= min_valid, "%s: at least %d usable probes (got %d)" % [group, min_valid, cases.size()])
	var landed: int = 0
	var touched: int = 0
	for c: Dictionary in cases:
		var res: Dictionary = c["res"]
		var label: String = c["label"]
		assert_false(bool(res["inside_seabed"]), "%s %s: never inside the seabed model (%s)" % [group, label, _flags(res)])
		assert_false(bool(res["pen"]), "%s %s: never inside an analytic obstacle (%s)" % [group, label, _flags(res)])
		assert_false(bool(res["tunnel"]), "%s %s: the centre path never crosses a solid (%s)" % [group, label, _flags(res)])
		assert_false(bool(res["above_surface"]), "%s %s: never above the surface (%s)" % [group, label, _flags(res)])
		if int(res["landed"]) == 1:
			landed += 1
			if bool(res["touched"]):
				touched += 1
	assert_true(landed >= int(ceil(0.75 * float(cases.size()))), "%s: the bite landed in most probes (%d of %d)" % [group, landed, cases.size()])
	assert_true(float(touched) >= min_touch * float(maxi(landed, 1)), "%s: the lunge reached the geometry in %d of %d landed probes (non-vacuity, need >= %.0f %%)" % [group, touched, landed, min_touch * 100.0])


# ======================================================================= seabed

func test_a_lunge_down_into_the_seabed_stops_on_it() -> void:
	var cases: Array = []
	var ref: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	for band in [1, 2, 3]:
		for xz: Vector2 in [Vector2(120.0, 60.0), Vector2(150.0, 40.0), Vector2(95.0, 90.0), Vector2(140.0, 100.0)]:
			for yaw: float in [0.0, 120.0]:
				var r: float = _radius(ref, band)
				var start := Vector3(xz.x, ref.seabed.height_at(xz.x, xz.y) + r + GAP_M, xz.y)
				if ref.seabed.resolve(start, r).distance_to(start) > 1e-6:
					continue
				var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
				var res: Dictionary = LS.probe(w, band, start, LS.dir_of(yaw, -55.0), [], 120)
				cases.append({"label": "band %d at %s yaw %.0f" % [band, xz, yaw], "res": res})
	_check(cases, 16, 0.75, "seabed")


func test_a_lunge_along_a_slope_hugging_the_seabed_stays_above_it() -> void:
	var cases: Array = []
	var ref: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	for band in [2, 3]:
		for xz: Vector2 in [Vector2(120.0, 60.0), Vector2(150.0, 40.0), Vector2(95.0, 90.0)]:
			for pitch: float in [-12.0, -25.0]:
				var r: float = _radius(ref, band)
				var start := Vector3(xz.x, ref.seabed.height_at(xz.x, xz.y) + r + 0.1, xz.y)
				if ref.seabed.resolve(start, r).distance_to(start) > 1e-6:
					continue
				var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
				cases.append({"label": "band %d at %s pitch %.0f" % [band, xz, pitch], "res": LS.probe(w, band, start, LS.dir_of(45.0, pitch), [], 120)})
	_check(cases, 8, 0.5, "slope")


# ======================================================================= surface and map box

func test_a_lunge_up_into_the_surface_stops_below_it() -> void:
	var cases: Array = []
	for band in [1, 2, 3]:
		var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
		var r: float = _radius(w, band)
		var start := Vector3(S3.ARENA.x, -r - GAP_M, S3.ARENA.z)
		var res: Dictionary = LS.probe(w, band, start, LS.dir_of(30.0, 50.0), [], 120)
		cases.append({"label": "band %d" % band, "res": res})
		assert_true((res["end"] as Vector3).y <= -r + 1e-6, "band %d: the player ends at or below -r (y %.4f)" % [band, (res["end"] as Vector3).y])
		assert_true((res["end"] as Vector3).y > -r - 0.05, "band %d: the lunge reached the surface (y %.4f)" % [band, (res["end"] as Vector3).y])
	_check(cases, 3, 0.0, "surface")


func test_a_lunge_toward_the_map_edge_stays_inside_the_box() -> void:
	var half: float = S2.half_size()
	for band in [1, 3]:
		for axis: String in ["x", "z"]:
			var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
			var r: float = _radius(w, band)
			var start := Vector3(half - r - GAP_M, -25.0, 0.0) if axis == "x" else Vector3(0.0, -25.0, half - r - GAP_M)
			if w.seabed.resolve(start, r).distance_to(start) > 1e-6:
				continue
			var dir: Vector3 = Vector3.RIGHT if axis == "x" else Vector3.BACK
			var res: Dictionary = LS.probe(w, band, start, dir, [], 60)
			var end: Vector3 = res["end"]
			assert_true(absf(end.x) <= half - r + 1e-6 and absf(end.z) <= half - r + 1e-6, "band %d axis %s: inside the map box (end %s)" % [band, axis, end])
			assert_eq(res["landed"], 1, "band %d axis %s: the bite landed" % [band, axis])


# ======================================================================= baked rocks

# Baked rock proxies of one scatter rule (ids s<rule>_*), `count` spread evenly over the id order; only rocks whose approach
# circle stays out of the soft edge current.
func _rocks(rule: int, count: int) -> Array[Dictionary]:
	var map: Dictionary = S5.map_record()
	var inner: float = float(map["size_m"]) * 0.5 - float(map["bounds"]["soft_margin_m"]) - APPROACH_M - 5.0
	var all: Array[Dictionary] = []
	for o: Variant in S5.content().get_proxies(&"reef"):
		var od: Dictionary = o
		var c: Array = od["center"]
		if str(od["id"]).begins_with("s%02d_" % rule) and absf(float(c[0])) <= inner and absf(float(c[2])) <= inner:
			all.append(od)
	var out: Array[Dictionary] = []
	if all.is_empty():
		return out
	for k in count:
		out.append(all[(k * all.size()) / count])
	return out


func _rock_cases(rocks: Array[Dictionary]) -> Array:
	var cases: Array = []
	var ref: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	for o: Dictionary in rocks:
		var ca: Array = o["center"]
		var c := Vector3(float(ca[0]), float(ca[1]), float(ca[2]))
		var near: Array[Dictionary] = LS.near_obstacles(ref, c, APPROACH_M + 8.0)
		for band in [1, 3]:
			var r: float = _radius(ref, band)
			for k in 8:
				var a: float = TAU * float(k) / 8.0
				var origin := c + Vector3(cos(a), 0.0, sin(a)) * APPROACH_M
				origin.y = maxf(c.y, ref.seabed.height_at(origin.x, origin.z) + r + 1.0)
				var dir: Vector3 = (c - origin).normalized()
				var start: Vector3 = LS.march_to_surface(ref, near, origin, dir, r, GAP_M, APPROACH_M + 4.0)
				if not start.is_finite():
					continue
				var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
				cases.append({"label": "%s band %d from %.0f deg" % [o["id"], band, rad_to_deg(a)], "res": LS.probe(w, band, start, dir, near, 120)})
				break
	return cases


func test_a_lunge_at_an_abyss_rock_never_ends_inside_it() -> void:
	var rocks: Array[Dictionary] = _rocks(16, ABYSS_ROCKS)
	assert_eq(rocks.size(), ABYSS_ROCKS, "abyss rocks found")
	_check(_rock_cases(rocks), ABYSS_ROCKS, 0.5, "abyss rocks")


func test_a_lunge_at_a_shallows_rock_never_ends_inside_it() -> void:
	var rocks: Array[Dictionary] = _rocks(3, SHALLOW_ROCKS)
	assert_eq(rocks.size(), SHALLOW_ROCKS, "shallows rocks found")
	_check(_rock_cases(rocks), SHALLOW_ROCKS, 0.5, "shallows rocks")


# ======================================================================= arches

func _arch_cases() -> Array:
	var cases: Array = []
	var ref: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
	var by_id: Dictionary = S5.obstacle_by_id(ref.map)
	for arch in ["arch_a", "arch_b"]:
		var left: Dictionary = by_id.get(arch + "_left", {})
		var right: Dictionary = by_id.get(arch + "_right", {})
		if left.is_empty() or right.is_empty():
			continue
		var lm: Vector3 = (S5._vec(left["a"]) + S5._vec(left["b"])) * 0.5
		var rm: Vector3 = (S5._vec(right["a"]) + S5._vec(right["b"])) * 0.5
		var centre: Vector3 = (lm + rm) * 0.5
		var across: Vector3 = lm - rm
		across.y = 0.0
		across = across.normalized()
		var near: Array[Dictionary] = LS.near_obstacles(ref, centre, 22.0)
		# (label, origin, direction) in the opening: at each pillar's inner face, and up at the lintel
		var probes: Array = [
			["left pillar", centre, across],
			["right pillar", centre, -across],
			["lintel", centre + Vector3(0.0, 0.0, -1.0), LS.dir_of(90.0, 70.0)],
		]
		for pr: Array in probes:
			for band in [1, 2, 3]:
				var r: float = _radius(ref, band)
				var start: Vector3 = LS.march_to_surface(ref, near, pr[1], pr[2], r, GAP_M, 14.0)
				if not start.is_finite():
					continue
				var w: SimWorld = LS.world(1.0, LS.BAND_M_TEST)
				cases.append({"label": "%s %s band %d" % [arch, pr[0], band], "res": LS.probe(w, band, start, pr[2], near, 120)})
	return cases


func test_a_lunge_into_an_arch_pillar_or_lintel_never_ends_inside_it() -> void:
	_check(_arch_cases(), 12, 0.75, "arches")
