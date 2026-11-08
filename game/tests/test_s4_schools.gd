extends TestCase
## S4 seeded schools (contract "Schools"): the school table follows map.schools; the centre motion and the member
## offsets are PURE functions of (school seed, tick): same inputs give the same value, in any call order, whatever
## the world did before; different world seeds / schools differ; the centre stays inside its zone AABB and above the
## seabed over a long tick range and moves continuously. Everything is read through the S4 helper (dynamic access),
## so a missing SchoolSystem fails the tests with a message instead of breaking the parse.
## Numbers come from ContentDB (map.schools, rules.schools.radius_per_sqrt_member_m, species swim speed).

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const SEED: int = 7


func _real(world_seed: int = SEED) -> SimWorld:
	return S4.make_world(world_seed, {"real": true})


## Radius of the member ellipsoid for a school: rules.schools.radius_per_sqrt_member_m x sqrt(size).
func _radius(w: SimWorld, size: int) -> float:
	return S3.rule_f(w.content, "schools.radius_per_sqrt_member_m") * sqrt(float(size))


# ======================================================== the table

func test_school_table_follows_the_map_records_in_order() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var recs: Array = S4.school_records(w)
	assert_true(recs.size() > 0, "the shipped map declares schools")
	var expected: int = 0
	for r_v: Variant in recs:
		expected += int((r_v as Dictionary)["count"])
	assert_eq(S4.school_count(w), expected, "school_count() == sum of map.schools counts (schools are dense, from 0, in map order)")
	var seeds: Dictionary = {}
	var id: int = 0
	for r_v2: Variant in recs:
		var r: Dictionary = r_v2
		for i in int(r["count"]):
			var s: Object = S4.get_school(w, id)
			assert_not_null(s, "get_school(%d) exists" % id)
			if s == null:
				id += 1
				continue
			assert_eq(int(s.get("id")), id, "school.id is its dense index")
			assert_eq(String(s.get("species_id")), String(r["species_id"]), "school %d species follows the record" % id)
			var size: int = S4.size_of(s)
			assert_true(size >= int(r["size_min"]) and size <= int(r["size_max"]), "school %d size %d inside %s..%s" % [id, size, r["size_min"], r["size_max"]])
			var alive: PackedByteArray = S4.alive_of(s)
			assert_eq(alive.size(), size, "school %d: alive has one byte per member" % id)
			assert_eq(S4.ambient_count(s), size, "school %d: every member starts in the school form" % id)
			assert_eq(S4.promoted_of(s).size(), 0, "school %d: nothing promoted at tick 0" % id)
			var zi: int = int(s.get("zone_index"))
			var zones: Array = w.map["zones"]
			assert_true(zi >= 0 and zi < zones.size() and String((zones[zi] as Dictionary)["id"]) == String(r["zone_id"]), "school %d zone_index points at zone %s" % [id, r["zone_id"]])
			seeds[int(s.get("seed"))] = true
			id += 1
	assert_eq(seeds.size(), expected, "every school has its own seed (hash of world seed and school id)")


func test_school_sizes_stay_inside_the_record_range_and_vary() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var by_record: Dictionary = {}
	for sid in S4.school_count(w):
		var rec: Dictionary = S4.record_for_school(w, sid)
		var key: String = "%s/%s" % [rec["species_id"], rec["zone_id"]]
		if not by_record.has(key):
			by_record[key] = {"rec": rec, "sizes": {}}
		(by_record[key]["sizes"] as Dictionary)[S4.size_of(S4.get_school(w, sid))] = true
	var varied: int = 0
	for key2: String in by_record.keys():
		var rec2: Dictionary = by_record[key2]["rec"]
		var distinct: int = (by_record[key2]["sizes"] as Dictionary).size()
		if int(rec2["size_max"]) - int(rec2["size_min"]) >= 4 and int(rec2["count"]) >= 6:
			assert_true(distinct >= 3, "%s: sizes vary across its %s schools (%d distinct)" % [key2, rec2["count"], distinct])
			varied += 1
	assert_true(varied >= 1, "the shipped data has at least one record with a size range worth varying")


func test_the_default_map_holds_about_a_thousand_fish() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var members: int = 0
	for sid in S4.school_count(w):
		members += S4.size_of(S4.get_school(w, sid))
	S4.run(w, 60)
	var entities: int = S3.creatures(w).size()
	var total: int = members + entities
	assert_true(total >= 800 and total <= 1600, "ambient members %d + non-school creatures %d = %d; the S4 bench needs about 1,000 fish" % [members, entities, total])


