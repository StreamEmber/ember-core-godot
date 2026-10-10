class_name StreamEmberManifest
extends RefCounted
## res://streamember/streamember-module.json + game-schema.json (StreamEmber.Live LiveManifest).
## Same formats as the GTA V / RDR2 runtimes and Falcon.

const _J := preload("streamember_json.gd")
const _Values := preload("streamember_values.gd")

## Falcon game UUID (lower case).
var application_uuid: String
## kebab-case code, e.g. "tower-rush".
var code: String
var name: String
## Schema action ids in schema order.
var action_ids: PackedStringArray

var _setting_defaults: Dictionary = {}
var _argument_defaults: Dictionary = {}
var _labels: Dictionary = {}


## Loads and validates both files. On failure returns the error text (String) instead of a manifest.
static func load_files(module_path: String, schema_path: String):
	var module = _read(module_path)
	if module is String:
		return module
	var schema = _read(schema_path)
	if schema is String:
		return schema
	return from_dictionaries(module, schema)


static func from_dictionaries(module: Dictionary, schema: Dictionary):
	var raw_uuid := _J.text(module, "applicationUuid")
	var uuid := _J.normalize_uuid(raw_uuid)
	if uuid == "" or uuid != raw_uuid.strip_edges().to_lower():
		return "streamember-module.json: applicationUuid is not a valid UUID: '%s'" % raw_uuid
	var module_code := _J.text(module, "code").strip_edges()
	if module_code == "":
		return "streamember-module.json: code is missing"
	var manifest = load("res://addons/streamember/streamember_manifest.gd").new()
	manifest.application_uuid = uuid
	manifest.code = module_code
	var display := _J.text(module, "name").strip_edges()
	manifest.name = display if display != "" else module_code
	for item in _J.arr(schema, "actions"):
		if not (item is Dictionary):
			continue
		var action_id := _J.text(item, "id")
		if action_id == "":
			continue
		manifest.action_ids.append(action_id)
		manifest._argument_defaults[action_id] = defaults_of(_J.arr(item, "arguments"))
		var label = _J.obj(item, "label")
		if label != null:
			manifest._labels[action_id] = label
	manifest._setting_defaults = defaults_of(_J.arr(_J.obj(schema, "settings"), "fields"))
	return manifest


## Schema field list → nested defaults: { path: "battle.max", default: 40 } → { battle: { max: 40 } }.
static func defaults_of(fields: Array) -> Dictionary:
	var result := {}
	for field in fields:
		if not (field is Dictionary):
			continue
		var path := _J.text(field, "path")
		if path == "":
			path = _J.text(field, "id")
		if path == "" or field.get("default") == null:
			continue
		var parts := path.split(".")
		var parent: Dictionary = result
		for i in parts.size() - 1:
			if not (parent.get(parts[i]) is Dictionary):
				parent[parts[i]] = {}
			parent = parent[parts[i]]
		var value = field["default"]
		parent[parts[parts.size() - 1]] = value.duplicate(true) if (value is Dictionary or value is Array) else value
	return result


func setting_defaults() -> Dictionary:
	return _setting_defaults.duplicate(true)


func setting_defaults_values() -> _Values:
	return _Values.new(setting_defaults())


func argument_defaults(action_id: String) -> Dictionary:
	var found = _argument_defaults.get(action_id)
	return found.duplicate(true) if found is Dictionary else {}


## Schema label in the language ("tr", "en"…), English, or the id.
func action_label(action_id: String, language: String) -> String:
	var label = _labels.get(action_id)
	if not (label is Dictionary):
		return action_id
	var result := _J.text(label, language)
	if result == "":
		result = _J.text(label, "en")
	return result if result != "" else action_id


static func _read(path: String):
	if not FileAccess.file_exists(path):
		return "%s is missing (export filter: add streamember/*.json to non-resource files)" % path
	var text := FileAccess.get_file_as_string(path)
	var parsed = _J.parse(text)
	if not (parsed is Dictionary):
		return "%s is not a JSON object" % path
	return parsed
