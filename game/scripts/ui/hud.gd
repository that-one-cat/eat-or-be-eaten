class_name Hud
extends CanvasLayer
## Final in-game HUD (GAME_DESIGN §10; art direction Q9: clean HUD, loud pop-ups only at effect moments). Built in
## code under one root Control that carries the shared Theme (res://ui/theme/main_theme.tres); every Control ignores
## the mouse (left click is the bite). Reads sim state and events only, never writes the sim.
##  - top-left: band badge + growth bar (XP to the next band), health, hunger;
##  - bottom-left: boost bar (stamina) + three ability slots (Boost, Bite-Dash, Sonar): locked slots greyed with a
##    lock, cooldown sweep + seconds from SimWorld.ability_cooldown_left(), a pop when an ability becomes ready, key
##    hints from the InputMap;
##  - top-right: run timer (SimWorld.run_ticks) and deaths;
##  - top-centre: boss HP bar (+ a trailing "chip" bar) while SimWorld.boss_engaged(), title from the species name;
##  - edge presence markers (PresenceIndicators);
##  - centre banners (band up / down, new ability, boss stunned), the death toast, a full-screen flash (kill
##    feedback) and an edge vignette (boss telegraph). Called by FeedbackFx / BossFx.
## Events are read on GameLoop.ticked with the cursor convention, only when the tick advanced (a world paused for a
## mutation pick re-emits `ticked` with the same tick; reading then would return the pick events twice).

const THEME: Theme = preload("res://ui/theme/main_theme.tres")
const MARGIN: float = 18.0
const BAR_W: float = 230.0
const BAR_H: float = 12.0
const BOSS_BAR_W: float = 440.0
const BOSS_BAR_H: float = 14.0
const SLOT_SIZE: float = 58.0
## Boss chip bar catch-up rate (fraction per real second toward the HP bar).
const CHIP_RATE: float = 1.6
const BOSS_FADE_S: float = 0.35
const ABILITY_IDS: Array[StringName] = [&"boost", &"bite_dash", &"sonar"]

var _world: SimWorld
var _entity_id: int = 0
var _event_tick: int = 0
var _root: Control
var _band_label: Label
var _xp_bar: ProgressBar
var _hp_bar: ProgressBar
var _hunger_bar: ProgressBar
var _boost_bar: ProgressBar
var _slots: Array[_AbilitySlot] = []
var _timer_label: Label
var _deaths_label: Label
var _boss_box: VBoxContainer
var _boss_title: Label
var _boss_bar: ProgressBar
var _boss_chip: ProgressBar
var _boss_name: String = "BOSS"
var _boss_shown: bool = false
var _boss_tween: Tween
var _presence: PresenceIndicators
var _banner: Label
var _toast: Label
var _flash: ColorRect
var _vignette: TextureRect
var _banner_tween: Tween
var _toast_tween: Tween
var _flash_tween: Tween
var _vignette_tween: Tween
var _hunger_max: float = 100.0
var _stamina_max: float = 100.0
var _cooldown_total: Dictionary[StringName, float] = {}


## Builds the HUD for `entity_id`; `camera` feeds the presence indicators (null = no markers).
func setup(loop: GameLoop, entity_id: int, camera: Camera3D) -> void:
	_world = loop.world
	_entity_id = entity_id
	_event_tick = _world.tick
	if _world.content != null:
		_hunger_max = float(_world.content.rules().get("hunger_max", _hunger_max))
		_stamina_max = float(_world.content.get_ability(&"boost").get("stamina_max", _stamina_max))
		for a: StringName in ABILITY_IDS:
			_cooldown_total[a] = float(_world.content.get_ability(a).get("cooldown_s", 0.0))
	_build(camera)
	loop.ticked.connect(_on_ticked)
	_process(0.0)


