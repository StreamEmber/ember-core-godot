extends Node
## StreamEmber Live for Godot (autoload "StreamEmber"). Same behaviour as StreamEmber.Live in the
## GTA V / RDR2 runtimes: identity, EventFabric connection, Falcon settings, presence, action dispatch.
## Everything runs on the main thread; handlers may call the game freely.
##
##   func _ready() -> void:
##       StreamEmber.on("enemy.spawn", _spawn)
##       StreamEmber.settings_changed.connect(_apply_settings)

## The module became active (first frame). Settings are already the schema defaults.
signal live_started
## The game is closing: remove everything you created.
signal live_stopped
## Every action (after the on(...) handlers ran). action.handled tells if one did.
signal action_received(action)
## Settings changed (also once at start with the schema defaults). Argument: StreamEmberValues.
signal settings_changed(settings)
signal connection_changed(connected: bool)
## Status texts the core shows (connected, test hotkeys, problems). level: 0 info, 1 warning, 2 error.
signal notified(text: String, level: int)

const VERSION := "0.5.0"
const SOURCE := "godot"
const MODULE_PATH := "res://streamember/streamember-module.json"
const SCHEMA_PATH := "res://streamember/game-schema.json"
const LOG_PATH := "user://logs/streamember.log"
const REMEMBERED_IDS := 4096
const ACTIONS_PER_FRAME := 25
const MAX_PENDING_ACTIONS := 2048
## In-game texts for the few error codes a streamer sees (contract: servers send codes, clients translate).
const MESSAGES := {
	"launcher_unreachable": ["Open StreamEmber Launcher and sign in for live actions", "Canlı aksiyonlar için StreamEmber Launcher'ı aç ve giriş yap"],
	"signed_out": ["Sign in to StreamEmber Launcher for live actions", "Canlı aksiyonlar için Launcher'da giriş yap"],
	"invalid_key": ["Launcher secret key rejected; restart the launcher", "Launcher gizli anahtarı reddedildi; launcher'ı yeniden başlat"],
	"key_rotated": ["Secret key renewed; reconnecting", "Gizli anahtar yenilendi; yeniden bağlanılıyor"],
	"wrong_region": ["Region changed; reconnecting to the new EventFabric", "Bölge değişti; yeni EventFabric'e bağlanılıyor"],
	"no_write": ["No secret key; actions arrive, writes are off", "Gizli anahtar yok; aksiyonlar gelir, yazma kapalı"],
}
const INFO := 0
const WARNING := 1
const ERROR := 2

## Project Settings → streamember/<key> (Runtime.ini "Live*" keys in the GTA V / RDR2 runtimes).
const DEFAULTS := {
	"enabled": true,
	"eventfabric_url": "",  # development only: normally the launcher gives the URL of the streamer's region
	"falcon_url": "https://falcon.streamember.com",
	"launcher_url": "http://127.0.0.1:47880",
	"customer_uuid": "",  # development only: read events/settings without the launcher
	"secret_key": "",  # development only: "sek_…" so writes (presence, session reset) work without the launcher
	"presence_seconds": 15,
	"settings_seconds": 600,
	"announce_actions": true,
	"test_hotkeys": true,
	"show_notifications": true,
	"debug": false,
}

const _J := preload("streamember_json.gd")
const _Values := preload("streamember_values.gd")
const _Action := preload("streamember_action.gd")
const _Manifest := preload("streamember_manifest.gd")
const _Client := preload("event_fabric_client.gd")

## null until the module is active.
var manifest: _Manifest
var is_active := false
var customer_uuid := ""
## Current settings: schema defaults merged with the streamer's Falcon config.
var settings: _Values = _Values.new()
var settings_revision := "schema"
## Active teams of the streamer's config, in order (StreamEmberAction.Team); empty when the game has no teams.
## Updated with the settings (settings_changed). Actions carry the viewer's team as action.viewer.team.
var teams: Array = []
## Two-letter UI language of the player's system ("tr", "en"…).
var language := "en"
var application_uuid: String:
	get:
		return manifest.application_uuid if manifest != null else ""
