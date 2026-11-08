class_name SimWorld
extends RefCounted
## Authoritative simulation state: entities, fixed 30 Hz tick, command queue, seeded RNG, event log, the one
## spatial grid. Pure logic (no nodes, no SceneTree, no wall clock); presentation reads state and events only.
##
## Swim model (per tick, every tunable from data: size band, abilities/boost.json, rules swim, map bounds):
## MOVE turns `heading` toward the aim direction (turn_rate_deg_s, pitch clamped to rules swim.max_pitch_deg,
## no roll); with thrust > 0 the velocity moves toward heading * thrust * max_speed at accel_mps2, without
## thrust it decays with drag_per_s, and BRAKE decelerates at brake_decel_mps2 (brake wins over thrust).
## max_speed = band swim_speed_mps, x boost speed_mult while boosting. Boost drains stamina while boosting and
## moving, regenerates while not boosting and stops at 0. BOOST commands set the intent (`boost_held`); `boosting`
## (re)starts while held once stamina >= restart_min_stamina_frac x stamina_max (and > 0), with no re-press.
## A player entity multiplies the band values by its species `player_profile` (swim_speed_mult also scales the
## boosted speed and the dash-end speed cap; turn_rate_mult, accel_mult, drag_mult, brake_mult); default 1.0 = band table.
## With a map: a soft current (water velocity) flows toward the centre inside bounds.soft_margin_m of the edge
## (ramping up to bounds.current_mps at the edge); the fish swims relative to that water, so an idle fish drifts
## with it and thrust/brake/drag act on velocity minus the water velocity; SeabedField resolves seabed/obstacle contact, the surface (y = -radius) is a
## ceiling and the map box is a hard clamp; velocity loses its component into whatever pushed it back.
## Without content (unit tests) the S0 kinematics apply: 1 m/s, instant acceleration/turn/stop, no pitch clamp,
## no stamina cost, no map, and no eat/bite/growth rules.
##
## S3 rules (with content; numbers from rules/core.json, size_bands.json, species/*.json, formulas in SimRules).
## step() runs these phases in order, ascending entity id inside each phase:
##  1. NPC brains (NpcBrain.think) submit SimCommands for this tick (brains_enabled).
##  2. Due commands are applied (movement intents; BITE requests are stored, resolved in phase 5).
##  3. Movement: creatures swim, food bits drift (and expire), hiding state (HIDDEN / REVEALED), grid sync.
##  4. Swallow: every target whose centre is inside a creature's mouth cone (reach = length * mouth_reach_mult,
##     half-angle mouth_cone_deg) and whose length (x inflate scale while inflated) is <= swallow_ratio of the
##     eater's is swallowed: EATEN, players gain falloff XP and hunger. NPCs swallow food bits always, creatures only
##     when they are predators or are aggro on that target. A swallowed NPC is removed; a swallowed player dies.
##  5. Bite: a BITE resolves when tick >= bite_ready_tick; target -1 = the nearest non-swallowable creature in the
##     cone (reach + target collision radius); damage = SimRules.bite_damage with the eater's band bite_power
##     (NPCs: band by length) and species bite_mult; sets the victim's aggro; an `inflate` species inflates
##     (INFLATED) when bitten while calm (no spikes on that bite); every bite on an already inflated one spikes the
##     biter (SPIKED). BITTEN.
##     Player bites (F1): the cone is length * bite_reach_mult / half-angle bite_cone_deg (NPC bites keep the mouth
##     values); a player BITE stays pending until bite_until_tick (command tick + bite_buffer_s) and is retried every
##     tick until it hits (a hit consumes it), NPC BITEs live for their one tick. A ready player bite that finds
##     nothing emits BITE_MISSED, at most once per bite_miss_cooldown_s (a swallow by the player counts as that cue);
##     a miss never touches bite_ready_tick.
##     Aim assist (T1.5, `_assisted_bite_target`; player bites with target -1 only, off while aim_assist_strength <= 0:
##     then the code path is the one above byte for byte): the candidate cone widens to bite_cone_deg +
##     aim_assist_cone_deg x strength (reach unchanged; outside the strict cone also capped by aim_assist_max_distance_m),
##     the lowest score wins, equal scores go to the lower entity id (see the helper for the formula).
##     `peek_bite_target(player_id)` (T1.11, debug / presentation query, never called by a phase): the entity id the real
##     selection would hit now, read-only (no lock write, no event, no RNG, no cooldown / request state), creatures only.
##     Control modes (T1.4, SET_CONTROL_MODE): a PLAYER uses max(rules value, its mode's value) as aim assist and lunge strength
##     (`_player_aim` / `_player_lunge`; modes from controls/modes.json; classic = 0, so classic + rules 0 = today). NPCs never do.
##     Bite lunge (T1.6, `_start_bite_lunge` / `_bite_lunge_carry`; off while the strength is <= 0: then no code path, state
##     or hash byte differs): a PLAYER bite that lands on a creature (not a miss, not a site, not an NPC / boss bite) opens a
##     lunge window of lunge_duration_s; every swim tick of the window adds a forward carry velocity along the heading,
##     v = band lunge_distance_m x lunge_strength / window seconds, to the position step only (the physical velocity, drag,
##     thrust, boost and stamina are untouched, so the travel is the same from rest and while cruising and nothing is left
##     to coast once it ends); the step goes through _substep / _constrain like any move. Capped so that |velocity + carry|
##     <= max swim speed x boost speed_mult (the travel then falls short of the distance); `speed` includes the carry.
##  6. Deaths (hp <= 0): DIED; an NPC turns into remains food bits (FOOD_SPAWNED) and is removed; a player loses
##     death_xp_loss_frac of its XP (band/length recomputed, BAND_DOWN), deaths += 1, waits respawn_delay_s and
##     respawns at the nearest map player spawn with full HP/hunger/stamina (RESPAWNED).
##  7. Vitals (players, only when vitals_enabled): hunger drain, starvation damage at 0 hunger, regen while
##     hunger > regen_min_hunger_frac of hunger_max.
##  8. Growth (players whose XP changed since the last growth): band from XP (BAND_UP / BAND_DOWN), length from
##     SimRules.length_for_xp, max HP by rules.player_hp_model (hp keeps its fraction).
##  9. NpcSpawner.tick (does nothing until NpcSpawner.set_enabled(world, true)).
## S4 population (only while NpcSpawner.is_enabled(world); PHASE_NAMES / phase_usec give the timing per phase):
##  - plankton (between swallow and bite): players graze the PlanktonField (`plankton`, map `plankton` block), then
##    the krill clouds (`krill`, one KrillField per map `krill` entry, one critter per eat): see PlanktonField /
##    KrillField; PLANKTON_EATEN (data.field 0 = plankton, i + 1 = krill[i]).
##  - schools (after the spawners): TierManager.tick (`tiers`) respawns due school members of `schools`
##    (SchoolSystem, map `schools`) and promotes / demotes members near / far from players. A promoted member is an
##    ordinary interactive NPC for every rule above; when it is removed for good (swallowed, killed, remove_entity)
##    SchoolSystem.member_lost emits SCHOOL_MEMBER_EATEN and schedules its respawn.
## S6 progression, abilities, boss (Progression, Abilities, BossBrain; numbers in data):
##  - Mutation pick: a player's BAND_UP (growth) makes an offer (Progression.offer: pending_offer, MUTATION_OFFERED).
##    While the only player of the world has an open offer (single-player; pick_pause_enabled), paused_for_pick is
##    true and step() applies due PICK_MUTATION commands only: tick, run_ticks and every other phase stand still,
##    other commands stay queued (advance() keeps consuming time, so there is no catch-up burst on resume). A pick
##    (also outside the pause, from the commands phase) clears the offer and the pause. With several players offers
##    are made per player and nobody pauses (multiplayer later becomes per-player).
##  - Passives multiply into the rules: bite damage (bite_power_mult of the biter, damage_taken_mult of a player
##    victim; spikes and the boss charge use damage_taken_mult too), max swim speed (swim_speed_mult), boost drain
##    (/ boost_duration_mult) and speed (x boost_speed_mult), hunger drain (hunger_drain_mult).
##  - ABILITY commands go to Abilities.use. A lunge (Bite-Dash, boss charge) replaces the swim step while
##    tick < dash_until_tick; the tick it ends emits DASH_ENDED, a Bite-Dash slows to bite_dash.exit_speed_frac of
##    the max swim speed and requests a best-target bite that ignores the bite cooldown once (resolved in the bite
##    phase of the same tick).
##  - Boss (a species with a `boss` block; boss_id()): BossBrain.think replaces NpcBrain.think; its close bites use
##    boss.bite_cooldown_s. Boss phase (after bite, before deaths): a STUNNED boss touched by the bite cone of a
##    living player (player bite reach + boss collision radius, i.e. the bite test) is the finisher: BOSS_DEFEATED, DIED, giant
##    remains (boss.remains_bits food bits of length remains.food_bits.length_m x boss.remains_bit_scale, carrying
##    the boss XP and hunger) and the boss is removed; a STUNNED boss nobody finishes within boss.stun_timeout_s
##    recovers (BossBrain.recover_from_stun, S7); else at hp <= 0 the boss is STUNNED (BOSS_STUNNED, hp 0, it
##    never dies in the deaths phase); else a DASH hits touched players (BITTEN with data.dash) and PATROL /
##    DISENGAGE regenerate HP. After the finisher, VICTORY (once) when every remains bit is gone or
##    boss.victory_delay_s has passed; run_won then stops run_ticks.
## Food sites (FoodSites `food`, the baked maps/<id>_food.json + data/food types; null without the file = no work):
##  - Only living players eat sites (NPCs never). Swallow lap, after the creature swallows: the respawns due this tick
##    (SITE_RESPAWNED), then a soft site whose centre is in the player's mouth cone (length x mouth_reach_mult + site
##    radius, mouth_cone_deg) is swallowed when SimRules.can_swallow(length, type length_m, type swallow_ratio or
##    rules.swallow_ratio) holds: SITE_EATEN.
##  - Bite phase: a ready player BITE with target -1 also looks at the sites in the bite cone (player bite reach +
##    site radius, bite_cone_deg); the nearest of the best creature and the sites (centre distance, a creature wins a
##    tie) is bitten. A hard site loses the normal bite damage (SITE_BITTEN) and is eaten at HP <= 0 (SITE_EATEN, no
##    remains); a swallowable soft site in the bite cone is eaten by the bite; a soft site too big to swallow is never
##    a bite target (no HP use, the bite misses). A site bite consumes the request and starts the bite cooldown.
##  - Eating credits SimRules.xp_gain(type xp x xp_band_mult[band], length, type length_m, xp_falloff) XP and
##    hunger_from_xp(hunger_xp) hunger; the site respawns respawn_s later. state_hash() includes FoodSites.write_state.
## The event log keeps the last EVENT_RETENTION_TICKS ticks (trimmed once per second of sim time).

const TICK_RATE: int = 30
const TICK_DT: float = 1.0 / 30.0
## Accumulator unit: 1 / (TICK_RATE * 1e6) s, so one tick is exactly 1_000_000 units and
## advance(1.0) is exactly 30 ticks with no float drift.
const _UNITS_PER_SECOND: int = TICK_RATE * 1000000
const _UNITS_PER_TICK: int = 1000000
## Swim speed used when no ContentDB is set (tests).
const DEFAULT_BASE_SPEED_MPS: float = 1.0
## Map used when content is set and no other map id is passed to _init().
const DEFAULT_MAP_ID: StringName = &"reef"
## Player species when no content is set or no species is marked `playable` (with content the first playable
## species id in sorted order is used), and the player length without content.
const PLAYER_SPECIES_ID: StringName = &"small_reef_fish"
const DEFAULT_PLAYER_LENGTH_M: float = 0.1
## species_id of remains food bits.
const FOOD_BIT_SPECIES_ID: StringName = &"food_bit"
## Grid cell when no content is set (no eat rules run then; the grid is only kept in sync).
const DEFAULT_GRID_CELL_M: float = 8.0
## Events older than this many ticks are dropped from the log (10 s at 30 Hz; readers poll every frame/tick).
const EVENT_RETENTION_TICKS: int = 300
const _EVENT_TRIM_INTERVAL_TICKS: int = 30
## Coasting speeds below this are snapped to rest (numerical, avoids endless sub-millimetre drift).
const REST_SPEED_MPS: float = 1e-3
## A tick that moves a body further than max(MOVE_SUBSTEP_M, its radius) is resolved in sub-steps of at most that length
## (Bite-Dash 0.76 m and boss dash 0.67 m per tick, fast boosts): the centre cannot skip through a thin rock or land
## deep inside overlapping ones. Normal swimming moves less and costs nothing extra.
const MOVE_SUBSTEP_M: float = 0.35
## SimEntity.bite_request value meaning "no BITE this tick".
const NO_BITE: int = -2
## step() phases in run order (index into phase_usec).
enum Phase { BRAINS, COMMANDS, MOVEMENT, SWALLOW, PLANKTON, BITE, BOSS, DEATHS, VITALS, GROWTH, SPAWNER, SCHOOLS }
const PHASE_NAMES: Array[String] = ["brains", "commands", "movement", "swallow", "plankton", "bite", "boss", "deaths", "vitals", "growth", "spawner", "schools"]
## Species tiers (index into ContentDB.SPECIES_TIERS), for npc_count().
const TIER_AMBIENT: int = 0
const TIER_INTERACTIVE: int = 1
const TIER_LARGE: int = 2

