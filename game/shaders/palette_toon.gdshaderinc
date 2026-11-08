// Shared palette toon look: fragment() + light() for every M_Palette mesh.
// Included by palette_toon.gdshader (static) and fish_swim.gdshader (vertex swim).
// Portable: Forward+, Mobile and Compatibility (no screen/depth textures, no compute).
//
// Albedo comes from the shared palette atlas (game/assets/textures/palette.png, 256x256,
// one 4 px row per species, 16 swatches of 16 px; UVs point at swatch centres).
// Facet normals are rebuilt from screen-space derivatives, so the low-poly facets stay
// crisp after blend shapes (juvenile/adult) and vertex swim deformation.
//
// Environment extras (only when the including shader defines PALETTE_ENV, see env_palette.gdshaderinc; fish
// shaders do not, so their output is unchanged): soft vertical gradient (darker at the base, from v_env_height =
// mesh-space height written in vertex()), depth tint towards navy by world depth, world-space caustics
// (water_caustics.gdshaderinc) added as light. The glow swatch keeps its untinted palette colour.

uniform sampler2D palette : source_color, filter_nearest, repeat_disable;

// Optional per-instance brightness tint: a shader that defines PALETTE_TINT before the include writes
// v_tint in vertex() (fish_swim: 1 + small INSTANCE_CUSTOM.y jitter, so crowd members are not clones).
#ifdef PALETTE_TINT
varying float v_tint;
#endif

// Optional glow pulse: a shader that defines PALETTE_GLOW_PULSE before the include writes v_glow in vertex()
// (fish_swim: 1 + glow_pulse_amp x sin(...), exactly 1 with the default amp 0; flat: one value per instance). It
// scales the glow swatch emission and the whole-body glow_body emission (default 0); with the defaults the output
// is unchanged.
#ifdef PALETTE_GLOW_PULSE
varying flat float v_glow;
#endif

#ifdef PALETTE_ENV
#include "res://shaders/water_caustics.gdshaderinc"
// Mesh-space height above the piece origin (metres, origin at the ground contact), written in vertex().
varying float v_env_height;

group_uniforms env;
/// Height over which the base darkening fades out (metres).
uniform float gradient_height_m : hint_range(0.1, 10.0) = 1.5;
/// Brightness at the base of a piece (1 = no gradient).
uniform float gradient_bottom : hint_range(0.0, 1.0) = 0.7;
/// Colour multiplier reached at depth_tint_depth_m (cool navy keeps deep pieces underwater).
uniform vec3 depth_tint : source_color = vec3(0.42, 0.55, 0.9);
uniform float depth_tint_depth_m : hint_range(1.0, 200.0) = 80.0;
/// 0 = no depth tint, 1 = full depth_tint at depth_tint_depth_m.
uniform float depth_tint_amount : hint_range(0.0, 1.0) = 0.6;
group_uniforms;
#endif

group_uniforms toon;
/// N.L where the lit band starts; the 2-step light switches here.
uniform float toon_threshold : hint_range(-1.0, 1.0) = 0.0;
/// Width of the soft edge between the two bands (0 = hard step).
uniform float toon_softness : hint_range(0.0, 0.5) = 0.03;
/// Light multiplier of the shadow band (cool tint keeps it underwater, never black).
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.56, 0.78);
/// 1 = facet normals from derivatives (faceted look), 0 = mesh normals.
uniform float flat_facets : hint_range(0.0, 1.0) = 1.0;

group_uniforms rim;
uniform vec3 rim_color : source_color = vec3(0.72, 0.95, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.45;
/// Fresnel value where the rim starts (higher = thinner rim).
uniform float rim_start : hint_range(0.0, 1.0) = 0.5;

group_uniforms glow;
/// Palette swatch index (0..15) that glows; default 11 = "accent".
uniform float glow_slot : hint_range(0.0, 15.0, 1.0) = 11.0;
/// Emission strength of the glow swatch (0 = off; bioluminescent accents use 1-4).
uniform float glow_strength : hint_range(0.0, 8.0) = 0.0;
#ifdef PALETTE_GLOW_PULSE
/// Emission of every swatch (soft self-glow of the whole mesh; 0 = off).
uniform float glow_body : hint_range(0.0, 4.0) = 0.0;
#endif
group_uniforms;

const float PALETTE_SLOTS = 16.0;

void fragment() {
	vec3 albedo = texture(palette, UV).rgb;
#ifdef PALETTE_TINT
	albedo *= v_tint;
#endif
	vec3 glow_albedo = albedo;
#ifdef PALETTE_ENV
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	albedo *= mix(gradient_bottom, 1.0, clamp(v_env_height / gradient_height_m, 0.0, 1.0));
	float tint_t = clamp(-world_pos.y / depth_tint_depth_m, 0.0, 1.0) * depth_tint_amount;
	albedo = mix(albedo, albedo * depth_tint, tint_t);
#endif
	ALBEDO = albedo;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;

	// Facet normal in view space, turned towards the camera (independent of the
	// derivative sign convention of the backend).
	vec3 facet = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	facet *= step(0.0, dot(facet, VIEW)) * 2.0 - 1.0;
	NORMAL = normalize(mix(NORMAL, facet, flat_facets));

	float fresnel = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = smoothstep(rim_start, rim_start + 0.12, fresnel);
	float glow_mask = 1.0 - step(0.5, abs(floor(UV.x * PALETTE_SLOTS) - glow_slot));
#ifdef PALETTE_GLOW_PULSE
	EMISSION = rim_color * rim * rim_strength + glow_albedo * (glow_mask * glow_strength + glow_body) * v_glow;
#else
	EMISSION = rim_color * rim * rim_strength + glow_albedo * glow_mask * glow_strength;
#endif
#ifdef PALETTE_ENV
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	EMISSION += albedo * caustics_color * water_caustics(world_pos, world_normal, TIME);
#endif
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float lit = smoothstep(toon_threshold - toon_softness, toon_threshold + toon_softness, ndl);
	vec3 band = mix(shadow_tint, vec3(1.0), lit * ATTENUATION);
	DIFFUSE_LIGHT += band * LIGHT_COLOR / PI;
}
