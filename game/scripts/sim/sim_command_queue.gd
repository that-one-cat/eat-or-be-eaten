class_name SimCommandQueue
extends RefCounted
## Pending commands. pop_for_tick() releases due commands in a deterministic order:
## (effective target tick asc, entity_id asc, seq asc). A tick of -1 counts as the popped tick.
## The order does not depend on how pushes from different entities interleave; per entity it is FIFO.

var _pending: Array[SimCommand] = []
var _next_seq: int = 0
var _pop_tick: int = 0  # effective tick for -1 commands during the current pop (used by the comparator)


func push(cmd: SimCommand) -> void:
	_next_seq += 1
	cmd.seq = _next_seq
	_pending.append(cmd)


func size() -> int:
	return _pending.size()


func clear() -> void:
	_pending.clear()


## Removes and returns every command with tick <= `tick` (-1 counts as `tick`), sorted.
func pop_for_tick(tick: int) -> Array[SimCommand]:
	var due: Array[SimCommand] = []
	if _pending.is_empty():
		return due
	var keep: int = 0
	for i in _pending.size():
		var c: SimCommand = _pending[i]
		if c.tick <= tick:
			due.append(c)
		else:
			_pending[keep] = c
			keep += 1
	_pending.resize(keep)
	if due.size() > 1:
		_pop_tick = tick
		# pushes usually arrive in order already (players, then brains by ascending id): skip the sort then
		for i in range(1, due.size()):
			if _less(due[i], due[i - 1]):
				due.sort_custom(_less)
				break
	return due


## Removes and returns the commands of `type` with tick <= `tick` (-1 counts as `tick`), sorted; every other command
## stays queued in order (SimWorld applies only PICK_MUTATION while paused for a pick).
func pop_type_for_tick(type: SimCommand.Type, tick: int) -> Array[SimCommand]:
	var due: Array[SimCommand] = []
	var keep: int = 0
	for i in _pending.size():
		var c: SimCommand = _pending[i]
		if c.type == type and c.tick <= tick:
			due.append(c)
		else:
			_pending[keep] = c
			keep += 1
	_pending.resize(keep)
	if due.size() > 1:
		_pop_tick = tick
		due.sort_custom(_less)
	return due


## Appends the pending commands to `buf` for SimWorld.state_hash(): canonical order (tick asc with -1 first,
## entity_id asc, then queue order) and without `seq`, so the result does not depend on how pushes from
## different entities interleaved.
func write_state(buf: StreamPeerBuffer) -> void:
	buf.put_64(_pending.size())
	if _pending.is_empty():
		return
	var sorted_cmds: Array[SimCommand] = _pending.duplicate()
	_pop_tick = -1
	sorted_cmds.sort_custom(_less)
	for c in sorted_cmds:
		buf.put_8(c.type)
		buf.put_64(c.entity_id)
		buf.put_64(c.tick)
		buf.put_double(c.dir.x)
		buf.put_double(c.dir.y)
		buf.put_double(c.dir.z)
		buf.put_double(c.thrust)
		buf.put_8(int(c.active))
		buf.put_64(c.target_id)
		buf.put_utf8_string(String(c.ability_id))
		buf.put_utf8_string(String(c.node_id))
		if c.type == SimCommand.Type.SET_CONTROL_MODE:  # only this type carries the payload: the bytes of the others stay as they were
			buf.put_utf8_string(String(c.mode_id))


func _less(a: SimCommand, b: SimCommand) -> bool:
	var ta: int = _pop_tick if a.tick < 0 else a.tick
	var tb: int = _pop_tick if b.tick < 0 else b.tick
	if ta != tb:
		return ta < tb
	if a.entity_id != b.entity_id:
		return a.entity_id < b.entity_id
	return a.seq < b.seq
