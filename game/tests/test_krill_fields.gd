extends TestCase
## Krill clouds (research 3.5): more PlanktonField instances (SimWorld.krill, one per zone palette), built by
## PlanktonField.create_block from map.krill blocks. Eaten like plankton (players only, mouth cell, min_eat_density,
## eat_per_tick, XP = xp_gain(amount * xp_per_unit, L_p, species length, xp_falloff), hunger = amount * hunger_per_unit),
## PLANKTON_EATEN.data.field = 1.. for krill (0 = plankton), regrowth bounded by cell_cap, fields are part of
## state_hash, and plankton itself is unchanged (see also the older test_s4_plankton.gd / test_feat_plankton_patches.gd).
## Controlled blocks here are UNIFORM (no `variation`) over the existing zone "open_water" / "shallows", so the tests
## do not depend on the shipped krill layout; the shipped layout has its own data tests (test_food_content.gd) and the
## patchiness sampler below. Needs species krill_open / krill_shallows from the implementation (PENDING until then).

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")

const OPEN: String = "open_water"


# ---------------------------------------------------------------- helpers

func _species_ready() -> bool:
	var missing := PackedStringArray()
	for id: StringName in F.KRILL_SPECIES:
		if F.make_world(1).content.get_species(id).is_empty():
			missing.append("species %s" % id)
	return F.require(self, missing)


## {"w", "field", "probe", "block", "pid"}: one uniform krill block in open water + a B1 player at the probe cell centre.
func _setup(world_seed: int = 801, overrides: Dictionary = {}, band_xp: float = 0.0) -> Dictionary:
	var block: Dictionary = F.krill_block(&"krill_open", [OPEN], overrides)
	var w: SimWorld = F.make_world(world_seed, {"krill": [block]})
	if not F.require_krill(self, w):
		return {}
	var fields: Array = F.krill_of(w)
	if fields.size() != 1:
		fail("expected 1 krill field for 1 block, got %d" % fields.size())
		return {}
	var field: Object = fields[0]
	var probe: Vector3 = F.krill_probe(w, field, OPEN)
	if not probe.is_finite():
		fail("setup: no krill cell with density > 0 in open_water")
		return {}
	var p: SimEntity = S3.player_at(w, probe, band_xp)
	p.hunger = 0.4 * S3.rule_f(w.content, "hunger_max")
	return {"w": w, "field": field, "probe": probe, "block": block, "pid": p.id}


func _krill_events(evs: Array[SimEvent]) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		if int(ev.data.get(F.FIELD_KEY, 0)) > 0:
			out.append(ev)
	return out


func _krill_length(w: SimWorld, species: StringName) -> float:
	return float((w.content.get_species(species)["length_m"] as Dictionary)["min"])


# ---------------------------------------------------------------- eating

func test_a_player_in_a_krill_cell_eats_it_with_field_index_xp_and_hunger() -> void:
	if not _species_ready():
		return
	var ctx: Dictionary = _setup()
	if ctx.is_empty():
		return
	var w: SimWorld = ctx["w"]
	var field: Object = ctx["field"]
	var p: SimEntity = w.get_entity(ctx["pid"])
	var block: Dictionary = ctx["block"]
	var d0: float = float(field.call("density_at", ctx["probe"]))
	assert_almost_eq(d0, float(block["density_max"]), 1e-9, "a fresh uniform cell starts at density_max")
	var xp0: float = p.xp
	var h0: float = p.hunger
	var evs: Array[SimEvent] = F.run(w, 1, {p.id: ctx["probe"]})
	var ks: Array[SimEvent] = _krill_events(evs)
	assert_eq(ks.size(), 1, "one krill PLANKTON_EATEN in the first tick")
	if ks.is_empty():
		return
	var ev: SimEvent = ks[0]
	assert_eq(int(ev.data.get(F.FIELD_KEY)), 1, "data.field == 1 for the first krill field (0 is plankton)")
	assert_eq(ev.entity_id, p.id, "entity = the eater")
	var amount: float = float(ev.data["amount"])
	assert_almost_eq(amount, float(block["density_max"]) / float(field.get("critters_per_cell")), 1e-9, "amount = one krill (density_max / critters_per_cell)")
	var want_xp: float = SimRules.xp_gain(amount * float(block["xp_per_unit"]), p.length_m, _krill_length(w, &"krill_open"), F.xp_falloff(w.content))
	assert_almost_eq(ev.value, want_xp, 1e-9, "XP = xp_gain(amount * xp_per_unit, L_p, krill length, falloff)")
	assert_almost_eq(p.xp - xp0, want_xp, 1e-9, "the player got exactly that")
	assert_almost_eq(p.hunger - h0, amount * float(block["hunger_per_unit"]), 1e-9, "hunger = amount * hunger_per_unit")
	assert_almost_eq(float(field.call("density_at", ctx["probe"])) , d0 - amount + 0.0, 0.05, "density dropped by about the amount (plus a tick of regrowth)")


