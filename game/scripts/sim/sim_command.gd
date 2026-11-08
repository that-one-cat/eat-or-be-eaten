class_name SimCommand
extends RefCounted
## One input intent for one entity. The only way input reaches the sim (via SimWorld.submit).

enum Type { MOVE, BOOST, BITE, ABILITY, BRAKE, PICK_MUTATION, SET_CONTROL_MODE }

var type: Type = Type.MOVE
var entity_id: int = 0
## Target tick; -1 = the next tick to run.
var tick: int = -1
## Assigned by SimCommandQueue.push, monotonic per queue.
var seq: int = 0
## MOVE: desired direction (normalized by the sim).
var dir: Vector3 = Vector3.ZERO
## MOVE: 0..1.
var thrust: float = 0.0
## BOOST / BRAKE: on/off.
var active: bool = false
## BITE: target entity id, -1 = none.
var target_id: int = -1
## ABILITY: ability id from res://data/abilities (S6: bite_dash | sonar; Bite-Dash lunges along the current heading).
var ability_id: StringName = &""
## PICK_MUTATION: one node id of the player's pending offer (anything else is ignored).
var node_id: StringName = &""
## SET_CONTROL_MODE: control mode id from res://data/controls/modes.json (a stable id, not an index; unknown ids are ignored).
var mode_id: StringName = &""


static func move(p_entity_id: int, p_dir: Vector3, p_thrust: float, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.MOVE
	c.entity_id = p_entity_id
	c.dir = p_dir
	c.thrust = p_thrust
	c.tick = p_tick
	return c


static func boost(p_entity_id: int, p_active: bool, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.BOOST
	c.entity_id = p_entity_id
	c.active = p_active
	c.tick = p_tick
	return c


static func bite(p_entity_id: int, p_target_id: int, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.BITE
	c.entity_id = p_entity_id
	c.target_id = p_target_id
	c.tick = p_tick
	return c


static func ability(p_entity_id: int, p_ability_id: StringName, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.ABILITY
	c.entity_id = p_entity_id
	c.ability_id = p_ability_id
	c.tick = p_tick
	return c


static func brake(p_entity_id: int, p_active: bool, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.BRAKE
	c.entity_id = p_entity_id
	c.active = p_active
	c.tick = p_tick
	return c


static func pick_mutation(p_entity_id: int, p_node_id: StringName, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.PICK_MUTATION
	c.entity_id = p_entity_id
	c.node_id = p_node_id
	c.tick = p_tick
	return c


static func set_control_mode(p_entity_id: int, p_mode_id: StringName, p_tick: int = -1) -> SimCommand:
	var c := SimCommand.new()
	c.type = Type.SET_CONTROL_MODE
	c.entity_id = p_entity_id
	c.mode_id = p_mode_id
	c.tick = p_tick
	return c
