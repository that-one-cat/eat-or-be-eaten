extends TestCase
## T1.7 per-species movement stats, sim side (end to end, real SimWorld runs on the shipped data):
##  1. IDENTITY: deterministic runs (scripted player in all 4 bands, the shipped-spawner world with schools, one run per
##     species with an NPC and a player) reproduce the state_hash captured BEFORE the change (BASELINE_HASHES in
##     species_stats_support.gd). An explicit all-1.0 player_profile reproduces them too.
##  2. PROFILE: a non-default player_profile multiplier changes player speed / turn / accel / drag / brake by exactly
##     that factor (analytic expectations from the band table), band by band, and does NOT touch NPCs.
##  3. NPC speed still comes from data (swim_speed_mps drives wander / flee speed).
## Sim stepped by hand, no real waits. Each test builds its own worlds; temp data trees are removed in after_each.

const SS := preload("res://tests/species_stats_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const DT: float = SimWorld.TICK_DT

var db: ContentDB


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")


func after_each() -> void:
	SS.cleanup()


func _band(b: int, key: String) -> float:
	return float(db.get_band(b)[key])


func _hash_msg(name: String, got: int, want: int) -> String:
	return "state_hash of '%s' changed: baseline %d, now %d (identity backfill must be bit-identical)" % [name, want, got]


# ======================================================== identity: pre-change state_hash baselines

func test_identity_player_movement_hash_in_every_band() -> void:
	for b in range(1, 5):
		var key: String = "player_band_%d" % b
		var got: int = SS.hash_player_band(db, b)
		assert_eq(got, int(SS.BASELINE_HASHES[key]), _hash_msg(key, got, int(SS.BASELINE_HASHES[key])))


func test_identity_real_world_with_spawners_schools_and_bites() -> void:
	var a: int = SS.hash_real_world(db, 4242, 900, 0)
	assert_eq(a, int(SS.BASELINE_HASHES["s3_real_4242_900"]), _hash_msg("s3_real_4242_900", a, int(SS.BASELINE_HASHES["s3_real_4242_900"])))
	var b: int = SS.hash_real_world(db, 77, 1800, 1)
	assert_eq(b, int(SS.BASELINE_HASHES["s3_real_77_1800"]), _hash_msg("s3_real_77_1800", b, int(SS.BASELINE_HASHES["s3_real_77_1800"])))


func test_identity_npc_run_hash_for_every_species() -> void:
	for id: String in SS.SHIPPED_SPECIES:
		var key: String = "npc_%s" % id
		var got: int = SS.hash_npc(db, id)
		assert_eq(got, int(SS.BASELINE_HASHES[key]), _hash_msg(key, got, int(SS.BASELINE_HASHES[key])))


func test_identity_explicit_unit_profile_reproduces_the_baselines() -> void:
	var unit_db: ContentDB = SS.db_with(func(root: String) -> void: SS.edit_profile_all(root, 1.0))
	assert_true(unit_db.is_valid(), "all-1.0 profile must validate:\n%s" % "\n".join(unit_db.errors))
	for b in range(1, 5):
		var key: String = "player_band_%d" % b
		assert_eq(SS.hash_player_band(unit_db, b), int(SS.BASELINE_HASHES[key]), "explicit 1.0 profile: %s" % key)
	assert_eq(SS.hash_real_world(unit_db, 4242, 900, 0), int(SS.BASELINE_HASHES["s3_real_4242_900"]), "explicit 1.0 profile: real world")
	assert_eq(SS.hash_npc(unit_db, "small_reef_fish"), int(SS.BASELINE_HASHES["npc_small_reef_fish"]), "explicit 1.0 profile: NPC of the player species")


func test_identity_probe_scenarios_are_not_vacuous() -> void:
	# The baselines mean something only if the scenarios move things and differ from each other.
	var seen: Dictionary = {}
	for k: String in SS.BASELINE_HASHES.keys():
		seen[int(SS.BASELINE_HASHES[k])] = true
	assert_eq(seen.size(), SS.BASELINE_HASHES.size(), "every probe scenario has its own hash")
	var w: SimWorld = SS.lane_world(db, 2)
	var e: SimEntity = SS.lane_player(w)
	var start: Vector3 = e.position
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 1.0))
	S2.run(w, 60)
	assert_true(e.position.distance_to(start) > 3.0, "the probe player really swims")


