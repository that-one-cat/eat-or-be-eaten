extends TestCase
## S3 impl-A: eat / bite / remains / death / respawn / vitals / growth resolution inside SimWorld.step(), the shared
## spatial grid, the event-log retention and hashing of the new state. Brains are off (brains_enabled = false) unless
## a test is about NPC behaviour; spawners stay off (NpcSpawner default); vitals only where a test enables them.
## The arena is open water in rock_arches, ~19 m above the seabed and far from obstacles and hiding volumes.

const ARENA := Vector3(150.0, -25.0, 40.0)

static var _db: ContentDB = null


func _content() -> ContentDB:
	if _db == null:
		_db = ContentDB.load_from_dir("res://data")
	return _db


func _rule(path: String) -> float:
	var cur: Variant = _content().rules()
	for part in path.split("."):
		cur = (cur as Dictionary)[part]
	return float(cur)


func _world(world_seed: int = 3, db: ContentDB = null) -> SimWorld:
	var w := SimWorld.new(world_seed, db if db != null else _content())
	w.brains_enabled = false
	w.pick_pause_enabled = false  # S6: a band-up offer would pause these one-player rule worlds
	return w


## Player at `pos` facing +X with `xp` (band/length/max HP derived by one growth step, the player does not move).
func _player(w: SimWorld, xp: float = 0.0, pos: Vector3 = ARENA) -> SimEntity:
	var e: SimEntity = w.get_entity(w.spawn_entity(SimWorld.PLAYER_SPECIES_ID, pos, 0.1, true))
	e.xp = xp
	e.heading = Vector3.RIGHT
	w.step()
	return e


func _npc(w: SimWorld, species: StringName, pos: Vector3, length_m: float, heading: Vector3 = Vector3.LEFT) -> SimEntity:
	var e: SimEntity = w.get_entity(w.spawn_entity(species, pos, length_m))
	e.heading = heading
	return e


func _ahead(w: SimWorld, e: SimEntity, frac: float) -> Vector3:
	return e.position + e.heading * (e.length_m * _rule("mouth_reach_mult") * frac)


func _events(w: SimWorld, type: SimEvent.Type, from_tick: int = 0) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev in w.events_since(from_tick):
		if ev.type == type:
			out.append(ev)
	return out


func _bits(w: SimWorld) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e.kind == SimEntity.Kind.FOOD_BIT:
			out.append(e)
	return out


func _run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.step()


# ---- grid

func test_one_grid_from_rules_tracks_spawn_move_and_removal() -> void:
	var w := _world()
	assert_almost_eq(w.grid.cell_size, _rule("grid_cell_m"), 1e-9, "cell from rules.grid_cell_m")
	var p: SimEntity = _player(w, 0.0)
	assert_true(w.grid.has(p.id), "spawned creature is in the grid")
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
	_run(w, 30)
	assert_true(w.grid.position_of(p.id).is_equal_approx(p.position), "grid position follows movement")
	var n: SimEntity = _npc(w, &"puffer", ARENA + Vector3(0, 0, 20), 0.4)
	assert_true(w.remove_entity(n.id), "removed")
	assert_false(w.grid.has(n.id), "removed entity leaves the grid")
	assert_eq(SimWorld.new(1).grid.cell_size, SimWorld.DEFAULT_GRID_CELL_M, "no content: default cell")


# ---- swallow

func test_swallow_in_the_mouth_gives_full_xp_and_hunger_and_eaten_event() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 300.0)  # 0.9 m
	p.hunger = 40.0
	var t: SimEntity = _npc(w, &"small_reef_fish", _ahead(w, p, 0.5), 0.08)
	var xp0: float = p.xp
	var t0: int = w.tick
	w.step()
	assert_null(w.get_entity(t.id), "swallowed and removed")
	assert_false(w.grid.has(t.id), "out of the grid")
	var xp_sp: float = float(_content().get_species(&"small_reef_fish")["xp"])
	assert_almost_eq(p.xp - xp0, xp_sp, 1e-9, "full XP (ratio 0.089 >= full_at_ratio)")
	assert_almost_eq(p.hunger, 40.0 + xp_sp * _rule("hunger_per_xp"), 1e-9, "hunger restored (vitals off: no drain)")
	var ev: Array[SimEvent] = _events(w, SimEvent.Type.EATEN, t0)
	assert_eq(ev.size(), 1, "one EATEN")
	if ev.size() == 1:
		assert_eq(ev[0].entity_id, t.id, "entity = the swallowed one")
		assert_eq(ev[0].other_id, p.id, "other = the eater")
		assert_almost_eq(ev[0].value, xp_sp, 1e-9, "value = XP gained")


