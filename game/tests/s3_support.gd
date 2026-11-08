extends RefCounted
## Shared helpers for the test_s3_*.gd files (res://tests/s3_support.gd). Not a test file: the runner only
## collects scripts whose name starts with "test_". Use via `const S3 := preload("res://tests/s3_support.gd")`.
## No class_name (no global class cache dependency). All tunables are read from ContentDB (data).
##
## World conventions used by every S3 test:
## - make_world() loads a PRIVATE ContentDB per world and by default EMPTIES map.spawners, so the population is
##   exactly what the test spawns. {"real_spawners": true} keeps the shipped population. ContentDB.rules() and
##   get_map() return the live dictionaries, so edits made before SimWorld.new() are what the sim reads.
## - Entities are spawned with SimWorld.spawn_entity() at their FINAL position (never teleported afterwards),
##   so the spatial grid entry is correct from the first tick. Derived fields (xp/band/length/hp) are written
##   consistently (same maths as the data), because the sim recomputes them from xp every tick.
## - Brains run for every non-player creature (no brain switch is assumed). Tests that need an inert target pin it
##   (step_n `pins`) or reset its aggro (`calm`); tests about brains leave them alone.
## - The ARENA is mid-water inside open_water AND rock_arches, 15-20 m above the seabed, >30 m from every
##   obstacle, >100 m from the map edge. Entities stay within ~20 m of it (one test uses +80 m on X).

const MAP_ID: StringName = &"reef"
const PLAYER_SPECIES: StringName = &"small_reef_fish"
const ARENA: Vector3 = Vector3(120.0, -25.0, 60.0)
## Hunger fraction given to spawned NPCs (see npc_at) and to players in exact-hp tests (no regen, no starvation).
const NPC_HUNGER_FRAC: float = 0.4

static var _content: ContentDB = null


# ---------------------------------------------------------------- data access

## Shared READ-ONLY content (never mutate it; make_world() builds its own copy).
static func content() -> ContentDB:
	if _content == null:
		_content = ContentDB.load_from_dir("res://data")
	return _content


## Dotted path into rules/core.json, e.g. rule(db, "hiding.lose_target_s"). null if missing.
static func rule(db: ContentDB, path: String) -> Variant:
	var cur: Variant = db.rules()
	for part: String in path.split("."):
		if cur is Dictionary and (cur as Dictionary).has(part):
			cur = (cur as Dictionary)[part]
		else:
			return null
	return cur


static func rule_f(db: ContentDB, path: String) -> float:
	var v: Variant = rule(db, path)
	if v == null:
		return 0.0
	return float(v)


## Seconds -> ticks (rounded), 30 Hz.
static func ticks(seconds: float) -> int:
	return int(round(seconds * 30.0))


static func bands(db: ContentDB) -> Array:
	var out: Array = []
	for i in range(1, db.band_count() + 1):
		out.append(db.get_band(i))
	return out


static func species_f(db: ContentDB, species: StringName, key: String, fallback: float = 0.0) -> float:
	return float(db.get_species(species).get(key, fallback))


## Band (1..n) whose length range contains `length_m` (clamped), as used for NPC bite power.
static func band_for_length(db: ContentDB, length_m: float) -> int:
	var n: int = db.band_count()
	for i in range(1, n + 1):
		var lm: Dictionary = db.get_band(i)["length_m"]
		if length_m <= float(lm["max"]):
			return i
	return n


# ---------------------------------------------------------------- growth reference maths

## Reference for SimRules.length_for_xp: log-scale interpolation inside the band by XP progress
## (band i spans xp_to_reach .. xp_full_length), clamped to the band-4 maximum.
static func length_ref(db: ContentDB, xp: float) -> float:
	var n: int = db.band_count()
	for i in range(1, n + 1):
		var b: Dictionary = db.get_band(i)
		var x0: float = float(b["xp_to_reach"])
		var x1: float = float(b["xp_full_length"])
		if xp <= x1 or i == n:
			var lm: Dictionary = b["length_m"]
			var lo: float = float(lm["min"])
			var hi: float = float(lm["max"])
			var frac: float = clampf((xp - x0) / (x1 - x0), 0.0, 1.0)
			return lo * pow(hi / lo, frac)
	return 0.0


