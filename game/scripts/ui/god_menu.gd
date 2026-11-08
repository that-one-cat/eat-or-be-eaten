class_name GodMenu
extends CanvasLayer
## The F1 God menu (dev builds only, created by GodHost): a side panel with one tab per registered panel. Does NOT
## pause the tree, so sliders can be tuned live while swimming; GodHost releases / recaptures the mouse on `opened` /
## `closed`. Controls are built in code (theme `res://ui/theme/main_theme.tres` when it exists), panels use
## mouse_filter STOP so a click on them never reaches the game.
##
## Extending: `register_panel(id, title, builder)` with `builder: Callable(ctx: GodContext) -> Control`. The control is built
## lazily, on the first open of a run (and again after `set_context` clears the run's panels), so a builder can read the
## live world through `ctx`. Registering an id again replaces the older panel. T1.1 ships the stub `gallery` (T5.3) and
## `commands` (generated from the registry); `tuning` is the T1.3 slider panel (`TuningPanel.build`).

signal opened
signal closed
## The Commands tab's button: the host opens the console.
signal console_requested

const THEME_PATH: String = "res://ui/theme/main_theme.tres"
const LAYER: int = 30
const PANEL_WIDTH: float = 460.0
const MARGIN: float = 12.0

var _panels: Dictionary = {}  # StringName -> {title: String, builder: Callable, holder: MarginContainer}
var _order: Array[StringName] = []
var _context: GodContext = null
var _commands: GodCommands = null
var _tabs: TabContainer
var _root: Control
var _result: Label = null  # answer line of the Commands tab


func _init() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		_root.theme = load(THEME_PATH) as Theme
	add_child(_root)
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -(PANEL_WIDTH + MARGIN)
	panel.offset_right = -MARGIN
	panel.offset_top = MARGIN
	panel.offset_bottom = -MARGIN
	_root.add_child(panel)
	var box: VBoxContainer = VBoxContainer.new()
	panel.add_child(box)
	var header: HBoxContainer = HBoxContainer.new()
	box.add_child(header)
	var title: Label = Label.new()
	title.text = "God menu (F1)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button: Button = Button.new()
	close_button.text = "Close"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)
	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_tabs)
	register_panel(&"commands", "Commands", _build_commands_panel)
	register_panel(&"tuning", "Tuning", TuningPanel.build)
	register_panel(&"gallery", "Gallery (T5.3)", _stub_builder.bind("The creature gallery arrives with T5.3."))


## Adds a tab, or replaces the panel with the same `id`. `builder`: Callable(ctx: GodContext) -> Control.
func register_panel(id: StringName, title: String, builder: Callable) -> void:
	var slot: int = _order.size()
	if _panels.has(id):
		var old: MarginContainer = _panels[id]["holder"]
		slot = old.get_index()
		_tabs.remove_child(old)
		old.queue_free()
		_order.erase(id)
	var holder: MarginContainer = MarginContainer.new()
	holder.name = String(id)
	_tabs.add_child(holder)
	_tabs.move_child(holder, slot)
	_tabs.set_tab_title(slot, title)
	_panels[id] = {"title": title, "builder": builder, "holder": holder}
	_order.insert(slot, id)
	if visible:
		_build_pending()


func has_panel(id: StringName) -> bool:
	return _panels.has(id)


## Registered panel ids in tab order.
func panel_ids() -> Array[StringName]:
	return _order.duplicate()


## The control a panel built (null before its first build or for an unknown id).
func panel_control(id: StringName) -> Control:
	if not _panels.has(id):
		return null
	var holder: MarginContainer = _panels[id]["holder"]
	return holder.get_child(0) as Control if holder.get_child_count() > 0 else null


## The registry the Commands tab lists.
func set_commands(commands: GodCommands) -> void:
	_commands = commands


## New run context: every built panel is discarded and rebuilt on the next open.
func set_context(ctx: GodContext) -> void:
	_context = ctx
	for id: StringName in _panels:
		var holder: MarginContainer = _panels[id]["holder"]
		for child: Node in holder.get_children():
			holder.remove_child(child)
			child.queue_free()
	if visible:
		_build_pending()


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	_build_pending()
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _build_pending() -> void:
	for id: StringName in _order:
		var holder: MarginContainer = _panels[id]["holder"]
		if holder.get_child_count() > 0:
			continue
		var builder: Callable = _panels[id]["builder"]
		var built: Control = null
		if builder.is_valid():
			built = builder.call(_context) as Control
		if built == null:
			built = _label("panel '%s' failed to build" % id)
		holder.add_child(built)


func _stub_builder(_ctx: GodContext, text: String) -> Control:
	return _label(text)


func _build_commands_panel(ctx: GodContext) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	var open_console: Button = Button.new()
	open_console.text = "Open console (~)"
	open_console.focus_mode = Control.FOCUS_NONE  # a focused button would fire again on Space / Enter while swimming
	open_console.pressed.connect(console_requested.emit)
	box.add_child(open_console)
	_result = _label("Press a button to run its command; the answer shows here (and in the console log).")
	box.add_child(_result)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var rows: VBoxContainer = VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	if _commands != null:
		var quick: PackedStringArray = _commands.quick_lines(ctx)
		if not quick.is_empty():
			rows.add_child(_label("Quick actions"))
			var flow: HFlowContainer = HFlowContainer.new()
			flow.name = "Quick"
			flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			rows.add_child(flow)
			for line: String in quick:
				var b: Button = Button.new()
				b.text = line
				b.focus_mode = Control.FOCUS_NONE
				b.pressed.connect(_run_line.bind(line))
				flow.add_child(b)
		rows.add_child(_label("All commands (type them in the console with their arguments)"))
		for n: String in _commands.names():
			rows.add_child(_label("%s - %s" % [n, _commands.help_text(n).get_slice("\n", 0)]))
	return box


# A quick button: runs `line` through the registry, shows the answer in the panel and logs it to the console.
func _run_line(line: String) -> void:
	if _commands == null or _context == null:
		return
	var answer: String = _commands.execute(line, _context)
	_context.log("> %s" % line)
	if not answer.is_empty():
		_context.log(answer)
	if _result != null and is_instance_valid(_result):
		_result.text = answer if not answer.is_empty() else "ok"


static func _label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l
