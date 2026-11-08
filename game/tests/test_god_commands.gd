extends TestCase
## T1.2 console commands (GodSimCommands through the GodCommands registry), the aim point (GodAim), DevOverlays,
## GodScript (parse + run on a real host) and the GameLoop time-scale hook. Every command is exercised on a real
## SimWorld through a GodContext (no host, no console), answers are asserted as text.

const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const ROCK_CENTRE: Vector3 = Vector3(20.0, -46.51, 100.0)

var _nodes: Array[Node] = []
var _cmds: GodCommands = null


func before_each() -> void:
	_cmds = GodCommands.with_builtins()
	GodSimCommands.register_all(_cmds)


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	(Engine.get_main_loop() as SceneTree).paused = false


func _adopt(n: Node) -> void:
	(Engine.get_main_loop() as SceneTree).root.add_child(n)
	_nodes.append(n)
	await (Engine.get_main_loop() as SceneTree).process_frame


## {"w", "p", "id", "ctx", "run"}: controlled world + player + a GodContext whose run node is in the tree.
func _rig(world_seed: int = 1) -> Dictionary:
	var rg: Dictionary = G.rig(world_seed)
	var run := Node3D.new()
	await _adopt(run)
	rg["run"] = run
	rg["ctx"] = G.context(rg["w"], rg["id"], run)
	return rg


func _x(rg: Dictionary, line: String) -> String:
	return _cmds.execute(line, rg["ctx"])


# ---------------------------------------------------------------- registry coverage

func test_register_all_registers_the_documented_commands() -> void:
	for n: String in ["tp", "places", "band", "xp", "heal", "spawn", "food", "despawn", "god", "hunger", "speed", "noclip", "event", "overlay", "boss"]:
		assert_true(_cmds.has_command(StringName(n)), "registered: %s" % n)
		assert_has(_cmds.help_text(), n, "help lists %s" % n)
		assert_has(_cmds.help_text(n), "usage", "%s has a usage line" % n)


func test_every_command_without_a_run_answers_and_does_not_crash() -> void:
	var ctx := GodContext.new()
	for n: String in _cmds.names():
		if n in ["clear", "close", "menu"]:
			continue
		for line: String in [n, n + " 1", n + " a b c", n + " on", n + " \"\""]:
			var out: String = _cmds.execute(line, ctx)
			if n == "help":
				continue
			assert_false(out.is_empty(), "'%s' with no run answers something" % line)


func test_every_command_with_garbage_args_survives_a_live_run() -> void:
	var rg: Dictionary = await _rig(2)
	for n: String in _cmds.names():
		if n in ["clear", "close", "menu", "boss"]:
			continue
		for args: String in ["", "zzz", "-1", "1e99", "nan", "inf", "'", "a b c d e f", "999999999999"]:
			_x(rg, "%s %s" % [n, args])  # a script error here fails the test through the runner's logger
	assert_true(rg["w"].get_entity(rg["id"]) != null, "world still sane")


# ---------------------------------------------------------------- tp / places

func test_tp_to_a_named_place() -> void:
	var rg: Dictionary = await _rig()
	var out: String = _x(rg, "tp cave")
	assert_has(out, "teleported to cave", out)
	assert_true((rg["p"] as SimEntity).position.distance_to(Vector3(-20, -41, 52)) < 0.5, "player at the cave: %s" % (rg["p"] as SimEntity).position)


func test_tp_is_case_insensitive_and_covers_every_place() -> void:
	var rg: Dictionary = await _rig()
	for place: Dictionary in GodSimCommands.places(rg["w"]):
		var out: String = _x(rg, "TP %s" % String(place["id"]).to_upper())
		assert_has(out, "teleported", "%s: %s" % [place["id"], out])


func test_tp_to_coordinates() -> void:
	var rg: Dictionary = await _rig()
	var out: String = _x(rg, "tp -10 -20 -78")
	assert_has(out, "teleported", out)
	assert_true((rg["p"] as SimEntity).position.distance_to(Vector3(-10, -20, -78)) < 0.5, "at the coordinates")
	var buried: String = _x(rg, "tp 10 -30 -100")  # inside the seabed: resolved upwards, the answer reports the real position
	assert_has(buried, "now at (10.0, -24", buried)


func test_tp_unknown_place_changes_nothing_and_lists_places() -> void:
	var rg: Dictionary = await _rig()
	var before: Vector3 = (rg["p"] as SimEntity).position
	var out: String = _x(rg, "tp atlantis")
	assert_has(out, "unknown place 'atlantis'", out)
	assert_has(out, "cave", "the listing follows")
	assert_eq((rg["p"] as SimEntity).position, before, "no move")


