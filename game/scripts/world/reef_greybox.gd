extends Node3D
## Playable grey-box reef (S2): starts the GameLoop, builds the terrain from the same map data the sim uses,
## then wires player view, ambient crowd, NPC views, feedback FX, camera, input, HUD (S6: Hud + presence markers),
## mutation pick overlay, sonar and boss FX, target health bars (TargetHealthBars, added in code), debug overlay and the
## S5 look stack (DepthEnvironment tier extras + UnderwaterFx) to the world (calls down, after all children are ready). User args: `-- --autopilot` (SwimTourAutopilot drives the
## fish, PlayerInput stays idle, debug overlay starts visible, HUD hidden), `-- --demo-fx` (DemoFx scripted feedback
## situation, PlayerInput idle), `-- --look-back` (camera held in the look-back view), `-- --quality=low|high`
## (QualitySettings tier, overrides user://settings.cfg), `-- --ambient-mode=school|chunk` (AmbientRenderer layout),
## `-- --s6-demo=<shot>` (S6Demo capture fixture: hud | pick | sonar | presence | boss; dev only, see s6_demo.gd).
## The pick overlay is set up only when PlayerInput drives the fish (autopilot / demo-fx pick on their own).
##
## Bench API: presentation_stats() (counters + presentation time of the last frame, see the method doc).

@onready var _game_loop: GameLoop = $GameLoop
@onready var _terrain: GreyboxTerrain = $GreyboxTerrain
@onready var _player_view: PlayerView = $PlayerView
@onready var _camera_rig: CameraRig = $CameraRig
@onready var _player_input: PlayerInput = $PlayerInput
@onready var _debug_overlay: DebugOverlay = $DebugOverlay
@onready var _environment: DepthEnvironment = $WorldEnvironment
@onready var _ambient: AmbientRenderer = $AmbientRenderer
@onready var _npc_views: NpcViews = $NpcViews
@onready var _feedback: FeedbackFx = $FeedbackFx
@onready var _hud: Hud = $Hud
@onready var _pick_overlay: MutationPickOverlay = $MutationPickOverlay
@onready var _sonar: SonarFx = $SonarFx
@onready var _boss_fx: BossFx = $BossFx
@onready var _fx: UnderwaterFx = $UnderwaterFx


func _ready() -> void:
	if not _game_loop.start():
		return
	var world: SimWorld = _game_loop.world
	var id: int = _game_loop.player_id
	_terrain.build(world.map)
	_player_view.setup(_game_loop, id)
	var input: PlayerInput = null
	if not _game_loop.autopilot_enabled and not _game_loop.demo_fx_enabled:
		_player_input.setup(world, id)
		input = _player_input
	_camera_rig.setup(world, id, _player_view, input)
	_hud.setup(_game_loop, id, _camera_rig)
	_hud.visible = not _game_loop.autopilot_enabled
	if input != null:
		_pick_overlay.setup(world, id)
		_pick_overlay.opened.connect(_hud.set_overlay_open.bind(true))
		_pick_overlay.closed.connect(_hud.set_overlay_open.bind(false))
	# `ticked` order matters: FeedbackFx takes over the views of creatures that died this tick (before NpcViews
	# prunes them); AmbientRenderer hides promoted members before NpcViews shows their entities (same frame)
	_feedback.setup(_game_loop, id, _npc_views, _player_view, _camera_rig, _hud)
	var assets := CrowdAssets.create(world.content)
	var tier: StringName = QualitySettings.tier()
	_ambient.setup(_game_loop, assets, tier)
	_npc_views.setup(_game_loop, id, assets, _ambient)
	_sonar.setup(_game_loop, id, _camera_rig)
	_boss_fx.setup(_game_loop, id, _npc_views, _camera_rig, _hud)
	# health bars over what the player bites; created here, not in the .tscn files (one hook for both maps)
	var target_bars := TargetHealthBars.new()
	target_bars.name = "TargetHealthBars"
	add_child(target_bars)
	target_bars.setup(_game_loop, id, _camera_rig)
	_debug_overlay.setup(world, id, _game_loop.autopilot_enabled)
	_environment.setup(_camera_rig)
	_environment.apply_quality(tier)
	_fx.setup(_camera_rig, tier, _environment)
	var shot: String = S6Demo.requested_shot()
	if not shot.is_empty():
		add_child(S6Demo.new(_game_loop, id, shot, _player_input))


## Presentation counters for benches (empty before setup). Keys: quality_tier, ambient_mode ("school" | "chunk"),
## ambient_instances (school members drawn, all schools), ambient_instances_visible (of those, in schools within the
## visibility range of the camera), ambient_multimeshes, plankton_instances, plankton_multimeshes,
## interactive_instances, interactive_multimeshes, node_views (puffers + large actors), large_nodes, food_bits,
## multimesh_count (all MultiMeshInstance3D nodes of the crowd), ambient_usec / npc_views_usec / presentation_usec
## (CPU time of the last frame: their `ticked` handlers of that frame + _process, Time.get_ticks_usec()).
func presentation_stats() -> Dictionary:
	if _game_loop.world == null:
		return {}
	var s: Dictionary = _ambient.bench_stats()
	s.merge(_npc_views.bench_stats())
	s["multimesh_count"] = int(s["ambient_multimeshes"]) + int(s["plankton_multimeshes"]) + int(s["interactive_multimeshes"])
	s["presentation_usec"] = int(s["ambient_usec"]) + int(s["npc_views_usec"])
	return s
