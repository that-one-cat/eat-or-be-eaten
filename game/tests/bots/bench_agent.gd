extends RefCounted
## Bench player-agent (S4 bench_sim): one simulated player that keeps the sim busy the way a real player does
## (swims with a school so its members get promoted, grazes plankton on the way) and eats only when the bench
## grants it an eat token, so the bench can pace the eat-event rate (tune the agents, never the sim).
## Talks to the sim through SimCommands only (rule 2) and reads state like a presentation layer; deterministic
## (own SimRng, ascending-id grid queries, ties to the lower id). commands() once per tick before SimWorld.step(),
## observe() with that step's events.
##
## Patrol (no token): follows its school at ORBIT_M from the centre (outside the school, so it does not swallow
## or chase members by accident), circling it slowly; agents without a school (or whose school is far after a
## respawn) swim seeded waypoints inside their zone box. Boosts to catch up when far behind.
## Hunt (token, grant()): the nearest passive creature or food bit it can eat within SIGHT_M: bites a creature it
## cannot swallow until it dies, then swallows the remains bits. The token ends when nothing edible is in sight
## after a swallow, or after HUNT_TIMEOUT_TICKS.

const SIGHT_M: float = 20.0
const ORBIT_M: float = 12.0
## Orbit angular speed around the school centre (rad/s).
const ORBIT_RATE: float = 0.12
## Farther than this from the orbit point: boost (stamina allowing).
const CATCH_UP_M: float = 20.0
const BOOST_MIN_STAMINA: float = 30.0
const ARRIVE_M: float = 4.0
const WAYPOINT_TIMEOUT_TICKS: int = 600
const HUNT_TIMEOUT_TICKS: int = 300
const RETARGET_TICKS: int = 15
## Clearance above the seabed / below the surface and lookahead for terrain following.
const CLEARANCE_M: float = 1.5
const LOOKAHEAD_M: float = 3.0
## Waypoints keep |x| <= this (well inside the map's soft-current margin).
const X_LIMIT_M: float = 200.0

## Eat token held, and whether this hunt has eaten something yet.
var hunting: bool = false
var ate_this_hunt: bool = false
## EATEN events this agent caused (it was the eater).
var eaten: int = 0
var tokens: int = 0
var id: int = 0

var _w: SimWorld
var _rng: SimRng
var _school: SchoolSystem.School = null
var _lo: Vector3
var _hi: Vector3
var _orbit_phase: float = 0.0
var _swallow_ratio: float = 0.1
var _reach_mult: float = 0.8
var _cos_half: float = 0.7
var _passive: Dictionary = {}  # species id -> true for passive, non-ambient species
var _buf: PackedInt32Array = PackedInt32Array()
var _target: int = -1
var _target_tick: int = 0
var _hunt_since: int = 0
var _wp: Vector3 = Vector3.ZERO
var _wp_since: int = -1
var _boosting: bool = false


## `school` may be null (waypoint patrol); `zone_lo` / `zone_hi` = the agent's zone box.
func _init(world: SimWorld, player_id: int, school: SchoolSystem.School, zone_lo: Vector3, zone_hi: Vector3, seed: int) -> void:
	_w = world
	id = player_id
	_school = school
	_lo = zone_lo
	_hi = zone_hi
	_rng = SimRng.new(seed * 6151 + 29)
	_orbit_phase = _rng.range_float(0.0, TAU)
	var r: Dictionary = world.content.rules()
	_swallow_ratio = float(r.get("swallow_ratio", _swallow_ratio))
	_reach_mult = float(r.get("mouth_reach_mult", _reach_mult))
	_cos_half = cos(deg_to_rad(float(r.get("mouth_cone_deg", 45.0))))
	for sid in world.content.species_ids():
		var rec: Dictionary = world.content.get_species(sid)
		if String(rec.get("temperament", "")) == "passive" and String(rec.get("tier", "")) != "ambient":
			_passive[sid] = true


## Where the agent wants to be at the start (orbit point of its school at tick 0, else a waypoint in the zone).
func start_position() -> Vector3:
	if _school != null:
		return _lift(_orbit_point(0))
	_pick_waypoint()
	return _wp


func alive() -> bool:
	var e: SimEntity = _w.get_entity(id)
	return e != null and e.alive


## Gives the agent an eat token.
func grant() -> void:
	hunting = true
	tokens += 1
	_hunt_since = _w.tick
	ate_this_hunt = false
	_target = -1


## Something edible within SIGHT_M (the bench only grants tokens to agents that can use them).
func sees_prey() -> bool:
	var e: SimEntity = _w.get_entity(id)
	return e != null and e.alive and _pick_prey(e) >= 0


func commands() -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	var e: SimEntity = _w.get_entity(id)
	if e == null or not e.alive:
		_target = -1
		_boosting = false
		return out
	var t: int = _w.tick
	if hunting and t - _hunt_since > HUNT_TIMEOUT_TICKS:
		hunting = false
	if hunting:
		if _target >= 0 and not _edible_alive(_target):
			_target = -1
		if _target < 0 or t - _target_tick >= RETARGET_TICKS:
			_target = _pick_prey(e)
			_target_tick = t
		if _target < 0:
			if ate_this_hunt:
				hunting = false
		else:
			_hunt(out, e)
			return out
	_patrol(out, e)
	return out


func observe(events: Array[SimEvent]) -> void:
	for ev in events:
		if ev.type == SimEvent.Type.EATEN and ev.other_id == id:
			eaten += 1
			ate_this_hunt = true


# ------------------------------------------------------------------ behaviour

