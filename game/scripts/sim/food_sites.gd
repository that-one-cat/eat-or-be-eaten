class_name FoodSites
extends RefCounted
## Baked food sites (food task X1): eggs, snails and the edible decor (giant clam, starfish, cone shells) as static
## points with sparse state instead of SimEntity (CLAUDE.md rules 1, 3, 4, 7). Built from the baked records of
## `maps/<map_id>_food.json` (tools/dressing/bake_food.gd, FoodPlacement.derive; ContentDB.get_food_sites) and the
## food type records `data/food/<type>.json` (ContentDB.get_food). Site ids are the record indices (dense, bake order).
##
## Per type (data): `kind` soft (swallowed whole by a player for which SimRules.can_swallow(length, type length_m,
## swallow_ratio or rules.swallow_ratio) holds; a too-small player cannot eat it, its bite does nothing) or hard (bitten:
## max HP = SimRules.creature_max_hp(base_hp, length_m) x hp_mult, the bite that brings it to 0 eats it), `xp` (credit,
## x xp_band_mult[player band - 1], then the rules.xp_falloff against length_m), `hunger_xp` (hunger credit), `respawn_s`
## (eaten -> alive again exactly that many seconds later, rounded to ticks) and `regen_s` (a damaged hard site is back to
## full HP that long after the last bite; 0 = never, only the respawn heals).
## State is lazy and sparse: only damaged or eaten sites hold state (`_touched`, ascending), so a site costs nothing per
## tick; respawns are a queue sorted by (tick, site), so SimWorld emits SITE_RESPAWNED in the respawn tick without a scan.
## Eating and biting are SimWorld's (players only, see its class doc); this class keeps the numbers and the state.
## Spatial lookup: a static bucket grid of cell_m (the SimWorld grid cell) over the site centres.

## Respawn queue keys: tick << QUEUE_SHIFT | site (sites < 2^QUEUE_SHIFT).
const QUEUE_SHIFT: int = 21
const DEFAULT_BASE_HP: float = 100.0

## The owning world's current tick (SimWorld keeps it equal to world.tick); the default of the read accessors.
var now_tick: int = 0

var _type_ids: Array[StringName] = []
var _type_soft: PackedByteArray = PackedByteArray()
var _type_len: PackedFloat64Array = PackedFloat64Array()
var _type_swallow: PackedFloat64Array = PackedFloat64Array()  # -1 = rules.swallow_ratio
var _type_xp: PackedFloat64Array = PackedFloat64Array()
var _type_hunger_xp: PackedFloat64Array = PackedFloat64Array()
var _type_band_mult: Array[PackedFloat64Array] = []
var _type_max_hp: PackedFloat64Array = PackedFloat64Array()
var _type_respawn: PackedInt32Array = PackedInt32Array()  # ticks
var _type_regen: PackedInt32Array = PackedInt32Array()  # ticks, 0 = never

var _site_type: PackedInt32Array = PackedInt32Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _radius: PackedFloat64Array = PackedFloat64Array()
var _max_radius: float = 0.0

var _hp: PackedFloat64Array = PackedFloat64Array()  # HP after the last bite (valid while _hit_tick >= 0)
var _hit_tick: PackedInt32Array = PackedInt32Array()  # tick of the last bite, -1 = undamaged
var _dead_until: PackedInt32Array = PackedInt32Array()  # respawn tick, -1 = alive
var _touched: PackedInt32Array = PackedInt32Array()  # sites with state, ascending
var _queue: PackedInt64Array = PackedInt64Array()  # respawn queue, ascending keys

var _inv_cell: float = 1.0
var _cells: Dictionary[Vector3i, PackedInt32Array] = {}  # cell -> sites (ascending)


## Sites of map `map_id` from its baked food file; null without content, food file or valid sites.
static func create(content: ContentDB, map_id: StringName, cell_m: float) -> FoodSites:
	if content == null:
		return null
	var records: Array = content.get_food_sites(map_id)
	if records.is_empty():
		return null
	return from_records(content, records, cell_m)


