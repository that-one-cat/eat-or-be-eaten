@tool
extends EditorScenePostImport
## Post-import for species GLBs (game/assets/models/species/*.glb, set as `import_script/path`
## in each .glb.import file).
##
## - Replaces every surface material (Blender's placeholder `M_Palette`) with the shared
##   palette toon ShaderMaterial, so all species batch on one material.
## - Flat facets: the GLB already carries per-face normals (flat-shaded export, morph normals
##   included) and the palette shaders rebuild facet normals from derivatives, which stays
##   correct under blend shapes and swim deformation. Normals are therefore kept as is.
## - Meshes under AUTO_LOD_MAX_TRIS triangles are rebuilt without the importer's auto-LODs
##   (LODs on sub-1k low-poly meshes only destroy the silhouette). Blend shapes and their
##   default weights are preserved (skin arrays too: the hero rigs keep their bones and weights).
## - Hero rigs (`*_rig_lod0.glb`, tools/blender/rig/make_rig.py): the static pose clips (turn_l, turn_r, tell) are
##   set to loop so the AnimationTree holds them; `swim_loop` is already looped and renamed `swim` by the importer
##   (`_loop` name suffix). Rig GLBs import with `animation/remove_immutable_tracks=false` (the static poses are
##   constant tracks) and `animation/import_rest_as_RESET=true` (rest pose = the additive reference).

const PALETTE_MATERIAL_PATH: String = "res://shaders/m_palette.tres"
const AUTO_LOD_MAX_TRIS: int = 1000
const LOOPED_POSES: Array[StringName] = [&"turn_l", &"turn_r", &"tell"]


func _post_import(scene: Node) -> Object:
	var material: Material = load(PALETTE_MATERIAL_PATH) as Material
	if material == null:
		push_error("species_post_import: cannot load %s" % PALETTE_MATERIAL_PATH)
		return scene
	_process_node(scene, material)
	return scene


func _process_node(node: Node, material: Material) -> void:
	var mesh_instance: MeshInstance3D = node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh is ArrayMesh:
		_process_mesh(mesh_instance, mesh_instance.mesh as ArrayMesh, material)
	var player: AnimationPlayer = node as AnimationPlayer
	if player != null:
		for anim_name: StringName in player.get_animation_list():
			if LOOPED_POSES.has(anim_name):
				player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	for child: Node in node.get_children():
		_process_node(child, material)


func _process_mesh(mesh_instance: MeshInstance3D, src: ArrayMesh, material: Material) -> void:
	if _triangle_count(src) >= AUTO_LOD_MAX_TRIS:
		for s: int in src.get_surface_count():
			src.surface_set_material(s, material)
		return

	var weights: Dictionary[StringName, float] = {}
	for b: int in src.get_blend_shape_count():
		var shape_name: StringName = src.get_blend_shape_name(b)
		weights[shape_name] = mesh_instance.get_blend_shape_value(b)

	var dst: ArrayMesh = ArrayMesh.new()
	dst.resource_name = src.resource_name
	dst.blend_shape_mode = src.blend_shape_mode
	for b: int in src.get_blend_shape_count():
		dst.add_blend_shape(src.get_blend_shape_name(b))
	for s: int in src.get_surface_count():
		# Empty LOD dictionary: no auto-LOD levels for this surface.
		dst.add_surface_from_arrays(src.surface_get_primitive_type(s), src.surface_get_arrays(s),
				src.surface_get_blend_shape_arrays(s), {})
		dst.surface_set_name(s, src.surface_get_name(s))
		dst.surface_set_material(s, material)
	mesh_instance.mesh = dst

	for b: int in dst.get_blend_shape_count():
		mesh_instance.set_blend_shape_value(b, weights.get(dst.get_blend_shape_name(b), 0.0))


func _triangle_count(mesh: ArrayMesh) -> int:
	var tris: int = 0
	for s: int in mesh.get_surface_count():
		var index_len: int = mesh.surface_get_array_index_len(s)
		tris += (index_len if index_len > 0 else mesh.surface_get_array_len(s)) / 3
	return tris
