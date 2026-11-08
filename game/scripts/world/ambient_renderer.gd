class_name AmbientRenderer
extends Node3D
## Ambient tier presentation (CLAUDE.md rules 4 and 10): school members in the school form and plankton swarms.
## Reads SimWorld.schools / SimWorld.plankton / SimWorld.krill and the school events; never writes the sim.
##
## Schools: every member in the school form (School.alive[k] == 1) is one MultiMesh instance of the species crowd
## mesh (CrowdAssets, opaque, no shadows, no physics) with INSTANCE_CUSTOM = (swim phase, tint, wobble a_k / TAU,
## wobble b_k / TAU); fish_swim.gdshader adds the SchoolSystem wobble on the GPU from `school_time`, so the CPU
## moves only one frame per school. Two layouts (user arg `-- --ambient-mode=school|chunk`, default school,
## timings in the S4 result section of tasks/stage-S4-living-ocean.md):
## - `school` (default): one MultiMeshInstance3D per school; instance transforms are the static member slots
##   (scale = member length), the node follows the interpolated school centre and yaw. Per-school frustum culling
##   and visibility_range_end. Changes per event only (set_instance_* on one slot).
## - `chunk`: one MultiMeshInstance3D per 64 m column chunk per species; every frame each school near the camera is
##   bucketed by its centre and its members are written in bulk via MultiMesh.buffer (world-space transforms).
## Removals swap the last visible instance into the freed slot and shrink visible_instance_count.
##
## Time base (matches NpcViews / PlayerView interpolation): after the step of tick S (world.tick = S + 1) an
## entity's state is "at S"; a promoted member is spawned at member_position(S). So the school frame is drawn at
## tau = world.tick - 2 + interpolation_alpha (centres cached per tick: prev = centre(S - 1), cur = centre(S)), and
## `school_time` = tau x TICK_DT. On SCHOOL_MEMBER_PROMOTED the instance is hidden in the same `ticked` handler in
## which NpcViews shows the entity at the member slot (connect this renderer before NpcViews). DEMOTED shows it
## again; RESPAWNED shows it with a short grow-in (GROW_TICKS); a member promoted while growing (or culled by the
## low tier) hands its grow-in over to the interactive view (handoff_grow_start).
## Quality: `low` draws only members k < ceil(size x quality.low.ambient_density_mult), shorter visibility range,
## smaller plankton swarms.
##
## Plankton: one MultiMesh of swarm clusters (plankton swarm-cell mesh) in the (2r + 1)^3 density cells around the
## camera; a cell shows ceil(per_cell x density / density_max) clusters while density / density_max > SWARM_THRESHOLD,
## so grazing visibly thins it. Rebuilt when the camera enters another cell, or (at most every SWARM_REBUILD_TICKS)
## after PLANKTON_EATEN events. Cluster spots are seeded per cell (SchoolSystem.hash01), kept above the seabed, and
## cached per cell while the cell stays around the camera (a rebuild copies slices, no per-instance math).
## Patchy fields (map plankton.variation) show fewer clusters in poor cells and none in empty ones by the same rule
## (density <= cell cap <= density_max). feat-plankton-visibility: clusters x2 in size and count per cell (both tiers).
##
## Krill clouds (SimWorld.krill, one KrillField per map `krill` entry): one MultiMesh per field with its 1-critter
## species model and material (CrowdAssets.MATERIALS: shallows / open without glow, abyss glow pulse). One instance =
## one krill: in the cells within KRILL_RADIUS (x, z) / KRILL_RADIUS_Y_CELLS (y) of the camera cell (clipped to the
## field grid) every ALIVE critter (KrillField.alive_mask) is drawn at its KrillField.critter_layout base position
## with INSTANCE_CUSTOM = (phase, tint, weave phase, drift phase) and a uniform scale = its length (KRILL_SCALE_*,
## hashed); the shader moves and turns it (fish_swim.gdshader `krill` uniforms, copied from the field; `school_time` = the sim time of the frame).
## A krill PLANKTON_EATEN (data.cell, data.k) hides that one instance at once (swap with the last); regrown krill
## appear on the next rebuild (camera cell change, or every KRILL_REFRESH_TICKS while a drawn cell misses krill).
## Low tier: fewer cells and only critters k < ceil(count x KRILL_SHOW_FRAC_LOW) per cell.