var live_connected: bool:
	get:
		return _client != null and _client.connected
## The launcher gave the secret key and EventFabric URL (presence and session reset need them).
var can_write: bool:
	get:
		return _secret_key != "" and _eventfabric_url != ""
## While true, live actions wait in the queue (menus, cutscenes, loading). A paused tree does the same.
var hold_actions := false

var _config := {}
var _activated := false
var _disabled := false
var _handlers := {}
var _incoming: Array = []
var _seen := {}
var _seen_order: Array = []
var _unknown_warned := {}
var _overflow_count := 0
var _client: _Client
var _customer_source := ""
var _customer_problem := ""
## "sek_…" from the launcher; never logged. Empty = read only.
var _secret_key := ""
## Root URL of the EventFabric of the streamer's region (from the launcher); empty = unknown.
var _eventfabric_url := ""
var _region_code := ""
var _resolving := false
var _warned_no_customer := false
var _warned_no_write := false
var _announced_connection := false
var _settings_fingerprint := ""
var _next_presence := 0.0
var _next_settings := INF
var _log_file: FileAccess
var _toasts: VBoxContainer


# ─── Public API ──────────────────────────────────────────────────────────────

## Registers a handler for a schema action id. handler: func(action: StreamEmberAction).
func on(action_id: String, handler: Callable) -> void:
	if not _handlers.has(action_id):
		_handlers[action_id] = []
	_handlers[action_id].append(handler)
	if _activated and not manifest.action_ids.has(action_id):
		_log("warn", "Handler '%s' is not in game-schema.json." % action_id)


## Removes a handler registered with on(...). Freed objects are dropped automatically.
func off(action_id: String, handler: Callable) -> void:
	if _handlers.has(action_id):
		_handlers[action_id].erase(handler)


## Reads the Falcon settings now; settings_changed follows.
func reload_settings() -> void:
	if _activated:
		_refresh_settings(true)


## Resets the live session (GCore counters: aggregation, cooldown) for this streamer and game. done: func(ok: bool).
func reset_gcore(done: Callable = Callable()) -> void:
	var ok := false
	if _activated and customer_uuid != "":
		if not can_write:
			_log("warn", "Session reset needs the secret key and EventFabric URL.")
		else:
			var url: String = _eventfabric_url + "/sessions/reset?applicationUuid=" + application_uuid.uri_encode() \
				+ "&key=" + _secret_key.uri_encode()
			var response := await _get_json(url)
			ok = response.ok
			if not ok:
				_log("warn", "Session reset failed: " + response.error)
	if done.is_valid():
		done.call(ok)


# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	# Connection, presence and hotkeys keep running while the game is paused; actions wait in the queue.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if not _activated:
		# First frame: the scene's _ready() handlers are registered by now.
		if not _disabled:
			_activate()
		return
	var now := _now()
	if _client != null:
		_client.poll(now)
	if now >= _next_presence:
		_next_presence = now + float(_config.presence_seconds)
		_heartbeat()
	if now >= _next_settings:
		_next_settings = now + float(_config.settings_seconds)
		_refresh_settings(false)
	for i in ACTIONS_PER_FRAME:
		if _incoming.is_empty() or not _can_dispatch():
			break
		_dispatch(_Action.new(_incoming.pop_front(), false))


func _input(event: InputEvent) -> void:
	if not _activated or not _config.test_hotkeys:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.ctrl_pressed and key.shift_pressed \
			and key.keycode >= KEY_F1 and key.keycode <= KEY_F12:
		get_viewport().set_input_as_handled()
		_hotkey(key.keycode - KEY_F1)


func _exit_tree() -> void:
	if _client != null:
		_client.stop()
		_client = null
	if _activated:
		_activated = false
		is_active = false
		_log("info", "Module '%s' stopped." % manifest.code)
		live_stopped.emit()


