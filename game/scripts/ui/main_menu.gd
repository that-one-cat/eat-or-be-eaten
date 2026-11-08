class_name MainMenu
extends CanvasLayer
## Main menu (GAME_DESIGN §10): Play, Settings, Quit over a water gradient. The title is the project name
## (application/config/name, the one place the working name lives). Emits requests; main.gd owns the flow.

signal play_requested
signal settings_requested
signal quit_requested

@onready var play_button: Button = %PlayButton
@onready var settings_button: Button = %SettingsButton
@onready var quit_button: Button = %QuitButton
@onready var _title: Label = %Title


func _ready() -> void:
	_title.text = str(ProjectSettings.get_setting("application/config/name", "Eat Or Be Eaten")).to_upper()
	play_button.pressed.connect(play_requested.emit)
	settings_button.pressed.connect(settings_requested.emit)
	quit_button.pressed.connect(quit_requested.emit)


func open() -> void:
	visible = true
	play_button.grab_focus.call_deferred()


func close() -> void:
	visible = false
