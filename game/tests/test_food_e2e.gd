extends TestCase
## End-to-end: a headless world on the SHIPPED food data where a scripted player (SimCommands only, like the bot)
## swallows an egg site, kills a starfish by bites and swims through a krill cloud. Proves the feature changes real
## behaviour: XP, hunger, events and the hashed state move; a control run in empty water does not; two identical runs
## are byte-identical; sonar ignores food; the XP a first patch is worth stays inside a pacing band.
## Capture-only (NOT here): how the food looks, density of krill clouds, health bar over the starfish, draw calls.

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const S6 := preload("res://tests/s6_support.gd")

## Pacing guard for the first patch around a spawn (Q1: bot B1 median ~3 min). XP of every site within NEAR_SPAWN_M eaten
## once, as a share of the B1 -> B2 requirement. Tunable together with the balance pass (X3); wide on purpose.
const PATCH_MIN_FRAC_OF_B2: float = 0.15
const PATCH_MAX_FRAC_OF_B2: float = 2.0
const JOURNEY_SEED: int = 777


# ---------------------------------------------------------------- journey builder

## Nearest live site of kind `kind` ("soft" | "hard") to `from`, with a free approach point; optional exact type.
func _pick(w: SimWorld, from: Vector3, kind: String, type: StringName = &"") -> Dictionary:
	var food: Object = F.food_of(w)
	var buf := PackedInt32Array()
	var recs: Dictionary = F.food_records()
	for radius: float in [20.0, 60.0, 150.0, 400.0]:
		food.call("sites_near_into", from, radius, buf)
		var best: Dictionary = {}
		var best_d: float = INF
		for i: int in buf:
			var t: StringName = StringName(str(food.call("site_type", i)))
			if str(recs.get(str(t), {}).get("kind", "")) != kind or (type != &"" and t != type):
				continue
			var p: Vector3 = food.call("site_pos", i)
			var d: float = p.distance_to(from)
			if d >= best_d or not w.seabed.obstacle_clear(p + Vector3.UP * 0.5, 0.3):
				continue
			var near := PackedInt32Array()
			food.call("sites_near_into", p, 1.0, near)
			if near.size() > 1:
				continue   # isolated sites only: the best-in-cone bite must hit THIS one
			best = {"id": i, "pos": p, "type": t}
			best_d = d
		if not best.is_empty():
			return best
	return {}


func _stand(w: SimWorld, site: Dictionary, length: float) -> Dictionary:
	var rec: Dictionary = F.food_record(w.content, site["type"])
	var reach: float = length * (S3.rule_f(w.content, "bite_reach_mult") if str(rec["kind"]) == "hard" else S3.rule_f(w.content, "mouth_reach_mult"))
	return F.approach(w, site["pos"], (reach + float(rec.get("radius_m", 0.0))) * 0.5)


## {"w","pid","legs"}: shipped food + shipped krill blocks in a controlled world (no fish, no plankton); the legs are
## waypoints {pos, heading, ticks, bite, site (id or -1)}.
func _journey_world() -> Dictionary:
	var shipped: Variant = S3.content().get_map(F.MAP_ID).get(F.MAP_KRILL_KEY)
	var blocks: Array = (shipped as Array).duplicate(true) if shipped is Array else []
	var w: SimWorld = F.make_world(JOURNEY_SEED, {"krill": blocks})
	if not F.require_food(self, w) or not F.require_krill(self, w):
		return {}
	if blocks.is_empty():
		F.pending(self, "map.krill is empty in the shipped data")
		return {}
	var spawn: Vector3 = S3.spawn_point(w, 0)
	var egg: Dictionary = _pick(w, spawn, "soft")
	var star: Dictionary = _pick(w, spawn, "hard", F.T_STARFISH)
	if egg.is_empty() or star.is_empty():
		fail("setup: no isolated egg (%s) or starfish (%s) site on the shipped map" % [egg, star])
		return {}
	var krill_pos: Vector3 = Vector3.INF
	var krill_field: int = -1
	var fields: Array = F.krill_of(w)
	for k in fields.size():
		var zones: Array = (blocks[k] as Dictionary).get("zones", [])
		for z: Variant in zones:
			var probe: Vector3 = F.krill_probe(w, fields[k], str(z))
			if probe.is_finite() and krill_pos == Vector3.INF:
				krill_pos = probe
				krill_field = k + 1
	if not krill_pos.is_finite():
		fail("setup: no krill cell with density > 0 in any shipped krill zone")
		return {}
	var a_egg: Dictionary = _stand(w, egg, 0.1)
	var a_star: Dictionary = _stand(w, star, 0.1)
	if a_egg.is_empty() or a_star.is_empty():
		fail("setup: no free approach point at the egg or the starfish")
		return {}
	var player: SimEntity = S3.player_at(w, a_egg["pos"], 0.0, a_egg["heading"])
	player.hunger = 0.4 * S3.rule_f(w.content, "hunger_max")
	var legs: Array[Dictionary] = [
		{"name": "egg", "pos": a_egg["pos"], "heading": a_egg["heading"], "ticks": 12, "bite": false, "site": egg["id"]},
		{"name": "starfish", "pos": a_star["pos"], "heading": a_star["heading"], "ticks": 400, "bite": true, "site": star["id"]},
		{"name": "krill", "pos": krill_pos, "heading": Vector3.RIGHT, "ticks": 30, "bite": false, "site": -1, "field": krill_field}]
	return {"w": w, "pid": player.id, "legs": legs}


