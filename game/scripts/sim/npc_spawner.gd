class_name NpcSpawner
extends RefCounted
## Per-zone NPC spawners (map `spawners`): keeps every record at its target count and respawns losses. Since S4 the
## map lists only the non-schooling species here (puffer, barracuda, grouper, sharks); schooling species live in
## SchoolSystem and plankton in PlanktonField. Called by SimWorld.step() in the spawner phase (after deaths and
## growth). Static; the per-world state (alive ids per spawner, pending respawn ticks, home zone per NPC, packs) is
## attached to the SimWorld as metadata (see write_state() for hashing it).
##
## set_enabled(world, true) switches the whole NPC population on: these spawners, the school tier phase
## (TierManager) and plankton grazing. Disabled by default so plain SimWorlds (tests, S2 scenes) stay empty.
##
## Records of schooling species (species `schooling`: they live in SchoolSystem) and of ambient-tier species
## (plankton: PlanktonField) spawn nothing (target 0).
## Counts: target_i = max(1, round(count_i * rules.npc_scale)) (rules.s3_npc_scale is still read when npc_scale is
## missing). Caps per tier (rule 4): interactive-tier spawners share rules.tiers.interactive_cap, large-tier spawners
## rules.tiers.large_cap. When a group's sum exceeds its cap, its targets are scaled to the cap: exact share
## count * cap / sum, floored, at least 1; then the largest (lowest index on ties) lose one each while the sum is
## above the cap, and the largest remainders (lowest index on ties) gain one each while it is below. Missing rules:
## scale 1, no cap. (Promoted school members also count against interactive_cap; TierManager keeps room for these
## spawner targets.)
## The whole population spawns on the first tick; afterwards a dead or removed NPC is replaced respawn_s later
## (respawn_s 0 = never, e.g. the giant shark). Positions come from the world RNG: uniform inside the zone AABB,
## height clamped to [seabed + behaviour.seabed_clearance_m, -clearance], resampled when the point is inside an
## obstacle, the zone has no water column there, or (S7) a living player is closer than
## rules.spawn.min_player_distance_m (missing = 0, no check). After _SPAWN_TRIES failed samples the last one is used.
##
## Packs (spawner `group` {min, max, chance, radius_m}, optional): on the first tick the target of a spawner is cut
## into packs in spawn order: per draw, with probability `chance` (world RNG) a pack of range_int(min, max) members
## (clipped to what is left of the target, so the last pack may be smaller), else a single NPC. Without `group` every
## NPC is a pack of one and no extra RNG is drawn (placements are the pre-pack ones). Pack membership is fixed per
## slot: a lost member is respawned respawn_s later (per member, as before) INTO ITS PACK: next to the pack leader
## (the lowest-id living member; uniform within +-radius_m horizontally, +-radius_m / 2 vertically, clamped to the zone
## AABB and the water column, same obstacle / player checks) when the pack still has a living member, else at a zone
## position like a fresh NPC (it becomes the new leader and the next respawns join it). Members of a new pack on the
## first tick are placed the same way around the first one. A due member respawn waits while the leader is closer than
## rules.spawn.min_player_distance_m to a living player (no pop-in next to the player, no instant refill mid-fight).
## Every member is an ordinary NPC (own hp, brain, temperament); NpcBrain reads pack_leader() / pack_radius_m() for
## the follow-the-leader cohesion while wandering.

const _META: StringName = &"npc_spawner_state"
## Position resampling attempts before falling back to the last sample pushed out by the SeabedField.
const _SPAWN_TRIES: int = 8


