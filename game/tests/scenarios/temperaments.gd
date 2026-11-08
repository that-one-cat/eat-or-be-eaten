extends Node
## S3 acceptance scenario (headless): godot --headless --path game res://tests/scenarios/temperaments.tscn
## Fresh isolated SimWorlds from the shipped data (spawners off, the default), entities placed with spawn_entity()
## at offsets from ARENA, the player driven only by SimCommands. Prints one "TEMPERAMENTS <criterion>: PASS|FAIL ..."
## line per criterion and "TEMPERAMENTS: PASS|FAIL ...", then quits with 0 (all pass) or 1.
## Criteria:
## - b1_swallows_plankton: plankton in a B1 player's mouth cone is swallowed (EATEN plankton<-player, XP + the
##   SimRules.xp_gain value, hunger up, plankton gone). Vitals on, so the hunger is below the maximum first.
## - b1_cannot_swallow_puffer: a puffer held in the mouth cone for HOLD_S: no EATEN, puffer alive, hp untouched
##   (brains off in this world so the puffer stays put and cannot retaliate; vitals off, so hp arithmetic is exact).
## - b1_bites_puffer_and_is_spiked: BITE on that puffer: BITTEN value = band-1 bite_power x length^2 x bite_mult,
##   puffer hp down by exactly that, INFLATED (inflated_until_tick = bite tick + inflate.duration_s); a second bite
##   while inflated: SPIKED value = spike frac x the player's max HP and the player's hp down by exactly that. The
##   inflating bite itself may spike or not (sim rule choice); if it does, the same exact amount is required.
## - barracuda_attacks_unprovoked: an idle B1 player inside a barracuda's detection radius (the player never bites):
##   BITTEN player<-barracuda within BARRACUDA_WINDOW_S.
## - grouper_only_retaliates: an idle player kept next to a grouper for CALM_S: no grouper bite; one player bite:
##   the grouper bites back within COUNTER_WINDOW_S; the player then keeps away and never bites again: the
##   grouper's last bite is before bite tick + retaliate_duration_s + 1 s and it is calm (no aggro) by then;
##   kept next to it again for RECALM_S: no bite. The player is B3 here (setup XP, like the unit tests) so it survives
##   the counter-bites (a grouper kills a B1 / B2 player in one bite).
## - no_unprovoked_bites_from_passive_or_retaliate: over every world, no BITTEN with a passive biter, and every
##   retaliator bite hits someone that bit it within retaliate_duration_s.
## - determinism: a second run of all worlds prints the same criterion lines.

const SEED: int = 1104
## Mid-water point inside open_water and rock_arches, >= 15 m above the seabed, >= 30 m from every obstacle (the
## same arena as tests/s3_support.gd; checked again by the "arena" guard below).
const ARENA: Vector3 = Vector3(150.0, -25.0, 60.0)
const ARENA_MIN_CLEARANCE_M: float = 10.0
const PRE_SWALLOW_S: float = 3.0
const HOLD_S: float = 2.0
const BARRACUDA_OFFSET: Vector3 = Vector3(12.0, 0.0, 0.0)
const BARRACUDA_WINDOW_S: float = 20.0
const GROUPER_OFFSET: Vector3 = Vector3(0.0, 0.0, -1.5)
const CALM_S: float = 10.0
const APPROACH_S: float = 10.0
const COUNTER_WINDOW_S: float = 4.0
const RECALM_S: float = 5.0
## "Next to": the player keeps within FOLLOW_M of the grouper (MOVE commands only), keeps away beyond KEEP_AWAY_M.
const FOLLOW_M: float = 2.5
const KEEP_AWAY_M: float = 10.0
const EPS: float = 1e-9

var _all_ok: bool = true
var _content: ContentDB
var _player_species: StringName = &""
var _bites: Array[Dictionary] = []  # every BITTEN of every world: {world, tick, biter, victim, species}