const MODE_SCHOOL: int = 0
const MODE_CHUNK: int = 1
const MODE_ARG: String = "--ambient-mode="
const CHUNK_M: float = 64.0
## Visibility range of a school (m from the camera; exponential fog 0.025/m leaves ~10% at 90 m).
const VIS_RANGE_HIGH_M: float = 90.0
const VIS_RANGE_LOW_M: float = 55.0
## Schools farther than the range + this margin are not moved this frame (they are culled anyway).
const UPDATE_MARGIN_M: float = 20.0
## Extra cull margin of the crowd nodes (wobble + swim deformation reach outside the instance AABB).
const CULL_MARGIN_M: float = 1.0
## Grow-in of a respawned member, ticks (0.5 s); start scale GROW_MIN.
const GROW_TICKS: float = 15.0
const GROW_MIN: float = 0.05
## Per-member hash salts (presentation only, SchoolSystem.hash01).
const SALT_PHASE: int = 101
const SALT_TINT: int = 102
const SALT_SWARM: int = 103
const CHUNK_INITIAL_CAPACITY: int = 64
const STRIDE: int = 16  # floats per instance: 12 transform + 4 custom
## Plankton swarms.
const SWARM_THRESHOLD: float = 0.15
const SWARM_RADIUS_CELLS_HIGH: int = 2
const SWARM_RADIUS_CELLS_LOW: int = 1
const SWARM_PER_CELL_HIGH: int = 12
const SWARM_PER_CELL_LOW: int = 6
const SWARM_SCALE_MIN_M: float = 0.3
const SWARM_SCALE_MAX_M: float = 0.56
const SWARM_REBUILD_TICKS: int = 10
const SWARM_SEABED_CLEARANCE_M: float = 0.3
const SWARM_SURFACE_CLEARANCE_M: float = 0.3
## Krill (cells of map krill cell_m; one instance per krill, scale = critter length: the size one krill had in the old
## 4-critter clusters).
const KRILL_RADIUS_CELLS_HIGH: int = 4
const KRILL_RADIUS_CELLS_LOW: int = 3
## Vertical cell radius of the krill around the camera (krill far above / below barely shows; caps the deep abyss).
const KRILL_RADIUS_Y_CELLS: int = 2
const KRILL_SHOW_FRAC_LOW: float = 0.5
const KRILL_SCALE_MIN_M: float = 0.15
const KRILL_SCALE_MAX_M: float = 0.28
const KRILL_REFRESH_TICKS: int = 60
const SALT_KRILL: int = 104

var mode: int = MODE_SCHOOL
var quality_tier: StringName = QualitySettings.HIGH
var density_mult: float = 1.0
var vis_range_m: float = VIS_RANGE_HIGH_M
## Presentation time of the last frame (tick handlers + _process), microseconds.
var last_usec: int = 0

var _world: SimWorld
var _schools: SchoolSystem
var _assets: CrowdAssets
var _by_id: Array[_SchoolView] = []  # school id -> view (null: species without a model)
var _views: Array[_SchoolView] = []
var _species: Array[StringName] = []
var _species_mesh: Array[ArrayMesh] = []
var _species_mat: Array[ShaderMaterial] = []
var _buckets: Dictionary[int, _Bucket] = {}
var _bucket_list: Array[_Bucket] = []
var _growing: Dictionary[int, int] = {}  # school id << 16 | k -> start tick
var _event_tick: int = 0
var _pending_usec: int = 0
var _in_range: int = 0
var _shown: int = 0
# plankton + krill swarms
var _swarms: Array[_Swarm] = []
var _swarm_of_field: Array[_Swarm] = []  # PLANKTON_EATEN data.field -> swarm (null: field not drawn)


class _SchoolView:
	extends RefCounted
	var sc: SchoolSystem.School
	var species_index: int = 0
	var mmi: MultiMeshInstance3D = null  # school mode
	var mm: MultiMesh = null
	var limit: int = 0  # members k < limit are drawn (low tier culling)
	var count: int = 0  # visible instances
	var slot_of: PackedInt32Array = PackedInt32Array()  # k -> instance slot, -1 = hidden
	var k_of: PackedInt32Array = PackedInt32Array()  # slot -> k
	var scale: PackedFloat32Array = PackedFloat32Array()  # grow-in factor per k
	var slots: PackedVector3Array = PackedVector3Array()
	var lengths: PackedFloat32Array = PackedFloat32Array()
	var custom: PackedColorArray = PackedColorArray()
	var prev_c: Vector3 = Vector3.ZERO
	var cur_c: Vector3 = Vector3.ZERO
	var next_c: Vector3 = Vector3.ZERO
	var prev_yaw: float = 0.0
	var cur_yaw: float = 0.0


