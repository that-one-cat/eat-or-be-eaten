class_name CrowdAssets
extends RefCounted
## Shared species visuals of the NPC presentation (NpcViews, AmbientRenderer); loaded once per scene.
##
## - Species GLB scenes (`sp_<archetype>_<model>_s1_lod0.glb`) and their swim material preset (shared, never
##   mutated), body / belly / accent colours from the palette atlas (probed from the mesh UVs).
## - Crowd meshes for MultiMesh instancing: MultiMesh has no per-instance blend shapes, so the juvenile/adult blend
##   shapes are baked into a plain ArrayMesh at CROWD_GROWTH (blend shape mode normalized:
##   v = base + sum w_i (shape_i - base)). Ghost nodes of crowd fish (FeedbackFx X-ray) use the same weights.
## - Crowd materials: one duplicate of the species preset per role, `ambient` (school wobble on, see
##   fish_swim.gdshader) and `interactive` (wobble off); the swim look is identical, so a promoted member keeps its
##   tail beat (same INSTANCE_CUSTOM phase).
## - Hero rigs (S7, CLAUDE.md rule 10): species in RIG_MODELS (the giant shark boss) get the rigged GLB with its rig
##   material preset (vertex swim off) for their node view (instantiate_model); BossView drives its FishRig. Crowd
##   meshes, colours and the shared `material()` still come from the unrigged GLB / swim preset.

const MODEL_DIR: String = "res://assets/models/species/"
const MODEL_ARCHETYPES: PackedStringArray = ["fusiform", "round", "swarm", "ray"]
## Model file id when it differs from the species id (S7a: the player fish GLB doubles as small_reef_fish).
const MODEL_ALIASES: Dictionary = {&"small_reef_fish": "reef_fish"}
## Swim material preset per species (as in the S7a lineup); species not listed use the default fish preset.
const MATERIALS: Dictionary = {
	&"plankton": preload("res://shaders/m_plankton_swim.tres"),
	&"krill_shallows": preload("res://shaders/m_krill_shallows_swim.tres"),
	&"krill_open": preload("res://shaders/m_krill_open_swim.tres"),
	&"krill_abyss": preload("res://shaders/m_krill_abyss_swim.tres"),
	&"puffer": preload("res://shaders/m_puffer_swim.tres"),
	&"barracuda": preload("res://shaders/m_shark_swim.tres"),
	&"shark": preload("res://shaders/m_shark_swim.tres"),
	&"giant_shark": preload("res://shaders/m_boss_swim.tres"),
}
const DEFAULT_MATERIAL: ShaderMaterial = preload("res://shaders/m_fish_swim.tres")
## Rigged node-view model and its material preset per species (S7 hero rigs; the player fish rig is PlayerView's).
const RIG_MODELS: Dictionary = {&"giant_shark": "res://assets/models/species/sp_fusiform_giant_shark_s1_rig_lod0.glb"}
const RIG_MATERIALS: Dictionary = {&"giant_shark": preload("res://shaders/m_boss_rig.tres")}
const PALETTE: Texture2D = preload("res://assets/textures/palette.png")
## Palette atlas layout (tools/blender/README.md): 64 rows of 4 px, 16 swatches of 16 px.
const PALETTE_ROWS: int = 64
const SLOT_BODY: int = 0
const SLOT_BELLY: int = 3
const SLOT_ACCENT: int = 11
## Growth g baked into crowd meshes (juvenile = 1 - g, adult = g).
const CROWD_GROWTH: float = 0.5

var _models: Dictionary[StringName, PackedScene] = {}
var _rig_models: Dictionary[StringName, PackedScene] = {}
var _swarm: Dictionary[StringName, bool] = {}
var _inflate: Dictionary[StringName, bool] = {}
var _colors: Dictionary[StringName, PackedColorArray] = {}
var _crowd_meshes: Dictionary[StringName, ArrayMesh] = {}
var _ambient_mats: Dictionary[StringName, ShaderMaterial] = {}
var _interactive_mats: Dictionary[StringName, ShaderMaterial] = {}
var _palette_image: Image = null


## Loads the model of every species in `content` (null content: no models).
static func create(content: ContentDB) -> CrowdAssets:
	var a := CrowdAssets.new()
	a._palette_image = PALETTE.get_image()
	if content != null:
		for sid: StringName in content.species_ids():
			a._load_species(sid)
	return a


func has_model(species_id: StringName) -> bool:
	return _models.has(species_id)


## True for the swarm archetype (plankton: the model is a cell of 1-2 cm critters, not one creature).
func is_swarm(species_id: StringName) -> bool:
	return _swarm.get(species_id, false)


## True when the model has the `inflated` blend shape (puffer: needs a per-instance weight, so it stays a node).
func has_inflate(species_id: StringName) -> bool:
	return _inflate.get(species_id, false)


## Body / belly / accent colours of a species from the palette atlas ([] when unknown).
func species_colors(species_id: StringName) -> PackedColorArray:
	return _colors.get(species_id, PackedColorArray())


## The shared swim material preset of a species.
func material(species_id: StringName) -> ShaderMaterial:
	return MATERIALS.get(species_id, DEFAULT_MATERIAL)


## A fresh instance of the species model with its swim material (null when the species has no model); the rigged
## model with its rig material for hero-rig species (giant shark).
func instantiate_model(species_id: StringName) -> Node3D:
	var rigged: bool = _rig_models.has(species_id)
	var scene: PackedScene = _rig_models[species_id] if rigged else _models.get(species_id, null)
	if scene == null:
		return null
	var model: Node3D = scene.instantiate() as Node3D
	var mesh: MeshInstance3D = find_mesh(model)
	if mesh != null:
		mesh.material_override = RIG_MATERIALS[species_id] if rigged else material(species_id)
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return model


