class_name NpcViews
extends Node3D
## Presentation of every non-player sim entity (interactive and large tiers, food bits; the ambient school form is
## AmbientRenderer). Reads SimWorld state only, never writes it.
##
## On every GameLoop.ticked it diffs world.entity_ids(), creates a view record per new creature / food bit, drops
## the records of entities that are gone and snapshots the previous and current tick state; _process interpolates
## with SimWorld.interpolation_alpha() like PlayerView. A new creature's previous state is extrapolated back one
## tick from its velocity, so a promoted school member keeps moving from its slot without a hitch.
## - Interactive creatures (CLAUDE.md rules 4/10): one MultiMeshInstance3D per species (CrowdAssets crowd mesh,
##   blend shapes baked at mid growth, `interactive` crowd material), all instances written in bulk every frame via
##   MultiMesh.buffer (transform + INSTANCE_CUSTOM (phase, tint, 0, 0)), visible_instance_count = live count,
##   capacity doubles on demand. Promoted school members use the phase/tint of their ambient instance
##   (AmbientRenderer.member_phase_tint) and inherit a running grow-in (AmbientRenderer.handoff_grow_start).
## - Large actors (species tier `large`, <= rules tiers.large_cap) and species with an `inflated` blend shape
##   (puffer: per-instance blend weight, MultiMesh cannot do that; few of them) are one GLB node each with the
##   species swim material, node scale = length_m, juvenile/adult blend from the length inside the species range;
##   puffer `inflated` follows inflated_until_tick (blend shape only, no node scale: S7a recommendation).
## - Plankton entities (DemoFx only; the map plankton is a density field drawn by AmbientRenderer) use the swarm
##   cell mesh scaled up so its 1-2 cm critters match the sim length. Food bits: small glowing low-poly spheres in
##   the accent colour of the creature they came from, shrinking during their last seconds.
## FeedbackFx: take_view(id) hands over the node of a dying node view, or a pooled ghost model at the interpolated
## pose of a dying MultiMesh fish (the X-ray flash); FeedbackFx returns it with release_view() when done.

const SPECIES_TIER_LARGE: String = "large"
## Swarm cell (0.12 m, critters 1-2 cm) per metre of plankton sim length.
const SWARM_CELL_PER_LENGTH: float = 8.0
## Food bit visual diameter: fraction of the source creature length, at least FOOD_BIT_MIN_M.
const FOOD_BIT_FRAC: float = 0.12
const FOOD_BIT_MIN_M: float = 0.025
## Food bits shrink away over their last seconds of lifetime.
const FOOD_BIT_FADE_S: float = 2.0
const FOOD_BIT_SPIN: float = 2.5
const FOOD_BIT_FALLBACK_COLOR: Color = Color(1.0, 0.89, 0.54)
## Puffer inflate/deflate smoothing rate, 1/s (fast pop).
const INFLATE_RATE: float = 14.0
## swim_phase spacing between consecutive entity ids (radians); crowd phase = fract(id x PHASE_STEP / TAU).
const PHASE_STEP: float = 2.1
const SALT_TINT: int = 104
const CROWD_INITIAL_CAPACITY: int = 32
const CROWD_CULL_MARGIN_M: float = 1.0
const STRIDE: int = 16  # floats per instance: 12 transform + 4 custom
## Pooled ghost models per species (X-ray flash of MultiMesh fish).
const GHOST_POOL: int = 4

enum _Kind { CROWD, NODE, BIT }

## Presentation time of the last frame (tick handlers + _process), microseconds.
var last_usec: int = 0

var _world: SimWorld
var _player_id: int = 0
var _assets: CrowdAssets
var _ambient: AmbientRenderer = null
var _views: Dictionary[int, _View] = {}
var _crowds: Dictionary[StringName, int] = {}  # species -> index into _crowd_list
var _crowd_list: Array[_Crowd] = []
var _nodes: Array[_View] = []  # node and food bit views, rebuilt every tick
var _node_species: Dictionary[StringName, bool] = {}
var _ghosts: Dictionary[StringName, Array] = {}
var _bit_materials: Dictionary[StringName, StandardMaterial3D] = {}
var _bit_mesh: SphereMesh
var _bit_source: Dictionary[int, StringName] = {}  # food bit id -> species of the creature it came from
var _event_tick: int = 0
var _gen: int = 0
var _pending_usec: int = 0
var _large_nodes: int = 0
var _bits: int = 0


