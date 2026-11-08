extends TestCase
## S4 school events (contract "Events"): SCHOOL_MEMBER_PROMOTED / DEMOTED / EATEN / RESPAWNED are the ONLY way school
## state changes. Checked on small controlled worlds (one or two silver schools in kelp_forest, respawn 4 s):
## event data and `alive` bookkeeping, promoted entity placement and back-references, a promoted member that dies
## emits EATEN and its slot comes back exactly respawn_s later, a demoted member returns to the school form without
## a DIED event, and the event log alone (test-side reducer) reproduces the school state; a second identical run
## gives the identical log and state. Ambient members cannot be eaten.
## Members are killed by writing hp = 0 on the promoted entity (S3 style); the sim turns that into DIED/EATEN.

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const RESPAWN_S: float = 4.0
const SIZE: int = 12


func _world(world_seed: int = 61, count: int = 1) -> SimWorld:
	return S4.school_world(world_seed, SIZE, SIZE, RESPAWN_S, S4.KELP, count)


## Pins the player into the middle of school `sid` every tick.
func _pin_to_school(pid: int, school: Object) -> Callable:
	return func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(school, world.tick))


# ======================================================== promotion

func test_promotion_emits_events_and_moves_the_member_into_an_entity() -> void:
	var w: SimWorld = _world()
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var evs: Array[SimEvent] = S4.run(w, S4.period(w) + 2, _pin_to_school(pid, school))
	var proms: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED")
	assert_true(proms.size() >= 1, "a player in the middle of a school promotes members within one scan period")
	var promote_radius: float = S4.tier_f(w, "promote_radius_m")
	var ks: Dictionary = {}
	var player_pos: Vector3 = w.get_entity(pid).position
	for ev: SimEvent in proms:
		var k: int = S4.ev_k(ev)
		assert_eq(S4.ev_school(ev), 0, "event names school 0")
		assert_true(k >= 0 and k < SIZE, "member index %d in range" % k)
		assert_false(ks.has(k), "member %d promoted once" % k)
		ks[k] = true
		var eid: int = int(ev.data.get("entity", -1))
		var e: SimEntity = w.get_entity(eid)
		assert_not_null(e, "event data.entity %d is a real entity" % eid)
		if e == null:
			continue
		assert_eq(e.species_id, S4.SILVER, "promoted entity has the school species")
		assert_eq(S4.school_id_of(e), 0, "back-reference school_id")
		assert_eq(S4.school_member_of(e), k, "back-reference school_member")
		assert_false(e.is_player, "promoted members are NPCs")
		var lm: Dictionary = w.content.get_species(S4.SILVER)["length_m"]
		assert_true(e.length_m >= float(lm["min"]) - 1e-9 and e.length_m <= float(lm["max"]) + 1e-9, "length %.3f inside the species range" % e.length_m)
		assert_eq(S4.alive_of(school)[k], 0, "member %d left the school form (alive == 0)" % k)
		assert_eq(int(S4.promoted_of(school).get(k, -1)), eid, "school.promoted maps member %d to entity %d" % [k, eid])
		assert_true(S4.member_pos(school, k, ev.tick).distance_to(player_pos) <= promote_radius + S4.POS_TOL, "promoted member %d was inside promote_radius_m" % k)
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_DEMOTED").size(), 0, "nothing is demoted while the player stays in the school")
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_EATEN").size(), 0, "nothing is eaten")
	assert_eq(S4.invariants(w), "", "school bookkeeping is consistent")


func test_a_promoted_entity_starts_at_the_sim_position_of_its_member() -> void:
	var w: SimWorld = _world(62)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = _pin_to_school(pid, school)
	var checked: int = 0
	for i in S4.period(w) + 4:
		pre.call(w)
		w.step()
		for ev: SimEvent in S4.events_named(w.events_since(w.tick - 1), "SCHOOL_MEMBER_PROMOTED"):
			var e: SimEntity = w.get_entity(int(ev.data.get("entity", -1)))
			if e == null:
				continue
			var expect: Vector3 = S4.member_pos(school, S4.ev_k(ev), ev.tick)
			assert_true(e.position.distance_to(expect) <= S4.POS_TOL, "member %d: entity at %s, sim position %s (tolerance %.1f m)" % [S4.ev_k(ev), e.position, expect, S4.POS_TOL])
			checked += 1
	assert_true(checked >= 1, "at least one promotion was checked")


