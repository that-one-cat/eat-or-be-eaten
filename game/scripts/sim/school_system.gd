class_name SchoolSystem
extends RefCounted
## Seeded NPC schools (CLAUDE.md rules 3 and 4): the sim keeps only school-level state, every position is a pure
## function of (school seed, tick), and every state change is a SimEvent that apply_event() replays.
##
## Built from the map `schools` records (map order; one record makes `count` schools, ids dense from 0) and
## rules `schools` (shape and motion). Per school: seed = mix(world seed, id); size = seeded in
## [size_min, size_max]; alive[k] = 1 while member k is in the ambient (school) form, 0 while it is promoted (an
## interactive SimEntity, `promoted[k]` = entity id) or eaten and waiting for its respawn (pending_respawn /
## pending_member, due ticks ascending).
##
## Centre path (center_at): a closed seeded Lissajous loop around a base point inside the zone,
##   x = bx + ax1 sin(w1 t + p1) + ax2 sin(w2 t + p2),  z = bz + az1 sin(w1 t + p1 + PI/2) + az2 sin(w2 t + p4),
## t = tick / TICK_RATE, amplitudes ~ rules schools.path_radius_m, w1 chosen so the mean speed is the species cruise
## speed (swim_speed_mps x behaviour.wander_speed_frac). x/z are clamped to the zone box inset by the school bound
## (and kept out of the map's soft-current margin); y = lerp(floor, ceiling, clamp(yf + 0.15 sin(w3 t + p5), 0, 1))
## between the seabed (height_at + clearance + half height) and the surface (-(clearance + half height)), also
## inside the zone's y range. No integrated history: any peer recomputes any school at any tick.
## heading_at / velocity_at are the finite difference to the next tick (heading falls back to -Z when still).
##
## Member offset (member_offset): slot(k) + wobble(k, t), rotated about +Y by the school yaw
## (yaw = atan2(-heading.x, -heading.z), the SimEntity.yaw_deg convention). slot(k) is a seeded point in an
## ellipsoid with radii (R, R * height_ratio, R), R = radius_per_sqrt_member_m * sqrt(size), uniform in volume.
## wobble(k, t) = wobble_m * (sin(w t + a_k), 0.5 sin(1.7 w t + b_k), cos(w t + a_k)), w = TAU * wobble_hz,
## a_k / b_k = TAU * hash01(seed, k, salt) (see member_wobble_phases); the shader may approximate it.
##
## The sim never moves ambient members: TierManager promotes members near players into SimEntities (placed at the
## exact sim slot) and demotes them back. Promoted entities carry SimEntity.school_id / school_member.

const _SALT_SIZE: int = 1
const _SALT_PATH: int = 2
const _SALT_SLOT: int = 3
const _SALT_LEN: int = 4
const _SALT_WOBBLE: int = 5
## Path constants (shape of the loop; the scale comes from data).
const _AMP_MAIN: float = 0.7
const _AMP_SECOND: float = 0.3
const _Y_SWAY: float = 0.15
const _WOBBLE_Y: float = 0.5
const _WOBBLE_Y_FREQ: float = 1.7
## Mean speed of the loop relative to w1 * A (the second harmonic adds about 30 percent).
const _SPEED_FACTOR: float = 1.3


## One school (read-only outside SchoolSystem; mutate only through apply_event).
class School:
	extends RefCounted
	var id: int = 0
	var species_id: StringName = &""
	var zone_index: int = -1
	var size: int = 0
	var seed: int = 0
	## 1 = member present in the school form, 0 = promoted or eaten.
	var alive: PackedByteArray = PackedByteArray()
	## Due ticks of pending respawns (ascending) and the member index of each.
	var pending_respawn: PackedInt32Array = PackedInt32Array()
	var pending_member: PackedInt32Array = PackedInt32Array()
	## Member k -> entity id while promoted.
	var promoted: Dictionary[int, int] = {}
	var respawn_ticks: int = 0
	var length_min: float = 0.1
	var length_max: float = 0.1
	## Slot ellipsoid radius R and bounding radius of every member around the centre (R + wobble).
	var radius_m: float = 0.0
	var bound_m: float = 0.0
	# path parameters (pure inputs of center_at)
	var _base: Vector2 = Vector2.ZERO
	var _amp: PackedFloat64Array = PackedFloat64Array()  # ax1, ax2, az1, az2
	var _w: PackedFloat64Array = PackedFloat64Array()  # w1, w2, w3 (rad/s)
	var _ph: PackedFloat64Array = PackedFloat64Array()  # p1, p2, p4, p5
	var _y_frac: float = 0.5
	var _lo: Vector3 = Vector3.ZERO  # centre clamp box
	var _hi: Vector3 = Vector3.ZERO
	var _y_margin: float = 0.0  # clearance + half height above the seabed / below the surface
	var _slots: PackedVector3Array = PackedVector3Array()
	var _wob_a: PackedFloat64Array = PackedFloat64Array()
	var _wob_b: PackedFloat64Array = PackedFloat64Array()
	var _lengths: PackedFloat64Array = PackedFloat64Array()
	# one-entry memo of the centre (center_at is called many times per tick for the same school)
	var _memo_tick: int = -2147483648
	var _memo_c: Vector3 = Vector3.ZERO
	var _memo_h_tick: int = -2147483648
	var _memo_yaw: float = 0.0
	var _memo_h: Vector3 = Vector3.FORWARD


