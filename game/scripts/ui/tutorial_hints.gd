class_name TutorialHints
extends CanvasLayer
## Tutorial hints of the first minute (GAME_DESIGN §10): move, eat small, bite big, hide in kelp, one at a time in a
## small bottom-centre panel. Event-driven: a hint is done when the player does the thing (moved MOVE_DONE_M from the
## spawn; EATEN / PLANKTON_EATEN / SITE_EATEN by the player; a BITTEN / SITE_BITTEN by the player; the player HIDDEN),
## else after its max_s; a hint whose action already happened is skipped. Timing uses sim time (SimWorld.run_ticks),
## so the mutation-pick pause freezes it; the panel is hidden while the world is paused for a pick and while the tree is paused (pause
## menu, victory: NOTIFICATION_PAUSED, the node is Pausable). No new hint starts while the player is dead (the death
## toast owns the screen). Worst case (no action done) the sequence ends at about 50 s of sim time: START_S + the
## max_s sum + 3 gaps. Reads sim state and events only.

## First hint after the run's fade-in has settled.
const START_S: float = 2.0
## Pause between two hints, so a new text is noticed as new.
const GAP_S: float = 1.5
## A hint stays at least this long even when its action is already done.
const MIN_SHOW_S: float = 3.0
const FADE_S: float = 0.35
const MOVE_DONE_M: float = 10.0
## Hints in order: id, text (key names from the InputMap, see key_name()), max seconds on screen.
const HINTS: Array[Dictionary] = [
	{"id": &"move", "text": "Steer with the mouse.  {swim_thrust} swim  ·  {boost} boost", "max_s": 10.0},
	{"id": &"eat", "text": "Swim into plankton, eggs and much smaller fish to swallow them", "max_s": 12.0},
	{"id": &"bite", "text": "{bite} bites what is too big to swallow: shells, starfish, bigger fish", "max_s": 12.0},
	{"id": &"hide", "text": "Hide in kelp and coral: predators lose track of you", "max_s": 10.0},
]

## Key names used in the hint texts when the InputMap cannot be asked (the project defaults).
const DEFAULT_KEYS: Dictionary[StringName, String] = {&"swim_thrust": "W", &"boost": "Shift", &"bite": "LMB", &"pause": "Esc"}

@onready var _panel: PanelContainer = %HintPanel
@onready var _label: Label = %HintLabel

var _loop: GameLoop
var _world: SimWorld
var _id: int = 0
var _event_tick: int = 0
var _start_pos: Vector3 = Vector3.ZERO
var _done: Dictionary[StringName, bool] = {}
var _index: int = -1  # hint on screen (-1 = none)
var _last: int = -1  # last hint shown or skipped
var _shown_at: float = 0.0  # sim seconds
var _next_at: float = START_S
var _tween: Tween


func _ready() -> void:
	_panel.modulate.a = 0.0
	_panel.visible = false


## Starts the hint sequence for `player_id` of `loop`'s world.
func setup(loop: GameLoop, player_id: int) -> void:
	clear()
	_loop = loop
	_world = loop.world
	_id = player_id
	_event_tick = _world.tick
	var e: SimEntity = _world.get_entity(player_id)
	_start_pos = e.position if e != null else Vector3.ZERO
	_index = -1
	_last = -1
	_next_at = START_S
	_done = {}
	loop.ticked.connect(_on_ticked)
	visible = true


## Stops and hides (run ended).
func clear() -> void:
	if _loop != null and is_instance_valid(_loop) and _loop.ticked.is_connected(_on_ticked):
		_loop.ticked.disconnect(_on_ticked)
	_loop = null
	_world = null
	_index = -1
	_hide_panel(true)


## Id of the hint on screen (&"" when none).
func current_hint() -> StringName:
	return HINTS[_index]["id"] if _index >= 0 else &""


## True when the hint panel is actually visible to the player.
func is_showing() -> bool:
	return visible and _panel.visible and _index >= 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		visible = false
	elif what == NOTIFICATION_UNPAUSED:
		visible = true


func _process(_delta: float) -> void:
	if _world != null:
		_panel.visible = _index >= 0 and not _world.paused_for_pick


func _on_ticked(tick: int) -> void:
	if tick == _event_tick or _world == null:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.EATEN:
				if ev.other_id == _id:
					_done[&"eat"] = true
			SimEvent.Type.PLANKTON_EATEN, SimEvent.Type.SITE_EATEN:
				if ev.entity_id == _id:
					_done[&"eat"] = true
			SimEvent.Type.BITTEN:
				if ev.other_id == _id:
					_done[&"bite"] = true
			SimEvent.Type.SITE_BITTEN:
				if ev.entity_id == _id:
					_done[&"bite"] = true
			SimEvent.Type.HIDDEN:
				if ev.entity_id == _id:
					_done[&"hide"] = true
	_event_tick = tick
	var e: SimEntity = _world.get_entity(_id)
	if e != null and e.alive and e.position.distance_to(_start_pos) >= MOVE_DONE_M:
		_done[&"move"] = true
	_advance(float(_world.run_ticks) * SimWorld.TICK_DT, e != null and e.alive)


func _advance(now: float, player_alive: bool = true) -> void:
	if _index >= 0:
		var hint: Dictionary = HINTS[_index]
		var age: float = now - _shown_at
		if age >= float(hint["max_s"]) or (age >= MIN_SHOW_S and _done.get(hint["id"], false)):
			_index = -1
			_next_at = now + GAP_S
			_hide_panel(false)
		return
	if now < _next_at or not player_alive:
		return
	var next: int = _next_index()
	if next < 0:
		return
	_index = next
	_shown_at = now
	_label.text = _format(str(HINTS[next]["text"]))
	_show_panel()


# The next hint after the last one whose action has not happened yet (-1 = sequence over).
func _next_index() -> int:
	while _last + 1 < HINTS.size():
		_last += 1
		if not _done.get(HINTS[_last]["id"], false):
			return _last
	return -1


## Key name of `action` (Hud.key_hint: layout-aware, "Shift", "LMB"); DEFAULT_KEYS on the headless display server,
## which has no keyboard layout to ask.
static func key_name(action: StringName) -> String:
	var key: String = Hud.key_hint(action) if DisplayServer.get_name() != "headless" else ""
	return key if not key.is_empty() else str(DEFAULT_KEYS.get(action, action))


static func _format(text: String) -> String:
	var out: String = text
	for action: StringName in DEFAULT_KEYS:
		out = out.replace("{%s}" % action, key_name(action))
	return out


func _show_panel() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_panel.visible = true
	_tween = create_tween().bind_node(_panel).set_ignore_time_scale(true)
	_tween.tween_property(_panel, ^"modulate:a", 1.0, FADE_S)


func _hide_panel(instant: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if instant or not is_inside_tree():
		_panel.modulate.a = 0.0
		return
	_tween = create_tween().bind_node(_panel).set_ignore_time_scale(true)
	_tween.tween_property(_panel, ^"modulate:a", 0.0, FADE_S)
