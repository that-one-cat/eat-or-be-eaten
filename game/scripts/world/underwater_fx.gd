class_name UnderwaterFx
extends Node3D
## Camera-bound underwater look (S5 look stack, CLAUDE.md rule 11). setup(camera, tier, depth_env) builds:
## - "Surface": the water surface seen from below (water_surface.gdshader), a subdivided plane at y = 0 that follows
##   the camera on a SURFACE_SNAP_M grid (no swimming of the wave pattern);
## - "LightShafts": additive cones (water_light_shaft.gdshader) in one MultiMesh, on a world grid of SHAFT_CELL_M
##   cells around the camera (each cell hashes whether it has a shaft, its offset, width and brightness, so shafts
##   stay put in the world); rebuilt when the camera enters another cell; faded out with camera depth
##   (SHAFT_FADE_DEPTH_M);
## - "MarineSnow": flakes wrapped in a box around the camera (water_snow.gdshader), dimmed with depth;
## - "Refraction": full-screen refraction wobble quad (water_refraction.gdshader, high tier only).
## Counts and switches come from QualitySettings.profile(tier). Every material is created here from its shader (no
## shared .tres is mutated). Presentation only: reads the camera and DepthEnvironment, never the sim.
##
## Bench API: bench_stats() (picked up by bench_crowd automatically).

const SHADER_SURFACE: Shader = preload("res://shaders/water_surface.gdshader")
const SHADER_SHAFT: Shader = preload("res://shaders/water_light_shaft.gdshader")
const SHADER_SNOW: Shader = preload("res://shaders/water_snow.gdshader")
const SHADER_REFRACTION: Shader = preload("res://shaders/water_refraction.gdshader")
const NOISE_TEX: Texture2D = preload("res://shaders/textures/caustics_cells.png")

## Surface plane size; must exceed 2 x water_surface fade_end_m (160 m) plus SURFACE_SNAP_M.
const SURFACE_SIZE_M: float = 360.0
const SURFACE_SNAP_M: float = 10.0
const SHAFT_CELL_M: float = 16.0
## Search radius for shaft cells (cells); the nearest `light_shafts` occupied cells get a cone.
const SHAFT_RADIUS_CELLS: int = 5
## Fraction of grid cells that hold a shaft.
const SHAFT_CELL_DENSITY: float = 0.45
const SHAFT_LENGTH_M: Vector2 = Vector2(34.0, 52.0)
const SHAFT_TOP_RADIUS_M: Vector2 = Vector2(0.8, 2.2)
const SHAFT_SPREAD: float = 2.2
## Shafts lean away from the light (unit-ish direction of travel of the light, mostly down).
const SHAFT_DIR: Vector3 = Vector3(0.22, -1.0, 0.14)
## Camera depth where the shafts are fully visible / gone.
const SHAFT_FADE_DEPTH_M: Vector2 = Vector2(25.0, 55.0)
## Snow brightness at the surface and at the abyss floor (x DepthEnvironment.depth_t).
const SNOW_INTENSITY: Vector2 = Vector2(0.55, 0.3)
const SNOW_SEED: int = 7

var quality_tier: StringName = QualitySettings.HIGH

var _camera: Camera3D
var _env: DepthEnvironment
var _surface: MeshInstance3D
var _surface_mat: ShaderMaterial
var _shafts: MultiMeshInstance3D
var _shaft_mat: ShaderMaterial
var _shaft_count: int = 0
var _shaft_cell := Vector2i(1 << 30, 1 << 30)
var _snow: MeshInstance3D
var _snow_mat: ShaderMaterial
var _snow_count: int = 0
var _refraction: MeshInstance3D


func _ready() -> void:
	# after the camera (0) and DepthEnvironment (20) have updated this frame
	process_priority = 21


## Builds the stack for `p_tier` around `camera`; `depth_env` (optional) feeds the water colour and depth.
func setup(camera: Camera3D, p_tier: StringName, depth_env: DepthEnvironment = null) -> void:
	_camera = camera
	_env = depth_env
	quality_tier = p_tier
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var prof: Dictionary = QualitySettings.profile(p_tier)
	_build_surface(int(prof["surface_cells"]))
	_build_shafts(int(prof["light_shafts"]))
	_build_snow(int(prof["marine_snow"]))
	if bool(prof["refraction"]):
		_build_refraction()
	_process(0.0)


func _process(_delta: float) -> void:
	if _camera == null:
		return
	var cam: Vector3 = _camera.global_position
	var depth_t: float = _env.depth_t if _env != null else clampf(-cam.y / 80.0, 0.0, 1.0)
	_surface.global_position = Vector3(snappedf(cam.x, SURFACE_SNAP_M), 0.0, snappedf(cam.z, SURFACE_SNAP_M))
	if _env != null:
		_surface_mat.set_shader_parameter(&"water_color", _env.water_color)
	_surface_mat.set_shader_parameter(&"surface_light", 1.0 - 0.85 * depth_t)
	var shaft_fade: float = 1.0 - smoothstep(SHAFT_FADE_DEPTH_M.x, SHAFT_FADE_DEPTH_M.y, -cam.y)
	_shafts.visible = shaft_fade > 0.0 and _shaft_count > 0
	if _shafts.visible:
		_shaft_mat.set_shader_parameter(&"shaft_fade", shaft_fade)
		var cell := Vector2i(floori(cam.x / SHAFT_CELL_M), floori(cam.z / SHAFT_CELL_M))
		if cell != _shaft_cell:
			_shaft_cell = cell
			_place_shafts(cell)
	_snow_mat.set_shader_parameter(&"intensity", lerpf(SNOW_INTENSITY.x, SNOW_INTENSITY.y, depth_t))


