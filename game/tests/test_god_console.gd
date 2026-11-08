extends TestCase
## T1.1 command registry (GodCommands) and the console node (GodConsole): tokenising, help, unknown / empty input,
## duplicate registration, nil / non-string results, quick-button providers, history, open / close signals and keys,
## the F1 menu's panel registry (GodMenu).

const G := preload("res://tests/god_support.gd")

var _nodes: Array[Node] = []


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _tree_root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


# Adds `n` to the tree and waits a frame: nodes added before the main loop has run are not yet "inside the tree".
func _adopt(n: Node) -> void:
	_tree_root().add_child(n)
	_nodes.append(n)
	await (Engine.get_main_loop() as SceneTree).process_frame


func _console(cmds: GodCommands = null) -> GodConsole:
	var c := GodConsole.new()
	await _adopt(c)
	c.commands = cmds if cmds != null else GodCommands.with_builtins()
	c.context = GodContext.new()
	c.close_keys = TypedWords.load_file().console_keys
	return c


func _echo_registry() -> GodCommands:
	var cmds: GodCommands = GodCommands.with_builtins()
	cmds.register(&"echo", "print the arguments, bracketed", _h_echo, "echo <words...>")
	return cmds


func _h_echo(args: PackedStringArray, _ctx: GodContext) -> String:
	return "|".join(args)


# ---------------------------------------------------------------- tokenizer

func test_tokenize_whitespace_and_extra_spaces() -> void:
	assert_eq(GodCommands.tokenize("  tp   cave\t now  "), PackedStringArray(["tp", "cave", "now"]), "runs of blanks collapse")
	assert_eq(GodCommands.tokenize(""), PackedStringArray(), "empty")
	assert_eq(GodCommands.tokenize("   \t "), PackedStringArray(), "blank")


func test_tokenize_quotes_group_words() -> void:
	assert_eq(GodCommands.tokenize("echo \"a  b\" c"), PackedStringArray(["echo", "a  b", "c"]), "double quotes")
	assert_eq(GodCommands.tokenize("echo 'x y'"), PackedStringArray(["echo", "x y"]), "single quotes")
	assert_eq(GodCommands.tokenize("echo \"it's\""), PackedStringArray(["echo", "it's"]), "the other quote inside is literal")
	assert_eq(GodCommands.tokenize("echo \"\" z"), PackedStringArray(["echo", "", "z"]), "an empty quoted token is kept")
	assert_eq(GodCommands.tokenize("echo \"open"), PackedStringArray(["echo", "open"]), "an unterminated quote takes the rest")


# ---------------------------------------------------------------- registry

func test_execute_runs_handler_with_args_case_insensitive() -> void:
	var cmds: GodCommands = _echo_registry()
	var ctx := GodContext.new()
	assert_eq(cmds.execute("echo a b", ctx), "a|b", "args passed without the command name")
	assert_eq(cmds.execute("ECHO A", ctx), "A", "command name is case-insensitive, args keep their case")
	assert_eq(cmds.execute("  echo   \"x  y\"  ", ctx), "x  y", "quotes and padding")


func test_unknown_and_empty_lines() -> void:
	var cmds: GodCommands = GodCommands.with_builtins()
	var ctx := GodContext.new()
	assert_eq(cmds.execute("", ctx), "", "empty line: nothing")
	assert_eq(cmds.execute("   ", ctx), "", "blank line: nothing")
	var out: String = cmds.execute("frobnicate 1 2", ctx)
	assert_has(out, "unknown command, try help", "unknown command answer")
	assert_has(out, "frobnicate", "names the offending word")


func test_help_lists_every_registered_command() -> void:
	var cmds: GodCommands = _echo_registry()
	var text: String = cmds.execute("help", GodContext.new())
	for n: String in cmds.names():
		assert_has(text, n, "help lists '%s'" % n)
	for builtin: String in ["help", "clear", "menu", "close", "echo"]:
		assert_true(cmds.has_command(StringName(builtin)), "registered: %s" % builtin)


func test_help_command_prints_usage_and_handles_unknown() -> void:
	var cmds: GodCommands = _echo_registry()
	var ctx := GodContext.new()
	var usage: String = cmds.execute("help echo", ctx)
	assert_has(usage, "print the arguments", "help text")
	assert_has(usage, "echo <words...>", "usage line")
	assert_has(cmds.execute("help nosuch", ctx), "unknown command", "help of an unknown command")
	assert_has(cmds.execute("HELP ECHO", ctx), "usage", "case-insensitive help argument")


func test_names_are_sorted_and_lowercase() -> void:
	var cmds := GodCommands.new()
	cmds.register(&"Zed", "z", func(_a: PackedStringArray, _c: GodContext) -> String: return "")
	cmds.register(&"alpha", "a", func(_a: PackedStringArray, _c: GodContext) -> String: return "")
	assert_eq(cmds.names(), PackedStringArray(["alpha", "zed"]), "sorted, lower-cased")
	assert_true(cmds.has_command(&"ZED"), "has_command is case-insensitive")


