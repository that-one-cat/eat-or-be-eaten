extends TestCase
## SpatialGrid: uniform grid, insert/move/remove, radius query (squared distance <= radius^2), ascending ids.


class _Lcg:
	var s: int
	func _init(p_seed: int) -> void:
		s = p_seed & 0x7FFFFFFF
	func next() -> int:
		s = (s * 1103515245 + 12345) & 0x7FFFFFFF
		return s
	func unit() -> float:
		return float(next() % 100000) / 100000.0


func _ids(packed: PackedInt32Array) -> Array:
	return Array(packed)


# ---- insert / has / count / position_of ----

func test_empty_grid() -> void:
	var g := SpatialGrid.new(10.0)
	assert_eq(g.count(), 0, "empty grid count")
	assert_false(g.has(1), "empty grid has nothing")
	assert_eq(g.query_radius(Vector3.ZERO, 100.0).size(), 0, "query on empty grid is empty")


func test_cell_size_is_stored() -> void:
	var g := SpatialGrid.new(12.5)
	assert_almost_eq(g.cell_size, 12.5, 1e-6, "cell_size field")


func test_insert_has_count_position() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(1, 2, 3))
	g.insert(2, Vector3(-4, 5, 6))
	assert_true(g.has(1) and g.has(2), "inserted ids are present")
	assert_false(g.has(3), "unknown id is absent")
	assert_eq(g.count(), 2, "count after two inserts")
	assert_eq(g.position_of(1), Vector3(1, 2, 3), "position_of id 1")
	assert_eq(g.position_of(2), Vector3(-4, 5, 6), "position_of id 2")


func test_insert_existing_id_acts_as_move() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(0, 0, 0))
	g.insert(1, Vector3(100, 0, 0))
	assert_eq(g.count(), 1, "re-inserting an id must not duplicate it")
	assert_eq(g.position_of(1), Vector3(100, 0, 0), "re-insert updates the position")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 5.0)), [], "old location must be empty after re-insert")
	assert_eq(_ids(g.query_radius(Vector3(100, 0, 0), 5.0)), [1], "new location holds the entity")


# ---- remove ----

func test_remove() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3.ZERO)
	g.insert(2, Vector3(1, 0, 0))
	assert_true(g.remove(1), "remove existing returns true")
	assert_false(g.has(1), "removed id is gone")
	assert_eq(g.count(), 1, "count after remove")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 10.0)), [2], "removed id must not appear in queries")


func test_remove_unknown_returns_false() -> void:
	var g := SpatialGrid.new(10.0)
	assert_false(g.remove(42), "remove of unknown id returns false")
	g.insert(1, Vector3.ZERO)
	assert_true(g.remove(1), "first remove true")
	assert_false(g.remove(1), "second remove false")
	assert_eq(g.count(), 0, "count back to 0")


func test_removed_id_can_be_reinserted() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3.ZERO)
	g.remove(1)
	g.insert(1, Vector3(50, 0, 0))
	assert_eq(g.count(), 1, "count")
	assert_eq(_ids(g.query_radius(Vector3(50, 0, 0), 1.0)), [1], "reinserted entity is found at the new place")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 1.0)), [], "and not at the old one")


# ---- move ----

func test_move_within_same_cell() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(1, 1, 1))
	g.move(1, Vector3(2, 2, 2))
	assert_eq(g.position_of(1), Vector3(2, 2, 2), "position updated")
	assert_eq(g.count(), 1, "count unchanged")
	assert_eq(_ids(g.query_radius(Vector3(2, 2, 2), 0.5)), [1], "found at the new position")
	assert_eq(_ids(g.query_radius(Vector3(1, 1, 1), 0.5)), [], "not found at the old position")


func test_move_across_cells_leaves_old_cell() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(0, 0, 0))
	g.move(1, Vector3(100, 0, 0))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 5.0)), [], "old cell must not return the moved entity")
	assert_eq(_ids(g.query_radius(Vector3(100, 0, 0), 5.0)), [1], "new cell returns it")
	assert_eq(g.count(), 1, "count unchanged by move")


func test_move_into_negative_space() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(5, 5, 5))
	g.move(1, Vector3(-55, -5, -5))
	assert_eq(_ids(g.query_radius(Vector3(5, 5, 5), 3.0)), [], "old cell empty")
	assert_eq(_ids(g.query_radius(Vector3(-55, -5, -5), 3.0)), [1], "found in negative space")


# ---- radius query: boundary ----

func test_radius_boundary_is_inclusive() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(3, 4, 0))  # distance exactly 5, squared exactly 25
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 5.0)), [1], "entity at distance == radius must be included (<=)")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 4.99)), [], "entity just outside the radius must be excluded")


