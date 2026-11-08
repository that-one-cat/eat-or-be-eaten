class_name SeabedField
extends RefCounted
## Static map collision for the sim: an analytic seabed heightfield plus simple obstacle primitives
## (sphere / capsule / axis-aligned box / rounded oriented box `obb`), all built from map data (`seabed`, `obstacles`
## in maps/*.json, plus the baked dressing proxies of maps/<id>_proxies.json that the caller passes in).
## Pure function of the data: no RNG state, no noise textures, no nodes. The presentation builds the visual
## seabed by sampling the same height_at() and obstacle meshes from obstacles(), so there is one source of truth.
##
## Seabed shape (depths are positive metres below the surface y = 0):
##   shelf(x, z) = profile(z) + value_noise(x, z) * noise.amplitude_m      (piecewise-linear depth profile along z)
##   the cliff line z_c(x) = cliff.z_m + value_noise_1d(x) * cliff.wobble_m blends the shelf into the abyss floor
##   (abyss_floor_depth_m, noise only raises it) with a smoothstep over cliff.width_m;
##   the result is clamped to [min_depth_m, depth_m]. height_at() returns -depth.
## height_at() and resolve() allocate nothing (packed arrays, scalar math only).
##
## Obstacle narrow phase: the broad-phase grid also keeps, per cell and primitive kind, the list of obstacles a
## sphere of radius <= BROAD_MAX_RADIUS_M inside that cell can reach (CSR lists, ascending obstacle index, so the
## push order equals the full pass). resolve() pushes only against the lists of the cell the centre is in;
## resolve_reference() is the full pass over every obstacle (tests compare the two).

## Finite-difference step for normal_at(), metres (numerical, not a gameplay value).
const NORMAL_EPS_M: float = 0.5
## resolve() checks the seabed plane only when the centre is closer than this many radii above it
## (steep slopes can touch the sphere although its centre is more than one radius above the ground below it).
const CONTACT_SLACK: float = 3.0
## Upper bound of seabed/obstacle alternation rounds in resolve() (corners between a slope and a pillar).
const RESOLVE_ROUNDS: int = 8
## Upper bound of obstacle sweeps per obstacle pass: a sweep is repeated while it moved the sphere (overlapping
## neighbours, e.g. two baked rocks touching, converge geometrically in their wedge) or moved it into another
## broad-phase cell. A sweep that moves nothing ends the pass, so free and single-contact spheres never pay for it.
const OBSTACLE_SWEEPS: int = 32
## After a resolve pass that touched an obstacle, the result is checked against the obstacles (penetration deeper than
## PENETRATION_EPS_M) and the seabed; a sphere still inside one (a lens between two overlapping rocks, a seabed wedge)
## gets up to this many further passes starting from where the previous one ended.
const VERIFY_PASSES: int = 3
const PENETRATION_EPS_M: float = 1e-4
## Obstacle broad phase: a horizontal grid of BROAD_CELL_M cells over the map marks every cell from which some
## obstacle is reachable by a sphere of radius <= BROAD_MAX_RADIUS_M (bounding-sphere test in x/z, so it is
## conservative). Larger spheres and points outside the map always take the full obstacle pass.
const BROAD_CELL_M: float = 8.0
const BROAD_MAX_RADIUS_M: float = 4.0
const _HASH_MASK: int = 0xFFFFFFFF
const _INV_2_32: float = 1.0 / 4294967296.0

var _seed: int = 0
var _min_depth: float = 0.0
var _max_depth: float = 0.0
var _profile_z: PackedFloat64Array = PackedFloat64Array()
var _profile_d: PackedFloat64Array = PackedFloat64Array()
var _noise_amp: float = 0.0
var _inv_noise_cell: float = 0.0
var _has_cliff: bool = false
var _cliff_z: float = 0.0
var _cliff_half_w: float = 0.0
var _wobble: float = 0.0
var _inv_wobble_cell: float = 0.0
var _abyss_depth: float = 0.0