func _activate() -> void:
	for key in DEFAULTS:
		_config[key] = ProjectSettings.get_setting("streamember/" + key, DEFAULTS[key])
	for key in ["eventfabric_url", "falcon_url", "launcher_url"]:
		var url := str(_config[key]).strip_edges().trim_suffix("/")
		_config[key] = url if url != "" else DEFAULTS[key]
	_config.secret_key = str(_config.secret_key).strip_edges()
	_config.presence_seconds = clampi(int(_config.presence_seconds), 5, 300)
	_config.settings_seconds = clampi(int(_config.settings_seconds), 10, 3600)
	_open_log()
	if not _config.enabled:
		_disabled = true
		_log("info", "Live is off (streamember/enabled = false).")
		return
	var loaded = _Manifest.load_files(MODULE_PATH, SCHEMA_PATH)
	if loaded is String:
		_disabled = true
		_log("error", "Live disabled: " + loaded)
		_notify("StreamEmber: " + loaded, ERROR)
		return
	manifest = loaded
	language = OS.get_locale_language()
	settings = manifest.setting_defaults_values()
	_settings_fingerprint = _J.stable_text(settings.raw()) + _J.stable_text([])
	settings_revision = "schema"
	teams = []
	_activated = true
	is_active = true
	_log("info", "Module '%s' (%s) active; StreamEmber for Godot %s, Godot %s." % [
		manifest.code, manifest.application_uuid, VERSION, Engine.get_version_info().string])
	live_started.emit()
	settings_changed.emit(settings)
	_validate_handlers()
	_resolve_identity()


func _validate_handlers() -> void:
	if action_received.get_connections().is_empty():
		for action_id in manifest.action_ids:
			if not _handlers.has(action_id):
				_log("warn", "Module '%s': schema action '%s' has no handler." % [manifest.code, action_id])
	for action_id in _handlers:
		if not manifest.action_ids.has(action_id):
			_log("warn", "Module '%s': handler '%s' is not in game-schema.json." % [manifest.code, action_id])


# ─── Identity and connection ─────────────────────────────────────────────────

func _resolve_identity() -> void:
	if _resolving or not _activated:
		return
	_resolving = true
	var found := await _find_customer()
	_resolving = false
	if _activated:
		_identity_resolved(found)


## {uuid, secret_key, eventfabric_url, region, source} or {} when unknown.
## Project settings (development) → launcher GET /api/customer (customer UUID, secret key, region EventFabric URL).
func _find_customer() -> Dictionary:
	var configured := _J.normalize_uuid(str(_config.customer_uuid))
	if configured != "":
		_customer_problem = ""
		var url := str(_config.eventfabric_url)
		if url == "":
			var region := await _get_json(_config.falcon_url + "/public/customers/" + configured.uri_encode() + "/region")
			if region.ok:
				url = _J.text(region.json, "eventFabricUrl").trim_suffix("/")
			else:
				_log("warn", "Region of the configured customer could not be read from Falcon: " + region.error)
		return {"uuid": configured, "secret_key": str(_config.secret_key), "eventfabric_url": url, "region": "", "source": "config"}
	var response := await _get_json(_config.launcher_url + "/api/customer")
	if response.ok:
		var uuid := _J.normalize_uuid(_J.text(response.json, "customerUuid"))
		if uuid != "":
			_customer_problem = ""
			var region = response.json.get("region")
			var url := _J.text(region, "eventFabricUrl").trim_suffix("/") if region is Dictionary else ""
			if str(_config.eventfabric_url) != "":
				url = str(_config.eventfabric_url)
			return {"uuid": uuid, "secret_key": _J.text(response.json, "secretKey"), "eventfabric_url": url,
				"region": _J.text(region, "code") if region is Dictionary else "", "source": "launcher"}
		_customer_problem = "signed_out"
	else:
		_customer_problem = "signed_out" if response.status > 0 else "launcher_unreachable"
		_log("debug", "Launcher customer not available: " + response.error)
	return {}


