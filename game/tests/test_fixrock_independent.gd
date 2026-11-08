extends TestCase
## fix-rock-collision, independent verification (written from the task spec, not from the implementation tests):
## black-box through SeabedField / SimWorld / ContentDB / NpcBrain / NpcSpawner with the shipped reef data.
## Reference geometry (sdf of every primitive) is re-implemented here (RefField), not taken from the sim or S5 helpers.
## Statistics lines are printed as "FIXROCK_STAT ..." so the numbers can be quoted in the test report.
## Default counts keep the file around 30 s for check.sh; FIXROCK_HEAVY=1 in the environment runs the full counts of the
## Phase B report (20,000 index points, 60 points per real rock pair).

const S3 := preload("res://tests/s3_support.gd")
const S5 := preload("res://tests/s5_support.gd")

const DT: float = 1.0 / 30.0
const PEN_TOL_M: float = 1e-3
## A straight centre path that cuts at least this deep into a rock is a real tunnel (not a clipped rounded corner).
const TUNNEL_DEPTH_M: float = 0.25
const CELL_M: float = 16.0
## Obstacle bounds are registered this far beyond their surface (largest query radius 4 m + slack).
const REACH_M: float = 6.0
const SCRATCH: String = "user://fixrock_independent_scratch"
## Band radii (length x collision_radius_mult 0.25): B1 0.2 m, B2 0.6 m, B3 1.4 m, B4 3.2 m long fish.
const RADII: Dictionary = {"B1": 0.05, "B2": 0.15, "B3": 0.35, "B4": 0.8, "boss": 2.5}
const BAND_SPEED: Dictionary = {"B1": 3.0, "B2": 4.5, "B3": 6.0, "B4": 7.5, "boss": 7.0}
const BOSS_DASH_MPS: float = 20.0
const RULES: Array[int] = [3, 8, 10, 14, 16]
const RULE_NAMES: Dictionary = {3: "shallows", 8: "kelp", 10: "arches", 14: "cliff_edge", 16: "abyss"}
const HEAVY_ENV: String = "FIXROCK_HEAVY"


## Full Phase B counts when FIXROCK_HEAVY=1 (slow, ~100 s), else the check.sh counts.
func _heavy() -> bool:
	return OS.get_environment(HEAVY_ENV) == "1"


# ------------------------------------------------------------------------------------------------ reference geometry

