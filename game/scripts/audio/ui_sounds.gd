class_name UiSounds
extends Node
## UI click / hover sounds for every BaseButton in the tree (main.tscn screens, and buttons added later such as the
## mutation pick cards of a run): hooks `pressed` (click) and `mouse_entered` (hover, enabled buttons only) without
## touching the screens. Plays on the `SFX` bus, so UI sounds bypass the `Underwater` low-pass and follow the SFX volume.
## One fixed variant per sound (`click_variant` / `hover_variant`, A = 0; the Director picks by ear) with a small pitch
## jitter. Process mode is inherited from Main (ALWAYS), so menus click while the tree is paused. Silent on the Dummy
## audio driver (headless), like AudioDirector.

const BUS: StringName = &"SFX"
const HOVER_GAP_MS: int = 60
const PITCH_JITTER: float = 0.03
const CLICK_DB: float = -4.0
const HOVER_DB: float = -10.0

@export var click_variant: int = 0
@export var hover_variant: int = 0

var _click: AudioStream
var _hover: AudioStream
var _click_player: AudioStreamPlayer
var _hover_player: AudioStreamPlayer
var _next_hover_ms: int = 0
var _rng := RandomNumberGenerator.new()
var _output: bool = true


func _ready() -> void:
	_output = AudioDirector.output_enabled()
	var clicks: Array[AudioStream] = AudioDirector.load_group(&"ui_click")
	var hovers: Array[AudioStream] = AudioDirector.load_group(&"ui_hover")
	_click = clicks[clampi(click_variant, 0, clicks.size() - 1)] if not clicks.is_empty() else null
	_hover = hovers[clampi(hover_variant, 0, hovers.size() - 1)] if not hovers.is_empty() else null
	_click_player = _make_player(_click, CLICK_DB)
	_hover_player = _make_player(_hover, HOVER_DB)
	get_tree().node_added.connect(_on_node_added)
	for n: Node in get_tree().root.find_children("*", "BaseButton", true, false):
		_hook(n as BaseButton)


func _make_player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = BUS
	p.volume_db = db
	p.max_polyphony = 2
	add_child(p)
	return p


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_hook(node as BaseButton)


func _hook(b: BaseButton) -> void:
	if b.pressed.is_connected(_on_pressed):
		return
	b.pressed.connect(_on_pressed)
	b.mouse_entered.connect(_on_hovered.bind(b))


func _on_pressed() -> void:
	if _click != null and _output:
		_click_player.pitch_scale = 1.0 + _rng.randf_range(-PITCH_JITTER, PITCH_JITTER)
		_click_player.play()


func _on_hovered(b: BaseButton) -> void:
	var now: int = Time.get_ticks_msec()
	if _hover == null or not _output or b.disabled or now < _next_hover_ms:
		return
	_next_hover_ms = now + HOVER_GAP_MS
	_hover_player.pitch_scale = 1.0 + _rng.randf_range(-PITCH_JITTER, PITCH_JITTER)
	_hover_player.play()
