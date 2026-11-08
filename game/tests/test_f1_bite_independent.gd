extends TestCase
## F1 bite feel, INDEPENDENT second test set (written from tasks/fix-bite-feel.md and section 7 of
## tasks/archive/2026-11/mvp/research/fix-bite-feel-1104/research-summary.md, not from the implementation or its tests).
## Complements test_f1_bite_feel.gd; shares no helper with it. Everything goes through public sim API + S3 helpers.
##
## Conventions: the player (S3.ARENA, heading +X) bites a pinned, durable victim (6x the player's length, never
## swallowed, brains off). Pre-change geometry is hardcoded (mouth reach 0.8 x length, half-cone 45 deg, single-tick
## press) so the "old numbers" do not depend on any key this change added.
##
## PlayerInput section: the node needs a real mouse mode. In a headless run Input.mouse_mode never reads back as
## CAPTURED (the headless DisplayServer stores nothing), so the tests that need a captured mouse return early there
## (guard `_mouse_capture_works()`); they run for real in a windowed run:
##   godot --path game --script res://tests/run_tests.gd -- --filter=test_f1_bite_independent
## The negative paths (uncaptured mouse never bites) run in both modes.

const S3 := preload("res://tests/s3_support.gd")
const SEED: int = 77
const OLD_MOUTH_REACH: float = 0.8
const OLD_MOUTH_CONE_DEG: float = 45.0
## The pre-F1 player bite: mouth geometry, single-tick press, no miss cue.
const OLD_RULES: Dictionary = {"bite_reach_mult": 0.8, "bite_cone_deg": 45.0, "bite_buffer_s": 0.0, "bite_miss_cooldown_s": 0.0}
const SCRATCH: String = "user://f1_independent_scratch"


# ================================================================ helpers

func _world(opts: Dictionary = {}) -> SimWorld:
	var w: SimWorld = S3.make_world(SEED, opts)
	w.brains_enabled = false
	return w


func _player(w: SimWorld, length_m: float = 0.5) -> SimEntity:
	return S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


func _victim(w: SimWorld, p: SimEntity, pos: Vector3) -> SimEntity:
	return S3.npc_at(w, &"small_reef_fish", pos, p.length_m * 6.0, -p.heading)


## Centre distance `dist` from `e`, `deg` degrees off its heading, rotated around `axis` (UP = yaw, BACK = pitch up).
func _at(e: SimEntity, dist: float, deg: float = 0.0, axis: Vector3 = Vector3.UP) -> Vector3:
	return e.position + e.heading.rotated(axis, deg_to_rad(deg)) * dist


func _rule(w: SimWorld, key: String) -> float:
	return S3.rule_f(w.content, key)


func _bite_reach_total(w: SimWorld, p: SimEntity, v: SimEntity) -> float:
	return p.length_m * _rule(w, "bite_reach_mult") + w.collision_radius(v)


func _cd_ticks(w: SimWorld) -> int:
	return S3.ticks(_rule(w, "bite_cooldown_s"))


func _buffer_ticks(w: SimWorld) -> int:
	return S3.ticks(_rule(w, "bite_buffer_s"))


func _miss_cd_ticks(w: SimWorld) -> int:
	return S3.ticks(_rule(w, "bite_miss_cooldown_s"))


## Ticks of BITTEN events where `biter` bit (victim < 0 = any).
func _bite_ticks(evs: Array[SimEvent], biter: int, victim: int = -1) -> Array[int]:
	var out: Array[int] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == biter and (victim < 0 or ev.entity_id == victim):
			out.append(ev.tick)
	return out


func _miss_ticks(evs: Array[SimEvent], id: int = -999) -> Array[int]:
	var out: Array[int] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITE_MISSED and (id == -999 or ev.entity_id == id):
			out.append(ev.tick)
	return out


func _any_miss_count(evs: Array[SimEvent]) -> int:
	return _miss_ticks(evs).size()


func _fresh_hit(rules: Dictionary, length_m: float, dist_total_frac: float, deg: float, axis: Vector3, explicit: bool) -> bool:
	# One press, victim at `dist_total_frac` x (bite reach + victim radius) and `deg` off the heading, one step.
	var w: SimWorld = _world({"rules": rules})
	var p: SimEntity = _player(w, length_m)
	var v: SimEntity = _victim(w, p, p.position + Vector3(0.0, 0.0, 30.0))
	# distances always come from the SHIPPED reach, so the same spot can be offered to a world with other rules
	var total: float = p.length_m * S3.rule_f(S3.content(), "bite_reach_mult") + w.collision_radius(v)
	var pos: Vector3 = _at(p, total * dist_total_frac, deg, axis)
	w.submit(SimCommand.bite(p.id, v.id if explicit else -1))
	var evs: Array[SimEvent] = S3.step_n(w, 1, {v.id: pos}, [v.id])
	return _bite_ticks(evs, p.id, v.id).size() == 1


func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		if not sub.begins_with("."):
			_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "json":
			var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
			out.store_string(FileAccess.get_file_as_string(src.path_join(f)))
			out.close()


func _remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


# ================================================================ data

