class_name BossBrain
extends RefCounted
## Giant shark boss decisions (GAME_DESIGN section 7; numbers: the species `boss` block). Static and stateless: the
## state machine lives on the boss SimEntity (`boss_*` fields, all hashed); think() runs in the brains phase instead
## of NpcBrain.think and acts through SimCommands (MOVE / BRAKE / BITE via NpcBrain.steer) plus the charge lunge
## (Abilities.start_dash, the same movement override as Bite-Dash). Damage, stun, finisher, remains and victory are
## rules and live in SimWorld's boss phase. Deterministic: no RNG, players visited in ascending id.
##
##   PATROL     wander the home zone (NpcBrain.wander), HP regen. A living player within engage_radius_m (any band,
##              hiding ignored) -> ENGAGE (BOSS_ENGAGED, other = that player); the first charge may come at once.
##   ENGAGE     chase the target (nearest living player in range, else the last one) at the species speed, BITE it
##              when it touches the mouth cone or the bodies overlap (bodies_touch: a 10 m body makes the centre
##              cone meaningless at close range; SimWorld uses the same rule for bites on the boss) and the boss bite
##              cooldown (boss.bite_cooldown_s) is over. When the
##              target is in range, the next charge is due (boss_attack_tick) and its distance is within
##              [dash_min_range_m, dash_distance_m] -> TELL. Close-range charge (S7 anti-hug): a target that stays
##              inside dash_min_range_m for hug_charge_after_s (boss_hug_tick) also gets the TELL when the charge is
##              due (BOSS_TELL data.close = true; same wind-up, same dodge). No living player in range for
##              disengage_after_s -> DISENGAGE (BOSS_DISENGAGED).
##   TELL       brakes and turns toward the direction locked at the start (BOSS_TELL, value = dash_windup_s) for
##              dash_windup_s -> DASH. Dodge = leave the locked line during the wind-up.
##   DASH       charge: dash_distance_m along the locked direction at dash_speed_mps (BOSS_DASH, DASH_STARTED); a
##              player touched (centre distance <= boss radius + player radius + dash_hit_margin_m) takes
##              dash_damage(): a victim in the last size band loses dash_damage_frac_of_b4_max_hp x its OWN max HP
##              (S7: GAME_DESIGN "40% of player max HP at B4"), a smaller one that fraction of the B4 max HP at
##              dash_ref_length_m (effectively lethal); once per charge, x its damage_taken_mult. Lunge over ->
##              ENGAGE, next charge due dash_interval_s later.
##   DISENGAGE  swims back toward its home point (spawn position) at the wander speed with HP regen; a player in
##              range -> ENGAGE, after disengage_return_s -> PATROL.
##   STUNNED    HP reached 0 (SimWorld: BOSS_STUNNED, it does not die). No commands; waits for the finisher. S7
##              time-out (SimWorld boss phase, recover_from_stun): no finisher within stun_timeout_s -> HP
##              stun_recover_hp_frac x max HP, DISENGAGE (BOSS_DISENGAGED data.recovered = true), so a player who
##              died after the stun does not leave the boss waiting and the HUD bar up forever.
##   DEFEATED   never seen on a live entity (the boss is removed in the finisher tick); kept for completeness.
## HP regen: hp_regen_frac_per_s x max HP per second in PATROL and DISENGAGE (SimWorld boss phase).

enum State { PATROL, ENGAGE, TELL, DASH, DISENGAGE, STUNNED, DEFEATED }

## DISENGAGE stops steering within this distance of the home point (metres, steering constant).
const HOME_REACHED_M: float = 4.0

static var _cache_content: ContentDB = null
static var _cache: Dictionary = {}  # StringName species id -> Params (or null when the species has no boss block)


