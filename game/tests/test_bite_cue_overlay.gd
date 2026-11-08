extends TestCase
## T1.11 "can bite" cue, presentation side: the dev overlay `bitecue` (DevOverlays, console `overlay bitecue [on|off]`,
## `overlay list`, God menu quick button). One pooled marker node exists only while the overlay is on, follows the creature the
## sim peek names (`SimWorld.peek_bite_target`), is hidden without a target, never touches the sim (rule 1), is default off,
## not persisted and only referenced by God / dev code. Plus the A/B capture God script.
##
## Assumptions (test plan): the overlay sits on the existing DevOverlays node as ONE child Node3D (no children of its own) that is
## created on `on` and freed (queue_free is fine, two frames are awaited) on `off`; it is visible only while a target is peeked and
## its centre is within the target collision radius + K.MARKER_TOL_M of the target centre after one frame; the overlay processes
## only while on; the capture script lives below tools/capture/ as `*.godscript`. Style checks (size, alpha, no flashing) apply only
## when the marker is a plain GeometryInstance3D / StandardMaterial3D, otherwise they are skipped.

const K := preload("res://tests/bite_cue_support.gd")
const G := preload("res://tests/god_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const CM := preload("res://tests/control_modes_support.gd")

var _nodes: Array[Node] = []
var _cmds: GodCommands = null


func before_each() -> void:
	_cmds = GodCommands.with_builtins()
	GodSimCommands.register_all(_cmds)


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	(Engine.get_main_loop() as SceneTree).paused = false


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int = 3) -> void:
	for i in n:
		await _tree().process_frame


func _adopt(n: Node) -> void:
	_tree().root.add_child(n)
	_nodes.append(n)
	await _tree().process_frame


## {"w","p","vs","pins","keep","run","ctx"}: AS arena (brains off), victims as [distance_m, deg] pairs pinned, a GodContext whose
## run node is in the tree. `length_mult` x player length for the victims (6 = the standard durable victim).
func _rig(victims: Array = [[0.9, 0.0]], length_mult: float = 6.0) -> Dictionary:
	var w: SimWorld = AS.world(AS.opts(0.0))
	var p: SimEntity = TS.player(w)
	var vs: Array[SimEntity] = []
	var pins: Dictionary = {}
	var keep: Array[int] = [p.id]
	for d: Variant in victims:
		var pos: Vector3 = TS.at(p, float((d as Array)[0]), float((d as Array)[1]))
		var v: SimEntity = S3.npc_at(w, &"small_reef_fish", pos, p.length_m * length_mult, -p.heading)
		vs.append(v)
		pins[v.id] = pos
		keep.append(v.id)
	var run := Node3D.new()
	await _adopt(run)
	return {"w": w, "p": p, "vs": vs, "pins": pins, "keep": keep, "run": run, "ctx": G.context(w, p.id, run)}


func _x(rg: Dictionary, line: String) -> String:
	return _cmds.execute(line, rg["ctx"])


func _step(rg: Dictionary, n: int = 1) -> void:
	S3.step_n(rg["w"], n, rg["pins"], rg["keep"])


func _move(rg: Dictionary, v: SimEntity, pos: Vector3) -> void:
	v.position = pos
	v.velocity = Vector3.ZERO
	rg["pins"][v.id] = pos
	_step(rg, 1)  # the spatial grid (what the selection queries) only follows entities when the sim steps


func _overlays(rg: Dictionary) -> DevOverlays:
	return (rg["ctx"] as GodContext).overlays()


func _marker(rg: Dictionary) -> Node3D:
	return K.marker_of(_overlays(rg))


func _shown(m: Node3D) -> bool:
	return m != null and is_instance_valid(m) and m.is_visible_in_tree()


func _near(m: Node3D, v: SimEntity, w: SimWorld) -> bool:
	return m != null and is_instance_valid(m) and m.global_position.distance_to(v.position) <= w.collision_radius(v) + K.MARKER_TOL_M


# ======================================================================= registration, default off

