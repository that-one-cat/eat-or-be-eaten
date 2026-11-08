// Full-screen refraction wobble (UnderwaterFx "Refraction", high tier): re-draws the screen texture with a slow
// sine distortion plus a soft vignette. Portable (screen texture works on Forward+, Mobile and Compatibility).
// The quad (QuadMesh 2 x 2) is placed in clip space by the vertex shader; z = 0.5 lies inside the clip range of
// both reverse-Z (Forward+/Mobile) and OpenGL depth, and depth testing is off anyway. The material must draw first
// in the transparent pass (render_priority -128, set by UnderwaterFx), because the screen texture holds only the
// opaque pass: transparent FX drawn after it stay undistorted instead of being overwritten.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
/// Distortion amplitude in screen fractions.
uniform float wobble_amp : hint_range(0.0, 0.02) = 0.0018;
/// Spatial frequency of the wobble (radians per screen).
uniform float wobble_freq : hint_range(1.0, 80.0) = 22.0;
uniform float wobble_speed : hint_range(0.0, 6.0) = 1.3;
/// Vignette strength at the screen corners (0 = off).
uniform float vignette : hint_range(0.0, 1.0) = 0.35;
uniform vec3 vignette_color : source_color = vec3(0.0, 0.04, 0.08);

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float t = TIME * wobble_speed;
	vec2 off = vec2(
		sin(uv.y * wobble_freq + t) + 0.5 * sin(uv.y * wobble_freq * 2.3 - t * 1.4 + uv.x * 6.0),
		cos(uv.x * wobble_freq * 0.8 + t * 0.9) + 0.5 * cos(uv.x * wobble_freq * 1.9 + t * 1.2 + uv.y * 5.0));
	// no wobble at the screen border (no smeared edge pixels)
	vec2 border = smoothstep(vec2(0.0), vec2(0.04), uv) * smoothstep(vec2(1.0), vec2(0.96), uv);
	off *= wobble_amp * border.x * border.y;
	vec3 col = texture(screen_tex, uv + off).rgb;
	float v = smoothstep(0.45, 1.0, length((uv - 0.5) * vec2(1.6, 1.25))) * vignette;
	ALBEDO = mix(col, vignette_color, v);
}
