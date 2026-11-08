class_name SettingsMenu
extends CanvasLayer
## Settings screen (GAME_DESIGN §6), reachable from the main menu and the pause menu: quality tier, master / music /
## SFX volume, mouse sensitivity (x the PlayerInput default), invert Y, control mode (T1.4: one item per record of
## data/controls/modes.json, a one-line description under the grid). Edits a GameSettings in place and applies the
## audio at once; `changed` lets main.gd apply the input settings to a running PlayerInput. close() saves the file, and
## so does a window close (NOTIFICATION_WM_CLOSE_REQUEST) while the screen is open.
## Quality: item 0 is "Auto (<detected tier>)" (GameSettings.quality_auto, the file keeps "auto"), then the tiers; the
## tier takes effect on the next run (QualitySettings reads it at scene start), the note says so.

signal changed
signal closed

const SENSITIVITY_MIN_MULT: float = 0.25
const SENSITIVITY_MAX_MULT: float = 3.0

@onready var quality_option: OptionButton = %QualityOption
@onready var control_mode_option: OptionButton = %ControlModeOption
@onready var master_slider: HSlider = %MasterSlider
@onready var music_slider: HSlider = %MusicSlider
@onready var sfx_slider: HSlider = %SfxSlider
@onready var sensitivity_slider: HSlider = %SensitivitySlider
@onready var invert_check: CheckButton = %InvertCheck
@onready var back_button: Button = %BackButton
@onready var _master_value: Label = %MasterValue
@onready var _music_value: Label = %MusicValue
@onready var _sfx_value: Label = %SfxValue
@onready var _sensitivity_value: Label = %SensitivityValue
@onready var _control_mode_note: Label = %ControlModeNote

var _settings: GameSettings
var _syncing: bool = false
var _mode_ids: Array[StringName] = []  # control_mode_option item index -> mode id


func _ready() -> void:
	quality_option.clear()
	quality_option.add_item("Auto (%s)" % String(QualitySettings.detect_default_tier()).capitalize())
	for tier: StringName in QualitySettings.TIERS:
		quality_option.add_item(String(tier).capitalize())
	var modes: ContentDB = GameSettings.mode_db()
	control_mode_option.clear()
	_mode_ids = modes.control_mode_ids().duplicate()
	for id: StringName in _mode_ids:
		control_mode_option.add_item(str(modes.get_control_mode(id).get("name", id)))
	sensitivity_slider.min_value = SENSITIVITY_MIN_MULT
	sensitivity_slider.max_value = SENSITIVITY_MAX_MULT
	quality_option.item_selected.connect(_on_quality)
	control_mode_option.item_selected.connect(_on_control_mode)
	master_slider.value_changed.connect(_on_volume.bind(&"master_volume", _master_value))
	music_slider.value_changed.connect(_on_volume.bind(&"music_volume", _music_value))
	sfx_slider.value_changed.connect(_on_volume.bind(&"sfx_volume", _sfx_value))
	sensitivity_slider.value_changed.connect(_on_sensitivity)
	invert_check.toggled.connect(_on_invert)
	back_button.pressed.connect(close)


## Shows the screen for `settings` (edited in place).
func open(settings: GameSettings) -> void:
	_settings = settings
	_syncing = true
	quality_option.select(0 if settings.quality_auto else maxi(QualitySettings.TIERS.find(settings.quality_tier), 0) + 1)
	master_slider.value = settings.master_volume * 100.0
	music_slider.value = settings.music_volume * 100.0
	sfx_slider.value = settings.sfx_volume * 100.0
	sensitivity_slider.value = settings.sensitivity / PlayerInput.DEFAULT_SENSITIVITY
	invert_check.button_pressed = settings.invert_y
	control_mode_option.select(maxi(_mode_ids.find(settings.control_mode), maxi(_mode_ids.find(SimEntity.CLASSIC_MODE), 0)))
	_syncing = false
	_refresh_labels()
	visible = true
	back_button.grab_focus.call_deferred()


## Saves and hides; emits `closed`.
func close() -> void:
	if not visible:
		return
	_save()
	visible = false
	closed.emit()


func _notification(what: int) -> void:
	# quitting with the screen open (window close button, Alt+F4, Cmd+Q) must not lose the edits
	if what == NOTIFICATION_WM_CLOSE_REQUEST and visible:
		_save()


func _save() -> void:
	if _settings == null:
		return
	var err: Error = _settings.save_file()
	if err != OK:
		push_warning("settings_menu: could not save %s (error %d)" % [_settings.path, err])


func _on_quality(index: int) -> void:
	if _syncing or _settings == null:
		return
	_settings.quality_auto = index <= 0
	if _settings.quality_auto:
		_settings.quality_tier = QualitySettings.detect_default_tier()
	else:
		_settings.quality_tier = QualitySettings.TIERS[clampi(index - 1, 0, QualitySettings.TIERS.size() - 1)]
	changed.emit()


func _on_volume(value: float, key: StringName, _label: Label) -> void:
	if _syncing or _settings == null:
		return
	_settings.set(key, clampf(value / 100.0, 0.0, 1.0))
	_settings.apply_audio()
	_refresh_labels()
	changed.emit()


func _on_sensitivity(value: float) -> void:
	if _syncing or _settings == null:
		return
	_settings.sensitivity = clampf(PlayerInput.DEFAULT_SENSITIVITY * value, GameSettings.MIN_SENSITIVITY, GameSettings.MAX_SENSITIVITY)
	_refresh_labels()
	changed.emit()


func _on_control_mode(index: int) -> void:
	if _syncing or _settings == null or index < 0 or index >= _mode_ids.size():
		return
	_settings.control_mode = _mode_ids[index]
	_refresh_labels()
	changed.emit()


func _on_invert(on: bool) -> void:
	if _syncing or _settings == null:
		return
	_settings.invert_y = on
	changed.emit()


func _refresh_labels() -> void:
	if _settings == null:
		return
	_master_value.text = "%d%%" % roundi(_settings.master_volume * 100.0)
	_music_value.text = "%d%%" % roundi(_settings.music_volume * 100.0)
	_sfx_value.text = "%d%%" % roundi(_settings.sfx_volume * 100.0)
	_sensitivity_value.text = "%.2fx" % (_settings.sensitivity / PlayerInput.DEFAULT_SENSITIVITY)
	var shown: int = control_mode_option.selected
	_control_mode_note.text = str(GameSettings.mode_db().get_control_mode(_mode_ids[shown]).get("description", "")) if shown >= 0 and shown < _mode_ids.size() else ""
