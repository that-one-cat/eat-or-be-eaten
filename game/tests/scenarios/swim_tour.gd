extends Node
## S2 acceptance scenario (headless): godot --headless --path game res://tests/scenarios/swim_tour.tscn
## Builds ContentDB + SimWorld (no other nodes), spawns the player and lets SwimTourAutopilot swim the tour with
## SimWorld.step(), recording every command. Prints one "SWIM_TOUR <criterion>: PASS|FAIL ..." line per criterion
## and a summary "SWIM_TOUR: PASS|FAIL ...", then quits with 0 (all pass) or 1.
## Criteria:
## - route: every ROUTE zone visited in order (zone membership from the map AABBs), the arch passed under both
##   ways, the tour finished with the final position in the shallows near the spawn point;
## - depth: max depth >= MIN_ABYSS_DEPTH_M;
## - bounds: every tick |x|, |z| <= size/2, y <= -radius, y >= height_at + radius - 1e-3, all finite;
## - stuck: never STALL_TICKS ticks in a row with thrust > 0 and a displacement < STALL_MIN_M;
## - time: sim time <= budget = route length / (band-1 swim speed * boost speed_mult) * BUDGET_FACTOR +
##   BUDGET_SLACK_S, and the whole scenario <= WALL_BUDGET_S of wall-clock time;
## - framerate: the recorded commands replayed through advance() with 1/30 s, 1/120 s and an irregular delta
##   sequence of the same total time end at the reference position within FPS_TOLERANCE_M and with the same
##   state_hash().

const WORLD_SEED: int = 1103
const SPAWN_INDEX: int = 0
const MIN_ABYSS_DEPTH_M: float = 70.0
const STALL_TICKS: int = 90
const STALL_MIN_M: float = 0.5
const FLOOR_EPS_M: float = 1e-3
const BUDGET_FACTOR: float = 2.0
const BUDGET_SLACK_S: float = 30.0
const WALL_BUDGET_S: float = 60.0
const FPS_TOLERANCE_M: float = 0.001
## The final position must be this close to the spawn point.
const HOME_RADIUS_M: float = 6.0
## SimWorld.advance() accumulator unit: one tick = 1_000_000 units (see sim_world.gd).
const UNITS_PER_TICK: int = 1000000
const UNITS_PER_SECOND: float = float(SimWorld.TICK_RATE * UNITS_PER_TICK)

var _all_ok: bool = true


func _ready() -> void:
	_run()
	get_tree().quit(0 if _all_ok else 1)