var _obstacles: Array[Dictionary] = []
# Packed copies of the obstacles for resolve(); every primitive also has a bounding sphere for early-out.
var _sph_c: PackedVector3Array = PackedVector3Array()
var _sph_r: PackedFloat64Array = PackedFloat64Array()
var _cap_a: PackedVector3Array = PackedVector3Array()
var _cap_b: PackedVector3Array = PackedVector3Array()
var _cap_r: PackedFloat64Array = PackedFloat64Array()
var _cap_bc: PackedVector3Array = PackedVector3Array()
var _cap_out: PackedVector3Array = PackedVector3Array()  # push direction for a centre exactly on the axis
var _cap_br: PackedFloat64Array = PackedFloat64Array()
var _box_min: PackedVector3Array = PackedVector3Array()
var _box_max: PackedVector3Array = PackedVector3Array()
var _box_bc: PackedVector3Array = PackedVector3Array()
var _box_br: PackedFloat64Array = PackedFloat64Array()
# Rounded oriented boxes: centre, inner half extents (size / 2 - round), corner radius, local axes (world), bounds.
var _obb_c: PackedVector3Array = PackedVector3Array()
var _obb_h: PackedVector3Array = PackedVector3Array()
var _obb_round: PackedFloat64Array = PackedFloat64Array()
var _obb_ax: PackedVector3Array = PackedVector3Array()
var _obb_ay: PackedVector3Array = PackedVector3Array()
var _obb_az: PackedVector3Array = PackedVector3Array()
var _obb_br: PackedFloat64Array = PackedFloat64Array()
# Broad phase grid (1 = an obstacle may be in reach), _broad_n cells per axis starting at _broad_origin (x and z).
var _broad: PackedByteArray = PackedByteArray()
var _broad_n: int = 0
var _broad_origin: float = 0.0
# Per-cell obstacle lists per kind (CSR): obstacles of cell c are _idx[_off[c] .. _off[c + 1] - 1].
var _sph_off: PackedInt32Array = PackedInt32Array()
var _sph_idx: PackedInt32Array = PackedInt32Array()
var _cap_off: PackedInt32Array = PackedInt32Array()
var _cap_idx: PackedInt32Array = PackedInt32Array()
var _box_off: PackedInt32Array = PackedInt32Array()
var _box_idx: PackedInt32Array = PackedInt32Array()
var _obb_off: PackedInt32Array = PackedInt32Array()
var _obb_idx: PackedInt32Array = PackedInt32Array()
# Set by _push_obstacles when a sweep moved the sphere (the verification in _resolve runs only then).
var _touched: bool = false


## Builds the field from a map record (validated by ContentDB). Missing blocks fall back to a flat floor at
## -depth_m without obstacles, so a partial record never crashes. `baked`: extra obstacle records (the baked dressing
## proxies, ContentDB.get_proxies()); they collide like the map's own and are marked `baked: true` in obstacles().
static func from_map(map: Dictionary, baked: Array = []) -> SeabedField:
	var f := SeabedField.new()
	var depth_m: float = float(map.get("depth_m", 0.0))
	var sb: Dictionary = map.get("seabed", {}) if map.get("seabed") is Dictionary else {}
	f._seed = int(sb.get("seed", 0)) & _HASH_MASK
	f._min_depth = float(sb.get("min_depth_m", 0.0))
	f._max_depth = depth_m
	var profile: Array = sb.get("profile", []) if sb.get("profile") is Array else []
	for p in profile:
		if p is Array and (p as Array).size() == 2:
			f._profile_z.append(float(p[0]))
			f._profile_d.append(float(p[1]))
	if f._profile_z.is_empty():
		f._profile_z.append(0.0)
		f._profile_d.append(depth_m)
	var noise: Dictionary = sb.get("noise", {}) if sb.get("noise") is Dictionary else {}
	var noise_cell: float = float(noise.get("cell_m", 0.0))
	if noise_cell > 0.0:
		f._noise_amp = float(noise.get("amplitude_m", 0.0))
		f._inv_noise_cell = 1.0 / noise_cell
	var cliff: Dictionary = sb.get("cliff", {}) if sb.get("cliff") is Dictionary else {}
	if not cliff.is_empty():
		f._has_cliff = true
		f._cliff_z = float(cliff.get("z_m", 0.0))
		f._cliff_half_w = maxf(float(cliff.get("width_m", 0.0)) * 0.5, 1e-3)
		var wobble_cell: float = float(cliff.get("wobble_cell_m", 0.0))
		if wobble_cell > 0.0:
			f._wobble = float(cliff.get("wobble_m", 0.0))
			f._inv_wobble_cell = 1.0 / wobble_cell
		f._abyss_depth = float(sb.get("abyss_floor_depth_m", depth_m))
	var list: Array = map.get("obstacles", []) if map.get("obstacles") is Array else []
	for o in list:
		if o is Dictionary:
			f._add_obstacle(o, false)
	for o in baked:
		if o is Dictionary:
			f._add_obstacle(o, true)
	f._build_broad_phase(float(map.get("size_m", 0.0)))
	return f


