class_name GodHost
extends Node
## Owner of the dev tools (God menu, console, command registry); the only thing `Main` talks to. Created by `Main` only
## when `GodBuild.allowed()` (debug / test builds), through `load("res://scripts/ui/god_host.gd")` so the main script
## holds no hard reference to it. Child of Main, `PROCESS_MODE_ALWAYS` (keeps working while the tree is paused).
##
## API for Main: `setup(main)`, `run_started(loop, run)`, `run_ended()`, `consumes_pause()`.
## Flow: typing a dev word (data/god/typed_words.json, default `eatgod`) while a run exists unlocks the session (in memory
## only, never saved; the word opens the menu); afterwards the menu keys toggle the F1 menu and the console keys the `~`
## console. Words are read in `_unhandled_input`, so a focused text field starves them (plus an explicit focus check);
## letter keys are never consumed, only the menu / console hotkeys are.
##
## Pause and mouse: the menu does NOT pause the tree (live tuning) and releases the mouse while open. The console pauses
## the tree (PlayerInput polls the keyboard, typing a command must not steer the fish) and on close restores the paused
## state it found; the mouse is recaptured only when the run was running, no menu is open and no mutation pick waits.

signal unlocked

## Seconds -> the matcher clock.
const USEC_PER_S: float = 1000000.0

var data: TypedWords = null
var matcher: TypedWordMatcher = TypedWordMatcher.new()
var commands: GodCommands = GodCommands.new()
var menu: GodMenu = null
var console: GodConsole = null
## Context of the current run (an empty one between runs).
var context: GodContext = GodContext.new()
var session_unlocked: bool = false

var _main: Node = null
var _prev_paused: bool = false


## Builds the menu and the console and loads the word / key data. Call once, after adding the host to the tree.
func setup(main: Node) -> void:
	_main = main
	process_mode = Node.PROCESS_MODE_ALWAYS
	data = TypedWords.load_file()
	for err: String in data.errors:
		push_error("god: %s" % err)
	matcher.setup(data.words_of_kind("dev"))
	commands = GodCommands.with_builtins()
	GodSimCommands.register_all(commands)
	menu = GodMenu.new()
	menu.set_commands(commands)
	menu.opened.connect(_on_menu_opened)
	menu.closed.connect(_on_menu_closed)
	menu.console_requested.connect(_open_console)
	add_child(menu)
	console = GodConsole.new()
	console.commands = commands
	console.close_keys = data.console_keys
	console.opened.connect(_on_console_opened)
	console.closed.connect(_on_console_closed)
	add_child(console)
	_bind_context(context)


## A run exists: hand the tools the live world and the nodes of the map.
func run_started(loop: GameLoop, run: Node) -> void:
	var ctx: GodContext = GodContext.new()
	ctx.world = loop.world
	ctx.player_id = loop.player_id
	ctx.loop = loop
	ctx.run = run
	ctx.main = _main
	ctx.player_input = run.get_node_or_null(^"PlayerInput") as PlayerInput
	ctx.camera = run.get_node_or_null(^"CameraRig") as CameraRig
	_bind_context(ctx)


## The run is being freed (Main unpauses and frees it itself): close the tools without touching pause or mouse.
func run_ended() -> void:
	_quiet_close()
	_bind_context(GodContext.new())


## True while Esc belongs to the console (Main must not pause the game on it).
func consumes_pause() -> bool:
	return console != null and console.is_open()


## Unlocks the session and opens the menu. Refused (false) while no run exists. Idempotent.
func unlock() -> bool:
	if not context.has_run():
		return false
	if not session_unlocked:
		session_unlocked = true
		console.print_line("God tools unlocked: %s menu, %s console." % [_key_hint(data.menu_keys.physical), "~"])
		unlocked.emit()
	menu.open()
	return true


## Runs a `--god-script` file (see GodScript) against the current run; prints the problems that stopped it. Async.
func run_script(path: String) -> void:
	var problems: PackedStringArray = await GodScript.run_file(self, path)
	for p: String in problems:
		push_error("god-script: %s" % p)
	if problems.is_empty():
		print("god-script: finished %s" % path)
	elif DisplayServer.get_name() == "headless":
		get_tree().quit(1)  # a scripted headless run must not hang after a failed script


func _unhandled_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or data == null or not context.has_run() or _text_field_focused():
		return
	if not session_unlocked:
		if matcher.feed_event(key, Time.get_ticks_usec() / USEC_PER_S) != &"":
			unlock()
		return  # letter keys stay gameplay input
	if console.is_open():
		return
	if data.menu_keys.matches(key):
		menu.toggle()
		get_viewport().set_input_as_handled()
	elif data.console_keys.matches(key):
		console.open()
		get_viewport().set_input_as_handled()


func _bind_context(ctx: GodContext) -> void:
	if context.logged.is_connected(_on_logged):
		context.logged.disconnect(_on_logged)
		context.clear_requested.disconnect(console.clear)
		context.menu_requested.disconnect(_on_menu_requested)
		context.close_requested.disconnect(console.close)
	context = ctx
	context.logged.connect(_on_logged)
	context.clear_requested.connect(console.clear)
	context.menu_requested.connect(_on_menu_requested)
	context.close_requested.connect(console.close)
	console.context = ctx
	menu.set_context(ctx)


func _on_logged(text: String) -> void:
	console.print_line(text)


func _on_menu_requested() -> void:
	console.close()
	menu.open()


func _open_console() -> void:
	console.open()


func _on_menu_opened() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_menu_closed() -> void:
	_recapture_mouse_if_running()


func _on_console_opened() -> void:
	_prev_paused = get_tree().paused
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_console_closed() -> void:
	if _main_state() != "VICTORY":
		get_tree().paused = _prev_paused
	_recapture_mouse_if_running()


# Mouse back to CAPTURED only when the run is running (tree not paused), no menu is open and no mutation pick waits.
func _recapture_mouse_if_running() -> void:
	if get_tree().paused or menu.is_open() or console.is_open() or not context.has_run():
		return
	if context.world.paused_for_pick:
		return
	var st: String = _main_state()
	if st == "" or st == "RUNNING":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Hides menu and console without emitting their closed signals (so pause and mouse stay as Main left them).
func _quiet_close() -> void:
	if console.is_open():
		console.hide_quietly()
	if menu.is_open():
		menu.visible = false


# Name of Main's State enum value ("RUNNING", "PAUSED", ...); "" when `main` has no `state` (tests, stubs).
func _main_state() -> String:
	if _main == null or not ("state" in _main):
		return ""
	var script: Script = _main.get_script() as Script
	if script == null:
		return ""
	var states: Variant = script.get_script_constant_map().get("State")
	if not (states is Dictionary):
		return ""
	return String((states as Dictionary).find_key(_main.get("state")))


func _text_field_focused() -> bool:
	if not is_inside_tree():
		return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


static func _key_hint(codes: PackedInt32Array) -> String:
	var names: PackedStringArray = []
	for c: int in codes:
		names.append(OS.get_keycode_string(c as Key))
	return "/".join(names)
