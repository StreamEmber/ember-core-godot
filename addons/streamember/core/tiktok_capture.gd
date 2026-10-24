extends RefCounted
## Mobile self-collection (D12): the phone collects its own TikTok LIVE and hands the frames to EventFabric, like the
## launcher does on PC. Polled from the main thread.
##   1. TikTokSign GET /connect?uniqueId=… (Authorization: Bearer <dek_/sek_>) → signed socket URL, cookies, user agent.
##   2. TikTok webcast socket from the phone's own IP: im_enter_room, hb every 10 s, ack when asked; a control
##      message with action 3 ends the stream.
##   3. Every push frame byte for byte → EventFabric /ingress/tiktok/webcast?target=…&key=… (binary).
## status(status, reason) uses the stream.status words. Final: not_live / not_found / ended (no automatic retry,
## restart() starts again). fallback(reason): self-collection is not possible (signer refused, socket keeps failing);
## the caller asks EventFabric to collect instead (collect=self). Every attempt signs again.

signal status(status: String, reason: String)
signal fallback(reason: String)

const HEARTBEAT_SECONDS := 10.0
const SILENT_SECONDS := 45.0
const CONNECT_TIMEOUT := 15.0
const BACKOFF_SECONDS := [1, 2, 4, 8, 15, 30]
## Consecutive failed attempts (no frame received) before falling back to EventFabric collection.
const FAILURES_BEFORE_FALLBACK := 3
const MAX_FRAME_BYTES := 4 * 1024 * 1024
const MAX_PENDING := 256
const STREAM_ENDED_ACTION := 3

var target: String
var running := false

var _sign_url: String
var _key: String
var _customer: String
var _application: String
## func(url: String, headers: PackedStringArray) -> {ok, status, json, code, error} (may await).
var _get_json: Callable
## func() -> String (may await): "wss://…" EventFabric root of the customer, "" when unknown.
var _resolve_ws_base: Callable
var _log: Callable
var _tiktok: WebSocketPeer
var _ingress: WebSocketPeer
var _pending: Array = []
var _room_id := 0
var _busy := false
var _opened := false
var _received := false
var _failures := 0
var _next_attempt_at := 0.0
var _next_ingress_at := 0.0
var _started_at := 0.0
var _next_heartbeat := 0.0
var _last_frame_at := 0.0


func _init(sign_url: String, key: String, customer: String, application: String, username: String,
		get_json: Callable, resolve_ws_base: Callable, log: Callable) -> void:
	_sign_url = sign_url.trim_suffix("/")
	_key = key
	_customer = customer
	_application = application
	target = username.strip_edges().trim_prefix("@").to_lower()
	_get_json = get_json
	_resolve_ws_base = resolve_ws_base
	_log = log


func start() -> void:
	running = true
	_failures = 0
	_next_attempt_at = 0.0


func stop() -> void:
	running = false
	_close_tiktok()
	if _ingress != null:
		_ingress.close(1000, "bye")
		_ingress = null
	_pending.clear()


## Call every frame with a monotonic time in seconds.
func poll(now: float) -> void:
	if not running:
		return
	_poll_ingress(now)
	if _tiktok == null:
		if now >= _next_attempt_at and not _busy:
			_attempt(now)
		return
	_tiktok.poll()
	match _tiktok.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if now - _started_at > CONNECT_TIMEOUT:
				_failed(now, "HANDSHAKE_REJECTED")
		WebSocketPeer.STATE_OPEN:
			if not _opened:
				_opened = true
				_last_frame_at = now
				_next_heartbeat = now + HEARTBEAT_SECONDS
				_send_tiktok(push_frame(0, "pb", "im_enter_room", enter_room(_room_id)))
				_log.call("info", "TikTok socket open (@%s, room %d); collecting on this device." % [target, _room_id])
			while _tiktok != null and _tiktok.get_available_packet_count() > 0:
				var bytes := _tiktok.get_packet()
				if not _tiktok.was_string_packet():
					_on_frame(now, bytes)
			if _tiktok == null:
				return
			if now >= _next_heartbeat:
				_next_heartbeat = now + HEARTBEAT_SECONDS
				_send_tiktok(push_frame(0, "pb", "hb", heartbeat(_room_id)))
			if now - _last_frame_at > SILENT_SECONDS:
				_failed(now, "UPSTREAM_SILENT")
		WebSocketPeer.STATE_CLOSED:
			_failed(now, "UPSTREAM_CLOSED (%d)" % _tiktok.get_close_code())


