# scripts/fish - fish presentation and local control

Rendering side of fish: nodes, animation hooks, player controller that turns input into sim commands. Three-tier model:

- **ambient** (~70%): fully procedural in the vertex shader (MultiMesh), not individually eatable, counted only as school density
- **interactive** (up to ~200 near the player): driven by the sim, written to MultiMesh in bulk
- **large** (up to ~20): real nodes with steering

Crowd fish are opaque, no shadows, no physics bodies. Only the player (and a few hero predators) get a skeleton.

Camera (`camera_rig.gd`, S7 feel pass): band distance / near / far from data; per-band elevation (`ELEVATION_BY_BAND`, B1 24 deg .. B4 16 deg) and a pivot `LOOK_AHEAD_LENGTHS` body lengths ahead of the fish keep the head, jaw and mouth FX in view (both are consts with a TODO to move into `size_bands[].camera`); look-back levels out to 10 deg without lead.

Hero rigs (S7): `fish_rig.gd` (`FishRig`, an `AnimationTree` with the graph `res://scenes/fish/fish_rig_tree.tres`: `swim` time-scaled by speed, additive `turn_l`/`turn_r` by yaw rate, additive `tell`, one-shots `dash` and `bite` (filtered to jaw + head bones)) on the rigged GLBs `sp_*_s1_rig_lod0.glb` (`tools/blender/rig/make_rig.py`) with the `m_fish_rig` / `m_boss_rig` material presets (vertex swim amplitudes 0, so the shader does not double the skeleton motion). `PlayerView` uses the player rig; `BossView` (scripts/world) the giant shark rig.

Control modes (T1.4, `docs/data/controls.md`): `PlayerInput.control_mode` (set by `GameSettings.apply_input` and the God console `mode`) selects a record of `data/controls/modes.json`; `aim_smoothing.gd` (`AimSmoothing.step`, pure and static) eases the MOVE aim direction for modes with `mouse_smooth_tau_s` / `aim_turn_cap_deg_s`; the node tells the sim once per change with `SET_CONTROL_MODE` (never for classic at run start).
