## systems.backdrop: the real Launch Site, placed from rust/launch_site_placements.json, and the
## terrain it sits in (course.json "terrain"). prep already flips meshes to the Godot right-handed
## Y-up frame; here only the placements are converted: z -> -z, quaternion (x,y,z,w) -> (-x,-y,z,w).
class_name Backdrop
extends Node3D

const EMPTY := -1.0e9

var content: Content
var meshes := {}
var mats := {}
var placed := 0
var nodes: Array[MeshInstance3D] = []
var T: Dictionary
var terrain: MeshInstance3D
var pit_cells := 0
var _noise: FastNoiseLite
var _ridge: FastNoiseLite
var _x0: float
var _z0: float
var _nx: int
var _nz: int
var _pit := PackedByteArray()

func build(c: Content, offset: Vector3, yaw_deg: float) -> void:
	content = c
	T = Sheets.load_sheet("course")["terrain"]
	transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(yaw_deg), 0)), offset)
	var data: Variant = content.json("scene_launch_site")
	if data != null:
		for p in data["placements"]:
			var mesh := _mesh(p["mesh"])
			if mesh == null:
				continue
			var q: Array = p["rot"]
			var s: Array = p["scale"]
			var sc := Vector3(s[0], s[1], s[2])
			var sgn := sc.sign()
			if sgn.x * sgn.y * sgn.z < 0.0:  # mirrored placement (some mounds): bake the mirror into the mesh
				mesh = _mirrored(p["mesh"], mesh, sgn)
				sc = sc.abs()
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			var basis := Basis(Quaternion(-q[0], -q[1], q[2], q[3])) * Basis.from_scale(sc)  # Unity TRS: scale is local
			var pos: Array = p["pos"]
			mi.transform = Transform3D(basis, Vector3(pos[0], pos[1], -pos[2]))
			add_child(mi)
			nodes.append(mi)
			placed += 1
	_pit_mask()
	_terrain()

func _mesh(name: String) -> Mesh:
	if meshes.has(name):
		return meshes[name]
	var scene := content.glb(content.dir.path_join("rust/mesh").path_join(name + ".glb"))
	var found: Mesh = null
	if scene:
		for mi in _all(scene, "MeshInstance3D"):
			found = mi.mesh
			break
		scene.queue_free()
	if found:
		for i in found.get_surface_count():
			found.surface_set_material(i, _fix(found.surface_get_material(i)))
	meshes[name] = found
	return found

## A mirrored copy of a mesh: positions, normals and tangents reflected and the winding reversed, so
## the faces stay outward. A negative-scale instance showed the mound's inside as a black blob.
func _mirrored(name: String, mesh: Mesh, sgn: Vector3) -> Mesh:
	var key := "%s|%v" % [name, sgn]
	if meshes.has(key):
		return meshes[key]
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(i)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for k in v.size():
			v[k] *= sgn
		arr[Mesh.ARRAY_VERTEX] = v
		if arr[Mesh.ARRAY_NORMAL] != null:
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			for k in n.size():
				n[k] *= sgn
			arr[Mesh.ARRAY_NORMAL] = n
		if arr[Mesh.ARRAY_TANGENT] != null:
			var t: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
			for k in range(0, t.size(), 4):
				t[k] *= sgn.x
				t[k + 1] *= sgn.y
				t[k + 2] *= sgn.z
				t[k + 3] = -t[k + 3]
			arr[Mesh.ARRAY_TANGENT] = t
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			for k in v.size():
				idx.append(k)
		for k in range(0, idx.size(), 3):
			var a := idx[k + 1]
			idx[k + 1] = idx[k + 2]
			idx[k + 2] = a
		arr[Mesh.ARRAY_INDEX] = idx
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(i, mesh.surface_get_material(i))
	meshes[key] = out
	return out

## One material per Rust material name, shared by every mesh, with mipmapped textures: runtime glTF
## textures have no mips, so distant buildings sparkled.
func _fix(m: Material) -> Material:
	if not (m is BaseMaterial3D):
		return m
	var key := m.resource_name
	if key != "" and mats.has(key):
		return mats[key]
	var b := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
	for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_ORM, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC]:
		var t := b.get_texture(slot)
		if t:
			var img := t.get_image()
			if img and not img.has_mipmaps():
				if img.is_compressed():
					img.decompress()
				img.generate_mipmaps()
				b.set_texture(slot, ImageTexture.create_from_image(img))
	b.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if key != "":
		mats[key] = b
	return b

