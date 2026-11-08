class_name GreyboxTerrain
extends Node3D
## Grey-box presentation of a map (not final art). build() creates:
## - "Seabed": a flat-shaded mesh sampled from SeabedField.height_at() on a regular grid (grid_spacing_m),
##   tinted per grid cell by the map zone it lies in and darkened with depth;
## - "Obstacles": the SeabedField.obstacles() primitives (sphere / capsule / box / rounded oriented box), plus the
##   baked proxies passed to build(), merged into one flat-shaded mesh;
## - "Surface": a translucent ceiling plane at y = 0, seen from below;
## - "EdgeWalls": translucent walls on the hard map edge.
## Lighting is baked into vertex colours and drawn with an unshaded material, so the look is identical on
## Forward+ and Compatibility and does not depend on scene lights. Seabed and obstacles use TERRAIN_MATERIAL (S5:
## the baked vertex colours + world-space caustics). No collision bodies: collision is sim-side.
## Dressed maps (S5 reef.tscn) switch the grey-box parts off (build_obstacles, build_edge_walls), extend the seabed
## past the map edge into the fog (apron_m) and colour it by depth (depth_colors) with rock on steep facets
## (steep_color) and a small per-facet brightness jitter (facet_jitter) instead of the zone tints.

## Map built automatically one frame after _ready unless build() was called first (empty id = never).
@export var auto_build_map_id: StringName = &"reef"
## Seabed sample spacing in metres (the map size is split into a whole number of cells).
@export_range(1.0, 10.0) var grid_spacing_m: float = 3.0
## Build the translucent "Surface" plane (off when UnderwaterFx draws the water surface).
@export var build_surface: bool = true
## Build the obstacle primitives mesh (off when map dressing draws the real pieces; debug overlay otherwise).
@export var build_obstacles: bool = true
## Build the translucent walls on the hard map edge.
@export var build_edge_walls: bool = true
## Seabed mesh margin beyond the map footprint (presentation only: the seabed continues into the fog).
@export_range(0.0, 400.0) var apron_m: float = 0.0
## Seabed colour by depth (offset = depth / map depth_m, sRGB); null = zone tints (ZONE_COLORS).
@export var depth_colors: Gradient
## Colour blended in on steep facets (normal.y below steep_start, full at steep_full) when depth_colors is set.
@export var steep_color: Color = Color(0.36, 0.42, 0.5)
@export var steep_start: float = 0.85
@export var steep_full: float = 0.55
## Per-facet brightness jitter (+-, deterministic hash) when depth_colors is set: keeps the facets readable.
@export_range(0.0, 0.3) var facet_jitter: float = 0.0

const TERRAIN_MATERIAL: Material = preload("res://shaders/m_greybox_terrain.tres")

## Baked light: colour * (AMBIENT + DIFFUSE * max(0, n . SUN_DIR)), then darkened with depth.
const SUN_DIR: Vector3 = Vector3(0.35, 1.0, 0.25)
const AMBIENT: float = 0.45
const DIFFUSE: float = 0.55
## Colour multiplier at the map's deepest point is 1 - DEPTH_DARKEN (mood gets darker with depth).
const DEPTH_DARKEN: float = 0.5
## Grey-box tints (sRGB) per zone id; zones not listed fall back to DEFAULT_COLOR.
const ZONE_COLORS: Dictionary = {
	"shallows": Color(0.93, 0.83, 0.58),
	"kelp_forest": Color(0.40, 0.62, 0.32),
	"rock_arches": Color(0.58, 0.53, 0.50),
	"sunken_boat": Color(0.62, 0.48, 0.34),
	"cliff_edge": Color(0.48, 0.45, 0.55),
	"abyss": Color(0.22, 0.30, 0.55),
	"open_water": Color(0.55, 0.60, 0.62),
}
const DEFAULT_COLOR: Color = Color(0.6, 0.6, 0.6)
## Obstacle tints per obstacle tag.
const TAG_COLORS: Dictionary = {
	"arch": Color(0.50, 0.46, 0.44),
	"cave": Color(0.40, 0.37, 0.38),
	"boat": Color(0.55, 0.36, 0.22),
	"rock": Color(0.47, 0.45, 0.45),
	"coral": Color(0.95, 0.45, 0.55),
}
## Face subdivisions of a rounded obb overlay mesh (projected onto the rounded box).
const OBB_SUBDIVIDE: int = 3
const SURFACE_COLOR: Color = Color(0.55, 0.80, 0.95, 0.35)
const EDGE_COLOR: Color = Color(1.0, 0.55, 0.25, 0.18)