## Blend-shape-free mesh of the species for MultiMesh instancing (baked at CROWD_GROWTH; null without a model).
func crowd_mesh(species_id: StringName) -> ArrayMesh:
	if _crowd_meshes.has(species_id):
		return _crowd_meshes[species_id]
	var scene: PackedScene = _models.get(species_id, null)
	if scene == null:
		return null
	var probe: Node3D = scene.instantiate() as Node3D
	var mi: MeshInstance3D = find_mesh(probe)
	var src: ArrayMesh = mi.mesh as ArrayMesh if mi != null else null
	var out := ArrayMesh.new()
	if src != null:
		for surf in src.get_surface_count():
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _baked_arrays(src, surf))
	probe.free()
	_crowd_meshes[species_id] = out
	return out


## Crowd material of a species: `school_wobble` = the ambient variant (wobble uniforms are set by AmbientRenderer).
func crowd_material(species_id: StringName, school_wobble: bool) -> ShaderMaterial:
	var cache: Dictionary[StringName, ShaderMaterial] = _ambient_mats if school_wobble else _interactive_mats
	var mat: ShaderMaterial = cache.get(species_id, null)
	if mat == null:
		mat = material(species_id).duplicate() as ShaderMaterial
		cache[species_id] = mat
	return mat


## Sets the juvenile/adult blend weights of a model node from growth g (no-op without those shapes).
static func set_growth(mesh: MeshInstance3D, g: float) -> void:
	set_shape(mesh, &"juvenile", 1.0 - g)
	set_shape(mesh, &"adult", g)


static func set_shape(mesh: MeshInstance3D, shape: StringName, weight: float) -> void:
	var idx: int = mesh.find_blend_shape_by_name(shape)
	if idx >= 0:
		mesh.set_blend_shape_value(idx, weight)


static func find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	var found: Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	return found[0] as MeshInstance3D if not found.is_empty() else null


# Surface arrays with the juvenile/adult blend shapes applied at CROWD_GROWTH (other shapes at 0).
func _baked_arrays(src: ArrayMesh, surf: int) -> Array:
	var arrays: Array = src.surface_get_arrays(surf)
	var shapes: Array = src.surface_get_blend_shape_arrays(surf)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array else PackedVector3Array()
	var base_v: PackedVector3Array = verts.duplicate()
	var base_n: PackedVector3Array = normals.duplicate()
	for i in mini(shapes.size(), src.get_blend_shape_count()):
		var shape_name: StringName = src.get_blend_shape_name(i)
		var w: float = 1.0 - CROWD_GROWTH if shape_name == &"juvenile" else (CROWD_GROWTH if shape_name == &"adult" else 0.0)
		if w == 0.0:
			continue
		var sv: PackedVector3Array = (shapes[i] as Array)[Mesh.ARRAY_VERTEX]
		for j in mini(sv.size(), verts.size()):
			verts[j] += (sv[j] - base_v[j]) * w
		var sn_v: Variant = (shapes[i] as Array)[Mesh.ARRAY_NORMAL]
		if sn_v is PackedVector3Array and not normals.is_empty():
			var sn: PackedVector3Array = sn_v
			for j in mini(sn.size(), normals.size()):
				normals[j] += (sn[j] - base_n[j]) * w
	for j in normals.size():
		normals[j] = normals[j].normalized()
	arrays[Mesh.ARRAY_VERTEX] = verts
	if not normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = normals
	return arrays


func _load_species(sid: StringName) -> void:
	var model_id: String = MODEL_ALIASES.get(sid, String(sid))
	for arch: String in MODEL_ARCHETYPES:
		var path: String = "%ssp_%s_%s_s1_lod0.glb" % [MODEL_DIR, arch, model_id]
		if ResourceLoader.exists(path):
			_models[sid] = load(path) as PackedScene
			_swarm[sid] = arch == "swarm"
			break
	if not _models.has(sid):
		push_warning("crowd_assets: no model for species %s" % sid)
		return
	if RIG_MODELS.has(sid) and ResourceLoader.exists(RIG_MODELS[sid]):
		_rig_models[sid] = load(RIG_MODELS[sid]) as PackedScene
	# palette row from the mesh UVs (every vertex of a species sits in its own palette row)
	var probe: Node3D = _models[sid].instantiate() as Node3D
	var mesh: MeshInstance3D = find_mesh(probe)
	if mesh != null and mesh.mesh != null:
		_inflate[sid] = mesh.find_blend_shape_by_name(&"inflated") >= 0
		if _palette_image != null and mesh.mesh.get_surface_count() > 0:
			var arrays: Array = mesh.mesh.surface_get_arrays(0)
			if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
				var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				if not uvs.is_empty():
					var row: int = clampi(int(uvs[0].y * PALETTE_ROWS), 0, PALETTE_ROWS - 1)
					_colors[sid] = PackedColorArray([_swatch(row, SLOT_BODY), _swatch(row, SLOT_BELLY), _swatch(row, SLOT_ACCENT)])
	probe.free()


func _swatch(row: int, slot: int) -> Color:
	var w: int = _palette_image.get_width()
	var h: int = _palette_image.get_height()
	return _palette_image.get_pixel(clampi(slot * w / 16 + w / 32, 0, w - 1), clampi(row * h / PALETTE_ROWS + h / (2 * PALETTE_ROWS), 0, h - 1))
