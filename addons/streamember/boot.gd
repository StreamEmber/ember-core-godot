extends RefCounted
## Chooses which core runs and keeps the downloaded cores up to date. Part of the stable addon (never downloaded).
##
## The core (core/*.gd: connection, sign-in, panel) ships embedded in every game and newer versions are published on
## the CDN (components/ember-core-godot, see ../../docs in StreamEmber/docs/cdn). At start the newest valid core is
## loaded: a downloaded one in user://streamember/core/<version>/ if it is newer than the embedded one, has the same
## API and did not fail twice to start, else the embedded one. A newer core is downloaded in the background and runs
## from the next start: the game never waits. Downloads are verified: core.json is signed (RSA-2048, SHA-256) with the
## key in secrets/ember-core-signing.pem and every file must match its SHA-256 in core.json.

const _Updater := preload("updater.gd")
const ROOT := "user://streamember/core"
const STATE := ROOT + "/state.cfg"
const EMBEDDED := "res://addons/streamember/core/live.gd"
const CDN_FOLDER := "components/ember-core-godot"
## A core that started this many times without reaching confirm() is marked bad and never loaded again.
const MAX_ATTEMPTS := 2
const PUBLIC_KEY := """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvijU4VqNcAOk5S9mbAqx
PpSQKbWFetAxU/AiXz4Hs/pyVUm5VJnes1SOhgs8tDEaQa219oalUjPUnjLaHIYG
Q6iytdflEhJ7hKbgO20OvXHmuJMn74dUvLBrNfol49q5BBq22fy/B6bRzyBxHSN6
B1ygOkRXCi9wQY+g0WlkmKpvEkeuPW4+YT2noe+vFrEUkhcjuXNCCKvrA3PwkB+t
eo+6iQbhMl9H4FVcceTANs23NpOfS48X8ZKDTU/fVpW5ugtI5IrGnCheHSZ65F9R
y0zWTWUryrYO094PHRLLdZRBVV8Ddl1UrsvQpQC/szxBDcAJUNBlyFhefoR2AOtH
dQIDAQAB
-----END PUBLIC KEY-----"""


## Downloaded cores are used only in exported games (the editor always runs the embedded core, so a developer tests
## what he ships) and while streamember/runtime_updates is on.
static func enabled() -> bool:
	return not OS.has_feature("editor") and bool(ProjectSettings.get_setting("streamember/runtime_updates", true))


## {script: GDScript, version, source: "embedded" | "cdn"}.
static func pick(embedded_version: String, host_api: int, root := ROOT) -> Dictionary:
	var state := ConfigFile.new()
	state.load(root + "/state.cfg")
	var trying := str(state.get_value("boot", "trying", ""))
	var attempts := int(state.get_value("boot", "attempts", 0))
	if trying != "" and attempts >= MAX_ATTEMPTS:
		state.set_value("bad", trying, true)
		trying = ""
		attempts = 0
		state.set_value("boot", "trying", "")
		state.set_value("boot", "attempts", 0)
	for version in installed(state):
		if _Updater.compare(version, embedded_version) <= 0:
			break
		var script = load(root + "/" + version + "/live.gd") if FileAccess.file_exists(root + "/" + version + "/live.gd") else null
		if script is GDScript and script.can_instantiate() and int(script.get_script_constant_map().get("API", -1)) == host_api:
			state.set_value("boot", "trying", version)
			state.set_value("boot", "attempts", attempts + 1 if trying == version else 1)
			state.save(root + "/state.cfg")
			return {"script": script, "version": version, "source": "cdn"}
		state.set_value("bad", version, true)
	state.save(root + "/state.cfg")
	return {"script": load(EMBEDDED), "version": embedded_version, "source": "embedded"}


## The running downloaded core started fine: it is no longer on trial.
static func confirm(root := ROOT) -> void:
	var state := ConfigFile.new()
	if state.load(root + "/state.cfg") != OK or str(state.get_value("boot", "trying", "")) == "":
		return
	state.set_value("boot", "trying", "")
	state.set_value("boot", "attempts", 0)
	state.save(root + "/state.cfg")


## Installed, not bad versions, newest first.
static func installed(state: ConfigFile) -> Array:
	var list: Array = []
	if state.has_section("installed"):
		for version in state.get_section_keys("installed"):
			if not bool(state.get_value("bad", version, false)):
				list.append(version)
	list.sort_custom(func(a, b) -> bool: return _Updater.compare(a, b) > 0)
	return list


## RSA PKCS#1 v1.5 / SHA-256 signature (base64) of data, by the StreamEmber core key.
static func verify(data: PackedByteArray, signature_base64: String, public_pem := PUBLIC_KEY) -> bool:
	var key := CryptoKey.new()
	if key.load_from_string(public_pem, true) != OK:
		return false
	var signature := Marshalls.base64_to_raw(signature_base64.strip_edges())
	if signature.is_empty():
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, sha256(data), signature, key)


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(data)
	return hash.finish()


