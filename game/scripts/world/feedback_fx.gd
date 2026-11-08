class_name FeedbackFx
extends Node3D
## Bite / kill / eat / growth feedback (GAME_DESIGN §8, art direction Q7: no red blood). Reads sim events
## (SimWorld.events_since, once per GameLoop.ticked) and entity state; never writes the sim.
##
## - BITTEN: bubbles + chunk puffs in the victim's palette colours; camera shake scaled by damage / victim max HP
##   when the player is involved; "CHOMP!" pop-up when damage >= rules feedback.chomp_min_frac of the victim max HP,
##   and a bigger one on every killing bite the player is part of (the NPC victim is already removed in that tick:
##   position and size come from its DIED event).
## - DIED: X-ray flash (victim body turns into an additive ghost with a bright skeleton inside) for
##   feedback.xray_flash_s, then the cartoon skeleton stays as remains and fades over remains.skeleton_fade_s.
##   The player killing a creature >= feedback.slowmo_min_length_ratio of its own length: slow-mo
##   (Engine.time_scale = feedback.slowmo_scale for feedback.slowmo_s real seconds) + camera punch + screen flash.
## - EATEN: gulp bubbles at the eater's mouth (player: small pulse). SPIKED: pale spike puffs (+ shake on the
##   player). INFLATED: bubble ring. BAND_UP / BAND_DOWN: HUD banner, bubble ring, pulse, camera punch.
## - Player DIED: X-ray flash + skeleton at the player and the death toast; RESPAWNED: bubbles.
## - The player's PLANKTON_EATEN (every grazing tick): XP summed in a PlanktonTally and shown as one small "+XP"
##   pop-up per PLANKTON_POPUP_TICKS window (own label pool, so it never cuts a CHOMP!), with a glow-coloured
##   puff at the mouth at most every PLANKTON_PUFF_TICKS.
## - BOSS_DEFEATED (S6 finisher): slow-mo + a full camera punch + strong shake, a big "CHOMP!" and a burst of bubbles
##   and chunks over the 10 m body; the boss DIED of the same tick gives the X-ray flash + skeleton like any kill, and
##   the giant remains are NpcViews food bits. Kept even when the boss is farther than FX_RANGE_M (it is the finisher).
## - Food sites (food task; the player's events only): SITE_BITTEN = chunk + bubble burst at the site in the food
##   type's `fx_colors`, a small shake (bite share of the site max HP), "CHOMP!" on the killing bite; SITE_EATEN =
##   bubble puff at the site, player pulse and a "+XP" pop-up (the plankton label pool). No skeleton, no slow-mo.
##
## Time: world effects (particles, flash, skeleton fade) run on scaled game time, so they slow down with the
## slow-mo. The slow-mo timer itself counts unscaled time (delta / Engine.time_scale), so it lasts slowmo_s for
## the viewer. Engine.time_scale also scales the delta GameLoop feeds to SimWorld.advance(), so the sim steps
## fewer fixed ticks per real second during slow-mo (views keep interpolating between them); every tick is still
## exactly 1/30 s of sim time, so sim results and determinism do not change.
## Particles: CPUParticles3D pools (one-shot, restart() per burst; see the class doc of _make_burst).
## Kill effects: at most KILL_CAP at once (a new kill finishes the oldest), skeletons from a fixed pool; ghosts come
## from NpcViews.take_view() (a pooled ghost model for MultiMesh fish) and go back through NpcViews.release_view().