func test_the_overlay_is_registered_listed_and_has_a_quick_button() -> void:
	assert_has(DevOverlays.names(), K.OVERLAY_NAME, "DevOverlays.names() carries bitecue")
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "overlay list"), "bitecue: off", "listed, and off by default")
	assert_has(_x(rg, "overlay lasers"), "bitecue", "the usage line of an unknown name lists it")
	var lines: PackedStringArray = _cmds.quick_lines(rg["ctx"])
	assert_has(lines, "overlay bitecue", "quick button line")
	var idx: Array[int] = []
	for i in lines.size():
		if lines[i].begins_with("overlay "):
			idx.append(i)
	assert_eq(idx[-1] - idx[0] + 1, idx.size(), "the overlay buttons form one block, bitecue sits next to the other overlays")
	assert_true(idx.size() >= 5, "obstacles, zones, grid, detect and bitecue")


func test_default_off_nothing_is_created_and_nothing_runs() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "overlay list"), "bitecue: off", "off")
	var ov: DevOverlays = _overlays(rg)
	assert_false(ov.is_enabled(K.OVERLAY_NAME), "flag off")
	assert_eq(ov.get_child_count(), 0, "no node below DevOverlays")
	assert_has(_x(rg, "overlay bitecue off"), "overlay bitecue: off", "an off request is answered")
	await _frames(2)
	assert_eq(ov.get_child_count(), 0, "an off request for an overlay that was never on creates nothing")
	assert_false(ov.is_enabled(K.OVERLAY_NAME), "and the flag is still off")
	assert_eq(K.count_nodes(rg["run"]), 2, "run node + DevOverlays, nothing else")


func test_a_fresh_context_starts_off_nothing_is_remembered() -> void:
	var a: Dictionary = await _rig()
	_x(a, "overlay bitecue on")
	assert_true(_overlays(a).is_enabled(K.OVERLAY_NAME), "on in the first context")
	var b: Dictionary = await _rig()
	assert_has(_x(b, "overlay list"), "bitecue: off", "a new run context is off again (no persistence)")
	assert_eq(_overlays(b).get_child_count(), 0, "and has no marker")


# ======================================================================= the marker node

func test_on_creates_exactly_one_marker_and_off_removes_it() -> void:
	var rg: Dictionary = await _rig()
	if not K.require(self, rg["w"]):
		return
	_x(rg, "overlay list")
	var base: int = K.count_nodes(rg["run"])
	assert_has(_x(rg, "overlay bitecue on"), "overlay bitecue: on", "on")
	await _frames(3)
	assert_eq(K.count_nodes(rg["run"]), base + 1, "exactly one node added to the run (a single pooled marker)")
	var ov: DevOverlays = _overlays(rg)
	assert_eq(ov.get_child_count(), 1, "it is a child of DevOverlays")
	assert_true(ov.is_enabled(K.OVERLAY_NAME), "flag on")
	assert_true(ov.is_processing(), "processing while on")
	assert_not_null(K.marker_of(ov), "a Node3D marker")
	assert_has(_x(rg, "overlay list"), "bitecue: on", "listing agrees")
	assert_has(_x(rg, "overlay bitecue off"), "overlay bitecue: off", "off")
	await _frames(3)
	assert_eq(K.count_nodes(rg["run"]), base, "the marker is gone again")
	assert_false(ov.is_enabled(K.OVERLAY_NAME), "flag off")
	assert_false(ov.is_processing(), "no per-frame work once off")


func test_toggling_many_times_leaks_no_nodes() -> void:
	var rg: Dictionary = await _rig()
	if not K.require(self, rg["w"]):
		return
	_x(rg, "overlay list")
	var base: int = K.count_nodes(rg["run"])
	for i in 8:
		_x(rg, "overlay bitecue")  # no flag = toggle
		await _frames(2)
		assert_eq(K.count_nodes(rg["run"]), base + 1, "round %d on: one marker" % i)
		_x(rg, "overlay bitecue")
		await _frames(2)
		assert_eq(K.count_nodes(rg["run"]), base, "round %d off: none" % i)
	_x(rg, "overlay bitecue on")
	_x(rg, "overlay bitecue on")
	await _frames(2)
	assert_eq(K.count_nodes(rg["run"]), base + 1, "on twice is still one marker")


func test_the_cue_does_not_disturb_the_other_overlays() -> void:
	var rg: Dictionary = await _rig()
	if not K.require(self, rg["w"]):
		return
	_x(rg, "overlay grid on")
	await _frames(2)
	var ov: DevOverlays = _overlays(rg)
	var base_children: int = ov.get_child_count()
	_x(rg, "overlay bitecue on")
	await _frames(2)
	assert_eq(ov.get_child_count(), base_children + 1, "one more child")
	_x(rg, "overlay bitecue off")
	await _frames(2)
	assert_eq(ov.get_child_count(), base_children, "back to the grid mesh only")
	assert_true(ov.is_enabled("grid"), "grid still on")
	assert_true(ov.is_processing(), "and processing (it needs it)")
	assert_true(ov.vertex_count("grid") > 0, "grid lattice still drawn")


