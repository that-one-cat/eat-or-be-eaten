// World-space caustics, shared by the env palette shaders and the grey-box terrain shader.
// Portable (Forward+, Mobile, Compatibility): one tileable texture, two samples, no screen/depth textures.
//
// caustics_tex = res://shaders/textures/caustics_cells.png (periodic Voronoi F2-F1 cell-edge map, baked by
// res://shaders/gen_caustics.gd): 0 on the cell borders. Two layers at different scales drift against each
// other; their border lines add up into the bright caustic web. Projected from above along world XZ, so the
// pattern lies on the seabed and the tops of rocks/corals; it fades with the surface slope (vertical faces get
// none) and with depth (caustics_fade_start_m .. caustics_fade_end_m, off below the end).

uniform sampler2D caustics_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

group_uniforms caustics;
/// Light added by a caustic line (x surface colour); 0 = off.
uniform float caustics_strength : hint_range(0.0, 3.0) = 0.6;
uniform vec3 caustics_color : source_color = vec3(1.0, 0.97, 0.82);
/// World size of one texture tile in metres (about 7 cells per tile).
uniform float caustics_tile_m : hint_range(1.0, 40.0) = 7.0;
/// Drift speed of the two layers (tiles per second x 20).
uniform float caustics_speed : hint_range(0.0, 4.0) = 0.6;
/// Width of a caustic line in texture units (higher = thicker, softer web).
uniform float caustics_line_width : hint_range(0.02, 0.5) = 0.16;
/// Depth (m below the surface) where the caustics start to fade, and where they are gone.
uniform float caustics_fade_start_m : hint_range(0.0, 80.0) = 10.0;
uniform float caustics_fade_end_m : hint_range(1.0, 80.0) = 40.0;
group_uniforms;

// Caustic light factor (0 .. ~1.4 x caustics_strength) at a world position with a world-space unit normal.
float water_caustics(vec3 world_pos, vec3 world_normal, float time) {
	float depth = -world_pos.y;
	float fade = (1.0 - smoothstep(caustics_fade_start_m, caustics_fade_end_m, depth)) * step(0.0, depth);
	float up = clamp(world_normal.y * 1.5 - 0.2, 0.0, 1.0);
	float t = time * caustics_speed * 0.05;
	// small height skew so stacked ledges do not repeat the same pattern
	vec2 uv = world_pos.xz / caustics_tile_m + world_pos.y * vec2(0.031, 0.017);
	uv += 0.06 * sin(uv.yx * 2.7 + time * caustics_speed * 0.9);
	float a = texture(caustics_tex, uv + vec2(1.0, 0.6) * t).r;
	float b = texture(caustics_tex, uv * 1.37 + vec2(0.31, 0.17) + vec2(-0.8, 1.2) * t).r;
	float la = 1.0 - smoothstep(0.0, caustics_line_width, a);
	float lb = 1.0 - smoothstep(0.0, caustics_line_width, b);
	float web = min(pow((la + lb) * 0.65, 2.0), 1.4);
	return web * fade * up * caustics_strength;
}
