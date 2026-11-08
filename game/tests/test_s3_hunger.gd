extends TestCase
## S3 hunger and health: 0-100 hunger drains from full to empty in 90 s at band multiplier 1 (x band
## hunger_drain_mult), eating restores it in proportion to XP, at 0 hunger health drains 2% of max HP per second,
## health regenerates slowly (regen_hp_frac_per_s) only while hunger is ABOVE 50%.
## The player stands still in mid-water (no NPCs, no spawners). Representative XP per band: B1 50, B2 200, B3 500, B4 900.

const S3 := preload("res://tests/s3_support.gd")
const BAND_XP: Array[float] = [50.0, 200.0, 500.0, 900.0]


func _world() -> SimWorld:
	return S3.make_world(41)


func _player(w: SimWorld, xp: float) -> SimEntity:
	return S3.player_at(w, S3.ARENA, xp, Vector3.RIGHT)


# ======================================================== drain

func test_hunger_drains_from_full_to_empty_in_ninety_seconds_at_band_one() -> void:
	var w: SimWorld = _world()
	assert_almost_eq(float(w.content.get_band(1)["hunger_drain_mult"]), 1.0, 1e-9, "band 1 multiplier is 1")
	var p: SimEntity = _player(w, BAND_XP[0])
	assert_almost_eq(p.hunger, 100.0, 1e-9, "starts full")
	S3.step_n(w, 87 * 30)
	assert_true(p.hunger > 2.0 and p.hunger < 4.5, "after 87 s of 90 s about 3.3 left, got %s" % p.hunger)
	S3.step_n(w, 4 * 30)
	assert_true(p.hunger >= 0.0 and p.hunger <= 1e-9, "empty after 91 s and never negative, got %s" % p.hunger)


func test_drain_rate_scales_with_the_band_multiplier() -> void:
	for bi in 4:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, BAND_XP[bi])
		var mult: float = float(w.content.get_band(p.band)["hunger_drain_mult"])
		S3.step_n(w, 300)
		var drop: float = 100.0 - p.hunger
		var expected: float = 100.0 * 10.0 / 90.0 * mult
		assert_true(absf(drop - expected) <= 0.02 * expected + 0.05, "band %d: 10 s costs %s, expected %s (x%s)" % [p.band, drop, expected, mult])


func test_band_multipliers_make_bigger_fish_hungrier() -> void:
	var prev: float = 0.0
	for bi in range(1, 5):
		var m: float = float(S3.content().get_band(bi)["hunger_drain_mult"])
		assert_true(m >= prev, "hunger_drain_mult must not shrink with the band (band %d: %s)" % [bi, m])
		prev = m


func test_hunger_is_clamped_at_zero() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[2])
	p.hunger = 0.01
	S3.step_n(w, 60, {}, [p.id])
	assert_almost_eq(p.hunger, 0.0, 1e-9, "hunger bottoms out at exactly 0")


# ======================================================== eating restores hunger

func test_swallowing_restores_hunger_in_proportion_to_xp() -> void:
	# [player length, meal species, meal length]; expected hunger gain = species xp x hunger_per_xp; all pairs give full XP.
	var cases: Array = [
		[0.25, &"plankton", 0.02],
		[1.0, &"silver_schooling_fish", 0.08],
		[1.2, &"small_reef_fish", 0.1],
	]
	for c in cases:
		var w: SimWorld = _world()
		c.append(float(w.content.get_species(c[1])["xp"]) * S3.rule_f(w.content, "hunger_per_xp"))
		var p: SimEntity = _player(w, S3.xp_for_length(w.content, float(c[0])))
		p.hunger = 30.0
		var meal: SimEntity = S3.npc_at(w, c[1], p.position + p.heading * (0.5 * S3.reach_m(w, p)), float(c[2]))
		S3.step_n(w, 1, {meal.id: meal.position})
		assert_true(S3.is_gone(w, meal.id), "%s swallowed" % c[1])
		var gain: float = p.hunger - 30.0
		assert_true(gain >= float(c[3]) - 0.3 and gain <= float(c[3]) + 1e-9, "%s: hunger gain %s, expected %s minus one tick of drain" % [c[1], gain, c[3]])


# ======================================================== starvation

