extends Node

## Bloodthief-style naming: Prefix_WEAPON_IB/OB_Level.
##
## Both axes set always_token, because inbounds and out of bounds are equally
## real categories and neither should be the silent default:
##   BT_SWORD_IB_cathedral
##   BT_SWORD_OB_cathedral
##   BT_CROSSBOW_IB_cathedral
##   BT_CROSSBOW_OB_cathedral

enum Weapon { SWORD, CROSSBOW }
enum Bounds { IB, OB }

## Medals are NOT an axis. They are a threshold on the score, so they cost no
## boards and are worked out on the client from the time that was just set.
## Adding them as an axis would double the board count and split the
## leaderboard by medal, which is the opposite of what you want.
enum Medal { DUNG, BONE, HEX, GODKILLER }

## Per-map target times in ms, fastest first. GODKILLER is the developer's own
## time and is only listed for maps that have one.
const TARGETS: Dictionary[String, Dictionary] = {
	"cathedral": {
		Medal.GODKILLER: 41_200,
		Medal.HEX: 52_000,
		Medal.BONE: 75_000,
	},
	"crypt": {
		Medal.HEX: 38_500,
		Medal.BONE: 61_000,
	},
}

var _start_ms: int = 0


func _ready() -> void:
	Steam.steamInit()

	SteamLeaderboard.configure({
		"prefix": "BT_",
		"axes": [
			{
				"id": "weapon",
				"default": Weapon.SWORD,
				"always_token": true,
				"tokens": {
					Weapon.SWORD: "SWORD",
					Weapon.CROSSBOW: "CROSSBOW",
				},
			},
			{
				"id": "bounds",
				"default": Bounds.IB,
				"always_token": true,
				"tokens": {
					Bounds.IB: "IB",
					Bounds.OB: "OB",
				},
			},
		],
		# Stored on every entry, in this order.
		"extra_keys": ["medal"],
		"ranks": {0.01: "Bloodthief", 0.10: "Master", 0.50: "Runner", 1.0: "Rookie"},
	})

	SteamLeaderboard.board_ready.connect(_on_board_ready)
	load_level("cathedral")


func load_level(level_name: String) -> void:
	SteamLeaderboard.set_group(level_name)


func start_run(weapon: Weapon) -> void:
	SteamLeaderboard.set_variant("weapon", weapon)
	SteamLeaderboard.set_variant("bounds", Bounds.IB)
	_start_ms = Time.get_ticks_msec()


# One way: once a runner leaves the route the whole run is OB.
func on_left_bounds() -> void:
	SteamLeaderboard.set_variant("bounds", Bounds.OB)


func finish_run() -> void:
	var time_ms: int = Time.get_ticks_msec() - _start_ms
	var medal: Medal = medal_for(SteamLeaderboard.group, time_ms)

	# The medal rides along on the entry so the leaderboard can show it next to
	# every score without a second lookup, and so it stays correct even if the
	# targets are retuned later.
	SteamLeaderboard.submit(time_ms, {"medal": medal})
	_show_medal(medal)


## Slowest tier is the floor: finishing at all earns Dung.
func medal_for(map_name: String, time_ms: int) -> Medal:
	var targets: Dictionary = TARGETS.get(map_name, {})
	for medal: Medal in [Medal.GODKILLER, Medal.HEX, Medal.BONE]:
		if targets.has(medal) and time_ms <= int(targets[medal]):
			return medal
	return Medal.DUNG


## Godkiller is a secret: it is never shown as a goal, only revealed once it
## has actually been beaten.
func visible_targets(map_name: String) -> Dictionary:
	var targets: Dictionary = TARGETS.get(map_name, {}).duplicate()
	targets.erase(Medal.GODKILLER)
	return targets


func medal_name(medal: Medal) -> String:
	match medal:
		Medal.GODKILLER:
			return "Godkiller"
		Medal.HEX:
			return "Hex"
		Medal.BONE:
			return "Bone"
		_:
			return "Dung"


func _on_board_ready() -> void:
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.GLOBAL, _on_entries, 1, 25)


func _on_entries(entries: Array) -> void:
	for entry: Dictionary in entries:
		var extra: Dictionary = SteamLeaderboard.decode_extra(entry["details"])
		# Scores set before medals shipped decode to 0, so recompute from the
		# time rather than showing everyone a Dung medal.
		var medal: Medal = extra.get("medal", Medal.DUNG) as Medal
		if medal == Medal.DUNG:
			medal = medal_for(SteamLeaderboard.group, entry["score"])
		print("#%d  %s  %d ms  %s" % [
			entry["global_rank"],
			Steam.getFriendPersonaName(entry["steam_id"]),
			entry["score"],
			medal_name(medal),
		])


# Browse the OB board while still running IB.
func on_filter_bounds(bounds: Bounds) -> void:
	SteamLeaderboard.set_view("bounds", bounds)


func _show_medal(medal: Medal) -> void:
	print("Earned: %s" % medal_name(medal))
