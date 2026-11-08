class_name KrillField
extends PlanktonField
## A krill cloud of individual critters (one per map `krill` entry, SimWorld.krill). Grid, zones, `variation` and
## the XP / hunger units are PlanktonField's; instead of a density every cell holds up to critters_per_cell krill.
##
## Layout (static, a pure function of the map data): a cell with column multiplier m (PlanktonField variation, 1
## without it) holds critter_count = ceil(critters_per_cell x m) krill, k = 0 .. count - 1. Each cell has a swarm
## centre (cell centre, x / z jittered by +-SWARM_JITTER_FRAC x cell_m); critter k sits at the centre + spread_m x
## (h, h / 2, h) with hashed h in [-1, 1] per axis, y kept inside the cell's band (the cell, clipped to the zone box
## and SURFACE_CLEARANCE_M below the surface). Krill zones lie above the seabed (data README), so no seabed test.
##
## Motion (`motion` block, all 0 = static): critter_offset(custom, t) at sim time t (tick x TICK_DT), mirrored by
## fish_swim.gdshader (the `krill` uniforms, set by AmbientRenderer from this field):
##   th = drift_w t + TAU phi, side = (sin th, 0, cos th), u = weave_w s t + TAU a, s = 1 + 0.25 tint,
##   offset = side x (drift_m + weave_m sin u) + up x bob_m sin(1.3 u + TAU phase).
## The cloud circles drift_m around its layout (the heading turns by drift_w: the collective turn), every critter
## weaves weave_m sideways and bobs; phi (per cell) is smooth value noise over variation.patch_m, so a cloud moves
## together. The shader turns each body along the velocity; weave_m < drift_m keeps it always moving forward.
##
## State: per touched cell the alive bits at the regrow clock tick (lazy like PlanktonField: untouched = all alive).
## Regrowth restores ONE critter (the lowest dead index) every regrow_ticks = round(unit / regrow_per_tick) ticks of
## its clock; the clock starts when a full cell loses its first critter and keeps its progress across later eats.
## density(cell) = alive count x unit, cell_cap = critter_count x unit (unit = density_max / critters_per_cell), so
## prune, touched_cells and the PlanktonField readers keep working.
##
## Eating (SimWorld._graze_krill): eat_nearest() removes the alive critter nearest to the mouth point (positions at
## the eat tick, motion included) within the eat radius; one critter = one PLANKTON_EATEN of `unit` density units.

const SALT_CRITTER: int = 231
const SALT_DRIFT: int = 232
const MAX_CRITTERS: int = 32
## Event / renderer key of critter k of cell c: c x KEY_STRIDE + k.
const KEY_STRIDE: int = 64
const SWARM_JITTER_FRAC: float = 0.25
const SURFACE_CLEARANCE_M: float = 0.3
## Floats per critter in critter_layout(): base x, y, z, then INSTANCE_CUSTOM phase, tint, weave phase a, drift phi.
const LAYOUT_STRIDE: int = 7

var critters_per_cell: int = 8
## Density units of one critter (density_max / critters_per_cell).
var unit: float = 0.125
var eat_radius_m: float = 0.5
var eat_interval_ticks: int = 1
var spread_m: float = 1.2
## Ticks per regrown critter (0 = never).
var regrow_ticks: int = 0
var drift_m: float = 0.0
var drift_w: float = 0.0
var weave_m: float = 0.0
var weave_w: float = 0.0
var bob_m: float = 0.0

var _salt: int = SALT_CRITTER
var _drift_seed: int = SALT_DRIFT
var _inv_patch: float = 1.0 / 24.0
var _reach_out: float = 0.0  # how far a critter can be outside its cell (layout + motion)
var _mask0: PackedInt64Array = PackedInt64Array()  # alive bits at the clock tick _t0 (touched cells)
var _layouts: Dictionary[int, PackedFloat32Array] = {}  # cache of critter_layout (static data)


## Field for one map `krill` entry (null when its species is missing). Keys on top of the plankton block (all
## optional): critters_per_cell (default 8), eat_radius_m (0.5), eat_interval_ticks (1), spread_m (1.2),
## motion {drift_m, drift_period_s, weave_m, weave_period_s, bob_m} (missing = static).
static func from_block(content: ContentDB, map: Dictionary, block: Dictionary) -> KrillField:
	var f: KrillField = PlanktonField._setup(KrillField.new(), content, map, block, false) as KrillField
	if f == null:
		return null
	f.critters_per_cell = clampi(int(block.get("critters_per_cell", 8)), 1, MAX_CRITTERS)
	f.unit = f.density_max / float(f.critters_per_cell)
	f.eat_radius_m = float(block.get("eat_radius_m", 0.5))
	f.eat_interval_ticks = maxi(int(block.get("eat_interval_ticks", 1)), 1)
	f.spread_m = float(block.get("spread_m", 1.2))
	if f.regrow_per_tick > 0.0:
		f.regrow_ticks = maxi(roundi(f.unit / f.regrow_per_tick), 1)
	var mo: Dictionary = block.get("motion", {}) if block.get("motion") is Dictionary else {}
	f.drift_m = float(mo.get("drift_m", 0.0))
	f.drift_w = TAU / float(mo["drift_period_s"]) if float(mo.get("drift_period_s", 0.0)) > 0.0 else 0.0
	f.weave_m = float(mo.get("weave_m", 0.0))
	f.weave_w = TAU / float(mo["weave_period_s"]) if float(mo.get("weave_period_s", 0.0)) > 0.0 else 0.0
	f.bob_m = float(mo.get("bob_m", 0.0))
	var v: Dictionary = block.get("variation", {}) if block.get("variation") is Dictionary else {}
	f._salt = int(v.get("seed", 0)) + SALT_CRITTER
	f._drift_seed = int(v.get("seed", 0)) + SALT_DRIFT
	f._inv_patch = 1.0 / float(v.get("patch_m", 24.0))
	f._reach_out = maxf((SWARM_JITTER_FRAC - 0.5) * f.cell_m + f.spread_m, 0.0) + f.drift_m + f.weave_m + f.bob_m
	f._mask0.resize(f.cell_count())
	return f


