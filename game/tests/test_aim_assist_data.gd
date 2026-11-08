extends TestCase
## T1.5 aim assist, data half: the four rules keys in rules/core.json (shipped strength 0.0, append-only, nothing else
## retuned), their rows in the tuning registry (data/god/tuning.json) and the docs (docs/data/rules.md, the decision
## log). The behaviour is in test_aim_assist_sim.gd.

const AS := preload("res://tests/aim_assist_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const S3 := preload("res://tests/s3_support.gd")

## core.json key order before T1.5 (append-only: this list must stay a prefix, the aim keys come after it).
const CORE_KEY_PREFIX: Array[String] = ["swallow_ratio", "hunger_max", "hunger_full_to_empty_s", "hunger_per_xp",
	"starvation_hp_frac_per_s", "regen_min_hunger_frac", "regen_hp_frac_per_s", "death_xp_loss_frac", "respawn_delay_s",
	"predator_hunt_ratio", "predator_give_up_s", "retaliate_duration_s", "player_hp_model", "grid_cell_m", "mouth_reach_mult",
	"mouth_cone_deg", "bite_cooldown_s", "bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "npc_scale",
	"spawn", "tiers", "schools", "quality", "xp_falloff", "hiding", "mutation_offer_count", "swim", "remains", "presence", "feedback"]
## SHA-256 of JSON.stringify(rules/core.json) before T1.5 (keys in file order): every existing value is unchanged.
const CORE_SHA_BEFORE: String = "47b8441c88cae03eedd3f63f84a42e2299715cbbb2c5fea556f2d12465ea72cd"
const PRE_REGISTRY_ROWS: int = 10


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _core() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/rules/core.json"))


# ======================================================================= rules/core.json

func test_the_four_keys_exist_as_numbers() -> void:
	var db: ContentDB = S3.content()
	for k: String in AS.KEYS:
		assert_true(TS.has_num(S3.rule(db, k)), "rules/core.json has a numeric %s" % k)


func test_the_shipped_strength_is_exactly_zero() -> void:
	assert_eq(float(_core().get(AS.KEY_STRENGTH, -1.0)), 0.0, "night constraint: aim_assist_strength ships as 0.0 (off)")


func test_the_inert_starting_values_are_in_range() -> void:
	var c: Dictionary = _core()
	var cone: float = float(c.get(AS.KEY_CONE, -1.0))
	var cap: float = float(c.get(AS.KEY_MAX_DIST, -1.0))
	var sticky: float = float(c.get(AS.KEY_STICKY, -1.0))
	assert_true(cone > 0.0 and cone <= 180.0, "aim_assist_cone_deg in (0, 180] (got %s)" % cone)
	assert_true(is_finite(cap) and cap > 0.0, "aim_assist_max_distance_m > 0 (got %s)" % cap)
	assert_true(sticky >= 0.0 and sticky <= 1.0, "aim_assist_stickiness in [0, 1] (got %s)" % sticky)


func test_core_json_stays_append_only_and_the_new_keys_come_last() -> void:
	var keys: Array = _core().keys()
	for i in CORE_KEY_PREFIX.size():
		assert_true(i < keys.size() and str(keys[i]) == CORE_KEY_PREFIX[i], "core.json key #%d is still %s" % [i, CORE_KEY_PREFIX[i]])
	for k: String in AS.KEYS:
		assert_true(keys.find(k) >= CORE_KEY_PREFIX.size(), "%s is appended after the existing keys" % k)


func test_no_existing_rule_value_was_retuned() -> void:
	var c: Dictionary = _core()
	# keep only the pre-T1.5 keys: robust to keys appended by any later task
	for k: Variant in c.keys().duplicate():
		if not CORE_KEY_PREFIX.has(str(k)):
			c.erase(k)
	assert_eq(JSON.stringify(c).sha256_text(), CORE_SHA_BEFORE, "rules/core.json restricted to the pre-T1.5 keys is byte-for-byte the pre-T1.5 content (values and order)")


func test_content_db_loads_clean_with_the_new_keys() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_eq(db.errors.size(), 0, "ContentDB loads clean (got %s)" % [db.errors])


# ======================================================================= tuning registry rows

func test_the_registry_has_a_rules_row_for_each_key_with_the_key_as_id() -> void:
	for k: String in AS.KEYS:
		var row: Dictionary = TS.entry_for("rules", k)
		assert_false(row.is_empty(), "data/god/tuning.json has a rules row for %s" % k)
		if not row.is_empty():
			assert_eq(str(row.get("id", "")), k, "row id = key name, so `tune %s <value>` works" % k)


func test_the_existing_ten_rows_are_kept() -> void:
	assert_true(TS.entries().size() >= PRE_REGISTRY_ROWS + AS.KEYS.size(), "ten T1.3 rows + four aim rows (got %d)" % TS.entries().size())
	for path: String in ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "bite_cooldown_s"]:
		assert_false(TS.entry_for("rules", path).is_empty(), "row %s kept" % path)
	for path: String in ["swim_speed_mps", "accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2"]:
		assert_false(TS.entry_for("band", path).is_empty(), "row %s kept" % path)