## Sites from in-memory records ({type, pos: [x, y, z], radius}; the baked file `sites` entries, extra keys ignored).
## Records with an unknown type or bad numbers are skipped (ContentDB reports them for the baked file). Null when none
## is left.
static func from_records(content: ContentDB, records: Array, cell_m: float) -> FoodSites:
	if content == null:
		return null
	var f := FoodSites.new()
	f._inv_cell = 1.0 / (cell_m if cell_m > 0.0 else 8.0)
	var type_index: Dictionary[StringName, int] = {}
	for r: Variant in records:
		if not (r is Dictionary):
			continue
		var rec: Dictionary = r
		var tid := StringName(str(rec.get("type", "")))
		var p: Variant = rec.get("pos")
		if not (p is Array) or (p as Array).size() != 3:
			continue
		if not type_index.has(tid):
			var t: Dictionary = content.get_food(tid)
			if t.is_empty():
				continue
			type_index[tid] = f._add_type(tid, t)
		var pos := Vector3(float(p[0]), float(p[1]), float(p[2]))
		var radius: float = float(rec.get("radius", 0.0))
		if not pos.is_finite() or not (radius > 0.0 and is_finite(radius)):
			continue
		var i: int = f._site_type.size()
		f._site_type.append(type_index[tid])
		f._pos.append(pos)
		f._radius.append(radius)
		f._max_radius = maxf(f._max_radius, radius)
		var key: Vector3i = f._cell_of(pos)
		var bucket: PackedInt32Array = f._cells.get(key, PackedInt32Array())
		bucket.append(i)
		f._cells[key] = bucket
	if f._site_type.is_empty():
		return null
	var n: int = f._site_type.size()
	f._hp.resize(n)
	f._hit_tick.resize(n)
	f._hit_tick.fill(-1)
	f._dead_until.resize(n)
	f._dead_until.fill(-1)
	return f


func site_count() -> int:
	return _site_type.size()


## Food type id of site `i` (data/food/<id>.json).
func site_type(i: int) -> StringName:
	return _type_ids[_site_type[i]]


## Site centre (world metres): the point the mouth / bite cones test against.
func site_pos(i: int) -> Vector3:
	return _pos[i]


## Radius added to the swallow / bite reach (like a creature's collision radius).
func site_radius(i: int) -> float:
	return _radius[i]


## Largest site radius (bounds the cone queries).
func max_radius() -> float:
	return _max_radius


## False from the tick the site is eaten until its respawn tick (exclusive).
func site_alive(i: int, at_tick: int = -1) -> bool:
	var d: int = _dead_until[i]
	return d < 0 or (now_tick if at_tick < 0 else at_tick) >= d


## Current HP: 0 while eaten, max HP when undamaged or regen_s after the last bite, else the HP after that bite.
func site_hp(i: int, at_tick: int = -1) -> float:
	var t: int = now_tick if at_tick < 0 else at_tick
	if not site_alive(i, t):
		return 0.0
	return _type_max_hp[_site_type[i]] if not _damaged(i, t) else _hp[i]


## Max HP (SimRules.creature_max_hp(base_hp, length_m) x hp_mult of the type; soft sites have it too, unused).
func site_max_hp(i: int) -> float:
	return _type_max_hp[_site_type[i]]


## True for a soft (swallowed) site, false for a hard (bitten) one.
func site_soft(i: int) -> bool:
	return _type_soft[_site_type[i]] == 1


## Type numbers the eat rules need (SimWorld): nominal length, swallow ratio override (-1 = rules), XP, hunger XP,
## the XP multiplier for player `band` (1-based, clamped to the listed bands, 1 without a list).
func site_length(i: int) -> float:
	return _type_len[_site_type[i]]


func site_swallow_ratio(i: int) -> float:
	return _type_swallow[_site_type[i]]


func site_xp(i: int) -> float:
	return _type_xp[_site_type[i]]


func site_hunger_xp(i: int) -> float:
	return _type_hunger_xp[_site_type[i]]


func site_band_mult(i: int, band: int) -> float:
	var m: PackedFloat64Array = _type_band_mult[_site_type[i]]
	if m.is_empty():
		return 1.0
	return m[clampi(band - 1, 0, m.size() - 1)]


## Clears `out` and appends the live sites whose centre is within `radius` of `center`, ascending id (no allocation
## once `out` has grown).
func sites_near_into(center: Vector3, radius: float, out: PackedInt32Array) -> void:
	out.clear()
	if not (radius >= 0.0) or not center.is_finite():
		return
	var lo: Vector3i = _cell_of(center - Vector3.ONE * radius)
	var hi: Vector3i = _cell_of(center + Vector3.ONE * radius)
	var r2: float = radius * radius
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var bucket: Variant = _cells.get(Vector3i(x, y, z))
				if bucket == null:
					continue
				for i: int in (bucket as PackedInt32Array):
					if _pos[i].distance_squared_to(center) <= r2 and site_alive(i):
						out.append(i)
	out.sort()