## Independent signed-distance model of the obstacle records (JSON form) with a 16 m grid of candidates.
class RefField extends RefCounted:
	var kind: PackedInt32Array = PackedInt32Array()  # 0 sphere, 1 capsule, 2 box, 3 obb
	var c: PackedVector3Array = PackedVector3Array()
	var b2: PackedVector3Array = PackedVector3Array()  # capsule b / box half / obb inner half
	var rad: PackedFloat64Array = PackedFloat64Array()  # sphere/capsule radius, obb corner radius
	var inv: Array[Basis] = []
	var ids: PackedStringArray = PackedStringArray()
	var bounds: Array[AABB] = []
	var cells: Dictionary = {}

	static func v3(a: Variant) -> Vector3:
		var l: Array = a
		return Vector3(float(l[0]), float(l[1]), float(l[2]))

	func add(o: Dictionary) -> void:
		var k: String = str(o["kind"])
		var i: int = kind.size()
		ids.append(str(o["id"]))
		inv.append(Basis())
		b2.append(Vector3.ZERO)
		rad.append(0.0)
		var bb := AABB()
		match k:
			"sphere":
				kind.append(0)
				c.append(v3(o["center"]))
				rad[i] = float(o["radius"])
				bb = AABB(c[i] - Vector3.ONE * rad[i], Vector3.ONE * rad[i] * 2.0)
			"capsule":
				kind.append(1)
				c.append(v3(o["a"]))
				b2[i] = v3(o["b"])
				rad[i] = float(o["radius"])
				var lo: Vector3 = c[i].min(b2[i]) - Vector3.ONE * rad[i]
				var hi: Vector3 = c[i].max(b2[i]) + Vector3.ONE * rad[i]
				bb = AABB(lo, hi - lo)
			"box":
				kind.append(2)
				c.append(v3(o["center"]))
				b2[i] = v3(o["size"]) * 0.5
				bb = AABB(c[i] - b2[i], b2[i] * 2.0)
			_:
				kind.append(3)
				c.append(v3(o["center"]))
				var size: Vector3 = v3(o["size"])
				rad[i] = float(o.get("round", 0.0))
				b2[i] = size * 0.5 - Vector3.ONE * rad[i]
				var q := Quaternion.IDENTITY
				if o.has("rot"):
					var r: Array = o["rot"]
					q = Quaternion(float(r[0]), float(r[1]), float(r[2]), float(r[3])).normalized()
				inv[i] = Basis(q).inverse()
				var half: float = size.length() * 0.5
				bb = AABB(c[i] - Vector3.ONE * half, Vector3.ONE * half * 2.0)
		bounds.append(bb)

	func build() -> void:
		cells.clear()
		for i in kind.size():
			var g: AABB = bounds[i].grow(REACH_M)
			for ix in range(floori(g.position.x / CELL_M), floori(g.end.x / CELL_M) + 1):
				for iz in range(floori(g.position.z / CELL_M), floori(g.end.z / CELL_M) + 1):
					var key := Vector2i(ix, iz)
					if not cells.has(key):
						cells[key] = []
					(cells[key] as Array).append(i)

	func count() -> int:
		return kind.size()

	func sdf(i: int, p: Vector3) -> float:
		match kind[i]:
			0:
				return p.distance_to(c[i]) - rad[i]
			1:
				var ab: Vector3 = b2[i] - c[i]
				var t: float = clampf((p - c[i]).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
				return p.distance_to(c[i] + ab * t) - rad[i]
			2:
				var q: Vector3 = (p - c[i]).abs() - b2[i]
				return q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
			_:
				var l: Vector3 = inv[i] * (p - c[i])
				var q2: Vector3 = l.abs() - b2[i]
				return q2.max(Vector3.ZERO).length() + minf(maxf(q2.x, maxf(q2.y, q2.z)), 0.0) - rad[i]
		return INF

	## Candidate obstacle indices of the grid cell of p.
	func near(p: Vector3) -> Array:
		return cells.get(Vector2i(floori(p.x / CELL_M), floori(p.z / CELL_M)), [])

	## Smallest surface distance to an obstacle among those within REACH_M (INF when none is that close).
	func clear(p: Vector3) -> float:
		var best: float = INF
		for i: int in near(p):
			best = minf(best, sdf(i, p))
		return best

	func clear_all(p: Vector3) -> float:
		var best: float = INF
		for i in kind.size():
			best = minf(best, sdf(i, p))
		return best

	func index_of(id: String) -> int:
		return ids.find(id)


static var _ref: RefField = null
static var _sb: SeabedField = null
static var _recs: Array[Dictionary] = []
static var _by_rule: Dictionary = {}


func _setup() -> void:
	if _ref != null:
		return
	var db: ContentDB = S5.content()
	var map: Dictionary = db.get_map(&"reef")
	_sb = SeabedField.from_map(map, db.get_proxies(&"reef"))
	_ref = RefField.new()
	for o: Variant in map["obstacles"]:
		_recs.append(o)
	for o: Variant in db.get_proxies(&"reef"):
		_recs.append(o)
	for o: Dictionary in _recs:
		_ref.add(o)
	_ref.build()
	for i in _recs.size():
		var id: String = str(_recs[i]["id"])
		if id.length() > 3 and id[0] == "s" and id[3] == "_":
			var rule: int = int(id.substr(1, 2))
			if not _by_rule.has(rule):
				_by_rule[rule] = []
			(_by_rule[rule] as Array).append(i)


func _stat(label: String, d: Dictionary) -> void:
	print("FIXROCK_STAT %s %s" % [label, JSON.stringify(d)])


## Rocks of the baked scatter rules, ordered by id, `count` of them spread evenly (and randomised start).
func _pick(rule: int, count: int, rng: RandomNumberGenerator) -> Array[int]:
	var all: Array = _by_rule.get(rule, [])
	var out: Array[int] = []
	if all.is_empty():
		return out
	for k in count:
		out.append(all[rng.randi_range(0, all.size() - 1)])
	return out


# ------------------------------------------------------------------------------------------------ kinematic swim fuzz

## Picks a free start 6 m beyond the bounding sphere of obstacle `i`, aimed at a random point of its core.
func _approach(i: int, r: float, rng: RandomNumberGenerator) -> Dictionary:
	var bb: AABB = _ref.bounds[i]
	var cen: Vector3 = bb.get_center()
	var half: float = bb.size.length() * 0.5
	var dist: float = half + 6.0
	for attempt in 14:
		var a: float = rng.randf() * TAU
		var s := cen + Vector3(cos(a), 0.0, sin(a)) * dist
		s.y = cen.y + (rng.randf() - 0.5) * bb.size.y * 0.8
		s.y = maxf(s.y, _sb.height_at(s.x, s.z) + r + 0.2)
		if absf(s.x) > 280.0 or absf(s.z) > 280.0 or s.y > -r - 0.3:
			continue
		if _sb.resolve(s, r).distance_to(s) > 1e-6 or _ref.clear(s) < r + 0.2:
			continue
		var aim := cen + Vector3((rng.randf() - 0.5) * bb.size.x * 0.6, (rng.randf() - 0.5) * bb.size.y * 0.6, (rng.randf() - 0.5) * bb.size.z * 0.6)
		return {"ok": true, "start": s, "dir": (aim - s).normalized(), "dist": dist, "half": half}
	return {"ok": false}


## Obstacles (id: sdf - r) whose surface is within 0.1 m of the sphere.
func _contacts(q: Vector3, r: float) -> String:
	var out: PackedStringArray = PackedStringArray()
	for i: int in _ref.near(q):
		var d: float = _ref.sdf(i, q) - r
		if d < 0.1:
			out.append("%s:%.4f" % [_ref.ids[i], d])
	return ", ".join(out)


## How deep (metres, 0 = not at all) the straight centre path a -> b cuts into the solid of any obstacle near it.
## A path between two surface-following positions may clip a rounded corner by a few cm (chord of the offset
## surface); only depth >= TUNNEL_DEPTH_M counts as the centre really passing through rock.
func _path_depth(a: Vector3, b: Vector3) -> float:
	var seg: float = a.distance_to(b)
	var ca: float = _ref.clear(a)
	if ca > seg + 0.01:
		return 0.0  # the sdf is 1-Lipschitz: the path cannot reach a surface
	var n: int = maxi(2, ceili(seg / 0.05))
	var deepest: float = 0.0
	for k in range(1, n):
		deepest = maxf(deepest, -_ref.clear(a.lerp(b, float(k) / float(n))))
	return deepest


## One tick of movement the way SimWorld moves a body (fix round): a step longer than max(MOVE_SUBSTEP_M, r) is
## resolved in equal sub-steps (SimWorld._substep), then the target is resolved. Returns [end, deepest centre-path cut].
func _advance(f: SeabedField, p: Vector3, want: Vector3, r: float, measure: bool) -> Array:
	var lim: float = maxf(SimWorld.MOVE_SUBSTEP_M, r)
	var n: int = maxi(1, ceili(p.distance_to(want) / lim))
	var stp: Vector3 = (want - p) / float(n)
	var q: Vector3 = p
	var depth: float = 0.0
	for k in n:
		var nq: Vector3 = f.resolve(q + stp, r)
		if measure:
			depth = maxf(depth, _path_depth(q, nq))
		q = nq
	return [q, depth]


## Drives a sphere of radius r with a constant desired velocity at obstacle `i` through resolve() with SimWorld's sub-steps.
## Returns {inside_ticks, final_inside, tunnels, worst_pen, ticks, skipped}.
func _kin_swim(i: int, r: float, speed: float, rng: RandomNumberGenerator) -> Dictionary:
	var ap: Dictionary = _approach(i, r, rng)
	if not bool(ap["ok"]):
		return {"skipped": true}
	var p: Vector3 = ap["start"]
	var vel: Vector3 = (ap["dir"] as Vector3) * speed
	var ticks: int = clampi(ceili((float(ap["dist"]) + float(ap["half"]) * 2.0 + 4.0) / (speed * DT)) + 15, 20, 800)
	var out: Dictionary = {"skipped": false, "inside_ticks": 0, "final_inside": false, "tunnels": 0, "through": 0, "max_path_depth": 0.0, "worst_pen": 0.0, "ticks": ticks, "detail": ""}
	var dirn: Vector3 = ap["dir"]
	var cen: Vector3 = _ref.bounds[i].get_center()
	for t in ticks:
		var want: Vector3 = p + vel * DT
		var adv: Array = _advance(_sb, p, want, r, true)
		var q: Vector3 = adv[0]
		var depth: float = adv[1]
		out["max_path_depth"] = maxf(float(out["max_path_depth"]), depth)
		if depth >= TUNNEL_DEPTH_M:
			out["tunnels"] = int(out["tunnels"]) + 1
			# a pass-through: the centre ends on the far side of the rock's centre plane
			if (p - cen).dot(dirn) < 0.0 and (q - cen).dot(dirn) > 0.0:
				out["through"] = int(out["through"]) + 1
		var pen: float = r - _ref.clear(q)
		if pen > PEN_TOL_M:
			out["inside_ticks"] = int(out["inside_ticks"]) + 1
			if pen > float(out["worst_pen"]):
				out["detail"] = "tick %d r %.3f pen %.4f seabed_gap %.3f step %.3f again %.4f contacts %s" % [t, r, pen, q.y - _sb.height_at(q.x, q.z), want.distance_to(p), _sb.resolve(q, r).distance_to(q), _contacts(q, r)]
			out["worst_pen"] = maxf(float(out["worst_pen"]), pen)
		p = q
	out["final_inside"] = r - _ref.clear(p) > PEN_TOL_M
	return out


## Runs `per_rule` random swims per scatter rule at (class, speed); returns aggregate stats.
func _kin_batch(klass: String, speed: float, per_rule: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var r: float = RADII[klass]
	var agg: Dictionary = {"class": klass, "speed": speed, "swims": 0, "skipped": 0, "inside_swims": 0, "final_inside": 0, "tunnel_swims": 0, "tunnel_events": 0, "through_swims": 0, "max_path_depth": 0.0, "worst_pen": 0.0, "worst_where": "", "worst_detail": "", "tunnel_where": [], "through_where": []}
	for rule: int in RULES:
		for i: int in _pick(rule, per_rule, rng):
			var res: Dictionary = _kin_swim(i, r, speed, rng)
			if bool(res["skipped"]):
				agg["skipped"] = int(agg["skipped"]) + 1
				continue
			agg["swims"] = int(agg["swims"]) + 1
			if int(res["inside_ticks"]) > 0:
				agg["inside_swims"] = int(agg["inside_swims"]) + 1
			if bool(res["final_inside"]):
				agg["final_inside"] = int(agg["final_inside"]) + 1
			if int(res["tunnels"]) > 0:
				agg["tunnel_swims"] = int(agg["tunnel_swims"]) + 1
				agg["tunnel_events"] = int(agg["tunnel_events"]) + int(res["tunnels"])
				if (agg["tunnel_where"] as Array).size() < 6:
					(agg["tunnel_where"] as Array).append("%s(%s)" % [_ref.ids[i], RULE_NAMES[rule]])
			agg["max_path_depth"] = maxf(float(agg["max_path_depth"]), float(res["max_path_depth"]))
			if int(res["through"]) > 0:
				agg["through_swims"] = int(agg["through_swims"]) + 1
				if (agg["through_where"] as Array).size() < 6:
					(agg["through_where"] as Array).append("%s(%s)" % [_ref.ids[i], RULE_NAMES[rule]])
			if float(res["worst_pen"]) > float(agg["worst_pen"]):
				agg["worst_pen"] = res["worst_pen"]
				agg["worst_where"] = "%s(%s)" % [_ref.ids[i], RULE_NAMES[rule]]
				agg["worst_detail"] = res["detail"]
	return agg


func test_random_swims_at_swim_and_boost_speed_never_enter_or_cross_a_rock() -> void:
	_setup()
	var per_rule: int = 14 if _heavy() else 8
	var tot_swims: int = 0
	for klass: String in ["B1", "B2", "B3", "B4", "boss"]:
		for mode: String in ["swim", "boost"]:
			var speed: float = float(BAND_SPEED[klass]) * (1.8 if mode == "boost" else 1.0)
			var agg: Dictionary = _kin_batch(klass, speed, per_rule, 1000 + hash(klass + mode) % 997)
			agg["mode"] = mode
			_stat("kin_swim", agg)
			tot_swims += int(agg["swims"])
			assert_eq(int(agg["inside_swims"]), 0, "%s %s: swims that ended a tick inside a proxy (worst %.4f m at %s)" % [klass, mode, agg["worst_pen"], agg["worst_where"]])
			assert_eq(int(agg["tunnel_swims"]), 0, "%s %s: swims whose centre path crossed a rock %s" % [klass, mode, agg["tunnel_where"]])
	assert_true(tot_swims >= (500 if _heavy() else 280), "enough swims actually ran (%d)" % tot_swims)


func test_random_swims_at_dash_speed_report_tunnelling_and_never_end_inside() -> void:
	_setup()
	var per_rule: int = 20
	var total: int = 0
	var tunnel_swims: int = 0
	var through_swims: int = 0
	var worst: float = 0.0
	for klass: String in ["B1", "B2", "B3", "B4", "boss"]:
		var speed: float = 20.0 if klass == "boss" else 8.0 / (11.0 * DT)  # Bite-Dash: 8 m over 0.35 s = 11 ticks
		var agg: Dictionary = _kin_batch(klass, speed, per_rule, 2000 + hash(klass) % 991)
		agg["mode"] = "dash"
		_stat("kin_dash", agg)
		total += int(agg["swims"])
		tunnel_swims += int(agg["tunnel_swims"])
		through_swims += int(agg["through_swims"])
		worst = maxf(worst, float(agg["worst_pen"]))
		assert_eq(int(agg["final_inside"]), 0, "%s dash: swims that ENDED inside a proxy (worst %.4f m at %s)" % [klass, agg["worst_pen"], agg["worst_where"]])
		assert_eq(int(agg["inside_swims"]), 0, "%s dash: swims with a tick inside a proxy (worst %.4f m at %s)" % [klass, agg["worst_pen"], agg["worst_where"]])
	_stat("kin_dash_total", {"swims": total, "tunnel_swims": tunnel_swims, "through_swims": through_swims, "tunnel_rate": float(tunnel_swims) / float(maxi(total, 1)), "through_rate": float(through_swims) / float(maxi(total, 1)), "worst_pen": worst})
	# fix round: SimWorld sub-steps long moves (MOVE_SUBSTEP_M), mirrored by _advance(); measured 0 of 477 (was 2 = 0.42 %
	# without sub-steps). At most 0.1 % is tolerated.
	assert_true(float(through_swims) / float(maxi(total, 1)) <= 0.001, "dash pass-through (ends on the far side of the rock) %d of %d swims" % [through_swims, total])
	assert_true(float(tunnel_swims) / float(maxi(total, 1)) <= 0.001, "dash centre path cut >= %.2f m into a rock in %d of %d swims" % [TUNNEL_DEPTH_M, tunnel_swims, total])


# ------------------------------------------------------------------------------------------------ SimWorld swims

## Spawns one body per rock in a fresh world, drives it straight at the rock for `ticks`, checks every tick.
## mode: "swim" | "boost" | "bite_dash" | "boss_dash". Returns {swims, inside, tunnels, worst_pen, reached}.
func _sim_batch(klass: String, mode: String, per_rule: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var w: SimWorld = S3.make_world(seed_value, {"vitals": false})
	w.brains_enabled = false
	var db: ContentDB = w.content
	var length: float = {"B1": 0.2, "B2": 0.6, "B3": 1.4, "B4": 3.2, "boss": 10.0}[klass]
	var xp: float = S3.xp_for_length(db, length)
	var bodies: Array[Dictionary] = []
	for rule: int in RULES:
		for i: int in _pick(rule, per_rule, rng):
			var r_guess: float = length * 0.25 if klass != "boss" else 2.5
			var ap: Dictionary = _approach(i, r_guess + (6.0 if klass == "boss" else 0.0), rng)
			if not bool(ap["ok"]):
				continue
			var s: Vector3 = ap["start"]
			var e: SimEntity
			if klass == "boss":
				e = S3.npc_at(w, &"giant_shark", s, 10.0, ap["dir"])
			else:
				e = S3.player_at(w, s, xp, ap["dir"])
				if mode == "bite_dash":
					e.abilities.append("bite_dash")
					e.ability_ready_ticks.append(0)
			bodies.append({"e": e, "i": i, "dir": ap["dir"], "r": w.collision_radius(e), "prev": e.position, "inside": false, "tun": false, "worst": 0.0, "touched": false, "dist": ap["dist"], "half": ap["half"]})
	var speed: float = w.band_swim_speed(bodies[0]["e"].band) * (1.8 if mode == "boost" else 1.0) if not bodies.is_empty() else 3.0
	var ticks: int = clampi(ceili((24.0) / maxf(speed * DT, 0.05)), 120, 450)
	if mode == "bite_dash" or mode == "boss_dash":
		ticks = 150
	var fired: Dictionary = {}
	for t in ticks:
		for b: Dictionary in bodies:
			var e2: SimEntity = b["e"]
			if mode == "boss_dash":
				if e2.dash_until_tick < 0 and not fired.has(e2.id):
					Abilities.start_dash(w, e2, b["dir"], BOSS_DASH_MPS, 45, Abilities.BOSS_DASH)
					fired[e2.id] = true
			else:
				w.submit(SimCommand.move(e2.id, b["dir"], 1.0))
				if mode == "boost":
					w.submit(SimCommand.boost(e2.id, true))
					e2.stamina = 100.0
				if mode == "bite_dash" and (t % 40 == 0):
					w.submit(SimCommand.ability(e2.id, &"bite_dash"))
					e2.ability_ready_ticks[0] = 0
		w.step()
		for b: Dictionary in bodies:
			var e3: SimEntity = b["e"]
			var r: float = b["r"]
			var pen: float = r - _ref.clear(e3.position)
			if pen > PEN_TOL_M:
				b["inside"] = true
				b["worst"] = maxf(float(b["worst"]), pen)
			var pd: float = _path_depth(b["prev"], e3.position)
			b["pdepth"] = maxf(float(b.get("pdepth", 0.0)), pd)
			if pd >= TUNNEL_DEPTH_M:
				b["deep"] = true
			var ccen: Vector3 = _ref.bounds[b["i"]].get_center()
			if pd >= TUNNEL_DEPTH_M and (b["prev"] - ccen).dot(b["dir"]) < 0.0 and (e3.position - ccen).dot(b["dir"]) > 0.0:
				b["tun"] = true
				if not b.has("tun_detail"):
					b["tun_detail"] = "rock %s size %s rot %s | prev %s -> now %s (step %.3f m, path depth %.3f) dir %s r %.3f" % [_ref.ids[b["i"]], _recs[b["i"]]["size"], _recs[b["i"]].get("rot"), b["prev"], e3.position, b["prev"].distance_to(e3.position), pd, b["dir"], r]
			if _ref.clear(e3.position) < r + 0.5:
				b["touched"] = true
			b["prev"] = e3.position
	var out: Dictionary = {"class": klass, "mode": mode, "swims": bodies.size(), "inside": 0, "tunnels": 0, "deep_path_swims": 0, "max_path_depth": 0.0, "worst_pen": 0.0, "reached": 0, "where": [], "tunnel_detail": []}
	for b: Dictionary in bodies:
		if bool(b["inside"]):
			out["inside"] = int(out["inside"]) + 1
			(out["where"] as Array).append(_ref.ids[b["i"]])
		if bool(b["tun"]):
			out["tunnels"] = int(out["tunnels"]) + 1
			(out["where"] as Array).append(str(_ref.ids[b["i"]]) + "(tunnel)")
			(out["tunnel_detail"] as Array).append(b["tun_detail"])
		if bool(b.get("deep", false)):
			out["deep_path_swims"] = int(out["deep_path_swims"]) + 1
		if bool(b["touched"]):
			out["reached"] = int(out["reached"]) + 1
		out["worst_pen"] = maxf(float(out["worst_pen"]), float(b["worst"]))
		out["max_path_depth"] = maxf(float(out["max_path_depth"]), float(b.get("pdepth", 0.0)))
	return out


func test_sim_world_swims_at_swim_boost_and_dash_speed_never_end_inside_a_rock() -> void:
	_setup()
	var tot: int = 0
	var reached: int = 0
	var tunnel_total: int = 0
	var dash_total: int = 0
	var combos: Array = [
		["B1", "swim"], ["B1", "boost"], ["B1", "bite_dash"],
		["B2", "boost"], ["B2", "bite_dash"],
		["B3", "swim"], ["B3", "boost"], ["B3", "bite_dash"],
		["B4", "boost"], ["B4", "bite_dash"],
		["boss", "swim"], ["boss", "boss_dash"],
	]
	for combo: Array in combos:
		var res: Dictionary = _sim_batch(combo[0], combo[1], 5 if _heavy() else 2, 3000 + hash(str(combo)) % 977)
		_stat("sim_swim", res)
		tot += int(res["swims"])
		reached += int(res["reached"])
		assert_eq(int(res["inside"]), 0, "%s %s: bodies that ended a tick inside a proxy (worst %.4f m) %s" % [combo[0], combo[1], res["worst_pen"], res["where"]])
		if combo[1] == "bite_dash" or combo[1] == "boss_dash":
			dash_total += int(res["swims"])
			tunnel_total += int(res["tunnels"])
		else:
			assert_eq(int(res["tunnels"]), 0, "%s %s: bodies whose centre path crossed a rock %s" % [combo[0], combo[1], res["where"]])
	_stat("sim_swim_total", {"swims": tot, "reached_rock": reached, "dash_swims": dash_total, "dash_tunnel_swims": tunnel_total})
	assert_true(reached * 2 >= tot, "most swims actually reached a rock (%d of %d)" % [reached, tot])
	assert_true(float(tunnel_total) <= 0.05 * float(maxi(dash_total, 1)), "dash tunnelling %d of %d" % [tunnel_total, dash_total])


# ------------------------------------------------------------------------------------------------ index vs reference

func test_cell_index_matches_the_reference_pass_on_20k_random_points() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var n: int = 20000 if _heavy() else 1200
	var mism_out: int = 0
	var mism_in: int = 0
	var n_out: int = 0
	var n_in: int = 0
	var max_dev_out: float = 0.0
	var max_dev_in: float = 0.0
	var bad_post_cell: int = 0
	var bad_post_ref: int = 0
	var worst_post: float = 0.0
	var n_under: int = 0
	var under_viol: int = 0
	var bad_post_inside_start: int = 0
	var solids: Array[int] = []
	for rule: int in RULES:
		solids.append_array(_by_rule.get(rule, []))
	for k in n:
		# 60 % near a random baked rock (where the difference could show), 40 % uniform on the map
		var p: Vector3
		if rng.randf() < 0.6:
			var i: int = solids[rng.randi_range(0, solids.size() - 1)]
			var bb: AABB = _ref.bounds[i]
			var cen: Vector3 = bb.get_center()
			p = cen + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * (bb.size.length() * 0.35)
		else:
			p = Vector3(rng.randf_range(-300.0, 300.0), 0.0, rng.randf_range(-300.0, 300.0))
			p.y = _sb.height_at(p.x, p.z) + rng.randf() * rng.randf() * 12.0
		var rr: float = rng.randf()
		var r: float = rng.randf_range(0.03, 0.5) if rr < 0.7 else (rng.randf_range(0.5, 4.0) if rr < 0.95 else rng.randf_range(4.0, 6.0))
		var underground: bool = p.y < _sb.height_at(p.x, p.z)
		var outside: bool = _sb.obstacle_clear(p, r)
		var a: Vector3 = _sb.resolve(p, r)
		var b: Vector3 = _sb.resolve_reference(p, r)
		var dev: float = a.distance_to(b)
		if outside:
			n_out += 1
			max_dev_out = maxf(max_dev_out, dev)
			if dev > 1e-9:
				mism_out += 1
		else:
			n_in += 1
			max_dev_in = maxf(max_dev_in, dev)
			if dev > 1e-9:
				mism_in += 1
		# post-condition of the production (cell-indexed) path: no rock penetration
		var pc: float = r - _ref.clear_all(a)
		var pr: float = r - _ref.clear_all(b)
		if underground:
			n_under += 1
			if pc > PEN_TOL_M:
				under_viol += 1
			continue
		if pc > PEN_TOL_M:
			if outside:
				bad_post_cell += 1
			else:
				bad_post_inside_start += 1
		if pr > PEN_TOL_M:
			bad_post_ref += 1
		worst_post = maxf(worst_post, maxf(pc, pr))
	_stat("index_vs_reference", {"points": n, "start_outside": n_out, "start_inside": n_in, "mismatch_outside": mism_out, "mismatch_inside": mism_in, "max_dev_outside_m": max_dev_out, "max_dev_inside_m": max_dev_in, "postcondition_viol_cell": bad_post_cell, "postcondition_viol_cell_inside_start": bad_post_inside_start, "postcondition_viol_ref": bad_post_ref, "underground_starts": n_under, "underground_viol": under_viol, "worst_post_pen_m": worst_post, "mismatch_rate_total": float(mism_out + mism_in) / float(n)})
	assert_eq(mism_out, 0, "cell index differs from the reference pass for starts clear of every obstacle (max dev %s m)" % max_dev_out)
	assert_eq(bad_post_cell, 0, "cell-indexed resolve leaves the sphere inside an obstacle from a clear start (%d of %d, worst %s m)" % [bad_post_cell, n, worst_post])
	assert_true(float(bad_post_inside_start) <= 0.01 * float(maxi(n_in, 1)), "resolve from a start inside a rock still ends inside one: %d of %d" % [bad_post_inside_start, n_in])


# ------------------------------------------------------------------------------------------------ wedges

func _synthetic(rocks: Array) -> Dictionary:
	var map: Dictionary = S5.map_record().duplicate(true)
	map["obstacles"] = []
	var f := SeabedField.from_map(map, rocks)
	var ref := RefField.new()
	for o: Variant in rocks:
		ref.add(o)
	ref.build()
	return {"sb": f, "ref": ref}


func _rand_quat(rng: RandomNumberGenerator) -> Quaternion:
	return Quaternion(Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized(), rng.randf_range(0.0, PI))


func _rock_rec(id: String, c: Vector3, size: Vector3, q: Quaternion, rnd: float) -> Dictionary:
	return {"id": id, "tag": "rock", "kind": "obb", "center": [c.x, c.y, c.z], "size": [size.x, size.y, size.z], "rot": [q.x, q.y, q.z, q.w], "round": rnd}


func test_seabed_plus_two_or_three_overlapping_rocks_never_leave_a_sphere_inside() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var sites: Array[Vector2] = [Vector2(40.0, -200.0), Vector2(-100.0, -60.0), Vector2(120.0, 40.0), Vector2(-60.0, 190.0), Vector2(30.0, 260.0)]
	var cases: int = 0
	# shallow = the sphere starts at most one Bite-Dash step (0.8 m) into the rocks; deep = further in (teleport-like)
	var st: Dictionary = {"shallow_pts": 0, "shallow_viol": 0, "shallow_worst": 0.0, "shallow_not_idem": 0, "deep_pts": 0, "deep_viol": 0, "deep_worst": 0.0, "deep_not_idem": 0, "free_pts": 0, "free_moved": 0, "floor_viol": 0, "floor_detail": ""}
	for case_i in (120 if _heavy() else 60):
		var site: Vector2 = sites[case_i % sites.size()]
		var h: float = _sb.height_at(site.x, site.y)
		var n_rocks: int = 2 if case_i % 3 != 0 else 3
		var recs: Array = []
		var anchor := Vector3(site.x, h + rng.randf_range(-0.5, 1.0), site.y)
		for k in n_rocks:
			var size := Vector3(rng.randf_range(1.5, 7.0), rng.randf_range(1.0, 6.0), rng.randf_range(1.5, 7.0))
			var off := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.6, 0.6), rng.randf_range(-1.0, 1.0)) * (3.0 if k > 0 else 0.0)
			var rnd: float = rng.randf() * minf(size.x, minf(size.y, size.z)) * 0.5
			recs.append(_rock_rec("w%d_%d" % [case_i, k], anchor + off, size, _rand_quat(rng), rnd))
		var syn: Dictionary = _synthetic(recs)
		var f: SeabedField = syn["sb"]
		var ref: RefField = syn["ref"]
		cases += 1
		for q_i in 150:
			var r: float = rng.randf_range(0.03, 1.2) if rng.randf() < 0.9 else rng.randf_range(1.2, 2.5)
			var p: Vector3 = anchor + Vector3(rng.randf_range(-7.0, 7.0), rng.randf_range(-4.0, 4.0), rng.randf_range(-7.0, 7.0))
			p.y = maxf(p.y, f.height_at(p.x, p.z))  # a fish is never below the seabed
			var a: Vector3 = f.resolve(p, r)
			var start_pen: float = r - minf(ref.clear_all(p), p.y - f.height_at(p.x, p.z) + 100.0)
			var key: String = "free"
			if a.distance_to(p) > 1e-9:
				key = "shallow" if start_pen <= 0.8 else "deep"
			var pen: float = r - ref.clear_all(a)
			var b2: Vector3 = f.resolve(a, r)
			var dev: float = a.distance_to(b2)
			if f.height_at(a.x, a.z) - a.y > 1e-4:
				st["floor_viol"] = int(st["floor_viol"]) + 1
				st["floor_detail"] = "case %d r %.3f p %s -> %s below_by %.9f again %s ref %s" % [case_i, r, p, a, f.height_at(a.x, a.z) - a.y, f.resolve(a, r), f.resolve_reference(p, r)]
			if key == "free":
				st["free_pts"] = int(st["free_pts"]) + 1
				if pen > PEN_TOL_M:
					st["free_moved"] = int(st["free_moved"]) + 1  # a start the sim treated as free is inside a rock: sdf/engine disagree
				continue
			st[key + "_pts"] = int(st[key + "_pts"]) + 1
			if pen > PEN_TOL_M:
				st[key + "_viol"] = int(st[key + "_viol"]) + 1
				st[key + "_worst"] = maxf(float(st[key + "_worst"]), pen)
			if dev > PEN_TOL_M:
				st[key + "_not_idem"] = int(st[key + "_not_idem"]) + 1
	st["cases"] = cases
	_stat("wedge_random_points", st)
	assert_eq(int(st["free_moved"]), 0, "a start that resolve() leaves in place must not be inside a rock")
	assert_eq(int(st["floor_viol"]), 0, "centre below the seabed after resolve: %s" % st["floor_detail"])
	assert_true(float(st["shallow_viol"]) <= 0.002 * float(maxi(int(st["shallow_pts"]), 1)), "shallow-start wedge points left inside a rock: %d of %d (worst %.4f m)" % [st["shallow_viol"], st["shallow_pts"], st["shallow_worst"]])
	assert_true(float(st["shallow_not_idem"]) <= 0.002 * float(maxi(int(st["shallow_pts"]), 1)), "resolve not idempotent for %d of %d shallow wedge points" % [st["shallow_not_idem"], st["shallow_pts"]])


func test_a_sphere_driven_into_a_seabed_rock_rock_wedge_stays_outside() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var swims: int = 0
	var inside: int = 0
	var worst: float = 0.0
	var details: Array[String] = []
	var sites: Array[Vector2] = [Vector2(40.0, -200.0), Vector2(-100.0, -60.0), Vector2(120.0, 40.0), Vector2(-60.0, 190.0)]
	for case_i in (80 if _heavy() else 40):
		var site: Vector2 = sites[case_i % sites.size()]
		var h: float = _sb.height_at(site.x, site.y)
		var recs: Array = []
		var anchor := Vector3(site.x, h + rng.randf_range(0.0, 0.8), site.y)
		for k in 2:
			var size := Vector3(rng.randf_range(2.0, 6.0), rng.randf_range(1.5, 5.0), rng.randf_range(2.0, 6.0))
			var off := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)) * (2.5 if k > 0 else 0.0)
			recs.append(_rock_rec("d%d_%d" % [case_i, k], anchor + off, size, Quaternion(Vector3.UP, rng.randf() * TAU), rng.randf() * 0.4 * minf(size.x, size.z) * 0.5))
		var syn: Dictionary = _synthetic(recs)
		var f: SeabedField = syn["sb"]
		var ref: RefField = syn["ref"]
		for s_i in 6:
			var r: float = [0.05, 0.15, 0.35, 0.8, 2.0][rng.randi_range(0, 4)]
			var speed: float = [3.0, 10.8, 22.9][rng.randi_range(0, 2)]
			var ang: float = rng.randf() * TAU
			var start := anchor + Vector3(cos(ang), 0.0, sin(ang)) * 14.0
			start.y = maxf(h + r + 0.05, anchor.y)
			start = f.resolve(start, r)
			# aim at the seabed-level core of the wedge, slightly downward so the floor and both rocks act together
			var aim := Vector3(anchor.x, h - 0.2, anchor.z)
			var dir: Vector3 = (aim - start).normalized()
			var p: Vector3 = start
			var bad: bool = false
			var swim_worst: float = 0.0
			for t in 160:
				p = _advance(f, p, p + dir * speed * DT, r, false)[0]
				var pen: float = r - ref.clear_all(p)
				if pen > PEN_TOL_M:
					bad = true
					swim_worst = maxf(swim_worst, pen)
			worst = maxf(worst, swim_worst)
			swims += 1
			if bad:
				inside += 1
				details.append("case %d r %.2f speed %.1f worst %.4f" % [case_i, r, speed, swim_worst])
	_stat("wedge_driven", {"swims": swims, "inside_swims": inside, "worst_pen_m": worst, "details": details})
	assert_eq(inside, 0, "driven wedge swims that were inside a rock at some tick (worst %.4f m)" % worst)