## Swarm clusters of one density field (plankton), or the krill of a krill cloud (kf != null).
class _Swarm:
	extends RefCounted
	var field: PlanktonField
	var kf: KrillField = null
	var krill: bool = false
	var mm: MultiMesh = null
	var capacity: int = 0  # MultiMesh instance_count of the swarm
	var radius: int = 0
	var per_cell: int = 0
	var scale_min: float = 0.0
	var scale_max: float = 0.0
	var salt: int = 0
	var lo: Vector3i = Vector3i.ZERO  # world cell range of the field grid (hi exclusive)
	var hi: Vector3i = Vector3i.ZERO
	var cell: Vector3i = Vector3i(-999999, 0, 0)
	var dirty: bool = false
	var built_tick: int = -999999
	var count: int = 0
	var floors: Dictionary[int, float] = {}  # column (ix, iz) -> seabed height at the cell centre
	var spots: Dictionary[int, PackedFloat32Array] = {}  # field cell -> its per_cell cluster instances (krill: critters)
	# krill only
	var mat: ShaderMaterial = null
	var buf: PackedFloat32Array = PackedFloat32Array()  # CPU copy of the uploaded instances
	var keys: PackedInt64Array = PackedInt64Array()  # slot -> critter key (KrillField.KEY_STRIDE)
	var show_frac: float = 1.0
	var partial: bool = false  # a drawn cell misses krill (regrowth needs a refresh)


class _Bucket:
	extends RefCounted
	var mmi: MultiMeshInstance3D
	var mm: MultiMesh
	var buf: PackedFloat32Array = PackedFloat32Array()
	var capacity: int = 0
	var count: int = 0
	var last_count: int = 0
	var origin: Vector3 = Vector3.ZERO


## Binds to the loop's world. `tier` = QualitySettings.tier(). Connect before NpcViews (see the class doc).
func setup(loop: GameLoop, assets: CrowdAssets, tier: StringName) -> void:
	_world = loop.world
	_schools = _world.schools
	_assets = assets
	quality_tier = tier
	density_mult = QualitySettings.ambient_density_mult(_world.content, tier)
	vis_range_m = VIS_RANGE_LOW_M if tier == QualitySettings.LOW else VIS_RANGE_HIGH_M
	mode = _mode_arg()
	_event_tick = _world.tick
	if _schools != null:
		_by_id.resize(_schools.school_count())
		for id in _schools.school_count():
			_add_school(_schools.get_school(id))
	_init_swarm()
	loop.ticked.connect(_on_ticked)
	_process(0.0)


## Swim phase (x, 0..1) and tint (y, -1..1) of school member k (INSTANCE_CUSTOM.x/.y; NpcViews uses the same values
## for a promoted member so its tail beat and shade continue).
static func member_phase_tint(school_seed: int, k: int) -> Vector2:
	return Vector2(SchoolSystem.hash01(school_seed, k, SALT_PHASE), SchoolSystem.hash01(school_seed, k, SALT_TINT) * 2.0 - 1.0)


## Grow-in start tick an interactive view should use for promoted member k of school `school_id`: the running
## grow-in of a just-respawned member, `world.tick` for a member the low tier does not draw (it would pop in), else -1.
func handoff_grow_start(school_id: int, k: int) -> int:
	var key: int = (school_id << 16) | k
	if _growing.has(key):
		return _growing[key]
	var sv: _SchoolView = _by_id[school_id] if school_id >= 0 and school_id < _by_id.size() else null
	if sv != null and k >= sv.limit:
		return _world.tick
	return -1


## Counters for benches and the debug overlay (see the S4 result section for the meaning of each key;
## plankton_instances = the plankton field only, krill_instances = all krill fields, plankton_multimeshes = every
## swarm MultiMesh, plankton and krill).
func bench_stats() -> Dictionary:
	var mms: int = _views.size() if mode == MODE_SCHOOL else _bucket_list.size()
	var plankton_count: int = 0
	var krill_count: int = 0
	for sw: _Swarm in _swarms:
		if sw.krill:
			krill_count += sw.count
		else:
			plankton_count += sw.count
	return {
		"quality_tier": String(quality_tier),
		"ambient_mode": "school" if mode == MODE_SCHOOL else "chunk",
		"ambient_instances": _shown,
		"ambient_instances_visible": _in_range,
		"ambient_multimeshes": mms,
		"plankton_instances": plankton_count,
		"krill_instances": krill_count,
		"plankton_multimeshes": _swarms.size(),
		"ambient_usec": last_usec,
	}


func _process(_delta: float) -> void:
	if _world == null:
		return
	var t0: int = Time.get_ticks_usec()
	var a: float = _world.interpolation_alpha()
	var cam: Camera3D = get_viewport().get_camera_3d()
	var cam_pos: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	if not _growing.is_empty():
		_update_growing(float(_world.tick) + a)
	var t_school: float = (float(_world.tick - 2) + a) * SimWorld.TICK_DT
	for m: ShaderMaterial in _species_mat:
		m.set_shader_parameter(&"school_time", t_school)
	if mode == MODE_SCHOOL:
		_render_schools(a, cam_pos)
	else:
		_render_chunks(a, cam_pos)
	for sw: _Swarm in _swarms:
		var cm: float = sw.field.cell_m
		var cell := Vector3i(floori(cam_pos.x / cm), floori(cam_pos.y / cm), floori(cam_pos.z / cm))
		if sw.kf != null:
			sw.mat.set_shader_parameter(&"school_time", t_school)
			if cell != sw.cell or (sw.partial and _world.tick - sw.built_tick >= KRILL_REFRESH_TICKS):
				_rebuild_krill(sw, cell)
		elif cell != sw.cell or (sw.dirty and _world.tick - sw.built_tick >= SWARM_REBUILD_TICKS):
			_rebuild_swarm(sw, cell)
	last_usec = _pending_usec + Time.get_ticks_usec() - t0
	_pending_usec = 0