## Ticks completed.
var tick: int = 0
## Run timer in ticks: counts every step, keeps running through deaths and respawns; stops once run_won.
var run_ticks: int = 0
## Set once by the VICTORY event (boss finisher + remains devoured or victory_delay_s).
var run_won: bool = false
## True while the single player of the world has an open mutation offer: step() applies picks only (class doc).
var paused_for_pick: bool = false
## Pick pause switch (configuration, not hashed): off = offers are still made, the sim keeps running.
var pick_pause_enabled: bool = true
var rng: SimRng
var content: ContentDB
var map_id: StringName = DEFAULT_MAP_ID
## Map record in use (empty without content or when the map is missing) and its collision field (null then).
var map: Dictionary = {}
var seabed: SeabedField = null
## The one uniform grid (hard rule 7) for eat/bite checks, brains and later interest management. Holds every
## live creature and food bit at its current position (dead players are taken out until they respawn).
var grid: SpatialGrid = null
## S4 population state (null without content, map or the map key): seeded schools, the plankton density field
## and the promotion / demotion manager. Read-only for presentation and benches.
var schools: SchoolSystem = null
var plankton: PlanktonField = null
## Krill clouds: one KrillField per map `krill` entry (record order; PLANKTON_EATEN data.field = index + 1).
var krill: Array[KrillField] = []
var tiers: TierManager = null
## Baked food sites (eggs, snails, edible decor; null without content, map or the map's baked food file).
## Read-only for presentation and the bot.
var food: FoodSites = null
## Phase 1 switch (NpcBrain.think for every NPC).
var brains_enabled: bool = true
## Phase 7 switch (hunger drain, starvation, regeneration). Off by default so swim-only worlds (S2 tests, swim
## tour) and isolated rule tests are not starved; the game loop and the bot harness turn it on.
var vitals_enabled: bool = false
## Debug / test overrides (god mode, hunger lock, noclip, time scale, tuning layer; SimDebug). null = normal rules; the object is not hashed (active overrides still show through entity hp / hunger), only a non-empty tuning layer is.
var debug: SimDebug.State = null
## Profiling (benches): a Callable returning microseconds, e.g. Callable(Time, "get_ticks_usec"). The sim never
## reads a clock itself (rule 1); while this is set, step() writes last_step_usec and phase_usec (one entry per
## PHASE_NAMES, 0 for a phase that did not run). Diagnostics only: never hashed, never read by sim logic.
var profile_clock: Callable = Callable()
var last_step_usec: int = 0
var phase_usec: PackedInt64Array = _zero_phases()

var _entities: Dictionary[int, SimEntity] = {}  # ids are monotonic, so insertion order == ascending id
var _ids: PackedInt32Array = PackedInt32Array()  # cached ascending ids, rebuilt (new array) when dirty
var _ids_dirty: bool = false
var _next_id: int = 1
var _queue: SimCommandQueue = SimCommandQueue.new()
var _events: Array[SimEvent] = []
var _accum_units: int = 0
var _seed: int = 0  # world seed (school seeds derive from it)
var _query: PackedInt32Array = PackedInt32Array()  # reused grid query buffer
var _site_query: PackedInt32Array = PackedInt32Array()  # reused food site query buffer
var _max_creature_len: float = 0.0  # longest creature seen (bounds the bite query radius)
var _players: Array[SimEntity] = []  # player entities, ascending id, rebuilt with _ids
var _tier_npcs: PackedInt32Array = PackedInt32Array([0, 0, 0])  # NPC creatures per tier (TIER_*)
var _boss_id: int = -1  # last spawned boss entity (-1 none; boss_id() checks it still exists)
var _boss_defeated_tick: int = -1
var _boss_finisher: int = -1
var _boss_remains: PackedInt32Array = PackedInt32Array()  # giant remains bit ids (VICTORY when all are gone)
var _boss_victory_ticks: int = 0  # boss.victory_delay_s of the defeated boss

# Tunables cached from content by _configure(). Band arrays: index 0 = no-content defaults, 1..n = size bands.
var _configured: bool = false
var _configured_for: ContentDB = null
var _p_speed: PackedFloat64Array = PackedFloat64Array()
var _p_accel: PackedFloat64Array = PackedFloat64Array()
var _p_drag: PackedFloat64Array = PackedFloat64Array()
var _p_turn: PackedFloat64Array = PackedFloat64Array()  # radians per tick
var _p_brake: PackedFloat64Array = PackedFloat64Array()
var _p_lunge_m: PackedFloat64Array = PackedFloat64Array()  # bite lunge distance per band (T1.6)
var _p_radius_mult: PackedFloat64Array = PackedFloat64Array()
var _p_max_hp: PackedFloat64Array = PackedFloat64Array()
var _p_bite_power: PackedFloat64Array = PackedFloat64Array()
var _p_hunger_mult: PackedFloat64Array = PackedFloat64Array()
var _bands: Array[Dictionary] = []
var _max_pitch_sin: float = 1.0
var _max_pitch_cos: float = 0.0
var _stamina_max: float = 0.0
var _boost_drain: float = 0.0
var _boost_regen: float = 0.0
var _boost_restart_frac: float = 0.0
var _boost_mult: float = 1.0
var _bite_dash_exit_frac: float = 1.0
var _half_size: float = 0.0
var _depth: float = 0.0
var _soft_margin: float = 0.0
var _current_mps: float = 0.0
var _spawns: PackedVector3Array = PackedVector3Array()
var _player_species: StringName = PLAYER_SPECIES_ID
var _species: Dictionary[StringName, _SpeciesRules] = {}
var _no_species: _SpeciesRules = _SpeciesRules.new()
var _max_inflate: float = 1.0
var _max_radius_mult: float = 0.0
var _swallow_ratio: float = 0.0
var _reach_mult: float = 0.0
var _cos_half: float = 1.0
var _bite_cd_ticks: int = 0
var _bite_reach_mult: float = 0.0  # player bites (F1); NPC bites use _reach_mult / _cos_half
var _bite_cos_half: float = 1.0
var _aim_strength: float = 0.0  # aim assist (T1.5): 0 = off (the strict path), clamped to 0..1
var _aim_cos_half: float = 1.0  # cos of the widened candidate half-angle (bite_cone_deg + cone x strength)
var _bite_cone_deg: float = 0.0
var _aim_cone_deg: float = 0.0  # aim_assist_cone_deg (>= 0): the extra half-angle at strength 1
var _mode_strength: Dictionary = {}  # control mode id (StringName) -> Vector2(aim assist, lunge) strength, both 0..1 (T1.4)
var _aim_max_d2: float = 0.0  # squared aim_assist_max_distance_m (centre distance cap outside the strict cone)
var _aim_stickiness: float = 0.0
var _lunge_strength: float = 0.0  # bite lunge (T1.6): 0 = off (no new code path, state or hash bytes), clamped to 0..1
var _lunge_ticks: int = 0  # lunge window length
var _bite_buffer_ticks: int = 0
var _bite_miss_cd_ticks: int = 0
var _retaliate_ticks: int = 0
var _hunger_max: float = 0.0
var _hunger_full_s: float = 0.0
var _hunger_per_xp: float = 0.0
var _starve_frac: float = 0.0
var _regen_min_frac: float = 1.0
var _regen_frac: float = 0.0
var _death_loss: float = 0.0
var _respawn_ticks: int = 0
var _falloff: Dictionary = {}
var _bits_min: int = 0
var _bits_max: int = 0
var _bit_len: float = 0.0
var _bit_drift: float = 0.0
var _bit_life_ticks: int = 0
var _hp_length2: bool = false


## Per-species numbers the rules need, read once from content.
class _SpeciesRules:
	extends RefCounted
	var base_hp: float = 0.0
	var hp_override: float = -1.0
	var xp: float = 0.0
	var xp_band_mult: PackedFloat64Array = PackedFloat64Array()  # by EATER band, empty = 1 for every band
	var bite_mult: float = 1.0
	var predator: bool = false
	var inflate_scale: float = 1.0
	var inflate_ticks: int = 0
	var spike_frac: float = 0.0
	var tier: int = -1
	var boss: bool = false
	var bite_cd_ticks: int = -1  # own bite cooldown (boss), -1 = rules.bite_cooldown_s
	# species `player_profile` (T1.7): multipliers on the band table values, applied to player-controlled entities only
	var prof_speed: float = 1.0
	var prof_turn: float = 1.0
	var prof_accel: float = 1.0
	var prof_drag: float = 1.0
	var prof_brake: float = 1.0


func _init(p_seed: int = 0, p_content: ContentDB = null, p_map_id: StringName = DEFAULT_MAP_ID) -> void:
	_seed = p_seed
	rng = SimRng.new(p_seed)
	content = p_content
	map_id = p_map_id
	_configure()


## Adds a creature at `position`; returns its id (starts at 1, never reused). Emits ENTITY_SPAWNED.
## With content: a player gets band 1 by XP, max HP by rules.player_hp_model, full HP and hunger; an NPC gets the
## band containing its length and max HP = hp_override or SimRules.creature_max_hp(base_hp, length).
func spawn_entity(species_id: StringName, position: Vector3, length_m: float, is_player: bool = false) -> int:
	_configure()
	var e := _new_entity()
	e.species_id = species_id
	e.position = position
	e.length_m = length_m
	e.is_player = is_player
	if content != null:
		if is_player:
			e.band = SimRules.band_for_xp(e.xp, _bands)
			e.max_hp = _player_max_hp(e)
			e.hunger = _hunger_max
		else:
			e.band = SimRules.band_for_length(length_m, _bands)
			var sp: _SpeciesRules = _species_of(e)
			e.max_hp = sp.hp_override if sp.hp_override > 0.0 else SimRules.creature_max_hp(sp.base_hp, length_m)
		if not (e.max_hp > 0.0 and is_finite(e.max_hp)):
			e.max_hp = 1.0
		e.hp = e.max_hp
		if is_player:
			Progression.apply_effects(content, e)
		elif _species_of(e).boss:
			e.boss_state = BossBrain.State.PATROL
			e.boss_home = position
			_boss_id = e.id
	e.grown_at_xp = e.xp
	if is_finite(length_m):
		_max_creature_len = maxf(_max_creature_len, length_m)
	_add(e)
	_events.append(SimEvent.create(SimEvent.Type.ENTITY_SPAWNED, tick, e.id))
	# Hiding state is current from the first brain pass (phase 1 runs before the phase-3 update).
	if content != null and NpcBrain.update_hidden(self, e):
		_emit(SimEvent.Type.HIDDEN, e.id)
	return e.id


## Spawns the player fish at map `player_spawns[spawn_index]` (index wraps; origin without a map) with the
## band 1 minimum length and full boost stamina. The spawn point is resolved against the map collision once.
func spawn_player(spawn_index: int = 0) -> int:
	_configure()
	var pos := Vector3.ZERO
	if not _spawns.is_empty():
		pos = _spawns[posmod(spawn_index, _spawns.size())]
	var length_m: float = DEFAULT_PLAYER_LENGTH_M
	if content != null:
		var band_len: Variant = content.get_band(1).get("length_m")
		if band_len is Dictionary:
			length_m = float((band_len as Dictionary).get("min", length_m))
	var id: int = spawn_entity(_player_species, pos, length_m, true)
	var e: SimEntity = _entities[id]
	e.stamina = _stamina_max
	if seabed != null:
		e.position = _constrain(e, e.position)
		_grid_sync(e)
	return id