func _ready() -> void:
	_content = ContentDB.load_from_dir()
	if not _content.is_valid():
		_report("setup", false, "content invalid: %s" % "; ".join(_content.errors))
		_summary("setup failed")
		get_tree().quit(1)
		return
	for sid in _content.species_ids():
		if bool(_content.get_species(sid).get("playable", false)):
			_player_species = sid
			break
	var wall0: int = Time.get_ticks_msec()
	var first: Array[Array] = _run_all()
	var second: Array[Array] = _run_all()
	for r in first:
		_report(r[0], r[1], r[2])
	_report("determinism", str(first) == str(second), "two runs, %d criterion lines, identical=%s" % [first.size(), str(first) == str(second)])
	_summary("criteria=%d wall=%.2f s" % [first.size() + 1, float(Time.get_ticks_msec() - wall0) / 1000.0])
	get_tree().quit(0 if _all_ok else 1)


func _run_all() -> Array[Array]:
	_bites.clear()
	var out: Array[Array] = []
	out.append(_arena_guard())
	out.append(_swallow_plankton())
	out.append_array(_puffer())
	out.append(_barracuda())
	out.append(_grouper())
	out.append(_no_unprovoked())
	return out


func _arena_guard() -> Array:
	var w := _world(true, false)
	var floor_y: float = w.seabed.height_at(ARENA.x, ARENA.z)
	var ok: bool = ARENA.y - floor_y >= ARENA_MIN_CLEARANCE_M and NpcBrain.hiding_tag_at(w, ARENA) == &""
	return ["arena", ok, "arena=%s seabed=%.2f clearance=%.2f m (>= %.0f) hiding=%s" % [ARENA, floor_y, ARENA.y - floor_y, ARENA_MIN_CLEARANCE_M, NpcBrain.hiding_tag_at(w, ARENA)]]


# ------------------------------------------------------------------ criteria

func _swallow_plankton() -> Array:
	var w := _world(true, true)
	var p: SimEntity = _player(w, ARENA)
	_run(w, 0, roundi(PRE_SWALLOW_S * SimWorld.TICK_RATE))
	var plen: float = float(_content.get_species(&"plankton")["length_m"]["min"])
	var pre_ok: bool = SimRules.can_swallow(p.length_m, plen, _rule("swallow_ratio"))
	var xp0: float = p.xp
	var hunger0: float = p.hunger
	var expect_xp: float = SimRules.xp_gain(float(_content.get_species(&"plankton")["xp"]), p.length_m, plen, _content.rules()["xp_falloff"])
	var pk: int = w.spawn_entity(&"plankton", p.position + p.heading * p.length_m * _rule("mouth_reach_mult") * 0.5, plen)
	var evs: Array[SimEvent] = _run(w, 0, SimWorld.TICK_RATE)
	var eaten: SimEvent = _find(evs, SimEvent.Type.EATEN, pk, p.id)
	var ok: bool = pre_ok and eaten != null and absf(p.xp - xp0 - expect_xp) <= EPS and p.hunger > hunger0 and w.get_entity(pk) == null
	return ["b1_swallows_plankton", ok, "player len=%.3f band=%d plankton len=%.3f eaten=%s at tick %d xp %.3f->%.3f (expect +%.3f) hunger %.2f->%.2f gone=%s" % [
		p.length_m, p.band, plen, eaten != null, eaten.tick if eaten else -1, xp0, p.xp, expect_xp, hunger0, p.hunger, w.get_entity(pk) == null]]


