extends TestCase
## F1 bite feel (tasks/fix-bite-feel.md): player bite buffer (rules.bite_buffer_s), hold-repeat (one BITE per tick),
## player-only bite cone (rules.bite_reach_mult / bite_cone_deg; NPCs keep the mouth values), the throttled
## BITE_MISSED cue (rules.bite_miss_cooldown_s), the -20% passive-prey flee distances, and the hash contract.
## The PlayerInput side of hold-repeat (re-submit while `bite` is held, arming guard) is a node and is checked by hand;
## here the sim half is tested: a BITE submitted every tick.
## Geometry as in test_s3_eat_bite.gd: the player in mid-water (S3.ARENA) facing +X, targets pinned (S3.step_n) at an
## exact centre distance / angle off the heading. Durable victims are 6x the player's length (never swallowed).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")
const SEED: int = 31
const RULES_SOURCE: String = "rules/core.json"
const F1_KEYS: Array[String] = ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s"]
## The pre-F1 bite: mouth geometry, single-tick press.
const OLD_RULES: Dictionary = {"bite_reach_mult": 0.8, "bite_cone_deg": 45.0, "bite_buffer_s": 0.0}


func _buffer_ticks(w: SimWorld) -> int:
	return S3.ticks(S3.rule_f(w.content, "bite_buffer_s"))


func _miss_cd_ticks(w: SimWorld) -> int:
	return S3.ticks(S3.rule_f(w.content, "bite_miss_cooldown_s"))


func _player(w: SimWorld, length_m: float) -> SimEntity:
	return S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


## Point at centre distance `dist` from `e`, `deg` degrees off its heading (around +Y).
func _at(e: SimEntity, dist: float, deg: float = 0.0) -> Vector3:
	return e.position + e.heading.rotated(Vector3.UP, deg_to_rad(deg)) * dist


## Durable passive victim (6x the player's length) at `pos`.
func _victim(w: SimWorld, p: SimEntity, pos: Vector3) -> SimEntity:
	return S3.npc_at(w, &"small_reef_fish", pos, p.length_m * 6.0, -p.heading)


func _inside(w: SimWorld, p: SimEntity) -> Vector3:
	return _at(p, S3.bite_reach_m(w, p) * 0.5)


func _outside(w: SimWorld, p: SimEntity) -> Vector3:
	return _at(p, S3.bite_reach_m(w, p) * 0.5, S3.bite_half_cone_deg(w) + 30.0)


func _bites_by(evs: Array[SimEvent], biter: int, victim: int = -1) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == biter and (victim < 0 or ev.entity_id == victim):
			out.append(ev)
	return out


