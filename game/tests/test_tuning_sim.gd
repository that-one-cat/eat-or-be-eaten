extends TestCase
## T1.3 tuning lab, sim half, end to end on real SimWorld runs through the console `tune` commands:
##  - identity: with an empty override layer every pinned state_hash / the lane baselines / a shipped-spawner world are
##    bit-identical to the pre-T1.3 code; tune + reset before the first step restores the baseline hash; rejected input
##    leaves the layer empty.
##  - live effect: an override changes the sim from the NEXT tick and equals the same edit made in the data (bite reach /
##    cone / buffer / miss cooldown / cooldown, and the cached band arrays: speed / accel / drag / turn / brake).
##  - determinism: same overrides + same seed = same hash; order / repeats do not matter; overrides live on one world only
##    and never touch the loaded data or the files.
## Comparisons between an override run and a data-edit run use TS.trace (entity state + events), NOT state_hash, because
## whether a non-empty override set enters state_hash is the implementation's documented choice.

const TS := preload("res://tests/tuning_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const SS := preload("res://tests/species_stats_support.gd")

const RULE_PATHS: Array[String] = ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "bite_cooldown_s"]
const BAND_PATHS: Array[String] = ["swim_speed_mps", "accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2"]
const HELD_TICKS: int = 150


# ======================================================================= helpers

func _db() -> ContentDB:
	return S3.content()


## Registry row for (target, path); records a failure when the row is missing.
func _row(target: String, path: String) -> Dictionary:
	var e: Dictionary = TS.entry_for(target, path)
	assert_false(e.is_empty(), "registry row %s:%s exists (data/god/tuning.json)" % [target, path])
	return e


func _alt(target: String, path: String) -> float:
	var e: Dictionary = _row(target, path)
	return TS.alt_value(e, _db()) if not e.is_empty() else 0.0


func _line(target: String, path: String, value: float) -> String:
	return "tune %s %s" % [str(_row(target, path).get("id", "")), TS.fmt(value)]


func _rule_line(path: String) -> String:
	return _line("rules", path, _alt("rules", path))


func _band_line(path: String) -> String:
	return _line("band", path, _alt("band", path))


func _all_rule_lines() -> Array:
	var out: Array = []
	for p: String in RULE_PATHS:
		out.append(_rule_line(p))
	return out


func _all_band_lines() -> Array:
	var out: Array = []
	for p: String in BAND_PATHS:
		out.append(_band_line(p))
	return out


func _id(target: String, path: String) -> String:
	return str(_row(target, path).get("id", ""))


func _data_f(path: String) -> float:
	return S3.rule_f(_db(), path)


func _base_composite() -> Dictionary:
	return TS.composite({}, [])


# ======================================================================= identity (empty layer)

func test_empty_layer_keeps_the_pinned_scenario_hashes() -> void:
	var got: Dictionary = {
		"bite_composite": TS.composite({}, [])["hash"], "held_bites": TS.held_bites({}, [])["hash"],
		"held_misses": TS.held_misses({}, [])["hash"], "press_enter_6": TS.press_then_enter({}, [], 6)["hash"],
		"press_enter_9": TS.press_then_enter({}, [], 9)["hash"],
	}
	for k: String in TS.BASELINE_HASHES.keys():
		assert_eq(got[k], TS.BASELINE_HASHES[k], "pre-T1.3 state_hash of %s" % k)


func test_empty_layer_keeps_the_lane_baselines_in_every_band() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for b in range(1, 5):
		assert_eq(TS.lane_run(db, b)["hash"], SS.BASELINE_HASHES["player_band_%d" % b], "band %d scripted player hash" % b)


func test_empty_layer_keeps_a_shipped_spawner_world_identical() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_eq(SS.hash_real_world(db, 4242, 900, 0), SS.BASELINE_HASHES["s3_real_4242_900"], "shipped spawners + schools + bites, 900 ticks")


func test_a_plain_world_has_no_override_state() -> void:
	var w: SimWorld = S3.make_world(TS.SEED)
	TS.player(w)
	S3.step_n(w, 30)
	assert_null(w.debug, "no SimDebug state is created by normal play (the layer is empty and off by default)")


