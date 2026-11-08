extends TestCase
## S5 dressing vs gameplay data: what the player SEES must match what the sim DOES.
## - every hiding volume of reef.json holds enough kelp / coral of its tag family (cover you can see);
## - the wrecked boat is in the sunken_boat zone at 40-50 m depth, with boat obstacle proxies;
## - every large set piece has sim obstacle proxies that match its shape (no Godot physics: the sim collides with the
##   analytic primitives of reef.json), and no obstacle is an invisible wall (each belongs to a dressed set piece);
## - the cliff segments follow the seabed cliff line without gaps; glowing flora sits deep (abyss / cliff edge) and
##   corals / kelp sit in their depth bands ("mood gets darker and more bioluminescent with depth", GAME_DESIGN 9).
## Thresholds are constants in s5_support.gd / this file (plan A9, A10), all tunable.

const S5 := preload("res://tests/s5_support.gd")
## Proxy union vs piece AABB: the longest horizontal extent of the proxies must be within these ratios of the piece's.
const PROXY_MIN_RATIO: float = 0.4
const PROXY_MAX_RATIO: float = 1.8
const PROXY_CENTRE_SLACK_M: float = 2.0
const CLIFF_GAP_M: float = 1.0
const GLOW_MIN_ABYSS: int = 20
const GLOW_MIN_CLIFF_EDGE: int = 8
const GLOW_MIN_DEPTH_M: float = 30.0
const CORAL_MAX_DEPTH_M: float = 30.0
const KELP_DEPTH_BAND: Vector2 = Vector2(8.0, 45.0)
## The ids of the S2 obstacles: the dressing may adjust their shapes, never drop them (S2-S4 tests and fish use them).
const S2_OBSTACLE_IDS: Array[String] = [
	"arch_a_left", "arch_a_right", "arch_a_top", "arch_b_left", "arch_b_right", "arch_b_top",
	"arch_c_left", "arch_c_right", "arch_c_top", "arch_d_left", "arch_d_right", "arch_d_top",
	"cave_1_left", "cave_1_right", "cave_1_top", "cave_2_left", "cave_2_right", "cave_2_top",
	"cave_3_left", "cave_3_right", "cave_3_top", "boat_hull", "boat_cabin",
	"rock_1", "rock_2", "rock_3", "rock_4", "coral_1",
]


func _map() -> Dictionary:
	return S5.map_record()


func _set_data_by_id() -> Dictionary:
	var out: Dictionary = {}
	for w: Variant in S5.dressing().get("set_pieces", []):
		out[str((w as Dictionary)["id"])] = w
	return out


func _quadrants_covered(list: Array, box: AABB, fam: String = "") -> int:
	var hit: Dictionary = {}
	var mid: Vector3 = box.get_center()
	for p: Variant in list:
		var pos: Vector3 = S5.pos_of(p)
		if not S5.in_xz(box, pos):
			continue
		if not fam.is_empty() and S5.family(S5.piece_of(p)) != fam:
			continue
		hit[Vector2i(1 if pos.x >= mid.x else 0, 1 if pos.z >= mid.z else 0)] = true
	return hit.size()


# ======================================================== hiding volumes

func test_every_hiding_volume_is_filled_with_matching_cover() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = _map()
	var volumes: Array = map.get("hiding_volumes", [])
	assert_true(volumes.size() > 0, "reef.json has hiding volumes")
	for hv: Variant in volumes:
		var v: Dictionary = hv
		var tag: String = str(v["tag"])
		var box: AABB = S5.aabb_of(v["aabb"])
		var need: int = S5.KELP_MIN_PER_VOLUME if tag == "kelp" else S5.CORAL_MIN_PER_VOLUME
		var n: int = S5.family_count_in(S5.placements(), box, tag)
		assert_true(n >= need, "hiding volume '%s' (%s) holds %d %s pieces, needs >= %d" % [v["id"], tag, n, tag, need])


