extends RefCounted
## Shared helpers for the test_food_*.gd / test_krill_*.gd files (res://tests/food_support.gd). Not a test file: the
## runner only collects scripts whose name starts with "test_". Use via `const F := preload("res://tests/food_support.gd")`.
## No class_name (no global class cache dependency).
##
## Task: tasks/food-eggs-snails-krill.md (eggs, snails, krill clouds, hard sessile prey). Contract: research section 7.4
## (tasks/archive/2026-11/mvp/research/food-eggs-snails-krill-1104/research-summary.md). The implementation (FoodSites, FoodPlacement, krill
## PlanktonField blocks, data/food/*.json) did NOT exist when these tests were written, so:
##  - Every access to a not-yet-existing class, method, property, event or file goes through THIS file and is DYNAMIC
##    (load(path), Object.call/get, SimEvent.Type.has). A missing piece is reported as PENDING (printed, test passes)
##    or, with FOOD_STRICT=1 in the environment (or `-- --food-strict`), as a FAILURE. Run strict after the impl merge.
##  - Everything the contract does NOT freeze is collected in the NAME TABLE below ("ADAPT" markers): fix the name once
##    here after the implementation lands, the test files stay untouched.
##
## World conventions: make_world() builds a PRIVATE ContentDB and a CONTROLLED world (no spawners, no schools, no
## plankton, no krill unless asked, vitals off). Food sites come from the shipped baked file, or (preferred, if the impl
## offers FoodSites.from_records) from ONE injected site in open water at S3.ARENA, so rock geometry never matters.
## Players are spawned at their FINAL position (S3.player_at) and held with S4.pin() before every tick.
## Expectations are computed from data (the food record, rules/core.json, size bands) with SimRules, never hard-coded.

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const S5 := preload("res://tests/s5_support.gd")

# ======================================================================= NAME TABLE (ADAPT after impl lands)

