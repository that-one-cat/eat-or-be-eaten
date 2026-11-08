extends Node
## S3 balance harness v1 (headless): godot --headless --path game res://tests/bots/run_bot.tscn -- --minutes=10 --seed=1 [--out=<path>]
## Builds ContentDB + SimWorld on the shipped map (vitals on, NpcSpawner on), spawns the player and lets the bot
## (bot_player.gd) play through SimCommands only, stepping the sim as fast as possible (no real-time pacing).
## Writes a JSON report (default <repo>/reports/S3/bot_run.json; a relative --out is relative to the repo root):
## time per band, deaths (cause, killer species / temperament), XP by source species, kills, damage taken,
## starvation time, final band / length / XP, run_ticks; wall-clock numbers (sim ms per tick p50 / p95) only
## under "wall_clock", so two runs with the same seed give byte-identical JSON apart from that key.
## Prints one "BOT <criterion>: PASS|FAIL|SKIP ..." line per criterion and "BOT: PASS|FAIL ...", exit 0 / 1.
## Balance experiments (not used by the acceptance run): --npc-scale=<f> and --max-npcs=<n> override
## rules.npc_scale / rules.tiers.interactive_cap for this run only (recorded under "overrides").
## S4: plankton is a density field; PLANKTON_EATEN XP is booked under the source "plankton" ("field" count).
## Food task: PLANKTON_EATEN of a krill field (data.field i > 0) is booked under that field's species id (krill_*,
## "field" count), SITE_EATEN under the food type id ("site" count; soft = swallowed, hard = killed by a bite).
## "xp_by_band" splits the gained XP by the player band at the time of the gain (band -> source -> XP).
## Balance mode adds "bands" (median / p25 / p75 over the seeds of time_to_band_min and time_in_band_min),
## "xp_by_source_total" / "xp_by_band_source_total" (summed over the seeds; per run "xp_b1_by_source") and "predator_deaths_per_seed".
## S6: the S3 bot knows nothing about mutation picks; a band-up offer pauses the single-player world, so the harness
## picks the first offered node at once (an extra paused step() that only applies the pick: ticks and run_ticks
## stay in step with the loop). Bot v2 (S6 impl-C) replaces this with a real policy in --boss mode.
## S6 boss mode (bot v2): godot --headless --path game res://tests/bots/run_bot.tscn -- --boss [--minutes=60] [--seed=7]
## [--out=<path>]: bot_player_v2.gd (mutation policy, Boost / Bite-Dash / Sonar, grows to B4, hunts the giant shark,
## dodges the TELL, bites it to the stun, finisher). The run stops at VICTORY. Extra report keys: mode "boss", picks
## ({tick, time_s, band, offer, pick}), abilities_used, dodges, boss_attempts ({start_s, end_s, outcome died |
## disengaged | defeated | open, player band / length / xp / hp at the start, boss_hp_start / boss_hp_min,
## damage_dealt, damage_taken_bite / _dash, tells, dashes, dash_hits}), victory, time_to_victory_s; deaths_by_cause gains
## boss_bite / boss_dash. Default out reports/S6/bot_run.json. Criteria: json, conservation (run_ticks stops at
## VICTORY), victory (VICTORY within --minutes); exit code 0 = all pass.
## S7 balance mode: godot --headless --path game res://tests/bots/run_bot.tscn -- --balance [--seeds=10] [--minutes=60]
## [--out=<path>]: full --boss runs for seeds 1..N, one after the other in this process (each seed gets its own
## ContentDB, SimWorld and bot, nothing is shared, so separate processes with other --out paths can run in parallel).
## Writes reports/S7/balance.json: per seed run_min (time to VICTORY, or --minutes on a timeout), victory, deaths by
## cause / killer species, picks, time per band, time to band, starving time, boss attempts (outcome, band, hp); plus
## run_min median / p25 / p75 and death totals. Criteria: conservation for every seed, json, balance_target (median
## run in [BALANCE_MIN_MIN, BALANCE_MAX_MIN] minutes); exit code 0 = all pass.
## Criteria: json (written, re-parsed, all numbers finite); conservation (XP gained - lost == final, sources sum
## to gained, band times sum to the run, run_ticks == ticks); acceptance (only for runs of >= ACCEPT_MINUTES):
## reach_b2 (band >= ACCEPT_BAND within ACCEPT_MINUTES), predator_death (>= 1 death with a predator killer).

