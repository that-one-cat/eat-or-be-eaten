extends TestCase
## ContentDB against the REAL data in res://data: everything loads, counts and key numbers match
## docs/GAME_DESIGN.md sections 2-4 and the S0 API contract.

const SPECIES_IDS: Array[String] = [
	"barracuda", "giant_shark", "grouper", "krill_abyss", "krill_open", "krill_shallows", "plankton", "puffer", "shark",
	"silver_schooling_fish", "small_reef_fish",
]
const MUTATION_IDS: Array[String] = [
	"hunter_bite_dash", "hunter_bite_power", "hunter_swim_speed", "hunter_turbo_boost",
	"survivor_armor_scales", "survivor_efficient_metabolism", "survivor_sonar", "survivor_wide_vision",
]
const ABILITY_IDS: Array[String] = ["bite_dash", "boost", "sonar"]

var db: ContentDB


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")


func _sorted_strings(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for i in ids:
		out.append(str(i))
	out.sort()
	return out


# ---- whole database ----

func test_real_data_is_valid() -> void:
	assert_not_null(db, "load_from_dir returns a ContentDB")
	assert_true(db.is_valid(), "real data must validate, errors:\n%s" % "\n".join(db.errors))
	assert_eq(db.errors.size(), 0, "no errors on real data")


func test_load_is_repeatable() -> void:
	var other := ContentDB.load_from_dir()  # default root is res://data
	assert_true(other.is_valid(), "default root loads")
	assert_eq(_sorted_strings(other.species_ids()), _sorted_strings(db.species_ids()), "same species on a second load")


# ---- species ----

func test_exactly_eight_species_with_contract_ids() -> void:
	assert_eq(db.species_ids().size(), 11, "8 species (GAME_DESIGN section 3) + 3 krill cloud species (map krill fields)")
	assert_eq(_sorted_strings(db.species_ids()), SPECIES_IDS, "species ids")


func test_species_record_ids_match_keys_and_validate_individually() -> void:
	for id in db.species_ids():
		var rec: Dictionary = db.get_species(id)
		assert_eq(str(rec.get("id")), str(id), "record id of %s equals its key" % id)
		var errs: PackedStringArray = ContentDB.validate_record(&"species", rec, "species/%s.json" % id)
		assert_eq(errs.size(), 0, "real record %s validates: %s" % [id, "; ".join(errs)])


func test_species_required_fields_present_and_in_range() -> void:
	for id in db.species_ids():
		var rec: Dictionary = db.get_species(id)
		assert_has(["predator", "retaliate", "passive"], rec.get("temperament"), "%s temperament in enum" % id)
		assert_has(["ambient", "interactive", "large"], rec.get("tier"), "%s tier in enum" % id)
		var len_m: Dictionary = rec.get("length_m", {})
		assert_true(float(len_m.get("min", 0.0)) > 0.0, "%s length min > 0" % id)
		assert_true(float(len_m.get("max", 0.0)) >= float(len_m.get("min", 1.0)), "%s length max >= min" % id)
		assert_true(float(rec.get("base_hp", 0.0)) > 0.0, "%s base_hp > 0" % id)
		assert_true(float(rec.get("xp", -1.0)) >= 0.0, "%s xp >= 0" % id)
		assert_true(rec.get("zones") is Array, "%s zones is an array" % id)


func test_unknown_species_returns_empty_dictionary() -> void:
	assert_true(db.get_species(&"kraken").is_empty(), "unknown species id yields an empty dictionary")


func test_species_temperaments_match_design() -> void:
	var expected: Dictionary = {
		"plankton": "passive", "silver_schooling_fish": "passive", "small_reef_fish": "passive",
		"puffer": "retaliate", "barracuda": "predator", "grouper": "retaliate",
		"shark": "predator", "giant_shark": "predator",
	}
	for id in expected:
		assert_eq(str(db.get_species(StringName(id)).get("temperament")), expected[id], "temperament of %s (GAME_DESIGN section 3)" % id)


func test_species_lengths_match_design() -> void:
	# GAME_DESIGN section 3 (starting values; if the balance pass retunes them, update this table with it).
	var expected: Dictionary = {
		"plankton": [0.01, 0.02], "silver_schooling_fish": [0.08, 0.15], "small_reef_fish": [0.10, 0.20],
		"puffer": [0.30, 0.50], "barracuda": [0.8, 1.5], "grouper": [1.0, 2.0], "shark": [2.5, 3.5],
	}
	for id in expected:
		var len_m: Dictionary = db.get_species(StringName(id)).get("length_m", {})
		assert_almost_eq(float(len_m.get("min", -1.0)), expected[id][0], 1e-4, "%s length min" % id)
		assert_almost_eq(float(len_m.get("max", -1.0)), expected[id][1], 1e-4, "%s length max" % id)
	var boss: Dictionary = db.get_species(&"giant_shark").get("length_m", {})
	assert_true(float(boss.get("min", 99.0)) <= 10.0 and float(boss.get("max", 0.0)) >= 10.0, "giant shark covers 10 m")


## GAME_DESIGN section 2 XP values are starting numbers, tuned in the S7 balance pass (all prey x1.5); what the design
## fixes is the order (bigger prey is worth more) and the boss giving no XP (win instead).
func test_species_xp_matches_design() -> void:
	var order: Array[String] = ["plankton", "silver_schooling_fish", "small_reef_fish", "puffer", "barracuda", "grouper", "shark"]
	for i in range(1, order.size()):
		var lo: float = float(db.get_species(StringName(order[i - 1])).get("xp", -1.0))
		var hi: float = float(db.get_species(StringName(order[i])).get("xp", -1.0))
		assert_true(lo > 0.0 and hi > lo, "xp of %s (%s) > xp of %s (%s) (GAME_DESIGN section 2 order)" % [order[i], str(hi), order[i - 1], str(lo)])
	assert_almost_eq(float(db.get_species(&"giant_shark").get("xp", -1.0)), 0.0, 1e-12, "the boss gives no XP (win instead)")


func test_plankton_is_ambient_tier() -> void:
	assert_eq(str(db.get_species(&"plankton").get("tier")), "ambient", "plankton is shader-only ambient (CLAUDE.md rule 4)")


# ---- size bands ----

func test_four_bands_indexed_from_one() -> void:
	assert_eq(db.band_count(), 4, "4 size bands")
	for i in range(1, 5):
		var b: Dictionary = db.get_band(i)
		assert_false(b.is_empty(), "band %d exists" % i)
		assert_eq(int(b.get("index", -1)), i, "band %d carries index %d" % [i, i])


func test_band_records_validate_individually() -> void:
	for i in range(1, 5):
		var errs: PackedStringArray = ContentDB.validate_record(&"size_band", db.get_band(i), "size_bands/size_bands.json")
		assert_eq(errs.size(), 0, "real band %d validates: %s" % [i, "; ".join(errs)])


func test_band_lengths_match_design_and_are_contiguous() -> void:
	var expected: Array = [[0.10, 0.30], [0.30, 0.90], [0.90, 2.0], [2.0, 3.5]]
	for i in range(1, 5):
		var len_m: Dictionary = db.get_band(i).get("length_m", {})
		assert_almost_eq(float(len_m.get("min", -1.0)), expected[i - 1][0], 1e-4, "B%d min length" % i)
		assert_almost_eq(float(len_m.get("max", -1.0)), expected[i - 1][1], 1e-4, "B%d max length" % i)
	for i in range(1, 4):
		var cur: Dictionary = db.get_band(i).get("length_m", {})
		var nxt: Dictionary = db.get_band(i + 1).get("length_m", {})
		assert_almost_eq(float(cur.get("max")), float(nxt.get("min")), 1e-6, "band %d max == band %d min" % [i, i + 1])


func test_band_xp_thresholds_match_design() -> void:
	var expected: Array[float] = [0.0, 100.0, 300.0, 700.0]
	for i in range(1, 5):
		assert_almost_eq(float(db.get_band(i).get("xp_to_reach", -1.0)), expected[i - 1], 1e-4, "B%d xp_to_reach" % i)


func test_band_numeric_fields_are_sane() -> void:
	var prev_cell: float = 0.0
	for i in range(1, 5):
		var b: Dictionary = db.get_band(i)
		assert_true(float(b.get("swim_speed_mps", 0.0)) > 0.0, "B%d swim_speed_mps > 0" % i)
		assert_true(float(b.get("max_hp", 0.0)) > 0.0, "B%d max_hp > 0" % i)
		assert_true(float(b.get("bite_power", 0.0)) > 0.0, "B%d bite_power > 0" % i)
		var cell: float = float(b.get("grid_cell_m", 0.0))
		assert_true(cell > 0.0, "B%d grid_cell_m > 0" % i)
		assert_true(cell >= prev_cell, "grid cells grow with the band (B%d)" % i)
		prev_cell = cell
		var cam: Dictionary = b.get("camera", {})
		assert_true(float(cam.get("distance", 0.0)) > 0.0, "B%d camera.distance > 0" % i)
		assert_true(float(cam.get("near", 0.0)) > 0.0, "B%d camera.near > 0" % i)
		assert_true(float(cam.get("far", 0.0)) > float(cam.get("near", 1e9)), "B%d camera.far > near" % i)
		var lod: Array = b.get("lod_m", [])
		assert_true(lod.size() >= 1, "B%d has LOD distances" % i)
		for j in range(1, lod.size()):
			assert_true(float(lod[j]) > float(lod[j - 1]), "B%d lod_m ascending" % i)


func test_band_for_xp_thresholds() -> void:
	assert_eq(db.band_for_xp(0.0), 1, "0 xp -> B1")
	assert_eq(db.band_for_xp(1.0), 1, "1 xp -> B1")
	assert_eq(db.band_for_xp(99.9), 1, "just below B2 threshold -> B1")
	assert_eq(db.band_for_xp(100.0), 2, "exactly 100 -> B2")
	assert_eq(db.band_for_xp(299.9), 2, "just below B3 -> B2")
	assert_eq(db.band_for_xp(300.0), 3, "exactly 300 -> B3")
	assert_eq(db.band_for_xp(699.9), 3, "just below B4 -> B3")
	assert_eq(db.band_for_xp(700.0), 4, "exactly 700 -> B4")
	assert_eq(db.band_for_xp(1200.0), 4, "1200 (max growth) -> B4")
	assert_eq(db.band_for_xp(100000.0), 4, "huge xp clamps to B4")


func test_band_for_xp_negative_clamps_to_b1() -> void:
	assert_eq(db.band_for_xp(-50.0), 1, "negative xp clamps to B1")


func test_band_for_xp_is_monotonic() -> void:
	var prev: int = 1
	var xp: float = 0.0
	while xp <= 1500.0:
		var b: int = db.band_for_xp(xp)
		assert_true(b >= prev, "band_for_xp must never decrease (xp=%f gave %d after %d)" % [xp, b, prev])
		assert_true(b >= 1 and b <= 4, "band in 1..4")
		prev = b
		xp += 7.5


# ---- mutations ----

func test_eight_mutation_nodes_with_contract_ids() -> void:
	assert_eq(db.mutation_ids().size(), 8, "8 mutation nodes (GAME_DESIGN section 4)")
	assert_eq(_sorted_strings(db.mutation_ids()), MUTATION_IDS, "mutation ids")


func test_mutation_records_validate_individually() -> void:
	for id in db.mutation_ids():
		var errs: PackedStringArray = ContentDB.validate_record(&"mutation", db.get_mutation(id), "mutations/mutations.json")
		assert_eq(errs.size(), 0, "real mutation %s validates: %s" % [id, "; ".join(errs)])


func test_mutation_tree_shape() -> void:
	var tiers: Dictionary = {
		"hunter_bite_power": 1, "hunter_bite_dash": 2, "hunter_swim_speed": 3, "hunter_turbo_boost": 4,
		"survivor_efficient_metabolism": 1, "survivor_sonar": 2, "survivor_armor_scales": 3, "survivor_wide_vision": 4,
	}
	var by_branch: Dictionary = {}
	for id in tiers:
		var m: Dictionary = db.get_mutation(StringName(id))
		assert_eq(int(m.get("tier", -1)), tiers[id], "tier of %s" % id)
		var branch: String = str(m.get("branch"))
		assert_eq(branch, "hunter" if id.begins_with("hunter_") else "survivor", "branch of %s" % id)
		by_branch[branch] = int(by_branch.get(branch, 0)) + 1
	assert_eq(by_branch.get("hunter"), 4, "hunter branch has 4 nodes")
	assert_eq(by_branch.get("survivor"), 4, "survivor branch has 4 nodes")


func test_mutation_requires_chain() -> void:
	for id in db.mutation_ids():
		var m: Dictionary = db.get_mutation(id)
		var tier: int = int(m.get("tier"))
		if tier == 1:
			assert_null(m.get("requires"), "%s (tier 1) requires nothing" % id)
			continue
		var parent: Dictionary = db.get_mutation(StringName(str(m.get("requires"))))
		assert_false(parent.is_empty(), "%s requires an existing node" % id)
		assert_eq(str(parent.get("branch")), str(m.get("branch")), "%s requires a node of the same branch" % id)
		assert_eq(int(parent.get("tier")), tier - 1, "%s requires the previous tier" % id)


func test_mutation_grants_reference_existing_abilities() -> void:
	var abilities := _sorted_strings(db.ability_ids())
	for id in db.mutation_ids():
		var m: Dictionary = db.get_mutation(id)
		if m.has("grants_ability"):
			assert_has(abilities, str(m["grants_ability"]), "%s grants an existing ability" % id)


func test_active_ability_mutations_grant_their_ability() -> void:
	assert_eq(str(db.get_mutation(&"hunter_bite_dash").get("grants_ability")), "bite_dash", "Bite-Dash node grants bite_dash")
	assert_eq(str(db.get_mutation(&"survivor_sonar").get("grants_ability")), "sonar", "Sonar node grants sonar")


# ---- abilities ----

func test_three_active_abilities() -> void:
	assert_eq(db.ability_ids().size(), 3, "3 active abilities")
	assert_eq(_sorted_strings(db.ability_ids()), ABILITY_IDS, "ability ids")
	for id in db.ability_ids():
		var a: Dictionary = db.get_ability(id)
		assert_eq(str(a.get("id")), str(id), "id matches key")
		assert_eq(str(a.get("kind")), "active", "%s is active" % id)
		assert_false(str(a.get("input_action", "")).is_empty(), "%s has an input_action" % id)
		assert_true(float(a.get("cooldown_s", -1.0)) >= 0.0, "%s cooldown_s >= 0" % id)
		var errs: PackedStringArray = ContentDB.validate_record(&"ability", a, "abilities/%s.json" % id)
		assert_eq(errs.size(), 0, "real ability %s validates: %s" % [id, "; ".join(errs)])


func test_ability_cooldowns_match_design() -> void:
	assert_almost_eq(float(db.get_ability(&"bite_dash").get("cooldown_s")), 6.0, 1e-4, "Bite-Dash cooldown 6 s")
	assert_almost_eq(float(db.get_ability(&"sonar").get("cooldown_s")), 15.0, 1e-4, "Sonar cooldown 15 s")


# ---- map ----

func test_reef_map_loads() -> void:
	assert_has(_sorted_strings(db.map_ids()), "reef", "reef map present")
	var m: Dictionary = db.get_map(&"reef")
	assert_eq(str(m.get("id")), "reef", "map id")
	assert_true((m.get("zones", []) as Array).size() > 0, "reef has zones")
	assert_true((m.get("spawners", []) as Array).size() > 0, "reef has spawners")
	var errs: PackedStringArray = ContentDB.validate_record(&"map", m, "maps/reef.json")
	assert_eq(errs.size(), 0, "real map validates: %s" % "; ".join(errs))


func test_species_zones_exist_in_reef_map() -> void:
	var zone_ids: Array[String] = []
	for z in (db.get_map(&"reef").get("zones", []) as Array):
		zone_ids.append(str((z as Dictionary).get("id")))
	for id in db.species_ids():
		for zone in (db.get_species(id).get("zones", []) as Array):
			assert_has(zone_ids, str(zone), "zone '%s' of species %s exists in maps/reef.json" % [zone, id])


# ---- rules ----

func test_rules_core_values() -> void:
	var r: Dictionary = db.rules()
	assert_false(r.is_empty(), "rules loaded")
	assert_almost_eq(float(r.get("swallow_ratio", -1.0)), 0.10, 1e-6, "swallow_ratio 0.10 (GAME_DESIGN section 2)")
	var errs: PackedStringArray = ContentDB.validate_record(&"rules", r, "rules/core.json")
	assert_eq(errs.size(), 0, "real rules validate: %s" % "; ".join(errs))


# ---- integration with the sim ----

func test_sim_world_uses_band_speed_from_content() -> void:
	var w := SimWorld.new(1, db)
	var id: int = w.spawn_entity(&"small_reef_fish", Vector3.ZERO, 0.15, true)
	var band: int = w.get_entity(id).band
	var speed: float = float(db.get_band(band).get("swim_speed_mps"))
	# S2 swim model: aim along the spawn heading (no turn), accelerate, then cruise at the band speed.
	w.submit(SimCommand.move(id, w.get_entity(id).heading, 1.0))
	for i in 90:
		w.step()
	assert_almost_eq(w.get_entity(id).speed, speed, 1e-3, "after 90 ticks the fish cruises at band-%d swim_speed_mps (%f)" % [band, speed])
