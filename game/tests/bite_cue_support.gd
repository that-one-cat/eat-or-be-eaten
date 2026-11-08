extends RefCounted
## Shared kit for the T1.11 "can bite" cue tests (res://tests/bite_cue_support.gd). Not a test file: the runner only collects
## scripts named test_*.gd. Use via `const K := preload("res://tests/bite_cue_support.gd")`. No class_name.
##
## What the tests assume (the contract in tasks/demo-t1-11-bite-cue.md, NOT private implementation names):
##  - `SimWorld.peek_bite_target(player_id: int) -> int` (entity id or -1) is public and READ-ONLY. It applies the selection of
##    a real player bite press without a target (strict cone; aim assist through the global strength, the control mode or the
##    remembered lock; swallowable / inactive creatures skipped; food sites ignored) and is independent of the bite cooldown.
##    It is called through `w.call(...)` so the test files load before the method exists; a missing method answers MISSING (-2),
##    which never equals a valid answer (-1 = "no target"), and every test asserts `has_peek` first.
##  - Overlay name `bitecue` in DevOverlays (console `overlay bitecue [on|off]`, `overlay list`, quick button
##    `overlay bitecue`). On = exactly ONE new node below the DevOverlays node (a pooled marker, no children of its own), visible
##    only while a target is peeked, placed at the target (within its collision radius + MARKER_TOL_M), updated each frame. Off =
##    that node is gone (freed within two frames); nothing is created before the first `on`.
##
## Geometry (shipped data, AS.opts(0.0) = explicit aim keys with the strength at 0): player 0.5 m heading +X, bite reach
## 1.5 x length = 0.75 m, strict half-cone 60 deg, victim = 6 x player length = 3.0 m (never swallowed), collision radius 0.75 m,
## so a victim centre is in strict reach up to 0.75 + 0.75 = 1.5 m. With strength 1 the cone is 60 + 90 = 150 deg.

