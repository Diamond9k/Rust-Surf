## systems.settings: the Esc menu laid out like CS2's: an icon nav bar (settings, resume, aim lobby, restart, quit),
## the settings tabs (Game, Keyboard / Mouse, Audio, Video, Crosshair) over the blurred game, settings.json rows as
## slider + number field or dropdown, the input.json binds (two keys per action) and a live crosshair preview.
## Values start from the player's CS2 convars, unrounded; only changes go to user://settings.json.
class_name Settings
extends CanvasLayer

var FILE := "user://settings.json"  # --uitest points it at a scratch file
const TABS := [["game", "Game"], ["keys", "Keyboard / Mouse"], ["audio", "Audio"], ["video", "Video"], ["crosshair", "Crosshair"]]
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(0.62, 0.64, 0.68)
const FILL := Color(0.86, 0.87, 0.9)
# v0.2 settings.json keys -> settings.json row ids
const OLD := {"sens": "sensitivity", "vm_fov": "viewmodel_fov", "vm_x": "viewmodel_offset_x", "vm_y": "viewmodel_offset_y",
	"vm_z": "viewmodel_offset_z", "xh_size": "cl_crosshairsize", "xh_gap": "cl_crosshairgap", "xh_thick": "cl_crosshairthickness",
	"xh_color": "cl_crosshaircolor", "xh_dot": "cl_crosshairdot", "speed": "show_speed"}
const BLUR := """shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float vignette = 0.0;
void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * 6.0;
	vec3 c = vec3(0.0);
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			c += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, 3.0).rgb;
		}
	}
	vec3 col = mix(c / 25.0, vec3(0.035, 0.04, 0.05), 0.6);
	vec2 d = (SCREEN_UV - 0.5) * vec2(1.0, 0.8);
	COLOR = vec4(col * (1.0 - vignette * smoothstep(0.15, 0.75, length(d) * 1.4)), 1.0);
}"""

var main: Node
var is_open := false
var vals := {}
var rows := {}           # id -> settings.json row
var _changed := {}
var _keys := {}          # input.json id -> [key, key] in slot order (CS2 key names, upper case)
var _keys_set := {}      # input.json ids whose keys the player set here (saved)
var _root: Control
var _tab := "game"
var _pages := {}
var _lists := {}         # tab -> the rows' VBox (its height sizes the panel, so the panel ends with its rows)
var _area: Control
var _tab_btns := {}
var _ctl := {}           # id -> [slider or option, number field or null]
var _bind_btns := {}     # "id:slot" -> Button
var _capture := ""       # "id:slot" waiting for a key
var _capture_frame := -1
var _preview: Control
var _u := 1.0
var _loading := true
var _no_save := false    # an unreadable settings file could not be set aside: never write over it
var _was_frozen := false # the player's frozen state before the menu opened (Shots or a lobby pose may hold it)
var _lim := {}           # slider id -> [lo, hi]: the sheet range widened to take the player's own CS2 value
var _save_due := false   # a slider moved: one save after hud.json menu_save_delay, not one per value_changed
var saves := 0           # files written this session (--uitest counts them)

func setup(m: Node) -> void:
	main = m
	layer = 50
	for r in Sheets.load_sheet("settings")["rows"]:
		rows[r["id"]] = r
	_base_keys()
	_load()
	_apply_keys()
	_build()
	for k in vals:
		if not _changed.has(k):
			if k == "display_mode" or k == "vsync":
				continue  # the window follows project.godot until the player picks otherwise
			if String(rows[k]["convar"]).begins_with("cl_crosshair"):
				continue  # Hud already reads the player's own convar text; rewriting it could only round it
		_apply(k)
	_loading = false
	_root.visible = false
	get_viewport().size_changed.connect(_rebuild)
	if OS.get_cmdline_user_args().has("--menu"):
		var ua := OS.get_cmdline_user_args()
		var ti := ua.find("--menu-tab")
		if ti >= 0 and ti + 1 < ua.size():
			_tab = ua[ti + 1]
		toggle()
	if OS.get_cmdline_user_args().has("--uitest"):
		_uitest.call_deferred()

func toggle() -> void:
	if _capture != "" or Engine.get_process_frames() == _capture_frame:
		return  # Esc while binding a key cancels the bind, not the menu
	is_open = not is_open
	_root.visible = is_open
	_show_tab(_tab)
	main.hud.visible = not is_open  # the menu covers the game; the HUD never draws over it
	var buy: Variant = main.weapons.get("_buy") if main.get("weapons") != null else null
	if is_open and buy is CanvasItem and (buy as CanvasItem).visible:
		(buy as CanvasItem).visible = false  # one menu at a time
	if is_open:  # the menu pauses movement like a paused local server, and gives back whatever held it before
		_was_frozen = main.player.frozen
		main.player.frozen = true
	else:
		main.player.frozen = _was_frozen
		_flush()
	if main.timer: main.timer.set_process(not is_open)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if is_open else Input.MOUSE_MODE_CAPTURED

# --- values ---

func _is_convar(r: Dictionary) -> bool:
	var c: String = r["convar"]
	return not c.contains(" ") and not c.begins_with("(")

## Start value: the player's CS2 convar, else the live system value, else the sheet default.
## Slider values stay exactly as the player's config has them (no clamp, no step rounding).
func _initial(r: Dictionary) -> Variant:
	var id: String = r["id"]
	var cv: Dictionary = main.hud.convars
	var kind: String = r["kind"]
	var v: Variant = r["default"]
	match id:
		"sensitivity": v = main.player.input.sensitivity
		"m_yaw": v = main.player.input.m_yaw
		"invert_mouse": v = main.player.input.m_pitch < 0.0
		"display_mode": v = 1 if DisplayServer.window_get_mode() >= DisplayServer.WINDOW_MODE_FULLSCREEN else 0
		"vsync": v = 0 if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED else 1
		"msaa": v = clampi(get_viewport().msaa_3d, 0, 3)
		"render_scale": v = get_viewport().scaling_3d_scale
		_:
			if id.begins_with("viewmodel_") and main.viewmodel.V.has(id):
				v = main.viewmodel.V[id]
			elif _is_convar(r) and cv.has(r["convar"]):
				v = Hud.on(cv, r["convar"], "0") if kind == "toggle" else Hud.num(cv, r["convar"], float(r["default"]))
	return float(v) if kind == "slider" else _fit(r, v)

## The value as the menu holds it: toggles bool, choices an index, sliders clamped (and snapped to the step
## when snap is true, as the slider itself moves; a typed number keeps its digits).
func _fit(r: Dictionary, v: Variant, snap: bool = true) -> Variant:
	match String(r["kind"]):
		"toggle":
			return v if v is bool else float(v) > 0.5
		"choice":
			return clampi(int(v), 0, String(r["choices"]).split("|").size() - 1)
		"slider":
			var st := float(r["step"])
			var lh: Array = _lim.get(r["id"], [float(r["min"]), float(r["max"])])
			var f := clampf(float(v), float(lh[0]), float(lh[1]))
			return snappedf(f, st) if snap and st > 0.0 else f
	return v

