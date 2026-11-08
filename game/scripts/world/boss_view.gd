class_name BossView
extends Node
## Hero rig of the giant shark boss (S7): drives the FishRig AnimationTree on the boss node view (NpcViews.view_node,
## the rigged GLB from CrowdAssets.RIG_MODELS). Reads events and entity state only, never writes the sim; the node
## transform stays NpcViews' + BossFx's (BossFx creates this node).
##  - swim rate from the speed (SWIM_RATE_MIN..MAX beats/s up to the species swim speed; the charge runs at the
##    top rate), slow while STUNNED; turn bend from the yaw rate.
##  - BOSS_TELL: the wind-up pose (wide gape, nose up, coiled body) eases in over the first 30% of the wind-up, like
##    BossFx's nose-up arch (both kept: the node arch reads from far away, the rig gape and coil up close).
##  - BOSS_DASH: burst stroke one-shot, the tell pose releases. Boss bites (BITTEN with the boss as the biter,
##    incl. a charge hit): bite snap.
## Timers run on game time (scaled delta), like the sim seconds they mirror.

const SWIM_RATE_MIN: float = 0.3
const SWIM_RATE_MAX: float = 1.1
const SWIM_RATE_STUNNED: float = 0.2
const SPEED_FALLBACK_MPS: float = 7.0
## Yaw rate (rad/s) that gives the full turn bend.
const TURN_FULL_RATE: float = 0.9
const TURN_SMOOTHING: float = 4.0
const TELL_EASE_FRAC: float = 0.3
const TELL_RELEASE: float = 10.0

var _world: SimWorld
var _npc_views: NpcViews
var _event_tick: int = 0
var _boss_id: int = -1
var _rig: FishRig = null
var _node: Node3D = null
var _top_speed: float = SPEED_FALLBACK_MPS
var _prev_yaw: float = 0.0
var _yaw_rate: float = 0.0
var _turn: float = 0.0
var _tell: float = 0.0
var _tell_total: float = 0.0
var _tell_left: float = 0.0


func setup(loop: GameLoop, npc_views: NpcViews) -> void:
	_world = loop.world
	_npc_views = npc_views
	_event_tick = _world.tick
	loop.ticked.connect(_on_ticked)


func _on_ticked(_tick: int) -> void:
	var boss: SimEntity = _world.get_entity(_world.boss_id())
	if boss != null:
		var yaw: float = deg_to_rad(boss.yaw_deg)
		_yaw_rate = angle_difference(_prev_yaw, yaw) / SimWorld.TICK_DT if boss.id == _boss_id else 0.0
		_prev_yaw = yaw
		if boss.id != _boss_id:
			_boss_id = boss.id
			var rec: Dictionary = _world.content.get_species(boss.species_id) if _world.content != null else {}
			_top_speed = maxf(float(rec.get("swim_speed_mps", SPEED_FALLBACK_MPS)), 0.1)
	if _world.tick == _event_tick:
		return
	if _rig != null and not is_instance_valid(_rig):
		_rig = null  # the finisher handed the boss node to FeedbackFx, which freed it
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.BOSS_TELL:
				_tell_total = maxf(ev.value, 0.05)
				_tell_left = _tell_total
			SimEvent.Type.BOSS_DASH:
				_tell_left = 0.0
				if _rig != null:
					_rig.dash()
			SimEvent.Type.BITTEN:
				if ev.other_id == _boss_id and _rig != null:
					_rig.bite()
			SimEvent.Type.BOSS_STUNNED, SimEvent.Type.BOSS_DEFEATED:
				_tell_left = 0.0
	_event_tick = _world.tick


func _process(delta: float) -> void:
	if _world == null:
		return
	var boss: SimEntity = _world.get_entity(_world.boss_id())
	var node: Node3D = _npc_views.view_node(boss.id) if boss != null else null
	if node != _node:
		_node = node
		_rig = FishRig.attach(node) if node != null else null
	if _rig == null:
		return
	_tell_left = maxf(_tell_left - delta, 0.0)
	if _tell_left > 0.0:
		_tell = smoothstep(0.0, TELL_EASE_FRAC, 1.0 - _tell_left / _tell_total)
	else:
		_tell = lerpf(_tell, 0.0, 1.0 - exp(-TELL_RELEASE * delta))
	_rig.set_tell(_tell if _tell > 0.01 else 0.0)
	var rate: float = lerpf(SWIM_RATE_MIN, SWIM_RATE_MAX, clampf(boss.velocity.length() / _top_speed, 0.0, 1.0))
	if boss.boss_state == BossBrain.State.STUNNED:
		rate = SWIM_RATE_STUNNED
	_rig.set_swim_rate(rate)
	_turn = lerpf(_turn, clampf(_yaw_rate / TURN_FULL_RATE, -1.0, 1.0), 1.0 - exp(-TURN_SMOOTHING * delta))
	_rig.set_turn(_turn)