func test_tune_then_reset_before_the_first_step_is_bit_identical() -> void:
	var base: Dictionary = _base_composite()
	var rules: Array = _all_rule_lines()
	rules.append("tune reset")
	assert_eq(TS.composite({}, rules)["hash"], base["hash"], "five rule overrides then `tune reset`: baseline state_hash")
	var per_id: Array = _all_rule_lines()
	for p: String in RULE_PATHS:
		per_id.append("tune reset %s" % _id("rules", p))
	assert_eq(TS.composite({}, per_id)["hash"], base["hash"], "five overrides then `tune reset <id>` each: baseline state_hash")
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for b in range(1, 5):
		var lines: Array = _all_band_lines()
		lines.append("tune reset")
		assert_eq(TS.lane_run(db, b, lines)["hash"], SS.BASELINE_HASHES["player_band_%d" % b], "band %d: five band overrides then reset" % b)


func test_rejected_input_leaves_the_layer_empty() -> void:
	var base: Dictionary = _base_composite()
	var e: Dictionary = _row("rules", "bite_reach_mult")
	var id: String = str(e.get("id", ""))
	var hi: float = float(e.get("max", 1.0))
	var lo: float = float(e.get("min", 0.0))
	var step: float = float(e.get("step", 0.1))
	var bad: Array[String] = [
		"tune %s %s" % [id, TS.fmt(hi + step)], "tune %s %s" % [id, TS.fmt(hi * 10.0 + 1.0)], "tune %s %s" % [id, TS.fmt(lo - step)],
		"tune %s nan" % id, "tune %s inf" % id, "tune %s -inf" % id, "tune %s 1e999" % id, "tune %s abc" % id, "tune %s \"\"" % id,
		"tune %s" % id, "tune no_such_id_zz 1", "tune reset no_such_id_zz", "tune", "tune list extra words", "tune bogus_subcommand",
	]
	var rg: Dictionary = TS.composite_rig({}, [])
	var cmds: GodCommands = TS.commands()
	for line: String in bad:
		var ans: String = TS.tune(cmds, rg["w"], (rg["p"] as SimEntity).id, line)
		assert_false(ans.is_empty(), "'%s' is answered" % line)
	var run: Dictionary = TS.composite_run(rg)
	assert_eq(run["trace"], base["trace"], "after all the rejected lines the sim is the baseline")
	assert_eq(run["hash"], base["hash"], "and so is the state_hash")


# ======================================================================= rules overrides: equal to a data edit

func test_the_five_bite_rules_together_equal_the_same_edit_in_the_data() -> void:
	var edits: Dictionary = {}
	for p: String in RULE_PATHS:
		edits[p] = _alt("rules", p)
	var data_side: Dictionary = TS.composite({"rules": edits}, [])
	var tune_side: Dictionary = TS.composite({}, _all_rule_lines())
	var base: Dictionary = _base_composite()
	assert_ne(data_side["trace"], base["trace"], "scenario is sensitive to the five edits (test self-check)")
	assert_eq(tune_side["trace"], data_side["trace"], "tune lines == data edit: identical entities and events over 240 held-bite ticks")
	assert_eq(tune_side["bites"], data_side["bites"], "bite count")
	assert_eq(tune_side["misses"], data_side["misses"], "miss cue count")


func test_each_bite_rule_alone_equals_the_data_edit() -> void:
	var base: Dictionary = _base_composite()
	for p: String in ["bite_reach_mult", "bite_cone_deg", "bite_miss_cooldown_s", "bite_cooldown_s"]:
		var alt: float = _alt("rules", p)
		var data_side: Dictionary = TS.composite({"rules": {p: alt}}, [])
		var tune_side: Dictionary = TS.composite({}, [_line("rules", p, alt)])
		assert_ne(data_side["trace"], base["trace"], "%s: scenario is sensitive (self-check)" % p)
		assert_eq(tune_side["trace"], data_side["trace"], "%s: override == data edit" % p)


func test_the_bite_buffer_override_equals_the_data_edit_for_every_entry_delay() -> void:
	var alt: float = _alt("rules", "bite_buffer_s")
	var line: String = _line("rules", "bite_buffer_s", alt)
	var differs: bool = false
	for k in range(0, 24):
		var data_side: Dictionary = TS.press_then_enter({"rules": {"bite_buffer_s": alt}}, [], k)
		var tune_side: Dictionary = TS.press_then_enter({}, [line], k)
		var base: Dictionary = TS.press_then_enter({}, [], k)
		assert_eq(tune_side["trace"], data_side["trace"], "buffer override, target enters after %d ticks" % k)
		differs = differs or data_side["trace"] != base["trace"]
	assert_true(differs, "the buffer edit changes at least one entry delay (self-check)")


