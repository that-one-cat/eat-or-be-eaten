extends TestCase
## S6 determinism (hard rule 2, contract "Determinism"): a scripted run with band-ups, mutation picks, both abilities and
## a boss engagement gives the same state_hash() and the same event log twice; the new state (mutations, abilities,
## boss_state) is part of the hash; the global RNG and the frame slicing do not matter. The S4 replay test
## (test_s4_determinism) must stay green: run it together with this file.
## The script reads only sim state and the tick (offers are answered by a fixed policy), so it is a valid command stream.

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const RUN_TICKS: int = 2400
## Test-side XP writes: tick -> band to reach (forces three band-ups early, while the player is alive).
const LEVEL_UPS: Dictionary = {4: 2, 25: 3, 45: 4}

var _memo: Dictionary = {}


## Pick policy: the first offered hunter node, else the first offered node.
func _choose(offer: PackedStringArray) -> String:
	for id: String in offer:
		if id.begins_with("hunter_"):
			return id
	return offer[0] if offer.size() > 0 else ""


func _run(world_seed: int, ticks_n: int) -> Dictionary:
	var key: String = "%d:%d" % [world_seed, ticks_n]
	if _memo.has(key):
		return _memo[key]
	var w: SimWorld = S6.make_world(world_seed, {"vitals": true})
	var spot: Vector3 = S6.abyss_spot(w)
	if not spot.is_finite() or not S6.api_problems(w).is_empty() or not S6.state_enum_problems(["PATROL"]).is_empty():
		return {"missing": true}
	var boss: SimEntity = S6.boss_at(w, spot)
	var p: SimEntity = S3.player_at(w, spot + Vector3(20.0, 0.0, 0.0), 0.0, Vector3.LEFT)
	S6.give_ability(w, p, "sonar")
	S6.give_ability(w, p, "bite_dash")
	var evs: Array[SimEvent] = []
	var seen: Dictionary = {}
	var done: Dictionary = {}
	var guard: int = 0
	while w.tick < ticks_n and guard < ticks_n * 4:
		guard += 1
		var t: int = w.tick
		if S6.paused(w):
			var choice: String = _choose(S6.offer_of(p))
			if not choice.is_empty():
				w.submit(S6.pick_cmd(p.id, choice))
		else:
			if LEVEL_UPS.has(t) and not done.has(t):
				done[t] = true
				p.xp = S6.band_xp(w.content, int(LEVEL_UPS[t])) + 1.0
			if t % 40 == 7:
				var a: float = float(t) * 0.05
				w.submit(SimCommand.move(p.id, Vector3(cos(a), 0.2 * sin(a * 0.7), sin(a)), 1.0))
			if t % 90 == 30:
				w.submit(SimCommand.boost(p.id, true))
			if t % 90 == 75:
				w.submit(SimCommand.boost(p.id, false))
			if t % 45 == 20:
				w.submit(SimCommand.bite(p.id, -1))
			if t % 200 == 60:
				w.submit(SimCommand.ability(p.id, &"sonar"))
			if t % 120 == 33:
				w.submit(SimCommand.ability(p.id, &"bite_dash"))
		S6.step_collect(w, evs, seen)
	var counts: Dictionary = {}
	for n: String in S6.NEW_EVENTS:
		counts[n] = S6.count_named(evs, n)
	var out: Dictionary = {
		"missing": false,
		"hash": w.state_hash(),
		"sig": S6.signature(evs),
		"tick": w.tick,
		"run_ticks": w.run_ticks,
		"mutations": Array(S6.mutations_of(p)),
		"abilities": Array(S6.abilities_of(p)),
		"deaths": p.deaths,
		"boss_state": S6.boss_state_value(boss),
		"counts": counts,
		"guard": guard,
	}
	_memo[key] = out
	return out


func _missing(r: Dictionary) -> bool:
	if bool(r["missing"]):
		fail("S6 API missing (see test_s6_boss / test_s6_mutation_pick for the member list) or no abyss spot")
		return true
	return false


func test_scripted_run_replays_to_the_same_hash_and_events() -> void:
	var a: Dictionary = _run(1234, RUN_TICKS)
	if _missing(a):
		return
	_memo.clear()
	var b: Dictionary = _run(1234, RUN_TICKS)
	assert_eq(a["hash"], b["hash"], "same seed + same script = same state_hash after %d ticks" % RUN_TICKS)
	assert_eq(a["sig"], b["sig"], "same event log (type, tick, entity, other, value)")
	assert_eq(a["mutations"], b["mutations"], "same picks")
	assert_eq(a["boss_state"], b["boss_state"], "same boss state")
	assert_eq(a["deaths"], b["deaths"], "same deaths")


