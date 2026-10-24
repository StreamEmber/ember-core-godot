extends CanvasLayer
## The core's connect panel: StreamEmber sign-in (phone), password reset and the live connection status, built from
## code above the game (layer 120). Opened by StreamEmber.open_connect_panel() or the chip (make_chip).
## Mobile app standard look: dark card, brand orange button, fields with rounded corners; texts in 14 languages.

const _Texts := preload("texts.gd")
const ORANGE := Color("ff6a1a")
const ORANGE_HOVER := Color("ff8240")
const CARD := Color("15171c")
const FIELD := Color("1f222a")
const LINE := Color(1, 1, 1, 0.10)
const TEXT := Color("f2f3f5")
const QUIET := Color("9aa0ab")
const DANGER := Color("ff6b6b")
const GOOD := Color("3ddc84")
const AMBER := Color("ffb020")
const WIDTH := 440.0
const LAUNCHER_WEB := "https://launcher.streamember.com"

var live: Node  # core/live.gd
var _dim: ColorRect
var _card: PanelContainer
var _body: VBoxContainer
var _header_row: Control
var _scroll: ScrollContainer
## Tests / screenshots: a fake virtual keyboard height in window pixels (-1 = ask the OS).
var keyboard_override := -1.0
var _keyboard_was := 0.0
## Until this time (ms) the focused field is kept in view; afterwards the player may scroll freely (to the button).
var _reveal_until := 0
var _view := ""
var _email := ""  # kept between the form and the reset views


func _init(core: Node) -> void:
	live = core
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if live.ui_theme != null:
		root.theme = live.ui_theme
	add_child(root)
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.6)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			close())
	root.add_child(_dim)
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", _box(CARD, 22, 24, LINE))
	root.add_child(_card)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 16)
	_card.add_child(outer)
	_header_row = _header()
	outer.add_child(_header_row)
	# The body scrolls: a landscape phone with the keyboard open leaves ~40 % of the height; the card never grows past
	# the visible area and the focused field is scrolled into view.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	outer.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)
	get_viewport().size_changed.connect(_place)
	get_viewport().gui_focus_changed.connect(func(_c: Control) -> void: _reveal_until = Time.get_ticks_msec() + 600)

	live.host.identity_changed.connect(_on_live_changed)
	live.host.connection_changed.connect(_on_live_changed.unbind(1))
	live.host.stream_changed.connect(_on_live_changed.unbind(1))


func open() -> void:
	if not is_node_ready():
		await ready  # opened before the game's tree is up (e.g. from an autoload's _ready)
	visible = true
	if _signed_in():
		_show_status()
	elif live.can_sign_in():
		_show_form()
	else:
		_show_launcher()


func close() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if visible:
		_place()  # follows the virtual keyboard


func _signed_in() -> bool:
	return live.customer_uuid != "" or live.has_stored_identity()


func _on_live_changed() -> void:
	if visible and _view in ["status", "launcher"]:
		open()


# ─── Views ───────────────────────────────────────────────────────────────────

func _show_form(error := "") -> void:
	_clear("form")
	_add(_spare(_label(_t("title"), 22, TEXT, true)))
	_add(_spare(_label(_t("intro"), 15, QUIET)))
	var email := _field(_t("email"), false)
	email.text = _email
	email.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_add(email)
	var password := _field(_t("password"), true)
	_add(_with_eye(password))
	var problem := _label(error, 14, DANGER)
	problem.visible = error != ""
	_add(problem)
	var go := _primary(_t("sign_in"))
	var submit := func() -> void:
		_email = email.text.strip_edges()
		go.disabled = true
		go.text = _t("signing_in")
		var result: Dictionary = await live.sign_in(_email, password.text)
		if not is_instance_valid(go):
			return
		if result.ok:
			_show_status()
		else:
			_show_form(_Texts.error(str(result.code)))
	go.pressed.connect(submit)
	email.text_submitted.connect(func(_t: String) -> void: password.grab_focus())
	password.text_submitted.connect(func(_t: String) -> void: submit.call())
	var forgot := _link(_t("forgot"), func() -> void:
		_email = email.text.strip_edges()
		_show_reset_request())
	forgot.size_flags_horizontal = Control.SIZE_SHRINK_END
	_add(forgot)
	_add(go)
	var create := _link(_t("no_account"), func() -> void: OS.shell_open(LAUNCHER_WEB))
	create.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_add(create)
	if _email == "":
		email.grab_focus.call_deferred()


