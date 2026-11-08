extends RefCounted
## Shared kit for the T1.3 tuning lab tests (res://tests/tuning_support.gd). Not a test file: the runner only collects
## scripts named test_*.gd. Use via `const TS := preload("res://tests/tuning_support.gd")`. No class_name.
##
## What the tests assume (the Director-visible contract, NOT private implementation names):
##  - registry file `res://data/god/tuning.json`: entries with id / target ("rules" | "band") / path / label / group /
##    min / max / step (the list may be the top-level array or sit under any array-valued key).
##  - console commands registered by `GodSimCommands.register_all`: `tune list | <id> <value> | reset [id] | save <name> |
##    load <name> | export <name>`; they act on `ctx.world` only (the live override state lives on the world via SimDebug).
##  - a `band` entry given through `tune <id> <value>` applies to EVERY band.
##  - presets: JSON `{version, overrides: {id: value}}` in a preset dir, export in an export dir.
##
## NAME TABLE (adapt here only if the implementation names differ): the pieces the tests could not know are
## the registry validator (static function on the overrides class) and the two injectable base directories. Every other
## test goes through the console commands, the registry FILE and the sim itself.
##
## Pre-change baselines (BASELINE_*): captured on the code BEFORE T1.3 (Godot 4.7.2, macOS arm64), see the test plan.

const G := preload("res://tests/god_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const SS := preload("res://tests/species_stats_support.gd")

const REGISTRY_PATH: String = "res://data/god/tuning.json"
const TMP_ROOT: String = "user://test_tuning_tmp"
const PRESET_DIR: String = "user://test_tuning_tmp/a/b/presets"
const EXPORT_DIR: String = "user://test_tuning_tmp/a/b/export"
const SEED: int = 31

# ----------------------------------------------------------------------------------------------- NAME TABLE
const OVERRIDES_SCRIPT: String = "res://scripts/sim/tuning_overrides.gd"
const PANEL_SCRIPT: String = "res://scripts/ui/tuning_panel.gd"
## Static validators tried in order; first argument = registry entries (wrapped like the shipped file when the
## parameter is named like a document), further parameters are filled by name (content / db, rules, bands).
const VALIDATE_METHODS: Array[String] = ["validate_registry", "validate_entries", "validate_records", "validate"]
## Scripts searched for the injectable (static) base directories, and the property names tried on them.
const INJECTION_SCRIPTS: Array[String] = [
	"res://scripts/sim/tuning_overrides.gd", "res://scripts/sim/sim_debug.gd", "res://scripts/ui/god_sim_commands.gd",
	"res://scripts/ui/tuning_panel.gd",
]
const PRESET_DIR_PROPS: Array[String] = ["preset_dir", "presets_dir", "preset_base_dir", "presets_root", "preset_root", "user_dir"]
const EXPORT_DIR_PROPS: Array[String] = ["export_dir", "export_base_dir", "exports_dir", "export_root", "reports_dir"]
## Names of the preset document keys.
const PRESET_VERSION_KEY: String = "version"
const PRESET_OVERRIDES_KEY: String = "overrides"

## state_hash of the scenarios below on the PRE-change code with an empty override layer.
const BASELINE_HASHES: Dictionary = {
	"bite_composite": 3915345708885060081,
	"held_bites": 8955536270428909148,
	"held_misses": 6105107178846075110,
	"press_enter_6": -7763946577586211378,
	"press_enter_9": -572225517048518415,
}

static var _saved_dirs: Array = []  # [[script, prop, old value]]


# ======================================================================= registry file

## Parsed registry document (null when the file is missing / malformed).
static func registry_doc() -> Variant:
	if not FileAccess.file_exists(REGISTRY_PATH):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))


## Key that holds the entry list ("" = the document IS the list). "?" = not found.
static func entries_key(doc: Variant) -> String:
	if doc is Array:
		return ""
	if doc is Dictionary:
		for k: Variant in (doc as Dictionary).keys():
			var v: Variant = (doc as Dictionary)[k]
			if v is Array and not (v as Array).is_empty() and (v as Array)[0] is Dictionary and ((v as Array)[0] as Dictionary).has("id"):
				return String(k)
	return "?"


## The shipped entries as dictionaries (empty when the file is missing).
static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var doc: Variant = registry_doc()
	var key: String = entries_key(doc)
	var list: Variant = doc if key == "" else (doc[key] if key != "?" else null)
	if list is Array:
		for item: Variant in (list as Array):
			if item is Dictionary:
				out.append((item as Dictionary).duplicate(true))
	return out


