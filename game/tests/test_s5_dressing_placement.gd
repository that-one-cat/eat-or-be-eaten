extends TestCase
## S5 map dressing PLACEMENT: the pure, node-free function
##   MapDressing.compute_placements(dressing, map, seabed: SeabedField, piece_index) -> Array
## (res://scripts/world/map_dressing.gd, plan assumption A5) must be deterministic from the dressing seed and put
## everything where the data says: inside the +-4 km world and the 600 x 600 m footprint, on the seabed, inside its
## zone, inside the rule's depth and scale ranges, with the rule's pieces/variants/weights, at least min_spacing_m
## apart, and away from the sim obstacles when the rule asks for it.
## Placement format (plan A6): {kind: "scatter"|"set_piece", piece, variant (1-based), pos: Vector3 (base), rot_y
## (radians), scale (float), zone_id + rule (scatter), id (set piece)}.

const S5 := preload("res://tests/s5_support.gd")


func _rules() -> Array:
	return S5.dressing().get("scatter", [])


func _rule_of(p: Dictionary) -> Dictionary:
	var i: int = int(p.get("rule", -1))
	var rules: Array = _rules()
	if i < 0 or i >= rules.size():
		return {}
	return rules[i]


func _first_diff(a: Array, b: Array) -> String:
	if a.size() != b.size():
		return "sizes differ: %d vs %d" % [a.size(), b.size()]
	for i in a.size():
		if a[i] != b[i]:
			return "first difference at #%d: %s vs %s" % [i, a[i], b[i]]
	return ""


# ======================================================== the API and determinism

func test_the_placement_function_exists_and_returns_placements() -> void:
	if not S5.require_api(self):
		return
	var list: Array = S5.placements()
	assert_true(list.size() > 0, "compute_placements returned placements")
	assert_true(S5.scatter_only(list).size() > 0, "scatter placements exist")
	assert_true(S5.set_pieces_only(list).size() > 0, "set piece placements exist")


func test_the_same_inputs_give_identical_placements() -> void:
	if not S5.require_api(self):
		return
	var a: Array = S5.compute_fresh()
	var b: Array = S5.compute_fresh()
	assert_true(a.size() > 0, "not vacuous")
	assert_true(a == b, "two runs on fresh copies of the same inputs: %s" % _first_diff(a, b))


func test_the_global_rng_and_call_history_do_not_matter() -> void:
	if not S5.require_api(self):
		return
	seed(12345)
	var a: Array = S5.compute_fresh()
	seed(987654)
	for i in 50:
		randf()
	var b: Array = S5.compute_fresh()
	assert_true(a == b, "different global RNG state: %s" % _first_diff(a, b))


func test_the_inputs_are_not_mutated() -> void:
	if not S5.require_api(self):
		return
	var d: Dictionary = S5.dressing().duplicate(true)
	var map: Dictionary = S5.map_record().duplicate(true)
	var d_before: String = var_to_str(d)
	var map_before: String = var_to_str(map)
	S5.compute(d, map, S5.seabed_for(map), S5.compute_index())
	assert_eq(var_to_str(d), d_before, "the dressing dictionary is untouched")
	assert_eq(var_to_str(map), map_before, "the map dictionary is untouched")


func test_the_dressing_seed_drives_the_scatter() -> void:
	if not S5.require_api(self):
		return
	var d2: Dictionary = S5.dressing().duplicate(true)
	d2["seed"] = int(d2["seed"]) + 1
	var base: Array = S5.scatter_only(S5.placements())
	var other: Array = S5.scatter_only(S5.compute_fresh(d2))
	assert_true(base.size() > 0 and other.size() > 0, "both seeds scatter something")
	assert_false(base == other, "another seed must move the scatter")


