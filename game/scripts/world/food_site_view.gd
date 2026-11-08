class_name FoodSiteView
extends Node
## Eaten / respawned food sites on screen (food task X1): reads SITE_EATEN / SITE_RESPAWNED by cursor (once per
## GameLoop.ticked, same-tick guard: a world paused for a pick re-emits `ticked` with the same tick) and hides / shows
## the site's instance in MapDressing (set_site_visible). Setup syncs every site that is already eaten. Reads sim
## events and FoodSites state only, never writes the sim.

var _world: SimWorld
var _dressing: MapDressing
var _event_tick: int = 0


func setup(loop: GameLoop, dressing: MapDressing) -> void:
	_world = loop.world
	_dressing = dressing
	_event_tick = _world.tick
	var food: FoodSites = _world.food
	if food != null:
		for i in food.site_count():
			if not food.site_alive(i):
				_dressing.set_site_visible(i, false)
	loop.ticked.connect(_on_ticked)


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return
	for ev: SimEvent in _world.events_since(_event_tick):
		if ev.type == SimEvent.Type.SITE_EATEN:
			_dressing.set_site_visible(int(ev.data.get("site", -1)), false)
		elif ev.type == SimEvent.Type.SITE_RESPAWNED:
			_dressing.set_site_visible(int(ev.data.get("site", -1)), true)
	_event_tick = _world.tick