## Inverse of length_ref: the XP that gives `length_m`.
static func xp_for_length(db: ContentDB, length_m: float) -> float:
	var n: int = db.band_count()
	for i in range(1, n + 1):
		var b: Dictionary = db.get_band(i)
		var lm: Dictionary = b["length_m"]
		var lo: float = float(lm["min"])
		var hi: float = float(lm["max"])
		if length_m <= hi or i == n:
			var x0: float = float(b["xp_to_reach"])
			var x1: float = float(b["xp_full_length"])
			return maxf(x0 + (x1 - x0) * log(length_m / lo) / log(hi / lo), 0.0)
	return 0.0


# ---------------------------------------------------------------- world and entity builders

## opts: "rules": Dictionary (overrides of rules/core.json; a dotted key such as "tiers.interactive_cap" sets a nested
## value), "spawners": Array (replaces map.spawners and
## switches NpcSpawner on), "hiding_volumes": Array (replaces map.hiding_volumes), "real_spawners": true (keep the
## shipped spawners and switch NpcSpawner on), "vitals": false (leave SimWorld.vitals_enabled off).
## Defaults: no spawners (NpcSpawner stays disabled, as in a plain SimWorld), vitals ON (hunger, starvation and
## regeneration are what the game loop runs with; the sim keeps them off in plain worlds).
static func make_world(world_seed: int = 1, opts: Dictionary = {}) -> SimWorld:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	var overrides: Dictionary = opts.get("rules", {})
	for k: Variant in overrides.keys():
		var parts: PackedStringArray = str(k).split(".")
		var cur: Dictionary = rules
		for i in parts.size() - 1:
			if not (cur.get(parts[i]) is Dictionary):
				cur[parts[i]] = {}
			cur = cur[parts[i]]
		cur[parts[-1]] = overrides[k]
	var map: Dictionary = db.get_map(MAP_ID)
	var spawn: bool = false
	if opts.has("spawners"):
		map["spawners"] = opts["spawners"]
		spawn = true
	elif bool(opts.get("real_spawners", false)):
		spawn = true
	else:
		map["spawners"] = []
	if opts.has("hiding_volumes"):
		map["hiding_volumes"] = opts["hiding_volumes"]
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = bool(opts.get("vitals", true))
	if spawn:
		NpcSpawner.set_enabled(w, true)
	return w


## Player entity at `pos` with xp-consistent band/length/max_hp, full hp, full hunger and full stamina.
static func player_at(w: SimWorld, pos: Vector3, xp: float = 0.0, heading: Vector3 = Vector3.RIGHT) -> SimEntity:
	var id: int = w.spawn_entity(PLAYER_SPECIES, pos, 0.1, true)
	var e: SimEntity = w.get_entity(id)
	set_growth(w, e, xp)
	e.heading = heading.normalized()
	e.hunger = rule_f(w.content, "hunger_max")
	e.stamina = float(w.content.get_ability(&"boost").get("stamina_max", 0.0))
	return e


## Writes xp, band, length, max_hp and hp the way the sim derives them (player max HP by rules.player_hp_model).
static func set_growth(w: SimWorld, e: SimEntity, xp: float) -> void:
	var db: ContentDB = w.content
	e.xp = xp
	e.band = db.band_for_xp(xp)
	e.length_m = length_ref(db, xp)
	e.max_hp = player_max_hp_ref(db, e.species_id, e.band, e.length_m)
	e.hp = e.max_hp


## Reference player max HP from data: "band" = the band's max_hp, "length2" = species base_hp * length^2.
static func player_max_hp_ref(db: ContentDB, species: StringName, band: int, length_m: float) -> float:
	if str(db.rules().get("player_hp_model", "band")) == "length2":
		return float(db.get_species(species)["base_hp"]) * length_m * length_m
	return float(db.get_band(band)["max_hp"])