func _load() -> void:
	for id in rows:
		if rows[id]["kind"] != "binds":
			vals[id] = _initial(rows[id])
			if rows[id]["kind"] == "slider":  # a CS2 value past the slider's range stays the player's, never clamped
				_lim[id] = [minf(float(rows[id]["min"]), float(vals[id])), maxf(float(rows[id]["max"]), float(vals[id]))]
	# a settings.json.tmp left beside the file is the newest whole write (the rename after it failed or was cut
	# off), so it wins when it parses; a torn temp is ignored and overwritten by the next save
	var d: Variant = _read(FILE + ".tmp")
	var path := FILE + ".tmp"
	if not (d is Dictionary):
		path = FILE
		if not FileAccess.file_exists(path):
			return
		d = _read(path)
	if not (d is Dictionary):
		# set the unreadable file aside before any save can write over it; if that fails, never save this session
		var bad := FILE + ".bad"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bad))
		_no_save = DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(bad)) != OK
		var why := "settings file unreadable: %s" % ("left untouched, changes will not be saved" if _no_save else "kept as " + bad.get_file())
		push_warning(why)
		main.hud.message(why + ", using your CS2 config", 6.0)
		return
	var saved: Dictionary = d.get("values", {}) if d.get("values") is Dictionary else {}
	if not d.has("values"):  # v0.2 file: flat keys
		for k in d:
			if OLD.has(k):
				saved[OLD[k]] = d[k]
		if d.get("volume") is float:
			saved["volume"] = float(d["volume"]) / 100.0
	for k in saved:
		if vals.has(k) and (saved[k] is float or saved[k] is bool):
			if _lim.has(k) and saved[k] is float:  # a value the player set here earlier is in range by definition
				_lim[k] = [minf(float(_lim[k][0]), float(saved[k])), maxf(float(_lim[k][1]), float(saved[k]))]
			vals[k] = _fit(rows[k], saved[k], false)
			_changed[k] = true
	if d.get("keys") is Dictionary:  # v0.2.1: id -> [key, key]
		for id in d["keys"]:
			if _keys.has(id) and d["keys"][id] is Array:
				var ks: Array = []
				for k in d["keys"][id]:
					ks.append(String(k).to_upper())
				_set_keys(id, ks)
	elif d.get("binds") is Dictionary:  # v0.2: id -> one key
		for id in d["binds"]:
			if _keys.has(id) and d["binds"][id] is String:
				_set_keys(id, [String(d["binds"][id]).to_upper()])

## The parsed file, or null when it is missing or does not parse (parse() reports it to us, not the log).
func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var js := JSON.new()
	return js.data if js.parse(FileAccess.get_file_as_string(path)) == OK else null

## A slider drag saves once, menu_save_delay after it settles (closing the menu saves at once).
func _save_soon() -> void:
	if _save_due:
		return
	_save_due = true
	get_tree().create_timer(float(main.hud.H["menu_save_delay"])).timeout.connect(_flush)

func _flush() -> void:
	if _save_due:
		_save()

## Writes a temp file and renames it over the old one, so a crash mid-write never loses the settings.
func _save() -> void:
	_save_due = false
	if _no_save:
		return
	saves += 1
	var out := {}
	for k in _changed:  # only what the player changed here, so the rest keeps following their CS2 config
		out[k] = vals[k]
	var keys := {}
	for id in _keys_set:
		keys[id] = _keys[id]
	var tmp := FILE + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		main.hud.message("could not save settings: %s" % error_string(FileAccess.get_open_error()), 3.0)
		return
	f.store_string(JSON.stringify({"values": out, "keys": keys}, "\t"))
	f.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(FILE))
	if err != OK:
		main.hud.message("could not save settings: %s" % error_string(err), 3.0)

func _apply(k: String) -> void:
	var r: Dictionary = rows[k]
	var v: Variant = vals[k]
	var h: Hud = main.hud
	if String(r["convar"]).begins_with("cl_crosshair"):
		h.convars[r["convar"]] = ("1" if v else "0") if v is bool else str(int(v)) if r["kind"] == "choice" else str(v)
		h.crosshair.queue_redraw()
		if _preview:
			_preview.queue_redraw()
		return
	if k.begins_with("viewmodel_"):
		main.viewmodel.set_view({k: v})
		return
	match k:
		"show_speed": h.set_speed_visible(v)
		"hit_marker": h.hit_marker = v
		"cl_showfps": h.set_fps_visible(v)
		"sensitivity": main.player.input.sensitivity = v
		"m_yaw": main.player.input.m_yaw = v
		"zoom_sensitivity_ratio":
			var w: Variant = main.get("weapons")
			if w != null and w.get("X") is Dictionary:
				w.X["zoom_sensitivity_ratio"] = v  # Weapons._set_zoom reads it on the next scope
		"invert_mouse": main.player.input.m_pitch = -absf(main.player.input.m_pitch) if v else absf(main.player.input.m_pitch)
		"volume":
			AudioServer.set_bus_mute(0, v <= 0.0)
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.0001)))
		"snd_musicvolume": _channel(["menu_music"], v)
		"ambient_volume":
			_channel(["ambience_loop"], v)
			if main.sounds and main.sounds.rows.has("speed_wind"):
				main.sounds._wind_db = float(main.sounds.rows["speed_wind"]["volume_db"]) + linear_to_db(maxf(v, 0.0001))
		"display_mode": DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if v == 1 else DisplayServer.WINDOW_MODE_WINDOWED)
		"vsync": DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v == 1 else DisplayServer.VSYNC_DISABLED)
		"fps_max": Engine.max_fps = maxi(int(v), 0)
		"msaa": get_viewport().msaa_3d = int(v) as Viewport.MSAA
		"render_scale": get_viewport().scaling_3d_scale = v

## sounds.json players at their row level times v (0 is silent).
func _channel(ids: Array, v: float) -> void:
	if main.sounds == null:
		return
	for id in ids:
		var p: AudioStreamPlayer = main.sounds.players.get(id)
		if p:
			p.volume_db = float(main.sounds.rows[id]["volume_db"]) + linear_to_db(maxf(v, 0.0001))

## soon: a slider drag, saved once it settles instead of on every step.
func _change(k: String, v: Variant, snap: bool = true, soon: bool = false) -> void:
	v = _fit(rows[k], v, snap)
	if vals[k] == v and _changed.has(k):
		return
	vals[k] = v
	_apply(k)
	if not _loading:
		_changed[k] = true
		if soon:
			_save_soon()
		else:
			_save()

# --- binds ---

func _input_rows() -> Array:
	return Sheets.load_sheet("input")["rows"]

