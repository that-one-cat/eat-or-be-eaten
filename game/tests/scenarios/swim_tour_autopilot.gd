class_name SwimTourAutopilot
extends RefCounted
## Deterministic closed-loop autopilot for the S2 acceptance tour:
## spawn -> shallows -> kelp_forest -> under a rock arch -> sunken_boat -> cliff_edge -> abyss, then the same
## waypoints in reverse back to the spawn point, where it brakes to rest.
## Waypoints come from map data only (zone AABBs, arch obstacles, SeabedField heights); no coordinates are
## hard-coded. Each call reads the entity state and returns the commands for exactly the current tick
## (explicit `tick`, so the list can be recorded and replayed with any frame pacing). Only MOVE / BOOST / BRAKE
## are used, the fish is never teleported, and there is no RNG.
## next_commands() must be called exactly once per sim tick, before SimWorld.step().

## Route zone ids, in visiting order (coordinates come from the map).
const ROUTE: PackedStringArray = ["shallows", "kelp_forest", "rock_arches", "sunken_boat", "cliff_edge", "abyss"]
## In this zone the route passes under an arch (obstacle tag "arch": the horizontal capsule is the lintel).
const ARCH_ZONE: String = "rock_arches"
const ARCH_TAG: String = "arch"
## Zone waypoint: the previous waypoint clamped into the zone shrunk by these margins, at seabed + CLEARANCE_M.
const ZONE_MARGIN_XZ_M: float = 8.0
const ZONE_MARGIN_Y_M: float = 3.0
const CLEARANCE_M: float = 3.0
## Zone waypoints are pushed out of obstacles and the seabed by this radius (small, so they stay in the zone).
const WAYPOINT_RADIUS_M: float = 1.0
## Waypoints before / after the arch, along its passage axis.
const ARCH_APPROACH_M: float = 15.0
## A waypoint counts as reached inside this distance.
const ARRIVE_RADIUS_M: float = 3.0
## Terrain following: the aim is raised when the seabed ahead (lookahead = max(MIN, speed * LOOKAHEAD_S))
## comes closer than FOLLOW_CLEARANCE_M.
const LOOKAHEAD_S: float = 1.5
const MIN_LOOKAHEAD_M: float = 6.0
const FOLLOW_CLEARANCE_M: float = 2.0
## The tour is finished once the fish has braked below this speed at the last waypoint.
const REST_SPEED_MPS: float = 0.05

var _world: SimWorld
var _id: int = 0
var _seabed: SeabedField = null
var _start: Vector3 = Vector3.ZERO
var _stamina_max: float = 0.0
var _wps: PackedVector3Array = PackedVector3Array()
var _wp: int = 0
var _ticks: int = 0
var _stopping: bool = false
var _finished: bool = false
var _visited: PackedStringArray = PackedStringArray()
# chosen arch: centre of the lintel, horizontal passage axis, half of the free gap, lintel underside
var _arch_found: bool = false
var _arch_c: Vector3 = Vector3.ZERO
var _arch_perp: Vector3 = Vector3.ZERO
var _arch_axis: Vector3 = Vector3.ZERO
var _arch_half_gap: float = 0.0
var _arch_bottom: float = 0.0
var _arch_passes: int = 0
var _prev_pos: Vector3 = Vector3.ZERO


func _init(world: SimWorld, entity_id: int) -> void:
	_world = world
	_id = entity_id
	_seabed = world.seabed
	var e: SimEntity = world.get_entity(entity_id)
	if e == null or _seabed == null:
		_finished = true
		return
	_start = e.position
	_prev_pos = _start
	if world.content != null:
		_stamina_max = float(world.content.get_ability(&"boost").get("stamina_max", 0.0))
	_build_route(world.map)


