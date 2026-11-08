extends TestCase
## Target health bars (tasks/feat-target-health-bar.md): TargetBarTracker (node-free: which targets get a bar, fade
## timing, cap / replacement, boss exclusion, pruning) and a headless TargetHealthBars smoke run on a real SimWorld
## bite (bars come out of the fixed pool and go back to it).

const S3 := preload("res://tests/s3_support.gd")

var _nodes: Array[Node] = []


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


# ---------------------------------------------------------------- helpers

func _bitten(victim_id: int, biter_id: int, tick: int = 0) -> SimEvent:
	var ev := SimEvent.create(SimEvent.Type.BITTEN, tick, victim_id, biter_id, 1.0)
	ev.data = {"max_hp": 10.0}
	return ev


## {"w", "p", "v"}: player (0.5 m, facing +X) in the arena and a pinned small reef fish in its mouth cone.
func _scene() -> Dictionary:
	var w: SimWorld = S3.make_world(17)
	var p: SimEntity = S3.player_at(w, S3.ARENA, S3.xp_for_length(w.content, 0.5), Vector3.RIGHT)
	var at: Vector3 = p.position + p.heading * (S3.reach_m(w, p) * 0.5)
	var v: SimEntity = S3.npc_at(w, &"small_reef_fish", at, p.length_m * 6.0, -p.heading)
	return {"w": w, "p": p, "v": v}


## A GameLoop shell around `w` (not in the tree: nothing steps it) and the bars node bound to it, no camera.
func _bars(w: SimWorld, player_id: int) -> Array:
	var loop := GameLoop.new()
	loop.world = w
	var bars := TargetHealthBars.new()
	bars.setup(loop, player_id, null)
	_nodes.append(bars)
	_nodes.append(loop)
	return [loop, bars]


func _bite(sc: Dictionary, loop: GameLoop) -> void:
	var w: SimWorld = sc["w"]
	var v: SimEntity = sc["v"]
	w.submit(SimCommand.bite((sc["p"] as SimEntity).id, v.id))
	var calm: Array[int] = [v.id]
	S3.step_n(w, 1, {v.id: v.position}, [], calm)
	loop.ticked.emit(w.tick)


func _visible_bars(bars: TargetHealthBars) -> int:
	var n: int = 0
	for c: Node in bars.get_children():
		if (c as MeshInstance3D).visible:
			n += 1
	return n


# ---------------------------------------------------------------- TargetBarTracker: who gets a bar

func test_only_a_player_bite_on_a_living_npc_starts_a_bar() -> void:
	var w: SimWorld = S3.make_world(17)
	var p: SimEntity = S3.player_at(w, S3.ARENA)
	var npc: SimEntity = S3.npc_at(w, &"small_reef_fish", S3.ARENA + Vector3(2.0, 0.0, 0.0))
	var other: SimEntity = S3.npc_at(w, &"grouper", S3.ARENA + Vector3(-2.0, 0.0, 0.0))
	assert_true(TargetBarTracker.is_player_hit(_bitten(npc.id, p.id), npc, p.id), "player bites an NPC: bar")
	assert_false(TargetBarTracker.is_player_hit(_bitten(npc.id, other.id), npc, p.id), "NPC-vs-NPC: no bar")
	assert_false(TargetBarTracker.is_player_hit(_bitten(p.id, npc.id), p, p.id), "the player bitten: no bar on the player")
	assert_false(TargetBarTracker.is_player_hit(_bitten(npc.id, p.id), null, p.id), "killing bite (victim already removed): none")
	var not_bitten := SimEvent.create(SimEvent.Type.EATEN, 0, npc.id, p.id)
	assert_false(TargetBarTracker.is_player_hit(not_bitten, npc, p.id), "other event types: none")
	npc.alive = false
	assert_false(TargetBarTracker.is_player_hit(_bitten(npc.id, p.id), npc, p.id), "dead victim: none")


func test_the_boss_never_gets_a_bar() -> void:
	var w: SimWorld = S3.make_world(17)
	var p: SimEntity = S3.player_at(w, S3.ARENA)
	var boss: SimEntity = S3.npc_at(w, &"giant_shark", S3.ARENA + Vector3(12.0, 0.0, 0.0))
	boss.boss_state = 0  # fixture: any boss state (>= 0) marks the boss
	assert_false(TargetBarTracker.is_player_hit(_bitten(boss.id, p.id), boss, p.id), "boss has the HUD bar")


# ---------------------------------------------------------------- TargetBarTracker: refresh, cap, fade

func test_a_new_hit_refreshes_the_same_bar() -> void:
	var t := TargetBarTracker.new()
	t.note_hit(5, 10)
	t.note_hit(5, 40)
	assert_eq(t.ids, PackedInt32Array([5]), "one bar per target")
	assert_eq(t.hit_ticks[0], 40, "the timer restarts at the latest hit")