func test_shipped_values_follow_the_spec_and_the_mouth_numbers_are_untouched() -> void:
	var w: SimWorld = _world()
	assert_almost_eq(_rule(w, "mouth_reach_mult"), OLD_MOUTH_REACH, 1e-9, "swallow mouth reach stays 0.8")
	assert_almost_eq(_rule(w, "mouth_cone_deg"), OLD_MOUTH_CONE_DEG, 1e-9, "swallow mouth cone stays 45")
	assert_almost_eq(_rule(w, "bite_cooldown_s"), 0.5, 1e-9, "bite cooldown stays 0.5 s")
	assert_almost_eq(_rule(w, "swallow_ratio"), 0.10, 1e-9, "swallow ratio untouched")
	var reach: float = _rule(w, "bite_reach_mult")
	assert_true(reach >= 1.3 and reach <= 2.0, "bite_reach_mult in the Director's 1.3-2.0 (got %s)" % reach)
	assert_true(_rule(w, "bite_cone_deg") > OLD_MOUTH_CONE_DEG, "bite cone wider than 45")
	assert_true(_rule(w, "bite_cone_deg") <= 90.0, "bite cone <= 90")
	assert_almost_eq(_rule(w, "bite_buffer_s"), 0.2, 1e-9, "buffer start value 0.2 s")
	assert_eq(_buffer_ticks(w), 6, "0.2 s = 6 ticks at 30 Hz")
	assert_eq(_cd_ticks(w), 15, "0.5 s = 15 ticks")
	assert_true(_rule(w, "bite_miss_cooldown_s") > 0.0, "a miss throttle exists")


func _rules_errors(key: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var r: Dictionary = S3.content().rules().duplicate(true)
	if erase:
		r.erase(key)
	else:
		r[key] = value
	return ContentDB.validate_record(&"rules", r, "rules/core.json")


func _mentions_key(errs: PackedStringArray, key: String) -> bool:
	for msg: String in errs:
		if msg.begins_with("rules/core.json: ") and msg.find(key) != -1:
			return true
	return false


func test_validation_rejects_bad_bite_reach_mult() -> void:
	for bad: Variant in [0.0, -0.001, -1.5, NAN, INF, -INF, "1.5", true, null, [1.5]]:
		assert_true(_mentions_key(_rules_errors("bite_reach_mult", bad), "bite_reach_mult"), "bite_reach_mult = %s rejected" % [bad])
	for good: Variant in [0.0001, 0.8, 1.3, 1.5, 2.0, 3]:
		assert_eq(_rules_errors("bite_reach_mult", good).size(), 0, "bite_reach_mult = %s accepted" % [good])


func test_validation_rejects_bad_bite_cone_deg() -> void:
	for bad: Variant in [0.0, -0.001, -45.0, 180.001, 181.0, 360.0, NAN, INF, "60", null]:
		assert_true(_mentions_key(_rules_errors("bite_cone_deg", bad), "bite_cone_deg"), "bite_cone_deg = %s rejected" % [bad])
	for good: Variant in [0.001, 45, 60.0, 90.0, 180.0]:
		assert_eq(_rules_errors("bite_cone_deg", good).size(), 0, "bite_cone_deg = %s accepted" % [good])


func test_validation_rejects_bad_buffer_and_miss_cooldown() -> void:
	for key: String in ["bite_buffer_s", "bite_miss_cooldown_s"]:
		for bad: Variant in [-0.001, -1.0, NAN, INF, "0.2", null, false]:
			assert_true(_mentions_key(_rules_errors(key, bad), key), "%s = %s rejected" % [key, bad])
		for good: Variant in [0, 0.0, 0.2, 0.5, 2]:
			assert_eq(_rules_errors(key, good).size(), 0, "%s = %s accepted (0 = off)" % [key, good])


func test_the_four_new_keys_are_optional() -> void:
	for key: String in ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s"]:
		assert_eq(_rules_errors(key, null, true).size(), 0, "rules without %s still validate" % key)


func test_a_bad_core_json_makes_the_whole_database_invalid() -> void:
	var cases: Array = [["bite_reach_mult", -2.0], ["bite_cone_deg", 270.0], ["bite_buffer_s", -0.2], ["bite_miss_cooldown_s", -1.0]]
	for case: Array in cases:
		_remove_dir(SCRATCH)
		_copy_dir("res://data", SCRATCH)
		var path: String = SCRATCH.path_join("rules/core.json")
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			fail("scratch copy of rules/core.json did not parse")
			_remove_dir(SCRATCH)
			return
		(parsed as Dictionary)[case[0]] = case[1]
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(parsed, "\t"))
		f.close()
		var db: ContentDB = ContentDB.load_from_dir(SCRATCH)
		_remove_dir(SCRATCH)
		assert_false(db.is_valid(), "%s = %s makes load_from_dir report errors" % [case[0], case[1]])
		assert_true(_mentions_key(db.errors, String(case[0])), "the error names %s (got %s)" % [case[0], db.errors])


func test_shipped_database_is_valid() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_true(db.is_valid(), "shipped data validates (%s)" % [db.errors])


# ================================================================ buffer window

## One press at tick T; the victim is out of reach for `k` ticks (T..T+k-1) and in the cone from T+k. Returns bites.
func _press_then_enter(k: int, explicit: bool, far: bool, opts: Dictionary = {}) -> int:
	var w: SimWorld = _world(opts)
	var p: SimEntity = _player(w, 0.5)
	var reach: float = p.length_m * maxf(_rule(w, "bite_reach_mult"), OLD_MOUTH_REACH)
	var outside: Vector3 = _at(p, reach * 3.0) if far else _at(p, reach * 0.5, 120.0)
	var v: SimEntity = _victim(w, p, outside)
	w.submit(SimCommand.bite(p.id, v.id if explicit else -1))
	var evs: Array[SimEvent] = S3.step_n(w, k, {v.id: outside}, [v.id])
	evs.append_array(S3.step_n(w, 4, {v.id: _at(p, reach * 0.5)}, [v.id]))
	return _bite_ticks(evs, p.id, v.id).size()