func test_no_swallow_behind_out_of_reach_or_over_the_ratio() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 300.0)
	var reach: float = p.length_m * _rule("mouth_reach_mult")
	var behind: SimEntity = _npc(w, &"small_reef_fish", p.position - Vector3.RIGHT * reach * 0.5, 0.08)
	var far: SimEntity = _npc(w, &"small_reef_fish", p.position + Vector3.RIGHT * reach * 1.2, 0.08)
	var big: SimEntity = _npc(w, &"small_reef_fish", p.position + Vector3(reach * 0.5, 0, 0.01), p.length_m * _rule("swallow_ratio") * 1.05)
	_run(w, 5)
	assert_not_null(w.get_entity(behind.id), "behind the mouth")
	assert_not_null(w.get_entity(far.id), "beyond reach")
	assert_not_null(w.get_entity(big.id), "over swallow_ratio")
	assert_eq(_events(w, SimEvent.Type.EATEN).size(), 0, "nothing eaten")


func test_swallow_xp_uses_the_falloff_for_tiny_targets() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 1200.0)  # 3.5 m
	var t: SimEntity = _npc(w, &"plankton", _ahead(w, p, 0.5), 0.015)
	var xp0: float = p.xp
	w.step()
	assert_null(w.get_entity(t.id), "swallowed")
	var expected: float = SimRules.xp_gain(1.0, p.length_m, 0.015, _content().rules()["xp_falloff"])
	assert_true(expected < 0.5, "falloff applies (%s)" % expected)
	assert_almost_eq(p.xp - xp0, expected, 1e-9, "B4 gets the reduced XP")


func test_npcs_swallow_creatures_only_when_hunting() -> void:
	var w := _world()
	var passive: SimEntity = _npc(w, &"small_reef_fish", ARENA, 0.2, Vector3.RIGHT)
	var snack: SimEntity = _npc(w, &"plankton", _ahead(w, passive, 0.5), 0.015)
	var cuda: SimEntity = _npc(w, &"barracuda", ARENA + Vector3(0, 0, 20), 1.2, Vector3.RIGHT)
	var prey: SimEntity = _npc(w, &"silver_schooling_fish", _ahead(w, cuda, 0.5), 0.1)
	_run(w, 3)
	assert_not_null(w.get_entity(snack.id), "a passive NPC does not swallow creatures")
	assert_null(w.get_entity(prey.id), "a predator swallows prey in its mouth")
	assert_true(w.get_entity(passive.id) != null and w.get_entity(cuda.id) != null, "both eaters still there")
	var p2 := _world()
	var src: SimEntity = _npc(p2, &"grouper", ARENA, 1.5)
	src.hp = 0.0
	p2.step()
	var bits: Array[SimEntity] = _bits(p2)
	assert_true(bits.size() > 0, "remains exist")
	if bits.is_empty():
		return
	var fish: SimEntity = _npc(p2, &"small_reef_fish", bits[0].position - Vector3.RIGHT * 0.05, 0.2, Vector3.RIGHT)
	p2.step()
	assert_true(_events(p2, SimEvent.Type.EATEN).size() >= 1, "any NPC swallows food bits")
	assert_almost_eq(fish.xp, 0.0, 1e-12, "NPCs gain no XP")


# ---- bite

func test_bite_damage_cooldown_event_and_aggro() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 200.0)  # B2
	var v: SimEntity = _npc(w, &"grouper", _ahead(w, p, 0.5), 2.0)
	var t0: int = w.tick
	for i in 60:
		w.submit(SimCommand.bite(p.id, v.id))
		w.step()
	var bites: Array[SimEvent] = _events(w, SimEvent.Type.BITTEN, t0)
	var cd: int = roundi(_rule("bite_cooldown_s") * SimWorld.TICK_RATE)
	assert_eq(bites.size(), ceili(60.0 / float(cd)), "one bite per cooldown (%d ticks)" % cd)
	var dmg: float = float(_content().get_band(p.band)["bite_power"]) * p.length_m * p.length_m
	assert_almost_eq(v.max_hp - v.hp, dmg * bites.size(), 1e-6, "damage = bite_power * L^2 per bite")
	if bites.size() > 1:
		assert_eq(bites[0].tick, t0, "first bite immediate")
		assert_eq(bites[1].tick - bites[0].tick, cd, "cooldown spacing")
		assert_eq(bites[0].entity_id, v.id, "entity = victim")
		assert_eq(bites[0].other_id, p.id, "other = biter")
		assert_almost_eq(bites[0].value, dmg, 1e-9, "value = damage")
		assert_almost_eq(float(bites[0].data["max_hp"]), v.max_hp, 1e-9, "data.max_hp")
	assert_eq(v.aggro_target, p.id, "victim aggro on the biter")
	assert_eq(v.aggro_until_tick, bites[bites.size() - 1].tick + roundi(_rule("retaliate_duration_s") * 30.0), "aggro for retaliate_duration_s")