func test_range_ends_are_accepted_and_act() -> void:
	var e: Dictionary = _row("rules", "bite_reach_mult")
	for v: float in [float(e.get("min", 0.0)), float(e.get("max", 1.0))]:
		var data_side: Dictionary = TS.composite({"rules": {"bite_reach_mult": v}}, [])
		var tune_side: Dictionary = TS.composite({}, ["tune %s %s" % [e.get("id"), TS.fmt(v)]])
		assert_eq(tune_side["trace"], data_side["trace"], "bite_reach_mult = %s (a range end) is applied" % v)


# ======================================================================= rules overrides: analytic, next tick, reset

func test_bite_reach_override_reaches_farther_from_the_next_tick_and_reset_takes_it_back() -> void:
	var cur: float = _data_f("bite_reach_mult")
	var alt: float = _alt("rules", "bite_reach_mult")
	var line: String = _line("rules", "bite_reach_mult", alt)
	if alt <= cur:
		fail("registry range leaves room above the shipped bite_reach_mult (alt %s, data %s)" % [alt, cur])
		return
	var mid: float = (cur + alt) * 0.5
	assert_eq(TS.one_bite_at({}, [], mid, 0.0), 0, "no override: a victim between the old and the new reach is not bitten (self-check)")
	assert_eq(TS.one_bite_at({}, [line], mid, 0.0), 1, "override at tick 0: bitten")
	assert_eq(TS.one_bite_at({}, [], mid, 0.0, 10, [line]), 1, "override set after 10 ticks: bitten on the very next press")
	assert_eq(TS.one_bite_at({}, [line], mid, 0.0, 10, ["tune reset"]), 0, "reset after 10 ticks: back to the data reach on the next press")
	assert_eq(TS.one_bite_at({}, [line, "tune reset %s" % _id("rules", "bite_reach_mult")], mid, 0.0), 0, "per-id reset")
	assert_eq(TS.one_bite_at({}, [line], cur * 0.5, 0.0), 1, "a victim well inside the old reach is still bitten")


func test_bite_cone_override_widens_the_cone_from_the_next_tick() -> void:
	var cur: float = _data_f("bite_cone_deg")
	var alt: float = _alt("rules", "bite_cone_deg")
	var line: String = _line("rules", "bite_cone_deg", alt)
	if alt <= cur:
		fail("registry range leaves room above the shipped bite_cone_deg (alt %s, data %s)" % [alt, cur])
		return
	var mid: float = minf((cur + alt) * 0.5, 170.0)
	var near: float = _data_f("bite_reach_mult") * 0.5
	assert_eq(TS.one_bite_at({}, [], near, mid), 0, "no override: outside the cone (self-check)")
	assert_eq(TS.one_bite_at({}, [line], near, mid), 1, "override: inside the widened cone")
	assert_eq(TS.one_bite_at({}, [], near, mid, 10, [line]), 1, "set after 10 ticks: next press uses it")
	assert_eq(TS.one_bite_at({}, [line], near, mid, 10, ["tune reset"]), 0, "reset: next press uses the data cone again")


func test_bite_buffer_override_keeps_a_press_alive_longer() -> void:
	var cur_t: int = S3.ticks(_data_f("bite_buffer_s"))
	var alt: float = _alt("rules", "bite_buffer_s")
	var line: String = _line("rules", "bite_buffer_s", alt)
	var alt_t: int = S3.ticks(alt)
	var k: int = cur_t + 1
	if alt_t < k:
		fail("registry range leaves room above the shipped bite_buffer_s (alt %s s = %d ticks, need >= %d)" % [alt, alt_t, k])
		return
	assert_eq(TS.press_then_enter({}, [], k)["bites"], 0, "no override: the press expired %d ticks before the target arrives (self-check)" % k)
	assert_eq(TS.press_then_enter({}, [line], k)["bites"], 1, "override: the press is still alive after %d ticks" % k)
	assert_eq(TS.press_then_enter({}, [line], alt_t + 2)["bites"], 0, "but not forever")


