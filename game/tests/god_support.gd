extends RefCounted
## Shared helpers for the test_god_*.gd files (T1.1 God menu core, T1.2 God commands). Not a test file (no `test_`
## prefix): use via `const G := preload("res://tests/god_support.gd")`. No class_name.
##
## - Key event builders (Latin layout, Russian layout where `unicode` is Cyrillic but the physical key is the US letter).
## - A controlled world + player + GodContext for the command / SimDebug tests.
## - A temp copy of res://data for the negative `places` / word-file tests.

const S3 := preload("res://tests/s3_support.gd")
const TMP_ROOT: String = "user://test_god_tmp"
const CYRILLIC_BASE: int = 0x0410  # arbitrary Cyrillic letters: never equal to a Latin letter


# ---------------------------------------------------------------- key events

## A key event. `physical` / `keycode` default to NONE (a synthetic event without them).
static func key(unicode: int, physical: int = KEY_NONE, pressed: bool = true, echo: bool = false, keycode: int = KEY_NONE) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.unicode = unicode
	ev.physical_keycode = physical as Key
	ev.keycode = keycode as Key
	ev.pressed = pressed
	ev.echo = echo
	return ev


## A letter typed on a Latin layout: unicode + keycode + physical key all say `c`.
static func latin(c: String, pressed: bool = true) -> InputEventKey:
	var code: int = c.to_upper().unicode_at(0)
	return key(c.unicode_at(0), code, pressed, false, code) if code >= KEY_A and code <= KEY_Z else key(c.unicode_at(0), KEY_NONE, pressed)


## The same physical key on a Russian layout: `unicode` is a Cyrillic letter, the physical key is still the US letter.
static func cyrillic(c: String, pressed: bool = true) -> InputEventKey:
	var code: int = c.to_upper().unicode_at(0)
	return key(CYRILLIC_BASE + (code - KEY_A), code, pressed)


## Feeds every letter of `word` into `matcher`, `dt_s` apart from `t0_s`. Returns the last non-empty result ("" if none).
static func type_word(matcher: TypedWordMatcher, word: String, t0_s: float = 0.0, dt_s: float = 0.1, ru: bool = false) -> StringName:
	var hit: StringName = &""
	var t: float = t0_s
	for i: int in word.length():
		var ev: InputEventKey = cyrillic(word[i]) if ru else latin(word[i])
		var r: StringName = matcher.feed_event(ev, t)
		if r != &"":
			hit = r
		t += dt_s
	return hit


## Same through the host (direct `_unhandled_input` calls, as the engine does after the GUI declined the event).
static func host_type(host: GodHost, word: String, ru: bool = false) -> void:
	for i: int in word.length():
		host._unhandled_input(cyrillic(word[i]) if ru else latin(word[i]))


static func backtick() -> InputEventKey:
	return key(96, KEY_QUOTELEFT, true, false, KEY_QUOTELEFT)


static func f1() -> InputEventKey:
	return key(0, KEY_F1, true, false, KEY_F1)


# ---------------------------------------------------------------- worlds and contexts

## {"w": SimWorld, "p": SimEntity, "id": int}: controlled world (no spawners), vitals on, the real player at spawn 0.
static func rig(world_seed: int = 1, opts: Dictionary = {}) -> Dictionary:
	var w: SimWorld = S3.make_world(world_seed, opts)
	var id: int = w.spawn_player()
	return {"w": w, "p": w.get_entity(id), "id": id}


## A GodContext over `w` (no host, no console). `run` is any Node3D (overlays attach to it); the caller frees it.
static func context(w: SimWorld, player_id: int, run: Node = null) -> GodContext:
	var ctx := GodContext.new()
	ctx.world = w
	ctx.player_id = player_id
	ctx.run = run
	return ctx


static func has_event(evs: Array[SimEvent], type: SimEvent.Type) -> bool:
	for ev: SimEvent in evs:
		if ev.type == type:
			return true
	return false


# ---------------------------------------------------------------- temp data

static func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d: DirAccess = DirAccess.open(src)
	if d == null:
		return
	for sub: String in d.get_directories():
		_copy_dir(src.path_join(sub), dst.path_join(sub))
	for f: String in d.get_files():
		if f.get_extension() == "import" or f.get_extension() == "uid":
			continue
		var out: FileAccess = FileAccess.open(dst.path_join(f), FileAccess.WRITE)
		out.store_buffer(FileAccess.get_file_as_bytes(src.path_join(f)))
		out.close()


static func remove_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for sub: String in d.get_directories():
		remove_dir(path.path_join(sub))
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


## Copy of res://data in user://, `edit` (Callable taking the copy's root path) applied, then loaded.
static func db_with(edit: Callable) -> ContentDB:
	remove_dir(TMP_ROOT)
	_copy_dir("res://data", TMP_ROOT)
	edit.call(TMP_ROOT)
	return ContentDB.load_from_dir(TMP_ROOT)


static func cleanup_temp() -> void:
	remove_dir(TMP_ROOT)


static func read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func write_json(path: String, value: Variant) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(value, "\t"))
	f.close()


static func errors_mention(db: ContentDB, needles: Array[String]) -> bool:
	for e: String in db.errors:
		var all: bool = true
		for n: String in needles:
			if not e.contains(n):
				all = false
		if all:
			return true
	return false
