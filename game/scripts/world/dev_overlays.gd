class_name DevOverlays
extends Node3D
## Debug overlays of the God tools (console `overlay <name> [on|off]`): read-only presentation, never writes sim state
## (rule 1), created lazily by GodContext on the first toggle so an unused overlay costs nothing. Child of the map scene
## root; `top_level`, so everything is drawn in world coordinates.
##  - obstacles: the sim obstacle proxies as translucent magenta (what `--show-obstacles` draws); delegated to the map
##    root's `set_obstacles_visible(on)` (dressed reef `reef.tscn`). The grey-box reef always draws its obstacles, so
##    there the overlay is "unsupported" (set_enabled returns false).
##  - zones: wire box of every `map.zones` aabb, one colour per zone (built once).
##  - grid: the SpatialGrid cell lattice (cell size from the world grid) within GRID_RADIUS_CELLS cells of the player;
##    rebuilt when the player enters another cell.
##  - detect: per NPC within DETECT_RANGE_M of the player (nearest DETECT_MAX_NPCS), a horizontal and a vertical ring for
##    its detection (red), flee (yellow) and boost-within (orange) radius; rebuilt every DETECT_EVERY_FRAMES frames.
##  - bitecue (T1.11, an A/B experiment, not a feature): ONE pooled billboard ring around the creature a bite press would
##    hit right now (`SimWorld.peek_bite_target`, read-only), sized to its collision radius, constant low alpha, no
##    flashing; hidden while there is no target. The marker node exists only while the overlay is on.
## Lines are unshaded, unlit, no shadows, drawn on top (depth test off, high render priority): they work in the
## Compatibility renderer too.

const NAMES: PackedStringArray = ["obstacles", "zones", "grid", "detect", "bitecue"]
const GRID_RADIUS_CELLS: int = 5
const DETECT_RANGE_M: float = 60.0
const DETECT_MAX_NPCS: int = 24
const DETECT_EVERY_FRAMES: int = 4
const RING_SEGMENTS: int = 24
const DETECT_COLOR: Color = Color(1.0, 0.25, 0.2)
const FLEE_COLOR: Color = Color(1.0, 0.9, 0.2)
const BOOST_COLOR: Color = Color(1.0, 0.55, 0.1)
const GRID_COLOR: Color = Color(0.3, 0.9, 1.0, 0.8)
const CUE_COLOR: Color = Color(1.0, 0.95, 0.65, 0.4)
const CUE_SCALE: float = 1.15  # marker diameter = target collision diameter x this
const CUE_MIN_DIAMETER_M: float = 0.05
const CUE_INNER: float = 0.45  # unit ring (outer radius 0.5)

var _world: SimWorld = null
var _player_id: int = -1
var _run: Node = null
var _enabled: Dictionary = {}  # name -> bool
var _meshes: Dictionary = {}  # name -> MeshInstance3D (zones, grid, detect)
var _material: StandardMaterial3D = null
var _cue: MeshInstance3D = null  # the bitecue marker, null while the overlay is off
var _grid_cell: Vector3i = Vector3i(2147483647, 0, 0)
var _frame: int = 0


## Binds the overlays to a run: `run` is the map scene root (it may offer `set_obstacles_visible`).
func setup(world: SimWorld, player_id: int, run: Node) -> void:
	_world = world
	_player_id = player_id
	_run = run
	top_level = true
	name = "DevOverlays"


## Overlay names this node knows.
static func names() -> PackedStringArray:
	return NAMES


func is_enabled(overlay: String) -> bool:
	return bool(_enabled.get(overlay, false))


