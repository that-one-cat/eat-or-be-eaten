extends RefCounted
## Shared helpers for the test_s5_*.gd files (res://tests/s5_support.gd). Not a test file: the runner only collects
## scripts whose name starts with "test_". Use via `const S5 := preload("res://tests/s5_support.gd")`.
## No class_name (no global class cache dependency).
##
## Contract (tasks/archive/2026-11/mvp/research/stage-S5-world-look-1104/s5-contract.md, "Map dressing") plus the assumptions of the test
## plan (stage-S5-world-look-1104_test_plan.md, "Assumptions needing a decision"):
## - data: res://data/maps/reef_dressing.json, read through `ContentDB.get_dressing(map_id)` (fallback: the JSON file);
## - builder: res://scripts/world/map_dressing.gd, `class_name MapDressing`, with a NODE-FREE static
##   `compute_placements(dressing: Dictionary, map: Dictionary, seabed: SeabedField, piece_index: Dictionary) -> Array`;
## - one placement = Dictionary {kind: "scatter"|"set_piece", piece: String, variant: int (1-based, = GLB v<n>),
##   pos: Vector3 (base of the piece), rot_y: float (radians), scale: float, zone_id: String and rule: int (index into
##   dressing.scatter) for scatter, id: String (set piece id) for set pieces};
## - GLB of a piece variant: res://assets/models/env/env_<piece>_v<variant>_lod0.glb.
## MapDressing is NEVER referenced statically here: a missing or renamed member fails one test with a readable
## "S5 API missing" message instead of a parse error that takes a whole file down.

const S3 := preload("res://tests/s3_support.gd")

const MAP_ID: StringName = &"reef"
const DRESSING_PATH: String = "res://data/maps/reef_dressing.json"
const DRESSING_SOURCE: String = "maps/reef_dressing.json"
const BUILDER_SCRIPT: String = "res://scripts/world/map_dressing.gd"
const ENV_DIR: String = "res://assets/models/env"
const REEF_SCENE: String = "res://scenes/maps/reef.tscn"
const GREYBOX_SCENE: String = "res://scenes/maps/reef_greybox.tscn"
const MAIN_SCENE: String = "res://scenes/main.tscn"

## Footprint of the map (half of size_m) and the hard rule 6 limit.
const FOOTPRINT_HALF_M: float = 300.0
const WORLD_LIMIT_M: float = 4000.0
## Tolerance on the footprint for the world AABB of a set piece (cliff tiles overlap the edge by 0.2 m).
const FOOTPRINT_AABB_SLACK_M: float = 1.0
## Scatter sits on the seabed: base y in [h - SINK, h + ABOVE]. Set pieces may be embedded deeper (big rocks on slopes).
const SCATTER_SINK_M: float = 1.0
const SCATTER_ABOVE_M: float = 0.3
const SET_SINK_M: float = 3.0
## depth_m rules are checked against the seabed depth at the placement (-height_at), this tolerance covers the sink.
const DEPTH_TOL_M: float = 0.5
const SCALE_TOL: float = 1e-4
const SPACING_TOL_M: float = 1e-3
## Sane limits for data (not for the generator): a scatter scale above this is a typo.
const MAX_SCATTER_SCALE: float = 6.0
const MAX_SET_SCALE: float = 6.0
## Runaway guard (density typo): total scatter instances of the map.
const MAX_SCATTER_TOTAL: int = 60000
## Hiding volumes need real cover: matching-family placements per volume (tunable, see plan A9).
const KELP_MIN_PER_VOLUME: int = 12
const CORAL_MIN_PER_VOLUME: int = 6
const HIDING_Y_TOL_M: float = 4.0

static var _memo: Dictionary = {}


# ---------------------------------------------------------------- data access

static func content() -> ContentDB:
	return S3.content()


static func map_record() -> Dictionary:
	return content().get_map(MAP_ID)


## The dressing record as ContentDB serves it; falls back to the JSON file when the accessor does not exist yet.
## Returns a LIVE dictionary: callers that edit it must duplicate(true) first.
static func dressing(db: ContentDB = null) -> Dictionary:
	var source: ContentDB = db if db != null else content()
	if source.has_method("get_dressing"):
		var v: Variant = source.call("get_dressing", MAP_ID)
		if v is Dictionary:
			return v as Dictionary
	return read_json(DRESSING_PATH)


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