func test_without_a_player_nothing_is_promoted_and_ambient_members_cannot_be_eaten() -> void:
	var w: SimWorld = _world(63)
	if not S4.require_api(self, w):
		return
	var school: Object = S4.get_school(w, 0)
	# A big predator in the middle of the school: ambient members are school-level state, not entities.
	S3.npc_at(w, &"shark", S4.center_at(school, 0), 3.0)
	var evs: Array[SimEvent] = S4.run(w, 600)
	assert_eq(S4.school_events(evs).size(), 0, "no school event at all: only players promote, and ambient members cannot be eaten")
	assert_eq(S4.ambient_count(school), SIZE, "every member is still in the school form")
	assert_eq(w.entity_count(), 1, "the sim holds no entity for ambient members (only the shark)")


# ======================================================== eaten / respawn

func _promoted_world(world_seed: int) -> Dictionary:
	var w: SimWorld = _world(world_seed)
	if not S4.api_problems(w).is_empty():
		return {"w": w}  # the test reports the missing API through S4.require_api
	var school: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = _pin_to_school(pid, school)
	var evs: Array[SimEvent] = S4.run(w, S4.period(w) + 2, pre)
	return {"w": w, "school": school, "pid": pid, "pre": pre, "events": evs}


func test_killing_a_promoted_member_emits_eaten_and_the_slot_stays_empty() -> void:
	var ctx: Dictionary = _promoted_world(64)
	var w: SimWorld = ctx["w"]
	if not S4.require_api(self, w):
		return
	var school: Object = ctx["school"]
	var victims: Array[SimEntity] = S4.promoted_entities(w)
	assert_true(victims.size() >= 1, "setup: a promoted member exists")
	if victims.is_empty():
		return
	var v: SimEntity = victims[0]
	var k: int = S4.school_member_of(v)
	v.hp = 0.0
	var evs: Array[SimEvent] = S4.run(w, 3, ctx["pre"])
	var eaten: Array[SimEvent] = S4.member_events(evs, "SCHOOL_MEMBER_EATEN", 0, k)
	assert_eq(eaten.size(), 1, "exactly one SCHOOL_MEMBER_EATEN for member %d" % k)
	assert_eq(S4.alive_of(school)[k], 0, "the slot is empty")
	assert_false(S4.promoted_of(school).has(k), "and no longer promoted")
	assert_true(S3.is_gone(w, v.id), "the entity is gone")
	assert_eq(S4.member_events(evs, "SCHOOL_MEMBER_DEMOTED", 0, k).size(), 0, "a kill is not a demotion")
	assert_eq(S4.invariants(w), "", "bookkeeping consistent after the kill")


