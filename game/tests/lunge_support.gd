extends RefCounted
## Shared kit for the T1.6 bite lunge tests (res://tests/lunge_support.gd). Not a test file: the runner only collects
## scripts named test_*.gd. Use via `const LS := preload("res://tests/lunge_support.gd")`. No class_name.
##
## What the tests assume (the contract in tasks/demo-t1-6-bite-lunge.md, NOT private implementation names):
##  - rules/core.json key `lunge_strength` (0..1 multiplier, shipped exactly 0.0 = OFF, 0 = today's code path bit for bit).
##  - size_bands.json key `lunge_distance_m` on EVERY band (finite >= 0): the TOTAL travel of one lunge at strength 1.
##  - the lunge applies to PLAYER bites that LAND on a creature (a miss never lunges, NPC / boss bites never lunge, a swallow
##    is not a bite), pushes the player forward along its `heading`, and runs through the normal movement path
##    (_substep / _constrain), so it can never end inside the seabed / a rock / an arch / above the surface.
##  - total travel ~ lunge_distance_m x lunge_strength for a player at rest, measured after the player has settled
##    (the tests use TOL_FRAC = +-30 %, because the internal impulse model is the implementation's choice: velocity
##    impulse + drag, or a short constant-speed burst, both qualify).
##  - the lunge is free (no stamina, no boost change) and its speed is capped at band max speed x boost speed_mult.
##  - the world is driven only through public API: SimWorld.submit / step / events, the God `tune` console commands
##    (tuning_support.gd), the rules / band edits of a ContentDB loaded before SimWorld.new.
##
## Geometry: the player (band N, mid length) idles at S3.ARENA (mid-water, > 15 m above the seabed, > 30 m from any obstacle,
## brains OFF), a durable victim (2 x the player length, never swallowable) follows it 0.5 body lengths ahead so every press
## lands. All runs are 30 Hz ticks.
##
## Pre-change baselines (BASELINE_*): captured on the code BEFORE T1.6 (Godot 4.7.2, macOS arm64, branch feat/bite-lunge at
## eb6946a), see the test plan.

