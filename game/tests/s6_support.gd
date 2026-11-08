extends RefCounted
## Shared helpers for the test_s6_*.gd files (res://tests/s6_support.gd). Not a test file: the runner only collects
## scripts whose name starts with "test_". Use via `const S6 := preload("res://tests/s6_support.gd")`.
## No class_name (no global class cache dependency).
##
## The S6 sim API is reached DYNAMICALLY (Object.get / .call / SimEvent.Type["NAME"] / SimCommand.Type["NAME"]), so one
## member that is missing or renamed fails the tests that need it with a readable "S6 API missing: ..." message
## instead of a parse error that takes the whole file down (same approach as s4_support.gd before the API was pinned).
## Names come from tasks/archive/2026-11/mvp/research/stage-S6-progression-boss-ui-1104/s6-contract.md; everything the contract does not
## name (see the test plan, "Assumptions needing a decision") is isolated in ONE helper below, so a rename is a
## one-line fix: pick_cmd(), picked_id(), boss_state_enum(), sonar_thresholds(), boss_f(), ability_f().
##
## All numbers (radii, windups, cooldowns, multipliers, ratios) are read from ContentDB; tests only choose scenario
## values (distances, XP to reach a band, pin positions).
##
## World conventions:
## - make_world() loads a PRIVATE ContentDB per world (or a patched one, see db_with_nodes) and is CONTROLLED:
##   map.spawners = [], map.schools = [], plankton zones = [], npc_scale 1.0, vitals off unless asked, NpcSpawner OFF.
##   The population is exactly what the test spawns. Brains run for every non-player creature.
## - Players come from S3.player_at(): xp-consistent band/length/max HP, no BAND_UP event at spawn. A band-up is
##   provoked on purpose with level_to() (xp write; the sim derives band in the growth phase of the next step).
## - Collected events are de-duplicated by instance id: a world that is paused for a pick does not advance its tick,
##   so events_since(tick - 1) would return the same events twice.

const S3 := preload("res://tests/s3_support.gd")

const BOSS: StringName = &"giant_shark"
const ABYSS: String = "abyss"
const SCRATCH: String = "user://s6_data_copy"
const TICKS_PER_S: int = 30
const NEW_EVENTS: Array[String] = [
	"MUTATION_OFFERED", "MUTATION_PICKED", "ABILITY_USED", "SONAR_PULSE", "BOSS_ENGAGED", "BOSS_TELL", "BOSS_DASH",
	"BOSS_DISENGAGED", "BOSS_STUNNED", "BOSS_DEFEATED", "VICTORY",
]
const WORLD_METHODS: Array[String] = ["ability_cooldown_left", "boss_id", "boss_engaged"]
const WORLD_PROPS: Array[String] = ["paused_for_pick", "run_won"]
const ENTITY_PROPS: Array[String] = ["pending_offer", "mutations", "abilities", "boss_state"]


# ---------------------------------------------------------------- API presence (compile-safe access)

static func ev_type(type_name: String) -> int:
	if SimEvent.Type.has(type_name):
		return int(SimEvent.Type[type_name])
	return -1


static func _prop_names(o: Object) -> Dictionary:
	var d: Dictionary = {}
	for p: Dictionary in o.get_property_list():
		d[str(p["name"])] = true
	return d


## Names of contract members that are not there (yet). Empty = the S6 sim API is present.
static func api_problems(w: SimWorld) -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in NEW_EVENTS:
		if ev_type(n) < 0:
			out.append("SimEvent.Type.%s" % n)
	if not SimCommand.Type.has("PICK_MUTATION"):
		out.append("SimCommand.Type.PICK_MUTATION")
	var wp: Dictionary = _prop_names(w)
	for n: String in WORLD_PROPS:
		if not wp.has(n):
			out.append("SimWorld.%s" % n)
	for m: String in WORLD_METHODS:
		if not w.has_method(m):
			out.append("SimWorld.%s()" % m)
	var ep: Dictionary = _prop_names(SimEntity.new())
	for n: String in ENTITY_PROPS:
		if not ep.has(n):
			out.append("SimEntity.%s" % n)
	return out


## Fails the calling test with a readable message and returns false when the S6 sim API is not there yet.
static func require_api(tc: TestCase, w: SimWorld) -> bool:
	var p: PackedStringArray = api_problems(w)
	if p.is_empty():
		return true
	tc.fail("S6 API missing: %s" % ", ".join(p))
	return false