## Seabed height (y, <= 0) at a horizontal position. Deterministic; allocation-free.
func height_at(x: float, z: float) -> float:
	# piecewise-linear depth profile along z (clamped at both ends)
	var n_pts: int = _profile_z.size()
	var depth: float = _profile_d[0]
	if z >= _profile_z[n_pts - 1]:
		depth = _profile_d[n_pts - 1]
	elif z > _profile_z[0]:
		for i in range(1, n_pts):
			if z <= _profile_z[i]:
				var z0: float = _profile_z[i - 1]
				depth = lerpf(_profile_d[i - 1], _profile_d[i], (z - z0) / (_profile_z[i] - z0))
				break
	var n: float = 0.0
	if _noise_amp > 0.0:
		n = (_value_noise_2d(x * _inv_noise_cell, z * _inv_noise_cell, _seed) * 2.0 - 1.0) * _noise_amp
	depth += n
	if _has_cliff:
		var cz: float = _cliff_z
		if _wobble > 0.0:
			cz += (_value_noise_1d(x * _inv_wobble_cell, _seed ^ 0x5bd1e995) * 2.0 - 1.0) * _wobble
		var t: float = smoothstep(cz - _cliff_half_w, cz + _cliff_half_w, z)
		if t > 0.0:
			# the abyss floor only rises with noise, so it never goes below abyss_floor_depth_m
			depth = lerpf(depth, _abyss_depth - (n + _noise_amp) * 0.5, t)
	return -clampf(depth, _min_depth, _max_depth)


## Upward unit normal of the seabed at (x, z) (central differences over NORMAL_EPS_M).
func normal_at(x: float, z: float) -> Vector3:
	var dx: float = height_at(x - NORMAL_EPS_M, z) - height_at(x + NORMAL_EPS_M, z)
	var dz: float = height_at(x, z - NORMAL_EPS_M) - height_at(x, z + NORMAL_EPS_M)
	return Vector3(dx, 2.0 * NORMAL_EPS_M, dz).normalized()


## Obstacle primitives from the map data (authored first, then baked), read-only. Keys: `id`, `tag` (e.g. "arch",
## "boat", "rock"), `kind`, `baked` (true for records passed as `baked` to from_map()) and
## sphere: `center: Vector3`, `radius`; capsule: `a`, `b: Vector3`, `radius`; box (axis-aligned): `center`, `size: Vector3`;
## obb (rounded oriented box): `center`, `size: Vector3` (full extents, local axes), `rot: Quaternion`, `round` (corner
## radius, 0 <= round <= min(size) / 2).
func obstacles() -> Array[Dictionary]:
	return _obstacles


## Pushes a sphere (centre `pos`, `radius`) out of the obstacles and the seabed; returns the new centre.
## Obstacles first, then alternating seabed / obstacle passes until nothing moves (at most RESOLVE_ROUNDS: a
## slope can push back into a pillar standing on it); finally the centre is kept above the seabed surface.
## Allocation-free. Broad phase (same result as the full pass): when no obstacle can reach the sphere anywhere
## the seabed push may move it (see _build_broad_phase), only the seabed is resolved, with one height_at() when
## the centre is clear of the ground. Obstacle passes use the cell lists (radius <= BROAD_MAX_RADIUS_M inside the
## grid), else every obstacle.
func resolve(pos: Vector3, radius: float) -> Vector3:
	if radius <= BROAD_MAX_RADIUS_M and not _obstacle_near(pos.x, pos.z):
		var h: float = height_at(pos.x, pos.z)
		if pos.y - h >= radius * CONTACT_SLACK:
			return pos
		var q: Vector3 = _push_seabed_from(pos, radius, h)
		if q.distance_squared_to(pos) < 1e-14:
			var r: Vector3 = pos
			r.y = maxf(r.y, h)
			return r
		if not _obstacle_near(q.x, q.z):
			q.y = maxf(q.y, height_at(q.x, q.z))
			return q
	return _resolve(pos, radius, true)


