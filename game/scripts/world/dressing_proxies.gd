class_name DressingProxies
extends RefCounted
## Baked collision proxies of solid dressing pieces (fix-rock-collision). One rounded oriented box (`obb` obstacle
## record) per placement of a piece listed in the dressing `solid_pieces` (scatter, and set pieces without
## `obstacle_ids` / `collision`), derived from the piece variant bounds (env/pieces.json `bounds`) and the placement
## transform (rot_y, tilt, slope alignment, uniform scale): plan box = bounds x fit about the bounds centre, height from
## the base to the top x fit, the bottom buried by the corner radius (round x the smallest half extent).
## Pure and deterministic: derive() is a function of (dressing, authored map, piece index) only; the placements are
## computed against the map's own obstacles (SeabedField.from_map(map) without baked records), exactly what
## MapDressing does at runtime because it skips baked obstacles as blockers.
## Used by tools/dressing/bake_proxies.gd (writes maps/<map_id>_proxies.json, the sim loads it as plain obstacles via
## ContentDB.get_proxies), tools/dressing/reef_layout.gd (index, a20 clump proxies) and tests; the sim never calls it.

const DEFAULT_TAG: String = "rock"
## Rounding of the baked numbers (metres, quaternion components).
const POS_STEP: float = 0.001
const ROT_STEP: float = 0.0001
const INDEX_PATH: String = "res://data/env/pieces.json"
## Generator specs of the env pieces (dev checkout only: outside res://, absent in exports).
const SPEC_DIR: String = "res://../tools/blender/env/pieces"
const GENERATED_BY: String = "tools/dressing/bake_proxies.gd -- --write (DressingProxies.derive from the dressing solid_pieces; do not edit)"


