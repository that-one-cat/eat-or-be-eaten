extends TestCase
## Presentation logic of the food feature that can be checked headless and node-free (research 5, 7.5 item 5):
## TargetBarTracker keys for sites (their own key space, pruned when the site dies / is out of range), MapDressing keeps
## food pieces in the low tier (no thinning of edible decor) and exposes the hide / show path for a site, the tutorial
## hints react to the new events, the new SFX groups exist on disk and in AudioDirector.GROUPS, and FoodSiteView reads
## events by cursor. Colour, silhouette, glow and draw calls are capture-only (see the test plan).
## Everything that depends on unfrozen names reports PENDING until adapted in food_support.gd (FOOD_STRICT=1 fails it).

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S5 := preload("res://tests/s5_support.gd")

## MapDressing hide / show API (research 5.1: MapDressing.set_site_visible(site, bool)); the getter is NOT frozen. ADAPT.
const DRESSING_SET_VISIBLE: String = "set_site_visible"
const DRESSING_GET_VISIBLE: String = "is_site_visible"

var _nodes: Array[Node] = []


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


# ======================================================================= target bars

func test_site_bars_use_their_own_key_space_and_are_pruned_with_the_site() -> void:
	if not F.require(self, PackedStringArray([] if F.has_tracker_key() else ["TargetBarTracker.%s" % F.TRACKER_KEY_CONST])):
		return
	# default HP: the second half of the test kills this starfish with held bites (nothing bites it in the first half)
	var sc: Dictionary = F.scene(self, F.T_STARFISH)
	if sc.is_empty():
		return
	var w: SimWorld = sc["w"]
	var id: int = sc["id"]
	var key: int = F.tracker_key(id)
	assert_ne(key, id, "a site key is never a plain entity id")
	assert_true(F.key_is_outside_entity_ids(key), "site keys live outside the entity id range (negative space or above any id the sim hands out): %d" % key)
	var t := TargetBarTracker.new()
	t.note_hit(sc["pid"], 0)   # an entity bar with a small id
	t.note_hit(key, 0)
	assert_eq(t.ids.size(), 2, "an entity bar and a site bar coexist (no collision when ids are equal numbers)")
	t.prune(w, sc["site"]["pos"], 60.0, 0.0)
	assert_true(t.ids.has(key), "a living site in range keeps its bar (prune asks the food state, not get_entity)")
	t.prune(w, sc["site"]["pos"] + Vector3(500.0, 0.0, 0.0), 60.0, 0.0)
	assert_false(t.ids.has(key), "a site out of range loses its bar")
	var t2 := TargetBarTracker.new()
	t2.note_hit(key, 0)
	# kill the site, then prune: the bar goes
	var p: SimEntity = sc["player"]
	for i in 40:
		w.submit(SimCommand.bite(p.id, -1))
		F.run(w, F.cooldown_ticks(w.content) + 1, {p.id: sc["pos"]})
		if not F.site_alive(w, id):
			break
	assert_false(F.site_alive(w, id), "setup: the site was killed")
	t2.prune(w, sc["site"]["pos"], 60.0, 0.0)
	assert_false(t2.ids.has(key), "a dead site loses its bar")


func test_bar_capacity_and_replacement_still_hold_with_site_keys() -> void:
	if not F.require(self, PackedStringArray([] if F.has_tracker_key() else ["TargetBarTracker.%s" % F.TRACKER_KEY_CONST])):
		return
	var t := TargetBarTracker.new()
	for k in TargetBarTracker.CAP + 3:
		t.note_hit(F.tracker_key(k), k)
	assert_eq(t.ids.size(), TargetBarTracker.CAP, "site bars respect the pool cap")
	assert_false(t.ids.has(F.tracker_key(0)), "the oldest hit was replaced")


# ======================================================================= dressing

func test_food_pieces_are_not_thinned_in_the_low_tier_and_sites_can_be_hidden() -> void:
	if not F.require(self, PackedStringArray([] if F.script_has(F.script_at("res://scripts/world/map_dressing.gd"), DRESSING_SET_VISIBLE) else ["MapDressing.%s" % DRESSING_SET_VISIBLE])):
		return
	var db: ContentDB = S5.content()
	var map: Dictionary = db.get_map(F.MAP_ID).duplicate(true)
	var dressing: Dictionary = db.get_dressing(F.MAP_ID).duplicate(true)
	var seabed: SeabedField = SeabedField.from_map(map, db.get_proxies(F.MAP_ID))
	# merged design: the renderer draws the BAKED site records (build's food_sites argument), not compute_placements
	var baked: Array = db.get_food_sites(F.MAP_ID)
	assert_true(baked.size() > 0, "there are baked food sites to draw")
	var md := MapDressing.new()
	_nodes.append(md)
	var list: Array = md.build(dressing, map, seabed, QualitySettings.LOW, baked)
	var edible: Array[String] = []
	edible.append_array(F.DECOR_PIECES.keys())
	edible.append(F.SNAIL_ORANGE_PIECE)
	edible.append_array(F.EGG_PIECES_A)
	for piece: String in edible:
		var placed: int = 0
		for p_v: Variant in list:
			var p: Dictionary = p_v
			if str(p.get("piece", "")) == piece and str(p.get("kind", "")) == "scatter" and F.DECOR_PIECES.has(piece):
				placed += 1   # edible decor: every scatter placement is a site and is drawn
		for s_v: Variant in baked:
			var s: Dictionary = s_v
			if str(s.get("piece", "")) == piece and int(s.get("decor", -1)) < 0:
				placed += 1   # own food pieces (eggs, snails) come from the baked records
		var drawn: int = 0
		for c: Node in md.get_children():
			if c is MultiMeshInstance3D and str(c.name).contains(piece):
				drawn += (c as MultiMeshInstance3D).multimesh.instance_count
		if placed == 0 or ResourceLoader.exists("res://assets/models/env/env_%s_v1_lod0.glb" % piece) == false:
			continue   # model not built yet / piece not placed: nothing to compare
		assert_eq(drawn, placed, "%s: every placement is drawn in the low tier (the sim is tier-agnostic: a thinned edible would be invisible food)" % piece)
	assert_eq(int(md.bench_stats().get("dressing_food_sites", -1)), baked.size(), "every baked site has a drawn instance in the low tier")
	# hide / show round trip (single-instance writes, event rate). The instance transform itself cannot be read back
	# headless (the dummy RenderingServer returns identity from MultiMesh.get_instance_transform), so the drawn slot and
	# the visibility state are asserted; the zero-scale write is capture-only.
	var slot: Dictionary = md.site_slot(0)
	assert_false(slot.is_empty(), "site 0 is drawn (has a MultiMesh slot)")
	assert_true(bool(md.call(DRESSING_GET_VISIBLE, 0)), "site 0 starts visible")
	md.call(DRESSING_SET_VISIBLE, 0, false)
	assert_false(bool(md.call(DRESSING_GET_VISIBLE, 0)), "site 0 hidden")
	md.call(DRESSING_SET_VISIBLE, 0, true)
	assert_true(bool(md.call(DRESSING_GET_VISIBLE, 0)), "site 0 visible again")


