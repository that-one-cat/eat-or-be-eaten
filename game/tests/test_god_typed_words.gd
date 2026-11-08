extends TestCase
## T1.1 typed-word unlock: TypedWordMatcher (pure logic, injected clock), the word / key data file (TypedWords) and its
## validator. Includes the Russian layout (unicode is Cyrillic, the physical key is the US letter).

const G := preload("res://tests/god_support.gd")
const TMP_FILE: String = "user://test_god_words.json"


func after_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_FILE))


func _matcher() -> TypedWordMatcher:
	var m := TypedWordMatcher.new()
	m.setup({"eatgod": "god"})
	return m


# ---------------------------------------------------------------- matcher

func test_word_typed_with_unicode_matches() -> void:
	assert_eq(G.type_word(_matcher(), "eatgod"), &"god", "e,a,t,g,o,d completes the word and returns its id")


func test_partial_word_does_not_match() -> void:
	assert_eq(G.type_word(_matcher(), "eatgo"), &"", "eatgo")
	assert_eq(G.type_word(_matcher(), "atgod"), &"", "atgod")


func test_word_matches_as_a_suffix_after_other_letters() -> void:
	assert_eq(G.type_word(_matcher(), "xxeatgod"), &"god", "garbage before the word is fine")


func test_extra_letter_after_the_word_matches_once_at_the_sixth_letter() -> void:
	var m: TypedWordMatcher = _matcher()
	assert_eq(G.type_word(m, "eatgod"), &"god", "first completion")
	assert_eq(m.feed_event(G.latin("d"), 1.0), &"", "the seventh letter does not re-fire")


func test_buffer_is_cleared_after_a_match() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eatgod")
	assert_eq(G.type_word(m, "god", 1.0), &"", "'god' alone after a match is not the word")
	assert_eq(G.type_word(m, "eatgod", 2.0), &"god", "typing it again matches again")


func test_long_gap_between_letters_forgets_the_word() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eat", 0.0)
	assert_eq(G.type_word(m, "god", 0.0 + TypedWordMatcher.TIMEOUT_S + 0.5), &"", "a pause longer than TIMEOUT_S empties the buffer")
	var m2: TypedWordMatcher = _matcher()
	assert_eq(G.type_word(m2, "eatgod", 0.0, TypedWordMatcher.TIMEOUT_S - 0.2), &"god", "gaps just under the timeout keep the word alive")


func test_space_or_digit_inside_the_word_breaks_it() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eat")
	m.feed_event(G.key(32, KEY_SPACE), 0.5)
	assert_eq(G.type_word(m, "god", 0.6), &"", "'eat god' with a space does not unlock")
	var m2: TypedWordMatcher = _matcher()
	G.type_word(m2, "eat")
	m2.feed_event(G.key(49, KEY_1), 0.5)
	assert_eq(G.type_word(m2, "god", 0.6), &"", "a digit in the middle breaks it")


func test_russian_layout_physical_keys_match() -> void:
	assert_eq(G.type_word(_matcher(), "eatgod", 0.0, 0.1, true), &"god", "Cyrillic unicode, US physical keys: matches")


func test_russian_layout_with_garbage_before_still_matches() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "qq", 0.0, 0.1, true)
	assert_eq(G.type_word(m, "eatgod", 0.3, 0.1, true), &"god", "suffix of the physical buffer")


func test_physical_only_event_without_unicode_matches() -> void:
	var m: TypedWordMatcher = _matcher()
	var hit: StringName = &""
	for c: String in "eatgod":
		hit = m.feed_event(G.key(0, c.to_upper().unicode_at(0)), 0.0)
	assert_eq(hit, &"god", "physical_keycode alone (no unicode) is enough")


func test_echo_and_release_events_are_ignored() -> void:
	var m: TypedWordMatcher = _matcher()
	var hit: StringName = &""
	var t: float = 0.0
	for c: String in "eatgod":
		m.feed_event(G.latin(c, false), t)  # release first
		m.feed_event(G.key(c.unicode_at(0), c.to_upper().unicode_at(0), true, true), t)  # echo (held key repeat)
		hit = m.feed_event(G.latin(c), t)
		t += 0.1
	assert_eq(hit, &"god", "releases and echoes do not pollute the buffer")


func test_echo_alone_never_completes_a_word() -> void:
	var m: TypedWordMatcher = _matcher()
	for c: String in "eatgod":
		assert_eq(m.feed_event(G.key(c.unicode_at(0), c.to_upper().unicode_at(0), true, true), 0.0), &"", "echo of %s" % c)