# ======================================================================= visibility and tracking

func test_hidden_without_a_target_and_shown_with_one() -> void:
	var rg: Dictionary = await _rig([[6.0, 0.0]])  # out of reach
	var w: SimWorld = rg["w"]
	if not K.require(self, w):
		return
	_x(rg, "overlay bitecue on")
	await _frames(3)
	var m: Node3D = _marker(rg)
	assert_not_null(m, "the marker exists while on")
	assert_false(_shown(m), "but is hidden: the prey is out of reach (peek %d)" % K.peek(w, rg["p"].id))
	var v: SimEntity = rg["vs"][0]
	_move(rg, v, TS.at(rg["p"], 0.9, 0.0))
	await _frames(3)
	m = _marker(rg)
	assert_true(_shown(m), "visible once a creature is in the cone")
	_move(rg, v, TS.at(rg["p"], 0.9, 100.0))
	await _frames(3)
	m = _marker(rg)
	assert_false(_shown(m), "hidden again when the prey leaves the strict cone (assist off)")


func test_the_marker_sits_on_the_target_and_follows_it() -> void:
	var rg: Dictionary = await _rig([[0.9, 0.0]])
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var v: SimEntity = rg["vs"][0]
	if not K.require(self, w):
		return
	_x(rg, "overlay bitecue on")
	await _frames(3)
	var m: Node3D = _marker(rg)
	assert_true(_shown(m), "visible")
	assert_true(_near(m, v, w), "on the target (marker %s, target %s)" % [m.global_position, v.position])
	var before: Vector3 = m.global_position
	_move(rg, v, TS.at(p, 1.0, 30.0))
	await _frames(3)
	m = _marker(rg)
	assert_true(_near(m, v, w), "follows the moved target (marker %s, target %s)" % [m.global_position, v.position])
	assert_true(m.global_position.distance_to(before) > 0.2, "it really moved")
	_move(rg, v, TS.at(p, 0.7, -40.0))
	await _frames(3)
	m = _marker(rg)
	assert_true(_near(m, v, w), "and again")


func test_the_marker_follows_the_peek_when_the_assist_changes_the_answer() -> void:
	var rg: Dictionary = await _rig([[0.9, 75.0], [1.3, 20.0]])  # K.GEOMETRIES "two_swap"
	var w: SimWorld = rg["w"]
	var a: SimEntity = rg["vs"][0]
	var b: SimEntity = rg["vs"][1]
	if not K.require(self, w):
		return
	_x(rg, "overlay bitecue on")
	await _frames(3)
	var m: Node3D = _marker(rg)
	assert_eq(K.peek(w, rg["p"].id), b.id, "precondition: strict cone, only B is in it")
	assert_true(_shown(m) and _near(m, b, w), "assist off: the marker is on B")
	_x(rg, AS.tune_line(AS.KEY_STRENGTH, 1.0))
	await _frames(3)
	m = _marker(rg)
	assert_eq(K.peek(w, rg["p"].id), a.id, "precondition: assist on prefers A")
	assert_true(_shown(m) and _near(m, a, w), "assist on: the marker jumped to A (marker %s, A %s)" % [m.global_position, a.position])
	_x(rg, "tune reset")
	await _frames(3)
	m = _marker(rg)
	assert_true(_shown(m) and _near(m, b, w), "tune reset: back on B")


func test_the_marker_shows_what_the_assisted_mode_would_bite() -> void:
	var rg: Dictionary = await _rig([[0.9, 75.0]])
	var w: SimWorld = rg["w"]
	if not K.require(self, w):
		return
	_x(rg, "overlay bitecue on")
	await _frames(3)
	var m: Node3D = _marker(rg)
	assert_false(_shown(m), "classic: the prey at 75 deg cannot be bitten, no cue")
	w.submit(CM.make_set(rg["p"].id, "assisted"))
	_step(rg, 2)
	await _frames(3)
	m = _marker(rg)
	assert_true(_shown(m) and _near(m, rg["vs"][0], w), "assisted mode: the cue appears on it")


