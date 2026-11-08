class_name MutationPickOverlay
extends CanvasLayer
## Mutation pick overlay (GAME_DESIGN §4, §10): while the player has an open offer (SimEntity.pending_offer, set by
## the sim on a band-up; the single-player world is paused meanwhile) it dims the screen and shows one card per offered
## node (3, or fewer when fewer nodes are available): branch + tier tag, icon placeholder, name, the one-line
## `description` from mutations.json, "ability" tag and the key hint. A click on a card or the pick_mutation_1..3
## actions (keys 1-3) submit SimCommand.pick_mutation; the sim applies it, clears the offer and resumes, and the
## overlay closes when the offer is gone. Polls the offer every frame (no event needed, robust to the pause).
## Cards ignore input for INPUT_GRACE_S after opening, so a held / spammed bite click does not pick by accident.
## The mouse is released / recaptured by PlayerInput (it watches the same offer). Presentation only.

const THEME: Theme = preload("res://ui/theme/main_theme.tres")
const CARD_SIZE: Vector2 = Vector2(260.0, 330.0)
const ICON_SIZE: float = 84.0
## Seconds after opening during which picks are ignored (real time).
const INPUT_GRACE_S: float = 0.6
const PICK_ACTIONS: Array[StringName] = [&"pick_mutation_1", &"pick_mutation_2", &"pick_mutation_3"]

## Emitted when the overlay opens / closes (impl-C: tutorial hints stay hidden meanwhile).
signal opened
signal closed

var _world: SimWorld
var _entity_id: int = 0
var _root: Control
var _dim: ColorRect
var _title: Label
var _sub: Label
var _row: HBoxContainer
var _cards: Array[Button] = []
var _offer: PackedStringArray = PackedStringArray()
var _open_time_ms: int = 0
var _submitted: bool = false
var _tween: Tween


func setup(world: SimWorld, entity_id: int) -> void:
	_world = world
	_entity_id = entity_id
	layer = 5
	_root = Control.new()
	_root.name = "Root"
	_root.theme = THEME
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.01, 0.04, 0.08, 0.6)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_dim)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 10)
	centre.add_child(col)
	_title = Label.new()
	_title.theme_type_variation = &"OverlayTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.text = "EVOLVE!"
	col.add_child(_title)
	_sub = Label.new()
	_sub.theme_type_variation = &"OverlaySub"
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 14.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 26)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_row)
	visible = false


## True while cards are shown.
func is_open() -> bool:
	return visible


func _process(_delta: float) -> void:
	if _world == null:
		return
	var e: SimEntity = _world.get_entity(_entity_id)
	var offer: PackedStringArray = e.pending_offer if e != null else PackedStringArray()
	if offer.is_empty():
		if not _offer.is_empty():
			_close()
		return
	if offer != _offer:
		_open(offer, e.band)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	for i in PICK_ACTIONS.size():
		if i < _cards.size() and event.is_action_pressed(PICK_ACTIONS[i]):
			get_viewport().set_input_as_handled()
			_pick(i)
			return