func test_duplicate_registration_replaces_and_reports() -> void:
	var cmds := GodCommands.new()
	assert_false(cmds.register(&"x", "first", func(_a: PackedStringArray, _c: GodContext) -> String: return "one"), "first registration: not a replacement")
	assert_true(cmds.register(&"x", "second", func(_a: PackedStringArray, _c: GodContext) -> String: return "two"), "second: reports the replacement")
	assert_eq(cmds.execute("x", GodContext.new()), "two", "the newer handler wins")
	assert_eq(cmds.names().size(), 1, "still one command")


func test_handler_results_nil_and_non_string_do_not_crash() -> void:
	var cmds := GodCommands.new()
	cmds.register(&"nothing", "returns nothing", func(_a: PackedStringArray, _c: GodContext) -> Variant: return null)
	cmds.register(&"number", "returns an int", func(_a: PackedStringArray, _c: GodContext) -> Variant: return 42)
	var ctx := GodContext.new()
	assert_eq(cmds.execute("nothing", ctx), "", "nil result prints nothing")
	assert_eq(cmds.execute("number", ctx), "42", "non-string result is stringified")


func test_invalid_handler_is_reported_not_fatal() -> void:
	var cmds := GodCommands.new()
	var holder: Object = RefCounted.new()
	cmds.register(&"gone", "handler on a freed object", Callable(holder, "no_such_method"))
	var out: String = cmds.execute("gone", GodContext.new())
	assert_has(out, "gone", "answers instead of crashing: %s" % out)


func test_handler_receives_the_context() -> void:
	var cmds := GodCommands.new()
	cmds.register(&"who", "player id", func(_a: PackedStringArray, ctx: GodContext) -> String: return "id=%d" % ctx.player_id)
	var ctx := GodContext.new()
	ctx.player_id = 7
	assert_eq(cmds.execute("who", ctx), "id=7", "ctx passed through")


func test_builtins_emit_context_signals() -> void:
	var cmds: GodCommands = GodCommands.with_builtins()
	var ctx := GodContext.new()
	var seen: Dictionary = {"clear": 0, "menu": 0, "close": 0}
	ctx.clear_requested.connect(func() -> void: seen["clear"] += 1)
	ctx.menu_requested.connect(func() -> void: seen["menu"] += 1)
	ctx.close_requested.connect(func() -> void: seen["close"] += 1)
	cmds.execute("clear", ctx)
	cmds.execute("menu", ctx)
	cmds.execute("close", ctx)
	assert_eq(seen, {"clear": 1, "menu": 1, "close": 1}, "each built-in raises exactly its request")


func test_context_log_emits_logged() -> void:
	var ctx := GodContext.new()
	var got: Array[String] = []
	ctx.logged.connect(func(t: String) -> void: got.append(t))
	ctx.log("hello")
	assert_eq(got, ["hello"] as Array[String], "log -> logged")


func test_quick_lines_come_from_providers() -> void:
	var cmds := GodCommands.new()
	assert_eq(cmds.quick_lines(GodContext.new()).size(), 0, "none registered")
	cmds.register_quick(func(_ctx: GodContext) -> PackedStringArray: return PackedStringArray(["a", "b"]))
	cmds.register_quick(func(_ctx: GodContext) -> PackedStringArray: return PackedStringArray(["c"]))
	assert_eq(cmds.quick_lines(GodContext.new()), PackedStringArray(["a", "b", "c"]), "providers concatenated in order")


# ---------------------------------------------------------------- console node

func test_console_submit_echoes_and_prints_the_answer() -> void:
	var c: GodConsole = await _console(_echo_registry())
	c.submit("echo hi there")
	var text: String = c.log_text()
	assert_has(text, "> echo hi there", "the command is echoed")
	assert_has(text, "hi|there", "and the answer printed")


func test_console_help_prints_commands() -> void:
	var c: GodConsole = await _console()
	c.submit("help")
	assert_has(c.log_text(), "commands:", "help output in the log")
	assert_has(c.log_text(), "God console. Type help.", "greeting present")


func test_console_empty_submit_does_nothing() -> void:
	var c: GodConsole = await _console()
	var before: String = c.log_text()
	c.submit("")
	c.submit("    ")
	assert_eq(c.log_text(), before, "no echo for blank lines")
	assert_eq(c.history_step(-1), "", "blank lines are not stored in the history")


func test_console_without_registry_reports() -> void:
	var c: GodConsole = await _console()
	c.commands = null
	c.submit("help")
	assert_has(c.log_text(), "no command registry", "reported, not a crash")


