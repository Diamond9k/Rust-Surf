## systems.hud: CS2-style HUD: health/armor bottom-left, ammo bottom-right, surf timer top centre, speed,
## messages, cl_showfps, an optional hit marker (off by default: CS2 has none) and the player's CS2 crosshair
## (static or dynamic from Weapons spread). Every size is hud.json pixels at ref_height, scaled by the window height.
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
var hp_label: Label
var armor_label: Label
var crosshair: Control
var hit_ctl: Control   # the hit marker draws on its own Control: Weapons hides the crosshair for snipers and scopes
var fps_label: Label
var hit_marker := false  # Settings 'hit_marker'; CS2 gives no hit marker, so it starts off
var convars := {}
var font: Font
var menu_font: Font    # the same face at the lighter weight CS2's settings text uses
var H := {}
var _s := 1.0
var _hit := 0.0
var _dyn := 0.0        # eased dynamic crosshair distance, px
var _fire := 0.0       # eased firing-only distance (style 5), px
var _ammo_box: Control
var _pill: PanelContainer
var _pill_sb: StyleBoxFlat
var _deco: Control
var _sized: Array = []  # [Label, base px]
var _msg_gen := 0      # each message() bumps it, so an older timer never clears a newer message
var _hp := 100.0
var _armor := 100.0

func setup(cv: Dictionary, cs2_dir: String = "") -> void:
	convars = cv
	H = Sheets.values("hud")
	font = _load_font(cs2_dir, 700)
	menu_font = _load_font(cs2_dir, int(H["menu_weight"]))
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_deco = Control.new()
	_deco.set_anchors_preset(Control.PRESET_FULL_RECT)
	_deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_deco.draw.connect(_draw_deco)
	root.add_child(_deco)
	speed_label = _label(root, H["font_speed"], HORIZONTAL_ALIGNMENT_CENTER)
	# timer: PanelContainer > VBox > labels (AimLobby hides it by that shape), top centre like the CS2 round clock
	_pill = PanelContainer.new()
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill_sb = StyleBoxFlat.new()
	_pill_sb.bg_color = Color(0, 0, 0, 0.5)
	_pill.add_theme_stylebox_override("panel", _pill_sb)
	_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.add_child(_pill)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", -2)
	_pill.add_child(col)
	timer_label = _label(col, H["font_timer"], HORIZONTAL_ALIGNMENT_CENTER)
	pb_label = _label(col, H["font_pb"], HORIZONTAL_ALIGNMENT_CENTER)
	pb_label.modulate = Color(0.78, 0.8, 0.84)
	msg_label = _label(root, H["font_msg"], HORIZONTAL_ALIGNMENT_CENTER)
	err_label = _label(root, 15, HORIZONTAL_ALIGNMENT_LEFT)
	fps_label = _label(root, H["font_fps"], HORIZONTAL_ALIGNMENT_LEFT)
	fps_label.visible = false
	err_label.modulate = Color(1, 0.4, 0.4)
	err_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	hp_label = _label(root, H["font_health"], HORIZONTAL_ALIGNMENT_LEFT)
	armor_label = _label(root, H["font_health"], HORIZONTAL_ALIGNMENT_LEFT)
	vitals(float(H["health"]), float(H["armor"]))
	_ammo_box = Control.new()
	_ammo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ammo_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_ammo_box)
	weapon_label = _label(_ammo_box, H["font_weapon"], HORIZONTAL_ALIGNMENT_RIGHT)
	weapon_label.modulate = Color(0.85, 0.86, 0.9)
	clip_label = _label(_ammo_box, H["font_clip"], HORIZONTAL_ALIGNMENT_RIGHT)
	reserve_label = _label(_ammo_box, H["font_reserve"], HORIZONTAL_ALIGNMENT_LEFT)
	reserve_label.modulate = Color(0.78, 0.8, 0.84)
	_ammo_box.visible = false
	crosshair = Control.new()
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.draw.connect(_draw_crosshair)
	root.add_child(crosshair)
	hit_ctl = Control.new()
	hit_ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hit_ctl.draw.connect(_draw_hit)
	root.add_child(hit_ctl)
	get_viewport().size_changed.connect(_layout)
	_layout()