func _misses_of(evs: Array[SimEvent], id: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITE_MISSED and ev.entity_id == id:
			out.append(ev)
	return out


func _all_misses(evs: Array[SimEvent]) -> int:
	var n: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITE_MISSED:
			n += 1
	return n


# ======================================================== data

func test_shipped_bite_rules_are_inside_the_director_ranges() -> void:
	var db: ContentDB = S3.content()
	for key in F1_KEYS:
		assert_not_null(S3.rule(db, key), "rules/core.json has %s" % key)
	var reach: float = S3.rule_f(db, "bite_reach_mult")
	var cone: float = S3.rule_f(db, "bite_cone_deg")
	var buffer: float = S3.rule_f(db, "bite_buffer_s")
	var miss_cd: float = S3.rule_f(db, "bite_miss_cooldown_s")
	assert_true(reach >= 1.3 and reach <= 2.0, "bite_reach_mult in the Director's 1.3-2.0 range (got %s)" % reach)
	assert_true(cone >= 45.0 and cone <= 90.0, "bite_cone_deg in 45..90 (got %s)" % cone)
	assert_true(buffer > 0.0 and buffer <= 0.5, "bite_buffer_s in (0, 0.5] (got %s)" % buffer)
	assert_true(miss_cd > 0.0, "bite_miss_cooldown_s > 0: a held button must not cue every tick (got %s)" % miss_cd)
	assert_true(reach > S3.rule_f(db, "mouth_reach_mult"), "the bite reaches farther than the swallow mouth")
	assert_true(cone > S3.rule_f(db, "mouth_cone_deg"), "the bite cone is wider than the swallow mouth")
	assert_eq(S3.ticks(buffer), 6, "start value 0.2 s = 6 ticks")


func test_bite_rule_keys_are_optional_and_validated() -> void:
	var rec: Dictionary = S3.content().rules().duplicate(true)
	for key in F1_KEYS:
		rec.erase(key)
	var errs: PackedStringArray = ContentDB.validate_record(&"rules", rec, RULES_SOURCE)
	assert_eq(errs.size(), 0, "the F1 keys are optional (got %s)" % [errs])
	var bad: Array = [["bite_reach_mult", 0.0], ["bite_reach_mult", -1.0], ["bite_reach_mult", "far"], ["bite_cone_deg", 0.0],
		["bite_cone_deg", 200.0], ["bite_buffer_s", -0.1], ["bite_buffer_s", "soon"], ["bite_miss_cooldown_s", -1.0]]
	for case: Array in bad:
		var r: Dictionary = S3.content().rules().duplicate(true)
		r[case[0]] = case[1]
		var e2: PackedStringArray = ContentDB.validate_record(&"rules", r, RULES_SOURCE)
		var named: bool = false
		for msg: String in e2:
			named = named or (msg.begins_with(RULES_SOURCE + ": ") and msg.find(str(case[0])) != -1)
		assert_true(named, "%s = %s is rejected with '<source>: %s: ...' (got %s)" % [case[0], case[1], case[0], e2])


func test_missing_bite_keys_fall_back_to_the_mouth_cone() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for key in F1_KEYS:
		db.rules().erase(key)
	db.get_map(S3.MAP_ID)["spawners"] = []
	var w := SimWorld.new(SEED, db)
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = _victim(w, p, p.position + Vector3(0.0, 0.0, 10.0))
	var mouth: float = S3.rule_f(db, "mouth_reach_mult")
	# beyond the mouth reach, inside what 1.5x would give
	var pos: Vector3 = _at(p, w.collision_radius(v) + p.length_m * mouth * 1.4)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 3, {v.id: pos})
	assert_eq(_bites_by(evs, p.id).size(), 0, "without bite_reach_mult the player bite is the mouth reach")
	assert_eq(_misses_of(evs, p.id).size(), 1, "without bite_buffer_s the press is single-tick (one miss cue, then gone)")


func test_passive_prey_flee_distances_are_cut_by_20_percent_and_speed_is_unchanged() -> void:
	var db: ContentDB = S3.content()
	# S7 values: small_reef 5 / 2.5, silver 6 / 3 (x0.8); swim_speed_mps (= flee speed) deliberately unchanged
	var expect: Dictionary = {&"small_reef_fish": [4.0, 2.0, 2.0], &"silver_schooling_fish": [4.8, 2.4, 2.5]}
	for sid: StringName in expect.keys():
		var sp: Dictionary = db.get_species(sid)
		var want: Array = expect[sid]
		assert_almost_eq(float(sp["flee_radius_m"]), float(want[0]), 1e-9, "%s flee_radius_m = 0.8 x S7" % sid)
		assert_almost_eq(float((sp["behaviour"] as Dictionary)["boost_within_m"]), float(want[1]), 1e-9, "%s behaviour.boost_within_m = 0.8 x S7" % sid)
		assert_almost_eq(float(sp["swim_speed_mps"]), float(want[2]), 1e-9, "%s swim_speed_mps unchanged (no panic-speed key; out of scope)" % sid)


# ======================================================== buffer

## One BITE(-1) press; the victim sits outside the cone for `k` ticks, then inside. Returns the player's bites.
func _press_then_enter(k: int, opts: Dictionary = {}) -> int:
	var w: SimWorld = S3.make_world(SEED, opts)
	var p: SimEntity = _player(w, 0.5)
	var outside: Vector3 = _outside(w, p)
	var v: SimEntity = _victim(w, p, outside)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, k, {v.id: outside})
	evs.append_array(S3.step_n(w, 3, {v.id: _inside(w, p)}))
	return _bites_by(evs, p.id, v.id).size()


func test_a_press_fires_when_the_target_enters_the_cone_within_the_buffer() -> void:
	var b: int = _buffer_ticks(S3.make_world(SEED))
	assert_true(b >= 1, "precondition: a buffer of at least one tick (got %d)" % b)
	for k in [0, 1, b]:
		assert_eq(_press_then_enter(k), 1, "target enters the cone %d ticks after the press (buffer %d): bitten" % [k, b])
	assert_eq(_press_then_enter(b + 1), 0, "target enters %d ticks after the press: the buffer is over" % (b + 1))