func test_hiding_cover_is_spread_over_the_volume() -> void:
	if not S5.require_api(self):
		return
	for hv: Variant in _map().get("hiding_volumes", []):
		var v: Dictionary = hv
		var box: AABB = S5.aabb_of(v["aabb"])
		var covered: int = _quadrants_covered(S5.placements(), box, str(v["tag"]))
		assert_true(covered >= 3, "hiding volume '%s': cover found in %d of 4 quadrants (needs >= 3), not one clump" % [v["id"], covered])


# ======================================================== the boat

func test_the_boat_lies_in_the_sunken_boat_zone_at_forty_to_fifty_metres() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = _map()
	var zone: AABB = S5.zone_aabb(map, "sunken_boat")
	var boats: Array = []
	for p: Variant in S5.set_pieces_only(S5.placements()):
		if S5.piece_of(p).contains("boat"):
			boats.append(p)
	assert_eq(boats.size(), 1, "exactly one boat set piece")
	if boats.size() != 1:
		return
	var boat: Dictionary = boats[0]
	var pos: Vector3 = S5.pos_of(boat)
	assert_true(S5.in_xz(zone, pos), "boat origin %s inside the sunken_boat zone xz %s" % [pos, zone])
	assert_true(-pos.y >= 40.0 and -pos.y <= 50.0, "boat base at %.1f m depth, wanted 40-50 m" % -pos.y)
	var h: float = S5.seabed_for(map).height_at(pos.x, pos.z)
	assert_true(pos.y >= h - S5.SET_SINK_M and pos.y <= h + 2.0, "boat rests on the seabed: y %.2f, seabed %.2f" % [pos.y, h])
	var data: Dictionary = _set_data_by_id().get(str(boat.get("id", "")), {})
	var obstacles: Dictionary = S5.obstacle_by_id(map)
	var ids: Array = data.get("obstacle_ids", [])
	assert_true(ids.size() > 0, "the boat has obstacle proxies")
	for oid: Variant in ids:
		assert_eq(str((obstacles.get(str(oid), {}) as Dictionary).get("tag", "")), "boat", "obstacle '%s' is tagged boat" % oid)


# ======================================================== large pieces and obstacle proxies

func test_every_large_set_piece_has_matching_obstacle_proxies() -> void:
	if not S5.require_api(self):
		return
	if not S5.specs_available():
		fail("generator specs (tools/blender/env/pieces) not readable: cannot tell which pieces are env_large")
		return
	var map: Dictionary = _map()
	var obstacles: Dictionary = S5.obstacle_by_id(map)
	var data: Dictionary = _set_data_by_id()
	var large: int = 0
	for p: Variant in S5.set_pieces_only(S5.placements()):
		var pd: Dictionary = p
		if S5.size_class(S5.piece_of(pd)) != "env_large":
			continue
		large += 1
		var sid: String = str(pd.get("id", ""))
		var ids: Array = (data.get(sid, {}) as Dictionary).get("obstacle_ids", [])
		if str((data.get(sid, {}) as Dictionary).get("collision", "")) == "seabed_field" and S5.piece_of(pd).contains("cliff"):
			continue  # explicit waiver (plan A11): the SeabedField cliff terrain already collides here
		assert_true(ids.size() > 0, "large set piece '%s' (%s) needs at least one obstacle proxy" % [sid, S5.piece_of(pd)])
		if ids.is_empty():
			continue
		var union: AABB = S5.union_bounds(ids, obstacles)
		assert_true(union.size != Vector3.ZERO, "set piece '%s': obstacle_ids resolve to real primitives" % sid)
		var box: AABB = S5.world_aabb(pd)
		var roomy: AABB = box.grow(PROXY_CENTRE_SLACK_M)
		assert_true(S5.in_xz(roomy, union.get_center()), "set piece '%s': proxy centre %s lies outside the piece footprint %s" % [sid, union.get_center(), box])
		var piece_ext: float = maxf(box.size.x, box.size.z)
		var proxy_ext: float = maxf(union.size.x, union.size.z)
		if piece_ext > 0.0:
			var ratio: float = proxy_ext / piece_ext
			assert_true(ratio >= PROXY_MIN_RATIO and ratio <= PROXY_MAX_RATIO, "set piece '%s': proxy extent %.1f m vs piece %.1f m (ratio %.2f, allowed %s..%s)" % [sid, proxy_ext, piece_ext, ratio, PROXY_MIN_RATIO, PROXY_MAX_RATIO])
	assert_true(large > 0, "the map dresses at least one env_large set piece (arches, cliff, boat ...)")


