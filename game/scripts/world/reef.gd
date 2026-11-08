extends "res://scripts/world/reef_greybox.gd"
## The dressed reef (S5, res://scenes/maps/reef.tscn, main scene): everything the grey-box reef has (game loop, views,
## crowd, feedback FX, HUD, camera, input, look stack; see reef_greybox.gd for the user args) plus MapDressing (the
## environment kit placed from maps/reef_dressing.json) on a depth-coloured seabed (GreyboxTerrain with
## build_obstacles / build_edge_walls off, apron and depth_colors set in the scene), and AudioDirector (S7: event SFX,
## music, ambience). The dressing also draws the baked food sites; FoodSiteView hides eaten ones (food task).
## Extra user args (dev / captures):
##   --show-obstacles          draws the sim obstacle proxies (reef.json + baked reef_proxies.json) as translucent
##                             magenta over the dressing;
##   --views=<a,b,...>         fixed review cameras (VIEWS) instead of the follow camera, each held --hold=<frames>
##                             (default 120) frames, in order; PlayerInput idle, HUD hidden.

const VIEW_ARG: String = "--views="
const HOLD_ARG: String = "--hold="
const DEFAULT_HOLD_FRAMES: int = 120
## Review viewpoints: name -> [camera position, look-at point].
const VIEWS: Dictionary = {
	"spawn": [Vector3(4, -6.5, -264), Vector3(28, -10, -238)],
	"shallows": [Vector3(-120, -6, -262), Vector3(-150, -10, -222)],
	"shelf": [Vector3(-60, -11, -211), Vector3(-60, -13.5, -200)],
	"kelp": [Vector3(-196, -12, -132), Vector3(-178, -16, -98)],
	"kelp_in": [Vector3(-10, -20, -78), Vector3(5, -16, -60)],
	"arches": [Vector3(-60, -36, 14), Vector3(-60, -32, 40)],
	"cave": [Vector3(-20, -41, 52), Vector3(-20, -40, 74)],
	"boat": [Vector3(38, -39, 40), Vector3(55, -42, 55)],
	"cliff_top": [Vector3(0, -45, 112), Vector3(0, -62, 170)],
	"cliff": [Vector3(10, -62, 182), Vector3(0, -58, 136)],
	"abyss": [Vector3(-60, -66, 175), Vector3(-110, -66, 210)],
	"look_up": [Vector3(0, -12, -240), Vector3(4, -2, -228)],
	# food task review: eggs + starfish by spawn 0, capsules on kelp, pearl strands under arch_a / in the cave, abyss food
	"food_spawn": [Vector3(17.6, -5.6, -249.6), Vector3(16.4, -7.3, -252.6)],
	"food_kelp": [Vector3(-10.6, -27.5, -71.4), Vector3(-12.2, -28.2, -69.4)],
	"food_arch": [Vector3(-150, -26.5, -4.5), Vector3(-150, -24.6, 0)],
	"food_cave": [Vector3(-20, -37.6, 72.4), Vector3(-20, -36, 77.6)],
	"food_abyss": [Vector3(-19.6, -75.6, 175.6), Vector3(-18.9, -77.4, 179.2)],
	# krill review: the edge of a rich cloud in each krill zone
	"krill_shallows": [Vector3(-28, -3.5, -250), Vector3(-22, -4, -244)],
	"krill_open": [Vector3(-48, -11, -114), Vector3(-42, -12, -108)],
	"krill_abyss": [Vector3(92, -61, 170), Vector3(98, -62, 176)],
}

@onready var _dressing: MapDressing = $MapDressing
@onready var _audio: AudioDirector = $AudioDirector

var _views: PackedStringArray = []
var _hold: int = DEFAULT_HOLD_FRAMES
var _view_frame: int = 0
var _dressing_ms: float = 0.0


func _ready() -> void:
	super._ready()
	var world: SimWorld = _game_loop.world
	if world == null:
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var t0: int = Time.get_ticks_usec()
	var map_id := StringName(str(world.map.get("id", "")))
	_dressing.build(world.content.get_dressing(map_id), world.map, world.seabed, QualitySettings.tier(), world.content.get_food_sites(map_id))
	_dressing_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	var food_view := FoodSiteView.new()
	food_view.name = "FoodSiteView"
	add_child(food_view)
	food_view.setup(_game_loop, _dressing)
	_audio.setup(_game_loop, _game_loop.player_id, _camera_rig)
	if args.has("--show-obstacles"):
		_show_obstacles(world.map, world.content.get_proxies(map_id))
	for arg: String in args:
		if arg.begins_with(VIEW_ARG):
			_views = arg.trim_prefix(VIEW_ARG).split(",", false)
		elif arg.begins_with(HOLD_ARG):
			_hold = maxi(1, int(arg.trim_prefix(HOLD_ARG)))
	if not _views.is_empty():
		_camera_rig.set_process(false)
		_player_input.set_physics_process(false)
		_player_input.set_process_unhandled_input(false)
		_hud.visible = false
		_apply_view()


func _process(_delta: float) -> void:
	if _views.is_empty():
		return
	_view_frame += 1
	_apply_view()


func _apply_view() -> void:
	var view_name: String = _views[mini(_view_frame / _hold, _views.size() - 1)]
	var v: Array = VIEWS.get(view_name, VIEWS["spawn"])
	_camera_rig.global_position = v[0]
	_camera_rig.look_at(v[1], Vector3.UP)


## Runtime toggle of the obstacle overlay (what `--show-obstacles` draws at startup); used by the God tools (DevOverlays).
## The mesh is built on the first `on` and only hidden / shown afterwards.
func set_obstacles_visible(on: bool) -> void:
	var part: MeshInstance3D = _terrain.get_node_or_null("Obstacles") as MeshInstance3D
	if part != null:
		part.visible = on
	elif on and _game_loop.world != null:
		var world: SimWorld = _game_loop.world
		_show_obstacles(world.map, world.content.get_proxies(StringName(str(world.map.get("id", "")))))


func _show_obstacles(map: Dictionary, baked: Array) -> void:
	_terrain.build_obstacles = true
	_terrain.build(map, baked)
	var part: MeshInstance3D = _terrain.get_node_or_null("Obstacles") as MeshInstance3D
	if part == null:
		return
	part.visible = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.1, 0.8, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	part.material_override = mat


## grey-box presentation_stats() plus the dressing counters (MapDressing.stats) and its build time.
func presentation_stats() -> Dictionary:
	var s: Dictionary = super.presentation_stats()
	if s.is_empty():
		return s
	s.merge(_dressing.stats)
	s["dressing_build_ms"] = snappedf(_dressing_ms, 0.1)
	return s
