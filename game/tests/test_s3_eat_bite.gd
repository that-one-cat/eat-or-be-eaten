extends TestCase
## S3 eat / bite resolution inside SimWorld.step(): auto-swallow in the mouth cone, BITE command (cooldown, damage
## formula, target selection), kills. The player is placed in mid-water (S3.ARENA) facing +X; targets are spawned
## at exact offsets in front of / behind / beside the mouth. Inert targets are pinned (S3.step_n) so only the rules
## under test act. Victims that must survive are 6x the player's length: bigger than 10% (never swallowed by
## anyone) and with 36x the player's damage worth of HP.
## Geometry assumption (documented in the plan): the mouth cone starts at the eater's position, points along its
## heading, reach = length * rules.mouth_reach_mult, half-angle = rules.mouth_cone_deg.

const S3 := preload("res://tests/s3_support.gd")
const SEED: int = 11


func _world() -> SimWorld:
	return S3.make_world(SEED)


func _player(w: SimWorld, length_m: float) -> SimEntity:
	return S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


## Point straight ahead of `p` at `frac` of its mouth reach.
func _ahead(w: SimWorld, p: SimEntity, frac: float) -> Vector3:
	return p.position + p.heading * (S3.reach_m(w, p) * frac)


## Passive, 6x longer than the player, in the mouth cone.
func _victim(w: SimWorld, p: SimEntity, frac: float = 0.5) -> SimEntity:
	return S3.npc_at(w, &"small_reef_fish", _ahead(w, p, frac), p.length_m * 6.0, -p.heading)


func _falloff(w: SimWorld) -> Dictionary:
	return w.content.rules()["xp_falloff"]


# ======================================================== setup guard

func test_setup_arena_is_free_and_inside_the_expected_zones() -> void:
	var w: SimWorld = _world()
	assert_true(w.content.is_valid(), "real data must be valid: %s" % [w.content.errors])
	var open_water: Array[Vector3] = S3.zone_box(w, "open_water")
	var arches: Array[Vector3] = S3.zone_box(w, "rock_arches")
	assert_eq(open_water.size(), 2, "zone open_water exists")
	assert_eq(arches.size(), 2, "zone rock_arches exists")
	if open_water.size() == 2 and arches.size() == 2:
		assert_true(S3.inside_box(S3.ARENA, open_water[0], open_water[1]), "arena inside open_water")
		assert_true(S3.inside_box(S3.ARENA, arches[0], arches[1]), "arena inside rock_arches")
	var dx: float = -40.0
	while dx <= 40.0:
		var dz: float = -40.0
		while dz <= 40.0:
			var p: Vector3 = S3.ARENA + Vector3(dx, 0.0, dz)
			assert_true(w.seabed.height_at(p.x, p.z) < p.y - 10.0, "seabed at least 10 m below the arena plane at %s" % p)
			assert_true(w.seabed.resolve(p, 3.0).distance_to(p) < 1e-6, "no obstacle within 3 m of %s" % p)
			dz += 10.0
		dx += 10.0


func test_world_has_the_shared_grid_and_no_npcs_without_spawners() -> void:
	var w: SimWorld = _world()
	assert_not_null(w.grid, "SimWorld.grid exists (hard rule 7: one uniform grid)")
	assert_true(w.grid is SpatialGrid, "grid is a SpatialGrid")
	assert_almost_eq(w.grid.cell_size, S3.rule_f(w.content, "grid_cell_m"), 1e-9, "grid cell size comes from rules.grid_cell_m")
	assert_true(w.grid.cell_size > 0.0, "positive cell size")
	S3.step_n(w, 5)
	assert_eq(w.entity_count(), 0, "emptied spawners spawn nothing (test isolation)")


# ======================================================== swallow: geometry

func test_swallows_an_eligible_target_in_front_of_the_mouth() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 1.0)
	p.hunger = 50.0
	var xp0: float = p.xp
	var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _ahead(w, p, 0.5), 0.08)
	assert_true(t.length_m / p.length_m >= float(_falloff(w)["full_at_ratio"]), "precondition: no falloff for this pair")
	var t0: int = w.tick
	S3.step_n(w, 2, {t.id: t.position})
	assert_true(S3.is_gone(w, t.id), "the silver fish is swallowed")
	assert_eq(S3.count_between(w, SimEvent.Type.EATEN, p.id, t.id, t0), 1, "exactly one EATEN event for the pair")
	assert_almost_eq(p.xp - xp0, float(w.content.get_species(&"silver_schooling_fish")["xp"]), 1e-6, "full species XP")
	var dh: float = p.hunger - 50.0
	var gain: float = float(w.content.get_species(&"silver_schooling_fish")["xp"]) * S3.rule_f(w.content, "hunger_per_xp")
	assert_true(dh > gain - 0.5 and dh <= gain + 1e-9, "hunger +%s (xp x hunger_per_xp) minus two ticks of drain, got %s" % [gain, dh])
	assert_false(w.grid.has(t.id), "the swallowed creature leaves the grid")