func _show_reset_request(error := "") -> void:
	_clear("reset")
	_add(_spare(_label(_t("reset_title"), 22, TEXT, true)))
	var email := _field(_t("email"), false)
	email.text = _email
	email.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_add(email)
	_add_error(error)
	var go := _primary(_t("reset_send"))
	go.pressed.connect(func() -> void:
		_email = email.text.strip_edges()
		go.disabled = true
		var result: Dictionary = await live.request_password_reset(_email)
		if not is_instance_valid(go):
			return
		if result.ok:
			_show_reset_code()
		else:
			_show_reset_request(_Texts.error(str(result.code))))
	email.text_submitted.connect(func(_t: String) -> void: go.pressed.emit())
	_add(go)
	_add(_link(_t("back"), func() -> void: _show_form()))


func _show_reset_code(error := "") -> void:
	_clear("reset")
	_add(_spare(_label(_t("reset_title"), 22, TEXT, true)))
	_add(_label(_t("reset_sent") % _email, 15, QUIET))
	var code := _field(_t("code"), false)
	code.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code.max_length = 6
	_add(code)
	var password := _field(_t("new_password"), true)
	_add(_with_eye(password))
	_add_error(error)
	var go := _primary(_t("reset_confirm"))
	go.pressed.connect(func() -> void:
		go.disabled = true
		go.text = _t("signing_in")
		var result: Dictionary = await live.confirm_password_reset(_email, code.text, password.text)
		if not is_instance_valid(go):
			return
		if result.ok:
			_show_status()
		else:
			_show_reset_code(_Texts.error(str(result.code))))
	code.text_submitted.connect(func(_t: String) -> void: password.grab_focus())
	password.text_submitted.connect(func(_t: String) -> void: go.pressed.emit())
	_add(go)
	_add(_link(_t("back"), func() -> void: _show_form()))
	code.grab_focus.call_deferred()


func _show_status() -> void:
	_clear("status")
	var connected: bool = live.live_connected
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(_dot(GOOD if connected else AMBER, 12))
	head.add_child(_label(_t("connected") if connected else _t("connecting"), 22, TEXT, true))
	_add(head)
	var source: String = live.identity_source
	var email: String = live.account_email()
	if email != "":
		_add(_label(_t("signed_in_as") % email, 15, QUIET))
	elif source == "launcher":
		_add(_label(_t("via_launcher"), 15, QUIET))
	var final := false
	for status in live.streams.values():
		var state := str(status.get("status", ""))
		final = final or state in ["ended", "not_live", "not_found", "denied"]
		_add(_label("@%s · %s" % [status.get("target", ""), _stream_text(state)], 15, TEXT))
	if live.streams.is_empty():
		for t in live.targets:
			_add(_label("@" + str(t.target), 15, TEXT))
	if source == "device" and live.targets.is_empty():
		_add(_label(_t("no_target"), 14, AMBER))
	if final:
		var again := _primary(_t("reconnect"))
		again.pressed.connect(func() -> void: live.restart_collection())
		_add(again)
	if source == "device" and live.account_shared():
		_add(_label(_t("shared_hint"), 13, QUIET))
	if source == "device":
		var out := _secondary(_t("sign_out"))
		out.pressed.connect(func() -> void:
			await live.sign_out()
			if visible:
				open())
		_add(out)


func _show_launcher() -> void:
	_clear("launcher")
	_add(_label(_t("title"), 22, TEXT, true))
	_add(_label(_t("intro"), 15, QUIET))
	_add(_label(_t("use_launcher"), 15, TEXT))


func _stream_text(state: String) -> String:
	match state:
		"collecting", "grace":
			return _t("st_collecting")
		"not_live":
			return _t("st_not_live")
		"ended":
			return _t("st_ended")
		"not_found":
			return _t("st_not_found")
		"denied":
			return _t("st_denied")
	return _t("connecting")


# ─── Building blocks ─────────────────────────────────────────────────────────