func test_npc_bite_uses_band_by_length_and_bite_mult() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 1000.0)
	var g: SimEntity = _npc(w, &"grouper", p.position - Vector3.RIGHT * 0.5, 1.5, Vector3.RIGHT)
	var hp0: float = p.hp
	w.submit(SimCommand.bite(g.id, p.id))
	w.step()
	assert_eq(g.band, 3, "1.5 m NPC uses band 3")
	var expected: float = float(_content().get_band(3)["bite_power"]) * 1.5 * 1.5 * 1.5
	assert_almost_eq(hp0 - p.hp, expected, 1e-6, "same formula against the player")


func test_auto_target_is_the_nearest_non_swallowable_in_the_cone() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 300.0)
	var snack: SimEntity = _npc(w, &"silver_schooling_fish", _ahead(w, p, 0.2), 0.08)
	var near_v: SimEntity = _npc(w, &"grouper", _ahead(w, p, 0.5), 2.0)
	var far_v: SimEntity = _npc(w, &"grouper", _ahead(w, p, 0.9), 2.0)
	var back: SimEntity = _npc(w, &"grouper", p.position - Vector3.RIGHT * 0.1, 2.0)
	w.submit(SimCommand.bite(p.id, -1))
	w.step()
	assert_null(w.get_entity(snack.id), "the swallowable one is swallowed instead")
	assert_true(near_v.hp < near_v.max_hp, "nearest valid target bitten")
	assert_almost_eq(far_v.hp, far_v.max_hp, 1e-12, "farther one untouched")
	assert_almost_eq(back.hp, back.max_hp, 1e-12, "one behind untouched")


func test_puffer_inflates_spikes_the_biter_and_grows_for_the_swallow_rule() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 50.0)  # B1
	var puffer: SimEntity = _npc(w, &"puffer", _ahead(w, p, 0.3), 0.4)
	var inflate: Dictionary = _content().get_species(&"puffer")["inflate"]
	var hp0: float = p.hp
	var t0: int = w.tick
	w.submit(SimCommand.bite(p.id, puffer.id))
	w.step()
	assert_eq(_events(w, SimEvent.Type.BITTEN, t0).size(), 1, "B1 can bite a puffer")
	assert_eq(_events(w, SimEvent.Type.INFLATED, t0).size(), 1, "INFLATED")
	assert_eq(_events(w, SimEvent.Type.SPIKED, t0).size(), 0, "no SPIKED on the inflating bite (Director)")
	assert_almost_eq(p.hp, hp0, 1e-12, "the biter is unhurt by the inflating bite")
	assert_eq(puffer.inflated_until_tick, t0 + roundi(float(inflate["duration_s"]) * 30.0), "inflated for duration_s")
	assert_almost_eq(w.effective_length(puffer), 0.4 * float(inflate["scale"]), 1e-9, "inflated length for the swallow rule")
	# a bite on the already inflated puffer spikes the biter
	_run(w, p.bite_ready_tick - w.tick)
	var t1: int = w.tick
	w.submit(SimCommand.bite(p.id, puffer.id))
	w.step()
	assert_eq(_events(w, SimEvent.Type.BITTEN, t1).size(), 1, "second bite lands")
	assert_eq(_events(w, SimEvent.Type.INFLATED, t1).size(), 0, "no re-inflation while inflated")
	var spikes: Array[SimEvent] = _events(w, SimEvent.Type.SPIKED, t1)
	assert_eq(spikes.size(), 1, "SPIKED on a bite while inflated")
	var spike: float = float(inflate["spike_damage_frac_of_biter_max_hp"]) * p.max_hp
	assert_almost_eq(hp0 - p.hp, spike, 1e-9, "10% of the biter's max HP")
	if spikes.size() == 1:
		assert_eq(spikes[0].entity_id, p.id, "entity = biter")
		assert_eq(spikes[0].other_id, puffer.id, "other = puffer")
	_run(w, t0 + roundi(float(inflate["duration_s"]) * 30.0) - w.tick)
	assert_almost_eq(w.effective_length(puffer), 0.4, 1e-9, "deflated after duration_s")