func _build(camera: Camera3D) -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.theme = THEME
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_flash = ColorRect.new()
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 1, 1, 0)
	_root.add_child(_flash)

	_vignette = TextureRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.texture = _vignette_texture()
	_vignette.modulate = Color(1, 1, 1, 0)
	_root.add_child(_vignette)

	_presence = PresenceIndicators.new()
	_presence.name = "PresenceIndicators"
	_presence.z_index = 1  # above the HUD panels (a marker may sit in a corner)
	_root.add_child(_presence)
	_presence.setup(_world, _entity_id, camera)

	# top-left: band + growth / health / hunger
	var tl := _panel(_root)
	tl.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tl.position = Vector2(MARGIN, MARGIN)
	var tl_row := HBoxContainer.new()
	tl_row.add_theme_constant_override("separation", 12)
	tl_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl.add_child(tl_row)
	var badge := PanelContainer.new()
	badge.theme_type_variation = &"BandBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tl_row.add_child(badge)
	_band_label = _label(&"HudTitle")
	_band_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(_band_label)
	var bars := VBoxContainer.new()
	bars.add_theme_constant_override("separation", 3)
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl_row.add_child(bars)
	_xp_bar = _bar(bars, "GROWTH", &"GrowthBar", BAR_W)
	_hp_bar = _bar(bars, "HEALTH", &"HealthBar", BAR_W)
	_hunger_bar = _bar(bars, "HUNGER", &"HungerBar", BAR_W)

	# bottom-left: boost bar + ability slots
	var bl := _panel(_root)
	bl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	bl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bl.offset_left = MARGIN
	bl.offset_bottom = -MARGIN
	var bl_col := VBoxContainer.new()
	bl_col.add_theme_constant_override("separation", 6)
	bl_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl.add_child(bl_col)
	var slot_row := HBoxContainer.new()
	slot_row.add_theme_constant_override("separation", 8)
	slot_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl_col.add_child(slot_row)
	for a: StringName in ABILITY_IDS:
		var slot := _AbilitySlot.new()
		slot.ability = a
		slot.key_text = key_hint(a)
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_row.add_child(slot)
		_slots.append(slot)
	_boost_bar = _bar(bl_col, "BOOST", &"BoostBar", SLOT_SIZE * 3.0 + 16.0 - 60.0)

	# top-right: timer + deaths
	var tr := _panel(_root)
	tr.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	tr.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	tr.offset_right = -MARGIN
	tr.offset_top = MARGIN
	var tr_col := VBoxContainer.new()
	tr_col.add_theme_constant_override("separation", 0)
	tr_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.add_child(tr_col)
	_timer_label = _label(&"HudValue")
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_timer_label.custom_minimum_size = Vector2(96.0, 0.0)
	tr_col.add_child(_timer_label)
	_deaths_label = _label(&"HudSmall")
	_deaths_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr_col.add_child(_deaths_label)

	# top-centre: boss bar
	_boss_box = VBoxContainer.new()
	_boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_box.add_theme_constant_override("separation", 2)
	_boss_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_boss_box.offset_left = -BOSS_BAR_W * 0.5
	_boss_box.offset_right = BOSS_BAR_W * 0.5
	_boss_box.offset_top = MARGIN
	_root.add_child(_boss_box)
	_boss_title = _label(&"HudSmall")
	_boss_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_title.add_theme_font_size_override("font_size", 15)
	_boss_box.add_child(_boss_title)
	var stack := Control.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.custom_minimum_size = Vector2(BOSS_BAR_W, BOSS_BAR_H)
	_boss_box.add_child(stack)
	_boss_chip = _plain_bar(&"BossChipBar")
	_boss_bar = _plain_bar(&"BossBar")
	for b: ProgressBar in [_boss_chip, _boss_bar]:
		b.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.add_child(b)
	# the chip shows through the HP bar's background: keep that background translucent
	_boss_box.modulate.a = 0.0
	_boss_box.visible = false

	_banner = _centre_label(&"HudBanner", -150.0)
	_toast = _centre_label(&"HudToast", 70.0)


