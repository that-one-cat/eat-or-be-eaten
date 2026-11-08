class_name NpcBrain
extends RefCounted
## NPC decision making (GAME_DESIGN section 3). Static and stateless: everything an NPC remembers lives in its
## SimEntity brain fields (brain_state, aggro_target, aggro_until_tick); the world is only read, every action is a
## SimCommand submitted for the current tick (rule 2: NPCs use the same command path as players).
## Deterministic: no RNG draws at all (wander targets are a pure hash of entity id and time), ids are visited in the
## order SimWorld calls think(), grid queries return ascending ids, ties go to the lower id.
##
## Temperament state machines (State values are stored in SimEntity.brain_state):
##   predator:  WANDER -> CHASE when a creature <= rules.predator_hunt_ratio of its length is within
##              detection_radius_m (x rules.hiding.detection_mult against hidden targets; never its own species
##              unless that is the player, never ambient-tier species). CHASE -> WANDER when the target is gone, or
##              aggro_until_tick passes (give-up deadline: tick + rules.predator_give_up_s, pushed out again on every
##              think that closes the distance on a visible target), or the target has been hidden for
##              rules.hiding.lose_target_s (a target hidden that long is not detected at all until it leaves).
##   retaliate: WANDER until SimWorld sets aggro_target/aggro_until_tick on a bite (retaliate_duration_s), then
##              RETALIATE (chase + bite the attacker) until the deadline or the same hiding loss. Puffers are
##              retaliators; inflating and spikes are bite rules (SimWorld), not brain decisions.
##   passive:   FLEE from creatures >= behaviour.flee_min_length_ratio x its length within flee_radius_m (own
##              species ignored unless player; once fleeing, until none is within flee_radius_m x
##              behaviour.flee_release_mult), else WANDER. behaviour.flees = false (plankton swarm) never flees.
## While pursuing: BITE the target when it touches the mouth cone (rules.mouth_reach_mult, rules.mouth_cone_deg),
## the bite is off cooldown and the target is too big to swallow (swallowing is automatic); thrust scales with how
## well the fish faces the target and inside bite range it brakes to turn on the spot. Boost when facing the
## target within behaviour.boost_within_m (fleeing: a threat that close). WANDER: cruise at behaviour.wander_speed_frac of
## swim_speed_mps toward a point within behaviour.wander_radius_m inside the home zone (spawner zone, else the
## species zone it is in, else its first zone), re-picked every behaviour.wander_retarget_s. All steering keeps
## behaviour.seabed_clearance_m above the SeabedField and below the surface. Promoted school members (S4) wander by
## following their school slot (rules schools.follow_lookahead_s, see _wander); fleeing and pursuit are unchanged.
## Pack followers (NpcSpawner packs, spawner `group`): a member whose pack leader is another NPC wanders by following
## it instead (loose cohesion, see _follow_leader); its own detection, pursuit, retaliation, bites and hp are those
## of any NPC, the leader (lowest-id living member) wanders normally.
## Brains think every behaviour.think_interval_ticks ticks, staggered by id (MOVE intents persist in between);
## a pursuing brain thinks every tick so bites are not missed.
##
## Hiding: hiding_tag_at() / update_hidden() implement map `hiding_volumes` membership; SimWorld calls
## update_hidden() for every creature so `hidden` / `hidden_since_tick` stay current (brains read `hidden`).

enum State { WANDER, CHASE, RETALIATE, FLEE }

const _PREDATOR: int = 0
const _RETALIATE: int = 1
const _PASSIVE: int = 2
## Pursuit thrust never drops below this fraction while turning toward the target (steering constant, keeps a
## little forward speed so the turn rate applies).
const _MIN_TURN_THRUST: float = 0.1
## Hiding-volume broad-phase cell (metres, lookup structure only).
const HIDE_CELL_M: float = 16.0
const _INV_HIDE_CELL: float = 1.0 / HIDE_CELL_M
const _MAX_MASK_VOLUMES: int = 62

static var _ctx: _Ctx = null
static var _ids: PackedInt32Array = PackedInt32Array()  # reused grid query buffer (no per-NPC allocation)