# ======================================================== centre motion: pure function of (seed, school, tick)

func test_center_at_is_a_pure_function_of_school_seed_and_tick() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var s: Object = S4.get_school(w, 0)
	var sample: Array[int] = [0, 1, 29, 30, 977, 5000, 36000, 123456]
	var first: Dictionary = {}
	for t: int in sample:
		first[t] = S4.center_at(s, t)
	for i in range(sample.size() - 1, -1, -1):
		assert_eq(S4.center_at(s, sample[i]), first[sample[i]], "center_at(tick %d) repeats exactly, also when asked in reverse order" % sample[i])
	assert_true(S4.center_at(s, 0) != S4.center_at(s, 3000), "the school actually moves")
	assert_true(S4.center_at(s, 0) != S4.center_at(s, 30), "and already within a second")


func test_center_at_does_not_depend_on_what_the_world_did() -> void:
	var fresh: SimWorld = _real()
	var busy: SimWorld = _real()
	if not S4.require_api(self, fresh):
		return
	# History in `busy`: a player in school 0 (promotions, spawners, brains) for 150 ticks.
	var pid: int = S4.player_at_school(busy, 0).id
	var s_busy0: Object = S4.get_school(busy, 0)
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, pid, S4.center_at(s_busy0, world.tick))
	S4.run(busy, 150, pre)
	var ids: Array[int] = [0, 5, S4.school_count(fresh) - 1]
	var ticks: Array[int] = [0, 10, 149, 150, 151, 1000, 9000]
	for sid: int in ids:
		var a: Object = S4.get_school(fresh, sid)
		var b: Object = S4.get_school(busy, sid)
		for t: int in ticks:
			assert_eq(S4.center_at(a, t), S4.center_at(b, t), "school %d tick %d: centre is the same in a fresh and a busy world" % [sid, t])
			assert_eq(S4.member_offset(a, 1, t), S4.member_offset(b, 1, t), "school %d tick %d: member offset is the same too" % [sid, t])


func test_other_world_seeds_move_schools_differently() -> void:
	var a: SimWorld = _real(SEED)
	var b: SimWorld = _real(SEED + 1)
	if not S4.require_api(self, a):
		return
	for sid in 3:
		var sa: Object = S4.get_school(a, sid)
		var sb: Object = S4.get_school(b, sid)
		assert_ne(int(sa.get("seed")), int(sb.get("seed")), "school %d: seed depends on the world seed" % sid)
		assert_true(S4.center_at(sa, 100) != S4.center_at(sb, 100), "school %d: another world seed gives another path" % sid)


func test_schools_of_one_record_do_not_share_a_path() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var rec_count: int = int(S4.record_for_school(w, 0)["count"])
	var seen: Dictionary = {}
	for sid in mini(rec_count, 12):
		var c: Vector3 = S4.center_at(S4.get_school(w, sid), 600)
		seen[snappedf(c.x, 0.01) * 1000.0 + snappedf(c.z, 0.01)] = true
	assert_eq(seen.size(), mini(rec_count, 12), "schools of one record are at different places (different seeds)")


func test_center_stays_inside_its_zone_and_above_the_seabed_for_twenty_minutes() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var outside: int = 0
	var below: int = 0
	var example: String = ""
	var checked: int = 0
	for sid in S4.school_count(w):
		var box: Array[Vector3] = S4.zone_box_for(w, sid)
		assert_eq(box.size(), 2, "school %d: its zone exists" % sid)
		if box.size() != 2:
			continue
		var s: Object = S4.get_school(w, sid)
		for t in range(0, 36001, 37):
			var c: Vector3 = S4.center_at(s, t)
			checked += 1
			if not S3.inside_box(c, box[0], box[1], 1e-3):
				outside += 1
				example = "school %d tick %d at %s" % [sid, t, c]
			elif c.y <= w.seabed.height_at(c.x, c.z):
				below += 1
				example = "school %d tick %d at %s (floor %s)" % [sid, t, c, w.seabed.height_at(c.x, c.z)]
	assert_true(checked > 1000, "enough samples were taken (%d)" % checked)
	assert_eq(outside, 0, "centre left its zone AABB %d times; first: %s" % [outside, example])
	assert_eq(below, 0, "centre went into the seabed %d times; first: %s" % [below, example])


