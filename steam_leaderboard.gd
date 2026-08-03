extends Node

## Steam leaderboards for Godot 4 + GodotSteam.
##
## Boards are created on demand from a naming rule, so a new level or category
## needs no Steamworks dashboard work. See README.md.
##
## Add as an autoload named "SteamLeaderboard", then call [method configure].
##
## gd-steam-ldb, MIT licensed. Extracted from SurfsUp:
## https://store.steampowered.com/app/3454830/SurfsUp/

enum RequestType { PERSONAL, FRIENDS, GLOBAL, AROUND, GROUP }

## Steam stores at most this many ints alongside an entry.
const EXTRA_MAX: int = 64

## The viewed board resolved and is safe to read.
signal board_ready

signal score_submitted(success: bool, context: Dictionary)

## The board never resolved, so the score was thrown away.
signal score_dropped(context: Dictionary)

signal replay_attached(success: bool)

## Handle of the viewed board, 0 until [signal board_ready].
var handle: int = 0
var entry_count: int = 1

## What the player is PLAYING. Uploads go here.
var variant: Dictionary[String, int] = {}
## What the UI is SHOWING. Browsing never moves uploads.
var view: Dictionary[String, int] = {}
## The level, track or course being played.
var group: String = ""

var _config: Dictionary = {}
var _axes: Array[Dictionary] = []
var _steam_id: int = 0
var _read_only: bool = false

var _handles: Dictionary[String, int] = {}
var _finds: Array[Dictionary] = []
var _finding: bool = false
var _pending: Array[Dictionary] = []
var _uploads: Array[Dictionary] = []
var _shares: Array[Dictionary] = []
var _requests: Array[Dictionary] = []
var _request: Dictionary = {}
var _timer: Timer = null


func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timeout)
	add_child(_timer)


## Call once after Steam.steamInit().
##
## config: prefix (required), axes, extra_keys, descending, excluded, timeout,
##         ranks, debug.
## axis:   id (required), default, tokens, always_token.
##
## read_only finds boards without creating them and blocks uploads, so a past
## season stays browsable.
func configure(config: Dictionary, steam_id: int = 0, read_only: bool = false) -> void:
	_config = config
	_steam_id = steam_id if steam_id != 0 else Steam.getSteamID()
	_read_only = read_only

	_axes.assign(config.get("axes", []))
	for axis: Dictionary in _axes:
		var id: String = axis.get("id", "")
		if not variant.has(id):
			variant[id] = axis.get("default", 0)
	view = variant.duplicate()

	for problem: String in validate():
		push_error("SteamLeaderboard: %s" % problem)

	_listen(Steam.leaderboard_find_result, _on_found)
	_listen(Steam.leaderboard_scores_downloaded, _on_downloaded)
	_listen(Steam.leaderboard_score_uploaded, _on_uploaded)
	_listen(Steam.leaderboard_ugc_set, _on_ugc_set)
	_listen(Steam.file_write_async_complete, _on_write_done)
	_listen(Steam.file_share_result, _on_shared)


func _listen(source: Signal, target: Callable) -> void:
	if not source.is_connected(target):
		source.connect(target)


# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

## Builds PREFIX_TOKEN_TOKEN_group.
##
## An axis contributes a token only when its value is not the default, unless
## always_token is set. The group goes last because level names often end in
## suffixes (level_b2) that would be ambiguous against tokens.
func board_name(for_group: String = "", for_variant: Dictionary = {}) -> String:
	if for_group.is_empty():
		for_group = group
	if for_variant.is_empty():
		for_variant = variant

	var parts: PackedStringArray = PackedStringArray()
	for axis: Dictionary in _axes:
		var token: String = _token(axis, for_variant.get(axis.get("id", ""), 0))
		if not token.is_empty():
			parts.append(token)
	if not for_group.is_empty():
		parts.append(for_group)
	return _prefix() + "_".join(parts)