func _patrol(out: Array[SimCommand], e: SimEntity) -> void:
	var aim: Vector3
	if _school != null and e.position.distance_to(_w.schools.center_at(_school, _w.tick)) < 120.0:
		aim = _lift(_orbit_point(_w.tick))
	else:
		if _wp_since < 0 or e.position.distance_to(_wp) <= ARRIVE_M or _w.tick - _wp_since > WAYPOINT_TIMEOUT_TICKS:
			_pick_waypoint()
		aim = _wp
	var d: float = e.position.distance_to(aim)
	var thrust: float = clampf(d / 6.0, 0.2, 1.0)
	_steer(out, e, aim, thrust, d > CATCH_UP_M and e.stamina > BOOST_MIN_STAMINA)


func _hunt(out: Array[SimCommand], e: SimEntity) -> void:
	var c: SimEntity = _w.get_entity(_target)
	var to: Vector3 = c.position - e.position
	var d: float = to.length()
	var reach: float = e.length_m * _reach_mult
	var band_speed: float = maxf(_w.band_swim_speed(e.band), 0.1)
	var dir: Vector3 = to / d if d > 1e-6 else e.heading
	var facing: float = clampf(e.heading.dot(dir), 0.1, 1.0)
	if not _swallowable(e, c):
		var bite_reach: float = reach + _w.collision_radius(c)
		if _w.tick >= e.bite_ready_tick and SimRules.in_cone(e.position, e.heading, c.position, bite_reach, _cos_half):
			out.append(SimCommand.bite(id, c.id, _w.tick))
		reach = bite_reach
	# slow down near the target so the mouth does not skip over it between two ticks
	var speed: float = minf(band_speed, c.speed + maxf(reach * SimWorld.TICK_RATE * 0.4, d * 2.0))
	_steer(out, e, c.position, speed / band_speed * facing, d > 6.0 and facing > 0.9 and e.stamina > BOOST_MIN_STAMINA)


# Nearest edible thing within SIGHT_M: food bits and passive creatures it can swallow or bite (no players).
func _pick_prey(e: SimEntity) -> int:
	_w.grid.query_radius_into(e.position, SIGHT_M, _buf)
	var best: int = -1
	var best_d2: float = INF
	for tid in _buf:
		if tid == id:
			continue
		var c: SimEntity = _w.get_entity(tid)
		if c == null or not c.alive or c.is_player:
			continue
		if c.kind == SimEntity.Kind.CREATURE and not _passive.has(c.species_id):
			continue
		if c.kind == SimEntity.Kind.FOOD_BIT and not _swallowable(e, c):
			continue
		var d2: float = e.position.distance_squared_to(c.position)
		if d2 < best_d2:
			best_d2 = d2
			best = tid
	return best


func _edible_alive(tid: int) -> bool:
	var c: SimEntity = _w.get_entity(tid)
	return c != null and c.alive


func _swallowable(e: SimEntity, c: SimEntity) -> bool:
	var len_c: float = c.length_m if c.kind == SimEntity.Kind.FOOD_BIT else _w.effective_length(c)
	return SimRules.can_swallow(e.length_m, len_c, _swallow_ratio)


func _orbit_point(at_tick: int) -> Vector3:
	var a: float = _orbit_phase + ORBIT_RATE * float(at_tick) / float(SimWorld.TICK_RATE)
	return _w.schools.center_at(_school, at_tick) + Vector3(cos(a), 0.0, sin(a)) * ORBIT_M


func _pick_waypoint() -> void:
	_wp_since = _w.tick
	var x: float = _rng.range_float(maxf(_lo.x, -X_LIMIT_M), minf(_hi.x, X_LIMIT_M))
	var z: float = _rng.range_float(_lo.z, _hi.z)
	var y_lo: float = _lo.y
	if _w.seabed != null:
		y_lo = maxf(y_lo, _w.seabed.height_at(x, z) + CLEARANCE_M * 2.0)
	var y_hi: float = minf(_hi.y, -CLEARANCE_M * 2.0)
	_wp = Vector3(x, _rng.range_float(y_lo, y_hi) if y_hi > y_lo else y_hi, z)


# Keeps a point between the seabed (+ clearance) and the surface.
func _lift(p: Vector3) -> Vector3:
	var top: float = -CLEARANCE_M * 2.0
	var y: float = minf(p.y, top)
	if _w.seabed != null:
		y = maxf(y, minf(_w.seabed.height_at(p.x, p.z) + CLEARANCE_M * 2.0, top))
	return Vector3(p.x, y, p.z)


# MOVE toward `aim` (lifted over the seabed ahead, kept below the surface), BOOST on change.
func _steer(out: Array[SimCommand], e: SimEntity, aim: Vector3, thrust: float, boost: bool) -> void:
	var p: Vector3 = e.position
	var to: Vector3 = aim - p
	var dir: Vector3 = to.normalized() if to.length_squared() > 1e-10 else e.heading
	if _w.seabed != null:
		var ahead: Vector3 = p + dir * LOOKAHEAD_M
		var floor_y: float = _w.seabed.height_at(ahead.x, ahead.z) + CLEARANCE_M + _w.collision_radius(e)
		if ahead.y < floor_y:
			dir.y = maxf(dir.y, clampf((floor_y - ahead.y) / LOOKAHEAD_M, 0.0, 1.0))
		if p.y > -CLEARANCE_M:
			dir.y = minf(dir.y, 0.0)
		dir = dir.normalized() if not dir.is_zero_approx() else e.heading
	out.append(SimCommand.move(id, dir, clampf(thrust, 0.0, 1.0), _w.tick))
	var want: bool = boost and e.stamina > 0.0
	if want != _boosting:
		_boosting = want
		out.append(SimCommand.boost(id, want, _w.tick))