const TS := preload("res://tests/tuning_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const CM := preload("res://tests/control_modes_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const PEEK_METHOD: StringName = &"peek_bite_target"
const OVERLAY_NAME: String = "bitecue"
const MISSING: int = -2
## How far the marker centre may be from the target centre (on top of the target collision radius).
const MARKER_TOL_M: float = 0.5
## Assist configurations: "off" = strength 0, "tune" = `tune aim_assist_strength 1` (global), "assisted" = the control mode.
const MODES: Array[String] = ["off", "tune", "assisted"]

## Victims as [distance_m, deg_off_heading]; all are 6 x player length (durable, never swallowable).
const GEOMETRIES: Array[Dictionary] = [
	{"name": "ahead", "v": [[0.9, 0.0]]},
	{"name": "crossing_outside", "v": [[0.9, 75.0]]},
	{"name": "mirror_outside", "v": [[0.9, -75.0]]},
	{"name": "empty", "v": []},
	{"name": "out_of_reach", "v": [[6.0, 0.0]]},
	{"name": "behind", "v": [[0.9, 180.0]]},
	{"name": "two_swap", "v": [[0.9, 75.0], [1.3, 20.0]]},
	{"name": "crowd3", "v": [[1.0, -70.0], [1.2, 30.0], [0.8, 100.0]]},
	{"name": "stacked", "v": [[0.9, 75.0], [0.9, 75.0]]},
]
## Victim index that `off` and `tune` (strength 1, cone 90, cap 1000, stickiness 0.5, no lock) must answer, -1 = no target.
## Derived from the T1.5 score: d / reach + strength x angle / PI (see sim_world.gd `_assisted_bite_target`).
const EXPECT: Dictionary = {
	"ahead": [0, 0], "crossing_outside": [-1, 0], "mirror_outside": [-1, 0], "empty": [-1, -1], "out_of_reach": [-1, -1],
	"behind": [-1, -1], "two_swap": [1, 0], "crowd3": [1, 2], "stacked": [-1, 0],
}


# ======================================================================= the query

static func has_peek(w: SimWorld) -> bool:
	return w.has_method(PEEK_METHOD)


## The peek answer, MISSING (-2) while the method does not exist.
static func peek(w: SimWorld, player_id: int) -> int:
	if not has_peek(w):
		return MISSING
	return int(w.call(PEEK_METHOD, player_id))


## Fails `tc` (once) when the method is missing; true when the test may go on.
static func require(tc: TestCase, w: SimWorld) -> bool:
	if has_peek(w):
		return true
	tc.fail("SimWorld.peek_bite_target(player_id) does not exist yet")
	return false


## Everything a read-only query must leave alone, as one string: tick, RNG state, event log size, the player's bite / lock
## memory and the per-entity trace.
static func snapshot(w: SimWorld, p: SimEntity) -> String:
	return "%d|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d" % [w.tick, w.rng.get_state(), w.events_since(0).size(), TS.trace(w), p.aim_lock_target,
		p.aim_lock_until_tick, p.bite_request, p.bite_until_tick, p.bite_ready_tick, p.bite_miss_ready_tick, p.last_bite_target]


## `n` peeks in a row. Returns {"answer","stable" (all answers equal),"same_state" (snapshot unchanged),"same_hash","no_debug"}.
static func hammer(w: SimWorld, player_id: int, n: int = 300) -> Dictionary:
	var p: SimEntity = w.get_entity(player_id)
	var snap: String = snapshot(w, p)
	var h: int = w.state_hash()
	var dbg: Object = w.debug  # a `tune` line creates the debug layer itself: the peek must neither create nor replace it
	var first: int = peek(w, player_id)
	var stable: bool = true
	for i in n:
		if peek(w, player_id) != first:
			stable = false
	return {"answer": first, "stable": stable, "same_state": snapshot(w, p) == snap, "same_hash": w.state_hash() == h, "no_debug": w.debug == dbg}


# ======================================================================= controlled rigs

## {"w","p","vs" (victims in geometry order),"pins","keep"}: brains-off arena, the geometry's victims pinned, the assist `mode`
## configured and one idle tick done (so a control-mode command is certainly active).
static func build(geom: Dictionary, mode: String) -> Dictionary:
	var w: SimWorld = AS.world(AS.opts(0.0))
	var p: SimEntity = TS.player(w)
	var vs: Array[SimEntity] = []
	var pins: Dictionary = {}
	var keep: Array[int] = [p.id]
	for d: Variant in (geom["v"] as Array):
		var pos: Vector3 = TS.at(p, float((d as Array)[0]), float((d as Array)[1]))
		var v: SimEntity = TS.victim(w, p, pos)
		vs.append(v)
		pins[v.id] = pos
		keep.append(v.id)
	if mode == "tune":
		TS.tune_all(TS.commands(), w, p.id, [AS.tune_line(AS.KEY_STRENGTH, 1.0)])
	elif mode == "assisted":
		var cmd: SimCommand = CM.make_set(p.id, "assisted")
		if cmd != null:
			w.submit(cmd)
	S3.step_n(w, 1, pins, keep)
	return {"w": w, "p": p, "vs": vs, "pins": pins, "keep": keep}


## Index of entity `id` in the rig's victims, -1 when it is none of them.
static func index_of(rg: Dictionary, id: int) -> int:
	var vs: Array = rg["vs"]
	for i in vs.size():
		if (vs[i] as SimEntity).id == id:
			return i
	return -1


## One held-off real bite press (a single `bite -1`) and two ticks. Returns {"ids" (victims bitten by the player),"misses","trace","hash"}.
static func press(rg: Dictionary) -> Dictionary:
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 2, rg["pins"], rg["keep"])
	return {"ids": AS.landed_ids(evs, p.id), "misses": TS.misses_of(evs, p.id), "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


# ======================================================================= moving scenarios (twin runs: peeks = 0 is the control)

static func _cross_pos(p: SimEntity, i: int) -> Vector3:
	return p.position + p.heading * 0.3 + AS.side_of(p) * (1.0 - 0.05 * float(i))


## The AS.crossing geometry with a HELD bite (one press every tick) and `peeks` peeks before every step. `o` = make_world opts,
## `lines` = console lines at tick 0, `mode_id` ("" = none) = control mode command. Returns {"first_peek_tick","first_peek_id",
## "first_bite_tick","first_bite_id","landed","mismatch" (landed bites whose victim differs from the peek taken just before),
## "v","w","p","trace","hash","peeks_total"}. first_* = -1 when it never happened.
static func crossing_held(o: Dictionary, lines: Array, mode_id: String, peeks: int, ticks: int = 24) -> Dictionary:
	var w: SimWorld = AS.world(o)
	var p: SimEntity = TS.player(w)
	var v: SimEntity = TS.victim(w, p, p.position + Vector3(0, 0, 10))
	TS.tune_all(TS.commands(), w, p.id, lines)
	if mode_id != "":
		w.submit(CM.make_set(p.id, mode_id))
	var evs: Array[SimEvent] = S3.step_n(w, 1, {v.id: _cross_pos(p, 0)}, [v.id, p.id])
	var out: Dictionary = {"first_peek_tick": -1, "first_peek_id": -1, "first_bite_tick": -1, "first_bite_id": -1, "landed": 0,
		"mismatch": 0, "peeks_total": 0, "w": w, "p": p, "v": v}
	for i in ticks:
		var pos: Vector3 = _cross_pos(p, i)
		v.position = pos
		v.velocity = Vector3.ZERO
		var pk: int = -1
		for k in peeks:
			pk = peek(w, p.id)
			out["peeks_total"] = int(out["peeks_total"]) + 1
		if peeks > 0 and pk >= 0 and int(out["first_peek_tick"]) < 0:
			out["first_peek_tick"] = i
			out["first_peek_id"] = pk
		w.submit(SimCommand.bite(p.id, -1))
		var got: Array[SimEvent] = S3.step_n(w, 1, {v.id: pos}, [v.id, p.id])
		evs.append_array(got)
		for vid: int in AS.landed_ids(got, p.id):
			out["landed"] = int(out["landed"]) + 1
			if int(out["first_bite_tick"]) < 0:
				out["first_bite_tick"] = i
				out["first_bite_id"] = vid
			if peeks > 0 and pk != vid:
				out["mismatch"] = int(out["mismatch"]) + 1
	out["trace"] = TS.trace_with(w, evs)
	out["hash"] = w.state_hash()
	return out


## The AS.sticky geometry (mirrored victims at +-75 deg, the NOT bitten one moves nearer after every bite) with the aim rules
## strength 1 and stickiness `sticky`, held bite, `peeks` peeks before every step. Returns {"ids","landed","mismatch","trace","hash"}.
static func sticky_run(sticky: float, peeks: int, ticks: int = 150, delta: float = 0.05) -> Dictionary:
	var w: SimWorld = AS.world(AS.opts(1.0, {AS.KEY_STICKY: sticky}))
	var p: SimEntity = TS.player(w)
	var a: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 75.0))
	var b: SimEntity = TS.victim(w, p, TS.at(p, 0.9, -75.0))
	var nearer: SimEntity = a
	var evs: Array[SimEvent] = []
	var mismatch: int = 0
	var landed: int = 0
	var ids: Array[int] = []
	for i in ticks:
		var pa: Vector3 = TS.at(p, 0.9 - (delta if nearer == a else 0.0), 75.0)
		var pb: Vector3 = TS.at(p, 0.9 - (delta if nearer == b else 0.0), -75.0)
		a.position = pa
		b.position = pb
		var pk: int = -3
		for k in peeks:
			pk = peek(w, p.id)
		w.submit(SimCommand.bite(p.id, -1))
		var got: Array[SimEvent] = S3.step_n(w, 1, {a.id: pa, b.id: pb}, [a.id, b.id, p.id])
		evs.append_array(got)
		for vid: int in AS.landed_ids(got, p.id):
			landed += 1
			ids.append(vid)
			if peeks > 0 and pk != vid:
				mismatch += 1
			nearer = b if vid == a.id else a
	return {"ids": ids, "landed": landed, "mismatch": mismatch, "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## AS.crowd (eight victims on a ring, the player turns 2 deg/tick, held bite, brains ON) with `peeks` peeks before every step.
## Same return shape as AS.crowd: {"w","p","evs","ids","trace","hash"}.
static func crowd_peeked(o: Dictionary, peeks: int, ticks: int = 300) -> Dictionary:
	var w: SimWorld = AS.world(o, true)
	var p: SimEntity = TS.player(w)
	var vs: Array[SimEntity] = []
	var keep: Array[int] = [p.id]
	for k in 8:
		var len_m: float = p.length_m * (3.0 + float(k % 4))
		var vk: SimEntity = S3.npc_at(w, &"small_reef_fish", p.position + Vector3(2.0, 0.0, 0.0), len_m, -p.heading)
		vs.append(vk)
		keep.append(vk.id)
	var evs: Array[SimEvent] = []
	for i in ticks:
		var pins: Dictionary = {}
		for k in 8:
			var ang: float = float(k) * 45.0 + 0.7 * float(i)
			var rad: float = 0.8 + 0.6 * float((k * 3) % 5) / 4.0
			pins[vs[k].id] = p.position + Vector3(rad, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(ang))
		for k in peeks:
			peek(w, p.id)
		var dir: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(2.0 * float(i)))
		w.submit(SimCommand.move(p.id, dir, 0.0))
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, pins, keep))
	return {"w": w, "p": p, "evs": evs, "ids": AS.landed_ids(evs, p.id), "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## AS.real_world_with_player_bites (shipped spawners + schools + scripted player + a bite every 45 ticks) with `peeks` peeks
## before every step. Returns {"trace","hash","player_bites"}.
static func real_world_peeked(o: Dictionary, peeks: int, world_seed: int = 4242, ticks: int = 900) -> Dictionary:
	var oo: Dictionary = o.duplicate(true)
	oo["real_spawners"] = true
	var w: SimWorld = S3.make_world(world_seed, oo)
	var id: int = w.spawn_player(0)
	S2.submit_segments(w, id, S2.movement_script(1001, ticks, true, true), true)
	var t: int = 40
	while t < ticks:
		w.submit(SimCommand.bite(id, -1, t))
		t += 45
	var evs: Array[SimEvent] = []
	for i in ticks:
		for k in peeks:
			peek(w, id)
		w.step()
		evs.append_array(w.events_since(w.tick - 1))
	return {"trace": TS.trace_with(w, evs), "hash": w.state_hash(), "player_bites": AS.bitten_by(evs, id).size()}


# ======================================================================= presentation helpers

## Number of nodes in the subtree of `root` (root included).
static func count_nodes(root: Node) -> int:
	var n: int = 1
	for c: Node in root.get_children():
		n += count_nodes(c)
	return n


## The marker node of a DevOverlays that has only the cue on: its only Node3D child (null when there is none).
static func marker_of(ov: DevOverlays) -> Node3D:
	var found: Node3D = null
	for c: Node in ov.get_children():
		if c is Node3D:
			found = c as Node3D
	return found


## Largest world-space extent of the marker (its own mesh / sprite box times its scale), -1 when it cannot be read.
static func extent_of(marker: Node3D) -> float:
	var g: GeometryInstance3D = marker as GeometryInstance3D
	if g == null:
		for c: Node in marker.get_children():
			if c is GeometryInstance3D:
				g = c as GeometryInstance3D
				break
	if g == null:
		return -1.0
	var box: AABB = g.get_aabb()
	var s: Vector3 = g.global_transform.basis.get_scale()
	return maxf(box.size.x * s.x, maxf(box.size.y * s.y, box.size.z * s.z))


## Alpha of the marker's colour when it is a plain StandardMaterial3D (material_override or surface 0), -1 when unreadable.
static func alpha_of(marker: Node3D) -> float:
	var g: GeometryInstance3D = marker as GeometryInstance3D
	if g == null:
		return -1.0
	var mat: Material = g.material_override
	if mat == null and g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
		mat = (g as MeshInstance3D).mesh.surface_get_material(0) if (g as MeshInstance3D).mesh.get_surface_count() > 0 else null
	if mat is StandardMaterial3D:
		var sm: StandardMaterial3D = mat as StandardMaterial3D
		if sm.vertex_color_use_as_albedo:
			return -1.0
		return sm.albedo_color.a * (1.0 - g.transparency)
	return -1.0


## Repo-relative .gd files below res://scripts that mention any of `tokens` (sorted).
static func scripts_mentioning(tokens: Array[String], dir: String = "res://scripts") -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	for sub: String in d.get_directories():
		out.append_array(scripts_mentioning(tokens, dir.path_join(sub)))
	for f: String in d.get_files():
		if f.get_extension() != "gd":
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		for t: String in tokens:
			if text.contains(t):
				out.append(dir.path_join(f))
				break
	out.sort()
	return out


## Absolute path of the repo root (the parent of the Godot project folder).
static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


## Files below `dir` (absolute, recursive) whose text contains `needle`.
static func files_containing(dir: String, needle: String) -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	for sub: String in d.get_directories():
		out.append_array(files_containing(dir.path_join(sub), needle))
	for f: String in d.get_files():
		var path: String = dir.path_join(f)
		if FileAccess.get_file_as_string(path).contains(needle):
			out.append(path)
	out.sort()
	return out
