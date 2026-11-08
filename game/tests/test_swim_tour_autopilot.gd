extends TestCase
## SwimTourAutopilot bookkeeping and command contract (the full tour runs in res://tests/scenarios/swim_tour.tscn).

const SEED: int = 1103

var _content: ContentDB


func before_each() -> void:
	if _content == null:
		_content = ContentDB.load_from_dir()


func _setup() -> Array:
	var w := SimWorld.new(SEED, _content)
	var id: int = w.spawn_player(0)
	return [w, id, SwimTourAutopilot.new(w, id)]


func test_zones_at_uses_the_map_aabbs_inclusively() -> void:
	var map: Dictionary = {"zones": [
		{"id": "a", "aabb": {"min": [0, -10, 0], "max": [10, 0, 10]}},
		{"id": "b", "aabb": {"min": [5, -20, 5], "max": [20, -5, 20]}},
	]}
	assert_eq(SwimTourAutopilot.zones_at(map, Vector3(1, -1, 1)), PackedStringArray(["a"]))
	assert_eq(SwimTourAutopilot.zones_at(map, Vector3(7, -7, 7)), PackedStringArray(["a", "b"]))
	assert_eq(SwimTourAutopilot.zones_at(map, Vector3(10, -5, 10)), PackedStringArray(["a", "b"]), "bounds inclusive")
	assert_eq(SwimTourAutopilot.zones_at(map, Vector3(30, -7, 7)), PackedStringArray())
	assert_eq(SwimTourAutopilot.zones_at({}, Vector3.ZERO), PackedStringArray(), "no zones")


func test_zones_visited_keeps_first_visit_order_without_duplicates() -> void:
	var s: Array = _setup()
	var w: SimWorld = s[0]
	var e: SimEntity = w.get_entity(s[1])
	var ap: SwimTourAutopilot = s[2]
	var points: Array[Vector3] = [e.position, Vector3(0, -30, -60), e.position, Vector3(0, -70, 250), Vector3(0, -30, -60)]
	for p in points:
		e.position = p  # bookkeeping only reads the position; no step in between
		ap.next_commands()
	var visited: PackedStringArray = ap.zones_visited()
	assert_true(visited.find("shallows") >= 0 and visited.find("shallows") < visited.find("kelp_forest"), str(visited))
	assert_true(visited.find("kelp_forest") < visited.find("abyss"), str(visited))
	for id in visited:
		assert_eq(visited.count(id), 1, "duplicate %s in %s" % [id, visited])
	assert_eq(ap.elapsed_ticks(), points.size())


func test_commands_target_the_current_tick_and_use_only_move_boost_brake() -> void:
	var s: Array = _setup()
	var w: SimWorld = s[0]
	var ap: SwimTourAutopilot = s[2]
	var allowed: Array = [SimCommand.Type.MOVE, SimCommand.Type.BOOST, SimCommand.Type.BRAKE]
	for i in 120:
		var moves: int = 0
		for c in ap.next_commands():
			assert_eq(c.tick, w.tick)
			assert_eq(c.entity_id, s[1])
			assert_has(allowed, c.type)
			if c.type == SimCommand.Type.MOVE:
				moves += 1
				assert_almost_eq(c.dir.length(), 1.0, 1e-4, "unit aim")
		assert_eq(moves, 1, "one MOVE per tick")
		w.step()


func test_route_covers_every_route_zone_and_returns_to_the_start() -> void:
	var s: Array = _setup()
	var w: SimWorld = s[0]
	var ap: SwimTourAutopilot = s[2]
	var wps: PackedVector3Array = ap.waypoints()
	assert_true(wps.size() > SwimTourAutopilot.ROUTE.size())
	assert_true(wps[wps.size() - 1].is_equal_approx(w.get_entity(s[1]).position), "ends at the start point")
	for zone in SwimTourAutopilot.ROUTE:
		var hit: bool = false
		for p in wps:
			hit = hit or SwimTourAutopilot.zones_at(w.map, p).has(zone)
		assert_true(hit, "no waypoint inside %s" % zone)
	assert_true(ap.route_length_m() > 0.0)


func test_autopilot_is_deterministic() -> void:
	var hashes: Array[int] = []
	for run in 2:
		var s: Array = _setup()
		var w: SimWorld = s[0]
		var ap: SwimTourAutopilot = s[2]
		for i in 600:
			for c in ap.next_commands():
				w.submit(c)
			w.step()
		hashes.append(w.state_hash())
	assert_eq(hashes[0], hashes[1])
