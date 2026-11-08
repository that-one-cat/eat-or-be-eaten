extends TestCase
## Food data (research 3.1, 2.2, 3.5, 6.4): data/food/*.json schema (positive and negative), cross-references (piece,
## sfx), the dressing `food` block, the map `krill` blocks and zones, the Done-when decisions expressed as data
## (decor shells / starfish / clams and snails have raised HP, all new food is edible, abyss snails split cyan / violet
## by depth), and the Blender-side contract files (specs, palette rows, krill species).
## Tests that need the implementation report PENDING until it lands (see food_support.gd; FOOD_STRICT=1 fails them).

const F := preload("res://tests/food_support.gd")
const S5 := preload("res://tests/s5_support.gd")

const NUM_KEYS: Array[String] = ["length_m", "xp", "respawn_s"]


func after_each() -> void:
	F.cleanup_temp()


func _errs(rec: Dictionary) -> PackedStringArray:
	return ContentDB.validate_record(F.FOOD_KIND, rec, "food/test.json")


# ======================================================================= shipped data

func test_shipped_food_records_are_valid_and_complete() -> void:
	var recs: Dictionary = F.food_records()
	if not F.require(self, PackedStringArray([] if not recs.is_empty() else ["data/food/*.json"])):
		return
	var db: ContentDB = S5.content()
	assert_true(db.is_valid(), "content valid: %s" % [db.errors])
	for id_v: Variant in recs.keys():
		var rec: Dictionary = recs[id_v]
		var where: String = str(rec["_file"])
		assert_eq(str(rec["id"]), str(where).get_basename(), "%s: id equals the file stem" % where)
		assert_has(["soft", "hard"], str(rec.get("kind")), "%s: kind soft|hard" % where)
		for k: String in F.REQUIRED_FOOD_KEYS:
			assert_true(rec.has(k), "%s: has %s" % [where, k])
		assert_true(float(rec.get("length_m", 0.0)) > 0.0, "%s: length_m > 0" % where)
		assert_true(float(rec.get("xp", -1.0)) >= 0.0, "%s: xp >= 0" % where)
		assert_true(float(rec.get("respawn_s", -1.0)) > 0.0, "%s: respawn_s > 0 (sites come back)" % where)
		assert_true(float(rec.get("hp_mult", 1.0)) > 0.0, "%s: hp_mult > 0" % where)
		if rec.has("swallow_ratio"):
			var r: float = float(rec["swallow_ratio"])
			assert_true(r > 0.0 and r <= 1.0, "%s: swallow_ratio in (0, 1]" % where)
		if rec.has("xp_band_mult"):
			assert_eq((rec["xp_band_mult"] as Array).size(), db.band_count(), "%s: xp_band_mult has one entry per band" % where)
		var listed: Array[String] = F.record_pieces(rec)
		assert_true(listed.size() >= 1, "%s: lists at least one piece" % where)
		for pid: String in listed:
			assert_true(ContentDB.env_piece_variants().has(pid), "%s: piece %s has GLBs" % [where, pid])


func test_every_decor_shell_starfish_and_clam_is_edible_with_raised_hp() -> void:
	var recs: Dictionary = F.food_records()
	if not F.require(self, PackedStringArray([] if not recs.is_empty() else ["data/food/*.json"])):
		return
	for piece: String in F.DECOR_PIECES.keys():
		var type: String = F.DECOR_PIECES[piece]
		assert_true(recs.has(type), "food type '%s' exists for decor piece %s (Q2: all of them are edible)" % [type, piece])
		if not recs.has(type):
			continue
		var rec: Dictionary = recs[type]
		assert_eq(F.record_pieces(rec), [piece], "%s lists exactly the existing decor piece" % type)
		assert_eq(str(rec.get("kind")), "hard", "%s is bitten, not swallowed" % type)
		assert_true(float(rec.get("hp_mult", 1.0)) > 1.0, "%s: raised HP (hp_mult > 1), slow static prey" % type)


