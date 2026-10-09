## systems.aim_lobby: the aim-train arena. Contract for weapons: raycast from the camera and, when
## collider.has_method("hit"), call collider.hit(damage, head, point). Call lobby.on_shot_fired() once per shot.
class_name AimLobby
extends Node3D

var main: Node
var active := false
var mode := "bots"
var modes: Array = []

var V := {}
var M := Sheets.movement()
var content: Content
var center := Vector3.ZERO
var _state := "idle"   # idle | round | summary
var _left := 0.0
var _gen := 0
var _hits := 0
var _heads := 0
var _shots := 0
var _react_sum := 0.0
var _react_n := 0
var _spawned_at := 0.0
var _best := {}
var _targets: Array[Node3D] = []
var _dir := 1.0
var _flip := 0.0
var _rng := RandomNumberGenerator.new()
var _label: Label
var _summary: Label

## Every hittable body: group "aim_target", hit(dmg, head, at). A bot's head sphere is its own body with head=true.
class AimTarget extends StaticBody3D:
	var lobby: AimLobby
	var unit: Node3D
	var is_head := false

	func hit(dmg: float, head: bool, at: Vector3) -> void:
		lobby.register_hit(unit, dmg, head or is_head, at)

func build(c: Content, m: Node) -> void:
	main = m
	content = c
	V = Sheets.values("aim_lobby")
	modes = Sheets.load_sheet("aim_lobby")["modes"]
	center = _v3("center")
	mode = String(modes[0]["id"])
	var ua := OS.get_cmdline_user_args()
	if ua.find("--lobby-mode") >= 0:
		mode = ua[ua.find("--lobby-mode") + 1]
	_rng.randomize()
	_best = _load_best()
	_input_action()
	_arena()
	_hud()
	_spawn_mode()

func _f(k: String) -> float:
	return float(V[k])

func _v3(k: String) -> Vector3:
	var a: Array = V[k]
	return Vector3(a[0], a[1], a[2])

func _col(k: String) -> Color:
	var a: Array = V[k]
	return Color(a[0], a[1], a[2])

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
	var p: SurfPlayer = main.player
	if not active:
		active = true
		p.teleport(spawn_pos(), _f("spawn_yaw"))
		p.pitch = 0.0
		p.cam.rotation_degrees.x = 0.0
		main.timer.reset()
		main.ghost.stop_run(false)
		_start_round()
	else:
		active = false
		_state = "idle"
		_gen += 1
		_label.visible = false
		_summary.visible = false
		_clear()
		main.hud.message("aim lobby closed, round not saved", 2.0)
		main.course.restart(p)
		main.timer.reset()
		main.ghost.stop_run(false)

# --- arena ---

func _mat(id: String, size: float) -> Material:
	var base: StandardMaterial3D = main.course.materials.get(id)
	if base == null:
		return StandardMaterial3D.new()
	var mat: StandardMaterial3D = base.duplicate()
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE / float(main.course.uv_scales[id])
	return mat