## Boss numbers of one species, read once per ContentDB.
class Params:
	extends RefCounted
	var engage_r2: float = 0.0
	var windup_ticks: int = 0
	var dash_damage: float = 0.0  # absolute, before the victim's damage_taken_mult
	var dash_speed: float = 0.0
	var dash_distance: float = 0.0
	var dash_ticks: int = 1
	var hit_margin: float = 0.0
	var min_range: float = 0.0
	var interval_ticks: int = 0
	var bite_cd_ticks: int = 0
	var disengage_ticks: int = 0
	var return_ticks: int = 0
	var regen_frac: float = 0.0
	var victory_ticks: int = 0
	var remains_bits: int = 0
	var bit_scale: float = 1.0
	var dash_frac: float = 0.0  # dash_damage_frac_of_b4_max_hp
	var last_band: int = 0  # the band whose victims lose dash_frac x their own max HP
	var hug_ticks: int = 0  # hug_charge_after_s (0 = off)
	var stun_timeout_ticks: int = 0  # stun_timeout_s (0 = no time-out)
	var stun_recover_frac: float = 0.0
	var reach_mult: float = 0.0
	var cone_cos: float = 1.0
	var wander_frac: float = 0.0


## Boss numbers for `species_id`, null when it has no `boss` block (or there is no content).
static func params(world: SimWorld, species_id: StringName) -> Params:
	var content: ContentDB = world.content
	if content == null:
		return null
	if _cache_content != content:
		_cache_content = content
		_cache = {}
	if _cache.has(species_id):
		return _cache[species_id]
	var p: Params = _params_from(content, species_id)
	_cache[species_id] = p
	return p


## Decides this tick for the boss `e` (called by SimWorld.step() in the brains phase, every tick).
static func think(world: SimWorld, e: SimEntity) -> void:
	var p: Params = params(world, e.species_id)
	if p == null or not e.alive or e.boss_state == State.STUNNED or e.boss_state == State.DEFEATED:
		return
	var now: int = world.tick
	var near: SimEntity = _nearest_player(world, e, p.engage_r2)
	if near != null:
		e.boss_seen_tick = now
	match e.boss_state:
		State.PATROL, State.DISENGAGE:
			if near != null:
				_enter(e, State.ENGAGE, now)
				e.boss_target = near.id
				world.emit_event(SimEvent.Type.BOSS_ENGAGED, e.id, near.id)
				_engage(world, p, e, near, now)
			elif e.boss_state == State.DISENGAGE and now - e.boss_state_tick >= p.return_ticks:
				_enter(e, State.PATROL, now)
				NpcBrain.wander(world, e)
			elif e.boss_state == State.DISENGAGE:
				_go_home(world, p, e)
			else:
				NpcBrain.wander(world, e)
		State.ENGAGE:
			if now - e.boss_seen_tick >= p.disengage_ticks:
				_enter(e, State.DISENGAGE, now)
				e.boss_target = -1
				world.emit_event(SimEvent.Type.BOSS_DISENGAGED, e.id)
				_go_home(world, p, e)
				return
			_engage(world, p, e, near, now)
		State.TELL:
			if now - e.boss_state_tick >= p.windup_ticks:
				_enter(e, State.DASH, now)
				e.boss_dash_hits = PackedInt32Array()
				NpcBrain.steer(world, e, e.boss_dir, 0.0)
				Abilities.start_dash(world, e, e.boss_dir, p.dash_speed, p.dash_ticks, Abilities.BOSS_DASH)
				var ev: SimEvent = world.emit_event(SimEvent.Type.BOSS_DASH, e.id, e.boss_target)
				ev.data = {"dir": e.boss_dir, "speed": p.dash_speed, "duration": float(p.dash_ticks) * SimWorld.TICK_DT}
			else:
				NpcBrain.steer(world, e, e.boss_dir, 0.0, false, true)
		State.DASH:
			if e.dash_until_tick < 0:
				_enter(e, State.ENGAGE, now)
				e.boss_attack_tick = now + p.interval_ticks
				_engage(world, p, e, near, now)


## HP a charge takes from `victim` before its damage_taken_mult (class doc, DASH).
static func dash_damage(p: Params, victim: SimEntity) -> float:
	if p.last_band > 0 and victim.band >= p.last_band:
		return p.dash_frac * victim.max_hp
	return p.dash_damage


