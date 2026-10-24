extends Node
## StreamEmber Live core (updatable part). The autoload `StreamEmber` (../streamember.gd) creates it as its child,
## forwards the public API and owns the signals; this file may be replaced at run time by a newer version downloaded
## from the CDN (see ../boot.gd), so it never uses class_name and finds its siblings with relative preloads.
## Everything runs on the main thread; handlers may call the game freely.

const VERSION := "0.9.0"
## Contract with the autoload (HOST_API in ../streamember.gd); a core with another API is never loaded.
const API := 1
const SOURCE := "godot"
const MODULE_PATH := "res://streamember/streamember-module.json"
const SCHEMA_PATH := "res://streamember/game-schema.json"
const LOG_PATH := "user://logs/streamember.log"
## Identity of a game signed in without a launcher (in-game StreamEmber sign-in → device key).
const IDENTITY_PATH := "user://streamember/identity.cfg"
const REMEMBERED_IDS := 4096
const ACTIONS_PER_FRAME := 25
const MAX_PENDING_ACTIONS := 2048
## In-game texts for the few error codes a streamer sees (contract: servers send codes, clients translate).
const MESSAGES := {
	"launcher_unreachable": ["Open StreamEmber Launcher and sign in for live actions", "Canlı aksiyonlar için StreamEmber Launcher'ı aç ve giriş yap"],
	"signed_out": ["Sign in to StreamEmber Launcher for live actions", "Canlı aksiyonlar için Launcher'da giriş yap"],
	"invalid_key": ["Launcher secret key rejected; restart the launcher", "Launcher gizli anahtarı reddedildi; launcher'ı yeniden başlat"],
	"key_rotated": ["Secret key renewed; reconnecting", "Gizli anahtar yenilendi; yeniden bağlanılıyor"],
	"wrong_node": ["Live server changed; reconnecting", "Canlı sunucu değişti; yeniden bağlanılıyor"],
	"node_disabled": ["Live server is closing; reconnecting to another one", "Canlı sunucu kapanıyor; başka sunucuya bağlanılıyor"],
	"no_write": ["No secret key; actions arrive, writes are off", "Gizli anahtar yok; aksiyonlar gelir, yazma kapalı"],
	"not_live": ["You are not live. Start the stream, then tap Reconnect", "Yayında değilsin. Yayını başlat, sonra Yeniden bağlan'a dokun"],
	"ended": ["The stream ended. Tap Reconnect when a new one starts", "Yayın bitti. Yeni yayın başlayınca Yeniden bağlan'a dokun"],
	"not_found": ["TikTok user not found; check the username in the launcher", "TikTok kullanıcısı bulunamadı; launcher'daki kullanıcı adını kontrol et"],
	"denied": ["Collection is off for this platform (Launcher › Integrations)", "Bu platform için toplama kapalı (Launcher › Entegrasyonlar)"],
}
const INFO := 0
const WARNING := 1
const ERROR := 2

## Project Settings → streamember/<key> (Runtime.ini "Live*" keys in the GTA V / RDR2 runtimes).
const DEFAULTS := {
	"enabled": true,
	"eventfabric_url": "",  # development only: normally the launcher gives the URL of the streamer's region
	"falcon_url": "https://falcon.streamember.com",
	"tiktoksign_url": "https://tiktoksign.streamember.com",
	## Who collects the live data of a device-key identity: "auto" (phone: this device collects TikTok itself and
	## EventFabric the other platforms; desktop: EventFabric), "device", "server" (EventFabric, collect=self) or "off".
	## A launcher identity never asks: the launcher produces the data.
	"collect": "auto",
	"launcher_url": "http://127.0.0.1:47880",
	"customer_uuid": "",  # development only: read events/settings without the launcher
	"secret_key": "",  # development only: "sek_…" so writes (presence, session reset) work without the launcher
	"presence_seconds": 15,
	"settings_seconds": 600,
	"announce_actions": true,
	"test_hotkeys": true,
	"show_notifications": true,
	"debug": false,
	"probe_launcher": true,  # false: never ask the local launcher (set automatically on Android / iOS)
	"cdn_url": "https://cdn.streamember.com",  # newer cores are downloaded from here (exported games only)
	"runtime_updates": true,  # false: always run the core this build shipped with
}