func _t(key: String) -> String:
	return _Texts.get_text(key)


func _clear(view: String) -> void:
	_view = view
	if _scroll != null:
		_scroll.scroll_vertical = 0
	for c in _body.get_children():
		c.queue_free()


func _add(c: Control) -> void:
	_body.add_child(c)


func _add_error(error: String) -> void:
	if error != "":
		_add(_label(error, 14, DANGER))


## Text that may go while the keyboard is open (title, intro): the fields and the button keep the room.
func _spare(c: Control) -> Control:
	c.set_meta("spare", true)
	return c


## Visible height of the game above the virtual keyboard, in viewport units.
func _keyboard_height(view: Vector2) -> float:
	var px := keyboard_override
	if px < 0.0:
		px = float(DisplayServer.virtual_keyboard_get_height()) if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD) else 0.0
	var window := float(DisplayServer.window_get_size().y)
	if px <= 0.0:
		return 0.0
	return px * view.y / window if window > 0.0 else px  # headless (tests): no window, px are viewport units


func _place() -> void:
	if _card == null or not visible:
		return
	var view := get_viewport().get_visible_rect().size
	var keyboard := _keyboard_height(view)
	var typing := keyboard > 0.0
	var free_h := view.y - keyboard
	var margin := 8.0 if typing else 16.0
	var w := minf(WIDTH if not typing else maxf(WIDTH, minf(view.x * 0.6, 640.0)), view.x - 2.0 * margin)
	for c in _body.get_children():
		if c.has_meta("spare"):
			c.visible = not typing
	_header_row.visible = not typing or free_h > 260.0
	if typing != _card.has_meta("typing"):
		_card.add_theme_stylebox_override("panel", _box(CARD, 22, 12 if typing else 24, LINE))
		if typing:
			_card.set_meta("typing", true)
		else:
			_card.remove_meta("typing")
	var pad := 24.0 if typing else 48.0
	_scroll.custom_minimum_size.x = w - pad
	var header_h := (_header_row.get_combined_minimum_size().y + 16.0) if _header_row.visible else 0.0
	var body_h := _body.get_combined_minimum_size().y
	var room := maxf(free_h - 2.0 * margin - pad - header_h, 60.0)
	_scroll.custom_minimum_size.y = minf(body_h, room)
	_card.size = Vector2(w, 0)
	_card.size = Vector2(w, _card.get_combined_minimum_size().y)
	var top := margin if typing else maxf(margin, (free_h - _card.size.y) * 0.5)
	_card.position = Vector2((view.x - w) * 0.5, top).floor()
	if keyboard != _keyboard_was:
		_keyboard_was = keyboard
		_reveal_until = Time.get_ticks_msec() + 600
	if Time.get_ticks_msec() < _reveal_until:
		_reveal_focus()


## Keeps the focused field inside the visible part of the card (above the keyboard). Runs for a moment after a focus
## or keyboard change, so it settles after late layout changes (wrapped text, keyboard animation).
func _reveal_focus() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	if focused == null or _scroll == null or not _body.is_ancestor_of(focused):
		return
	var top := focused.get_global_rect().position.y - _scroll.get_global_rect().position.y
	var bottom := top + focused.size.y
	if top < 0.0:
		_scroll.scroll_vertical += floori(top) - 4
	elif bottom > _scroll.size.y:
		_scroll.scroll_vertical += ceili(bottom - _scroll.size.y) + 4


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_dot(ORANGE, 14))
	row.add_child(_label("StreamEmber", 16, TEXT, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var x := Button.new()
	x.text = "✕"
	x.flat = true
	x.focus_mode = Control.FOCUS_NONE
	x.tooltip_text = _t("close")
	x.add_theme_color_override("font_color", QUIET)
	x.add_theme_font_size_override("font_size", 18)
	x.pressed.connect(close)
	row.add_child(x)
	return row


func _label(text: String, size: int, color: Color, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 120
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_constant_override("outline_size", 1)
		l.add_theme_color_override("font_outline_color", color)
	return l


func _field(placeholder: String, secret: bool) -> LineEdit:
	var f := LineEdit.new()
	f.placeholder_text = placeholder
	f.secret = secret
	f.custom_minimum_size.y = 52
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.add_theme_font_size_override("font_size", 17)
	f.add_theme_color_override("font_color", TEXT)
	f.add_theme_color_override("font_placeholder_color", QUIET)
	f.add_theme_stylebox_override("normal", _box(FIELD, 14, 14, LINE))
	f.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), 14, 14, ORANGE))
	if secret:
		f.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	return f