## FX farther than this from the player are skipped (not visible through the fog anyway).
const FX_RANGE_M: float = 60.0
const BURST_POOL: int = 8
## Concurrent kill effects (X-ray ghost + skeleton); also the skeleton pool size.
const KILL_CAP: int = 8
const POPUP_POOL: int = 4
## Pop-up rise, fraction of the band camera distance.
const POPUP_RISE_FRAC: float = 0.15
## Shake (trauma 0..1) per bite: base + scale * damage fraction (player as biter / as victim).
const SHAKE_BITE_BASE: float = 0.12
const SHAKE_BITE_SCALE: float = 0.5
const SHAKE_HIT_BASE: float = 0.25
const SHAKE_HIT_SCALE: float = 0.9
const SHAKE_SPIKED: float = 0.25
const SHAKE_KILL: float = 0.35
const SHAKE_PLAYER_DIED: float = 0.8
## Kill slow-mo punch (FOV kick); the finisher gets the full PUNCH_FINISHER so it reads bigger than any kill.
const PUNCH_KILL: float = 0.7
const PUNCH_BAND: float = -0.6
## Boss finisher (S6): camera punch, shake and the pop-up scale.
const PUNCH_FINISHER: float = 1.0
const SHAKE_FINISHER: float = 0.7
const FINISHER_POPUP_SCALE: float = 2.8
## CHOMP! of a killing bite: a bit bigger than a plain big bite.
const KILL_POPUP_SCALE: float = 1.35
## Remains skeleton sinks this many body lengths per second while it fades.
const SKELETON_SINK: float = 0.08
const SKELETON_TILT_RAD_S: float = 0.5
## X-ray screen flash alpha for player kills; the finisher flash is stronger and lasts FINISHER_FLASH_S.
const SCREEN_FLASH_ALPHA: float = 0.28
const FINISHER_FLASH_ALPHA: float = 0.5
const FINISHER_FLASH_S: float = 0.4
const BUBBLE_COLOR: Color = Color(0.86, 0.97, 1.0, 0.7)
const SPIKE_COLORS: PackedColorArray = [Color(1.0, 0.96, 0.78), Color(0.96, 0.9, 0.62)]
const CHUNK_FALLBACK: PackedColorArray = [Color(1.0, 0.62, 0.25), Color(1.0, 0.86, 0.6)]
const CHOMP_COLOR: Color = Color(1.0, 0.85, 0.2)
const CHOMP_OUTLINE: Color = Color(0.22, 0.08, 0.32)
const SKELETON_SHADER: Shader = preload("res://shaders/fx_skeleton.gdshader")
const XRAY_SHADER: Shader = preload("res://shaders/fx_xray.gdshader")
const BUBBLE_SHADER: Shader = preload("res://shaders/fx_bubble.gdshader")
## Plankton grazing feedback: pop-up gap (12 ticks = 0.4 s), puff gap (6 ticks = 0.2 s), pop-up size and colours
## (the plankton palette mint + accent yellow), puff emitters.
const PLANKTON_POPUP_TICKS: int = 12
const PLANKTON_PUFF_TICKS: int = 6
const PLANKTON_POPUP_SCALE: float = 0.55
const PLANKTON_POPUP_POOL: int = 3
const PLANKTON_PUFF_POOL: int = 3
const PLANKTON_XP_COLOR: Color = Color(0.65, 1.0, 0.85)
const PLANKTON_XP_OUTLINE: Color = Color(0.05, 0.2, 0.25)
const PLANKTON_PUFF_COLORS: PackedColorArray = [Color(0.75, 1.0, 0.88, 0.9), Color(1.0, 0.9, 0.55, 0.9)]
## Skeleton vertex colours: bone (white, tinted by the shader) and eye sockets.
const BONE_TINT: Color = Color(1.0, 1.0, 1.0)
const SOCKET_TINT: Color = Color(0.18, 0.2, 0.3)

var _world: SimWorld
var _player_id: int = 0
var _npc_views: NpcViews
var _player_view: PlayerView
var _camera: CameraRig
var _hud: Hud
var _event_tick: int = 0
var _chomp_min_frac: float = 0.25
var _xray_s: float = 0.15
var _fade_s: float = 3.0
var _slowmo_scale: float = 0.3
var _slowmo_s: float = 0.6
var _slowmo_ratio: float = 0.5
var _death_loss: float = 0.5
var _slowmo_left: float = 0.0
var _bubbles: Array[CPUParticles3D] = []
var _chunks: Array[CPUParticles3D] = []
var _next_bubble: int = 0
var _next_chunk: int = 0
var _popups: Array[Label3D] = []
var _popup_tweens: Array[Tween] = []
var _next_popup: int = 0
var _skeleton_mesh: ArrayMesh
var _skeleton_mat: ShaderMaterial
var _xray_mat: ShaderMaterial
var _kills: Array[_Kill] = []
var _free_skeletons: Array[MeshInstance3D] = []
var _xp_popups: Array[Label3D] = []
var _xp_tweens: Array[Tween] = []
var _next_xp_popup: int = 0
var _puffs: Array[CPUParticles3D] = []
var _next_puff: int = 0
var _xp_tally: PlanktonTally = PlanktonTally.new(PLANKTON_POPUP_TICKS)
var _grazed: bool = false  # the player grazed in the ticks read by the current _on_ticked
var _last_puff_tick: int = -1000000
var _food_colors: Dictionary = {}  # food type id -> PackedColorArray (food `fx_colors`)


## Throttled sum of plankton XP (pure, no nodes): add(xp, tick) on every PLANKTON_EATEN, take(tick) once per tick.
## The first add() after a take opens a window; take() returns the XP summed in it once the window is gap_ticks
## old (0 before that or when nothing is pending). Steady grazing: one sum every gap_ticks; the remainder after
## grazing stops comes out gap_ticks after its first event.
class PlanktonTally:
	extends RefCounted
	var gap_ticks: int = 1
	var pending: float = 0.0
	var since: int = 0  # tick of the first add() of the open window

	func _init(p_gap_ticks: int) -> void:
		gap_ticks = p_gap_ticks

	func add(xp: float, tick: int) -> void:
		if not (pending > 0.0):
			since = tick
		pending += xp

	func take(tick: int) -> float:
		if not (pending > 0.0) or tick - since < gap_ticks:
			return 0.0
		var out: float = pending
		pending = 0.0
		return out


