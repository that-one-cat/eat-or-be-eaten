extends RefCounted
## Shared kit for the T1.5 aim assist tests (res://tests/aim_assist_support.gd). Not a test file: the runner only collects
## scripts named test_*.gd. Use via `const AS := preload("res://tests/aim_assist_support.gd")`. No class_name.
##
## What the tests assume (the contract in tasks/demo-t1-5-aim-assist.md, NOT private implementation names):
##  - rules/core.json keys `aim_assist_strength` (0..1, shipped 0.0), `aim_assist_cone_deg` (EXTRA half-angle on top of
##    `bite_cone_deg`), `aim_assist_max_distance_m` (cap on the assisted distance; unit chosen by the implementation, so the
##    tests only ever use a tiny value (CAP_TINY) and a huge one (CAP_HUGE)), `aim_assist_stickiness` (0..1).
##  - the assist only touches PLAYER bites with target -1 (`SimCommand.bite(id, -1)`); explicit targets and NPC bites do not
##    change; the assist never picks a target the strict path would reject for another reason (swallowable, inactive).
##  - registry rows: one per key in data/god/tuning.json; the row id is looked up by (target "rules", path = key).
##  - the world is driven only through public API: SimWorld.submit / step / events, the God `tune` console commands
##    (tuning_support.gd) and the rules override of S3.make_world (`opts["rules"]`).
##
## Geometry (shipped data at the time of writing, recomputed from the world where it matters): player 0.5 m, bite reach
## 1.5 x length = 0.75 m, bite half-cone 60 deg, victim = 6 x player length = 3.0 m (never swallowed), collision radius
## 0.25 x length = 0.75 m, so a victim centre is in strict reach up to 0.75 + 0.75 = 1.5 m.
##
## Pre-change baselines (BASELINE_*): captured on the code BEFORE T1.5 (Godot 4.7.2, macOS arm64, branch feat/aim-assist at
## 6712558), see the test plan. The scenarios are built so that every aim_assist_* key may be present with strength 0.

