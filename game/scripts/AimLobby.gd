## systems.aim_lobby: the aim range. Humanoid bots built from primitives (sheet 'parts' and 'props'), CS2
## hitgroups, numbered lanes, distance markers, a 3-2-1 countdown, rounds, kills, time-to-kill and a stats panel.
## Contract for weapons: raycast from the camera and, when collider.has_method("hit"), call
## collider.hit(damage, head, point). Call lobby.on_shot_fired() once per shot, before that shot's hits.
class_name AimLobby
extends Node3D

const FEED_PLAYER := Color(0.62, 0.77, 1.0)
const FEED_BOT := Color(0.93, 0.76, 0.36)
const GREY := Color(0.72, 0.74, 0.78)

var main: Node
var active := false
var mode := "bots"
var modes: Array = []

var V := {}
var S := {}
var M := Sheets.movement()
var content: Content
var center := Vector3.ZERO
var H := 1.3716
var _state := "idle"   # idle | countdown | round | summary
var _left := 0.0
var _clock := 0.0      # round clock: stands still while the Esc menu is open
var _gen := 0
var _quick := false    # --wtest / --shots / --lobbytest: no countdown, the round starts at once
var _shots := 0
var _hits := 0
var _heads := 0
var _hit_shot := -1
var _head_shot := false
var _shot_frame := -1
var _shot_ok := false
var _kills := 0
var _hs_kills := 0
var _damage := 0.0
var _ttk: Array[float] = []
var _flick_sum := 0.0
var _flick_n := 0
var _on_target := 0.0
var _used := {}
var _spawned_at := 0.0
var _best := {}
var _targets: Array[Node3D] = []
var _dir := 1.0
var _flip := 0.0
var _rng := RandomNumberGenerator.new()
var _mats := {}
var _surf_hud := {}
var _ui: Control
var _top_kills: Label
var _top_time: Label
var _top_score: Label
var _top_mode: Label
var _rows: Array = []   # [row, name Label, value Label]
var _panel_title: Label
var _feed: VBoxContainer
var _feed_items: Array = []   # [Control, expires at _clock]
var _big: Label
var _warn: Label
var _hint: Label
var _summary: PanelContainer
var _sum_title: Label
var _sum_body: Label

## Every hittable body: group "aim_target", hit(dmg, head, at). A bot's head is its own body with is_head=true;
## every part of one bot shares the bot as its unit, so Weapons merges a bot's parts into one hit per shot.
class AimTarget extends StaticBody3D:
	var lobby: AimLobby
	var unit: Node3D
	var is_head := false
	var group := "chest"

	func hit(dmg: float, head: bool, at: Vector3) -> void:
		lobby.register_hit(unit, dmg, head or is_head, at, group)

## One humanoid bot: the unit every part reports to. pose tips over on death and rocks back on hits.
class Bot extends Node3D:
	var hp := 100.0
	var hp_max := 100.0
	var alive := true
	var first_hit := -1.0
	var down_at := 0.0
	var kick := 0.0
	var tag := ""
	var pose: Node3D
	var bodies: Array = []

func build(c: Content, m: Node) -> void:
	main = m
	content = c
	S = Sheets.load_sheet("aim_lobby")
	V = Sheets.values("aim_lobby")
	modes = S["modes"]
	center = _v3("center")
	H = float(M["hull_height"])
	mode = String(modes[0]["id"])
	var ua := OS.get_cmdline_user_args()
	var mi := ua.find("--lobby-mode")
	if mi >= 0 and mi + 1 < ua.size():
		for r in modes:
			if r["id"] == ua[mi + 1]:
				mode = ua[mi + 1]
	_quick = ua.has("--wtest") or ua.has("--shots") or ua.has("--lobbytest")
	_rng.randomize()
	_best = {} if _quick else _load_best()  # test and render runs never touch the player's bests
	_input_action()
	_arena()
	_hud()
	if ua.has("--lobbytest"):
		_selftest()

func _f(k: String) -> float:
	return float(V[k])

func _v3(k: String) -> Vector3:
	return _a3(V[k])

func _a3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

func _col(k: String) -> Color:
	return _c(V[k])

func _c(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))

func _input_action() -> void:
	if not InputMap.has_action("surf_lobby_mode"):
		InputMap.add_action("surf_lobby_mode")
	if InputMap.action_get_events("surf_lobby_mode").is_empty():
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_M
		InputMap.action_add_event("surf_lobby_mode", ev)

func spawn_pos() -> Vector3:
	return center + _v3("spawn_offset")

func toggle() -> void:
	if not active:
		_enter(true)
	else:
		_leave("aim lobby closed, round not saved")
		main.course.restart(main.player)
		main.timer.reset()
		main.ghost.stop_run(false)

func _enter(teleport: bool) -> void:
	var p: SurfPlayer = main.player
	active = true
	if teleport:
		p.teleport(spawn_pos(), _f("spawn_yaw"))
		p.pitch = 0.0
		p.cam.rotation_degrees.x = 0.0
	main.timer.reset()
	main.ghost.stop_run(false)
	_draw_gun()
	_show_surf_hud(false)
	_ui.visible = true
	_start_round()