var _schools: Array[School] = []
var _seabed: SeabedField = null
var _wobble_m: float = 0.0
var _wobble_w: float = 0.0
var _height_ratio: float = 1.0
var _promoted_total: int = 0


## Builds the schools of `map` (null map / no `schools` key: no schools). `seabed` may be null (flat y range).
static func create(world_seed: int, content: ContentDB, map: Dictionary, seabed: SeabedField) -> SchoolSystem:
	var s := SchoolSystem.new()
	s._seabed = seabed
	if content == null or map.is_empty():
		return s
	var rules: Dictionary = content.rules().get("schools", {}) if content.rules().get("schools") is Dictionary else {}
	var radius_per: float = float(rules.get("radius_per_sqrt_member_m", 0.5))
	var path_r: float = float(rules.get("path_radius_m", 30.0))
	s._height_ratio = float(rules.get("height_ratio", 0.5))
	s._wobble_m = float(rules.get("wobble_m", 0.0))
	s._wobble_w = TAU * float(rules.get("wobble_hz", 0.0))
	var zones: Array = map.get("zones", []) if map.get("zones") is Array else []
	var zone_ids: Array[String] = []
	for z in zones:
		zone_ids.append(str((z as Dictionary).get("id")))
	var half: float = float(map.get("size_m", 0.0)) * 0.5
	var bounds: Dictionary = map.get("bounds", {}) if map.get("bounds") is Dictionary else {}
	var edge: float = half - float(bounds.get("soft_margin_m", 0.0))
	var records: Array = map.get("schools", []) if map.get("schools") is Array else []
	for rec_v in records:
		var rec: Dictionary = rec_v
		var species_id := StringName(str(rec.get("species_id")))
		var sp: Dictionary = content.get_species(species_id)
		var zi: int = zone_ids.find(str(rec.get("zone_id")))
		if sp.is_empty() or zi < 0:
			continue
		var behaviour: Dictionary = sp.get("behaviour", {}) if sp.get("behaviour") is Dictionary else {}
		var cruise: float = maxf(float(sp.get("swim_speed_mps", 1.0)) * float(behaviour.get("wander_speed_frac", 0.5)), 0.05)
		var clearance: float = float(behaviour.get("seabed_clearance_m", 0.0))
		var lengths: Dictionary = sp.get("length_m", {}) if sp.get("length_m") is Dictionary else {}
		var aabb: Dictionary = (zones[zi] as Dictionary).get("aabb", {})
		var zlo := Vector3(float(aabb["min"][0]), float(aabb["min"][1]), float(aabb["min"][2]))
		var zhi := Vector3(float(aabb["max"][0]), float(aabb["max"][1]), float(aabb["max"][2]))
		var respawn_s: float = float(rec.get("respawn_s", 0.0))
		for n in int(rec.get("count", 0)):
			var sc := School.new()
			sc.id = s._schools.size()
			sc.species_id = species_id
			sc.zone_index = zi
			sc.seed = _mix(world_seed, sc.id, 0)
			var size_min: int = int(rec.get("size_min", 1))
			var size_max: int = maxi(int(rec.get("size_max", size_min)), size_min)
			sc.size = size_min + mini(floori(hash01(sc.seed, 0, _SALT_SIZE) * float(size_max - size_min + 1)), size_max - size_min)
			sc.respawn_ticks = maxi(1, roundi(respawn_s * SimWorld.TICK_RATE)) if respawn_s > 0.0 else 0
			sc.length_min = float(lengths.get("min", 0.1))
			sc.length_max = float(lengths.get("max", sc.length_min))
			sc.radius_m = radius_per * sqrt(float(sc.size))
			sc.bound_m = sc.radius_m + s._wobble_m * 1.5
			sc._y_margin = clearance + sc.radius_m * s._height_ratio + s._wobble_m
			s._init_path(sc, zlo, zhi, edge, path_r, cruise)
			s._init_members(sc)
			s._schools.append(sc)
	return s


