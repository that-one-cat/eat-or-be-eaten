extends TestCase
## S3 NPC brains: temperament state machines observed through the sim (events, hp, aggro fields, positions).
## predator: hunts creatures <= predator_hunt_ratio (60%) of its length inside detection_radius_m;
## retaliate: ignores you until bitten, then fights the attacker for retaliate_duration_s (10 s), then calms;
## passive: never attacks, flees from bigger creatures within flee_radius_m;
## puffer: retaliate + inflates x1.8 for 5 s when bitten (that bite does not spike); while inflated every bite
## spikes the biter for 10% of the biter's max HP.
## Brains run for real here (no pins on the creature under test). The player is stationary and, where noted,
## kept alive (hp refilled after each step) so a lethal predator does not end the observation window.
## Windows are generous (a brain may wander before it notices) and geometry is far from any obstacle (S3.ARENA).
## Not covered at unit level: "predator gives up after predator_give_up_s without progress" (needs a reachable
## but unreachable target; observed indirectly by the bot run and the temperaments scenario).

const S3 := preload("res://tests/s3_support.gd")


func _player(w: SimWorld, length_m: float, pos: Vector3) -> SimEntity:
	return S3.player_at(w, pos, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


# ======================================================== predator

func test_predator_attacks_a_small_player_unprovoked_inside_its_detection_radius() -> void:
	# [species, predator length, player length, distance, window ticks]
	var cases: Array = [
		[&"barracuda", 1.0, 0.5, 12.0, 300],
		[&"shark", 3.0, 1.5, 25.0, 600],
	]
	for c in cases:
		var w: SimWorld = S3.make_world(5)
		var radius: float = S3.species_f(w.content, c[0], "detection_radius_m")
		assert_true(float(c[3]) < radius, "%s: geometry check, %s m is inside the %s m detection radius" % [c[0], c[3], radius])
		var p: SimEntity = _player(w, float(c[2]), S3.ARENA + Vector3(float(c[3]), 0.0, 0.0))
		var a: SimEntity = S3.npc_at(w, c[0], S3.ARENA, float(c[1]), Vector3.LEFT)  # facing away from the player
		var evs: Array[SimEvent] = S3.step_n(w, int(c[4]), {}, [p.id])
		assert_true(S3.pair_events(evs, SimEvent.Type.BITTEN, a.id, p.id).size() >= 1, "%s attacks the %s m player %s m away within %d ticks" % [c[0], c[2], c[3], c[4]])


func test_predator_does_not_notice_a_player_far_outside_its_detection_radius() -> void:
	var w: SimWorld = S3.make_world(5)
	var radius: float = S3.species_f(w.content, &"barracuda", "detection_radius_m")
	var dist: float = 4.0 * radius
	var p: SimEntity = _player(w, 0.5, S3.ARENA + Vector3(dist, 0.0, 0.0))
	var a: SimEntity = S3.npc_at(w, &"barracuda", S3.ARENA, 1.0, Vector3.RIGHT)  # even facing the player
	var t0: int = w.tick
	var closest: float = INF
	for i in 90:
		S3.step_n(w, 1, {}, [p.id])
		closest = minf(closest, a.position.distance_to(p.position))
	assert_eq(S3.count_between(w, SimEvent.Type.BITTEN, a.id, p.id, t0), 0, "no attack from %s m (radius %s)" % [dist, radius])
	assert_true(closest > radius, "the barracuda never closed to within its detection radius in 3 s (closest %s m, radius %s)" % [closest, radius])


func test_predator_hunts_up_to_sixty_percent_of_its_length_and_ignores_bigger_targets() -> void:
	var ratio: float = S3.rule_f(S3.content(), "predator_hunt_ratio")
	assert_almost_eq(ratio, 0.6, 1e-9, "GAME_DESIGN: 60%")
	for factor in [0.97, 1.03, 1.5]:
		var w: SimWorld = S3.make_world(5)
		var pred_len: float = 1.0
		var player_len: float = pred_len * ratio * float(factor)
		var p: SimEntity = _player(w, player_len, S3.ARENA + Vector3(8.0, 0.0, 0.0))
		var a: SimEntity = S3.npc_at(w, &"barracuda", S3.ARENA, pred_len, Vector3.LEFT)
		var t0: int = w.tick
		S3.step_n(w, 300, {}, [p.id])
		var bites: int = S3.count_between(w, SimEvent.Type.BITTEN, a.id, p.id, t0)
		if float(factor) < 1.0:
			assert_true(bites >= 1, "a player at %.0f%% of the barracuda's length (%s m) is hunted" % [float(factor) * ratio * 100.0, player_len])
		else:
			assert_eq(bites, 0, "a player at %.0f%% of the barracuda's length (%s m) is ignored" % [float(factor) * ratio * 100.0, player_len])


func test_predator_swallows_prey_under_ten_percent_and_bites_bigger_prey_to_death() -> void:
	# NPCs follow the same eat/bite rules among themselves.
	var w: SimWorld = S3.make_world(5)
	var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", S3.ARENA + Vector3(8.0, 0.0, 0.0), 0.09)
	var a: SimEntity = S3.npc_at(w, &"barracuda", S3.ARENA, 1.0, Vector3.LEFT)
	var evs: Array[SimEvent] = S3.step_n(w, 600)
	assert_true(S3.pair_events(evs, SimEvent.Type.EATEN, a.id, snack.id).size() >= 1, "the barracuda swallows a 0.09 m fish (<= 10%% of 1.0 m)")

	var w2: SimWorld = S3.make_world(6)
	var prey: SimEntity = S3.npc_at(w2, &"small_reef_fish", S3.ARENA + Vector3(8.0, 0.0, 0.0), 0.4)
	var a2: SimEntity = S3.npc_at(w2, &"barracuda", S3.ARENA, 1.0, Vector3.LEFT)
	var evs2: Array[SimEvent] = S3.step_n(w2, 600)
	assert_true(S3.pair_events(evs2, SimEvent.Type.BITTEN, a2.id, prey.id).size() >= 1, "a 0.4 m fish (40%%, not swallowable) is bitten")
	assert_true(S3.is_gone(w2, prey.id), "and dies")
	var died: Array[SimEvent] = S3.of_type(evs2, SimEvent.Type.DIED)
	assert_true(died.size() >= 1, "DIED event for the prey")
	if died.size() >= 1:
		assert_eq(String(died[0].data.get("species", "")), "small_reef_fish", "DIED data names the species")


# ======================================================== retaliate

func test_retaliators_ignore_the_player_until_bitten_then_fight_for_ten_seconds_then_calm_down() -> void:
	for c in [[&"grouper", 1.5], [&"puffer", 1.2]]:
		var w: SimWorld = S3.make_world(13)
		var p: SimEntity = _player(w, 1.2, S3.ARENA)
		var r: SimEntity = S3.npc_at(w, c[0], p.position + p.heading * (0.6 * S3.reach_m(w, p)), float(c[1]), -p.heading)
		var pins: Dictionary = {r.id: r.position}
		var calm_evs: Array[SimEvent] = S3.step_n(w, 150, pins, [p.id])
		assert_eq(S3.of_type(calm_evs, SimEvent.Type.BITTEN).size(), 0, "%s: leaves the player alone for 5 s" % c[0])
		assert_false(S3.is_aggro(r, w.tick), "%s: not aggressive before the bite" % c[0])

		w.submit(SimCommand.bite(p.id, r.id))
		var tb: int = w.tick
		var bite_evs: Array[SimEvent] = S3.step_n(w, 1, pins, [p.id])
		var dur: int = S3.ticks(S3.rule_f(w.content, "retaliate_duration_s"))
		assert_eq(S3.pair_events(bite_evs, SimEvent.Type.BITTEN, p.id, r.id).size(), 1, "%s: the player's bite landed" % c[0])
		assert_eq(r.aggro_target, p.id, "%s: the attacker becomes the aggro target" % c[0])
		assert_true(r.aggro_until_tick >= tb + dur - 2 and r.aggro_until_tick <= tb + dur + 3, "%s: aggro lasts %d ticks (until %d, bite at %d)" % [c[0], dur, r.aggro_until_tick, tb])
		assert_true(S3.is_aggro(r, w.tick), "%s: is_aggro right after the bite" % c[0])

		# Released: the retaliator moves freely; the player never bites again (collected: the log is trimmed after 300 ticks).
		var fight_evs: Array[SimEvent] = S3.step_n(w, dur + 150, {}, [p.id])
		var bites: Array[SimEvent] = S3.of_type(fight_evs, SimEvent.Type.BITTEN)
		assert_true(bites.size() >= 1, "%s: fights back" % c[0])
		if bites.size() >= 1:
			assert_true(bites[0].tick <= tb + 120, "%s: first counter-bite within 4 s (tick %d, bitten at %d)" % [c[0], bites[0].tick, tb])
			assert_true(bites[bites.size() - 1].tick <= tb + dur + 4, "%s: no bite after the aggro window (last at %d, window ends %d)" % [c[0], bites[bites.size() - 1].tick, tb + dur])
		for ev in bites:
			assert_true(S3.involves(ev, r.id, p.id), "%s: it only ever bites the attacker" % c[0])


func test_retaliate_duration_is_refreshed_by_a_new_bite() -> void:
	var w: SimWorld = S3.make_world(13)
	var p: SimEntity = _player(w, 1.2, S3.ARENA)
	var r: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (0.6 * S3.reach_m(w, p)), 1.5, -p.heading)
	var pins: Dictionary = {r.id: r.position}
	var dur: int = S3.ticks(S3.rule_f(w.content, "retaliate_duration_s"))
	w.submit(SimCommand.bite(p.id, r.id))
	S3.step_n(w, 1, pins, [p.id])
	var first_until: int = r.aggro_until_tick
	S3.step_n(w, 120, pins, [p.id])
	var tb2: int = w.tick
	w.submit(SimCommand.bite(p.id, r.id))
	S3.step_n(w, 1, pins, [p.id])
	assert_true(r.aggro_until_tick > first_until, "a later bite pushes the aggro deadline out (%d -> %d)" % [first_until, r.aggro_until_tick])
	assert_true(r.aggro_until_tick >= tb2 + dur - 2, "to a full duration from the new bite (until %d, bite at %d, duration %d)" % [r.aggro_until_tick, tb2, dur])


