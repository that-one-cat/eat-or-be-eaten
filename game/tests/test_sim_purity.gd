extends TestCase
## CLAUDE.md hard rule 1: game/scripts/sim/ is pure logic (RefCounted, no nodes, no SceneTree), deterministic,
## no global RNG, no wall clock. Static scan of the sources + a check that all contract files exist.

const SIM_DIR: String = "res://scripts/sim"
const CONTRACT_FILES: Array[String] = [
	"sim_rng.gd", "sim_command.gd", "sim_command_queue.gd", "sim_event.gd",
	"sim_entity.gd", "sim_world.gd", "spatial_grid.gd", "content_db.gd",
]

var _sources: Dictionary = {}  # file name -> Array[String] of code lines (comments stripped)


func before_each() -> void:
	_sources.clear()
	var dir := DirAccess.open(SIM_DIR)
	assert_not_null(dir, "cannot open %s" % SIM_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".gd"):
			var lines: Array[String] = []
			for raw in FileAccess.get_file_as_string(SIM_DIR.path_join(f)).split("\n"):
				lines.append(raw.split("#")[0])  # drop comments (a '#' inside a string is rare enough)
			_sources[f] = lines


func _offenders(pattern: String) -> Array[String]:
	var rx := RegEx.new()
	var err: int = rx.compile(pattern)
	assert_eq(err, OK, "test bug: regex does not compile: %s" % pattern)
	var hits: Array[String] = []
	for f in _sources:
		var lines: Array = _sources[f]
		for i in lines.size():
			if rx.search(lines[i]) != null:
				hits.append("%s:%d: %s" % [f, i + 1, str(lines[i]).strip_edges()])
	return hits


func test_contract_files_exist() -> void:
	for f in CONTRACT_FILES:
		assert_true(FileAccess.file_exists(SIM_DIR.path_join(f)), "contract file missing: %s/%s" % [SIM_DIR, f])


func test_sim_has_scripts_to_scan() -> void:
	assert_true(_sources.size() >= CONTRACT_FILES.size(), "scan found only %d scripts, purity checks would be vacuous" % _sources.size())


func test_sim_does_not_extend_node() -> void:
	var hits := _offenders("^\\s*extends\\s+(Node\\w*|Control|CanvasItem|Window|Viewport\\w*|SceneTree|MainLoop)\\b")
	assert_eq(hits.size(), 0, "sim must not extend nodes (rule 1):\n  " + "\n  ".join(hits))


func test_sim_has_no_scene_tree_access() -> void:
	var hits := _offenders("\\b(get_tree|get_node|get_parent|get_children|add_child|queue_free|get_viewport)\\s*\\(|\\bSceneTree\\b|\\bpreload\\s*\\(\\s*\"[^\"]*\\.tscn\"")
	assert_eq(hits.size(), 0, "sim must not touch the SceneTree:\n  " + "\n  ".join(hits))


func test_sim_does_not_use_node_style_paths_or_singletons() -> void:
	var hits := _offenders("\\bEngine\\.get_main_loop\\b|\\bInput\\.|\\bDisplayServer\\.|\\bRenderingServer\\.|\\bPhysicsServer3D\\.|@onready|\\$[A-Za-z_]")
	assert_eq(hits.size(), 0, "sim must not depend on input, rendering or node paths:\n  " + "\n  ".join(hits))


func test_every_sim_script_extends_ref_counted() -> void:
	# a sim class may also extend another sim class that extends RefCounted directly (KrillField extends PlanktonField)
	var direct := RegEx.new()
	direct.compile("^\\s*extends\\s+RefCounted\\b")
	var class_rx := RegEx.new()
	class_rx.compile("^\\s*class_name\\s+(\\w+)")
	var bases: Array[String] = ["RefCounted"]
	for f0 in _sources:
		var cls: String = ""
		var is_direct: bool = false
		for line0 in (_sources[f0] as Array):
			var m: RegExMatch = class_rx.search(line0)
			if m != null:
				cls = m.get_string(1)
			is_direct = is_direct or direct.search(line0) != null
		if is_direct and not cls.is_empty():
			bases.append(cls)
	var rx := RegEx.new()
	rx.compile("^\\s*extends\\s+(%s)\\b" % "|".join(bases))
	for f in _sources:
		var found: bool = false
		for line in (_sources[f] as Array):
			if rx.search(line) != null:
				found = true
				break
		assert_true(found, "%s must `extends RefCounted` (contract: all sim classes are RefCounted)" % f)


func test_sim_uses_no_global_rng() -> void:
	var hits := _offenders("\\b(randomize|randi|randf|randi_range|randf_range|rand_from_seed|seed)\\s*\\(")
	assert_eq(hits.size(), 0, "sim must use SimRng only (no global RNG / randomize):\n  " + "\n  ".join(hits))


func test_sim_does_not_read_wall_clock() -> void:
	var hits := _offenders("\\bTime\\.get_\\w+|\\bOS\\.get_ticks\\w*|\\bOS\\.get_unix\\w*|\\bTime\\.get_ticks\\w*")
	# content_db.gd only loads files; the simulation itself must not depend on real time.
	assert_eq(hits.size(), 0, "sim must not read the wall clock (determinism):\n  " + "\n  ".join(hits))