## Per-species brain numbers, read once from content.
class _Species:
	extends RefCounted
	var temperament: int = _PASSIVE
	var ambient: bool = false
	var speed: float = 0.0
	var detect_radius: float = 0.0
	var flee_radius: float = 0.0
	var flees: bool = false
	var flee_ratio: float = 1.0
	var flee_release: float = 1.0
	var boost_within: float = 0.0
	var wander_frac: float = 0.0
	var wander_radius: float = 0.0
	var wander_ticks: int = 1
	var think_ticks: int = 1
	var clearance: float = 0.0
	var zones: PackedInt32Array = PackedInt32Array()  # map zone indices of the species' zones, data order


## Content-derived lookup tables for one (ContentDB, map) pair; immutable once built.
class _Ctx:
	extends RefCounted
	var content: ContentDB = null
	var map_id: StringName = &""
	var species: Dictionary = {}  # StringName -> _Species
	var band_speed: PackedFloat64Array = PackedFloat64Array()  # [band] -> swim_speed_mps, index 0 unused
	var zone_index: Dictionary = {}  # String zone id -> index
	var zone_min: PackedVector3Array = PackedVector3Array()
	var zone_max: PackedVector3Array = PackedVector3Array()
	var hide_min: PackedVector3Array = PackedVector3Array()
	var hide_max: PackedVector3Array = PackedVector3Array()
	var hide_tag: Array[StringName] = []
	var hide_cells: PackedInt64Array = PackedInt64Array()  # [ix * hide_n + iz] -> bit mask of volume indices
	var hide_n: int = 0  # cells per axis, 0 = no broad phase (full scan)
	var hide_origin: Vector2 = Vector2.ZERO  # (x, z) of cell (0, 0)
	var hunt_ratio: float = 0.0
	var detect_mult: float = 1.0
	var lose_ticks: int = 0
	var give_up_ticks: int = 0
	var reach_mult: float = 0.0
	var cone_cos: float = 1.0
	var swallow_ratio: float = 0.0
	var follow_s: float = 0.0  # rules schools.follow_lookahead_s
	var follow_ticks: int = 0


## Decides this tick's commands for one NPC (players, dead entities and food bits are ignored).
## Called by SimWorld.step() in phase 1 for every creature in ascending id order; commands use tick = world.tick.
static func think(world: SimWorld, e: SimEntity) -> void:
	if e.is_player or not e.alive or e.kind != SimEntity.Kind.CREATURE:
		return
	var ctx: _Ctx = _context(world)
	if ctx == null:
		return
	var sp: _Species = ctx.species.get(e.species_id)
	if sp == null:
		return
	# pursuers think every tick (bite timing), everyone else every think_interval_ticks, staggered by id
	var pursuing: bool = sp.temperament != _PASSIVE and (e.brain_state == State.CHASE or e.brain_state == State.RETALIATE or (e.aggro_target >= 0 and world.tick < e.aggro_until_tick))
	if not pursuing and (world.tick + e.id) % sp.think_ticks != 0:
		return
	var target: SimEntity = null
	if sp.temperament != _PASSIVE:
		target = _current_target(world, ctx, e)
		if target == null and sp.temperament == _PREDATOR:
			target = _detect_prey(world, ctx, sp, e)
			if target != null:
				e.aggro_target = target.id
				e.aggro_until_tick = world.tick + ctx.give_up_ticks
	if target != null:
		e.brain_state = State.RETALIATE if sp.temperament == _RETALIATE else State.CHASE
		_pursue(world, ctx, sp, e, target)
		return
	if sp.temperament == _PASSIVE and sp.flees:
		var away: Vector3 = _flee_vector(world, sp, e, sp.flee_radius * (sp.flee_release if e.brain_state == State.FLEE else 1.0))
		if not away.is_zero_approx():
			e.brain_state = State.FLEE
			var boost: bool = sp.boost_within > 0.0 and away.length() * sp.boost_within >= 1.0
			_steer(world, ctx, sp, e, away.normalized(), sp.speed, boost)
			return
	e.brain_state = State.WANDER
	_wander(world, ctx, sp, e)


## Idle wander of `e` (the WANDER behaviour above: home zone, hashed targets, school slot) for brains outside
## NpcBrain (BossBrain PATROL). Submits commands for world.tick; no-op without content or species record.
static func wander(world: SimWorld, e: SimEntity) -> void:
	var ctx: _Ctx = _context(world)
	var sp: _Species = ctx.species.get(e.species_id) if ctx != null else null
	if sp != null:
		_wander(world, ctx, sp, e)