## Filled by build(): ms, grid (cells per side), seabed_triangles, obstacle_triangles.
var build_stats: Dictionary = {}

var _built: bool = false
var _parts: Array[Node3D] = []
# zone table for tinting: XZ rectangles, Y ranges, XZ areas, colours
var _z_min: PackedVector3Array = PackedVector3Array()
var _z_max: PackedVector3Array = PackedVector3Array()
var _z_area: PackedFloat64Array = PackedFloat64Array()
var _z_color: PackedColorArray = PackedColorArray()


## Appends flat-shaded triangles with baked light (packed arrays are values in GDScript, so they live here).
class _MeshBuf extends RefCounted:
	var verts: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var cols: PackedColorArray = PackedColorArray()
	var sun: Vector3 = SUN_DIR.normalized()

	## Godot treats clockwise triangles (seen from the front) as front faces; the face normal is (c-a) x (b-a).
	func tri(a: Vector3, b: Vector3, c: Vector3, base: Color) -> void:
		var n: Vector3 = (c - a).cross(b - a)
		n = n.normalized() if n.length_squared() > 1e-20 else Vector3.UP
		var s: float = AMBIENT + DIFFUSE * maxf(n.dot(sun), 0.0)
		var col := Color(base.r * s, base.g * s, base.b * s, base.a)
		verts.append(a)
		verts.append(b)
		verts.append(c)
		for i in 3:
			norms.append(n)
			cols.append(col)

	func commit(material: Material) -> ArrayMesh:
		var mesh := ArrayMesh.new()
		if verts.is_empty():
			return mesh
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_COLOR] = cols
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, material)
		return mesh


func _ready() -> void:
	if not auto_build_map_id.is_empty():
		_auto_build.call_deferred()


## Rebuilds every grey-box part from a map record (ContentDB.get_map()). Safe to call again. `baked`: extra obstacle
## records for the "Obstacles" part (ContentDB.get_proxies()).
func build(map: Dictionary, baked: Array = []) -> void:
	var t0: int = Time.get_ticks_usec()
	_built = true
	_clear()
	var size: float = float(map.get("size_m", 0.0))
	var depth: float = float(map.get("depth_m", 0.0))
	if size <= 0.0 or depth <= 0.0:
		push_warning("GreyboxTerrain: map '%s' has no size_m/depth_m, nothing built" % map.get("id", ""))
		return
	var field: SeabedField = SeabedField.from_map(map, baked)
	_load_zones(map)
	var vertex_mat: Material = TERRAIN_MATERIAL

	var extent: float = size + 2.0 * apron_m
	var cells: int = maxi(1, ceili(extent / grid_spacing_m))
	var seabed: _MeshBuf = _seabed_mesh(field, extent, depth, cells)
	var obstacles: _MeshBuf = _obstacle_mesh(field) if build_obstacles else _MeshBuf.new()
	_add_part("Seabed", seabed.commit(vertex_mat))
	if build_obstacles:
		_add_part("Obstacles", obstacles.commit(vertex_mat))
	if build_surface:
		_add_part("Surface", _surface_mesh(size))
	if build_edge_walls:
		_add_part("EdgeWalls", _edge_mesh(size, depth))

	build_stats = {
		"ms": float(Time.get_ticks_usec() - t0) / 1000.0,
		"grid": cells,
		"seabed_triangles": seabed.verts.size() / 3,
		"obstacle_triangles": obstacles.verts.size() / 3,
	}


func _auto_build() -> void:
	if _built:
		return
	var db: ContentDB = ContentDB.load_from_dir()
	var map: Dictionary = db.get_map(auto_build_map_id)
	if map.is_empty():
		push_warning("GreyboxTerrain: map '%s' not found" % auto_build_map_id)
		return
	build(map)


