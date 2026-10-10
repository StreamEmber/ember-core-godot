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

const VERSION := "0.1.0"
const SOURCE := "godot"
const MODULE_PATH := "res://streamember/streamember-module.json"
const SCHEMA_PATH := "res://streamember/game-schema.json"
const LOG_PATH := "user://logs/streamember.log"
const REMEMBERED_IDS := 4096
const ACTIONS_PER_FRAME := 25
const MAX_PENDING_ACTIONS := 2048
const TOKEN_REFRESH_MARGIN := 120.0
const TOKEN_USE_MARGIN := 30.0
const INFO := 0
const WARNING := 1
const ERROR := 2

## Project Settings → streamember/<key> (Runtime.ini "Live*" keys in the GTA V / RDR2 runtimes).
const DEFAULTS := {
	"enabled": true,
	"eventfabric_url": "https://eventfabric.streamember.com",
	"falcon_url": "https://falcon.streamember.com",
	"launcher_url": "http://127.0.0.1:47880",
	"customer_uuid": "",  # development only: read events/settings without the launcher
	"presence_seconds": 15,
	"settings_seconds": 60,
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
## Two-letter UI language of the player's system ("tr", "en"…).
var language := "en"
var application_uuid: String:
	get:
		return manifest.application_uuid if manifest != null else ""
var live_connected: bool:
	get:
		return _client != null and _client.connected
## True while a valid runtime token is cached (presence and GCore reset need one).
var can_write: bool:
	get:
		return _peek_token() != null

signal _token_done

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
var _token: Dictionary = {}
var _token_problem := ""
var _token_busy := false
var _resolving := false
var _warned_no_customer := false
var _warned_no_token := false
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


## Resets GCore counters (aggregation, cooldown) for this streamer and game. done: func(ok: bool).
func reset_gcore(done: Callable = Callable()) -> void:
	var ok := false
	if _activated and customer_uuid != "":
		var url: String = _config.eventfabric_url + "/gcore/reset?customerUuid=" + customer_uuid.uri_encode() \
			+ "&applicationUuid=" + application_uuid.uri_encode()
		var token := await _get_token()
		if token.is_empty():
			_log("warn", "GCore reset needs a runtime token (%s)." % _token_problem)
		else:
			var response := await _get_json(url, token.value)
			ok = response.ok
			if response.status == 401:
				_token = {}
			if not ok:
				_log("warn", "GCore reset failed: " + response.error)
	if done.is_valid():
		done.call(ok)


# ─── Lifecycle ───────────────────────────────────────────────────────────────

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
		if _incoming.is_empty():
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
	_settings_fingerprint = _J.stable_text(settings.raw())
	settings_revision = "schema"
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
		_identity_resolved(found[0], found[1])


## [customer uuid or "", source]. Project setting (development) → launcher /api/customer → token sub.
func _find_customer() -> Array:
	var configured := _J.normalize_uuid(str(_config.customer_uuid))
	if configured != "":
		_customer_problem = ""
		return [configured, "config"]
	var response := await _get_json(_config.launcher_url + "/api/customer")
	if response.ok:
		var uuid := _J.normalize_uuid(_J.text(response.json, "customerUuid"))
		if uuid != "":
			_customer_problem = ""
			return [uuid, "launcher"]
		_customer_problem = "signed_out"
	else:
		_customer_problem = "signed_out" if response.status > 0 else "launcher_offline"
		_log("debug", "Launcher customer not available: " + response.error)
	var token := _peek_token()
	return [token.sub, "token"] if not token.is_empty() else ["", ""]


func _identity_resolved(customer: String, source: String) -> void:
	if customer == "":
		if not _warned_no_customer:
			_warned_no_customer = true
			var offline := _customer_problem == "launcher_offline"
			_log("warn", "No customer UUID (%s). Retrying every %d s." % [
				"launcher not reachable at " + _config.launcher_url if offline else "launcher not signed in", _config.presence_seconds])
			_notify("Canlı aksiyonlar için StreamEmber Launcher'ı aç ve giriş yap" if offline
				else "Canlı aksiyonlar için Launcher'da giriş yap", ERROR if offline else WARNING)
		return
	if customer == customer_uuid and _client != null:
		return
	_warned_no_customer = false
	_customer_source = source
	customer_uuid = customer
	_log("info", "Customer %s (%s)." % [customer, source])
	if _client != null:
		_client.stop()
	_announced_connection = false
	var ws_base: String = _config.eventfabric_url.replace("https://", "wss://").replace("http://", "ws://")
	_client = _Client.new(ws_base, customer, manifest.application_uuid, _log)
	_client.action_received.connect(_from_network)
	_client.connection_changed.connect(_on_connection_changed.bind(_client))
	_next_presence = 0.0
	_refresh_settings(true)
	_next_settings = _now() + float(_config.settings_seconds)


func _on_connection_changed(connected: bool, client: _Client) -> void:
	if client != _client or not _activated:
		return
	connection_changed.emit(connected)
	if connected and not _announced_connection:
		_announced_connection = true
		_notify(manifest.name + " canlı yayına bağlandı")


## Presence (needs a runtime token), launcher notification and a fresh customer lookup.
func _heartbeat() -> void:
	if customer_uuid == "" or _customer_source != "config":
		_resolve_identity()
	if customer_uuid == "":
		return
	var customer := customer_uuid
	var application := application_uuid
	var presence_url: String = _config.eventfabric_url + "/presence?customerUuid=" + customer.uri_encode() \
		+ "&applicationUuid=" + application.uri_encode() + "&source=" + SOURCE
	var notify_launcher := _customer_problem != "launcher_offline"
	var token := await _get_token()
	if token.is_empty():
		_no_write_access()
	elif token.sub != customer:
		_log("warn", "The runtime token is for customer %s, not %s; presence skipped." % [token.sub, customer])
	else:
		var response := await _get_json(presence_url, token.value)
		if response.ok:
			_warned_no_token = false
		else:
			if response.status == 401:
				_token = {}
			_log("debug", "Presence failed: " + response.error)
	if notify_launcher and _activated:
		await _get_json(_config.launcher_url + "/api/active-application?applicationUuid=" + application.uri_encode() + "&source=" + SOURCE)


func _no_write_access() -> void:
	if _warned_no_token:
		return
	_warned_no_token = true
	_log("warn", "No runtime token (%s): presence and other EventFabric writes are skipped. Live actions still arrive." % _token_problem)
	_notify("Launcher yetki doğrulaması başarısız (%s); aksiyonlar gelir, yazma kapalı" % _token_problem, WARNING)


# ─── Runtime token (Identity v2) ─────────────────────────────────────────────

## Cached token still valid for a while, without a request. {} when none.
func _peek_token() -> Dictionary:
	return _token if _usable(_token, TOKEN_USE_MARGIN) else {}


## Token for a write, refreshed ~2 min before it expires. {} when none can be obtained.
func _get_token(force: bool = false) -> Dictionary:
	if not force and _usable(_token, TOKEN_REFRESH_MARGIN):
		return _token
	if _token_busy:
		await _token_done
		return _peek_token()
	_token_busy = true
	var url: String = _config.launcher_url + "/api/runtime-token?audience=eventfabric&applicationUuid=" + application_uuid.uri_encode()
	var response := await _get_json(url)
	var problem := ""
	if response.ok:
		var token := parse_jwt(_J.text(response.json, "token"), _J.number(response.json, "expiresIn"))
		if token.is_empty():
			problem = "token_error"
			_log("debug", "The launcher answered without a runtime token.")
		elif not _usable(token, 0.0):
			problem = "token_error"
			_log("debug", "The runtime token is expired or for another application (%s)." % token.app)
		else:
			_token = token
			if _token_problem != "":
				_log("info", "Runtime token available again.")
			_log("debug", "Runtime token refreshed; scope '%s'." % token.scope)
	elif response.status == 401:
		problem = "no_session"
	elif response.status > 0:
		problem = "token_error"
	else:
		problem = "launcher_offline"
	if problem != "" and problem != _token_problem:
		_log("warn", "Runtime token not available (%s): %s" % [problem, response.error])
	_token_problem = problem
	_token_busy = false
	_token_done.emit()
	return _peek_token()


func _usable(token: Dictionary, margin: float) -> bool:
	if token.is_empty() or Time.get_unix_time_from_system() + margin >= float(token.exp):
		return false
	return token.app == "" or token.app == application_uuid


## Reads (does not verify) an ES256 runtime token: {value, sub, app, exp, scope}; {} when not a JWT with a sub.
static func parse_jwt(jwt: String, fallback_expires_in: float = 0.0) -> Dictionary:
	var parts := jwt.strip_edges().split(".")
	if parts.size() != 3:
		return {}
	var payload_b64 := parts[1].replace("-", "+").replace("_", "/")
	while payload_b64.length() % 4 != 0:
		payload_b64 += "="
	var payload = _J.parse(Marshalls.base64_to_raw(payload_b64).get_string_from_utf8())
	if not (payload is Dictionary):
		return {}
	var subject := _J.normalize_uuid(_J.text(payload, "sub"))
	if subject == "":
		return {}
	var exp := _J.number(payload, "exp")
	if exp <= 0.0:
		exp = Time.get_unix_time_from_system() + (fallback_expires_in if fallback_expires_in > 0.0 else 300.0)
	return {
		"value": jwt.strip_edges(),
		"sub": subject,
		"app": _J.normalize_uuid(_J.text(payload, "app")),
		"exp": exp,
		"scope": _J.text(payload, "scope"),
	}


# ─── Settings ────────────────────────────────────────────────────────────────

## Falcon public config → settings. Reading needs no token.
func _refresh_settings(notify_always: bool) -> void:
	if customer_uuid == "" or manifest == null:
		return
	var customer := customer_uuid
	var current := manifest
	var url: String = _config.falcon_url + "/public/game/config/" + customer.uri_encode() + "/" + current.application_uuid.uri_encode()
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
	var fingerprint := _J.stable_text(merged)
	if fingerprint == _settings_fingerprint:
		return false
	_settings_fingerprint = fingerprint
	settings = _Values.new(merged)
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


## Ctrl+Shift+F1…F9: schema action (test), F10 status, F11 reload settings, F12 GCore reset.
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
		_notify("%s | müşteri: %s | EventFabric: %s | yazma: %s | ayarlar: %s" % [manifest.name,
			customer_uuid.substr(0, 8) + "…" if customer_uuid != "" else "yok",
			"bağlı" if live_connected else "bağlı değil", "var" if can_write else "yok", settings_revision])
	elif index == 10:
		_refresh_settings(true)
		_notify("Ayarlar yeniden yükleniyor")
	elif index == 11:
		reset_gcore(func(ok: bool) -> void:
			_notify("GCore sıfırlandı" if ok else "GCore sıfırlanamadı", INFO if ok else ERROR))


# ─── HTTP, log, notifications ────────────────────────────────────────────────

## GET → {ok, status (0 = no answer), json, error}. The token goes only into the header, never into logs.
func _get_json(url: String, token: String = "") -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	add_child(request)
	var headers := PackedStringArray(["Accept: application/json"])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var error := request.request(url, headers)
	if error != OK:
		request.queue_free()
		return {"ok": false, "status": 0, "json": {}, "error": error_string(error)}
	var answer: Array = await request.request_completed
	request.queue_free()
	if answer[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "json": {}, "error": "no answer (result %d)" % answer[0]}
	var code: int = answer[1]
	var body: PackedByteArray = answer[3]
	var parsed = _J.parse(body.get_string_from_utf8()) if body.size() > 0 else null
	var ok := code >= 200 and code < 300
	return {"ok": ok, "status": code, "json": parsed if parsed is Dictionary else {}, "error": "" if ok else "HTTP %d" % code}


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