## The shipped entries as a plain (untyped) Array of dictionaries, safe to append foreign rows to.
static func entries_raw() -> Array:
	var out: Array = []
	for e: Dictionary in entries():
		out.append(e)
	return out


## A document shaped like the shipped file but holding `list`.
static func wrap_like_shipped(list: Array) -> Variant:
	var doc: Variant = registry_doc()
	var key: String = entries_key(doc)
	if key == "" or key == "?" or not (doc is Dictionary):
		return list
	var copy: Dictionary = (doc as Dictionary).duplicate(true)
	copy[key] = list
	return copy


static func entry_for(target: String, path: String) -> Dictionary:
	for e: Dictionary in entries():
		if str(e.get("target", "")) == target and str(e.get("path", "")) == path:
			return e
	return {}


## Registry id of the (target, path) entry, "" when the registry has no such row.
static func id_for(target: String, path: String) -> String:
	return str(entry_for(target, path).get("id", ""))


static func has_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## Value of a dotted rules path in a ContentDB (null when absent).
static func rule_value(db: ContentDB, path: String) -> Variant:
	return S3.rule(db, path)


## Data value an entry points at: the rule, or band 1's field for band entries.
static func data_value(entry: Dictionary, db: ContentDB) -> Variant:
	if str(entry.get("target", "")) == "band":
		return db.get_band(1).get(str(entry.get("path", "")))
	return rule_value(db, str(entry.get("path", "")))


## A valid, clearly different value for `entry`: halfway between the data value and the farther range end, on the step grid.
static func alt_value(entry: Dictionary, db: ContentDB) -> float:
	var lo: float = float(entry.get("min", 0.0))
	var hi: float = float(entry.get("max", 1.0))
	var step: float = float(entry.get("step", 0.0))
	var cur_v: Variant = data_value(entry, db)
	var cur: float = float(cur_v) if has_num(cur_v) else lo
	var far: float = hi if absf(hi - cur) >= absf(cur - lo) else lo
	var v: float = (cur + far) * 0.5
	if step > 0.0:
		v = lo + snappedf(v - lo, step)
	v = snappedf(clampf(v, lo, hi), 0.000001)
	if absf(v - cur) < 1e-9:
		v = snappedf(far, 0.000001)
	return v


## Console text for a float (no scientific notation, trimmed).
static func fmt(v: float) -> String:
	return String.num(v, 6)


# ======================================================================= commands and worlds

static func commands() -> GodCommands:
	var cmds: GodCommands = GodCommands.with_builtins()
	GodSimCommands.register_all(cmds)
	return cmds


## Runs one console line against `w` (context without a host); returns the answer.
static func tune(cmds: GodCommands, w: SimWorld, player_id: int, line: String) -> String:
	return cmds.execute(line, G.context(w, player_id))


## Every `lines` entry executed in order (the answers are returned).
static func tune_all(cmds: GodCommands, w: SimWorld, player_id: int, lines: Array) -> Array[String]:
	var out: Array[String] = []
	for l: Variant in lines:
		out.append(tune(cmds, w, player_id, str(l)))
	return out


## SHA-256 of the event log slice `evs` (type, tick, ids) appended to the entity state: bites show up even when the victim is
## refilled every tick.
static func trace_with(w: SimWorld, evs: Array[SimEvent]) -> String:
	var parts: PackedStringArray = [trace(w)]
	for ev: SimEvent in evs:
		parts.append("%d,%d,%d,%d,%.6f" % [ev.type, ev.tick, ev.entity_id, ev.other_id, ev.value])
	return "\n".join(parts).sha256_text()


## Per-entity numeric state of `w` as a SHA-256 hex (excludes state_hash on purpose: whether the override set enters the
## hash is the implementation's documented choice, the trajectory must not depend on it).
static func trace(w: SimWorld) -> String:
	var parts: PackedStringArray = []
	parts.append("tick=%d" % w.tick)
	for id: int in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		parts.append("%d|%s|%s|%s|%s|%.9f|%.9f|%.9f|%d|%.9f|%.9f|%d|%d|%d" % [e.id, e.species_id,
			var_to_str(e.position), var_to_str(e.velocity), var_to_str(e.heading), e.hp, e.xp, e.hunger, e.band, e.speed,
			e.length_m, int(e.alive), e.bite_ready_tick, e.last_bite_target])
	return "\n".join(parts).sha256_text()


# ======================================================================= bite scenarios (S3 controlled world)