func test_real_overlapping_baked_pairs_hold_spheres_outside_the_union() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	var rocks: Array[int] = []
	for rule: int in RULES:
		rocks.append_array(_by_rule.get(rule, []))
	# find overlapping pairs (bounding boxes intersect and the surfaces really overlap at the bounds centre line)
	var pairs: Array[Vector2i] = []
	for a_i in rocks.size():
		var a: int = rocks[a_i]
		var ba: AABB = _ref.bounds[a]
		for b_i in range(a_i + 1, mini(a_i + 40, rocks.size())):
			var b: int = rocks[b_i]
			if ba.intersects(_ref.bounds[b]):
				var mid: Vector3 = (ba.get_center() + _ref.bounds[b].get_center()) * 0.5
				if _ref.sdf(a, mid) < 0.5 and _ref.sdf(b, mid) < 0.5:
					pairs.append(Vector2i(a, b))
	_stat("real_pairs", {"overlapping_pairs_found": pairs.size()})
	var st: Dictionary = {"shallow_pts": 0, "shallow_viol": 0, "shallow_worst": 0.0, "deep_pts": 0, "deep_viol": 0, "deep_worst": 0.0, "free_pts": 0, "free_inside": 0}
	for pr: Vector2i in pairs:
		var mid: Vector3 = (_ref.bounds[pr.x].get_center() + _ref.bounds[pr.y].get_center()) * 0.5
		for k in (60 if _heavy() else 8):
			var r: float = [0.05, 0.15, 0.35, 0.8][rng.randi_range(0, 3)]
			var p: Vector3 = mid + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 2.0
			p.y = maxf(p.y, _sb.height_at(p.x, p.z))  # a fish is never below the seabed
			var start_pen: float = r - _ref.clear_all(p)
			var q: Vector3 = _sb.resolve(p, r)
			var key: String = "free" if q.distance_to(p) < 1e-9 else ("shallow" if start_pen <= 0.8 else "deep")
			var pen: float = r - _ref.clear_all(q)
			if key == "free":
				st["free_pts"] = int(st["free_pts"]) + 1
				if pen > PEN_TOL_M:
					st["free_inside"] = int(st["free_inside"]) + 1
				continue
			st[key + "_pts"] = int(st[key + "_pts"]) + 1
			if pen > PEN_TOL_M:
				st[key + "_viol"] = int(st[key + "_viol"]) + 1
				st[key + "_worst"] = maxf(float(st[key + "_worst"]), pen)
	_stat("real_pairs_resolve", st)
	assert_true(pairs.size() > 0, "the reef has overlapping baked rocks to test")
	assert_eq(int(st["free_inside"]), 0, "a start resolve() leaves in place is inside a rock")
	assert_true(float(st["shallow_viol"]) <= 0.002 * float(maxi(int(st["shallow_pts"]), 1)), "shallow-start points left inside a rock union: %d of %d (worst %.4f m)" % [st["shallow_viol"], st["shallow_pts"], st["shallow_worst"]])