## resolve() without the broad phase and the cell lists (every obstacle in every sweep): the reference result the
## cell-indexed pass must reproduce. Tests and tools only; same contract as resolve().
func resolve_reference(pos: Vector3, radius: float) -> Vector3:
	return _resolve(pos, radius, false)


## True when every obstacle surface is at least `clearance` away from `p` (signed distance >= clearance; the seabed is
## not checked). Uses the cell lists for clearance <= BROAD_MAX_RADIUS_M inside the grid (camera boom march).
func obstacle_clear(p: Vector3, clearance: float) -> bool:
	var cell: int = _cell_of(p.x, p.z) if clearance <= BROAD_MAX_RADIUS_M else -1
	if cell < 0:
		for i in _sph_c.size():
			if p.distance_to(_sph_c[i]) - _sph_r[i] < clearance:
				return false
		for i in _cap_a.size():
			if _sdf_cap(p, i) < clearance:
				return false
		for i in _box_min.size():
			if _sdf_box(p, i) < clearance:
				return false
		for i in _obb_c.size():
			if _sdf_obb(p, i) < clearance:
				return false
		return true
	for k in range(_sph_off[cell], _sph_off[cell + 1]):
		var i: int = _sph_idx[k]
		if p.distance_to(_sph_c[i]) - _sph_r[i] < clearance:
			return false
	for k in range(_cap_off[cell], _cap_off[cell + 1]):
		if _sdf_cap(p, _cap_idx[k]) < clearance:
			return false
	for k in range(_box_off[cell], _box_off[cell + 1]):
		if _sdf_box(p, _box_idx[k]) < clearance:
			return false
	for k in range(_obb_off[cell], _obb_off[cell + 1]):
		if _sdf_obb(p, _obb_idx[k]) < clearance:
			return false
	return true


## Obstacles a query in the broad-phase cell of (x, z) checks (sum over kinds; -1 outside the grid = every obstacle).
## Structural guard for tests (bounded narrow phase), not used by the sim.
func cell_candidates(x: float, z: float) -> int:
	var cell: int = _cell_of(x, z)
	if cell < 0:
		return -1
	return (_sph_off[cell + 1] - _sph_off[cell]) + (_cap_off[cell + 1] - _cap_off[cell]) \
		+ (_box_off[cell + 1] - _box_off[cell]) + (_obb_off[cell + 1] - _obb_off[cell])


func _resolve(pos: Vector3, radius: float, use_cells: bool) -> Vector3:
	_touched = false
	var p: Vector3 = _resolve_pass(pos, radius, use_cells)
	if not _touched:
		return p
	for verify_i in VERIFY_PASSES:
		if obstacle_clear(p, radius - PENETRATION_EPS_M) and _push_seabed(p, radius).distance_squared_to(p) < 1e-14:
			break
		p = _resolve_pass(p, radius, use_cells)
	return p


# One obstacle / seabed alternation (see resolve()).
func _resolve_pass(pos: Vector3, radius: float, use_cells: bool) -> Vector3:
	var p: Vector3 = _push_obstacles(pos, radius, use_cells)
	for round_i in RESOLVE_ROUNDS:
		var q: Vector3 = _push_seabed(p, radius)
		if q.distance_squared_to(p) < 1e-14:
			break
		p = _push_obstacles(q, radius, use_cells)
		if p.distance_squared_to(q) < 1e-14:
			break
	p.y = maxf(p.y, height_at(p.x, p.z))
	return p


func _push_seabed(pos: Vector3, radius: float) -> Vector3:
	return _push_seabed_from(pos, radius, height_at(pos.x, pos.z))


