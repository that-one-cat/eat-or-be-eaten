extends TestCase
## S6 presence indicators (GAME_DESIGN section 5): neutral edge-of-screen markers for creatures >= 50% of the player's
## length within 30 m that are OUTSIDE the camera view; front 270 degree sector (rear 90 hidden), 360 with Wide Vision;
## never danger-coded.
##
## API (impl-B owns game/scripts/ui/presence_indicators.gd; confirmed against the code):
##   class PresenceIndicators (res://scripts/ui/presence_indicators.gd), static pure function
##   visible_markers(player: SimEntity, player_basis: Basis, camera: Camera3D, creatures: Array[SimEntity],
##                   sector_deg: float, min_len_ratio: float, radius_m: float) -> Array
##   returning one entry per marker (Dictionary or Object) with an `id` (creature entity id) plus presentation-only
##   fields (screen angle / position). If the file or the function is missing, every test here
##   fails (no skip). If the signature changes, change ONLY _script() and _markers().
## The camera is a Camera3D in the SceneTree behind the player (player faces -Z, camera 5 m behind, identity basis).

const S3 := preload("res://tests/s3_support.gd")
const S6 := preload("res://tests/s6_support.gd")

const PATH: String = "res://scripts/ui/presence_indicators.gd"
const DIST: float = 15.0
const DANGER_KEYS: String = "danger|threat|colo|tint|bigger|smaller|size|ratio|length|scale|hostile|predator|prey"

var _cams: Array[Camera3D] = []


func after_each() -> void:
	for c: Camera3D in _cams:
		if is_instance_valid(c):
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			c.free()
	_cams.clear()


# ---------------------------------------------------------------- adapter (the only place that knows the API)

func _script() -> GDScript:
	if not ResourceLoader.exists(PATH):
		return null
	var s: GDScript = load(PATH) as GDScript
	if s == null:
		return null
	for m: Dictionary in s.get_script_method_list():
		if str(m["name"]) == "visible_markers":
			return s
	return null


## The API exists (impl-B); a missing file/function is a FAILURE, never a skip.
func _api() -> bool:
	var ok: bool = _script() != null
	assert_true(ok, "PresenceIndicators.visible_markers exists in %s" % PATH)
	return ok


func _markers(player: SimEntity, cam: Camera3D, creatures: Array, sector_deg: float, min_ratio: float, radius: float) -> Array:
	var s: GDScript = _script()
	var typed: Array[SimEntity] = []
	for c: Variant in creatures:
		typed.append(c as SimEntity)
	var out: Variant = s.call("visible_markers", player, Basis.IDENTITY, cam, typed, sector_deg, min_ratio, radius)
	return out if out is Array else []


func _marker_id(m: Variant) -> int:
	if m is Dictionary:
		return int((m as Dictionary).get("id", (m as Dictionary).get("creature_id", -1)))
	if m is Object:
		return int((m as Object).get("id"))
	return -1


func _ids(markers: Array) -> Array:
	var out: Array = []
	for m: Variant in markers:
		out.append(_marker_id(m))
	out.sort()
	return out


# ---------------------------------------------------------------- scene

## {"w", "p", "cam", "db"}: player (B3, facing -Z) at a point in open water, camera 5 m behind it.
func _scene() -> Dictionary:
	var w: SimWorld = S6.make_world(91)
	var p: SimEntity = S3.player_at(w, S3.ARENA, 500.0, Vector3.FORWARD)
	var cam := Camera3D.new()
	cam.fov = 75.0
	(Engine.get_main_loop() as SceneTree).root.add_child(cam)
	cam.global_transform = Transform3D(Basis.IDENTITY, p.position + Vector3(0.0, 0.0, 5.0))
	_cams.append(cam)
	return {"w": w, "p": p, "cam": cam}


## Creature `ratio` x the player's length, `dist` m away, `deg` degrees to the left of the player's facing.
func _at(sc: Dictionary, deg: float, ratio: float = 1.0, dist: float = DIST) -> SimEntity:
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["p"]
	var dir: Vector3 = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(deg))
	return S3.npc_at(w, &"grouper", p.position + dir * dist, p.length_m * ratio)


func _rules(sc: Dictionary) -> Dictionary:
	var w: SimWorld = sc["w"]
	var pr: Dictionary = w.content.rules()["presence"]
	return {"ratio": float(pr["min_length_ratio"]), "radius": float(pr["radius_m"]), "sector": float(pr["sector_deg"])}


func _shown(sc: Dictionary, c: SimEntity, sector: float = -1.0, ratio: float = -1.0, radius: float = -1.0) -> bool:
	var rules: Dictionary = _rules(sc)
	var m: Array = _markers(sc["p"], sc["cam"], [c], rules["sector"] if sector < 0.0 else sector, rules["ratio"] if ratio < 0.0 else ratio, rules["radius"] if radius < 0.0 else radius)
	return _ids(m).has(c.id)


# ---------------------------------------------------------------- tests

func test_a_creature_in_view_gets_no_marker() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	assert_false(_shown(sc, _at(sc, 0.0)), "straight ahead = on screen = no marker")


func test_creatures_beside_the_camera_get_markers_on_both_sides() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	for deg in [90.0, 100.0, -90.0, -100.0]:
		assert_true(_shown(sc, _at(sc, deg)), "%s degrees off the facing, outside the view, inside the front sector: marker" % str(deg))


