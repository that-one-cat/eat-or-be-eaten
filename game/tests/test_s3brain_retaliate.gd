extends TestCase
## NpcBrain retaliate machine (grouper, puffer): WANDER while unprovoked, RETALIATE against the biter while SimWorld's
## aggro deadline (retaliate_duration_s) runs, back to WANDER when it passes.

const B := preload("res://tests/s3brain_support.gd")


## Player right behind a retaliator that faces away from it; the player can bite it at once.
func _scene(species: StringName, length_m: float) -> Dictionary:
	var w: SimWorld = B.make_world(11)
	var p: SimEntity = B.player(w, B.ARENA, Vector3.RIGHT)
	B.tough(p)
	var r: SimEntity = B.npc(w, species, B.ARENA + Vector3(0.2, 0.0, 0.0), length_m, Vector3.RIGHT)
	return {"w": w, "p": p, "r": r}


func test_retaliators_stay_calm_until_bitten() -> void:
	for c in [[&"grouper", 1.5], [&"puffer", 0.4]]:
		var sc: Dictionary = _scene(c[0], c[1])
		var w: SimWorld = sc["w"]
		var p: SimEntity = sc["p"]
		var r: SimEntity = sc["r"]
		for i in 90:
			B.step_n(w, 1)
			assert_eq(r.brain_state, NpcBrain.State.WANDER, "%s calm at tick %d" % [c[0], i])
		assert_eq(B.bites(w, r.id, p.id), 0, "%s never bit the player unprovoked" % c[0])


func test_a_bite_turns_a_retaliator_on_the_attacker_until_the_duration_ends() -> void:
	for c in [[&"grouper", 1.5], [&"puffer", 0.4]]:
		var sc: Dictionary = _scene(c[0], c[1])
		var w: SimWorld = sc["w"]
		var p: SimEntity = sc["p"]
		var r: SimEntity = sc["r"]
		var dur: int = B.ticks(B.rule_f(w, "retaliate_duration_s"))
		w.submit(SimCommand.bite(p.id, r.id, w.tick))
		var tb: int = w.tick
		B.step_n(w, 1)
		assert_true(B.bites(w, p.id, r.id, tb) == 1, "%s: precondition, the player's bite landed" % c[0])
		var spiked: int = 0
		for ev: SimEvent in w.events_since(tb):
			if ev.type == SimEvent.Type.SPIKED:
				spiked += 1
		assert_eq(spiked, 0, "%s: the first bite (inflating a calm puffer) does not spike the biter" % c[0])
		B.step_n(w, 3)
		assert_eq(r.brain_state, NpcBrain.State.RETALIATE, "%s: RETALIATE right after the bite" % c[0])
		assert_eq(r.aggro_target, p.id, "%s: against the attacker" % c[0])
		# the player flees at full boost (faster than both retaliators); the chase lasts the whole window
		var move: Dictionary = {p.id: [Vector3.LEFT, true]}
		B.step_n(w, dur - 20, move)
		assert_eq(r.brain_state, NpcBrain.State.RETALIATE, "%s: still retaliating near the end of the window" % c[0])
		B.step_n(w, 25, move)
		assert_eq(r.brain_state, NpcBrain.State.WANDER, "%s: calm again after retaliate_duration_s" % c[0])
		assert_eq(r.aggro_target, -1, "%s: aggro cleared" % c[0])
