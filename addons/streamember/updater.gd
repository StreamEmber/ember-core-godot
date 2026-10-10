@tool
extends Node
## Installs a StreamEmber Live release into res://addons/streamember. Used by the editor plugin
## (Project → Tools → "StreamEmber Live: check for updates") and by update.gd on the command line.
## Releases are the GitHub Releases of ember-core-godot; CI creates one only when the tests pass.

const REPO := "StreamEmberPlatform/ember-core-godot"
const TARGET := "res://addons/streamember"
const ZIP_TEMP := "user://streamember-update.zip"

## Overridable for tests.
var api_url := "https://api.github.com/repos/" + REPO


## Latest release (or the release of `version`): {version, zip_url, notes_url, error}.
func fetch_release(version := "") -> Dictionary:
	var url := api_url + ("/releases/latest" if version == "" else "/releases/tags/v" + version.trim_prefix("v"))
	var answer := await fetch(url)
	if answer.error != "":
		return {"error": answer.error}
	var json = JSON.parse_string(answer.body.get_string_from_utf8())
	if not json is Dictionary or not json.has("tag_name") or not json.has("zipball_url"):
		return {"error": "unexpected answer from " + url}
	return {"version": str(json.tag_name).trim_prefix("v"), "zip_url": str(json.zipball_url),
		"notes_url": str(json.get("html_url", "")), "error": ""}


## GET url (redirects followed): {body: PackedByteArray, error}.
func fetch(url: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 60.0
	add_child(request)
	var error := request.request(url, PackedStringArray(["User-Agent: StreamEmber-Godot-Updater", "Accept: */*"]))
	if error != OK:
		request.queue_free()
		return {"body": PackedByteArray(), "error": error_string(error)}
	var answer: Array = await request.request_completed
	request.queue_free()
	if answer[0] != HTTPRequest.RESULT_SUCCESS:
		return {"body": PackedByteArray(), "error": "no answer from %s (result %d)" % [url, answer[0]]}
	if answer[1] < 200 or answer[1] >= 300:
		return {"body": PackedByteArray(), "error": "HTTP %d from %s" % [answer[1], url]}
	return {"body": answer[3], "error": ""}


## Version in <target>/plugin.cfg, "" if none.
static func installed_version(target := TARGET) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(target.path_join("plugin.cfg")) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


## -1, 0, 1 by major.minor.patch ("v" prefix and "-suffix" ignored).
static func compare(a: String, b: String) -> int:
	var x := _numbers(a)
	var y := _numbers(b)
	for i in 3:
		if x[i] != y[i]:
			return -1 if x[i] < y[i] else 1
	return 0


static func major(version: String) -> int:
	return _numbers(version)[0]


## Addon files from a release zip (GitHub source zip or the release asset): {relative path: bytes}.
static func files_from_zip(bytes: PackedByteArray) -> Dictionary:
	var file := FileAccess.open(ZIP_TEMP, FileAccess.WRITE)
	if file == null:
		return {}
	file.store_buffer(bytes)
	file.close()
	var reader := ZIPReader.new()
	var files := {}
	if reader.open(ZIP_TEMP) == OK:
		for entry in reader.get_files():
			var at := entry.find("addons/streamember/")
			# only <root>/addons/streamember/… (never a nested copy inside some other folder)
			if at < 0 or entry.ends_with("/") or entry.substr(0, at).count("/") > 1:
				continue
			var relative := entry.substr(at + "addons/streamember/".length())
			if _safe(relative):
				files[relative] = reader.read_file(entry)
		reader.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ZIP_TEMP))
	return files


## Addon files from a local ember-core-godot checkout (or any folder holding addons/streamember).
static func files_from_dir(root: String) -> Dictionary:
	var files := {}
	_collect(root.path_join("addons/streamember"), "", files)
	return files


## Replaces <target> with `files`; files of the old version that the new one no longer has are removed.
## Returns "" or an error. Nothing is written when the files are not a StreamEmber Live addon.
static func install(files: Dictionary, target := TARGET) -> String:
	if not files.has("plugin.cfg") or not files.has("streamember.gd"):
		return "not a StreamEmber Live addon (plugin.cfg / streamember.gd missing)"
	for relative in files:
		var path: String = target.path_join(relative)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var out := FileAccess.open(path, FileAccess.WRITE)
		if out == null:
			return "cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
		out.store_buffer(files[relative])
		out.close()
	var old := {}
	_collect(target, "", old, false)
	for relative in old:
		var owner: String = relative.trim_suffix(".import")  # an icon's .import goes with the icon
		if not files.has(relative) and not files.has(owner):
			DirAccess.remove_absolute(target.path_join(relative))
	return ""


static func _numbers(version: String) -> Array:
	var parts := version.strip_edges().trim_prefix("v").split("-")[0].split(".")
	var numbers := [0, 0, 0]
	for i in mini(3, parts.size()):
		numbers[i] = parts[i].to_int()
	return numbers


static func _safe(relative: String) -> bool:
	return relative != "" and not relative.begins_with("/") and not relative.contains("..") and not relative.contains(":")


static func _collect(dir_path: String, prefix: String, into: Dictionary, read := true) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_directories():
		_collect(dir_path.path_join(name), prefix + name + "/", into, read)
	for name in dir.get_files():
		if read and name.ends_with(".import"):
			continue  # editor cache; Godot recreates it
		into[prefix + name] = FileAccess.get_file_as_bytes(dir_path.path_join(name)) if read else true