# ---------------------------------------------------------------- dynamic state accessors

static func paused(w: SimWorld) -> bool:
	return bool(w.get("paused_for_pick"))


static func run_won(w: SimWorld) -> bool:
	return bool(w.get("run_won"))


static func offer_of(e: SimEntity) -> PackedStringArray:
	var v: Variant = e.get("pending_offer")
	if v is PackedStringArray:
		return v
	var out := PackedStringArray()
	if v is Array:
		for x: Variant in v:
			out.append(str(x))
	return out


static func mutations_of(e: SimEntity) -> PackedStringArray:
	var v: Variant = e.get("mutations")
	if v is PackedStringArray:
		return v
	var out := PackedStringArray()
	if v is Array:
		for x: Variant in v:
			out.append(str(x))
	return out


static func abilities_of(e: SimEntity) -> PackedStringArray:
	var v: Variant = e.get("abilities")
	if v is PackedStringArray:
		return v
	var out := PackedStringArray()
	if v is Array:
		for x: Variant in v:
			out.append(str(x))
	return out


static func cooldown_left(w: SimWorld, entity_id: int, ability: StringName) -> float:
	return float(w.call("ability_cooldown_left", entity_id, ability))


static func boss_id(w: SimWorld) -> int:
	return int(w.call("boss_id"))


static func boss_engaged(w: SimWorld) -> bool:
	return bool(w.call("boss_engaged"))


static func presence_sector_deg(e: SimEntity) -> float:
	var v: Variant = e.get("presence_sector_deg")
	return -1.0 if v == null else float(v)


## Grants nodes the way a pick leaves the player, WITHOUT an offer or a band-up: `Progression.grant(world, e, node_id)`
## (owned in order, ability ready at once, passives recomputed, MUTATION_PICKED, open offer untouched). The real pick path
## is covered separately (test_s6_mutation_pick, test_bite_power_through_the_real_pick_path).
static func give(w: SimWorld, e: SimEntity, node_ids: Array) -> void:
	for id_v: Variant in node_ids:
		Progression.grant(w, e, str(id_v))


## Unlocks `ability` by granting the one node whose `grants_ability` names it (no effects of its own in the shipped
## data). Returns false when no such node exists or it is already owned.
static func give_ability(w: SimWorld, e: SimEntity, ability: String) -> bool:
	for id: StringName in w.content.mutation_ids():
		if str(w.content.get_mutation(id).get("grants_ability", "")) == ability:
			return Progression.grant(w, e, String(id))
	return false


static func _script_has(script: GDScript, method_name: String) -> bool:
	for m: Dictionary in script.get_script_method_list():
		if str(m["name"]) == method_name:
			return true
	return false


# ---------------------------------------------------------------- data access

static func ability_f(db: ContentDB, ability: StringName, key: String, fallback: float = NAN) -> float:
	var v: Variant = db.get_ability(ability).get(key)
	return fallback if v == null else float(v)


## species giant_shark -> boss block number (fallback when the key is not in data yet).
static func boss_f(db: ContentDB, key: String, fallback: float = NAN) -> float:
	var boss: Variant = db.get_species(BOSS).get("boss")
	if boss is Dictionary and (boss as Dictionary).has(key):
		return float((boss as Dictionary)[key])
	return fallback


static func effect_f(db: ContentDB, node_id: StringName, key: String) -> float:
	var fx: Variant = db.get_mutation(node_id).get("effects")
	if fx is Dictionary and (fx as Dictionary).has(key):
		return float((fx as Dictionary)[key])
	return NAN


static func offer_count(db: ContentDB) -> int:
	return int(db.rules().get("mutation_offer_count", 3))


static func band_xp(db: ContentDB, band: int) -> float:
	return float(db.get_band(band)["xp_to_reach"])


## Mid-band XP for each band (1..4): safely inside the band, away from the thresholds.
static func mid_xp(db: ContentDB, band: int) -> float:
	var b: Dictionary = db.get_band(band)
	return 0.5 * (float(b["xp_to_reach"]) + float(b["xp_full_length"]))


