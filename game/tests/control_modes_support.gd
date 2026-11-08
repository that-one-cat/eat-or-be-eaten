extends RefCounted
## Shared kit for the T1.4 control-mode tests (res://tests/control_modes_support.gd). Not a test file: the runner only
## collects scripts named test_*.gd. Use via `const CM := preload("res://tests/control_modes_support.gd")`. No class_name.
##
## What the tests assume (the contract in tasks/demo-t1-4-control-modes.md, NOT private implementation names):
##  - game/data/controls/modes.json: three records `classic` / `smoothed` / `assisted` (id, `name`, a description string,
##    `mouse_smooth_tau_s`, an optional aim turn cap in deg/s, `aim_assist_strength`, `lunge_strength`). The reader below
##    accepts a bare list, a list under any key, or an id -> record object.
##  - SimCommand.Type.SET_CONTROL_MODE is appended AFTER PICK_MUTATION; the payload is either an int index into the SORTED
##    mode ids or a stable id (the factory's argument type decides which one the kit sends).
##  - the sim keeps `control_mode` on the player entity; effective strengths for a PLAYER are max(global rule, mode value);
##    state_hash has bytes for the mode only while it is not `classic`; NPCs are unaffected.
##  - the pure smoothing step is a STATIC function (script under res://scripts/ whose file name contains "smooth", or a
##    static method of PlayerInput) taking (current dir: Vector3, target dir: Vector3, dt, tau[, cap deg/s]) and returning a
##    unit Vector3. The kit finds it by name / argument types (see `smoothing()`); adapt only this file if it is shaped
##    differently.
##  - PlayerInput learns the mode through GameSettings.apply_input(input) (the GameSettings property and the config key are
##    found by scanning, see `settings_prop()` / `cfg_key()`), and submits SET_CONTROL_MODE on change only (never for classic
##    at run start).
## Every lookup returns an "absent" value (null / "" / empty Dictionary) instead of raising, so a missing piece is a clean
## test failure, never a script error.
##
## Pre-change baselines (BASELINE_*): captured on the code BEFORE T1.4 (Godot 4.7.2, macOS arm64, branch feat/control-modes
## at d6ee47e), see the test plan. All of them are classic (no command, global strengths 0).

const G := preload("res://tests/god_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const LS := preload("res://tests/lunge_support.gd")

const MODES_PATH: String = "res://data/controls/modes.json"
const MODES_REL: String = "controls/modes.json"
const IDS: Array[String] = ["classic", "smoothed", "assisted"]
const KEY_TAU: String = "mouse_smooth_tau_s"
const KEY_AIM: String = "aim_assist_strength"
const KEY_LUNGE: String = "lunge_strength"
## Names tried for the optional aim turn cap (deg/s); a key containing "cap" is also accepted.
const CAP_KEYS: Array[String] = ["aim_turn_cap_deg_s", "mouse_turn_cap_deg_s", "turn_cap_deg_s", "aim_turn_rate_cap_deg_s",
	"aim_max_turn_deg_s", "max_turn_deg_s", "aim_turn_cap_deg_per_s"]
const DESC_KEYS: Array[String] = ["description", "desc", "summary", "blurb", "tooltip", "help"]
const SET_FACTORIES: Array[String] = ["set_control_mode", "control_mode", "set_mode"]
const SET_PAYLOAD_PROPS: Array[String] = ["mode_id", "control_mode", "mode", "mode_index", "mode_idx"]
const INPUT_MODE_METHODS: Array[String] = ["set_control_mode", "set_mode", "apply_control_mode"]
const INPUT_MODE_PROPS: Array[String] = ["control_mode", "mode_id", "mode"]

const SEED: int = 31
const SCRATCH_SETTINGS: String = "user://test_control_modes_settings.cfg"

## state_hash / trace of the classic scenarios on the PRE-change code (no command, global strengths 0).
const BASELINE_HASHES: Dictionary = {
	"crossing": 2794397896037733731,
	"lunge": 1228774801738535490,
	"swim": -497735685568051292,
	"bot": -9124309784903148793,
}
const BASELINE_TRACES: Dictionary = {
	"crossing": "e626ec4304ee8559fdf8d11bdf769c460a9e70f959108d3ac704e0a6dd3f6bf4",
	"lunge": "0d9c9595167cf78a6c00c2fe9cd577943b379987efe2c8c2226335f9de0b034d",
	"swim": "63eb7750c2001632f6d1e00540f597e06e4753dfa15c6267f337e8a2a7e7ec98",
}
## SHA-256 of the full classic PlayerInput command stream of run_stream("classic") (240 frames at 60 Hz, scripted aim / thrust /
## boost / brake, no SET command).
const BASELINE_STREAM_DIGEST: String = "29e0ffb13d66f52414569f3babc3dfdcd0a9f962199e29600d245f21b83f26ff"
## Digest of every command the v1 balance bot submits over BOT_TICKS ticks (seed 1); its final state_hash is BASELINE_HASHES["bot"].
const BASELINE_BOT_DIGEST: String = "8844c2f720727328bebe1acdf1b5c11bf27beb4d6f08cc65d95575362f807bfd"
const BOT_TICKS: int = 1800

static var _smooth_cache: Dictionary = {}


# ======================================================================= data file (tolerant reader)

static func modes_doc() -> Variant:
	if not FileAccess.file_exists(MODES_PATH):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(MODES_PATH))


