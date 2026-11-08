class_name TypedWordMatcher
extends RefCounted
## Detects typed words in a stream of key presses (the "eatgod" unlock). Pure logic, no nodes: the caller passes the
## clock, so it is testable without a SceneTree.
##
## Two parallel rolling buffers are kept per key press: the typed characters (`unicode`, lower-cased) and the letters of
## the PHYSICAL key (`physical_keycode` A-Z), so the word also matches on a Russian layout where `unicode` is Cyrillic.
## A word matches when the end (suffix) of either buffer equals it. Ignored without touching the buffers: releases, echo,
## ctrl / alt / meta combos and keys that type nothing (Shift alone, arrows, F-keys). Any other key (digit, space, a
## non-matching letter) is written into both buffers as a filler, so it breaks a word typed around it. Silence longer than
## TIMEOUT_S empties both buffers; a match empties them too.

## Seconds of silence after which a half-typed word is forgotten.
const TIMEOUT_S: float = 1.5
## Written into a buffer for a key that has no letter in that buffer's alphabet.
const FILLER: String = "?"

var _words: Dictionary = {}  # word -> id
var _max_len: int = 0
var _typed: String = ""
var _physical: String = ""
var _last_s: float = -INF


## `words`: word (lowercase a-z) -> id. Clears the buffers.
func setup(words: Dictionary) -> void:
	_words = words.duplicate()
	_max_len = 0
	for w: String in _words:
		_max_len = maxi(_max_len, w.length())
	reset()


func reset() -> void:
	_typed = ""
	_physical = ""
	_last_s = -INF


## Feeds one event at time `now_s` (seconds, any monotonic clock). Returns the id of the word that was just completed,
## or &"" when nothing matched. Never consumes the event.
func feed_event(ev: InputEvent, now_s: float) -> StringName:
	var key: InputEventKey = ev as InputEventKey
	if key == null or not key.pressed or key.echo or key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return &""
	var letter: String = _physical_letter(key)
	if key.unicode == 0 and letter.is_empty():
		return &""  # types nothing (Shift, arrows, F-keys)
	if now_s - _last_s > TIMEOUT_S:
		reset()
	_last_s = now_s
	_typed = _push(_typed, String.chr(key.unicode).to_lower() if key.unicode > 0 else FILLER)
	_physical = _push(_physical, letter if not letter.is_empty() else FILLER)
	for w: String in _words:
		if _typed.ends_with(w) or _physical.ends_with(w):
			var id: StringName = StringName(_words[w])
			reset()
			return id
	return &""


# Lower-case letter of the physical key (falls back to `keycode` for synthetic events without physical_keycode), or "".
func _physical_letter(key: InputEventKey) -> String:
	var code: int = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code >= KEY_A and code <= KEY_Z:
		return String.chr(code - KEY_A + 97)
	return ""


func _push(buf: String, c: String) -> String:
	buf += c
	return buf.right(_max_len) if buf.length() > _max_len else buf