const _J := preload("res://addons/streamember/streamember_json.gd")
const _Values := preload("res://addons/streamember/streamember_values.gd")
const _Action := preload("res://addons/streamember/streamember_action.gd")
const _Manifest := preload("res://addons/streamember/streamember_manifest.gd")
const _Client := preload("event_fabric_client.gd")
const _Capture := preload("tiktok_capture.gd")
const _Panel := preload("panel.gd")
const _Texts := preload("texts.gd")
const TERMINAL_STATUSES := ["ended", "not_live", "not_found", "denied"]

## The autoload (StreamEmber): owns the signals the game connects to.
var host: Node
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
## Where the identity came from: "" (none), "config", "launcher", "device" (in-game sign-in), "manual" (set_identity without a key).
var identity_source := ""
## Platforms of a device / manual identity (from Falcon): [{platform, target}].
var targets: Array = []
## Who collects for this identity: "" (nobody / the launcher), "device" (this device, TikTok) or "server" (EventFabric).
var collect_mode := ""
## "platform:target" → last stream status (see stream_changed).
var streams: Dictionary = {}
var application_uuid: String:
	get:
		return manifest.application_uuid if manifest != null else ""
var live_connected: bool:
	get:
		return _client != null and _client.connected
## A write key (secret key sek_… or device key dek_…) and the EventFabric URL are known (presence needs them).
var can_write: bool:
	get:
		return _secret_key != "" and _eventfabric_url != ""
## "full" (secret key: everything), "device" (device key: presence + collection only) or "" (no key).
var write_scope: String:
	get:
		if _secret_key.begins_with("dek_"):
			return "device"
		return "full" if _secret_key != "" else ""
## While true, live actions wait in the queue (menus, cutscenes, loading). A paused tree does the same.
var hold_actions := false

var _config := {}
var _activated := false
var _disabled := false
var _handlers := {}
var _incoming: Array = []
var _seen := {}
var _seen_order: Array = []
var _seen_events := {}
var _seen_events_order: Array = []
var _unknown_warned := {}
var _overflow_count := 0
var _client: _Client
var _capture: _Capture
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
var _launcher_available := true
var _stored := {}  # IDENTITY_PATH contents
## Shared sign-in of the StreamEmber games on this phone (Android plugin StreamEmberAccount); null = none.
var _shared: Object
var _minting := false
var _panel: CanvasLayer
## Optional Theme for the core's panel and chip (the game's fonts / colours). Set before opening the panel.
var ui_theme: Theme


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
		if not can_write or write_scope != "full":
			_log("warn", "Session reset needs the secret key (not a device key) and EventFabric URL.")
		else:
			var url: String = _eventfabric_url + "/sessions/reset?applicationUuid=" + application_uuid.uri_encode() \
				+ "&key=" + _secret_key.uri_encode()
			var response := await _get_json(url)
			ok = response.ok
			if not ok:
				_log("warn", "Session reset failed: " + response.error)
	if done.is_valid():
		done.call(ok)


## Identity without a launcher (the in-game sign-in uses it; tests and tools may too). info: {customer_uuid, device_key?,
## eventfabric_url?, region?, targets? [{platform, target}], source: "device" | "manual", email?, shared?}.
## Persisted in user://streamember/identity.cfg; the launcher (when reachable) still wins over it.
func set_identity(info: Dictionary) -> void:
	_remember(info)
	if _activated and not _stored.is_empty():
		_resolve_identity()