func test_the_script_is_not_vacuous() -> void:
	var r: Dictionary = _run(1234, RUN_TICKS)
	if _missing(r):
		return
	var c: Dictionary = r["counts"]
	assert_eq(int(r["tick"]), RUN_TICKS, "the run reached the end tick (no stall on a pause)")
	assert_true(int(c["MUTATION_OFFERED"]) >= 1, "at least one offer: %s" % str(c))
	assert_true(int(c["MUTATION_PICKED"]) >= 1, "at least one pick: %s" % str(c))
	assert_true(int(c["SONAR_PULSE"]) >= 1, "sonar was used: %s" % str(c))
	assert_true(int(c["ABILITY_USED"]) >= 1, "bite-dash was used: %s" % str(c))
	assert_true(int(c["BOSS_ENGAGED"]) >= 1, "the boss engaged: %s" % str(c))
	assert_true(int(c["BOSS_TELL"]) >= 1, "the boss attacked: %s" % str(c))
	assert_true((r["mutations"] as Array).size() >= 1, "the player owns a mutation")
	assert_true(int(r["run_ticks"]) <= int(r["tick"]), "run_ticks never exceeds the tick")


func test_pauses_do_not_run_the_run_timer() -> void:
	var r: Dictionary = _run(1234, RUN_TICKS)
	if _missing(r):
		return
	assert_eq(int(r["run_ticks"]), int(r["tick"]), "no tick is lost or double counted around the pauses: run_ticks == tick (the world is not 'running' while paused, and neither counter moves)")


func test_a_different_seed_gives_a_different_run() -> void:
	var a: Dictionary = _run(1234, RUN_TICKS)
	if _missing(a):
		return
	var b: Dictionary = _run(4321, RUN_TICKS)
	assert_ne(a["hash"], b["hash"], "another world seed ends in another state")


func test_global_rng_does_not_leak_into_the_run() -> void:
	seed(5)
	randi()
	var a: Dictionary = _run(777, 900)
	if _missing(a):
		return
	_memo.clear()
	seed(98765)
	for i in 50:
		randf()
	var b: Dictionary = _run(777, 900)
	assert_eq(a["hash"], b["hash"], "global randi()/randf()/seed() do not influence picks, abilities or the boss")
	assert_eq(a["sig"], b["sig"], "nor the event log")


func test_new_state_is_part_of_the_hash() -> void:
	var rows: Array = []
	for variant in range(6):
		var w: SimWorld = S6.make_world(555)
		var spot: Vector3 = S6.abyss_spot(w)
		if not S6.require_api(self, w) or not S6.require_states(self, ["PATROL", "ENGAGE", "TELL", "DASH", "STUNNED"]) or not spot.is_finite():
			return
		var boss: SimEntity = S6.boss_at(w, spot)
		var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0)
		match variant:
			1:
				S6.give(w, p, ["hunter_bite_power"])
			2:
				S6.give_ability(w, p, "sonar")
			3:
				var en: Dictionary = S6.boss_state_enum()
				boss.set("boss_state", int(en["STUNNED"]))
			4:
				w.set("run_won", true)
		rows.append(w.state_hash())
	assert_eq(rows[5], rows[0], "test setup: the untouched world hashes the same twice")
	assert_ne(rows[1], rows[0], "player.mutations is hashed")
	assert_ne(rows[2], rows[0], "player.abilities is hashed")
	assert_ne(rows[3], rows[0], "boss_state is hashed")
	assert_ne(rows[4], rows[0], "run_won is hashed (assumption A12: contract says 'state_hash() covers the new fields')")
	assert_ne(rows[1], rows[2], "different fields hash differently")


func test_mutation_order_is_hashed() -> void:
	# picks are an ordered list ("order of picks" in the contract): same set in another order is another state
	var hashes: Array[int] = []
	for order in [["hunter_bite_power", "survivor_efficient_metabolism"], ["survivor_efficient_metabolism", "hunter_bite_power"]]:
		var w: SimWorld = S6.make_world(556)
		var p: SimEntity = S3.player_at(w, S3.ARENA, 0.0)
		if not S6.require_api(self, w):
			return
		S6.give(w, p, order)
		hashes.append(w.state_hash())
	assert_ne(hashes[0], hashes[1], "mutations hash covers the order of picks")


func test_new_sim_files_are_pure() -> void:
	# Mirrors test_sim_purity for the new files (that test scans the whole directory; this one also proves they exist).
	var files: Array[String] = ["progression.gd", "abilities.gd", "boss_brain.gd"]
	var banned: Array[String] = ["randi(", "randf(", "randomize(", "randi_range(", "randf_range(", "Time.", "OS.get_ticks", "get_tree", "extends Node"]
	for f: String in files:
		var path: String = "res://scripts/sim/" + f
		assert_true(FileAccess.file_exists(path), "contract file exists: %s (assumption A13: names from the contract; rename here if impl-A chose others)" % path)
		if not FileAccess.file_exists(path):
			continue
		var src: String = FileAccess.get_file_as_string(path)
		assert_true(src.contains("class_name "), "%s has a class_name" % f)
		for b: String in banned:
			for line: String in src.split("\n"):
				var code: String = line.split("#")[0]
				assert_false(code.contains(b), "%s must not use '%s': %s" % [f, b, line.strip_edges()])
