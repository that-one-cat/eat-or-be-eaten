class_name VictoryScreen
extends CanvasLayer
## Victory screen (GAME_DESIGN §7, §10): run time, deaths and the mutations picked (names from data, in pick order,
## tinted by branch from the theme Palette), buttons Play again / Menu. Filled from the VICTORY event data by main.gd.

signal play_again_requested
signal menu_requested

const THEME: Theme = preload("res://ui/theme/main_theme.tres")

@onready var play_again_button: Button = %PlayAgainButton
@onready var menu_button: Button = %ToMenuButton
@onready var time_value: Label = %TimeValue
@onready var deaths_value: Label = %DeathsValue
@onready var mutation_list: VBoxContainer = %MutationList


func _ready() -> void:
	play_again_button.pressed.connect(play_again_requested.emit)
	menu_button.pressed.connect(menu_requested.emit)


## Shows the result; `mutations` = node ids in pick order (names looked up in `content`).
func show_result(run_ticks: int, deaths: int, mutations: PackedStringArray, content: ContentDB) -> void:
	time_value.text = Hud.format_run_time(run_ticks)
	deaths_value.text = str(deaths)
	for child: Node in mutation_list.get_children():
		mutation_list.remove_child(child)
		child.queue_free()
	if mutations.is_empty():
		mutation_list.add_child(_row("none", THEME.get_color(&"text_dim", &"Palette")))
	for id: String in mutations:
		var node: Dictionary = content.get_mutation(StringName(id)) if content != null else {}
		var branch: StringName = StringName(str(node.get("branch", "")))
		var color: Color = THEME.get_color(branch, &"Palette") if THEME.has_color(branch, &"Palette") else THEME.get_color(&"text", &"Palette")
		mutation_list.add_child(_row(str(node.get("name", id)), color))
	visible = true
	play_again_button.grab_focus.call_deferred()


func close() -> void:
	visible = false


## Names currently listed (for tests).
func listed_mutations() -> PackedStringArray:
	var out := PackedStringArray()
	for child: Node in mutation_list.get_children():
		if child is Label:
			out.append((child as Label).text)
	return out


func _row(text: String, color: Color) -> Label:
	var l := Label.new()
	l.theme_type_variation = &"HudValue"
	l.text = text
	l.add_theme_color_override("font_color", color)
	return l
