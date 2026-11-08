class_name AudioDirector
extends Node
## Game audio (GAME_DESIGN §11): sim events -> SFX, plus the music loop and the underwater ambience. Reads
## SimWorld.events_since once per GameLoop.ticked (like FeedbackFx) and entity state; never writes the sim.
##
## - World sounds (NPC bites, kills, swallows, puffer bubbles, the boss): pooled AudioStreamPlayer3D at the event
##   position on the `Underwater` bus (low-pass + slight reverb, under `SFX`), inverse-distance falloff with
##   unit_size from the creature length; skipped beyond CULL_M from the camera (the 3D listener).
## - Player sounds (own bites / being bitten, swallow, kill, boost start, Bite-Dash, sonar, band-up, respawn, plankton,
##   the own bite missing = BITE_MISSED, already throttled by the sim): pooled non-positional AudioStreamPlayer, also on
##   `Underwater`.
## - Every play picks a random variant of the group (never the same one twice in a row) with a small pitch jitter;
##   at most MAX_PER_GROUP_TICK plays per group per sim tick, and a minimum gap per group (GAP_2D_S / GAP_3D_S, longer
##   ones for boost and plankton). Voices: an idle pool player, else the oldest one is reused.
## - Music: the reef theme and the boss layer play in sync (AudioStreamSynchronized, same 80 s grid) on `Music`; while
##   SimWorld.boss_engaged() the mix crossfades to the theme at CALM_BOSS_DB + the layer at BOSS_LAYER_DB. Ambience
##   loop on `SFX` (already filtered, so it bypasses `Underwater`). Fades run on real time (slow-mo does not stretch them).
## - process_mode ALWAYS (set in the scene): music and in-flight sounds keep playing over the pause / victory screens.
## - Headless-safe: on the Dummy audio driver (--headless) streams load and events are handled as usual but nothing is
##   started (output_enabled() false): Dummy keeps a playing stream registered past the quit-time resource cleanup
##   ("resources still in use at exit" after --quit-after), and there is nothing to hear anyway.
## - Food (food task, player only, 2D): SITE_BITTEN = bite_small (the killing bite too), SITE_EATEN = the food type's
##   `sfx` group (crunch; a soft egg at SITE_SOFT_DB, a killed hard site at 0 dB); PLANKTON_EATEN of a krill field
##   (data.field > 0) = gulp, throttled KRILL_GAP_S on its own key (plankton, field 0 or no key, keeps the bubbles).
## Volumes: the S6 settings drive the Master / Music / SFX buses (GameSettings.apply_audio); `Underwater` sends into SFX.
## Assets: res://assets/audio/{sfx/<group>/<group>_v<n>.wav, music/*.ogg} from tools/audio/build_all.py.

const SFX_DIR: String = "res://assets/audio/sfx/"
const MUSIC_PATH: String = "res://assets/audio/music/reef_theme_v1.ogg"
const BOSS_LAYER_PATH: String = "res://assets/audio/music/reef_boss_v1.ogg"
const AMBIENCE_PATH: String = "res://assets/audio/music/ambience_reef.ogg"
const BUS_WORLD: StringName = &"Underwater"
const BUS_MUSIC: StringName = &"Music"
const BUS_AMBIENCE: StringName = &"SFX"
## SFX groups this node plays (folder names under SFX_DIR).
const GROUPS: Array[StringName] = [&"bubbles", &"bite_small", &"bite_big", &"bite_miss", &"swallow", &"kill", &"boost",
	&"sonar", &"boss_tell", &"boss_dash", &"band_up", &"crunch", &"gulp"]
## Per-group gain (dB) on top of the file level (files peak at -1 dBFS x their preset level).
const GROUP_DB: Dictionary = {&"bubbles": -6.0, &"bite_small": -3.0, &"bite_big": 0.0, &"bite_miss": -4.0, &"swallow": -4.0,
	&"kill": -2.0, &"boost": -6.0, &"sonar": -3.0, &"boss_tell": 0.0, &"boss_dash": 0.0, &"band_up": -3.0, &"crunch": -2.0,
	&"gulp": -8.0}