const DEFAULT_MINUTES: float = 10.0
const DEFAULT_SEED: int = 1
const DEFAULT_OUT: String = "reports/S3/bot_run.json"
const ACCEPT_MINUTES: float = 10.0
const ACCEPT_BAND: int = 2
const ACCEPT_PREDATOR_DEATHS: int = 1
const SPAWN_INDEX: int = 0
const XP_EPS: float = 1e-6
const BOSS_ARG: String = "--boss"
const BOSS_DEFAULT_MINUTES: float = 60.0
const BOSS_DEFAULT_SEED: int = 7
const BOSS_DEFAULT_OUT: String = "reports/S6/bot_run.json"
const BALANCE_ARG: String = "--balance"
const BALANCE_DEFAULT_SEEDS: int = 10
const BALANCE_DEFAULT_OUT: String = "reports/S7/balance.json"
## Balance target (GAME_DESIGN section 1: a run takes 20-30 minutes): median bot run time over the seeds.
const BALANCE_MIN_MIN: float = 20.0
const BALANCE_MAX_MIN: float = 30.0

const BotPlayer := preload("res://tests/bots/bot_player.gd")
const BotPlayerV2 := preload("res://tests/bots/bot_player_v2.gd")

var _all_ok: bool = true


func _ready() -> void:
	_run()
	get_tree().quit(0 if _all_ok else 1)


func _run() -> void:
	var wall0: int = Time.get_ticks_usec()
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	var boss_mode: bool = OS.get_cmdline_user_args().has(BOSS_ARG)
	var balance_mode: bool = OS.get_cmdline_user_args().has(BALANCE_ARG)
	var minutes: float = float(args.get("minutes", BOSS_DEFAULT_MINUTES if boss_mode or balance_mode else DEFAULT_MINUTES))
	var seed: int = int(args.get("seed", BOSS_DEFAULT_SEED if boss_mode else DEFAULT_SEED))
	var repo_root: String = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var default_out: String = BALANCE_DEFAULT_OUT if balance_mode else (BOSS_DEFAULT_OUT if boss_mode else DEFAULT_OUT)
	var out_path: String = String(args.get("out", default_out))
	if not out_path.is_absolute_path():
		out_path = repo_root.path_join(out_path).simplify_path()
	var overrides: Dictionary = {}
	if args.has("npc-scale"):
		overrides["npc_scale"] = float(args["npc-scale"])
	if args.has("max-npcs"):
		overrides["tiers.interactive_cap"] = int(args["max-npcs"])
	if balance_mode:
		_run_balance(int(args.get("seeds", BALANCE_DEFAULT_SEEDS)), minutes, overrides, out_path, wall0)
		return
	var r: Dictionary = _play(seed, minutes, boss_mode, overrides)
	if r.is_empty():
		_summary("setup failed")
		return
	var report: Dictionary = r["report"]
	var e_xp: float = float(report["final_xp"])
	var max_band: int = int(report["max_band"])
	var deaths_n: int = (report["deaths"] as Array).size()
	report["wall_clock"] = {
		"total_s": float(Time.get_ticks_usec() - wall0) / 1e6,
		"sim_ms_per_tick_p50": r["p50_ms"],
		"sim_ms_per_tick_p95": r["p95_ms"],
		"sim_ms_per_tick_max": r["max_ms"],
	}
	_write_json(report, out_path)
	_report_conservation(r)

	if boss_mode:
		var won: bool = bool(report["victory"])
		_report("victory", won, "time_to_victory=%s min (<= %s) attempts=%d picks=%s deaths=%d by_cause=%s abilities=%s dodges=%d" % [
			"never" if not won else "%.2f" % (float(report["time_to_victory_s"]) / 60.0), str(minutes), int(report["boss_attempts_total"]),
			JSON.stringify(report["mutations_final"]), deaths_n, JSON.stringify(report["deaths_by_cause"]), JSON.stringify(report["abilities_used"]), int(report["dodges"])])
		_summary("boss seed=%d minutes=%s ticks=%d max_band=%d final_xp=%.2f final_length=%.3f m deaths=%d sim_ms_p50=%.3f p95=%.3f wall=%.1f s" % [
			seed, str(minutes), int(report["ticks"]), max_band, e_xp, float(report["final_length_m"]), deaths_n,
			r["p50_ms"], r["p95_ms"], float(Time.get_ticks_usec() - wall0) / 1e6])
		return

	# acceptance (full-length runs only)
	var time_to_band: Dictionary = report["time_to_band_s"]
	var deaths_by_predator: int = int(report["deaths_by_predator"])
	var accept: bool = minutes >= ACCEPT_MINUTES
	var t_band: Variant = time_to_band.get("B%d" % ACCEPT_BAND)
	var band_ok: bool = t_band != null and float(t_band) <= ACCEPT_MINUTES * 60.0
	var band_info: String = "max_band=%d time_to_B%d=%s s (<= %.0f)" % [max_band, ACCEPT_BAND, "never" if t_band == null else "%.1f" % float(t_band), ACCEPT_MINUTES * 60.0]
	var pred_ok: bool = deaths_by_predator >= ACCEPT_PREDATOR_DEATHS
	var pred_info: String = "deaths_by_predator=%d (>= %d) deaths=%d by_cause=%s" % [deaths_by_predator, ACCEPT_PREDATOR_DEATHS, deaths_n, JSON.stringify(report["deaths_by_cause"])]
	if accept:
		_report("reach_b%d" % ACCEPT_BAND, band_ok, band_info)
		_report("predator_death", pred_ok, pred_info)
	else:
		print("BOT reach_b%d: SKIP (needs --minutes>=%.0f) %s" % [ACCEPT_BAND, ACCEPT_MINUTES, band_info])
		print("BOT predator_death: SKIP (needs --minutes>=%.0f) %s" % [ACCEPT_MINUTES, pred_info])

	_summary("seed=%d minutes=%s ticks=%d max_band=%d final_xp=%.2f final_length=%.3f m deaths=%d swallows=%d bites=%d starving=%.1f s sim_ms_p50=%.3f p95=%.3f wall=%.1f s" % [
		seed, str(minutes), int(report["ticks"]), max_band, e_xp, float(report["final_length_m"]), deaths_n, int(report["swallows"]), int(report["bites"]),
		float(report["starving_s"]), r["p50_ms"], r["p95_ms"], float(Time.get_ticks_usec() - wall0) / 1e6])


