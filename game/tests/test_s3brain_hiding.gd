extends TestCase
## Hiding: map hiding_volumes (kelp / coral AABBs), NpcBrain.hiding_tag_at / update_hidden, detection radius
## x hiding.detection_mult against hidden targets, a chased target lost after hiding.lose_target_s in hiding and
## not re-detected while it stays hidden.

const B := preload("res://tests/s3brain_support.gd")


func _volume_centre(w: SimWorld, id: String) -> Vector3:
	for v: Variant in (w.map["hiding_volumes"] as Array):
		if str((v as Dictionary)["id"]) == id:
			var a: Array = v["aabb"]["min"]
			var b: Array = v["aabb"]["max"]
			return (Vector3(float(a[0]), float(a[1]), float(a[2])) + Vector3(float(b[0]), float(b[1]), float(b[2]))) * 0.5
	return Vector3.INF


func test_reef_map_has_kelp_and_coral_volumes_in_open_water() -> void:
	var w: SimWorld = B.make_world(1)
	var tags: Dictionary = {}
	for v: Variant in (w.map.get("hiding_volumes", []) as Array):
		var rec: Dictionary = v
		tags[str(rec["tag"])] = int(tags.get(str(rec["tag"]), 0)) + 1
		var c: Vector3 = _volume_centre(w, str(rec["id"]))
		var top: float = float(rec["aabb"]["max"][1])
		assert_true(top > w.seabed.height_at(c.x, c.z) + 2.0, "%s reaches 2+ m above the seabed at its centre" % rec["id"])
		var zone: AABB = B.zone_box(w, "kelp_forest" if str(rec["tag"]) == "kelp" else "shallows")
		assert_true(zone.grow(0.01).has_point(Vector3(c.x, zone.get_center().y, c.z)), "%s centre lies over its zone" % rec["id"])
	assert_true(int(tags.get("kelp", 0)) >= 2 and int(tags.get("coral", 0)) >= 2, "several kelp and coral volumes: %s" % tags)
	for sp: Variant in (w.map["player_spawns"] as Array):
		var p := Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
		assert_eq(NpcBrain.hiding_tag_at(w, p), &"", "player spawn %s is not inside a hiding volume" % p)


func test_hiding_tag_at_reports_the_volume_tag() -> void:
	var w: SimWorld = B.make_world(1)
	var kelp: Vector3 = _volume_centre(w, "kelp_mid")
	var coral: Vector3 = _volume_centre(w, "coral_spawn")
	assert_eq(NpcBrain.hiding_tag_at(w, kelp), &"kelp", "kelp_mid centre")
	assert_eq(NpcBrain.hiding_tag_at(w, coral), &"coral", "coral_spawn centre")
	assert_eq(NpcBrain.hiding_tag_at(w, B.ARENA), &"", "open water")


func test_update_hidden_sets_and_clears_the_fields() -> void:
	var w: SimWorld = B.make_world(1, {"hiding_volumes": [B.cube_volume(B.ARENA, 4.0)]})
	# spawn outside (spawn_entity already computes `hidden`), then move in
	var e: SimEntity = B.player(w, B.ARENA + Vector3(10.0, 0.0, 0.0))
	assert_false(e.hidden, "spawned outside: not hidden")
	e.position = B.ARENA
	assert_true(NpcBrain.update_hidden(w, e), "entering reports a change")
	assert_true(e.hidden, "hidden")
	assert_eq(e.hidden_since_tick, w.tick, "since this tick")
	assert_false(NpcBrain.update_hidden(w, e), "no change while inside")
	e.position = B.ARENA + Vector3(10.0, 0.0, 0.0)
	assert_true(NpcBrain.update_hidden(w, e), "leaving reports a change")
	assert_false(e.hidden, "revealed")
	assert_eq(e.hidden_since_tick, -1, "since cleared")


func test_detection_against_a_hidden_target_uses_the_reduced_radius() -> void:
	var probe := B.make_world(1)
	var r: float = B.species_f(probe, &"barracuda", "detection_radius_m")
	var mult: float = B.rule_f(probe, "hiding.detection_mult")
	for c in [[r * mult + 3.0, false], [r * mult - 2.0, true]]:
		var w: SimWorld = B.make_world(5, {"hiding_volumes": [B.cube_volume(B.ARENA, 3.0)]})
		var p: SimEntity = B.player(w, B.ARENA)
		B.tough(p)
		var a: SimEntity = B.npc(w, &"barracuda", B.ARENA + Vector3(float(c[0]), 0.0, 0.0), 1.0, Vector3.RIGHT)
		# `hidden` is first computed in the movement phase of the first step (after phase 1 brains): let one step
		# run without brains so the barracuda's first look already sees a hidden player
		w.brains_enabled = false
		B.step_n(w, 1)
		w.brains_enabled = true
		var took: int = B.step_until(w, func() -> bool: return a.aggro_target == p.id, 20)
		assert_eq(took >= 0, c[1], "hidden player at %s m (reduced radius %s m): detected = %s" % [c[0], r * mult, c[1]])
		assert_true(p.hidden, "precondition: the player is hidden")


func test_a_chased_target_is_lost_after_lose_target_s_in_hiding() -> void:
	var lose: int = 0
	for hidden in [true, false]:
		var vols: Array = [B.cube_volume(B.ARENA, 3.0)] if hidden else []
		var w: SimWorld = B.make_world(5, {"hiding_volumes": vols})
		lose = B.ticks(B.rule_f(w, "hiding.lose_target_s"))
		var p: SimEntity = B.player(w, B.ARENA)
		B.tough(p)
		var a: SimEntity = B.npc(w, &"barracuda", B.ARENA + Vector3(40.0, 0.0, 0.0), 1.0, Vector3.LEFT)
		a.aggro_target = p.id  # mid-chase, e.g. the player just dived into the kelp
		a.aggro_until_tick = w.tick + 100000
		B.step_n(w, lose - 10)
		assert_eq(a.aggro_target, p.id, "hidden=%s: still chasing before lose_target_s" % hidden)
		B.step_n(w, 15)
		if hidden:
			assert_eq(a.aggro_target, -1, "hidden for lose_target_s: target lost")
			assert_ne(a.brain_state, NpcBrain.State.CHASE, "and no longer chasing")
		else:
			assert_eq(a.aggro_target, p.id, "control: a visible target is still chased")


func test_a_target_hidden_for_lose_target_s_is_not_detected_even_close() -> void:
	var w: SimWorld = B.make_world(5, {"hiding_volumes": [B.cube_volume(B.ARENA, 3.0)]})
	var lose: int = B.ticks(B.rule_f(w, "hiding.lose_target_s"))
	var p: SimEntity = B.player(w, B.ARENA)
	B.tough(p)
	var a: SimEntity = B.npc(w, &"barracuda", B.ARENA + Vector3(5.0, 0.0, 0.0), 1.0, Vector3.LEFT)
	w.brains_enabled = false
	B.step_n(w, lose + 5)
	w.brains_enabled = true
	for i in 30:
		B.step_n(w, 1)
		assert_eq(a.aggro_target, -1, "a long-hidden player 5 m away stays undetected (tick %d)" % i)
