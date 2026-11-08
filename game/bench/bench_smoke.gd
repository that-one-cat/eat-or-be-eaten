extends Node
## Minimal benchmark: measures N frame times and prints one BENCH_JSON line, then quits.
## Usage: godot --headless --path game res://bench/bench_smoke.tscn -- --frames=<N>

const DEFAULT_FRAMES: int = 300

var _frames: int = DEFAULT_FRAMES
var _samples: PackedFloat64Array = PackedFloat64Array()
var _last_usec: int = 0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			_frames = maxi(1, arg.trim_prefix("--frames=").to_int())
	_last_usec = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_usec()
	_samples.append((now - _last_usec) / 1000.0)
	_last_usec = now
	if _samples.size() >= _frames:
		_finish()


func _finish() -> void:
	set_process(false)
	var sorted: PackedFloat64Array = _samples.duplicate()
	sorted.sort()
	var result: Dictionary = {
		"godot": Engine.get_version_info().string,
		"frames": sorted.size(),
		"p50_ms": snappedf(_percentile(sorted, 0.50), 0.001),
		"p95_ms": snappedf(_percentile(sorted, 0.95), 0.001),
		"max_ms": snappedf(sorted[sorted.size() - 1], 0.001),
	}
	print("BENCH_JSON:" + JSON.stringify(result, "", false))
	get_tree().quit(0)


## Nearest-rank percentile on a sorted array.
func _percentile(sorted: PackedFloat64Array, p: float) -> float:
	var idx: int = clampi(ceili(p * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[idx]