func test_buffer_window_edge_six_ticks_fires_seven_does_not() -> void:
	var b: int = _buffer_ticks(_world())
	assert_eq(b, 6, "precondition: shipped buffer is 6 ticks")
	for explicit: bool in [false, true]:
		for far: bool in [false, true]:
			for k in range(0, b + 4):
				var want: int = 1 if k <= b else 0
				assert_eq(_press_then_enter(k, explicit, far), want, "enters %d ticks after the press (explicit=%s far=%s): %s" % [k, explicit, far, "fires" if want == 1 else "dropped"])


func test_zero_buffer_restores_the_single_tick_press() -> void:
	var opts: Dictionary = {"rules": {"bite_buffer_s": 0.0}}
	assert_eq(_press_then_enter(0, false, false, opts), 1, "buffer 0: target already there bites")
	assert_eq(_press_then_enter(1, false, false, opts), 0, "buffer 0: one tick late is a miss")


func test_a_buffered_press_waits_for_the_cooldown_and_fires_on_the_first_ready_tick() -> void:
	var b: int = _buffer_ticks(_world())
	for r in range(0, b + 4):
		var w: SimWorld = _world()
		var p: SimEntity = _player(w)
		var v: SimEntity = _victim(w, p, _at(p, p.length_m * 0.5))
		var pins: Dictionary = {v.id: v.position}
		var cd: int = _cd_ticks(w)
		w.submit(SimCommand.bite(p.id, -1))
		var evs: Array[SimEvent] = S3.step_n(w, 1, pins, [v.id])
		var first: Array[int] = _bite_ticks(evs, p.id, v.id)
		assert_eq(first.size(), 1, "setup: first bite lands")
		if first.size() != 1:
			continue
		var ready: int = first[0] + cd
		var press_at: int = ready - r
		while w.tick < press_at:
			evs.append_array(S3.step_n(w, 1, pins, [v.id]))
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, cd + b + 4, pins, [v.id]))
		var ticks: Array[int] = _bite_ticks(evs, p.id, v.id)
		if r <= b:
			assert_eq(ticks.size(), 2, "press %d ticks before the cooldown ends: second bite fires" % r)
			if ticks.size() == 2:
				assert_eq(ticks[1], ready, "r=%d: exactly on the first ready tick" % r)
		else:
			assert_eq(ticks.size(), 1, "press %d ticks before the cooldown ends (> buffer): dropped" % r)
		assert_eq(_any_miss_count(evs), 0, "r=%d: cooldown + a target in the cone never produces a miss cue" % r)


func test_a_single_press_is_one_shot_without_new_commands() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var v: SimEntity = _victim(w, p, _at(p, p.length_m * 0.5))
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 120, {v.id: v.position}, [v.id])
	assert_eq(_bite_ticks(evs, p.id, v.id).size(), 1, "one press = one bite; the sim never auto-repeats (hold-repeat is the input layer)")
	assert_eq(p.bite_request, SimWorld.NO_BITE, "nothing left pending")


func test_a_new_press_restarts_the_window() -> void:
	var b: int = _buffer_ticks(_world())
	for enter in [5 + b, 6 + b]:
		var w: SimWorld = _world()
		var p: SimEntity = _player(w)
		var out_pos: Vector3 = _at(p, p.length_m * 4.0)
		var v: SimEntity = _victim(w, p, out_pos)
		var evs: Array[SimEvent] = []
		for t in 20:
			if t == 0 or t == 5:
				w.submit(SimCommand.bite(p.id, -1))
			var pos: Vector3 = _at(p, p.length_m * 0.5) if t >= enter else out_pos
			evs.append_array(S3.step_n(w, 1, {v.id: pos}, [v.id]))
		var hits: int = _bite_ticks(evs, p.id, v.id).size()
		assert_eq(hits, 1 if enter == 5 + b else 0, "presses at 0 and 5, target arrives at %d: %s" % [enter, "bites" if enter == 5 + b else "too late"])


# ================================================================ hold-repeat cadence

func test_hold_repeat_is_exactly_one_bite_per_cooldown() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var v: SimEntity = _victim(w, p, _at(p, p.length_m * 0.5))
	var cd: int = _cd_ticks(w)
	var n: int = 150  # 5 s
	var evs: Array[SimEvent] = []
	for i in n:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: v.position}, [v.id]))
	var ticks: Array[int] = _bite_ticks(evs, p.id, v.id)
	assert_eq(ticks.size(), ceili(float(n) / float(cd)), "5 s held = one bite per %d ticks" % cd)
	for i in range(1, ticks.size()):
		assert_eq(ticks[i] - ticks[i - 1], cd, "bite %d follows the previous by exactly the cooldown" % i)
	assert_eq(ticks[0], 0, "the first bite is immediate")
	assert_eq(_any_miss_count(evs), 0, "a held bite on a present target never cues a miss")


func test_hold_repeat_in_the_wide_cone_off_axis_keeps_the_cadence() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var v: SimEntity = _victim(w, p, p.position)
	var pos: Vector3 = _at(p, _bite_reach_total(w, p, v) * 0.9, _rule(w, "bite_cone_deg") - 3.0)
	var cd: int = _cd_ticks(w)
	var evs: Array[SimEvent] = []
	for i in 90:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: pos}, [v.id]))
	assert_eq(_bite_ticks(evs, p.id, v.id).size(), ceili(90.0 / float(cd)), "target near the edge of the wide cone: same cadence")