# _push_seabed with the seabed height under `pos` already known.
func _push_seabed_from(pos: Vector3, radius: float, h: float) -> Vector3:
	var p: Vector3 = pos
	var gap: float = p.y - h
	if gap >= radius * CONTACT_SLACK:
		return p
	# local plane approximation: signed distance to the slope is gap * n.y
	var nrm: Vector3 = normal_at(p.x, p.z)
	var dist: float = gap * nrm.y
	if dist < radius:
		p += nrm * (radius - dist)
	var floor_y: float = height_at(p.x, p.z) + radius * nrm.y
	if p.y < floor_y:
		p.y = floor_y
	return p


# Up to OBSTACLE_SWEEPS sweeps over the obstacles (the cell lists of the current cell when `use_cells` and the
# radius allows, else all); stops after a sweep that moved nothing.
func _push_obstacles(pos: Vector3, radius: float, use_cells: bool) -> Vector3:
	var p: Vector3 = pos
	var cells: bool = use_cells and radius <= BROAD_MAX_RADIUS_M
	for sweep_i in OBSTACLE_SWEEPS:
		var cell: int = _cell_of(p.x, p.z) if cells else -1
		var q: Vector3 = _sweep_all(p, radius) if cell < 0 else _sweep_cell(p, radius, cell)
		if q.distance_squared_to(p) < 1e-14:
			return q
		_touched = true
		p = q
	return p


func _sweep_all(pos: Vector3, radius: float) -> Vector3:
	var p: Vector3 = pos
	for i in _sph_c.size():
		p = _push_from_point(p, radius, _sph_c[i], _sph_r[i], Vector3.UP)
	for i in _cap_a.size():
		p = _push_cap(p, radius, i)
	for i in _box_min.size():
		p = _push_box(p, radius, i)
	for i in _obb_c.size():
		p = _push_obb(p, radius, i)
	return p


func _sweep_cell(pos: Vector3, radius: float, cell: int) -> Vector3:
	var p: Vector3 = pos
	for k in range(_sph_off[cell], _sph_off[cell + 1]):
		var i: int = _sph_idx[k]
		p = _push_from_point(p, radius, _sph_c[i], _sph_r[i], Vector3.UP)
	for k in range(_cap_off[cell], _cap_off[cell + 1]):
		p = _push_cap(p, radius, _cap_idx[k])
	for k in range(_box_off[cell], _box_off[cell + 1]):
		p = _push_box(p, radius, _box_idx[k])
	for k in range(_obb_off[cell], _obb_off[cell + 1]):
		p = _push_obb(p, radius, _obb_idx[k])
	return p


func _push_cap(p: Vector3, radius: float, i: int) -> Vector3:
	var reach: float = _cap_br[i] + radius
	if p.distance_squared_to(_cap_bc[i]) > reach * reach:
		return p
	var a: Vector3 = _cap_a[i]
	var ab: Vector3 = _cap_b[i] - a
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0) if not ab.is_zero_approx() else 0.0
	return _push_from_point(p, radius, a + ab * t, _cap_r[i], _cap_out[i])


func _push_box(p: Vector3, radius: float, i: int) -> Vector3:
	var reach: float = _box_br[i] + radius
	if p.distance_squared_to(_box_bc[i]) > reach * reach:
		return p
	return _push_from_box(p, radius, _box_min[i], _box_max[i])