# ======================================================== passive

func test_passive_fish_flees_from_a_bigger_creature_inside_its_flee_radius() -> void:
	var w: SimWorld = S3.make_world(17)
	var fish: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA, 0.15, Vector3.RIGHT)
	var flee_r: float = S3.species_f(w.content, &"small_reef_fish", "flee_radius_m")
	var p: SimEntity = _player(w, 0.5, S3.ARENA + Vector3(3.0, 0.0, 0.0))
	assert_true(3.0 < flee_r, "geometry check: 3 m is inside the %s m flee radius" % flee_r)
	var d0: float = fish.position.distance_to(p.position)
	S3.step_n(w, 60, {}, [p.id])
	var d60: float = fish.position.distance_to(p.position)
	S3.step_n(w, 60, {}, [p.id])
	var d120: float = fish.position.distance_to(p.position)
	assert_true(d60 > d0 + 1.0, "after 2 s the fish is more than 1 m farther away (%s -> %s)" % [d0, d60])
	assert_true(d120 >= d0 + 2.0, "after 4 s at least 2 m farther (%s -> %s)" % [d0, d120])
	assert_eq(S3.events_of(w, SimEvent.Type.BITTEN).size(), 0, "a fleeing passive fish never bites")


func test_passive_creatures_never_attack_even_when_bigger_than_the_player() -> void:
	var w: SimWorld = S3.make_world(19)
	var p: SimEntity = _player(w, 0.15, S3.ARENA)
	var big: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(1.0, 0.0, 0.0), 0.6, Vector3.LEFT)
	var t0: int = w.tick
	S3.step_n(w, 300, {}, [p.id])
	assert_eq(S3.count_between(w, SimEvent.Type.BITTEN, big.id, p.id, t0), 0, "a 0.6 m passive fish does not bite a 0.15 m player")
	assert_eq(S3.count_between(w, SimEvent.Type.EATEN, big.id, p.id, t0), 0, "and cannot swallow it (25%% of its length)")


