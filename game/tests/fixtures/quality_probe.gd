extends SceneTree
## Helper process for test_s5_quality_settings.gd (not a test: the runner skips res://tests/fixtures/).
## Usage: godot --headless --path game --script res://tests/fixtures/quality_probe.gd [-- --quality=low|high]
## Prints "S5_TIER=<QualitySettings.tier()>" and "S5_DEFAULT=<QualitySettings.detect_default_tier()>", exits 0.


func _initialize() -> void:
	print("S5_TIER=%s" % String(QualitySettings.tier()))
	print("S5_DEFAULT=%s" % String(QualitySettings.detect_default_tier()))
	quit(0)