# Rounded oriented box: closest point of the inner box (size / 2 - round) in the local frame, pushed to
# radius + round from it. A centre inside the inner box leaves through the nearest face whose exit is not under the
# seabed (like _push_from_box); when every face exit is under the seabed, through the most upward-facing face.
func _push_obb(p: Vector3, radius: float, i: int) -> Vector3:
	var c: Vector3 = _obb_c[i]
	var d: Vector3 = p - c
	var reach_b: float = _obb_br[i] + radius
	if d.length_squared() > reach_b * reach_b:
		return p
	var ax: Vector3 = _obb_ax[i]
	var ay: Vector3 = _obb_ay[i]
	var az: Vector3 = _obb_az[i]
	var ih: Vector3 = _obb_h[i]
	var l := Vector3(d.dot(ax), d.dot(ay), d.dot(az))
	var q: Vector3 = l.clamp(-ih, ih)
	var dl: Vector3 = l - q
	var reach: float = radius + _obb_round[i]
	var d2: float = dl.length_squared()
	if d2 >= reach * reach:
		return p
	if d2 > 1e-12:
		var o: Vector3 = q + dl * (reach / sqrt(d2))
		return c + ax * o.x + ay * o.y + az * o.z
	var out: Vector3 = p
	var best: float = INF
	for axis in 3:
		var col: Vector3 = ax if axis == 0 else (ay if axis == 1 else az)
		for k in 2:
			var sgn: float = 1.0 if k == 1 else -1.0
			var dist: float = ih[axis] - sgn * l[axis]
			if dist >= best:
				continue
			var cand: Vector3 = p + col * (sgn * (ih[axis] + reach) - l[axis])
			if cand.y - radius < height_at(cand.x, cand.z):
				continue
			best = dist
			out = cand
	if best == INF:
		var up_axis: int = 0
		for axis in 3:
			var col_y: float = (ax if axis == 0 else (ay if axis == 1 else az)).y
			var best_y: float = (ax if up_axis == 0 else (ay if up_axis == 1 else az)).y
			if absf(col_y) > absf(best_y):
				up_axis = axis
		var up: Vector3 = ax if up_axis == 0 else (ay if up_axis == 1 else az)
		var s: float = 1.0 if up.y >= 0.0 else -1.0
		out = p + up * (s * (ih[up_axis] + reach) - l[up_axis])
	return out


func _sdf_cap(p: Vector3, i: int) -> float:
	var a: Vector3 = _cap_a[i]
	var ab: Vector3 = _cap_b[i] - a
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0) if not ab.is_zero_approx() else 0.0
	return p.distance_to(a + ab * t) - _cap_r[i]


func _sdf_box(p: Vector3, i: int) -> float:
	var c: Vector3 = _box_bc[i]
	var q: Vector3 = (p - c).abs() - (_box_max[i] - c)
	return q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


func _sdf_obb(p: Vector3, i: int) -> float:
	var d: Vector3 = p - _obb_c[i]
	var l := Vector3(d.dot(_obb_ax[i]), d.dot(_obb_ay[i]), d.dot(_obb_az[i]))
	var q: Vector3 = l.abs() - _obb_h[i]
	return q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0) - _obb_round[i]


# Marks every broad-phase cell whose x/z rectangle comes within (bounding radius + BROAD_MAX_RADIUS_M) of an
# obstacle's bounding-sphere centre and lists the obstacle there (per-kind CSR lists). Without a map size the grid
# stays empty and every query is "near" and takes the full pass.
func _build_broad_phase(size_m: float) -> void:
	if not (size_m > 0.0) or not is_finite(size_m):
		return
	_broad_n = ceili(size_m / BROAD_CELL_M) + 2
	_broad_origin = -size_m * 0.5 - BROAD_CELL_M
	_broad.resize(_broad_n * _broad_n)
	_broad.fill(0)
	var sph: Array = _cell_lists(_sph_c, _sph_r)
	_sph_off = sph[0]
	_sph_idx = sph[1]
	var cap: Array = _cell_lists(_cap_bc, _cap_br)
	_cap_off = cap[0]
	_cap_idx = cap[1]
	var box: Array = _cell_lists(_box_bc, _box_br)
	_box_off = box[0]
	_box_idx = box[1]
	var obb: Array = _cell_lists(_obb_c, _obb_br)
	_obb_off = obb[0]
	_obb_idx = obb[1]