# ---------------------------------------------------------------- piece kit (GLBs on disk + generator specs)

## Piece id -> number of variant GLBs on disk (variants are v1..vN).
static func glb_variants() -> Dictionary:
	if _memo.has("glb_variants"):
		return _memo["glb_variants"]
	var out: Dictionary = {}
	var rx := RegEx.new()
	rx.compile("^env_(.+)_v(\\d+)_lod0\\.glb$")
	var d: DirAccess = DirAccess.open(ENV_DIR)
	if d != null:
		for f: String in d.get_files():
			var m: RegExMatch = rx.search(f)
			if m == null:
				continue
			var pid: String = m.get_string(1)
			out[pid] = maxi(int(out.get(pid, 0)), int(m.get_string(2)))
	_memo["glb_variants"] = out
	return out


## Generator specs (tools/blender/env/pieces/*.json) by piece id. Empty when the tools directory is not readable
## (then spec-based tests degrade to the GLB-only checks and `specs_available()` fails once, loudly).
static func specs() -> Dictionary:
	if _memo.has("specs"):
		return _memo["specs"]
	var out: Dictionary = {}
	var dir_path: String = repo_root().path_join("tools/blender/env/pieces")
	var d: DirAccess = DirAccess.open(dir_path)
	if d != null:
		for f: String in d.get_files():
			if f.get_extension() != "json":
				continue
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir_path.path_join(f)))
			if parsed is Dictionary and (parsed as Dictionary).get("id") is String:
				out[(parsed as Dictionary)["id"]] = parsed
	_memo["specs"] = out
	return out


static func specs_available() -> bool:
	return not specs().is_empty()


## The test side's own piece index: id -> {id, variants (GLBs on disk), size_class, biome, glow, sway, footprint_m}
## (the spec keys only when the generator spec is readable).
static func test_index() -> Dictionary:
	if _memo.has("test_index"):
		return _memo["test_index"]
	var out: Dictionary = {}
	var variants: Dictionary = glb_variants()
	var sp: Dictionary = specs()
	for pid: String in variants.keys():
		var entry: Dictionary = {"id": pid, "variants": int(variants[pid])}
		if sp.has(pid):
			var spec: Dictionary = sp[pid]
			for key: String in ["size_class", "biome", "glow", "sway", "footprint_m", "double_sided"]:
				if spec.has(key):
					entry[key] = spec[key]
		out[pid] = entry
	_memo["test_index"] = out
	return out


static func piece_known(piece_id: String) -> bool:
	return glb_variants().has(piece_id)


static func size_class(piece_id: String) -> String:
	return String((specs().get(piece_id, {}) as Dictionary).get("size_class", ""))


static func is_glow(piece_id: String) -> bool:
	if specs().has(piece_id):
		return bool((specs()[piece_id] as Dictionary).get("glow", false))
	return piece_id.contains("glow")


## "kelp" | "coral" | "" (hiding-volume tag family, matched on the piece id).
static func family(piece_id: String) -> String:
	if piece_id.contains("kelp"):
		return "kelp"
	if piece_id.contains("coral"):
		return "coral"
	return ""


static func glb_path(piece_id: String, variant: int) -> String:
	return "%s/env_%s_v%d_lod0.glb" % [ENV_DIR, piece_id, variant]


## `variants` of a scatter piece entry: an int N (-> 1..N) or an explicit array of ints.
static func variant_list(entry: Variant) -> Array[int]:
	var out: Array[int] = []
	if entry is int or entry is float:
		for i in range(1, int(entry) + 1):
			out.append(i)
	elif entry is Array:
		for v: Variant in (entry as Array):
			out.append(int(v))
	return out


# ---------------------------------------------------------------- GLB geometry (instantiated outside the tree)

## Local AABB (metres, origin = base centre) of a piece variant; AABB() when the GLB does not load.
static func local_aabb(piece_id: String, variant: int) -> AABB:
	var key: String = "aabb:%s:%d" % [piece_id, variant]
	if _memo.has(key):
		return _memo[key]
	var result: AABB = AABB()
	var scene: PackedScene = load(glb_path(piece_id, variant)) as PackedScene
	if scene != null:
		var root: Node = scene.instantiate()
		var acc: Array = []
		_collect_aabb(root, Transform3D.IDENTITY, acc)
		if not acc.is_empty():
			result = acc[0]
		root.free()
	_memo[key] = result
	return result


