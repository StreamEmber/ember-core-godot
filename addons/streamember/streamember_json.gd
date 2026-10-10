extends RefCounted
## JSON helpers shared by the StreamEmber addon (mirrors StreamEmber.Live Internal/Json.cs).
## Godot's JSON parser returns every number as float.

const UUID_PATTERN := "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"


static func obj(source, key: String):
	if source is Dictionary and source.get(key) is Dictionary:
		return source[key]
	return null


static func arr(source, key: String) -> Array:
	if source is Dictionary and source.get(key) is Array:
		return source[key]
	return []


## Scalar as text: strings as they are, numbers without a trailing ".0", bools as true/false.
static func scalar_text(value) -> String:
	if value is String:
		return value
	if value is bool:
		return "true" if value else "false"
	if value is float or value is int:
		var number := float(value)
		if is_finite(number) and number == floorf(number) and absf(number) < 1e15:
			return str(int(number))
		return str(number)
	return ""


static func text(source, key: String) -> String:
	if source is Dictionary:
		return scalar_text(source.get(key))
	return ""


static func is_number(value) -> bool:
	return (value is float or value is int) and is_finite(float(value))


## Number at key (also a numeric string); fallback otherwise.
static func number(source, key: String, fallback: float = 0.0) -> float:
	if not (source is Dictionary):
		return fallback
	var value = source.get(key)
	if is_number(value):
		return float(value)
	if value is String and value.is_valid_float():
		return value.to_float()
	return fallback


static func merge(base: Dictionary, overlay) -> Dictionary:
	var result: Dictionary = base.duplicate(true)
	if overlay is Dictionary:
		_merge_into(result, overlay)
	return result


static func _merge_into(target: Dictionary, overlay: Dictionary) -> void:
	for key in overlay:
		var value = overlay[key]
		if value == null:
			continue
		if value is Dictionary and target.get(key) is Dictionary:
			_merge_into(target[key], value)
		elif value is Dictionary or value is Array:
			target[key] = value.duplicate(true)
		else:
			target[key] = value


## Lower-case canonical UUID or "" when the text is not a UUID.
static func normalize_uuid(value) -> String:
	if not (value is String):
		return ""
	var candidate: String = value.strip_edges().to_lower()
	var regex := RegEx.create_from_string(UUID_PATTERN)
	return candidate if regex.search(candidate) != null else ""


## Parses JSON without printing an error for bad input; null when the text is not JSON.
static func parse(text: String):
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


static func stable_text(value) -> String:
	return JSON.stringify(value, "", true)