# S7 balance mode (header doc): --boss runs for seeds 1..n, a compact record per seed and the run-time quantiles.
func _run_balance(n: int, minutes: float, overrides: Dictionary, out_path: String, wall0: int) -> void:
	var runs: Array = []
	var run_min := PackedFloat64Array()
	var cause_total: Dictionary = {}
	var killer_total: Dictionary = {}
	var starving_total: float = 0.0
	var src_total: Dictionary = {}
	var band_total: Dictionary = {}  # band -> source -> XP, summed over the seeds
	var pred_per_seed: Array = []
	for seed in range(1, n + 1):
		var t0: int = Time.get_ticks_usec()
		var r: Dictionary = _play(seed, minutes, true, overrides)
		if r.is_empty():
			_summary("setup failed")
			return
		_report_conservation(r, "seed %d " % seed)
		var rep: Dictionary = r["report"]
		var won: bool = bool(rep["victory"])
		var minutes_run: float = _s(float(rep["time_to_victory_s"]) / 60.0) if won else minutes
		run_min.append(minutes_run)
		var killers: Dictionary = {}
		for d in rep["deaths"]:
			var k: String = String(d["killer_species"]) if not String(d["killer_species"]).is_empty() else "starvation"
			killers[k] = int(killers.get(k, 0)) + 1
			killer_total[k] = int(killer_total.get(k, 0)) + 1
		for c in rep["deaths_by_cause"]:
			cause_total[c] = int(cause_total.get(c, 0)) + int(rep["deaths_by_cause"][c])
		starving_total += float(rep["starving_s"])
		var attempts: Array = []
		for a in rep["boss_attempts"]:
			attempts.append({"start_min": _s(float(a["start_s"]) / 60.0), "outcome": a["outcome"], "band": a["band"],
				"hp": a["hp"], "max_hp": a["max_hp"], "boss_hp_min": a["boss_hp_min"], "tells": a["tells"], "dash_hits": a["dash_hits"],
				"damage_taken_bite": a["damage_taken_bite"], "damage_taken_dash": a["damage_taken_dash"]})
		var to_band: Dictionary = {}
		for b in rep["time_to_band_s"]:
			var v: Variant = rep["time_to_band_s"][b]
			to_band[b] = _s(float(v) / 60.0) if v != null else null
		var in_band: Dictionary = {}
		for b in rep["time_in_band_s"]:
			in_band[b] = _s(float(rep["time_in_band_s"][b]) / 60.0)
		var picks: Array = []
		for pk in rep["picks"]:
			picks.append(pk["pick"])
		var src_xp: Dictionary = {}
		for k in rep["xp_sources"]:
			src_xp[k] = _s(float(rep["xp_sources"][k]["xp"]))
			src_total[k] = _s(float(src_total.get(k, 0.0)) + float(rep["xp_sources"][k]["xp"]))
		var b1_xp: Dictionary = {}
		for band in rep["xp_by_band"]:
			var per: Dictionary = rep["xp_by_band"][band]
			var tot: Dictionary = band_total.get(band, {})
			for k in per:
				tot[k] = _s(float(tot.get(k, 0.0)) + float(per[k]))
				if band == "B1":
					b1_xp[k] = _s(float(per[k]))
			band_total[band] = tot
		pred_per_seed.append(int(rep["deaths_by_predator"]))
		runs.append({
			"seed": seed, "victory": won, "run_min": minutes_run, "max_band": rep["max_band"],
			"deaths": (rep["deaths"] as Array).size(), "deaths_by_cause": rep["deaths_by_cause"], "deaths_by_killer": killers,
			"deaths_by_predator": rep["deaths_by_predator"], "picks": picks, "time_to_band_min": to_band, "time_in_band_min": in_band,
			"starving_s": _s(float(rep["starving_s"])), "min_hunger": _s(float(rep["min_hunger"])), "boss_attempts": attempts,
			"boss_attempts_total": attempts.size(), "final_state_hash": rep["final_state_hash"],
			"xp_by_source": src_xp, "xp_b1_by_source": b1_xp,
		})
		print("BOT seed %d: run=%.2f min victory=%s max_band=%d deaths=%d %s starving=%.1f s attempts=%d to_band=%s in_band=%s picks=%s wall=%.1f s" % [
			seed, minutes_run, str(won), int(rep["max_band"]), (rep["deaths"] as Array).size(), JSON.stringify(killers),
			float(rep["starving_s"]), attempts.size(), JSON.stringify(to_band), JSON.stringify(in_band), JSON.stringify(picks), float(Time.get_ticks_usec() - t0) / 1e6])
	var sorted: PackedFloat64Array = run_min.duplicate()
	sorted.sort()
	var median: float = _quantile(sorted, 0.5)
	var bands: Dictionary = {"time_to_band_min": {}, "time_in_band_min": {}}
	for key in bands:
		for b in (runs[0][key] as Dictionary if not runs.is_empty() else {}):
			var v := PackedFloat64Array()
			for run in runs:
				var x: Variant = (run[key] as Dictionary).get(b)
				if x != null:
					v.append(float(x))
			v.sort()
			bands[key][b] = {"median": _s(_quantile(v, 0.5)), "p25": _s(_quantile(v, 0.25)), "p75": _s(_quantile(v, 0.75)), "n": v.size()}
	var report: Dictionary = {
		"mode": "balance",
		"seeds": n,
		"minutes": minutes,
		"overrides": overrides,
		"godot_version": String(Engine.get_version_info().get("string", "")),
		"target_min": [BALANCE_MIN_MIN, BALANCE_MAX_MIN],
		"run_min": {"median": _s(median), "p25": _s(_quantile(sorted, 0.25)), "p75": _s(_quantile(sorted, 0.75)),
			"min": sorted[0] if not sorted.is_empty() else 0.0, "max": sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0},
		"victories": runs.filter(func(x: Dictionary) -> bool: return x["victory"]).size(),
		"deaths_by_cause_total": cause_total,
		"deaths_by_killer_total": killer_total,
		"starving_s_total": _s(starving_total),
		"predator_deaths_per_seed": pred_per_seed,
		"bands": bands,
		"xp_by_source_total": src_total,
		"xp_by_band_source_total": band_total,
		"runs": runs,
		"wall_clock": {"total_s": float(Time.get_ticks_usec() - wall0) / 1e6},
	}
	_write_json(report, out_path)
	print("BOT bands: to_band_min=%s in_band_min=%s predator_deaths_per_seed=%s" % [
		JSON.stringify(bands["time_to_band_min"]), JSON.stringify(bands["time_in_band_min"]), JSON.stringify(pred_per_seed)])
	print("BOT xp_by_band_source_total=%s" % JSON.stringify(band_total))
	_report("balance_target", median >= BALANCE_MIN_MIN and median <= BALANCE_MAX_MIN, "median=%.2f min (p25 %.2f, p75 %.2f; target %.0f-%.0f) victories=%d/%d deaths=%s" % [
		median, _quantile(sorted, 0.25), _quantile(sorted, 0.75), BALANCE_MIN_MIN, BALANCE_MAX_MIN, report["victories"], n, JSON.stringify(killer_total)])
	_summary("balance seeds=%d minutes=%s median=%.2f min wall=%.1f s" % [n, str(minutes), median, float(Time.get_ticks_usec() - wall0) / 1e6])


