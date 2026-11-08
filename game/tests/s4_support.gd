extends RefCounted
## Shared helpers for the test_s4_*.gd files (res://tests/s4_support.gd). Not a test file: the runner only collects
## scripts whose name starts with "test_". Use via `const S4 := preload("res://tests/s4_support.gd")`.
## No class_name (no global class cache dependency).
##
## API PINNED (impl-A, 2026-11-04): SchoolSystem methods are INSTANCE methods of `SimWorld.schools`
## (center_at / heading_at / member_offset / apply_event ...); PlanktonField.density_at(pos, tick = -1) is the density
## accessor; PLANKTON_EATEN.value = XP gained. Members are still reached dynamically (Object.get / .call /
## SimEvent.Type["NAME"]) so that one renamed member fails a test with a readable "S4 API missing" message instead of
## a parse error that takes the whole file down; there is no "skip if absent" branch any more.
##
## All tunables (radii, caps, periods, respawn times) are read from ContentDB (data); tests only set the values they
## need for a controlled scenario (small caps, one-school maps) through make_world() overrides.
##
## World conventions:
## - make_world() loads a PRIVATE ContentDB per world. By default it is CONTROLLED: map.spawners = [], map.schools = [],
##   plankton zones = [], rules.npc_scale = 1.0, vitals off. {"real": true} keeps the shipped map (schools, spawners, plankton) and enables NpcSpawner.
## - Players are spawned at their FINAL position (S3.player_at) and held in place with pin() (position write + zero
##   velocity before every step), the way s3_support.step_n pins targets.
## - Schools are placed by data, not by the test: the test reads center_at()/member_offset() and puts the player
##   relative to them. Test worlds use the zone "kelp_forest" (thick water column, species-legal for silver) and
##   "abyss" (far from kelp_forest) so that geometry never depends on a lucky seed.

const S3 := preload("res://tests/s3_support.gd")

const SILVER: StringName = &"silver_schooling_fish"
const REEF_FISH: StringName = &"small_reef_fish"
const KELP: String = "kelp_forest"
const ABYSS: String = "abyss"
const SHALLOWS: String = "shallows"
const SCHOOL_SCRIPT: String = "res://scripts/sim/school_system.gd"
## Tolerance (m) when comparing a promoted entity with the sim position of its member (one tick of drift + rounding).
const POS_TOL: float = 1.0
const EVENT_NAMES: Array[String] = ["SCHOOL_MEMBER_PROMOTED", "SCHOOL_MEMBER_DEMOTED", "SCHOOL_MEMBER_EATEN", "SCHOOL_MEMBER_RESPAWNED"]
const SCHOOL_METHODS: Array[String] = ["center_at", "heading_at", "member_offset", "apply_event", "get_school", "school_count"]


# ---------------------------------------------------------------- API presence (compile-safe access)

static func school_script() -> GDScript:
	if not ResourceLoader.exists(SCHOOL_SCRIPT):
		return null
	return load(SCHOOL_SCRIPT) as GDScript


static func _script_has(script: GDScript, method_name: String) -> bool:
	for m: Dictionary in script.get_script_method_list():
		if str(m["name"]) == method_name:
			return true
	return false


## -1 when SimEvent.Type has no member `name`.
static func ev_type(type_name: String) -> int:
	if SimEvent.Type.has(type_name):
		return int(SimEvent.Type[type_name])
	return -1


static func api_problems(w: SimWorld) -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in EVENT_NAMES:
		if ev_type(n) < 0:
			out.append("SimEvent.Type.%s" % n)
	var sys: Object = w.get("schools")
	if sys == null:
		out.append("SimWorld.schools")
	else:
		for m: String in SCHOOL_METHODS:
			if not sys.has_method(m):
				out.append("SchoolSystem.%s (instance method)" % m)
	return out


## Fails the calling test with a readable message and returns false when the school API is not there yet.
static func require_api(tc: TestCase, w: SimWorld) -> bool:
	var p: PackedStringArray = api_problems(w)
	if p.is_empty():
		return true
	tc.fail("S4 API missing: %s" % ", ".join(p))
	return false