## Places and sizes everything for the current window height.
func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	_s = vp.y / float(H["ref_height"])
	var s := _s
	for e in _sized:
		var l: Label = e[0]
		var px := maxi(int(round(float(e[1]) * s)), 8)
		l.add_theme_font_size_override("font_size", px)
		l.add_theme_constant_override("outline_size", maxi(int(px / 10.0), 2))
		l.add_theme_constant_override("shadow_offset_x", maxi(int(2 * s), 1))
		l.add_theme_constant_override("shadow_offset_y", maxi(int(2 * s), 1))
	var bh: float = H["bar_height"] * s
	var fh: float = H["font_health"] * s
	var ty := vp.y - bh * 0.5 - fh * 0.62
	_place(hp_label, Vector2(58 * s, ty), Vector2(110 * s, fh * 1.25))
	_place(armor_label, Vector2(214 * s, ty), Vector2(110 * s, fh * 1.25))
	var fc: float = H["font_clip"] * s
	_place(clip_label, Vector2(vp.x - 330 * s, vp.y - bh * 0.5 - fc * 0.62), Vector2(200 * s, fc * 1.25))
	var fr: float = H["font_reserve"] * s
	_place(reserve_label, Vector2(vp.x - 122 * s, vp.y - bh * 0.5 - fr * 0.45), Vector2(110 * s, fr * 1.25))
	var fw: float = H["font_weapon"] * s
	_place(weapon_label, Vector2(vp.x - 330 * s, vp.y - bh - fw * 1.5), Vector2(310 * s, fw * 1.3))
	var fs: float = H["font_speed"] * s
	_place(speed_label, Vector2(vp.x * 0.5 - 150 * s, vp.y - bh - fs * 1.6), Vector2(300 * s, fs * 1.3))
	var fm: float = H["font_msg"] * s
	_place(msg_label, Vector2(0, vp.y * 0.3 - fm), Vector2(vp.x, fm * 1.4))
	_place(err_label, Vector2(16, 12 + 70 * s), Vector2(vp.x - 32, 0))
	var ff: float = H["font_fps"] * s
	_place(fps_label, Vector2(8 * s, 4 * s), Vector2(300 * s, ff * 1.3))
	_pill.anchor_left = 0.5
	_pill.anchor_right = 0.5
	_pill.offset_left = -80 * s
	_pill.offset_right = 80 * s
	_pill.offset_top = 6 * s
	_pill.offset_bottom = 6 * s
	_pill_sb.content_margin_left = 18 * s
	_pill_sb.content_margin_right = 18 * s
	_pill_sb.content_margin_top = 2 * s
	_pill_sb.content_margin_bottom = 5 * s
	crosshair.position = (vp * 0.5).floor()
	hit_ctl.position = crosshair.position
	_deco.queue_redraw()
	crosshair.queue_redraw()

func _place(c: Control, pos: Vector2, sz: Vector2) -> void:
	c.position = pos
	c.size = sz

## CS2's own panorama font if the install has one (Stratum first, bold or not as weight asks), else a system font
## at that weight.
func _load_font(cs2_dir: String, weight: int) -> Font:
	var dir := cs2_dir + "/game/csgo/panorama/fonts"
	if cs2_dir != "" and DirAccess.dir_exists_absolute(dir):
		var best := ""
		var best_score := -1
		var files := Array(DirAccess.get_files_at(dir))
		files.sort()
		for f in files:
			var ext := String(f).get_extension().to_lower()
			if ext != "ttf" and ext != "otf":
				continue
			var low := String(f).to_lower()
			var score := (2 if low.contains("stratum") else 0) + (1 if low.contains("bold") == (weight >= 600) else 0)
			if score > best_score:
				best = f
				best_score = score
		if best != "":
			var ff := FontFile.new()
			if ff.load_dynamic_font(dir + "/" + best) == OK:
				return ff
	# no CS2 font: Windows' DIN-style Bahnschrift is the nearest stock face to Stratum; any other sans is
	# narrowed by hud.json font_narrow so it keeps Stratum's condensed proportions
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Stratum2", "Bahnschrift", "Arial Narrow", "Liberation Sans Narrow", "Arial", "Liberation Sans", "Helvetica"])
	sf.font_weight = weight
	var fv := FontVariation.new()
	fv.base_font = sf
	if not "Bahnschrift" in OS.get_system_fonts():
		fv.variation_transform = Transform2D(Vector2(float(H["font_narrow"]), 0), Vector2(0, 1), Vector2.ZERO)
	return fv

