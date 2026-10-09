## systems.aim_lobby: the aim range. Humanoid bots built from primitives (sheet 'parts' and 'props'), CS2
## hitgroups, numbered lanes, distance markers, a 3-2-1 countdown, rounds, kills, time-to-kill and a stats panel.
## Contract for weapons: raycast from the camera and, when collider.has_method("hit"), call
## collider.hit(damage, head, point). Call lobby.on_shot_fired() once per shot, before that shot's hits.
class_name AimLobby
extends Node3D

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
var _shot_weapon := ""   # the weapon that fired the current shot: its hits use its armor ratio, not whatever is held later
var _kills := 0
var _hs_kills := 0
var _damage := 0.0
var _ttk: Array[float] = []        # per bot: from the shot that first hit it to the kill
var _gaps: Array[float] = []       # kill interval: from the later of the bot standing up and the previous kill
var _flick_sum := 0.0
var _flick_n := 0
var _on_target := 0.0
var _last_shot_at := 0.0   # round clock of the latest shot
var _last_kill_at := 0.0   # round clock of the previous kill: the kill interval counts from it or the bot's stand-up
var _last_kill_shot := -1
var _used := {}
var _spawned_at := 0.0
var _pause_now := -1.0     # Weapons' clock when the last paused frame ran, -1 while not paused
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
var _hint: Control
var _summary: PanelContainer
var _sum_title: Label
var _sum_grid: GridContainer
var _sum_body: Label
var _layer: CanvasLayer

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
## kevlar is the lobby's own name for its armour: Weapons only armours targets with an 'armor' property and
## would split before the hitgroup scale, so the lobby does CS's order itself (hitgroup, then armour).
class Bot extends Node3D:
	var hp := 100.0
	var hp_max := 100.0
	var kevlar := 0.0
	var helmet := false
	var first_hit_at := -1.0
	var last_hit_at := -1.0
	var alive := true
	var up_at := 0.0
	var down_at := 0.0
	var kick := 0.0
	var phase := 0.0       # idle sway offset, so the range never moves in step
	var fall_side := 1.0   # which way a downed bot twists as it falls
	var tag := ""
	var pose: Node3D
	var head: Node3D        # the head body: it looks around on its own while the bot idles
	var bodies: Array = []

func build(c: Content, m: Node) -> void:
	main = m
	content = c
	S = Sheets.load_sheet("aim_lobby")
	V = Sheets.values("aim_lobby")
	modes = S["modes"]
	# the range has its own frame: origin at the sheet centre, turned range_yaw so the sun lights the bots'
	# faces. Everything below is placed in that frame (center stays zero); player checks go through to_local.
	position = _v3("center")
	rotation_degrees.y = _f("range_yaw")
	center = Vector3.ZERO
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
	return to_global(_v3("spawn_offset"))

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
		p.teleport(spawn_pos(), _f("spawn_yaw") + _f("range_yaw"))
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
				if main.get("shots_running") == true and main.viewmodel:
					main.viewmodel.idle()  # a Gauntlet capture shows the gun held, not mid-draw
			return
	main.hud.message("no CS2 gun exported yet: run prep on your PC (B opens the buy menu)", 4.0)

## Weapons times draws, bolts, reloads, shells and the Zeus charge on its own clock. While the round clock
## stands still (Esc menu, buy menu) every pending timer is pushed back by however far that clock ran, so a
## pause never finishes a reload or a bolt for free. A weapons clock that stops by itself moves nothing here.
const WEAPON_TIMERS := ["_next_fire", "_reload_until", "_shell_next", "_toggle_until", "_burst_at", "_dry_at", "_part_at"]

func _hold_weapon_clock(paused: bool) -> void:
	var w: Node = main.weapons
	if w == null or not paused or not w.has_method("_now"):
		_pause_now = -1.0
		return
	var now := float(w.call("_now"))
	if _pause_now >= 0.0 and now > _pause_now:
		var d := now - _pause_now
		for k in WEAPON_TIMERS:
			var v: Variant = w.get(k)
			if v is float and float(v) > _pause_now:
				w.set(k, float(v) + d)
		var rc: Variant = w.get("_recharge")
		if rc is Dictionary:
			for id in (rc as Dictionary).keys():
				if float(rc[id]) > _pause_now:
					rc[id] = float(rc[id]) + d
		var cock: Variant = w.get("_cock")
		if cock is float and float(cock) >= 0.0:
			w.set("_cock", float(cock) + d)  # an R8 hammer pull keeps the part it had already done
	_pause_now = now

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

## The round clock stands still whenever Weapons blocks the trigger: the Esc menu, the buy menu, or a frozen
## player (a Gauntlet capture freezes the camera but keeps the range live).
func _paused() -> bool:
	if main.settings != null and main.settings.is_open:
		return true
	var w: Node = main.weapons
	if w != null and w.get("_buy") is CanvasLayer and (w.get("_buy") as CanvasLayer).visible:
		return true
	return main.player != null and main.player.frozen and main.get("shots_running") != true

func _inside_arena(at: Vector3) -> bool:
	var sz: Array = V["arena_size"]
	var l := to_local(at)
	return absf(l.x) < float(sz[0]) * 0.5 + 5.0 and absf(l.z) < float(sz[1]) * 0.5 + 5.0 and l.y > -5.0 and l.y < _f("wall_height") + 30.0

func _behind_line() -> bool:
	return to_local(main.player.global_position).z >= _f("firing_line_z")

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

## A see-through black that fades from alpha a at UV 'from' to nothing at UV 'to' (floor contact shade).
func _shade(a: float, from: Vector2, to: Vector2) -> StandardMaterial3D:
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, a))
	g.set_color(1, Color(0, 0, 0, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 64
	gt.height = 64
	gt.fill_from = from
	gt.fill_to = to
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = gt
	return m

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

## The walls' own concrete: the wall material's Rust texture with tonal variation, pour lines every
## wall_lift_m, grime streaks and Rust's own leak decals (course.json weathering atlas) running down from the
## top edge (UV is metres along / up the wall, UV2.x metres below the top).
const WALL_SHADER := "shader_type spatial;
uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_tex = false;
uniform bool has_nrm = false;
uniform vec3 base = vec3(0.6);
uniform float scale = 5.0;
uniform float grime = 0.6;
uniform float lift = 1.5;
uniform float rough = 0.85;
uniform vec3 grid_col = vec3(0.86);
uniform float grid_m = 1.0;
uniform float grid_major = 5.0;
uniform float grid_a = 0.2;
uniform sampler2D tex_leak : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_leak = false;
uniform float leaks = 0.0;
uniform vec2 leak_v = vec2(0.607, 0.925);
uniform float leak_len = 4.0;
uniform float leak_width = 5.0;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) { s += a * vn(p); p = p * 2.03 + vec2(17.1, 9.2); a *= 0.5; }
	return s / 0.9375;
}
// a band of the leak atlas, as Course.gd's ramps read it: v from v0 at t = 0 to v1 at t = 1, u in
// leak_width tiles that each pick the atlas's left (moss) or right (rust) half; colour from a blurred mip
vec4 band(vec2 v, float u, float t, float seed) {
	float tile = floor(u);
	float hf = step(0.5, hash(vec2(tile, seed)));
	vec2 at = vec2((fract(u) * 0.96 + 0.02) * 0.5 + hf * 0.5, mix(v.x, v.y, clamp(t, 0.0, 1.0)));
	vec2 g = vec2(u * 0.5, mix(v.x, v.y, t)) * vec2(textureSize(tex_leak, 0));
	float lod = log2(max(max(length(dFdx(g)), length(dFdy(g))), 1.0)) + 0.5;
	vec4 soft = textureLod(tex_leak, at, lod + 2.5);
	float a = smoothstep(0.45, 0.9, textureLod(tex_leak, at, lod + 1.5).a);
	return vec4(clamp(soft.rgb / max(soft.a, 0.1), 0.0, 1.0), a);
}
void fragment() {
	vec2 m = UV;
	vec2 uv = m / scale;
	vec3 c = has_tex ? texture(tex, uv).rgb : base;
	c *= mix(0.8, 1.08, fbm(m / 9.0 + vec2(4.0, 1.0)));
	float d = abs(fract(m.y / lift + 0.5) - 0.5) * lift;
	c *= 1.0 - 0.22 * (1.0 - smoothstep(0.008, 0.03, d));
	float top = UV2.x;
	float streak = smoothstep(0.45, 0.85, fbm(vec2(m.x * 1.4, top * 0.06) + vec2(3.0, 7.0)));
	float s = streak * exp(-top / 4.5) * grime;
	float lip = (1.0 - smoothstep(0.05, 0.35, top)) * grime;
	c *= 1.0 - 0.55 * s - 0.3 * lip;
	vec2 g = abs(fract(m / grid_m + 0.5) - 0.5) * grid_m;
	vec2 gM = abs(fract(m / (grid_m * grid_major) + 0.5) - 0.5) * grid_m * grid_major;
	float px = fwidth(m.x) + fwidth(m.y);
	float minor = 1.0 - smoothstep(0.004, 0.012 + px, min(g.x, g.y));
	float major = 1.0 - smoothstep(0.012, 0.03 + px, min(gM.x, gM.y));
	c = mix(c, grid_col, max(minor * 0.45, major) * grid_a * (1.0 - s * 0.6));
	float la = 0.0;
	if (has_leak) {
		float run = smoothstep(0.3, 0.55, fbm(vec2(m.x / 9.0, 3.7)));
		vec4 lk = band(leak_v, m.x / leak_width, top / leak_len, 11.0);
		la = clamp(lk.a * leaks * run * (1.0 - smoothstep(0.75, 1.0, top / leak_len)), 0.0, 1.0);
		c = mix(c, mix(lk.rgb, vec3(dot(lk.rgb, vec3(0.333))), 0.35) * 0.75, la);
	}
	ALBEDO = c;
	if (has_nrm) { NORMAL_MAP = texture(nrm, uv).rgb; }
	ROUGHNESS = mix(rough, 1.0, max(s * 0.5, la * 0.4));
}
"