func test_tp_bad_arguments_print_usage_without_moving() -> void:
	var rg: Dictionary = await _rig()
	var before: Vector3 = (rg["p"] as SimEntity).position
	for line: String in ["tp 1 2", "tp a b c", "tp 1 2 3 4"]:
		assert_has(_x(rg, line), "usage", line)
	assert_has(_x(rg, "tp"), "usage", "tp with no argument")
	assert_eq((rg["p"] as SimEntity).position, before, "nothing moved")


func test_tp_list_and_places_commands() -> void:
	var rg: Dictionary = await _rig()
	for line: String in ["tp list", "places"]:
		var out: String = _x(rg, line)
		for id: String in ["spawn_0", "shallows", "kelp", "arches", "cave", "boat", "cliff", "abyss", "boss"]:
			assert_has(out, id, "%s lists %s" % [line, id])


func test_tp_with_a_dead_player_is_refused() -> void:
	var rg: Dictionary = await _rig()
	(rg["p"] as SimEntity).alive = false
	assert_has(_x(rg, "tp cave"), "cannot teleport", "dead player message")


func test_tp_into_a_rock_reports_the_resolved_position() -> void:
	var rg: Dictionary = await _rig()
	var out: String = _x(rg, "tp %f %f %f" % [ROCK_CENTRE.x, ROCK_CENTRE.y, ROCK_CENTRE.z])
	assert_has(out, "now at", out)
	assert_true((rg["p"] as SimEntity).position.distance_to(ROCK_CENTRE) >= 3.99, "pushed out of the rock")


# ---------------------------------------------------------------- band / xp / heal

func test_band_command_requests_a_band_and_applies_next_tick() -> void:
	var rg: Dictionary = await _rig()
	var out: String = _x(rg, "band 3")
	assert_has(out, "band 3 requested", out)
	S3.step_n(rg["w"], 2)
	assert_eq((rg["p"] as SimEntity).band, 3, "applied by the sim")


func test_band_command_clamps_and_validates() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "band 99"), "clamped", "99 clamps with a note")
	assert_has(_x(rg, "band"), "usage", "no argument")
	assert_has(_x(rg, "band x"), "usage", "not a number")
	assert_has(_x(rg, "band 1 2"), "usage", "too many arguments")


func test_band_command_notes_a_pending_pick() -> void:
	var rg: Dictionary = await _rig(5)
	_x(rg, "band 2")
	S3.step_n(rg["w"], 3)
	assert_true((rg["w"] as SimWorld).paused_for_pick, "test setup: pick pending")
	assert_has(_x(rg, "band 3"), "mutation pick is pending", "the answer warns about the pending pick")


func test_xp_command() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "xp 123"), "XP set to 123", "ok")
	assert_eq((rg["p"] as SimEntity).xp, 123.0, "written")
	assert_has(_x(rg, "xp"), "usage", "missing")
	assert_has(_x(rg, "xp abc"), "usage", "bad")
	assert_has(_x(rg, "xp inf"), "usage", "infinite")


func test_heal_command() -> void:
	var rg: Dictionary = await _rig()
	(rg["p"] as SimEntity).hp = 0.1
	assert_has(_x(rg, "heal"), "HP refilled", "ok")
	assert_eq((rg["p"] as SimEntity).hp, (rg["p"] as SimEntity).max_hp, "full")
	(rg["p"] as SimEntity).alive = false
	assert_has(_x(rg, "heal"), "cannot heal", "dead")


# ---------------------------------------------------------------- spawn / food / despawn

func test_spawn_without_arguments_lists_species() -> void:
	var rg: Dictionary = await _rig()
	var out: String = _x(rg, "spawn")
	for sid: String in ["shark", "puffer", "grouper", "barracuda"]:
		assert_has(out, sid, "lists %s" % sid)
	assert_false(out.contains("plankton"), "ambient species are not offered")


