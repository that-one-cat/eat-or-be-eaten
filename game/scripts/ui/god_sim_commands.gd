class_name GodSimCommands
extends RefCounted
## The T1.2 God commands (console `~` and the F1 Commands tab). `register_all(cmds)` is called by GodHost where the
## registry is built. Every sim change goes through a documented `SimDebug` function (rules 1-2): the handlers only parse
## arguments, call SimDebug and describe the result; they validate their input and never throw.
##
##   tp <place|x y z> | tp list | places     named places come from map `places` (data/maps/<map>.json)
##   band <1-4> | xp <n> | heal               progression (SimDebug.set_band / set_xp / heal)
##   spawn [species [len]] | food [n] | despawn   NPC / glowing food bits at the aim point (GodAim); food = bits only
##   god | hunger | noclip [on|off]           flags (no argument toggles)
##   speed <x>                                time scale (0.05..8; GameLoop multiplies the frame delta)
##   event [list|trigger <id>]                scheduler stub (T6.1) + the recent sim events
##   overlay <name> [on|off] | overlay list   obstacles, zones, grid, detect, bitecue (DevOverlays)
##   boss [tp|hp <n>|stun|heal|win]           boss shortcuts (no argument: status)
##   tune list | <id> <value> | reset [id] | save|load|export <name>   tuning lab (T1.3): runtime overrides over rules and
##                                            band tables (data/god/tuning.json), presets in user://tuning, export to reports/tuning
##   mode [list|<id>]                         control mode (T1.4, data/controls/modes.json): sets the run's PlayerInput, which
##                                            tells the sim (SET_CONTROL_MODE); live only, the saved setting is untouched
## The console pauses the game while open: effects that need a sim tick (band, xp, boss HP) show up when it closes.

const EVENT_WINDOW_TICKS: int = 90
const BOSS_TP_DISTANCE_M: float = 20.0
const SPEED_PRESETS: PackedStringArray = ["0.25", "0.5", "1", "2", "4"]
const STUB_EVENTS: String = "no event scheduler yet (T6.1)"


static func register_all(cmds: GodCommands) -> void:
	cmds.register(&"tp", "teleport to a named place or to x y z", _cmd_tp, "tp <place> | tp <x> <y> <z> | tp list")
	cmds.register(&"places", "list the named teleport places", _cmd_places, "places")
	cmds.register(&"band", "set the player size band (1-4)", _cmd_band, "band <1-4>")
	cmds.register(&"xp", "set the player XP", _cmd_xp, "xp <n>")
	cmds.register(&"heal", "refill the player HP", _cmd_heal, "heal")
	cmds.register(&"spawn", "spawn a creature at the aim point (no argument: list)", _cmd_spawn, "spawn <species> [length_m]")
	cmds.register(&"food", "spawn glowing food bits at the aim point", _cmd_food, "food [count]")
	cmds.register(&"despawn", "remove everything spawned by spawn / food", _cmd_despawn, "despawn")
	cmds.register(&"god", "god mode: the player cannot die", _cmd_god, "god [on|off]")
	cmds.register(&"hunger", "hunger lock: hunger stays full", _cmd_hunger, "hunger [on|off]")
	cmds.register(&"speed", "game speed multiplier 0.05..8", _cmd_speed, "speed <x>")
	cmds.register(&"noclip", "fly through rocks and the seabed", _cmd_noclip, "noclip [on|off]")
	cmds.register(&"event", "list recent events / trigger an event (scheduler comes with T6.1)", _cmd_event, "event [list|trigger <id>]")
	cmds.register(&"overlay", "toggle a debug overlay (obstacles, zones, grid, detect, bitecue)", _cmd_overlay, "overlay <name> [on|off] | overlay list")
	cmds.register(&"boss", "boss shortcuts (no argument: status)", _cmd_boss, "boss [tp|hp <n>|stun|heal|win]")
	cmds.register(&"tune", "tuning lab: override rule and band numbers live, save / load presets", _cmd_tune,
		"tune list | tune <id> <value> | tune reset [id] | tune save <name> | tune load <name> | tune export <name>")
	cmds.register(&"mode", "control mode: list the modes / switch the live run (assisted turns the sim assists on)", _cmd_mode, "mode list | mode <id>")
	cmds.register_quick(quick_lines)