func _weathered(id: String) -> Material:
	var src: StandardMaterial3D = main.course.materials.get(id)
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = WALL_SHADER
	m.shader = sh
	if src:
		m.set_shader_parameter("has_tex", src.albedo_texture != null)
		m.set_shader_parameter("tex", src.albedo_texture)
		m.set_shader_parameter("has_nrm", src.normal_texture != null)
		m.set_shader_parameter("nrm", src.normal_texture)
		m.set_shader_parameter("rough", src.roughness)
	m.set_shader_parameter("scale", float(main.course.uv_scales.get(id, 5.0)))
	m.set_shader_parameter("grime", _f("wall_grime"))
	m.set_shader_parameter("lift", _f("wall_lift_m"))
	var g: Array = V["wall_grid"]
	m.set_shader_parameter("grid_m", float(g[0]))
	m.set_shader_parameter("grid_major", float(g[1]))
	m.set_shader_parameter("grid_a", float(g[2]))
	var pc := _col("color_paint")
	m.set_shader_parameter("grid_col", Vector3(pc.r, pc.g, pc.b))
	var wt: Dictionary = Sheets.load_sheet("course")["weathering"]
	var lk: Texture2D = content.texture(String(wt["texture"]), "MainTex") if content else null
	var lw: Array = V["wall_leaks"]
	m.set_shader_parameter("has_leak", lk != null and float(lw[0]) > 0.0)
	if lk:
		m.set_shader_parameter("tex_leak", lk)
	m.set_shader_parameter("leaks", float(lw[0]))
	m.set_shader_parameter("leak_len", float(lw[1]))
	m.set_shader_parameter("leak_width", float(wt["leak_width"]))
	var lv: Array = wt["leak_v"]
	m.set_shader_parameter("leak_v", Vector2(float(lv[0]), float(lv[1])))
	return m

## One inner wall face: a quad from 'from' along 'along' for span metres, h tall, facing n.
func _face(from: Vector3, along: Vector3, span: float, h: float, n: Vector3, mat: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := [from, from + along * span, from + along * span + Vector3.UP * h, from + Vector3.UP * h]
	var top := [h, h, 0.0, 0.0]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(Vector2((p[i] as Vector3).dot(along), (p[i] as Vector3).y))
		st.set_uv2(Vector2(top[i], 1.0))
		st.add_vertex(center + p[i])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)

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
	var fh := _f("front_wall_height")  # low behind the player, so its shadow never covers the firing line
	var wm := _mat(String(V["wall_material"]))
	var tm := _mat(String(V["trim_material"]))
	var face := _weathered(String(V["wall_material"]))
	var hx := sx * 0.5
	var hz := sz_z * 0.5
	for s in [-1.0, 1.0]:
		var zh := wh if s < 0.0 else fh
		_box(Vector3(0, zh * 0.5, s * (hz + t * 0.5)), Vector3(sx + t * 2.0, zh, t), wm)
		_box(Vector3(s * (hx + t * 0.5), wh * 0.5, 0), Vector3(t, wh, sz_z), wm)
		_box(Vector3(0, zh + 0.12, s * (hz + t * 0.5)), Vector3(sx + t * 2.0 + 0.3, 0.24, t + 0.3), tm)
		_box(Vector3(s * (hx + t * 0.5), wh + 0.12, 0), Vector3(t + 0.3, 0.24, sz_z), tm)
	_face(Vector3(-hx, 0, -hz + 0.005), Vector3.RIGHT, sx, wh, Vector3.BACK, face)
	_face(Vector3(hx, 0, hz - 0.005), Vector3.LEFT, sx, fh, Vector3.FORWARD, face)
	_face(Vector3(-hx + 0.005, 0, hz), Vector3.FORWARD, sz_z, wh, Vector3.RIGHT, face)
	_face(Vector3(hx - 0.005, 0, -hz), Vector3.BACK, sz_z, wh, Vector3.LEFT, face)
	# lower band of green site panels with a metal skirting, broken by concrete pilasters with lamps
	var wn := _mat(String(V["wainscot_material"]))
	var bh := _f("wainscot_height")
	for s in [-1.0, 1.0]:
		_box(Vector3(0, bh * 0.5, s * (hz - 0.04)), Vector3(sx, bh, 0.08), wn)
		_box(Vector3(s * (hx - 0.04), bh * 0.5, 0), Vector3(0.08, bh, sz_z), wn)
		_box(Vector3(0, bh + 0.04, s * (hz - 0.07)), Vector3(sx, 0.08, 0.14), tm)
		_box(Vector3(s * (hx - 0.07), bh + 0.04, 0), Vector3(0.14, 0.08, sz_z), tm)
		_box(Vector3(0, trim * 0.5, s * (hz - 0.1)), Vector3(sx, trim, 0.12), tm)
		_box(Vector3(s * (hx - 0.1), trim * 0.5, 0), Vector3(0.12, trim, sz_z), tm)
	# contact shade on the floor along every wall foot (the corner a baked map would darken)
	var ao: Array = V["wall_ao"]
	for s in [-1.0, 1.0]:
		_paint(Vector3(0, -0.003, s * (hz - float(ao[0]) * 0.5)), sx, float(ao[0]), _shade(float(ao[1]), Vector2(0.5, 0.5 + s * 0.5), Vector2(0.5, 0.5 - s * 0.5)))
		_paint(Vector3(s * (hx - float(ao[0]) * 0.5), -0.003, 0), float(ao[0]), sz_z, _shade(float(ao[1]), Vector2(0.5 + s * 0.5, 0.5), Vector2(0.5 - s * 0.5, 0.5)))
	var pm := _mat(String(V["pilaster_material"]))
	var pw: Array = V["pilaster_size"]
	var lamp := _flat(_col("color_lamp"), 2.5, 0.4)
	var lamp_box := _flat(Color(0.12, 0.12, 0.12), 0.0, 0.5)
	var spots: Array = []  # [position, facing]
	var n := int(_f("lane_count"))
	for i in n + 1:
		spots.append([Vector3(_lane_x(i + 0.5), 0, -hz), Vector3(0, 0, 1)])
	var step := _f("pilaster_step")
	var zz := -hz + step
	while zz < hz - 1.0:
		for s in [-1.0, 1.0]:
			spots.append([Vector3(s * hx, 0, zz), Vector3(-s, 0, 0)])
		zz += step
	for sp in spots:
		var at: Vector3 = sp[0]
		var f: Vector3 = sp[1]
		var size := Vector3(float(pw[0]), wh + 0.3, float(pw[1])) if f.x == 0.0 else Vector3(float(pw[1]), wh + 0.3, float(pw[0]))
		_box(at + f * float(pw[1]) * 0.5 + Vector3(0, (wh + 0.3) * 0.5, 0), size, pm)
		var lp := at + f * (float(pw[1]) + 0.15) + Vector3(0, wh - 1.2, 0)
		_box(lp, Vector3(0.5, 0.18, 0.3) if f.x == 0.0 else Vector3(0.3, 0.18, 0.5), lamp_box, false)
		_box(lp - Vector3(0, 0.1, 0), Vector3(0.4, 0.03, 0.22) if f.x == 0.0 else Vector3(0.22, 0.03, 0.4), lamp, false)
		_lamp_light(lp - Vector3(0, 0.12, 0), f)
		_pilaster_ao(at, f, float(pw[0]), float(pw[1]), wh)
	_corner_ao(hx, hz, wh, fh)
	_stains(sx, sz_z)
	var lw := _f("lane_width")
	var fz := _f("firing_line_z")
	var back := -hz
	var pc := _col("color_paint")
	var paint := _flat(pc, 0.0, 0.85)
	var plaque := _flat(_col("color_plaque"), 0.0, 0.7)
	for i in n + 1:
		_paint(Vector3(_lane_x(i + 0.5), 0, (fz + back) * 0.5), 0.12, fz - back, paint)
	var lp: Array = V["lane_plaque"]
	var fnum := _f("lane_floor_number")
	for i in n:
		var x := _lane_x(i + 1)
		_text3d(str(i + 1), Vector3(x, 0.012, fz - fnum * 1.2), Vector3(-90, 0, 0), fnum, Color(pc, _f("floor_paint_alpha")))
		_box(Vector3(x, wh * 0.62, back + 0.06), Vector3(float(lp[0]), float(lp[1]), 0.08), plaque, false)
		_text3d(str(i + 1), Vector3(x, wh * 0.62, back + 0.12), Vector3.ZERO, float(lp[2]), pc)
	var edge := n * lw * 0.5
	var dt: Array = V["distance_text"]
	for d in V["distance_marks"]:
		var z := fz - float(d)
		_paint(Vector3(0, 0, z), n * lw, 0.1, paint)
		for s in [-1.0, 1.0]:
			_text3d("%d m" % int(d), Vector3(s * (edge + (hx - edge) * 0.5), 0.012, z + float(dt[0]) * 0.75), Vector3(-90, 0, 0), float(dt[0]), Color(pc, _f("floor_paint_alpha")))
			var py := _f("distance_plaque_y")
			_box(Vector3(s * (hx - 0.09), py, z), Vector3(0.08, float(dt[1]) * 1.4, float(dt[2])), plaque, false)
			_text3d("%d m" % int(d), Vector3(s * (hx - 0.15), py, z), Vector3(0, -90.0 * s, 0), float(dt[1]), pc)
	_paint(Vector3(0, 0.002, fz), sx, 0.18, _flat(_col("color_line"), 0.0, 0.8))
	var rh := _f("rail_height")
	_box(Vector3(0, rh * 0.5, fz - 0.4), Vector3(sx, rh, 0.4), pm)
	var cm := _mat(String(V["cover_material"]))
	for r in V["cover"]:
		var a: Array = r
		_crate(Vector3(_lane_x(float(a[0])), 0, fz - float(a[1])), Vector3(a[2], a[3], a[4]), cm, tm)
	for r in V["crate_stacks"]:
		var a: Array = r
		_crate(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), cm, tm)
	for r in V["catwalks"]:
		_catwalk(r, tm)
	var cr: Array = V["bot_crate"]
	for s in V["bot_spots"]:
		var a: Array = s
		if float(a[4]) > 0.0 and int(a[5]) == 0:  # a raised spot off the catwalks: the bot stands on a crate
			_crate(Vector3(_lane_x(float(a[0])) + float(a[2]), 0, fz - float(a[1])), Vector3(float(cr[0]), float(a[4]), float(cr[1])), cm, tm)