class _View:
	extends RefCounted
	var kind: int = 0
	var species_id: StringName = &""
	var node: Node3D = null
	var mesh: MeshInstance3D = null
	var crowd: int = -1  # index into _crowd_list (no back-reference: _Crowd.list holds the views)
	var large: bool = false
	var base_scale: float = 1.0
	var phase: float = 0.0
	var tint: float = 0.0
	var grow_start: int = -1
	var prev_pos: Vector3
	var cur_pos: Vector3
	var prev_yaw: float = 0.0
	var cur_yaw: float = 0.0
	var prev_pitch: float = 0.0
	var cur_pitch: float = 0.0
	var inflate_idx: int = -1
	var inflate_w: float = 0.0
	var inflated: bool = false
	var expire_tick: int = -1
	var seen: int = 0


class _Crowd:
	extends RefCounted
	var mmi: MultiMeshInstance3D
	var mm: MultiMesh
	var buf: PackedFloat32Array = PackedFloat32Array()
	var capacity: int = 0
	var last_count: int = 0
	var list: Array[_View] = []


## Binds to the loop's world; the player (`player_id`) is drawn by PlayerView, not here. `assets` is shared with
## AmbientRenderer (created here when null); `ambient` (optional) provides the promotion hand-over values and must
## be set up (connected to `ticked`) before this.
func setup(loop: GameLoop, player_id: int, assets: CrowdAssets = null, ambient: AmbientRenderer = null) -> void:
	_world = loop.world
	_player_id = player_id
	_assets = assets if assets != null else CrowdAssets.create(_world.content)
	_ambient = ambient
	_event_tick = _world.tick
	_bit_mesh = SphereMesh.new()
	_bit_mesh.radius = 0.5
	_bit_mesh.height = 1.0
	_bit_mesh.radial_segments = 6
	_bit_mesh.rings = 3
	if _world.content != null:
		for sid: StringName in _world.content.species_ids():
			var rec: Dictionary = _world.content.get_species(sid)
			_node_species[sid] = str(rec.get("tier", "")) == SPECIES_TIER_LARGE or _assets.has_inflate(sid)
	_sync(_world.tick)
	loop.ticked.connect(_sync)
	_process(0.0)


## Body / belly / accent colours of a species from the palette atlas ([] when unknown).
func species_colors(species_id: StringName) -> PackedColorArray:
	return _assets.species_colors(species_id)


## A fresh instance of the species model with its swim material (null when the species has no model).
func instantiate_model(species_id: StringName) -> Node3D:
	return _assets.instantiate_model(species_id)


## Hands a node showing entity `id` over to the caller (FeedbackFx, kill flash), or null when there is no view.
## Node views: the view node itself (no longer updated here). MultiMesh views: a pooled ghost model at the fish's
## interpolated pose (the instance disappears with the entity). Return it with release_view().
func take_view(id: int) -> Node3D:
	var v: _View = _views.get(id, null)
	if v == null:
		return null
	_views.erase(id)
	if v.kind != _Kind.CROWD:
		_nodes.erase(v)
		if v.large:
			_large_nodes -= 1
		elif v.kind == _Kind.BIT:
			_bits -= 1
		return v.node
	_crowd_list[v.crowd].list.erase(v)
	var ghost: Node3D = _take_ghost(v.species_id)
	if ghost != null:
		var a: float = _world.interpolation_alpha()
		var basis := Basis.from_euler(Vector3(lerpf(v.prev_pitch, v.cur_pitch, a), lerp_angle(v.prev_yaw, v.cur_yaw, a), 0.0))
		ghost.transform = Transform3D(basis.scaled(Vector3.ONE * v.base_scale), v.prev_pos.lerp(v.cur_pos, a))
	return ghost


