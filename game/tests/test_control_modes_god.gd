extends TestCase
## T1.4 control modes in the God tools: the `mode list` / `mode <id>` console command through the God test kit (registry, no
## host, a real PlayerInput node in the GodContext), the live effect on the node and on the sim (SET_CONTROL_MODE reaches the
## world, the assisted bite lands, classic restores the miss), the quick buttons, and the gate / purity source checks (the
## Settings selector and the input layer know nothing about the God build gate; the console command is behind it).
##
## Assumptions (test plan): `mode <id>` changes the PlayerInput of the context (and so the sim through its normal command), a
## repeated `mode <id>` sends nothing new, `mode list` prints every id and every `name`, an unknown id is refused with an answer
## naming it, a context without a run answers a message (no crash). The console change is live only (not asserted either way
## for the saved settings).

const CM := preload("res://tests/control_modes_support.gd")
const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")

const DT: float = 1.0 / 60.0


func after_each() -> void:
	for a: StringName in [&"bite", &"boost", &"swim_thrust", &"swim_brake"]:
		if InputMap.has_action(a):
			Input.action_release(a)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


## {"w","p","pi","ctx","cmds"}: controlled world, player at the arena looking -Z, PlayerInput in the tree and in the context.
func _rig() -> Dictionary:
	var w: SimWorld = AS.world({})
	var p: SimEntity = S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, 0.5), Vector3(0, 0, -1))  # 0.5 m like TS.player
	var pi: PlayerInput = await CM.input_rig(w, p)
	var ctx: GodContext = G.context(w, p.id)
	ctx.player_input = pi
	return {"w": w, "p": p, "pi": pi, "ctx": ctx, "cmds": TS.commands()}


func _free(rg: Dictionary) -> void:
	CM.release_input(rg["pi"])


## One sim tick of the live loop: two physics frames of the node (60 Hz), then the world step. `pins` / `keep` as in S3.step_n.
func _tick(rg: Dictionary, pins: Dictionary = {}, keep: Array[int] = []) -> Array[SimEvent]:
	var pi: PlayerInput = rg["pi"]
	pi._physics_process(DT)
	pi._physics_process(DT)
	return S3.step_n(rg["w"], 1, pins, keep)


func _say(rg: Dictionary, line: String) -> String:
	return (rg["cmds"] as GodCommands).execute(line, rg["ctx"])


# ======================================================================= registry and answers

func test_mode_is_registered_with_a_usage_line() -> void:
	var cmds: GodCommands = TS.commands()
	var ctx: GodContext = G.context(AS.world({}), 1)
	var all: String = cmds.execute("help", ctx)
	assert_has(all, "mode", "`help` lists the mode command")
	var one: String = cmds.execute("help mode", ctx)
	assert_true(one.to_lower().contains("mode") and not one.to_lower().contains("unknown"), "`help mode` describes it (got: %s)" % one)


func test_mode_list_shows_every_id_and_label() -> void:
	var rg: Dictionary = await _rig()
	var answer: String = _say(rg, "mode list")
	for id: String in CM.IDS:
		assert_has(answer, id, "`mode list` names %s" % id)
		assert_has(answer, CM.name_of(id), "`mode list` shows the label of %s" % id)
	_free(rg)


func test_mode_without_arguments_answers_instead_of_failing() -> void:
	var rg: Dictionary = await _rig()
	var answer: String = _say(rg, "mode")
	assert_true(answer.to_lower().contains("mode") and not answer.contains("unknown command"), "usage or the current mode (got: %s)" % answer)
	_free(rg)


func test_an_unknown_mode_is_refused_and_nothing_is_sent() -> void:
	if not CM.has_type():
		fail("SimCommand.Type.SET_CONTROL_MODE does not exist")
		return
	var rg: Dictionary = await _rig()
	var answer: String = _say(rg, "mode no_such_mode")
	assert_true(answer.contains("no_such_mode") or answer.to_lower().contains("unknown"), "the answer names the problem (got: %s)" % answer)
	for i in 4:
		_tick(rg)
	assert_true(CM.in_mode(rg["p"], "classic"), "the player is still in classic")
	_free(rg)


func test_mode_without_a_run_answers_a_message() -> void:
	var cmds: GodCommands = TS.commands()
	var answer: String = cmds.execute("mode assisted", GodContext.new())
	assert_false(answer.strip_edges().is_empty() or answer.contains("unknown command"), "a context without a run answers with a message of the command (got: %s)" % answer)
	var list: String = cmds.execute("mode list", GodContext.new())
	assert_false(list.strip_edges().is_empty() or list.contains("unknown command"), "`mode list` without a run answers too (got: %s)" % list)


# ======================================================================= live effect