## A vertical shade quad on a wall (normal f) centred at c, w wide and h tall, darkest at the u = 0 edge
## when dark_left, else at u = 1 (QuadMesh u runs along UP x f).
func _wall_shade(c: Vector3, f: Vector3, w: float, h: float, a: float, dark_left: bool) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	mi.mesh = q
	mi.material_override = _shade(a, Vector2(0.0 if dark_left else 1.0, 0.5), Vector2(1.0 if dark_left else 0.0, 0.5))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.basis = Basis(Vector3.UP.cross(f), Vector3.UP, f)
	mi.position = center + c
	add_child(mi)

## Ambient occlusion a baked map would give a pilaster: the wall darkens beside it and the floor at its foot.
func _pilaster_ao(at: Vector3, f: Vector3, pw: float, pd: float, wh: float) -> void:
	var ao: Array = V["pilaster_ao"]
	var w := float(ao[0])
	var x := Vector3.UP.cross(f)
	var wall := at + f * 0.015 + Vector3(0, wh * 0.5, 0)
	_wall_shade(wall + x * (pw * 0.5 + w * 0.5), f, w, wh, float(ao[1]), true)
	_wall_shade(wall - x * (pw * 0.5 + w * 0.5), f, w, wh, float(ao[1]), false)
	for side in [-1.0, 1.0]:  # the pilaster's own sides face along the wall
		var n: Vector3 = x * side
		_wall_shade(at + f * (pd * 0.5) + x * side * (pw * 0.5 + 0.012) + Vector3(0, wh * 0.5, 0), n, pd, wh, float(ao[1]) * 0.6, side < 0.0)
	_floor_shade(at + f * (pd + w * 0.5), f, pw + w, w, float(ao[1]))

## A floor shade quad centred at c, w along the wall and d out from it (f), darkest at the wall side.
func _floor_shade(c: Vector3, f: Vector3, w: float, d: float, a: float) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(w, d)
	mi.mesh = q
	mi.material_override = _shade(a, Vector2(0.5, 1.0), Vector2(0.5, 0.0))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.basis = Basis(f.cross(Vector3.UP), f, Vector3.UP)
	mi.position = center + Vector3(c.x, 0.004, c.z)
	add_child(mi)

## The inner corners where two walls meet darken toward the seam.
func _corner_ao(hx: float, hz: float, wh: float, fh: float) -> void:
	var ao: Array = V["pilaster_ao"]
	var w := float(ao[0]) * 2.0
	for cz in [-1.0, 1.0]:
		var h := wh if cz < 0.0 else fh
		for cx in [-1.0, 1.0]:
			var fz := Vector3(0, 0, -cz)  # the end wall faces into the range
			var fx := Vector3(-cx, 0, 0)  # the side wall faces into the range
			_wall_shade(Vector3(cx * (hx - w * 0.5), h * 0.5, cz * (hz - 0.17)), fz, w, h, float(ao[1]), Vector3.UP.cross(fz).x * cx < 0.0)
			_wall_shade(Vector3(cx * (hx - 0.17), wh * 0.5, cz * (hz - w * 0.5)), fx, w, wh, float(ao[1]), Vector3.UP.cross(fx).z * cz < 0.0)

## Warm pools under the wall lamps: a downward spot aimed down the wall face, no shadows.
func _lamp_light(at: Vector3, f: Vector3) -> void:
	var ll: Array = V["lamp_light"]
	if float(ll[0]) <= 0.0:
		return
	var l := SpotLight3D.new()
	l.light_color = _col("color_lamp")
	l.light_energy = float(ll[0])
	l.spot_range = float(ll[1])
	l.spot_angle = float(ll[2])
	l.spot_attenuation = 1.2
	l.shadow_enabled = false
	l.position = center + at + f * 0.1
	l.basis = Basis.looking_at(Vector3(0, -1, 0) + f * float(ll[3]), f)
	add_child(l)

## Oil and scuff stains on the range floor: soft noise blots, placed from a fixed seed so every render matches.
func _stains(sx: float, sz: float) -> void:
	var st: Array = V["floor_stains"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(st[0])
	var n := FastNoiseLite.new()
	n.frequency = 0.035
	n.fractal_octaves = 4
	var c := _col("color_stain")
	var px := 128
	var mats: Array = []
	for k in 3:
		n.seed = k + 1
		var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
		for y in px:
			for x in px:
				var r := Vector2(x - px * 0.5 + 0.5, y - px * 0.5 + 0.5).length() / (px * 0.5)
				var v := n.get_noise_2d(x * 2.0, y * 2.0) * 0.5 + 0.5 + (0.35 - r) * 0.6
				img.set_pixel(x, y, Color(c, float(st[3]) * smoothstep(0.45, 0.75, v) * (1.0 - smoothstep(0.7, 1.0, r))))
		img.generate_mipmaps()
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = ImageTexture.create_from_image(img)
		m.roughness = float(st[4])
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mats.append(m)
	for i in int(st[1]):
		var size := rng.randf_range(float(st[2]) * 0.4, float(st[2]))
		var at := Vector3(rng.randf_range(-sx * 0.45, sx * 0.45), -0.002, rng.randf_range(-sz * 0.45, sz * 0.45))
		_paint(at, size, size * rng.randf_range(0.5, 1.0), mats[i % mats.size()])

## A crate: a panelled box standing on 'base' (relative to center) with a metal frame on its edges.
func _crate(base: Vector3, size: Vector3, mat: Material, frame: Material) -> void:
	_box(base + Vector3(0, size.y * 0.5, 0), size, mat)
	var e := _f("crate_frame")
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(base + Vector3(sx * (size.x * 0.5 - e * 0.5 + 0.01), size.y * 0.5, sz * (size.z * 0.5 - e * 0.5 + 0.01)), Vector3(e, size.y + 0.01, e), frame, false)
		_box(base + Vector3(sx * (size.x * 0.5 - e * 0.5 + 0.01), size.y - e * 0.5 + 0.005, 0), Vector3(e, e, size.z + 0.02), frame, false)
	for sz in [-1.0, 1.0]:
		_box(base + Vector3(0, size.y - e * 0.5 + 0.005, sz * (size.z * 0.5 - e * 0.5 + 0.01)), Vector3(size.x + 0.02, e, e), frame, false)

## A raised walkway along a side wall: [side -1/1, near m, far m (from the firing line), width, height].
## Concrete under a metal deck, a rail on the open edge, and a stair down at the near end.
func _catwalk(r: Array, metal: Material) -> void:
	var sx := float(V["arena_size"][0]) * 0.5
	var side := float(r[0])
	var fz := _f("firing_line_z")
	var z0 := fz - float(r[1])
	var z1 := fz - float(r[2])
	var w := float(r[3])
	var h := float(r[4])
	var x := side * (sx - w * 0.5)
	var span := z0 - z1
	var zc := (z0 + z1) * 0.5
	_box(Vector3(x, (h - 0.12) * 0.5, zc), Vector3(w, h - 0.12, span), _mat(String(V["pilaster_material"])))
	_box(Vector3(x, h - 0.06, zc), Vector3(w + 0.1, 0.12, span), metal)
	var ex := side * (sx - w) - side * 0.05
	var post := _f("catwalk_rail")
	var k := 0.0
	while k <= span + 0.01:
		_box(Vector3(ex, h + post * 0.5, z1 + k), Vector3(0.06, post, 0.06), metal)
		k += 2.0
	_box(Vector3(ex, h + post, zc), Vector3(0.07, 0.07, span), metal, false)
	_box(Vector3(ex, h + post * 0.5, zc), Vector3(0.04, 0.04, span), metal, false)
	var steps := int(ceil(h / 0.3))
	for i in steps:
		var sh := h * float(i + 1) / steps
		_box(Vector3(x, sh * 0.5, z0 + 0.35 + (steps - 1 - i) * 0.35), Vector3(w * 0.8, sh, 0.35), metal)

# --- hud ---
# CS2 look: square dark panels, team-colour strips, small uppercase captions with a soft shadow. Every size is
# a pixel at the hud.json ref_height; the whole layer scales with the window height like Hud.gd.

func _style(a: float, accent: Color = Color(0, 0, 0, 0), side: int = SIDE_TOP) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, a)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 6
	if accent.a > 0.0:
		sb.border_color = accent
		sb.set_border_width(side, 3)
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
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("shadow_outline_size", 2)
	parent.add_child(l)
	return l