func test_the_marker_is_hidden_when_the_player_is_gone() -> void:
	var rg: Dictionary = await _rig([[0.9, 0.0]])
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	if not K.require(self, w):
		return
	_x(rg, "overlay bitecue on")
	await _frames(3)
	var m: Node3D = _marker(rg)
	assert_true(_shown(m), "visible while alive")
	p.alive = false
	await _frames(3)
	m = _marker(rg)
	assert_false(_shown(m), "dead player: no cue")
	p.alive = true
	await _frames(3)
	m = _marker(rg)
	assert_true(_shown(m), "alive again: cue again")
	w.remove_entity(p.id)
	await _frames(3)
	m = _marker(rg)
	assert_false(_shown(m), "removed player: no cue and no crash")


# ======================================================================= style (tolerant)

func test_the_marker_is_sized_to_the_target_and_subtle() -> void:
	var small: Dictionary = await _rig([[0.9, 0.0]], 6.0)
	var big: Dictionary = await _rig([[0.9, 0.0]], 12.0)
	if not K.require(self, small["w"]):
		return
	_x(small, "overlay bitecue on")
	_x(big, "overlay bitecue on")
	await _frames(3)
	var ms: Node3D = _marker(small)
	var mb: Node3D = _marker(big)
	assert_true(_shown(ms) and _shown(mb), "both visible")
	var es: float = K.extent_of(ms)
	var eb: float = K.extent_of(mb)
	if es < 0.0 or eb < 0.0:
		print("NOTE test_the_marker_is_sized_to_the_target_and_subtle: marker extent not readable (not a GeometryInstance3D), size checks skipped")
	else:
		var rs: float = (small["w"] as SimWorld).collision_radius(small["vs"][0])
		var rb: float = (big["w"] as SimWorld).collision_radius(big["vs"][0])
		assert_true(es >= rs * 0.5 and es <= rs * 8.0, "small: extent %.2f m for a collision radius of %.2f m" % [es, rs])
		assert_true(eb > es * 1.3, "a target twice as long gets a clearly bigger marker (%.2f vs %.2f)" % [eb, es])
		assert_true(eb >= rb * 0.5 and eb <= rb * 8.0, "big: extent %.2f m for a collision radius of %.2f m" % [eb, rb])
	var alpha: float = K.alpha_of(ms)
	if alpha < 0.0:
		print("NOTE test_the_marker_is_sized_to_the_target_and_subtle: alpha not readable (shader / vertex colours), alpha checks skipped")
	else:
		assert_true(alpha <= 0.55, "subtle: alpha %.2f" % alpha)
		var seen: Array[float] = []
		for i in 8:
			await _frames(1)
			seen.append(K.alpha_of(ms))
			assert_true(_shown(ms), "frame %d: still visible while the target stays (no flashing)" % i)
		for a: float in seen:
			assert_almost_eq(a, alpha, 1e-4, "constant alpha over frames (no flashing)")
	if ms is GeometryInstance3D:
		assert_eq((ms as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "casts no shadow")


# ======================================================================= rule 1: presentation never mutates the sim

func test_the_cue_is_presentation_only() -> void:
	var a: Dictionary = await _rig([[0.9, 75.0], [1.3, 20.0]])
	var b: Dictionary = await _rig([[0.9, 75.0], [1.3, 20.0]])
	if not K.require(self, a["w"]):
		return
	_x(a, "overlay bitecue on")
	for rg: Dictionary in [a, b]:
		_x(rg, AS.tune_line(AS.KEY_STRENGTH, 1.0))
	var snap_a: String = ""
	for i in 40:
		(a["w"] as SimWorld).submit(SimCommand.bite(a["p"].id, -1))
		(b["w"] as SimWorld).submit(SimCommand.bite(b["p"].id, -1))
		_step(a, 3)
		_step(b, 3)
		await _frames(1)  # the overlay reads the world each frame, a peek per frame
	snap_a = TS.trace(a["w"])
	assert_eq(snap_a, TS.trace(b["w"]), "same entity state with the cue on and without it")
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "same state_hash (rule 1: presentation reads, never mutates)")
	assert_eq((a["w"] as SimWorld).rng.get_state(), (b["w"] as SimWorld).rng.get_state(), "same RNG state")
	assert_eq((a["w"] as SimWorld).debug == null, (b["w"] as SimWorld).debug == null, "the cue creates no SimDebug state of its own")


