// Sonar contact marker (S6, scripts/world/sonar_fx.gd): camera-facing ring drawn around a creature for the sonar
// duration, on a MultiMeshInstance3D of unit quads (one instance per contact). Seen through everything
// (depth_test_disabled): the sonar "outlines" what it found. Per instance: COLOR = tint (rgb) + fade (a);
// INSTANCE_CUSTOM.x = shape (0 smaller: thin ring, 1 similar: ring + inner dot, 2 bigger: thick ring with 4 outward
// ticks), so the size class reads without colour (colour-blind safe). The instance basis scale = marker diameter.
// Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

varying float v_shape;

void vertex() {
	float s = length(MODEL_MATRIX[0].xyz);
	// billboard: keep the instance origin and scale, face the camera
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_shape = INSTANCE_CUSTOM.x;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float aa = fwidth(r) * 1.5;
	float shape = floor(v_shape + 0.5);
	float width = shape > 1.5 ? 0.16 : (shape > 0.5 ? 0.1 : 0.08);
	float ring_r = 0.72;
	float ring = 1.0 - smoothstep(width - aa, width + aa, abs(r - ring_r));
	float extra = 0.0;
	if (shape > 0.5 && shape < 1.5) {
		extra = 1.0 - smoothstep(0.12 - aa, 0.12 + aa, r);
	} else if (shape > 1.5) {
		// four ticks pointing outward on the diagonals
		vec2 q = abs(p);
		float diag = abs(q.x - q.y) * 0.7071;
		float along = (q.x + q.y) * 0.7071;
		extra = (1.0 - smoothstep(0.06 - aa, 0.06 + aa, diag)) * step(0.82, along) * step(along, 0.99);
	}
	// dark edge around the ring: keeps pale tints readable on bright shallow water
	float halo = 1.0 - smoothstep(width + 0.07 - aa, width + 0.07 + aa, abs(r - ring_r));
	float core = max(ring, extra);
	ALBEDO = mix(vec3(0.02, 0.06, 0.12), COLOR.rgb, core);
	ALPHA = COLOR.a * max(core, halo * 0.5);
}