static func plankton_problems(w: SimWorld) -> PackedStringArray:
	var out := PackedStringArray()
	if ev_type("PLANKTON_EATEN") < 0:
		out.append("SimEvent.Type.PLANKTON_EATEN")
	var f: Object = w.get("plankton")
	if f == null:
		out.append("SimWorld.plankton")
	else:
		for m: String in ["density_at", "density", "cell_at", "cell_center", "is_plankton_cell", "touched_cells", "cell_cap"]:
			if not f.has_method(m):
				out.append("PlanktonField.%s" % m)
	return out


static func require_plankton(tc: TestCase, w: SimWorld) -> bool:
	var p: PackedStringArray = plankton_problems(w)
	if p.is_empty():
		return true
	tc.fail("S4 API missing: %s" % ", ".join(p))
	return false


# ---------------------------------------------------------------- school accessors (all dynamic)

static func schools(w: SimWorld) -> Object:
	return w.get("schools")


static func school_count(w: SimWorld) -> int:
	var s: Object = schools(w)
	if s == null:
		return 0
	return int(s.call("school_count"))


## School object `id` of the world's SchoolSystem. Remembers which system owns the school, so that the pure
## functions below can be called as instance methods (`SimWorld.schools.center_at(school, tick)`).
static func get_school(w: SimWorld, id: int) -> Object:
	var s: Object = schools(w)
	if s == null:
		return null
	var school: Object = s.call("get_school", id)
	if school != null:
		_owner[school.get_instance_id()] = s
	return school


static var _owner: Dictionary = {}


static func _school_call(school: Object, method_name: String, args: Array) -> Variant:
	var sys: Object = _owner[school.get_instance_id()]
	return sys.callv(method_name, args)


static func center_at(school: Object, tick: int) -> Vector3:
	return _school_call(school, "center_at", [school, tick])


static func heading_at(school: Object, tick: int) -> Vector3:
	return _school_call(school, "heading_at", [school, tick])


static func member_offset(school: Object, k: int, tick: int) -> Vector3:
	return _school_call(school, "member_offset", [school, k, tick])


static func member_pos(school: Object, k: int, tick: int) -> Vector3:
	return center_at(school, tick) + member_offset(school, k, tick)


static func alive_of(school: Object) -> PackedByteArray:
	return school.get("alive")


static func promoted_of(school: Object) -> Dictionary:
	return school.get("promoted")


static func size_of(school: Object) -> int:
	return int(school.get("size"))


## Number of members in the school form (alive == 1).
static func ambient_count(school: Object) -> int:
	var n: int = 0
	for b: int in alive_of(school):
		n += b
	return n


static func school_id_of(e: SimEntity) -> int:
	var v: Variant = e.get("school_id")
	return -1 if v == null else int(v)


static func school_member_of(e: SimEntity) -> int:
	var v: Variant = e.get("school_member")
	return -1 if v == null else int(v)


# ---------------------------------------------------------------- data access

static func tier_f(w: SimWorld, key: String) -> float:
	return S3.rule_f(w.content, "tiers." + key)


## tiers.update_every_ticks as an int (>= 1).
static func period(w: SimWorld) -> int:
	return maxi(1, int(tier_f(w, "update_every_ticks")))


static func school_records(w: SimWorld) -> Array:
	var v: Variant = w.map.get("schools", [])
	return v if v is Array else []


## The map.schools record that school `id` was expanded from (records expand in map order, `count` schools each).
static func record_for_school(w: SimWorld, id: int) -> Dictionary:
	var n: int = 0
	for r_v: Variant in school_records(w):
		var r: Dictionary = r_v
		n += int(r["count"])
		if id < n:
			return r
	return {}


static func zone_box_for(w: SimWorld, id: int) -> Array[Vector3]:
	return S3.zone_box(w, String(record_for_school(w, id).get("zone_id", "")))


static func species_tier(w: SimWorld, species: StringName) -> String:
	return String(w.content.get_species(species).get("tier", ""))


static func species_schooling(db: ContentDB, species: StringName) -> bool:
	return bool(db.get_species(species).get("schooling", false))


# ---------------------------------------------------------------- world builders

static func school_rec(species: StringName, zone: String, count: int, size_min: int, size_max: int, respawn_s: float) -> Dictionary:
	return {"species_id": String(species), "zone_id": zone, "count": count, "size_min": size_min, "size_max": size_max, "respawn_s": respawn_s}


static func spawner_rec(species: String, zone: String, count: int, respawn_s: float) -> Dictionary:
	return {"species_id": species, "zone_id": zone, "count": count, "respawn_s": respawn_s}


