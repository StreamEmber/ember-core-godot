class_name StreamEmberValues
extends RefCounted
## Settings / arguments reader (StreamEmber.Live LiveValues): dotted paths, bounded numbers.
## Example: settings.get_int("battle.maxEnemies", 40, 1, 100)

const _J := preload("streamember_json.gd")
const INT_MIN := -2147483648
const INT_MAX := 2147483647

var _root: Dictionary


func _init(root = null) -> void:
	_root = root if root is Dictionary else {}


## The underlying dictionary (do not change it).
func raw() -> Dictionary:
	return _root


func keys() -> Array:
	return _root.keys()


func has(path: String) -> bool:
	return _find(path) != null


func get_string(path: String, fallback: String = "") -> String:
	var value = _find(path)
	if value is String or value is bool or _J.is_number(value):
		return _J.scalar_text(value)
	return fallback


func get_bool(path: String, fallback: bool = false) -> bool:
	var value = _find(path)
	if value is bool:
		return value
	if value is String:
		var lowered: String = value.strip_edges().to_lower()
		if lowered == "true":
			return true
		if lowered == "false":
			return false
	return fallback


func get_float(path: String, fallback: float = 0.0, min_value: float = -INF, max_value: float = INF) -> float:
	var value = _find(path)
	var result := float(value) if _J.is_number(value) else fallback
	return clampf(result, min_value, max_value)


func get_int(path: String, fallback: int = 0, min_value: int = INT_MIN, max_value: int = INT_MAX) -> int:
	var value = _find(path)
	var result := fallback
	if _J.is_number(value):
		result = int(clampf(roundf(float(value)), float(INT_MIN), float(INT_MAX)))
	return clampi(result, min_value, max_value)


## A JSON array of scalars, or a comma separated string; empty entries dropped.
func get_string_list(path: String) -> PackedStringArray:
	var result := PackedStringArray()
	var value = _find(path)
	if value is Array:
		for item in value:
			var entry := _J.scalar_text(item).strip_edges()
			if entry != "":
				result.append(entry)
	elif value is String:
		for part in value.split(","):
			if part.strip_edges() != "":
				result.append(part.strip_edges())
	return result


func get_object(path: String):
	var value = _find(path)
	return get_script().new(value.duplicate(true) if value is Dictionary else {})


func get_object_list(path: String) -> Array:
	var result: Array = []
	var value = _find(path)
	if value is Array:
		for item in value:
			if item is Dictionary:
				result.append(get_script().new(item.duplicate(true)))
	return result


func to_json() -> String:
	return JSON.stringify(_root)


func _to_string() -> String:
	return to_json()


func _find(path: String):
	if path == "":
		return null
	if _root.get(path) != null:
		return _root[path]
	var current = _root
	for part in path.split("."):
		if not (current is Dictionary) or current.get(part) == null:
			return null
		current = current[part]
	return current
