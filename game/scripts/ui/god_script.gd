class_name GodScript
extends RefCounted
## Scripted God sessions for captures and smoke runs: `-- --god-script=<file>` (debug / test builds only, see
## GodBuild.script_arg). Main starts a run automatically, then GodHost.run_script() executes the file once.
##
## One step per line; `#` starts a comment (whole line or after the command), blank lines are skipped:
##   wait <seconds>      real seconds (the game keeps running)
##   wait_ticks <n>      until the sim has advanced n ticks
##   shot <name>         saves a screenshot to user://god_shots/<name>.png (needs a display; skipped headless)
##   quit                quits the application
##   anything else       a console command line (`tp cave`, `band 3`, `spawn shark`, `god on`, ...)
## The file is parsed completely first; any malformed line or unknown command aborts the script before anything runs, the
## error naming the line number. Command answers are printed to stdout with a `god-script:` prefix.

const SHOT_DIR: String = "user://god_shots"
const MAX_WAIT_S: float = 3600.0

## Step dictionaries: {op: "wait"|"wait_ticks"|"shot"|"quit"|"cmd"|"error", arg: Variant, line: int}.
## An "error" step carries the message in `arg`.


static func parse(text: String) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	var lines: PackedStringArray = text.split("\n")
	for i in lines.size():
		var raw: String = lines[i].get_slice("#", 0).strip_edges()
		if raw.is_empty():
			continue
		var line_no: int = i + 1
		var parts: PackedStringArray = raw.split(" ", false, 1)
		var verb: String = parts[0].to_lower()
		var rest: String = parts[1].strip_edges() if parts.size() > 1 else ""
		match verb:
			"wait":
				if not rest.is_valid_float() or rest.to_float() < 0.0 or rest.to_float() > MAX_WAIT_S:
					steps.append(_error(line_no, "wait needs seconds in 0..%d, got '%s'" % [int(MAX_WAIT_S), rest]))
				else:
					steps.append({"op": "wait", "arg": rest.to_float(), "line": line_no})
			"wait_ticks":
				if not rest.is_valid_int() or rest.to_int() < 0:
					steps.append(_error(line_no, "wait_ticks needs a non-negative integer, got '%s'" % rest))
				else:
					steps.append({"op": "wait_ticks", "arg": rest.to_int(), "line": line_no})
			"shot":
				var shot_name: String = rest if not rest.is_empty() else "shot_%d" % line_no
				if not shot_name.is_valid_filename() or shot_name.contains("/"):
					steps.append(_error(line_no, "shot needs a plain file name, got '%s'" % rest))
				else:
					steps.append({"op": "shot", "arg": shot_name, "line": line_no})
			"quit":
				steps.append({"op": "quit", "arg": "", "line": line_no})
			_:
				steps.append({"op": "cmd", "arg": raw, "line": line_no})
	return steps


## The messages of the "error" steps ("line N: ..."), empty when the script is well formed.
static func errors(steps: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = []
	for s: Dictionary in steps:
		if s["op"] == "error":
			out.append("line %d: %s" % [s["line"], s["arg"]])
	return out


## "line N: unknown command 'x'" for every command step whose first word is not in `commands`.
static func unknown_commands(steps: Array[Dictionary], commands: GodCommands) -> PackedStringArray:
	var out: PackedStringArray = []
	for s: Dictionary in steps:
		if s["op"] != "cmd":
			continue
		var word: String = String(s["arg"]).get_slice(" ", 0)
		if not commands.has_command(StringName(word)):
			out.append("line %d: unknown command '%s'" % [s["line"], word])
	return out


## Reads `path`, parses it and runs it. Returns the errors that stopped it (empty = ran to the end). Async.
static func run_file(host: GodHost, path: String) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		return PackedStringArray(["god-script: file not found: %s" % path])
	return await run(host, parse(FileAccess.get_file_as_string(path)))


## Executes parsed `steps` against the host's registry and run context. Returns the parse errors (nothing runs then) or
## ["line N: ..."] for a step that could not run (run ended); empty on success. Async (waits).
static func run(host: GodHost, steps: Array[Dictionary]) -> PackedStringArray:
	var problems: PackedStringArray = errors(steps)
	problems.append_array(unknown_commands(steps, host.commands))
	if not problems.is_empty():
		return problems
	var tree: SceneTree = host.get_tree()
	for s: Dictionary in steps:
		if not host.context.has_run():
			return PackedStringArray(["line %d: the run ended before the script finished" % s["line"]])
		match s["op"]:
			"cmd":
				var answer: String = host.commands.execute(s["arg"], host.context)
				print("god-script: > %s" % s["arg"])
				if not answer.is_empty():
					print("god-script: %s" % answer.replace("\n", "\ngod-script: "))
			"wait":
				await tree.create_timer(float(s["arg"])).timeout
			"wait_ticks":
				var world: SimWorld = host.context.world
				var until: int = world.tick + int(s["arg"])
				var deadline: int = Time.get_ticks_msec() + int(maxf(10.0, 4.0 * float(s["arg"]) / SimWorld.TICK_RATE) * 1000.0)
				while host.context.world == world and world.tick < until and Time.get_ticks_msec() < deadline:
					await tree.process_frame
			"shot":
				await _shot(tree, s["arg"])
			"quit":
				tree.quit()
				return PackedStringArray()
	return PackedStringArray()


static func _shot(tree: SceneTree, shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("god-script: shot %s skipped (headless, nothing is drawn)" % shot_name)
		return
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var image: Image = tree.root.get_texture().get_image() if tree.root.get_texture() != null else null
	if image == null or image.is_empty():
		print("god-script: shot %s skipped (no display)" % shot_name)
		return
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var out: String = "%s/%s.png" % [SHOT_DIR, shot_name]
	image.save_png(out)
	print("god-script: shot saved %s" % ProjectSettings.globalize_path(out))


static func _error(line_no: int, message: String) -> Dictionary:
	return {"op": "error", "arg": message, "line": line_no}