func test_an_eaten_slot_respawns_exactly_respawn_s_later() -> void:
	var ctx: Dictionary = _promoted_world(65)
	var w: SimWorld = ctx["w"]
	if not S4.require_api(self, w):
		return
	var school: Object = ctx["school"]
	var victims: Array[SimEntity] = S4.promoted_entities(w)
	if victims.is_empty():
		fail("setup: a promoted member exists")
		return
	var k: int = S4.school_member_of(victims[0])
	victims[0].hp = 0.0
	var delay: int = S3.ticks(RESPAWN_S)
	var evs: Array[SimEvent] = S4.run(w, 2, ctx["pre"])
	var eaten: Array[SimEvent] = S4.member_events(evs, "SCHOOL_MEMBER_EATEN", 0, k)
	assert_eq(eaten.size(), 1, "member %d was eaten" % k)
	if eaten.is_empty():
		return
	var t_eaten: int = eaten[0].tick
	# Pinned layout (impl-A): pending_respawn = due ticks (eaten tick + respawn_s), ascending; pending_member = the
	# member index at the same position.
	var pending: PackedInt32Array = school.get("pending_respawn")
	var pending_k: PackedInt32Array = school.get("pending_member")
	assert_eq(pending.size(), pending_k.size(), "pending_respawn and pending_member are parallel lists")
	var idx: int = pending_k.find(k)
	assert_true(idx >= 0, "member %d is listed in pending_member %s" % [k, pending_k])
	if idx >= 0:
		assert_eq(pending[idx], t_eaten + delay, "its due tick is eaten tick %d + %d" % [t_eaten, delay])
	# Move the player away so the respawned member is not promoted again immediately (it would hide the school form).
	var away: Callable = func(world: SimWorld) -> void:
		S4.pin(world, ctx["pid"], S4.place(world, S4.center_at(school, world.tick), 200.0))
	var gap_ok: bool = true
	var t_respawn: int = -1
	for i in delay + 60:
		away.call(w)
		w.step()
		var step_evs: Array[SimEvent] = w.events_since(w.tick - 1)
		if w.tick < t_eaten + delay - 3:
			gap_ok = gap_ok and S4.alive_of(school)[k] == 0 and not S4.promoted_of(school).has(k)
		var back: Array[SimEvent] = S4.member_events(step_evs, "SCHOOL_MEMBER_RESPAWNED", 0, k)
		if not back.is_empty():
			t_respawn = back[0].tick
			break
	assert_true(gap_ok, "the slot stays empty until shortly before respawn_s has passed")
	assert_true(t_respawn >= 0, "SCHOOL_MEMBER_RESPAWNED fired for member %d" % k)
	if t_respawn >= 0:
		assert_true(absi((t_respawn - t_eaten) - delay) <= 1, "respawn %d ticks after the loss, expected %d (respawn_s %.1f)" % [t_respawn - t_eaten, delay, RESPAWN_S])
		assert_eq(S4.alive_of(school)[k], 1, "the member is back in the school form")
	assert_eq(S4.invariants(w), "", "bookkeeping consistent after the respawn")


# ======================================================== demotion

func test_demotion_returns_the_member_to_the_school_without_a_died_event() -> void:
	var ctx: Dictionary = _promoted_world(66)
	var w: SimWorld = ctx["w"]
	if not S4.require_api(self, w):
		return
	var school: Object = ctx["school"]
	var ids: Array[int] = []
	var ks: Array[int] = []
	for e: SimEntity in S4.promoted_entities(w):
		ids.append(e.id)
		ks.append(S4.school_member_of(e))
	assert_true(ids.size() >= 1, "setup: members are promoted")
	var min_ticks: int = S3.ticks(S4.tier_f(w, "min_interactive_s"))
	var away: Callable = func(world: SimWorld) -> void:
		S4.pin(world, ctx["pid"], S4.place(world, S4.center_at(school, world.tick), 200.0))
	var evs: Array[SimEvent] = S4.run(w, min_ticks + 4 * S4.period(w) + 60, away)
	for k: int in ks:
		assert_eq(S4.member_events(evs, "SCHOOL_MEMBER_DEMOTED", 0, k).size(), 1, "member %d was demoted once after the player left" % k)
		assert_eq(S4.alive_of(school)[k], 1, "member %d is back in the school form (alive == 1)" % k)
	for id: int in ids:
		assert_true(S3.is_gone(w, id), "entity %d was removed" % id)
		assert_false(w.grid.has(id), "entity %d left the spatial grid" % id)
		for ev: SimEvent in S4.events_named(evs, "DIED"):
			assert_ne(ev.entity_id, id, "a demoted member must not emit DIED")
	var died: int = 0
	for ev2: SimEvent in evs:
		if int(ev2.type) == int(SimEvent.Type.DIED):
			died += 1
	assert_eq(died, 0, "no DIED event in the whole demotion run")
	assert_eq(S4.events_named(evs, "SCHOOL_MEMBER_EATEN").size(), 0, "and no EATEN: demotion is not death")
	assert_eq(S4.promoted_of(school).size(), 0, "nothing left in school.promoted")
	assert_eq(S4.invariants(w), "", "bookkeeping consistent")


# ======================================================== the log reproduces the state