const MAP_ID: StringName = &"reef"
## Scripts (class_name files; loaded by path so a missing file is PENDING, not a parse error).
const SITES_SCRIPT: String = "res://scripts/sim/food_sites.gd"
const PLACEMENT_SCRIPT: String = "res://scripts/world/food_placement.gd"
const VIEW_SCRIPT: String = "res://scripts/world/food_site_view.gd"
const BOT_SCRIPT: String = "res://tests/bots/bot_player.gd"
const TRACKER_SCRIPT: String = "res://scripts/ui/target_bar_tracker.gd"
const TUTORIAL_SCRIPT: String = "res://scripts/ui/tutorial_hints.gd"
const AUDIO_SCRIPT: String = "res://scripts/audio/audio_director.gd"
const PLANKTON_SCRIPT: String = "res://scripts/sim/plankton_field.gd"
## Data (frozen: research 2.1, 3.1).
const FOOD_DATA_DIR: String = "res://data/food"
const BAKED_FOOD_PATH: String = "res://data/maps/reef_food.json"
const SFX_DIRS: Array[String] = ["res://assets/audio/sfx/crunch", "res://assets/audio/sfx/gulp"]
## ContentDB.validate_record kind of data/food/*.json (research 3.2: "add the kind to validate_record's list").
const FOOD_KIND: StringName = &"food"
## Keys a food record must have (merged schema, game/data/README.md "Food keys": the non-defaulted ones; the contract
## draft had a single `piece`, the data has a `pieces` list of {id, zones?, above_y?, below_y?}; radius_m and sfx are required too).
const REQUIRED_FOOD_KEYS: Array[String] = ["id", "kind", "pieces", "length_m", "radius_m", "xp", "respawn_s", "sfx"]
## Key of the piece list in a food record.
const FOOD_PIECES_KEY: String = "pieces"
## Event names (research 5.1).
const EV_BITTEN: String = "SITE_BITTEN"
const EV_EATEN: String = "SITE_EATEN"
const EV_RESPAWNED: String = "SITE_RESPAWNED"
## FoodSites API (research 7.4) and the world members.
const SITES_METHODS: Array[String] = ["site_count", "site_type", "site_pos", "site_radius", "site_alive", "site_hp", "site_max_hp", "sites_near_into", "write_state"]
## Food type ids that research 2.2 / 3.3 name explicitly. Other egg / snail ids are DISCOVERED from data/food/*.json
## through their `piece`, never by name.
const T_STARFISH: StringName = &"starfish"
const T_CONE: StringName = &"cone_shell"
const T_CLAM: StringName = &"giant_clam"
## Adapted to the merged data (X1): one soft type per egg family (egg_roe = a21 mound + a22 ring, egg_kelp, egg_pearl,
## egg_glow) and ONE snail type with three colour-way pieces. The constant names keep the contract's wording.
const T_EGG_PEACH: StringName = &"egg_roe"
const T_EGG_RING: StringName = &"egg_roe"
const T_SNAIL_ORANGE: StringName = &"snail"
## Decor piece -> food type (research 2.2 `food.edible_decor`; Q2: ALL of them are edible).
const DECOR_PIECES: Dictionary = {"a14_starfish": "starfish", "a15_cone_shells": "cone_shell", "a13_giant_clam": "giant_clam"}
## Egg / snail pieces (research 6.2) grouped by the biome test they belong to.
const EGG_PIECES_A: Array[String] = ["a21_egg_roe_mound", "a22_egg_roe_ring"]
const EGG_PIECES_B_KELP: Array[String] = ["b_egg_capsules", "b_egg_ribbon"]
const EGG_PIECES_B_ARCH: Array[String] = ["b_egg_pearls", "b_egg_lavender"]
const EGG_PIECES_C: Array[String] = ["c19_egg_glow_cyan", "c20_egg_glow_violet"]
const SNAIL_ORANGE_PIECE: String = "a23_snail_orange"
const SNAIL_CYAN_PIECE: String = "c21_snail_cyan"
const SNAIL_VIOLET_PIECE: String = "c22_snail_violet"
## Q4: cyan snails above this y, violet below.
const SNAIL_SPLIT_Y: float = -65.0
## Palette rows / glow flags per piece (research 6.4, 7.3): piece -> [row, glow].
const PIECE_ROWS: Dictionary = {
	"a21_egg_roe_mound": [34, false], "a22_egg_roe_ring": [34, false], "b_egg_capsules": [34, false], "b_egg_ribbon": [34, false],
	"b_egg_pearls": [34, false], "b_egg_lavender": [34, false], "a23_snail_orange": [34, false],
	"c19_egg_glow_cyan": [37, true], "c21_snail_cyan": [37, true], "c20_egg_glow_violet": [38, true], "c22_snail_violet": [38, true]}
## Pieces that host authored pearl strands: set-piece `piece` values (research 2.4: 4 arches, the cave, 2 stone arches).
const PEARL_HOST_PIECES: Array[String] = ["b_arch_natural", "b_cave", "c05_stone_arch"]
## Per-biome minimum counts (research 7.5 item 2). Tune only with the bake printout in hand.
const MIN_EGGS_A: int = 300
const MIN_EGGS_B_KELP: int = 80
const MIN_EGGS_C: int = 150
const MIN_SITES_NEAR_SPAWN: int = 6
const NEAR_SPAWN_M: float = 40.0
## Krill (research 3.5).
const KRILL_SPECIES: Array[StringName] = [&"krill_shallows", &"krill_open", &"krill_abyss"]
const KRILL_ZONES: Array[String] = ["krill_shallows", "krill_open", "krill_abyss"]
## Property / key names that are NOT frozen. ADAPT here.
const WORLD_FOOD: String = "food"
const WORLD_KRILL: String = "krill"
const TRACKER_KEY_CONST: String = "FOOD_KEY_BASE"   # research 5.1 draft: ids hold FOOD_KEY_BASE + site
const TRACKER_KEY_FUNC: String = "site_key"         # merged: static TargetBarTracker.site_key(site) = -1 - site
const DRESSING_FOOD_KEY: String = "food"
## Baked site record (maps/<map>_food.json): the rule that produced it ("decor" | "authored" | food rule id) and the host
## placement index (MapDressing.compute_placements order; `host_ref` = the set piece id of an authored anchor is derived).
const SITE_RULE_KEY: String = "rule"
const SITE_HOST_KEY: String = "host"
const MAP_KRILL_KEY: String = "krill"
const FIELD_KEY: String = "field"                    # PLANKTON_EATEN.data.field (0 = plankton, 1.. = krill order)