func test_a_cell_is_eaten_down_to_min_eat_density_then_stops_and_regrows_to_its_cap() -> void:
	if not _species_ready():
		return
	var ctx: Dictionary = _setup(802, {"regrow_per_s": 0.5})
	if ctx.is_empty():
		return
	var w: SimWorld = ctx["w"]
	var field: Object = ctx["field"]
	var block: Dictionary = ctx["block"]
	var p: SimEntity = w.get_entity(ctx["pid"])
	var evs: Array[SimEvent] = F.run(w, 60, {p.id: ctx["probe"]})
	var ks: Array[SimEvent] = _krill_events(evs)
	var total: float = 0.0
	var gained: float = 0.0
	for ev: SimEvent in ks:
		total += float(ev.data["amount"])
		gained += ev.value
	assert_true(total >= float(block["density_max"]) - float(block["min_eat_density"]) - float(block["eat_per_tick"]), "most of the rich cell was eaten (%.2f of %.2f)" % [total, float(block["density_max"])])
	assert_true(total <= float(block["density_max"]) + 60.0 * float(block["regrow_per_s"]) / 30.0 + 1e-6, "never more than the cell held plus its regrowth")
	assert_almost_eq(p.xp, gained, 1e-9, "all XP came from krill events")
	var last_tick_events: int = _krill_events(F.run(w, 30, {p.id: ctx["probe"]})).size()
	assert_true(last_tick_events < 30, "eating stops while the cell is below min_eat_density (not one event per tick forever)")
	F.run(w, 30 * 10, {p.id: F.quiet_point(w)})
	assert_almost_eq(float(field.call("density_at", ctx["probe"])), float(block["density_max"]), 1e-6, "left alone the cell regrows to its cap and no higher")


func test_nothing_to_eat_outside_the_krill_zones() -> void:
	if not _species_ready():
		return
	var ctx: Dictionary = _setup(803)
	if ctx.is_empty():
		return
	var w: SimWorld = ctx["w"]
	var abyss: Array[Vector3] = S3.zone_box(w, "abyss")
	var far: Vector3 = (abyss[0] + abyss[1]) * 0.5
	var p: SimEntity = w.get_entity(ctx["pid"])
	var evs: Array[SimEvent] = F.run(w, 60, {p.id: far})
	assert_eq(_krill_events(evs).size(), 0, "no krill outside the listed zones")
	assert_almost_eq(float(ctx["field"].call("density_at", far)), 0.0, 1e-12, "density 0 outside the zones")


func test_npcs_do_not_graze_krill() -> void:
	if not _species_ready():
		return
	var ctx: Dictionary = _setup(804)
	if ctx.is_empty():
		return
	var w: SimWorld = ctx["w"]
	w.get_entity(ctx["pid"]).position = F.quiet_point(w)   # the player leaves
	var npc: SimEntity = S3.npc_at(w, &"small_reef_fish", ctx["probe"], 0.3)
	var evs: Array[SimEvent] = F.run(w, 60, {ctx["pid"]: F.quiet_point(w), npc.id: ctx["probe"]})
	assert_eq(_krill_events(evs).size(), 0, "an NPC in a krill cell eats nothing (players only)")
	assert_almost_eq(float(ctx["field"].call("density_at", ctx["probe"])), float(ctx["block"]["density_max"]), 1e-9, "the cell stays full")


