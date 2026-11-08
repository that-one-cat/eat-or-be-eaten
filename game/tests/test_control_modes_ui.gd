extends TestCase
## T1.4 control modes, UI: the selector in the Settings screen (scene instance with an injected GameSettings: labels and
## descriptions from the data, reflects and edits the setting, `changed`, saved by close(), unknown value shows classic), and two
## ui_flow-style journeys through the real res://scenes/main.tscn with a scratch settings path:
##   1. a saved `assisted` is applied at run start (the live player entity ends up in assisted), then the God console `mode`
##      command switches it live (unlock through GodHost.unlock(), commands through the console node);
##   2. menu -> Play -> Esc pause -> Settings -> pick assisted in the selector -> Back (file saved) -> Resume -> the live entity
##      follows; again with classic.
## The selector is found by content (an OptionButton other than the quality one whose items are the data `name`s), the setting
## by CM.settings_prop(), so node and property names stay the implementation's choice. The tools/check.sh ui_flow step is the
## separate gate for the existing scripted path (tests/scenarios/ui_flow.gd); it must keep passing untouched.

const CM := preload("res://tests/control_modes_support.gd")
const TS := preload("res://tests/tuning_support.gd")

const MAIN_SCENE: String = "res://scenes/main.tscn"
const MENU_SCENE: String = "res://scenes/ui/settings_menu.tscn"
const SCRATCH: String = "user://test_control_modes_ui_settings.cfg"
const REAL_SETTINGS: String = "user://settings.cfg"
const WAIT_S: float = 30.0
const LOAD_WAIT_S: float = 90.0

var _nodes: Array[Node] = []


func after_each() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.paused = false
	Engine.time_scale = 1.0
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _adopt(n: Node) -> void:
	_tree().root.add_child(n)
	_nodes.append(n)
	await _tree().process_frame


