extends TestCase
## T1.2 SimDebug God tools on a plain SimWorld (no nodes): teleport, set_band, heal, spawn_species + refusals,
## spawn_food_bits, despawn_debug, god mode, hunger lock, noclip, time-scale state, boss shortcuts, and the guarantee
## that an unused / all-off debug state changes nothing (state_hash, rng).

const G := preload("res://tests/god_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

## A sphere obstacle of the reef (rock_2: centre (20, -46.51, 100), r 4), see data/maps/reef.json.
const ROCK_CENTRE: Vector3 = Vector3(20.0, -46.51, 100.0)
const ROCK_R: float = 4.0


# ---------------------------------------------------------------- debug state is off by default

func test_world_has_no_debug_state_by_default() -> void:
	var w: SimWorld = S3.make_world(1)
	assert_null(w.debug, "world.debug is null until a God tool creates it")


func test_state_is_created_lazily_and_is_stable() -> void:
	var w: SimWorld = S3.make_world(1)
	var st: SimDebug.State = SimDebug.state(w)
	assert_not_null(st, "created")
	assert_true(SimDebug.state(w) == st, "the same object on the second call")
	assert_false(st.god or st.hunger_lock or st.noclip, "all flags off")
	assert_eq(st.time_scale, 1.0, "time scale 1")
	assert_eq(st.spawned_ids.size(), 0, "nothing spawned")


# ---------------------------------------------------------------- teleport

func test_teleport_moves_stops_and_syncs_the_grid() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	p.velocity = Vector3(3, 0, 0)
	p.speed = 3.0
	var target := Vector3(-10.0, -20.0, -78.0)  # `kelp` place
	assert_true(SimDebug.teleport(w, p.id, target), "teleport succeeds")
	assert_true(p.position.distance_to(target) < 0.5, "arrived (resolved against terrain): %s" % p.position)
	assert_eq(p.velocity, Vector3.ZERO, "velocity zeroed")
	assert_eq(p.speed, 0.0, "speed zeroed")
	assert_true(w.grid.has(p.id), "still in the grid")
	assert_true(w.grid.position_of(p.id).distance_to(p.position) < 1e-4, "grid position equals entity position")
	assert_true(w.grid.query_radius(target, 2.0).has(p.id), "the grid finds it at the new place")


func test_teleport_to_every_shipped_place() -> void:
	var rg: Dictionary = G.rig(2)
	var w: SimWorld = rg["w"]
	for place: Dictionary in GodSimCommands.places(w):
		var pos: Vector3 = place["pos"]
		assert_true(SimDebug.teleport(w, rg["id"], pos), "%s: teleport ok" % place["id"])
		assert_true((rg["p"] as SimEntity).position.distance_to(pos) < 0.5, "%s: arrived" % place["id"])


func test_teleport_refusals() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var before: Vector3 = p.position
	assert_false(SimDebug.teleport(w, 99999, Vector3(0, -10, 0)), "unknown entity")
	assert_false(SimDebug.teleport(w, p.id, Vector3(INF, 0, 0)), "infinite position")
	assert_false(SimDebug.teleport(w, p.id, Vector3(NAN, 0, 0)), "NaN position")
	assert_eq(p.position, before, "refusals do not move the player")
	p.alive = false
	assert_false(SimDebug.teleport(w, p.id, Vector3(0, -10, 0)), "dead player")
	assert_eq(p.position, before, "a dead player does not move")


func test_teleport_into_a_rock_is_pushed_out() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	assert_true(SimDebug.teleport(w, p.id, ROCK_CENTRE), "teleport into the rock centre")
	assert_true(p.position.distance_to(ROCK_CENTRE) >= ROCK_R - 0.01, "resolved outside the sphere (%.2f m from its centre, r %.1f)" % [p.position.distance_to(ROCK_CENTRE), ROCK_R])


func test_teleport_clamps_to_the_map_box() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	assert_true(SimDebug.teleport(w, p.id, Vector3(99999, 50, -99999)), "far outside the map")
	var half: float = float(w.map["size_m"]) * 0.5
	assert_true(absf(p.position.x) <= half and absf(p.position.z) <= half and p.position.y <= 0.0, "clamped into the box / below the surface: %s" % p.position)


# ---------------------------------------------------------------- set_band / heal / xp

func test_set_band_each_band_applies_after_one_step() -> void:
	for b: int in range(1, 5):
		var rg: Dictionary = G.rig(10 + b)
		var w: SimWorld = rg["w"]
		var p: SimEntity = rg["p"]
		assert_eq(SimDebug.set_band(w, p.id, b), b, "band %d requested" % b)
		var t0: int = w.tick
		S3.step_n(w, 2)
		assert_eq(p.band, b, "band %d applied" % b)
		var lm: Dictionary = w.content.get_band(b)["length_m"]
		assert_true(p.length_m >= float(lm["min"]) - 1e-6 and p.length_m <= float(lm["max"]) + 1e-6, "band %d: length %.3f inside %s" % [b, p.length_m, lm])
		assert_true(p.max_hp > 0.0, "band %d: max hp derived" % b)
		if b > 1:
			assert_true(G.has_event(w.events_since(t0), SimEvent.Type.BAND_UP), "band %d: BAND_UP emitted" % b)


func test_set_band_clamps_and_refuses() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var n: int = w.content.band_count()
	assert_eq(SimDebug.set_band(w, rg["id"], 0), 1, "0 clamps to band 1")
	assert_eq(SimDebug.set_band(w, rg["id"], -5), 1, "negative clamps to band 1")
	assert_eq(SimDebug.set_band(w, rg["id"], 99), n, "99 clamps to the last band")
	var npc: SimEntity = S3.npc_at(w, &"puffer", S3.ARENA)
	assert_eq(SimDebug.set_band(w, npc.id, 2), 0, "a non-player is refused (returns 0)")
	assert_eq(SimDebug.set_band(w, 424242, 2), 0, "unknown id is refused")


func test_set_band_two_pauses_the_world_for_the_mutation_pick() -> void:
	var rg: Dictionary = G.rig(21)
	var w: SimWorld = rg["w"]
	SimDebug.set_band(w, rg["id"], 2)
	S3.step_n(w, 3)
	assert_true(w.paused_for_pick, "the first time into a band offers a mutation and pauses the single-player world")
	assert_eq((rg["p"] as SimEntity).pending_offer.size() > 0, true, "an offer is pending")


func test_set_xp_and_old_hooks_still_work() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	assert_true(SimDebug.set_xp(w, rg["id"], 50.0), "set_xp")
	assert_eq((rg["p"] as SimEntity).xp, 50.0, "xp written")
	assert_true(SimDebug.set_xp(w, rg["id"], -3.0), "negative accepted")
	assert_eq((rg["p"] as SimEntity).xp, 0.0, "but floored at 0")
	assert_true(SimDebug.force_band_up(w, rg["id"]), "force_band_up")
	assert_false(SimDebug.set_xp(w, 4242, 1.0), "unknown id")


func test_heal_refills_a_living_player_only() -> void:
	var rg: Dictionary = G.rig(1)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	p.hp = 1.0
	assert_true(SimDebug.heal(w, p.id), "heal")
	assert_eq(p.hp, p.max_hp, "full hp")
	var npc: SimEntity = S3.npc_at(w, &"puffer", S3.ARENA)
	assert_false(SimDebug.heal(w, npc.id), "a non-player is refused")
	p.alive = false
	assert_false(SimDebug.heal(w, p.id), "a dead player is refused")


# ---------------------------------------------------------------- spawn species

func test_spawnable_species_spawn_with_band_and_hp() -> void:
	var rg: Dictionary = G.rig(31)
	var w: SimWorld = rg["w"]
	var at: Vector3 = S3.ARENA
	var spawnable: PackedStringArray = GodSimCommands.spawnable_species(w)
	assert_true(spawnable.size() >= 6, "the shipped roster has interactive + large species: %s" % [spawnable])
	for sid: String in spawnable:
		if w.content.get_species(StringName(sid)).get("boss") is Dictionary:
			continue
		var id: int = SimDebug.spawn_species(w, StringName(sid), at)
		assert_true(id >= 0, "%s spawns" % sid)
		var e: SimEntity = w.get_entity(id)
		assert_not_null(e, "%s exists" % sid)
		if e == null:
			continue
		var lm: Dictionary = w.content.get_species(StringName(sid))["length_m"]
		assert_almost_eq(e.length_m, (float(lm["min"]) + float(lm["max"])) * 0.5, 1e-6, "%s: default length is the middle of its range" % sid)
		assert_eq(e.band, S3.band_for_length(w.content, e.length_m), "%s: band from length" % sid)
		assert_true(e.hp > 0.0 and e.hp == e.max_hp, "%s: full positive hp" % sid)
		assert_almost_eq(e.max_hp, float(w.content.get_species(StringName(sid))["base_hp"]) * e.length_m * e.length_m, 1e-3, "%s: hp = base_hp x length^2" % sid)
		assert_true(w.grid.has(id), "%s in the grid" % sid)
		assert_false(e.is_player, "%s is an NPC" % sid)


func test_spawn_length_is_clamped_to_the_species_range() -> void:
	var w: SimWorld = G.rig(32)["w"]
	var lm: Dictionary = w.content.get_species(&"shark")["length_m"]
	var big: SimEntity = w.get_entity(SimDebug.spawn_species(w, &"shark", S3.ARENA, 999.0))
	assert_almost_eq(big.length_m, float(lm["max"]), 1e-6, "too long -> max")
	var small: SimEntity = w.get_entity(SimDebug.spawn_species(w, &"shark", S3.ARENA, 0.001))
	assert_almost_eq(small.length_m, float(lm["min"]), 1e-6, "too short -> min")
	var exact: SimEntity = w.get_entity(SimDebug.spawn_species(w, &"shark", S3.ARENA, 3.0))
	assert_almost_eq(exact.length_m, 3.0, 1e-6, "in range -> as asked")
	var nan: SimEntity = w.get_entity(SimDebug.spawn_species(w, &"shark", S3.ARENA, NAN))
	assert_almost_eq(nan.length_m, (float(lm["min"]) + float(lm["max"])) * 0.5, 1e-6, "NaN -> the default")


func test_spawn_refusals() -> void:
	var w: SimWorld = G.rig(33)["w"]
	var count0: int = w.entity_count()
	for sid: StringName in [&"plankton", &"krill_shallows", &"krill_open", &"krill_abyss"]:
		assert_eq(SimDebug.spawn_species(w, sid, S3.ARENA), -1, "%s is ambient tier: refused" % sid)
		assert_false(SimDebug.spawn_refusal(w, sid).is_empty(), "%s: a reason is given" % sid)
	assert_eq(SimDebug.spawn_species(w, &"kraken", S3.ARENA), -1, "unknown species refused")
	assert_has(SimDebug.spawn_refusal(w, &"kraken"), "unknown", "reason says unknown")
	assert_eq(SimDebug.spawn_species(w, &"food_bit", S3.ARENA), -1, "food_bit is not a species")
	assert_eq(SimDebug.spawn_species(w, &"puffer", Vector3(INF, 0, 0)), -1, "non-finite position refused")
	assert_eq(w.entity_count(), count0, "refusals add no entity")
	assert_eq(SimDebug.state(w).spawned_ids.size(), 0, "and record no id")


func test_second_boss_is_refused_while_one_is_alive() -> void:
	var w: SimWorld = G.rig(34)["w"]
	assert_eq(w.boss_id(), -1, "test setup: no boss")
	assert_eq(SimDebug.spawn_refusal(w, &"giant_shark"), "", "the first boss may be spawned")
	var id: int = SimDebug.spawn_species(w, &"giant_shark", S6.abyss_spot(w))
	assert_true(id >= 0, "first boss spawns")
	assert_eq(w.boss_id(), id, "and becomes the world's boss")
	assert_eq(SimDebug.spawn_species(w, &"giant_shark", S6.abyss_spot(w)), -1, "second boss refused")
	assert_has(SimDebug.spawn_refusal(w, &"giant_shark"), "boss", "reason mentions the boss")
	assert_eq(w.boss_id(), id, "the first boss is still THE boss")


func test_despawn_removes_only_debug_spawns() -> void:
	var rg: Dictionary = G.rig(35)
	var w: SimWorld = rg["w"]
	var native: SimEntity = S3.npc_at(w, &"puffer", S3.ARENA + Vector3(30, 0, 0))
	var a: int = SimDebug.spawn_species(w, &"puffer", S3.ARENA)
	var b: int = SimDebug.spawn_species(w, &"grouper", S3.ARENA + Vector3(0, 5, 0))
	var bits: PackedInt32Array = SimDebug.spawn_food_bits(w, S3.ARENA, 3)
	assert_eq(SimDebug.state(w).spawned_ids.size(), 2 + bits.size(), "all debug spawns recorded")
	assert_eq(SimDebug.despawn_debug(w), 2 + bits.size(), "removed count")
	assert_null(w.get_entity(a), "debug puffer gone")
	assert_null(w.get_entity(b), "debug grouper gone")
	for id: int in bits:
		assert_null(w.get_entity(id), "debug bit gone")
	assert_not_null(w.get_entity(native.id), "the non-debug NPC stays")
	assert_not_null(w.get_entity(rg["id"]), "the player stays")
	assert_eq(SimDebug.despawn_debug(w), 0, "second call removes nothing")
	assert_false(w.grid.has(a), "removed entities left the grid")


func test_despawn_counts_only_what_still_exists() -> void:
	var w: SimWorld = G.rig(36)["w"]
	var a: int = SimDebug.spawn_species(w, &"puffer", S3.ARENA)
	var b: int = SimDebug.spawn_species(w, &"puffer", S3.ARENA + Vector3(0, 4, 0))
	w.remove_entity(a)
	assert_eq(SimDebug.despawn_debug(w), 1, "one was already gone")
	assert_null(w.get_entity(b), "the other removed")


func test_despawn_without_any_debug_state_is_a_no_op() -> void:
	var w: SimWorld = S3.make_world(1)
	assert_eq(SimDebug.despawn_debug(w), 0, "no state, nothing removed")
	assert_null(w.debug, "and no state is created by despawn")


# ---------------------------------------------------------------- food bits

func test_food_bits_are_entities_with_xp_hunger_and_events() -> void:
	var rg: Dictionary = G.rig(41)
	var w: SimWorld = rg["w"]
	var t0: int = w.tick
	var ids: PackedInt32Array = SimDebug.spawn_food_bits(w, S3.ARENA, 5)
	assert_eq(ids.size(), 5, "five bits")
	var spawned: int = 0
	for ev: SimEvent in w.events_since(t0):
		if ev.type == SimEvent.Type.FOOD_SPAWNED:
			spawned += 1
	assert_eq(spawned, 5, "five FOOD_SPAWNED events")
	for id: int in ids:
		var b: SimEntity = w.get_entity(id)
		assert_eq(b.kind, SimEntity.Kind.FOOD_BIT, "kind")
		assert_eq(b.xp_value, SimDebug.FOOD_BIT_XP, "default xp")
		assert_true(b.hunger_value > 0.0, "hunger value")
		assert_true(b.expire_tick > w.tick, "has a lifetime")
		assert_true(w.grid.has(id), "in the grid")
		assert_true(b.position.distance_to(S3.ARENA) < 3.0, "near the aim point")


func test_food_bit_count_xp_and_position_edges() -> void:
	var w: SimWorld = G.rig(42)["w"]
	assert_eq(SimDebug.spawn_food_bits(w, S3.ARENA, 0).size(), 1, "0 clamps to 1")
	assert_eq(SimDebug.spawn_food_bits(w, S3.ARENA, -4).size(), 1, "negative clamps to 1")
	assert_eq(SimDebug.spawn_food_bits(w, S3.ARENA, 1000).size(), 64, "1000 clamps to 64")
	var custom: PackedInt32Array = SimDebug.spawn_food_bits(w, S3.ARENA, 1, 7.5)
	assert_eq(w.get_entity(custom[0]).xp_value, 7.5, "explicit xp")
	var fallback: PackedInt32Array = SimDebug.spawn_food_bits(w, S3.ARENA, 1, NAN)
	assert_eq(w.get_entity(fallback[0]).xp_value, SimDebug.FOOD_BIT_XP, "NaN xp -> default")
	assert_eq(SimDebug.spawn_food_bits(w, Vector3(INF, 0, 0), 3).size(), 0, "non-finite position -> nothing")


func test_food_bits_do_not_draw_from_the_world_rng() -> void:
	# Bits use a golden-angle ring, no RNG draw: a world that spawned and removed bits keeps the same rng state as one
	# that did not, so the only hash difference is the id counter. Compare after aligning next_id by spawning NPC-free ids.
	var a: SimWorld = G.rig(43)["w"]
	var b: SimWorld = G.rig(43)["w"]
	var ids: PackedInt32Array = SimDebug.spawn_food_bits(a, S3.ARENA, 8)
	for id: int in ids:
		a.remove_entity(id)
	# b burns the same number of ids with throw-away NPCs that are removed again, no rng involved either
	for i: int in 8:
		b.remove_entity(b.spawn_entity(&"puffer", S3.ARENA, 0.4))
	S3.step_n(a, 30)
	S3.step_n(b, 30)
	assert_eq(a.state_hash(), b.state_hash(), "same rng stream and same id counter: the bits drew no random numbers")


func test_a_player_in_front_of_a_debug_bit_eats_it_for_xp() -> void:
	var rg: Dictionary = G.rig(44)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	p.heading = Vector3.RIGHT
	var xp0: float = p.xp
	var ids: PackedInt32Array = SimDebug.spawn_food_bits(w, p.position + Vector3.RIGHT * (0.4 * p.length_m), 1, 5.0)
	var bit: int = ids[0]
	var t0: int = w.tick
	S3.step_n(w, 6, {bit: w.get_entity(bit).position})
	assert_true(S3.is_gone(w, bit), "the bit in the mouth is swallowed")
	assert_true(S3.count_between(w, SimEvent.Type.EATEN, p.id, bit, t0) >= 1, "EATEN names the eater and the bit")
	assert_true(p.xp > xp0, "XP gained (%.2f -> %.2f)" % [xp0, p.xp])


# ---------------------------------------------------------------- god mode

func _lethal_player(w: SimWorld, id: int) -> SimEntity:
	var p: SimEntity = w.get_entity(id)
	p.hp = 0.0
	return p


func test_without_god_mode_a_player_at_zero_hp_dies() -> void:
	var rg: Dictionary = G.rig(51)
	var w: SimWorld = rg["w"]
	var p: SimEntity = _lethal_player(w, rg["id"])
	S3.step_n(w, 2)
	assert_eq(p.deaths, 1, "control: normal rules kill it")


func test_god_mode_blocks_death_at_zero_hp() -> void:
	var rg: Dictionary = G.rig(52)
	var w: SimWorld = rg["w"]
	SimDebug.set_god(w, true)
	var p: SimEntity = _lethal_player(w, rg["id"])
	var evs: Array[SimEvent] = S3.step_n(w, 5)
	assert_eq(p.deaths, 0, "no death")
	assert_true(p.alive, "alive")
	assert_false(G.has_event(evs, SimEvent.Type.DIED), "no DIED event")
	assert_false(G.has_event(evs, SimEvent.Type.RESPAWNED), "no RESPAWNED event")
	assert_eq(p.hp, p.max_hp, "hp back at the maximum")


func test_god_mode_survives_starvation() -> void:
	var rg: Dictionary = G.rig(53)
	var w: SimWorld = rg["w"]
	SimDebug.set_god(w, true)
	var p: SimEntity = w.get_entity(rg["id"])
	p.hunger = 0.0
	p.hp = 0.01
	S3.step_n(w, 120)
	assert_true(p.alive and p.deaths == 0, "starving with 0.01 hp for 4 s does not kill a god")
	# the refill runs before the vitals phase, so the end of a step sits one tick of starvation below the maximum
	assert_true(p.hp >= p.max_hp * 0.99, "hp refilled (%.4f / %.4f)" % [p.hp, p.max_hp])
	# control without god
	var ctl: Dictionary = G.rig(53)
	var cw: SimWorld = ctl["w"]
	var cp: SimEntity = cw.get_entity(ctl["id"])
	cp.hunger = 0.0
	cp.hp = 0.01
	S3.step_n(cw, 120)
	assert_eq(cp.deaths, 1, "control: the same setup kills a normal player")


func test_god_mode_survives_being_swallowed_by_a_shark() -> void:
	var w: SimWorld = S3.make_world(54)
	SimDebug.set_god(w, true)
	var shark_len: float = 3.0
	var reach: float = shark_len * S3.rule_f(w.content, "mouth_reach_mult")
	var shark: SimEntity = S3.npc_at(w, &"shark", S3.ARENA, shark_len, Vector3.RIGHT)
	var p: SimEntity = S3.player_at(w, S3.ARENA + Vector3.RIGHT * (0.5 * reach), S3.xp_for_length(w.content, 0.2))
	var evs: Array[SimEvent] = S3.step_n(w, 6)
	assert_true(shark.alive, "test setup: the shark is alive")
	assert_true(S3.pair_events(evs, SimEvent.Type.EATEN, shark.id, p.id).size() >= 1, "test setup: the shark did swallow the player (EATEN)")
	assert_true(p.alive and p.deaths == 0, "the god player is not killed by the swallow")
	for ev: SimEvent in evs:
		assert_false(ev.type == SimEvent.Type.DIED and ev.entity_id == p.id, "no DIED event for the player")


func test_god_mode_survives_the_boss_dash() -> void:
	var rg: Dictionary = S6.boss_rig(87, 20.0, S6.mid_xp(S6.make_world(87).content, 1), {"vitals": true})
	if rg.is_empty():
		fail("test setup: no free spot in the abyss zone for the boss")
		return
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.set_god(w, true)
	var evs: Array[SimEvent] = S6.run(w, 240, {p.id: p.position})
	var dashes: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BOSS_DASH:
			dashes += 1
	assert_true(dashes >= 1, "test setup: the boss dashed at the pinned player (%d)" % dashes)
	assert_eq(p.deaths, 0, "a band-1 god player survives the dash that kills a normal band-1 player")
	for ev: SimEvent in evs:
		assert_false(ev.type == SimEvent.Type.DIED and ev.entity_id == p.id, "no DIED event for the player")
	# control: the same rig without god mode loses the player (test_s6_boss: the dash kills below band 4)
	var ctl: Dictionary = S6.boss_rig(87, 20.0, S6.mid_xp(S6.make_world(87).content, 1), {"vitals": true})
	S6.run(ctl["w"], 240, {(ctl["p"] as SimEntity).id: (ctl["p"] as SimEntity).position})
	assert_true((ctl["p"] as SimEntity).deaths >= 1, "control: without god the same dash kills (deaths %d)" % (ctl["p"] as SimEntity).deaths)


func test_god_mode_off_restores_normal_death() -> void:
	var rg: Dictionary = G.rig(55)
	var w: SimWorld = rg["w"]
	SimDebug.set_god(w, true)
	S3.step_n(w, 3)
	SimDebug.set_god(w, false)
	var p: SimEntity = _lethal_player(w, rg["id"])
	S3.step_n(w, 2)
	assert_eq(p.deaths, 1, "after god off a lethal hit kills again")


func test_god_mode_heals_every_player_but_not_npcs() -> void:
	var rg: Dictionary = G.rig(56)
	var w: SimWorld = rg["w"]
	SimDebug.set_god(w, true)
	var npc: SimEntity = S3.npc_at(w, &"puffer", S3.ARENA)
	npc.hp = 0.5
	var p: SimEntity = rg["p"]
	p.hp = 1.0
	S3.step_n(w, 1)
	assert_eq(p.hp, p.max_hp, "player refilled")
	assert_true(npc.hp < npc.max_hp, "NPC hp is not touched by god mode (%.2f / %.2f)" % [npc.hp, npc.max_hp])


# ---------------------------------------------------------------- hunger lock

func test_hunger_drains_without_the_lock() -> void:
	var rg: Dictionary = G.rig(61)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var h0: float = p.hunger
	S3.step_n(w, 60 * 30)
	assert_true(p.hunger < h0 - 1.0, "control: hunger drains over 60 s (%.1f -> %.1f)" % [h0, p.hunger])


func test_hunger_lock_keeps_hunger_at_max_for_a_minute() -> void:
	var rg: Dictionary = G.rig(62)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var hmax: float = S3.rule_f(w.content, "hunger_max")
	SimDebug.set_hunger_lock(w, true)
	p.hunger = hmax * 0.3
	S3.step_n(w, 60 * 30)
	assert_true(p.hunger >= hmax - hmax * 0.01, "hunger at the end of 60 s is within one tick of drain of the max (%.2f / %.2f)" % [p.hunger, hmax])
	assert_true(p.hp > 0.0 and p.deaths == 0, "never starved")


func test_hunger_unlock_resumes_the_drain() -> void:
	var rg: Dictionary = G.rig(63)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.set_hunger_lock(w, true)
	S3.step_n(w, 30)
	SimDebug.set_hunger_lock(w, false)
	var h0: float = p.hunger
	S3.step_n(w, 60 * 30)
	assert_true(p.hunger < h0 - 1.0, "drain resumes after unlock (%.1f -> %.1f)" % [h0, p.hunger])


# ---------------------------------------------------------------- noclip

func test_without_noclip_a_player_cannot_swim_into_the_rock() -> void:
	var rg: Dictionary = G.rig(71)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.teleport(w, p.id, ROCK_CENTRE + Vector3(-8, 0, 0))
	p.heading = Vector3.RIGHT
	p.velocity = Vector3.RIGHT * 6.0
	for i: int in 90:
		w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
		w.step()
	assert_true(p.position.distance_to(ROCK_CENTRE) >= ROCK_R - 0.05, "normal rules: kept out of the rock (%.2f m from centre)" % p.position.distance_to(ROCK_CENTRE))


func test_noclip_teleport_into_a_rock_stays_inside() -> void:
	var rg: Dictionary = G.rig(72)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.set_noclip(w, true)
	assert_true(SimDebug.teleport(w, p.id, ROCK_CENTRE), "teleport")
	assert_true(p.position.distance_to(ROCK_CENTRE) < ROCK_R - 0.5, "noclip: the player sits inside the rock (%.2f m from centre)" % p.position.distance_to(ROCK_CENTRE))


func test_noclip_swims_through_a_rock() -> void:
	var rg: Dictionary = G.rig(73)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.set_noclip(w, true)
	SimDebug.teleport(w, p.id, ROCK_CENTRE + Vector3(-8, 0, 0))
	var passed: bool = false
	for i: int in 150:
		w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
		w.step()
		if p.position.x > ROCK_CENTRE.x + 1.0:
			passed = true
			break
	assert_true(passed, "noclip: swam through the rock (x %.2f, rock centre x %.2f)" % [p.position.x, ROCK_CENTRE.x])


func test_noclip_keeps_the_map_box_and_surface_clamps() -> void:
	var rg: Dictionary = G.rig(74)
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	SimDebug.set_noclip(w, true)
	SimDebug.teleport(w, p.id, Vector3(99999, 99999, 99999))
	var half: float = float(w.map["size_m"]) * 0.5
	assert_true(p.position.x <= half and p.position.z <= half, "box clamp holds: %s" % p.position)
	assert_true(p.position.y <= 0.0, "surface clamp holds: y %.2f" % p.position.y)
	SimDebug.teleport(w, p.id, Vector3(0, -99999, 0))
	var depth: float = float(w.map["depth_m"])
	assert_true(p.position.y >= -depth, "floor of the map box holds: y %.2f (depth %.0f)" % [p.position.y, depth])


func test_noclip_applies_to_players_only() -> void:
	var rg: Dictionary = G.rig(75)
	var w: SimWorld = rg["w"]
	SimDebug.set_noclip(w, true)
	var npc: SimEntity = S3.npc_at(w, &"puffer", S3.ARENA)
	SimDebug.teleport(w, npc.id, ROCK_CENTRE)
	assert_true(npc.position.distance_to(ROCK_CENTRE) >= ROCK_R - 0.01, "an NPC is still pushed out of the rock with noclip on")


# ---------------------------------------------------------------- time scale state

func test_time_scale_is_clamped_and_ignores_non_finite() -> void:
	var w: SimWorld = S3.make_world(1)
	assert_eq(SimDebug.set_time_scale(w, 2.0), 2.0, "2x")
	assert_eq(SimDebug.set_time_scale(w, 100.0), SimDebug.TIME_SCALE_MAX, "clamped to the max")
	assert_eq(SimDebug.set_time_scale(w, 0.0), SimDebug.TIME_SCALE_MIN, "0 clamps to the min (no freeze)")
	assert_eq(SimDebug.set_time_scale(w, -3.0), SimDebug.TIME_SCALE_MIN, "negative clamps to the min")
	SimDebug.set_time_scale(w, 4.0)
	assert_eq(SimDebug.set_time_scale(w, NAN), 4.0, "NaN changes nothing")
	assert_eq(SimDebug.set_time_scale(w, INF), 4.0, "INF changes nothing")


func test_engine_time_scale_is_never_touched_by_the_tools() -> void:
	var before: float = Engine.time_scale
	var w: SimWorld = S3.make_world(1)
	SimDebug.set_time_scale(w, 5.0)
	SimDebug.set_god(w, true)
	SimDebug.set_hunger_lock(w, true)
	SimDebug.set_noclip(w, true)
	assert_eq(Engine.time_scale, before, "Engine.time_scale belongs to FeedbackFx")


# ---------------------------------------------------------------- boss shortcuts

func test_boss_shortcuts_without_a_boss_return_false() -> void:
	var w: SimWorld = G.rig(81)["w"]
	assert_false(SimDebug.boss_stun(w), "stun: no boss")
	assert_false(SimDebug.boss_heal(w), "heal: no boss")
	assert_false(SimDebug.set_boss_hp(w, 5.0), "hp: no boss")


func test_boss_stun_stuns_on_the_next_step_and_heal_refills() -> void:
	var rg: Dictionary = S6.boss_rig(91, 15.0, S6.mid_xp(S6.make_world(91).content, 4))
	if rg.is_empty():
		fail("test setup: no free spot in the abyss zone for the boss")
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = S6.run(w, 20, {boss.id: boss.position, p.id: p.position}, [p.id])
	assert_true(SimDebug.boss_stun(w), "stun accepted")
	assert_eq(boss.hp, 0.0, "hp zeroed at once")
	all.append_array(S6.run(w, 3, {boss.id: boss.position, p.id: p.position}, [p.id]))
	assert_eq(S6.count_named(all, "BOSS_STUNNED"), 1, "BOSS_STUNNED fires once on the next step")
	assert_not_null(w.get_entity(boss.id), "the boss is not killed, it is stunned")
	assert_true(SimDebug.boss_heal(w), "heal accepted")
	assert_eq(boss.hp, boss.max_hp, "hp refilled")


func test_boss_win_ends_the_run_with_one_victory() -> void:
	var rg: Dictionary = G.rig(82)
	var w: SimWorld = rg["w"]
	var t0: int = w.tick
	SimDebug.force_victory(w, rg["id"])
	SimDebug.force_victory(w, rg["id"])  # idempotent
	assert_true(w.run_won, "run won")
	var n: int = 0
	for ev: SimEvent in w.events_since(t0):
		if ev.type == SimEvent.Type.VICTORY:
			n += 1
	assert_eq(n, 1, "exactly one VICTORY event")


# ---------------------------------------------------------------- determinism

func _quiet_hash(world_seed: int, ticks: int, setup: Callable) -> int:
	var w: SimWorld = G.rig(world_seed)["w"]
	setup.call(w)
	for i: int in ticks:
		w.step()
	return w.state_hash()


func _hash_after(world_seed: int, ticks: int, setup: Callable) -> int:
	var rg: Dictionary = G.rig(world_seed, {"real_spawners": true})
	var w: SimWorld = rg["w"]
	setup.call(w)
	for i: int in ticks:
		w.step()
	return w.state_hash()


func test_empty_debug_state_does_not_change_the_hash_over_600_ticks() -> void:
	var plain: int = _hash_after(5, 600, func(_w: SimWorld) -> void: pass)
	var with_state: int = _hash_after(5, 600, func(w: SimWorld) -> void: SimDebug.state(w))
	assert_eq(with_state, plain, "debug == null and debug with every flag off hash identically after 600 ticks")


func test_time_scale_is_not_read_by_the_sim() -> void:
	var plain: int = _hash_after(6, 600, func(_w: SimWorld) -> void: pass)
	var scaled: int = _hash_after(6, 600, func(w: SimWorld) -> void: SimDebug.set_time_scale(w, 3.0))
	assert_eq(scaled, plain, "time_scale only multiplies the frame delta in GameLoop: the sim result per tick is unchanged")


func test_god_mode_in_a_quiet_world_keeps_the_hash() -> void:
	# controlled world (no spawners): nothing hurts the player, so the refill changes nothing hashed
	var plain: int = _quiet_hash(9, 600, func(_w: SimWorld) -> void: pass)
	var god: int = _quiet_hash(9, 600, func(w: SimWorld) -> void: SimDebug.set_god(w, true))
	assert_eq(god, plain, "god mode with no damage leaves the hash identical")


func test_hunger_lock_changes_only_hunger_not_the_rng_stream() -> void:
	# state_hash covers entity hunger, so a locked player hashes differently by design; the random stream must not move
	var a: SimWorld = G.rig(9)["w"]
	var b: SimWorld = G.rig(9)["w"]
	SimDebug.set_hunger_lock(b, true)
	for i: int in 600:
		a.step()
		b.step()
	assert_eq(b.rng.get_state(), a.rng.get_state(), "rng state identical after 600 ticks")
	assert_eq(b.get_entity(b.players()[0].id).position, a.get_entity(a.players()[0].id).position, "positions identical")
	assert_true(b.players()[0].hunger > a.players()[0].hunger, "only hunger differs: locked %.1f vs drained %.1f" % [b.players()[0].hunger, a.players()[0].hunger])


func test_hash_is_unchanged_by_setting_and_clearing_noclip() -> void:
	var plain: int = _hash_after(7, 300, func(_w: SimWorld) -> void: pass)
	var toggled: int = _hash_after(7, 300, func(w: SimWorld) -> void:
		SimDebug.set_noclip(w, true)
		SimDebug.set_noclip(w, false))
	assert_eq(toggled, plain, "noclip off again = the normal rules")


func test_state_hash_does_not_read_the_debug_object() -> void:
	var rg: Dictionary = G.rig(8)
	var w: SimWorld = rg["w"]
	var h0: int = w.state_hash()
	var st: SimDebug.State = SimDebug.state(w)
	st.god = true
	st.noclip = true
	st.hunger_lock = true
	st.time_scale = 7.0
	st.spawned_ids = PackedInt32Array([1, 2, 3])
	assert_eq(w.state_hash(), h0, "flags and spawned ids are not part of the hash")
