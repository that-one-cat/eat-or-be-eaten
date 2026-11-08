extends TestCase
## S2 boundaries (sim side): soft current near the map edge, hard clamp at the edge, surface ceiling,
## seabed floor, obstacles. Margin / current strength come from reef.json `bounds`; radius from band data.
## Edge tests run in the abyss (floor ~80 m, y = -40) so the seabed never interferes; the -Z edge (shallows) is
## covered by the teleport clamp test only.

const S2 := preload("res://tests/s2_support.gd")
const EDGE_Y: float = -40.0

var w: SimWorld
var e: SimEntity
var pid: int = 0
var sb: SeabedField


func before_each() -> void:
	w = S2.make_world(21)
	sb = S2.seabed()
	e = null
	pid = 0


func _place(pos: Vector3, heading: Vector3 = Vector3.RIGHT, b: int = 1) -> void:
	e = S2.spawn_at(w, pos, heading, b)
	pid = e.id


## Position `frac` of the way through the soft margin (0 = inner border, 1 = the map edge) on a side:
## 0 = +X, 1 = -X, 2 = +Z (the abyss side).
func _edge_pos(side: int, frac: float) -> Vector3:
	var c: float = S2.half_size() - S2.soft_margin() * (1.0 - frac)
	match side:
		0:
			return Vector3(c, EDGE_Y, S2.LANE_Z)
		1:
			return Vector3(-c, EDGE_Y, S2.LANE_Z)
		_:
			return Vector3(0.0, EDGE_Y, c)


func _inward(side: int) -> Vector3:
	match side:
		0:
			return Vector3.LEFT
		1:
			return Vector3.RIGHT
		_:
			return Vector3.FORWARD  # -Z


# ======================================================== soft current

func test_bounds_data_present_and_spawns_are_outside_the_margin() -> void:
	var m: float = S2.soft_margin()
	assert_true(m > 0.0, "bounds.soft_margin_m > 0")
	assert_true(S2.current_mps() > 0.0, "bounds.current_mps > 0")
	assert_true(m < S2.half_size(), "margin smaller than half the map")
	for s: Variant in (S2.map()["player_spawns"] as Array):
		var a: Array = s
		var edge_dist: float = S2.half_size() - maxf(absf(float(a[0])), absf(float(a[2])))
		assert_true(edge_dist > m, "player spawn %s must be outside the soft margin (%s m from the edge, margin %s)" % [a, edge_dist, m])


func test_soft_current_pushes_idle_fish_toward_the_centre() -> void:
	for side in 3:
		w = S2.make_world(21)
		var start: Vector3 = _edge_pos(side, 0.5)
		_place(start)
		S2.run(w, 30)
		var moved: float = (e.position - start).dot(_inward(side))
		assert_true(moved > 0.01, "side %d: idle fish inside the margin must drift inward (moved %s m)" % [side, moved])


func test_no_current_outside_the_margin() -> void:
	for side in 3:
		w = S2.make_world(21)
		var start: Vector3 = _edge_pos(side, 0.0) + _inward(side) * 5.0  # 5 m inside the calm area
		_place(start)
		S2.run(w, 60)
		assert_true(e.position.distance_to(start) < 1e-3, "side %d: no push 5 m inside the calm area (moved %s m)" % [side, e.position.distance_to(start)])


func test_current_gets_stronger_toward_the_edge() -> void:
	for side in 3:
		var shallow := S2.make_world(21)
		var s_e: SimEntity = S2.spawn_at(shallow, _edge_pos(side, 0.2), Vector3.RIGHT, 1)
		var s_start: Vector3 = s_e.position
		var deep := S2.make_world(21)
		var d_e: SimEntity = S2.spawn_at(deep, _edge_pos(side, 0.9), Vector3.RIGHT, 1)
		var d_start: Vector3 = d_e.position
		S2.run(shallow, 15)
		S2.run(deep, 15)
		var shallow_move: float = (s_e.position - s_start).dot(_inward(side))
		var deep_move: float = (d_e.position - d_start).dot(_inward(side))
		assert_true(deep_move > shallow_move, "side %d: push at 90%% of the margin (%s m) must beat push at 20%% (%s m)" % [side, deep_move, shallow_move])


func test_current_speed_is_bounded_by_current_mps() -> void:
	var cap: float = S2.current_mps()
	for side in 3:
		w = S2.make_world(21)
		_place(_edge_pos(side, 0.95))
		var peak: float = 0.0
		for i in 90:
			w.step()
			peak = maxf(peak, e.velocity.dot(_inward(side)))
		assert_true(peak <= cap * 1.05 + 0.01, "side %d: inward drift speed %s exceeds bounds.current_mps %s" % [side, peak, cap])
		assert_true(peak >= cap * 0.3, "side %d: near the edge the current should be clearly felt (peak %s, current_mps %s)" % [side, peak, cap])


