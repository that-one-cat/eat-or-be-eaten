extends Node
## S4 headless sim benchmark (engine tripwire, GAME_DESIGN section 12):
##   godot --headless --path game res://bench/bench_sim.tscn -- --frames=<ticks> [--warmup=<ticks>] [--seed=<n>] [--no-gate]
## Default reef map with spawners, schools and plankton on (NpcSpawner.set_enabled), vitals on, 16 player agents
## (tests/bots/bench_agent.gd, SimCommands only) spread over shallows / kelp forest / rock arches in bands 1-3.
## Fixed 30 Hz stepping, as fast as possible (no real-time pacing: the tick cost does not depend on it); the
## first --warmup ticks are not measured. The bench paces the eat rate: it hands an eat token to the next agent
## that sees something edible while the agents' EATEN events so far (eater = a player), plus the expected EATEN
## of the hunts that have not eaten yet (running mean of EATEN per token, prior HUNT_PRIOR_EATEN), stay below
## EAT_RATE_PER_MIN, at most MAX_HUNTERS at a time. "Eat events" = EATEN with a player eater: that is the load the
## agents control. NPC predation (barracuda / sharks swallowing promoted members and remains) comes on top, from
## the sim and the data alone; it is reported separately (events_per_min.eaten_by_npcs, eaten_by_npc_species).
## Measures per tick: SimWorld.step() wall time (tick), per-phase time (SimWorld.phase_usec with profile_clock set),
## school/flocking = brains + schools phases (all NPC brain thinks, a conservative upper bound of the school-member
## steering, plus TierManager), agent command time; entity counts every COUNT_SAMPLE_TICKS; process RSS via
## `ps -o rss=` (sampled every RSS_SAMPLE_TICKS, max reported) and OS.get_static_memory_usage().
## Prints one BENCH_JSON line; thresholds from res://bench/thresholds.json ("sim"); exit 0 / 2 (tripwire) /
## 3 (invalid load), always 0 with --no-gate. The editor binary is a debug build: release exports run faster.

const BenchUtil := preload("res://bench/bench_util.gd")
const BenchAgent := preload("res://tests/bots/bench_agent.gd")

const DEFAULT_TICKS: int = 1800
const DEFAULT_WARMUP: int = 300
const DEFAULT_SEED: int = 1
## Agents per zone (zone id, count); bands cycle through AGENT_BANDS in creation order.
const AGENT_ZONES: Array = [["shallows", 6], ["kelp_forest", 6], ["rock_arches", 4]]
const AGENT_BANDS: Array[int] = [1, 2, 3]
const EAT_RATE_PER_MIN: float = 50.0
const MAX_HUNTERS: int = 4
## Prior of the EATEN events one eat token yields (one kill gives 3-6 remains bits, NPCs take part of them).
const HUNT_PRIOR_EATEN: float = 2.0
const COUNT_SAMPLE_TICKS: int = 30
const RSS_SAMPLE_TICKS: int = 600

var _world: SimWorld
var _agents: Array[BenchAgent] = []
var _rr: int = 0  # round-robin start for the next eat token


func _ready() -> void:
	var code: int = _run()
	get_tree().quit(code)