func test_console_history_up_down() -> void:
	var c: GodConsole = await _console()
	c.submit("alpha")
	c.submit("beta")
	c.submit("beta")  # consecutive duplicate is stored once
	assert_eq(c.history_step(-1), "beta", "newest first")
	assert_eq(c.history_step(-1), "alpha", "then the older one (the duplicate was not stored twice)")
	assert_eq(c.history_step(-1), "alpha", "clamped at the oldest")
	assert_eq(c.history_step(1), "beta", "back down")
	assert_eq(c.history_step(1), "", "past the newest: an empty fresh line")


func test_console_history_is_capped() -> void:
	var c: GodConsole = await _console()
	for i: int in GodConsole.HISTORY_MAX + 20:
		c.submit("cmd%d" % i)
	for i: int in GodConsole.HISTORY_MAX + 5:
		c.history_step(-1)
	assert_eq(c.history_step(-1), "cmd20", "only the last HISTORY_MAX lines remain")


func test_console_clear_command_empties_the_log() -> void:
	var c: GodConsole = await _console()
	var ctx := GodContext.new()
	c.context = ctx
	ctx.clear_requested.connect(c.clear)
	c.submit("clear")
	assert_false(c.log_text().contains("God console. Type help."), "log cleared by the built-in")


func test_console_open_close_signals_and_state() -> void:
	var c: GodConsole = await _console()
	var seen: Array[String] = []
	c.opened.connect(func() -> void: seen.append("opened"))
	c.closed.connect(func() -> void: seen.append("closed"))
	assert_false(c.is_open(), "starts closed")
	c.open()
	c.open()  # second open is a no-op
	assert_true(c.is_open(), "open")
	c.toggle()
	assert_false(c.is_open(), "toggle closes")
	c.close()  # already closed: no signal
	assert_eq(seen, ["opened", "closed"] as Array[String], "one signal per real transition")


func test_console_hide_quietly_emits_nothing() -> void:
	var c: GodConsole = await _console()
	var seen: Array[String] = []
	c.closed.connect(func() -> void: seen.append("closed"))
	c.open()
	c.hide_quietly()
	assert_false(c.is_open(), "hidden")
	assert_eq(seen.size(), 0, "no closed signal (the run is being freed)")


func test_console_closes_on_console_keys_and_escape() -> void:
	var c: GodConsole = await _console()
	c.open()
	c._input(G.backtick())
	assert_false(c.is_open(), "backtick closes")
	c.open()
	c._input(G.key(1105, KEY_NONE))
	assert_false(c.is_open(), "Russian ё closes")
	c.open()
	var esc := InputEventAction.new()
	esc.action = &"pause"
	esc.pressed = true
	c._input(esc)
	assert_false(c.is_open(), "Esc (pause action) closes")


func test_console_input_while_closed_is_ignored() -> void:
	var c: GodConsole = await _console()
	c._input(G.backtick())
	assert_false(c.is_open(), "a closed console does not open itself on its own close key")


func test_console_ignores_other_keys_while_open() -> void:
	var c: GodConsole = await _console()
	c.open()
	c._input(G.latin("w"))
	c._input(G.f1())
	assert_true(c.is_open(), "w and F1 do not close the console")


# ---------------------------------------------------------------- F1 menu panel registry

func test_menu_ships_stub_panels_and_commands_tab() -> void:
	var m := GodMenu.new()
	await _adopt(m)
	for id: StringName in [&"commands", &"tuning", &"gallery"]:
		assert_true(m.has_panel(id), "default panel %s" % id)


func test_menu_register_panel_builds_lazily_and_replace_keeps_slot() -> void:
	var m := GodMenu.new()
	await _adopt(m)
	var built: Array[int] = [0]
	m.register_panel(&"mine", "Mine", func(_ctx: GodContext) -> Control:
		built[0] += 1
		var l := Label.new()
		l.text = "v1"
		return l)
	assert_eq(built[0], 0, "not built before the first open")
	var order_before: Array[StringName] = m.panel_ids()
	m.open()
	assert_eq(built[0], 1, "built on open")
	assert_true(m.panel_control(&"mine") is Label, "the control is reachable")
	m.register_panel(&"mine", "Mine 2", func(_ctx: GodContext) -> Control:
		var l := Label.new()
		l.text = "v2"
		return l)
	assert_eq(m.panel_ids(), order_before, "replacing an id keeps its tab slot and adds no tab")


func test_menu_open_close_toggle_signals() -> void:
	var m := GodMenu.new()
	await _adopt(m)
	var seen: Array[String] = []
	m.opened.connect(func() -> void: seen.append("o"))
	m.closed.connect(func() -> void: seen.append("c"))
	m.toggle()
	m.toggle()
	m.close()
	assert_eq(seen, ["o", "c"] as Array[String], "toggle twice = one open + one close; close when closed is silent")


func test_menu_panel_builder_returning_null_shows_a_fallback() -> void:
	var m := GodMenu.new()
	await _adopt(m)
	m.register_panel(&"broken", "Broken", func(_ctx: GodContext) -> Control: return null)
	m.open()
	assert_not_null(m.panel_control(&"broken"), "a failing builder yields a fallback label, not an empty tab")
