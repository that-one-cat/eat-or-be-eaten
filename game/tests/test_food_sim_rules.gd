extends TestCase
## Food sites in the sim (research 1, 3, 5.1, 7.4/7.5 item 3): soft sites (eggs) are swallowed from the mouth cone at the
## right reach and only by a big enough fish (per-type swallow_ratio override; the global ratio for fish is unchanged);
## hard sites (snails, shells, starfish, clams) are NOT swallowed but killed by bites by the HP formula
## (base_hp * L^2 * hp_mult, damage 25 * L_p^2), heal after regen_s, and respawn exactly at respawn_s; XP =
## xp_gain(xp * xp_band_mult[band], ...), hunger = hunger_from_xp(hunger_xp or xp); only living players touch sites; a
## nearer creature wins over a site in the bite cone and vice versa; the F1 bite buffer / miss cue work with sites;
## events carry the documented payload; state_hash / write_state cover the site state; a world without a food file
## behaves as before.
## Scenes use ONE isolated site (injected in open water when FoodSites.from_records exists, else a real one) and a B-band
## player pinned next to it; every expectation is computed from data in food_support.gd.

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")

const HARD_TYPES: Array[StringName] = [&"starfish", &"cone_shell", &"giant_clam"]
## Player lengths of the bite table (research 3.3: L_p 0.10 / 0.15 / 0.30; 0.6 m is a band-2 fish, 1.2 m reaches band 3).
const BITE_LENGTHS: Array[float] = [0.10, 0.15, 0.30, 0.60, 1.20]


# ======================================================================= soft sites (eggs)

func test_a_soft_site_is_swallowed_from_the_cone_with_xp_hunger_and_events() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH)
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var rec: Dictionary = sc["rec"]
	var id: int = sc["id"]
	var xp0: float = p.xp
	var hunger0: float = p.hunger
	var evs: Array[SimEvent] = F.run(w, 12, {p.id: sc["pos"]})
	var eaten: Array[SimEvent] = F.named_for(evs, F.EV_EATEN, id)
	assert_eq(eaten.size(), 1, "exactly one SITE_EATEN for the egg site")
	if eaten.is_empty():
		return
	var ev: SimEvent = eaten[0]
	assert_eq(ev.entity_id, p.id, "entity = the eater")
	assert_true(bool(ev.data.get("soft", false)), "data.soft is true for an egg")
	assert_eq(str(ev.data.get("type")), str(F.T_EGG_PEACH), "data.type")
	assert_true((ev.data.get("pos") as Vector3).distance_to(sc["site"]["pos"]) < 0.5, "data.pos is the site position")
	assert_almost_eq(ev.value, F.expect_xp(w.content, p, rec), 1e-6, "value = XP = xp_gain(xp * band mult, L_p, length_m, xp_falloff)")
	assert_almost_eq(p.xp - xp0, ev.value, 1e-6, "the player's XP grew by exactly the event value")
	assert_almost_eq(p.hunger - hunger0, minf(F.expect_hunger(w.content, rec), S3.rule_f(w.content, "hunger_max") - hunger0), 1e-6, "hunger grew by hunger_from_xp(hunger_xp)")
	assert_false(F.site_alive(w, id), "the site is gone (waiting for its respawn)")
	assert_eq(F.named(evs, "EATEN").size(), 0, "no creature EATEN event: sites are not entities")
	assert_eq(F.named(evs, F.EV_BITTEN).size(), 0, "a swallowed egg is not bitten")


func test_a_soft_site_outside_the_reach_or_the_cone_is_left_alone() -> void:
	var far: Dictionary = F.scene(self, F.T_EGG_PEACH, {"frac": 2.5})
	if far.is_empty():
		return
	var evs: Array[SimEvent] = F.run(far["w"], 30, {far["pid"]: far["pos"]})
	assert_eq(F.named(evs, F.EV_EATEN).size(), 0, "2.5x the reach away: not eaten")
	assert_true(F.site_alive(far["w"], far["id"]), "still alive")
	var behind: Dictionary = F.scene(self, F.T_EGG_PEACH, {"away": true})
	if behind.is_empty():
		return
	var evs2: Array[SimEvent] = F.run(behind["w"], 30, {behind["pid"]: behind["pos"]})
	assert_eq(F.named(evs2, F.EV_EATEN).size(), 0, "site behind the head (outside the 45 degree cone): not eaten")