static func _keyed(d: Variant) -> bool:
	if not (d is Dictionary) or (d as Dictionary).is_empty():
		return false
	var named: bool = false
	for k: Variant in (d as Dictionary).keys():
		var v: Variant = (d as Dictionary)[k]
		if not (v is Dictionary):
			return false
		if (v as Dictionary).has("name"):
			named = true
	return named


## {"kind": "list"|"keyed"|"none", "container": the Array / Dictionary that holds the records (a reference into `doc`)}.
static func locate(doc: Variant) -> Dictionary:
	if doc is Array:
		return {"kind": "list", "container": doc}
	if doc is Dictionary:
		var d: Dictionary = doc
		for k: Variant in d.keys():
			var v: Variant = d[k]
			if v is Array and not (v as Array).is_empty() and (v as Array)[0] is Dictionary:
				return {"kind": "list", "container": v}
		for k: Variant in d.keys():
			if _keyed(d[k]):
				return {"kind": "keyed", "container": d[k]}
		if _keyed(d):
			return {"kind": "keyed", "container": d}
	return {"kind": "none", "container": null}


## [{"id": String, "rec": Dictionary (reference into `doc`)}] in file order.
static func pairs_of(doc: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var loc: Dictionary = locate(doc)
	if loc["kind"] == "list":
		for it: Variant in (loc["container"] as Array):
			if it is Dictionary:
				out.append({"id": str((it as Dictionary).get("id", "")), "rec": it})
	elif loc["kind"] == "keyed":
		for k: Variant in (loc["container"] as Dictionary).keys():
			out.append({"id": str(k), "rec": (loc["container"] as Dictionary)[k]})
	return out


## The shipped mode records as copies with "id" set, in file order (empty when the file is missing or unreadable).
static func modes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for pr: Dictionary in pairs_of(modes_doc()):
		var rec: Dictionary = (pr["rec"] as Dictionary).duplicate(true)
		rec["id"] = pr["id"]
		out.append(rec)
	return out


static func mode(id: String) -> Dictionary:
	for m: Dictionary in modes():
		if str(m["id"]) == id:
			return m
	return {}


static func ids_file() -> Array[String]:
	var out: Array[String] = []
	for m: Dictionary in modes():
		out.append(str(m["id"]))
	return out


static func ids_sorted() -> Array[String]:
	var out: Array[String] = ids_file()
	out.sort()
	return out


## Numeric field of a shipped mode (`fallback` when the mode or field is missing / not a number).
static func mode_f(id: String, key: String, fallback: float = 0.0) -> float:
	var v: Variant = mode(id).get(key)
	return float(v) if TS.has_num(v) else fallback


static func name_of(id: String) -> String:
	return str(mode(id).get("name", ""))


## First non-empty string field of a record other than id / name (the one-line description).
static func description_of(id: String) -> String:
	var m: Dictionary = mode(id)
	for k: String in DESC_KEYS:
		if m.get(k) is String and not (m[k] as String).strip_edges().is_empty():
			return m[k]
	for k: Variant in m.keys():
		if str(k) != "id" and str(k) != "name" and m[k] is String and not (m[k] as String).strip_edges().is_empty():
			return m[k]
	return ""


## Key of the optional turn cap (deg/s) used anywhere in the file ("" = the data has none).
static func cap_key() -> String:
	for m: Dictionary in modes():
		for k: String in CAP_KEYS:
			if m.has(k):
				return k
		for k: Variant in m.keys():
			if str(k).contains("cap") and TS.has_num(m[k]):
				return str(k)
	return ""


## Strict bite half-cone (deg) and the shipped assist cone extension (deg at strength 1).
static func strict_cone_deg() -> float:
	return S3.rule_f(S3.content(), "bite_cone_deg")


static func assist_cone_deg() -> float:
	return S3.rule_f(S3.content(), "aim_assist_cone_deg")


static func widened_deg(strength: float) -> float:
	return strict_cone_deg() + assist_cone_deg() * strength


# ----------------------------------------------------------------------- temp data copies (negative / data-driven tests)

## Loaded ContentDB over a throw-away copy of res://data in which `edit.call(doc, pairs)` rewrote controls/modes.json.
## `doc` is the parsed file, `pairs` the editable [{"id","rec"}] references. Call G.cleanup_temp() afterwards.
static func db_with_edit(edit: Callable) -> ContentDB:
	return G.db_with(func(root: String) -> void:
		var path: String = root.path_join(MODES_REL)
		if not FileAccess.file_exists(path):
			return  # no modes file yet: the copy loads without one
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		edit.call(doc, pairs_of(doc))
		G.write_json(path, doc))


## Sets `key` on the record `id` (value null removes the key). Returns the loaded copy.
static func db_with_field(id: String, key: String, value: Variant) -> ContentDB:
	return db_with_edit(func(_doc: Variant, pairs: Array[Dictionary]) -> void:
		for pr: Dictionary in pairs:
			if pr["id"] == id:
				if value == null:
					(pr["rec"] as Dictionary).erase(key)
				else:
					(pr["rec"] as Dictionary)[key] = value)


## Renames record `from` to `to` (list layout: the id field; keyed layout: the key). False when the layout cannot do it.
static func rename_id(doc: Variant, from: String, to: String) -> bool:
	var loc: Dictionary = locate(doc)
	if loc["kind"] == "list":
		for pr: Dictionary in pairs_of(doc):
			if pr["id"] == from:
				(pr["rec"] as Dictionary)["id"] = to
				return true
	elif loc["kind"] == "keyed":
		var c: Dictionary = loc["container"]
		if c.has(from):
			var rec: Variant = c[from]
			c.erase(from)
			c[to] = rec
			return true
	return false


static func errors_text(db: ContentDB) -> String:
	return "\n".join(db.errors)


## True when the loaded copy is rejected with an error that names the modes file (and every needle, case-insensitive).
static func rejected(db: ContentDB, needles: Array[String] = []) -> bool:
	if db.is_valid():
		return false
	var t: String = errors_text(db).to_lower()
	if not (t.contains("modes") or t.contains("controls")):
		return false
	for n: String in needles:
		if not t.contains(n.to_lower()):
			return false
	return true


## ContentDB over res://data with extra rule keys (flat) written in; no spawners are removed (callers use world_on).
static func db_shipped(rules_extra: Dictionary = {}, band_m: Variant = null) -> ContentDB:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	for k: Variant in rules_extra.keys():
		rules[str(k)] = rules_extra[k]
	if band_m != null:
		for i in range(1, db.band_count() + 1):
			db.get_band(i)["lunge_distance_m"] = float((band_m as Array)[i - 1]) if band_m is Array else float(band_m)
	return db


## Controlled world (no spawners, vitals on) over `db`.
static func world_on(db: ContentDB, brains: bool = false, world_seed: int = SEED) -> SimWorld:
	db.get_map(S3.MAP_ID)["spawners"] = []
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = true
	w.brains_enabled = brains
	return w


# ======================================================================= the command

static func set_type() -> int:
	return int(SimCommand.Type.get("SET_CONTROL_MODE", -1))


static func has_type() -> bool:
	return set_type() >= 0


static func _sim_command_script() -> GDScript:
	return load("res://scripts/sim/sim_command.gd") as GDScript


## The factory method description ({} when SimCommand has none of SET_FACTORIES).
static func factory() -> Dictionary:
	var sc: GDScript = _sim_command_script()
	if sc == null:
		return {}
	for m: Dictionary in sc.get_script_method_list():
		if SET_FACTORIES.has(str(m["name"])) and (int(m["flags"]) & METHOD_FLAG_STATIC) != 0:
			return m
	return {}


## Payload for `id` in the type the payload argument asks for (int = index into the sorted ids).
static func payload_for(id: String, as_type: int) -> Variant:
	if as_type == TYPE_INT:
		return ids_sorted().find(id)
	if as_type == TYPE_STRING:
		return id
	return StringName(id)


## SET_CONTROL_MODE command for `entity_id`. Null when the type or a way to build it does not exist yet.
static func make_set(entity_id: int, id: String, tick: int = -1) -> SimCommand:
	if not has_type():
		return null
	var f: Dictionary = factory()
	if not f.is_empty():
		var args: Array = []
		var fargs: Array = f["args"]
		for i in fargs.size():
			match i:
				0:
					args.append(entity_id)
				1:
					args.append(payload_for(id, int((fargs[i] as Dictionary)["type"])))
				2:
					args.append(tick)
				_:
					args.append(null)
		return _sim_command_script().callv(str(f["name"]), args) as SimCommand
	var c := SimCommand.new()
	c.type = set_type() as SimCommand.Type
	c.entity_id = entity_id
	c.tick = tick
	for prop: String in SET_PAYLOAD_PROPS:
		if prop in c:
			c.set(prop, payload_for(id, typeof(c.get(prop))))
			return c
	return null


## A command whose payload names no mode: `kind` 0 = an unknown id / index 999, 1 = empty id / -1, 2 = odd-case id / 9999.
## The payload field is found by diffing a real "assisted" command against a blank SimCommand.
static func make_bad_set(entity_id: int, kind: int = 0, tick: int = -1) -> SimCommand:
	var c: SimCommand = make_set(entity_id, "assisted", tick)
	if c == null:
		return null
	var blank := SimCommand.new()
	for p: Dictionary in c.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var n: String = str(p["name"])
		if n == "seq" or n == "tick" or n == "entity_id" or n == "type":
			continue
		var cur: Variant = c.get(n)
		if str(cur) == str(blank.get(n)):
			continue
		if typeof(cur) == TYPE_INT:
			c.set(n, [999, -1, 9999][kind % 3])
		else:
			c.set(n, StringName(["no_such_mode", "", "CLASSIC "][kind % 3]))
		return c
	return c


## True when `cmd` is a SET_CONTROL_MODE carrying `id` (compared field by field with a freshly built command).
static func is_set_of(cmd: SimCommand, id: String) -> bool:
	if cmd == null or int(cmd.type) != set_type():
		return false
	var ref: SimCommand = make_set(cmd.entity_id, id)
	if ref == null:
		return false
	for p: Dictionary in cmd.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var n: String = str(p["name"])
		if n == "seq" or n == "tick":
			continue
		if str(cmd.get(n)) != str(ref.get(n)):
			return false
	return true


static func is_set(cmd: SimCommand) -> bool:
	return cmd != null and has_type() and int(cmd.type) == set_type()


# ----------------------------------------------------------------------- entity state

## Raw `control_mode` value of an entity (null = the field does not exist).
static func mode_value(e: SimEntity) -> Variant:
	return e.get("control_mode") if e != null else null


## True when a raw state value means mode `id` (string / StringName id, or an int index into the sorted or the file order).
static func value_is(v: Variant, id: String) -> bool:
	if v == null:
		return false
	if v is String or v is StringName:
		return str(v) == id
	if v is int:
		return int(v) == ids_sorted().find(id) or int(v) == ids_file().find(id)
	return false


## Entity is in mode `id`; for a non-classic id the value must not also read as classic (index ambiguity).
static func in_mode(e: SimEntity, id: String) -> bool:
	var v: Variant = mode_value(e)
	if not value_is(v, id):
		return false
	return id == "classic" or not value_is(v, "classic")


# ======================================================================= sim scenarios

static func _drive(w: SimWorld, p: SimEntity, v: SimEntity, pos_fn: Callable, ticks: int, evs: Array[SimEvent]) -> void:
	for i in ticks:
		evs.append_array(S3.step_n(w, 1, {v.id: pos_fn.call(p, i)}, [v.id, p.id]))


## Prey swimming ACROSS the aim (AS.crossing geometry), one idle tick first so a mode set at tick 0 is certainly active when
## the single bite press happens. `mode_id` "" = no command at all. `rules` = global rule overrides (e.g. the strengths).
## Returns {"w","p","v","evs","min_angle","bites","misses","trace","hash"}.
static func crossing(mode_id: String, rules: Dictionary = {}, ticks: int = 24, window: int = 7) -> Dictionary:
	var w: SimWorld = AS.world({"rules": rules})
	var p: SimEntity = TS.player(w)
	var v: SimEntity = TS.victim(w, p, p.position + Vector3(0, 0, 10))
	if mode_id != "":
		w.submit(make_set(p.id, mode_id))
	var pos0: Vector3 = p.position + p.heading * 0.3 + AS.side_of(p) * 1.0
	var evs: Array[SimEvent] = S3.step_n(w, 1, {v.id: pos0}, [v.id, p.id])
	var min_angle: float = 360.0
	w.submit(SimCommand.bite(p.id, -1))
	for i in ticks:
		var pos: Vector3 = p.position + p.heading * 0.3 + AS.side_of(p) * (1.0 - 0.05 * float(i))
		if i < window:
			min_angle = minf(min_angle, AS.angle_deg(p, pos))
		evs.append_array(S3.step_n(w, 1, {v.id: pos}, [v.id, p.id]))
	var bites: Array[SimEvent] = TS.bites_by(evs, p.id, v.id)
	return {"w": w, "p": p, "v": v, "evs": evs, "min_angle": min_angle, "bites": bites.size(), "misses": TS.misses_of(evs, p.id),
		"trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## ONE victim pinned `deg` off the heading at `centre_m`; for every entry of `modes` ("" = no command) the mode is set, one idle
## tick passes, one bite press is made and `phase_ticks` ticks are watched. Returns the landed bites per phase.
## `w` = a ready world (controlled, brains off); the victim follows the player pose so a lunge never changes the geometry.
static func phases(w: SimWorld, modes_seq: Array, deg: float, centre_m: float = 0.9, phase_ticks: int = 60) -> Array[int]:
	var p: SimEntity = TS.player(w)
	var v: SimEntity = TS.victim(w, p, TS.at(p, centre_m, deg))
	var out: Array[int] = []
	for m: Variant in modes_seq:
		if str(m) != "":
			w.submit(make_set(p.id, str(m)))
		S3.step_n(w, 1, {v.id: TS.at(p, centre_m, deg)}, [v.id, p.id])
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = []
		for i in phase_ticks:
			evs.append_array(S3.step_n(w, 1, {v.id: TS.at(p, centre_m, deg)}, [v.id, p.id]))
		out.append(TS.bites_by(evs, p.id, v.id).size())
	return out


## phases() on a fresh controlled world with global rule overrides `rules`.
static func phases_on(modes_seq: Array, deg: float, rules: Dictionary = {}) -> Array[int]:
	return phases(AS.world({"rules": rules}), modes_seq, deg)


## Lunge rig: band `band` player at rest (LS geometry), victim following its mouth, one bite at tick 2. `mode_id` "" = no command.
## Returns LS.run() + LS.motion() ("travel", "along", "angle_deg", "speed", ...).
static func lunge_once(w: SimWorld, mode_id: String, band: int = 2, settle: int = LS.SETTLE) -> Dictionary:
	var p: SimEntity = LS.player(w, band, LS.HEADING_YAW)
	var v: SimEntity = LS.victim(w, p)
	if mode_id != "":
		w.submit(make_set(p.id, mode_id))
	var r: Dictionary = LS.run(w, p, v, settle, [{"tick": 2, "bite": true}])
	r.merge(LS.motion(r, p.heading))
	return r


## Second (third ...) bite of the same world and player after the first run settled: `mode_id` is set at the start ("" = no command).
static func lunge_again(r: Dictionary, mode_id: String, settle: int = LS.SETTLE) -> Dictionary:
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	var v: SimEntity = r["v"]
	if mode_id != "":
		w.submit(make_set(p.id, mode_id))
	var r2: Dictionary = LS.run(w, p, v, settle, [{"tick": 2, "bite": true}])
	r2.merge(LS.motion(r2, p.heading))
	return r2


## Lunge world: controlled, global lunge_strength `g_lunge` (0 = off) and the explicit band distances LS.BAND_M_TEST;
## `rules_extra` e.g. {"aim_assist_strength": 0.9}.
static func lunge_world(g_lunge: float = 0.0, rules_extra: Dictionary = {}) -> SimWorld:
	return LS.world(g_lunge, LS.BAND_M_TEST, rules_extra)


## Lunge world over a ContentDB (data-driven tests): global strengths 0, explicit band distances.
static func lunge_world_on(db: ContentDB) -> SimWorld:
	for i in range(1, db.band_count() + 1):
		db.get_band(i)["lunge_distance_m"] = LS.BAND_M_TEST[i - 1]
	return world_on(db)


## Free swimming in empty water: scripted MOVE / BOOST / BRAKE / bite presses (all misses), 240 ticks. `plan` = [{"tick", "mode"}]
## mode commands. Returns {"w","p","hash","trace"}.
static func swim(plan: Array = [], ticks: int = 240) -> Dictionary:
	var w: SimWorld = AS.world({})
	var p: SimEntity = TS.player(w)
	for i in ticks:
		for item: Variant in plan:
			if int((item as Dictionary)["tick"]) == i:
				w.submit(make_set(p.id, str((item as Dictionary)["mode"])))
		if i % 30 == 0:
			w.submit(SimCommand.move(p.id, Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(12.0 * float(i / 30))), 0.7))
		if i == 100:
			w.submit(SimCommand.boost(p.id, true))
		if i == 160:
			w.submit(SimCommand.boost(p.id, false))
		if i % 45 == 0:
			w.submit(SimCommand.bite(p.id, -1))
		w.step()
		p.hp = p.max_hp
	return {"w": w, "p": p, "hash": w.state_hash(), "trace": TS.trace(w)}


## Shark hunting small fish, the (inert) player 40 m away. `player_mode` / `shark_mode` ("" = none) are set at tick 0.
## Returns {"trace","hash","npc_bites","shark_id","w"}.
static func npc_hunt(player_mode: String, shark_mode: String = "", ticks: int = 600) -> Dictionary:
	var w: SimWorld = S3.make_world(AS.SEED, {})
	var p: SimEntity = TS.player(w)
	p.position += Vector3(40.0, 0.0, 0.0)
	var c: Vector3 = S3.ARENA
	var shark: SimEntity = S3.npc_at(w, &"shark", c, 3.0, Vector3.RIGHT)
	for k in 4:
		S3.npc_at(w, &"small_reef_fish", c + Vector3(2.5 + 0.4 * float(k), 0.0, 0.6 * float(k) - 1.0), 0.9, Vector3.RIGHT)
	if player_mode != "":
		w.submit(make_set(p.id, player_mode))
	if shark_mode != "":
		w.submit(make_set(shark.id, shark_mode))
	var evs: Array[SimEvent] = S3.step_n(w, ticks, {}, [p.id])
	var n: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id != p.id:
			n += 1
	return {"trace": TS.trace_with(w, evs), "hash": w.state_hash(), "npc_bites": n, "shark_id": shark.id, "w": w}


## Shipped spawners + schools + the scripted player of AS.real_world_with_player_bites (a bite every 45 ticks), a mode command at tick 0.
static func real_world(mode_id: String, world_seed: int = 4242, ticks: int = 600, player_bites: bool = true) -> Dictionary:
	var w: SimWorld = S3.make_world(world_seed, {"real_spawners": true})
	var id: int = w.spawn_player(0)
	if mode_id != "":
		w.submit(make_set(id, mode_id))
	S2.submit_segments(w, id, S2.movement_script(1001, ticks, true, true), true)
	if player_bites:
		var t: int = 40
		while t < ticks:
			w.submit(SimCommand.bite(id, -1, t))
			t += 45
	var evs: Array[SimEvent] = S3.step_n(w, ticks)
	var npc_bites: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id != id:
			npc_bites += 1
	return {"w": w, "trace": TS.trace_with(w, evs), "hash": w.state_hash(), "npc_bites": npc_bites, "player_bites": TS.bites_by(evs, id).size()}


## v1 balance bot (seed `bot_seed`) in the shipped world for `ticks` ticks. Returns {"digest" (SHA-256 of every command the bot
## submitted), "hash" (final state_hash), "max_type" (largest command type seen), "set_count" (SET_CONTROL_MODE commands)}.
static func bot_stream(ticks: int = BOT_TICKS, bot_seed: int = 1) -> Dictionary:
	var Bot: GDScript = load("res://tests/bots/bot_player.gd") as GDScript
	var content: ContentDB = ContentDB.load_from_dir()
	var w := SimWorld.new(bot_seed, content)
	w.vitals_enabled = true
	NpcSpawner.set_enabled(w, true)
	var pid: int = w.spawn_player(0)
	var bot: RefCounted = Bot.new(w, pid, bot_seed)
	var lines: PackedStringArray = []
	var max_type: int = -1
	var sets: int = 0
	for i in ticks:
		for c: SimCommand in bot.commands():
			lines.append(cmd_line(c))
			max_type = maxi(max_type, int(c.type))
			if is_set(c):
				sets += 1
			w.submit(c)
		w.step()
		var evs: Array[SimEvent] = w.events_since(w.tick - 1)
		bot.observe(evs)
		if w.paused_for_pick:
			var e: SimEntity = w.get_entity(pid)
			w.submit(SimCommand.pick_mutation(pid, StringName(e.pending_offer[0])))
			w.step()
	return {"digest": "\n".join(lines).sha256_text(), "hash": w.state_hash(), "max_type": max_type, "set_count": sets}


# ======================================================================= PlayerInput

## "type,entity,tick,dir,thrust,active,target,ability,node" of one command (tick -1 = next tick; seq is not part of it).
static func cmd_line(c: SimCommand) -> String:
	return "%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%d,%d,%s,%s" % [c.type, c.entity_id, c.tick, c.dir.x, c.dir.y, c.dir.z, c.thrust,
		int(c.active), c.target_id, str(c.ability_id), str(c.node_id)]


static func stream_digest(frames: Array) -> String:
	var lines: PackedStringArray = []
	for fr: Variant in frames:
		for c: SimCommand in (fr as Array):
			lines.append(cmd_line(c))
		lines.append("--")
	return "\n".join(lines).sha256_text()


## Scripted aim of frame `i` as (yaw, pitch): the first 4 frames hold the start aim, then a smooth sweep.
static func aim_at(i: int) -> Vector2:
	if i < 4:
		return Vector2.ZERO
	return Vector2(0.9 * sin(0.05 * float(i)) + 0.5 * sin(0.013 * float(i)), 0.4 * sin(0.031 * float(i) + 1.0))


## PlayerInput in the tree with its own processing off (the test calls _physics_process by hand), aim -Z (yaw 0, pitch 0).
static func input_rig(w: SimWorld, p: SimEntity) -> PlayerInput:
	var pi := PlayerInput.new()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.root.add_child(pi)
	pi.set_physics_process(false)
	pi.set_process_unhandled_input(false)
	pi.setup(w, p.id)
	pi.aim_yaw = 0.0
	pi.aim_pitch = 0.0
	# a node added during the runner's _initialize enters the tree one frame later and re-enables its own processing
	await tree.process_frame
	pi.set_physics_process(false)
	pi.set_process_unhandled_input(false)
	pi.aim_yaw = 0.0
	pi.aim_pitch = 0.0
	w._queue.pop_for_tick(w.tick)  # drop whatever the node submitted on its own before it was switched off
	return pi


static func release_input(pi: PlayerInput) -> void:
	for a: StringName in [&"bite", &"boost", &"swim_thrust", &"swim_brake", &"bite_dash", &"sonar"]:
		if InputMap.has_action(a):
			Input.action_release(a)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var parent: Node = pi.get_parent()
	if parent != null:
		parent.remove_child(pi)
	pi.free()


## Scripted Input actions of frame `i` (thrust 0.5 from frame 10, boost 50..120, brake 80..100).
static func script_actions(i: int) -> void:
	if i == 10:
		Input.action_press(&"swim_thrust", 0.5)
	if i == 50:
		Input.action_press(&"boost")
	if i == 80:
		Input.action_press(&"swim_brake")
	if i == 100:
		Input.action_release(&"swim_brake")
	if i == 120:
		Input.action_release(&"boost")


## Tells the input node about the mode the way a run does (GameSettings.apply_input); falls back to setters on PlayerInput.
## Returns false when no way exists.
static func apply_mode(pi: PlayerInput, id: String) -> bool:
	var gs := GameSettings.new(SCRATCH_SETTINGS)
	if set_settings_mode(gs, id):
		gs.apply_input(pi)
		return true
	for m: String in INPUT_MODE_METHODS:
		if pi.has_method(m):
			pi.call(m, StringName(id))
			return true
	for prop: String in INPUT_MODE_PROPS:
		if prop in pi:
			pi.set(prop, payload_for(id, typeof(pi.get(prop))))
			return true
	return false


## Runs `frames` physics frames of a PlayerInput on a fresh world (player band 1 at the arena, aim -Z). A mode other than
## "classic" is applied through apply_mode() before the first frame ("@settings" = GameSettings.new(SCRATCH_SETTINGS) loaded and applied). `aim_fn` (frame -> Vector2 yaw / pitch, default aim_at);
## `mid_switch` = {"frame": int, "mode": String} switches the mode once in the middle. Every `step_every` frames the commands
## are drained from the queue (so the list per frame is exact) and the world steps once.
## Returns {"frames": Array of Array[SimCommand], "dirs": Array[Vector3] (MOVE dirs), "aims": Array[Vector3] (raw aim at that frame),
## "applied": bool, "pid": int}.
static func run_stream(mode_id: String, frames: int = 240, dt: float = 1.0 / 60.0, aim_fn: Callable = Callable(), mid_switch: Dictionary = {}) -> Dictionary:
	var w: SimWorld = AS.world({})
	var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0, Vector3(0, 0, -1))
	var pi: PlayerInput = await input_rig(w, p)
	var applied: bool = true
	if mode_id == "@settings":  # the real run-start path: the settings file (scratch path) is loaded and applied
		var gs := GameSettings.new(SCRATCH_SETTINGS)
		gs.load_file()
		gs.apply_input(pi)
	elif mode_id != "classic" and mode_id != "":
		applied = apply_mode(pi, mode_id)
	var out_frames: Array = []
	var dirs: Array[Vector3] = []
	var aims: Array[Vector3] = []
	var every: int = maxi(roundi((1.0 / 30.0) / dt), 1)
	for i in frames:
		var a: Vector2 = aim_fn.call(i) if aim_fn.is_valid() else aim_at(i)
		pi.aim_yaw = a.x
		pi.aim_pitch = a.y
		script_actions(i)
		if not mid_switch.is_empty() and int(mid_switch["frame"]) == i:
			applied = apply_mode(pi, str(mid_switch["mode"])) and applied
		pi._physics_process(dt)
		var got: Array[SimCommand] = []
		for c: SimCommand in w._queue.pop_for_tick(w.tick):
			got.append(c)
			if int(c.type) == int(SimCommand.Type.MOVE):
				dirs.append(c.dir)
				aims.append(pi.aim_direction())
		out_frames.append(got)
		if i % every == every - 1:
			w.step()
			p.hp = p.max_hp
	release_input(pi)
	return {"frames": out_frames, "dirs": dirs, "aims": aims, "applied": applied, "pid": p.id}