func test_starvation_costs_two_percent_of_max_hp_per_second() -> void:
	for bi in 4:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, BAND_XP[bi])
		p.hunger = 0.0
		var frac: float = S3.rule_f(w.content, "starvation_hp_frac_per_s")
		var hp0: float = p.hp
		S3.step_n(w, 60)
		var lost: float = hp0 - p.hp
		var expected: float = frac * p.max_hp * 2.0
		assert_true(absf(lost - expected) <= 0.08 * expected, "band %d: lost %s in 2 s, expected %s (%s of %s per second)" % [p.band, lost, expected, frac, p.max_hp])
		assert_almost_eq(p.hunger, 0.0, 1e-9, "hunger stays at 0")


func test_starvation_kills_after_about_fifty_seconds_and_counts_a_death() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[1])
	p.hunger = 0.0
	S3.step_n(w, 1470)
	assert_true(p.alive and p.deaths == 0, "alive after 49 s of starvation (hp %s of %s)" % [p.hp, p.max_hp])
	assert_true(p.hp > 0.0, "hp still positive")
	S3.step_n(w, 90)
	assert_eq(p.deaths, 1, "dead by starvation after ~52 s")
	assert_eq(S3.events_of(w, SimEvent.Type.DIED).size(), 1, "one DIED event")


func test_no_starvation_while_hunger_is_above_zero() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[2])
	p.hunger = 40.0
	var hp0: float = p.hp
	S3.step_n(w, 60)
	assert_almost_eq(p.hp, hp0, 1e-9, "hunger 40%% (> 0, <= 50%%): neither starving nor regenerating")


# ======================================================== regeneration

func test_health_regenerates_while_hunger_is_above_half() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[2])
	var frac: float = S3.rule_f(w.content, "regen_hp_frac_per_s")
	assert_true(frac > 0.0, "regen_hp_frac_per_s must be positive")
	p.hp = 0.5 * p.max_hp
	var hp0: float = p.hp
	S3.step_n(w, 30)
	var gain: float = p.hp - hp0
	var expected: float = frac * p.max_hp
	assert_true(gain >= 0.9 * expected and gain <= 1.1 * expected, "1 s of regen at full hunger: +%s, expected %s (%s of %s)" % [gain, expected, frac, p.max_hp])


func test_regeneration_never_exceeds_max_hp() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[2])
	p.hp = p.max_hp - 0.1
	S3.step_n(w, 90)
	assert_true(p.hp <= p.max_hp + 1e-9, "hp capped at max_hp (got %s of %s)" % [p.hp, p.max_hp])
	assert_almost_eq(p.hp, p.max_hp, 1e-6, "and the small deficit is healed")


func test_no_regeneration_at_or_below_half_hunger() -> void:
	for h in [40.0, 50.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, BAND_XP[2])
		p.hp = 0.5 * p.max_hp
		p.hunger = float(h)
		var hp0: float = p.hp
		S3.step_n(w, 30)
		assert_almost_eq(p.hp, hp0, 1e-9, "hunger %s%%: no regeneration (the threshold is strictly above 50%%)" % h)


func test_regeneration_starts_just_above_half_hunger() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, BAND_XP[2])
	p.hp = 0.5 * p.max_hp
	p.hunger = 50.5
	var hp0: float = p.hp
	S3.step_n(w, 1)
	assert_true(p.hp > hp0, "hunger 50.5%%: regeneration on (hp %s -> %s)" % [hp0, p.hp])


# ======================================================== NPCs (assumption flagged in the plan)

func test_npcs_neither_starve_nor_drain_hunger_to_death() -> void:
	# GAME_DESIGN section 2 states hunger for the player only. A lone passive NPC with 0 hunger must live 2 minutes.
	var w: SimWorld = _world()
	var fish: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA, 0.15)
	fish.hunger = 0.0
	var evs: Array[SimEvent] = S3.step_n(w, 120 * 30)  # collected while stepping: the log keeps only 300 ticks
	assert_not_null(w.get_entity(fish.id), "the NPC is still in the world after 120 s")
	assert_true(fish.alive, "alive")
	assert_almost_eq(fish.hp, fish.max_hp, 1e-9, "unhurt: no starvation for NPCs")
	assert_eq(S3.of_type(evs, SimEvent.Type.DIED).size(), 0, "no DIED event")
