class_name S6Demo
extends Node
## Capture-only S6 fixture (user arg `-- --s6-demo=<shot>`, reef.tscn / reef_greybox.tscn; NEVER active in normal
## play, ignored in release builds). Sets up one situation for a review screenshot through SimDebug / Progression.grant and direct fixture writes
## (like DemoFx), then acts only through SimCommands. Mutation offers caused by the setup are auto-picked (first node)
## except in the `pick` shot. The mouse is left free and PlayerInput ignores mouse look (no stray input in captures).
## Prints `S6_DEMO <what> frame=<process frame> tick=<t>` lines to time captures.
## Shots:
##   hud       shallows at spawn, B2 with Bite-Dash granted, a Bite-Dash at SETUP_FRAME + 120 (cooldown sweep), partial
##             stamina / hunger / health, a running timer and one death on the counter;
##   pick      B1 at spawn, force_band_up at SETUP_FRAME + 40 -> the pick overlay (2 cards with the shipped tree);
##   sonar     B2, Sonar granted, smaller / similar / bigger creatures around (brains off), a pulse at SETUP_FRAME + 120;
##   presence  B2, creatures >= 50% of the player's length beside / above / behind the player out of view (brains off);
##   boss      B4 (full growth), teleported 17 m in front of the giant shark in the abyss: engage, HP bar, telegraph.

const ARG: String = "--s6-demo="
const SHOTS: PackedStringArray = ["hud", "pick", "sonar", "presence", "boss"]
const SETUP_FRAME: int = 3
const B2_XP: float = 200.0
const B4_XP: float = 1200.0
const BOSS_DIST_M: float = 17.0

var _world: SimWorld
var _id: int = 0
var _shot: String = ""
var _input: PlayerInput
var _frame: int = 0
var _event_tick: int = 0
var _picked_for: PackedStringArray = PackedStringArray()
var _boss_placed: bool = false


## The shot named by `--s6-demo=<shot>`, "" when absent or unknown.
static func requested_shot() -> String:
	if not OS.is_debug_build():
		return ""  # SimDebug / Progression.grant fixtures are never reachable from a release export
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(ARG):
			var shot: String = arg.trim_prefix(ARG)
			if SHOTS.has(shot):
				return shot
			push_warning("s6_demo: unknown shot '%s' (expected one of %s)" % [shot, ", ".join(SHOTS)])
	return ""


func _init(loop: GameLoop, player_id: int, shot: String, input: PlayerInput) -> void:
	_world = loop.world
	_id = player_id
	_shot = shot
	_input = input
	_event_tick = _world.tick
	loop.ticked.connect(_on_ticked)


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_input.set_process_unhandled_input(false)


func _process(_delta: float) -> void:
	_frame += 1
	var p: SimEntity = _world.get_entity(_id)
	if p == null:
		return
	if _shot != "pick" and not p.pending_offer.is_empty() and not _picked_for.has(",".join(p.pending_offer)):
		_picked_for.append(",".join(p.pending_offer))
		_world.submit(SimCommand.pick_mutation(_id, StringName(p.pending_offer[0])))
		_log("auto_pick_" + p.pending_offer[0])
	if _frame == SETUP_FRAME:
		_setup(p)
	elif _frame == SETUP_FRAME + 10:
		# after the growth phase derived the new length
		if _shot == "sonar":
			_spawn_ring(p, [[&"small_reef_fish", 0.35, 6.0, 10.0, 0.0], [&"small_reef_fish", 0.4, 9.0, -25.0, 1.0],
				[&"grouper", 1.0, 11.0, 20.0, -0.5], [&"barracuda", 1.05, 16.0, -12.0, 1.5],
				[&"grouper", 2.4, 20.0, 35.0, 2.0], [&"shark", 3.0, 26.0, -30.0, 3.0], [&"silver_schooling_fish", 0.3, 7.0, -8.0, -0.8]])
		elif _shot == "presence":
			_spawn_ring(p, [[&"grouper", 1.2, 9.0, 95.0, 0.0], [&"barracuda", 1.1, 14.0, -100.0, 1.0],
				[&"grouper", 1.0, 12.0, 60.0, 5.0], [&"shark", 2.0, 20.0, -125.0, -2.0], [&"grouper", 1.0, 10.0, 170.0, 0.0],
				[&"small_reef_fish", 0.2, 6.0, 80.0, 0.0]])
	match _shot:
		"hud":
			if _frame == SETUP_FRAME + 120:
				_world.submit(SimCommand.ability(_id, &"bite_dash"))
				_log("bite_dash")
		"pick":
			if _frame == SETUP_FRAME + 40:
				SimDebug.force_band_up(_world, _id)
				_log("force_band_up")
		"sonar":
			if _frame == SETUP_FRAME + 120:
				_world.submit(SimCommand.ability(_id, &"sonar"))
				_log("sonar")
		"boss":
			if not _boss_placed and _frame > SETUP_FRAME + 170 and _world.boss_id() >= 0 and p.band >= 4 and p.pending_offer.is_empty():
				_place_near_boss(p)


