## systems.hud: CS2-style HUD: speed, timer pill, ammo, hitmarker, messages, and the CS2 crosshair of the player.
class_name Hud
extends CanvasLayer

var speed_label: Label
var timer_label: Label
var pb_label: Label
var msg_label: Label
var err_label: Label
var weapon_label: Label
var clip_label: Label
var reserve_label: Label
var crosshair: Control
var convars := {}
var font: Font
var _hit := 0.0
var _hit_head := false
var _ammo_box: Control

func setup(cv: Dictionary, cs2_dir: String = "") -> void:
	convars = cv
	font = _load_font(cs2_dir)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	speed_label = _label(root, 44, HORIZONTAL_ALIGNMENT_CENTER)
	_anchor(speed_label, 0.5, 1.0, 0.5, 1.0, -200, -110, 200, -50)
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.07, 0.72)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 8
	pill.add_theme_stylebox_override("panel", sb)
	_anchor(pill, 1.0, 0.0, 1.0, 0.0, -190, 18, -18, 18)
	pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	root.add_child(pill)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", -2)
	pill.add_child(col)
	timer_label = _label(col, 30, HORIZONTAL_ALIGNMENT_RIGHT)
	pb_label = _label(col, 16, HORIZONTAL_ALIGNMENT_RIGHT)
	pb_label.modulate = Color(0.78, 0.8, 0.84)
	msg_label = _label(root, 34, HORIZONTAL_ALIGNMENT_CENTER)
	_anchor(msg_label, 0.5, 0.5, 0.5, 0.5, -400, -190, 400, -130)
	err_label = _label(root, 15, HORIZONTAL_ALIGNMENT_LEFT)
	_anchor(err_label, 0.0, 0.0, 0.0, 0.0, 16, 12, 16, 12)
	err_label.modulate = Color(1, 0.4, 0.4)
	_ammo_box = Control.new()
	_ammo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(_ammo_box, 1.0, 1.0, 1.0, 1.0, -300, -130, -28, -24)
	root.add_child(_ammo_box)
	weapon_label = _label(_ammo_box, 18, HORIZONTAL_ALIGNMENT_RIGHT)
	_anchor(weapon_label, 0.0, 0.0, 1.0, 0.0, 0, 0, 0, 26)
	weapon_label.modulate = Color(0.85, 0.86, 0.9)
	clip_label = _label(_ammo_box, 56, HORIZONTAL_ALIGNMENT_RIGHT)
	_anchor(clip_label, 0.0, 1.0, 1.0, 1.0, -100, -70, -90, 0)
	reserve_label = _label(_ammo_box, 26, HORIZONTAL_ALIGNMENT_RIGHT)
	_anchor(reserve_label, 1.0, 1.0, 1.0, 1.0, -84, -36, 0, 0)
	reserve_label.modulate = Color(0.78, 0.8, 0.84)
	_ammo_box.visible = false
	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.draw.connect(_draw_crosshair)
	root.add_child(crosshair)

func _anchor(c: Control, al: float, at: float, ar: float, ab: float, ol: float, ot: float, orr: float, ob: float) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob

## CS2's own panorama font if the install has one, else a bold system font.
func _load_font(cs2_dir: String) -> Font:
	if cs2_dir != "" and DirAccess.dir_exists_absolute(cs2_dir + "/game/csgo/panorama/fonts"):
		var dir := cs2_dir + "/game/csgo/panorama/fonts"
		var best := ""
		for f in DirAccess.get_files_at(dir):
			var ext := f.get_extension().to_lower()
			if ext != "ttf" and ext != "otf":
				continue
			var low := f.to_lower()
			if best == "" or (low.contains("bold") and not best.to_lower().contains("bold")) or low.contains("stratum"):
				best = f
		if best != "":
			var ff := FontFile.new()
			if ff.load_dynamic_font(dir + "/" + best) == OK:
				return ff
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Stratum2", "Arial", "Helvetica"])
	sf.font_weight = 700
	return sf

func _label(parent: Control, size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = align
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", maxi(size / 9, 3))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 3)
	parent.add_child(l)
	return l

## cl_crosshair* convars drawn like the CS2 classic static crosshair, plus the hitmarker.
func _draw_crosshair() -> void:
	var size := float(convars.get("cl_crosshairsize", "5")) * 2.0
	var gap := float(convars.get("cl_crosshairgap", "1")) * 2.0 + 4.0
	var th: float = maxf(float(convars.get("cl_crosshairthickness", "0.5")) * 2.0, 1.0)
	var colors := {"0": Color(1, 0, 0), "1": Color(0, 1, 0), "2": Color(1, 1, 0), "3": Color(0, 0, 1), "4": Color(0, 1, 1), "5": Color(1, 1, 1)}
	var c: Color = colors.get(str(convars.get("cl_crosshaircolor", "1")), Color(0, 1, 0))
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		crosshair.draw_line(d * gap, d * (gap + size), c, th)
	if str(convars.get("cl_crosshairdot", "false")) == "true":
		crosshair.draw_rect(Rect2(-th, -th, th * 2, th * 2), c)
	if _hit > 0.0:
		var hc := Color(1, 0.3, 0.25, _hit / 0.15) if _hit_head else Color(1, 1, 1, _hit / 0.15)
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			crosshair.draw_line(d * 6.0, d * 13.0, hc, 2.0)

func _process(delta: float) -> void:
	if _hit > 0.0:
		_hit = maxf(_hit - delta, 0.0)
		if crosshair:
			crosshair.queue_redraw()

func update(speed_u: float, t: float, pb: float, running: bool) -> void:
	speed_label.text = "%d" % int(speed_u)
	timer_label.text = RunTimer.fmt(t) if running or t > 0.0 else "ready"
	pb_label.text = "PB " + RunTimer.fmt(pb)

func message(s: String, seconds: float = 2.5) -> void:
	msg_label.text = s
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(func() -> void:
			if msg_label.text == s:
				msg_label.text = "")

func errors(lines: PackedStringArray) -> void:
	err_label.text = "\n".join(lines)

## Bottom-right ammo block: "30 / 90", weapon name above; clip -1 hides the ammo (knife).
func weapon(wname: String, clip: int, reserve: int) -> void:
	_ammo_box.visible = true
	weapon_label.text = wname.to_upper()
	clip_label.visible = clip >= 0
	reserve_label.visible = clip >= 0
	if clip >= 0:
		clip_label.text = str(clip)
		reserve_label.text = "/ %d" % reserve
		clip_label.modulate = Color(1, 0.35, 0.3) if clip <= 5 else Color.WHITE

func hitmarker(head: bool) -> void:
	_hit = 0.15
	_hit_head = head
	if crosshair:
		crosshair.queue_redraw()

func set_speed_visible(b: bool) -> void:
	speed_label.visible = b
