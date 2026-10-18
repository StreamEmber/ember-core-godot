class_name StreamEmberAction
extends RefCounted
## One GameAction v2 packet (StreamEmber.Live LiveAction). Handlers receive it on the main thread.

const _J := preload("streamember_json.gd")
const _Values := preload("streamember_values.gd")

## Packet id (used for duplicate removal).
var id: String
## Action id from game-schema.json, e.g. "enemy.spawn".
var action: String
var rule_id: String
var customer_uuid: String
var application_uuid: String
var created_at: String
## Arguments with the schema defaults filled in.
var arguments: _Values
## How many times the rule fired (>= 1). Multiply, then cap: mini(cap, arg * quantity).
var quantity: int
var trigger: Trigger
var viewer: Viewer
## null when the action was not triggered by a gift.
var gift: Gift
var subscription: Subscription
var reward: Reward
var aggregation: Aggregation
## Comment text ("" when none).
var comment: String
var like_count: int
## True for test packets (Ctrl+Shift+F1–F9).
var is_test: bool
## Set by the core: true when at least one on(...) handler or action_received listener got it.
var handled := false

var _json: Dictionary


func _init(json = null, test: bool = false) -> void:
	_json = json if json is Dictionary else {}
	is_test = test
	id = _J.text(_json, "id")
	action = _J.text(_json, "action")
	rule_id = _J.text(_json, "ruleId")
	customer_uuid = _J.text(_json, "customerUuid")
	application_uuid = _J.text(_json, "applicationUuid")
	created_at = _J.text(_json, "createdAt")
	arguments = _Values.new(_J.obj(_json, "arguments"))
	var count := _J.number(_json, "quantity", 1.0)
	quantity = 1 if count < 1.0 else int(minf(count, 2147483647.0))
	trigger = Trigger.new(_J.obj(_json, "trigger"))
	viewer = Viewer.new(_J.obj(_json, "viewer"))
	var part = _J.obj(_json, "gift")
	gift = Gift.new(part) if part != null else null
	part = _J.obj(_json, "subscription")
	subscription = Subscription.new(part) if part != null else null
	part = _J.obj(_json, "reward")
	reward = Reward.new(part) if part != null else null
	part = _J.obj(_json, "aggregation")
	aggregation = Aggregation.new(part) if part != null else null
	comment = _J.text(_J.obj(_json, "comment"), "text")
	like_count = maxi(0, int(_J.number(_J.obj(_json, "like"), "count")))


## Streamer template: {user} {username} {nickname} {team} {quantity} {gift} {comment} {streamer} {platform}.
func render(template: String) -> String:
	return template \
		.replace("{user}", viewer.display_name) \
		.replace("{team}", viewer.team.name if viewer.team != null else "") \
		.replace("{username}", viewer.username) \
		.replace("{nickname}", viewer.nickname) \
		.replace("{quantity}", str(quantity)) \
		.replace("{gift}", gift.name if gift != null else "") \
		.replace("{comment}", comment) \
		.replace("{streamer}", trigger.target) \
		.replace("{platform}", trigger.platform)


## Short "who · gift ×n" text.
func describe() -> String:
	var who := viewer.display_name if viewer.display_name != "" else "StreamEmber"
	if gift != null and gift.name != "":
		return who + " · " + gift.name + (" ×%d" % quantity if quantity > 1 else "")
	return who


func to_json() -> String:
	return JSON.stringify(_json)


func raw() -> Dictionary:
	return _json


func _to_string() -> String:
	return "StreamEmberAction[%s id=%s x%d%s]" % [action, id, quantity, " test" if is_test else ""]


## Core only: Falcon/EventFabric carry just the saved arguments; the schema fills the rest.
func _apply_argument_defaults(defaults: Dictionary) -> void:
	if defaults.is_empty():
		return
	var merged := _J.merge(defaults, _J.obj(_json, "arguments"))
	_json["arguments"] = merged
	arguments = _Values.new(merged)


class Trigger:
	var platform: String
	## Streamer's user name on the platform.
	var target: String
	var room_id: String
	var kind: String
	var category: String
	var event: String
	var event_id: String

	func _init(json) -> void:
		platform = _J.text(json, "platform")
		target = _J.text(json, "target")
		room_id = _J.text(json, "roomId")
		kind = _J.text(json, "kind")
		category = _J.text(json, "category")
		event = _J.text(json, "event")
		event_id = _J.text(json, "eventId")


class Viewer:
	var id: String
	var username: String
	var nickname: String
	var avatar_url: String
	var display_name: String
	## The viewer's team when the game has teams (chat keyword or auto-assigned by GCore); otherwise null.
	var team: Team

	func _init(json) -> void:
		id = _J.text(json, "id")
		username = _J.text(json, "username")
		nickname = _J.text(json, "nickname")
		avatar_url = _J.text(json, "avatarUrl")
		display_name = nickname if nickname != "" else username
		var part = _J.obj(json, "team")
		team = Team.new(part) if part != null else null


## A team of the game config (StreamEmber.teams) or a viewer's team (viewer.team).
class Team:
	var id: String
	## Lowercase code set by the streamer, e.g. "gs".
	var code: String
	var name: String
	var short_name: String
	## "#RRGGBB" ("" when not set).
	var primary_color: String
	var secondary_color: String
	## Team logo uploaded to Falcon (public image URL); "" when none. Load it with HTTPRequest.
	var logo_url: String

	func _init(json) -> void:
		id = _J.text(json, "id")
		code = _J.text(json, "code")
		name = _J.text(json, "name")
		short_name = _J.text(json, "shortName")
		primary_color = _J.text(json, "primaryColor")
		secondary_color = _J.text(json, "secondaryColor")
		logo_url = _J.text(json, "logoUrl")


class Gift:
	var id: String
	var name: String
	var image_url: String
	var coins: int
	var count: int
	var total_coins: int

	func _init(json) -> void:
		id = _J.text(json, "id")
		name = _J.text(json, "name")
		image_url = _J.text(json, "imageUrl")
		coins = maxi(0, int(_J.number(json, "coins")))
		count = maxi(0, int(_J.number(json, "count")))
		total_coins = maxi(0, int(_J.number(json, "totalCoins")))


class Subscription:
	var tier: String
	var months: int
	var gifter: Viewer

	func _init(json) -> void:
		tier = _J.text(json, "tier")
		months = maxi(0, int(_J.number(json, "months")))
		var part = _J.obj(json, "gifter")
		gifter = Viewer.new(part) if part != null else null


class Reward:
	var id: String
	var text: String
	var coins: int

	func _init(json) -> void:
		id = _J.text(json, "id")
		text = _J.text(json, "text")
		coins = maxi(0, int(_J.number(json, "coins")))


class Aggregation:
	var unit: String
	var scope: String
	var threshold: int
	var fire_index: int
	var fire_count: int
	var remainder: int

	func _init(json) -> void:
		unit = _J.text(json, "unit")
		scope = _J.text(json, "scope")
		threshold = maxi(0, int(_J.number(json, "threshold")))
		fire_index = maxi(0, int(_J.number(json, "fireIndex")))
		fire_count = maxi(0, int(_J.number(json, "fireCount")))
		remainder = maxi(0, int(_J.number(json, "remainder")))
