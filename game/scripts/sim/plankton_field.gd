class_name PlanktonField
extends RefCounted
## Plankton as a density grid instead of entities (CLAUDE.md rule 4, GAME_DESIGN section 3 "swarm density").
## Built from the map `plankton` block (`create`, `create_block`); the krill clouds (map `krill` list) are KrillField,
## which shares the grid, zones and variation below and replaces the density by individual critters.
## Cubic cells of cell_m, aligned with the SpatialGrid (cell boundaries at integer multiples of cell_m from the
## origin), covering the map box (`create_block` without whole_map: the bounding box of its zones); only
## cells whose centre lies inside one of the listed zones hold plankton. Density starts at density_max and regrows
## linearly by regrow_per_s up to density_max. Storage is lazy (density + tick of the last change per touched cell),
## so regrowth costs nothing per tick and is exactly reproducible.
##
## Eating (SimWorld plankton phase): a living player whose mouth point (centre + heading x length x
## rules.mouth_reach_mult) is in a plankton cell with density > 0, and for which plankton is swallowable
## (SimRules.can_swallow against length_m = the species' minimum length), eats min(density, eat_per_tick) per tick
## while the cell density is >= min_eat_density (optional key, default 0; keeps an emptied cell from being nibbled
## every tick as it regrows):
## XP = SimRules.xp_gain(amount x xp_per_unit, eater length, length_m, rules.xp_falloff), hunger + amount x
## hunger_per_unit, PLANKTON_EATEN. NPCs do not graze (they have no XP or hunger).
##
## Patchiness (optional `variation` block {seed, patch_m, empty_frac, rich_frac, min_mult}): every cell column
## (ix, iz) gets a multiplier m in [0, 1] and its cells hold at most cell_cap = density_max x m (start density and
## regrowth limit; the regrowth rate stays regrow_per_s, a cap-0 cell holds nothing). m comes from smooth 2D value
## noise (lattice spacing patch_m, lattice values SchoolSystem.hash01(seed, ...)) mapped through its rank r in [0, 1)
## over all plankton cells (a column weighs as many plankton cells as it has): r < empty_frac -> 0,
## r >= 1 - rich_frac -> 1, else lerp(min_mult, 1) over the band between. The rank mapping fixes the share of empty
## and full cells and the mean multiplier for any seed: mean m = rich_frac + (1 - empty_frac - rich_frac) x
## (1 + min_mult) / 2, so density_max = old density_max / mean m keeps the mean cap of the uniform field. The caps are
## static map data (not part of state_hash; the eaten cells are). Without the block every cap is density_max.

const SALT_VARIATION: int = 211

var species_id: StringName = &""
var cell_m: float = 0.0
var density_max: float = 0.0
var regrow_per_tick: float = 0.0
var eat_per_tick: float = 0.0
var min_eat_density: float = 0.0
var xp_per_unit: float = 0.0
var hunger_per_unit: float = 0.0
## Length the swallow rule and the XP falloff use for plankton (species length_m.min).
var length_m: float = 0.0
## The owning world's current tick (SimWorld keeps it equal to world.tick); the default for the read accessors.
var now_tick: int = 0

var _inv_cell: float = 1.0
var _origin: Vector3i = Vector3i.ZERO  # integer cell coordinate of cell index 0
var _n: Vector3i = Vector3i.ZERO  # cells per axis
var _box_lo: PackedVector3Array = PackedVector3Array()  # plankton zone boxes (a cell holds plankton when its
var _box_hi: PackedVector3Array = PackedVector3Array()  # centre is inside one of them)
var _d0: PackedFloat64Array = PackedFloat64Array()  # density at _t0 (touched cells)
var _t0: PackedInt32Array = PackedInt32Array()  # tick of the last change, -1 = untouched (full)
var _touched: PackedInt32Array = PackedInt32Array()  # cells with _t0 >= 0, ascending
var _plankton_cells: int = -1  # computed on first request
var _col_mult: PackedFloat64Array = PackedFloat64Array()  # column ix * _n.z + iz -> cap multiplier; empty = all 1


