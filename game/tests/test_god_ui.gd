extends TestCase
## T1.1 / T1.2 host behaviour: GodHost standalone (typed-word unlock, F1 / F4 menu, `~` console, pause restore, focus
## guard, run lifecycle, menu quick buttons) and ONE end-to-end journey through the real res://scenes/main.tscn with
## events delivered by Input.parse_input_event. Mouse-mode round trips are NOT asserted: Input.mouse_mode never reads
## back CAPTURED headless (see test_f1_bite_independent.gd).

const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const MAIN_SCENE: String = "res://scenes/main.tscn"
const E2E_SETTINGS: String = "user://test_god_e2e_settings.cfg"
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
	DirAccess.remove_absolute(ProjectSettings.globalize_path(E2E_SETTINGS))


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frame() -> void:
	await _tree().process_frame


func _adopt(n: Node) -> void:
	_tree().root.add_child(n)
	_nodes.append(n)
	await _frame()


## {"host", "loop", "run", "w", "id"}: a host over a plain Node (no Main) with a started GameLoop as its run.
func _rig(with_run: bool = true) -> Dictionary:
	var host := GodHost.new()
	await _adopt(host)
	var stub := Node.new()
	await _adopt(stub)
	host.setup(stub)
	var out: Dictionary = {"host": host}
	if with_run:
		var loop := GameLoop.new()
		await _adopt(loop)
		assert_true(loop.start(), "GameLoop starts")
		var run := Node3D.new()
		await _adopt(run)
		host.run_started(loop, run)
		out["loop"] = loop
		out["run"] = run
		out["w"] = loop.world
		out["id"] = loop.player_id
	return out


# ---------------------------------------------------------------- setup

func test_setup_builds_menu_console_and_the_full_registry() -> void:
	var rg: Dictionary = await _rig(false)
	var host: GodHost = rg["host"]
	assert_not_null(host.menu, "menu")
	assert_not_null(host.console, "console")
	assert_eq(host.process_mode, Node.PROCESS_MODE_ALWAYS, "keeps working while the tree is paused")
	for n: String in ["help", "clear", "menu", "close", "tp", "band", "spawn", "god", "noclip", "overlay", "boss"]:
		assert_true(host.commands.has_command(StringName(n)), "command %s registered (T1.1 built-ins + T1.2 commands)" % n)
	assert_eq(host.data.errors.size(), 0, "shipped word file loads clean")
	assert_false(host.session_unlocked, "locked at start")
	assert_false(host.context.has_run(), "no run yet")
	assert_false(host.menu.is_open() or host.console.is_open(), "both closed")


# ---------------------------------------------------------------- unlock

func test_unlock_needs_a_running_world() -> void:
	var rg: Dictionary = await _rig(false)
	var host: GodHost = rg["host"]
	assert_false(host.unlock(), "unlock refused without a run")
	G.host_type(host, "eatgod")
	assert_false(host.session_unlocked, "the typed word without a run does nothing")
	assert_false(host.menu.is_open(), "menu stays closed")


func test_typing_the_word_unlocks_and_opens_the_menu() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var fired: Array[int] = [0]
	host.unlocked.connect(func() -> void: fired[0] += 1)
	G.host_type(host, "eatgod")
	assert_true(host.session_unlocked, "unlocked")
	assert_true(host.menu.is_open(), "the unlock opens the menu (acceptance criterion)")
	assert_eq(fired[0], 1, "unlocked signal once")
	assert_has(host.console.log_text(), "God tools unlocked", "announced in the console log")


func test_russian_layout_typing_unlocks() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	G.host_type(host, "eatgod", true)
	assert_true(host.session_unlocked, "Cyrillic unicode + US physical keys unlock")


func test_wrong_word_does_not_unlock() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	G.host_type(host, "eatfood")
	G.host_type(host, "godeat")
	assert_false(host.session_unlocked, "other words")
	assert_false(host.menu.is_open(), "menu closed")


func test_unlock_is_per_session_object() -> void:
	var a: Dictionary = await _rig()
	(a["host"] as GodHost).unlock()
	var b: Dictionary = await _rig()
	assert_true((a["host"] as GodHost).session_unlocked, "first host unlocked")
	assert_false((b["host"] as GodHost).session_unlocked, "a new host starts locked: nothing is persisted")
	assert_false(FileAccess.file_exists("user://god_unlocked"), "no unlock marker on disk")


