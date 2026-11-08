extends TestCase
## S3 growth and death: XP -> band/length/max HP every tick, BAND_UP at the thresholds (also through eating),
## death = lose death_xp_loss_frac of XP (band may drop, BAND_DOWN), deaths counter, respawn_delay_s later at the
## nearest player_spawns entry (RESPAWNED), dead player is inert, run_ticks keeps counting.
## Deaths are produced with hp = 0 (the sim must turn HP <= 0 into DIED for the player too).

const S3 := preload("res://tests/s3_support.gd")
const SEED: int = 31


func _world() -> SimWorld:
	return S3.make_world(SEED)


func _player(w: SimWorld, xp: float, pos: Vector3 = S3.ARENA) -> SimEntity:
	return S3.player_at(w, pos, xp, Vector3.RIGHT)


## Kills the player in the next step; returns the tick at which the death happened (event tick).
func _die(w: SimWorld, p: SimEntity) -> int:
	p.hp = 0.0
	var t0: int = w.tick
	w.step()
	return t0


func _respawn_ticks(w: SimWorld) -> int:
	return S3.ticks(S3.rule_f(w.content, "respawn_delay_s"))


# ======================================================== growth follows XP

func test_band_length_and_max_hp_follow_xp_every_tick() -> void:
	for xp in [0.0, 50.0, 99.9, 100.0, 250.0, 299.9, 300.0, 500.0, 699.9, 700.0, 1000.0, 1200.0, 1500.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, 0.0)
		p.xp = float(xp)
		S3.step_n(w, 2)
		var expected_band: int = w.content.band_for_xp(float(xp))
		assert_eq(p.band, expected_band, "band at %s XP" % xp)
		assert_almost_eq(p.length_m, S3.length_ref(w.content, float(xp)), 1e-5, "length at %s XP" % xp)
		assert_almost_eq(p.max_hp, S3.player_max_hp_ref(w.content, p.species_id, expected_band, p.length_m), 1e-9, "player max HP follows rules.player_hp_model at %s XP" % xp)
		assert_true(p.hp <= p.max_hp + 1e-9 and p.hp > 0.0, "hp stays within (0, max_hp] at %s XP" % xp)


func test_band_thresholds_are_one_hundred_three_hundred_seven_hundred() -> void:
	# GAME_DESIGN section 2, through the sim (not just the data file).
	for case in [[99.99, 1], [100.0, 2], [299.99, 2], [300.0, 3], [699.99, 3], [700.0, 4]]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, 0.0)
		p.xp = float(case[0])
		S3.step_n(w, 1)
		assert_eq(p.band, int(case[1]), "band at %s XP" % case[0])


func test_band_up_fires_exactly_once_at_each_threshold() -> void:
	for thr in [100.0, 300.0, 700.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(thr) - 0.5)
		var band0: int = p.band
		S3.step_n(w, 2)
		assert_eq(S3.events_of(w, SimEvent.Type.BAND_UP).size(), 0, "no BAND_UP while below %s XP" % thr)
		p.xp = float(thr) + 0.5
		var t0: int = w.tick
		S3.step_n(w, 10)
		var ups: Array[SimEvent] = S3.events_of(w, SimEvent.Type.BAND_UP, t0)
		assert_eq(ups.size(), 1, "exactly one BAND_UP when crossing %s XP" % thr)
		if ups.size() == 1:
			assert_true(S3.mentions(ups[0], p.id), "BAND_UP names the player")
		assert_eq(p.band, band0 + 1, "band advanced by one")
		var lm: Dictionary = w.content.get_band(p.band)["length_m"]
		assert_true(p.length_m >= float(lm["min"]) - 1e-6, "length is at least the new band minimum")
		assert_almost_eq(p.max_hp, S3.player_max_hp_ref(w.content, p.species_id, p.band, p.length_m), 1e-9, "max HP of the new band / length")
		assert_true(p.hp > 0.0 and p.hp <= p.max_hp + 1e-9, "hp valid after band-up")


