@tool
extends EditorPlugin
class_name GdSteamLdbPlugin

const AUTOLOAD_NAME: String = "SteamLeaderboard"
const AUTOLOAD_PATH: String = "res://addons/gd_steam_ldb/steam_leaderboard.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
