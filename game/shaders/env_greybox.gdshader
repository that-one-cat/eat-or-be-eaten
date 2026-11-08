// Grey-box terrain (GreyboxTerrain "Seabed" / "Obstacles", m_greybox_terrain): the baked per-face light in the
// vertex colours (sRGB, unshaded, identical on every renderer) plus the world-space caustics of the env shaders.
// The Compatibility renderer hands COLOR to the shader already linearised (measured on 4.7.2: matches
// StandardMaterial3D vertex_color_is_srgb there), the RD renderers do not, hence the CURRENT_RENDERER switch.
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/water_caustics.gdshaderinc"

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

void fragment() {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 base = COLOR.rgb;
#else
	vec3 base = srgb_to_linear(COLOR.rgb);
#endif
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ALBEDO = base + base * caustics_color * water_caustics(world_pos, world_normal, TIME);
}
