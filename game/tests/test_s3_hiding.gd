extends TestCase
## S3 hiding: map `hiding_volumes` (AABBs tagged kelp / coral). Inside one, an entity is `hidden`
## (HIDDEN / REVEALED events, `hidden_since_tick`); predators detect hidden targets at detection_radius x
## hiding.detection_mult (0.4) and a predator loses a target that has been hidden for hiding.lose_target_s (2 s).
## Volume record schema is read through S3.box_min_max / S3.volume_tag (an "aabb": {min, max} object like zones, or
## min/max directly; tag in "tag" or "kind"). Custom volumes are built from a copy of a real record so the schema is
## whatever the data uses. Unit-level interpretation (flagged in the plan): a hidden target stays lost for the
## predator while it stays hidden; it is not re-acquired inside 0.4 x radius.

const S3 := preload("res://tests/s3_support.gd")


## World whose only hiding volume is a cube of half-size `half` around `centre` (tag of the real kelp record).
func _box_world(world_seed: int, centre: Vector3, half: float) -> SimWorld:
	var real: SimWorld = S3.make_world(1)
	var vols: Array = S3.hiding_volumes(real)
	assert_true(vols.size() >= 1, "precondition: the real map has hiding volumes")
	var rec: Dictionary = vols[0] if vols.size() >= 1 else {"tag": "kelp", "aabb": {"min": [0, 0, 0], "max": [1, 1, 1]}}
	var box: Dictionary = S3.volume_with_box(rec, centre - Vector3.ONE * half, centre + Vector3.ONE * half)
	return S3.make_world(world_seed, {"hiding_volumes": [box]})


func _no_volume_world(world_seed: int) -> SimWorld:
	return S3.make_world(world_seed, {"hiding_volumes": []})


func _player(w: SimWorld, length_m: float, pos: Vector3) -> SimEntity:
	return S3.player_at(w, pos, S3.xp_for_length(w.content, length_m), Vector3.RIGHT)


# ======================================================== data

func test_map_declares_kelp_and_coral_hiding_volumes_aligned_with_their_zones() -> void:
	var w: SimWorld = S3.make_world(1)
	var vols: Array = S3.hiding_volumes(w)
	assert_true(vols.size() >= 2, "map.hiding_volumes has volumes (got %d)" % vols.size())
	var kelp_zone: Array[Vector3] = S3.zone_box(w, "kelp_forest")
	var reef_zone: Array[Vector3] = S3.zone_box(w, "shallows")
	var tags: Dictionary = {}
	for v: Variant in vols:
		var rec: Dictionary = v
		var tag: String = S3.volume_tag(rec)
		tags[tag] = true
		var mm: Array[Vector3] = S3.box_min_max(rec)
		assert_true(mm[0].x < mm[1].x and mm[0].y < mm[1].y and mm[0].z < mm[1].z, "%s volume has a positive size" % tag)
		assert_true(mm[0].y >= -w.map["depth_m"] - 1e-6 and mm[1].y <= 1e-6, "%s volume lies in the water column" % tag)
		var half: float = float(w.map["size_m"]) * 0.5
		assert_true(absf(mm[0].x) <= half and absf(mm[1].x) <= half and absf(mm[0].z) <= half and absf(mm[1].z) <= half, "%s volume lies inside the map" % tag)
		var zone: Array[Vector3] = kelp_zone if tag == "kelp" else reef_zone
		if tag == "kelp" or tag == "coral":
			var overlap: bool = mm[0].x <= zone[1].x and mm[1].x >= zone[0].x and mm[0].y <= zone[1].y and mm[1].y >= zone[0].y and mm[0].z <= zone[1].z and mm[1].z >= zone[0].z
			assert_true(overlap, "%s volume overlaps its zone (%s)" % [tag, "kelp_forest" if tag == "kelp" else "shallows/reef"])
	assert_true(tags.has("kelp"), "at least one kelp volume")
	assert_true(tags.has("coral"), "at least one coral volume")


# ======================================================== hidden flag

func test_entities_inside_real_volumes_are_hidden_and_the_arena_is_not() -> void:
	for tag in ["kelp", "coral"]:
		var w: SimWorld = S3.make_world(3)
		var probe: Vector3 = S3.hiding_probe(w, tag)
		assert_true(probe != Vector3.INF, "a %s volume has a free point above the seabed" % tag)
		if probe == Vector3.INF:
			continue
		var p: SimEntity = _player(w, 0.15, probe)
		S3.step_n(w, 3)
		assert_true(p.hidden, "a player inside a %s volume is hidden" % tag)
		assert_true(p.hidden_since_tick >= 0 and p.hidden_since_tick <= w.tick, "hidden_since_tick %d is when it began" % p.hidden_since_tick)
		assert_eq(S3.events_of(w, SimEvent.Type.HIDDEN).size(), 1, "one HIDDEN event (%s)" % tag)
	var w2: SimWorld = S3.make_world(3)
	for v: Variant in S3.hiding_volumes(w2):
		var mm: Array[Vector3] = S3.box_min_max(v)
		assert_false(S3.inside_box(S3.ARENA, mm[0], mm[1]), "precondition: the arena is outside every real volume")
	var q: SimEntity = _player(w2, 0.15, S3.ARENA)
	S3.step_n(w2, 3)
	assert_false(q.hidden, "mid-water outside every volume: not hidden")
	assert_eq(S3.events_of(w2, SimEvent.Type.HIDDEN).size(), 0, "no HIDDEN event outside")


