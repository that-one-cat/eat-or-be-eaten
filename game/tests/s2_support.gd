extends RefCounted
## Shared helpers for the test_s2_*.gd files (res://tests/s2_support.gd). Not a test file: the runner only
## collects scripts whose name starts with "test_". Use via `const S2 := preload("res://tests/s2_support.gd")`.
## All tunables are read from ContentDB (data); nothing here hard-codes speeds or radii.

const MAP_ID: StringName = &"reef"
## Open-water "lane" in the abyss: floor ~80 m deep, far from every obstacle, 90 m from the +Z edge.
const LANE_Y: float = -40.0
const LANE_Z: float = 210.0
const LANE_X0: float = -200.0

static var _content: ContentDB = null


## Deterministic LCG so test input never depends on the code under test (SimRng) or on global RNG.
class Lcg:
	var s: int

	func _init(p_seed: int) -> void:
		s = p_seed & 0x7FFFFFFF

	func next() -> int:
		s = (s * 1103515245 + 12345) & 0x7FFFFFFF
		return s

	## [0, 1)
	func unit() -> float:
		return float(next() % 10000) / 10000.0


# ---------------------------------------------------------------- data access

static func content() -> ContentDB:
	if _content == null:
		_content = ContentDB.load_from_dir("res://data")
	return _content


static func map() -> Dictionary:
	return content().get_map(MAP_ID)


static func half_size() -> float:
	return float(map().get("size_m", 600.0)) * 0.5


static func soft_margin() -> float:
	return float((map().get("bounds", {}) as Dictionary).get("soft_margin_m", 0.0))


static func current_mps() -> float:
	return float((map().get("bounds", {}) as Dictionary).get("current_mps", 0.0))


static func map_spawn(index: int) -> Vector3:
	var a: Array = (map()["player_spawns"] as Array)[index]
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func seabed() -> SeabedField:
	return SeabedField.from_map(map())


static func boost() -> Dictionary:
	return content().get_ability(&"boost")


static func band(b: int) -> Dictionary:
	return content().get_band(b)


## Numeric band field, e.g. band_f(2, "turn_rate_deg_s").
static func band_f(b: int, key: String) -> float:
	return float(band(b).get(key, 0.0))


static func band_speed(b: int) -> float:
	return band_f(b, "swim_speed_mps")


static func band_length(b: int) -> float:
	return float((band(b)["length_m"] as Dictionary)["min"])


static func radius_for(b: int, length_m: float) -> float:
	return length_m * band_f(b, "collision_radius_mult")


static func radius(e: SimEntity) -> float:
	return radius_for(e.band, e.length_m)


# ---------------------------------------------------------------- world helpers

static func make_world(world_seed: int = 1) -> SimWorld:
	return SimWorld.new(world_seed, content())


static func lane_start() -> Vector3:
	return Vector3(LANE_X0, LANE_Y, LANE_Z)


## Spawns the player through the S2 API, then teleports it (SimEntity fields are public) and puts it in band `band_index`.
static func spawn_at(w: SimWorld, pos: Vector3, heading: Vector3 = Vector3.RIGHT, band_index: int = 1) -> SimEntity:
	var id: int = w.spawn_player(0)
	var e: SimEntity = w.get_entity(id)
	e.position = pos
	e.velocity = Vector3.ZERO
	e.heading = heading.normalized()
	e.band = band_index
	e.xp = band_f(band_index, "xp_to_reach")
	e.length_m = band_length(band_index)
	return e


static func run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.step()


## True if the horizontal lane of `length` metres along +X from the lane start is free of seabed/obstacles for a sphere of radius r.
static func lane_is_clear(sb: SeabedField, r: float, length: float = 400.0) -> bool:
	var x: float = LANE_X0
	while x <= LANE_X0 + length:
		var p := Vector3(x, LANE_Y, LANE_Z)
		if sb.resolve(p, r).distance_to(p) > 1e-6:
			return false
		x += 2.0
	return true


# ---------------------------------------------------------------- math helpers

static func angle_deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.normalized().angle_to(b.normalized()))


