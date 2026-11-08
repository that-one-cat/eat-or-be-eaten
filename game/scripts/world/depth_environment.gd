class_name DepthEnvironment
extends WorldEnvironment
## Underwater environment driven by the camera depth (S5 look stack): background, depth fog, ambient light, sun
## energy, fog sun-scatter, glow and (high tier on Forward+ only) volumetric fog go from bright turquoise shallows
## (0 m) over teal-green (mid_depth_m) to the navy abyss (full_depth_m). Plain exponential depth fog is the portable
## base (Forward+ and Compatibility); glow carries the emissive accents (palette slot 11) on every renderer.
## apply_quality(tier) switches the tier extras (QualitySettings.profile()). Presentation only.

@export var full_depth_m: float = 80.0
@export var mid_depth_m: float = 28.0
@export var shallow_color: Color = Color(0.30, 0.72, 0.76)
@export var mid_color: Color = Color(0.1, 0.42, 0.44)
@export var deep_color: Color = Color(0.06, 0.15, 0.24)
@export var shallow_ambient: Color = Color(0.72, 0.84, 0.84)
@export var mid_ambient: Color = Color(0.36, 0.58, 0.58)
@export var deep_ambient: Color = Color(0.28, 0.4, 0.62)
@export var shallow_fog_density: float = 0.018
@export var deep_fog_density: float = 0.027
## Fog brightening towards the sun (looking up in the shallows).
@export var shallow_sun_scatter: float = 0.15
@export var deep_sun_scatter: float = 0.0
## Glow intensity (deep water shows more bloom around bioluminescence).
@export var shallow_glow: float = 0.25
@export var deep_glow: float = 1.6
## Volumetric fog density (high tier, Forward+ only).
@export var shallow_volumetric_density: float = 0.003
@export var deep_volumetric_density: float = 0.0025
## Optional sun light dimmed with depth.
@export var sun: DirectionalLight3D
@export var shallow_sun_energy: float = 1.1
@export var deep_sun_energy: float = 0.5

## Water colour at the current camera depth (sRGB, = background and fog colour); read by UnderwaterFx.
var water_color: Color = Color(0.30, 0.72, 0.76)
## Camera depth over full_depth_m, 0 (surface) .. 1 (abyss floor).
var depth_t: float = 0.0
## True when apply_quality() turned volumetric fog on (high tier and Forward+).
var volumetric_fog: bool = false

var _camera: Camera3D
var _fog_mult: float = 1.0


func setup(camera: Camera3D) -> void:
	_camera = camera
	_process(0.0)


## Applies the tier's environment settings (QualitySettings.profile(): glow levels, fog density multiplier,
## volumetric fog on Forward+). Safe to call again.
func apply_quality(p_tier: StringName) -> void:
	if environment == null:
		return
	var prof: Dictionary = QualitySettings.profile(p_tier)
	_fog_mult = float(prof["fog_density_mult"])
	environment.glow_enabled = true
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	environment.glow_hdr_threshold = 1.0
	environment.glow_bloom = 0.0
	var levels: Array = prof["glow_levels"]
	for i in range(1, 8):
		environment.set("glow_levels/%d" % i, 1.0 if levels.has(i) else 0.0)
	volumetric_fog = bool(prof["volumetric_fog"]) and QualitySettings.is_forward_plus()
	environment.volumetric_fog_enabled = volumetric_fog
	if volumetric_fog:
		environment.volumetric_fog_length = 70.0
		environment.volumetric_fog_anisotropy = 0.6
		environment.volumetric_fog_ambient_inject = 0.5
		# the background gets the same fog, so far geometry never shows a band against it
		environment.volumetric_fog_sky_affect = 1.0
	_process(0.0)


func _ready() -> void:
	# after the camera has moved this frame
	process_priority = 20


func _process(_delta: float) -> void:
	if _camera == null or environment == null:
		return
	var depth: float = -_camera.global_position.y
	depth_t = clampf(depth / full_depth_m, 0.0, 1.0)
	water_color = _ramp(depth, shallow_color, mid_color, deep_color)
	environment.background_color = water_color
	environment.fog_light_color = water_color
	environment.fog_density = lerpf(shallow_fog_density, deep_fog_density, depth_t) * _fog_mult
	environment.fog_sun_scatter = lerpf(shallow_sun_scatter, deep_sun_scatter, depth_t)
	environment.ambient_light_color = _ramp(depth, shallow_ambient, mid_ambient, deep_ambient)
	environment.glow_intensity = lerpf(shallow_glow, deep_glow, depth_t)
	if volumetric_fog:
		environment.volumetric_fog_density = lerpf(shallow_volumetric_density, deep_volumetric_density, depth_t)
		environment.volumetric_fog_albedo = water_color.lightened(0.5)
	if sun != null:
		sun.light_energy = lerpf(shallow_sun_energy, deep_sun_energy, depth_t)


# Two-segment colour ramp: a at 0 m, b at mid_depth_m, c at full_depth_m (clamped).
func _ramp(depth: float, a: Color, b: Color, c: Color) -> Color:
	if depth <= mid_depth_m:
		return a.lerp(b, clampf(depth / mid_depth_m, 0.0, 1.0))
	return b.lerp(c, clampf((depth - mid_depth_m) / maxf(full_depth_m - mid_depth_m, 0.001), 0.0, 1.0))
