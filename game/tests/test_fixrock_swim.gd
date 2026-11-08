extends TestCase
## fix-rock-collision end to end: a player fish (band 1 and band 3 radius) driven straight at baked abyss and shallows
## rocks with boost on never ends up inside the rock (the Director's playtest bug), a boss-radius sphere marched
## through a boulder stays outside, and food bits spawned against a rock start outside it.

const S3 := preload("res://tests/s3_support.gd")
const S5 := preload("res://tests/s5_support.gd")

const APPROACH_M: float = 15.0
const TICKS: int = 300
const PEN_TOL_M: float = 1e-3
const ABYSS_ROCKS: int = 12
const SHALLOW_ROCKS: int = 6
## Mid band 3 length (metres) for the B3 radius.
const B3_LENGTH_M: float = 1.6


# Baked rock proxies of one scatter rule (ids s<rule>_*), `count` of them spread evenly over the id order; only rocks
# whose approach circle stays out of the soft edge current (bounds.soft_margin_m).
func _rocks(rule: int, count: int) -> Array[Dictionary]:
	var map: Dictionary = S5.map_record()
	var inner: float = float(map["size_m"]) * 0.5 - float(map["bounds"]["soft_margin_m"]) - APPROACH_M
	var all: Array[Dictionary] = []
	for o: Variant in S5.content().get_proxies(&"reef"):
		var c: Vector3 = _centre(o)
		if str((o as Dictionary)["id"]).begins_with("s%02d_" % rule) and absf(c.x) <= inner and absf(c.z) <= inner:
			all.append(o)
	var out: Array[Dictionary] = []
	if all.is_empty():
		return out
	for k in count:
		out.append(all[(k * all.size()) / count])
	return out


func _centre(o: Dictionary) -> Vector3:
	var c: Array = o["center"]
	return Vector3(float(c[0]), float(c[1]), float(c[2]))


# Drives a fresh player of `xp` from APPROACH_M away straight at the proxy centre for TICKS ticks (boost on).
# Returns {err: "" or the failure, reached: bool}. Failures: the centre comes closer than r (minus PEN_TOL_M) to the
# rock surface, the centre path between two ticks crosses the rock, or the fish stops short of the rock without
# touching anything (a fish stopped by the seabed or a neighbouring rock is fine, reached = false).
# `dirs`: horizontal directions (rock -> start) to try in order; default 8 compass directions.
func _drive_at(o: Dictionary, xp: float, dirs: Array[Vector3] = []) -> Dictionary:
	var w: SimWorld = S3.make_world(9, {"vitals": false})
	var c: Vector3 = _centre(o)
	var start := Vector3.INF
	var db: ContentDB = w.content
	var r: float = S3.length_ref(db, xp) * float(db.get_band(db.band_for_xp(xp))["collision_radius_mult"])
	var tries: Array[Vector3] = dirs.duplicate()
	if tries.is_empty():
		for k in 8:
			var a: float = TAU * float(k) / 8.0
			tries.append(Vector3(cos(a), 0.0, sin(a)))
	for t: Vector3 in tries:
		var s := c + t * APPROACH_M
		s.y = maxf(c.y, w.seabed.height_at(s.x, s.z) + r + 1.0)
		if absf(s.x) > 280.0 or absf(s.z) > 280.0:
			continue
		if w.seabed.resolve(s, r).distance_to(s) < 1e-6:
			start = s
			break
	if not start.is_finite():
		return {"err": "", "reached": false}  # boxed in on every side (no free approach): nothing to test here
	var dir: Vector3 = (c - start).normalized()
	var e: SimEntity = S3.player_at(w, start, xp, dir)
	if absf(w.collision_radius(e) - r) > 1e-6:
		return {"err": "radius model mismatch: %s vs %s" % [w.collision_radius(e), r], "reached": false}
	w.submit(SimCommand.move(e.id, dir, 1.0))
	w.submit(SimCommand.boost(e.id, true))
	var closest: float = INF
	var prev: Vector3 = e.position
	for i in TICKS:
		w.step()
		var d: float = S5.obstacle_sdf(o, e.position)
		closest = minf(closest, d)
		if d < r - PEN_TOL_M:
			return {"err": "rock %s r %.3f: tick %d centre %s is %.4f m from the surface (penetrates)" % [o["id"], r, i, e.position, d], "reached": true}
		if _crosses(o, prev, e.position):
			return {"err": "rock %s r %.3f: tick %d the centre path %s -> %s crosses the rock (tunnelled)" % [o["id"], r, i, prev, e.position], "reached": true}
		prev = e.position
		if i % 100 == 99:
			w.submit(SimCommand.boost(e.id, true))
	if closest <= r + 0.5:
		return {"err": "", "reached": true}
	if w.seabed.resolve(e.position, r + 0.1).distance_to(e.position) < 1e-6:
		return {"err": "rock %s r %.3f: the fish stopped %.2f m short without touching anything (%s)" % [o["id"], r, closest, e.position], "reached": false}
	return {"err": "", "reached": false}