## The user's "Reconnect" after a final status.
func restart() -> void:
	stop()
	start()


func _attempt(now: float) -> void:
	_busy = true
	status.emit("connecting", "")
	var response: Dictionary = await _get_json.call(_sign_url + "/connect?uniqueId=" + target.uri_encode(),
		PackedStringArray(["Authorization: Bearer " + _key]))
	_busy = false
	if not running:
		return
	var json: Dictionary = response.json
	var state := _text(json.get("status"))
	if response.status == 400 or state == "not_found":
		_final("not_found", "USER_NOT_FOUND")
		return
	if state == "offline":
		_final("not_live", "NOT_LIVE")
		return
	if response.status == 401 or response.status == 403:
		_give_up("SIGNER_UNAUTHORIZED")
		return
	if response.status == 429:
		var problem = json.get("error")
		var wait := float(problem.get("retryAfterMs", 60000)) / 1000.0 if problem is Dictionary else 60.0
		_next_attempt_at = now + clampf(wait, 1.0, 3600.0)
		status.emit("reconnecting", "SIGNER_RATE_LIMITED")
		return
	var connection = json.get("connection")
	if not response.ok or state != "live" or not (connection is Dictionary) or _text(connection.get("url")) == "":
		_failed(now, "SIGN_FAILED " + str(response.error))
		return
	_room_id = int(_text(json.get("roomId")))
	_tiktok = WebSocketPeer.new()
	_tiktok.inbound_buffer_size = MAX_FRAME_BYTES
	_tiktok.max_queued_packets = 4096
	var headers := PackedStringArray(["Origin: https://www.tiktok.com",
		"User-Agent: " + (_text(connection.get("userAgent")) if _text(connection.get("userAgent")) != "" else "Mozilla/5.0")])
	if _text(connection.get("cookies")) != "":
		headers.append("Cookie: " + _text(connection.get("cookies")))
	_tiktok.handshake_headers = headers
	_opened = false
	_received = false
	_started_at = now
	var error := _tiktok.connect_to_url(_text(connection.get("url")))
	if error != OK:
		_failed(now, "HANDSHAKE_REJECTED " + error_string(error))


func _on_frame(now: float, bytes: PackedByteArray) -> void:
	_last_frame_at = now
	var push := parse_push_frame(bytes)
	var payload_type: String = push.get("payload_type", "")
	if payload_type not in ["msg", ""]:
		return  # hb / ack answers
	if not _received:
		_received = true
		_failures = 0
		status.emit("collecting", "")
	_forward(bytes)
	var batch := parse_fetch_result(expand(push.get("payload", PackedByteArray())))
	if batch.get("need_ack", false):
		_send_tiktok(push_frame(push.get("log_id", 0), "", "ack", batch.get("internal_ext", "").to_utf8_buffer()))
	if batch.get("stream_ended", false):
		_log.call("info", "TikTok reported the LIVE ended (@%s)." % target)
		_final("ended", "STREAM_END")


func _forward(bytes: PackedByteArray) -> void:
	if _ingress != null and _ingress.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ingress.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)
		return
	_pending.append(bytes)
	if _pending.size() > MAX_PENDING:
		_pending.pop_front()  # shortcut: oldest frames are dropped while EventFabric is unreachable; a disk queue if that matters