func _remember(info: Dictionary) -> void:
	var uuid := _J.normalize_uuid(str(info.get("customer_uuid", "")))
	if uuid == "":
		_log("warn", "set_identity: customer_uuid missing or not a UUID.")
		return
	var list: Array = []
	for t in info.get("targets", []):
		if t is Dictionary and str(t.get("target", "")).strip_edges() != "":
			list.append({"platform": str(t.get("platform", "tiktok")).to_lower(), "target": str(t.get("target")).strip_edges().trim_prefix("@")})
	_stored = {
		"customer_uuid": uuid,
		"device_key": str(info.get("device_key", "")).strip_edges(),
		"eventfabric_url": str(info.get("eventfabric_url", "")).strip_edges().trim_suffix("/"),
		"region": str(info.get("region", "")),
		"targets": list,
		"source": "device" if str(info.get("source", "manual")) == "device" else "manual",
		"email": str(info.get("email", "")),
		"shared": bool(info.get("shared", false)),
	}
	_save_identity()
	_log("info", "Identity stored (%s, customer %s, %d target(s))." % [_stored.source, uuid, list.size()])
	_warned_no_customer = false


## Forgets the stored identity (device / manual). A launcher identity is unaffected.
func clear_identity() -> void:
	_stored = {}
	DirAccess.remove_absolute(IDENTITY_PATH)
	if identity_source in ["device", "manual"]:
		if _client != null:
			_client.stop()
			_client = null
		customer_uuid = ""
		_secret_key = ""
		_eventfabric_url = ""
		identity_source = ""
		_customer_source = ""
		targets = []
		_stop_collection()
		_log("info", "Identity cleared.")
		host.identity_changed.emit()
		if _activated:
			_resolve_identity()


# ─── In-game sign-in (StreamEmber account) ───────────────────────────────────

## Phone: StreamEmber e-mail + password → a device key (dek_) for this game. The session token (ses_) is kept only
## in the shared account store of this phone (Android plugin StreamEmberAccount), so the other StreamEmber games
## connect by themselves; without that store the session is closed at once and only the device key stays.
## Returns {ok, code}; code is a Falcon error code (invalid_credentials, email_not_verified …), "network" or "use_launcher".
func sign_in(email: String, password: String) -> Dictionary:
	_load_config()
	email = email.strip_edges().to_lower()
	if email == "" or password == "":
		return {"ok": false, "code": "fields_required"}
	if not can_sign_in():
		return {"ok": false, "code": "use_launcher"}
	var login := await _login(email, password)
	if not login.ok:
		return login
	var token: String = login.token
	var key := await _issue_device_key(token)
	if not key.ok:
		await _post_json(_config.falcon_url + "/api/auth/logout", {}, token)
		return key
	var shared: bool = _shared != null and bool(_shared.call("set_account", email, token, key.customer_uuid))
	if not shared:
		await _post_json(_config.falcon_url + "/api/auth/logout", {}, token)
	_log("info", "Signed in as %s%s." % [email, " (shared with the other StreamEmber games on this device)" if shared else ""])
	_remember_device_key(key, email, shared)
	_resolve_identity()
	return {"ok": true, "code": ""}


## Signs out on this device: this game forgets its key and the shared sign-in is removed (the other StreamEmber games
## on this phone disconnect at their next start).
func sign_out() -> void:
	var account := _shared_account()
	if not account.is_empty():
		_shared.call("clear_account")
		await _post_json(_config.falcon_url + "/api/auth/logout", {}, str(account.token))
	clear_identity()


## Falcon mails a 6-digit code. {ok, code}.
func request_password_reset(email: String) -> Dictionary:
	_load_config()
	email = email.strip_edges().to_lower()
	if email == "":
		return {"ok": false, "code": "fields_required"}
	var response := await _post_json(_config.falcon_url + "/api/auth/password-reset/request", {"email": email})
	return {"ok": response.ok, "code": _error_code(response)}