## Steering for brains outside NpcBrain: MOVE toward unit `dir` at `speed` m/s (seabed / surface clearance of the
## species, thrust relative to the band max), BOOST / BRAKE on change. No-op without content or species record.
static func steer(world: SimWorld, e: SimEntity, dir: Vector3, speed: float, boost: bool = false, brake: bool = false) -> void:
	var ctx: _Ctx = _context(world)
	var sp: _Species = ctx.species.get(e.species_id) if ctx != null else null
	if sp != null:
		_steer(world, ctx, sp, e, dir, speed, boost, brake)


## Species swim speed (species swim_speed_mps), 0 without content or record.
static func species_speed(world: SimWorld, species_id: StringName) -> float:
	var ctx: _Ctx = _context(world)
	var sp: _Species = ctx.species.get(species_id) if ctx != null else null
	return sp.speed if sp != null else 0.0


## Tag (&"kelp" / &"coral") of the first map hiding volume containing `pos`, or &"" when none does.
## Broad phase: a horizontal grid (HIDE_CELL_M) holds per cell a bit mask of the volumes overlapping it in x/z
## (up to 62 volumes; more fall back to the full scan), so most positions cost one array read.
static func hiding_tag_at(world: SimWorld, pos: Vector3) -> StringName:
	var ctx: _Ctx = _context(world)
	if ctx == null:
		return &""
	if ctx.hide_n > 0:
		var ix: int = floori((pos.x - ctx.hide_origin.x) * _INV_HIDE_CELL)
		var iz: int = floori((pos.z - ctx.hide_origin.y) * _INV_HIDE_CELL)
		if ix >= 0 and iz >= 0 and ix < ctx.hide_n and iz < ctx.hide_n:
			var mask: int = ctx.hide_cells[ix * ctx.hide_n + iz]
			var i: int = 0
			while mask != 0:
				if (mask & 1) != 0 and _inside(pos, ctx.hide_min[i], ctx.hide_max[i]):
					return ctx.hide_tag[i]
				mask >>= 1
				i += 1
			return &""
	for i in ctx.hide_min.size():
		if _inside(pos, ctx.hide_min[i], ctx.hide_max[i]):
			return ctx.hide_tag[i]
	return &""


## Hiding rule for any creature (player included): sets `hidden` from the centre position and `hidden_since_tick`
## (world.tick on entering, -1 on leaving). Returns true when `hidden` changed (the caller emits HIDDEN / REVEALED).
static func update_hidden(world: SimWorld, e: SimEntity) -> bool:
	var now: bool = e.alive and hiding_tag_at(world, e.position) != &""
	if now == e.hidden:
		return false
	e.hidden = now
	e.hidden_since_tick = world.tick if now else -1
	return true


# The aggro target if it is still valid (alive creature, deadline not passed, not hidden for lose_target_s or
# longer), else clears aggro and returns null.
static func _current_target(world: SimWorld, ctx: _Ctx, e: SimEntity) -> SimEntity:
	if e.aggro_target < 0:
		return null
	var t: SimEntity = world.get_entity(e.aggro_target)
	if t == null or t == e or not _is_live_creature(t) or world.tick >= e.aggro_until_tick or _lost_in_hiding(world, ctx, t):
		e.aggro_target = -1
		e.aggro_until_tick = -1
		return null
	return t


# Hidden for lose_target_s or longer: lost to whoever chases it, and not detectable at all while it stays hidden.
static func _lost_in_hiding(world: SimWorld, ctx: _Ctx, t: SimEntity) -> bool:
	return t.hidden and world.tick - t.hidden_since_tick >= ctx.lose_ticks


