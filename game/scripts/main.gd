extends Node
## Entry scene and game flow (S6): main menu -> run -> pause / victory -> menu. Prints the boot line.
##
## main.tscn keeps the screens (MainMenu, PauseMenu, SettingsMenu, VictoryScreen, TutorialHints, Fade) as children
## and instances `run_scene` (the dressed reef, S5; reef_greybox.tscn stays for the swim tour, tests and as a fallback)
## under `Run`. reef.tscn stays runnable on its own (no menu) for captures and benches.
##  - Play: fade to black, threaded load of `run_scene` (ResourceLoader.load_threaded_request), instance it, wire it
##    (GameLoop.ticked for VICTORY, TutorialHints, the settings onto its PlayerInput), fade in.
##  - `pause` action (Esc) during a run: tree paused (the run is Pausable, the screens Always), mouse released, pause
##    menu (Resume, Settings, Quit to menu). Read in _input, before PlayerInput's own Esc handling. Resume recaptures
##    the mouse unless the world waits for a mutation pick (the pick overlay needs the cursor). Esc in the settings
##    screen goes back.
##  - VICTORY event: tree paused, mouse released, victory screen with the event's run_ticks / deaths / mutations;
##    Play again (fresh run) or Menu.
##  - Settings: GameSettings at `settings_path` (tests inject a scratch path), audio applied on start and live,
##    input applied live to the running PlayerInput, saved when the settings screen closes.
## Capture-only user arg `-- --s6-screen=main_menu|victory`: main_menu = the menu as is; victory = starts a run, after
## CAPTURE_VICTORY_DELAY_S grants CAPTURE_MUTATIONS (Progression.grant) and CAPTURE_BANNER_S later forces the victory
## (SimDebug), so the victory screen shows over the reef. Never used in normal play; ignored in release builds.
## Dev user arg `-- --god-script=<file>` (debug / test builds, GodBuild): starts a run and executes the God script (GodScript).
## Benchmark entry `-- --bench=sim|crowd` (also in release exports: the exported exe cannot be pointed at another
## scene, `--scene` is not available in release templates): replaces main.tscn with res://bench/bench_<name>.tscn,
## which reads its own user args and quits with its exit code (tools/windows/run_benchmarks.bat).

signal state_changed(state: State)

enum State { MENU, LOADING, RUNNING, PAUSED, VICTORY }

const SCREEN_ARG: String = "--s6-screen="
const BENCH_ARG: String = "--bench="
const BENCH_SCENES: Dictionary[String, String] = {
	"sim": "res://bench/bench_sim.tscn",
	"crowd": "res://bench/bench_crowd.tscn",
}
const FADE_S: float = 0.35
const CAPTURE_VICTORY_DELAY_S: float = 2.0
## Capture: time between the grants and the forced victory (the HUD's grant banners finish first).
const CAPTURE_BANNER_S: float = 3.5
const CAPTURE_MUTATIONS: PackedStringArray = ["hunter_bite_power", "hunter_bite_dash", "survivor_efficient_metabolism"]

@export_file("*.tscn") var run_scene: String = "res://scenes/maps/reef.tscn"
@export var settings_path: String = GameSettings.DEFAULT_PATH

var state: State = State.MENU
var settings: GameSettings
## The running map scene (null in the menu).
var run: Node = null
var loop: GameLoop = null

var _god: Node = null  # GodHost (dev tools); null in release exports
var _event_tick: int = 0
var _settings_focus: Button = null  # button that gets the focus back when the settings close
var _fade_tween: Tween

@onready var main_menu: MainMenu = $MainMenu
@onready var pause_menu: PauseMenu = $PauseMenu
@onready var settings_menu: SettingsMenu = $SettingsMenu
@onready var victory_screen: VictoryScreen = $VictoryScreen
@onready var hints: TutorialHints = $TutorialHints
@onready var _run_holder: Node = $Run
@onready var _fade: ColorRect = $Fade/Rect


