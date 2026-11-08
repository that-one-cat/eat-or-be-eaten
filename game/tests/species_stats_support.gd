extends RefCounted
## Shared kit for the T1.7 per-species movement stats tests (res://tests/species_stats_support.gd). Not a test file:
## the runner only collects scripts named test_*.gd. Use via `const SS := preload("res://tests/species_stats_support.gd")`.
##
## NAME TABLE: the schema places (flat keys vs a `movement` block, the `player_profile` multiplier key names) were
## chosen by the implementer, so every lookup below accepts both layouts. If the implementation uses other names,
## adapt this table only (the tests never spell a key outside it).
##
## Baselines: BASELINE_* are state_hash values captured BEFORE the T1.7 change (see the test plan for the exact
## command). The identity backfill requires them to stay byte-identical.

const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const TMP_ROOT: String = "user://species_stats_tmp"

## The 11 shipped species ids (frozen: the task is about backfilling exactly these).
const SHIPPED_SPECIES: Array[String] = [
	"barracuda", "giant_shark", "grouper", "krill_abyss", "krill_open", "krill_shallows",
	"plankton", "puffer", "shark", "silver_schooling_fish", "small_reef_fish",
]

## Frozen pre-change `swim_speed_mps` of every shipped species (canonical key, must not change or be renamed).
const BASELINE_SPEED: Dictionary = {
	"plankton": 0.2, "giant_shark": 7.0, "barracuda": 8.0, "small_reef_fish": 2.0, "silver_schooling_fish": 2.5,
	"puffer": 1.2, "shark": 6.5, "krill_shallows": 0.4, "krill_abyss": 0.4, "krill_open": 0.4, "grouper": 2.0,
}

## New per-species movement fields (the canonical speed key `swim_speed_mps` stays as it is).
const NEW_FIELDS: Array[String] = [
	"boost_mult", "boost_stamina", "turn_rate_deg_s", "accel_mps2", "drag_per_s", "brake_decel_mps2", "depth_range_m",
]
## Scalar numeric new fields (depth_range_m is a range, handled separately).
const SCALAR_FIELDS: Array[String] = [
	"boost_mult", "boost_stamina", "turn_rate_deg_s", "accel_mps2", "drag_per_s", "brake_decel_mps2",
]

## Block names tried for the grouped layout, in order.
const MOVEMENT_BLOCKS: Array[String] = ["movement"]
## player_profile multiplier key candidates per movement quantity (first match in the shipped / edited record wins,
## then a substring match, then the first candidate is used).
const PROFILE_KEYS: Dictionary = {
	"speed": ["swim_speed_mult", "swim_speed_mps_mult", "speed_mult", "swim_speed"],
	"turn": ["turn_rate_mult", "turn_rate_deg_s_mult", "turn_mult", "turn_rate"],
	"accel": ["accel_mult", "accel_mps2_mult", "acceleration_mult", "accel"],
	"drag": ["drag_mult", "drag_per_s_mult", "drag"],
	"brake": ["brake_mult", "brake_decel_mult", "brake_decel_mps2_mult", "brake"],
}
const PROFILE_BLOCK: String = "player_profile"

## state_hash values of the deterministic probe scenarios on the PRE-change code (shipped data, default profile).
## Captured with the probe scenarios of baseline_hashes() (Godot 4.7.2, macOS arm64).
const BASELINE_HASHES: Dictionary = {
	"player_band_1": -1545991630045483898, "player_band_2": 982161711152018542,
	"player_band_3": 7467221309544426979, "player_band_4": 4555161850365424499,
	"s3_real_4242_900": 7096022500323752592, "s3_real_77_1800": 5163799907134584225,
	"npc_barracuda": 8541926551619623688, "npc_giant_shark": 1946175541572911294,
	"npc_grouper": -8798767754497346965, "npc_krill_abyss": 3910232007453197065,
	"npc_krill_open": -2509461837538009402, "npc_krill_shallows": -1685343980485379102,
	"npc_plankton": 5212924258354355176, "npc_puffer": 6742949235918809241,
	"npc_shark": -5881070842827922619, "npc_silver_schooling_fish": 6302597001958451929,
	"npc_small_reef_fish": 4363781149561517789,
}


# ======================================================================= record access (both layouts)

## The grouped block holding `key` in `rec` ({} when the layout is flat).
static func block_with(rec: Dictionary, key: String) -> Dictionary:
	for b: String in MOVEMENT_BLOCKS:
		if rec.get(b) is Dictionary and (rec[b] as Dictionary).has(key):
			return rec[b]
	return {}


static func has_stat(rec: Dictionary, key: String) -> bool:
	return rec.has(key) or not block_with(rec, key).is_empty()


## Value of a movement stat wherever the implementation stored it (movement block first, then flat), null if absent.
static func stat(rec: Dictionary, key: String) -> Variant:
	var blk: Dictionary = block_with(rec, key)
	if not blk.is_empty():
		return blk[key]
	return rec.get(key)