# Puffer held in the mouth cone (brains off: it does not move or retaliate), then bitten twice.
func _puffer() -> Array[Array]:
	var w := _world(false, false)
	var p: SimEntity = _player(w, ARENA)
	var sp: Dictionary = _content.get_species(&"puffer")
	var plen: float = float(sp["length_m"]["min"])
	var reach: float = p.length_m * _rule("mouth_reach_mult")
	var cos_half: float = cos(deg_to_rad(_rule("mouth_cone_deg")))
	var pf_id: int = w.spawn_entity(&"puffer", p.position + p.heading * reach * 0.6, plen)
	var pf: SimEntity = w.get_entity(pf_id)
	var hold: int = roundi(HOLD_S * SimWorld.TICK_RATE)
	var in_cone_ticks: int = 0
	var evs: Array[SimEvent] = []
	for i in hold:
		evs.append_array(_run(w, 1, 1))
		if SimRules.in_cone(p.position, p.heading, pf.position, reach, cos_half):
			in_cone_ticks += 1
	var swallowable: bool = SimRules.can_swallow(p.length_m, w.effective_length(pf), _rule("swallow_ratio"))
	var hold_ok: bool = in_cone_ticks == hold and not swallowable and _find(evs, SimEvent.Type.EATEN, pf_id, -1) == null \
		and w.get_entity(pf_id) != null and absf(pf.hp - pf.max_hp) <= EPS and _find(evs, SimEvent.Type.BITTEN, pf_id, -1) == null
	var r1: Array = ["b1_cannot_swallow_puffer", hold_ok, "player len=%.3f band=%d puffer len=%.3f in_cone=%d/%d ticks swallowable=%s eaten=%s hp=%.4f/%.4f" % [
		p.length_m, p.band, plen, in_cone_ticks, hold, swallowable, _find(evs, SimEvent.Type.EATEN, pf_id, -1) != null, pf.hp, pf.max_hp]]

	var band1: Dictionary = _content.get_band(1)
	var mult: float = float(_content.get_species(_player_species).get("bite_mult", 1.0))
	var dmg: float = float(band1["bite_power"]) * p.length_m * p.length_m * mult
	var spike: float = float(sp["inflate"]["spike_damage_frac_of_biter_max_hp"]) * p.max_hp
	var inflate_ticks: int = roundi(float(sp["inflate"]["duration_s"]) * SimWorld.TICK_RATE)
	var php0: float = p.hp
	var fhp0: float = pf.hp
	var bite_tick: int = w.tick
	w.submit(SimCommand.bite(p.id, pf_id, w.tick))
	evs = _run(w, 1, 1)
	var bitten: SimEvent = _find(evs, SimEvent.Type.BITTEN, pf_id, p.id)
	var inflated: SimEvent = _find(evs, SimEvent.Type.INFLATED, pf_id, -1)
	var spiked: SimEvent = _find(evs, SimEvent.Type.SPIKED, p.id, pf_id)
	# the inflating bite may or may not spike (sim rule choice); when it does, the amount must be exact
	var spike1: float = spiked.value if spiked else 0.0
	var ok1: bool = bitten != null and absf(bitten.value - dmg) <= EPS and absf(fhp0 - pf.hp - dmg) <= EPS \
		and inflated != null and pf.inflated_until_tick == bite_tick + inflate_ticks \
		and (spiked == null or absf(spiked.value - spike) <= EPS) and absf(php0 - p.hp - spike1) <= EPS
	# second bite after the cooldown, still inflated
	_run(w, 1, maxi(p.bite_ready_tick - w.tick, 0))
	var php1: float = p.hp
	var still_inflated: bool = w.tick < pf.inflated_until_tick
	w.submit(SimCommand.bite(p.id, pf_id, w.tick))
	evs = _run(w, 1, 1)
	var spiked2: SimEvent = _find(evs, SimEvent.Type.SPIKED, p.id, pf_id)
	var ok2: bool = still_inflated and spiked2 != null and absf(spiked2.value - spike) <= EPS and absf(php1 - p.hp - spike) <= EPS
	var r2: Array = ["b1_bites_puffer_and_is_spiked", ok1 and ok2, "bite %.4f (expect %.4f) puffer hp %.4f->%.4f inflated_until=%d (expect %d) 1st-bite spike=%s player hp %.4f->%.4f; spike expect %.4f = %.2f x max_hp %.2f; 2nd bite inflated=%s spike=%s player hp %.4f->%.4f" % [
		bitten.value if bitten else -1.0, dmg, fhp0, fhp0 - (bitten.value if bitten else 0.0), pf.inflated_until_tick, bite_tick + inflate_ticks,
		"%.4f" % spiked.value if spiked else "none", php0, php0 - spike1, spike, float(sp["inflate"]["spike_damage_frac_of_biter_max_hp"]), p.max_hp,
		still_inflated, "%.4f" % spiked2.value if spiked2 else "none", php1, p.hp]]
	return [r1, r2]


