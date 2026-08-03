extends Node

## The smallest useful setup: one board per level, top ten, no categories.

func _ready() -> void:
	Steam.steamInit()
	SteamLeaderboard.configure({"prefix": "MyGame_"})
	SteamLeaderboard.board_ready.connect(_on_board_ready)

	start_level("level_01")


func start_level(level_name: String) -> void:
	SteamLeaderboard.set_group(level_name)


func finish_level(time_ms: int) -> void:
	SteamLeaderboard.submit(time_ms)


func _on_board_ready() -> void:
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.GLOBAL, _on_entries, 1, 10)


func _on_entries(entries: Array) -> void:
	for entry: Dictionary in entries:
		print("#%d  %s  %d" % [
			entry["global_rank"],
			Steam.getFriendPersonaName(entry["steam_id"]),
			entry["score"],
		])
