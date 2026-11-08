class_name TypedWords
extends RefCounted
## Typed-word and hotkey data of the dev tools: `res://data/god/typed_words.json` (schema: data/README.md).
##  - `words`: records `{id, word, kind}`; `kind` "dev" needs the God build gate, "cheat" is reserved for the player-facing
##    cheat words (T7.2) that share this system and stay in release.
##  - `menu_keys` / `console_keys`: key sets that toggle the F1 menu / the `~` console (see KeySet).
## Invalid records are skipped and reported in `errors` (path-qualified); a missing file gives no words and no keys.

const PATH: String = "res://data/god/typed_words.json"
const KINDS: PackedStringArray = ["dev", "cheat"]
const WORD_MIN_LEN: int = 3
const WORD_MAX_LEN: int = 16

## Records that passed validation, in file order.
var words: Array[Dictionary] = []
var menu_keys: KeySet = KeySet.new()
var console_keys: KeySet = KeySet.new()
var errors: PackedStringArray = []


## A set of key bindings for one action. A key press matches when ANY of the three lists hits: `physical` (layout
## independent position, US-ANSI names), `keycode` (layout dependent logical key) or `unicode` (the typed character, so
## a Cyrillic layout still reaches the key that types a backtick on a Latin one). Echo, releases and ctrl / alt / meta
## combos never match (Shift is allowed: `~` is Shift + backtick).
class KeySet extends RefCounted:
	var physical: PackedInt32Array = []
	var keycodes: PackedInt32Array = []
	var unicodes: PackedInt32Array = []

	func matches(ev: InputEventKey) -> bool:
		if not ev.pressed or ev.echo or ev.ctrl_pressed or ev.alt_pressed or ev.meta_pressed:
			return false
		return ev.physical_keycode in physical or ev.keycode in keycodes or (ev.unicode != 0 and ev.unicode in unicodes)


## Loads and validates `path`; never null. A missing / unreadable / malformed file is reported in `errors`.
static func load_file(path: String = PATH) -> TypedWords:
	var tw: TypedWords = TypedWords.new()
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		tw.errors.append("%s: missing or empty" % path)
		return tw
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		tw.errors.append("%s: not a JSON object" % path)
		return tw
	var root: Dictionary = parsed
	var records: Variant = root.get("words", [])
	if records is Array:
		tw.errors.append_array(validate_words(records, path))
		var bad: Dictionary = {}
		for err: String in tw.errors:
			bad[_error_index(err)] = true
		for i: int in (records as Array).size():
			if not bad.has(i):
				tw.words.append((records as Array)[i])
	else:
		tw.errors.append("%s: words must be an array" % path)
	tw.menu_keys = _key_set(root.get("menu_keys", {}), "%s: menu_keys" % path, tw.errors)
	tw.console_keys = _key_set(root.get("console_keys", {}), "%s: console_keys" % path, tw.errors)
	return tw


## Errors of a `words` array: record shape, id (snake_case, unique), word (lowercase a-z, 3-16, unique), kind.
## Every message starts with `<path>: words[<i>]`.
static func validate_words(records: Array, path: String = PATH) -> PackedStringArray:
	var errs: PackedStringArray = []
	var ids: Dictionary = {}
	var seen: Dictionary = {}
	for i: int in records.size():
		var where: String = "%s: words[%d]" % [path, i]
		if not (records[i] is Dictionary):
			errs.append("%s must be an object" % where)
			continue
		var rec: Dictionary = records[i]
		var id: Variant = rec.get("id")
		if not (id is String) or not _is_id(id):
			errs.append("%s.id must be a snake_case string" % where)
		elif ids.has(id):
			errs.append("%s.id '%s' is not unique" % [where, id])
		else:
			ids[id] = true
		var word: Variant = rec.get("word")
		if not (word is String) or not _is_word(word):
			errs.append("%s.word must be lowercase a-z, %d-%d letters" % [where, WORD_MIN_LEN, WORD_MAX_LEN])
		elif seen.has(word):
			errs.append("%s.word '%s' is not unique" % [where, word])
		else:
			seen[word] = true
		if not (rec.get("kind") is String) or not KINDS.has(rec.get("kind")):
			errs.append("%s.kind must be one of %s" % [where, ", ".join(KINDS)])
	return errs


## word -> id of the records of `kind` ("dev" or "cheat"), for TypedWordMatcher.setup().
func words_of_kind(kind: String) -> Dictionary:
	var out: Dictionary = {}
	for rec: Dictionary in words:
		if rec.get("kind") == kind:
			out[rec["word"]] = rec["id"]
	return out


static func _is_word(w: String) -> bool:
	if w.length() < WORD_MIN_LEN or w.length() > WORD_MAX_LEN:
		return false
	for i: int in w.length():
		var c: int = w.unicode_at(i)
		if c < 97 or c > 122:
			return false
	return true


static func _is_id(s: String) -> bool:
	if s.is_empty() or s.unicode_at(0) < 97 or s.unicode_at(0) > 122:
		return false
	for i: int in s.length():
		var c: int = s.unicode_at(i)
		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
			return false
	return true


# "<path>: words[3]..." -> 3 (-1 when the message is not about a record).
static func _error_index(err: String) -> int:
	var a: int = err.find("words[")
	if a < 0:
		return -1
	var b: int = err.find("]", a)
	return err.substr(a + 6, b - a - 6).to_int()


static func _key_set(src: Variant, where: String, errs: PackedStringArray) -> KeySet:
	var ks: KeySet = KeySet.new()
	if not (src is Dictionary):
		errs.append("%s must be an object" % where)
		return ks
	var d: Dictionary = src
	ks.physical = _key_names(d.get("physical", []), "%s.physical" % where, errs)
	ks.keycodes = _key_names(d.get("keycode", []), "%s.keycode" % where, errs)
	var us: Variant = d.get("unicode", [])
	if us is Array:
		for u: Variant in us:
			if (u is float or u is int) and int(u) > 0:
				ks.unicodes.append(int(u))
			else:
				errs.append("%s.unicode entries must be positive integers" % where)
	else:
		errs.append("%s.unicode must be an array" % where)
	return ks


static func _key_names(src: Variant, where: String, errs: PackedStringArray) -> PackedInt32Array:
	var out: PackedInt32Array = []
	if not (src is Array):
		errs.append("%s must be an array of key names" % where)
		return out
	for n: Variant in src:
		var code: int = OS.find_keycode_from_string(String(n)) if n is String else 0
		if code == KEY_NONE:
			errs.append("%s: unknown key name '%s'" % [where, str(n)])
		else:
			out.append(code)
	return out
