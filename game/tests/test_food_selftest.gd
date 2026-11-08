extends TestCase
## Self-test of the food test kit (food_support.gd): the dynamic-access mechanisms the other test_food_* / test_krill_*
## files rely on work on the CURRENT tree (they do not need the implementation), and the controlled world is sane.

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")


func after_each() -> void:
	F.cleanup_temp()


func test_a_static_method_can_be_called_through_a_loaded_script() -> void:
	var s: GDScript = F.script_at("res://scripts/sim/sim_rules.gd")
	assert_not_null(s, "sim_rules.gd loads")
	assert_true(F.script_has(s, "can_swallow"), "script_has finds a static method")
	assert_false(F.script_has(s, "no_such_method"), "script_has is false for a missing method")
	assert_true(bool(s.call("can_swallow", 1.0, 0.05, 0.1)), "static call through the script object works (food kit relies on it)")
	assert_null(F.script_at("res://scripts/sim/no_such_script.gd"), "a missing script is null, not an error")


func test_missing_api_is_reported_not_raised() -> void:
	assert_true(F.require(self, PackedStringArray()), "no problems -> proceed")
	if F.strict():
		return   # strict mode makes pending() a failure by design; nothing more to check here
	assert_false(F.require(self, PackedStringArray(["FoodSites.site_count"])), "problems -> do not proceed")
	assert_eq(failures.size(), 0, "lenient mode records no failure (prints PENDING instead)")


func test_the_controlled_world_steps_and_holds_a_pinned_player() -> void:
	var w: SimWorld = F.make_world(5)
	var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0)
	var evs: Array[SimEvent] = F.run(w, 30, {p.id: S3.ARENA})
	assert_eq(w.tick, 30, "30 ticks stepped")
	var names: Array[String] = []
	for ev: SimEvent in evs:
		if ev.type != SimEvent.Type.ENTITY_SPAWNED:
			names.append(SimEvent.Type.keys()[ev.type])
	assert_eq(names.size(), 0, "nothing happens in empty controlled water (no spawners, schools, plankton or krill): %s" % [names])
	assert_true(p.position.distance_to(S3.ARENA) < 1e-6, "the player stays pinned")
	assert_true(w.map.get("krill") is Array and (w.map["krill"] as Array).is_empty(), "controlled world: map.krill = []")


func test_expected_value_helpers_match_the_sim_formulas() -> void:
	var w: SimWorld = F.make_world(6)
	var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0)
	var rec: Dictionary = F.good_food_record()
	assert_almost_eq(F.expect_max_hp(rec), 100.0 * 0.1 * 0.1 * 2.0, 1e-9, "max hp = base_hp * L^2 * hp_mult")
	assert_almost_eq(F.bite_dmg(w, p), 25.0 * 0.1 * 0.1, 1e-9, "B1 bite at 0.10 m = bite_power 25 * L^2 (small_reef_fish bite_mult 1)")
	assert_eq(F.bites_to_kill(2.0, 0.25), 8, "2 hp / 0.25 = 8 bites (research 3.3 starfish at L_p 0.10)")
	assert_almost_eq(F.band_mult(rec, 3), 0.5, 1e-12, "xp_band_mult is indexed by the player band")
	assert_almost_eq(F.band_mult({}, 3), 1.0, 1e-12, "no xp_band_mult = 1")
	assert_almost_eq(F.expect_hunger(w.content, rec), 3.0 * 10.0, 1e-9, "hunger = hunger_xp * hunger_per_xp")


func test_temp_data_copy_round_trips_through_content_db() -> void:
	var db: ContentDB = F.db_with(func(root: String) -> void:
		F.write_json(root.path_join("notes/zz_note.json"), {"id": "zz_note"}))
	assert_true(db.is_valid(), "an untouched data copy loads: %s" % [db.errors])
	assert_true(FileAccess.file_exists(F.TMP_ROOT.path_join("maps/reef.json")), "maps/reef.json copied")
	assert_true(FileAccess.file_exists(F.TMP_ROOT.path_join("notes/zz_note.json")), "the edit callback ran")