func test_ctrl_alt_meta_combos_are_ignored_not_breaking() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eat")
	for mod: String in ["ctrl", "alt", "meta"]:
		var ev: InputEventKey = G.latin("x")
		ev.ctrl_pressed = mod == "ctrl"
		ev.alt_pressed = mod == "alt"
		ev.meta_pressed = mod == "meta"
		assert_eq(m.feed_event(ev, 0.3), &"", "%s+x is swallowed silently" % mod)
	assert_eq(G.type_word(m, "god", 0.4), &"god", "the combos did not reset or pollute the buffer")


func test_shift_alone_does_not_reset_the_buffer() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eat")
	m.feed_event(G.key(0, KEY_SHIFT, true, false, KEY_SHIFT), 0.3)
	assert_eq(G.type_word(m, "god", 0.4), &"god", "Shift between letters is ignored")


func test_uppercase_typing_matches() -> void:
	var m: TypedWordMatcher = _matcher()
	var hit: StringName = &""
	for c: String in "EATGOD":
		hit = m.feed_event(G.key(c.unicode_at(0), c.unicode_at(0), true, false, c.unicode_at(0)), 0.0)
	assert_eq(hit, &"god", "Shift/CapsLock letters are lower-cased")


func test_non_key_events_are_ignored() -> void:
	var m: TypedWordMatcher = _matcher()
	assert_eq(m.feed_event(InputEventMouseButton.new(), 0.0), &"", "mouse event")
	assert_eq(m.feed_event(InputEventAction.new(), 0.0), &"", "action event")


func test_reset_clears_a_half_typed_word() -> void:
	var m: TypedWordMatcher = _matcher()
	G.type_word(m, "eat")
	m.reset()
	assert_eq(G.type_word(m, "god", 0.1), &"", "after reset the 'eat' is forgotten")


func test_two_words_each_report_their_own_id() -> void:
	var m := TypedWordMatcher.new()
	m.setup({"eatgod": "god", "fishy": "fish"})
	assert_eq(G.type_word(m, "fishy"), &"fish", "second word")
	assert_eq(G.type_word(m, "eatgod", 1.0), &"god", "first word")


# ---------------------------------------------------------------- data file

func test_shipped_word_file_is_valid_and_has_eatgod() -> void:
	var tw: TypedWords = TypedWords.load_file()
	assert_eq(tw.errors.size(), 0, "no errors: %s" % [tw.errors])
	assert_eq(tw.words_of_kind("dev"), {"eatgod": "god"}, "the dev word list")
	assert_eq(tw.words_of_kind("cheat").size(), 0, "no cheat words shipped yet (T7.2)")


func test_shipped_menu_and_console_keys() -> void:
	var tw: TypedWords = TypedWords.load_file()
	assert_has(tw.menu_keys.physical, KEY_F1, "F1 opens the menu")
	assert_has(tw.menu_keys.physical, KEY_F4, "F4 is the second binding")
	assert_has(tw.menu_keys.physical, KEY_M, "M is the third binding (laptops where F-keys need Fn)")
	assert_has(tw.console_keys.physical, KEY_QUOTELEFT, "backtick physical key")
	for u: int in [96, 126, 1105, 1025]:
		assert_has(tw.console_keys.unicodes, u, "unicode %d opens the console (Latin ` ~ and Russian ё Ё)" % u)


func test_menu_key_set_matching() -> void:
	var ks: TypedWords.KeySet = TypedWords.load_file().menu_keys
	assert_true(ks.matches(G.f1()), "F1")
	assert_true(ks.matches(G.key(0, KEY_F4)), "F4")
	assert_true(ks.matches(G.key(0, KEY_M)), "M")
	assert_false(ks.matches(G.key(0, KEY_F2)), "F2 is not bound")
	assert_false(ks.matches(G.key(0, KEY_F1, false)), "release")
	assert_false(ks.matches(G.key(0, KEY_F1, true, true)), "echo")
	var ctrl: InputEventKey = G.f1()
	ctrl.ctrl_pressed = true
	assert_false(ks.matches(ctrl), "ctrl+F1")
	assert_false(ks.matches(G.latin("e")), "a letter")


func test_console_key_set_matching_layouts() -> void:
	var ks: TypedWords.KeySet = TypedWords.load_file().console_keys
	assert_true(ks.matches(G.backtick()), "US backtick: physical + keycode + unicode")
	assert_true(ks.matches(G.key(126, KEY_QUOTELEFT, true, false, KEY_ASCIITILDE)), "shift+backtick = ~")
	assert_true(ks.matches(G.key(1105, KEY_QUOTELEFT)), "Russian layout: the same physical key types ё")
	assert_true(ks.matches(G.key(1105, KEY_NONE)), "ё by unicode only (layout reports another physical code)")
	assert_true(ks.matches(G.key(1025, KEY_NONE)), "Ё by unicode only")
	assert_true(ks.matches(G.key(126, KEY_NONE)), "~ by unicode only")
	assert_false(ks.matches(G.latin("a")), "plain a")
	assert_false(ks.matches(G.key(0, KEY_NONE)), "empty event (unicode 0) must not match the unicode list")
	var alt: InputEventKey = G.backtick()
	alt.alt_pressed = true
	assert_false(ks.matches(alt), "alt+backtick")