func test_no_obstacle_is_an_invisible_wall() -> void:
	if not S5.require_api(self):
		return
	var claimed: Dictionary = {}
	for w: Variant in S5.dressing().get("set_pieces", []):
		for oid: Variant in (w as Dictionary).get("obstacle_ids", []):
			claimed[str(oid)] = (w as Dictionary).get("id")
	for o: Variant in _map().get("obstacles", []):
		var oid2: String = str((o as Dictionary)["id"])
		assert_true(claimed.has(oid2), "obstacle '%s' (%s) belongs to no set piece: fish would bump into nothing" % [oid2, (o as Dictionary).get("tag")])


func test_the_s2_obstacle_ids_are_kept() -> void:
	var by_id: Dictionary = S5.obstacle_by_id(_map())
	for oid: String in S2_OBSTACLE_IDS:
		assert_true(by_id.has(oid), "obstacle '%s' still exists (adjust its shape, do not remove it)" % oid)


func test_arches_and_caves_are_dressed_with_arch_or_cave_pieces() -> void:
	if not S5.require_api(self):
		return
	var data: Dictionary = _set_data_by_id()
	var groups: Dictionary = {}
	for o: Variant in _map().get("obstacles", []):
		var od: Dictionary = o
		if str(od.get("tag", "")) == "arch" or str(od.get("tag", "")) == "cave":
			var gid: String = str(od["id"]).rsplit("_", true, 1)[0]
			groups[gid] = str(od["tag"])
	assert_true(groups.size() >= 7, "reef.json has 4 arches + 3 caves, found %d groups" % groups.size())
	for gid2: String in groups.keys():
		var owner_piece: String = ""
		for sid: String in data.keys():
			for oid: Variant in (data[sid] as Dictionary).get("obstacle_ids", []):
				if str(oid).begins_with(gid2 + "_"):
					owner_piece = str((data[sid] as Dictionary).get("piece", ""))
		assert_false(owner_piece.is_empty(), "%s '%s' has no set piece" % [groups[gid2], gid2])
		if not owner_piece.is_empty():
			var ok: bool = owner_piece.contains("arch") or owner_piece.contains("cave") or owner_piece.contains("pillar")
			assert_true(ok, "%s '%s' is dressed with '%s' (expected an arch / cave / pillar piece)" % [groups[gid2], gid2, owner_piece])


# ======================================================== cliff

func test_the_cliff_segments_follow_the_cliff_line_without_gaps() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = _map()
	var zone: AABB = S5.zone_aabb(map, "cliff_edge")
	var spans: Array = []
	for p: Variant in S5.set_pieces_only(S5.placements()):
		var pd: Dictionary = p
		if not S5.piece_of(pd).contains("cliff"):
			continue
		var pos: Vector3 = S5.pos_of(pd)
		assert_true(pos.z >= zone.position.z and pos.z <= zone.end.z, "cliff piece '%s' at z %.1f is inside the cliff_edge zone (z %s..%s, cliff line %s)" % [pd.get("id"), pos.z, zone.position.z, zone.end.z, (map["seabed"]["cliff"] as Dictionary)["z_m"]])
		var box: AABB = S5.world_aabb(pd)
		spans.append(Vector2(box.position.x, box.end.x))
	assert_true(spans.size() >= 4, "at least 4 cliff segments, found %d" % spans.size())
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	if spans.is_empty():
		return
	assert_true((spans[0] as Vector2).x <= -S5.FOOTPRINT_HALF_M + CLIFF_GAP_M, "the cliff starts at the west edge (first segment from x %.1f)" % (spans[0] as Vector2).x)
	var reach: float = (spans[0] as Vector2).y
	for i in range(1, spans.size()):
		var s: Vector2 = spans[i]
		assert_true(s.x <= reach + CLIFF_GAP_M, "gap of %.1f m in the cliff line between x %.1f and x %.1f" % [s.x - reach, reach, s.x])
		reach = maxf(reach, s.y)
	assert_true(reach >= S5.FOOTPRINT_HALF_M - CLIFF_GAP_M, "the cliff reaches the east edge (last segment ends at x %.1f)" % reach)