static func _collect_aabb(node: Node, parent_xf: Transform3D, acc: Array) -> void:
	var xf: Transform3D = parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var box: AABB = xf * (node as MeshInstance3D).mesh.get_aabb()
		if acc.is_empty():
			acc.append(box)
		else:
			acc[0] = (acc[0] as AABB).merge(box)
	for child: Node in node.get_children():
		_collect_aabb(child, xf, acc)


## World AABB of a placed piece (rotation about Y, uniform scale, translation).
static func world_aabb(p: Dictionary) -> AABB:
	var local: AABB = local_aabb(piece_of(p), variant_of(p))
	if local.size == Vector3.ZERO:
		return AABB(pos_of(p), Vector3.ZERO)
	var xf := Transform3D(Basis(Vector3.UP, rot_of(p)).scaled(Vector3.ONE * scale_of(p)), pos_of(p))
	var out: AABB = xf * local
	return out


# ---------------------------------------------------------------- placements

static func has_builder() -> bool:
	return ResourceLoader.exists(BUILDER_SCRIPT) and builder_script() != null


static func builder_script() -> GDScript:
	if not ResourceLoader.exists(BUILDER_SCRIPT):
		return null
	return load(BUILDER_SCRIPT) as GDScript


static func script_has_method(script: GDScript, method_name: String) -> bool:
	for m: Dictionary in script.get_script_method_list():
		if str(m["name"]) == method_name:
			return true
	return false


## Fails the calling test with a readable message and returns false when the builder API is not there yet.
static func require_api(tc: TestCase) -> bool:
	var script: GDScript = builder_script()
	if script == null:
		tc.fail("S5 API missing: %s (MapDressing script) does not exist or does not parse" % BUILDER_SCRIPT)
		return false
	if not script_has_method(script, "compute_placements"):
		tc.fail("S5 API missing: MapDressing.compute_placements (static, node-free) not found in %s" % BUILDER_SCRIPT)
		return false
	if dressing().is_empty():
		tc.fail("S5 data missing: %s (empty or unreadable)" % DRESSING_PATH)
		return false
	return true


## The piece index handed to compute_placements: MapDressing.piece_index() when the builder offers one, else test_index().
static func compute_index() -> Dictionary:
	var script: GDScript = builder_script()
	if script != null and script_has_method(script, "piece_index"):
		var v: Variant = script.call("piece_index")
		if v is Dictionary:
			return v as Dictionary
	return test_index()


static func seabed_for(map: Dictionary) -> SeabedField:
	return SeabedField.from_map(map)


## One call of the pure placement function. Inputs are used as given (callers pass deep copies when they care).
static func compute(d: Dictionary, map: Dictionary, seabed: SeabedField, index: Dictionary) -> Array:
	var script: GDScript = builder_script()
	if script == null:
		return []
	var v: Variant = script.call("compute_placements", d, map, seabed, index)
	if v is Array:
		return v as Array
	return []


## Fresh run on deep copies of the shipped data (a new SeabedField every call).
static func compute_fresh(d_override: Dictionary = {}) -> Array:
	var map: Dictionary = map_record().duplicate(true)
	var d: Dictionary = (d_override if not d_override.is_empty() else dressing()).duplicate(true)
	return compute(d, map, seabed_for(map), compute_index())


## Memoised placements of the shipped data (results only; never mutate).
static func placements() -> Array:
	if not _memo.has("placements"):
		_memo["placements"] = compute_fresh()
	return _memo["placements"]


static func scatter_only(list: Array) -> Array:
	var out: Array = []
	for p: Variant in list:
		if p is Dictionary and str((p as Dictionary).get("kind", "")) == "scatter":
			out.append(p)
	return out


static func set_pieces_only(list: Array) -> Array:
	var out: Array = []
	for p: Variant in list:
		if p is Dictionary and str((p as Dictionary).get("kind", "")) == "set_piece":
			out.append(p)
	return out


