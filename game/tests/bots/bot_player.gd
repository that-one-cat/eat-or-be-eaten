extends RefCounted
## Balance harness v1 bot (S3): plays the eat / bite / grow loop as the player with simple rules, through
## SimCommands only (rule 2). It reads sim state and events like a presentation layer would, never writes them.
## Deterministic: its own SimRng seeded from the run seed, ascending-id grid queries, ties go to the lower id.
## commands() must be called once per tick, before SimWorld.step(); observe() gets that step's events.
##
## Rules, in priority order every tick:
##  1. FLEE: a predator that would hunt us (our length <= rules.predator_hunt_ratio x its length) within its
##     detection_radius_m + THREAT_MARGIN_M, or a retaliator we bit (still inside rules.retaliate_duration_s) within
##     SIGHT_M that is not about to die: swim away (inverse-square sum), boost, and duck into a hiding volume when
##     one lies ahead.
##  2. HIDE: HP below HIDE_HP_FRAC (and hunger high enough to regenerate): swim to the nearest map hiding volume and
##     rest there until HP >= RESUME_HP_FRAC or hunger falls to the regeneration floor + HIDE_HUNGER_MARGIN.
##  3. FORAGE: the best target by expected XP per second within SIGHT_M: things it can swallow (food bits,
##     creatures <= swallow_ratio of its length) and creatures it can kill in <= MAX_KILL_BITES bites whose expected
##     counter-damage (counter-bites + puffer spikes) stays below KILL_RISK_HP_FRAC of its HP. BITE when the target
##     is in the mouth cone and the bite is off cooldown.
##     Food sites (world.food: eggs, snails, edible decor; the player-only FoodSites) compete in the same score:
##     XP / (d / speed + bites x bite_cooldown_s), XP = xp_gain(type xp x xp_band_mult[band], length, type length_m)
##     from ContentDB.get_food(type), bites = ceil(site_hp / our bite damage) for hard sites, 0 for soft ones (a soft
##     site too big to swallow scores 0). Soft sites are swallowed by swimming the mouth onto them; hard sites get
##     a target-less BITE (-1: the sim's "best in the bite cone", the only way to bite a site) when the site is in
##     the player bite cone (rules.bite_reach_mult / bite_cone_deg). The last LOOKAHEAD_M to a site skip the
##     terrain lift (sites sit on the seabed and on rock tops; the sim's seabed constraint keeps the body out).
##     Sites inside the map's soft-current margin are ignored (same bound as the wander points).
##  4. WANDER: to a random point within WANDER_RADIUS_M, clamped into the nearest zone of the passive prey species
##     (map + species data) and out of the map's soft-current margin, re-picked on arrival or after WANDER_TIMEOUT_TICKS; boosts while stamina is above
##     BOOST_WANDER_STAMINA (covers ground like a searching player).
## Unsticking: a target that cannot be reached (or bitten again) in CHASE_TIMEOUT_TICKS, or no progress for STUCK_TICKS while
## thrusting, gets the target blacklisted for BLACKLIST_TICKS and a new wander point (food sites alike; stuck on a site
## also ignores all sites for BLACKLIST_TICKS, so the bot leaves a rock that hides several of them).

enum Mode { FLEE, HIDE, FORAGE, WANDER, DEAD }