func _on_ticked(_tick: int) -> void:
	var t0: int = Time.get_ticks_usec()
	for ev: SimEvent in _world.events_since(_event_tick):
		if ev.type < SimEvent.Type.SCHOOL_MEMBER_PROMOTED:
			continue
		if ev.type == SimEvent.Type.PLANKTON_EATEN:
			var fi: int = int(ev.data.get("field", 0))
			var esw: _Swarm = _swarm_of_field[fi] if fi >= 0 and fi < _swarm_of_field.size() else null
			if esw != null and esw.kf != null:
				_hide_krill(esw, int(ev.data.get("cell", -1)) * KrillField.KEY_STRIDE + int(ev.data.get("k", 0)))
			elif esw != null:
				esw.dirty = true
			continue
		var sid: int = int(ev.data.get("school", -1))
		var sv: _SchoolView = _by_id[sid] if sid >= 0 and sid < _by_id.size() else null
		var k: int = int(ev.data.get("k", -1))
		if sv == null or k < 0 or k >= sv.sc.size:
			continue
		match ev.type:
			SimEvent.Type.SCHOOL_MEMBER_PROMOTED, SimEvent.Type.SCHOOL_MEMBER_EATEN:
				_hide(sv, k)
			SimEvent.Type.SCHOOL_MEMBER_DEMOTED:
				_show(sv, k)
			SimEvent.Type.SCHOOL_MEMBER_RESPAWNED:
				if k < sv.limit:
					_growing[(sid << 16) | k] = _world.tick
					sv.scale[k] = GROW_MIN
				_show(sv, k)
	_event_tick = _world.tick
	var s: int = _world.tick - 1
	for sv: _SchoolView in _views:
		sv.prev_c = sv.cur_c
		sv.cur_c = sv.next_c
		sv.next_c = _schools.center_at(sv.sc, s + 1)
		sv.prev_yaw = sv.cur_yaw
		sv.cur_yaw = _yaw(sv.cur_c, sv.next_c)
	_pending_usec += Time.get_ticks_usec() - t0


func _add_school(sc: SchoolSystem.School) -> void:
	if not _assets.has_model(sc.species_id):
		return
	var sv := _SchoolView.new()
	sv.sc = sc
	sv.species_index = _species.find(sc.species_id)
	if sv.species_index < 0:
		sv.species_index = _species.size()
		_species.append(sc.species_id)
		_species_mesh.append(_assets.crowd_mesh(sc.species_id))
		var mat: ShaderMaterial = _assets.crowd_material(sc.species_id, true)
		mat.set_shader_parameter(&"school_wobble_m", _schools.wobble_amplitude())
		mat.set_shader_parameter(&"school_wobble_w", _schools.wobble_angular_speed())
		_species_mat.append(mat)
	sv.limit = sc.size if density_mult >= 1.0 else clampi(ceili(float(sc.size) * density_mult), 0, sc.size)
	sv.slot_of.resize(sc.size)
	sv.slot_of.fill(-1)
	sv.k_of.resize(sc.size)
	sv.scale.resize(sc.size)
	sv.scale.fill(1.0)
	for k in sc.size:
		sv.slots.append(_schools.member_slot(sc, k))
		sv.lengths.append(_schools.member_length(sc, k))
		var pt: Vector2 = member_phase_tint(sc.seed, k)
		var wob: Vector2 = _schools.member_wobble_phases(sc, k)
		sv.custom.append(Color(pt.x, pt.y, wob.x / TAU, wob.y / TAU))
	var s: int = _world.tick - 1
	sv.prev_c = _schools.center_at(sc, s - 1)
	sv.cur_c = _schools.center_at(sc, s)
	sv.next_c = _schools.center_at(sc, s + 1)
	sv.prev_yaw = _yaw(sv.prev_c, sv.cur_c)
	sv.cur_yaw = _yaw(sv.cur_c, sv.next_c)
	if mode == MODE_SCHOOL:
		sv.mm = _new_multimesh(_species_mesh[sv.species_index], maxi(sv.limit, 1))
		sv.mmi = _new_instance(sv.mm, _species_mat[sv.species_index], vis_range_m)
		sv.mmi.transform = Transform3D(Basis(Vector3.UP, sv.cur_yaw), sv.cur_c)
	_by_id[sc.id] = sv
	_views.append(sv)
	for k in sc.size:
		if sc.alive[k] == 1:
			_show(sv, k)


