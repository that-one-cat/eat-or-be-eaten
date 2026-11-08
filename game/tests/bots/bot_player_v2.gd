extends "res://tests/bots/bot_player.gd"
## Balance harness v2 bot (S6): the S3 bot (bot_player.gd: flee / hide / forage / wander) plus mutation picks, the
## active abilities and the giant shark boss. Same contract: SimCommands only, deterministic, commands() once per
## tick before SimWorld.step(), observe() with that step's events; choose_pick() answers a MUTATION_OFFERED.
##
## Plans:
##  - GROW: the S3 behaviour (food sites included), plus Bite-Dash to close the last metres on a bite target (and as an escape lunge while
##    fleeing when the heading already points away), plus Sonar whenever a threat is around (it has no effect on the
##    bot's own perception; it is used like a player would). The boss counts as a predator threat (S3 rule), so the
##    bot keeps away from it while growing.
##  - BOSS: entered when the bot is in the last band with >= BOSS_READY_XP_FRAC of that band's full-length XP, HP
##    >= BOSS_READY_HP_FRAC and hunger >= BOSS_READY_HUNGER_FRAC. Swims to the boss (the bot knows where it is: the
##    player knows it patrols the abyss; searching the zone is not modelled), and while far from it falls back to
##    GROW for food when hunger drops below BOSS_FOOD_HUNGER_FRAC. Fight: hugs the boss (swims into its body, leading
##    it by LEAD_S of its velocity): inside dash_min_range_m it charges only after boss.hug_charge_after_s (S7 close
##    charge, dodged like any other tell), the bodies touch, so every bite lands (0.5 s cooldown against its 1.5 s);
##    bites whenever the boss is in the mouth cone or the bodies touch,
##    Bite-Dashes in from mid range; during the boss TELL / DASH aimed at it, swims sideways off the locked charge
##    line (the perpendicular closest to its heading) with boost; a STUNNED boss is touched for the finisher. No
##    retreat once engaged: fleeing a 7 m/s boss means eating a charge (seen in the first runs); the entry gate
##    (HP / XP / hunger) is what keeps the fight winnable.
## Pick policy (contract): Hunter nodes until Bite-Dash is owned, then Survivor nodes until Sonar is owned, then
## BEST_ORDER; the first offered node when nothing matches.

enum Plan { GROW, BOSS }

const BOSS_READY_XP_FRAC: float = 0.95
const BOSS_READY_HP_FRAC: float = 0.95
const BOSS_READY_HUNGER_FRAC: float = 0.6
const BOSS_FOOD_HUNGER_FRAC: float = 0.45
## Beyond this distance from the boss the bot is "travelling" (may stop to eat).
const BOSS_TRAVEL_M: float = 40.0
## Fight aim: the boss centre plus its velocity x LEAD_S.
const LEAD_S: float = 0.2
## Bite-Dash only when the target lies this well inside the heading (cosine).
const DASH_FACING_COS: float = 0.97
const FLEE_DASH_COS: float = 0.9
const DODGE_LOOKAHEAD_M: float = 12.0
const HUNTER: String = "hunter"
const SURVIVOR: String = "survivor"
const BITE_DASH_ID: String = "hunter_bite_dash"
const SONAR_ID: String = "survivor_sonar"
const BEST_ORDER: PackedStringArray = [
	"survivor_armor_scales", "hunter_bite_power", "hunter_swim_speed", "hunter_turbo_boost",
	"survivor_efficient_metabolism", "survivor_sonar", "hunter_bite_dash", "survivor_wide_vision",
]

var plan: Plan = Plan.GROW
## Ability uses by id (String -> int).
var ability_uses: Dictionary = {"bite_dash": 0, "sonar": 0}
## Dodge manoeuvres started (one per boss TELL aimed at the bot).
var dodges: int = 0

var _lunge_len: float = 8.0
var _dodging_tell: int = -1  # tick of the TELL being dodged
var _dodge_dir: Vector3 = Vector3.ZERO


func _init(world: SimWorld, player_id: int, seed: int) -> void:
	super._init(world, player_id, seed)
	mode_ticks["BOSS"] = 0
	_lunge_len = float(world.content.get_ability(&"bite_dash").get("lunge_distance_m", _lunge_len))


