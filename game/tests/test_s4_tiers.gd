extends TestCase
## S4 promotion / demotion (contract "Promotion / demotion", TierManager inside SimWorld.step()):
## - promote ambient members within tiers.promote_radius_m of the NEAREST player (any player);
## - hysteresis: between promote and demote radius an interactive member stays; beyond demote_radius_m it is demoted,
##   but only after tiers.min_interactive_s as interactive; never while a predator targets it;
## - promoted entities start at the sim position of the member (covered in test_s4_school_events);
## - caps: tiers.interactive_cap (schools + non-school interactive spawners share it), tiers.large_cap (large spawners);
##   when the cap bites, promotion is nearest-first and deterministic;
## - several players: each promotes the school around it, a school near nobody stays ambient.
## Radii / periods come from ContentDB; caps are overridden only where the scenario needs a small one.
## Geometry: size-1 schools in kelp_forest; the player is re-placed every tick at a fixed horizontal distance from the
## member (sim position while ambient, entity position once promoted) with S4.place().

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const MARGIN_M: float = 5.0


## Player at st["d_ambient"] from the member while it is in the school form, at st["d_interactive"] from its entity
## while it is promoted. Once the member has been promoted, a later empty slot (demotion) does NOT bring the player
## back: it stays at the interactive distance (st["seen"] latch), otherwise the member would legitimately be promoted
## again (the contract has no re-promotion cooldown).
func _stalker(school: Object, pid: int, st: Dictionary) -> Callable:
	return func(world: SimWorld) -> void:
		var anchor: Vector3 = S4.member_pos(school, 0, world.tick)
		var live: Array[SimEntity] = S4.promoted_entities(world)
		var d: float = float(st["d_ambient"])
		if not live.is_empty():
			anchor = live[0].position
			d = float(st["d_interactive"])
			st["seen"] = true
			st["last"] = anchor
		elif bool(st.get("seen", false)):
			anchor = st["last"]
			d = float(st["d_interactive"])
		S4.pin(world, pid, S4.place(world, anchor, d))


func _one_member_world(world_seed: int, extra: Dictionary = {}) -> SimWorld:
	return S4.school_world(world_seed, 1, 1, 4.0, S4.KELP, 1, extra)


func _start_player(w: SimWorld, school: Object, d: float) -> int:
	var p: Vector3 = S4.place(w, S4.member_pos(school, 0, w.tick), d)
	assert_true(p.is_finite(), "setup: a valid player position %.0f m from the member exists" % d)
	return S3.player_at(w, p if p.is_finite() else S3.ARENA, 0.0).id


# ======================================================== radii and hysteresis

func test_members_beyond_the_promote_radius_stay_ambient() -> void:
	var w: SimWorld = _one_member_world(41)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var pid: int = _start_player(w, school, promote + MARGIN_M)
	var st: Dictionary = {"d_ambient": promote + MARGIN_M, "d_interactive": promote + MARGIN_M}
	var evs: Array[SimEvent] = S4.run(w, 6 * S4.period(w) + 10, _stalker(school, pid, st))
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED").size(), 0, "a member %.0f m away (promote radius %.0f m) is not promoted" % [promote + MARGIN_M, promote])
	assert_eq(S4.ambient_count(school), 1, "it stays in the school form")
	assert_eq(S4.promoted_entities(w).size(), 0, "no interactive entity exists")


func test_members_inside_the_promote_radius_are_promoted_within_one_scan_period() -> void:
	var w: SimWorld = _one_member_world(42)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var pid: int = _start_player(w, school, promote - MARGIN_M)
	var st: Dictionary = {"d_ambient": promote - MARGIN_M, "d_interactive": promote - MARGIN_M}
	var period: int = S4.period(w)
	var evs: Array[SimEvent] = S4.run(w, period + 2, _stalker(school, pid, st))
	var proms: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED")
	assert_eq(proms.size(), 1, "a member %.0f m away is promoted within one scan period (%d ticks)" % [promote - MARGIN_M, period])
	assert_eq(S4.ambient_count(school), 0, "it left the school form")