func _all(n: Node, cls: String) -> Array:
	var out := []
	if n.get_class() == cls:
		out.append(n)
	for ch in n.get_children():
		out += _all(ch, cls)
	return out

## Ground height before the pit: the site's terrain levels (course.json terrain.steps) plus hills
## that rise outside the site rectangle so the horizon is land, not a grey strip.
func level(x: float) -> float:
	var y := float(T["base_y"])
	for s in T["steps"]:
		y += float(s["dy"]) * (1.0 - clampf((x - float(s["x0"])) / (float(s["x1"]) - float(s["x0"])), 0.0, 1.0))
	return y

func height(x: float, z: float) -> float:
	var r: Array = T["site_rect"]
	var dx := maxf(maxf(float(r[0]) - x, x - float(r[2])), 0.0)
	var dz := maxf(maxf(float(r[1]) - z, z - float(r[3])), 0.0)
	var d := sqrt(dx * dx + dz * dz)
	var y := level(x)
	if d > 0.0:
		var hl: Dictionary = T["hills"]
		var n := _noise.get_noise_2d(x, z) * 0.5 + 0.5
		y += float(hl["height"]) * smoothstep(0.0, float(hl["ramp"]), d) * (float(hl["floor"]) + (1.0 - float(hl["floor"])) * n)
		var rg := _ridge.get_noise_2d(x, z) * 0.5 + 0.5
		y += float(hl["far_height"]) * smoothstep(float(hl["far_start"]), float(hl["far_end"]), d) * (0.35 + 0.65 * rg)
	return y

## Which site cells are open pit: the launch pad and flame trench sink ~36 m below the ground, so the
## ground must not cover them. Every placed mesh that reaches below its ground level is rasterised into
## a top-height grid and the empty cells are flooded in from the edge; cells whose top is below the
## ground level, and empty cells the flood never reached (walled in by the pit), are pit.
func _pit_mask() -> void:
	var r: Array = T["site_rect"]
	var cell := float(T["cell"])
	var lip := float(T["pit_lip"])
	_x0 = float(r[0])
	_z0 = float(r[1])
	_nx = int(ceil((float(r[2]) - _x0) / cell))
	_nz = int(ceil((float(r[3]) - _z0) / cell))
	_pit.resize(_nx * _nz)
	_pit.fill(0)
	if nodes.is_empty():
		return
	var top := PackedFloat32Array()
	top.resize(_nx * _nz)
	top.fill(EMPTY)
	var inv := 1.0 / cell
	for mi in nodes:
		var xf := transform * mi.transform
		var box := xf * mi.get_aabb()
		if box.position.y >= level(box.get_center().x) - lip:
			continue  # buildings standing on the ground: the ground runs under them
		var f: PackedVector3Array = xf * mi.mesh.get_faces()
		for i in range(0, f.size(), 3):
			var a := f[i]
			var b := f[i + 1]
			var c := f[i + 2]
			var span := maxf(maxf(absf(a.x - b.x), absf(a.x - c.x)), maxf(absf(a.z - b.z), absf(a.z - c.z)))
			var n := int(span * inv * 2.0) + 1
			for u in n + 1:
				for v in n + 1 - u:
					var p := a + (b - a) * (float(u) / n) + (c - a) * (float(v) / n)
					var ix := int((p.x - _x0) * inv)
					var iz := int((p.z - _z0) * inv)
					if ix >= 0 and ix < _nx and iz >= 0 and iz < _nz:
						var k := iz * _nx + ix
						if p.y > top[k]:
							top[k] = p.y
	var outside := PackedByteArray()
	outside.resize(_nx * _nz)
	outside.fill(0)
	var q := PackedInt32Array()
	for ix in _nx:
		q.append(ix)
		q.append((_nz - 1) * _nx + ix)
	for iz in _nz:
		q.append(iz * _nx)
		q.append(iz * _nx + _nx - 1)
	var head := 0
	while head < q.size():
		var k := q[head]
		head += 1
		if outside[k] == 1 or top[k] != EMPTY:
			continue
		outside[k] = 1
		var ix := k % _nx
		if ix > 0: q.append(k - 1)
		if ix < _nx - 1: q.append(k + 1)
		if k >= _nx: q.append(k - _nx)
		if k < (_nz - 1) * _nx: q.append(k + _nx)
	for k in _nx * _nz:
		var x := _x0 + (float(k % _nx) + 0.5) * cell
		if top[k] == EMPTY:
			_pit[k] = 0 if outside[k] == 1 else 2  # 2: open pit floor, no mesh above it
		elif top[k] < level(x) - lip:
			_pit[k] = 1  # 1: a pit mesh is the surface here
		if _pit[k] > 0:
			pit_cells += 1