func test_row_ranges_fit_the_key_meaning_and_contain_the_shipped_values() -> void:
	var c: Dictionary = _core()
	for k: String in AS.KEYS:
		var row: Dictionary = TS.entry_for("rules", k)
		if row.is_empty():
			assert_true(false, "row for %s missing" % k)
			continue
		var lo: float = float(row["min"])
		var hi: float = float(row["max"])
		var shipped: float = float(c.get(k, NAN))
		assert_true(shipped >= lo and shipped <= hi, "%s: shipped %s inside the slider range [%s, %s]" % [k, shipped, lo, hi])
		assert_true(float(row["step"]) > 0.0 and lo < hi, "%s: step > 0 and min < max" % k)
	var s: Dictionary = TS.entry_for("rules", AS.KEY_STRENGTH)
	if not s.is_empty():
		assert_eq(float(s["min"]), 0.0, "strength slider starts at 0")
		assert_eq(float(s["max"]), 1.0, "strength slider ends at 1")
	var st: Dictionary = TS.entry_for("rules", AS.KEY_STICKY)
	if not st.is_empty():
		assert_eq(float(st["min"]), 0.0, "stickiness slider starts at 0")
		assert_eq(float(st["max"]), 1.0, "stickiness slider ends at 1")
	var cone: Dictionary = TS.entry_for("rules", AS.KEY_CONE)
	if not cone.is_empty():
		assert_true(float(cone["max"]) <= 180.0 and float(cone["min"]) >= 0.0, "cone slider within 0..180 deg")


func test_the_validator_accepts_the_registry_with_the_new_rows() -> void:
	var res: Dictionary = TS.validate(TS.entries_raw())
	if not bool(res["found"]):
		assert_true(false, "no registry validator found under the NAME TABLE names (tuning_support.gd VALIDATE_METHODS)")
		return
	assert_true(bool(res["ok"]), "validator accepts the shipped registry incl. aim rows (errors: %s)" % [res["errors"]])


func test_every_aim_key_is_tunable_through_the_console() -> void:
	var w: SimWorld = S3.make_world(AS.SEED, {})
	var p: SimEntity = TS.player(w)
	var cmds: GodCommands = TS.commands()
	for k: String in AS.KEYS:
		var row: Dictionary = TS.entry_for("rules", k)
		if row.is_empty():
			assert_true(false, "row for %s missing" % k)
			continue
		var v: float = TS.alt_value(row, S3.content())
		var ans: String = TS.tune(cmds, w, p.id, AS.tune_line(k, v))
		var low: String = ans.to_lower()
		assert_false(low.contains("unknown") or low.contains("error") or low.contains("usage") or low.contains("refus") or low.contains("outside"), "tune %s %s accepted (answer: %s)" % [k, TS.fmt(v), ans])
		var listing: String = TS.tune(cmds, w, p.id, "tune list")
		assert_true(listing.contains(k), "`tune list` shows %s" % k)
	TS.tune(cmds, w, p.id, "tune reset")


func test_the_tuning_lab_identity_still_holds_with_the_new_rows() -> void:
	# the generic T1.3 guard: an empty layer leaves every pinned hash alone (the rows are data, nothing is applied)
	assert_eq(TS.composite({}, [])["hash"], TS.BASELINE_HASHES["bite_composite"], "empty layer, bite composite")
	assert_eq(TS.held_bites({}, [])["hash"], TS.BASELINE_HASHES["held_bites"], "empty layer, held bites")


# ======================================================================= docs

func test_rules_md_documents_the_four_keys() -> void:
	var text: String = FileAccess.get_file_as_string(_repo("docs/data/rules.md"))
	assert_false(text.is_empty(), "docs/data/rules.md exists")
	for k: String in AS.KEYS:
		assert_true(text.contains("`%s`" % k), "docs/data/rules.md documents `%s`" % k)
	assert_true(text.to_lower().contains("aim assist"), "rules.md names the feature (aim assist)")


func test_the_inert_starting_values_are_logged_as_an_orchestrator_default_decision() -> void:
	var dir: String = _repo("docs/decisions")
	var found: bool = false
	for f: String in TS.files_below(dir):
		if not f.ends_with(".md"):
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		if text.contains("aim_assist") and text.contains("orchestrator-default"):
			found = true
	assert_true(found, "docs/decisions/*.md has a `decided_by: orchestrator-default` entry for the aim_assist_* starting values")