func _poll_ingress(now: float) -> void:
	if _ingress == null:
		if now >= _next_ingress_at and not _busy:
			_open_ingress(now)
		return
	_ingress.poll()
	match _ingress.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while not _pending.is_empty():
				_ingress.send(_pending.pop_front(), WebSocketPeer.WRITE_MODE_BINARY)
			while _ingress.get_available_packet_count() > 0:
				_ingress.get_packet()
		WebSocketPeer.STATE_CLOSED:
			_log.call("warn", "EventFabric ingress closed (%d %s); reopening." % [_ingress.get_close_code(), _ingress.get_close_reason()])
			_ingress = null
			# The EventFabric address is resolved again (the customer may have moved to another machine: wrong_node).
			_next_ingress_at = now + randf_range(2.0, 5.0)


func _open_ingress(now: float) -> void:
	_busy = true
	var base: String = str(await _resolve_ws_base.call()).strip_edges().trim_suffix("/")
	_busy = false
	if not running or _ingress != null:
		return
	if base == "":
		_next_ingress_at = now + 5.0
		return
	_ingress = WebSocketPeer.new()
	_ingress.outbound_buffer_size = MAX_FRAME_BYTES
	var url := base + "/ingress/tiktok/webcast?target=" + target.uri_encode() + "&customerUuid=" + _customer.uri_encode() \
		+ "&applicationUuid=" + _application.uri_encode() + "&key=" + _key.uri_encode()
	if _ingress.connect_to_url(url) != OK:
		_ingress = null
		_next_ingress_at = now + 5.0


func _failed(now: float, reason: String) -> void:
	var had_frames := _received
	_close_tiktok()
	if had_frames:
		_failures = 0  # a live connection dropped: sign again at once
		_next_attempt_at = now + 1.0
		status.emit("reconnecting", reason)
		return
	_failures += 1
	_log.call("warn", "TikTok self-collection failed (attempt %d, @%s): %s" % [_failures, target, reason])
	if _failures >= FAILURES_BEFORE_FALLBACK:
		_give_up(reason)
		return
	_next_attempt_at = now + BACKOFF_SECONDS[clampi(_failures - 1, 0, BACKOFF_SECONDS.size() - 1)] * randf_range(0.7, 1.3)
	status.emit("reconnecting", reason)


func _final(state: String, reason: String) -> void:
	stop()
	status.emit(state, reason)


func _give_up(reason: String) -> void:
	stop()
	_log.call("warn", "TikTok self-collection not possible (%s); EventFabric collects instead." % reason)
	fallback.emit(reason)


func _close_tiktok() -> void:
	if _tiktok != null and _tiktok.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_tiktok.close()
	_tiktok = null
	_opened = false
	_received = false


func _send_tiktok(bytes: PackedByteArray) -> void:
	if _tiktok != null and _tiktok.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_tiktok.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)


static func _text(value) -> String:
	return "" if value == null else str(value)


# ─── Minimal protobuf (only the fields the webcast handshake needs) ──────────