## NPC of `species` at `pos`. length < 0 = middle of the species range (geometric). hp = base_hp * length^2.
## hunger = NPC_HUNGER_FRAC of the maximum (no regen, no starvation inside a test of normal length).
static func npc_at(w: SimWorld, species: StringName, pos: Vector3, length_m: float = -1.0, heading: Vector3 = Vector3.RIGHT) -> SimEntity:
	var sp: Dictionary = w.content.get_species(species)
	var lm: Dictionary = sp["length_m"]
	var length: float = length_m
	if length <= 0.0:
		length = sqrt(float(lm["min"]) * float(lm["max"]))
	var id: int = w.spawn_entity(species, pos, length, false)
	var e: SimEntity = w.get_entity(id)
	e.length_m = length
	e.max_hp = float(sp["base_hp"]) * length * length
	e.hp = e.max_hp
	# Between starvation (0) and regeneration (> 50%): hp deltas in tests are exact whatever the NPC hunger rules are.
	e.hunger = NPC_HUNGER_FRAC * rule_f(w.content, "hunger_max")
	e.heading = heading.normalized()
	return e


static func reach_m(w: SimWorld, e: SimEntity) -> float:
	return e.length_m * rule_f(w.content, "mouth_reach_mult")


static func half_cone_deg(w: SimWorld) -> float:
	return rule_f(w.content, "mouth_cone_deg")


## Player bite reach (F1): length x rules.bite_reach_mult (missing = mouth_reach_mult), before the target radius.
static func bite_reach_m(w: SimWorld, e: SimEntity) -> float:
	var v: Variant = rule(w.content, "bite_reach_mult")
	return e.length_m * (float(v) if v != null else rule_f(w.content, "mouth_reach_mult"))


## Player bite half-angle (F1): rules.bite_cone_deg (missing = mouth_cone_deg).
static func bite_half_cone_deg(w: SimWorld) -> float:
	var v: Variant = rule(w.content, "bite_cone_deg")
	return float(v) if v != null else half_cone_deg(w)


static func spawn_point(w: SimWorld, index: int) -> Vector3:
	var a: Array = (w.map["player_spawns"] as Array)[index]
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


# ---------------------------------------------------------------- stepping

## Steps `n` ticks. pins: {entity_id: Vector3} -> the entity is put back at that position (velocity zero) before
## and after every step (an inert target; brains may still turn it). keep_alive: ids whose hp is refilled after
## every step (observe events, never die by attrition). calm: ids whose aggro/brain state is reset after every
## step, so a bitten retaliator never sees the aggro (a lethal bite inside one step still kills).
## Returns every event emitted during these ticks (the world trims its log after 300 ticks, so long observation
## windows must collect as they go instead of calling events_since() at the end).
static func step_n(w: SimWorld, n: int, pins: Dictionary = {}, keep_alive: Array[int] = [], calm: Array[int] = []) -> Array[SimEvent]:
	var collected: Array[SimEvent] = []
	var calm_state: Dictionary = {}
	for cid: int in calm:
		var ce: SimEntity = w.get_entity(cid)
		if ce != null:
			calm_state[cid] = ce.brain_state
	for i in n:
		_apply_pins(w, pins)
		w.step()
		collected.append_array(w.events_since(w.tick - 1))
		_apply_pins(w, pins)
		for kid: int in keep_alive:
			var k: SimEntity = w.get_entity(kid)
			if k != null and k.alive and k.hp > 0.0:
				k.hp = k.max_hp
		for cid2: int in calm_state.keys():
			var c: SimEntity = w.get_entity(cid2)
			if c != null:
				c.aggro_target = -1
				c.aggro_until_tick = -1
				c.brain_state = int(calm_state[cid2])
	return collected


static func _apply_pins(w: SimWorld, pins: Dictionary) -> void:
	for pid: int in pins.keys():
		var e: SimEntity = w.get_entity(pid)
		if e != null and e.alive:
			e.position = pins[pid]
			e.velocity = Vector3.ZERO


# ---------------------------------------------------------------- events and queries

static func events_of(w: SimWorld, type: SimEvent.Type, from_tick: int = 0) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in w.events_since(from_tick):
		if ev.type == type:
			out.append(ev)
	return out


static func of_type(evs: Array[SimEvent], type: SimEvent.Type) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if ev.type == type:
			out.append(ev)
	return out