## Krill in `cell` when it is full (0 outside the zones and in empty patches).
func critter_count(cell: int) -> int:
	if not is_plankton_cell(cell):
		return 0
	if _col_mult.is_empty():
		return critters_per_cell
	var m: float = _col_mult[(cell / (_n.z * _n.y)) * _n.z + cell % _n.z]
	return ceili(float(critters_per_cell) * m - 1e-9) if m > 0.0 else 0


func cell_cap(cell: int) -> float:
	return float(critter_count(cell)) * unit


func density(cell: int, at_tick: int = -1) -> float:
	return float(_popcount(alive_mask(cell, at_tick))) * unit


## Alive bits of `cell` at `at_tick` (-1 = now_tick): bit k = critter k (0 for a cell without krill).
func alive_mask(cell: int, at_tick: int = -1) -> int:
	var n: int = critter_count(cell)
	if n == 0:
		return 0
	var full: int = (1 << n) - 1
	var t0: int = _t0[cell]
	if t0 < 0:
		return full
	if at_tick < 0:
		at_tick = now_tick
	var mask: int = _mask0[cell]
	if regrow_ticks > 0:
		var r: int = (at_tick - t0) / regrow_ticks
		while r > 0 and mask != full:
			var dead: int = full & ~mask
			mask |= dead & -dead
			r -= 1
	return mask


## Removes one critter of `cell` (the highest alive index) at `at_tick`; returns `unit` (0 when none is alive).
func eat(cell: int, at_tick: int) -> float:
	var mask: int = alive_mask(cell, at_tick)
	for k in range(critter_count(cell) - 1, -1, -1):
		if (mask >> k) & 1 == 1:
			take(cell, k, at_tick)
			return unit
	return 0.0


## Removes critter k of `cell` at `at_tick` (no-op when it is not alive).
func take(cell: int, k: int, at_tick: int) -> void:
	var mask: int = alive_mask(cell, at_tick)
	if (mask >> k) & 1 == 0:
		return
	var t0: int = _t0[cell]
	if t0 < 0:
		_touched.insert(_touched.bsearch(cell), cell)
	if t0 < 0 or mask == (1 << critter_count(cell)) - 1:
		t0 = at_tick  # a full cell starts its regrow clock now
	else:
		t0 = _clock(cell, at_tick)
	_mask0[cell] = mask & ~(1 << k)
	_t0[cell] = t0


## Eats the alive critter nearest to `mouth` within `radius` (positions at `at_tick`, motion included); returns its
## key (cell x KEY_STRIDE + k) or -1. Cells are scanned in index order, ties keep the first critter found.
func eat_nearest(mouth: Vector3, radius: float, at_tick: int) -> int:
	var m: float = radius + _reach_out
	var lo := Vector3i(((mouth - Vector3(m, m, m)) * _inv_cell).floor()) - _origin
	var hi := Vector3i(((mouth + Vector3(m, m, m)) * _inv_cell).floor()) - _origin
	lo = lo.max(Vector3i.ZERO)
	hi = hi.min(_n - Vector3i.ONE)
	var best_d2: float = radius * radius
	var best: int = -1
	var t: float = float(at_tick) * SimWorld.TICK_DT
	for ix in range(lo.x, hi.x + 1):
		for iy in range(lo.y, hi.y + 1):
			for iz in range(lo.z, hi.z + 1):
				var cell: int = (ix * _n.y + iy) * _n.z + iz
				var mask: int = alive_mask(cell, at_tick)
				if mask == 0:
					continue
				var lay: PackedFloat32Array = _cached_layout(cell)
				for k in lay.size() / LAYOUT_STRIDE:
					if (mask >> k) & 1 == 0:
						continue
					var o: int = k * LAYOUT_STRIDE
					var p := Vector3(lay[o], lay[o + 1], lay[o + 2]) + critter_offset(lay[o + 3], lay[o + 4], lay[o + 5], lay[o + 6], t)
					var d2: float = p.distance_squared_to(mouth)
					if d2 < best_d2:
						best_d2 = d2
						best = cell * KEY_STRIDE + k
	if best >= 0:
		take(best / KEY_STRIDE, best % KEY_STRIDE, at_tick)
	return best