## Stun time-out (SimWorld boss phase): back to DISENGAGE with stun_recover_hp_frac of max HP.
static func recover_from_stun(world: SimWorld, e: SimEntity, p: Params) -> void:
	_enter(e, State.DISENGAGE, world.tick)
	e.hp = p.stun_recover_frac * e.max_hp
	e.boss_target = -1
	e.boss_hug_tick = -1
	var ev: SimEvent = world.emit_event(SimEvent.Type.BOSS_DISENGAGED, e.id)
	ev.data = {"recovered": true}


## Body contact for boss bites (both ways) and the finisher: centre distance <= the two collision radii.
static func bodies_touch(world: SimWorld, a: SimEntity, b: SimEntity) -> bool:
	var r: float = world.collision_radius(a) + world.collision_radius(b)
	return a.position.distance_squared_to(b.position) <= r * r


## True while the boss fights (ENGAGE, TELL, DASH, STUNNED): the HUD shows its HP bar.
static func is_engaged(e: SimEntity) -> bool:
	return e != null and (e.boss_state == State.ENGAGE or e.boss_state == State.TELL or e.boss_state == State.DASH or e.boss_state == State.STUNNED)


# ENGAGE behaviour: pick the target, start a TELL when a charge is due, else chase and bite.
static func _engage(world: SimWorld, p: Params, e: SimEntity, near: SimEntity, now: int) -> void:
	if near != null:
		e.boss_target = near.id
	var t: SimEntity = world.get_entity(e.boss_target)
	if t == null or not t.alive or t.kind != SimEntity.Kind.CREATURE:
		NpcBrain.steer(world, e, e.heading, 0.0)
		return
	var to: Vector3 = t.position - e.position
	var d2: float = to.length_squared()
	var dir: Vector3 = to / sqrt(d2) if d2 > 1e-12 else e.heading
	var close: bool = d2 < p.min_range * p.min_range
	if not close:
		e.boss_hug_tick = -1
	elif e.boss_hug_tick < 0:
		e.boss_hug_tick = now
	var hugged: bool = close and p.hug_ticks > 0 and now - e.boss_hug_tick >= p.hug_ticks
	if near != null and now >= e.boss_attack_tick and (not close or hugged) and d2 <= p.dash_distance * p.dash_distance:
		_enter(e, State.TELL, now)
		e.boss_dir = dir
		e.boss_hug_tick = -1
		var ev: SimEvent = world.emit_event(SimEvent.Type.BOSS_TELL, e.id, t.id, float(p.windup_ticks) * SimWorld.TICK_DT)
		ev.data = {"dir": dir, "close": close}
		NpcBrain.steer(world, e, dir, 0.0, false, true)
		return
	var reach: float = e.length_m * p.reach_mult + world.collision_radius(t)
	var in_range: bool = d2 <= reach * reach
	if in_range and now >= e.bite_ready_tick and (SimRules.in_cone(e.position, e.heading, t.position, reach, p.cone_cos) or bodies_touch(world, e, t)):
		world.submit(SimCommand.bite(e.id, t.id, now))
	var facing: float = e.heading.dot(dir)
	var speed: float = NpcBrain.species_speed(world, e.species_id)
	NpcBrain.steer(world, e, dir, speed * clampf(facing, 0.1, 1.0), false, in_range and facing < p.cone_cos)


static func _go_home(world: SimWorld, p: Params, e: SimEntity) -> void:
	var to: Vector3 = e.boss_home - e.position
	if to.length_squared() <= HOME_REACHED_M * HOME_REACHED_M:
		NpcBrain.steer(world, e, e.heading, 0.0)
		return
	NpcBrain.steer(world, e, to.normalized(), NpcBrain.species_speed(world, e.species_id) * p.wander_frac)


static func _enter(e: SimEntity, state: State, now: int) -> void:
	e.boss_state = state
	e.boss_state_tick = now