## Field for `map` (null when the map has no `plankton` block or its species is missing). Its grid covers the whole
## map box (S4 cell indices).
static func create(content: ContentDB, map: Dictionary) -> PlanktonField:
	if content == null or not (map.get("plankton") is Dictionary):
		return null
	return create_block(content, map, map["plankton"], true)


## Field for one block of the `plankton` shape (null when its species is missing). The grid covers the bounding box
## of the block's zones (clipped to the map box; cell boundaries stay at integer multiples of cell_m from the origin,
## cell_at is -1 outside it), or the whole map box with `whole_map` (`create`). Map `krill` entries use
## KrillField.from_block (same setup, individual critters).
static func create_block(content: ContentDB, map: Dictionary, block: Dictionary, whole_map: bool = false) -> PlanktonField:
	return _setup(PlanktonField.new(), content, map, block, whole_map)


# Fills `f` from `block` (create_block); null when the block's species is missing.
static func _setup(f: PlanktonField, content: ContentDB, map: Dictionary, block: Dictionary, whole_map: bool) -> PlanktonField:
	if content == null:
		return null
	var sp: Dictionary = content.get_species(StringName(str(block.get("species_id", ""))))
	if sp.is_empty():
		return null
	f.species_id = StringName(str(block.get("species_id")))
	f.cell_m = float(block.get("cell_m", 8.0))
	f._inv_cell = 1.0 / f.cell_m
	f.density_max = float(block.get("density_max", 1.0))
	f.regrow_per_tick = float(block.get("regrow_per_s", 0.0)) * SimWorld.TICK_DT
	f.eat_per_tick = float(block.get("eat_per_tick", 0.0))
	f.min_eat_density = float(block.get("min_eat_density", 0.0))
	f.xp_per_unit = float(block.get("xp_per_unit", 0.0))
	f.hunger_per_unit = float(block.get("hunger_per_unit", 0.0))
	var lengths: Dictionary = sp.get("length_m", {}) if sp.get("length_m") is Dictionary else {}
	f.length_m = float(lengths.get("min", 0.01))
	var half: float = float(map.get("size_m", 0.0)) * 0.5
	var depth: float = float(map.get("depth_m", 0.0))
	var lo := Vector3i(floori(-half * f._inv_cell), floori(-depth * f._inv_cell), floori(-half * f._inv_cell))
	var hi := Vector3i(ceili(half * f._inv_cell), 0, ceili(half * f._inv_cell))
	var wanted: Array = block.get("zones", []) if block.get("zones") is Array else []
	for z in (map.get("zones", []) as Array):
		var zd: Dictionary = z
		if wanted.has(zd.get("id")):
			var a: Array = zd["aabb"]["min"]
			var b: Array = zd["aabb"]["max"]
			f._box_lo.append(Vector3(float(a[0]), float(a[1]), float(a[2])))
			f._box_hi.append(Vector3(float(b[0]), float(b[1]), float(b[2])))
	if not whole_map:
		var zlo := Vector3i(hi)
		var zhi := Vector3i(lo)
		for i in f._box_lo.size():
			zlo = zlo.min(Vector3i((f._box_lo[i] * f._inv_cell).floor()))
			zhi = zhi.max(Vector3i((f._box_hi[i] * f._inv_cell).ceil()))
		lo = zlo.clamp(lo, hi)
		hi = zhi.clamp(lo, hi)
	f._origin = lo
	f._n = hi - lo
	var count: int = f._n.x * f._n.y * f._n.z
	f._d0.resize(count)
	f._t0.resize(count)
	f._t0.fill(-1)
	if block.get("variation") is Dictionary:
		f._build_variation(block["variation"])
	return f


## Box covered by the grid (world metres; corners at multiples of cell_m).
func bounds() -> AABB:
	return AABB(Vector3(_origin) * cell_m, Vector3(_n) * cell_m)


## Total cells of the grid (indices 0 .. cell_count() - 1) and how many of them hold plankton.
func cell_count() -> int:
	return _t0.size()