func _pc(parent: Node, a: float, accent: Color = Color(0, 0, 0, 0), side: int = SIDE_TOP) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", _style(a, accent, side))
	parent.add_child(p)
	return p

## A panel that fades out to the right (CS2's side panels), with a thin accent line down its left edge.
func _fade_panel(parent: Node, a: float, accent: Color) -> PanelContainer:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.01, 0.011, 0.6, 1.0])
	g.colors = PackedColorArray([accent, accent, Color(0, 0, 0, a), Color(0, 0, 0, a * 0.7), Color(0, 0, 0, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 4
	var sb := StyleBoxTexture.new()
	sb.texture = gt
	sb.content_margin_left = 20
	sb.content_margin_right = 40
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p

func _hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_layer = layer
	_ui = Control.new()
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)
	var ct := _col("ui_ct")
	var tt := _col("ui_t")
	# top centre, CS2-style: kills | round clock | score, team-colour strips on the side boxes
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 2)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.offset_top = 8
	_ui.add_child(top)
	_top_kills = _top_box(top, "KILLS", ct)
	var mid := _pc(top, _f("ui_alpha") + 0.1)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", -6)
	mid.add_child(mv)
	_top_time = _lab(mv, 34, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_top_time.custom_minimum_size.x = 150
	_top_mode = _lab(mv, 13, GREY, HORIZONTAL_ALIGNMENT_CENTER)
	_top_score = _top_box(top, "SCORE", tt)
	# stats panel top left, where CS2 keeps the radar (the range has none)
	var panel := _fade_panel(_ui, _f("ui_alpha"), tt)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 0
	panel.offset_top = 24
	panel.custom_minimum_size = Vector2(_f("ui_panel_w"), 0)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 2)
	panel.add_child(pv)
	var fs: Array = V["ui_panel_font"]
	_panel_title = _lab(pv, int(fs[2]), tt)
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.14)
	line.custom_minimum_size = Vector2(0, 1)
	pv.add_child(line)
	for i in int(_f("ui_panel_rows")) + 1:
		var hb := HBoxContainer.new()
		pv.add_child(hb)
		var nl := _lab(hb, int(fs[0]), GREY)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var vl := _lab(hb, int(fs[1]), Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
		_rows.append([hb, nl, vl])
	# kill feed, top right like CS2
	_feed = VBoxContainer.new()
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_feed.offset_top = 70
	_feed.offset_right = -20
	_feed.add_theme_constant_override("separation", 4)
	_ui.add_child(_feed)
	_big = _lab(_ui, 150, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_big.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_big.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_big.grow_vertical = Control.GROW_DIRECTION_BOTH
	_big.offset_top = -230
	_warn = _lab(_ui, 22, Color(1, 0.35, 0.3), HORIZONTAL_ALIGNMENT_CENTER, "GET BEHIND THE YELLOW LINE: SHOTS FROM HERE DON'T COUNT")
	_warn.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_warn.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_warn.offset_top = 80
	# key hints, bottom centre above the CS2 bottom bar
	var hints := HBoxContainer.new()
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.add_theme_constant_override("separation", 22)
	hints.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hints.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hints.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hints.offset_bottom = -int(_f("ui_hint_bottom"))
	_ui.add_child(hints)
	for h in [["M", "NEXT MODE"], ["B", "BUY MENU"], ["ESC", "PAUSE / LEAVE"]]:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 7)
		hints.add_child(hb)
		var cap := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.45)
		sb.border_color = Color(1, 1, 1, 0.45)
		sb.set_border_width_all(1)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_bottom = 1
		cap.add_theme_stylebox_override("panel", sb)
		hb.add_child(cap)
		_lab(cap, 12, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, h[0])
		var hl := _lab(hb, 13, GREY, HORIZONTAL_ALIGNMENT_LEFT, h[1])
		hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint = hints
	# round summary
	_summary = _pc(_ui, 0.82, tt)
	_summary.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_summary.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_summary.grow_vertical = Control.GROW_DIRECTION_BOTH
	_summary.custom_minimum_size = Vector2(460, 0)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 6)
	_summary.add_child(sv)
	_sum_title = _lab(sv, 28, tt, HORIZONTAL_ALIGNMENT_CENTER)
	_sum_grid = GridContainer.new()
	_sum_grid.columns = 2
	_sum_grid.add_theme_constant_override("h_separation", 40)
	sv.add_child(_sum_grid)
	_sum_body = _lab(sv, 16, GREY, HORIZONTAL_ALIGNMENT_CENTER)
	_summary.visible = false
	_ui.visible = false
	get_viewport().size_changed.connect(_layout_ui)
	_layout_ui()

## The layer is drawn at ref_height and scaled to the window, so every pixel above is a 1080p pixel.
func _layout_ui() -> void:
	var vp := get_viewport().get_visible_rect().size
	var s := vp.y / float(Sheets.values("hud")["ref_height"])
	_layer.scale = Vector2(s, s)
	_ui.position = Vector2.ZERO
	_ui.size = vp / s

func _top_box(parent: Node, cap: String, col: Color) -> Label:
	var p := _pc(parent, _f("ui_alpha"), col)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -6)
	p.add_child(v)
	var l := _lab(v, 30, col, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size.x = 92
	_lab(v, 12, GREY, HORIZONTAL_ALIGNMENT_CENTER, cap)
	return l

func _acc() -> float:
	return 100.0 * _hits / maxf(_shots, 1)

## Round seconds played so far (the clock stands still while paused).
func _elapsed() -> float:
	return _f("round_s") - maxf(_left, 0.0) if _state == "round" else _f("round_s")

func _avg_ms(a: Array[float]) -> float:
	var s := 0.0
	for x in a:
		s += x
	return 1000.0 * s / maxf(a.size(), 1)

func _best_ttk_ms() -> float:
	return 1000.0 * float(_ttk.min()) if not _ttk.is_empty() else 0.0

## Score per mode. Misses cost points in every mode, so spraying never beats aiming.
func _score() -> int:
	var miss := (_shots - _hits) * int(_f("points_miss"))
	match mode:
		"bots":
			return maxi(0, _kills * int(_f("points_kill")) + _hs_kills * int(_f("points_hs_kill")) - miss)
		"flick":
			return maxi(0, _hits * int(_f("points_flick")) - miss)
		"track":
			return maxi(0, int(_on_target * _f("points_track_s")) - miss)
	return 0

## [name, value] rows for the panel, the summary and the --wtest line.
func _stats() -> Array:
	var out: Array = []
	match mode:
		"bots":
			out.append(["Kills", str(_kills)])
			out.append(["Headshot %", "%.0f%%" % (100.0 * _hs_kills / maxf(_kills, 1))])
			out.append(["Accuracy", "%.0f%%" % _acc()])
			out.append(["Avg time to kill", "%.0f ms" % _avg_ms(_ttk) if _kills > 0 else "-"])
			out.append(["Kills / min", "%.1f" % (60.0 * _kills / maxf(_elapsed(), 1.0))])
			out.append(["Avg kill interval", "%.0f ms" % _avg_ms(_gaps) if _kills > 0 else "-"])
			out.append(["Best time to kill", "%.0f ms" % _best_ttk_ms() if _kills > 0 else "-"])
			out.append(["Shots / hits", "%d / %d" % [_shots, _hits]])
			out.append(["Damage", str(int(_damage))])
		"flick":
			out.append(["Orbs hit", str(_hits)])
			out.append(["Accuracy", "%.0f%%" % _acc()])
			out.append(["Avg time to hit", "%.0f ms" % (1000.0 * _flick_sum / maxf(_flick_n, 1)) if _flick_n > 0 else "-"])
			out.append(["Shots", str(_shots)])
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
	var st := _stats().slice(0, int(_f("ui_panel_rows")))  # the first rows live; the summary shows them all
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
	_hold_weapon_clock(_paused())
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
	_gaps.clear()
	_flick_sum = 0.0
	_flick_n = 0
	_on_target = 0.0
	_last_kill_shot = -1
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
	_last_shot_at = _clock
	_last_kill_at = _clock
	for t in _targets:
		if t is Bot:
			(t as Bot).up_at = _clock

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
	for c in _sum_grid.get_children():
		c.queue_free()
	for r in _stats():
		_lab(_sum_grid, 15, GREY, HORIZONTAL_ALIGNMENT_LEFT, String(r[0]).to_upper())
		_lab(_sum_grid, 18, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, String(r[1]))
	_sum_body.text = ("%s\nnext round in %d s" % [line, int(_f("summary_s"))]).to_upper()
	_summary.visible = true
	_clear()

## The best file, else the temp copy a save left behind if it was killed before the rename. A file that will
## not parse is kept beside it as .bad (never silently replaced by an empty table).
func _load_best() -> Dictionary:
	var p := String(V["best_file"])
	for f in [p, p + ".tmp"]:
		if not FileAccess.file_exists(f):
			continue
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(f)) == OK and j.data is Dictionary:
			return j.data
		if FileAccess.file_exists(f + ".bad"):
			DirAccess.remove_absolute(f + ".bad")  # keep the newest torn copy: a rename onto a file can fail
		DirAccess.rename_absolute(f, f + ".bad")
		push_warning("aim lobby: %s did not parse, kept as %s.bad" % [f, f])
	return {}

