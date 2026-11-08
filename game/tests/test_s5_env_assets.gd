extends TestCase
## S5 environment kit as Godot sees it: every env GLB imports to a one-mesh PackedScene with the env material
## (m_env / m_env_glow / m_env_double by the generator spec), base origin, real-metre size; every piece the dressing
## uses exists; the dressed scenes exist, main.tscn loads reef.tscn, and the dressing code stays presentation-only
## (no physics bodies, no global RNG / clock in the placement path).
## Materials are inspected headless through the imported mesh (MeshInstance3D.get_active_material): this works in
## headless runs (verified); it does NOT compile shaders, that stays a windowed manual check (plan, check.sh notes).

const S5 := preload("res://tests/s5_support.gd")
const MAX_ORIGIN_Y_M: float = 0.05
const MAX_EXTENT_M: float = 80.0


func _each_glb() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var variants: Dictionary = S5.glb_variants()
	var ids: Array = variants.keys()
	ids.sort()
	for pid: String in ids:
		for v in range(1, int(variants[pid]) + 1):
			out.append({"piece": pid, "variant": v, "path": S5.glb_path(pid, v)})
	return out


func _mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for c: Node in node.get_children():
		_mesh_instances(c, out)


# ======================================================== kit consistency

func test_the_kit_is_not_empty_and_variants_are_contiguous() -> void:
	var variants: Dictionary = S5.glb_variants()
	assert_true(variants.size() >= 20, "at least 20 environment pieces under res://assets/models/env/ (found %d)" % variants.size())
	for pid: String in variants.keys():
		for v in range(1, int(variants[pid]) + 1):
			assert_true(FileAccess.file_exists(S5.glb_path(pid, v)), "%s: variant v%d exists (variants are v1..v%d, no holes)" % [pid, v, int(variants[pid])])


func test_every_spec_has_exactly_its_variants_on_disk() -> void:
	if not S5.specs_available():
		fail("generator specs (tools/blender/env/pieces) not readable from %s" % S5.repo_root())
		return
	var variants: Dictionary = S5.glb_variants()
	for pid: String in S5.specs().keys():
		var want: int = int((S5.specs()[pid] as Dictionary).get("variants", 1))
		assert_eq(int(variants.get(pid, 0)), want, "%s: GLB variants on disk vs spec.variants" % pid)
	for pid2: String in variants.keys():
		assert_true(S5.specs().has(pid2), "GLB set '%s' has no generator spec (orphan)" % pid2)


func test_every_env_glb_is_imported() -> void:
	for g: Dictionary in _each_glb():
		assert_true(FileAccess.file_exists(str(g["path"]) + ".import"), "%s has its .import file" % g["path"])
		assert_true(ResourceLoader.exists(str(g["path"])), "%s is known to the resource loader" % g["path"])


# ======================================================== imported scenes

func test_every_env_glb_loads_as_one_mesh_with_a_base_origin() -> void:
	var checked: int = 0
	for g: Dictionary in _each_glb():
		var scene: PackedScene = load(str(g["path"])) as PackedScene
		if scene == null:
			fail("%s does not load as a PackedScene" % g["path"])
			continue
		var root: Node = scene.instantiate()
		var meshes: Array[MeshInstance3D] = []
		_mesh_instances(root, meshes)
		assert_true(root is Node3D, "%s: root is a Node3D" % g["path"])
		assert_eq(meshes.size(), 1, "%s: exactly one MeshInstance3D" % g["path"])
		if meshes.size() == 1:
			var mesh: Mesh = meshes[0].mesh
			assert_eq(mesh.get_surface_count(), 1, "%s: one surface (one material)" % g["path"])
			var box: AABB = S5.local_aabb(str(g["piece"]), int(g["variant"]))
			assert_true(absf(box.position.y) <= MAX_ORIGIN_Y_M, "%s: base at y = 0 (min y %.3f)" % [g["path"], box.position.y])
			assert_true(box.size.y > 0.05 and box.size.x < MAX_EXTENT_M * 2.0 and box.size.z < MAX_EXTENT_M * 2.0 and box.size.y < MAX_EXTENT_M, "%s: real-metre size (%s)" % [g["path"], box.size])
			assert_true(absf(box.get_center().x) < box.size.x and absf(box.get_center().z) < box.size.z, "%s: origin near the footprint centre (box %s)" % [g["path"], box])
		root.free()
		checked += 1
	assert_true(checked > 0, "no env GLB checked")


func test_env_materials_follow_the_generator_spec() -> void:
	var checked: int = 0
	for g: Dictionary in _each_glb():
		var scene: PackedScene = load(str(g["path"])) as PackedScene
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		var meshes: Array[MeshInstance3D] = []
		_mesh_instances(root, meshes)
		if meshes.size() != 1:
			root.free()
			continue
		var mat: Material = meshes[0].get_active_material(0)
		var spec: Dictionary = S5.specs().get(str(g["piece"]), {})
		var want: String = "res://shaders/m_env.tres"
		if bool(spec.get("glow", false)):
			want = "res://shaders/m_env_glow.tres"
		elif bool(spec.get("double_sided", false)):
			want = "res://shaders/m_env_double.tres"
		if mat == null:
			fail("%s: no material on surface 0" % g["path"])
		elif S5.specs().has(str(g["piece"])):
			assert_eq(mat.resource_path, want, "%s: material (spec glow=%s double_sided=%s)" % [g["path"], spec.get("glow", false), spec.get("double_sided", false)])
		else:
			assert_true(mat.resource_path.begins_with("res://shaders/m_env"), "%s: an m_env* material, got '%s'" % [g["path"], mat.resource_path])
		root.free()
		checked += 1
	assert_true(checked > 0, "no env GLB checked")