## Pop-up text for `xp` gathered plankton XP: one decimal below 10 ("+0.4 XP"), whole numbers above.
static func plankton_xp_text(xp: float) -> String:
	return "+%.1f XP" % maxf(xp, 0.1) if xp < 9.95 else "+%d XP" % roundi(xp)


## One kill effect: optional X-ray ghost (the victim's model) + the skeleton, aged in game time.
class _Kill:
	extends RefCounted
	var ghost: Node3D = null
	var ghost_meshes: Array[MeshInstance3D] = []
	var skeleton: MeshInstance3D
	var length: float = 1.0
	var age: float = 0.0


func setup(loop: GameLoop, player_id: int, npc_views: NpcViews, player_view: PlayerView, camera: CameraRig, hud: Hud) -> void:
	_world = loop.world
	_player_id = player_id
	_npc_views = npc_views
	_player_view = player_view
	_camera = camera
	_hud = hud
	_event_tick = _world.tick
	var rules: Dictionary = _world.content.rules() if _world.content != null else {}
	var fb: Dictionary = rules.get("feedback", {}) if rules.get("feedback") is Dictionary else {}
	_chomp_min_frac = float(fb.get("chomp_min_frac", _chomp_min_frac))
	_xray_s = float(fb.get("xray_flash_s", _xray_s))
	_slowmo_scale = clampf(float(fb.get("slowmo_scale", _slowmo_scale)), 0.05, 1.0)
	_slowmo_s = float(fb.get("slowmo_s", _slowmo_s))
	_slowmo_ratio = float(fb.get("slowmo_min_length_ratio", _slowmo_ratio))
	var remains: Dictionary = rules.get("remains", {}) if rules.get("remains") is Dictionary else {}
	_fade_s = maxf(float(remains.get("skeleton_fade_s", _fade_s)), 0.01)
	_death_loss = float(rules.get("death_xp_loss_frac", _death_loss))
	_skeleton_mesh = build_skeleton_mesh()
	_skeleton_mat = ShaderMaterial.new()
	_skeleton_mat.shader = SKELETON_SHADER
	_skeleton_mat.render_priority = 1  # drawn after the X-ray ghost it sits in
	_xray_mat = ShaderMaterial.new()
	_xray_mat.shader = XRAY_SHADER
	for i in KILL_CAP:
		var sk := MeshInstance3D.new()
		sk.mesh = _skeleton_mesh
		sk.material_override = _skeleton_mat
		sk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sk.visible = false
		add_child(sk)
		_free_skeletons.append(sk)
	for i in BURST_POOL:
		_bubbles.append(_make_burst(true))
		_chunks.append(_make_burst(false))
	for i in POPUP_POOL:
		_popups.append(_make_label(CHOMP_COLOR, CHOMP_OUTLINE))
		_popup_tweens.append(null)
	for i in PLANKTON_POPUP_POOL:
		_xp_popups.append(_make_label(PLANKTON_XP_COLOR, PLANKTON_XP_OUTLINE))
		_xp_tweens.append(null)
	for i in PLANKTON_PUFF_POOL:
		var puff: CPUParticles3D = _make_burst(false)
		puff.color_initial_ramp.set_color(0, PLANKTON_PUFF_COLORS[0])
		puff.color_initial_ramp.set_color(1, PLANKTON_PUFF_COLORS[1])
		puff.amount = 8
		_puffs.append(puff)
	# before NpcViews prunes the views of this tick's dead (take_view needs them): connect first
	loop.ticked.connect(_on_ticked)


func _exit_tree() -> void:
	# never leave the engine in slow motion (scene change, quit)
	if _slowmo_left > 0.0:
		Engine.time_scale = 1.0
		_slowmo_left = 0.0


func _notification(what: int) -> void:
	# a tree pause (pause menu, victory right after the finisher) stops _process: end the slow-mo instead of
	# leaving the menus and their tweens in slow motion
	if what == NOTIFICATION_PAUSED and _slowmo_left > 0.0:
		Engine.time_scale = 1.0
		_slowmo_left = 0.0


func _process(delta: float) -> void:
	if _world == null:
		return
	if _slowmo_left > 0.0:
		_slowmo_left -= delta / maxf(Engine.time_scale, 0.001)
		if _slowmo_left <= 0.0:
			Engine.time_scale = 1.0
	var i: int = 0
	while i < _kills.size():
		var k: _Kill = _kills[i]
		k.age += delta
		if _update_kill(k):
			i += 1
		else:
			_finish_kill(k)
			_kills.remove_at(i)