## Code from the e-mail + new password; signs in with it. {ok, code}.
func confirm_password_reset(email: String, code: String, new_password: String) -> Dictionary:
	_load_config()
	email = email.strip_edges().to_lower()
	var response := await _post_json(_config.falcon_url + "/api/auth/password-reset/confirm",
		{"email": email, "code": code.strip_edges(), "newPassword": new_password})
	if not response.ok:
		return {"ok": false, "code": _error_code(response)}
	return await sign_in(email, new_password)


## Phones sign in inside the game; a computer uses the launcher (debug builds may sign in too, for testing).
func can_sign_in() -> bool:
	return _platform() in ["android", "ios"] or OS.is_debug_build()


## E-mail of the in-game StreamEmber sign-in ("" for a launcher / development identity or none).
func account_email() -> String:
	return str(_stored.get("email", "")) if identity_source == "device" else ""


## The sign-in is shared with the other StreamEmber games on this phone.
func account_shared() -> bool:
	return identity_source == "device" and bool(_stored.get("shared", false))


## The connect panel (sign-in form or the connection status). Built by the core, above the game.
func open_panel() -> void:
	if _panel == null or not is_instance_valid(_panel):
		_panel = _Panel.new(self)
		add_child(_panel)
	_panel.open()


## A small "Live" chip that shows the connection and opens the panel; the game places it (lobby corner, settings).
func make_connect_button() -> Button:
	return _Panel.make_chip(self)


func _login(email: String, password: String) -> Dictionary:
	var app: String = manifest.code if manifest != null else ""
	var response := await _post_json(_config.falcon_url + "/api/auth/login", {"email": email, "password": password, "client": _client_info(app)})
	if not response.ok and response.code == "app_unknown" and app != "":
		# the game is not registered as a Falcon client app yet: the session is labelled as the launcher's
		response = await _post_json(_config.falcon_url + "/api/auth/login", {"email": email, "password": password, "client": _client_info("")})
	if not response.ok:
		return {"ok": false, "code": _error_code(response)}
	var token := _J.text(response.json, "token")
	return {"ok": token != "", "code": "" if token != "" else "unexpected", "token": token}


func _issue_device_key(token: String) -> Dictionary:
	var response := await _post_json(_config.falcon_url + "/api/me/device-keys", {"applicationUuid": application_uuid,
		"deviceName": _device_name(), "devicePlatform": "ios" if _platform() == "ios" else "android"}, token)
	if not response.ok:
		return {"ok": false, "code": _error_code(response)}
	var json: Dictionary = response.json
	var uuid := _J.normalize_uuid(_J.text(json, "customerUuid"))
	if uuid == "" or _J.text(json, "deviceKey") == "":
		return {"ok": false, "code": "unexpected"}
	return {"ok": true, "code": "", "customer_uuid": uuid, "json": json}


func _remember_device_key(key: Dictionary, email: String, shared: bool) -> void:
	var json: Dictionary = key.json
	var region = json.get("region")
	var list: Array = []
	for t in json.get("targets", []):
		if t is Dictionary:
			list.append({"platform": _J.text(t, "platform"), "target": _J.text(t, "username") if t.has("username") else _J.text(t, "target")})
	_remember({
		"customer_uuid": key.customer_uuid,
		"device_key": _J.text(json, "deviceKey"),
		"eventfabric_url": _J.text(region, "eventFabricUrl") if region is Dictionary else "",
		"region": _J.text(region, "code") if region is Dictionary else "",
		"targets": list,
		"source": "device",
		"email": email,
		"shared": shared,
	})


## {email, token, customerUuid} of the shared sign-in, {} when there is none (or no plugin).
func _shared_account() -> Dictionary:
	if _shared == null:
		return {}
	var parsed = _J.parse(str(_shared.call("get_account")))
	return parsed if parsed is Dictionary and _J.text(parsed, "token") != "" else {}