func _run() -> int:
	var wall0: int = Time.get_ticks_usec()
	var args: Dictionary = BenchUtil.parse_args()
	var ticks: int = maxi(1, BenchUtil.arg_int(args, "frames", DEFAULT_TICKS))
	var warmup: int = maxi(0, BenchUtil.arg_int(args, "warmup", DEFAULT_WARMUP))
	var seed: int = BenchUtil.arg_int(args, "seed", DEFAULT_SEED)
	var gate: bool = not args.has("no-gate")
	var content: ContentDB = ContentDB.load_from_dir()
	if not content.is_valid():
		push_error("bench_sim: content invalid: %s" % "; ".join(content.errors))
		return 1
	_world = SimWorld.new(seed, content)
	_world.vitals_enabled = true
	NpcSpawner.set_enabled(_world, true)
	_world.profile_clock = Callable(Time, "get_ticks_usec")
	var placement: Dictionary = _spawn_agents(content, seed)

	var n_phases: int = SimWorld.PHASE_NAMES.size()
	var tick_us := PackedFloat64Array()
	var school_us := PackedFloat64Array()
	var agent_us := PackedFloat64Array()
	var phase_us: Array[PackedFloat64Array] = []
	for p in n_phases:
		phase_us.append(PackedFloat64Array())
	var c_ambient := PackedInt32Array()
	var c_inter := PackedInt32Array()
	var c_large := PackedInt32Array()
	var c_promoted := PackedInt32Array()
	var c_entities := PackedInt32Array()
	var ev_count: Dictionary = {}
	for k in ["eaten_total", "eaten_by_players", "eaten_by_npcs", "eaten_food_bits", "eaten_creatures", "school_member_eaten",
			"plankton_eaten", "died_npc", "player_deaths", "bitten", "promoted", "demoted", "school_respawned"]:
		ev_count[k] = 0
	var eaten_since_start: int = 0  # agents' EATEN events since tick 0 (pacing input)
	var npc_eaters: Dictionary = {}  # NPC species -> EATEN events it caused (measured window)
	var food_bits: Dictionary = {}  # live food bit ids (EATEN of a bit vs a creature)
	var rss_max: float = BenchUtil.rss_mb()
	var read_from: int = 0
	var t_measure0: int = 0

	for i in warmup + ticks:
		var measuring: bool = i >= warmup
		if i == warmup:
			t_measure0 = Time.get_ticks_usec()
		var a0: int = Time.get_ticks_usec()
		for ag: BenchAgent in _agents:
			for c: SimCommand in ag.commands():
				_world.submit(c)
		var a1: int = Time.get_ticks_usec()
		_world.step()
		var a2: int = Time.get_ticks_usec()
		var evs: Array[SimEvent] = _world.events_since(read_from)
		read_from = _world.tick
		_world.clear_events_before(_world.tick)
		for ag: BenchAgent in _agents:
			ag.observe(evs)
		for ev in evs:
			match ev.type:
				SimEvent.Type.FOOD_SPAWNED:
					food_bits[ev.entity_id] = true
				SimEvent.Type.EATEN:
					var bit: bool = food_bits.erase(ev.entity_id)
					var eater: SimEntity = _world.get_entity(ev.other_id)
					var by_player: bool = eater != null and eater.is_player
					eaten_since_start += 1 if by_player else 0
					if measuring:
						ev_count["eaten_total"] += 1
						ev_count["eaten_by_players" if by_player else "eaten_by_npcs"] += 1
						if eater != null and not by_player:
							npc_eaters[String(eater.species_id)] = int(npc_eaters.get(String(eater.species_id), 0)) + 1
						ev_count["eaten_food_bits" if bit else "eaten_creatures"] += 1
		if measuring:
			for ev in evs:
				match ev.type:
					SimEvent.Type.SCHOOL_MEMBER_EATEN:
						ev_count["school_member_eaten"] += 1
					SimEvent.Type.PLANKTON_EATEN:
						ev_count["plankton_eaten"] += 1
					SimEvent.Type.DIED:
						var dead: SimEntity = _world.get_entity(ev.entity_id)
						ev_count["player_deaths" if dead != null and dead.is_player else "died_npc"] += 1
					SimEvent.Type.BITTEN:
						ev_count["bitten"] += 1
					SimEvent.Type.SCHOOL_MEMBER_PROMOTED:
						ev_count["promoted"] += 1
					SimEvent.Type.SCHOOL_MEMBER_DEMOTED:
						ev_count["demoted"] += 1
					SimEvent.Type.SCHOOL_MEMBER_RESPAWNED:
						ev_count["school_respawned"] += 1
		_pace_eating(eaten_since_start, i + 1)
		if not measuring:
			continue
		tick_us.append(float(a2 - a1))
		agent_us.append(float(a1 - a0))
		for p in n_phases:
			phase_us[p].append(float(_world.phase_usec[p]))
		school_us.append(float(_world.phase_usec[SimWorld.Phase.BRAINS] + _world.phase_usec[SimWorld.Phase.SCHOOLS]))
		var m: int = i - warmup
		if m % COUNT_SAMPLE_TICKS == 0 or m == ticks - 1:
			c_ambient.append(_ambient_members())
			c_inter.append(_world.npc_count(SimWorld.TIER_INTERACTIVE))
			c_large.append(_world.npc_count(SimWorld.TIER_LARGE))
			c_promoted.append(_world.schools.promoted_count() if _world.schools != null else 0)
			c_entities.append(_world.entity_count())
		if m % RSS_SAMPLE_TICKS == RSS_SAMPLE_TICKS - 1:
			rss_max = maxf(rss_max, BenchUtil.rss_mb())
	var measure_s: float = float(Time.get_ticks_usec() - t_measure0) / 1e6
	var rss_end: float = BenchUtil.rss_mb()
	rss_max = maxf(rss_max, rss_end)

	var minutes: float = float(ticks) / float(SimWorld.TICK_RATE) / 60.0
	var per_min: Dictionary = {}
	for k in ev_count:
		per_min[k] = snappedf(float(ev_count[k]) / minutes, 0.1)
	var phase_p95: Dictionary = {}
	var phase_mean: Dictionary = {}
	for p in n_phases:
		var s: Dictionary = BenchUtil.stats_ms(phase_us[p])
		phase_p95[SimWorld.PHASE_NAMES[p]] = s["p95"]
		phase_mean[SimWorld.PHASE_NAMES[p]] = s["mean"]
	var tick_stats: Dictionary = BenchUtil.stats_ms(tick_us)
	var school_stats: Dictionary = BenchUtil.stats_ms(school_us)
	var amb: Dictionary = BenchUtil.count_stats(c_ambient)
	var inter: Dictionary = BenchUtil.count_stats(c_inter)
	var large: Dictionary = BenchUtil.count_stats(c_large)
	var npc_fish_min: int = 0
	for j in c_ambient.size():
		var total: int = c_ambient[j] + c_inter[j] + c_large[j]
		npc_fish_min = total if j == 0 else mini(npc_fish_min, total)
	var deaths: int = 0
	var tokens: int = 0
	var agent_eaten: int = 0
	var alive_end: int = 0
	var bands_end: Dictionary = {}
	for ag: BenchAgent in _agents:
		var e: SimEntity = _world.get_entity(ag.id)
		deaths += e.deaths
		tokens += ag.tokens
		agent_eaten += ag.eaten
		alive_end += 1 if e.alive else 0
		bands_end["B%d" % e.band] = int(bands_end.get("B%d" % e.band, 0)) + 1

	var result: Dictionary = {"bench": "bench_sim"}
	result.merge(BenchUtil.machine())
	result.merge({
		"seed": seed,
		"map": String(_world.map_id),
		"tick_rate_hz": SimWorld.TICK_RATE,
		"ticks_measured": ticks,
		"warmup_ticks": warmup,
		"sim_seconds_measured": snappedf(float(ticks) / float(SimWorld.TICK_RATE), 0.01),
		"wall_s_measured": snappedf(measure_s, 0.01),
		"wall_s_total": snappedf(float(Time.get_ticks_usec() - wall0) / 1e6, 0.01),
		"tick_ms": tick_stats,
		"phase_p95_ms": phase_p95,
		"phase_mean_ms": phase_mean,
		"school_flocking_ms": school_stats,
		"school_flocking_definition": "per tick: brains phase (every NPC brain think, incl. promoted school members) + schools phase (TierManager)",
		"agent_commands_ms": BenchUtil.stats_ms(agent_us),
		"entities": {
			"ambient_members": amb,
			"interactive": inter,
			"large": large,
			"promoted": BenchUtil.count_stats(c_promoted),
			"sim_entities": BenchUtil.count_stats(c_entities),
			"npc_fish_min": npc_fish_min,
			"schools": _world.schools.school_count() if _world.schools != null else 0,
		},
		"agents": {
			"count": _agents.size(),
			"placement": placement,
			"bands_end": bands_end,
			"alive_end": alive_end,
			"deaths_total": deaths,
			"eat_tokens": tokens,
			"eaten_by_agents": agent_eaten,
		},
		"eat_rate_target_per_min": EAT_RATE_PER_MIN,
		"eat_rate_definition": "EATEN events with a player-agent eater (paced); eaten_total adds NPC predation",
		"eat_pacing": "token while agent EATEN so far + unfed hunters x mean EATEN per token < target pace, max %d hunters" % MAX_HUNTERS,
		"final_state_hash": str(_world.state_hash()),
		"events": ev_count,
		"events_per_min": per_min,
		"eaten_by_npc_species": npc_eaters,
		"memory": {
			"rss_mb_max": rss_max,
			"rss_mb_end": rss_end,
			"rss_method": "ps -o rss= -p <pid> (KiB), sampled every %d ticks + end" % RSS_SAMPLE_TICKS,
			"static_mb": snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1),
			"static_peak_mb": snappedf(float(OS.get_static_memory_peak_usage()) / 1048576.0, 0.1),
		},
	})
	var th: Dictionary = BenchUtil.load_thresholds("sim")
	var tw: Dictionary = th.get("tripwires", {})
	var va: Dictionary = th.get("validity", {})
	var tripwires: Dictionary = {
		"tick_p95_ms": BenchUtil.at_most(tick_stats["p95"], float(tw.get("tick_p95_ms", 8.0))),
		"rss_mb": BenchUtil.at_most(rss_max, float(tw.get("rss_mb", 600.0))),
		"school_flocking_p95_ms": BenchUtil.at_most(school_stats["p95"], float(tw.get("school_flocking_p95_ms", 3.0))),
	}
	var eat_rate: float = per_min["eaten_by_players"]
	var validity: Dictionary = {
		"agents": BenchUtil.at_least(_agents.size(), float(va.get("agents_min", 16))),
		"npc_fish": BenchUtil.at_least(npc_fish_min, float(va.get("npc_fish_min", 900))),
		"eat_rate_per_min": {"value": eat_rate, "min": float(va.get("eat_rate_per_min_min", 35.0)), "max": float(va.get("eat_rate_per_min_max", 70.0)),
			"pass": eat_rate >= float(va.get("eat_rate_per_min_min", 35.0)) and eat_rate <= float(va.get("eat_rate_per_min_max", 70.0))},
		# `ps` exists on macOS / Linux only: -1 (not measured) is valid on Windows, where the rss tripwire cannot fail
		"rss_measured": BenchUtil.at_least(rss_max, -1.0 if OS.get_name() == "Windows" else 0.0),
		"ticks_measured": BenchUtil.at_least(float(ticks), float(va.get("ticks_measured_min", 1800))),
		"load_avg_per_thread": BenchUtil.load_check(result, float(va.get("load_avg_per_thread_max", 1.0))),
	}
	return BenchUtil.finish(result, tripwires, validity, gate)