func test_every_egg_piece_has_a_soft_type_and_every_snail_piece_a_hard_type() -> void:
	var recs: Dictionary = F.food_records()
	if not F.require(self, PackedStringArray([] if not recs.is_empty() else ["data/food/*.json"])):
		return
	var all_eggs: Array[String] = []
	all_eggs.append_array(F.EGG_PIECES_A)
	all_eggs.append_array(F.EGG_PIECES_B_KELP)
	all_eggs.append_array(F.EGG_PIECES_B_ARCH)
	all_eggs.append_array(F.EGG_PIECES_C)
	for piece: String in all_eggs:
		var types: Array[StringName] = F.types_of_pieces([piece])
		assert_true(types.size() >= 1, "egg piece %s has a food type" % piece)
		for t: StringName in types:
			assert_eq(str(recs[str(t)]["kind"]), "soft", "%s (%s): eggs are swallowed" % [t, piece])
	for piece2: String in [F.SNAIL_ORANGE_PIECE, F.SNAIL_CYAN_PIECE, F.SNAIL_VIOLET_PIECE]:
		var types2: Array[StringName] = F.types_of_pieces([piece2])
		assert_true(types2.size() >= 1, "snail piece %s has a food type" % piece2)
		for t2: StringName in types2:
			assert_eq(str(recs[str(t2)]["kind"]), "hard", "%s (%s): snails are killed by bites" % [t2, piece2])
			assert_true(float(recs[str(t2)].get("hp_mult", 1.0)) > 1.0, "%s: snail HP raised" % t2)


func test_pacing_numbers_leave_the_first_minutes_easy_but_not_unbounded() -> void:
	# Q1 (bot B1 median ~3 min) is a balance RESULT (capture/bot run). Structural guards only: the data numbers must be
	# able to move the pacing and must not allow instant farming.
	var recs: Dictionary = F.food_records()
	if not F.require(self, PackedStringArray([] if not recs.is_empty() else ["data/food/*.json"])):
		return
	var db: ContentDB = S5.content()
	var b1_to_b2: float = float(db.get_band(2)["xp_to_reach"])
	for id_v: Variant in recs.keys():
		var rec: Dictionary = recs[id_v]
		assert_true(float(rec["xp"]) < b1_to_b2 * 0.2, "%s: one item is worth well under 20%% of B1->B2 (%s xp)" % [id_v, rec["xp"]])
		assert_true(float(rec["respawn_s"]) >= 30.0, "%s: respawn_s >= 30 (a patch cannot be farmed continuously)" % id_v)


# ======================================================================= negative schema

func test_a_good_food_record_validates_and_each_required_key_is_enforced() -> void:
	if not F.content_ready(self):
		return
	assert_eq(_errs(F.good_food_record()).size(), 0, "baseline record is valid: %s" % [_errs(F.good_food_record())])
	for k: String in F.REQUIRED_FOOD_KEYS:
		var rec: Dictionary = F.good_food_record()
		rec.erase(k)
		assert_true(_errs(rec).size() > 0, "missing '%s' is rejected" % k)


func test_bad_numbers_and_enums_are_rejected() -> void:
	if not F.content_ready(self):
		return
	var cases: Array[Dictionary] = [
		{"hp_mult": 0.0}, {"hp_mult": -1.0}, {"base_hp": 0.0}, {"swallow_ratio": 1.5}, {"swallow_ratio": -0.1},
		{"xp": -1.0}, {"respawn_s": -5.0}, {"length_m": 0.0}, {"kind": "squishy"},
		{"xp_band_mult": [1, 1, 1]}, {"xp_band_mult": [1, 1, 1, 1, 1]}, {"xp_band_mult": [1, -1, 1, 1]},
		{"xp": "three"}, {"hp_mult": "2"}]
	for c: Dictionary in cases:
		var rec: Dictionary = F.good_food_record()
		for k: Variant in c.keys():
			rec[k] = c[k]
		assert_true(_errs(rec).size() > 0, "rejected: %s" % [c])
	var ok: Dictionary = F.good_food_record()
	ok["swallow_ratio"] = 0.5
	assert_eq(_errs(ok).size(), 0, "swallow_ratio 0.5 is valid: %s" % [_errs(ok)])


func test_unknown_piece_and_unknown_sfx_are_cross_reference_errors() -> void:
	if not F.content_ready(self):
		return
	var good: ContentDB = F.db_with(func(root: String) -> void:
		F.write_json(root.path_join("food/zz_test_food.json"), F.good_food_record()))
	assert_true(good.is_valid(), "a valid extra record loads: %s" % [good.errors])
	assert_true(good.has_method("get_food") and not F.food_record(good, &"zz_test_food").is_empty(), "get_food returns the extra record")
	var bad_piece: Dictionary = F.good_food_record()
	bad_piece[F.FOOD_PIECES_KEY] = [{"id": "no_such_piece"}]
	var db1: ContentDB = F.db_with(func(root: String) -> void:
		F.write_json(root.path_join("food/zz_test_food.json"), bad_piece))
	assert_false(db1.is_valid(), "unknown piece -> invalid content")
	assert_true(F.errors_mention(db1, "no_such_piece") or F.errors_mention(db1, "piece"), "the error names the piece: %s" % [db1.errors])
	var bad_sfx: Dictionary = F.good_food_record()
	bad_sfx["sfx"] = "no_such_sfx_group"
	var db2: ContentDB = F.db_with(func(root: String) -> void:
		F.write_json(root.path_join("food/zz_test_food.json"), bad_sfx))
	assert_false(db2.is_valid(), "unknown sfx group -> invalid content")
	assert_true(F.errors_mention(db2, "sfx"), "the error names sfx: %s" % [db2.errors])