## Every command of all frames as one flat list.
static func flat(frames: Array) -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	for fr: Variant in frames:
		for c: SimCommand in (fr as Array):
			out.append(c)
	return out


static func count_sets(frames: Array) -> int:
	var n: int = 0
	for c: SimCommand in flat(frames):
		if is_set(c):
			n += 1
	return n


## Frames without the SET commands (what a classic stream would hold).
static func without_sets(frames: Array) -> Array:
	var out: Array = []
	for fr: Variant in frames:
		var keep: Array[SimCommand] = []
		for c: SimCommand in (fr as Array):
			if not is_set(c):
				keep.append(c)
		out.append(keep)
	return out


# ======================================================================= GameSettings

## Name of the GameSettings variable that holds the control mode ("" = none yet).
static func settings_prop() -> String:
	var sc: GDScript = load("res://scripts/ui/game_settings.gd") as GDScript
	if sc == null:
		return ""
	var best: String = ""
	for p: Dictionary in sc.get_script_property_list():
		var n: String = str(p["name"])
		if n.contains("control_mode"):
			return n
		if n.contains("mode") and not n.contains("mouse") and best == "":
			best = n
	return best


static func settings_mode(gs: GameSettings) -> String:
	var prop: String = settings_prop()
	if prop == "":
		return ""
	var v: Variant = gs.get(prop)
	if v is int:
		var sorted: Array[String] = ids_sorted()
		return sorted[int(v)] if int(v) >= 0 and int(v) < sorted.size() else ""
	return str(v)