# Always ends in "_", so "MyGame" cannot silently give "MyGamelevel_01".
func _prefix() -> String:
	var prefix: String = _config.get("prefix", "")
	if prefix.is_empty() or prefix.ends_with("_"):
		return prefix
	return prefix + "_"


func _token(axis: Dictionary, value: int) -> String:
	if value == axis.get("default", 0) and not axis.get("always_token", false):
		return ""
	return axis.get("tokens", {}).get(value, "")


## Splits a board name into {"group": String, "variant": Dictionary}.
func parse_name(board: String) -> Dictionary:
	var prefix: String = _prefix()
	if not board.begins_with(prefix):
		return {"group": "", "variant": {}}

	var found: Dictionary[String, int] = {}
	for axis: Dictionary in _axes:
		found[axis.get("id", "")] = axis.get("default", 0)

	var group_parts: PackedStringArray = PackedStringArray()
	for part: String in board.substr(prefix.length()).split("_"):
		var axis_id: String = _axis_for_token(part)
		if axis_id.is_empty():
			group_parts.append(part)
		else:
			found[axis_id] = _value_for_token(axis_id, part)
	return {"group": "_".join(group_parts), "variant": found}


func _axis_for_token(token: String) -> String:
	for axis: Dictionary in _axes:
		if axis.get("tokens", {}).values().has(token):
			return axis.get("id", "")
	return ""


func _value_for_token(axis_id: String, token: String) -> int:
	for axis: Dictionary in _axes:
		if axis.get("id", "") != axis_id:
			continue
		var tokens: Dictionary = axis.get("tokens", {})
		for value: int in tokens:
			if tokens[value] == token:
				return value
	return 0


## Boards created per group, the product of every axis. Each axis multiplies
## this, so it is worth printing once during setup.
func boards_per_group() -> int:
	var total: int = 1
	for axis: Dictionary in _axes:
		var values: Dictionary[int, bool] = {axis.get("default", 0): true}
		for value: int in axis.get("tokens", {}):
			values[value] = true
		total *= values.size()
	return total


## Config problems, empty when valid. A duplicate token silently misparses
## names rather than erroring, so call this in development.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(_config.get("prefix", "")).is_empty():
		problems.append("prefix is empty, boards would collide with other games")

	var owners: Dictionary[String, String] = {}
	for axis: Dictionary in _axes:
		var id: String = axis.get("id", "")
		if id.is_empty():
			problems.append("an axis has no id")
			continue

		var tokens: Dictionary = axis.get("tokens", {})
		for value: int in tokens:
			var token: String = tokens[value]
			if token.is_empty():
				problems.append("%s: value %d has an empty token" % [id, value])
			elif token.contains("_"):
				problems.append("%s: token '%s' contains '_'" % [id, token])
			elif owners.has(token):
				problems.append("token '%s' used by both '%s' and '%s'"
					% [token, owners[token], id])
			owners[token] = id

		var default_value: int = axis.get("default", 0)
		var always: bool = axis.get("always_token", false)
		if always and not tokens.has(default_value):
			problems.append("%s: always_token needs a token for default %d"
				% [id, default_value])
		elif not always and tokens.has(default_value):
			problems.append("%s: default %d must not have a token unless always_token"
				% [id, default_value])
	return problems


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

## Point at a level. Clears the previous level's state, then resolves this
## one's board so the handle is ready before the run ends.
func set_group(new_group: String) -> void:
	reset()
	group = new_group
	if _excluded(new_group):
		if _config.get("debug", false):
			print("[SteamLeaderboard] group '%s' is excluded, no board" % new_group)
		return
	_find(new_group, variant, true)


## Retarget uploads. The view follows.
func set_variant(axis_id: String, value: int) -> void:
	if variant.get(axis_id, -1) == value:
		return
	variant[axis_id] = value
	view[axis_id] = value
	_activate()