## Written whole to a temp file, then renamed over the old one, so a crash mid-write never loses the bests.
func _save_best() -> void:
	var p := String(V["best_file"])
	var f := FileAccess.open(p + ".tmp", FileAccess.WRITE)
	if f == null:
		main.hud.message("could not save the best score: %s" % error_string(FileAccess.get_open_error()), 3.0)
		return
	f.store_string(JSON.stringify(_best))
	f.flush()
	f.close()
	var err := DirAccess.rename_absolute(p + ".tmp", p)
	if err != OK:
		main.hud.message("could not save the best score: %s" % error_string(err), 3.0)

## Weapons calls this once per trigger pull, hit or miss, before that pull's hits.
func on_shot_fired() -> void:
	if not (active and _state == "round"):
		return
	_shots += 1
	_last_shot_at = _clock
	_shot_frame = Engine.get_process_frames()
	_shot_ok = _behind_line()
	_shot_weapon = String(main.weapons.held()) if main.weapons else ""
	_used[_shot_weapon] = true

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
			_count(head)  # accuracy only: time on target is sampled every physics tick (_track_tick)
			(unit as Bot).kick = _f("bot_flinch") * 0.5
		"bots":
			var b := unit as Bot
			if b == null or not b.alive:
				return
			_count(head)
			if b.first_hit_at < 0.0:
				b.first_hit_at = _last_shot_at
			b.last_hit_at = _clock
			var d := minf(_hit_damage(b, dmg, head, group, _shot_weapon), b.hp)
			b.hp -= d
			_damage += d
			b.kick = _f("bot_flinch")
			if b.hp <= 0.0:
				_kill(b, head)

## One hit's health damage on a bot, in CS's order: the hitgroup scale (Weapons already applied the weapon's
## headshot multiplier; the knife skips the scale unless knife_hitgroups), then armour with the firing weapon's
## armor ratio, then whole points when damage_floor (CS keeps health as an integer). Pays the bot's kevlar.
func _hit_damage(b: Bot, dmg: float, head: bool, group: String, weapon: String) -> float:
	var id := weapon if weapon != "" else "knife"
	var w: Node = main.weapons
	if w == null:
		return _hit_health(b, dmg, head, group, id == "knife", 1.0, 1.0)
	return _hit_health(b, dmg, head, group, id == "knife", float(w.stat(id, "armor ratio")) * float(w.X["armor_ratio_scale"]), float(w.X["armor_bonus"]))

## _hit_damage with the armour terms given (the --lobbytest shots-to-kill table feeds CS2's own numbers).
func _hit_health(b: Bot, dmg: float, head: bool, group: String, knife: bool, ratio: float, bonus: float) -> float:
	var scale := 1.0 if head or (knife and not bool(V["knife_hitgroups"])) else _f("hitgroup_" + group)
	var split := armour_split(dmg * scale, "head" if head else group, ratio, bonus, b.kevlar, b.helmet)
	b.kevlar -= float(split[1])
	return floorf(split[0]) if bool(V["damage_floor"]) else float(split[0])

## CS armour: an armoured group (chest, stomach, arms; the head only with a helmet; never the legs) takes
## ratio of the damage to health, and the kevlar pays bonus of the rest, capped by what is left of it.
## Returns [health damage, kevlar paid].
static func armour_split(d: float, group: String, ratio: float, bonus: float, kevlar: float, helmet: bool) -> Array:
	if kevlar <= 0.0 or group == "legs" or (group == "head" and not helmet):
		return [d, 0.0]
	var health := d * ratio
	var paid := (d - health) * bonus
	if paid > kevlar:
		health = d - kevlar / bonus
		paid = kevlar
	return [health, paid]

## One hit per shot at most (a shotgun through two bots is still one shot that hit), so accuracy stays <= 100%.
## True when this is the shot's first hit.
func _count(head: bool) -> bool:
	if _hit_shot == _shots:
		if head and not _head_shot:
			_heads += 1
			_head_shot = true
		return false
	_hit_shot = _shots
	_head_shot = head
	_hits += 1
	if head:
		_heads += 1
	return true

## Track: one physics tick of time on target when the trigger is held while the gun is firing (_firing), from
## behind the firing line, with the crosshair ray on the live track bot. A tick is a tick whatever the fire
## rate; shots only count toward accuracy and the miss cost.
func _track_tick(dt: float, trigger: bool, on_bot: bool, firing: bool) -> void:
	if not (active and _state == "round" and mode == "track") or _paused():
		return
	if not trigger or not on_bot or not firing or not _behind_line():
		return
	_on_target += dt

## True while the held gun is really firing: a round of this gun went off within its cycle (or track_fire_window,
## so a semi-auto must keep clicking) and it can fire again now. An empty clip, a dry Zeus, a reload or shell
## load, a draw, a silencer turn and the knife all earn nothing.
func _firing() -> bool:
	var w: Node = main.weapons
	if w == null:
		return false
	var id := String(w.held())
	if id == "" or id == "knife" or not w.ammo.has(id) or _shots == 0 or _shot_weapon != id:
		return false
	if int(w.ammo[id][0]) <= 0 or float(w._reload_until) > 0.0 or float(w._shell_next) > 0.0:
		return false
	var cyc := float(w.mstat(id, "cycletime"))
	if float(w._now()) + 0.0005 < maxf(float(w._next_fire) - cyc, float(w._toggle_until)):
		return false  # still drawing, or a silencer turn
	return _clock - _last_shot_at <= maxf(cyc, _f("track_fire_window"))

