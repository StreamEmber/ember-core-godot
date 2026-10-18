extends RefCounted
## EventFabric realtime connection (StreamEmber.Live EventFabricClient), polled from the main thread:
## /events/ws?format=json&customerUuid=…&applicationUuid=…  Only packetType=action frames are forwarded.
## The WebSocket base URL is asked from the resolver before every connect (region may change; a new URL drops
## the replay cursor). system frames: config.changed → config_changed; error wrong_region/key_rotated/invalid_key
## → identity_rejected + reconnect. The last cursor is sent as replay=true&cursor=… after a disconnect.
## Reconnect after 1, 2, 5, 10, 20, 30 s; ping every 20 s.

signal action_received(json: Dictionary)
signal connection_changed(connected: bool)
## Falcon settings changed for this application.
signal config_changed
## EventFabric refused this identity: "wrong_region" | "key_rotated" | "invalid_key".
signal identity_rejected(code: String)

const _J := preload("streamember_json.gd")
const BACKOFF_SECONDS := [1, 2, 5, 10, 20, 30]
const MAX_FRAME_BYTES := 4 * 1024 * 1024
const CONNECT_TIMEOUT := 10.0
const PING_SECONDS := 20.0

var customer_uuid: String
var application_uuid: String
var connected := false

var _ws_base := ""
## func() -> String (may await): "wss://…" or "" when unknown.
var _resolve_ws_base: Callable
var _resolving := false
var _log: Callable
var _peer: WebSocketPeer
var _cursor := ""
var _attempts := 0
var _ever_connected := false
var _next_connect_at := 0.0
var _connect_started := 0.0
var _next_ping := 0.0
var _stopped := false


## resolve_ws_base: func() -> String (may await). log: func(level: String, message: String), level = "info" | "warn" | "debug".
func _init(resolve_ws_base: Callable, customer: String, application: String, log: Callable) -> void:
	_resolve_ws_base = resolve_ws_base
	customer_uuid = customer
	application_uuid = application
	_log = log


## Call every frame with a monotonic time in seconds.
func poll(now: float) -> void:
	if _stopped:
		return
	if _peer == null:
		if now >= _next_connect_at and not _resolving:
			_resolve_and_open(now)
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if now - _connect_started > CONNECT_TIMEOUT:
				_drop(now, true, "connect timeout")
		WebSocketPeer.STATE_OPEN:
			if not connected:
				connected = true
				_attempts = 0
				_next_ping = now + PING_SECONDS
				_log.call("info", ("Reconnected" if _ever_connected else "Connected") + " to EventFabric (application " + application_uuid + ").")
				_ever_connected = true
				connection_changed.emit(true)
			while _peer != null and _peer.get_available_packet_count() > 0:
				var packet := _peer.get_packet()
				if _peer.was_string_packet():
					_handle(packet.get_string_from_utf8())
			if _peer != null and now >= _next_ping:
				_next_ping = now + PING_SECONDS
				_peer.send_text("{\"type\":\"ping\"}")
		WebSocketPeer.STATE_CLOSED:
			var was_open := connected
			if was_open:
				_log.call("warn", "EventFabric connection closed (%d); reconnecting." % _peer.get_close_code())
			_drop(now, not was_open, "closed (%d %s)" % [_peer.get_close_code(), _peer.get_close_reason()])


func stop() -> void:
	if _stopped:
		return
	_stopped = true
	if _peer != null:
		_peer.close(1000, "bye")
		_peer = null
	if connected:
		connected = false
		connection_changed.emit(false)


func build_url() -> String:
	var url := _ws_base + "/events/ws?format=json&customerUuid=" + customer_uuid.uri_encode() \
		+ "&applicationUuid=" + application_uuid.uri_encode()
	if _cursor.strip_edges() != "":
		url += "&replay=true&cursor=" + _cursor.uri_encode()
	return url


## Seconds to wait before the next attempt (exposed for tests).
func next_delay() -> int:
	return BACKOFF_SECONDS[clampi(_attempts - 1, 0, BACKOFF_SECONDS.size() - 1)]


func _resolve_and_open(now: float) -> void:
	_resolving = true
	var ws_base: String = str(await _resolve_ws_base.call()).strip_edges().trim_suffix("/")
	_resolving = false
	if _stopped or _peer != null:
		return
	if ws_base == "":
		_drop(now, true, "EventFabric URL unknown (launcher not reachable?)")
		return
	if ws_base != _ws_base:
		if _ws_base != "":
			_log.call("info", "EventFabric moved to " + ws_base + "; replay cursor dropped.")
		_ws_base = ws_base
		_cursor = ""
	_open(now)


func _open(now: float) -> void:
	_peer = WebSocketPeer.new()
	# Godot's default inbound buffer is 64 KiB; replay frames can be larger.
	_peer.inbound_buffer_size = MAX_FRAME_BYTES
	_peer.max_queued_packets = 4096
	_connect_started = now
	var url := build_url()
	_log.call("debug", "Connecting to " + url.get_slice("?", 0))
	var error := _peer.connect_to_url(url)
	if error != OK:
		_drop(now, true, error_string(error))


func _drop(now: float, failed: bool, reason: String) -> void:
	if _peer != null and _peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_peer.close()
	_peer = null
	if failed:
		_attempts += 1
		if _attempts <= 3 or _attempts % 10 == 0:
			_log.call("warn", "EventFabric connection failed (attempt %d): %s" % [_attempts, reason])
	if connected:
		connected = false
		connection_changed.emit(false)
	_next_connect_at = now + next_delay()


## Exposed for tests: handles one text frame.
func handle_frame(text: String) -> void:
	_handle(text)


func _handle(text: String) -> void:
	var frame = _J.parse(text)
	if not (frame is Dictionary):
		return
	var frame_cursor := _text(frame.get("cursor"))
	if frame_cursor != "":
		_cursor = frame_cursor
	match _text(frame.get("packetType")):
		"action":
			if frame.get("action") is Dictionary:
				action_received.emit(frame["action"])
		"system":
			if frame.get("system") is Dictionary:
				_handle_system(frame["system"])
		# packetType=event: raw events are not needed in game (GCore turns them into actions).


func _handle_system(system: Dictionary) -> void:
	var type := _text(system.get("type"))
	_log.call("debug", "system: " + JSON.stringify(system))
	if system.get("cursorExpired") == true:
		var reason := _text(system.get("cursorExpiredReason"))
		if reason == "boot_changed":
			_log.call("info", "EventFabric was restarted; live actions resumed.")
		else:
			_log.call("warn", "Replay window passed (%s); actions sent while disconnected may have been missed." % reason)
	if type == "replay.completed" and system.get("hasMore") == true:
		if _cursor.strip_edges() != "" and _peer != null:
			_peer.send_text(JSON.stringify({"type": "replay.next", "cursor": _cursor, "limit": 100}))
	elif type == "command.rejected":
		_log.call("warn", "EventFabric rejected a command: " + _text(system.get("code")) + " " + _text(system.get("message")))
	elif type == "config.changed":
		var application := _text(system.get("applicationUuid"))
		if application == "" or application == application_uuid:
			config_changed.emit()
	elif type == "error" or type == "key_rotated":
		var code := _text(system.get("code")) if type == "error" else type
		_log.call("warn", "EventFabric: " + code + " " + _text(system.get("message")))
		if code in ["wrong_region", "key_rotated", "invalid_key"]:
			identity_rejected.emit(code)
			_drop(0.0, false, code)  # the next connect asks the resolver again
			_next_connect_at = 0.0


func cursor() -> String:
	return _cursor


static func _text(value) -> String:
	return _J.scalar_text(value)