func test_a_too_small_fish_cannot_swallow_a_soft_site_and_the_per_type_ratio_decides() -> void:
	# egg length_m 0.08: ratio 0.5 -> needs a fish >= 0.16 m; ratio 0.1 (the global one) -> needs >= 0.8 m.
	var small: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"length_m": 0.08, "swallow_ratio": 0.5}, "length": 0.10})
	if small.is_empty():
		return
	var evs: Array[SimEvent] = F.run(small["w"], 30, {small["pid"]: small["pos"]})
	assert_eq(F.named(evs, F.EV_EATEN).size(), 0, "0.10 m fish vs a 0.08 m egg at ratio 0.5: too small")
	var big: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"length_m": 0.08, "swallow_ratio": 0.5}, "length": 0.20})
	var evs2: Array[SimEvent] = F.run(big["w"], 12, {big["pid"]: big["pos"]})
	assert_eq(F.named(evs2, F.EV_EATEN).size(), 1, "0.20 m fish vs the same egg at ratio 0.5: swallowed")
	var global_ratio: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"length_m": 0.08, "swallow_ratio": 0.1}, "length": 0.20})
	var evs3: Array[SimEvent] = F.run(global_ratio["w"], 30, {global_ratio["pid"]: global_ratio["pos"]})
	assert_eq(F.named(evs3, F.EV_EATEN).size(), 0, "ratio 0.1: the 0.20 m fish cannot swallow a 0.08 m egg (0.08 > 0.02)")


func test_a_food_override_does_not_change_the_swallow_rule_for_fish() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"swallow_ratio": 0.9}, "length": 1.0})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var big_fish: SimEntity = S3.npc_at(w, &"small_reef_fish", p.position + p.heading * (S3.reach_m(w, p) * 0.5), p.length_m * 0.3, -p.heading)
	var calm: Array[int] = [big_fish.id]
	var evs: Array[SimEvent] = S3.step_n(w, 6, {p.id: sc["pos"], big_fish.id: big_fish.position}, [], calm)
	assert_eq(F.named(evs, "EATEN").size(), 0, "a fish 0.3x the player's length is NOT swallowed (global ratio 0.1), whatever a food type says")


func test_a_soft_site_is_not_killed_by_bites() -> void:
	# SPEC ASSUMPTION (research 1.3: eggs are swallowed, 'no HP use'): a bite on an egg too big to swallow does nothing.
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"length_m": 0.08, "swallow_ratio": 0.5}, "length": 0.10})
	if sc.is_empty():
		return
	var evs: Array[SimEvent] = F.run(sc["w"], 60, {sc["pid"]: sc["pos"]}, [sc["pid"]])
	assert_eq(F.named(evs, F.EV_EATEN).size(), 0, "no kill of a soft site by biting (spec gap if this fails: decide soft + bite)")
	assert_eq(F.named(evs, F.EV_BITTEN).size(), 0, "no SITE_BITTEN on a soft site")
	assert_true(F.named(evs, "BITE_MISSED").size() >= 1, "the held bite finds nothing -> the F1 air-chomp cue")


# ======================================================================= hard sites (bitten)

func test_a_hard_site_is_not_swallowed_even_by_a_fish_that_could_swallow_its_size() -> void:
	for type: StringName in HARD_TYPES:
		var sc: Dictionary = F.scene(self, type, {"length": 1.2})
		if sc.is_empty():
			return
		var evs: Array[SimEvent] = F.run(sc["w"], 30, {sc["pid"]: sc["pos"]})
		assert_eq(F.named(evs, F.EV_EATEN).size(), 0, "%s: not swallowed (length_m <= 0.1 * L_p would allow it for a soft item)" % type)
		assert_true(F.site_alive(sc["w"], sc["id"]), "%s: untouched without a bite" % type)


