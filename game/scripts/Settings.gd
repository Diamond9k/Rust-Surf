## systems.settings: the Esc menu: resume / aim lobby / restart / quit, sliders saved to user://settings.json.
class_name Settings
extends CanvasLayer

const FILE := "user://settings.json"
const ACCENT := Color(0.878, 0.643, 0.227)
# key -> [label, min, max, step, section]
const ROWS := [
	["sens", "Sensitivity", 0.1, 10.0, 0.01, "Mouse"],
	["fov", "Field of view", 70.0, 110.0, 1.0, "Video"],
	["vm_fov", "Viewmodel FOV", 54.0, 68.0, 1.0, "Viewmodel"],
	["vm_x", "Offset X", -2.5, 2.5, 0.1, "Viewmodel"],
	["vm_y", "Offset Y", -2.0, 2.0, 0.1, "Viewmodel"],
	["vm_z", "Offset Z", -2.0, 2.0, 0.1, "Viewmodel"],
	["volume", "Master volume", 0.0, 100.0, 1.0, "Audio"],
	["xh_size", "Size", 0.0, 10.0, 0.5, "Crosshair"],
	["xh_gap", "Gap", -5.0, 10.0, 0.5, "Crosshair"],
	["xh_thick", "Thickness", 0.0, 5.0, 0.1, "Crosshair"],
	["xh_color", "Color (0-5)", 0.0, 5.0, 1.0, "Crosshair"],
]

var main: Node
var is_open := false
var vals := {}
var _sliders := {}
var _readouts := {}
var _checks := {}
var _root: Control
var _loading := true
var _changed := {}

func setup(m: Node) -> void:
	main = m
	layer = 50
	_load_defaults()
	_build()
	for k in vals:
		_apply(k)
	_loading = false
	_root.visible = false
	if OS.get_cmdline_user_args().has("--menu"):
		toggle()

func toggle() -> void:
	is_open = not is_open
	_root.visible = is_open
	main.hud.msg_label.visible = not is_open
	if is_open and main.weapons._buy.visible:
		main.weapons._buy.visible = false  # one menu at a time
	main.player.frozen = is_open  # the menu pauses movement like a paused local server
	if main.timer: main.timer.set_process(not is_open)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if is_open else Input.MOUSE_MODE_CAPTURED

func _load_defaults() -> void:
	var h: Hud = main.hud
	var V: Dictionary = main.viewmodel.V
	vals = {
		"sens": main.player.input.sensitivity, "fov": float(Sheets.movement()["fov_default"]),
		"vm_fov": V.get("viewmodel_fov", 68.0), "vm_x": V.get("viewmodel_offset_x", 0.0),
		"vm_y": V.get("viewmodel_offset_y", 0.0), "vm_z": V.get("viewmodel_offset_z", 0.0),
		"volume": 100.0,
		"xh_size": float(h.convars.get("cl_crosshairsize", "5")), "xh_gap": float(h.convars.get("cl_crosshairgap", "1")),
		"xh_thick": float(h.convars.get("cl_crosshairthickness", "0.5")), "xh_color": float(h.convars.get("cl_crosshaircolor", "1")),
		"xh_dot": str(h.convars.get("cl_crosshairdot", "false")).to_lower() in ["true", "1"], "speed": true,
	}
	if FileAccess.file_exists(FILE):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if d is Dictionary:
			for k in vals:
				if d.has(k) and typeof(d[k]) == typeof(vals[k]):
					vals[k] = d[k]
					_changed[k] = true

func _save() -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f:
		# only what the player changed here, so the rest keeps following their CS2 config
		var out := {}
		for k in _changed:
			out[k] = vals[k]
		f.store_string(JSON.stringify(out))