func test_center_motion_is_continuous_and_not_faster_than_the_species_can_swim() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var picks: Array[int] = [0, S4.school_count(w) / 2, S4.school_count(w) - 1]
	for sid: int in picks:
		var s: Object = S4.get_school(w, sid)
		var speed: float = float(w.content.get_species(StringName(String(s.get("species_id"))))["swim_speed_mps"])
		var cap: float = 3.0 * speed / 30.0 + 0.01  # generous: 3x the species speed per tick
		var prev: Vector3 = S4.center_at(s, 0)
		var worst: float = 0.0
		for t in range(1, 6000):
			var c: Vector3 = S4.center_at(s, t)
			worst = maxf(worst, c.distance_to(prev))
			prev = c
		assert_true(worst <= cap, "school %d: biggest per-tick step %.4f m <= %.4f m (3x species speed %.1f m/s); no teleports" % [sid, worst, cap, speed])
		assert_true(worst > 0.0, "school %d actually moves" % sid)


func test_heading_follows_the_direction_of_motion() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var s: Object = S4.get_school(w, 0)
	var good: int = 0
	var n: int = 0
	for t in range(0, 6000, 29):
		var h: Vector3 = S4.heading_at(s, t)
		assert_almost_eq(h.length(), 1.0, 0.01, "heading at tick %d is a unit vector" % t)
		var d: Vector3 = S4.center_at(s, t + 15) - S4.center_at(s, t)
		if d.length() < 1e-3:
			continue
		n += 1
		if h.dot(d.normalized()) > 0.0:
			good += 1
	assert_true(n > 50, "the school moves most of the time (%d samples)" % n)
	assert_true(float(good) >= 0.9 * float(n), "heading points along the motion in %d of %d samples" % [good, n])


# ======================================================== member offsets

func _largest_school(w: SimWorld) -> Object:
	var best: Object = null
	for sid in S4.school_count(w):
		var s: Object = S4.get_school(w, sid)
		if best == null or S4.size_of(s) > S4.size_of(best):
			best = s
	return best


func test_member_offset_is_pure_and_stays_near_the_member_ellipsoid() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var s: Object = _largest_school(w)
	var size: int = S4.size_of(s)
	var r: float = _radius(w, size)
	assert_true(r > 0.0, "rules.schools.radius_per_sqrt_member_m is set (radius %.2f m for %d members)" % [r, size])
	var sum_len: float = 0.0
	var n: int = 0
	for t in [0, 100, 5000]:
		var first: Array[Vector3] = []
		for k in size:
			first.append(S4.member_offset(s, k, t))
		for k in range(size - 1, -1, -1):
			assert_eq(S4.member_offset(s, k, t), first[k], "offset(k=%d, tick %d) repeats exactly" % [k, t])
		for k in size:
			var l: float = first[k].length()
			assert_true(l <= 2.0 * r + 0.5, "member %d at tick %d is %.2f m from the centre; the ellipsoid radius is %.2f m (wobble allowance x2)" % [k, t, l, r])
			sum_len += l
			n += 1
	assert_true(sum_len / float(n) > 0.05 * r, "members are spread around the centre (mean %.2f m)" % (sum_len / float(n)))


func test_members_have_their_own_slots_and_schools_their_own_layout() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var s: Object = _largest_school(w)
	var size: int = S4.size_of(s)
	var seen: Dictionary = {}
	for k in size:
		var o: Vector3 = S4.member_offset(s, k, 0)
		seen["%.3f/%.3f/%.3f" % [o.x, o.y, o.z]] = true
	assert_true(seen.size() >= int(0.9 * float(size)), "%d of %d members have distinct slots" % [seen.size(), size])
	var s0: Object = S4.get_school(w, 0)
	var s1: Object = S4.get_school(w, 1)
	assert_true(S4.member_offset(s0, 0, 0) != S4.member_offset(s1, 0, 0), "member 0 sits differently in different schools (seeded)")


func test_the_member_wobble_is_slow_and_continuous() -> void:
	var w: SimWorld = _real()
	if not S4.require_api(self, w):
		return
	var s: Object = _largest_school(w)
	var size: int = S4.size_of(s)
	var r: float = _radius(w, size)
	var moved: bool = false
	for k in mini(size, 8):
		var prev: Vector3 = S4.member_offset(s, k, 0)
		var first: Vector3 = prev
		for t in range(1, 900):
			var o: Vector3 = S4.member_offset(s, k, t)
			assert_true(o.distance_to(prev) <= 0.05 * r + 0.01, "member %d tick %d: offset jumped %.3f m in one tick (radius %.2f m)" % [k, t, o.distance_to(prev), r])
			prev = o
			if o.distance_to(first) > 1e-4:
				moved = true
	assert_true(moved, "offsets wobble over 30 s (not frozen)")