func test_unlock_is_idempotent_and_survives_a_new_run() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	assert_true(host.unlock(), "first")
	assert_true(host.unlock(), "second")
	host.run_ended()
	assert_true(host.session_unlocked, "the unlock stays across runs of the same app session")
	assert_false(host.context.has_run(), "but the context is empty between runs")


# ---------------------------------------------------------------- hotkeys

func test_hotkeys_do_nothing_before_the_unlock() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host._unhandled_input(G.f1())
	host._unhandled_input(G.backtick())
	assert_false(host.menu.is_open(), "F1 does nothing while locked")
	assert_false(host.console.is_open(), "backtick does nothing while locked")
	assert_false(_tree().paused, "and nothing paused the game")


func test_f1_and_f4_toggle_the_menu_after_unlock() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host._unhandled_input(G.f1())
	assert_true(host.menu.is_open(), "F1 opens")
	host._unhandled_input(G.f1())
	assert_false(host.menu.is_open(), "F1 closes")
	host._unhandled_input(G.key(0, KEY_F4, true, false, KEY_F4))
	assert_true(host.menu.is_open(), "F4 opens (second binding for Mac laptops)")
	host._unhandled_input(G.key(0, KEY_F2, true, false, KEY_F2))
	assert_true(host.menu.is_open(), "F2 is not bound")
	host._unhandled_input(G.key(0, KEY_F4, false))
	assert_true(host.menu.is_open(), "a key release does not toggle")


func test_menu_does_not_pause_the_game() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	assert_true(host.menu.is_open(), "test setup: menu open")
	assert_false(_tree().paused, "the F1 menu leaves the tree running (live tuning)")


func test_backtick_variants_open_the_console_and_pause_the_tree() -> void:
	var variants: Array[InputEventKey] = [G.backtick(), G.key(126, KEY_QUOTELEFT, true, false, KEY_ASCIITILDE), G.key(1105, KEY_QUOTELEFT), G.key(1025, KEY_NONE), G.key(126, KEY_NONE)]
	for ev: InputEventKey in variants:
		var rg: Dictionary = await _rig()
		var host: GodHost = rg["host"]
		host.unlock()
		host.menu.close()
		host._unhandled_input(ev)
		await _frame()  # lets the console's deferred focus grab run before it is closed again
		assert_true(host.console.is_open(), "console opened by unicode %d / physical %d" % [ev.unicode, ev.physical_keycode])
		assert_true(_tree().paused, "the tree is paused while the console is open (typing W/S/Q must not steer the fish)")
		host.console.close()
		assert_false(_tree().paused, "and unpaused again on close")


func test_console_open_while_the_pause_menu_is_up_keeps_the_pause() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	_tree().paused = true  # what Main.pause() does
	host._unhandled_input(G.backtick())
	assert_true(host.console.is_open(), "console opens over the pause menu")
	host.console.close()
	assert_true(_tree().paused, "closing the console does not unpause the game the pause menu paused")


func test_escape_closes_the_console_and_main_is_told_not_to_pause() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host._unhandled_input(G.backtick())
	assert_true(host.consumes_pause(), "Esc belongs to the console while it is open")
	var esc := InputEventAction.new()
	esc.action = &"pause"
	esc.pressed = true
	host.console._input(esc)
	assert_false(host.console.is_open(), "Esc closed it")
	assert_false(host.consumes_pause(), "and Esc is Main's again")


func test_hotkeys_are_ignored_while_the_console_is_open() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host.console.open()
	host._unhandled_input(G.f1())
	assert_false(host.menu.is_open(), "F1 does not open the menu behind the console")


func test_hotkeys_need_a_run() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host.run_ended()
	host._unhandled_input(G.f1())
	host._unhandled_input(G.backtick())
	assert_false(host.menu.is_open() or host.console.is_open(), "no run (menu / loading state): F1 and backtick do nothing")


func test_letter_keys_are_never_consumed_but_hotkeys_are() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var vp: Viewport = host.get_viewport()
	vp.push_input(G.latin("e"))  # a full dispatch resets the handled flag first
	host.unlock()
	host.menu.close()
	vp.push_input(G.latin("w"))
	assert_false(vp.is_input_handled(), "W (gameplay key) is not consumed by the unlocked host")
	vp.push_input(G.f1())
	assert_true(vp.is_input_handled(), "F1 is consumed (it must not also reach the game)")
	assert_true(host.menu.is_open(), "and it toggled the menu through the real dispatch")
	vp.push_input(G.latin("w"))
	assert_false(vp.is_input_handled(), "the next letter resets the flag again")