const TS := preload("res://tests/tuning_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const S5 := preload("res://tests/s5_support.gd")
const S6 := preload("res://tests/s6_support.gd")
const SS := preload("res://tests/species_stats_support.gd")
const F := preload("res://tests/food_support.gd")

const KEY_STRENGTH: String = "lunge_strength"
const KEY_BAND_M: String = "lunge_distance_m"

const SEED: int = 31
## Tolerance on the travel distance: +-30 % of lunge_distance_m x strength (documented in the test plan).
const TOL_FRAC: float = 0.30
## Ticks until a resting player has surely settled (drag 0.8/s from ~2 m/s needs < 280 ticks; a burst model is faster).
const SETTLE: int = 450
const SETTLED_SPEED_MPS: float = 0.01
## Explicit band distances (metres) for tests that must not depend on the shipped starting values; low enough that the
## speed cap (band max x boost mult) does not bind on a drag-decay model (v0 = D x drag: 3.0 / 3.6 / 4.0 / 4.8 m/s).
const BAND_M_TEST: Array[float] = [2.0, 3.0, 4.0, 6.0]
## Aggressive distance used by the strength-0 identity scenarios (inert while the strength is 0).
const BAND_M_HUGE: float = 50.0

const HEADING_YAW: Vector3 = Vector3(0.6, 0.0, -0.8)
## Victim distance (body lengths) for the cruising runs: the player covers up to 0.27 m per tick (boost), so the victim must be
## further ahead than at rest for the press to land before it is overtaken.
const CRUISE_AHEAD_LEN: float = 1.2

## state_hash of the strength-0 scenarios on the PRE-change code (see baseline_hashes()). Filled from the capture run.
const BASELINE_HASHES: Dictionary = {
	"chase_b1": 5468791833732582280,
	"chase_b2": -7675163550370593834,
	"chase_b3": 2848234929112834161,
	"chase_b4": 4360346185406697982,
	"misses_b3": 1581368361230569450,
	"site_bites": -37102392647280940,
	"dash_bite": 9104095858234023772,
}
## SHA-256 of JSON.stringify(rules/core.json) before T1.6 (keys in file order).
const CORE_SHA_BEFORE: String = "ee868131242935f561858a9e3af050e8c3c600bf0d0749a68f6d77dc9961b1d3"
## SHA-256 of JSON.stringify(size_bands.json) before T1.6 (keys in file order).
const BANDS_SHA_BEFORE: String = "be3c8f450f0fe6516a9107cfdcd9c6615d7e59adc4e648806563d069e1f891ad"

## QA-scaffold self-check hook: when valid, called as `hook.call(world, player)` right after a tick in which the player landed a
## bite, so the scaffold can prove its own oracles with a hand-made impulse on the pre-change code. The tests leave it invalid.
static var emulate: Callable = Callable()


# ======================================================================= worlds

## ContentDB with lunge_strength written into the rules (extra rules on top) and, when `band_m` is not null, lunge_distance_m
## in every band (a float for all bands or an Array of one value per band).
static func db_with(strength: float, band_m: Variant = null, rules_extra: Dictionary = {}) -> ContentDB:
	var db: ContentDB = ContentDB.load_from_dir("res://data")
	var rules: Dictionary = db.rules()
	rules[KEY_STRENGTH] = strength
	for k: Variant in rules_extra.keys():
		rules[str(k)] = rules_extra[k]
	if band_m != null:
		for i in range(1, db.band_count() + 1):
			var d: float = float((band_m as Array)[i - 1]) if band_m is Array else float(band_m)
			db.get_band(i)[KEY_BAND_M] = d
	return db


## Controlled world (no spawners, NPC brains OFF so pinned victims stay put, vitals ON) over `db_with(...)`.
static func world(strength: float, band_m: Variant = null, rules_extra: Dictionary = {}, brains: bool = false, world_seed: int = SEED) -> SimWorld:
	var db: ContentDB = db_with(strength, band_m, rules_extra)
	db.get_map(S3.MAP_ID)["spawners"] = []
	var w: SimWorld = SimWorld.new(world_seed, db)
	w.vitals_enabled = true
	w.brains_enabled = brains
	return w


## Shipped data as it is on disk (no lunge keys written by the test), controlled world like `world()`.
static func world_shipped(brains: bool = false, world_seed: int = SEED) -> SimWorld:
	var w: SimWorld = S3.make_world(world_seed, {})
	w.brains_enabled = brains
	return w


## XP that gives the geometric middle length of band `band`.
static func mid_xp(db: ContentDB, band: int) -> float:
	var lm: Dictionary = db.get_band(band)["length_m"]
	return S3.xp_for_length(db, sqrt(float(lm["min"]) * float(lm["max"])))


## Player of band `band` (mid length) at S3.ARENA, heading `heading`.
static func player(w: SimWorld, band: int, heading: Vector3 = HEADING_YAW) -> SimEntity:
	return S3.player_at(w, S3.ARENA, mid_xp(w.content, band), heading)


## Durable victim, 2 x the player length (never swallowable), `ahead_len` body lengths in front of the mouth.
static func victim(w: SimWorld, p: SimEntity, ahead_len: float = 0.5) -> SimEntity:
	return S3.npc_at(w, &"small_reef_fish", p.position + p.heading * (p.length_m * ahead_len), p.length_m * 2.0, -p.heading)


## Shipped `lunge_distance_m` of band `band` (NAN when the key is missing).
static func shipped_band_m(db: ContentDB, band: int) -> float:
	var v: Variant = db.get_band(band).get(KEY_BAND_M)
	return float(v) if TS.has_num(v) else NAN


## Pitched oblique heading (yaw + 20 deg up).
static func heading_pitched() -> Vector3:
	return Vector3(0.5, 0.35, -0.8).normalized()


# ======================================================================= core loop

## Steps `total` ticks. `script`: Array of {"tick": int, "bite": true[, "target": id]} | {"tick": int, "lines": [console lines]}
## (executed before that tick's step; `lines` act on `w` through the God commands). `v`: victim kept at `ahead_len` body lengths
## in front of the player every tick (follow = true) or pinned where it stands (follow = false); null = no victim. Refills the hp
## of player and victim every tick. Returns {"w","p","v","evs","start","pos" (Array[Vector3] after every tick),
## "vel" (Array[Vector3]), "stamina" (Array[float]), "boosting" (Array[bool]), "end", "landed" (landed bites on `v`)}.
static func run(w: SimWorld, p: SimEntity, v: SimEntity, total: int, script: Array = [], follow: bool = true, ahead_len: float = 0.5) -> Dictionary:
	var evs: Array[SimEvent] = []
	var pos: Array[Vector3] = []
	var vel: Array[Vector3] = []
	var stamina: Array[float] = []
	var boosting: Array[bool] = []
	var start: Vector3 = p.position
	var vpos: Vector3 = v.position if v != null else Vector3.ZERO
	var cmds: GodCommands = null
	for i in total:
		for item: Variant in script:
			var d: Dictionary = item
			if int(d["tick"]) != i:
				continue
			if d.has("lines"):
				if cmds == null:
					cmds = TS.commands()
				TS.tune_all(cmds, w, p.id, d["lines"])
			if bool(d.get("bite", false)):
				w.submit(SimCommand.bite(p.id, int(d.get("target", -1))))
		if v != null:
			v.position = p.position + p.heading * (p.length_m * ahead_len) if follow else vpos
			v.velocity = Vector3.ZERO
		w.step()
		var got: Array[SimEvent] = w.events_since(w.tick - 1)
		evs.append_array(got)
		if emulate.is_valid() and not TS.bites_by(got, p.id).is_empty():
			emulate.call(w, p)
		if v != null:
			v.position = p.position + p.heading * (p.length_m * ahead_len) if follow else vpos
			v.velocity = Vector3.ZERO
			if v.alive:
				v.hp = v.max_hp
		if p.alive:
			p.hp = p.max_hp
		pos.append(p.position)
		vel.append(p.velocity)
		stamina.append(p.stamina)
		boosting.append(p.boosting)
	return {"w": w, "p": p, "v": v, "evs": evs, "start": start, "pos": pos, "vel": vel, "stamina": stamina, "boosting": boosting,
		"end": p.position, "landed": TS.bites_by(evs, p.id, v.id if v != null else -1).size()}


## {"travel", "along", "angle_deg", "speed", "disp"} of a run result against `heading` (end position vs start).
static func motion(r: Dictionary, heading: Vector3) -> Dictionary:
	var d: Vector3 = (r["end"] as Vector3) - (r["start"] as Vector3)
	var n: float = d.length()
	var p: SimEntity = r["p"]
	return {"disp": d, "travel": n, "along": d.dot(heading), "angle_deg": rad_to_deg(heading.angle_to(d)) if n > 1e-9 else 0.0, "speed": p.velocity.length()}


## Largest per-tick position change over the run (m), 0 when it never moved.
static func max_step(r: Dictionary) -> float:
	var prev: Vector3 = r["start"]
	var m: float = 0.0
	for q: Vector3 in (r["pos"] as Array[Vector3]):
		m = maxf(m, q.distance_to(prev))
		prev = q
	return m


# ======================================================================= scenarios

## ONE bite press at tick 0, the player at rest, victim following, `settle` ticks. `lines` run at tick 0 before the press.
## Returns run() + motion() against the player heading.
static func rest_lunge(w: SimWorld, band: int, heading: Vector3 = HEADING_YAW, lines: Array = [], settle: int = SETTLE) -> Dictionary:
	var p: SimEntity = player(w, band, heading)
	var v: SimEntity = victim(w, p)
	var script: Array = []
	if not lines.is_empty():
		script.append({"tick": 0, "lines": lines})
	script.append({"tick": 0, "bite": true})
	var r: Dictionary = run(w, p, v, settle, script)
	r.merge(motion(r, p.heading))
	return r


## Held bite in EMPTY water (no victim at all) for `total` ticks, the player at rest. Returns run() + motion() + "misses".
static func empty_water_bites(w: SimWorld, band: int, total: int = 120, heading: Vector3 = HEADING_YAW) -> Dictionary:
	var p: SimEntity = player(w, band, heading)
	var script: Array = []
	for i in total:
		script.append({"tick": i, "bite": true})
	var r: Dictionary = run(w, p, null, total, script)
	r.merge(motion(r, p.heading))
	r["misses"] = TS.misses_of(r["evs"], p.id)
	return r


## A band-2 player cruising on thrust 1 along +X (optionally boosting), ONE press at `press_at`, the victim following.
## Returns run() + motion() against +X. Compare two calls (strength 1 vs 0) for the extra travel.
static func cruise(strength: float, band_m: Variant, press_at: int = 45, total: int = 120, boost: bool = false, band: int = 2) -> Dictionary:
	var w: SimWorld = world(strength, band_m)
	var p: SimEntity = player(w, band, Vector3.RIGHT)
	var v: SimEntity = victim(w, p, CRUISE_AHEAD_LEN)
	w.submit(SimCommand.move(p.id, Vector3.RIGHT, 1.0))
	if boost:
		w.submit(SimCommand.boost(p.id, true))
	var r: Dictionary = run(w, p, v, total, [{"tick": press_at, "bite": true}], true, CRUISE_AHEAD_LEN)
	r.merge(motion(r, Vector3.RIGHT))
	return r


## Extra travel (strength `s` run minus the strength-0 run, same script) of a cruising player. Returns {"extra" (Vector3),
## "forward" (along +X), "lateral" (off +X), "on", "off"}.
static func cruise_extra(strength: float, band_m: Variant, boost: bool = false, press_at: int = 45, total: int = 120) -> Dictionary:
	var on: Dictionary = cruise(strength, band_m, press_at, total, boost)
	var off: Dictionary = cruise(0.0, band_m, press_at, total, boost)
	var extra: Vector3 = (on["end"] as Vector3) - (off["end"] as Vector3)
	return {"extra": extra, "forward": extra.x, "lateral": Vector2(extra.y, extra.z).length(), "on": on, "off": off}


## Player lands a bite at tick 0, hp is set to 0 on tick 1 (it dies in tick 1), then the run continues through the respawn and
## `after` idle ticks. Returns {"died": bool, "respawned": bool, "pos_a" (first tick after the respawn), "pos_b" (`after` ticks
## later), "vel_a", "w", "p"}.
static func death_after_bite(strength: float, band_m: Variant, band: int = 2, after: int = 90) -> Dictionary:
	var w: SimWorld = world(strength, band_m)
	var p: SimEntity = player(w, band, HEADING_YAW)
	var v: SimEntity = victim(w, p)
	w.submit(SimCommand.bite(p.id, -1))
	v.position = p.position + p.heading * (p.length_m * 0.5)
	w.step()
	p.hp = 0.0
	var died: bool = false
	var respawned: bool = false
	var guard: int = 0
	while guard < 400 and not respawned:
		w.step()
		guard += 1
		if not p.alive:
			died = true
		elif died:
			respawned = true
	var out: Dictionary = {"died": died, "respawned": respawned, "w": w, "p": p}
	if respawned:
		out["pos_a"] = p.position
		out["vel_a"] = p.velocity
		for i in after:
			w.step()
		out["pos_b"] = p.position
	return out


# ======================================================================= hash scenarios (identity at strength 0)

## Held bite on a victim that follows the mouth for `ticks` ticks while the player steers (turns +20 deg every second,
## thrust 0.6): about nine landed bites; a lunge, if one existed, would move the player at every one of them.
static func chase_hash(w: SimWorld, band: int, ticks: int = 150) -> int:
	var p: SimEntity = player(w, band, Vector3.RIGHT)
	var v: SimEntity = victim(w, p)
	for i in ticks:
		if i % 30 == 0:
			w.submit(SimCommand.move(p.id, Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(20.0 * float(floori(float(i) / 30.0)))), 0.6))
		v.position = p.position + p.heading * (p.length_m * 0.5)
		v.velocity = Vector3.ZERO
		w.submit(SimCommand.bite(p.id, -1))
		w.step()
		v.hp = v.max_hp
		p.hp = p.max_hp
	return w.state_hash()