# ======================================================================= gate: God / dev code only, not a setting

func test_only_god_and_dev_code_knows_the_cue() -> void:
	var hits: Array[String] = K.scripts_mentioning(["bitecue", "peek_bite_target"])
	var allowed: PackedStringArray = ["res://scripts/sim/sim_world.gd", "res://scripts/world/dev_overlays.gd"]
	var strays: Array[String] = []
	for path: String in hits:
		if not allowed.has(path) and not path.get_file().begins_with("god_"):
			strays.append(path)
	assert_eq(strays.size(), 0, "no HUD / input / settings / audio / world renderer code mentions the cue: %s" % [strays])
	assert_has(hits, "res://scripts/world/dev_overlays.gd", "the overlay is implemented in dev_overlays.gd")
	assert_has(hits, "res://scripts/sim/sim_world.gd", "the query lives in sim_world.gd")


func test_the_cue_is_not_a_setting_a_rule_or_a_tuning_row() -> void:
	var settings: String = FileAccess.get_file_as_string("res://scripts/ui/game_settings.gd").to_lower()
	for needle: String in ["bitecue", "bite_cue", "can_bite"]:
		assert_false(settings.contains(needle), "GameSettings has no '%s'" % needle)
	for needle: String in ["bitecue", "bite_cue", "peek_bite"]:
		assert_eq(K.files_containing(ProjectSettings.globalize_path("res://data"), needle).size(), 0, "game/data has no '%s' (not data, not a rule, not a tuning row)" % needle)


func test_the_sim_query_is_not_called_by_the_sim_itself() -> void:
	# "with the cue off nothing runs": the only caller of peek_bite_target is the overlay (and tests / God code), never a sim phase
	var calls: int = 0
	for line: String in FileAccess.get_file_as_string("res://scripts/sim/sim_world.gd").split("\n"):
		var t: String = line.strip_edges()
		if t.contains("peek_bite_target") and not t.begins_with("func ") and not t.begins_with("#"):
			calls += 1
	assert_eq(calls, 0, "sim_world.gd only DEFINES the query (comments aside), no sim phase calls it")


# ======================================================================= captures

func _godscript_files() -> Array[String]:
	var out: Array[String] = []
	var dir: String = K.repo_root().path_join("tools/capture")
	var d: DirAccess = DirAccess.open(dir)
	if d != null:
		for f: String in d.get_files():
			if f.get_extension() == "godscript":
				out.append(dir.path_join(f))
	return out


func test_the_ab_capture_script_parses_and_toggles_the_cue() -> void:
	var files: Array[String] = _godscript_files()
	assert_false(files.is_empty(), "a *.godscript with the A/B capture exists below tools/capture/ (tools/capture/bitecue_ab.godscript)")
	var found: bool = false
	for path: String in files:
		var text: String = FileAccess.get_file_as_string(path)
		if not text.contains("bitecue"):
			continue
		found = true
		var steps: Array[Dictionary] = GodScript.parse(text)
		assert_eq(GodScript.errors(steps), PackedStringArray(), "%s parses" % path.get_file())
		assert_eq(GodScript.unknown_commands(steps, _cmds), PackedStringArray(), "%s only uses registered commands" % path.get_file())
		var shots: int = 0
		var on_at: int = -1
		var off_at: int = -1
		var first_shot: int = -1
		var last_shot: int = -1
		for i in steps.size():
			var s: Dictionary = steps[i]
			if s["op"] == "shot":
				shots += 1
				if first_shot < 0:
					first_shot = i
				last_shot = i
			elif s["op"] == "cmd":
				var line: String = String(s["arg"]).strip_edges().to_lower()
				if line == "overlay bitecue on" and on_at < 0:
					on_at = i
				elif line == "overlay bitecue off" and off_at < 0:
					off_at = i
		assert_true(shots >= 2, "at least one shot with the cue off and one with it on (%d shots)" % shots)
		assert_true(on_at >= 0, "turns the cue on explicitly")
		assert_true(first_shot >= 0 and last_shot > first_shot, "shots before and after the toggle")
		assert_true((on_at > first_shot) or (off_at > first_shot and on_at >= 0), "A and B frames are separated by the toggle")
	assert_true(found, "one of the scripts is the bitecue A/B capture")