# ======================================================== hard clamp

func test_thrusting_outward_never_leaves_the_map() -> void:
	var half: float = S2.half_size()
	for side in 3:
		w = S2.make_world(21)
		var outward: Vector3 = -_inward(side)
		_place(_edge_pos(side, 0.5), outward)
		w.submit(SimCommand.move(pid, outward, 1.0))
		w.submit(SimCommand.boost(pid, true))
		for i in 600:
			w.step()
			assert_true(absf(e.position.x) <= half + 1e-4 and absf(e.position.z) <= half + 1e-4, "side %d tick %d: left the map at %s" % [side, i, e.position])
			if i % 100 == 99:
				w.submit(SimCommand.boost(pid, true))  # keep trying with whatever stamina regenerated


func test_positions_outside_the_map_are_clamped_back() -> void:
	var half: float = S2.half_size()
	var cases: Array[Vector3] = [
		Vector3(half + 50.0, EDGE_Y, S2.LANE_Z),
		Vector3(-half - 50.0, EDGE_Y, S2.LANE_Z),
		Vector3(0.0, EDGE_Y, half + 50.0),
		Vector3(0.0, EDGE_Y, -half - 50.0),
		Vector3(half + 100.0, EDGE_Y, half + 100.0),
		Vector3(1.0e6, EDGE_Y, -1.0e6),
	]
	for p in cases:
		w = S2.make_world(21)
		_place(p)
		w.step()
		assert_true(e.position.is_finite(), "%s: position finite after clamp" % p)
		assert_true(absf(e.position.x) <= half + 1e-4 and absf(e.position.z) <= half + 1e-4, "%s: not clamped to the map (now %s)" % [p, e.position])


# ======================================================== ceiling

func test_ceiling_is_minus_radius_for_every_band() -> void:
	for b in range(1, S2.content().band_count() + 1):
		w = S2.make_world(21)
		_place(Vector3(0.0, EDGE_Y, S2.LANE_Z), Vector3.RIGHT, b)
		var r: float = S2.radius(e)
		w.submit(SimCommand.move(pid, Vector3.UP, 1.0))
		var top: float = -INF
		for i in 600:  # 20 s: enough for 40 m at the slowest band plus the turn to pitch 80
			w.step()
			top = maxf(top, e.position.y)
		assert_true(top <= -r + 1e-4, "band %d: y reached %s, ceiling is -radius = %s" % [b, top, -r])
		assert_true(e.position.y >= -r - 0.5, "band %d: fish should be riding the ceiling after 20 s (y %s, radius %s)" % [b, e.position.y, r])
		assert_true(e.velocity.y <= 1e-3, "band %d: no upward velocity left at the ceiling (%s)" % [b, e.velocity.y])


func test_position_above_the_surface_is_pushed_down() -> void:
	for b in range(1, S2.content().band_count() + 1):
		w = S2.make_world(21)
		_place(Vector3(0.0, 5.0, S2.LANE_Z), Vector3.RIGHT, b)
		var r: float = S2.radius(e)
		w.step()
		assert_true(e.position.y <= -r + 1e-4, "band %d: teleported above the surface, y after tick %s (must be <= %s)" % [b, e.position.y, -r])


func test_fish_slides_along_the_ceiling() -> void:
	_place(Vector3(0.0, EDGE_Y, S2.LANE_Z))
	var r: float = S2.radius(e)
	e.position.y = -r  # touching the surface
	w.submit(SimCommand.move(pid, Vector3.RIGHT, 1.0))
	S2.run(w, 90)
	assert_true(e.position.x > 1.0, "a fish at the ceiling can still swim sideways (x %s)" % e.position.x)
	assert_true(e.position.y <= -r + 1e-4, "and stays under the surface (y %s)" % e.position.y)


# ======================================================== seabed floor

func test_fish_driven_into_the_seabed_never_goes_below_height_plus_radius() -> void:
	var spots: Array[Vector2] = [Vector2(0.0, -250.0), Vector2(120.0, -200.0), Vector2(-100.0, -90.0), Vector2(0.0, 60.0), Vector2(0.0, 250.0)]
	var dirs: Array[Vector3] = [Vector3.DOWN, Vector3(0.6, -0.8, 0.0), Vector3(0.0, -0.8, 0.6), Vector3(-0.6, -0.8, 0.0)]
	for b in [1, 4]:
		for spot in spots:
			for d in dirs:
				w = S2.make_world(21)
				var h: float = sb.height_at(spot.x, spot.y)
				var r: float = S2.radius_for(b, S2.band_length(b))
				var y0: float = minf(h + r + 8.0, -r - 0.5)
				_place(Vector3(spot.x, y0, spot.y), d.normalized(), b)
				w.submit(SimCommand.move(pid, d, 1.0))
				w.submit(SimCommand.boost(pid, true))
				for i in 300:
					w.step()
					var floor_y: float = sb.height_at(e.position.x, e.position.z) + r
					if e.position.y < floor_y - 1e-3:
						fail("band %d spot %s dir %s tick %d: y %s below height_at + radius %s" % [b, spot, d, i, e.position.y, floor_y])
						break