func test_spawn_puts_a_creature_at_the_aim_point() -> void:
	var rg: Dictionary = await _rig(7)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	p.heading = Vector3.RIGHT
	SimDebug.teleport(w, p.id, S3.ARENA)
	var n0: int = w.entity_count()
	var out: String = _x(rg, "spawn shark")
	assert_has(out, "spawned shark #", out)
	assert_eq(w.entity_count(), n0 + 1, "one entity added")
	var aim: Vector3 = (rg["ctx"] as GodContext).aim_point()
	var shark: SimEntity = null
	for id: int in w.entity_ids():
		if w.get_entity(id).species_id == &"shark":
			shark = w.get_entity(id)
	assert_not_null(shark, "found it")
	if shark != null:
		assert_true(shark.position.distance_to(aim) < 1.0, "at the aim point (%s vs %s)" % [shark.position, aim])
		assert_true(shark.position.x > p.position.x, "in front of a +X-facing player")
		assert_true(shark.heading.dot(p.position - shark.position) > 0.0, "faces the player")


func test_spawn_with_length_and_bad_input() -> void:
	var rg: Dictionary = await _rig(8)
	assert_has(_x(rg, "spawn puffer 0.45"), "0.45 m", "explicit length honoured")
	assert_has(_x(rg, "spawn puffer -1"), "usage", "negative length")
	assert_has(_x(rg, "spawn puffer abc"), "usage", "text length")
	assert_has(_x(rg, "spawn kraken"), "cannot spawn: unknown species", "unknown species")
	assert_has(_x(rg, "spawn plankton"), "cannot spawn", "ambient species")
	assert_has(_x(rg, "SPAWN Shark"), "spawned shark", "case-insensitive species")


func test_spawn_second_boss_is_refused_through_the_command() -> void:
	var rg: Dictionary = await _rig(9)
	var w: SimWorld = rg["w"]
	SimDebug.teleport(w, rg["id"], S6.abyss_spot(w))
	assert_has(_x(rg, "spawn giant_shark"), "spawned giant_shark", "first boss")
	var boss: int = w.boss_id()
	assert_true(boss >= 0, "boss registered")
	assert_has(_x(rg, "spawn giant_shark"), "boss is already alive", "second refused")
	assert_eq(w.boss_id(), boss, "the first boss is untouched")


func test_spawn_with_a_dead_player_is_refused() -> void:
	var rg: Dictionary = await _rig(10)
	(rg["p"] as SimEntity).alive = false
	assert_has(_x(rg, "spawn puffer"), "player is dead", "message")


func test_food_command() -> void:
	var rg: Dictionary = await _rig(11)
	var w: SimWorld = rg["w"]
	assert_has(_x(rg, "food"), "spawned 5 food bits", "default 5")
	assert_eq(S3.food_bits(w).size(), 5, "five entities")
	assert_has(_x(rg, "food 3"), "spawned 3 food bits", "explicit count")
	assert_has(_x(rg, "food 1000"), "spawned 64 food bits", "clamped to 64")
	assert_has(_x(rg, "food 0"), "usage", "zero")
	assert_has(_x(rg, "food x"), "usage", "text")


func test_despawn_command() -> void:
	var rg: Dictionary = await _rig(12)
	_x(rg, "spawn puffer")
	_x(rg, "food 2")
	assert_has(_x(rg, "despawn"), "removed 3 debug spawns", "puffer + 2 bits")
	assert_has(_x(rg, "despawn"), "removed 0", "idempotent")


# ---------------------------------------------------------------- flag commands

func test_god_hunger_noclip_toggle_and_set() -> void:
	var rg: Dictionary = await _rig()
	var w: SimWorld = rg["w"]
	var cases: Array[Array] = [["god", "god mode"], ["hunger", "hunger lock"], ["noclip", "noclip"]]
	for c: Array in cases:
		var cmd: String = c[0]
		assert_has(_x(rg, cmd), "ON", "%s: no argument turns it on" % cmd)
		assert_has(_x(rg, cmd), "off", "%s: toggles back" % cmd)
		assert_has(_x(rg, "%s on" % cmd), "ON", "%s on" % cmd)
		assert_has(_x(rg, "%s ON" % cmd), "ON", "%s ON is idempotent / case-insensitive" % cmd)
		assert_has(_x(rg, "%s off" % cmd), "off", "%s off" % cmd)
		assert_has(_x(rg, "%s maybe" % cmd), "usage", "%s with garbage" % cmd)
		for word: String in ["1", "true", "yes"]:
			assert_has(_x(rg, "%s %s" % [cmd, word]), "ON", "%s %s" % [cmd, word])
		for word: String in ["0", "false", "no"]:
			assert_has(_x(rg, "%s %s" % [cmd, word]), "off", "%s %s" % [cmd, word])
	assert_false(w.debug.god or w.debug.hunger_lock or w.debug.noclip, "all flags ended off")