func _barracuda() -> Array:
	var w := _world(true, false)
	var p: SimEntity = _player(w, ARENA)
	var blen: float = float(_content.get_species(&"barracuda")["length_m"]["min"])
	var detect: float = float(_content.get_species(&"barracuda")["detection_radius_m"])
	var huntable: bool = p.length_m <= _rule("predator_hunt_ratio") * blen and not SimRules.can_swallow(blen, p.length_m, _rule("swallow_ratio"))
	var b_id: int = w.spawn_entity(&"barracuda", ARENA + BARRACUDA_OFFSET, blen)
	var window: int = roundi(BARRACUDA_WINDOW_S * SimWorld.TICK_RATE)
	var bitten: SimEvent = null
	for i in window:
		var evs: Array[SimEvent] = _run(w, 3, 1)
		bitten = _find(evs, SimEvent.Type.BITTEN, p.id, b_id)
		if bitten != null:
			break
	var ok: bool = huntable and BARRACUDA_OFFSET.length() < detect and bitten != null
	return ["barracuda_attacks_unprovoked", ok, "barracuda len=%.2f at %.1f m (detect %.0f m) player len=%.3f band=%d huntable=%s, player issued no commands; bitten=%s after %.2f s dmg=%.2f" % [
		blen, BARRACUDA_OFFSET.length(), detect, p.length_m, p.band, huntable, bitten != null,
		float(bitten.tick) / SimWorld.TICK_RATE if bitten else -1.0, bitten.value if bitten else 0.0]]