## The crosshair ray (screen centre, where the player looks) against the world: true when the first thing it
## meets is a part of the track bot, so a wall or crate between them blocks it.
func _crosshair_on(unit: Node3D) -> bool:
	var p: SurfPlayer = main.player
	if p == null or p.cam == null:
		return false
	var xf: Transform3D = p.cam.global_transform
	var q := PhysicsRayQueryParameters3D.create(xf.origin, xf.origin - xf.basis.z * _f("track_ray_m"))
	q.exclude = [p.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and hit["collider"] is AimTarget and (hit["collider"] as AimTarget).unit == unit

func _kill(b: Bot, head: bool) -> void:
	b.alive = false
	b.down_at = _clock
	b.fall_side = 1.0 if _rng.randf() < 0.5 else -1.0
	_kills += 1
	if head:
		_hs_kills += 1
	# time to kill: from the shot that first hit this bot (a one-tap is 0 ms). The kill interval runs from the
	# later of this bot standing up and the previous kill; a second kill by the same shot (penetration,
	# pellets) belongs to that shot's engagement and adds no interval
	_ttk.append(_clock - b.first_hit_at)
	if _last_kill_shot != _shots:
		_gaps.append(_clock - maxf(b.up_at, _last_kill_at))
	_last_kill_at = _clock
	_last_kill_shot = _shots
	_set_live(b, false)
	_feed_add(b.tag, head)

func _set_live(b: Bot, live: bool) -> void:
	for o in b.bodies:
		(o as CollisionObject3D).collision_layer = 1 if live else 0

## Live bots sway on their feet (bot_idle); downed bots tip over backwards with a twist, then stand back up
## after bot_respawn_s on the round clock.
func _tick_bots(dt: float) -> void:
	var fall_s := maxf(_f("bot_fall_s"), 0.01)
	var idle: Array = V["bot_idle"]
	for t in _targets:
		var b := t as Bot
		if b == null or not is_instance_valid(b):
			continue
		b.kick = move_toward(b.kick, 0.0, dt * 1.2)
		if b.alive and b.first_hit_at >= 0.0 and _clock - b.last_hit_at >= _f("bot_heal_s"):
			_heal(b)  # left alone, a wounded bot is fresh again: the next time to kill starts from scratch
		var fall := 0.0
		if not b.alive:
			var since := _clock - b.down_at
			fall = clampf(since / fall_s, 0.0, 1.0)
			fall = fall * fall
			if since >= _f("bot_respawn_s") and _state == "round":
				b.alive = true
				_heal(b)
				b.kick = 0.0
				b.up_at = _clock
				fall = 0.0
				_set_live(b, true)
		var ph := _clock * TAU * float(idle[1]) + b.phase
		var still := 1.0 - fall
		b.pose.rotation = Vector3(-(b.kick + fall * PI * 0.5) + deg_to_rad(float(idle[0])) * 0.5 * sin(ph * 0.7) * still,
			deg_to_rad(float(idle[2])) * sin(ph * 0.37) * still + fall * b.fall_side * 0.5,
			deg_to_rad(float(idle[0])) * sin(ph) * still + fall * b.fall_side * 0.25)
		if b.head:  # a slow scan left and right, out of step with the sway
			b.head.rotation = Vector3(deg_to_rad(_f("bot_head_look")) * 0.3 * sin(ph * 0.31 + 1.7), deg_to_rad(_f("bot_head_look")) * sin(ph * 0.19 + b.phase), 0.0) * still

func _heal(b: Bot) -> void:
	b.hp = b.hp_max
	b.kevlar = _f("bot_armor")
	b.first_hit_at = -1.0
	b.last_hit_at = -1.0

func _feed_add(victim: String, head: bool) -> void:
	var p := _pc(_feed, 0.6)
	var sb: StyleBoxFlat = p.get_theme_stylebox("panel")
	sb.border_color = _col("ui_feed_border")  # CS2 outlines the local player's own kills
	sb.set_border_width_all(2)
	sb.content_margin_top = 3
	sb.content_margin_bottom = 4
	p.size_flags_horizontal = Control.SIZE_SHRINK_END
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	p.add_child(hb)
	_lab(hb, 15, _col("ui_ct"), HORIZONTAL_ALIGNMENT_LEFT, "You")
	_lab(hb, 15, Color(0.9, 0.9, 0.9), HORIZONTAL_ALIGNMENT_LEFT, _weapon_name(_shot_weapon).to_upper())
	if head:
		_lab(hb, 15, Color(1, 0.85, 0.4), HORIZONTAL_ALIGNMENT_LEFT, "HS")
	_lab(hb, 15, _col("ui_t"), HORIZONTAL_ALIGNMENT_LEFT, victim)
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

func _target(unit: Node3D, shape: Shape3D, mesh: Mesh, mat: Material, xf: Transform3D, head: bool, group: String, parent: Node3D, shape_xf := Transform3D.IDENTITY) -> AimTarget:
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
	cs.transform = shape_xf
	tb.add_child(cs)
	parent.add_child(tb)
	return tb

func _sphere(r: float) -> SphereMesh:
	var key := "s%.4f" % r
	if not _meshes.has(key):
		var m := SphereMesh.new()
		m.radius = r
		m.height = r * 2.0
		m.radial_segments = 32
		m.rings = 16
		_meshes[key] = m
	return _meshes[key]

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
	_targets.append(_bot(Vector3(0, 0, _f("firing_line_z") - _f("track_distance")), 0.0, 0, "BOT"))
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

## A sheet part or prop in the bot frame (metres): [transform, mesh, hitbox shape or null, mesh scale, hitbox
## transform in the part]. sphere: centre a, radius r. capsule / taper: a to b, radius r at a and r2 at b (lathed,
## so a limb narrows toward its joint). beam: a box from a to b, r half wide and r2 half tall (gun parts, feet).
## box / rbox: centre a, size b. cylinder: centre a, height b.y. k scales the drawn mesh in the part's own axes
## (x across, y along a to b, z depth). The hitbox is the undrawn shape, or the box 'hit' gives ([centre, size]).
func _shape_of(r: Dictionary) -> Array:
	var a := _a3(r["a"]) * H
	var b := _a3(r["b"]) * H
	var rad := float(r["r"]) * H
	var rad2 := float(r.get("r2", r["r"])) * H
	var k := _a3(r["k"]) if r.has("k") else Vector3.ONE
	var out: Array
	match String(r["shape"]):
		"sphere":
			var ss := SphereShape3D.new()
			ss.radius = rad
			out = [Transform3D(Basis(), a), _sphere(rad), ss, k]
		"box", "rbox":
			var bs := BoxShape3D.new()
			bs.size = b
			var bm := BoxMesh.new()
			bm.size = b
			out = [Transform3D(Basis(), a), bm, bs, k]
		"cylinder":
			var cm := CylinderMesh.new()
			cm.top_radius = rad
			cm.bottom_radius = rad
			cm.height = b.y
			out = [Transform3D(Basis(), a), cm, null, k]
		_:
			# capsule, taper, beam: laid from a to b, x kept level so a beam's height stands up
			var d := b - a
			var y := d.normalized() if d.length() > 0.0001 else Vector3.UP
			var ref := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP.cross(y)
			var x := (ref - y * ref.dot(y)).normalized()
			var xf := Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5)
			if String(r["shape"]) == "beam":
				var beam := BoxShape3D.new()
				beam.size = Vector3(rad * 2.0, d.length(), rad2 * 2.0)
				out = [xf, _cached_box(beam.size), beam, k]
			else:
				var cs := CapsuleShape3D.new()
				cs.radius = maxf(rad, rad2)
				cs.height = d.length() + cs.radius * 2.0
				out = [xf, _taper_mesh(rad, rad2, d.length()), cs, k]
	out.append(Transform3D.IDENTITY)
	var hb: Variant = r.get("hit", "auto")
	if hb is Array:
		var box := BoxShape3D.new()
		box.size = Vector3(float(hb[3]), float(hb[4]), float(hb[5])) * H
		out[2] = box
		out[4] = (out[0] as Transform3D).affine_inverse() * Transform3D(Basis(), Vector3(float(hb[0]), float(hb[1]), float(hb[2])) * H)
	return out

var _meshes := {}

func _cached_box(size: Vector3) -> BoxMesh:
	var key := "b%s" % size
	if not _meshes.has(key):
		var m := BoxMesh.new()
		m.size = size
		_meshes[key] = m
	return _meshes[key]

## A capsule whose two end radii differ: a lathe along y from r1 at -len/2 to r2 at +len/2, round caps.
func _taper_mesh(r1: float, r2: float, len: float) -> ArrayMesh:
	var key := "t%.4f/%.4f/%.4f" % [r1, r2, len]
	if _meshes.has(key):
		return _meshes[key]
	var seg := 18
	var cap := 5
	var prof: Array = []  # [radius, y, normal xz, normal y]
	var slope := asin(clampf((r1 - r2) / maxf(len, 0.0001), -0.99, 0.99))  # the side's tilt, tangent to both caps
	for i in cap + 1:
		var t := lerpf(-PI * 0.5, slope, float(i) / cap)
		prof.append([r1 * cos(t), -len * 0.5 + r1 * sin(t), cos(t), sin(t)])
	for i in cap + 1:
		var t := lerpf(slope, PI * 0.5, float(i) / cap)
		prof.append([r2 * cos(t), len * 0.5 + r2 * sin(t), cos(t), sin(t)])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in prof.size():
		var p: Array = prof[j]
		for i in seg + 1:
			var t := TAU * i / seg
			st.set_normal(Vector3(cos(t) * float(p[2]), float(p[3]), sin(t) * float(p[2])))
			st.set_uv(Vector2(float(i) / seg, float(j) / (prof.size() - 1)))
			st.add_vertex(Vector3(cos(t) * float(p[0]), float(p[1]), sin(t) * float(p[0])))
	for j in prof.size() - 1:
		for i in seg:
			var a := j * (seg + 1) + i
			var b := a + seg + 1
			for v in [a, a + 1, b, a + 1, b + 1, b]:
				st.add_index(v)
	var m := st.commit()
	_meshes[key] = m
	return m

## The cloth weave: greyscale value noise between the two cloth_noise levels, multiplied into the slot colour.
func _cloth_tex() -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	n.frequency = 0.18
	n.fractal_octaves = 3
	var t := NoiseTexture2D.new()
	t.width = 128
	t.height = 128
	t.seamless = true
	t.noise = n
	var cn: Array = V["cloth_noise"]
	var g := Gradient.new()
	g.set_color(0, Color(float(cn[0]), float(cn[0]), float(cn[0])))
	g.set_color(1, Color(float(cn[1]), float(cn[1]), float(cn[1])))
	t.color_ramp = g
	return t

## Bot skin, cloth and kit. Primitives read flat under the range's even light, so the shade gives them volume
## the way baked AO does on a game model: faces turned down darken (ao_down), the part's rim darkens toward
## grazing view (edge), the lowest foot_ao_m of the body darkens toward the floor it stands on (foot_ao),
## and cloth gets a soft sheen at the silhouette plus its weave (local-space triplanar, so it rides the part).
## Kit metal takes the trim material's texture the same way.
const BOT_SHADER := "shader_type spatial;
uniform vec3 col : source_color = vec3(0.5);
uniform sampler2D weave : filter_linear_mipmap, repeat_enable;
uniform bool cloth = false;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_tex = false;
uniform float weave_scale = 6.0;
uniform float rough = 0.9;
uniform float spec = 0.4;
uniform float metal = 0.0;
uniform float ao_down = 0.55;
uniform float edge = 0.75;
uniform float sheen = 0.25;
uniform float foot_ao = 0.6;
uniform float foot_ao_m = 0.35;
instance uniform float base_y = 0.0;
varying vec3 wn;
varying vec3 wp;
varying vec3 lp;
varying vec3 ln;
void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	lp = VERTEX;
	ln = NORMAL;
}
void fragment() {
	vec3 c = col;
	vec3 b = pow(abs(normalize(ln)), vec3(4.0));
	b /= max(b.x + b.y + b.z, 0.0001);
	if (has_tex) {
		vec2 s = vec2(weave_scale * 0.25);
		c *= texture(tex, lp.yz * s).rgb * b.x + texture(tex, lp.xz * s).rgb * b.y + texture(tex, lp.xy * s).rgb * b.z;
	}
	if (cloth) {
		float w = texture(weave, lp.yz * weave_scale).r * b.x + texture(weave, lp.xz * weave_scale).r * b.y + texture(weave, lp.xy * weave_scale).r * b.z;
		c *= w;
		RIM = sheen;
		RIM_TINT = 0.6;
	}
	c *= mix(1.0, ao_down, clamp(-normalize(wn).y, 0.0, 1.0));
	c *= mix(edge, 1.0, sqrt(clamp(dot(NORMAL, VIEW), 0.0, 1.0)));
	c *= mix(foot_ao, 1.0, smoothstep(0.0, foot_ao_m, wp.y - base_y));
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = spec;
	METALLIC = metal;
}
"

