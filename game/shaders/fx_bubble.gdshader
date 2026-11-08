// Bubble particle (S3 feedback): nearly clear centre, bright fresnel rim, colour and alpha from the particle
// vertex colour (CPUParticles3D color / color_ramp). Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

void fragment() {
	float edge = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * (0.12 + 0.88 * edge * edge);
}