func test_a_press_waits_out_the_cooldown_within_the_buffer() -> void:
	var b: int = _buffer_ticks(S3.make_world(SEED))
	for r in [1, b, b + 1]:
		var w: SimWorld = S3.make_world(SEED)
		var p: SimEntity = _player(w, 0.5)
		var v: SimEntity = _victim(w, p, _inside(w, p))
		var t0: int = w.tick
		p.bite_ready_tick = t0 + r
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = S3.step_n(w, b + 4, {v.id: v.position})
		var bites: Array[SimEvent] = _bites_by(evs, p.id, v.id)
		if r <= b:
			assert_eq(bites.size(), 1, "cooldown ends %d ticks after the press: the buffered press fires" % r)
			if bites.size() == 1:
				assert_eq(bites[0].tick, t0 + r, "on the first ready tick")
		else:
			assert_eq(bites.size(), 0, "cooldown ends %d ticks after the press (buffer %d): dropped" % [r, b])
		assert_eq(_misses_of(evs, p.id).size(), 0, "r=%d: no miss cue while the bite is on cooldown" % r)
		assert_eq(p.bite_request, SimWorld.NO_BITE, "r=%d: nothing pending afterwards" % r)


func test_without_a_buffer_a_press_lives_for_one_tick() -> void:
	var opts: Dictionary = {"rules": {"bite_buffer_s": 0.0}}
	assert_eq(_press_then_enter(0, opts), 1, "buffer 0: target already in the cone is bitten")
	assert_eq(_press_then_enter(1, opts), 0, "buffer 0: one tick later is too late (the S3 behaviour)")


# ======================================================== hold-repeat (sim half)

func test_held_bite_repeats_at_the_cooldown_rate() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var cd: int = S3.ticks(S3.rule_f(w.content, "bite_cooldown_s"))
	assert_true(cd >= 1, "precondition: bite_cooldown_s > 0")
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = _victim(w, p, _inside(w, p))
	var evs: Array[SimEvent] = []
	for i in 150:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: v.position}, [v.id]))
	var bites: Array[SimEvent] = _bites_by(evs, p.id, v.id)
	var expected: int = ceili(150.0 / float(cd))
	assert_true(absi(bites.size() - expected) <= 1, "5 s held = about %d bites at %d ticks cooldown, got %d" % [expected, cd, bites.size()])
	for i in range(1, bites.size()):
		assert_true(bites[i].tick - bites[i - 1].tick >= cd, "bites at least the cooldown apart")
	assert_eq(_misses_of(evs, p.id).size(), 0, "a target always in the cone never produces a miss cue")


# ======================================================== bite geometry

func test_player_bite_reach_and_cone_are_the_bite_values() -> void:
	var w0: SimWorld = S3.make_world(SEED)
	var m: float = S3.rule_f(w0.content, "mouth_reach_mult")
	var b: float = S3.rule_f(w0.content, "bite_reach_mult")
	var mc: float = S3.half_cone_deg(w0)
	var bc: float = S3.bite_half_cone_deg(w0)
	assert_true(b > m and bc > mc, "precondition: bite cone wider than the mouth (%s/%s vs %s/%s)" % [b, bc, m, mc])
	# [label, centre distance in player lengths beyond the target radius, degrees off the heading, hit]
	var cases: Array = [["between mouth and bite reach", (m + b) * 0.5, 0.0, true], ["beyond the bite reach", b * 1.1 + 0.1, 0.0, false],
		["between mouth and bite cone", m * 0.5, (mc + bc) * 0.5, true], ["outside the bite cone", m * 0.5, bc + 10.0, false]]
	for c: Array in cases:
		var w: SimWorld = S3.make_world(SEED)
		var p: SimEntity = _player(w, 0.5)
		var v: SimEntity = _victim(w, p, p.position + Vector3(0.0, 0.0, 10.0))
		var pos: Vector3 = _at(p, w.collision_radius(v) + p.length_m * float(c[1]), float(c[2]))
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = S3.step_n(w, 2, {v.id: pos})
		assert_eq(_bites_by(evs, p.id, v.id).size(), 1 if bool(c[3]) else 0, "%s: %s" % [c[0], "bitten" if bool(c[3]) else "not bitten"])