# Returns false when the effect is over (the caller finishes it).
func _update_kill(k: _Kill) -> bool:
	var flash: float = 1.0 - clampf(k.age / maxf(_xray_s, 0.001), 0.0, 1.0)
	if k.ghost != null:
		if flash <= 0.0:
			_npc_views.release_view(k.ghost)
			k.ghost = null
		else:
			for m: MeshInstance3D in k.ghost_meshes:
				m.set_instance_shader_parameter(&"fade", flash)
	var t: float = k.age - _xray_s
	k.skeleton.set_instance_shader_parameter(&"xray", flash)
	if t <= 0.0:
		return true
	var f: float = 1.0 - t / _fade_s
	if f <= 0.0:
		return false
	k.skeleton.set_instance_shader_parameter(&"fade", f * f * (3.0 - 2.0 * f))
	var dt: float = get_process_delta_time()
	k.skeleton.position.y -= SKELETON_SINK * k.length * dt
	k.skeleton.rotate_object_local(Vector3.FORWARD, SKELETON_TILT_RAD_S * dt)
	return true


# Returns the ghost to NpcViews and the skeleton to the pool.
func _finish_kill(k: _Kill) -> void:
	if k.ghost != null:
		_npc_views.release_view(k.ghost)
		k.ghost = null
	k.skeleton.visible = false
	_free_skeletons.append(k.skeleton)


func _on_ticked(_tick: int) -> void:
	var player: SimEntity = _world.get_entity(_player_id)
	var centre: Vector3 = player.position if player != null else Vector3.ZERO
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.BITTEN:
				_on_bitten(ev, centre)
			SimEvent.Type.DIED:
				_on_died(ev, player, centre)
			SimEvent.Type.EATEN:
				_on_eaten(ev, centre)
			SimEvent.Type.SPIKED:
				_on_spiked(ev, centre)
			SimEvent.Type.INFLATED:
				var pf: SimEntity = _world.get_entity(ev.entity_id)
				if pf != null and _near(pf.position, centre):
					_burst(_bubbles, pf.position, pf.length_m * 2.0, PackedColorArray(), 1.0)
			SimEvent.Type.BAND_UP, SimEvent.Type.BAND_DOWN:
				if ev.entity_id == _player_id and player != null:
					var up: bool = ev.type == SimEvent.Type.BAND_UP
					_hud.show_band(int(ev.value), up)
					_player_view.pulse(0.35 if up else -0.2)
					if up:
						_burst(_bubbles, player.position, player.length_m * 2.5, PackedColorArray(), 1.0)
						_camera.punch(PUNCH_BAND)
			SimEvent.Type.RESPAWNED:
				if ev.entity_id == _player_id and player != null:
					_burst(_bubbles, player.position, player.length_m * 3.0, PackedColorArray(), 1.0)
			SimEvent.Type.BOSS_DEFEATED:
				_on_boss_defeated(ev)
			SimEvent.Type.PLANKTON_EATEN:
				if ev.entity_id == _player_id:
					_xp_tally.add(ev.value, ev.tick)
					_grazed = true
			SimEvent.Type.SITE_BITTEN:
				if ev.entity_id == _player_id:
					_on_site_bitten(ev)
			SimEvent.Type.SITE_EATEN:
				if ev.entity_id == _player_id and player != null:
					_on_site_eaten(ev, player)
	_event_tick = _world.tick
	_on_plankton(player)


# Throttled grazing feedback: puff at the mouth at once and then at most every PLANKTON_PUFF_TICKS while grazing,
# aggregated "+XP" pop-up above it (PlanktonTally).
func _on_plankton(player: SimEntity) -> void:
	var puff: bool = _grazed and _world.tick - _last_puff_tick >= PLANKTON_PUFF_TICKS
	_grazed = false
	if puff:
		_last_puff_tick = _world.tick
	var xp: float = _xp_tally.take(_world.tick)
	if player == null or not (puff or xp > 0.0):
		return
	var mouth: Vector3 = player.position + player.heading * (player.length_m * 0.45)
	if puff:
		var p: CPUParticles3D = _puffs[_next_puff]
		_next_puff = (_next_puff + 1) % _puffs.size()
		p.position = mouth
		p.scale = Vector3.ONE * maxf(player.length_m * 0.9, 0.01)
		p.restart()
	if xp > 0.0:
		var i: int = _next_xp_popup
		_next_xp_popup = (_next_xp_popup + 1) % _xp_popups.size()
		_xp_tweens[i] = _play_popup(_xp_popups[i], _xp_tweens[i], plankton_xp_text(xp), mouth + Vector3.UP * player.length_m * 0.6, PLANKTON_POPUP_SCALE)