func test_god_command_really_blocks_death() -> void:
	var rg: Dictionary = await _rig(13)
	_x(rg, "god on")
	(rg["p"] as SimEntity).hp = 0.0
	S3.step_n(rg["w"], 3)
	assert_eq((rg["p"] as SimEntity).deaths, 0, "the command-enabled god mode works through the sim")


func test_speed_command() -> void:
	var rg: Dictionary = await _rig()
	var w: SimWorld = rg["w"]
	assert_has(_x(rg, "speed"), "x1", "status without argument")
	assert_has(_x(rg, "speed 2"), "x2", "set")
	assert_eq(w.debug.time_scale, 2.0, "stored")
	assert_has(_x(rg, "speed 100"), "clamped", "clamped with a note")
	assert_eq(w.debug.time_scale, SimDebug.TIME_SCALE_MAX, "stored clamped")
	assert_has(_x(rg, "speed 0"), "clamped", "0 clamps to the min, not a freeze")
	assert_eq(w.debug.time_scale, SimDebug.TIME_SCALE_MIN, "min")
	assert_has(_x(rg, "speed fast"), "usage", "text")
	assert_has(_x(rg, "speed 1 2"), "usage", "extra argument")
	assert_has(_x(rg, "speed nan"), "usage", "nan")


# ---------------------------------------------------------------- event stub

func test_event_command_is_a_stub_with_a_clear_message() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "event"), "no event scheduler yet (T6.1)", "no argument")
	assert_has(_x(rg, "event trigger boss_wave"), "no event scheduler yet (T6.1)", "trigger")
	assert_has(_x(rg, "event trigger boss_wave"), "boss_wave", "names the requested id")
	assert_has(_x(rg, "event trigger"), "no event scheduler yet (T6.1)", "trigger without id does not crash")


func test_event_list_summarises_recent_events() -> void:
	var rg: Dictionary = await _rig()
	var quiet: String = _x(rg, "event list")
	assert_has(quiet, "no event scheduler yet", "stub text present")
	assert_has(quiet, "events of the last 90 ticks", "window stated")
	assert_false(quiet.contains("BAND_UP"), "no band-up yet")
	SimDebug.set_band(rg["w"], rg["id"], 2)
	S3.step_n(rg["w"], 2)
	var busy: String = _x(rg, "event list")
	assert_has(busy, "BAND_UP x1", "the band-up event is counted: %s" % busy)


# ---------------------------------------------------------------- boss

func test_boss_command_without_a_boss() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "boss"), "no boss alive", "status")
	for sub: String in ["tp", "stun", "heal", "hp 5"]:
		assert_has(_x(rg, "boss " + sub), "no boss alive", "boss %s" % sub)


func test_boss_command_with_a_boss() -> void:
	var rg: Dictionary = S6.boss_rig(91, 60.0, S6.mid_xp(S6.make_world(91).content, 4), {"vitals": true})
	if rg.is_empty():
		fail("test setup: no abyss spot")
		return
	var run := Node3D.new()
	await _adopt(run)
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	rg["ctx"] = G.context(w, p.id, run)
	assert_has(_x(rg, "boss"), "boss giant_shark", "status names the boss")
	assert_has(_x(rg, "boss tp"), "teleported", "tp")
	assert_true(absf(p.position.distance_to(boss.position) - GodSimCommands.BOSS_TP_DISTANCE_M) < 3.0, "player ~%.0f m from the boss (is %.1f)" % [GodSimCommands.BOSS_TP_DISTANCE_M, p.position.distance_to(boss.position)])
	assert_has(_x(rg, "boss hp 123"), "boss HP set to 123", "hp")
	assert_eq(boss.hp, 123.0, "written")
	assert_has(_x(rg, "boss hp"), "usage", "hp without value")
	assert_has(_x(rg, "boss heal"), "refilled", "heal")
	assert_eq(boss.hp, boss.max_hp, "full")
	assert_has(_x(rg, "boss stun"), "stunned", "stun")
	assert_eq(boss.hp, 0.0, "hp zero")
	assert_has(_x(rg, "boss dance"), "usage", "unknown sub-command")
	var t0: int = w.tick
	assert_has(_x(rg, "boss win"), "victory forced", "win")
	assert_has(_x(rg, "boss win"), "already won", "win twice")
	var victories: int = 0
	for ev: SimEvent in w.events_since(t0):
		if ev.type == SimEvent.Type.VICTORY:
			victories += 1
	assert_eq(victories, 1, "one VICTORY")


func test_boss_win_works_without_a_boss() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "boss win"), "victory forced", "win does not need a live boss")
	assert_true((rg["w"] as SimWorld).run_won, "run_won")