func _clear() -> void:
	for p in _parts:
		remove_child(p)
		p.queue_free()
	_parts.clear()


func _add_part(part_name: String, mesh: Mesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_parts.append(mi)


func _seabed_mesh(field: SeabedField, size: float, depth: float, cells: int) -> _MeshBuf:
	var cell: float = size / float(cells)
	var half: float = size * 0.5
	var row: int = cells + 1
	var hs := PackedFloat64Array()
	hs.resize(row * row)
	for j in row:
		var z: float = -half + float(j) * cell
		for i in row:
			hs[j * row + i] = field.height_at(-half + float(i) * cell, z)
	var buf := _MeshBuf.new()
	for j in cells:
		var z0: float = -half + float(j) * cell
		var z1: float = z0 + cell
		for i in cells:
			var x0: float = -half + float(i) * cell
			var x1: float = x0 + cell
			var k: int = j * row + i
			var v00 := Vector3(x0, hs[k], z0)
			var v10 := Vector3(x1, hs[k + 1], z0)
			var v01 := Vector3(x0, hs[k + row], z1)
			var v11 := Vector3(x1, hs[k + row + 1], z1)
			var y: float = (v00.y + v10.y + v01.y + v11.y) * 0.25
			var dark: float = 1.0 - DEPTH_DARKEN * clampf(-y / depth, 0.0, 1.0)
			if depth_colors == null:
				var base: Color = _zone_color(x0 + cell * 0.5, y, z0 + cell * 0.5)
				base = Color(base.r * dark, base.g * dark, base.b * dark)
				buf.tri(v00, v10, v01, base)
				buf.tri(v10, v11, v01, base)
			else:
				buf.tri(v00, v10, v01, _ramp_color(v00, v10, v01, depth, dark, k * 2))
				buf.tri(v10, v11, v01, _ramp_color(v10, v11, v01, depth, dark, k * 2 + 1))
	return buf


# Depth-ramp colour of one seabed triangle (depth_colors mode): ramp at the triangle's mean depth, rock on steep
# facets, brightness jitter per facet, depth darkening.
func _ramp_color(a: Vector3, b: Vector3, c: Vector3, depth: float, dark: float, salt: int) -> Color:
	var y: float = (a.y + b.y + c.y) / 3.0
	var col: Color = depth_colors.sample(clampf(-y / depth, 0.0, 1.0))
	var n: Vector3 = (c - a).cross(b - a).normalized()
	var steep: float = clampf((steep_start - absf(n.y)) / maxf(steep_start - steep_full, 1e-3), 0.0, 1.0)
	col = col.lerp(steep_color, steep)
	var h: int = (salt * 0x9E3779B1) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	var j: float = 1.0 + facet_jitter * (float(h & 0xFFFF) / 32767.5 - 1.0)
	var m: float = dark * j
	return Color(col.r * m, col.g * m, col.b * m)


func _obstacle_mesh(field: SeabedField) -> _MeshBuf:
	var buf := _MeshBuf.new()
	for o: Dictionary in field.obstacles():
		var col: Color = TAG_COLORS.get(o.get("tag", ""), DEFAULT_COLOR)
		var prim: PrimitiveMesh = null
		var xf := Transform3D.IDENTITY
		match o.get("kind", ""):
			"sphere":
				var s := SphereMesh.new()
				s.radius = float(o["radius"])
				s.height = s.radius * 2.0
				s.radial_segments = 10
				s.rings = 5
				prim = s
				xf.origin = o["center"]
			"capsule":
				var a: Vector3 = o["a"]
				var b: Vector3 = o["b"]
				var c := CapsuleMesh.new()
				c.radius = float(o["radius"])
				c.height = a.distance_to(b) + c.radius * 2.0
				c.radial_segments = 8
				c.rings = 2
				prim = c
				var axis: Vector3 = (b - a).normalized() if not a.is_equal_approx(b) else Vector3.UP
				if axis.y < 0.0:
					axis = -axis  # capsules are symmetric; avoids the antiparallel arc
				xf = Transform3D(Basis(Quaternion(Vector3.UP, axis)), (a + b) * 0.5)
			"box":
				var bx := BoxMesh.new()
				bx.size = o["size"]
				prim = bx
				xf.origin = o["center"]
			"obb":
				var ob := BoxMesh.new()
				ob.size = o["size"]
				var rnd: float = float(o["round"])
				if rnd > 0.0:
					ob.subdivide_width = OBB_SUBDIVIDE
					ob.subdivide_height = OBB_SUBDIVIDE
					ob.subdivide_depth = OBB_SUBDIVIDE
				prim = ob
				xf = Transform3D(Basis(o["rot"] as Quaternion), o["center"])
		if prim == null:
			continue
		var arrays: Array = prim.get_mesh_arrays()
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if o.get("kind", "") == "obb" and float(o["round"]) > 0.0:
			v = _rounded(v, (o["size"] as Vector3) * 0.5, float(o["round"]))
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size() - 2, 3):
			buf.tri(xf * v[idx[t]], xf * v[idx[t + 1]], xf * v[idx[t + 2]], col)
	return buf