func test_hard_sites_die_after_exactly_the_computed_number_of_bites() -> void:
	for type: StringName in HARD_TYPES:
		for length: float in BITE_LENGTHS:
			var sc: Dictionary = F.scene(self, type, {"length": length})
			if sc.is_empty():
				return
			var w: SimWorld = sc["w"]
			var p: SimEntity = sc["player"]
			var rec: Dictionary = sc["rec"]
			var id: int = sc["id"]
			var max_hp: float = F.expect_max_hp(rec)
			var dmg: float = F.bite_dmg(w, p)
			var n: int = F.bites_to_kill(max_hp, dmg)
			var tag: String = "%s @ L_p %.2f (max_hp %.3f, dmg %.4f, %d bites)" % [type, length, max_hp, dmg, n]
			assert_almost_eq(F.site_max_hp(w, id), max_hp, 1e-6, "%s: site_max_hp = creature_max_hp(base_hp, length_m) * hp_mult" % tag)
			var cd: int = F.cooldown_ticks(w.content)
			for k in range(1, n):
				var evs: Array[SimEvent] = _one_bite(w, p, sc["pos"], cd)
				var hit: Array[SimEvent] = F.named_for(evs, F.EV_BITTEN, id)
				assert_eq(hit.size(), 1, "%s: bite %d is a SITE_BITTEN" % [tag, k])
				if hit.size() == 1:
					assert_almost_eq(hit[0].value, dmg, 1e-6, "%s: bite %d damage = bite_damage(power, L_p, mult)" % [tag, k])
					assert_almost_eq(float(hit[0].data.get("max_hp", -1.0)), max_hp, 1e-6, "%s: data.max_hp" % tag)
					assert_almost_eq(float(hit[0].data.get("hp", -1.0)), max_hp - dmg * float(k), 1e-6, "%s: data.hp after bite %d" % [tag, k])
				assert_true(F.site_alive(w, id), "%s: alive after bite %d" % [tag, k])
				assert_almost_eq(F.site_hp(w, id), max_hp - dmg * float(k), 1e-6, "%s: site_hp after bite %d" % [tag, k])
			var xp0: float = p.xp
			var last: Array[SimEvent] = _one_bite(w, p, sc["pos"], cd)
			var eaten: Array[SimEvent] = F.named_for(last, F.EV_EATEN, id)
			assert_eq(eaten.size(), 1, "%s: bite %d kills (SITE_EATEN)" % [tag, n])
			assert_false(F.site_alive(w, id), "%s: dead" % tag)
			if eaten.size() == 1:
				assert_false(bool(eaten[0].data.get("soft", true)), "%s: data.soft is false for a kill by bite" % tag)
				assert_almost_eq(eaten[0].value, F.expect_xp(w.content, p, rec), 1e-6, "%s: kill XP" % tag)
				assert_true(p.xp > xp0, "%s: the player was credited at once (no remains bits)" % tag)
			assert_eq(F.named(last, "EATEN").size() + F.named(last, "FOOD_SPAWNED").size(), 0, "%s: no creature EATEN / remains bits for a site" % tag)


