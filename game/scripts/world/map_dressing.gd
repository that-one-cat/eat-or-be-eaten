class_name MapDressing
extends Node3D
## Map dressing (S5, presentation only): places the environment kit (game/assets/models/env) on a map from its
## dressing record (`maps/<map_id>_dressing.json`, ContentDB.get_dressing) and the SeabedField heights.
## Two steps:
## 1. compute_placements() - static, node-free and deterministic (seeded RandomNumberGenerator per scatter rule, no
##    global RNG, no clock, inputs never mutated): the list of placements;
## 2. build() - turns that list into nodes: scatter = one MultiMeshInstance3D per piece variant per CHUNK_M chunk
##    (opaque, no shadows, visibility_range_end per chunk, sway in the env shader, kelp with m_env_kelp.tres),
##    set pieces = one MeshInstance3D each. No physics bodies: sim collision stays the analytic SeabedField
##    (reef.json obstacles; large set pieces name their proxies in `obstacle_ids`, the cliff uses the seabed cliff;
##    solid scatter collides through the baked proxies of maps/<id>_proxies.json, DressingProxies).
## The sim never reads any of this.
##
## Placement (one Dictionary each): kind "scatter" | "set_piece", piece (env piece id), variant (1-based, GLB v<n>),
## pos (Vector3, base of the piece), rot_y (radians, data is degrees), scale (uniform float), zone_id + rule (scatter
## rule index; set pieces: "" and -1), id (set piece id; scatter ""), up (Vector3: seabed normal when the rule aligns
## to the slope, else UP), tilt (radians about the piece's local X, applied before rot_y; set piece `tilt_deg`).
##
## Scatter rule semantics (data reference: game/data/README.md): candidates are drawn uniformly in the zone XZ
## rectangle clipped to the map footprint (or, with `hiding_volume_ids`, in those volumes' XZ inside the zone), in
## clumps when `clump` is set; a candidate is kept when the seabed depth under it is inside `depth_m`, the slope is at
## most `max_slope_deg`, it keeps `min_spacing_m` (XZ) from every placement of the same rule and, with
## `avoid_obstacles`, stays clear of the map obstacles and of the footprints of the env_medium / env_large set pieces.
## Baked dressing proxies (obstacles marked `baked`, maps/<id>_proxies.json) are never blockers: they are derived from
## these placements (DressingProxies), so the placements must not depend on them.
## Clumps: `clump: {count: [min, max], radius_m, group?}` places count items within radius_m of a centre; rules with
## the same `group` (and zone) draw their centres from one shared stream, so they dress the same spots.
## Count target = density_per_100m2 x area / 100 (may end lower: spacing, depth, obstacles; attempts are bounded).
## Base y = seabed height - sink (rule `sink_m` + a slope allowance when not aligned, at most MAX_SINK_M).
## Food sites (food task): build() also draws the baked food sites (`food_sites` = ContentDB.get_food_sites, the records
## FoodPlacement.derive baked; compute_placements() never adds them): own food pieces (eggs, snails) join the scatter
## buckets (one MultiMesh per piece variant per chunk, draw distance = dressing `food.view_m` x tier); an edible decor
## site IS its decor instance (record `decor` = placement index). Food and edible decor pieces are exempt from the
## low-tier thinning (the sim is tier-agnostic: a thinned starfish would be an invisible edible). set_site_visible()
## hides an eaten site (zero-scale instance transform) and shows it again (FoodSiteView, from SITE_EATEN /
## SITE_RESPAWNED).