func test_bite_cooldown_override_slows_the_held_bite_rate() -> void:
	var alt: float = _alt("rules", "bite_cooldown_s")
	var cd_alt: int = S3.ticks(alt)
	var cd_cur: int = S3.ticks(_data_f("bite_cooldown_s"))
	if cd_alt <= cd_cur:
		fail("registry range leaves room above the shipped bite_cooldown_s (alt %s s)" % alt)
		return
	var ticks: Array = TS.held_bites({}, [_line("rules", "bite_cooldown_s", alt)], HELD_TICKS)["ticks"]
	var expected: int = ceili(float(HELD_TICKS) / float(cd_alt))
	assert_true(absi(ticks.size() - expected) <= 1, "5 s held = about %d bites at %d ticks cooldown, got %d" % [expected, cd_alt, ticks.size()])
	for i in range(1, ticks.size()):
		assert_true(int(ticks[i]) - int(ticks[i - 1]) >= cd_alt, "bites at least %d ticks apart (override)" % cd_alt)
	assert_true(ticks.size() < (TS.held_bites({}, [], HELD_TICKS)["ticks"] as Array).size(), "fewer bites than with the data cooldown")


func test_bite_miss_cooldown_override_throttles_the_miss_cue() -> void:
	var alt: float = _alt("rules", "bite_miss_cooldown_s")
	var cd_alt: int = S3.ticks(alt)
	var cd_cur: int = S3.ticks(_data_f("bite_miss_cooldown_s"))
	if cd_alt <= cd_cur:
		fail("registry range leaves room above the shipped bite_miss_cooldown_s (alt %s s)" % alt)
		return
	var misses: int = TS.held_misses({}, [_line("rules", "bite_miss_cooldown_s", alt)], HELD_TICKS)["misses"]
	var expected: int = ceili(float(HELD_TICKS) / float(cd_alt))
	assert_true(absi(misses - expected) <= 1, "held bite in empty water: about %d cues at %d ticks, got %d" % [expected, cd_alt, misses])
	assert_true(misses < int(TS.held_misses({}, [], HELD_TICKS)["misses"]), "fewer cues than with the data throttle")


# ======================================================================= band overrides: cached movement arrays

## One observable per band field; `lines` are run at tick 0 AFTER the spawn (so the sim has already cached the table).
func _band_scenario(path: String, db: ContentDB, band: int, lines: Array) -> String:
	if path == "drag_per_s":
		return str(TS.coast_speed(db, band, float(_db().get_band(band)["swim_speed_mps"]) * 0.8, 20, lines))
	return str(TS.lane_run(db, band, lines)["trace"])


func test_each_band_override_equals_the_same_edit_in_the_data_in_every_band() -> void:
	var base_db: ContentDB = ContentDB.load_from_dir("res://data")
	for path: String in BAND_PATHS:
		var alt: float = _alt("band", path)
		var line: String = _line("band", path, alt)
		var edited: ContentDB = TS.db_with_band(path, alt)
		for b in range(1, 5):
			var data_side: String = _band_scenario(path, edited, b, [])
			var base: String = _band_scenario(path, base_db, b, [])
			assert_ne(data_side, base, "%s band %d: scenario is sensitive (self-check)" % [path, b])
			assert_eq(_band_scenario(path, base_db, b, [line]), data_side, "%s band %d: override == data edit (cached array refreshed)" % [path, b])


func test_all_five_band_overrides_together_equal_the_data_edit() -> void:
	var edited: ContentDB = ContentDB.load_from_dir("res://data")
	for path: String in BAND_PATHS:
		var alt: float = _alt("band", path)
		for b in range(1, 5):
			edited.get_band(b)[path] = alt
	var base_db: ContentDB = ContentDB.load_from_dir("res://data")
	for b in range(1, 5):
		assert_eq(TS.lane_run(base_db, b, _all_band_lines())["trace"], TS.lane_run(edited, b)["trace"], "band %d, five overrides at once" % b)


func test_turn_rate_override_acts_on_the_very_next_tick() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var alt: float = _alt("band", "turn_rate_deg_s")
	var line: String = _line("band", "turn_rate_deg_s", alt)
	for b in range(1, 5):
		var cur: float = float(db.get_band(b)["turn_rate_deg_s"])
		var plain: Array[float] = TS.turn_deltas(db, b, 90.0, 3, [])
		var tuned: Array[float] = TS.turn_deltas(db, b, 90.0, 3, [line])
		var reset: Array[float] = TS.turn_deltas(db, b, 90.0, 3, [line, "tune reset"])
		for i in 3:
			assert_almost_eq(plain[i], deg_to_rad(cur) / 30.0, 1e-4, "band %d data turn: %.1f deg/s per tick %d" % [b, cur, i])
			assert_almost_eq(tuned[i], deg_to_rad(alt) / 30.0, 1e-4, "band %d override %.1f deg/s acts from the next tick (tick %d)" % [b, alt, i])
			assert_almost_eq(reset[i], plain[i], 1e-6, "band %d reset restores the data turn rate (tick %d)" % [b, i])


