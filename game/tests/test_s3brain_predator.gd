extends TestCase
## NpcBrain predator machine: WANDER -> CHASE on detection (<= predator_hunt_ratio of its length, inside
## detection_radius_m, not own species, not ambient tier), BITE in the mouth cone, CHASE -> WANDER after
## rules.predator_give_up_s without closing in, and back to WANDER when the target dies.

const B := preload("res://tests/s3brain_support.gd")


func _chasing(a: SimEntity, target_id: int) -> bool:
	return a.brain_state == NpcBrain.State.CHASE and a.aggro_target == target_id


func test_predator_detects_and_chases_a_small_player_in_its_radius() -> void:
	var w: SimWorld = B.make_world(3)
	var p: SimEntity = B.player(w, B.ARENA + Vector3(10.0, 0.0, 0.0))
	B.tough(p)
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.LEFT)
	var d0: float = a.position.distance_to(p.position)
	var took: int = B.step_until(w, func() -> bool: return _chasing(a, p.id), 10)
	assert_true(took >= 0, "CHASE with the player as aggro target within 10 ticks (state %d, target %d)" % [a.brain_state, a.aggro_target])
	B.step_n(w, 90)
	assert_true(a.position.distance_to(p.position) < d0 - 3.0, "closes in: %s -> %s m" % [d0, a.position.distance_to(p.position)])


func test_predator_bites_the_target_once_in_reach() -> void:
	var w: SimWorld = B.make_world(3)
	var p: SimEntity = B.player(w, B.ARENA + Vector3(10.0, 0.0, 0.0))
	B.tough(p)
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.LEFT)
	B.step_n(w, 300)
	assert_true(B.bites(w, a.id, p.id) >= 1, "the barracuda bites the player within 10 s")


func test_predator_returns_to_wander_when_its_target_dies() -> void:
	var w: SimWorld = B.make_world(3)
	var p: SimEntity = B.player(w, B.ARENA + Vector3(10.0, 0.0, 0.0))
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.LEFT)
	var died: int = B.step_until(w, func() -> bool: return not p.alive, 300)
	assert_true(died >= 0, "precondition: the B1 player dies to the barracuda within 10 s")
	B.step_n(w, 3)
	assert_eq(a.aggro_target, -1, "target dropped while the player waits for respawn")
	assert_eq(a.brain_state, NpcBrain.State.WANDER, "back to WANDER")


func test_predator_ignores_targets_outside_its_detection_radius() -> void:
	var w: SimWorld = B.make_world(3)
	var r: float = B.species_f(w, &"barracuda", "detection_radius_m")
	var p: SimEntity = B.player(w, B.ARENA + Vector3(r + 3.0, 0.0, 0.0))
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.LEFT)
	for i in 30:
		B.step_n(w, 1)
		assert_ne(a.brain_state, NpcBrain.State.CHASE, "no chase at %s m (radius %s), tick %d" % [r + 3.0, r, i])
	assert_eq(a.aggro_target, -1, "no aggro target")


func test_predator_ignores_too_big_own_species_and_ambient_targets() -> void:
	var w: SimWorld = B.make_world(3)
	var ratio: float = B.rule_f(w, "predator_hunt_ratio")
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.RIGHT)
	var big: SimEntity = B.npc(w, &"grouper", B.ARENA + Vector3(5.0, 0.0, 0.0), ratio * 1.05)
	var kin: SimEntity = B.npc(w, &"barracuda", B.ARENA + Vector3(-5.0, 0.0, 0.0), 0.5)
	var swarm: SimEntity = B.npc(w, &"plankton", B.ARENA + Vector3(0.0, 0.0, 5.0), 0.015)
	for i in 30:
		B.step_n(w, 1)
		assert_ne(a.brain_state, NpcBrain.State.CHASE, "no chase (target %d) at tick %d" % [a.aggro_target, i])
	assert_true(big.alive and kin.alive, "the grouper (%s m) and the 0.5 m barracuda are left alone" % big.length_m)
	assert_true(swarm.id > 0, "plankton existed in range")


func test_predator_hunts_an_npc_just_under_the_ratio() -> void:
	var w: SimWorld = B.make_world(3)
	var ratio: float = B.rule_f(w, "predator_hunt_ratio")
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.RIGHT)
	var prey: SimEntity = B.npc(w, &"grouper", B.ARENA + Vector3(5.0, 0.0, 0.0), ratio * 0.95)
	var took: int = B.step_until(w, func() -> bool: return _chasing(a, prey.id), 10)
	assert_true(took >= 0, "a %s m grouper (< %s of 1.0 m) is hunted" % [prey.length_m, ratio])


func test_predator_gives_up_without_progress_after_the_give_up_time() -> void:
	# A slow barracuda (species speed overridden) cannot close in on a player swimming away at full boost.
	var w: SimWorld = B.make_world(3, {"species": {"barracuda": {"swim_speed_mps": 0.5}}})
	var give_up: int = B.ticks(B.rule_f(w, "predator_give_up_s"))
	assert_true(give_up > 0, "rules.predator_give_up_s is set")
	# start 18 m inside the detection radius (12 m at radius 30): the player is out of range once the chase drops
	var start_m: float = B.species_f(w, &"barracuda", "detection_radius_m") - 18.0
	var p: SimEntity = B.player(w, B.ARENA + Vector3(start_m, 0.0, 0.0))
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA, 1.0, Vector3.RIGHT)
	var move: Dictionary = {p.id: [Vector3.RIGHT, true]}
	var t_acq: int = B.step_until(w, func() -> bool: return _chasing(a, p.id), 10, move)
	assert_true(t_acq >= 0, "precondition: the chase starts")
	var t_drop: int = B.step_until(w, func() -> bool: return a.brain_state != NpcBrain.State.CHASE, give_up + 30, move)
	assert_true(t_drop >= 0, "gives up within give_up_s + 1 s (%d ticks)" % give_up)
	assert_true(t_drop >= give_up - 5, "but not before give_up_s (dropped after %d of %d ticks)" % [t_drop, give_up])
	assert_eq(a.aggro_target, -1, "aggro cleared")
	B.step_n(w, 30, move)
	assert_ne(a.brain_state, NpcBrain.State.CHASE, "the player is out of range by now: no new chase")