# ======================================================== player profile: end to end

func test_default_player_speed_is_the_band_table_value() -> void:
	for b in range(1, 5):
		assert_almost_eq(SS.peak_speed(db, b, 150), _band(b, "swim_speed_mps"), 1e-3, "band %d: default profile = band swim_speed_mps" % b)


func test_profile_speed_multiplier_scales_player_top_speed_in_every_band() -> void:
	for mult: float in [0.5, 1.5, 2.0]:
		var pdb: ContentDB = SS.db_with_profile("speed", mult)
		assert_true(pdb.is_valid(), "speed x%s must validate:\n%s" % [mult, "\n".join(pdb.errors)])
		for b in range(1, 5):
			var want: float = _band(b, "swim_speed_mps") * mult
			var got: float = SS.peak_speed(pdb, b, 200)
			assert_almost_eq(got, want, 0.02 * want + 1e-3, "band %d, speed x%s: peak %s, expected band x mult = %s (profile key candidates: %s)" % [b, mult, got, want, SS.PROFILE_KEYS["speed"]])


func test_profile_speed_multiplier_scales_boosted_top_speed_too() -> void:
	var pdb: ContentDB = SS.db_with_profile("speed", 1.5)
	var w: SimWorld = SS.lane_world(pdb, 2)
	var e: SimEntity = SS.lane_player(w)
	w.submit(SimCommand.move(e.id, Vector3.RIGHT, 1.0))
	w.submit(SimCommand.boost(e.id, true))
	var peak: float = 0.0
	for i in 60:
		w.step()
		peak = maxf(peak, e.velocity.length())
	var want: float = _band(2, "swim_speed_mps") * 1.5 * float(db.get_ability(&"boost")["speed_mult"])
	assert_almost_eq(peak, want, 0.03 * want, "boost peak = band x profile x boost speed_mult")


func test_profile_turn_multiplier_scales_turn_rate() -> void:
	var ticks: int = 3
	var base: float = SS.heading_turned_deg(db, 2, ticks, 120.0)
	assert_almost_eq(base, _band(2, "turn_rate_deg_s") * DT * ticks, 0.5, "default turn = band turn_rate_deg_s x time")
	for mult: float in [0.5, 2.0]:
		var got: float = SS.heading_turned_deg(SS.db_with_profile("turn", mult), 2, ticks, 120.0)
		assert_almost_eq(got, base * mult, 0.5, "turn x%s: heading moved %s deg, expected %s" % [mult, got, base * mult])


func test_profile_accel_multiplier_scales_acceleration() -> void:
	var ticks: int = 3  # still far below the band max speed: pure acceleration phase
	var base: float = SS.speed_after_thrust(db, 2, ticks)
	assert_almost_eq(base, _band(2, "accel_mps2") * DT * ticks, 0.02, "default accel = band accel_mps2 x time")
	for mult: float in [0.5, 2.0]:
		var got: float = SS.speed_after_thrust(SS.db_with_profile("accel", mult), 2, ticks)
		assert_almost_eq(got, base * mult, 0.02, "accel x%s: speed %s, expected %s" % [mult, got, base * mult])


func test_profile_drag_multiplier_scales_coasting_decay() -> void:
	var v0: float = 3.0
	var ticks: int = 15
	var drag: float = _band(2, "drag_per_s")
	assert_almost_eq(SS.speed_after_coast(db, 2, v0, ticks), v0 * exp(-drag * DT * ticks), 0.02, "default coast follows band drag_per_s")
	for mult: float in [0.5, 2.0]:
		var got: float = SS.speed_after_coast(SS.db_with_profile("drag", mult), 2, v0, ticks)
		assert_almost_eq(got, v0 * exp(-drag * mult * DT * ticks), 0.02, "drag x%s: speed %s after coasting" % [mult, got])


func test_profile_brake_multiplier_scales_braking_deceleration() -> void:
	var v0: float = 4.0
	var ticks: int = 6
	var brake: float = _band(2, "brake_decel_mps2")
	assert_almost_eq(SS.speed_after_brake(db, 2, v0, ticks), v0 - brake * DT * ticks, 0.02, "default brake follows band brake_decel_mps2")
	for mult: float in [0.5, 1.5]:
		var got: float = SS.speed_after_brake(SS.db_with_profile("brake", mult), 2, v0, ticks)
		assert_almost_eq(got, maxf(v0 - brake * mult * DT * ticks, 0.0), 0.02, "brake x%s: speed %s after braking" % [mult, got])