# Spawns the agents (player entities) at their start points; returns the placement summary.
func _spawn_agents(content: ContentDB, seed: int) -> Dictionary:
	var species: StringName = _player_species(content)
	var boost_max: float = float(content.get_ability(&"boost").get("stamina_max", 0.0))
	var zones: Array = _world.map.get("zones", [])
	var placement: Dictionary = {}
	var n: int = 0
	for entry in AGENT_ZONES:
		var zone_id: String = entry[0]
		var count: int = entry[1]
		var zi: int = -1
		for z in zones.size():
			if String(zones[z].get("id", "")) == zone_id:
				zi = z
		if zi < 0:
			push_error("bench_sim: map has no zone %s" % zone_id)
			continue
		var lo: Vector3 = _vec(zones[zi]["aabb"]["min"])
		var hi: Vector3 = _vec(zones[zi]["aabb"]["max"])
		var own: Array = []
		if _world.schools != null:
			for s in _world.schools.school_count():
				var sc: SchoolSystem.School = _world.schools.get_school(s)
				if sc.zone_index == zi:
					own.append(sc)
		var info: Array = []
		for j in count:
			var school: SchoolSystem.School = own[floori(float(j) * own.size() / count)] if not own.is_empty() else null
			var band: int = AGENT_BANDS[n % AGENT_BANDS.size()]
			var ag: BenchAgent = BenchAgent.new(_world, -1, school, lo, hi, seed * 101 + n)
			var pid: int = _world.spawn_entity(species, ag.start_position(), float(content.get_band(1)["length_m"]["min"]), true)
			ag.id = pid
			var e: SimEntity = _world.get_entity(pid)
			e.stamina = boost_max
			# band by XP: SimWorld growth derives band / length / max HP on the first step (xp != grown_at_xp)
			e.xp = float(content.get_band(band).get("xp_to_reach", 0.0))
			_agents.append(ag)
			info.append({"band": band, "school": school.id if school != null else -1})
			n += 1
		placement[zone_id] = info
	return placement