func test_typing_the_word_does_not_consume_its_letters() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var vp: Viewport = host.get_viewport()
	for c: String in "eatgo":
		vp.push_input(G.latin(c))
		assert_false(vp.is_input_handled(), "'%s' stays gameplay input" % c)
	assert_false(host.session_unlocked, "still locked after five letters")


# ---------------------------------------------------------------- text-field focus guard

## Regression guard (found by test-specialist): GodConsole.open() grabs the line focus deferred; closing the console in the
## same frame (before the deferred call runs) used to leave the focus on the now hidden LineEdit, and from then on
## GodHost._text_field_focused() swallowed the typed word, F1 and the console keys. Fixed by deferring `_focus_line()`,
## which checks `visible` first.
func test_console_closed_in_the_same_frame_leaves_no_hidden_focus() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host.console.open()
	host.console.close()  # same frame: the deferred grab_focus has not run yet
	await _frame()
	await _frame()
	var owner: Control = host.get_viewport().gui_get_focus_owner()
	assert_true(owner == null or not (owner is LineEdit), "no hidden LineEdit keeps the keyboard focus after open+close (focus owner: %s)" % owner)
	host._unhandled_input(G.f1())
	assert_true(host.menu.is_open(), "F1 still works after a console open+close in one frame")


func test_a_focused_line_edit_blocks_the_word_and_the_hotkeys() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var edit := LineEdit.new()
	await _adopt(edit)
	edit.grab_focus()
	await _frame()
	if host.get_viewport().gui_get_focus_owner() != edit:
		print("NOTE test_god_ui: headless viewport did not hand focus to the LineEdit; focus-guard assertions skipped")
		return
	G.host_type(host, "eatgod")
	assert_false(host.session_unlocked, "the word typed into a text field does not unlock")
	host.unlock()
	host.menu.close()
	host._unhandled_input(G.f1())
	assert_false(host.menu.is_open(), "F1 is ignored while a text field has focus")
	host._unhandled_input(G.backtick())
	assert_false(host.console.is_open(), "backtick too")
	edit.release_focus()
	await _frame()
	host._unhandled_input(G.f1())
	assert_true(host.menu.is_open(), "after the focus is gone the hotkey works again")


func test_focus_in_a_text_edit_also_blocks() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var edit := TextEdit.new()
	await _adopt(edit)
	edit.grab_focus()
	await _frame()
	if host.get_viewport().gui_get_focus_owner() != edit:
		return
	G.host_type(host, "eatgod")
	assert_false(host.session_unlocked, "TextEdit focus blocks the word as well")


# ---------------------------------------------------------------- lifecycle

func test_run_ended_closes_tools_quietly_and_clears_the_context() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.console.open()
	assert_true(_tree().paused, "test setup: paused by the console")
	var closed_signals: Array[int] = [0]
	host.console.closed.connect(func() -> void: closed_signals[0] += 1)
	host.run_ended()
	assert_false(host.console.is_open() or host.menu.is_open(), "everything closed")
	assert_eq(closed_signals[0], 0, "no closed signal: Main owns pause / mouse while freeing the run")
	assert_true(_tree().paused, "the host did not touch the pause state (Main unpauses in _free_run)")
	assert_false(host.context.has_run(), "context emptied")
	assert_eq(host.context.player_id, -1, "no stale player id")


func test_new_run_binds_a_fresh_context() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var first: GodContext = host.context
	host.run_ended()
	var loop2 := GameLoop.new()
	await _adopt(loop2)
	loop2.start()
	host.run_started(loop2, rg["run"])
	assert_true(host.context != first, "a new context object")
	assert_true(host.context.world == loop2.world, "pointing at the new world")
	assert_false(first.logged.is_connected(host._on_logged), "the old context no longer drives the console")


# ---------------------------------------------------------------- console / menu through the host

func test_console_commands_reach_the_live_world() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var w: SimWorld = rg["w"]
	host.console.submit("tp cave")
	assert_true(w.get_entity(rg["id"]).position.distance_to(Vector3(-20, -41, 52)) < 0.5, "the console teleported the real player")
	assert_has(host.console.log_text(), "teleported to cave", "answer in the log")
	host.console.submit("god on")
	assert_true(w.debug.god, "god mode set through the console")
	host.console.submit("frobnicate")
	assert_has(host.console.log_text(), "unknown command, try help", "unknown command answered in the log")