func _run() -> void:
	var wall0: int = Time.get_ticks_msec()
	var content: ContentDB = ContentDB.load_from_dir()
	if not content.is_valid():
		_report("setup", false, "content invalid: %s" % "; ".join(content.errors))
		_summary("setup failed")
		return
	var world := SimWorld.new(WORLD_SEED, content)
	var id: int = world.spawn_player(SPAWN_INDEX)
	var e: SimEntity = world.get_entity(id)
	var map: Dictionary = world.map
	var ap := SwimTourAutopilot.new(world, id)
	var start: Vector3 = e.position
	var half: float = float(map.get("size_m", 0.0)) * 0.5
	var band: Dictionary = content.get_band(1)
	var boost_mult: float = float(content.get_ability(&"boost").get("speed_mult", 1.0))
	var top_speed: float = float(band.get("swim_speed_mps", 1.0)) * boost_mult
	var route_m: float = ap.route_length_m()
	var budget_s: float = route_m / top_speed * BUDGET_FACTOR + BUDGET_SLACK_S
	var max_ticks: int = ceili(budget_s * 2.0 * SimWorld.TICK_RATE)

	var recorded: Array[SimCommand] = []
	var distance: float = 0.0
	var max_depth: float = -start.y
	var bounds_error: String = ""
	var stall_tick: int = -1
	var thrust_run: int = 0
	var longest_thrust_window_min_m: float = INF
	var hist := PackedVector3Array()
	hist.resize(STALL_TICKS + 1)
	hist[0] = start
	while not ap.is_finished() and world.tick < max_ticks:
		for c in ap.next_commands():
			world.submit(c)
			recorded.append(c)
		var before: Vector3 = e.position
		world.step()
		var p: Vector3 = e.position
		distance += before.distance_to(p)
		max_depth = maxf(max_depth, -p.y)
		if bounds_error.is_empty():
			bounds_error = _bounds_problem(world, e, half)
			if not bounds_error.is_empty():
				bounds_error = "tick %d: %s" % [world.tick, bounds_error]
		hist[world.tick % (STALL_TICKS + 1)] = p
		thrust_run = thrust_run + 1 if e.move_thrust > 0.0 else 0
		if thrust_run >= STALL_TICKS:
			var moved: float = p.distance_to(hist[(world.tick - STALL_TICKS) % (STALL_TICKS + 1)])
			longest_thrust_window_min_m = minf(longest_thrust_window_min_m, moved)
			if moved < STALL_MIN_M and stall_tick < 0:
				stall_tick = world.tick
	var ticks: int = world.tick
	var sim_s: float = float(ticks) / SimWorld.TICK_RATE
	var end_pos: Vector3 = e.position
	var ref_hash: int = world.state_hash()

	# route
	var visited: PackedStringArray = ap.zones_visited()
	var order_ok: bool = _in_order(visited, SwimTourAutopilot.ROUTE)
	var final_zones: PackedStringArray = SwimTourAutopilot.zones_at(map, end_pos)
	var home_m: float = end_pos.distance_to(start)
	var route_ok: bool = ap.is_finished() and order_ok and ap.arch_passes() >= 2 and final_zones.has("shallows") and home_m <= HOME_RADIUS_M
	_report("route", route_ok, "finished=%s visited=%s in_order=%s arch_passes=%d final_zones=%s home=%.2f m (<= %.1f)" % [
		ap.is_finished(), ">".join(visited), order_ok, ap.arch_passes(), ",".join(final_zones), home_m, HOME_RADIUS_M])
	_report("depth", max_depth >= MIN_ABYSS_DEPTH_M, "max_depth=%.2f m (>= %.1f)" % [max_depth, MIN_ABYSS_DEPTH_M])
	_report("bounds", bounds_error.is_empty(), "ok over %d ticks" % ticks if bounds_error.is_empty() else bounds_error)
	_report("stuck", stall_tick < 0, "min displacement over any %d-tick thrust window=%.2f m (>= %.1f)%s" % [
		STALL_TICKS, longest_thrust_window_min_m, STALL_MIN_M, "" if stall_tick < 0 else " stalled at tick %d" % stall_tick])

	# frame-rate independence
	var fps_ok: bool = true
	var fps_info: PackedStringArray = PackedStringArray()
	var sequences: Dictionary = {
		"dt1/30": _fixed_units(ticks, UNITS_PER_TICK),
		"dt1/120": _fixed_units(ticks, UNITS_PER_TICK / 4),
		"irregular": _irregular_units(ticks),
	}
	for seq_name: String in sequences:
		var r: Dictionary = _replay(content, recorded, ticks, sequences[seq_name])
		var err: float = (r["pos"] as Vector3).distance_to(end_pos)
		var same: bool = r["tick"] == ticks and err <= FPS_TOLERANCE_M and r["hash"] == ref_hash
		fps_ok = fps_ok and same
		fps_info.append("%s: frames=%d end=%s err=%.6f m hash=%s" % [
			seq_name, (sequences[seq_name] as PackedInt64Array).size(), _v(r["pos"]), err, "same" if r["hash"] == ref_hash else "DIFF"])
	_report("framerate", fps_ok, "ref end=%s tol=%.3f m; %s" % [_v(end_pos), FPS_TOLERANCE_M, "; ".join(fps_info)])

	var wall_s: float = float(Time.get_ticks_msec() - wall0) / 1000.0
	var time_ok: bool = ap.is_finished() and sim_s <= budget_s and wall_s <= WALL_BUDGET_S
	_report("time", time_ok, "sim=%.1f s budget=%.1f s (route %.1f m / %.2f m/s * %.1f + %.0f s) wall=%.2f s (<= %.0f)" % [
		sim_s, budget_s, route_m, top_speed, BUDGET_FACTOR, BUDGET_SLACK_S, wall_s, WALL_BUDGET_S])

	var hit: int = 0
	for z in SwimTourAutopilot.ROUTE:
		if visited.has(z):
			hit += 1
	_summary("zones=%d/%d ticks=%d sim=%.1f s distance=%.1f m max_depth=%.2f m budget=%.1f s commands=%d" % [
		hit, SwimTourAutopilot.ROUTE.size(), ticks, sim_s, distance, max_depth, budget_s, recorded.size()])


