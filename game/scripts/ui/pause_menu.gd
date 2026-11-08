class_name PauseMenu
extends CanvasLayer
## Pause menu (Esc during a run): Resume, Settings, Quit to menu over a dimmed, paused run. main.gd pauses the tree
## and handles Esc; this screen only emits requests (its process mode is Always, so its buttons work while paused).

signal resume_requested
signal settings_requested
signal quit_requested

@onready var resume_button: Button = %ResumeButton
@onready var settings_button: Button = %SettingsButton
@onready var quit_button: Button = %QuitButton
@onready var _hint: Label = %Hint


func _ready() -> void:
	resume_button.pressed.connect(resume_requested.emit)
	settings_button.pressed.connect(settings_requested.emit)
	quit_button.pressed.connect(quit_requested.emit)
	_hint.text = "%s to resume" % TutorialHints.key_name(&"pause")


func open() -> void:
	visible = true
	resume_button.grab_focus.call_deferred()


func close() -> void:
	visible = false