## Collision radius of an entity (length_m * band collision_radius_mult; 0 without content).
func collision_radius(e: SimEntity) -> float:
	_configure()
	return e.length_m * _p_radius_mult[_band_index(e.band)]


## Length used by the swallow rule and the bite reach: length_m, x the species inflate scale while inflated.
func effective_length(e: SimEntity) -> float:
	if e.inflated_until_tick > tick:
		return e.length_m * _species_of(e).inflate_scale
	return e.length_m


func remove_entity(id: int) -> bool:
	if not _entities.has(id):
		return false
	_remove(id)
	return true


func get_entity(id: int) -> SimEntity:
	return _entities.get(id, null)


func entity_count() -> int:
	return _entities.size()


## Ascending ids (creatures and food bits; check SimEntity.kind).
func entity_ids() -> PackedInt32Array:
	return _sorted_ids().duplicate()


## The only way input reaches the sim.
func submit(cmd: SimCommand) -> void:
	_queue.push(cmd)


## Living NPC creatures (not players, not food bits) whose species is in `tier` (TIER_*).
func npc_count(tier: int) -> int:
	return _tier_npcs[tier] if tier >= 0 and tier < _tier_npcs.size() else 0


## Clears `out` and appends the position of every living player (ascending id).
func player_positions_into(out: PackedVector3Array) -> void:
	out.clear()
	_sorted_ids()
	for e in _players:
		if e.alive:
			out.append(e.position)


## Band max swim speed (m/s) of size band `band` (the no-content default without content).
func band_swim_speed(band: int) -> float:
	_configure()
	return _p_speed[_band_index(band)]


## Player entities, ascending id (shared array: read-only for callers).
func players() -> Array[SimEntity]:
	_sorted_ids()
	return _players


## The boss entity id (a species with a `boss` block), -1 when there is none (not spawned yet or defeated).
func boss_id() -> int:
	return _boss_id if _entities.has(_boss_id) else -1


## True while the boss fights a player (ENGAGE, TELL, DASH, STUNNED): the HUD shows the boss HP bar.
func boss_engaged() -> bool:
	return BossBrain.is_engaged(_entities.get(_boss_id, null))


## Seconds until `ability_id` is ready again for `entity_id` (0 when ready, not granted or unknown entity).
func ability_cooldown_left(entity_id: int, ability_id: StringName) -> float:
	return Abilities.cooldown_left(self, _entities.get(entity_id, null), ability_id)


## Tick of the boss finisher, -1 before it.
func boss_defeated_tick() -> int:
	return _boss_defeated_tick


## Appends an event to the log for this tick. For sim subsystems (SchoolSystem, TierManager) only; presentation
## never emits events.
func emit_event(type: SimEvent.Type, entity_id: int, other_id: int = -1, value: float = 0.0) -> SimEvent:
	return _emit(type, entity_id, other_id, value)


## One fixed tick (phases in the class doc), then `tick` and `run_ticks` advance.
func step() -> void:
	_configure()
	if paused_for_pick:
		_apply_picks()
		return
	var timed: bool = profile_clock.is_valid()
	var t0: int = int(profile_clock.call()) if timed else 0
	var t: int = t0
	if tick % _EVENT_TRIM_INTERVAL_TICKS == 0:
		_trim_events()
	var rules_on: bool = content != null
	var population_on: bool = rules_on and NpcSpawner.is_enabled(self)
	if rules_on and brains_enabled:
		for id in _sorted_ids():
			var b: SimEntity = _entities.get(id, null)
			if b != null and b.alive and b.kind == SimEntity.Kind.CREATURE and not b.is_player:
				if b.boss_state >= 0:
					BossBrain.think(self, b)
				else:
					NpcBrain.think(self, b)
	if timed:
		t = _lap(Phase.BRAINS, t)
	if _queue.size() > 0:
		for cmd in _queue.pop_for_tick(tick):
			_apply(cmd)
	if timed:
		t = _lap(Phase.COMMANDS, t)
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e == null or not e.alive:
			continue
		if e.kind == SimEntity.Kind.FOOD_BIT:
			_drift(e)
			continue
		_swim(e)
		_grid_sync(e)
		if rules_on and NpcBrain.update_hidden(self, e):
			_emit(SimEvent.Type.HIDDEN if e.hidden else SimEvent.Type.REVEALED, e.id)
	if timed:
		t = _lap(Phase.MOVEMENT, t)
	if rules_on:
		_resolve_swallows()
		if food != null:
			_eat_sites()
		if timed:
			t = _lap(Phase.SWALLOW, t)
		if population_on and (plankton != null or not krill.is_empty()):
			_graze()
		if timed:
			t = _lap(Phase.PLANKTON, t)
		_resolve_bites()
		if timed:
			t = _lap(Phase.BITE, t)
		_update_boss()
		if timed:
			t = _lap(Phase.BOSS, t)
		if debug != null:
			SimDebug.apply_overrides(self)
		_resolve_deaths()
		if timed:
			t = _lap(Phase.DEATHS, t)
		if vitals_enabled:
			_update_vitals()
		if timed:
			t = _lap(Phase.VITALS, t)
		_update_growth()
		_update_pause()
		if timed:
			t = _lap(Phase.GROWTH, t)
		NpcSpawner.tick(self)
		if timed:
			t = _lap(Phase.SPAWNER, t)
		if population_on and tiers != null:
			tiers.tick(self)
		if timed:
			t = _lap(Phase.SCHOOLS, t)
	if timed:
		last_step_usec = t - t0
	if not run_won:
		run_ticks += 1
	if food != null:
		food.now_tick = tick + 1
	tick += 1
	if plankton != null:
		plankton.now_tick = tick
	for f: PlanktonField in krill:
		f.now_tick = tick


static func _zero_phases() -> PackedInt64Array:
	var a := PackedInt64Array()
	a.resize(PHASE_NAMES.size())
	return a


# Stores the time since `since` for `phase` (profile_clock set); returns the clock now.
func _lap(phase: int, since: int) -> int:
	var now: int = int(profile_clock.call())
	phase_usec[phase] = now - since
	return now


## Runs as many fixed steps as the accumulated time allows; returns how many ran.
func advance(delta_s: float) -> int:
	# NaN/INF/negative deltas would corrupt the accumulator (roundi(INF) overflows it); treat them as no time.
	if not is_finite(delta_s) or delta_s <= 0.0:
		return 0
	_accum_units += roundi(delta_s * _UNITS_PER_SECOND)
	var ran: int = 0
	while _accum_units >= _UNITS_PER_TICK:
		_accum_units -= _UNITS_PER_TICK
		step()
		ran += 1
	return ran


## Fraction of a tick left in the accumulator, in [0, 1).
func interpolation_alpha() -> float:
	return float(_accum_units) / float(_UNITS_PER_TICK)


## Deterministic within one build: SHA-256 over tick, run timer, rng state, id counter, every entity (ascending
## id), the spawner state, the krill cells missing a critter (alive bits + regrow clock, per field), the school state (alive bits, pending
## respawns, promoted members), the plankton cells below full density, the still-pending commands (canonical order)
## and the S6 state (per entity: mutations,
## abilities + ready ticks, open offer, offered bands, passives, lunge, boss fields; world: run_won, boss id,
## finisher tick / player, giant remains ids) and, per player, the control mode id ONLY while it is not `classic` (T1.4). Not hashed on purpose (also paused_for_pick: derived from the offers): the advance()
## accumulator (frame pacing, not sim state), the event log and the grid (derived), the content database
## (immutable input), the brains_enabled / vitals_enabled switches (configuration) and `debug` (SimDebug overrides), except
## its tuning layer (T1.3): a NON-empty TuningOverrides is hashed at the very end (an empty one writes nothing).
func state_hash() -> int:
	var buf := StreamPeerBuffer.new()
	buf.put_64(tick)
	buf.put_64(run_ticks)
	buf.put_64(rng.get_state())
	buf.put_64(_next_id)
	for id in _sorted_ids():
		var e: SimEntity = _entities[id]
		buf.put_64(e.id)
		buf.put_8(e.kind)
		buf.put_utf8_string(String(e.species_id))
		_put_vec(buf, e.position)
		_put_vec(buf, e.velocity)
		_put_vec(buf, e.heading)
		buf.put_double(e.length_m)
		buf.put_double(e.hp)
		buf.put_double(e.max_hp)
		buf.put_double(e.hunger)
		buf.put_double(e.xp)
		buf.put_double(e.grown_at_xp)
		buf.put_64(e.band)
		buf.put_double(e.stamina)
		buf.put_8(int(e.boosting) | (int(e.is_player) << 1) | (int(e.alive) << 2) | (int(e.braking) << 3) | (int(e.hidden) << 4) | (int(e.boost_held) << 5))
		buf.put_double(e.speed)
		buf.put_double(e.yaw_deg)
		buf.put_double(e.pitch_deg)
		_put_vec(buf, e.move_dir)
		buf.put_double(e.move_thrust)
		buf.put_64(e.last_bite_target)
		buf.put_64(e.bite_request)
		buf.put_64(e.bite_until_tick)
		buf.put_64(e.bite_miss_ready_tick)
		buf.put_utf8_string(String(e.last_ability_id))
		buf.put_64(e.deaths)
		buf.put_64(e.respawn_tick)
		buf.put_64(e.bite_ready_tick)
		buf.put_64(e.inflated_until_tick)
		buf.put_64(e.aggro_target)
		buf.put_64(e.aggro_until_tick)
		buf.put_64(e.brain_state)
		buf.put_64(e.hidden_since_tick)
		buf.put_64(e.last_damage_from)
		buf.put_double(e.xp_value)
		buf.put_double(e.hunger_value)
		buf.put_64(e.expire_tick)
		buf.put_double(e.source_length_m)
		buf.put_utf8_string(String(e.source_species))
		buf.put_64(e.school_id)
		buf.put_64(e.school_member)
		buf.put_64(e.school_since_tick)
		_put_strings(buf, e.mutations)
		_put_strings(buf, e.abilities)
		buf.put_32(e.ability_ready_ticks.size())
		for r in e.ability_ready_ticks:
			buf.put_64(r)
		_put_strings(buf, e.pending_offer)
		buf.put_32(e.picks_offered_for_band.size())
		for b in e.picks_offered_for_band:
			buf.put_32(b)
		buf.put_double(e.bite_power_mult)
		buf.put_double(e.swim_speed_mult)
		buf.put_double(e.boost_duration_mult)
		buf.put_double(e.boost_speed_mult)
		buf.put_double(e.hunger_drain_mult)
		buf.put_double(e.damage_taken_mult)
		buf.put_double(e.presence_sector_deg)
		buf.put_64(e.dash_until_tick)
		_put_vec(buf, e.dash_velocity)
		buf.put_utf8_string(String(e.dash_ability))
		if e.is_player and _player_aim(e) > 0.0:  # lock memory exists only while the assist is on (effective strength 0 = no new bytes)
			buf.put_64(e.aim_lock_target)
			buf.put_64(e.aim_lock_until_tick)
		if e.bite_lunge_left > 0 and _player_lunge(e) > 0.0:  # a running lunge window exists only while the lunge is on (effective strength 0 = no new bytes)
			buf.put_64(e.bite_lunge_left)
			buf.put_double(e.bite_lunge_mps)
		if e.control_mode != SimEntity.CLASSIC_MODE:  # classic (the default) adds no bytes
			buf.put_utf8_string(String(e.control_mode))
		buf.put_64(e.boss_state)
		if e.boss_state >= 0:
			buf.put_64(e.boss_state_tick)
			buf.put_64(e.boss_target)
			_put_vec(buf, e.boss_dir)
			buf.put_64(e.boss_seen_tick)
			buf.put_64(e.boss_attack_tick)
			_put_vec(buf, e.boss_home)
			buf.put_32(e.boss_dash_hits.size())
			for h in e.boss_dash_hits:
				buf.put_64(h)
			buf.put_64(e.boss_hug_tick)
	buf.put_8(int(run_won))
	buf.put_64(_boss_id)
	buf.put_64(_boss_defeated_tick)
	buf.put_64(_boss_finisher)
	buf.put_32(_boss_remains.size())
	for r in _boss_remains:
		buf.put_64(r)
	if food != null:
		food.write_state(buf, tick)
	NpcSpawner.write_state(self, buf)
	buf.put_32(krill.size())
	for f: PlanktonField in krill:
		f.write_state(buf, tick)
	if schools != null:
		schools.write_state(buf)
	if plankton != null:
		plankton.write_state(buf, tick)
	_queue.write_state(buf)
	if debug != null and debug.tuning != null:
		debug.tuning.write_state(buf)  # nothing while the override layer is empty
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().decode_s64(0)