func test_target_leaving_stops_bites_and_misses_wait_for_the_cooldown() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var near: Vector3 = _at(p, p.length_m * 0.5)
	var gone: Vector3 = p.position + Vector3(0.0, 0.0, 40.0)
	var v: SimEntity = _victim(w, p, near)
	var cd: int = _cd_ticks(w)
	var mcd: int = _miss_cd_ticks(w)
	var evs: Array[SimEvent] = []
	for t in 150:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: near if t <= 20 else gone}, [v.id]))
	var bites: Array[int] = _bite_ticks(evs, p.id, v.id)
	var misses: Array[int] = _miss_ticks(evs, p.id)
	assert_eq(bites, [0, cd] as Array[int], "bites at 0 and one cooldown later, then the target is gone")
	assert_true(misses.size() >= 2, "misses start once the bite is ready and nothing is in reach")
	if misses.is_empty():
		return
	assert_true(misses[0] >= bites[-1] + cd, "no miss cue while the bite is on cooldown (first miss %d, ready %d)" % [misses[0], bites[-1] + cd])
	for i in range(1, misses.size()):
		assert_true(misses[i] - misses[i - 1] >= mcd, "miss cues at least bite_miss_cooldown_s (%d ticks) apart" % mcd)
	assert_true(misses.size() <= ceili(float(150 - misses[0]) / float(mcd)), "no more cues than one per throttle window")


func test_held_bite_in_empty_water_cues_at_most_once_per_miss_cooldown() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var mcd: int = _miss_cd_ticks(w)
	var n: int = 150
	var evs: Array[SimEvent] = []
	for i in n:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1))
	var misses: Array[int] = _miss_ticks(evs, p.id)
	assert_true(misses.size() >= 1, "some feedback exists")
	assert_true(misses.size() <= ceili(float(n) / float(mcd)), "<= 1 per %d ticks (got %d in %d ticks)" % [mcd, misses.size(), n])
	assert_eq(misses[0], 0, "the first miss cues on the press tick (immediate feedback)")
	for i in range(1, misses.size()):
		assert_true(misses[i] - misses[i - 1] >= mcd, "cue %d is at least %d ticks after the previous" % [i, mcd])
	assert_eq(_any_miss_count(evs), misses.size(), "every BITE_MISSED belongs to the player")
	assert_true(p.bite_ready_tick <= w.tick, "a miss imposes no bite cooldown (bite_ready_tick untouched)")
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITE_MISSED:
			assert_eq(ev.other_id, -1, "other = -1")
			assert_almost_eq(ev.value, 0.0, 1e-9, "value = 0")


func test_flickering_target_cannot_beat_the_cooldown_rate() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var near: Vector3 = _at(p, p.length_m * 0.5)
	var gone: Vector3 = p.position + Vector3(0.0, 0.0, 40.0)
	var v: SimEntity = _victim(w, p, near)
	var cd: int = _cd_ticks(w)
	var evs: Array[SimEvent] = []
	for t in 150:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: near if t % 3 == 0 else gone}, [v.id]))
	var ticks: Array[int] = _bite_ticks(evs, p.id, v.id)
	assert_true(ticks.size() >= 5, "it still bites regularly (got %d)" % ticks.size())
	assert_true(ticks.size() <= 150 / cd + 1, "never more than one bite per cooldown (got %d)" % ticks.size())
	for i in range(1, ticks.size()):
		assert_true(ticks[i] - ticks[i - 1] >= cd, "bites >= cooldown apart")


# ================================================================ geometry

func test_player_bite_reach_boundary_scales_with_length() -> void:
	var m: float = _rule(_world(), "bite_reach_mult")
	for length in [0.2, 0.5, 1.5]:
		for explicit: bool in [false, true]:
			assert_true(_fresh_hit({}, length, 0.97, 0.0, Vector3.UP, explicit), "L=%s explicit=%s: 3%% inside the bite reach (%sx + radius) hits" % [length, explicit, m])
			assert_false(_fresh_hit({}, length, 1.03, 0.0, Vector3.UP, explicit), "L=%s explicit=%s: 3%% beyond the bite reach misses" % [length, explicit])


func test_player_bite_cone_boundary_yaw_and_pitch() -> void:
	var cone: float = _rule(_world(), "bite_cone_deg")
	for axis: Vector3 in [Vector3.UP, Vector3.BACK, Vector3.DOWN]:
		assert_true(_fresh_hit({}, 0.5, 0.5, cone - 2.0, axis, false), "axis %s: 2 deg inside the bite cone hits" % axis)
		assert_false(_fresh_hit({}, 0.5, 0.5, cone + 2.0, axis, false), "axis %s: 2 deg outside the bite cone misses" % axis)
		assert_true(_fresh_hit({}, 0.5, 0.5, (OLD_MOUTH_CONE_DEG + cone) * 0.5, axis, false), "axis %s: between the old 45 and the new cone hits" % axis)


func test_what_the_old_numbers_missed_is_now_a_bite() -> void:
	# [distance as a fraction of the NEW total reach (bite reach + radius), degrees off the heading]
	var spots: Array = [[0.80, 0.0], [0.60, 52.0], [0.75, 55.0]]
	for s: Array in spots:
		assert_true(_fresh_hit({}, 0.5, float(s[0]), float(s[1]), Vector3.UP, false), "new rules bite at %s" % [s])
		assert_false(_fresh_hit(OLD_RULES, 0.5, float(s[0]), float(s[1]), Vector3.UP, false), "pre-change numbers miss at %s (the Director's 0 bites)" % [s])


func test_the_swallow_geometry_is_the_old_mouth_whatever_the_bite_values() -> void:
	# [distance in player lengths from the centre, degrees off heading, swallowed]
	var cases: Array = [[0.75, 0.0, true], [0.5, 40.0, true], [0.85, 0.0, false], [1.2, 0.0, false], [0.5, 50.0, false], [0.3, 58.0, false]]
	for rules: Dictionary in [{}, OLD_RULES]:
		for c: Array in cases:
			var w: SimWorld = _world({"rules": rules})
			var p: SimEntity = _player(w, 1.0)
			var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", p.position + Vector3(0.0, 0.0, 30.0), 0.08)
			var pos: Vector3 = _at(p, p.length_m * float(c[0]), float(c[1]))
			var evs: Array[SimEvent] = []
			for i in 5:
				w.submit(SimCommand.bite(p.id, -1))  # a held bite must not drag a swallowable fish in from the bite reach
				evs.append_array(S3.step_n(w, 1, {snack.id: pos}))
			assert_eq(S3.is_gone(w, snack.id), bool(c[2]), "swallow at %s lengths / %s deg (rules %s): %s" % [c[0], c[1], "old" if rules == OLD_RULES else "new", "swallowed" if bool(c[2]) else "survives"])
			assert_eq(_bite_ticks(evs, p.id).size(), 0, "BITE(-1) never bites a swallowable fish")