func test_a_flat_edit_of_one_rule_leaves_the_other_rules_alone() -> void:
	if not S5.require_api(self):
		return
	var rules: Array = _rules()
	if rules.size() < 2:
		fail("setup: need at least two scatter rules")
		return
	var d2: Dictionary = S5.dressing().duplicate(true)
	((d2["scatter"] as Array)[0] as Dictionary)["density_per_100m2"] = float(((d2["scatter"] as Array)[0] as Dictionary)["density_per_100m2"]) * 2.0 + 1.0
	var base: Array = S5.scatter_only(S5.placements())
	var other: Array = S5.scatter_only(S5.compute_fresh(d2))
	for r in range(1, rules.size()):
		var a: Array = []
		var b: Array = []
		for p: Variant in base:
			if int((p as Dictionary).get("rule", -1)) == r:
				a.append(p)
		for p2: Variant in other:
			if int((p2 as Dictionary).get("rule", -1)) == r:
				b.append(p2)
		assert_true(a == b, "rule %d must not change when only rule 0 changes (each rule draws from its own stream): %s" % [r, _first_diff(a, b)])


# ======================================================== format

func test_placement_format() -> void:
	if not S5.require_api(self):
		return
	var rule_count: int = _rules().size()
	var bad: int = 0
	for p: Variant in S5.placements():
		if not (p is Dictionary):
			fail("a placement is not a Dictionary: %s" % [p])
			return
		var pd: Dictionary = p
		var kind: String = str(pd.get("kind", ""))
		var problem: String = ""
		if kind != "scatter" and kind != "set_piece":
			problem = "kind '%s'" % kind
		elif not S5.piece_known(S5.piece_of(pd)):
			problem = "unknown piece '%s'" % S5.piece_of(pd)
		elif S5.variant_of(pd) < 1 or S5.variant_of(pd) > int(S5.glb_variants().get(S5.piece_of(pd), 0)):
			problem = "variant %d" % S5.variant_of(pd)
		elif not (pd.get("pos") is Vector3) or not S5.pos_of(pd).is_finite():
			problem = "pos %s" % [pd.get("pos")]
		elif not is_finite(S5.scale_of(pd)) or S5.scale_of(pd) <= 0.0:
			problem = "scale %s" % [pd.get("scale")]
		elif not is_finite(S5.rot_of(pd)):
			problem = "rot_y %s" % [pd.get("rot_y")]
		elif kind == "scatter" and (not (pd.get("zone_id") is String) or int(pd.get("rule", -1)) < 0 or int(pd.get("rule", -1)) >= rule_count):
			problem = "scatter without zone_id/rule: %s" % [pd]
		elif kind == "set_piece" and not (pd.get("id") is String):
			problem = "set piece without id"
		if not problem.is_empty():
			bad += 1
			if bad <= 5:
				fail("bad placement (%s): %s" % [problem, pd])
	assert_eq(bad, 0, "malformed placements")


func test_every_set_piece_is_placed_once_in_data_order() -> void:
	if not S5.require_api(self):
		return
	var want: Array = S5.dressing().get("set_pieces", [])
	var got: Array = S5.set_pieces_only(S5.placements())
	assert_eq(got.size(), want.size(), "one placement per set_pieces entry")
	for i in mini(got.size(), want.size()):
		var w: Dictionary = want[i]
		var g: Dictionary = got[i]
		assert_eq(str(g.get("id", "")), str(w["id"]), "set piece #%d id" % i)
		assert_eq(S5.piece_of(g), str(w["piece"]), "set piece '%s' piece" % w["id"])
		assert_eq(S5.variant_of(g), int(w.get("variant", 1)), "set piece '%s' variant" % w["id"])
		assert_almost_eq(S5.scale_of(g), float(w.get("scale", 1.0)), S5.SCALE_TOL, "set piece '%s' scale" % w["id"])
		var pos: Variant = w.get("pos")
		var p: Vector3 = S5.pos_of(g)
		if pos is Array:
			assert_true(p.distance_to(Vector3(float(pos[0]), float(pos[1]), float(pos[2]))) < 1e-3, "set piece '%s' keeps its explicit pos (got %s)" % [w["id"], p])
		elif pos is Dictionary:
			var xz: Array = (pos as Dictionary)["xz"]
			assert_true(absf(p.x - float(xz[0])) < 1e-3 and absf(p.z - float(xz[1])) < 1e-3, "set piece '%s' keeps its anchor xz (got %s)" % [w["id"], p])
		if w.has("rot_y"):
			assert_almost_eq(wrapf(S5.rot_of(g) - deg_to_rad(float(w["rot_y"])), -PI, PI), 0.0, 1e-3, "set piece '%s' rot_y (data is degrees, placement radians)" % w["id"])


