extends SceneTree
## Headless self-test, no network:
##   godot --headless --path . -s res://tests/run_tests.gd
## Exit code 0 = all passed.

const J := preload("res://addons/streamember/streamember_json.gd")
const Values := preload("res://addons/streamember/streamember_values.gd")
const Action := preload("res://addons/streamember/streamember_action.gd")
const Manifest := preload("res://addons/streamember/streamember_manifest.gd")
const Client := preload("res://addons/streamember/event_fabric_client.gd")
const Core := preload("res://addons/streamember/streamember.gd")
const Updater := preload("res://addons/streamember/updater.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_values()
	_test_manifest()
	_test_action()
	_test_jwt()
	_test_client()
	_test_core_queue()
	_test_updater()
	print("%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + label)


func _test_values() -> void:
	var v := Values.new({"a": {"b": 7.0, "s": "x"}, "flag": "TRUE", "dotted.key": 3.0, "list": ["a", " ", 2.0], "csv": "x, y,,z"})
	check(v.get_int("a.b") == 7, "nested int")
	check(v.get_int("a.b", 0, 1, 5) == 5, "int clamp")
	check(v.get_int("missing", 9) == 9, "int fallback")
	check(v.get_int("a.s", 4) == 4, "string is not a number")
	check(v.get_bool("flag") == true, "bool from string")
	check(v.get_int("dotted.key") == 3, "direct dotted key wins")
	check(v.get_string("a.b") == "7", "number as text without .0")
	check(v.get_float("a.b", 0.0, 0.0, 2.5) == 2.5, "float clamp")
	check(v.get_string_list("list") == PackedStringArray(["a", "2"]), "string list from array")
	check(v.get_string_list("csv") == PackedStringArray(["x", "y", "z"]), "string list from csv")
	check(v.get_object("a").get_string("s") == "x", "object")
	check(v.has("a.b") and not v.has("a.zz"), "has")


func _schema() -> Dictionary:
	return {
		"settings": {"fields": [
			{"id": "maxAlive", "path": "boxes.maxAlive", "default": 50},
			{"id": "plain", "default": "p"},
			{"id": "noDefault", "path": "x.y"},
		]},
		"actions": [
			{"id": "box.drop", "label": {"tr": "Kutu düşür", "en": "Drop boxes"}, "arguments": [{"id": "count", "path": "count", "default": 3}]},
			{"id": "box.clear", "arguments": []},
		],
	}


func _manifest():
	return Manifest.from_dictionaries({"applicationUuid": "B68B5DCC-090E-48A9-BB38-E8C16886AAB7", "code": "demo"}, _schema())


func _test_manifest() -> void:
	var m = _manifest()
	check(not (m is String), "manifest loads: " + str(m))
	check(m.application_uuid == "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "uuid lower-cased")
	check(m.name == "demo", "name falls back to code")
	check(m.action_ids == PackedStringArray(["box.drop", "box.clear"]), "action ids in order")
	check(m.setting_defaults() == {"boxes": {"maxAlive": 50}, "plain": "p"}, "setting defaults nested")
	check(m.argument_defaults("box.drop") == {"count": 3}, "argument defaults")
	check(m.action_label("box.drop", "tr") == "Kutu düşür", "label tr")
	check(m.action_label("box.drop", "de") == "Drop boxes", "label falls back to en")
	check(m.action_label("box.clear", "tr") == "box.clear", "label falls back to id")
	check(Manifest.from_dictionaries({"applicationUuid": "nope", "code": "x"}, {}) is String, "bad uuid rejected")
	check(Manifest.from_dictionaries({"applicationUuid": "b68b5dcc-090e-48a9-bb38-e8c16886aab7"}, {}) is String, "missing code rejected")
	check(Manifest.load_files("res://streamember/streamember-module.json", "res://streamember/game-schema.json") is Manifest, "demo files load")


func _test_action() -> void:
	var a := Action.new({
		"id": "1", "action": "box.drop", "quantity": 4.0, "arguments": {"extra": true},
		"viewer": {"username": "ali", "nickname": ""}, "gift": {"name": "Rose", "coins": 1.0},
		"trigger": {"platform": "tiktok", "target": "streamer"}, "comment": {"text": "hi"}, "like": {"count": 12.0},
	})
	check(a.quantity == 4, "quantity")
	check(a.viewer.display_name == "ali", "display name falls back to username")
	check(a.gift.name == "Rose" and a.subscription == null, "optional parts")
	check(a.render("{user} {gift} x{quantity} @{streamer} {comment}") == "ali Rose x4 @streamer hi", "render")
	check(a.describe() == "ali · Rose ×4", "describe")
	check(a.like_count == 12, "like count")
	a._apply_argument_defaults({"count": 3, "extra": false})
	check(a.arguments.get_int("count") == 3 and a.arguments.get_bool("extra") == true, "argument defaults merged under saved values")
	check(Action.new({"quantity": 0}).quantity == 1, "quantity at least 1")
	check(Action.new({"quantity": 1e12}).quantity == 2147483647, "quantity capped")


func _jwt(payload: Dictionary) -> String:
	var body := Marshalls.utf8_to_base64(JSON.stringify(payload)).replace("+", "-").replace("/", "_").replace("=", "")
	return "eyJhbGciOiJFUzI1NiJ9." + body + ".sig"


func _test_jwt() -> void:
	var exp := Time.get_unix_time_from_system() + 600.0
	var t := Core.parse_jwt(_jwt({"sub": "B68B5DCC-090E-48A9-BB38-E8C16886AAB7", "app": "", "exp": exp, "scope": "presence:write"}))
	check(t.sub == "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "jwt sub")
	check(t.app == "" and t.scope == "presence:write" and absf(t.exp - exp) < 1.0, "jwt fields")
	check(Core.parse_jwt("not-a-jwt").is_empty(), "bad jwt")
	check(Core.parse_jwt(_jwt({"sub": "x"})).is_empty(), "jwt without uuid sub")
	var fallback := Core.parse_jwt(_jwt({"sub": "b68b5dcc-090e-48a9-bb38-e8c16886aab7"}), 100.0)
	check(fallback.exp > Time.get_unix_time_from_system() + 90.0, "expiresIn fallback")


func _test_client() -> void:
	var logs: Array = []
	var client := Client.new("wss://ef.example", "c-1", "a-1", func(level: String, message: String) -> void: logs.append(message))
	check(client.build_url() == "wss://ef.example/events/ws?format=json&customerUuid=c-1&applicationUuid=a-1", "url")
	var received: Array = []
	client.action_received.connect(func(json: Dictionary) -> void: received.append(json))
	client.handle_frame("{\"packetType\":\"action\",\"cursor\":\"42\",\"action\":{\"id\":\"x\"}}")
	client.handle_frame("{\"packetType\":\"event\",\"cursor\":\"43\"}")
	client.handle_frame("not json")
	check(received.size() == 1 and received[0].id == "x", "only action frames forwarded")
	check(client.build_url().ends_with("&replay=true&cursor=43"), "replay with last cursor")
	check(client.next_delay() == 1, "first delay 1 s")
	client._attempts = 3
	check(client.next_delay() == 5, "third failure 5 s")
	client._attempts = 99
	check(client.next_delay() == 30, "delay capped at 30 s")


func _test_core_queue() -> void:
	var core = Core.new()
	core.manifest = _manifest()
	core._config = Core.DEFAULTS.duplicate()
	core._config.announce_actions = false
	var got: Array = []
	core.on("box.drop", func(action) -> void: got.append(action))
	core._from_network({"id": "1", "action": "box.drop", "applicationUuid": "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "quantity": 2})
	core._from_network({"id": "1", "action": "box.drop"})
	core._from_network({"id": "2", "action": "box.drop", "applicationUuid": "00000000-0000-4000-8000-000000000000"})
	core._from_network({"action": "box.drop"})
	check(core._incoming.size() == 2, "duplicates and id-less packets dropped")
	while not core._incoming.is_empty():
		core._dispatch(Action.new(core._incoming.pop_front()))
	check(got.size() == 1, "other application's action ignored")
	check(got[0].arguments.get_int("count") == 3 and got[0].handled, "schema argument default applied, handled")
	for i in Core.MAX_PENDING_ACTIONS + 10:
		core._from_network({"id": "q%d" % i})
	check(core._incoming.size() == Core.MAX_PENDING_ACTIONS, "queue bounded")
	core._incoming.clear()
	for i in Core.REMEMBERED_IDS + 100:
		core._from_network({"id": "r%d" % i})
		core._incoming.clear()
	check(core._seen.size() == Core.REMEMBERED_IDS, "remembered ids bounded")
	core.free()


func _test_updater() -> void:
	check(Updater.compare("0.10.0", "0.9.9") == 1 and Updater.compare("v1.2.3", "1.2.3") == 0, "version compare")
	check(Updater.compare("1.2.3-beta", "1.2.4") == -1 and Updater.compare("", "0.1.0") == -1, "version compare suffix/empty")
	check(Updater.major("2.0.1") == 2, "major")
	check(Updater.installed_version() == Core.VERSION, "plugin.cfg version == VERSION")

	var zip_path := "user://updater-test.zip"
	var packer := ZIPPacker.new()
	packer.open(zip_path)
	var entries := {
		"Org-ember-core-godot-abc123/addons/streamember/plugin.cfg": "[plugin]\nversion=\"9.0.0\"\n",
		"Org-ember-core-godot-abc123/addons/streamember/streamember.gd": "extends Node",
		"Org-ember-core-godot-abc123/addons/streamember/sub/new.gd": "new",
		"Org-ember-core-godot-abc123/demo/addons/streamember/nested.gd": "nested copy",
		"Org-ember-core-godot-abc123/addons/streamember/../evil.gd": "evil",
		"Org-ember-core-godot-abc123/README.md": "readme",
	}
	for name in entries:
		packer.start_file(name)
		packer.write_file(entries[name].to_utf8_buffer())
		packer.close_file()
	packer.close()
	var files := Updater.files_from_zip(FileAccess.get_file_as_bytes(zip_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(zip_path))
	check(files.keys().size() == 3 and files.has("sub/new.gd") and files.has("plugin.cfg"), "zip: only <root>/addons/streamember files: %s" % [files.keys()])

	var target := "user://updater-test-target"
	for name in ["streamember.gd", "old.gd", "old.gd.uid", "icon.svg", "icon.svg.import", "gone.png.import"]:
		DirAccess.make_dir_recursive_absolute(target)
		FileAccess.open(target.path_join(name), FileAccess.WRITE).store_string("old")
	files["icon.svg"] = "svg".to_utf8_buffer()
	check(Updater.install({"plugin.cfg": PackedByteArray()}, target) != "", "install refuses a non-addon")
	check(FileAccess.file_exists(target.path_join("old.gd")), "refused install wrote nothing")
	check(Updater.install(files, target) == "", "install")
	check(Updater.installed_version(target) == "9.0.0", "installed version")
	check(FileAccess.get_file_as_string(target.path_join("sub/new.gd")) == "new", "new file in subfolder")
	check(not FileAccess.file_exists(target.path_join("old.gd")) and not FileAccess.file_exists(target.path_join("old.gd.uid")), "removed files deleted")
	check(FileAccess.file_exists(target.path_join("icon.svg.import")) and not FileAccess.file_exists(target.path_join("gone.png.import")), ".import kept only with its file")
	check(Updater.files_from_dir("res://").has("updater.gd"), "files from a local checkout")
	OS.move_to_trash(ProjectSettings.globalize_path(target))