# Nearest huntable creature in the detection radius (lower id on ties), or null. Hidden targets count only within
# detection_radius x detection_mult and only during their first lose_target_s in hiding.
static func _detect_prey(world: SimWorld, ctx: _Ctx, sp: _Species, e: SimEntity) -> SimEntity:
	if world.grid == null or sp.detect_radius <= 0.0:
		return null
	var r: float = sp.detect_radius
	var r_hidden: float = r * ctx.detect_mult
	var r_hidden2: float = r_hidden * r_hidden
	var max_len: float = e.length_m * ctx.hunt_ratio
	world.grid.query_radius_into(e.position, r, _ids)
	var best: SimEntity = null
	var best_d2: float = INF
	for id in _ids:
		if id == e.id:
			continue
		var t: SimEntity = world.get_entity(id)
		if t == null or not _is_live_creature(t) or t.length_m > max_len:
			continue
		if t.species_id == e.species_id and not t.is_player:
			continue
		var tsp: _Species = ctx.species.get(t.species_id)
		if tsp != null and tsp.ambient:
			continue
		var d2: float = e.position.distance_squared_to(t.position)
		if t.hidden and (d2 > r_hidden2 or _lost_in_hiding(world, ctx, t)):
			continue
		if d2 < best_d2:
			best_d2 = d2
			best = t
	return best


# Chase `t`, bite it when it touches the mouth cone, extend a predator's give-up deadline while closing in.
# Bites resolve after this tick's movement, so the cone test also tries both positions one tick ahead.
# Turn first, then dash: thrust follows how well the fish faces its target, and inside bite range a fish that
# does not face its target brakes and turns on the spot (otherwise a fast fish orbits a target that sits inside
# its turning circle, or sits on top of it with the centres swapping sides every tick).
static func _pursue(world: SimWorld, ctx: _Ctx, sp: _Species, e: SimEntity, t: SimEntity) -> void:
	var to: Vector3 = t.position - e.position
	var d2: float = to.length_squared()
	var dir: Vector3 = to / sqrt(d2) if d2 > 1e-12 else e.heading
	var reach: float = e.length_m * ctx.reach_mult + world.collision_radius(t)
	var in_range: bool = d2 <= reach * reach
	if in_range and world.tick >= e.bite_ready_tick and not SimRules.can_swallow(e.length_m, t.length_m, ctx.swallow_ratio):
		var mouth: Vector3 = e.position + e.velocity * SimWorld.TICK_DT
		var prey: Vector3 = t.position + t.velocity * SimWorld.TICK_DT
		if SimRules.in_cone(mouth, e.heading, prey, reach, ctx.cone_cos) or SimRules.in_cone(e.position, e.heading, t.position, reach, ctx.cone_cos):
			world.submit(SimCommand.bite(e.id, t.id, world.tick))
	if sp.temperament == _PREDATOR and not t.hidden and dir.dot(e.velocity - t.velocity) > 0.0:
		e.aggro_until_tick = maxi(e.aggro_until_tick, world.tick + ctx.give_up_ticks)
	var facing: float = e.heading.dot(dir)
	var brake: bool = in_range and facing < ctx.cone_cos
	var boost: bool = not brake and facing > ctx.cone_cos and sp.boost_within > 0.0 and d2 <= sp.boost_within * sp.boost_within
	_steer(world, ctx, sp, e, dir, sp.speed * clampf(facing, _MIN_TURN_THRUST, 1.0), boost, brake)


# Sum of (self - threat) / d^2 over threats in the flee radius (zero vector when there is none).
# Its length is 1 / d for a single threat, so `|away| * boost_within >= 1` means "a threat is that close".
static func _flee_vector(world: SimWorld, sp: _Species, e: SimEntity, radius: float) -> Vector3:
	var away := Vector3.ZERO
	if world.grid == null or radius <= 0.0:
		return away
	var min_len: float = e.length_m * sp.flee_ratio
	world.grid.query_radius_into(e.position, radius, _ids)
	for id in _ids:
		if id == e.id:
			continue
		var t: SimEntity = world.get_entity(id)
		# length first: in a school most neighbours are similar-sized schoolmates (same result, cheaper reject)
		if t == null or t.length_m < min_len or not _is_live_creature(t):
			continue
		if t.species_id == e.species_id and not t.is_player:
			continue
		var off: Vector3 = e.position - t.position
		var d2: float = off.length_squared()
		if d2 < 1e-12:
			off = Vector3.UP
			d2 = 1.0
		away += off / d2
	return away