## The node to pick from `offer` (policy in the class doc).
func choose_pick(offer: PackedStringArray) -> String:
	if offer.is_empty():
		return ""
	var e: SimEntity = _w.get_entity(_id)
	var owned: PackedStringArray = e.mutations if e != null else PackedStringArray()
	var branch: String = ""
	if not owned.has(BITE_DASH_ID):
		branch = HUNTER
	elif not owned.has(SONAR_ID):
		branch = SURVIVOR
	if not branch.is_empty():
		for id in offer:
			if String(_db.get_mutation(StringName(id)).get("branch", "")) == branch:
				return id
	for id in BEST_ORDER:
		if offer.has(id):
			return id
	return offer[0]


func commands() -> Array[SimCommand]:
	var e: SimEntity = _w.get_entity(_id)
	if e == null or not e.alive:
		plan = Plan.GROW
		return super.commands()
	var boss: SimEntity = _w.get_entity(_w.boss_id())
	_update_plan(e, boss)
	var out: Array[SimCommand] = []
	if plan == Plan.BOSS and not _travel_food(e, boss):
		mode_ticks["BOSS"] += 1
		_fight(out, e, boss)
		_use_sonar(out, e, true)
		return out
	out = super.commands()
	_grow_abilities(out, e)
	return out


func observe(events: Array[SimEvent]) -> void:
	super.observe(events)
	for ev in events:
		if ev.type == SimEvent.Type.ABILITY_USED and ev.entity_id == _id:
			var a: String = String(ev.data.get("ability", ""))
			ability_uses[a] = int(ability_uses.get(a, 0)) + 1


# ------------------------------------------------------------------ plan

func _update_plan(e: SimEntity, boss: SimEntity) -> void:
	if boss == null or not boss.alive:
		plan = Plan.GROW
		return
	if plan == Plan.BOSS:
		return
	var hp_frac: float = e.hp / e.max_hp if e.max_hp > 0.0 else 1.0
	var last: Dictionary = _bands[_bands.size() - 1]
	var ready_xp: float = float(last.get("xp_full_length", 0.0)) * BOSS_READY_XP_FRAC
	var hunger_frac: float = e.hunger / _hunger_max if _hunger_max > 0.0 else 1.0
	if e.band >= _bands.size() and e.xp >= ready_xp and hp_frac >= BOSS_READY_HP_FRAC and hunger_frac >= BOSS_READY_HUNGER_FRAC:
		plan = Plan.BOSS
		_target = -1
		_site = -1


# True while travelling to the boss and hungry: GROW handles this tick (eats on the way).
func _travel_food(e: SimEntity, boss: SimEntity) -> bool:
	if boss == null or BossBrain.is_engaged(boss) and boss.boss_target == _id:
		return false
	var hunger_frac: float = e.hunger / _hunger_max if _hunger_max > 0.0 else 1.0
	return hunger_frac < BOSS_FOOD_HUNGER_FRAC and e.position.distance_to(boss.position) > BOSS_TRAVEL_M


# ------------------------------------------------------------------ boss fight