## Submits one best-in-cone bite and steps until the cooldown is over; returns the events.
func _one_bite(w: SimWorld, p: SimEntity, pos: Vector3, cd_ticks: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	w.submit(SimCommand.bite(p.id, -1))
	out.append_array(F.run(w, cd_ticks + 1, {p.id: pos}))
	return out


func test_damage_regenerates_after_regen_s_and_not_before() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0, "regen_s": 2.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var id: int = sc["id"]
	var cd: int = F.cooldown_ticks(w.content)
	var evs: Array[SimEvent] = _one_bite(w, p, sc["pos"], cd)
	assert_eq(F.named_for(evs, F.EV_BITTEN, id).size(), 1, "one bite landed")
	var max_hp: float = F.site_max_hp(w, id)
	var bite_tick: int = F.named_for(evs, F.EV_BITTEN, id)[0].tick
	assert_true(F.site_hp(w, id) < max_hp, "damaged right after the bite")
	var regen_ticks: int = S3.ticks(2.0)
	assert_true(F.site_hp(w, id, bite_tick + regen_ticks - 3) < max_hp, "still damaged just before last bite + regen_s")
	assert_almost_eq(F.site_hp(w, id, bite_tick + regen_ticks + 3), max_hp, 1e-9, "full HP just after last bite + regen_s (lazy regen, no per-tick state)")
	F.run(w, regen_ticks + 10, {p.id: sc["pos"]})
	assert_almost_eq(F.site_hp(w, id), max_hp, 1e-9, "after stepping through it the world agrees")


func test_a_second_bite_inside_regen_s_restarts_the_regen_timer() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0, "regen_s": 2.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var id: int = sc["id"]
	var cd: int = F.cooldown_ticks(w.content)
	_one_bite(w, p, sc["pos"], cd)
	var second: Array[SimEvent] = _one_bite(w, p, sc["pos"], cd)
	var t2: int = F.named_for(second, F.EV_BITTEN, id)[0].tick
	var max_hp: float = F.site_max_hp(w, id)
	assert_true(F.site_hp(w, id, t2 + S3.ticks(2.0) - 3) < max_hp, "regen counts from the LAST bite")
	assert_almost_eq(F.site_hp(w, id, t2 + S3.ticks(2.0) + 3), max_hp, 1e-9, "and heals fully after it")


func test_xp_uses_the_band_multiplier_and_the_falloff() -> void:
	var override: Dictionary = {"xp": 10.0, "xp_band_mult": [1.0, 1.0, 0.5, 0.25]}
	for length: float in [0.10, 1.2]:
		var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": override, "length": length})
		if sc.is_empty():
			return
		var w: SimWorld = sc["w"]
		var p: SimEntity = sc["player"]
		var evs: Array[SimEvent] = []
		for i in 40:
			evs.append_array(_one_bite(w, p, sc["pos"], F.cooldown_ticks(w.content)))
			if not F.named_for(evs, F.EV_EATEN, sc["id"]).is_empty():
				break
		var eaten: Array[SimEvent] = F.named_for(evs, F.EV_EATEN, sc["id"])
		assert_eq(eaten.size(), 1, "L_p %.2f: killed" % length)
		if eaten.size() == 1:
			var want: float = SimRules.xp_gain(10.0 * float(override["xp_band_mult"][p.band - 1]), p.length_m, float(sc["rec"]["length_m"]), F.xp_falloff(w.content))
			assert_almost_eq(eaten[0].value, want, 1e-6, "L_p %.2f (band %d): xp * band mult, then the falloff" % [length, p.band])


func test_hunger_uses_hunger_xp_without_the_falloff() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"hunger_xp": 2.0}, "hunger_frac": 0.2})
	if sc.is_empty():
		return
	var p: SimEntity = sc["player"]
	var h0: float = p.hunger
	F.run(sc["w"], 12, {p.id: sc["pos"]})
	assert_almost_eq(p.hunger - h0, 2.0 * S3.rule_f(sc["w"].content, "hunger_per_xp"), 1e-6, "hunger = hunger_xp * hunger_per_xp")


# ======================================================================= respawn

