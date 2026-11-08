class_name DemoFx
extends RefCounted
## Dev scenario for feedback captures (user arg `-- --demo-fx`, reef_greybox.tscn): a scripted, deterministic
## situation right in front of the player spawn that triggers every S3 feedback in order:
## swallow a plankton cell -> bite a puffer twice (inflate + spikes, CHOMP!) -> kill a small reef fish >= 50% of
## the player's length (X-ray flash, skeleton, slow-mo, camera punch) -> swallow the remains bits and a plankton
## trail -> band up (B1 -> B2), then cruise on.
## Setup is a fixture like the test scenarios: it places NPCs through NpcSpawner.spawn_npc, turns the brains off
## (targets hold still, the puffer does not bite back) and starts the player at START_XP so the band-up comes
## within seconds. After that the player is driven only through SimCommands, one call per tick (like
## SwimTourAutopilot). Prints `DEMO_FX <step> tick=<t> frame=<f>` lines to time captures.
## S6: the band-up opens a mutation offer that pauses the sim until a pick arrives; the demo auto-picks the first
## offered node with a PICK_MUTATION command right away (no overlay: reef_greybox.gd sets the pick overlay up only
## for PlayerInput play), so the demo does not freeze at the band-up. The pause stays on (the sim path is the real one).

const START_XP: float = 90.0
const PLANKTON_LEN_M: float = 0.015
const PUFFER_LEN_M: float = 0.35
const VICTIM_LEN_M: float = 0.2
const TRAIL_COUNT: int = 8
## Player bites the puffer this many times before moving on.
const PUFFER_BITES: int = 2
## Ticks the player brakes after the kill (slow-mo and remains in view).
const HOLD_TICKS: int = 45
## BITE is sent every tick inside this distance (the sim checks the mouth cone and the cooldown).
const BITE_RANGE_M: float = 0.6
## Thrust stops inside this distance of a bite target.
const STOP_RANGE_M: float = 0.32
const CRUISE_TICKS: int = 150

enum Step { SWALLOW, PUFFER, KILL, HOLD, EAT, CRUISE, DONE }

var _world: SimWorld
var _id: int = 0
var _step: Step = Step.SWALLOW
var _plankton: int = -1
var _puffer: int = -1
var _victim: int = -1
var _trail: Array[int] = []
var _bits: Array[int] = []
var _puffer_bites: int = 0
var _hold_left: int = HOLD_TICKS
var _cruise_left: int = CRUISE_TICKS
var _event_tick: int = 0
var _fwd: Vector3 = Vector3.FORWARD


func _init(world: SimWorld, player_id: int) -> void:
	_world = world
	_id = player_id
	world.brains_enabled = false
	var p: SimEntity = world.get_entity(player_id)
	p.xp = START_XP
	_fwd = Vector3(p.heading.x, 0.0, p.heading.z).normalized()
	var right: Vector3 = _fwd.cross(Vector3.UP)
	var o: Vector3 = p.position
	_plankton = NpcSpawner.spawn_npc(world, &"plankton", o + _fwd * 0.8, PLANKTON_LEN_M)
	_puffer = NpcSpawner.spawn_npc(world, &"puffer", o + _fwd * 2.4 + right * 0.15, PUFFER_LEN_M, -_fwd)
	_victim = NpcSpawner.spawn_npc(world, &"small_reef_fish", o + _fwd * 4.6 - right * 0.15, VICTIM_LEN_M, right)
	for i in TRAIL_COUNT:
		_trail.append(NpcSpawner.spawn_npc(world, &"plankton", o + _fwd * (6.0 + 0.45 * float(i)) + right * (0.12 * sin(float(i))), PLANKTON_LEN_M))
	# scenery a bit off the path (brains off: they swim in place)
	NpcSpawner.spawn_npc(world, &"grouper", o + _fwd * 12.0 + right * 4.0 + Vector3.UP * 0.5, 1.4, -right)
	NpcSpawner.spawn_npc(world, &"barracuda", o + _fwd * 16.0 - right * 5.0 + Vector3.UP * 1.5, 1.1, right)
	for i in 6:
		NpcSpawner.spawn_npc(world, &"silver_schooling_fish", o + _fwd * (7.0 + 0.5 * float(i)) - right * (2.0 + 0.3 * float(i % 3)) + Vector3.UP * (0.6 + 0.2 * float(i % 2)), 0.12, _fwd)
	_event_tick = world.tick