## Every key of the player's CS2 binds (defaults, then cs2_user_keys.vcfg over them, key by key), grouped per
## input.json action; an action with no key there gets its default_key. A key belongs to one action, like CS2.
func _base_keys() -> void:
	var by_key := {}
	var si: SurfInput = main.sinput
	if main.get("paths") != null:
		for path in [main.paths.cs2_default_keys(), main.paths.user_cfg("cs2_user_keys.vcfg")]:
			var d: Dictionary = si._parse_vcfg(path)
			for k in d:
				by_key[String(k).to_upper()] = d[k]
	for r in _input_rows():
		var ks: Array = []
		var first := String(si.binds.get(r["cs2_command"], "")).to_upper()
		if first != "" and by_key.get(first) == r["cs2_command"]:
			ks.append(first)  # the key SurfInput registered stays the primary slot
		for k in by_key:
			if by_key[k] == r["cs2_command"] and not ks.has(k):
				ks.append(k)
		if ks.is_empty():
			ks.append(String(r["default_key"]).to_upper())
		_keys[r["id"]] = ks.slice(0, 2)
	for id in _keys:  # a key named twice (a vcfg quirk) stays with the first action only
		for k in _keys[id]:
			for other in _keys:
				if other != id and (_keys[other] as Array).has(k):
					(_keys[other] as Array).erase(k)

## Sets an action's keys and takes each of them off every other action (CS2 moves a key, it never doubles it).
func _set_keys(id: String, ks: Array) -> void:
	for k in ks:
		for other in _keys:
			if other != id and (_keys[other] as Array).has(k):
				(_keys[other] as Array).erase(k)
				_keys_set[other] = true
	_keys[id] = ks.slice(0, 2)
	_keys_set[id] = true

## Puts _keys into the InputMap: each action gets exactly its keys (SurfInput builds each event).
func _apply_keys() -> void:
	var tmp := "_settings_key"
	for r in _input_rows():
		var action: String = r["godot_action"]
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for k in _keys.get(r["id"], []):
			main.sinput._register(tmp, k)
			for ev in InputMap.action_get_events(tmp):
				InputMap.action_add_event(action, ev)
	if InputMap.has_action(tmp):
		InputMap.erase_action(tmp)

## CS2 key name for a pressed key or mouse button (the names cs2_user_keys.vcfg uses).
func _key_name(ev: InputEvent) -> String:
	if ev is InputEventMouseButton:
		for n in SurfInput.MOUSE:
			if SurfInput.MOUSE[n] == ev.button_index:
				return n
		return ""
	var kc: Key = (ev as InputEventKey).keycode
	for n in SurfInput.KEYS:
		if SurfInput.KEYS[n] == kc:
			return n
	if kc >= KEY_F1 and kc <= KEY_F12:
		return "F%d" % (kc - KEY_F1 + 1)
	return OS.get_keycode_string(kc).to_upper()