## Number of mesh vertices an overlay currently holds (0 when off / empty); diagnostics and tests.
func vertex_count(overlay: String) -> int:
	var inst: MeshInstance3D = _meshes.get(overlay)
	if inst == null or not inst.visible or inst.mesh == null or inst.mesh.get_surface_count() == 0:
		return 0
	return (inst.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


## Switches an overlay. Returns false for an unknown name or one the current map cannot show (obstacles on the grey-box
## reef); nothing is created for an `off` request of an overlay that was never on.
func set_enabled(overlay: String, on: bool) -> bool:
	if not NAMES.has(overlay) or _world == null:
		return false
	if overlay == "obstacles":
		if _run == null or not _run.has_method(&"set_obstacles_visible"):
			return false
		_run.call(&"set_obstacles_visible", on)
		_enabled[overlay] = on
		return true
	if overlay == "bitecue":
		_set_cue(on)
		return true
	if not on and not _meshes.has(overlay):
		_enabled[overlay] = false
		return true
	var inst: MeshInstance3D = _mesh_of(overlay)
	inst.visible = on
	_enabled[overlay] = on
	match overlay:
		"zones":
			if on and inst.mesh == null:
				inst.mesh = _zones_mesh()
		"grid":
			_grid_cell = Vector3i(2147483647, 0, 0)  # force a rebuild
		"detect":
			_frame = 0
	set_process(is_enabled("grid") or is_enabled("detect") or is_enabled("bitecue"))
	return true


func _process(_delta: float) -> void:
	if _world == null:
		return
	if is_enabled("grid"):
		_update_grid()
	if is_enabled("detect"):
		if _frame % DETECT_EVERY_FRAMES == 0:
			(_meshes["detect"] as MeshInstance3D).mesh = _detect_mesh()
		_frame += 1
	if is_enabled("bitecue"):
		_update_cue()


# bitecue on: one marker node (hidden until a target exists); off: the node is freed, nothing is kept.
func _set_cue(on: bool) -> void:
	_enabled["bitecue"] = on
	if on and _cue == null:
		_cue = _make_cue()
		add_child(_cue)
		_update_cue()
	elif not on and _cue != null:
		_cue.queue_free()
		_cue = null
	set_process(is_enabled("grid") or is_enabled("detect") or on)


func _make_cue() -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = CUE_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true  # the ring lies in the target's centre plane, the body would hide it otherwise
	mat.render_priority = 100
	var inst := MeshInstance3D.new()
	inst.name = "BiteCue"
	inst.mesh = _ring_mesh()
	inst.material_override = mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.extra_cull_margin = 1.0
	inst.visible = false
	return inst


# Moves the marker onto the creature the sim says a bite would hit now (read-only: peek_bite_target never writes).
func _update_cue() -> void:
	if _cue == null:
		return
	var target: SimEntity = null
	var id: int = _world.peek_bite_target(_player_id)
	if id >= 0:
		target = _world.get_entity(id)
	_cue.visible = target != null
	if target == null:
		return
	var d: float = maxf(2.0 * _world.collision_radius(target) * CUE_SCALE, CUE_MIN_DIAMETER_M)
	_cue.global_position = target.position
	_cue.scale = Vector3(d, d, d)


# A flat unit ring in the XY plane (outer radius 0.5): the material billboards it.
static func _ring_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for s in RING_SEGMENTS:
		var a: float = TAU * float(s) / float(RING_SEGMENTS)
		verts.append(Vector3(cos(a), sin(a), 0.0) * 0.5)
		verts.append(Vector3(cos(a), sin(a), 0.0) * CUE_INNER)
		var o0: int = 2 * s
		var o1: int = 2 * ((s + 1) % RING_SEGMENTS)
		idx.append_array([o0, o0 + 1, o1, o1, o0 + 1, o1 + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _mesh_of(overlay: String) -> MeshInstance3D:
	if _meshes.has(overlay):
		return _meshes[overlay]
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.vertex_color_use_as_albedo = true
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.no_depth_test = true
		_material.render_priority = 100
	var inst := MeshInstance3D.new()
	inst.name = overlay.capitalize()
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.material_override = _material
	inst.extra_cull_margin = 16384.0  # the lines move with the player / span the map: never frustum-culled
	add_child(inst)
	_meshes[overlay] = inst
	return inst


func _zones_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for z: Variant in _world.map.get("zones", []):
		var zone: Dictionary = z
		var box: Dictionary = zone.get("aabb", {})
		var lo: Array = box.get("min", [])
		var hi: Array = box.get("max", [])
		if lo.size() != 3 or hi.size() != 3:
			continue
		var col := Color.from_hsv(float(str(zone.get("id", "")).hash() % 360) / 360.0, 0.6, 1.0, 0.9)
		_add_box(verts, cols, Vector3(lo[0], lo[1], lo[2]), Vector3(hi[0], hi[1], hi[2]), col)
	return _lines(verts, cols)


func _update_grid() -> void:
	var p: SimEntity = _world.get_entity(_player_id)
	if p == null or _world.grid == null:
		return
	var cs: float = _world.grid.cell_size
	var cell := Vector3i(floori(p.position.x / cs), floori(p.position.y / cs), floori(p.position.z / cs))
	if cell == _grid_cell:
		return
	_grid_cell = cell
	var r: int = GRID_RADIUS_CELLS
	var lo := Vector3(cell - Vector3i(r, r, r)) * cs
	var hi := Vector3(cell + Vector3i(r + 1, r + 1, r + 1)) * cs
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for i in 2 * r + 2:
		for j in 2 * r + 2:
			var a: float = float(i) * cs
			var b: float = float(j) * cs
			verts.append_array([Vector3(lo.x, lo.y + a, lo.z + b), Vector3(hi.x, lo.y + a, lo.z + b)])
			verts.append_array([Vector3(lo.x + a, lo.y, lo.z + b), Vector3(lo.x + a, hi.y, lo.z + b)])
			verts.append_array([Vector3(lo.x + a, lo.y + b, lo.z), Vector3(lo.x + a, lo.y + b, hi.z)])
	cols.resize(verts.size())
	cols.fill(GRID_COLOR)
	(_meshes["grid"] as MeshInstance3D).mesh = _lines(verts, cols)


func _detect_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var player: SimEntity = _world.get_entity(_player_id)
	if player == null or _world.grid == null or _world.content == null:
		return _lines(verts, cols)
	var near: Array[SimEntity] = []
	for id: int in _world.grid.query_radius(player.position, DETECT_RANGE_M):
		var e: SimEntity = _world.get_entity(id)
		if e != null and e.kind == SimEntity.Kind.CREATURE and not e.is_player and e.alive:
			near.append(e)
	near.sort_custom(func(a: SimEntity, b: SimEntity) -> bool:
		return a.position.distance_squared_to(player.position) < b.position.distance_squared_to(player.position))
	for k in mini(near.size(), DETECT_MAX_NPCS):
		var e: SimEntity = near[k]
		var rec: Dictionary = _world.content.get_species(e.species_id)
		var behaviour: Dictionary = rec.get("behaviour", {}) if rec.get("behaviour") is Dictionary else {}
		_add_rings(verts, cols, e, float(rec.get("detection_radius_m", 0.0)), DETECT_COLOR)
		_add_rings(verts, cols, e, float(rec.get("flee_radius_m", 0.0)), FLEE_COLOR)
		_add_rings(verts, cols, e, float(behaviour.get("boost_within_m", 0.0)), BOOST_COLOR)
	return _lines(verts, cols)


# A horizontal ring and a vertical ring (in the plane of the heading and up) of `radius` around `e`.
static func _add_rings(verts: PackedVector3Array, cols: PackedColorArray, e: SimEntity, radius: float, col: Color) -> void:
	if radius <= 0.0:
		return
	var fwd := Vector3(e.heading.x, 0.0, e.heading.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var axes: Array[Array] = [[Vector3.RIGHT, Vector3.BACK], [fwd, Vector3.UP]]
	for axis: Array in axes:
		var u: Vector3 = axis[0]
		var v: Vector3 = axis[1]
		for s in RING_SEGMENTS:
			var a0: float = TAU * float(s) / float(RING_SEGMENTS)
			var a1: float = TAU * float(s + 1) / float(RING_SEGMENTS)
			verts.append(e.position + (u * cos(a0) + v * sin(a0)) * radius)
			verts.append(e.position + (u * cos(a1) + v * sin(a1)) * radius)
			cols.append(col)
			cols.append(col)


static func _add_box(verts: PackedVector3Array, cols: PackedColorArray, lo: Vector3, hi: Vector3, col: Color) -> void:
	var c: Array[Vector3] = []
	for i in 8:
		c.append(Vector3(hi.x if i & 1 else lo.x, hi.y if i & 2 else lo.y, hi.z if i & 4 else lo.z))
	for pair: Array in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		verts.append(c[pair[0]])
		verts.append(c[pair[1]])
		cols.append(col)
		cols.append(col)


static func _lines(verts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