## Events of `type` about the pair {a, b} in a collected log.
static func pair_events(evs: Array[SimEvent], type: SimEvent.Type, a: int, b: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if ev.type == type and involves(ev, a, b):
			out.append(ev)
	return out


## True if the event is about the pair {a, b} in either role (the contract does not pin who is entity_id).
static func involves(ev: SimEvent, a: int, b: int) -> bool:
	return (ev.entity_id == a and ev.other_id == b) or (ev.entity_id == b and ev.other_id == a)


static func count_between(w: SimWorld, type: SimEvent.Type, a: int, b: int, from_tick: int = 0) -> int:
	var n: int = 0
	for ev: SimEvent in events_of(w, type, from_tick):
		if involves(ev, a, b):
			n += 1
	return n


## True if the event mentions entity `id` in either role.
static func mentions(ev: SimEvent, id: int) -> bool:
	return ev.entity_id == id or ev.other_id == id


static func is_gone(w: SimWorld, id: int) -> bool:
	var e: SimEntity = w.get_entity(id)
	return e == null or not e.alive


## Living non-player creatures (food bits excluded).
static func creatures(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id: int in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e.kind == SimEntity.Kind.CREATURE and not e.is_player and e.alive:
			out.append(e)
	return out


static func food_bits(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id: int in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e.kind == SimEntity.Kind.FOOD_BIT:
			out.append(e)
	return out


static func species_count(w: SimWorld, species: StringName) -> int:
	var n: int = 0
	for e: SimEntity in creatures(w):
		if e.species_id == species:
			n += 1
	return n


## Aggro as the brains define it: a target and an unexpired deadline.
static func is_aggro(e: SimEntity, tick: int) -> bool:
	return e.aggro_target != -1 and tick < e.aggro_until_tick


# ---------------------------------------------------------------- geometry helpers

static func box_min_max(rec: Dictionary) -> Array[Vector3]:
	var src: Dictionary = rec
	if rec.get("aabb") is Dictionary:
		src = rec["aabb"]
	var a: Array = src["min"]
	var b: Array = src["max"]
	var out: Array[Vector3] = []
	out.append(Vector3(float(a[0]), float(a[1]), float(a[2])))
	out.append(Vector3(float(b[0]), float(b[1]), float(b[2])))
	return out


static func inside_box(p: Vector3, bmin: Vector3, bmax: Vector3, margin: float = 0.0) -> bool:
	return p.x >= bmin.x - margin and p.x <= bmax.x + margin \
		and p.y >= bmin.y - margin and p.y <= bmax.y + margin \
		and p.z >= bmin.z - margin and p.z <= bmax.z + margin


static func zone_box(w: SimWorld, zone_id: String) -> Array[Vector3]:
	for z: Variant in (w.map["zones"] as Array):
		var zd: Dictionary = z
		if String(zd["id"]) == zone_id:
			return box_min_max(zd)
	var none: Array[Vector3] = []
	return none


static func hiding_volumes(w: SimWorld) -> Array:
	var v: Variant = w.map.get("hiding_volumes", [])
	if v is Array:
		return v
	return []


static func volume_tag(rec: Dictionary) -> String:
	return String(rec.get("tag", rec.get("kind", "")))


## A copy of a hiding-volume record with its box replaced (keeps whatever schema the record uses).
static func volume_with_box(rec: Dictionary, bmin: Vector3, bmax: Vector3) -> Dictionary:
	var r: Dictionary = rec.duplicate(true)
	var lo: Array = [bmin.x, bmin.y, bmin.z]
	var hi: Array = [bmax.x, bmax.y, bmax.z]
	if r.get("aabb") is Dictionary:
		(r["aabb"] as Dictionary)["min"] = lo
		(r["aabb"] as Dictionary)["max"] = hi
	else:
		r["min"] = lo
		r["max"] = hi
	return r


## A point inside the first hiding volume with `tag`, about 2 m above the seabed (Vector3.INF if none fits).
static func hiding_probe(w: SimWorld, tag: String) -> Vector3:
	for v: Variant in hiding_volumes(w):
		var rec: Dictionary = v
		if volume_tag(rec) != tag:
			continue
		var mm: Array[Vector3] = box_min_max(rec)
		# a quarter of the way in from the min corner: off the box centre, where the shipped map puts its coral rock
		var cx: float = mm[0].x + 0.25 * (mm[1].x - mm[0].x)
		var cz: float = mm[0].z + 0.25 * (mm[1].z - mm[0].z)
		var floor_y: float = w.seabed.height_at(cx, cz)
		var y: float = clampf(floor_y + 2.0, mm[0].y + 0.5, mm[1].y - 0.5)
		if y > floor_y + 0.5 and y < -0.5:
			return Vector3(cx, y, cz)
	return Vector3.INF