func test_hidden_follows_volume_membership_with_hidden_and_revealed_events() -> void:
	var w: SimWorld = _box_world(5, S3.ARENA, 4.0)
	var p: SimEntity = _player(w, 0.15, S3.ARENA)
	S3.step_n(w, 2)
	assert_true(p.hidden, "inside the box: hidden")
	var hid: Array[SimEvent] = S3.events_of(w, SimEvent.Type.HIDDEN)
	assert_eq(hid.size(), 1, "one HIDDEN event")
	if hid.size() == 1:
		assert_true(S3.mentions(hid[0], p.id), "names the player")
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
	S3.step_n(w, 150, {}, [p.id])
	assert_true(p.position.x > S3.ARENA.x + 4.5, "precondition: the player swam out of the 4 m box (x = %s)" % p.position.x)
	assert_false(p.hidden, "left the box: no longer hidden")
	var rev: Array[SimEvent] = S3.events_of(w, SimEvent.Type.REVEALED)
	assert_eq(rev.size(), 1, "one REVEALED event")
	if rev.size() == 1 and hid.size() == 1:
		assert_true(rev[0].tick > hid[0].tick, "REVEALED comes after HIDDEN")
		assert_true(S3.mentions(rev[0], p.id), "names the player")
	assert_eq(S3.events_of(w, SimEvent.Type.HIDDEN).size(), 1, "and no second HIDDEN")


func test_npcs_hide_too() -> void:
	var w: SimWorld = _box_world(5, S3.ARENA, 4.0)
	var fish: SimEntity = S3.npc_at(w, &"silver_schooling_fish", S3.ARENA, 0.1)
	var out: SimEntity = S3.npc_at(w, &"silver_schooling_fish", S3.ARENA + Vector3(30.0, 0.0, 0.0), 0.1)
	S3.step_n(w, 3, {fish.id: fish.position, out.id: out.position})
	assert_true(fish.hidden, "an NPC inside the volume is hidden")
	assert_false(out.hidden, "an NPC 30 m away is not")


# ======================================================== predators vs hidden targets

func _predator_vs_player(w: SimWorld, dist: float) -> Dictionary:
	var p: SimEntity = _player(w, 0.5, S3.ARENA)
	var a: SimEntity = S3.npc_at(w, &"barracuda", S3.ARENA + Vector3(dist, 0.0, 0.0), 1.0, Vector3.RIGHT)  # facing away
	return {"p": p, "a": a}


func test_detection_radius_against_a_hidden_target_is_forty_percent() -> void:
	var mult: float = S3.rule_f(S3.content(), "hiding.detection_mult")
	assert_almost_eq(mult, 0.4, 1e-9, "GAME_DESIGN: x0.4")
	var radius: float = S3.species_f(S3.content(), &"barracuda", "detection_radius_m")
	var dist: float = 18.0
	assert_true(dist < radius and dist > mult * radius, "geometry: %s m is inside the %s m radius but outside %s m" % [dist, radius, mult * radius])

	var hidden_w: SimWorld = _box_world(7, S3.ARENA, 4.0)
	var hs: Dictionary = _predator_vs_player(hidden_w, dist)
	var hp: SimEntity = hs["p"]
	var ha: SimEntity = hs["a"]
	S3.step_n(hidden_w, 90, {}, [hp.id])
	assert_true(hp.hidden, "the player is hidden")
	assert_eq(S3.count_between(hidden_w, SimEvent.Type.BITTEN, ha.id, hp.id), 0, "a hidden player 18 m away (> 8 m) is not attacked within 3 s")

	var open_w: SimWorld = _no_volume_world(7)
	var os: Dictionary = _predator_vs_player(open_w, dist)
	var op: SimEntity = os["p"]
	var oa: SimEntity = os["a"]
	S3.step_n(open_w, 300, {}, [op.id])
	assert_true(S3.count_between(open_w, SimEvent.Type.BITTEN, oa.id, op.id) >= 1, "control: the same player in the open is attacked from 18 m")


func test_predator_loses_a_hidden_target_after_two_seconds() -> void:
	var lose_ticks: int = S3.ticks(S3.rule_f(S3.content(), "hiding.lose_target_s"))
	assert_eq(lose_ticks, 60, "GAME_DESIGN: 2 s")
	var quiet_from: int = lose_ticks + 30
	var window: int = 150

	var hidden_w: SimWorld = _box_world(9, S3.ARENA, 4.0)
	var hs: Dictionary = _predator_vs_player(hidden_w, 3.0)  # inside 0.4 x radius = 8 m: it may chase at first
	var hp: SimEntity = hs["p"]
	var ha: SimEntity = hs["a"]
	S3.step_n(hidden_w, quiet_from, {}, [hp.id])
	var late_start: int = hidden_w.tick
	S3.step_n(hidden_w, window, {}, [hp.id])
	assert_true(hp.hidden, "the player stayed hidden")
	assert_eq(S3.count_between(hidden_w, SimEvent.Type.BITTEN, ha.id, hp.id, late_start), 0, "from %d ticks after the player hid, the predator no longer bites it (the first %d ticks are free)" % [quiet_from, quiet_from])

	var open_w: SimWorld = _no_volume_world(9)
	var os: Dictionary = _predator_vs_player(open_w, 3.0)
	var op: SimEntity = os["p"]
	var oa: SimEntity = os["a"]
	S3.step_n(open_w, quiet_from, {}, [op.id])
	var o_late: int = open_w.tick
	S3.step_n(open_w, window, {}, [op.id])
	assert_true(S3.count_between(open_w, SimEvent.Type.BITTEN, oa.id, op.id, o_late) >= 1, "control: in the open the predator keeps biting in the same window")