func test_menu_and_close_commands_switch_between_the_tools() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	host.unlock()
	host.menu.close()
	host.console.open()
	host.console.submit("menu")
	assert_false(host.console.is_open(), "`menu` closes the console")
	assert_true(host.menu.is_open(), "and opens the F1 menu")
	host.console.open()
	host.console.submit("close")
	assert_false(host.console.is_open(), "`close` closes the console")


func test_menu_commands_tab_has_working_quick_buttons() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var w: SimWorld = rg["w"]
	host.unlock()
	var panel: Control = host.menu.panel_control(&"commands")
	assert_not_null(panel, "commands tab built on open")
	var buttons: Array[Node] = panel.find_children("*", "Button", true, false)
	var by_text: Dictionary = {}
	for b: Node in buttons:
		by_text[(b as Button).text] = b
	assert_true(buttons.size() >= 30, "quick buttons present (%d)" % buttons.size())
	for want: String in ["tp cave", "band 2", "god", "heal", "overlay zones"]:
		assert_true(by_text.has(want), "button '%s'" % want)
	(by_text["tp cave"] as Button).pressed.emit()
	assert_true(w.get_entity(rg["id"]).position.distance_to(Vector3(-20, -41, 52)) < 0.5, "button 'tp cave' teleported the player")
	(by_text["god"] as Button).pressed.emit()
	assert_true(w.debug.god, "button 'god' turned god mode on")
	assert_has(host.console.log_text(), "> tp cave", "button presses are logged to the console")


func test_menu_panels_are_rebuilt_for_a_new_run() -> void:
	var rg: Dictionary = await _rig()
	var host: GodHost = rg["host"]
	var built: Array[int] = [0]
	host.menu.register_panel(&"probe", "Probe", func(ctx: GodContext) -> Control:
		built[0] += 1
		var l := Label.new()
		l.text = "world %s" % (ctx.world != null)
		return l)
	host.unlock()
	assert_eq(built[0], 1, "built on open")
	host.run_ended()
	assert_eq(host.menu.panel_control(&"probe"), null, "run_ended -> set_context discards the built panels")


# ---------------------------------------------------------------- end to end through the real Main