# ======================================================================= dressing `food` block

func _dressing_with(edit: Callable) -> ContentDB:
	return F.db_with(func(root: String) -> void:
		var path: String = root.path_join("maps/reef_dressing.json")
		var d: Dictionary = F.read_json(path)
		edit.call(d)
		F.write_json(path, d))


func test_the_shipped_dressing_food_block_has_rules_authored_anchors_and_valid_references() -> void:
	if not F.content_ready(self):
		return
	var d: Dictionary = S5.content().get_dressing(F.MAP_ID)
	assert_true(d.get(F.DRESSING_FOOD_KEY) is Dictionary, "reef_dressing.json has a food block")
	if not (d.get(F.DRESSING_FOOD_KEY) is Dictionary):
		return
	var food: Dictionary = d[F.DRESSING_FOOD_KEY]
	assert_true(int(food.get("seed", -1)) >= 0, "food.seed")
	assert_true((food.get("rules", []) as Array).size() >= 3, "host rules for shallows eggs, coral rings and snails exist")
	var edible: Dictionary = food.get("edible_decor", {})
	for piece: String in F.DECOR_PIECES.keys():
		assert_eq(str(edible.get(piece, "")), F.DECOR_PIECES[piece], "edible_decor maps %s" % piece)
	assert_true((food.get("authored", []) as Array).size() >= 7, "authored pearl anchors for 4 arches + cave + 2 stone arches (Q3)")
	var recs: Dictionary = F.food_records()
	var index: Dictionary = MapDressing.piece_index()
	for r_v: Variant in food.get("rules", []):
		var r: Dictionary = r_v
		assert_true(recs.has(str(r.get("food"))), "rule %s: food type %s exists" % [r.get("id"), r.get("food")])
		if r.has("piece"):
			assert_true(index.has(str(r["piece"])), "rule %s: piece %s exists" % [r.get("id"), r.get("piece")])
			assert_has(F.record_pieces(recs.get(str(r.get("food")), {})), str(r["piece"]), "rule %s: the piece is listed by its food type" % r.get("id"))
		else:
			for pid: String in F.record_pieces(recs.get(str(r.get("food")), {})):
				assert_true(index.has(pid), "rule %s: the type's piece %s exists (chosen by zone / depth)" % [r.get("id"), pid])
		assert_true(float(r.get("chance", -1.0)) >= 0.0 and float(r.get("chance", 2.0)) <= 1.0, "rule %s: chance in 0..1" % r.get("id"))
		for h: Variant in r.get("hosts", []):
			assert_true(index.has(str(h)), "rule %s: host %s is a known piece" % [r.get("id"), h])


func test_bad_dressing_food_blocks_are_rejected() -> void:
	if not F.content_ready(self):
		return
	var cases: Array[Dictionary] = [
		{"name": "unknown host piece", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["hosts"] = ["no_such_piece"]},
		{"name": "unknown food type", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["food"] = "no_such_food"},
		{"name": "unknown egg piece", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["piece"] = "no_such_piece"},
		{"name": "chance above 1", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["chance"] = 1.5},
		{"name": "negative chance", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["chance"] = -0.1},
		{"name": "anchor not in the enum", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["anchor"] = "sideways"},
		{"name": "variants 4", "edit": func(food: Dictionary) -> void: (food["rules"][0] as Dictionary)["variants"] = 4},
		{"name": "edible_decor with an unknown type", "edit": func(food: Dictionary) -> void: (food["edible_decor"] as Dictionary)["a14_starfish"] = "no_such_food"}]
	for c: Dictionary in cases:
		var edit: Callable = c["edit"]
		var db: ContentDB = _dressing_with(func(d: Dictionary) -> void:
			if d.get(F.DRESSING_FOOD_KEY) is Dictionary:
				edit.call(d[F.DRESSING_FOOD_KEY]))
		assert_false(db.is_valid(), "%s -> invalid content" % c["name"])


# ======================================================================= map krill blocks and zones