# Cruise toward a hashed point near the entity, inside its home zone; back into the zone when outside it.
# A promoted school member instead follows its slot: it steers to where the slot will be follow_lookahead_s ahead,
# at the speed that gets it there in that time (capped at the species speed), so it swims with its school.
# A pack follower follows its pack leader (_follow_leader).
static func _wander(world: SimWorld, ctx: _Ctx, sp: _Species, e: SimEntity) -> void:
	if e.school_id >= 0 and world.schools != null and ctx.follow_ticks > 0:
		var sc: SchoolSystem.School = world.schools.get_school(e.school_id)
		if sc != null:
			var to: Vector3 = world.schools.member_position(sc, e.school_member, world.tick + ctx.follow_ticks) - e.position
			var d: float = to.length()
			_steer(world, ctx, sp, e, to / d if d > 1e-6 else e.heading, minf(d / ctx.follow_s, sp.speed), false)
			return
	var leader_id: int = NpcSpawner.pack_leader(world, e.id)
	if leader_id >= 0 and ctx.follow_ticks > 0:
		_follow_leader(world, ctx, sp, e, world.get_entity(leader_id), NpcSpawner.pack_radius_m(world, e.id))
		return
	var zi: int = NpcSpawner.home_zone_index(world, e.id)
	if zi < 0:
		zi = sp.zones[0] if not sp.zones.is_empty() else -1
		for z in sp.zones:
			if _inside(e.position, ctx.zone_min[z], ctx.zone_max[z]):
				zi = z
				break
	if zi < 0 or zi >= ctx.zone_min.size():
		_steer(world, ctx, sp, e, e.heading, sp.speed * sp.wander_frac, false)
		return
	var lo: Vector3 = ctx.zone_min[zi]
	var hi: Vector3 = ctx.zone_max[zi]
	var epoch: int = floori(float(world.tick + e.id * 97) / float(sp.wander_ticks))
	var p: Vector3 = e.position
	var x: float = clampf(p.x + (_hash01(e.id, epoch, 1) * 2.0 - 1.0) * sp.wander_radius, lo.x, hi.x)
	var z: float = clampf(p.z + (_hash01(e.id, epoch, 2) * 2.0 - 1.0) * sp.wander_radius, lo.z, hi.z)
	var y_lo: float = lo.y
	if world.seabed != null:
		y_lo = maxf(y_lo, world.seabed.height_at(x, z) + sp.clearance)
	var y_hi: float = minf(hi.y, -sp.clearance)
	var y: float = lerpf(y_lo, y_hi, _hash01(e.id, epoch, 3)) if y_hi > y_lo else minf(y_lo, -sp.clearance)
	var to := Vector3(x, y, z) - p
	var dir: Vector3 = to.normalized() if to.length_squared() > 1e-6 else e.heading
	_steer(world, ctx, sp, e, dir, sp.speed * sp.wander_frac, false)


# Pack follower wander: steer to a hashed slot around the leader (horizontal 0.35-0.75 x radius `r`, height +-0.25 x
# r, re-picked every wander_retarget_s) at the leader's position follow_lookahead_s ahead, at the speed that gets it
# there in that time. Capped at 2x the cruise speed while within 2 r of the leader (calm formation changes), at the
# species speed beyond (catching up after a chase).
static func _follow_leader(world: SimWorld, ctx: _Ctx, sp: _Species, e: SimEntity, leader: SimEntity, r: float) -> void:
	var epoch: int = floori(float(world.tick + e.id * 97) / float(sp.wander_ticks))
	var a: float = _hash01(e.id, epoch, 4) * TAU
	var out: float = r * (0.35 + 0.4 * _hash01(e.id, epoch, 5))
	var slot := Vector3(cos(a) * out, (_hash01(e.id, epoch, 6) - 0.5) * 0.5 * r, sin(a) * out)
	var to: Vector3 = leader.position + leader.velocity * ctx.follow_s + slot - e.position
	var d: float = to.length()
	var cap: float = sp.speed if d > 2.0 * r else minf(sp.speed, 2.0 * sp.speed * sp.wander_frac)
	_steer(world, ctx, sp, e, to / d if d > 1e-6 else e.heading, minf(d / ctx.follow_s, cap), false)