func _process(delta: float) -> void:
	if _world == null:
		return
	var e: SimEntity = _world.get_entity(_entity_id)
	if e == null:
		return
	_band_label.text = "B%d" % e.band
	_hp_bar.value = clampf(e.hp / e.max_hp, 0.0, 1.0) if e.max_hp > 0.0 else 0.0
	_hunger_bar.value = clampf(e.hunger / _hunger_max, 0.0, 1.0) if _hunger_max > 0.0 else 0.0
	_xp_bar.value = _band_progress(e)
	_boost_bar.value = clampf(e.stamina / _stamina_max, 0.0, 1.0) if _stamina_max > 0.0 else 0.0
	_timer_label.text = format_run_time(_world.run_ticks)
	_deaths_label.text = "DEATHS %d" % e.deaths
	for slot: _AbilitySlot in _slots:
		var unlocked: bool = slot.ability == &"boost" or e.abilities.has(String(slot.ability))
		var left: float = _world.ability_cooldown_left(_entity_id, slot.ability) if unlocked else 0.0
		var total: float = maxf(_cooldown_total.get(slot.ability, 0.0), left)
		var active: bool = e.boosting if slot.ability == &"boost" else (e.dash_until_tick > _world.tick and e.dash_ability == slot.ability)
		slot.set_state(unlocked, left, total, active)
	_update_boss(delta)


func _update_boss(delta: float) -> void:
	var boss: SimEntity = _world.get_entity(_world.boss_id())
	var show: bool = boss != null and _world.boss_engaged()
	if show != _boss_shown:
		_boss_shown = show
		if show and _world.content != null:
			_boss_name = str(_world.content.get_species(boss.species_id).get("name", _boss_name)).to_upper()
		if _boss_tween != null and _boss_tween.is_valid():
			_boss_tween.kill()
		_boss_box.visible = true
		if show:
			_boss_chip.value = _boss_bar.value
		_boss_tween = create_tween().bind_node(_boss_box).set_ignore_time_scale(true)
		_boss_tween.tween_property(_boss_box, ^"modulate:a", 1.0 if show else 0.0, BOSS_FADE_S).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		if not show:
			_boss_tween.tween_callback(_boss_box.hide)
	if boss == null:
		return
	var frac: float = clampf(boss.hp / boss.max_hp, 0.0, 1.0) if boss.max_hp > 0.0 else 0.0
	_boss_bar.value = frac
	var real_dt: float = delta / maxf(Engine.time_scale, 0.001)
	_boss_chip.value = frac if frac > _boss_chip.value else move_toward(_boss_chip.value, frac, CHIP_RATE * real_dt * maxf(_boss_chip.value - frac, 0.05))
	var stunned: bool = boss.boss_state == BossBrain.State.STUNNED
	_boss_title.text = ("%s  -  STUNNED" % _boss_name) if stunned else _boss_name


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		if ev.entity_id != _entity_id and ev.type != SimEvent.Type.BOSS_STUNNED:
			continue
		match ev.type:
			SimEvent.Type.MUTATION_PICKED:
				var ability: String = str(ev.data.get("ability", ""))
				var node: Dictionary = _world.content.get_mutation(StringName(str(ev.data.get("node_id", "")))) if _world.content != null else {}
				if not ability.is_empty():
					show_banner("NEW: %s  [%s]" % [str(_world.content.get_ability(StringName(ability)).get("name", ability)).to_upper(), key_hint(StringName(ability))], THEME.get_color(&"band_up", &"Palette"))
				elif not node.is_empty():
					show_banner("+ %s" % str(node.get("name", "")).to_upper(), THEME.get_color(&"accent", &"Palette"), 1.0)
			SimEvent.Type.BOSS_STUNNED:
				show_banner("STUNNED!  BITE IT!", THEME.get_color(&"band_up", &"Palette"), 2.0)
	_event_tick = _world.tick


## Centre banner for a band change (`up` false = band lost).
func show_band(band: int, up: bool) -> void:
	show_banner(("BAND %d!" % band) if up else ("BAND %d" % band), THEME.get_color(&"band_up" if up else &"band_down", &"Palette"))


