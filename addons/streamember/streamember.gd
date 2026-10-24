extends Node
## StreamEmber Live for Godot (autoload "StreamEmber"). Same behaviour as StreamEmber.Live in the GTA V / RDR2
## runtimes: identity, EventFabric connection, Falcon settings, presence, action dispatch, the in-game StreamEmber
## sign-in (phones) and its connect panel.
##
## This file is the stable contract the game is built with. The work is done by the core (core/live.gd), which
## updates itself from the CDN without a new game build (boot.gd): this node creates the newest valid core as its
## child and forwards the API below to it. Everything runs on the main thread; handlers may call the game freely.
##
##   func _ready() -> void:
##       StreamEmber.on("enemy.spawn", _spawn)
##       StreamEmber.settings_changed.connect(_apply_settings)
##       $Lobby.add_child(StreamEmber.make_connect_button())   # small "● Live" chip, opens the connect panel

## The module became active (first frame). Settings are already the schema defaults.
signal live_started
## The game is closing: remove everything you created.
signal live_stopped
## Every action (after the on(...) handlers ran). action.handled tells if one did.
signal action_received(action)
## Every normalized platform event of this streamer + game (comment, like, join, follow, share, gift …), deduplicated by
## event id, delivered on the main thread right away (not held while paused). json: EventContracts normalized event
## (`id`, `platform`, `catalogId`, `kind`, `category`, `stream.roomId`, `actor.id/username/nickname/avatarUrl`, payload).
## Use it for presence (who is active); game effects still come as actions. Since 0.7.0.
signal activity_received(event: Dictionary)
## Settings changed (also once at start with the schema defaults). Argument: StreamEmberValues.
signal settings_changed(settings)
signal connection_changed(connected: bool)
## The live identity changed (launcher, in-game sign-in / sign-out, another StreamEmber game on this phone signed in).
## Read customer_uuid / identity_source / account_email.
signal identity_changed
## State of a collected stream (stream.status, or this device's own TikTok collection): {platform, target, status,
## reason, since, restartAllowedAt, source}. status: connecting | collecting | reconnecting | grace | ended | not_live |
## not_found | denied. The last four are final: nothing asks again until restart_collection().
signal stream_changed(status: Dictionary)
## Status texts the core shows (connected, test hotkeys, problems). level: 0 info, 1 warning, 2 error.
signal notified(text: String, level: int)

## Version of this addon (the stable part + the embedded core). core_version is the core that actually runs.
const VERSION := "0.9.0"
## Contract with the core: a downloaded core runs only if its API is the same.
const HOST_API := 1
const _Boot := preload("boot.gd")
const _Embedded := preload("core/live.gd")
const _Values := preload("streamember_values.gd")
const MODULE_PATH: String = _Embedded.MODULE_PATH
const SCHEMA_PATH: String = _Embedded.SCHEMA_PATH
const LOG_PATH: String = _Embedded.LOG_PATH
## Project Settings → streamember/<key> (registered by the editor plugin).
const DEFAULTS: Dictionary = _Embedded.DEFAULTS
const TERMINAL_STATUSES: Array = _Embedded.TERMINAL_STATUSES
const INFO := 0
const WARNING := 1
const ERROR := 2

## Version of the running core (embedded, or newer from the CDN) and where it came from ("embedded" | "cdn").
var core_version := VERSION
var core_source := "embedded"

## null until the module is active.
var manifest:
	get:
		return _core.manifest
var is_active: bool:
	get:
		return _core.is_active
var customer_uuid: String:
	get:
		return _core.customer_uuid
## Current settings: schema defaults merged with the streamer's Falcon config.
var settings:
	get:
		return _core.settings
var settings_revision: String:
	get:
		return _core.settings_revision
## Active teams of the streamer's config, in order (StreamEmberAction.Team); empty when the game has no teams.
var teams: Array:
	get:
		return _core.teams
## Two-letter UI language of the game ("tr", "en"…).
var language: String:
	get:
		return _core.language
## Where the identity came from: "" (none), "config", "launcher", "device" (in-game sign-in), "manual".
var identity_source: String:
	get:
		return _core.identity_source
## Platforms of an in-game sign-in (from Falcon): [{platform, target}].
var targets: Array:
	get:
		return _core.targets
## Who collects for this identity: "" (nobody / the launcher), "device" (this device, TikTok) or "server" (EventFabric).
var collect_mode: String:
	get:
		return _core.collect_mode