func test_radius_zero_matches_exact_position_only() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(2, 2, 2))
	g.insert(2, Vector3(2, 2, 2.5))
	assert_eq(_ids(g.query_radius(Vector3(2, 2, 2), 0.0)), [1], "radius 0 returns only entities at the exact point")


func test_boundary_on_cell_edge() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(10, 0, 0))  # exactly on a cell border
	assert_eq(_ids(g.query_radius(Vector3(9, 0, 0), 1.0)), [1], "entity on a cell border at distance == radius")
	assert_eq(_ids(g.query_radius(Vector3(11, 0, 0), 1.0)), [1], "same, approached from the other side")


func test_all_three_axes_count() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(0, 30, 0))
	g.insert(2, Vector3(0, 0, 30))
	g.insert(3, Vector3(30, 0, 0))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 10.0)), [], "far entities on every axis are excluded")
	assert_eq(_ids(g.query_radius(Vector3(0, 30, 0), 1.0)), [1], "y axis")
	assert_eq(_ids(g.query_radius(Vector3(0, 0, 30), 1.0)), [2], "z axis")
	assert_eq(_ids(g.query_radius(Vector3(30, 0, 0), 1.0)), [3], "x axis")


# ---- radius query: multi-cell ----

func test_radius_spanning_several_cells() -> void:
	var g := SpatialGrid.new(10.0)
	for i in 10:
		g.insert(i + 1, Vector3(i * 10.0, 0, 0))  # x = 0, 10, ..., 90
	var got: Array = _ids(g.query_radius(Vector3.ZERO, 45.0))
	assert_eq(got, [1, 2, 3, 4, 5], "radius 45 with cell 10 must reach x=0..40")
	var all: Array = _ids(g.query_radius(Vector3(45, 0, 0), 1000.0))
	assert_eq(all.size(), 10, "huge radius returns everything")


func test_radius_much_larger_than_cell_in_3d() -> void:
	var g := SpatialGrid.new(2.0)
	var expected: Array = []
	var id: int = 1
	for x in range(-3, 4):
		for y in range(-3, 4):
			for z in range(-3, 4):
				var p := Vector3(x * 3.0, y * 3.0, z * 3.0)
				g.insert(id, p)
				if p.length_squared() <= 100.0:
					expected.append(id)
				id += 1
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 10.0)), expected, "sphere of radius 10 over a 3D lattice with cell size 2")


# ---- negative coordinates ----

func test_negative_coordinates() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(-1, -1, -1))
	g.insert(2, Vector3(-15, 0, 0))
	g.insert(3, Vector3(-25, -25, -25))
	assert_eq(_ids(g.query_radius(Vector3(-1, -1, -1), 0.1)), [1], "tiny radius in negative space")
	assert_eq(_ids(g.query_radius(Vector3(-10, 0, 0), 6.0)), [2], "negative query center")
	assert_eq(_ids(g.query_radius(Vector3(-25, -25, -25), 1.0)), [3], "deep negative")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 3.0)), [1], "positive center sees nearest negative entity only")


func test_query_straddles_origin() -> void:
	var g := SpatialGrid.new(10.0)
	g.insert(1, Vector3(-0.5, 0, 0))
	g.insert(2, Vector3(0.5, 0, 0))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 1.0)), [1, 2], "entities on both sides of the origin cell split must both be found")


# ---- ordering ----

func test_results_ascending_regardless_of_insert_order() -> void:
	var g := SpatialGrid.new(10.0)
	for id in [9, 3, 7, 1, 5]:
		g.insert(id, Vector3(float(id) * 0.1, 0, 0))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 5.0)), [1, 3, 5, 7, 9], "same cell: ascending ids")


func test_results_ascending_across_cells() -> void:
	var g := SpatialGrid.new(5.0)
	g.insert(30, Vector3(-12, 0, 0))
	g.insert(10, Vector3(12, 0, 0))
	g.insert(20, Vector3(0, 12, 0))
	g.insert(5, Vector3(0, 0, -12))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 20.0)), [5, 10, 20, 30], "multi-cell result must be globally ascending")


func test_query_is_repeatable() -> void:
	var g := SpatialGrid.new(10.0)
	for i in 30:
		g.insert(i + 1, Vector3(i * 1.7 - 20.0, i % 5, -i * 0.9))
	var a: Array = _ids(g.query_radius(Vector3(3, 2, -4), 15.0))
	var b: Array = _ids(g.query_radius(Vector3(3, 2, -4), 15.0))
	assert_eq(a, b, "a query must not mutate the grid")


# ---- brute-force cross-check ----

