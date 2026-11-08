extends TestCase
## S6 boss (GAME_DESIGN section 7, contract "Boss"): the giant shark state machine on the entity
## (patrol -> engage -> tell -> dash -> engage ... -> disengage -> patrol; HP 0 -> stunned -> finisher -> defeated ->
## victory exactly once with run data). Numbers: species giant_shark `boss` block, rules, size bands.
## Geometry: the boss is spawned in the abyss; the player stands `dist` metres along +X facing it. To make timing
## exact the player (and, where a test is about the state machine only, the boss) is pinned to its position every tick
## (S6.run `pins`); player HP is refilled after every step (`keep_alive`) when the test must survive the boss.
## The state enum is found by name in res://scripts/sim/boss_brain.gd (S6.boss_state_enum()).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const STATES: Array[String] = ["PATROL", "ENGAGE", "TELL", "DASH", "STUNNED"]
## Fully grown B4 player: length = band 4 max, HP = base_hp x length^2.
const B4_XP: float = 1200.0
## Deep in B4 even after one death (death_xp_loss_frac 0.5).
const B4_DEEP_XP: float = 3000.0


func _rig(world_seed: int, dist: float, xp: float, opts: Dictionary = {}) -> Dictionary:
	var rg: Dictionary = S6.boss_rig(world_seed, dist, xp, opts)
	if rg.is_empty():
		fail("test setup: no free spot in the abyss zone for the boss")
	return rg


func _ready_to_test(w: SimWorld) -> bool:
	return S6.require_api(self, w) and S6.require_states(self, STATES)


func _radius(w: SimWorld) -> float:
	return S6.boss_f(w.content, "engage_radius_m")


func _windup_ticks(w: SimWorld) -> int:
	return int(round(S6.boss_f(w.content, "dash_windup_s") * float(S6.TICKS_PER_S)))


## Runs until `type_name` shows up or `max_ticks` passed; appends every event to `into`. Returns the event or null.
func _run_until(w: SimWorld, type_name: String, max_ticks: int, pins: Dictionary, keep: Array[int], into: Array[SimEvent]) -> SimEvent:
	for i in max_ticks:
		var evs: Array[SimEvent] = S6.run(w, 1, pins, keep)
		into.append_array(evs)
		var hit: Array[SimEvent] = S6.events_named(evs, type_name)
		if not hit.is_empty():
			return hit[0]
	return null


# ======================================================== patrol

func test_world_without_a_boss_reports_none() -> void:
	var w: SimWorld = S6.make_world(80)
	if not S6.require_api(self, w):
		return
	assert_eq(S6.boss_id(w), -1, "boss_id() is -1 when there is no boss")
	assert_false(S6.boss_engaged(w), "not engaged")


func test_patrols_inside_the_abyss_while_nobody_is_near() -> void:
	var w: SimWorld = S6.make_world(81)
	var spot: Vector3 = S6.abyss_spot(w)
	assert_true(spot.is_finite(), "test setup: abyss spot")
	if not spot.is_finite():
		return
	var boss: SimEntity = S6.boss_at(w, spot)
	if not _ready_to_test(w):
		return
	assert_eq(S6.boss_id(w), boss.id, "boss_id() finds the giant shark")
	var box: Array[Vector3] = S3.zone_box(w, S6.ABYSS)
	var states: Dictionary = {}
	var outside: Array[String] = []
	var far: Array[float] = [0.0]
	var probe := func(_w: SimWorld) -> void:
		states[S6.state_name(boss)] = true
		if w.tick % 30 == 0:
			far[0] = maxf(far[0], boss.position.distance_to(spot))
			if not S3.inside_box(boss.position, box[0], box[1], 5.0):
				outside.append("tick %d at %s" % [w.tick, str(boss.position)])
	var evs: Array[SimEvent] = S6.run(w, 1800, {}, [], probe)
	assert_eq(states.keys(), ["PATROL"], "the boss stays in PATROL for a minute with nobody around, saw %s" % str(states.keys()))
	assert_false(S6.boss_engaged(w), "not engaged")
	for n: String in ["BOSS_ENGAGED", "BOSS_TELL", "BOSS_DASH", "BOSS_DISENGAGED", "BOSS_STUNNED", "BOSS_DEFEATED", "VICTORY"]:
		assert_eq(S6.count_named(evs, n), 0, "no %s while patrolling" % n)
	assert_true(far[0] > 3.0, "it actually patrols: moved %s m from its spawn" % str(far[0]))
	assert_true(outside.is_empty(), "stays in the abyss zone: %s" % str(outside.slice(0, 3)))
	assert_true(boss.alive and boss.hp == boss.max_hp, "untouched")