## Bot perception radius (no data key: GAME_DESIGN has no threat indicators; the player sees what is near).
const SIGHT_M: float = 25.0
const THREAT_MARGIN_M: float = 5.0
const RESCAN_TICKS: int = 6
const HIDE_HP_FRAC: float = 0.4
const RESUME_HP_FRAC: float = 0.9
const HIDE_HUNGER_MARGIN: float = 0.05
const MAX_KILL_BITES: int = 8
const KILL_RISK_HP_FRAC: float = 0.6
## A retaliator we bit stops being a threat when it needs at most this many more bites from us.
const FINISH_BITES: int = 2
const CHASE_TIMEOUT_TICKS: int = 300
const BLACKLIST_TICKS: int = 300
const STUCK_TICKS: int = 60
const STUCK_MIN_M: float = 0.5
const WANDER_ARRIVE_M: float = 4.0
const WANDER_TIMEOUT_TICKS: int = 600
const WANDER_RADIUS_M: float = 50.0
const BOOST_WANDER_STAMINA: float = 60.0
## The current target's score is multiplied by this when re-picking (stops flip-flopping between targets).
const KEEP_TARGET_BONUS: float = 1.3
## Steering: clearance above the seabed / below the surface, lookahead for terrain following.
const CLEARANCE_M: float = 1.0
const LOOKAHEAD_M: float = 3.0
## Boost only with at least this much stamina, and when the target is farther than BOOST_CHASE_M.
const BOOST_MIN_STAMINA: float = 30.0
const BOOST_CHASE_M: float = 5.0
const HIDE_AHEAD_M: float = 40.0

var mode: Mode = Mode.WANDER
## Ticks spent per mode (Mode name -> ticks).
var mode_ticks: Dictionary = {}

var _w: SimWorld
var _id: int = 0
var _rng: SimRng
var _db: ContentDB
var _bands: Array = []
var _sp: Dictionary = {}  # StringName -> {temperament, xp, detect, bite_mult, spike_frac}
var _swallow_ratio: float = 0.1
var _reach_mult: float = 0.8
var _cos_half: float = 0.7
var _bite_cd_s: float = 0.5
var _hunt_ratio: float = 0.6
var _retaliate_ticks: int = 300
var _falloff: Dictionary = {}
var _regen_min_frac: float = 0.5
var _hunger_max: float = 100.0
var _player_bite_mult: float = 1.0
var _wander_lo: PackedVector3Array = PackedVector3Array()
var _wander_hi: PackedVector3Array = PackedVector3Array()
var _map_half: float = INF  # map half-size minus the soft-current margin (wander points stay inside)
var _hide_lo: PackedVector3Array = PackedVector3Array()
var _hide_hi: PackedVector3Array = PackedVector3Array()
var _buf: PackedInt32Array = PackedInt32Array()
var _site_buf: PackedInt32Array = PackedInt32Array()
var _food_types: Dictionary = {}  # StringName -> {soft, xp, band_mult, length, swallow} (ContentDB.get_food, lazy)
var _bite_reach_mult: float = 1.5
var _bite_cos_half: float = 0.5

var _target: int = -1
## Current food site target (world.food site id, -1 = none); exclusive with _target.
var _site: int = -1
var _site_blacklist: Dictionary = {}  # site -> until tick
var _sites_off_until: int = 0  # no site targets before this tick (set when stuck on a site)
var _target_since: int = 0
var _blacklist: Dictionary = {}  # id -> until tick
var _angered: Dictionary = {}  # retaliator id -> until tick
var _threats: PackedInt32Array = PackedInt32Array()
var _hiding: bool = false
var _wander_pt: Vector3 = Vector3.ZERO
var _wander_since: int = -1
var _stuck_ref: Vector3 = Vector3.ZERO
var _stuck_tick: int = -1
var _boosting: bool = false
var _braking: bool = false