func test_the_env_materials_exist_and_use_the_env_shaders() -> void:
	for path: String in ["res://shaders/m_env.tres", "res://shaders/m_env_glow.tres", "res://shaders/m_env_double.tres"]:
		var mat: ShaderMaterial = load(path) as ShaderMaterial
		assert_not_null(mat, "%s loads as a ShaderMaterial" % path)
		if mat != null:
			assert_not_null(mat.shader, "%s has a shader" % path)
			assert_true(mat.shader.resource_path.contains("env_palette"), "%s uses an env_palette shader (got %s)" % [path, mat.shader.resource_path])


func test_every_piece_the_dressing_uses_loads() -> void:
	var d: Dictionary = S5.dressing()
	if d.is_empty():
		fail("S5 data missing: %s" % S5.DRESSING_PATH)
		return
	var used: Dictionary = {}
	for r: Variant in d.get("scatter", []):
		for pe: Variant in (r as Dictionary).get("pieces", []):
			for v: int in S5.variant_list((pe as Dictionary).get("variants", 1)):
				used["%s|%d" % [(pe as Dictionary)["id"], v]] = true
	for w: Variant in d.get("set_pieces", []):
		used["%s|%d" % [(w as Dictionary)["piece"], int((w as Dictionary).get("variant", 1))]] = true
	assert_true(used.size() > 0, "the dressing uses pieces")
	for key: String in used.keys():
		var parts: PackedStringArray = key.split("|")
		var path: String = S5.glb_path(parts[0], int(parts[1]))
		assert_true(load(path) is PackedScene, "%s (used by the dressing) loads as a PackedScene" % path)


# ======================================================== scenes and presentation-only code

func test_the_dressed_reef_scene_loads_and_the_greybox_stays() -> void:
	assert_true(load(S5.REEF_SCENE) is PackedScene, "%s loads as a PackedScene" % S5.REEF_SCENE)
	assert_true(load(S5.GREYBOX_SCENE) is PackedScene, "%s still exists (swim tour, tests, fallback)" % S5.GREYBOX_SCENE)


func test_main_scene_loads_the_reef() -> void:
	var text: String = FileAccess.get_file_as_string(S5.MAIN_SCENE)
	assert_false(text.is_empty(), "%s is readable" % S5.MAIN_SCENE)
	assert_true(text.contains("scenes/maps/reef.tscn"), "main.tscn references scenes/maps/reef.tscn (not the grey-box)")
	assert_false(text.contains("reef_greybox.tscn"), "main.tscn no longer loads the grey-box")


func test_the_dressing_code_has_no_physics_bodies() -> void:
	var src: String = FileAccess.get_file_as_string(S5.BUILDER_SCRIPT)
	assert_false(src.is_empty(), "S5 API missing: %s" % S5.BUILDER_SCRIPT)
	var scene_text: String = FileAccess.get_file_as_string(S5.REEF_SCENE)
	var rx := RegEx.new()
	rx.compile("StaticBody3D|RigidBody3D|CharacterBody3D|AnimatableBody3D|CollisionShape3D|CollisionPolygon3D|Area3D|PhysicsServer3D")
	var code_lines: Array[String] = []
	for line: String in src.split("\n"):
		if not line.strip_edges().begins_with("#"):
			code_lines.append(line)
	assert_null(rx.search("\n".join(code_lines)), "map_dressing.gd must not create physics bodies (sim collision = analytic SeabedField obstacles)")
	assert_null(rx.search(scene_text), "reef.tscn must not contain physics bodies or collision shapes")


func test_the_placement_path_uses_no_global_rng_or_clock() -> void:
	var src: String = FileAccess.get_file_as_string(S5.BUILDER_SCRIPT)
	if src.is_empty():
		fail("S5 API missing: %s" % S5.BUILDER_SCRIPT)
		return
	var rx := RegEx.new()
	rx.compile("(?<![\\w.])(randf|randi|randomize|randf_range|randi_range|rand_from_seed)\\(|Time\\.get_|OS\\.get_ticks|OS\\.get_unix")
	var hits: Array[String] = []
	for line: String in src.split("\n"):
		var code: String = line.strip_edges()
		if code.begins_with("#"):
			continue
		if rx.search(code) != null:
			hits.append(code)
	assert_eq(hits.size(), 0, "global RNG or clock in map_dressing.gd (use a seeded RandomNumberGenerator / hash): %s" % [hits])
	assert_true(src.contains("static func compute_placements"), "map_dressing.gd declares `static func compute_placements` (plan A5)")


func test_the_sim_never_reads_the_dressing() -> void:
	var d: DirAccess = DirAccess.open("res://scripts/sim")
	assert_not_null(d, "res://scripts/sim is readable")
	if d == null:
		return
	for f: String in d.get_files():
		if f.get_extension() != "gd":
			continue
		var src: String = FileAccess.get_file_as_string("res://scripts/sim".path_join(f))
		if f == "content_db.gd":
			continue  # data loading only: the one place that may know the dressing file
		assert_false(src.contains("MapDressing") or src.contains("reef_dressing") or src.contains("get_dressing"), "res://scripts/sim/%s must not depend on the dressing (rule 1)" % f)