const CHUNK_M: float = 64.0
## Generated piece metadata (size class, footprint, flags): tools/dressing/reef_layout.gd --index writes it.
const PIECE_INDEX_PATH: String = "res://data/env/pieces.json"
const KELP_MATERIAL_PATH: String = "res://shaders/m_env_kelp.tres"
## m_env_kelp sways the tips up to ~2 m outside the mesh AABB.
const KELP_CULL_MARGIN_M: float = 2.5
const DEFAULT_SINK_M: float = 0.08
const MAX_SINK_M: float = 0.9
const ATTEMPTS_PER_TARGET: int = 8
const BLOCKER_CELL_M: float = 16.0
## Extra clearance of avoid_obstacles scatter: base point at least this + FOOTPRINT_CLEAR x piece radius outside.
const OBSTACLE_CLEAR_M: float = 0.25
const FOOTPRINT_CLEAR: float = 0.6
## Set pieces that block scatter (avoid_obstacles rules) with this share of their footprint radius.
const SET_PIECE_BLOCK: float = 0.8
const DEFAULT_RADIUS_M: float = 0.5
const HASH_MASK: int = 0xFFFFFFFF
## Seed salt of the shared clump-centre streams (`clump.group`), far from the rule indices.
const CLUMP_GROUP_SALT: int = 100000

## Food site draw distance (high tier) when the dressing `food` block has no `view_m`.
const FOOD_VIEW_M: float = 45.0

## Filled by build(): counters for benches (the caller adds timings; this file stays clock-free).
var stats: Dictionary = {}

# Food site -> its MultiMesh instance (null = not drawn), instance index, shown transform (chunk-local), shown flag.
var _site_mm: Array[MultiMesh] = []
var _site_k: PackedInt32Array = PackedInt32Array()
var _site_xf: Array[Transform3D] = []
var _site_shown: PackedByteArray = PackedByteArray()


# ================================================================== piece index

## Piece id -> {id, variants (GLBs on disk), size_class, biome, glow, sway, double_sided, footprint_m [x, y, z] (largest
## variant, metres), tags (Array of String), bounds (per variant [min x, min y, min z, size x, size y, size z], metres,
## [] when not indexed)}. Variants come from the GLBs (ContentDB.env_piece_variants()); the other
## keys from PIECE_INDEX_PATH (defaults when a piece is missing there: env_small, footprint 1 m).
static func piece_index() -> Dictionary:
	var meta: Dictionary = {}
	if FileAccess.file_exists(PIECE_INDEX_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PIECE_INDEX_PATH))
		if parsed is Dictionary and (parsed as Dictionary).get("pieces") is Dictionary:
			meta = parsed["pieces"]
	var out: Dictionary = {}
	var variants: Dictionary = ContentDB.env_piece_variants()
	for pid: String in variants:
		var m: Dictionary = meta.get(pid, {}) if meta.get(pid) is Dictionary else {}
		out[pid] = {
			"id": pid,
			"variants": int(variants[pid]),
			"size_class": str(m.get("size_class", "env_small")),
			"biome": str(m.get("biome", "")),
			"glow": bool(m.get("glow", false)),
			"sway": bool(m.get("sway", false)),
			"double_sided": bool(m.get("double_sided", false)),
			"footprint_m": m.get("footprint_m", [1.0, 1.0, 1.0]),
			"tags": m.get("tags", []),
			"bounds": m.get("bounds", []),
		}
	return out


# ================================================================== placements (node-free)

static func compute_placements(dressing: Dictionary, map: Dictionary, seabed: SeabedField, p_piece_index: Dictionary) -> Array:
	var out: Array = []
	var half: float = float(map.get("size_m", 0.0)) * 0.5
	var foot := Rect2(-half, -half, half * 2.0, half * 2.0)
	var zones: Dictionary = _rects(map.get("zones", []))
	var volumes: Dictionary = _rects(map.get("hiding_volumes", []))
	var blockers := _Blockers.new(seabed.obstacles())
	var base_seed: int = int(dressing.get("seed", 0)) & HASH_MASK

	var sets: Array = dressing.get("set_pieces", []) if dressing.get("set_pieces") is Array else []
	for sp: Variant in sets:
		if not (sp is Dictionary):
			continue
		var p: Dictionary = _set_piece(sp, seabed)
		out.append(p)
		var info: Dictionary = p_piece_index.get(p["piece"], {})
		var cls: String = str(info.get("size_class", ""))
		if (cls == "env_medium" or cls == "env_large") and not (sp as Dictionary).has("collision"):
			var pos: Vector3 = p["pos"]
			blockers.add_disc(Vector2(pos.x, pos.z), _radius(p_piece_index, p["piece"]) * float(p["scale"]) * SET_PIECE_BLOCK)

	var rules: Array = dressing.get("scatter", []) if dressing.get("scatter") is Array else []
	for i in rules.size():
		if rules[i] is Dictionary:
			_scatter(rules[i], i, base_seed, foot, zones, volumes, seabed, blockers, p_piece_index, out)
	return out


