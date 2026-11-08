extends TestCase
## T1.6 bite lunge, data half: `lunge_strength` in rules/core.json (shipped 0.0, append-only, nothing else retuned),
## `lunge_distance_m` on every size band (required, finite >= 0, modest inert starting values), their rows in the tuning
## registry (data/god/tuning.json) and the docs (docs/data/rules.md, docs/data/size_bands.md, the decision log).
## The behaviour is in test_bite_lunge_sim.gd / _geometry.gd, the strength-0 identity in test_bite_lunge_identity.gd.

const LS := preload("res://tests/lunge_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const SS := preload("res://tests/species_stats_support.gd")

## core.json key order before T1.6 (append-only: this list must stay a prefix, the lunge keys come after it).
const CORE_KEY_PREFIX: Array[String] = ["swallow_ratio", "hunger_max", "hunger_full_to_empty_s", "hunger_per_xp",
	"starvation_hp_frac_per_s", "regen_min_hunger_frac", "regen_hp_frac_per_s", "death_xp_loss_frac", "respawn_delay_s",
	"predator_hunt_ratio", "predator_give_up_s", "retaliate_duration_s", "player_hp_model", "grid_cell_m", "mouth_reach_mult",
	"mouth_cone_deg", "bite_cooldown_s", "bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "npc_scale",
	"spawn", "tiers", "schools", "quality", "xp_falloff", "hiding", "mutation_offer_count", "swim", "remains", "presence", "feedback",
	"aim_assist_strength", "aim_assist_cone_deg", "aim_assist_max_distance_m", "aim_assist_stickiness"]
const PRE_REGISTRY_ROWS: int = 14


func after_each() -> void:
	SS.cleanup()


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _core() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/rules/core.json"))


func _bands_doc() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/size_bands/size_bands.json"))


## ContentDB loaded from a temp copy of the data where `edit.call(bands: Array)` changed the size band records.
func _db_with_bands(edit: Callable) -> ContentDB:
	return SS.db_with(func(root: String) -> void:
		var path: String = root.path_join("size_bands/size_bands.json")
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		edit.call(doc["bands"])
		SS.write_text(path, JSON.stringify(doc, "\t")))


func _lunge_errors(db: ContentDB) -> Array[String]:
	var out: Array[String] = []
	for e: Variant in db.errors:
		if str(e).contains(LS.KEY_BAND_M):
			out.append(str(e))
	return out


# ======================================================================= rules/core.json

func test_lunge_strength_exists_as_a_number() -> void:
	assert_true(TS.has_num(S3.rule(S3.content(), LS.KEY_STRENGTH)), "rules/core.json has a numeric lunge_strength")


func test_the_shipped_strength_is_exactly_zero() -> void:
	assert_eq(float(_core().get(LS.KEY_STRENGTH, -1.0)), 0.0, "night constraint: lunge_strength ships as 0.0 (off)")


func test_core_json_stays_append_only_and_the_new_keys_come_last() -> void:
	var keys: Array = _core().keys()
	for i in CORE_KEY_PREFIX.size():
		assert_true(i < keys.size() and str(keys[i]) == CORE_KEY_PREFIX[i], "core.json key #%d is still %s" % [i, CORE_KEY_PREFIX[i]])
	assert_true(keys.find(LS.KEY_STRENGTH) >= CORE_KEY_PREFIX.size(), "lunge_strength is appended after the existing keys")


func test_no_existing_rule_value_was_retuned() -> void:
	var c: Dictionary = _core()
	# keep only the pre-T1.6 keys: robust to keys appended by any later task
	for k: Variant in c.keys().duplicate():
		if not CORE_KEY_PREFIX.has(str(k)):
			c.erase(k)
	assert_eq(JSON.stringify(c).sha256_text(), LS.CORE_SHA_BEFORE, "rules/core.json restricted to the pre-T1.6 keys is byte-for-byte the pre-T1.6 content (values and order)")


func test_content_db_loads_clean_with_the_new_keys() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	assert_eq(db.errors.size(), 0, "ContentDB loads clean (got %s)" % [db.errors])


# ======================================================================= size_bands.json

func test_every_band_carries_a_finite_non_negative_distance() -> void:
	var db: ContentDB = S3.content()
	assert_eq(db.band_count(), 4, "four shipped bands")
	for b in range(1, db.band_count() + 1):
		var v: Variant = db.get_band(b).get(LS.KEY_BAND_M)
		assert_true(TS.has_num(v), "band %d has a numeric %s (got %s)" % [b, LS.KEY_BAND_M, v])
		if TS.has_num(v):
			assert_true(is_finite(float(v)) and float(v) >= 0.0, "band %d %s finite and >= 0 (got %s)" % [b, LS.KEY_BAND_M, v])


func test_the_starting_distances_are_modest() -> void:
	# task: roughly 0.5-1 body length of the band's middle length; the test allows 0.25 .. 1.5 body lengths
	var db: ContentDB = S3.content()
	for b in range(1, db.band_count() + 1):
		var lm: Dictionary = db.get_band(b)["length_m"]
		var mid: float = sqrt(float(lm["min"]) * float(lm["max"]))
		var d: float = LS.shipped_band_m(db, b)
		assert_true(d >= 0.25 * mid and d <= 1.5 * mid, "band %d: %s %.3f m within 0.25 .. 1.5 x the middle length %.3f m" % [b, LS.KEY_BAND_M, d, mid])


func test_no_existing_band_value_was_retuned() -> void:
	var doc: Dictionary = _bands_doc()
	for b: Variant in doc["bands"]:
		(b as Dictionary).erase(LS.KEY_BAND_M)
	assert_eq(JSON.stringify(doc).sha256_text(), LS.BANDS_SHA_BEFORE, "size_bands.json without lunge_distance_m is byte-for-byte the pre-T1.6 content")


func test_a_missing_distance_on_any_band_is_rejected() -> void:
	for victim: int in [0, 2]:
		var db: ContentDB = _db_with_bands(func(bands: Array) -> void: (bands[victim] as Dictionary).erase(LS.KEY_BAND_M))
		assert_false(_lunge_errors(db).is_empty(), "band index %d without %s is a load error naming the key (errors: %s)" % [victim, LS.KEY_BAND_M, db.errors])


func test_bad_distances_are_rejected_with_the_key_in_the_message() -> void:
	var bad: Array = [-0.5, -1e-9, "1.5", null, true, [1.0], {"v": 1.0}]
	for value: Variant in bad:
		var db: ContentDB = _db_with_bands(func(bands: Array) -> void: (bands[1] as Dictionary)[LS.KEY_BAND_M] = value)
		assert_false(_lunge_errors(db).is_empty(), "%s = %s rejected (errors: %s)" % [LS.KEY_BAND_M, var_to_str(value), db.errors])


func test_zero_and_large_distances_are_accepted() -> void:
	for value: float in [0.0, 0.001, 1000.0]:
		var db: ContentDB = _db_with_bands(func(bands: Array) -> void: (bands[2] as Dictionary)[LS.KEY_BAND_M] = value)
		assert_eq(_lunge_errors(db).size(), 0, "%s = %s is valid (errors: %s)" % [LS.KEY_BAND_M, value, db.errors])


# ======================================================================= tuning registry rows

func test_the_registry_has_a_rules_row_for_the_strength() -> void:
	var row: Dictionary = TS.entry_for("rules", LS.KEY_STRENGTH)
	assert_false(row.is_empty(), "data/god/tuning.json has a rules row for lunge_strength")
	if row.is_empty():
		return
	assert_eq(float(row["min"]), 0.0, "strength slider starts at 0")
	assert_eq(float(row["max"]), 1.0, "strength slider ends at 1")
	assert_true(float(row["step"]) > 0.0 and float(row["step"]) <= 0.25, "strength step in (0, 0.25]")


func test_the_registry_has_a_band_row_for_the_distance() -> void:
	var row: Dictionary = TS.entry_for("band", LS.KEY_BAND_M)
	assert_false(row.is_empty(), "data/god/tuning.json has a band row for lunge_distance_m (applies to every band)")
	if row.is_empty():
		return
	var db: ContentDB = S3.content()
	var biggest: float = 0.0
	for b in range(1, db.band_count() + 1):
		var d: float = LS.shipped_band_m(db, b)
		biggest = maxf(biggest, d)
		assert_true(d >= float(row["min"]) and d <= float(row["max"]), "band %d shipped %.3f inside the slider range [%s, %s]" % [b, d, row["min"], row["max"]])
	assert_true(float(row["min"]) >= 0.0, "distance slider never negative")
	assert_true(float(row["max"]) >= 2.0 * biggest, "slider leaves room to tune: max %s >= 2 x the biggest shipped %.3f" % [row["max"], biggest])
	assert_true(float(row["step"]) > 0.0 and float(row["min"]) < float(row["max"]), "step > 0 and min < max")


func test_the_existing_fourteen_rows_are_kept() -> void:
	assert_true(TS.entries().size() >= PRE_REGISTRY_ROWS + 2, "14 earlier rows + the two lunge rows (got %d)" % TS.entries().size())
	for path: String in ["bite_reach_mult", "bite_cone_deg", "bite_buffer_s", "bite_miss_cooldown_s", "bite_cooldown_s", "aim_assist_strength", "aim_assist_cone_deg", "aim_assist_max_distance_m", "aim_assist_stickiness"]:
		assert_false(TS.entry_for("rules", path).is_empty(), "row %s kept" % path)
	for path: String in ["swim_speed_mps", "accel_mps2", "drag_per_s", "turn_rate_deg_s", "brake_decel_mps2"]:
		assert_false(TS.entry_for("band", path).is_empty(), "row %s kept" % path)


func test_the_validator_accepts_the_registry_with_the_new_rows() -> void:
	var res: Dictionary = TS.validate(TS.entries_raw())
	if not bool(res["found"]):
		assert_true(false, "no registry validator found under the NAME TABLE names (tuning_support.gd VALIDATE_METHODS)")
		return
	assert_true(bool(res["ok"]), "validator accepts the shipped registry incl. lunge rows (errors: %s)" % [res["errors"]])


func test_both_rows_are_tunable_through_the_console() -> void:
	var w: SimWorld = S3.make_world(LS.SEED, {})
	var p: SimEntity = TS.player(w)
	var cmds: GodCommands = TS.commands()
	for pair: Array in [["rules", LS.KEY_STRENGTH], ["band", LS.KEY_BAND_M]]:
		var row: Dictionary = TS.entry_for(str(pair[0]), str(pair[1]))
		if row.is_empty():
			assert_true(false, "row for %s missing" % pair[1])
			continue
		var id: String = str(row["id"])
		var v: float = TS.alt_value(row, S3.content())
		var ans: String = TS.tune(cmds, w, p.id, "tune %s %s" % [id, TS.fmt(v)])
		var low: String = ans.to_lower()
		assert_false(low.contains("unknown") or low.contains("error") or low.contains("usage") or low.contains("refus") or low.contains("outside"), "tune %s %s accepted (answer: %s)" % [id, TS.fmt(v), ans])
		assert_true(TS.tune(cmds, w, p.id, "tune list").contains(id), "`tune list` shows %s" % id)
	TS.tune(cmds, w, p.id, "tune reset")


func test_an_out_of_range_strength_is_rejected_and_leaves_the_layer_empty() -> void:
	var id: String = TS.id_for("rules", LS.KEY_STRENGTH)
	if id.is_empty():
		assert_true(false, "row for lunge_strength missing")
		return
	var clean: SimWorld = LS.world(0.0)
	TS.player(clean)
	for _i in 5:
		clean.step()
	for bad: String in ["2", "-0.1", "nan", "abc"]:
		var w: SimWorld = LS.world(0.0)
		var p: SimEntity = TS.player(w)
		TS.tune(TS.commands(), w, p.id, "tune %s %s" % [id, bad])
		for _i in 5:
			w.step()
		assert_eq(w.state_hash(), clean.state_hash(), "`tune %s %s` was rejected: the hash is the clean one" % [id, bad])


# ======================================================================= docs

func test_size_bands_md_documents_the_distance() -> void:
	var text: String = FileAccess.get_file_as_string(_repo("docs/data/size_bands.md"))
	assert_false(text.is_empty(), "docs/data/size_bands.md exists")
	assert_true(text.contains("`%s`" % LS.KEY_BAND_M), "docs/data/size_bands.md documents `lunge_distance_m`")


func test_rules_md_documents_the_strength() -> void:
	var text: String = FileAccess.get_file_as_string(_repo("docs/data/rules.md"))
	assert_true(text.contains("`%s`" % LS.KEY_STRENGTH), "docs/data/rules.md documents `lunge_strength`")
	assert_true(text.to_lower().contains("lunge"), "rules.md names the feature (lunge)")


func test_the_inert_starting_values_are_logged_as_an_orchestrator_default_decision() -> void:
	var dir: String = _repo("docs/decisions")
	var found: bool = false
	for f: String in TS.files_below(dir):
		if not f.ends_with(".md"):
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		if text.contains(LS.KEY_BAND_M) and text.contains("orchestrator-default"):
			found = true
	assert_true(found, "docs/decisions/*.md has a `decided_by: orchestrator-default` entry naming lunge_distance_m")