# ---- kills and remains

func test_kill_spawns_remains_that_carry_the_xp_and_expire() -> void:
	var w := _world(9)
	var p: SimEntity = _player(w, 200.0, ARENA + Vector3(0, 0, -20))
	var v: SimEntity = _npc(w, &"grouper", ARENA, 1.5)
	v.hp = 0.01
	var t0: int = w.tick
	w.submit(SimCommand.bite(p.id, v.id))
	v.position = _ahead(w, p, 0.5)
	w.step()
	var died: Array[SimEvent] = _events(w, SimEvent.Type.DIED, t0)
	assert_eq(died.size(), 1, "DIED")
	if died.size() == 1:
		assert_eq(died[0].entity_id, v.id, "entity = dead")
		assert_eq(died[0].other_id, p.id, "other = killer")
		assert_eq(String(died[0].data["species"]), "grouper", "data.species")
		assert_almost_eq(float(died[0].data["length"]), 1.5, 1e-9, "data.length")
		assert_true(died[0].data["pos"] is Vector3, "data.pos")
	assert_null(w.get_entity(v.id), "NPC removed")
	var bits: Array[SimEntity] = _bits(w)
	var fb: Dictionary = _content().rules()["remains"]["food_bits"]
	assert_true(bits.size() >= int(fb["min"]) and bits.size() <= int(fb["max"]), "3-6 bits, got %d" % bits.size())
	assert_eq(_events(w, SimEvent.Type.FOOD_SPAWNED, t0).size(), bits.size(), "FOOD_SPAWNED per bit")
	var xp_sum: float = 0.0
	var hunger_sum: float = 0.0
	for b in bits:
		xp_sum += b.xp_value
		hunger_sum += b.hunger_value
		assert_true(w.grid.has(b.id), "bit in the grid")
		assert_almost_eq(b.length_m, float(fb["length_m"]), 1e-12, "bit length from data")
		assert_almost_eq(b.velocity.length(), float(fb["drift_mps"]), 1e-6, "drifts at drift_mps")
	var xp_g: float = float(_content().get_species(&"grouper")["xp"])
	assert_almost_eq(xp_sum, xp_g, 1e-9, "bits share the creature's XP")
	assert_almost_eq(hunger_sum, xp_g * _rule("hunger_per_xp"), 1e-9, "and its hunger value")
	assert_almost_eq(p.xp, 200.0, 1e-9, "no XP for the kill itself")
	p.position = ARENA + Vector3(0, 30, 0)  # out of the way: let the bits expire
	_run(w, roundi(float(fb["lifetime_s"]) * 30.0) + 1)
	assert_eq(_bits(w).size(), 0, "bits expire after lifetime_s")
	for b in bits:
		assert_false(w.grid.has(b.id), "expired bit left the grid")


func test_swallowing_a_food_bit_uses_the_source_length_for_falloff() -> void:
	var w := _world(4)
	var v: SimEntity = _npc(w, &"grouper", ARENA, 1.5)
	v.hp = 0.0
	w.step()
	var bits: Array[SimEntity] = _bits(w)
	assert_true(bits.size() > 0, "bits")
	if bits.is_empty():
		return
	var b: SimEntity = bits[0]
	var p: SimEntity = _player(w, 50.0, b.position + Vector3(0, 0, 40))
	p.hunger = 10.0
	p.position = b.position - Vector3.RIGHT * 0.02
	var xp0: float = p.xp
	var val: float = b.xp_value
	var hun: float = b.hunger_value
	w.step()
	assert_null(w.get_entity(b.id), "swallowed")
	assert_true(p.xp - xp0 >= val - 1e-9, "full XP (source 1.5 m is not tiny for a B1 player), got %s of %s" % [p.xp - xp0, val])
	assert_true(p.hunger >= minf(10.0 + hun, _rule("hunger_max")) - 1e-9, "hunger restored (capped at hunger_max)")


# ---- player death and respawn

