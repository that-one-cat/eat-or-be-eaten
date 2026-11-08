extends RefCounted
## Shared helpers of the S4 benches (bench_sim, bench_crowd): user args, timing stats, machine info, thresholds,
## tripwire verdicts and the one-line BENCH_JSON output. Load with preload("res://bench/bench_util.gd").
##
## Exit codes of a bench scene: 0 = all tripwires pass (or --no-gate), 2 = a tripwire failed, 3 = the run is not
## valid for the gate (the load is not what the tripwire assumes, or no window for GPU numbers). 1 stays "crash".

const THRESHOLDS_PATH: String = "res://bench/thresholds.json"
const EXIT_PASS: int = 0
const EXIT_TRIPWIRE: int = 2
const EXIT_INVALID: int = 3


## `--key=value` -> {"key": "value"}, a bare `--flag` -> {"flag": "true"}.
static func parse_args() -> Dictionary:
	var out: Dictionary = {}
	for a: String in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv: PackedStringArray = a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


static func arg_int(args: Dictionary, key: String, fallback: int) -> int:
	var v: String = String(args.get(key, ""))
	return v.to_int() if v.is_valid_int() else fallback


## {p50, p95, p99, max, mean} in ms of samples given in microseconds (nearest-rank percentiles).
static func stats_ms(samples_usec: PackedFloat64Array) -> Dictionary:
	if samples_usec.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "mean": 0.0, "n": 0}
	var sorted: PackedFloat64Array = samples_usec.duplicate()
	sorted.sort()
	var sum: float = 0.0
	for v in sorted:
		sum += v
	return {
		"p50": ms(percentile(sorted, 0.50)),
		"p95": ms(percentile(sorted, 0.95)),
		"p99": ms(percentile(sorted, 0.99)),
		"max": ms(sorted[sorted.size() - 1]),
		"mean": ms(sum / float(sorted.size())),
		"n": sorted.size(),
	}


## Nearest-rank percentile of an ascending array.
static func percentile(sorted: PackedFloat64Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(ceili(p * sorted.size()) - 1, 0, sorted.size() - 1)]


static func ms(usec: float) -> float:
	return snappedf(usec / 1000.0, 0.001)


## {min, mean, max, end} of integer samples (entity counts).
static func count_stats(samples: PackedInt32Array) -> Dictionary:
	if samples.is_empty():
		return {"min": 0, "mean": 0.0, "max": 0, "end": 0}
	var lo: int = samples[0]
	var hi: int = samples[0]
	var sum: int = 0
	for v in samples:
		lo = mini(lo, v)
		hi = maxi(hi, v)
		sum += v
	return {"min": lo, "mean": snappedf(float(sum) / float(samples.size()), 0.1), "max": hi, "end": samples[samples.size() - 1]}


## Godot version, build kind, CPU brand (sysctl machdep.cpu.brand_string on macOS), OS.
static func machine() -> Dictionary:
	var cpu: String = ""
	var out: Array = []
	if OS.get_name() == "macOS" and OS.execute("sysctl", ["-n", "machdep.cpu.brand_string"], out) == 0 and not out.is_empty():
		cpu = String(out[0]).strip_edges()
	if cpu.is_empty():
		cpu = OS.get_processor_name()
	return {
		"godot": String(Engine.get_version_info().get("string", "")),
		"build": "debug (editor binary)" if OS.is_debug_build() else "release",
		"cpu": cpu,
		"cpu_threads": OS.get_processor_count(),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"renderer": "headless" if DisplayServer.get_name() == "headless" else RenderingServer.get_current_rendering_method(),
		"load_avg_1m": load_avg(),
	}