func _input(ev: InputEvent) -> void:
	if _capture == "" or not ev.is_pressed() or ev.is_echo():
		return
	if not (ev is InputEventKey or ev is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	var slot := _capture
	_capture = ""
	_capture_frame = Engine.get_process_frames()
	if ev is InputEventKey and (ev as InputEventKey).keycode == KEY_ESCAPE:
		_refresh_binds()
		return
	var key := _key_name(ev)
	if key != "":
		_rebind(slot, key)
	_refresh_binds()

## "id:slot" gets key; "" clears the slot. A key already in this action's other slot swaps places with it,
## so no key is lost.
func _rebind(slot: String, key: String) -> void:
	var id := slot.get_slice(":", 0)
	var i := int(slot.get_slice(":", 1))
	var ks: Array = (_keys[id] as Array).duplicate()
	var j := ks.find(key) if key != "" else -1
	if j >= 0 and i < ks.size():
		ks[j] = ks[i]
		ks[i] = key
	elif j >= 0:
		pass  # an empty slot asked for a key this action already has: it stays where it is
	elif i < ks.size():
		if key == "":
			ks.remove_at(i)
		else:
			ks[i] = key
	elif key != "":
		ks.append(key)
	_set_keys(id, ks)
	_apply_keys()
	_save()

func _refresh_binds() -> void:
	for s in _bind_btns:
		var ks: Array = _keys.get(String(s).get_slice(":", 0), [])
		var i := int(String(s).get_slice(":", 1))
		(_bind_btns[s] as Button).text = String(ks[i]).to_upper() if i < ks.size() else "-"

func _reset_binds() -> void:
	_keys.clear()
	_keys_set.clear()
	_base_keys()
	_apply_keys()
	_save()
	_refresh_binds()

# --- layout ---

func _rebuild() -> void:
	if _root == null:
		return
	_root.queue_free()
	_capture = ""
	_build()
	_root.visible = is_open
	_show_tab(_tab)

func _px(v: float) -> int:
	return maxi(int(round(v * _u)), 1)

func _sb(c: Color, radius: float = 2.0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(_px(radius))
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1)
	s.content_margin_left = _px(10)
	s.content_margin_right = _px(10)
	s.content_margin_top = _px(3)
	s.content_margin_bottom = _px(3)
	return s

func _theme() -> Theme:
	var t := Theme.new()
	if main.hud.menu_font:
		t.default_font = main.hud.menu_font
	t.default_font_size = _px(float(main.hud.H["menu_font"]))
	for c in ["Label", "Button", "OptionButton", "LineEdit", "PopupMenu"]:
		t.set_color("font_color", c, TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_hover_color", "OptionButton", Color.WHITE)
	t.set_stylebox("normal", "OptionButton", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
	t.set_stylebox("hover", "OptionButton", _sb(Color(1, 1, 1, 0.1), 2, Color(1, 1, 1, 0.25)))
	t.set_stylebox("pressed", "OptionButton", _sb(Color(1, 1, 1, 0.14), 2, Color(1, 1, 1, 0.25)))
	t.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	t.set_icon("arrow", "OptionButton", _caret(_px(10)))
	t.set_stylebox("panel", "PopupMenu", _sb(Color(0.09, 0.1, 0.11, 0.98), 2, Color(1, 1, 1, 0.15)))
	t.set_stylebox("hover", "PopupMenu", _sb(Color(1, 1, 1, 0.12)))
	t.set_stylebox("normal", "LineEdit", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
	t.set_stylebox("focus", "LineEdit", _sb(Color(0, 0, 0, 0.5), 2, Color(1, 1, 1, 0.45)))
	t.set_stylebox("panel", "TooltipPanel", _sb(Color(0.06, 0.065, 0.07, 0.97), 2, Color(1, 1, 1, 0.18)))
	t.set_color("font_color", "TooltipLabel", TEXT)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.16)
	track.content_margin_top = _px(2)
	track.content_margin_bottom = _px(2)
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = FILL
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var grab := _circle(_px(12), Color.WHITE)
	t.set_icon("grabber", "HSlider", grab)
	t.set_icon("grabber_highlight", "HSlider", grab)
	var sbar := StyleBoxFlat.new()
	sbar.bg_color = Color(1, 1, 1, 0.05)
	sbar.content_margin_left = _px(3)
	sbar.content_margin_right = _px(3)
	var sgrab := StyleBoxFlat.new()
	sgrab.bg_color = Color(1, 1, 1, 0.3)
	sgrab.set_corner_radius_all(_px(3))
	t.set_stylebox("scroll", "VScrollBar", sbar)
	t.set_stylebox("grabber", "VScrollBar", sgrab)
	t.set_stylebox("grabber_highlight", "VScrollBar", sgrab)
	t.set_stylebox("grabber_pressed", "VScrollBar", sgrab)
	return t

## A small solid down caret d px wide for the dropdowns (a game menu's, not a web form's chevron).
func _caret(d: int) -> ImageTexture:
	var img := Image.create_empty(d, d, false, Image.FORMAT_RGBA8)
	for x in d:
		for y in d:
			var u := (x + 0.5) / d * 2.0 - 1.0
			var v := (y + 0.5) / d
			var a := clampf((0.72 - v - absf(u) * 0.5) * d * 0.9, 0.0, 1.0) if v > 0.28 else 0.0  # apex at the bottom
			img.set_pixel(x, y, Color(DIM.r, DIM.g, DIM.b, a))
	return ImageTexture.create_from_image(img)

func _circle(d: int, c: Color) -> ImageTexture:
	var img := Image.create_empty(d, d, false, Image.FORMAT_RGBA8)
	var r := d * 0.5
	for x in d:
		for y in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(c.r, c.g, c.b, clampf(r - dist, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

func _build() -> void:
	var vp := get_viewport().get_visible_rect().size
	_u = vp.y / float(main.hud.H["menu_ref_height"])
	_pages.clear()
	_lists.clear()
	_tab_btns.clear()
	_ctl.clear()
	_bind_btns.clear()
	_preview = null
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = _theme()
	add_child(_root)
	var blur := ColorRect.new()
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = BLUR
	mat.set_shader_parameter("vignette", float(main.hud.H["menu_vignette"]))
	blur.material = mat
	_root.add_child(blur)
	# nav bar: icon buttons like CS2's main menu (settings lit, resume, aim lobby, restart; quit on the right)
	var nav_h := _px(float(main.hud.H["menu_nav"]))
	var nav := Panel.new()
	var nsb := _sb(Color(0.015, 0.018, 0.022, 0.92), 0)
	nsb.border_color = Color(1, 1, 1, 0.07)
	nsb.border_width_bottom = 1
	nav.add_theme_stylebox_override("panel", nsb)
	nav.set_anchors_preset(Control.PRESET_TOP_WIDE)
	nav.offset_bottom = nav_h
	_root.add_child(nav)
	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = _px(10)
	hb.offset_right = -_px(10)
	hb.add_theme_constant_override("separation", _px(2))
	nav.add_child(hb)
	_nav_button(hb, "gear", "", "Settings", nav_h, true)
	_nav_button(hb, "play", "RESUME", "Back to the game (Esc)", nav_h).pressed.connect(toggle)
	var sep := ColorRect.new()
	sep.color = Color(1, 1, 1, 0.1)
	sep.custom_minimum_size = Vector2(1, nav_h * 0.5)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(sep)
	_nav_button(hb, "target", "", "Aim lobby", nav_h).pressed.connect(func() -> void:
		toggle()
		main.lobby.toggle())
	_nav_button(hb, "restart", "", "Restart the run", nav_h).pressed.connect(func() -> void:
		toggle()
		if main.lobby.active:
			main.lobby.toggle()  # leaving the lobby already puts you back on the start pad
		else:
			main.course.restart(main.player)
			main.timer.reset())
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sp)
	_nav_button(hb, "power", "", "Quit", nav_h).pressed.connect(func() -> void: get_tree().quit())
	# settings tabs under the nav bar, centred, the open one underlined
	var tab_h := _px(float(main.hud.H["menu_tabs"]))
	var tb := HBoxContainer.new()
	tb.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tb.offset_top = nav_h
	tb.offset_bottom = nav_h + tab_h
	tb.alignment = BoxContainer.ALIGNMENT_CENTER
	tb.add_theme_constant_override("separation", _px(6))
	_root.add_child(tb)
	var group := ButtonGroup.new()
	for t in TABS:
		var b := _flat_button(tb, String(t[1]).to_upper(), tab_h)
		b.toggle_mode = true
		b.button_group = group
		var tid: String = t[0]
		b.pressed.connect(func() -> void: _show_tab(tid))
		_tab_btns[tid] = b
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.08)
	line.set_anchors_preset(Control.PRESET_TOP_WIDE)
	line.offset_top = nav_h + tab_h
	line.offset_bottom = nav_h + tab_h + 1
	_root.add_child(line)
	# pages: one centred column under the tabs
	var w := minf(float(main.hud.H["menu_width"]) * _u, vp.x - _px(32))
	var area := Control.new()
	area.anchor_left = 0.5
	area.anchor_right = 0.5
	area.anchor_bottom = 1.0
	area.offset_left = -w * 0.5
	area.offset_right = w * 0.5
	area.offset_top = nav_h + tab_h + _px(16)
	area.offset_bottom = -_px(18)
	_root.add_child(area)
	_area = area
	var back := Panel.new()  # the darker, near-opaque column behind the rows
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_theme_stylebox_override("panel", _sb(Color(0.016, 0.019, 0.024, float(main.hud.H["menu_panel_alpha"])), 3, Color(1, 1, 1, 0.06)))
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.offset_left = -_px(12)
	back.offset_right = _px(12)
	back.offset_top = -_px(10)
	back.offset_bottom = _px(8)
	area.add_child(back)
	for t in TABS:
		var page := _page(String(t[0]), w)
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.visible = false
		area.add_child(page)
		_pages[t[0]] = page

## A nav-bar button: a drawn icon, optional text after it, a tooltip; lit is the page you are on.
func _nav_button(parent: Control, icon: String, text: String, tip: String, h: int, lit: bool = false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(h, h)
	b.text = text
	b.add_theme_font_size_override("font_size", _px(17))
	_bold(b)
	b.add_theme_color_override("font_color", Color.WHITE if lit else TEXT)
	var pad := func(c: Color, under: bool) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = c
		s.content_margin_left = h * 0.86 if text != "" else 0.0
		s.content_margin_right = _px(16) if text != "" else 0.0
		if under:
			s.border_color = Color.WHITE
			s.border_width_bottom = _px(3)
		return s
	b.add_theme_stylebox_override("normal", pad.call(Color(1, 1, 1, 0.06) if lit else Color(0, 0, 0, 0), lit))
	b.add_theme_stylebox_override("hover", pad.call(Color(1, 1, 1, 0.1), lit))
	b.add_theme_stylebox_override("pressed", pad.call(Color(1, 1, 1, 0.14), lit))
	var ic := Control.new()
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.custom_minimum_size = Vector2(h, h)
	ic.size = Vector2(h, h)
	ic.draw.connect(func() -> void:
		var on := lit or b.is_hovered()
		_icon(ic, icon, Vector2(h, h) * 0.5 + Vector2(h * 0.08 if text != "" else 0.0, 0), h * 0.2, Color.WHITE if on else DIM))
	b.mouse_entered.connect(ic.queue_redraw)
	b.mouse_exited.connect(ic.queue_redraw)
	b.add_child(ic)
	parent.add_child(b)
	return b

## Line icons drawn at c with radius r: gear, play, target, restart, power.
func _icon(ci: CanvasItem, icon: String, c: Vector2, r: float, col: Color) -> void:
	var w := maxf(r * 0.2, 1.5)
	match icon:
		"play":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.6, -r * 0.8), c + Vector2(r * 0.85, 0), c + Vector2(-r * 0.6, r * 0.8)]), col)
		"gear":
			var pts := PackedVector2Array()
			for i in 32:
				var a := TAU * i / 32.0
				var tooth := (i % 4) < 2
				pts.append(c + Vector2(cos(a), sin(a)) * r * (1.0 if tooth else 0.74))
			ci.draw_colored_polygon(pts, col)
			ci.draw_circle(c, r * 0.36, Color(0.015, 0.018, 0.022))
		"target":
			ci.draw_arc(c, r * 0.72, 0, TAU, 32, col, w, true)
			for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
				ci.draw_line(c + d * r * 0.38, c + d * r * 1.05, col, w, true)
			ci.draw_circle(c, w * 0.7, col)
		"restart":
			ci.draw_arc(c, r * 0.78, -PI * 0.35, PI * 1.45, 32, col, w, true)
			var e := c + Vector2(cos(-PI * 0.35), sin(-PI * 0.35)) * r * 0.78
			ci.draw_colored_polygon(PackedVector2Array([e + Vector2(-r * 0.42, -r * 0.12), e + Vector2(r * 0.18, -r * 0.4), e + Vector2(r * 0.12, r * 0.25)]), col)
		"power":
			ci.draw_arc(c, r * 0.8, -PI * 0.3, PI * 1.3, 32, col, w, true)
			ci.draw_line(c + Vector2(0, -r * 1.0), c + Vector2(0, -r * 0.15), col, w, true)

