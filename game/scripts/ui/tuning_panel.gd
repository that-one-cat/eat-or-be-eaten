class_name TuningPanel
extends VBoxContainer
## The `tuning` tab of the F1 God menu (T1.3): one row per registry row of `data/god/tuning.json`, grouped by `group`, each
## with its label, an HSlider, a numeric entry (SpinBox) and a reset button, plus "Reset all". The controls carry the row's
## min / max / step. Every change goes through `SimDebug.tuning_*` (rules 1-2: the UI never writes sim state), so the sim
## picks it up on the next tick and the console `tune` commands see the same layer; the panel polls `TuningOverrides.revision`
## and the player's band, so a console change or a band-up shows up in the sliders too. A slider shows the override, else the
## data value (of the player's current band for a band row). Presets: console `tune save|load|export <name>`.
## Built by `GodMenu` through the panel registry (`build`), only where `GodBuild.allowed()`.

## Decimals kept when a control value becomes an override (slider arithmetic leaves float noise; the presets stay clean).
const VALUE_DECIMALS: int = 6
const SLIDER_MIN_WIDTH: float = 140.0
const SPIN_MIN_WIDTH: float = 96.0

var _world: SimWorld = null
var _player_id: int = -1
var _tuning: TuningOverrides = null
var _rows: Dictionary = {}  # String id -> {"name": Label, "data": Label, "slider": HSlider, "spin": SpinBox, "reset": Button}
var _status: Label = null
var _syncing: bool = false
var _revision: int = -1
var _band: int = -1


## The builder the GodMenu registry calls: the panel, or a one-line note when there is nothing to tune.
static func build(ctx: GodContext) -> Control:
	if not GodBuild.allowed():
		return _note("Tuning is disabled in this build.")
	if ctx == null or not ctx.has_run():
		return _note("Start a run to tune the rules and the size-band tables.")
	var panel := TuningPanel.new()
	panel.setup(ctx)
	return panel


func setup(ctx: GodContext) -> void:
	_world = ctx.world
	_player_id = ctx.player_id
	_tuning = SimDebug.tuning(_world)
	add_child(_note("Sliders override the data live (next tick) and are never saved into the game files. Presets: console `tune save|load|export <name>`."))
	if _tuning.rows.is_empty():
		add_child(_note("Tuning registry unavailable: %s" % "; ".join(_tuning.errors)))
		return
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	var group: String = ""
	for row: Dictionary in _tuning.rows:
		if String(row["group"]) != group:
			group = row["group"]
			var title := Label.new()
			title.text = group
			title.add_theme_color_override(&"font_color", Color(0.75, 0.9, 1.0))
			body.add_child(title)
		body.add_child(_build_row(row))
	var reset_all := Button.new()
	reset_all.text = "Reset all"
	reset_all.tooltip_text = "Reset all overrides to the data values"
	reset_all.focus_mode = Control.FOCUS_NONE
	reset_all.pressed.connect(_on_reset_all)
	add_child(reset_all)
	_status = _note("")
	add_child(_status)
	_sync()


func _process(_delta: float) -> void:
	if _tuning == null or _world == null or not is_visible_in_tree():
		return
	if _tuning.revision != _revision or _player_band() != _band:
		_sync()


func _build_row(row: Dictionary) -> Control:
	var id: String = row["id"]
	var box := VBoxContainer.new()
	var head := HBoxContainer.new()
	box.add_child(head)
	var name_label := Label.new()
	name_label.text = row["label"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(name_label)
	var data_label := Label.new()
	data_label.text = "data %s" % _tuning.data_text(id)
	data_label.modulate = Color(1, 1, 1, 0.6)
	head.add_child(data_label)
	var line := HBoxContainer.new()
	box.add_child(line)
	var slider := HSlider.new()
	slider.min_value = float(row["min"])
	slider.max_value = float(row["max"])
	slider.step = float(row["step"])
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = SLIDER_MIN_WIDTH
	slider.focus_mode = Control.FOCUS_NONE  # a focused slider would eat the arrow keys while swimming
	line.add_child(slider)
	var spin := SpinBox.new()
	spin.min_value = float(row["min"])
	spin.max_value = float(row["max"])
	spin.step = float(row["step"])
	spin.custom_minimum_size.x = SPIN_MIN_WIDTH
	var edit: LineEdit = spin.get_line_edit()
	edit.text_submitted.connect(func(_text: String) -> void: edit.release_focus())
	line.add_child(spin)
	var reset := Button.new()
	reset.text = "Reset"
	reset.tooltip_text = "Back to the data value"
	reset.focus_mode = Control.FOCUS_NONE
	line.add_child(reset)
	slider.value_changed.connect(_on_value.bind(id))
	spin.value_changed.connect(_on_value.bind(id))
	reset.pressed.connect(_on_reset.bind(id))
	_rows[id] = {"name": name_label, "data": data_label, "slider": slider, "spin": spin, "reset": reset}
	return box


func _on_value(v: float, id: String) -> void:
	if _syncing:
		return
	var row: Dictionary = _tuning.get_row(id)
	var clean: float = clampf(String.num(v, VALUE_DECIMALS).to_float(), float(row["min"]), float(row["max"]))
	var err: String = SimDebug.tuning_set(_world, id, clean)
	_status.text = err if not err.is_empty() else "%s = %s" % [id, String.num(clean, VALUE_DECIMALS)]
	_sync()


func _on_reset(id: String) -> void:
	SimDebug.tuning_reset(_world, id)
	_status.text = "%s: back to the data value" % id
	_sync()


func _on_reset_all() -> void:
	SimDebug.tuning_reset(_world)
	_status.text = "all overrides reset"
	_sync()


# Controls to the layer (override, else the data value of the player's band).
func _sync() -> void:
	_syncing = true
	_band = _player_band()
	for id: String in _rows:
		var r: Dictionary = _rows[id]
		var v: float = _tuning.value(id, _band)
		(r["slider"] as HSlider).value = v
		(r["spin"] as SpinBox).value = v
		(r["reset"] as Button).disabled = not _tuning.is_overridden(id)
		(r["name"] as Label).text = String(_tuning.get_row(id)["label"]) + (" *" if _tuning.is_overridden(id) else "")
	_revision = _tuning.revision
	_syncing = false


func _player_band() -> int:
	var p: SimEntity = _world.get_entity(_player_id) if _world != null else null
	return p.band if p != null else 1


static func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l
