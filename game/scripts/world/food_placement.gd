class_name FoodPlacement
extends RefCounted
## Food site placement (food task X1): derives the food sites of a map from its dressing `food` block (host rules,
## data reference: game/data/README.md "Food keys"), the dressing placements (MapDressing.compute_placements), the
## seabed WITH the baked proxies (so rocks count) and the env piece index (bounds). Pure and deterministic: no global
## RNG, no clock, inputs untouched; every random value comes from a RandomNumberGenerator seeded per (food rule, host
## scatter rule, host piece, host ordinal within that rule and piece), so appending a scatter rule or a food rule
## never reshuffles the other sites. The only other input is the host meshes (the env GLBs, read for the `top` anchor:
## a ray grid over the mesh top; the authored anchors were measured the same way by tools/dressing/reef_layout.gd).
## Used by tools/dressing/bake_food.gd (writes maps/<map_id>_food.json, which the sim reads through ContentDB /
## FoodSites) and tests; the game never calls derive() at runtime (MapDressing draws the baked records).
##
## Site order (= site ids): every placement of an `edible_decor` piece (dressing order; the drawn decor itself is the
## site, `decor` = its placement index; a decor centre that is not clear of the obstacles by reach_clearance_m, e.g. a
## starfish under a scattered boulder, is moved out to the obstacle surface by SeabedField.resolve), then the rules in
## order (hosts in placement order, `count` items each), then the `authored` anchors. `host` = the host placement
## index. Anchors:
##  - top: a SPOT_GRID x SPOT_GRID ray grid over the host variant bounds (`inset` x the half extents around the bounds
##    centre) finds the mesh top; spots steeper than max_slope_deg are dropped, one of the SPOT_PICK highest is used;
##    the item stands on it along the host up axis, sunk sink_m.
##  - base_ring: on the seabed (aligned to its normal, sunk sink_m) at `ring` x the host footprint radius x host scale
##    from the host origin, random direction.
##  - stem: on the host axis (local x = z = 0: kelp stipe, tube worm) at `stem_y` metres (host frame, scaled with the
##    host) above the base; the item's ring sits around the stem.
##  - authored: `local` = attachment point in the host set piece frame (ledge underside); the item hangs from it: base
##    = attachment - up x (variant top x scale - HANG_OVERLAP_M) (the hanging pearl strands have their attachment plane
##    at the bounds top).
## Edge current: no site (edible decor included: that decor is drawn but not edible) whose centre lies inside the map
## `bounds.soft_margin_m` of the map edge, where SimWorld's edge current outruns a small fish.
## Filters (rule sites; authored: the same with the free-water check below instead of above): the site centre is
## obstacle_clear by reach_clearance_m, the point ABOVE_CHECK_M above it (below: HANG_CHECK_M) is clear, the seabed
## under the centre is below it, and the centre keeps MIN_SPACING_M from every other food site on the same host.
## Piece choice of a rule without `piece`: the first entry of the food type's `pieces` whose `zones` contain the host
## zone (scatter zone_id) and whose above_y / below_y window contains the item base y (snail: orange in A/B, cyan
## above y -65, violet below). Site centre = placement transform x the variant bounds centre (never below
## MIN_ABOVE_SEABED_M over the seabed); site radius = max(type radius_m, half the smaller plan extent x scale).

const FOOD_DIR: String = "res://data/food"
const DEFAULT_CLEARANCE_M: float = 0.05
const DEFAULT_SINK_M: float = 0.01
const DEFAULT_INSET: float = 0.5
const DEFAULT_MAX_SLOPE_DEG: float = 30.0
const DEFAULT_SCALE: Array = [0.9, 1.1]
const DEFAULT_RING: Array = [0.6, 0.9]
const DEFAULT_STEM_Y: Array = [0.3, 0.7]
const SPOT_GRID: int = 7
const SPOT_PICK: int = 6
const MIN_SPACING_M: float = 0.35
const ABOVE_CHECK_M: float = 0.15
const HANG_CHECK_M: float = 0.3
## A hanging piece reaches this far into its ledge (no visible gap).
const HANG_OVERLAP_M: float = 0.01
const MIN_ABOVE_SEABED_M: float = 0.03
## Extra clearance of the filters over reach_clearance_m: the baked numbers are rounded to POS_STEP.
const CLEAR_MARGIN_M: float = 0.002
## Salts of the per-host streams (the scatter rule index of set pieces is -1).
const SALT_RULE: int = 1000
const POS_STEP: float = 0.001
const ROT_STEP: float = 0.0001
const GENERATED_BY: String = "tools/dressing/bake_food.gd -- --write (FoodPlacement.derive from the dressing food block; do not edit)"


