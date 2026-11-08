// Additive light-shaft cones (UnderwaterFx "LightShafts", MultiMesh of a capless CylinderMesh, height 1 along +Y,
// stretched and tilted per instance). Soft silhouette from the view angle, fade along the shaft (bright under the
// surface, gone at the bottom), scrolling noise streaks, fade near the camera (no wall when swimming through) and
// at distance. No fog (additive + fog would brighten the far water); the distance fade replaces it.
// INSTANCE_CUSTOM: x = brightness (0..1), y = noise offset. shaft_fade (0..1) is set per frame by UnderwaterFx from
// the camera depth. Portable: no screen/depth textures.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 shaft_color : source_color = vec3(0.78, 0.97, 1.0);
uniform float intensity : hint_range(0.0, 2.0) = 0.4;
uniform float shaft_fade : hint_range(0.0, 1.0) = 1.0;
uniform float scroll_speed : hint_range(0.0, 1.0) = 0.04;
/// Distance from the camera where shafts start to appear (metres) and the end of the far fade.
uniform float near_fade_m : hint_range(0.0, 30.0) = 4.0;
uniform float far_fade_m : hint_range(10.0, 400.0) = 110.0;

varying float v_along;
varying float v_around;
varying vec2 v_custom;

void vertex() {
	v_along = 0.5 - VERTEX.y; // 0 = top (surface), 1 = bottom
	v_around = atan(VERTEX.z, VERTEX.x) / TAU + 0.5;
	v_custom = INSTANCE_CUSTOM.xy;
}

void fragment() {
	float facing = abs(dot(NORMAL, VIEW));
	float soft = facing * facing;
	float vfade = smoothstep(0.0, 0.08, v_along) * (1.0 - smoothstep(0.25, 1.0, v_along));
	float t = TIME * scroll_speed;
	float n = texture(noise_tex, vec2(v_around * 2.0 + v_custom.y + t, v_along * 0.35 - t * 0.6)).r;
	float dist = length(VERTEX);
	float dfade = smoothstep(near_fade_m, near_fade_m * 3.0, dist) * (1.0 - smoothstep(far_fade_m * 0.5, far_fade_m, dist));
	float a = soft * vfade * dfade * mix(0.25, 1.0, n) * v_custom.x * shaft_fade;
	ALBEDO = shaft_color;
	ALPHA = clamp(a * intensity, 0.0, 1.0);
}