func _show(sv: _SchoolView, k: int) -> void:
	if sv.slot_of[k] >= 0 or k >= sv.limit:
		return
	var s: int = sv.count
	sv.slot_of[k] = s
	sv.k_of[s] = k
	sv.count += 1
	_shown += 1
	if sv.mm != null:
		_write_instance(sv, s, k)
		sv.mm.visible_instance_count = sv.count


func _hide(sv: _SchoolView, k: int) -> void:
	var s: int = sv.slot_of[k]
	if s < 0:
		return
	var last: int = sv.count - 1
	if s != last:
		var moved: int = sv.k_of[last]
		sv.k_of[s] = moved
		sv.slot_of[moved] = s
		if sv.mm != null:
			_write_instance(sv, s, moved)
	sv.slot_of[k] = -1
	sv.count = last
	_shown -= 1
	if sv.mm != null:
		sv.mm.visible_instance_count = last


func _write_instance(sv: _SchoolView, slot: int, k: int) -> void:
	sv.mm.set_instance_transform(slot, Transform3D(Basis.from_scale(Vector3.ONE * (sv.lengths[k] * sv.scale[k])), sv.slots[k]))
	sv.mm.set_instance_custom_data(slot, sv.custom[k])


func _update_growing(now: float) -> void:
	var done: Array[int] = []
	for key: int in _growing:
		var sv: _SchoolView = _by_id[key >> 16]
		var k: int = key & 0xFFFF
		var f: float = (now - float(_growing[key])) / GROW_TICKS
		if f >= 1.0:
			done.append(key)
			f = 1.0
		sv.scale[k] = maxf(f, GROW_MIN)
		if sv.mm != null and sv.slot_of[k] >= 0:
			_write_instance(sv, sv.slot_of[k], k)
	for key: int in done:
		_growing.erase(key)


func _render_schools(a: float, cam_pos: Vector3) -> void:
	var update2: float = (vis_range_m + UPDATE_MARGIN_M) * (vis_range_m + UPDATE_MARGIN_M)
	var vis2: float = vis_range_m * vis_range_m
	_in_range = 0
	for sv: _SchoolView in _views:
		if sv.count == 0:
			continue
		var c: Vector3 = sv.prev_c.lerp(sv.cur_c, a)
		var d2: float = c.distance_squared_to(cam_pos)
		if d2 > update2:
			continue
		if d2 <= vis2:
			_in_range += sv.count
		sv.mmi.transform = Transform3D(Basis(Vector3.UP, lerp_angle(sv.prev_yaw, sv.cur_yaw, a)), c)


func _render_chunks(a: float, cam_pos: Vector3) -> void:
	var update2: float = (vis_range_m + UPDATE_MARGIN_M) * (vis_range_m + UPDATE_MARGIN_M)
	var vis2: float = vis_range_m * vis_range_m
	_in_range = 0
	for b: _Bucket in _bucket_list:
		b.count = 0
	for sv: _SchoolView in _views:
		if sv.count == 0:
			continue
		var c: Vector3 = sv.prev_c.lerp(sv.cur_c, a)
		var d2: float = c.distance_squared_to(cam_pos)
		if d2 > update2:
			continue
		if d2 <= vis2:
			_in_range += sv.count
		var cx: int = floori(c.x / CHUNK_M)
		var cz: int = floori(c.z / CHUNK_M)
		var key: int = ((cx + 4096) * 8192 + (cz + 4096)) * 16 + sv.species_index
		var b: _Bucket = _buckets.get(key, null)
		if b == null:
			b = _new_bucket(sv.species_index, cx, cz)
			_buckets[key] = b
		if b.count + sv.count > b.capacity:
			_grow_bucket(b, b.count + sv.count)
		var rot := Basis(Vector3.UP, lerp_angle(sv.prev_yaw, sv.cur_yaw, a))
		var base: Vector3 = c - b.origin
		var buf: PackedFloat32Array = b.buf
		b.buf = PackedFloat32Array()  # drop the second reference: writes below must not copy the array
		var o: int = b.count * STRIDE
		for i in sv.count:
			var k: int = sv.k_of[i]
			var s: float = sv.lengths[k] * sv.scale[k]
			var p: Vector3 = base + rot * sv.slots[k]
			var cu: Color = sv.custom[k]
			buf[o] = rot.x.x * s
			buf[o + 1] = rot.y.x * s
			buf[o + 2] = rot.z.x * s
			buf[o + 3] = p.x
			buf[o + 4] = rot.x.y * s
			buf[o + 5] = rot.y.y * s
			buf[o + 6] = rot.z.y * s
			buf[o + 7] = p.y
			buf[o + 8] = rot.x.z * s
			buf[o + 9] = rot.y.z * s
			buf[o + 10] = rot.z.z * s
			buf[o + 11] = p.z
			buf[o + 12] = cu.r
			buf[o + 13] = cu.g
			buf[o + 14] = cu.b
			buf[o + 15] = cu.a
			o += STRIDE
		b.buf = buf
		b.count += sv.count
	for b: _Bucket in _bucket_list:
		if b.count > 0 or b.last_count > 0:
			b.mm.buffer = b.buf
			b.mm.visible_instance_count = b.count
			b.last_count = b.count