## Titles, tabs and the nav bar keep the HUD's bold face; rows use the theme's lighter one.
func _bold(c: Control) -> void:
	if main.hud.font:
		c.add_theme_font_override("font", main.hud.font)

func _flat_button(parent: Control, text: String, h: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = h
	b.add_theme_font_size_override("font_size", _px(15))
	_bold(b)
	b.add_theme_color_override("font_color", DIM)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	var pad := func(c: Color, under: bool) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = c
		s.content_margin_left = _px(14)
		s.content_margin_right = _px(14)
		if under:
			s.border_color = Color.WHITE
			s.border_width_bottom = _px(2)
		return s
	b.add_theme_stylebox_override("normal", pad.call(Color(0, 0, 0, 0), false))
	b.add_theme_stylebox_override("hover", pad.call(Color(1, 1, 1, 0.06), false))
	b.add_theme_stylebox_override("pressed", pad.call(Color(0, 0, 0, 0), true))
	b.add_theme_stylebox_override("hover_pressed", pad.call(Color(1, 1, 1, 0.06), true))
	parent.add_child(b)
	return b

func _show_tab(t: String) -> void:
	if not _pages.has(t):
		t = "game"
	_tab = t
	for k in _pages:
		_pages[k].visible = k == t
	(_tab_btns[t] as Button).set_pressed_no_signal(true)
	_fit_area.call_deferred()

## The panel ends under the open tab's last row (scrolling only when the rows outgrow the window).
func _fit_area() -> void:
	if _area == null or not is_instance_valid(_area) or not _lists.has(_tab):
		return
	var h: float = (_lists[_tab] as Control).get_combined_minimum_size().y
	var host := _pages[_tab] as Control
	if host is HBoxContainer:
		h = maxf(h, host.get_combined_minimum_size().y)
	var room := get_viewport().get_visible_rect().size.y - _area.offset_top - _px(18)
	_area.anchor_bottom = 0.0
	_area.offset_bottom = _area.offset_top + minf(h, room)

func _page(tab: String, w: float) -> Control:
	var host: Control
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 0)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	if tab == "crosshair":
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", _px(18))
		hb.add_child(_preview_panel(w * 0.36))
		hb.add_child(scroll)
		host = hb
	else:
		host = scroll
	_lists[tab] = list
	var section := ""
	var n := 0
	for id in rows:
		var r: Dictionary = rows[id]
		if r["tab"] != tab:
			continue
		if r["kind"] == "binds":
			_binds_list(list)
			continue
		if r["section"] != section:
			section = r["section"]
			_header(list, section)
			n = 0
		_row(list, r, n)
		n += 1
	return host

## A section title with a rule under it; cols names the columns of the controls on the right (bind slots).
func _header(parent: Control, text: String, cols: Array = []) -> void:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", _px(10))
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", _px(18))
	l.add_theme_color_override("font_color", Color.WHITE)
	_bold(l)
	hb.add_child(l)
	for c in cols:
		var cl := Label.new()
		cl.text = String(c).to_upper()
		cl.custom_minimum_size.x = _px(128)
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		cl.add_theme_font_size_override("font_size", _px(12))
		cl.add_theme_color_override("font_color", DIM)
		hb.add_child(cl)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", _px(18) if parent.get_child_count() > 0 else _px(2))
	pad.add_theme_constant_override("margin_bottom", _px(8))
	pad.add_theme_constant_override("margin_left", _px(4))
	pad.add_theme_constant_override("margin_right", _px(10))
	pad.add_child(hb)
	parent.add_child(pad)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.12)
	rule.custom_minimum_size.y = 1
	parent.add_child(rule)

## One settings line: label left, control right, alternating shade like CS2's lists.
func _line(parent: Control, label: String, n: int) -> HBoxContainer:
	var pc := PanelContainer.new()
	var s := _sb(Color(1, 1, 1, 0.045) if n % 2 == 0 else Color(0, 0, 0, 0.18), 0)
	s.content_margin_left = _px(14)
	s.content_margin_right = _px(10)
	pc.add_theme_stylebox_override("panel", s)
	pc.custom_minimum_size.y = _px(float(main.hud.H["menu_row"]))
	parent.add_child(pc)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", _px(10))
	pc.add_child(hb)
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.82, 0.84, 0.87))
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(l)
	return hb

func _row(parent: Control, r: Dictionary, n: int) -> void:
	var k: String = r["id"]
	var hb := _line(parent, r["label"], n)
	var right := HBoxContainer.new()
	right.add_theme_constant_override("separation", _px(10))
	right.custom_minimum_size.x = _px(300)
	right.alignment = BoxContainer.ALIGNMENT_END
	hb.add_child(right)
	if r["kind"] == "slider":
		var s := HSlider.new()
		var lh: Array = _lim.get(k, [float(r["min"]), float(r["max"])])
		s.min_value = float(lh[0])
		s.max_value = float(lh[1])
		s.step = float(r["step"])
		s.value = float(vals[k])
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.custom_minimum_size.y = _px(16)
		s.focus_mode = Control.FOCUS_NONE
		right.add_child(s)
		var f := LineEdit.new()
		f.custom_minimum_size.x = _px(70)
		f.alignment = HORIZONTAL_ALIGNMENT_CENTER
		f.text = _fmt(r, float(vals[k]))
		f.select_all_on_focus = true
		right.add_child(f)
		_ctl[k] = [s, f]
		s.value_changed.connect(func(v: float) -> void:
			_change(k, v, true, true)
			f.text = _fmt(r, float(vals[k])))
		var commit := func(_t: String = "") -> void:
			var t := f.text.strip_edges()
			if t == _fmt(r, float(vals[k])):
				pass  # untouched: the shown text may be rounded, the value keeps every digit of the player's config
			elif t.is_valid_float() or t.is_valid_int():
				_change(k, float(t), false)  # a typed number keeps its digits, only clamped to the range
				s.set_value_no_signal(float(vals[k]))
			f.text = _fmt(r, float(vals[k]))
			f.release_focus()
		f.text_submitted.connect(commit)
		f.focus_exited.connect(commit)
	else:
		var o := OptionButton.new()
		o.focus_mode = Control.FOCUS_NONE
		o.custom_minimum_size.x = _px(220)
		for c in String(r["choices"]).split("|"):
			o.add_item(c)
		o.select(int(vals[k]))
		right.add_child(o)
		_ctl[k] = [o, null]
		o.item_selected.connect(func(i: int) -> void:
			_change(k, i == 1 if r["kind"] == "toggle" else i))

