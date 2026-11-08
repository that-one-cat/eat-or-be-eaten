class_name TuningOverrides
extends RefCounted
## Runtime override layer over the rules (`rules/core.json`) and the size-band tables (T1.3 tuning lab). Pure logic (rule 1).
## Which keys are tunable, and their slider range, is DATA: the registry `data/god/tuning.json` (hard rule 8, schema
## `docs/data/god-tuning.md`). A later subtask adds a tunable key by adding a registry row, no code.
##
## One instance holds `{registry id -> value}` for ONE world; it lives in `SimDebug.State.tuning` (created by
## `SimDebug.tuning(world)`, the only way the God tools reach it) and sits on top of the loaded data: `ContentDB` and the
## JSON files are never modified. The sim reads it through `rule_override()` / `band_override()` (SimWorld `_rule_f` and the
## cached band movement arrays) and refreshes its caches after every change (`SimWorld._retune`), so a change acts on the NEXT
## tick. The layer is empty by default and stays empty in release builds (the only callers are the God tools).
##
## state_hash: an EMPTY layer contributes nothing (`write_state` writes no byte), so every baseline hash is unchanged; a
## NON-empty layer is hashed (id + value, in registry order, so the order of `tune` lines does not matter): the same
## overrides + the same seed give the same hash, and a tuned run never hashes like an untuned one.
##
## Presets: `{"version": 1, "overrides": {"<id>": <number>}}` (only the overridden ids). `save` / `load` use `preset_dir`
## (`user://tuning`), `export` writes `export_dir` (`reports/tuning` inside the repo; refused in an exported build). Names are
## lower-cased and must be `[a-z0-9_-]` (anything else is refused, never mapped to a path). A preset is validated whole
## against the registry (ids, finite numbers, ranges) before anything is applied; `load` REPLACES the current layer.

const REGISTRY_PATH: String = "res://data/god/tuning.json"
const PRESET_VERSION: int = 1
const DEFAULT_PRESET_DIR: String = "user://tuning"
## Relative to the repository root (the parent of the Godot project directory).
const DEFAULT_EXPORT_DIR: String = "reports/tuning"
const NAME_MAX_LEN: int = 48
const TARGET_RULES: String = "rules"
const TARGET_BAND: String = "band"

## Base directories of save / load and export (static so tests can redirect them; the defaults are the two constants above).
static var preset_dir: String = DEFAULT_PRESET_DIR
static var export_dir: String = DEFAULT_EXPORT_DIR

## Valid registry rows in file order (empty when the registry failed validation, see `errors`).
var rows: Array[Dictionary] = []
## Why the registry was rejected ("" entries: none). `create()` leaves `rows` empty on any error.
var errors: PackedStringArray = PackedStringArray()
## Bumped on every change of the override set (panels poll it).
var revision: int = 0

var _content: ContentDB = null
var _by_id: Dictionary = {}  # String -> Dictionary (row)
var _values: Dictionary = {}  # String id -> float
var _rule_values: Dictionary = {}  # String rules path -> float
var _band_values: Dictionary = {}  # String band field -> Array of [band (0 = every band), float]


## Loads and validates `res://data/god/tuning.json` against `content`.
static func create(content: ContentDB) -> TuningOverrides:
	var t := TuningOverrides.new()
	t._content = content
	var doc: Variant = null
	if FileAccess.file_exists(REGISTRY_PATH):
		doc = _parse_json(FileAccess.get_file_as_string(REGISTRY_PATH))
	var list: Variant = (doc as Dictionary).get("entries") if doc is Dictionary else doc
	if not (list is Array):
		t.errors.append("%s: missing or not a JSON object with an `entries` array" % REGISTRY_PATH)
		return t
	t.errors = validate_registry(list, content)
	if not t.errors.is_empty():
		return t
	for item: Variant in (list as Array):
		var row: Dictionary = item
		t.rows.append(row)
		t._by_id[String(row["id"])] = row
	return t


# ------------------------------------------------------------------ registry validation