func test_the_swallow_keeps_the_mouth_reach() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var p: SimEntity = _player(w, 1.0)
	var m: float = S3.rule_f(w.content, "mouth_reach_mult")
	var b: float = S3.rule_f(w.content, "bite_reach_mult")
	var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _at(p, p.length_m * (m + b) * 0.5), 0.08)
	var evs: Array[SimEvent] = []
	for i in 5:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {snack.id: snack.position}))
	assert_false(S3.is_gone(w, snack.id), "a swallowable fish between mouth and bite reach is not swallowed")
	assert_eq(_bites_by(evs, p.id).size(), 0, "and not bitten (BITE(-1) skips swallowable creatures)")


func test_npc_bites_keep_the_mouth_geometry_and_one_tick() -> void:
	for c in ["between mouth and bite reach", "inside the mouth reach", "enters one tick late"]:
		var w: SimWorld = S3.make_world(SEED)
		w.brains_enabled = false  # the NPC biter acts only through the test's commands
		var n: SimEntity = S3.npc_at(w, &"grouper", S3.ARENA, 1.0, Vector3.RIGHT)
		var v: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(0.0, 0.0, 15.0), 6.0, Vector3.LEFT)
		var m: float = S3.rule_f(w.content, "mouth_reach_mult")
		var b: float = S3.rule_f(w.content, "bite_reach_mult")
		var r: float = w.collision_radius(v)
		var near: Vector3 = _at(n, r + n.length_m * m * 0.5)
		w.submit(SimCommand.bite(n.id, v.id))
		var evs: Array[SimEvent] = []
		match c:
			"between mouth and bite reach":
				evs = S3.step_n(w, 3, {v.id: _at(n, r + n.length_m * (m + b) * 0.5)})
			"inside the mouth reach":
				evs = S3.step_n(w, 3, {v.id: near})
			_:
				evs = S3.step_n(w, 1, {v.id: _at(n, r + n.length_m * m * 0.5, S3.half_cone_deg(w) + 30.0)})
				evs.append_array(S3.step_n(w, 3, {v.id: near}))
		assert_eq(_bites_by(evs, n.id, v.id).size(), 1 if c == "inside the mouth reach" else 0, "NPC bite, %s" % c)
		assert_eq(_all_misses(evs), 0, "%s: no BITE_MISSED for an NPC" % c)


# ======================================================== human model (acceptance scenario)

## Player 0.20 m boosting after a fleeing small_reef_fish (0.12 m, full stamina, 1 m ahead, brains on), aiming at
## where the prey was 3 ticks ago (human reaction lag); ONE BITE(-1) at `click` (-1 = none). Returns
## {"hit": tick of the bite on the prey or -1, "new_cone": ticks the prey was inside the 1.5x/60 cone, "old_cone": ...
## inside the 0.8x/45 mouth cone} (cone ticks only up to the first hit).
func _chase(click: int, opts: Dictionary = {}) -> Dictionary:
	var w: SimWorld = S3.make_world(5, opts)
	var p: SimEntity = S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, 0.20), Vector3.RIGHT)
	var t: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(1.0, 0.0, 0.0), 0.12, Vector3.RIGHT)
	t.stamina = float(w.content.get_ability(&"boost").get("stamina_max", 100.0))
	w.submit(SimCommand.boost(p.id, true))
	if click >= 0:
		w.submit(SimCommand.bite(p.id, -1, click))
	var hist: Array[Vector3] = []
	var new_cone: Array[int] = []
	var old_cone: Array[int] = []
	var hit: int = -1
	for i in 90:
		hist.append(t.position if w.get_entity(t.id) != null else hist[-1])
		var aim: Vector3 = hist[maxi(hist.size() - 4, 0)]
		w.submit(SimCommand.move(p.id, (aim - p.position).normalized(), 1.0))
		var tk: int = w.tick
		w.step()
		if hit < 0 and _bites_by(w.events_since(tk), p.id, t.id).size() > 0:
			hit = tk
		if hit < 0 and w.get_entity(t.id) != null:
			var r: float = w.collision_radius(t)
			if SimRules.in_cone(p.position, p.heading, t.position, p.length_m * 1.5 + r, cos(deg_to_rad(60.0))):
				new_cone.append(tk)
			if SimRules.in_cone(p.position, p.heading, t.position, p.length_m * 0.8 + r, cos(deg_to_rad(45.0))):
				old_cone.append(tk)
	return {"hit": hit, "new_cone": new_cone, "old_cone": old_cone}