func _grouper() -> Array:
	var w := _world(true, false)
	var p: SimEntity = _player(w, ARENA)
	# B3 player (setup write, the sim derives band / length / max HP on the first step) so it survives counter-bites
	p.xp = float(_content.get_band(3)["xp_to_reach"])
	var glen: float = float(_content.get_species(&"grouper")["length_m"]["min"])
	var g_id: int = w.spawn_entity(&"grouper", ARENA + GROUPER_OFFSET, glen)
	var g: SimEntity = w.get_entity(g_id)
	# bystanders: a passive small reef fish and a puffer close by (neither may bite unprovoked)
	w.spawn_entity(_player_species, ARENA + Vector3(1.5, 0.5, 0.0), float(_content.get_species(_player_species)["length_m"]["min"]))
	w.spawn_entity(&"puffer", ARENA + Vector3(-1.5, 0.5, 0.0), float(_content.get_species(&"puffer")["length_m"]["min"]))
	var retaliate_ticks: int = roundi(_rule("retaliate_duration_s") * SimWorld.TICK_RATE)
	var info: PackedStringArray = PackedStringArray()

	# a) idle next to the grouper
	var calm_bites: int = 0
	var max_d: float = 0.0
	for i in roundi(CALM_S * SimWorld.TICK_RATE):
		_follow(w, p, g, FOLLOW_M)
		calm_bites += _count(_run(w, 5, 1), SimEvent.Type.BITTEN, -1, g_id)
		max_d = maxf(max_d, p.position.distance_to(g.position))
	info.append("calm %.0f s: grouper bites=%d max_dist=%.2f m (player len=%.2f band=%d hp=%.0f)" % [CALM_S, calm_bites, max_d, p.length_m, p.band, p.hp])

	# b) approach and bite once
	var bite_tick: int = -1
	var reach: float = p.length_m * _rule("mouth_reach_mult")
	var cos_half: float = cos(deg_to_rad(_rule("mouth_cone_deg")))
	for i in roundi(APPROACH_S * SimWorld.TICK_RATE):
		var d: float = p.position.distance_to(g.position)
		var to: Vector3 = (g.position - p.position).normalized()
		w.submit(SimCommand.move(p.id, to, 0.0 if d < reach else 0.3, w.tick))
		if w.tick >= p.bite_ready_tick and SimRules.in_cone(p.position, p.heading, g.position, reach + w.collision_radius(g), cos_half):
			w.submit(SimCommand.bite(p.id, g_id, w.tick))
		var b: SimEvent = _find(_run(w, 5, 1), SimEvent.Type.BITTEN, g_id, p.id)
		if b != null:
			bite_tick = b.tick
			break
	info.append("player bite at tick %d" % bite_tick)

	# c) idle: the grouper bites back
	var counter_tick: int = -1
	if bite_tick >= 0:
		w.submit(SimCommand.move(p.id, p.heading, 0.0, w.tick))
		w.submit(SimCommand.brake(p.id, true, w.tick))
		for i in roundi(COUNTER_WINDOW_S * SimWorld.TICK_RATE):
			var b: SimEvent = _find(_run(w, 5, 1), SimEvent.Type.BITTEN, p.id, g_id)
			if b != null:
				counter_tick = b.tick
				break
		w.submit(SimCommand.brake(p.id, false, w.tick))
	info.append("counter-bite after %.2f s (<= %.0f)" % [float(counter_tick - bite_tick) / SimWorld.TICK_RATE if counter_tick >= 0 else -1.0, COUNTER_WINDOW_S])

	# d) keep away (no more player bites) until the window + 1 s has passed
	var last_g_bite: int = counter_tick
	var calm_at: int = bite_tick + retaliate_ticks + SimWorld.TICK_RATE
	while bite_tick >= 0 and w.tick <= calm_at:
		var off: Vector3 = p.position - g.position
		if off.length() < KEEP_AWAY_M:
			w.submit(SimCommand.move(p.id, off.normalized(), 1.0, w.tick))
			w.submit(SimCommand.boost(p.id, true, w.tick))
		else:
			w.submit(SimCommand.move(p.id, off.normalized(), 0.0, w.tick))
			w.submit(SimCommand.boost(p.id, false, w.tick))
		for ev in _run(w, 5, 1):
			if ev.type == SimEvent.Type.BITTEN and ev.entity_id == p.id and ev.other_id == g_id:
				last_g_bite = ev.tick
	w.submit(SimCommand.boost(p.id, false, w.tick))
	var calm: bool = g.aggro_target < 0 or g.aggro_until_tick <= w.tick
	info.append("last grouper bite at tick %d (<= %d) calm at %d=%s player hp=%.1f alive=%s" % [last_g_bite, bite_tick + retaliate_ticks + SimWorld.TICK_RATE, w.tick, calm, p.hp, p.alive])

	# e) next to it again
	var recalm_bites: int = 0
	var back: int = 0
	while back < roundi(APPROACH_S * 3.0 * SimWorld.TICK_RATE) and p.position.distance_to(g.position) > FOLLOW_M:
		_follow(w, p, g, FOLLOW_M)
		recalm_bites += _count(_run(w, 5, 1), SimEvent.Type.BITTEN, -1, g_id)
		back += 1
	for i in roundi(RECALM_S * SimWorld.TICK_RATE):
		_follow(w, p, g, FOLLOW_M)
		recalm_bites += _count(_run(w, 5, 1), SimEvent.Type.BITTEN, -1, g_id)
	info.append("back next to it (%.2f m) for %.0f s: grouper bites=%d" % [p.position.distance_to(g.position), RECALM_S, recalm_bites])

	var ok: bool = p.band == 3 and calm_bites == 0 and bite_tick >= 0 and counter_tick >= 0 \
		and counter_tick - bite_tick <= roundi(COUNTER_WINDOW_S * SimWorld.TICK_RATE) \
		and last_g_bite <= bite_tick + retaliate_ticks + SimWorld.TICK_RATE and calm and recalm_bites == 0 and p.alive
	return ["grouper_only_retaliates", ok, "; ".join(info)]


