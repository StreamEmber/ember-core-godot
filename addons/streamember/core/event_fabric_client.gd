extends RefCounted
## EventFabric realtime connection (StreamEmber.Live EventFabricClient), polled from the main thread:
## /events/ws?format=json&customerUuid=…&applicationUuid=…  packetType=action → action_received; packetType=event
## (normalized platform events of the same customer + application) → event_received.
## The WebSocket base URL is asked from the resolver before every connect (the customer's EventFabric machine may
## change; a new URL drops the replay cursor). system frames: config.changed → config_changed; error wrong_node /
## node_disabled / key_rotated / invalid_key → identity_rejected + reconnect; stream.status → stream_status.
## The last cursor is sent as replay=true&cursor=… after a disconnect.
## Collection (set_collect): collect=self&key=… asks EventFabric to collect the key owner's enabled platforms. Once
## every collected stream is final (ended / not_live / not_found / denied) the client stops asking; only restart()
## asks again (restart=manual). Reconnect after 1, 2, 4, 8, 15, 30 s ±30%; ping every 20 s.

signal action_received(json: Dictionary)
## A normalized platform event (comment, like, join, follow, share, gift …), as JSON (EventContracts NORMALIZED_EVENT).
signal event_received(json: Dictionary)
signal connection_changed(connected: bool)
## Falcon settings changed for this application.
signal config_changed
## EventFabric refused this identity: "wrong_node" | "node_disabled" | "key_rotated" | "invalid_key".
signal identity_rejected(code: String)
## stream.status of a collected / watched stream: {platform, target, status, reason, since, retryAt, restartAllowedAt,
## adapter, source}. status: connecting | collecting | reconnecting | grace | ended | not_live | not_found | denied.
signal stream_status(status: Dictionary)

const _J := preload("res://addons/streamember/streamember_json.gd")
const BACKOFF_SECONDS := [1, 2, 4, 8, 15, 30]
## Final stream statuses: collection is not asked again automatically.
const TERMINAL := ["ended", "not_live", "not_found", "denied"]
const REJECT_CODES := ["wrong_node", "node_disabled", "key_rotated", "invalid_key"]
const MAX_FRAME_BYTES := 4 * 1024 * 1024
const CONNECT_TIMEOUT := 10.0
const PING_SECONDS := 20.0

var customer_uuid: String
var application_uuid: String
var connected := false

var _ws_base := ""
## Key asking collect=self ("" = listen only).
var _collect_key := ""
## false once every collected stream is final; restart() turns it back on.
var _collecting := false
var _restart_next := false
## "platform:target" → last stream.status.
var streams := {}
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


## Ask EventFabric to collect the key owner's enabled platforms (collect=self). key: dek_… / sek_… of this customer; "" = listen only.
func set_collect(key: String) -> void:
	_collect_key = key
	_collecting = key != ""


func collecting() -> bool:
	return _collecting


## User's "Reconnect": asks collection again (restart=manual) on a fresh connection. EventFabric allows one per 15 s per
## stream; earlier than restartAllowedAt it answers with the remembered status.
func restart() -> void:
	if _collect_key == "":
		return
	_collecting = true
	_restart_next = true
	reconnect()


## Reconnects at once (the URL is resolved again); a transport reconnect never carries restart=manual.
func reconnect() -> void:
	if _peer != null:
		_drop(0.0, false, "reconnect")
	_next_connect_at = 0.0


func build_url() -> String:
	var url := _ws_base + "/events/ws?format=json&customerUuid=" + customer_uuid.uri_encode() \
		+ "&applicationUuid=" + application_uuid.uri_encode()
	if _collecting and _collect_key != "":
		url += "&collect=self&key=" + _collect_key.uri_encode()
		if _restart_next:
			url += "&restart=manual"
	if _cursor.strip_edges() != "":
		url += "&replay=true&cursor=" + _cursor.uri_encode()
	return url


## Seconds to wait before the next attempt, without jitter (exposed for tests).
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
	_restart_next = false  # a transport reconnect never repeats the user's restart
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
	# ±30%: clients dropped together do not come back together
	_next_connect_at = now + next_delay() * randf_range(0.7, 1.3)


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
		"event":
			if frame.get("event") is Dictionary:
				event_received.emit(frame["event"])


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
		# EventFabric sends it only to sockets of this customer + application.
		config_changed.emit()
	elif type == "stream.status":
		# Details travel as a JSON string in system.message.
		var parsed = _J.parse(_text(system.get("message"))) if not (system.get("message") is Dictionary) else system["message"]
		if not (parsed is Dictionary) or _text(parsed.get("platform")) == "":
			return
		streams[_text(parsed.get("platform")) + ":" + _text(parsed.get("target"))] = parsed
		if _collecting and streams.values().all(func(s) -> bool: return _text(s.get("status")) in TERMINAL):
			_collecting = false  # final for every stream: keep listening, ask again only on restart()
		stream_status.emit(parsed)
	elif type == "error" or type == "key_rotated":
		var code := _text(system.get("code")) if type == "error" else type
		_log.call("warn", "EventFabric: " + code + " " + _text(system.get("message")))
		if code in REJECT_CODES:
			identity_rejected.emit(code)
			_drop(0.0, false, code)  # the next connect asks the resolver again
			_next_connect_at = 0.0


func cursor() -> String:
	return _cursor


static func _text(value) -> String:
	return _J.scalar_text(value)