# Nearest living, active player within the engage radius (lower id on ties), or null.
static func _nearest_player(world: SimWorld, e: SimEntity, r2: float) -> SimEntity:
	var best: SimEntity = null
	var best_d2: float = INF
	for pl in world.players():
		if not SimWorld._is_active_creature(pl):
			continue
		var d2: float = pl.position.distance_squared_to(e.position)
		if d2 <= r2 and d2 < best_d2:
			best_d2 = d2
			best = pl
	return best


static func _params_from(content: ContentDB, species_id: StringName) -> Params:
	var rec: Dictionary = content.get_species(species_id)
	if not (rec.get("boss") is Dictionary):
		return null
	var b: Dictionary = rec["boss"]
	var rules: Dictionary = content.rules()
	var p := Params.new()
	var engage: float = float(b.get("engage_radius_m", 0.0))
	p.engage_r2 = engage * engage
	p.windup_ticks = roundi(float(b.get("dash_windup_s", 0.0)) * SimWorld.TICK_RATE)
	p.dash_speed = float(b.get("dash_speed_mps", 0.0))
	p.dash_distance = float(b.get("dash_distance_m", 0.0))
	p.dash_ticks = maxi(roundi(p.dash_distance / p.dash_speed * SimWorld.TICK_RATE), 1) if p.dash_speed > 0.0 else 1
	p.hit_margin = float(b.get("dash_hit_margin_m", 0.0))
	p.min_range = float(b.get("dash_min_range_m", 0.0))
	p.interval_ticks = roundi(float(b.get("dash_interval_s", 0.0)) * SimWorld.TICK_RATE)
	p.bite_cd_ticks = roundi(float(b.get("bite_cooldown_s", rules.get("bite_cooldown_s", 0.0))) * SimWorld.TICK_RATE)
	p.disengage_ticks = roundi(float(b.get("disengage_after_s", 0.0)) * SimWorld.TICK_RATE)
	p.return_ticks = roundi(float(b.get("disengage_return_s", 0.0)) * SimWorld.TICK_RATE)
	p.regen_frac = float(b.get("hp_regen_frac_per_s", 0.0))
	p.victory_ticks = roundi(float(b.get("victory_delay_s", 0.0)) * SimWorld.TICK_RATE)
	p.remains_bits = int(b.get("remains_bits", 0))
	p.bit_scale = float(b.get("remains_bit_scale", 1.0))
	p.reach_mult = float(rules.get("mouth_reach_mult", 0.0))
	p.cone_cos = cos(deg_to_rad(float(rules.get("mouth_cone_deg", 0.0))))
	var behaviour: Variant = rec.get("behaviour")
	p.wander_frac = float((behaviour as Dictionary).get("wander_speed_frac", 0.5)) if behaviour is Dictionary else 0.5
	# dash damage below the last band: the given fraction of the max HP a B4 player has at the reference length
	# (rules.player_hp_model); in the last band the victim's own max HP (dash_damage())
	var ref_len: float = float(b.get("dash_ref_length_m", 0.0))
	var ref_hp: float = float(content.get_band(content.band_count()).get("max_hp", 0.0)) if content.band_count() > 0 else 0.0
	if str(rules.get("player_hp_model", "band")) == "length2":
		var player_sp: Dictionary = {}
		for id in content.species_ids():
			if content.get_species(id).get("playable") == true:
				player_sp = content.get_species(id)
				break
		ref_hp = SimRules.creature_max_hp(float(player_sp.get("base_hp", 0.0)), ref_len)
	p.dash_frac = float(b.get("dash_damage_frac_of_b4_max_hp", 0.0))
	p.dash_damage = p.dash_frac * ref_hp
	p.last_band = content.band_count()
	p.hug_ticks = roundi(float(b.get("hug_charge_after_s", 0.0)) * SimWorld.TICK_RATE)
	p.stun_timeout_ticks = roundi(float(b.get("stun_timeout_s", 0.0)) * SimWorld.TICK_RATE)
	p.stun_recover_frac = float(b.get("stun_recover_hp_frac", 0.0))
	return p