func _label(parent: Control, size: float, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.4))
	parent.add_child(l)
	_sized.append([l, size])
	return l

## The two bottom strips (dark fading to clear) and the health, armor and bullet icons.
func _draw_deco() -> void:
	var vp := _deco.size
	var s := _s
	var bh: float = H["bar_height"] * s
	var bw: float = H["bar_width"] * s
	var dark := Color(0, 0, 0, 0.55)
	var clear := Color(0, 0, 0, 0)
	var y0 := vp.y - bh
	_deco.draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(bw, y0), Vector2(bw, vp.y), Vector2(0, vp.y)]), PackedColorArray([dark, clear, clear, dark]))
	var ammo := _ammo_box.visible and clip_label.visible
	if ammo:
		_deco.draw_polygon(PackedVector2Array([Vector2(vp.x - bw, y0), Vector2(vp.x, y0), Vector2(vp.x, vp.y), Vector2(vp.x - bw, vp.y)]), PackedColorArray([clear, dark, dark, clear]))
	var cy := vp.y - bh * 0.5
	var ic := Color(1, 1, 1, 0.92)
	# health cross
	var a := 22.0 * s
	var t := 7.0 * s
	var cx := 30.0 * s
	_deco.draw_rect(Rect2(cx - t * 0.5, cy - a * 0.5, t, a), ic)
	_deco.draw_rect(Rect2(cx - a * 0.5, cy - t * 0.5, a, t), ic)
	# health and armor bars under the numbers: white full part over a dim track, health red when low
	var bw2: float = H["vital_bar_width"] * s
	var bh2: float = maxf(roundf(H["vital_bar_height"] * s), 2.0)
	var by := cy + float(H["font_health"]) * s * 0.5
	var low := _hp <= float(H["low_health"])
	for e in [[58.0 * s, _hp, low], [214.0 * s, _armor, false]]:
		var x0: float = e[0] + 4.0 * s
		var f := clampf(float(e[1]) / 100.0, 0.0, 1.0)
		_deco.draw_rect(Rect2(x0, by, bw2, bh2), Color(1, 1, 1, 0.18))
		_deco.draw_rect(Rect2(x0, by, roundf(bw2 * f), bh2), Color(1, 0.3, 0.25) if e[2] else ic)
	hp_label.modulate = Color(1, 0.35, 0.3) if low else Color.WHITE
	# armor shield
	var sx := 188.0 * s
	var w := 11.0 * s
	_deco.draw_colored_polygon(PackedVector2Array([Vector2(sx - w, cy - 11 * s), Vector2(sx, cy - 14 * s), Vector2(sx + w, cy - 11 * s),
		Vector2(sx + w, cy), Vector2(sx, cy + 13 * s), Vector2(sx - w, cy)]), ic)
	# bullets right of the reserve count
	if ammo:
		for i in 3:
			var x := vp.x - (22.0 + i * 8.0) * s
			_deco.draw_rect(Rect2(x - 2.5 * s, cy - 5 * s, 5 * s, 15 * s), ic)
			_deco.draw_colored_polygon(PackedVector2Array([Vector2(x - 2.5 * s, cy - 5 * s), Vector2(x, cy - 11 * s), Vector2(x + 2.5 * s, cy - 5 * s)]), ic)

