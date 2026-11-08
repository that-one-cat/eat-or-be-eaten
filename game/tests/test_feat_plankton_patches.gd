extends TestCase
## feat-plankton-visibility: patchy plankton and its eating feedback.
## (1) PlanktonField with the optional map.plankton.variation block: per-column caps (cell_cap), deterministic from the
## data alone, the rank mapping gives the configured shares and mean for any seed, patches are spatially coherent,
## maps without the block stay uniform, regrowth is exact against a per-cell cap and independent of pruning.
## (2) ContentDB validation of the variation keys. (3) FeedbackFx.PlanktonTally / plankton_xp_text (pure throttle
## and aggregation logic of the grazing pop-up).

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")
const MAP_SOURCE: String = "maps/reef.json"
## density_max of the uniform S4 field this feature replaced: the B1 growth balance was tuned against its mean.
const UNIFORM_BASELINE_MEAN: float = 1.0


func _map() -> Dictionary:
	return S3.content().get_map(S3.MAP_ID).duplicate(true)


func _field(map: Dictionary) -> PlanktonField:
	return PlanktonField.create(S3.content(), map)


func _variation(map: Dictionary) -> Dictionary:
	return (map["plankton"] as Dictionary)["variation"]


## Caps of every plankton cell in index order.
func _caps(f: PlanktonField) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for c in f.cell_count():
		if f.is_plankton_cell(c):
			out.append(f.cell_cap(c))
	return out


func _mentions(errs: PackedStringArray, a: String, b: String = "") -> bool:
	for e: String in errs:
		if e.find(a) != -1 and (b.is_empty() or e.find(b) != -1):
			return true
	return false


# ======================================================== the field: shares, mean, determinism

func test_the_shipped_field_has_the_configured_shares_and_keeps_the_uniform_mean() -> void:
	var map: Dictionary = _map()
	if not (map.get("plankton") is Dictionary) or not (map["plankton"].get("variation") is Dictionary):
		fail("setup: the shipped reef has no plankton.variation block")
		return
	var f: PlanktonField = _field(map)
	var v: Dictionary = _variation(map)
	var caps: PackedFloat64Array = _caps(f)
	assert_true(caps.size() > 1000, "setup: the reef has plankton cells (%d)" % caps.size())
	var empty: int = 0
	var full: int = 0
	var sum: float = 0.0
	var lowest_live: float = INF
	for cap in caps:
		sum += cap
		if cap == 0.0:
			empty += 1
		else:
			lowest_live = minf(lowest_live, cap)
		if cap == f.density_max:
			full += 1
	var n: float = float(caps.size())
	# columns weigh as many cells as they hold, so the shares are exact only up to one column
	assert_almost_eq(float(empty) / n, float(v["empty_frac"]), 0.01, "share of empty cells = empty_frac")
	assert_almost_eq(float(full) / n, float(v["rich_frac"]), 0.01, "share of full (rich) cells = rich_frac")
	var mean_m: float = float(v["rich_frac"]) + (1.0 - float(v["empty_frac"]) - float(v["rich_frac"])) * (1.0 + float(v["min_mult"])) * 0.5
	assert_almost_eq(sum / n / f.density_max, mean_m, 0.01 * mean_m, "mean multiplier = rich + band x (1 + min_mult) / 2 (any seed)")
	assert_almost_eq(sum / n, UNIFORM_BASELINE_MEAN, 0.1 * UNIFORM_BASELINE_MEAN, "mean cap within 10%% of the uniform field's %.2f" % UNIFORM_BASELINE_MEAN)
	# every cell that holds plankton can be eaten and drawn: caps above min_eat_density and the swarm threshold
	assert_true(lowest_live >= f.min_eat_density, "poorest non-empty cap %.3f is edible (min_eat_density %.3f)" % [lowest_live, f.min_eat_density])
	assert_true(lowest_live > AmbientRenderer.SWARM_THRESHOLD * f.density_max, "poorest non-empty cap %.3f is drawn (swarm threshold %.3f)" % [lowest_live, AmbientRenderer.SWARM_THRESHOLD * f.density_max])
	assert_true(lowest_live >= float(v["min_mult"]) * f.density_max - 1e-9, "no non-empty cap below min_mult x density_max")


func test_the_field_depends_on_the_map_data_only() -> void:
	var map: Dictionary = _map()
	var a: PackedFloat64Array = _caps(_field(map))
	assert_true(a == _caps(_field(map)), "same data -> same caps")
	var w1 := SimWorld.new(1, S3.content())
	var w2 := SimWorld.new(987654, S3.content())
	assert_true(a == _caps(w1.plankton) and a == _caps(w2.plankton), "the world seed does not change the field")
	_variation(map)["seed"] = int(_variation(map)["seed"]) + 1
	var b: PackedFloat64Array = _caps(_field(map))
	var differing: int = 0
	for i in a.size():
		if a[i] != b[i]:
			differing += 1
	assert_true(differing > a.size() / 10, "another variation seed gives another layout (%d of %d cells differ)" % [differing, a.size()])


func test_patches_are_spatially_coherent_not_per_cell_noise() -> void:
	var f: PlanktonField = _field(_map())
	var cm: float = f.cell_m
	var layer: Dictionary = {}  # (ix, iz) of the top plankton layer -> cap / density_max
	for c in f.cell_count():
		var p: Vector3 = f.cell_center(c)
		if absf(p.y + 0.5 * cm) < 0.01 and f.is_plankton_cell(c):
			layer[Vector2i(floori(p.x / cm), floori(p.z / cm))] = f.cell_cap(c) / f.density_max
	assert_true(layer.size() > 500, "setup: the top layer holds plankton (%d cells)" % layer.size())
	var near: float = _mean_abs_diff(layer, 1)
	var far: float = _mean_abs_diff(layer, 9)  # 72 m, beyond twice the 40 m patch size
	# white noise would give near ~ far; value noise with 40 m patches differs ~5x less between 8 m neighbours
	assert_true(near < 0.5 * far, "neighbouring cells (8 m) differ %.3f vs %.3f at 72 m" % [near, far])


func _mean_abs_diff(layer: Dictionary, lag: int) -> float:
	var total: float = 0.0
	var pairs: int = 0
	for k: Vector2i in layer:
		var k2 := Vector2i(k.x, k.y + lag)
		if layer.has(k2):
			total += absf(float(layer[k]) - float(layer[k2]))
			pairs += 1
	return total / float(maxi(pairs, 1))


func test_without_a_variation_block_every_plankton_cell_is_full_density_max() -> void:
	var map: Dictionary = _map()
	var plain: Dictionary = map["plankton"]
	plain.erase("variation")
	var f: PlanktonField = _field(map)
	var plankton_cells: int = 0
	for c in f.cell_count():
		if f.is_plankton_cell(c):
			plankton_cells += 1
			assert_eq(f.cell_cap(c), f.density_max, "uniform cap")
			assert_eq(f.density(c, 12345), f.density_max, "a fresh cell is full")
		else:
			assert_eq(f.cell_cap(c), 0.0, "no cap outside the zones")
	assert_true(plankton_cells > 1000, "setup: plankton cells exist")
	# rich_frac 1 is the same uniform field
	var map2: Dictionary = _map()
	var v: Dictionary = _variation(map2)
	v["empty_frac"] = 0.0
	v["rich_frac"] = 1.0
	var g: PlanktonField = _field(map2)
	for c in g.cell_count():
		if g.is_plankton_cell(c):
			assert_eq(g.cell_cap(c), g.density_max, "rich_frac 1 -> every cell full")


# ======================================================== regrowth against a per-cell cap

func test_regrowth_is_exact_per_cell_cap_and_pruning_does_not_change_the_state() -> void:
	var f: PlanktonField = _field(_map())
	var rich: int = -1
	var poor: int = -1
	var empty: int = -1
	for c in f.cell_count():
		if not f.is_plankton_cell(c):
			continue
		var cap: float = f.cell_cap(c)
		if rich < 0 and cap == f.density_max:
			rich = c
		elif poor < 0 and cap > 0.0 and cap < 0.5 * f.density_max:
			poor = c
		elif empty < 0 and cap == 0.0:
			empty = c
	if rich < 0 or poor < 0 or empty < 0:
		fail("setup: the shipped field needs a rich, a poor and an empty cell (%d %d %d)" % [rich, poor, empty])
		return
	var start: int = 100
	f.now_tick = start
	var last: Dictionary = {}  # cell -> tick of its last successful eat
	var after: Dictionary = {}  # cell -> density just after it
	for i in 60:
		var t: int = start + i
		for c in [rich, poor]:
			if f.eat(c, t) > 0.0:
				last[c] = t
				after[c] = f.density(c, t)
	assert_true(last.has(rich) and last.has(poor), "setup: both cells were eaten down")
	assert_true(f.eat(empty, start) == 0.0 and f.density(empty, start + 5000) == 0.0 and not f.touched_cells().has(empty), "an empty cell holds nothing and cannot be eaten")
	# exact regrowth: min(density after + rate x ticks, cap), the rate is absolute for both caps
	for c in [rich, poor]:
		var cap: float = f.cell_cap(c)
		for dt in [0, 1, 7, 100, 700, 2000, 5000]:
			var t: int = int(last[c]) + dt
			var want: float = minf(float(after[c]) + f.regrow_per_tick * float(dt), cap)
			assert_almost_eq(f.density(c, t), want, 1e-12, "cell cap %.3f: density %d ticks after the last eat" % [cap, dt])
	var poor_full: int = int(last[poor]) + ceili((f.cell_cap(poor) - float(after[poor])) / f.regrow_per_tick) + 2
	var rich_full: int = int(last[rich]) + ceili((f.cell_cap(rich) - float(after[rich])) / f.regrow_per_tick) + 2
	assert_true(poor_full < rich_full, "the poor cell refills first (absolute rate): tick %d vs %d" % [poor_full, rich_full])
	assert_eq(f.density(poor, poor_full), f.cell_cap(poor), "the poor cell is exactly at its cap")
	assert_true(f.density(rich, poor_full) < f.cell_cap(rich), "while the rich one is still regrowing")
	# state_hash input is the same before and after pruning, and pruning forgets exactly the refilled cell
	var before := StreamPeerBuffer.new()
	f.write_state(before, poor_full)
	assert_eq(f.touched_cells().size(), 2, "both cells are tracked before the prune")
	f.prune(poor_full)
	var pruned := StreamPeerBuffer.new()
	f.write_state(pruned, poor_full)
	assert_eq(f.touched_cells().size(), 1, "the refilled poor cell is forgotten")
	assert_true(before.data_array == pruned.data_array, "write_state is identical before and after the prune")
	f.prune(rich_full)
	assert_eq(f.touched_cells().size(), 0, "and the rich one once it is full")
	assert_eq(f.density(rich, rich_full), f.cell_cap(rich), "pruned cells read as exactly their cap")


func test_grazing_and_regrowth_stay_inside_the_cap_for_other_variation_seeds() -> void:
	var zones: Array = (S3.content().get_map(S3.MAP_ID).get("plankton", {}) as Dictionary).get("zones", [])
	for vs in [1, 2, 3, 6]:
		var hashes: Array[int] = []
		for rep in 2:
			var w: SimWorld = S4.make_world(5, {"plankton_zones": zones, "variation_seed": vs})
			var probe: Vector3 = S4.plankton_probe(w)
			if not probe.is_finite():
				fail("setup: variation seed %d has no probe cell" % vs)
				return
			var cap: float = S4.cell_cap(w, probe)
			var e: SimEntity = S3.player_at(w, probe, 0.0)
			var highest: float = 0.0
			var lowest: float = INF
			for i in 120:
				S4.pin(w, e.id, probe)
				w.step()
				var d: float = S4.density_at(w, probe)
				highest = maxf(highest, d)
				lowest = minf(lowest, d)
			assert_true(highest <= cap + 1e-12 and lowest >= 0.0, "seed %d: density stays in [0, cap %.3f] while grazing (%.4f..%.4f)" % [vs, cap, lowest, highest])
			assert_true(lowest < cap, "seed %d: the cell was really eaten" % vs)
			w.remove_entity(e.id)
			var rate: float = float(S4.plankton_cfg(w)["regrow_per_s"]) * SimWorld.TICK_DT
			var budget: int = ceili(cap / rate) + 60
			var full_at: int = -1
			for i in budget:
				w.step()
				var d2: float = S4.density_at(w, probe)
				assert_true(d2 <= cap + 1e-12, "seed %d: regrowth never above the cap" % vs)
				if d2 >= cap:
					full_at = i
					break
			assert_true(full_at >= 0, "seed %d: the cell (cap %.3f) is full again within %d ticks" % [vs, cap, budget])
			S4.run(w, 60)
			hashes.append(w.state_hash())
		assert_eq(hashes[0], hashes[1], "seed %d: identical runs, identical state_hash" % vs)


# ======================================================== ContentDB validation of map.plankton.variation

func _variation_case(key: String, value: Variant, erase: bool = false) -> PackedStringArray:
	var rec: Dictionary = _map()
	if erase:
		_variation(rec).erase(key)
	else:
		_variation(rec)[key] = value
	return ContentDB.validate_record(&"map", rec, MAP_SOURCE)


func test_the_shipped_variation_block_is_valid_and_bad_ones_are_rejected() -> void:
	assert_eq(ContentDB.validate_record(&"map", _map(), MAP_SOURCE).size(), 0, "maps/reef.json (with variation) passes its schema")
	for bad: Variant in [-1, 1.5, "x"]:
		assert_true(_mentions(_variation_case("seed", bad), "plankton.variation.seed"), "seed %s must be rejected" % [bad])
	for bad2: Variant in [0, -40, "x", 4]:  # 4 < cell_m 8
		assert_true(_mentions(_variation_case("patch_m", bad2), "plankton.variation.patch_m"), "patch_m %s must be rejected" % [bad2])
	for key in ["empty_frac", "rich_frac", "min_mult"]:
		for bad3: Variant in [-0.1, 1.5, "x"]:
			assert_true(_mentions(_variation_case(key, bad3), "plankton.variation.%s" % key), "%s %s must be rejected" % [key, bad3])
	for key in ["seed", "patch_m", "empty_frac", "rich_frac", "min_mult"]:
		assert_true(_mentions(_variation_case(key, null, true), "plankton.variation.%s" % key), "a missing %s must be rejected" % key)
	var rec: Dictionary = _map()
	_variation(rec)["empty_frac"] = 0.6
	_variation(rec)["rich_frac"] = 0.6
	assert_true(_mentions(ContentDB.validate_record(&"map", rec, MAP_SOURCE), "plankton.variation", "empty_frac + rich_frac"), "empty_frac + rich_frac > 1 must be rejected")
	var rec2: Dictionary = _map()
	(rec2["plankton"] as Dictionary)["variation"] = 3
	assert_true(_mentions(ContentDB.validate_record(&"map", rec2, MAP_SOURCE), "plankton.variation"), "variation must be an object")
	var rec3: Dictionary = _map()
	(rec3["plankton"] as Dictionary).erase("variation")
	assert_eq(ContentDB.validate_record(&"map", rec3, MAP_SOURCE).size(), 0, "the block is optional")


# ======================================================== grazing feedback: pure throttle and text

func test_the_plankton_tally_waits_for_its_window_then_pays_the_sum_once() -> void:
	var t := FeedbackFx.PlanktonTally.new(12)
	assert_eq(t.take(50), 0.0, "nothing pending, nothing to show")
	t.add(0.03, 100)
	t.add(0.02, 105)
	for tick in range(100, 112):
		assert_eq(t.take(tick), 0.0, "window of 12 ticks still open at tick %d" % tick)
	assert_almost_eq(t.take(112), 0.05, 1e-12, "the window pays the whole sum once it is 12 ticks old")
	assert_eq(t.take(113), 0.0, "and is empty afterwards")
	t.add(0.0, 200)
	assert_eq(t.take(300), 0.0, "zero XP never opens a window")


func test_a_steady_grazer_gets_throttled_pop_ups_that_add_up_to_everything_eaten() -> void:
	var t := FeedbackFx.PlanktonTally.new(12)
	var paid: float = 0.0
	var pops: Array[int] = []
	var added: float = 0.0
	for tick in 300:  # one PLANKTON_EATEN per tick, as while sitting in a cell with plenty left
		t.add(0.03, tick)
		added += 0.03
		var xp: float = t.take(tick)
		if xp > 0.0:
			paid += xp
			pops.append(tick)
	assert_true(pops.size() >= 20 and pops.size() <= 25, "about one pop-up per 0.43 s over 10 s (%d)" % pops.size())
	for i in range(1, pops.size()):
		assert_true(pops[i] - pops[i - 1] >= 12, "pop-ups at least 12 ticks (0.4 s) apart")
	assert_almost_eq(paid + t.pending, added, 1e-9, "nothing is lost or counted twice")
	for tick in range(300, 320):  # grazing stops: the remainder still comes out
		var xp2: float = t.take(tick)
		if xp2 > 0.0:
			paid += xp2
	assert_almost_eq(paid, added, 1e-9, "the tail is paid after grazing stops")


func test_plankton_xp_text() -> void:
	assert_eq(FeedbackFx.plankton_xp_text(0.4), "+0.4 XP", "one decimal below 10")
	assert_eq(FeedbackFx.plankton_xp_text(9.94), "+9.9 XP", "still one decimal")
	assert_eq(FeedbackFx.plankton_xp_text(9.96), "+10 XP", "whole numbers from 9.95")
	assert_eq(FeedbackFx.plankton_xp_text(123.4), "+123 XP", "whole numbers above")