# One headless run on the shipped map (fresh ContentDB, SimWorld and bot). Returns {} when the content is invalid,
# else {"report": the JSON report without "wall_clock", the conservation inputs, "p50_ms" / "p95_ms" / "max_ms"}.
func _play(seed: int, minutes: float, boss_mode: bool, overrides: Dictionary) -> Dictionary:
	var content: ContentDB = ContentDB.load_from_dir()
	if not content.is_valid():
		_report("setup", false, "content invalid: %s" % "; ".join(content.errors))
		return {}
	for k in overrides:
		if k == "tiers.interactive_cap":
			(content.rules()["tiers"] as Dictionary)["interactive_cap"] = overrides[k]
		else:
			content.rules()[k] = overrides[k]
	var world := SimWorld.new(seed, content)
	world.vitals_enabled = true
	NpcSpawner.set_enabled(world, true)
	var pid: int = world.spawn_player(SPAWN_INDEX)
	var bot = BotPlayerV2.new(world, pid, seed) if boss_mode else BotPlayer.new(world, pid, seed)
	var ticks: int = roundi(minutes * 60.0 * SimWorld.TICK_RATE)
	var band_count: int = content.band_count()

	var species_of: Dictionary = {}  # entity id -> species id (String), from spawn / death events
	var bit_source: Dictionary = {}  # food bit id -> species of the creature it came from
	var xp_sources: Dictionary = {}
	var xp_by_band: Dictionary = {}  # "B<n>" -> source -> XP gained while in that band
	var kills: Dictionary = {}
	var damage_taken: Dictionary = {}
	var deaths: Array = []
	var deaths_by_cause: Dictionary = {"bite": 0, "swallow": 0, "spikes": 0, "starvation": 0}
	if boss_mode:
		deaths_by_cause.merge({"boss_bite": 0, "boss_dash": 0})
	var picks: Array = []
	var attempts: Array = []
	var attempt: Dictionary = {}  # the open boss attempt (empty = none)
	var victory_tick: int = -1
	var ticks_run: int = 0
	var band_ticks := PackedInt64Array()
	band_ticks.resize(band_count + 1)
	var first_band_tick: Dictionary = {1: 0}
	var max_band: int = 1
	var xp_gained: float = 0.0
	var xp_lost: float = 0.0
	var bites: int = 0
	var swallows: int = 0
	var starving_ticks: int = 0
	var hidden_ticks: int = 0
	var min_hunger: float = INF
	var step_us := PackedFloat64Array()
	step_us.resize(ticks)
	var read_from: int = 0
	var e: SimEntity = world.get_entity(pid)

	for i in ticks:
		ticks_run = i + 1
		for c in bot.commands():
			world.submit(c)
		var xp_before: float = e.xp
		var band_before: int = e.band
		var t0: int = Time.get_ticks_usec()
		world.step()
		step_us[i] = float(Time.get_ticks_usec() - t0)
		var evs: Array[SimEvent] = world.events_since(read_from)
		read_from = world.tick
		world.clear_events_before(world.tick)
		bot.observe(evs)
		if world.paused_for_pick:
			var pick: String = e.pending_offer[0]
			if boss_mode:
				pick = bot.choose_pick(e.pending_offer)
				picks.append({"tick": world.tick, "time_s": _s(float(world.tick) / SimWorld.TICK_RATE), "band": e.band,
					"offer": Array(e.pending_offer), "pick": pick})
			world.submit(SimCommand.pick_mutation(pid, StringName(pick)))
			world.step()
		var gained_now: float = 0.0
		var died_ev: SimEvent = null
		var swallowed_by: int = -1
		var spiked_by: int = -1
		var boss_dash_hit: bool = false
		var boss: int = world.boss_id() if boss_mode else -1
		for ev in evs:
			if boss_mode:
				attempt = _track_boss(ev, pid, e, world, attempt, attempts, bot)
				if ev.type == SimEvent.Type.BITTEN and ev.entity_id == pid and bool(ev.data.get("dash", false)):
					boss_dash_hit = true
				elif ev.type == SimEvent.Type.VICTORY:
					victory_tick = ev.tick
			match ev.type:
				SimEvent.Type.ENTITY_SPAWNED:
					var s: SimEntity = world.get_entity(ev.entity_id)
					if s != null:
						species_of[ev.entity_id] = String(s.species_id)
				SimEvent.Type.FOOD_SPAWNED:
					bit_source[ev.entity_id] = species_of.get(ev.other_id, "unknown")
				SimEvent.Type.EATEN:
					if ev.other_id == pid:
						swallows += 1
						gained_now += ev.value
						var bit: bool = bit_source.has(ev.entity_id)
						var src: String = bit_source.get(ev.entity_id, species_of.get(ev.entity_id, "unknown"))
						var rec: Dictionary = xp_sources.get(src, {"count": 0, "whole": 0, "bits": 0, "xp": 0.0})
						rec["count"] += 1
						rec["bits" if bit else "whole"] += 1
						rec["xp"] += ev.value
						xp_sources[src] = rec
						_add_band_xp(xp_by_band, band_before, src, ev.value)
						bit_source.erase(ev.entity_id)
					elif ev.entity_id == pid:
						swallowed_by = ev.other_id
					else:
						bit_source.erase(ev.entity_id)
				SimEvent.Type.PLANKTON_EATEN:
					if ev.entity_id == pid:
						gained_now += ev.value
						var field: int = int(ev.data.get("field", 0))
						var psrc: String = "plankton" if field <= 0 or field > world.krill.size() else String(world.krill[field - 1].species_id)
						var prec: Dictionary = xp_sources.get(psrc, {"count": 0, "whole": 0, "bits": 0, "field": 0, "xp": 0.0})
						prec["count"] += 1
						prec["field"] = int(prec.get("field", 0)) + 1
						prec["xp"] += ev.value
						xp_sources[psrc] = prec
						_add_band_xp(xp_by_band, band_before, psrc, ev.value)
				SimEvent.Type.SITE_EATEN:
					if ev.entity_id == pid:
						gained_now += ev.value
						var fsrc: String = String(ev.data.get("type", "food_site"))
						var frec: Dictionary = xp_sources.get(fsrc, {"count": 0, "whole": 0, "bits": 0, "site": 0, "soft": 0, "hard": 0, "xp": 0.0})
						frec["count"] += 1
						frec["site"] += 1
						frec["soft" if bool(ev.data.get("soft", false)) else "hard"] += 1
						frec["xp"] += ev.value
						xp_sources[fsrc] = frec
						_add_band_xp(xp_by_band, band_before, fsrc, ev.value)
				SimEvent.Type.BITTEN:
					if ev.other_id == pid:
						bites += 1
					elif ev.entity_id == pid:
						var by: String = species_of.get(ev.other_id, "unknown")
						damage_taken[by] = float(damage_taken.get(by, 0.0)) + ev.value
				SimEvent.Type.SPIKED:
					if ev.entity_id == pid:
						spiked_by = ev.other_id
						var by: String = "%s_spikes" % species_of.get(ev.other_id, "unknown")
						damage_taken[by] = float(damage_taken.get(by, 0.0)) + ev.value
				SimEvent.Type.DIED:
					if ev.entity_id == pid:
						died_ev = ev
					else:
						species_of[ev.entity_id] = String(ev.data.get("species", species_of.get(ev.entity_id, "unknown")))
						if ev.other_id == pid:
							var ks: String = species_of[ev.entity_id]
							kills[ks] = int(kills.get(ks, 0)) + 1
		xp_gained += gained_now
		if died_ev != null:
			var had: float = xp_before + gained_now
			var lost: float = had - e.xp
			xp_lost += lost
			var killer: int = died_ev.other_id
			var cause: String = "starvation"
			if killer >= 0:
				cause = "swallow" if swallowed_by == killer else ("spikes" if spiked_by == killer else "bite")
				if boss_mode and killer >= 0 and killer == boss:
					cause = "boss_dash" if boss_dash_hit else "boss_bite"
			var killer_species: String = species_of.get(killer, "unknown") if killer >= 0 else ""
			var killer_temper: String = ""
			if killer >= 0:
				killer_temper = String(content.get_species(StringName(killer_species)).get("temperament", "unknown"))
			deaths_by_cause[cause] += 1
			var pos: Vector3 = died_ev.data.get("pos", e.position)
			deaths.append({
				"tick": died_ev.tick,
				"time_s": _s(float(died_ev.tick) / SimWorld.TICK_RATE),
				"band": SimRules.band_for_xp(had, _bands(content)),
				"length_m": _s(float(died_ev.data.get("length", 0.0))),
				"cause": cause,
				"killer_species": killer_species,
				"killer_temperament": killer_temper,
				"xp_before": had,
				"xp_lost": lost,
				"pos": [_s(pos.x), _s(pos.y), _s(pos.z)],
			})
		band_ticks[e.band] += 1
		if e.band > max_band:
			for b in range(max_band + 1, e.band + 1):
				first_band_tick[b] = world.tick
			max_band = e.band
		if e.alive:
			min_hunger = minf(min_hunger, e.hunger)
			if e.hunger <= 0.0:
				starving_ticks += 1
			if e.hidden:
				hidden_ticks += 1
		if victory_tick >= 0:
			break
	if not attempt.is_empty():
		attempt["outcome"] = "open"
		attempts.append(attempt)
	if boss_mode:
		ticks = ticks_run
		step_us.resize(ticks_run)

	var time_in_band: Dictionary = {}
	var time_to_band: Dictionary = {}
	var band_sum_s: float = 0.0
	for b in range(1, band_count + 1):
		time_in_band["B%d" % b] = float(band_ticks[b]) / SimWorld.TICK_RATE
		band_sum_s += float(band_ticks[b]) / SimWorld.TICK_RATE
		time_to_band["B%d" % b] = float(first_band_tick[b]) / SimWorld.TICK_RATE if first_band_tick.has(b) else null
	var sources_sum: float = 0.0
	for k in xp_sources:
		sources_sum += float(xp_sources[k]["xp"])
	var deaths_by_predator: int = 0
	for d in deaths:
		if d["killer_temperament"] == "predator":
			deaths_by_predator += 1
	var mode_s: Dictionary = {}
	for m in bot.mode_ticks:
		mode_s[m] = float(bot.mode_ticks[m]) / SimWorld.TICK_RATE
	var sorted_us: PackedFloat64Array = step_us.duplicate()
	sorted_us.sort()

	var report: Dictionary = {
		"seed": seed,
		"minutes": minutes,
		"ticks": ticks,
		"overrides": overrides,
		"run_ticks": world.run_ticks,
		"godot_version": String(Engine.get_version_info().get("string", "")),
		"max_band": max_band,
		"final_band": e.band,
		"final_length_m": e.length_m,
		"final_xp": e.xp,
		"final_alive": e.alive,
		"time_to_band_s": time_to_band,
		"time_in_band_s": time_in_band,
		"deaths": deaths,
		"deaths_total": e.deaths,
		"deaths_by_predator": deaths_by_predator,
		"deaths_by_cause": deaths_by_cause,
		"xp_sources": xp_sources,
		"xp_by_band": xp_by_band,
		"xp_gained_total": xp_gained,
		"xp_lost_on_death_total": xp_lost,
		"kills": kills,
		"damage_taken": damage_taken,
		"bites": bites,
		"swallows": swallows,
		"starving_s": float(starving_ticks) / SimWorld.TICK_RATE,
		"min_hunger": min_hunger if is_finite(min_hunger) else 0.0,
		"hidden_s": float(hidden_ticks) / SimWorld.TICK_RATE,
		"bot_mode_s": mode_s,
		"entities_end": world.entity_count(),
		"final_state_hash": str(world.state_hash()),
	}
	if boss_mode:
		report.merge({
			"mode": "boss",
			"victory": victory_tick >= 0,
			"time_to_victory_s": _s(float(victory_tick) / SimWorld.TICK_RATE) if victory_tick >= 0 else null,
			"picks": picks,
			"mutations_final": Array(e.mutations),
			"abilities_used": bot.ability_uses,
			"dodges": bot.dodges,
			"boss_attempts": attempts,
			"boss_attempts_total": attempts.size(),
		})
	var sorted_ms: Array[float] = [_pct(sorted_us, 0.5) / 1000.0, _pct(sorted_us, 0.95) / 1000.0,
		(sorted_us[sorted_us.size() - 1] if not sorted_us.is_empty() else 0.0) / 1000.0]
	return {
		"report": report, "xp_gained": xp_gained, "xp_lost": xp_lost, "final_xp": e.xp, "sources_sum": sources_sum,
		"band_sum_s": band_sum_s, "ticks": ticks, "run_ticks": world.run_ticks, "run_won": world.run_won,
		"p50_ms": sorted_ms[0], "p95_ms": sorted_ms[1], "max_ms": sorted_ms[2],
	}


