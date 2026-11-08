@tool
extends "res://scripts/fish/species_post_import.gd"
## Post-import for environment GLBs (game/assets/models/env/*.glb, set as `import_script/path`
## in each .glb.import file; tools/blender/env/build_all.py writes that stub for new GLBs).
##
## Same mesh handling as the species script (shared palette material on every surface,
## per-face normals kept, no auto-LODs below 1,000 triangles), but with the environment
## materials of the look stack, picked per mesh from the node extras written by build_all.py:
## `glow` -> m_env_glow.tres, `double_sided` -> m_env_double.tres, else m_env.tres.
## A missing env material falls back to the shared m_palette.tres. The choice is baked at
## import time: after adding or changing those materials, reimport the env GLBs (delete
## game/.godot/imported/env_* and run `godot --headless --path game --import`).
## Map dressing may still set its own material_override on MultiMesh scatter.

const ENV_MATERIAL_PATH: String = "res://shaders/m_env.tres"
const ENV_GLOW_MATERIAL_PATH: String = "res://shaders/m_env_glow.tres"
const ENV_DOUBLE_MATERIAL_PATH: String = "res://shaders/m_env_double.tres"


func _post_import(scene: Node) -> Object:
	var nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	nodes.push_front(scene)
	for node: Node in nodes:
		var mesh_instance: MeshInstance3D = node as MeshInstance3D
		if mesh_instance == null or not mesh_instance.mesh is ArrayMesh:
			continue
		var material: Material = _material_for(mesh_instance)
		if material == null:
			return scene
		_process_mesh(mesh_instance, mesh_instance.mesh as ArrayMesh, material)
	return scene


func _material_for(mesh_instance: MeshInstance3D) -> Material:
	var extras: Dictionary = mesh_instance.get_meta(&"extras", {}) as Dictionary
	var path: String = ENV_MATERIAL_PATH
	if extras.get("glow", false):
		path = ENV_GLOW_MATERIAL_PATH
	elif extras.get("double_sided", false):
		path = ENV_DOUBLE_MATERIAL_PATH
	if not ResourceLoader.exists(path):
		path = PALETTE_MATERIAL_PATH
	var material: Material = load(path) as Material
	if material == null:
		push_error("env_post_import: cannot load %s" % path)
	return material