# True when the straight centre path a -> b passes through the solid of `o` (sampled every <= 5 cm).
func _crosses(o: Dictionary, a: Vector3, b: Vector3) -> bool:
	var n: int = maxi(2, ceili(a.distance_to(b) / 0.05))
	for k in range(1, n):
		if S5.obstacle_sdf(o, a.lerp(b, float(k) / float(n))) < 0.0:
			return true
	return false


func _check_rocks(rocks: Array[Dictionary], label: String) -> void:
	assert_eq(rocks.size(), ABYSS_ROCKS if label == "abyss" else SHALLOW_ROCKS, "%s rocks found" % label)
	var xp_b3: float = S3.xp_for_length(S5.content(), B3_LENGTH_M)
	var runs: int = 0
	var reached: int = 0
	for o: Dictionary in rocks:
		for xp: float in [0.0, xp_b3]:
			var res: Dictionary = _drive_at(o, xp)
			runs += 1
			if bool(res["reached"]):
				reached += 1
			if not str(res["err"]).is_empty():
				fail("%s: %s" % [label, res["err"]])
	assert_true(reached * 2 >= runs, "%s: most approaches actually reach their rock (%d of %d)" % [label, reached, runs])


func test_band1_and_band3_fish_cannot_swim_into_abyss_rocks() -> void:
	_check_rocks(_rocks(16, ABYSS_ROCKS), "abyss")


func test_band1_and_band3_fish_cannot_swim_into_shallows_rocks() -> void:
	_check_rocks(_rocks(3, SHALLOW_ROCKS), "shallows")


func test_a_boosting_band1_fish_does_not_tunnel_through_the_thinnest_abyss_rock() -> void:
	var thin: Dictionary = {}
	var best: float = INF
	for o: Dictionary in _rocks(16, 1000):
		var sz: Array = o["size"]
		var t: float = minf(float(sz[0]), float(sz[2]))
		if t < best:
			best = t
			thin = o
	assert_false(thin.is_empty(), "abyss rocks baked")
	if thin.is_empty():
		return
	# approach along the thin horizontal axis, from both sides (the per-tick path check catches a skip-through)
	var b := Basis(S5.quat_of(thin))
	var sz2: Array = thin["size"]
	var axis: Vector3 = b.x if float(sz2[0]) <= float(sz2[2]) else b.z
	axis.y = 0.0
	axis = axis.normalized()
	var reached: int = 0
	for side: Vector3 in [axis, -axis]:
		var dirs: Array[Vector3] = [side]
		var res: Dictionary = _drive_at(thin, 0.0, dirs)
		assert_eq(str(res["err"]), "", "thin rock %s (%.2f m) from %s" % [thin["id"], best, side])
		if bool(res["reached"]):
			reached += 1
	assert_true(reached >= 1, "the boosting band-1 fish reached the thin rock %s from at least one side" % thin["id"])