## Position of critter k of `cell` at `at_tick` (layout + motion).
func critter_position(cell: int, k: int, at_tick: int) -> Vector3:
	var lay: PackedFloat32Array = critter_layout(cell)
	var o: int = k * LAYOUT_STRIDE
	if o + LAYOUT_STRIDE > lay.size():
		return cell_center(cell)
	return Vector3(lay[o], lay[o + 1], lay[o + 2]) + critter_offset(lay[o + 3], lay[o + 4], lay[o + 5], lay[o + 6], float(at_tick) * SimWorld.TICK_DT)


## Motion offset (metres) of a critter with INSTANCE_CUSTOM (phase, tint, a, phi) at sim time `t` seconds; the same
## formula as fish_swim.gdshader (class doc).
func critter_offset(phase: float, tint: float, a: float, phi: float, t: float) -> Vector3:
	if drift_m <= 0.0:
		return Vector3.ZERO
	var th: float = drift_w * t + TAU * phi
	var u: float = weave_w * (1.0 + 0.25 * tint) * t + TAU * a
	var r: float = drift_m + weave_m * sin(u)
	return Vector3(sin(th) * r, bob_m * sin(1.3 * u + TAU * phase), cos(th) * r)


## Static layout of `cell` (pure; LAYOUT_STRIDE floats per critter k < critter_count, see the class doc): base
## position and the INSTANCE_CUSTOM values (phase, tint in [-1, 1], weave phase a, drift phase phi).
func critter_layout(cell: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n: int = critter_count(cell)
	if n == 0:
		return out
	var c: Vector3 = cell_center(cell)
	var y_lo: float = c.y - 0.5 * cell_m
	var y_hi: float = minf(c.y + 0.5 * cell_m, -SURFACE_CLEARANCE_M)
	for i in _box_lo.size():
		var blo: Vector3 = _box_lo[i]
		var bhi: Vector3 = _box_hi[i]
		if c.x >= blo.x and c.x <= bhi.x and c.y >= blo.y and c.y <= bhi.y and c.z >= blo.z and c.z <= bhi.z:
			y_lo = maxf(y_lo, blo.y)
			y_hi = minf(y_hi, bhi.y)
			break
	var sx: float = c.x + (SchoolSystem.hash01(cell, 0, _salt) - 0.5) * 2.0 * SWARM_JITTER_FRAC * cell_m
	var sz: float = c.z + (SchoolSystem.hash01(cell, 1, _salt) - 0.5) * 2.0 * SWARM_JITTER_FRAC * cell_m
	var sy: float = 0.5 * (y_lo + y_hi)
	var phi: float = PlanktonField.value_noise(_drift_seed, c.x * _inv_patch, c.z * _inv_patch)
	out.resize(n * LAYOUT_STRIDE)
	for k in n:
		var j: int = 8 + k * 8
		var o: int = k * LAYOUT_STRIDE
		out[o] = sx + (SchoolSystem.hash01(cell, j, _salt) * 2.0 - 1.0) * spread_m
		out[o + 1] = clampf(sy + (SchoolSystem.hash01(cell, j + 1, _salt) - 0.5) * spread_m, y_lo, y_hi)
		out[o + 2] = sz + (SchoolSystem.hash01(cell, j + 2, _salt) * 2.0 - 1.0) * spread_m
		out[o + 3] = SchoolSystem.hash01(cell, j + 3, _salt)
		out[o + 4] = SchoolSystem.hash01(cell, j + 4, _salt) * 2.0 - 1.0
		out[o + 5] = SchoolSystem.hash01(cell, j + 5, _salt)
		out[o + 6] = phi
	return out


## Appends every cell with a dead critter at `at_tick` (ascending: cell, alive bits, regrow clock tick).
func write_state(buf: StreamPeerBuffer, at_tick: int) -> void:
	var n: int = 0
	for c in _touched:
		if alive_mask(c, at_tick) != (1 << critter_count(c)) - 1:
			n += 1
	buf.put_32(n)
	for c in _touched:
		var mask: int = alive_mask(c, at_tick)
		if mask != (1 << critter_count(c)) - 1:
			buf.put_32(c)
			buf.put_64(mask)
			buf.put_64(_clock(c, at_tick))


# The regrow clock of a touched cell advanced by the whole regrow steps up to `at_tick`.
func _clock(cell: int, at_tick: int) -> int:
	var t0: int = _t0[cell]
	if regrow_ticks <= 0:
		return t0
	return t0 + ((at_tick - t0) / regrow_ticks) * regrow_ticks


func _cached_layout(cell: int) -> PackedFloat32Array:
	var lay: PackedFloat32Array = _layouts.get(cell, PackedFloat32Array())
	if lay.is_empty():
		lay = critter_layout(cell)
		_layouts[cell] = lay
	return lay


static func _popcount(x: int) -> int:
	var n: int = 0
	while x != 0:
		x &= x - 1
		n += 1
	return n