## The live view node of entity `id` (node views: large actors, puffers, food bits), null for MultiMesh fish or when
## there is no view. Read-only for callers except a transform tweak applied after this node's _process (BossFx).
func view_node(id: int) -> Node3D:
	var v: _View = _views.get(id, null)
	return v.node if v != null and v.kind == _Kind.NODE else null


## Takes back a node from take_view() or instantiate_model(): pooled ghosts are hidden for reuse, others freed.
func release_view(node: Node3D) -> void:
	if node == null:
		return
	var sid: StringName = node.get_meta(&"ghost_species", &"")
	var pool: Array = _ghosts.get(sid, [])
	if sid != &"" and pool.size() < GHOST_POOL and node.get_parent() == self:
		node.visible = false
		pool.append(node)
		_ghosts[sid] = pool
	else:
		node.queue_free()


## Counters for benches and the debug overlay (see the S4 result section for the meaning of each key).
func bench_stats() -> Dictionary:
	var interactive: int = 0
	for c: _Crowd in _crowd_list:
		interactive += c.list.size()
	return {
		"interactive_instances": interactive,
		"interactive_multimeshes": _crowd_list.size(),
		"node_views": _nodes.size() - _bits,
		"large_nodes": _large_nodes,
		"food_bits": _bits,
		"npc_views_usec": last_usec,
	}


func _process(delta: float) -> void:
	if _world == null:
		return
	var t0: int = Time.get_ticks_usec()
	var a: float = _world.interpolation_alpha()
	var now: float = float(_world.tick) + a
	for c: _Crowd in _crowd_list:
		_write_crowd(c, a, now)
	var k_inflate: float = 1.0 - exp(-INFLATE_RATE * delta)
	for v: _View in _nodes:
		v.node.position = v.prev_pos.lerp(v.cur_pos, a)
		if v.kind == _Kind.BIT:
			v.node.rotate_y(FOOD_BIT_SPIN * delta)
			var left_s: float = (float(v.expire_tick) - now) * SimWorld.TICK_DT
			v.node.scale = Vector3.ONE * v.base_scale * clampf(left_s / FOOD_BIT_FADE_S, 0.05, 1.0)
			continue
		var yaw: float = lerp_angle(v.prev_yaw, v.cur_yaw, a)
		var pitch: float = lerpf(v.prev_pitch, v.cur_pitch, a)
		v.node.quaternion = Quaternion.from_euler(Vector3(pitch, yaw, 0.0))
		if v.inflate_idx >= 0:
			v.inflate_w = lerpf(v.inflate_w, 1.0 if v.inflated else 0.0, k_inflate)
			v.mesh.set_blend_shape_value(v.inflate_idx, v.inflate_w)
	last_usec = _pending_usec + Time.get_ticks_usec() - t0
	_pending_usec = 0


# All instances of one species crowd in one buffer write.
func _write_crowd(c: _Crowd, a: float, now: float) -> void:
	var n: int = c.list.size()
	if n == 0 and c.last_count == 0:
		return
	if n > c.capacity:
		var cap: int = c.capacity
		while cap < n:
			cap *= 2
		c.capacity = cap
		c.mm.instance_count = cap
		c.buf.resize(cap * STRIDE)
	var buf: PackedFloat32Array = c.buf
	c.buf = PackedFloat32Array()  # drop the second reference: writes below must not copy the array
	var o: int = 0
	for v: _View in c.list:
		var s: float = v.base_scale
		if v.grow_start >= 0:
			var f: float = (now - float(v.grow_start)) / AmbientRenderer.GROW_TICKS
			if f >= 1.0:
				v.grow_start = -1
			else:
				s *= maxf(f, AmbientRenderer.GROW_MIN)
		var p: Vector3 = v.prev_pos.lerp(v.cur_pos, a)
		var b: Basis = Basis.from_euler(Vector3(lerpf(v.prev_pitch, v.cur_pitch, a), lerp_angle(v.prev_yaw, v.cur_yaw, a), 0.0)) * s
		buf[o] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = p.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = p.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = p.z
		buf[o + 12] = v.phase
		buf[o + 13] = v.tint
		buf[o + 14] = 0.0
		buf[o + 15] = 0.0
		o += STRIDE
	c.mm.buffer = buf
	c.mm.visible_instance_count = n
	c.last_count = n
	c.buf = buf