## Browse another board without moving where scores go.
func set_view(axis_id: String, value: int) -> void:
	if view.get(axis_id, -1) == value:
		return
	view[axis_id] = value
	_activate()


func _excluded(check: String) -> bool:
	return check in _config.get("excluded", [])


func _activate() -> void:
	var board: String = board_name(group, view)
	if _handles.has(board):
		handle = _handles[board]
		entry_count = Steam.getLeaderboardEntryCount(handle)
		board_ready.emit()
		return
	handle = 0
	_find(group, view, true)


# ---------------------------------------------------------------------------
# Board resolution
# ---------------------------------------------------------------------------

# Finds are serialized: Steam's callback does not say which board it answers,
# so two in flight would be indistinguishable.
func _find(find_group: String, find_variant: Dictionary, activate: bool) -> void:
	var board: String = board_name(find_group, find_variant)
	for queued: Dictionary in _finds:
		if queued["board"] == board:
			queued["activate"] = queued["activate"] or activate
			return
	_finds.append({"board": board, "activate": activate})
	_next_find()


func _next_find() -> void:
	if _finding or _finds.is_empty():
		return
	_finding = true
	var board: String = _finds[0]["board"]
	if _config.get("debug", false):
		print("[SteamLeaderboard] find %s" % board)
	if _read_only:
		Steam.findLeaderboard(board)
		return
	var sort: int = Steam.LEADERBOARD_SORT_METHOD_ASCENDING
	if _config.get("descending", false):
		sort = Steam.LEADERBOARD_SORT_METHOD_DESCENDING
	Steam.findOrCreateLeaderboard(board, sort, Steam.LEADERBOARD_DISPLAY_TYPE_NUMERIC)


func _on_found(board_handle: int, result: int) -> void:
	var entry: Dictionary = {}
	if _finding and not _finds.is_empty():
		entry = _finds.pop_front()
	_finding = false

	if entry.is_empty():
		_next_find()
		return

	var board: String = entry["board"]
	if result == 1:
		_handles[board] = board_handle
		_flush(board, board_handle)
		if entry["activate"]:
			handle = board_handle
			entry_count = Steam.getLeaderboardEntryCount(board_handle)
			board_ready.emit()
	else:
		push_warning("SteamLeaderboard: find failed for %s" % board)
		_drop(board)

	_next_find()
	_next_request()


# ---------------------------------------------------------------------------
# Submitting
# ---------------------------------------------------------------------------

## Send a score, queueing it when the board is not resolved yet.
##
## extra_info rides along on the entry, keyed by the "extra_keys" config list.
## context is handed back on [signal score_submitted] and [signal score_dropped],
## so an async callback never has to trust state that may have changed.
## keep_best false overwrites even with a worse score.
func submit(
	score: int,
	extra_info: Dictionary = {},
	context: Dictionary = {},
	keep_best: bool = true,
) -> void:
	if _read_only:
		return
	if _excluded(group):
		score_dropped.emit(context)
		return

	var details: PackedInt32Array = encode_extra(extra_info)
	var board: String = board_name(group, variant)
	if _handles.has(board):
		_send(_handles[board], score, details, keep_best, context)
		return

	_pending.append({
		"board": board, "score": score, "details": details,
		"keep_best": keep_best, "context": context,
	})
	_find(group, variant, false)


func _send(
	board_handle: int,
	score: int,
	details: PackedInt32Array,
	keep_best: bool,
	context: Dictionary,
) -> void:
	_uploads.append({"handle": board_handle, "context": context})
	Steam.uploadLeaderboardScore(score, keep_best, details, board_handle)
	if _config.get("debug", false):
		print("[SteamLeaderboard] submit %d to board %d" % [score, board_handle])


func _flush(board: String, board_handle: int) -> void:
	var remaining: Array[Dictionary] = []
	for queued: Dictionary in _pending:
		if queued["board"] == board:
			_send(board_handle, queued["score"], queued["details"],
				queued["keep_best"], queued["context"])
		else:
			remaining.append(queued)
	_pending = remaining