func _pit_at(x: float, z: float) -> int:
	var cell := float(T["cell"])
	var ix := int(floor((x - _x0) / cell))
	var iz := int(floor((z - _z0) / cell))
	if ix < 0 or ix >= _nx or iz < 0 or iz >= _nz:
		return 0
	return _pit[iz * _nx + ix]

## Grid lines: the site cell size inside the rectangle, growing outward to the far extent.
func _axis(a: float, b: float) -> PackedFloat32Array:
	var cell := float(T["cell"])
	var ext := float(T["extent"])
	var g := float(T["growth"])
	var left := PackedFloat32Array()
	var s := cell
	var p := a
	while p > a - ext:
		s *= g
		p -= s
		left.append(p)
	left.reverse()
	var out := left
	var n := int(ceil((b - a) / cell))
	for i in n + 1:
		out.append(a + i * cell)
	s = cell
	p = a + n * cell
	while p < b + ext:
		s *= g
		p += s
		out.append(p)
	return out

func _terrain() -> void:
	_noise = FastNoiseLite.new()
	var hl: Dictionary = T["hills"]
	_noise.seed = int(hl["seed"])
	_noise.frequency = 1.0 / float(hl["period"])
	_noise.fractal_octaves = 4
	_ridge = FastNoiseLite.new()  # far ridgelines: the horizon is a skyline of hills, not a flat strip
	_ridge.seed = int(hl["seed"]) + 1
	_ridge.frequency = 1.0 / float(hl["far_period"])
	_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge.fractal_octaves = 5
	var r: Array = T["site_rect"]
	var xs := _axis(float(r[0]), float(r[2]))
	var zs := _axis(float(r[1]), float(r[3]))
	var nx := xs.size()
	var nz := zs.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(nx * nz)
	norms.resize(nx * nz)
	for j in nz:
		for i in nx:
			var x := xs[i]
			var z := zs[j]
			verts[j * nx + i] = Vector3(x, height(x, z), z)
			norms[j * nx + i] = Vector3(height(x - 1.0, z) - height(x + 1.0, z), 2.0, height(x, z - 1.0) - height(x, z + 1.0)).normalized()
	var idx := PackedInt32Array()
	var floor_y := float(T["pit_floor_y"])
	for j in nz - 1:
		for i in nx - 1:
			var pit := _pit_at((xs[i] + xs[i + 1]) * 0.5, (zs[j] + zs[j + 1]) * 0.5)
			if pit == 1:
				continue
			var a := j * nx + i
			if pit == 2:  # open pit floor: its own four vertices at the floor height
				a = verts.size()
				for v in [Vector3(xs[i], floor_y, zs[j]), Vector3(xs[i + 1], floor_y, zs[j]), Vector3(xs[i], floor_y, zs[j + 1]), Vector3(xs[i + 1], floor_y, zs[j + 1])]:
					verts.append(v)
					norms.append(Vector3.UP)
				idx.append_array([a, a + 1, a + 3, a, a + 3, a + 2])
				continue
			idx.append_array([a, a + 1, a + nx + 1, a, a + nx + 1, a + nx])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	terrain = MeshInstance3D.new()
	terrain.name = "terrain"
	terrain.mesh = mesh
	terrain.top_level = true  # built in course coordinates, not the prefab's
	terrain.material_override = _terrain_material()
	add_child(terrain)
	terrain.global_transform = Transform3D.IDENTITY