func _with_eye(field: LineEdit) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(field)
	var eye := _link(_t("show"), Callable())
	eye.pressed.connect(func() -> void:
		field.secret = not field.secret
		eye.text = _t("show") if field.secret else _t("hide"))
	row.add_child(eye)
	return row


func _primary(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 54
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 18)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(state, Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.7))
	b.add_theme_stylebox_override("normal", _box(ORANGE, 16, 12))
	b.add_theme_stylebox_override("hover", _box(ORANGE_HOVER, 16, 12))
	b.add_theme_stylebox_override("pressed", _box(ORANGE.darkened(0.15), 16, 12))
	b.add_theme_stylebox_override("disabled", _box(ORANGE.darkened(0.3), 16, 12))
	return b


func _secondary(text: String) -> Button:
	var b := _primary(text)
	for s in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(s, _box(FIELD if s != "hover" else FIELD.lightened(0.08), 16, 12, LINE))
	return b


func _link(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", ORANGE)
	b.add_theme_color_override("font_hover_color", ORANGE_HOVER)
	b.add_theme_color_override("font_pressed_color", ORANGE_HOVER)
	if action.is_valid():
		b.pressed.connect(action)
	return b


static func _dot(color: Color, size: float) -> Control:
	var d := Panel.new()
	d.custom_minimum_size = Vector2(size, size)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_theme_stylebox_override("panel", _box(color, int(size), 0))
	return d


static func _box(color: Color, radius: int, pad: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1 if border != ORANGE else 2)
	s.anti_aliasing = true
	return s


# ─── Chip ────────────────────────────────────────────────────────────────────

## The small "● Live" pill the game puts in a corner of its lobby (or a settings row).
static func make_chip(core: Node) -> Button:
	return _Chip.new(core)


class _Chip extends Button:
	var live: Node
	var _dot_box: Panel
	var _text: Label

	func _init(core: Node) -> void:
		live = core
		focus_mode = Control.FOCUS_NONE
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0, 0, 0, 0.45)
		s.border_color = Color(1, 1, 1, 0.16)
		s.set_border_width_all(1)
		s.set_corner_radius_all(999)
		s.content_margin_left = 14
		s.content_margin_right = 16
		s.content_margin_top = 8
		s.content_margin_bottom = 8
		var hover: StyleBoxFlat = s.duplicate()
		hover.bg_color = Color(0, 0, 0, 0.6)
		add_theme_stylebox_override("normal", s)
		add_theme_stylebox_override("hover", hover)
		add_theme_stylebox_override("pressed", hover)
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 8)
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 14
		row.offset_right = -16
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		add_child(row)
		_dot_box = Panel.new()
		_dot_box.custom_minimum_size = Vector2(10, 10)
		_dot_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_dot_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_dot_box)
		_text = Label.new()
		_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text.add_theme_font_size_override("font_size", 16)
		_text.add_theme_color_override("font_color", Color.WHITE)
		row.add_child(_text)
		pressed.connect(func() -> void: live.open_panel())
		live.host.identity_changed.connect(_refresh)
		live.host.connection_changed.connect(_refresh.unbind(1))
		live.host.stream_changed.connect(_refresh.unbind(1))
		_refresh()

	func _refresh() -> void:
		var connected: bool = live.live_connected
		var known: bool = live.customer_uuid != ""
		var name := ""
		if known and not live.targets.is_empty():
			name = "@" + str(live.targets[0].target)
		_text.text = name if name != "" else _Texts.get_text("chip")
		var color := Color(1, 1, 1, 0.35)
		if known:
			color = Color("ff3b5c") if connected else Color("ffb020")
		var s := StyleBoxFlat.new()
		s.bg_color = color
		s.set_corner_radius_all(5)
		_dot_box.add_theme_stylebox_override("panel", s)
		custom_minimum_size = Vector2(_text.get_minimum_size().x + 10 + 8 + 30, 40)