# ======================================================== bounds

func test_everything_is_inside_the_world_and_the_footprint() -> void:
	if not S5.require_api(self):
		return
	var outside: int = 0
	for p: Variant in S5.placements():
		var pd: Dictionary = p
		var pos: Vector3 = S5.pos_of(pd)
		var ok: bool = absf(pos.x) <= S5.FOOTPRINT_HALF_M and absf(pos.z) <= S5.FOOTPRINT_HALF_M and absf(pos.y) <= S5.WORLD_LIMIT_M
		if ok and str(pd.get("kind")) == "set_piece":
			var box: AABB = S5.world_aabb(pd)
			ok = box.position.x >= -S5.FOOTPRINT_HALF_M - S5.FOOTPRINT_AABB_SLACK_M and box.end.x <= S5.FOOTPRINT_HALF_M + S5.FOOTPRINT_AABB_SLACK_M \
				and box.position.z >= -S5.FOOTPRINT_HALF_M - S5.FOOTPRINT_AABB_SLACK_M and box.end.z <= S5.FOOTPRINT_HALF_M + S5.FOOTPRINT_AABB_SLACK_M
		if not ok:
			outside += 1
			if outside <= 5:
				fail("outside the 600 x 600 m footprint: %s" % [pd])
	assert_eq(outside, 0, "placements outside the footprint")


func test_scatter_sits_on_the_seabed() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = S5.map_record()
	var sb: SeabedField = S5.seabed_for(map)
	var bad: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		var pos: Vector3 = S5.pos_of(p)
		var h: float = sb.height_at(pos.x, pos.z)
		if pos.y < h - S5.SCATTER_SINK_M or pos.y > h + S5.SCATTER_ABOVE_M:
			bad += 1
			if bad <= 5:
				fail("scatter off the seabed: y %.2f, seabed %.2f at (%.1f, %.1f)" % [pos.y, h, pos.x, pos.z])
	assert_eq(bad, 0, "scatter placements not on the seabed (y within [h - %s, h + %s])" % [S5.SCATTER_SINK_M, S5.SCATTER_ABOVE_M])


func test_set_pieces_are_not_buried_and_anchored_ones_sit_on_the_seabed() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = S5.map_record()
	var sb: SeabedField = S5.seabed_for(map)
	var anchored: Dictionary = {}
	for w: Variant in S5.dressing().get("set_pieces", []):
		if (w as Dictionary).get("pos") is Dictionary:
			anchored[str((w as Dictionary)["id"])] = true
	for p: Variant in S5.set_pieces_only(S5.placements()):
		var pd: Dictionary = p
		var pos: Vector3 = S5.pos_of(pd)
		var h: float = sb.height_at(pos.x, pos.z)
		if not S5.piece_of(pd).contains("cliff"):  # cliff walls rise from the abyss floor, far below the seabed at the lip line
			assert_true(pos.y >= h - S5.SET_SINK_M, "set piece '%s' is buried: y %.2f, seabed %.2f" % [pd.get("id"), pos.y, h])
		if anchored.has(str(pd.get("id"))):
			assert_true(pos.y <= h + S5.SCATTER_ABOVE_M, "anchored set piece '%s' floats: y %.2f, seabed %.2f" % [pd.get("id"), pos.y, h])


# ======================================================== scatter rules

