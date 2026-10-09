## systems.course_builder + checkpoints: one node per course.json row.
class_name Course
extends Node3D

signal entered_zone(kind: String, id: String)

var sheet: Dictionary
var materials := {}
var surfaces := {}
var uv_scales := {}
var spawn_pos: Vector3
var spawn_yaw: float
var checkpoint_pos: Vector3
var checkpoint_yaw: float
var content: Content
var rows := {}

func build(c: Content) -> void:
	content = c
	sheet = Sheets.load_sheet("course")
	spawn_pos = _v3(sheet["spawn"]["pos"])
	spawn_yaw = float(sheet["spawn"]["yaw"])
	checkpoint_pos = spawn_pos
	checkpoint_yaw = spawn_yaw
	for m in Sheets.load_sheet("materials")["rows"]:
		materials[m["id"]] = _material(m)
		surfaces[m["id"]] = _surface(m)
		uv_scales[m["id"]] = float(m["uv_scale"])
	for r in sheet["rows"]:
		rows[r["id"]] = r
		add_child(_piece(r))

func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

## materials.json row -> StandardMaterial3D using textures read from Rust.
func _material(m: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = float(m["roughness"])
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if m["albedo"] != "(none)":
		var t := content.texture(m["albedo"], "MainTex")
		if t:
			mat.albedo_texture = t
			# anisotropic: ground and ramps seen at grazing angles keep their detail instead of blurring
			# aniso keeps ramps detailed at grazing angles; sharp (no mips) is the crisp far gravel the Gauntlet critics preferred
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR if m.get("filter", "aniso") == "sharp" else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var n := content.texture(m["normal"], "BumpMap")
		if n:
			mat.normal_enabled = true
			mat.normal_texture = n
	else:
		mat.albedo_color = Color(0.2, 0.9, 0.4, 0.15)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

## The course's own surfaces: the same textures through the weathering shader (materials.json
## weather, grime, detail). AimLobby still borrows the plain StandardMaterial3D from materials.
func _surface(m: Dictionary) -> Material:
	if m["albedo"] == "(none)":
		return materials[m["id"]]
	var t := content.texture(m["albedo"], "MainTex")
	if t == null:
		return materials[m["id"]]
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SURFACE_SHADER
	sm.shader = sh
	sm.set_shader_parameter("tex_a", t)
	sm.set_shader_parameter("nrm_a", content.texture(m["normal"], "BumpMap"))
	sm.set_shader_parameter("has_nrm", content.texture(m["normal"], "BumpMap") != null)
	var w: Texture2D = null
	if m["weather"] != "(none)":
		w = content.texture(m["weather"], "MainTex")
	sm.set_shader_parameter("has_b", w != null)
	if w:
		sm.set_shader_parameter("tex_b", w)
		sm.set_shader_parameter("nrm_b", content.texture(m["weather"], "BumpMap"))
	sm.set_shader_parameter("scale_a", float(m["uv_scale"]))
	sm.set_shader_parameter("weather", float(m["weather_cover"]))
	sm.set_shader_parameter("grime", float(m["grime"]))
	sm.set_shader_parameter("detail", float(m["detail"]))
	sm.set_shader_parameter("roughness_val", float(m["roughness"]))
	return sm

func _piece(r: Dictionary) -> Node3D:
	var node: Node3D
	var basis := Basis.from_euler(Vector3(0, deg_to_rad(float(r["yaw"])), 0)) * Basis.from_euler(Vector3(0, 0, deg_to_rad(float(r["pitch"]))))
	match r["kind"]:
		"ramp": node = _ramp(r)
		"platform": node = _box_body(r)
		"decor": node = _decor(r)
		_: node = _zone(r)
	node.name = r["id"]
	node.transform = Transform3D(basis, _v3(r["pos"]))
	return node

## A ramp is a triangular prism along local X; ridge peaks up, valley is a V you surf inside.
func _ramp(r: Dictionary) -> StaticBody3D:
	var L := float(r["length"]) * 0.5
	var W := float(r["half_width"])
	var H := float(r["height"]) * 0.5
	var ridge: bool = r["shape"] == "ridge"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := Vector2(H, 0) if ridge else Vector2(-H, 0)
	var left := Vector2(-H, -W) if ridge else Vector2(H, -W)
	var right := Vector2(-H, W) if ridge else Vector2(H, W)
	for f in [[apex, left], [apex, right]]:
		var a: Vector2 = f[0]
		var b: Vector2 = f[1]
		var p0 := Vector3(-L, a.x, a.y); var p1 := Vector3(L, a.x, a.y)
		var p2 := Vector3(L, b.x, b.y); var p3 := Vector3(-L, b.x, b.y)
		var n := (p1 - p0).cross(p3 - p0).normalized()
		if n.y < 0.0:
			n = -n
		var slope := (Vector3(0, b.x, b.y) - Vector3(0, a.x, a.y)).length()
		# the top edge is the apex of a ridge and the outer rim of a valley
		_quad(st, p0, p1, p2, p3, n, L * 2.0, slope, 0.0 if ridge else slope, slope if ridge else 0.0)
	if ridge:
		var pa := Vector3(-L, H, 0); var pl := Vector3(-L, -H, -W); var pr := Vector3(-L, -H, W)
		_tri(st, pa, pl, pr, Vector3(-1, 0, 0))
		var dx := Vector3(2 * L, 0, 0)
		_tri(st, pa + dx, pr + dx, pl + dx, Vector3(1, 0, 0))
		_quad(st, Vector3(-L, -H, -W), Vector3(-L, -H, W), Vector3(L, -H, W), Vector3(L, -H, -W), Vector3.DOWN, L * 2.0, W * 2.0, -1.0, -1.0)
	st.generate_tangents()  # normal maps need tangents; without them shaded faces go black
	var mesh := st.commit()
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = surfaces[r["material"]]
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(mesh.get_faces())
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	return body

## UV in metres (the shader divides by uv_scale); UV2.x is metres from the face's top edge (top0 at
## p0/p1, top1 at p2/p3) and UV2.y is 1 on surf faces, 0 where no grime belongs (top < 0).
func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, ulen: float, vlen: float, top0: float, top1: float) -> void:
	var pts := [p0, p1, p2, p3]
	var uv := [Vector2(0, 0), Vector2(ulen, 0), Vector2(ulen, vlen), Vector2(0, vlen)]
	var face := 1.0 if top0 >= 0.0 else 0.0
	var uv2 := [Vector2(top0, face), Vector2(top0, face), Vector2(top1, face), Vector2(top1, face)]
	# Godot treats clockwise triangles as front faces; with culling off a back face shades with its
	# normal flipped (dark ramp faces), so every triangle is wound to face along n.
	var flip := (p1 - p0).cross(p2 - p0).dot(n) > 0.0
	for tri in ([[0, 2, 1], [0, 3, 2]] if flip else [[0, 1, 2], [0, 2, 3]]):
		for i in tri:
			st.set_normal(n)
			st.set_uv(uv[i])
			st.set_uv2(uv2[i])
			st.add_vertex(pts[i])

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	for p in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(p.y, p.z))
		st.set_uv2(Vector2.ZERO)
		st.add_vertex(p)

