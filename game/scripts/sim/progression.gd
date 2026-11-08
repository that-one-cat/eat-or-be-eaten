class_name Progression
extends RefCounted
## Mutation picks and passives (GAME_DESIGN section 4). Static and stateless: everything lives on the player
## SimEntity (`mutations`, `pending_offer`, `picks_offered_for_band`, the passive multipliers, `abilities`), every
## draw comes from the world RNG, so a run is reproducible from its seed and commands (rule 2).
##
## Offers: SimWorld calls offer() on a player's BAND_UP and after each pick. When the player has no open offer, the
## lowest band in 2..band that was never offered gets one: up to rules.mutation_offer_count node ids drawn without
## replacement (world RNG, partial Fisher-Yates over the available ids in ascending order) from the available nodes;
## the band is marked offered even when nothing is available (then no offer and no event). Available = not owned and
## (tier 1 or `requires` owned): tier order inside a branch. Sets `pending_offer` and emits MUTATION_OFFERED.
## A jump over several bands (B1 -> B4 in one tick) therefore offers band by band, one pick each.
## pick(): a node id from the open offer is owned (appended to `mutations`), its `grants_ability` is granted (ready
## at once), the passives are recomputed, the offer is cleared and MUTATION_PICKED is emitted; anything else is
## ignored. grant() applies a node the same way without an offer (test / bot / UI hooks). The world-level pause (SimWorld.paused_for_pick) is derived from the offers by SimWorld.
##
## Passives (apply_effects): every multiplier key of the owned nodes' `effects` multiplies into the field of the same
## name (bite_power_mult, swim_speed_mult, boost_duration_mult, boost_speed_mult, hunger_drain_mult,
## damage_taken_mult; 1 without any); presence_sector_deg is the widest owned value, else rules presence.sector_deg.
## SimWorld applies them in the existing rules (bite damage, swim speed, boost drain / speed, hunger drain, damage
## taken from bites, spikes and the boss charge).

## Effect keys that are not multipliers.
const SECTOR_KEY: String = "presence_sector_deg"


## Offers the next owed band (see the class doc). No-op without content, for NPCs, dead players (a dead player cannot
## pick: the pause would never end; the band stays owed and is offered at the next call) or while an offer is open.
static func offer(world: SimWorld, e: SimEntity) -> void:
	if world.content == null or not e.is_player or not e.alive or not e.pending_offer.is_empty():
		return
	for band in range(2, e.band + 1):
		if e.picks_offered_for_band.has(band):
			continue
		e.picks_offered_for_band.append(band)
		var pool: PackedStringArray = available(world.content, e)
		var n: int = mini(int(world.content.rules().get("mutation_offer_count", 3)), pool.size())
		if n <= 0:
			continue
		for i in n:
			var j: int = world.rng.range_int(i, pool.size() - 1)
			var tmp: String = pool[i]
			pool[i] = pool[j]
			pool[j] = tmp
		e.pending_offer = pool.slice(0, n)
		var ev: SimEvent = world.emit_event(SimEvent.Type.MUTATION_OFFERED, e.id, -1, float(band))
		ev.data = {"offer": e.pending_offer.duplicate(), "band": band}
		return


## Node ids `e` can pick now, ascending: not owned, and tier 1 or its `requires` node owned.
static func available(content: ContentDB, e: SimEntity) -> PackedStringArray:
	var out := PackedStringArray()
	for id in content.mutation_ids():
		var sid := String(id)
		if e.mutations.has(sid):
			continue
		var req: Variant = content.get_mutation(id).get("requires")
		if req is String and not e.mutations.has(req):
			continue
		out.append(sid)
	return out


## Applies a pick from the open offer; returns false (nothing changes) when `node_id` is not offered.
static func pick(world: SimWorld, e: SimEntity, node_id: StringName) -> bool:
	if world.content == null or not e.pending_offer.has(String(node_id)):
		return false
	e.pending_offer = PackedStringArray()
	return grant(world, e, String(node_id))


## Applies node `node_id` to `e` exactly like a pick (owned, granted ability ready at once, passives recomputed,
## MUTATION_PICKED) without an offer and without the tier-order check: for tests, bot v2 and UI-flow hooks. Leaves
## an open offer (and a pause for it) untouched until a PICK_MUTATION. False for an unknown or owned node.
static func grant(world: SimWorld, e: SimEntity, node_id: String) -> bool:
	if world.content == null or e.mutations.has(node_id) or world.content.get_mutation(StringName(node_id)).is_empty():
		return false
	var sid: String = node_id
	e.mutations.append(sid)
	var ability: String = ""
	var rec: Dictionary = world.content.get_mutation(StringName(sid))
	if rec.get("grants_ability") is String:
		ability = rec["grants_ability"]
		if not e.abilities.has(ability):
			e.abilities.append(ability)
			e.ability_ready_ticks.append(0)
	apply_effects(world.content, e)
	var ev: SimEvent = world.emit_event(SimEvent.Type.MUTATION_PICKED, e.id)
	ev.data = {"node_id": sid, "ability": ability}
	return true


## Recomputes the passive fields of `e` from its owned mutations (see the class doc).
static func apply_effects(content: ContentDB, e: SimEntity) -> void:
	e.bite_power_mult = 1.0
	e.swim_speed_mult = 1.0
	e.boost_duration_mult = 1.0
	e.boost_speed_mult = 1.0
	e.hunger_drain_mult = 1.0
	e.damage_taken_mult = 1.0
	e.presence_sector_deg = default_sector(content) if e.is_player else 0.0
	if content == null:
		return
	for id in e.mutations:
		var effects: Variant = content.get_mutation(StringName(id)).get("effects")
		if not (effects is Dictionary):
			continue
		for key: String in effects:
			var v: float = float(effects[key])
			match key:
				"bite_power_mult":
					e.bite_power_mult *= v
				"swim_speed_mult":
					e.swim_speed_mult *= v
				"boost_duration_mult":
					e.boost_duration_mult *= v
				"boost_speed_mult":
					e.boost_speed_mult *= v
				"hunger_drain_mult":
					e.hunger_drain_mult *= v
				"damage_taken_mult":
					e.damage_taken_mult *= v
				SECTOR_KEY:
					e.presence_sector_deg = maxf(e.presence_sector_deg, v)


## rules presence.sector_deg (270 in the shipped data; 360 without content).
static func default_sector(content: ContentDB) -> float:
	if content == null:
		return 360.0
	var presence: Variant = content.rules().get("presence")
	return float((presence as Dictionary).get("sector_deg", 360.0)) if presence is Dictionary else 360.0