func test_cap_replaces_the_target_hit_longest_ago() -> void:
	var t := TargetBarTracker.new()
	for i in TargetBarTracker.CAP:
		t.note_hit(100 + i, 10 + i)
	t.note_hit(100, 50)  # refreshed: now the most recent
	t.note_hit(999, 60)
	assert_eq(t.ids.size(), TargetBarTracker.CAP, "never more than CAP bars")
	assert_true(t.ids.has(999), "the new target gets a bar")
	assert_false(t.ids.has(101), "it replaced the one hit longest ago")
	assert_true(t.ids.has(100), "the refreshed one stays")


func test_bar_holds_then_fades_out() -> void:
	var t := TargetBarTracker.new()
	t.note_hit(1, 0)
	var hold_t: float = TargetBarTracker.HOLD_S * SimWorld.TICK_RATE
	var fade_t: float = TargetBarTracker.FADE_S * SimWorld.TICK_RATE
	assert_almost_eq(t.alpha(0, 0.0), 1.0, 1e-9, "full right after the hit")
	assert_almost_eq(t.alpha(0, hold_t - 1.0), 1.0, 1e-9, "full until HOLD_S")
	assert_almost_eq(t.alpha(0, hold_t + fade_t * 0.5), 0.5, 1e-6, "half way through the fade")
	assert_almost_eq(t.alpha(0, hold_t + fade_t + 1.0), 0.0, 1e-9, "gone after HOLD_S + FADE_S")
	assert_almost_eq(TargetBarTracker.HOLD_S, 4.0, 1e-9, "task: about 4 s without new damage")


func test_prune_drops_gone_dead_far_and_faded_targets() -> void:
	var w: SimWorld = S3.make_world(17)
	var c: Vector3 = S3.ARENA
	var keep: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(3.0, 0.0, 0.0))
	var gone: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(0.0, 0.0, 3.0))
	var dead: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(0.0, 3.0, 0.0))
	var far: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(30.0, 0.0, 0.0))
	var old: SimEntity = S3.npc_at(w, &"small_reef_fish", c + Vector3(-3.0, 0.0, 0.0))
	var now: float = 1000.0
	var t := TargetBarTracker.new()
	for e: SimEntity in [keep, gone, dead, far]:
		t.note_hit(e.id, int(now))
	t.note_hit(old.id, int(now - (TargetBarTracker.HOLD_S + TargetBarTracker.FADE_S) * SimWorld.TICK_RATE) - 1)
	w.remove_entity(gone.id)
	dead.alive = false
	t.prune(w, c, 20.0, now)
	assert_eq(t.ids, PackedInt32Array([keep.id]), "only the living, near, recently hit target keeps its bar")
	assert_eq(t.hit_ticks.size(), t.ids.size(), "parallel arrays stay in step")


# ---------------------------------------------------------------- TargetHealthBars node (headless smoke)

func test_a_real_player_bite_shows_a_bar_and_it_returns_to_the_pool() -> void:
	var sc: Dictionary = _scene()
	var w: SimWorld = sc["w"]
	var v: SimEntity = sc["v"]
	var pair: Array = _bars(w, (sc["p"] as SimEntity).id)
	var loop: GameLoop = pair[0]
	var bars: TargetHealthBars = pair[1]
	assert_eq(bars.get_child_count(), TargetBarTracker.CAP, "fixed pool created at setup")
	bars._process(0.0)
	assert_eq(_visible_bars(bars), 0, "no bar before any bite")
	_bite(sc, loop)
	assert_true(v.hp < v.max_hp and v.alive, "test setup: the bite landed and did not kill")
	bars._process(0.0)
	assert_eq(bars.tracked_ids(), PackedInt32Array([v.id]), "the bitten fish has a bar")
	assert_eq(_visible_bars(bars), 1, "one pool node drawn")
	var bar: MeshInstance3D = bars.get_child(0) as MeshInstance3D
	assert_true(bar.position.y > v.position.y, "the bar sits above the fish")
	var frac: float = float(bar.get_instance_shader_parameter(&"frac"))
	assert_almost_eq(frac, v.hp / v.max_hp, 1e-5, "bar shows the HP fraction")
	assert_almost_eq(float(bar.get_instance_shader_parameter(&"fade")), 1.0, 1e-6, "fully visible right after the bite")
	# no new damage: the bar fades out and its node goes back to the pool
	var calm: Array[int] = [v.id]
	S3.step_n(w, S3.ticks(TargetBarTracker.HOLD_S + TargetBarTracker.FADE_S) + 2, {v.id: v.position}, [v.id], calm)
	loop.ticked.emit(w.tick)
	bars._process(0.0)
	assert_eq(bars.tracked_ids().size(), 0, "faded out after HOLD_S + FADE_S")
	assert_eq(_visible_bars(bars), 0, "node hidden (back in the pool)")
	# the next bite brings it back; the target leaving the world removes it at once
	_bite(sc, loop)
	bars._process(0.0)
	assert_eq(_visible_bars(bars), 1, "reappears on the next player bite")
	w.remove_entity(v.id)
	bars._process(0.0)
	assert_eq(_visible_bars(bars), 0, "target gone (eaten / died / demoted): bar gone")
	assert_eq(bars.get_child_count(), TargetBarTracker.CAP, "the pool never grows")