# ---------------------------------------------------------------- overlays

func test_overlay_listing_and_unknown_name() -> void:
	var rg: Dictionary = await _rig()
	assert_eq((rg["run"] as Node).get_child_count(), 0, "no overlay node before the first use")
	var out: String = _x(rg, "overlay list")
	for n: String in DevOverlays.names():
		assert_has(out, "%s: off" % n, "%s listed off" % n)
	assert_has(_x(rg, "overlay"), "usage", "no argument")
	assert_has(_x(rg, "overlay lasers"), "unknown overlay 'lasers'", "unknown name")
	assert_has(_x(rg, "overlay zones maybe"), "usage", "bad flag")


func test_overlay_zones_builds_a_mesh_and_off_hides_it() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "overlay zones on"), "overlay zones: on", "on")
	var ov: DevOverlays = (rg["ctx"] as GodContext).overlays()
	assert_not_null(ov, "node exists")
	assert_true(ov.vertex_count("zones") > 0, "zones mesh is non-empty (%d vertices)" % ov.vertex_count("zones"))
	assert_eq(ov.vertex_count("zones") % 24, 0, "24 line vertices per zone box")
	assert_has(_x(rg, "overlay zones"), "overlay zones: off", "no flag toggles")
	assert_eq(ov.vertex_count("zones"), 0, "off: nothing drawn")
	assert_false(ov.is_enabled("zones"), "flag off")
	assert_has(_x(rg, "overlay list"), "zones: off", "listing agrees")


func test_overlay_grid_and_detect_draw_only_while_on_and_process_only_then() -> void:
	var rg: Dictionary = await _rig(3)
	var w: SimWorld = rg["w"]
	SimDebug.teleport(w, rg["id"], S3.ARENA)
	var npc: SimEntity = S3.npc_at(w, &"shark", S3.ARENA + Vector3(8, 0, 0))
	assert_not_null(npc, "an NPC in range of the detect rings")
	_x(rg, "overlay grid on")
	_x(rg, "overlay detect on")
	var ov: DevOverlays = (rg["ctx"] as GodContext).overlays()
	assert_true(ov.is_processing(), "processing while grid / detect are on")
	for i: int in DevOverlays.DETECT_EVERY_FRAMES + 3:
		await (Engine.get_main_loop() as SceneTree).process_frame
	assert_true(ov.vertex_count("grid") > 0, "grid lattice drawn (%d)" % ov.vertex_count("grid"))
	assert_true(ov.vertex_count("detect") > 0, "detection rings drawn for the nearby NPC (%d)" % ov.vertex_count("detect"))
	_x(rg, "overlay grid off")
	_x(rg, "overlay detect off")
	assert_false(ov.is_processing(), "no per-frame work once both are off")
	assert_eq(ov.vertex_count("grid") + ov.vertex_count("detect"), 0, "nothing drawn")


func test_overlay_obstacles_unavailable_on_a_plain_map_node() -> void:
	var rg: Dictionary = await _rig()
	assert_has(_x(rg, "overlay obstacles on"), "not available", "a node without set_obstacles_visible")


func test_overlay_obstacles_delegates_to_the_map_root() -> void:
	var rg: Dictionary = await _rig()
	var script := GDScript.new()
	script.source_code = "extends Node3D\nvar shown: bool = false\nfunc set_obstacles_visible(on: bool) -> void:\n\tshown = on\n"
	assert_eq(script.reload(), OK, "stub script compiles")
	var map_root := Node3D.new()
	map_root.set_script(script)
	await _adopt(map_root)
	(rg["ctx"] as GodContext).run = map_root
	assert_has(_x(rg, "overlay obstacles on"), "overlay obstacles: on", "delegated on")
	assert_true(map_root.get("shown"), "the map root was told to show its obstacles")
	assert_has(_x(rg, "overlay obstacles off"), "overlay obstacles: off", "delegated off")
	assert_false(map_root.get("shown"), "and to hide them")


func test_overlays_do_not_change_the_sim() -> void:
	var a: Dictionary = await _rig(14)
	var b: Dictionary = await _rig(14)
	_x(a, "overlay zones on")
	_x(a, "overlay grid on")
	_x(a, "overlay detect on")
	S3.step_n(a["w"], 120)
	S3.step_n(b["w"], 120)
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "overlays are presentation only (rule 1)")


# ---------------------------------------------------------------- quick buttons