func test_npc_predator_bite_zone_is_the_old_mouth_zone() -> void:
	# A shark's reach / cone are identical to the pre-change numbers: 0.8 x length + victim radius, 45 deg, single tick.
	var length: float = 3.0
	# [label, distance in lengths-of-reach (x (0.8 L + r)), deg, hit]
	var cases: Array = [["inside the old reach", 0.97, 0.0, true], ["just outside the old reach", 1.05, 0.0, false],
		["inside the player bite reach, outside the mouth", 1.6, 0.0, false], ["old cone edge in", 0.5, 43.0, true],
		["old cone edge out", 0.5, 47.0, false], ["inside the player bite cone only", 0.5, 56.0, false]]
	for explicit: bool in [true, false]:
		for c: Array in cases:
			var w: SimWorld = _world()
			var shark: SimEntity = S3.npc_at(w, &"shark", S3.ARENA, length, Vector3.RIGHT)
			var prey: SimEntity = S3.player_at(w, S3.ARENA + Vector3(0.0, 0.0, 40.0), S3.xp_for_length(w.content, 0.5))
			var total: float = length * OLD_MOUTH_REACH + w.collision_radius(prey)
			var pos: Vector3 = _at(shark, total * float(c[1]), float(c[2]))
			w.submit(SimCommand.bite(shark.id, prey.id if explicit else -1))
			var evs: Array[SimEvent] = S3.step_n(w, 3, {prey.id: pos}, [prey.id])
			var hits: int = _bite_ticks(evs, shark.id, prey.id).size()
			assert_eq(hits, 1 if bool(c[3]) else 0, "shark (explicit=%s) %s: %s" % [explicit, c[0], "bites" if bool(c[3]) else "misses"])
			assert_eq(_any_miss_count(evs), 0, "%s: BITE_MISSED never fires for a shark" % c[0])


func test_npc_bite_has_no_buffer() -> void:
	var w: SimWorld = _world()
	var shark: SimEntity = S3.npc_at(w, &"shark", S3.ARENA, 3.0, Vector3.RIGHT)
	var prey: SimEntity = S3.player_at(w, S3.ARENA + Vector3(0.0, 0.0, 40.0), S3.xp_for_length(w.content, 0.5))
	var total: float = 3.0 * OLD_MOUTH_REACH + w.collision_radius(prey)
	w.submit(SimCommand.bite(shark.id, prey.id))
	var evs: Array[SimEvent] = S3.step_n(w, 1, {prey.id: _at(shark, total * 3.0)}, [prey.id])
	evs.append_array(S3.step_n(w, 6, {prey.id: _at(shark, total * 0.5)}, [prey.id]))
	assert_eq(_bite_ticks(evs, shark.id, prey.id).size(), 0, "an NPC press that finds nothing is gone after its tick")
	assert_eq(shark.bite_request, SimWorld.NO_BITE, "nothing pending on the NPC")


func test_f1_keys_do_not_change_an_npc_only_population() -> void:
	# The player idles (no BITE ever); every bite in the world is an NPC bite. Shipped F1 keys vs the pre-F1 numbers
	# must give the same world, tick for tick: NPC reach/cone/buffer are not touched.
	var traces: Array = []
	var bites: Array[int] = []
	for rules: Dictionary in [{}, OLD_RULES]:
		var w: SimWorld = S3.make_world(5, {"real_spawners": true, "rules": rules})
		var p: SimEntity = S3.player_at(w, S3.spawn_point(w, 0), S3.xp_for_length(w.content, 0.5))
		p.hp = p.max_hp
		var hs: Array[int] = []
		var n_bites: int = 0
		for i in 900:
			w.step()
			n_bites += S3.of_type(w.events_since(w.tick - 1), SimEvent.Type.BITTEN).size()
			if i % 30 == 29:
				hs.append(w.state_hash())
		traces.append(hs)
		bites.append(n_bites)
	assert_eq(traces[0], traces[1], "state_hash trace identical with and without the F1 keys")
	assert_true(bites[0] > 0, "the scenario has teeth: NPCs bit something in 30 s (got %d)" % bites[0])


func test_wide_cone_bite_picks_the_nearest_creature() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var cone: float = _rule(w, "bite_cone_deg")
	var near_v: SimEntity = _victim(w, p, p.position + Vector3(0.0, 0.0, 30.0))
	var far_v: SimEntity = _victim(w, p, p.position + Vector3(0.0, 0.0, -30.0))
	var near_pos: Vector3 = _at(p, p.length_m * 0.4, cone - 4.0)
	var far_pos: Vector3 = _at(p, p.length_m * 0.9, 0.0)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 1, {near_v.id: near_pos, far_v.id: far_pos}, [near_v.id, far_v.id])
	assert_eq(_bite_ticks(evs, p.id, near_v.id).size(), 1, "the nearer creature (off-axis, inside the wide cone) is bitten")
	assert_eq(_bite_ticks(evs, p.id, far_v.id).size(), 0, "not the farther one on the axis")


# ================================================================ BITE_MISSED rules