func test_a_site_respawns_exactly_at_respawn_s_and_is_edible_again() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH, {"override": {"respawn_s": 2.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var id: int = sc["id"]
	var evs: Array[SimEvent] = F.run(w, 12, {p.id: sc["pos"]})
	var eaten: Array[SimEvent] = F.named_for(evs, F.EV_EATEN, id)
	if eaten.is_empty():
		fail("setup: the egg was not eaten")
		return
	var t_eaten: int = eaten[0].tick
	var want: int = t_eaten + S3.ticks(2.0)
	assert_false(F.site_alive(w, id, want - 1), "still gone one tick before respawn_s")
	assert_true(F.site_alive(w, id, want), "back at eaten tick + respawn_s")
	var more: Array[SimEvent] = F.run(w, S3.ticks(2.0) + 4, {p.id: sc["pos"] + Vector3.UP * 5.0})
	var back: Array[SimEvent] = F.named_for(more, F.EV_RESPAWNED, id)
	assert_eq(back.size(), 1, "one SITE_RESPAWNED")
	if back.size() == 1:
		assert_true(absi(back[0].tick - want) <= 1, "SITE_RESPAWNED at tick %d, expected %d (+-1)" % [back[0].tick, want])
		assert_eq(back[0].entity_id, -1, "respawn event has no entity")
	assert_almost_eq(F.site_hp(w, id), F.site_max_hp(w, id), 1e-9, "respawned at full HP")
	var again: Array[SimEvent] = F.run(w, 12, {p.id: sc["pos"]})
	assert_eq(F.named_for(again, F.EV_EATEN, id).size(), 1, "eaten a second time after the respawn")


# ======================================================================= who may eat

func test_npcs_never_touch_sites() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	w.get_entity(sc["pid"]).position = S3.ARENA + Vector3(0.0, 15.0, 0.0)   # the player is elsewhere
	var site_pos: Vector3 = sc["site"]["pos"]
	for sp: StringName in [&"small_reef_fish", &"grouper"]:
		var a: Dictionary = F.approach(w, site_pos, 0.15)
		if a.is_empty():
			continue
		var npc: SimEntity = S3.npc_at(w, sp, a["pos"], 0.3, a["heading"])
		var calm: Array[int] = [npc.id]
		var evs: Array[SimEvent] = []
		for i in 60:
			w.submit(SimCommand.bite(npc.id, -1))
			evs.append_array(S3.step_n(w, 1, {npc.id: a["pos"]}, [], calm))
		assert_eq(F.named(evs, F.EV_BITTEN).size() + F.named(evs, F.EV_EATEN).size(), 0, "%s next to the site, biting every tick: no site event (Q5: only the player eats sites)" % sp)
	assert_almost_eq(F.site_hp(w, sc["id"]), F.site_max_hp(w, sc["id"]), 1e-9, "site HP untouched by NPCs")


func test_sites_are_not_entities() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH)
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	assert_eq(w.entity_ids().size(), 1, "the world holds the player only: sites are baked data, not SimEntity (tier caps and sonar untouched)")
	F.run(w, 12, {sc["pid"]: sc["pos"]})
	assert_eq(w.entity_ids().size(), 1, "still one entity after eating a site")
	for id: int in w.entity_ids():
		assert_ne(w.get_entity(id).kind, SimEntity.Kind.FOOD_BIT, "no remains bit")


func test_a_dead_player_eats_nothing() -> void:
	var sc: Dictionary = F.scene(self, F.T_EGG_PEACH)
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	p.hp = 0.0
	F.run(w, 2, {p.id: sc["pos"] + Vector3.UP * 20.0})
	assert_false(p.alive, "setup: the player is dead")
	var evs: Array[SimEvent] = F.run(w, 20, {p.id: sc["pos"]}, [p.id])
	assert_eq(F.named(evs, F.EV_EATEN).size() + F.named(evs, F.EV_BITTEN).size(), 0, "a dead player at the site: nothing eaten, nothing bitten")


# ======================================================================= nearest first, bite buffer, miss cue

func test_the_nearer_of_a_creature_and_a_site_is_bitten() -> void:
	for site_nearer: bool in [true, false]:
		var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}, "length": 0.3})
		if sc.is_empty():
			return
		var w: SimWorld = sc["w"]
		var p: SimEntity = sc["player"]
		var sdist: float = p.position.distance_to(sc["site"]["pos"])
		var cdist: float = sdist * (1.6 if site_nearer else 0.5)
		var grouper: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * cdist, p.length_m * 3.0, -p.heading)
		var calm: Array[int] = [grouper.id]
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = S3.step_n(w, 4, {p.id: sc["pos"], grouper.id: grouper.position}, [p.id], calm)
		var creature_hit: bool = not F.named(evs, "BITTEN").is_empty()
		var site_hit: bool = not F.named(evs, F.EV_BITTEN).is_empty()
		if site_nearer:
			assert_true(site_hit and not creature_hit, "site at %.2f m vs creature at %.2f m: the site is bitten" % [sdist, cdist])
		else:
			assert_true(creature_hit and not site_hit, "creature at %.2f m vs site at %.2f m: the creature is bitten" % [cdist, sdist])


