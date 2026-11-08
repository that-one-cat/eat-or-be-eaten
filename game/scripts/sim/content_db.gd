class_name ContentDB
extends RefCounted
## Data-driven content loaded from JSON under a data root (default res://data): species, size bands,
## mutations, abilities, maps (+ optional map dressings `maps/<map_id>_dressing.json`, S5, and baked dressing
## collision proxies `maps/<map_id>_proxies.json`) and global rules, with schema and cross-reference validation. The sim
## never reads dressings (presentation data: MapDressing); it reads the baked proxies (plain obstacle records).
## Food (food task): optional `food/<type>.json` type records (get_food) and the baked food sites
## `maps/<map_id>_food.json` (tools/dressing/bake_food.gd; get_food_sites, read by FoodSites); the dressing `food`
## block (placement rules) is validated with the dressing.
## Pure data (no nodes, no SceneTree). Never crashes on bad input: problems are collected in `errors`
## as `<source>: <field.path>: <problem>`, where source is relative to the data root
## (e.g. `species/puffer.json`). Whole-file problems use the field path `$`.
## Returned records are the parsed dictionaries; callers must treat them as read-only.

const TEMPERAMENTS: Array[String] = ["predator", "retaliate", "passive"]
const SPECIES_TIERS: Array[String] = ["ambient", "interactive", "large"]
const MUTATION_BRANCHES: Array[String] = ["hunter", "survivor"]
const ABILITY_KINDS: Array[String] = ["active", "passive"]
const OBSTACLE_KINDS: Array[String] = ["sphere", "capsule", "box", "obb"]
## obb `rot` quaternions must be unit length within this tolerance (the baked files round them to 1e-4).
const QUAT_LENGTH_TOL: float = 1e-2
const HIDING_TAGS: Array[String] = ["kelp", "coral"]
## Upper bound for rules swim.max_pitch_deg (the heading must keep a horizontal part).
const MAX_PITCH_LIMIT_DEG: float = 89.0
const MAX_BAND_INDEX: int = 4
const MAX_MUTATION_TIER: int = 4
## Hard design rule 6: the world stays within +-4 km of the origin.
const WORLD_LIMIT_M: float = 4000.0
const MAX_COUNT: int = 1000000
## Upper bounds for map `schools` records (TierManager packs school id and member index into 20 bits each).
const MAX_SCHOOL_SIZE: int = 4096
const MAX_SCHOOLS_PER_RECORD: int = 10000
## Upper bound for map `spawners[].group.min` / `max` (NpcSpawner packs: small groups, not schools).
const MAX_GROUP_SIZE: int = 16
## Map dressing files (S5): `maps/<map_id>` + this suffix + `.json`; skipped by the map loader.
const DRESSING_SUFFIX: String = "_dressing"
## Baked dressing collision proxies: `maps/<map_id>` + this suffix + `.json` (tools/dressing/bake_proxies.gd); skipped
## by the map loader, served by get_proxies().
const PROXIES_SUFFIX: String = "_proxies"
## Baked food sites: `maps/<map_id>` + this suffix + `.json` (tools/dressing/bake_food.gd); skipped by the map loader,
## served by get_food_sites().
const FOOD_SUFFIX: String = "_food"
## Food types (`food/<id>.json` `kind`): soft = swallowed whole, hard = bitten (HP).
const FOOD_KINDS: Array[String] = ["soft", "hard"]
## Dressing `food.rules[].anchor`: top of the host mesh, a ring on the seabed around the host, the host stem axis.
const FOOD_ANCHORS: Array[String] = ["top", "base_ring", "stem"]
## SFX group folders (food `sfx` cross-reference: res://assets/audio/sfx/<group>/).
const SFX_DIR: String = "res://assets/audio/sfx"
## Dressing `solid_pieces` recipe bound (proxy box = piece bounds x fit).
const MAX_SOLID_FIT: float = 2.0
## Environment piece GLBs `env_<piece>_v<n>_lod0.glb` (dressing cross-references: piece ids and variants).
const ENV_MODELS_DIR: String = "res://assets/models/env"
## Schema bound for dressing depth ranges (the exact map depth is checked in the cross-references).
const MAX_DRESSING_DEPTH_M: float = 200.0
const MAX_DRESSING_SCALE: float = 10.0
const DRESSING_ROT_RANDOM: String = "random"
const DRESSING_ANCHORS: Array[String] = ["seabed"]
const DRESSING_COLLISIONS: Array[String] = ["seabed_field"]
## Control modes (T1.4): id shape, the mandatory record and the bounds of the input-side numbers.
const CLASSIC_CONTROL_MODE: StringName = &"classic"
const MAX_SMOOTH_TAU_S: float = 10.0
const MAX_TURN_CAP_DEG_S: float = 3600.0

## Required numbers in rules/core.json: [path, lo, hi, lo_exclusive].
const RULE_NUMBERS: Array = [
	["swallow_ratio", 0.0, 1.0, true],
	["hunger_max", 0.0, INF, true],
	["hunger_full_to_empty_s", 0.0, INF, true],
	["hunger_per_xp", 0.0, INF, false],
	["starvation_hp_frac_per_s", 0.0, 1.0, false],
	["regen_min_hunger_frac", 0.0, 1.0, false],
	["regen_hp_frac_per_s", 0.0, 1.0, false],
	["death_xp_loss_frac", 0.0, 1.0, false],
	["respawn_delay_s", 0.0, INF, false],
	["predator_hunt_ratio", 0.0, 1.0, true],
	["retaliate_duration_s", 0.0, INF, false],
	["xp_falloff.full_at_ratio", 0.0, INF, true],
	["xp_falloff.min_ratio", 0.0, INF, true],
	["xp_falloff.min_mult", 0.0, 1.0, false],
	["hiding.lose_target_s", 0.0, INF, false],
	["hiding.detection_mult", 0.0, 1.0, false],
	["remains.skeleton_fade_s", 0.0, INF, false],
	["presence.min_length_ratio", 0.0, INF, false],
	["presence.radius_m", 0.0, INF, true],
	["presence.sector_deg", 0.0, 360.0, true],
	["feedback.slowmo_scale", 0.0, 1.0, true],
	["feedback.slowmo_s", 0.0, INF, false],
	["feedback.slowmo_min_length_ratio", 0.0, INF, false],
	["feedback.xray_flash_s", 0.0, INF, false],
	["swim.max_pitch_deg", 0.0, MAX_PITCH_LIMIT_DEG, true],
	["predator_give_up_s", 0.0, INF, false],
	["grid_cell_m", 0.0, INF, true],
	["mouth_reach_mult", 0.0, INF, true],
	["mouth_cone_deg", 0.0, 180.0, true],
	["bite_cooldown_s", 0.0, INF, false],
	["npc_scale", 0.0, INF, false],
	["tiers.promote_radius_m", 0.0, INF, true],
	["tiers.demote_radius_m", 0.0, INF, true],
	["tiers.min_interactive_s", 0.0, INF, false],
	["schools.radius_per_sqrt_member_m", 0.0, INF, true],
	["schools.height_ratio", 0.0, 1.0, true],
	["schools.wobble_m", 0.0, INF, false],
	["schools.wobble_hz", 0.0, INF, false],
	["schools.path_radius_m", 0.0, INF, true],
	["schools.follow_lookahead_s", 0.0, INF, true],
	["quality.low.ambient_density_mult", 0.0, 1.0, true],
	["remains.food_bits.length_m", 0.0, INF, true],
	["remains.food_bits.drift_mps", 0.0, INF, false],
	["remains.food_bits.lifetime_s", 0.0, INF, true],
	["feedback.chomp_min_frac", 0.0, 1.0, false],
]
## Mutation node `effects` keys (S6, Progression) -> [lo, hi, lo_exclusive]. Multipliers stack multiplicatively over
## the owned nodes; presence_sector_deg is the widest owned value (presentation reads it).
const MUTATION_EFFECTS: Dictionary = {
	"bite_power_mult": [0.0, INF, true],
	"swim_speed_mult": [0.0, INF, true],
	"boost_duration_mult": [0.0, INF, true],
	"boost_speed_mult": [0.0, INF, true],
	"hunger_drain_mult": [0.0, INF, false],
	"damage_taken_mult": [0.0, INF, false],
	"presence_sector_deg": [0.0, 360.0, true],
}
## Species movement stats (T1.7), all required and > 0: boost speed multiplier, boost stamina pool, turn rate, thrust
## acceleration, coasting drag, brake deceleration. `depth_range_m` ([min, max] metres below the surface) is checked apart.
const SPECIES_MOVEMENT_FIELDS: Array[String] = ["boost_mult", "boost_stamina", "turn_rate_deg_s", "accel_mps2", "drag_per_s", "brake_decel_mps2"]
## Optional `player_profile` multipliers of a species (each > 0, default 1.0): player value = band table x multiplier.
const PLAYER_PROFILE_KEYS: Array[String] = ["swim_speed_mult", "turn_rate_mult", "accel_mult", "drag_mult", "brake_mult"]
## rules player_hp_model: "band" = player max HP from the size band (max_hp), "length2" = species base_hp * length^2.
const PLAYER_HP_MODELS: Array[String] = ["band", "length2"]

## Every problem found by load_from_dir(); empty when the content is valid.
var errors: PackedStringArray = PackedStringArray()

var _root: String = ""
var _errs: Array[String] = []
var _species: Dictionary = {}  # String id -> record
var _bands: Array[Dictionary] = []  # index - 1 -> record
var _mutations: Dictionary = {}  # String id -> record
var _mutation_pos: Dictionary = {}  # String id -> position in mutations.json "nodes"
var _abilities: Dictionary = {}
var _maps: Dictionary = {}
var _dressings: Dictionary = {}  # String map id -> dressing record
var _proxies: Dictionary = {}  # String map id -> Array of baked obstacle records
var _foods: Dictionary = {}  # String food type id -> record
var _food_sites: Dictionary = {}  # String map id -> Array of baked food site records
var _rules: Dictionary = {}
var _control_modes: Dictionary = {}  # String id -> record (controls/modes.json)
var _control_mode_order: Array[StringName] = []  # ids in file order


## Loads and validates everything under `root`. Always returns a ContentDB; check is_valid()/errors.
static func load_from_dir(root: String = "res://data") -> ContentDB:
	var db := ContentDB.new()
	db._root = root
	if not DirAccess.dir_exists_absolute(root):
		db._errs.append("%s: $: data directory not found" % root)
	else:
		db._load_records("species", &"species", db._species)
		db._load_bands()
		db._load_mutations()
		db._load_records("abilities", &"ability", db._abilities)
		db._load_foods()
		db._load_records("maps", &"map", db._maps)
		db._load_dressings()
		db._load_proxies()
		db._load_food_sites()
		db._load_rules()
		db._load_control_modes()
		db._check_references()
	db.errors = PackedStringArray(db._errs)
	return db


## Only `controls/modes.json` (T1.4), validated; for the settings layer, which has no world. Problems are in `errors`.
static func load_control_modes(root: String = "res://data") -> ContentDB:
	var db := ContentDB.new()
	db._root = root
	db._load_control_modes()
	db.errors = PackedStringArray(db._errs)
	return db


## Single-record schema check (no cross-references). `kind` is one of &"species", &"size_band",
## &"mutation", &"ability", &"map", &"dressing", &"proxies", &"food", &"food_sites", &"rules", &"control_mode"; `source` prefixes every
## error message.
static func validate_record(kind: StringName, record: Dictionary, source: String) -> PackedStringArray:
	var errs: Array[String] = []
	_check_record(kind, record, _Checker.new(source, errs))
	return PackedStringArray(errs)


func is_valid() -> bool:
	return errors.is_empty()


func species_ids() -> Array[StringName]:
	return _sorted_ids(_species)


func get_species(id: StringName) -> Dictionary:
	return _species.get(String(id), {})


func band_count() -> int:
	return _bands.size()


## 1-based; empty dictionary when out of range.
func get_band(index: int) -> Dictionary:
	if index < 1 or index > _bands.size():
		return {}
	return _bands[index - 1]