func test_player_death_halves_xp_drops_band_and_respawns_at_the_nearest_spawn() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 150.0, Vector3(140.0, -10.0, -200.0))  # B2, near spawn [150, -5, -220]
	assert_eq(p.band, 2, "B2")
	var t0: int = w.tick
	var r0: int = w.run_ticks
	p.hp = 0.0
	w.step()
	var died: Array[SimEvent] = _events(w, SimEvent.Type.DIED, t0)
	assert_eq(died.size(), 1, "DIED")
	if died.size() == 1:
		assert_eq(died[0].other_id, -1, "no killer")
	assert_almost_eq(p.xp, 150.0 * (1.0 - _rule("death_xp_loss_frac")), 1e-9, "lose half of the XP")
	assert_eq(p.band, 1, "dropped to B1")
	assert_eq(_events(w, SimEvent.Type.BAND_DOWN, t0).size(), 1, "BAND_DOWN")
	assert_almost_eq(p.length_m, SimRules.length_for_xp(75.0, [_content().get_band(1), _content().get_band(2), _content().get_band(3), _content().get_band(4)]), 1e-9, "shrunk")
	assert_eq(p.deaths, 1, "deaths counted")
	assert_false(p.alive, "waiting for respawn")
	assert_false(w.grid.has(p.id), "dead player out of the grid")
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
	var delay: int = roundi(_rule("respawn_delay_s") * 30.0)
	_run(w, delay - 1)
	assert_false(p.alive, "still dead before respawn_delay_s")
	w.step()
	assert_true(p.alive, "respawned after respawn_delay_s")
	assert_eq(_events(w, SimEvent.Type.RESPAWNED, t0).size(), 1, "RESPAWNED")
	assert_true(p.position.distance_to(Vector3(150, -5, -220)) < 1.0, "at the nearest player spawn: %s" % p.position)
	assert_almost_eq(p.hp, p.max_hp, 1e-9, "full HP")
	assert_almost_eq(p.hunger, _rule("hunger_max"), 1e-9, "full hunger")
	assert_true(w.grid.has(p.id), "back in the grid")
	assert_eq(w.run_ticks - r0, delay + 1, "run timer kept running")


func test_a_predator_swallows_a_small_player_who_then_dies() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 0.0)
	var shark: SimEntity = _npc(w, &"shark", p.position - Vector3.RIGHT * 0.5, 3.0, Vector3.RIGHT)
	var t0: int = w.tick
	w.step()
	var died: Array[SimEvent] = _events(w, SimEvent.Type.DIED, t0)
	assert_eq(_events(w, SimEvent.Type.EATEN, t0).size(), 1, "EATEN")
	assert_eq(died.size(), 1, "the swallowed player dies the same tick")
	if died.size() == 1:
		assert_eq(died[0].other_id, shark.id, "killed by the shark")
	assert_not_null(w.get_entity(p.id), "a player is never removed")
	assert_eq(p.deaths, 1, "death counted")


# ---- vitals

func test_vitals_drain_starve_and_regen_only_when_enabled() -> void:
	var off := _world()
	var p0: SimEntity = _player(off, 50.0)
	_run(off, 300)
	assert_almost_eq(p0.hunger, _rule("hunger_max"), 1e-9, "vitals off by default: no drain")
	var w := _world()
	w.vitals_enabled = true
	var p: SimEntity = _player(w, 50.0)
	var h0: float = p.hunger
	_run(w, 300)
	assert_almost_eq(h0 - p.hunger, _rule("hunger_max") / _rule("hunger_full_to_empty_s") * 10.0, 1e-6, "10 s of B1 drain")
	p.hunger = 0.0
	var hp0: float = p.hp
	_run(w, 30)
	assert_almost_eq(hp0 - p.hp, _rule("starvation_hp_frac_per_s") * p.max_hp, 1e-6, "starvation: 2% max HP per s")
	p.hunger = _rule("hunger_max")
	p.hp = p.max_hp * 0.5
	_run(w, 30)
	assert_true(p.hp > p.max_hp * 0.5, "regen while hunger > 50%")
	p.hp = p.max_hp * 0.5
	p.hunger = _rule("hunger_max") * _rule("regen_min_hunger_frac")
	_run(w, 30)
	assert_almost_eq(p.hp, p.max_hp * 0.5, 1e-9, "no regen at or below 50%")


# ---- growth

