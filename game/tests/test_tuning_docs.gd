extends TestCase
## T1.3 tuning lab docs and hash policy (R1-R7): the registry has a docs/data page (frontmatter, the columns, presets,
## export, the state_hash decision) and a row in game/data/README.md. `python3 tools/docs/build.py --check` is part of
## the gate (tools/check.sh), not of this file.

const TS := preload("res://tests/tuning_support.gd")


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


## docs/data pages that ARE the tuning registry reference: they mention god/tuning.json and the registry's own
## surfaces (user://tuning, reports/tuning, GodBuild). Other pages that merely link the file (controls.md, rules.md)
## are skipped.
func _pages() -> Array[String]:
	var out: Array[String] = []
	var dir: String = _repo("docs/data")
	for f: String in TS.files_below(dir):
		if not f.ends_with(".md"):
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(f))
		if text.contains("god/tuning.json") and text.contains("user://tuning") and text.contains("reports/tuning") \
				and text.contains("GodBuild"):
			out.append(dir.path_join(f))
	return out


func test_a_docs_data_page_documents_the_registry() -> void:
	var pages: Array[String] = _pages()
	assert_true(pages.size() >= 1, "a docs/data/*.md page mentions god/tuning.json")
	if pages.is_empty():
		return
	var text: String = FileAccess.get_file_as_string(pages[0])
	assert_true(text.begins_with("---"), "the page starts with R-protocol frontmatter")
	for needle: String in ["area:", "mirrors:", "verified:"]:
		assert_has(text, needle, "frontmatter key %s" % needle)
	for col: String in ["id", "target", "path", "label", "group", "min", "max", "step"]:
		assert_has(text, "`%s`" % col, "the registry column `%s` is documented" % col)
	for topic: String in ["rules", "band", "user://tuning", "reports/tuning", "GodBuild"]:
		assert_has(text, topic, "the page covers: %s" % topic)


func test_the_page_states_the_state_hash_decision() -> void:
	var pages: Array[String] = _pages()
	if pages.is_empty():
		fail("no docs/data page for the registry")
		return
	var text: String = FileAccess.get_file_as_string(pages[0])
	assert_has(text, "state_hash", "the page documents whether the override set enters state_hash")
	assert_true(text.to_lower().contains("empty"), "and says what an EMPTY layer does")


func test_the_data_readme_has_a_row_for_the_registry() -> void:
	var text: String = FileAccess.get_file_as_string(_repo("game/data/README.md"))
	assert_has(text, "tuning.json", "game/data/README.md lists god/tuning.json")