## Commands for the current tick (world.tick). Empty once finished.
func next_commands() -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	var e: SimEntity = _world.get_entity(_id)
	if _finished or e == null:
		return out
	var t: int = _world.tick
	var pos: Vector3 = e.position
	_ticks += 1
	_track(pos)
	var last: int = _wps.size() - 1
	while _wp < last and pos.distance_to(_wps[_wp]) <= ARRIVE_RADIUS_M:
		_wp += 1
	if _wp == last and pos.distance_to(_wps[last]) <= ARRIVE_RADIUS_M:
		_stopping = true
	if _stopping:
		if e.boosting:
			out.append(SimCommand.boost(_id, false, t))
		if not e.braking:
			out.append(SimCommand.brake(_id, true, t))
		out.append(SimCommand.move(_id, e.heading, 0.0, t))
		if e.speed < REST_SPEED_MPS:
			_finished = true
		return out
	out.append(SimCommand.move(_id, _aim(e, _wps[_wp]), 1.0, t))
	# boost whenever stamina is full; the sim stops the boost at 0 stamina
	if not e.boosting and _stamina_max > 0.0 and e.stamina >= _stamina_max:
		out.append(SimCommand.boost(_id, true, t))
	return out


func is_finished() -> bool:
	return _finished


## Zone ids in the order of first visit (each id once), from the positions seen by next_commands().
func zones_visited() -> PackedStringArray:
	return _visited


## Ticks driven so far (calls of next_commands() that returned commands).
func elapsed_ticks() -> int:
	return _ticks


## The full route: outbound zone waypoints, the reverse leg and the start point last.
func waypoints() -> PackedVector3Array:
	return _wps


## Length of the polyline start -> waypoints, metres.
func route_length_m() -> float:
	var total: float = 0.0
	var prev: Vector3 = _start
	for p in _wps:
		total += prev.distance_to(p)
		prev = p
	return total


## How many times the fish crossed the chosen arch's plane between the pillars and below the lintel.
func arch_passes() -> int:
	return _arch_passes


## Zone ids (map order) whose AABB contains `p`, bounds inclusive.
static func zones_at(map: Dictionary, p: Vector3) -> PackedStringArray:
	var out := PackedStringArray()
	var zones: Array = map.get("zones", []) if map.get("zones") is Array else []
	for z: Variant in zones:
		if not (z is Dictionary and (z as Dictionary).get("aabb") is Dictionary):
			continue
		var aabb: Dictionary = z["aabb"]
		var lo: Vector3 = _vec3(aabb.get("min"))
		var hi: Vector3 = _vec3(aabb.get("max"))
		if p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y and p.z >= lo.z and p.z <= hi.z:
			out.append(str(z.get("id", "")))
	return out


func _track(pos: Vector3) -> void:
	for id in zones_at(_world.map, pos):
		if not _visited.has(id):
			_visited.append(id)
	if _arch_found:
		var s0: float = (_prev_pos - _arch_c).dot(_arch_perp)
		var s1: float = (pos - _arch_c).dot(_arch_perp)
		if (s0 < 0.0) != (s1 < 0.0):
			var lateral: float = absf((pos - _arch_c).dot(_arch_axis))
			if lateral < _arch_half_gap and pos.y < _arch_bottom:
				_arch_passes += 1
	_prev_pos = pos


# Heads for `target`; raises the aim when the seabed half-way or at the lookahead point is too close.
func _aim(e: SimEntity, target: Vector3) -> Vector3:
	var to: Vector3 = target - e.position
	var dist: float = to.length()
	if dist < 1e-6:
		return e.heading
	var dir: Vector3 = to / dist
	var look: float = maxf(MIN_LOOKAHEAD_M, e.speed * LOOKAHEAD_S)
	if dist <= look:
		return dir
	var lift: Vector3 = Vector3.ZERO
	var need: float = 0.0
	for f: float in [0.5, 1.0]:
		var ahead: Vector3 = e.position + dir * (look * f)
		var floor_y: float = _seabed.height_at(ahead.x, ahead.z) + FOLLOW_CLEARANCE_M
		if floor_y - ahead.y > need:
			need = floor_y - ahead.y
			lift = Vector3(ahead.x, floor_y, ahead.z)
	if need > 0.0:
		dir = (lift - e.position).normalized()
	return dir