func test_mode_changes_the_node_and_the_sim_live() -> void:
	if not CM.has_type():
		fail("SimCommand.Type.SET_CONTROL_MODE does not exist")
		return
	var rg: Dictionary = await _rig()
	var p: SimEntity = rg["p"]
	assert_true(CM.in_mode(p, "classic"), "setup: classic")
	var answer: String = _say(rg, "mode assisted")
	assert_false(answer.to_lower().contains("unknown"), "accepted (got: %s)" % answer)
	for i in 3:
		_tick(rg, {}, [p.id])
	assert_true(CM.in_mode(p, "assisted"), "after `mode assisted` the player entity is in assisted (value %s)" % str(CM.mode_value(p)))
	_say(rg, "mode smoothed")
	for i in 3:
		_tick(rg, {}, [p.id])
	assert_true(CM.in_mode(p, "smoothed"), "`mode smoothed` follows")
	_say(rg, "mode classic")
	for i in 3:
		_tick(rg, {}, [p.id])
	assert_true(CM.in_mode(p, "classic"), "`mode classic` brings it back")
	_free(rg)


func test_the_same_mode_twice_sends_one_command() -> void:
	if not CM.has_type():
		fail("SimCommand.Type.SET_CONTROL_MODE does not exist")
		return
	var rg: Dictionary = await _rig()
	var w: SimWorld = rg["w"]
	var pi: PlayerInput = rg["pi"]
	_say(rg, "mode assisted")
	_say(rg, "mode assisted")
	for i in 4:
		pi._physics_process(DT)
	var sets: int = 0
	for c: SimCommand in w._queue.pop_for_tick(w.tick):
		if CM.is_set(c):
			sets += 1
			assert_true(CM.is_set_of(c, "assisted"), "names assisted")
	assert_eq(sets, 1, "two identical console lines, one SET_CONTROL_MODE")
	_free(rg)


func test_the_console_mode_drives_a_real_assisted_bite_and_classic_restores_the_miss() -> void:
	if not CM.has_type():
		fail("SimCommand.Type.SET_CONTROL_MODE does not exist")
		return
	var rg: Dictionary = await _rig()
	var w: SimWorld = rg["w"]
	w.brains_enabled = false
	var p: SimEntity = rg["p"]
	var s_a: float = CM.mode_f("assisted", CM.KEY_AIM)
	var deg: float = (CM.strict_cone_deg() + CM.widened_deg(s_a)) * 0.5
	var v: SimEntity = TS.victim(w, p, TS.at(p, 0.9, deg))
	var landed: Array[int] = []
	for line: String in ["mode classic", "mode assisted", "mode classic", "mode assisted"]:
		_say(rg, line)
		for i in 3:
			_tick(rg, {v.id: TS.at(p, 0.9, deg)}, [v.id, p.id])
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = []
		for i in 60:
			evs.append_array(_tick(rg, {v.id: TS.at(p, 0.9, deg)}, [v.id, p.id]))
		landed.append(TS.bites_by(evs, p.id, v.id).size())
	assert_eq(landed.size(), 4, "four phases ran")
	if landed.size() == 4:
		assert_eq(landed[0], 0, "`mode classic`: the prey at %.0f deg is missed" % deg)
		assert_true(landed[1] >= 1, "`mode assisted`: the bite lands (%d)" % landed[1])
		assert_eq(landed[2], 0, "`mode classic` again: the miss is back")
		assert_true(landed[3] >= 1, "`mode assisted` again: bite")
	_free(rg)


# ======================================================================= quick buttons

func test_the_god_menu_offers_a_quick_button_per_mode() -> void:
	var ctx: GodContext = G.context(AS.world({}), 1)
	var lines: PackedStringArray = GodSimCommands.quick_lines(ctx)
	for id: String in CM.IDS:
		assert_true(lines.has("mode %s" % id), "quick line `mode %s` is offered" % id)


# ======================================================================= gate and purity (source level)

func _source(rel: String) -> String:
	return FileAccess.get_file_as_string(_repo(rel))


func test_the_console_command_sits_behind_the_god_gate() -> void:
	var src: String = _source("game/scripts/ui/god_sim_commands.gd")
	var start: int = src.find("func _cmd_mode")
	assert_true(start >= 0, "god_sim_commands.gd has _cmd_mode")
	if start < 0:
		return
	var end: int = src.find("\nstatic func ", start + 10)
	var body: String = src.substr(start, (end if end > start else src.length()) - start)
	assert_true(body.contains("GodBuild.allowed"), "_cmd_mode checks GodBuild.allowed() like `tune` does")


func test_the_settings_selector_and_the_input_layer_know_nothing_about_the_god_build() -> void:
	for rel: String in ["game/scripts/ui/settings_menu.gd", "game/scripts/ui/game_settings.gd", "game/scripts/fish/player_input.gd"]:
		var src: String = _source(rel)
		assert_false(src.contains("GodBuild"), "%s does not use the God build gate (the selector is for everyone)" % rel)
		assert_false(src.contains("SimDebug"), "%s does not reach into SimDebug (input only submits commands)" % rel)


func test_the_input_layer_never_writes_sim_state() -> void:
	var src: String = _source("game/scripts/fish/player_input.gd")
	for pat: String in ["_entities", ".control_mode =", "world.debug", "_world.debug"]:
		assert_false(src.contains(pat), "player_input.gd does not touch `%s`" % pat)
