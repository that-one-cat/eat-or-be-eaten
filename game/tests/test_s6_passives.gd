extends TestCase
## S6 passives (contract "Passives"): every node effect changes exactly the right rule by the data multiplier.
## Method: TWIN worlds, same seed, same scenario; world B's player owns the node(s) under test, world A's does not.
## The assertion is the ratio B/A (or the difference) against the multiplier read from ContentDB, so the tests do not
## depend on how the base rule is computed. A baseline check against the S3 formula keeps the scenario honest.
## Nodes are granted by writing player.mutations (S6.give); the sim must derive the effects from that list at use
## time (assumption A3). test_bite_power_through_the_real_pick_path covers the pick path end to end.

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const BITE_NODE: StringName = &"hunter_bite_power"
const SPEED_NODE: StringName = &"hunter_swim_speed"
const TURBO_NODE: StringName = &"hunter_turbo_boost"
const METABOLISM_NODE: StringName = &"survivor_efficient_metabolism"
const ARMOR_NODE: StringName = &"survivor_armor_scales"
const VISION_NODE: StringName = &"survivor_wide_vision"


func _world_with(nodes: Array, world_seed: int, xp: float, opts: Dictionary = {}) -> Dictionary:
	var r: Dictionary = S6.arena_player(world_seed, xp, opts)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	S6.give(w, p, nodes)
	return {"w": w, "p": p}


# ======================================================== bite power

## Damage of the first bite of a B3 player on a pinned grouper (value of the BITTEN event).
func _first_bite(w: SimWorld, p: SimEntity) -> float:
	var reach: float = S3.reach_m(w, p)
	var t: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (0.5 * reach), 1.5)
	w.submit(SimCommand.bite(p.id, t.id))
	var evs: Array[SimEvent] = S6.run(w, 3, {t.id: t.position})
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.entity_id == t.id and ev.other_id == p.id:
			return ev.value
	return NAN


