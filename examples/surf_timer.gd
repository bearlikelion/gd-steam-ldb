extends Node

## The most involved example: a surf/movement timer, from the SurfsUp source
## code, https://store.steampowered.com/app/3454830/SurfsUp/
##
## Three axes, open-ended bonus courses, split times, ghost replays, and a
## read-only archive of a past season.
##
## Names and values here are made up. Substitute your own.
##
## Boards for map "canyon":
##   ST_canyon                 normal movement, standard style, kb+m
##   ST_LEGACY_canyon          legacy movement physics
##   ST_HSW_canyon             half-sideways style
##   ST_PAD_canyon             controller
##   ST_LEGACY_HSW_PAD_canyon  all three at once
##   ST_B1_canyon              bonus course 1
##   ST_GLOBAL                 cross-map aggregate
##
## 40 boards per map (4 modes x 5 styles x 2 inputs), created on demand.

enum Mode { NORMAL, LEGACY, EASY, FREESTYLE }
enum Style { NONE, SIDEWAYS, BACKWARDS, NO_SKIPS, FORWARD_ONLY }

const GLOBAL_BOARD: String = "GLOBAL"

## Bump for a season wipe. The previous season's boards stay untouched under
## their old prefix, browsable read-only.
const PREFIX_LIVE: String = "S2_"
const PREFIX_ARCHIVE: String = "S1_"

var _splits: PackedInt32Array = PackedInt32Array()
var _run_start_ms: int = 0


func _ready() -> void:
	# A launch flag browses last season: an older prefix, read-only so looking
	# up a board that only exists this season cannot create an empty one there.
	var archive: bool = "--archive" in OS.get_cmdline_user_args()

	# Set once. Every board on every map derives from it, so this one string is
	# what separates live scores from archived ones.
	var prefix: String = PREFIX_ARCHIVE if archive else PREFIX_LIVE

	SteamLeaderboard.configure({
		"prefix": prefix,
		"axes": [
			# NORMAL, NONE and kb+m are the defaults, so a standard run lands
			# on the bare "ST_canyon". That is what lets a fifth style be added
			# later without renaming a single existing board.
			{
				"id": "mode",
				"default": Mode.NORMAL,
				"tokens": {
					Mode.LEGACY: "LEGACY",
					Mode.EASY: "EASY",
					Mode.FREESTYLE: "FREESTYLE",
				},
			},
			{
				"id": "style",
				"default": Style.NONE,
				"tokens": {
					Style.SIDEWAYS: "HSW",
					Style.BACKWARDS: "BW",
					Style.NO_SKIPS: "NS",
					Style.FORWARD_ONLY: "WO",
				},
			},
			# Controller runs rank separately, so they are their own boards.
			{
				"id": "pad",
				"default": 0,
				"tokens": {
					1: "PAD",
				},
			},
		],
		# Fixed slots for stage splits, plus the run's checkpoint count so a
		# partial run is distinguishable from a short map.
		"extra_keys": ["stage1", "stage2", "stage3", "stage4", "stages"],
		# Playable for testing, but never ranked.
		"excluded": ["test_map", "menu_background"],
		"ranks": {
			0.01: "Legendary",
			0.10: "Grand Master",
			0.25: "Master",
			0.50: "Intermediate",
			1.00: "Novice",
		},
		"debug": OS.has_feature("debug"),
	}, Steam.getSteamID(), archive)

	SteamLeaderboard.board_ready.connect(_on_board_ready)
	SteamLeaderboard.score_submitted.connect(_on_submitted)
	SteamLeaderboard.score_dropped.connect(_on_dropped)

	print("%d boards per map" % SteamLeaderboard.boards_per_group())


# ---------------------------------------------------------------------------
# Maps and bonus courses
# ---------------------------------------------------------------------------

## Bonus courses go in the group, not an axis: B1/B2/B3 is open-ended and an
## axis needs a fixed value set. "canyon" and "B1_canyon" are simply two
## different groups, which also puts the course token first.
func map_group(map_name: String, course: int = 0) -> String:
	if course > 0:
		return "B%d_%s" % [course, map_name]
	return map_name


func load_map(map_name: String) -> void:
	SteamLeaderboard.set_group(map_group(map_name))


func switch_to_bonus(map_name: String, course: int) -> void:
	SteamLeaderboard.set_group(map_group(map_name, course))


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

# Latched at the start of the run. An input-device flag flips on any stray
# event, so reading it live would move a run onto the PAD board mid-attempt.
func start_run(mode: Mode, style: Style, using_pad: bool) -> void:
	SteamLeaderboard.set_variant("mode", mode)
	SteamLeaderboard.set_variant("style", style)
	SteamLeaderboard.set_variant("pad", 1 if using_pad else 0)
	_run_start_ms = Time.get_ticks_msec()
	_splits.clear()