func test_hysteresis_keeps_a_member_between_the_promote_and_the_demote_radius() -> void:
	var w: SimWorld = _one_member_world(43)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var demote: float = S4.tier_f(w, "demote_radius_m")
	assert_true(demote > promote, "data: demote radius %.1f > promote radius %.1f (hysteresis)" % [demote, promote])
	var mid: float = 0.5 * (promote + demote)
	var pid: int = _start_player(w, school, promote - MARGIN_M)
	# Approach until promoted, then stand at the middle distance for much longer than min_interactive_s.
	var st: Dictionary = {"d_ambient": promote - MARGIN_M, "d_interactive": mid}
	var pre: Callable = _stalker(school, pid, st)
	var first: Array[SimEvent] = S4.run(w, 3 * S4.period(w), pre)
	assert_eq(S4.events_named(first, "SCHOOL_MEMBER_PROMOTED").size(), 1, "setup: the member was promoted")
	var hold: int = S3.ticks(S4.tier_f(w, "min_interactive_s")) + 8 * S4.period(w) + 90
	var evs: Array[SimEvent] = S4.run(w, hold, pre)
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_DEMOTED").size(), 0, "no demotion while the player is %.1f m away (between %.0f and %.0f)" % [mid, promote, demote])
	assert_eq(S4.promoted_entities(w).size(), 1, "the interactive entity is still there")
	assert_eq(S4.ambient_count(school), 0, "and the slot is still empty")


func test_demotion_beyond_the_demote_radius_waits_for_min_interactive_s() -> void:
	var w: SimWorld = _one_member_world(44)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var demote: float = S4.tier_f(w, "demote_radius_m")
	var pid: int = _start_player(w, school, promote - MARGIN_M)
	# The stalker jumps to "beyond the demote radius" in the very tick after the promotion.
	var st: Dictionary = {"d_ambient": promote - MARGIN_M, "d_interactive": demote + MARGIN_M}
	var min_ticks: int = S3.ticks(S4.tier_f(w, "min_interactive_s"))
	var period: int = S4.period(w)
	var evs: Array[SimEvent] = S4.run(w, min_ticks + 4 * period + 90, _stalker(school, pid, st))
	var proms: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED")
	var dems: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_DEMOTED")
	assert_eq(proms.size(), 1, "setup: promoted once")
	assert_eq(dems.size(), 1, "and demoted once after the player moved beyond %.0f m" % demote)
	if proms.size() == 1 and dems.size() == 1:
		var held: int = dems[0].tick - proms[0].tick
		assert_true(held >= min_ticks - 1, "interactive for %d ticks, at least min_interactive_s = %d ticks" % [held, min_ticks])
		assert_true(held <= min_ticks + period + 3, "and demoted at the first scan after that (%d <= %d + %d)" % [held, min_ticks, period])
	assert_eq(S4.ambient_count(school), 1, "the member is back in the school form")
	assert_eq(S4.promoted_entities(w).size(), 0, "the entity is gone")


func test_a_member_chased_by_a_predator_is_not_demoted_until_the_chase_ends() -> void:
	var w: SimWorld = _one_member_world(45)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var demote: float = S4.tier_f(w, "demote_radius_m")
	var pid: int = _start_player(w, school, promote - MARGIN_M)
	var st: Dictionary = {"d_ambient": promote - MARGIN_M, "d_interactive": demote + MARGIN_M}
	var pre_player: Callable = _stalker(school, pid, st)
	S4.run(w, 3 * S4.period(w), pre_player)
	var live: Array[SimEntity] = S4.promoted_entities(w)
	assert_eq(live.size(), 1, "setup: the member is promoted")
	if live.size() != 1:
		return
	var target_id: int = live[0].id
	var hunter: SimEntity = S3.npc_at(w, &"barracuda", live[0].position + Vector3(6.0, 0.0, 0.0), 1.0)
	var hid: int = hunter.id
	# Hold the hunter 6 m from the member (it cannot reach it) and keep the hunt going every tick.
	var chase: Callable = func(world: SimWorld) -> void:
		pre_player.call(world)
		var h: SimEntity = world.get_entity(hid)
		var t: SimEntity = world.get_entity(target_id)
		if h != null and h.alive and t != null and t.alive:
			h.position = t.position + Vector3(6.0, 0.0, 0.0)
			h.velocity = Vector3.ZERO
			h.aggro_target = target_id
			h.aggro_until_tick = world.tick + 300
	var min_ticks: int = S3.ticks(S4.tier_f(w, "min_interactive_s"))
	var evs: Array[SimEvent] = S4.run(w, min_ticks + 6 * S4.period(w) + 90, chase)
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_DEMOTED").size(), 0, "no demotion while a predator targets the member, although the player is beyond the demote radius")
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_EATEN").size(), 0, "(and the hold kept the member alive, so the check is meaningful)")
	assert_eq(S4.promoted_entities(w).size(), 1, "the member is still interactive")
	# Chase over: the predator disappears; the member may now be demoted within a few seconds.
	w.remove_entity(hid)
	var after: Array[SimEvent] = S4.run(w, S3.ticks(4.0) + 2 * S4.period(w) + 10, pre_player)
	assert_eq(S4.events_named(after, "SCHOOL_MEMBER_DEMOTED").size(), 1, "once the chase is over the far member is demoted")