# Submits MOVE (and BOOST / BRAKE on change): `dir` bent away from the seabed and the surface, thrust = the
# wanted speed as a fraction of the band's max swim speed.
static func _steer(world: SimWorld, ctx: _Ctx, sp: _Species, e: SimEntity, dir: Vector3, speed: float, boost: bool, brake: bool = false) -> void:
	var c: float = sp.clearance
	if world.seabed != null and c > 0.0:
		var ahead: Vector3 = e.position + dir * c
		var floor_y: float = world.seabed.height_at(ahead.x, ahead.z) + c
		if ahead.y < floor_y:
			dir.y = maxf(dir.y, clampf((floor_y - ahead.y) / c, 0.0, 1.0))
		if e.position.y > -c:
			dir.y = minf(dir.y, 0.0)
		dir = dir.normalized() if not dir.is_zero_approx() else e.heading
	var band_max: float = ctx.band_speed[clampi(e.band, 1, ctx.band_speed.size() - 1)] if ctx.band_speed.size() > 1 else speed
	var thrust: float = clampf(speed / band_max, 0.0, 1.0) if band_max > 0.0 else 0.0
	world.submit(SimCommand.move(e.id, dir, thrust, world.tick))
	var want_boost: bool = boost and e.stamina > 0.0
	if want_boost != e.boosting:
		world.submit(SimCommand.boost(e.id, want_boost, world.tick))
	if brake != e.braking:
		world.submit(SimCommand.brake(e.id, brake, world.tick))


static func _is_live_creature(t: SimEntity) -> bool:
	return t.kind == SimEntity.Kind.CREATURE and t.alive and t.respawn_tick < 0


# Deterministic value in [0, 1) from (a, b, salt): splitmix64-style mixing, logical shifts emulated with masks.
static func _hash01(a: int, b: int, salt: int) -> float:
	var h: int = a * 0x632BE59BD9B4E019 + b * 0x3C6EF372FE94F82B + salt * 0x1B873593A54FF53A
	h = (h ^ ((h >> 30) & 0x3FFFFFFFF)) * 0x3F58476D1CE4E5B9
	h = (h ^ ((h >> 27) & 0x1FFFFFFFFF)) * 0x14D049BB133111EB
	h = h ^ ((h >> 31) & 0x1FFFFFFFF)
	return float(h & 0xFFFFFF) / 16777216.0


static func _context(world: SimWorld) -> _Ctx:
	var content: ContentDB = world.content
	if content == null:
		return null
	if _ctx != null and _ctx.content == content and _ctx.map_id == world.map_id:
		return _ctx
	var ctx := _Ctx.new()
	ctx.content = content
	ctx.map_id = world.map_id
	var rules: Dictionary = content.rules()
	var hiding: Dictionary = rules.get("hiding", {}) if rules.get("hiding") is Dictionary else {}
	ctx.hunt_ratio = float(rules.get("predator_hunt_ratio", 0.0))
	ctx.swallow_ratio = float(rules.get("swallow_ratio", 0.0))
	ctx.detect_mult = float(hiding.get("detection_mult", 1.0))
	ctx.lose_ticks = roundi(float(hiding.get("lose_target_s", 0.0)) * SimWorld.TICK_RATE)
	ctx.give_up_ticks = roundi(float(rules.get("predator_give_up_s", 0.0)) * SimWorld.TICK_RATE)
	ctx.reach_mult = float(rules.get("mouth_reach_mult", 0.0))
	ctx.cone_cos = cos(deg_to_rad(float(rules.get("mouth_cone_deg", 0.0))))
	var school_rules: Dictionary = rules.get("schools", {}) if rules.get("schools") is Dictionary else {}
	ctx.follow_s = float(school_rules.get("follow_lookahead_s", 0.0))
	ctx.follow_ticks = roundi(ctx.follow_s * SimWorld.TICK_RATE) if ctx.follow_s > 0.0 else 0
	ctx.band_speed = PackedFloat64Array([0.0])
	for i in range(1, content.band_count() + 1):
		ctx.band_speed.append(float(content.get_band(i).get("swim_speed_mps", 0.0)))
	var map: Dictionary = content.get_map(world.map_id)
	var zones: Array = map.get("zones", []) if map.get("zones") is Array else []
	for z in zones:
		var aabb: Dictionary = (z as Dictionary).get("aabb", {})
		ctx.zone_index[str((z as Dictionary).get("id"))] = ctx.zone_min.size()
		ctx.zone_min.append(_vec(aabb.get("min")))
		ctx.zone_max.append(_vec(aabb.get("max")))
	var volumes: Array = map.get("hiding_volumes", []) if map.get("hiding_volumes") is Array else []
	for v in volumes:
		var aabb: Dictionary = (v as Dictionary).get("aabb", {})
		ctx.hide_min.append(_vec(aabb.get("min")))
		ctx.hide_max.append(_vec(aabb.get("max")))
		ctx.hide_tag.append(StringName(str((v as Dictionary).get("tag", ""))))
	_build_hide_cells(ctx, float(map.get("size_m", 0.0)))
	for id in content.species_ids():
		ctx.species[id] = _species_from(content.get_species(id), ctx)
	_ctx = ctx
	return ctx