## Highest band whose `xp_to_reach` is <= xp; negative XP (and anything below every threshold) is band 1.
func band_for_xp(xp: float) -> int:
	var band: int = 1
	for i in _bands.size():
		var need: float = _num_or_nan(_bands[i], "xp_to_reach")
		if not is_nan(need) and xp >= need:
			band = i + 1
	return band


func mutation_ids() -> Array[StringName]:
	return _sorted_ids(_mutations)


func get_mutation(id: StringName) -> Dictionary:
	return _mutations.get(String(id), {})


func ability_ids() -> Array[StringName]:
	return _sorted_ids(_abilities)


func get_ability(id: StringName) -> Dictionary:
	return _abilities.get(String(id), {})


func map_ids() -> Array[StringName]:
	return _sorted_ids(_maps)


func get_map(id: StringName) -> Dictionary:
	return _maps.get(String(id), {})


## Dressing of a map (`maps/<map_id>_dressing.json`, S5 presentation data read by MapDressing), {} when none.
func get_dressing(map_id: StringName) -> Dictionary:
	return _dressings.get(String(map_id), {})


## Baked dressing collision proxies of a map (`maps/<map_id>_proxies.json` `obstacles`: obstacle records like the map's
## own, mostly `obb`), [] when none. SimWorld passes them to SeabedField.from_map(map, proxies).
func get_proxies(map_id: StringName) -> Array:
	return _proxies.get(String(map_id), [])


## Food type ids (`food/<id>.json`), sorted.
func food_ids() -> Array[StringName]:
	return _sorted_ids(_foods)


## Food type record (`food/<type>.json`; FoodSites, the bot), {} when unknown. The live parsed dictionary (like
## get_map): read-only for callers.
func get_food(type: StringName) -> Dictionary:
	return _foods.get(String(type), {})


## Baked food sites of a map (`maps/<map_id>_food.json` `sites`; FoodSites.create, MapDressing), [] when none.
func get_food_sites(map_id: StringName) -> Array:
	return _food_sites.get(String(map_id), [])


## Environment piece id -> number of variant GLBs (`env_<id>_v<n>_lod0.glb` under ENV_MODELS_DIR, n = 1..N).
## Uses ResourceLoader.list_directory(), so it also works in exported builds (no raw .glb files there).
static func env_piece_variants() -> Dictionary:
	var out: Dictionary = {}
	var rx := RegEx.new()
	rx.compile("^env_(.+)_v(\\d+)_lod0\\.glb$")
	for f: String in ResourceLoader.list_directory(ENV_MODELS_DIR):
		var m: RegExMatch = rx.search(f)
		if m != null:
			out[m.get_string(1)] = maxi(int(out.get(m.get_string(1), 0)), int(m.get_string(2)))
	return out


func rules() -> Dictionary:
	return _rules


## Control mode ids (`controls/modes.json`, T1.4) in file order (`classic` is always there in a valid database).
func control_mode_ids() -> Array[StringName]:
	return _control_mode_order


## Control mode record, {} when unknown. The live parsed dictionary: read-only for callers.
func get_control_mode(id: StringName) -> Dictionary:
	return _control_modes.get(String(id), {})


# ------------------------------------------------------------------ loading

## One record per `<subdir>/<id>.json`; the record id must equal the file stem.
func _load_records(subdir: String, kind: StringName, into: Dictionary) -> void:
	var d := DirAccess.open(_root.path_join(subdir))
	if d == null:
		_errs.append("%s/: $: directory not found" % subdir)
		return
	var files: Array[String] = []
	for f in d.get_files():
		var stem: String = f.get_basename()
		if f.ends_with(".json") and not (kind == &"map" and (stem.ends_with(DRESSING_SUFFIX) or stem.ends_with(PROXIES_SUFFIX) or stem.ends_with(FOOD_SUFFIX))):
			files.append(f)
	files.sort()
	if files.is_empty():
		_errs.append("%s/: $: no .json files" % subdir)
	for f in files:
		var source: String = "%s/%s" % [subdir, f]
		var rec: Variant = _read_json(source)
		if not (rec is Dictionary):
			continue
		var c := _Checker.new(source, _errs)
		_check_record(kind, rec, c)
		var stem: String = f.get_basename()
		var rid: Variant = (rec as Dictionary).get("id")
		if rid is String and rid != stem:
			c.add("id", "must equal the file name stem '%s'" % stem)
		into[stem] = rec


## `maps/<map_id>_dressing.json` (optional per map): schema + cross-references (map, zones, hiding volumes,
## obstacles, env piece GLBs).
func _load_dressings() -> void:
	var d := DirAccess.open(_root.path_join("maps"))
	if d == null:
		return
	var files: Array[String] = []
	for f in d.get_files():
		if f.ends_with(DRESSING_SUFFIX + ".json"):
			files.append(f)
	files.sort()
	var pieces: Dictionary = env_piece_variants() if not files.is_empty() else {}
	for f in files:
		var source: String = "maps/%s" % f
		var rec: Variant = _read_json(source)
		if not (rec is Dictionary):
			continue
		var c := _Checker.new(source, _errs)
		_check_dressing(rec, c)
		var map_id: String = f.get_basename().trim_suffix(DRESSING_SUFFIX)
		if not _maps.has(map_id):
			c.add("$", "no map '%s' for this dressing (maps/%s.json)" % [map_id, map_id])
			continue
		_check_dressing_refs(rec, _maps[map_id], pieces, c)
		_dressings[map_id] = rec


## `maps/<map_id>_proxies.json` (optional per map): schema (obstacle records), the map must exist, ids must not repeat a
## map obstacle id.
func _load_proxies() -> void:
	var d := DirAccess.open(_root.path_join("maps"))
	if d == null:
		return
	var files: Array[String] = []
	for f in d.get_files():
		if f.ends_with(PROXIES_SUFFIX + ".json"):
			files.append(f)
	files.sort()
	for f in files:
		var source: String = "maps/%s" % f
		var rec: Variant = _read_json(source)
		if not (rec is Dictionary):
			continue
		var c := _Checker.new(source, _errs)
		_check_proxies(rec, c)
		var map_id: String = f.get_basename().trim_suffix(PROXIES_SUFFIX)
		if not _maps.has(map_id):
			c.add("$", "no map '%s' for these proxies (maps/%s.json)" % [map_id, map_id])
			continue
		if rec.get("map") is String and rec["map"] != map_id:
			c.add("map", "must equal the map id '%s' of the file name" % map_id)
		var own: Dictionary = {}
		for o in _array_at(_maps[map_id], "obstacles"):
			if o is Dictionary and (o as Dictionary).get("id") is String:
				own[(o as Dictionary)["id"]] = true
		var list: Array = _array_at(rec, "obstacles")
		for i in list.size():
			if list[i] is Dictionary and (list[i] as Dictionary).get("id") is String and own.has(list[i]["id"]):
				c.add("obstacles[%d].id" % i, "repeats the map obstacle id '%s' (maps/%s.json)" % [list[i]["id"], map_id])
		_proxies[map_id] = list