## Error strings for the registry rows `entries` (empty = valid). `content` supplies the shipped rules and band tables the
## paths are checked against (null: only the syntax is checked).
static func validate_registry(entries: Array, content: ContentDB) -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Dictionary = {}
	var keys: Dictionary = {}
	for i: int in entries.size():
		if not (entries[i] is Dictionary):
			out.append("row %d: not an object" % i)
			continue
		var e: Dictionary = entries[i]
		var tag: String = "row %d" % i
		var id_v: Variant = e.get("id")
		if not (id_v is String) or not _is_ident(id_v):
			out.append("%s: id must be a snake_case string (a-z, 0-9, _, starting with a letter)" % tag)
		else:
			tag = "row %d (%s)" % [i, id_v]
			if ids.has(id_v):
				out.append("%s: duplicate id" % tag)
			ids[id_v] = true
		var target_v: Variant = e.get("target")
		var target: String = target_v if target_v is String else ""
		if target != TARGET_RULES and target != TARGET_BAND:
			out.append("%s: target must be \"rules\" or \"band\"" % tag)
		var path_v: Variant = e.get("path")
		if not (path_v is String) or (path_v as String).is_empty():
			out.append("%s: path must be a non-empty string" % tag)
		elif target == TARGET_RULES or target == TARGET_BAND:
			var path_err: String = _path_error(target, path_v, content)
			if not path_err.is_empty():
				out.append("%s: %s" % [tag, path_err])
		for f: String in ["label", "group"]:
			if not (e.get(f) is String) or (e.get(f) as String).strip_edges().is_empty():
				out.append("%s: %s must be a non-empty string" % [tag, f])
		var finite: bool = true
		for f: String in ["min", "max", "step"]:
			if not _is_finite_number(e.get(f)):
				out.append("%s: %s must be a finite number" % [tag, f])
				finite = false
		if finite:
			if float(e["min"]) >= float(e["max"]):
				out.append("%s: min must be below max (range)" % tag)
			if float(e["step"]) <= 0.0:
				out.append("%s: step must be above 0" % tag)
		var band: int = 0
		if e.has("band"):
			var band_v: Variant = e["band"]
			var bands: int = content.band_count() if content != null else 0
			var band_ok: bool = target == TARGET_BAND and _is_finite_number(band_v) and float(band_v) == floorf(float(band_v)) \
					and int(band_v) >= 1 and (content == null or int(band_v) <= bands)
			if band_ok:
				band = int(band_v)
			else:
				out.append("%s: band must be a size band index (1..%d) and only on a band row" % [tag, bands])
		var pair: String = "%s:%s:%d" % [target, path_v, band]
		if keys.has(pair):
			out.append("%s: duplicate target + path (%s)" % [tag, pair])
		keys[pair] = true
	return out


# The reason `path` cannot be tuned under `target`, "" when it can: simple lower-case key names, and a number in the shipped data.
static func _path_error(target: String, path: String, content: ContentDB) -> String:
	var parts: PackedStringArray = path.split(".")
	if target == TARGET_BAND and parts.size() != 1:
		return "path '%s' is not a band field name" % path
	for part: String in parts:
		if not _is_ident(part, true):
			return "path '%s' is not a plain key path (a-z, 0-9, _ and dots)" % path
	if content == null:
		return ""
	if target == TARGET_RULES:
		var cur: Variant = content.rules()
		for part: String in parts:
			if not (cur is Dictionary) or not (cur as Dictionary).has(part):
				return "path '%s' does not exist in rules/core.json (unknown key)" % path
			cur = (cur as Dictionary)[part]
		return "" if _is_number(cur) else "path '%s' is not a numeric rules value" % path
	if content.band_count() < 1:
		return "no size bands to check path '%s' against" % path
	for b: int in range(1, content.band_count() + 1):
		if not _is_number(content.get_band(b).get(path)):
			return "path '%s' is not a numeric field of every size band (unknown field)" % path
	return ""


# ------------------------------------------------------------------ values

func has_row(id: String) -> bool:
	return _by_id.has(id)


## The registry row of `id` (empty for an unknown id).
func get_row(id: String) -> Dictionary:
	return _by_id.get(id, {})


## True when no id is overridden.
func is_empty() -> bool:
	return _values.is_empty()


func is_overridden(id: String) -> bool:
	return _values.has(id)


## Overridden ids in registry order.
func overridden_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for row: Dictionary in rows:
		if _values.has(row["id"]):
			out.append(row["id"])
	return out