func test_does_not_swallow_a_target_behind_the_mouth() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 1.0)
	var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", p.position - p.heading * (S3.reach_m(w, p) * 0.5), 0.08)
	var xp0: float = p.xp
	var t0: int = w.tick
	S3.step_n(w, 30, {t.id: t.position})
	assert_false(S3.is_gone(w, t.id), "a fish behind the eater is not swallowed")
	assert_eq(S3.events_of(w, SimEvent.Type.EATEN, t0).size(), 0, "no EATEN event")
	assert_almost_eq(p.xp, xp0, 1e-9, "no XP")


func test_does_not_swallow_a_target_out_of_reach() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 1.0)
	var far: float = S3.reach_m(w, p) * 1.5 + 1.0
	var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", p.position + p.heading * far, 0.08)
	var t0: int = w.tick
	S3.step_n(w, 30, {t.id: t.position})
	assert_false(S3.is_gone(w, t.id), "a fish %s m ahead (reach %s) is not swallowed" % [far, S3.reach_m(w, p)])
	assert_eq(S3.events_of(w, SimEvent.Type.EATEN, t0).size(), 0, "no EATEN event")


func test_mouth_cone_half_angle_is_respected_for_yaw_and_pitch_offsets() -> void:
	var half: float = S3.half_cone_deg(_world())
	assert_true(half > 12.0 and half < 165.0, "rules.mouth_cone_deg must be a sensible half-angle, got %s" % half)
	if not (half > 12.0 and half < 165.0):
		return
	for axis_name in ["yaw", "pitch"]:
		var axis: Vector3 = Vector3.UP if axis_name == "yaw" else Vector3.FORWARD
		for inside in [true, false]:
			var w: SimWorld = _world()
			var p: SimEntity = _player(w, 1.0)
			var deg: float = half - 10.0 if inside else half + 10.0
			var dir: Vector3 = p.heading.rotated(axis, deg_to_rad(deg))
			var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", p.position + dir * (S3.reach_m(w, p) * 0.5), 0.08)
			S3.step_n(w, 3, {t.id: t.position})
			assert_eq(S3.is_gone(w, t.id), inside, "%s offset %s deg (half-angle %s): swallowed must be %s" % [axis_name, deg, half, inside])


# ======================================================== swallow: eligibility

func test_swallow_limit_in_the_world_is_ten_percent_of_the_eater_length() -> void:
	var ratio: float = S3.rule_f(_world().content, "swallow_ratio")
	for factor in [0.98, 1.02]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, 1.0)
		var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _ahead(w, p, 0.5), p.length_m * ratio * float(factor))
		S3.step_n(w, 20, {t.id: t.position})
		assert_eq(S3.is_gone(w, t.id), float(factor) < 1.0, "target at %s x the 10%% limit: swallowed must be %s" % [factor, float(factor) < 1.0])


func test_a_target_over_the_limit_in_the_mouth_is_left_alone() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.25)
	var puffer: SimEntity = S3.npc_at(w, &"puffer", _ahead(w, p, 0.5), 0.3, -p.heading)
	var t0: int = w.tick
	S3.step_n(w, 60, {puffer.id: puffer.position})
	assert_false(S3.is_gone(w, puffer.id), "B1 cannot swallow a puffer")
	assert_eq(S3.events_of(w, SimEvent.Type.EATEN, t0).size(), 0, "no EATEN")
	assert_almost_eq(puffer.hp, puffer.max_hp, 1e-9, "and nothing bites it without a BITE command")


func test_b1_swallows_plankton_for_full_xp_and_hunger() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.25)
	p.hunger = 30.0
	var xp0: float = p.xp
	var t: SimEntity = S3.npc_at(w, &"plankton", _ahead(w, p, 0.5), 0.02)
	S3.step_n(w, 1, {t.id: t.position})
	assert_true(S3.is_gone(w, t.id), "plankton swallowed")
	assert_almost_eq(p.xp - xp0, 1.0, 1e-6, "plankton XP 1, no falloff for a 0.25 m eater")
	var dh: float = p.hunger - 30.0
	var gain: float = S3.rule_f(w.content, "hunger_per_xp")
	assert_true(dh > gain - 0.2 and dh <= gain + 1e-9, "hunger +%s (1 xp x hunger_per_xp) minus one tick of drain, got %s" % [gain, dh])


