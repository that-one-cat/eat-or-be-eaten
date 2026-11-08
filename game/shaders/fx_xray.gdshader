// X-ray ghost of a fish body during the kill flash (S3): translucent deep blue with a bright cyan fresnel edge,
// so the white skeleton drawn inside (higher render priority) reads through it on bright and dark water alike.
// Applied as material_override on the victim's own model (blend shapes kept, no swim motion during the flash).
// Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform vec3 body_color : source_color = vec3(0.05, 0.16, 0.42);
uniform vec3 edge_color : source_color = vec3(0.45, 0.95, 1.0);

/// Opacity multiplier, 1 = full flash, 0 = gone.
instance uniform float fade = 1.0;

void fragment() {
	float edge = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float e2 = edge * edge;
	ALBEDO = mix(body_color, edge_color, e2);
	ALPHA = (0.55 + 0.45 * e2) * fade;
}