# ------------------------------------------------------------------------------------------------ NPC brains

## Creatures alive in `w` as {id: SimEntity}.
func _live(w: SimWorld) -> Array[SimEntity]:
	return S3.creatures(w)


## A free spot next to rock `i` (3 m beyond its bounding box on a random side) for a body of radius r + extra clearance.
func _spot_near(i: int, r: float, clearance: float, rng: RandomNumberGenerator) -> Vector3:
	var bb: AABB = _ref.bounds[i]
	var cen: Vector3 = bb.get_center()
	for attempt in 30:
		var a: float = rng.randf() * TAU
		var d: float = bb.size.length() * 0.5 * rng.randf_range(0.9, 1.15) + 1.0
		var p := cen + Vector3(cos(a), 0.0, sin(a)) * d
		p.y = maxf(cen.y + rng.randf_range(-0.5, 0.5) * bb.size.y, _sb.height_at(p.x, p.z) + clearance + r)
		if absf(p.x) < 270.0 and absf(p.z) < 270.0 and p.y < -r - 0.5 and _sb.resolve(p, r).distance_to(p) < 1e-6 and _ref.clear(p) > r + 0.1:
			return p
	return Vector3.INF


func test_npc_brains_around_rocks_never_end_inside_a_proxy_and_never_stay_stuck() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var groups: Array = [
		{"species": &"small_reef_fish", "rule": 3, "n": 10},
		{"species": &"silver_schooling_fish", "rule": 3, "n": 8},
		{"species": &"puffer", "rule": 10, "n": 8},
		{"species": &"grouper", "rule": 10, "n": 8},
		{"species": &"barracuda", "rule": 8, "n": 8},
		{"species": &"shark", "rule": 14, "n": 8},
	]
	var ticks: int = 2400
	var agg: Dictionary = {"npcs": 0, "tick_checks": 0, "violations": 0, "worst_pen_m": 0.0, "stuck": [], "min_extent_m": INF}
	for gi in groups.size():
		var g: Dictionary = groups[gi]
		var w: SimWorld = S3.make_world(8000 + gi, {"vitals": false})
		var ids: Array[int] = []
		for i: int in _pick(int(g["rule"]), int(g["n"]) if _heavy() else int(g["n"]) / 2, rng):
			var sp: Dictionary = w.content.get_species(g["species"])
			var lm: Dictionary = sp["length_m"]
			var len_m: float = sqrt(float(lm["min"]) * float(lm["max"]))
			var r_est: float = len_m * 0.25
			var p: Vector3 = _spot_near(i, r_est, float(sp["behaviour"].get("seabed_clearance_m", 1.0)) * 0.5, rng)
			if not p.is_finite():
				continue
			ids.append(S3.npc_at(w, g["species"], p, len_m, Vector3(rng.randfn(), 0.0, rng.randfn()).normalized()).id)
		var trail: Dictionary = {}
		for id: int in ids:
			trail[id] = []
		for t in ticks:
			w.step()
			for id: int in ids:
				var e: SimEntity = w.get_entity(id)
				if e == null or not e.alive:
					continue
				agg["tick_checks"] = int(agg["tick_checks"]) + 1
				var pen: float = w.collision_radius(e) - _ref.clear(e.position)
				if pen > PEN_TOL_M:
					agg["violations"] = int(agg["violations"]) + 1
					agg["worst_pen_m"] = maxf(float(agg["worst_pen_m"]), pen)
				if t % 30 == 0:
					(trail[id] as Array).append(e.position)
		for id: int in ids:
			var e2: SimEntity = w.get_entity(id)
			if e2 == null or not e2.alive:
				continue
			agg["npcs"] = int(agg["npcs"]) + 1
			var tr: Array = trail[id]
			var last: Array = tr.slice(maxi(tr.size() - 40, 0))  # last 40 s
			var lo: Vector3 = last[0]
			var hi: Vector3 = last[0]
			for v: Vector3 in last:
				lo = lo.min(v)
				hi = hi.max(v)
			var extent: float = lo.distance_to(hi)
			agg["min_extent_m"] = minf(float(agg["min_extent_m"]), extent)
			if extent < 1.0:
				(agg["stuck"] as Array).append("%s#%d at %s" % [g["species"], id, e2.position])
	_stat("npc_brains", agg)
	assert_eq(int(agg["violations"]), 0, "NPC ticks spent inside a proxy (worst %.4f m)" % float(agg["worst_pen_m"]))
	assert_true(int(agg["npcs"]) >= (30 if _heavy() else 15), "enough NPCs survived the run (%d)" % int(agg["npcs"]))
	assert_eq((agg["stuck"] as Array).size(), 0, "NPCs that stayed within 1 m for the last 40 s: %s" % [agg["stuck"]])