class _State:
	extends RefCounted
	var enabled: bool = false
	var initialized: bool = false
	var targets: PackedInt32Array = PackedInt32Array()
	var respawn_ticks: PackedInt32Array = PackedInt32Array()  # 0 = never respawn
	var species: Array[StringName] = []
	var zone: PackedInt32Array = PackedInt32Array()  # index into map zones, -1 unknown
	var tier: PackedInt32Array = PackedInt32Array()  # SimWorld.TIER_* of the species
	var group_min: PackedInt32Array = PackedInt32Array()  # per spawner, 1 = no `group`
	var group_max: PackedInt32Array = PackedInt32Array()
	var group_chance: PackedFloat64Array = PackedFloat64Array()
	var group_radius: PackedFloat64Array = PackedFloat64Array()  # metres, 0 = no `group`
	var min_player_d: float = 0.0  # rules.spawn.min_player_distance_m
	var alive: Array = []  # per spawner: Array[int] of entity ids (ascending)
	var pending: Array = []  # per spawner: Array[int] of due ticks (ascending)
	var pending_pack: Array = []  # per spawner: Array[int] pack index of each due tick (parallel to pending)
	var home: Dictionary = {}  # entity id -> zone index
	var pack_spawner: PackedInt32Array = PackedInt32Array()  # per pack: spawner index
	var pack_members: Array = []  # per pack: Array[int] of living member ids (ascending)
	var pack_of: Dictionary = {}  # entity id -> pack index


## Turns spawning on or off for `world` (off by default).
static func set_enabled(world: SimWorld, enabled: bool) -> void:
	_state(world).enabled = enabled


static func is_enabled(world: SimWorld) -> bool:
	return world.has_meta(_META) and (world.get_meta(_META) as _State).enabled


## Phase 9 of SimWorld.step(): replaces losses and spawns what is due.
static func tick(world: SimWorld) -> void:
	if not world.has_meta(_META) or world.content == null or world.map.is_empty():
		return
	var st: _State = world.get_meta(_META)
	if not st.enabled:
		return
	if not st.initialized:
		_init_state(world, st)
	for i in st.targets.size():
		var ids: Array[int] = st.alive[i]
		var due: Array[int] = st.pending[i]
		var due_pack: Array[int] = st.pending_pack[i]
		var k: int = 0
		while k < ids.size():
			var e: SimEntity = world.get_entity(ids[k])
			if e != null and e.alive:
				k += 1
				continue
			var p: int = st.pack_of[ids[k]]
			(st.pack_members[p] as Array[int]).erase(ids[k])
			st.pack_of.erase(ids[k])
			st.home.erase(ids[k])
			ids.remove_at(k)
			if st.respawn_ticks[i] > 0:
				due.append(world.tick + st.respawn_ticks[i])
				due_pack.append(p)
		var j: int = 0
		while j < due.size() and due[j] <= world.tick and ids.size() < st.targets[i]:
			if _pack_waits(world, st, due_pack[j]):
				j += 1
				continue
			var pack: int = due_pack[j]
			due.remove_at(j)
			due_pack.remove_at(j)
			_spawn_for(world, st, i, pack)


## Zone index (into map `zones`) an NPC was spawned in, -1 when it was not spawned by a spawner.
static func home_zone_index(world: SimWorld, entity_id: int) -> int:
	if not world.has_meta(_META):
		return -1
	return int((world.get_meta(_META) as _State).home.get(entity_id, -1))


## Number of NPCs the spawner at `index` keeps alive (after scale and cap); 0 before the first tick.
static func target_count(world: SimWorld, index: int) -> int:
	if not world.has_meta(_META):
		return 0
	var st: _State = world.get_meta(_META)
	return st.targets[index] if index >= 0 and index < st.targets.size() else 0


## Sum of the targets of the spawners whose species is in `tier` (SimWorld.TIER_*); 0 before the first tick.
static func target_total(world: SimWorld, tier: int) -> int:
	if not world.has_meta(_META):
		return 0
	var st: _State = world.get_meta(_META)
	var n: int = 0
	for i in st.targets.size():
		if st.tier[i] == tier:
			n += st.targets[i]
	return n


## Id of the pack leader `entity_id` follows: the lowest-id living member of its pack when that is another NPC;
## -1 for leaders, NPCs alone in their pack and entities not spawned by a spawner.
static func pack_leader(world: SimWorld, entity_id: int) -> int:
	if not world.has_meta(_META):
		return -1
	var st: _State = world.get_meta(_META)
	var p: int = int(st.pack_of.get(entity_id, -1))
	if p < 0:
		return -1
	var leader: SimEntity = _leader(world, st, p)
	return leader.id if leader != null and leader.id != entity_id else -1