# ======================================================== puffer

func _puffer_scene(player_len: float, world_seed: int = 21) -> Dictionary:
	var w: SimWorld = S3.make_world(world_seed)
	var p: SimEntity = _player(w, player_len, S3.ARENA)
	p.hunger = S3.NPC_HUNGER_FRAC * 100.0  # no regeneration: hp deltas are exact
	var pf: SimEntity = S3.npc_at(w, &"puffer", p.position + p.heading * (0.5 * S3.reach_m(w, p)), p.length_m * 4.0, -p.heading)
	return {"w": w, "p": p, "pf": pf}


func _inflate_data(w: SimWorld) -> Dictionary:
	return w.content.get_species(&"puffer")["inflate"]


func test_a_bitten_puffer_inflates_for_five_seconds() -> void:
	var sc: Dictionary = _puffer_scene(0.5)
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["p"]
	var pf: SimEntity = sc["pf"]
	var dur: int = S3.ticks(float(_inflate_data(w)["duration_s"]))
	assert_true(pf.inflated_until_tick <= w.tick, "not inflated before being bitten")
	w.submit(SimCommand.bite(p.id, pf.id))
	var tb: int = w.tick
	S3.step_n(w, 1, {pf.id: pf.position}, [], [pf.id])
	var infl: Array[SimEvent] = S3.events_of(w, SimEvent.Type.INFLATED, tb)
	assert_eq(infl.size(), 1, "one INFLATED event")
	assert_eq(S3.events_of(w, SimEvent.Type.SPIKED, tb).size(), 0, "Director: the bite that inflates a calm puffer does not spike")
	if infl.size() == 1:
		assert_true(S3.mentions(infl[0], pf.id), "INFLATED names the puffer")
	assert_true(pf.inflated_until_tick >= tb + dur - 2 and pf.inflated_until_tick <= tb + dur + 3, "inflated for %d ticks: until %d, bite at %d" % [dur, pf.inflated_until_tick, tb])