## opts: "real": true (shipped map); "schools": Array (map.schools); "spawners": Array (map.spawners); NpcSpawner is
## always switched on (see below); "plankton_zones": Array (plankton.zones); "variation_seed": int (plankton.variation.seed
## of the shipped patch field, to prove a test does not depend on the shipped layout); "tiers": Dictionary merged into rules.tiers;
## "rules": Dictionary of top-level rule overrides; "vitals": bool (default false controlled / true real); "population": false = leave NpcSpawner.set_enabled off.
static func make_world(world_seed: int = 1, opts: Dictionary = {}) -> SimWorld:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	var map: Dictionary = db.get_map(S3.MAP_ID)
	var real: bool = bool(opts.get("real", false))
	if not real:
		rules["npc_scale"] = 1.0
		map["schools"] = opts.get("schools", [])
		map["spawners"] = opts.get("spawners", [])
		var pl: Variant = map.get("plankton")
		if pl is Dictionary:
			(pl as Dictionary)["zones"] = opts.get("plankton_zones", [])
			if opts.has("variation_seed") and (pl as Dictionary).get("variation") is Dictionary:
				((pl as Dictionary)["variation"] as Dictionary)["seed"] = int(opts["variation_seed"])
	var overrides: Dictionary = opts.get("rules", {})
	for k: Variant in overrides.keys():
		rules[k] = overrides[k]
	var tiers_o: Dictionary = opts.get("tiers", {})
	if not tiers_o.is_empty():
		var tiers: Variant = rules.get("tiers")
		if tiers is Dictionary:
			for k2: Variant in tiers_o.keys():
				(tiers as Dictionary)[k2] = tiers_o[k2]
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = bool(opts.get("vitals", real))
	# The NPC population switch also gates the schools phase (TierManager) in the implementation, so it is always on;
	# a controlled world with spawners = [] simply has nothing for the spawner to spawn.
	if bool(opts.get("population", true)):
		NpcSpawner.set_enabled(w, true)
	return w


## Controlled world with `count` silver schools of `size_min..size_max` members in `zone`.
static func school_world(world_seed: int, size_min: int, size_max: int, respawn_s: float = 4.0, zone: String = KELP, count: int = 1, opts: Dictionary = {}) -> SimWorld:
	var o: Dictionary = opts.duplicate()
	o["schools"] = [school_rec(SILVER, zone, count, size_min, size_max, respawn_s)]
	return make_world(world_seed, o)


## A B1 player standing in the middle of school `school_id` at the world's current tick.
static func player_at_school(w: SimWorld, school_id: int = 0, offset: Vector3 = Vector3.ZERO) -> SimEntity:
	var s: Object = get_school(w, school_id)
	return S3.player_at(w, center_at(s, w.tick) + offset, 0.0)


static func pin(w: SimWorld, id: int, pos: Vector3) -> void:
	var e: SimEntity = w.get_entity(id)
	if e != null and e.alive and pos.is_finite():
		e.position = pos
		e.velocity = Vector3.ZERO


## A valid player position at horizontal distance `d` from `anchor` (first of 8 directions that is inside the map
## margin and at least 3 m above the seabed, below the surface). Vector3.INF when none fits.
static func place(w: SimWorld, anchor: Vector3, d: float) -> Vector3:
	var half: float = float(w.map.get("size_m", 600.0)) * 0.5 - float((w.map.get("bounds", {}) as Dictionary).get("soft_margin_m", 40.0)) - 5.0
	for i in 8:
		var a: float = TAU * float(i) / 8.0
		var p: Vector3 = anchor + Vector3(cos(a), 0.0, sin(a)) * d
		if absf(p.x) <= half and absf(p.z) <= half and p.y < -2.0 and p.y > w.seabed.height_at(p.x, p.z) + 3.0:
			return p
	return Vector3.INF


# ---------------------------------------------------------------- stepping and events

## Steps n ticks. `pre` (Callable taking the SimWorld) runs before every tick. Returns every event emitted.
static func run(w: SimWorld, n: int, pre: Callable = Callable()) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for i in n:
		if pre.is_valid():
			pre.call(w)
		w.step()
		out.append_array(w.events_since(w.tick - 1))
	return out