func test_quick_lines_cover_places_bands_species_and_overlays() -> void:
	var rg: Dictionary = await _rig()
	var lines: PackedStringArray = _cmds.quick_lines(rg["ctx"])
	for want: String in ["tp cave", "tp boss", "band 1", "band 4", "heal", "god", "noclip", "speed 0.5", "spawn shark", "food", "despawn", "overlay zones", "boss tp", "boss win", "event list"]:
		assert_has(lines, want, "quick line '%s'" % want)
	assert_false(lines.has("spawn plankton"), "no ambient species buttons")
	for line: String in lines:
		var out: String = _cmds.execute(line, rg["ctx"])
		assert_false(out.begins_with("unknown command"), "every quick line is a real command: %s" % line)
	assert_eq(GodSimCommands.quick_lines(GodContext.new()).size(), 0, "no run: no buttons")


# ---------------------------------------------------------------- GodAim

func test_aim_point_open_water_travels_the_reach() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.teleport(w, p.id, S3.ARENA)
	var aim: Vector3 = GodAim.aim_point(w, p, Vector3.RIGHT)
	var reach: float = GodAim.reach_m(p.length_m)
	assert_true(aim.distance_to(p.position) <= reach + 1e-3, "never beyond the reach")
	assert_true(aim.distance_to(p.position) >= reach - reach / float(GodAim.MARCH_STEPS) - 1e-3, "free water: within one march step of the reach (%.2f / %.2f)" % [aim.distance_to(p.position), reach])
	assert_true(absf((aim - p.position).normalized().dot(Vector3.RIGHT) - 1.0) < 1e-4, "along the aim direction")


func test_aim_point_reach_is_clamped() -> void:
	assert_eq(GodAim.reach_m(0.01), GodAim.MIN_REACH_M, "tiny fish: minimum")
	assert_eq(GodAim.reach_m(100.0), GodAim.MAX_REACH_M, "giant: maximum")
	assert_almost_eq(GodAim.reach_m(1.0), GodAim.REACH_LENGTHS, 1e-6, "in between: 12 lengths")


func test_aim_point_stops_before_the_seabed() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var floor_y: float = w.seabed.height_at(S3.ARENA.x, S3.ARENA.z)
	SimDebug.teleport(w, p.id, Vector3(S3.ARENA.x, floor_y + 4.0, S3.ARENA.z))
	p.length_m = 5.0  # reach 40 m: the downward ray certainly hits the floor
	var aim: Vector3 = GodAim.aim_point(w, p, Vector3.DOWN)
	assert_true(aim.y >= w.seabed.height_at(aim.x, aim.z) + GodAim.CLEARANCE_M - 1e-3, "result is above the seabed (y %.2f, floor %.2f)" % [aim.y, w.seabed.height_at(aim.x, aim.z)])
	assert_true(aim.distance_to(p.position) < 40.0, "stopped early")


func test_aim_point_stops_before_the_surface_and_before_a_rock() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.teleport(w, p.id, Vector3(0, -2.0, -250))
	p.length_m = 5.0
	var up: Vector3 = GodAim.aim_point(w, p, Vector3.UP)
	assert_true(up.y <= -GodAim.CLEARANCE_M, "never above the surface (y %.2f)" % up.y)
	SimDebug.teleport(w, p.id, ROCK_CENTRE + Vector3(-12, 0, 0))
	p.length_m = 5.0
	var toward: Vector3 = GodAim.aim_point(w, p, Vector3.RIGHT)
	assert_true(toward.distance_to(ROCK_CENTRE) >= 4.0, "the point is outside the rock (%.2f m from its centre)" % toward.distance_to(ROCK_CENTRE))
	assert_true(toward.x < ROCK_CENTRE.x, "and before it on the ray")


func test_aim_point_zero_or_bad_direction_falls_back_to_the_heading() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.teleport(w, p.id, S3.ARENA)
	p.heading = Vector3.BACK
	for bad: Vector3 in [Vector3.ZERO, Vector3(NAN, 0, 0), Vector3(INF, 0, 0)]:
		var aim: Vector3 = GodAim.aim_point(w, p, bad)
		assert_true(aim.is_finite(), "finite result for %s" % bad)
		assert_true(aim.z > p.position.z, "along the heading (+Z) for %s" % bad)


# ---------------------------------------------------------------- GodScript.parse

func test_script_parse_skips_comments_and_blank_lines() -> void:
	var steps: Array[Dictionary] = GodScript.parse("# header\n\n   \ntp cave  # inline\n#tail\n")
	assert_eq(steps.size(), 1, "one command")
	assert_eq(steps[0]["op"], "cmd", "a command step")
	assert_eq(steps[0]["arg"], "tp cave", "inline comment stripped")
	assert_eq(steps[0]["line"], 4, "1-based source line kept")