## Commands for the current tick; call exactly once per tick before SimWorld.step().
func next_commands() -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	_read_events()
	var p: SimEntity = _world.get_entity(_id)
	if p == null or not p.alive:
		return out
	if not p.pending_offer.is_empty():
		out.append(SimCommand.pick_mutation(_id, StringName(p.pending_offer[0]), _world.tick))
		_log("auto_pick_" + p.pending_offer[0])
		return out
	match _step:
		Step.SWALLOW:
			if _world.get_entity(_plankton) == null:
				_advance(Step.PUFFER)
			else:
				_approach(out, p, _plankton, false)
		Step.PUFFER:
			if _puffer_bites >= PUFFER_BITES or _world.get_entity(_puffer) == null:
				_advance(Step.KILL)
			else:
				_approach(out, p, _puffer, true)
		Step.KILL:
			if _world.get_entity(_victim) == null:
				_advance(Step.HOLD)
			else:
				_approach(out, p, _victim, true)
		Step.HOLD:
			out.append(SimCommand.move(_id, _fwd, 0.0, _world.tick))
			out.append(SimCommand.brake(_id, true, _world.tick))
			_hold_left -= 1
			if _hold_left <= 0:
				out.append(SimCommand.brake(_id, false, _world.tick))
				_advance(Step.EAT)
		Step.EAT:
			var target: int = _next_food(p)
			if target < 0:
				_advance(Step.CRUISE)
			else:
				_approach(out, p, target, false)
		Step.CRUISE:
			out.append(SimCommand.move(_id, _fwd, 0.35, _world.tick))
			_cruise_left -= 1
			if _cruise_left <= 0:
				out.append(SimCommand.move(_id, _fwd, 0.0, _world.tick))
				_advance(Step.DONE)
	return out


func is_finished() -> bool:
	return _step == Step.DONE


func _approach(out: Array[SimCommand], p: SimEntity, target_id: int, bite: bool) -> void:
	var t: SimEntity = _world.get_entity(target_id)
	if t == null:
		return
	var to: Vector3 = t.position - p.position
	var d: float = to.length()
	if d < 1e-4:
		return
	# slow down near the target so the mouth cone lines up instead of overshooting
	var thrust: float = clampf(d * 0.9, 0.12 if bite else 0.25, 0.6)
	if bite and d < STOP_RANGE_M:
		thrust = 0.0  # glide and turn in place: do not swim into the target
	out.append(SimCommand.move(_id, to / d, thrust, _world.tick))
	if bite and d <= BITE_RANGE_M:
		out.append(SimCommand.bite(_id, target_id, _world.tick))


# Nearest remaining remains bit, then the plankton trail in order.
func _next_food(p: SimEntity) -> int:
	var best: int = -1
	var best_d2: float = INF
	for id: int in _bits:
		var b: SimEntity = _world.get_entity(id)
		if b != null:
			var d2: float = b.position.distance_squared_to(p.position)
			if d2 < best_d2:
				best_d2 = d2
				best = id
	if best >= 0:
		return best
	for id: int in _trail:
		if _world.get_entity(id) != null:
			return id
	return -1


func _read_events() -> void:
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.BITTEN:
				if ev.entity_id == _puffer and ev.other_id == _id:
					_puffer_bites += 1
					_log("bite_puffer")
				elif ev.entity_id == _victim and ev.other_id == _id:
					_log("bite_victim")
			SimEvent.Type.EATEN:
				if ev.other_id == _id:
					_log("swallow")
			SimEvent.Type.DIED:
				if ev.entity_id == _victim:
					_log("kill")
			SimEvent.Type.FOOD_SPAWNED:
				if ev.other_id == _victim:
					_bits.append(ev.entity_id)
			SimEvent.Type.BAND_UP:
				if ev.entity_id == _id:
					_log("band_up")
	_event_tick = _world.tick


func _advance(step: Step) -> void:
	_step = step
	_log("step_" + String(Step.keys()[step]).to_lower())


func _log(what: String) -> void:
	print("DEMO_FX %s tick=%d frame=%d" % [what, _world.tick, Engine.get_process_frames()])