# Per tick: food-bit sources from FOOD_SPAWNED, then the view diff and the state snapshot.
func _sync(_tick: int) -> void:
	var t0: int = Time.get_ticks_usec()
	# DIED (data.species) comes before the FOOD_SPAWNED events of the same remains
	var died: Dictionary[int, StringName] = {}
	for ev: SimEvent in _world.events_since(_event_tick):
		if ev.type == SimEvent.Type.DIED:
			died[ev.entity_id] = StringName(ev.data.get("species", &""))
		elif ev.type == SimEvent.Type.FOOD_SPAWNED:
			_bit_source[ev.entity_id] = died.get(ev.other_id, &"")
	_event_tick = _world.tick
	_gen += 1
	for c: _Crowd in _crowd_list:
		c.list.clear()
	_nodes.clear()
	var seen: int = 0
	for id: int in _world.entity_ids():
		if id == _player_id:
			continue
		var e: SimEntity = _world.get_entity(id)
		var v: _View = _views.get(id, null)
		if v == null:
			v = _create(e)
			if v == null:
				continue
			_views[id] = v
		v.seen = _gen
		seen += 1
		_snapshot(v, e)
		if v.kind == _Kind.CROWD:
			_crowd_list[v.crowd].list.append(v)
		else:
			_nodes.append(v)
	if seen != _views.size():
		for id: int in _views.keys():
			var v: _View = _views[id]
			if v.seen != _gen:
				_views.erase(id)
				_bit_source.erase(id)
				if v.large:
					_large_nodes -= 1
				elif v.kind == _Kind.BIT:
					_bits -= 1
				if v.node != null:
					v.node.queue_free()
	_pending_usec += Time.get_ticks_usec() - t0


func _snapshot(v: _View, e: SimEntity) -> void:
	v.prev_pos = v.cur_pos
	v.prev_yaw = v.cur_yaw
	v.prev_pitch = v.cur_pitch
	v.cur_pos = e.position
	v.cur_yaw = deg_to_rad(e.yaw_deg)
	v.cur_pitch = deg_to_rad(e.pitch_deg)
	v.inflated = _world.tick < e.inflated_until_tick


func _create(e: SimEntity) -> _View:
	var v := _View.new()
	v.species_id = e.species_id
	if e.kind == SimEntity.Kind.FOOD_BIT:
		v.kind = _Kind.BIT
		v.expire_tick = e.expire_tick
		var mi := MeshInstance3D.new()
		mi.mesh = _bit_mesh
		mi.material_override = _bit_material(_bit_source.get(e.id, &""))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		v.node = mi
		v.base_scale = maxf(e.source_length_m * FOOD_BIT_FRAC, FOOD_BIT_MIN_M)
		_bits += 1
	elif not _assets.has_model(e.species_id):
		return null
	elif _node_species.get(e.species_id, false):
		v.kind = _Kind.NODE
		v.node = _assets.instantiate_model(e.species_id)
		v.mesh = CrowdAssets.find_mesh(v.node)
		v.base_scale = e.length_m
		v.large = not _assets.has_inflate(e.species_id)
		if v.large:
			_large_nodes += 1
		if v.mesh != null:
			v.mesh.set_instance_shader_parameter(&"swim_phase", PHASE_STEP * float(e.id))
			CrowdAssets.set_growth(v.mesh, _growth(e))
			v.inflate_idx = v.mesh.find_blend_shape_by_name(&"inflated")
	else:
		v.kind = _Kind.CROWD
		v.crowd = _crowd_for(e.species_id)
		v.base_scale = e.length_m * (SWARM_CELL_PER_LENGTH if _assets.is_swarm(e.species_id) else 1.0)
		var sc: SchoolSystem.School = _world.schools.get_school(e.school_id) if _world.schools != null and e.school_id >= 0 else null
		if sc != null:
			var pt: Vector2 = AmbientRenderer.member_phase_tint(sc.seed, e.school_member)
			v.phase = pt.x
			v.tint = pt.y
			if _ambient != null:
				v.grow_start = _ambient.handoff_grow_start(e.school_id, e.school_member)
		else:
			v.phase = fposmod(PHASE_STEP * float(e.id) / TAU, 1.0)
			v.tint = SchoolSystem.hash01(e.id, 0, SALT_TINT) * 2.0 - 1.0
	v.cur_pos = e.position
	v.cur_yaw = deg_to_rad(e.yaw_deg)
	v.cur_pitch = deg_to_rad(e.pitch_deg)
	# one tick back along the velocity: the first interpolated frame continues the motion it was spawned with
	v.prev_pos = e.position - e.velocity * SimWorld.TICK_DT
	v.prev_yaw = v.cur_yaw
	v.prev_pitch = v.cur_pitch
	if v.node != null:
		v.node.set_meta(&"species", e.species_id)
		v.node.scale = Vector3.ONE * v.base_scale
		v.node.position = e.position
		add_child(v.node)
	return v