func test_eating_across_a_threshold_triggers_band_up() -> void:
	# [xp just below the threshold, species of the meal, meal length]: the meal gives full XP (ratio >= 5%) and 10% fits.
	var cases: Array = [
		[99.5, &"plankton", 0.02, 2],
		[299.0, &"silver_schooling_fish", 0.08, 3],
		[698.0, &"small_reef_fish", 0.19, 4],
	]
	for c in cases:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(c[0]))
		var reach: float = S3.reach_m(w, p)
		var meal: SimEntity = S3.npc_at(w, c[1], p.position + p.heading * (0.5 * reach), float(c[2]))
		var t0: int = w.tick
		S3.step_n(w, 3, {meal.id: meal.position})
		assert_true(S3.is_gone(w, meal.id), "%s is swallowed at %s XP" % [c[1], c[0]])
		assert_eq(S3.events_of(w, SimEvent.Type.BAND_UP, t0).size(), 1, "eating %s at %s XP: one BAND_UP" % [c[1], c[0]])
		assert_eq(p.band, int(c[3]), "now band %s" % c[3])


# ======================================================== death

func test_death_halves_xp_counts_the_death_and_may_drop_a_band() -> void:
	for xp in [1200.0, 700.0, 300.0, 100.0, 50.0, 0.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(xp))
		var band_before: int = p.band
		var loss: float = S3.rule_f(w.content, "death_xp_loss_frac")
		var t0: int = _die(w, p)
		var expected_xp: float = float(xp) * (1.0 - loss)
		var expected_band: int = w.content.band_for_xp(expected_xp)
		assert_almost_eq(p.xp, expected_xp, 1e-6, "XP %s -> %s" % [xp, expected_xp])
		assert_eq(p.deaths, 1, "deaths counter at %s XP" % xp)
		assert_eq(p.band, expected_band, "band after death at %s XP" % xp)
		assert_almost_eq(p.length_m, S3.length_ref(w.content, expected_xp), 1e-5, "the fish shrinks with its XP")
		assert_almost_eq(p.max_hp, S3.player_max_hp_ref(w.content, p.species_id, expected_band, p.length_m), 1e-9, "max HP of the lower band / length")
		assert_eq(S3.events_of(w, SimEvent.Type.DIED, t0).size(), 1, "one DIED event at %s XP" % xp)
		var drops: int = S3.events_of(w, SimEvent.Type.BAND_DOWN, t0).size()
		if expected_band < band_before:
			assert_true(drops >= 1, "BAND_DOWN when %d -> %d (at %s XP)" % [band_before, expected_band, xp])
		else:
			assert_eq(drops, 0, "no BAND_DOWN when the band stays %d (at %s XP)" % [band_before, xp])
		assert_false(p.alive, "the player is dead right after the lethal step")
		var delay: int = _respawn_ticks(w)
		assert_true(p.respawn_tick >= t0 + delay - 2 and p.respawn_tick <= t0 + delay + 3, "respawn_tick %d = death %d + %d ticks (3 s)" % [p.respawn_tick, t0, delay])


func test_the_death_event_describes_the_player() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 500.0)
	var pos0: Vector3 = p.position
	var len0: float = p.length_m
	var t0: int = _die(w, p)
	var died: Array[SimEvent] = S3.events_of(w, SimEvent.Type.DIED, t0)
	assert_eq(died.size(), 1, "one DIED")
	if died.size() == 1:
		assert_true(S3.mentions(died[0], p.id), "names the player")
		assert_eq(String(died[0].data.get("species", "")), "small_reef_fish", "data.species")
		var ev_len: float = float(died[0].data.get("length", -1.0))
		var len_after: float = S3.length_ref(w.content, 250.0)
		assert_true(absf(ev_len - len0) < 1e-5 or absf(ev_len - len_after) < 1e-5, "data.length is the length at death (before %s or after %s shrinking), got %s" % [len0, len_after, ev_len])
		var pos: Variant = died[0].data.get("pos")
		assert_true(pos is Vector3 and (pos as Vector3).distance_to(pos0) < 1.0, "data.pos = where the player died")