func _new_bucket(species_index: int, cx: int, cz: int) -> _Bucket:
	var b := _Bucket.new()
	b.origin = Vector3((float(cx) + 0.5) * CHUNK_M, -0.5 * float(_world.map.get("depth_m", 80.0)), (float(cz) + 0.5) * CHUNK_M)
	b.mm = _new_multimesh(_species_mesh[species_index], CHUNK_INITIAL_CAPACITY)
	b.capacity = CHUNK_INITIAL_CAPACITY
	b.buf.resize(b.capacity * STRIDE)
	# visibility is measured to the chunk, so the range grows by about the chunk half diagonal
	b.mmi = _new_instance(b.mm, _species_mat[species_index], vis_range_m + CHUNK_M * 0.75)
	b.mmi.position = b.origin
	_bucket_list.append(b)
	return b


func _grow_bucket(b: _Bucket, need: int) -> void:
	var cap: int = b.capacity
	while cap < need:
		cap *= 2
	b.capacity = cap
	b.mm.instance_count = cap
	b.buf.resize(cap * STRIDE)


# MultiMesh with custom data (use_custom_data and the mesh are set before instance_count).
func _new_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	return mm


func _new_instance(mm: MultiMesh, mat: Material, range_end: float) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = CULL_MARGIN_M
	mmi.visibility_range_end = range_end
	add_child(mmi)
	return mmi


# Yaw of the school frame from the centre at S to the centre at S + 1 (SchoolSystem.heading_at convention:
# yaw = atan2(-h.x, -h.z), 0 while the centre does not move).
static func _yaw(c0: Vector3, c1: Vector3) -> float:
	var d: Vector3 = c1 - c0
	if d.length_squared() <= 1e-12:
		return 0.0
	return atan2(-d.x, -d.z)


func _init_swarm() -> void:
	var low: bool = quality_tier == QualitySettings.LOW
	_swarm_of_field.resize(1 + _world.krill.size())
	_add_swarm(0, _world.plankton, false, SWARM_RADIUS_CELLS_LOW if low else SWARM_RADIUS_CELLS_HIGH, SWARM_PER_CELL_LOW if low else SWARM_PER_CELL_HIGH, SWARM_SCALE_MIN_M, SWARM_SCALE_MAX_M, SALT_SWARM)
	for i in _world.krill.size():
		var kf: KrillField = _world.krill[i]
		_add_swarm(i + 1, kf, true, KRILL_RADIUS_CELLS_LOW if low else KRILL_RADIUS_CELLS_HIGH, kf.critters_per_cell, KRILL_SCALE_MIN_M, KRILL_SCALE_MAX_M, SALT_KRILL + i)


# One swarm MultiMesh for field `f` (PLANKTON_EATEN data.field = field_index); none without a model or density.
func _add_swarm(field_index: int, f: PlanktonField, krill: bool, radius: int, per_cell: int, scale_min: float, scale_max: float, salt: int) -> void:
	if f == null or not _assets.has_model(f.species_id) or not (f.density_max > 0.0):
		return
	var sw := _Swarm.new()
	sw.field = f
	sw.krill = krill
	sw.radius = radius
	sw.per_cell = per_cell
	sw.scale_min = scale_min
	sw.scale_max = scale_max
	sw.salt = salt
	var b: AABB = f.bounds()
	sw.lo = Vector3i((b.position / f.cell_m).round())
	sw.hi = Vector3i((b.end / f.cell_m).round())
	var side: int = 2 * radius + 1
	var side_y: int = 2 * mini(radius, KRILL_RADIUS_Y_CELLS) + 1 if krill else side
	sw.capacity = side * side * mini(side_y, sw.hi.y - sw.lo.y) * per_cell
	if sw.capacity <= 0:
		return
	sw.mm = _new_multimesh(_assets.crowd_mesh(f.species_id), sw.capacity)
	var mat: ShaderMaterial = _assets.crowd_material(f.species_id, false)
	var mmi: MultiMeshInstance3D = _new_instance(sw.mm, mat, 0.0)  # around the camera: no range
	if f is KrillField:
		sw.kf = f as KrillField
		sw.mat = mat
		sw.show_frac = KRILL_SHOW_FRAC_LOW if quality_tier == QualitySettings.LOW else 1.0
		mat.set_shader_parameter(&"drift_m", sw.kf.drift_m)
		mat.set_shader_parameter(&"drift_w", sw.kf.drift_w)
		mat.set_shader_parameter(&"weave_m", sw.kf.weave_m)
		mat.set_shader_parameter(&"weave_w", sw.kf.weave_w)
		mat.set_shader_parameter(&"bob_m", sw.kf.bob_m)
		mmi.extra_cull_margin = CULL_MARGIN_M + sw.kf.drift_m + sw.kf.weave_m + sw.kf.bob_m
	_swarms.append(sw)
	_swarm_of_field[field_index] = sw