## 1-minute load average (sysctl vm.loadavg, "{ 1m 5m 15m }"); -1 when unavailable. Other busy processes
## (parallel agents, builds) inflate every number: compare it with cpu_threads before trusting a run.
static func load_avg() -> float:
	var out: Array = []
	# macOS only: a missing sysctl / ps on Windows would log an engine error into every bench run
	if OS.get_name() != "macOS" or OS.execute("sysctl", ["-n", "vm.loadavg"], out) != 0 or out.is_empty():
		return -1.0
	var parts: PackedStringArray = String(out[0]).replace("{", "").replace("}", "").strip_edges().split(" ", false)
	return parts[0].to_float() if not parts.is_empty() and parts[0].is_valid_float() else -1.0


## Validity check "the machine was not busy": 1-minute load average per CPU thread (from the merged machine()
## fields of `result`) against `limit`. An unavailable load average (-1) passes: it must not invalidate a run.
static func load_check(result: Dictionary, limit: float) -> Dictionary:
	var per_thread: float = float(result.get("load_avg_1m", -1.0)) / maxf(float(result.get("cpu_threads", 1)), 1.0)
	return at_most(snappedf(per_thread, 0.01), limit)


## Process resident set size in MB via `ps -o rss= -p <pid>` (KiB); -1 when ps fails.
static func rss_mb() -> float:
	var out: Array = []
	if OS.get_name() == "Windows" or OS.execute("ps", ["-o", "rss=", "-p", str(OS.get_process_id())], out) != 0 or out.is_empty():
		return -1.0
	var kib: String = String(out[0]).strip_edges()
	return snappedf(kib.to_float() / 1024.0, 0.1) if kib.is_valid_float() else -1.0


## Section `section` of res://bench/thresholds.json (empty, with an error, when missing).
static func load_thresholds(section: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(THRESHOLDS_PATH))
	if not (parsed is Dictionary and (parsed as Dictionary).get(section) is Dictionary):
		push_error("bench: %s has no '%s' section" % [THRESHOLDS_PATH, section])
		return {}
	return (parsed as Dictionary)[section]


## One upper-limit check: {value, limit, pass}.
static func at_most(value: float, limit: float) -> Dictionary:
	return {"value": value, "limit": limit, "pass": value <= limit}


## One lower-limit check: {value, min, pass}.
static func at_least(value: float, minimum: float) -> Dictionary:
	return {"value": value, "min": minimum, "pass": value >= minimum}


## Adds tripwires / validity / gate / verdict to `result`, prints the BENCH_JSON line and one readable
## verdict line, returns the exit code (always 0 with gate off).
static func finish(result: Dictionary, tripwires: Dictionary, validity: Dictionary, gate: bool) -> int:
	var trip_ok: bool = true
	for k in tripwires:
		trip_ok = trip_ok and bool((tripwires[k] as Dictionary)["pass"])
	var valid_ok: bool = true
	for k in validity:
		valid_ok = valid_ok and bool((validity[k] as Dictionary)["pass"])
	var verdict: String = "PASS" if trip_ok and valid_ok else ("FAIL" if valid_ok else "INVALID")
	result["thresholds_file"] = THRESHOLDS_PATH
	result["tripwires"] = tripwires
	result["validity"] = validity
	result["gate"] = "on" if gate else "off"
	result["verdict"] = verdict
	print("BENCH_JSON:" + JSON.stringify(result, "", false))
	var parts: PackedStringArray = PackedStringArray()
	for k in tripwires:
		var c: Dictionary = tripwires[k]
		parts.append("%s=%s%s" % [k, str(c["value"]), "" if c["pass"] else " (FAIL > %s)" % str(c["limit"])])
	for k in validity:
		var c: Dictionary = validity[k]
		if not c["pass"]:
			parts.append("%s=%s (INVALID)" % [k, str(c["value"])])
	print("BENCH %s: %s (gate %s) %s" % [String(result.get("bench", "?")), verdict, "on" if gate else "off", " ".join(parts)])
	if not gate or verdict == "PASS":
		return EXIT_PASS
	return EXIT_TRIPWIRE if verdict == "FAIL" else EXIT_INVALID
