// Water surface seen from below (UnderwaterFx "Surface", a subdivided plane at y = 0 that follows the camera).
// Faceted: rolling sine waves in the vertex shader, flat facet normals from derivatives. Inside Snell's window
// (view ray close to the facet normal) the bright sky shows; outside it the surface mirrors the water (water_color,
// set per frame by UnderwaterFx from DepthEnvironment). Facets shimmer by their tilt. Opaque and fogged, so it
// melts into the water with distance and is invisible from the abyss. Portable.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec3 window_color : source_color = vec3(0.86, 1.0, 1.0);
/// Brightness of the window (> 1 lets the glow pick it up).
uniform float window_energy : hint_range(0.0, 4.0) = 1.25;
uniform vec3 water_color : source_color = vec3(0.3, 0.68, 0.74);
/// Cosine of the Snell's window half angle (48.6 degrees -> 0.66).
uniform float window_cos : hint_range(0.0, 1.0) = 0.66;
uniform float wave_amp_m : hint_range(0.0, 3.0) = 0.45;
uniform float wave_length_m : hint_range(1.0, 60.0) = 9.0;
uniform float wave_speed : hint_range(0.0, 4.0) = 0.8;
/// Brightness variation between facets.
uniform float shimmer : hint_range(0.0, 2.0) = 0.9;
/// Window light multiplier (UnderwaterFx dims it with the camera depth).
uniform float surface_light : hint_range(0.0, 1.0) = 1.0;
/// Horizontal distance from the camera where the surface melts into water_color (the plane edge stays invisible).
uniform float fade_start_m = 90.0;
uniform float fade_end_m = 160.0;

varying vec3 v_world;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float k = TAU / wave_length_m;
	float t = TIME * wave_speed;
	float h = 0.5 * sin(wp.x * k + t) + 0.35 * sin((wp.x * 0.6 + wp.z * 0.8) * k * 1.3 - t * 1.2) + 0.4 * sin(wp.z * k * 0.7 + t * 0.7);
	VERTEX.y += h * wave_amp_m;
	v_world = wp + vec3(0.0, h * wave_amp_m, 0.0);
}

void fragment() {
	vec3 n = normalize(cross(dFdx(v_world), dFdy(v_world)));
	n *= -sign(n.y + 1e-6); // facet normal pointing down, towards the water
	vec3 dir = normalize(v_world - CAMERA_POSITION_WORLD);
	float c = dot(dir, -n);
	float win = smoothstep(window_cos - 0.1, window_cos + 0.15, c);
	float tilt = clamp(1.0 + n.y, 0.0, 1.0); // 0 = flat facet
	float sparkle = shimmer * (tilt * 6.0 - 0.15) + 0.15 * shimmer * n.x;
	vec3 inside = window_color * window_energy * (1.0 + sparkle);
	vec3 outside = water_color * (1.15 + 0.5 * sparkle);
	float edge = smoothstep(fade_start_m, fade_end_m, length(v_world.xz - CAMERA_POSITION_WORLD.xz));
	ALBEDO = mix(mix(outside, inside, win * surface_light), water_color, edge);
}