func _rebuild_swarm(sw: _Swarm, cell: Vector3i) -> void:
	sw.cell = cell
	sw.dirty = false
	sw.built_tick = _world.tick
	var pf: PlanktonField = sw.field
	var cm: float = pf.cell_m
	var buf := PackedFloat32Array()
	var spots: Dictionary[int, PackedFloat32Array] = {}
	var r: int = sw.radius
	# the (2r + 1)^3 cells around the camera, clipped to the field grid (cells outside it have no density)
	for ix in range(maxi(cell.x - r, sw.lo.x), mini(cell.x + r + 1, sw.hi.x)):
		for iz in range(maxi(cell.z - r, sw.lo.z), mini(cell.z + r + 1, sw.hi.z)):
			for iy in range(maxi(cell.y - r, sw.lo.y), mini(cell.y + r + 1, sw.hi.y)):
				var centre := Vector3((float(ix) + 0.5) * cm, (float(iy) + 0.5) * cm, (float(iz) + 0.5) * cm)
				var id: int = pf.cell_at(centre)
				if id < 0:
					continue
				var f: float = pf.density(id) / pf.density_max
				if f <= SWARM_THRESHOLD:
					if sw.spots.has(id):
						spots[id] = sw.spots[id]
					continue
				var cs: PackedFloat32Array = sw.spots[id] if sw.spots.has(id) else _cell_spots(sw, id, centre, _column_floor(sw, ix, iz))
				spots[id] = cs
				buf.append_array(cs.slice(0, mini(ceili(float(sw.per_cell) * f), cs.size() / STRIDE) * STRIDE))
	sw.spots = spots
	if buf.is_empty() and sw.count == 0:
		return  # nothing drawn before or now: skip the upload
	sw.count = buf.size() / STRIDE
	buf.resize(sw.capacity * STRIDE)
	sw.mm.buffer = buf
	sw.mm.visible_instance_count = sw.count


