extends TestCase
## fix-rock-collision: the baked dressing proxies (maps/reef_proxies.json) are fresh (== DressingProxies.derive of the
## shipped dressing, authored map and piece index), env/pieces.json is fresh (== DressingProxies.build_index()), every
## solid placement has exactly one proxy, baked proxies never feed back into the placements (MapDressing blockers),
## and the cell-indexed narrow phase stays bounded on the real map.

const S5 := preload("res://tests/s5_support.gd")

const PROXIES_PATH: String = "res://data/maps/reef_proxies.json"
const INDEX_PATH: String = "res://data/env/pieces.json"
## Freshness tolerances (Vector3 / Basis are float32: exact equality across platforms is not promised).
const POS_TOL_M: float = 5e-3
const ROT_TOL: float = 1e-3
## Structural guard of the narrow phase: obstacles listed in any broad-phase cell (measured 2026-11-04 on the baked
## reef: worst 14, mean 2.0; authored only: worst 12).
const MAX_CELL_CANDIDATES: int = 32

static var _derived: Array[Dictionary] = []


func _content() -> ContentDB:
	return S5.content()


func _derive() -> Array[Dictionary]:
	if _derived.is_empty():
		var db: ContentDB = _content()
		_derived = DressingProxies.derive(db.get_dressing(&"reef").duplicate(true), db.get_map(&"reef").duplicate(true), MapDressing.piece_index())
	return _derived


func _baked() -> Array:
	return _content().get_proxies(&"reef")


func test_the_shipped_data_loads_with_baked_proxies() -> void:
	var db: ContentDB = _content()
	assert_true(db.is_valid(), "content valid: %s" % [db.errors])
	assert_true(FileAccess.file_exists(PROXIES_PATH), "%s exists" % PROXIES_PATH)
	assert_true(_baked().size() > 1000, "reef has baked proxies (%d)" % _baked().size())
	assert_true(db.get_proxies(&"no_such_map").is_empty(), "no proxies for an unknown map")
	var own: Dictionary = S5.obstacle_by_id(db.get_map(&"reef"))
	for o: Variant in _baked():
		assert_false(own.has(str((o as Dictionary)["id"])), "baked id %s is not a reef.json obstacle" % (o as Dictionary)["id"])
	assert_false(own.size() > 200, "baked proxies stay out of reef.json obstacles (%d there)" % own.size())


func test_baked_proxies_are_fresh() -> void:
	var fresh: Array[Dictionary] = _derive()
	var file: Array = _baked()
	assert_eq(file.size(), fresh.size(), "proxy count: file vs fresh derive (re-run tools/dressing/bake_proxies.gd -- --write)")
	if file.size() != fresh.size():
		return
	for i in fresh.size():
		var a: Dictionary = file[i]
		var b: Dictionary = fresh[i]
		var where: String = "proxy %d (%s)" % [i, b["id"]]
		if a["id"] != b["id"] or a["tag"] != b["tag"] or a["kind"] != b["kind"]:
			fail("%s: id/tag/kind %s/%s/%s != fresh %s/%s/%s (stale bake)" % [where, a["id"], a["tag"], a["kind"], b["id"], b["tag"], b["kind"]])
			return
		for key: String in ["center", "size"]:
			for k in 3:
				if absf(float(a[key][k]) - float(b[key][k])) > POS_TOL_M:
					fail("%s: %s %s != fresh %s (stale bake)" % [where, key, a[key], b[key]])
					return
		for k in 4:
			if absf(float(a["rot"][k]) - float(b["rot"][k])) > ROT_TOL:
				fail("%s: rot %s != fresh %s (stale bake)" % [where, a["rot"], b["rot"]])
				return
		if absf(float(a["round"]) - float(b["round"])) > POS_TOL_M:
			fail("%s: round %s != fresh %s (stale bake)" % [where, a["round"], b["round"]])
			return


func test_the_piece_index_is_fresh() -> void:
	var want: String = DressingProxies.build_index()
	var have: String = FileAccess.get_file_as_string(INDEX_PATH)
	if want == have:
		return
	var a: PackedStringArray = have.split("\n")
	var b: PackedStringArray = want.split("\n")
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			fail("%s line %d differs from DressingProxies.build_index() (re-run reef_layout.gd -- --index):\n  file:  %s\n  fresh: %s" % [INDEX_PATH, i + 1, a[i], b[i]])
			return
	fail("%s: %d lines, fresh index %d lines" % [INDEX_PATH, a.size(), b.size()])


func test_every_solid_piece_has_bounds_for_each_variant() -> void:
	var solid: Dictionary = _content().get_dressing(&"reef").get("solid_pieces", {})
	assert_true(solid.size() >= 7, "the dressing names its solid pieces (%d)" % solid.size())
	var index: Dictionary = MapDressing.piece_index()
	for pid: String in solid:
		assert_true(index.has(pid), "solid piece %s has GLBs" % pid)
		var info: Dictionary = index.get(pid, {})
		var bounds: Array = info.get("bounds", [])
		assert_eq(bounds.size(), int(info.get("variants", 0)), "%s: one bounds entry per variant" % pid)
		for b: Variant in bounds:
			assert_true(b is Array and (b as Array).size() == 6 and float(b[3]) > 0.0 and float(b[4]) > 0.0 and float(b[5]) > 0.0, "%s: bounds %s" % [pid, b])


