## systems.input: the CS2 binds and mouse settings of the player, mapped onto Godot actions.
class_name SurfInput
extends RefCounted

var binds := {}        # cs2 command -> key name (CS2 naming)
var convars := {}
var sensitivity := 2.5
var m_yaw := 0.022
var m_pitch := 0.022
var source := ""

const KEYS := {
	"SPACE": KEY_SPACE, "CTRL": KEY_CTRL, "SHIFT": KEY_SHIFT, "ALT": KEY_ALT, "TAB": KEY_TAB,
	"ESCAPE": KEY_ESCAPE, "ENTER": KEY_ENTER, "BACKSPACE": KEY_BACKSPACE, "CAPSLOCK": KEY_CAPSLOCK,
	"UPARROW": KEY_UP, "DOWNARROW": KEY_DOWN, "LEFTARROW": KEY_LEFT, "RIGHTARROW": KEY_RIGHT,
	"INS": KEY_INSERT, "DEL": KEY_DELETE, "HOME": KEY_HOME, "END": KEY_END, "PGUP": KEY_PAGEUP, "PGDN": KEY_PAGEDOWN,
	"SEMICOLON": KEY_SEMICOLON, "`": KEY_QUOTELEFT, "\u0027": KEY_APOSTROPHE, ",": KEY_COMMA, ".": KEY_PERIOD, "/": KEY_SLASH,
	"[": KEY_BRACKETLEFT, "]": KEY_BRACKETRIGHT, "-": KEY_MINUS, "=": KEY_EQUAL, char(92): KEY_BACKSLASH,
}
const MOUSE := {"MOUSE1": MOUSE_BUTTON_LEFT, "MOUSE2": MOUSE_BUTTON_RIGHT, "MOUSE3": MOUSE_BUTTON_MIDDLE,
	"MOUSE4": MOUSE_BUTTON_XBUTTON1, "MOUSE5": MOUSE_BUTTON_XBUTTON2,
	"MWHEELUP": MOUSE_BUTTON_WHEEL_UP, "MWHEELDOWN": MOUSE_BUTTON_WHEEL_DOWN}

func _init(paths: Paths) -> void:
	# hooks.cs2_user_keys: the file of the player, with the CS2 defaults underneath it.
	var defaults := _parse_vcfg(paths.cs2_default_keys())
	var user := _parse_vcfg(paths.user_cfg("cs2_user_keys.vcfg"))
	source = "CS2 defaults"
	for k in defaults:
		binds[defaults[k]] = k
	for k in user:
		binds[user[k]] = k
		source = "your cs2_user_keys.vcfg"
	convars = _parse_vcfg(paths.user_cfg("cs2_user_convars.vcfg"))
	sensitivity = float(convars.get("sensitivity", "2.5"))
	m_yaw = float(convars.get("m_yaw", "0.022"))
	m_pitch = float(convars.get("m_pitch", "0.022"))
	for r in Sheets.load_sheet("input")["rows"]:
		var key: String = binds.get(r["cs2_command"], r["default_key"])
		_register(r["godot_action"], key)

## "KEY" "value" pairs from a vcfg; the nesting ("config"/"bindings") is skipped.
func _parse_vcfg(path: String) -> Dictionary:
	var out := {}
	if path == "" or not FileAccess.file_exists(path):
		return out
	var q := char(34)
	for line in FileAccess.get_file_as_string(path).split(char(10)):
		var parts := line.strip_edges().split(q)
		if parts.size() >= 5 and parts[0] == "":
			out[parts[1]] = parts[3]
	return out

func _register(action: String, key: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	var up := key.to_upper()
	var ev: InputEvent
	if MOUSE.has(up):
		ev = InputEventMouseButton.new()
		ev.button_index = MOUSE[up]
	else:
		ev = InputEventKey.new()
		if KEYS.has(up):
			ev.keycode = KEYS[up]
		elif up.begins_with("F") and up.substr(1).is_valid_int():
			ev.keycode = KEY_F1 + int(up.substr(1)) - 1
		elif up.begins_with("KP_"):
			ev.keycode = OS.find_keycode_from_string(up.substr(3))
		else:
			ev.keycode = OS.find_keycode_from_string(up)
	InputMap.action_add_event(action, ev)

## Degrees of turn for one mouse count, like Source: m_yaw * sensitivity.
func yaw_deg(counts: float) -> float:
	return counts * m_yaw * sensitivity

func pitch_deg(counts: float) -> float:
	return counts * m_pitch * sensitivity