## `food/<id>.json` (optional directory: none = no food): schema + cross-references (env piece GLBs, SFX group folder).
func _load_foods() -> void:
	if not DirAccess.dir_exists_absolute(_root.path_join("food")):
		return
	_load_records("food", &"food", _foods)
	if _foods.is_empty():
		return
	var pieces: Dictionary = env_piece_variants()
	var groups: PackedStringArray = ResourceLoader.list_directory(SFX_DIR)
	for id: String in _foods:
		var rec: Dictionary = _foods[id]
		var c := _Checker.new("food/%s.json" % id, _errs)
		var list: Array = _array_at(rec, "pieces")
		for i in list.size():
			if list[i] is Dictionary and (list[i] as Dictionary).get("id") is String and not pieces.has(list[i]["id"]):
				c.add("pieces[%d].id" % i, "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [list[i]["id"], ENV_MODELS_DIR, list[i]["id"]])
		if rec.get("sfx") is String and not groups.has(str(rec["sfx"]) + "/"):
			c.add("sfx", "unknown SFX group '%s' (no %s/%s/)" % [rec["sfx"], SFX_DIR, rec["sfx"]])


## `maps/<map_id>_food.json` (optional per map, tools/dressing/bake_food.gd): schema, the map must exist, every site's
## type must be a food type that lists the site's piece (edible decor included).
func _load_food_sites() -> void:
	var d := DirAccess.open(_root.path_join("maps"))
	if d == null:
		return
	var files: Array[String] = []
	for f in d.get_files():
		if f.ends_with(FOOD_SUFFIX + ".json"):
			files.append(f)
	files.sort()
	for f in files:
		var source: String = "maps/%s" % f
		var rec: Variant = _read_json(source)
		if not (rec is Dictionary):
			continue
		var c := _Checker.new(source, _errs)
		_check_food_sites(rec, c)
		var map_id: String = f.get_basename().trim_suffix(FOOD_SUFFIX)
		if not _maps.has(map_id):
			c.add("$", "no map '%s' for these food sites (maps/%s.json)" % [map_id, map_id])
			continue
		if rec.get("map") is String and rec["map"] != map_id:
			c.add("map", "must equal the map id '%s' of the file name" % map_id)
		var list: Array = _array_at(rec, "sites")
		for i in list.size():
			if not (list[i] is Dictionary) or not ((list[i] as Dictionary).get("type") is String):
				continue
			var s: Dictionary = list[i]
			var t: Dictionary = _foods.get(s["type"], {})
			if t.is_empty():
				c.add("sites[%d].type" % i, "unknown food type '%s' (no food/%s.json)" % [s["type"], s["type"]])
			elif s.get("piece") is String and not _food_piece_ids(t).has(s["piece"]):
				c.add("sites[%d].piece" % i, "piece '%s' is not listed in food/%s.json pieces" % [s["piece"], s["type"]])
		_food_sites[map_id] = list


func _load_bands() -> void:
	var source: String = "size_bands/size_bands.json"
	var data: Variant = _read_json(source)
	if not (data is Dictionary):
		return
	var c := _Checker.new(source, _errs)
	if not c.array(data, "bands", true, true):
		return
	var list: Array = (data as Dictionary)["bands"]
	for i in list.size():
		if not (list[i] is Dictionary):
			c.add("bands[%d]" % i, "must be an object")
			_bands.clear()
			return
		_check_record(&"size_band", list[i], c.sub("bands[%d]" % i))
		_bands.append(list[i])
	for i in _bands.size():
		var index: float = _num_or_nan(_bands[i], "index")
		if not is_nan(index) and int(index) != i + 1:
			c.add("bands[%d].index" % i, "must be %d (bands are listed in index order)" % (i + 1))
		if i == 0:
			continue
		var prev_max: float = _num_or_nan(_bands[i - 1], "length_m.max")
		var cur_min: float = _num_or_nan(_bands[i], "length_m.min")
		if not is_nan(prev_max) and not is_nan(cur_min) and absf(prev_max - cur_min) > 1e-6:
			c.add("bands[%d].length_m.min" % i, "must equal bands[%d].length_m.max (%s), bands are contiguous" % [i - 1, _Checker.fmt(prev_max)])
		var prev_xp: float = _num_or_nan(_bands[i - 1], "xp_to_reach")
		var cur_xp: float = _num_or_nan(_bands[i], "xp_to_reach")
		if not is_nan(prev_xp) and not is_nan(cur_xp) and cur_xp <= prev_xp:
			c.add("bands[%d].xp_to_reach" % i, "must be greater than bands[%d].xp_to_reach (%s)" % [i - 1, _Checker.fmt(prev_xp)])


func _load_mutations() -> void:
	var source: String = "mutations/mutations.json"
	var data: Variant = _read_json(source)
	if not (data is Dictionary):
		return
	var c := _Checker.new(source, _errs)
	if not c.array(data, "nodes", true, true):
		return
	var list: Array = (data as Dictionary)["nodes"]
	for i in list.size():
		if not (list[i] is Dictionary):
			c.add("nodes[%d]" % i, "must be an object")
			continue
		var rec: Dictionary = list[i]
		_check_record(&"mutation", rec, c.sub("nodes[%d]" % i))
		var rid: Variant = rec.get("id")
		if not (rid is String):
			continue
		if _mutations.has(rid):
			c.add("nodes[%d].id" % i, "duplicate mutation id '%s'" % rid)
			continue
		_mutations[rid] = rec
		_mutation_pos[rid] = i


func _load_rules() -> void:
	var source: String = "rules/core.json"
	var data: Variant = _read_json(source)
	if not (data is Dictionary):
		return
	_check_record(&"rules", data, _Checker.new(source, _errs))
	_rules = data


## `controls/modes.json` (T1.4): {"modes": [record]}; ids unique, `classic` must exist.
func _load_control_modes() -> void:
	var source: String = "controls/modes.json"
	var data: Variant = _read_json(source)
	if not (data is Dictionary):
		return
	var c := _Checker.new(source, _errs)
	if not c.array(data, "modes", true, true):
		return
	var list: Array = (data as Dictionary)["modes"]
	for i in list.size():
		if not (list[i] is Dictionary):
			c.add("modes[%d]" % i, "must be an object")
			continue
		var rec: Dictionary = list[i]
		_check_record(&"control_mode", rec, c.sub("modes[%d]" % i))
		var rid: Variant = rec.get("id")
		if not _is_mode_id(rid):
			continue
		if _control_modes.has(rid):
			c.add("modes[%d].id" % i, "duplicate control mode id '%s'" % rid)
			continue
		_control_modes[rid] = rec
		_control_mode_order.append(StringName(rid))
	if not _control_modes.has(CLASSIC_CONTROL_MODE):
		c.add("modes", "must contain a '%s' record" % CLASSIC_CONTROL_MODE)


## Reads and parses one JSON object file; records an error and returns null on any problem.
func _read_json(source: String) -> Variant:
	var path: String = _root.path_join(source)
	if not FileAccess.file_exists(path):
		_errs.append("%s: $: file not found" % source)
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		# get_error_line() is 0-based; report 1-based like editors do.
		_errs.append("%s: $: invalid JSON at line %d: %s" % [source, json.get_error_line() + 1, json.get_error_message()])
		return null
	if not (json.data is Dictionary):
		_errs.append("%s: $: must be a JSON object" % source)
		return null
	return json.data


# ------------------------------------------------------------------ cross-references

func _check_references() -> void:
	var zone_ids: Dictionary = {}
	for map_id in _maps:
		for z in _array_at(_maps[map_id], "zones"):
			if z is Dictionary and (z as Dictionary).get("id") is String:
				zone_ids[(z as Dictionary)["id"]] = true

	for id in _species:
		var zones: Array = _array_at(_species[id], "zones")
		for i in zones.size():
			if zones[i] is String and not zone_ids.has(zones[i]):
				_errs.append("species/%s.json: zones[%d]: unknown zone '%s' (not defined in any map)" % [id, i, zones[i]])

	for id in _mutations:
		var m: Dictionary = _mutations[id]
		var path: String = "nodes[%d]" % _mutation_pos[id]
		var tier: float = _num_or_nan(m, "tier")
		var req: Variant = m.get("requires")
		if req is String and not is_nan(tier) and tier > 1.0:
			var parent: Dictionary = _mutations.get(req, {})
			if parent.is_empty():
				_errs.append("mutations/mutations.json: %s.requires: unknown mutation '%s'" % [path, req])
			elif str(parent.get("branch")) != str(m.get("branch")):
				_errs.append("mutations/mutations.json: %s.requires: '%s' is in another branch (must be %s)" % [path, req, str(m.get("branch"))])
			elif _num_or_nan(parent, "tier") != tier - 1.0:
				_errs.append("mutations/mutations.json: %s.requires: must reference the tier %d node of its branch" % [path, int(tier) - 1])
		var grant: Variant = m.get("grants_ability")
		if grant is String and not _abilities.has(grant):
			_errs.append("mutations/mutations.json: %s.grants_ability: unknown ability '%s'" % [path, grant])

	for map_id in _maps:
		var own_zones: Dictionary = {}
		for z in _array_at(_maps[map_id], "zones"):
			if z is Dictionary and (z as Dictionary).get("id") is String:
				own_zones[(z as Dictionary)["id"]] = true
		var spawners: Array = _array_at(_maps[map_id], "spawners")
		for i in spawners.size():
			if not (spawners[i] is Dictionary):
				continue
			var s: Dictionary = spawners[i]
			var sid: Variant = s.get("species_id")
			if sid is String and not _species.has(sid):
				_errs.append("maps/%s.json: spawners[%d].species_id: unknown species '%s'" % [map_id, i, sid])
			elif sid is String and s.get("group") is Dictionary and (_species[sid].get("schooling") == true or _species[sid].get("tier") == "ambient"):
				_errs.append("maps/%s.json: spawners[%d].group: species '%s' is schooling or ambient (its spawner spawns nothing)" % [map_id, i, sid])
			var zid: Variant = s.get("zone_id")
			if zid is String and not own_zones.has(zid):
				_errs.append("maps/%s.json: spawners[%d].zone_id: unknown zone '%s' (not in this map)" % [map_id, i, zid])
		var schools: Array = _array_at(_maps[map_id], "schools")
		for i in schools.size():
			if not (schools[i] is Dictionary):
				continue
			var s: Dictionary = schools[i]
			var sid: Variant = s.get("species_id")
			if sid is String and not _species.has(sid):
				_errs.append("maps/%s.json: schools[%d].species_id: unknown species '%s'" % [map_id, i, sid])
			elif sid is String and _species[sid].get("schooling") != true:
				_errs.append("maps/%s.json: schools[%d].species_id: species '%s' is not schooling" % [map_id, i, sid])
			var zid: Variant = s.get("zone_id")
			if zid is String and not own_zones.has(zid):
				_errs.append("maps/%s.json: schools[%d].zone_id: unknown zone '%s' (not in this map)" % [map_id, i, zid])
		_check_krill_refs(map_id, own_zones)
		var pk: Variant = (_maps[map_id] as Dictionary).get("plankton")
		if pk is Dictionary:
			var pid: Variant = (pk as Dictionary).get("species_id")
			if pid is String and not _species.has(pid):
				_errs.append("maps/%s.json: plankton.species_id: unknown species '%s'" % [map_id, pid])
			var pzones: Array = _array_at(pk, "zones")
			for i in pzones.size():
				if pzones[i] is String and not own_zones.has(pzones[i]):
					_errs.append("maps/%s.json: plankton.zones[%d]: unknown zone '%s' (not in this map)" % [map_id, i, pzones[i]])
			var cell: float = _num_or_nan(pk, "cell_m")
			var grid: float = _num_or_nan(_rules, "grid_cell_m")
			if cell > 0.0 and grid > 0.0 and not (_is_whole(cell / grid) or _is_whole(grid / cell)):
				_errs.append("maps/%s.json: plankton.cell_m: must divide or be a multiple of rules grid_cell_m (%s)" % [map_id, _Checker.fmt(grid)])


# Map `krill` entries: species exists, zones are in this map, cell_m fits the grid (like map `plankton`).
func _check_krill_refs(map_id: String, own_zones: Dictionary) -> void:
	var list: Array = _array_at(_maps[map_id], "krill")
	var grid: float = _num_or_nan(_rules, "grid_cell_m")
	for i in list.size():
		if not (list[i] is Dictionary):
			continue
		var k: Dictionary = list[i]
		var sid: Variant = k.get("species_id")
		if sid is String and not _species.has(sid):
			_errs.append("maps/%s.json: krill[%d].species_id: unknown species '%s'" % [map_id, i, sid])
		var kzones: Array = _array_at(k, "zones")
		for j in kzones.size():
			if kzones[j] is String and not own_zones.has(kzones[j]):
				_errs.append("maps/%s.json: krill[%d].zones[%d]: unknown zone '%s' (not in this map)" % [map_id, i, j, kzones[j]])
		var cell: float = _num_or_nan(k, "cell_m")
		if cell > 0.0 and grid > 0.0 and not (_is_whole(cell / grid) or _is_whole(grid / cell)):
			_errs.append("maps/%s.json: krill[%d].cell_m: must divide or be a multiple of rules grid_cell_m (%s)" % [map_id, i, _Checker.fmt(grid)])


# ------------------------------------------------------------------ record schemas

static func _check_record(kind: StringName, rec: Dictionary, c: _Checker) -> void:
	match kind:
		&"species":
			_check_species(rec, c)
		&"size_band":
			_check_size_band(rec, c)
		&"mutation":
			_check_mutation(rec, c)
		&"ability":
			_check_ability(rec, c)
		&"map":
			_check_map(rec, c)
		&"dressing":
			_check_dressing(rec, c)
		&"proxies":
			_check_proxies(rec, c)
		&"food":
			_check_food(rec, c)
		&"food_sites":
			_check_food_sites(rec, c)
		&"rules":
			_check_rules(rec, c)
		&"control_mode":
			_check_control_mode(rec, c)
		_:
			c.add("kind", "unknown record kind '%s'" % kind)


static func _check_species(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "id")
	c.text(rec, "name", false)
	c.one_of(rec, "temperament", TEMPERAMENTS)
	c.one_of(rec, "tier", SPECIES_TIERS)
	c.range_block(rec, "length_m", 0.0, true)
	c.num(rec, "base_hp", 0.0, INF, true)
	c.num(rec, "hp_override", 0.0, INF, true, false)
	c.num(rec, "xp", 0.0)
	if rec.has("xp_band_mult"):
		var m: Variant = rec["xp_band_mult"]
		if not (m is Array) or (m as Array).size() != MAX_BAND_INDEX:
			c.add("xp_band_mult", "must be an array of %d numbers (one per size band of the eater)" % MAX_BAND_INDEX)
		else:
			for k in MAX_BAND_INDEX:
				if not c.num_value(m[k], "xp_band_mult[%d]" % k, 0.0, INF, true):
					break
	c.num(rec, "swim_speed_mps", 0.0, INF, true)
	_check_species_movement(rec, c)
	c.num(rec, "bite_mult", 0.0, INF, true, false)
	var temperament: String = rec["temperament"] if rec.get("temperament") is String else ""
	c.num(rec, "detection_radius_m", 0.0, INF, true, temperament == "predator")
	c.num(rec, "flee_radius_m", 0.0, INF, true, temperament == "passive")
	c.range_block(rec, "school_size", 1.0, false, false)
	if rec.has("playable") and typeof(rec["playable"]) != TYPE_BOOL:
		c.add("playable", "must be true or false")
	if rec.has("schooling"):
		if typeof(rec["schooling"]) != TYPE_BOOL:
			c.add("schooling", "must be true or false")
		elif rec["schooling"] and rec.get("tier") != "interactive":
			c.add("schooling", "a schooling species must have tier 'interactive' (school members are promoted into it)")
	if c.dict(rec, "inflate", false):
		c.num(rec, "inflate.scale", 1.0, INF, true)
		c.num(rec, "inflate.duration_s", 0.0, INF, true)
		c.num(rec, "inflate.spike_damage_frac_of_biter_max_hp", 0.0, 1.0)
	if c.dict(rec, "boss", false):
		c.num(rec, "boss.engage_radius_m", 0.0, INF, true)
		c.num(rec, "boss.dash_windup_s", 0.0)
		c.num(rec, "boss.dash_damage_frac_of_b4_max_hp", 0.0, 1.0)
		c.num(rec, "boss.disengage_after_s", 0.0)
		c.num(rec, "boss.hp_regen_frac_per_s", 0.0, 1.0)
		# S6 boss fight (BossBrain): dash charge, close-bite cooldown, disengage return, finisher remains, victory
		c.num(rec, "boss.dash_ref_length_m", 0.0, INF, true)
		c.num(rec, "boss.dash_speed_mps", 0.0, INF, true)
		c.num(rec, "boss.dash_distance_m", 0.0, INF, true)
		c.num(rec, "boss.dash_hit_margin_m", 0.0)
		c.num(rec, "boss.dash_min_range_m", 0.0)
		c.num(rec, "boss.dash_interval_s", 0.0)
		c.num(rec, "boss.bite_cooldown_s", 0.0)
		c.num(rec, "boss.disengage_return_s", 0.0)
		c.num(rec, "boss.victory_delay_s", 0.0)
		c.integer(rec, "boss.remains_bits", 0, MAX_COUNT)
		c.num(rec, "boss.remains_bit_scale", 0.0, INF, true)
		# S7: close-range charge after a hug, stun time-out (optional; missing = off)
		c.num(rec, "boss.hug_charge_after_s", 0.0, INF, false, false)
		c.num(rec, "boss.stun_timeout_s", 0.0, INF, false, false)
		c.num(rec, "boss.stun_recover_hp_frac", 0.0, 1.0, false, false)
	if c.array(rec, "zones"):
		var zones: Array = rec["zones"]
		for i in zones.size():
			if not (zones[i] is String) or (zones[i] as String).is_empty():
				c.add("zones[%d]" % i, "must be a non-empty string")
	_check_npc_behaviour(rec, c)


# T1.7 per-species movement stats (all required; zero is out of range for the rate-like ones) and the optional
# player_profile multipliers (default 1.0 when a key or the whole block is missing).
static func _check_species_movement(rec: Dictionary, c: _Checker) -> void:
	for key: String in SPECIES_MOVEMENT_FIELDS:
		c.num(rec, key, 0.0, INF, true)
	if c.array(rec, "depth_range_m"):
		var depth: Array = rec["depth_range_m"]
		if depth.size() != 2:
			c.add("depth_range_m", "must be [min, max] (2 numbers)")
		else:
			var has_min: bool = c.num_value(depth[0], "depth_range_m[0]", 0.0)
			var has_max: bool = c.num_value(depth[1], "depth_range_m[1]", 0.0)
			if has_min and has_max and float(depth[1]) < float(depth[0]):
				c.add("depth_range_m[1]", "must be >= depth_range_m[0]")
	if c.dict(rec, "player_profile", false):
		for key: String in PLAYER_PROFILE_KEYS:
			c.num(rec, "player_profile.%s" % key, 0.0, INF, true, false)


static func _check_size_band(rec: Dictionary, c: _Checker) -> void:
	c.integer(rec, "index", 1, MAX_BAND_INDEX)
	c.range_block(rec, "length_m", 0.0, true)
	var has_reach: bool = c.num(rec, "xp_to_reach", 0.0)
	var has_full: bool = c.num(rec, "xp_full_length", 0.0)
	if has_reach and has_full and float(rec["xp_full_length"]) <= float(rec["xp_to_reach"]):
		c.add("xp_full_length", "must be > xp_to_reach")
	c.num(rec, "swim_speed_mps", 0.0, INF, true)
	c.num(rec, "accel_mps2", 0.0, INF, true)
	c.num(rec, "drag_per_s", 0.0, INF, true)
	c.num(rec, "turn_rate_deg_s", 0.0, INF, true)
	c.num(rec, "brake_decel_mps2", 0.0, INF, true)
	c.num(rec, "lunge_distance_m", 0.0, INF, false)  # T1.6 bite lunge: total travel at lunge_strength 1 (0 = no lunge in this band)
	c.num(rec, "collision_radius_mult", 0.0, 1.0, true)
	c.num(rec, "max_hp", 0.0, INF, true)
	c.num(rec, "bite_power", 0.0, INF, true)
	c.num(rec, "hunger_drain_mult", 0.0, INF, true)
	c.num(rec, "grid_cell_m", 0.0, INF, true)
	if c.dict(rec, "camera"):
		c.num(rec, "camera.distance", 0.0, INF, true)
		var has_near: bool = c.num(rec, "camera.near", 0.0, INF, true)
		var has_far: bool = c.num(rec, "camera.far", 0.0, INF, true)
		if has_near and has_far and float(rec["camera"]["far"]) <= float(rec["camera"]["near"]):
			c.add("camera.far", "must be > camera.near")
	if c.array(rec, "lod_m", true, true):
		var lod: Array = rec["lod_m"]
		for i in lod.size():
			if not c.num_value(lod[i], "lod_m[%d]" % i, 0.0, INF, true):
				return
			if i > 0 and float(lod[i]) <= float(lod[i - 1]):
				c.add("lod_m[%d]" % i, "must be > lod_m[%d] (ascending)" % (i - 1))


static func _check_mutation(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "id")
	c.text(rec, "name", false)
	c.one_of(rec, "branch", MUTATION_BRANCHES)
	var has_tier: bool = c.integer(rec, "tier", 1, MAX_MUTATION_TIER)
	if not rec.has("requires"):
		c.add("requires", "is required (null for a tier 1 node)")
	elif has_tier:
		var req: Variant = rec["requires"]
		if int(rec["tier"]) == 1 and typeof(req) != TYPE_NIL:
			c.add("requires", "must be null for a tier 1 node")
		elif int(rec["tier"]) > 1 and (not (req is String) or (req as String).is_empty()):
			c.add("requires", "must be the id of the tier %d node of the same branch" % (int(rec["tier"]) - 1))
	c.text(rec, "description")
	if c.dict(rec, "effects"):
		var effects: Dictionary = rec["effects"]
		for key in effects:
			if not MUTATION_EFFECTS.has(key):
				c.add("effects.%s" % key, "unknown effect (known: %s)" % "|".join(PackedStringArray(MUTATION_EFFECTS.keys())))
				continue
			var lim: Array = MUTATION_EFFECTS[key]
			c.num_value(effects[key], "effects.%s" % key, lim[0], lim[1], lim[2])
	c.text(rec, "grants_ability", false)


static func _check_ability(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "id")
	c.text(rec, "name", false)
	c.one_of(rec, "kind", ABILITY_KINDS)
	var kind: String = rec["kind"] if rec.get("kind") is String else ""
	c.text(rec, "input_action", kind == "active")
	c.num(rec, "cooldown_s", 0.0)
	if str(rec.get("id", "")) == "boost":
		# the sim's stamina model reads these (GAME_DESIGN section 4)
		c.num(rec, "stamina_max", 0.0, INF, true)
		c.num(rec, "stamina_drain_per_s", 0.0, INF, true)
		c.num(rec, "stamina_regen_per_s", 0.0)
		# boost restarts (also while held) only once stamina >= this fraction of stamina_max
		c.num(rec, "restart_min_stamina_frac", 0.0, 1.0)
		c.num(rec, "speed_mult", 1.0)
	elif str(rec.get("id", "")) == "bite_dash":
		# S6 Abilities.bite_dash: lunge along the heading, then one bite that ignores the bite cooldown
		c.num(rec, "lunge_distance_m", 0.0, INF, true)
		c.num(rec, "lunge_duration_s", 0.0, INF, true)
		# speed after the lunge as a fraction of the band max swim speed (keeps the total close to lunge_distance_m)
		c.num(rec, "exit_speed_frac", 0.0, 1.0)
	elif str(rec.get("id", "")) == "sonar":
		# S6 Abilities.sonar: contacts within radius_m, rel by length ratio (smaller < below <= similar <= above < bigger)
		c.num(rec, "radius_m", 0.0, INF, true)
		c.num(rec, "duration_s", 0.0, INF, true)
		var has_below: bool = c.num(rec, "smaller_below_ratio", 0.0, INF, true)
		if c.num(rec, "bigger_above_ratio", 0.0, INF, true) and has_below and float(rec["bigger_above_ratio"]) < float(rec["smaller_below_ratio"]):
			c.add("bigger_above_ratio", "must be >= smaller_below_ratio")
	c.text(rec, "description", false)


static func _check_map(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "id")
	c.num(rec, "size_m", 0.0, WORLD_LIMIT_M * 2.0, true)  # hard design rule 6: the map stays within +-4 km
	c.num(rec, "depth_m", 0.0, INF, true)
	if c.array(rec, "zones", true, true):
		var seen: Dictionary = {}
		var zones: Array = rec["zones"]
		for i in zones.size():
			var path: String = "zones[%d]" % i
			if not (zones[i] is Dictionary):
				c.add(path, "must be an object")
				continue
			var zone: Dictionary = zones[i]
			var zc := c.sub(path)
			if zc.text(zone, "id"):
				if seen.has(zone["id"]):
					zc.add("id", "duplicate zone id '%s'" % zone["id"])
				seen[zone["id"]] = true
			if zc.dict(zone, "aabb"):
				var has_min: bool = zc.vec3(zone, "aabb.min")
				var has_max: bool = zc.vec3(zone, "aabb.max")
				if has_min and has_max:
					var lo: Array = zone["aabb"]["min"]
					var hi: Array = zone["aabb"]["max"]
					for axis in 3:
						if float(hi[axis]) <= float(lo[axis]):
							zc.add("aabb.max", "must be > aabb.min on every axis")
							break
	if c.array(rec, "spawners"):
		var spawners: Array = rec["spawners"]
		for i in spawners.size():
			var path: String = "spawners[%d]" % i
			if not (spawners[i] is Dictionary):
				c.add(path, "must be an object")
				continue
			var sc := c.sub(path)
			sc.text(spawners[i], "species_id")
			sc.text(spawners[i], "zone_id")
			sc.integer(spawners[i], "count", 1, MAX_COUNT)
			sc.num(spawners[i], "respawn_s", 0.0)
			if sc.dict(spawners[i], "group", false):
				var has_min: bool = sc.integer(spawners[i], "group.min", 2, MAX_GROUP_SIZE)
				if sc.integer(spawners[i], "group.max", 2, MAX_GROUP_SIZE) and has_min and int(spawners[i]["group"]["max"]) < int(spawners[i]["group"]["min"]):
					sc.add("group.max", "must be >= group.min")
				sc.num(spawners[i], "group.chance", 0.0, 1.0)
				sc.num(spawners[i], "group.radius_m", 0.0, INF, true)
	if c.array(rec, "player_spawns", true, true):
		var spawns: Array = rec["player_spawns"]
		for i in spawns.size():
			c.vec3_value(spawns[i], "player_spawns[%d]" % i)
	var half_size: float = float(rec["size_m"]) * 0.5 if _Checker.is_num(rec.get("size_m")) else INF
	var depth_m: float = float(rec["depth_m"]) if _Checker.is_num(rec.get("depth_m")) else INF
	_check_places(rec, c, half_size, depth_m)
	if c.dict(rec, "bounds"):
		if c.num(rec, "bounds.soft_margin_m", 0.0, INF, true) and float(rec["bounds"]["soft_margin_m"]) >= half_size:
			c.add("bounds.soft_margin_m", "must be < size_m / 2")
		c.num(rec, "bounds.current_mps", 0.0)
	_check_seabed(rec, c, depth_m)
	_check_obstacles(rec, c)
	_check_hiding_volumes(rec, c)
	_check_schools(rec, c)
	_check_plankton(rec, c)
	_check_krill(rec, c)


## Map `places` (optional): [{id, name?, pos}] named teleport points of the God tools (T1.2; sim ignores them).
## `id` unique snake_case, `pos` [x, y, z] inside the map box (|x|, |z| <= size_m / 2, -depth_m <= y <= 0).
static func _check_places(rec: Dictionary, c: _Checker, half_size: float, depth_m: float) -> void:
	if not c.array(rec, "places", false):
		return
	var seen: Dictionary = {}
	var list: Array = rec["places"]
	for i in list.size():
		var path: String = "places[%d]" % i
		if not (list[i] is Dictionary):
			c.add(path, "must be an object")
			continue
		var pc := c.sub(path)
		var place: Dictionary = list[i]
		if pc.text(place, "id"):
			var id: String = place["id"]
			if id != id.to_lower() or not id.is_valid_ascii_identifier():
				pc.add("id", "must be snake_case (a-z, 0-9, _)")
			elif seen.has(id):
				pc.add("id", "duplicate place id '%s'" % id)
			seen[id] = true
		pc.text(place, "name", false)
		if pc.vec3(place, "pos"):
			var pos: Array = place["pos"]
			if absf(float(pos[0])) > half_size or absf(float(pos[2])) > half_size or float(pos[1]) > 0.0 or float(pos[1]) < -depth_m:
				pc.add("pos", "must be inside the map box (|x|, |z| <= size_m / 2, -depth_m <= y <= 0)")


## Map `schools` (optional): [{species_id, zone_id, count, size_min, size_max, respawn_s}] (S4, SchoolSystem).
static func _check_schools(rec: Dictionary, c: _Checker) -> void:
	if not c.array(rec, "schools", false):
		return
	var list: Array = rec["schools"]
	for i in list.size():
		var path: String = "schools[%d]" % i
		if not (list[i] is Dictionary):
			c.add(path, "must be an object")
			continue
		var s: Dictionary = list[i]
		var sc := c.sub(path)
		sc.text(s, "species_id")
		sc.text(s, "zone_id")
		sc.integer(s, "count", 1, MAX_SCHOOLS_PER_RECORD)
		var has_min: bool = sc.integer(s, "size_min", 1, MAX_SCHOOL_SIZE)
		var has_max: bool = sc.integer(s, "size_max", 1, MAX_SCHOOL_SIZE)
		if has_min and has_max and int(s["size_max"]) < int(s["size_min"]):
			sc.add("size_max", "must be >= size_min")
		sc.num(s, "respawn_s", 0.0)


## Map `plankton` (optional): {species_id, zones: [zone ids], cell_m, density_max, regrow_per_s, eat_per_tick,
## xp_per_unit, hunger_per_unit, min_eat_density (optional), variation (optional: {seed, patch_m >= cell_m,
## empty_frac, rich_frac (0..1, sum <= 1), min_mult (0..1)})} (S4, PlanktonField; variation: feat-plankton-visibility).
## `key` = the block's key in `rec` (no dots; `_check_krill` passes "krill[i]").
static func _check_plankton(rec: Dictionary, c: _Checker, key: String = "plankton", krill: bool = false) -> void:
	if not c.dict(rec, key, false):
		return
	c.text(rec, key + ".species_id")
	if c.array(rec, key + ".zones", true, true):
		var zones: Array = rec[key]["zones"]
		for i in zones.size():
			if not (zones[i] is String) or (zones[i] as String).is_empty():
				c.add(key + ".zones[%d]" % i, "must be a non-empty string")
	c.num(rec, key + ".cell_m", 0.0, INF, true)
	c.num(rec, key + ".density_max", 0.0, INF, true)
	c.num(rec, key + ".regrow_per_s", 0.0)
	if not krill:  # krill is eaten per critter (_check_krill)
		c.num(rec, key + ".eat_per_tick", 0.0, INF, true)
		c.num(rec, key + ".min_eat_density", 0.0, INF, false, false)
	c.num(rec, key + ".xp_per_unit", 0.0)
	c.num(rec, key + ".hunger_per_unit", 0.0)
	if not c.dict(rec, key + ".variation", false):
		return
	var pk: Dictionary = rec[key]
	var v: Dictionary = pk["variation"]
	c.integer(rec, key + ".variation.seed", 0, 2147483647)
	if c.num(rec, key + ".variation.patch_m", 0.0, INF, true) and _Checker.is_num(pk.get("cell_m")):
		if float(v["patch_m"]) < float(pk["cell_m"]):
			c.add(key + ".variation.patch_m", "must be >= %s.cell_m" % key)
	var has_empty: bool = c.num(rec, key + ".variation.empty_frac", 0.0, 1.0)
	var has_rich: bool = c.num(rec, key + ".variation.rich_frac", 0.0, 1.0)
	if has_empty and has_rich and float(v["empty_frac"]) + float(v["rich_frac"]) > 1.0:
		c.add(key + ".variation", "empty_frac + rich_frac must be <= 1")
	c.num(rec, key + ".variation.min_mult", 0.0, 1.0)


## Map `krill` (optional): array of krill cloud fields, each with the `plankton` block keys (above; species_id = a
## krill species; no eat_per_tick / min_eat_density) plus the optional KrillField keys: critters_per_cell (int
## 1..KrillField.MAX_CRITTERS), eat_radius_m (> 0), eat_interval_ticks (int >= 1), spread_m (>= 0), motion {drift_m,
## drift_period_s (> 0), weave_m (< drift_m), weave_period_s (> 0), bob_m} (all >= 0). The zone boxes of two different
## entries must not overlap (positive volume), so a cloud shows one palette.
static func _check_krill(rec: Dictionary, c: _Checker) -> void:
	if not c.array(rec, "krill", false):
		return
	var list: Array = rec["krill"]
	var boxes: Dictionary = {}
	for z: Variant in (rec.get("zones", []) if rec.get("zones") is Array else []):
		if z is Dictionary and (z as Dictionary).get("id") is String and (z as Dictionary).get("aabb") is Dictionary:
			var a: Variant = z["aabb"].get("min")
			var b: Variant = z["aabb"].get("max")
			if _is_vec3(a) and _is_vec3(b):
				boxes[z["id"]] = [a, b]
	for i in list.size():
		var key: String = "krill[%d]" % i
		if not (list[i] is Dictionary):
			c.add(key, "must be an object")
			continue
		var one: Dictionary = {key: list[i]}
		_check_plankton(one, c, key, true)
		c.integer(one, key + ".critters_per_cell", 1, KrillField.MAX_CRITTERS, false)
		c.num(one, key + ".eat_radius_m", 0.0, INF, true, false)
		c.integer(one, key + ".eat_interval_ticks", 1, 2147483647, false)
		c.num(one, key + ".spread_m", 0.0, INF, false, false)
		if c.dict(one, key + ".motion", false):
			for mk: String in ["drift_m", "weave_m", "bob_m"]:
				c.num(one, key + ".motion." + mk, 0.0, INF, false, false)
			for pk: String in ["drift_period_s", "weave_period_s"]:
				c.num(one, key + ".motion." + pk, 0.0, INF, true, false)
			var mo: Dictionary = (list[i] as Dictionary)["motion"]
			var drift: float = float(mo["drift_m"]) if _Checker.is_num(mo.get("drift_m")) else 0.0
			if _Checker.is_num(mo.get("weave_m")) and float(mo["weave_m"]) > 0.0 and float(mo["weave_m"]) >= drift:
				c.add(key + ".motion.weave_m", "must be < motion.drift_m (krill always swim forward)")
		for j in range(i):
			if list[j] is Dictionary:
				var hit: String = _krill_overlap(list[i], list[j], boxes)
				if not hit.is_empty():
					c.add(key + ".zones", "%s overlaps krill[%d] (krill fields need disjoint zones)" % [hit, j])


# First zone of krill entry `a` whose box overlaps (positive volume) a zone box of entry `b`, "" when none.
static func _krill_overlap(a: Dictionary, b: Dictionary, boxes: Dictionary) -> String:
	var za: Array = a.get("zones", []) if a.get("zones") is Array else []
	var zb: Array = b.get("zones", []) if b.get("zones") is Array else []
	for ida: Variant in za:
		for idb: Variant in zb:
			if not boxes.has(ida) or not boxes.has(idb):
				continue
			var p: Array = boxes[ida]
			var q: Array = boxes[idb]
			var overlap: bool = true
			for axis in 3:
				var lo: float = maxf(float(p[0][axis]), float(q[0][axis]))
				var hi: float = minf(float(p[1][axis]), float(q[1][axis]))
				if not (hi > lo):
					overlap = false
			if overlap:
				return "zone '%s'" % ida
	return ""


static func _is_vec3(v: Variant) -> bool:
	if not (v is Array) or (v as Array).size() != 3:
		return false
	for item: Variant in (v as Array):
		if not _Checker.is_num(item):
			return false
	return true


static func _check_seabed(rec: Dictionary, c: _Checker, depth_m: float) -> void:
	if not c.dict(rec, "seabed"):
		return
	c.integer(rec, "seabed.seed", 0, 2147483647)
	if c.num(rec, "seabed.min_depth_m", 0.0) and float(rec["seabed"]["min_depth_m"]) >= depth_m:
		c.add("seabed.min_depth_m", "must be < depth_m")
	if c.array(rec, "seabed.profile", true, true):
		var pts: Array = rec["seabed"]["profile"]
		var prev_z: float = -INF
		for i in pts.size():
			var path: String = "seabed.profile[%d]" % i
			var p: Variant = pts[i]
			if not (p is Array) or (p as Array).size() != 2:
				c.add(path, "must be a [z, depth] pair")
				return
			if not c.num_value(p[0], path + "[0]") or not c.num_value(p[1], path + "[1]", 0.0, depth_m, true):
				return
			if float(p[0]) <= prev_z:
				c.add(path + "[0]", "must be > the previous profile z (ascending)")
			prev_z = float(p[0])
	if c.dict(rec, "seabed.noise"):
		c.num(rec, "seabed.noise.amplitude_m", 0.0)
		c.num(rec, "seabed.noise.cell_m", 0.0, INF, true)
	if c.dict(rec, "seabed.cliff", false):
		c.num(rec, "seabed.cliff.z_m")
		c.num(rec, "seabed.cliff.width_m", 0.0, INF, true)
		c.num(rec, "seabed.cliff.wobble_m", 0.0)
		c.num(rec, "seabed.cliff.wobble_cell_m", 0.0, INF, true)
		c.num(rec, "seabed.abyss_floor_depth_m", 0.0, depth_m, true)


static func _check_obstacles(rec: Dictionary, c: _Checker) -> void:
	if not c.array(rec, "obstacles"):
		return
	var seen: Dictionary = {}
	var list: Array = rec["obstacles"]
	for i in list.size():
		var path: String = "obstacles[%d]" % i
		if not (list[i] is Dictionary):
			c.add(path, "must be an object")
			continue
		var o: Dictionary = list[i]
		var oc := c.sub(path)
		if oc.text(o, "id"):
			if seen.has(o["id"]):
				oc.add("id", "duplicate obstacle id '%s'" % o["id"])
			seen[o["id"]] = true
		oc.text(o, "tag", false)
		if not oc.one_of(o, "kind", OBSTACLE_KINDS):
			continue
		match str(o["kind"]):
			"sphere":
				oc.vec3(o, "center")
				oc.num(o, "radius", 0.0, INF, true)
			"capsule":
				oc.vec3(o, "a")
				oc.vec3(o, "b")
				oc.num(o, "radius", 0.0, INF, true)
			"box", "obb":
				oc.vec3(o, "center")
				var size_ok: bool = oc.vec3(o, "size")
				if size_ok:
					for v in (o["size"] as Array):
						if float(v) <= 0.0:
							oc.add("size", "must be > 0 on every axis")
							size_ok = false
							break
				if str(o["kind"]) == "obb":
					_check_obb(o, oc, size_ok)


## Extra fields of an `obb` (rounded oriented box) record: optional `rot` [x, y, z, w] unit quaternion (default
## identity) and `round` (corner radius, default 0, at most half the smallest size).
static func _check_obb(o: Dictionary, oc: _Checker, size_ok: bool) -> void:
	if o.has("rot"):
		var rot: Variant = o["rot"]
		if not (rot is Array) or (rot as Array).size() != 4:
			oc.add("rot", "must be an [x, y, z, w] quaternion")
		else:
			var len2: float = 0.0
			for k in 4:
				if not oc.num_value(rot[k], "rot[%d]" % k):
					return
				len2 += float(rot[k]) * float(rot[k])
			if absf(sqrt(len2) - 1.0) > QUAT_LENGTH_TOL:
				oc.add("rot", "must be a unit quaternion (length %s)" % _Checker.fmt(sqrt(len2)))
	if oc.num(o, "round", 0.0, INF, false, false) and size_ok:
		var s: Array = o["size"]
		var limit: float = minf(float(s[0]), minf(float(s[1]), float(s[2]))) * 0.5
		if float(o["round"]) > limit + 1e-6:
			oc.add("round", "must be <= half the smallest size (%s)" % _Checker.fmt(limit))


## Baked proxies record (`maps/<map_id>_proxies.json`): {generated_by?, map, dressing_seed?, obstacles: [obstacle]}.
static func _check_proxies(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "map")
	c.text(rec, "generated_by", false)
	c.integer(rec, "dressing_seed", 0, 2147483647, false)
	_check_obstacles(rec, c)

# ------------------------------------------------------------------ map dressing (S5, presentation data)

## Dressing record: {seed, scatter: [rule], set_pieces: [set piece], solid_pieces?: {piece id: recipe}} (contract: tasks/archive/2026-11/mvp/research/stage-S5-world-look-1104/
## s5-contract.md "Map dressing"; field reference: game/data/README.md).
static func _check_dressing(rec: Dictionary, c: _Checker) -> void:
	c.integer(rec, "seed", 0, 2147483647)
	if c.array(rec, "scatter"):
		var rules: Array = rec["scatter"]
		for i in rules.size():
			if not (rules[i] is Dictionary):
				c.add("scatter[%d]" % i, "must be an object")
				continue
			_check_scatter_rule(rules[i], c.sub("scatter[%d]" % i))
	if c.array(rec, "set_pieces"):
		var seen: Dictionary = {}
		var sets: Array = rec["set_pieces"]
		for i in sets.size():
			if not (sets[i] is Dictionary):
				c.add("set_pieces[%d]" % i, "must be an object")
				continue
			var sp: Dictionary = sets[i]
			var sc := c.sub("set_pieces[%d]" % i)
			_check_set_piece(sp, sc)
			if sp.get("id") is String:
				if seen.has(sp["id"]):
					sc.add("id", "duplicate set piece id '%s'" % sp["id"])
				seen[sp["id"]] = true
	# solid_pieces: pieces that get a baked collision proxy (DressingProxies): {fit (default 1), round (0..1 of the
	# smallest half extent, default 0), tag (default "rock")}
	if c.dict(rec, "solid_pieces", false):
		var solid: Dictionary = rec["solid_pieces"]
		for pid: Variant in solid:
			var path: String = "solid_pieces.%s" % pid
			if not (solid[pid] is Dictionary):
				c.add(path, "must be an object")
				continue
			var pc := c.sub(path)
			pc.num(solid[pid], "fit", 0.0, MAX_SOLID_FIT, true, false)
			pc.num(solid[pid], "round", 0.0, 1.0, false, false)
			pc.text(solid[pid], "tag", false)
	if c.dict(rec, "food", false):
		_check_dressing_food(rec["food"], c.sub("food"))


static func _check_scatter_rule(r: Dictionary, c: _Checker) -> void:
	c.text(r, "zone_id")
	if c.array(r, "pieces", true, true):
		var pieces: Array = r["pieces"]
		for j in pieces.size():
			if not (pieces[j] is Dictionary):
				c.add("pieces[%d]" % j, "must be an object")
				continue
			var pc := c.sub("pieces[%d]" % j)
			pc.text(pieces[j], "id")
			pc.num(pieces[j], "weight", 0.0, INF, true, false)
			if (pieces[j] as Dictionary).has("variants"):
				_check_variants(pieces[j]["variants"], pc)
	c.num(r, "density_per_100m2", 0.0)
	_check_pair(r, "scale", 0.0, MAX_DRESSING_SCALE, true, false, true, c)
	_check_pair(r, "depth_m", 0.0, MAX_DRESSING_DEPTH_M, false, true, false, c)
	c.num(r, "min_spacing_m", 0.0, INF, false, false)
	if r.has("rot_y") and not (_Checker.is_num(r["rot_y"]) or r["rot_y"] == DRESSING_ROT_RANDOM):
		c.add("rot_y", "must be \"%s\" or a number (degrees)" % DRESSING_ROT_RANDOM)
	for flag: String in ["align_to_slope", "avoid_obstacles"]:
		if r.has(flag) and typeof(r[flag]) != TYPE_BOOL:
			c.add(flag, "must be true or false")
	c.num(r, "max_slope_deg", 0.0, 90.0, false, false)
	c.num(r, "sink_m", 0.0, 1.0, false, false)
	c.num(r, "view_m", 0.0, INF, true, false)
	if c.array(r, "hiding_volume_ids", false, true):
		var ids: Array = r["hiding_volume_ids"]
		for k in ids.size():
			if not (ids[k] is String) or (ids[k] as String).is_empty():
				c.add("hiding_volume_ids[%d]" % k, "must be a non-empty string")
	if c.dict(r, "clump", false):
		_check_pair(r["clump"], "count", 1.0, float(MAX_COUNT), false, false, true, c.sub("clump"))
		c.num(r, "clump.radius_m", 0.0, INF, true)
		c.integer(r, "clump.group", 0, MAX_COUNT, false)


static func _check_set_piece(sp: Dictionary, c: _Checker) -> void:
	c.text(sp, "id")
	c.text(sp, "piece")
	c.integer(sp, "variant", 1, 99, false)
	var pos: Variant = sp.get("pos")
	if not sp.has("pos"):
		c.add("pos", "is required")
	elif pos is Dictionary:
		var pd: Dictionary = pos
		if not (pd.get("anchor") is String) or not DRESSING_ANCHORS.has(pd["anchor"]):
			c.add("pos.anchor", "must be one of %s" % "|".join(PackedStringArray(DRESSING_ANCHORS)))
		var xz: Variant = pd.get("xz")
		if not (xz is Array) or (xz as Array).size() != 2 or not _Checker.is_num(xz[0]) or not _Checker.is_num(xz[1]):
			c.add("pos.xz", "must be an [x, z] array of numbers")
		elif absf(float(xz[0])) > WORLD_LIMIT_M or absf(float(xz[1])) > WORLD_LIMIT_M:
			c.add("pos.xz", "must stay within +-%s m of the origin" % _Checker.fmt(WORLD_LIMIT_M))
	else:
		c.vec3_value(pos, "pos")
	c.num(sp, "rot_y", -INF, INF, false, false)
	c.num(sp, "tilt_deg", -90.0, 90.0, false, false)
	c.num(sp, "scale", 0.0, MAX_DRESSING_SCALE, true, false)
	c.num(sp, "sink_m", 0.0, 10.0, false, false)
	if sp.has("collision") and not (sp["collision"] is String and DRESSING_COLLISIONS.has(sp["collision"])):
		c.add("collision", "must be one of %s" % "|".join(PackedStringArray(DRESSING_COLLISIONS)))
	if c.array(sp, "obstacle_ids"):
		var ids: Array = sp["obstacle_ids"]
		for k in ids.size():
			if not (ids[k] is String) or (ids[k] as String).is_empty():
				c.add("obstacle_ids", "must be an array of obstacle id strings ([%d] is %s)" % [k, ids[k]])
				break


## `variants` of a piece entry: an integer N >= 1 (variants 1..N) or a non-empty array of integers >= 1.
static func _check_variants(v: Variant, c: _Checker) -> void:
	if v is Array:
		if (v as Array).is_empty():
			c.add("variants", "must not be empty")
		for item in (v as Array):
			if not _Checker.is_num(item) or float(item) != floorf(float(item)) or float(item) < 1.0:
				c.add("variants", "must list integers >= 1")
				return
	elif not _Checker.is_num(v) or float(v) != floorf(float(v)) or float(v) < 1.0:
		c.add("variants", "must be an integer >= 1 or an array of integers >= 1")


## `[min, max]` pair of numbers within [lo, hi] (lo exclusive when `lo_exclusive`); max > min when `strict`, else
## max >= min.
static func _check_pair(rec: Dictionary, key: String, lo: float, hi: float, lo_exclusive: bool, strict: bool, required: bool, c: _Checker) -> void:
	if not rec.has(key):
		if required:
			c.add(key, "is required")
		return
	var v: Variant = rec[key]
	if not (v is Array) or (v as Array).size() != 2 or not _Checker.is_num(v[0]) or not _Checker.is_num(v[1]):
		c.add(key, "must be a [min, max] pair of numbers")
		return
	var a: float = float(v[0])
	var b: float = float(v[1])
	if (lo_exclusive and a <= lo) or a < lo or b > hi or not is_finite(a) or not is_finite(b):
		c.add(key, "must stay within %s%s..%s" % ["(" if lo_exclusive else "[", _Checker.fmt(lo), _Checker.fmt(hi)])
	elif (strict and b <= a) or b < a:
		c.add(key, "max must be %s min" % (">" if strict else ">="))


## Cross-references of one dressing against its map and the env piece kit (`pieces`: id -> variant count).
func _check_dressing_refs(rec: Dictionary, map: Dictionary, pieces: Dictionary, c: _Checker) -> void:
	var zones: Dictionary = {}
	for z in _array_at(map, "zones"):
		if z is Dictionary and (z as Dictionary).get("id") is String:
			zones[(z as Dictionary)["id"]] = true
	var volumes: Dictionary = {}
	for v in _array_at(map, "hiding_volumes"):
		if v is Dictionary and (v as Dictionary).get("id") is String:
			volumes[(v as Dictionary)["id"]] = true
	var obstacles: Dictionary = {}
	for o in _array_at(map, "obstacles"):
		if o is Dictionary and (o as Dictionary).get("id") is String:
			obstacles[(o as Dictionary)["id"]] = true
	var depth_m: float = _num_or_nan(map, "depth_m")
	var rules: Array = _array_at(rec, "scatter")
	for i in rules.size():
		if not (rules[i] is Dictionary):
			continue
		var r: Dictionary = rules[i]
		var path: String = "scatter[%d]" % i
		if r.get("zone_id") is String and not zones.has(r["zone_id"]):
			c.add(path + ".zone_id", "unknown zone '%s' (not in this map)" % r["zone_id"])
		var ids: Array = _array_at(r, "hiding_volume_ids")
		for k in ids.size():
			if ids[k] is String and not volumes.has(ids[k]):
				c.add("%s.hiding_volume_ids[%d]" % [path, k], "unknown hiding volume '%s'" % ids[k])
		var dr: Variant = r.get("depth_m")
		if dr is Array and (dr as Array).size() == 2 and _Checker.is_num(dr[1]) and not is_nan(depth_m) and float(dr[1]) > depth_m:
			c.add(path + ".depth_m", "max must be <= the map depth_m (%s)" % _Checker.fmt(depth_m))
		var list: Array = _array_at(r, "pieces")
		for j in list.size():
			if not (list[j] is Dictionary) or not ((list[j] as Dictionary).get("id") is String):
				continue
			var pid: String = list[j]["id"]
			var ppath: String = "%s.pieces[%d]" % [path, j]
			if not pieces.has(pid):
				c.add(ppath + ".id", "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [pid, ENV_MODELS_DIR, pid])
				continue
			var vs: Variant = (list[j] as Dictionary).get("variants", 1)
			var top: int = 0
			if vs is Array:
				for item in (vs as Array):
					if _Checker.is_num(item):
						top = maxi(top, int(item))
			elif _Checker.is_num(vs):
				top = int(vs)
			if top > int(pieces[pid]):
				c.add(ppath + ".variants", "variant %d of '%s' does not exist (GLBs v1..v%d)" % [top, pid, pieces[pid]])
	if rec.get("solid_pieces") is Dictionary:
		for pid: Variant in (rec["solid_pieces"] as Dictionary):
			if not pieces.has(str(pid)):
				c.add("solid_pieces.%s" % pid, "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [pid, ENV_MODELS_DIR, pid])
	var owner_of: Dictionary = {}
	var sets: Array = _array_at(rec, "set_pieces")
	for i in sets.size():
		if not (sets[i] is Dictionary):
			continue
		var sp: Dictionary = sets[i]
		var path: String = "set_pieces[%d]" % i
		if sp.get("piece") is String:
			var pid: String = sp["piece"]
			if not pieces.has(pid):
				c.add(path + ".piece", "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [pid, ENV_MODELS_DIR, pid])
			elif _Checker.is_num(sp.get("variant", 1)) and int(sp.get("variant", 1)) > int(pieces[pid]):
				c.add(path + ".variant", "variant %d of '%s' does not exist (GLBs v1..v%d)" % [int(sp["variant"]), pid, pieces[pid]])
		var ids: Array = _array_at(sp, "obstacle_ids")
		for k in ids.size():
			if not (ids[k] is String):
				continue
			if not obstacles.has(ids[k]):
				c.add("%s.obstacle_ids[%d]" % [path, k], "unknown obstacle '%s' (not in this map)" % ids[k])
			elif owner_of.has(ids[k]):
				c.add("%s.obstacle_ids[%d]" % [path, k], "obstacle '%s' is already claimed by set piece '%s'" % [ids[k], owner_of[ids[k]]])
			else:
				owner_of[ids[k]] = str(sp.get("id", ""))
	if rec.get("food") is Dictionary:
		_check_dressing_food_refs(rec["food"], rec, zones, pieces, c.sub("food"))


# ------------------------------------------------------------------ NPC brain keys (S3, read by NpcBrain / NpcSpawner)

## Species `behaviour` block. `flees` is required for passive species; a fleeing species also needs
## `flee_min_length_ratio` (threat = creature >= ratio x own length) and `flee_release_mult` (>= 1: keeps fleeing
## until no threat is within flee_radius_m x mult). flees = false: never flees (plankton swarm).
static func _check_npc_behaviour(rec: Dictionary, c: _Checker) -> void:
	if not c.dict(rec, "behaviour"):
		return
	var passive: bool = str(rec.get("temperament", "")) == "passive"
	var b: Dictionary = rec["behaviour"]
	if b.has("flees") or passive:
		var flees: Variant = b.get("flees")
		if typeof(flees) != TYPE_BOOL:
			c.add("behaviour.flees", "must be true or false")
		elif flees:
			c.num(rec, "behaviour.flee_min_length_ratio", 0.0, INF, true)
			c.num(rec, "behaviour.flee_release_mult", 1.0)
	c.num(rec, "behaviour.boost_within_m", 0.0)
	c.num(rec, "behaviour.wander_speed_frac", 0.0, 1.0, true)
	c.num(rec, "behaviour.wander_radius_m", 0.0, INF, true)
	c.num(rec, "behaviour.wander_retarget_s", 0.0, INF, true)
	c.integer(rec, "behaviour.think_interval_ticks", 1, 30)
	c.num(rec, "behaviour.seabed_clearance_m", 0.0)


## Map `hiding_volumes` (optional): [{id, tag: kelp|coral, aabb: {min, max}}], ids unique, max > min on every axis.
static func _check_hiding_volumes(rec: Dictionary, c: _Checker) -> void:
	if not c.array(rec, "hiding_volumes", false):
		return
	var seen: Dictionary = {}
	var list: Array = rec["hiding_volumes"]
	for i in list.size():
		var path: String = "hiding_volumes[%d]" % i
		if not (list[i] is Dictionary):
			c.add(path, "must be an object")
			continue
		var v: Dictionary = list[i]
		var vc := c.sub(path)
		if vc.text(v, "id"):
			if seen.has(v["id"]):
				vc.add("id", "duplicate hiding volume id '%s'" % v["id"])
			seen[v["id"]] = true
		vc.one_of(v, "tag", HIDING_TAGS)
		if vc.dict(v, "aabb") and vc.vec3(v, "aabb.min") and vc.vec3(v, "aabb.max"):
			for axis in 3:
				if float(v["aabb"]["max"][axis]) <= float(v["aabb"]["min"][axis]):
					vc.add("aabb.max", "must be > aabb.min on every axis")
					break


static func _check_rules(rec: Dictionary, c: _Checker) -> void:
	for entry in RULE_NUMBERS:
		c.num(rec, entry[0], entry[1], entry[2], entry[3])
	c.integer(rec, "mutation_offer_count", 1, MAX_MUTATION_TIER * MUTATION_BRANCHES.size())
	if c.range_block(rec, "remains.food_bits", 1.0, false):
		c.integer(rec, "remains.food_bits.min", 1, MAX_COUNT)
		c.integer(rec, "remains.food_bits.max", 1, MAX_COUNT)
	c.integer(rec, "tiers.interactive_cap", 1, MAX_COUNT)
	c.integer(rec, "tiers.large_cap", 0, MAX_COUNT)
	c.integer(rec, "tiers.update_every_ticks", 1, 30)
	var promote: float = _num_or_nan(rec, "tiers.promote_radius_m")
	var demote: float = _num_or_nan(rec, "tiers.demote_radius_m")
	if not is_nan(promote) and not is_nan(demote) and demote <= promote:
		c.add("tiers.demote_radius_m", "must be > tiers.promote_radius_m (hysteresis)")
	c.num(rec, "quality.high.ambient_density_mult", 0.0, 1.0, true, false)
	c.num(rec, "spawn.min_player_distance_m", 0.0, WORLD_LIMIT_M, false, false)
	# F1 player bite feel (optional: reach / cone fall back to the mouth values, buffer / miss cue to 0 = off)
	c.num(rec, "bite_reach_mult", 0.0, INF, true, false)
	c.num(rec, "bite_cone_deg", 0.0, 180.0, true, false)
	c.num(rec, "bite_buffer_s", 0.0, INF, false, false)
	c.num(rec, "bite_miss_cooldown_s", 0.0, INF, false, false)
	# T1.6 bite lunge (optional: missing = off; the distance is per band in size_bands.json)
	c.num(rec, "lunge_strength", 0.0, 1.0, false, false)
	c.num(rec, "lunge_duration_s", 0.0, INF, false, false)
	c.one_of(rec, "player_hp_model", PLAYER_HP_MODELS)
	var full_at: float = _num_or_nan(rec, "xp_falloff.full_at_ratio")
	var min_ratio: float = _num_or_nan(rec, "xp_falloff.min_ratio")
	if not is_nan(full_at) and not is_nan(min_ratio) and min_ratio >= full_at:
		c.add("xp_falloff.min_ratio", "must be < xp_falloff.full_at_ratio")


# ------------------------------------------------------------------ control modes (T1.4; docs/data/controls.md)

## One control mode: {id (snake_case), name, description, mouse_smooth_tau_s (0..MAX_SMOOTH_TAU_S), aim_turn_cap_deg_s?
## (0..MAX_TURN_CAP_DEG_S, 0 = none), aim_assist_strength (0..1), lunge_strength (0..1)}.
static func _check_control_mode(rec: Dictionary, c: _Checker) -> void:
	if not _is_mode_id(rec.get("id")):
		c.add("id", "must be a snake_case string (a-z, 0-9, _; starts with a letter)")
	c.text(rec, "name")
	c.text(rec, "description")
	c.num(rec, "mouse_smooth_tau_s", 0.0, MAX_SMOOTH_TAU_S)
	c.num(rec, "aim_turn_cap_deg_s", 0.0, MAX_TURN_CAP_DEG_S, false, false)
	c.num(rec, "aim_assist_strength", 0.0, 1.0)
	c.num(rec, "lunge_strength", 0.0, 1.0)


# ------------------------------------------------------------------ food (food task; game/data/README.md "Food keys")

## Food type (`food/<id>.json`): {id, name?, kind: soft|hard, pieces: [{id, zones?: [zone ids], above_y?, below_y?}],
## length_m, radius_m, base_hp? (100), hp_mult? (1), swallow_ratio? (0..1, default rules.swallow_ratio), xp,
## hunger_xp? (default xp), xp_band_mult? ([4 x >= 0] by player band), respawn_s, regen_s? (0 = never), sfx,
## fx_colors? (["#rrggbb", ...])}.
static func _check_food(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "id")
	c.text(rec, "name", false)
	c.one_of(rec, "kind", FOOD_KINDS)
	if c.array(rec, "pieces", true, true):
		var list: Array = rec["pieces"]
		for i in list.size():
			if not (list[i] is Dictionary):
				c.add("pieces[%d]" % i, "must be an object")
				continue
			var pc := c.sub("pieces[%d]" % i)
			pc.text(list[i], "id")
			if pc.array(list[i], "zones", false, true):
				for z: Variant in (list[i]["zones"] as Array):
					if not (z is String) or (z as String).is_empty():
						pc.add("zones", "must be an array of zone id strings")
						break
			pc.num(list[i], "above_y", -WORLD_LIMIT_M, WORLD_LIMIT_M, false, false)
			pc.num(list[i], "below_y", -WORLD_LIMIT_M, WORLD_LIMIT_M, false, false)
	c.num(rec, "length_m", 0.0, INF, true)
	c.num(rec, "radius_m", 0.0, INF, true)
	c.num(rec, "base_hp", 0.0, INF, true, false)
	c.num(rec, "hp_mult", 0.0, INF, true, false)
	c.num(rec, "swallow_ratio", 0.0, 1.0, true, false)
	c.num(rec, "xp", 0.0)
	c.num(rec, "hunger_xp", 0.0, INF, false, false)
	if rec.has("xp_band_mult"):
		var m: Variant = rec["xp_band_mult"]
		if not (m is Array) or (m as Array).size() != MAX_BAND_INDEX:
			c.add("xp_band_mult", "must be an array of %d numbers (one per size band)" % MAX_BAND_INDEX)
		else:
			for k in MAX_BAND_INDEX:
				if not c.num_value(m[k], "xp_band_mult[%d]" % k, 0.0):
					break
	c.num(rec, "respawn_s", 0.0)
	c.num(rec, "regen_s", 0.0, INF, false, false)
	c.text(rec, "sfx")
	if c.array(rec, "fx_colors", false):
		for k in (rec["fx_colors"] as Array).size():
			var col: Variant = rec["fx_colors"][k]
			if not (col is String) or not Color.html_is_valid(col):
				c.add("fx_colors[%d]" % k, "must be an HTML colour string (#rrggbb)")


## Baked food sites (`maps/<map_id>_food.json`): {generated_by?, map, dressing_seed?, food_seed?, sites: [{type, piece,
## variant, pos: [x, y, z] (site centre), radius (> 0), base: [x, y, z] (piece origin), rot_y (radians), up: [x, y, z],
## scale (> 0), decor (dressing placement index of an edible decor piece, -1 = own food piece), host? (dressing placement
## index of the host), rule?}]}.
static func _check_food_sites(rec: Dictionary, c: _Checker) -> void:
	c.text(rec, "map")
	c.text(rec, "generated_by", false)
	c.integer(rec, "dressing_seed", 0, 2147483647, false)
	c.integer(rec, "food_seed", 0, 2147483647, false)
	if not c.array(rec, "sites"):
		return
	var list: Array = rec["sites"]
	for i in list.size():
		if not (list[i] is Dictionary):
			c.add("sites[%d]" % i, "must be an object")
			continue
		var s: Dictionary = list[i]
		var sc := c.sub("sites[%d]" % i)
		sc.text(s, "type")
		sc.text(s, "piece")
		sc.integer(s, "variant", 1, 99)
		sc.vec3(s, "pos")
		sc.vec3(s, "base")
		sc.vec3(s, "up")
		sc.num(s, "radius", 0.0, INF, true)
		sc.num(s, "rot_y")
		sc.num(s, "scale", 0.0, MAX_DRESSING_SCALE, true)
		sc.integer(s, "decor", -1, MAX_COUNT)
		sc.integer(s, "host", -1, MAX_COUNT, false)
		sc.text(s, "rule", false)


## Dressing `food` block (presentation + bake input, tools/dressing/bake_food.gd): {seed, view_m?, reach_clearance_m?,
## edible_decor?: {piece id: food type}, rules?: [rule], authored?: [anchor]}; rule {id, hosts: [piece ids], zones?,
## anchor: top|base_ring|stem, chance (0..1), count? [min, max], food, piece?, variants?, scale? [min, max], inset?
## (0..1), ring? [min, max], stem_y? [min, max], max_slope_deg?, sink_m?}; anchor {host (set piece id), food, piece,
## variant?, local: [x, y, z] (attachment point in the host frame), rot_y? (deg), scale?}.
static func _check_dressing_food(f: Dictionary, c: _Checker) -> void:
	c.integer(f, "seed", 0, 2147483647)
	c.num(f, "view_m", 0.0, INF, true, false)
	c.num(f, "reach_clearance_m", 0.0, 1.0, false, false)
	if c.dict(f, "edible_decor", false):
		var decor: Dictionary = f["edible_decor"]
		for pid: Variant in decor:
			if not (decor[pid] is String) or (decor[pid] as String).is_empty():
				c.add("edible_decor.%s" % pid, "must be a food type id")
	if c.array(f, "rules", false):
		var seen: Dictionary = {}
		var rules: Array = f["rules"]
		for i in rules.size():
			if not (rules[i] is Dictionary):
				c.add("rules[%d]" % i, "must be an object")
				continue
			var r: Dictionary = rules[i]
			var rc := c.sub("rules[%d]" % i)
			if rc.text(r, "id"):
				if seen.has(r["id"]):
					rc.add("id", "duplicate food rule id '%s'" % r["id"])
				seen[r["id"]] = true
			if rc.array(r, "hosts", true, true):
				for h: Variant in (r["hosts"] as Array):
					if not (h is String) or (h as String).is_empty():
						rc.add("hosts", "must be an array of piece id strings")
						break
			if rc.array(r, "zones", false, true):
				for z: Variant in (r["zones"] as Array):
					if not (z is String) or (z as String).is_empty():
						rc.add("zones", "must be an array of zone id strings")
						break
			rc.one_of(r, "anchor", FOOD_ANCHORS)
			rc.num(r, "chance", 0.0, 1.0)
			_check_pair(r, "count", 0.0, float(MAX_COUNT), false, false, false, rc)
			rc.text(r, "food")
			rc.text(r, "piece", false)
			if r.has("variants"):
				_check_variants(r["variants"], rc)
			_check_pair(r, "scale", 0.0, MAX_DRESSING_SCALE, true, false, false, rc)
			rc.num(r, "inset", 0.0, 1.0, false, false)
			_check_pair(r, "ring", 0.0, 3.0, false, false, false, rc)
			_check_pair(r, "stem_y", 0.0, 10.0, false, false, false, rc)
			rc.num(r, "max_slope_deg", 0.0, 90.0, false, false)
			rc.num(r, "sink_m", 0.0, 1.0, false, false)
	if c.array(f, "authored", false):
		var list: Array = f["authored"]
		for i in list.size():
			if not (list[i] is Dictionary):
				c.add("authored[%d]" % i, "must be an object")
				continue
			var ac := c.sub("authored[%d]" % i)
			ac.text(list[i], "host")
			ac.text(list[i], "food")
			ac.text(list[i], "piece")
			ac.integer(list[i], "variant", 1, 99, false)
			ac.vec3(list[i], "local")
			ac.num(list[i], "rot_y", -INF, INF, false, false)
			ac.num(list[i], "scale", 0.0, MAX_DRESSING_SCALE, true, false)


## Cross-references of the dressing `food` block: pieces (GLBs), zones of the map, food types (and their piece lists),
## authored hosts = set pieces of this dressing.
func _check_dressing_food_refs(f: Dictionary, rec: Dictionary, zones: Dictionary, pieces: Dictionary, c: _Checker) -> void:
	if f.get("edible_decor") is Dictionary:
		var decor: Dictionary = f["edible_decor"]
		for pid: Variant in decor:
			if not pieces.has(str(pid)):
				c.add("edible_decor.%s" % pid, "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [pid, ENV_MODELS_DIR, pid])
			_check_food_piece_ref(str(decor[pid]), str(pid), pieces, c, "edible_decor.%s" % pid)
	var rules: Array = _array_at(f, "rules")
	for i in rules.size():
		if not (rules[i] is Dictionary):
			continue
		var r: Dictionary = rules[i]
		var path: String = "rules[%d]" % i
		for h: Variant in _array_at(r, "hosts"):
			if h is String and not pieces.has(h):
				c.add(path + ".hosts", "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [h, ENV_MODELS_DIR, h])
		for z: Variant in _array_at(r, "zones"):
			if z is String and not zones.has(z):
				c.add(path + ".zones", "unknown zone '%s' (not in this map)" % z)
		if r.get("food") is String:
			_check_food_piece_ref(str(r["food"]), str(r.get("piece", "")), pieces, c, path)
			if r.get("piece") is String and pieces.has(r["piece"]) and r.has("variants"):
				var top: int = 0
				var vs: Variant = r["variants"]
				for item: Variant in (vs as Array if vs is Array else [vs]):
					if _Checker.is_num(item):
						top = maxi(top, int(item))
				if top > int(pieces[r["piece"]]):
					c.add(path + ".variants", "variant %d of '%s' does not exist (GLBs v1..v%d)" % [top, r["piece"], pieces[r["piece"]]])
	var sets: Dictionary = {}
	for sp: Variant in _array_at(rec, "set_pieces"):
		if sp is Dictionary and (sp as Dictionary).get("id") is String:
			sets[sp["id"]] = true
	var list: Array = _array_at(f, "authored")
	for i in list.size():
		if not (list[i] is Dictionary):
			continue
		var a: Dictionary = list[i]
		var path: String = "authored[%d]" % i
		if a.get("host") is String and not sets.has(a["host"]):
			c.add(path + ".host", "unknown set piece '%s' (not in this dressing's set_pieces)" % a["host"])
		if a.get("food") is String and a.get("piece") is String:
			_check_food_piece_ref(str(a["food"]), str(a["piece"]), pieces, c, path)
			if pieces.has(a["piece"]) and _Checker.is_num(a.get("variant", 1)) and int(a.get("variant", 1)) > int(pieces[a["piece"]]):
				c.add(path + ".variant", "variant %d of '%s' does not exist (GLBs v1..v%d)" % [int(a["variant"]), a["piece"], pieces[a["piece"]]])


# `food` must be a known food type; `piece` ("" = chosen by the type) a GLB listed in the type's pieces.
func _check_food_piece_ref(food: String, piece: String, pieces: Dictionary, c: _Checker, path: String) -> void:
	var t: Dictionary = _foods.get(food, {})
	if t.is_empty():
		c.add(path + ".food", "unknown food type '%s' (no food/%s.json)" % [food, food])
		return
	if piece.is_empty():
		return
	if not pieces.has(piece):
		c.add(path + ".piece", "unknown piece '%s' (no %s/env_%s_v1_lod0.glb)" % [piece, ENV_MODELS_DIR, piece])
	elif not _food_piece_ids(t).has(piece):
		c.add(path + ".piece", "piece '%s' is not listed in food/%s.json pieces" % [piece, food])


static func _food_piece_ids(t: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for p: Variant in _array_at(t, "pieces"):
		if p is Dictionary and (p as Dictionary).get("id") is String:
			out.append(p["id"])
	return out


# ------------------------------------------------------------------ helpers

static func _sorted_ids(records: Dictionary) -> Array[StringName]:
	var keys: Array[String] = []
	for k in records:
		keys.append(k)
	keys.sort()
	var out: Array[StringName] = []
	for k in keys:
		out.append(StringName(k))
	return out


static func _is_mode_id(v: Variant) -> bool:
	if not (v is String):
		return false
	var re := RegEx.new()
	re.compile("^[a-z][a-z0-9_]*$")
	return re.search(v) != null


## Number at a dotted path, or NAN when missing or not a number.
static func _num_or_nan(rec: Dictionary, path: String) -> float:
	var found: Array = _Checker.lookup(rec, path)
	if found.is_empty() or not _Checker.is_num(found[0]):
		return NAN
	return float(found[0])


static func _is_whole(f: float) -> bool:
	return absf(f - roundf(f)) < 1e-9


static func _array_at(rec: Dictionary, key: String) -> Array:
	var v: Variant = rec.get(key)
	return v if v is Array else []


## Collects schema errors for one source; paths are dotted and relative to the checked dictionary,
## prefixed with `prefix` (e.g. `bands[1]`) in error messages.
class _Checker:
	extends RefCounted

	var source: String
	var prefix: String
	var errors: Array[String]

	func _init(p_source: String, p_errors: Array[String], p_prefix: String = "") -> void:
		source = p_source
		errors = p_errors
		prefix = p_prefix

	## Checker for a nested record that shares this checker's error list.
	func sub(path: String) -> _Checker:
		return _Checker.new(source, errors, full(path))

	func full(path: String) -> String:
		if prefix.is_empty():
			return path
		if path.begins_with("["):
			return prefix + path
		return "%s.%s" % [prefix, path]

	func add(path: String, problem: String) -> void:
		errors.append("%s: %s: %s" % [source, full(path), problem])

	## [value] when the dotted path exists, [] otherwise.
	static func lookup(rec: Dictionary, path: String) -> Array:
		var cur: Variant = rec
		for part in path.split("."):
			if not (cur is Dictionary) or not (cur as Dictionary).has(part):
				return []
			cur = (cur as Dictionary)[part]
		return [cur]

	static func is_num(v: Variant) -> bool:
		return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

	static func fmt(f: float) -> String:
		if f == floorf(f) and absf(f) < 1e15:
			return str(int(f))
		return str(f)

	## Found value wrapped in an array, or [] (with an error when required).
	func _found(rec: Dictionary, path: String, required: bool) -> Array:
		var found: Array = lookup(rec, path)
		if found.is_empty() and required:
			add(path, "is required")
		return found

	## True when a valid number is present. Optional + missing -> false without an error.
	func num(rec: Dictionary, path: String, lo: float = -INF, hi: float = INF, lo_exclusive: bool = false, required: bool = true) -> bool:
		var found: Array = _found(rec, path, required)
		if found.is_empty():
			return false
		return num_value(found[0], path, lo, hi, lo_exclusive)

	func num_value(v: Variant, path: String, lo: float = -INF, hi: float = INF, lo_exclusive: bool = false) -> bool:
		if not is_num(v):
			add(path, "must be a number")
			return false
		var f: float = float(v)
		# JSON like 1e999 parses to INF; no schema field accepts a non-finite value.
		if is_nan(f) or is_inf(f):
			add(path, "must be a finite number")
			return false
		if lo_exclusive and f <= lo:
			add(path, "must be > %s" % fmt(lo))
			return false
		if f < lo:
			add(path, "must be >= %s" % fmt(lo))
			return false
		if f > hi:
			add(path, "must be <= %s" % fmt(hi))
			return false
		return true

	func integer(rec: Dictionary, path: String, lo: int, hi: int, required: bool = true) -> bool:
		var found: Array = _found(rec, path, required)
		if found.is_empty():
			return false
		var v: Variant = found[0]
		if not is_num(v) or float(v) != floorf(float(v)) or float(v) < lo or float(v) > hi:
			add(path, "must be an integer in %d..%d" % [lo, hi])
			return false
		return true

	func text(rec: Dictionary, path: String, required: bool = true) -> bool:
		var found: Array = _found(rec, path, required)
		if found.is_empty():
			return false
		if not (found[0] is String) or (found[0] as String).is_empty():
			add(path, "must be a non-empty string")
			return false
		return true

	func one_of(rec: Dictionary, path: String, allowed: Array[String]) -> bool:
		var found: Array = _found(rec, path, true)
		if found.is_empty():
			return false
		if not (found[0] is String) or not allowed.has(found[0]):
			add(path, "must be one of %s" % "|".join(PackedStringArray(allowed)))
			return false
		return true

	func dict(rec: Dictionary, path: String, required: bool = true) -> bool:
		var found: Array = _found(rec, path, required)
		if found.is_empty():
			return false
		if not (found[0] is Dictionary):
			add(path, "must be an object")
			return false
		return true

	func array(rec: Dictionary, path: String, required: bool = true, non_empty: bool = false) -> bool:
		var found: Array = _found(rec, path, required)
		if found.is_empty():
			return false
		if not (found[0] is Array):
			add(path, "must be an array")
			return false
		if non_empty and (found[0] as Array).is_empty():
			add(path, "must not be empty")
			return false
		return true

	## `{min, max}` block: both numbers above `lo` (exclusive when `lo_exclusive`), max >= min.
	func range_block(rec: Dictionary, path: String, lo: float, lo_exclusive: bool, required: bool = true) -> bool:
		if not dict(rec, path, required):
			return false
		var has_min: bool = num(rec, path + ".min", lo, INF, lo_exclusive)
		var has_max: bool = num(rec, path + ".max", lo, INF, lo_exclusive)
		if not (has_min and has_max):
			return false
		var block: Dictionary = lookup(rec, path)[0]
		if float(block["max"]) < float(block["min"]):
			add(path + ".max", "must be >= %s.min" % full(path))
			return false
		return true

	func vec3(rec: Dictionary, path: String) -> bool:
		var found: Array = _found(rec, path, true)
		if found.is_empty():
			return false
		return vec3_value(found[0], path)

	## [x, y, z] numbers inside the +-WORLD_LIMIT_M world box.
	func vec3_value(v: Variant, path: String) -> bool:
		if not (v is Array) or (v as Array).size() != 3:
			add(path, "must be an [x, y, z] array")
			return false
		for item in (v as Array):
			if not is_num(item):
				add(path, "must be an [x, y, z] array of numbers")
				return false
			if not is_finite(float(item)) or absf(float(item)) > WORLD_LIMIT_M:
				add(path, "must stay within +-%s m of the origin" % fmt(WORLD_LIMIT_M))
				return false
		return true