func plankton_cell_count() -> int:
	if _plankton_cells < 0:
		_plankton_cells = 0
		for c in _t0.size():
			if is_plankton_cell(c):
				_plankton_cells += 1
	return _plankton_cells


## Cell index containing `pos`, -1 outside the grid.
func cell_at(pos: Vector3) -> int:
	var ix: int = floori(pos.x * _inv_cell) - _origin.x
	var iy: int = floori(pos.y * _inv_cell) - _origin.y
	var iz: int = floori(pos.z * _inv_cell) - _origin.z
	if ix < 0 or iy < 0 or iz < 0 or ix >= _n.x or iy >= _n.y or iz >= _n.z:
		return -1
	return (ix * _n.y + iy) * _n.z + iz


## Centre of cell `cell` (world metres).
func cell_center(cell: int) -> Vector3:
	var iz: int = cell % _n.z
	var iy: int = (cell / _n.z) % _n.y
	var ix: int = cell / (_n.z * _n.y)
	return Vector3((float(ix + _origin.x) + 0.5) * cell_m, (float(iy + _origin.y) + 0.5) * cell_m, (float(iz + _origin.z) + 0.5) * cell_m)


## True for a cell inside one of the plankton zones.
func is_plankton_cell(cell: int) -> bool:
	if cell < 0 or cell >= _t0.size():
		return false
	var c: Vector3 = cell_center(cell)
	for i in _box_lo.size():
		var lo: Vector3 = _box_lo[i]
		var hi: Vector3 = _box_hi[i]
		if c.x >= lo.x and c.x <= hi.x and c.y >= lo.y and c.y <= hi.y and c.z >= lo.z and c.z <= hi.z:
			return true
	return false


## Maximum density of `cell` (density_max x its column multiplier, see the class doc); 0 outside the plankton zones.
func cell_cap(cell: int) -> float:
	if not is_plankton_cell(cell):
		return 0.0
	if _col_mult.is_empty():
		return density_max
	return density_max * _col_mult[(cell / (_n.z * _n.y)) * _n.z + cell % _n.z]


## Density of `cell` at `at_tick` (-1 = now_tick); 0 outside the plankton zones.
func density(cell: int, at_tick: int = -1) -> float:
	var cap: float = cell_cap(cell)
	if not (cap > 0.0):
		return 0.0
	if at_tick < 0:
		at_tick = now_tick
	var t0: int = _t0[cell]
	if t0 < 0:
		return cap
	return minf(_d0[cell] + regrow_per_tick * float(at_tick - t0), cap)


func density_at(pos: Vector3, at_tick: int = -1) -> float:
	return density(cell_at(pos), at_tick)


## Cells eaten below their cap that have not been pruned yet (ascending). Every other plankton cell is full.
func touched_cells() -> PackedInt32Array:
	return _touched


## Takes min(density, eat_per_tick) from `cell` at `tick`; returns the amount (0 when the density is 0 or below
## min_eat_density, or the cell holds no plankton).
func eat(cell: int, at_tick: int) -> float:
	var d: float = density(cell, at_tick)
	var amount: float = minf(d, eat_per_tick)
	if not (amount > 0.0) or d < min_eat_density:
		return 0.0
	if _t0[cell] < 0:
		var i: int = _touched.bsearch(cell)
		_touched.insert(i, cell)
	_d0[cell] = d - amount
	_t0[cell] = at_tick
	return amount


## Forgets cells that have regrown to their cap (their density is the same either way).
func prune(at_tick: int) -> void:
	var keep: int = 0
	for i in _touched.size():
		var c: int = _touched[i]
		if density(c, at_tick) >= cell_cap(c):
			_t0[c] = -1
		else:
			_touched[keep] = c
			keep += 1
	_touched.resize(keep)