static func piece_of(p: Dictionary) -> String:
	return str(p.get("piece", ""))


static func variant_of(p: Dictionary) -> int:
	return int(p.get("variant", 0))


static func pos_of(p: Dictionary) -> Vector3:
	var v: Variant = p.get("pos")
	if v is Vector3:
		return v as Vector3
	return Vector3(INF, INF, INF)


static func rot_of(p: Dictionary) -> float:
	return float(p.get("rot_y", 0.0))


## Uniform scale: a float, or a Vector3 (x is used; uniformity is asserted by the placement schema test).
static func scale_of(p: Dictionary) -> float:
	var v: Variant = p.get("scale", 1.0)
	if v is Vector3:
		return (v as Vector3).x
	return float(v)


static func seabed_depth(seabed: SeabedField, pos: Vector3) -> float:
	return -seabed.height_at(pos.x, pos.z)


# ---------------------------------------------------------------- map geometry

static func zone_aabb(map: Dictionary, zone_id: String) -> AABB:
	for z: Variant in map.get("zones", []):
		var zd: Dictionary = z
		if str(zd.get("id", "")) == zone_id:
			return aabb_of(zd.get("aabb", {}))
	return AABB()


static func has_zone(map: Dictionary, zone_id: String) -> bool:
	for z: Variant in map.get("zones", []):
		if str((z as Dictionary).get("id", "")) == zone_id:
			return true
	return false


static func aabb_of(box: Variant) -> AABB:
	var bd: Dictionary = box
	var lo: Array = bd["min"]
	var hi: Array = bd["max"]
	var a := Vector3(float(lo[0]), float(lo[1]), float(lo[2]))
	var b := Vector3(float(hi[0]), float(hi[1]), float(hi[2]))
	return AABB(a, b - a)


static func in_xz(box: AABB, p: Vector3, margin: float = 0.0) -> bool:
	return p.x >= box.position.x - margin and p.x <= box.end.x + margin and p.z >= box.position.z - margin and p.z <= box.end.z + margin


static func obstacle_by_id(map: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for o: Variant in map.get("obstacles", []):
		out[str((o as Dictionary)["id"])] = o
	return out


static func _vec(v: Variant) -> Vector3:
	var a: Array = v
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Signed distance from `p` to the obstacle primitive (negative inside).
static func obstacle_sdf(o: Dictionary, p: Vector3) -> float:
	match str(o.get("kind", "")):
		"sphere":
			return p.distance_to(_vec(o["center"])) - float(o["radius"])
		"capsule":
			var a: Vector3 = _vec(o["a"])
			var b: Vector3 = _vec(o["b"])
			var ab: Vector3 = b - a
			var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			return p.distance_to(a + ab * t) - float(o["radius"])
		"box":
			var q: Vector3 = (p - _vec(o["center"])).abs() - _vec(o["size"]) * 0.5
			return Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
		"obb":
			var rnd: float = float(o.get("round", 0.0))
			var l: Vector3 = quat_of(o).inverse() * (p - _vec(o["center"]))
			var qo: Vector3 = l.abs() - (_vec(o["size"]) * 0.5 - Vector3.ONE * rnd)
			return qo.max(Vector3.ZERO).length() + minf(maxf(qo.x, maxf(qo.y, qo.z)), 0.0) - rnd
	return INF


## `rot` of an obb record ([x, y, z, w], normalized; identity when missing).
static func quat_of(o: Dictionary) -> Quaternion:
	var r: Variant = o.get("rot")
	if r is Array and (r as Array).size() == 4:
		return Quaternion(float(r[0]), float(r[1]), float(r[2]), float(r[3])).normalized()
	return Quaternion.IDENTITY


static func obstacle_bounds(o: Dictionary) -> AABB:
	match str(o.get("kind", "")):
		"sphere":
			var c: Vector3 = _vec(o["center"])
			var r: float = float(o["radius"])
			return AABB(c - Vector3.ONE * r, Vector3.ONE * r * 2.0)
		"capsule":
			var a: Vector3 = _vec(o["a"])
			var b: Vector3 = _vec(o["b"])
			var rc: float = float(o["radius"])
			var lo: Vector3 = Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)) - Vector3.ONE * rc
			var hi: Vector3 = Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)) + Vector3.ONE * rc
			return AABB(lo, hi - lo)
		"box":
			var cb: Vector3 = _vec(o["center"])
			var sz: Vector3 = _vec(o["size"])
			return AABB(cb - sz * 0.5, sz)
		"obb":
			var co: Vector3 = _vec(o["center"])
			var h: Vector3 = _vec(o["size"]) * 0.5
			var b := Basis(quat_of(o))
			var ext := Vector3(
				absf(b.x.x) * h.x + absf(b.y.x) * h.y + absf(b.z.x) * h.z,
				absf(b.x.y) * h.x + absf(b.y.y) * h.y + absf(b.z.y) * h.z,
				absf(b.x.z) * h.x + absf(b.y.z) * h.y + absf(b.z.z) * h.z)
			return AABB(co - ext, ext * 2.0)
	return AABB()