func test_bite_missed_is_player_only() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var npc: SimEntity = S3.npc_at(w, &"grouper", p.position + Vector3(0.0, 0.0, 30.0), 1.5, Vector3.RIGHT)
	var evs: Array[SimEvent] = []
	for i in 90:
		w.submit(SimCommand.bite(npc.id, -1))
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1))
	assert_true(_miss_ticks(evs, p.id).size() > 0, "setup: the player cues misses")
	assert_eq(_miss_ticks(evs, npc.id).size(), 0, "the NPC biter never gets BITE_MISSED")
	assert_eq(_any_miss_count(evs), _miss_ticks(evs, p.id).size(), "every BITE_MISSED is the player's")


func test_no_miss_cue_on_the_swallow_tick() -> void:
	# Sweep the swallow tick across several miss-throttle windows: whatever the phase of the throttle, the tick on
	# which the player swallows something carries no BITE_MISSED.
	var cue_seen_before: int = 0
	for swallow_at in range(1, 41):
		var w: SimWorld = _world()
		var p: SimEntity = _player(w, 1.0)
		var snack: SimEntity = S3.npc_at(w, &"silver_schooling_fish", p.position + Vector3(0.0, 0.0, 30.0), 0.08)
		var far_spot: Vector3 = _at(p, p.length_m * 1.2)
		var mouth_spot: Vector3 = _at(p, p.length_m * 0.3)
		var evs: Array[SimEvent] = []
		for t in swallow_at + 2:
			w.submit(SimCommand.bite(p.id, -1))
			evs.append_array(S3.step_n(w, 1, {snack.id: far_spot if t < swallow_at else mouth_spot}))
		var eaten: Array[int] = []
		for ev: SimEvent in evs:
			if ev.type == SimEvent.Type.EATEN and (ev.entity_id == p.id or ev.other_id == p.id):
				eaten.append(ev.tick)
		assert_eq(eaten.size(), 1, "setup (swallow at %d): the snack is swallowed once" % swallow_at)
		if eaten.size() != 1:
			continue
		var misses: Array[int] = _miss_ticks(evs, p.id)
		if not misses.is_empty() and misses[0] < eaten[0]:
			cue_seen_before += 1
		assert_false(misses.has(eaten[0]), "swallow at tick %d: no BITE_MISSED on the swallow tick" % eaten[0])
	assert_true(cue_seen_before >= 30, "setup: the held bite did cue air-chomps before the swallow in most runs (%d of 40)" % cue_seen_before)


func test_no_miss_cue_on_a_hit_tick() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var v: SimEntity = _victim(w, p, _at(p, p.length_m * 4.0))
	var evs: Array[SimEvent] = []
	for t in 40:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {v.id: _at(p, p.length_m * 0.5) if t >= 8 else _at(p, p.length_m * 4.0)}, [v.id]))
	var bites: Array[int] = _bite_ticks(evs, p.id, v.id)
	var misses: Array[int] = _miss_ticks(evs, p.id)
	assert_true(bites.size() >= 2 and misses.size() >= 1, "setup: misses first, bites later")
	for b: int in bites:
		assert_false(misses.has(b), "no BITE_MISSED on the hit tick %d" % b)


func test_a_dead_player_holding_bite_produces_no_events_until_respawn() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	p.hp = 0.0
	S3.step_n(w, 1)
	assert_false(p.alive, "setup: dead")
	var evs: Array[SimEvent] = []
	var guard: int = 0
	while not p.alive and guard < 300:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1))
		guard += 1
	assert_true(guard > 10, "setup: the respawn delay lasted a while")
	assert_eq(_any_miss_count(evs), 0, "no BITE_MISSED for a dead player")
	assert_eq(p.bite_request, SimWorld.NO_BITE, "commands to a dead player leave nothing pending")


# ================================================================ death / respawn

func test_death_clears_a_pending_buffer_and_the_respawned_fish_does_not_bite() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var near: Vector3 = _at(p, p.length_m * 0.5)
	var v: SimEntity = _victim(w, p, near)
	var pins: Dictionary = {v.id: near}
	w.submit(SimCommand.bite(p.id, -1))
	S3.step_n(w, 1, pins, [v.id])  # bite lands: on cooldown
	w.submit(SimCommand.bite(p.id, -1))
	S3.step_n(w, 1, pins, [v.id])  # second press: pending behind the cooldown
	assert_ne(p.bite_request, SimWorld.NO_BITE, "setup: a press is pending behind the cooldown")
	p.hp = 0.0
	S3.step_n(w, 1, pins, [v.id])
	assert_false(p.alive, "setup: died")
	assert_eq(p.bite_request, SimWorld.NO_BITE, "death drops the pending request")
	assert_eq(p.bite_until_tick, -1, "and its window")
	var guard: int = 0
	while not p.alive and guard < 400:
		S3.step_n(w, 1, pins, [v.id])
		guard += 1
	assert_true(p.alive, "setup: respawned")
	# the victim follows the respawned fish into its bite cone; no new command is ever sent
	var evs: Array[SimEvent] = []
	for i in 60:
		var pos: Vector3 = _at(p, p.length_m * 0.5)
		evs.append_array(S3.step_n(w, 1, {v.id: pos}, [v.id]))
	assert_eq(_bite_ticks(evs, p.id).size(), 0, "no bite from a press made before the death")
	assert_eq(_any_miss_count(evs), 0, "and no air-chomp cue either")


# ================================================================ determinism

