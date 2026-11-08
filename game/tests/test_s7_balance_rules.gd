extends TestCase
## S7 balance-pass sim fixes (contract "balance"; review S6 M1-M3, S4 M1). Every number comes from ContentDB:
##  - dash damage: a last-band victim loses dash_damage_frac_of_b4_max_hp x its OWN max HP (a fresh B4 survives one
##    hit), a smaller victim that fraction of the B4 max HP at dash_ref_length_m;
##  - close-range charge: a target hugging the boss inside dash_min_range_m gets a TELL (data.close) after
##    hug_charge_after_s, never before;
##  - stun time-out: an unfinished stun ends after stun_timeout_s with stun_recover_hp_frac of max HP (DISENGAGE,
##    BOSS_DISENGAGED data.recovered), not earlier;
##  - spawn distance: spawner NPCs never appear within rules.spawn.min_player_distance_m of a living player.
## Geometry and pins as in test_s6_boss.gd (S6.boss_rig: boss in the abyss, player `dist` m along +X).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const STATES: Array[String] = ["PATROL", "ENGAGE", "TELL", "DASH", "DISENGAGE", "STUNNED"]


func _rig(world_seed: int, dist: float, xp: float) -> Dictionary:
	var rg: Dictionary = S6.boss_rig(world_seed, dist, xp)
	if rg.is_empty():
		fail("test setup: no free spot in the abyss zone for the boss")
		return {}
	if not (S6.require_api(self, rg["w"]) and S6.require_states(self, STATES)):
		return {}
	return rg


func _last_band(db: ContentDB) -> int:
	return db.band_count()


## The first charge hit on a player with `xp` standing 15 m in front of the (free) boss: {"dmg", "max_hp", "band",
## "hp_after"}; empty when no charge hit within 8 s.
func _first_dash_hit(world_seed: int, xp: float) -> Dictionary:
	var rg: Dictionary = _rig(world_seed, 15.0, xp)
	if rg.is_empty():
		return {}
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	var pins: Dictionary = {p.id: p.position}
	for i in 240:
		p.hp = p.max_hp  # every charge meets a full-HP player (close bites do not add up)
		for ev: SimEvent in S6.run(w, 1, pins):
			if ev.type == SimEvent.Type.BITTEN and ev.entity_id == p.id and bool(ev.data.get("dash", false)):
				return {"dmg": ev.value, "max_hp": p.max_hp, "band": p.band, "hp_after": p.max_hp - ev.value}
	return {}


# ======================================================== dash damage (S6 review M1)

func test_dash_takes_the_fraction_of_the_victims_own_max_hp_in_the_last_band() -> void:
	var db: ContentDB = S6.make_world(701).content
	var frac: float = S6.boss_f(db, "dash_damage_frac_of_b4_max_hp")
	var last: int = _last_band(db)
	for xp: float in [S6.band_xp(db, last), S6.mid_xp(db, last), float(db.get_band(last)["xp_full_length"])]:
		var hit: Dictionary = _first_dash_hit(701, xp)
		assert_false(hit.is_empty(), "test setup: the charge hit a B%d player with %s XP" % [last, str(xp)])
		if hit.is_empty():
			continue
		assert_eq(int(hit["band"]), last, "test setup: the player is in the last band")
		var expect: float = frac * float(hit["max_hp"])
		assert_almost_eq(float(hit["dmg"]), expect, expect * 1e-6, "%s XP: dash = %s x own max HP %s" % [str(xp), str(frac), str(hit["max_hp"])])


func test_a_fresh_last_band_player_survives_one_charge() -> void:
	var db: ContentDB = S6.make_world(702).content
	var hit: Dictionary = _first_dash_hit(702, S6.band_xp(db, _last_band(db)))
	assert_false(hit.is_empty(), "test setup: the charge hit a fresh last-band player")
	if hit.is_empty():
		return
	assert_true(float(hit["hp_after"]) > 0.0, "a fresh B%d player (max HP %s) survives one charge (%s)" % [_last_band(db), str(hit["max_hp"]), str(hit["dmg"])])


