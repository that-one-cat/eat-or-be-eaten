class_name DebugOverlay
extends CanvasLayer
## F3 (`debug_overlay` action) toggles a text overlay: fps, frame time, sim tick, player position, depth,
## speed, band, stamina, boost/brake state. Reads sim state only.

## Frame-time smoothing rate, 1/s.
const FRAME_TIME_RATE: float = 4.0

@onready var _label: Label = $Label

var _world: SimWorld
var _entity_id: int = 0
var _frame_ms: float = 0.0


func setup(world: SimWorld, entity_id: int, start_visible: bool) -> void:
	_world = world
	_entity_id = entity_id
	visible = start_visible


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_overlay"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 1.0 - exp(-FRAME_TIME_RATE * delta))
	if not visible or _world == null:
		return
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	var p: Vector3 = e.position
	_label.text = "fps %d  frame %.2f ms\ntick %d\npos %.1f, %.1f, %.1f\ndepth %.1f m\nspeed %.2f m/s\nband %d  length %.2f m\nstamina %.0f\nboost %s  brake %s" % [
		Engine.get_frames_per_second(), _frame_ms, _world.tick, p.x, p.y, p.z, -p.y, e.speed,
		e.band, e.length_m, e.stamina, "on" if e.boosting else "off", "on" if e.braking else "off"]