func _identity_resolved(found: Dictionary) -> void:
	if found.is_empty():
		if not _warned_no_customer:
			_warned_no_customer = true
			var offline := _customer_problem == "launcher_unreachable"
			_log("warn", "No customer (%s). Retrying every %d s." % [
				"launcher not reachable at " + _config.launcher_url if offline else "launcher not signed in", _config.presence_seconds])
			_notify(_message("launcher_unreachable" if offline else "signed_out"), ERROR if offline else WARNING)
		return
	var customer: String = found.uuid
	var same: bool = customer == customer_uuid and found.secret_key == _secret_key and found.eventfabric_url == _eventfabric_url
	if same and _client != null:
		return
	var same_uuid: bool = customer == customer_uuid
	_warned_no_customer = false
	if found.secret_key != "" and found.secret_key != _secret_key:
		_warned_no_write = false
	_customer_source = found.source
	customer_uuid = customer
	_secret_key = found.secret_key
	_eventfabric_url = found.eventfabric_url
	_region_code = found.region
	_log("info", "Customer %s (%s, region %s, EventFabric %s, write %s)." % [customer, found.source,
		_region_code if _region_code != "" else "?", _eventfabric_url if _eventfabric_url != "" else "?", "on" if can_write else "off"])
	if same_uuid and _client != null:
		return  # only key/URL changed: the client asks for the URL again on its next connect
	if _client != null:
		_client.stop()
	_announced_connection = false
	_client = _Client.new(_resolve_ws_base, customer, manifest.application_uuid, _log)
	_client.action_received.connect(_from_network)
	_client.connection_changed.connect(_on_connection_changed.bind(_client))
	_client.config_changed.connect(_on_config_changed.bind(_client))
	_client.identity_rejected.connect(_on_identity_rejected.bind(_client))
	_next_presence = 0.0
	_refresh_settings(true)
	_next_settings = _now() + float(_config.settings_seconds)


## Before every EventFabric connect: ask the launcher again (region / key may have changed). "" = unknown.
func _resolve_ws_base() -> String:
	var found := await _find_customer()
	if not found.is_empty() and _activated:
		_identity_resolved(found)
	var url := _eventfabric_url
	return url.replace("https://", "wss://").replace("http://", "ws://") if url != "" else ""


func _on_connection_changed(connected: bool, client: _Client) -> void:
	if client != _client or not _activated:
		return
	connection_changed.emit(connected)
	if not connected:
		return
	_refresh_settings(false)  # a config.changed sent while disconnected is not replayed
	_next_settings = _now() + float(_config.settings_seconds)
	if not _announced_connection:
		_announced_connection = true
		_notify(manifest.name + " canlı yayına bağlandı")


func _on_config_changed(client: _Client) -> void:
	if client == _client and _activated:
		_refresh_settings(false)


func _on_identity_rejected(code: String, client: _Client) -> void:
	if client != _client or not _activated:
		return
	_notify(_message(code), WARNING)
	_resolve_identity()


## Presence report (needs the secret key), launcher notification and a fresh customer lookup.
func _heartbeat() -> void:
	if customer_uuid == "" or _customer_source != "config":
		_resolve_identity()
	if customer_uuid == "":
		return
	var application := application_uuid
	if not can_write:
		_no_write_access()
		return
	var key := _secret_key
	var response := await _get_json(_eventfabric_url + "/presence/report?applicationUuid=" + application.uri_encode() \
		+ "&source=" + SOURCE + "&key=" + key.uri_encode())
	if not response.ok:
		_log("debug", "Presence failed: " + response.error)
		if response.code in ["wrong_region", "invalid_key", "key_rotated"] and _activated:
			_on_identity_rejected(response.code, _client)
	if _customer_source == "launcher" and _activated:
		await _get_json(_config.launcher_url + "/api/active-application?applicationUuid=" + application.uri_encode() \
			+ "&source=" + SOURCE + "&key=" + key.uri_encode())


func _no_write_access() -> void:
	if _warned_no_write:
		return
	_warned_no_write = true
	_log("warn", "No secret key / EventFabric URL: presence and other EventFabric writes are skipped. Live actions still arrive.")
	_notify(_message("no_write"), WARNING)


func _message(code: String) -> String:
	if not MESSAGES.has(code):
		return code
	return MESSAGES[code][1] if language == "tr" else MESSAGES[code][0]