## Appends every cell below its cap at `tick` (ascending, density quantised to 1e-6) to a state hash buffer.
func write_state(buf: StreamPeerBuffer, at_tick: int) -> void:
	var n: int = 0
	for c in _touched:
		if density(c, at_tick) < cell_cap(c):
			n += 1
	buf.put_32(n)
	for c in _touched:
		var d: float = density(c, at_tick)
		if d < cell_cap(c):
			buf.put_32(c)
			buf.put_64(roundi(d * 1.0e6))


# Column multipliers from the `variation` block (class doc): value noise per column centre, ranked by plankton
# cells; ties are broken by the column index, so the result depends on the data only.
func _build_variation(v: Dictionary) -> void:
	var seed_v: int = int(v.get("seed", 0))
	var inv_patch: float = 1.0 / float(v.get("patch_m", 48.0))
	var empty_frac: float = float(v.get("empty_frac", 0.0))
	var rich_frac: float = float(v.get("rich_frac", 0.0))
	var min_mult: float = float(v.get("min_mult", 1.0))
	var cols: int = _n.x * _n.z
	# plankton cells per column: the iy range of every zone box that covers the column centre
	var weight := PackedInt32Array()
	weight.resize(cols)
	var mark := PackedByteArray()
	mark.resize(_n.y)
	var total: int = 0
	for ix in _n.x:
		var x: float = (float(ix + _origin.x) + 0.5) * cell_m
		for iz in _n.z:
			var z: float = (float(iz + _origin.z) + 0.5) * cell_m
			mark.fill(0)
			for b in _box_lo.size():
				var lo: Vector3 = _box_lo[b]
				var hi: Vector3 = _box_hi[b]
				if x < lo.x or x > hi.x or z < lo.z or z > hi.z:
					continue
				var y0: int = maxi(ceili(lo.y * _inv_cell - 0.5) - _origin.y, 0)
				var y1: int = mini(floori(hi.y * _inv_cell - 0.5) - _origin.y, _n.y - 1)
				for iy in range(y0, y1 + 1):
					mark[iy] = 1
			var w: int = mark.count(1)
			weight[ix * _n.z + iz] = w
			total += w
	_col_mult.resize(cols)
	_col_mult.fill(0.0)
	if total == 0:
		return
	var keys := PackedInt64Array()
	for col in cols:
		if weight[col] > 0:
			var x: float = (float(col / _n.z + _origin.x) + 0.5) * cell_m
			var z: float = (float(col % _n.z + _origin.z) + 0.5) * cell_m
			keys.append((int(value_noise(seed_v, x * inv_patch, z * inv_patch) * 16777216.0) << 20) | col)
	keys.sort()
	var middle: float = 1.0 - empty_frac - rich_frac
	var below: int = 0
	for key in keys:
		var col: int = key & 0xFFFFF
		var r: float = (float(below) + 0.5 * float(weight[col])) / float(total)
		below += weight[col]
		if r < empty_frac:
			_col_mult[col] = 0.0
		elif r >= 1.0 - rich_frac or middle <= 0.0:
			_col_mult[col] = 1.0
		else:
			_col_mult[col] = lerpf(min_mult, 1.0, (r - empty_frac) / middle)


## Smooth 2D value noise in [0, 1) at lattice coordinates (u, v): smoothstep blend of SchoolSystem.hash01(seed, ...)
## at the four surrounding integer lattice points.
static func value_noise(seed_v: int, u: float, v: float) -> float:
	var i: int = floori(u)
	var j: int = floori(v)
	var tu: float = u - float(i)
	var tv: float = v - float(j)
	tu = tu * tu * (3.0 - 2.0 * tu)
	tv = tv * tv * (3.0 - 2.0 * tv)
	var a: float = _lattice(seed_v, i, j)
	var b: float = _lattice(seed_v, i + 1, j)
	var c: float = _lattice(seed_v, i, j + 1)
	var d: float = _lattice(seed_v, i + 1, j + 1)
	return lerpf(lerpf(a, b, tu), lerpf(c, d, tu), tv)


static func _lattice(seed_v: int, i: int, j: int) -> float:
	return SchoolSystem.hash01(seed_v, (i + 32768) * 65536 + (j + 32768), SALT_VARIATION)