func _box_body(r: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	var size := Vector3(float(r["length"]), float(r["height"]), float(r["half_width"]) * 2.0)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat: Material = surfaces[r["material"]]
	if mat is ShaderMaterial:
		mat = mat.duplicate()
		mat.set_shader_parameter("world_map", true)  # boxes: textured in world space, no stretching
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	return body

## Scenery only: a textured box with no collision (the ground under the course).
func _decor(r: Dictionary) -> Node3D:
	var body := _box_body(r)
	for ch in body.get_children():
		if ch is CollisionShape3D:
			body.remove_child(ch)
			ch.free()
	var mi := body.get_child(0) as MeshInstance3D
	body.remove_child(mi)
	body.free()
	return mi

func _zone(r: Dictionary) -> Area3D:
	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(float(r["length"]), float(r["height"]), float(r["half_width"]) * 2.0)
	cs.shape = bs
	area.add_child(cs)
	area.body_entered.connect(func(body: Node3D) -> void:
		if body is SurfPlayer:
			_on_zone(r, body))
	return area

func _on_zone(r: Dictionary, player: SurfPlayer) -> void:
	match r["kind"]:
		"checkpoint":
			checkpoint_pos = _v3(r["pos"])
			checkpoint_pos.y += 0.3 - float(r["height"]) * 0.5
			checkpoint_yaw = float(r["yaw"])
		"zone_kill":
			player.teleport(checkpoint_pos, checkpoint_yaw)
	entered_zone.emit(r["kind"], r["id"])

func restart(player: SurfPlayer) -> void:
	checkpoint_pos = spawn_pos
	checkpoint_yaw = spawn_yaw
	player.teleport(spawn_pos, spawn_yaw)

func to_checkpoint(player: SurfPlayer) -> void:
	player.teleport(checkpoint_pos, checkpoint_yaw)

## Weathered surface: the base texture, a second (cracked, dirty) texture over part of it by noise,
## large tint patches, dirt streaks down from a ramp's top edge with a chipped lip, and a close-up
## detail overlay so the surface stays sharp under the player.
const SURFACE_SHADER := "shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tex_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_a : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_b : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_b : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_nrm = false;
uniform bool has_b = false;
uniform bool world_map = false;
uniform float scale_a = 4.0;
uniform float weather = 0.3;
uniform float grime = 0.5;
uniform float detail = 0.3;
uniform float roughness_val = 0.85;
varying vec3 wpos;
varying vec3 wn;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.03 + vec2(17.1, 9.2); a *= 0.5; }
	return s / 0.9375;
}
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec2 m = UV;
	if (world_map) {
		vec3 an = abs(wn);
		m = an.y > max(an.x, an.z) ? wpos.xz : (an.x > an.z ? wpos.zy : wpos.xy);
	}
	vec2 uv = m / scale_a;
	vec3 c = texture(tex_a, uv).rgb;
	vec3 nm = has_nrm ? texture(nrm_a, uv).rgb : vec3(0.5, 0.5, 1.0);
	float rough = roughness_val;
	if (has_b) {
		float w = smoothstep(1.0 - weather - 0.1, 1.0 - weather + 0.1, fbm(m / (scale_a * 2.7) + vec2(5.3, 1.7)));
		vec2 uvb = m / (scale_a * 1.3) + vec2(0.31, 0.77);
		c = mix(c, texture(tex_b, uvb).rgb * mix(c, vec3(dot(c, vec3(0.333))), 0.5) / max(vec3(dot(c, vec3(0.333))), vec3(0.05)), w * 0.85);
		nm = mix(nm, texture(nrm_b, uvb).rgb, w * 0.85);
	}
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	vec3 mean = textureLod(tex_a, vec2(0.5), 12.0).rgb;
	vec3 dt = texture(tex_a, uv * 7.31 + vec2(0.13, 0.57)).rgb;
	c *= mix(vec3(1.0), dt / max(mean, vec3(0.04)), detail * (1.0 - smoothstep(3.0, 18.0, dist)));
	c *= mix(0.86, 1.08, fbm(m / 23.0 + vec2(11.0, 3.0)));
	float face = UV2.y;
	float top = UV2.x;
	float streak = smoothstep(0.42, 0.8, fbm(vec2(m.x * 0.9, top * 0.07) + vec2(2.0, 9.0)));
	float s = streak * exp(-top / 7.0) * grime * face;
	float pool = smoothstep(0.55, 0.8, fbm(m / 6.0 + vec2(41.0, 13.0))) * grime * face * 0.5;
	c *= 1.0 - 0.5 * s - 0.25 * pool;
	rough = mix(rough, 1.0, s * 0.5);
	float lip = (1.0 - smoothstep(0.06, 0.4, top)) * face * grime * step(0.001, grime);
	float chip = smoothstep(0.35, 0.65, vnoise(vec2(m.x * 3.0, top * 6.0)));
	c = mix(c, c * 1.22 + vec3(0.025), lip * chip);
	ALBEDO = c;
	NORMAL_MAP = nm;
	ROUGHNESS = rough;
}
"
