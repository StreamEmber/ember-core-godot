extends SceneTree
## Updates res://addons/streamember of the project given with --path (run from the game's folder):
##   godot --headless --path . -s res://addons/streamember/update.gd                         latest release
##   godot --headless --path . -s res://addons/streamember/update.gd -- --version=0.2.0      that release
##   godot --headless --path . -s res://addons/streamember/update.gd -- --from=../ember-core-godot   local core (unreleased)
##   godot --headless --path . -s res://addons/streamember/update.gd -- --check              exit 2 if a newer release exists
## Then: godot --headless --path . --import

const Updater := preload("updater.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var options := {}
	for arg in OS.get_cmdline_user_args():
		var pair := arg.trim_prefix("--").split("=", true, 1)
		options[pair[0]] = pair[1] if pair.size() > 1 else "true"
	var current := Updater.installed_version()
	var files := {}
	var label := ""

	if options.has("from"):
		var project := ProjectSettings.globalize_path("res://").simplify_path()
		var source: String = options.from if options.from.is_absolute_path() else project.path_join(options.from)
		source = source.simplify_path()
		if source == project:
			_finish(1, "--from points at this project itself.")
			return
		files = Updater.files_from_dir(source)
		label = "%s from %s" % [Updater.installed_version(source.path_join("addons/streamember")), source]
	else:
		var updater := Updater.new()
		root.add_child(updater)
		updater.api_url = options.get("api", updater.api_url)  # tests / mirrors
		var release: Dictionary = await updater.fetch_release(options.get("version", ""))
		if release.error != "":
			_finish(1, "Could not read the release: " + release.error)
			return
		var newer := Updater.compare(release.version, current) > 0
		if options.has("check"):
			_finish(2 if newer else 0, "Installed %s, latest %s. %s" % [current, release.version, release.notes_url])
			return
		if not options.has("version") and not newer:
			_finish(0, "StreamEmber Live %s is up to date." % current)
			return
		var download: Dictionary = await updater.fetch(release.zip_url)
		if download.error != "":
			_finish(1, "Download failed: " + download.error)
			return
		files = Updater.files_from_zip(download.body)
		label = "%s (%s)" % [release.version, release.notes_url]

	var error := Updater.install(files)
	if error != "":
		_finish(1, "Not installed: " + error)
		return
	_finish(0, "StreamEmber Live %s installed (was %s): %s\nNow run: godot --headless --path . --import"
		% [Updater.installed_version(), current if current != "" else "none", label])


func _finish(code: int, message: String) -> void:
	if code == 1:
		printerr("[StreamEmber] " + message)
	else:
		print("[StreamEmber] " + message)
	quit(code)