func _flat(c: Color, emit: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = 0.6
	if emit > 0.0:
		mat.emission_enabled = true
		mat.emission = c
		mat.emission_energy_multiplier = emit
	return mat

## A box centred at c with the given size; solid unless solid is false.
func _box(c: Vector3, size: Vector3, mat: Material, solid: bool = true) -> void:
	var body := StaticBody3D.new()
	body.position = c
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

func _arena() -> void:
	var sz: Array = V["arena_size"]
	var sx := float(sz[0])
	var sz_z := float(sz[1])
	var wh := _f("wall_height")
	var t := _f("wall_thickness")
	var g := _f("ground_size")
	_box(center + Vector3(0, -1.55, 0), Vector3(g, 1.0, g), _mat(String(V["ground_material"]), g))
	_box(center + Vector3(0, -t * 0.5, 0), Vector3(sx, t, sz_z), _mat(String(V["floor_material"]), sx))
	var wm := _mat(String(V["wall_material"]), sx)
	_box(center + Vector3(0, wh * 0.5, -sz_z * 0.5 - t * 0.5), Vector3(sx + t * 2.0, wh, t), wm)
	_box(center + Vector3(0, wh * 0.5, sz_z * 0.5 + t * 0.5), Vector3(sx + t * 2.0, wh, t), wm)
	for s in [-1.0, 1.0]:
		_box(center + Vector3(s * (sx * 0.5 + t * 0.5), wh * 0.5, 0), Vector3(t, wh, sz_z), wm)
	var cm := _mat(String(V["cover_material"]), 3.0)
	for r in V["cover"]:
		var a: Array = r
		_box(center + Vector3(a[0], float(a[3]) * 0.5, a[1]), Vector3(a[2], a[3], a[4]), cm)
	var spawn_z := _v3("spawn_offset").z
	var lane := _flat(_col("color_lane"), 0.3)
	for d in V["bot_distances"]:
		_box(center + Vector3(0, 0.01, spawn_z - float(d)), Vector3(sx - 2.0, 0.02, 0.25), lane, false)

# --- hud ---

func _hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_label = _text(layer, 22, Control.PRESET_TOP_WIDE, 14.0)
	_summary = _text(layer, 30, Control.PRESET_FULL_RECT, 0.0)
	_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.visible = false
	_summary.visible = false

func _text(layer: CanvasLayer, size: int, preset: Control.LayoutPreset, top: float) -> Label:
	var l := Label.new()
	l.set_anchors_and_offsets_preset(preset)
	l.offset_top = top
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 8)
	layer.add_child(l)
	return l

func _acc() -> float:
	return 100.0 * _hits / maxf(_shots, 1)

func _hs() -> float:
	return 100.0 * _heads / maxf(_hits, 1)

func _react_ms() -> float:
	return 1000.0 * _react_sum / maxf(_react_n, 1)

func _score() -> int:
	return _hits * int(_f("points_hit")) + _heads * int(_f("points_head"))

func _stats_line() -> String:
	var s := "hits %d  shots %d  acc %.0f%%" % [_hits, _shots, _acc()]
	if mode == "bots":
		s += "  hs %.0f%%" % _hs()
	if mode == "flick" and _react_n > 0:
		s += "  react %.0f ms" % _react_ms()
	return s

func _mode_label() -> String:
	for r in modes:
		if r["id"] == mode:
			return String(r["label"])
	return mode.to_upper()

# --- rounds ---

func _process(dt: float) -> void:
	if not active:
		return
	if Input.is_action_just_pressed("surf_lobby_mode"):
		var i := 0
		for k in modes.size():
			if modes[k]["id"] == mode:
				i = k
		mode = String(modes[(i + 1) % modes.size()]["id"])
		_start_round()
	if main.settings and main.settings.is_open:
		_spawned_at += dt  # the Esc menu pauses the round and the reaction clock
		return
	if _state == "round":
		_left -= dt
		if _left <= 0.0:
			_end_round()
		else:
			_label.text = "%s   %02d s   %s   score %d   best %d\n[M] next mode" % [_mode_label(), ceili(_left), _stats_line(), _score(), int(_best.get(mode, 0))]
	elif _state == "summary":
		_left -= dt
		if _left <= 0.0:
			_start_round()

func _start_round() -> void:
	_gen += 1
	_hits = 0
	_heads = 0
	_shots = 0
	_react_sum = 0.0
	_react_n = 0
	_left = _f("round_s")
	_state = "round"
	_summary.visible = false
	_label.visible = true
	_spawn_mode()

func _end_round() -> void:
	_state = "summary"
	_left = _f("summary_s")
	var score := _score()
	var new_best := score > int(_best.get(mode, 0))
	if new_best:
		_best[mode] = score
		_save_best()
	_label.text = "%s   round over" % _mode_label()
	_summary.text = "%s\nscore %d%s\n%s" % [_mode_label(), score, "   NEW BEST" if new_best else "   best %d" % int(_best.get(mode, 0)), _stats_line()]
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
	if f:
		f.store_string(JSON.stringify(_best))

## Weapons calls this for every shot, hit or miss.
func on_shot_fired() -> void:
	if active and _state == "round":
		_shots += 1