# Writes `report` as JSON to `out_path` and reports the json criterion (written, re-parsed, all numbers finite).
func _write_json(report: Dictionary, out_path: String) -> void:
	var text: String = JSON.stringify(report, "\t", true, true)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	var written: bool = f != null
	if written:
		f.store_string(text + "\n")
		f.close()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_path)) if written else null
	var finite: bool = _all_finite(report)
	_report("json", written and parsed is Dictionary and finite, "path=%s parsed=%s finite=%s" % [out_path, parsed is Dictionary, finite])


# conservation: XP gained - lost == final, sources sum to gained, band times sum to the run, run_ticks == ticks
# (run_ticks does not count the VICTORY tick: it stops once the run is won).
func _report_conservation(r: Dictionary, prefix: String = "") -> void:
	var xp_ok: bool = absf(r["xp_gained"] - r["xp_lost"] - r["final_xp"]) <= XP_EPS and absf(r["sources_sum"] - r["xp_gained"]) <= XP_EPS
	var expect_run_ticks: int = int(r["ticks"]) - (1 if r["run_won"] else 0)
	var time_ok: bool = absf(r["band_sum_s"] - float(r["ticks"]) / SimWorld.TICK_RATE) <= XP_EPS and int(r["run_ticks"]) == expect_run_ticks
	_report("conservation", xp_ok and time_ok, "%sgained=%.4f lost=%.4f final=%.4f sources=%.4f band_time=%.1f s run_ticks=%d ticks=%d" % [
		prefix, r["xp_gained"], r["xp_lost"], r["final_xp"], r["sources_sum"], r["band_sum_s"], r["run_ticks"], r["ticks"]])