## Food type records of `root`/food (id -> record), read directly (the bake does not need a full ContentDB).
static func food_types(root: String = "res://data") -> Dictionary:
	var out: Dictionary = {}
	var dir: String = root.path_join("food")
	var d := DirAccess.open(dir)
	if d == null:
		return out
	var files: PackedStringArray = d.get_files()
	files.sort()
	for f in files:
		if f.get_extension() == "json":
			var rec: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f)))
			if rec is Dictionary:
				out[f.get_basename()] = rec
	return out


## Food site records (JSON-ready, rounded; keys in ContentDB._check_food_sites) for `dressing` on `map`. `seabed` must
## include the baked proxies (SeabedField.from_map(map, ContentDB.get_proxies)); `types` = food type records (default:
## food_types()); `stats` (optional out) gets per rule id {hosts, tries, kept, obstacle, reach, buried, spacing, spot}.
static func derive(dressing: Dictionary, map: Dictionary, seabed: SeabedField, piece_index: Dictionary, types: Dictionary = {},
		stats: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var food: Dictionary = dressing.get("food", {}) if dressing.get("food") is Dictionary else {}
	if food.is_empty():
		return out
	if types.is_empty():
		types = food_types()
	var list: Array = MapDressing.compute_placements(dressing, map, seabed, piece_index)
	var fseed: int = int(food.get("seed", 0)) & MapDressing.HASH_MASK
	var clearance: float = float(food.get("reach_clearance_m", DEFAULT_CLEARANCE_M))
	var bounds: Dictionary = map.get("bounds", {}) if map.get("bounds") is Dictionary else {}
	var inner: float = float(map.get("size_m", 0.0)) * 0.5 - float(bounds.get("soft_margin_m", 0.0))
	var meshes: Dictionary = {}
	var used: Dictionary = {}  # host placement index -> PackedVector3Array of food site centres

	# host ordinal within (scatter rule, piece): the stream key that survives appended rules
	var ordinal := PackedInt32Array()
	var seen: Dictionary = {}
	for p: Dictionary in list:
		var okey: String = "%d|%s" % [int(p["rule"]), p["piece"]]
		ordinal.append(int(seen.get(okey, 0)))
		seen[okey] = int(seen.get(okey, 0)) + 1

	var decor: Dictionary = food.get("edible_decor", {}) if food.get("edible_decor") is Dictionary else {}
	var dst: Dictionary = {"hosts": 0, "kept": 0, "moved": 0, "margin": 0}
	stats["decor"] = dst
	for i in list.size():
		var p: Dictionary = list[i]
		if not decor.has(p["piece"]):
			continue
		var t: Dictionary = types.get(str(decor[p["piece"]]), {})
		var c: Vector3 = _centre(p, piece_index)
		c.y = maxf(c.y, seabed.height_at(c.x, c.z) + MIN_ABOVE_SEABED_M)
		dst["hosts"] += 1
		if _in_margin(c, inner):
			dst["margin"] += 1
			continue
		dst["kept"] += 1
		if not seabed.obstacle_clear(c, clearance + CLEAR_MARGIN_M):
			# decor partly (or wholly) inside a scattered rock: the sim point moves out to the rock surface
			c = seabed.resolve(c, clearance + 2.0 * CLEAR_MARGIN_M)
			dst["moved"] += 1
		out.append(_record(str(decor[p["piece"]]), p, c, _site_radius(t, p, piece_index), i, i, "decor"))

	var rules: Array = food.get("rules", []) if food.get("rules") is Array else []
	for fr in rules.size():
		if not (rules[fr] is Dictionary):
			continue
		var r: Dictionary = rules[fr]
		var st: Dictionary = {"hosts": 0, "tries": 0, "kept": 0, "margin": 0, "obstacle": 0, "reach": 0, "buried": 0, "spacing": 0, "spot": 0}
		stats[str(r.get("id", fr))] = st
		var hosts: Array = r.get("hosts", [])
		var zones: Array = r.get("zones", []) if r.get("zones") is Array else []
		var t: Dictionary = types.get(str(r.get("food", "")), {})
		if t.is_empty():
			continue
		var chance: float = float(r.get("chance", 0.0))
		var cnt: Array = r.get("count", [1, 1])
		var sc: Array = r.get("scale", DEFAULT_SCALE)
		var anchor: String = str(r.get("anchor", "top"))
		var sink: float = float(r.get("sink_m", DEFAULT_SINK_M))
		for i in list.size():
			var h: Dictionary = list[i]
			if not hosts.has(h["piece"]) or (not zones.is_empty() and not zones.has(h["zone_id"])):
				continue
			st["hosts"] += 1
			var rng := RandomNumberGenerator.new()
			rng.seed = MapDressing._mix(MapDressing._mix(MapDressing._mix(fseed, fr), SALT_RULE + int(h["rule"])), (str(h["piece"]).hash() & 0xFFFF) * 65536 + ordinal[i])
			if rng.randf() >= chance:
				continue
			var n: int = rng.randi_range(int(cnt[0]), int(cnt[1]))
			var hxf: Transform3D = MapDressing.placement_transform(h)
			var hup: Vector3 = hxf.basis.y.normalized()
			for k in n:
				st["tries"] += 1
				# every random value of the item up front: the stream does not depend on rejections
				var u_a: float = rng.randf()
				var u_b: float = rng.randf()
				var u_rot: float = rng.randf()
				var u_scale: float = rng.randf()
				var u_var: float = rng.randf()
				var base: Vector3
				var up: Vector3 = hup
				match anchor:
					"top":
						var spots: Array = _top_spots(meshes, piece_index, str(h["piece"]), int(h["variant"]), float(r.get("inset", DEFAULT_INSET)),
							float(r.get("max_slope_deg", DEFAULT_MAX_SLOPE_DEG)))
						if spots.is_empty():
							st["spot"] += 1
							continue
						var spot: Vector3 = spots[mini(int(u_a * mini(SPOT_PICK, spots.size())), spots.size() - 1)]
						base = hxf * spot - hup * sink
					"base_ring":
						var ring: Array = r.get("ring", DEFAULT_RING)
						var ang: float = u_a * TAU
						var rad: float = lerpf(float(ring[0]), float(ring[1]), u_b) * MapDressing._radius(piece_index, str(h["piece"])) * float(h["scale"])
						var hp: Vector3 = h["pos"]
						var x: float = hp.x + cos(ang) * rad
						var z: float = hp.z + sin(ang) * rad
						up = seabed.normal_at(x, z)
						base = Vector3(x, seabed.height_at(x, z), z) - up * sink
					"stem":
						var sy: Array = r.get("stem_y", DEFAULT_STEM_Y)
						base = hxf * Vector3(0.0, lerpf(float(sy[0]), float(sy[1]), u_a), 0.0)
					_:
						continue
				var pid: String = str(r["piece"]) if r.get("piece") is String else _choose_piece(t, str(h["zone_id"]), base.y)
				if pid.is_empty() or not piece_index.has(pid):
					st["spot"] += 1
					continue
				var variants: Array = MapDressing._variants(r.get("variants", int((piece_index[pid] as Dictionary).get("variants", 1))))
				var fp: Dictionary = {
					"kind": "food", "piece": pid, "variant": int(variants[mini(int(u_var * variants.size()), variants.size() - 1)]),
					"pos": base, "rot_y": u_rot * TAU, "scale": lerpf(float(sc[0]), float(sc[1]), u_scale),
					"up": up, "tilt": 0.0, "zone_id": h["zone_id"], "rule": -1, "id": "",
				}
				var centre: Vector3 = _centre(fp, piece_index)
				var why: String = "margin" if _in_margin(centre, inner) else _reject(seabed, centre, up, clearance, false, used.get(i, PackedVector3Array()))
				if not why.is_empty():
					st[why] += 1
					continue
				_use(used, i, centre)
				out.append(_record(str(r["food"]), fp, centre, _site_radius(t, fp, piece_index), -1, i, str(r.get("id", ""))))
				st["kept"] += 1

	var sets: Dictionary = {}
	for i in list.size():
		if list[i]["kind"] == "set_piece":
			sets[list[i]["id"]] = i
	var authored: Array = food.get("authored", []) if food.get("authored") is Array else []
	var ast: Dictionary = {"hosts": authored.size(), "tries": authored.size(), "kept": 0, "margin": 0, "obstacle": 0, "reach": 0, "buried": 0, "spacing": 0, "spot": 0}
	stats["authored"] = ast
	for a: Variant in authored:
		var ad: Dictionary = a
		var hi: int = int(sets.get(str(ad.get("host", "")), -1))
		var t: Dictionary = types.get(str(ad.get("food", "")), {})
		var pid: String = str(ad.get("piece", ""))
		if hi < 0 or t.is_empty() or not piece_index.has(pid):
			ast["spot"] += 1
			continue
		var h: Dictionary = list[hi]
		var loc: Array = ad["local"]
		var attach: Vector3 = MapDressing.placement_transform(h) * Vector3(float(loc[0]), float(loc[1]), float(loc[2]))
		var v: int = int(ad.get("variant", 1))
		var s: float = float(ad.get("scale", 1.0))
		var fp: Dictionary = {
			"kind": "food", "piece": pid, "variant": v,
			"pos": attach - Vector3.UP * (_top(piece_index, pid, v) * s - HANG_OVERLAP_M),
			"rot_y": float(h["rot_y"]) + deg_to_rad(float(ad.get("rot_y", 0.0))), "scale": s,
			"up": Vector3.UP, "tilt": 0.0, "zone_id": "", "rule": -1, "id": "",
		}
		var centre: Vector3 = _centre(fp, piece_index)
		var why: String = "margin" if _in_margin(centre, inner) else _reject(seabed, centre, Vector3.UP, clearance, true, used.get(hi, PackedVector3Array()))
		if not why.is_empty():
			ast[why] += 1
			continue
		_use(used, hi, centre)
		out.append(_record(str(ad["food"]), fp, centre, _site_radius(t, fp, piece_index), -1, hi, "authored"))
		ast["kept"] += 1
	return out


## Text of maps/<map_id>_food.json (one site per line, stable order and number format).
static func sites_text(records: Array[Dictionary], map_id: String, dressing_seed: int, food_seed: int) -> String:
	var lines: PackedStringArray = []
	for r: Dictionary in records:
		lines.append('\t\t{ "type": "%s", "piece": "%s", "variant": %d, "pos": %s, "radius": %s, "base": %s, "rot_y": %s, "up": %s, "scale": %s, "decor": %d, "host": %d, "rule": "%s" }' % [
			r["type"], r["piece"], int(r["variant"]), DressingProxies._list(r["pos"], 3), DressingProxies.num_text(float(r["radius"]), 3),
			DressingProxies._list(r["base"], 3), DressingProxies.num_text(float(r["rot_y"]), 4), DressingProxies._list(r["up"], 4),
			DressingProxies.num_text(float(r["scale"]), 3), int(r["decor"]), int(r["host"]), r["rule"]])
	return '{\n\t"generated_by": "%s",\n\t"map": "%s",\n\t"dressing_seed": %d,\n\t"food_seed": %d,\n\t"sites": [\n%s\n\t]\n}\n' % [
		GENERATED_BY, map_id, dressing_seed, food_seed, ",\n".join(lines)]


## A baked site record as a MapDressing placement (kind "food"; base, rot_y, up, scale -> placement_transform).
static func placement_of(rec: Dictionary) -> Dictionary:
	var b: Array = rec.get("base", [0, 0, 0])
	var u: Array = rec.get("up", [0, 1, 0])
	return {
		"kind": "food", "piece": str(rec.get("piece", "")), "variant": int(rec.get("variant", 1)),
		"pos": Vector3(float(b[0]), float(b[1]), float(b[2])), "rot_y": float(rec.get("rot_y", 0.0)),
		"scale": float(rec.get("scale", 1.0)), "up": Vector3(float(u[0]), float(u[1]), float(u[2])).normalized(),
		"tilt": 0.0, "zone_id": "", "rule": -1, "id": "",
	}


## First hit of a ray (piece frame, unit scale) on the drawn mesh of piece variant `v` (the first MeshInstance3D of
## the GLB, like MapDressing): {position, normal} or {} (no hit / no mesh). `cache`: shared TriangleMesh cache.
static func ray_piece(cache: Dictionary, pid: String, v: int, from: Vector3, dir: Vector3) -> Dictionary:
	var tm: TriangleMesh = _tri_mesh(cache, pid, v)
	if tm == null:
		return {}
	return tm.intersect_ray(from, dir)


# ------------------------------------------------------------------ internals

static func _record(type: String, p: Dictionary, centre: Vector3, radius: float, decor: int, host: int, rule: String) -> Dictionary:
	var b: Vector3 = p["pos"]
	var u: Vector3 = (p.get("up", Vector3.UP) as Vector3).normalized()
	return {
		"type": type, "piece": p["piece"], "variant": int(p["variant"]),
		"pos": [_snap(centre.x, POS_STEP), _snap(centre.y, POS_STEP), _snap(centre.z, POS_STEP)],
		"radius": _snap(radius, POS_STEP),
		"base": [_snap(b.x, POS_STEP), _snap(b.y, POS_STEP), _snap(b.z, POS_STEP)],
		"rot_y": _snap(fposmod(float(p["rot_y"]), TAU), ROT_STEP),
		"up": [_snap(u.x, ROT_STEP), _snap(u.y, ROT_STEP), _snap(u.z, ROT_STEP)],
		"scale": _snap(float(p["scale"]), POS_STEP), "decor": decor, "host": host, "rule": rule,
	}


# "" when the site centre passes the filters, else the stats key of the first failed one.
static func _reject(seabed: SeabedField, centre: Vector3, up: Vector3, clearance: float, hanging: bool, near: PackedVector3Array) -> String:
	if not seabed.obstacle_clear(centre, clearance + CLEAR_MARGIN_M):
		return "obstacle"
	if not seabed.obstacle_clear(centre - up * HANG_CHECK_M if hanging else centre + up * ABOVE_CHECK_M, 0.0):
		return "reach"
	if seabed.height_at(centre.x, centre.z) >= centre.y:
		return "buried"
	for q: Vector3 in near:
		if q.distance_to(centre) < MIN_SPACING_M:
			return "spacing"
	return ""


# True inside the map's soft-current edge margin (map bounds.soft_margin_m, the SimWorld current zone).
static func _in_margin(p: Vector3, inner: float) -> bool:
	return absf(p.x) > inner or absf(p.z) > inner


static func _use(used: Dictionary, host: int, centre: Vector3) -> void:
	var a: PackedVector3Array = used.get(host, PackedVector3Array())
	a.append(centre)
	used[host] = a


# First entry of the type's pieces matching the host zone and the y window ("" = none).
static func _choose_piece(t: Dictionary, zone_id: String, y: float) -> String:
	for e: Variant in (t.get("pieces", []) as Array):
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		if ed.get("zones") is Array and not (ed["zones"] as Array).has(zone_id):
			continue
		if ed.has("above_y") and y < float(ed["above_y"]):
			continue
		if ed.has("below_y") and y >= float(ed["below_y"]):
			continue
		return str(ed.get("id", ""))
	return ""


# World centre of a placement's variant bounds (the base when the piece has no bounds).
static func _centre(p: Dictionary, index: Dictionary) -> Vector3:
	var b: Array = _bounds(index, str(p["piece"]), int(p["variant"]))
	if b.is_empty():
		return p["pos"]
	var lc := Vector3(float(b[0]) + float(b[3]) * 0.5, float(b[1]) + float(b[4]) * 0.5, float(b[2]) + float(b[5]) * 0.5)
	return MapDressing.placement_transform(p) * lc


static func _site_radius(t: Dictionary, p: Dictionary, index: Dictionary) -> float:
	var r: float = float(t.get("radius_m", 0.1))
	var b: Array = _bounds(index, str(p["piece"]), int(p["variant"]))
	if b.is_empty():
		return r
	return maxf(r, 0.5 * minf(float(b[3]), float(b[5])) * float(p["scale"]))


static func _top(index: Dictionary, pid: String, v: int) -> float:
	var b: Array = _bounds(index, pid, v)
	return float(b[1]) + float(b[4]) if not b.is_empty() else 0.0


static func _bounds(index: Dictionary, pid: String, v: int) -> Array:
	var all: Array = (index.get(pid, {}) as Dictionary).get("bounds", [])
	return all[v - 1] if v >= 1 and v <= all.size() else []


# Mesh top spots of a host variant (piece frame, highest first; ties by grid order): see the class doc (`top`).
static func _top_spots(cache: Dictionary, index: Dictionary, pid: String, v: int, inset: float, max_slope_deg: float) -> Array:
	var key: String = "spots|%s|%d|%.3f|%.1f" % [pid, v, inset, max_slope_deg]
	if cache.has(key):
		return cache[key]
	var spots: Array = []
	var b: Array = _bounds(index, pid, v)
	if not b.is_empty():
		var min_ny: float = cos(deg_to_rad(max_slope_deg))
		var cx: float = float(b[0]) + float(b[3]) * 0.5
		var cz: float = float(b[2]) + float(b[5]) * 0.5
		var top: float = float(b[1]) + float(b[4])
		var hits: Array = []
		for gx in SPOT_GRID:
			for gz in SPOT_GRID:
				var u: float = (float(gx) / float(SPOT_GRID - 1)) * 2.0 - 1.0
				var w: float = (float(gz) / float(SPOT_GRID - 1)) * 2.0 - 1.0
				var from := Vector3(cx + u * inset * float(b[3]) * 0.5, top + 1.0, cz + w * inset * float(b[5]) * 0.5)
				var hit: Dictionary = ray_piece(cache, pid, v, from, Vector3.DOWN)
				if hit.is_empty() or (hit["normal"] as Vector3).y < min_ny:
					continue
				hits.append([(hit["position"] as Vector3), gx * SPOT_GRID + gz])
		hits.sort_custom(func(a: Array, c: Array) -> bool: return (a[0] as Vector3).y > (c[0] as Vector3).y or ((a[0] as Vector3).y == (c[0] as Vector3).y and int(a[1]) < int(c[1])))
		for hh: Array in hits:
			spots.append(hh[0])
	cache[key] = spots
	return spots


static func _tri_mesh(cache: Dictionary, pid: String, v: int) -> TriangleMesh:
	var key: String = "mesh|%s|%d" % [pid, v]
	if cache.has(key):
		return cache[key]
	var tm: TriangleMesh = null
	var path: String = "%s/env_%s_v%d_lod0.glb" % [ContentDB.ENV_MODELS_DIR, pid, v]
	var scene: PackedScene = load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		var root: Node = scene.instantiate()
		var found: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
		if root is MeshInstance3D:
			found.push_front(root)
		if not found.is_empty():
			tm = (found[0] as MeshInstance3D).mesh.generate_triangle_mesh()
		root.free()
	cache[key] = tm
	return tm


static func _snap(f: float, step: float) -> float:
	var r: float = snappedf(f, step)
	return 0.0 if r == 0.0 else r