func test_the_shipped_map_has_three_disjoint_krill_blocks_with_their_own_zones() -> void:
	var map: Dictionary = S5.content().get_map(F.MAP_ID)
	var blocks: Variant = map.get(F.MAP_KRILL_KEY)
	if not F.require(self, PackedStringArray([] if blocks is Array else ["map.%s (Array of plankton-shaped blocks)" % F.MAP_KRILL_KEY])):
		return
	var list: Array = blocks
	assert_eq(list.size(), 3, "three krill blocks: shallows, open water, abyss")
	var species: Array[String] = []
	var seen_zones: Array[String] = []
	var grid: float = _grid_m(S5.content())
	for b_v: Variant in list:
		var b: Dictionary = b_v
		species.append(str(b.get("species_id")))
		assert_true(S5.content().get_species(StringName(str(b.get("species_id")))).size() > 0, "species %s exists" % b.get("species_id"))
		assert_true(float(b.get("cell_m", 0.0)) > 0.0 and is_zero_approx(fmod(grid, float(b["cell_m"]))), "cell_m %s divides the %s m sim grid" % [b.get("cell_m"), grid])
		for z: Variant in b.get("zones", []):
			assert_false(seen_zones.has(str(z)), "zone %s belongs to ONE krill block (two palettes in a cell are impossible)" % z)
			seen_zones.append(str(z))
			assert_true(F.box_of(map, str(z)).size() == 2, "zone %s exists in map.zones" % z)
		var v: Variant = b.get("variation")
		assert_true(v is Dictionary and float((v as Dictionary).get("empty_frac", 0.0)) >= 0.5, "%s: patchy (variation.empty_frac >= 0.5) so krill reads as clouds, not haze" % b.get("species_id"))
	for want: StringName in F.KRILL_SPECIES:
		assert_has(species, str(want), "block for %s" % want)
	for i in seen_zones.size():
		for j in range(i + 1, seen_zones.size()):
			assert_false(F.boxes_overlap(F.box_of(map, seen_zones[i]), F.box_of(map, seen_zones[j])), "krill zones %s / %s do not overlap" % [seen_zones[i], seen_zones[j]])


func _grid_m(db: ContentDB) -> float:
	return float(db.rules().get("grid_cell_m", 8.0))


func test_krill_species_are_ambient_tiny_and_never_spawned() -> void:
	var db: ContentDB = S5.content()
	if not F.require(self, PackedStringArray([] if db.get_species(&"krill_open").size() > 0 else ["data/species/krill_*.json"])):
		return
	var map: Dictionary = db.get_map(F.MAP_ID)
	for id: StringName in F.KRILL_SPECIES:
		var sp: Dictionary = db.get_species(id)
		assert_false(sp.is_empty(), "species %s exists" % id)
		assert_eq(str(sp.get("tier")), "ambient", "%s: ambient tier (NpcSpawner excludes it, _count_tier ignores it)" % id)
		var lm: Dictionary = sp.get("length_m", {})
		assert_true(float(lm.get("min", 1.0)) <= 0.03 and float(lm.get("min", 0.0)) >= 0.005, "%s: tiny length_m (the XP falloff reference)" % id)
		for rec_key: String in ["spawners", "schools"]:
			for r: Variant in map.get(rec_key, []):
				assert_ne(str((r as Dictionary).get("species_id")), str(id), "%s is not in map.%s" % [id, rec_key])


func test_bad_krill_blocks_are_rejected() -> void:
	if not F.require(self, PackedStringArray([] if S5.content().get_map(F.MAP_ID).get(F.MAP_KRILL_KEY) is Array else ["map.krill validation"])):
		return
	var cases: Array[Dictionary] = [
		{"name": "unknown species", "edit": func(b: Array) -> void: (b[0] as Dictionary)["species_id"] = "no_such_species"},
		{"name": "cell_m does not divide the 8 m grid", "edit": func(b: Array) -> void: (b[0] as Dictionary)["cell_m"] = 3.0},
		{"name": "unknown zone", "edit": func(b: Array) -> void: (b[0] as Dictionary)["zones"] = ["no_such_zone"]},
		{"name": "two blocks share a zone", "edit": func(b: Array) -> void: (b[1] as Dictionary)["zones"] = (b[0] as Dictionary)["zones"]},
		{"name": "negative density", "edit": func(b: Array) -> void: (b[0] as Dictionary)["density_max"] = -1.0}]
	for c: Dictionary in cases:
		var edit: Callable = c["edit"]
		var db: ContentDB = F.db_with(func(root: String) -> void:
			var path: String = root.path_join("maps/reef.json")
			var m: Dictionary = F.read_json(path)
			if m.get(F.MAP_KRILL_KEY) is Array:
				edit.call(m[F.MAP_KRILL_KEY])
			F.write_json(path, m))
		assert_false(db.is_valid(), "%s -> invalid content" % c["name"])