func test_every_solid_placement_has_exactly_one_baked_proxy() -> void:
	var db: ContentDB = _content()
	var dressing: Dictionary = db.get_dressing(&"reef")
	var solid: Dictionary = dressing.get("solid_pieces", {})
	var sets: Dictionary = {}
	for sp: Variant in dressing["set_pieces"]:
		sets[str(sp["id"])] = sp
	var list: Array = S5.compute_fresh()
	var want: Dictionary = {}
	var ordinal: Dictionary = {}
	var scatter: int = 0
	for p: Variant in list:
		var pd: Dictionary = p
		if not solid.has(pd["piece"]):
			continue
		if pd["kind"] == "scatter":
			var r: int = int(pd["rule"])
			want["s%02d_%04d" % [r, int(ordinal.get(r, 0))]] = pd
			ordinal[r] = int(ordinal.get(r, 0)) + 1
			scatter += 1
		else:
			var sp: Dictionary = sets[str(pd["id"])]
			if not sp.has("collision") and (sp.get("obstacle_ids", []) as Array).is_empty():
				want["p_%s" % pd["id"]] = pd
	var seen: Dictionary = {}
	for o: Variant in _baked():
		var oid: String = str((o as Dictionary)["id"])
		assert_false(seen.has(oid), "baked id %s is unique" % oid)
		seen[oid] = true
		assert_true(want.has(oid), "baked proxy %s belongs to a solid placement" % oid)
	assert_true(scatter > 1000, "the reef has solid scatter (%d)" % scatter)
	for oid: String in want:
		if not seen.has(oid):
			fail("solid placement %s (%s at %s) has no baked proxy" % [oid, want[oid]["piece"], want[oid]["pos"]])
			return
	# each proxy sits on its placement: the base point lies inside the proxy footprint
	var by_id: Dictionary = {}
	for o: Variant in _baked():
		by_id[str(o["id"])] = o
	for oid: String in want:
		var base: Vector3 = (want[oid] as Dictionary)["pos"]
		var o: Dictionary = by_id[oid]
		assert_true(S5.obstacle_sdf(o, base + Vector3.UP * 0.05) < 0.0, "proxy %s contains its placement base %s" % [oid, base])


func test_baked_proxies_never_move_the_placements() -> void:
	var db: ContentDB = _content()
	var map: Dictionary = db.get_map(&"reef").duplicate(true)
	var dressing: Dictionary = db.get_dressing(&"reef").duplicate(true)
	var index: Dictionary = MapDressing.piece_index()
	var plain: Array = MapDressing.compute_placements(dressing, map, SeabedField.from_map(map), index)
	var with_baked: Array = MapDressing.compute_placements(dressing, map, SeabedField.from_map(map, _baked()), index)
	assert_eq(with_baked.size(), plain.size(), "same placement count with the baked proxies in the field (trap: scatter avoiding its own proxies)")
	if with_baked.size() != plain.size():
		return
	for i in plain.size():
		var a: Dictionary = plain[i]
		var b: Dictionary = with_baked[i]
		if a["piece"] != b["piece"] or not (a["pos"] as Vector3).is_equal_approx(b["pos"]):
			fail("placement %d differs: %s %s vs %s %s" % [i, a["piece"], a["pos"], b["piece"], b["pos"]])
			return


func test_the_sim_world_collides_with_the_baked_proxies() -> void:
	var w := SimWorld.new(1, _content())
	var n_baked: int = 0
	for o: Dictionary in w.seabed.obstacles():
		if bool(o["baked"]):
			n_baked += 1
	assert_eq(n_baked, _baked().size(), "SimWorld's seabed holds every baked proxy")
	assert_eq(w.seabed.obstacles().size() - n_baked, (w.map["obstacles"] as Array).size(), "plus the map's own obstacles")


func test_the_narrow_phase_stays_bounded_on_the_reef() -> void:
	var w := SimWorld.new(1, _content())
	var worst: int = 0
	var at := Vector2.ZERO
	var x: float = -300.0
	while x <= 300.0:
		var z: float = -300.0
		while z <= 300.0:
			var n: int = w.seabed.cell_candidates(x, z)
			if n > worst:
				worst = n
				at = Vector2(x, z)
			z += SeabedField.BROAD_CELL_M
		x += SeabedField.BROAD_CELL_M
	assert_true(worst > 0, "the grid lists obstacles")
	assert_true(worst <= MAX_CELL_CANDIDATES, "at most %d obstacles per broad-phase cell, worst %d at %s" % [MAX_CELL_CANDIDATES, worst, at])