## Number of schools (ids are 0 .. school_count() - 1).
func school_count() -> int:
	return _schools.size()


func get_school(id: int) -> School:
	return _schools[id] if id >= 0 and id < _schools.size() else null


## Promoted members over all schools.
func promoted_count() -> int:
	return _promoted_total


## Members currently in the school form (alive[k] == 1).
func alive_count(school: School) -> int:
	return school.alive.count(1)


## School centre at `tick` (pure function of the school seed and the tick; see the class doc).
func center_at(school: School, at_tick: int) -> Vector3:
	if at_tick == school._memo_tick:
		return school._memo_c
	var c: Vector3 = _center(school, at_tick)
	school._memo_tick = at_tick
	school._memo_c = c
	return c


## Unit swim direction of the school at `tick` (towards the centre at tick + 1; -Z when the centre does not move).
func heading_at(school: School, at_tick: int) -> Vector3:
	_heading_memo(school, at_tick)
	return school._memo_h


## Centre velocity at `tick`, m/s (finite difference to tick + 1).
func velocity_at(school: School, at_tick: int) -> Vector3:
	return (_center(school, at_tick + 1) - center_at(school, at_tick)) * float(SimWorld.TICK_RATE)


## Offset of member k from the school centre at `tick`, world axes (slot + wobble, rotated by the school yaw).
func member_offset(school: School, k: int, at_tick: int) -> Vector3:
	_heading_memo(school, at_tick)
	return (school._slots[k] + member_wobble(school, k, at_tick)).rotated(Vector3.UP, school._memo_yaw)


## Member k position at `tick` (centre + member_offset).
func member_position(school: School, k: int, at_tick: int) -> Vector3:
	return center_at(school, at_tick) + member_offset(school, k, at_tick)


## Seeded slot of member k in the school frame (-Z forward, no wobble, not rotated).
func member_slot(school: School, k: int) -> Vector3:
	return school._slots[k]


## Wobble of member k at `tick` in the school frame (formula in the class doc).
func member_wobble(school: School, k: int, at_tick: int) -> Vector3:
	if _wobble_m <= 0.0:
		return Vector3.ZERO
	var t: float = float(at_tick) * SimWorld.TICK_DT
	var a: float = _wobble_w * t + school._wob_a[k]
	return Vector3(sin(a), _WOBBLE_Y * sin(_WOBBLE_Y_FREQ * _wobble_w * t + school._wob_b[k]), cos(a)) * _wobble_m


## Wobble phases (a_k, b_k) of member k, radians, for the shader.
func member_wobble_phases(school: School, k: int) -> Vector2:
	return Vector2(school._wob_a[k], school._wob_b[k])


## Seeded body length of member k (inside the species length range).
func member_length(school: School, k: int) -> float:
	return school._lengths[k]


## Wobble amplitude (m) and angular frequency (rad/s) shared by all schools (rules schools.wobble_m / wobble_hz).
func wobble_amplitude() -> float:
	return _wobble_m


func wobble_angular_speed() -> float:
	return _wobble_w


## Applies one school event (the authoritative path calls this right after emitting; a replica replays the event
## list in order and ends with the same alive / pending / promoted state). Other event types are ignored.
func apply_event(ev: SimEvent) -> void:
	if ev.type < SimEvent.Type.SCHOOL_MEMBER_PROMOTED or ev.type > SimEvent.Type.SCHOOL_MEMBER_RESPAWNED:
		return
	var sc: School = get_school(int(ev.data.get("school", -1)))
	var k: int = int(ev.data.get("k", -1))
	if sc == null or k < 0 or k >= sc.size:
		return
	match ev.type:
		SimEvent.Type.SCHOOL_MEMBER_PROMOTED:
			sc.alive[k] = 0
			if not sc.promoted.has(k):
				_promoted_total += 1
			sc.promoted[k] = int(ev.data.get("entity", ev.entity_id))
		SimEvent.Type.SCHOOL_MEMBER_DEMOTED:
			if sc.promoted.erase(k):
				_promoted_total -= 1
			sc.alive[k] = 1
		SimEvent.Type.SCHOOL_MEMBER_EATEN:
			if sc.promoted.erase(k):
				_promoted_total -= 1
			sc.alive[k] = 0
			if sc.respawn_ticks > 0:
				sc.pending_respawn.append(ev.tick + sc.respawn_ticks)
				sc.pending_member.append(k)
		SimEvent.Type.SCHOOL_MEMBER_RESPAWNED:
			var i: int = sc.pending_member.find(k)
			if i >= 0:
				sc.pending_respawn.remove_at(i)
				sc.pending_member.remove_at(i)
			sc.alive[k] = 1