## Spawner `group.radius_m` of the pack of `entity_id`; 0 without a group (or not a spawner NPC).
static func pack_radius_m(world: SimWorld, entity_id: int) -> float:
	if not world.has_meta(_META):
		return 0.0
	var st: _State = world.get_meta(_META)
	var p: int = int(st.pack_of.get(entity_id, -1))
	return st.group_radius[st.pack_spawner[p]] if p >= 0 else 0.0


## Pack index of a spawner NPC, -1 otherwise. Packs are numbered 0.. in first-tick spawn order and never change.
static func pack_index(world: SimWorld, entity_id: int) -> int:
	if not world.has_meta(_META):
		return -1
	return int((world.get_meta(_META) as _State).pack_of.get(entity_id, -1))


## Number of packs (0 before the first tick).
static func pack_count(world: SimWorld) -> int:
	return (world.get_meta(_META) as _State).pack_members.size() if world.has_meta(_META) else 0


## Living member ids of pack `pack` (ascending, a copy; as of the last spawner phase).
static func pack_members(world: SimWorld, pack: int) -> Array[int]:
	var out: Array[int] = []
	if world.has_meta(_META) and pack >= 0 and pack < pack_count(world):
		out.assign((world.get_meta(_META) as _State).pack_members[pack])
	return out


## Spawns one NPC (SimWorld.spawn_entity gives it the band of its length and full species HP) facing `heading`,
## with full boost stamina so brains can dash right away.
static func spawn_npc(world: SimWorld, species_id: StringName, pos: Vector3, length_m: float, heading: Vector3 = Vector3.FORWARD) -> int:
	var id: int = world.spawn_entity(species_id, pos, length_m)
	var e: SimEntity = world.get_entity(id)
	e.heading = heading.normalized() if not heading.is_zero_approx() else Vector3.FORWARD
	if world.content != null:
		e.stamina = float(world.content.get_ability(&"boost").get("stamina_max", 0.0))
	return id


## Appends the spawner state to a state hash buffer (SimWorld.state_hash()); writes nothing when spawning was
## never configured for this world.
static func write_state(world: SimWorld, buf: StreamPeerBuffer) -> void:
	if not world.has_meta(_META):
		return
	var st: _State = world.get_meta(_META)
	buf.put_8(int(st.enabled) | (int(st.initialized) << 1))
	for i in st.targets.size():
		var ids: Array[int] = st.alive[i]
		var due: Array[int] = st.pending[i]
		var due_pack: Array[int] = st.pending_pack[i]
		buf.put_32(ids.size())
		for id in ids:
			buf.put_64(id)
			buf.put_32(int(st.home.get(id, -1)))
			buf.put_32(int(st.pack_of.get(id, -1)))
		buf.put_32(due.size())
		for k in due.size():
			buf.put_64(due[k])
			buf.put_32(due_pack[k])
	buf.put_32(st.pack_spawner.size())
	for s in st.pack_spawner:
		buf.put_32(s)


static func _state(world: SimWorld) -> _State:
	if not world.has_meta(_META):
		world.set_meta(_META, _State.new())
	return world.get_meta(_META)