static func set_settings_mode(gs: GameSettings, id: String) -> bool:
	var prop: String = settings_prop()
	if prop == "":
		return false
	gs.set(prop, payload_for(id, typeof(gs.get(prop))))
	return true


## [section, key] the config file uses for the mode (found by saving classic and `probe_id` and diffing the files); [] if none.
static func cfg_key(probe_id: String = "assisted") -> Array:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_SETTINGS))
	var gs := GameSettings.new(SCRATCH_SETTINGS)
	if not set_settings_mode(gs, "classic"):
		return []
	gs.save_file()
	var a := ConfigFile.new()
	a.load(SCRATCH_SETTINGS)
	set_settings_mode(gs, probe_id)
	gs.save_file()
	var b := ConfigFile.new()
	b.load(SCRATCH_SETTINGS)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_SETTINGS))
	for s: String in b.get_sections():
		for k: String in b.get_section_keys(s):
			if not a.has_section_key(s, k) or str(a.get_value(s, k)) != str(b.get_value(s, k)):
				return [s, k]
	return []


static func remove_scratch() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_SETTINGS))


# ======================================================================= pure smoothing step

static func _scan_dirs() -> Array[String]:
	return ["res://scripts/fish", "res://scripts/sim", "res://scripts/ui", "res://scripts"]


