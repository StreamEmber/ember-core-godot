extends Node2D
## Demo: viewers drop boxes and write on the screen. Shows the StreamEmber patterns:
## handlers in _ready, settings from settings_changed, bounded work per frame, cleanup in live_stopped.

const BOX_CAP := 50          # hard cap per packet: units = mini(BOX_CAP, count * quantity)
const SPAWNS_PER_FRAME := 2  # spread big gifts over frames

var _max_alive := 50
var _show_names := true
var _queue: Array[String] = []   # viewer name per pending box
var _boxes: Array[Node2D] = []

@onready var _status: Label = $UI/Status
@onready var _message: Label = $UI/Message


func _ready() -> void:
	StreamEmber.on("box.drop", _drop_boxes)
	StreamEmber.on("screen.message", _show_message)
	StreamEmber.on("box.clear", func(_action) -> void: _clear())
	StreamEmber.settings_changed.connect(_apply_settings)
	StreamEmber.connection_changed.connect(func(connected: bool) -> void: _update_status())
	StreamEmber.live_stopped.connect(_clear)
	_update_status()
	# the core's "● Live" chip in the bottom-right corner: opens the connect panel (sign-in on a phone)
	var layer := CanvasLayer.new()
	add_child(layer)
	var chip := StreamEmber.make_connect_button()
	chip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	chip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	chip.offset_right = -16
	chip.offset_bottom = -16
	layer.add_child(chip)


func _process(_delta: float) -> void:
	for i in SPAWNS_PER_FRAME:
		if _queue.is_empty() or _boxes.size() >= _max_alive:
			break
		_spawn_box(_queue.pop_front())
	for box in _boxes.duplicate():
		box.position.y += 240.0 * _delta
		if box.position.y > get_viewport_rect().size.y + 40.0:
			_boxes.erase(box)
			box.queue_free()


func _apply_settings(settings) -> void:
	_max_alive = settings.get_int("boxes.maxAlive", 50, 1, 200)
	_show_names = settings.get_bool("boxes.showNames", true)
	_update_status()


func _drop_boxes(action) -> void:
	var count: int = action.arguments.get_int("count", 3, 1, 20)
	var units := mini(BOX_CAP, count * action.quantity)
	for i in units:
		if _queue.size() >= 500:
			break
		_queue.append(action.viewer.display_name.left(24))


func _show_message(action) -> void:
	_message.text = action.render(action.arguments.get_string("text", "{user}")).left(120)


func _spawn_box(viewer: String) -> void:
	var box := Node2D.new()
	var rect := ColorRect.new()
	rect.size = Vector2(36, 36)
	rect.position = Vector2(-18, -18)
	rect.color = Color.from_hsv(randf(), 0.7, 1.0)
	box.add_child(rect)
	if _show_names and viewer != "":
		var name_label := Label.new()
		name_label.text = viewer
		name_label.position = Vector2(-18, -44)
		box.add_child(name_label)
	box.position = Vector2(randf_range(40.0, get_viewport_rect().size.x - 40.0), -40.0)
	add_child(box)
	_boxes.append(box)


func _clear() -> void:
	_queue.clear()
	for box in _boxes:
		box.queue_free()
	_boxes.clear()


func _update_status() -> void:
	_status.text = "StreamEmber: %s | en fazla %d kutu | Ctrl+Shift+F1–F3 test, F10 durum" % [
		"bağlı" if StreamEmber.live_connected else "bağlı değil", _max_alive]