## Loud centre pop-up (effect moments only): pop-in with overshoot, hold `hold_s`, fade.
func show_banner(text: String, color: Color, hold_s: float = 1.6) -> void:
	_banner.text = text
	_banner.modulate = color
	_banner_tween = _pop(_banner, _banner_tween, hold_s)


## Death toast: "-50% growth" from rules death_xp_loss_frac.
func show_death_toast(loss_frac: float) -> void:
	_toast.text = "-%d%% growth" % roundi(loss_frac * 100.0)
	_toast.modulate = THEME.get_color(&"toast", &"Palette")
	_toast_tween = _pop(_toast, _toast_tween, 2.6)


## Full-screen colour flash that fades out over `duration_s` (real time, unaffected by slow-mo).
func flash(color: Color, duration_s: float) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash.color = color
	_flash_tween = create_tween().bind_node(_flash).set_ignore_time_scale(true)
	_flash_tween.tween_property(_flash, ^"color:a", 0.0, maxf(duration_s, 0.01) * 2.0).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)


## Screen-edge vignette in `color`: quick fade-in, pulses while held for `duration_s` (real time), then fades out.
func vignette(color: Color, duration_s: float) -> void:
	if _vignette_tween != null and _vignette_tween.is_valid():
		_vignette_tween.kill()
	_vignette.modulate = Color(color, 0.0)
	_vignette_tween = create_tween().bind_node(_vignette).set_ignore_time_scale(true)
	var hold: float = maxf(duration_s - 0.3, 0.05)
	_vignette_tween.tween_property(_vignette, ^"modulate:a", color.a, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_vignette_tween.tween_property(_vignette, ^"modulate:a", color.a * 0.55, hold * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_vignette_tween.tween_property(_vignette, ^"modulate:a", color.a, hold * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_vignette_tween.tween_property(_vignette, ^"modulate:a", 0.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


## A full-screen overlay (mutation pick) opened / closed: presence markers and the centre banner make way.
func set_overlay_open(on: bool) -> void:
	_presence.visible = not on
	if on:
		if _banner_tween != null and _banner_tween.is_valid():
			_banner_tween.kill()
		_banner.hide()


## Run timer text: m:ss, h:mm:ss from one hour.
static func format_run_time(run_ticks: int) -> String:
	var secs: int = int(float(run_ticks) * SimWorld.TICK_DT)
	if secs >= 3600:
		return "%d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60]
	return "%d:%02d" % [secs / 60, secs % 60]


## Short key hint of the first InputMap event of `action` ("Shift", "RMB", "Q"; "" when unbound).
static func key_hint(action: StringName) -> String:
	if not InputMap.has_action(action):
		return ""
	for ev: InputEvent in InputMap.action_get_events(action):
		var mb: InputEventMouseButton = ev as InputEventMouseButton
		if mb != null:
			match mb.button_index:
				MOUSE_BUTTON_LEFT:
					return "LMB"
				MOUSE_BUTTON_RIGHT:
					return "RMB"
				MOUSE_BUTTON_MIDDLE:
					return "MMB"
			return "M%d" % mb.button_index
		var k: InputEventKey = ev as InputEventKey
		if k != null:
			# physical keycodes name the US-layout key (DisplayServer layout lookups are not available headless)
			return OS.get_keycode_string(k.keycode if k.keycode != KEY_NONE else k.physical_keycode)
	return ""


# XP progress from the current band threshold to the next one (last band: to xp_full_length).
func _band_progress(e: SimEntity) -> float:
	if _world.content == null:
		return 0.0
	var band: Dictionary = _world.content.get_band(e.band)
	var lo: float = float(band.get("xp_to_reach", 0.0))
	var hi: float = float(_world.content.get_band(e.band + 1).get("xp_to_reach", band.get("xp_full_length", lo)))
	return clampf((e.xp - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 1.0


# Pop-in with overshoot, hold, fade (kill-before-recreate, ignores slow-mo).
func _pop(label: Label, old: Tween, hold_s: float) -> Tween:
	if old != null and old.is_valid():
		old.kill()
	label.visible = true
	label.modulate.a = 1.0
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2.ONE * 0.4
	var tw: Tween = create_tween().bind_node(label).set_ignore_time_scale(true)
	tw.tween_property(label, ^"scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(hold_s)
	tw.tween_property(label, ^"modulate:a", 0.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(label.hide)
	return tw


func _panel(parent: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = &"HudPanel"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	return p


func _bar(parent: Control, title: String, variation: StringName, width: float) -> ProgressBar:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var name_label: Label = _label(&"HudSmall")
	name_label.text = title
	name_label.custom_minimum_size = Vector2(56.0, 0.0)
	row.add_child(name_label)
	var bar: ProgressBar = _plain_bar(variation)
	bar.custom_minimum_size = Vector2(width, BAR_H)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)
	return bar


func _plain_bar(variation: StringName) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.theme_type_variation = variation
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.0
	bar.show_percentage = false
	return bar


func _label(variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _centre_label(variation: StringName, y: float) -> Label:
	var l: Label = _label(variation)
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.offset_left = -400.0
	l.offset_right = 400.0
	l.offset_top = y
	l.offset_bottom = y + 64.0
	l.visible = false
	_root.add_child(l)
	return l


# Radial edge gradient (transparent centre, white edges; tinted by modulate).
static func _vignette_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 0.9))
	g.add_point(0.55, Color(1, 1, 1, 0))
	g.add_point(0.82, Color(1, 1, 1, 0.35))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 144
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.2, 0.5)
	return t


## One ability slot: rounded tile, procedural icon, key hint, lock when not granted, cooldown sweep + seconds,
## highlight while active (boosting / lunging), a short pop when the cooldown ends.
class _AbilitySlot:
	extends Control
	var ability: StringName = &""
	var key_text: String = ""
	var _unlocked: bool = false
	var _left: float = 0.0
	var _total: float = 0.0
	var _active: bool = false
	var _pop_tween: Tween

	func set_state(unlocked: bool, left: float, total: float, active: bool) -> void:
		var ready_now: bool = _unlocked and _left > 0.0 and left <= 0.0
		if unlocked == _unlocked and is_equal_approx(left, _left) and active == _active and total == _total:
			return
		_unlocked = unlocked
		_left = left
		_total = total
		_active = active
		if ready_now:
			_pop()
		queue_redraw()

	func _pop() -> void:
		if _pop_tween != null and _pop_tween.is_valid():
			_pop_tween.kill()
		pivot_offset = size * 0.5
		scale = Vector2.ONE * 1.18
		_pop_tween = create_tween().bind_node(self).set_ignore_time_scale(true)
		_pop_tween.tween_property(self, ^"scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var accent: Color = get_theme_color(&"accent", &"Palette")
		var locked_c: Color = get_theme_color(&"locked", &"Palette")
		var bg := Color(0.03, 0.1, 0.16, 0.85) if _unlocked else Color(0.03, 0.07, 0.1, 0.6)
		var border: Color = Color(1.0, 0.95, 0.75) if _active else (Color(accent, 0.6) if _unlocked else Color(locked_c, 0.35))
		_round_rect(r, bg, 9.0)
		var c: Vector2 = r.get_center() - Vector2(0.0, 4.0)
		var icon_c: Color = Color(0.95, 0.99, 1.0) if _unlocked else Color(locked_c, 0.55)
		match ability:
			&"boost":
				for i in 2:
					var y: float = c.y + 7.0 - 9.0 * float(i)
					draw_polyline(PackedVector2Array([Vector2(c.x - 10.0, y + 6.0), Vector2(c.x, y - 4.0), Vector2(c.x + 10.0, y + 6.0)]), icon_c, 3.5, true)
			&"bite_dash":
				for i in 3:
					var y2: float = c.y - 6.0 + 6.0 * float(i)
					draw_line(Vector2(c.x - 15.0, y2), Vector2(c.x - 5.0 + 2.0 * float(i % 2), y2), Color(icon_c, 0.7), 2.0, true)
				var jaw := PackedVector2Array([Vector2(c.x - 2.0, c.y - 10.0), Vector2(c.x + 14.0, c.y - 3.0), Vector2(c.x + 4.0, c.y), Vector2(c.x + 14.0, c.y + 3.0), Vector2(c.x - 2.0, c.y + 10.0)])
				draw_polyline(jaw, icon_c, 3.0, true)
				for t in 3:
					var tx: float = c.x + 1.0 + 4.0 * float(t)
					draw_line(Vector2(tx, c.y - 8.0 + 1.6 * float(t)), Vector2(tx + 1.5, c.y - 4.0 + 1.6 * float(t)), icon_c, 2.0, true)
			&"sonar":
				draw_circle(c + Vector2(-8.0, 0.0), 3.0, icon_c)
				for i in 3:
					draw_arc(c + Vector2(-8.0, 0.0), 7.0 + 6.0 * float(i), -0.9, 0.9, 12, Color(icon_c, 1.0 - 0.22 * float(i)), 2.5, true)
		if not _unlocked:
			# lock glyph bottom-right
			var lc: Vector2 = Vector2(r.end.x - 13.0, r.end.y - 22.0)
			draw_rect(Rect2(lc - Vector2(6.0, 0.0), Vector2(12.0, 9.0)), Color(locked_c, 0.9))
			draw_arc(lc, 4.0, PI, TAU, 8, Color(locked_c, 0.9), 2.0, true)
		elif _left > 0.0 and _total > 0.0:
			var frac: float = clampf(_left / _total, 0.0, 1.0)
			var pts := PackedVector2Array([r.get_center()])
			var steps: int = maxi(3, int(32.0 * frac))
			var rad: float = r.size.length() * 0.5
			for i in steps + 1:
				var a: float = -PI * 0.5 + TAU * (1.0 - frac) + TAU * frac * float(i) / float(steps)
				var p: Vector2 = r.get_center() + Vector2(cos(a), sin(a)) * rad
				pts.append(Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y)))
			draw_colored_polygon(pts, Color(0.0, 0.03, 0.06, 0.62))
			var font: Font = get_theme_default_font()
			var txt: String = str(ceili(_left))
			var fs: int = 20
			var w: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs).x
			draw_string_outline(font, Vector2(r.get_center().x - w * 0.5, r.get_center().y + 6.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, 4, Color(0.02, 0.06, 0.11))
			draw_string(font, Vector2(r.get_center().x - w * 0.5, r.get_center().y + 6.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, Color(1, 1, 1))
		_round_rect_outline(r, border, 9.0, 2.0 if not _active else 3.0)
		if not key_text.is_empty():
			var f: Font = get_theme_default_font()
			var ks: int = 11
			var kw: float = f.get_string_size(key_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ks).x
			var kp := Vector2(r.get_center().x - kw * 0.5, r.end.y - 5.0)
			draw_string_outline(f, kp, key_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ks, 3, Color(0.02, 0.06, 0.11))
			draw_string(f, kp, key_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ks, Color(0.85, 0.93, 1.0, 0.9) if _unlocked else Color(locked_c, 0.8))

	func _round_rect(r: Rect2, color: Color, radius: float) -> void:
		draw_colored_polygon(_round_pts(r, radius), color)

	func _round_rect_outline(r: Rect2, color: Color, radius: float, width: float) -> void:
		var pts: PackedVector2Array = _round_pts(r.grow(-width * 0.5), radius)
		pts.append(pts[0])
		draw_polyline(pts, color, width, true)

	static func _round_pts(r: Rect2, radius: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		var corners: Array[Vector2] = [r.position + Vector2(r.size.x - radius, radius), r.end - Vector2(radius, radius), r.position + Vector2(radius, r.size.y - radius), r.position + Vector2(radius, radius)]
		for ci in 4:
			for s in 5:
				var a: float = -PI * 0.5 + PI * 0.5 * float(ci) + PI * 0.5 * float(s) / 4.0
				pts.append(corners[ci] + Vector2(cos(a), sin(a)) * radius)
		return pts