# ======================================================== engage

func test_engages_inside_the_radius_at_every_band() -> void:
	for band in range(1, 5):
		var probe_world: SimWorld = S6.make_world(82)
		var xp: float = S6.mid_xp(probe_world.content, band)
		var rg: Dictionary = _rig(82, 0.0, xp)
		if rg.is_empty():
			return
		var w: SimWorld = rg["w"]
		var boss: SimEntity = rg["boss"]
		var p: SimEntity = rg["p"]
		if not _ready_to_test(w):
			return
		var d: float = _radius(w) - 5.0
		p.position = S6.player_pos(rg["spot"], d)
		var pins: Dictionary = {boss.id: boss.position, p.id: p.position}
		var evs: Array[SimEvent] = S6.run(w, 15, pins, [p.id])
		assert_true(S6.boss_engaged(w), "B%d player %s m away: engaged" % [band, str(d)])
		var up: Array[SimEvent] = S6.events_named(evs, "BOSS_ENGAGED")
		assert_eq(up.size(), 1, "B%d: exactly one BOSS_ENGAGED" % band)
		if up.size() == 1:
			assert_eq(up[0].entity_id, boss.id, "B%d: the event is about the boss" % band)
		assert_true(["ENGAGE", "TELL"].has(S6.state_name(boss)), "B%d: state is ENGAGE or TELL, got %s" % [band, S6.state_name(boss)])


func test_engage_radius_edges() -> void:
	var radius: float = 0.0
	for edge: Array in [[-1.0, true], [2.0, false]]:
		var rg: Dictionary = _rig(83, 0.0, B4_XP)
		if rg.is_empty():
			return
		var w: SimWorld = rg["w"]
		var boss: SimEntity = rg["boss"]
		var p: SimEntity = rg["p"]
		if not _ready_to_test(w):
			return
		radius = _radius(w)
		var d: float = radius + float(edge[0])
		p.position = S6.player_pos(rg["spot"], d)
		var evs: Array[SimEvent] = S6.run(w, 90, {boss.id: boss.position, p.id: p.position}, [p.id])
		assert_eq(S6.boss_engaged(w), bool(edge[1]), "player at engage_radius_m + (%s) = %s m: engaged = %s" % [str(edge[0]), str(d), str(edge[1])])
		assert_eq(S6.count_named(evs, "BOSS_ENGAGED") > 0, bool(edge[1]), "BOSS_ENGAGED iff inside the radius (%s m)" % str(d))
		if not bool(edge[1]):
			assert_eq(S6.state_name(boss), "PATROL", "outside the radius the boss keeps patrolling")