## Respawns every member whose respawn is due (SCHOOL_MEMBER_RESPAWNED each, school id ascending). Called by
## TierManager at the start of the schools phase.
func tick_respawns(world: SimWorld) -> void:
	for sc in _schools:
		while not sc.pending_respawn.is_empty() and sc.pending_respawn[0] <= world.tick:
			_emit(world, SimEvent.Type.SCHOOL_MEMBER_RESPAWNED, -1, -1, sc.id, sc.pending_member[0])


## A promoted member entity is gone for good (eaten, killed or removed): SCHOOL_MEMBER_EATEN, respawn scheduled,
## the entity's back-reference cleared. Called by SimWorld when such an entity is removed.
func member_lost(world: SimWorld, e: SimEntity, by_id: int) -> void:
	var sid: int = e.school_id
	var k: int = e.school_member
	e.school_id = -1
	e.school_member = -1
	if get_school(sid) != null:
		_emit(world, SimEvent.Type.SCHOOL_MEMBER_EATEN, e.id, by_id, sid, k)


## Appends the school state (alive bits, pending respawns, promoted pairs ascending by k) to a state hash buffer.
func write_state(buf: StreamPeerBuffer) -> void:
	buf.put_32(_schools.size())
	for sc in _schools:
		buf.put_32(sc.size)
		buf.put_data(sc.alive)
		buf.put_32(sc.pending_respawn.size())
		for i in sc.pending_respawn.size():
			buf.put_32(sc.pending_respawn[i])
			buf.put_32(sc.pending_member[i])
		var keys: Array = sc.promoted.keys()
		keys.sort()
		buf.put_32(keys.size())
		for k: int in keys:
			buf.put_32(k)
			buf.put_64(sc.promoted[k])


## Deterministic value in [0, 1) from (seed, k, salt) (same mixing as the rest of the sim; the shader may reuse it).
static func hash01(seed: int, k: int, salt: int) -> float:
	return float(_mix(seed, k, salt) & 0xFFFFFF) / 16777216.0


# splitmix64-style mixing; logical shifts emulated with masks (GDScript >> is arithmetic).
static func _mix(a: int, b: int, salt: int) -> int:
	var h: int = a * 0x632BE59BD9B4E019 + b * 0x3C6EF372FE94F82B + (salt + 1) * 0x1B873593A54FF53A
	h = (h ^ ((h >> 30) & 0x3FFFFFFFF)) * 0x3F58476D1CE4E5B9
	h = (h ^ ((h >> 27) & 0x1FFFFFFFFF)) * 0x14D049BB133111EB
	return h ^ ((h >> 31) & 0x1FFFFFFFF)


func _emit(world: SimWorld, type: SimEvent.Type, entity_id: int, other_id: int, school_id: int, k: int) -> void:
	var ev: SimEvent = world.emit_event(type, entity_id, other_id)
	ev.data = {"school": school_id, "k": k}
	apply_event(ev)


func _center(sc: School, at_tick: int) -> Vector3:
	var t: float = float(at_tick) * SimWorld.TICK_DT
	var a1: float = sc._w[0] * t + sc._ph[0]
	var a2: float = sc._w[1] * t
	var x: float = sc._base.x + sc._amp[0] * sin(a1) + sc._amp[1] * sin(a2 + sc._ph[1])
	var z: float = sc._base.y + sc._amp[2] * cos(a1) + sc._amp[3] * sin(a2 + sc._ph[2])
	x = clampf(x, sc._lo.x, sc._hi.x)
	z = clampf(z, sc._lo.z, sc._hi.z)
	var y_lo: float = sc._lo.y
	if _seabed != null:
		y_lo = maxf(y_lo, _seabed.height_at(x, z) + sc._y_margin)
	var y_hi: float = minf(sc._hi.y, -sc._y_margin)
	var f: float = clampf(sc._y_frac + _Y_SWAY * sin(sc._w[2] * t + sc._ph[3]), 0.0, 1.0)
	var y: float = lerpf(y_lo, y_hi, f) if y_hi > y_lo else minf(y_lo, -sc._y_margin)
	return Vector3(x, y, z)