# ======================================================== depth mood

func test_glowing_flora_marks_the_abyss_and_the_cliff_edge() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = _map()
	var sb: SeabedField = S5.seabed_for(map)
	var abyss: AABB = S5.zone_aabb(map, "abyss")
	var edge: AABB = S5.zone_aabb(map, "cliff_edge")
	var glow: Array = []
	for p: Variant in S5.placements():
		if S5.is_glow(S5.piece_of(p)):
			glow.append(p)
	var in_abyss: int = 0
	var in_edge: int = 0
	var too_shallow: int = 0
	for p2: Variant in glow:
		var pos: Vector3 = S5.pos_of(p2)
		if S5.in_xz(abyss, pos):
			in_abyss += 1
		if S5.in_xz(edge, pos):
			in_edge += 1
		if S5.seabed_depth(sb, pos) < GLOW_MIN_DEPTH_M:
			too_shallow += 1
			if too_shallow <= 3:
				fail("glowing piece too shallow (%.1f m): %s" % [S5.seabed_depth(sb, pos), p2])
	assert_true(in_abyss >= GLOW_MIN_ABYSS, "abyss holds %d glowing pieces, wanted >= %d" % [in_abyss, GLOW_MIN_ABYSS])
	assert_true(in_edge >= GLOW_MIN_CLIFF_EDGE, "cliff_edge holds %d glowing pieces, wanted >= %d" % [in_edge, GLOW_MIN_CLIFF_EDGE])
	assert_eq(too_shallow, 0, "glowing pieces above %s m depth" % GLOW_MIN_DEPTH_M)
	assert_true(_quadrants_covered(glow, abyss) >= 3, "glow is spread over the abyss (>= 3 of 4 quadrants)")


func test_corals_and_kelp_stay_in_their_depth_bands() -> void:
	if not S5.require_api(self):
		return
	var sb: SeabedField = S5.seabed_for(_map())
	var bad: int = 0
	for p: Variant in S5.placements():
		var pid: String = S5.piece_of(p)
		var fam: String = S5.family(pid)
		var depth: float = S5.seabed_depth(sb, S5.pos_of(p))
		var problem: String = ""
		if fam == "coral" and not S5.is_glow(pid) and depth > CORAL_MAX_DEPTH_M:
			problem = "coral '%s' at %.1f m (reef corals live above %s m)" % [pid, depth, CORAL_MAX_DEPTH_M]
		elif fam == "kelp" and (depth < KELP_DEPTH_BAND.x or depth > KELP_DEPTH_BAND.y):
			problem = "kelp '%s' at %.1f m (kelp forest band %s..%s m)" % [pid, depth, KELP_DEPTH_BAND.x, KELP_DEPTH_BAND.y]
		if not problem.is_empty():
			bad += 1
			if bad <= 5:
				fail(problem)
	assert_eq(bad, 0, "flora outside its depth band")


func test_the_shallows_are_not_dressed_with_deep_pieces() -> void:
	if not S5.require_api(self):
		return
	var map: Dictionary = _map()
	var shallows: AABB = S5.zone_aabb(map, "shallows")
	var n_coral: int = 0
	for p: Variant in S5.placements():
		var pos: Vector3 = S5.pos_of(p)
		if not S5.in_xz(shallows, pos):
			continue
		assert_false(S5.is_glow(S5.piece_of(p)), "glowing piece in the shallows: %s" % [p])
		if S5.family(S5.piece_of(p)) == "coral":
			n_coral += 1
	assert_true(n_coral >= 20, "the shallows (spawn area) are a coral reef: %d coral pieces, wanted >= 20" % n_coral)