func _leave(msg: String) -> void:
	active = false
	_state = "idle"
	_gen += 1
	_ui.visible = false
	_clear()
	_show_surf_hud(true)
	if msg != "":
		main.hud.message(msg, 2.0)

## An aim map starts you on a gun: the primary, else the pistol; the knife only when prep exported no gun.
func _draw_gun() -> void:
	var w: Node = main.weapons
	if w == null:
		return
	for s in ["primary", "secondary"]:
		if String(w.slots.get(s, "")) != "":
			if w.current != s:
				w.switch_to(s)
			return
	main.hud.message("no CS2 gun exported yet: run prep on your PC (B opens the buy menu)", 4.0)

## The surf timer pill and speed readout mean nothing here: hide them while the lobby is open.
func _show_surf_hud(on: bool) -> void:
	var h: Node = main.hud
	if h == null or not (h.get("timer_label") is Control):
		return
	var pill: Node = (h.timer_label as Control).get_parent().get_parent()
	var nodes: Array = [h.get("speed_label"), pill if pill is PanelContainer else h.timer_label]
	for n in nodes:
		if not (n is Control):
			continue
		if not on:
			_surf_hud[n] = (n as Control).visible
			(n as Control).visible = false
		elif _surf_hud.has(n):
			(n as Control).visible = bool(_surf_hud[n])
	if on:
		_surf_hud.clear()

func _paused() -> bool:
	return main.settings != null and main.settings.is_open

func _inside_arena(at: Vector3) -> bool:
	var sz: Array = V["arena_size"]
	var l := at - center
	return absf(l.x) < float(sz[0]) * 0.5 + 5.0 and absf(l.z) < float(sz[1]) * 0.5 + 5.0 and l.y > -5.0 and l.y < _f("wall_height") + 30.0

func _behind_line() -> bool:
	return main.player.global_position.z - center.z >= _f("firing_line_z")

# --- arena ---

func _mat(id: String) -> StandardMaterial3D:
	var base: StandardMaterial3D = main.course.materials.get(id)
	if base == null:
		return StandardMaterial3D.new()
	var mat: StandardMaterial3D = base.duplicate()
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE / float(main.course.uv_scales[id])
	return mat

func _flat(c: Color, emit: float = 0.0, rough: float = 0.6) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = rough
	if emit > 0.0:
		mat.emission_enabled = true
		mat.emission = c
		mat.emission_energy_multiplier = emit
	return mat

## A box centred at c (relative to center) with the given size; solid unless solid is false.
func _box(c: Vector3, size: Vector3, mat: Material, solid: bool = true) -> void:
	var body := StaticBody3D.new()
	body.position = center + c
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	if solid:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		body.add_child(cs)
	add_child(body)