# Eat pacing: one more token when the EATEN events so far are below the target pace (see the class doc).
func _pace_eating(eaten_so_far: int, ticks_so_far: int) -> void:
	var due: float = EAT_RATE_PER_MIN / 60.0 / float(SimWorld.TICK_RATE) * float(ticks_so_far)
	var hunters: int = 0
	var unfed: int = 0
	var tokens: int = 0
	for ag: BenchAgent in _agents:
		hunters += 1 if ag.hunting else 0
		unfed += 1 if ag.hunting and not ag.ate_this_hunt else 0
		tokens += ag.tokens
	var per_token: float = (float(eaten_so_far) + HUNT_PRIOR_EATEN) / float(tokens + 1)
	if float(eaten_so_far) + float(unfed) * per_token >= due or hunters >= MAX_HUNTERS:
		return
	for k in _agents.size():
		var j: int = (_rr + k) % _agents.size()
		var ag: BenchAgent = _agents[j]
		if not ag.hunting and ag.sees_prey():
			ag.grant()
			_rr = j + 1
			return


func _ambient_members() -> int:
	if _world.schools == null:
		return 0
	var total: int = 0
	for s in _world.schools.school_count():
		total += _world.schools.alive_count(_world.schools.get_school(s))
	return total


# Same rule as SimWorld: the first `playable` species in sorted id order.
static func _player_species(content: ContentDB) -> StringName:
	var ids: Array[StringName] = content.species_ids()
	ids.sort()
	for sid in ids:
		if content.get_species(sid).get("playable") == true:
			return sid
	return SimWorld.PLAYER_SPECIES_ID


static func _vec(v: Variant) -> Vector3:
	var a: Array = v
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