## Union of the bounds of the obstacles `ids` (AABB() when none resolves).
static func union_bounds(ids: Array, by_id: Dictionary) -> AABB:
	var have: bool = false
	var out: AABB = AABB()
	for id: Variant in ids:
		if not by_id.has(str(id)):
			continue
		var b: AABB = obstacle_bounds(by_id[str(id)])
		out = b if not have else out.merge(b)
		have = true
	return out


## Placements of family `fam` whose base lies inside the volume (xz inside, y within the volume +- tolerance).
static func family_count_in(list: Array, volume: AABB, fam: String) -> int:
	var n: int = 0
	for p: Variant in list:
		var pd: Dictionary = p
		if family(piece_of(pd)) != fam:
			continue
		var pos: Vector3 = pos_of(pd)
		if in_xz(volume, pos) and pos.y >= volume.position.y - HIDING_Y_TOL_M and pos.y <= volume.end.y:
			n += 1
	return n


## Number of pairs closer than `min_d` in XZ, and the first offending pair as text ("" when none). Hash grid, O(n).
static func spacing_violations(points: PackedVector2Array, min_d: float) -> Array:
	var cell: float = maxf(min_d, 1e-3)
	var grid: Dictionary = {}
	var count: int = 0
	var first: String = ""
	for i in points.size():
		var c := Vector2i(int(floor(points[i].x / cell)), int(floor(points[i].y / cell)))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := Vector2i(c.x + dx, c.y + dz)
				if not grid.has(key):
					continue
				for j: int in grid[key]:
					if points[i].distance_to(points[j]) < min_d - SPACING_TOL_M:
						count += 1
						if first.is_empty():
							first = "#%d %s and #%d %s are %.3f m apart" % [j, points[j], i, points[i], points[i].distance_to(points[j])]
		if not grid.has(c):
			grid[c] = []
		(grid[c] as Array).append(i)
	return [count, first]


# ---------------------------------------------------------------- error-list helpers

static func mentions(errs: PackedStringArray, a: String, b: String = "") -> bool:
	for e: String in errs:
		if e.find(a) != -1 and (b.is_empty() or e.find(b) != -1):
			return true
	return false


# ---------------------------------------------------------------- throw-away copies of res://data

static func copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		if not sub.begins_with("."):
			copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "json":
			var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
			out.store_string(FileAccess.get_file_as_string(src.path_join(f)))
			out.close()


static func remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


## Loads a copy of res://data (under `scratch`) in which the JSON file `rel` (e.g. "maps/reef_dressing.json") was
## edited by `edit(parsed: Dictionary)`, and returns ContentDB's error list ("setup: ..." entries when the copy
## cannot be prepared). The copy is deleted afterwards.
static func load_with_edit(scratch: String, rel: String, edit: Callable) -> PackedStringArray:
	remove_dir(scratch)
	copy_dir("res://data", scratch)
	var path: String = scratch.path_join(rel)
	if not FileAccess.file_exists(path):
		remove_dir(scratch)
		return PackedStringArray(["setup: %s does not exist in the data copy" % rel])
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		remove_dir(scratch)
		return PackedStringArray(["setup: could not read the copied %s" % rel])
	edit.call(parsed)
	var out: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed, "\t"))
	out.close()
	var db: ContentDB = ContentDB.load_from_dir(scratch)
	var errs: PackedStringArray = db.errors
	remove_dir(scratch)
	return errs