# ======================================================================= Blender-side contract (specs on disk)

func test_egg_and_snail_specs_follow_the_row_contract() -> void:
	var root: String = S5.repo_root().path_join("tools/blender/env/pieces")
	var missing := PackedStringArray()
	for piece: String in F.PIECE_ROWS.keys():
		if not FileAccess.file_exists(root.path_join(piece + ".json")):
			missing.append(piece + ".json")
	if not F.require(self, missing):
		return
	for piece2: String in F.PIECE_ROWS.keys():
		var spec: Dictionary = F.read_json(root.path_join(piece2 + ".json"))
		var want: Array = F.PIECE_ROWS[piece2]
		assert_eq(int(spec.get("palette_row", -1)), int(want[0]), "%s: palette_row" % piece2)
		assert_eq(bool(spec.get("glow", false)), bool(want[1]), "%s: glow flag (only rows 37 / 38 glow)" % piece2)
		assert_eq(str(spec.get("size_class", "")), "env_small", "%s: env_small" % piece2)
		assert_false(bool(spec.get("sway", false)), "%s: static (sway false)" % piece2)
		assert_true(int(spec.get("variants", 1)) >= 1 and int(spec.get("variants", 1)) <= 3, "%s: 1-3 variants" % piece2)


func test_pieces_sharing_a_palette_row_carry_identical_palettes() -> void:
	var root: String = S5.repo_root().path_join("tools/blender/env/pieces")
	var missing := PackedStringArray()
	for piece: String in F.PIECE_ROWS.keys():
		if not FileAccess.file_exists(root.path_join(piece + ".json")):
			missing.append(piece + ".json")
	if not F.require(self, missing):
		return
	var by_row: Dictionary = {}
	for piece2: String in F.PIECE_ROWS.keys():
		var spec: Dictionary = F.read_json(root.path_join(piece2 + ".json"))
		var row: int = int(spec.get("palette_row", -1))
		var pal: String = JSON.stringify(spec.get("palette", {}), "", true)
		if by_row.has(row):
			assert_eq(pal, by_row[row]["pal"], "row %d: %s and %s share an IDENTICAL palette (env rule)" % [row, piece2, by_row[row]["piece"]])
		else:
			by_row[row] = {"piece": piece2, "pal": pal}


func test_krill_specs_exist_for_each_krill_species() -> void:
	var root: String = S5.repo_root().path_join("tools/blender/species")
	var missing := PackedStringArray()
	for id: StringName in F.KRILL_SPECIES:
		if not FileAccess.file_exists(root.path_join("%s.json" % id)):
			missing.append("species/%s.json" % id)
	if not F.require(self, missing):
		return
	for id2: StringName in F.KRILL_SPECIES:
		var spec: Dictionary = F.read_json(root.path_join("%s.json" % id2))
		assert_eq(str(spec.get("archetype", "swarm")), "swarm", "%s: swarm archetype" % id2)
		assert_eq(str(spec.get("size_class", "plankton")), "plankton", "%s: plankton size class (<= 150 tris)" % id2)
		assert_true(S5.content().get_species(id2).size() > 0, "%s: data record paired with the spec (build_all_species roster check)" % id2)


# ======================================================================= provenance (merge point)

func test_the_manifest_lists_every_new_glb_and_audio_group() -> void:
	var text: String = FileAccess.get_file_as_string("res://assets/manifest.yaml")
	var missing := PackedStringArray()
	for piece: String in F.PIECE_ROWS.keys():
		if not FileAccess.file_exists("res://assets/models/env/env_%s_v1_lod0.glb" % piece):
			missing.append("env_%s_v1_lod0.glb (built by the orchestrator at the merge point)" % piece)
	if not F.require(self, missing):
		return
	for piece2: String in F.PIECE_ROWS.keys():
		assert_true(text.contains("env_%s_v1_lod0.glb" % piece2), "manifest.yaml has an entry for %s (own_script, ai_disclosure: false)" % piece2)
	for id: StringName in F.KRILL_SPECIES:
		assert_true(FileAccess.file_exists("res://assets/models/species/sp_swarm_%s_s1_lod0.glb" % id), "krill GLB for %s" % id)
		assert_true(text.contains("sp_swarm_%s_s1_lod0.glb" % id), "manifest.yaml has an entry for the %s GLB" % id)