## The value with the step's decimals, and more when the player's config has more (1.125 stays 1.125).
func _fmt(r: Dictionary, v: float) -> String:
	var st := float(r["step"])
	var dec := 0 if st >= 1.0 else 2 if st < 0.1 else 1
	var s := ("%." + str(dec) + "f") % v
	if not is_equal_approx(float(s), v):
		s = String.num(v, 4)
	return s

## Keyboard / Mouse: every input.json row with its two key slots; click a slot, then press a key (Esc cancels);
## right-click a slot to clear it. A key taken by another action moves here, like CS2.
func _binds_list(parent: Control) -> void:
	var groups := {"Movement": [], "Equipment": [], "UI": [], "Rust Surf": []}
	for r in _input_rows():
		var used := String(r["used_in"])
		groups["Rust Surf" if String(r["cs2_command"]).begins_with("(") else "Movement" if used.begins_with("SurfPlayer") else "Equipment" if used.begins_with("Weapons") or used.begins_with("Viewmodel") or used.begins_with("Inventory") else "UI"].append(r)
	for sec in groups:
		_binds_group(parent, sec, groups[sec])
	_refresh_binds()
	var reset := Button.new()
	reset.text = "RESET TO CS2 BINDS"
	reset.focus_mode = Control.FOCUS_NONE
	reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	reset.add_theme_stylebox_override("normal", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
	reset.add_theme_stylebox_override("hover", _sb(Color(1, 1, 1, 0.1), 2, Color(1, 1, 1, 0.3)))
	reset.pressed.connect(_reset_binds)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", _px(10))
	pad.add_child(reset)
	parent.add_child(pad)

func _binds_group(parent: Control, sec: String, group: Array) -> void:
	if group.is_empty():
		return
	_header(parent, sec, ["Key", "Alternate"])
	var n := 0
	for r in group:
		var label: String = r["label"]
		var hb := _line(parent, label, n)
		var cmd := Label.new()
		cmd.text = r["cs2_command"] if not String(r["cs2_command"]).begins_with("(") else ""
		cmd.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
		cmd.add_theme_font_size_override("font_size", _px(13))
		cmd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hb.add_child(cmd)
		for i in 2:
			var b := Button.new()
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size.x = _px(128)
			b.clip_text = true
			b.add_theme_stylebox_override("normal", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
			b.add_theme_stylebox_override("hover", _sb(Color(1, 1, 1, 0.1), 2, Color(1, 1, 1, 0.3)))
			b.add_theme_stylebox_override("pressed", _sb(Color(1, 1, 1, 0.16), 2, Color(1, 1, 1, 0.5)))
			if i == 1:
				b.add_theme_color_override("font_color", Color(0.75, 0.77, 0.8))
			hb.add_child(b)
			var slot := "%s:%d" % [r["id"], i]
			b.pressed.connect(func() -> void:
				_refresh_binds()
				_capture = slot
				b.text = "PRESS A KEY")
			b.gui_input.connect(func(ev: InputEvent) -> void:
				if _capture == "" and ev is InputEventMouseButton and ev.pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
					_rebind(slot, "")
					_refresh_binds())
			_bind_btns[slot] = b
		n += 1

## Crosshair tab preview: the crosshair at true screen size over sky and ground; dynamic styles breathe.
func _preview_panel(w: float) -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size.x = w
	v.add_theme_constant_override("separation", _px(6))
	var l := Label.new()
	l.text = "Preview"
	l.add_theme_font_size_override("font_size", _px(18))
	l.add_theme_color_override("font_color", Color.WHITE)
	_bold(l)
	v.add_child(l)
	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(w, w * 0.8)
	_preview.clip_contents = true
	_preview.draw.connect(_draw_preview.bind(_preview))  # bound: an old preview freed by a resize draws itself only
	v.add_child(_preview)
	var note := Label.new()
	note.text = "Dynamic styles open and close as if moving and firing."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", _px(12))
	note.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	note.custom_minimum_size.x = w
	v.add_child(note)
	return v

func _draw_preview(pv: Control) -> void:
	var sz := pv.size
	var sky := [Color(0.52, 0.62, 0.72), Color(0.74, 0.78, 0.8)]
	pv.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(sz.x, 0), Vector2(sz.x, sz.y * 0.55), Vector2(0, sz.y * 0.55)]),
		PackedColorArray([sky[0], sky[0], sky[1], sky[1]]))
	pv.draw_rect(Rect2(0, sz.y * 0.55, sz.x, sz.y * 0.45), Color(0.27, 0.25, 0.22))
	pv.draw_rect(Rect2(sz.x * 0.62, sz.y * 0.3, sz.x * 0.38, sz.y * 0.25), Color(0.36, 0.35, 0.33))
	pv.draw_rect(Rect2(sz.x * 0.53, sz.y * 0.36, sz.x * 0.07, sz.y * 0.19), Color(0.08, 0.08, 0.08))  # a dark doorway: the right arm on dark
	pv.draw_rect(Rect2(Vector2.ZERO, sz), Color(1, 1, 1, 0.15), false, 1.0)
	var h := get_viewport().get_visible_rect().size.y
	var t := Time.get_ticks_msec() / 1000.0
	var k := 0.5 - 0.5 * cos(t * 1.7)
	var hud: Hud = main.hud
	var spread := hud.spread_to_px(0.006 + 0.05 * k, h)
	pv.draw_set_transform((sz * 0.5).floor())
	Hud.draw_xh(pv, hud.convars, h, hud.H, spread, hud.spread_to_px(0.02 * k, h), hud._wgap)
	pv.draw_set_transform(Vector2.ZERO)

func _process(_dt: float) -> void:
	if is_open and _tab == "crosshair" and _preview:
		_preview.queue_redraw()

# --- --uitest: asserted checks of the menu and the HUD; exits 1 on any failure ---

