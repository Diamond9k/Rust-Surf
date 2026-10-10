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
var _trim_mat: Material

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
	for d in sheet["paint"]:
		_paint(d)

## course.json paint: one Decal per row, a band of a Rust decal atlas (rect is u0, v0, u1, v1 of the
## texture) laid flat at pos, length along yaw, projected down onto whatever is under it.
func _paint(d: Dictionary) -> void:
	var t := content.texture(d["texture"], "MainTex")
	if t == null:
		return
	var rc: Array = d["rect"]
	var img := t.get_image()
	var sz := Vector2(img.get_width(), img.get_height())
	var px := Rect2i(Vector2i(Vector2(rc[0], rc[1]) * sz), Vector2i(Vector2(float(rc[2]) - float(rc[0]), float(rc[3]) - float(rc[1])) * sz))
	var dc := Decal.new()
	dc.name = d["id"]
	dc.texture_albedo = _region(img, px)
	var n := content.texture(d["texture"], "BumpMap")
	if n:
		dc.texture_normal = _region(n.get_image(), Rect2i(Vector2i(Vector2(px.position) * Vector2(n.get_width(), n.get_height()) / sz), Vector2i(Vector2(px.size) * Vector2(n.get_width(), n.get_height()) / sz)))
	dc.size = Vector3(float(d["length"]), 1.0, float(d["width"]))
	dc.albedo_mix = float(d["opacity"])
	var tn: Array = d["tint"]
	dc.modulate = Color(tn[0], tn[1], tn[2], float(d["opacity"]))
	dc.upper_fade = 0.1
	dc.lower_fade = 0.1
	add_child(dc)
	dc.transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(float(d["yaw"])), 0)), _v3(d["pos"]))

func _region(img: Image, px: Rect2i) -> ImageTexture:
	var r := img.get_region(px)
	if r.is_compressed():
		r.decompress()
	r.generate_mipmaps()
	return ImageTexture.create_from_image(r)

func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