func _open(offer: PackedStringArray, band: int) -> void:
	_offer = offer.duplicate()
	_submitted = false
	_open_time_ms = Time.get_ticks_msec()
	for c: Button in _cards:
		c.queue_free()
	_cards.clear()
	_sub.text = "Band %d reached  -  pick one mutation" % band
	for i in _offer.size():
		var card: Button = _make_card(i, StringName(_offer[i]))
		_row.add_child(card)
		_cards.append(card)
	visible = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_root.modulate.a = 0.0
	_tween = create_tween().bind_node(_root).set_ignore_time_scale(true)
	_tween.tween_property(_root, ^"modulate:a", 1.0, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for i in _cards.size():
		var card: Button = _cards[i]
		card.pivot_offset = CARD_SIZE * 0.5
		card.scale = Vector2.ONE * 0.82
		var tw: Tween = card.create_tween().set_ignore_time_scale(true)
		tw.tween_interval(0.06 * float(i))
		tw.tween_property(card, ^"scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if not _cards.is_empty():
		_cards[0].grab_focus.call_deferred()
	opened.emit()


func _close() -> void:
	_offer = PackedStringArray()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().bind_node(_root).set_ignore_time_scale(true)
	_tween.tween_property(_root, ^"modulate:a", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_callback(hide)
	closed.emit()


func _pick(i: int) -> void:
	if _submitted or i < 0 or i >= _offer.size():
		return
	if Time.get_ticks_msec() - _open_time_ms < int(INPUT_GRACE_S * 1000.0):
		return
	_submitted = true
	_world.submit(SimCommand.pick_mutation(_entity_id, StringName(_offer[i])))
	for j in _cards.size():
		var card: Button = _cards[j]
		card.disabled = true
		var tw: Tween = card.create_tween().set_ignore_time_scale(true)
		if j == i:
			tw.tween_property(card, ^"scale", Vector2.ONE * 1.08, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		else:
			tw.tween_property(card, ^"modulate:a", 0.35, 0.12)


func _make_card(i: int, node_id: StringName) -> Button:
	var node: Dictionary = _world.content.get_mutation(node_id) if _world.content != null else {}
	var branch: String = str(node.get("branch", ""))
	var branch_color: Color = THEME.get_color(StringName(branch), &"Palette") if THEME.has_color(StringName(branch), &"Palette") else THEME.get_color(&"accent", &"Palette")
	var card := Button.new()
	card.theme_type_variation = &"CardButton"
	card.custom_minimum_size = CARD_SIZE
	card.focus_mode = Control.FOCUS_ALL
	card.pressed.connect(_pick.bind(i))
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 16.0
	col.offset_right = -16.0
	col.offset_top = 14.0
	col.offset_bottom = -14.0
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(col)
	var tag := Label.new()
	tag.theme_type_variation = &"CardTag"
	tag.text = "%s  -  TIER %d" % [branch.to_upper(), int(node.get("tier", 1))]
	tag.add_theme_color_override("font_color", branch_color)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(tag)
	var icon := _CardIcon.new()
	icon.color = branch_color
	icon.glyph = str(node.get("name", "?")).left(1).to_upper()
	icon.active = not str(node.get("grants_ability", "")).is_empty()
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(icon)
	var title := Label.new()
	title.theme_type_variation = &"CardTitle"
	title.text = str(node.get("name", node_id))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(title)
	if icon.active:
		var ab := Label.new()
		ab.theme_type_variation = &"CardTag"
		ab.text = "NEW ABILITY"
		ab.add_theme_color_override("font_color", THEME.get_color(&"band_up", &"Palette"))
		ab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(ab)
	var body := Label.new()
	body.theme_type_variation = &"CardBody"
	body.text = str(node.get("description", ""))
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	var key := Label.new()
	key.theme_type_variation = &"CardKey"
	key.text = "[ %s ]" % Hud.key_hint(PICK_ACTIONS[i]) if i < PICK_ACTIONS.size() else ""
	key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(key)
	for c: Node in col.get_children():
		(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	return card


## Icon placeholder: branch-coloured faceted badge with the node's initial (final icons: S7).
class _CardIcon:
	extends Control
	var color: Color = Color.WHITE
	var glyph: String = "?"
	var active: bool = false

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = minf(size.x, size.y) * 0.5 - 2.0
		var pts := PackedVector2Array()
		var sides: int = 6 if active else 8
		for i in sides:
			var a: float = -PI * 0.5 + TAU * float(i) / float(sides)
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(pts, Color(color, 0.22))
		# faceted look: alternate darker wedges
		for i in sides:
			if i % 2 == 0:
				draw_colored_polygon(PackedVector2Array([c, pts[i], pts[(i + 1) % sides]]), Color(color, 0.12))
		pts.append(pts[0])
		draw_polyline(pts, color, 3.0, true)
		var font: Font = get_theme_default_font()
		var fs: int = int(r * 1.05)
		var w: float = font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs).x
		var asc: float = font.get_ascent(fs) - font.get_descent(fs)
		var at := Vector2(c.x - w * 0.5, c.y + asc * 0.5)
		draw_string_outline(font, at, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, 6, Color(0.02, 0.06, 0.11))
		draw_string(font, at, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, Color(1, 1, 1))
