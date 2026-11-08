class_name FishRig
extends AnimationTree
## AnimationTree of a hero rig (S7; tools/blender/rig/make_rig.py: the player fish and the giant shark boss only,
## CLAUDE.md rule 10). Graph `res://scenes/fish/fish_rig_tree.tres`:
##   swim (looped, 1 beat/s) -> swim_rate (TimeScale) -> turn_l / turn_r (Add2, static C-bend poses)
##   -> tell (Add2, boss wind-up pose) -> dash (OneShot, whole body) -> bite (OneShot, filtered to jaw + head bones).
## Callers (PlayerView, BossView) feed it from sim state and events only; nothing here reads or writes the sim.
## Parameter writes are guarded (no set() when the value did not change). The rigged GLBs use the *_rig swim
## material presets (vertex swim amplitudes 0), so the skeleton motion is not doubled by the shader.

const TREE: AnimationNodeBlendTree = preload("res://scenes/fish/fish_rig_tree.tres")
const NODE_NAME: StringName = &"FishRig"
const P_SWIM_RATE: StringName = &"parameters/swim_rate/scale"
const P_TURN_L: StringName = &"parameters/turn_l/add_amount"
const P_TURN_R: StringName = &"parameters/turn_r/add_amount"
const P_TELL: StringName = &"parameters/tell/add_amount"
const P_DASH: StringName = &"parameters/dash/request"
const P_BITE: StringName = &"parameters/bite/request"
const P_BITE_ACTIVE: StringName = &"parameters/bite/active"
## Smallest change worth a parameter write.
const EPS: float = 0.005

var _swim_rate: float = 1.0
var _turn: float = 0.0
var _tell: float = 0.0


## The rig of `model` (a rigged GLB instance with an AnimationPlayer): the existing FishRig child, or a new one
## added as a child. Null when the model has no AnimationPlayer (unrigged fallback model).
static func attach(model: Node) -> FishRig:
	var existing: FishRig = model.get_node_or_null(NodePath(NODE_NAME)) as FishRig
	if existing != null:
		return existing
	var players: Array[Node] = model.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return null
	var rig := FishRig.new()
	rig.name = NODE_NAME
	rig.tree_root = TREE
	model.add_child(rig)
	rig.root_node = rig.get_path_to(model)
	rig.anim_player = rig.get_path_to(players[0])
	rig.set(P_SWIM_RATE, rig._swim_rate)
	rig.active = true
	return rig


## Tail beats per second (the swim clip is one beat long).
func set_swim_rate(beats_per_s: float) -> void:
	if absf(beats_per_s - _swim_rate) > EPS:
		_swim_rate = beats_per_s
		set(P_SWIM_RATE, beats_per_s)


## Turn bend in [-1, 1]: positive = turning left (yaw increasing), negative = right.
func set_turn(turn: float) -> void:
	turn = clampf(turn, -1.0, 1.0)
	if absf(turn - _turn) > EPS or (turn == 0.0 and _turn != 0.0):
		_turn = turn
		set(P_TURN_L, maxf(turn, 0.0))
		set(P_TURN_R, maxf(-turn, 0.0))


## Boss wind-up pose amount in [0, 1] (wide gape, nose up, coiled body).
func set_tell(amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if absf(amount - _tell) > EPS or (amount == 0.0 and _tell != 0.0):
		_tell = amount
		set(P_TELL, amount)


## Bite snap (jaw + head); ignored while a bite is still playing.
func bite() -> void:
	if not bool(get(P_BITE_ACTIVE)):
		set(P_BITE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## Burst stroke (dash, boost start, boss charge); restarts a running one.
func dash() -> void:
	set(P_DASH, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