## Source convar booleans come as "1"/"0" or "true"/"false".
static func on(cv: Dictionary, k: String, def: String) -> bool:
	return str(cv.get(k, def)).to_lower() in ["1", "true"]

static func num(cv: Dictionary, k: String, def: float) -> float:
	var v := str(cv.get(k, def))
	return float(v) if v.is_valid_float() or v.is_valid_int() else def

## hud.json xh_colors: the cl_crosshaircolor 0-4 presets as "r,g,b|r,g,b|..." (0-255).
static func presets(hv: Dictionary) -> Array:
	var out: Array = []
	for t in String(hv.get("xh_colors", "50,250,50")).split("|"):
		var p := t.split(",")
		out.append(Color8(int(p[0]), int(p[1]), int(p[2])))
	return out

static func xh_color(cv: Dictionary, hv: Dictionary) -> Color:
	var i := int(num(cv, "cl_crosshaircolor", 1))
	var cols := presets(hv)
	var c: Color = cols[i] if i >= 0 and i < cols.size() else cols[mini(1, cols.size() - 1)]
	if i == 5:  # CS2 colour 5 is the player's own RGB
		c = Color8(clampi(int(num(cv, "cl_crosshaircolor_r", 50)), 0, 255), clampi(int(num(cv, "cl_crosshaircolor_g", 250)), 0, 255), clampi(int(num(cv, "cl_crosshaircolor_b", 50)), 0, 255))
	if on(cv, "cl_crosshairusealpha", "true"):
		c.a = clampf(num(cv, "cl_crosshairalpha", 200) / 255.0, 0.0, 1.0)
	return c

## The cl_crosshair* crosshair at the origin of ci for a window h px tall. spread_px is how far the
## dynamic styles move out (spread + inaccuracy), fire_px the firing-only part (style 5). The menu preview uses it too.
static func draw_xh(ci: CanvasItem, cv: Dictionary, h: float, hv: Dictionary, spread_px: float, fire_px: float) -> void:
	var m := xh_px(cv, h, hv)
	var yres := h / float(hv["yres_base"])
	var style := int(num(cv, "cl_crosshairstyle", 2))
	var size: float = m["size"]
	var th: float = m["thickness"]
	var gap: float = m["gap"]
	var move := 0.0
	if style in [0, 2, 3]:
		move = roundf(spread_px)
	elif style == 5:
		move = roundf(fire_px)
	var c := xh_color(cv, hv)
	var ot: float = m["outline"]
	var arms: Array = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1)]
	if not on(cv, "cl_crosshair_t", "false"):
		arms.append(Vector2(0, -1))
	var segs: Array = []  # [distance from centre, length, alpha mod]
	if style == 2:
		var ratio := clampf(num(cv, "cl_crosshair_dynamic_maxdist_splitratio", 0.35), 0.0, 1.0)
		var split := num(cv, "cl_crosshair_dynamic_splitdist", 7) * yres
		var inner := roundf(size * (1.0 - ratio))
		if move > split:
			segs.append([gap, inner, num(cv, "cl_crosshair_dynamic_splitalpha_innermod", 1)])
			segs.append([gap + inner + move, size - inner, num(cv, "cl_crosshair_dynamic_splitalpha_outermod", 0.5)])
		else:
			segs.append([gap, size, 1.0])
	else:
		segs.append([gap + move, size, 1.0])
	var half := floorf(th * 0.5)
	for pass_i in 2:
		if pass_i == 0 and ot <= 0.0:
			continue
		var grow := ot if pass_i == 0 else 0.0
		for sg in segs:
			var am: float = sg[2]
			var col := Color(0, 0, 0, c.a * am) if pass_i == 0 else Color(c.r, c.g, c.b, c.a * am)
			var d: float = sg[0]
			var ln: float = sg[1]
			if ln <= 0.0:
				continue
			for v in arms:
				var r: Rect2
				if v.x > 0:
					r = Rect2(d, -half, ln, th)
				elif v.x < 0:
					r = Rect2(-d - ln, -half, ln, th)
				elif v.y > 0:
					r = Rect2(-half, d, th, ln)
				else:
					r = Rect2(-half, -d - ln, th, ln)
				ci.draw_rect(r.grow(grow), col)
		if on(cv, "cl_crosshairdot", "false"):
			ci.draw_rect(Rect2(-half, -half, th, th).grow(grow), Color(0, 0, 0, c.a) if pass_i == 0 else c)

