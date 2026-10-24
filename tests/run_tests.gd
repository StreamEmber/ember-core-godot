extends SceneTree
## Headless self-test, no network:
##   godot --headless --path . -s res://tests/run_tests.gd
## Exit code 0 = all passed.

const J := preload("res://addons/streamember/streamember_json.gd")
const Values := preload("res://addons/streamember/streamember_values.gd")
const Action := preload("res://addons/streamember/streamember_action.gd")
const Manifest := preload("res://addons/streamember/streamember_manifest.gd")
const Client := preload("res://addons/streamember/core/event_fabric_client.gd")
const Core := preload("res://addons/streamember/core/live.gd")
const Host := preload("res://addons/streamember/streamember.gd")
const Boot := preload("res://addons/streamember/boot.gd")
const Texts := preload("res://addons/streamember/core/texts.gd")
const Updater := preload("res://addons/streamember/updater.gd")
const Capture := preload("res://addons/streamember/core/tiktok_capture.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_test_values()
	_test_manifest()
	_test_action()
	_test_client()
	_test_capture_proto()
	_test_identity()
	_test_core_queue()
	_test_updater()
	_test_host()
	await _test_sign_in()
	_test_texts()
	_test_boot()
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
	check(a.viewer.team == null, "no team without teams")
	var t := Action.new({"viewer": {"nickname": "Ahmet", "team": {"id": "t1", "code": "gs", "name": "Galatasaray", "shortName": "GS", "primaryColor": "#A90432", "logoUrl": "https://cdn/gs.webp"}}})
	check(t.viewer.team != null and t.viewer.team.code == "gs" and t.viewer.team.short_name == "GS" and t.viewer.team.primary_color == "#A90432", "viewer team")
	check(t.viewer.team.logo_url == "https://cdn/gs.webp", "team logo url")
	check(t.render("{user} ({team})") == "Ahmet (Galatasaray)", "render team")


func _test_client() -> void:
	var logs: Array = []
	var client := Client.new(func() -> String: return "wss://ef.example", "c-1", "a-1", func(level: String, message: String) -> void: logs.append(message))
	client._ws_base = "wss://ef.example"
	check(client.build_url() == "wss://ef.example/events/ws?format=json&customerUuid=c-1&applicationUuid=a-1", "url")
	var rejected: Array = []
	client.identity_rejected.connect(func(code: String) -> void: rejected.append(code))
	var config_changes := [0]
	client.config_changed.connect(func() -> void: config_changes[0] += 1)
	client.handle_frame("{\"packetType\":\"system\",\"system\":{\"type\":\"config.changed\",\"applicationUuid\":\"a-1\"}}")
	client.handle_frame("{\"packetType\":\"system\",\"system\":{\"type\":\"config.changed\",\"applicationUuid\":\"other\"}}")
	check(config_changes[0] == 2, "config.changed always reloads (EventFabric already filters by customer + application, 0.5.1)")
	client.handle_frame("{\"packetType\":\"system\",\"system\":{\"type\":\"error\",\"code\":\"wrong_node\"}}")
	check(rejected == ["wrong_node"], "wrong_node rejected")
	var received: Array = []
	client.action_received.connect(func(json: Dictionary) -> void: received.append(json))
	client.handle_frame("{\"packetType\":\"action\",\"cursor\":\"42\",\"action\":{\"id\":\"x\"}}")
	var events: Array = []
	client.event_received.connect(func(json: Dictionary) -> void: events.append(json))
	client.handle_frame("{\"packetType\":\"event\",\"cursor\":\"43\"}")
	client.handle_frame("{\"packetType\":\"event\",\"event\":{\"id\":\"e1\",\"catalogId\":\"tiktok.comment\",\"actor\":{\"id\":\"7\"}}}")
	client.handle_frame("not json")
	check(received.size() == 1 and received[0].id == "x", "only action frames on action_received")
	check(events.size() == 1 and events[0].catalogId == "tiktok.comment", "event frames on event_received (0.7.0)")
	check(client.build_url().ends_with("&replay=true&cursor=43"), "replay with last cursor")
	check(client.next_delay() == 1, "first delay 1 s")
	client._attempts = 3
	check(client.next_delay() == 4, "third failure 4 s")
	client._attempts = 99
	check(client.next_delay() == 30, "delay capped at 30 s")
	# collection: collect=self with the key, stream.status, final statuses stop asking, restart=manual once
	client._cursor = ""
	client.set_collect("dek_k")
	check(client.build_url() == "wss://ef.example/events/ws?format=json&customerUuid=c-1&applicationUuid=a-1&collect=self&key=dek_k", "collect url")
	var statuses: Array = []
	client.stream_status.connect(func(status: Dictionary) -> void: statuses.append(status))
	client.handle_frame("{\"packetType\":\"system\",\"system\":{\"type\":\"stream.status\",\"message\":\"{\\\"platform\\\":\\\"tiktok\\\",\\\"target\\\":\\\"ali\\\",\\\"status\\\":\\\"collecting\\\"}\"}}")
	check(statuses.size() == 1 and statuses[0].get("status") == "collecting" and client.collecting(), "stream.status parsed")
	client.handle_frame("{\"packetType\":\"system\",\"system\":{\"type\":\"stream.status\",\"message\":\"{\\\"platform\\\":\\\"tiktok\\\",\\\"target\\\":\\\"ali\\\",\\\"status\\\":\\\"ended\\\"}\"}}")
	check(not client.collecting() and not client.build_url().contains("collect="), "final status: collection not asked again")
	client.restart()
	check(client.build_url().ends_with("&collect=self&key=dek_k&restart=manual"), "restart asks with restart=manual")


func _test_capture_proto() -> void:
	check(Capture.varint(300) == PackedByteArray([0xAC, 0x02]), "varint 300")
	check(Capture.varint(-1).size() == 10, "negative int64 is 10 bytes")
	check(Capture._read_varint(Capture.varint(7342169118234520331), 0)[0] == 7342169118234520331, "room id round trip")
	var frame := Capture.push_frame(99, "pb", "hb", Capture.heartbeat(12345))
	var parsed := Capture.parse_push_frame(frame)
	check(parsed.log_id == 99 and parsed.payload_type == "hb" and Capture._fields(parsed.payload)[0] == [1, 12345], "push frame round trip")
	# fetch result: messages[{method: WebcastControlMessage, payload: {action: 3}}], internal_ext "x", need_ack true
	var control := Capture._tag(2, 0)
	control.append_array(Capture.varint(3))
	var message := Capture._bytes_field(1, "WebcastControlMessage".to_utf8_buffer())
	message.append_array(Capture._bytes_field(2, control))
	var batch := Capture._bytes_field(1, message)
	batch.append_array(Capture._bytes_field(5, "x".to_utf8_buffer()))
	batch.append_array(Capture._tag(9, 0))
	batch.append_array(Capture.varint(1))
	var result := Capture.parse_fetch_result(Capture.expand(batch.compress(FileAccess.COMPRESSION_GZIP)))
	check(result.need_ack and result.internal_ext == "x" and result.stream_ended, "gzip fetch result: ack + stream end")
	check(Capture._fields(PackedByteArray([0x0A, 0x7F])).is_empty(), "truncated input ignored")


func _test_identity() -> void:
	var core = Core.new()
	core.clear_identity()
	check(not core.has_stored_identity(), "no stored identity")
	core.set_identity({"customer_uuid": "B68B5DCC-090E-48A9-BB38-E8C16886AAB7", "device_key": "dek_x", "eventfabric_url": "https://ef.example/",
		"targets": [{"platform": "tiktok", "target": "@Ali"}, {"target": ""}], "source": "device"})
	check(core.has_stored_identity() and core._stored.customer_uuid == "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "identity stored, uuid normalized")
	check(core._stored.targets == [{"platform": "tiktok", "target": "Ali"}], "targets cleaned: %s" % [core._stored.targets])
	check(core._stored.eventfabric_url == "https://ef.example" and core._stored.source == "device", "fields")
	var again = Core.new()
	again._load_identity()
	check(again._stored.get("device_key") == "dek_x" and again._stored.targets.size() == 1, "identity reloaded from user://")
	again._secret_key = "dek_x"
	again._eventfabric_url = "https://ef.example"
	check(again.can_write and again.write_scope == "device", "device key: write scope device")
	again._secret_key = "sek_y"
	check(again.write_scope == "full", "secret key: full scope")
	core.set_identity({"customer_uuid": "nope"})
	check(core._stored.customer_uuid == "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "bad uuid ignored")
	core.clear_identity()
	check(not FileAccess.file_exists(Core.IDENTITY_PATH), "identity file removed")


func _test_core_queue() -> void:
	var host = Host.new()
	var core = host._core
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
	check(core._can_dispatch(), "dispatch when a handler is registered")
	core.hold_actions = true
	check(not core._can_dispatch(), "hold_actions keeps actions queued")
	core.hold_actions = false
	var saved: Dictionary = core._handlers.duplicate(true)
	core._handlers.clear()
	check(not core._can_dispatch(), "no handler yet (menu): actions wait")
	core._handlers = saved
	for i in Core.MAX_PENDING_ACTIONS + 10:
		core._from_network({"id": "q%d" % i})
	check(core._incoming.size() == Core.MAX_PENDING_ACTIONS, "queue bounded")
	core._incoming.clear()
	for i in Core.REMEMBERED_IDS + 100:
		core._from_network({"id": "r%d" % i})
		core._incoming.clear()
	check(core._seen.size() == Core.REMEMBERED_IDS, "remembered ids bounded")
	host.free()


func _test_updater() -> void:
	check(Updater.compare("0.10.0", "0.9.9") == 1 and Updater.compare("v1.2.3", "1.2.3") == 0, "version compare")
	check(Updater.compare("1.2.3-beta", "1.2.4") == -1 and Updater.compare("", "0.1.0") == -1, "version compare suffix/empty")
	check(Updater.major("2.0.1") == 2, "major")
	check(Updater.installed_version() == Host.VERSION and Core.VERSION == Host.VERSION, "plugin.cfg version == VERSION == core VERSION")

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
	check(not FileAccess.file_exists(target.path_join("plugin.cfg.new")), "no .new files left")
	check(FileAccess.get_file_as_string(target.path_join("sub/new.gd")) == "new", "new file in subfolder")
	check(not FileAccess.file_exists(target.path_join("old.gd")) and not FileAccess.file_exists(target.path_join("old.gd.uid")), "removed files deleted")
	check(FileAccess.file_exists(target.path_join("icon.svg.import")) and not FileAccess.file_exists(target.path_join("gone.png.import")), ".import kept only with its file")
	check(Updater.files_from_dir("res://").has("updater.gd"), "files from a local checkout")
	OS.move_to_trash(ProjectSettings.globalize_path(target))


func _test_host() -> void:
	var host = Host.new()
	check(host.core_source == "embedded" and host.core_version == Host.VERSION, "editor runs the embedded core")
	check(host._core.API == Host.HOST_API and host._core.host == host, "core API matches, core knows its host")
	host._core.customer_uuid = "c-9"
	host.hold_actions = true
	check(host.customer_uuid == "c-9" and host._core.hold_actions, "properties forwarded both ways")
	check(Host.DEFAULTS.has("cdn_url") and Host.TERMINAL_STATUSES.has("ended"), "constants come from the embedded core")
	var fired := [false]
	host.identity_changed.connect(func() -> void: fired[0] = true)
	host._core.host.identity_changed.emit()
	check(fired[0], "core emits the host's signals")
	host.free()


func _test_sign_in() -> void:
	var host = Host.new()
	var core = host._core
	core.manifest = _manifest()
	core._remember_device_key({"customer_uuid": "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "json": {"deviceKey": "dek_z",
		"region": {"code": "tr", "eventFabricUrl": "https://tr1.example/"}, "targets": [{"platform": "tiktok", "username": "nabe"}]}},
		"ali@example.com", true)
	check(core._stored.device_key == "dek_z" and core._stored.eventfabric_url == "https://tr1.example", "device key stored, url trimmed")
	check(core._stored.targets == [{"platform": "tiktok", "target": "nabe"}], "Falcon username -> target")
	check(core._stored.email == "ali@example.com" and core._stored.shared, "e-mail and shared flag stored")
	var again = Core.new()
	again._load_identity()
	check(again._stored.get("email") == "ali@example.com" and again._stored.get("shared") == true, "e-mail / shared reloaded")
	again.free()
	core.identity_source = "device"
	check(host.account_email == "ali@example.com" and core.account_shared(), "account e-mail through the host")
	check(core._error_code({"ok": false, "status": 0, "code": ""}) == "network" and core._error_code({"ok": false, "status": 401, "code": "invalid_credentials"}) == "invalid_credentials", "error codes")
	check(core._error_code({"ok": false, "status": 502, "code": ""}) == "http_502", "error code fallback")
	check(core._client_info("snowball").platform == "desktop" and core.can_sign_in() == OS.is_debug_build(), "desktop: sign-in only in debug builds")
	# shared sign-in of this phone (Android plugin) — a fake with the same methods
	var fake := FakeShared.new()
	core._shared = fake
	check(core._shared_account().is_empty(), "no shared account")
	fake.account = JSON.stringify({"email": "ali@example.com", "token": "ses_s", "customerUuid": "b68b5dcc-090e-48a9-bb38-e8c16886aab7"})
	check(core._shared_account().token == "ses_s", "shared account read")
	await core._sync_shared_account()
	check(core._stored.get("email") == "ali@example.com" and not core._minting, "same e-mail: nothing minted")
	fake.account = ""
	await core._sync_shared_account()
	check(core._stored.get("email") == "ali@example.com", "signed out elsewhere: cleared deferred (not inside the lookup)")
	core._shared = null
	core.identity_source = ""
	core.clear_identity()
	host.free()


class FakeShared extends RefCounted:
	var account := ""
	var cleared := false
	func get_account() -> String:
		return account
	func set_account(_e: String, _t: String, _c: String) -> bool:
		return true
	func clear_account() -> bool:
		cleared = true
		account = ""
		return true


func _test_texts() -> void:
	var bad: Array = []
	for key in Texts.T:
		if Texts.T[key].size() != Texts.LANGS.size():
			bad.append(key)
	check(bad.is_empty(), "every text in 14 languages: %s" % [bad])
	var saved := TranslationServer.get_locale()
	TranslationServer.set_locale("tr_TR")
	check(Texts.get_text("sign_in") == "Giriş yap", "Turkish")
	TranslationServer.set_locale("zh_TW")
	check(Texts.get_text("sign_in") == "登入", "Traditional Chinese from zh_TW")
	TranslationServer.set_locale("xx")
	check(Texts.get_text("sign_in") == "Sign in", "unknown language -> English")
	check(Texts.error("invalid_credentials") == "Wrong e-mail or password." and Texts.error("weird").contains("weird"), "error texts")
	TranslationServer.set_locale(saved)


func _test_boot() -> void:
	var root := "user://boot-test"
	Boot._remove_tree(root)
	DirAccess.make_dir_recursive_absolute(root)
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var pem := key.save_to_string(true)
	var live := "extends Node\nconst API := 1\nconst VERSION := \"9.1.0\"\nconst H := preload(\"helper.gd\")\n"
	var helper := "extends RefCounted\n"
	var files := {"live.gd": live.to_utf8_buffer(), "helper.gd": helper.to_utf8_buffer()}
	var core_json := JSON.stringify({"version": "9.1.0", "api": 1, "minGodot": "4.3", "files": [
		{"path": "live.gd", "sha256": Boot.sha256(files["live.gd"]).hex_encode()},
		{"path": "helper.gd", "sha256": Boot.sha256(files["helper.gd"]).hex_encode()}]}).to_utf8_buffer()
	var sig := Marshalls.raw_to_base64(crypto.sign(HashingContext.HASH_SHA256, Boot.sha256(core_json), key))
	check(Boot.verify(core_json, sig, pem), "signature verifies")
	check(not Boot.verify(core_json, sig), "another key (the real one) refuses it")
	var tampered := core_json.duplicate()
	tampered[5] = 65
	check(Boot.install(tampered, sig, files, 1, root, pem) == "bad signature", "tampered core.json refused")
	check(Boot.install(core_json, sig, {"live.gd": files["live.gd"], "helper.gd": "x".to_utf8_buffer()}, 1, root, pem).begins_with("checksum"), "file checksum checked")
	check(Boot.install(core_json, sig, files, 2, root, pem).begins_with("API"), "other API refused")
	check(not DirAccess.dir_exists_absolute(root + "/9.1.0"), "nothing installed after refusals")
	check(Boot.install(core_json, sig, files, 1, root, pem) == "", "installed")
	check(FileAccess.file_exists(root + "/9.1.0/helper.gd"), "files in place")
	var picked := Boot.pick("0.9.0", 1, root)
	check(picked.source == "cdn" and picked.version == "9.1.0", "newer downloaded core picked")
	check(Boot.pick("9.2.0", 1, root).source == "embedded", "newer embedded core wins")
	Boot.pick("0.9.0", 1, root)  # second start without confirm
	check(Boot.pick("0.9.0", 1, root).source == "embedded", "two unconfirmed starts -> marked bad, embedded again")
	var state := ConfigFile.new()
	state.load(root + "/state.cfg")
	check(state.get_value("bad", "9.1.0", false) == true, "bad version recorded")
	check(Boot.install(core_json, sig, files, 1, root, pem) == "" and Boot.pick("0.9.0", 1, root).source == "cdn", "reinstall clears bad")
	Boot.confirm(root)
	Boot.pick("0.9.0", 1, root)
	Boot.confirm(root)
	check(Boot.pick("0.9.0", 1, root).source == "cdn", "confirmed starts never mark it bad")
	Boot.prune(["0.9.0"], root)
	check(not DirAccess.dir_exists_absolute(root + "/9.1.0") and Boot.pick("0.9.0", 1, root).source == "embedded", "pruned")
	Boot._remove_tree(root)
