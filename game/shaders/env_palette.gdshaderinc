// Environment palette body (S5 contract "Env material"): the shared palette toon look (2-step + rim, flat facets,
// no outlines, glow swatch = slot 11 x glow_strength) plus the PALETTE_ENV extras (base gradient, depth tint,
// world-space caustics) and vertex sway. Included by env_palette.gdshader (cull_back) and
// env_palette_double.gdshader (cull_disabled, for single-sided strips such as kelp blades and seagrass).
//
// Sway: weight = UV2.x (0 at the root -> 1 at the tip; meshes without UV2 read 0 and stay still). The offset grows
// with weight^2 and its phase is a function of the world position only (a wave travelling across the field and up
// the strand), so split vertices of one facet corner move together and the mesh never cracks. Works on
// MeshInstance3D and MultiMeshInstance3D (MODEL_MATRIX includes the instance transform). Amplitude in mesh units
// (metres; scaled instances sway proportionally).

#define PALETTE_ENV
#include "res://shaders/palette_toon.gdshaderinc"

group_uniforms sway;
/// Tip displacement at weight 1 (metres, mesh space). 0 = no sway.
uniform float sway_amp_m : hint_range(0.0, 2.0) = 0.35;
/// Angular speed of the sway (radians per second).
uniform float sway_speed : hint_range(0.0, 6.0) = 1.1;
/// Wavelength of the sway wave travelling through the field (metres).
uniform float sway_wavelength_m : hint_range(1.0, 100.0) = 14.0;
group_uniforms;

void vertex() {
	v_env_height = VERTEX.y;
	float w = UV2.x * UV2.x;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float k = TAU / sway_wavelength_m;
	float ph = TIME * sway_speed - (wp.x * 0.8 + wp.z * 0.6) * k - wp.y * k * 0.5;
	VERTEX.x += sway_amp_m * w * sin(ph);
	VERTEX.z += sway_amp_m * w * 0.6 * sin(ph * 0.73 + 1.9);
}