## Held bite into empty water while the player steers (a miss never lunges), `ticks` ticks.
static func misses_hash(w: SimWorld, band: int, ticks: int = 120) -> int:
	var p: SimEntity = player(w, band, Vector3.RIGHT)
	for i in ticks:
		if i % 30 == 0:
			w.submit(SimCommand.move(p.id, Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(15.0 * float(floori(float(i) / 30.0)))), 0.5))
		w.submit(SimCommand.bite(p.id, -1))
		w.step()
		p.hp = p.max_hp
	return w.state_hash()


## Held bite on a hard food site (starfish) with a free player of 1.2 m for `ticks` ticks (food_support scene). 0 when the
## scene cannot be built (the caller reports it).
static func site_bites_hash(tc: TestCase, ticks: int = 90) -> int:
	var sc: Dictionary = F.scene(tc, F.T_STARFISH, {"length": 1.2})
	if sc.is_empty():
		return 0
	var w: SimWorld = sc["w"]
	F.run(w, ticks, {}, [int(sc["pid"])])
	return w.state_hash()


## Bite-Dash ability (granted through the real mutation node) ending in its bite on a pinned victim, 120 ticks, in `w` (null =
## the shipped controlled world of S3.make_world). Returns state_hash.
static func dash_bite_hash(w_in: SimWorld = null) -> int:
	var w: SimWorld = w_in if w_in != null else S3.make_world(SEED, {})
	var p: SimEntity = S3.player_at(w, S3.ARENA, mid_xp(w.content, 2), Vector3.RIGHT)
	S6.give_ability(w, p, "bite_dash")
	var vpos: Vector3 = p.position + Vector3.RIGHT * 8.5
	var v: SimEntity = S3.npc_at(w, &"small_reef_fish", vpos, p.length_m * 3.0, -Vector3.RIGHT)
	w.submit(SimCommand.ability(p.id, &"bite_dash"))
	S3.step_n(w, 120, {v.id: vpos}, [v.id, p.id])
	return w.state_hash()