# ─── Settings ────────────────────────────────────────────────────────────────

## Falcon public config → settings. Reading needs no key.
func _refresh_settings(notify_always: bool) -> void:
	if customer_uuid == "" or manifest == null:
		return
	var customer := customer_uuid
	var current := manifest
	var url: String = _config.falcon_url + "/public/customers/" + customer.uri_encode() + "/applications/" + current.application_uuid.uri_encode() + "/config"
	var response := await _get_json(url)
	if customer != customer_uuid or current != manifest or not _activated:
		return
	if not response.ok:
		_log("warn", "Game settings could not be loaded from Falcon (%s); keeping current settings." % response.error)
	var changed: bool = response.ok and _apply_config(response.json)
	if changed:
		_log("info", "Settings revision %s applied." % settings_revision)
	if changed or notify_always:
		settings_changed.emit(settings)


func _apply_config(config: Dictionary) -> bool:
	var merged := _J.merge(manifest.setting_defaults(), _J.obj(config, "settings"))
	var revision := _J.text(config, "revision")
	settings_revision = revision if revision != "" else "unknown"
	var team_list: Array = config.get("teams") if config.get("teams") is Array else []
	var fingerprint := _J.stable_text(merged) + _J.stable_text(team_list)
	if fingerprint == _settings_fingerprint:
		return false
	_settings_fingerprint = fingerprint
	settings = _Values.new(merged)
	teams = []
	for item in team_list:
		if item is Dictionary:
			teams.append(_Action.Team.new(item))
	return true


# ─── Actions ─────────────────────────────────────────────────────────────────

## From the connection: drop duplicates, queue for _process.
func _from_network(json: Dictionary) -> void:
	var id := _J.text(json, "id")
	if id == "" or _seen.has(id):
		return
	if _incoming.size() >= MAX_PENDING_ACTIONS:
		_overflow_count += 1
		if _overflow_count == 1 or _overflow_count % 100 == 0:
			_log("warn", "Live action queue full; rejected %d action(s). Reduce event rate." % _overflow_count)
		return
	_seen[id] = true
	_seen_order.append(id)
	while _seen_order.size() > REMEMBERED_IDS:
		_seen.erase(_seen_order.pop_front())
	_incoming.append(json)


## Actions wait while the tree is paused, hold_actions is set, or no handler is registered yet
## (a menu or loading scene before the gameplay scene's _ready).
func _can_dispatch() -> bool:
	if hold_actions or (is_inside_tree() and get_tree().paused):
		return false
	if not action_received.get_connections().is_empty():
		return true
	for list in _handlers.values():
		for handler in list:
			if handler.is_valid():
				return true
	return false


func _dispatch(action: _Action) -> void:
	if manifest == null:
		return
	if action.application_uuid != "" and action.application_uuid.to_lower() != manifest.application_uuid:
		return
	action._apply_argument_defaults(manifest.argument_defaults(action.action))
	_log("debug", "%s %s" % [action, action.arguments])
	if _config.announce_actions:
		_notify("%s  >  %s%s%s" % [action.describe(), manifest.action_label(action.action, language),
			" x%d" % action.quantity if action.quantity > 1 else "", " (test)" if action.is_test else ""])
	var delivered := false
	var handlers: Array = _handlers.get(action.action, [])
	for handler in handlers.duplicate():
		if not handler.is_valid():
			handlers.erase(handler)
			continue
		handler.call(action)
		delivered = true
	action.handled = delivered
	if not action_received.get_connections().is_empty():
		delivered = true
	action_received.emit(action)
	if not delivered and not _unknown_warned.has(action.action):
		_unknown_warned[action.action] = true
		_log("warn", "Module '%s' has no handler for action '%s'. Check game-schema.json and StreamEmber.on(...)." % [manifest.code, action.action])