## {"script": GDScript, "name": String, "args": Array} of the discovered static smoothing function ({} = none yet).
static func smoothing() -> Dictionary:
	if not _smooth_cache.is_empty():
		return _smooth_cache
	var paths: Array[String] = []
	for dir: String in _scan_dirs():
		var d: DirAccess = DirAccess.open(dir)
		if d == null:
			continue
		for f: String in d.get_files():
			if f.ends_with(".gd") and f.to_lower().contains("smooth"):
				paths.append(dir.path_join(f))
	paths.append("res://scripts/fish/player_input.gd")
	var best: Dictionary = {}
	var best_score: int = -1
	for path: String in paths:
		var sc: GDScript = load(path) as GDScript
		if sc == null:
			continue
		for m: Dictionary in sc.get_script_method_list():
			if (int(m["flags"]) & METHOD_FLAG_STATIC) == 0:
				continue
			var n: String = str(m["name"]).to_lower()
			if not (n.contains("smooth") or n.contains("step") or n.contains("ease")):
				continue
			var vecs: int = 0
			for a: Dictionary in m["args"]:
				if int(a["type"]) == TYPE_VECTOR3:
					vecs += 1
			if vecs < 2:
				continue
			var score: int = (4 if n == "step" or n == "smooth_step" or n == "smooth" else 0) + (2 if path.to_lower().contains("smooth") else 0) + (m["args"] as Array).size()
			if score > best_score:
				best_score = score
				best = {"script": sc, "name": str(m["name"]), "args": m["args"]}
	_smooth_cache = best
	return best