# ======================================================================= the layer sits on top of the data

func test_overrides_never_touch_the_loaded_data_or_the_files() -> void:
	var files: Array[String] = ["res://data/rules/core.json", "res://data/size_bands/size_bands.json", TS.REGISTRY_PATH]
	var before: Array[String] = []
	for f: String in files:
		before.append(FileAccess.get_sha256(f))
	var rg: Dictionary = TS.composite_rig({}, _all_rule_lines() + _all_band_lines())
	TS.composite_run(rg, 60)
	var w: SimWorld = rg["w"]
	var fresh: ContentDB = ContentDB.load_from_dir("res://data")
	for p: String in RULE_PATHS:
		assert_almost_eq(float(S3.rule(w.content, p)), float(S3.rule(fresh, p)), 1e-12, "world content: rules.%s is still the data value" % p)
	for p: String in BAND_PATHS:
		for b in range(1, w.content.band_count() + 1):
			assert_almost_eq(float(w.content.get_band(b)[p]), float(fresh.get_band(b)[p]), 1e-12, "world content: band %d %s is still the data value" % [b, p])
	for i in files.size():
		assert_eq(FileAccess.get_sha256(files[i]), before[i], "%s is byte-identical after tuning" % files[i])
	# another, fresh ContentDB-backed world is clean (nothing leaked into a shared cache)
	assert_eq(TS.composite({}, [])["trace"], _base_composite()["trace"], "a world built afterwards is the baseline")


func test_overrides_live_on_one_world_only() -> void:
	var clean: Dictionary = TS.composite_rig({}, [])  # built BEFORE the tuned world
	var tuned: Dictionary = TS.composite_rig({}, _all_rule_lines())
	var after: Dictionary = TS.composite_rig({}, [])  # built AFTER
	var base: Dictionary = _base_composite()
	assert_ne(TS.composite_run(tuned)["trace"], base["trace"], "the tuned world differs (self-check)")
	assert_eq(TS.composite_run(clean)["trace"], base["trace"], "a world that existed before the tune is untouched")
	assert_eq(TS.composite_run(after)["trace"], base["trace"], "a world created after the tune is untouched")


# ======================================================================= determinism

func test_same_overrides_and_seed_give_the_same_hash_and_not_the_baseline() -> void:
	var lines: Array = _all_rule_lines()
	var a: Dictionary = TS.composite({}, lines)
	var b: Dictionary = TS.composite({}, lines)
	assert_eq(a["hash"], b["hash"], "two runs with the same overrides: same state_hash")
	assert_eq(a["trace"], b["trace"], "and the same trajectory")
	assert_ne(a["hash"], _base_composite()["hash"], "the overridden run is not the baseline run")
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var l1: Dictionary = TS.lane_run(db, 2, _all_band_lines())
	var l2: Dictionary = TS.lane_run(db, 2, _all_band_lines())
	assert_eq(l1["hash"], l2["hash"], "band overrides: same state_hash twice")
	assert_ne(l1["hash"], SS.BASELINE_HASHES["player_band_2"], "and not the baseline")


func test_order_and_repeats_of_tune_lines_do_not_matter_and_the_last_write_wins() -> void:
	var l1: String = _rule_line("bite_reach_mult")
	var l2: String = _rule_line("bite_cone_deg")
	var ab: Dictionary = TS.composite({}, [l1, l2])
	var ba: Dictionary = TS.composite({}, [l2, l1])
	var abab: Dictionary = TS.composite({}, [l1, l2, l1, l2])
	assert_eq(ab["hash"], ba["hash"], "order does not matter (hash)")
	assert_eq(ab["hash"], abab["hash"], "repeating a line does not matter (hash)")
	var e: Dictionary = _row("rules", "bite_reach_mult")
	var first: String = "tune %s %s" % [e.get("id"), TS.fmt(float(e.get("max", 2.0)))]
	assert_eq(TS.composite({}, [first, l1])["hash"], TS.composite({}, [l1])["hash"], "last write wins (hash)")


func test_setting_the_data_value_explicitly_does_not_change_the_trajectory() -> void:
	var line: String = _line("rules", "bite_reach_mult", _data_f("bite_reach_mult"))
	assert_eq(TS.composite({}, [line])["trace"], _base_composite()["trace"], "override == data value: same entities and events")