func _ready() -> void:
	print("fish-game boot OK, Godot %s" % Engine.get_version_info().string)
	var bench: String = _bench_scene()
	if not bench.is_empty():
		get_tree().change_scene_to_file.call_deferred(bench)
		return
	settings = GameSettings.new(settings_path)
	settings.load_file()
	settings.apply_audio()
	main_menu.play_requested.connect(start_run)
	main_menu.settings_requested.connect(open_settings.bind(main_menu.settings_button))
	main_menu.quit_requested.connect(get_tree().quit)
	pause_menu.resume_requested.connect(resume)
	pause_menu.settings_requested.connect(open_settings.bind(pause_menu.settings_button))
	pause_menu.quit_requested.connect(quit_to_menu)
	settings_menu.changed.connect(_on_settings_changed)
	settings_menu.closed.connect(_on_settings_closed)
	victory_screen.play_again_requested.connect(start_run)
	victory_screen.menu_requested.connect(quit_to_menu)
	pause_menu.close()
	settings_menu.visible = false
	victory_screen.close()
	if GodBuild.allowed():  # debug / test builds only; loaded by path so a release export holds no reference
		_god = (load("res://scripts/ui/god_host.gd") as GDScript).new() as Node
		add_child(_god)
		_god.call(&"setup", self)
	main_menu.open()
	if _screen_arg() == "victory":
		_capture_victory()
	elif _god != null and not GodBuild.script_arg().is_empty():
		_run_god_script(GodBuild.script_arg())


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause") or event.is_echo():
		return
	if _god != null and _god.call(&"consumes_pause"):
		return  # Esc closes the God console first
	if settings_menu.visible:
		settings_menu.close()
	elif state == State.RUNNING:
		pause()
	elif state == State.PAUSED:
		resume()
	else:
		return
	get_viewport().set_input_as_handled()


## Menu / victory -> a fresh run (fade, threaded load, wire, fade in).
func start_run() -> void:
	if state == State.LOADING or state == State.RUNNING or state == State.PAUSED:
		return
	_set_state(State.LOADING)
	await _fade_to(1.0)
	_free_run()
	main_menu.close()
	victory_screen.close()
	await get_tree().process_frame  # the old run is gone before the new one starts
	var err: Error = ResourceLoader.load_threaded_request(run_scene)
	var packed: PackedScene = null
	if err == OK:
		while ResourceLoader.load_threaded_get_status(run_scene) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
		packed = ResourceLoader.load_threaded_get(run_scene) as PackedScene
	if packed == null:
		push_error("main: could not load %s" % run_scene)
		_back_to_menu()
		await _fade_to(0.0)  # the fade is black here: show the menu again
		return
	run = packed.instantiate()
	_run_holder.add_child(run)  # the map's _ready starts the GameLoop and the views
	loop = run.get_node_or_null(^"GameLoop") as GameLoop
	if loop == null or loop.world == null:
		push_error("main: %s has no running GameLoop" % run_scene)
		_free_run()
		_back_to_menu()
		await _fade_to(0.0)
		return
	loop.ticked.connect(_on_ticked)
	_event_tick = loop.world.tick
	settings.apply_input(player_input())
	hints.setup(loop, loop.player_id)
	_set_state(State.RUNNING)
	if _god != null:
		_god.call(&"run_started", loop, run)
	await _fade_to(0.0)


func pause() -> void:
	if state != State.RUNNING:
		return
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	pause_menu.open()
	_set_state(State.PAUSED)


func resume() -> void:
	if state != State.PAUSED:
		return
	settings_menu.visible = false
	pause_menu.close()
	get_tree().paused = false
	if loop != null and loop.world != null and not loop.world.paused_for_pick:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_state(State.RUNNING)


## Pause / victory -> main menu (fade, run freed).
func quit_to_menu() -> void:
	if state != State.PAUSED and state != State.VICTORY:
		return
	_set_state(State.LOADING)
	await _fade_to(1.0)
	_free_run()
	pause_menu.close()
	settings_menu.visible = false
	victory_screen.close()
	_back_to_menu()
	await _fade_to(0.0)