func test_predators_chasing_bait_behind_a_rock_are_blocked_but_free_again_afterwards() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2468
	var viol: int = 0
	var worst: float = 0.0
	var runs: int = 0
	var stuck: Array[String] = []
	var closest: Array[float] = []
	for rule: int in [3, 8, 10, 14]:
		for i: int in _pick(rule, 3 if _heavy() else 2, rng):
			var bb: AABB = _ref.bounds[i]
			var cen: Vector3 = bb.get_center()
			var half: float = bb.size.length() * 0.5
			var a: float = rng.randf() * TAU
			var dir := Vector3(cos(a), 0.0, sin(a))
			var w: SimWorld = S3.make_world(9000 + i, {"vitals": false})
			var species: StringName = &"shark" if rule == 14 or rule == 10 else &"barracuda"
			var sp: Dictionary = w.content.get_species(species)
			var len_m: float = (float(sp["length_m"]["min"]) + float(sp["length_m"]["max"])) * 0.5
			var pred_pos := cen - dir * (half + 5.0)
			var bait_pos := cen + dir * (half + 1.5)
			pred_pos.y = maxf(cen.y, _sb.height_at(pred_pos.x, pred_pos.z) + 4.0)
			bait_pos.y = pred_pos.y
			if absf(pred_pos.x) > 270.0 or absf(pred_pos.z) > 270.0 or absf(bait_pos.x) > 270.0 or absf(bait_pos.z) > 270.0:
				continue
			if _sb.resolve(pred_pos, len_m * 0.25).distance_to(pred_pos) > 1e-6 or _sb.resolve(bait_pos, 0.1).distance_to(bait_pos) > 1e-6:
				continue
			var pred: SimEntity = S3.npc_at(w, species, pred_pos, len_m, dir)
			var bait: SimEntity = S3.player_at(w, bait_pos, S3.xp_for_length(w.content, 0.35), -dir)
			var best: float = INF
			var trail: Array[Vector3] = []
			runs += 1
			for t in 2700:
				if t == 900:
					w.remove_entity(bait.id)
				else:
					if w.get_entity(bait.id) != null:
						bait.position = bait_pos
						bait.velocity = Vector3.ZERO
						bait.hp = bait.max_hp
				w.step()
				if not pred.alive or w.get_entity(pred.id) == null:
					break
				var pen: float = w.collision_radius(pred) - _ref.clear(pred.position)
				if pen > PEN_TOL_M:
					viol += 1
					worst = maxf(worst, pen)
				if t < 900:
					best = minf(best, pred.position.distance_to(bait_pos))
				if t % 30 == 0 and t >= 1500:
					trail.append(pred.position)
			closest.append(best)
			if trail.size() > 10:
				var lo: Vector3 = trail[0]
				var hi: Vector3 = trail[0]
				for v: Vector3 in trail:
					lo = lo.min(v)
					hi = hi.max(v)
				if lo.distance_to(hi) < 1.0:
					stuck.append("%s near %s (%s) at %s" % [species, _ref.ids[i], RULE_NAMES[rule], pred.position])
	_stat("predator_bait", {"runs": runs, "violations": viol, "worst_pen_m": worst, "stuck_after_bait_removed": stuck, "closest_to_bait_m": closest})
	assert_true(runs >= (6 if _heavy() else 4), "enough chase setups (%d)" % runs)
	assert_eq(viol, 0, "predator ticks inside a proxy (worst %.4f m)" % worst)
	assert_eq(stuck.size(), 0, "predators still stuck at the rock 20 s after the bait vanished: %s" % [stuck])


func test_boss_brain_patrol_and_dashes_in_the_abyss_never_enter_a_rock() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 60606
	var viol: int = 0
	var worst: float = 0.0
	var dashes: int = 0
	var runs: int = 0
	var stuck: Array[String] = []
	for k in 60:
		if runs >= (6 if _heavy() else 3):
			break
		var w: SimWorld = S3.make_world(7000 + k, {"vitals": false})
		var rocks: Array[int] = _pick(16, 1, rng)
		var i: int = rocks[0]
		var bb: AABB = _ref.bounds[i]
		var cen: Vector3 = bb.get_center()
		var a: float = rng.randf() * TAU
		var dir := Vector3(cos(a), 0.0, sin(a))
		var boss_pos := cen - dir * (bb.size.length() * 0.5 + 14.0)
		boss_pos.y = maxf(cen.y, _sb.height_at(boss_pos.x, boss_pos.z) + 6.5)
		var bait_pos := cen + dir * (bb.size.length() * 0.5 + 4.0)
		bait_pos.y = boss_pos.y
		if absf(boss_pos.x) > 270.0 or absf(boss_pos.z) > 270.0 or absf(bait_pos.x) > 270.0 or absf(bait_pos.z) > 270.0:
			continue
		if _sb.resolve(boss_pos, 2.5).distance_to(boss_pos) > 1e-6 or _sb.resolve(bait_pos, 0.6).distance_to(bait_pos) > 1e-6:
			continue
		var boss: SimEntity = S3.npc_at(w, &"giant_shark", boss_pos, 10.0, dir)
		var bait: SimEntity = S3.player_at(w, bait_pos, S3.xp_for_length(w.content, 3.0), -dir)
		runs += 1
		var trail: Array[Vector3] = []
		var ev_from: int = 0
		for t in 2400:
			bait.position = bait_pos
			bait.velocity = Vector3.ZERO
			bait.hp = bait.max_hp
			w.step()
			if t % 30 == 29:
				for ev: SimEvent in w.events_since(ev_from):
					if ev.type == SimEvent.Type.DASH_STARTED and ev.entity_id == boss.id:
						dashes += 1
				ev_from = w.tick
			var pen: float = w.collision_radius(boss) - _ref.clear(boss.position)
			if pen > PEN_TOL_M:
				viol += 1
				worst = maxf(worst, pen)
			if t % 30 == 0 and t >= 1200:
				trail.append(boss.position)
		var lo: Vector3 = trail[0]
		var hi: Vector3 = trail[0]
		for v: Vector3 in trail:
			lo = lo.min(v)
			hi = hi.max(v)
		if lo.distance_to(hi) < 1.0:
			stuck.append("boss at %s next to %s" % [boss.position, _ref.ids[i]])
	_stat("boss_brain", {"runs": runs, "boss_dashes": dashes, "violations": viol, "worst_pen_m": worst, "stuck_last_40s": stuck})
	assert_true(runs >= (6 if _heavy() else 3), "enough boss setups (%d)" % runs)
	assert_eq(viol, 0, "boss ticks inside a proxy (worst %.4f m)" % worst)
	assert_eq(stuck.size(), 0, "boss never moved in the last 40 s: %s" % [stuck])