# Box vertices projected onto the rounded box (inner half extents half - rnd, corner radius rnd).
static func _rounded(v: PackedVector3Array, half: Vector3, rnd: float) -> PackedVector3Array:
	var inner: Vector3 = half - Vector3.ONE * rnd
	var out := PackedVector3Array()
	out.resize(v.size())
	for i in v.size():
		var q: Vector3 = v[i].clamp(-inner, inner)
		var d: Vector3 = v[i] - q
		out[i] = q + d.normalized() * rnd if d.length_squared() > 1e-12 else v[i]
	return out


func _surface_mesh(size: float) -> Mesh:
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	var mat: StandardMaterial3D = _material(SURFACE_COLOR, false)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material = mat
	return plane


func _edge_mesh(size: float, depth: float) -> Mesh:
	var h: float = size * 0.5
	var corners: Array[Vector2] = [Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)]
	var verts := PackedVector3Array()
	for i in 4:
		var p: Vector2 = corners[i]
		var q: Vector2 = corners[(i + 1) % 4]
		var a := Vector3(p.x, 0.0, p.y)
		var b := Vector3(q.x, 0.0, q.y)
		var c := Vector3(q.x, -depth, q.y)
		var d := Vector3(p.x, -depth, p.y)
		verts.append_array(PackedVector3Array([a, b, c, a, c, d]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat: StandardMaterial3D = _material(EDGE_COLOR, false)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


static func _material(albedo: Color, use_vertex_color: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = albedo
	if use_vertex_color:
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
	if albedo.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _load_zones(map: Dictionary) -> void:
	_z_min.clear()
	_z_max.clear()
	_z_area.clear()
	_z_color.clear()
	var zones: Array = map.get("zones", []) if map.get("zones") is Array else []
	for z: Variant in zones:
		if not (z is Dictionary and (z as Dictionary).get("aabb") is Dictionary):
			continue
		var aabb: Dictionary = z["aabb"]
		var lo: Vector3 = _vec3(aabb.get("min"))
		var hi: Vector3 = _vec3(aabb.get("max"))
		_z_min.append(lo)
		_z_max.append(hi)
		_z_area.append((hi.x - lo.x) * (hi.z - lo.z))
		_z_color.append(ZONE_COLORS.get(str(z.get("id", "")), DEFAULT_COLOR))


static func _vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


# Zone tint at a seabed point: among zones whose XZ rectangle contains it, the one whose Y range is closest
# to y; ties go to the smaller (more specific) rectangle, so the boat site beats the arches and open water.
func _zone_color(x: float, y: float, z: float) -> Color:
	var best: int = -1
	var best_dy: float = INF
	var best_area: float = INF
	for i in _z_min.size():
		var lo: Vector3 = _z_min[i]
		var hi: Vector3 = _z_max[i]
		if x < lo.x or x > hi.x or z < lo.z or z > hi.z:
			continue
		var dy: float = maxf(maxf(lo.y - y, y - hi.y), 0.0)
		if dy < best_dy or (dy == best_dy and _z_area[i] < best_area):
			best = i
			best_dy = dy
			best_area = _z_area[i]
	return _z_color[best] if best >= 0 else DEFAULT_COLOR