## Max HP of a player of length `length_m` (rules.player_hp_model), band `band`.
static func player_hp(db: ContentDB, band: int, length_m: float) -> float:
	return S3.player_max_hp_ref(db, S3.PLAYER_SPECIES, band, length_m)


static func normal_bite_damage(db: ContentDB, species: StringName, band: int, length_m: float) -> float:
	return SimRules.bite_damage(float(db.get_band(band)["bite_power"]), length_m, float(db.get_species(species).get("bite_mult", 1.0)))


## Numbers of the sonar rel thresholds, found by key name (a key containing "smaller" / "bigger", possibly nested) in
## the sonar ability record. NAN when absent (the contract says "thresholds in data"; key names are not pinned).
static func sonar_thresholds(db: ContentDB) -> Dictionary:
	var flat: Dictionary = {}
	_flatten(db.get_ability(&"sonar"), "", flat)
	var out: Dictionary = {"smaller": NAN, "bigger": NAN}
	for k: Variant in flat.keys():
		var key: String = str(k).to_lower()
		if key.contains("smaller") and is_nan(float(out["smaller"])):
			out["smaller"] = float(flat[k])
		elif key.contains("bigger") and is_nan(float(out["bigger"])):
			out["bigger"] = float(flat[k])
	return out


static func _flatten(d: Dictionary, prefix: String, out: Dictionary) -> void:
	for k: Variant in d.keys():
		var v: Variant = d[k]
		var name: String = "%s%s" % [prefix, str(k)]
		if v is Dictionary:
			_flatten(v, name + ".", out)
		elif v is int or v is float:
			out[name] = v


# ---------------------------------------------------------------- content copies with extra mutation nodes

