class_name GodConsole
extends CanvasLayer
## The `~` God console (dev builds only, created by GodHost): a log (RichTextLabel) and a command line (LineEdit) over the
## top of the screen, with input history (Up / Down). `submit(line)` runs a line through the GodCommands registry and
## prints the answer. While it is open GodHost pauses the tree (typing W / S / Q into the line must not steer the fish)
## and restores the previous pause / mouse state on `closed`.
##
## Closing: Esc (the `pause` action) and the console keys (`console_keys`, the same set that opens it) are read in
## `_input` while open, so the line never types a backtick and Main's own Esc handling does not also pause the game.

signal opened
signal closed

const THEME_PATH: String = "res://ui/theme/main_theme.tres"
const LAYER: int = 31
const HEIGHT_FRAC: float = 0.45
const HISTORY_MAX: int = 100
const PROMPT: String = "> "

var commands: GodCommands = null
var context: GodContext = null
## Keys that close the console again (set by GodHost from the data file).
var close_keys: TypedWords.KeySet = TypedWords.KeySet.new()

var _history: PackedStringArray = []
var _history_pos: int = 0  # == _history.size() while the line is a fresh one
var _log: RichTextLabel
var _line: LineEdit


func _init() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	var root: Control = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		root.theme = load(THEME_PATH) as Theme
	add_child(root)
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.anchor_bottom = HEIGHT_FRAC
	root.add_child(panel)
	var box: VBoxContainer = VBoxContainer.new()
	panel.add_child(box)
	_log = RichTextLabel.new()
	_log.name = "Log"
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_log)
	_line = LineEdit.new()
	_line.name = "Line"
	_line.placeholder_text = "command (help)"
	_line.keep_editing_on_text_submit = true
	_line.text_submitted.connect(submit)
	_line.gui_input.connect(_on_line_gui_input)
	box.add_child(_line)
	print_line("God console. Type help.")


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	_history_pos = _history.size()
	_line.clear()
	_focus_line.call_deferred()
	opened.emit()


## Deferred from open(): skipped when the console was closed (or hidden quietly) before the call ran, so a hidden
## LineEdit never keeps the keyboard focus.
func _focus_line() -> void:
	if visible:
		_line.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	_line.release_focus()
	closed.emit()


## Hides the console without emitting `closed` (the run is being freed; pause and mouse are not ours to restore).
func hide_quietly() -> void:
	visible = false
	_line.release_focus()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## Echoes `line`, stores it in the history and prints the registry's answer. An empty line does nothing.
func submit(line: String) -> void:
	var text: String = line.strip_edges()
	_line.clear()
	if text.is_empty():
		return
	print_line(PROMPT + text)
	if _history.is_empty() or _history[_history.size() - 1] != text:
		_history.append(text)
		if _history.size() > HISTORY_MAX:
			_history.remove_at(0)
	_history_pos = _history.size()
	if commands == null:
		print_line("no command registry")
		return
	var out: String = commands.execute(text, context if context != null else GodContext.new())
	if not out.is_empty():
		print_line(out)


## Appends one line to the log (plain text, no bbcode).
func print_line(text: String) -> void:
	_log.add_text(text + "\n")


func clear() -> void:
	_log.clear()


## The log as plain text.
func log_text() -> String:
	return _log.get_parsed_text()


## Moves through the input history (-1 = older, +1 = newer) and puts that entry on the command line; returns it
## ("" past the newest entry).
func history_step(dir: int) -> String:
	if _history.is_empty():
		return ""
	_history_pos = clampi(_history_pos + dir, 0, _history.size())
	var entry: String = _history[_history_pos] if _history_pos < _history.size() else ""
	_line.text = entry
	_line.caret_column = entry.length()
	return entry


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var key: InputEventKey = event as InputEventKey
	var closing: bool = event.is_action_pressed(&"pause") and not event.is_echo()
	if key != null and close_keys.matches(key):
		closing = true
	if closing:
		close()
		get_viewport().set_input_as_handled()


func _on_line_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_up"):
		history_step(-1)
		_line.accept_event()
	elif event.is_action_pressed(&"ui_down"):
		history_step(1)
		_line.accept_event()