func _init(world: SimWorld, player_id: int, seed: int) -> void:
	_w = world
	_id = player_id
	_db = world.content
	_rng = SimRng.new(seed * 7919 + 17)
	for m in Mode.keys():
		mode_ticks[m] = 0
	var r: Dictionary = _db.rules()
	_swallow_ratio = float(r.get("swallow_ratio", _swallow_ratio))
	_reach_mult = float(r.get("mouth_reach_mult", _reach_mult))
	_cos_half = cos(deg_to_rad(float(r.get("mouth_cone_deg", 45.0))))
	_bite_cd_s = float(r.get("bite_cooldown_s", _bite_cd_s))
	_bite_reach_mult = float(r.get("bite_reach_mult", _reach_mult))
	_bite_cos_half = cos(deg_to_rad(float(r.get("bite_cone_deg", r.get("mouth_cone_deg", 45.0)))))
	_hunt_ratio = float(r.get("predator_hunt_ratio", _hunt_ratio))
	_retaliate_ticks = roundi(float(r.get("retaliate_duration_s", 10.0)) * SimWorld.TICK_RATE)
	_falloff = r.get("xp_falloff", {})
	_regen_min_frac = float(r.get("regen_min_hunger_frac", _regen_min_frac))
	_hunger_max = float(r.get("hunger_max", _hunger_max))
	for i in range(1, _db.band_count() + 1):
		_bands.append(_db.get_band(i))
	for sid in _db.species_ids():
		var rec: Dictionary = _db.get_species(sid)
		var inflate: Dictionary = rec.get("inflate", {})
		_sp[sid] = {
			"temperament": String(rec.get("temperament", "passive")),
			"xp": float(rec.get("xp", 0.0)),
			"detect": float(rec.get("detection_radius_m", 0.0)),
			"bite_mult": float(rec.get("bite_mult", 1.0)),
			"spike_frac": float(inflate.get("spike_damage_frac_of_biter_max_hp", 0.0)),
		}
	var me: SimEntity = world.get_entity(player_id)
	if me != null and _sp.has(me.species_id):
		_player_bite_mult = float(_sp[me.species_id]["bite_mult"])
	# wander region: the zones of the passive (prey) species that are not ambient
	var zone_ids: Array[String] = []
	for sid in _db.species_ids():
		var rec: Dictionary = _db.get_species(sid)
		if String(rec.get("temperament", "")) != "passive" or String(rec.get("tier", "")) == "ambient":
			continue
		for z in rec.get("zones", []):
			if not zone_ids.has(String(z)):
				zone_ids.append(String(z))
	for z in world.map.get("zones", []):
		if zone_ids.has(String(z.get("id", ""))):
			_wander_lo.append(_vec(z["aabb"]["min"]))
			_wander_hi.append(_vec(z["aabb"]["max"]))
	if world.map.has("size_m"):
		_map_half = float(world.map["size_m"]) * 0.5 - float(world.map.get("bounds", {}).get("soft_margin_m", 0.0))
	for hv in world.map.get("hiding_volumes", []):
		_hide_lo.append(_vec(hv["aabb"]["min"]))
		_hide_hi.append(_vec(hv["aabb"]["max"]))


## Commands for the current tick (explicit tick = world.tick).
func commands() -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	var e: SimEntity = _w.get_entity(_id)
	var t: int = _w.tick
	if e == null or not e.alive:
		mode = Mode.DEAD
		mode_ticks["DEAD"] += 1
		_target = -1
		_site = -1
		_wander_since = -1
		_boosting = false
		_braking = false
		_stuck_tick = -1
		return out
	if _stuck_tick < 0:
		_stuck_ref = e.position
		_stuck_tick = t
	var target_ok: bool = _valid_target()
	if t % RESCAN_TICKS == 0 or not target_ok:
		_scan(e)
	var hp_frac: float = e.hp / e.max_hp if e.max_hp > 0.0 else 1.0
	var hunger_frac: float = e.hunger / _hunger_max if _hunger_max > 0.0 else 1.0
	var hunger_floor: float = _regen_min_frac + HIDE_HUNGER_MARGIN
	if _hiding and (hp_frac >= RESUME_HP_FRAC or hunger_frac <= hunger_floor):
		_hiding = false
	elif not _hiding and hp_frac < HIDE_HP_FRAC and hunger_frac > hunger_floor and not _hide_lo.is_empty():
		_hiding = true

	var away: Vector3 = _flee_vector(e)
	if not away.is_zero_approx():
		mode = Mode.FLEE
		var dir: Vector3 = away.normalized()
		var hv: Vector3 = _nearest_hide_point(e.position)
		if hv.is_finite() and hv.distance_to(e.position) <= HIDE_AHEAD_M and (hv - e.position).normalized().dot(dir) > 0.3:
			dir = (hv - e.position).normalized()
		_steer(out, e, e.position + dir * LOOKAHEAD_M * 3.0, _band_speed(e), true, false)
	elif _hiding:
		mode = Mode.HIDE
		if e.hidden:
			_steer(out, e, e.position, 0.0, false, true)
		else:
			_steer(out, e, _nearest_hide_point(e.position), _band_speed(e), e.stamina > BOOST_MIN_STAMINA, false)
	elif _site >= 0:
		mode = Mode.FORAGE
		_forage_site(out, e)
	elif _target >= 0:
		mode = Mode.FORAGE
		_forage(out, e)
	else:
		mode = Mode.WANDER
		if _wander_since < 0 or e.position.distance_to(_wander_pt) <= WANDER_ARRIVE_M or t - _wander_since > WANDER_TIMEOUT_TICKS:
			_pick_wander(e.position)
		_steer(out, e, _wander_pt, _band_speed(e), e.stamina > BOOST_WANDER_STAMINA or (_boosting and e.stamina > 0.0), false)
	mode_ticks[Mode.keys()[mode]] += 1
	_check_stuck(e)
	return out


