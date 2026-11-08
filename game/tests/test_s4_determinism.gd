extends TestCase
## S4 determinism: two simulated minutes (3600 ticks) of the SHIPPED map with spawners + schools + plankton + a
## scripted player give the same state_hash() and the same event log, twice. The hash reacts to a school member being
## eaten and covers the new school / entity fields; frame slicing and the global RNG do not matter; the new sim files
## are pure (RefCounted, no global RNG or wall clock).
## The player starts in the middle of school 0 (so promotions certainly happen) and follows the S2 movement script
## plus a BITE every 45 ticks, all commands with explicit ticks. Runs are memoised per file instance (results only).

const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const WORLD_SEED: int = 5151
const MINUTES_TICKS: int = 3600
const SHORT: int = 600

var _memo: Dictionary = {}


## deltas empty = step() per tick, otherwise advance() with the cycled frame deltas (no event capture then).
## kill_tick >= 0: at that tick one promoted member (lowest entity id) gets hp = 0.
func _run(world_seed: int, ticks_n: int, kill_tick: int = -1, deltas: Array[float] = []) -> Dictionary:
	var w: SimWorld = S4.make_world(world_seed, {"real": true})
	var school: Object = S4.get_school(w, 0)
	if school == null:
		return {"missing": true}
	var pid: int = S3.player_at(w, S4.center_at(school, 0) + Vector3(2.0, 0.0, 1.0), 0.0).id
	S2.submit_segments(w, pid, S2.movement_script(1001, ticks_n, true, true), true)
	var t: int = 40
	while t < ticks_n:
		w.submit(SimCommand.bite(pid, -1, t))
		t += 45
	var evs: Array[SimEvent] = []
	var killed: bool = false
	if deltas.is_empty():
		for i in ticks_n:
			if i == kill_tick:
				var list: Array[SimEntity] = S4.promoted_entities(w)
				if not list.is_empty():
					list[0].hp = 0.0
					killed = true
			w.step()
			evs.append_array(w.events_since(w.tick - 1))
	else:
		var frame: int = 0
		while w.tick < ticks_n and frame < 200000:
			w.advance(deltas[frame % deltas.size()])
			frame += 1
	return {
		"missing": false,
		"hash": w.state_hash(),
		"sig": S4.signature(evs),
		"promoted": S4.events_named(evs, "SCHOOL_MEMBER_PROMOTED").size(),
		"eaten": S4.events_named(evs, "SCHOOL_MEMBER_EATEN").size(),
		"school_events": S4.school_events(evs).size(),
		"killed": killed,
		"entities": w.entity_count(),
		"invariants": S4.invariants(w),
	}


func _cached(key: String, world_seed: int, ticks_n: int, kill_tick: int = -1) -> Dictionary:
	if not _memo.has(key):
		_memo[key] = _run(world_seed, ticks_n, kill_tick)
	return _memo[key]


func _api_ok(r: Dictionary) -> bool:
	if bool(r.get("missing", false)):
		fail("S4 API missing: SimWorld.schools / SchoolSystem")
		return false
	return true


# ======================================================== two simulated minutes

func test_two_simulated_minutes_replay_to_the_same_hash_and_events() -> void:
	var first: Dictionary = _cached("minutes", WORLD_SEED, MINUTES_TICKS)
	if not _api_ok(first):
		return
	var again: Dictionary = _run(WORLD_SEED, MINUTES_TICKS)
	assert_eq(again["hash"], first["hash"], "state_hash after 3600 ticks differs between two runs")
	assert_eq(again["sig"], first["sig"], "event log differs between two runs")
	assert_eq(again["entities"], first["entities"], "entity count differs")


func test_the_two_minute_run_is_not_vacuous() -> void:
	var r: Dictionary = _cached("minutes", WORLD_SEED, MINUTES_TICKS)
	if not _api_ok(r):
		return
	assert_true(int(r["promoted"]) >= 1, "the player in a school promoted members (%d promotions)" % int(r["promoted"]))
	assert_true(int(r["entities"]) >= 24, "the world is populated (%d entities)" % int(r["entities"]))
	assert_eq(r["invariants"], "", "school bookkeeping consistent after two minutes")
	var other: Dictionary = _cached("minutes_other_seed", WORLD_SEED + 1, SHORT)
	assert_ne(other["hash"], _cached("short", WORLD_SEED, SHORT)["hash"], "another world seed gives another hash")


func test_the_hash_changes_when_a_school_member_is_eaten() -> void:
	var base: Dictionary = _cached("short", WORLD_SEED, SHORT)
	if not _api_ok(base):
		return
	var hit: Dictionary = _cached("short_kill", WORLD_SEED, SHORT, 200)
	assert_true(bool(hit["killed"]), "setup: a promoted member existed at tick 200 and was killed")
	assert_true(int(hit["eaten"]) >= 1, "the kill produced SCHOOL_MEMBER_EATEN")
	assert_ne(hit["hash"], base["hash"], "state_hash must reflect an eaten school member")
	assert_ne(hit["sig"], base["sig"], "and so must the event log")
	var hit2: Dictionary = _run(WORLD_SEED, SHORT, 200)
	assert_eq(hit2["hash"], hit["hash"], "the run with the kill is itself reproducible")


func test_global_rng_state_does_not_leak_into_the_sim() -> void:
	var ref: Dictionary = _cached("short", WORLD_SEED, SHORT)
	if not _api_ok(ref):
		return
	seed(1)
	var h1: int = int(_run(WORLD_SEED, SHORT)["hash"])
	seed(987654321)
	randi()
	randf()
	var h2: int = int(_run(WORLD_SEED, SHORT)["hash"])
	assert_eq(h1, h2, "the sim uses only its own SimRng (no randf/randi/shuffle/pick_random)")
	assert_eq(h1, ref["hash"], "and the result equals the memoised reference run")