func on_checkpoint() -> void:
	_splits.append(Time.get_ticks_msec() - _run_start_ms)


func finish_run(replay_bytes: PackedByteArray) -> void:
	# The global board is website-computed, so a run must never upload while it
	# is being viewed.
	if is_global_board():
		return

	var total_ms: int = Time.get_ticks_msec() - _run_start_ms
	var replay_name: String = "%s_%d.rpl" % [
		SteamLeaderboard.group, Time.get_unix_time_from_system()]

	# Splits ride along on the entry, so a stage-by-stage comparison against
	# the record needs no second request.
	SteamLeaderboard.submit(total_ms, _stage_info(), {
		"map": SteamLeaderboard.group,
		"replay": replay_name,
		"time_ms": total_ms,
	})

	if not replay_bytes.is_empty():
		SteamLeaderboard.attach_replay(replay_name, replay_bytes)


func _on_submitted(success: bool, context: Dictionary) -> void:
	if not success:
		push_warning("Score upload failed on %s" % context["map"])
		return
	_mirror_to_backend(context)


# The board never resolved, so the recorded replay would sit on disk forever.
func _on_dropped(context: Dictionary) -> void:
	DirAccess.remove_absolute("user://replays/" + str(context["replay"]))


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

func _on_board_ready() -> void:
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.GLOBAL, _on_page, 1, 25)
	SteamLeaderboard.fetch(SteamLeaderboard.RequestType.PERSONAL, _on_personal)


# Slots the recorded splits into the configured keys.
func _stage_info() -> Dictionary:
	var info: Dictionary = {"stages": _splits.size()}
	for i: int in range(mini(_splits.size(), 4)):
		info["stage%d" % (i + 1)] = _splits[i]
	return info


func _on_page(entries: Array) -> void:
	for entry: Dictionary in entries:
		var extra: Dictionary = SteamLeaderboard.decode_extra(entry["details"])
		print("#%d  %s  %s  %d stages" % [
			entry["global_rank"],
			Steam.getFriendPersonaName(entry["steam_id"]),
			format_time(entry["score"]),
			extra.get("stages", 0),
		])
		_cache_record_splits(extra)


func _on_personal(entries: Array) -> void:
	if entries.is_empty():
		return
	var mine: Dictionary = entries[0]
	print("PB %s, rank %d of %d (%s)" % [
		format_time(mine["score"]),
		mine["global_rank"],
		SteamLeaderboard.entry_count,
		SteamLeaderboard.rank_label(mine["global_rank"]),
	])

	SteamLeaderboard.download_replay(mine["ugc_handle"],
		func(data: PackedByteArray) -> void:
			if not data.is_empty():
				_load_ghost(data)
	)


# ---------------------------------------------------------------------------
# Leaderboard menu filters
# ---------------------------------------------------------------------------

# The menu browses other boards; runs keep uploading to what is being played.
# This is why set_view exists: someone comparing themselves against the
# sideways board must not have their normal run land there.
func on_filter_mode(mode: Mode) -> void:
	SteamLeaderboard.set_view("mode", mode)


func on_filter_style(style: Style) -> void:
	SteamLeaderboard.set_view("style", style)


func on_filter_pad(pad: bool) -> void:
	SteamLeaderboard.set_view("pad", 1 if pad else 0)


# The player actually switched mode, so uploads move with it.
func on_mode_selected(mode: Mode) -> void:
	SteamLeaderboard.set_variant("mode", mode)


# ---------------------------------------------------------------------------
# Cross-map aggregate
# ---------------------------------------------------------------------------

## The global board is READ ONLY here. Its ranking is computed by the website
## from every map's scores, not by any single run, so the game only ever reads
## it. Never call submit() while it is the active group: the score would land
## on a board nothing else writes to and would be overwritten by the next
## website recalculation.
##
## It takes no axis tokens, so its name is just PREFIX + GLOBAL.
func show_global_board() -> void:
	SteamLeaderboard.set_group(GLOBAL_BOARD)


func is_global_board() -> bool:
	return SteamLeaderboard.group == GLOBAL_BOARD


# ---------------------------------------------------------------------------

func format_time(ms: int) -> String:
	return "%d:%06.3f" % [ms / 60000, (ms % 60000) / 1000.0]


func _mirror_to_backend(_context: Dictionary) -> void:
	pass


func _cache_record_splits(_extra: Dictionary) -> void:
	pass


func _load_ghost(_data: PackedByteArray) -> void:
	pass