func test_xp_per_unit_falls_with_the_players_band_by_the_falloff() -> void:
	if not _species_ready():
		return
	var db: ContentDB = F.make_world(1).content
	var per_band: Array[float] = []
	for band in range(1, db.band_count() + 1):
		var length: float = float(db.get_band(band)["length_m"]["min"])
		per_band.append(SimRules.xp_gain(1.0, length, _krill_length(F.make_world(1), &"krill_open"), F.xp_falloff(db)))
	for i in range(1, per_band.size()):
		assert_true(per_band[i] <= per_band[i - 1] + 1e-12, "xp multiplier never rises with the band (B%d %.3f -> B%d %.3f)" % [i, per_band[i - 1], i + 1, per_band[i]])
	assert_true(per_band[0] > 0.7, "B1 gets (nearly) full XP from krill (%.3f)" % per_band[0])
	assert_true(per_band[per_band.size() - 1] <= 0.25, "B4 gets <= 25%% (krill cannot feed the late game; %.3f)" % per_band[per_band.size() - 1])
	# and the sim agrees with the formula for a band-3 eater
	var hi_xp: float = S3.xp_for_length(db, 1.0)
	var ctx: Dictionary = _setup(805, {}, hi_xp)
	if ctx.is_empty():
		return
	var w: SimWorld = ctx["w"]
	var p: SimEntity = w.get_entity(ctx["pid"])
	var length_at_eat: float = p.length_m   # the eat uses the length before this tick's growth from the XP it earns
	var ks: Array[SimEvent] = _krill_events(F.run(w, 1, {p.id: ctx["probe"]}))
	if ks.is_empty():
		fail("a big fish in a krill cell eats (swallow ratio) but got no event")
		return
	var want: float = SimRules.xp_gain(float(ks[0].data["amount"]) * float(ctx["block"]["xp_per_unit"]), length_at_eat, _krill_length(w, &"krill_open"), F.xp_falloff(w.content))
	assert_almost_eq(ks[0].value, want, 1e-9, "band %d player: XP follows the falloff" % p.band)


# ---------------------------------------------------------------- several blocks, hashing

func test_two_blocks_keep_separate_fields_and_field_indices() -> void:
	if not _species_ready():
		return
	var blocks: Array = [F.krill_block(&"krill_open", [OPEN]), F.krill_block(&"krill_abyss", ["abyss"])]   # disjoint boxes
	var w: SimWorld = F.make_world(806, {"krill": blocks})
	if not F.require_krill(self, w):
		return
	var fields: Array = F.krill_of(w)
	assert_eq(fields.size(), 2, "one PlanktonField per block, in block order")
	if fields.size() != 2:
		return
	assert_eq(str(fields[0].get("species_id")), "krill_open", "field 0 (data.field 1) is the first block")
	assert_eq(str(fields[1].get("species_id")), "krill_abyss", "field 1 (data.field 2) is the second block")
	var probe: Vector3 = F.krill_probe(w, fields[1], "abyss")
	if not probe.is_finite():
		fail("setup: no abyss krill cell")
		return
	var p: SimEntity = S3.player_at(w, probe, 0.0)
	var ks: Array[SimEvent] = _krill_events(F.run(w, 3, {p.id: probe}))
	assert_true(ks.size() >= 1, "abyss krill eaten")
	for ev: SimEvent in ks:
		assert_eq(int(ev.data.get(F.FIELD_KEY)), 2, "the abyss block is data.field 2")
	assert_eq((fields[0].call("touched_cells") as PackedInt32Array).size(), 0, "the open-water field was not touched")
	assert_true((fields[1].call("touched_cells") as PackedInt32Array).size() > 0, "the abyss field was")


func test_krill_fields_are_hashed_and_deterministic() -> void:
	if not _species_ready():
		return
	var a: Dictionary = _setup(807)
	var b: Dictionary = _setup(807)
	var c: Dictionary = _setup(807)
	if a.is_empty() or b.is_empty() or c.is_empty():
		return
	var ea: Array[SimEvent] = F.run(a["w"], 20, {a["pid"]: a["probe"]})
	var eb: Array[SimEvent] = F.run(b["w"], 20, {b["pid"]: b["probe"]})
	F.run(c["w"], 20, {c["pid"]: F.quiet_point(c["w"])})   # control: the player never enters the cloud
	assert_eq(S4.signature(ea), S4.signature(eb), "identical runs: identical event streams")
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "identical runs: identical state_hash")
	assert_eq(F.field_state_bytes(a["field"], (a["w"] as SimWorld).tick), F.field_state_bytes(b["field"], (b["w"] as SimWorld).tick), "identical field bytes")
	assert_ne(F.field_state_bytes(a["field"], (a["w"] as SimWorld).tick), F.field_state_bytes(c["field"], (c["w"] as SimWorld).tick), "an eaten cell is part of the field state")
	# isolate the field's contribution: two identical worlds, one cell eaten directly through the public field API
	var x: Dictionary = _setup(808)
	var y: Dictionary = _setup(808)
	if x.is_empty() or y.is_empty():
		return
	var cell: int = int((y["field"] as Object).call("cell_at", y["probe"]))
	assert_eq((x["w"] as SimWorld).state_hash(), (y["w"] as SimWorld).state_hash(), "setup: identical worlds hash alike")
	(y["field"] as Object).call("eat", cell, (y["w"] as SimWorld).tick)
	assert_ne((x["w"] as SimWorld).state_hash(), (y["w"] as SimWorld).state_hash(), "state_hash covers the krill fields (one eaten cell changes it)")


