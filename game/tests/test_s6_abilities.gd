extends TestCase
## S6 abilities (GAME_DESIGN section 4, contract "Abilities"): Bite-Dash and Sonar are locked until a node grants them;
## Bite-Dash lunges lunge_distance_m along the heading and ends in a bite; Sonar emits SONAR_PULSE with radius,
## duration and contacts classified smaller / similar / bigger by the data thresholds; both obey cooldown_s and expose
## SimWorld.ability_cooldown_left(). Every number comes from game/data/abilities/*.json.

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const DASH: StringName = &"bite_dash"
const SONAR: StringName = &"sonar"
## B3 player: big enough to bite a 1.5 m grouper, small enough to stay in the arena.
const PLAYER_XP: float = 500.0


func _rig(world_seed: int, abilities: Array = []) -> Dictionary:
	var r: Dictionary = S6.arena_player(world_seed, PLAYER_XP)
	var p: SimEntity = r["p"]
	for a: Variant in abilities:
		S6.give_ability(r["w"], p, str(a))
	return r


func _lunge_ticks(db: ContentDB) -> int:
	return int(ceil(S6.ability_f(db, DASH, "lunge_duration_s", 0.35) * float(S6.TICKS_PER_S)))


## Uses of `ability` inside an event list: ABILITY_USED with data.ability for Bite-Dash, SONAR_PULSE for Sonar.
func _uses(evs: Array[SimEvent], ability: StringName) -> int:
	var n: int = 0
	if ability == SONAR:
		return S6.count_named(evs, "SONAR_PULSE")
	for ev: SimEvent in S6.events_named(evs, "ABILITY_USED"):
		if str(ev.data.get("ability", "")) == String(ability):
			n += 1
	return n


# ======================================================== locked until granted

func test_abilities_are_locked_until_granted() -> void:
	var r: Dictionary = _rig(61)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var start: Vector3 = p.position
	w.submit(SimCommand.ability(p.id, DASH))
	w.submit(SimCommand.ability(p.id, SONAR))
	var evs: Array[SimEvent] = S6.run(w, 60)
	assert_eq(_uses(evs, DASH), 0, "Bite-Dash does nothing before hunter_bite_dash")
	assert_eq(_uses(evs, SONAR), 0, "Sonar does nothing before survivor_sonar")
	assert_eq(S6.count_named(evs, "ABILITY_USED"), 0, "no ABILITY_USED at all")
	assert_true(p.position.distance_to(start) < 0.5, "a locked Bite-Dash does not move the fish (moved %s m)" % str(p.position.distance_to(start)))
	assert_eq(S6.cooldown_left(w, p.id, DASH), 0.0, "no cooldown started by a locked ability")
	assert_eq(S6.cooldown_left(w, p.id, SONAR), 0.0, "no cooldown started by a locked ability")