func test_below_the_last_band_the_dash_is_the_b4_reference_amount() -> void:
	var db: ContentDB = S6.make_world(703).content
	var last: int = _last_band(db)
	var ref_len: float = S6.boss_f(db, "dash_ref_length_m")
	var expect: float = S6.boss_f(db, "dash_damage_frac_of_b4_max_hp") * S6.player_hp(db, last, ref_len)
	var hit: Dictionary = _first_dash_hit(703, S6.mid_xp(db, last - 1))
	assert_false(hit.is_empty(), "test setup: the charge hit a B%d player" % (last - 1))
	if hit.is_empty():
		return
	assert_almost_eq(float(hit["dmg"]), expect, expect * 1e-6, "B%d: dash = frac x the B%d max HP at dash_ref_length_m" % [last - 1, last])


# ======================================================== close-range charge (S6 review M2)

func test_a_hugging_player_gets_a_close_tell_after_the_hug_time() -> void:
	var db: ContentDB = S6.make_world(704).content
	var hug_s: float = S6.boss_f(db, "hug_charge_after_s")
	assert_true(hug_s > 0.0, "data: boss.hug_charge_after_s is set")
	var min_range: float = S6.boss_f(db, "dash_min_range_m")
	var rg: Dictionary = _rig(704, min_range * 0.4, S6.mid_xp(db, _last_band(db)))
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var evs: Array[SimEvent] = S6.run(w, S3.ticks(hug_s) + 60, {boss.id: boss.position, p.id: p.position}, [p.id])
	var engaged: Array[SimEvent] = S6.events_named(evs, "BOSS_ENGAGED")
	var tells: Array[SimEvent] = S6.events_named(evs, "BOSS_TELL")
	assert_eq(engaged.size(), 1, "test setup: engaged once")
	assert_true(tells.size() >= 1, "a player inside dash_min_range_m (%s m) gets a tell" % str(min_range * 0.4))
	if engaged.size() != 1 or tells.is_empty():
		return
	var waited: int = tells[0].tick - engaged[0].tick
	assert_true(waited >= S3.ticks(hug_s) - 1 and waited <= S3.ticks(hug_s) + 3, "the close tell comes hug_charge_after_s after the hug started (%d ticks, data %d)" % [waited, S3.ticks(hug_s)])
	assert_true(bool(tells[0].data.get("close", false)), "BOSS_TELL data.close marks the close-range charge")


func test_no_close_tell_while_the_player_keeps_leaving_the_min_range() -> void:
	var db: ContentDB = S6.make_world(705).content
	var hug_s: float = S6.boss_f(db, "hug_charge_after_s")
	var min_range: float = S6.boss_f(db, "dash_min_range_m")
	var rg: Dictionary = _rig(705, min_range * 0.4, S6.mid_xp(db, _last_band(db)))
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var close: Vector3 = p.position
	# out of engage and charge range for one tick: the hug ends
	var out: Vector3 = S6.player_pos(rg["spot"], maxf(S6.boss_f(db, "dash_distance_m"), S6.boss_f(db, "engage_radius_m")) + 2.0)
	var pins: Dictionary = {boss.id: boss.position, p.id: close}
	var all: Array[SimEvent] = []
	# hug for just under the hug time, step out for one tick, repeat: the hug timer restarts every time
	for round_i in 3:
		pins[p.id] = close
		all.append_array(S6.run(w, S3.ticks(hug_s) - 5, pins, [p.id]))
		pins[p.id] = out
		all.append_array(S6.run(w, 1, pins, [p.id]))
	var close_tells: int = 0
	for ev: SimEvent in S6.events_named(all, "BOSS_TELL"):
		if bool(ev.data.get("close", false)):
			close_tells += 1
	assert_eq(close_tells, 0, "the hug timer restarts when the player leaves dash_min_range_m")


# ======================================================== stun time-out (S6 review M3)