# [offsets (cells + 1), indices] of the obstacles (bounding spheres `centers`, `radii`) per cell; marks _broad.
# Counting sort by cell over an ascending obstacle loop keeps every cell list in ascending index order.
func _cell_lists(centers: PackedVector3Array, radii: PackedFloat64Array) -> Array:
	var ncell: int = _broad_n * _broad_n
	var pair_cell := PackedInt32Array()
	var pair_obj := PackedInt32Array()
	for i in centers.size():
		var c: Vector3 = centers[i]
		var reach: float = radii[i] + BROAD_MAX_RADIUS_M
		var lo_x: int = clampi(floori((c.x - reach - _broad_origin) / BROAD_CELL_M), 0, _broad_n - 1)
		var hi_x: int = clampi(floori((c.x + reach - _broad_origin) / BROAD_CELL_M), 0, _broad_n - 1)
		var lo_z: int = clampi(floori((c.z - reach - _broad_origin) / BROAD_CELL_M), 0, _broad_n - 1)
		var hi_z: int = clampi(floori((c.z + reach - _broad_origin) / BROAD_CELL_M), 0, _broad_n - 1)
		for ix in range(lo_x, hi_x + 1):
			for iz in range(lo_z, hi_z + 1):
				var x0: float = _broad_origin + float(ix) * BROAD_CELL_M
				var z0: float = _broad_origin + float(iz) * BROAD_CELL_M
				var dx: float = maxf(maxf(x0 - c.x, c.x - (x0 + BROAD_CELL_M)), 0.0)
				var dz: float = maxf(maxf(z0 - c.z, c.z - (z0 + BROAD_CELL_M)), 0.0)
				if dx * dx + dz * dz <= reach * reach:
					pair_cell.append(ix * _broad_n + iz)
					pair_obj.append(i)
	var off := PackedInt32Array()
	off.resize(ncell + 1)
	off.fill(0)
	for cell in pair_cell:
		off[cell + 1] += 1
		_broad[cell] = 1
	for k in range(1, ncell + 1):
		off[k] += off[k - 1]
	var idx := PackedInt32Array()
	idx.resize(pair_cell.size())
	var fill: PackedInt32Array = off.slice(0, ncell)
	for j in pair_cell.size():
		var cell: int = pair_cell[j]
		idx[fill[cell]] = pair_obj[j]
		fill[cell] += 1
	return [off, idx]


# Broad-phase cell index of (x, z), or -1 without a grid or outside it.
func _cell_of(x: float, z: float) -> int:
	if _broad_n == 0:
		return -1
	var ix: int = floori((x - _broad_origin) / BROAD_CELL_M)
	var iz: int = floori((z - _broad_origin) / BROAD_CELL_M)
	if ix < 0 or iz < 0 or ix >= _broad_n or iz >= _broad_n:
		return -1
	return ix * _broad_n + iz


# False only when the broad phase proves no obstacle is in reach of (x, z) for radius <= BROAD_MAX_RADIUS_M.
func _obstacle_near(x: float, z: float) -> bool:
	var cell: int = _cell_of(x, z)
	if cell < 0:
		return true
	return _broad[cell] != 0


func _add_obstacle(o: Dictionary, baked: bool) -> void:
	var kind: String = str(o.get("kind", ""))
	var rec: Dictionary = {"id": str(o.get("id", "")), "tag": str(o.get("tag", "")), "kind": kind, "baked": baked}
	match kind:
		"sphere":
			var c: Vector3 = _vec(o.get("center"))
			var r: float = float(o.get("radius", 0.0))
			rec["center"] = c
			rec["radius"] = r
			_sph_c.append(c)
			_sph_r.append(r)
		"capsule":
			var a: Vector3 = _vec(o.get("a"))
			var b: Vector3 = _vec(o.get("b"))
			var r: float = float(o.get("radius", 0.0))
			rec["a"] = a
			rec["b"] = b
			rec["radius"] = r
			_cap_a.append(a)
			_cap_b.append(b)
			_cap_r.append(r)
			_cap_bc.append((a + b) * 0.5)
			var axis: Vector3 = b - a
			var side: Vector3 = axis.cross(Vector3.UP)
			if side.length_squared() < 1e-12 * maxf(axis.length_squared(), 1.0):
				side = axis.cross(Vector3.RIGHT)  # vertical capsule (pillar): push sideways, never along the axis
			_cap_out.append(side.normalized() if not side.is_zero_approx() else Vector3.UP)
			_cap_br.append(a.distance_to(b) * 0.5 + r)
		"box":
			var c: Vector3 = _vec(o.get("center"))
			var size: Vector3 = _vec(o.get("size")).abs()
			rec["center"] = c
			rec["size"] = size
			_box_min.append(c - size * 0.5)
			_box_max.append(c + size * 0.5)
			_box_bc.append(c)
			_box_br.append(size.length() * 0.5)
		"obb":
			var c: Vector3 = _vec(o.get("center"))
			var size: Vector3 = _vec(o.get("size")).abs()
			var rot: Quaternion = _quat(o.get("rot"))
			var rnd: float = clampf(float(o.get("round", 0.0)), 0.0, minf(size.x, minf(size.y, size.z)) * 0.5)
			rec["center"] = c
			rec["size"] = size
			rec["rot"] = rot
			rec["round"] = rnd
			var basis := Basis(rot)
			_obb_c.append(c)
			_obb_h.append(size * 0.5 - Vector3.ONE * rnd)
			_obb_round.append(rnd)
			_obb_ax.append(basis.x)
			_obb_ay.append(basis.y)
			_obb_az.append(basis.z)
			_obb_br.append(size.length() * 0.5)
		_:
			return
	_obstacles.append(rec)