## Runs the legs in order (teleport + pin, like S3 tests); `control` = the same time spent in empty water instead.
func _fly(j: Dictionary, control: bool) -> Array[SimEvent]:
	var w: SimWorld = j["w"]
	var p: SimEntity = w.get_entity(j["pid"])
	var all: Array[SimEvent] = []
	for leg: Dictionary in j["legs"]:
		var pos: Vector3 = F.quiet_point(w) if control else leg["pos"]
		p.position = pos
		p.velocity = Vector3.ZERO
		p.heading = leg["heading"]
		var bites: Array[int] = []
		if bool(leg["bite"]) and not control:
			bites.append(p.id)
		all.append_array(F.run(w, int(leg["ticks"]), {p.id: pos}, bites))
	return all


# ---------------------------------------------------------------- the journey

func test_a_player_eats_an_egg_kills_a_starfish_and_swims_through_krill() -> void:
	var j: Dictionary = _journey_world()
	if j.is_empty():
		return
	var w: SimWorld = j["w"]
	var p: SimEntity = w.get_entity(j["pid"])
	var xp0: float = p.xp
	var hunger0: float = p.hunger
	var hash0: int = w.state_hash()
	var food0: PackedByteArray = F.food_state_bytes(w)
	var legs: Array = j["legs"]
	var evs: Array[SimEvent] = _fly(j, false)

	var egg_id: int = int(legs[0]["site"])
	var star_id: int = int(legs[1]["site"])
	var eaten_egg: Array[SimEvent] = F.named_for(evs, F.EV_EATEN, egg_id)
	var eaten_star: Array[SimEvent] = F.named_for(evs, F.EV_EATEN, star_id)
	assert_eq(eaten_egg.size(), 1, "the egg was swallowed")
	assert_true(bool(eaten_egg[0].data.get("soft", false)) if not eaten_egg.is_empty() else false, "egg: soft")
	assert_true(F.named_for(evs, F.EV_BITTEN, star_id).size() >= 1, "the starfish was bitten (health-bar events)")
	assert_eq(eaten_star.size(), 1, "the starfish died after bites")
	assert_false(bool(eaten_star[0].data.get("soft", true)) if not eaten_star.is_empty() else false, "starfish: killed by bites, not swallowed")
	assert_false(F.site_alive(w, egg_id), "egg site gone")
	assert_false(F.site_alive(w, star_id), "starfish site gone")

	var krill_evs: Array[SimEvent] = []
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		if int(ev.data.get(F.FIELD_KEY, 0)) > 0:
			krill_evs.append(ev)
	assert_true(krill_evs.size() >= 1, "krill was grazed (PLANKTON_EATEN with data.field > 0)")
	var in_target: int = 0
	for ev2: SimEvent in krill_evs:
		if int(ev2.data.get(F.FIELD_KEY)) == int(legs[2]["field"]):
			in_target += 1
	assert_true(in_target >= 1, "the field index (data.field) names the krill block that was entered")

	# conservation: every XP point came from one of the three food events
	var from_events: float = 0.0
	for ev3: SimEvent in eaten_egg + eaten_star + krill_evs:
		from_events += ev3.value
	assert_almost_eq(p.xp - xp0, from_events, 1e-6, "XP gained == sum of the SITE_EATEN and krill PLANKTON_EATEN values")
	assert_true(p.xp > xp0 and p.hunger > hunger0 - 1e-9, "XP and hunger moved")

	# the hashed state moved
	assert_ne(w.state_hash(), hash0, "state_hash changed")
	assert_ne(F.food_state_bytes(w), food0, "the food state (eaten sites) changed")
	var target: Object = F.krill_of(w)[int(legs[2]["field"]) - 1]
	assert_true((target.call("touched_cells") as PackedInt32Array).size() > 0, "the entered krill field has touched (eaten) cells")