func _terrain_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = TERRAIN_SHADER
	sm.shader = sh
	var rows := {}
	for m in Sheets.load_sheet("materials")["rows"]:
		rows[m["id"]] = m
	var layers: Array = T["layers"]
	var scales := Vector3.ONE
	for i in 3:
		var m: Dictionary = rows[layers[i]]
		sm.set_shader_parameter("tex%d" % i, content.texture(m["albedo"], "MainTex"))
		sm.set_shader_parameter("nrm%d" % i, content.texture(m["normal"], "BumpMap"))
		scales[i] = float(m["uv_scale"])
	sm.set_shader_parameter("scales", scales)
	var r: Array = T["site_rect"]
	sm.set_shader_parameter("site_rect", Vector4(r[0], r[1], r[2], r[3]))
	var sd: Dictionary = T["shading"]
	for k in sd:
		if String(k).begins_with("_"):
			continue
		var v: Variant = sd[k]
		sm.set_shader_parameter(k, Vector3(v[0], v[1], v[2]) if v is Array else float(v))
	sm.set_shader_parameter("pit_y", float(T["pit_floor_y"]))
	sm.set_shader_parameter("roughness_val", float(rows[layers[0]]["roughness"]))
	return sm

## Three ground layers (open ground, dirt, site concrete) mixed by world-space noise, each sampled at
## two unrelated scales so no tile repeats, and darkened or lifted in large patches.
const TERRAIN_SHADER := "shader_type spatial;
render_mode cull_back;
uniform sampler2D tex0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm0 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm1 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm2 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 scales = vec3(14.0, 9.0, 8.0);
uniform vec4 site_rect;
uniform float site_fade = 40.0;
uniform float site_cover = 0.5;
uniform float site_shade = 1.0;
uniform float dirt_cover = 0.3;
uniform float macro_period = 90.0;
uniform float macro_strength = 0.25;
uniform vec3 tint_a = vec3(1.0);
uniform vec3 tint_b = vec3(1.0);
uniform float tint_period = 260.0;
uniform float far_start = 60.0;
uniform float far_scale = 4.0;
uniform float pit_y = -36.0;
uniform float roughness_val = 0.95;
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
	TANGENT = vec3(1.0, 0.0, 0.0);
	BINORMAL = vec3(0.0, 0.0, 1.0);
}
void layer(sampler2D t, sampler2D n, vec2 p, float s, float m, float far, out vec3 c, out vec3 nm) {
	vec2 uv = p / s;
	vec2 uv2 = p / (s * 2.71) + vec2(0.37, 0.61);
	float k = smoothstep(0.3, 0.7, m);
	c = mix(texture(t, uv).rgb, texture(t, uv2).rgb, k);
	nm = mix(texture(n, uv).rgb, texture(n, uv2).rgb, k);
	vec3 cf = texture(t, uv / far_scale).rgb;
	c = mix(c, mix(c, cf, 0.6), far);
}
void fragment() {
	vec2 p = wpos.xz;
	float far = smoothstep(far_start, far_start * 4.0, length(wpos - CAMERA_POSITION_WORLD));
	float m = fbm(p / macro_period);
	float m2 = fbm(p / (macro_period * 0.43) + vec2(31.0, 7.0));
	float m3 = fbm(p / (macro_period * 0.21) + vec2(3.0, 51.0));
	vec3 c0; vec3 n0; vec3 c1; vec3 n1; vec3 c2; vec3 n2;
	layer(tex0, nrm0, p, scales.x, m3, far, c0, n0);
	layer(tex1, nrm1, p, scales.y, m, far, c1, n1);
	layer(tex2, nrm2, p, scales.z, m2, far, c2, n2);
	vec2 dd = max(max(site_rect.xy - p, p - site_rect.zw), vec2(0.0));
	float inside = 1.0 - smoothstep(0.0, site_fade, length(dd));
	float low = 1.0 - smoothstep(pit_y + 2.0, pit_y + 6.0, wpos.y);
	float slope = 1.0 - clamp(wn.y, 0.0, 1.0);
	float dirt = max(max(smoothstep(1.0 - dirt_cover - 0.05, 1.0 - dirt_cover + 0.05, m), smoothstep(0.08, 0.3, slope)), low);
	float site = inside * (1.0 - low) * smoothstep(1.0 - site_cover - 0.05, 1.0 - site_cover + 0.05, m2);
	vec3 c = mix(mix(c0, c1, dirt), c2 * site_shade, site);
	vec3 nm = mix(mix(n0, n1, dirt), n2, site);
	float tint = fbm(p / (macro_period * 2.3) + vec2(7.0, 3.0));
	c *= mix(1.0 - macro_strength, 1.0 + macro_strength * 0.6, tint);
	vec3 tn = mix(tint_a, tint_b, smoothstep(0.3, 0.7, fbm(p / tint_period + vec2(19.0, 41.0))));
	c *= mix(tn, vec3(1.0), site);  // open ground only: olive and brown patches; the site concrete stays grey
	ALBEDO = c;
	NORMAL_MAP = nm;
	ROUGHNESS = roughness_val;
}
"