func _drop(board: String) -> void:
	var remaining: Array[Dictionary] = []
	for queued: Dictionary in _pending:
		if queued["board"] == board:
			score_dropped.emit(queued["context"])
		else:
			remaining.append(queued)
	_pending = remaining


func _on_uploaded(success: int, board_handle: int, _score: Dictionary) -> void:
	var context: Dictionary = {}
	for i: int in range(_uploads.size()):
		if _uploads[i]["handle"] == board_handle:
			context = _uploads[i]["context"]
			_uploads.remove_at(i)
			break
	score_submitted.emit(success == 1, context)


# ---------------------------------------------------------------------------
# Extra info
# ---------------------------------------------------------------------------

## Packs a dictionary into the int array Steam stores on an entry.
##
## Values are written in "extra_keys" order, so that list is the schema. Append
## to it freely; reordering or removing keys remaps existing entries, so change
## the prefix when you need to break it. Missing keys write 0.
func encode_extra(extra_info: Dictionary) -> PackedInt32Array:
	var keys: Array = _config.get("extra_keys", [])
	var packed: PackedInt32Array = PackedInt32Array()
	if keys.is_empty():
		return packed

	if keys.size() > EXTRA_MAX:
		push_warning("SteamLeaderboard: extra_keys holds %d entries, Steam stores %d"
			% [keys.size(), EXTRA_MAX])
	for key: String in keys.slice(0, EXTRA_MAX):
		packed.append(int(extra_info.get(key, 0)))
	return packed


## Reads an entry's details back into a dictionary. Keys absent from the entry
## are 0, so a score written before a key was added still reads cleanly.
func decode_extra(details: PackedInt32Array) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _config.get("extra_keys", [])
	for i: int in range(keys.size()):
		out[keys[i]] = details[i] if i < details.size() else 0
	return out


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

## Read entries. [param callback] takes an Array and always fires, with an
## empty array on failure or timeout.
##
## start/end are 1-based inclusive ranks, ignored for PERSONAL and GROUP.
## Only call once [signal board_ready] has fired.
func fetch(
	type: RequestType,
	callback: Callable,
	start: int = 1,
	end: int = 10,
	users: Array = [],
) -> void:
	_requests.append({
		"type": type, "callback": callback,
		"start": start, "end": end, "users": users,
	})
	_next_request()


func _next_request() -> void:
	if handle == 0 or _requests.is_empty() or not _request.is_empty():
		return
	_request = _requests.pop_front()
	_timer.start(_config.get("timeout", 10.0))

	var type: RequestType = _request["type"]
	if type == RequestType.PERSONAL:
		Steam.downloadLeaderboardEntriesForUsers([_steam_id], handle)
		return
	if type == RequestType.GROUP:
		Steam.downloadLeaderboardEntriesForUsers(_request["users"], handle)
		return

	var scope: int = Steam.LEADERBOARD_DATA_REQUEST_GLOBAL
	if type == RequestType.FRIENDS:
		scope = Steam.LEADERBOARD_DATA_REQUEST_FRIENDS
	elif type == RequestType.AROUND:
		scope = Steam.LEADERBOARD_DATA_REQUEST_GLOBAL_AROUND_USER
	Steam.downloadLeaderboardEntries(_request["start"], _request["end"], scope, handle)


func _on_downloaded(message: String, request_handle: int, result: Array) -> void:
	_timer.stop()
	if _request.is_empty():
		return
	# An empty message is normal for a board with no scores yet.
	if message.is_empty() or request_handle != handle:
		_deliver([])
		return
	entry_count = Steam.getLeaderboardEntryCount(handle)
	_deliver(result)


