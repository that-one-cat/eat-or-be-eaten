# assets

Style: stylized **low-poly** with a flat/gradient **palette texture** (one shared `M_Palette` material, one palette row per species), simple toon/rim-light shader, depth fog. Silhouette and hue double as gameplay signals ("can I eat it?"). Not semi-realistic, not hand-painted per-species textures (breaks batching).

Folders: `models/` (GLB 2.0 only), `textures/` (palette atlas, icons), `audio/`.

Rules:

- Naming: `sp_<archetype>_<species>_s<stage>_<lod>` (example: `sp_fusiform_grouper_s2_lod0`).
- GLB export from Blender with applied transforms, 1 unit = 1 m, origin at the centre of mass; normal mode Flat on import.
- Triangle budgets: plankton <=150, small <=600, medium <=1,500, large <=3,000, player <=4,000.
- Every shipped asset has an entry in `manifest.yaml` (provenance for Steam AI disclosure and licences). AI-generated 3D only for awkward body plans (octopus, crab, turtle, jellyfish), never the main source. Hunyuan3D 2.1 is excluded (licence). Never feed Unity Asset Store assets to AI generators.
- Raw/unreviewed output goes to `_raw/` or `_incoming/` (gitignored), not here.
- Icons are rendered from the 3D species themselves.

Full reasoning: Vault `projects/fish-game/research/art-pipeline.md`.

## Species pipeline in Godot

Models come from `tools/blender/` (spec JSON -> GLB; conventions in `tools/blender/README.md`: unit body length along Z, nose to -Z, origin at the centre of mass, `juvenile`/`adult` blend shapes, extras `length_m`, `size_class`, `species_id`).

- **Import**: every `models/species/*.glb.import` sets `import_script/path="res://scripts/fish/species_post_import.gd"`. For a new GLB: run `godot --headless --path game --import` once (creates the `.import` file), set that line, import again, commit the `.import` file. The script replaces the Blender placeholder material with the shared `res://shaders/m_palette.tres` and rebuilds meshes under 1,000 triangles without auto-LODs (blend shapes kept). Normals stay as exported (per-face); the shaders rebuild facet normals anyway.
- **Palette**: `textures/palette.png` imports lossless, no mipmaps, `detect_3d` off (VRAM compression would smear the 4 px species rows); the shaders sample it with `filter_nearest`.
- **Materials** (`game/shaders/`): `m_palette.tres` (`palette_toon.gdshader`, static look: palette albedo, 2-step toon light, rim, optional glow swatch), `m_fish_swim.tres` (`fish_swim.gdshader`, same look + vertex swim), `m_ray_swim.tres` (swim preset with wing flap for the ray archetype), `m_shark_swim.tres` (slow tail-led beat, weaker rim so predators read darker; shark, barracuda), `m_boss_swim.tres` (giant shark: shark motion + `accent` glow 2.5), `m_puffer_swim.tres` (fast fin flutter, stiff body), `m_plankton_swim.tres` (slow drift + faint glow). Shared look lives in `palette_toon.gdshaderinc`. Both shaders run on Forward+ and Compatibility. Glow is a material uniform, so a species that glows needs its own preset (giant shark: fin edges, gills and irises are painted with the `accent` swatch).
- **Swimming fish**: set the swim material as `material_override` (MeshInstance3D or MultiMeshInstance3D). Phase per fish: `set_instance_shader_parameter("swim_phase", x)` on single nodes, `INSTANCE_CUSTOM.x` (0..1) on MultiMesh instances (enable `use_custom_data` before `instance_count`). Growth `g`: blend shape weights `juvenile = 1 - g`, `adult = g`; node scale = body length in metres. Puffer: blend shape `inflated` 0..1 on top (girth x1.8, spines out; a delta from the adult).
- **Glow accents**: `glow_strength > 0` makes the `accent` swatch (slot 11, or `glow_slot`) emissive.
- **Preview**: `godot --path game res://scenes/dev/species_showcase.tscn` (S1: reef fish + ray) and `res://scenes/dev/species_lineup.tscn` (all 8 MVP species at true relative scale, juvenile + adult, puffers toggling `inflated`; a 24 s camera tour with 6 stops, the last one the overview with the 10 m giant shark at the far end; capture with `tools/capture.sh res://scenes/dev/species_lineup.tscn 1440 <dir>`).

## Environment pipeline in Godot

Models come from `tools/blender/env/` (spec JSON -> GLB; conventions in `tools/blender/env/README.md`: real metres, origin at the base centre with y = 0 at the ground contact, front to -Z, flat facets, env palette rows 32-63, sway weight in UV2.x, emissive `accent` swatch for glowing pieces). Files: `models/env/env_<id>_v<n>_lod0.glb`; triangle budgets `env_small` <= 300, `env_medium` <= 1,500, `env_large` <= 4,000 (table: `tools/blender/env/BUDGETS.md`).

- **Import**: `tools/blender/env/build_all.py` writes a `.glb.import` stub with `import_script/path="res://scripts/world/env_post_import.gd"` for every new GLB; `godot --headless --path game --import` fills in the rest. The script (extends the species one) puts `res://shaders/m_env.tres` on every surface (fallback `m_palette.tres` if it does not exist at import time; reimport after it appears) and drops auto-LODs below 1,000 triangles.
- **Metadata**: node extras (`get_meta("extras")` on the imported node) carry `piece_id`, `size_class`, `aabb_min_m`/`aabb_max_m`, `footprint_m`, `sway`, `glow`.
- **Physics**: none in the GLBs; sim collision stays analytic (`reef.json` obstacles).

## Audio in Godot

Sounds come from `tools/audio/` (`build_all.py`; commands, dependencies and determinism in `tools/audio/README.md`): `audio/sfx/<group>/<group>_v<n>.wav` (2-3 deliberately different variants per group) and `audio/music/{reef_theme_v1,reef_boss_v1,ambience_reef}.ogg` (loops; their `.ogg.import` files set `loop=true`, keep that on reimport). Never hand-edit a rendered file; change the preset or score and rebuild. Playback: `scripts/audio/README.md`.
