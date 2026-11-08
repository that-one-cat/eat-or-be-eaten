// Target health bar (scripts/ui/target_health_bars.gd): a slim camera-facing bar above a creature the player bit.
// Unit QuadMesh; the node scale is the bar size (x = width, y = height, metres). Dark backing with a thin border,
// fill from the left by `frac`, colour green -> amber -> red as it drops (HUD palette colours set on the
// shared material). Per bar: `frac` and `fade` (instance uniforms, one shared material). Seen through everything
// like the sonar rings and the CHOMP pop-ups (depth_test_disabled, fog_disabled), so it reads like HUD.
// Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform vec4 backing_color : source_color = vec4(0.02, 0.06, 0.11, 0.78);
uniform vec3 high_color : source_color = vec3(0.42, 0.92, 0.6);
uniform vec3 mid_color : source_color = vec3(1.0, 0.74, 0.3);
uniform vec3 low_color : source_color = vec3(1.0, 0.45, 0.52);
/// Border thickness, fraction of the bar height (the same on every side).
uniform float border = 0.2;

/// HP fraction 0..1.
instance uniform float frac = 1.0;
/// Opacity 0..1.
instance uniform float fade = 1.0;

varying vec2 v_border;

void vertex() {
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	// billboard: keep the node origin and its x / y scale, face the camera
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_border = vec2(border * sy / max(sx, 1e-6), border);
}

void fragment() {
	vec2 lo = v_border;
	vec2 hi = vec2(1.0) - v_border;
	float f = clamp(frac, 0.0, 1.0);
	float fill_x = mix(lo.x, hi.x, f);
	vec2 aa = fwidth(UV);
	vec2 inner = smoothstep(lo - aa, lo + aa, UV) * (vec2(1.0) - smoothstep(hi - aa, hi + aa, UV));
	float fill = inner.x * inner.y * (1.0 - smoothstep(fill_x - aa.x, fill_x + aa.x, UV.x));
	// short blends between flat bands (a long blend gives muddy olive mid-tones): red < 0.2, amber 0.3-0.5, green > 0.6
	vec3 tint = mix(mix(low_color, mid_color, smoothstep(0.2, 0.3, f)), high_color, smoothstep(0.5, 0.6, f));
	// lighter at the top (UV.y = 0), a little volume like the HUD bars
	tint *= mix(1.1, 0.85, UV.y);
	ALBEDO = mix(backing_color.rgb, tint, fill);
	ALPHA = fade * mix(backing_color.a, 1.0, fill);
}