## Extra gain for world sounds the player is not part of.
const NPC_DB: float = -5.0
const POOL_3D: int = 16
const POOL_2D: int = 8
## World sounds farther than this from the camera are not played (fogged out anyway; FeedbackFx uses 60 m).
const CULL_M: float = 50.0
const MAX_PER_GROUP_TICK: int = 2
const PITCH_JITTER: float = 0.04
const GAP_2D_S: float = 0.08
const GAP_3D_S: float = 0.15
const BOOST_GAP_S: float = 0.35
const PLANKTON_GAP_S: float = 1.2
const PLANKTON_DB: float = -12.0
## Krill grazing gulp gap (separate key from the plankton bubbles) and the crunch of a swallowed soft food site.
const KRILL_GAP_S: float = 1.2
const SITE_SOFT_DB: float = -3.0
## unit_size = clamp(length * UNIT_PER_M, UNIT_MIN, UNIT_MAX) (full volume within about that distance).
const UNIT_PER_M: float = 3.0
const UNIT_MIN: float = 3.0
const UNIT_MAX: float = 30.0
const MUSIC_FADE_IN_S: float = 3.0
const BOSS_FADE_S: float = 1.5
const CALM_BOSS_DB: float = -3.0
const BOSS_LAYER_DB: float = -4.0
const AMBIENCE_DB: float = -3.0
const SILENT_DB: float = -60.0

## Plays started per group since setup (counted also when output is off; for tests and checks).
var play_counts: Dictionary = {}  # StringName -> int

var _world: SimWorld
var _player_id: int = 0
var _camera: Node3D
var _event_tick: int = 0
var _chomp_min_frac: float = 0.25
var _streams: Dictionary = {}  # StringName -> Array[AudioStream]
var _last_variant: Dictionary = {}  # StringName -> int
var _per_tick: Dictionary = {}  # StringName -> plays this tick
var _next_ok_ms: Dictionary = {}  # String key -> Time.get_ticks_msec() before which the key is blocked
var _pool3: Array[AudioStreamPlayer3D] = []
var _pool2: Array[AudioStreamPlayer] = []
var _started3: PackedInt64Array = PackedInt64Array()
var _started2: PackedInt64Array = PackedInt64Array()
var _rng := RandomNumberGenerator.new()
var _was_boosting: bool = false
var _music: AudioStreamPlayer
var _sync: AudioStreamSynchronized
var _ambience: AudioStreamPlayer
var _music_level: float = 0.0
var _boss_mix: float = 0.0
var _boss_target: float = 0.0
var _output: bool = true


## False on the Dummy audio driver (headless runs): no stream is started there (see the class doc).
static func output_enabled() -> bool:
	return AudioServer.get_driver_name() != "Dummy"


