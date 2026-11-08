class_name PlayerInput
extends Node
## Turns mouse + keyboard (GAME_DESIGN §6) into SimCommands; never moves a node.
##
## Mouse motion (captured) changes the aim yaw/pitch (stored as two angles, never accumulated on a
## transform); every physics frame one MOVE(aim direction, thrust) is submitted, BOOST/BRAKE only when the
## key state changes. While `look_back` is held the aim stays the forward aim: only the camera swings.
## Mouse is captured on start and on a click, released on `pause` (Esc). Abilities: `bite_dash` (right mouse) and
## `sonar` (Q) submit ABILITY commands (the sim ignores abilities that are not granted or still cooling down).
## Bite (F1): a press submits BITE(-1); while `bite` stays held it is re-submitted once per sim tick (the sim keeps a
## player bite pending for rules.bite_buffer_s and fires it when ready, so holding repeats the bite). Hold-repeat is
## armed only after a physics frame with `bite` released while the mouse is captured: the click that captures the
## mouse, a click on a pick card or on the pause menu never turns into a held bite.
## While the player has an open mutation offer (pending_offer, the pick overlay is shown) or the sim is paused for a
## pick, no gameplay input is sent and the mouse is released; it is captured again when the offer is gone. While the
## SceneTree is paused (pause menu) this node does not process at all (default process mode).
## Settings: user://settings.cfg `[input] sensitivity` (radians per pixel), `invert_y`.
## Control mode (T1.4, docs/data/controls.md): `control_mode` is an id of controls/modes.json (GameSettings.apply_input at run
## start and on a settings change, the God console `mode`). The node applies the record's input side (the MOVE direction is
## eased toward the raw aim by AimSmoothing when mouse_smooth_tau_s / aim_turn_cap_deg_s say so; `classic` sends the raw aim
## untouched) and tells the sim ONCE per change with SET_CONTROL_MODE (the sim starts in classic, so classic at run start sends
## nothing). While the player is dead (the sim ignores commands for it) the SET waits until it lives again.

const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_SENSITIVITY: float = 0.0025
## Aim pitch limit when the rules have none (the sim clamps the fish to rules swim.max_pitch_deg anyway).
const DEFAULT_MAX_PITCH_DEG: float = 80.0

var sensitivity: float = DEFAULT_SENSITIVITY
var invert_y: bool = false
## Requested control mode id; an id the run's content does not know is taken as classic.
var control_mode: StringName = SimEntity.CLASSIC_MODE
## Aim angles, radians: yaw 0 = -Z (rotation.y convention), pitch positive = up.
var aim_yaw: float = 0.0
var aim_pitch: float = 0.0

var _world: SimWorld
var _entity_id: int = 0
var _max_pitch: float = deg_to_rad(DEFAULT_MAX_PITCH_DEG)
var _boost_sent: bool = false
var _brake_sent: bool = false
var _offer_open: bool = false
var _bite_armed: bool = false
var _bite_sent_tick: int = -1  # world.tick of the last BITE submitted (at most one per sim tick)
var _mode_applied: StringName = SimEntity.CLASSIC_MODE  # mode whose smoothing numbers are loaded below
var _mode_sent: StringName = SimEntity.CLASSIC_MODE  # mode the sim was last told (it starts in classic)
var _smooth_tau: float = 0.0
var _smooth_cap_deg_s: float = 0.0
var _smooth_dir: Vector3 = Vector3.FORWARD  # the direction MOVE sends while smoothing


## Starts sending commands for `entity_id`; the aim starts at the fish heading.
func setup(world: SimWorld, entity_id: int) -> void:
	_world = world
	_entity_id = entity_id
	var swim: Variant = world.content.rules().get("swim") if world.content != null else null
	if swim is Dictionary and (swim as Dictionary).has("max_pitch_deg"):
		_max_pitch = deg_to_rad(float((swim as Dictionary)["max_pitch_deg"]))
	var e: SimEntity = world.get_entity(entity_id)
	if e != null:
		aim_yaw = deg_to_rad(e.yaw_deg)
		aim_pitch = deg_to_rad(e.pitch_deg)
	_load_settings()
	_set_captured(true)


## Unit aim direction (same yaw/pitch convention as the sim).
func aim_direction() -> Vector3:
	var cp: float = cos(aim_pitch)
	return Vector3(-sin(aim_yaw) * cp, sin(aim_pitch), -cos(aim_yaw) * cp)