static func _init_state(world: SimWorld, st: _State) -> void:
	st.initialized = true
	var rules: Dictionary = world.content.rules()
	var scale: float = float(rules.get("npc_scale", rules.get("s3_npc_scale", 1.0)))
	var tiers: Dictionary = rules.get("tiers", {}) if rules.get("tiers") is Dictionary else {}
	var caps: Dictionary = {SimWorld.TIER_INTERACTIVE: int(tiers.get("interactive_cap", -1)), SimWorld.TIER_LARGE: int(tiers.get("large_cap", -1))}
	var spawn_rules: Variant = rules.get("spawn")
	st.min_player_d = float((spawn_rules as Dictionary).get("min_player_distance_m", 0.0)) if spawn_rules is Dictionary else 0.0
	var zone_ids: Array[String] = []
	for z in (world.map.get("zones", []) as Array):
		zone_ids.append(str((z as Dictionary).get("id")))
	var spawners: Array = world.map.get("spawners", []) if world.map.get("spawners") is Array else []
	for s in spawners:
		var d: Dictionary = s
		var sid := StringName(str(d.get("species_id")))
		var sp: Dictionary = world.content.get_species(sid)
		var tier: int = ContentDB.SPECIES_TIERS.find(str(sp.get("tier", "")))
		var excluded: bool = sp.get("schooling") == true or tier == SimWorld.TIER_AMBIENT
		st.targets.append(0 if excluded else maxi(1, roundi(float(d.get("count", 1)) * scale)))
		st.tier.append(-1 if excluded else tier)
		var respawn_s: float = float(d.get("respawn_s", 0.0))
		st.respawn_ticks.append(maxi(1, roundi(respawn_s * SimWorld.TICK_RATE)) if respawn_s > 0.0 else 0)
		st.species.append(sid)
		st.zone.append(zone_ids.find(str(d.get("zone_id"))))
		var group: Dictionary = d.get("group", {}) if d.get("group") is Dictionary else {}
		st.group_min.append(maxi(int(group.get("min", 1)), 1))
		st.group_max.append(maxi(int(group.get("max", 1)), 1))
		st.group_chance.append(float(group.get("chance", 0.0)))
		st.group_radius.append(float(group.get("radius_m", 0.0)))
		var ids: Array[int] = []
		var due: Array[int] = []
		var due_pack: Array[int] = []
		st.alive.append(ids)
		st.pending.append(due)
		st.pending_pack.append(due_pack)
	for tier: int in caps:
		var cap: int = caps[tier]
		var group := PackedInt32Array()  # indices of the spawners of this tier
		var total: int = 0
		for i in st.targets.size():
			if st.tier[i] == tier:
				group.append(i)
				total += st.targets[i]
		if cap < 0 or total <= cap:
			continue
		var sub := PackedInt32Array()
		for i in group:
			sub.append(st.targets[i])
		sub = _capped(sub, total, cap)
		for k in group.size():
			st.targets[group[k]] = sub[k]
	for i in st.targets.size():
		var left: int = st.targets[i]
		while left > 0:
			var n: int = 1
			if st.group_max[i] > 1 and world.rng.next_float() < st.group_chance[i]:
				n = mini(world.rng.range_int(st.group_min[i], st.group_max[i]), left)
			var p: int = st.pack_spawner.size()
			var members: Array[int] = []
			st.pack_spawner.append(i)
			st.pack_members.append(members)
			for k in n:
				_spawn_for(world, st, i, p)
			left -= n