static func has_smoothing() -> bool:
	return not smoothing().is_empty()


## True when the pure step accepts a turn cap (a cap-like float argument, or a record Dictionary).
static func smoothing_has_cap() -> bool:
	for a: Dictionary in smoothing().get("args", []):
		var an: String = str(a["name"]).to_lower()
		if int(a["type"]) == TYPE_DICTIONARY:
			return true
		if int(a["type"]) == TYPE_FLOAT and (an.contains("cap") or an.contains("max") or an.contains("limit") or an.contains("rate") or an.contains("turn")):
			return true
	return false


## One smoothing step through the discovered function. Null when none exists / it returned no Vector3.
static func smooth_step(cur: Vector3, tar: Vector3, dt: float, tau: float, cap_deg_s: float = 0.0) -> Variant:
	var t: Dictionary = smoothing()
	if t.is_empty():
		return null
	var args: Array = []
	var vec_seen: int = 0
	var floats_left: Array[float] = [dt, tau, cap_deg_s]
	var float_pos: int = 0
	for a: Dictionary in t["args"]:
		var an: String = str(a["name"]).to_lower()
		match int(a["type"]):
			TYPE_VECTOR3:
				var is_cur: bool = false
				for h: String in ["cur", "prev", "last", "smoothed", "state", "from", "old"]:
					is_cur = is_cur or an.contains(h)
				var is_tar: bool = false
				for h: String in ["tar", "raw", "goal", "want", "desir", "aim", "input", "dest"]:
					is_tar = is_tar or an.contains(h)
				if is_cur or (not is_tar and vec_seen == 0):
					args.append(cur)
				else:
					args.append(tar)
				vec_seen += 1
			TYPE_FLOAT:
				if an.contains("dt") or an.contains("delta"):
					args.append(dt)
				elif an.contains("tau") or an.contains("time_const"):
					args.append(tau)
				elif an.contains("cap") or an.contains("max") or an.contains("limit") or an.contains("rate") or an.contains("turn"):
					args.append(cap_deg_s)
				else:
					args.append(floats_left[mini(float_pos, 2)])
				float_pos += 1
			TYPE_DICTIONARY:
				var rec: Dictionary = {KEY_TAU: tau}
				for k: String in CAP_KEYS:
					rec[k] = cap_deg_s
				args.append(rec)
			TYPE_INT:
				args.append(0)
			TYPE_BOOL:
				args.append(false)
			_:
				args.append(null)
	var res: Variant = (t["script"] as GDScript).callv(str(t["name"]), args)
	return res