func _unhandled_input(event: InputEvent) -> void:
	if _world == null:
		return
	if event.is_action_pressed(&"pause"):
		_set_captured(false)
		get_viewport().set_input_as_handled()
		return
	if _offer_open:
		return
	var captured: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not captured:
		# the click that captures the mouse is not a bite
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_set_captured(true)
			get_viewport().set_input_as_handled()
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		# screen_relative: raw device motion, independent of the stretch/content scale (relative is rescaled by it)
		aim_yaw = wrapf(aim_yaw - motion.screen_relative.x * sensitivity, -PI, PI)
		var dy: float = motion.screen_relative.y * sensitivity
		aim_pitch = clampf(aim_pitch + (dy if invert_y else -dy), -_max_pitch, _max_pitch)
		return
	if event.is_action_pressed(&"bite"):
		_bite_armed = true
		_submit_bite()
	elif event.is_action_pressed(&"bite_dash"):
		_world.submit(SimCommand.ability(_entity_id, &"bite_dash"))
	elif event.is_action_pressed(&"sonar"):
		_world.submit(SimCommand.ability(_entity_id, &"sonar"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_bite_armed = false  # resume may capture the mouse while the button is still down


func _exit_tree() -> void:
	# never leave the player with a captured mouse when this node goes away (scene change, quit to menu)
	if _world != null:
		_set_captured(false)


func _physics_process(delta: float) -> void:
	if _world == null:
		return
	var e: SimEntity = _world.get_entity(_entity_id)
	var offer_open: bool = e != null and not e.pending_offer.is_empty()
	if offer_open != _offer_open:
		_offer_open = offer_open
		_set_captured(not offer_open)
	if _offer_open or _world.paused_for_pick:
		_bite_armed = false
		return
	_sync_control_mode(e)
	var dir: Vector3 = aim_direction()
	if _smooth_tau > 0.0 or _smooth_cap_deg_s > 0.0:
		_smooth_dir = AimSmoothing.step(_smooth_dir, dir, delta, _smooth_tau, _smooth_cap_deg_s)
		dir = _smooth_dir
	_world.submit(SimCommand.move(_entity_id, dir, Input.get_action_strength(&"swim_thrust")))
	var bite_held: bool = Input.is_action_pressed(&"bite")
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_bite_armed = false
	elif not bite_held:
		_bite_armed = true
	elif _bite_armed:
		_submit_bite()
	var boost: bool = Input.is_action_pressed(&"boost")
	if boost != _boost_sent:
		_boost_sent = boost
		_world.submit(SimCommand.boost(_entity_id, boost))
	var brake: bool = Input.is_action_pressed(&"swim_brake")
	if brake != _brake_sent:
		_brake_sent = brake
		_world.submit(SimCommand.brake(_entity_id, brake))


# Loads the smoothing numbers of a newly requested control mode (the smoothed direction starts at the current aim) and sends
# SET_CONTROL_MODE once per change (held back while the player is dead: the sim would drop it).
func _sync_control_mode(e: SimEntity) -> void:
	if control_mode != _mode_applied:
		var rec: Dictionary = _mode_record(control_mode)
		if rec.is_empty():
			control_mode = SimEntity.CLASSIC_MODE  # unknown id (or no content): classic
			rec = _mode_record(control_mode)
		_mode_applied = control_mode
		_smooth_tau = float(rec.get("mouse_smooth_tau_s", 0.0))
		_smooth_cap_deg_s = float(rec.get("aim_turn_cap_deg_s", 0.0))
		_smooth_dir = aim_direction()
	if _mode_applied != _mode_sent and e != null and e.alive:
		_mode_sent = _mode_applied
		_world.submit(SimCommand.set_control_mode(_entity_id, _mode_sent))


func _mode_record(id: StringName) -> Dictionary:
	return _world.content.get_control_mode(id) if _world.content != null else {}


# One BITE(-1) per sim tick (physics runs faster than the 30 Hz sim).
func _submit_bite() -> void:
	if _bite_sent_tick == _world.tick:
		return
	_bite_sent_tick = _world.tick
	_world.submit(SimCommand.bite(_entity_id, -1))


func _set_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


# Reads the settings; writes the defaults when the file does not exist yet (so they can be edited).
func _load_settings() -> void:
	var cfg := ConfigFile.new()
	var err: Error = cfg.load(SETTINGS_PATH)
	var raw: float = float(cfg.get_value("input", "sensitivity", DEFAULT_SENSITIVITY))
	# a hand-edited file may hold nan/inf: clampf passes NaN through and would poison the aim angles
	sensitivity = clampf(raw, 0.0001, 0.05) if is_finite(raw) else DEFAULT_SENSITIVITY
	invert_y = bool(cfg.get_value("input", "invert_y", false))
	if err == ERR_FILE_NOT_FOUND:
		cfg.set_value("input", "sensitivity", sensitivity)
		cfg.set_value("input", "invert_y", invert_y)
		cfg.save(SETTINGS_PATH)