## Events of the last step: memory of retaliators we bit; a landed bite on the target restarts its chase timeout.
func observe(events: Array[SimEvent]) -> void:
	for ev in events:
		if ev.type == SimEvent.Type.BITTEN and ev.other_id == _id:
			if ev.entity_id == _target:
				_target_since = ev.tick  # progress: the chase timeout restarts
			var v: SimEntity = _w.get_entity(ev.entity_id)
			if v != null and _temperament(v) != "passive":
				_angered[ev.entity_id] = ev.tick + _retaliate_ticks
		elif ev.type == SimEvent.Type.SITE_BITTEN and ev.entity_id == _id and int(ev.data.get("site", -1)) == _site:
			_target_since = ev.tick  # progress on the site: the chase timeout restarts
			_stuck_ref = _w.get_entity(_id).position  # hovering over a site while chewing is not being stuck
			_stuck_tick = ev.tick


# ------------------------------------------------------------------ perception

func _scan(e: SimEntity) -> void:
	var t: int = _w.tick
	_threats.clear()
	for id in _angered.keys():
		if int(_angered[id]) <= t:
			_angered.erase(id)
	for id in _blacklist.keys():
		if int(_blacklist[id]) <= t:
			_blacklist.erase(id)
	var radius: float = SIGHT_M
	for sid in _sp:
		radius = maxf(radius, float(_sp[sid]["detect"]) + THREAT_MARGIN_M)
	_w.grid.query_radius_into(e.position, radius, _buf)
	var speed: float = maxf(_band_speed(e), 0.1)
	var my_dmg: float = _bite_dmg_of(e.band, e.length_m, _player_bite_mult)
	var best: int = -1
	var best_score: float = 0.0
	for id in _buf:
		if id == _id:
			continue
		var c: SimEntity = _w.get_entity(id)
		if c == null or not c.alive:
			continue
		var d: float = e.position.distance_to(c.position)
		if c.kind == SimEntity.Kind.CREATURE and _is_threat(e, c, d, my_dmg):
			_threats.append(id)
			continue
		if d > SIGHT_M or _blacklist.has(id):
			continue
		var score: float = _score(e, c, d, speed, my_dmg)
		if id == _target:
			score *= KEEP_TARGET_BONUS
		if score > best_score:
			best_score = score
			best = id
	var best_site: int = -1
	if _w.food != null and t >= _sites_off_until:
		for s in _site_blacklist.keys():
			if int(_site_blacklist[s]) <= t:
				_site_blacklist.erase(s)
		_w.food.sites_near_into(e.position, SIGHT_M, _site_buf)
		for s in _site_buf:
			var sp: Vector3 = _w.food.site_pos(s)
			# like the wander points: never into the soft-current margin (the current outruns B1 / B2)
			if _site_blacklist.has(s) or absf(sp.x) > _map_half or absf(sp.z) > _map_half:
				continue
			var score: float = _site_score(e, s, speed, my_dmg)
			if s == _site:
				score *= KEEP_TARGET_BONUS
			if score > best_score:
				best_score = score
				best_site = s
	if best_site >= 0:
		best = -1
	if best != _target or best_site != _site:
		_target = best
		_site = best_site
		_target_since = t