func test_the_bite_buffer_holds_a_bite_for_a_site_that_enters_the_cone_in_time() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}, "away": true})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	var toward: Vector3 = -p.heading
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = F.run(w, 2, {p.id: sc["pos"]})
	assert_eq(F.named(evs, F.EV_BITTEN).size(), 0, "facing away: no hit yet")
	p.heading = toward   # the player turns inside rules.bite_buffer_s (0.2 s = 6 ticks)
	evs.append_array(F.run(w, 3, {p.id: sc["pos"]}))
	assert_eq(F.named_for(evs, F.EV_BITTEN, sc["id"]).size(), 1, "the buffered bite lands on the site once it is in the cone (F1 bite buffer)")


func test_a_bite_on_nothing_emits_the_miss_cue_and_a_late_turn_is_too_late() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}, "away": true})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["player"]
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = F.run(w, S3.ticks(S3.rule_f(w.content, "bite_buffer_s")) + 4, {p.id: sc["pos"]})
	assert_true(F.named(evs, "BITE_MISSED").size() >= 1, "nothing in the cone: BITE_MISSED")
	p.heading = -p.heading
	var late: Array[SimEvent] = F.run(w, 3, {p.id: sc["pos"]})
	assert_eq(F.named(late, F.EV_BITTEN).size(), 0, "the buffer expired: turning later does not bite by itself")


func test_a_held_bite_hits_a_site_at_most_once_per_cooldown() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 200.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var evs: Array[SimEvent] = F.run(w, 90, {sc["pid"]: sc["pos"]}, [sc["pid"]])
	var hits: Array[SimEvent] = F.named_for(evs, F.EV_BITTEN, sc["id"])
	assert_true(hits.size() >= 5, "a held bite keeps biting (%d hits in 3 s)" % hits.size())
	for i in range(1, hits.size()):
		assert_true(hits[i].tick - hits[i - 1].tick >= F.cooldown_ticks(w.content), "bites %d and %d respect rules.bite_cooldown_s" % [i - 1, i])


# ======================================================================= FoodSites contract, hash, fallbacks

func test_foodsites_queries_match_a_brute_force_scan_on_the_shipped_map() -> void:
	var w: SimWorld = F.make_world(311)
	if not F.require_food(self, w):
		return
	var food: Object = F.food_of(w)
	var n: int = int(food.call("site_count"))
	assert_true(n > 1000, "the reef has a few thousand sites (%d)" % n)
	var map: Dictionary = w.map
	var buf := PackedInt32Array([999999, 7])   # garbage: the query must clear it
	var recs: Dictionary = F.food_records()
	var centres: Array[Vector3] = [S3.spawn_point(w, 0), S3.spawn_point(w, 1), S3.spawn_point(w, 2)]
	for c: Vector3 in centres:
		food.call("sites_near_into", c, 40.0, buf)
		var got: Array[int] = []
		for i: int in buf:
			got.append(i)
		var sorted: Array[int] = got.duplicate()
		sorted.sort()
		assert_eq(got, sorted, "ascending ids")
		var lo: Array[int] = []
		var hi: Array[int] = []
		var max_r: float = 0.0
		for i2 in n:
			max_r = maxf(max_r, float(food.call("site_radius", i2)))
		for i3 in n:
			var d: float = (food.call("site_pos", i3) as Vector3).distance_to(c)
			if bool(food.call("site_alive", i3)) and d <= 40.0:
				lo.append(i3)
			if bool(food.call("site_alive", i3)) and d <= 40.0 + max_r:
				hi.append(i3)
		for i4: int in lo:
			assert_true(got.has(i4), "site %d inside the radius is returned near %s" % [i4, c])
		for i5: int in got:
			assert_true(hi.has(i5), "site %d returned near %s is within radius + its own radius" % [i5, c])
		assert_true(recs.has(str(food.call("site_type", got[0]))) if not got.is_empty() else true, "site_type is a food record id")
	assert_true(map.has("zones"), "map loaded")