func test_a_fleeing_member_is_not_demoted_while_it_flees() -> void:
	var w: SimWorld = _one_member_world(46)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var promote: float = S4.tier_f(w, "promote_radius_m")
	var demote: float = S4.tier_f(w, "demote_radius_m")
	var pid: int = _start_player(w, school, promote - MARGIN_M)
	var st: Dictionary = {"d_ambient": promote - MARGIN_M, "d_interactive": demote + MARGIN_M}
	var pre_player: Callable = _stalker(school, pid, st)
	S4.run(w, 3 * S4.period(w), pre_player)
	var live: Array[SimEntity] = S4.promoted_entities(w)
	assert_eq(live.size(), 1, "setup: the member is promoted")
	if live.size() != 1:
		return
	var target_id: int = live[0].id
	# A large predator frozen 3 m from the member, never targeting it: the member flees (brain state FLEE) but nobody hunts it.
	var big: SimEntity = S3.npc_at(w, &"shark", live[0].position + Vector3(3.0, 0.0, 0.0), 3.0)
	var big_id: int = big.id
	var fled_ticks: int = 0
	var min_ticks: int = S3.ticks(S4.tier_f(w, "min_interactive_s"))
	var dems: int = 0
	for i in min_ticks + 6 * S4.period(w) + 60:
		pre_player.call(w)
		var b: SimEntity = w.get_entity(big_id)
		var t: SimEntity = w.get_entity(target_id)
		if b != null and t != null and b.alive and t.alive:
			b.position = t.position + Vector3(3.0, 0.0, 0.0)
			b.velocity = Vector3.ZERO
			b.aggro_target = -1
		w.step()
		dems += S4.events_named(w.events_since(w.tick - 1), "SCHOOL_MEMBER_DEMOTED").size()
		var t2: SimEntity = w.get_entity(target_id)
		if t2 != null and t2.alive and t2.brain_state == NpcBrain.State.FLEE:
			fled_ticks += 1
	assert_true(fled_ticks > 0, "setup: the member actually fled from the shark (%d ticks in FLEE)" % fled_ticks)
	assert_eq(dems, 0, "no demotion while the member flees, although the player is beyond the demote radius (impl-A choice, plan A9)")
	assert_false(S3.is_gone(w, target_id), "(the member survived the whole hold, so the check is meaningful)")


func test_a_dead_player_neither_promotes_nor_holds_members() -> void:
	var w: SimWorld = S4.school_world(47, 8, 8, 4.0, S4.KELP, 1)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var p: SimEntity = S4.player_at_school(w, 0)
	p.hp = 0.0
	var evs: Array[SimEvent] = S4.run(w, 4 * S4.period(w))
	assert_false(p.alive, "setup: the player is dead")
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED").size(), 0, "a dead player in the middle of the school promotes nobody")
	assert_eq(S4.ambient_count(school), 8, "the school stays in the school form")


# ======================================================== caps

func _interactive_total(w: SimWorld) -> int:
	return S4.creatures_of_tier(w, "interactive").size()