## The sky for Main._lighting: lighting.json gradient, a sun disc with a halo where the sun light comes
## from, and a static cloud layer (nothing moves, so the sky light probe renders once).
static func sky_material(L: Dictionary) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SKY_SHADER
	sm.shader = sh
	for k in ["sky_top", "sky_horizon", "ground_horizon", "ground_bottom", "cloud_color", "cloud_shade"]:
		var a: Array = L[k]
		sm.set_shader_parameter(k, Color(a[0], a[1], a[2]))
	for k in ["sun_disc_deg", "sun_halo_deg", "sun_halo", "sun_disc_energy", "cloud_cover", "cloud_scale", "cloud_height_fade"]:
		sm.set_shader_parameter(k, float(L[k]))
	return sm

const SKY_SHADER := "shader_type sky;
uniform vec3 sky_top : source_color;
uniform vec3 sky_horizon : source_color;
uniform vec3 ground_horizon : source_color;
uniform vec3 ground_bottom : source_color;
uniform vec3 cloud_color : source_color;
uniform vec3 cloud_shade : source_color;
uniform float sun_disc_deg = 0.8;
uniform float sun_halo_deg = 8.0;
uniform float sun_halo = 0.6;
uniform float sun_disc_energy = 12.0;
uniform float cloud_cover = 0.45;
uniform float cloud_scale = 1.4;
uniform float cloud_height_fade = 0.08;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0; float a = 0.5;
	for (int i = 0; i < 6; i++) { s += a * vnoise(p); p = p * 2.07 + vec2(17.1, 9.2); a *= 0.5; }
	return s;
}
void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col;
	if (h >= 0.0) {
		col = mix(sky_horizon, sky_top, pow(clamp(h, 0.0, 1.0), 0.45));
	} else {
		col = mix(ground_horizon, ground_bottom, pow(clamp(-h, 0.0, 1.0), 0.6));
	}
	float sun = 0.0;
	vec3 sun_col = vec3(0.0);
	float a = 180.0;
	if (LIGHT0_ENABLED) {
		a = degrees(acos(clamp(dot(d, LIGHT0_DIRECTION), -1.0, 1.0)));
		sun_col = LIGHT0_COLOR * LIGHT0_ENERGY;
		float halo = pow(clamp(1.0 - a / sun_halo_deg, 0.0, 1.0), 3.0) * sun_halo + exp(-a / (sun_halo_deg * 2.0)) * sun_halo * 0.12;
		col += sun_col * halo * step(0.0, h + 0.05);
		sun = 1.0 - smoothstep(sun_disc_deg * 0.85, sun_disc_deg, a);
	}
	if (h > 0.0) {
		vec2 uv = d.xz / (h + 0.12) * cloud_scale;
		float n = fbm(uv + vec2(3.1, 8.7));
		float cov = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.35, n);
		float thick = smoothstep(1.0 - cloud_cover, 1.0, fbm(uv * 1.9 + vec2(5.0, 1.0)) * 0.5 + n * 0.5);
		cov *= smoothstep(0.0, cloud_height_fade, h);
		vec3 cc = mix(cloud_color, cloud_shade, thick) + sun_col * 0.25 * exp(-a / 12.0) * (1.0 - thick);
		col = mix(col, cc, cov * 0.92);
		sun *= 1.0 - cov * 0.85;
	}
	col = mix(col, sun_col * sun_disc_energy, sun);
	COLOR = col;
}
"
