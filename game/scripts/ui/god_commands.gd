class_name GodCommands
extends RefCounted
## Command registry of the God console. T1.2 and later tasks only `register()` into it; they never edit the console.
##
## A handler is `func(args: PackedStringArray, ctx: GodContext) -> String`; the returned text is printed by the caller
## (null / "" prints nothing). `execute(line, ctx)` tokenises on whitespace (double or single quotes group a token, they
## are optional), looks the first token up case-insensitively, and never throws: an unknown name answers
## "unknown command, try help", an invalid handler or a handler that returns nothing is reported, not fatal.
## Registering a name twice replaces the older command. Built-ins (`with_builtins`): help [cmd], clear, menu, close.
## `register_quick(provider)` adds ready-made lines for the menu buttons.

const UNKNOWN_TEXT: String = "unknown command, try help"

var _commands: Dictionary = {}  # StringName -> {help: String, usage: String, handler: Callable}
var _quick: Array[Callable] = []


## Registers `name` (lower-cased). Returns true when an older command of that name was replaced.
func register(name: StringName, help: String, handler: Callable, usage: String = "") -> bool:
	var key: StringName = StringName(String(name).to_lower())
	var replaced: bool = _commands.has(key)
	_commands[key] = {"help": help, "usage": usage, "handler": handler}
	return replaced


## Registers a provider of quick-button command lines: `Callable(ctx: GodContext) -> PackedStringArray` (e.g. "tp cave"); the
## F1 menu's Commands tab shows one button per line and runs it through `execute`.
func register_quick(provider: Callable) -> void:
	_quick.append(provider)


## The quick-button lines of every provider for `ctx` (may be empty).
func quick_lines(ctx: GodContext) -> PackedStringArray:
	var out: PackedStringArray = []
	for provider: Callable in _quick:
		if provider.is_valid():
			out.append_array(provider.call(ctx))
	return out


func has_command(name: StringName) -> bool:
	return _commands.has(StringName(String(name).to_lower()))


## Sorted command names.
func names() -> PackedStringArray:
	var out: PackedStringArray = []
	for k: StringName in _commands:
		out.append(String(k))
	out.sort()
	return out


## `help` text: one line per command (name + one-line help), or the usage block of `command` when given.
func help_text(command: String = "") -> String:
	if not command.is_empty():
		var key: StringName = StringName(command.to_lower())
		if not _commands.has(key):
			return "%s: %s" % [command, UNKNOWN_TEXT]
		var rec: Dictionary = _commands[key]
		var usage: String = rec["usage"] if not String(rec["usage"]).is_empty() else String(key)
		return "%s\n  usage: %s" % [rec["help"], usage]
	var lines: PackedStringArray = []
	for n: String in names():
		lines.append("  %s - %s" % [n, _commands[StringName(n)]["help"]])
	return "commands:\n%s" % "\n".join(lines)


## Runs one console line; returns the text to print (may be empty).
func execute(line: String, ctx: GodContext) -> String:
	var tokens: PackedStringArray = tokenize(line)
	if tokens.is_empty():
		return ""
	var key: StringName = StringName(tokens[0].to_lower())
	if not _commands.has(key):
		return "%s: %s" % [tokens[0], UNKNOWN_TEXT]
	var handler: Callable = _commands[key]["handler"]
	if not handler.is_valid():
		return "%s: handler is no longer valid" % tokens[0]
	var result: Variant = handler.call(tokens.slice(1), ctx)
	if result == null:
		return ""
	return result if result is String else str(result)


## Whitespace split; "double" or 'single' quotes group words into one token (quotes are removed, an empty quoted token is kept).
static func tokenize(line: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur: String = ""
	var quote: String = ""
	var has_token: bool = false
	for i: int in line.length():
		var c: String = line[i]
		if not quote.is_empty():
			if c == quote:
				quote = ""
			else:
				cur += c
		elif c == "\"" or c == "'":
			quote = c
			has_token = true
		elif c == " " or c == "\t":
			if has_token:
				out.append(cur)
				cur = ""
				has_token = false
		else:
			cur += c
			has_token = true
	if has_token:
		out.append(cur)
	return out


## A registry with the built-ins `help [cmd]`, `clear`, `menu`, `close`.
static func with_builtins() -> GodCommands:
	var cmds: GodCommands = GodCommands.new()
	cmds.register(&"help", "list commands, or show the usage of one", cmds._cmd_help, "help [command]")
	cmds.register(&"clear", "clear the console log", func(_args: PackedStringArray, ctx: GodContext) -> String:
		ctx.clear_requested.emit()
		return "")
	cmds.register(&"menu", "open the F1 menu", func(_args: PackedStringArray, ctx: GodContext) -> String:
		ctx.menu_requested.emit()
		return "")
	cmds.register(&"close", "close the console", func(_args: PackedStringArray, ctx: GodContext) -> String:
		ctx.close_requested.emit()
		return "")
	return cmds


# A method callable (not a lambda that captures the registry) so the registry holds no reference cycle.
func _cmd_help(args: PackedStringArray, _ctx: GodContext) -> String:
	return help_text(args[0] if not args.is_empty() else "")
