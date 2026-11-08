class_name QualitySettings
extends RefCounted
## Quality tiers (S4 hook, full tiers in S5). Presentation only: the sim never reads the tier.
##
## Tier selection, first match wins:
## 1. user arg `-- --quality=low|high` (benches, captures);
## 2. user://settings.cfg `[graphics] quality_tier` ("high" | "low"; "auto" = step 3), written by GameSettings
##    (S6 settings menu) or save_tier();
## 3. detect_default_tier(): `low` when the renderer is gl_compatibility or the GPU adapter name matches
##    INTEGRATED_GPU_PATTERNS (weak iGPUs, software rasterisers), else `high`.
## Unknown values fall back to the detected default with a warning. The tier is read once per scene start
## (reef_greybox.gd passes it down); a change from the settings menu applies on the next scene load.
##
## What a tier does (profile() is the single table; consumers: AmbientRenderer, DepthEnvironment, UnderwaterFx,
## map dressing):
## - `low`: Compatibility-safe set. Ambient density x rules quality.low.ambient_density_mult, shorter visibility
##   ranges and smaller plankton swarms (AmbientRenderer), no volumetric fog, no refraction quad, fewer light shafts
##   and marine-snow flakes, coarser surface mesh, fewer glow levels, denser fog (shorter draw distance).
## - `high`: everything on; Forward+-only extras (volumetric fog) only when the renderer is forward_plus.

const SETTINGS_PATH: String = "user://settings.cfg"
const SECTION: String = "graphics"
const KEY: String = "quality_tier"
const ARG_PREFIX: String = "--quality="
const HIGH: StringName = &"high"
const LOW: StringName = &"low"
## Stored by GameSettings while the user has not picked a tier (detection decides at every start).
const AUTO: StringName = &"auto"
const TIERS: Array[StringName] = [LOW, HIGH]
## Lower-case substrings of RenderingServer.get_video_adapter_name() that select `low` by default.
const INTEGRATED_GPU_PATTERNS: PackedStringArray = [
	"hd graphics", "iris", "radeon(tm) graphics", "radeon graphics", "radeon(tm) vega", "mali", "adreno",
	"powervr", "llvmpipe", "swiftshader", "software rasterizer", "microsoft basic render",
]

## Per-tier presentation settings (see profile()).
const _PROFILES: Dictionary = {
	&"high": {
		"volumetric_fog": true,
		"refraction": true,
		"light_shafts": 14,
		"marine_snow": 900,
		"surface_cells": 72,
		"glow_levels": [2, 3, 4, 5],
		"fog_density_mult": 1.0,
		"draw_distance_m": 140.0,
		"dressing_density_mult": 1.0,
	},
	&"low": {
		"volumetric_fog": false,
		"refraction": false,
		"light_shafts": 6,
		"marine_snow": 350,
		"surface_cells": 36,
		"glow_levels": [3, 5],
		"fog_density_mult": 1.15,
		"draw_distance_m": 90.0,
		"dressing_density_mult": 0.55,
	},
}


## The active tier (HIGH or LOW).
static func tier() -> StringName:
	var raw: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PREFIX):
			raw = arg.trim_prefix(ARG_PREFIX)
	if raw.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(SETTINGS_PATH) == OK:
			raw = str(cfg.get_value(SECTION, KEY, ""))
	if raw.is_empty() or raw == String(AUTO):
		return detect_default_tier()
	if raw == String(HIGH) or raw == String(LOW):
		return StringName(raw)
	var fallback: StringName = detect_default_tier()
	push_warning("quality_settings: unknown quality tier '%s', using %s" % [raw, fallback])
	return fallback


## Default tier from a simple GPU check: `low` on the Compatibility renderer or an integrated/software GPU.
static func detect_default_tier() -> StringName:
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return LOW
	return LOW if is_integrated_gpu(RenderingServer.get_video_adapter_name()) else HIGH


## True when `adapter_name` matches INTEGRATED_GPU_PATTERNS (case-insensitive). Apple M-series count as discrete.
static func is_integrated_gpu(adapter_name: String) -> bool:
	var name: String = adapter_name.to_lower()
	for pattern: String in INTEGRATED_GPU_PATTERNS:
		if name.contains(pattern):
			return true
	return false


## True when the active renderer is Forward+ (gate for Forward+-only extras such as volumetric fog).
static func is_forward_plus() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"


## Persists the tier to user://settings.cfg [graphics] quality_tier, keeping every other section/key (S6 settings
## menu). Takes effect on the next scene load. Returns the ConfigFile save error.
static func save_tier(p_tier: StringName) -> Error:
	if not TIERS.has(p_tier):
		push_warning("quality_settings: refusing to save unknown tier '%s'" % p_tier)
		return ERR_INVALID_PARAMETER
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # missing file is fine: start empty
	cfg.set_value(SECTION, KEY, String(p_tier))
	return cfg.save(SETTINGS_PATH)


## Presentation settings of `p_tier` (a copy; unknown tiers get HIGH's): volumetric_fog (bool, applied only on
## Forward+), refraction (bool), light_shafts (int, cones around the camera), marine_snow (int, flakes),
## surface_cells (int, surface plane subdivisions per side), glow_levels (Array of Environment glow levels 1..7),
## fog_density_mult (float, x DepthEnvironment fog density: shorter draw distance), draw_distance_m (float,
## visibility_range_end of map dressing chunks), dressing_density_mult (float, share of small scatter props MapDressing
## draws; kelp and larger pieces always stay).
static func profile(p_tier: StringName) -> Dictionary:
	return (_PROFILES.get(p_tier, _PROFILES[HIGH]) as Dictionary).duplicate(true)


## Fraction of ambient school members drawn at `tier` (rules quality.<tier>.ambient_density_mult, clamped to
## [0, 1]; 1 when the key is missing).
static func ambient_density_mult(content: ContentDB, p_tier: StringName) -> float:
	var rules: Dictionary = content.rules() if content != null else {}
	var quality: Dictionary = rules.get("quality", {}) if rules.get("quality") is Dictionary else {}
	var block: Dictionary = quality.get(String(p_tier), {}) if quality.get(String(p_tier)) is Dictionary else {}
	var mult: float = float(block.get("ambient_density_mult", 1.0))
	return clampf(mult, 0.0, 1.0) if is_finite(mult) else 1.0