## Events with event.tick >= `from_tick` (only the last EVENT_RETENTION_TICKS ticks are kept).
func events_since(from_tick: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev in _events:
		if ev.tick >= from_tick:
			out.append(ev)
	return out


func clear_events_before(before_tick: int) -> void:
	var keep: Array[SimEvent] = []
	for ev in _events:
		if ev.tick >= before_tick:
			keep.append(ev)
	_events = keep


# ------------------------------------------------------------------ commands

# Commands for unknown or removed entities, and MOVE commands with non-finite numbers, are ignored silently
# (a NaN/INF direction or thrust would poison position and the spatial grid for good).
func _apply(cmd: SimCommand) -> void:
	var e: SimEntity = _entities.get(cmd.entity_id, null)
	if e == null or not e.alive or e.kind != SimEntity.Kind.CREATURE:
		return
	if cmd.type == SimCommand.Type.MOVE and not (cmd.dir.is_finite() and is_finite(cmd.dir.length_squared()) and is_finite(cmd.thrust)):
		return
	match cmd.type:
		SimCommand.Type.MOVE:
			# the heading turns toward move_dir during integration (turn-rate limited)
			e.move_dir = cmd.dir
			e.move_thrust = clampf(cmd.thrust, 0.0, 1.0)
		SimCommand.Type.BOOST:
			# intent only: the swim step derives `boosting` from it and the stamina
			e.boost_held = cmd.active
		SimCommand.Type.BRAKE:
			e.braking = cmd.active
		SimCommand.Type.BITE:
			# resolved in the bite phase; the last BITE wins; a player's stays pending for the buffer (class doc)
			e.last_bite_target = cmd.target_id
			if content != null:
				e.bite_request = maxi(cmd.target_id, -1)
				e.bite_until_tick = tick + (_bite_buffer_ticks if e.is_player else 0)
		SimCommand.Type.ABILITY:
			e.last_ability_id = cmd.ability_id
			Abilities.use(self, e, cmd.ability_id)
		SimCommand.Type.PICK_MUTATION:
			if Progression.pick(self, e, cmd.node_id):
				Progression.offer(self, e)
				_update_pause()
		SimCommand.Type.SET_CONTROL_MODE:
			# players only, known modes only; a real change drops the lock memory and any running lunge window of the old mode
			if e.is_player and cmd.mode_id != e.control_mode and content != null and not content.get_control_mode(cmd.mode_id).is_empty():
				e.control_mode = cmd.mode_id
				e.aim_lock_target = -1
				e.aim_lock_until_tick = 0
				e.bite_lunge_left = 0


# Paused for a pick: only the due PICK_MUTATION commands are applied (everything else stays queued).
func _apply_picks() -> void:
	if _queue.size() > 0:
		for cmd in _queue.pop_type_for_tick(SimCommand.Type.PICK_MUTATION, tick):
			_apply(cmd)
	_update_pause()


func _update_pause() -> void:
	_sorted_ids()
	paused_for_pick = pick_pause_enabled and _players.size() == 1 and not _players[0].pending_offer.is_empty()


# ------------------------------------------------------------------ movement

# One tick of the swim model for one entity (see the class doc).
func _swim(e: SimEntity) -> void:
	if e.dash_until_tick >= 0:
		if tick < e.dash_until_tick:
			_lunge(e)
			return
		_end_dash(e)
	var bi: int = _band_index(e.band)
	var turn: float = _p_turn[bi]
	var accel: float = _p_accel[bi]
	var drag: float = _p_drag[bi]
	var brake: float = _p_brake[bi]
	var top: float = _p_speed[bi]
	if e.is_player:
		# band table x species player_profile (x1.0 by default: bit-identical to the plain band values)
		var prof: _SpeciesRules = _species_of(e)
		turn *= prof.prof_turn
		accel *= prof.prof_accel
		drag *= prof.prof_drag
		brake *= prof.prof_brake
		top *= prof.prof_speed
	if not e.move_dir.is_zero_approx():
		var target: Vector3 = _clamp_pitch(e.move_dir.normalized(), e.heading)
		e.heading = _turn_heading(e.heading, target, turn)

	# boost follows the held intent; when boosting costs stamina, a (re)start needs stamina >= the restart threshold,
	# so a held boost restarts by itself once enough stamina has regenerated
	if not e.boost_held:
		e.boosting = false
	elif not e.boosting:
		e.boosting = _boost_drain <= 0.0 or (e.stamina > 0.0 and e.stamina >= _boost_restart_frac * _stamina_max)
	if e.boosting:
		if e.move_thrust > 0.0 and not e.braking and _boost_drain > 0.0:
			e.stamina = maxf(e.stamina - _boost_drain / e.boost_duration_mult * TICK_DT, 0.0)
			if e.stamina <= 0.0:
				e.boosting = false
	else:
		e.stamina = minf(e.stamina + _boost_regen * TICK_DT, _stamina_max)

	# the fish swims relative to the water: thrust, brake and drag act on (velocity - water velocity)
	var water: Vector3 = _current_at(e.position) if seabed != null else Vector3.ZERO
	if e.braking:
		e.velocity = e.velocity.move_toward(water, brake * TICK_DT)
	elif e.move_thrust > 0.0:
		var max_speed: float = top * e.swim_speed_mult * (_boost_mult * e.boost_speed_mult if e.boosting else 1.0)
		e.velocity = e.velocity.move_toward(water + e.heading * (e.move_thrust * max_speed), accel * TICK_DT)
	else:
		var rel: Vector3 = (e.velocity - water) * exp(-drag * TICK_DT)
		if rel.length_squared() < REST_SPEED_MPS * REST_SPEED_MPS:
			rel = Vector3.ZERO
		e.velocity = water + rel

	var p: Vector3 = e.position + e.velocity * TICK_DT
	var carry: Vector3 = Vector3.ZERO
	var sub_m: float = 0.0
	if e.bite_lunge_left > 0:  # bite lunge window (T1.6): never set while the player's lunge strength is <= 0
		carry = _bite_lunge_carry(e, top * e.swim_speed_mult * _boost_mult * e.boost_speed_mult)
		p += carry * TICK_DT
		sub_m = collision_radius(e)  # finer sub-steps: a chord of one lunge step must not clip a thin edge
	if seabed != null:
		p = _constrain(e, _substep(e, p, sub_m))
	e.position = p
	e.speed = e.velocity.length() if carry.is_zero_approx() else (e.velocity + carry).length()
	e.yaw_deg = rad_to_deg(atan2(-e.heading.x, -e.heading.z))
	e.pitch_deg = rad_to_deg(asin(clampf(e.heading.y, -1.0, 1.0)))


# One tick of a running bite lunge window: the extra velocity (along the heading) the position step gets on top of the
# normal motion. Capped so |velocity + carry| <= `cap` (a velocity already at the cap gets none). A window left over when the
# strength was tuned to 0 is dropped.
func _bite_lunge_carry(e: SimEntity, cap: float) -> Vector3:
	e.bite_lunge_left -= 1
	if _player_lunge(e) <= 0.0:
		e.bite_lunge_left = 0
		return Vector3.ZERO
	var v2: float = e.velocity.length_squared()
	if v2 >= cap * cap:
		return Vector3.ZERO
	var along: float = e.velocity.dot(e.heading)
	var room: float = -along + sqrt(along * along - v2 + cap * cap)  # |velocity + heading * room| == cap
	return e.heading * clampf(room, 0.0, e.bite_lunge_mps)


# Opens the lunge window after a PLAYER bite landed on a creature: lunge_distance_m of the player's band x lunge_strength,
# spread evenly over the window (lunge_duration_s, whole ticks). No-op while the strength, the distance or the duration is 0.
func _start_bite_lunge(e: SimEntity, strength: float) -> void:
	var dist: float = _p_lunge_m[_band_index(e.band)] * strength
	if not (dist > 0.0) or _lunge_ticks <= 0:
		return
	e.bite_lunge_left = _lunge_ticks
	e.bite_lunge_mps = dist / (float(_lunge_ticks) * TICK_DT)


# Lunge tick: moves with dash_velocity, heading locked to it (seabed / surface / map clamps still apply).
func _lunge(e: SimEntity) -> void:
	e.heading = e.dash_velocity.normalized() if not e.dash_velocity.is_zero_approx() else e.heading
	e.velocity = e.dash_velocity
	var p: Vector3 = e.position + e.velocity * TICK_DT
	if seabed != null:
		p = _constrain(e, _substep(e, p))
	e.position = p
	e.speed = e.velocity.length()
	e.yaw_deg = rad_to_deg(atan2(-e.heading.x, -e.heading.z))
	e.pitch_deg = rad_to_deg(asin(clampf(e.heading.y, -1.0, 1.0)))


# The lunge is over: DASH_ENDED; a Bite-Dash drops to bite_dash.exit_speed_frac x the max swim speed (so the total
# travel stays close to lunge_distance_m) and requests its bite (cooldown ignored once); the boss charge is capped to
# its max swim speed.
func _end_dash(e: SimEntity) -> void:
	var kind: StringName = e.dash_ability
	e.dash_until_tick = -1
	e.dash_ability = &""
	e.dash_velocity = Vector3.ZERO
	var cap: float = _p_speed[_band_index(e.band)] * e.swim_speed_mult
	if e.is_player:
		cap *= _species_of(e).prof_speed
	if kind == Abilities.BITE_DASH:
		cap *= _bite_dash_exit_frac
	e.velocity = e.velocity.limit_length(cap)
	var ev: SimEvent = _emit(SimEvent.Type.DASH_ENDED, e.id)
	ev.data = {"ability": String(kind)}
	if kind == Abilities.BITE_DASH and content != null:
		e.bite_request = -1
		e.bite_until_tick = tick  # single shot, no buffer
		e.bite_ready_tick = mini(e.bite_ready_tick, tick)


# Food bit: drifts with its constant velocity, kept out of the seabed and the obstacles (a bit inside a rock would be
# unreachable), below the surface and inside the map; removed once expired.
func _drift(e: SimEntity) -> void:
	if tick >= e.expire_tick:
		_remove(e.id)
		return
	var p: Vector3 = e.position + e.velocity * TICK_DT
	if seabed != null:
		var r: float = collision_radius(e)
		p = _clamp_point(seabed.resolve(p, r), r)
	e.position = p
	_grid_sync(e)


# Seabed/obstacles, surface ceiling and the hard map box; removes the velocity component into the push.
func _constrain(e: SimEntity, p: Vector3) -> Vector3:
	if debug != null and debug.noclip and e.is_player:
		return SimDebug.noclip_constrain(self, e, p)
	var r: float = collision_radius(e)
	var q: Vector3 = seabed.resolve(p, r)
	q.y = clampf(q.y, -_depth + r, -r)
	q.x = clampf(q.x, -_half_size + r, _half_size - r)
	q.z = clampf(q.z, -_half_size + r, _half_size - r)
	var push: Vector3 = q - p
	if push.length_squared() > 1e-12:
		var n: Vector3 = push.normalized()
		var into: float = e.velocity.dot(n)
		if into < 0.0:
			e.velocity -= n * into
	return q


# Movement target of a long step: resolves the path from e.position in equal sub-steps of at most
# max(MOVE_SUBSTEP_M, radius) (`sub_m` > 0: of at most sub_m, used by the bite lunge) and returns the last sub-step target
# (the caller's _constrain resolves it and clamps).
func _substep(e: SimEntity, p: Vector3, sub_m: float = 0.0) -> Vector3:
	if debug != null and debug.noclip and e.is_player:
		return p
	var d: Vector3 = p - e.position
	var r: float = collision_radius(e)
	var lim: float = maxf(MOVE_SUBSTEP_M, r) if sub_m <= 0.0 else maxf(sub_m, 0.001)
	var len2: float = d.length_squared()
	if len2 <= lim * lim:
		return p
	var n: int = ceili(sqrt(len2) / lim)
	var step: Vector3 = d / float(n)
	var q: Vector3 = e.position
	for k in n - 1:
		q = seabed.resolve(q + step, r)
	return q + step


# Cheap point clamp: above the seabed height, below the surface, inside the map box (no obstacles).
func _clamp_point(p: Vector3, r: float) -> Vector3:
	var q := Vector3(clampf(p.x, -_half_size + r, _half_size - r), p.y, clampf(p.z, -_half_size + r, _half_size - r))
	q.y = clampf(maxf(q.y, seabed.height_at(q.x, q.z) + r), -_depth + r, -r)
	return q


# Water current near the map edge, pointing back toward the centre (per axis, linear ramp over the margin).
func _current_at(p: Vector3) -> Vector3:
	var c := Vector3.ZERO
	if _current_mps <= 0.0 or _soft_margin <= 0.0:
		return c
	var inner: float = _half_size - _soft_margin
	var ex: float = absf(p.x) - inner
	if ex > 0.0:
		c.x = -signf(p.x) * _current_mps * minf(ex / _soft_margin, 1.0)
	var ez: float = absf(p.z) - inner
	if ez > 0.0:
		c.z = -signf(p.z) * _current_mps * minf(ez / _soft_margin, 1.0)
	return c


# Keeps |pitch| <= max pitch; a vertical vector keeps the horizontal direction of `fallback`.
func _clamp_pitch(v: Vector3, fallback: Vector3) -> Vector3:
	if absf(v.y) <= _max_pitch_sin:
		return v
	var hz := Vector2(v.x, v.z)
	if hz.length_squared() < 1e-12:
		hz = Vector2(fallback.x, fallback.z)
	if hz.length_squared() < 1e-12:
		hz = Vector2(0.0, -1.0)
	hz = hz.normalized() * _max_pitch_cos
	return Vector3(hz.x, signf(v.y) * _max_pitch_sin, hz.y)


# Turns unit `h` toward unit `t` (already pitch-clamped) by at most `max_angle` radians, keeping the pitch
# limit. The geodesic step can pass over the limit near the poles; then the step is taken in yaw/pitch space
# (pitch stays legal) and shortened by bisection until it fits the turn budget.
func _turn_heading(h: Vector3, t: Vector3, max_angle: float) -> Vector3:
	var r: Vector3 = _turn_toward(h, t, max_angle)
	if absf(r.y) <= _max_pitch_sin + 1e-9:
		return r
	var c: Vector3 = _clamp_pitch(r, h)
	if h.angle_to(c) <= max_angle:
		return c
	var yaw_h: float = atan2(-h.x, -h.z)
	var pitch_h: float = asin(clampf(h.y, -1.0, 1.0))
	var dyaw: float = angle_difference(yaw_h, atan2(-c.x, -c.z))
	var dpitch: float = asin(clampf(c.y, -1.0, 1.0)) - pitch_h
	var lo: float = 0.0
	var hi: float = 1.0
	for i in 12:
		var mid: float = (lo + hi) * 0.5
		if h.angle_to(_dir_from_yaw_pitch(yaw_h + dyaw * mid, pitch_h + dpitch * mid)) <= max_angle:
			lo = mid
		else:
			hi = mid
	return _dir_from_yaw_pitch(yaw_h + dyaw * lo, pitch_h + dpitch * lo)


# Unit direction for yaw (0 = -Z, rotation.y convention) and pitch (up positive), radians.
static func _dir_from_yaw_pitch(yaw: float, pitch: float) -> Vector3:
	var cp: float = cos(pitch)
	return Vector3(-sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)


# Rotates unit `h` toward unit `t` by at most `max_angle` radians.
static func _turn_toward(h: Vector3, t: Vector3, max_angle: float) -> Vector3:
	var angle: float = h.angle_to(t)
	if angle <= max_angle:
		return t
	var axis: Vector3 = h.cross(t)
	if axis.length_squared() < 1e-12:
		axis = Vector3.UP if absf(h.y) < 0.99 else Vector3.RIGHT
	return h.rotated(axis.normalized(), max_angle).normalized()


# ------------------------------------------------------------------ phase 4: swallow

func _resolve_swallows() -> void:
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e == null or not _is_active_creature(e):
			continue
		var reach: float = e.length_m * _reach_mult
		if not (reach > 0.0):
			continue
		grid.query_radius_into(e.position, reach, _query)
		for tid in _query:
			if tid == id:
				continue
			var t: SimEntity = _entities.get(tid, null)
			if t == null or not t.alive:
				continue
			if t.kind == SimEntity.Kind.CREATURE:
				if t.hp <= 0.0 or not SimRules.can_swallow(e.length_m, effective_length(t), _swallow_ratio):
					continue
				if not e.is_player and not _npc_hunts(e, t):
					continue
			elif not SimRules.can_swallow(e.length_m, t.length_m, _swallow_ratio):
				continue
			if SimRules.in_cone(e.position, e.heading, t.position, reach, _cos_half):
				_swallow(e, t)


# NPCs swallow other creatures only when hunting: predators always, anyone else only its aggro target.
func _npc_hunts(e: SimEntity, t: SimEntity) -> bool:
	return _species_of(e).predator or (e.aggro_target == t.id and tick < e.aggro_until_tick)


func _swallow(e: SimEntity, t: SimEntity) -> void:
	var gained: float = 0.0
	if e.is_player:
		# the swallow is the mouth cue of this tick: no BITE_MISSED air-chomp right after it (held bite while eating)
		e.bite_miss_ready_tick = maxi(e.bite_miss_ready_tick, tick + maxi(_bite_miss_cd_ticks, 1))
		var food_xp: float = t.xp_value
		var food_len: float = t.source_length_m
		var hunger_gain: float = t.hunger_value
		var food_sp: _SpeciesRules = null
		if t.kind == SimEntity.Kind.CREATURE:
			food_sp = _species_of(t)
			food_xp = food_sp.xp
			food_len = t.length_m
			hunger_gain = SimRules.hunger_from_xp(food_xp, _hunger_per_xp)
		else:
			food_sp = _species.get(t.source_species, null)
		# species xp_band_mult by the eater's band right now; hunger stays unscaled (tracks food, not progression)
		if food_sp != null:
			food_xp *= _xp_band_mult(food_sp, e.band)
		gained = SimRules.xp_gain(food_xp, e.length_m, food_len, _falloff)
		e.xp += gained
		e.hunger = minf(e.hunger + hunger_gain, _hunger_max)
	_emit(SimEvent.Type.EATEN, t.id, e.id, gained)
	if t.is_player:
		# a player is never removed: it dies in phase 6 and respawns
		t.hp = 0.0
		t.last_damage_from = e.id
	else:
		_remove(t.id, e.id)


# Species XP multiplier for an eater in 1-based `band` (1 when the species has no xp_band_mult).
static func _xp_band_mult(sp: _SpeciesRules, band: int) -> float:
	var m: PackedFloat64Array = sp.xp_band_mult
	return 1.0 if m.is_empty() else m[clampi(band - 1, 0, m.size() - 1)]


# ------------------------------------------------------------------ plankton phase

# Players graze the plankton field, then every krill field in map order (PlanktonField / KrillField class docs),
# ascending id per field; a mouth inside a plankton cell and near a krill eats from both.
func _graze() -> void:
	_sorted_ids()
	if plankton != null:
		_graze_field(plankton, 0)
	for i in krill.size():
		_graze_krill(krill[i], i + 1)
	if tick % _EVENT_TRIM_INTERVAL_TICKS == 0:
		if plankton != null:
			plankton.prune(tick)
		for f: PlanktonField in krill:
			f.prune(tick)


# One field: PLANKTON_EATEN data.field = 0 for plankton, krill index + 1.
func _graze_field(pf: PlanktonField, field: int) -> void:
	for e in _players:
		if not _is_active_creature(e) or not SimRules.can_swallow(e.length_m, pf.length_m, _swallow_ratio):
			continue
		var cell: int = pf.cell_at(e.position + e.heading * (e.length_m * _reach_mult))
		if cell < 0:
			continue
		var amount: float = pf.eat(cell, tick)
		if amount <= 0.0:
			continue
		var gained: float = SimRules.xp_gain(amount * pf.xp_per_unit, e.length_m, pf.length_m, _falloff)
		e.xp += gained
		e.hunger = minf(e.hunger + amount * pf.hunger_per_unit, _hunger_max)
		var ev: SimEvent = _emit(SimEvent.Type.PLANKTON_EATEN, e.id, -1, gained)
		ev.data = {"cell": cell, "amount": amount, "pos": pf.cell_center(cell), "field": field}


# One krill field: every eat_interval_ticks (staggered by entity id) a player swallows the krill nearest to its mouth
# point within max(eat_radius_m, length x mouth_reach_mult) (KrillField.eat_nearest): one critter = one event of
# `unit` density units (XP and hunger as for plankton); data adds the critter index `k`, `pos` = where it was eaten.
func _graze_krill(kf: KrillField, field: int) -> void:
	for e in _players:
		if not _is_active_creature(e) or not SimRules.can_swallow(e.length_m, kf.length_m, _swallow_ratio):
			continue
		if (tick + e.id) % kf.eat_interval_ticks != 0:
			continue
		var reach: float = e.length_m * _reach_mult
		var mouth: Vector3 = e.position + e.heading * reach
		var key: int = kf.eat_nearest(mouth, maxf(kf.eat_radius_m, reach), tick)
		if key < 0:
			continue
		var cell: int = key / KrillField.KEY_STRIDE
		var k: int = key % KrillField.KEY_STRIDE
		var gained: float = SimRules.xp_gain(kf.unit * kf.xp_per_unit, e.length_m, kf.length_m, _falloff)
		e.xp += gained
		e.hunger = minf(e.hunger + kf.unit * kf.hunger_per_unit, _hunger_max)
		var ev: SimEvent = _emit(SimEvent.Type.PLANKTON_EATEN, e.id, -1, gained)
		ev.data = {"cell": cell, "k": k, "amount": kf.unit, "pos": kf.critter_position(cell, k, tick), "field": field}


# ------------------------------------------------------------------ phase 5: bite

# A pending request is retried every tick until it hits (consumed) or tick >= bite_until_tick (dropped); on
# cooldown it just waits. A ready player bite that finds nothing emits the throttled BITE_MISSED cue.
func _resolve_bites() -> void:
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e == null or e.bite_request == NO_BITE:
			continue
		if not _is_active_creature(e):
			e.bite_request = NO_BITE
			continue
		var ready: bool = tick >= e.bite_ready_tick
		var t: SimEntity = _bite_target(e, e.bite_request) if ready else null
		if ready and food != null and e.is_player and e.bite_request < 0:
			var site: int = _site_bite_target(e, t)
			if site >= 0:
				e.bite_request = NO_BITE
				_bite_site(e, site)
				continue
		if t != null:
			e.bite_request = NO_BITE
			_bite(e, t)
			if e.is_player:
				var lunge: float = _player_lunge(e)
				if lunge > 0.0:
					_start_bite_lunge(e, lunge)
			continue
		if ready and e.is_player and tick >= e.bite_miss_ready_tick:
			e.bite_miss_ready_tick = tick + _bite_miss_cd_ticks
			_emit(SimEvent.Type.BITE_MISSED, e.id)
		if tick >= e.bite_until_tick:
			e.bite_request = NO_BITE


# `commit` false = the read-only query of peek_bite_target: the same selection, but the aim lock memory is not written.
func _bite_target(e: SimEntity, req: int, commit: bool = true) -> SimEntity:
	var reach: float = e.length_m * (_bite_reach_mult if e.is_player else _reach_mult)
	var cos_half: float = _bite_cos_half if e.is_player else _cos_half
	if req >= 0:
		var t: SimEntity = _entities.get(req, null)
		if t == null or t == e or not _is_active_creature(t) or not _in_bite_cone(e, t, reach, cos_half):
			return null
		return t
	if e.is_player:  # NPC / boss bites always carry a target (req >= 0), the gate stays explicit
		var aim: float = _player_aim(e)
		if aim > 0.0:
			return _assisted_bite_target(e, reach, cos_half, aim, commit)
	var best: SimEntity = null
	var best_d2: float = INF
	grid.query_radius_into(e.position, reach + _max_creature_len * _max_radius_mult * _max_inflate, _query)
	for tid in _query:
		if tid == e.id:
			continue
		var c: SimEntity = _entities.get(tid, null)
		if c == null or not _is_active_creature(c) or SimRules.can_swallow(e.length_m, effective_length(c), _swallow_ratio):
			continue
		if not _in_bite_cone(e, c, reach, cos_half):
			continue
		var d2: float = e.position.distance_squared_to(c.position)
		if d2 < best_d2:
			best_d2 = d2
			best = c
	return best


# Aim assist (T1.5): soft lock for a player bite without a target. Candidates are the creatures the strict path would
# accept (active, not swallowable by ratio) inside the strict cone, plus those inside the widened cone
# (bite_cone_deg + aim_assist_cone_deg x strength) whose CENTRE is at most aim_assist_max_distance_m metres away; the
# reach (+ target radius) is never extended. Lowest score wins:
#   score = d / reach + strength x angle / PI - stickiness x [candidate is the remembered lock]
# d = centre distance (so the first term is "reaches of own length"), angle = heading to centre in radians (0 = dead
# centre, PI = behind). Equal scores go to the lower entity id (grid order never matters). The lock memory (per
# player, kept for twice the bite cooldown so it outlives the cooldown between two selections) is dropped when the
# remembered target is no longer a candidate or nothing was found.
func _assisted_bite_target(e: SimEntity, reach: float, cos_half: float, strength: float, commit: bool = true) -> SimEntity:
	var aim_cos_half: float = _aim_cos_half if strength == _aim_strength else cos(deg_to_rad(minf(_bite_cone_deg + _aim_cone_deg * strength, 180.0)))
	var lock: int = e.aim_lock_target if tick < e.aim_lock_until_tick else -1
	var inv_reach: float = 1.0 / maxf(reach, 0.001)
	var best: SimEntity = null
	var best_score: float = INF
	grid.query_radius_into(e.position, reach + _max_creature_len * _max_radius_mult * _max_inflate, _query)
	for tid in _query:
		if tid == e.id:
			continue
		var c: SimEntity = _entities.get(tid, null)
		if c == null or not _is_active_creature(c) or SimRules.can_swallow(e.length_m, effective_length(c), _swallow_ratio):
			continue
		var to: Vector3 = c.position - e.position
		var d2: float = to.length_squared()
		if not _in_bite_cone(e, c, reach, cos_half) and (d2 > _aim_max_d2 or not _in_bite_cone(e, c, reach, aim_cos_half)):
			continue
		var d: float = sqrt(d2)
		var angle: float = acos(clampf(e.heading.dot(to) / d, -1.0, 1.0)) if d > 0.000001 else 0.0
		var score: float = d * inv_reach + strength * angle / PI - (_aim_stickiness if c.id == lock else 0.0)
		if score < best_score or (score == best_score and best != null and c.id < best.id):
			best_score = score
			best = c
	if not commit:  # peek: the memory is read (stickiness above), never dropped or refreshed
		return best
	if best == null:
		e.aim_lock_target = -1
		return null
	var esp: _SpeciesRules = _species_of(e)
	e.aim_lock_target = best.id
	e.aim_lock_until_tick = tick + 2 * maxi(esp.bite_cd_ticks if esp.bite_cd_ticks >= 0 else _bite_cd_ticks, 1)
	return best


# Debug / presentation query (T1.11 "can bite" cue, God tools only): the entity id a bite press by player `player_id`
# would hit right now, -1 for none, an unknown id or a player that is dead / at 0 hp. READ-ONLY: it runs the real
# selection (`_bite_target` with target -1: strict cone, aim assist of the rules / control mode, swallowable and inactive
# creatures skipped) but writes nothing (aim lock memory, events, RNG, tick, bite state); the bite cooldown and the
# request buffer are ignored; food sites are not considered (creatures only). No sim phase calls it.
func peek_bite_target(player_id: int) -> int:
	var e: SimEntity = _entities.get(player_id, null)
	if e == null or not _is_active_creature(e):
		return -1
	var t: SimEntity = _bite_target(e, -1, false)
	return t.id if t != null else -1


# Effective aim assist / lunge strength of a player (T1.4): max(rules value, the value of its control mode record). A
# creature that is no player never gets a mode (SET_CONTROL_MODE is ignored for it), the callers gate on is_player.
func _player_aim(e: SimEntity) -> float:
	return maxf(_aim_strength, (_mode_strength.get(e.control_mode, Vector2.ZERO) as Vector2).x)


func _player_lunge(e: SimEntity) -> float:
	return maxf(_lunge_strength, (_mode_strength.get(e.control_mode, Vector2.ZERO) as Vector2).y)


# Boss bites, both ways (S6): overlapping bodies (centre distance <= both collision radii) count as in the cone
# whatever the heading; the centre cone alone means nothing inside a 10 m body. Other bites: the S3 cone only
# (`reach` / `cos_half`: the biter's, player bite or mouth values).
func _in_bite_cone(e: SimEntity, t: SimEntity, reach: float, cos_half: float) -> bool:
	var r: float = collision_radius(t) * (effective_length(t) / t.length_m if t.length_m > 0.0 else 1.0)
	if (e.boss_state >= 0 or t.boss_state >= 0) and BossBrain.bodies_touch(self, e, t):
		return true
	return SimRules.in_cone(e.position, e.heading, t.position, reach + r, cos_half)


func _bite(e: SimEntity, t: SimEntity) -> void:
	var esp: _SpeciesRules = _species_of(e)
	var dmg: float = SimRules.bite_damage(_p_bite_power[_band_index(e.band)], e.length_m, esp.bite_mult) * e.bite_power_mult
	if t.is_player:
		dmg *= t.damage_taken_mult
	t.hp -= dmg
	t.last_damage_from = e.id
	e.bite_ready_tick = tick + (esp.bite_cd_ticks if esp.bite_cd_ticks >= 0 else _bite_cd_ticks)
	if not t.is_player:
		t.aggro_target = e.id
		t.aggro_until_tick = tick + _retaliate_ticks
	var ev: SimEvent = _emit(SimEvent.Type.BITTEN, t.id, e.id, dmg)
	ev.data = {"max_hp": t.max_hp}
	var sp: _SpeciesRules = _species_of(t)
	if sp.inflate_ticks <= 0:
		return
	# the bite that inflates a calm puffer does not spike; only bites on an already inflated puffer do
	if tick >= t.inflated_until_tick:
		t.inflated_until_tick = tick + sp.inflate_ticks
		_emit(SimEvent.Type.INFLATED, t.id, e.id, float(sp.inflate_ticks) * TICK_DT)
		return
	var spike: float = sp.spike_frac * e.max_hp * e.damage_taken_mult
	if spike > 0.0:
		e.hp -= spike
		e.last_damage_from = t.id
		_emit(SimEvent.Type.SPIKED, e.id, t.id, spike)


# ------------------------------------------------------------------ food sites (FoodSites; class doc "Food sites")

# Swallow lap, after the creature swallows: the respawns due this tick, then the players swallow soft sites.
func _eat_sites() -> void:
	food.pop_respawns_into(tick, _site_query)
	for i in _site_query:
		var rev: SimEvent = _emit(SimEvent.Type.SITE_RESPAWNED, -1)
		rev.data = {"site": i, "type": food.site_type(i), "pos": food.site_pos(i)}
	_sorted_ids()
	for e in _players:
		if not _is_active_creature(e):
			continue
		var reach: float = e.length_m * _reach_mult
		if not (reach > 0.0):
			continue
		food.sites_near_into(e.position, reach + food.max_radius(), _site_query)
		for i in _site_query:
			if not food.site_soft(i) or not food.site_alive(i, tick) or not _site_swallowable(e, i):
				continue
			if SimRules.in_cone(e.position, e.heading, food.site_pos(i), reach + food.site_radius(i), _cos_half):
				_eat_site(e, i)
	if tick % _EVENT_TRIM_INTERVAL_TICKS == 0:
		food.prune(tick)


func _site_swallowable(e: SimEntity, i: int) -> bool:
	var ratio: float = food.site_swallow_ratio(i)
	return SimRules.can_swallow(e.length_m, food.site_length(i), ratio if ratio >= 0.0 else _swallow_ratio)


# Nearest live site in the player's bite cone that is closer than the best creature `t` (null = none), -1 = none.
# Soft sites count only when swallowable.
func _site_bite_target(e: SimEntity, t: SimEntity) -> int:
	var reach: float = e.length_m * _bite_reach_mult
	var best_d2: float = e.position.distance_squared_to(t.position) if t != null else INF
	var best: int = -1
	food.sites_near_into(e.position, reach + food.max_radius(), _site_query)
	for i in _site_query:
		if food.site_soft(i) and not _site_swallowable(e, i):
			continue
		var p: Vector3 = food.site_pos(i)
		var d2: float = e.position.distance_squared_to(p)
		if d2 < best_d2 and SimRules.in_cone(e.position, e.heading, p, reach + food.site_radius(i), _bite_cos_half):
			best_d2 = d2
			best = i
	return best


# A player bite on site `i`: cooldown, then a soft site is eaten, a hard one damaged (eaten at HP <= 0).
func _bite_site(e: SimEntity, i: int) -> void:
	var esp: _SpeciesRules = _species_of(e)
	e.bite_ready_tick = tick + (esp.bite_cd_ticks if esp.bite_cd_ticks >= 0 else _bite_cd_ticks)
	if food.site_soft(i):
		_eat_site(e, i)
		return
	var dmg: float = SimRules.bite_damage(_p_bite_power[_band_index(e.band)], e.length_m, esp.bite_mult) * e.bite_power_mult
	var hp: float = food.bite(i, dmg, tick)
	var ev: SimEvent = _emit(SimEvent.Type.SITE_BITTEN, e.id, -1, dmg)
	ev.data = {"site": i, "type": food.site_type(i), "pos": food.site_pos(i), "max_hp": food.site_max_hp(i), "hp": maxf(hp, 0.0)}
	if hp <= 0.0:
		_eat_site(e, i)


# Player `e` eats site `i`: XP (type xp x band mult, falloff) and hunger, the site waits for its respawn.
func _eat_site(e: SimEntity, i: int) -> void:
	var soft: bool = food.site_soft(i)
	if soft:
		# like a swallow: the mouth cue of this tick, no BITE_MISSED air-chomp right after it
		e.bite_miss_ready_tick = maxi(e.bite_miss_ready_tick, tick + maxi(_bite_miss_cd_ticks, 1))
	var gained: float = SimRules.xp_gain(food.site_xp(i) * food.site_band_mult(i, e.band), e.length_m, food.site_length(i), _falloff)
	e.xp += gained
	e.hunger = minf(e.hunger + SimRules.hunger_from_xp(food.site_hunger_xp(i), _hunger_per_xp), _hunger_max)
	food.eat(i, tick)
	var ev: SimEvent = _emit(SimEvent.Type.SITE_EATEN, e.id, -1, gained)
	ev.data = {"site": i, "type": food.site_type(i), "pos": food.site_pos(i), "soft": soft}


# ------------------------------------------------------------------ phase 6: deaths and respawns

func _resolve_deaths() -> void:
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e == null or e.kind != SimEntity.Kind.CREATURE:
			continue
		if e.alive and e.hp <= 0.0 and e.boss_state != BossBrain.State.STUNNED:
			_die(e)
		elif not e.alive and e.respawn_tick >= 0 and tick >= e.respawn_tick:
			_respawn(e)


func _die(e: SimEntity) -> void:
	var ev: SimEvent = _emit(SimEvent.Type.DIED, e.id, e.last_damage_from)
	ev.data = {"species": e.species_id, "length": e.length_m, "pos": e.position}
	if not e.is_player:
		_spawn_remains(e)
		_remove(e.id, e.last_damage_from)
		return
	e.hp = 0.0
	e.alive = false  # before _grow: a dying player gets no mutation offer (a dead player cannot pick, the pause would never end)
	e.xp = maxf(e.xp * (1.0 - _death_loss), 0.0)
	_grow(e)
	e.deaths += 1
	e.respawn_tick = tick + _respawn_ticks
	e.velocity = Vector3.ZERO
	e.speed = 0.0
	e.boosting = false
	e.braking = false
	e.bite_request = NO_BITE
	e.bite_until_tick = -1
	e.dash_until_tick = -1
	e.dash_ability = &""
	e.dash_velocity = Vector3.ZERO
	e.bite_lunge_left = 0
	if e.hidden:
		e.hidden = false
		e.hidden_since_tick = -1
		_emit(SimEvent.Type.REVEALED, e.id)
	grid.remove(e.id)


# At the map player spawn nearest to where the player died (its position is kept while dead).
func _respawn(e: SimEntity) -> void:
	var pos: Vector3 = e.position
	var best_d2: float = INF
	for sp in _spawns:
		var d2: float = sp.distance_squared_to(e.position)
		if d2 < best_d2:
			best_d2 = d2
			pos = sp
	e.alive = true
	e.respawn_tick = -1
	e.hp = e.max_hp
	e.hunger = _hunger_max
	e.stamina = _stamina_max
	e.last_damage_from = -1
	e.velocity = Vector3.ZERO
	e.position = _constrain(e, pos) if seabed != null else pos
	_grid_sync(e)
	var ev: SimEvent = _emit(SimEvent.Type.RESPAWNED, e.id)
	ev.data = {"pos": e.position}


# 3-6 (rules remains.food_bits min..max, world RNG) glowing bits sharing the creature's XP and hunger value;
# `fixed_count` >= 0 (boss) replaces the draw, `len_scale` scales the bit length, `out_ids` collects the bit ids.
func _spawn_remains(e: SimEntity, fixed_count: int = -1, len_scale: float = 1.0, out_ids: PackedInt32Array = PackedInt32Array()) -> void:
	var count: int = fixed_count if fixed_count >= 0 else rng.range_int(_bits_min, _bits_max)
	if count <= 0:
		return
	var sp: _SpeciesRules = _species_of(e)
	var xp_each: float = sp.xp / float(count)
	var hunger_each: float = SimRules.hunger_from_xp(sp.xp, _hunger_per_xp) / float(count)
	var spread: float = collision_radius(e)
	for i in count:
		var pos: Vector3 = e.position + _rand_unit() * (spread * rng.next_float())
		var vel: Vector3 = _rand_unit() * _bit_drift
		var b := _new_entity()
		b.kind = SimEntity.Kind.FOOD_BIT
		b.species_id = FOOD_BIT_SPECIES_ID
		b.length_m = _bit_len * len_scale
		# pushed out of obstacles once at spawn (a bit inside a rock is unreachable); drifting keeps the cheap clamp
		b.position = _clamp_point(seabed.resolve(pos, collision_radius(b)), collision_radius(b)) if seabed != null else pos
		b.velocity = vel
		b.heading = vel.normalized() if not vel.is_zero_approx() else Vector3.FORWARD
		b.xp_value = xp_each
		b.hunger_value = hunger_each
		b.source_length_m = e.length_m
		b.source_species = e.species_id
		b.expire_tick = tick + _bit_life_ticks
		_add(b)
		out_ids.append(b.id)
		_emit(SimEvent.Type.FOOD_SPAWNED, b.id, e.id, xp_each)


# Uniform direction from the world RNG (rejection sampling; deterministic draw count per accepted sample).
func _rand_unit() -> Vector3:
	for i in 16:
		var v := Vector3(rng.range_float(-1.0, 1.0), rng.range_float(-1.0, 1.0), rng.range_float(-1.0, 1.0))
		var l2: float = v.length_squared()
		if l2 > 1e-4 and l2 <= 1.0:
			return v / sqrt(l2)
	return Vector3.UP


# ------------------------------------------------------------------ boss phase

# Finisher / stun / charge hits / regen, then the victory check (class doc).
func _update_boss() -> void:
	var b: SimEntity = _entities.get(_boss_id, null)
	if b != null and b.alive:
		var p: BossBrain.Params = BossBrain.params(self, b.species_id)
		if p != null:
			if b.boss_state == BossBrain.State.STUNNED:
				_sorted_ids()
				for pl in _players:
					if _is_active_creature(pl) and _in_bite_cone(pl, b, pl.length_m * _bite_reach_mult, _bite_cos_half):
						_defeat_boss(b, pl, p)
						break
				if b.boss_state == BossBrain.State.STUNNED and p.stun_timeout_ticks > 0 and tick - b.boss_state_tick >= p.stun_timeout_ticks:
					BossBrain.recover_from_stun(self, b, p)
			elif b.hp <= 0.0:
				b.hp = 0.0
				b.boss_state = BossBrain.State.STUNNED
				b.boss_state_tick = tick
				b.dash_until_tick = -1
				b.dash_ability = &""
				b.dash_velocity = Vector3.ZERO
				b.move_thrust = 0.0
				b.boost_held = false
				b.boosting = false
				_emit(SimEvent.Type.BOSS_STUNNED, b.id, b.last_damage_from)
			else:
				if b.boss_state == BossBrain.State.DASH and b.dash_until_tick >= 0:
					_charge_hits(b, p)
				if (b.boss_state == BossBrain.State.PATROL or b.boss_state == BossBrain.State.DISENGAGE) and b.hp < b.max_hp:
					b.hp = minf(b.hp + p.regen_frac * b.max_hp * TICK_DT, b.max_hp)
	if _boss_defeated_tick >= 0 and not run_won:
		var left: bool = false
		for id in _boss_remains:
			if _entities.has(id):
				left = true
				break
		if not left or tick - _boss_defeated_tick >= _boss_victory_ticks:
			_win()


# The charging boss damages every player its body touches, once per charge.
func _charge_hits(b: SimEntity, p: BossBrain.Params) -> void:
	_sorted_ids()
	var rb: float = collision_radius(b) + p.hit_margin
	for pl in _players:
		if not _is_active_creature(pl) or b.boss_dash_hits.has(pl.id):
			continue
		var r: float = rb + collision_radius(pl)
		if pl.position.distance_squared_to(b.position) > r * r:
			continue
		b.boss_dash_hits.append(pl.id)
		var dmg: float = BossBrain.dash_damage(p, pl) * pl.damage_taken_mult
		pl.hp -= dmg
		pl.last_damage_from = b.id
		var ev: SimEvent = _emit(SimEvent.Type.BITTEN, pl.id, b.id, dmg)
		ev.data = {"max_hp": pl.max_hp, "dash": true}


func _defeat_boss(b: SimEntity, pl: SimEntity, p: BossBrain.Params) -> void:
	b.boss_state = BossBrain.State.DEFEATED
	b.boss_state_tick = tick
	b.last_damage_from = pl.id
	var ev: SimEvent = _emit(SimEvent.Type.BOSS_DEFEATED, b.id, pl.id)
	ev.data = {"pos": b.position}
	var died: SimEvent = _emit(SimEvent.Type.DIED, b.id, pl.id)
	died.data = {"species": b.species_id, "length": b.length_m, "pos": b.position}
	_boss_remains = PackedInt32Array()
	_spawn_remains(b, p.remains_bits, p.bit_scale, _boss_remains)
	_boss_defeated_tick = tick
	_boss_finisher = pl.id
	_boss_victory_ticks = p.victory_ticks
	_remove(b.id, pl.id)


func _win() -> void:
	run_won = true
	var pl: SimEntity = _entities.get(_boss_finisher, null)
	var ev: SimEvent = _emit(SimEvent.Type.VICTORY, _boss_finisher)
	ev.data = {"run_ticks": run_ticks, "deaths": pl.deaths if pl != null else 0, "mutations": pl.mutations.duplicate() if pl != null else PackedStringArray()}


# ------------------------------------------------------------------ phases 7-8: vitals and growth

func _update_vitals() -> void:
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e == null or not e.is_player or not _is_active_creature(e):
			continue
		e.hunger = maxf(e.hunger - SimRules.hunger_drain_per_tick(_hunger_max, _hunger_full_s, _p_hunger_mult[_band_index(e.band)], TICK_DT) * e.hunger_drain_mult, 0.0)
		if e.hunger <= 0.0:
			e.hp -= _starve_frac * e.max_hp * TICK_DT
			e.last_damage_from = -1
		elif e.hunger > _regen_min_frac * _hunger_max and e.hp < e.max_hp:
			e.hp = minf(e.hp + _regen_frac * e.max_hp * TICK_DT, e.max_hp)


func _update_growth() -> void:
	for id in _sorted_ids():
		var e: SimEntity = _entities.get(id, null)
		if e != null and e.is_player and e.alive and e.xp != e.grown_at_xp and is_finite(e.xp):
			_grow(e)


# Band, length and max HP from XP (hp keeps its fraction of max HP); BAND_UP / BAND_DOWN on a band change.
func _grow(e: SimEntity) -> void:
	e.grown_at_xp = e.xp
	var old_band: int = e.band
	var frac: float = clampf(e.hp / e.max_hp, 0.0, 1.0) if e.max_hp > 0.0 else 1.0
	e.band = SimRules.band_for_xp(e.xp, _bands)
	e.length_m = SimRules.length_for_xp(e.xp, _bands)
	_max_creature_len = maxf(_max_creature_len, e.length_m)
	e.max_hp = _player_max_hp(e)
	e.hp = frac * e.max_hp
	if e.band > old_band:
		_emit(SimEvent.Type.BAND_UP, e.id, -1, float(e.band))
		Progression.offer(self, e)
	elif e.band < old_band:
		_emit(SimEvent.Type.BAND_DOWN, e.id, -1, float(e.band))


func _player_max_hp(e: SimEntity) -> float:
	if _hp_length2:
		return SimRules.creature_max_hp(_species_of(e).base_hp, e.length_m)
	return _p_max_hp[_band_index(e.band)]


# ------------------------------------------------------------------ helpers

# A living creature that can still act (eat, bite, be bitten): food bits, dead players and creatures already at
# 0 HP this tick are not.
static func _is_active_creature(e: SimEntity) -> bool:
	return e.kind == SimEntity.Kind.CREATURE and e.alive and e.hp > 0.0


func _species_of(e: SimEntity) -> _SpeciesRules:
	return _species.get(e.species_id, _no_species)


func _emit(type: SimEvent.Type, entity_id: int, other_id: int = -1, value: float = 0.0) -> SimEvent:
	var ev := SimEvent.create(type, tick, entity_id, other_id, value)
	_events.append(ev)
	return ev


# Events are appended in tick order, so the expired ones are a prefix.
func _trim_events() -> void:
	var cutoff: int = tick - EVENT_RETENTION_TICKS
	if _events.is_empty() or _events[0].tick >= cutoff:
		return
	var i: int = 0
	while i < _events.size() and _events[i].tick < cutoff:
		i += 1
	_events = _events.slice(i)


func _new_entity() -> SimEntity:
	var e := SimEntity.new()
	e.id = _next_id
	_next_id += 1
	return e


func _add(e: SimEntity) -> void:
	_entities[e.id] = e
	_ids_dirty = true
	_count_tier(e, 1)
	_grid_sync(e)


# `by_id`: who swallowed / killed it (-1 n/a); a promoted school member removed this way is lost to its school.
func _remove(id: int, by_id: int = -1) -> void:
	var e: SimEntity = _entities.get(id, null)
	if e == null:
		return
	if e.school_id >= 0 and schools != null:
		schools.member_lost(self, e, by_id)
	_count_tier(e, -1)
	_entities.erase(id)
	grid.remove(id)
	_ids_dirty = true


func _count_tier(e: SimEntity, delta: int) -> void:
	if e.kind != SimEntity.Kind.CREATURE or e.is_player:
		return
	var tier: int = _species_of(e).tier
	if tier >= 0:
		_tier_npcs[tier] += delta


func _grid_sync(e: SimEntity) -> void:
	# the grid rejects (with an error) positions it cannot index; such an entity is simply not in the grid
	if e.position.is_finite() and maxf(maxf(absf(e.position.x), absf(e.position.y)), absf(e.position.z)) < 1.0e6:
		grid.move(e.id, e.position)
	else:
		grid.remove(e.id)


# Cached ascending ids. A rebuild replaces the array, so a loop over an earlier result is never disturbed by
# spawns or removals during a phase.
func _sorted_ids() -> PackedInt32Array:
	if _ids_dirty:
		_ids = PackedInt32Array(_entities.keys())
		_ids_dirty = false
		_players.clear()
		for e: SimEntity in _entities.values():
			if e.is_player:
				_players.append(e)
	return _ids


func _band_index(band: int) -> int:
	var n: int = _p_speed.size() - 1
	return clampi(band, 1, n) if n > 0 else 0


# Caches every tunable from `content` (re-run when `content` is swapped); index 0 holds the S0 defaults.
func _configure() -> void:
	if _configured and _configured_for == content:
		return
	_configured = true
	_configured_for = content
	_p_speed = PackedFloat64Array([DEFAULT_BASE_SPEED_MPS])
	_p_accel = PackedFloat64Array([INF])
	_p_drag = PackedFloat64Array([INF])
	_p_turn = PackedFloat64Array([INF])
	_p_brake = PackedFloat64Array([INF])
	_p_lunge_m = PackedFloat64Array([0.0])
	_p_radius_mult = PackedFloat64Array([0.0])
	_p_max_hp = PackedFloat64Array([1.0])
	_p_bite_power = PackedFloat64Array([0.0])
	_p_hunger_mult = PackedFloat64Array([1.0])
	_bands = []
	_max_pitch_sin = 1.0
	_max_pitch_cos = 0.0
	_stamina_max = 0.0
	_boost_drain = 0.0
	_boost_regen = 0.0
	_boost_restart_frac = 0.0
	_boost_mult = 1.0
	_bite_dash_exit_frac = 1.0
	krill = []
	map = {}
	seabed = null
	schools = null
	plankton = null
	tiers = null
	food = null
	_spawns = PackedVector3Array()
	_player_species = PLAYER_SPECIES_ID
	_species = {}
	_max_inflate = 1.0
	_max_radius_mult = 0.0
	_configure_rules()
	_mode_strength = {}
	if content != null:
		for id: StringName in content.control_mode_ids():
			var m: Dictionary = content.get_control_mode(id)
			_mode_strength[id] = Vector2(clampf(float(m.get("aim_assist_strength", 0.0)), 0.0, 1.0), clampf(float(m.get("lunge_strength", 0.0)), 0.0, 1.0))
	grid = SpatialGrid.new(_rule_f("grid_cell_m", DEFAULT_GRID_CELL_M))
	for id in _sorted_ids():
		_grid_sync(_entities[id])
	if content == null:
		return
	for i in range(1, content.band_count() + 1):
		var b: Dictionary = content.get_band(i)
		_bands.append(b)
		_p_speed.append(float(b.get("swim_speed_mps", DEFAULT_BASE_SPEED_MPS)))
		_p_accel.append(float(b.get("accel_mps2", INF)))
		_p_drag.append(float(b.get("drag_per_s", INF)))
		_p_turn.append(deg_to_rad(float(b.get("turn_rate_deg_s", INF))) * TICK_DT)
		_p_brake.append(float(b.get("brake_decel_mps2", INF)))
		_p_lunge_m.append(float(b.get("lunge_distance_m", 0.0)))
		_p_radius_mult.append(float(b.get("collision_radius_mult", 0.0)))
		_p_max_hp.append(float(b.get("max_hp", 1.0)))
		_p_bite_power.append(float(b.get("bite_power", 0.0)))
		_p_hunger_mult.append(float(b.get("hunger_drain_mult", 1.0)))
		_max_radius_mult = maxf(_max_radius_mult, _p_radius_mult[i])
	if debug != null and debug.tuning != null:
		_apply_band_tuning()
	var swim: Variant = content.rules().get("swim")
	if swim is Dictionary and (swim as Dictionary).has("max_pitch_deg"):
		var pitch: float = deg_to_rad(float((swim as Dictionary)["max_pitch_deg"]))
		_max_pitch_sin = sin(pitch)
		_max_pitch_cos = cos(pitch)
	var boost: Dictionary = content.get_ability(&"boost")
	_stamina_max = float(boost.get("stamina_max", 0.0))
	_boost_drain = float(boost.get("stamina_drain_per_s", 0.0))
	_boost_regen = float(boost.get("stamina_regen_per_s", 0.0))
	_boost_restart_frac = float(boost.get("restart_min_stamina_frac", 0.0))
	_boost_mult = float(boost.get("speed_mult", 1.0))
	_bite_dash_exit_frac = float(content.get_ability(Abilities.BITE_DASH).get("exit_speed_frac", 1.0))
	_configure_species()
	_recount_tiers()
	map = content.get_map(map_id)
	if map.is_empty():
		return
	var spawns: Array = map.get("player_spawns", []) if map.get("player_spawns") is Array else []
	for sp in spawns:
		_spawns.append(Vector3(float(sp[0]), float(sp[1]), float(sp[2])))
	seabed = SeabedField.from_map(map, content.get_proxies(map_id))
	food = FoodSites.create(content, map_id, _rule_f("grid_cell_m", DEFAULT_GRID_CELL_M))
	if food != null:
		food.now_tick = tick
	_half_size = float(map.get("size_m", 0.0)) * 0.5
	_depth = float(map.get("depth_m", 0.0))
	var bounds: Dictionary = map.get("bounds", {}) if map.get("bounds") is Dictionary else {}
	_soft_margin = float(bounds.get("soft_margin_m", 0.0))
	_current_mps = float(bounds.get("current_mps", 0.0))
	_configure_krill()
	if map.get("schools") is Array:
		schools = SchoolSystem.create(_seed, content, map, seabed)
		tiers = TierManager.create(content)
	plankton = PlanktonField.create(content, map)


# Tuning lab (T1.3, SimDebug.tuning_*): re-derives every cached number the override layer reaches, so a change acts on the next
# tick: the rule numbers of _configure_rules (through _rule_f) and the band movement arrays.
func _retune() -> void:
	_configure()
	_configure_rules()
	_apply_band_tuning()


# Band movement arrays from the band tables with the override layer on top (the same expressions as _configure; with an empty
# layer every value is the data value, bit for bit).
func _apply_band_tuning() -> void:
	var t: TuningOverrides = debug.tuning if debug != null else null
	for i in range(1, _bands.size() + 1):
		var b: Dictionary = _bands[i - 1]
		_p_speed[i] = _band_f(t, "swim_speed_mps", i, b, DEFAULT_BASE_SPEED_MPS)
		_p_accel[i] = _band_f(t, "accel_mps2", i, b, INF)
		_p_drag[i] = _band_f(t, "drag_per_s", i, b, INF)
		_p_turn[i] = deg_to_rad(_band_f(t, "turn_rate_deg_s", i, b, INF)) * TICK_DT
		_p_brake[i] = _band_f(t, "brake_decel_mps2", i, b, INF)
		_p_lunge_m[i] = _band_f(t, "lunge_distance_m", i, b, 0.0)


static func _band_f(t: TuningOverrides, field: String, band: int, rec: Dictionary, fallback: float) -> float:
	var base: float = float(rec.get(field, fallback))
	return base if t == null else t.band_override(field, band, base)


func _recount_tiers() -> void:
	_tier_npcs = PackedInt32Array([0, 0, 0])
	for e: SimEntity in _entities.values():
		_count_tier(e, 1)


# Krill clouds: one KrillField per map `krill` entry (entries whose species is missing are skipped).
func _configure_krill() -> void:
	var blocks: Array = map.get("krill", []) if map.get("krill") is Array else []
	for b: Variant in blocks:
		var f: KrillField = KrillField.from_block(content, map, b) if b is Dictionary else null
		if f != null:
			krill.append(f)


# Rule numbers (rules/core.json); without content every rule is inert.
func _configure_rules() -> void:
	_swallow_ratio = _rule_f("swallow_ratio", 0.0)
	_reach_mult = _rule_f("mouth_reach_mult", 0.0)
	_cos_half = cos(deg_to_rad(_rule_f("mouth_cone_deg", 0.0)))
	_bite_cd_ticks = maxi(roundi(_rule_f("bite_cooldown_s", 0.0) * TICK_RATE), 0)
	_bite_reach_mult = _rule_f("bite_reach_mult", _reach_mult)
	_bite_cone_deg = _rule_f("bite_cone_deg", _rule_f("mouth_cone_deg", 0.0))
	_bite_cos_half = cos(deg_to_rad(_bite_cone_deg))
	_aim_strength = clampf(_rule_f("aim_assist_strength", 0.0), 0.0, 1.0)
	_aim_cone_deg = maxf(_rule_f("aim_assist_cone_deg", 0.0), 0.0)
	_aim_cos_half = cos(deg_to_rad(minf(_bite_cone_deg + _aim_cone_deg * _aim_strength, 180.0)))
	_aim_max_d2 = maxf(_rule_f("aim_assist_max_distance_m", 0.0), 0.0) ** 2
	_aim_stickiness = clampf(_rule_f("aim_assist_stickiness", 0.0), 0.0, 1.0)
	_lunge_strength = clampf(_rule_f("lunge_strength", 0.0), 0.0, 1.0)
	_lunge_ticks = maxi(roundi(_rule_f("lunge_duration_s", 0.0) * TICK_RATE), 0)
	_bite_buffer_ticks = maxi(roundi(_rule_f("bite_buffer_s", 0.0) * TICK_RATE), 0)
	_bite_miss_cd_ticks = maxi(roundi(_rule_f("bite_miss_cooldown_s", 0.0) * TICK_RATE), 0)
	_retaliate_ticks = roundi(_rule_f("retaliate_duration_s", 0.0) * TICK_RATE)
	_hunger_max = _rule_f("hunger_max", 0.0)
	_hunger_full_s = _rule_f("hunger_full_to_empty_s", 0.0)
	_hunger_per_xp = _rule_f("hunger_per_xp", 0.0)
	_starve_frac = _rule_f("starvation_hp_frac_per_s", 0.0)
	_regen_min_frac = _rule_f("regen_min_hunger_frac", 1.0)
	_regen_frac = _rule_f("regen_hp_frac_per_s", 0.0)
	_death_loss = clampf(_rule_f("death_xp_loss_frac", 0.0), 0.0, 1.0)
	_respawn_ticks = roundi(_rule_f("respawn_delay_s", 0.0) * TICK_RATE)
	_falloff = content.rules().get("xp_falloff", {}) if content != null and content.rules().get("xp_falloff") is Dictionary else {}
	_bits_min = int(_rule_f("remains.food_bits.min", 0.0))
	_bits_max = int(_rule_f("remains.food_bits.max", 0.0))
	_bit_len = _rule_f("remains.food_bits.length_m", 0.0)
	_bit_drift = _rule_f("remains.food_bits.drift_mps", 0.0)
	_bit_life_ticks = roundi(_rule_f("remains.food_bits.lifetime_s", 0.0) * TICK_RATE)
	_hp_length2 = content != null and str(content.rules().get("player_hp_model", "band")) == "length2"


func _configure_species() -> void:
	var playable: StringName = &""
	for id in content.species_ids():
		var rec: Dictionary = content.get_species(id)
		var s := _SpeciesRules.new()
		s.base_hp = float(rec.get("base_hp", 0.0))
		s.hp_override = float(rec.get("hp_override", -1.0))
		s.xp = float(rec.get("xp", 0.0))
		if rec.get("xp_band_mult") is Array:
			for m: Variant in (rec["xp_band_mult"] as Array):
				s.xp_band_mult.append(float(m))
		s.bite_mult = float(rec.get("bite_mult", 1.0))
		s.predator = str(rec.get("temperament", "")) == "predator"
		s.tier = ContentDB.SPECIES_TIERS.find(str(rec.get("tier", "")))
		var inflate: Variant = rec.get("inflate")
		if inflate is Dictionary:
			s.inflate_scale = float((inflate as Dictionary).get("scale", 1.0))
			s.inflate_ticks = roundi(float((inflate as Dictionary).get("duration_s", 0.0)) * TICK_RATE)
			s.spike_frac = float((inflate as Dictionary).get("spike_damage_frac_of_biter_max_hp", 0.0))
			_max_inflate = maxf(_max_inflate, s.inflate_scale)
		var profile: Variant = rec.get("player_profile")
		if profile is Dictionary:
			var pp: Dictionary = profile
			s.prof_speed = float(pp.get("swim_speed_mult", 1.0))
			s.prof_turn = float(pp.get("turn_rate_mult", 1.0))
			s.prof_accel = float(pp.get("accel_mult", 1.0))
			s.prof_drag = float(pp.get("drag_mult", 1.0))
			s.prof_brake = float(pp.get("brake_mult", 1.0))
		if rec.get("boss") is Dictionary:
			s.boss = true
			s.bite_cd_ticks = BossBrain.params(self, id).bite_cd_ticks
		_species[id] = s
		if playable == &"" and rec.get("playable") == true:
			playable = id
	if playable != &"":
		_player_species = playable


# Number at a dotted path in rules/core.json, `fallback` when there is no content or the value is missing.
func _rule_f(path: String, fallback: float) -> float:
	if content == null:
		return fallback
	if debug != null and debug.tuning != null:
		var tuned: Variant = debug.tuning.rule_override(path)
		if tuned != null:
			return float(tuned)
	var cur: Variant = content.rules()
	for part in path.split("."):
		if not (cur is Dictionary) or not (cur as Dictionary).has(part):
			return fallback
		cur = (cur as Dictionary)[part]
	return float(cur) if (typeof(cur) == TYPE_INT or typeof(cur) == TYPE_FLOAT) else fallback


static func _put_strings(buf: StreamPeerBuffer, a: PackedStringArray) -> void:
	buf.put_32(a.size())
	for x in a:
		buf.put_utf8_string(x)


static func _put_vec(buf: StreamPeerBuffer, v: Vector3) -> void:
	buf.put_double(v.x)
	buf.put_double(v.y)
	buf.put_double(v.z)
