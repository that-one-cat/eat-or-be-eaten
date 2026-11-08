# shaders

Every shader here works on Forward+, Mobile and Compatibility; Forward+-only extras (volumetric fog) are switched by the quality tier in `scripts/world/depth_environment.gd`, never by a shader.

## Fish (S1-S4)
`fish_swim.gdshader` (vertex swim + optional school wobble from `school_wobble_m/_w` + `school_time`, `INSTANCE_CUSTOM` = phase, tint, wobble phases a/TAU, b/TAU) includes `palette_toon.gdshaderinc` with `PALETTE_TINT` (per-instance brightness jitter). Crowd materials are runtime duplicates of the `m_*_swim.tres` presets (`scripts/world/crowd_assets.gd`); the `.tres` files are never mutated. `palette_toon.gdshader` / `m_palette.tres` = static `M_Palette`.

## Environment pieces (S5)
- `env_palette.gdshaderinc` = `palette_toon.gdshaderinc` with `PALETTE_ENV` (soft base gradient, depth tint, world-space caustics; fish shaders do not define it, their output is unchanged) + vertex sway from **UV2.x** (0 root -> 1 tip, phase from the world position). Shaders: `env_palette.gdshader` (cull back), `env_palette_double.gdshader` (cull disabled, single-sided strips).
- Materials (assign as surface material or `material_override`; never mutate at runtime, duplicate first):
  - `m_env.tres` - every opaque piece (rocks, corals, sand, cliff, boat); `glow_strength` 0.
  - `m_env_glow.tres` - pieces with `glow: true`; palette slot 11 emits at `glow_strength` 2.5 (Environment glow picks it up).
  - `m_env_double.tres` - single-sided strips (kelp blades, seagrass, torn net).
  - `m_env_kelp.tres` - `m_env_double` with a kelp sway (`sway_amp_m` 1.8 at the tip, `sway_speed` 0.55, `sway_wavelength_m` 30); MapDressing sets it as `material_override` on kelp scatter and set pieces (S5 map).
- Uniforms worth tuning per material: `sway_amp_m` (0.35, tip metres), `sway_speed` (1.1 rad/s), `sway_wavelength_m` (14), `gradient_height_m` (1.5) / `gradient_bottom` (0.7), `depth_tint` / `depth_tint_depth_m` (80) / `depth_tint_amount` (0.6), `glow_strength`, `caustics_*` (below), plus the toon/rim uniforms of `palette_toon.gdshaderinc`.

## Water stack (S5)
- `water_caustics.gdshaderinc` - world-space caustics (`caustics_tex` = `textures/caustics_cells.png`, a periodic Voronoi edge map baked by `gen_caustics.gd`; two drifting layers; fade with slope and depth `caustics_fade_start_m` 10 -> `caustics_fade_end_m` 40, off below). Used by the env shaders and `env_greybox.gdshader` (grey-box terrain: baked vertex colours + caustics, `m_greybox_terrain.tres`).
- `water_surface.gdshader` (faceted surface from below, Snell's window), `water_light_shaft.gdshader` (additive cones, `INSTANCE_CUSTOM` x = brightness, y = noise offset), `water_snow.gdshader` (marine snow wrapped around the camera, zero CPU), `water_refraction.gdshader` (full-screen wobble + vignette, screen texture, render priority min). All four are instanced by `scripts/world/underwater_fx.gd` with runtime materials.

## Target health bar
`fx_target_bar.gdshader` (`scripts/ui/target_health_bars.gd`): billboard unit quad, node scale = bar size; dark backing + border, fill by the `frac` instance uniform, flat red < 0.2 / amber 0.3-0.5 / green > 0.6 with short blends (HUD palette colours set on the one shared material), `fade` instance uniform; depth test and fog off like the sonar rings.