func _on_bitten(ev: SimEvent, centre: Vector3) -> void:
	var victim: SimEntity = _world.get_entity(ev.entity_id)
	var biter: SimEntity = _world.get_entity(ev.other_id)
	var pos: Vector3
	var size: float
	var species: StringName
	var max_hp: float
	# the killing bite: an NPC victim is removed in the same tick, its DIED event carries the position and size
	var died: SimEvent = _died_in_tick(ev) if victim == null or not victim.alive else null
	if victim != null:
		pos = victim.position
		size = victim.length_m
		species = victim.species_id
		max_hp = float(ev.data.get("max_hp", victim.max_hp))
	elif died != null:
		pos = died.data.get("pos", centre)
		size = float(died.data.get("length", 1.0))
		species = StringName(died.data.get("species", &""))
		max_hp = float(ev.data.get("max_hp", 0.0))
	else:
		return
	var frac: float = clampf(ev.value / max_hp, 0.0, 1.0) if max_hp > 0.0 else 1.0
	var involved: bool = ev.entity_id == _player_id or ev.other_id == _player_id
	if not involved and not _near(pos, centre):
		return
	# the hit point: on the victim's surface toward the biter
	var at: Vector3 = pos
	if biter != null:
		at = pos.move_toward(biter.position, size * 0.3)
	_burst(_chunks, at, size, _npc_views.species_colors(species), 0.6 + frac)
	_burst(_bubbles, at, size, PackedColorArray(), 0.6 + frac)
	if ev.other_id == _player_id:
		_camera.add_trauma(SHAKE_BITE_BASE + SHAKE_BITE_SCALE * frac)
	elif ev.entity_id == _player_id:
		_camera.add_trauma(SHAKE_HIT_BASE + SHAKE_HIT_SCALE * frac)
	# every killing bite the player is part of is a CHOMP, however small its damage share
	if involved and (frac >= _chomp_min_frac or died != null):
		_popup("CHOMP!", at + Vector3.UP * size * 0.5, KILL_POPUP_SCALE if died != null else 1.0)


# The player's bite on a food site: chunks in the food colours + bubbles, a small shake, CHOMP! on the killing bite.
func _on_site_bitten(ev: SimEvent) -> void:
	var pos: Vector3 = ev.data.get("pos", Vector3.ZERO)
	var site: int = int(ev.data.get("site", -1))
	var size: float = _world.food.site_radius(site) * 2.0 if _world.food != null and site >= 0 and site < _world.food.site_count() else 0.3
	var max_hp: float = float(ev.data.get("max_hp", 0.0))
	var frac: float = clampf(ev.value / max_hp, 0.0, 1.0) if max_hp > 0.0 else 1.0
	var killed: bool = float(ev.data.get("hp", 1.0)) <= 0.0
	_burst(_chunks, pos, size, _food_colors_of(StringName(ev.data.get("type", &""))), 0.6 + frac)
	_burst(_bubbles, pos, size, PackedColorArray(), 0.5 + frac * 0.5)
	_camera.add_trauma(SHAKE_BITE_BASE + SHAKE_BITE_SCALE * frac * 0.5)
	if killed:
		_popup("CHOMP!", pos + Vector3.UP * size * 0.5)


# The player ate a food site (swallowed egg or killed hard site): bubble puff, pulse, "+XP" pop-up.
func _on_site_eaten(ev: SimEvent, player: SimEntity) -> void:
	var pos: Vector3 = ev.data.get("pos", player.position)
	_burst(_bubbles, pos, player.length_m * 1.6, PackedColorArray(), 0.8)
	_player_view.pulse(0.12)
	if ev.value > 0.0:
		var i: int = _next_xp_popup
		_next_xp_popup = (_next_xp_popup + 1) % _xp_popups.size()
		_xp_tweens[i] = _play_popup(_xp_popups[i], _xp_tweens[i], plankton_xp_text(ev.value), pos + Vector3.UP * player.length_m * 0.8, PLANKTON_POPUP_SCALE)


func _food_colors_of(type: StringName) -> PackedColorArray:
	if _food_colors.has(type):
		return _food_colors[type]
	var cols := PackedColorArray()
	var rec: Dictionary = _world.content.get_food(type) if _world.content != null else {}
	if rec.get("fx_colors") is Array:
		for c: Variant in (rec["fx_colors"] as Array):
			cols.append(Color.html(str(c)))
	if cols.is_empty():
		cols = CHUNK_FALLBACK
	_food_colors[type] = cols
	return cols