## WebcastPushFrame: 2 log_id, 6 payload_encoding, 7 payload_type, 8 payload.
static func push_frame(log_id: int, encoding: String, payload_type: String, payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	if log_id != 0:
		out.append_array(_tag(2, 0)); out.append_array(varint(log_id))
	if encoding != "":
		out.append_array(_bytes_field(6, encoding.to_utf8_buffer()))
	out.append_array(_bytes_field(7, payload_type.to_utf8_buffer()))
	out.append_array(_bytes_field(8, payload))
	return out


## WebcastImEnterRoomMessage: 1 room_id, 4 live_id = 12, 5 identity = "audience", 9 filter_welcome_msg = "0".
static func enter_room(room_id: int) -> PackedByteArray:
	var out := _tag(1, 0)
	out.append_array(varint(room_id))
	out.append_array(_tag(4, 0)); out.append_array(varint(12))
	out.append_array(_bytes_field(5, "audience".to_utf8_buffer()))
	out.append_array(_bytes_field(9, "0".to_utf8_buffer()))
	return out


## HeartBeatMessage: 1 room_id.
static func heartbeat(room_id: int) -> PackedByteArray:
	var out := _tag(1, 0)
	out.append_array(varint(room_id))
	return out


## {log_id, payload_type, payload}
static func parse_push_frame(bytes: PackedByteArray) -> Dictionary:
	var result := {}
	for field in _fields(bytes):
		match field[0]:
			2: result.log_id = field[1]
			7: result.payload_type = (field[1] as PackedByteArray).get_string_from_utf8()
			8: result.payload = field[1]
	return result


## ProtoMessageFetchResult: 1 messages (BaseProtoMessage: 1 method, 2 payload), 5 internal_ext, 9 need_ack.
## → {need_ack, internal_ext, stream_ended} (stream_ended: a WebcastControlMessage with action 3).
static func parse_fetch_result(bytes: PackedByteArray) -> Dictionary:
	var result := {"need_ack": false, "internal_ext": "", "stream_ended": false}
	for field in _fields(bytes):
		match field[0]:
			5: result.internal_ext = (field[1] as PackedByteArray).get_string_from_utf8()
			9: result.need_ack = field[1] != 0
			1:
				var method := ""
				var payload := PackedByteArray()
				for inner in _fields(field[1]):
					if inner[0] == 1:
						method = (inner[1] as PackedByteArray).get_string_from_utf8()
					elif inner[0] == 2:
						payload = inner[1]
				if method == "WebcastControlMessage":
					for control in _fields(payload):
						if control[0] == 2 and control[1] == STREAM_ENDED_ACTION:
							result.stream_ended = true
	return result


## A gzip payload is recognised by its magic bytes.
static func expand(payload: PackedByteArray) -> PackedByteArray:
	if payload.size() < 2 or payload[0] != 0x1f or payload[1] != 0x8b:
		return payload
	return payload.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)


static func varint(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	for i in 10:
		var low := value & 0x7F
		value = (value >> 7) & 0x01FFFFFFFFFFFFFF  # logical shift: negative int64 encodes as 10 bytes
		if value == 0:
			out.append(low)
			return out
		out.append(low | 0x80)
	return out


static func _tag(field: int, wire: int) -> PackedByteArray:
	return varint((field << 3) | wire)


static func _bytes_field(field: int, data: PackedByteArray) -> PackedByteArray:
	var out := _tag(field, 2)
	out.append_array(varint(data.size()))
	out.append_array(data)
	return out


## [[field, value]]: varint → int, length-delimited → PackedByteArray; fixed32/64 skipped. Stops at malformed input.
static func _fields(bytes: PackedByteArray) -> Array:
	var fields: Array = []
	var i := 0
	while i < bytes.size():
		var key := _read_varint(bytes, i)
		if key[1] < 0:
			break
		i = key[1]
		var wire: int = key[0] & 7
		var field: int = key[0] >> 3
		if wire == 0:
			var v := _read_varint(bytes, i)
			if v[1] < 0:
				break
			fields.append([field, v[0]])
			i = v[1]
		elif wire == 2:
			var n := _read_varint(bytes, i)
			if n[1] < 0 or n[1] + n[0] > bytes.size() or n[0] < 0:
				break
			fields.append([field, bytes.slice(n[1], n[1] + n[0])])
			i = n[1] + n[0]
		elif wire == 1:
			i += 8
		elif wire == 5:
			i += 4
		else:
			break
	return fields


## [value, next index] or [0, -1].
static func _read_varint(bytes: PackedByteArray, at: int) -> Array:
	var value := 0
	var shift := 0
	while at < bytes.size() and shift < 64:
		var b := bytes[at]
		at += 1
		value |= (b & 0x7F) << shift
		if b < 0x80:
			return [value, at]
		shift += 7
	return [0, -1]