## Floor paint: a flat quad just above the floor.
func _paint(c: Vector3, sx: float, sz: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(sx, sz)
	mi.mesh = pm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = center + c + Vector3(0, 0.006, 0)
	add_child(mi)

## Painted or plaque text; rot in degrees ((-90, 0, 0) lies flat on the floor, readable from the spawn).
func _text3d(s: String, c: Vector3, rot: Vector3, height_m: float, col: Color) -> void:
	var l := Label3D.new()
	l.text = s
	if main.hud and main.hud.font:
		l.font = main.hud.font
	l.font_size = 96
	l.pixel_size = height_m / 96.0
	l.modulate = col
	l.outline_size = 0
	l.shaded = true
	l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.position = center + c
	l.rotation_degrees = rot
	add_child(l)

func _lane_x(lane: float) -> float:
	return -_f("lane_count") * _f("lane_width") * 0.5 + (lane - 0.5) * _f("lane_width")

func _arena() -> void:
	var sz: Array = V["arena_size"]
	var sx := float(sz[0])
	var sz_z := float(sz[1])
	var wh := _f("wall_height")
	var t := _f("wall_thickness")
	var g := _f("ground_size")
	var trim := _f("wall_trim_height")
	_box(Vector3(0, -1.55, 0), Vector3(g, 1.0, g), _mat(String(V["ground_material"])))
	_box(Vector3(0, -t * 0.5, 0), Vector3(sx, t, sz_z), _mat(String(V["floor_material"])))
	var wm := _mat(String(V["wall_material"]))
	var tm := _mat(String(V["trim_material"]))
	for s in [-1.0, 1.0]:
		_box(Vector3(0, wh * 0.5, s * (sz_z * 0.5 + t * 0.5)), Vector3(sx + t * 2.0, wh, t), wm)
		_box(Vector3(s * (sx * 0.5 + t * 0.5), wh * 0.5, 0), Vector3(t, wh, sz_z), wm)
		_box(Vector3(0, trim * 0.5, s * (sz_z * 0.5 - 0.06)), Vector3(sx, trim, 0.12), tm)
		_box(Vector3(s * (sx * 0.5 - 0.06), trim * 0.5, 0), Vector3(0.12, trim, sz_z), tm)
		_box(Vector3(0, wh + 0.12, s * (sz_z * 0.5 + t * 0.5)), Vector3(sx + t * 2.0 + 0.3, 0.24, t + 0.3), tm)
		_box(Vector3(s * (sx * 0.5 + t * 0.5), wh + 0.12, 0), Vector3(t + 0.3, 0.24, sz_z), tm)
	var n := int(_f("lane_count"))
	var lw := _f("lane_width")
	var fz := _f("firing_line_z")
	var back := -sz_z * 0.5
	var pc := _col("color_paint")
	var paint := _flat(pc, 0.0, 0.85)
	var plaque := _flat(_col("color_plaque"), 0.0, 0.7)
	for i in n + 1:
		_paint(Vector3(_lane_x(i + 0.5), 0, (fz + back) * 0.5), 0.12, fz - back, paint)
	for i in n:
		var x := _lane_x(i + 1)
		_text3d(str(i + 1), Vector3(x, 0.012, fz - 2.6), Vector3(-90, 0, 0), 2.2, pc)
		_box(Vector3(x, wh * 0.62, back + 0.04), Vector3(2.6, 2.8, 0.08), plaque, false)
		_text3d(str(i + 1), Vector3(x, wh * 0.62, back + 0.1), Vector3.ZERO, 2.4, pc)
	var edge := n * lw * 0.5
	for d in V["distance_marks"]:
		var z := fz - float(d)
		_paint(Vector3(0, 0, z), n * lw, 0.1, paint)
		for s in [-1.0, 1.0]:
			_text3d("%d m" % int(d), Vector3(s * (edge + (sx * 0.5 - edge) * 0.5), 0.012, z + 0.55), Vector3(-90, 0, 0), 0.75, pc)
			_box(Vector3(s * (sx * 0.5 - 0.04), 2.4, z), Vector3(0.08, 1.0, 2.3), plaque, false)
			_text3d("%d m" % int(d), Vector3(s * (sx * 0.5 - 0.1), 2.4, z), Vector3(0, -90.0 * s, 0), 0.7, pc)
	_paint(Vector3(0, 0.002, fz), sx, 0.3, _flat(_col("color_line"), 0.0, 0.8))
	var rh := _f("rail_height")
	_box(Vector3(0, rh * 0.5, fz - 0.35), Vector3(sx, rh, 0.4), _flat(_col("color_line"), 0.0, 0.8))
	var cm := _mat(String(V["cover_material"]))
	for r in V["cover"]:
		var a: Array = r
		_box(Vector3(_lane_x(float(a[0])), float(a[3]) * 0.5, fz - float(a[1])), Vector3(a[2], a[3], a[4]), cm)
	var cr: Array = V["bot_crate"]
	for s in V["bot_spots"]:
		var a: Array = s
		if float(a[4]) > 0.0:  # a raised spot: the bot stands on a crate
			_box(Vector3(_lane_x(float(a[0])) + float(a[2]), float(a[4]) * 0.5, fz - float(a[1])), Vector3(float(cr[0]), float(a[4]), float(cr[1])), cm)

# --- hud ---

func _style(a: float, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.06, a)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 6
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(2)
	return sb

func _lab(parent: Node, size: int, col: Color = Color.WHITE, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, text: String = "") -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = align
	l.text = text
	if main.hud and main.hud.font:
		l.add_theme_font_override("font", main.hud.font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 4)
	parent.add_child(l)
	return l

func _pc(parent: Node, a: float, border: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", _style(a, border))
	parent.add_child(p)
	return p

func _hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)
	# top centre, CS2-style: kills | round clock | score
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 3)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.offset_top = 10
	_ui.add_child(top)
	_top_kills = _top_box(top, "KILLS", FEED_PLAYER)
	var mid := _pc(top, 0.82)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", -4)
	mid.add_child(mv)
	_top_time = _lab(mv, 30, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_top_time.custom_minimum_size.x = 120
	_top_mode = _lab(mv, 13, GREY, HORIZONTAL_ALIGNMENT_CENTER)
	_top_score = _top_box(top, "SCORE", FEED_BOT)
	# left stats panel
	var panel := _pc(_ui, 0.5)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	panel.offset_left = 14
	panel.offset_top = -120
	panel.custom_minimum_size = Vector2(210, 0)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 1)
	panel.add_child(pv)
	_panel_title = _lab(pv, 13, FEED_BOT)
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 6)
	pv.add_child(sep)
	for i in 9:
		var hb := HBoxContainer.new()
		pv.add_child(hb)
		var nl := _lab(hb, 13, GREY)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var vl := _lab(hb, 14, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
		_rows.append([hb, nl, vl])
	# kill feed, top right like CS2
	_feed = VBoxContainer.new()
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_feed.offset_top = 14
	_feed.offset_right = -16
	_feed.add_theme_constant_override("separation", 3)
	_ui.add_child(_feed)
	_big = _lab(_ui, 120, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_big.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_big.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_big.grow_vertical = Control.GROW_DIRECTION_BOTH
	_big.offset_top = -170
	_big.add_theme_constant_override("outline_size", 10)
	_warn = _lab(_ui, 22, Color(1, 0.35, 0.3), HORIZONTAL_ALIGNMENT_CENTER, "GET BEHIND THE YELLOW LINE: shots from here don't count")
	_warn.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_warn.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_warn.offset_top = 60
	_hint = _lab(_ui, 14, GREY, HORIZONTAL_ALIGNMENT_CENTER, "[M] next mode    [B] buy menu    [Esc] pause / leave")
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.offset_top = -34
	_summary = _pc(_ui, 0.86)
	_summary.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_summary.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_summary.grow_vertical = Control.GROW_DIRECTION_BOTH
	_summary.custom_minimum_size = Vector2(380, 0)
	var sv := VBoxContainer.new()
	_summary.add_child(sv)
	_sum_title = _lab(sv, 26, FEED_BOT, HORIZONTAL_ALIGNMENT_CENTER)
	_sum_body = _lab(sv, 18)
	_summary.visible = false
	_ui.visible = false

func _top_box(parent: Node, cap: String, col: Color) -> Label:
	var p := _pc(parent, 0.7)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	p.add_child(v)
	var l := _lab(v, 26, col, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size.x = 76
	_lab(v, 12, GREY, HORIZONTAL_ALIGNMENT_CENTER, cap)
	return l

func _acc() -> float:
	return 100.0 * _hits / maxf(_shots, 1)

## Round seconds played so far (the clock stands still while paused).
func _elapsed() -> float:
	return _f("round_s") - maxf(_left, 0.0) if _state == "round" else _f("round_s")

func _avg_ttk_ms() -> float:
	var s := 0.0
	for x in _ttk:
		s += x
	return 1000.0 * s / maxf(_ttk.size(), 1)

func _best_ttk_ms() -> float:
	return 1000.0 * float(_ttk.min()) if not _ttk.is_empty() else 0.0

## Score per mode. Misses cost points, so spraying never beats aiming.
func _score() -> int:
	var miss := (_shots - _hits) * int(_f("points_miss"))
	match mode:
		"bots":
			return maxi(0, _kills * int(_f("points_kill")) + _hs_kills * int(_f("points_hs_kill")) - miss)
		"flick":
			return maxi(0, _hits * int(_f("points_flick")) - miss)
		"track":
			return int(_on_target * _f("points_track_s"))
	return 0

## [name, value] rows for the panel, the summary and the --wtest line.
func _stats() -> Array:
	var out: Array = []
	match mode:
		"bots":
			out.append(["Kills", str(_kills)])
			out.append(["Headshot %", "%.0f%%" % (100.0 * _hs_kills / maxf(_kills, 1))])
			out.append(["Accuracy", "%.0f%%" % _acc()])
			out.append(["Shots / hits", "%d / %d" % [_shots, _hits]])
			out.append(["Avg time to kill", "%.0f ms" % _avg_ttk_ms() if _kills > 0 else "-"])
			out.append(["Best time to kill", "%.0f ms" % _best_ttk_ms() if _kills > 0 else "-"])
			out.append(["Time per kill", "%.2f s" % (_elapsed() / _kills) if _kills > 0 else "-"])
			out.append(["Damage", str(int(_damage))])
		"flick":
			out.append(["Orbs hit", str(_hits)])
			out.append(["Accuracy", "%.0f%%" % _acc()])
			out.append(["Shots", str(_shots)])
			out.append(["Avg time to hit", "%.0f ms" % (1000.0 * _flick_sum / maxf(_flick_n, 1)) if _flick_n > 0 else "-"])
		"track":
			out.append(["On target", "%.1f s" % _on_target])
			out.append(["Accuracy", "%.0f%%" % _acc()])
			out.append(["Shots / hits", "%d / %d" % [_shots, _hits]])
	return out

func _stats_line() -> String:
	var parts: PackedStringArray = []
	for r in _stats():
		parts.append("%s %s" % [String(r[0]).to_lower(), r[1]])
	return "  ".join(parts) + "  score %d" % _score()

func _mode_label() -> String:
	for r in modes:
		if r["id"] == mode:
			return String(r["label"])
	return mode.to_upper()

func _weapon_name(id: String) -> String:
	if id == "" or id == "knife":
		return "Knife"
	var w: Node = main.weapons
	return String(w.rows[id]["name"]) if w and w.rows.has(id) else id

## Best scores are per mode and weapon; a round fired with more than one weapon is not ranked.
func _best_key() -> String:
	if _used.size() > 1:
		return ""
	var w := String(_used.keys()[0]) if _used.size() == 1 else (String(main.weapons.held()) if main.weapons else "")
	return "%s|%s" % [mode, w]

func _refresh_hud() -> void:
	_top_kills.text = str(_kills if mode == "bots" else _hits)
	_top_score.text = str(_score())
	var secs := ceili(_left) if _state == "round" else int(_f("round_s"))
	_top_time.text = "%d:%02d" % [int(secs / 60.0), secs % 60]
	_top_time.add_theme_color_override("font_color", Color(1, 0.35, 0.3) if _state == "round" and _left < 10.0 else Color.WHITE)
	var key := _best_key()
	var wn := _weapon_name(key.get_slice("|", 1)) if key != "" else "mixed"
	_top_mode.text = "%s  ·  %s" % [_mode_label(), "PAUSED" if _paused() else wn.to_upper()]
	_panel_title.text = "AIM RANGE  ·  %s" % _mode_label()
	var st := _stats()
	st.append(["Best (%s)" % wn, str(int(_best.get(key, 0))) if key != "" else "not ranked"])
	for i in _rows.size():
		var r: Array = _rows[i]
		(r[0] as Control).visible = i < st.size()
		if i < st.size():
			(r[1] as Label).text = String(st[i][0])
			(r[2] as Label).text = String(st[i][1])
	_big.visible = _state == "countdown"
	if _state == "countdown":
		_big.text = str(ceili(_left))
	_warn.visible = _state in ["round", "countdown"] and not _behind_line()

# --- rounds ---

func _process(dt: float) -> void:
	if not active:
		if main.get("shots_running") == true and main.player and _inside_arena(main.player.global_position):
			_enter(false)  # the Gauntlet lobby pose: show the range as a player sees it
		return
	if not _inside_arena(main.player.global_position):
		_leave("left the aim lobby, round not saved")  # restart or checkpoint teleported the player away
		return
	if not _paused():
		_clock += dt
		if Input.is_action_just_pressed("surf_lobby_mode"):
			var i := 0
			for k in modes.size():
				if modes[k]["id"] == mode:
					i = k
			mode = String(modes[(i + 1) % modes.size()]["id"])
			_start_round()
		match _state:
			"countdown":
				_left -= dt
				if _left <= 0.0:
					_go()
			"round":
				_left -= dt
				if _left <= 0.0:
					_end_round()
			"summary":
				_left -= dt
				if _left <= 0.0:
					_start_round()
		_tick_bots(dt)
		_tick_feed()
	_refresh_hud()

func _start_round() -> void:
	_gen += 1
	_shots = 0
	_hits = 0
	_heads = 0
	_hit_shot = -1
	_head_shot = false
	_shot_frame = -1
	_kills = 0
	_hs_kills = 0
	_damage = 0.0
	_ttk.clear()
	_flick_sum = 0.0
	_flick_n = 0
	_on_target = 0.0
	_used.clear()
	for it in _feed_items:
		(it[0] as Node).queue_free()
	_feed_items.clear()
	if main.weapons and main.weapons.has_method("refill"):
		main.weapons.refill()  # an aim map never runs you dry
	_summary.visible = false
	_spawn_mode()
	_state = "countdown"
	_left = 0.0 if _quick else _f("countdown_s")
	if _left <= 0.0:
		_go()

func _go() -> void:
	_state = "round"
	_left = _f("round_s")
	_spawned_at = _clock

func _end_round() -> void:
	_state = "summary"
	_left = _f("summary_s")
	var score := _score()
	var key := _best_key()
	var line := ""
	if key == "":
		line = "more than one weapon fired: not ranked"
	elif score > int(_best.get(key, 0)):
		_best[key] = score
		line = "NEW BEST with the %s" % _weapon_name(key.get_slice("|", 1))
		if not _quick:
			_save_best()
	else:
		line = "best with the %s: %d" % [_weapon_name(key.get_slice("|", 1)), int(_best.get(key, 0))]
	_sum_title.text = "%s  ·  SCORE %d" % [_mode_label(), score]
	var body: PackedStringArray = []
	for r in _stats():
		body.append("%-20s %s" % [String(r[0]), String(r[1])])
	body.append("")
	body.append(line)
	body.append("next round in %d s" % int(_f("summary_s")))
	_sum_body.text = "\n".join(body)
	_summary.visible = true
	_clear()

func _load_best() -> Dictionary:
	var p := String(V["best_file"])
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			return d
	return {}

func _save_best() -> void:
	var f := FileAccess.open(String(V["best_file"]), FileAccess.WRITE)
	if f == null:
		main.hud.message("could not save the best score: %s" % error_string(FileAccess.get_open_error()), 3.0)
		return
	f.store_string(JSON.stringify(_best))
	f.close()

## Weapons calls this once per trigger pull, hit or miss, before that pull's hits.
func on_shot_fired() -> void:
	if not (active and _state == "round"):
		return
	_shots += 1
	_shot_frame = Engine.get_process_frames()
	_shot_ok = _behind_line()
	if main.weapons:
		_used[String(main.weapons.held())] = true

## Called by AimTarget.hit(). unit is the target root (a Bot, or the flick orb). A hit counts only in a round,
## in the same frame as a shot fired from behind the firing line, on a live target of this round.
func register_hit(unit: Node3D, dmg: float, head: bool, _at: Vector3, group: String = "chest") -> void:
	if not active or _state != "round" or not is_instance_valid(unit) or not _targets.has(unit):
		return
	if _shot_frame != Engine.get_process_frames() or not _shot_ok:
		return
	match mode:
		"flick":
			_count(false)
			_flick_sum += _clock - _spawned_at
			_flick_n += 1
			_spawn_mode()
		"track":
			_count(head)
			(unit as Bot).kick = _f("bot_flinch") * 0.5
		"bots":
			var b := unit as Bot
			if b == null or not b.alive:
				return
			_count(head)
			var d := dmg if head else dmg * _f("hitgroup_" + group)  # Weapons already applied the weapon's headshot multiplier
			d = minf(d, b.hp)
			if b.first_hit < 0.0:
				b.first_hit = _clock
			b.hp -= d
			_damage += d
			b.kick = _f("bot_flinch")
			if b.hp <= 0.0:
				_kill(b, head)

## One hit per shot at most (a shotgun through two bots is still one shot that hit), so accuracy stays <= 100%.
func _count(head: bool) -> void:
	if _hit_shot == _shots:
		if head and not _head_shot:
			_heads += 1
			_head_shot = true
		return
	_hit_shot = _shots
	_head_shot = head
	_hits += 1
	if head:
		_heads += 1

func _kill(b: Bot, head: bool) -> void:
	b.alive = false
	b.down_at = _clock
	_kills += 1
	if head:
		_hs_kills += 1
	_ttk.append(_clock - b.first_hit)
	b.first_hit = -1.0
	_set_live(b, false)
	_feed_add(b.tag, head)

func _set_live(b: Bot, live: bool) -> void:
	for o in b.bodies:
		(o as CollisionObject3D).collision_layer = 1 if live else 0

## Downed bots tip over backwards, then stand back up after bot_respawn_s on the round clock.
func _tick_bots(dt: float) -> void:
	var fall_s := maxf(_f("bot_fall_s"), 0.01)
	for t in _targets:
		var b := t as Bot
		if b == null or not is_instance_valid(b):
			continue
		b.kick = move_toward(b.kick, 0.0, dt * 1.2)
		var fall := 0.0
		if not b.alive:
			var since := _clock - b.down_at
			fall = clampf(since / fall_s, 0.0, 1.0)
			fall = fall * fall
			if since >= _f("bot_respawn_s") and _state == "round":
				b.alive = true
				b.hp = b.hp_max
				b.kick = 0.0
				fall = 0.0
				_set_live(b, true)
		b.pose.rotation.x = -(b.kick + fall * PI * 0.5)

func _feed_add(victim: String, head: bool) -> void:
	var p := _pc(_feed, 0.72, Color(0.85, 0.12, 0.1))
	p.size_flags_horizontal = Control.SIZE_SHRINK_END
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	p.add_child(hb)
	_lab(hb, 15, FEED_PLAYER, HORIZONTAL_ALIGNMENT_LEFT, "You")
	_lab(hb, 15, Color(0.9, 0.9, 0.9), HORIZONTAL_ALIGNMENT_LEFT, _weapon_name(String(main.weapons.held()) if main.weapons else "").to_upper())
	if head:
		_lab(hb, 15, Color(1, 0.85, 0.4), HORIZONTAL_ALIGNMENT_LEFT, "HS")
	_lab(hb, 15, FEED_BOT, HORIZONTAL_ALIGNMENT_LEFT, victim)
	_feed_items.append([p, _clock + _f("killfeed_s")])
	while _feed_items.size() > int(_f("killfeed_n")):
		(_feed_items.pop_front()[0] as Node).queue_free()

func _tick_feed() -> void:
	while not _feed_items.is_empty() and float(_feed_items[0][1]) <= _clock:
		(_feed_items.pop_front()[0] as Node).queue_free()

# --- targets ---

func _clear() -> void:
	for t in _targets:
		if is_instance_valid(t):
			t.queue_free()
	_targets.clear()

func _spawn_mode() -> void:
	_clear()
	match mode:
		"flick": _spawn_flick()
		"track": _spawn_track()
		"bots": _spawn_bots()

func _target(unit: Node3D, shape: Shape3D, mesh: Mesh, mat: Material, xf: Transform3D, head: bool, group: String, parent: Node3D) -> AimTarget:
	var tb := AimTarget.new()
	tb.lobby = self
	tb.unit = unit if unit != null else tb
	tb.is_head = head
	tb.group = group
	tb.transform = xf
	tb.add_to_group("aim_target")
	tb.set_meta("head", head)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	tb.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	tb.add_child(cs)
	parent.add_child(tb)
	return tb

func _sphere(r: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	return m

func _spawn_flick() -> void:
	var dr: Array = V["flick_dist"]
	var yr: Array = V["flick_y"]
	var hx := _f("lane_count") * _f("lane_width") * 0.5 - 1.0
	var r := _f("flick_radius")
	var z := _f("firing_line_z") - _rng.randf_range(float(dr[0]), float(dr[1]))
	var at := center + Vector3(_rng.randf_range(-hx, hx), _rng.randf_range(float(yr[0]), float(yr[1])), z)
	var shape := SphereShape3D.new()
	shape.radius = r
	var t := _target(null, shape, _sphere(r), _flat(_col("color_flick"), 1.0), Transform3D(Basis(), at), false, "head", self)
	_targets.append(t)
	_spawned_at = _clock

func _spawn_track() -> void:
	_targets.append(_bot(Vector3(0, 0, _f("firing_line_z") - _f("track_distance")), 0.0, 1, "BOT"))
	_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	_flip = _flip_in()

func _flip_in() -> float:
	var r: Array = V["track_flip_s"]
	return _rng.randf_range(float(r[0]), float(r[1]))

func _spawn_bots() -> void:
	var i := 0
	for s in V["bot_spots"]:
		var a: Array = s
		i += 1
		var at := Vector3(_lane_x(float(a[0])) + float(a[2]), float(a[4]), _f("firing_line_z") - float(a[1]))
		_targets.append(_bot(at, _rng.randf_range(-1.0, 1.0) * _f("bot_yaw_jitter"), int(a[3]), "BOT %02d" % i))

# --- humanoid bots ---

## A sheet part or prop in the bot frame (metres): [transform, mesh, collision shape or null].
func _shape_of(r: Dictionary) -> Array:
	var a := _a3(r["a"]) * H
	var b := _a3(r["b"]) * H
	var rad := float(r["r"]) * H
	match String(r["shape"]):
		"sphere":
			var ss := SphereShape3D.new()
			ss.radius = rad
			var sm := _sphere(rad)
			var st := float(r["b"][1])
			if st > 0.0:
				sm.height = rad * 2.0 * st  # stretched mesh, round hitbox
			return [Transform3D(Basis(), a), sm, ss]
		"box":
			var bm := BoxMesh.new()
			bm.size = b
			var bs := BoxShape3D.new()
			bs.size = b
			return [Transform3D(Basis(), a), bm, bs]
		"cylinder":
			var cm := CylinderMesh.new()
			cm.top_radius = rad
			cm.bottom_radius = rad
			cm.height = b.y
			return [Transform3D(Basis(), a), cm, null]
	# capsule from a to b
	var d := b - a
	var y := d.normalized() if d.length() > 0.0001 else Vector3.UP
	var x := y.cross(Vector3.BACK if absf(y.dot(Vector3.BACK)) < 0.99 else Vector3.RIGHT).normalized()
	var mesh := CapsuleMesh.new()
	mesh.radius = rad
	mesh.height = d.length() + rad * 2.0
	var cs := CapsuleShape3D.new()
	cs.radius = rad
	cs.height = mesh.height
	return [Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5), mesh, cs]

func _cloth_tex(normal: bool) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	n.frequency = 0.18
	n.fractal_octaves = 3
	var t := NoiseTexture2D.new()
	t.width = 128
	t.height = 128
	t.seamless = true
	t.noise = n
	if normal:
		t.as_normal_map = true
		t.bump_strength = 3.0
	else:
		var cn: Array = V["cloth_noise"]
		var g := Gradient.new()
		g.set_color(0, Color(float(cn[0]), float(cn[0]), float(cn[0])))
		g.set_color(1, Color(float(cn[1]), float(cn[1]), float(cn[1])))
		t.color_ramp = g
	return t

## One material per outfit slot; cloth gets the procedural weave, metal the course's metal texture.
func _slot_mat(outfit: int, slot: String) -> Material:
	var key := "%d/%s" % [outfit, slot]
	if _mats.has(key):
		return _mats[key]
	var o: Dictionary = S["outfits"][outfit]
	var m: StandardMaterial3D
	match slot:
		"gun_metal":
			m = _flat(_col("color_gun_metal"), 0.0, 0.45)
			m.metallic = 0.6
		"gun_wood":
			m = _flat(_col("color_gun_wood"), 0.0, 0.7)
		"metal":
			m = _mat(String(V["trim_material"]))
			m.uv1_world_triplanar = false
			m.uv1_scale = Vector3.ONE * 2.0
			m.albedo_color = _c(o["metal"])
		"skin", "eyes", "hair":
			m = _flat(_c(o[slot]), 0.0, 0.75 if slot == "skin" else 0.9)
		_:
			m = _flat(_c(o[slot]), 0.0, 0.95)
			if not _mats.has("cloth"):
				_mats["cloth"] = [_cloth_tex(false), _cloth_tex(true)]
			m.albedo_texture = _mats["cloth"][0]
			m.normal_enabled = true
			m.normal_texture = _mats["cloth"][1]
			m.uv1_triplanar = true
			m.uv1_scale = Vector3.ONE * 6.0
	_mats[key] = m
	return m

## A standing humanoid facing the firing line: every sheet part is its own hittable body in its hitgroup
## (the head with is_head=true), all sharing the bot as unit; props ride on parts so they fall with them.
func _bot(at: Vector3, yaw_deg: float, outfit: int, tag: String) -> Bot:
	outfit = clampi(outfit, 0, S["outfits"].size() - 1)
	var o: Dictionary = S["outfits"][outfit]
	var b := Bot.new()
	b.tag = tag
	b.hp = _f("bot_hp")
	b.hp_max = b.hp
	b.position = center + at
	b.rotation_degrees.y = yaw_deg
	b.pose = Node3D.new()
	b.add_child(b.pose)
	add_child(b)
	var by_id := {}
	for r in S["parts"]:
		var s := _shape_of(r)
		var tb := _target(b, s[2], s[1], _slot_mat(outfit, String(r["slot"])), s[0], String(r["group"]) == "head", String(r["group"]), b.pose)
		b.bodies.append(tb)
		by_id[String(r["id"])] = tb
	var head_gear := String(o["head"])
	for r in S["props"]:
		var when := String(r["when"])
		if not (when == "always" or (when == "face" and head_gear != "wrap") or when == head_gear or when == String(o["chest"])):
			continue
		var on: Node3D = by_id.get(String(r["on"]))
		if on == null:
			continue
		var s := _shape_of(r)
		var mi := MeshInstance3D.new()
		mi.mesh = s[1]
		mi.material_override = _slot_mat(outfit, String(r["slot"]))
		mi.transform = on.transform.affine_inverse() * (s[0] as Transform3D)
		on.add_child(mi)
	return b

func _physics_process(dt: float) -> void:
	if not (active and _state == "round" and mode == "track" and _targets.size() > 0) or _paused():
		return
	var t := _targets[0]
	if not is_instance_valid(t):
		return
	var half := _f("track_half_range")
	_flip -= dt
	if _flip <= 0.0:
		_dir = -_dir
		_flip = _flip_in()
	var x: float = t.position.x - center.x + _dir * _f("track_speed_u") * float(M["unit_to_m"]) * dt
	if absf(x) > half:
		x = clampf(x, -half, half)
		_dir = -signf(x)
	t.position.x = center.x + x
	# time on target: the crosshair on the bot with the trigger held, from behind the line
	if Input.is_action_pressed("surf_attack") and _behind_line():
		var cam: Camera3D = main.player.cam
		var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position - cam.global_basis.z * 200.0)
		q.exclude = [main.player.get_rid()]
		var r := cam.get_world_3d().direct_space_state.intersect_ray(q)
		if r.get("collider") is AimTarget and (r["collider"] as AimTarget).unit == t:
			_on_target += dt

# --- --lobbytest: the scoring rules, checked headless ---

func _check(what: String, ok: bool, got: Variant) -> bool:
	print("LTEST %s %s (%s)" % ["PASS" if ok else "FAIL", what, str(got)])
	return ok

func _part(b: Bot, id: String) -> AimTarget:
	var i := 0
	for r in S["parts"]:
		if String(r["id"]) == id:
			return b.bodies[i]
		i += 1
	return null

func _selftest() -> void:
	for i in 5:
		await get_tree().process_frame
	var had_best := FileAccess.file_exists(String(V["best_file"]))
	mode = "bots"
	toggle()
	await get_tree().process_frame
	var ok := _check("round running", _state == "round", _state)
	ok = _check("bots spawned", _targets.size() == V["bot_spots"].size(), _targets.size()) and ok
	var b0 := _targets[0] as Bot
	var b1 := _targets[1] as Bot
	var b2 := _targets[2] as Bot
	_part(b0, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("hit with no shot ignored", _hits == 0 and b0.hp == 100.0, _stats_line()) and ok
	on_shot_fired()
	_part(b0, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("headshot kill", _kills == 1 and _hs_kills == 1 and _hits == 1 and not b0.alive, _stats_line()) and ok
	on_shot_fired()
	_part(b1, "thigh_l").hit(100.0, false, Vector3.ZERO)
	ok = _check("legs x0.75", is_equal_approx(b1.hp, 25.0), b1.hp) and ok
	_part(b2, "chest").hit(30.0, false, Vector3.ZERO)
	ok = _check("two bots in one shot = one hit", _hits == 2 and _shots == 2, _stats_line()) and ok
	await get_tree().process_frame
	await get_tree().process_frame
	on_shot_fired()
	_part(b1, "stomach").hit(20.0, false, Vector3.ZERO)
	ok = _check("stomach x1.25 kill, ttk > 0", _kills == 2 and _hs_kills == 1 and _ttk.size() == 2 and _ttk[1] > 0.0, "ttk %.3f" % (_ttk[1] if _ttk.size() > 1 else -1.0)) and ok
	on_shot_fired()
	_part(b0, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("dead bot ignored", _kills == 2 and _hits == 3, _stats_line()) and ok
	on_shot_fired()
	on_shot_fired()
	ok = _check("misses cost points", _score() == 2 * 100 + 50 - 3 * 10, _score()) and ok
	var p: SurfPlayer = main.player
	p.global_position.z = center.z + _f("firing_line_z") - 2.0
	on_shot_fired()
	_part(b2, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("shot from past the line ignored", _kills == 2 and b2.alive, _stats_line()) and ok
	p.global_position = spawn_pos()
	var t0 := Time.get_ticks_msec()
	while not b0.alive and Time.get_ticks_msec() - t0 < 6000:
		await get_tree().process_frame
	ok = _check("bot stands back up", b0.alive and b0.hp == b0.hp_max and (b0.bodies[0] as CollisionObject3D).collision_layer == 1, b0.alive) and ok
	_left = 0.01
	await get_tree().process_frame
	await get_tree().process_frame
	ok = _check("summary", _state == "summary" and _summary.visible and _targets.is_empty(), _sum_body.text.replace("\n", " | ")) and ok
	on_shot_fired()
	ok = _check("no shots after the round", _shots == 7, _shots) and ok
	_quick = false
	_start_round()
	on_shot_fired()
	ok = _check("countdown first, shots not counted", _state == "countdown" and _shots == 0 and _left > 0.0, "%.1f s left" % _left) and ok
	t0 = Time.get_ticks_msec()
	while _state == "countdown" and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	ok = _check("round starts after the countdown", _state == "round" and absf(took - _f("countdown_s")) < 0.5, "%.2f s" % took) and ok
	ok = _check("test run wrote no best file", FileAccess.file_exists(String(V["best_file"])) == had_best, had_best) and ok
	print("LTEST ", "ALL PASS" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)