## Loads every variant of an SFX group (sorted by name; empty when the folder is missing).
static func load_group(group: StringName) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	var dir: String = SFX_DIR + String(group) + "/"
	var names: PackedStringArray = ResourceLoader.list_directory(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()
	names.sort()
	for n: String in names:
		if n.get_extension() == "wav" or n.get_extension() == "ogg":
			var s: AudioStream = load(dir + n) as AudioStream
			if s != null:
				out.append(s)
	return out


func setup(loop: GameLoop, player_id: int, camera: Node3D) -> void:
	_world = loop.world
	_player_id = player_id
	_camera = camera
	_event_tick = _world.tick
	_output = output_enabled()
	_rng.seed = 1104  # presentation-only RNG (variant / pitch picks), never the sim's
	var rules: Dictionary = _world.content.rules() if _world.content != null else {}
	var fb: Dictionary = rules.get("feedback", {}) if rules.get("feedback") is Dictionary else {}
	_chomp_min_frac = float(fb.get("chomp_min_frac", _chomp_min_frac))
	for g: StringName in GROUPS:
		_streams[g] = load_group(g)
		if (_streams[g] as Array).is_empty():
			push_warning("audio_director: no sounds in %s%s" % [SFX_DIR, g])
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = BUS_WORLD
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.max_distance = CULL_M
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		add_child(p)
		_pool3.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_WORLD
		add_child(p)
		_pool2.append(p)
	_started3.resize(POOL_3D)
	_started2.resize(POOL_2D)
	_setup_music()
	loop.ticked.connect(_on_ticked)


func _setup_music() -> void:
	var calm: AudioStream = load(MUSIC_PATH) as AudioStream
	var layer: AudioStream = load(BOSS_LAYER_PATH) as AudioStream
	if calm != null:
		_sync = AudioStreamSynchronized.new()
		_sync.stream_count = 2 if layer != null else 1
		_sync.set_sync_stream(0, calm)
		_sync.set_sync_stream_volume(0, 0.0)
		if layer != null:
			_sync.set_sync_stream(1, layer)
			_sync.set_sync_stream_volume(1, SILENT_DB)
		_music = AudioStreamPlayer.new()
		_music.stream = _sync
		_music.bus = BUS_MUSIC
		_music.volume_db = SILENT_DB
		add_child(_music)
		if _output:
			_music.play()
	var amb: AudioStream = load(AMBIENCE_PATH) as AudioStream
	if amb != null:
		_ambience = AudioStreamPlayer.new()
		_ambience.stream = amb
		_ambience.bus = BUS_AMBIENCE
		_ambience.volume_db = SILENT_DB
		add_child(_ambience)
		if _output:
			_ambience.play()


func _process(delta: float) -> void:
	if _world == null:
		return
	var real: float = delta / maxf(Engine.time_scale, 0.001)  # fades last real seconds, also during slow-mo
	if _music_level < 1.0:
		_music_level = minf(_music_level + real / MUSIC_FADE_IN_S, 1.0)
		var fade_db: float = maxf(linear_to_db(maxf(_music_level, 0.001)), SILENT_DB)
		if _music != null:
			_music.volume_db = fade_db
		if _ambience != null:
			_ambience.volume_db = fade_db + AMBIENCE_DB
	if _sync != null and _sync.stream_count > 1 and _boss_mix != _boss_target:
		_boss_mix = move_toward(_boss_mix, _boss_target, real / BOSS_FADE_S)
		_sync.set_sync_stream_volume(0, CALM_BOSS_DB * _boss_mix)
		_sync.set_sync_stream_volume(1, maxf(linear_to_db(maxf(_boss_mix, 0.001)) + BOSS_LAYER_DB, SILENT_DB))


func _on_ticked(_tick: int) -> void:
	if _world.tick == _event_tick:
		return  # a world paused for a pick re-emits `ticked` with the same tick
	_per_tick.clear()
	var player: SimEntity = _world.get_entity(_player_id)
	for ev: SimEvent in _world.events_since(_event_tick):
		match ev.type:
			SimEvent.Type.BITTEN:
				_on_bitten(ev)
			SimEvent.Type.EATEN:
				_on_eaten(ev)
			SimEvent.Type.DIED:
				_on_died(ev)
			SimEvent.Type.SPIKED:
				if ev.entity_id == _player_id:
					_play_2d(&"bite_small", -2.0, 1.25)
			SimEvent.Type.BITE_MISSED:
				if ev.entity_id == _player_id:
					_play_2d(&"bite_miss")
			SimEvent.Type.INFLATED:
				var pf: SimEntity = _world.get_entity(ev.entity_id)
				if pf != null:
					_play_3d(&"bubbles", pf.position, pf.length_m, NPC_DB)
			SimEvent.Type.PLANKTON_EATEN:
				if ev.entity_id != _player_id:
					pass
				elif int(ev.data.get("field", 0)) > 0:
					if _gap_ok("krill", KRILL_GAP_S):
						_play_2d(&"gulp")
				elif _gap_ok("plankton", PLANKTON_GAP_S):
					_play_2d(&"bubbles", PLANKTON_DB)
			SimEvent.Type.SITE_BITTEN:
				if ev.entity_id == _player_id:
					_play_2d(&"bite_small")
			SimEvent.Type.SITE_EATEN:
				if ev.entity_id == _player_id:
					_play_2d(_food_group(StringName(ev.data.get("type", &""))), SITE_SOFT_DB if bool(ev.data.get("soft", false)) else 0.0)
			SimEvent.Type.BAND_UP:
				if ev.entity_id == _player_id:
					_play_2d(&"band_up")
			SimEvent.Type.RESPAWNED:
				if ev.entity_id == _player_id:
					_play_2d(&"bubbles")
			SimEvent.Type.DASH_STARTED:
				if ev.entity_id == _player_id:
					_play_2d(&"boost", 2.0)
			SimEvent.Type.SONAR_PULSE:
				if ev.entity_id == _player_id:
					_play_2d(&"sonar")
			SimEvent.Type.BOSS_TELL:
				_play_boss(&"boss_tell", ev)
			SimEvent.Type.BOSS_DASH:
				_play_boss(&"boss_dash", ev)
			SimEvent.Type.BOSS_DEFEATED:
				_play_2d(&"band_up", 2.0, 0.9)
	_event_tick = _world.tick
	if player != null:
		if player.boosting and not _was_boosting and _gap_ok("boost", BOOST_GAP_S):
			_play_2d(&"boost")
		_was_boosting = player.boosting
	_boss_target = 1.0 if _world.boss_engaged() else 0.0


func _on_bitten(ev: SimEvent) -> void:
	var victim: SimEntity = _world.get_entity(ev.entity_id)
	var max_hp: float = float(ev.data.get("max_hp", victim.max_hp if victim != null else 0.0))
	var frac: float = ev.value / max_hp if max_hp > 0.0 else 0.0
	var group: StringName = &"bite_big" if frac >= _chomp_min_frac or bool(ev.data.get("dash", false)) else &"bite_small"
	if ev.entity_id == _player_id or ev.other_id == _player_id:
		_play_2d(group)
	elif victim != null:
		_play_3d(group, victim.position, victim.length_m, NPC_DB)


func _on_eaten(ev: SimEvent) -> void:
	if ev.other_id == _player_id:
		_play_2d(&"swallow")
		return
	var eater: SimEntity = _world.get_entity(ev.other_id)
	if eater != null:
		_play_3d(&"swallow", eater.position + eater.heading * (eater.length_m * 0.45), eater.length_m, NPC_DB)


func _on_died(ev: SimEvent) -> void:
	if ev.entity_id == _player_id:
		_play_2d(&"kill", 0.0, 0.8)  # the player's own death: same crunch, lower
	elif ev.other_id == _player_id:
		_play_2d(&"kill")
	else:
		var pos: Vector3 = ev.data.get("pos", Vector3.ZERO)
		_play_3d(&"kill", pos, float(ev.data.get("length", 1.0)), NPC_DB)


# SFX group of a food type (its `sfx`, default crunch); a group outside GROUPS is loaded on first use.
func _food_group(type: StringName) -> StringName:
	var rec: Dictionary = _world.content.get_food(type) if _world.content != null else {}
	var g := StringName(str(rec.get("sfx", "crunch")))
	if not _streams.has(g):
		_streams[g] = load_group(g)
	return g


# The boss is a 10 m actor: positional at its body with a large unit size, never culled (the warning must land).
func _play_boss(group: StringName, ev: SimEvent) -> void:
	var boss: SimEntity = _world.get_entity(ev.entity_id)
	if boss == null:
		_play_2d(group)
	else:
		_play_3d(group, boss.position, boss.length_m, 0.0, true)


func _play_2d(group: StringName, db: float = 0.0, pitch: float = 1.0) -> void:
	var stream: AudioStream = _pick(group, "2d:")
	if stream == null:
		return
	var i: int = _voice_index(_pool2, _started2)
	_started2[i] = Time.get_ticks_msec()
	var p: AudioStreamPlayer = _pool2[i]
	p.stream = stream
	p.volume_db = float(GROUP_DB.get(group, 0.0)) + db
	p.pitch_scale = pitch * _jitter()
	if _output:
		p.play()


func _play_3d(group: StringName, pos: Vector3, length_m: float, db: float = 0.0, force: bool = false) -> void:
	if not force and (_camera == null or _camera.global_position.distance_squared_to(pos) > CULL_M * CULL_M):
		return
	var stream: AudioStream = _pick(group, "3d:")
	if stream == null:
		return
	var i: int = _voice_index(_pool3, _started3)
	_started3[i] = Time.get_ticks_msec()
	var p: AudioStreamPlayer3D = _pool3[i]
	p.stream = stream
	p.position = pos
	p.unit_size = clampf(length_m * UNIT_PER_M, UNIT_MIN, UNIT_MAX)
	p.max_distance = maxf(CULL_M, p.unit_size * 4.0)
	p.volume_db = float(GROUP_DB.get(group, 0.0)) + db
	p.pitch_scale = _jitter()
	if _output:
		p.play()


# A random variant of `group` (not the previous one), or null when capped this tick / inside the group's gap.
func _pick(group: StringName, gap_prefix: String) -> AudioStream:
	var variants: Array = _streams.get(group, [])
	if variants.is_empty() or int(_per_tick.get(group, 0)) >= MAX_PER_GROUP_TICK:
		return null
	if not _gap_ok(gap_prefix + String(group), GAP_2D_S if gap_prefix == "2d:" else GAP_3D_S):
		return null
	_per_tick[group] = int(_per_tick.get(group, 0)) + 1
	var v: int = _rng.randi_range(0, variants.size() - 1)
	if variants.size() > 1 and v == int(_last_variant.get(group, -1)):
		v = (v + 1) % variants.size()
	_last_variant[group] = v
	play_counts[group] = int(play_counts.get(group, 0)) + 1
	return variants[v]


# True (and blocks `key` for `gap_s` real seconds) when `key` is not inside its gap.
func _gap_ok(key: String, gap_s: float) -> bool:
	var now: int = Time.get_ticks_msec()
	if now < int(_next_ok_ms.get(key, 0)):
		return false
	_next_ok_ms[key] = now + int(gap_s * 1000.0)
	return true


# Index of an idle voice of `players`, else of the one started longest ago (`started`: start msec per voice).
func _voice_index(players: Array, started: PackedInt64Array) -> int:
	var oldest: int = 0
	for k in players.size():
		if not players[k].playing:
			return k
		if started[k] < started[oldest]:
			oldest = k
	return oldest


func _jitter() -> float:
	return 1.0 + _rng.randf_range(-PITCH_JITTER, PITCH_JITTER)