# The DIED event of `bite`'s victim in the same tick, killed by `bite`'s biter (null when the bite did not kill).
func _died_in_tick(bite: SimEvent) -> SimEvent:
	for d: SimEvent in _world.events_since(bite.tick):
		if d.tick != bite.tick:
			break
		if d.type == SimEvent.Type.DIED and d.entity_id == bite.entity_id and d.other_id == bite.other_id:
			return d
	return null


func _on_died(ev: SimEvent, player: SimEntity, centre: Vector3) -> void:
	var pos: Vector3 = ev.data.get("pos", centre)
	var length: float = float(ev.data.get("length", 1.0))
	var species: StringName = StringName(ev.data.get("species", &""))
	var is_player: bool = ev.entity_id == _player_id
	if not is_player and ev.other_id != _player_id and not _near(pos, centre):
		return  # NpcViews frees the view
	var basis := Basis.IDENTITY
	var ghost: Node3D = null
	if is_player:
		basis = _player_view.model_basis()
		ghost = _npc_views.instantiate_model(species)
		if ghost != null:
			add_child(ghost)
			ghost.global_transform = Transform3D(basis.scaled(Vector3.ONE * length), pos)
		_camera.add_trauma(SHAKE_PLAYER_DIED)
		_hud.show_death_toast(_death_loss)
	else:
		ghost = _npc_views.take_view(ev.entity_id)
		if ghost != null:
			basis = ghost.global_transform.basis.orthonormalized()
	_spawn_kill(ghost, pos, basis, length)
	_burst(_bubbles, pos, length, PackedColorArray(), 0.8)
	_burst(_chunks, pos, length, _npc_views.species_colors(species), 1.0)
	if ev.other_id == _player_id and player != null:
		_camera.add_trauma(SHAKE_KILL)
		if length >= _slowmo_ratio * player.length_m:
			_start_slowmo()


func _on_eaten(ev: SimEvent, centre: Vector3) -> void:
	var eater: SimEntity = _world.get_entity(ev.other_id)
	if eater == null:
		return
	var is_player: bool = ev.other_id == _player_id
	if not is_player and not _near(eater.position, centre):
		return
	var mouth: Vector3 = eater.position + eater.heading * (eater.length_m * 0.45)
	_burst(_bubbles, mouth, eater.length_m * (1.8 if is_player else 1.2), PackedColorArray(), 1.0 if is_player else 0.6)
	if is_player:
		_player_view.pulse(0.12)


func _on_spiked(ev: SimEvent, centre: Vector3) -> void:
	var biter: SimEntity = _world.get_entity(ev.entity_id)
	if biter == null or (ev.entity_id != _player_id and not _near(biter.position, centre)):
		return
	var mouth: Vector3 = biter.position + biter.heading * (biter.length_m * 0.45)
	_burst(_chunks, mouth, biter.length_m * 0.8, SPIKE_COLORS, 0.8)
	if ev.entity_id == _player_id:
		_camera.add_trauma(SHAKE_SPIKED)
		_popup("OUCH!", mouth + Vector3.UP * biter.length_m * 0.4)


# The finisher: slow-mo + full punch + shake, giant CHOMP, bubble and chunk bursts over the boss body.
func _on_boss_defeated(ev: SimEvent) -> void:
	var pos: Vector3 = ev.data.get("pos", Vector3.ZERO)
	# the boss is removed in the finisher tick: its length and species come with the DIED event of the same tick
	var boss_len: float = 10.0
	var species: StringName = &""
	for d: SimEvent in _world.events_since(ev.tick):
		if d.type == SimEvent.Type.DIED and d.entity_id == ev.entity_id:
			boss_len = float(d.data.get("length", boss_len))
			species = StringName(d.data.get("species", &""))
			break
	_start_slowmo(PUNCH_FINISHER)
	_camera.add_trauma(SHAKE_FINISHER)
	_hud.flash(Color(1.0, 0.97, 0.85, FINISHER_FLASH_ALPHA), FINISHER_FLASH_S)
	# two bubble bursts (body and head end) and a chunk burst: the 10 m body erupts, not one point of it
	_burst(_bubbles, pos, boss_len * 0.5, PackedColorArray(), 2.0)
	_burst(_bubbles, pos + Vector3.UP * boss_len * 0.15, boss_len * 0.3, PackedColorArray(), 2.0)
	_burst(_chunks, pos, boss_len * 0.35, _npc_views.species_colors(species), 2.0)
	_popup("CHOMP!!", pos + Vector3.UP * boss_len * 0.25, FINISHER_POPUP_SCALE)


func _start_slowmo(punch: float = PUNCH_KILL) -> void:
	_slowmo_left = _slowmo_s
	Engine.time_scale = _slowmo_scale
	_camera.punch(punch)
	_hud.flash(Color(0.75, 0.95, 1.0, SCREEN_FLASH_ALPHA), _xray_s)