## ContentDB from a throw-away copy of res://data whose mutations.json got `extra` nodes appended (written to
## user://, loaded, deleted at once: ContentDB keeps everything in memory). Null when the copy cannot be made.
static func db_with_nodes(extra: Array) -> ContentDB:
	_remove_dir(SCRATCH)
	_copy_dir("res://data", SCRATCH)
	var path: String = SCRATCH.path_join("mutations/mutations.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_remove_dir(SCRATCH)
		return null
	var nodes: Array = (parsed as Dictionary)["nodes"]
	nodes.append_array(extra)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_remove_dir(SCRATCH)
		return null
	f.store_string(JSON.stringify(parsed, "\t"))
	f.close()
	var db: ContentDB = ContentDB.load_from_dir(SCRATCH)
	_remove_dir(SCRATCH)
	return db


## A tier-1 hunter node (no prerequisite) with the given effects; the shipped tree has only two such nodes.
static func extra_node(id: String, effects: Dictionary = {}) -> Dictionary:
	return {"id": id, "name": id, "description": "test node", "branch": "hunter", "tier": 1, "requires": null, "effects": effects}


static func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		if not sub.begins_with("."):
			_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "json":
			var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
			out.store_string(FileAccess.get_file_as_string(src.path_join(f)))
			out.close()


static func _remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------- world builders

## opts: "db": ContentDB (default: a fresh load of res://data), "vitals": bool (default false), "rules": Dictionary of
## dotted overrides of rules/core.json (e.g. {"tiers.interactive_cap": 5}). Controlled world (see the header).
static func make_world(world_seed: int = 1, opts: Dictionary = {}) -> SimWorld:
	var db: ContentDB = opts.get("db", null)
	if db == null:
		db = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	rules["npc_scale"] = 1.0
	var overrides: Dictionary = opts.get("rules", {})
	for k: Variant in overrides.keys():
		var parts: PackedStringArray = str(k).split(".")
		var cur: Dictionary = rules
		for i in parts.size() - 1:
			if not (cur.get(parts[i]) is Dictionary):
				cur[parts[i]] = {}
			cur = cur[parts[i]]
		cur[parts[-1]] = overrides[k]
	var map: Dictionary = db.get_map(S3.MAP_ID)
	map["spawners"] = []
	map["schools"] = []
	var pl: Variant = map.get("plankton")
	if pl is Dictionary:
		(pl as Dictionary)["zones"] = []
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = bool(opts.get("vitals", false))
	return w


## A point in the abyss zone well above the seabed (the boss patrols there). Vector3.INF when none fits.
static func abyss_spot(w: SimWorld) -> Vector3:
	var box: Array[Vector3] = S3.zone_box(w, ABYSS)
	if box.is_empty():
		return Vector3.INF
	for x: float in [0.0, 40.0, -40.0, 80.0, -80.0]:
		for z: float in [230.0, 210.0, 250.0]:
			var floor_y: float = w.seabed.height_at(x, z)
			var y: float = maxf(floor_y + 14.0, box[0].y + 6.0)
			if y < box[1].y - 2.0 and y > floor_y + 10.0:
				return Vector3(x, y, z)
	return Vector3.INF


## The boss at `pos` facing +X (HP = hp_override through the normal spawn path).
static func boss_at(w: SimWorld, pos: Vector3, heading: Vector3 = Vector3.RIGHT) -> SimEntity:
	var len: float = float((w.content.get_species(BOSS).get("length_m") as Dictionary)["min"])
	var id: int = w.spawn_entity(BOSS, pos, len, false)
	var e: SimEntity = w.get_entity(id)
	e.heading = heading.normalized()
	return e


## Boss at the abyss spot, player (xp -> band/length/HP) `dist` metres away along +X facing the boss.
## Returns {"w", "boss": SimEntity, "p": SimEntity, "spot": Vector3} or an empty Dictionary if no spot fits.
static func boss_rig(world_seed: int, dist: float, player_xp: float, opts: Dictionary = {}) -> Dictionary:
	var w: SimWorld = make_world(world_seed, opts)
	var spot: Vector3 = abyss_spot(w)
	if not spot.is_finite():
		return {}
	var boss: SimEntity = boss_at(w, spot)
	var p: SimEntity = S3.player_at(w, spot + Vector3(dist, 0.0, 0.0), player_xp, Vector3.LEFT)
	return {"w": w, "boss": boss, "p": p, "spot": spot}


static func player_pos(spot: Vector3, dist: float) -> Vector3:
	return spot + Vector3(dist, 0.0, 0.0)


# ---------------------------------------------------------------- boss state machine (BossBrain.State, dynamic)

static var _state_enum: Dictionary = {}


## name -> int of the boss state enum (any constant of boss_brain.gd that is a Dictionary with a PATROL key).
## Empty when the file or the enum is missing.
static func boss_state_enum() -> Dictionary:
	if not _state_enum.is_empty():
		return _state_enum
	if not ResourceLoader.exists("res://scripts/sim/boss_brain.gd"):
		return {}
	var script: GDScript = load("res://scripts/sim/boss_brain.gd") as GDScript
	if script == null:
		return {}
	var consts: Dictionary = script.get_script_constant_map()
	for k: Variant in consts.keys():
		var v: Variant = consts[k]
		if v is Dictionary and (v as Dictionary).has("PATROL"):
			_state_enum = v
			return _state_enum
	return {}


static func boss_state_value(e: SimEntity) -> int:
	return int(e.get("boss_state"))


static func state_name(e: SimEntity) -> String:
	var en: Dictionary = boss_state_enum()
	var v: int = boss_state_value(e)
	for k: Variant in en.keys():
		if int(en[k]) == v:
			return str(k)
	return "?%d" % v


## True when the boss state enum has all of `names` (a missing name is an API problem, reported by the caller).
static func state_enum_problems(names: Array) -> PackedStringArray:
	var out := PackedStringArray()
	var en: Dictionary = boss_state_enum()
	if en.is_empty():
		out.append("BossBrain.State enum (a Dictionary constant with PATROL in res://scripts/sim/boss_brain.gd)")
		return out
	for n_v: Variant in names:
		if not en.has(str(n_v)):
			out.append("BossBrain.State.%s" % str(n_v))
	return out


static func require_states(tc: TestCase, names: Array) -> bool:
	var p: PackedStringArray = state_enum_problems(names)
	if p.is_empty():
		return true
	tc.fail("S6 API missing: %s" % ", ".join(p))
	return false


# ---------------------------------------------------------------- commands

## PICK_MUTATION command: `SimCommand.pick_mutation(entity_id, node_id, tick)` (payload field `node_id`).
static func pick_cmd(entity_id: int, node_id: String, tick: int = -1) -> SimCommand:
	return SimCommand.pick_mutation(entity_id, StringName(node_id), tick)


## Node id carried by a MUTATION_PICKED event ("" when no known key holds it).
static func picked_id(ev: SimEvent) -> String:
	for key: String in ["node_id", "node", "id"]:
		if ev.data.has(key):
			return str(ev.data[key])
	return ""


static func offer_ids(ev: SimEvent) -> PackedStringArray:
	var out := PackedStringArray()
	var v: Variant = ev.data.get("offer")
	if v is Array or v is PackedStringArray:
		for x: Variant in v:
			out.append(str(x))
	return out


# ---------------------------------------------------------------- stepping and events

## One step; returns only events that were not returned before (a paused world keeps its tick).
static func step_collect(w: SimWorld, out: Array[SimEvent], seen: Dictionary) -> void:
	var t0: int = w.tick
	w.step()
	for ev: SimEvent in w.events_since(t0):
		var iid: int = ev.get_instance_id()
		if not seen.has(iid):
			seen[iid] = true
			out.append(ev)


## Steps n times. pins {id: Vector3}: position forced (velocity 0) before every step (an inert entity; brains may turn
## it). keep_alive [ids]: hp refilled after every step. probe: Callable(w) called after every step, before the pins and
## the refill (so it sees damage). Returns every new event.
static func run(w: SimWorld, n: int, pins: Dictionary = {}, keep_alive: Array[int] = [], probe: Callable = Callable()) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	var seen: Dictionary = {}
	for i in n:
		_apply_pins(w, pins)
		step_collect(w, out, seen)
		if probe.is_valid():
			probe.call(w)
		_apply_pins(w, pins)
		for kid: int in keep_alive:
			var k: SimEntity = w.get_entity(kid)
			if k != null and k.alive and k.hp > 0.0:
				k.hp = k.max_hp
	return out


static func _apply_pins(w: SimWorld, pins: Dictionary) -> void:
	for pid: int in pins.keys():
		var e: SimEntity = w.get_entity(pid)
		if e != null and e.alive:
			e.position = pins[pid]
			e.velocity = Vector3.ZERO


static func events_named(evs: Array[SimEvent], type_name: String) -> Array[SimEvent]:
	var t: int = ev_type(type_name)
	var out: Array[SimEvent] = []
	if t < 0:
		return out
	for ev: SimEvent in evs:
		if int(ev.type) == t:
			out.append(ev)
	return out


static func count_named(evs: Array[SimEvent], type_name: String) -> int:
	return events_named(evs, type_name).size()


## Order-sensitive signature of an event list (type, tick, entity, other, value to 1e-3).
static func signature(evs: Array[SimEvent]) -> int:
	var lines := PackedStringArray()
	for ev: SimEvent in evs:
		lines.append("%d:%d:%d:%d:%.3f" % [int(ev.type), ev.tick, ev.entity_id, ev.other_id, ev.value])
	return "\n".join(lines).hash()


# ---------------------------------------------------------------- band-up and picks

## Writes the XP that puts the player at the start of `band` (+1) and steps once; returns the new events. The world
## derives the band in the growth phase of that step (BAND_UP, then the offer).
static func level_to(w: SimWorld, e: SimEntity, band: int) -> Array[SimEvent]:
	e.xp = band_xp(w.content, band) + 1.0
	var out: Array[SimEvent] = []
	step_collect(w, out, {})
	return out


## Submits the pick and steps up to `max_steps` times until the world is no longer paused. Returns the new events.
static func resolve_pick(w: SimWorld, pid: int, node_id: String, max_steps: int = 3) -> Array[SimEvent]:
	w.submit(pick_cmd(pid, node_id))
	var out: Array[SimEvent] = []
	var seen: Dictionary = {}
	for i in max_steps:
		step_collect(w, out, seen)
		if not paused(w):
			break
	return out


## A player in an empty arena with `xp`, ready for band-up experiments (world seed `s`, shipped or patched data).
static func arena_player(world_seed: int, xp: float = 0.0, opts: Dictionary = {}) -> Dictionary:
	var w: SimWorld = make_world(world_seed, opts)
	var p: SimEntity = S3.player_at(w, S3.ARENA, xp)
	return {"w": w, "p": p}


# ---------------------------------------------------------------- misc geometry

## Direction on the horizontal plane `deg` degrees from `forward` around +Y (positive = to the left).
static func yaw_dir(forward: Vector3, deg: float) -> Vector3:
	return forward.rotated(Vector3.UP, deg_to_rad(deg)).normalized()
