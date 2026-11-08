extends Node3D
## Dev showcase (S1): species GLBs swimming in place, juvenile next to adult.
##
## Every direct child with a `growth` metadata entry is a fish (an instanced species GLB):
## growth 0 = juvenile, 1 = adult, mapped to the `juvenile`/`adult` blend shapes
## (weight(juvenile) = 1 - growth, weight(adult) = growth). Optional `swim_material` metadata
## overrides the swim ShaderMaterial (e.g. the ray's wing-flap preset).
## Scale follows the unit-length convention: node scale = body length in metres. The adult
## length comes from the GLB extras (`length_m`); a juvenile is `juvenile_length_ratio` of it.

const DEFAULT_SWIM_MATERIAL: Material = preload("res://shaders/m_fish_swim.tres")
## Phase step between fish so they do not beat in sync (radians).
const PHASE_STEP: float = 2.1

## Juvenile length as a fraction of the adult length (player fish: 0.10 m of 0.20 m).
@export_range(0.1, 1.0) var juvenile_length_ratio: float = 0.5


func _ready() -> void:
	var index: int = 0
	for child: Node in get_children():
		if not child.has_meta("growth"):
			continue
		var fish: Node3D = child as Node3D
		var mesh_instance: MeshInstance3D = _find_mesh(child)
		if fish == null or mesh_instance == null:
			push_error("species_showcase: %s has no MeshInstance3D" % child.name)
			continue
		var growth: float = clampf(float(child.get_meta("growth")), 0.0, 1.0)
		var extras: Dictionary = mesh_instance.get_meta("extras", {})
		var adult_length: float = float(extras.get("length_m", 1.0))
		fish.scale = Vector3.ONE * adult_length * lerpf(juvenile_length_ratio, 1.0, growth)
		_set_shape(mesh_instance, &"juvenile", 1.0 - growth)
		_set_shape(mesh_instance, &"adult", growth)
		mesh_instance.material_override = child.get_meta("swim_material", DEFAULT_SWIM_MATERIAL)
		mesh_instance.set_instance_shader_parameter(&"swim_phase", PHASE_STEP * float(index))
		index += 1


func _set_shape(mesh_instance: MeshInstance3D, shape: StringName, weight: float) -> void:
	var idx: int = mesh_instance.find_blend_shape_by_name(shape)
	if idx < 0:
		push_error("species_showcase: %s has no blend shape %s" % [mesh_instance.name, shape])
		return
	mesh_instance.set_blend_shape_value(idx, weight)


func _find_mesh(node: Node) -> MeshInstance3D:
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
	return null