func test_the_interactive_cap_is_never_exceeded_and_the_nearest_members_win() -> void:
	var cap: int = 5
	var w: SimWorld = S4.school_world(51, 30, 30, 4.0, S4.KELP, 1, {"tiers": {"interactive_cap": cap}})
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0, Vector3(1.5, 0.5, -1.0)).id
	var start_pos: Vector3 = w.get_entity(pid).position
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, start_pos)
	var promoted: Array[SimEvent] = []
	var worst: int = 0
	for i in 150:
		pre.call(w)
		w.step()
		promoted.append_array(S4.events_named(w.events_since(w.tick - 1), "SCHOOL_MEMBER_PROMOTED"))
		worst = maxi(worst, _interactive_total(w))
	assert_true(worst <= cap, "never more than the cap (%d) interactive entities; saw %d" % [cap, worst])
	assert_eq(promoted.size(), cap, "30 members want in, exactly the cap (%d) get in" % cap)
	assert_eq(S4.promoted_of(school).size(), cap, "school.promoted lists them")
	if promoted.is_empty():
		return
	# Nearest first: everyone promoted is at most 0.5 m (the distance quantum) farther than everyone left out.
	var t0: int = promoted[0].tick
	var in_set: Dictionary = {}
	for ev: SimEvent in promoted:
		in_set[S4.ev_k(ev)] = true
	var farthest_in: float = 0.0
	var nearest_out: float = INF
	for k in 30:
		var d: float = S4.member_pos(school, k, t0).distance_to(start_pos)
		if in_set.has(k):
			farthest_in = maxf(farthest_in, d)
		else:
			nearest_out = minf(nearest_out, d)
	assert_true(farthest_in <= nearest_out + 0.5 + 0.25, "nearest-first: farthest promoted member %.2f m, nearest left out %.2f m" % [farthest_in, nearest_out])
	# Promotion order is by distance (quantised to 0.5 m): never a clearly farther member before a clearly nearer one.
	var prev: float = 0.0
	for ev2: SimEvent in promoted:
		var d2: float = S4.member_pos(school, S4.ev_k(ev2), t0).distance_to(start_pos)
		assert_true(d2 + 0.75 >= prev, "promotion order is nearest-first (member %d at %.2f m after %.2f m)" % [S4.ev_k(ev2), d2, prev])
		prev = maxf(prev, d2)


func test_the_promotion_order_under_a_cap_is_deterministic() -> void:
	var orders: Array[Array] = []
	for run_i in 2:
		var w: SimWorld = S4.school_world(52, 30, 30, 4.0, S4.KELP, 1, {"tiers": {"interactive_cap": 5}})
		if not S4.require_api(self, w):
			return
		var pid: int = S4.player_at_school(w, 0, Vector3(1.5, 0.5, -1.0)).id
		var start_pos: Vector3 = w.get_entity(pid).position
		var pre: Callable = func(world: SimWorld) -> void:
			S4.pin(world, pid, start_pos)
		var evs: Array[SimEvent] = S4.run(w, 60, pre)
		var order: Array = []
		for ev: SimEvent in S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED"):
			order.append([ev.tick, S4.ev_school(ev), S4.ev_k(ev), int(ev.data.get("entity", -1))])
		orders.append(order)
	assert_eq(orders[0].size(), 5, "5 promotions under cap 5")
	assert_eq(str(orders[0]), str(orders[1]), "same seed, same promotion sequence (tick, school, k, entity id)")


func test_non_school_interactive_spawners_count_against_the_interactive_cap() -> void:
	var cap: int = 6
	var puffers: int = 4
	var w: SimWorld = S4.school_world(53, 30, 30, 4.0, S4.KELP, 1, {"tiers": {"interactive_cap": cap}, "spawners": [S4.spawner_rec("puffer", S4.KELP, puffers, 5.0)]})
	if not S4.require_api(self, w):
		return
	var pid: int = S4.player_at_school(w, 0).id
	var school: Object = S4.get_school(w, 0)
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(school, world.tick))
	var worst: int = 0
	for i in 180:
		pre.call(w)
		w.step()
		worst = maxi(worst, _interactive_total(w))
	assert_true(worst <= cap, "puffers + promoted members never exceed the cap (%d); saw %d" % [cap, worst])
	assert_eq(S3.species_count(w, &"puffer"), puffers, "spawner puffers are always entities")
	assert_eq(S4.promoted_entities(w).size(), cap - puffers, "the school gets what the puffers leave: %d" % (cap - puffers))


func test_the_interactive_cap_limits_a_non_school_spawner() -> void:
	var w: SimWorld = S4.make_world(54, {"spawners": [S4.spawner_rec("puffer", S4.KELP, 50, 2.0)], "tiers": {"interactive_cap": 10}})
	if not S4.require_api(self, w):
		return
	var worst: int = 0
	for i in 150:
		w.step()
		worst = maxi(worst, S3.species_count(w, &"puffer"))
	assert_eq(worst, 10, "50 puffers wanted, the interactive cap (10) is the limit")