func test_script_parse_verbs() -> void:
	var steps: Array[Dictionary] = GodScript.parse("wait 1.5\nwait_ticks 30\nshot beach\nquit\nGOD ON")
	assert_eq(steps.size(), 5, "five steps")
	assert_eq(steps[0], {"op": "wait", "arg": 1.5, "line": 1}, "wait")
	assert_eq(steps[1], {"op": "wait_ticks", "arg": 30, "line": 2}, "wait_ticks")
	assert_eq(steps[2], {"op": "shot", "arg": "beach", "line": 3}, "shot")
	assert_eq(steps[3]["op"], "quit", "quit")
	assert_eq(steps[4]["op"], "cmd", "anything else is a console line")
	assert_eq(GodScript.parse("WAIT 2")[0]["op"], "wait", "verbs are case-insensitive")
	assert_eq(GodScript.parse("shot")[0]["arg"], "shot_1", "an unnamed shot gets a line-based name")


func test_script_parse_errors_carry_line_numbers() -> void:
	var cases: Array[Array] = [
		["wait", "wait needs seconds"], ["wait abc", "wait needs seconds"], ["wait -1", "wait needs seconds"], ["wait 999999", "wait needs seconds"],
		["wait_ticks", "wait_ticks needs"], ["wait_ticks 1.5", "wait_ticks needs"], ["wait_ticks -3", "wait_ticks needs"],
		["shot a/b", "plain file name"], ["shot ../x", "plain file name"],
	]
	for c: Array in cases:
		var steps: Array[Dictionary] = GodScript.parse("tp cave\n%s" % c[0])
		var errs: PackedStringArray = GodScript.errors(steps)
		assert_eq(errs.size(), 1, "'%s': one error" % c[0])
		if errs.size() == 1:
			assert_true(errs[0].begins_with("line 2: ") and errs[0].contains(c[1]), "'%s': %s" % [c[0], errs[0]])


func test_script_parse_of_empty_text_and_crlf() -> void:
	assert_eq(GodScript.parse("").size(), 0, "empty")
	assert_eq(GodScript.parse("# only comments\r\n").size(), 0, "comment with CRLF")
	var steps: Array[Dictionary] = GodScript.parse("god on\r\nheal\r\n")
	assert_eq(steps.size(), 2, "CRLF lines")
	assert_eq(steps[0]["arg"], "god on", "no stray carriage return")


func test_script_unknown_commands_are_reported_with_lines() -> void:
	var steps: Array[Dictionary] = GodScript.parse("tp cave\nfrobnicate 1\ngod on\nteleportt cave")
	var unknown: PackedStringArray = GodScript.unknown_commands(steps, _cmds)
	assert_eq(unknown.size(), 2, "two unknown")
	assert_eq(unknown[0], "line 2: unknown command 'frobnicate'", "first")
	assert_eq(unknown[1], "line 4: unknown command 'teleportt'", "second")
	assert_eq(GodScript.unknown_commands(GodScript.parse("wait 1\nquit"), _cmds).size(), 0, "verbs are not commands")


# ---------------------------------------------------------------- GodScript.run on a real host

func _host_with_run() -> Dictionary:
	var host := GodHost.new()
	await _adopt(host)
	host.setup(Node.new())  # a plain node: no `state`, no pause logic
	var loop := GameLoop.new()
	await _adopt(loop)
	assert_true(loop.start(), "GameLoop starts")
	var run := Node3D.new()
	await _adopt(run)
	host.run_started(loop, run)
	return {"host": host, "loop": loop, "run": run}


func test_script_runs_to_the_end_and_leaves_the_expected_state() -> void:
	var h: Dictionary = await _host_with_run()
	var host: GodHost = h["host"]
	var w: SimWorld = host.context.world
	var steps: Array[Dictionary] = GodScript.parse("# scripted capture\ntp cave\ngod on\nspeed 2\nspawn shark\nwait_ticks 3\nfood 4")
	var problems: PackedStringArray = await GodScript.run(host, steps)
	assert_eq(problems.size(), 0, "ran to the end: %s" % [problems])
	assert_true(w.get_entity(host.context.player_id).position.distance_to(Vector3(-20, -41, 52)) < 5.0, "player near the cave (it may have swum a tick or two)")
	assert_true(w.debug.god, "god mode on")
	assert_eq(w.debug.time_scale, 2.0, "speed 2")
	assert_true(w.tick >= 3, "wait_ticks let the sim advance (tick %d)" % w.tick)
	assert_eq(S3.food_bits(w).size() >= 4, true, "food bits spawned")
	var sharks: int = 0
	for id: int in w.entity_ids():
		sharks += int(w.get_entity(id).species_id == &"shark")
	assert_true(sharks >= 1, "the shark exists")


