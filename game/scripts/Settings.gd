## systems.settings: the Esc menu laid out like CS2's settings: a tab bar (Game, Keyboard / Mouse, Audio, Video,
## Crosshair) over the blurred game, settings.json rows as slider + number field or dropdown, the input.json binds,
## and a live crosshair preview. Values start from the player's CS2 convars; only changes go to user://settings.json.
class_name Settings
extends CanvasLayer

const FILE := "user://settings.json"
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
void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * 6.0;
	vec3 c = vec3(0.0);
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			c += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, 3.0).rgb;
		}
	}
	COLOR = vec4(mix(c / 25.0, vec3(0.035, 0.04, 0.05), 0.55), 1.0);
}"""

var main: Node
var is_open := false
var vals := {}
var rows := {}           # id -> settings.json row
var _changed := {}
var _binds := {}         # input.json id -> key the player bound here
var _root: Control
var _tab := "game"
var _pages := {}
var _tab_btns := {}
var _ctl := {}           # id -> [slider or option, number field or null]
var _bind_btns := {}     # input.json id -> Button
var _capture := ""       # input.json id waiting for a key
var _capture_frame := -1
var _preview: Control
var _u := 1.0
var _loading := true

func setup(m: Node) -> void:
	main = m
	layer = 50
	for r in Sheets.load_sheet("settings")["rows"]:
		rows[r["id"]] = r
	_load()
	for id in _binds:
		_bind(id, _binds[id])
	_build()
	for k in vals:
		if (k == "display_mode" or k == "vsync") and not _changed.has(k):
			continue  # the window follows project.godot until the player picks otherwise
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

func toggle() -> void:
	if _capture != "" or Engine.get_process_frames() == _capture_frame:
		return  # Esc while binding a key cancels the bind, not the menu
	is_open = not is_open
	_root.visible = is_open
	_show_tab(_tab)
	main.hud.visible = not is_open  # the menu covers the game; the HUD never draws over it
	if is_open and main.weapons._buy.visible:
		main.weapons._buy.visible = false  # one menu at a time
	main.player.frozen = is_open  # the menu pauses movement like a paused local server
	if main.timer: main.timer.set_process(not is_open)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if is_open else Input.MOUSE_MODE_CAPTURED

# --- values ---

func _is_convar(r: Dictionary) -> bool:
	var c: String = r["convar"]
	return not c.contains(" ") and not c.begins_with("(")

## Start value: the player's CS2 convar, else the live system value, else the sheet default.
func _initial(r: Dictionary) -> Variant:
	var id: String = r["id"]
	var cv: Dictionary = main.hud.convars
	var kind: String = r["kind"]
	var v: Variant = r["default"]
	match id:
		"sensitivity": v = main.player.input.sensitivity
		"invert_mouse": v = main.player.input.m_pitch < 0.0
		"display_mode": v = 1 if DisplayServer.window_get_mode() >= DisplayServer.WINDOW_MODE_FULLSCREEN else 0
		"vsync": v = 0 if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED else 1
		"msaa": v = clampi(get_viewport().msaa_3d, 0, 3)
		_:
			if id.begins_with("viewmodel_") and main.viewmodel.V.has(id):
				v = main.viewmodel.V[id]
			elif _is_convar(r) and cv.has(r["convar"]):
				v = Hud.on(cv, r["convar"], "0") if kind == "toggle" else Hud.num(cv, r["convar"], float(r["default"]))
	return _fit(r, v)

## The value as the menu holds it: sliders clamped and snapped to their step, toggles bool, choices an index.
func _fit(r: Dictionary, v: Variant) -> Variant:
	match String(r["kind"]):
		"toggle":
			return v if v is bool else float(v) > 0.5
		"choice":
			return clampi(int(v), 0, String(r["choices"]).split("|").size() - 1)
		"slider":
			var st := float(r["step"])
			var f := clampf(float(v), float(r["min"]), float(r["max"]))
			return snappedf(f, st) if st > 0.0 else f
	return v

func _load() -> void:
	for id in rows:
		if rows[id]["kind"] != "binds":
			vals[id] = _initial(rows[id])
	if not FileAccess.file_exists(FILE):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(FILE))
	if not (d is Dictionary):
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
			vals[k] = _fit(rows[k], saved[k])
			_changed[k] = true
	if d.get("binds") is Dictionary:
		for k in d["binds"]:
			if d["binds"][k] is String:
				_binds[k] = d["binds"][k]

func _save() -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f == null:
		main.hud.message("could not save settings: %s" % error_string(FileAccess.get_open_error()), 3.0)
		return
	var out := {}
	for k in _changed:  # only what the player changed here, so the rest keeps following their CS2 config
		out[k] = vals[k]
	f.store_string(JSON.stringify({"values": out, "binds": _binds}, "\t"))

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
		"sensitivity": main.player.input.sensitivity = v
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
		"fps_max": Engine.max_fps = int(v)
		"msaa": get_viewport().msaa_3d = int(v) as Viewport.MSAA

## sounds.json players at their row level times v (0 is silent).
func _channel(ids: Array, v: float) -> void:
	if main.sounds == null:
		return
	for id in ids:
		var p: AudioStreamPlayer = main.sounds.players.get(id)
		if p:
			p.volume_db = float(main.sounds.rows[id]["volume_db"]) + linear_to_db(maxf(v, 0.0001))

func _change(k: String, v: Variant) -> void:
	v = _fit(rows[k], v)
	if vals[k] == v and _changed.has(k):
		return
	vals[k] = v
	_apply(k)
	if not _loading:
		_changed[k] = true
		_save()

# --- binds ---

func _input_rows() -> Array:
	return Sheets.load_sheet("input")["rows"]

func _key_of(r: Dictionary) -> String:
	if _binds.has(r["id"]):
		return _binds[r["id"]]
	return main.sinput.binds.get(r["cs2_command"], r["default_key"])

func _bind(id: String, key: String) -> void:
	for r in _input_rows():
		if r["id"] == id:
			main.sinput._register(r["godot_action"], key)

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
	return OS.get_keycode_string(kc).to_lower()

func _input(ev: InputEvent) -> void:
	if _capture == "" or not ev.is_pressed() or ev.is_echo():
		return
	if not (ev is InputEventKey or ev is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	var id := _capture
	_capture = ""
	_capture_frame = Engine.get_process_frames()
	if ev is InputEventKey and (ev as InputEventKey).keycode == KEY_ESCAPE:
		_refresh_binds()
		return
	var key := _key_name(ev)
	if key != "":
		_binds[id] = key
		_bind(id, key)
		_save()
	_refresh_binds()

func _refresh_binds() -> void:
	for r in _input_rows():
		if _bind_btns.has(r["id"]):
			(_bind_btns[r["id"]] as Button).text = _key_of(r).to_upper()

func _reset_binds() -> void:
	_binds.clear()
	for r in _input_rows():
		main.sinput._register(r["godot_action"], main.sinput.binds.get(r["cs2_command"], r["default_key"]))
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
	if main.hud.font:
		t.default_font = main.hud.font
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
	t.set_stylebox("panel", "PopupMenu", _sb(Color(0.09, 0.1, 0.11, 0.98), 2, Color(1, 1, 1, 0.15)))
	t.set_stylebox("hover", "PopupMenu", _sb(Color(1, 1, 1, 0.12)))
	t.set_stylebox("normal", "LineEdit", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
	t.set_stylebox("focus", "LineEdit", _sb(Color(0, 0, 0, 0.5), 2, Color(1, 1, 1, 0.45)))
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
	blur.material = mat
	_root.add_child(blur)
	# top bar: tabs left, run actions right
	var bar_h := _px(52)
	var bar := Panel.new()
	bar.add_theme_stylebox_override("panel", _sb(Color(0.02, 0.025, 0.03, 0.75), 0))
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = bar_h
	_root.add_child(bar)
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.08)
	line.set_anchors_preset(Control.PRESET_TOP_WIDE)
	line.offset_top = bar_h
	line.offset_bottom = bar_h + 1
	_root.add_child(line)
	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = _px(18)
	hb.offset_right = -_px(18)
	hb.add_theme_constant_override("separation", _px(4))
	bar.add_child(hb)
	var group := ButtonGroup.new()
	for t in TABS:
		var b := _flat_button(hb, String(t[1]).to_upper(), bar_h)
		b.toggle_mode = true
		b.button_group = group
		var tid: String = t[0]
		b.pressed.connect(func() -> void: _show_tab(tid))
		_tab_btns[tid] = b
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sp)
	_flat_button(hb, "RESUME", bar_h).pressed.connect(toggle)
	_flat_button(hb, "AIM LOBBY", bar_h).pressed.connect(func() -> void:
		toggle()
		main.lobby.toggle())
	_flat_button(hb, "RESTART RUN", bar_h).pressed.connect(func() -> void:
		toggle()
		if main.lobby.active:
			main.lobby.toggle()  # leaving the lobby already puts you back on the start pad
		else:
			main.course.restart(main.player)
			main.timer.reset())
	_flat_button(hb, "QUIT", bar_h).pressed.connect(func() -> void: get_tree().quit())
	# pages: one centred column under the bar
	var w := minf(float(main.hud.H["menu_width"]) * _u, vp.x - _px(32))
	var area := Control.new()
	area.anchor_left = 0.5
	area.anchor_right = 0.5
	area.anchor_bottom = 1.0
	area.offset_left = -w * 0.5
	area.offset_right = w * 0.5
	area.offset_top = bar_h + _px(22)
	area.offset_bottom = -_px(22)
	_root.add_child(area)
	for t in TABS:
		var page := _page(String(t[0]), w)
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.visible = false
		area.add_child(page)
		_pages[t[0]] = page

func _flat_button(parent: Control, text: String, h: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = h
	b.add_theme_font_size_override("font_size", _px(15))
	b.add_theme_color_override("font_color", DIM)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	var pad := func(c: Color, under: bool) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = c
		s.content_margin_left = _px(12)
		s.content_margin_right = _px(12)
		if under:
			s.border_color = Color.WHITE
			s.border_width_bottom = _px(3)
		return s
	b.add_theme_stylebox_override("normal", pad.call(Color(0, 0, 0, 0), false))
	b.add_theme_stylebox_override("hover", pad.call(Color(1, 1, 1, 0.07), false))
	b.add_theme_stylebox_override("pressed", pad.call(Color(1, 1, 1, 0.05), true))
	b.add_theme_stylebox_override("hover_pressed", pad.call(Color(1, 1, 1, 0.09), true))
	parent.add_child(b)
	return b

func _show_tab(t: String) -> void:
	if not _pages.has(t):
		t = "game"
	_tab = t
	for k in _pages:
		_pages[k].visible = k == t
	(_tab_btns[t] as Button).set_pressed_no_signal(true)

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
	var section := ""
	var n := 0
	for id in rows:
		var r: Dictionary = rows[id]
		if r["tab"] != tab:
			continue
		if r["section"] != section:
			section = r["section"]
			_header(list, section)
			n = 0
		if r["kind"] == "binds":
			_binds_list(list)
		else:
			_row(list, r, n)
		n += 1
	return host

func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", _px(13))
	l.add_theme_color_override("font_color", DIM)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", _px(14) if parent.get_child_count() > 0 else 0)
	pad.add_theme_constant_override("margin_bottom", _px(6))
	pad.add_theme_constant_override("margin_left", _px(12))
	pad.add_child(l)
	parent.add_child(pad)

## One settings line: label left, control right, alternating shade like CS2's lists.
func _line(parent: Control, label: String, n: int) -> HBoxContainer:
	var pc := PanelContainer.new()
	var s := _sb(Color(1, 1, 1, 0.045) if n % 2 == 0 else Color(0, 0, 0, 0.18), 0)
	s.content_margin_left = _px(12)
	s.content_margin_right = _px(12)
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
	l.add_theme_color_override("font_color", Color(0.8, 0.82, 0.85))
	l.clip_text = true
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
		s.min_value = float(r["min"])
		s.max_value = float(r["max"])
		s.step = float(r["step"])
		s.value = float(vals[k])
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.custom_minimum_size.y = _px(16)
		s.focus_mode = Control.FOCUS_NONE
		right.add_child(s)
		var f := LineEdit.new()
		f.custom_minimum_size.x = _px(66)
		f.alignment = HORIZONTAL_ALIGNMENT_CENTER
		f.text = _fmt(r, float(vals[k]))
		f.select_all_on_focus = true
		right.add_child(f)
		_ctl[k] = [s, f]
		s.value_changed.connect(func(v: float) -> void:
			f.text = _fmt(r, v)
			_change(k, v))
		var commit := func(_t: String = "") -> void:
			var t := f.text.strip_edges()
			if t.is_valid_float() or t.is_valid_int():
				s.value = float(_fit(r, float(t)))  # clamped and snapped, then value_changed applies it
			f.text = _fmt(r, float(vals[k]))
			f.release_focus()
		f.text_submitted.connect(commit)
		f.focus_exited.connect(commit)
	else:
		var o := OptionButton.new()
		o.focus_mode = Control.FOCUS_NONE
		o.custom_minimum_size.x = _px(200)
		for c in String(r["choices"]).split("|"):
			o.add_item(c)
		o.select(int(vals[k]))
		right.add_child(o)
		_ctl[k] = [o, null]
		o.item_selected.connect(func(i: int) -> void:
			_change(k, i == 1 if r["kind"] == "toggle" else i))

func _fmt(r: Dictionary, v: float) -> String:
	var st := float(r["step"])
	return "%d" % int(round(v)) if st >= 1.0 else "%.2f" % v if st < 0.1 else "%.1f" % v

## Keyboard / Mouse: every input.json row with the key it is bound to; click, then press a key to rebind.
func _binds_list(parent: Control) -> void:
	var n := 0
	for r in _input_rows():
		var label := String(r["id"]).replace("_", " ").capitalize()
		var hb := _line(parent, label, n)
		var cmd := Label.new()
		cmd.text = r["cs2_command"] if not String(r["cs2_command"]).begins_with("(") else "mashup"
		cmd.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
		cmd.add_theme_font_size_override("font_size", _px(13))
		cmd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hb.add_child(cmd)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = _px(150)
		b.text = _key_of(r).to_upper()
		b.add_theme_stylebox_override("normal", _sb(Color(0, 0, 0, 0.35), 2, Color(1, 1, 1, 0.12)))
		b.add_theme_stylebox_override("hover", _sb(Color(1, 1, 1, 0.1), 2, Color(1, 1, 1, 0.3)))
		b.add_theme_stylebox_override("pressed", _sb(Color(1, 1, 1, 0.16), 2, Color(1, 1, 1, 0.5)))
		hb.add_child(b)
		var rid: String = r["id"]
		b.pressed.connect(func() -> void:
			_refresh_binds()
			_capture = rid
			b.text = "PRESS A KEY")
		_bind_btns[rid] = b
		n += 1
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

## Crosshair tab preview: the crosshair at true screen size over light and dark ground; dynamic styles breathe.
func _preview_panel(w: float) -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size.x = w
	v.add_theme_constant_override("separation", _px(6))
	var l := Label.new()
	l.text = "PREVIEW"
	l.add_theme_font_size_override("font_size", _px(13))
	l.add_theme_color_override("font_color", DIM)
	v.add_child(l)
	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(w, w * 0.8)
	_preview.clip_contents = true
	_preview.draw.connect(_draw_preview)
	v.add_child(_preview)
	var note := Label.new()
	note.text = "Dynamic styles open and close as if moving and firing."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", _px(12))
	note.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	note.custom_minimum_size.x = w
	v.add_child(note)
	return v

func _draw_preview() -> void:
	var sz := _preview.size
	var sky := [Color(0.52, 0.62, 0.72), Color(0.74, 0.78, 0.8)]
	_preview.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(sz.x, 0), Vector2(sz.x, sz.y * 0.55), Vector2(0, sz.y * 0.55)]),
		PackedColorArray([sky[0], sky[0], sky[1], sky[1]]))
	_preview.draw_rect(Rect2(0, sz.y * 0.55, sz.x, sz.y * 0.45), Color(0.27, 0.25, 0.22))
	_preview.draw_rect(Rect2(sz.x * 0.62, sz.y * 0.3, sz.x * 0.38, sz.y * 0.25), Color(0.36, 0.35, 0.33))
	_preview.draw_rect(Rect2(Vector2.ZERO, sz), Color(1, 1, 1, 0.15), false, 1.0)
	var h := get_viewport().get_visible_rect().size.y
	var t := Time.get_ticks_msec() / 1000.0
	var k := 0.5 - 0.5 * cos(t * 1.7)
	var hud: Hud = main.hud
	var spread := hud.spread_to_px(0.006 + 0.05 * k, h)
	_preview.draw_set_transform((sz * 0.5).floor())
	Hud.draw_xh(_preview, hud.convars, h, hud.H, spread, hud.spread_to_px(0.02 * k, h))
	_preview.draw_set_transform(Vector2.ZERO)

func _process(_dt: float) -> void:
	if is_open and _tab == "crosshair" and _preview:
		_preview.queue_redraw()
