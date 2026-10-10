@tool
extends EditorPlugin
## Adds the StreamEmber autoload and the streamember/* project settings.

const AUTOLOAD := "StreamEmber"
const CORE_PATH := "res://addons/streamember/streamember.gd"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, CORE_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	var defaults: Dictionary = load(CORE_PATH).DEFAULTS
	for key in defaults:
		var setting: String = "streamember/" + key
		if not ProjectSettings.has_setting(setting):
			ProjectSettings.set_setting(setting, defaults[key])
		ProjectSettings.set_initial_value(setting, defaults[key])
		ProjectSettings.set_as_basic(setting, true)