const POS_TOL: float = 5e-3
const TMP_ROOT: String = "user://food_data_tmp"


# ======================================================================= pending / strict

static func strict() -> bool:
	return OS.get_environment("FOOD_STRICT") == "1" or OS.get_cmdline_user_args().has("--food-strict")


## Reports a missing piece of the implementation. Lenient: prints PENDING and the test passes. Strict: the test fails.
static func pending(tc: TestCase, what: String) -> void:
	if strict():
		tc.fail("PENDING (strict mode): %s" % what)
	else:
		print("PENDING %s: %s" % [tc.current_test, what])


## True when `problems` is empty, else reports them as pending and returns false.
static func require(tc: TestCase, problems: PackedStringArray) -> bool:
	if problems.is_empty():
		return true
	pending(tc, "implementation missing: " + ", ".join(problems))
	return false


# ======================================================================= dynamic API access

static func script_at(path: String) -> GDScript:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as GDScript


static func script_has(script: GDScript, method_name: String) -> bool:
	if script == null:
		return false
	for m: Dictionary in script.get_script_method_list():
		if str(m["name"]) == method_name:
			return true
	return false


static func script_const(script: GDScript, const_name: String) -> Variant:
	if script == null:
		return null
	return script.get_script_constant_map().get(const_name)


## Problems that stop every food-site sim test (empty = the impl is in).
static func food_problems(w: SimWorld) -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in [EV_BITTEN, EV_EATEN, EV_RESPAWNED]:
		if S4.ev_type(n) < 0:
			out.append("SimEvent.Type.%s" % n)
	if not w.content.has_method("get_food"):
		out.append("ContentDB.get_food")
	var food: Object = w.get(WORLD_FOOD)
	if food == null:
		out.append("SimWorld.%s (non-null for the shipped map)" % WORLD_FOOD)
	else:
		for m: String in SITES_METHODS:
			if not food.has_method(m):
				out.append("FoodSites.%s" % m)
	return out


static func krill_problems(w: SimWorld) -> PackedStringArray:
	var out := PackedStringArray()
	var k: Variant = w.get(WORLD_KRILL)
	if not (k is Array):
		out.append("SimWorld.%s (Array[PlanktonField])" % WORLD_KRILL)
	if not script_has(script_at(PLANKTON_SCRIPT), "create_block"):
		out.append("PlanktonField.create_block")
	return out


static func require_food(tc: TestCase, w: SimWorld) -> bool:
	return require(tc, food_problems(w))


static func require_krill(tc: TestCase, w: SimWorld) -> bool:
	return require(tc, krill_problems(w))


static func require_script(tc: TestCase, path: String, methods: Array[String] = []) -> GDScript:
	var s: GDScript = script_at(path)
	var missing := PackedStringArray()
	if s == null:
		missing.append("script %s" % path)
	else:
		for m: String in methods:
			if not script_has(s, m):
				missing.append("%s.%s" % [path.get_file(), m])
	if not require(tc, missing):
		return null
	return s


static func content_ready(tc: TestCase) -> bool:
	return require(tc, PackedStringArray([] if ContentDB.new().has_method("get_food") else ["ContentDB.get_food"]))


static func food_of(w: SimWorld) -> Object:
	return w.get(WORLD_FOOD)


static func krill_of(w: SimWorld) -> Array:
	var v: Variant = w.get(WORLD_KRILL)
	return v if v is Array else []


# ======================================================================= data access

static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func write_json(path: String, value: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(value, "\t"))
	f.close()