func _is_threat(e: SimEntity, c: SimEntity, d: float, my_dmg: float) -> bool:
	var temper: String = _temperament(c)
	if temper == "predator":
		return e.length_m <= _hunt_ratio * c.length_m and d <= float(_sp[c.species_id]["detect"]) + THREAT_MARGIN_M
	if temper == "retaliate" and _angered.has(c.id) and d <= SIGHT_M:
		return ceili(c.hp / my_dmg) > FINISH_BITES if my_dmg > 0.0 else true
	return false


# Expected XP per second of going for `c` (0 = not a target).
func _score(e: SimEntity, c: SimEntity, d: float, speed: float, my_dmg: float) -> float:
	if c.kind == SimEntity.Kind.FOOD_BIT:
		if not SimRules.can_swallow(e.length_m, c.length_m, _swallow_ratio):
			return 0.0
		return SimRules.xp_gain(c.xp_value, e.length_m, c.source_length_m, _falloff) / (d / speed + 0.1)
	var sp: Dictionary = _sp.get(c.species_id, {})
	if sp.is_empty():
		return 0.0
	var xp: float = SimRules.xp_gain(float(sp["xp"]), e.length_m, c.length_m, _falloff)
	if SimRules.can_swallow(e.length_m, _w.effective_length(c), _swallow_ratio):
		return xp / (d / speed + 0.1)
	var n: int = _bites_to_kill(c, my_dmg)
	if n < 0 or n > MAX_KILL_BITES or _kill_risk(e, c, n) >= KILL_RISK_HP_FRAC * e.hp:
		return 0.0
	# the remains are eaten bit by bit: about one extra second
	return xp / (d / speed + float(n) * _bite_cd_s + 1.0)


# Expected XP per second of going for food site `s` (research 7.4): XP / (d / speed + bites x cooldown); soft sites are
# swallowed (0 bites; 0 when too big to swallow), hard ones need ceil(HP / our bite damage) bites.
func _site_score(e: SimEntity, s: int, speed: float, my_dmg: float) -> float:
	var ft: Dictionary = _food_type(_w.food.site_type(s))
	var d: float = e.position.distance_to(_w.food.site_pos(s))
	var mult: Array = ft["band_mult"]
	var xp: float = float(ft["xp"]) * (float(mult[clampi(e.band - 1, 0, mult.size() - 1)]) if not mult.is_empty() else 1.0)
	xp = SimRules.xp_gain(xp, e.length_m, float(ft["length"]), _falloff)
	if bool(ft["soft"]):
		if not SimRules.can_swallow(e.length_m, float(ft["length"]), float(ft["swallow"])):
			return 0.0
		return xp / (d / speed + 0.1)
	if my_dmg <= 0.0:
		return 0.0
	var bites: int = maxi(ceili(_w.food.site_hp(s) / my_dmg), 1)
	return xp / (d / speed + float(bites) * _bite_cd_s)


# Food type numbers the score needs (ContentDB.get_food), cached per type.
func _food_type(type: StringName) -> Dictionary:
	if not _food_types.has(type):
		var rec: Dictionary = _db.get_food(type)
		_food_types[type] = {
			"soft": String(rec.get("kind", "")) == "soft",
			"xp": float(rec.get("xp", 0.0)),
			"band_mult": rec.get("xp_band_mult", []) if rec.get("xp_band_mult") is Array else [],
			"length": float(rec.get("length_m", 0.0)),
			"swallow": float(rec.get("swallow_ratio", _swallow_ratio)),
		}
	return _food_types[type]