## Another StreamEmber game on this phone signed in (or out): follow it. Runs before every identity lookup.
func _sync_shared_account() -> void:
	if _shared == null or _minting:
		return
	var account := _shared_account()
	var mine := str(_stored.get("email", ""))
	if account.is_empty():
		if bool(_stored.get("shared", false)):
			_log("info", "Signed out in another StreamEmber game on this device.")
			clear_identity.call_deferred()
		return
	if not _stored.is_empty() and mine == _J.text(account, "email"):
		return
	_minting = true
	var key := await _issue_device_key(_J.text(account, "token"))
	_minting = false
	if key.ok:
		_log("info", "Connected with the StreamEmber sign-in of this device (%s)." % _J.text(account, "email"))
		_remember_device_key(key, _J.text(account, "email"), true)
	elif key.code in ["invalid_session", "unauthorized"]:
		_shared.call("clear_account")  # the session ended (password change, sign-out elsewhere)


func _client_info(app: String) -> Dictionary:
	return {"app": app, "deviceName": _device_name(), "platform": _platform()}


func _platform() -> String:
	return "android" if OS.has_feature("android") else "ios" if OS.has_feature("ios") else "web" if OS.has_feature("web") else "desktop"


func _device_name() -> String:
	var name := OS.get_model_name() if _platform() in ["android", "ios"] else OS.get_name()
	return (name if name != "" and name != "GenericDevice" else _platform()).left(80)


func _error_code(response: Dictionary) -> String:
	if response.ok:
		return ""
	if int(response.status) == 0:
		return "network"
	return str(response.code) if str(response.code) != "" else "http_%d" % int(response.status)


## True when a stored (device / manual) identity exists, even before the module is active.
func has_stored_identity() -> bool:
	if _stored.is_empty():
		_load_identity()
	return not _stored.is_empty()


# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	# Connection, presence and hotkeys keep running while the game is paused; actions wait in the queue.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Engine.has_singleton("StreamEmberAccount"):
		_shared = Engine.get_singleton("StreamEmberAccount")


func _process(_delta: float) -> void:
	if not _activated:
		# First frame: the scene's _ready() handlers are registered by now.
		if not _disabled:
			_activate()
		return
	var now := _now()
	if _client != null:
		_client.poll(now)
	if _capture != null:
		_capture.poll(now)
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
	_stop_collection()
	if _client != null:
		_client.stop()
		_client = null
	if _activated:
		_activated = false
		is_active = false
		_log("info", "Module '%s' stopped." % manifest.code)
		host.live_stopped.emit()


## Project settings → _config. Runs at activation, or earlier when a scene's _ready() already calls the API.
func _load_config() -> void:
	if not _config.is_empty():
		return
	for key in DEFAULTS:
		_config[key] = ProjectSettings.get_setting("streamember/" + key, DEFAULTS[key])
	for key in ["eventfabric_url", "falcon_url", "launcher_url"]:
		var url := str(_config[key]).strip_edges().trim_suffix("/")
		_config[key] = url if url != "" else DEFAULTS[key]
	_config.secret_key = str(_config.secret_key).strip_edges()
	_config.tiktoksign_url = str(_config.tiktoksign_url).strip_edges().trim_suffix("/")
	_config.collect = str(_config.collect).strip_edges().to_lower()
	_config.presence_seconds = clampi(int(_config.presence_seconds), 5, 300)
	_launcher_available = bool(_config.probe_launcher) and not OS.has_feature("android") and not OS.has_feature("ios")
	_config.settings_seconds = clampi(int(_config.settings_seconds), 10, 3600)
	_open_log()


func _activate() -> void:
	_load_config()
	_load_identity()
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
	language = TranslationServer.get_locale().get_slice("_", 0)
	settings = manifest.setting_defaults_values()
	_settings_fingerprint = _J.stable_text(settings.raw()) + _J.stable_text([])
	settings_revision = "schema"
	teams = []
	_activated = true
	is_active = true
	_log("info", "Module '%s' (%s) active; StreamEmber for Godot %s, Godot %s." % [
		manifest.code, manifest.application_uuid, VERSION, Engine.get_version_info().string])
	host.live_started.emit()
	host.settings_changed.emit(settings)
	_validate_handlers()
	_resolve_identity()


