class_name TargetBarTracker
extends RefCounted
## Which creatures show a target health bar (TargetHealthBars draws them). Node-free and clock-free: time is sim
## ticks (a float `now` = world.tick + interpolation alpha), so a paused world freezes the fade too.
##  - A BITTEN event whose biter is the player starts (or refreshes) the bar of its victim: a living NPC creature that
##    is not the boss (the boss has the HUD bar). A killing bite starts nothing (the victim is gone in that tick).
##  - A bar stays HOLD_S after the player's last hit, then fades out over FADE_S. It is dropped at once when the
##    target is gone (died, eaten, demoted to the ambient tier: all remove the entity) or farther than the range.
##  - At most CAP bars; a hit on a new target when all are taken replaces the one hit longest ago.
##  - Food sites (food task): a SITE_BITTEN of the player that leaves HP > 0 starts the bar of that site; site keys live
##    in the negative key space (site_key(site) = -1 - site; entity ids are >= 1). A site bar is dropped like an
##    entity bar when the site is eaten (not alive), farther than the range, or faded.

## Simultaneous bars (also the TargetHealthBars pool size).
const CAP: int = 8
## Seconds a bar stays fully visible after the player's last hit on its target.
const HOLD_S: float = 4.0
## Seconds of the fade-out that follows.
const FADE_S: float = 0.5

## Tracked targets: entity ids (sites: site_key) and the tick of the player's last hit on each (parallel arrays, order = slot order).
var ids := PackedInt32Array()
var hit_ticks := PackedInt64Array()


## True when `ev` is a player bite that should show a bar over `victim` (the entity ev.entity_id, null when gone).
static func is_player_hit(ev: SimEvent, victim: SimEntity, player_id: int) -> bool:
	if ev == null or ev.type != SimEvent.Type.BITTEN or ev.other_id != player_id or ev.entity_id == player_id:
		return false
	if victim == null or victim.id != ev.entity_id or not victim.alive or victim.kind != SimEntity.Kind.CREATURE:
		return false
	return not victim.is_player and victim.boss_state < 0


## Key of food site `site` in `ids` (negative; entity ids are positive).
static func site_key(site: int) -> int:
	return -1 - site


## Food site of key `id` (-1 when `id` is an entity id).
static func key_site(id: int) -> int:
	return -1 - id if id < 0 else -1


## True when `ev` is a player bite on a food site that leaves it alive (HP > 0): a bar over ev.data.site.
static func is_player_site_hit(ev: SimEvent, player_id: int) -> bool:
	return ev != null and ev.type == SimEvent.Type.SITE_BITTEN and ev.entity_id == player_id and float(ev.data.get("hp", 0.0)) > 0.0


## Starts or refreshes the bar of `id` at `tick`.
func note_hit(id: int, tick: int) -> void:
	var i: int = ids.find(id)
	if i >= 0:
		hit_ticks[i] = tick
		return
	if ids.size() < CAP:
		ids.append(id)
		hit_ticks.append(tick)
		return
	var oldest: int = 0
	for j in hit_ticks.size():
		if hit_ticks[j] < hit_ticks[oldest]:
			oldest = j
	ids[oldest] = id
	hit_ticks[oldest] = tick


## Drops the bars whose target is gone or dead (site: eaten), farther than `range_m` from `centre`, or fully faded
## at `now`.
func prune(world: SimWorld, centre: Vector3, range_m: float, now: float) -> void:
	var r2: float = range_m * range_m
	var i: int = ids.size() - 1
	while i >= 0:
		var gone: bool
		var site: int = key_site(ids[i])
		if site >= 0:
			gone = world.food == null or site >= world.food.site_count() or not world.food.site_alive(site) \
				or world.food.site_pos(site).distance_squared_to(centre) > r2
		else:
			var e: SimEntity = world.get_entity(ids[i])
			gone = e == null or not e.alive or e.position.distance_squared_to(centre) > r2
		if gone or alpha(i, now) <= 0.0:
			ids.remove_at(i)
			hit_ticks.remove_at(i)
		i -= 1


## Opacity of slot `i` at `now` (ticks): 1 during HOLD_S after the last hit, then linear to 0 over FADE_S.
func alpha(i: int, now: float) -> float:
	var age_s: float = (now - float(hit_ticks[i])) * SimWorld.TICK_DT
	return clampf(1.0 - (age_s - HOLD_S) / FADE_S, 0.0, 1.0)