static func player(w: SimWorld, length_m: float = 0.5) -> SimEntity:
	return S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


static func at(e: SimEntity, dist: float, deg: float = 0.0) -> Vector3:
	return e.position + e.heading.rotated(Vector3.UP, deg_to_rad(deg)) * dist


## Durable passive victim (6x the player length) at `pos`.
static func victim(w: SimWorld, p: SimEntity, pos: Vector3) -> SimEntity:
	return S3.npc_at(w, &"small_reef_fish", pos, p.length_m * 6.0, -p.heading)


static func bites_by(evs: Array[SimEvent], biter: int, victim_id: int = -1) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == biter and (victim_id < 0 or ev.entity_id == victim_id):
			out.append(ev)
	return out


static func misses_of(evs: Array[SimEvent], id: int) -> int:
	var n: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITE_MISSED and ev.entity_id == id:
			n += 1
	return n


## {"w", "p", "v", "cmds"}: player 0.5 m, durable victim pinned by the caller. `lines` are console lines run at tick 0.
static func bite_rig(opts: Dictionary, lines: Array, victim_pos_fn: Callable = Callable()) -> Dictionary:
	var w: SimWorld = S3.make_world(SEED, opts)
	var p: SimEntity = player(w)
	var v: SimEntity = null
	if victim_pos_fn.is_valid():
		v = victim(w, p, victim_pos_fn.call(w, p))
	var cmds: GodCommands = commands()
	tune_all(cmds, w, p.id, lines)
	return {"w": w, "p": p, "v": v, "cmds": cmds}


## Rig for composite(): victim starts in front of the player.
static func composite_rig(opts: Dictionary, lines: Array) -> Dictionary:
	return bite_rig(opts, lines, func(_w: SimWorld, p: SimEntity) -> Vector3: return at(p, p.length_m * 0.3))


## Held bite (one BITE per tick) for `ticks` ticks while a durable victim is pinned on a sweep (distance 0.3..3.0 player
## lengths, angle 0..100 deg), on an existing composite_rig `rg`. Returns {"trace", "hash", "bites", "misses"}.
static func composite_run(rg: Dictionary, ticks: int = 240) -> Dictionary:
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var v: SimEntity = rg["v"]
	var evs: Array[SimEvent] = []
	for i in ticks:
		var d: float = p.length_m * (0.3 + 2.7 * (0.5 + 0.5 * sin(float(i) * 0.07)))
		var a: float = 100.0 * (0.5 + 0.5 * sin(float(i) * 0.045 + 1.0))
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: at(p, d + w.collision_radius(v), a)}, [v.id]))
	return {"trace": trace_with(w, evs), "hash": w.state_hash(), "bites": bites_by(evs, p.id).size(), "misses": misses_of(evs, p.id)}


## composite_run on a fresh rig (`lines` = console lines run at tick 0).
static func composite(opts: Dictionary, lines: Array, ticks: int = 240) -> Dictionary:
	return composite_run(composite_rig(opts, lines), ticks)


## Held bite at a victim that stays inside the cone: bite ticks. Returns {"trace", "hash", "ticks": Array[int]}.
static func held_bites(opts: Dictionary, lines: Array, n: int = 150) -> Dictionary:
	var rg: Dictionary = bite_rig(opts, lines, func(w: SimWorld, p: SimEntity) -> Vector3: return at(p, p.length_m * 0.4))
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var v: SimEntity = rg["v"]
	var evs: Array[SimEvent] = []
	for i in n:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: v.position}, [v.id]))
	var ticks: Array[int] = []
	for ev: SimEvent in bites_by(evs, p.id, v.id):
		ticks.append(ev.tick)
	return {"trace": trace_with(w, evs), "hash": w.state_hash(), "ticks": ticks}


## Held bite in empty water: BITE_MISSED count. Returns {"trace", "hash", "misses"}.
static func held_misses(opts: Dictionary, lines: Array, n: int = 150) -> Dictionary:
	var rg: Dictionary = bite_rig(opts, lines)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var evs: Array[SimEvent] = []
	for i in n:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1))
	return {"trace": trace_with(w, evs), "hash": w.state_hash(), "misses": misses_of(evs, p.id)}