func test_swallow_xp_follows_the_falloff_curve() -> void:
	for length_m in [1.0, 3.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(length_m))
		var t: SimEntity = S3.npc_at(w, &"plankton", _ahead(w, p, 0.5), 0.015)
		var expected: float = SimRules.xp_gain(float(w.content.get_species(&"plankton")["xp"]), p.length_m, 0.015, _falloff(w))
		assert_true(expected < 0.9, "precondition: falloff applies for a %s m eater (expected %s)" % [length_m, expected])
		var xp0: float = p.xp
		S3.step_n(w, 1, {t.id: t.position})
		assert_true(S3.is_gone(w, t.id), "swallowed")
		assert_almost_eq(p.xp - xp0, expected, 1e-6, "XP for a %s m eater equals SimRules.xp_gain" % length_m)


func test_swallowing_never_pushes_hunger_above_the_maximum() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 1.0)
	p.hunger = 99.9
	var t: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _ahead(w, p, 0.5), 0.08)
	S3.step_n(w, 2, {t.id: t.position})
	assert_true(S3.is_gone(w, t.id), "swallowed")
	assert_true(p.hunger <= S3.rule_f(w.content, "hunger_max") + 1e-9, "hunger capped at hunger_max, got %s" % p.hunger)
	assert_true(p.hunger > 99.0, "and it is (almost) full")


# ======================================================== bite: damage and geometry

func test_bite_damage_follows_the_band_formula_in_every_band() -> void:
	for length_m in [0.15, 0.5, 1.2, 3.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(length_m))
		var v: SimEntity = _victim(w, p)
		assert_almost_eq(v.max_hp, 100.0 * v.length_m * v.length_m, 1e-6, "victim HP = base_hp x length^2")
		w.submit(SimCommand.bite(p.id, v.id))
		var t0: int = w.tick
		S3.step_n(w, 1, {v.id: v.position})
		var evs: Array[SimEvent] = S3.events_of(w, SimEvent.Type.BITTEN, t0)
		assert_eq(evs.size(), 1, "one BITTEN event at %s m" % length_m)
		if evs.size() != 1:
			continue
		var power: float = float(w.content.get_band(p.band)["bite_power"])
		var expected: float = power * p.length_m * p.length_m
		assert_almost_eq(evs[0].value, expected, 1e-6, "event value = bite_power x length^2 at %s m (band %d)" % [length_m, p.band])
		assert_almost_eq(v.max_hp - v.hp, expected, 1e-6, "victim lost exactly that much")
		assert_true(S3.involves(evs[0], p.id, v.id), "event names both creatures")


# A player bite uses the F1 bite cone (S3.bite_reach_m / bite_half_cone_deg), wider than the mouth cone.
func test_bite_needs_the_target_in_the_cone_and_in_reach() -> void:
	var cases: Array[String] = ["behind", "out_of_reach", "beside"]
	for c in cases:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, 0.5)
		var pos: Vector3
		match c:
			"behind":
				pos = p.position - p.heading * (S3.bite_reach_m(w, p) * 0.5)
			"out_of_reach":
				pos = p.position + p.heading * (S3.bite_reach_m(w, p) * 1.5 + 1.0)
			_:
				pos = p.position + p.heading.rotated(Vector3.UP, deg_to_rad(S3.bite_half_cone_deg(w) + 15.0)) * (S3.bite_reach_m(w, p) * 0.5)
		var v: SimEntity = S3.npc_at(w, &"small_reef_fish", pos, p.length_m * 6.0, -p.heading)
		w.submit(SimCommand.bite(p.id, v.id))
		var t0: int = w.tick
		S3.step_n(w, 5, {v.id: v.position})
		assert_eq(S3.events_of(w, SimEvent.Type.BITTEN, t0).size(), 0, "%s: an explicit BITTEN target outside the cone/reach is not hit" % c)
		assert_almost_eq(v.hp, v.max_hp, 1e-9, "%s: untouched" % c)


func test_bite_with_nothing_in_the_cone_does_nothing() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.5)
	w.submit(SimCommand.bite(p.id, -1))
	var t0: int = w.tick
	S3.step_n(w, 5)
	assert_eq(S3.events_of(w, SimEvent.Type.BITTEN, t0).size(), 0, "no BITTEN")
	assert_almost_eq(p.hp, p.max_hp, 1e-9, "no self-damage")