# X-ray ghost (the victim model with the X-ray material, or null) + skeleton at `pos`, oriented by `basis`.
func _spawn_kill(ghost: Node3D, pos: Vector3, basis: Basis, length: float) -> void:
	if _kills.size() >= KILL_CAP:
		_finish_kill(_kills[0])
		_kills.remove_at(0)
	var k := _Kill.new()
	k.length = length
	if ghost != null:
		k.ghost = ghost
		for n: Node in ghost.find_children("*", "MeshInstance3D", true, false):
			var m: MeshInstance3D = n as MeshInstance3D
			m.material_override = _xray_mat
			m.set_instance_shader_parameter(&"fade", 1.0)
			k.ghost_meshes.append(m)
		if ghost is MeshInstance3D:
			(ghost as MeshInstance3D).material_override = _xray_mat
			k.ghost_meshes.append(ghost as MeshInstance3D)
	var sk: MeshInstance3D = _free_skeletons.pop_back()
	sk.visible = true
	sk.global_transform = Transform3D(basis.scaled(Vector3.ONE * length), pos)
	sk.set_instance_shader_parameter(&"xray", 1.0)
	sk.set_instance_shader_parameter(&"fade", 1.0)
	_kills.append(k)
	k.skeleton = sk


func _near(p: Vector3, centre: Vector3) -> bool:
	return p.distance_squared_to(centre) <= FX_RANGE_M * FX_RANGE_M


# Next emitter of `pool` at `pos`, node scale = `size` (the whole burst scales with the creature), `colors`
# (2 entries: start/end of the colour ramp; empty = keep the emitter's own), amount scaled by `strength`.
func _burst(pool: Array[CPUParticles3D], pos: Vector3, size: float, colors: PackedColorArray, strength: float) -> void:
	var is_bubbles: bool = pool == _bubbles
	var idx: int = _next_bubble if is_bubbles else _next_chunk
	if is_bubbles:
		_next_bubble = (_next_bubble + 1) % pool.size()
	else:
		_next_chunk = (_next_chunk + 1) % pool.size()
	var p: CPUParticles3D = pool[idx]
	p.position = pos
	p.scale = Vector3.ONE * maxf(size, 0.01)
	p.amount = clampi(roundi((14.0 if is_bubbles else 10.0) * strength), 4, 32)
	if colors.size() >= 2 or (not is_bubbles and colors.is_empty()):
		var c: PackedColorArray = colors if colors.size() >= 2 else CHUNK_FALLBACK
		var g: Gradient = p.color_initial_ramp
		g.set_color(0, c[0])
		g.set_color(1, c[1])
	p.restart()


# One-shot burst emitter, local coordinates (node scale scales positions, velocities, gravity and particle size,
# so one tuning works from a 1 cm plankton to a 10 m shark). CPUParticles3D, not GPUParticles3D: bursts are
# 4-32 particles, CPU particles behave the same on Forward+ and Compatibility and need no process-shader
# compile on the first emission (no hitch at the first bite).
func _make_burst(bubbles: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 0.85 if bubbles else 0.95
	p.local_coords = true
	p.lifetime = 1.3 if bubbles else 0.75
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.25
	p.direction = Vector3.UP if bubbles else Vector3.ZERO
	p.spread = 70.0 if bubbles else 180.0
	p.initial_velocity_min = 0.4 if bubbles else 0.8
	p.initial_velocity_max = 1.2 if bubbles else 2.0
	p.gravity = Vector3(0.0, 1.4, 0.0) if bubbles else Vector3(0.0, -0.6, 0.0)
	p.damping_min = 1.0 if bubbles else 3.0
	p.damping_max = 2.0 if bubbles else 4.0
	p.scale_amount_min = 0.03 if bubbles else 0.07
	p.scale_amount_max = 0.08 if bubbles else 0.14
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(0.25, 1.0))
	curve.add_point(Vector2(1.0, 1.0 if bubbles else 0.0))
	p.scale_amount_curve = curve
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	var tint := Gradient.new()
	tint.set_color(0, BUBBLE_COLOR if bubbles else CHUNK_FALLBACK[0])
	tint.set_color(1, BUBBLE_COLOR if bubbles else CHUNK_FALLBACK[1])
	p.color_initial_ramp = tint
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8 if bubbles else 5
	mesh.rings = 4 if bubbles else 3
	if bubbles:
		var bubble_mat := ShaderMaterial.new()
		bubble_mat.shader = BUBBLE_SHADER
		mesh.material = bubble_mat
	else:
		# flat palette colour (unshaded: lit chunks went olive in the shadow band)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material = mat
	p.mesh = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