## Ctrl+Shift+F1…F9: schema action (test), F10 status, F11 reload settings, F12 session reset.
func _hotkey(index: int) -> void:
	if index <= 8:
		if index >= manifest.action_ids.size():
			return
		_dispatch(_Action.new({
			"schemaVersion": 2,
			"id": "test-%d-%d" % [Time.get_ticks_usec(), randi()],
			"customerUuid": customer_uuid,
			"applicationUuid": manifest.application_uuid,
			"action": manifest.action_ids[index],
			"arguments": {},
			"quantity": 1,
			"ruleId": "test",
			"trigger": {"platform": "streamember", "kind": "manual", "event": "streamember.manual"},
			"viewer": {"id": "streamember", "username": "streamember", "nickname": "Test"},
		}, true))
	elif index == 9:
		_notify("%s | müşteri: %s | EventFabric: %s | yazma: %s | ayarlar: %s | kuyruk: %d" % [manifest.name,
			customer_uuid.substr(0, 8) + "…" if customer_uuid != "" else "yok",
			"bağlı" if live_connected else "bağlı değil", "var" if can_write else "yok", settings_revision, _incoming.size()])
	elif index == 10:
		_refresh_settings(true)
		_notify("Ayarlar yeniden yükleniyor")
	elif index == 11:
		reset_gcore(func(ok: bool) -> void:
			_notify("Oturum sıfırlandı" if ok else "Oturum sıfırlanamadı", INFO if ok else ERROR))


# ─── HTTP, log, notifications ────────────────────────────────────────────────

## GET → {ok, status (0 = no answer), json, error}. The token goes only into the header, never into logs.
## {ok, status, json, code, error}. code = contract error code ("wrong_region"…) of a non-2xx body, "" otherwise.
func _get_json(url: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	add_child(request)
	var headers := PackedStringArray(["Accept: application/json", "User-Agent: StreamEmber-Godot/" + VERSION])
	var error := request.request(url, headers)
	if error != OK:
		request.queue_free()
		return {"ok": false, "status": 0, "json": {}, "code": "", "error": error_string(error)}
	var answer: Array = await request.request_completed
	request.queue_free()
	if answer[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "json": {}, "code": "", "error": "no answer (result %d)" % answer[0]}
	var status: int = answer[1]
	var body: PackedByteArray = answer[3]
	var parsed = _J.parse(body.get_string_from_utf8()) if body.size() > 0 else null
	var json: Dictionary = parsed if parsed is Dictionary else {}
	var ok := status >= 200 and status < 300
	var code := "" if ok else _J.text(json, "code")
	var message := "" if ok else _J.text(json, "message")
	return {"ok": ok, "status": status, "json": json, "code": code,
		"error": "" if ok else "HTTP %d%s%s" % [status, " " + code if code != "" else "", ": " + message if message != "" else ""]}


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _open_log() -> void:
	DirAccess.make_dir_recursive_absolute(LOG_PATH.get_base_dir())
	_log_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)


func _log(level: String, message: String) -> void:
	if level == "debug" and not _config.get("debug", false):
		return
	var line := "[StreamEmber] " + message
	match level:
		"warn":
			push_warning(line)
		"error":
			push_error(line)
		_:
			print(line)
	if _log_file != null:
		_log_file.store_line("%s %s %s" % [Time.get_datetime_string_from_system(), level.to_upper(), message])
		_log_file.flush()


func _notify(text: String, level: int = INFO) -> void:
	notified.emit(text, level)
	if level == INFO:
		_log("info", text)
	if not _config.get("show_notifications", true) or DisplayServer.get_name() == "headless":
		return
	if _toasts == null:
		var layer := CanvasLayer.new()
		layer.layer = 128
		add_child(layer)
		_toasts = VBoxContainer.new()
		_toasts.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		_toasts.offset_left = -520
		_toasts.offset_top = 16
		_toasts.offset_right = -16
		_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(_toasts)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_color_override("font_color", [Color.WHITE, Color.GOLD, Color.TOMATO][clampi(level, 0, 2)])
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	_toasts.add_child(label)
	while _toasts.get_child_count() > 5:
		_toasts.get_child(0).free()
	get_tree().create_timer(5.0).timeout.connect(func() -> void:
		if is_instance_valid(label):
			label.queue_free())