func _build_route(map: Dictionary) -> void:
	var zones: Dictionary = {}
	var list: Array = map.get("zones", []) if map.get("zones") is Array else []
	for z: Variant in list:
		if z is Dictionary and (z as Dictionary).get("aabb") is Dictionary:
			var aabb: Dictionary = z["aabb"]
			zones[str(z.get("id", ""))] = AABB(_vec3(aabb.get("min")), _vec3(aabb.get("max")) - _vec3(aabb.get("min")))
	var out := PackedVector3Array()
	var prev: Vector3 = _start
	for i in ROUTE.size():
		var id: String = ROUTE[i]
		if not zones.has(id):
			push_warning("SwimTourAutopilot: route zone '%s' missing in map" % id)
			continue
		var box: AABB = zones[id]
		if id == ARCH_ZONE:
			var hint: Vector3 = prev
			if i + 1 < ROUTE.size() and zones.has(ROUTE[i + 1]):
				hint = (zones[ROUTE[i + 1]] as AABB).get_center()
			if _pick_arch(box, prev, hint):
				var entry: Vector3 = _arch_c - _arch_perp * ARCH_APPROACH_M
				var exit: Vector3 = _arch_c + _arch_perp * ARCH_APPROACH_M
				entry.y = maxf(entry.y, _seabed.height_at(entry.x, entry.z) + CLEARANCE_M)
				exit.y = maxf(exit.y, _seabed.height_at(exit.x, exit.z) + CLEARANCE_M)
				out.append(entry)
				out.append(exit)
				prev = exit
				continue
		var p: Vector3 = _zone_point(box, prev)
		out.append(p)
		prev = p
	# return leg: the outbound waypoints in reverse (passes the arch again), then the start point
	for i in range(out.size() - 2, -1, -1):
		out.append(out[i])
	out.append(_start)
	_wps = out


# The point of `box` (shrunk by the margins) nearest to `prev` in XZ, CLEARANCE_M above the seabed and inside the
# zone's depth range where possible, then pushed out of obstacles by WAYPOINT_RADIUS_M.
func _zone_point(box: AABB, prev: Vector3) -> Vector3:
	var lo: Vector3 = box.position
	var hi: Vector3 = box.end
	var x: float = _clamp_inner(prev.x, lo.x, hi.x, ZONE_MARGIN_XZ_M)
	var z: float = _clamp_inner(prev.z, lo.z, hi.z, ZONE_MARGIN_XZ_M)
	var h: float = _seabed.height_at(x, z)
	var y: float = _clamp_inner(h + CLEARANCE_M, lo.y, hi.y, ZONE_MARGIN_Y_M)
	y = minf(maxf(y, h + 1.0), -1.0)
	return _seabed.resolve(Vector3(x, y, z), WAYPOINT_RADIUS_M)


# Picks the arch lintel inside `box` with the shortest detour prev -> arch -> hint; sets the _arch_* fields.
func _pick_arch(box: AABB, prev: Vector3, hint: Vector3) -> bool:
	var best: float = INF
	for o: Dictionary in _seabed.obstacles():
		if o.get("tag", "") != ARCH_TAG or o.get("kind", "") != "capsule":
			continue
		var a: Vector3 = o["a"]
		var b: Vector3 = o["b"]
		var span := Vector3(b.x - a.x, 0.0, b.z - a.z)
		if absf(a.y - b.y) > 0.01 or span.length_squared() < 1e-6:
			continue  # pillars are vertical; the lintel is the horizontal capsule
		var c: Vector3 = (a + b) * 0.5
		if c.x < box.position.x or c.x > box.end.x or c.z < box.position.z or c.z > box.end.z:
			continue
		var cost: float = prev.distance_to(c) + c.distance_to(hint)
		if cost >= best:
			continue
		best = cost
		var r: float = float(o["radius"])
		_arch_axis = span.normalized()
		_arch_perp = _arch_axis.cross(Vector3.UP).normalized()
		_arch_half_gap = span.length() * 0.5 - r
		_arch_bottom = c.y - r
		var floor_y: float = _seabed.height_at(c.x, c.z)
		_arch_c = Vector3(c.x, (floor_y + _arch_bottom) * 0.5, c.z)
		if (prev - _arch_c).dot(_arch_perp) > 0.0:
			_arch_perp = -_arch_perp
	_arch_found = best < INF
	return _arch_found


static func _clamp_inner(v: float, lo: float, hi: float, margin: float) -> float:
	if hi - lo < 2.0 * margin:
		return (lo + hi) * 0.5
	return clampf(v, lo + margin, hi - margin)


static func _vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