func test_human_model_click_on_a_fleeing_prey_lands_now_and_failed_before() -> void:
	var db: ContentDB = S3.content()
	assert_almost_eq(S3.rule_f(db, "bite_reach_mult"), 1.5, 1e-9, "scenario calibrated for bite_reach_mult 1.5")
	assert_almost_eq(S3.rule_f(db, "bite_cone_deg"), 60.0, 1e-9, "scenario calibrated for bite_cone_deg 60")
	var base: Dictionary = _chase(-1)
	var inside: Array = base["new_cone"]
	assert_true(inside.size() >= 2, "the prey passes through the new bite cone for a few ticks (got %s)" % [inside])
	if inside.is_empty():
		return
	var first: int = int(inside[0])
	var b: int = _buffer_ticks(S3.make_world(5))
	for off in [-b, -2, 0, 1, 2, 3]:
		assert_true(int(_chase(first + off)["hit"]) >= 0, "a click %+d ticks from the first in-cone tick lands" % off)
	assert_eq(int(_chase(first - b - 1)["hit"]), -1, "a click %d ticks early is outside the buffer" % (b + 1))
	var old: Dictionary = _chase(-1, {"rules": OLD_RULES})
	assert_eq((old["old_cone"] as Array).size(), 0, "pre-F1: the prey never enters the mouth cone in this chase (the playtest's 0 bites)")
	for off2 in [-b, 0, 1, 2, 3]:
		assert_eq(int(_chase(first + off2, {"rules": OLD_RULES})["hit"]), -1, "pre-F1 numbers: the click %+d misses" % off2)


# ======================================================== miss cue

func test_held_bite_in_empty_water_emits_throttled_misses() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var cd: int = _miss_cd_ticks(w)
	assert_true(cd >= 2, "precondition: a miss throttle of at least 2 ticks (got %d)" % cd)
	var p: SimEntity = _player(w, 0.5)
	var evs: Array[SimEvent] = []
	for i in 120:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1))
	var misses: Array[SimEvent] = _misses_of(evs, p.id)
	var expected: int = ceili(120.0 / float(cd))
	assert_true(absi(misses.size() - expected) <= 1, "4 s held in empty water = about %d miss cues (throttle %d ticks), got %d" % [expected, cd, misses.size()])
	for i in range(1, misses.size()):
		assert_true(misses[i].tick - misses[i - 1].tick >= cd, "miss cues at least the throttle apart")
	if not misses.is_empty():
		assert_eq(misses[0].other_id, -1, "BITE_MISSED other = -1")
		assert_almost_eq(misses[0].value, 0.0, 1e-9, "BITE_MISSED value = 0")
	assert_eq(p.bite_ready_tick, 0, "a miss never touches bite_ready_tick")


func test_a_miss_then_a_hit_inside_the_buffer() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var p: SimEntity = _player(w, 0.5)
	var outside: Vector3 = _outside(w, p)
	var v: SimEntity = _victim(w, p, outside)
	var t0: int = w.tick
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 2, {v.id: outside})
	evs.append_array(S3.step_n(w, 3, {v.id: _inside(w, p)}))
	var misses: Array[SimEvent] = _misses_of(evs, p.id)
	var bites: Array[SimEvent] = _bites_by(evs, p.id, v.id)
	assert_eq(misses.size(), 1, "one miss cue on the empty first tick")
	assert_eq(bites.size(), 1, "the still-pending press bites when the target arrives")
	if misses.size() == 1 and bites.size() == 1:
		assert_eq(misses[0].tick, t0, "miss on the press tick")
		assert_eq(bites[0].tick, t0 + 2, "bite on the tick the target is in the cone")