const TS := preload("res://tests/tuning_support.gd")
const S2 := preload("res://tests/s2_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const SS := preload("res://tests/species_stats_support.gd")

const KEY_STRENGTH: String = "aim_assist_strength"
const KEY_CONE: String = "aim_assist_cone_deg"
const KEY_MAX_DIST: String = "aim_assist_max_distance_m"
const KEY_STICKY: String = "aim_assist_stickiness"
const KEYS: Array[String] = [KEY_STRENGTH, KEY_CONE, KEY_MAX_DIST, KEY_STICKY]

const SEED: int = 31
## Explicit test values for the inert keys (so a scenario never depends on the shipped starting values).
const CONE_DEG: float = 90.0
const CAP_HUGE: float = 1000.0
const CAP_TINY: float = 0.001
const STICKY_MID: float = 0.5

## state_hash of the strength-0 scenarios on the PRE-change code (aim keys written into the rules but inert).
const BASELINE_HASHES: Dictionary = {
	"crossing": -6765186110613557003,
	"stacked": 1566594956942625878,
	"sticky": 4379930117015031235,
	"crowd": 885487155568915505,
	"explicit": 8717552809966625740,
}
## TS.BASELINE_HASHES (five bite scenarios) and SS.BASELINE_HASHES (lanes, shipped-spawner world) are reused as they are:
## they are pinned on the pre-T1.3 code and still hold on main.


# ======================================================================= opts and rows

## Controlled world for the geometry scenarios: NPC brains OFF, so a pinned victim stays exactly where the test puts it
## during the step (brains move NPCs by ~0.05 m per tick before the bite phase, which would blur the exact ties and the
## 5 cm distance differences the scoring tests rely on).
static func world(o: Dictionary, brains: bool = false) -> SimWorld:
	var w: SimWorld = S3.make_world(SEED, o)
	w.brains_enabled = brains
	return w


## make_world opts with the four aim keys set (`extra` entries override the defaults / add other rule overrides).
static func opts(strength: float, extra: Dictionary = {}) -> Dictionary:
	var rules: Dictionary = {KEY_STRENGTH: strength, KEY_CONE: CONE_DEG, KEY_MAX_DIST: CAP_HUGE, KEY_STICKY: STICKY_MID}
	for k: Variant in extra.keys():
		rules[k] = extra[k]
	return {"rules": rules}


## Registry id of the row for a rules key ("" when the registry has no such row).
static func row_id(key: String) -> String:
	return TS.id_for("rules", key)


## Console line `tune <id> <value>` for a key (id looked up in the registry).
static func tune_line(key: String, value: float) -> String:
	return "tune %s %s" % [row_id(key), TS.fmt(value)]


# ======================================================================= geometry

## Unit vector to the player's left (+90 deg around +Y of the heading).
static func side_of(p: SimEntity) -> Vector3:
	return p.heading.rotated(Vector3.UP, PI * 0.5)


## Strict-cone angle (deg) between the heading and the direction to `pos`.
static func angle_deg(p: SimEntity, pos: Vector3) -> float:
	return rad_to_deg(p.heading.angle_to(pos - p.position))


## Strict reach of the player bite incl. the victim radius (centre distance limit).
static func strict_range(w: SimWorld, p: SimEntity, v: SimEntity) -> float:
	return S3.bite_reach_m(w, p) + w.collision_radius(v)


static func bitten_by(evs: Array[SimEvent], biter: int, victim_id: int = -1) -> Array[SimEvent]:
	return TS.bites_by(evs, biter, victim_id)


# ======================================================================= scenarios

## Prey swimming ACROSS the aim: it moves laterally (+side -> -side) at 0.05 m/tick, 0.3 m ahead of the mouth, from 1.0 m to the
## left. A single bite press at tick 0 lives for the buffer (6 ticks) while the prey is 73 deg .. 65 deg off the heading, i.e.
## outside the strict 60 deg cone the whole time; later it crosses the aim line (nothing pressed any more).
## Returns {"w","p","v","evs","min_angle" (over the press window),"bites","misses","first_bite_tick","trace","hash"}.
static func crossing(o: Dictionary, lines: Array = [], ticks: int = 24, window: int = 7) -> Dictionary:
	var w: SimWorld = world(o)
	var p: SimEntity = TS.player(w)
	var v: SimEntity = TS.victim(w, p, p.position + Vector3(0, 0, 10))
	TS.tune_all(TS.commands(), w, p.id, lines)
	var evs: Array[SimEvent] = []
	var min_angle: float = 360.0
	w.submit(SimCommand.bite(p.id, -1))
	for i in ticks:
		var pos: Vector3 = p.position + p.heading * 0.3 + side_of(p) * (1.0 - 0.05 * float(i))
		if i < window:
			min_angle = minf(min_angle, angle_deg(p, pos))
		evs.append_array(S3.step_n(w, 1, {v.id: pos}, [v.id, p.id]))
	var bites: Array[SimEvent] = bitten_by(evs, p.id, v.id)
	return {"w": w, "p": p, "v": v, "evs": evs, "min_angle": min_angle, "bites": bites.size(), "misses": TS.misses_of(evs, p.id),
		"first_bite_tick": bites[0].tick if not bites.is_empty() else -1, "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## Two victims of identical size standing on the SAME point 75 deg off the heading (exact score tie). Held bite for `ticks`.
## Returns {"w","p","a","b","evs","ids" (victim id of every landed bite, in order),"trace","hash"}.
static func stacked(o: Dictionary, ticks: int = 120, deg: float = 75.0, dist: float = 0.9) -> Dictionary:
	var w: SimWorld = world(o)
	var p: SimEntity = TS.player(w)
	var pos: Vector3 = TS.at(p, dist, deg)
	var a: SimEntity = TS.victim(w, p, pos)
	var b: SimEntity = TS.victim(w, p, pos)
	var evs: Array[SimEvent] = []
	for i in ticks:
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, {a.id: pos, b.id: pos}, [a.id, b.id, p.id]))
	return {"w": w, "p": p, "a": a, "b": b, "evs": evs, "ids": landed_ids(evs, p.id), "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## Victim ids of the BITTEN events of `biter`, in event order.
static func landed_ids(evs: Array[SimEvent], biter: int) -> Array[int]:
	var out: Array[int] = []
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == biter:
			out.append(ev.entity_id)
	return out


## ONE bite press at a single durable victim whose centre is `centre_m` away and `deg` off the heading (brains off), tune lines
## `lines` run first. Returns the number of bites landed on it in the 2 ticks after the press.
static func bite_at(o: Dictionary, deg: float, centre_m: float, lines: Array = []) -> int:
	var w: SimWorld = world(o)
	var p: SimEntity = TS.player(w)
	var pos: Vector3 = TS.at(p, centre_m, deg)
	var v: SimEntity = TS.victim(w, p, pos)
	TS.tune_all(TS.commands(), w, p.id, lines)
	w.submit(SimCommand.bite(p.id, -1))
	var evs: Array[SimEvent] = S3.step_n(w, 2, {v.id: pos}, [v.id, p.id])
	return bitten_by(evs, p.id, v.id).size()


## Two victims mirrored left / right (+-75 deg) at 0.9 m (`lines` = console lines run at tick 0). Held bite; after every landed bite the victim that was NOT bitten is
## put `delta` metres nearer than the other one (the feedback that tempts a flickering lock to jump). The first bite sees A
## nearer. Returns {"ids": Array[int] of landed victims, "a","b","w","p","trace","hash"}.
static func sticky(o: Dictionary, delta: float = 0.05, ticks: int = 150, lines: Array = []) -> Dictionary:
	var w: SimWorld = world(o)
	var p: SimEntity = TS.player(w)
	var a: SimEntity = TS.victim(w, p, TS.at(p, 0.9, 75.0))
	var b: SimEntity = TS.victim(w, p, TS.at(p, 0.9, -75.0))
	TS.tune_all(TS.commands(), w, p.id, lines)
	var nearer: SimEntity = a
	var evs: Array[SimEvent] = []
	for i in ticks:
		var pa: Vector3 = TS.at(p, 0.9 - (delta if nearer == a else 0.0), 75.0)
		var pb: Vector3 = TS.at(p, 0.9 - (delta if nearer == b else 0.0), -75.0)
		w.submit(SimCommand.bite(p.id, -1))
		var got: Array[SimEvent] = S3.step_n(w, 1, {a.id: pa, b.id: pb}, [a.id, b.id, p.id])
		evs.append_array(got)
		var ids: Array[int] = landed_ids(got, p.id)
		for vid: int in ids:
			nearer = b if vid == a.id else a
	return {"w": w, "p": p, "a": a, "b": b, "evs": evs, "ids": landed_ids(evs, p.id), "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## Eight victims (1.5 .. 3.0 m) on a ring of 0.8 .. 1.4 m around the player, the player turns 2 deg/tick, held bite, 300 ticks.
## Returns {"w","p","evs","ids","trace","hash"}.
static func crowd(o: Dictionary, ticks: int = 300) -> Dictionary:
	var w: SimWorld = world(o, true)
	var p: SimEntity = TS.player(w)
	var vs: Array[SimEntity] = []
	var keep: Array[int] = [p.id]
	for k in 8:
		var len_m: float = p.length_m * (3.0 + float(k % 4))
		var vk: SimEntity = S3.npc_at(w, &"small_reef_fish", p.position + Vector3(2.0, 0.0, 0.0), len_m, -p.heading)
		vs.append(vk)
		keep.append(vk.id)
	var evs: Array[SimEvent] = []
	for i in ticks:
		var pins: Dictionary = {}
		for k in 8:
			var ang: float = float(k) * 45.0 + 0.7 * float(i)
			var rad: float = 0.8 + 0.6 * float((k * 3) % 5) / 4.0
			pins[vs[k].id] = p.position + Vector3(rad, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(ang))
		var dir: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(2.0 * float(i)))
		w.submit(SimCommand.move(p.id, dir, 0.0))
		w.submit(SimCommand.bite(p.id, -1))
		evs.append_array(S3.step_n(w, 1, pins, keep))
	return {"w": w, "p": p, "evs": evs, "ids": landed_ids(evs, p.id), "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## Explicit-target bites among decoys: A (75 deg, outside), B (20 deg, inside), C (-70 deg, outside) all at 0.9 m, durable.
## Presses: tick 0 -> A, tick 20 -> B, tick 40 -> C, tick 60 -> an id that does not exist, tick 80 -> the player itself.
## Returns {"w","p","a","b","c","evs","trace","hash"}.
static func explicit(o: Dictionary, lines: Array = []) -> Dictionary:
	var w: SimWorld = world(o)
	var p: SimEntity = TS.player(w)
	var pa: Vector3 = TS.at(p, 0.9, 75.0)
	var pb: Vector3 = TS.at(p, 0.9, 20.0)
	var pc: Vector3 = TS.at(p, 0.9, -70.0)
	var a: SimEntity = TS.victim(w, p, pa)
	var b: SimEntity = TS.victim(w, p, pb)
	var c: SimEntity = TS.victim(w, p, pc)
	TS.tune_all(TS.commands(), w, p.id, lines)
	var targets: Array[int] = [a.id, b.id, c.id, 9999, p.id]
	var evs: Array[SimEvent] = []
	var press: int = 0
	for i in 100:
		if i % 20 == 0:
			w.submit(SimCommand.bite(p.id, targets[press]))
			press += 1
		evs.append_array(S3.step_n(w, 1, {a.id: pa, b.id: pb, c.id: pc}, [a.id, b.id, c.id, p.id]))
	return {"w": w, "p": p, "a": a, "b": b, "c": c, "evs": evs, "trace": TS.trace_with(w, evs), "hash": w.state_hash()}


## NPC-only engagement: a shark hunting small fish with the (inert) player 40 m away that never bites. `ticks` ticks.
## Returns {"trace","hash","npc_bites" (BITTEN events whose biter is not the player),"evs"}.
static func npc_hunt(o: Dictionary, ticks: int = 600) -> Dictionary:
	var w: SimWorld = S3.make_world(SEED, o)
	var p: SimEntity = TS.player(w)
	p.position += Vector3(40.0, 0.0, 0.0)
	var c: Vector3 = S3.ARENA
	var shark: SimEntity = S3.npc_at(w, &"shark", c, 3.0, Vector3.RIGHT)
	var keep: Array[int] = [p.id]
	for k in 4:
		var f: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(2.5 + 0.4 * float(k), 0.0, 0.6 * float(k) - 1.0), 0.9, Vector3.RIGHT)
		keep.append(f.id)
	var evs: Array[SimEvent] = S3.step_n(w, ticks, {}, [p.id])
	var npc_bites: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id != p.id:
			npc_bites += 1
	return {"trace": TS.trace_with(w, evs), "hash": w.state_hash(), "npc_bites": npc_bites, "evs": evs, "shark": shark.id}


## Shipped spawners + schools + scripted player (movement script of SS.hash_real_world) with NO bites at all; the world is
## full of NPC bites. Returns {"trace","hash","npc_bites"}.
static func real_world_no_player_bites(o: Dictionary, world_seed: int = 4242, ticks: int = 900) -> Dictionary:
	var oo: Dictionary = o.duplicate(true)
	oo["real_spawners"] = true
	var w: SimWorld = S3.make_world(world_seed, oo)
	var id: int = w.spawn_player(0)
	S2.submit_segments(w, id, S2.movement_script(1001, ticks, true, true), true)
	var evs: Array[SimEvent] = S3.step_n(w, ticks)
	var n: int = 0
	for ev: SimEvent in evs:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id != id:
			n += 1
	return {"trace": TS.trace_with(w, evs), "hash": w.state_hash(), "npc_bites": n}


## Same as SS.hash_real_world (shipped spawners + schools + a player bite every 45 ticks) but with the aim rules from `o`.
static func real_world_with_player_bites(o: Dictionary, world_seed: int = 4242, ticks: int = 900) -> Dictionary:
	var oo: Dictionary = o.duplicate(true)
	oo["real_spawners"] = true
	var w: SimWorld = S3.make_world(world_seed, oo)
	var id: int = w.spawn_player(0)
	S2.submit_segments(w, id, S2.movement_script(1001, ticks, true, true), true)
	var t: int = 40
	while t < ticks:
		w.submit(SimCommand.bite(id, -1, t))
		t += 45
	var evs: Array[SimEvent] = S3.step_n(w, ticks)
	return {"trace": TS.trace_with(w, evs), "hash": w.state_hash(), "player_bites": bitten_by(evs, id).size()}


## All strength-0 scenario hashes by name (same keys as BASELINE_HASHES): every other aim key is set to an aggressive
## value, the strength is 0.
static func baseline_hashes() -> Dictionary:
	var o: Dictionary = opts(0.0, {KEY_CONE: 170.0, KEY_MAX_DIST: CAP_HUGE, KEY_STICKY: 1.0})
	return {
		"crossing": crossing(o)["hash"], "stacked": stacked(o)["hash"], "sticky": sticky(o)["hash"], "crowd": crowd(o)["hash"],
		"explicit": explicit(o)["hash"],
	}