func test_bite_power_mult_scales_bite_damage() -> void:
	var a: Dictionary = _world_with([], 41, 500.0)
	var b: Dictionary = _world_with([BITE_NODE], 41, 500.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var dmg_a: float = _first_bite(a["w"], a["p"])
	var dmg_b: float = _first_bite(b["w"], b["p"])
	var base: float = S6.normal_bite_damage(db, S3.PLAYER_SPECIES, a["p"].band, a["p"].length_m)
	assert_false(is_nan(dmg_a) or is_nan(dmg_b), "test setup: both bites landed")
	assert_almost_eq(dmg_a, base, base * 1e-6, "baseline bite = band bite_power x length^2 x species mult")
	var mult: float = S6.effect_f(db, BITE_NODE, "bite_power_mult")
	assert_false(is_nan(mult), "data: hunter_bite_power has effects.bite_power_mult")
	assert_almost_eq(dmg_b / dmg_a, mult, 1e-6, "bite damage x bite_power_mult (%s)" % str(mult))


func test_bite_power_through_the_real_pick_path() -> void:
	var r: Dictionary = S6.arena_player(42, 0.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	S6.level_to(w, p, 2)
	S6.resolve_pick(w, p.id, String(BITE_NODE))
	p.xp = S6.mid_xp(w.content, 3)
	S6.run(w, 2)
	assert_eq(p.band, 3, "test setup: B3")
	var picked: float = _first_bite(w, p)
	var base: float = S6.normal_bite_damage(w.content, S3.PLAYER_SPECIES, p.band, p.length_m)
	var mult: float = S6.effect_f(w.content, BITE_NODE, "bite_power_mult")
	assert_almost_eq(picked, base * mult, base * 1e-6, "a picked Bite Power node scales the bite (no field write involved)")


func test_effects_of_the_same_key_stack_multiplicatively() -> void:
	var db: ContentDB = S6.db_with_nodes([S6.extra_node("hunter_bp_a", {"bite_power_mult": 1.25}), S6.extra_node("hunter_bp_b", {"bite_power_mult": 1.2})])
	assert_not_null(db, "test setup: patched data copy")
	if db == null:
		return
	var db2: ContentDB = S6.db_with_nodes([S6.extra_node("hunter_bp_a", {"bite_power_mult": 1.25}), S6.extra_node("hunter_bp_b", {"bite_power_mult": 1.2})])
	var a: Dictionary = _world_with([], 43, 500.0, {"db": db})
	var b: Dictionary = _world_with(["hunter_bp_a", "hunter_bp_b"], 43, 500.0, {"db": db2})
	if not S6.require_api(self, a["w"]):
		return
	var ratio: float = _first_bite(b["w"], b["p"]) / _first_bite(a["w"], a["p"])
	assert_almost_eq(ratio, 1.25 * 1.2, 1e-6, "1.25 x 1.2 = 1.5 (additive would give 1.45)")


# ======================================================== swim speed, boost

## Speed after `ticks` of full thrust along +X from rest (B2 player), optionally with the boost held.
func _speed_after(w: SimWorld, p: SimEntity, ticks: int, boost: bool) -> float:
	if boost:
		w.submit(SimCommand.boost(p.id, true))
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
	S6.run(w, ticks)
	return p.speed


func test_swim_speed_mult_scales_terminal_speed() -> void:
	var a: Dictionary = _world_with([], 44, 200.0)
	var b: Dictionary = _world_with([SPEED_NODE], 44, 200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var sa: float = _speed_after(a["w"], a["p"], 90, false)
	var sb: float = _speed_after(b["w"], b["p"], 90, false)
	var band_speed: float = float(db.get_band(a["p"].band)["swim_speed_mps"])
	assert_almost_eq(sa, band_speed, band_speed * 0.01, "baseline terminal speed = band swim speed")
	var mult: float = S6.effect_f(db, SPEED_NODE, "swim_speed_mult")
	assert_almost_eq(sb / sa, mult, 0.01, "terminal speed x swim_speed_mult (%s)" % str(mult))


func test_boost_speed_mult_scales_boosted_speed() -> void:
	var a: Dictionary = _world_with([], 45, 200.0)
	var b: Dictionary = _world_with([TURBO_NODE], 45, 200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var sa: float = _speed_after(a["w"], a["p"], 60, true)
	var sb: float = _speed_after(b["w"], b["p"], 60, true)
	var band_speed: float = float(db.get_band(a["p"].band)["swim_speed_mps"])
	var boost_mult: float = S6.ability_f(db, &"boost", "speed_mult", 1.0)
	assert_almost_eq(sa, band_speed * boost_mult, band_speed * boost_mult * 0.01, "baseline boosted speed = band speed x boost speed_mult")
	var mult: float = S6.effect_f(db, TURBO_NODE, "boost_speed_mult")
	assert_almost_eq(sb / sa, mult, 0.02, "boosted speed x boost_speed_mult (%s), assumption A4: applied to the boosted speed as a whole" % str(mult))


func test_boost_duration_mult_divides_stamina_drain() -> void:
	var a: Dictionary = _world_with([], 46, 200.0)
	var b: Dictionary = _world_with([TURBO_NODE], 46, 200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	_speed_after(a["w"], a["p"], 60, true)
	_speed_after(b["w"], b["p"], 60, true)
	var smax: float = S6.ability_f(db, &"boost", "stamina_max")
	var drain: float = S6.ability_f(db, &"boost", "stamina_drain_per_s")
	var used_a: float = smax - a["p"].stamina
	var used_b: float = smax - b["p"].stamina
	assert_almost_eq(used_a, drain * 2.0, 1.0, "baseline: 2 s of boost drains drain_per_s x 2")
	var mult: float = S6.effect_f(db, TURBO_NODE, "boost_duration_mult")
	assert_almost_eq(used_a / used_b, mult, 0.02, "stamina drain / boost_duration_mult (%s): the boost lasts that much longer" % str(mult))


func test_boost_lasts_longer_with_turbo() -> void:
	# The same thing as seen by the player: ticks of boosting until the stamina is gone.
	var a: Dictionary = _world_with([], 47, 200.0)
	var b: Dictionary = _world_with([TURBO_NODE], 47, 200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var ticks_a: int = _boost_ticks(a["w"], a["p"])
	var ticks_b: int = _boost_ticks(b["w"], b["p"])
	var mult: float = S6.effect_f(db, TURBO_NODE, "boost_duration_mult")
	assert_true(ticks_a > 30, "test setup: baseline boost lasts a while (%d ticks)" % ticks_a)
	assert_almost_eq(float(ticks_b) / float(ticks_a), mult, 0.05, "boost duration x %s" % str(mult))


func _boost_ticks(w: SimWorld, p: SimEntity) -> int:
	# thrust 0.02: the boost drains stamina only while thrusting, and the fish hardly moves (stays in the arena)
	w.submit(SimCommand.boost(p.id, true))
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 0.02))
	var n: int = 0
	for i in 900:
		S6.run(w, 1)
		if not p.boosting:
			break
		n += 1
	return n


# ======================================================== hunger, damage taken

func test_hunger_drain_mult_slows_hunger() -> void:
	var a: Dictionary = _world_with([], 48, 200.0, {"vitals": true})
	var b: Dictionary = _world_with([METABOLISM_NODE], 48, 200.0, {"vitals": true})
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var h0: float = a["p"].hunger
	S6.run(a["w"], 300)
	S6.run(b["w"], 300)
	var lost_a: float = h0 - a["p"].hunger
	var lost_b: float = h0 - b["p"].hunger
	var expect_a: float = S3.rule_f(db, "hunger_max") / S3.rule_f(db, "hunger_full_to_empty_s") * float(db.get_band(a["p"].band)["hunger_drain_mult"]) * 10.0
	assert_almost_eq(lost_a, expect_a, expect_a * 0.01, "baseline: hunger_max / full_to_empty_s x band mult x 10 s")
	var mult: float = S6.effect_f(db, METABOLISM_NODE, "hunger_drain_mult")
	assert_almost_eq(lost_b / lost_a, mult, 0.01, "hunger loss x hunger_drain_mult (%s)" % str(mult))


## HP lost by a B4 victim bitten once by a B3 attacker (both players, pinned, victim in front of the attacker).
func _hp_lost_by_victim(w: SimWorld, victim: SimEntity) -> float:
	var attacker: SimEntity = S3.player_at(w, victim.position - Vector3(1.0, 0.0, 0.0), 500.0, Vector3.RIGHT)
	var hp0: float = victim.hp
	w.submit(SimCommand.bite(attacker.id, victim.id))
	S6.run(w, 2, {attacker.id: attacker.position, victim.id: victim.position})
	return hp0 - victim.hp


func test_damage_taken_mult_reduces_bite_damage() -> void:
	var a: Dictionary = _world_with([], 49, 1200.0)
	var b: Dictionary = _world_with([ARMOR_NODE], 49, 1200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var lost_a: float = _hp_lost_by_victim(a["w"], a["p"])
	var lost_b: float = _hp_lost_by_victim(b["w"], b["p"])
	assert_true(lost_a > 0.0, "test setup: the bite landed (lost %s)" % str(lost_a))
	var mult: float = S6.effect_f(db, ARMOR_NODE, "damage_taken_mult")
	assert_almost_eq(lost_b / lost_a, mult, 0.005, "HP lost x damage_taken_mult (%s)" % str(mult))


func test_damage_taken_mult_does_not_touch_the_damage_dealt() -> void:
	# Armor Scales on the ATTACKER must not change what it deals.
	var a: Dictionary = _world_with([], 50, 1200.0)
	var b: Dictionary = _world_with([], 50, 1200.0)
	if not S6.require_api(self, a["w"]):
		return
	var lost_plain: float = _hp_lost_by_victim(a["w"], a["p"])
	var attacker_b: SimEntity = S3.player_at(b["w"], b["p"].position - Vector3(1.0, 0.0, 0.0), 500.0, Vector3.RIGHT)
	S6.give(b["w"], attacker_b, [ARMOR_NODE])
	var hp0: float = b["p"].hp
	b["w"].submit(SimCommand.bite(attacker_b.id, b["p"].id))
	S6.run(b["w"], 2, {attacker_b.id: attacker_b.position, b["p"].id: b["p"].position})
	assert_almost_eq(hp0 - b["p"].hp, lost_plain, lost_plain * 1e-6, "an armored attacker bites for the same damage")


# ======================================================== presence sector

func test_presence_sector_deg_is_stored_for_the_hud() -> void:
	var a: Dictionary = _world_with([], 51, 200.0)
	var b: Dictionary = _world_with([VISION_NODE], 51, 200.0)
	if not S6.require_api(self, a["w"]):
		return
	var db: ContentDB = a["w"].content
	var base: float = S3.rule_f(db, "presence.sector_deg")
	var plain: float = S6.presence_sector_deg(a["p"])
	assert_true(plain == base or plain <= 0.0, "without Wide Vision the stored sector is the rules default (%s) or unset (0), got %s (assumption A5)" % [str(base), str(plain)])
	var wide: float = S6.effect_f(db, VISION_NODE, "presence_sector_deg")
	assert_eq(wide, 360.0, "data: Wide Vision = 360 degrees")
	assert_almost_eq(S6.presence_sector_deg(b["p"]), wide, 1e-6, "player.presence_sector_deg = the node value")


func test_passives_do_not_leak_between_players() -> void:
	# Two players in one world: only the owner gets the multiplier.
	var r: Dictionary = S6.arena_player(52, 500.0)
	var w: SimWorld = r["w"]
	var owner_p: SimEntity = r["p"]
	var other: SimEntity = S3.player_at(w, S3.ARENA + Vector3(0.0, 0.0, 30.0), 500.0)
	if not S6.require_api(self, w):
		return
	S6.give(w, owner_p, [BITE_NODE])
	var d_owner: float = _first_bite(w, owner_p)
	var d_other: float = _first_bite(w, other)
	var mult: float = S6.effect_f(w.content, BITE_NODE, "bite_power_mult")
	assert_almost_eq(d_owner / d_other, mult, 1e-6, "only the owner's bite is scaled")