func test_an_inflated_puffer_spikes_the_biter_for_ten_percent_of_the_biters_max_hp() -> void:
	for length_m in [0.15, 0.5, 1.2, 3.0]:
		var sc: Dictionary = _puffer_scene(float(length_m))
		var w: SimWorld = sc["w"]
		var p: SimEntity = sc["p"]
		var pf: SimEntity = sc["pf"]
		var frac: float = float(_inflate_data(w)["spike_damage_frac_of_biter_max_hp"])
		assert_almost_eq(frac, 0.10, 1e-9, "GAME_DESIGN: 10%")
		pf.inflated_until_tick = w.tick + 300  # already inflated: the bite below is a bite WHILE inflated
		var hp0: float = p.hp
		w.submit(SimCommand.bite(p.id, pf.id))
		var tb: int = w.tick
		S3.step_n(w, 1, {pf.id: pf.position}, [], [pf.id])
		var spikes: Array[SimEvent] = S3.events_of(w, SimEvent.Type.SPIKED, tb)
		var expected: float = frac * p.max_hp
		assert_eq(spikes.size(), 1, "%s m biter: one SPIKED event" % length_m)
		if spikes.size() == 1:
			assert_almost_eq(spikes[0].value, expected, 1e-6, "%s m biter (band %d, max HP %s): spike value" % [length_m, p.band, p.max_hp])
			assert_true(S3.involves(spikes[0], p.id, pf.id), "SPIKED names puffer and biter")
		assert_almost_eq(hp0 - p.hp, expected, 1e-6, "%s m biter loses exactly 10%% of its max HP" % length_m)
		assert_true(pf.hp < pf.max_hp, "and the bite still damages the puffer")


