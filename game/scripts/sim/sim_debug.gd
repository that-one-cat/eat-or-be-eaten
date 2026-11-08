class_name SimDebug
extends RefCounted
## Test and debug hooks for scripted UI tests, bots and scenarios. NEVER called by normal play: every hook bypasses
## the command path (rule 2) on purpose to reach a situation quickly. Each one changes the world the way the real
## rules would and emits the same events, so presentation code under test reacts exactly as in a run.
##  - force_band_up(world, id): gives the player the XP of the next band threshold; the next step()'s growth phase
##    emits BAND_UP and (first time for that band) MUTATION_OFFERED, which pauses a single-player world.
##  - set_xp(world, id, xp): sets the player's XP; growth re-derives band / length / max HP on the next step().
##  - set_boss_hp(world, hp): sets the boss HP (0 = it is STUNNED in the next step()'s boss phase).
##  - force_victory(world, id = -1): run_won + VICTORY now (entity = `id`, else the finisher, else the first player);
##    no-op when the run is already won.
## God tools (T1.2, the console / F1 menu of GodHost; debug and test builds only):
##  - State + state(world): the override flags, created on first use as `world.debug` (null = normal rules; the object is never hashed, an
##    empty State hashes like null, but active flags show in state_hash through entity hp / hunger). SimWorld calls apply_overrides() once per step
##    (before the death phase) and noclip_constrain() from _constrain; time_scale is read by GameLoop only.
##  - teleport, set_band, heal: player placement / progression; set_god, set_hunger_lock, set_noclip, set_time_scale: flags.
##  - spawn_species, spawn_food_bits, despawn_debug: creatures and food bits at a point (ids are remembered for despawn).
##  - boss_stun, boss_heal: boss HP shortcuts (set_boss_hp / force_victory above cover the rest).
## Tuning lab (T1.3, same callers): `State.tuning` holds the TuningOverrides of the world (null until first used; EMPTY by default
##    and never created by normal play). tuning / tuning_set / tuning_reset / tuning_save / tuning_load / tuning_export are the only
##    way the God tools change it; every change re-derives the sim's cached rule and band numbers (SimWorld._retune) so it acts on the
##    next tick. An empty layer adds nothing to state_hash; a non-empty one is hashed (TuningOverrides.write_state).

## Returns false when `player_id` is not a player or is already in the last band.
static func force_band_up(world: SimWorld, player_id: int) -> bool:
	var e: SimEntity = world.get_entity(player_id)
	if e == null or not e.is_player or world.content == null or e.band >= world.content.band_count():
		return false
	e.xp = maxf(e.xp, float(world.content.get_band(e.band + 1).get("xp_to_reach", e.xp)))
	return true


static func set_xp(world: SimWorld, player_id: int, xp: float) -> bool:
	var e: SimEntity = world.get_entity(player_id)
	if e == null or not e.is_player:
		return false
	e.xp = maxf(xp, 0.0)
	return true


## Returns false when there is no boss.
static func set_boss_hp(world: SimWorld, hp: float) -> bool:
	var b: SimEntity = world.get_entity(world.boss_id())
	if b == null:
		return false
	b.hp = clampf(hp, 0.0, b.max_hp)
	return true


static func force_victory(world: SimWorld, player_id: int = -1) -> void:
	if world.run_won:
		return
	if player_id >= 0:
		world._boss_finisher = player_id
	elif world._boss_finisher < 0 and not world.players().is_empty():
		world._boss_finisher = world.players()[0].id
	world._win()


# ------------------------------------------------------------------ God tools (T1.2)

const TIME_SCALE_MIN: float = 0.05
const TIME_SCALE_MAX: float = 8.0
## Default XP of one debug food bit.
const FOOD_BIT_XP: float = 2.0
## Radius (m) of the ring a batch of debug food bits is spread on, and the golden angle between neighbours.
const FOOD_SPREAD_M: float = 0.5
const GOLDEN_ANGLE: float = 2.399963

## Override flags of one world (`world.debug`). All off / 1.0 = the normal rules.
class State:
	extends RefCounted
	## Players cannot die: HP is refilled before the death phase of every step.
	var god: bool = false
	## Players' hunger stays at the maximum.
	var hunger_lock: bool = false
	## Players ignore the seabed and obstacles (the map box and the surface still hold).
	var noclip: bool = false
	## Multiplies the frame delta in GameLoop (more / fewer ticks per second); the sim itself is unchanged.
	var time_scale: float = 1.0
	## Entities created by spawn_species / spawn_food_bits that despawn_debug removes.
	var spawned_ids: PackedInt32Array = PackedInt32Array()
	## Runtime overrides over the rules and the band tables (T1.3); null until `SimDebug.tuning(world)` first runs.
	var tuning: TuningOverrides = null