## One material per outfit slot: [roughness, specular, metallic] from bot_slot_pbr, cloth slots woven.
func _slot_mat(outfit: int, slot: String) -> Material:
	var key := "%d/%s" % [outfit, slot]
	if _mats.has(key):
		return _mats[key]
	var o: Dictionary = S["outfits"][outfit]
	var col: Color
	match slot:
		"gun_metal": col = _col("color_gun_metal")
		"gun_wood": col = _col("color_gun_wood")
		_: col = _c(o[slot])
	var pbr: Dictionary = V["bot_slot_pbr"]
	var cloth := not pbr.has(slot)
	var k: Array = pbr.get(slot, pbr["cloth"])
	if not _mats.has("shader"):
		var sh := Shader.new()
		sh.code = BOT_SHADER
		_mats["shader"] = sh
		_mats["cloth"] = _cloth_tex()
	var m := ShaderMaterial.new()
	m.shader = _mats["shader"]
	m.set_shader_parameter("col", col)
	m.set_shader_parameter("cloth", cloth)
	m.set_shader_parameter("weave", _mats["cloth"])
	var src: StandardMaterial3D = main.course.materials.get(String(V["trim_material"])) if (V["bot_rusty_slots"] as Array).has(slot) else null
	if src and src.albedo_texture:  # kit metal (masks, plates, kilt signs) wears the course's rusty trim metal
		m.set_shader_parameter("has_tex", true)
		m.set_shader_parameter("tex", src.albedo_texture)
	m.set_shader_parameter("weave_scale", _f("bot_weave_scale"))
	m.set_shader_parameter("rough", float(k[0]))
	m.set_shader_parameter("spec", float(k[1]))
	m.set_shader_parameter("metal", float(k[2]))
	var sd: Array = V["bot_shade"]
	m.set_shader_parameter("ao_down", float(sd[0]))
	m.set_shader_parameter("edge", float(sd[1]))
	m.set_shader_parameter("sheen", float(sd[2]) if cloth else 0.0)
	m.set_shader_parameter("foot_ao", float(sd[3]))
	m.set_shader_parameter("foot_ao_m", float(sd[4]))
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
	b.kevlar = _f("bot_armor")
	b.helmet = bool(V["bot_helmet"])
	b.position = center + at
	b.rotation_degrees.y = yaw_deg
	b.phase = _rng.randf() * TAU
	b.pose = Node3D.new()
	b.add_child(b.pose)
	add_child(b)
	var by_id := {}
	for r in S["parts"]:
		var s := _shape_of(r)
		var tb := _target(b, s[2], s[1], _slot_mat(outfit, String(r["slot"])), s[0], String(r["group"]) == "head", String(r["group"]), b.pose, s[4])
		(tb.get_child(0) as MeshInstance3D).scale = s[3]
		(tb.get_child(0) as MeshInstance3D).set_instance_shader_parameter("base_y", b.global_position.y)
		b.bodies.append(tb)
		by_id[String(r["id"])] = tb
		if tb.is_head:
			b.head = tb
	var gear: Array = o["gear"]
	for r in S["props"]:
		var when := String(r["when"])
		if not (when == "always" or gear.has(when)):
			continue
		var on: Node3D = by_id.get(String(r["on"]))
		if on == null:
			continue
		var s := _shape_of(r)
		var mi := MeshInstance3D.new()
		mi.mesh = s[1]
		mi.material_override = _slot_mat(outfit, String(r["slot"]))
		mi.transform = on.transform.affine_inverse() * (s[0] as Transform3D).scaled_local(s[3])
		mi.set_instance_shader_parameter("base_y", b.global_position.y)
		on.add_child(mi)
	return b

func _physics_process(dt: float) -> void:
	if not (active and _state == "round" and mode == "track" and _targets.size() > 0) or _paused():
		return
	var t := _targets[0]
	if not is_instance_valid(t):
		return
	_track_tick(dt, Input.is_action_pressed("surf_attack"), _crosshair_on(t), _firing())
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