func test_player_death_does_not_spawn_food_bits() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 500.0)
	_die(w, p)
	S3.step_n(w, 5)
	assert_eq(S3.food_bits(w).size(), 0, "only NPCs leave remains (the player respawns)")
	assert_not_null(w.get_entity(p.id), "the player entity stays in the world while dead")


func test_a_second_death_halves_again_and_counts_two() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 700.0)
	_die(w, p)
	S3.step_n(w, _respawn_ticks(w) + 10)
	assert_true(p.alive, "respawned")
	assert_almost_eq(p.xp, 350.0, 1e-6, "first death: 700 -> 350")
	var t1: int = _die(w, p)
	assert_almost_eq(p.xp, 175.0, 1e-6, "second death: 350 -> 175")
	assert_eq(p.deaths, 2, "two deaths counted")
	assert_eq(p.band, 2, "B2 at 175 XP")
	assert_true(S3.events_of(w, SimEvent.Type.BAND_DOWN, t1).size() >= 1, "BAND_DOWN 3 -> 2")


func test_dying_while_already_dead_is_not_counted_twice() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 400.0)
	_die(w, p)
	p.hp = 0.0
	S3.step_n(w, 20)
	assert_eq(p.deaths, 1, "still one death")
	assert_almost_eq(p.xp, 200.0, 1e-6, "XP halved once")
	assert_eq(S3.events_of(w, SimEvent.Type.DIED).size(), 1, "one DIED event")


# ======================================================== respawn

func test_respawn_after_three_seconds_at_the_nearest_spawn() -> void:
	var cases: Array = []
	for i in 3:
		cases.append([i, "near spawn %d" % i])
	for c in cases:
		var w: SimWorld = _world()
		var sp: Vector3 = S3.spawn_point(w, int(c[0]))
		var death_pos: Vector3 = sp + Vector3(7.0, -2.0, 15.0)
		var p: SimEntity = _player(w, 400.0, death_pos)
		var t0: int = _die(w, p)
		var delay: int = _respawn_ticks(w)
		S3.step_n(w, delay - 30)  # one second before the end of the delay
		assert_false(p.alive, "%s: still dead before the delay ends" % c[1])
		assert_eq(S3.events_of(w, SimEvent.Type.RESPAWNED, t0).size(), 0, "%s: no RESPAWNED yet" % c[1])
		S3.step_n(w, 60)
		assert_true(p.alive, "%s: alive again after %d ticks" % [c[1], delay + 30])
		assert_eq(p.respawn_tick, -1, "%s: respawn_tick back to -1" % c[1])
		var ups: Array[SimEvent] = S3.events_of(w, SimEvent.Type.RESPAWNED, t0)
		assert_eq(ups.size(), 1, "%s: one RESPAWNED" % c[1])
		if ups.size() == 1:
			assert_true(ups[0].tick >= t0 + delay - 2 and ups[0].tick <= t0 + delay + 4, "%s: RESPAWNED at tick %d (death %d + %d)" % [c[1], ups[0].tick, t0, delay])
		var d_own: float = p.position.distance_to(sp)
		assert_true(d_own < 5.0, "%s: back within 5 m of its spawn (%s m)" % [c[1], d_own])
		for j in 3:
			if j != int(c[0]):
				assert_true(d_own < p.position.distance_to(S3.spawn_point(w, j)), "%s: nearer to spawn %d than to spawn %d" % [c[1], int(c[0]), j])
		assert_almost_eq(p.hp, p.max_hp, 1e-6, "%s: full health after respawn" % c[1])
		assert_eq(p.deaths, 1, "%s: deaths stays 1" % c[1])
		assert_almost_eq(p.xp, 200.0, 1e-6, "%s: XP stays halved" % c[1])


func test_death_far_from_the_shallows_respawns_at_the_nearest_of_the_three_spawns() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 400.0)  # at the arena (x 120): spawn 2 is the nearest
	var best: int = 0
	var best_d: float = INF
	for j in 3:
		var d: float = p.position.distance_to(S3.spawn_point(w, j))
		if d < best_d:
			best_d = d
			best = j
	_die(w, p)
	S3.step_n(w, _respawn_ticks(w) + 20)
	assert_true(p.alive, "respawned")
	assert_true(p.position.distance_to(S3.spawn_point(w, best)) < 5.0, "respawned at spawn %d (nearest to %s), at %s" % [best, S3.ARENA, p.position])