## The shipped data value of `id`; for a band row the value of `band` (the row's own band when it has one). NAN when unknown.
func data_value(id: String, band: int = 1) -> float:
	var row: Dictionary = get_row(id)
	if row.is_empty() or _content == null:
		return NAN
	var path: String = row["path"]
	if row["target"] == TARGET_RULES:
		var cur: Variant = _content.rules()
		for part: String in path.split("."):
			cur = (cur as Dictionary).get(part) if cur is Dictionary else null
		return float(cur) if _is_number(cur) else NAN
	var which: int = int(row.get("band", band))
	var v: Variant = _content.get_band(clampi(which, 1, maxi(_content.band_count(), 1))).get(path)
	return float(v) if _is_number(v) else NAN


## The value in force for `id`: the override, else the data value (of `band` for a band row).
func value(id: String, band: int = 1) -> float:
	return float(_values[id]) if _values.has(id) else data_value(id, band)


## Data value(s) of `id` as text: one number, or "lo..hi" when the bands differ.
func data_text(id: String) -> String:
	var row: Dictionary = get_row(id)
	if row.is_empty() or _content == null:
		return ""
	if row["target"] == TARGET_RULES or row.has("band"):
		return String.num(data_value(id), 6)
	var lo: float = INF
	var hi: float = -INF
	for b: int in range(1, _content.band_count() + 1):
		var v: float = data_value(id, b)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return String.num(lo, 6) if is_equal_approx(lo, hi) else "%s..%s" % [String.num(lo, 6), String.num(hi, 6)]


## "" when `v` is a finite number inside the range of the row `id`, else why not.
func check_value(id: String, v: Variant) -> String:
	var row: Dictionary = get_row(id)
	if row.is_empty():
		return "unknown tuning id '%s'" % id
	if not _is_finite_number(v):
		return "'%s': the value must be a finite number" % id
	var f: float = float(v)
	if f < float(row["min"]) or f > float(row["max"]):
		return "'%s': %s is outside the range %s..%s" % [id, String.num(f, 6), String.num(float(row["min"]), 6), String.num(float(row["max"]), 6)]
	return ""


## Sets the override of `id`. Returns "" on success, else why it was refused (nothing changes).
func set_value(id: String, v: Variant) -> String:
	var err: String = check_value(id, v)
	if err.is_empty():
		_values[id] = float(v)
		_changed()
	return err


## Removes the override of `id`. Returns false for an unknown id.
func reset(id: String) -> bool:
	if not _by_id.has(id):
		return false
	if _values.erase(id):
		_changed()
	return true


func reset_all() -> void:
	if not _values.is_empty():
		_values.clear()
		_changed()


## Override of the rules number at `path` (dotted), null when there is none.
func rule_override(path: String) -> Variant:
	return _rule_values.get(path)


## Value of band field `field` for size band `band`: the last override that applies, else `fallback`.
func band_override(field: String, band: int, fallback: float) -> float:
	var list: Variant = _band_values.get(field)
	if list == null:
		return fallback
	var out: float = fallback
	for rec: Array in (list as Array):
		if int(rec[0]) == 0 or int(rec[0]) == band:
			out = float(rec[1])
	return out


## state_hash input: nothing at all while the layer is empty.
func write_state(buf: StreamPeerBuffer) -> void:
	if _values.is_empty():
		return
	buf.put_utf8_string("tuning")
	buf.put_32(_values.size())
	for row: Dictionary in rows:
		if _values.has(row["id"]):
			buf.put_utf8_string(row["id"])
			buf.put_double(_values[row["id"]])


func _changed() -> void:
	revision += 1
	_rule_values.clear()
	_band_values.clear()
	for row: Dictionary in rows:
		var id: String = row["id"]
		if not _values.has(id):
			continue
		if row["target"] == TARGET_RULES:
			_rule_values[row["path"]] = _values[id]
		else:
			if not _band_values.has(row["path"]):
				_band_values[row["path"]] = []
			(_band_values[row["path"]] as Array).append([int(row.get("band", 0)), _values[id]])


# ------------------------------------------------------------------ presets

## The preset document of the current layer.
func to_document() -> Dictionary:
	var ov: Dictionary = {}
	for row: Dictionary in rows:
		if _values.has(row["id"]):
			ov[row["id"]] = _values[row["id"]]
	return {"version": PRESET_VERSION, "overrides": ov}