func _heading_memo(sc: School, at_tick: int) -> void:
	if at_tick == sc._memo_h_tick:
		return
	var d: Vector3 = _center(sc, at_tick + 1) - center_at(sc, at_tick)
	sc._memo_h = d.normalized() if d.length_squared() > 1e-12 else Vector3.FORWARD
	sc._memo_yaw = atan2(-sc._memo_h.x, -sc._memo_h.z)
	sc._memo_h_tick = at_tick


func _init_path(sc: School, zlo: Vector3, zhi: Vector3, edge: float, path_r: float, cruise: float) -> void:
	var a: float = path_r * (0.7 + 0.6 * hash01(sc.seed, 0, _SALT_PATH))
	var squash: float = 0.6 + 0.4 * hash01(sc.seed, 1, _SALT_PATH)
	var turn: float = 1.0 if hash01(sc.seed, 2, _SALT_PATH) < 0.5 else -1.0
	sc._amp = PackedFloat64Array([a * _AMP_MAIN, a * _AMP_SECOND, turn * a * _AMP_MAIN * squash, a * _AMP_SECOND])
	var w1: float = cruise / (a * _SPEED_FACTOR)
	sc._w = PackedFloat64Array([w1, w1 * (1.7 + 0.6 * hash01(sc.seed, 3, _SALT_PATH)), w1 * 0.7])
	sc._ph = PackedFloat64Array()
	for i in 4:
		sc._ph.append(TAU * hash01(sc.seed, 4 + i, _SALT_PATH))
	sc._y_frac = 0.25 + 0.5 * hash01(sc.seed, 8, _SALT_PATH)
	var b: float = sc.bound_m
	sc._lo = Vector3(maxf(zlo.x + b, -edge + b), zlo.y + sc._y_margin, maxf(zlo.z + b, -edge + b))
	sc._hi = Vector3(minf(zhi.x - b, edge - b), zhi.y - sc._y_margin, minf(zhi.z - b, edge - b))
	for axis: int in [0, 2]:
		if sc._hi[axis] < sc._lo[axis]:
			var mid: float = (zlo[axis] + zhi[axis]) * 0.5
			sc._lo[axis] = mid
			sc._hi[axis] = mid
	# base point: far enough from the clamp box edges for the loop to fit when the zone allows it
	var reach_x: float = absf(sc._amp[0]) + absf(sc._amp[1])
	var reach_z: float = absf(sc._amp[2]) + absf(sc._amp[3])
	sc._base = Vector2(
		_pick(sc._lo.x, sc._hi.x, reach_x, hash01(sc.seed, 9, _SALT_PATH)),
		_pick(sc._lo.z, sc._hi.z, reach_z, hash01(sc.seed, 10, _SALT_PATH)))


# Uniform in [lo + reach, hi - reach], or the middle of [lo, hi] when that is empty.
static func _pick(lo: float, hi: float, reach: float, u: float) -> float:
	if hi - lo > 2.0 * reach:
		return lerpf(lo + reach, hi - reach, u)
	return (lo + hi) * 0.5


func _init_members(sc: School) -> void:
	sc.alive.resize(sc.size)
	sc.alive.fill(1)
	for k in sc.size:
		var cz: float = hash01(sc.seed, k, _SALT_SLOT) * 2.0 - 1.0
		var phi: float = TAU * hash01(sc.seed, k + 0x10000, _SALT_SLOT)
		var r: float = pow(hash01(sc.seed, k + 0x20000, _SALT_SLOT), 1.0 / 3.0) * sc.radius_m
		var s: float = sqrt(maxf(1.0 - cz * cz, 0.0))
		sc._slots.append(Vector3(s * cos(phi) * r, cz * r * _height_ratio, s * sin(phi) * r))
		sc._wob_a.append(TAU * hash01(sc.seed, k, _SALT_WOBBLE))
		sc._wob_b.append(TAU * hash01(sc.seed, k + 0x10000, _SALT_WOBBLE))
		sc._lengths.append(lerpf(sc.length_min, sc.length_max, hash01(sc.seed, k, _SALT_LEN)))