func _uitest() -> void:
	FILE = "user://settings_uitest.json"
	var fails: Array = []
	var ok := func(cond: bool, what: String) -> void:
		print("UITEST %s %s" % ["PASS" if cond else "FAIL", what])
		if not cond:
			fails.append(what)
	# a CS2 value keeps its digits: no step rounding, no clamp, shown as written
	var sr: Dictionary = rows["sensitivity"]
	main.player.input.sensitivity = 1.125
	ok.call(is_equal_approx(float(_initial(sr)), 1.125) and _fmt(sr, 1.125) == "1.125", "sensitivity 1.125 stays 1.125 (%s)" % _fmt(sr, float(_initial(sr))))
	main.hud.convars["fps_max"] = "999"
	ok.call(int(_initial(rows["fps_max"])) == 999, "fps_max 999 is not clamped")
	main.hud.convars.erase("fps_max")
	ok.call(is_equal_approx(float(_fit(sr, 1.125, false)), 1.125) and is_equal_approx(float(_fit(sr, 1.125)), 1.13), "typed value keeps digits, slider snaps")
	# a rebind moves the key: MOUSE1 on reload leaves attack
	_rebind("reload:0", "MOUSE1")
	var has := func(action: String, b: MouseButton) -> bool:
		for ev in InputMap.action_get_events(action):
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == b:
				return true
		return false
	ok.call(has.call("surf_reload", MOUSE_BUTTON_LEFT) and not has.call("surf_attack", MOUSE_BUTTON_LEFT) and not (_keys["attack"] as Array).has("MOUSE1"), "MOUSE1 moved from attack to reload")
	_rebind("jump:1", "MWHEELDOWN")
	ok.call(has.call("surf_jump", MOUSE_BUTTON_WHEEL_DOWN) and InputMap.action_get_events("surf_jump").size() == 2, "jump holds two keys")
	# a key already in the action's other slot swaps places: [A, B] with slot 0 set to B is [B, A], no key lost
	var jk: Array = (_keys["jump"] as Array).duplicate()
	_rebind("jump:0", String(jk[1]))
	ok.call(_keys["jump"] == [jk[1], jk[0]], "rebinding a slot to the other slot's key swaps them (%s -> %s)" % [jk, _keys["jump"]])
	# the file is written whole (temp + rename) and reads back
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(FILE))
	ok.call(d is Dictionary and d["keys"].has("reload") and d["keys"].has("attack") and not FileAccess.file_exists(FILE + ".tmp"), "settings file saved atomically with the moved keys")
	_reset_binds()
	ok.call(has.call("surf_attack", MOUSE_BUTTON_LEFT) and not has.call("surf_reload", MOUSE_BUTTON_LEFT), "reset puts MOUSE1 back on attack")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))
	# an unreadable file is set aside as .bad (never overwritten); a lone .tmp left by a cut-off save is read back
	var gp := func(p: String) -> String: return ProjectSettings.globalize_path(p)
	DirAccess.remove_absolute(gp.call(FILE + ".bad"))
	var bf := FileAccess.open(FILE, FileAccess.WRITE)
	bf.store_string("{ not json")
	bf.close()
	_load()
	ok.call(FileAccess.file_exists(FILE + ".bad") and not FileAccess.file_exists(FILE) and not _no_save, "unreadable settings file kept as .bad")
	_change("volume", 0.5)
	ok.call(FileAccess.get_file_as_string(FILE + ".bad") == "{ not json" and FileAccess.file_exists(FILE), "the .bad copy survives the next save")
	DirAccess.remove_absolute(gp.call(FILE))
	bf = FileAccess.open(FILE + ".tmp", FileAccess.WRITE)
	bf.store_string(JSON.stringify({"values": {"sensitivity": 3.25}, "keys": {}}))
	bf.close()
	_changed.clear()
	_load()
	ok.call(is_equal_approx(float(vals["sensitivity"]), 3.25), "a lone settings.json.tmp is read back")
	# a torn settings.json beside a whole .tmp: the .tmp (the newest whole write) wins and nothing is lost
	bf = FileAccess.open(FILE, FileAccess.WRITE)
	bf.store_string("{ \"values\": {")
	bf.close()
	bf = FileAccess.open(FILE + ".tmp", FileAccess.WRITE)
	bf.store_string(JSON.stringify({"values": {"sensitivity": 4.5}, "keys": {}}))
	bf.close()
	_changed.clear()
	_load()
	ok.call(is_equal_approx(float(vals["sensitivity"]), 4.5), "a whole .tmp wins over a torn settings.json")
	bf = FileAccess.open(FILE, FileAccess.WRITE)
	bf.store_string(JSON.stringify({"values": {"sensitivity": 1.5}, "keys": {}}))
	bf.close()
	_changed.clear()
	_load()
	ok.call(is_equal_approx(float(vals["sensitivity"]), 4.5), "a whole .tmp (rename failed) wins over the older settings.json")
	for p in [FILE, FILE + ".tmp", FILE + ".bad"]:
		DirAccess.remove_absolute(gp.call(p))
	# a CS2 value past the slider range stays the player's: 0.05 sensitivity is neither clamped on load nor on a nudge
	var sens0: float = main.player.input.sensitivity
	main.player.input.sensitivity = 0.05
	_changed.clear()
	_load()
	_change("sensitivity", 0.05, false)
	ok.call(is_equal_approx(float(vals["sensitivity"]), 0.05) and is_equal_approx(float(_fit(sr, 0.04, false)), 0.05), "CS2 sensitivity 0.05 kept (range widened to it, not past it)")
	main.player.input.sensitivity = sens0
	_changed.clear()
	_load()
	# a slider drag writes the file once after it settles, not once per value_changed
	_rebuild()
	var n0 := saves
	var sl: HSlider = _ctl["volume"][0]
	for i in 20:
		sl.value = 0.2 + i * 0.01
	var during := saves - n0
	_flush()
	ok.call(during == 0 and saves - n0 == 1 and is_equal_approx(float(vals["volume"]), 0.39), "a 20-step volume drag saves once (%d during, %d after)" % [during, saves - n0])
	for p in [FILE, FILE + ".tmp", FILE + ".bad"]:
		DirAccess.remove_absolute(gp.call(p))
	_changed.clear()
	_load()
	_apply("volume")
	# zoom_sensitivity_ratio: the player's convar unrounded, and a change reaches Weapons
	main.hud.convars["zoom_sensitivity_ratio"] = "0.818933"
	ok.call(is_equal_approx(float(_initial(rows["zoom_sensitivity_ratio"])), 0.818933), "zoom_sensitivity_ratio 0.818933 from the convar")
	main.hud.convars.erase("zoom_sensitivity_ratio")
	_change("zoom_sensitivity_ratio", 0.818933, false)
	ok.call(is_equal_approx(float(main.weapons.X["zoom_sensitivity_ratio"]), 0.818933), "zoom_sensitivity_ratio reaches Weapons")
	for p in [FILE, FILE + ".tmp", FILE + ".bad"]:
		DirAccess.remove_absolute(gp.call(p))
	# leaving a number field untouched never rewrites the player's unrounded value
	_changed.erase("sensitivity")
	vals["sensitivity"] = 1.818181
	_rebuild()
	var fld: LineEdit = _ctl["sensitivity"][1]
	fld.focus_exited.emit()
	ok.call(is_equal_approx(float(vals["sensitivity"]), 1.818181) and not _changed.has("sensitivity"), "an untouched sensitivity field keeps 1.818181 (shows %s)" % fld.text)
	fld.text = "2.5"
	fld.text_submitted.emit("2.5")
	ok.call(is_equal_approx(float(vals["sensitivity"]), 2.5), "a typed sensitivity is taken")
	# closing the menu gives back the frozen state it found (a capture pose keeps the player frozen)
	main.player.frozen = true
	toggle()
	toggle()
	ok.call(main.player.frozen, "closing the menu keeps a player frozen by something else frozen")
	main.player.frozen = false
	toggle()
	toggle()
	ok.call(not main.player.frozen, "closing the menu unfreezes a player it froze")
	for p in [FILE, FILE + ".tmp", FILE + ".bad"]:
		DirAccess.remove_absolute(gp.call(p))
	# a repeated message is not cut short by the first one's timer
	main.hud.message("uitest", 0.05)
	main.hud.message("uitest", 5.0)
	await get_tree().create_timer(0.2).timeout
	ok.call(main.hud.msg_label.text == "uitest", "a repeated message keeps its own time")
	main.hud.message("", 0.0)
	# no crosshair on an unscoped sniper, the usual one on a rifle
	var w: Node = main.weapons
	var was: Array = [w.current, w.slots["primary"]]
	w.current = "primary"
	w.slots["primary"] = "cs2_awp"
	var awp: bool = main.hud._no_xh()
	w.slots["primary"] = "cs2_ak47"
	ok.call(awp and not main.hud._no_xh(), "AWP unscoped draws no crosshair, AK does")
	w.current = was[0]
	w.slots["primary"] = was[1]
	# crosshair pixels: thickness truncates (0.7 at 1080p is 1 px), presets are the 250/50 colours
	var hv: Dictionary = main.hud.H
	ok.call(float(Hud.xh_px({"cl_crosshairthickness": "0.7"}, 1080, hv)["thickness"]) == 1.0, "thickness 0.7 at 1080p draws 1 px")
	ok.call(float(Hud.xh_px({"cl_crosshairthickness": "1"}, 1080, hv)["thickness"]) == 2.0, "thickness 1 at 1080p draws 2 px")
	ok.call(Hud.xh_color({"cl_crosshaircolor": "1", "cl_crosshairusealpha": "0"}, hv).is_equal_approx(Color8(50, 250, 50)), "colour 1 is 50,250,50")
	# styles 0/1 keep hud.json's fixed Default shape; cl_crosshairgap_useweaponvalue swaps gap_base for the gun's
	var big := {"cl_crosshairsize": "10", "cl_crosshairthickness": "3", "cl_crosshairgap": "-3"}
	var d0 := big.duplicate()
	d0["cl_crosshairstyle"] = "0"
	var d4 := big.duplicate()
	d4["cl_crosshairstyle"] = "4"
	var m0: Dictionary = Hud.xh_px(d0, 1080, hv)
	ok.call(m0["size"] == roundf(float(hv["default_xh_size"]) * 1080 / float(hv["yres_base"])) and m0["size"] != Hud.xh_px(d4, 1080, hv)["size"], "style 0 ignores cl_crosshairsize (%s px), style 4 follows it" % m0["size"])
	var g4: float = Hud.xh_px(d4, 1080, hv)["gap"]
	var gw: float = Hud.xh_px(d4, 1080, hv, float(hv["gap_base"]) + 6.0)["gap"]
	ok.call(gw > g4, "a weapon gap widens the static gap (%s -> %s px)" % [g4, gw])
	ok.call(Hud.xh_color({"cl_crosshaircolor": "5", "cl_crosshaircolor_r": "10", "cl_crosshaircolor_g": "20", "cl_crosshaircolor_b": "30", "cl_crosshairalpha": "128"}, hv).is_equal_approx(Color8(10, 20, 30, 128)), "colour 5 is the custom RGB with alpha")
	# no hit marker unless the player turns it on
	main.hud.hitmarker(false)
	ok.call(main.hud._hit == 0.0, "hit marker off by default")
	main.hud.hit_marker = true
	main.hud.hitmarker(false)
	ok.call(main.hud._hit > 0.0, "hit marker shows when turned on")
	ok.call(main.hud.hit_ctl.visible and main.hud.hit_ctl.get_parent() != main.hud.crosshair, "hit marker draws apart from the crosshair (shown on snipers too)")
	await get_tree().process_frame
	ok.call(main.hud.hit_ctl.position == main.hud.crosshair.position, "hit marker sits on the crosshair (cl_crosshair_recoil moves both)")
	main.hud.hit_marker = false
	main.hud._hit = 0.0
	# no bare 0 at rest; the dynamic gap follows the live camera fov
	main.hud.update(0.0, 0.0, 0.0, false)
	ok.call(main.hud.speed_label.text == "", "speed readout empty at rest")
	main.hud.update(250.0, 0.0, 0.0, false)
	ok.call(main.hud.speed_label.text == "250", "speed readout shows 250")
	var cam := get_viewport().get_camera_3d()
	var fov0 := cam.fov
	var px0: float = main.hud.spread_to_px(0.01, 1080)
	cam.fov = fov0 * 0.5
	var px1: float = main.hud.spread_to_px(0.01, 1080)
	cam.fov = fov0
	ok.call(px1 > px0 * 1.9, "dynamic gap widens when the fov narrows (%.1f -> %.1f px)" % [px0, px1])
	ok.call(absf(px0 - 0.01 * 540.0 / tan(deg_to_rad(fov0) * 0.5)) < 0.01, "spread px is the camera projection (%.2f px)" % px0)
	# every tab at 960x540 and 1920x1080: nothing past the window edge, the HUD hidden under the menu
	for res in [Vector2i(960, 540), Vector2i(1920, 1080)]:
		get_window().size = res
		await get_tree().process_frame
		_rebuild()
		if not is_open:
			toggle()
		for t in TABS:
			_show_tab(String(t[0]))
			for i in 3:
				await get_tree().process_frame
			var vp := get_viewport().get_visible_rect()
			var bad := _outside(_root, vp)
			ok.call(bad == "", "%dx%d %s tab inside the window %s" % [vp.size.x, vp.size.y, t[0], bad])
		ok.call(not main.hud.visible, "HUD hidden while the menu is open")
	if is_open:
		toggle()
	print("UITEST %s" % ("ok" if fails.is_empty() else "FAILED %d" % fails.size()))
	get_tree().quit(0 if fails.is_empty() else 1)

## The first visible control (outside a scroll list) that runs past the window or is squeezed under its minimum size.
func _outside(n: Node, vp: Rect2, in_scroll: bool = false) -> String:
	for c in n.get_children():
		if not (c is Control) or not (c as Control).is_visible_in_tree():
			continue
		var cc := c as Control
		var r := cc.get_global_rect()
		if not in_scroll and (r.position.x < vp.position.x - 1 or r.end.x > vp.end.x + 1 or r.position.y < -1 or r.end.y > vp.end.y + 1):
			return "%s %s" % [cc.get_class(), r]
		if r.end.x > vp.end.x + 1:
			return "%s %s past right edge" % [cc.get_class(), r]
		if cc is Label and (cc as Label).clip_text and (cc as Label).get_theme_font("font").get_string_size((cc as Label).text, HORIZONTAL_ALIGNMENT_LEFT, -1, (cc as Label).get_theme_font_size("font_size")).x > r.size.x + 1:
			return "label '%s' clipped" % (cc as Label).text
		var sub := _outside(cc, vp, in_scroll or cc is ScrollContainer)
		if sub != "":
			return sub
	return ""