## The override state of `world`, created on first use.
static func state(world: SimWorld) -> State:
	if world.debug == null:
		world.debug = State.new()
	return world.debug


## The tuning override layer of `world` (registry loaded and validated on first use; empty until something is set).
static func tuning(world: SimWorld) -> TuningOverrides:
	var st: State = state(world)
	if st.tuning == null:
		st.tuning = TuningOverrides.create(world.content)
	return st.tuning


## Overrides registry row `id` with `v`. Returns "" on success, else why it was refused (nothing changes).
static func tuning_set(world: SimWorld, id: String, v: Variant) -> String:
	var err: String = tuning(world).set_value(id, v)
	if err.is_empty():
		world._retune()
	return err


## Drops the override of `id` ("" = every override). Returns false for an unknown id.
static func tuning_reset(world: SimWorld, id: String = "") -> bool:
	var t: TuningOverrides = tuning(world)
	if id.is_empty():
		t.reset_all()
	elif not t.reset(id):
		return false
	world._retune()
	return true


## Replaces the layer with the preset `name` of TuningOverrides.preset_dir. Returns "" or why not (then nothing changes).
static func tuning_load(world: SimWorld, name: String) -> String:
	var err: String = tuning(world).load_preset(name)
	if err.is_empty():
		world._retune()
	return err


## Writes the layer to TuningOverrides.preset_dir. Returns "" or why not.
static func tuning_save(world: SimWorld, name: String) -> String:
	return tuning(world).save_preset(name)


## Writes the layer to the repo's reports/tuning (TuningOverrides.export_dir). Returns "" or why not.
static func tuning_export(world: SimWorld, name: String) -> String:
	return tuning(world).export_preset(name)


## Moves a living creature to `pos` (resolved against the seabed, obstacles, surface and map box like a spawn), stops
## it and syncs the grid. Returns false for an unknown / dead entity or a non-finite position.
static func teleport(world: SimWorld, id: int, pos: Vector3) -> bool:
	var e: SimEntity = world.get_entity(id)
	if e == null or e.kind != SimEntity.Kind.CREATURE or not e.alive or not pos.is_finite():
		return false
	world._configure()
	e.position = world._constrain(e, pos) if world.seabed != null else pos
	e.velocity = Vector3.ZERO
	e.dash_velocity = Vector3.ZERO
	e.speed = 0.0
	world._grid_sync(e)
	return true


## Sets the player's XP to the threshold of `band` (clamped to 1..band_count); the next step() derives band, length and
## HP. Jumping straight to band N offers only band N's mutation. Returns the band set, 0 for a non-player / no content.
static func set_band(world: SimWorld, player_id: int, band: int) -> int:
	if world.content == null or world.content.band_count() < 1:
		return 0
	var b: int = clampi(band, 1, world.content.band_count())
	if not set_xp(world, player_id, float(world.content.get_band(b).get("xp_to_reach", 0.0))):
		return 0
	return b


## Full HP for a living player. Returns false for a non-player / a dead one.
static func heal(world: SimWorld, player_id: int) -> bool:
	var e: SimEntity = world.get_entity(player_id)
	if e == null or not e.is_player or not e.alive:
		return false
	e.hp = e.max_hp
	return true


static func set_god(world: SimWorld, on: bool) -> bool:
	state(world).god = on
	return on


static func set_hunger_lock(world: SimWorld, on: bool) -> bool:
	state(world).hunger_lock = on
	return on


static func set_noclip(world: SimWorld, on: bool) -> bool:
	state(world).noclip = on
	return on


## Returns the scale in force (clamped to TIME_SCALE_MIN..TIME_SCALE_MAX; a non-finite value changes nothing).
static func set_time_scale(world: SimWorld, scale: float) -> float:
	var st: State = state(world)
	if is_finite(scale):
		st.time_scale = clampf(scale, TIME_SCALE_MIN, TIME_SCALE_MAX)
	return st.time_scale


## Why spawn_species would refuse `species_id` ("" = it can be spawned): unknown species, ambient tier (never a
## SimEntity) or a second boss while one is alive.
static func spawn_refusal(world: SimWorld, species_id: StringName) -> String:
	if world.content == null:
		return "no content"
	var sp: Dictionary = world.content.get_species(species_id)
	if sp.is_empty():
		return "unknown species '%s'" % species_id
	var tier: String = str(sp.get("tier", ""))
	if tier != "interactive" and tier != "large":
		return "'%s' is %s tier (only interactive / large species are entities)" % [species_id, tier if not tier.is_empty() else "untiered"]
	if sp.get("boss") is Dictionary and world.boss_id() >= 0:
		return "a boss is already alive"
	return ""


