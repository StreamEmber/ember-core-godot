extends Node
## End-to-end scene for tests/e2e/run.sh: records what the core delivers, then quits.

var _result := {"actions": [], "settings": [], "connections": [], "gcore_reset": null}


func _ready() -> void:
	StreamEmber.on("box.drop", func(action) -> void:
		_result.actions.append({"id": action.id, "action": action.action, "count": action.arguments.get_int("count"), "quantity": action.quantity}))
	StreamEmber.on("screen.message", func(action) -> void:
		_result.actions.append({"id": action.id, "action": action.action, "text": action.render(action.arguments.get_string("text"))}))
	StreamEmber.on("box.clear", func(_action) -> void: pass)
	StreamEmber.settings_changed.connect(func(settings) -> void: _result.settings.append(settings.get_int("boxes.maxAlive")))
	StreamEmber.connection_changed.connect(func(connected: bool) -> void: _result.connections.append(connected))
	await get_tree().create_timer(6.0).timeout
	StreamEmber.reset_gcore(func(ok: bool) -> void: _result.gcore_reset = ok)
	await get_tree().create_timer(1.5).timeout
	_result["can_write"] = StreamEmber.can_write
	_result["customer"] = StreamEmber.customer_uuid
	_result["teams"] = StreamEmber.teams.map(func(team) -> String: return team.code)
	var file := FileAccess.open(OS.get_environment("SE_E2E_OUT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(_result, " "))
	file.close()
	get_tree().quit()
