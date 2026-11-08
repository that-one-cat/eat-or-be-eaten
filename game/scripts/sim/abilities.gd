class_name Abilities
extends RefCounted
## Active abilities granted by mutations (GAME_DESIGN section 4; numbers in game/data/abilities). Static and
## stateless: grants and cooldowns live on the entity (`abilities`, `ability_ready_ticks` = tick at which each one is
## ready again). SimWorld calls use() when it applies an ABILITY command (rule 2). Boost stays the BOOST command.
##  - bite_dash: lunge lunge_distance_m along the current heading over lunge_duration_s (rounded to whole ticks, the
##    speed makes the distance exact; seabed / map clamps still apply), then SimWorld bites the best target in the
##    cone at the end of the lunge, ignoring the bite cooldown once (normal bite rules otherwise), and slows the fish
##    to exit_speed_frac x its max swim speed. ABILITY_USED,
##    DASH_STARTED; DASH_ENDED when the lunge ends.
##  - sonar: SONAR_PULSE listing every living creature within radius_m (grid query, ascending id, self excluded) with
##    rel by length ratio target / user: < smaller_below_ratio "smaller", > bigger_above_ratio "bigger", else
##    "similar". Ambient school members are not entities and are not listed.
## A use needs the ability granted, the user alive and world.tick >= its ready tick; it starts cooldown_s.

const BITE_DASH: StringName = &"bite_dash"
const SONAR: StringName = &"sonar"
## dash_ability of the boss charge (BossBrain), not a data ability.
const BOSS_DASH: StringName = &"boss_dash"
const REL_SMALLER: String = "smaller"
const REL_SIMILAR: String = "similar"
const REL_BIGGER: String = "bigger"

static var _ids: PackedInt32Array = PackedInt32Array()  # reused grid query buffer


## Tries to use `ability_id` for `e`; returns true when it fired.
static func use(world: SimWorld, e: SimEntity, ability_id: StringName) -> bool:
	if world.content == null or not SimWorld._is_active_creature(e):
		return false
	var slot: int = e.abilities.find(String(ability_id))
	if slot < 0 or world.tick < e.ability_ready_ticks[slot]:
		return false
	var rec: Dictionary = world.content.get_ability(ability_id)
	if rec.is_empty():
		return false
	match ability_id:
		BITE_DASH:
			if e.dash_until_tick >= 0:
				return false
			var ticks: int = maxi(roundi(float(rec.get("lunge_duration_s", 0.0)) * SimWorld.TICK_RATE), 1)
			var speed: float = float(rec.get("lunge_distance_m", 0.0)) / (float(ticks) * SimWorld.TICK_DT)
			start_dash(world, e, e.heading, speed, ticks, BITE_DASH)
		SONAR:
			_sonar(world, e, rec)
		_:
			return false
	var cd: float = float(rec.get("cooldown_s", 0.0))
	e.ability_ready_ticks[slot] = world.tick + maxi(roundi(cd * SimWorld.TICK_RATE), 0)
	var ev: SimEvent = world.emit_event(SimEvent.Type.ABILITY_USED, e.id, -1, cd)
	ev.data = {"ability": String(ability_id)}
	return true


## Seconds until `ability_id` is ready for `e` (0 when ready, not granted or `e` is null).
static func cooldown_left(world: SimWorld, e: SimEntity, ability_id: StringName) -> float:
	if e == null:
		return 0.0
	var slot: int = e.abilities.find(String(ability_id))
	if slot < 0:
		return 0.0
	return float(maxi(e.ability_ready_ticks[slot] - world.tick, 0)) / SimWorld.TICK_RATE


## Starts a lunge of `ticks` ticks along unit `dir` at `speed` (Bite-Dash, boss charge); DASH_STARTED.
static func start_dash(world: SimWorld, e: SimEntity, dir: Vector3, speed: float, ticks: int, kind: StringName) -> void:
	var d: Vector3 = dir.normalized() if not dir.is_zero_approx() else e.heading
	e.heading = d
	e.dash_velocity = d * speed
	e.dash_until_tick = world.tick + ticks
	e.dash_ability = kind
	var ev: SimEvent = world.emit_event(SimEvent.Type.DASH_STARTED, e.id)
	ev.data = {"ability": String(kind), "dir": d, "duration": float(ticks) * SimWorld.TICK_DT}


static func _sonar(world: SimWorld, e: SimEntity, rec: Dictionary) -> void:
	var radius: float = float(rec.get("radius_m", 0.0))
	var below: float = float(rec.get("smaller_below_ratio", 0.0))
	var above: float = float(rec.get("bigger_above_ratio", INF))
	var contacts: Array[Dictionary] = []
	if world.grid != null and radius > 0.0:
		world.grid.query_radius_into(e.position, radius, _ids)  # exact radius, ascending ids
		for id in _ids:
			var t: SimEntity = world.get_entity(id)
			if t == null or t == e or t.kind != SimEntity.Kind.CREATURE or not t.alive:
				continue
			var ratio: float = t.length_m / e.length_m if e.length_m > 0.0 else 1.0
			var rel: String = REL_SMALLER if ratio < below else (REL_BIGGER if ratio > above else REL_SIMILAR)
			contacts.append({"id": id, "rel": rel})
	var ev: SimEvent = world.emit_event(SimEvent.Type.SONAR_PULSE, e.id, -1, radius)
	ev.data = {"radius": radius, "duration": float(rec.get("duration_s", 0.0)), "contacts": contacts}