## materials.json row -> StandardMaterial3D using textures read from Rust.
func _material(m: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = float(m["roughness"])
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if m.get("color", "(none)") is Array:
		# plain colour, no texture: the far ground ring has nothing to tile or shimmer, fog fades it into the horizon
		var c: Array = m["color"]
		mat.albedo_color = Color(c[0], c[1], c[2])
	elif m["albedo"] != "(none)":
		var t := content.texture(m["albedo"], "MainTex")
		if t:
			mat.albedo_texture = t
			# anisotropic: ground and ramps seen at grazing angles keep their detail instead of blurring
			# aniso keeps ramps detailed at grazing angles; sharp (no mips) is the crisp far gravel the Gauntlet critics preferred
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR if m.get("filter", "aniso") == "sharp" else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var n := _normal(m)
		if n:
			mat.normal_enabled = true
			mat.normal_texture = n
	else:
		mat.albedo_color = Color(0.2, 0.9, 0.4, 0.15)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

## A row's normal map; "(none)" for textures Rust ships without one (glass_industrial).
func _normal(m: Dictionary) -> Texture2D:
	return null if m["normal"] == "(none)" else content.texture(m["normal"], "BumpMap")

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
	sm.set_shader_parameter("nrm_a", _normal(m))
	sm.set_shader_parameter("has_nrm", _normal(m) != null)
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
	sm.set_shader_parameter("panel", float(m["panel"]))
	sm.set_shader_parameter("crease_ao", float(m["crease_ao"]))
	sm.set_shader_parameter("normal_depth", float(m["normal_depth"]))
	sm.set_shader_parameter("seam_lock", float(m["seam_lock"]))
	sm.set_shader_parameter("panel_tone", float(m["panel_tone"]))
	sm.set_shader_parameter("weather_crop", float(m["weather_crop"]))
	sm.set_shader_parameter("tile_crop_v", float(m["tile_crop_v"]))
	var tn: Array = m["tint"]
	sm.set_shader_parameter("tint", Vector3(tn[0], tn[1], tn[2]))
	var W: Dictionary = sheet["weathering"]
	var lk := content.texture(W["texture"], "MainTex")
	sm.set_shader_parameter("has_leak", lk != null and (float(m["leaks"]) > 0.0 or float(m["debris"]) > 0.0))
	if lk:
		sm.set_shader_parameter("tex_leak", lk)
	sm.set_shader_parameter("leaks", float(m["leaks"]))
	sm.set_shader_parameter("debris", float(m["debris"]))
	for k in ["leak_v", "debris_v"]:
		var a: Array = W[k]
		sm.set_shader_parameter(k, Vector2(a[0], a[1]))
	for k in ["leak_len", "leak_width", "debris_width", "groove", "groove_width", "edge_wear", "leak_vary", "leak_gap", "tie_hole", "rust_len", "rust_width", "rust_keep"]:
		sm.set_shader_parameter(k, float(W[k]))
	sm.set_shader_parameter("ties", float(m["ties"]))
	var tpi: Array = W["tie_pitch"]
	sm.set_shader_parameter("tie_pitch", Vector2(tpi[0], tpi[1]))
	var rt: Array = W["rust_tint"]
	sm.set_shader_parameter("rust_tint", Vector3(rt[0], rt[1], rt[2]))
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
	var trims := SurfaceTool.new()
	trims.begin(Mesh.PRIMITIVE_TRIANGLES)
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
		_quad(st, p0, p1, p2, p3, n, L * 2.0, slope, 0.0 if ridge else slope, slope if ridge else 0.0, slope)
		# steel trim strips along the face's exposed edges: both edges of a ridge face, the rim of a valley
		if ridge:
			_trim(trims, p0, p1, p2, p3, n)
		_trim(trims, p3, p2, p1, p0, n)
	if ridge:
		var pa := Vector3(-L, H, 0); var pl := Vector3(-L, -H, -W); var pr := Vector3(-L, -H, W)
		_tri(st, pa, pl, pr, Vector3(-1, 0, 0))
		var dx := Vector3(2 * L, 0, 0)
		_tri(st, pa + dx, pr + dx, pl + dx, Vector3(1, 0, 0))
		_quad(st, Vector3(-L, -H, -W), Vector3(-L, -H, W), Vector3(L, -H, W), Vector3(L, -H, -W), Vector3.DOWN, L * 2.0, W * 2.0, -1.0, -1.0, 0.0)
	else:
		_valley_shell(st, L, W, H)
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
	trims.generate_tangents()
	var tm := MeshInstance3D.new()
	tm.name = "trim"
	tm.mesh = trims.commit()
	tm.material_override = _trim_material()
	body.add_child(tm)  # scenery only: the collision stays the bare prism
	return body

## course.json shell: a valley is a solid cast block, not a folded sheet: a flat coping shell.coping metres
## wide outside each rim, outer walls down to shell.skirt metres below the crease, a base, and end caps
## cut in the V. Part of the collision, so what looks solid is solid.
func _valley_shell(st: SurfaceTool, L: float, W: float, H: float) -> void:
	var c := float(sheet["shell"]["coping"])
	var y0 := -H - float(sheet["shell"]["skirt"])
	var o := W + c
	for s: float in [-1.0, 1.0]:
		_quad(st, Vector3(-L, H, W * s), Vector3(L, H, W * s), Vector3(L, H, o * s), Vector3(-L, H, o * s), Vector3.UP, L * 2.0, c, -1.0, -1.0, 0.0)
		_quad(st, Vector3(-L, H, o * s), Vector3(L, H, o * s), Vector3(L, y0, o * s), Vector3(-L, y0, o * s), Vector3(0, 0, s), L * 2.0, H - y0, -1.0, -1.0, 0.0)
	_quad(st, Vector3(-L, y0, -o), Vector3(-L, y0, o), Vector3(L, y0, o), Vector3(L, y0, -o), Vector3.DOWN, L * 2.0, o * 2.0, -1.0, -1.0, 0.0)
	# end caps: the block's cross-section (z, y) less the V, triangulated
	var poly := PackedVector2Array([Vector2(-o, H), Vector2(-W, H), Vector2(0, -H), Vector2(W, H), Vector2(o, H), Vector2(o, y0), Vector2(-o, y0)])
	var tris := Geometry2D.triangulate_polygon(poly)
	for x: float in [-L, L]:
		var n := Vector3(signf(x), 0, 0)
		for i in range(0, tris.size(), 3):
			var p: Array[Vector3] = []
			for k in 3:
				var q := poly[tris[i + k]]
				p.append(Vector3(x, q.y, q.x))
			if (p[1] - p[0]).cross(p[2] - p[0]).dot(n) > 0.0:
				_tri(st, p[0], p[2], p[1], n)
			else:
				_tri(st, p[0], p[1], p[2], n)

## course.json trim: a steel flat trim.width metres wide on the face, from the edge e0-e1 toward f1-f0,
## standing trim.offset proud of it, with its inner side face closed so the edge reads as a solid capping
## that catches the sun; UV in metres with v starting at trim.v0 (the band of the trim texture).
func _trim(st: SurfaceTool, e0: Vector3, e1: Vector3, f1: Vector3, f0: Vector3, n: Vector3) -> void:
	var T: Dictionary = sheet["trim"]
	var w := float(T["width"])
	var th := float(T["offset"])
	var lift := n * th
	var d0 := (f0 - e0).normalized() * w
	var d1 := (f1 - e1).normalized() * w
	var ulen := e0.distance_to(e1)
	var v0 := float(T["v0"])
	_trim_quad(st, [e0 + lift, e1 + lift, e1 + d1 + lift, e0 + d0 + lift], n, [Vector2(0, v0), Vector2(ulen, v0), Vector2(ulen, v0 + w), Vector2(0, v0 + w)])
	var side := d0.normalized()
	_trim_quad(st, [e0 + d0 + lift, e1 + d1 + lift, e1 + d1, e0 + d0], side, [Vector2(0, v0 + w), Vector2(ulen, v0 + w), Vector2(ulen, v0 + w + th), Vector2(0, v0 + w + th)])

func _trim_quad(st: SurfaceTool, pts: Array, n: Vector3, uv: Array) -> void:
	var flip := ((pts[1] as Vector3) - (pts[0] as Vector3)).cross((pts[2] as Vector3) - (pts[0] as Vector3)).dot(n) > 0.0
	for tri in ([[0, 2, 1], [0, 3, 2]] if flip else [[0, 1, 2], [0, 2, 3]]):
		for i in tri:
			st.set_normal(n)
			st.set_uv(uv[i])
			st.set_uv2(Vector2(-1, -1))
			st.add_vertex(pts[i])

func _trim_material() -> Material:
	if _trim_mat == null:
		_trim_mat = surfaces[sheet["trim"]["material"]]
		if _trim_mat is ShaderMaterial:
			_trim_mat = _trim_mat.duplicate()
			_trim_mat.set_shader_parameter("atlas", true)  # one band of an atlas: no second sampling
	return _trim_mat

## UV in metres (the shader divides by uv_scale); on surf faces UV2.x is metres from the face's top
## edge (top0 at p0/p1, top1 at p2/p3) and UV2.y metres from its bottom edge (slope - top); faces with
## no edge wear (top < 0: undersides, end caps) get UV2 (-1, -1).
func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, ulen: float, vlen: float, top0: float, top1: float, slope: float) -> void:
	var pts := [p0, p1, p2, p3]
	var uv := [Vector2(0, 0), Vector2(ulen, 0), Vector2(ulen, vlen), Vector2(0, vlen)]
	var a := Vector2(top0, slope - top0) if top0 >= 0.0 else Vector2(-1, -1)
	var b := Vector2(top1, slope - top1) if top0 >= 0.0 else Vector2(-1, -1)
	var uv2 := [a, a, b, b]
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
		st.set_uv2(Vector2(-1, -1))
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
## large tint patches, cast slabs with their own tone and dark joints, dirt streaks down from a ramp's
## top edge with a chamfered, chipped lip, grime and occlusion in the crease at its foot, and a
## close-up detail overlay so the surface stays sharp under the player.
const SURFACE_SHADER := "shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tex_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_a : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_b : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_b : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_nrm = false;
uniform bool has_b = false;
uniform bool world_map = false;
uniform bool atlas = false;
uniform float scale_a = 4.0;
uniform float weather = 0.3;
uniform float grime = 0.5;
uniform float detail = 0.3;
uniform float roughness_val = 0.85;
uniform float panel = 0.0;
uniform float crease_ao = 0.0;
uniform float normal_depth = 1.0;
uniform float seam_lock = 0.0;
uniform float panel_tone = 0.0;
uniform float weather_crop = 0.0;
uniform float tile_crop_v = 0.0;
uniform float groove = 0.0;
uniform float groove_width = 0.05;
uniform float edge_wear = 0.0;
uniform vec3 tint = vec3(1.0);
uniform sampler2D tex_leak : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_leak = false;
uniform float leaks = 0.0;
uniform float debris = 0.0;
uniform vec2 leak_v = vec2(0.615, 0.92);
uniform vec2 debris_v = vec2(0.32, 0.17);
uniform float leak_len = 6.0;
uniform float leak_width = 5.0;
uniform float debris_width = 2.0;
uniform float leak_vary = 0.0;
uniform float leak_gap = 0.0;
uniform float ties = 0.0;
uniform vec2 tie_pitch = vec2(1.0, 0.8);
uniform float tie_hole = 0.03;
uniform float rust_len = 2.5;
uniform float rust_width = 0.12;
uniform float rust_keep = 0.3;
uniform vec3 rust_tint = vec3(0.8, 0.55, 0.38);
varying vec3 wpos;
varying vec3 wn;
varying flat vec2 face_off;  // flat: interpolation jitter fed into hash() speckled the leak decals and slab joints per pixel

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
// tile_crop_v trims the bevel a slab texture draws along its top and bottom edge, so the panels run on as
// long strips instead of a grid; gradients from the unwrapped uv keep the mips seamless
vec2 vcrop(vec2 p) { return vec2(p.x, fract(p.y) * (1.0 - 2.0 * tile_crop_v) + tile_crop_v); }
vec3 ta(vec2 p) { return textureGrad(tex_a, vcrop(p), dFdx(p), dFdy(p)).rgb; }
vec3 tn(vec2 p) { return textureGrad(nrm_a, vcrop(p), dFdx(p), dFdy(p)).rgb; }
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// each face of each piece samples its textures from its own place: the two walls of a valley no
	// longer show the same crack at the same spot
	float side = sign(NORMAL.z) + 2.0 * sign(NORMAL.x) + 4.0 * sign(NORMAL.y);
	vec2 np = NODE_POSITION_WORLD.xz * 0.013 + side * vec2(5.3, 1.1);
	face_off = floor(vec2(hash(np), hash(np.yx + vec2(2.9, 8.3))) * 97.0);
}
// a band of a decal atlas (v from v0 at t = 0 to v1 at t = 1), u running along the edge in leak_width
// metre tiles, each tile picking the left or right half of the atlas; derivatives taken before the
// tile wrap so mipmaps do not seam. The atlas is black where clear but speckled with stray pixels
// where half clear (they read as dots), so the colour comes from a blurrier mip divided by its alpha
// and the alpha is tightened
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
	if (world_map) {
		vec3 an = abs(wn);
		m = an.y > max(an.x, an.z) ? wpos.xz : (an.x > an.z ? wpos.zy : wpos.xy);
	}
	vec2 mo = m + (world_map ? vec2(0.0) : face_off);  // texture space only; slab joints stay on m
	vec2 uv = mo / scale_a;
	vec3 c = ta(uv);
	vec3 nm = has_nrm ? tn(uv) : vec3(0.5, 0.5, 1.0);
	// a second, larger sampling of the same texture over half the surface by noise: no visible repeat
	vec2 uv3 = mo / (scale_a * 2.37) + vec2(0.21, 0.67);
	if (seam_lock > 0.0) {
		// a texture with cast panel seams baked in: the second sampling moves one whole panel along u, so
		// its seams fall on the first's instead of crossing them
		uv3 = uv + vec2(1.0 / seam_lock, 0.0);
	}
	float k3 = atlas ? 0.0 : 0.6 * smoothstep(0.35, 0.65, fbm(mo / (scale_a * 3.1) + vec2(8.0, 2.0)));
	c = mix(c, ta(uv3), k3);
	if (has_nrm) { nm = mix(nm, tn(uv3), k3); }
	float rough = roughness_val * mix(1.0, 0.72, smoothstep(0.5, 0.75, fbm(m / 9.0 + vec2(23.0, 5.0))));  // worn, smoother patches catch the sun
	if (has_b) {
		float w = smoothstep(1.0 - weather - 0.1, 1.0 - weather + 0.1, fbm(mo / (scale_a * 2.7) + vec2(5.3, 1.7)));
		// the cracked texture twice, the second turned a quarter and at an unrelated scale, crossfaded by
		// noise, so its crack network never repeats in a grid down a long ramp
		vec2 uvb = mo / (scale_a * 1.3) + vec2(0.31, 0.77);
		vec2 uvb2 = vec2(-mo.y, mo.x) / (scale_a * 1.87) + vec2(0.53, 0.19);
		float kb = smoothstep(0.4, 0.6, fbm(mo / (scale_a * 1.9) + vec2(27.0, 13.0)));
		// weather_crop trims the dark border some Rust textures carry round each tile (a grid of lines
		// across the ramp otherwise); gradients from the unwrapped uv keep the mips seamless
		vec2 cb1 = fract(uvb) * (1.0 - 2.0 * weather_crop) + weather_crop;
		vec2 cb2 = fract(uvb2) * (1.0 - 2.0 * weather_crop) + weather_crop;
		vec3 cb = mix(textureGrad(tex_b, cb1, dFdx(uvb), dFdy(uvb)).rgb, textureGrad(tex_b, cb2, dFdx(uvb2), dFdy(uvb2)).rgb, kb);
		vec3 nb = mix(textureGrad(nrm_b, cb1, dFdx(uvb), dFdy(uvb)).rgb, textureGrad(nrm_b, cb2, dFdx(uvb2), dFdy(uvb2)).rgb, kb);
		c = mix(c, cb * mix(c, vec3(dot(c, vec3(0.333))), 0.5) / max(vec3(dot(c, vec3(0.333))), vec3(0.05)), w * 0.85);
		nm = mix(nm, nb, w * 0.85);
	}
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	vec3 mean = textureLod(tex_a, vec2(0.5), 12.0).rgb;
	vec3 dt = ta(uv * 7.31 + vec2(0.13, 0.57));
	float near = atlas ? 0.0 : detail * (1.0 - smoothstep(3.0, 18.0, dist));
	c *= mix(vec3(1.0), dt / max(mean, vec3(0.04)), near);
	if (has_nrm) {
		vec3 dn = tn(uv * 7.31 + vec2(0.13, 0.57));
		nm = vec3(nm.xy + (dn.xy - 0.5) * near * 1.2, nm.z);  // detail normal: fine grain under the player
	}
	c *= mix(0.8, 1.1, fbm(mo / 17.0 + vec2(11.0, 3.0)));
	if (seam_lock > 0.0) {
		// each cast panel its own pour: a tone per panel strip, a little lighter or darker than its neighbours
		float strip = floor(uv.x * seam_lock);
		c *= 1.0 + panel_tone * (hash(vec2(strip, face_off.x + 7.0)) * 2.0 - 1.0);
	}
	c *= tint;
	float face = world_map ? 0.0 : step(0.0, UV2.y);  // boxes have no UV2: no edge wear
	float top = max(UV2.x, 0.0);
	float bot = max(UV2.y, 0.0);
	float occ = 1.0;
	if (panel > 0.0 && face > 0.5) {
		// rows of cast slabs, each row with its own slab length and offset so the joints never line
		// up into a grid down a long ramp
		float row = floor(m.y / panel);
		vec2 ps = vec2(panel * mix(1.2, 2.4, hash(vec2(row, 5.0) + face_off)), panel);
		vec2 pc = vec2(m.x / ps.x + hash(vec2(row, 9.0) + face_off), m.y / ps.y);
		if (seam_lock > 0.0) {
			// the texture's own cast seams run every strip metres along u: slabs one to three strips long,
			// each row offset by whole strips, so every vertical joint lands on a baked seam
			float strip = scale_a / seam_lock;
			float ns = 1.0 + floor(hash(vec2(row, 5.0) + face_off) * 3.0);
			ps.x = strip * ns;
			pc.x = ((m.x + face_off.x) / strip + floor(hash(vec2(row, 9.0) + face_off) * ns)) / ns;
		}
		vec2 f = fract(pc);
		c *= mix(0.9, 1.07, hash(floor(pc) + vec2(3.0, 7.0)));
		rough *= mix(0.86, 1.08, hash(floor(pc) + vec2(19.0, 2.0)));  // each pour cured its own way: some slabs sheen more
		vec2 e = min(f, 1.0 - f) * ps;
		float d = min(e.x, e.y);
		float w = max(0.03, fwidth(d) * 1.5);
		float joint = (1.0 - smoothstep(w * 0.5, w, d)) * (1.0 - smoothstep(25.0, 90.0, dist));
		// each joint is a shallow V groove: the slab edges either side tilt into it, so under the sun one
		// lip catches the light and the other falls dark
		vec2 gs = vec2(f.x < 0.5 ? -1.0 : 1.0, f.y < 0.5 ? -1.0 : 1.0);
		vec2 g = (1.0 - smoothstep(vec2(0.0), vec2(max(groove_width, w)), e)) * (1.0 - smoothstep(30.0, 120.0, dist));
		g *= 1.0 - smoothstep(groove_width * 0.3, groove_width, fwidth(d));  // under a pixel wide the groove only flickers
		nm.xy += gs * g * groove;
		c *= 1.0 - 0.24 * joint * mix(0.35, 1.0, hash(floor(pc) + vec2(13.0, 1.0)));  // some joints grouted, some dirty
		float under = (1.0 - smoothstep(0.0, 0.9, f.y * ps.y)) * (1.0 - smoothstep(60.0, 200.0, dist));
		c *= 1.0 - 0.12 * under * grime;
		rough = mix(rough, 1.0, joint * 0.5);
	}
	if (ties > 0.0 && face > 0.5) {
		// form-tie holes in rows down the face, and below some of them a rust run bled from the rebar,
		// widening and fading as it runs down the slope; faded to its average once under a pixel or two
		vec2 tp = vec2(m.x + face_off.x, top) / tie_pitch;
		vec2 tc = floor(tp);
		vec2 tf = (fract(tp) - 0.5) * tie_pitch;
		float hole = (1.0 - smoothstep(tie_hole * 0.6, tie_hole, length(tf))) * (1.0 - smoothstep(8.0, 20.0, dist));
		c *= 1.0 - 0.55 * hole * ties;
		float rs = 0.0;
		for (int k = 0; k < 3; k++) {
			vec2 cc = tc - vec2(0.0, float(k));
			float dy = (tp.y - cc.y - 0.5) * tie_pitch.y;  // metres below that row's tie
			float len = rust_len * mix(0.35, 1.0, hash(cc + vec2(7.0, 3.0)));
			float t = clamp(dy / len, 0.0, 1.0);
			float wid = rust_width * mix(0.35, 1.0, sqrt(t)) * mix(0.75, 1.25, vnoise(vec2(m.x * 6.0, top * 1.3)));
			float run = (1.0 - smoothstep(wid * 0.5, wid, abs(tf.x))) * step(0.0, dy) * (1.0 - smoothstep(0.4, 1.0, t));
			rs = max(rs, run * step(1.0 - rust_keep, hash(cc + vec2(31.0, 5.0))) * mix(0.45, 1.0, vnoise(vec2(m.x * 14.0, top * 3.0))));
		}
		rs = mix(rs, rust_keep * 0.12, smoothstep(0.5, 1.5, fwidth(m.x) / rust_width));
		c = mix(c, c * rust_tint, clamp(rs * ties, 0.0, 1.0));
		rough = mix(rough, 1.0, rs * ties * 0.5);
	}
	if (face > 0.5) {
		float wb = max(0.05, fwidth(top) * 1.5);
		float bevel = 1.0 - smoothstep(0.12, 0.12 + wb, top);
		float shade = (1.0 - smoothstep(0.2, 0.2 + wb, top)) * (1.0 - bevel);
		c *= 1.0 + 0.2 * bevel - 0.3 * shade;
		// the crease: wide soft occlusion plus a narrow dark gutter, which also hides the shadow-map
		// light leak where the two faces of a valley meet
		occ = mix(1.0 - crease_ao, 1.0, smoothstep(0.0, 3.5, bot)) * mix(1.0 - crease_ao * 1.3, 1.0, smoothstep(0.05, 0.7, bot));
		occ = clamp(occ, 0.05, 1.0);
		c *= mix(occ, 1.0, 0.35);
	}
	float streak = smoothstep(0.42, 0.8, fbm(vec2(mo.x * 0.9, top * 0.07) + vec2(2.0, 9.0)));
	float s = streak * exp(-top / 7.0) * grime * face;
	float pool = smoothstep(0.55, 0.8, fbm(mo / 6.0 + vec2(41.0, 13.0))) * grime * face * 0.5;
	c *= 1.0 - 0.5 * s - 0.25 * pool;
	rough = mix(rough, 1.0, s * 0.5);
	float lip = (1.0 - smoothstep(0.06, 0.4, top)) * face * grime * step(0.001, grime);
	float chip = smoothstep(0.35, 0.65, vnoise(vec2(m.x * 3.0, top * 6.0)));
	c = mix(c, c * 1.22 + vec3(0.025), lip * chip);
	// worn arris: the top edge scuffed smooth by boots, with chipped-out pits that stay rough
	float wear = (1.0 - smoothstep(0.0, 0.9, top)) * face * edge_wear;
	float pit = smoothstep(0.62, 0.8, vnoise(vec2(m.x * 7.0, top * 9.0) + vec2(4.0, 1.0)));
	rough = mix(rough, mix(0.45, 1.0, pit), wear);
	nm.xy += (vec2(vnoise(m * 14.0), vnoise(m * 14.0 + vec2(7.0, 3.0))) - 0.5) * pit * wear * 0.8;
	if (has_leak) {  // uniform branch only: the atlas lookups need derivatives, undefined per pixel branch
		// Rust's own leak decals (dirt_stains_leaks) hanging from the top edge, in runs along it
		float run = smoothstep(0.35, 0.6, fbm(vec2(mo.x / 11.0, 3.7)));
		// each atlas tile hangs its own length and strength, and some hang none, so the drips stop
		// reading as one decal repeated along the edge
		float lt = floor((m.x + face_off.x) / leak_width);
		float ll = leak_len * mix(1.0 - leak_vary, 1.0 + leak_vary * 0.5, hash(vec2(lt, face_off.y + 5.0)));
		float lkeep = step(leak_gap, hash(vec2(lt, face_off.y + 17.0))) * mix(0.55, 1.0, hash(vec2(lt, face_off.y + 29.0)));
		vec4 lk = band(leak_v, (m.x + face_off.x) / leak_width, top / ll, face_off.y);
		float la = lk.a * leaks * run * lkeep * face * (1.0 - smoothstep(0.75, 1.0, top / ll));
		c = mix(c, mix(lk.rgb, vec3(dot(lk.rgb, vec3(0.333))), 0.35) * 0.75, clamp(la, 0.0, 1.0));
		rough = mix(rough, 1.0, la * 0.4);
		// gravel and litter washed into the foot of the face (the crease of a valley)
		vec4 db = band(debris_v, (m.x + face_off.y) / (leak_width * 1.6), bot / debris_width, face_off.x + 3.0);
		float da = db.a * debris * face * (1.0 - smoothstep(0.8, 1.0, bot / debris_width));
		c = mix(c, db.rgb, clamp(da, 0.0, 1.0));
		rough = mix(rough, 1.0, da);
	}
	ALBEDO = c;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_depth;
	ROUGHNESS = rough;
	AO = occ;
	AO_LIGHT_AFFECT = 1.0 - 0.5 * smoothstep(0.0, 1.0, UV2.y);
}
"