# ======================================================================= tutorial, audio

func test_tutorial_hints_count_sites_as_eating_and_biting() -> void:
	var src: String = FileAccess.get_file_as_string(F.TUTORIAL_SCRIPT)
	if not F.require(self, PackedStringArray([] if src.contains("SITE_EATEN") else ["TutorialHints handles SITE_EATEN / SITE_BITTEN"])):
		return
	# Weak by nature (the done flags are private to a Node): a source scan for the events plus the wording.
	assert_true(src.contains("SITE_BITTEN"), "SITE_BITTEN marks the 'bite' hint done")
	var script: GDScript = F.script_at(F.TUTORIAL_SCRIPT)
	var hints: Array = F.script_const(script, "HINTS")
	var eat: String = ""
	var bite: String = ""
	for h_v: Variant in hints:
		var h: Dictionary = h_v
		if str(h["id"]) == "eat":
			eat = str(h["text"]).to_lower()
		elif str(h["id"]) == "bite":
			bite = str(h["text"]).to_lower()
	assert_true(eat.contains("egg") or eat.contains("plankton"), "the eat hint names the new food kinds: '%s'" % eat)
	assert_true(bite.contains("shell") or bite.contains("starfish"), "the bite hint names hard prey: '%s'" % bite)


func test_new_sfx_groups_exist_on_disk_and_in_the_audio_director() -> void:
	var missing := PackedStringArray()
	for dir: String in F.SFX_DIRS:
		if DirAccess.open(dir) == null:
			missing.append(dir)
	if not F.require(self, missing):
		return
	for dir2: String in F.SFX_DIRS:
		var wavs: Array[String] = []
		for f: String in DirAccess.open(dir2).get_files():
			if f.get_extension() == "wav":
				wavs.append(f)
		assert_true(wavs.size() >= 2, "%s: at least 2 variants (%d)" % [dir2, wavs.size()])
		for wav: String in wavs:
			assert_true(FileAccess.file_exists(dir2.path_join(wav + ".import")), "%s has its committed .import" % wav)
		var group: StringName = StringName(dir2.get_file())
		var groups: Variant = F.script_const(F.script_at(F.AUDIO_SCRIPT), "GROUPS")
		assert_true(groups is Array and (groups as Array).has(group), "AudioDirector.GROUPS lists '%s'" % group)
	var recs: Dictionary = F.food_records()
	for id_v: Variant in recs.keys():
		var sfx: String = str((recs[id_v] as Dictionary).get("sfx", ""))
		if not sfx.is_empty():
			assert_true(DirAccess.dir_exists_absolute("res://assets/audio/sfx/%s" % sfx), "%s: sfx group '%s' has a folder" % [id_v, sfx])


# ======================================================================= view

func test_food_site_view_reads_events_by_cursor_without_repeating_on_a_paused_tick() -> void:
	if F.require_script(self, F.VIEW_SCRIPT) == null:
		return
	var probe: Dictionary = F.view_probe(self)
	if probe.is_empty():
		F.pending(self, "ADAPT food_support.view_probe(): build a FoodSiteView on a world, return {w, hide_calls: Array, step: Callable}")
		return
	for n: Node in (probe["nodes"] as Array):
		_nodes.append(n)
	var w: SimWorld = probe["w"]
	var calls: Array = probe["hide_calls"]
	var sc: Dictionary = probe["scene"]
	var step: Callable = probe["step"]
	step.call(12)   # the egg is swallowed
	var after_eat: int = calls.size()
	assert_eq(after_eat, 1, "one hide call for the eaten site")
	step.call(0)    # a paused world emits ticked with the SAME tick: the event must not be re-read
	step.call(0)
	assert_eq(calls.size(), after_eat, "no repeat on a paused tick (CONVENTIONS: Presentation time)")
	step.call(S3.ticks(float(sc["rec"]["respawn_s"])) + 5)
	assert_eq(calls.size(), after_eat + 1, "one show call on SITE_RESPAWNED")
	assert_true(w.tick > 0, "world advanced")