func test_an_unfinished_stun_times_out_and_the_boss_recovers_some_hp() -> void:
	var db: ContentDB = S6.make_world(706).content
	var timeout_s: float = S6.boss_f(db, "stun_timeout_s")
	var frac: float = S6.boss_f(db, "stun_recover_hp_frac")
	assert_true(timeout_s > 0.0 and frac > 0.0, "data: boss.stun_timeout_s and stun_recover_hp_frac are set")
	var rg: Dictionary = _rig(706, 15.0, float(db.get_band(_last_band(db))["xp_full_length"]))
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var pins: Dictionary = {boss.id: boss.position, p.id: p.position}
	S6.run(w, 5, pins, [p.id])
	assert_true(S6.boss_engaged(w), "test setup: engaged")
	boss.hp = 0.0
	var evs: Array[SimEvent] = S6.run(w, 2, pins, [p.id])
	var stunned: Array[SimEvent] = S6.events_named(evs, "BOSS_STUNNED")
	assert_eq(stunned.size(), 1, "test setup: stunned")
	if stunned.size() != 1:
		return
	var t_stun: int = stunned[0].tick
	var timeout: int = S3.ticks(timeout_s)
	# the player stays 15 m away: no finisher
	S6.run(w, t_stun + timeout - 2 - w.tick, pins, [p.id])
	assert_eq(S6.state_name(boss), "STUNNED", "still STUNNED just before stun_timeout_s")
	var hit: SimEvent = null
	var hp_at: float = -1.0
	for i in 10:
		var step_evs: Array[SimEvent] = S6.run(w, 1, pins, [p.id])
		for ev: SimEvent in S6.events_named(step_evs, "BOSS_DISENGAGED"):
			if bool(ev.data.get("recovered", false)):
				hit = ev
				hp_at = boss.hp
		if hit != null:
			break
	assert_not_null(hit, "BOSS_DISENGAGED (data.recovered) after stun_timeout_s")
	if hit == null:
		return
	assert_true(absi(hit.tick - t_stun - timeout) <= 1, "time-out after %d ticks (data %d)" % [hit.tick - t_stun, timeout])
	assert_almost_eq(hp_at, frac * boss.max_hp, boss.max_hp * 0.01, "recovers with stun_recover_hp_frac x max HP")
	assert_ne(S6.state_name(boss), "STUNNED", "no longer stunned")
	assert_not_null(w.get_entity(boss.id), "the boss is still in the world")


# ======================================================== spawn distance (S4 review M1)

func test_spawner_npcs_keep_the_min_distance_from_living_players() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var min_d: float = S3.rule_f(db, "spawn.min_player_distance_m")
	assert_true(min_d > 0.0, "data: rules.spawn.min_player_distance_m is set")
	var cap: int = int(S3.rule_f(db, "tiers.interactive_cap"))
	var map: Dictionary = db.get_map(S3.MAP_ID)
	# one dense puffer spawner over the whole shallows (where the player spawns) with a 1 s respawn
	map["spawners"] = [{"species_id": "puffer", "zone_id": "shallows", "count": cap, "respawn_s": 1}]
	map["schools"] = []
	(map["plankton"] as Dictionary)["zones"] = []
	db.rules()["npc_scale"] = 1.0
	var w := SimWorld.new(707, db)
	NpcSpawner.set_enabled(w, true)
	var pid: int = w.spawn_player(0)
	var p: SimEntity = w.get_entity(pid)
	var near: Array[String] = []
	var spawned: Array[int] = [0]
	var check := func(evs: Array[SimEvent]) -> void:
		for ev: SimEvent in S6.events_named(evs, "ENTITY_SPAWNED"):
			var n: SimEntity = w.get_entity(ev.entity_id)
			if n == null or n.is_player:
				continue
			spawned[0] += 1
			var d: float = n.position.distance_to(p.position)
			if d < min_d:
				near.append("id %d at %.1f m" % [n.id, d])
	var evs: Array[SimEvent] = S6.run(w, 1)
	check.call(evs)
	assert_true(spawned[0] >= cap, "test setup: the initial population spawned (%d)" % spawned[0])
	# kill the whole population, let it respawn around the player (still at its spawn point)
	for id in w.entity_ids():
		var e: SimEntity = w.get_entity(id)
		if e != null and not e.is_player and e.kind == SimEntity.Kind.CREATURE:
			w.remove_entity(id)
	var before: int = spawned[0]
	evs = S6.run(w, S3.ticks(1.0) + 3, {pid: p.position})
	check.call(evs)
	assert_true(spawned[0] - before >= cap, "test setup: the population respawned (%d)" % (spawned[0] - before))
	assert_true(near.is_empty(), "no spawner NPC within %s m of the player: %s" % [str(min_d), str(near.slice(0, 5))])
