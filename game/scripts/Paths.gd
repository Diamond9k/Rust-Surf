## systems.launch_args: folders Melty hands the game at launch, and where the CS2 config of the player lives.
class_name Paths
extends RefCounted

var data_dir := ""   # extracted content (prep output)
var rust_dir := ""   # {game}
var cs2_dir := ""    # {game:counter-strike-2}
var steam_dir := ""  # Steam install (userdata lives here)
var error := ""

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--data": data_dir = _next(args, i); i += 1
			"--rust": rust_dir = _next(args, i); i += 1
			"--cs2": cs2_dir = _next(args, i); i += 1
		i += 1
	if data_dir == "" and OS.has_feature("editor"):
		# Dev run from the editor: data folder beside the project, games where Steam put them on this PC.
		data_dir = ProjectSettings.globalize_path("res://").path_join("../data").simplify_path()
		rust_dir = "C:/Program Files (x86)/Steam/steamapps/common/Rust"
		cs2_dir = "C:/Program Files (x86)/Steam/steamapps/common/Counter-Strike Global Offensive"
	for pair in [["--data", data_dir], ["--rust", rust_dir], ["--cs2", cs2_dir]]:
		if pair[1] == "" or not DirAccess.dir_exists_absolute(pair[1]):
			error = "Missing folder for %s: %s. Melty passes these at launch." % [pair[0], pair[1]]
			return
	steam_dir = _find_steam()

func _next(args: PackedStringArray, i: int) -> String:
	return args[i + 1] if i + 1 < args.size() else ""

## hooks.steam_root: registry SteamPath first, then the library root the CS2 folder sits in.
func _find_steam() -> String:
	var out := []
	if OS.get_name() == "Windows":
		OS.execute("reg", ["query", "HKCU" + char(92) + "Software" + char(92) + "Valve" + char(92) + "Steam", "/v", "SteamPath"], out, true)
		for line in "".join(PackedStringArray(out)).split(char(10)):
			if line.strip_edges().begins_with("SteamPath"):
				var parts := line.split("REG_SZ")
				if parts.size() == 2:
					var p := parts[1].strip_edges()
					if DirAccess.dir_exists_absolute(p):
						return p
	return cs2_dir.path_join("../../..").simplify_path()

## hooks.cs2_user_keys / cs2_user_convars: the file of the newest account first.
func user_cfg(file: String) -> String:
	var best := ""
	var best_time := 0
	var ud := steam_dir.path_join("userdata")
	var d := DirAccess.open(ud)
	if d:
		for acc in d.get_directories():
			var p := ud.path_join(acc).path_join("730/remote").path_join(file)
			if FileAccess.file_exists(p):
				var t := FileAccess.get_modified_time(p)
				if t >= best_time:
					best_time = t
					best = p
	return best

func cs2_default_keys() -> String:
	return cs2_dir.path_join("game/csgo/cfg/user_keys_default.vcfg")