# ------------------------------------------------------------------------------------------------ spawns

func test_player_spawns_respawns_and_spawner_npcs_are_never_inside_a_proxy() -> void:
	_setup()
	# 1) the three map spawn points, raw and through SimWorld.spawn_player
	var w0: SimWorld = S3.make_world(1, {"vitals": false})
	var raw_hits: int = 0
	for k in 3:
		var sp: Vector3 = S3.spawn_point(w0, k)
		var id: int = w0.spawn_player(k)
		var e: SimEntity = w0.get_entity(id)
		var r: float = w0.collision_radius(e)
		assert_true(_ref.clear_all(e.position) >= r - PEN_TOL_M, "player spawn %d (%s) ends inside a proxy" % [k, e.position])
		if _ref.clear_all(sp) < r:
			raw_hits += 1
		# every band radius at the raw spawn point resolves outside
		for rr: float in [0.05, 0.15, 0.35, 0.8]:
			var q: Vector3 = _sb.resolve(sp, rr)
			assert_true(_ref.clear_all(q) >= rr - PEN_TOL_M, "spawn %d radius %.2f resolves inside a proxy" % [k, rr])
	# 2) death + respawn from random places (nearest spawn, constrained)
	var rng := RandomNumberGenerator.new()
	rng.seed = 123
	var respawns: int = 0
	var bad_resp: int = 0
	for k in (12 if _heavy() else 6):
		var w: SimWorld = S3.make_world(100 + k, {"vitals": false})
		var id2: int = w.spawn_player(k)
		var p: SimEntity = w.get_entity(id2)
		p.position = Vector3(rng.randf_range(-250.0, 250.0), -20.0, rng.randf_range(-250.0, 250.0))
		p.hp = 0.0
		for t in 400:
			w.step()
			if p.alive and t > 5:
				break
		if p.alive:
			respawns += 1
			if _ref.clear_all(p.position) < w.collision_radius(p) - PEN_TOL_M:
				bad_resp += 1
	assert_eq(bad_resp, 0, "respawned players inside a proxy")
	assert_true(respawns >= (8 if _heavy() else 4), "players did respawn (%d)" % respawns)
	# 3) NpcSpawner populations over many seeds and zones, at spawn time and after some ticks
	var spawned: int = 0
	var inside: int = 0
	var worst: float = 0.0
	var by_species: Dictionary = {}
	for seed_i in (14 if _heavy() else 6):
		var w2: SimWorld = S3.make_world(500 + seed_i, {"real_spawners": true, "vitals": false})
		for t in 3:
			w2.step()
		var seen: Dictionary = {}
		for e2: SimEntity in S3.creatures(w2):
			var pen: float = w2.collision_radius(e2) - _ref.clear_all(e2.position)
			spawned += 1
			by_species[str(e2.species_id)] = int(by_species.get(str(e2.species_id), 0)) + 1
			seen[e2.id] = true
			if pen > PEN_TOL_M:
				inside += 1
				worst = maxf(worst, pen)
		if seed_i < 4:
			for t in 900:
				w2.step()
			for e3: SimEntity in S3.creatures(w2):
				var pen2: float = w2.collision_radius(e3) - _ref.clear_all(e3.position)
				if pen2 > PEN_TOL_M:
					inside += 1
					worst = maxf(worst, pen2)
	_stat("spawns", {"raw_spawn_points_within_radius_of_a_proxy": raw_hits, "respawns": respawns, "spawner_npcs_checked": spawned, "inside": inside, "worst_pen_m": worst, "by_species": by_species})
	assert_eq(inside, 0, "spawner NPCs inside a proxy (worst %.4f m)" % worst)
	assert_true(spawned >= (300 if _heavy() else 120), "the spawners produced a population (%d)" % spawned)


# ------------------------------------------------------------------------------------------------ soft flora / hiding

func test_no_soft_flora_has_a_collision_proxy() -> void:
	_setup()
	var db: ContentDB = S5.content()
	var dressing: Dictionary = db.get_dressing(&"reef")
	var solid: Dictionary = dressing["solid_pieces"]
	for pid: String in solid:
		var lower: String = pid.to_lower()
		var soft: bool = false
		for word: String in ["kelp", "coral", "grass", "sponge", "frond", "anemone", "fan", "weed", "plant"]:
			if lower.contains(word):
				soft = true
		assert_false(soft, "solid_pieces lists the soft-looking piece %s" % pid)
	var tags: Dictionary = {}
	for o: Variant in db.get_proxies(&"reef"):
		tags[str((o as Dictionary).get("tag", ""))] = int(tags.get(str((o as Dictionary).get("tag", "")), 0)) + 1
		assert_eq(str((o as Dictionary)["kind"]), "obb", "baked proxy kind of %s" % (o as Dictionary)["id"])
	for tag: String in tags:
		assert_true(tag == "rock" or tag == "boat", "baked proxy tag '%s' (%d)" % [tag, tags[tag]])
	# scatter rules that place soft flora (by piece name) have no baked proxies of their own id range
	var soft_rules: Array[int] = []
	for ri in (dressing["scatter"] as Array).size():
		var rule: Dictionary = dressing["scatter"][ri]
		var only_soft: bool = true
		for pc: Dictionary in rule["pieces"]:
			if solid.has(str(pc["id"])):
				only_soft = false
		if only_soft:
			soft_rules.append(ri)
	var leaked: int = 0
	for o: Variant in db.get_proxies(&"reef"):
		var id: String = str((o as Dictionary)["id"])
		if id.begins_with("s") and soft_rules.has(int(id.substr(1, 2))):
			leaked += 1
	_stat("soft_flora", {"proxy_tags": tags, "soft_only_rules": soft_rules.size(), "proxies_in_soft_only_rules": leaked})
	assert_eq(leaked, 0, "proxies were baked for rules that place only soft flora")


func test_a_band1_fish_can_enter_every_hiding_volume_and_hide() -> void:
	_setup()
	var w0: SimWorld = S3.make_world(3, {"vitals": false})
	var vols: Array = S3.hiding_volumes(w0)
	assert_true(vols.size() >= 8, "the reef has hiding volumes (%d)" % vols.size())
	var db: ContentDB = S5.content()
	var map_free: SeabedField = SeabedField.from_map(db.get_map(&"reef"))
	var report: Array = []
	for v: Variant in vols:
		var rec: Dictionary = v
		var mm: Array[Vector3] = S3.box_min_max(rec)
		var lo: Vector3 = mm[0]
		var hi: Vector3 = mm[1]
		var r: float = 0.05
		# free fraction of the volume for a B1 sphere, with and without the baked proxies
		var total: int = 0
		var free_with: int = 0
		var free_without: int = 0
		var best: Vector3 = Vector3.INF
		var best_d: float = INF
		var cen: Vector3 = (lo + hi) * 0.5
		var step: float = 0.75 if _heavy() else 1.5
		var x: float = lo.x + 0.1
		while x < hi.x:
			var z: float = lo.z + 0.1
			while z < hi.z:
				var y: float = lo.y + 0.1
				while y < hi.y:
					var p := Vector3(x, y, z)
					if y > _sb.height_at(x, z) + 0.3:
						total += 1
						if _sb.resolve(p, r).distance_to(p) < 1e-6:
							free_with += 1
							if p.distance_to(cen) < best_d:
								best_d = p.distance_to(cen)
								best = p
						if map_free.resolve(p, r).distance_to(p) < 1e-6:
							free_without += 1
					y += step
				z += step
			x += step
		assert_true(total > 0 and free_with > 0, "volume %s has free space for a B1 fish (%d of %d points)" % [rec["id"], free_with, total])
		# swim in from 8 directions
		var reached_dirs: int = 0
		var hidden_dirs: int = 0
		if best.is_finite():
			for d_i in (8 if _heavy() else 4):
				var a: float = TAU * float(d_i) / float(8 if _heavy() else 4)
				var start: Vector3 = best + Vector3(cos(a), 0.0, sin(a)) * 14.0
				start.y = maxf(best.y, _sb.height_at(start.x, start.z) + 0.6)
				if _sb.resolve(start, r).distance_to(start) > 1e-6 or absf(start.x) > 280.0 or absf(start.z) > 280.0:
					continue
				var w: SimWorld = S3.make_world(4000 + d_i, {"vitals": false})
				w.brains_enabled = false
				var e: SimEntity = S3.player_at(w, start, 0.0, best - start)
				var inside: bool = false
				for t in 220:
					w.submit(SimCommand.move(e.id, (best - e.position), 1.0))
					w.step()
					if e.position.x >= lo.x and e.position.x <= hi.x and e.position.y >= lo.y and e.position.y <= hi.y and e.position.z >= lo.z and e.position.z <= hi.z:
						inside = true
						break
				if inside:
					reached_dirs += 1
					if e.hidden:
						hidden_dirs += 1
		report.append({"volume": rec["id"], "free_with": free_with, "free_without": free_without, "total": total, "dirs_in": reached_dirs, "dirs_hidden": hidden_dirs})
		assert_true(reached_dirs >= 1, "volume %s: a B1 fish swam in from %d of 8 directions" % [rec["id"], reached_dirs])
		assert_true(float(free_with) >= 0.8 * float(free_without), "volume %s: baked rocks removed %d of %d free points" % [rec["id"], free_without - free_with, free_without])
		if reached_dirs > 0:
			assert_true(hidden_dirs == reached_dirs, "volume %s: a fish inside the volume is hidden (%d of %d)" % [rec["id"], hidden_dirs, reached_dirs])
	_stat("hiding_volumes", {"volumes": report})