func test_rear_sector_is_hidden_at_270_and_shown_at_360() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var base: float = _rules(sc)["sector"]
	var wide: float = S6.effect_f((sc["w"] as SimWorld).content, &"survivor_wide_vision", "presence_sector_deg")
	assert_eq(base, 270.0, "data: base sector 270")
	assert_eq(wide, 360.0, "data: Wide Vision 360")
	for deg in [150.0, 180.0, -150.0, 210.0]:
		var c: SimEntity = _at(sc, deg)
		assert_false(_shown(sc, c, base), "%s degrees (rear 90 degree wedge): hidden with the base sector" % str(deg))
		assert_true(_shown(sc, c, wide), "%s degrees: shown with Wide Vision" % str(deg))


func test_sector_edge_is_at_half_the_sector_angle() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var base: float = _rules(sc)["sector"]
	var half: float = base * 0.5
	assert_true(_shown(sc, _at(sc, half - 3.0), base), "%s degrees: inside the %s degree sector" % [str(half - 3.0), str(base)])
	assert_false(_shown(sc, _at(sc, half + 3.0), base), "%s degrees: outside" % str(half + 3.0))
	assert_true(_shown(sc, _at(sc, -(half - 3.0)), base), "the sector is symmetric (left/right)")
	assert_false(_shown(sc, _at(sc, -(half + 3.0)), base), "symmetric outside")
	# a custom sector value is honoured, not just the shipped numbers
	assert_false(_shown(sc, _at(sc, 100.0), 180.0), "100 degrees is outside a 180 degree sector")
	assert_true(_shown(sc, _at(sc, 80.0), 180.0), "80 degrees is inside a 180 degree sector")


func test_only_creatures_of_at_least_half_the_players_length() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var min_ratio: float = _rules(sc)["ratio"]
	assert_false(_shown(sc, _at(sc, 90.0, min_ratio * 0.8)), "below the ratio: no marker")
	assert_true(_shown(sc, _at(sc, 90.0, min_ratio * 1.2)), "above the ratio: marker")
	assert_true(_shown(sc, _at(sc, 90.0, min_ratio)), "exactly the ratio counts (>=), assumption A15")
	assert_true(_shown(sc, _at(sc, 90.0, 6.0)), "a giant is marked too")


func test_only_creatures_within_the_radius() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var radius: float = _rules(sc)["radius"]
	assert_true(_shown(sc, _at(sc, 90.0, 1.0, radius - 1.0)), "inside the radius: marker")
	assert_false(_shown(sc, _at(sc, 90.0, 1.0, radius + 1.0)), "outside the radius: none")


func test_the_player_itself_is_never_marked() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var rules: Dictionary = _rules(sc)
	var side: SimEntity = _at(sc, 90.0)
	var m: Array = _markers(sc["p"], sc["cam"], [sc["p"], side], rules["sector"], rules["ratio"], rules["radius"])
	assert_eq(_ids(m), [side.id], "only the other creature")


func test_markers_never_encode_danger() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var rules: Dictionary = _rules(sc)
	var tiny: SimEntity = _at(sc, 90.0, 0.6)
	var huge: SimEntity = _at(sc, -90.0, 8.0)
	var m: Array = _markers(sc["p"], sc["cam"], [tiny, huge], rules["sector"], rules["ratio"], rules["radius"])
	assert_eq(_ids(m).size(), 2, "test setup: both marked")
	var rx := RegEx.new()
	rx.compile("(?i)(%s)" % DANGER_KEYS)
	for mk: Variant in m:
		if mk is Dictionary:
			for k: Variant in (mk as Dictionary).keys():
				assert_null(rx.search(str(k)), "marker field '%s' must not carry size / danger information" % str(k))
	# the same distance and bearing must give an identical marker for a mouse and for a whale (only the id differs)
	var a: Array = _markers(sc["p"], sc["cam"], [_at(sc, 90.0, 0.6)], rules["sector"], rules["ratio"], rules["radius"])
	var b: Array = _markers(sc["p"], sc["cam"], [_at(sc, 90.0, 8.0)], rules["sector"], rules["ratio"], rules["radius"])
	if a.size() == 1 and b.size() == 1 and a[0] is Dictionary and b[0] is Dictionary:
		var da: Dictionary = (a[0] as Dictionary).duplicate()
		var db2: Dictionary = (b[0] as Dictionary).duplicate()
		for k2: String in ["id", "creature_id"]:
			da.erase(k2)
			db2.erase(k2)
		assert_eq(da, db2, "marker payload is identical regardless of the creature's size")


func test_the_function_is_pure() -> void:
	if not _api():
		return
	var sc: Dictionary = _scene()
	var rules: Dictionary = _rules(sc)
	var list: Array = [_at(sc, 90.0), _at(sc, -100.0), _at(sc, 170.0), _at(sc, 0.0)]
	var before: Array = []
	for e: SimEntity in list:
		before.append(e.position)
	var one: Array = _ids(_markers(sc["p"], sc["cam"], list, rules["sector"], rules["ratio"], rules["radius"]))
	var two: Array = _ids(_markers(sc["p"], sc["cam"], list, rules["sector"], rules["ratio"], rules["radius"]))
	assert_eq(one, two, "same input = same markers")
	for i in list.size():
		assert_eq((list[i] as SimEntity).position, before[i], "inputs are not modified")
