// Marine snow (UnderwaterFx "MarineSnow"): a fixed set of tiny additive billboards wrapped in a box around the
// camera (every flake lives at mod(seed position + drift, box) relative to the camera), so the field follows the
// camera forever with no CPU cost, no particle simulation and no popping. Portable (no particles, no compute).
// Mesh: one quad per flake, all 4 corners carry the flake's seed position in [0,1)^3 as VERTEX, UV = corner,
// UV2 = (size jitter 0..1, phase 0..1). Needs a huge custom AABB (the mesh is never culled).
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled, skip_vertex_transform;

uniform vec3 box_m = vec3(26.0, 18.0, 26.0);
uniform float size_m : hint_range(0.005, 0.5) = 0.045;
/// Drift in metres per second (slow sinking).
uniform vec3 drift = vec3(0.04, -0.07, 0.025);
uniform vec3 snow_color : source_color = vec3(0.75, 0.95, 1.0);
uniform float intensity : hint_range(0.0, 2.0) = 0.55;

varying vec2 v_corner;
varying float v_fade;

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	float ph = UV2.y * TAU;
	vec3 sway = 0.25 * vec3(sin(TIME * 0.35 + ph), 0.5 * sin(TIME * 0.5 + ph * 1.7), cos(TIME * 0.3 + ph));
	vec3 p = VERTEX * box_m + drift * TIME + sway;
	vec3 rel = mod(p - cam, box_m) - box_m * 0.5;
	vec3 view = (VIEW_MATRIX * vec4(cam + rel, 1.0)).xyz;
	view.xy += (UV - 0.5) * size_m * (0.5 + UV2.x);
	VERTEX = view;
	v_corner = UV - 0.5;
	vec3 edge = abs(rel) / (box_m * 0.5);
	v_fade = smoothstep(0.3, 1.2, -view.z) * (1.0 - smoothstep(0.6, 1.0, max(edge.x, max(edge.y, edge.z))));
}

void fragment() {
	float r = length(v_corner) * 2.0;
	ALBEDO = snow_color;
	ALPHA = clamp((1.0 - smoothstep(0.2, 1.0, r)) * v_fade * intensity, 0.0, 1.0);
}