# Boss attempt bookkeeping (boss mode): an attempt opens on BOSS_ENGAGED of the player and closes on the player's
# death, BOSS_DISENGAGED or BOSS_DEFEATED ("open" when the run ends first). Returns the open attempt (empty = none).
static func _track_boss(ev: SimEvent, pid: int, e: SimEntity, world: SimWorld, attempt: Dictionary, attempts: Array, bot: RefCounted) -> Dictionary:
	var boss: SimEntity = world.get_entity(world.boss_id())
	var now_s: float = _s(float(ev.tick) / SimWorld.TICK_RATE)
	match ev.type:
		SimEvent.Type.BOSS_ENGAGED:
			if ev.other_id == pid and attempt.is_empty():
				return {
					"start_s": now_s, "end_s": null, "outcome": "",
					"band": e.band, "length_m": _s(e.length_m), "xp": _s(e.xp), "hp": _s(e.hp), "max_hp": _s(e.max_hp),
					"mutations": Array(e.mutations), "bot_plan": "boss" if int(bot.get("plan")) == 1 else "grow",
					"boss_hp_start": _s(boss.hp) if boss != null else 0.0, "boss_hp_min": _s(boss.hp) if boss != null else 0.0,
					"damage_dealt": 0.0, "damage_taken_bite": 0.0, "damage_taken_dash": 0.0,
					"tells": 0, "dashes": 0, "dash_hits": 0, "player_bites": 0,
				}
		SimEvent.Type.BITTEN:
			if attempt.is_empty():
				return attempt
			if ev.other_id == pid and ev.entity_id == world.boss_id():
				attempt["damage_dealt"] = _s(float(attempt["damage_dealt"]) + ev.value)
				attempt["player_bites"] = int(attempt["player_bites"]) + 1
				if boss != null:
					attempt["boss_hp_min"] = minf(float(attempt["boss_hp_min"]), _s(boss.hp))
			elif ev.entity_id == pid and ev.other_id == world.boss_id():
				var dash: bool = bool(ev.data.get("dash", false))
				var key: String = "damage_taken_dash" if dash else "damage_taken_bite"
				attempt[key] = _s(float(attempt[key]) + ev.value)
				if dash:
					attempt["dash_hits"] = int(attempt["dash_hits"]) + 1
		SimEvent.Type.BOSS_TELL:
			if not attempt.is_empty() and ev.other_id == pid:
				attempt["tells"] = int(attempt["tells"]) + 1
		SimEvent.Type.BOSS_DASH:
			if not attempt.is_empty() and ev.other_id == pid:
				attempt["dashes"] = int(attempt["dashes"]) + 1
		SimEvent.Type.BOSS_STUNNED:
			if not attempt.is_empty():
				attempt["boss_hp_min"] = 0.0
				attempt["stunned_s"] = now_s
		SimEvent.Type.DIED, SimEvent.Type.BOSS_DISENGAGED, SimEvent.Type.BOSS_DEFEATED:
			if attempt.is_empty() or (ev.type == SimEvent.Type.DIED and ev.entity_id != pid):
				return attempt
			attempt["end_s"] = now_s
			attempt["outcome"] = {SimEvent.Type.DIED: "died", SimEvent.Type.BOSS_DISENGAGED: "disengaged",
				SimEvent.Type.BOSS_DEFEATED: "defeated"}[ev.type]
			attempts.append(attempt)
			return {}
	return attempt