## Godot convention: forward = -Z, yaw about +Y, positive pitch = nose up.
static func dir_from_yaw_pitch(yaw_deg: float, pitch_deg: float) -> Vector3:
	var y: float = deg_to_rad(yaw_deg)
	var p: float = deg_to_rad(pitch_deg)
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))


## Numeric triples in an obstacle record (JSON arrays or Vector3), in key order.
static func vec_values(d: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for k: Variant in d.keys():
		var v: Variant = d[k]
		if v is Vector3:
			out.append(v)
		elif v is Array:
			var arr: Array = v
			if arr.size() == 3 and _is_num(arr[0]) and _is_num(arr[1]) and _is_num(arr[2]):
				out.append(Vector3(float(arr[0]), float(arr[1]), float(arr[2])))
	return out


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## A point that really is inside obstacle `obs` for a sphere of radius r (mean of the record's vectors first,
## then each vector). Returns Vector3.INF if none of them penetrates (record schema not probe-able).
static func penetrating_probe(sb: SeabedField, obs: Dictionary, r: float) -> Vector3:
	var vs: Array[Vector3] = vec_values(obs)
	if vs.is_empty():
		return Vector3.INF
	var sum := Vector3.ZERO
	for v: Vector3 in vs:
		sum += v
	var candidates: Array[Vector3] = [sum / float(vs.size())]
	candidates.append_array(vs)
	for p: Vector3 in candidates:
		if sb.resolve(p, r).distance_to(p) > 1e-4:
			return p
	return Vector3.INF


# ---------------------------------------------------------------- command scripts

## Segmented movement script (cruise / boosted cruise / brake / cruise). One entry per segment start:
## {tick:int, dir:Vector3, thrust:float, boost:bool, brake:bool}. `with_brake=false` keeps the same MOVE/thrust
## pattern (thrust 0 during brake segments) but never raises the brake flag; same for `with_boost`.
static func movement_script(script_seed: int, ticks: int, with_brake: bool, with_boost: bool) -> Array[Dictionary]:
	var lcg := Lcg.new(script_seed)
	var out: Array[Dictionary] = []
	var t: int = 0
	var phase: int = 0
	while t < ticks:
		var seg: int = 20 + lcg.next() % 30
		var yaw: float = lcg.unit() * 360.0
		var pitch: float = (lcg.unit() - 0.5) * 60.0
		var mode: int = phase % 4  # 0 cruise, 1 boosted cruise, 2 brake (thrust 0), 3 cruise
		var thrust: float = 0.0 if mode == 2 else 0.6 + 0.4 * lcg.unit()
		out.append({
			"tick": t,
			"dir": dir_from_yaw_pitch(yaw, pitch),
			"thrust": thrust,
			"boost": with_boost and mode == 1,
			"brake": with_brake and mode == 2,
		})
		t += seg
		phase += 1
	return out


## Submits a movement_script for entity `id`. `explicit_ticks` true = each command carries its target tick.
static func submit_segments(w: SimWorld, id: int, segs: Array[Dictionary], explicit_ticks: bool = true) -> void:
	for s: Dictionary in segs:
		var t: int = int(s["tick"]) if explicit_ticks else -1
		w.submit(SimCommand.move(id, s["dir"], float(s["thrust"]), t))
		w.submit(SimCommand.boost(id, bool(s["boost"]), t))
		w.submit(SimCommand.brake(id, bool(s["brake"]), t))


## Dense script: a fresh MOVE every tick (slowly turning), boost on/off windows and one brake window.
## Every command carries its explicit target tick, so the result must not depend on how time is sliced into frames.
static func submit_per_tick_script(w: SimWorld, id: int, ticks: int) -> void:
	for t in ticks:
		var dir: Vector3 = dir_from_yaw_pitch(0.15 * float(t), 18.0 * sin(0.013 * float(t)))
		var braking: bool = t >= 300 and t < 345
		w.submit(SimCommand.move(id, dir, 0.0 if braking else 1.0, t))
		if t % 240 == 0:
			w.submit(SimCommand.boost(id, true, t))
		elif t % 120 == 0:
			w.submit(SimCommand.boost(id, false, t))
		if t == 300:
			w.submit(SimCommand.brake(id, true, t))
		elif t == 345:
			w.submit(SimCommand.brake(id, false, t))