func test_profile_multipliers_are_independent() -> void:
	# speed x2 must not change turn rate or acceleration (each multiplier owns one quantity).
	var pdb: ContentDB = SS.db_with_profile("speed", 2.0)
	assert_almost_eq(SS.heading_turned_deg(pdb, 2, 3, 120.0), SS.heading_turned_deg(db, 2, 3, 120.0), 1e-6, "speed multiplier leaves turn rate alone")
	assert_almost_eq(SS.speed_after_thrust(pdb, 2, 3), SS.speed_after_thrust(db, 2, 3), 1e-6, "speed multiplier leaves acceleration alone")
	var tdb: ContentDB = SS.db_with_profile("turn", 2.0)
	assert_almost_eq(SS.peak_speed(tdb, 2, 150), _band(2, "swim_speed_mps"), 1e-3, "turn multiplier leaves top speed alone")


func test_profile_changes_the_player_run_hash_only_when_not_default() -> void:
	var fast: int = SS.hash_player_band(SS.db_with_profile("speed", 1.5), 2)
	assert_ne(fast, int(SS.BASELINE_HASHES["player_band_2"]), "speed x1.5 must change the player run (otherwise the multiplier is not consumed)")


# ======================================================== profile is player-only; NPC speed stays data-driven

## NPC of the player species wandering with an idle player far away: [peak speed, final position, final hash].
func _npc_run(content: ContentDB, species: StringName, ticks: int) -> Array:
	var w := SimWorld.new(21, content)
	var far: Vector3 = S3.ARENA + Vector3(150.0, 0.0, 0.0)
	S3.player_at(w, far, 0.0)
	var npc: SimEntity = S3.npc_at(w, species, S3.ARENA)
	var peak: float = 0.0
	for i in ticks:
		w.step()
		peak = maxf(peak, npc.velocity.length())
	return [peak, npc.position, w.state_hash()]


func test_player_profile_does_not_touch_npcs_of_the_same_species() -> void:
	var player_species: StringName = SS.player_species_id(db)
	var base: Array = _npc_run(db, player_species, 400)
	var fast_db: ContentDB = SS.db_with_profile("speed", 2.0)
	var fast: Array = _npc_run(fast_db, player_species, 400)
	assert_eq(fast[1], base[1], "NPC %s ends at the same place whatever the player profile says" % player_species)
	assert_eq(fast[0], base[0], "NPC peak speed unchanged by the player profile")
	assert_true(float(base[0]) > 0.0, "test setup: the NPC really swims")


func test_npc_speed_still_follows_swim_speed_mps_in_data() -> void:
	var sp: StringName = &"small_reef_fish"
	var base: Array = _npc_run(db, sp, 90)
	var frac: float = float((db.get_species(sp)["behaviour"] as Dictionary)["wander_speed_frac"])
	var cruise: float = float(db.get_species(sp)["swim_speed_mps"]) * frac
	assert_true(float(base[0]) > 0.0 and float(base[0]) <= cruise * 1.05 + 1e-6, "NPC wander speed %s must not exceed swim_speed_mps x wander_speed_frac = %s" % [base[0], cruise])
	var doubled: ContentDB = SS.db_with(func(root: String) -> void:
		var path: String = root.path_join("species/%s.json" % String(sp))
		var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		rec["swim_speed_mps"] = float(rec["swim_speed_mps"]) * 2.0
		var blk: Dictionary = SS.block_with(rec, "swim_speed_mps")
		if not blk.is_empty():
			blk["swim_speed_mps"] = rec["swim_speed_mps"]
		SS.write_text(path, JSON.stringify(rec, "\t")))
	var fast: Array = _npc_run(doubled, sp, 90)
	assert_almost_eq(float(fast[0]), float(base[0]) * 2.0, 0.05 * float(base[0]) * 2.0 + 1e-6, "doubling swim_speed_mps doubles the NPC speed (data-driven, hard rule 8)")