func _bites_to_kill(c: SimEntity, my_dmg: float) -> int:
	if my_dmg <= 0.0:
		return -1
	return maxi(ceili(c.hp / my_dmg), 1)


# Damage we expect to take while killing `c` in `n` bites: its counter-bites (one per bite after the first, unless
# it is passive) plus spikes on every bite (puffer).
func _kill_risk(e: SimEntity, c: SimEntity, n: int) -> float:
	var sp: Dictionary = _sp[c.species_id]
	var risk: float = float(sp["spike_frac"]) * e.max_hp * float(n)
	if String(sp["temperament"]) != "passive":
		var band: int = SimRules.band_for_length(c.length_m, _bands)
		risk += _bite_dmg_of(band, c.length_m, float(sp["bite_mult"])) * float(n - 1)
	return risk


# False (and the target dropped) when the target is gone or was chased for too long.
func _valid_target() -> bool:
	if _site >= 0:
		if not _w.food.site_alive(_site):
			_site = -1
			return false
		if _w.tick - _target_since > CHASE_TIMEOUT_TICKS:
			_site_blacklist[_site] = _w.tick + BLACKLIST_TICKS
			_site = -1
			return false
		return true
	if _target < 0:
		return true
	var c: SimEntity = _w.get_entity(_target)
	if c == null or not c.alive:
		_target = -1
		return false
	if _w.tick - _target_since > CHASE_TIMEOUT_TICKS:
		_blacklist[_target] = _w.tick + BLACKLIST_TICKS
		_target = -1
		return false
	return true


func _flee_vector(e: SimEntity) -> Vector3:
	var away := Vector3.ZERO
	var my_dmg: float = _bite_dmg_of(e.band, e.length_m, _player_bite_mult)
	for id in _threats:
		var c: SimEntity = _w.get_entity(id)
		if c == null or not c.alive:
			continue
		var off: Vector3 = e.position - c.position
		var d2: float = maxf(off.length_squared(), 1e-6)
		if not _is_threat(e, c, sqrt(d2), my_dmg):
			continue
		away += off / d2
	return away


# ------------------------------------------------------------------ acting

func _forage(out: Array[SimCommand], e: SimEntity) -> void:
	var c: SimEntity = _w.get_entity(_target)
	var to: Vector3 = c.position - e.position
	var d: float = to.length()
	var reach: float = e.length_m * _reach_mult
	var swallow: bool = c.kind == SimEntity.Kind.FOOD_BIT or SimRules.can_swallow(e.length_m, _w.effective_length(c), _swallow_ratio)
	var dir: Vector3 = to / d if d > 1e-6 else e.heading
	var facing: float = e.heading.dot(dir)
	if swallow:
		# slow enough near the target that the mouth cannot skip over it between two ticks
		var speed: float = minf(_band_speed(e), maxf(reach * SimWorld.TICK_RATE * 0.5, d * 2.0))
		_steer(out, e, c.position, speed * clampf(facing, 0.1, 1.0), false, d < reach * 3.0 and facing < _cos_half)
		return
	var bite_reach: float = reach + _w.collision_radius(c) * (_w.effective_length(c) / c.length_m if c.length_m > 0.0 else 1.0)
	if _w.tick >= e.bite_ready_tick:
		# bites resolve after this tick's movement: also try both positions one tick ahead
		var mouth: Vector3 = e.position + e.velocity * SimWorld.TICK_DT
		var prey: Vector3 = c.position + c.velocity * SimWorld.TICK_DT
		if SimRules.in_cone(e.position, e.heading, c.position, bite_reach, _cos_half) or SimRules.in_cone(mouth, e.heading, prey, bite_reach, _cos_half):
			out.append(SimCommand.bite(_id, c.id, _w.tick))
	var boost: bool = d > BOOST_CHASE_M and facing > _cos_half and e.stamina > BOOST_MIN_STAMINA
	# close in at the prey's speed plus a margin, so the fish does not overshoot and orbit it
	var speed: float = minf(_band_speed(e), c.speed + maxf(bite_reach * SimWorld.TICK_RATE * 0.3, d * 2.0))
	_steer(out, e, c.position, speed * clampf(facing, 0.1, 1.0), boost, d < bite_reach * 2.0 and facing < _cos_half)