# ------------------------------------------------------------------------------------------------ food bits / plankton

func test_food_bits_spawn_outside_rocks_and_report_how_many_drift_in() -> void:
	_setup()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var spawned: int = 0
	var inside_at_spawn: int = 0
	var worst_spawn: float = 0.0
	var drifted_in: int = 0
	var worst_drift: float = 0.0
	var victims: int = 0
	for rule: int in RULES:
		for i: int in _pick(rule, 8 if _heavy() else 3, rng):
			var w: SimWorld = S3.make_world(6000 + i, {"vitals": false})
			w.brains_enabled = false
			var species: StringName = &"shark"
			var p: Vector3 = _spot_near(i, 0.7, 0.5, rng)
			if not p.is_finite():
				continue
			# squeeze the victim right against the surface
			var v: SimEntity = S3.npc_at(w, species, p, 3.0)
			var cen: Vector3 = _ref.bounds[i].get_center()
			var toward: Vector3 = (cen - p).normalized()
			var q: Vector3 = p
			for s_i in 40:
				var nxt: Vector3 = _sb.resolve(q + toward * 0.15, w.collision_radius(v))
				q = nxt
			v.position = q
			victims += 1
			v.hp = 0.0
			w.step()
			var bits: Array[SimEntity] = S3.food_bits(w)
			var ids: Array[int] = []
			for b: SimEntity in bits:
				ids.append(b.id)
				spawned += 1
				var pen: float = w.collision_radius(b) - _ref.clear(b.position)
				if pen > PEN_TOL_M:
					inside_at_spawn += 1
					worst_spawn = maxf(worst_spawn, pen)
			var flagged: Dictionary = {}
			for t in 960:
				w.step()
				for id: int in ids:
					var b2: SimEntity = w.get_entity(id)
					if b2 == null:
						continue
					var depth: float = -_ref.clear(b2.position)
					if depth > 0.02 and not flagged.has(id):
						flagged[id] = true
						drifted_in += 1
					worst_drift = maxf(worst_drift, depth)
	_stat("food_bits", {"victims": victims, "bits": spawned, "inside_at_spawn": inside_at_spawn, "worst_spawn_pen_m": worst_spawn, "bits_that_drifted_into_a_rock": drifted_in, "worst_drift_depth_m": worst_drift})
	assert_true(spawned >= (40 if _heavy() else 15), "food bits were produced (%d)" % spawned)
	assert_eq(inside_at_spawn, 0, "food bits spawned inside a rock (worst %.4f m)" % worst_spawn)
	# fix round: SimWorld._drift resolves the bits against the obstacles every tick
	assert_eq(drifted_in, 0, "food bits that drifted more than 2 cm into a rock (worst %.4f m)" % worst_drift)


func test_no_plankton_cell_is_completely_buried_in_rock() -> void:
	_setup()
	var w: SimWorld = S3.make_world(2, {"vitals": false})
	var pf: PlanktonField = w.plankton
	assert_not_null(pf, "the reef has a plankton field")
	if pf == null:
		return
	var cells: int = 0
	var buried: int = 0
	var half_buried: int = 0
	var worst: float = 0.0
	for c in pf.cell_count():
		if not pf.is_plankton_cell(c):
			continue
		cells += 1
		var cen: Vector3 = pf.cell_center(c)
		var solid: int = 0
		var pts: int = 0
		for dx in [-3.0, 0.0, 3.0]:
			for dy in [-3.0, 0.0, 3.0]:
				for dz in [-3.0, 0.0, 3.0]:
					var p: Vector3 = cen + Vector3(dx, dy, dz)
					if p.y > _sb.height_at(p.x, p.z):
						pts += 1
						if _ref.clear(p) < 0.0:
							solid += 1
		if pts >= 8:
			var frac: float = float(solid) / float(pts)
			worst = maxf(worst, frac)
			if solid == pts:
				buried += 1
			if frac > 0.5:
				half_buried += 1
	_stat("plankton", {"plankton_cells": cells, "fully_buried": buried, "over_half_solid": half_buried, "worst_solid_fraction": worst})
	assert_true(cells > 0, "plankton cells exist")
	assert_true(float(buried) <= 0.001 * float(cells), "plankton cells whose every sample is inside a rock: %d of %d (unreachable plankton)" % [buried, cells])


# ------------------------------------------------------------------------------------------------ determinism

func _scripted_run(seed_value: int, ticks: int, hashes: PackedInt64Array) -> void:
	var w: SimWorld = S3.make_world(seed_value, {"real_spawners": true, "vitals": true})
	var p: SimEntity = S3.player_at(w, Vector3(0.0, -6.0, -250.0), 0.0, Vector3(0.0, 0.0, 1.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for t in ticks:
		if t % 45 == 0:
			var a: float = rng.randf() * TAU
			w.submit(SimCommand.move(p.id, Vector3(cos(a), rng.randf_range(-0.3, 0.1), sin(a)), 1.0))
			w.submit(SimCommand.boost(p.id, rng.randf() < 0.5))
		w.step()
		if t % 150 == 149:
			hashes.append(w.state_hash())


func test_state_hash_is_identical_for_two_identical_runs_on_the_baked_map() -> void:
	_setup()
	var h1 := PackedInt64Array()
	var h2 := PackedInt64Array()
	var h3 := PackedInt64Array()
	var run_ticks: int = 900 if _heavy() else 450
	_scripted_run(77, run_ticks, h1)
	_scripted_run(77, run_ticks, h2)
	_scripted_run(78, run_ticks, h3)
	_stat("determinism", {"checkpoints": h1.size(), "equal": h1 == h2, "other_seed_differs": h1 != h3})
	assert_eq(h1.size(), run_ticks / 150, "one checkpoint per 150 ticks recorded")
	assert_true(h1 == h2, "two identical runs diverge: %s vs %s" % [h1, h2])
	assert_true(h1 != h3, "a different seed gives a different hash trail")
	# two independently loaded ContentDBs bake the same collision world
	var a: SeabedField = SeabedField.from_map(ContentDB.load_from_dir("res://data").get_map(&"reef"), ContentDB.load_from_dir("res://data").get_proxies(&"reef"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var diff: int = 0
	for k in (3000 if _heavy() else 1000):
		var p := Vector3(rng.randf_range(-290.0, 290.0), 0.0, rng.randf_range(-290.0, 290.0))
		p.y = _sb.height_at(p.x, p.z) + rng.randf() * 4.0
		var r: float = rng.randf_range(0.03, 2.5)
		if a.resolve(p, r) != _sb.resolve(p, r):
			diff += 1
	assert_eq(diff, 0, "independently built fields differ on resolve")


# ------------------------------------------------------------------------------------------------ baked file freshness

func test_freshness_check_reports_a_tampered_copy_of_the_proxies() -> void:
	_setup()
	var db: ContentDB = S5.content()
	var fresh: Array[Dictionary] = DressingProxies.derive(db.get_dressing(&"reef").duplicate(true), db.get_map(&"reef").duplicate(true), MapDressing.piece_index())
	var dressing_seed: int = int(db.get_dressing(&"reef").get("seed", 0))
	var good: String = DressingProxies.proxies_text(fresh, "reef", dressing_seed)
	var shipped: String = FileAccess.get_file_as_string("res://data/maps/reef_proxies.json")
	# the tool's check is a byte comparison of the regenerated text with the shipped file
	assert_true(good == shipped, "shipped reef_proxies.json is byte-identical to a regeneration (bake_proxies --check semantics)")
	var tampers: Dictionary = {}
	var t1: Array[Dictionary] = fresh.duplicate(true)
	(t1[5]["center"] as Array)[1] = float(t1[5]["center"][1]) + 0.01
	tampers["centre moved 1 cm"] = t1
	var t2: Array[Dictionary] = fresh.duplicate(true)
	t2[100]["round"] = float(t2[100]["round"]) + 0.01
	tampers["round +0.01"] = t2
	var t3: Array[Dictionary] = fresh.duplicate(true)
	t3.remove_at(700)
	tampers["record dropped"] = t3
	var t4: Array[Dictionary] = fresh.duplicate(true)
	(t4[900]["size"] as Array)[0] = float(t4[900]["size"][0]) * 1.05
	tampers["size x1.05"] = t4
	var t5: Array[Dictionary] = fresh.duplicate(true)
	var q: Array = t5[300]["rot"]
	t5[300]["rot"] = [q[0], q[1], q[2] * -1.0, q[3]] if absf(float(q[2])) > 1e-6 else [q[0] + 0.001, q[1], q[2], q[3]]
	tampers["rotation changed"] = t5
	var t6: Array[Dictionary] = fresh.duplicate(true)
	t6.reverse()
	tampers["order reversed"] = t6
	var missed: Array[String] = []
	for name: String in tampers:
		var text: String = DressingProxies.proxies_text(tampers[name], "reef", dressing_seed)
		if text == shipped:
			missed.append(name)
	_stat("freshness_tamper", {"cases": tampers.size(), "missed": missed})
	assert_eq(missed.size(), 0, "tampered copies the freshness comparison does not report: %s" % [missed])
	# and the loader notices a stale pieces.json too: any change in the index text is visible to a text compare
	var index_text: String = DressingProxies.build_index()
	assert_true(index_text == FileAccess.get_file_as_string("res://data/env/pieces.json"), "pieces.json is fresh")
	assert_true(index_text.replace("\"bounds\"", "\"boundz\"") != index_text, "tamper sanity")


# ------------------------------------------------------------------------------------------------ ContentDB validation

func _obb_ok() -> Dictionary:
	return {"id": "ok_1", "tag": "rock", "kind": "obb", "center": [0.0, -10.0, 0.0], "size": [2.0, 1.0, 3.0], "rot": [0.0, 0.0, 0.0, 1.0], "round": 0.4}


func _bad(rec: Dictionary, key: String, value: Variant) -> Dictionary:
	var out: Dictionary = rec.duplicate(true)
	if value == null:
		out.erase(key)
	else:
		out[key] = value
	return out


func test_content_db_rejects_malformed_obb_records_in_proxies_and_in_maps() -> void:
	var good: Dictionary = _obb_ok()
	var cases: Dictionary = {
		"size zero": _bad(good, "size", [2.0, 0.0, 3.0]),
		"size negative": _bad(good, "size", [2.0, -1.0, 3.0]),
		"size 2 numbers": _bad(good, "size", [2.0, 3.0]),
		"size 4 numbers": _bad(good, "size", [2.0, 3.0, 1.0, 1.0]),
		"size strings": _bad(good, "size", ["a", "b", "c"]),
		"size INF": _bad(good, "size", [2.0, INF, 3.0]),
		"size missing": _bad(good, "size", null),
		"center missing": _bad(good, "center", null),
		"center 2 numbers": _bad(good, "center", [0.0, 0.0]),
		"center string": _bad(good, "center", "origin"),
		"round too big": _bad(good, "round", 0.6),
		"round negative": _bad(good, "round", -0.01),
		"round string": _bad(good, "round", "big"),
		"rot 3 numbers": _bad(good, "rot", [0.0, 0.0, 1.0]),
		"rot 5 numbers": _bad(good, "rot", [0.0, 0.0, 0.0, 1.0, 0.0]),
		"rot not unit": _bad(good, "rot", [0.0, 0.0, 0.0, 2.0]),
		"rot zero": _bad(good, "rot", [0.0, 0.0, 0.0, 0.0]),
		"rot string": _bad(good, "rot", "identity"),
		"id missing": _bad(good, "id", null),
		"id number": _bad(good, "id", 5),
		"id empty": _bad(good, "id", ""),
		"kind unknown": _bad(good, "kind", "torus"),
		"kind missing": _bad(good, "kind", null),
		"tag number": _bad(good, "tag", 7),
	}
	var ok: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [good]}, "maps/reef_proxies.json")
	assert_eq(ok.size(), 0, "a valid obb proxies record passes: %s" % [ok])
	var accepted: Array[String] = []
	var accepted_map: Array[String] = []
	var db: ContentDB = S5.content()
	for name: String in cases:
		var errs: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [cases[name]]}, "maps/reef_proxies.json")
		if errs.is_empty():
			accepted.append(name)
		var m: Dictionary = db.get_map(&"reef").duplicate(true)
		m["obstacles"] = [cases[name]]
		var merrs: PackedStringArray = ContentDB.validate_record(&"map", m, "maps/reef.json")
		var rel: bool = false
		for e: String in merrs:
			if e.contains("obstacles"):
				rel = true
		if not rel:
			accepted_map.append(name)
	# NaN cannot come out of a JSON file (the parser has no NaN literal), but validate_record() takes Dictionaries:
	# reported, not asserted
	var nan_cases: Dictionary = {"size NaN": _bad(good, "size", [2.0, NAN, 3.0]), "center NaN": _bad(good, "center", [0.0, NAN, 0.0]), "round NaN": _bad(good, "round", NAN), "rot NaN": _bad(good, "rot", [0.0, NAN, 0.0, 1.0])}
	var nan_accepted: Array[String] = []
	for name: String in nan_cases:
		if ContentDB.validate_record(&"proxies", {"map": "reef", "obstacles": [nan_cases[name]]}, "maps/reef_proxies.json").is_empty():
			nan_accepted.append(name)
	_stat("malformed_obb", {"cases": cases.size(), "accepted_in_proxies": accepted, "accepted_in_map": accepted_map, "nan_accepted_by_validate_record": nan_accepted})
	assert_eq(accepted.size(), 0, "malformed obb records ACCEPTED in a proxies file: %s" % [accepted])
	assert_eq(accepted_map.size(), 0, "malformed obb records ACCEPTED in the map obstacles: %s" % [accepted_map])