func test_script_with_an_error_runs_nothing() -> void:
	var h: Dictionary = await _host_with_run()
	var host: GodHost = h["host"]
	var w: SimWorld = host.context.world
	var before: Vector3 = w.get_entity(host.context.player_id).position
	var problems: PackedStringArray = await GodScript.run(host, GodScript.parse("tp cave\nfrobnicate\nwait banana"))
	assert_eq(problems.size(), 2, "both problems reported up front: %s" % [problems])
	assert_true("\n".join(problems).contains("line 2"), "unknown command line")
	assert_true("\n".join(problems).contains("line 3"), "bad wait line")
	assert_eq(w.get_entity(host.context.player_id).position, before, "the valid first line did NOT run (all-or-nothing)")


func test_script_file_missing_and_without_a_run() -> void:
	var host := GodHost.new()
	await _adopt(host)
	host.setup(Node.new())
	var missing: PackedStringArray = await GodScript.run_file(host, "user://nope_god_script.txt")
	assert_true(missing.size() == 1 and missing[0].contains("file not found"), "missing file: %s" % [missing])
	var no_run: PackedStringArray = await GodScript.run(host, GodScript.parse("tp cave"))
	assert_true(no_run.size() == 1 and no_run[0].contains("run ended"), "no run: %s" % [no_run])


func test_script_quit_step_ends_the_script_without_running_later_lines() -> void:
	# `quit` calls tree.quit(), which would end the test runner: only parse-level coverage here.
	var steps: Array[Dictionary] = GodScript.parse("god on\nquit\nheal")
	assert_eq(steps[1]["op"], "quit", "quit parsed")
	assert_eq(steps.size(), 3, "later lines still parse (they are skipped at run time)")


# ---------------------------------------------------------------- GameLoop time scale

func _ticks_for(scale: float, frames: int, delta: float) -> int:
	var loop := GameLoop.new()
	assert_true(loop.start(), "GameLoop starts")
	if not is_equal_approx(scale, 1.0):
		SimDebug.set_time_scale(loop.world, scale)
	var t0: int = loop.world.tick
	for i: int in frames:
		loop._process(delta)
	var ticks: int = loop.world.tick - t0
	loop.free()
	return ticks


func test_time_scale_changes_ticks_per_frame_proportionally() -> void:
	var base: int = _ticks_for(1.0, 20, 0.1)
	assert_true(absi(base - 60) <= 1, "x1: 2 s of frames = ~60 ticks (%d)" % base)
	var fast: int = _ticks_for(2.0, 20, 0.1)
	assert_true(absi(fast - 120) <= 2, "x2: ~120 ticks (%d)" % fast)
	var slow: int = _ticks_for(0.5, 20, 0.1)
	assert_true(absi(slow - 30) <= 1, "x0.5: ~30 ticks (%d)" % slow)


func test_time_scale_is_capped_by_the_max_frame_dt() -> void:
	var cap_ticks: int = int(round(GameLoop.MAX_FRAME_DT * 30.0))
	var burst: int = _ticks_for(8.0, 1, 1.0)
	assert_true(burst <= cap_ticks + 1, "one huge scaled frame is capped at MAX_FRAME_DT (%d ticks, cap %d)" % [burst, cap_ticks])


func test_time_scale_leaves_engine_time_scale_alone() -> void:
	var before: float = Engine.time_scale
	_ticks_for(4.0, 3, 0.05)
	assert_eq(Engine.time_scale, before, "Engine.time_scale untouched")


func test_per_tick_sim_result_does_not_depend_on_time_scale() -> void:
	var a := GameLoop.new()
	a.start()
	var b := GameLoop.new()
	b.start()
	SimDebug.set_time_scale(b.world, 2.0)
	while a.world.tick < 60:
		a._process(0.05)
	while b.world.tick < 60:
		b._process(0.05)
	assert_eq(a.world.tick, b.world.tick, "both stopped on tick 60")
	assert_eq(a.world.state_hash(), b.world.state_hash(), "same tick count = same state, whatever the delta scale")
	a.free()
	b.free()