func test_frame_slicing_does_not_change_the_result() -> void:
	var ref: Dictionary = _cached("short", WORLD_SEED, SHORT)
	if not _api_ok(ref):
		return
	var d60: Array[float] = [1.0 / 60.0]
	var irregular: Array[float] = [0.0137, 0.009, 0.0211, 0.0166, 0.0049, 0.0302]
	assert_eq(_run(WORLD_SEED, SHORT, -1, d60)["hash"], ref["hash"], "60 fps frames give the step() result")
	assert_eq(_run(WORLD_SEED, SHORT, -1, irregular)["hash"], ref["hash"], "irregular frames give the step() result")


# ======================================================== new state is hashed

func _fresh() -> SimWorld:
	return S4.make_world(WORLD_SEED, {"real": true})


func test_school_and_entity_fields_are_part_of_the_hash() -> void:
	var base_w: SimWorld = _fresh()
	if not S4.require_api(self, base_w):
		return
	var base: int = base_w.state_hash()
	assert_eq(_fresh().state_hash(), base, "two fresh worlds with one seed hash alike")
	var cases: Array[String] = ["alive", "pending_respawn", "pending_member", "promoted"]
	for field: String in cases:
		var w: SimWorld = _fresh()
		var s: Object = S4.get_school(w, 0)
		match field:
			"alive":
				var a: PackedByteArray = S4.alive_of(s)
				a[0] = 0
				s.set("alive", a)
			"pending_respawn":
				var p: PackedInt32Array = s.get("pending_respawn")
				p.append(123456)
				s.set("pending_respawn", p)
				var pm0: PackedInt32Array = s.get("pending_member")  # parallel list: keep the lengths equal
				pm0.append(0)
				s.set("pending_member", pm0)
			"pending_member":
				# Two parallel entries with the same due tick, only the member index differs from the control below.
				var p2: PackedInt32Array = s.get("pending_respawn")
				p2.append(123456)
				s.set("pending_respawn", p2)
				var pm: PackedInt32Array = s.get("pending_member")
				pm.append(0)
				s.set("pending_member", pm)
				var other: SimWorld = _fresh()
				var so: Object = S4.get_school(other, 0)
				var po: PackedInt32Array = so.get("pending_respawn")
				po.append(123456)
				so.set("pending_respawn", po)
				var pmo: PackedInt32Array = so.get("pending_member")
				pmo.append(1)
				so.set("pending_member", pmo)
				assert_ne(w.state_hash(), other.state_hash(), "the member index inside pending_member is hashed")
			"promoted":
				var d: Dictionary = S4.promoted_of(s)
				d[0] = 999
				s.set("promoted", d)
		assert_ne(w.state_hash(), base, "School.%s must be hashed" % field)
	for field2: String in ["school_id", "school_member"]:
		var w2: SimWorld = S4.make_world(5, {})
		S3.player_at(w2, S3.ARENA, 100.0)
		var npc: SimEntity = S3.npc_at(w2, &"grouper", S3.ARENA + Vector3(30.0, 0.0, 0.0), 1.5)
		var before: int = w2.state_hash()
		npc.set(field2, 7)
		assert_ne(w2.state_hash(), before, "SimEntity.%s must be hashed" % field2)


func test_world_seed_changes_the_school_layout_and_hash() -> void:
	var a: SimWorld = S4.make_world(1, {"real": true})
	var b: SimWorld = S4.make_world(2, {"real": true})
	if not S4.require_api(self, a):
		return
	assert_ne(a.state_hash(), b.state_hash(), "different world seeds hash differently at tick 0")
	var differs: bool = false
	for sid in mini(S4.school_count(a), 6):
		if S4.size_of(S4.get_school(a, sid)) != S4.size_of(S4.get_school(b, sid)) or S4.center_at(S4.get_school(a, sid), 0) != S4.center_at(S4.get_school(b, sid), 0):
			differs = true
	assert_true(differs, "school sizes or paths follow the world seed")


# ======================================================== purity of the new sim files

func test_new_sim_files_exist_are_ref_counted_and_use_no_global_rng_or_clock() -> void:
	var bad := RegEx.new()
	assert_eq(bad.compile("\\brandf\\s*\\(|\\brandi\\s*\\(|\\brandf_range\\s*\\(|\\brandi_range\\s*\\(|\\brandomize\\s*\\(|\\.shuffle\\s*\\(|\\.pick_random\\s*\\(|\\bget_tree\\s*\\(|Time\\.get_|OS\\.get_ticks|extends\\s+Node"), OK, "test regex")
	for entry in [["school_system.gd", "SchoolSystem"], ["tier_manager.gd", "TierManager"], ["plankton_field.gd", "PlanktonField"]]:
		var path: String = "res://scripts/sim/%s" % entry[0]
		assert_true(FileAccess.file_exists(path), "contract file missing: %s" % path)
		if not FileAccess.file_exists(path):
			continue
		var lines: Array[String] = []
		for raw in FileAccess.get_file_as_string(path).split("\n"):
			lines.append(raw.split("#")[0])
		var code: String = "\n".join(lines)
		assert_true(code.find("class_name %s" % entry[1]) != -1, "%s declares class_name %s" % [entry[0], entry[1]])
		assert_true(code.find("extends RefCounted") != -1, "%s extends RefCounted (hard rule 1: sim is not a node)" % entry[0])
		var hit: RegExMatch = bad.search(code)
		assert_null(hit, "%s must be pure and deterministic (found '%s')" % [entry[0], hit.get_string() if hit != null else ""])
