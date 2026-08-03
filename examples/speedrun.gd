extends Node

## Speedrunning game: levels, weapons, categories, checkpoint splits, replays.
##
## Boards for level "e1m1":
##   Run_e1m1              pistol, any%
##   Run_SHOTGUN_e1m1      shotgun, any%
##   Run_100_e1m1          pistol, 100%
##   Run_SHOTGUN_100_e1m1  shotgun, 100%

enum Weapon { PISTOL, SHOTGUN, RAILGUN }
enum Category { ANY, HUNDRED }

var _start_ms: int = 0
var _splits: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	Steam.steamInit()

	SteamLeaderboard.configure({
		"prefix": "Run_",
		"axes": [
			{
				"id": "weapon",
				"default": Weapon.PISTOL,
				"tokens": {
					Weapon.SHOTGUN: "SHOTGUN",
					Weapon.RAILGUN: "RAILGUN",
				},
			},
			{
				"id": "category",
				"default": Category.ANY,
				"tokens": {
					Category.HUNDRED: "100",
				},
			},
		],
		# Fixed slots for the checkpoint splits, so a run stores up to four.
		"extra_keys": ["split1", "split2", "split3", "split4"],
		"excluded": ["tutorial", "testmap"],
		"ranks": {0.01: "World Class", 0.10: "Master", 0.50: "Runner", 1.0: "Rookie"},
		"debug": OS.has_feature("debug"),
	})

	SteamLeaderboard.board_ready.connect(_on_board_ready)
	SteamLeaderboard.score_submitted.connect(_on_submitted)
	SteamLeaderboard.score_dropped.connect(_on_dropped)

	print("%d boards per level" % SteamLeaderboard.boards_per_group())
	load_level("e1m1")


func load_level(level_name: String) -> void:
	SteamLeaderboard.set_group(level_name)


# Latched at the start: reading the equipped weapon live would let a mid-run
# swap retarget the board.
func start_run(weapon: Weapon, category: Category) -> void:
	SteamLeaderboard.set_variant("weapon", weapon)
	SteamLeaderboard.set_variant("category", category)
	_start_ms = Time.get_ticks_msec()
	_splits.clear()


func on_checkpoint() -> void:
	_splits.append(Time.get_ticks_msec() - _start_ms)


func finish_run(replay: PackedByteArray) -> void:
	var total_ms: int = Time.get_ticks_msec() - _start_ms
	var replay_name: String = "%s_%d.rpl" % [
		SteamLeaderboard.group, Time.get_unix_time_from_system()]

	SteamLeaderboard.submit(total_ms, _split_info(), {
		"level": SteamLeaderboard.group,
		"replay": replay_name,
		"time_ms": total_ms,
	})

	if not replay.is_empty():
		SteamLeaderboard.attach_replay(replay_name, replay)


func _on_submitted(success: bool, context: Dictionary) -> void:
	if success:
		print("Sent %d ms on %s" % [context["time_ms"], context["level"]])
	else:
		push_warning("Upload failed on %s" % context["level"])


# The board never resolved, so the recorded replay is orphaned.
func _on_dropped(context: Dictionary) -> void:
	DirAccess.remove_absolute("user://replays/" + str(context["replay"]))


func _on_board_ready() -> void:
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.GLOBAL, _on_entries, 1, 25)
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.PERSONAL, _on_personal)


# Slots the recorded splits into the configured keys.
func _split_info() -> Dictionary:
	var info: Dictionary = {}
	for i: int in range(mini(_splits.size(), 4)):
		info["split%d" % (i + 1)] = _splits[i]
	return info


func _on_entries(entries: Array) -> void:
	for entry: Dictionary in entries:
		var extra: Dictionary = SteamLeaderboard.decode_extra(entry["details"])
		print("#%d  %s  %s  first split %s" % [
			entry["global_rank"],
			Steam.getFriendPersonaName(entry["steam_id"]),
			format_time(entry["score"]),
			format_time(extra.get("split1", 0)),
		])


func _on_personal(entries: Array) -> void:
	if entries.is_empty():
		return
	var mine: Dictionary = entries[0]
	print("PB %s, rank %d (%s)" % [
		format_time(mine["score"]),
		mine["global_rank"],
		SteamLeaderboard.rank_label(mine["global_rank"]),
	])

	SteamLeaderboard.download_replay(mine["ugc_handle"],
		func(data: PackedByteArray) -> void:
			if not data.is_empty():
				print("Ghost: %d bytes" % data.size())
	)


# Filter buttons browse without moving where runs upload.
func on_filter_weapon(weapon: Weapon) -> void:
	SteamLeaderboard.set_view("weapon", weapon)


func on_filter_category(category: Category) -> void:
	SteamLeaderboard.set_view("category", category)


func format_time(ms: int) -> String:
	return "%d:%02d.%03d" % [ms / 60000, (ms / 1000) % 60, ms % 1000]