## Baked proxy records (JSON-ready: arrays and floats, rounded) for every solid placement, in placement order (set
## pieces first, then the scatter rules). Ids: scatter `s<rule:02d>_<n:04d>` (n-th solid placement of the rule),
## set pieces `p_<set piece id>`. Pieces without bounds in `index` are skipped (the freshness test requires bounds).
static func derive(dressing: Dictionary, map: Dictionary, index: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var solid: Dictionary = dressing.get("solid_pieces", {}) if dressing.get("solid_pieces") is Dictionary else {}
	if solid.is_empty():
		return out
	var sets: Dictionary = {}
	for sp: Variant in dressing.get("set_pieces", []):
		if sp is Dictionary:
			sets[str((sp as Dictionary).get("id", ""))] = sp
	var list: Array = MapDressing.compute_placements(dressing, map, SeabedField.from_map(map), index)
	var ordinal: Dictionary = {}
	for p: Dictionary in list:
		var pid: String = p["piece"]
		if not solid.has(pid) or not (solid[pid] is Dictionary):
			continue
		var id: String = ""
		if p["kind"] == "set_piece":
			var sp: Dictionary = sets.get(str(p["id"]), {})
			if sp.has("collision") or not (sp.get("obstacle_ids", []) as Array).is_empty():
				continue  # authored proxies (reef.json) or the seabed cliff already collide
			id = "p_%s" % p["id"]
		else:
			var rule: int = int(p["rule"])
			var n: int = int(ordinal.get(rule, 0))
			ordinal[rule] = n + 1
			id = "s%02d_%04d" % [rule, n]
		var bounds: Array = (index.get(pid, {}) as Dictionary).get("bounds", [])
		var v: int = int(p["variant"])
		if v < 1 or v > bounds.size():
			continue
		var recipe: Dictionary = solid[pid]
		var basis: Basis = MapDressing.placement_transform(p).basis.orthonormalized()
		var box: Dictionary = obb(p["pos"], basis, float(p["scale"]), bounds[v - 1], float(recipe.get("fit", 1.0)), float(recipe.get("round", 0.0)))
		out.append(record(id, str(recipe.get("tag", DEFAULT_TAG)), box))
	return out


## Rounded oriented box of one placed piece variant: `base` (placement pos), `basis` (orthonormal rotation), uniform
## `scale`, variant `bounds` [min x, min y, min z, size x, size y, size z] (unit scale, origin = base centre), recipe
## `fit` (bounds multiplier) and `round_frac` (corner radius as a fraction of the smallest half extent).
## Returns {center: Vector3, size: Vector3, rot: Quaternion, round: float} (unrounded).
static func obb(base: Vector3, basis: Basis, scale: float, bounds: Array, fit: float, round_frac: float) -> Dictionary:
	var m := Vector3(float(bounds[0]), float(bounds[1]), float(bounds[2]))
	var s := Vector3(float(bounds[3]), float(bounds[4]), float(bounds[5]))
	var top: float = (m.y + s.y) * fit
	var hx: float = s.x * 0.5 * fit
	var hz: float = s.z * 0.5 * fit
	var r: float = round_frac * minf(hx, minf(hz, top))
	var size_l := Vector3(2.0 * hx, top + r, 2.0 * hz)
	var centre_l := Vector3(m.x + s.x * 0.5, (top - r) * 0.5, m.z + s.z * 0.5)
	var q: Quaternion = basis.get_rotation_quaternion()
	if q.w < 0.0:
		q = -q  # one canonical sign per rotation
	return {"center": base + basis * (centre_l * scale), "size": size_l * scale, "rot": q, "round": r * scale}


## JSON-ready obstacle record of an obb() result (rounded to POS_STEP / ROT_STEP; round kept <= min(size) / 2).
static func record(id: String, tag: String, box: Dictionary) -> Dictionary:
	var c: Vector3 = box["center"]
	var s: Vector3 = box["size"]
	var q: Quaternion = box["rot"]
	var size: Array = [_snap(s.x, POS_STEP), _snap(s.y, POS_STEP), _snap(s.z, POS_STEP)]
	var limit: float = minf(float(size[0]), minf(float(size[1]), float(size[2]))) * 0.5
	return {
		"id": id, "tag": tag, "kind": "obb",
		"center": [_snap(c.x, POS_STEP), _snap(c.y, POS_STEP), _snap(c.z, POS_STEP)],
		"size": size,
		"rot": [_snap(q.x, ROT_STEP), _snap(q.y, ROT_STEP), _snap(q.z, ROT_STEP), _snap(q.w, ROT_STEP)],
		"round": minf(_snap(float(box["round"]), POS_STEP), floorf(limit / POS_STEP) * POS_STEP),
	}


## Text of maps/<map_id>_proxies.json (one record per line, stable order and number format).
static func proxies_text(records: Array[Dictionary], map_id: String, dressing_seed: int) -> String:
	var lines: PackedStringArray = []
	for r: Dictionary in records:
		lines.append('\t\t{ "id": "%s", "tag": "%s", "kind": "obb", "center": %s, "size": %s, "rot": %s, "round": %s }' % [
			r["id"], r["tag"], _list(r["center"], 3), _list(r["size"], 3), _list(r["rot"], 4), num_text(float(r["round"]), 3)])
	return '{\n\t"generated_by": "%s",\n\t"map": "%s",\n\t"dressing_seed": %d,\n\t"obstacles": [\n%s\n\t]\n}\n' % [
		GENERATED_BY, map_id, dressing_seed, ",\n".join(lines)]


## Text of env/pieces.json: per piece the generator spec flags (SPEC_DIR), footprint_m (componentwise max of the mesh
## AABB sizes over all variants; MapDressing scatter spacing depends on it, keep it unchanged) and bounds (per variant
## the merged local AABB of its MeshInstance3D nodes: [min x, min y, min z, size x, size y, size z]), 0.01 m.
static func build_index() -> String:
	var specs: Dictionary = {}
	var dir: String = ProjectSettings.globalize_path(SPEC_DIR)
	var d := DirAccess.open(dir)
	var files: PackedStringArray = d.get_files() if d != null else PackedStringArray()
	for f in files:
		if f.get_extension() == "json":
			var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f)))
			if spec is Dictionary:
				specs[str(spec["id"])] = spec
	var variants: Dictionary = ContentDB.env_piece_variants()
	var ids: Array = variants.keys()
	ids.sort()
	var lines: PackedStringArray = []
	for pid: String in ids:
		var spec: Dictionary = specs.get(pid, {})
		var size := Vector3.ZERO
		var bounds: PackedStringArray = []
		for v in range(1, int(variants[pid]) + 1):
			var scene: PackedScene = load("%s/env_%s_v%d_lod0.glb" % [ContentDB.ENV_MODELS_DIR, pid, v])
			var root: Node = scene.instantiate()
			var box := AABB()
			var first: bool = true
			for mi: Node in root.find_children("*", "MeshInstance3D", true, false):
				var mesh_box: AABB = (mi as MeshInstance3D).mesh.get_aabb()
				size = size.max(mesh_box.size)
				var b: AABB = _node_xf(mi as Node3D, root) * mesh_box
				box = b if first else box.merge(b)
				first = false
			root.free()
			bounds.append("[%s, %s, %s, %s, %s, %s]" % [num_text(box.position.x), num_text(box.position.y), num_text(box.position.z),
				num_text(box.size.x), num_text(box.size.y), num_text(box.size.z)])
		var tags: PackedStringArray = [str(spec.get("biome", ""))]
		for flag: String in ["glow", "sway", "double_sided"]:
			if bool(spec.get(flag, false)):
				tags.append(flag)
		for fam: String in ["kelp", "coral"]:
			if pid.contains(fam):
				tags.append(fam)
		var tag_list: PackedStringArray = []
		for t in tags:
			tag_list.append('"%s"' % t)
		lines.append('\t\t"%s": { "variants": %d, "size_class": "%s", "biome": "%s", "glow": %s, "sway": %s, "double_sided": %s, "footprint_m": [%s, %s, %s], "tags": [%s], "bounds": [%s] }' % [
			pid, int(variants[pid]), str(spec.get("size_class", "env_small")), str(spec.get("biome", "")),
			str(bool(spec.get("glow", false))).to_lower(), str(bool(spec.get("sway", false))).to_lower(),
			str(bool(spec.get("double_sided", false))).to_lower(), num_text(size.x), num_text(size.y), num_text(size.z),
			", ".join(tag_list), ", ".join(bounds)])
	return '{\n\t"generated_by": "tools/dressing/reef_layout.gd --index (generator specs + imported GLB bounds; do not edit)",\n\t"pieces": {\n%s\n\t}\n}\n' % ",\n".join(lines)


## Number as written in the generated JSON files: snapped to 10^-digits, integers without a decimal point, no "-0".
static func num_text(f: float, digits: int = 2) -> String:
	var r: float = snappedf(f, pow(10.0, -digits))
	if r == 0.0:
		r = 0.0
	if r == floorf(r):
		return str(int(r))
	return String.num(r, digits + 1)


static func _list(a: Array, digits: int) -> String:
	var parts: PackedStringArray = []
	for v: Variant in a:
		parts.append(num_text(float(v), digits))
	return "[%s]" % ", ".join(parts)


static func _snap(f: float, step: float) -> float:
	var r: float = snappedf(f, step)
	return 0.0 if r == 0.0 else r


static func _node_xf(n: Node3D, root: Node) -> Transform3D:
	var xf: Transform3D = n.transform
	var cur: Node = n.get_parent()
	while cur != null and cur != root.get_parent():
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf
