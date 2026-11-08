extends TestCase
## S4 plankton field (contract "Plankton"): plankton are a density grid, not entities. A creature that can swallow
## plankton and has its mouth in a cell with density > 0 removes density and gets XP and hunger in proportion
## (PLANKTON_EATEN {cell, amount}); regrowth is deterministic, bounded by the cell's cap and refills an eaten cell;
## nothing happens outside the listed zones; the density is part of state_hash().
## Caps (feat-plankton-visibility): density_max is the RICH-cell density; a cell's own maximum is
## PlanktonField.cell_cap(cell) (S4.cell_cap(w, pos)), which is below density_max (or 0) in poor (empty) patches of the
## map's plankton.variation. Every bound below is therefore the probe cell's cap, never density_max, so the tests do
## not depend on which patch layout the shipped seed gives (test_feat_plankton_patches.gd sweeps other seeds).
## Pinned API (impl-A): PlanktonField.density_at(pos, tick = -1) -> float; PLANKTON_EATEN {entity = eater, value = XP
## gained, data {cell, amount, pos}}; only PLAYERS graze; a cell is eaten only while its density >= min_eat_density;
## XP = SimRules.xp_gain(amount x xp_per_unit, eater length, plankton length, rules.xp_falloff); hunger + amount x
## hunger_per_unit. Rates come from map.plankton in the data; nothing tuned is hard-coded.

const S3 := preload("res://tests/s3_support.gd")
const S4 := preload("res://tests/s4_support.gd")


func _world(world_seed: int = 71) -> SimWorld:
	var cfg_zones: Array = (S3.content().get_map(S3.MAP_ID).get("plankton", {}) as Dictionary).get("zones", [])
	return S4.make_world(world_seed, {"plankton_zones": cfg_zones})


## World + a B1 player (hunger at 40%, vitals off so only eating changes it) held at a plankton cell centre.
func _setup(world_seed: int = 71) -> Dictionary:
	var w: SimWorld = _world(world_seed)
	var probe: Vector3 = Vector3.INF
	var pid: int = -1
	if S4.plankton_problems(w).is_empty():
		probe = S4.plankton_probe(w)
	if probe.is_finite():
		var e: SimEntity = S3.player_at(w, probe, 0.0)
		e.hunger = 0.4 * S3.rule_f(w.content, "hunger_max")
		pid = e.id
	return {"w": w, "probe": probe, "pid": pid, "cap": S4.cell_cap(w, probe) if probe.is_finite() else 0.0}


func _pin(w: SimWorld, pid: int, pos: Vector3) -> Callable:
	return func(world: SimWorld) -> void:
		S4.pin(world, pid, pos)


func _sum_amount(evs: Array[SimEvent]) -> float:
	var total: float = 0.0
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		total += float(ev.data.get("amount", 0.0))
	return total


func _sum_value(evs: Array[SimEvent]) -> float:
	var total: float = 0.0
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		total += ev.value
	return total


## Centre of another plankton cell with a positive cap, a few cells from `probe` along z (Vector3.INF if none).
func _other_cell(w: SimWorld, probe: Vector3) -> Vector3:
	var step: float = float(S4.plankton_cfg(w)["cell_m"])
	for k in [2, -2, 3, -3, 4, -4]:
		var p: Vector3 = probe + Vector3(0.0, 0.0, float(k) * step)
		if S4.cell_cap(w, p) > 0.0:
			return p
	return Vector3.INF


func _usable(ctx: Dictionary) -> bool:
	var w: SimWorld = ctx["w"]
	if not S4.require_plankton(self, w):
		return false
	if not (ctx["probe"] as Vector3).is_finite():
		fail("setup: no plankton cell with density > 0 found in the listed zones (map.plankton.zones %s)" % [S4.plankton_cfg(w).get("zones")])
		return false
	return true


# ======================================================== not entities, only where listed

func test_plankton_are_not_entities() -> void:
	var w: SimWorld = S4.make_world(70, {"real": true})
	S4.run(w, 90)
	var plankton: int = 0
	for id: int in w.entity_ids():
		if w.get_entity(id).species_id == &"plankton":
			plankton += 1
	assert_eq(plankton, 0, "no plankton entity exists in the shipped world after 3 s")
	for rec_v: Variant in (w.map["spawners"] as Array):
		assert_ne(String((rec_v as Dictionary)["species_id"]), "plankton", "map.spawners has no plankton record any more (plankton is map.plankton)")
	assert_true(w.map.get("plankton") is Dictionary, "map.plankton exists")


func test_the_field_starts_with_plankton_inside_the_listed_zones_and_none_outside() -> void:
	var ctx: Dictionary = _setup()
	if not _usable(ctx):
		return
	var w: SimWorld = ctx["w"]
	var cfg: Dictionary = S4.plankton_cfg(w)
	var dmax: float = float(cfg["density_max"])
	var cap: float = ctx["cap"]
	var inside: float = S4.density_at(w, ctx["probe"])
	assert_true(cap > 0.0 and cap <= dmax + 1e-9, "the probe cell's cap %.3f is in (0, density_max %.3f]" % [cap, dmax])
	assert_almost_eq(inside, cap, 1e-9, "a fresh cell inside the zone starts at its cap")
	var abyss: Array[Vector3] = S3.zone_box(w, S4.ABYSS)
	var far: Vector3 = (abyss[0] + abyss[1]) * 0.5
	assert_false((cfg["zones"] as Array).has(S4.ABYSS), "setup: the abyss is not a plankton zone")
	assert_almost_eq(S4.density_at(w, far), 0.0, 1e-12, "no plankton outside the listed zones")


func test_nothing_to_eat_outside_the_plankton_zones() -> void:
	var w: SimWorld = _world(72)
	if not S4.require_plankton(self, w):
		return
	var abyss: Array[Vector3] = S3.zone_box(w, S4.ABYSS)
	var pos: Vector3 = (abyss[0] + abyss[1]) * 0.5
	var e: SimEntity = S3.player_at(w, pos, 0.0)
	var xp0: float = e.xp
	var evs: Array[SimEvent] = S4.run(w, 120, _pin(w, e.id, pos))
	assert_eq(S4.events_named(evs, "PLANKTON_EATEN").size(), 0, "no PLANKTON_EATEN in the abyss")
	assert_almost_eq(e.xp, xp0, 1e-12, "and no XP")


# ======================================================== eating

func test_eating_reduces_the_density_and_pays_xp_and_hunger_in_proportion() -> void:
	var ctx: Dictionary = _setup(73)
	if not _usable(ctx):
		return
	var w: SimWorld = ctx["w"]
	var e: SimEntity = w.get_entity(ctx["pid"])
	var pre: Callable = _pin(w, e.id, ctx["probe"])
	var cfg: Dictionary = S4.plankton_cfg(w)
	var regrow: float = float(cfg["regrow_per_s"])  # absolute density per second, whatever the cell's cap
	var d0: float = S4.density_at(w, ctx["probe"])
	var xp0: float = e.xp
	var h0: float = e.hunger
	var n: int = 15
	var evs: Array[SimEvent] = S4.run(w, n, pre)
	var eaten: float = _sum_amount(evs)
	var d1: float = S4.density_at(w, ctx["probe"])
	assert_true(eaten > 0.0, "the player in a plankton cell ate something (%.4f)" % eaten)
	assert_true(d1 < d0, "density fell from %.4f to %.4f" % [d0, d1])
	assert_true(absf((d0 - d1) - eaten) <= regrow * float(n) / 30.0 * 2.0 + 1e-6, "density lost %.4f matches the eaten amount %.4f (regrowth allowance only)" % [d0 - d1, eaten])
	var xp_gain: float = e.xp - xp0
	var hunger_gain: float = e.hunger - h0
	assert_true(xp_gain > 0.0, "XP was paid (%.4f)" % xp_gain)
	assert_true(hunger_gain > 0.0, "hunger was restored (%.4f)" % hunger_gain)
	# PLANKTON_EATEN.value is the XP gained: the events add up to the player's XP, and each event follows the XP rule
	# (xp_per_unit x amount x the size falloff of the eater against the plankton's length).
	assert_almost_eq(_sum_value(evs), xp_gain, 1e-6, "sum of PLANKTON_EATEN.value equals the XP the player gained")
	var plankton_len: float = float((w.content.get_species(StringName(String(cfg["species_id"])))["length_m"] as Dictionary)["min"])
	var falloff: Dictionary = w.content.rules()["xp_falloff"]
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		assert_eq(ev.entity_id, e.id, "PLANKTON_EATEN names the eater")
		assert_true(ev.data.has("cell") and ev.data.has("amount") and ev.data.has("pos"), "data has cell, amount and pos")
		var want: float = SimRules.xp_gain(float(ev.data["amount"]) * float(cfg["xp_per_unit"]), e.length_m, plankton_len, falloff)
		assert_almost_eq(ev.value, want, 1e-6, "value = XP for amount %.4f" % float(ev.data["amount"]))
	assert_almost_eq(hunger_gain, eaten * float(cfg["hunger_per_unit"]), 1e-6, "hunger gained = eaten amount x map.plankton.hunger_per_unit")
	# Note: the cell is eaten empty within ~10 ticks (eat_per_tick x ticks > density) and then rests until it regrows
	# to min_eat_density, so a second batch right after would eat nothing (see the min_eat_density test).


func test_only_players_graze_and_a_cell_below_min_eat_density_is_left_alone() -> void:
	var ctx: Dictionary = _setup(77)
	if not _usable(ctx):
		return
	var w: SimWorld = ctx["w"]
	var cfg: Dictionary = S4.plankton_cfg(w)
	# An NPC small enough to swallow plankton, held in another plankton cell, never grazes.
	var other: Vector3 = _other_cell(w, ctx["probe"])
	if not other.is_finite():
		fail("setup: no second plankton cell with a positive cap near the probe")
		return
	var npc: SimEntity = S3.npc_at(w, S4.REEF_FISH, other)
	var npc_id: int = npc.id
	var pre: Callable = func(world: SimWorld) -> void:
		S4.pin(world, ctx["pid"], ctx["probe"])
		S4.pin(world, npc_id, other)
	var evs: Array[SimEvent] = S4.run(w, 90, pre)
	var eaters: Dictionary = {}
	for ev: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		eaters[ev.entity_id] = true
	assert_true(eaters.has(ctx["pid"]), "setup: the player grazed")
	assert_false(eaters.has(npc_id), "an NPC never produces PLANKTON_EATEN")
	assert_almost_eq(S4.density_at(w, other), S4.cell_cap(w, other), 1e-9, "and leaves its cell untouched (still at its cap)")
	# min_eat_density: while a cell is below it nothing is taken from it.
	var min_eat: float = float(cfg.get("min_eat_density", 0.0))
	assert_true(min_eat > 0.0, "map.plankton.min_eat_density is set (%.3f)" % min_eat)
	var cell: int = -1
	for ev2: SimEvent in S4.events_named(evs, "PLANKTON_EATEN"):
		cell = int(ev2.data["cell"])
	var field: Object = w.get("plankton")
	var violations: int = 0
	var eaten_after_low: int = 0
	for i in 240:
		var d_before: float = float(field.call("density", cell))
		pre.call(w)
		w.step()
		var got: int = 0
		for ev3: SimEvent in S4.events_named(w.events_since(w.tick - 1), "PLANKTON_EATEN"):
			if int(ev3.data["cell"]) == cell:
				got += 1
		# 0.005 absorbs the one-tick regrowth between the probe and the phase.
		if d_before < min_eat - 0.005 and got > 0:
			violations += 1
		if d_before < min_eat - 0.005:
			eaten_after_low += 1
	assert_eq(violations, 0, "no PLANKTON_EATEN from a cell whose density is below min_eat_density (%.3f)" % min_eat)
	assert_true(eaten_after_low > 0, "the cell really sat below min_eat_density for a while (not vacuous)")


func test_the_density_stays_between_zero_and_the_cell_cap() -> void:
	var ctx: Dictionary = _setup(74)
	if not _usable(ctx):
		return
	var w: SimWorld = ctx["w"]
	var cap: float = ctx["cap"]
	var pre: Callable = _pin(w, ctx["pid"], ctx["probe"])
	var lowest: float = INF
	var highest: float = 0.0
	for i in 40:
		S4.run(w, 10, pre)
		var d: float = S4.density_at(w, ctx["probe"])
		lowest = minf(lowest, d)
		highest = maxf(highest, d)
	assert_true(lowest >= 0.0, "density never negative (min %.6f)" % lowest)
	assert_true(highest <= cap + 1e-9, "density never above the cell cap %.3f (max %.6f)" % [cap, highest])
	assert_true(lowest < cap, "the player really ate the cell down")


# ======================================================== regrowth

func test_an_eaten_cell_regrows_monotonically_up_to_its_cap() -> void:
	var ctx: Dictionary = _setup(75)
	if not _usable(ctx):
		return
	var w: SimWorld = ctx["w"]
	var cfg: Dictionary = S4.plankton_cfg(w)
	var cap: float = ctx["cap"]
	var rate: float = float(cfg["regrow_per_s"])
	assert_true(rate > 0.0, "map.plankton.regrow_per_s > 0")
	S4.run(w, 120, _pin(w, ctx["pid"], ctx["probe"]))
	var low: float = S4.density_at(w, ctx["probe"])
	assert_true(low < cap - 1e-6, "setup: the cell was eaten down (%.4f of %.3f)" % [low, cap])
	w.remove_entity(ctx["pid"])
	var prev: float = low
	var budget_ticks: int = int(3.0 * cap / rate * 30.0) + 60
	var full_at: int = -1
	for i in budget_ticks:
		w.step()
		if i % 15 == 0:
			var d: float = S4.density_at(w, ctx["probe"])
			assert_true(d >= prev - 1e-9, "regrowth never decreases (tick +%d: %.4f after %.4f)" % [i, d, prev])
			assert_true(d <= cap + 1e-9, "and never exceeds the cell cap (%.6f)" % d)
			prev = d
			if full_at < 0 and d >= cap - 1e-6:
				full_at = i
	assert_true(full_at >= 0, "the cell is full again within 3 x cap / regrow_per_s = %.0f s" % (3.0 * cap / rate))


func test_regrowth_and_eating_are_deterministic_and_part_of_the_hash() -> void:
	var hashes: Array[int] = []
	var densities: Array[float] = []
	for i in 2:
		var ctx: Dictionary = _setup(76)
		if not _usable(ctx):
			return
		var w: SimWorld = ctx["w"]
		S4.run(w, 60, _pin(w, ctx["pid"], ctx["probe"]))
		w.remove_entity(ctx["pid"])
		S4.run(w, 300)
		hashes.append(w.state_hash())
		densities.append(S4.density_at(w, ctx["probe"]))
	assert_eq(hashes[0], hashes[1], "same seed, same actions: identical state_hash")
	assert_almost_eq(densities[0], densities[1], 1e-12, "identical density")
	# Same world, but the player idles OUTSIDE the plankton zones (nothing eaten) for the same 60 ticks.
	var ctx2: Dictionary = _setup(76)
	if not _usable(ctx2):
		return
	var w2: SimWorld = ctx2["w"]
	var abyss: Array[Vector3] = S3.zone_box(w2, S4.ABYSS)
	var elsewhere: Vector3 = (abyss[0] + abyss[1]) * 0.5
	S4.pin(w2, ctx2["pid"], elsewhere)
	S4.run(w2, 60, _pin(w2, ctx2["pid"], elsewhere))
	w2.remove_entity(ctx2["pid"])
	S4.run(w2, 300)
	assert_ne(w2.state_hash(), hashes[0], "a field that was eaten from hashes differently from an untouched one (density is hashed)")
	assert_true(S4.density_at(w2, ctx2["probe"]) > densities[0] - 1e-9, "and the untouched cell is at least as dense")