## 900 ticks, two schools, a player pinned to school 0 for 10 s then 200 m away; three promoted members are killed at
## tick 90. Checks the bookkeeping invariants after every tick and snapshots state at 150 / 450 / 900.
func _scenario(world_seed: int) -> Dictionary:
	var w: SimWorld = S4.school_world(world_seed, SIZE, SIZE, RESPAWN_S, S4.KELP, 2)
	if not S4.api_problems(w).is_empty():
		return {"w": w}  # the test reports the missing API through S4.require_api
	var s0: Object = S4.get_school(w, 0)
	var pid: int = S4.player_at_school(w, 0).id
	var pre: Callable = func(world: SimWorld) -> void:
		var t: int = world.tick
		if t < 300:
			S4.pin(world, pid, S4.center_at(s0, t))
		else:
			S4.pin(world, pid, S4.place(world, S4.center_at(s0, t), 200.0))
		if t == 90:
			var n: int = 0
			var list: Array[SimEntity] = S4.promoted_entities(world)
			list.sort_custom(func(a: SimEntity, b: SimEntity) -> bool: return a.id < b.id)
			for e: SimEntity in list:
				if n < 3:
					e.hp = 0.0
					n += 1
	var evs: Array[SimEvent] = []
	var violations: Array[String] = []
	var checkpoints: Array[Dictionary] = []
	for i in 900:
		pre.call(w)
		w.step()
		evs.append_array(w.events_since(w.tick - 1))
		var v: String = S4.invariants(w)
		if v != "" and violations.size() < 5:
			violations.append("tick %d: %s" % [w.tick, v])
		if i == 149 or i == 449 or i == 899:
			checkpoints.append({"events": evs.size(), "state": S4.snapshot(w)})
	return {"w": w, "events": evs, "violations": violations, "checkpoints": checkpoints}


func test_the_event_log_alone_reproduces_the_school_state() -> void:
	var r: Dictionary = _scenario(67)
	var w: SimWorld = r["w"]
	if not S4.require_api(self, w):
		return
	var evs: Array[SimEvent] = r["events"]
	var violations: Array[String] = r["violations"]
	assert_eq(violations.size(), 0, "school bookkeeping invariants held on every tick: %s" % [violations])
	var all_school: Array[SimEvent] = S4.school_events(evs)
	for name: String in ["SCHOOL_MEMBER_PROMOTED", "SCHOOL_MEMBER_EATEN", "SCHOOL_MEMBER_RESPAWNED", "SCHOOL_MEMBER_DEMOTED"]:
		assert_true(S4.events_named(evs, name).size() >= 1, "scenario is not vacuous: at least one %s" % name)
	assert_true(all_school.size() >= 12, "plenty of school events (%d)" % all_school.size())
	var sizes: Dictionary = S4.sizes_of(w)
	for cp: Dictionary in r["checkpoints"]:
		var upto: Array[SimEvent] = evs.slice(0, int(cp["events"]))
		var rebuilt: Dictionary = S4.replay(upto, sizes)
		var live: Dictionary = cp["state"]
		for sid: Variant in sizes.keys():
			assert_eq(rebuilt[sid]["alive"], live[sid]["alive"], "after %d events: replayed alive[] of school %s equals the live one" % [upto.size(), sid])
			assert_eq(rebuilt[sid]["promoted"], live[sid]["promoted"], "after %d events: replayed promoted set of school %s equals the live one" % [upto.size(), sid])


func test_applying_the_event_list_to_a_fresh_world_rebuilds_the_school_state() -> void:
	var r: Dictionary = _scenario(71)
	var w: SimWorld = r["w"]
	if not S4.require_api(self, w):
		return
	var fresh: SimWorld = S4.school_world(71, SIZE, SIZE, RESPAWN_S, S4.KELP, 2)
	S4.apply_events(fresh, r["events"])
	var live: Dictionary = S4.snapshot(w)
	var rebuilt: Dictionary = S4.snapshot(fresh)
	for sid: Variant in live.keys():
		assert_eq(rebuilt[sid]["alive"], live[sid]["alive"], "school %s: alive[] rebuilt by apply_event equals the live one" % sid)
		assert_eq(rebuilt[sid]["promoted"], live[sid]["promoted"], "school %s: promoted set rebuilt by apply_event equals the live one" % sid)
		assert_eq(S4.promoted_of(S4.get_school(fresh, int(sid))), S4.promoted_of(S4.get_school(w, int(sid))), "school %s: promoted member -> entity id map equals the live one" % sid)
		for field: String in ["pending_respawn", "pending_member"]:
			var live_p: PackedInt32Array = S4.get_school(w, int(sid)).get(field)
			var fresh_p: PackedInt32Array = S4.get_school(fresh, int(sid)).get(field)
			assert_eq(fresh_p, live_p, "school %s: %s rebuilt by apply_event equals the live one" % [sid, field])