func test_foodsites_create_returns_null_without_a_baked_file() -> void:
	var s: GDScript = F.require_script(self, F.SITES_SCRIPT, ["create"])
	if s == null:
		return
	var w: SimWorld = F.make_world(312)
	assert_null(s.call("create", w.content, &"no_such_map", S3.rule_f(w.content, "grid_cell_m")), "no baked food file for the map -> null")


func test_a_world_without_food_behaves_as_before() -> void:
	var w: SimWorld = F.make_world(313)   # runs WITHOUT the implementation too: the old eat / bite paths must not care
	w.set(F.WORLD_FOOD, null)
	var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0)
	var fish: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(0.05, 0.0, 0.0), 0.01, Vector3.LEFT)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = F.run(w, 40, {p.id: S3.ARENA})
	assert_true(w.state_hash() != 0, "state_hash works with food == null")
	assert_true(F.named(evs, "EATEN").size() + F.named(evs, "BITE_MISSED").size() >= 1, "the old eat / bite paths still run (fish swallowed or air-chomp)")
	assert_true(fish.id > 0, "scene sanity")


func test_state_hash_and_food_state_are_deterministic_and_change_with_an_eat() -> void:
	var a: Dictionary = F.scene(self, F.T_EGG_PEACH, {"seed": 400})
	var b: Dictionary = F.scene(self, F.T_EGG_PEACH, {"seed": 400})
	var c: Dictionary = F.scene(self, F.T_EGG_PEACH, {"seed": 400, "away": true})
	if a.is_empty() or b.is_empty() or c.is_empty():
		return
	var ea: Array[SimEvent] = F.run(a["w"], 20, {a["pid"]: a["pos"]})
	var eb: Array[SimEvent] = F.run(b["w"], 20, {b["pid"]: b["pos"]})
	var ec: Array[SimEvent] = F.run(c["w"], 20, {c["pid"]: c["pos"]})
	assert_eq(S4.signature(ea), S4.signature(eb), "two identical runs: identical event streams")
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "two identical runs: identical state_hash")
	assert_eq(F.food_state_bytes(a["w"]), F.food_state_bytes(b["w"]), "two identical runs: identical food state bytes")
	assert_eq(F.named(ec, F.EV_EATEN).size(), 0, "control run: nothing eaten")
	assert_ne((a["w"] as SimWorld).state_hash(), (c["w"] as SimWorld).state_hash(), "eating a site changes state_hash")
	assert_ne(F.food_state_bytes(a["w"]), F.food_state_bytes(c["w"]), "and the food state bytes (eaten site is in the hashed state)")
	var d: Dictionary = F.scene(self, F.T_EGG_PEACH, {"seed": 400, "away": true})
	F.run(d["w"], 20, {d["pid"]: d["pos"]})
	assert_eq(F.food_state_bytes(c["w"]), F.food_state_bytes(d["w"]), "untouched food state is identical across worlds (sparse: nothing is written for untouched sites)")


func test_events_carry_the_documented_payload() -> void:
	var sc: Dictionary = F.scene(self, F.T_STARFISH, {"override": {"hp_mult": 50.0}})
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var evs: Array[SimEvent] = _one_bite(w, sc["player"], sc["pos"], F.cooldown_ticks(w.content))
	var hits: Array[SimEvent] = F.named_for(evs, F.EV_BITTEN, sc["id"])
	assert_eq(hits.size(), 1, "one SITE_BITTEN")
	if hits.size() == 1:
		var ev: SimEvent = hits[0]
		assert_eq(ev.entity_id, sc["pid"], "entity = the biter (the player), NOT a pseudo entity id")
		assert_true(ev.value > 0.0, "value = damage")
		for k: String in ["site", "type", "pos", "max_hp", "hp"]:
			assert_true(ev.data.has(k), "SITE_BITTEN.data has '%s'" % k)
		assert_eq(str(ev.data.get("type")), str(F.T_STARFISH), "data.type")
	assert_eq(F.named(evs, "BITTEN").size(), 0, "no creature BITTEN event is emitted for a site (every older consumer would misread it)")