func _wait(cond: Callable, timeout_s: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not bool(cond.call()):
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await _frame()
	return true


func _send(ev: InputEvent) -> void:
	Input.parse_input_event(ev)
	await _frame()


func _tap(ev: InputEventKey) -> void:
	await _send(ev)
	var rel: InputEventKey = ev.duplicate() as InputEventKey
	rel.pressed = false
	await _send(rel)


func _type_through_input(word: String, ru: bool = false) -> void:
	for i: int in word.length():
		await _tap(G.cyrillic(word[i]) if ru else G.latin(word[i]))


func _send_action(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		await _send(ev)


func _state(main: Node) -> String:
	var states: Dictionary = (main.get_script() as Script).get_script_constant_map()["State"]
	return String(states.find_key(main.get("state")))


func test_end_to_end_through_the_real_main_scene() -> void:
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.set(&"settings_path", E2E_SETTINGS)
	await _adopt(main)
	var host: GodHost = main.get("_god") as GodHost
	assert_not_null(host, "Main created the God host (debug build, GodBuild.allowed())")
	if host == null:
		return
	assert_true(host.get_parent() == main, "child of Main")
	assert_eq(host.process_mode, Node.PROCESS_MODE_ALWAYS, "ALWAYS")

	# menu state: the host exists but is inert
	assert_true(await _wait(func() -> bool: return _state(main) == "MENU", WAIT_S), "Main reached the menu")
	await _type_through_input("eatgod")
	await _send(G.f1())
	assert_false(host.session_unlocked or host.menu.is_open(), "in the main menu (no run) the word and F1 do nothing")

	# start the run through the real menu button
	(main.get("main_menu") as MainMenu).play_button.pressed.emit()
	var running: bool = await _wait(func() -> bool: return _state(main) == "RUNNING", LOAD_WAIT_S)
	assert_true(running, "run started through the Play button")
	if not running:
		return
	var loop: GameLoop = main.get("loop") as GameLoop
	var w: SimWorld = loop.world
	assert_true(host.context.has_run() and host.context.world == w, "Main handed the live run to the host (run_started)")
	assert_not_null(host.context.player_input, "PlayerInput found in the map scene")
	assert_not_null(host.context.camera, "CameraRig found in the map scene")

	# locked: F1 / backtick inert
	await _send(G.f1())
	await _send(G.backtick())
	assert_false(host.menu.is_open() or host.console.is_open(), "locked: F1 and backtick do nothing")
	assert_false(_tree().paused, "game still running")

	# typing the word (real input dispatch) unlocks and opens the menu; the letters stayed gameplay input
	await _type_through_input("eatgod")
	assert_true(host.session_unlocked, "unlocked by typing through the viewport")
	assert_true(host.menu.is_open(), "menu opened by the unlock")
	assert_false(_tree().paused, "menu does not pause")

	# F1 / F4 toggle
	await _tap(G.f1())
	assert_false(host.menu.is_open(), "F1 closes")
	await _tap(G.f1())
	assert_true(host.menu.is_open(), "F1 opens")
	await _tap(G.key(0, KEY_F4, true, false, KEY_F4))
	assert_false(host.menu.is_open(), "F4 closes")

	# console: opens on backtick, pauses the tree, Main stays RUNNING; Esc closes it and Main does NOT pause
	await _tap(G.backtick())
	assert_true(host.console.is_open(), "backtick opens the console")
	assert_true(_tree().paused, "tree paused while the console is open")
	assert_eq(_state(main), "RUNNING", "Main's own flow state is untouched")
	await _send_action(&"pause")
	assert_false(host.console.is_open(), "Esc closes the console")
	assert_eq(_state(main), "RUNNING", "Esc did not also pause the game (console consumed it)")
	assert_false(_tree().paused, "tree running again")

	# commands against the live run
	host.console.submit("help")
	assert_has(host.console.log_text(), "commands:", "help prints the registry")
	host.console.submit("tp boat")
	assert_true(w.get_entity(loop.player_id).position.distance_to(Vector3(38, -39, 40)) < 1.0, "tp boat moved the real player")
	host.console.submit("god on")
	host.console.submit("speed 2")
	assert_true(w.debug.god and w.debug.time_scale == 2.0, "flags set on the live world")
	assert_eq(Engine.time_scale, 1.0, "Engine.time_scale untouched by `speed`")
	var t0: int = w.tick
	await _wait(func() -> bool: return w.tick >= t0 + 20, 20.0)
	assert_true(w.tick >= t0 + 20, "the world keeps ticking under speed x2 (tick %d)" % w.tick)

	# Esc with the pause menu: pause, then the console over it keeps the pause on close
	await _send_action(&"pause")
	assert_eq(_state(main), "PAUSED", "Esc pauses the game as before")
	assert_true(_tree().paused, "tree paused")
	await _tap(G.backtick())
	assert_true(host.console.is_open(), "console opens over the pause menu")
	await _tap(G.backtick())
	assert_false(host.console.is_open(), "backtick closes it")
	assert_eq(_state(main), "PAUSED", "still PAUSED")
	assert_true(_tree().paused, "the pause survived the console round trip")
	await _send_action(&"pause")
	assert_eq(_state(main), "RUNNING", "Esc resumes")
	assert_false(_tree().paused, "running")

	# back to the menu: tools closed, context cleared, unlock kept for the session
	host.menu.open()
	await _send_action(&"pause")
	assert_eq(_state(main), "PAUSED", "paused (with the F1 menu open) so that Quit to menu is possible")
	main.call(&"quit_to_menu")
	assert_true(await _wait(func() -> bool: return _state(main) == "MENU" and main.get("run") == null, WAIT_S), "back in the menu")
	assert_false(host.menu.is_open() or host.console.is_open(), "tools closed with the run")
	assert_false(host.context.has_run(), "context cleared")
	assert_true(host.session_unlocked, "unlock is kept for the app session")
	await _tap(G.f1())
	assert_false(host.menu.is_open(), "F1 is inert again in the menu state")
	assert_eq(Engine.time_scale, 1.0, "engine time scale 1")
	assert_false(_tree().paused, "not paused")
	await get_tree_timer(1.0)


func get_tree_timer(seconds: float) -> void:
	await _tree().create_timer(seconds).timeout
