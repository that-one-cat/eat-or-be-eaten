// Sonar pulse wave (S6, scripts/world/sonar_fx.gd): an expanding sphere shell around the player. Additive fresnel
// rim plus a thin bright band where the shell cuts the view, so it reads both from outside (a ring) and after it
// passed the camera (a faint wall). `fade` (0..1) is set per frame. Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(0.55, 0.92, 1.0);
uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float facing = abs(dot(NORMAL, VIEW));
	float rim = pow(1.0 - facing, 3.0);
	ALBEDO = tint * (rim * 1.6 + 0.06) * fade;
}