## Whole-pixel arm length, thickness (Source truncates YRES(thickness), min 1), static gap and outline
## (screen pixels, not scaled; 0 when off) for a window h px tall.
static func xh_px(cv: Dictionary, h: float, hv: Dictionary) -> Dictionary:
	var yres := h / float(hv["yres_base"])
	var ot := 0.0
	if on(cv, "cl_crosshair_drawoutline", "false"):
		ot = maxf(roundf(num(cv, "cl_crosshair_outlinethickness", 1)), 1.0)
	return {"size": maxf(roundf(num(cv, "cl_crosshairsize", 5) * yres), 0.0),
		"thickness": maxf(floorf(num(cv, "cl_crosshairthickness", 0.5) * yres), 1.0),
		"gap": roundf((float(hv["gap_base"]) + num(cv, "cl_crosshairgap", 1)) * h / float(hv["gap_ref_height"])),
		"outline": ot}

## Pixels a spread cone of rad radians covers on a window h px tall (Source: YRES(rad x 320 / tan(fov/2)), fov the
## horizontal fov at 4:3). The fov is the live camera's (Godot keeps height), turned back into Source's 4:3 one.
func spread_to_px(rad: float, h: float) -> float:
	return rad * float(H["spread_units"]) / _tan43() * h / float(H["yres_base"])

## tan(fov/2) of Source's 4:3 horizontal fov for the live camera (its vertical fov widened by 4:3 = 320:240).
func _tan43() -> float:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var v := cam.fov if cam != null else Sheets.vfov_43(float(Sheets.movement()["fov_default"]))
	return tan(deg_to_rad(v) * 0.5) * float(H["spread_units"]) / (float(H["yres_base"]) * 0.5)

## cl_crosshair_recoil: where the bullets go against the screen centre, px (the aim punch the camera does not show).
func _recoil_px(w: Node, h: float) -> Vector2:
	if w == null or not on(convars, "cl_crosshair_recoil", "false") or not (w.get("X") is Dictionary) or not (w.get("_aim") is Vector2):
		return Vector2.ZERO
	var x: Dictionary = w.X
	var aim: Vector2 = (w._aim as Vector2) * float(x["recoil_scale"])
	var view: Vector2 = w._view if w.get("_view") is Vector2 else Vector2.ZERO
	var d := aim - (view + aim * float(x["view_recoil_tracking"]))  # degrees: x pitch up, y yaw left
	var f := float(H["spread_units"]) / _tan43() * h / float(H["yres_base"])
	return Vector2(-tan(deg_to_rad(d.y)), -tan(deg_to_rad(d.x))) * f

## True while CS2 draws no crosshair: one rule, Weapons.crosshair_shown() (unscoped snipers, any scope).
func _no_xh() -> bool:
	var w: Node = get_parent().get("weapons") if get_parent() else null
	return w != null and w.has_method("crosshair_shown") and not w.crosshair_shown()

func _draw_crosshair() -> void:
	if not _no_xh():
		draw_xh(crosshair, convars, get_viewport().get_visible_rect().size.y, H, _dyn, _fire)

func _draw_hit() -> void:
	if _hit <= 0.0:
		return
	var k := get_viewport().get_visible_rect().size.y / float(H["ref_height"])
	var hc := Color(1, 1, 1, _hit / float(H["hit_time"]))  # white for every hit
	for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		hit_ctl.draw_line(d * float(H["hit_inner"]) * k, d * float(H["hit_outer"]) * k, hc, maxf(float(H["hit_width"]) * k, 1.0), true)