## Checks a downloaded core.json + its files and installs them as root/<version>/. files: {path: bytes}.
## Returns "" or the reason it was refused (nothing is installed then).
static func install(core_json: PackedByteArray, signature_base64: String, files: Dictionary, host_api: int,
		root := ROOT, public_pem := PUBLIC_KEY) -> String:
	if not verify(core_json, signature_base64, public_pem):
		return "bad signature"
	var info = JSON.parse_string(core_json.get_string_from_utf8())
	if not info is Dictionary:
		return "core.json is not an object"
	var version := str(info.get("version", ""))
	if not version.is_valid_filename() or _Updater.compare(version, "0.0.1") < 0:
		return "bad version " + version
	if int(info.get("api", -1)) != host_api:
		return "API %s, this game needs %d" % [str(info.get("api")), host_api]
	if _Updater.compare(Engine.get_version_info().string, str(info.get("minGodot", "4.3"))) < 0:
		return "needs Godot " + str(info.get("minGodot"))
	var listed: Array = info.get("files", []) if info.get("files") is Array else []
	if not listed.any(func(f) -> bool: return f is Dictionary and str(f.get("path", "")) == "live.gd"):
		return "live.gd missing"
	var part := root + "/" + version + ".part"
	_remove_tree(part)
	for f in listed:
		var path := str(f.get("path", "")) if f is Dictionary else ""
		if path == "" or path.begins_with("/") or ".." in path or ":" in path or not files.has(path):
			_remove_tree(part)
			return "bad or missing file " + path
		var bytes: PackedByteArray = files[path]
		if sha256(bytes).hex_encode() != str(f.get("sha256", "")).to_lower():
			_remove_tree(part)
			return "checksum mismatch: " + path
		DirAccess.make_dir_recursive_absolute((part + "/" + path).get_base_dir())
		var out := FileAccess.open(part + "/" + path, FileAccess.WRITE)
		if out == null:
			_remove_tree(part)
			return "cannot write " + path
		out.store_buffer(bytes)
		out.close()
	_remove_tree(root + "/" + version)
	if DirAccess.rename_absolute(part, root + "/" + version) != OK:
		_remove_tree(part)
		return "cannot move into place"
	var state := ConfigFile.new()
	state.load(root + "/state.cfg")
	state.set_value("installed", version, host_api)
	if state.has_section_key("bad", version):
		state.erase_section_key("bad", version)
	state.save(root + "/state.cfg")
	return ""


## Keeps the versions in keep, deletes the other downloaded cores.
static func prune(keep: Array, root := ROOT) -> void:
	var state := ConfigFile.new()
	state.load(root + "/state.cfg")
	if not state.has_section("installed"):
		return
	for version in state.get_section_keys("installed"):
		if not version in keep:
			_remove_tree(root + "/" + version)
			state.erase_section_key("installed", version)
	state.save(root + "/state.cfg")


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_files():
		dir.remove(name)
	for name in dir.get_directories():
		_remove_tree(path + "/" + name)
	DirAccess.remove_absolute(path)


## Background download of a newer core (runs once per start, a few seconds after it). log: func(level, text).
class Downloader extends Node:
	var cdn := ""
	var running := ""
	var host_api := 1
	var log_func: Callable
	var root := ROOT
	var public_pem := PUBLIC_KEY
	var delay := 5.0
	## This script (boot.gd): an inner class cannot call the outer static functions directly.
	var boot: Script
	## Emitted with the installed version ("" when nothing new / it failed). For tests.
	signal finished(version: String)

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		get_tree().create_timer(delay, true, false, true).timeout.connect(check)

	func check() -> void:
		var base := cdn.trim_suffix("/") + "/" + CDN_FOLDER
		var latest := await _fetch(base + "/latest.json")
		var info = JSON.parse_string(latest.body.get_string_from_utf8()) if latest.ok else null
		var version := str(info.get("version", "")) if info is Dictionary else ""
		var state := ConfigFile.new()
		state.load(root + "/state.cfg")
		if version == "" or _Updater.compare(version, running) <= 0 or state.has_section_key("installed", version) \
				or bool(state.get_value("bad", version, false)):
			if not latest.ok:
				_log("debug", "Core update check failed: " + latest.error)
			finished.emit("")
			return
		var core_json := await _fetch(base + "/" + version + "/core.json")
		var signature := await _fetch(base + "/" + version + "/core.json.sig")
		var parsed = JSON.parse_string(core_json.body.get_string_from_utf8()) if core_json.ok else null
		if not core_json.ok or not signature.ok or not parsed is Dictionary:
			_log("warn", "Core %s could not be downloaded." % version)
			finished.emit("")
			return
		var files := {}
		for f in parsed.get("files", []):
			var path := str(f.get("path", "")) if f is Dictionary else ""
			if path == "" or ".." in path:
				continue
			var got := await _fetch(base + "/" + version + "/" + path)
			if not got.ok:
				_log("warn", "Core %s: %s could not be downloaded (%s)." % [version, path, got.error])
				finished.emit("")
				return
			files[path] = got.body
		var problem: String = boot.install(core_json.body, signature.body.get_string_from_utf8(), files, host_api, root, public_pem)
		if problem != "":
			_log("warn", "Core %s refused: %s." % [version, problem])
			finished.emit("")
			return
		boot.prune([version, running], root)
		_log("info", "StreamEmber core %s downloaded; it runs from the next start." % version)
		finished.emit(version)

	func _fetch(url: String) -> Dictionary:
		var request := HTTPRequest.new()
		request.timeout = 30.0
		request.body_size_limit = 4 * 1024 * 1024
		add_child(request)
		var error := request.request(url, PackedStringArray(["User-Agent: StreamEmber-Godot-Boot"]))
		if error != OK:
			request.queue_free()
			return {"ok": false, "body": PackedByteArray(), "error": error_string(error)}
		var answer: Array = await request.request_completed
		request.queue_free()
		var ok: bool = answer[0] == HTTPRequest.RESULT_SUCCESS and answer[1] == 200
		return {"ok": ok, "body": answer[3], "error": "" if ok else "result %d, HTTP %d" % [answer[0], answer[1]]}

	func _log(level: String, text: String) -> void:
		if log_func.is_valid():
			log_func.call(level, text)
