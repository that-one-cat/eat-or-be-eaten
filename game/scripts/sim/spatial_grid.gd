class_name SpatialGrid
extends RefCounted
## Uniform 3D grid shared by eat checks, flocking and (later) network interest management (hard rule 7).
## Cells are keyed by one packed int: each cell coordinate is offset by 2^20 and stored in 21 bits
## (x << 42 | y << 21 | z), enough for +-2^20 cells per axis. Each occupied cell keeps an Array[int] of ids;
## empty cells are dropped. query_radius checks squared distance, so no Area3D per entity.

const _OFFSET: int = 1 << 20
const _MASK: int = (1 << 21) - 1
## query_radius widens its cell box by this many metres so that a point the float32 distance check accepts
## on the sphere boundary is never missed because of rounding in the cell-index maths.
const _QUERY_PAD_M: float = 0.01

var cell_size: float = 1.0

var _inv_cell: float = 1.0
var _cells: Dictionary = {}    # int cell key -> Array[int] ids
var _pos: Dictionary[int, Vector3] = {}
var _cell_of: Dictionary[int, int] = {}  # id -> cell key


func _init(p_cell_size: float = 1.0) -> void:
	if not (is_finite(p_cell_size) and p_cell_size > 0.0):
		push_error("SpatialGrid: cell_size must be a finite number > 0, got %s; using 1.0" % p_cell_size)
		p_cell_size = 1.0
	cell_size = p_cell_size
	_inv_cell = 1.0 / p_cell_size


## Inserting an existing id moves it. A position that is not finite, or whose cell index does not fit the
## 21-bit packing (|coord| / cell_size >= 2^20), is rejected with push_error and the grid is left unchanged.
func insert(id: int, pos: Vector3) -> void:
	if not _is_indexable(pos):
		push_error("SpatialGrid: id %d position %s is not finite or outside the indexable range" % [id, pos])
		return
	if _pos.has(id):
		move(id, pos)
		return
	var key: int = _key_of(pos)
	_pos[id] = pos
	_cell_of[id] = key
	_add_to_cell(key, id)


func move(id: int, pos: Vector3) -> void:
	if not _is_indexable(pos):
		push_error("SpatialGrid: id %d position %s is not finite or outside the indexable range" % [id, pos])
		return
	if not _pos.has(id):
		insert(id, pos)
		return
	_pos[id] = pos
	var key: int = _key_of(pos)
	var old_key: int = _cell_of[id]
	if key == old_key:
		return
	_remove_from_cell(old_key, id)
	_cell_of[id] = key
	_add_to_cell(key, id)


## False if the id is unknown.
func remove(id: int) -> bool:
	if not _pos.has(id):
		return false
	_remove_from_cell(_cell_of[id], id)
	_pos.erase(id)
	_cell_of.erase(id)
	return true


func has(id: int) -> bool:
	return _pos.has(id)


func count() -> int:
	return _pos.size()


func position_of(id: int) -> Vector3:
	return _pos.get(id, Vector3.ZERO)


## Ids within `radius` of `center` (squared distance <= radius^2), ascending.
## Visits only cells inside the sphere's AABB; when that box holds more cells than are occupied,
## it walks the occupied cells instead and skips those outside the box (same result, bounded cost).
## A non-finite centre, or a NaN/negative radius, matches nothing; an infinite radius matches everything.
func query_radius(center: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	query_radius_into(center, radius, out)
	return out


## Same as query_radius, but clears and fills the caller's `out` (lets the sim tick reuse one buffer).
func query_radius_into(center: Vector3, radius: float, out: PackedInt32Array) -> void:
	out.clear()
	if _pos.is_empty() or not center.is_finite() or is_nan(radius) or radius < 0.0:
		return
	if is_inf(radius):
		out.append_array(PackedInt32Array(_pos.keys()))
		out.sort()
		return
	var r2: float = radius * radius
	var reach: float = radius + _QUERY_PAD_M
	var lo := Vector3i(floori((center.x - reach) * _inv_cell), floori((center.y - reach) * _inv_cell), floori((center.z - reach) * _inv_cell))
	var hi := Vector3i(floori((center.x + reach) * _inv_cell), floori((center.y + reach) * _inv_cell), floori((center.z + reach) * _inv_cell))
	# Float product: a huge radius must not overflow the int64 cell count and wrongly pick the per-cell walk.
	var box_cells: float = (float(hi.x) - float(lo.x) + 1.0) * (float(hi.y) - float(lo.y) + 1.0) * (float(hi.z) - float(lo.z) + 1.0)
	if box_cells > float(_cells.size()):
		for key: int in _cells:
			var cx: int = ((key >> 42) & _MASK) - _OFFSET
			var cy: int = ((key >> 21) & _MASK) - _OFFSET
			var cz: int = (key & _MASK) - _OFFSET
			if cx < lo.x or cx > hi.x or cy < lo.y or cy > hi.y or cz < lo.z or cz > hi.z:
				continue
			_collect(_cells[key], center, r2, out)
	else:
		# packed key = kx << 42 | ky << 21 | kz (see _pack), walked axis by axis without per-cell calls
		for cx in range(lo.x, hi.x + 1):
			var kx: int = ((cx + _OFFSET) & _MASK) << 42
			for cy in range(lo.y, hi.y + 1):
				var kxy: int = kx | (((cy + _OFFSET) & _MASK) << 21)
				for cz in range(lo.z, hi.z + 1):
					var ids: Variant = _cells.get(kxy | ((cz + _OFFSET) & _MASK))
					if ids != null:
						for id: int in (ids as Array[int]):
							if center.distance_squared_to(_pos[id]) <= r2:
								out.append(id)
	if out.size() > 1:
		out.sort()


func _collect(ids: Array[int], center: Vector3, r2: float, out: PackedInt32Array) -> void:
	for id in ids:
		var p: Vector3 = _pos[id]
		if center.distance_squared_to(p) <= r2:
			out.append(id)


func _key_of(pos: Vector3) -> int:
	return _pack(floori(pos.x * _inv_cell), floori(pos.y * _inv_cell), floori(pos.z * _inv_cell))


func _is_indexable(pos: Vector3) -> bool:
	return pos.is_finite() and maxf(maxf(absf(pos.x), absf(pos.y)), absf(pos.z)) * _inv_cell < float(_OFFSET - 1)


static func _pack(cx: int, cy: int, cz: int) -> int:
	return (((cx + _OFFSET) & _MASK) << 42) | (((cy + _OFFSET) & _MASK) << 21) | ((cz + _OFFSET) & _MASK)


func _add_to_cell(key: int, id: int) -> void:
	var ids: Variant = _cells.get(key)
	if ids == null:
		var fresh: Array[int] = [id]
		_cells[key] = fresh
	else:
		(ids as Array[int]).append(id)


func _remove_from_cell(key: int, id: int) -> void:
	var ids: Array[int] = _cells[key]
	var idx: int = ids.find(id)
	var last: int = ids.size() - 1
	ids[idx] = ids[last]
	ids.resize(last)
	if last == 0:
		_cells.erase(key)
