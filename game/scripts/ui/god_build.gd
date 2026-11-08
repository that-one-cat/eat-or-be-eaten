class_name GodBuild
extends RefCounted
## Build gate for the dev tools (God menu, console, SimDebug-backed commands). They exist only in debug / test builds:
## the editor binary, debug export templates and the headless test runner have `OS.is_debug_build()`; a release export
## has neither that nor the custom feature tag `god_menu`. `Main` creates the God host only when `allowed()` is true,
## so a release export creates no node and registers no command. The tag is the opt-in for a release-optimised
## playtest preset (add it to that preset's `custom_features`; the shipping preset must not carry it).


## True in debug / test builds and in an export that carries the `god_menu` feature tag. Parameters are injectable for tests.
static func allowed(is_debug: bool = OS.is_debug_build(), feature: bool = OS.has_feature("god_menu")) -> bool:
	return is_debug or feature


const SCRIPT_ARG: String = "--god-script="


## Path of a `--god-script=<file>` user arg ("" when absent, empty, or the dev tools are not allowed in this build).
static func script_arg(args: PackedStringArray = OS.get_cmdline_user_args(), dev_allowed: bool = allowed()) -> String:
	if not dev_allowed:
		return ""
	for arg: String in args:
		if arg.begins_with(SCRIPT_ARG):
			return arg.trim_prefix(SCRIPT_ARG).strip_edges()
	return ""
