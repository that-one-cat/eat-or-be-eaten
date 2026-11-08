class_name TierManager
extends RefCounted
## Promotion / demotion between the ambient school form and interactive SimEntities (CLAUDE.md rule 4).
## SimWorld.step() runs tick() as the schools phase (after the spawners) while the NPC population is enabled
## (NpcSpawner.set_enabled). Numbers: rules `tiers`.
##
## Every tick: due school respawns (SchoolSystem.tick_respawns). Then the schools with
## id % update_every_ticks == tick % update_every_ticks are scanned (staggered), ascending school id:
##  - demotion, member k ascending: a promoted member that has been interactive for >= min_interactive_s, whose
##    nearest living player is farther than demote_radius_m, that is not fleeing (brain state FLEE), not aggressive
##    (aggro_target with a running deadline) and not the running aggro target of another creature, is demoted:
##    SCHOOL_MEMBER_DEMOTED, its entity is removed (no DIED) and the member is back in the school form.
##  - promotion candidates: members in the school form within promote_radius_m of the nearest living player (the
##    school is skipped when its bounding sphere is out of reach of every player).
## Candidates are promoted nearest-first (distance quantised to BUCKET_M; ties by school id, then k) while the
## interactive tier has room: room = interactive_cap - promoted - max(other interactive NPCs alive, interactive
## spawner targets), so spawner respawns never push the tier over the cap. A promoted member is spawned at its sim
## slot with the school heading and velocity (move intent = the school motion until its brain thinks) and
## SCHOOL_MEMBER_PROMOTED is emitted. Distances are squared, players only (dead players excluded).

## Distance quantum of the nearest-first promotion order, metres.
const BUCKET_M: float = 0.5

var interactive_cap: int = 0
var promote_radius_m: float = 0.0
var demote_radius_m: float = 0.0
var min_interactive_ticks: int = 0
var update_every_ticks: int = 1

var _players := PackedVector3Array()
var _near := PackedVector3Array()
var _cand := PackedInt64Array()
var _targets: Dictionary[int, bool] = {}
var _targets_tick: int = -1


## Reads rules `tiers` (missing keys: no cap, nothing promoted).
static func create(content: ContentDB) -> TierManager:
	var t := TierManager.new()
	var rules: Dictionary = content.rules().get("tiers", {}) if content != null and content.rules().get("tiers") is Dictionary else {}
	t.interactive_cap = int(rules.get("interactive_cap", 0))
	t.promote_radius_m = float(rules.get("promote_radius_m", 0.0))
	t.demote_radius_m = maxf(float(rules.get("demote_radius_m", 0.0)), t.promote_radius_m)  # validated: > promote
	t.min_interactive_ticks = roundi(float(rules.get("min_interactive_s", 0.0)) * SimWorld.TICK_RATE)
	t.update_every_ticks = maxi(int(rules.get("update_every_ticks", 1)), 1)
	return t


## The schools phase of SimWorld.step() (see the class doc).
func tick(world: SimWorld) -> void:
	var schools: SchoolSystem = world.schools
	if schools == null or schools.school_count() == 0:
		return
	schools.tick_respawns(world)
	world.player_positions_into(_players)
	var now: int = world.tick
	var phase: int = now % update_every_ticks
	var promote2: float = promote_radius_m * promote_radius_m
	var demote2: float = demote_radius_m * demote_radius_m
	_cand.clear()
	for id in range(phase, schools.school_count(), update_every_ticks):
		var sc: SchoolSystem.School = schools.get_school(id)
		if not sc.promoted.is_empty():
			_demote_scan(world, schools, sc, now, demote2)
		if promote_radius_m <= 0.0:
			continue
		var c: Vector3 = schools.center_at(sc, now)
		var reach: float = promote_radius_m + sc.bound_m
		_near.clear()
		for p in _players:
			if p.distance_squared_to(c) <= reach * reach:
				_near.append(p)
		if _near.is_empty():
			continue
		for k in sc.size:
			if sc.alive[k] == 0:
				continue
			var d2: float = _nearest_d2(_near, schools.member_position(sc, k, now))
			if d2 <= promote2:
				_cand.append((floori(sqrt(d2) / BUCKET_M) << 40) | (id << 20) | k)
	if _cand.is_empty():
		return
	_cand.sort()
	var others: int = world.npc_count(SimWorld.TIER_INTERACTIVE) - schools.promoted_count()
	var room: int = interactive_cap - schools.promoted_count() - maxi(others, NpcSpawner.target_total(world, SimWorld.TIER_INTERACTIVE))
	for key in _cand:
		if room <= 0:
			break
		_promote(world, schools, schools.get_school((key >> 20) & 0xFFFFF), key & 0xFFFFF, now)
		room -= 1


func _demote_scan(world: SimWorld, schools: SchoolSystem, sc: SchoolSystem.School, now: int, demote2: float) -> void:
	var keys: Array = sc.promoted.keys()
	keys.sort()
	for k: int in keys:
		var e: SimEntity = world.get_entity(sc.promoted[k])
		if e == null or e.school_id != sc.id:
			continue
		if now - e.school_since_tick < min_interactive_ticks or _nearest_d2(_players, e.position) <= demote2:
			continue
		if _busy(world, e, now):
			continue
		var ev: SimEvent = world.emit_event(SimEvent.Type.SCHOOL_MEMBER_DEMOTED, e.id)
		ev.data = {"school": sc.id, "k": k}
		e.school_id = -1
		e.school_member = -1
		world.remove_entity(e.id)
		schools.apply_event(ev)


# Fleeing, aggressive, or the running aggro target of any creature (built once per tick when first needed).
func _busy(world: SimWorld, e: SimEntity, now: int) -> bool:
	if e.brain_state == NpcBrain.State.FLEE or (e.aggro_target >= 0 and now < e.aggro_until_tick):
		return true
	if _targets_tick != now:
		_targets_tick = now
		_targets.clear()
		for id in world.entity_ids():
			var c: SimEntity = world.get_entity(id)
			if c.aggro_target >= 0 and now < c.aggro_until_tick:
				_targets[c.aggro_target] = true
	return _targets.has(e.id)


func _promote(world: SimWorld, schools: SchoolSystem, sc: SchoolSystem.School, k: int, now: int) -> void:
	var heading: Vector3 = schools.heading_at(sc, now)
	var id: int = NpcSpawner.spawn_npc(world, sc.species_id, schools.member_position(sc, k, now), schools.member_length(sc, k), heading)
	var e: SimEntity = world.get_entity(id)
	e.school_id = sc.id
	e.school_member = k
	e.school_since_tick = now
	e.velocity = schools.velocity_at(sc, now)
	e.speed = e.velocity.length()
	e.move_dir = heading
	e.move_thrust = clampf(e.speed / maxf(world.band_swim_speed(e.band), 1e-6), 0.0, 1.0)
	var ev: SimEvent = world.emit_event(SimEvent.Type.SCHOOL_MEMBER_PROMOTED, id)
	ev.data = {"school": sc.id, "k": k, "entity": id}
	schools.apply_event(ev)


static func _nearest_d2(points: PackedVector3Array, p: Vector3) -> float:
	var best: float = INF
	for q in points:
		var d2: float = q.distance_squared_to(p)
		if d2 < best:
			best = d2
	return best