## data/food/*.json as {id: record} (empty when the folder is absent).
static func food_records() -> Dictionary:
	var out: Dictionary = {}
	var d: DirAccess = DirAccess.open(FOOD_DATA_DIR)
	if d == null:
		return out
	var files: Array[String] = []
	for f: String in d.get_files():
		if f.get_extension() == "json":
			files.append(f)
	files.sort()
	for f2: String in files:
		var rec: Variant = read_json(FOOD_DATA_DIR.path_join(f2))
		if rec is Dictionary:
			(rec as Dictionary)["_file"] = f2
			out[str((rec as Dictionary).get("id", f2.get_basename()))] = rec
	return out


## The live record the sim reads (ContentDB.get_food, same contract as get_map: live dictionary).
static func food_record(db: ContentDB, type: StringName) -> Dictionary:
	if not db.has_method("get_food"):
		return {}
	var v: Variant = db.call("get_food", type)
	return v if v is Dictionary else {}


## Piece ids a food record lists (`pieces: [{id, ...}]`).
static func record_pieces(rec: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var list: Variant = rec.get(FOOD_PIECES_KEY)
	if list is Array:
		for e: Variant in (list as Array):
			if e is Dictionary:
				out.append(str((e as Dictionary).get("id", "")))
	return out


## Records that list at least one of `pieces` (types are discovered by piece, never by name).
static func types_of_pieces(pieces: Array[String]) -> Array[StringName]:
	var out: Array[StringName] = []
	var recs: Dictionary = food_records()
	var ids: Array = recs.keys()
	ids.sort()
	for id_v: Variant in ids:
		for pid: String in record_pieces(recs[id_v]):
			if pieces.has(pid):
				out.append(StringName(str(id_v)))
				break
	return out


## The rule that produced a baked site record ("decor", "authored" or a dressing food rule id).
static func site_rule(site: Dictionary) -> String:
	return str(site.get(SITE_RULE_KEY, ""))


## Set piece id hosting an authored site (baked record `host` = placement index into `placements`); "" otherwise.
static func site_host_ref(site: Dictionary, placements: Array) -> String:
	var hi: int = int(site.get(SITE_HOST_KEY, -1))
	if hi < 0 or hi >= placements.size():
		return ""
	var h: Dictionary = placements[hi]
	return str(h.get("id", "")) if str(h.get("kind", "")) == "set_piece" else ""


static func good_food_record() -> Dictionary:
	return {"id": "zz_test_food", "name": "Test food", "kind": "hard", "pieces": [{"id": "a14_starfish"}], "length_m": 0.1, "radius_m": 0.08,
		"base_hp": 100, "hp_mult": 2.0, "xp": 3, "hunger_xp": 3, "xp_band_mult": [1, 1, 0.5, 0.2], "respawn_s": 240, "regen_s": 20, "sfx": "crunch"}


static func box_of(map: Dictionary, zone_id: String) -> Array[Vector3]:
	for z: Variant in (map.get("zones", []) as Array):
		var zd: Dictionary = z
		if str(zd.get("id", "")) == zone_id:
			var a: Array = zd["aabb"]["min"]
			var b: Array = zd["aabb"]["max"]
			return [Vector3(float(a[0]), float(a[1]), float(a[2])), Vector3(float(b[0]), float(b[1]), float(b[2]))]
	var none: Array[Vector3] = []
	return none


## xz containment with a margin (hosts sit on zone edges; offsets can leave the box by a little).
static func in_zone_xz(map: Dictionary, zone_id: String, p: Vector3, margin: float = 2.0) -> bool:
	var box: Array[Vector3] = box_of(map, zone_id)
	if box.size() != 2:
		return false
	return p.x >= box[0].x - margin and p.x <= box[1].x + margin and p.z >= box[0].z - margin and p.z <= box[1].z + margin


static func boxes_overlap(a: Array[Vector3], b: Array[Vector3]) -> bool:
	return a[0].x < b[1].x and a[1].x > b[0].x and a[0].y < b[1].y and a[1].y > b[0].y and a[0].z < b[1].z and a[1].z > b[0].z


# ======================================================================= expected values (from data + SimRules)

static func xp_falloff(db: ContentDB) -> Dictionary:
	var v: Variant = S3.rule(db, "xp_falloff")
	return v if v is Dictionary else {}


static func expect_max_hp(rec: Dictionary) -> float:
	return SimRules.creature_max_hp(float(rec.get("base_hp", 100.0)), float(rec["length_m"])) * float(rec.get("hp_mult", 1.0))


static func band_mult(rec: Dictionary, band: int) -> float:
	var bm: Variant = rec.get("xp_band_mult")
	if bm is Array and (bm as Array).size() >= band and band >= 1:
		return float((bm as Array)[band - 1])
	return 1.0


static func expect_xp(db: ContentDB, player: SimEntity, rec: Dictionary) -> float:
	return SimRules.xp_gain(float(rec["xp"]) * band_mult(rec, player.band), player.length_m, float(rec["length_m"]), xp_falloff(db))


static func expect_hunger(db: ContentDB, rec: Dictionary) -> float:
	return SimRules.hunger_from_xp(float(rec.get("hunger_xp", rec["xp"])), S3.rule_f(db, "hunger_per_xp"))


## Damage of one player bite (same maths as SimWorld._bite for a player without mutations).
static func bite_dmg(w: SimWorld, player: SimEntity) -> float:
	var power: float = float(w.content.get_band(player.band)["bite_power"])
	var mult: float = float(w.content.get_species(player.species_id).get("bite_mult", 1.0))
	return SimRules.bite_damage(power, player.length_m, mult) * player.bite_power_mult


static func bites_to_kill(max_hp: float, dmg: float) -> int:
	return int(ceil(max_hp / dmg - 1e-9))


static func cooldown_ticks(db: ContentDB) -> int:
	return S3.ticks(S3.rule_f(db, "bite_cooldown_s"))


# ======================================================================= worlds

## opts: "seed" via the argument; "food_override": {type: {key: value}} (written into the LIVE record before SimWorld.new);
## "krill": Array (replaces map.krill; default: [] in a controlled world); "real": true (shipped population, krill
## and plankton kept); "vitals": bool (default false); "rules": top-level rules/core.json overrides.
static func make_world(world_seed: int = 1, opts: Dictionary = {}) -> SimWorld:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	var map: Dictionary = db.get_map(MAP_ID)
	var real: bool = bool(opts.get("real", false))
	if not real:
		rules["npc_scale"] = 1.0
		map["schools"] = []
		map["spawners"] = []
		var pl: Variant = map.get("plankton")
		if pl is Dictionary:
			(pl as Dictionary)["zones"] = []
		map[MAP_KRILL_KEY] = []
	if opts.has("krill"):
		map[MAP_KRILL_KEY] = opts["krill"]
	var ro: Dictionary = opts.get("rules", {})
	for k: Variant in ro.keys():
		rules[k] = ro[k]
	var fo: Dictionary = opts.get("food_override", {})
	for t: Variant in fo.keys():
		var rec: Dictionary = food_record(db, StringName(str(t)))
		var edits: Dictionary = fo[t]
		for ek: Variant in edits.keys():
			rec[ek] = edits[ek]
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = bool(opts.get("vitals", real))
	NpcSpawner.set_enabled(w, true)
	return w


## A uniform (no `variation`) krill block over `zones`, shaped like map.plankton (research 3.5).
static func krill_block(species: StringName, zones: Array, overrides: Dictionary = {}) -> Dictionary:
	var b: Dictionary = {"species_id": String(species), "zones": zones, "cell_m": 4.0, "density_max": 1.0, "regrow_per_s": 0.02,
		"eat_per_tick": 0.1, "min_eat_density": 0.1, "xp_per_unit": 0.8, "hunger_per_unit": 5.0}
	for k: Variant in overrides.keys():
		b[k] = overrides[k]
	return b


# ======================================================================= site selection and scenes

## ONE site of `type`: {"id", "pos", "injected"} or {}. Prefers an injected site in open water at S3.ARENA
## (FoodSites.from_records, ADAPT the record shape if needed); otherwise the first isolated live real site whose
## column above is free (approach from above works).
static func place_site(w: SimWorld, type: StringName) -> Dictionary:
	var rec: Dictionary = food_record(w.content, type)
	if rec.is_empty():
		return {}
	var s: GDScript = script_at(SITES_SCRIPT)
	if script_has(s, "from_records"):
		var pieces: Array[String] = record_pieces(rec)
		var one: Dictionary = {"type": String(type), "piece": pieces[0] if not pieces.is_empty() else "", "variant": 1,
			"pos": [S3.ARENA.x, S3.ARENA.y, S3.ARENA.z], "radius": float(rec.get("radius_m", 0.1)), "rot_y": 0.0, "scale": 1.0}
		var inj: Variant = s.call("from_records", w.content, [one], S3.rule_f(w.content, "grid_cell_m"))
		if inj != null:
			(inj as Object).set("now_tick", w.tick)
			w.set(WORLD_FOOD, inj)
			return {"id": 0, "pos": S3.ARENA, "injected": true}
	var food: Object = food_of(w)
	if food == null:
		return {}
	var buf := PackedInt32Array()
	var fallback: Dictionary = {}
	var n: int = int(food.call("site_count"))
	for i in n:
		if StringName(str(food.call("site_type", i))) != type or not bool(food.call("site_alive", i)):
			continue
		var p: Vector3 = food.call("site_pos", i)
		if not w.seabed.obstacle_clear(p + Vector3.UP * 0.5, 0.3):
			continue
		food.call("sites_near_into", p, 1.5, buf)
		if buf.size() <= 1:
			return {"id": i, "pos": p, "injected": false}
		if fallback.is_empty():
			fallback = {"id": i, "pos": p, "injected": false}
	return fallback


## {"pos", "heading"} of a free point `dist` away from `site` (from above first), heading toward the site; {} if none.
static func approach(w: SimWorld, site: Vector3, dist: float, clearance: float = 0.03) -> Dictionary:
	var dirs: Array[Vector3] = [Vector3.UP, Vector3(1, 1, 0).normalized(), Vector3(-1, 1, 0).normalized(), Vector3(0, 1, 1).normalized(),
		Vector3(0, 1, -1).normalized(), Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]
	for d: Vector3 in dirs:
		var p: Vector3 = site + d * dist
		if p.y < -1.0 and p.y > w.seabed.height_at(p.x, p.z) + clearance and w.seabed.obstacle_clear(p, clearance):
			return {"pos": p, "heading": -d}
	return {}


## The standard scene: {"w", "id", "site", "pid", "player", "rec", "pos"} or {} (pending / failure already reported).
## opts: "override" (food record edits), "length" (player length m, default 0.1), "frac" (distance as a fraction of the
## reach, default 0.5), "away": true (heading turned 180 degrees), "seed", "hunger_frac" (default 0.4).
static func scene(tc: TestCase, type: StringName, opts: Dictionary = {}) -> Dictionary:
	var fo: Dictionary = {}
	if opts.has("override"):
		fo[type] = opts["override"]
	var w: SimWorld = make_world(int(opts.get("seed", 301)), {"food_override": fo})
	if not require_food(tc, w):
		return {}
	var rec: Dictionary = food_record(w.content, type)
	if rec.is_empty():
		pending(tc, "food type '%s' not in data/food" % type)
		return {}
	var site: Dictionary = place_site(w, type)
	if site.is_empty():
		tc.fail("no usable site of type '%s' in the world" % type)
		return {}
	var length: float = float(opts.get("length", 0.1))
	var reach: float = length * (S3.rule_f(w.content, "bite_reach_mult") if str(rec.get("kind", "")) == "hard" else S3.rule_f(w.content, "mouth_reach_mult"))
	var dist: float = (reach + float(rec.get("radius_m", 0.0))) * float(opts.get("frac", 0.5))
	var a: Dictionary = approach(w, site["pos"], dist)
	if a.is_empty():
		tc.fail("no free approach point around site %s of '%s'" % [site["id"], type])
		return {}
	var heading: Vector3 = a["heading"]
	if bool(opts.get("away", false)):
		heading = -heading
	var player: SimEntity = S3.player_at(w, a["pos"], S3.xp_for_length(w.content, length), heading)
	player.hunger = float(opts.get("hunger_frac", 0.4)) * S3.rule_f(w.content, "hunger_max")
	return {"w": w, "id": int(site["id"]), "site": site, "pid": player.id, "player": player, "rec": rec, "pos": a["pos"]}


## Steps `n` ticks. pins {entity id: Vector3} are re-applied before every tick; ids in `bite_ids` submit a "best in cone"
## bite every tick (the hold-repeat of PlayerInput). Returns every event of those ticks.
static func run(w: SimWorld, n: int, pins: Dictionary = {}, bite_ids: Array[int] = []) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for i in n:
		for pid: int in pins.keys():
			S4.pin(w, pid, pins[pid])
		for bid: int in bite_ids:
			w.submit(SimCommand.bite(bid, -1))
		w.step()
		out.append_array(w.events_since(w.tick - 1))
	return out


static func named(evs: Array[SimEvent], type_name: String) -> Array[SimEvent]:
	return S4.events_named(evs, type_name)


## Events of `type_name` about site `site_id` (data.site).
static func named_for(evs: Array[SimEvent], type_name: String, site_id: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in named(evs, type_name):
		if int(ev.data.get("site", -1)) == site_id:
			out.append(ev)
	return out


static func site_alive(w: SimWorld, i: int, at_tick: int = -1) -> bool:
	return bool(food_of(w).call("site_alive", i, at_tick))


static func site_hp(w: SimWorld, i: int, at_tick: int = -1) -> float:
	return float(food_of(w).call("site_hp", i, at_tick))


static func site_max_hp(w: SimWorld, i: int) -> float:
	return float(food_of(w).call("site_max_hp", i))


static func food_state_bytes(w: SimWorld) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	food_of(w).call("write_state", buf, w.tick)
	return buf.data_array


static func field_state_bytes(field: Object, at_tick: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	field.call("write_state", buf, at_tick)
	return buf.data_array


# ======================================================================= temp data copies (schema / cross-reference tests)

static func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "import" or f.get_extension() == "uid":
			continue
		var data: PackedByteArray = FileAccess.get_file_as_bytes(src.path_join(f))
		var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
		out.store_buffer(data)
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


## Fresh copy of res://data in user://, handed to `edit` (Callable taking the root path), then loaded. The caller's
## `after_each` should call cleanup_temp().
static func db_with(edit: Callable) -> ContentDB:
	_remove_dir(TMP_ROOT)
	_copy_dir("res://data", TMP_ROOT)
	edit.call(TMP_ROOT)
	return ContentDB.load_from_dir(TMP_ROOT)


static func cleanup_temp() -> void:
	_remove_dir(TMP_ROOT)


static func errors_mention(db: ContentDB, needle: String) -> bool:
	for e: String in db.errors:
		if e.contains(needle):
			return true
	return false


# ======================================================================= krill helpers

## A point at the centre of a cell of `field` with cap > 0 inside the zone box of `zone_id`, or Vector3.INF.
static func krill_probe(w: SimWorld, field: Object, zone_id: String) -> Vector3:
	var box: Array[Vector3] = box_of(w.map, zone_id)
	if box.size() != 2:
		return Vector3.INF
	var cell: float = float(field.get("cell_m"))
	var cx: float = (box[0].x + box[1].x) * 0.5
	var cz: float = (box[0].z + box[1].z) * 0.5
	for dz in [0, 1, -1, 2, -2, 3, -3]:
		for dx in [0, 1, -1, 2, -2, 3, -3]:
			var x: float = (floorf(cx / cell) + 0.5 + float(dx)) * cell
			var z: float = (floorf(cz / cell) + 0.5 + float(dz)) * cell
			var floor_y: float = w.seabed.height_at(x, z)
			for dy in [0, 1, -1, 2, -2]:
				var y: float = (floorf((floor_y + 3.0) / cell) + 0.5 + float(dy)) * cell
				if y > floor_y + 2.0 and y < -1.0 and y >= box[0].y and y <= box[1].y:
					var p := Vector3(x, y, z)
					if float(field.call("density_at", p)) > 0.0:
						return p
	return Vector3.INF


## A point with no krill density and no food site within 6 m (a "control" position that eats nothing). Candidates: the
## abyss and a coarse grid; falls back to the abyss centre.
static func quiet_point(w: SimWorld) -> Vector3:
	var cands: Array[Vector3] = []
	var abyss: Array[Vector3] = box_of(w.map, "abyss")
	if abyss.size() == 2:
		cands.append((abyss[0] + abyss[1]) * 0.5)
	for x in [-250.0, -120.0, 0.0, 120.0, 250.0]:
		for z in [-250.0, -100.0, 20.0, 100.0, 250.0]:
			cands.append(Vector3(x, -25.0, z))
	var near := PackedInt32Array()
	var food: Object = food_of(w)
	for c: Vector3 in cands:
		var ok: bool = true
		for f: Variant in krill_of(w):
			if float((f as Object).call("density_at", c)) > 0.0:
				ok = false
		if food != null and ok:
			food.call("sites_near_into", c, 6.0, near)
			ok = near.is_empty()
		if ok:
			return c
	return cands[0] if not cands.is_empty() else S3.ARENA


# ======================================================================= presentation helpers

## Key of food site `site` in TargetBarTracker.ids. Merged API: static `site_key(site)` in the NEGATIVE key space (entity
## ids are >= 1); the contract draft had `FOOD_KEY_BASE + site`. Both are supported, the first one found wins.
static func tracker_key(site: int) -> int:
	var s: GDScript = script_at(TRACKER_SCRIPT)
	if script_has(s, TRACKER_KEY_FUNC):
		return int(s.call(TRACKER_KEY_FUNC, site))
	var base: Variant = script_const(s, TRACKER_KEY_CONST)
	return (int(base) if base != null else 1000000) + site


static func has_tracker_key() -> bool:
	var s: GDScript = script_at(TRACKER_SCRIPT)
	return script_has(s, TRACKER_KEY_FUNC) or script_const(s, TRACKER_KEY_CONST) != null


## A site key never equals an entity id: it is <= 0 (negative key space) or above any id the sim hands out.
static func key_is_outside_entity_ids(key: int) -> bool:
	return key < 1 or key > 100000


## Recording stand-in for MapDressing: every hide / show request of the view lands in `calls` as [site, shown].
class RecDressing extends MapDressing:
	var calls: Array = []

	func set_site_visible(site: int, shown: bool) -> void:
		calls.append([site, shown])


## Builds a FoodSiteView (setup(loop, dressing)) on a controlled scene: an egg site swallowed on the first tick (respawn_s 2),
## the player then moved 30 m away so the respawned egg is not eaten again. Returns {"w": SimWorld, "scene": Dictionary,
## "hide_calls": Array (appended by the recording dressing), "step": Callable(n: int), "nodes": Array[Node] (free them)}.
## `step(n)` advances n ticks, emitting the loop's `ticked` after each; n == 0 re-emits the same tick (a paused world).
## Returns {} when the scene cannot be built (already reported).
static func view_probe(tc: TestCase) -> Dictionary:
	var vs: GDScript = script_at(VIEW_SCRIPT)
	if vs == null:
		return {}
	var sc: Dictionary = scene(tc, T_EGG_PEACH, {"override": {"respawn_s": 2.0}})
	if sc.is_empty():
		return {}
	var w: SimWorld = sc["w"]
	var loop := GameLoop.new()
	loop.world = w
	var dressing := RecDressing.new()
	var view: Node = vs.new()
	view.call("setup", loop, dressing)
	var done: Array[int] = [0]
	var pid: int = sc["pid"]
	var home: Vector3 = sc["pos"]
	var step := func(n: int) -> void:
		if n == 0:
			loop.ticked.emit(w.tick)
			return
		for i in n:
			S4.pin(w, pid, home if done[0] < 12 else home + Vector3(30.0, 0.0, 0.0))
			w.step()
			done[0] += 1
			loop.ticked.emit(w.tick)
	var nodes: Array[Node] = [view, dressing, loop]
	return {"w": w, "scene": sc, "hide_calls": dressing.calls, "step": step, "nodes": nodes}