## "platform:target" → last stream status (see stream_changed).
var streams: Dictionary:
	get:
		return _core.streams
var application_uuid: String:
	get:
		return _core.application_uuid
var live_connected: bool:
	get:
		return _core.live_connected
## A write key (secret key sek_… or device key dek_…) and the EventFabric URL are known (presence needs them).
var can_write: bool:
	get:
		return _core.can_write
## "full" (secret key), "device" (device key: presence + collection only) or "" (no key).
var write_scope: String:
	get:
		return _core.write_scope
## E-mail of the in-game StreamEmber sign-in ("" for a launcher identity or none).
var account_email: String:
	get:
		return _core.account_email()
## While true, live actions wait in the queue (menus, cutscenes, loading). A paused tree does the same.
var hold_actions: bool:
	get:
		return _core.hold_actions
	set(value):
		_core.hold_actions = value
## Optional Theme (fonts) for the core's connect panel and chip.
var ui_theme: Theme:
	get:
		return _core.ui_theme
	set(value):
		_core.ui_theme = value

var _core: Node


func _init() -> void:
	var picked: Dictionary = _Boot.pick(VERSION, HOST_API) if _Boot.enabled() else {"script": _Embedded, "version": VERSION, "source": "embedded"}
	_core = picked.script.new()
	if _core == null:  # cannot happen with the embedded core; a broken download is refused by pick()
		_core = _Embedded.new()
		picked = {"version": VERSION, "source": "embedded"}
	core_version = picked.version
	core_source = picked.source
	_core.name = "Core"
	_core.host = self
	add_child(_core)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_core.call("_log", "info", "Core %s (%s); addon %s." % [core_version, core_source, VERSION])
	if not _Boot.enabled():
		return
	if core_source == "cdn":
		get_tree().create_timer(10.0, true, false, true).timeout.connect(func() -> void: _Boot.confirm())
	var downloader := _Boot.Downloader.new()
	downloader.cdn = str(ProjectSettings.get_setting("streamember/cdn_url", DEFAULTS.get("cdn_url", "https://cdn.streamember.com")))
	downloader.running = core_version
	downloader.host_api = HOST_API
	downloader.boot = _Boot
	downloader.log_func = func(level: String, text: String) -> void: _core.call("_log", level, text)
	add_child(downloader)


# ─── API (forwarded to the core) ─────────────────────────────────────────────

## Registers a handler for a schema action id. handler: func(action: StreamEmberAction).
func on(action_id: String, handler: Callable) -> void:
	_core.on(action_id, handler)


## Removes a handler registered with on(...). Freed objects are dropped automatically.
func off(action_id: String, handler: Callable) -> void:
	_core.off(action_id, handler)


## Reads the Falcon settings now; settings_changed follows.
func reload_settings() -> void:
	_core.reload_settings()


## Resets the live session (GCore counters) for this streamer and game. Needs the launcher's secret key. done: func(ok).
func reset_gcore(done: Callable = Callable()) -> void:
	_core.reset_gcore(done)


## "Reconnect" after a final stream status (ended, not_live, not_found, denied).
func restart_collection() -> void:
	_core.restart_collection()


## The connect panel: StreamEmber sign-in on a phone, the connection status, sign-out. Built and translated by the core.
func open_connect_panel() -> void:
	_core.open_panel()


## A small "● Live" chip (connection state, opens the panel). The game places it, e.g. in a lobby corner.
func make_connect_button() -> Button:
	return _core.make_connect_button()


## Phones (and debug builds): StreamEmber e-mail + password → this game's device key. {ok, code}. The panel uses it.
func sign_in(email: String, password: String) -> Dictionary:
	return await _core.sign_in(email, password)


## Signs out on this device (also the shared sign-in of the other StreamEmber games on this phone).
func sign_out() -> void:
	await _core.sign_out()


## True where the in-game sign-in is offered (phones; debug builds for testing). A computer uses the launcher.
func can_sign_in() -> bool:
	return _core.can_sign_in()


## Identity without a launcher: {customer_uuid, device_key?, eventfabric_url?, region?, targets?, source, email?}.
func set_identity(info: Dictionary) -> void:
	_core.set_identity(info)


## Forgets the stored identity of this game (the shared sign-in stays; sign_out() removes both).
func clear_identity() -> void:
	_core.clear_identity()


## True when this game has a stored identity, even before the module is active.
func has_stored_identity() -> bool:
	return _core.has_stored_identity()