static func _set_piece(sp: Dictionary, seabed: SeabedField) -> Dictionary:
	var pos := Vector3.ZERO
	var raw: Variant = sp.get("pos")
	if raw is Array and (raw as Array).size() == 3:
		pos = Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	elif raw is Dictionary:
		var xz: Array = (raw as Dictionary).get("xz", [0.0, 0.0])
		pos.x = float(xz[0])
		pos.z = float(xz[1])
		pos.y = seabed.height_at(pos.x, pos.z) - float(sp.get("sink_m", 0.0))
	return {
		"kind": "set_piece",
		"piece": str(sp.get("piece", "")),
		"variant": int(sp.get("variant", 1)),
		"pos": pos,
		"rot_y": deg_to_rad(float(sp.get("rot_y", 0.0))),
		"scale": float(sp.get("scale", 1.0)),
		"zone_id": "",
		"rule": -1,
		"id": str(sp.get("id", "")),
		"up": Vector3.UP,
		"tilt": deg_to_rad(float(sp.get("tilt_deg", 0.0))),
	}


static func _scatter(r: Dictionary, rule_i: int, base_seed: int, foot: Rect2, zones: Dictionary, volumes: Dictionary,
		seabed: SeabedField, blockers: _Blockers, index: Dictionary, out: Array) -> void:
	var zone_id: String = str(r.get("zone_id", ""))
	if not zones.has(zone_id):
		return
	var zone: Rect2 = (zones[zone_id] as Rect2).intersection(foot)
	var regions: Array[Rect2] = []
	if r.get("hiding_volume_ids") is Array:
		for vid: Variant in r["hiding_volume_ids"]:
			if volumes.has(str(vid)):
				var part: Rect2 = (volumes[str(vid)] as Rect2).intersection(zone)
				if part.has_area():
					regions.append(part)
	elif zone.has_area():
		regions.append(zone)
	var area: float = 0.0
	for reg in regions:
		area += reg.get_area()
	var target: int = roundi(float(r.get("density_per_100m2", 0.0)) * area / 100.0)
	if target <= 0:
		return

	var pieces: Array = r.get("pieces", [])
	var cum := PackedFloat64Array()
	var total_w: float = 0.0
	var vlists: Array = []
	for pe: Variant in pieces:
		total_w += float((pe as Dictionary).get("weight", 1.0))
		cum.append(total_w)
		vlists.append(_variants((pe as Dictionary).get("variants", 1)))
	var depth_r: Array = r.get("depth_m", [0.0, 1.0e9])
	var d0: float = float(depth_r[0])
	var d1: float = float(depth_r[1])
	var scale_r: Array = r.get("scale", [1.0, 1.0])
	var rot: Variant = r.get("rot_y", "random")
	var align: bool = bool(r.get("align_to_slope", false))
	var avoid: bool = bool(r.get("avoid_obstacles", false))
	var spacing: float = float(r.get("min_spacing_m", 0.0))
	var min_ny: float = cos(deg_to_rad(float(r.get("max_slope_deg", 90.0))))
	var sink_base: float = float(r.get("sink_m", DEFAULT_SINK_M))
	var clump_n := Vector2i(1, 1)
	var clump_r: float = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = _mix(base_seed, rule_i)
	# clump centres: the rule's own stream, or a shared stream per clump `group` (rules of one group and zone put
	# their clumps on the same spots, e.g. rocks + corals + small props = one reef patch)
	var centre_rng: RandomNumberGenerator = rng
	if r.get("clump") is Dictionary:
		var cl: Dictionary = r["clump"]
		var cn: Array = cl.get("count", [1, 1])
		clump_n = Vector2i(int(cn[0]), int(cn[1]))
		clump_r = float(cl.get("radius_m", 0.0))
		if cl.has("group"):
			centre_rng = RandomNumberGenerator.new()
			centre_rng.seed = _mix(base_seed, CLUMP_GROUP_SALT + int(cl["group"]))
	var grid: Dictionary = {}
	var cell: float = maxf(spacing, 0.5)
	var placed: int = 0
	var attempts: int = 0
	var max_attempts: int = target * ATTEMPTS_PER_TARGET + 64
	while placed < target and attempts < max_attempts:
		var reg: Rect2 = _pick_region(regions, area, centre_rng.randf())
		var centre := Vector2(reg.position.x + centre_rng.randf() * reg.size.x, reg.position.y + centre_rng.randf() * reg.size.y)
		var n: int = rng.randi_range(clump_n.x, clump_n.y)
		for k in n:
			if placed >= target:
				break
			attempts += 1
			var xz: Vector2 = centre
			if clump_r > 0.0 and (k > 0 or centre_rng != rng):
				var ang: float = rng.randf() * TAU
				xz += Vector2(cos(ang), sin(ang)) * clump_r * sqrt(rng.randf())
			# draw every random value of the candidate up front: the stream does not depend on rejections
			var u_piece: float = rng.randf() * total_w
			var u_variant: float = rng.randf()
			var u_scale: float = rng.randf()
			var u_rot: float = rng.randf()
			if not _in_regions(regions, xz):
				continue
			var h: float = seabed.height_at(xz.x, xz.y)
			if -h < d0 or -h > d1:
				continue
			var nrm: Vector3 = seabed.normal_at(xz.x, xz.y)
			if nrm.y < min_ny:
				continue
			var pi_: int = cum.bsearch(u_piece, false)
			pi_ = mini(pi_, pieces.size() - 1)
			var pid: String = str((pieces[pi_] as Dictionary).get("id", ""))
			var vl: Array = vlists[pi_]
			var variant: int = int(vl[mini(int(u_variant * vl.size()), vl.size() - 1)])
			var s: float = lerpf(float(scale_r[0]), float(scale_r[1]), u_scale)
			var radius: float = _radius(index, pid) * s
			var base := Vector3(xz.x, h, xz.y)
			if avoid and not blockers.clear(base, OBSTACLE_CLEAR_M + radius * FOOTPRINT_CLEAR):
				continue
			if spacing > 0.0 and not _spacing_ok(grid, cell, xz, spacing):
				continue
			var sink: float = sink_base
			if not align:
				var slope_t: float = sqrt(maxf(1.0 - nrm.y * nrm.y, 0.0)) / maxf(nrm.y, 0.1)
				sink += radius * slope_t * 0.5
			sink = minf(sink, MAX_SINK_M)
			if spacing > 0.0:
				var key := Vector2i(floori(xz.x / cell), floori(xz.y / cell))
				if not grid.has(key):
					grid[key] = PackedVector2Array()
				var bucket: PackedVector2Array = grid[key]
				bucket.append(xz)
				grid[key] = bucket
			var rot_y: float = u_rot * TAU if not (rot is float or rot is int) else deg_to_rad(float(rot))
			out.append({
				"kind": "scatter",
				"piece": pid,
				"variant": variant,
				"pos": Vector3(xz.x, h - sink, xz.y),
				"rot_y": rot_y,
				"scale": s,
				"zone_id": zone_id,
				"rule": rule_i,
				"id": "",
				"up": nrm if align else Vector3.UP,
				"tilt": 0.0,
			})
			placed += 1