static func _push_from_point(p: Vector3, radius: float, c: Vector3, r: float, fallback: Vector3) -> Vector3:
	var reach: float = r + radius
	var d: Vector3 = p - c
	var d2: float = d.length_squared()
	if d2 >= reach * reach:
		return p
	if d2 < 1e-12:
		return c + fallback * reach
	return c + d * (reach / sqrt(d2))


func _push_from_box(p: Vector3, radius: float, lo: Vector3, hi: Vector3) -> Vector3:
	var q: Vector3 = p.clamp(lo, hi)
	var d: Vector3 = p - q
	var d2: float = d.length_squared()
	if d2 >= radius * radius:
		return p
	if d2 > 1e-12:
		return q + d * (radius / sqrt(d2))
	# centre inside the box: leave through the nearest face whose exit is not under the seabed
	# (boxes such as the boat rest on the seabed; exiting downward would be pushed straight back in)
	var out: Vector3 = p
	var best: float = INF
	for axis in 3:
		for k in 2:
			var to_hi: bool = k == 1
			var dist: float = hi[axis] - p[axis] if to_hi else p[axis] - lo[axis]
			if dist >= best:
				continue
			var cand: Vector3 = p
			cand[axis] = hi[axis] + radius if to_hi else lo[axis] - radius
			if cand.y - radius < height_at(cand.x, cand.z):
				continue
			best = dist
			out = cand
	if best == INF:
		out = p
		out.y = hi.y + radius
	return out


## [x, y, z, w] -> normalized Quaternion; identity when missing, malformed or of zero length.
static func _quat(v: Variant) -> Quaternion:
	if v is Array and (v as Array).size() == 4:
		var q := Quaternion(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
		if q.length_squared() > 1e-12:
			return q.normalized()
	return Quaternion.IDENTITY


static func _vec(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


## Integer lattice hash -> [0, 1). 32-bit arithmetic kept below int64 overflow by masking.
## The noise functions below inline the same hash (call overhead dominates height_at() in GDScript).
static func _hash01(ix: int, iz: int, s: int) -> float:
	var h: int = ((ix * 73856093) ^ (iz * 19349663) ^ s) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h ^= h >> 16
	return float(h) * _INV_2_32


## Smooth value noise on the integer lattice, [0, 1). Inlined _hash01 for the 4 corners.
static func _value_noise_2d(fx: float, fz: float, s: int) -> float:
	var ix: int = floori(fx)
	var iz: int = floori(fz)
	var tx: float = fx - float(ix)
	var tz: float = fz - float(iz)
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	var hx0: int = ix * 73856093
	var hx1: int = hx0 + 73856093
	var hz0: int = (iz * 19349663) ^ s
	var hz1: int = ((iz + 1) * 19349663) ^ s
	var h: int = (hx0 ^ hz0) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	var c00: float = float(h ^ (h >> 16)) * _INV_2_32
	h = (hx1 ^ hz0) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	var c10: float = float(h ^ (h >> 16)) * _INV_2_32
	h = (hx0 ^ hz1) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	var c01: float = float(h ^ (h >> 16)) * _INV_2_32
	h = (hx1 ^ hz1) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	h = ((h ^ (h >> 16)) * 0x45d9f3b) & _HASH_MASK
	var c11: float = float(h ^ (h >> 16)) * _INV_2_32
	return lerpf(lerpf(c00, c10, tx), lerpf(c01, c11, tx), tz)


static func _value_noise_1d(fx: float, s: int) -> float:
	var ix: int = floori(fx)
	var t: float = fx - float(ix)
	t = t * t * (3.0 - 2.0 * t)
	return lerpf(_hash01(ix, 0, s), _hash01(ix + 1, 0, s), t)