func _no_unprovoked() -> Array:
	var retaliate_ticks: int = roundi(_rule("retaliate_duration_s") * SimWorld.TICK_RATE)
	var bad: PackedStringArray = PackedStringArray()
	var counted: Dictionary = {}
	for b in _bites:
		var temper: String = "player" if b["species"] == "player" else String(_content.get_species(StringName(b["species"])).get("temperament", ""))
		counted[temper] = int(counted.get(temper, 0)) + 1
		if temper == "passive":
			bad.append("passive %s bit %d at tick %d (world %d)" % [b["species"], b["victim"], b["tick"], b["world"]])
		elif temper == "retaliate":
			var provoked: bool = false
			for o in _bites:
				if o["world"] == b["world"] and o["biter"] == b["victim"] and o["victim"] == b["biter"] and o["tick"] <= b["tick"] and b["tick"] - int(o["tick"]) <= retaliate_ticks:
					provoked = true
					break
			if not provoked:
				bad.append("retaliator %s bit %d unprovoked at tick %d (world %d)" % [b["species"], b["victim"], b["tick"], b["world"]])
	return ["no_unprovoked_bites_from_passive_or_retaliate", bad.is_empty(), "bites by temperament=%s %s" % [JSON.stringify(counted), "; ".join(bad)]]


# ------------------------------------------------------------------ helpers

func _world(brains: bool, vitals: bool) -> SimWorld:
	var w := SimWorld.new(SEED, _content)
	w.brains_enabled = brains
	w.vitals_enabled = vitals
	w.pick_pause_enabled = false  # S6: a band-up offer would pause these one-player arenas
	return w


func _player(w: SimWorld, pos: Vector3) -> SimEntity:
	var len_m: float = float(_content.get_band(1)["length_m"]["min"])
	return w.get_entity(w.spawn_entity(_player_species, pos, len_m, true))


# MOVE commands only: close in when farther than `dist`, otherwise drift (no thrust). Never bites.
func _follow(w: SimWorld, p: SimEntity, g: SimEntity, dist: float) -> void:
	var to: Vector3 = g.position - p.position
	w.submit(SimCommand.move(p.id, to.normalized(), 0.3 if to.length() > dist else 0.0, w.tick))


# Steps `n` ticks and returns their events; records every BITTEN for the cross-world check (world tag `wid`).
func _run(w: SimWorld, wid: int, n: int) -> Array[SimEvent]:
	var out: Array[SimEvent] = []
	for i in n:
		var from: int = w.tick
		w.step()
		for ev in w.events_since(from):
			out.append(ev)
			if ev.type == SimEvent.Type.BITTEN:
				var biter: SimEntity = w.get_entity(ev.other_id)
				var sid: String = "player" if biter != null and biter.is_player else (String(biter.species_id) if biter else "")
				_bites.append({"world": wid, "tick": ev.tick, "biter": ev.other_id, "victim": ev.entity_id, "species": sid})
	return out


# First event of `type` with that subject / other party (-1 = any).
static func _find(evs: Array[SimEvent], type: SimEvent.Type, entity_id: int, other_id: int) -> SimEvent:
	for ev in evs:
		if ev.type == type and (entity_id < 0 or ev.entity_id == entity_id) and (other_id < 0 or ev.other_id == other_id):
			return ev
	return null


static func _count(evs: Array[SimEvent], type: SimEvent.Type, entity_id: int, other_id: int) -> int:
	var n: int = 0
	for ev in evs:
		if ev.type == type and (entity_id < 0 or ev.entity_id == entity_id) and (other_id < 0 or ev.other_id == other_id):
			n += 1
	return n


func _rule(key: String) -> float:
	return float(_content.rules()[key])


func _report(criterion: String, ok: bool, info: String) -> void:
	_all_ok = _all_ok and ok
	print("TEMPERAMENTS %s: %s %s" % [criterion, "PASS" if ok else "FAIL", info])


func _summary(info: String) -> void:
	print("TEMPERAMENTS: %s %s" % ["PASS" if _all_ok else "FAIL", info])