func test_a_boss_radius_sphere_marched_into_a_big_boulder_stays_outside() -> void:
	var w: SimWorld = S3.make_world(2, {"vitals": false})
	var big: Dictionary = {}
	var vol: float = 0.0
	for o: Variant in S5.content().get_proxies(&"reef"):
		var od: Dictionary = o
		if str(od["id"]).begins_with("s16_"):
			var s: Array = od["size"]
			var v: float = float(s[0]) * float(s[1]) * float(s[2])
			if v > vol:
				vol = v
				big = od
	assert_false(big.is_empty(), "abyss rocks baked")
	if big.is_empty():
		return
	var r: float = 2.5
	var c: Vector3 = _centre(big)
	var step: float = 20.0 / 30.0  # boss dash 20 m/s at 30 Hz
	for k in 4:
		var a: float = TAU * float(k) / 4.0 + 0.3
		var dir := Vector3(cos(a), 0.0, sin(a))
		var p: Vector3 = c - dir * 30.0
		p.y = maxf(c.y, w.seabed.height_at(p.x, p.z) + r)
		p = w.seabed.resolve(p, r)
		for i in 60:
			p = w.seabed.resolve(p + dir * step, r)
			if S5.obstacle_sdf(big, p) < r - PEN_TOL_M:
				fail("boss sphere from %s: inside boulder %s at step %d (%s)" % [dir, big["id"], i, p])
				return


func test_food_bits_spawned_against_a_rock_start_outside_it() -> void:
	var rocks: Array[Dictionary] = _rocks(16, 6)
	for o: Dictionary in rocks:
		var w: SimWorld = S3.make_world(13, {"vitals": false})
		var c: Vector3 = _centre(o)
		var s: Array = o["size"]
		var top := Vector3(c.x, c.y + float(s[1]) * 0.5, c.z)
		var v: SimEntity = S3.npc_at(w, &"shark", top)
		v.hp = 0.0
		w.step()
		var bits: Array[SimEntity] = S3.food_bits(w)
		assert_true(bits.size() > 0, "rock %s: the shark left bits" % o["id"])
		for b: SimEntity in bits:
			var br: float = w.collision_radius(b)
			# the bits drift one tick after spawning: allow that drift on top of the penetration tolerance
			assert_true(S5.obstacle_sdf(o, b.position) >= br - 0.05, "rock %s: bit %s at %s is inside the rock (sdf %.3f)" % [o["id"], b.id, b.position, S5.obstacle_sdf(o, b.position)])


func test_drifting_food_bits_never_sink_into_a_rock() -> void:
	# fix round: SimWorld._drift resolves bits against the obstacles every tick (before: 23 % of the bits spawned
	# against a rock drifted into it, up to 2.75 m deep, unreachable)
	var life: int = S3.ticks(S3.rule_f(S5.content(), "remains.food_bits.lifetime_s"))
	var touching: int = 0
	for o: Dictionary in _rocks(16, 4):
		var w: SimWorld = S3.make_world(17, {"vitals": false})
		var c: Vector3 = _centre(o)
		var s: Array = o["size"]
		var v: SimEntity = S3.npc_at(w, &"shark", Vector3(c.x, c.y + float(s[1]) * 0.5, c.z))
		v.hp = 0.0
		w.step()
		var ids: Array[int] = []
		for b: SimEntity in S3.food_bits(w):
			ids.append(b.id)
		for t in life:
			w.step()
			for id: int in ids:
				var b: SimEntity = w.get_entity(id)
				if b == null:
					continue
				var br: float = w.collision_radius(b)
				var d: float = S5.obstacle_sdf(o, b.position)
				if d < br - PEN_TOL_M:
					fail("rock %s: bit %d drifted into the rock at tick %d (sdf %.4f, radius %.4f)" % [o["id"], id, t, d, br])
					return
				if d < br + 0.01:
					touching += 1
	assert_true(touching > 0, "some bits actually drifted against their rock (bit-ticks in contact: %d)" % touching)