# Spawns one NPC for spawner `i` into pack `p`: next to the pack leader when the pack has a living member, else at a
# world-RNG position inside the zone.
static func _spawn_for(world: SimWorld, st: _State, i: int, p: int) -> void:
	var zi: int = st.zone[i]
	var sp: Dictionary = world.content.get_species(st.species[i])
	if zi < 0 or sp.is_empty():
		return
	var zone: Dictionary = (world.map["zones"] as Array)[zi]
	var aabb: Dictionary = zone.get("aabb", {})
	var lo := Vector3(float(aabb["min"][0]), float(aabb["min"][1]), float(aabb["min"][2]))
	var hi := Vector3(float(aabb["max"][0]), float(aabb["max"][1]), float(aabb["max"][2]))
	var lengths: Dictionary = sp.get("length_m", {})
	var length_m: float = world.rng.range_float(float(lengths.get("min", 0.1)), float(lengths.get("max", 0.1)))
	var behaviour: Dictionary = sp.get("behaviour", {}) if sp.get("behaviour") is Dictionary else {}
	var clearance: float = float(behaviour.get("seabed_clearance_m", 0.0))
	var band: int = SimRules.band_for_length(length_m, _bands(world.content))
	var radius: float = length_m * float(world.content.get_band(band).get("collision_radius_mult", 0.0))
	var min_d: float = st.min_player_d
	var players := PackedVector3Array()
	if min_d > 0.0:
		world.player_positions_into(players)
	var leader: SimEntity = _leader(world, st, p)
	var r: float = st.group_radius[i]
	var pos := Vector3.ZERO
	for attempt in _SPAWN_TRIES:
		var x: float
		var z: float
		var y: float
		var ok: bool
		if leader != null:
			var c: Vector3 = leader.position
			x = clampf(world.rng.range_float(c.x - r, c.x + r), lo.x, hi.x)
			z = clampf(world.rng.range_float(c.z - r, c.z + r), lo.z, hi.z)
			var y_lo: float = lo.y
			if world.seabed != null:
				y_lo = maxf(y_lo, world.seabed.height_at(x, z) + clearance)
			var y_hi: float = minf(hi.y, -clearance)
			y = clampf(c.y + world.rng.range_float(-0.5 * r, 0.5 * r), y_lo, y_hi)
			ok = y_hi > y_lo
		else:
			x = world.rng.range_float(lo.x, hi.x)
			z = world.rng.range_float(lo.z, hi.z)
			var y_lo: float = lo.y
			if world.seabed != null:
				y_lo = maxf(y_lo, world.seabed.height_at(x, z) + clearance)
			var y_hi: float = minf(hi.y, -clearance)
			y = world.rng.range_float(y_lo, y_hi) if y_hi > y_lo else y_lo
			ok = y_hi > y_lo
		pos = Vector3(x, y, z)
		if world.seabed != null:
			var q: Vector3 = world.seabed.resolve(pos, radius)
			ok = ok and q.distance_squared_to(pos) < 1e-8
			pos = q
		for pp in players:
			ok = ok and pp.distance_squared_to(pos) >= min_d * min_d
		if ok:
			break
	var heading: Vector3 = leader.heading if leader != null else Vector3.ZERO
	if leader == null:
		var a: float = world.rng.range_float(-PI, PI)
		heading = Vector3(-sin(a), 0.0, -cos(a))
	var id: int = spawn_npc(world, st.species[i], pos, length_m, heading)
	(st.alive[i] as Array[int]).append(id)
	(st.pack_members[p] as Array[int]).append(id)
	st.pack_of[id] = p
	st.home[id] = zi


# First living member of pack `p` (lowest id), or null.
static func _leader(world: SimWorld, st: _State, p: int) -> SimEntity:
	for id: int in (st.pack_members[p] as Array[int]):
		var e: SimEntity = world.get_entity(id)
		if e != null and e.alive:
			return e
	return null


# A due member respawn of pack `p` waits while its leader is closer than min_player_distance_m to a living player.
static func _pack_waits(world: SimWorld, st: _State, p: int) -> bool:
	if st.min_player_d <= 0.0:
		return false
	var leader: SimEntity = _leader(world, st, p)
	if leader == null:
		return false
	var players := PackedVector3Array()
	world.player_positions_into(players)
	for pp in players:
		if pp.distance_squared_to(leader.position) < st.min_player_d * st.min_player_d:
			return true
	return false


# `targets` (summing to `total` > cap) scaled to the cap (see the class doc).
static func _capped(targets: PackedInt32Array, total: int, cap: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var rem := PackedFloat64Array()
	var sum: int = 0
	for n in targets:
		var exact: float = float(n) * float(cap) / float(total)
		var m: int = maxi(1, floori(exact))
		out.append(m)
		rem.append(exact - float(m))
		sum += m
	while sum > cap:
		var big: int = 0
		for i in out.size():
			if out[i] > out[big]:
				big = i
		if out[big] <= 0:
			break
		out[big] -= 1
		sum -= 1
	while sum < cap:
		var best: int = -1
		for i in out.size():
			if out[i] < targets[i] and (best < 0 or rem[i] > rem[best]):
				best = i
		if best < 0:
			break
		out[best] += 1
		rem[best] -= 1.0
		sum += 1
	return out


static func _bands(content: ContentDB) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(1, content.band_count() + 1):
		out.append(content.get_band(i))
	return out