func _deliver(entries: Array) -> void:
	var callback: Callable = _request.get("callback", Callable())
	# Cleared first so a callback that fetches again does not reenter.
	_request = {}
	if callback.is_valid():
		callback.call_deferred(entries)
	_next_request()


func _on_timeout() -> void:
	if not _request.is_empty():
		_deliver([])


## Percentile label for a rank, from the "ranks" config key.
func rank_label(rank: int) -> String:
	var ranks: Dictionary = _config.get("ranks", {})
	if ranks.is_empty() or entry_count <= 0:
		return ""
	var percentile: float = float(rank) / float(entry_count)
	var thresholds: Array = ranks.keys()
	thresholds.sort()
	for threshold: float in thresholds:
		if percentile <= threshold:
			return ranks[threshold]
	return ranks[thresholds[thresholds.size() - 1]]


# ---------------------------------------------------------------------------
# Replays (UGC)
# ---------------------------------------------------------------------------

## Attach a replay to the player's entry: cloud write, share, attach.
##
## The board is captured now rather than when the share lands, so a slow upload
## cannot attach to the wrong board after a level change.
## file_name must not contain ':' or '/', which Steam rejects silently.
func attach_replay(file_name: String, data: PackedByteArray) -> void:
	if _read_only:
		return
	if file_name.contains(":") or file_name.contains("/"):
		push_error("SteamLeaderboard: invalid cloud name '%s'" % file_name)
		return
	_shares.append({"file": file_name, "board": board_name(group, variant)})
	Steam.fileWriteAsync(file_name, data, data.size())


# Write results arrive in call order, so FIFO matches a callback to its file.
func _on_write_done(result: int) -> void:
	if _shares.is_empty():
		return
	if result != Steam.RESULT_OK:
		push_warning("SteamLeaderboard: cloud write failed")
		_shares.pop_front()
		return
	Steam.fileShare(_shares[0]["file"])


func _on_shared(result: int, file_handle: int, file_name: String) -> void:
	var pending: Dictionary = {}
	for i: int in range(_shares.size()):
		if _shares[i]["file"] == file_name:
			pending = _shares.pop_at(i)
			break
	if result != Steam.RESULT_OK or pending.is_empty():
		push_warning("SteamLeaderboard: share failed for %s" % file_name)
		return

	var board_handle: int = _handles.get(pending["board"], 0)
	if board_handle == 0:
		push_warning("SteamLeaderboard: share landed for an unresolved board")
		return
	Steam.attachLeaderboardUGC(file_handle, board_handle)


func _on_ugc_set(_board_handle: int, result: int) -> void:
	replay_attached.emit(result == Steam.RESULT_OK)


## Download a replay. [param callback] takes a PackedByteArray, empty when the
## entry has no replay. Those entries have a ugc_handle of 0 or -1.
func download_replay(ugc_handle: int, callback: Callable) -> void:
	if ugc_handle == 0 or ugc_handle == -1:
		callback.call_deferred(PackedByteArray())
		return

	# One-shot and handle-matched: many downloads can be in flight at once.
	var on_done: Callable = func(result: int, info: Dictionary) -> void:
		if info.get("handle", 0) != ugc_handle:
			return
		if result != Steam.RESULT_OK:
			callback.call_deferred(PackedByteArray())
			return
		callback.call_deferred(Steam.ugcRead(ugc_handle, info.get("size", 0), 0,
			Steam.UGC_READ_CONTINUE_READING_UNTIL_FINISHED))
	Steam.download_ugc_result.connect(on_done, CONNECT_ONE_SHOT)
	Steam.ugcDownload(ugc_handle, 0)


# ---------------------------------------------------------------------------

## Clears per-level state. [method set_group] calls this for you.
func reset() -> void:
	handle = 0
	entry_count = 1
	_handles.clear()
	_finds.clear()
	_finding = false
	_pending.clear()
	_uploads.clear()
	_shares.clear()
	_requests.clear()
	_request = {}
	_timer.stop()
	view = variant.duplicate()
