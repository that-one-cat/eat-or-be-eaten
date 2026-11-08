// Cartoon fish skeleton (S3 kill feedback): bright X-ray white-cyan during the flash, then bone-coloured remains
// that fade out. Unshaded with a cheap view-facing shade so the bones read as round; the vertex colour darkens
// parts (eye sockets). Per-instance `xray` and `fade` (instance uniforms, one shared material).
// Portable: Forward+, Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

uniform vec3 bone_color : source_color = vec3(0.95, 0.93, 0.84);
uniform vec3 xray_color : source_color = vec3(0.86, 1.0, 1.0);

/// 1 = X-ray flash look, 0 = bone remains.
instance uniform float xray = 0.0;
/// Opacity, 1 = solid, 0 = gone.
instance uniform float fade = 1.0;

void fragment() {
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	vec3 bone = bone_color * (0.62 + 0.38 * facing);
	ALBEDO = mix(bone, xray_color, xray) * COLOR.rgb;
	ALPHA = fade;
}
