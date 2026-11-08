extends TestCase
## NpcBrain passive machine: FLEE from creatures >= behaviour.flee_min_length_ratio x own length inside
## flee_radius_m (own species ignored), keep fleeing until clear of flee_radius_m x flee_release_mult, else WANDER.
## Plankton (behaviour.flees = false) never flees.

const B := preload("res://tests/s3brain_support.gd")


func test_passive_fish_flees_from_a_bigger_creature_and_gets_clear() -> void:
	var w: SimWorld = B.make_world(17)
	var fish: SimEntity = B.npc(w, &"small_reef_fish", B.ARENA, 0.15)
	var flee_r: float = B.species_f(w, &"small_reef_fish", "flee_radius_m")
	var release: float = B.behaviour_f(w, &"small_reef_fish", "flee_release_mult")
	var big: SimEntity = B.npc(w, &"grouper", B.ARENA + Vector3(3.0, 0.0, 0.0), 1.5, Vector3.FORWARD)
	var d0: float = fish.position.distance_to(big.position)
	assert_true(d0 < flee_r, "geometry: %s m inside the flee radius %s m" % [d0, flee_r])
	var took: int = B.step_until(w, func() -> bool: return fish.brain_state == NpcBrain.State.FLEE, 6)
	assert_true(took >= 0, "FLEE within one think interval")
	B.step_n(w, 60)
	var d60: float = fish.position.distance_to(big.position)
	assert_true(d60 > d0 + 1.0, "1+ m farther after 2 s (%s -> %s)" % [d0, d60])
	B.step_n(w, 120)
	var d180: float = fish.position.distance_to(big.position)
	assert_true(d180 > flee_r, "clear of the flee radius after 6 s (%s m > %s m; release at %s m)" % [d180, flee_r, flee_r * release])


func test_passive_fish_ignores_smaller_and_own_species() -> void:
	var w: SimWorld = B.make_world(17)
	var fish: SimEntity = B.npc(w, &"small_reef_fish", B.ARENA, 0.15)
	B.npc(w, &"silver_schooling_fish", B.ARENA + Vector3(1.0, 0.0, 0.0), 0.12)
	B.npc(w, &"small_reef_fish", B.ARENA + Vector3(-1.5, 0.0, 0.0), 0.3)
	for i in 45:
		B.step_n(w, 1)
		assert_eq(fish.brain_state, NpcBrain.State.WANDER, "no flee from a smaller fish or a bigger one of its own species (tick %d)" % i)


func test_passive_fish_flees_from_a_bigger_player_of_its_own_species() -> void:
	var w: SimWorld = B.make_world(17)
	var fish: SimEntity = B.npc(w, &"small_reef_fish", B.ARENA, 0.1)
	B.player(w, B.ARENA + Vector3(1.0, 0.0, 0.0), Vector3.RIGHT, 0.25)
	var took: int = B.step_until(w, func() -> bool: return fish.brain_state == NpcBrain.State.FLEE, 6)
	assert_true(took >= 0, "the player counts as a threat even though it is the same species")


func test_plankton_never_flees() -> void:
	var w: SimWorld = B.make_world(17)
	assert_false(bool((w.content.get_species(&"plankton")["behaviour"] as Dictionary)["flees"]), "data: plankton behaviour.flees = false")
	var swarm: SimEntity = B.npc(w, &"plankton", B.ARENA, 0.015)
	B.npc(w, &"grouper", B.ARENA + Vector3(0.3, 0.0, 0.0), 1.5, Vector3.FORWARD)
	for i in 60:
		B.step_n(w, 1)
		assert_eq(swarm.brain_state, NpcBrain.State.WANDER, "plankton drifts, never flees (tick %d)" % i)
	assert_true(swarm.speed <= B.species_f(w, &"plankton", "swim_speed_mps") + 1e-3, "and drifts at most at its species speed (%s m/s)" % swarm.speed)