func test_fish_driven_down_the_cliff_stays_above_the_seabed() -> void:
	var r: float = S2.radius_for(1, S2.band_length(1))
	var start := Vector3(0.0, sb.height_at(0.0, 110.0) + r + 2.0, 110.0)
	var dir := Vector3(0.0, -0.2, 1.0).normalized()
	_place(start, dir, 1)
	w.submit(SimCommand.move(pid, dir, 1.0))
	w.submit(SimCommand.boost(pid, true))
	for i in 300:
		w.step()
		var floor_y: float = sb.height_at(e.position.x, e.position.z) + r
		if e.position.y < floor_y - 1e-3:
			fail("tick %d: y %s below height_at + radius %s on the cliff" % [i, e.position.y, floor_y])
			break
	assert_true(e.position.z > 112.0, "the fish actually travelled across the cliff zone (z %s)" % e.position.z)


# ======================================================== obstacles

func test_obstacles_exist_and_each_can_be_probed() -> void:
	var obs: Array[Dictionary] = sb.obstacles()
	assert_true(obs.size() >= 2, "reef.json defines arches and a boat placeholder, got %d obstacles" % obs.size())
	var r: float = S2.radius_for(1, S2.band_length(1))
	var probed: int = 0
	for o in obs:
		if S2.penetrating_probe(sb, o, r).is_finite():
			probed += 1
	assert_true(probed >= 1, "at least one obstacle record must contain a point that resolve() pushes out (probe found 0 of %d)" % obs.size())


func test_fish_inside_an_obstacle_is_pushed_out_by_the_sim() -> void:
	var r: float = S2.radius_for(1, S2.band_length(1))
	var tested: int = 0
	for o in sb.obstacles():
		var p: Vector3 = S2.penetrating_probe(sb, o, r)
		if not p.is_finite():
			continue
		w = S2.make_world(21)
		p.y = minf(p.y, -r - 0.01)
		if sb.resolve(p, r).distance_to(p) < 1e-4:
			continue  # lowering to the ceiling took the probe out of the obstacle
		_place(p)
		w.step()
		assert_true(e.position.is_finite(), "obstacle %s: position finite after push-out" % o)
		assert_true(sb.resolve(e.position, r).distance_to(e.position) < 1e-3, "obstacle %s: fish still penetrating after one tick at %s" % [o, e.position])
		tested += 1
	assert_true(tested >= 1, "no obstacle could be tested")


func test_fish_driven_straight_into_obstacles_stays_outside_for_300_ticks() -> void:
	var r: float = S2.radius_for(1, S2.band_length(1))
	var half: float = S2.half_size()
	var trials: int = 0
	var progressed: int = 0
	for o in sb.obstacles():
		var vs: Array[Vector3] = S2.vec_values(o)
		if vs.is_empty():
			continue
		var centre := Vector3.ZERO
		for v in vs:
			centre += v
		centre /= float(vs.size())
		centre.y = minf(centre.y, -r - 0.5)
		for off in [Vector3(25.0, 0.0, 0.0), Vector3(-25.0, 0.0, 0.0), Vector3(0.0, 0.0, 25.0), Vector3(0.0, 0.0, -25.0)]:
			var start: Vector3 = centre + off
			if absf(start.x) > half - S2.soft_margin() or absf(start.z) > half - S2.soft_margin():
				continue
			if sb.resolve(start, r).distance_to(start) > 1e-4:
				continue  # start itself is inside the seabed/another obstacle
			w = S2.make_world(21)
			var dir: Vector3 = (centre - start).normalized()
			_place(start, dir)
			w.submit(SimCommand.move(pid, dir, 1.0))
			w.submit(SimCommand.boost(pid, true))
			trials += 1
			var closest: float = start.distance_to(centre)
			for i in 300:
				w.step()
				closest = minf(closest, e.position.distance_to(centre))
				if sb.resolve(e.position, r).distance_to(e.position) > 1e-3:
					fail("obstacle %s from %s tick %d: fish inside geometry at %s" % [o, off, i, e.position])
					break
				if i % 100 == 99:
					w.submit(SimCommand.boost(pid, true))
			if closest < start.distance_to(centre) - 5.0:
				progressed += 1
	assert_true(trials >= 1, "no usable approach start found")
	assert_true(progressed >= 1, "the fish never actually closed in on an obstacle (test would be vacuous)")