func test_scatter_stays_inside_its_zone() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = S5.map_record()
	var bad: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		var pd: Dictionary = p
		var rule: Dictionary = _rule_of(pd)
		var zone: AABB = S5.zone_aabb(map, str(rule.get("zone_id", "")))
		if str(pd.get("zone_id", "")) != str(rule.get("zone_id", "")) or not S5.in_xz(zone, S5.pos_of(pd)):
			bad += 1
			if bad <= 5:
				fail("scatter outside zone '%s' %s: %s" % [rule.get("zone_id"), zone, pd])
	assert_eq(bad, 0, "scatter placements outside their zone")


func test_scatter_respects_the_depth_range() -> void:
	if not S5.require_api(self):
		return
	var sb: SeabedField = S5.seabed_for(S5.map_record())
	var bad: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		var rule: Dictionary = _rule_of(p)
		var dr: Array = rule.get("depth_m", [0.0, 1.0e9])
		var depth: float = S5.seabed_depth(sb, S5.pos_of(p))
		if depth < float(dr[0]) - S5.DEPTH_TOL_M or depth > float(dr[1]) + S5.DEPTH_TOL_M:
			bad += 1
			if bad <= 5:
				fail("seabed depth %.2f m outside the rule range %s: %s" % [depth, dr, p])
	assert_eq(bad, 0, "scatter placements outside the rule depth range")


func test_scatter_respects_the_scale_range() -> void:
	if not S5.require_api(self):
		return
	var bad: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		var sc: Array = _rule_of(p).get("scale", [0.0, 1.0e9])
		var s: float = S5.scale_of(p)
		if s < float(sc[0]) - S5.SCALE_TOL or s > float(sc[1]) + S5.SCALE_TOL:
			bad += 1
			if bad <= 5:
				fail("scale %.3f outside %s: %s" % [s, sc, p])
	assert_eq(bad, 0, "scatter placements outside the rule scale range")


func test_scatter_uses_only_the_pieces_and_variants_of_its_rule() -> void:
	if not S5.require_api(self):
		return
	var bad: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		var pd: Dictionary = p
		var allowed: Dictionary = {}
		for pe: Variant in _rule_of(pd).get("pieces", []):
			allowed[str((pe as Dictionary)["id"])] = S5.variant_list((pe as Dictionary).get("variants", 1))
		var pid: String = S5.piece_of(pd)
		if not allowed.has(pid) or not (allowed[pid] as Array).has(S5.variant_of(pd)):
			bad += 1
			if bad <= 5:
				fail("piece/variant not allowed by rule %s: %s" % [pd.get("rule"), pd])
	assert_eq(bad, 0, "scatter placements with a piece or variant their rule does not list")


func test_the_piece_mix_follows_the_weights() -> void:
	if not S5.require_api(self):
		return
	var rules: Array = _rules()
	var checked: int = 0
	for i in rules.size():
		var pieces: Array = (rules[i] as Dictionary).get("pieces", [])
		if pieces.size() < 2:
			continue
		var counts: Dictionary = {}
		var n: int = 0
		for p: Variant in S5.scatter_only(S5.placements()):
			if int((p as Dictionary).get("rule", -1)) == i:
				counts[S5.piece_of(p)] = int(counts.get(S5.piece_of(p), 0)) + 1
				n += 1
		if n < 200:
			continue
		checked += 1
		var total_w: float = 0.0
		for pe: Variant in pieces:
			total_w += float((pe as Dictionary)["weight"])
		for pe2: Variant in pieces:
			var share: float = float(counts.get(str((pe2 as Dictionary)["id"]), 0)) / float(n)
			var want: float = float((pe2 as Dictionary)["weight"]) / total_w
			assert_true(absf(share - want) <= 0.12, "rule %d piece '%s': share %.2f, weight share %.2f (n %d)" % [i, (pe2 as Dictionary)["id"], share, want, n])
	if checked == 0:
		print("NOTE test_s5_dressing_placement: no multi-piece rule with >= 200 placements, weight mix not exercised")