# ---------------------------------------------------------------- plankton regression

func test_plankton_events_carry_field_zero_and_plankton_behaviour_is_unchanged() -> void:
	var cfg_zones: Array = (S3.content().get_map(F.MAP_ID).get("plankton", {}) as Dictionary).get("zones", [])
	var w: SimWorld = S4.make_world(809, {"plankton_zones": cfg_zones})
	if not S4.plankton_problems(w).is_empty():
		F.pending(self, "plankton API missing: %s" % ", ".join(S4.plankton_problems(w)))
		return
	var probe: Vector3 = S4.plankton_probe(w)
	if not probe.is_finite():
		fail("setup: no plankton cell")
		return
	var p: SimEntity = S3.player_at(w, probe, 0.0)
	var evs: Array[SimEvent] = S4.run(w, 5, func(world: SimWorld) -> void: S4.pin(world, p.id, probe))
	var pl: Array[SimEvent] = S4.events_named(evs, "PLANKTON_EATEN")
	assert_true(pl.size() >= 1, "plankton is still eaten")
	for ev: SimEvent in pl:
		if not F.require(self, PackedStringArray([] if ev.data.has(F.FIELD_KEY) else ["PLANKTON_EATEN.data.field"])):
			return
		assert_eq(int(ev.data[F.FIELD_KEY]), 0, "plankton is field 0")


func test_create_block_reproduces_create_for_the_plankton_block() -> void:
	var s: GDScript = F.require_script(self, F.PLANKTON_SCRIPT, ["create_block", "create"])
	if s == null:
		return
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var map: Dictionary = db.get_map(F.MAP_ID)
	var old_way: Object = s.call("create", db, map)
	var new_way: Object = s.call("create_block", db, map, map["plankton"])
	assert_not_null(old_way, "create() still works (one-line wrapper)")
	assert_not_null(new_way, "create_block() works for the plankton block")
	if old_way == null or new_way == null:
		return
	for prop: String in ["species_id", "cell_m", "density_max", "regrow_per_tick", "eat_per_tick", "min_eat_density", "xp_per_unit", "hunger_per_unit", "length_m"]:
		assert_eq(old_way.get(prop), new_way.get(prop), "same %s" % prop)
	assert_eq(F.field_state_bytes(old_way, 0), F.field_state_bytes(new_way, 0), "same (empty) state")
	assert_eq(int(old_way.call("plankton_cell_count")), int(new_way.call("plankton_cell_count")), "same set of plankton cells")


# ---------------------------------------------------------------- shipped layout (patchy clouds, not haze)

func test_the_shipped_krill_blocks_read_as_clouds_not_a_uniform_haze() -> void:
	if not _species_ready():
		return
	var blocks: Variant = S3.content().get_map(F.MAP_ID).get(F.MAP_KRILL_KEY)
	if not F.require(self, PackedStringArray([] if blocks is Array and not (blocks as Array).is_empty() else ["map.krill in the shipped data"])):
		return
	var w: SimWorld = F.make_world(810, {"krill": (blocks as Array).duplicate(true)})
	if not F.require_krill(self, w):
		return
	var fields: Array = F.krill_of(w)
	assert_eq(fields.size(), (blocks as Array).size(), "one field per shipped block")
	for k in fields.size():
		var field: Object = fields[k]
		var block: Dictionary = (blocks as Array)[k]
		var cell: float = float(block["cell_m"])
		var want_empty: float = float((block.get("variation", {}) as Dictionary).get("empty_frac", 0.0))
		var empty: int = 0
		var total: int = 0
		for z: Variant in block["zones"]:
			var box: Array[Vector3] = F.box_of(w.map, str(z))
			var y: float = (box[0].y + box[1].y) * 0.5
			var x: float = box[0].x + cell * 0.5
			while x < box[1].x:
				var zz: float = box[0].z + cell * 0.5
				while zz < box[1].z:
					var c: int = int(field.call("cell_at", Vector3(x, y, zz)))
					if c >= 0:
						total += 1
						if float(field.call("cell_cap", c)) <= 0.0:
							empty += 1
					zz += cell * 4.0
				x += cell * 4.0
		assert_true(total > 50, "%s: enough sampled columns (%d)" % [block["species_id"], total])
		if total > 50:
			var share: float = float(empty) / float(total)
			assert_true(absf(share - want_empty) <= 0.2, "%s: %.0f%% of sampled cells are empty, variation.empty_frac says %.0f%% (+-20)" % [block["species_id"], share * 100.0, want_empty * 100.0])
			assert_true(share >= 0.4, "%s: at least 40%% of the zone is empty water so krill reads as separate clouds" % block["species_id"])