# The per_cell cluster instances (STRIDE floats each) of field cell `id`, seeded by the cell index and the swarm
# salt; empty when the cell has no water above the seabed.
func _cell_spots(sw: _Swarm, id: int, centre: Vector3, floor_y: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var cm: float = sw.field.cell_m
	var salt: int = sw.salt
	var top: float = minf(centre.y + 0.5 * cm, -SWARM_SURFACE_CLEARANCE_M)
	var bottom: float = maxf(centre.y - 0.5 * cm, floor_y)
	if top <= bottom:
		return out
	out.resize(sw.per_cell * STRIDE)
	for i in sw.per_cell:
		var p := Vector3(
			centre.x + (SchoolSystem.hash01(id, i, salt) - 0.5) * cm,
			lerpf(bottom, top, SchoolSystem.hash01(id, i + 64, salt)),
			centre.z + (SchoolSystem.hash01(id, i + 128, salt) - 0.5) * cm)
		var h: float = SchoolSystem.hash01(id, i + 192, salt)
		var b: Basis = Basis(Vector3.UP, TAU * h) * lerpf(sw.scale_min, sw.scale_max, h)
		var o: int = i * STRIDE
		out[o] = b.x.x
		out[o + 1] = b.y.x
		out[o + 2] = b.z.x
		out[o + 3] = p.x
		out[o + 4] = b.x.y
		out[o + 5] = b.y.y
		out[o + 6] = b.z.y
		out[o + 7] = p.y
		out[o + 8] = b.x.z
		out[o + 9] = b.y.z
		out[o + 10] = b.z.z
		out[o + 11] = p.z
		out[o + 12] = h
	return out


# Krill: every alive critter of the cells around the camera (KrillField layout, cached per cell while in range).
func _rebuild_krill(sw: _Swarm, cell: Vector3i) -> void:
	sw.cell = cell
	sw.built_tick = _world.tick
	sw.partial = false
	var kf: KrillField = sw.kf
	var cm: float = kf.cell_m
	var buf: PackedFloat32Array = sw.buf
	sw.buf = PackedFloat32Array()  # drop the second reference: writes below must not copy the array
	buf.resize(0)
	var keys: PackedInt64Array = sw.keys
	sw.keys = PackedInt64Array()
	keys.resize(0)
	var spots: Dictionary[int, PackedFloat32Array] = {}
	var r: int = sw.radius
	var ry: int = mini(r, KRILL_RADIUS_Y_CELLS)
	for ix in range(maxi(cell.x - r, sw.lo.x), mini(cell.x + r + 1, sw.hi.x)):
		for iz in range(maxi(cell.z - r, sw.lo.z), mini(cell.z + r + 1, sw.hi.z)):
			for iy in range(maxi(cell.y - ry, sw.lo.y), mini(cell.y + ry + 1, sw.hi.y)):
				var id: int = kf.cell_at(Vector3((float(ix) + 0.5) * cm, (float(iy) + 0.5) * cm, (float(iz) + 0.5) * cm))
				var mask: int = kf.alive_mask(id)
				if mask == 0:
					continue
				var cs: PackedFloat32Array = sw.spots[id] if sw.spots.has(id) else _krill_spots(sw, id)
				spots[id] = cs
				var n: int = cs.size() / STRIDE
				var shown: int = n if sw.show_frac >= 1.0 else ceili(float(n) * sw.show_frac)
				var full: int = (1 << n) - 1
				if mask != full:
					sw.partial = true
				elif shown == n:
					buf.append_array(cs)
					for k in n:
						keys.append(id * KrillField.KEY_STRIDE + k)
					continue
				for k in shown:
					if (mask >> k) & 1 == 1:
						buf.append_array(cs.slice(k * STRIDE, (k + 1) * STRIDE))
						keys.append(id * KrillField.KEY_STRIDE + k)
	sw.spots = spots
	sw.keys = keys
	if keys.is_empty() and sw.count == 0:
		sw.buf = buf
		return  # nothing drawn before or now: skip the upload
	sw.count = keys.size()
	buf.resize(sw.capacity * STRIDE)
	sw.mm.buffer = buf
	sw.mm.visible_instance_count = sw.count
	sw.buf = buf


# The instances (STRIDE floats each) of every critter of krill cell `id`: layout position, uniform scale = a hashed
# critter length, INSTANCE_CUSTOM from the layout.
func _krill_spots(sw: _Swarm, id: int) -> PackedFloat32Array:
	var lay: PackedFloat32Array = sw.kf.critter_layout(id)
	var n: int = lay.size() / KrillField.LAYOUT_STRIDE
	var out := PackedFloat32Array()
	out.resize(n * STRIDE)
	for k in n:
		var l: int = k * KrillField.LAYOUT_STRIDE
		var s: float = lerpf(sw.scale_min, sw.scale_max, SchoolSystem.hash01(id, k, sw.salt))
		var o: int = k * STRIDE
		out[o] = s
		out[o + 3] = lay[l]
		out[o + 5] = s
		out[o + 7] = lay[l + 1]
		out[o + 10] = s
		out[o + 11] = lay[l + 2]
		out[o + 12] = lay[l + 3]
		out[o + 13] = lay[l + 4]
		out[o + 14] = lay[l + 5]
		out[o + 15] = lay[l + 6]
	return out


# Hides the drawn instance of critter `key` (the last instance moves into its slot); no-op when it is not drawn.
func _hide_krill(sw: _Swarm, key: int) -> void:
	var slot: int = sw.keys.find(key)
	if slot < 0:
		return
	var last: int = sw.count - 1
	if slot != last:
		var o: int = slot * STRIDE
		var src: int = last * STRIDE
		for j in STRIDE:
			sw.buf[o + j] = sw.buf[src + j]
		sw.keys[slot] = sw.keys[last]
		var b: PackedFloat32Array = sw.buf
		sw.mm.set_instance_transform(slot, Transform3D(Basis(Vector3(b[o], b[o + 4], b[o + 8]), Vector3(b[o + 1], b[o + 5], b[o + 9]), Vector3(b[o + 2], b[o + 6], b[o + 10])), Vector3(b[o + 3], b[o + 7], b[o + 11])))
		sw.mm.set_instance_custom_data(slot, Color(b[o + 12], b[o + 13], b[o + 14], b[o + 15]))
	sw.keys.resize(last)
	sw.count = last
	sw.partial = true
	sw.mm.visible_instance_count = last


# Lowest swarm height of a cell column: seabed at the column centre + clearance (cached; flat 0 floor without seabed).
func _column_floor(sw: _Swarm, ix: int, iz: int) -> float:
	var key: int = (ix + 65536) * 131072 + (iz + 65536)
	if sw.floors.has(key):
		return sw.floors[key]
	var cm: float = sw.field.cell_m
	var y: float = -INF
	if _world.seabed != null:
		y = _world.seabed.height_at((float(ix) + 0.5) * cm, (float(iz) + 0.5) * cm) + SWARM_SEABED_CLEARANCE_M
	sw.floors[key] = y
	return y


static func _mode_arg() -> int:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(MODE_ARG):
			var v: String = arg.trim_prefix(MODE_ARG)
			if v == "chunk":
				return MODE_CHUNK
			if v != "school":
				push_warning("ambient_renderer: unknown %s, using school" % arg)
	return MODE_SCHOOL