func _bounds_problem(world: SimWorld, e: SimEntity, half: float) -> String:
	var p: Vector3 = e.position
	if not (p.is_finite() and e.velocity.is_finite() and e.heading.is_finite()):
		return "non-finite state pos=%s vel=%s heading=%s" % [p, e.velocity, e.heading]
	var r: float = world.collision_radius(e)
	if absf(p.x) > half or absf(p.z) > half:
		return "outside the map box: %s" % _v(p)
	if p.y > -r + 1e-6:
		return "above the ceiling: y=%.4f radius=%.4f" % [p.y, r]
	var floor_y: float = world.seabed.height_at(p.x, p.z) + r - FLOOR_EPS_M
	if p.y < floor_y:
		return "below the seabed: y=%.4f floor=%.4f at %s" % [p.y, floor_y, _v(p)]
	return ""


# Replays `recorded` (explicit ticks) on a fresh world through advance() with the given frame deltas (units).
# Commands are submitted just ahead of the ticks a frame can run, so the queue stays short.
func _replay(content: ContentDB, recorded: Array[SimCommand], ticks: int, units: PackedInt64Array) -> Dictionary:
	var w := SimWorld.new(WORLD_SEED, content)
	var id: int = w.spawn_player(SPAWN_INDEX)
	var next: int = 0
	for u in units:
		var horizon: int = w.tick + int(u / UNITS_PER_TICK) + 2
		while next < recorded.size() and recorded[next].tick < horizon:
			w.submit(recorded[next])
			next += 1
		w.advance(float(u) / UNITS_PER_SECOND)
	return {"tick": w.tick, "pos": w.get_entity(id).position, "hash": w.state_hash()}


static func _fixed_units(ticks: int, per_frame: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var total: int = ticks * UNITS_PER_TICK
	while total > 0:
		out.append(mini(per_frame, total))
		total -= per_frame
	return out


# Deterministic irregular frame times: 1/240 .. 1/16 s from an LCG, a 0.25 s hitch every 97th frame, the last
# frame trimmed so the sum is exactly `ticks` ticks.
static func _irregular_units(ticks: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var total: int = ticks * UNITS_PER_TICK
	var state: int = 1103
	var frame: int = 0
	while total > 0:
		state = (state * 1103515245 + 12345) & 0x7FFFFFFF
		var u: int = 125000 + state % 1750000
		frame += 1
		if frame % 97 == 0:
			u = 7500000
		u = mini(u, total)
		out.append(u)
		total -= u
	return out


# True when `required` appears in `seen` in the same relative order (other ids may be interleaved).
static func _in_order(seen: PackedStringArray, required: PackedStringArray) -> bool:
	var last: int = -1
	for id in required:
		var i: int = seen.find(id)
		if i < 0 or i < last:
			return false
		last = i
	return true


static func _v(p: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [p.x, p.y, p.z]


func _report(criterion: String, ok: bool, info: String) -> void:
	_all_ok = _all_ok and ok
	print("SWIM_TOUR %s: %s %s" % [criterion, "PASS" if ok else "FAIL", info])


func _summary(info: String) -> void:
	print("SWIM_TOUR: %s %s" % ["PASS" if _all_ok else "FAIL", info])