func test_a_control_run_in_empty_water_changes_nothing() -> void:
	var j: Dictionary = _journey_world()
	if j.is_empty():
		return
	var w: SimWorld = j["w"]
	var p: SimEntity = w.get_entity(j["pid"])
	var xp0: float = p.xp
	var food0: PackedByteArray = F.food_state_bytes(w)
	var evs: Array[SimEvent] = _fly(j, true)
	assert_eq(F.named(evs, F.EV_EATEN).size() + F.named(evs, F.EV_BITTEN).size(), 0, "no site events in empty water")
	assert_eq(S4.events_named(evs, "PLANKTON_EATEN").size(), 0, "no krill in empty water")
	assert_almost_eq(p.xp, xp0, 1e-12, "no XP")
	assert_eq(F.food_state_bytes(w), food0, "the food state is untouched")


func test_two_identical_journeys_are_byte_identical() -> void:
	var a: Dictionary = _journey_world()
	var b: Dictionary = _journey_world()
	if a.is_empty() or b.is_empty():
		return
	var ea: Array[SimEvent] = _fly(a, false)
	var eb: Array[SimEvent] = _fly(b, false)
	assert_eq(S4.signature(ea), S4.signature(eb), "identical event streams (including payloads)")
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "identical state_hash")
	assert_eq(F.food_state_bytes(a["w"]), F.food_state_bytes(b["w"]), "identical food state")


func test_sonar_does_not_show_food() -> void:
	# Decision Q6: food is NOT on sonar. Sites are not entities, so a pulse in the middle of food reports no contacts.
	var j: Dictionary = _journey_world()
	if j.is_empty():
		return
	var w: SimWorld = j["w"]
	var p: SimEntity = w.get_entity(j["pid"])
	if not S6.give_ability(w, p, "sonar"):
		F.pending(self, "no mutation node grants sonar in the shipped data")
		return
	var leg: Dictionary = (j["legs"] as Array)[0]
	var radius: float = S6.ability_f(w.content, &"sonar", "radius_m")
	var near := PackedInt32Array()
	F.food_of(w).call("sites_near_into", leg["pos"], radius, near)
	assert_true(near.size() >= 3, "setup: at least 3 food sites inside the sonar radius (%d)" % near.size())
	p.position = leg["pos"]
	p.heading = leg["heading"]
	w.submit(SimCommand.ability(p.id, &"sonar"))
	var evs: Array[SimEvent] = F.run(w, 4, {p.id: leg["pos"]})
	var pulses: Array[SimEvent] = S4.events_named(evs, "SONAR_PULSE")
	assert_eq(pulses.size(), 1, "the pulse happened")
	if pulses.size() == 1:
		assert_eq((pulses[0].data.get("contacts", []) as Array).size(), 0, "no contacts: sites (and krill) are not on sonar")


func test_the_first_patch_around_each_spawn_is_worth_a_bounded_amount_of_xp() -> void:
	# Pacing guard (Q1, research 3.4): everything within 40 m of a spawn eaten ONCE by a B1 fish must not make B1 vanish
	# (> 2x the B1->B2 requirement) nor leave the early game empty (< 15%). The real numbers come from the bot balance run.
	var w: SimWorld = F.make_world(JOURNEY_SEED)
	if not F.require_food(self, w):
		return
	var b1 := SimEntity.new()
	b1.band = 1
	b1.length_m = float(w.content.get_band(1)["length_m"]["min"])
	var b2_xp: float = float(w.content.get_band(2)["xp_to_reach"])
	var food: Object = F.food_of(w)
	var buf := PackedInt32Array()
	for si in 3:
		var spawn: Vector3 = S3.spawn_point(w, si)
		food.call("sites_near_into", spawn, F.NEAR_SPAWN_M, buf)
		var total: float = 0.0
		for i: int in buf:
			var rec: Dictionary = F.food_record(w.content, StringName(str(food.call("site_type", i))))
			if not rec.is_empty():
				total += F.expect_xp(w.content, b1, rec)
		assert_true(total >= b2_xp * PATCH_MIN_FRAC_OF_B2, "spawn %d: first patch worth %.1f XP, at least %.0f%% of the B1->B2 %.0f" % [si, total, PATCH_MIN_FRAC_OF_B2 * 100.0, b2_xp])
		assert_true(total <= b2_xp * PATCH_MAX_FRAC_OF_B2, "spawn %d: first patch worth %.1f XP, at most %.0f%% of the B1->B2 %.0f" % [si, total, PATCH_MAX_FRAC_OF_B2 * 100.0, b2_xp])


func test_the_whole_reef_is_not_a_single_xp_pile() -> void:
	# Respawns cap the farming rate: one pass over EVERY site must stay far above the run's XP need only in aggregate,
	# but each type's respawn_s must exceed the time to eat a 12-item patch at bot speed (research 3.4): >= 60 s.
	var recs: Dictionary = F.food_records()
	if not F.require(self, PackedStringArray([] if not recs.is_empty() else ["data/food/*.json"])):
		return
	for id_v: Variant in recs.keys():
		assert_true(float((recs[id_v] as Dictionary)["respawn_s"]) >= 60.0, "%s: respawn_s >= 60 s so a patch is not an infinite XP tap" % id_v)
