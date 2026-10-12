@tool
extends EditorPlugin
## Adds the StreamEmber autoload and the streamember/* project settings, and keeps the addon up to date:
## once a day (and from Project → Tools) it checks the ember-core-godot releases and offers to install a newer one.

const AUTOLOAD := "StreamEmber"
const CORE_PATH := "res://addons/streamember/streamember.gd"
const CHECK_UPDATES := "streamember/editor/check_updates"
const MENU_ITEM := "StreamEmber Live: check for updates"
const CHECK_EVERY_SECONDS := 24 * 3600
const Updater := preload("updater.gd")

var _updater: Updater
var _dialog: AcceptDialog
var _release := {}
var _export: _ExportManifest


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, CORE_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	var defaults: Dictionary = load(CORE_PATH).DEFAULTS
	for key in defaults:
		_add_setting("streamember/" + key, defaults[key])
	_add_setting(CHECK_UPDATES, true)
	_export = _ExportManifest.new()
	add_export_plugin(_export)

	_updater = Updater.new()
	add_child(_updater)
	add_tool_menu_item(MENU_ITEM, _check_updates.bind(true))
	var last_check: int = EditorInterface.get_editor_settings().get_project_metadata("streamember", "last_update_check", 0)
	if ProjectSettings.get_setting(CHECK_UPDATES, true) and Time.get_unix_time_from_system() - last_check > CHECK_EVERY_SECONDS:
		_check_updates.call_deferred(false)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)
	remove_export_plugin(_export)
	if _dialog != null:
		_dialog.queue_free()
	_updater.queue_free()


func _add_setting(setting: String, value) -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, value)
	ProjectSettings.set_initial_value(setting, value)
	ProjectSettings.set_as_basic(setting, true)


func _check_updates(manual: bool) -> void:
	var release: Dictionary = await _updater.fetch_release()
	if release.error != "":
		print_rich("[color=yellow][StreamEmber] Update check failed: %s[/color]" % release.error)
		if manual:
			_show("Could not check for updates:\n" + release.error)
		return
	EditorInterface.get_editor_settings().set_project_metadata("streamember", "last_update_check", int(Time.get_unix_time_from_system()))
	var current := Updater.installed_version()
	if Updater.compare(release.version, current) <= 0:
		if manual:
			_show("StreamEmber Live %s is up to date." % current)
		return
	_release = release
	var text := "StreamEmber Live %s is available (this project has %s).\n\nUpdate now? The editor saves and restarts afterwards." \
		% [release.version, current]
	if Updater.major(release.version) != Updater.major(current):
		text += "\n\nThis is a new major version: read the changes first, your game code may need changes."
	print_rich("[color=cyan][StreamEmber] Update available: %s → %s  %s[/color]" % [current, release.version, release.notes_url])
	var dialog := _show(text, true)
	dialog.ok_button_text = "Update"
	dialog.add_button("Changes", true, "notes")


func _install() -> void:
	var download: Dictionary = await _updater.fetch(_release.zip_url)
	var error: String = download.error
	if error == "":
		error = Updater.install(Updater.files_from_zip(download.body))
	if error != "":
		push_error("[StreamEmber] Update failed: " + error)
		_show("Update failed:\n" + error)
		return
	print("[StreamEmber] Installed StreamEmber Live %s; restarting the editor." % Updater.installed_version())
	EditorInterface.restart_editor(true)


func _show(text: String, confirm := false) -> AcceptDialog:
	if _dialog != null:
		_dialog.queue_free()
	_dialog = ConfirmationDialog.new() if confirm else AcceptDialog.new()
	_dialog.title = "StreamEmber Live"
	_dialog.dialog_text = text
	if confirm:
		_dialog.confirmed.connect(_install)
		_dialog.custom_action.connect(func(_action): OS.shell_open(_release.notes_url))
	EditorInterface.get_base_control().add_child(_dialog)
	_dialog.popup_centered()
	return _dialog


## streamember/*.json are not resources; this ships them with every export (no export filter needed).
class _ExportManifest extends EditorExportPlugin:
	func _get_name() -> String:
		return "StreamEmber Live"

	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		var core = load(CORE_PATH)
		for path in [core.MODULE_PATH, core.SCHEMA_PATH]:
			if FileAccess.file_exists(path):
				add_file(path, FileAccess.get_file_as_bytes(path), false)