## ONE bite press while the victim is outside the cone for `k` ticks, then inside for 3. Returns {"trace", "hash", "bites"}.
static func press_then_enter(opts: Dictionary, lines: Array, k: int) -> Dictionary:
	var outside_fn: Callable = func(w: SimWorld, p: SimEntity) -> Vector3:
		return at(p, p.length_m * S3.rule_f(w.content, "bite_reach_mult") * 0.5, S3.bite_half_cone_deg(w) + 30.0)
	var rg: Dictionary = bite_rig(opts, lines, outside_fn)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var v: SimEntity = rg["v"]
	var outside: Vector3 = v.position
	var inside: Vector3 = at(p, p.length_m * S3.rule_f(w.content, "bite_reach_mult") * 0.5)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, k, {v.id: outside})
	evs.append_array(S3.step_n(w, 3, {v.id: inside}))
	return {"trace": trace_with(w, evs), "hash": w.state_hash(), "bites": bites_by(evs, p.id, v.id).size()}


## One bite at a victim pinned at centre distance `dist_len` player lengths (+ its radius) and `deg` off the heading,
## `tune_after` console lines run after `warm` idle ticks. Returns bites landed in the 2 ticks after the press.
static func one_bite_at(opts: Dictionary, lines_at_start: Array, dist_len: float, deg: float, warm: int = 0, lines_after_warm: Array = []) -> int:
	var rg: Dictionary = bite_rig(opts, lines_at_start, func(w: SimWorld, p: SimEntity) -> Vector3: return p.position + Vector3(0, 0, 10))
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var v: SimEntity = rg["v"]
	var pos: Vector3 = at(p, w.collision_radius(v) + p.length_m * dist_len, deg)
	if warm > 0:
		S3.step_n(w, warm, {v.id: pos})
		tune_all(rg["cmds"], w, p.id, lines_after_warm)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 2, {v.id: pos})
	return bites_by(evs, p.id, v.id).size()


# ======================================================================= movement scenarios (S2 lane)

## ContentDB whose band table has `field` set to `value` in every band.
static func db_with_band(field: String, value: float) -> ContentDB:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for i in range(1, db.band_count() + 1):
		db.get_band(i)[field] = value
	return db


## Scripted player (cruise / boost / brake) for 400 ticks in band `band_index` on the S2 lane; `lines` run at tick 0
## after the spawn (so the sim has already cached the band table). Returns {"trace", "hash", "w"}.
static func lane_run(db: ContentDB, band_index: int, lines: Array = []) -> Dictionary:
	var w: SimWorld = SS.lane_world(db, band_index, 3)
	var e: SimEntity = SS.lane_player(w)
	tune_all(commands(), w, e.id, lines)
	S2.submit_segments(w, e.id, S2.movement_script(2000 + band_index, 400, true, true), true)
	S2.run(w, 400)
	return {"trace": trace(w), "hash": w.state_hash(), "w": w}


## Speed after `ticks` ticks of coasting (thrust 0) from `v0` m/s along +X; `lines` run at tick 0.
static func coast_speed(db: ContentDB, band_index: int, v0: float, ticks: int, lines: Array = []) -> float:
	var w: SimWorld = SS.lane_world(db, band_index, 3)
	var e: SimEntity = SS.lane_player(w)
	tune_all(commands(), w, e.id, lines)
	e.velocity = Vector3.RIGHT * v0
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 0.0))
	for i in ticks:
		w.step()
	return e.velocity.length()


## Per-tick heading change (rad) of a lane player steering `turn_deg` away from +X; `lines` run after tick `warm`.
## Returns the angle turned in each of the ticks `warm`.. `warm + 2` as Array[float] (3 deltas).
static func turn_deltas(db: ContentDB, band_index: int, turn_deg: float, warm: int, lines: Array) -> Array[float]:
	var w: SimWorld = SS.lane_world(db, band_index, 3)
	var e: SimEntity = SS.lane_player(w)
	var dir: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(turn_deg))
	w.submit(SimCommand.move(e.id, dir, 0.0))
	for i in warm:
		w.step()
	tune_all(commands(), w, e.id, lines)
	var out: Array[float] = []
	for i in 3:
		var before: Vector3 = e.heading
		w.step()
		out.append(before.angle_to(e.heading))
	return out


# ======================================================================= temp dirs and injection

static func remove_dir(path: String) -> void:
	G.remove_dir(path)


## Fresh empty temp tree (preset and export dirs exist).
static func fresh_tmp() -> void:
	remove_dir(TMP_ROOT)
	DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	DirAccess.make_dir_recursive_absolute(EXPORT_DIR)


static func cleanup_tmp() -> void:
	remove_dir(TMP_ROOT)