func _setup(p: SimEntity) -> void:
	match _shot:
		"hud":
			SimDebug.set_xp(_world, _id, 165.0)
			Progression.grant(_world, p, "hunter_bite_power")
			Progression.grant(_world, p, "hunter_bite_dash")
			p.stamina = 55.0
			p.hunger = 64.0
			p.deaths = 1
			_world.run_ticks = 30 * 97
		"sonar":
			SimDebug.set_xp(_world, _id, B2_XP)
			Progression.grant(_world, p, "survivor_efficient_metabolism")
			Progression.grant(_world, p, "survivor_sonar")
			_world.brains_enabled = false
		"presence":
			SimDebug.set_xp(_world, _id, B2_XP)
			_world.brains_enabled = false
		"boss":
			SimDebug.set_xp(_world, _id, B4_XP)
	_log("setup_" + _shot)


# Spawns [species, length x player length, distance m, yaw degrees left of the player's facing, height m] around p.
func _spawn_ring(p: SimEntity, list: Array) -> void:
	var len: float = p.length_m
	var fwd := Vector3(p.heading.x, 0.0, p.heading.z).normalized()
	for item: Array in list:
		var dir: Vector3 = fwd.rotated(Vector3.UP, deg_to_rad(float(item[3])))
		var pos: Vector3 = p.position + dir * float(item[2]) + Vector3.UP * float(item[4])
		NpcSpawner.spawn_npc(_world, item[0], pos, len * float(item[1]), fwd.rotated(Vector3.UP, deg_to_rad(float(item[3]) + 90.0)))


func _place_near_boss(p: SimEntity) -> void:
	var boss: SimEntity = _world.get_entity(_world.boss_id())
	_boss_placed = true
	var face := Vector3(boss.heading.x, 0.0, boss.heading.z).normalized()
	if face.is_zero_approx():
		face = Vector3.FORWARD
	var pos: Vector3 = boss.position + face * BOSS_DIST_M + Vector3.UP * 2.0
	p.position = pos
	p.velocity = Vector3.ZERO
	var to_boss: Vector3 = (boss.position - pos).normalized()
	p.heading = to_boss
	_input.aim_yaw = atan2(-to_boss.x, -to_boss.z)
	_input.aim_pitch = asin(clampf(to_boss.y, -1.0, 1.0))
	_log("boss_placed dist=%.1f" % pos.distance_to(boss.position))


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.MUTATION_OFFERED:
				if ev.entity_id == _id:
					_log("offer " + ",".join(ev.data.get("offer", PackedStringArray())))
			SimEvent.Type.BOSS_ENGAGED:
				_log("boss_engaged")
			SimEvent.Type.BOSS_TELL:
				_log("boss_tell")
			SimEvent.Type.BOSS_DASH:
				_log("boss_dash")
			SimEvent.Type.SONAR_PULSE:
				_log("sonar_pulse contacts=%d" % (ev.data.get("contacts", []) as Array).size())
	_event_tick = _world.tick


func _log(what: String) -> void:
	print("S6_DEMO %s frame=%d tick=%d" % [what, Engine.get_process_frames(), _world.tick])