func _fight(out: Array[SimCommand], e: SimEntity, b: SimEntity) -> void:
	var t: int = _w.tick
	var to: Vector3 = b.position - e.position
	var d: float = to.length()
	var dir_to: Vector3 = to / d if d > 1e-6 else e.heading
	var boss_r: float = _w.collision_radius(b)
	var reach: float = e.length_m * _reach_mult + boss_r
	var speed: float = _band_speed(e) * e.swim_speed_mult
	if b.boss_state == BossBrain.State.STUNNED:
		_dodging_tell = -1
		_steer(out, e, b.position, speed, e.stamina > BOOST_MIN_STAMINA, false)
		return
	var charging: bool = (b.boss_state == BossBrain.State.TELL or b.boss_state == BossBrain.State.DASH) and b.boss_target == _id
	if charging:
		if _dodging_tell != b.boss_state_tick and b.boss_state == BossBrain.State.TELL:
			_dodging_tell = b.boss_state_tick
			_dodge_dir = _pick_dodge(e, b)
			dodges += 1
		if not _dodge_dir.is_zero_approx():
			_steer(out, e, e.position + _dodge_dir * DODGE_LOOKAHEAD_M, speed, e.stamina > 0.0, false)
			_try_bite(out, e, b, reach)
			return
	# hug: inside its body every bite of ours lands (it charges only after hug_charge_after_s, dodged above)
	var aim: Vector3 = b.position + b.velocity * LEAD_S
	var da: float = e.position.distance_to(aim)
	var boost: bool = da > BOOST_CHASE_M and e.stamina > BOOST_MIN_STAMINA
	var want: float = minf(speed, b.speed + maxf(da * 2.0, 1.0))
	_steer(out, e, aim, want if da < BOOST_CHASE_M else speed, boost, false)
	_try_bite(out, e, b, reach)
	if d > reach and d < reach + _lunge_len - 1.0 and e.heading.dot(dir_to) > DASH_FACING_COS:
		_try_ability(out, e, &"bite_dash")
	if t % RESCAN_TICKS == 0:
		_target = -1


func _try_bite(out: Array[SimCommand], e: SimEntity, b: SimEntity, reach: float) -> void:
	if _w.tick < e.bite_ready_tick:
		return
	if BossBrain.bodies_touch(_w, e, b) or SimRules.in_cone(e.position, e.heading, b.position, reach, _cos_half):
		out.append(SimCommand.bite(_id, b.id, _w.tick))


# Sideways off the locked charge line: of the four perpendiculars the one closest to the current heading (no dive
# into the seabed, no climb through the surface).
func _pick_dodge(e: SimEntity, b: SimEntity) -> Vector3:
	var line: Vector3 = b.boss_dir.normalized() if not b.boss_dir.is_zero_approx() else b.heading
	var side: Vector3 = line.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = line.cross(Vector3.RIGHT)
	side = side.normalized()
	var up: Vector3 = side.cross(line).normalized()
	var best := Vector3.ZERO
	var best_dot: float = -INF
	var floor_y: float = _w.seabed.height_at(e.position.x, e.position.z) if _w.seabed != null else -INF
	for c: Vector3 in [side, -side, up, -up]:
		if c.y < -0.5 and e.position.y - floor_y < DODGE_LOOKAHEAD_M:
			continue
		if c.y > 0.5 and e.position.y > -DODGE_LOOKAHEAD_M:
			continue
		var dot: float = c.dot(e.heading)
		if dot > best_dot:
			best_dot = dot
			best = c
	return best


# ------------------------------------------------------------------ abilities

func _grow_abilities(out: Array[SimCommand], e: SimEntity) -> void:
	_use_sonar(out, e, not _threats.is_empty())
	if mode == Mode.FLEE:
		var away: Vector3 = _flee_vector(e)
		if not away.is_zero_approx() and e.heading.dot(away.normalized()) > FLEE_DASH_COS:
			_try_ability(out, e, &"bite_dash")
		return
	if mode != Mode.FORAGE or _target < 0:
		return
	var c: SimEntity = _w.get_entity(_target)
	if c == null or c.kind != SimEntity.Kind.CREATURE or SimRules.can_swallow(e.length_m, _w.effective_length(c), _swallow_ratio):
		return
	var to: Vector3 = c.position - e.position
	var d: float = to.length()
	var reach: float = e.length_m * _reach_mult + _w.collision_radius(c)
	if d > reach and d < reach + _lunge_len * 0.9 and d > 1e-6 and e.heading.dot(to / d) > DASH_FACING_COS:
		_try_ability(out, e, &"bite_dash")


func _use_sonar(out: Array[SimCommand], e: SimEntity, wanted: bool) -> void:
	if wanted:
		_try_ability(out, e, &"sonar")


func _try_ability(out: Array[SimCommand], e: SimEntity, ability: StringName) -> void:
	if not e.abilities.has(String(ability)) or _w.ability_cooldown_left(_id, ability) > 0.0 or e.dash_until_tick >= 0:
		return
	out.append(SimCommand.ability(_id, ability, _w.tick))