## Damages hard site `i` by `damage` at `at_tick`; returns the HP left (<= 0: the caller eats it with eat()).
func bite(i: int, damage: float, at_tick: int) -> float:
	var hp: float = site_hp(i, at_tick) - maxf(damage, 0.0)
	_touch(i)
	_hp[i] = hp
	_hit_tick[i] = at_tick
	return hp


## Site `i` is eaten at `at_tick`: dead until at_tick + respawn ticks (queued for SITE_RESPAWNED).
func eat(i: int, at_tick: int) -> void:
	_touch(i)
	var back: int = at_tick + _type_respawn[_site_type[i]]
	_dead_until[i] = back
	_hit_tick[i] = -1
	var key: int = (back << QUEUE_SHIFT) | i
	_queue.insert(_queue.bsearch(key), key)


## Clears `out` and moves every queued respawn due at or before `at_tick` into it (sites, respawn order).
func pop_respawns_into(at_tick: int, out: PackedInt32Array) -> void:
	out.clear()
	var n: int = 0
	while n < _queue.size() and (_queue[n] >> QUEUE_SHIFT) <= at_tick:
		out.append(_queue[n] & ((1 << QUEUE_SHIFT) - 1))
		n += 1
	if n > 0:
		_queue = _queue.slice(n)


## Forgets the state of sites that are alive and undamaged again at `at_tick` (their reads are the same either way).
func prune(at_tick: int) -> void:
	var keep: int = 0
	for k in _touched.size():
		var i: int = _touched[k]
		if site_alive(i, at_tick) and not _damaged(i, at_tick):
			_dead_until[i] = -1
			_hit_tick[i] = -1
		else:
			_touched[keep] = i
			keep += 1
	_touched.resize(keep)


## Appends every site that is eaten or damaged at `at_tick` (ascending: id, respawn tick or -1, HP quantised to 1e-6)
## to a state hash buffer.
func write_state(buf: StreamPeerBuffer, at_tick: int) -> void:
	var n: int = 0
	for i in _touched:
		if not site_alive(i, at_tick) or _damaged(i, at_tick):
			n += 1
	buf.put_32(n)
	for i in _touched:
		var alive: bool = site_alive(i, at_tick)
		if alive and not _damaged(i, at_tick):
			continue
		buf.put_32(i)
		buf.put_64(-1 if alive else _dead_until[i])
		buf.put_64(roundi(site_hp(i, at_tick) * 1.0e6))


# ------------------------------------------------------------------ internals

func _add_type(tid: StringName, t: Dictionary) -> int:
	var length: float = float(t.get("length_m", 0.0))
	_type_ids.append(tid)
	_type_soft.append(1 if str(t.get("kind", "")) == "soft" else 0)
	_type_len.append(length)
	_type_swallow.append(float(t["swallow_ratio"]) if t.has("swallow_ratio") else -1.0)
	var xp: float = float(t.get("xp", 0.0))
	_type_xp.append(xp)
	_type_hunger_xp.append(float(t.get("hunger_xp", xp)))
	var mult := PackedFloat64Array()
	if t.get("xp_band_mult") is Array:
		for m: Variant in (t["xp_band_mult"] as Array):
			mult.append(float(m))
	_type_band_mult.append(mult)
	var hp: float = SimRules.creature_max_hp(float(t.get("base_hp", DEFAULT_BASE_HP)), length) * float(t.get("hp_mult", 1.0))
	_type_max_hp.append(hp if hp > 0.0 and is_finite(hp) else 1.0)
	_type_respawn.append(maxi(roundi(float(t.get("respawn_s", 0.0)) * SimWorld.TICK_RATE), 1))
	_type_regen.append(maxi(roundi(float(t.get("regen_s", 0.0)) * SimWorld.TICK_RATE), 0))
	return _type_ids.size() - 1


# Damaged (below max HP) at `at_tick`: bitten and not yet healed by regen_s.
func _damaged(i: int, at_tick: int) -> bool:
	var h: int = _hit_tick[i]
	if h < 0:
		return false
	var regen: int = _type_regen[_site_type[i]]
	return regen <= 0 or at_tick - h < regen


func _touch(i: int) -> void:
	var k: int = _touched.bsearch(i)
	if k >= _touched.size() or _touched[k] != i:
		_touched.insert(k, i)


func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x * _inv_cell), floori(p.y * _inv_cell), floori(p.z * _inv_cell))