func test_matches_brute_force_after_inserts_moves_removes() -> void:
	var lcg := _Lcg.new(12345)
	var g := SpatialGrid.new(7.0)
	var pos: Dictionary = {}
	for id in range(1, 201):
		g.insert(id, Vector3((lcg.unit() - 0.5) * 200.0, (lcg.unit() - 0.5) * 60.0, (lcg.unit() - 0.5) * 200.0))
		pos[id] = g.position_of(id)
	for i in 80:
		var id: int = 1 + lcg.next() % 200
		g.move(id, Vector3((lcg.unit() - 0.5) * 200.0, (lcg.unit() - 0.5) * 60.0, (lcg.unit() - 0.5) * 200.0))
		pos[id] = g.position_of(id)
	for i in 30:
		var id: int = 1 + lcg.next() % 200
		if pos.has(id):
			assert_true(g.remove(id), "remove of a live id")
			pos.erase(id)
	assert_eq(g.count(), pos.size(), "count tracks the surviving ids")
	for q in 60:
		var center := Vector3((lcg.unit() - 0.5) * 220.0, (lcg.unit() - 0.5) * 70.0, (lcg.unit() - 0.5) * 220.0)
		var radius: float = lcg.unit() * 45.0
		var expected: Array = []
		for id in pos:
			if center.distance_squared_to(pos[id]) <= radius * radius:
				expected.append(id)
		expected.sort()
		assert_eq(_ids(g.query_radius(center, radius)), expected, "query %d (center=%s r=%f) disagrees with brute force" % [q, center, radius])


# ---- world bounds, packing and invalid input ----

func test_world_corners_at_smallest_band_cell() -> void:
	# Rule 6: world within +-4 km; smallest grid_cell_m in size_bands.json is 4 m -> 1000 cells, far below 2^20.
	var g := SpatialGrid.new(4.0)
	var corners: Array[Vector3] = []
	var id: int = 1
	for sx in [-4000.0, 4000.0]:
		for sy in [-4000.0, 4000.0]:
			for sz in [-4000.0, 4000.0]:
				var p := Vector3(sx, sy, sz)
				corners.append(p)
				g.insert(id, p)
				id += 1
	assert_eq(g.count(), 8, "all eight corners inserted")
	for i in corners.size():
		assert_eq(_ids(g.query_radius(corners[i], 1.0)), [i + 1], "corner %d is found alone (no key aliasing)" % i)


func test_huge_radius_returns_everything_without_hanging() -> void:
	var g := SpatialGrid.new(1.0)
	g.insert(1, Vector3(-3000, 5, 10))
	g.insert(2, Vector3(3000, -5, -10))
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 1.0e7)), [1, 2], "radius far larger than the world")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, INF)), [1, 2], "infinite radius")


func test_invalid_query_arguments_match_nothing() -> void:
	var g := SpatialGrid.new(4.0)
	g.insert(1, Vector3.ZERO)
	assert_eq(g.query_radius(Vector3(NAN, 0, 0), 10.0).size(), 0, "NaN centre")
	assert_eq(g.query_radius(Vector3.ZERO, NAN).size(), 0, "NaN radius")
	assert_eq(g.query_radius(Vector3.ZERO, -5.0).size(), 0, "negative radius")


func test_non_finite_or_out_of_range_positions_are_rejected() -> void:
	var g := SpatialGrid.new(4.0)
	g.insert(1, Vector3.ZERO)
	g.insert(2, Vector3(NAN, 0, 0))
	g.insert(3, Vector3(INF, 0, 0))
	g.insert(4, Vector3(1.0e12, 0, 0))
	assert_eq(g.count(), 1, "only the valid position was stored")
	g.move(1, Vector3(0, NAN, 0))
	assert_eq(g.position_of(1), Vector3.ZERO, "a rejected move keeps the old position")
	assert_eq(_ids(g.query_radius(Vector3.ZERO, 5.0)), [1], "grid still consistent")


func test_boundary_point_is_found_at_far_coordinates() -> void:
	# Points exactly on the query sphere at large coordinates (float32 rounding territory) must match brute force.
	var lcg := _Lcg.new(777)
	var g := SpatialGrid.new(4.0)
	var pts: Dictionary = {}
	for id in range(1, 301):
		var p := Vector3(3900.0 + lcg.unit() * 100.0, -3950.0 + lcg.unit() * 60.0, 3800.0 + lcg.unit() * 200.0)
		g.insert(id, p)
		pts[id] = p
	for q in 100:
		var center := Vector3(3900.0 + lcg.unit() * 100.0, -3950.0 + lcg.unit() * 60.0, 3800.0 + lcg.unit() * 200.0)
		var target: Vector3 = pts[1 + lcg.next() % 300]
		var radius: float = center.distance_to(target)  # the target sits on the sphere boundary
		var expected: Array = []
		for id in pts:
			if center.distance_squared_to(pts[id]) <= radius * radius:
				expected.append(id)
		expected.sort()
		assert_eq(_ids(g.query_radius(center, radius)), expected, "boundary query %d disagrees with brute force" % q)