# Food site target: swim the mouth onto a soft site (the swallow lap eats it), bite a hard one with a target-less BITE
# while it is in the player bite cone (this tick or one tick ahead). Static target: the speed ramps down with the
# distance; no BRAKE (a braking fish facing away cannot turn back to a target that does not move).
func _forage_site(out: Array[SimCommand], e: SimEntity) -> void:
	var pos: Vector3 = _w.food.site_pos(_site)
	var to: Vector3 = pos - e.position
	var d: float = to.length()
	var dir: Vector3 = to / d if d > 1e-6 else e.heading
	var facing: float = e.heading.dot(dir)
	var terrain: bool = d > LOOKAHEAD_M
	if bool(_food_type(_w.food.site_type(_site))["soft"]):
		var reach: float = e.length_m * _reach_mult + _w.food.site_radius(_site)
		var speed: float = minf(_band_speed(e), maxf(reach * SimWorld.TICK_RATE * 0.5, d * 2.0))
		_steer(out, e, pos, speed * clampf(facing, 0.1, 1.0), false, false, terrain)
		return
	var bite_reach: float = e.length_m * _bite_reach_mult + _w.food.site_radius(_site)
	if _w.tick >= e.bite_ready_tick:
		var mouth: Vector3 = e.position + e.velocity * SimWorld.TICK_DT
		if SimRules.in_cone(e.position, e.heading, pos, bite_reach, _bite_cos_half) or SimRules.in_cone(mouth, e.heading, pos, bite_reach, _bite_cos_half):
			out.append(SimCommand.bite(_id, -1, _w.tick))
	var boost: bool = d > BOOST_CHASE_M and facing > _cos_half and e.stamina > BOOST_MIN_STAMINA
	var speed: float = minf(_band_speed(e), d * 2.0)
	_steer(out, e, pos, speed * clampf(facing, 0.1, 1.0), boost, false, terrain)


# MOVE toward `aim` (lifted over the seabed ahead unless `terrain` is false, kept below the surface), BOOST / BRAKE on
# change.
func _steer(out: Array[SimCommand], e: SimEntity, aim: Vector3, speed: float, boost: bool, brake: bool, terrain: bool = true) -> void:
	var p: Vector3 = e.position
	var r: float = _w.collision_radius(e)
	var to: Vector3 = aim - p
	var dir: Vector3 = to.normalized() if to.length_squared() > 1e-10 else e.heading
	if _w.seabed != null and terrain:
		var ahead: Vector3 = p + dir * LOOKAHEAD_M
		var floor_y: float = _w.seabed.height_at(ahead.x, ahead.z) + CLEARANCE_M + r
		if ahead.y < floor_y:
			dir.y = maxf(dir.y, clampf((floor_y - ahead.y) / LOOKAHEAD_M, 0.0, 1.0))
		if p.y > -CLEARANCE_M - r:
			dir.y = minf(dir.y, 0.0)
		dir = dir.normalized() if not dir.is_zero_approx() else e.heading
	var band_max: float = _band_speed(e)
	var thrust: float = clampf(speed / band_max, 0.0, 1.0) if band_max > 0.0 else 0.0
	out.append(SimCommand.move(_id, dir, 0.0 if brake else thrust, _w.tick))
	var want_boost: bool = boost and e.stamina > 0.0 and not brake
	if want_boost != _boosting:
		_boosting = want_boost
		out.append(SimCommand.boost(_id, want_boost, _w.tick))
	if brake != _braking:
		_braking = brake
		out.append(SimCommand.brake(_id, brake, _w.tick))