## Scripted held-bite run: a press at t=2 while the victim is still out of reach (buffer in flight), the victim arrives
## at t=7, a second press at t=40 with arrival at t=44. `shift` delays the first press. Returns the hash every tick
## plus the number of ticks with a pending request.
func _scripted(shift: int) -> Dictionary:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var out_pos: Vector3 = _at(p, p.length_m * 4.0)
	var v: SimEntity = _victim(w, p, out_pos)
	var in_pos: Vector3 = _at(p, p.length_m * 0.5)
	var hashes: Array[int] = []
	var pending: int = 0
	for t in 120:
		if t == 2 + shift or t == 40:
			w.submit(SimCommand.bite(p.id, -1))
		var inside: bool = (t >= 7 and t < 38) or t >= 44
		S3.step_n(w, 1, {v.id: in_pos if inside else out_pos}, [v.id])
		if p.bite_request != SimWorld.NO_BITE:
			pending += 1
		hashes.append(w.state_hash())
	return {"hashes": hashes, "pending": pending}


func test_scripted_buffer_in_flight_is_deterministic_tick_by_tick() -> void:
	var a: Dictionary = _scripted(0)
	var b: Dictionary = _scripted(0)
	assert_true(int(a["pending"]) >= 5, "setup: the buffer was in flight for several ticks (got %d)" % int(a["pending"]))
	assert_eq(a["hashes"], b["hashes"], "two identical runs: same state_hash on every tick")
	var c: Dictionary = _scripted(1)
	assert_ne(a["hashes"], c["hashes"], "a press one tick later changes the hash trace (the buffer state is hashed)")


func test_the_new_pending_bite_fields_are_part_of_the_state_hash() -> void:
	# Fields that change behaviour must be hashed (CONVENTIONS): the window end and the miss-cue throttle.
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var h0: int = w.state_hash()
	for field: String in ["bite_until_tick", "bite_miss_ready_tick"]:
		var old: int = int(p.get(field))
		p.set(field, old + 5)
		assert_ne(w.state_hash(), h0, "%s feeds state_hash" % field)
		p.set(field, old)
		assert_eq(w.state_hash(), h0, "%s restored: the hash returns" % field)


func test_population_run_with_a_held_bite_is_deterministic() -> void:
	var runs: Array = []
	for r in 2:
		var w: SimWorld = S3.make_world(9, {"real_spawners": true})
		var p: SimEntity = S3.player_at(w, S3.spawn_point(w, 0), S3.xp_for_length(w.content, 0.3))
		var hashes: Array[int] = []
		var tally: int = 0
		for t in 600:
			w.submit(SimCommand.move(p.id, Vector3(0.6, 0.1 * sin(float(t) * 0.05), 0.4).normalized(), 0.7))
			if t % 4 != 3:
				w.submit(SimCommand.bite(p.id, -1))
			w.step()
			for ev: SimEvent in w.events_since(w.tick - 1):
				if ev.type == SimEvent.Type.BITE_MISSED or ev.type == SimEvent.Type.BITTEN or ev.type == SimEvent.Type.EATEN:
					tally += 1
			if t % 20 == 19:
				hashes.append(w.state_hash())
		runs.append({"h": hashes, "tally": tally})
	assert_eq((runs[0] as Dictionary)["h"], (runs[1] as Dictionary)["h"], "same seed + same held-bite script: same hash every 20 ticks")
	assert_eq((runs[0] as Dictionary)["tally"], (runs[1] as Dictionary)["tally"], "and the same number of bite events")
	assert_true(int((runs[0] as Dictionary)["tally"]) > 0, "the scripted player did bite / miss / eat something")


# ================================================================ human model (kinematic, no brains)

## Player L=0.2 m (heading +X) sees a prey 0.12 m close the distance at 0.1 m per tick (a 3 m/s closing speed, the
## geometry of the playtest's chase) 0.03 m to the side; ONE press at tick `click`. Returns the tick of the bite, -1 = none.
func _crossing(click: int, rules: Dictionary) -> int:
	var w: SimWorld = _world({"rules": rules})
	var p: SimEntity = S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, 0.2), Vector3.RIGHT)
	var prey: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(1.0, 0.0, 0.03), 0.12, Vector3.RIGHT)
	for t in 25:
		if t == click:
			w.submit(SimCommand.bite(p.id, -1))
		var pos: Vector3 = S3.ARENA + Vector3(0.8 - 0.1 * float(t), 0.0, 0.03)
		var evs: Array[SimEvent] = S3.step_n(w, 1, {prey.id: pos}, [prey.id])
		var hits: Array[int] = _bite_ticks(evs, p.id, prey.id)
		if not hits.is_empty():
			return hits[0]
	return -1


func test_a_human_click_window_on_a_closing_prey_is_far_wider_than_before() -> void:
	var new_rules: int = 0
	var old_rules: int = 0
	for click in 25:
		if _crossing(click, {}) >= 0:
			new_rules += 1
		if _crossing(click, OLD_RULES) >= 0:
			old_rules += 1
	assert_true(new_rules >= 6, "with the new rules at least 6 click ticks (0.2 s) land a bite (got %d)" % new_rules)
	assert_true(new_rules >= 3 * maxi(old_rules, 1), "the landing window is at least 3x the old one (new %d, old %d click ticks of 25)" % [new_rules, old_rules])


# ================================================================ PlayerInput

## True when the display server reports a captured mouse (not in a headless run).
func _mouse_capture_works() -> bool:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var ok: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return ok


