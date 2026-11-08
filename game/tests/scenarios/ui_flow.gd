extends Node
## S6 scripted UI path test (headless or windowed): godot --headless --path game res://tests/scenarios/ui_flow.tscn
## Instances main.tscn with a scratch settings file (SETTINGS_PATH; the real user://settings.cfg is compared before /
## after and must be untouched) and walks the whole flow through the real screens (buttons via their `pressed`
## signal, Esc via Input.parse_input_event of the `pause` action):
##   menu -> Play -> run loaded, a tutorial hint on screen -> Esc: pause (tree paused, hints hidden) -> Settings:
##   master 50 %, sensitivity 2x, invert Y (applied live to the bus / the running PlayerInput) -> Back (file saved) ->
##   Resume -> SimDebug.force_band_up -> world paused for the pick, hints hidden -> pick through the map's
##   MutationPickOverlay (impl-B): wait until it is open and past its input grace, press the `pick_mutation_1` action
##   (key 1); without the overlay or the action, PICK_MUTATION is submitted directly and a note is printed ->
##   SimDebug.force_victory -> victory screen lists the picked mutation, tree paused -> Menu -> back in the menu, run
##   freed, tree running, time scale 1.
## Prints "UI_FLOW <step>: PASS|FAIL ..." per step and "UI_FLOW: PASS|FAIL", exits 0 / 1. Waits are wall-clock
## bounded (WAIT_S) so a stuck screen fails instead of hanging.

const MAIN_SCENE: String = "res://scenes/main.tscn"
const SETTINGS_PATH: String = "user://test_ui_flow_settings.cfg"
const REAL_SETTINGS_PATH: String = "user://settings.cfg"
const OVERLAY_PATH: NodePath = ^"MutationPickOverlay"
const PICK_ACTION: StringName = &"pick_mutation_1"
const WAIT_S: float = 30.0
const LOAD_WAIT_S: float = 90.0

var _all_ok: bool = true
var _main: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _run()
	_cleanup()
	print("UI_FLOW: %s" % ("PASS" if _all_ok else "FAIL"))
	get_tree().quit(0 if _all_ok else 1)