func _check_stuck(e: SimEntity) -> void:
	var t: int = _w.tick
	if mode == Mode.HIDE and e.hidden:
		_stuck_ref = e.position
		_stuck_tick = t
		return
	if t - _stuck_tick < STUCK_TICKS:
		return
	if e.position.distance_to(_stuck_ref) < STUCK_MIN_M and e.move_thrust > 0.0:
		if _target >= 0:
			_blacklist[_target] = t + BLACKLIST_TICKS
			_target = -1
		if _site >= 0:
			# static sites behind the same rock would catch the bot again: no sites until it has wandered off
			_site_blacklist[_site] = t + BLACKLIST_TICKS
			_site = -1
			_sites_off_until = t + BLACKLIST_TICKS
		_pick_wander(e.position)
	_stuck_ref = e.position
	_stuck_tick = t


func _pick_wander(p: Vector3) -> void:
	_wander_since = _w.tick
	if _wander_lo.is_empty():
		_wander_pt = Vector3.ZERO
		return
	var x: float = p.x + _rng.range_float(-WANDER_RADIUS_M, WANDER_RADIUS_M)
	var z: float = p.z + _rng.range_float(-WANDER_RADIUS_M, WANDER_RADIUS_M)
	# clamp into the nearest prey zone (xz distance to its box)
	var i: int = 0
	var best_d2: float = INF
	for k in _wander_lo.size():
		var q := Vector2(clampf(x, _wander_lo[k].x, _wander_hi[k].x), clampf(z, _wander_lo[k].z, _wander_hi[k].z))
		var d2: float = q.distance_squared_to(Vector2(x, z))
		if d2 < best_d2:
			best_d2 = d2
			i = k
	var lo: Vector3 = _wander_lo[i]
	var hi: Vector3 = _wander_hi[i]
	x = clampf(clampf(x, lo.x, hi.x), -_map_half, _map_half)
	z = clampf(clampf(z, lo.z, hi.z), -_map_half, _map_half)
	var y_lo: float = lo.y
	if _w.seabed != null:
		y_lo = maxf(y_lo, _w.seabed.height_at(x, z) + CLEARANCE_M * 2.0)
	var y_hi: float = minf(hi.y, -CLEARANCE_M * 2.0)
	var y: float = _rng.range_float(y_lo, y_hi) if y_hi > y_lo else y_hi
	_wander_pt = Vector3(x, y, z)


# Nearest point inside the nearest hiding volume (shrunk by the clearance, above the seabed); INF when none.
func _nearest_hide_point(p: Vector3) -> Vector3:
	var best := Vector3(INF, INF, INF)
	var best_d2: float = INF
	for i in _hide_lo.size():
		var lo: Vector3 = _hide_lo[i] + Vector3.ONE * CLEARANCE_M
		var hi: Vector3 = _hide_hi[i] - Vector3.ONE * CLEARANCE_M
		var q := Vector3(clampf(p.x, lo.x, hi.x), clampf(p.y, lo.y, hi.y), clampf(p.z, lo.z, hi.z))
		if _w.seabed != null:
			q.y = clampf(maxf(q.y, _w.seabed.height_at(q.x, q.z) + CLEARANCE_M), lo.y, hi.y)
		var d2: float = p.distance_squared_to(q)
		if d2 < best_d2:
			best_d2 = d2
			best = q
	return best


# ------------------------------------------------------------------ data helpers

func _band_speed(e: SimEntity) -> float:
	return float(_bands[clampi(e.band, 1, _bands.size()) - 1].get("swim_speed_mps", 1.0))


func _bite_dmg_of(band: int, length_m: float, mult: float) -> float:
	var power: float = float(_bands[clampi(band, 1, _bands.size()) - 1].get("bite_power", 0.0))
	return SimRules.bite_damage(power, length_m, mult)


func _temperament(c: SimEntity) -> String:
	return String(_sp[c.species_id]["temperament"]) if _sp.has(c.species_id) else ""


static func _vec(v: Variant) -> Vector3:
	var a: Array = v
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
