extends TestCase
## S6 data: shipped mutations / abilities / boss block are valid and carry every number the S6 sim reads (so that
## nothing is hard-coded in sim code, hard rule 8). These tests run before the sim exists (data only).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const EFFECT_KEYS: Array[String] = [
	"bite_power_mult", "swim_speed_mult", "boost_duration_mult", "boost_speed_mult", "hunger_drain_mult", "damage_taken_mult",
	"presence_sector_deg",
]

var _db: ContentDB = null


func before_each() -> void:
	_db = ContentDB.load_from_dir("res://data")


func test_shipped_data_is_valid() -> void:
	assert_true(_db.is_valid(), "ContentDB errors: %s" % "; ".join(_db.errors))


func test_every_effect_key_is_a_known_passive_with_a_sane_value() -> void:
	for id: StringName in _db.mutation_ids():
		var fx: Dictionary = _db.get_mutation(id).get("effects", {})
		for k: Variant in fx.keys():
			assert_true(EFFECT_KEYS.has(str(k)), "%s: effect key '%s' is not one the sim applies (known: %s)" % [id, str(k), ", ".join(EFFECT_KEYS)])
			var v: float = float(fx[k])
			assert_true(v > 0.0, "%s.%s must be > 0 (a multiplier), got %s" % [id, str(k), str(v)])
			if str(k) == "presence_sector_deg":
				assert_true(v <= 360.0, "%s: sector is at most 360 degrees" % id)


func test_grants_reference_active_abilities_and_each_ability_has_one_source() -> void:
	var sources: Dictionary = {}
	for id: StringName in _db.mutation_ids():
		var g: String = str(_db.get_mutation(id).get("grants_ability", ""))
		if g.is_empty():
			continue
		var ab: Dictionary = _db.get_ability(StringName(g))
		assert_false(ab.is_empty(), "%s grants unknown ability '%s'" % [id, g])
		assert_eq(str(ab.get("kind", "")), "active", "%s grants '%s', which must be an active ability" % [id, g])
		sources[g] = int(sources.get(g, 0)) + 1
	for g2: String in ["bite_dash", "sonar"]:
		assert_eq(int(sources.get(g2, 0)), 1, "%s is granted by exactly one mutation node" % g2)


func test_branches_are_chains_of_tiers() -> void:
	for id: StringName in _db.mutation_ids():
		var rec: Dictionary = _db.get_mutation(id)
		var tier: int = int(rec["tier"])
		var req: Variant = rec.get("requires")
		if tier == 1:
			assert_null(req, "%s: tier 1 has no prerequisite" % id)
			continue
		var pre: Dictionary = _db.get_mutation(StringName(str(req)))
		assert_false(pre.is_empty(), "%s requires unknown node '%s'" % [id, str(req)])
		assert_eq(int(pre.get("tier", -1)), tier - 1, "%s requires the previous tier of its branch" % id)
		assert_eq(str(pre.get("branch", "")), str(rec["branch"]), "%s requires a node of its own branch" % id)


func test_offer_count_rule() -> void:
	assert_eq(S6.offer_count(_db), 3, "rules.mutation_offer_count = 3 (GAME_DESIGN section 4)")


func test_bite_dash_record_has_what_the_sim_needs() -> void:
	var ab: Dictionary = _db.get_ability(&"bite_dash")
	assert_true(float(ab.get("lunge_distance_m", 0.0)) > 0.0, "lunge_distance_m")
	assert_true(float(ab.get("cooldown_s", 0.0)) > 0.0, "cooldown_s")
	assert_true(float(ab.get("lunge_duration_s", 0.0)) > 0.0, "lunge_duration_s > 0 (contract: new key, starting value 0.35 s)")
	assert_eq(str(ab.get("input_action", "")), "bite_dash", "input action name")


func test_sonar_record_has_what_the_sim_needs() -> void:
	var ab: Dictionary = _db.get_ability(&"sonar")
	assert_true(float(ab.get("radius_m", 0.0)) > 0.0, "radius_m")
	assert_true(float(ab.get("duration_s", 0.0)) > 0.0, "duration_s")
	assert_true(float(ab.get("cooldown_s", 0.0)) > 0.0, "cooldown_s")
	assert_eq(str(ab.get("input_action", "")), "sonar", "input action name")
	var th: Dictionary = S6.sonar_thresholds(_db)
	assert_false(is_nan(float(th["smaller"])), "a 'smaller' ratio threshold is in data (contract: thresholds in data; key names not pinned, matched by substring)")
	assert_false(is_nan(float(th["bigger"])), "a 'bigger' ratio threshold is in data")
	if not is_nan(float(th["smaller"])) and not is_nan(float(th["bigger"])):
		assert_true(float(th["smaller"]) < 1.0 and float(th["bigger"]) > 1.0, "smaller < 1 < bigger, got %s / %s" % [str(th["smaller"]), str(th["bigger"])])


func test_boss_record_has_what_the_sim_needs() -> void:
	var sp: Dictionary = _db.get_species(S6.BOSS)
	assert_false(sp.is_empty(), "giant_shark exists")
	assert_eq(str(sp.get("tier", "")), "large", "large actor")
	assert_true(float(sp.get("hp_override", 0.0)) > 0.0, "hp_override")
	var boss: Variant = sp.get("boss")
	assert_true(boss is Dictionary, "species.boss block")
	if boss is Dictionary:
		for k: String in ["engage_radius_m", "dash_windup_s", "dash_damage_frac_of_b4_max_hp", "disengage_after_s", "hp_regen_frac_per_s"]:
			assert_true((boss as Dictionary).has(k) and float((boss as Dictionary)[k]) > 0.0, "boss.%s > 0" % k)
		assert_true((boss as Dictionary).has("victory_delay_s"), "boss.victory_delay_s is in data (contract: starting 6 s; location boss.victory_delay_s is assumption A14)")
		assert_true(float((boss as Dictionary)["dash_damage_frac_of_b4_max_hp"]) < 1.0, "the dash is a fraction of max HP")
	# the boss is a real obstacle: sized like the design says and placed in the abyss
	assert_true(float((sp["length_m"] as Dictionary)["min"]) >= 8.0, "a 10 m class actor")
	assert_true((sp.get("zones", []) as Array).has("abyss"), "patrols the abyss zone")


func test_the_map_spawns_exactly_one_boss_in_the_abyss() -> void:
	var n: int = 0
	for rec_v: Variant in _db.get_map(S3.MAP_ID).get("spawners", []):
		var rec: Dictionary = rec_v
		if str(rec.get("species_id", "")) == String(S6.BOSS):
			n += int(rec.get("count", 0))
			assert_eq(str(rec.get("zone_id", "")), "abyss", "the boss spawner is in the abyss")
			assert_eq(float(rec.get("respawn_s", -1.0)), 0.0, "the boss does not respawn (a defeated boss ends the run)")
	assert_eq(n, 1, "one boss on the map")


func test_presence_rules_exist() -> void:
	var pr: Variant = _db.rules().get("presence")
	assert_true(pr is Dictionary, "rules.presence")
	if pr is Dictionary:
		assert_eq(float((pr as Dictionary)["min_length_ratio"]), 0.5, "creatures from 50% of the player's length (GAME_DESIGN section 5)")
		assert_eq(float((pr as Dictionary)["radius_m"]), 30.0, "within 30 m")
		assert_eq(float((pr as Dictionary)["sector_deg"]), 270.0, "front 270 degrees")
