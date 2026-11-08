class_name GodContext
extends RefCounted
## What a God command or panel can reach: the running world and the presentation nodes of the current run, handed over by
## GodHost (there is no global registry). Fields are null / -1 between runs. Commands and panels must go through
## documented `SimDebug` functions for anything that changes the sim (rules 1-2); the context only gives access.
##
## Output and UI requests are signals so a handler never needs a console or menu reference: `log()` ->
## `logged`, the built-ins `clear` / `menu` / `close` -> `clear_requested` / `menu_requested` / `close_requested`.

signal logged(text: String)
signal clear_requested
signal menu_requested
signal close_requested

var world: SimWorld = null
var player_id: int = -1
var loop: GameLoop = null
var player_input: PlayerInput = null
var camera: CameraRig = null
## The map scene root of the run.
var run: Node = null
## The Main node (flow state, settings).
var main: Node = null

var _overlays: DevOverlays = null


## The player entity, or null when there is no world / the id is gone.
func player() -> SimEntity:
	return world.get_entity(player_id) if world != null else null


## True while a run exists.
func has_run() -> bool:
	return world != null


## The run's DevOverlays node, created (as a child of the map root) on first use; null without a run or a map node.
func overlays() -> DevOverlays:
	if _overlays == null or not is_instance_valid(_overlays):
		if world == null or run == null or not (run is Node3D):
			return null
		_overlays = DevOverlays.new()
		run.add_child(_overlays)
		_overlays.setup(world, player_id, run)
	return _overlays


## The aim point of the player (GodAim) along the mouse aim, or the heading without a PlayerInput; the player position
## when there is no player.
func aim_point() -> Vector3:
	var p: SimEntity = player()
	if p == null:
		return Vector3.ZERO
	return GodAim.aim_point(world, p, player_input.aim_direction() if player_input != null else p.heading)


## Prints a line to the console log (no-op when no console listens).
func log(text: String) -> void:
	logged.emit(text)