## Validates a parsed preset document against the registry. {"error": String, "values": Dictionary}; `error` "" = valid.
func check_document(doc: Variant) -> Dictionary:
	var fail := func(msg: String) -> Dictionary: return {"error": msg, "values": {}}
	if not (doc is Dictionary):
		return fail.call("the preset is not valid JSON or not a JSON object")
	var version: Variant = (doc as Dictionary).get("version")
	if not _is_finite_number(version) or int(version) != PRESET_VERSION:
		return fail.call("unsupported preset version (expected %d)" % PRESET_VERSION)
	var ov: Variant = (doc as Dictionary).get("overrides")
	if not (ov is Dictionary):
		return fail.call("the preset has no `overrides` object")
	var values: Dictionary = {}
	for key: Variant in (ov as Dictionary).keys():
		var id: String = str(key)
		var err: String = check_value(id, (ov as Dictionary)[key])
		if not err.is_empty():
			return fail.call(err)
		values[id] = float((ov as Dictionary)[key])
	return {"error": "", "values": values}


## Lower-cased `name` when it is a legal preset name ([a-z0-9_-], 1..NAME_MAX_LEN), "" when it is refused.
static func sanitize_name(name: String) -> String:
	var n: String = name.to_lower()
	if n.is_empty() or n.length() > NAME_MAX_LEN:
		return ""
	for i: int in n.length():
		var c: int = n.unicode_at(i)
		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
			return ""
	return n


## Where `export` writes: `export_dir`, or for the default the repo's reports/tuning ("" in an exported build, where the
## project directory is not a repository).
static func resolved_export_dir() -> String:
	if export_dir != DEFAULT_EXPORT_DIR:
		return export_dir
	if not OS.has_feature("editor"):
		return ""
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(DEFAULT_EXPORT_DIR).simplify_path()


## Writes the current layer to `<preset_dir>/<name>.json`. Returns "" or the reason it failed.
func save_preset(name: String) -> String:
	return _write(preset_dir, name)


## Writes the current layer to `<export dir>/<name>.json` (reports/tuning in the repo). Returns "" or the reason.
func export_preset(name: String) -> String:
	var dir: String = resolved_export_dir()
	if dir.is_empty():
		return "export is refused in an exported build (reports/tuning exists only in the repository)"
	return _write(dir, name)


## Replaces the layer with the preset `<preset_dir>/<name>.json`. Returns "" or the reason; on any problem nothing changes.
func load_preset(name: String) -> String:
	var n: String = sanitize_name(name)
	if n.is_empty():
		return _bad_name(name)
	var path: String = preset_dir.path_join(n + ".json")
	if not FileAccess.file_exists(path):
		return "preset '%s' not found" % n
	var res: Dictionary = check_document(_parse_json(FileAccess.get_file_as_string(path)))
	if not String(res["error"]).is_empty():
		return "preset '%s' rejected: %s" % [n, res["error"]]
	_values = res["values"]
	_changed()
	return ""


func _write(dir: String, name: String) -> String:
	var n: String = sanitize_name(name)
	if n.is_empty():
		return _bad_name(name)
	var made: int = DirAccess.make_dir_recursive_absolute(dir)
	if made != OK and made != ERR_ALREADY_EXISTS:
		return "cannot create the directory %s (error %d)" % [dir, made]
	var path: String = dir.path_join(n + ".json")
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s (error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(to_document(), "\t") + "\n")
	f.close()
	return ""


static func _bad_name(name: String) -> String:
	return "bad preset name '%s': use 1-%d characters of a-z, 0-9, _ and -" % [name, NAME_MAX_LEN]


# ------------------------------------------------------------------ small helpers

# Parsed JSON, null when `text` is not valid JSON (no engine error is printed, unlike JSON.parse_string).
static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _is_finite_number(v: Variant) -> bool:
	return _is_number(v) and is_finite(float(v))


# a-z, 0-9 and _ only; must start with a letter unless `digits_first` (path segments may start with a digit).
static func _is_ident(s: String, digits_first: bool = false) -> bool:
	if s.is_empty():
		return false
	for i: int in s.length():
		var c: int = s.unicode_at(i)
		var letter: bool = c >= 97 and c <= 122
		var digit: bool = c >= 48 and c <= 57
		if not (letter or digit or c == 95) or (i == 0 and not letter and not digits_first):
			return false
	return true