func test_a_respawned_player_has_food_in_the_belly() -> void:
	# Assumption flagged in the plan: a respawn refills hunger above the regen threshold, otherwise a player who
	# starved to death would starve again at once.
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 400.0)
	p.hunger = 0.0
	_die(w, p)
	S3.step_n(w, _respawn_ticks(w) + 10)
	assert_true(p.alive, "respawned")
	assert_true(p.hunger > S3.rule_f(w.content, "regen_min_hunger_frac") * S3.rule_f(w.content, "hunger_max"), "hunger above 50%% after respawn, got %s" % p.hunger)


func test_a_dead_player_ignores_commands_and_cannot_be_hurt() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 450.0)
	var reach_g: float = 1.5 * S3.rule_f(w.content, "mouth_reach_mult")
	var g: SimEntity = S3.npc_at(w, &"grouper", p.position - Vector3.RIGHT * (0.5 * reach_g), 1.5, Vector3.RIGHT)
	var t0: int = _die(w, p)
	var pos_dead: Vector3 = p.position
	var hunger_dead: float = p.hunger
	for i in 45:
		w.submit(SimCommand.move(p.id, Vector3.UP, 1.0))
		w.submit(SimCommand.bite(g.id, p.id))
		S3.step_n(w, 1, {g.id: g.position})
	assert_false(p.alive, "still dead after 1.5 s")
	assert_true(p.position.distance_to(pos_dead) < 1e-6, "MOVE is ignored while dead")
	assert_almost_eq(p.hunger, hunger_dead, 1e-9, "hunger does not drain while dead")
	assert_eq(S3.count_between(w, SimEvent.Type.BITTEN, g.id, p.id, t0 + 1), 0, "a dead player cannot be bitten")
	assert_eq(p.deaths, 1, "and cannot die again")


# ======================================================== run timer

func test_run_ticks_keeps_counting_through_death_and_respawn() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 400.0)
	S3.step_n(w, 10)
	var r0: int = w.run_ticks
	assert_true(r0 > 0, "run timer runs (got %d after 10 ticks)" % r0)
	_die(w, p)
	S3.step_n(w, _respawn_ticks(w) + 60)
	var steps: int = 1 + _respawn_ticks(w) + 60
	assert_eq(w.run_ticks - r0, steps, "run_ticks advanced by exactly the number of steps, across death and respawn")
	assert_true(p.alive, "respawned meanwhile")


# ======================================================== eaten by a bigger fish (flagged assumption)

func test_a_player_swallowed_by_a_big_predator_dies_and_loses_half_the_xp() -> void:
	# Assumption flagged in the plan: an NPC that swallows the player kills it (same death path as HP 0).
	var w: SimWorld = _world()
	var shark_len: float = 3.0
	var reach_s: float = shark_len * S3.rule_f(w.content, "mouth_reach_mult")
	var xp: float = S3.xp_for_length(w.content, 0.2)
	var shark: SimEntity = S3.npc_at(w, &"shark", S3.ARENA, shark_len, Vector3.RIGHT)
	var p: SimEntity = _player(w, xp, S3.ARENA + Vector3.RIGHT * (0.5 * reach_s))
	assert_true(p.length_m <= shark_len * S3.rule_f(w.content, "swallow_ratio"), "precondition: the player fits in the shark's mouth")
	var t0: int = w.tick
	S3.step_n(w, 3)
	assert_true(S3.count_between(w, SimEvent.Type.EATEN, shark.id, p.id, t0) >= 1, "the shark swallows the player")
	assert_eq(p.deaths, 1, "that is a death")
	assert_almost_eq(p.xp, xp * 0.5, 1e-6, "with the normal XP loss")
	assert_false(p.alive, "and a respawn timer")