func test_each_node_unlocks_only_its_own_ability() -> void:
	var r: Dictionary = _rig(62, ["bite_dash"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	w.submit(SimCommand.ability(p.id, SONAR))
	var evs: Array[SimEvent] = S6.run(w, 5)
	assert_eq(_uses(evs, SONAR), 0, "owning Bite-Dash does not unlock Sonar")
	w.submit(SimCommand.ability(p.id, DASH))
	evs = S6.run(w, 5)
	assert_eq(_uses(evs, DASH), 1, "Bite-Dash works once granted")


func test_unknown_ability_ids_and_cooldown_query_of_unknown_ids() -> void:
	var r: Dictionary = _rig(63, ["bite_dash", "sonar"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	w.submit(SimCommand.ability(p.id, &"no_such_ability"))
	var evs: Array[SimEvent] = S6.run(w, 5)
	assert_eq(S6.count_named(evs, "ABILITY_USED"), 0, "unknown ability id is ignored")
	assert_eq(S6.cooldown_left(w, p.id, &"no_such_ability"), 0.0, "cooldown of an unknown ability is 0")
	assert_eq(S6.cooldown_left(w, 999999, DASH), 0.0, "cooldown of an unknown entity is 0")
	assert_eq(S6.cooldown_left(w, p.id, &"boost"), 0.0, "Boost has no cooldown (cooldown_s 0)")


# ======================================================== Bite-Dash

func test_dash_lunges_the_data_distance_along_the_heading() -> void:
	for heading in [Vector3.RIGHT, Vector3(0.6, 0.0, 0.8), Vector3(0.0, 0.6, 0.8)]:
		var r: Dictionary = _rig(64, ["bite_dash"])
		var w: SimWorld = r["w"]
		var p: SimEntity = r["p"]
		if not S6.require_api(self, w):
			return
		var h: Vector3 = (heading as Vector3).normalized()
		p.heading = h
		var db: ContentDB = w.content
		var dist: float = S6.ability_f(db, DASH, "lunge_distance_m")
		var start: Vector3 = p.position
		var track: Array[Vector3] = []
		w.submit(SimCommand.ability(p.id, DASH))
		var evs: Array[SimEvent] = S6.run(w, 90, {}, [], func(_w: SimWorld) -> void: track.append(p.position))
		assert_eq(_uses(evs, DASH), 1, "one ABILITY_USED for heading %s" % str(h))
		var used: Array[SimEvent] = S6.events_named(evs, "ABILITY_USED")
		if used.size() == 1:
			assert_eq(used[0].entity_id, p.id, "the event is about the player")
		var n_end: int = _lunge_ticks(db) + 2
		var moved: Vector3 = track[n_end] - start
		var along: float = moved.dot(h)
		assert_true(absf(along - dist) <= 0.05 * dist, "heading %s: lunge covers lunge_distance_m %s +-5%% by the end of the lunge, got %s" % [str(h), str(dist), str(along)])
		var lateral: float = (moved - h * along).length()
		assert_true(lateral < 0.05 * dist + 0.3, "heading %s: the lunge is straight along the heading (lateral %s m)" % [str(h), str(lateral)])
		var late: float = (track[89] - start).dot(h)
		assert_true(late <= 1.3 * dist, "heading %s: no runaway after the lunge: %s m after 3 s (exit_speed_frac makes the fish crawl; impl measured 8.4-9.6 m for lunge_distance_m %s)" % [str(h), str(late), str(dist)])


func test_dash_ends_in_a_bite_on_the_target_ahead() -> void:
	var r: Dictionary = _rig(65, ["bite_dash"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var db: ContentDB = w.content
	var dist: float = S6.ability_f(db, DASH, "lunge_distance_m")
	var t: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (dist + 0.5), 1.5)
	var t_id: int = t.id
	w.submit(SimCommand.ability(p.id, DASH))
	var evs: Array[SimEvent] = S6.run(w, _lunge_ticks(db) + 20, {t_id: t.position})
	var used: Array[SimEvent] = S6.events_named(evs, "ABILITY_USED")
	var bites: Array[SimEvent] = []
	for ev: SimEvent in S6.events_named(evs, "BITTEN"):
		if ev.entity_id == t_id and ev.other_id == p.id:
			bites.append(ev)
	assert_eq(used.size(), 1, "test setup: the dash was used")
	assert_eq(bites.size(), 1, "the dash ends in exactly one bite on the target")
	if bites.size() == 1 and used.size() == 1:
		assert_true(bites[0].tick >= used[0].tick + _lunge_ticks(db) - 3, "the bite lands at the END of the lunge (tick %d, used %d, lunge %d ticks)" % [bites[0].tick, used[0].tick, _lunge_ticks(db)])
		var normal: float = S6.normal_bite_damage(db, S3.PLAYER_SPECIES, p.band, p.length_m)
		assert_almost_eq(bites[0].value, normal, normal * 1e-6, "the dash bite follows the normal bite rules (assumption A7)")


func test_dash_bite_ignores_the_bite_cooldown_once() -> void:
	var r: Dictionary = _rig(66, ["bite_dash"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var db: ContentDB = w.content
	var dist: float = S6.ability_f(db, DASH, "lunge_distance_m")
	# near: in plain bite range at the start; far: where the lunge ends
	var near: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (0.5 * S3.reach_m(w, p)), 1.5)
	var far: SimEntity = S3.npc_at(w, &"grouper", p.position + p.heading * (dist + 0.5), 1.5)
	var pins: Dictionary = {near.id: near.position, far.id: far.position}
	p.bite_ready_tick = w.tick + 10000
	w.submit(SimCommand.bite(p.id, near.id))
	var plain: Array[SimEvent] = S6.run(w, 3, pins)
	var blocked: int = 0
	for ev: SimEvent in plain:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == p.id:
			blocked += 1
	assert_eq(blocked, 0, "test setup: a plain BITE is blocked by the cooldown")
	w.submit(SimCommand.ability(p.id, DASH))
	var evs: Array[SimEvent] = S6.run(w, _lunge_ticks(db) + 20, pins)
	var landed: int = 0
	for ev2: SimEvent in evs:
		if ev2.type == SimEvent.Type.BITTEN and ev2.entity_id == far.id and ev2.other_id == p.id:
			landed += 1
	assert_eq(landed, 1, "the dash bite lands although the bite cooldown has not elapsed")


func test_dash_without_a_target_ends_without_a_bite() -> void:
	var r: Dictionary = _rig(67, ["bite_dash"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	w.submit(SimCommand.ability(p.id, DASH))
	var evs: Array[SimEvent] = S6.run(w, 60)
	assert_eq(_uses(evs, DASH), 1, "used")
	assert_eq(S6.count_named(evs, "BITTEN"), 0, "no target, no bite")
	assert_true(p.alive and p.hp > 0.0, "the player is fine")


func test_dash_cooldown() -> void:
	_check_cooldown(68, DASH, ["bite_dash"])


# ======================================================== Sonar

func _spawn_contact(w: SimWorld, p: SimEntity, ratio: float, dist: float, deg: float) -> SimEntity:
	var pos: Vector3 = p.position + S6.yaw_dir(Vector3.RIGHT, deg) * dist
	return S3.npc_at(w, &"grouper", pos, p.length_m * ratio)


func _contacts(ev: SimEvent) -> Dictionary:
	var out: Dictionary = {}
	var v: Variant = ev.data.get("contacts")
	if v is Array:
		for c_v: Variant in v:
			if c_v is Dictionary:
				out[int((c_v as Dictionary).get("id", -1))] = str((c_v as Dictionary).get("rel", ""))
	return out


func test_sonar_pulse_reports_radius_duration_and_contacts() -> void:
	var r: Dictionary = _rig(71, ["sonar"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var db: ContentDB = w.content
	var radius: float = S6.ability_f(db, SONAR, "radius_m")
	var small: SimEntity = _spawn_contact(w, p, 0.5, 10.0, 0.0)
	var same: SimEntity = _spawn_contact(w, p, 1.0, 20.0, -30.0)
	var big: SimEntity = _spawn_contact(w, p, 2.0, 30.0, -60.0)
	var edge_in: SimEntity = _spawn_contact(w, p, 1.0, radius - 6.0, -15.0)
	var out_of_range: SimEntity = _spawn_contact(w, p, 1.0, radius + 8.0, -45.0)
	var pins: Dictionary = {}
	for e: SimEntity in [small, same, big, edge_in, out_of_range]:
		pins[e.id] = e.position
	w.submit(SimCommand.ability(p.id, SONAR))
	var evs: Array[SimEvent] = S6.run(w, 4, pins)
	var pulses: Array[SimEvent] = S6.events_named(evs, "SONAR_PULSE")
	assert_eq(pulses.size(), 1, "exactly one SONAR_PULSE")
	if pulses.size() != 1:
		return
	var ev: SimEvent = pulses[0]
	assert_eq(ev.entity_id, p.id, "the pulse is about the player")
	assert_almost_eq(float(ev.data.get("radius", -1.0)), radius, 1e-6, "data.radius = radius_m")
	assert_almost_eq(float(ev.data.get("duration", -1.0)), S6.ability_f(db, SONAR, "duration_s"), 1e-6, "data.duration = duration_s")
	var contacts: Dictionary = _contacts(ev)
	assert_eq(contacts.get(small.id, ""), "smaller", "half the player's length is 'smaller'")
	assert_eq(contacts.get(same.id, ""), "similar", "equal length is 'similar'")
	assert_eq(contacts.get(big.id, ""), "bigger", "twice the length is 'bigger'")
	assert_true(contacts.has(edge_in.id), "a creature just inside the radius is a contact")
	assert_false(contacts.has(out_of_range.id), "a creature outside the radius is not")
	assert_false(contacts.has(p.id), "the player is not its own contact")
	assert_eq(contacts.size(), 4, "exactly the four creatures in range")


func test_sonar_classification_thresholds_come_from_data() -> void:
	var r: Dictionary = _rig(72, ["sonar"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var th: Dictionary = S6.sonar_thresholds(w.content)
	if is_nan(float(th["smaller"])) or is_nan(float(th["bigger"])):
		fail("data: the sonar ability record carries the 'smaller' and 'bigger' ratio thresholds (key names containing 'smaller' / 'bigger'; contract: thresholds in data), got %s" % str(w.content.get_ability(SONAR)))
		return
	var ts: float = th["smaller"]
	var tb: float = th["bigger"]
	assert_true(ts < 1.0 and tb > 1.0, "data: smaller < 1 < bigger (%s, %s)" % [str(ts), str(tb)])
	var cases: Array = [[ts * 0.95, "smaller"], [ts * 1.05, "similar"], [tb * 0.95, "similar"], [tb * 1.05, "bigger"]]
	var ids: Array[int] = []
	var pins: Dictionary = {}
	for i in cases.size():
		var e: SimEntity = _spawn_contact(w, p, float((cases[i] as Array)[0]), 12.0 + 3.0 * float(i), -20.0 * float(i))
		ids.append(e.id)
		pins[e.id] = e.position
	w.submit(SimCommand.ability(p.id, SONAR))
	var evs: Array[SimEvent] = S6.run(w, 4, pins)
	var pulses: Array[SimEvent] = S6.events_named(evs, "SONAR_PULSE")
	if pulses.size() != 1:
		fail("expected one SONAR_PULSE, got %d" % pulses.size())
		return
	var contacts: Dictionary = _contacts(pulses[0])
	for i in cases.size():
		var case_a: Array = cases[i]
		assert_eq(contacts.get(ids[i], ""), case_a[1], "ratio %s is '%s'" % [str(case_a[0]), case_a[1]])


func test_sonar_contacts_follow_the_players_current_size() -> void:
	# The same creature is 'bigger' for a B3 player and 'smaller' for a B4 player (relative, not absolute).
	var rel_b3: String = ""
	var rel_b4: String = ""
	for xp in [PLAYER_XP, 1200.0]:
		var r: Dictionary = S6.arena_player(73, xp)
		var w: SimWorld = r["w"]
		var p: SimEntity = r["p"]
		S6.give_ability(w, p, "sonar")
		if not S6.require_api(self, w):
			return
		var c: SimEntity = S3.npc_at(w, &"grouper", p.position + Vector3(0.0, 0.0, -10.0), 2.0)
		w.submit(SimCommand.ability(p.id, SONAR))
		var evs: Array[SimEvent] = S6.run(w, 4, {c.id: c.position})
		var pulses: Array[SimEvent] = S6.events_named(evs, "SONAR_PULSE")
		var rel: String = _contacts(pulses[0]).get(c.id, "") if pulses.size() == 1 else "no pulse"
		if xp == PLAYER_XP:
			rel_b3 = rel
		else:
			rel_b4 = rel
	assert_true(rel_b3 == "bigger" or rel_b3 == "similar", "a 2 m grouper is not smaller than a B3 player (got '%s')" % rel_b3)
	assert_eq(rel_b4, "smaller", "a 2 m grouper is smaller than a 3.5 m B4 player (ratio 0.57 < the data threshold)")


func test_sonar_cooldown() -> void:
	_check_cooldown(74, SONAR, ["sonar"])


# ======================================================== shared cooldown contract

## Use -> cooldown_s on the clock -> counts down monotonically -> a second use is ignored -> works again after cooldown_s.
func _check_cooldown(world_seed: int, ability: StringName, grants: Array) -> void:
	var r: Dictionary = _rig(world_seed, grants)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	if not S6.require_api(self, w):
		return
	var db: ContentDB = w.content
	var cd: float = S6.ability_f(db, ability, "cooldown_s")
	assert_true(cd > 0.0, "data: %s has a cooldown" % String(ability))
	w.submit(SimCommand.ability(p.id, ability))
	var first: Array[SimEvent] = S6.run(w, 2)
	assert_eq(_uses(first, ability), 1, "%s: first use" % String(ability))
	var left0: float = S6.cooldown_left(w, p.id, ability)
	assert_true(left0 <= cd + 1e-6 and left0 >= cd - 0.2, "%s: cooldown_left right after use is cooldown_s %s, got %s" % [String(ability), str(cd), str(left0)])
	# count down: monotonic, one second of ticks removes one second (+-0.1)
	var seen_left: Array[float] = []
	S6.run(w, S6.TICKS_PER_S, {}, [], func(_w: SimWorld) -> void: seen_left.append(S6.cooldown_left(w, p.id, ability)))
	var monotonic: bool = true
	for i in range(1, seen_left.size()):
		if seen_left[i] > seen_left[i - 1] + 1e-6:
			monotonic = false
	assert_true(monotonic, "%s: cooldown_left never increases while counting down" % String(ability))
	assert_almost_eq(left0 - seen_left[seen_left.size() - 1], 1.0, 0.1, "%s: one second later the cooldown is one second shorter" % String(ability))
	# second use inside the cooldown: ignored
	w.submit(SimCommand.ability(p.id, ability))
	var blocked: Array[SimEvent] = S6.run(w, 10)
	assert_eq(_uses(blocked, ability), 0, "%s: a use inside the cooldown is ignored" % String(ability))
	# the clock keeps running to zero and stays there
	var elapsed_ticks: int = 2 + S6.TICKS_PER_S + 10
	var remaining: int = int(ceil(cd * float(S6.TICKS_PER_S))) - elapsed_ticks + 15
	S6.run(w, maxi(remaining, 0))
	assert_eq(S6.cooldown_left(w, p.id, ability), 0.0, "%s: cooldown_left is 0 once cooldown_s has elapsed" % String(ability))
	w.submit(SimCommand.ability(p.id, ability))
	var again: Array[SimEvent] = S6.run(w, 3)
	assert_eq(_uses(again, ability), 1, "%s: usable again after the cooldown" % String(ability))
	assert_true(S6.cooldown_left(w, p.id, ability) > cd - 0.3, "%s: the cooldown restarts" % String(ability))


func test_two_players_have_independent_cooldowns() -> void:
	var r: Dictionary = _rig(75, ["sonar"])
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	var q: SimEntity = S3.player_at(w, S3.ARENA + Vector3(0.0, 0.0, 30.0), PLAYER_XP)
	S6.give_ability(w, q, "sonar")
	if not S6.require_api(self, w):
		return
	w.submit(SimCommand.ability(p.id, SONAR))
	S6.run(w, 3)
	assert_true(S6.cooldown_left(w, p.id, SONAR) > 0.0, "player p is cooling down")
	assert_eq(S6.cooldown_left(w, q.id, SONAR), 0.0, "player q is not")
	w.submit(SimCommand.ability(q.id, SONAR))
	var evs: Array[SimEvent] = S6.run(w, 3)
	assert_eq(S6.count_named(evs, "SONAR_PULSE"), 1, "q can use Sonar while p cools down")