func test_every_bite_while_inflated_spikes_again() -> void:
	var sc: Dictionary = _puffer_scene(0.5)
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["p"]
	var pf: SimEntity = sc["pf"]
	pf.inflated_until_tick = w.tick + 300
	var hp0: float = p.hp
	var gap: int = S3.ticks(S3.rule_f(w.content, "bite_cooldown_s")) + 3
	var t0: int = w.tick
	for i in 2:
		w.submit(SimCommand.bite(p.id, pf.id))
		S3.step_n(w, gap, {pf.id: pf.position}, [], [pf.id])
	assert_eq(S3.events_of(w, SimEvent.Type.BITTEN, t0).size(), 2, "two bites landed")
	assert_eq(S3.events_of(w, SimEvent.Type.SPIKED, t0).size(), 2, "and both were spiked")
	assert_almost_eq(hp0 - p.hp, 2.0 * 0.10 * p.max_hp, 1e-6, "the biter lost 2 x 10%% of its max HP")


func test_inflation_wears_off_and_a_later_bite_inflates_it_again() -> void:
	var sc: Dictionary = _puffer_scene(0.5)
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["p"]
	var pf: SimEntity = sc["pf"]
	var dur: int = S3.ticks(float(_inflate_data(w)["duration_s"]))
	var pins: Dictionary = {pf.id: pf.position}
	w.submit(SimCommand.bite(p.id, pf.id))
	var t1: int = w.tick
	S3.step_n(w, 1, pins, [p.id], [pf.id])
	var spikes_first: int = S3.events_of(w, SimEvent.Type.SPIKED, t1).size()
	assert_eq(spikes_first, 0, "Director: the inflating bite on a calm puffer does not spike")
	S3.step_n(w, dur + 10, pins, [p.id], [pf.id])
	assert_true(w.tick >= pf.inflated_until_tick, "5 s later the inflation is over (tick %d, until %d)" % [w.tick, pf.inflated_until_tick])
	w.submit(SimCommand.bite(p.id, pf.id))
	var t2: int = w.tick
	S3.step_n(w, 1, pins, [p.id], [pf.id])
	assert_eq(S3.events_of(w, SimEvent.Type.INFLATED, t2).size(), 1, "the second bite inflates it again")
	assert_eq(S3.events_of(w, SimEvent.Type.SPIKED, t2).size(), spikes_first, "and behaves like the first bite on a calm puffer (same number of spikes: %d)" % spikes_first)
	assert_true(pf.inflated_until_tick >= t2 + dur - 2, "a fresh 5 s inflation")


func test_an_inflated_puffer_counts_as_x1_8_bigger_for_the_swallow_rule() -> void:
	# GAME_DESIGN: the puffer inflates x1.8 in size. A 3.2 m fish swallows a 0.30 m puffer (limit 0.32 m); the same
	# puffer inflated is 0.54 m for the rule and is left alone.
	for inflated in [false, true]:
		var w: SimWorld = S3.make_world(23)
		var p: SimEntity = _player(w, 3.2, S3.ARENA)
		var pf: SimEntity = S3.npc_at(w, &"puffer", p.position + p.heading * (0.5 * S3.reach_m(w, p)), 0.30, -p.heading)
		assert_true(pf.length_m <= p.length_m * S3.rule_f(w.content, "swallow_ratio"), "precondition: 0.30 m fits the 3.2 m fish's mouth")
		assert_true(pf.length_m * float(_inflate_data(w)["scale"]) > p.length_m * S3.rule_f(w.content, "swallow_ratio"), "precondition: 0.30 m x 1.8 does not")
		if inflated:
			pf.inflated_until_tick = w.tick + 300
		S3.step_n(w, 20, {pf.id: pf.position}, [p.id], [pf.id])
		assert_eq(S3.is_gone(w, pf.id), not inflated, "inflated = %s: the puffer is swallowed only when it is not inflated" % inflated)