static func _spacing_ok(grid: Dictionary, cell: float, xz: Vector2, spacing: float) -> bool:
	var c := Vector2i(floori(xz.x / cell), floori(xz.y / cell))
	var reach: int = ceili(spacing / cell)
	var s2: float = spacing * spacing
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var key := Vector2i(c.x + dx, c.y + dz)
			if not grid.has(key):
				continue
			for q: Vector2 in (grid[key] as PackedVector2Array):
				if q.distance_squared_to(xz) < s2:
					return false
	return true


static func _pick_region(regions: Array[Rect2], area: float, u: float) -> Rect2:
	var acc: float = 0.0
	for reg in regions:
		acc += reg.get_area()
		if u * area <= acc:
			return reg
	return regions[regions.size() - 1]


static func _in_regions(regions: Array[Rect2], xz: Vector2) -> bool:
	for reg in regions:
		if xz.x >= reg.position.x and xz.x <= reg.end.x and xz.y >= reg.position.y and xz.y <= reg.end.y:
			return true
	return false


## id -> XZ Rect2 of `zones` / `hiding_volumes` records ({id, aabb: {min, max}}).
static func _rects(list: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (list is Array):
		return out
	for z: Variant in list:
		if not (z is Dictionary) or not ((z as Dictionary).get("aabb") is Dictionary):
			continue
		var lo: Array = z["aabb"].get("min", [0, 0, 0])
		var hi: Array = z["aabb"].get("max", [0, 0, 0])
		out[str(z.get("id", ""))] = Rect2(float(lo[0]), float(lo[2]), float(hi[0]) - float(lo[0]), float(hi[2]) - float(lo[2]))
	return out


static func _variants(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for item: Variant in v:
			out.append(int(item))
	else:
		for k in range(1, int(v) + 1):
			out.append(k)
	if out.is_empty():
		out.append(1)
	return out


## Horizontal footprint radius of a piece at scale 1 (half the larger XZ extent; DEFAULT_RADIUS_M when unknown).
static func _radius(index: Dictionary, pid: String) -> float:
	var info: Variant = index.get(pid)
	if info is Dictionary and (info as Dictionary).get("footprint_m") is Array and (info["footprint_m"] as Array).size() == 3:
		var f: Array = info["footprint_m"]
		return maxf(float(f[0]), float(f[2])) * 0.5
	return DEFAULT_RADIUS_M


## 32-bit mix of the dressing seed and a rule index (one independent stream per rule).
static func _mix(a: int, b: int) -> int:
	var h: int = (a * 0x9E3779B1 + (b + 1) * 0x85EBCA77) & HASH_MASK
	h = ((h ^ (h >> 15)) * 0x2C1B3C6D) & HASH_MASK
	h = ((h ^ (h >> 12)) * 0x297A2D39) & HASH_MASK
	return h ^ (h >> 15)


## Obstacle primitives (signed distance) plus XZ discs (set piece footprints), bucketed on a coarse XZ grid.
class _Blockers extends RefCounted:
	var _prims: Array[Dictionary] = []
	var _discs: Array[Vector3] = []  # x, z, radius
	var _cells: Dictionary = {}  # Vector2i -> PackedInt32Array (prims >= 0, discs: -1 - index)

	func _init(obstacles: Array[Dictionary]) -> void:
		for o: Dictionary in obstacles:
			if bool(o.get("baked", false)):
				continue
			var lo := Vector2.ZERO
			var hi := Vector2.ZERO
			match str(o.get("kind", "")):
				"sphere":
					var c: Vector3 = o["center"]
					var r: float = float(o["radius"])
					lo = Vector2(c.x - r, c.z - r)
					hi = Vector2(c.x + r, c.z + r)
				"capsule":
					var a: Vector3 = o["a"]
					var b: Vector3 = o["b"]
					var rc: float = float(o["radius"])
					lo = Vector2(minf(a.x, b.x) - rc, minf(a.z, b.z) - rc)
					hi = Vector2(maxf(a.x, b.x) + rc, maxf(a.z, b.z) + rc)
				"box":
					var cb: Vector3 = o["center"]
					var hs: Vector3 = (o["size"] as Vector3) * 0.5
					lo = Vector2(cb.x - hs.x, cb.z - hs.z)
					hi = Vector2(cb.x + hs.x, cb.z + hs.z)
				"obb":
					var co: Vector3 = o["center"]
					var ro: float = (o["size"] as Vector3).length() * 0.5
					lo = Vector2(co.x - ro, co.z - ro)
					hi = Vector2(co.x + ro, co.z + ro)
				_:
					continue
			_prims.append(o)
			_insert(lo, hi, _prims.size() - 1)

	func add_disc(c: Vector2, r: float) -> void:
		_discs.append(Vector3(c.x, c.y, r))
		_insert(c - Vector2(r, r), c + Vector2(r, r), -_discs.size())

	## True when `p` is at least `margin` outside every primitive and disc.
	func clear(p: Vector3, margin: float) -> bool:
		var key := Vector2i(floori(p.x / MapDressing.BLOCKER_CELL_M), floori(p.z / MapDressing.BLOCKER_CELL_M))
		if not _cells.has(key):
			return true
		for k: int in (_cells[key] as PackedInt32Array):
			if k < 0:
				var d: Vector3 = _discs[-1 - k]
				if Vector2(p.x - d.x, p.z - d.y).length() < d.z + margin:
					return false
			elif MapDressing.sdf(_prims[k], p) < margin:
				return false
		return true

	func _insert(lo: Vector2, hi: Vector2, k: int) -> void:
		# grown by the largest margin a query uses (radius ~ 4 m pieces); cells are coarse anyway
		var g: float = 6.0
		var c0 := Vector2i(floori((lo.x - g) / MapDressing.BLOCKER_CELL_M), floori((lo.y - g) / MapDressing.BLOCKER_CELL_M))
		var c1 := Vector2i(floori((hi.x + g) / MapDressing.BLOCKER_CELL_M), floori((hi.y + g) / MapDressing.BLOCKER_CELL_M))
		for x in range(c0.x, c1.x + 1):
			for z in range(c0.y, c1.y + 1):
				var key := Vector2i(x, z)
				if not _cells.has(key):
					_cells[key] = PackedInt32Array()
				var arr: PackedInt32Array = _cells[key]
				arr.append(k)
				_cells[key] = arr


## Signed distance from `p` to a SeabedField obstacle record (negative inside).
static func sdf(o: Dictionary, p: Vector3) -> float:
	match str(o.get("kind", "")):
		"sphere":
			return p.distance_to(o["center"]) - float(o["radius"])
		"capsule":
			var a: Vector3 = o["a"]
			var ab: Vector3 = (o["b"] as Vector3) - a
			var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			return p.distance_to(a + ab * t) - float(o["radius"])
		"box":
			var q: Vector3 = (p - (o["center"] as Vector3)).abs() - (o["size"] as Vector3) * 0.5
			return Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
		"obb":
			var rnd: float = float(o["round"])
			var l: Vector3 = (o["rot"] as Quaternion).inverse() * (p - (o["center"] as Vector3))
			var qo: Vector3 = l.abs() - ((o["size"] as Vector3) * 0.5 - Vector3.ONE * rnd)
			return qo.max(Vector3.ZERO).length() + minf(maxf(qo.x, maxf(qo.y, qo.z)), 0.0) - rnd
	return INF


# ================================================================== nodes

## Builds the dressing nodes of `map` (children of this node; safe to call again). `tier`: QualitySettings tier
## (draw distance, scatter density multiplier). `food_sites`: the baked food site records of the map (class doc).
## Returns the placement list it used.
func build(dressing: Dictionary, map: Dictionary, seabed: SeabedField, tier: StringName, food_sites: Array = []) -> Array:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var index: Dictionary = piece_index()
	var list: Array = compute_placements(dressing, map, seabed, index)
	var prof: Dictionary = QualitySettings.profile(tier)
	var high: Dictionary = QualitySettings.profile(QualitySettings.HIGH)
	var draw_m: float = float(prof["draw_distance_m"])
	var tier_scale: float = draw_m / maxf(float(high["draw_distance_m"]), 1.0)
	var density_mult: float = float(prof.get("dressing_density_mult", 1.0))
	var rules: Array = dressing.get("scatter", []) if dressing.get("scatter") is Array else []
	var meshes: Dictionary = {}
	var kelp: Material = load(KELP_MATERIAL_PATH) as Material if ResourceLoader.exists(KELP_MATERIAL_PATH) else null

	# food: edible pieces (never thinned) and the decor placement of each edible decor site
	var food: Dictionary = dressing.get("food", {}) if dressing.get("food") is Dictionary else {}
	var edible: Dictionary = {}
	if food.get("edible_decor") is Dictionary:
		for pid: Variant in (food["edible_decor"] as Dictionary):
			edible[str(pid)] = true
	var decor_site: Dictionary = {}
	for s in food_sites.size():
		var rec: Dictionary = food_sites[s] if food_sites[s] is Dictionary else {}
		edible[str(rec.get("piece", ""))] = true
		if int(rec.get("decor", -1)) >= 0:
			decor_site[int(rec["decor"])] = s
	_site_mm.clear()
	_site_mm.resize(food_sites.size())
	_site_k.resize(food_sites.size())
	_site_xf.clear()
	_site_xf.resize(food_sites.size())
	_site_shown.resize(food_sites.size())
	_site_shown.fill(0)

	# scatter: bucket by piece variant, chunk and view distance
	var buckets: Dictionary = {}
	var thinned: int = 0
	for i in list.size():
		var p: Dictionary = list[i]
		if p["kind"] != "scatter":
			continue
		var pid: String = p["piece"]
		var info: Dictionary = index.get(pid, {})
		if density_mult < 1.0 and not pid.contains("kelp") and not edible.has(pid) and str(info.get("size_class", "env_small")) == "env_small" \
				and _hash01(i) >= density_mult:
			thinned += 1
			continue
		var rule: Dictionary = rules[int(p["rule"])] if int(p["rule"]) < rules.size() else {}
		var view: float = minf(float(rule.get("view_m", high["draw_distance_m"])) * tier_scale, draw_m)
		_bucket(buckets, p, view, int(decor_site.get(i, -1)))
	# own food pieces (eggs, snails) from the baked records
	var food_view: float = minf(float(food.get("view_m", FOOD_VIEW_M)) * tier_scale, draw_m)
	for s in food_sites.size():
		if food_sites[s] is Dictionary and int((food_sites[s] as Dictionary).get("decor", -1)) < 0:
			_bucket(buckets, FoodPlacement.placement_of(food_sites[s]), food_view, s)

	var keys: Array = buckets.keys()
	keys.sort()
	var instances: int = 0
	for key: String in keys:
		var b: Dictionary = buckets[key]
		var mesh: Mesh = _mesh(meshes, b["piece"], b["variant"])
		if mesh == null:
			continue
		var items: Array = b["items"]
		var sites: Array = b["sites"]
		var origin := Vector3.ZERO
		for p: Dictionary in items:
			origin += p["pos"]
		origin /= float(items.size())
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = items.size()
		for k in items.size():
			var xf: Transform3D = placement_transform(items[k])
			xf.origin -= origin
			mm.set_instance_transform(k, xf)
			var site: int = sites[k]
			if site >= 0:
				_site_mm[site] = mm
				_site_k[site] = k
				_site_xf[site] = xf
				_site_shown[site] = 1
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Scatter_%s" % key.replace("|", "_").replace("-", "m")
		mmi.multimesh = mm
		mmi.position = origin
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = float(b["view"]) + CHUNK_M * 0.71
		if kelp != null and str(b["piece"]).contains("kelp"):
			mmi.material_override = kelp
			mmi.extra_cull_margin = KELP_CULL_MARGIN_M
		mmi.add_to_group(&"env_dressing")
		add_child(mmi)
		instances += items.size()

	var set_nodes: int = 0
	for p: Dictionary in list:
		if p["kind"] != "set_piece":
			continue
		var mesh2: Mesh = _mesh(meshes, p["piece"], p["variant"])
		if mesh2 == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Set_%s" % p["id"]
		mi.mesh = mesh2
		mi.transform = placement_transform(p)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = draw_m + mesh2.get_aabb().size.length() * float(p["scale"])
		if kelp != null and str(p["piece"]).contains("kelp"):
			mi.material_override = kelp
		mi.add_to_group(&"env_dressing")
		add_child(mi)
		set_nodes += 1

	stats = {
		"dressing_placements": list.size(),
		"dressing_instances": instances,
		"dressing_thinned": thinned,
		"dressing_multimeshes": buckets.size(),
		"dressing_set_pieces": set_nodes,
		"dressing_food_sites": _site_shown.count(1),
	}
	return list


func bench_stats() -> Dictionary:
	return stats


## Shows / hides the drawn instance of food site `site` (no-op for a site that is not drawn).
func set_site_visible(site: int, shown: bool) -> void:
	if site < 0 or site >= _site_mm.size() or _site_mm[site] == null:
		return
	var xf: Transform3D = _site_xf[site]
	_site_mm[site].set_instance_transform(_site_k[site], xf if shown else Transform3D(Basis.from_scale(Vector3.ZERO), xf.origin))
	_site_shown[site] = 1 if shown else 0


## True while food site `site` is drawn and shown.
func is_site_visible(site: int) -> bool:
	return site >= 0 and site < _site_shown.size() and _site_shown[site] == 1


## The instance of food site `site` after build(): {multimesh: MultiMesh, index: int} ({} when it is not drawn).
func site_slot(site: int) -> Dictionary:
	if site < 0 or site >= _site_mm.size() or _site_mm[site] == null:
		return {}
	return {"multimesh": _site_mm[site], "index": _site_k[site]}


# Adds placement `p` (food site `site`, -1 = none) to its piece variant / chunk / view distance bucket.
static func _bucket(buckets: Dictionary, p: Dictionary, view: float, site: int) -> void:
	var pos: Vector3 = p["pos"]
	var pid: String = p["piece"]
	var key: String = "%s|%d|%d|%d|%d" % [pid, int(p["variant"]), floori(pos.x / CHUNK_M), floori(pos.z / CHUNK_M), roundi(view)]
	if not buckets.has(key):
		buckets[key] = {"piece": pid, "variant": int(p["variant"]), "view": view, "items": [], "sites": []}
	(buckets[key]["items"] as Array).append(p)
	(buckets[key]["sites"] as Array).append(site)


## World transform of a placement: rot_y about UP, then (set pieces) `tilt` about the local X axis, (aligned scatter)
## the up vector turned to the seabed normal, uniform scale, translation to pos.
static func placement_transform(p: Dictionary) -> Transform3D:
	var basis := Basis(Vector3.UP, float(p.get("rot_y", 0.0)))
	var tilt: float = float(p.get("tilt", 0.0))
	if tilt != 0.0:
		basis = basis * Basis(Vector3.RIGHT, tilt)
	var up: Vector3 = p.get("up", Vector3.UP)
	if not up.is_equal_approx(Vector3.UP):
		basis = Basis(Quaternion(Vector3.UP, up.normalized())) * basis
	return Transform3D(basis.scaled(Vector3.ONE * float(p.get("scale", 1.0))), p["pos"])


func _mesh(cache: Dictionary, pid: String, variant: int) -> Mesh:
	var key: String = "%s|%d" % [pid, variant]
	if cache.has(key):
		return cache[key]
	var path: String = "%s/env_%s_v%d_lod0.glb" % [ContentDB.ENV_MODELS_DIR, pid, variant]
	var mesh: Mesh = null
	var scene: PackedScene = load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		var root: Node = scene.instantiate()
		var found: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
		if root is MeshInstance3D:
			found.push_front(root)
		if not found.is_empty():
			mesh = (found[0] as MeshInstance3D).mesh
		root.free()
	if mesh == null:
		push_warning("MapDressing: no mesh for %s" % path)
	cache[key] = mesh
	return mesh


static func _hash01(i: int) -> float:
	var h: int = (i * 0x9E3779B1 + 0x7F4A7C15) & HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & HASH_MASK
	h ^= h >> 16
	return float(h) / 4294967296.0
