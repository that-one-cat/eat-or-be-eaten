extends TestCase
## Bot extension (X3, research 7.4 last paragraph / 7.5 item 6): the S3 balance bot (tests/bots/bot_player.gd) must go
## for food sites. Behavioural, deterministic, SimCommands only: a bot placed near one isolated site eats it within 40 s.
## The balance numbers themselves (bot median run 20-30 min, B1 median ~3 min, 10/10 wins) are produced by
## `run_bot.tscn -- --balance --seeds=10` and are CAPTURE/RUN-ONLY, never asserted here.
## PENDING while the bot has no food awareness (its source does not mention food sites).

const F := preload("res://tests/food_support.gd")
const S3 := preload("res://tests/s3_support.gd")
const BotPlayer := preload("res://tests/bots/bot_player.gd")

const BOT_TICKS: int = 30 * 40
const START_DISTANCE_M: float = 6.0


func _bot_knows_food() -> bool:
	var src: String = FileAccess.get_file_as_string(F.BOT_SCRIPT)
	return src.contains(".food") or src.contains("sites_near_into")


func _bot_scene(type: StringName) -> Dictionary:
	if not F.require(self, PackedStringArray([] if _bot_knows_food() else ["bot_player.gd food-site awareness (X3)"])):
		return {}
	var w: SimWorld = F.make_world(901)
	if not F.require_food(self, w):
		return {}
	var site: Dictionary = F.place_site(w, type)
	if site.is_empty():
		F.pending(self, "no site of type %s" % type)
		return {}
	var a: Dictionary = F.approach(w, site["pos"], START_DISTANCE_M, 0.5)
	if a.is_empty():
		fail("setup: no free start point %.0f m from the site" % START_DISTANCE_M)
		return {}
	var p: SimEntity = S3.player_at(w, a["pos"], 0.0, a["heading"])
	return {"w": w, "p": p, "site": site}


func _fly_bot(sc: Dictionary) -> Array[SimEvent]:
	var w: SimWorld = sc["w"]
	var p: SimEntity = sc["p"]
	var bot = BotPlayer.new(w, p.id, 901)
	var all: Array[SimEvent] = []
	for i in BOT_TICKS:
		for c in bot.commands():
			w.submit(c)
		w.step()
		var evs: Array[SimEvent] = w.events_since(w.tick - 1)
		bot.observe(evs)
		all.append_array(evs)
		if not F.named_for(all, F.EV_EATEN, int(sc["site"]["id"])).is_empty():
			break
	return all


func test_the_bot_swallows_an_egg_site_within_40_seconds() -> void:
	var sc: Dictionary = _bot_scene(F.T_EGG_PEACH)
	if sc.is_empty():
		return
	var evs: Array[SimEvent] = _fly_bot(sc)
	assert_eq(F.named_for(evs, F.EV_EATEN, int(sc["site"]["id"])).size(), 1, "the bot ate the only food around")


func test_the_bot_kills_a_starfish_with_bites_within_40_seconds() -> void:
	var sc: Dictionary = _bot_scene(F.T_STARFISH)
	if sc.is_empty():
		return
	var evs: Array[SimEvent] = _fly_bot(sc)
	assert_true(F.named_for(evs, F.EV_BITTEN, int(sc["site"]["id"])).size() >= 1, "the bot bit the starfish")
	assert_eq(F.named_for(evs, F.EV_EATEN, int(sc["site"]["id"])).size(), 1, "and killed it")


func test_the_bot_run_is_deterministic_with_food() -> void:
	var a: Dictionary = _bot_scene(F.T_EGG_PEACH)
	var b: Dictionary = _bot_scene(F.T_EGG_PEACH)
	if a.is_empty() or b.is_empty():
		return
	_fly_bot(a)
	_fly_bot(b)
	assert_eq((a["w"] as SimWorld).state_hash(), (b["w"] as SimWorld).state_hash(), "same seed, same bot, same hash")
