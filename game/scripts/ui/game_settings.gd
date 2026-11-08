class_name GameSettings
extends RefCounted
## Player settings (GAME_DESIGN §6): mouse sensitivity, invert Y, control mode, master / music / SFX volume, quality tier. Persisted
## in a ConfigFile (`path`, default user://settings.cfg; tests inject their own path so the real file stays untouched):
##   [input]    sensitivity (radians per pixel, PlayerInput's unit), invert_y, control_mode (T1.4: a mode id of
##              data/controls/modes.json; a missing, unknown or non-string value reads as "classic")
##   [audio]    master_volume, music_volume, sfx_volume (linear 0..1; buses get linear_to_db, 0 = muted)
##   [graphics] quality_tier ("auto" | "low" | "high", the QualitySettings section/key; "auto" = QualitySettings
##              detects the tier at each start, so a first save never pins the tier of the machine it ran on)
## save() keeps every other section/key of the file. Values read from disk are validated (hand-edited files).
## Applying: apply_audio() sets the Master / Music / SFX bus volumes (buses from res://default_bus_layout.tres);
## apply_input() sets a live PlayerInput's sensitivity / invert_y / control_mode. The quality tier is read by QualitySettings.tier() at
## scene start, so a change applies on the next run (QualitySettings only reads the default path).

const DEFAULT_PATH: String = "user://settings.cfg"
const BUS_MASTER: StringName = &"Master"
const BUS_MUSIC: StringName = &"Music"
const BUS_SFX: StringName = &"SFX"
const MIN_SENSITIVITY: float = 0.0001
const MAX_SENSITIVITY: float = 0.05

var path: String = DEFAULT_PATH
var sensitivity: float = PlayerInput.DEFAULT_SENSITIVITY
var invert_y: bool = false
var control_mode: StringName = SimEntity.CLASSIC_MODE
var master_volume: float = 1.0
var music_volume: float = 0.8
var sfx_volume: float = 1.0
var quality_tier: StringName = QualitySettings.HIGH
## True while the user has not picked a tier: quality_tier is the detected one and the file stores "auto".
var quality_auto: bool = true

static var _modes: ContentDB = null


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


## Reads the file (missing file or keys: defaults; a missing, "auto" or unknown tier = auto: quality_tier is
## QualitySettings.detect_default_tier()).
func load_file() -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	sensitivity = clampf(_finite(cfg.get_value("input", "sensitivity", PlayerInput.DEFAULT_SENSITIVITY), PlayerInput.DEFAULT_SENSITIVITY), MIN_SENSITIVITY, MAX_SENSITIVITY)
	invert_y = bool(cfg.get_value("input", "invert_y", false))
	var mode: Variant = cfg.get_value("input", "control_mode", "")
	control_mode = StringName(mode) if mode is String and mode_db().control_mode_ids().has(StringName(mode)) else SimEntity.CLASSIC_MODE
	master_volume = clampf(_finite(cfg.get_value("audio", "master_volume", 1.0), 1.0), 0.0, 1.0)
	music_volume = clampf(_finite(cfg.get_value("audio", "music_volume", 0.8), 0.8), 0.0, 1.0)
	sfx_volume = clampf(_finite(cfg.get_value("audio", "sfx_volume", 1.0), 1.0), 0.0, 1.0)
	var raw: String = str(cfg.get_value(QualitySettings.SECTION, QualitySettings.KEY, ""))
	quality_auto = not QualitySettings.TIERS.has(StringName(raw))
	quality_tier = QualitySettings.detect_default_tier() if quality_auto else StringName(raw)


## Writes all settings, keeping the other keys of the file. Returns the ConfigFile save error.
func save_file() -> Error:
	var cfg := ConfigFile.new()
	cfg.load(path)  # missing file is fine: start empty
	cfg.set_value("input", "sensitivity", sensitivity)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("input", "control_mode", String(control_mode))
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value(QualitySettings.SECTION, QualitySettings.KEY, String(QualitySettings.AUTO if quality_auto else quality_tier))
	return cfg.save(path)


func apply_audio() -> void:
	_set_bus(BUS_MASTER, master_volume)
	_set_bus(BUS_MUSIC, music_volume)
	_set_bus(BUS_SFX, sfx_volume)


func apply_input(input: PlayerInput) -> void:
	if input == null:
		return
	input.sensitivity = sensitivity
	input.invert_y = invert_y
	input.control_mode = control_mode


## The shipped control modes (data/controls/modes.json only, loaded once): the ids a stored value must be one of and the
## names / descriptions the Settings screen shows.
static func mode_db() -> ContentDB:
	if _modes == null:
		_modes = ContentDB.load_control_modes()
	return _modes


static func _set_bus(bus: StringName, linear: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))


static func _finite(v: Variant, fallback: float) -> float:
	var f: float = float(v) if (v is float or v is int) else fallback
	return f if is_finite(f) else fallback