func test_the_large_cap_limits_large_actors() -> void:
	var w: SimWorld = S4.make_world(55, {"spawners": [S4.spawner_rec("shark", "open_water", 10, 2.0), S4.spawner_rec("grouper", "rock_arches", 10, 2.0)], "tiers": {"large_cap": 3, "interactive_cap": 50}})
	if not S4.require_api(self, w):
		return
	var worst: int = 0
	for i in 150:
		w.step()
		worst = maxi(worst, S4.creatures_of_tier(w, "large").size())
	assert_eq(worst, 3, "20 large actors wanted, the large cap (3) is the limit and is reached")
	assert_eq(S4.creatures_of_tier(w, "interactive").size(), 0, "large actors do not use the interactive cap")


# ======================================================== several players

func test_each_player_promotes_the_school_around_it_and_a_far_school_stays_ambient() -> void:
	var recs: Array = [S4.school_rec(S4.SILVER, S4.KELP, 1, 6, 6, 4.0), S4.school_rec(S4.SILVER, S4.ABYSS, 1, 6, 6, 4.0)]
	# World 1: only a player at the kelp school.
	var w1: SimWorld = S4.make_world(56, {"schools": recs})
	if not S4.require_api(self, w1):
		return
	var a1: Object = S4.get_school(w1, 0)
	var b1: Object = S4.get_school(w1, 1)
	var p1: int = S4.player_at_school(w1, 0).id
	S4.run(w1, S4.period(w1) + 4, func(world: SimWorld) -> void: S4.pin(world, p1, S4.center_at(a1, world.tick)))
	assert_true(S4.promoted_of(a1).size() >= 1, "the school around the player is promoted")
	assert_eq(S4.ambient_count(b1), 6, "the school far from every player stays fully ambient")
	# World 2: a second player at the abyss school. Distance is to the NEAREST player, so both schools are promoted.
	var w2: SimWorld = S4.make_world(56, {"schools": recs})
	var a2: Object = S4.get_school(w2, 0)
	var b2: Object = S4.get_school(w2, 1)
	var pa: int = S4.player_at_school(w2, 0).id
	var pb: int = S4.player_at_school(w2, 1).id
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pa, S4.center_at(a2, world.tick))
		S4.pin(world, pb, S4.center_at(b2, world.tick))
	S4.run(w2, S4.period(w2) + 4, pre)
	assert_true(S4.promoted_of(a2).size() >= 1, "player A's school is promoted")
	assert_true(S4.promoted_of(b2).size() >= 1, "player B's school is promoted (nearest-player distance, not just the first player)")
	assert_eq(S4.invariants(w2), "", "bookkeeping consistent with two players")
	# Player A leaves: its school demotes after min_interactive_s, B's school keeps its members.
	var min_ticks: int = S3.ticks(S4.tier_f(w2, "min_interactive_s"))
	var pre2: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pb, S4.center_at(b2, world.tick))
		world.remove_entity(pa)
	var evs: Array[SimEvent] = S4.run(w2, min_ticks + 4 * S4.period(w2) + 60, pre2)
	assert_eq(S4.promoted_of(a2).size(), 0, "A's school is back to the school form")
	assert_eq(S4.ambient_count(a2), 6, "all six members of A's school are ambient again")
	assert_true(S4.promoted_of(b2).size() >= 1, "B's school is still promoted around its player")
	for ev: SimEvent in S4.events_named(evs, "SCHOOL_MEMBER_DEMOTED"):
		assert_eq(S4.ev_school(ev), 0, "only A's school was demoted")


func test_promotion_scans_run_at_the_configured_period() -> void:
	var w: SimWorld = S4.school_world(57, 8, 8, 4.0, S4.KELP, 1)
	if not S4.require_api(self, w):
		return
	var period: int = S4.period(w)
	assert_true(period >= 1, "tiers.update_every_ticks >= 1")
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(school, world.tick))
	var evs: Array[SimEvent] = S4.run(w, 3 * period, pre)
	var proms: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED")
	assert_true(proms.size() >= 1, "members promoted")
	if not proms.is_empty():
		assert_true(proms[0].tick <= period, "first promotion within the first scan period (tick %d, period %d)" % [proms[0].tick, period])
		var residue: int = proms[0].tick % period
		for ev: SimEvent in proms:
			assert_eq(ev.tick % period, residue, "all promotions of one school happen on its own scan phase (tick %d)" % ev.tick)