func test_bite_with_invalid_targets_is_ignored() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = _victim(w, p)
	w.submit(SimCommand.bite(p.id, 9999))
	w.submit(SimCommand.bite(p.id, p.id))
	var t0: int = w.tick
	S3.step_n(w, 5, {v.id: v.position})
	assert_eq(S3.events_of(w, SimEvent.Type.BITTEN, t0).size(), 0, "unknown id and self are ignored")
	assert_almost_eq(p.hp, p.max_hp, 1e-9, "the biter is unharmed")
	assert_almost_eq(v.hp, v.max_hp, 1e-9, "the bystander is untouched")


func test_bite_with_target_minus_one_picks_the_nearest_valid_creature() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.5)
	var near_v: SimEntity = S3.npc_at(w, &"small_reef_fish", _ahead(w, p, 0.35), p.length_m * 6.0, -p.heading)
	var far_v: SimEntity = S3.npc_at(w, &"small_reef_fish", _ahead(w, p, 0.8), p.length_m * 6.0, -p.heading)
	var pins: Dictionary = {near_v.id: near_v.position, far_v.id: far_v.position}
	w.submit(SimCommand.bite(p.id, -1))
	var t0: int = w.tick
	S3.step_n(w, 1, pins)
	var evs: Array[SimEvent] = S3.events_of(w, SimEvent.Type.BITTEN, t0)
	assert_eq(evs.size(), 1, "one bite")
	assert_true(near_v.hp < near_v.max_hp, "the nearer creature was bitten")
	assert_almost_eq(far_v.hp, far_v.max_hp, 1e-9, "the farther one was not")
	if evs.size() == 1:
		assert_true(S3.involves(evs[0], p.id, near_v.id), "event names the nearer victim")


func test_bite_with_target_minus_one_ignores_creatures_behind() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.5)
	var behind: SimEntity = S3.npc_at(w, &"small_reef_fish", p.position - p.heading * (S3.reach_m(w, p) * 0.2), p.length_m * 6.0, p.heading)
	var front: SimEntity = S3.npc_at(w, &"small_reef_fish", _ahead(w, p, 0.7), p.length_m * 6.0, -p.heading)
	var pins: Dictionary = {behind.id: behind.position, front.id: front.position}
	w.submit(SimCommand.bite(p.id, -1))
	S3.step_n(w, 1, pins)
	assert_almost_eq(behind.hp, behind.max_hp, 1e-9, "the nearer creature BEHIND the mouth is not a valid target")
	assert_true(front.hp < front.max_hp, "the one in the cone is bitten")


func test_bite_with_target_minus_one_skips_swallowable_creatures() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 1.0)
	var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _ahead(w, p, 0.2), 0.08)
	var victim: SimEntity = S3.npc_at(w, &"small_reef_fish", _ahead(w, p, 0.7), 6.0, -p.heading)
	var pins: Dictionary = {snack.id: snack.position, victim.id: victim.position}
	w.submit(SimCommand.bite(p.id, -1))
	var t0: int = w.tick
	S3.step_n(w, 2, pins)
	assert_true(S3.is_gone(w, snack.id), "the swallowable creature is simply eaten")
	assert_true(victim.hp < victim.max_hp, "and the bite goes to the non-swallowable one")
	assert_eq(S3.count_between(w, SimEvent.Type.BITTEN, p.id, snack.id, t0), 0, "never a BITTEN event for a swallowed fish")


# ======================================================== bite: cooldown

func test_bite_cooldown_limits_the_bite_rate() -> void:
	var w: SimWorld = _world()
	var cd_ticks: float = S3.rule_f(w.content, "bite_cooldown_s") * 30.0
	assert_true(cd_ticks >= 1.0, "rules.bite_cooldown_s must be positive (got %s ticks)" % cd_ticks)
	if cd_ticks < 1.0:
		return
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = _victim(w, p)
	var t0: int = w.tick
	for i in 150:
		w.submit(SimCommand.bite(p.id, v.id))
		S3.step_n(w, 1, {v.id: v.position})
	var evs: Array[SimEvent] = S3.events_of(w, SimEvent.Type.BITTEN, t0)
	assert_true(evs.size() >= 1, "at least the first bite lands")
	if evs.is_empty():
		return
	assert_eq(evs[0].tick, t0, "the first bite is immediate (the cooldown starts ready)")
	var expected: int = int(ceil(150.0 / cd_ticks))
	assert_true(absi(evs.size() - expected) <= 1, "5 s of held bite = about %d bites at %s ticks cooldown, got %d" % [expected, cd_ticks, evs.size()])
	for i in range(1, evs.size()):
		assert_true(float(evs[i].tick - evs[i - 1].tick) >= cd_ticks - 1.0, "bites %d and %d are %d ticks apart (cooldown %s)" % [i - 1, i, evs[i].tick - evs[i - 1].tick, cd_ticks])
	assert_true(float(p.bite_ready_tick - evs[evs.size() - 1].tick) >= cd_ticks - 1.0, "bite_ready_tick is set cooldown ticks after the last bite")