## Look-stack counters for benches: quality_tier, light_shafts (cones placed and visible), marine_snow (flakes),
## refraction (bool), volumetric_fog (bool, from DepthEnvironment).
func bench_stats() -> Dictionary:
	return {
		"quality_tier": String(quality_tier),
		"light_shafts": _shafts.multimesh.visible_instance_count if _shafts != null and _shafts.visible else 0,
		"marine_snow": _snow_count,
		"refraction": _refraction != null,
		"volumetric_fog": _env != null and _env.volumetric_fog,
	}


func _build_surface(cells: int) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SURFACE_SIZE_M, SURFACE_SIZE_M)
	plane.subdivide_width = cells - 1
	plane.subdivide_depth = cells - 1
	_surface_mat = ShaderMaterial.new()
	_surface_mat.shader = SHADER_SURFACE
	plane.material = _surface_mat
	_surface = _add_mesh("Surface", plane)


func _build_shafts(count: int) -> void:
	_shaft_count = count
	var cone := CylinderMesh.new()
	cone.top_radius = 1.0
	cone.bottom_radius = SHAFT_SPREAD
	cone.height = 1.0
	cone.radial_segments = 10
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	_shaft_mat = ShaderMaterial.new()
	_shaft_mat.shader = SHADER_SHAFT
	_shaft_mat.set_shader_parameter(&"noise_tex", NOISE_TEX)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true  # before instance_count
	mm.instance_count = count
	mm.visible_instance_count = 0
	mm.mesh = cone
	_shafts = MultiMeshInstance3D.new()
	_shafts.name = "LightShafts"
	_shafts.multimesh = mm
	_shafts.material_override = _shaft_mat
	_shafts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shafts)
	_shaft_cell = Vector2i(1 << 30, 1 << 30)


# Nearest occupied cells around `center` get a cone each (deterministic per cell, independent of the camera path).
func _place_shafts(center: Vector2i) -> void:
	var mm: MultiMesh = _shafts.multimesh
	var found: Array[Vector3i] = []  # (dist2, i, j)
	for dj in range(-SHAFT_RADIUS_CELLS, SHAFT_RADIUS_CELLS + 1):
		for di in range(-SHAFT_RADIUS_CELLS, SHAFT_RADIUS_CELLS + 1):
			var i: int = center.x + di
			var j: int = center.y + dj
			if _hash01(i, j, 0) < SHAFT_CELL_DENSITY:
				found.append(Vector3i(di * di + dj * dj, i, j))
	found.sort()
	var n: int = mini(found.size(), mm.instance_count)
	var dir: Vector3 = SHAFT_DIR.normalized()
	for k in n:
		var i: int = found[k].y
		var j: int = found[k].z
		var length: float = lerpf(SHAFT_LENGTH_M.x, SHAFT_LENGTH_M.y, _hash01(i, j, 3))
		var radius: float = lerpf(SHAFT_TOP_RADIUS_M.x, SHAFT_TOP_RADIUS_M.y, _hash01(i, j, 4))
		var top := Vector3((float(i) + 0.15 + 0.7 * _hash01(i, j, 1)) * SHAFT_CELL_M, 0.5,
			(float(j) + 0.15 + 0.7 * _hash01(i, j, 2)) * SHAFT_CELL_M)
		# mesh +Y points against the light: the cone's top sits at the surface, its body runs along `dir`
		var basis := Basis(Quaternion(Vector3.UP, -dir)) * Basis.from_scale(Vector3(radius, length, radius))
		mm.set_instance_transform(k, Transform3D(basis, top + dir * (length * 0.5)))
		mm.set_instance_custom_data(k, Color(lerpf(0.45, 1.0, _hash01(i, j, 5)), _hash01(i, j, 6), 0.0, 0.0))
	mm.visible_instance_count = n


func _build_snow(count: int) -> void:
	_snow_count = count
	var rng := RandomNumberGenerator.new()
	rng.seed = SNOW_SEED
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	verts.resize(count * 4)
	uvs.resize(count * 4)
	uv2s.resize(count * 4)
	idx.resize(count * 6)
	var corners: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for f in count:
		var p := Vector3(rng.randf(), rng.randf(), rng.randf())
		var extra := Vector2(rng.randf(), rng.randf())
		for c in 4:
			verts[f * 4 + c] = p
			uvs[f * 4 + c] = corners[c]
			uv2s[f * 4 + c] = extra
		var b: int = f * 4
		idx[f * 6 + 0] = b
		idx[f * 6 + 1] = b + 1
		idx[f * 6 + 2] = b + 2
		idx[f * 6 + 3] = b
		idx[f * 6 + 4] = b + 2
		idx[f * 6 + 5] = b + 3
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	if count > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-5000, -5000, -5000), Vector3(10000, 10000, 10000))
	_snow_mat = ShaderMaterial.new()
	_snow_mat.shader = SHADER_SNOW
	_snow = _add_mesh("MarineSnow", mesh)
	_snow.material_override = _snow_mat


func _build_refraction() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_REFRACTION
	mat.render_priority = Material.RENDER_PRIORITY_MIN
	quad.material = mat
	_refraction = _add_mesh("Refraction", quad)
	_refraction.extra_cull_margin = 16384.0


func _add_mesh(part_name: String, mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


# Deterministic 0..1 hash of a grid cell and a channel (presentation only, no sim RNG).
static func _hash01(i: int, j: int, channel: int) -> float:
	var h: int = (i * 73856093) ^ (j * 19349663) ^ (channel * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0