## Writes a stat where it already lives (grouped or flat); a missing one goes where its siblings are.
static func set_stat(rec: Dictionary, key: String, value: Variant) -> void:
	var blk: Dictionary = block_with(rec, key)
	if not blk.is_empty():
		blk[key] = value
		return
	if rec.has(key):
		rec[key] = value
		return
	for b: String in MOVEMENT_BLOCKS:
		if rec.get(b) is Dictionary:
			(rec[b] as Dictionary)[key] = value
			return
	rec[key] = value


## Removes a stat from every place it lives.
static func erase_stat(rec: Dictionary, key: String) -> void:
	rec.erase(key)
	for b: String in MOVEMENT_BLOCKS:
		if rec.get(b) is Dictionary:
			(rec[b] as Dictionary).erase(key)


static func is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## [lo, hi] of a depth_range_m value given as [lo, hi] or {min, max}; empty when it is neither.
static func depth_pair(v: Variant) -> Array[float]:
	var out: Array[float] = []
	if v is Array and (v as Array).size() == 2 and is_num(v[0]) and is_num(v[1]):
		out.append(float(v[0]))
		out.append(float(v[1]))
	elif v is Dictionary and is_num((v as Dictionary).get("min")) and is_num((v as Dictionary).get("max")):
		out.append(float(v["min"]))
		out.append(float(v["max"]))
	return out


## Same shape as `v` with its two numbers replaced.
static func depth_like(v: Variant, lo: Variant, hi: Variant) -> Variant:
	if v is Dictionary:
		return {"min": lo, "max": hi}
	return [lo, hi]


# ======================================================================= player profile

## The record of the player species (first playable in sorted order, as SimWorld picks it).
static func player_species_id(db: ContentDB) -> StringName:
	var ids: Array[StringName] = db.species_ids()
	ids.sort()
	for id: StringName in ids:
		if db.get_species(id).get("playable") == true:
			return id
	return &"small_reef_fish"


## The profile dictionary of a (mutable) species record, created flat under `player_profile` when absent.
static func profile_of(rec: Dictionary) -> Dictionary:
	if rec.get(PROFILE_BLOCK) is Dictionary:
		return rec[PROFILE_BLOCK]
	for b: String in MOVEMENT_BLOCKS:
		if rec.get(b) is Dictionary and (rec[b] as Dictionary).get(PROFILE_BLOCK) is Dictionary:
			return rec[b][PROFILE_BLOCK]
	rec[PROFILE_BLOCK] = {}
	return rec[PROFILE_BLOCK]


## Key of the multiplier for `what` ("speed" | "turn" | "accel" | "drag" | "brake") inside `profile`.
static func profile_key(profile: Dictionary, what: String) -> String:
	var cands: Array = PROFILE_KEYS[what]
	for c: String in cands:
		if profile.has(c):
			return c
	for k: Variant in profile.keys():
		if String(k).contains(what):
			return String(k)
	return cands[0]


## Sets one profile multiplier on the player species of a temp data tree.
static func edit_profile(root: String, what: String, mult: float) -> void:
	var path: String = root.path_join("species/%s.json" % String(player_species_id(ContentDB.load_from_dir("res://data"))))
	var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var prof: Dictionary = profile_of(rec)
	prof[profile_key(prof, what)] = mult
	write_text(path, JSON.stringify(rec, "\t"))


## Sets every multiplier already present in the shipped profile (or the five candidates) to `mult`.
static func edit_profile_all(root: String, mult: float) -> void:
	var path: String = root.path_join("species/%s.json" % String(player_species_id(ContentDB.load_from_dir("res://data"))))
	var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var prof: Dictionary = profile_of(rec)
	for what: String in PROFILE_KEYS.keys():
		prof[profile_key(prof, what)] = mult
	write_text(path, JSON.stringify(rec, "\t"))


# ======================================================================= temp data trees

static func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


static func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	if d == null:
		return
	for sub in d.get_directories():
		_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f in d.get_files():
		if f.ends_with(".json"):
			write_text(dst.path_join(f), FileAccess.get_file_as_string(src.path_join(f)))


static func remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		remove_dir(path.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


## ContentDB loaded from a throw-away copy of res://data (JSON) after `edit.call(root)`. Caller: cleanup() in after_each.
static func db_with(edit: Callable) -> ContentDB:
	remove_dir(TMP_ROOT)
	_copy_dir("res://data", TMP_ROOT)
	edit.call(TMP_ROOT)
	return ContentDB.load_from_dir(TMP_ROOT)


static func cleanup() -> void:
	remove_dir(TMP_ROOT)


## The shipped content with a profile edit applied (what: "speed"|"turn"|"accel"|"drag"|"brake").
static func db_with_profile(what: String, mult: float) -> ContentDB:
	return db_with(func(root: String) -> void: edit_profile(root, what, mult))


# ======================================================================= probes (player movement e2e)

## Player of `db`'s player species at the abyss lane in band `band_index` (S2 geometry), velocity zero, heading +X.
static func lane_world(db: ContentDB, band_index: int = 1, world_seed: int = 3) -> SimWorld:
	var w := SimWorld.new(world_seed, db)
	S2.spawn_at(w, S2.lane_start(), Vector3.RIGHT, band_index)
	return w


static func lane_player(w: SimWorld) -> SimEntity:
	return w.players()[0]


## Peak speed over `ticks` ticks of full thrust along +X from rest.
static func peak_speed(db: ContentDB, band_index: int, ticks: int) -> float:
	var w: SimWorld = lane_world(db, band_index)
	var e: SimEntity = lane_player(w)
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 1.0))
	var peak: float = 0.0
	for i in ticks:
		w.step()
		peak = maxf(peak, e.velocity.length())
	return peak