# ---------------------------------------------------------------- validator

func _rec(id: String, word: String, kind: String = "dev") -> Dictionary:
	return {"id": id, "word": word, "kind": kind}


func test_validator_accepts_good_records() -> void:
	assert_eq(TypedWords.validate_words([_rec("god", "eatgod"), _rec("c_1", "abc", "cheat")]).size(), 0, "dev + cheat")


func test_validator_errors_are_path_qualified() -> void:
	var path: String = "res://data/god/typed_words.json"
	var cases: Array[Array] = [
		[_rec("god", "EatGod"), "words[0].word", "uppercase"],
		[_rec("god", "ab"), "words[0].word", "too short"],
		[_rec("god", "abcdefghijklmnopq"), "words[0].word", "too long (17)"],
		[_rec("god", "eat god"), "words[0].word", "space"],
		[_rec("god", "eatg0d"), "words[0].word", "digit"],
		[_rec("Bad Id", "eatgod"), "words[0].id", "bad id"],
		[_rec("", "eatgod"), "words[0].id", "empty id"],
		[_rec("god", "eatgod", "root"), "words[0].kind", "bad kind"],
		[{"id": "god", "word": "eatgod"}, "words[0].kind", "missing kind"],
	]
	for c: Array in cases:
		var errs: PackedStringArray = TypedWords.validate_words([c[0]], path)
		var hit: bool = false
		for e: String in errs:
			if e.begins_with(path + ": ") and e.contains(c[1]):
				hit = true
		assert_true(hit, "%s: expected an error with '%s', got %s" % [c[2], c[1], errs])


func test_validator_rejects_duplicates_and_non_objects() -> void:
	var dup_word: PackedStringArray = TypedWords.validate_words([_rec("a", "eatgod"), _rec("b", "eatgod")])
	assert_eq(dup_word.size(), 1, "duplicate word: one error")
	assert_true(dup_word.size() == 1 and dup_word[0].contains("words[1].word") and dup_word[0].contains("not unique"), "points at the second record: %s" % [dup_word])
	var dup_id: PackedStringArray = TypedWords.validate_words([_rec("a", "eatgod"), _rec("a", "other")])
	assert_true(dup_id.size() == 1 and dup_id[0].contains("words[1].id"), "duplicate id: %s" % [dup_id])
	var non_obj: PackedStringArray = TypedWords.validate_words(["eatgod"])
	assert_true(non_obj.size() == 1 and non_obj[0].contains("words[0] must be an object"), "non-object record: %s" % [non_obj])


func test_load_file_skips_bad_records_and_keeps_good_ones() -> void:
	G.write_json(TMP_FILE, {"words": [_rec("god", "eatgod"), _rec("bad", "BAD"), _rec("god2", "eatgod")],
		"menu_keys": {"physical": ["F1"]}, "console_keys": {"physical": ["QuoteLeft"]}})
	var tw: TypedWords = TypedWords.load_file(TMP_FILE)
	assert_eq(tw.words.size(), 1, "only the first valid record survives")
	assert_eq(tw.words[0]["id"], "god", "the surviving record")
	assert_true(tw.errors.size() >= 2, "both bad records reported: %s" % [tw.errors])
	for e: String in tw.errors:
		assert_true(e.begins_with(TMP_FILE + ": "), "path-qualified: %s" % e)


func test_load_file_survives_a_missing_or_malformed_file() -> void:
	var missing: TypedWords = TypedWords.load_file("user://does_not_exist_god.json")
	assert_eq(missing.words.size(), 0, "no words")
	assert_true(missing.errors.size() >= 1, "reported")
	var f: FileAccess = FileAccess.open(TMP_FILE, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var bad: TypedWords = TypedWords.load_file(TMP_FILE)
	assert_eq(bad.words.size(), 0, "malformed JSON gives no words")
	assert_true(bad.errors.size() >= 1, "and an error")


func test_load_file_reports_unknown_key_names() -> void:
	G.write_json(TMP_FILE, {"words": [], "menu_keys": {"physical": ["F1", "NotAKey"]}, "console_keys": {"unicode": [0, "x"]}})
	var tw: TypedWords = TypedWords.load_file(TMP_FILE)
	var joined: String = "\n".join(tw.errors)
	assert_true(joined.contains("NotAKey"), "unknown key name named in the error: %s" % joined)
	assert_true(joined.contains("unicode entries"), "bad unicode entries reported: %s" % joined)
	assert_has(tw.menu_keys.physical, KEY_F1, "the valid key still loads")