# Arcade text pop-up (Label3D, fixed screen size): scale-in with overshoot, rise, fade (kill-before-recreate).
func _popup(text: String, at: Vector3, size_mult: float = 1.0) -> void:
	var i: int = _next_popup
	_next_popup = (_next_popup + 1) % _popups.size()
	_popup_tweens[i] = _play_popup(_popups[i], _popup_tweens[i], text, at, size_mult)


# Animates one pooled pop-up label (kills its previous tween `old`); returns the new tween.
func _play_popup(label: Label3D, old: Tween, text: String, at: Vector3, size_mult: float) -> Tween:
	if old != null and old.is_valid():
		old.kill()
	label.text = text
	label.position = at
	label.visible = true
	label.scale = Vector3.ONE * 0.3
	label.modulate.a = 1.0
	label.outline_modulate.a = 1.0
	var tw: Tween = create_tween().bind_node(label)
	tw.set_parallel(true)
	tw.tween_property(label, ^"scale", Vector3.ONE * 1.15 * size_mult, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, ^"position", at + Vector3.UP * POPUP_RISE_FRAC * _camera.band_distance(), 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, ^"modulate:a", 0.0, 0.3).set_delay(0.5)
	tw.tween_property(label, ^"outline_modulate:a", 0.0, 0.3).set_delay(0.5)
	tw.chain().tween_callback(label.hide)
	return tw


# Pooled pop-up label (Label3D, billboard, fixed screen size, drawn over the scene), hidden.
func _make_label(color: Color, outline: Color) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0009
	label.font_size = 64
	label.outline_size = 18
	label.modulate = color
	label.outline_modulate = outline
	label.visible = false
	add_child(label)
	return label


## Unit-length cartoon fish skeleton (nose -Z, centre at the origin, like the species GLBs): skull with dark
## eye sockets, jaw, spine, five rib hoops hanging under the spine, tail fin. Primitive meshes merged into one
## surface with vertex colours (part = [mesh, transform, colour]).
static func build_skeleton_mesh() -> ArrayMesh:
	var parts: Array = []
	var skull := SphereMesh.new()
	skull.radius = 0.11
	skull.height = 0.2
	skull.radial_segments = 8
	skull.rings = 5
	parts.append([skull, Transform3D(Basis.from_scale(Vector3(0.9, 1.0, 1.3)), Vector3(0.0, 0.0, -0.36))])
	var socket := SphereMesh.new()
	socket.radius = 0.04
	socket.height = 0.08
	socket.radial_segments = 6
	socket.rings = 3
	for side in [-1.0, 1.0]:
		parts.append([socket, Transform3D(Basis.from_scale(Vector3(0.5, 1.0, 1.0)), Vector3(0.088 * side, 0.025, -0.38)), SOCKET_TINT])
	var jaw := PrismMesh.new()
	jaw.size = Vector3(0.16, 0.12, 0.09)
	parts.append([jaw, Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0)), Vector3(0.0, -0.1, -0.42))])
	var spine := CylinderMesh.new()
	spine.top_radius = 0.016
	spine.bottom_radius = 0.012
	spine.height = 0.72
	spine.radial_segments = 6
	spine.rings = 1
	parts.append([spine, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 0.0, 0.08))])
	for i in 5:
		var r: float = lerpf(0.13, 0.06, float(i) / 4.0)
		var rib := TorusMesh.new()
		rib.inner_radius = r - 0.012
		rib.outer_radius = r
		rib.rings = 10
		rib.ring_segments = 4
		# hoop in the XY plane (torus axis = Z), hanging under the spine
		parts.append([rib, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, -r * 0.85, -0.14 + 0.1 * float(i)))])
	var tail := PrismMesh.new()
	tail.size = Vector3(0.34, 0.18, 0.02)
	tail.left_to_right = 0.5
	# prism X (base) -> -Y, prism Y (apex) -> -Z toward the spine, prism Z (thickness) -> X
	parts.append([tail, Transform3D(Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0)), Vector3(0.0, 0.0, 0.41))])
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for part: Array in parts:
		var arrays: Array = (part[0] as PrimitiveMesh).get_mesh_arrays()
		var xf: Transform3D = part[1]
		var tint: Color = part[2] if part.size() > 2 else BONE_TINT
		var nb: Basis = xf.basis.inverse().transposed()
		var base: int = verts.size()
		var pv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var pn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for j in pv.size():
			verts.append(xf * pv[j])
			normals.append((nb * pn[j]).normalized())
			colors.append(tint)
		var idx_v: Variant = arrays[Mesh.ARRAY_INDEX]
		var pi_arr: PackedInt32Array = idx_v if idx_v is PackedInt32Array else PackedInt32Array()
		if pi_arr.is_empty():
			for j in pv.size():
				indices.append(base + j)
		else:
			for j in pi_arr:
				indices.append(base + j)
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_COLOR] = colors
	out[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return mesh