func test_a_continuous_engagement_emits_one_engaged_event() -> void:
	var rg: Dictionary = _rig(84, 15.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var evs: Array[SimEvent] = S6.run(w, 450, {p.id: p.position}, [p.id])
	assert_eq(S6.count_named(evs, "BOSS_ENGAGED"), 1, "15 s of fighting (several tell/dash cycles) = one BOSS_ENGAGED")
	assert_true(S6.count_named(evs, "BOSS_TELL") >= 1, "test is not vacuous: it attacked")


# ======================================================== tell, dash, bites

func test_tell_lasts_the_windup_and_fair_damage_comes_after_it() -> void:
	var rg: Dictionary = _rig(85, 15.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var rows: Array = []  # [step tick, state after the step, hp lost in that step]
	var probe := func(_w: SimWorld) -> void:
		rows.append([w.tick - 1, S6.state_name(boss), p.max_hp - p.hp])
	var evs: Array[SimEvent] = S6.run(w, 240, {p.id: p.position}, [p.id], probe)
	var engaged: Array[SimEvent] = S6.events_named(evs, "BOSS_ENGAGED")
	var tells: Array[SimEvent] = S6.events_named(evs, "BOSS_TELL")
	var dashes: Array[SimEvent] = S6.events_named(evs, "BOSS_DASH")
	assert_true(tells.size() >= 1 and dashes.size() >= 1, "test setup: a tell and a dash happened (%d, %d)" % [tells.size(), dashes.size()])
	if tells.is_empty() or dashes.is_empty():
		return
	var wind: int = _windup_ticks(w)
	assert_true(engaged[0].tick <= tells[0].tick, "engage comes before the tell")
	assert_true(absi((dashes[0].tick - tells[0].tick) - wind) <= 3, "TELL -> DASH takes dash_windup_s (%d ticks +-3), took %d" % [wind, dashes[0].tick - tells[0].tick])
	for row: Array in rows:
		var t: int = int(row[0])
		if t > tells[0].tick and t < dashes[0].tick - 1:
			assert_eq(str(row[1]), "TELL", "state during the wind-up at tick %d" % t)
	var first_hit: int = -1
	for row2: Array in rows:
		if float(row2[2]) > 0.0:
			first_hit = int(row2[0])
			break
	assert_true(first_hit >= tells[0].tick + wind - 3, "no damage before the telegraph has run out (first damage tick %d, tell %d, windup %d)" % [first_hit, tells[0].tick, wind])


## HP lost by a player in the first tick after BOSS_DASH in which it lost any (hit by the charge).
func _dash_damage(world_seed: int, xp: float) -> float:
	var rg: Dictionary = _rig(world_seed, 15.0, xp)
	if rg.is_empty():
		return NAN
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return NAN
	var drops: Array = []  # [tick, lost]
	var probe := func(_w: SimWorld) -> void:
		if p.hp < p.max_hp:
			drops.append([w.tick - 1, p.max_hp - p.hp])
	var evs: Array[SimEvent] = S6.run(w, 240, {p.id: p.position}, [p.id], probe)
	var dashes: Array[SimEvent] = S6.events_named(evs, "BOSS_DASH")
	if dashes.is_empty():
		return NAN
	for d: Array in drops:
		if int(d[0]) >= dashes[0].tick:
			return float(d[1])
	return NAN


func test_dash_damage_is_the_fraction_of_b4_max_hp() -> void:
	var w0: SimWorld = S6.make_world(86)
	var db: ContentDB = w0.content
	var frac: float = S6.boss_f(db, "dash_damage_frac_of_b4_max_hp")
	var b4_len: float = float((db.get_band(4)["length_m"] as Dictionary)["max"])
	var expect: float = frac * S6.player_hp(db, 4, b4_len)
	var full: float = _dash_damage(86, B4_XP)
	assert_false(is_nan(full), "test setup: the dash hit a B4 player")
	if is_nan(full):
		return
	assert_almost_eq(full, expect, expect * 0.02, "dash = dash_damage_frac_of_b4_max_hp x max HP of a fully grown B4 player (%s x %s), assumption A9" % [str(frac), str(expect / frac)])
	# S7 (review M1): in B4 the fraction is of the victim's OWN max HP, so a smaller B4 player loses less
	# (test_s7_balance_rules.gd pins the exact amounts)
	var mid: float = _dash_damage(86, 1000.0)
	assert_false(is_nan(mid), "test setup: the dash hit a smaller B4 player")
	if not is_nan(mid):
		var len_mid: float = SimRules.length_for_xp(1000.0, S3.bands(db))
		var expect_mid: float = frac * S6.player_hp(db, 4, len_mid)
		assert_almost_eq(mid, expect_mid, expect_mid * 0.02, "a smaller B4 player loses the fraction of its own max HP")


func test_dash_kills_below_b4() -> void:
	for band in [1, 2]:
		var probe_world: SimWorld = S6.make_world(87)
		var rg: Dictionary = _rig(87, 20.0, S6.mid_xp(probe_world.content, int(band)))
		if rg.is_empty():
			return
		var w: SimWorld = rg["w"]
		var boss: SimEntity = rg["boss"]
		var p: SimEntity = rg["p"]
		if not _ready_to_test(w):
			return
		# the pin puts a respawned player back next to the boss, so later deaths are expected: look at the first
		var evs: Array[SimEvent] = S6.run(w, 240, {p.id: p.position})
		var died: Array[SimEvent] = S6.events_named(evs, "DIED")
		var tells: Array[SimEvent] = S6.events_named(evs, "BOSS_TELL")
		assert_true(died.size() >= 1, "B%d player dies to the boss" % band)
		if died.size() >= 1 and tells.size() >= 1:
			assert_eq(died[0].entity_id, p.id, "B%d: the player died" % band)
			assert_eq(died[0].other_id, boss.id, "B%d: killed by the boss" % band)
			assert_true(died[0].tick >= tells[0].tick + _windup_ticks(w) - 3, "B%d: not before the telegraph ran out" % band)


func test_close_bites_use_the_normal_bite_rules() -> void:
	var rg: Dictionary = _rig(88, 3.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var db: ContentDB = w.content
	var evs: Array[SimEvent] = S6.run(w, 240, {boss.id: boss.position, p.id: p.position}, [p.id])
	var normal: float = S6.normal_bite_damage(db, S6.BOSS, boss.band, boss.length_m)
	var ticks: Array[int] = []
	var matching: int = 0
	for ev: SimEvent in S6.events_named(evs, "BITTEN"):
		# S7: a hugging player also gets the close-range charge (data.dash); that is not a bite
		if ev.entity_id == p.id and ev.other_id == boss.id and not bool(ev.data.get("dash", false)):
			ticks.append(ev.tick)
			if absf(ev.value - normal) <= normal * 1e-3:
				matching += 1
	assert_true(ticks.size() >= 2, "a player inside bite reach is bitten repeatedly, got %d bites" % ticks.size())
	assert_true(matching >= 1, "at least one boss bite deals the normal bite damage %s (band %d bite_power x length^2 x bite_mult)" % [str(normal), boss.band])
	var cd_ticks: int = S3.ticks(S6.boss_f(db, "bite_cooldown_s", S3.rule_f(db, "bite_cooldown_s")))
	for i in range(1, ticks.size()):
		assert_true(ticks[i] - ticks[i - 1] >= cd_ticks - 1, "boss bites respect the boss bite cooldown (%d ticks apart, min %d)" % [ticks[i] - ticks[i - 1], cd_ticks - 1])


# ======================================================== disengage

func test_disengages_after_the_timeout_and_regenerates_then_reengages() -> void:
	var rg: Dictionary = _rig(89, 15.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var db: ContentDB = w.content
	var near: Vector3 = p.position
	var far: Vector3 = S6.player_pos(rg["spot"], _radius(w) + 40.0)
	var pins: Dictionary = {boss.id: boss.position, p.id: near}
	var all: Array[SimEvent] = []
	all.append_array(S6.run(w, 30, pins, [p.id]))
	assert_true(S6.boss_engaged(w), "test setup: engaged")
	boss.hp = boss.max_hp * 0.5
	var hp_cut: float = boss.hp
	pins[p.id] = far
	var timeout: int = S3.ticks(S6.boss_f(db, "disengage_after_s"))
	var engaged_until: Array[int] = [0]
	var t_out: int = w.tick
	var hit: SimEvent = null
	for i in timeout + 120:
		var evs: Array[SimEvent] = S6.run(w, 1, pins, [p.id])
		all.append_array(evs)
		if S6.boss_engaged(w):
			engaged_until[0] = w.tick - t_out
		var d: Array[SimEvent] = S6.events_named(evs, "BOSS_DISENGAGED")
		if not d.is_empty():
			hit = d[0]
			break
	assert_not_null(hit, "BOSS_DISENGAGED fires after disengage_after_s out of range")
	if hit == null:
		return
	var waited: int = hit.tick - t_out
	assert_true(waited >= timeout - 5 and waited <= timeout + 15, "disengaged %d ticks after the player left; data says %d (+15 / -5)" % [waited, timeout])
	assert_true(engaged_until[0] >= timeout - 6, "stays engaged until the timeout (engaged for %d ticks, timeout %d)" % [engaged_until[0], timeout])
	assert_eq(S6.count_named(all, "BOSS_DISENGAGED"), 1, "exactly one BOSS_DISENGAGED")
	assert_eq(hit.entity_id, boss.id, "event is about the boss")
	S6.run(w, 3, pins, [p.id])
	assert_false(S6.boss_engaged(w), "boss_engaged() is false after the disengage")
	assert_true(["DISENGAGE", "PATROL"].has(S6.state_name(boss)), "DISENGAGE (swimming home) or PATROL right after, got %s" % S6.state_name(boss))
	var return_ticks: int = S3.ticks(S6.boss_f(db, "disengage_return_s", 3.0))
	S6.run(w, return_ticks + 15, pins, [p.id])
	assert_eq(S6.state_name(boss), "PATROL", "back to PATROL after the return")
	# slow HP regeneration while patrolling: hp_regen_frac_per_s of max HP per second
	var hp0: float = boss.hp
	S6.run(w, 300, pins, [p.id])
	var gain: float = boss.hp - hp0
	var expect: float = S6.boss_f(db, "hp_regen_frac_per_s") * boss.max_hp * 10.0
	assert_true(gain >= 0.75 * expect and gain <= 1.25 * expect, "10 s of patrol regenerates hp_regen_frac_per_s x max HP x 10 = %s (+-25%%), got %s (from %s, cut to %s)" % [str(expect), str(gain), str(hp0), str(hp_cut)])
	assert_true(boss.hp <= boss.max_hp, "never above max HP")
	# the player returns: a new engagement is announced again
	pins[p.id] = near
	var back: Array[SimEvent] = S6.run(w, 20, pins, [p.id])
	assert_eq(S6.count_named(back, "BOSS_ENGAGED"), 1, "coming back engages again")
	assert_true(S6.boss_engaged(w), "engaged again")


func test_the_out_of_range_timer_resets_when_the_player_returns() -> void:
	var rg: Dictionary = _rig(90, 15.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var db: ContentDB = w.content
	var near: Vector3 = p.position
	var far: Vector3 = S6.player_pos(rg["spot"], _radius(w) + 40.0)
	var timeout: int = S3.ticks(S6.boss_f(db, "disengage_after_s"))
	var pins: Dictionary = {boss.id: boss.position, p.id: near}
	var all: Array[SimEvent] = []
	all.append_array(S6.run(w, 30, pins, [p.id]))
	pins[p.id] = far
	all.append_array(S6.run(w, timeout - 90, pins, [p.id]))
	assert_true(S6.boss_engaged(w), "test setup: still engaged 3 s before the timeout")
	pins[p.id] = near
	all.append_array(S6.run(w, 60, pins, [p.id]))
	pins[p.id] = far
	var t_leave: int = w.tick
	var hit: SimEvent = _run_until(w, "BOSS_DISENGAGED", timeout + 120, pins, [p.id], all)
	assert_not_null(hit, "disengages eventually")
	if hit != null:
		assert_true(hit.tick - t_leave >= timeout - 5, "a visit inside the radius restarts the timer: disengaged %d ticks after the second exit, timeout %d" % [hit.tick - t_leave, timeout])
	assert_eq(S6.count_named(all, "BOSS_DISENGAGED"), 1, "one disengage only")


# ======================================================== stun, finisher, victory

## Engaged boss (player 15 m away, boss and player pinned), returns the rig after `ticks` and with the hp cut applied.
func _engaged(world_seed: int, xp: float = B4_XP) -> Dictionary:
	var rg: Dictionary = _rig(world_seed, 15.0, xp)
	if rg.is_empty():
		return {}
	var w: SimWorld = rg["w"]
	if not _ready_to_test(w):
		return {}
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = []
	rg["all"] = all
	var keep: Array[int] = [p.id]
	var hit: SimEvent = _run_until(w, "BOSS_ENGAGED", 12, {boss.id: boss.position, p.id: p.position}, keep, all)
	assert_not_null(hit, "test setup: the boss engaged")
	return rg


func test_hp_zero_stuns_the_boss_instead_of_killing_it() -> void:
	var rg: Dictionary = _engaged(91)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = rg["all"]
	var boss_id: int = boss.id
	var pins: Dictionary = {boss_id: boss.position, p.id: p.position}
	boss.hp = 0.0
	all.append_array(S6.run(w, 3, pins, [p.id]))
	var stunned: Array[SimEvent] = S6.events_named(all, "BOSS_STUNNED")
	assert_eq(stunned.size(), 1, "exactly one BOSS_STUNNED")
	if stunned.size() == 1:
		assert_eq(stunned[0].entity_id, boss_id, "the event is about the boss")
	assert_not_null(w.get_entity(boss_id), "the stunned boss is still in the world")
	assert_eq(S6.state_name(boss), "STUNNED", "state STUNNED")
	var tick_stun: int = stunned[0].tick if stunned.size() == 1 else w.tick
	# stays stunned and harmless for 5 s; nothing finishes it; no victory yet
	var later: Array[SimEvent] = S6.run(w, 150, pins, [p.id])
	all.append_array(later)
	assert_eq(S6.state_name(boss), "STUNNED", "still STUNNED 5 s later (waits for the finisher)")
	assert_not_null(w.get_entity(boss_id), "still in the world")
	assert_eq(S6.count_named(all, "DIED"), 0, "nothing died (the boss is not killed by HP 0)")
	assert_eq(S6.count_named(all, "BOSS_DEFEATED"), 0, "no BOSS_DEFEATED without the finisher")
	assert_eq(S6.count_named(all, "VICTORY"), 0, "no VICTORY without the finisher")
	assert_false(S6.run_won(w), "run_won stays false")
	var hurt: int = 0
	for ev: SimEvent in later:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == boss_id and ev.tick > tick_stun:
			hurt += 1
	assert_eq(hurt, 0, "a stunned boss does not attack")


func test_a_player_bite_lowers_boss_hp_by_the_normal_bite_damage() -> void:
	var rg: Dictionary = _engaged(92)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	boss.bite_ready_tick = w.tick + 100000
	p.position = S6.player_pos(rg["spot"], 3.0)
	var hp0: float = boss.hp
	w.submit(SimCommand.bite(p.id, boss.id))
	var evs: Array[SimEvent] = S6.run(w, 3, {boss.id: boss.position, p.id: p.position}, [p.id])
	var expect: float = S6.normal_bite_damage(w.content, S3.PLAYER_SPECIES, p.band, p.length_m)
	assert_almost_eq(hp0 - boss.hp, expect, expect * 1e-6, "boss HP drops by the normal bite damage")
	assert_eq(S6.count_named(evs, "BOSS_STUNNED"), 0, "one bite out of ~30 does not stun")
	assert_true(S6.boss_engaged(w), "still engaged")


## Stunned boss; the player stays 15 m away (the finisher is a mouth-cone touch, so it must not be near yet).
func _stunned(world_seed: int, xp: float = B4_XP) -> Dictionary:
	var rg: Dictionary = _engaged(world_seed, xp)
	if rg.is_empty():
		return {}
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = rg["all"]
	boss.hp = 0.0
	all.append_array(S6.run(w, 3, {boss.id: boss.position, p.id: p.position}, [p.id]))
	assert_eq(S6.state_name(boss), "STUNNED", "test setup: stunned")
	return rg


func test_the_player_touching_a_stunned_boss_finishes_it() -> void:
	var rg: Dictionary = _stunned(93)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = rg["all"]
	var boss_id: int = boss.id
	p.position = S6.player_pos(rg["spot"], 3.0)
	var evs: Array[SimEvent] = S6.run(w, 5, {p.id: p.position}, [p.id])
	all.append_array(evs)
	var done: Array[SimEvent] = S6.events_named(evs, "BOSS_DEFEATED")
	assert_eq(done.size(), 1, "the finisher produces exactly one BOSS_DEFEATED")
	if done.size() == 1:
		assert_eq(done[0].entity_id, boss_id, "the event is about the boss")
		assert_eq(done[0].other_id, p.id, "the finisher is credited to the player (assumption A11)")
	var remains: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.FOOD_SPAWNED and ev.other_id == boss_id:
			remains += 1
	var fb: Dictionary = w.content.rules()["remains"]["food_bits"]
	assert_true(remains >= int(fb["min"]), "the boss leaves remains (food bits), at least remains.food_bits.min (%d), got %d" % [int(fb["min"]), remains])
	assert_eq(S6.count_named(evs, "VICTORY"), 0, "the victory comes after the remains, not in the finisher tick (contract: eaten or victory_delay_s)")
	assert_null(w.get_entity(boss_id), "the boss collapses into its remains (entity removed)")


func test_an_npc_cannot_finish_a_stunned_boss() -> void:
	var rg: Dictionary = _stunned(98)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	# a big grouper (not a player) right at the boss mouth for 5 s
	var g: SimEntity = S3.npc_at(w, &"grouper", boss.position + Vector3(3.0, 0.0, 0.0), 2.0, Vector3.LEFT)
	var evs: Array[SimEvent] = S6.run(w, 150, {boss.id: boss.position, p.id: p.position, g.id: g.position}, [p.id])
	assert_eq(S6.count_named(evs, "BOSS_DEFEATED"), 0, "only a player finishes the boss")
	assert_not_null(w.get_entity(boss.id), "still there")


func test_giant_remains_are_scaled_up() -> void:
	var rg: Dictionary = _stunned(94)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var boss_id: int = boss.id
	p.position = S6.player_pos(rg["spot"], 3.0)
	var evs: Array[SimEvent] = S6.run(w, 5, {p.id: p.position}, [p.id])
	var remains: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.FOOD_SPAWNED and ev.other_id == boss_id:
			remains += 1
	var fb: Dictionary = w.content.rules()["remains"]["food_bits"]
	assert_true(remains > int(fb["max"]), "giant remains: more bits than a normal creature leaves (max %d), got %d (assumption A8)" % [int(fb["max"]), remains])


func test_victory_fires_once_with_the_run_data() -> void:
	var rg: Dictionary = _engaged(95, B4_DEEP_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var all: Array[SimEvent] = rg["all"]
	var db: ContentDB = w.content
	S6.give(w, p, ["hunter_bite_power", "hunter_bite_dash"])
	# one death first, so that "deaths" is not vacuous (the player respawns at a map spawn, far away)
	p.hp = 0.0
	all.append_array(S6.run(w, S3.ticks(S3.rule_f(db, "respawn_delay_s")) + 10, {boss.id: boss.position}))
	assert_eq(p.deaths, 1, "test setup: one death")
	assert_true(p.alive, "test setup: respawned")
	assert_true(p.band == 4, "test setup: still B4 after the XP loss, got B%d" % p.band)
	# back to the boss, stun it, finish it by touching it
	p.position = S6.player_pos(rg["spot"], 15.0)
	var pins: Dictionary = {boss.id: boss.position, p.id: p.position}
	all.append_array(S6.run(w, 10, pins, [p.id]))
	boss.hp = 0.0
	all.append_array(S6.run(w, 3, pins, [p.id]))
	assert_eq(S6.state_name(boss), "STUNNED", "test setup: stunned")
	p.position = S6.player_pos(rg["spot"], 3.0)
	all.append_array(S6.run(w, 5, {p.id: p.position}, [p.id]))
	assert_eq(S6.count_named(all, "BOSS_DEFEATED"), 1, "test setup: the boss was defeated")
	var delay_ticks: int = S3.ticks(S6.boss_f(db, "victory_delay_s", 6.0))
	all.append_array(S6.run(w, delay_ticks + 120, {p.id: p.position}, [p.id]))
	var wins: Array[SimEvent] = S6.events_named(all, "VICTORY")
	assert_eq(wins.size(), 1, "exactly one VICTORY")
	assert_true(S6.run_won(w), "run_won is set")
	if wins.size() == 1:
		var v: SimEvent = wins[0]
		assert_eq(v.entity_id, p.id, "the victory is the player's")
		assert_true(absi(int(v.data.get("run_ticks", -1000)) - v.tick) <= 2, "data.run_ticks is the run time at the victory (%s vs tick %d)" % [str(v.data.get("run_ticks")), v.tick])
		assert_eq(int(v.data.get("deaths", -1)), 1, "data.deaths")
		var muts: Array = []
		for m: Variant in v.data.get("mutations", []):
			muts.append(str(m))
		assert_eq(muts, ["hunter_bite_power", "hunter_bite_dash"], "data.mutations = the picks, in order")
		var defeated: Array[SimEvent] = S6.events_named(all, "BOSS_DEFEATED")
		assert_true(v.tick >= defeated[0].tick, "victory after the defeat")
	# a long quiet time afterwards: no second victory, nothing re-triggers
	all.append_array(S6.run(w, 1800, {p.id: p.position}, [p.id]))
	assert_eq(S6.count_named(all, "VICTORY"), 1, "still exactly one VICTORY a minute later")
	assert_eq(S6.count_named(all, "BOSS_DEFEATED"), 1, "still exactly one BOSS_DEFEATED")


func test_victory_comes_after_victory_delay_when_the_remains_are_left_alone() -> void:
	var rg: Dictionary = _stunned(96)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var boss: SimEntity = rg["boss"]
	var p: SimEntity = rg["p"]
	var db: ContentDB = w.content
	p.position = S6.player_pos(rg["spot"], 3.0)
	var all: Array[SimEvent] = []
	all.append_array(S6.run(w, 2, {p.id: p.position}, [p.id]))
	var defeated: Array[SimEvent] = S6.events_named(all, "BOSS_DEFEATED")
	assert_eq(defeated.size(), 1, "test setup: defeated")
	if defeated.is_empty():
		return
	# the player swims away: the remains (30 s lifetime) cannot be eaten, the delay fires the victory
	var away: Vector3 = S6.player_pos(rg["spot"], 60.0)
	var delay: int = S3.ticks(S6.boss_f(db, "victory_delay_s", 6.0))
	all.append_array(S6.run(w, delay + 90, {p.id: away}, [p.id]))
	var wins: Array[SimEvent] = S6.events_named(all, "VICTORY")
	assert_eq(wins.size(), 1, "one VICTORY")
	if wins.size() == 1:
		var dt: int = wins[0].tick - defeated[0].tick
		assert_true(absi(dt - delay) <= S6.TICKS_PER_S, "VICTORY victory_delay_s (%d ticks) after the defeat, was %d" % [delay, dt])


func test_no_victory_without_defeating_the_boss() -> void:
	var rg: Dictionary = _rig(97, 15.0, B4_XP)
	if rg.is_empty():
		return
	var w: SimWorld = rg["w"]
	var p: SimEntity = rg["p"]
	if not _ready_to_test(w):
		return
	var evs: Array[SimEvent] = S6.run(w, 900, {p.id: p.position}, [p.id])
	assert_eq(S6.count_named(evs, "VICTORY"), 0, "30 s of fighting, no victory")
	assert_false(S6.run_won(w), "run_won false")