## Ready-made command lines for the menu's quick buttons (one button each).
static func quick_lines(ctx: GodContext) -> PackedStringArray:
	var out: PackedStringArray = []
	if ctx == null or ctx.world == null:
		return out
	for p: Dictionary in places(ctx.world):
		out.append("tp %s" % p["id"])
	for b in range(1, ctx.world.content.band_count() + 1 if ctx.world.content != null else 1):
		out.append("band %d" % b)
	out.append_array(["heal", "god", "hunger", "noclip"])
	for s: String in SPEED_PRESETS:
		out.append("speed %s" % s)
	for sid: String in spawnable_species(ctx.world):
		out.append("spawn %s" % sid)
	out.append_array(["food", "despawn"])
	for n: String in DevOverlays.names():
		out.append("overlay %s" % n)
	out.append_array(["boss tp", "boss stun", "boss heal", "boss win", "event list"])
	if ctx.world.content != null:
		for id: StringName in ctx.world.content.control_mode_ids():
			out.append("mode %s" % id)
	return out


## The valid `places` records of the world's map (id, name, pos as Vector3), in file order.
static func places(world: SimWorld) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = world.map.get("places")
	if not (raw is Array):
		return out
	for item: Variant in (raw as Array):
		if item is Dictionary and (item as Dictionary).get("id") is String and (item as Dictionary).get("pos") is Array \
				and ((item as Dictionary)["pos"] as Array).size() == 3:
			var pos: Array = (item as Dictionary)["pos"]
			out.append({"id": item["id"], "name": str(item.get("name", item["id"])), "pos": Vector3(pos[0], pos[1], pos[2])})
	return out


## Species ids `spawn` accepts (interactive and large tier), sorted.
static func spawnable_species(world: SimWorld) -> PackedStringArray:
	var out: PackedStringArray = []
	if world.content == null:
		return out
	for id: StringName in world.content.species_ids():
		var tier: String = str(world.content.get_species(id).get("tier", ""))
		if tier == "interactive" or tier == "large":
			out.append(String(id))
	return out


# ------------------------------------------------------------------ handlers