func _validate_handlers() -> void:
	if host.action_received.get_connections().is_empty():
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
	if _launcher_available:
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
	# no launcher: the in-game sign-in of this game, or of another StreamEmber game on this phone (shared account)
	await _sync_shared_account()
	if not _stored.is_empty():
		var url := str(_stored.eventfabric_url)
		if str(_config.eventfabric_url) != "":
			url = str(_config.eventfabric_url)
		else:
			# Falcon assigns the customer's EventFabric machine; it may change (wrong_node / node_disabled), so ask every time.
			var region := await _get_json(_config.falcon_url + "/public/customers/" + str(_stored.customer_uuid).uri_encode() + "/region")
			var fresh := _J.text(region.json, "eventFabricUrl").trim_suffix("/") if region.ok else ""
			if fresh != "" and fresh != url:
				url = fresh
				_stored.eventfabric_url = url
				_save_identity()
		_customer_problem = ""
		return {"uuid": _stored.customer_uuid, "secret_key": _stored.device_key, "eventfabric_url": url,
			"region": _stored.region, "source": _stored.source}
	if not _launcher_available:
		_customer_problem = "no_identity"
	return {}


func _identity_resolved(found: Dictionary) -> void:
	if found.is_empty():
		if _customer_problem == "no_identity":
			return  # phone without a sign-in: solo play, nothing to say
		if not _warned_no_customer:
			_warned_no_customer = true  # logged only: a player who never connects sees nothing (the chip shows the state)
			var offline := _customer_problem == "launcher_unreachable"
			_log("info", "No customer (%s). Retrying every %d s." % [
				"launcher not reachable at " + _config.launcher_url if offline else "launcher not signed in", _config.presence_seconds])
		return
	var customer: String = found.uuid
	var same: bool = customer == customer_uuid and found.secret_key == _secret_key and found.eventfabric_url == _eventfabric_url
	if same and _client != null:
		return
	var same_uuid: bool = customer == customer_uuid
	_warned_no_customer = false
	if found.secret_key != "" and found.secret_key != _secret_key:
		_warned_no_write = false
	var source_changed: bool = found.source != _customer_source
	_customer_source = found.source
	identity_source = found.source
	customer_uuid = customer
	_secret_key = found.secret_key
	_eventfabric_url = found.eventfabric_url
	_region_code = found.region
	var stored: bool = found.source in ["device", "manual"]
	targets = _stored.get("targets", []).duplicate(true) if stored else []
	_log("info", "Customer %s (%s, region %s, EventFabric %s, write %s)." % [customer, found.source,
		_region_code if _region_code != "" else "?", _eventfabric_url if _eventfabric_url != "" else "?", write_scope if can_write else "off"])
	if same_uuid and _client != null and not source_changed:
		return  # only key/URL changed: the client asks for the URL again on its next connect
	_stop_collection()
	if _client != null:
		_client.stop()
	_announced_connection = false
	_client = _Client.new(_resolve_ws_base, customer, manifest.application_uuid, _log)
	_client.action_received.connect(_from_network)
	_client.event_received.connect(_event_from_network)
	_client.connection_changed.connect(_on_connection_changed.bind(_client))
	_client.config_changed.connect(_on_config_changed.bind(_client))
	_client.identity_rejected.connect(_on_identity_rejected.bind(_client))
	_client.stream_status.connect(_on_stream_status.bind(_client))
	_start_collection()
	host.identity_changed.emit()
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
	host.connection_changed.emit(connected)
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


# ─── Collection ──────────────────────────────────────────────────────────────

## The user's "Reconnect" after a final status (stream ended / not live …): asks collection again.
func restart_collection() -> void:
	if _capture != null:
		_capture.restart()
	if _client != null:
		_client.restart()  # no-op unless EventFabric collects (collect=self)