static func _inject(props: Array[String], value: String) -> bool:
	for path: String in INJECTION_SCRIPTS:
		if not ResourceLoader.exists(path):
			continue
		var s: Script = load(path)
		for prop: String in props:
			if typeof(s.get(prop)) == TYPE_STRING:
				_saved_dirs.append([s, prop, s.get(prop)])
				s.set(prop, value)
				return true
	return false


## Points the implementation's preset / export base directories at the temp tree. Returns "" on success, else why not.
static func inject_dirs() -> String:
	fresh_tmp()
	var missing: Array[String] = []
	if not _inject(PRESET_DIR_PROPS, PRESET_DIR):
		missing.append("preset dir (static String var named one of %s)" % [PRESET_DIR_PROPS])
	if not _inject(EXPORT_DIR_PROPS, EXPORT_DIR):
		missing.append("export dir (static String var named one of %s)" % [EXPORT_DIR_PROPS])
	if not missing.is_empty():
		restore_dirs()
		return "no injection point for " + ", ".join(missing) + ": spec requires injectable base paths (adapt TS.PRESET_DIR_PROPS / EXPORT_DIR_PROPS)"
	return ""


static func restore_dirs() -> void:
	for rec: Array in _saved_dirs:
		(rec[0] as Script).set(rec[1], rec[2])
	_saved_dirs.clear()


## Files (res-relative names) below `root`, recursive.
static func files_below(root: String) -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(root)
	if d == null:
		return out
	for sub: String in d.get_directories():
		for f: String in files_below(root.path_join(sub)):
			out.append(sub.path_join(f))
	for f: String in d.get_files():
		out.append(f)
	return out


static func preset_file(name: String) -> String:
	return PRESET_DIR.path_join(name + ".json")


static func export_file(name: String) -> String:
	return EXPORT_DIR.path_join(name + ".json")


static func write_preset(name: String, doc: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	G.write_json(preset_file(name), doc)


# ======================================================================= registry validation adapter

## Runs the implementation's registry validator on `list` (Array of entry dictionaries). Returns
## {"found": bool, "errors": Array[String], "ok": bool}; `found` false = no validator under the NAME TABLE names.
static func validate(list: Array) -> Dictionary:
	var out: Dictionary = {"found": false, "errors": [], "ok": true, "method": ""}
	if not ResourceLoader.exists(OVERRIDES_SCRIPT):
		return out
	var s: Script = load(OVERRIDES_SCRIPT)
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for name: String in VALIDATE_METHODS:
		var info: Dictionary = {}
		for m: Dictionary in s.get_script_method_list():
			if m["name"] == name:
				info = m
		if info.is_empty():
			continue
		var args: Array = []
		var params: Array = info["args"]
		for i in params.size():
			var pn: String = String(params[i]["name"]).to_lower()
			if i == 0:
				args.append(wrap_like_shipped(list) if pn in ["doc", "document", "registry", "data", "json", "root", "file"] else list)
			elif pn in ["content", "db", "content_db", "data"]:
				args.append(db)
			elif pn.contains("rules"):
				args.append(db.rules())
			elif pn.contains("band"):
				args.append(db.get_band(1))
			else:
				args.append(null)
		var res: Variant = s.callv(name, args)
		out["found"] = true
		out["method"] = name
		out["errors"] = errors_of(res)
		out["ok"] = (out["errors"] as Array).is_empty() and not (res is bool and not bool(res))
		return out
	return out


## Normalises a validator result to a list of error strings (empty = ok).
static func errors_of(res: Variant) -> Array[String]:
	var errs: Array[String] = []
	if res is Array or res is PackedStringArray:
		for item: Variant in res:
			errs.append(str(item))
	elif res is String and not (res as String).is_empty():
		errs.append(res)
	elif res is Dictionary and (res as Dictionary).has("errors"):
		return errors_of((res as Dictionary)["errors"])
	elif res is Object and "errors" in res:
		return errors_of(res.get("errors"))
	return errs


# ======================================================================= scene-tree helpers (UI tests)

static func find_all(root: Node, type_name: String) -> Array[Node]:
	var out: Array[Node] = []
	if root.is_class(type_name):
		out.append(root)
	for c: Node in root.get_children():
		out.append_array(find_all(c, type_name))
	return out


static func all_text(root: Node) -> String:
	var parts: PackedStringArray = []
	if root is Label:
		parts.append((root as Label).text)
	if root is Button:
		parts.append((root as Button).text)
	for c: Node in root.get_children():
		parts.append(all_text(c))
	return "\n".join(parts)