static func _add_band_xp(xp_by_band: Dictionary, band: int, src: String, xp: float) -> void:
	var key: String = "B%d" % band
	var per: Dictionary = xp_by_band.get(key, {})
	per[src] = float(per.get(src, 0.0)) + xp
	xp_by_band[key] = per


static func _parse_args(args: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for a in args:
		if a.begins_with("--") and a.contains("="):
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1]
	return out


static func _bands(content: ContentDB) -> Array:
	var out: Array = []
	for i in range(1, content.band_count() + 1):
		out.append(content.get_band(i))
	return out


static func _pct(sorted: PackedFloat64Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(floor(q * float(sorted.size() - 1))), 0, sorted.size() - 1)]


# Linear-interpolated quantile of an ascending array (0 when empty).
static func _quantile(sorted: PackedFloat64Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	var x: float = q * float(sorted.size() - 1)
	var i: int = floori(x)
	var j: int = mini(i + 1, sorted.size() - 1)
	return lerpf(sorted[i], sorted[j], x - float(i))


static func _s(v: float) -> float:
	return snappedf(v, 0.001)


static func _all_finite(v: Variant) -> bool:
	if v is float:
		return is_finite(v)
	if v is Dictionary:
		for k in v:
			if not _all_finite(v[k]):
				return false
	elif v is Array:
		for x in v:
			if not _all_finite(x):
				return false
	return true


func _report(criterion: String, ok: bool, info: String) -> void:
	_all_ok = _all_ok and ok
	print("BOT %s: %s %s" % [criterion, "PASS" if ok else "FAIL", info])


func _summary(info: String) -> void:
	print("BOT: %s %s" % ["PASS" if _all_ok else "FAIL", info])