func test_scatter_keeps_clear_of_sim_obstacles_when_asked() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = S5.map_record()
	var obstacles: Array = []
	var bounds: Array[AABB] = []
	for o: Variant in map.get("obstacles", []):
		obstacles.append(o)
		bounds.append(S5.obstacle_bounds(o).grow(0.05))
	var inside: int = 0
	var tested: int = 0
	for p: Variant in S5.scatter_only(S5.placements()):
		if not bool(_rule_of(p).get("avoid_obstacles", false)):
			continue
		tested += 1
		var pos: Vector3 = S5.pos_of(p)
		for k in obstacles.size():
			if bounds[k].has_point(pos) and S5.obstacle_sdf(obstacles[k], pos) < 0.0:
				inside += 1
				if inside <= 5:
					fail("avoid_obstacles scatter inside obstacle '%s': %s" % [(obstacles[k] as Dictionary)["id"], p])
	assert_true(tested > 0, "some scatter comes from avoid_obstacles rules")
	assert_eq(inside, 0, "avoid_obstacles scatter inside a sim obstacle")


func test_min_spacing_is_respected_per_rule() -> void:
	if not S5.require_api(self):
		return
	var rules: Array = _rules()
	var checked: int = 0
	for i in rules.size():
		var spacing: float = float((rules[i] as Dictionary).get("min_spacing_m", 0.0))
		if spacing <= 0.0:
			continue
		var pts := PackedVector2Array()
		for p: Variant in S5.scatter_only(S5.placements()):
			if int((p as Dictionary).get("rule", -1)) == i:
				var pos: Vector3 = S5.pos_of(p)
				pts.append(Vector2(pos.x, pos.z))
		checked += 1
		var res: Array = S5.spacing_violations(pts, spacing)
		assert_eq(int(res[0]), 0, "rule %d (min_spacing_m %s, %d points): %s" % [i, spacing, pts.size(), res[1]])
	assert_true(checked > 0, "at least one rule has min_spacing_m > 0")


func test_the_density_is_not_exceeded_and_no_rule_is_dead() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = S5.map_record()
	var rules: Array = _rules()
	var footprint := AABB(Vector3(-S5.FOOTPRINT_HALF_M, -1000.0, -S5.FOOTPRINT_HALF_M), Vector3(S5.FOOTPRINT_HALF_M * 2.0, 2000.0, S5.FOOTPRINT_HALF_M * 2.0))
	for i in rules.size():
		var r: Dictionary = rules[i]
		var n: int = 0
		for p: Variant in S5.scatter_only(S5.placements()):
			if int((p as Dictionary).get("rule", -1)) == i:
				n += 1
		var density: float = float(r.get("density_per_100m2", 0.0))
		if density <= 0.0:
			assert_eq(n, 0, "rule %d has density 0: no placements" % i)
			continue
		var zone: AABB = S5.zone_aabb(map, str(r["zone_id"]))
		var clipped: AABB = zone.intersection(footprint)
		var area: float = clipped.size.x * clipped.size.z
		var mean: float = density * area / 100.0
		var chunks: float = ceilf(clipped.size.x / 64.0 + 1.0) * ceilf(clipped.size.z / 64.0 + 1.0)
		var cap: float = mean * 1.15 + 4.0 * sqrt(mean) + 3.0 + chunks
		assert_true(float(n) <= cap, "rule %d (%s): %d placements, expected at most %.0f for %.0f m2 at %s per 100 m2" % [i, r["zone_id"], n, cap, area, density])
		assert_true(n >= 1, "rule %d (%s) places nothing (its depth range %s never meets the seabed of the zone?)" % [i, r["zone_id"], r.get("depth_m")])


func test_instance_budget() -> void:
	if not S5.require_api(self):
		return
	var scatter: int = S5.scatter_only(S5.placements()).size()
	assert_true(scatter <= S5.MAX_SCATTER_TOTAL, "scatter total %d <= %d (runaway density?)" % [scatter, S5.MAX_SCATTER_TOTAL])
	assert_true(S5.set_pieces_only(S5.placements()).size() <= 400, "set pieces <= 400 (one node each)")