func test_every_eaten_member_was_promoted_and_died_with_its_entity() -> void:
	var r: Dictionary = _scenario(68)
	var w: SimWorld = r["w"]
	if not S4.require_api(self, w):
		return
	var evs: Array[SimEvent] = r["events"]
	var eaten: Array[SimEvent] = S4.events_named(evs, "SCHOOL_MEMBER_EATEN")
	assert_true(eaten.size() >= 3, "the three scripted kills produced EATEN events (%d)" % eaten.size())
	var died_ids: Dictionary = {}
	for ev: SimEvent in evs:
		if int(ev.type) == int(SimEvent.Type.DIED):
			died_ids[ev.entity_id] = ev.tick
	for ev2: SimEvent in eaten:
		var sid: int = S4.ev_school(ev2)
		var k: int = S4.ev_k(ev2)
		var before_promoted: int = 0
		var before_demoted: int = 0
		var entity: int = -1
		for p: SimEvent in S4.member_events(evs, "SCHOOL_MEMBER_PROMOTED", sid, k):
			if p.tick <= ev2.tick:
				before_promoted += 1
				entity = int(p.data.get("entity", -1))
		for d: SimEvent in S4.member_events(evs, "SCHOOL_MEMBER_DEMOTED", sid, k):
			if d.tick <= ev2.tick:
				before_demoted += 1
		assert_true(before_promoted > before_demoted, "member %d/%d: eaten only while promoted (an ambient member cannot be eaten)" % [sid, k])
		assert_true(died_ids.has(entity), "member %d/%d: the entity %d has a DIED event" % [sid, k, entity])
	# Each respawn follows an eaten event of the same member by respawn_s.
	var delay: int = S3.ticks(RESPAWN_S)
	for ev3: SimEvent in S4.events_named(evs, "SCHOOL_MEMBER_RESPAWNED"):
		var matches: int = 0
		for e4: SimEvent in S4.member_events(evs, "SCHOOL_MEMBER_EATEN", S4.ev_school(ev3), S4.ev_k(ev3)):
			if absi((ev3.tick - e4.tick) - delay) <= 1:
				matches += 1
		assert_eq(matches, 1, "respawn of member %d/%d at tick %d follows one loss by %d ticks" % [S4.ev_school(ev3), S4.ev_k(ev3), ev3.tick, delay])


func test_the_same_run_twice_gives_the_same_log_state_and_hash() -> void:
	var a: Dictionary = _scenario(69)
	var wa: SimWorld = a["w"]
	if not S4.require_api(self, wa):
		return
	var b: Dictionary = _scenario(69)
	var wb: SimWorld = b["w"]
	assert_eq(S4.signature(a["events"]), S4.signature(b["events"]), "identical event logs (including data)")
	assert_eq(S4.snapshot(wa), S4.snapshot(wb), "identical school state")
	assert_eq(wa.state_hash(), wb.state_hash(), "identical state_hash")
	var c: Dictionary = _scenario(70)
	var ka: Array[SimEvent] = S4.events_named(a["events"], "SCHOOL_MEMBER_PROMOTED")
	var kc: Array[SimEvent] = S4.events_named(c["events"], "SCHOOL_MEMBER_PROMOTED")
	assert_true(ka.size() >= 1 and kc.size() >= 1, "both seeds promote members")
	assert_ne((c["w"] as SimWorld).state_hash(), wa.state_hash(), "another world seed gives another state")