static func events_named(evs: Array[SimEvent], type_name: String) -> Array[SimEvent]:
	var t: int = ev_type(type_name)
	var out: Array[SimEvent] = []
	if t < 0:
		return out
	for ev: SimEvent in evs:
		if int(ev.type) == t:
			out.append(ev)
	return out


static func school_events(evs: Array[SimEvent]) -> Array[SimEvent]:
	var types: Array[int] = []
	for n: String in EVENT_NAMES:
		types.append(ev_type(n))
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if types.has(int(ev.type)):
			out.append(ev)
	return out


static func ev_school(ev: SimEvent) -> int:
	return int(ev.data.get("school", -1))


static func ev_k(ev: SimEvent) -> int:
	return int(ev.data.get("k", -1))


## Events of `type_name` about member k of school `sid`.
static func member_events(evs: Array[SimEvent], type_name: String, sid: int, k: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in events_named(evs, type_name):
		if ev_school(ev) == sid and ev_k(ev) == k:
			out.append(ev)
	return out


## Order-sensitive signature of an event list (type, tick, ids, value, data).
static func signature(evs: Array[SimEvent]) -> int:
	var parts := PackedStringArray()
	for ev: SimEvent in evs:
		parts.append("%d:%d:%d:%d:%d:%s" % [int(ev.type), ev.tick, ev.entity_id, ev.other_id, int(round(ev.value * 1000.0)), str(ev.data)])
	return ",".join(parts).hash()


# ---------------------------------------------------------------- entity queries

static func promoted_entities(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for e: SimEntity in S3.creatures(w):
		if school_id_of(e) >= 0:
			out.append(e)
	return out


static func creatures_of_tier(w: SimWorld, tier: String) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for e: SimEntity in S3.creatures(w):
		if species_tier(w, e.species_id) == tier:
			out.append(e)
	return out


static func players(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id: int in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e.is_player and e.alive:
			out.append(e)
	return out


# ---------------------------------------------------------------- invariants and replay

## "" when the school bookkeeping is consistent, else the first problem found:
## alive.size() == size; every promoted member has alive == 0 and a living entity that points back to it;
## every living entity with school_id >= 0 is listed in that school's promoted dictionary.
static func invariants(w: SimWorld) -> String:
	var listed: int = 0
	for sid in school_count(w):
		var s: Object = get_school(w, sid)
		var alive: PackedByteArray = alive_of(s)
		if alive.size() != size_of(s):
			return "school %d: alive.size() %d != size %d" % [sid, alive.size(), size_of(s)]
		var promoted: Dictionary = promoted_of(s)
		for k_v: Variant in promoted.keys():
			var k: int = int(k_v)
			listed += 1
			if k < 0 or k >= alive.size():
				return "school %d: promoted member %d out of range" % [sid, k]
			if alive[k] != 0:
				return "school %d: member %d is promoted but alive == 1" % [sid, k]
			var e: SimEntity = w.get_entity(int(promoted[k_v]))
			if e == null or not e.alive:
				return "school %d: promoted member %d points at a missing or dead entity %s" % [sid, k, promoted[k_v]]
			if school_id_of(e) != sid or school_member_of(e) != k:
				return "school %d: entity %d back-reference is (%d, %d), expected (%d, %d)" % [sid, e.id, school_id_of(e), school_member_of(e), sid, k]
	var with_ref: int = 0
	for e2: SimEntity in promoted_entities(w):
		with_ref += 1
	if with_ref != listed:
		return "%d living entities carry a school_id but the schools list %d promoted members" % [with_ref, listed]
	return ""


## {school id: {"alive": PackedByteArray copy, "promoted": sorted Array of member indices}} of the live world.
static func snapshot(w: SimWorld) -> Dictionary:
	var out: Dictionary = {}
	for sid in school_count(w):
		var s: Object = get_school(w, sid)
		var keys: Array = promoted_of(s).keys()
		var ks: Array[int] = []
		for k: Variant in keys:
			ks.append(int(k))
		ks.sort()
		out[sid] = {"alive": alive_of(s).duplicate(), "promoted": ks}
	return out


## Test-side reducer: school state from an event list alone (every member starts in the school form).
## PROMOTED -> alive 0 + promoted; DEMOTED -> alive 1; EATEN -> alive 0, not promoted; RESPAWNED -> alive 1.
static func replay(evs: Array[SimEvent], sizes: Dictionary) -> Dictionary:
	var alive: Dictionary = {}
	var promoted: Dictionary = {}
	for sid_v: Variant in sizes.keys():
		var a := PackedByteArray()
		a.resize(int(sizes[sid_v]))
		a.fill(1)
		alive[sid_v] = a
		promoted[sid_v] = {}
	var t_promoted: int = ev_type("SCHOOL_MEMBER_PROMOTED")
	var t_demoted: int = ev_type("SCHOOL_MEMBER_DEMOTED")
	var t_eaten: int = ev_type("SCHOOL_MEMBER_EATEN")
	var t_respawned: int = ev_type("SCHOOL_MEMBER_RESPAWNED")
	for ev: SimEvent in evs:
		var t: int = int(ev.type)
		if t != t_promoted and t != t_demoted and t != t_eaten and t != t_respawned:
			continue
		var sid: int = ev_school(ev)
		var k: int = ev_k(ev)
		if not alive.has(sid):
			continue
		var a2: PackedByteArray = alive[sid]
		if k < 0 or k >= a2.size():
			continue
		if t == t_promoted:
			a2[k] = 0
			(promoted[sid] as Dictionary)[k] = true
		elif t == t_demoted:
			a2[k] = 1
			(promoted[sid] as Dictionary).erase(k)
		elif t == t_eaten:
			a2[k] = 0
			(promoted[sid] as Dictionary).erase(k)
		else:
			a2[k] = 1
		alive[sid] = a2
	var out: Dictionary = {}
	for sid2: Variant in alive.keys():
		var ks: Array[int] = []
		for k2: Variant in (promoted[sid2] as Dictionary).keys():
			ks.append(int(k2))
		ks.sort()
		out[sid2] = {"alive": alive[sid2], "promoted": ks}
	return out


## Feeds `evs` (in order) to a world's SchoolSystem.apply_event.
static func apply_events(w: SimWorld, evs: Array[SimEvent]) -> void:
	var sys: Object = schools(w)
	for ev: SimEvent in evs:
		sys.call("apply_event", ev)


static func sizes_of(w: SimWorld) -> Dictionary:
	var out: Dictionary = {}
	for sid in school_count(w):
		out[sid] = size_of(get_school(w, sid))
	return out


# ---------------------------------------------------------------- plankton

## Density at a position (PlanktonField.density_at, current tick).
static func density_at(w: SimWorld, pos: Vector3) -> float:
	return float((w.get("plankton") as Object).call("density_at", pos))


## Maximum density of the cell at a position (PlanktonField.cell_cap: density_max x the patch multiplier of its
## column; 0 outside the plankton zones). A fresh cell starts at its cap, an eaten one regrows to it.
static func cell_cap(w: SimWorld, pos: Vector3) -> float:
	var f: Object = w.get("plankton")
	return float(f.call("cell_cap", f.call("cell_at", pos)))


static func plankton_cfg(w: SimWorld) -> Dictionary:
	var v: Variant = w.map.get("plankton", {})
	return v if v is Dictionary else {}


## A point inside the first listed plankton zone, snapped to a cell centre, in open water, with density > 0.
## Vector3.INF if no candidate qualifies.
static func plankton_probe(w: SimWorld) -> Vector3:
	var cfg: Dictionary = plankton_cfg(w)
	var zones: Array = cfg.get("zones", [])
	var cell: float = float(cfg.get("cell_m", 8.0))
	for z_v: Variant in zones:
		var box: Array[Vector3] = S3.zone_box(w, String(z_v))
		if box.size() != 2:
			continue
		var cx: float = (box[0].x + box[1].x) * 0.5
		var cz: float = (box[0].z + box[1].z) * 0.5
		for dz in [0, 1, -1, 2, -2]:
			for dx in [0, 1, -1, 2, -2]:
				var x: float = (floorf(cx / cell) + 0.5 + float(dx)) * cell
				var z: float = (floorf(cz / cell) + 0.5 + float(dz)) * cell
				var floor_y: float = w.seabed.height_at(x, z)
				for dy in [0, 1, -1, 2]:
					var y: float = (floorf((floor_y + 3.0) / cell) + 0.5 + float(dy)) * cell
					if y > floor_y + 2.0 and y < -1.0 and y >= box[0].y and y <= box[1].y and density_at(w, Vector3(x, y, z)) > 0.0:
						return Vector3(x, y, z)
	return Vector3.INF