func _wait(cond: Callable, timeout_s: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not bool(cond.call()):
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await _tree().process_frame
	return true


func _state(main: Node) -> String:
	var states: Dictionary = (main.get_script() as Script).get_script_constant_map()["State"]
	return String(states.find_key(main.get("state")))


func _need() -> bool:
	if CM.settings_prop() == "":
		fail("GameSettings has no control-mode property (looked for a variable containing 'control_mode' or 'mode')")
		return false
	return true


## Settings menu scene in the tree, opened on `gs`.
func _menu(gs: GameSettings) -> SettingsMenu:
	var sm: SettingsMenu = (load(MENU_SCENE) as PackedScene).instantiate() as SettingsMenu
	await _adopt(sm)
	sm.open(gs)
	return sm


func _pick(ob: OptionButton, id: String) -> void:
	var idx: int = CM.item_of(ob, id)
	ob.select(idx)
	ob.item_selected.emit(idx)


# ======================================================================= settings menu (scene instance)

func test_the_selector_lists_every_mode_by_its_data_name() -> void:
	if not _need():
		return
	var gs := GameSettings.new(SCRATCH)
	var sm: SettingsMenu = await _menu(gs)
	var ob: OptionButton = CM.mode_selector(sm)
	assert_not_null(ob, "an OptionButton (not the quality one) lists the mode names %s" % [CM.IDS.map(func(i: String) -> String: return CM.name_of(i))])
	if ob == null:
		return
	for id: String in CM.IDS:
		assert_true(CM.item_of(ob, id) >= 0, "item '%s' for %s" % [CM.name_of(id), id])
	assert_false(ob.disabled, "the selector is enabled (it is not behind the God gate)")
	assert_true(ob.is_visible_in_tree(), "and visible in the opened screen")


func test_the_selector_reflects_the_setting_when_the_screen_opens() -> void:
	if not _need():
		return
	for id: String in CM.IDS:
		var gs := GameSettings.new(SCRATCH)
		CM.set_settings_mode(gs, id)
		var sm: SettingsMenu = await _menu(gs)
		var ob: OptionButton = CM.mode_selector(sm)
		if ob == null:
			fail("no mode selector in the settings menu")
			return
		assert_eq(CM.selected_mode_name(ob), CM.name_of(id), "setting %s -> selector shows '%s'" % [id, CM.name_of(id)])
		assert_eq(CM.settings_mode(gs), id, "and opening the screen does not rewrite the setting")


func test_choosing_a_mode_edits_the_settings_and_announces_the_change() -> void:
	if not _need():
		return
	var gs := GameSettings.new(SCRATCH)
	var sm: SettingsMenu = await _menu(gs)
	var ob: OptionButton = CM.mode_selector(sm)
	if ob == null:
		fail("no mode selector in the settings menu")
		return
	var changed: Array[int] = [0]
	sm.changed.connect(func() -> void: changed[0] += 1)
	for id: String in ["assisted", "smoothed", "classic"]:
		var before: int = changed[0]
		_pick(ob, id)
		assert_eq(CM.settings_mode(gs), id, "choosing '%s' sets the setting to %s" % [CM.name_of(id), id])
		assert_true(changed[0] > before, "and emits `changed` (Main applies it to the running PlayerInput)")


func test_the_description_follows_the_selection() -> void:
	if not _need():
		return
	var gs := GameSettings.new(SCRATCH)
	var sm: SettingsMenu = await _menu(gs)
	var ob: OptionButton = CM.mode_selector(sm)
	if ob == null:
		fail("no mode selector in the settings menu")
		return
	assert_has(TS.all_text(sm), CM.description_of("classic"), "the screen shows the one-line description of the current mode (classic)")
	_pick(ob, "assisted")
	assert_has(TS.all_text(sm), CM.description_of("assisted"), "after choosing assisted its description is shown")
	_pick(ob, "smoothed")
	assert_has(TS.all_text(sm), CM.description_of("smoothed"), "and smoothed's")


func test_an_unknown_setting_value_shows_classic_and_does_not_crash() -> void:
	if not _need():
		return
	var gs := GameSettings.new(SCRATCH)
	var prop: String = CM.settings_prop()
	gs.set(prop, 99 if typeof(gs.get(prop)) == TYPE_INT else StringName("bogus_mode"))
	var sm: SettingsMenu = await _menu(gs)
	var ob: OptionButton = CM.mode_selector(sm)
	if ob == null:
		fail("no mode selector in the settings menu")
		return
	assert_eq(CM.selected_mode_name(ob), CM.name_of("classic"), "an unknown stored value is shown as classic")


func test_closing_the_screen_saves_the_chosen_mode() -> void:
	if not _need():
		return
	var gs := GameSettings.new(SCRATCH)
	var sm: SettingsMenu = await _menu(gs)
	var ob: OptionButton = CM.mode_selector(sm)
	if ob == null:
		fail("no mode selector in the settings menu")
		return
	_pick(ob, "assisted")
	sm.back_button.pressed.emit()
	assert_false(sm.visible, "Back closes the screen")
	var back := GameSettings.new(SCRATCH)
	back.load_file()
	assert_eq(CM.settings_mode(back), "assisted", "the file now says assisted")
	var sm2: SettingsMenu = await _menu(back)
	assert_eq(CM.selected_mode_name(CM.mode_selector(sm2)), CM.name_of("assisted"), "and a re-opened screen shows it")


# ======================================================================= journeys through main.tscn

func _start_main(seed_mode: String) -> Dictionary:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	if seed_mode != "":
		var gs := GameSettings.new(SCRATCH)
		CM.set_settings_mode(gs, seed_mode)
		gs.save_file()
	var real_existed: bool = FileAccess.file_exists(REAL_SETTINGS)
	var real_before: String = FileAccess.get_file_as_string(REAL_SETTINGS) if real_existed else ""
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.set(&"settings_path", SCRATCH)
	await _adopt(main)
	var out: Dictionary = {"main": main, "real_existed": real_existed, "real_before": real_before, "running": false}
	if not await _wait(func() -> bool: return _state(main) == "MENU", WAIT_S):
		return out
	(main.get("main_menu") as MainMenu).play_button.pressed.emit()
	out["running"] = await _wait(func() -> bool: return _state(main) == "RUNNING", LOAD_WAIT_S)
	return out


func _in_mode(main: Node, id: String) -> bool:
	var loop: GameLoop = main.get("loop") as GameLoop
	return loop != null and loop.world != null and CM.in_mode(loop.world.get_entity(loop.player_id), id)


func _wait_mode(main: Node, id: String) -> bool:
	return await _wait(func() -> bool: return _in_mode(main, id), WAIT_S)


func _real_settings_untouched(j: Dictionary) -> bool:
	var after: String = FileAccess.get_file_as_string(REAL_SETTINGS) if FileAccess.file_exists(REAL_SETTINGS) else ""
	return not bool(j["real_existed"]) or after == str(j["real_before"])


func test_journey_saved_mode_at_run_start_then_the_god_console_switches_it_live() -> void:
	if not _need() or not CM.has_type():
		fail("SET_CONTROL_MODE or the GameSettings mode property is missing")
		return
	var j: Dictionary = await _start_main("assisted")
	assert_true(bool(j["running"]), "run started through the Play button")
	if not bool(j["running"]):
		return
	var main: Node = j["main"]
	assert_true(await _wait_mode(main, "assisted"), "a saved `assisted` is applied at run start: the live player entity is in assisted")
	var host: GodHost = main.get("_god") as GodHost
	assert_not_null(host, "the God host exists in the test build")
	if host == null:
		return
	assert_true(host.unlock(), "God tools unlocked in the run")
	host.console.submit("mode classic")
	assert_true(await _wait_mode(main, "classic"), "`mode classic` in the console puts the live player back to classic")
	host.console.submit("mode smoothed")
	assert_true(await _wait_mode(main, "smoothed"), "`mode smoothed` follows")
	host.console.submit("mode assisted")
	assert_true(await _wait_mode(main, "assisted"), "`mode assisted` follows")
	host.console.submit("mode list")
	var log: String = host.console.log_text()
	for id: String in CM.IDS:
		assert_has(log, id, "`mode list` printed %s into the console log" % id)
	assert_true(_real_settings_untouched(j), "the real user://settings.cfg stayed untouched")


func test_journey_default_run_starts_in_classic_and_the_settings_screen_switches_the_mode() -> void:
	if not _need() or not CM.has_type():
		fail("SET_CONTROL_MODE or the GameSettings mode property is missing")
		return
	var j: Dictionary = await _start_main("")
	assert_true(bool(j["running"]), "run started through the Play button")
	if not bool(j["running"]):
		return
	var main: Node = j["main"]
	var loop: GameLoop = main.get("loop") as GameLoop
	var t0: int = loop.world.tick
	assert_true(await _wait(func() -> bool: return loop.world.tick >= t0 + 30, WAIT_S), "the world ticks")
	assert_true(_in_mode(main, "classic"), "the default run is classic")

	var pause_menu: PauseMenu = main.get("pause_menu") as PauseMenu
	var sm: SettingsMenu = main.get("settings_menu") as SettingsMenu
	for id: String in ["assisted", "classic"]:
		main.call(&"pause")
		assert_true(await _wait(func() -> bool: return _state(main) == "PAUSED", WAIT_S), "Esc pause (before choosing %s)" % id)
		pause_menu.settings_button.pressed.emit()
		assert_true(sm.visible, "the settings screen opens over the pause menu")
		var ob: OptionButton = CM.mode_selector(sm)
		assert_not_null(ob, "the selector is in the screen")
		if ob == null:
			return
		_pick(ob, id)
		assert_eq(CM.settings_mode(main.get("settings") as GameSettings), id, "the live settings object says %s" % id)
		sm.back_button.pressed.emit()
		var saved := GameSettings.new(SCRATCH)
		saved.load_file()
		assert_eq(CM.settings_mode(saved), id, "Back saved %s into the scratch file" % id)
		pause_menu.resume_button.pressed.emit()
		assert_eq(_state(main), "RUNNING", "resumed")
		assert_true(await _wait_mode(main, id), "after the screen the live player entity is in %s" % id)
	assert_true(_real_settings_untouched(j), "the real user://settings.cfg stayed untouched")