func test_content_db_rejects_malformed_proxies_files() -> void:
	var good: Dictionary = _obb_ok()
	var other: Dictionary = _bad(good, "id", "ok_2")
	var files: Dictionary = {
		"obstacles not an array": {"map": "reef", "obstacles": {"a": 1}},
		"obstacles missing": {"map": "reef"},
		"entry not an object": {"map": "reef", "obstacles": [good, 5]},
		"duplicate ids": {"map": "reef", "obstacles": [good, good.duplicate(true)]},
		"map missing": {"obstacles": [good]},
		"map not text": {"map": 7, "obstacles": [good]},
		"seed negative": {"map": "reef", "dressing_seed": -3, "obstacles": [good]},
		"seed text": {"map": "reef", "dressing_seed": "five", "obstacles": [good]},
	}
	var ok: PackedStringArray = ContentDB.validate_record(&"proxies", {"map": "reef", "dressing_seed": 5301, "generated_by": "x", "obstacles": [good, other]}, "maps/reef_proxies.json")
	assert_eq(ok.size(), 0, "valid proxies file passes: %s" % [ok])
	var accepted: Array[String] = []
	for name: String in files:
		if ContentDB.validate_record(&"proxies", files[name], "maps/reef_proxies.json").is_empty():
			accepted.append(name)
	_stat("malformed_proxies_files", {"cases": files.size(), "accepted": accepted})
	assert_eq(accepted.size(), 0, "malformed proxies files ACCEPTED: %s" % [accepted])
	# full loader: an id repeating a map obstacle id, a proxies file for another map, and a broken record all fail the db
	var map_id: String = str(S5.map_record()["obstacles"][0]["id"])
	var e1: PackedStringArray = S5.load_with_edit(SCRATCH, "maps/reef_proxies.json", func(d: Dictionary) -> void:
		(d["obstacles"][0] as Dictionary)["id"] = map_id)
	assert_true(S5.mentions(e1, map_id), "proxy id repeating the map obstacle '%s' is rejected: %s" % [map_id, e1])
	var e2: PackedStringArray = S5.load_with_edit(SCRATCH, "maps/reef_proxies.json", func(d: Dictionary) -> void:
		d["map"] = "ghost")
	assert_false(e2.is_empty(), "a proxies file whose map field names another map is rejected")
	var e3: PackedStringArray = S5.load_with_edit(SCRATCH, "maps/reef_proxies.json", func(d: Dictionary) -> void:
		(d["obstacles"][3] as Dictionary)["size"] = [1.0, -1.0, 1.0])
	assert_false(e3.is_empty(), "a shipped-file record with a negative size fails the content load")
	var e4: PackedStringArray = S5.load_with_edit(SCRATCH, "maps/reef_proxies.json", func(d: Dictionary) -> void:
		(d["obstacles"] as Array).append((d["obstacles"] as Array)[0].duplicate(true)))
	assert_false(e4.is_empty(), "a duplicated record in the shipped proxies file fails the content load")


func test_content_db_rejects_malformed_solid_pieces() -> void:
	var base: Dictionary = S5.content().get_dressing(&"reef").duplicate(true)
	var cases: Dictionary = {
		"not an object": [1, 2],
		"recipe not an object": {"a12_boulder": 3},
		"fit zero": {"a12_boulder": {"fit": 0.0}},
		"fit negative": {"a12_boulder": {"fit": -1.0}},
		"fit huge": {"a12_boulder": {"fit": 1000.0}},
		"fit NaN": {"a12_boulder": {"fit": NAN}},
		"fit text": {"a12_boulder": {"fit": "1"}},
		"round > 1": {"a12_boulder": {"round": 1.5}},
		"round negative": {"a12_boulder": {"round": -0.2}},
		"round NaN": {"a12_boulder": {"round": NAN}},
		"tag number": {"a12_boulder": {"tag": 9}},
	}
	var ok_rec: Dictionary = base.duplicate(true)
	ok_rec["solid_pieces"] = {"a12_boulder": {"fit": 1.0, "round": 0.5, "tag": "rock"}}
	assert_eq(ContentDB.validate_record(&"dressing", ok_rec, "maps/reef_dressing.json").size(), 0, "valid solid_pieces pass")
	var accepted: Array[String] = []
	for name: String in cases:
		var rec: Dictionary = base.duplicate(true)
		rec["solid_pieces"] = cases[name]
		if ContentDB.validate_record(&"dressing", rec, "maps/reef_dressing.json").is_empty():
			accepted.append(name)
	# unknown piece id goes through the cross-reference of the full loader
	var e1: PackedStringArray = S5.load_with_edit(SCRATCH, "maps/reef_dressing.json", func(d: Dictionary) -> void:
		(d["solid_pieces"] as Dictionary)["no_such_rock"] = {"fit": 1.0})
	_stat("malformed_solid_pieces", {"cases": cases.size(), "accepted": accepted, "unknown_piece_errors": e1.size()})
	assert_eq(accepted.size(), 0, "malformed solid_pieces ACCEPTED: %s" % [accepted])
	assert_true(S5.mentions(e1, "no_such_rock"), "an unknown solid piece id is rejected by name: %s" % [e1])


func test_from_map_survives_malformed_baked_records_without_crashing() -> void:
	var map: Dictionary = S5.map_record().duplicate(true)
	map["obstacles"] = []
	var junk: Array = [
		{"id": "j1", "kind": "obb"},
		{"id": "j2", "kind": "obb", "center": [0, -10, 0]},
		{"id": "j3", "kind": "obb", "center": [0, -10, 0], "size": [1, 1, 1], "rot": [0, 0, 0, 0]},
		{"id": "j4", "kind": "obb", "center": [0, -10, 0], "size": [1, 1, 1], "round": 99.0},
		{"id": "j5", "kind": "obb", "center": [0, -10, 0], "size": [-4, 0, 1], "rot": [1, 2]},
		{"id": "j6", "kind": "torus", "center": [0, -10, 0]},
		{"id": "j7"},
		5,
		"text",
		null,
		{"id": "j8", "kind": "obb", "center": [1e30, 0, -1e30], "size": [1, 1, 1]},
		{"id": "ok", "kind": "obb", "center": [10, -10, 10], "size": [2, 2, 2], "rot": [0, 0, 0, 1], "round": 0.5},
	]
	var f: SeabedField = SeabedField.from_map(map, junk)
	var p := Vector3(10.0, -10.0, 10.0)
	var q: Vector3 = f.resolve(p, 0.3)
	assert_true(q.distance_to(p) > 0.9, "the one valid record still collides (pushed %.2f m)" % q.distance_to(p))
	for k in 200:
		var pos := Vector3(float(k) * 1.1 - 100.0, -10.0, float(k) * 0.7 - 60.0)
		var r: Vector3 = f.resolve(pos, 0.2)
		assert_true(r.is_finite(), "resolve stays finite with junk records at %s" % pos)
