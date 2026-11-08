extends TestCase
## T1.3 tuning lab, UI half: the `tuning` tab of the God menu is a real panel (built through the existing GodMenu
## panel registry with a GodContext, like the other God tests), its controls read and write the live overrides through
## the sim (observed by the sim, never by private names), the console works through a real GodHost, one journey runs
## through the real res://scenes/main.tscn, and the dev-only gate is respected in the source tree.
## Panel controls are located by their Godot class and range (min / max / step of the registry row), not by node names.

const TS := preload("res://tests/tuning_support.gd")
const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")

const MAIN_SCENE: String = "res://scenes/main.tscn"
const E2E_SETTINGS: String = "user://test_tuning_e2e_settings.cfg"
const WAIT_S: float = 30.0
const LOAD_WAIT_S: float = 90.0
## Files allowed to mention the tuning classes (everything else must stay unaware of the dev tools).
const TUNING_AWARE: Array[String] = [
	"tuning_overrides.gd", "tuning_panel.gd", "sim_debug.gd", "sim_world.gd", "god_menu.gd", "god_sim_commands.gd", "god_host.gd", "god_context.gd",
]

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


func _wait(cond: Callable, timeout_s: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not bool(cond.call()):
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await _frame()
	return true


## {"menu", "w", "p", "ctx", "rg"}: a God menu over a composite rig world; the tuning panel is built (menu opened).
func _menu_rig(lines: Array = []) -> Dictionary:
	var rg: Dictionary = TS.composite_rig({}, lines)
	var ctx: GodContext = G.context(rg["w"], (rg["p"] as SimEntity).id)
	var m := GodMenu.new()
	await _adopt(m)
	m.set_commands(TS.commands())
	m.set_context(ctx)
	m.open()
	return {"menu": m, "w": rg["w"], "p": rg["p"], "ctx": ctx, "rg": rg}


func _panel(m: GodMenu) -> Control:
	return m.panel_control(&"tuning")


func _same(a: float, b: float) -> bool:
	return absf(a - b) <= 1e-6 * maxf(1.0, absf(b))


## Sliders of `root` whose range equals the registry row's.
func _sliders_for(root: Node, e: Dictionary) -> Array[Slider]:
	var out: Array[Slider] = []
	for n: Node in TS.find_all(root, "Slider"):
		var s: Slider = n as Slider
		if _same(s.min_value, float(e.get("min", 0.0))) and _same(s.max_value, float(e.get("max", 1.0))) and _same(s.step, float(e.get("step", 0.1))):
			out.append(s)
	return out


func _rows_with_range(e: Dictionary) -> int:
	var n: int = 0
	for o: Dictionary in TS.entries():
		if _same(float(o.get("min", 0.0)), float(e.get("min", 0.0))) and _same(float(o.get("max", 0.0)), float(e.get("max", 1.0))) \
				and _same(float(o.get("step", 0.0)), float(e.get("step", 0.1))):
			n += 1
	return n


## First of the bite rows (those the composite scenario is sensitive to) whose slider range is unique among rows and panel.
func _unique_bite_row(panel: Control) -> Dictionary:
	for p: String in ["bite_reach_mult", "bite_cone_deg", "bite_miss_cooldown_s", "bite_cooldown_s"]:
		var e: Dictionary = TS.entry_for("rules", p)
		if not e.is_empty() and _rows_with_range(e) == 1 and _sliders_for(panel, e).size() == 1:
			return e
	return {}


func _button(root: Node, needle: String) -> Button:
	for n: Node in TS.find_all(root, "Button"):
		var b: Button = n as Button
		if b.text.to_lower().contains(needle) or b.tooltip_text.to_lower().contains(needle):
			return b
	return null


# ======================================================================= the panel in the God menu

func test_the_tuning_tab_is_a_real_panel_and_not_the_stub() -> void:
	var r: Dictionary = await _menu_rig()
	var m: GodMenu = r["menu"]
	assert_true(m.has_panel(&"tuning"), "the `tuning` id is still registered")
	var panel: Control = _panel(m)
	assert_not_null(panel, "the panel is built when the menu opens")
	if panel == null:
		return
	assert_false(TS.all_text(panel).contains("arrive with T1.3"), "the stub text is gone")
	assert_true(TS.find_all(panel, "Slider").size() > 0, "it holds sliders")
	var tabs: TabContainer = m.find_child("Tabs", true, false) as TabContainer
	if tabs != null:
		for i in tabs.get_tab_count():
			assert_false(tabs.get_tab_title(i).contains("(T1.3)"), "the tab title no longer says (T1.3)")


func test_one_slider_per_registry_row_with_the_registry_range() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var sliders: Array[Node] = TS.find_all(panel, "Slider")
	assert_eq(sliders.size(), TS.entries().size(), "as many sliders as registry rows")
	for e: Dictionary in TS.entries():
		assert_true(_sliders_for(panel, e).size() >= 1, "a slider with the range of %s [%s, %s] step %s" % [e.get("id"), e.get("min"), e.get("max"), e.get("step")])


func test_the_panel_shows_every_label_and_group() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var text: String = TS.all_text(panel)
	for e: Dictionary in TS.entries():
		assert_has(text, str(e.get("label", "")), "label of %s" % e.get("id"))
		assert_has(text, str(e.get("group", "")), "group of %s" % e.get("id"))


func test_sliders_reflect_the_live_world() -> void:
	var alt: float = TS.alt_value(TS.entry_for("rules", "bite_cone_deg"), S3.content())
	var line: String = "tune %s %s" % [TS.id_for("rules", "bite_cone_deg"), TS.fmt(alt)]
	var r: Dictionary = await _menu_rig([line])
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var cone: Dictionary = TS.entry_for("rules", "bite_cone_deg")
	var s: Array[Slider] = _sliders_for(panel, cone)
	if _rows_with_range(cone) != 1 or s.size() != 1:
		fail("bite_cone_deg needs a unique slider range for this check (rows %d, sliders %d)" % [_rows_with_range(cone), s.size()])
		return
	assert_almost_eq(s[0].value, alt, 1e-4, "the slider of an overridden row shows the override")
	var reach: Dictionary = TS.entry_for("rules", "bite_reach_mult")
	var s2: Array[Slider] = _sliders_for(panel, reach)
	if _rows_with_range(reach) == 1 and s2.size() == 1:
		assert_almost_eq(s2[0].value, S3.rule_f(S3.content(), "bite_reach_mult"), 1e-4, "an untouched row shows the data value")


func test_moving_a_slider_overrides_the_live_sim_through_the_data_path() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var e: Dictionary = _unique_bite_row(panel)
	if e.is_empty():
		fail("no bite row has a unique slider range in the panel (adapt the test or give the rows distinct ranges)")
		return
	var path: String = str(e.get("path"))
	var alt: float = TS.alt_value(e, S3.content())
	var s: Slider = _sliders_for(panel, e)[0]
	s.value = alt
	var data_side: Dictionary = TS.composite({"rules": {path: alt}}, [])
	var got: Dictionary = TS.composite_run(r["rg"])
	assert_eq(got["trace"], data_side["trace"], "slider %s -> %s: the world behaves as if the data said so" % [e.get("id"), alt])
	assert_ne(got["trace"], TS.composite({}, [])["trace"], "and differs from the baseline (self-check)")
	assert_has(TS.tune(TS.commands(), r["w"], (r["p"] as SimEntity).id, "tune list"), TS.fmt(alt), "the console sees the slider's value")


func test_reset_all_returns_the_sim_and_the_sliders_to_the_data() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var e: Dictionary = _unique_bite_row(panel)
	if e.is_empty():
		fail("no bite row has a unique slider range in the panel")
		return
	var s: Slider = _sliders_for(panel, e)[0]
	var data_value: float = s.value
	s.value = TS.alt_value(e, S3.content())
	var reset_all: Button = _button(panel, "reset all")
	assert_not_null(reset_all, "a `reset all` button (text or tooltip)")
	if reset_all == null:
		return
	reset_all.pressed.emit()
	assert_almost_eq(s.value, data_value, 1e-4, "the slider went back to the data value")
	assert_eq(TS.composite_run(r["rg"])["trace"], TS.composite({}, [])["trace"], "and the sim is the baseline again")


func test_every_row_has_a_reset_and_a_numeric_entry() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var rows: int = TS.entries().size()
	assert_true(TS.find_all(panel, "Button").size() >= rows + 1, "a reset button per slider plus `reset all` (buttons: %d, rows: %d)" % [TS.find_all(panel, "Button").size(), rows])
	var numeric: int = TS.find_all(panel, "SpinBox").size() + TS.find_all(panel, "LineEdit").size()
	assert_true(numeric >= rows, "a numeric entry per slider (SpinBox / LineEdit: %d, rows: %d)" % [numeric, rows])


func test_a_numeric_entry_sets_the_override() -> void:
	var r: Dictionary = await _menu_rig()
	var panel: Control = _panel(r["menu"])
	if panel == null:
		fail("tuning panel missing")
		return
	var e: Dictionary = _unique_bite_row(panel)
	if e.is_empty():
		fail("no bite row has a unique slider range in the panel")
		return
	var alt: float = TS.alt_value(e, S3.content())
	var done: bool = false
	for n: Node in TS.find_all(panel, "SpinBox"):
		var sb: SpinBox = n as SpinBox
		if _same(sb.min_value, float(e.get("min", 0.0))) and _same(sb.max_value, float(e.get("max", 1.0))) and _same(sb.step, float(e.get("step", 0.1))):
			sb.value = alt
			done = true
			break
	if not done:
		# LineEdit based entry: there is no way to tell which field belongs to which row without names, so this check
		# only runs for SpinBox panels (the count check above still demands one numeric entry per row).
		return
	assert_eq(TS.composite_run(r["rg"])["trace"], TS.composite({"rules": {str(e.get("path")): alt}}, [])["trace"], "typing %s into the numeric field overrides the sim" % alt)


func test_the_panel_builds_without_a_run() -> void:
	var m := GodMenu.new()
	await _adopt(m)
	m.set_commands(TS.commands())
	m.set_context(GodContext.new())
	m.open()
	var panel: Control = _panel(m)
	assert_not_null(panel, "no world: the panel still builds (it explains instead of crashing)")
	assert_true(m.is_open(), "menu open")


func test_a_new_run_context_rebuilds_the_panel_with_clean_sliders() -> void:
	var alt_line: String = "tune %s %s" % [TS.id_for("rules", "bite_cone_deg"), TS.fmt(TS.alt_value(TS.entry_for("rules", "bite_cone_deg"), S3.content()))]
	var r: Dictionary = await _menu_rig([alt_line])
	var m: GodMenu = r["menu"]
	var fresh: Dictionary = TS.composite_rig({}, [])
	m.set_context(G.context(fresh["w"], (fresh["p"] as SimEntity).id))
	var panel: Control = _panel(m)
	if panel == null:
		fail("tuning panel missing after set_context")
		return
	var cone: Dictionary = TS.entry_for("rules", "bite_cone_deg")
	var s: Array[Slider] = _sliders_for(panel, cone)
	if _rows_with_range(cone) != 1 or s.size() != 1:
		fail("bite_cone_deg needs a unique slider range for this check")
		return
	assert_almost_eq(s[0].value, S3.rule_f(S3.content(), "bite_cone_deg"), 1e-4, "the new run's slider shows the data value: overrides do not leak between runs")


# ======================================================================= dev-only gate (source tree)

func test_the_panel_talks_to_the_sim_only_through_debug_hooks() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/ui/tuning_panel.gd")
	assert_false(src.is_empty(), "res://scripts/ui/tuning_panel.gd exists")
	for bad: String in ["world._", "._p_speed", "._p_turn", "._p_accel", "._p_drag", "._p_brake", "SimWorld.new", "content.rules()["]:
		assert_false(src.contains(bad), "the panel never touches `%s` (UI -> SimDebug / commands only)" % bad)


func test_only_the_god_code_knows_the_tuning_classes() -> void:
	var offenders: Array[String] = []
	for dir: String in ["res://scripts", "res://scenes"]:
		for f: String in TS.files_below(dir):
			if not (f.ends_with(".gd") or f.ends_with(".tscn")):
				continue
			if f.get_file() in TUNING_AWARE or f.get_file().begins_with("tuning_"):
				continue
			var text: String = FileAccess.get_file_as_string(dir.path_join(f))
			if text.contains("TuningOverrides") or text.contains("TuningPanel") or text.contains("tuning_overrides") or text.contains("tuning_panel"):
				offenders.append(dir.path_join(f))
	assert_eq(offenders.size(), 0, "no gameplay / presentation script references the tuning layer (got %s)" % [offenders])


func test_main_reaches_the_tuning_layer_only_through_the_gated_host() -> void:
	var main_src: String = FileAccess.get_file_as_string("res://scripts/main.gd")
	assert_false(main_src.contains("Tuning") or main_src.contains("tuning"), "main.gd does not mention the tuning tools at all")
	assert_true(main_src.contains("GodBuild.allowed()"), "main.gd still builds the host behind GodBuild.allowed()")


func test_the_god_gate_is_off_for_a_release_build() -> void:
	assert_false(GodBuild.allowed(false, false), "release export without the god_menu tag: no dev tools (so no tuning commands, panel or overrides)")
	assert_true(GodBuild.allowed(true, false), "debug build: allowed")


# ======================================================================= through a real GodHost

## {"host", "loop", "run", "w", "id"} as in test_god_ui.gd.
func _host_rig() -> Dictionary:
	var host := GodHost.new()
	await _adopt(host)
	var stub := Node.new()
	await _adopt(stub)
	host.setup(stub)
	var loop := GameLoop.new()
	await _adopt(loop)
	assert_true(loop.start(), "GameLoop starts")
	var run := Node3D.new()
	await _adopt(run)
	host.run_started(loop, run)
	return {"host": host, "loop": loop, "run": run, "w": loop.world, "id": loop.player_id}


func _turn_delta(w: SimWorld, id: int) -> float:
	var e: SimEntity = w.get_entity(id)
	var dir: Vector3 = e.heading.rotated(Vector3.UP, deg_to_rad(90.0))
	w.submit(SimCommand.move(id, dir, 0.0))
	var before: Vector3 = e.heading
	w.step()
	return before.angle_to(e.heading)


func test_console_tune_through_a_real_host_changes_the_live_world() -> void:
	var rg: Dictionary = await _host_rig()
	var host: GodHost = rg["host"]
	var w: SimWorld = rg["w"]
	var id: int = rg["id"]
	assert_true(host.commands.has_command(&"tune"), "the host registry has tune")
	var e: Dictionary = TS.entry_for("band", "turn_rate_deg_s")
	var alt: float = TS.alt_value(e, S3.content())
	var band: Dictionary = w.content.get_band(w.get_entity(id).band)
	var data_turn: float = float(band["turn_rate_deg_s"])
	var plain: float = _turn_delta(w, id)
	assert_almost_eq(plain, deg_to_rad(data_turn) / 30.0, 1e-4, "before tuning: the data turn rate")
	host.console.submit("tune %s %s" % [e.get("id"), TS.fmt(alt)])
	assert_has(host.console.log_text(), str(e.get("id")), "the answer is in the console log")
	assert_almost_eq(_turn_delta(w, id), deg_to_rad(alt) / 30.0, 1e-4, "next tick: the overridden turn rate")
	host.console.submit("tune reset")
	assert_almost_eq(_turn_delta(w, id), deg_to_rad(data_turn) / 30.0, 1e-4, "`tune reset`: the data turn rate again")


func test_the_menu_of_a_real_host_builds_the_panel_for_the_live_run() -> void:
	var rg: Dictionary = await _host_rig()
	var host: GodHost = rg["host"]
	host.unlock()
	var panel: Control = host.menu.panel_control(&"tuning")
	assert_not_null(panel, "the tuning tab is built on unlock / open")
	if panel == null:
		return
	assert_eq(TS.find_all(panel, "Slider").size(), TS.entries().size(), "one slider per row")
	assert_false(_tree().paused, "the menu does not pause (live tuning)")


# ======================================================================= one journey through the real main scene

func _send(ev: InputEvent) -> void:
	Input.parse_input_event(ev)
	await _frame()


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
	assert_true(await _wait(func() -> bool: return _state(main) == "MENU", WAIT_S), "Main reached the menu")
	(main.get("main_menu") as MainMenu).play_button.pressed.emit()
	var running: bool = await _wait(func() -> bool: return _state(main) == "RUNNING", LOAD_WAIT_S)
	assert_true(running, "run started through the Play button")
	if not running:
		return
	var loop: GameLoop = main.get("loop") as GameLoop
	var w: SimWorld = loop.world
	var id: int = loop.player_id
	assert_true(host.unlock(), "unlocked")
	var panel: Control = host.menu.panel_control(&"tuning")
	assert_not_null(panel, "the tuning tab exists in the real menu")
	if panel != null:
		assert_eq(TS.find_all(panel, "Slider").size(), TS.entries().size(), "one slider per registry row")
	var e: Dictionary = TS.entry_for("band", "turn_rate_deg_s")
	var alt: float = TS.alt_value(e, S3.content())
	host.console.submit("tune %s %s" % [e.get("id"), TS.fmt(alt)])
	assert_almost_eq(_turn_delta(w, id), deg_to_rad(alt) / 30.0, 1e-4, "the live run turns at the overridden rate on the next tick")
	host.console.submit("tune reset")
	assert_eq(Engine.time_scale, 1.0, "engine time scale untouched")
	host.menu.open()
	await _send_action(&"pause")
	assert_eq(_state(main), "PAUSED", "paused (Quit to menu is possible from the pause menu)")
	main.call(&"quit_to_menu")
	assert_true(await _wait(func() -> bool: return _state(main) == "MENU" and main.get("run") == null, WAIT_S), "back in the menu")
	assert_false(host.menu.is_open() or host.console.is_open(), "tools closed with the run")