func _process(delta: float) -> void:
	if crosshair == null:
		return
	if _hit > 0.0:
		_hit = maxf(_hit - delta, 0.0)
		hit_ctl.queue_redraw()
	if fps_label.visible:
		fps_label.text = "%d fps" % int(Engine.get_frames_per_second())
	var spread := 0.0
	var fire := 0.0
	var w: Node = get_parent().get("weapons") if get_parent() else null
	if w != null and w.has_method("_spread") and w.has_method("held") and w.get("main") != null and w.main.player != null:
		var id: String = w.held()
		var x: Variant = w.get("X")
		var to_rad: float = float(x.get("inaccuracy_to_rad", 0.001)) if x is Dictionary else 0.001  # items_game units -> radians
		if id != "":
			spread = float(w._spread(id)) * to_rad
			fire = float(w.get("_inaccuracy")) * to_rad
	var h := get_viewport().get_visible_rect().size.y
	var k := clampf(delta * float(H["dynamic_rate"]), 0.0, 1.0)
	_dyn = lerpf(_dyn, spread_to_px(spread, h), k)
	_fire = lerpf(_fire, spread_to_px(fire, h), k)
	crosshair.position = (get_viewport().get_visible_rect().size * 0.5).floor() + _recoil_px(w, h).round()
	crosshair.queue_redraw()

func update(speed_u: float, t: float, pb: float, running: bool) -> void:
	speed_label.text = "%d" % int(speed_u) if speed_u >= float(H["speed_min"]) else ""  # no bare 0 at rest
	timer_label.text = RunTimer.fmt(maxf(t, 0.0))
	pb_label.text = "PB " + RunTimer.fmt(pb)

func message(s: String, seconds: float = 2.5) -> void:
	msg_label.text = s
	_msg_gen += 1
	var gen := _msg_gen
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(func() -> void:
			if _msg_gen == gen:
				msg_label.text = "")

## Health and armor, bottom-left (numbers and the bars under them). Nothing in the mashup deals damage to the
## player yet, so Hud starts them at hud.json health/armor; a damage model calls this.
func vitals(hp: float, armor: float) -> void:
	_hp = hp
	_armor = armor
	hp_label.text = str(int(ceilf(hp)))
	armor_label.text = str(int(ceilf(armor)))
	if _deco:
		_deco.queue_redraw()

func errors(lines: PackedStringArray) -> void:
	err_label.text = "\n".join(lines)

## Bottom-right ammo: "30 / 90", weapon name above; clip -1 hides the ammo (knife).
func weapon(wname: String, clip: int, reserve: int, clip_max: int = -1) -> void:
	_ammo_box.visible = true
	weapon_label.text = wname.to_upper() if clip >= 0 else ""  # the knife has no ammo panel at all
	clip_label.visible = clip >= 0
	reserve_label.visible = clip >= 0
	if clip >= 0:
		clip_label.text = str(clip)
		reserve_label.text = "/ %d" % reserve
		var low := maxi(1, int(clip_max * float(H["low_ammo_frac"])) if clip_max > 0 else 5)
		clip_label.modulate = Color(1, 0.35, 0.3) if clip <= low else Color.WHITE
	_deco.queue_redraw()

## A hit: when the player turned the hit marker on, the white marker (head or body alike) and the hud.json
## hit_sound row when sounds.json has one. Off (the default) a hit shows and plays nothing, as in CS2.
func hitmarker(_head: bool) -> void:
	if not hit_marker:
		return
	_hit = float(H["hit_time"])
	var snd: Node = get_parent().get("sounds") if get_parent() else null
	if snd != null and snd.get("players") is Dictionary and (snd.players as Dictionary).has(String(H["hit_sound"])):
		snd.play(String(H["hit_sound"]))
	if hit_ctl:
		hit_ctl.queue_redraw()

func set_speed_visible(b: bool) -> void:
	speed_label.visible = b

func set_fps_visible(b: bool) -> void:
	fps_label.visible = b