func test_growth_follows_xp_and_keeps_explicit_spawn_lengths() -> void:
	var w := _world()
	var s: SimEntity = w.get_entity(w.spawn_entity(SimWorld.PLAYER_SPECIES_ID, ARENA, 0.15, true))
	_run(w, 3)
	assert_almost_eq(s.length_m, 0.15, 1e-12, "an explicit length is kept while the XP does not change")
	var p: SimEntity = _player(w, 0.0, ARENA + Vector3(0, 0, 10))
	var t0: int = w.tick
	p.xp = 100.0
	w.step()
	assert_eq(p.band, 2, "band 2 at 100 XP")
	assert_almost_eq(p.length_m, 0.30, 1e-9, "length from length_for_xp")
	var exp_hp: float = float(_content().get_band(2)["max_hp"])
	if str(_content().rules()["player_hp_model"]) == "length2":
		exp_hp = float(_content().get_species(p.species_id)["base_hp"]) * p.length_m * p.length_m
	assert_almost_eq(p.max_hp, exp_hp, 1e-9, "max HP by rules.player_hp_model")
	assert_almost_eq(p.hp, p.max_hp, 1e-9, "hp keeps its fraction")
	var ups: Array[SimEvent] = _events(w, SimEvent.Type.BAND_UP, t0)
	assert_eq(ups.size(), 1, "BAND_UP once")
	if ups.size() == 1:
		assert_almost_eq(ups[0].value, 2.0, 1e-12, "value = new band")


func test_player_hp_model_length2_uses_base_hp_times_length_squared() -> void:
	var db := ContentDB.load_from_dir("res://data")
	db.rules()["player_hp_model"] = "length2"
	var w := _world(3, db)
	var p: SimEntity = _player(w, 300.0)
	var base: float = float(db.get_species(SimWorld.PLAYER_SPECIES_ID)["base_hp"])
	assert_almost_eq(p.max_hp, base * p.length_m * p.length_m, 1e-9, "length2 model")


# ---- event log and hashing

func test_event_log_is_bounded() -> void:
	var w := _world()
	var p: SimEntity = _player(w, 0.0)
	_run(w, SimWorld.EVENT_RETENTION_TICKS + 60)
	var spawn_seen: bool = false
	for ev in w.events_since(0):
		if ev.entity_id == p.id and ev.type == SimEvent.Type.ENTITY_SPAWNED:
			spawn_seen = true
		assert_true(ev.tick >= w.tick - SimWorld.EVENT_RETENTION_TICKS - 30, "no event older than the retention window")
	assert_false(spawn_seen, "the tick-0 spawn event was trimmed")
	w.spawn_entity(&"puffer", ARENA + Vector3(0, 0, 30), 0.4)
	assert_eq(w.events_since(w.tick).size(), 1, "recent events are kept")


func test_living_world_is_deterministic_and_new_fields_are_hashed() -> void:
	var hashes: Array[int] = []
	for run in 2:
		var w := SimWorld.new(21, _content())
		w.vitals_enabled = true
		NpcSpawner.set_enabled(w, true)
		var id: int = w.spawn_player(0)
		for t in 300:
			w.submit(SimCommand.move(id, Vector3(sin(t * 0.05), -0.1, -1.0), 1.0, t))
			if t % 7 == 0:
				w.submit(SimCommand.bite(id, -1, t))
		for t in 300:
			w.step()
		hashes.append(w.state_hash())
		if run == 1:
			assert_true(w.entity_count() > 10, "the spawner populated the world (%d)" % w.entity_count())
			var e: SimEntity = w.get_entity(id)
			var h: int = w.state_hash()
			for field in ["deaths", "respawn_tick", "bite_ready_tick", "bite_until_tick", "bite_miss_ready_tick", "inflated_until_tick", "aggro_target", "aggro_until_tick", "brain_state", "hidden_since_tick", "last_damage_from", "expire_tick"]:
				var old: int = e.get(field)
				e.set(field, old + 1)
				assert_ne(w.state_hash(), h, "%s is hashed" % field)
				e.set(field, old)
			for field in ["xp_value", "hunger_value", "source_length_m", "grown_at_xp"]:
				var oldf: float = e.get(field)
				e.set(field, oldf + 0.5)
				assert_ne(w.state_hash(), h, "%s is hashed" % field)
				e.set(field, oldf)
			e.hidden = not e.hidden
			assert_ne(w.state_hash(), h, "hidden is hashed")
			e.hidden = not e.hidden
			w.run_ticks += 1
			assert_ne(w.state_hash(), h, "run_ticks is hashed")
			w.run_ticks -= 1
			assert_eq(w.state_hash(), h, "restored")
	assert_eq(hashes[0], hashes[1], "same seed + commands -> same hash with brains, spawners, eating and vitals")