## Spawns one NPC of `species_id` at `pos` (resolved against the terrain) facing `heading`, with `length_m` clamped to
## the species range (< 0 = the middle of it). Returns its id, -1 when refused (see spawn_refusal). Debug spawns count
## toward the tier caps and have no spawner home zone.
static func spawn_species(world: SimWorld, species_id: StringName, pos: Vector3, length_m: float = -1.0, heading: Vector3 = Vector3.FORWARD) -> int:
	if not spawn_refusal(world, species_id).is_empty() or not pos.is_finite():
		return -1
	var range_m: Variant = world.content.get_species(species_id).get("length_m")
	var lo: float = float((range_m as Dictionary).get("min", 1.0)) if range_m is Dictionary else 1.0
	var hi: float = float((range_m as Dictionary).get("max", lo)) if range_m is Dictionary else lo
	var len: float = (lo + hi) * 0.5 if length_m < 0.0 or not is_finite(length_m) else clampf(length_m, lo, hi)
	var id: int = NpcSpawner.spawn_npc(world, species_id, pos, len, heading)
	var e: SimEntity = world.get_entity(id)
	if world.seabed != null:
		e.position = world._constrain(e, e.position)
	world._grid_sync(e)
	state(world).spawned_ids.append(id)
	return id


## Spawns `count` (1..64) glowing food bits on a small ring around `pos`, each worth `xp_each` (<= 0 = FOOD_BIT_XP)
## XP and the matching hunger, living for the rules.remains lifetime. The XP does not fall off with the eater's size.
## Returns the bit ids. Food SITES (eggs, starfish...) are baked data and cannot be added at runtime.
static func spawn_food_bits(world: SimWorld, pos: Vector3, count: int = 5, xp_each: float = -1.0) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if world.content == null or not pos.is_finite():
		return out
	world._configure()
	var xp: float = xp_each if xp_each > 0.0 and is_finite(xp_each) else FOOD_BIT_XP
	var source_len: float = 1.0
	for pl: SimEntity in world.players():
		source_len = maxf(source_len, pl.length_m)
	var st: State = state(world)
	for i in clampi(count, 1, 64):
		var angle: float = GOLDEN_ANGLE * float(i)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var b: SimEntity = world._new_entity()
		b.kind = SimEntity.Kind.FOOD_BIT
		b.species_id = SimWorld.FOOD_BIT_SPECIES_ID
		b.length_m = world._bit_len
		var at: Vector3 = pos + dir * (FOOD_SPREAD_M * sqrt(float(i)) * 0.5)
		b.position = world._clamp_point(world.seabed.resolve(at, world.collision_radius(b)), world.collision_radius(b)) if world.seabed != null else at
		b.velocity = dir * world._bit_drift
		b.heading = dir
		b.xp_value = xp
		b.hunger_value = SimRules.hunger_from_xp(xp, world._hunger_per_xp)
		b.source_length_m = source_len
		b.expire_tick = world.tick + world._bit_life_ticks
		world._add(b)
		world._emit(SimEvent.Type.FOOD_SPAWNED, b.id, -1, xp)
		out.append(b.id)
		st.spawned_ids.append(b.id)
	return out


## Removes every entity made by spawn_species / spawn_food_bits that still exists. Returns how many were removed.
static func despawn_debug(world: SimWorld) -> int:
	if world.debug == null:
		return 0
	var n: int = 0
	for id: int in world.debug.spawned_ids:
		if world.remove_entity(id):
			n += 1
	world.debug.spawned_ids = PackedInt32Array()
	return n


## Boss HP to 0: it is STUNNED in the next step()'s boss phase. Returns false when there is no boss.
static func boss_stun(world: SimWorld) -> bool:
	return set_boss_hp(world, 0.0)


## Boss HP to its maximum. Returns false when there is no boss.
static func boss_heal(world: SimWorld) -> bool:
	var b: SimEntity = world.get_entity(world.boss_id())
	return b != null and set_boss_hp(world, b.max_hp)


## Called by SimWorld.step() (only while `world.debug != null`) after the bite and boss phases, before the death phase:
## god mode refills every living player's HP (so this tick's lethal damage is undone before _die), the hunger lock
## refills hunger. Starvation of the vitals phase is undone the same way on the next step.
static func apply_overrides(world: SimWorld) -> void:
	var st: State = world.debug
	if st == null or not (st.god or st.hunger_lock):
		return
	for p: SimEntity in world.players():
		if not p.alive:
			continue
		if st.god:
			p.hp = p.max_hp
		if st.hunger_lock:
			p.hunger = world._hunger_max


## SimWorld._constrain for a player while noclip is on: only the surface, the floor of the map (-depth) and the map box.
static func noclip_constrain(world: SimWorld, e: SimEntity, p: Vector3) -> Vector3:
	var r: float = world.collision_radius(e)
	return Vector3(
		clampf(p.x, -world._half_size + r, world._half_size - r),
		clampf(p.y, -world._depth + r, -r),
		clampf(p.z, -world._half_size + r, world._half_size - r))