static func _cmd_tp(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	if args.is_empty():
		return "usage: tp <place> | tp <x> <y> <z> | tp list\n%s" % _places_text(ctx.world)
	if args[0].to_lower() == "list":
		return _places_text(ctx.world)
	var target: Vector3 = Vector3.ZERO
	var label: String = ""
	if args.size() == 1:
		var found: bool = false
		for p: Dictionary in places(ctx.world):
			if String(p["id"]) == args[0].to_lower():
				target = p["pos"]
				label = String(p["id"])
				found = true
				break
		if not found:
			return "unknown place '%s'\n%s" % [args[0], _places_text(ctx.world)]
	elif args.size() == 3 and args[0].is_valid_float() and args[1].is_valid_float() and args[2].is_valid_float():
		target = Vector3(args[0].to_float(), args[1].to_float(), args[2].to_float())
		label = _fmt(target)
	else:
		return "usage: tp <place> | tp <x> <y> <z> | tp list"
	if not SimDebug.teleport(ctx.world, ctx.player_id, target):
		return "cannot teleport: the player is dead or the position is invalid"
	return "teleported to %s, now at %s" % [label, _fmt(ctx.player().position)]


static func _cmd_places(_args: PackedStringArray, ctx: GodContext) -> String:
	return _places_text(ctx.world) if ctx.has_run() else _NO_RUN


static func _cmd_band(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var n: int = ctx.world.content.band_count() if ctx.world.content != null else 0
	if args.size() != 1 or not args[0].is_valid_int():
		return "usage: band <1-%d>" % n
	var band: int = SimDebug.set_band(ctx.world, ctx.player_id, args[0].to_int())
	if band == 0:
		return "cannot set the band (no player)"
	var note: String = "" if band == args[0].to_int() else " (clamped from %s)" % args[0]
	return "band %d requested%s, XP %.0f; it applies on the next tick%s" % [band, note, ctx.player().xp, _pick_note(ctx)]


static func _cmd_xp(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	if args.size() != 1 or not args[0].is_valid_float() or not is_finite(args[0].to_float()):
		return "usage: xp <n>"
	if not SimDebug.set_xp(ctx.world, ctx.player_id, args[0].to_float()):
		return "cannot set XP (no player)"
	return "XP set to %.0f; band and size follow on the next tick%s" % [ctx.player().xp, _pick_note(ctx)]


static func _cmd_heal(_args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	return "HP refilled to %.0f" % ctx.player().max_hp if SimDebug.heal(ctx.world, ctx.player_id) else "cannot heal: the player is dead"


static func _cmd_spawn(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	if args.is_empty():
		return "usage: spawn <species> [length_m]\nspecies: %s" % ", ".join(spawnable_species(ctx.world))
	var species: StringName = StringName(args[0].to_lower())
	var refusal: String = SimDebug.spawn_refusal(ctx.world, species)
	if not refusal.is_empty():
		return "cannot spawn: %s\nspecies: %s" % [refusal, ", ".join(spawnable_species(ctx.world))]
	var length_m: float = -1.0
	if args.size() > 1:
		if not args[1].is_valid_float() or args[1].to_float() <= 0.0:
			return "usage: spawn <species> [length_m]"
		length_m = args[1].to_float()
	var player: SimEntity = ctx.player()
	if player == null or not player.alive:
		return "cannot spawn: the player is dead"
	var at: Vector3 = ctx.aim_point()
	var id: int = SimDebug.spawn_species(ctx.world, species, at, length_m, player.position - at)
	if id < 0:
		return "cannot spawn %s" % species
	var e: SimEntity = ctx.world.get_entity(id)
	return "spawned %s #%d (%.2f m, band %d) at %s" % [species, id, e.length_m, e.band, _fmt(e.position)]


static func _cmd_food(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var count: int = 5
	if not args.is_empty():
		if not args[0].is_valid_int() or args[0].to_int() < 1:
			return "usage: food [count]"
		count = args[0].to_int()
	if ctx.player() == null:
		return "cannot spawn food: no player"
	var ids: PackedInt32Array = SimDebug.spawn_food_bits(ctx.world, ctx.aim_point(), count)
	return "spawned %d food bits (glowing bits; baked food sites cannot be added at runtime)" % ids.size() if not ids.is_empty() else "cannot spawn food"


static func _cmd_despawn(_args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	return "removed %d debug spawns" % SimDebug.despawn_debug(ctx.world)


static func _cmd_god(args: PackedStringArray, ctx: GodContext) -> String:
	return _flag_cmd("god mode", "god", args, ctx, func(w: SimWorld, on: bool) -> bool: return SimDebug.set_god(w, on),
		func(st: SimDebug.State) -> bool: return st.god)


static func _cmd_hunger(args: PackedStringArray, ctx: GodContext) -> String:
	return _flag_cmd("hunger lock", "hunger", args, ctx, func(w: SimWorld, on: bool) -> bool: return SimDebug.set_hunger_lock(w, on),
		func(st: SimDebug.State) -> bool: return st.hunger_lock)


static func _cmd_noclip(args: PackedStringArray, ctx: GodContext) -> String:
	return _flag_cmd("noclip", "noclip", args, ctx, func(w: SimWorld, on: bool) -> bool: return SimDebug.set_noclip(w, on),
		func(st: SimDebug.State) -> bool: return st.noclip)


static func _cmd_speed(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	if args.is_empty():
		return "game speed x%s (usage: speed <%s..%s>)" % [_num(SimDebug.state(ctx.world).time_scale), _num(SimDebug.TIME_SCALE_MIN), _num(SimDebug.TIME_SCALE_MAX)]
	if args.size() != 1 or not args[0].is_valid_float() or not is_finite(args[0].to_float()):
		return "usage: speed <%s..%s>" % [_num(SimDebug.TIME_SCALE_MIN), _num(SimDebug.TIME_SCALE_MAX)]
	var asked: float = args[0].to_float()
	var got: float = SimDebug.set_time_scale(ctx.world, asked)
	return "game speed x%s%s" % [_num(got), "" if is_equal_approx(got, asked) else " (clamped from %s)" % _num(asked)]


static func _cmd_event(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var sub: String = args[0].to_lower() if not args.is_empty() else ""
	if sub == "list":
		var counts: Dictionary = {}
		for ev: SimEvent in ctx.world.events_since(ctx.world.tick - EVENT_WINDOW_TICKS):
			var key: String = SimEvent.Type.keys()[ev.type]
			counts[key] = int(counts.get(key, 0)) + 1
		var keys: Array = counts.keys()
		keys.sort()
		var parts: PackedStringArray = []
		for k: String in keys:
			parts.append("%s x%d" % [k, counts[k]])
		return "%s\nevents of the last %d ticks: %s" % [STUB_EVENTS, EVENT_WINDOW_TICKS, ", ".join(parts) if not parts.is_empty() else "none"]
	if sub == "trigger":
		return "%s: cannot trigger '%s'" % [STUB_EVENTS, args[1] if args.size() > 1 else ""]
	return "%s\nusage: event [list|trigger <id>]" % STUB_EVENTS


static func _cmd_overlay(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var usage: String = "usage: overlay <%s> [on|off] | overlay list" % "|".join(DevOverlays.names())
	if args.is_empty():
		return usage
	var ov: DevOverlays = ctx.overlays()
	if args[0].to_lower() == "list":
		var lines: PackedStringArray = []
		for n: String in DevOverlays.names():
			lines.append("%s: %s" % [n, "on" if ov != null and ov.is_enabled(n) else "off"])
		return "\n".join(lines)
	var overlay: String = args[0].to_lower()
	if not DevOverlays.names().has(overlay):
		return "unknown overlay '%s'\n%s" % [args[0], usage]
	if ov == null:
		return "overlays need a running map scene"
	var on: bool = not ov.is_enabled(overlay)
	if args.size() > 1:
		var parsed: int = _parse_flag(args[1])
		if parsed < 0:
			return usage
		on = parsed == 1
	if not ov.set_enabled(overlay, on):
		return "overlay %s is not available on this map (the grey-box reef always draws its obstacles)" % overlay
	return "overlay %s: %s" % [overlay, "on" if on else "off"]


static func _cmd_boss(args: PackedStringArray, ctx: GodContext) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var world: SimWorld = ctx.world
	var boss: SimEntity = world.get_entity(world.boss_id())
	var sub: String = args[0].to_lower() if not args.is_empty() else ""
	if sub == "win":
		if world.run_won:
			return "the run is already won"
		SimDebug.force_victory(world, ctx.player_id)
		return "victory forced"
	if boss == null and sub != "":
		return "no boss alive (spawn giant_shark or wait for the abyss spawner)"
	match sub:
		"":
			if boss == null:
				return "no boss alive%s" % (", it was defeated" if world.boss_defeated_tick() >= 0 else "")
			return "boss %s #%d: HP %.0f / %.0f, %s, at %s" % [boss.species_id, boss.id, boss.hp, boss.max_hp,
				"engaged" if world.boss_engaged() else "not engaged", _fmt(boss.position)]
		"tp":
			var player: SimEntity = ctx.player()
			if player == null:
				return "cannot teleport: no player"
			var away: Vector3 = player.position - boss.position
			away = away.normalized() if not away.is_zero_approx() else Vector3.BACK
			if not SimDebug.teleport(world, ctx.player_id, boss.position + away * BOSS_TP_DISTANCE_M):
				return "cannot teleport: the player is dead"
			return "teleported %.0f m from the boss, now at %s" % [BOSS_TP_DISTANCE_M, _fmt(ctx.player().position)]
		"hp":
			if args.size() != 2 or not args[1].is_valid_float():
				return "usage: boss hp <n>"
			SimDebug.set_boss_hp(world, args[1].to_float())
			return "boss HP set to %.0f / %.0f" % [world.get_entity(world.boss_id()).hp, boss.max_hp]
		"stun":
			SimDebug.boss_stun(world)
			return "boss HP set to 0: it is stunned on the next tick (bite it to finish it)"
		"heal":
			SimDebug.boss_heal(world)
			return "boss HP refilled to %.0f" % boss.max_hp
	return "usage: boss [tp|hp <n>|stun|heal|win]"


const _TUNE_USAGE: String = "usage: tune list | tune <id> <value> | tune reset [id] | tune save|load|export <name>"


static func _cmd_tune(args: PackedStringArray, ctx: GodContext) -> String:
	if not GodBuild.allowed():
		return "tuning is disabled in this build"
	if not ctx.has_run():
		return _NO_RUN
	if args.is_empty():
		return "%s\n%s" % [_TUNE_USAGE, _tune_list(ctx.world)]
	var sub: String = args[0].to_lower()
	var world: SimWorld = ctx.world
	match sub:
		"list":
			return _tune_list(world) if args.size() == 1 else "usage: tune list"
		"reset":
			if args.size() > 2:
				return "usage: tune reset [id]"
			var which: String = args[1].to_lower() if args.size() == 2 else ""
			if not SimDebug.tuning_reset(world, which):
				return "unknown tuning id '%s' (tune list shows the ids)" % args[1]
			return "tuning: %s reset to the data value" % (which if not which.is_empty() else "every override")
		"save", "load", "export":
			if args.size() != 2:
				return "usage: tune %s <name>" % sub
			var err: String = ""
			match sub:
				"save":
					err = SimDebug.tuning_save(world, args[1])
				"load":
					err = SimDebug.tuning_load(world, args[1])
				_:
					err = SimDebug.tuning_export(world, args[1])
			if not err.is_empty():
				return "tune %s: %s" % [sub, err]
			var n: int = SimDebug.tuning(world).overridden_ids().size()
			return "tune %s '%s' ok: %d override(s)" % [sub, args[1].to_lower(), n]
	var t: TuningOverrides = SimDebug.tuning(world)
	if not t.has_row(sub):
		return "unknown tuning id or subcommand '%s'\n%s" % [args[0], _TUNE_USAGE]
	if args.size() != 2 or not args[1].is_valid_float():
		return "%s = %s (usage: tune %s <value>)" % [sub, _tune_num(t.value(sub)) if t.is_overridden(sub) else t.data_text(sub), sub]
	var err_set: String = SimDebug.tuning_set(world, sub, args[1].to_float())
	if not err_set.is_empty():
		return err_set
	return "%s = %s (data %s); it applies on the next tick" % [sub, _tune_num(t.value(sub)), t.data_text(sub)]


# One line per registry row: id = value, "*" and the data value when overridden.
static func _tune_list(world: SimWorld) -> String:
	var t: TuningOverrides = SimDebug.tuning(world)
	if t.rows.is_empty():
		return "tuning registry unavailable: %s" % "; ".join(t.errors)
	var lines: PackedStringArray = []
	for row: Dictionary in t.rows:
		var id: String = row["id"]
		if t.is_overridden(id):
			lines.append("  %s = %s  * (data %s)" % [id, _tune_num(t.value(id)), t.data_text(id)])
		else:
			lines.append("  %s = %s" % [id, t.data_text(id)])
	return "tuning (%d override(s)):\n%s" % [t.overridden_ids().size(), "\n".join(lines)]


static func _tune_num(v: float) -> String:
	return String.num(v, 6)


const _MODE_USAGE: String = "usage: mode list | mode <id>"


static func _cmd_mode(args: PackedStringArray, ctx: GodContext) -> String:
	if not GodBuild.allowed():
		return "the mode command is disabled in this build (pick the control mode in Settings)"
	var modes: ContentDB = ctx.world.content if ctx.has_run() and ctx.world.content != null else GameSettings.mode_db()
	if not args.is_empty() and args[0].to_lower() == "list":
		var lines: PackedStringArray = []
		for id: StringName in modes.control_mode_ids():
			var rec: Dictionary = modes.get_control_mode(id)
			lines.append("  %s - %s: %s" % [id, rec.get("name", id), rec.get("description", "")])
		return "control modes:\n%s" % "\n".join(lines)
	if not ctx.has_run():
		return _NO_RUN
	if ctx.player_input == null:
		return "no player input in this run"
	if args.is_empty():
		return "mode: %s (%s)" % [ctx.player_input.control_mode, _MODE_USAGE]
	var id: StringName = StringName(args[0].to_lower())
	if modes.get_control_mode(id).is_empty():
		return "unknown control mode '%s' (mode list shows the ids)" % args[0]
	ctx.player_input.control_mode = id
	return "control mode: %s (%s); the sim is told on the next frame" % [id, modes.get_control_mode(id).get("name", id)]


# ------------------------------------------------------------------ helpers

const _NO_RUN: String = "no run: start a game first"


# Shared body of god / hunger / noclip: no argument toggles, on|off sets, anything else prints the usage.
static func _flag_cmd(title: String, command: String, args: PackedStringArray, ctx: GodContext, setter: Callable, getter: Callable) -> String:
	if not ctx.has_run():
		return _NO_RUN
	var current: bool = getter.call(SimDebug.state(ctx.world))
	var on: bool = not current
	if not args.is_empty():
		var parsed: int = _parse_flag(args[0])
		if parsed < 0:
			return "usage: %s [on|off]" % command
		on = parsed == 1
	setter.call(ctx.world, on)
	return "%s: %s" % [title, "ON" if on else "off"]


# 1 = on, 0 = off, -1 = not a flag word.
static func _parse_flag(word: String) -> int:
	match word.to_lower():
		"on", "1", "true", "yes":
			return 1
		"off", "0", "false", "no":
			return 0
	return -1


static func _places_text(world: SimWorld) -> String:
	var lines: PackedStringArray = []
	for p: Dictionary in places(world):
		lines.append("  %s - %s %s" % [p["id"], p["name"], _fmt(p["pos"])])
	return "places:\n%s" % "\n".join(lines) if not lines.is_empty() else "this map has no places"


static func _pick_note(ctx: GodContext) -> String:
	return "\na mutation pick is pending: choose it first, the game is paused for it" if ctx.world.paused_for_pick else ""


static func _fmt(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


static func _num(f: float) -> String:
	return str(snappedf(f, 0.01))