## --lobbytest: a shot fired with weapon id (the test player holds the knife when no CS2 gun is exported).
func _fire(id := "cs2_ak47") -> void:
	on_shot_fired()
	if _state == "round":
		_shot_weapon = id

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
	_fire()
	_part(b0, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("headshot kill", _kills == 1 and _hs_kills == 1 and _hits == 1 and not b0.alive, _stats_line()) and ok
	_fire()
	_part(b1, "thigh_l").hit(100.0, false, Vector3.ZERO)
	ok = _check("legs x0.75", is_equal_approx(b1.hp, 25.0), b1.hp) and ok
	_part(b2, "chest").hit(30.0, false, Vector3.ZERO)
	ok = _check("two bots in one shot = one hit", _hits == 2 and _shots == 2, _stats_line()) and ok
	await get_tree().process_frame
	await get_tree().process_frame
	_fire()
	_part(b1, "stomach").hit(400.0, false, Vector3.ZERO)
	ok = _check("second-shot kill: ttk from its first hit > 0, one-tap ttk 0", _kills == 2 and _hs_kills == 1 and _ttk.size() == 2 and _ttk[0] == 0.0 and _ttk[1] > 0.0, _ttk) and ok
	_fire()
	_part(b0, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("dead bot ignored", _kills == 2 and _hits == 3, _stats_line()) and ok
	_fire()
	_fire()
	ok = _check("misses cost points", _score() == 2 * 100 + 50 - 3 * 10, _score()) and ok
	var p: SurfPlayer = main.player
	p.global_position = to_global(Vector3(0, 0.05, _f("firing_line_z") - 2.0))
	_fire()
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
	_fire()
	ok = _check("no shots after the round", _shots == 7, _shots) and ok
	_quick = false
	_start_round()
	_fire()
	ok = _check("countdown first, shots not counted", _state == "countdown" and _shots == 0 and _left > 0.0, "%.1f s left" % _left) and ok
	t0 = Time.get_ticks_msec()
	while _state == "countdown" and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	ok = _check("round starts after the countdown", _state == "round" and absf(took - _f("countdown_s")) < 0.5, "%.2f s" % took) and ok
	ok = _check("test run wrote no best file", FileAccess.file_exists(String(V["best_file"])) == had_best, had_best) and ok
	# track: time on target is sampled per tick (trigger held, crosshair on the bot); shots only count accuracy
	_quick = true
	mode = "track"
	_start_round()
	for i in 4:
		await get_tree().process_frame
	var tb := _targets[0] as Bot
	var tick := 1.0 / Engine.physics_ticks_per_second
	var cam: Camera3D = p.cam
	var keep_cam := cam.transform
	await get_tree().physics_frame
	cam.look_at(_part(tb, "chest").global_position)
	var seen := _crosshair_on(tb)
	cam.look_at(_part(tb, "chest").global_position + global_transform.basis.x * 8.0)
	ok = _check("track: the crosshair ray finds the bot, and misses beside it", seen and not _crosshair_on(tb), seen) and ok
	cam.transform = keep_cam
	var base := _on_target  # the real trigger is never held headless, so _physics_process adds nothing
	_track_tick(tick, false, true, true)
	_track_tick(tick, true, false, true)
	_track_tick(tick, true, true, false)
	ok = _check("track: no trigger, off the bot or not firing, no time", _on_target == base, _on_target) and ok
	for i in 10:
		_track_tick(tick, true, true, true)
	var one := _on_target
	ok = _check("track: ten ticks on target = ten ticks, whatever the gun", is_equal_approx(one - base, 10.0 * tick), "%.4f s" % (one - base)) and ok
	_part(tb, "chest").hit(30.0, false, Vector3.ZERO)
	ok = _check("track: hit without a shot earns nothing", _on_target == one and _hits == 0, _on_target) and ok
	_fire()
	_part(tb, "chest").hit(30.0, false, Vector3.ZERO)
	_part(tb, "head").hit(30.0, true, Vector3.ZERO)
	ok = _check("track: a hit counts accuracy, not time", _on_target == one and _hits == 1 and _shots == 1, _stats_line()) and ok
	_fire()
	ok = _check("track: a miss earns nothing", _on_target == one and _hits == 1, _on_target) and ok
	p.global_position = to_global(Vector3(0, 0.05, _f("firing_line_z") - 2.0))
	_track_tick(tick, true, true, true)
	ok = _check("track: past the firing line earns nothing", _on_target == one, _on_target) and ok
	p.global_position = spawn_pos()
	# the firing gate, on the real weapon state: an AK put in hand without its model (no frame runs meanwhile)
	var wg: Node = main.weapons
	var ak := "cs2_ak47"
	var keep_slot := String(wg.slots["primary"])
	var keep_cur := String(wg.current)
	wg.slots["primary"] = ak
	wg.current = "primary"
	wg._next_fire = 0.0
	wg._toggle_until = 0.0
	wg._reload_until = 0.0
	wg._shell_next = 0.0
	wg.ammo[ak] = [30, 90]
	_fire(ak)
	var live := _firing()
	wg.ammo[ak] = [0, 90]
	var dry := _on_target
	for i in 10:
		_track_tick(tick, true, true, _firing())
	ok = _check("track: trigger held on an empty gun earns 0 s", live and _on_target == dry, "firing with rounds %s, %.4f s empty" % [live, _on_target - dry]) and ok
	wg.ammo[ak] = [30, 90]
	wg._reload_until = wg._now() + 1.0
	var rl := _firing()
	wg._reload_until = 0.0
	wg._shell_next = wg._now() + 1.0
	var sh := _firing()
	wg._shell_next = 0.0
	wg._next_fire = wg._now() + 1.0
	var dr := _firing()
	wg._next_fire = 0.0
	_last_shot_at = _clock - 1.0
	var stale := _firing()
	_last_shot_at = _clock
	wg.current = "knife"
	var kn := _firing()
	ok = _check("track: reload, shell load, draw, no shot within the window, knife: no time", not (rl or sh or dr or stale or kn), [rl, sh, dr, stale, kn]) and ok
	wg.current = keep_cur
	wg.slots["primary"] = keep_slot
	wg.refill()
	one = _on_target
	main.settings.is_open = true
	_track_tick(tick, true, true, true)
	var held_left := _left
	await get_tree().process_frame
	ok = _check("track: menu open earns nothing and holds the clock", _on_target == one and _left == held_left, "%.3f s" % _left) and ok
	main.settings.is_open = false
	var buy: Variant = main.weapons.get("_buy")
	if buy is CanvasLayer:
		(buy as CanvasLayer).visible = true
		held_left = _left
		await get_tree().process_frame
		await get_tree().process_frame
		ok = _check("buy menu open holds the round clock", _paused() and _left == held_left, "%.3f s" % _left) and ok
		# a reload pending when the menu opens still has all of its time left when it closes
		wg._reload_until = wg._now() + 0.5
		var due := float(wg._reload_until) - float(wg._now())
		var t1 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 300:
			await get_tree().process_frame
		var still := float(wg._reload_until) - float(wg._now())
		(buy as CanvasLayer).visible = false
		await get_tree().process_frame
		ok = _check("pause keeps a pending reload's time", absf(still - due) < 0.06, "%.3f s left of %.3f after 0.3 s paused" % [still, due]) and ok
		wg._reload_until = 0.0
	else:
		ok = _check("buy menu found", false, buy) and ok
	_on_target += 1.0  # a full second on target, so the miss cost shows above the floor of 0
	ok = _check("track: misses cost points", _score() == maxi(0, int(_on_target * _f("points_track_s")) - (_shots - _hits) * int(_f("points_miss"))) and _shots > _hits, _score()) and ok
	# bots: one shot that kills two bots adds one time-to-kill, not a zero
	mode = "bots"
	_start_round()
	await get_tree().process_frame
	await get_tree().process_frame
	_fire()
	_part(_targets[0] as Bot, "head").hit(400.0, true, Vector3.ZERO)
	_part(_targets[1] as Bot, "head").hit(400.0, true, Vector3.ZERO)
	ok = _check("double kill by one shot: one hit, two kills, one kill interval > 0", _kills == 2 and _hits == 1 and _ttk.size() == 2 and _gaps.size() == 1 and _gaps[0] > 0.0, _gaps) and ok
	# a wounded bot left alone for bot_heal_s heals: a kill much later is a new engagement, not a long ttk
	var bhl := _targets[8] as Bot
	_fire()
	_part(bhl, "chest").hit(30.0, false, Vector3.ZERO)
	var hurt := bhl.hp < bhl.hp_max and bhl.first_hit_at >= 0.0
	bhl.last_hit_at = _clock - _f("bot_heal_s") - 0.01
	await get_tree().process_frame
	ok = _check("wounded bot heals after bot_heal_s with no hits", hurt and bhl.hp == bhl.hp_max and bhl.first_hit_at < 0.0 and bhl.kevlar == _f("bot_armor"), "hp %.0f first hit %.2f" % [bhl.hp, bhl.first_hit_at]) and ok
	# armour, CS order: hitgroup scale first, then the split; legs never armoured, the head only with a helmet
	var w: Node = main.weapons
	var ratio := float(w.stat("cs2_ak47", "armor ratio")) * float(w.X["armor_ratio_scale"])
	var bonus := float(w.X["armor_bonus"])
	var ba := _targets[2] as Bot
	var bl := _targets[3] as Bot
	var bh := _targets[4] as Bot
	ba.kevlar = 100.0
	bl.kevlar = 100.0
	bh.kevlar = 100.0
	bh.helmet = false
	_fire()
	_part(ba, "stomach").hit(40.0, false, Vector3.ZERO)
	_part(bl, "thigh_r").hit(40.0, false, Vector3.ZERO)
	_part(bh, "head").hit(40.0, true, Vector3.ZERO)
	var hp_a := floorf(50.0 * ratio)
	ok = _check("armour: stomach x1.25 then split, whole points", is_equal_approx(ba.hp, 100.0 - hp_a) and is_equal_approx(ba.kevlar, 100.0 - (50.0 - 50.0 * ratio) * bonus), "hp %.2f kevlar %.2f" % [ba.hp, ba.kevlar]) and ok
	ok = _check("armour: legs unarmoured", is_equal_approx(bl.hp, 70.0) and bl.kevlar == 100.0, "hp %.2f kevlar %.2f" % [bl.hp, bl.kevlar]) and ok
	ok = _check("armour: no helmet, full head damage", is_equal_approx(bh.hp, 60.0) and bh.kevlar == 100.0, "hp %.2f" % bh.hp) and ok
	bl.kevlar = 1.0
	_fire()
	_part(bl, "chest").hit(40.0, false, Vector3.ZERO)
	ok = _check("armour: worn-out kevlar caps what it absorbs", is_equal_approx(bl.hp, 70.0 - floorf(40.0 - 1.0 / bonus)) and bl.kevlar == 0.0, "hp %.2f" % bl.hp) and ok
	# the knife: no hitgroup scale (knife_hitgroups false), still armoured on the body
	var bk := _targets[6] as Bot
	bk.kevlar = 0.0
	_fire("knife")
	_part(bk, "thigh_l").hit(65.0, false, Vector3.ZERO)
	ok = _check("knife: legs take the full stab", is_equal_approx(bk.hp, 100.0 - (65.0 if not bool(V["knife_hitgroups"]) else floorf(65.0 * _f("hitgroup_legs")))), bk.hp) and ok
	# the shot's own weapon decides the armour, not the one held when the hit lands (here the knife is held)
	var bw := _targets[7] as Bot
	bw.kevlar = 100.0
	_fire("cs2_ak47")
	_part(bw, "chest").hit(36.0, false, Vector3.ZERO)
	ok = _check("armour ratio from the firing weapon", is_equal_approx(bw.hp, 100.0 - floorf(36.0 * ratio)), "hp %.0f, held %s, knife ratio %.3f, ak ratio %.3f" % [bw.hp, main.weapons.held(), float(w.stat("knife", "armor ratio")) * float(w.X["armor_ratio_scale"]), ratio]) and ok
	# shots to kill, CS2's numbers: damage, armor ratio and headshot multiplier from the stk_checks table
	var scale := float(w.X["armor_ratio_scale"])
	for r in S["stk_checks"]:
		var sb := Bot.new()
		sb.kevlar = float(r["kevlar"])
		sb.helmet = bool(r["helmet"])
		var hd := String(r["group"]) == "head"
		var n := 0
		while sb.hp > 0.0 and n < 30:
			var dm := float(r["damage"]) * (float(r["hs_mult"]) if hd else 1.0)
			sb.hp -= minf(_hit_health(sb, dm, hd, String(r["group"]), false, float(r["armor_ratio"]) * scale, bonus), sb.hp)
			n += 1
		sb.free()
		ok = _check("shots to kill: %s" % r["id"], n == int(r["shots"]), "%d (want %d)" % [n, int(r["shots"])]) and ok
	ok = _check("sheet: bots wear kevlar and helmet", ba.helmet == bool(V["bot_helmet"]) and (_targets[5] as Bot).kevlar == _f("bot_armor"), _f("bot_armor")) and ok
	# best file: whole-file save through a temp file; an unparsable file is set aside, not silently lost
	var keep := String(V["best_file"])
	var keep_best := _best
	V["best_file"] = "user://aim_best_selftest.json"
	_best = {"bots|ak47": 1234}
	_save_best()
	var back := _load_best()
	ok = _check("best file round trip, no temp left", int(back.get("bots|ak47", 0)) == 1234 and not FileAccess.file_exists(String(V["best_file"]) + ".tmp"), back) and ok
	var bf := FileAccess.open(String(V["best_file"]), FileAccess.WRITE)
	bf.store_string("{\"bots|ak47\": 12")
	bf.close()
	back = _load_best()
	ok = _check("torn best file set aside as .bad", back.is_empty() and FileAccess.file_exists(String(V["best_file"]) + ".bad"), back) and ok
	bf = FileAccess.open(String(V["best_file"]), FileAccess.WRITE)
	bf.store_string("{\"bots|ak47\": 99")
	bf.close()
	back = _load_best()
	ok = _check("second torn file replaces the old .bad", back.is_empty() and not FileAccess.file_exists(String(V["best_file"])) and FileAccess.get_file_as_string(String(V["best_file"]) + ".bad").ends_with("99"), back) and ok
	for f in ["", ".tmp", ".bad"]:
		if FileAccess.file_exists(String(V["best_file"]) + f):
			DirAccess.remove_absolute(String(V["best_file"]) + f)
	V["best_file"] = keep
	_best = keep_best
	print("LTEST ", "ALL PASS" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)
