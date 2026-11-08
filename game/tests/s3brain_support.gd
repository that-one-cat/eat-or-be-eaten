extends RefCounted
## Shared helpers for the test_s3brain_*.gd files (NPC brains, hiding, spawners). Not a test file (no `test_`
## prefix). Use via `const B := preload("res://tests/s3brain_support.gd")`. Numbers come from ContentDB.

## Mid-water inside open_water and rock_arches, ~15 m above the seabed, far from obstacles and map edges.
const ARENA: Vector3 = Vector3(150.0, -25.0, 60.0)
const MAP_ID: StringName = &"reef"


## World with a private ContentDB (the loaded dictionaries are edited in place before SimWorld reads them).
## opts: "rules": {key: value} rule overrides (a dotted key such as "tiers.interactive_cap" sets a nested value);
## "spawners": Array replacing map.spawners; "schools": Array replacing map.schools (S4); "hiding_volumes": Array
## replacing map.hiding_volumes; "species": {species_id: {key: value}} overrides; "spawn": true enables NpcSpawner.
static func make_world(world_seed: int = 1, opts: Dictionary = {}) -> SimWorld:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	var overrides: Dictionary = opts.get("rules", {})
	for k: Variant in overrides:
		_set_rule(rules, str(k), overrides[k])
	var map: Dictionary = db.get_map(MAP_ID)
	if opts.has("spawners"):
		map["spawners"] = opts["spawners"]
	if opts.has("schools"):
		map["schools"] = opts["schools"]
	if opts.has("hiding_volumes"):
		map["hiding_volumes"] = opts["hiding_volumes"]
	var sp_over: Dictionary = opts.get("species", {})
	for sid: Variant in sp_over:
		var rec: Dictionary = db.get_species(StringName(str(sid)))
		for k: Variant in (sp_over[sid] as Dictionary):
			rec[k] = sp_over[sid][k]
	var w := SimWorld.new(world_seed, db)
	if bool(opts.get("spawn", false)):
		NpcSpawner.set_enabled(w, true)
	return w


## rules[path] = value; a dotted path walks (and creates) nested dictionaries.
static func _set_rule(rules: Dictionary, path: String, value: Variant) -> void:
	var parts: PackedStringArray = path.split(".")
	var cur: Dictionary = rules
	for i in parts.size() - 1:
		if not (cur.get(parts[i]) is Dictionary):
			cur[parts[i]] = {}
		cur = cur[parts[i]]
	cur[parts[-1]] = value


## One cube hiding volume of half-size `half` around `centre`.
static func cube_volume(centre: Vector3, half: float, tag: String = "kelp") -> Dictionary:
	var lo: Vector3 = centre - Vector3.ONE * half
	var hi: Vector3 = centre + Vector3.ONE * half
	return {"id": "test_cube", "tag": tag, "aabb": {"min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]}}


static func spawner(species: String, zone: String, count: int, respawn_s: float) -> Dictionary:
	return {"species_id": species, "zone_id": zone, "count": count, "respawn_s": respawn_s}


## A player at `pos` (spawned there, so the grid entry is right from the first tick). The default length is inside
## band 1 and above 10% of a 1 m predator, so it gets bitten rather than swallowed (growth only rewrites the
## length when XP changes).
static func player(w: SimWorld, pos: Vector3, heading: Vector3 = Vector3.RIGHT, length_m: float = 0.25) -> SimEntity:
	var e: SimEntity = w.get_entity(w.spawn_entity(&"small_reef_fish", pos, length_m, true))
	e.heading = heading
	return e


## Makes `e` effectively unkillable for the test (bites still land and emit BITTEN).
static func tough(e: SimEntity) -> void:
	e.max_hp = 1.0e9
	e.hp = 1.0e9


static func npc(w: SimWorld, species: StringName, pos: Vector3, length_m: float, heading: Vector3 = Vector3.RIGHT) -> SimEntity:
	return w.get_entity(NpcSpawner.spawn_npc(w, species, pos, length_m, heading))


static func ticks(seconds: float) -> int:
	return roundi(seconds * SimWorld.TICK_RATE)


static func rule_f(w: SimWorld, path: String) -> float:
	var cur: Variant = w.content.rules()
	for part: String in path.split("."):
		cur = (cur as Dictionary).get(part) if cur is Dictionary else null
	return float(cur) if cur != null else NAN


static func species_f(w: SimWorld, species: StringName, key: String) -> float:
	return float(w.content.get_species(species).get(key, NAN))


static func behaviour_f(w: SimWorld, species: StringName, key: String) -> float:
	return float((w.content.get_species(species).get("behaviour", {}) as Dictionary).get(key, NAN))


## Steps `n` ticks; `move` = {id: [dir, boost]} re-submits a MOVE (thrust 1) and BOOST for that entity every tick.
static func step_n(w: SimWorld, n: int, move: Dictionary = {}) -> void:
	for i in n:
		for id: int in move:
			var m: Array = move[id]
			w.submit(SimCommand.move(id, m[0], 1.0, w.tick))
			w.submit(SimCommand.boost(id, bool(m[1]), w.tick))
		w.step()


## Steps until `cond.call()` is true (at most `limit` ticks); returns the ticks taken, or -1.
static func step_until(w: SimWorld, cond: Callable, limit: int, move: Dictionary = {}) -> int:
	for i in limit + 1:
		if cond.call():
			return i
		if i < limit:
			step_n(w, 1, move)
	return -1


static func bites(w: SimWorld, biter: int, victim: int, from_tick: int = 0) -> int:
	var n: int = 0
	for ev: SimEvent in w.events_since(from_tick):
		if ev.type == SimEvent.Type.BITTEN and ev.entity_id == victim and ev.other_id == biter:
			n += 1
	return n


static func zone_box(w: SimWorld, zone_id: String) -> AABB:
	for z: Variant in (w.map["zones"] as Array):
		if str((z as Dictionary)["id"]) == zone_id:
			var a: Array = z["aabb"]["min"]
			var b: Array = z["aabb"]["max"]
			var lo := Vector3(float(a[0]), float(a[1]), float(a[2]))
			return AABB(lo, Vector3(float(b[0]), float(b[1]), float(b[2])) - lo)
	return AABB()


## Living non-player creatures.
static func npcs(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e.kind == SimEntity.Kind.CREATURE and not e.is_player and e.alive:
			out.append(e)
	return out