## All strength-0 scenario hashes by name (same keys as BASELINE_HASHES). `extreme`: lunge_strength 0.0 written into the rules
## and a 50 m lunge_distance_m in every band (inert while the strength is 0); false = shipped data untouched.
static func baseline_hashes(tc: TestCase, extreme: bool) -> Dictionary:
	var out: Dictionary = {}
	for b in range(1, 5):
		out["chase_b%d" % b] = chase_hash(world(0.0, BAND_M_HUGE) if extreme else world_shipped(), b)
	out["misses_b3"] = misses_hash(world(0.0, BAND_M_HUGE) if extreme else world_shipped(), 3)
	out["site_bites"] = site_bites_hash(tc)
	out["dash_bite"] = dash_bite_hash()
	return out


# ======================================================================= geometry probes

## Obstacles (map obstacles + baked rock proxies) whose bounds, grown by `radius`, contain `centre`.
static func near_obstacles(w: SimWorld, centre: Vector3, radius: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lists: Array = [w.map.get("obstacles", []), w.content.get_proxies(S3.MAP_ID)]
	for lst: Variant in lists:
		for o: Variant in (lst as Array):
			var od: Dictionary = o
			if S5.obstacle_bounds(od).grow(radius).has_point(centre):
				out.append(od)
	return out


static func min_sdf(near: Array[Dictionary], p: Vector3) -> float:
	var m: float = INF
	for o: Dictionary in near:
		m = minf(m, S5.obstacle_sdf(o, p))
	return m


## True when the straight path a -> b passes through the solid of any of `near` (sampled every <= 5 cm).
static func crosses(near: Array[Dictionary], a: Vector3, b: Vector3) -> bool:
	var n: int = maxi(2, ceili(a.distance_to(b) / 0.05))
	for k in range(1, n):
		if min_sdf(near, a.lerp(b, float(k) / float(n))) < 0.0:
			return true
	return false


## First point along origin + dir * t (0.05 m steps) whose surface gap for a sphere of radius `r` is <= `gap`; Vector3.INF when
## the origin is not free / nothing is hit within `max_len` / the point is not free for the seabed model.
static func march_to_surface(w: SimWorld, near: Array[Dictionary], origin: Vector3, dir: Vector3, r: float, gap: float, max_len: float = 20.0) -> Vector3:
	if min_sdf(near, origin) <= r + gap:
		return Vector3.INF
	var t: float = 0.0
	while t <= max_len:
		var q: Vector3 = origin + dir * t
		if min_sdf(near, q) <= r + gap:
			if w.seabed.resolve(q, r).distance_to(q) < 1e-6:
				return q
			return Vector3.INF
		t += 0.05
	return Vector3.INF


## ONE landed bite at `start` heading `heading` (player of band `band`, victim pinned 0.3 body lengths in front), watched for
## `ticks` ticks. Returns {"landed", "inside_seabed" (a tick ended with the player sphere overlapping the seabed model),
## "pen" (a tick ended inside an analytic obstacle of `near`, beyond 1 mm), "tunnel" (a tick's straight path crossed a solid),
## "above_surface", "touched" (a tick ended within 5 cm of the seabed model), "moved" (end vs start, m), "r", "end", "w", "p"}.
static func probe(w: SimWorld, band: int, start: Vector3, heading: Vector3, near: Array[Dictionary], ticks: int = 120) -> Dictionary:
	var p: SimEntity = S3.player_at(w, start, mid_xp(w.content, band), heading)
	var v: SimEntity = S3.npc_at(w, &"small_reef_fish", start + p.heading * (p.length_m * 0.3), p.length_m, -p.heading)
	var r: float = w.collision_radius(p)
	var res: Dictionary = run(w, p, v, ticks, [{"tick": 0, "bite": true}], false)
	var inside_seabed: bool = false
	var pen: bool = false
	var tunnel: bool = false
	var above_surface: bool = false
	var touched: bool = false
	var prev: Vector3 = start
	for q: Vector3 in (res["pos"] as Array[Vector3]):
		if w.seabed.resolve(q, r - 1e-3).distance_to(q) > 1e-4:
			inside_seabed = true
		if w.seabed.resolve(q, r + 0.05).distance_to(q) > 1e-6:
			touched = true
		if min_sdf(near, q) < r - 1e-3:
			pen = true
		if crosses(near, prev, q):
			tunnel = true
		if q.y > -r + 1e-6:
			above_surface = true
		prev = q
	return {"landed": res["landed"], "inside_seabed": inside_seabed, "pen": pen, "tunnel": tunnel, "above_surface": above_surface,
		"touched": touched, "moved": (res["end"] as Vector3).distance_to(start), "r": r, "end": res["end"], "w": w, "p": p}


## Heading with yaw `yaw_deg` (0 = +X) and pitch `pitch_deg` (negative = down).
static func dir_of(yaw_deg: float, pitch_deg: float) -> Vector3:
	var y: float = deg_to_rad(yaw_deg)
	var pt: float = deg_to_rad(pitch_deg)
	return Vector3(cos(pt) * cos(y), sin(pt), cos(pt) * sin(y)).normalized()