# ======================================================== kills

func test_same_size_creature_dies_in_about_four_bites_in_the_world() -> void:
	for length_m in [0.15, 0.5, 1.2, 3.0]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, float(length_m))
		var v: SimEntity = S3.npc_at(w, &"small_reef_fish", _ahead(w, p, 0.5), p.length_m, -p.heading)
		var t0: int = w.tick
		var died: bool = false
		for i in 900:
			w.submit(SimCommand.bite(p.id, v.id))
			S3.step_n(w, 1, {v.id: v.position}, [p.id])
			if S3.is_gone(w, v.id):
				died = true
				break
		assert_true(died, "a same-size creature dies to repeated bites (%s m)" % length_m)
		var bites: int = S3.events_of(w, SimEvent.Type.BITTEN, t0).size()
		assert_true(bites >= 3 and bites <= 5, "GAME_DESIGN: about 4 bites for a same-size creature, got %d at %s m" % [bites, length_m])
		assert_eq(S3.events_of(w, SimEvent.Type.DIED, t0).size(), 1, "exactly one DIED event")


func test_lethal_bite_emits_died_with_species_length_and_position() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = _victim(w, p)
	v.hp = 0.001
	var xp0: float = p.xp
	w.submit(SimCommand.bite(p.id, v.id))
	var t0: int = w.tick
	S3.step_n(w, 1, {v.id: v.position})
	var died: Array[SimEvent] = S3.events_of(w, SimEvent.Type.DIED, t0)
	assert_eq(died.size(), 1, "one DIED event")
	assert_eq(S3.events_of(w, SimEvent.Type.BITTEN, t0).size(), 1, "and the lethal bite is reported as BITTEN")
	if died.size() == 1:
		var ev: SimEvent = died[0]
		assert_true(S3.mentions(ev, v.id), "DIED names the dead creature")
		assert_eq(String(ev.data.get("species", "")), "small_reef_fish", "data.species")
		assert_almost_eq(float(ev.data.get("length", -1.0)), v.length_m, 1e-6, "data.length")
		var pos: Variant = ev.data.get("pos")
		assert_true(pos is Vector3, "data.pos is a Vector3")
		if pos is Vector3:
			assert_true((pos as Vector3).distance_to(v.position) < 1.0, "data.pos is where the creature died")
	assert_true(S3.is_gone(w, v.id), "the creature is gone")
	assert_false(w.grid.has(v.id), "and out of the grid")
	assert_almost_eq(p.xp, xp0, 1e-9, "the killer gets XP only by eating the remains, not at the kill")


func test_npc_bite_uses_the_same_formula_against_the_player() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, 3.0), Vector3.RIGHT)
	var grouper_len: float = 1.5
	var reach_g: float = grouper_len * S3.rule_f(w.content, "mouth_reach_mult")
	var g: SimEntity = S3.npc_at(w, &"grouper", p.position - Vector3.RIGHT * (0.5 * reach_g), grouper_len, Vector3.RIGHT)
	p.hunger = S3.NPC_HUNGER_FRAC * 100.0  # below the regen threshold: the hp delta is exactly the bite
	var hp0: float = p.hp
	w.submit(SimCommand.bite(g.id, p.id))
	var t0: int = w.tick
	S3.step_n(w, 1, {g.id: g.position})
	var evs: Array[SimEvent] = S3.events_of(w, SimEvent.Type.BITTEN, t0)
	assert_eq(evs.size(), 1, "one bite")
	var power: float = float(w.content.get_band(S3.band_for_length(w.content, grouper_len))["bite_power"])
	var expected: float = power * grouper_len * grouper_len * float(w.content.get_species(&"grouper")["bite_mult"])
	assert_almost_eq(hp0 - p.hp, expected, 1e-6, "grouper (1.5 m, band by length, bite_mult 1.5) damages the player by the shared formula")
	if evs.size() == 1:
		assert_almost_eq(evs[0].value, expected, 1e-6, "event value")
		assert_true(S3.involves(evs[0], g.id, p.id), "event names both")
