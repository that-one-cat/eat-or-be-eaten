extends TestCase
## T1.6 bite lunge, identity at `lunge_strength` 0: with the lunge OFF the sim is bit-identical to the pre-T1.6 code.
## Every hash below was captured on the code BEFORE T1.6 (tests/lunge_support.gd BASELINE_HASHES, the T1.3 / T1.5 / T1.7
## baselines in tuning_support / aim_assist_support / species_stats_support) and must keep passing before and after the
## implementation. The scenarios are bite-heavy on purpose (about ten landed bites each, a miss run, a hard-site bite, a
## Bite-Dash ending in its bite), so any stray lunge, any new hashed byte and any changed RNG draw shows up here.

const LS := preload("res://tests/lunge_support.gd")
const TS := preload("res://tests/tuning_support.gd")
const AS := preload("res://tests/aim_assist_support.gd")
const SS := preload("res://tests/species_stats_support.gd")
const S3 := preload("res://tests/s3_support.gd")


func _check(got: Dictionary, label: String) -> void:
	for k: String in LS.BASELINE_HASHES.keys():
		assert_eq(got.get(k), LS.BASELINE_HASHES[k], "%s: %s" % [label, k])


func test_the_scenarios_really_land_bites_and_miss() -> void:
	# scenario sanity (otherwise the hashes below would prove nothing)
	for b in range(1, 5):
		var w: SimWorld = LS.world_shipped()
		LS.chase_hash(w, b)
		var pid: int = w.players()[0].id
		assert_true(TS.bites_by(w.events_since(0), pid).size() >= 8, "band %d chase lands >= 8 bites" % b)
	var wm: SimWorld = LS.world_shipped()
	LS.misses_hash(wm, 3)
	assert_true(TS.misses_of(wm.events_since(0), wm.players()[0].id) >= 5, "the miss run cues >= 5 misses")


func test_identity_with_the_shipped_data() -> void:
	_check(LS.baseline_hashes(self, false), "shipped data")


func test_identity_with_strength_zero_written_and_huge_band_distances() -> void:
	_check(LS.baseline_hashes(self, true), "lunge_strength 0.0 + lunge_distance_m 50 m in every band")


func test_a_negative_strength_is_off() -> void:
	for b in [1, 3]:
		var w: SimWorld = LS.world(-1.0, LS.BAND_M_HUGE)
		assert_eq(LS.chase_hash(w, b), LS.BASELINE_HASHES["chase_b%d" % b], "strength -1 behaves like the baseline in band %d" % b)


func test_the_t13_bite_baselines_hold_with_the_lunge_key_present() -> void:
	var o: Dictionary = {"rules": {LS.KEY_STRENGTH: 0.0}}
	assert_eq(TS.composite(o, [])["hash"], TS.BASELINE_HASHES["bite_composite"], "bite composite")
	assert_eq(TS.held_bites(o, [])["hash"], TS.BASELINE_HASHES["held_bites"], "held bites")
	assert_eq(TS.held_misses(o, [])["hash"], TS.BASELINE_HASHES["held_misses"], "held misses")
	assert_eq(TS.press_then_enter(o, [], 6)["hash"], TS.BASELINE_HASHES["press_enter_6"], "press then enter (6)")
	assert_eq(TS.press_then_enter(o, [], 9)["hash"], TS.BASELINE_HASHES["press_enter_9"], "press then enter (9)")


func test_the_t15_aim_assist_baselines_hold_with_the_lunge_key_present() -> void:
	var o: Dictionary = AS.opts(0.0, {AS.KEY_CONE: 170.0, AS.KEY_STICKY: 1.0, LS.KEY_STRENGTH: 0.0})
	assert_eq(AS.crossing(o)["hash"], AS.BASELINE_HASHES["crossing"], "crossing prey")
	assert_eq(AS.stacked(o)["hash"], AS.BASELINE_HASHES["stacked"], "stacked prey")
	assert_eq(AS.explicit(o)["hash"], AS.BASELINE_HASHES["explicit"], "explicit-target presses")


func test_the_t17_movement_baselines_hold_with_strength_zero_and_huge_distances() -> void:
	var db: ContentDB = LS.db_with(0.0, LS.BAND_M_HUGE)
	for b in range(1, 5):
		assert_eq(SS.hash_player_band(db, b), SS.BASELINE_HASHES["player_band_%d" % b], "scripted player, band %d" % b)
	assert_eq(SS.hash_real_world(db, 4242, 900, 0), SS.BASELINE_HASHES["s3_real_4242_900"], "shipped spawners + schools + a player bite every 45 ticks")


func test_the_t17_movement_baselines_hold_with_the_shipped_data() -> void:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	for b in range(1, 5):
		assert_eq(SS.hash_player_band(db, b), SS.BASELINE_HASHES["player_band_%d" % b], "scripted player, band %d" % b)
	assert_eq(SS.hash_real_world(db, 4242, 900, 0), SS.BASELINE_HASHES["s3_real_4242_900"], "shipped spawners + schools + bites, seed 4242")
	for sp: String in ["shark", "barracuda", "puffer"]:
		assert_eq(SS.hash_npc(db, sp), SS.BASELINE_HASHES["npc_%s" % sp], "NPC run %s" % sp)


func test_an_empty_tuning_layer_adds_nothing_at_strength_zero() -> void:
	# the T1.3 guarantee for the new rows: no tune line, no override layer, no new hash bytes
	var w: SimWorld = LS.world_shipped()
	assert_null(w.debug, "no SimDebug state is created by a plain world")
	LS.chase_hash(w, 2)
	assert_null(w.debug, "...nor by a run with landed bites")
	assert_eq(w.state_hash(), LS.BASELINE_HASHES["chase_b2"], "and the hash is the baseline")