## "" (nobody: the launcher produces, or no key), "device" (this device collects TikTok itself, D12) or "server"
## (EventFabric collects the key owner's enabled platforms, collect=self).
func _collect_mode() -> String:
	var setting := str(_config.get("collect", "auto"))
	if setting == "off" or _secret_key == "" or _customer_source in ["launcher", "manual"]:
		return ""
	if setting == "auto":
		return "device" if OS.has_feature("android") or OS.has_feature("ios") else "server"
	return setting if setting in ["device", "server"] else ""


func _start_collection() -> void:
	streams = {}
	collect_mode = _collect_mode()
	var tiktok := ""
	var others := false
	for t in targets:
		if str(t.platform) == "tiktok":
			if tiktok == "":
				tiktok = str(t.target)
		else:
			others = true
	if collect_mode == "device" and tiktok == "":
		collect_mode = "server"
	# Phone: TikTok from this device; the other platforms (and TikTok while this device sends it, launcher priority) on EventFabric.
	if collect_mode == "server" or (collect_mode == "device" and others):
		_client.set_collect(_secret_key)
	if collect_mode == "device":
		_capture = _Capture.new(str(_config.tiktoksign_url), _secret_key, customer_uuid, application_uuid, tiktok,
			_get_json, _resolve_ws_base, _log)
		_capture.status.connect(_on_capture_status.bind(_capture))
		_capture.fallback.connect(_on_capture_fallback.bind(_capture))
		_capture.start()
	if collect_mode != "":
		_log("info", "Collection: %s%s." % [collect_mode, " (@" + tiktok + " on this device)" if collect_mode == "device" else ""])


func _stop_collection() -> void:
	if _capture != null:
		_capture.stop()
		_capture = null
	streams = {}
	collect_mode = ""


func _on_capture_status(state: String, reason: String, capture: _Capture) -> void:
	if capture != _capture or not _activated:
		return
	_stream_changed({"platform": "tiktok", "target": capture.target, "status": state, "reason": reason,
		"since": int(Time.get_unix_time_from_system() * 1000), "source": "device"})


## This device cannot collect (signer refused, TikTok keeps refusing): EventFabric collects instead (collect=self).
func _on_capture_fallback(reason: String, capture: _Capture) -> void:
	if capture != _capture or not _activated or _client == null:
		return
	_capture = null
	collect_mode = "server"
	_client.set_collect(_secret_key)
	_client.reconnect()


func _on_stream_status(status: Dictionary, client: _Client) -> void:
	if client == _client and _activated:
		_stream_changed(status)


func _stream_changed(status: Dictionary) -> void:
	var key := _J.text(status, "platform") + ":" + _J.text(status, "target")
	var previous := _J.text(streams.get(key, {}), "status")
	streams[key] = status
	var state := _J.text(status, "status")
	if state in TERMINAL_STATUSES and state != previous:
		_notify(_message(state), WARNING)
	host.stream_changed.emit(status)


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
		if response.code in ["wrong_node", "node_disabled", "invalid_key", "key_rotated"] and _activated:
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
		host.settings_changed.emit(settings)


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