# Hiding broad phase over the map square (one cell of padding); left empty without a map size or with more volumes
# than a mask holds.
static func _build_hide_cells(ctx: _Ctx, size_m: float) -> void:
	if not (size_m > 0.0) or not is_finite(size_m) or ctx.hide_min.size() > _MAX_MASK_VOLUMES:
		return
	ctx.hide_n = ceili(size_m / HIDE_CELL_M) + 2
	ctx.hide_origin = Vector2(-size_m * 0.5 - HIDE_CELL_M, -size_m * 0.5 - HIDE_CELL_M)
	ctx.hide_cells.resize(ctx.hide_n * ctx.hide_n)
	ctx.hide_cells.fill(0)
	for i in ctx.hide_min.size():
		var lo: Vector3 = ctx.hide_min[i]
		var hi: Vector3 = ctx.hide_max[i]
		var x0: int = clampi(floori((lo.x - ctx.hide_origin.x) * _INV_HIDE_CELL), 0, ctx.hide_n - 1)
		var x1: int = clampi(floori((hi.x - ctx.hide_origin.x) * _INV_HIDE_CELL), 0, ctx.hide_n - 1)
		var z0: int = clampi(floori((lo.z - ctx.hide_origin.y) * _INV_HIDE_CELL), 0, ctx.hide_n - 1)
		var z1: int = clampi(floori((hi.z - ctx.hide_origin.y) * _INV_HIDE_CELL), 0, ctx.hide_n - 1)
		for ix in range(x0, x1 + 1):
			for iz in range(z0, z1 + 1):
				ctx.hide_cells[ix * ctx.hide_n + iz] |= 1 << i


static func _species_from(rec: Dictionary, ctx: _Ctx) -> _Species:
	var sp := _Species.new()
	sp.temperament = ["predator", "retaliate", "passive"].find(str(rec.get("temperament", "passive")))
	sp.ambient = str(rec.get("tier", "")) == "ambient"
	sp.speed = float(rec.get("swim_speed_mps", 0.0))
	sp.detect_radius = float(rec.get("detection_radius_m", 0.0))
	sp.flee_radius = float(rec.get("flee_radius_m", 0.0))
	var b: Dictionary = rec.get("behaviour", {}) if rec.get("behaviour") is Dictionary else {}
	sp.flees = bool(b.get("flees", false))
	sp.flee_ratio = float(b.get("flee_min_length_ratio", 1.0))
	sp.flee_release = float(b.get("flee_release_mult", 1.0))
	sp.boost_within = float(b.get("boost_within_m", 0.0))
	sp.wander_frac = float(b.get("wander_speed_frac", 0.0))
	sp.wander_radius = float(b.get("wander_radius_m", 0.0))
	sp.wander_ticks = maxi(roundi(float(b.get("wander_retarget_s", 1.0)) * SimWorld.TICK_RATE), 1)
	sp.think_ticks = maxi(int(b.get("think_interval_ticks", 1)), 1)
	sp.clearance = float(b.get("seabed_clearance_m", 0.0))
	var zones: Array = rec.get("zones", []) if rec.get("zones") is Array else []
	for z in zones:
		if ctx.zone_index.has(str(z)):
			sp.zones.append(int(ctx.zone_index[str(z)]))
	return sp


static func _inside(p: Vector3, lo: Vector3, hi: Vector3) -> bool:
	return p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y and p.z >= lo.z and p.z <= hi.z


static func _vec(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