func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	var real_existed: bool = FileAccess.file_exists(REAL_SETTINGS_PATH)
	var real_before: String = FileAccess.get_file_as_string(REAL_SETTINGS_PATH) if real_existed else ""
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	_main.set(&"settings_path", SETTINGS_PATH)
	add_child(_main)
	var menu: MainMenu = _main.get(&"main_menu")
	var pause_menu: PauseMenu = _main.get(&"pause_menu")
	var settings_menu: SettingsMenu = _main.get(&"settings_menu")
	var victory: VictoryScreen = _main.get(&"victory_screen")
	var hints: TutorialHints = _main.get(&"hints")

	# menu -> Play
	if not _check("menu", await _wait(func() -> bool: return _state() == 0 and menu.visible, WAIT_S), "menu visible"):
		return
	menu.play_button.pressed.emit()
	if not _check("play", await _wait(func() -> bool: return _state() == 2, LOAD_WAIT_S), "state RUNNING after Play"):
		return
	var loop: GameLoop = _main.get(&"loop")
	var world: SimWorld = loop.world
	var pid: int = loop.player_id
	_check("run", not menu.visible and world != null and not get_tree().paused, "menu hidden, world %s" % (world != null))
	_check("hint", await _wait(func() -> bool: return hints.is_showing(), WAIT_S), "first hint '%s'" % hints.current_hint())

	# Esc -> pause -> settings -> back -> resume
	_send_action(&"pause")
	_check("pause", await _wait(func() -> bool: return _state() == 3, WAIT_S) and get_tree().paused and pause_menu.visible and not hints.visible,
		"paused=%s pause_menu=%s hints_visible=%s" % [get_tree().paused, pause_menu.visible, hints.visible])
	pause_menu.settings_button.pressed.emit()
	_check("settings_open", settings_menu.visible and settings_menu.layer > pause_menu.layer, "settings over the pause menu")
	settings_menu.master_slider.value = 50.0
	settings_menu.sensitivity_slider.value = 2.0
	settings_menu.invert_check.button_pressed = true
	var input: PlayerInput = _main.call(&"player_input")
	var bus_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"Master"))
	var has_buses: bool = AudioServer.get_bus_index(&"Music") >= 0 and AudioServer.get_bus_index(&"SFX") >= 0
	_check("settings_live", absf(bus_db - linear_to_db(0.5)) < 0.01 and has_buses and input != null
		and is_equal_approx(input.sensitivity, PlayerInput.DEFAULT_SENSITIVITY * 2.0) and input.invert_y,
		"master_db=%.2f buses=%s sensitivity=%s invert_y=%s" % [bus_db, has_buses, input.sensitivity if input != null else -1.0, input.invert_y if input != null else false])
	settings_menu.back_button.pressed.emit()
	var cfg := ConfigFile.new()
	var saved: bool = cfg.load(SETTINGS_PATH) == OK and is_equal_approx(float(cfg.get_value("audio", "master_volume", -1.0)), 0.5) and bool(cfg.get_value("input", "invert_y", false))
	_check("settings_saved", saved and not settings_menu.visible and pause_menu.visible, "file %s master_volume=%s" % [SETTINGS_PATH, cfg.get_value("audio", "master_volume", "missing")])
	pause_menu.resume_button.pressed.emit()
	_check("resume", _state() == 2 and not get_tree().paused and not pause_menu.visible and hints.visible, "running again")

	# band-up -> pick
	var e: SimEntity = world.get_entity(pid)
	SimDebug.force_band_up(world, pid)
	if not _check("offer", await _wait(func() -> bool: return world.paused_for_pick, WAIT_S), "paused_for_pick, offer %s" % e.pending_offer):
		return
	await get_tree().process_frame
	_check("hints_hidden_for_pick", not hints.is_showing(), "hint panel hidden during the pick")
	var offer: PackedStringArray = e.pending_offer.duplicate()
	var run: Node = _main.get(&"run")
	var overlay: MutationPickOverlay = run.get_node_or_null(OVERLAY_PATH) as MutationPickOverlay
	if overlay != null and InputMap.has_action(PICK_ACTION):
		_check("overlay_open", await _wait(func() -> bool: return overlay.is_open(), WAIT_S), "MutationPickOverlay open")
		await get_tree().create_timer(MutationPickOverlay.INPUT_GRACE_S + 0.2).timeout
		_send_action(PICK_ACTION)
	else:
		print("UI_FLOW note: no MutationPickOverlay / %s action; PICK_MUTATION submitted directly" % PICK_ACTION)
		world.submit(SimCommand.pick_mutation(pid, StringName(offer[0])))
	_check("pick", await _wait(func() -> bool: return not world.paused_for_pick and e.mutations.size() == 1, WAIT_S)
		and e.mutations[0] == offer[0], "picked %s of %s" % [e.mutations, offer])

	# victory -> menu
	SimDebug.force_victory(world, pid)
	if not _check("victory", await _wait(func() -> bool: return _state() == 4 and victory.visible, WAIT_S), "victory screen visible"):
		return
	var picked_name: String = str(world.content.get_mutation(StringName(e.mutations[0])).get("name", ""))
	_check("victory_stats", get_tree().paused and victory.listed_mutations().has(picked_name) and victory.deaths_value.text == "0",
		"mutations %s (expect %s) deaths %s time %s" % [victory.listed_mutations(), picked_name, victory.deaths_value.text, victory.time_value.text])
	victory.menu_button.pressed.emit()
	_check("back_to_menu", await _wait(func() -> bool: return _state() == 0 and menu.visible, WAIT_S) and _main.get(&"run") == null
		and not get_tree().paused and is_equal_approx(Engine.time_scale, 1.0) and not victory.visible,
		"state %d run %s paused %s" % [_state(), _main.get(&"run"), get_tree().paused])
	await get_tree().create_timer(1.0).timeout  # let the fade-in finish (no coroutine left pending at quit)
	_check("run_freed", _main.get_node(^"Run").get_child_count() == 0, "Run holder empty")

	var real_after: String = FileAccess.get_file_as_string(REAL_SETTINGS_PATH) if FileAccess.file_exists(REAL_SETTINGS_PATH) else ""
	_check("real_settings_untouched", not real_existed or real_after == real_before, "%s unchanged" % REAL_SETTINGS_PATH)


func _state() -> int:
	return int(_main.get(&"state"))


func _send_action(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)


# Waits (process frames) until `cond` is true or `timeout_s` of wall-clock time passed; returns the condition.
func _wait(cond: Callable, timeout_s: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not bool(cond.call()):
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await get_tree().process_frame
	return true


func _check(step: String, ok: bool, info: String) -> bool:
	_all_ok = _all_ok and ok
	print("UI_FLOW %s: %s %s" % [step, "PASS" if ok else "FAIL", info])
	return ok


func _cleanup() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