func _apply(k: String) -> void:
	var v: Variant = vals[k]
	var h: Hud = main.hud
	match k:
		"sens": main.player.input.sensitivity = v
		"fov":
			main.player.cam.fov = Sheets.vfov_43(v)
			main.viewmodel.set_view({"world_fov": v})
		"vm_fov": main.viewmodel.set_view({"viewmodel_fov": v})
		"vm_x": main.viewmodel.set_view({"viewmodel_offset_x": v})
		"vm_y": main.viewmodel.set_view({"viewmodel_offset_y": v})
		"vm_z": main.viewmodel.set_view({"viewmodel_offset_z": v})
		"volume": AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v / 100.0, 0.0001)))
		"xh_size": h.convars["cl_crosshairsize"] = str(v)
		"xh_gap": h.convars["cl_crosshairgap"] = str(v)
		"xh_thick": h.convars["cl_crosshairthickness"] = str(v)
		"xh_color": h.convars["cl_crosshaircolor"] = str(int(v))
		"xh_dot": h.convars["cl_crosshairdot"] = "true" if v else "false"
		"speed": h.set_speed_visible(v)
	if k.begins_with("xh_") and h.crosshair:
		h.crosshair.queue_redraw()

func _change(k: String, v: Variant) -> void:
	vals[k] = v
	_apply(k)
	if not _loading:
		_changed[k] = true
		_save()

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var theme := Theme.new()
	if main.hud.font:
		theme.default_font = main.hud.font
	theme.default_font_size = 16
	_root.theme = theme
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.45)
	_root.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -330
	panel.offset_right = 330
	panel.offset_top = -250
	panel.offset_bottom = 250
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.106, 0.114, 0.125, 0.9)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 22)
	panel.add_child(hb)
	var btns := VBoxContainer.new()
	btns.custom_minimum_size.x = 150
	btns.add_theme_constant_override("separation", 8)
	hb.add_child(btns)
	var title := Label.new()
	title.text = "RUST SURF"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", ACCENT)
	btns.add_child(title)
	_button(btns, "Resume", toggle)
	_button(btns, "Aim lobby", func() -> void:
		toggle()
		main.lobby.toggle())
	_button(btns, "Restart run", func() -> void:
		toggle()
		if main.lobby.active:
			main.lobby.toggle()  # leaving the lobby already puts you back on the start pad
		else:
			main.course.restart(main.player)
			main.timer.reset())
	_button(btns, "Quit", func() -> void: get_tree().quit())
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hb.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	scroll.add_child(col)
	var section := ""
	for r in ROWS:
		if r[5] != section:
			section = r[5]
			_header(col, section)
		_slider(col, r)
		if r[0] == "xh_color":
			_check(col, "xh_dot", "Center dot")
	_header(col, "HUD")
	_check(col, "speed", "Show speed")

func _button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text.to_upper()
	b.custom_minimum_size.y = 36
	b.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed"]:
		var s := StyleBoxFlat.new()
		s.bg_color = {"normal": Color(0.17, 0.18, 0.2), "hover": Color(0.25, 0.26, 0.29), "pressed": ACCENT}[st]
		s.set_corner_radius_all(3)
		b.add_theme_stylebox_override(st, s)
	b.pressed.connect(cb)
	parent.add_child(b)

func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", ACCENT)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_child(l)
	parent.add_child(pad)

func _slider(parent: Control, r: Array) -> void:
	var k: String = r[0]
	var row := HBoxContainer.new()
	var name_l := Label.new()
	name_l.text = r[1]
	name_l.custom_minimum_size.x = 130
	name_l.add_theme_color_override("font_color", Color(0.8, 0.82, 0.85))
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = r[2]
	s.max_value = r[3]
	s.step = r[4]
	s.value = clampf(float(vals[k]), r[2], r[3])
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(160, 22)
	s.focus_mode = Control.FOCUS_NONE
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.25, 0.26, 0.29)
	track.set_content_margin_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT
	fill.set_content_margin_all(2)
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	row.add_child(s)
	var val_l := Label.new()
	val_l.custom_minimum_size.x = 52
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_l)
	parent.add_child(row)
	_sliders[k] = s
	_readouts[k] = val_l
	_show(k, s.value, r[4])
	s.value_changed.connect(func(v: float) -> void:
		_show(k, v, r[4])
		_change(k, v))

func _show(k: String, v: float, step: float) -> void:
	_readouts[k].text = ("%d" if step >= 1.0 else "%.2f" if step < 0.1 else "%.1f") % v

func _check(parent: Control, k: String, text: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = vals[k]
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(on: bool) -> void: _change(k, on))
	parent.add_child(c)
	_checks[k] = c