func _crowd_for(sid: StringName) -> int:
	if _crowds.has(sid):
		return _crowds[sid]
	var c := _Crowd.new()
	c.mm = MultiMesh.new()
	c.mm.transform_format = MultiMesh.TRANSFORM_3D
	c.mm.use_custom_data = true  # before instance_count
	c.mm.mesh = _assets.crowd_mesh(sid)
	c.capacity = CROWD_INITIAL_CAPACITY
	c.mm.instance_count = c.capacity
	c.mm.visible_instance_count = 0
	c.buf.resize(c.capacity * STRIDE)
	c.mmi = MultiMeshInstance3D.new()
	c.mmi.multimesh = c.mm
	c.mmi.material_override = _assets.crowd_material(sid, false)
	c.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	c.mmi.extra_cull_margin = CROWD_CULL_MARGIN_M
	add_child(c.mmi)
	_crowds[sid] = _crowd_list.size()
	_crowd_list.append(c)
	return _crowds[sid]


# A hidden pooled ghost model of `sid` (or a new one), with the crowd mesh growth and the swim material.
func _take_ghost(sid: StringName) -> Node3D:
	var pool: Array = _ghosts.get(sid, [])
	var ghost: Node3D = pool.pop_back() if not pool.is_empty() else null
	if ghost == null:
		ghost = _assets.instantiate_model(sid)
		if ghost == null:
			return null
		ghost.set_meta(&"ghost_species", sid)
		var mesh: MeshInstance3D = CrowdAssets.find_mesh(ghost)
		if mesh != null:
			CrowdAssets.set_growth(mesh, CrowdAssets.CROWD_GROWTH)
		add_child(ghost)
	else:
		var mesh: MeshInstance3D = CrowdAssets.find_mesh(ghost)
		if mesh != null:
			mesh.material_override = _assets.material(sid)
	ghost.visible = true
	return ghost


# Juvenile -> adult weight from the length inside the species length range (0 when the range is empty).
func _growth(e: SimEntity) -> float:
	var rec: Dictionary = _world.content.get_species(e.species_id) if _world.content != null else {}
	var lr: Dictionary = rec.get("length_m", {}) if rec.get("length_m") is Dictionary else {}
	var lo: float = float(lr.get("min", e.length_m))
	var hi: float = float(lr.get("max", e.length_m))
	return clampf((e.length_m - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 1.0


# One shared glowing material per source species (accent swatch).
func _bit_material(source: StringName) -> StandardMaterial3D:
	var mat: StandardMaterial3D = _bit_materials.get(source, null)
	if mat != null:
		return mat
	var colors: PackedColorArray = species_colors(source)
	var c: Color = colors[2] if colors.size() > 2 else FOOD_BIT_FALLBACK_COLOR
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 2.0
	_bit_materials[source] = mat
	return mat