func test_no_miss_cue_on_a_swallow() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var cd: int = _miss_cd_ticks(w)
	var p: SimEntity = _player(w, 1.0)
	var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", _at(p, S3.reach_m(w, p) * 0.3), 0.08)
	var t0: int = w.tick
	var evs: Array[SimEvent] = []
	for i in cd + 2:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {snack.id: snack.position}))
	assert_eq(S3.count_between(w, SimEvent.Type.EATEN, p.id, snack.id, t0), 1, "test setup: the snack is swallowed")
	var misses: Array[SimEvent] = _misses_of(evs, p.id)
	assert_true(misses.size() >= 1, "the held bite cues again once the throttle after the swallow is over")
	if not misses.is_empty():
		assert_true(misses[0].tick >= t0 + cd, "no air-chomp on the swallow tick nor within the throttle after it (first at %d, swallow %d)" % [misses[0].tick, t0])


func test_bite_dash_that_finds_nothing_misses_once_and_does_not_linger() -> void:
	var r: Dictionary = S6.arena_player(SEED, 500.0)
	var w: SimWorld = r["w"]
	var p: SimEntity = r["p"]
	assert_true(S6.give_ability(w, p, "bite_dash"), "test setup: Bite-Dash granted")
	w.submit(SimCommand.ability(p.id, &"bite_dash"))
	var evs: Array[SimEvent] = S6.run(w, 40)
	var ended: Array[SimEvent] = S6.events_named(evs, "DASH_ENDED")
	var misses: Array[SimEvent] = _misses_of(evs, p.id)
	assert_eq(ended.size(), 1, "test setup: one lunge")
	assert_eq(misses.size(), 1, "a dash bite into empty water cues one miss")
	if ended.size() == 1 and misses.size() == 1:
		assert_eq(misses[0].tick, ended[0].tick, "on the DASH_ENDED tick")
	assert_eq(p.bite_request, SimWorld.NO_BITE, "the dash bite is single-shot (nothing pending)")


func test_death_clears_the_pending_bite() -> void:
	var w: SimWorld = S3.make_world(SEED)
	var p: SimEntity = _player(w, 0.5)
	w.submit(SimCommand.bite(p.id, -1))
	S3.step_n(w, 1)
	assert_ne(p.bite_request, SimWorld.NO_BITE, "test setup: the press is still pending after a miss")
	p.hp = 0.0
	var t_die: int = w.tick
	S3.step_n(w, 1)
	assert_false(p.alive, "test setup: the player died")
	assert_eq(p.bite_request, SimWorld.NO_BITE, "death drops the pending bite")
	assert_eq(p.bite_until_tick, -1, "and its window")
	var evs: Array[SimEvent] = S3.step_n(w, S3.ticks(S3.rule_f(w.content, "respawn_delay_s")) + 30)
	assert_true(p.alive, "test setup: respawned")
	assert_eq(_bites_by(evs, p.id).size(), 0, "the respawned player does not bite by itself")
	for ev: SimEvent in _misses_of(evs, p.id):
		fail("no miss cue after the death (tick %d, died %d)" % [ev.tick, t_die])


# ======================================================== determinism and hash

func _held_run() -> Array[int]:
	var w: SimWorld = S3.make_world(SEED)
	var p: SimEntity = _player(w, 0.5)
	var v: SimEntity = S3.npc_at(w, &"small_reef_fish", _at(p, 2.0), p.length_m * 6.0, Vector3.RIGHT)
	var hashes: Array[int] = []
	for i in 120:
		w.submit(SimCommand.move(p.id, (v.position - p.position).normalized(), 0.6))
		if i % 3 != 2:
			w.submit(SimCommand.bite(p.id, -1))
		w.step()
		if i % 10 == 9:
			hashes.append(w.state_hash())
	return hashes


func test_held_bite_runs_are_deterministic_and_the_new_fields_are_hashed() -> void:
	assert_eq(_held_run(), _held_run(), "same seed + held-bite schedule -> same hash every 10 ticks")
	var w: SimWorld = S3.make_world(SEED)
	var p: SimEntity = _player(w, 0.5)
	var h: int = w.state_hash()
	p.bite_until_tick += 3
	assert_ne(w.state_hash(), h, "bite_until_tick is hashed")
	p.bite_until_tick -= 3
	p.bite_miss_ready_tick += 3
	assert_ne(w.state_hash(), h, "bite_miss_ready_tick is hashed")
	p.bite_miss_ready_tick -= 3
	assert_eq(w.state_hash(), h, "restored")