func _click_event(pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	return ev


## PlayerInput in the tree (so get_viewport() works) but with its own processing off: the test calls _physics_process
## and _unhandled_input by hand, so one call = one physics frame / one event.
func _input_node(w: SimWorld, p: SimEntity) -> PlayerInput:
	var pi := PlayerInput.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(pi)
	pi.set_physics_process(false)
	pi.set_process_unhandled_input(false)
	pi.setup(w, p.id)
	pi.aim_yaw = -PI * 0.5  # aim +X: sin(-pi/2) = -1 -> x = +1
	pi.aim_pitch = 0.0
	# a node added during the runner's _initialize is not inside the tree until the main loop has run a frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	return pi


func _release_input(pi: PlayerInput) -> void:
	Input.action_release(&"bite")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var parent: Node = pi.get_parent()
	if parent != null:
		parent.remove_child(pi)
	pi.free()


## Number of BITE commands queued for the next tick (drains the due commands; MOVE etc. are discarded).
func _queued_bites(w: SimWorld) -> int:
	var n: int = 0
	for cmd: SimCommand in w._queue.pop_for_tick(w.tick):
		if cmd.type == SimCommand.Type.BITE:
			n += 1
	return n


func _frame(pi: PlayerInput, w: SimWorld, physics_frames: int = 2) -> int:
	# two physics frames per 30 Hz sim tick (the project runs 60 Hz physics); returns the BITEs queued in that tick
	for i in physics_frames:
		pi._physics_process(1.0 / 60.0)
	var n: int = _queued_bites(w)
	w.step()
	return n


func test_player_input_never_bites_with_an_uncaptured_mouse() -> void:
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var pi: PlayerInput = await _input_node(w, p)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.action_press(&"bite")
	var total: int = 0
	for i in 10:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # keep it uncaptured whatever the display server does
		total += _frame(pi, w)
	assert_eq(total, 0, "a held button with a visible mouse (Esc menu) sends no BITE")
	_release_input(pi)


func test_player_input_press_event_submits_one_bite_per_tick() -> void:
	if not _mouse_capture_works():
		return  # headless: no captured mouse (see the file header)
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var pi: PlayerInput = await _input_node(w, p)
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_CAPTURED, "setup: captured")
	Input.action_press(&"bite")
	pi._unhandled_input(_click_event(true))
	pi._unhandled_input(_click_event(true))  # a second event in the same tick is deduplicated
	assert_eq(_queued_bites(w), 1, "a click while captured submits one BITE(-1) per sim tick")
	_release_input(pi)


func test_player_input_hold_repeat_sends_one_bite_per_tick_and_the_sim_bites_per_cooldown() -> void:
	if not _mouse_capture_works():
		return
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var v: SimEntity = _victim(w, p, _at(p, p.length_m * 0.5))
	var pi: PlayerInput = await _input_node(w, p)
	var cd: int = _cd_ticks(w)
	# physics frame with the button up arms the hold-repeat
	_frame(pi, w)
	Input.action_press(&"bite")
	pi._unhandled_input(_click_event(true))
	var per_tick: Array[int] = []
	var evs: Array[SimEvent] = []
	for t in 90:
		pi._physics_process(1.0 / 60.0)
		pi._physics_process(1.0 / 60.0)
		per_tick.append(_queued_bites(w))
		w.submit(SimCommand.bite(p.id, -1))  # the drained commands do not reach the sim: replay one BITE per tick
		evs.append_array(S3.step_n(w, 1, {v.id: v.position}, [v.id]))
	assert_eq(per_tick.count(1), 90, "held button: exactly one BITE per sim tick, press tick included (90 of 90 ticks, two physics frames each)")
	assert_eq(per_tick.count(2) + per_tick.count(3), 0, "never two BITE commands in one tick")
	assert_eq(_bite_ticks(evs, p.id, v.id).size(), ceili(90.0 / float(cd)), "and the sim answers with one bite per cooldown")
	_release_input(pi)


func test_player_input_capture_click_is_not_a_bite_and_a_held_button_stays_disarmed() -> void:
	if not _mouse_capture_works():
		return
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var pi: PlayerInput = await _input_node(w, p)
	# Esc: the mouse is released
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	Input.action_press(&"pause")
	pi._unhandled_input(esc)
	Input.action_release(&"pause")
	assert_ne(Input.mouse_mode, Input.MOUSE_MODE_CAPTURED, "setup: Esc released the mouse")
	# the click that re-captures the mouse
	Input.action_press(&"bite")
	pi._unhandled_input(_click_event(true))
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_CAPTURED, "the click re-captured the mouse")
	assert_eq(_queued_bites(w), 0, "the capturing click is not a bite")
	var held: int = 0
	for i in 6:
		held += _frame(pi, w)
	assert_eq(held, 0, "the button still held from the capturing click never turns into a held bite")
	Input.action_release(&"bite")
	_frame(pi, w)  # armed by a released frame
	Input.action_press(&"bite")
	assert_eq(_frame(pi, w), 1, "release + press again: bites (and holds) normally")
	_release_input(pi)


func test_player_input_pick_pause_and_pause_notification_disarm_the_hold() -> void:
	if not _mouse_capture_works():
		return
	var w: SimWorld = _world()
	var p: SimEntity = _player(w)
	var pi: PlayerInput = await _input_node(w, p)
	_frame(pi, w)  # released: armed
	Input.action_press(&"bite")
	assert_eq(_frame(pi, w), 1, "armed + held: bites")
	# sim paused for a mutation pick
	w.paused_for_pick = true
	var during: int = 0
	for i in 4:
		pi._physics_process(1.0 / 60.0)
		during += _queued_bites(w)
	assert_eq(during, 0, "paused for a pick: no gameplay input at all")
	w.paused_for_pick = false
	assert_eq(_frame(pi, w), 0, "the button still held when the pick ends does not bite")
	Input.action_release(&"bite")
	_frame(pi, w)
	Input.action_press(&"bite")
	assert_eq(_frame(pi, w), 1, "armed again after a release")
	# pause menu / resume
	pi.notification(Node.NOTIFICATION_PAUSED)
	assert_eq(_frame(pi, w), 0, "NOTIFICATION_PAUSED disarms: a button held across the pause menu does not bite")
	_release_input(pi)
