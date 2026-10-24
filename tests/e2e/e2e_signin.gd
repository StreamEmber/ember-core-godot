extends Node
## Second end-to-end scene: no launcher, the player signs in inside the game (tests/e2e/run.sh phase 2).

var _result := {"wrong": {}, "right": {}, "actions": [], "connections": [], "identity_changes": 0}


func _ready() -> void:
	StreamEmber.on("box.drop", func(_a) -> void: pass)
	StreamEmber.on("screen.message", func(action) -> void: _result.actions.append(action.id))
	StreamEmber.on("box.clear", func(_a) -> void: pass)
	StreamEmber.connection_changed.connect(func(connected: bool) -> void: _result.connections.append(connected))
	StreamEmber.identity_changed.connect(func() -> void: _result.identity_changes += 1)
	await get_tree().process_frame
	await get_tree().process_frame
	_result["before"] = StreamEmber.customer_uuid
	_result.wrong = await StreamEmber.sign_in("ali@example.com", "wrong")
	_result.right = await StreamEmber.sign_in(" Ali@Example.com ", "correct horse")
	await get_tree().create_timer(4.0).timeout
	_result["customer"] = StreamEmber.customer_uuid
	_result["source"] = StreamEmber.identity_source
	_result["email"] = StreamEmber.account_email
	_result["targets"] = StreamEmber.targets
	_result["write_scope"] = StreamEmber.write_scope
	_result["collect_mode"] = StreamEmber.collect_mode
	await StreamEmber.sign_out()
	_result["after_sign_out"] = StreamEmber.customer_uuid
	_result["stored_after"] = StreamEmber.has_stored_identity()
	var file := FileAccess.open(OS.get_environment("SE_E2E_OUT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(_result, " "))
	file.close()
	get_tree().quit()