## Shows the settings screen over the main menu or the pause menu (its dim blocks their clicks, its panel covers
## them); `focus` gets the focus back when it closes.
func open_settings(focus: Button) -> void:
	_settings_focus = focus
	settings_menu.open(settings)


## The running map's PlayerInput (null when none).
func player_input() -> PlayerInput:
	return run.get_node_or_null(^"PlayerInput") as PlayerInput if run != null else null


func _on_settings_changed() -> void:
	settings.apply_input(player_input())


func _on_settings_closed() -> void:
	if _settings_focus != null and _settings_focus.is_visible_in_tree():
		_settings_focus.grab_focus.call_deferred()
	_settings_focus = null


func _on_ticked(tick: int) -> void:
	if tick == _event_tick or loop == null:
		return  # a world paused for a pick re-emits `ticked` with the same tick
	for ev: SimEvent in loop.world.events_since(_event_tick):
		if ev.type == SimEvent.Type.VICTORY:
			_on_victory(ev)
	_event_tick = tick


func _on_victory(ev: SimEvent) -> void:
	if state != State.RUNNING and state != State.PAUSED:
		return
	pause_menu.close()
	settings_menu.visible = false
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var muts: Variant = ev.data.get("mutations", PackedStringArray())
	victory_screen.show_result(int(ev.data.get("run_ticks", loop.world.run_ticks)), int(ev.data.get("deaths", 0)),
		PackedStringArray(muts) if muts is PackedStringArray or muts is Array else PackedStringArray(), loop.world.content)
	_set_state(State.VICTORY)


func _free_run() -> void:
	hints.clear()
	if _god != null:
		_god.call(&"run_ended")
	get_tree().paused = false
	Engine.time_scale = 1.0
	if loop != null and loop.ticked.is_connected(_on_ticked):
		loop.ticked.disconnect(_on_ticked)
	if run != null:
		run.queue_free()  # PlayerInput._exit_tree releases the mouse
	run = null
	loop = null


func _back_to_menu() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main_menu.open()
	_set_state(State.MENU)


func _set_state(s: State) -> void:
	state = s
	_fade.mouse_filter = Control.MOUSE_FILTER_STOP if s == State.LOADING else Control.MOUSE_FILTER_IGNORE
	state_changed.emit(s)


func _fade_to(alpha: float) -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween().set_ignore_time_scale(true)
	_fade_tween.tween_property(_fade, ^"color:a", alpha, FADE_S)
	await _fade_tween.finished


# Scene of `--bench=<name>` ("" when absent; unknown names warn and start the game normally).
static func _bench_scene() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(BENCH_ARG):
			var bench_name: String = arg.trim_prefix(BENCH_ARG)
			if BENCH_SCENES.has(bench_name):
				return BENCH_SCENES[bench_name]
			push_warning("main: unknown %s (expected one of %s)" % [arg, ", ".join(BENCH_SCENES.keys())])
	return ""


static func _screen_arg() -> String:
	if not OS.is_debug_build():
		return ""  # capture fixtures (SimDebug) are never reachable from a release export
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(SCREEN_ARG):
			return arg.trim_prefix(SCREEN_ARG)
	return ""


# Dev only (--god-script=<file>, GodBuild.script_arg): a run starts by itself, then the God host executes the file once.
func _run_god_script(path: String) -> void:
	await start_run()
	if loop != null:
		_god.call(&"run_script", path)


# Capture only (--s6-screen=victory): a run with three granted mutations, then a forced victory.
func _capture_victory() -> void:
	await start_run()
	if loop == null:
		return
	await get_tree().create_timer(CAPTURE_VICTORY_DELAY_S, false).timeout
	var e: SimEntity = loop.world.get_entity(loop.player_id)
	for id: String in CAPTURE_MUTATIONS:
		Progression.grant(loop.world, e, id)
	await get_tree().create_timer(CAPTURE_BANNER_S, false).timeout
	if loop != null:
		SimDebug.force_victory(loop.world, loop.player_id)