## Angle in degrees between two directions.
static func deg_between(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


## Direction `deg` degrees from -Z about +Y (yaw) and `pitch_deg` up.
static func dir_yaw_pitch(deg: float, pitch_deg: float = 0.0) -> Vector3:
	var y: float = deg_to_rad(deg)
	var pt: float = deg_to_rad(pitch_deg)
	return Vector3(-sin(y) * cos(pt), sin(pt), -cos(y) * cos(pt)).normalized()


## Iterates the step `n` times toward a fixed target; returns the list of directions (index 0 = after the first step).
static func iterate(cur: Vector3, tar: Vector3, dt: float, tau: float, n: int, cap_deg_s: float = 0.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var c: Vector3 = cur
	for i in n:
		var r: Variant = smooth_step(c, tar, dt, tau, cap_deg_s)
		if not (r is Vector3):
			return out
		c = r
		out.append(c)
	return out


# ======================================================================= UI helpers

## The OptionButton of a SettingsMenu that lists the control modes (items == the `name` of every mode); null if none.
static func mode_selector(menu: Node) -> OptionButton:
	var names: Array[String] = []
	for m: Dictionary in modes():
		names.append(str(m.get("name", "")))
	for n: Node in TS.find_all(menu, "OptionButton"):
		var ob: OptionButton = n as OptionButton
		if ob == menu.get("quality_option"):
			continue
		var texts: Array[String] = []
		for i in ob.item_count:
			texts.append(ob.get_item_text(i))
		var all: bool = not names.is_empty()
		for nm: String in names:
			all = all and texts.has(nm)
		if all:
			return ob
	return null


## Index of the item whose text is the mode's `name` (-1 = none).
static func item_of(ob: OptionButton, id: String) -> int:
	var nm: String = name_of(id)
	for i in ob.item_count:
		if ob.get_item_text(i) == nm:
			return i
	return -1


static func selected_mode_name(ob: OptionButton) -> String:
	return ob.get_item_text(ob.selected) if ob.selected >= 0 and ob.selected < ob.item_count else ""