## Called by AimTarget.hit(). unit is the target root (bot body, flick or track target).
func register_hit(unit: Node3D, dmg: float, head: bool, _at: Vector3) -> void:
	if not active or _state != "round" or not is_instance_valid(unit) or not _targets.has(unit):
		return
	match mode:
		"flick":
			_react_sum += Time.get_ticks_msec() * 0.001 - _spawned_at
			_react_n += 1
			_count(false)
			_spawn_mode()
		"track":
			_count(false)
		"bots":
			_count(head)
			var hp := float(unit.get_meta("hp")) - dmg
			unit.set_meta("hp", hp)
			if hp <= 0.0:
				_down(unit)

func _count(head: bool) -> void:
	_hits += 1
	if head:
		_heads += 1

func _down(unit: Node3D) -> void:
	_set_live(unit, false)
	var gen := _gen
	get_tree().create_timer(_f("bot_respawn_s")).timeout.connect(func() -> void:
		if gen == _gen and is_instance_valid(unit):
			unit.set_meta("hp", unit.get_meta("hp_max"))
			_set_live(unit, true))

func _set_live(unit: Node3D, live: bool) -> void:
	unit.visible = live
	for b in [unit] + unit.get_children().filter(func(n: Node) -> bool: return n is CollisionObject3D):
		(b as CollisionObject3D).collision_layer = 1 if live else 0

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

func _target(unit: Node3D, shape: Shape3D, mesh: Mesh, mat: Material, at: Vector3, head: bool, parent: Node3D) -> AimTarget:
	var tb := AimTarget.new()
	tb.lobby = self
	tb.unit = unit if unit != null else tb
	tb.is_head = head
	tb.position = at
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
	var sz: Array = V["arena_size"]
	var yr: Array = V["flick_y"]
	var hx := float(sz[0]) * 0.5 - _f("flick_margin")
	var r := _f("flick_radius")
	var wall_z := -float(sz[1]) * 0.5
	var at := center + Vector3(_rng.randf_range(-hx, hx), _rng.randf_range(float(yr[0]), float(yr[1])), wall_z + _f("flick_gap"))
	var shape := SphereShape3D.new()
	shape.radius = r
	var t := _target(null, shape, _sphere(r), _flat(_col("color_flick"), 1.0), at, true, self)
	_targets.append(t)
	_spawned_at = Time.get_ticks_msec() * 0.001

func _bot_shape() -> CapsuleShape3D:
	var s := CapsuleShape3D.new()
	s.radius = float(M["hull_width"]) * 0.5
	s.height = float(M["hull_height"]) - _f("bot_head_radius") * 2.0
	return s

func _capsule_mesh(s: CapsuleShape3D) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = s.radius
	m.height = s.height
	return m

func _spawn_track() -> void:
	var s := _bot_shape()
	var z := _v3("spawn_offset").z - _f("track_distance")
	var t := _target(null, s, _capsule_mesh(s), _flat(_col("color_track"), 0.6), center + Vector3(0, s.height * 0.5, z), true, self)
	_targets.append(t)
	_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	_flip = _flip_in()

func _flip_in() -> float:
	var r: Array = V["track_flip_s"]
	return _rng.randf_range(float(r[0]), float(r[1]))

func _spawn_bots() -> void:
	var s := _bot_shape()
	var dist: Array = V["bot_distances"]
	var xs: Array = V["bot_x"]
	var hr := _f("bot_head_radius")
	var hs := SphereShape3D.new()
	hs.radius = hr
	for i in dist.size():
		var at := center + Vector3(float(xs[i]), 0, _v3("spawn_offset").z - float(dist[i]))
		var body := _target(null, s, _capsule_mesh(s), _flat(_col("color_bot")), at + Vector3(0, s.height * 0.5, 0), false, self)
		body.set_meta("hp", _f("bot_hp"))
		body.set_meta("hp_max", _f("bot_hp"))
		var head := _target(body, hs, _sphere(hr), _flat(_col("color_head"), 0.5), Vector3(0, float(M["hull_height"]) - hr - s.height * 0.5, 0), true, body)
		head.set_meta("head", true)
		_targets.append(body)

func _physics_process(dt: float) -> void:
	if not (active and _state == "round" and mode == "track" and _targets.size() > 0):
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