## Speed after `ticks` ticks of full thrust from rest (pure acceleration phase when ticks is small).
static func speed_after_thrust(db: ContentDB, band_index: int, ticks: int) -> float:
	var w: SimWorld = lane_world(db, band_index)
	var e: SimEntity = lane_player(w)
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 1.0))
	for i in ticks:
		w.step()
	return e.velocity.length()


## Angle (deg) the heading turned in `ticks` ticks when the intent is `turn_deg` away from +X in the XZ plane.
static func heading_turned_deg(db: ContentDB, band_index: int, ticks: int, turn_deg: float) -> float:
	var w: SimWorld = lane_world(db, band_index)
	var e: SimEntity = lane_player(w)
	var dir: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(turn_deg))
	w.submit(SimCommand.move(e.id, dir, 0.0))
	for i in ticks:
		w.step()
	return S2.angle_deg(Vector3.RIGHT, e.heading)


## Speed after `ticks` ticks of coasting from `v0` m/s (thrust 0, no brake).
static func speed_after_coast(db: ContentDB, band_index: int, v0: float, ticks: int) -> float:
	var w: SimWorld = lane_world(db, band_index)
	var e: SimEntity = lane_player(w)
	e.velocity = Vector3.RIGHT * v0
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 0.0))
	for i in ticks:
		w.step()
	return e.velocity.length()


## Speed after `ticks` ticks of braking from `v0` m/s.
static func speed_after_brake(db: ContentDB, band_index: int, v0: float, ticks: int) -> float:
	var w: SimWorld = lane_world(db, band_index)
	var e: SimEntity = lane_player(w)
	e.velocity = Vector3.RIGHT * v0
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 0.0))
	w.submit(SimCommand.brake(e.id, true))
	for i in ticks:
		w.step()
	return e.velocity.length()


# ======================================================================= deterministic hash scenarios

## Scripted player movement (cruise / boost / brake / cruise segments) in band `b`, 400 ticks, S2 lane.
static func hash_player_band(db: ContentDB, b: int) -> int:
	var w: SimWorld = lane_world(db, b, 3)
	var e: SimEntity = lane_player(w)
	S2.submit_segments(w, e.id, S2.movement_script(2000 + b, 400, true, true), true)
	S2.run(w, 400)
	return w.state_hash()


## Shipped spawners + schools + scripted player with a bite every 45 ticks (the S3 determinism journey).
static func hash_real_world(db: ContentDB, world_seed: int, ticks: int, spawn_index: int) -> int:
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = true
	NpcSpawner.set_enabled(w, true)
	var id: int = w.spawn_player(spawn_index)
	S2.submit_segments(w, id, S2.movement_script(1001 + spawn_index, ticks, true, true), true)
	var t: int = 40
	while t < ticks:
		w.submit(SimCommand.bite(id, -1, t))
		t += 45
	S2.run(w, ticks)
	return w.state_hash()


## One NPC of `species` plus a band-2 player 14 m away that swims at it for 100 ticks then idles; 600 ticks.
## Exercises wander / flee / chase / boost speeds of that species (no spawners, no schools).
static func hash_npc(db: ContentDB, species: String) -> int:
	var w := SimWorld.new(9, db)
	w.vitals_enabled = true
	var npc_pos: Vector3 = S3.ARENA
	var p: SimEntity = S3.player_at(w, npc_pos + Vector3(-14.0, 0.0, 0.0), 150.0, Vector3.RIGHT)
	S3.npc_at(w, StringName(species), npc_pos)
	for t in 100:
		w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0, t))
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 0.0, 100))
	S2.run(w, 600)
	return w.state_hash()


## All baseline probes by name (same keys as BASELINE_HASHES).
static func baseline_hashes(db: ContentDB) -> Dictionary:
	var out: Dictionary = {}
	for b in range(1, 5):
		out["player_band_%d" % b] = hash_player_band(db, b)
	out["s3_real_4242_900"] = hash_real_world(db, 4242, 900, 0)
	out["s3_real_77_1800"] = hash_real_world(db, 77, 1800, 1)
	for sp: String in SHIPPED_SPECIES:
		out["npc_%s" % sp] = hash_npc(db, sp)
	return out