## Normalized events: drop duplicates (same id on replay/redelivery), hand to the game at once.
func _event_from_network(json: Dictionary) -> void:
	var id := _J.text(json, "id")
	if id == "" or _seen_events.has(id):
		return
	_seen_events[id] = true
	_seen_events_order.append(id)
	while _seen_events_order.size() > REMEMBERED_IDS:
		_seen_events.erase(_seen_events_order.pop_front())
	host.activity_received.emit(json)


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
	if not host.action_received.get_connections().is_empty():
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
	if not host.action_received.get_connections().is_empty():
		delivered = true
	host.action_received.emit(action)
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
		_notify("%s | müşteri: %s (%s) | EventFabric: %s | yazma: %s | toplama: %s | ayarlar: %s | kuyruk: %d" % [manifest.name,
			customer_uuid.substr(0, 8) + "…" if customer_uuid != "" else "yok", identity_source if identity_source != "" else "-",
			"bağlı" if live_connected else "bağlı değil", write_scope if can_write else "yok",
			",".join(PackedStringArray(streams.values().map(func(x) -> String: return _J.text(x, "target") + "=" + _J.text(x, "status")))) if not streams.is_empty() else "-", settings_revision, _incoming.size()])
	elif index == 10:
		_refresh_settings(true)
		_notify("Ayarlar yeniden yükleniyor")
	elif index == 11:
		reset_gcore(func(ok: bool) -> void:
			_notify("Oturum sıfırlandı" if ok else "Oturum sıfırlanamadı", INFO if ok else ERROR))


# ─── HTTP, log, notifications ────────────────────────────────────────────────

## GET → {ok, status (0 = no answer), json, error}. The token goes only into the header, never into logs.
## {ok, status, json, code, error}. code = contract error code ("wrong_node"…) of a non-2xx body, "" otherwise.
func _get_json(url: String, extra_headers := PackedStringArray()) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	add_child(request)
	var headers := PackedStringArray(["Accept: application/json", "User-Agent: StreamEmber-Godot/" + VERSION])
	headers.append_array(extra_headers)
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


## POST JSON body → same result shape as _get_json.
## token: Falcon session (ses_), sent only as Authorization: Bearer.
func _post_json(url: String, body: Dictionary, token := "") -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	add_child(request)
	var headers := PackedStringArray(["Accept: application/json", "Content-Type: application/json", "User-Agent: StreamEmber-Godot/" + VERSION])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var error := request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		request.queue_free()
		return {"ok": false, "status": 0, "json": {}, "code": "", "error": error_string(error)}
	var answer: Array = await request.request_completed
	request.queue_free()
	if answer[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "json": {}, "code": "", "error": "no answer (result %d)" % answer[0]}
	var status: int = answer[1]
	var raw: PackedByteArray = answer[3]
	var parsed = _J.parse(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var json: Dictionary = parsed if parsed is Dictionary else {}
	var ok := status >= 200 and status < 300
	var code := "" if ok else _J.text(json, "code")
	var message := "" if ok else _J.text(json, "message")
	return {"ok": ok, "status": status, "json": json, "code": code,
		"error": "" if ok else "HTTP %d%s%s" % [status, " " + code if code != "" else "", ": " + message if message != "" else ""]}


func _load_identity() -> void:
	var cf := ConfigFile.new()
	if cf.load(IDENTITY_PATH) != OK:
		return
	var uuid := _J.normalize_uuid(str(cf.get_value("identity", "customer_uuid", "")))
	if uuid == "":
		return
	var list: Array = []
	for item in cf.get_value("identity", "targets", []):
		if item is Dictionary:
			list.append({"platform": str(item.get("platform", "tiktok")), "target": str(item.get("target", ""))})
	_stored = {
		"customer_uuid": uuid,
		"device_key": str(cf.get_value("identity", "device_key", "")),
		"eventfabric_url": str(cf.get_value("identity", "eventfabric_url", "")),
		"region": str(cf.get_value("identity", "region", "")),
		"targets": list,
		"source": str(cf.get_value("identity", "source", "manual")),
		"email": str(cf.get_value("identity", "email", "")),
		"shared": bool(cf.get_value("identity", "shared", false)),
	}


func _save_identity() -> void:
	DirAccess.make_dir_recursive_absolute(IDENTITY_PATH.get_base_dir())
	var cf := ConfigFile.new()
	for key in _stored:
		cf.set_value("identity", key, _stored[key])
	cf.set_value("identity", "saved_at", Time.get_datetime_string_from_system(true))
	cf.save(IDENTITY_PATH)


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
	host.notified.emit(text, level)
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
