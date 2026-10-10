## systems.backdrop: the real Launch Site, placed from rust/launch_site_placements.json, and the
## terrain it sits in (course.json "terrain"). prep already flips meshes to the Godot right-handed
## Y-up frame; here only the placements are converted: z -> -z, quaternion (x,y,z,w) -> (-x,-y,z,w).
class_name Backdrop
extends Node3D

const EMPTY := -1.0e9
const MAX_ROADS := 16  # the terrain shader's array sizes
const MAX_APRONS := 32

var content: Content
var meshes := {}
var mats := {}
var placed := 0
var props := 0
var halls := 0
var aprons := PackedVector4Array()
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
var _tmat: ShaderMaterial
var scattered := {}
var _avoid: Array[AABB] = []

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
	_props()
	_halls()
	_scatter()

## course.json terrain.props: extra copies of the extracted Launch Site meshes set around the course as
## scenery (our arrangement, not Rust's layout), standing on the ground height at their x, z. The
## buildings named in apron_meshes get a concrete apron round them, as the halls do.
func _props() -> void:
	var with_apron: Array = T["props"]["apron_meshes"]
	var mg := float(T["props"]["apron"])
	for p in T["props"]["rows"]:
		var mesh := _mesh(p["mesh"])
		if mesh == null:
			continue
		var at: Array = p["pos"]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.top_level = true
		add_child(mi)
		var sc := float(p["scale"])
		mi.global_transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(float(p["yaw"])), 0)).scaled(Vector3.ONE * sc), Vector3(at[0], height(at[0], at[1]) + float(p["dy"]), at[1]))
		props += 1
		var box := mi.global_transform * mesh.get_aabb()
		_avoid.append(box)
		if String(p["mesh"]) in with_apron:
			aprons.append(Vector4(box.position.x - mg, box.position.z - mg, box.end.x + mg, box.end.z + mg))

## course.json terrain.halls: large industrial halls built here from Rust's own Launch Site textures
## (corrugated sheet_metal walls over a cinder block base, roof_plating_a gable roofs, glass_industrial
## window bands, concrete pilasters and plinth, sheet metal doors, an optional glazed roof lantern). Our
## buildings, scenery only (no collision): prep extracts no Rust building larger than the warehouse.
func _halls() -> void:
	var H: Dictionary = T["halls"]
	var roles: Dictionary = H["materials"]
	for h in H["rows"]:
		var sts := {}
		for k in roles:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[k] = st
		var used := _hall(h, sts)
		var mesh := ArrayMesh.new()
		for k in used:
			var st: SurfaceTool = sts[k]
			st.generate_tangents()
			st.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _row_mat(String(roles[k])))
		var mi := MeshInstance3D.new()
		mi.name = String(h["id"])
		mi.mesh = mesh
		mi.top_level = true
		add_child(mi)
		var at: Array = h["pos"]
		mi.global_transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(float(h["yaw"])), 0)), Vector3(at[0], height(at[0], at[1]) + float(h["dy"]), at[1]))
		var box := mi.global_transform * mesh.get_aabb()
		_avoid.append(box)
		halls += 1
		var mg := float(H["apron"])
		aprons.append(Vector4(box.position.x - mg, box.position.z - mg, box.end.x + mg, box.end.z + mg))
	# the ground round each hall (and apron prop) is the site concrete (terrain shader aprons)
	_ground_material().set_shader_parameter("apron_count", mini(aprons.size(), MAX_APRONS))
	var ap := aprons.duplicate()
	ap.resize(MAX_APRONS)
	_ground_material().set_shader_parameter("aprons", ap)

## One hall in its own frame: length along x, width along z, ground at y 0. Returns the roles it drew.
func _hall(h: Dictionary, sts: Dictionary) -> Dictionary:
	var sz: Array = h["size"]
	var L := float(sz[0]) * 0.5
	var W := float(sz[1]) * 0.5
	var top := float(sz[2])
	var rise := float(h["rise"])
	var bh := float(h["base"])
	var pl := float(T["halls"]["plinth"])
	var used := {}
	# plinth, sunk into the ground so a hall on a slope never floats
	_hbox(sts["plinth"], Vector3(-L - 0.3, -2.0, -W - 0.3), Vector3(L + 0.3, pl, W + 0.3))
	used["plinth"] = true
	var sides := [[Vector3(-L, 0, W), Vector3(L, 0, W), Vector3(0, 0, 1)], [Vector3(L, 0, -W), Vector3(-L, 0, -W), Vector3(0, 0, -1)],
		[Vector3(L, 0, W), Vector3(L, 0, -W), Vector3(1, 0, 0)], [Vector3(-L, 0, -W), Vector3(-L, 0, W), Vector3(-1, 0, 0)]]
	var win: Array = h["windows"]
	var door: Array = h["door"]
	var sp := float(h["pilaster"])
	for i in 4:
		var p: Vector3 = sides[i][0]
		var q: Vector3 = sides[i][1]
		var n: Vector3 = sides[i][2]
		var span := p.distance_to(q)
		_hwall(sts["base"], p, q, n, 0.0, span, pl, bh, 0.0)
		_hwall(sts["wall"], p, q, n, 0.0, span, bh, top, 0.0)
		if rise > 0.0 and i >= 2:  # gable ends
			var a := p + Vector3(0, top, 0)
			var b := q + Vector3(0, top, 0)
			var c := (p + q) * 0.5 + Vector3(0, top + rise, 0)
			_htri(sts["wall"], a, b, c, n, Vector2(0, -top), Vector2(span, -top), Vector2(span * 0.5, -top - rise))
		# bays between pilasters: a window band in each on the long walls, the end walls glazed above the door
		var bays := maxi(1, int(round(span / sp))) if sp > 0.0 else 1
		var bw := span / bays
		if float(win[1]) > float(win[0]):
			for k in bays:
				var u0 := k * bw + 0.7
				var u1 := (k + 1) * bw - 0.7
				if i >= 2 and u1 > span * 0.5 - float(door[0]) * 0.5 - 0.5 and u0 < span * 0.5 + float(door[0]) * 0.5 + 0.5:
					continue
				_hwall(sts["glass"], p, q, n, u0, u1, float(win[0]), float(win[1]), 0.04)
				used["glass"] = true
		if i >= 2 and float(door[0]) > 0.0:
			_hwall(sts["door"], p, q, n, span * 0.5 - float(door[0]) * 0.5, span * 0.5 + float(door[0]) * 0.5, pl, float(door[1]), 0.06)
			_hwall(sts["plinth"], p, q, n, span * 0.5 - float(door[0]) * 0.5 - 0.4, span * 0.5 + float(door[0]) * 0.5 + 0.4, float(door[1]), float(door[1]) + 0.5, 0.12)
			used["door"] = true
		if sp > 0.0:
			for k in bays + 1:
				_hpost(sts["plinth"], p, q, n, k * bw, top)
	used["base"] = true
	used["wall"] = true
	# roof: a gable along x with eaves overhanging oh (flat when rise is 0), drawn on both sides
	var oh := float(T["halls"]["eave"])
	var ey := top - oh * rise / W
	var ridge := top + rise
	for sgn: float in [1.0, -1.0]:
		var a := Vector3(-L - oh, ridge, 0)
		var b := Vector3(L + oh, ridge, 0)
		var c := Vector3(L + oh, ey, (W + oh) * sgn)
		var d := Vector3(-L - oh, ey, (W + oh) * sgn)
		var n := (b - a).cross(d - a).normalized()
		if n.y < 0.0:
			n = -n
		var sl := a.distance_to(d)
		_hquad(sts["roof"], [a, b, c, d], n, [Vector2(a.x, 0), Vector2(b.x, 0), Vector2(c.x, sl), Vector2(d.x, sl)])
		var dn := Vector3(0, -0.05, 0)
		_hquad(sts["roof"], [a + dn, b + dn, c + dn, d + dn], -n, [Vector2(a.x, 0), Vector2(b.x, 0), Vector2(c.x, sl), Vector2(d.x, sl)])
		# fascia along the eave
		_hquad(sts["plinth"], [d, c, c - Vector3(0, 0.4, 0), d - Vector3(0, 0.4, 0)], Vector3(0, 0, sgn), [Vector2(d.x, 0), Vector2(c.x, 0), Vector2(c.x, 0.4), Vector2(d.x, 0.4)])
	used["roof"] = true
	# a glazed lantern along the ridge
	var ln: Array = h["lantern"]
	if float(ln[1]) > 0.0:
		var ll := L * float(ln[0])
		var lw := float(ln[1]) * 0.5
		var y0 := top + rise * (1.0 - lw / W) - 0.2
		var y1 := ridge + float(ln[2])
		_hwall(sts["glass"], Vector3(-ll, 0, lw), Vector3(ll, 0, lw), Vector3(0, 0, 1), 0.0, ll * 2.0, y0, y1, 0.0)
		_hwall(sts["glass"], Vector3(ll, 0, -lw), Vector3(-ll, 0, -lw), Vector3(0, 0, -1), 0.0, ll * 2.0, y0, y1, 0.0)
		_hwall(sts["wall"], Vector3(ll, 0, lw), Vector3(ll, 0, -lw), Vector3(1, 0, 0), 0.0, lw * 2.0, y0, y1, 0.0)
		_hwall(sts["wall"], Vector3(-ll, 0, -lw), Vector3(-ll, 0, lw), Vector3(-1, 0, 0), 0.0, lw * 2.0, y0, y1, 0.0)
		var o := 0.4
		_hquad(sts["roof"], [Vector3(-ll - o, y1, -lw - o), Vector3(ll + o, y1, -lw - o), Vector3(ll + o, y1, lw + o), Vector3(-ll - o, y1, lw + o)], Vector3.UP,
			[Vector2(-ll, -lw), Vector2(ll, -lw), Vector2(ll, lw), Vector2(-ll, lw)])
		used["glass"] = true
	return used

## A wall strip on the face p -> q (outward n): from u0 to u1 metres along it, y0 to y1 high, lifted off by
## off. UV in metres, v down from the top so the textures hang the right way up.
func _hwall(st: SurfaceTool, p: Vector3, q: Vector3, n: Vector3, u0: float, u1: float, y0: float, y1: float, off: float) -> void:
	var d := (q - p).normalized()
	var a := p + d * u0 + n * off
	var b := p + d * u1 + n * off
	_hquad(st, [a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0)], n,
		[Vector2(u0, -y0), Vector2(u1, -y0), Vector2(u1, -y1), Vector2(u0, -y1)])

## A concrete pilaster standing proud of the wall at u metres along it.
func _hpost(st: SurfaceTool, p: Vector3, q: Vector3, n: Vector3, u: float, top: float) -> void:
	var d := (q - p).normalized()
	var w := 0.35
	var dep := 0.35
	_hwall(st, p, q, n, u - w, u + w, 0.0, top + 0.1, dep)
	for s: float in [-1.0, 1.0]:
		var c := p + d * (u + w * s)
		var e := Vector3(0, top + 0.1, 0)
		_hquad(st, [c, c + n * dep, c + n * dep + e, c + e], d * s, [Vector2(0, 0), Vector2(dep, 0), Vector2(dep, -e.y), Vector2(0, -e.y)])

## A box with its five visible faces (no bottom), UV in metres.
func _hbox(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var sides := [[Vector3(lo.x, 0, hi.z), Vector3(hi.x, 0, hi.z), Vector3(0, 0, 1)], [Vector3(hi.x, 0, lo.z), Vector3(lo.x, 0, lo.z), Vector3(0, 0, -1)],
		[Vector3(hi.x, 0, hi.z), Vector3(hi.x, 0, lo.z), Vector3(1, 0, 0)], [Vector3(lo.x, 0, lo.z), Vector3(lo.x, 0, hi.z), Vector3(-1, 0, 0)]]
	for sd in sides:
		var p: Vector3 = sd[0]
		var q: Vector3 = sd[1]
		_hwall(st, p, q, sd[2], 0.0, p.distance_to(q), lo.y, hi.y, 0.0)
	_hquad(st, [Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.UP,
		[Vector2(lo.x, lo.z), Vector2(hi.x, lo.z), Vector2(hi.x, hi.z), Vector2(lo.x, hi.z)])

## Godot front faces are clockwise: every triangle is wound to face along n (as Course._quad).
func _hquad(st: SurfaceTool, pts: Array, n: Vector3, uv: Array) -> void:
	var p0: Vector3 = pts[0]
	var flip := ((pts[1] as Vector3) - p0).cross((pts[2] as Vector3) - p0).dot(n) > 0.0
	for tri in ([[0, 2, 1], [0, 3, 2]] if flip else [[0, 1, 2], [0, 2, 3]]):
		for i in tri:
			st.set_color(_grime((pts[i] as Vector3).y))
			st.set_normal(n)
			st.set_uv(uv[i])
			st.add_vertex(pts[i])

## Vertex shade of a hall: dirt splashed up the lowest metres of the walls (course.json halls grime).
func _grime(y: float) -> Color:
	var g: Array = T["halls"]["grime"]
	var k := lerpf(float(g[0]), 1.0, clampf(y / float(g[1]), 0.0, 1.0))
	return Color(k, k, k)

func _htri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var pts := [a, b, c]
	var uv := [ua, ub, uc]
	var order := [0, 2, 1] if (b - a).cross(c - a).dot(n) > 0.0 else [0, 1, 2]
	for i in order:
		st.set_color(_grime((pts[i] as Vector3).y))
		st.set_normal(n)
		st.set_uv(uv[i])
		st.add_vertex(pts[i])

## A materials.json row as a plain StandardMaterial3D (UV in metres, scaled by the row's uv_scale).
func _row_mat(id: String) -> StandardMaterial3D:
	var key := "row:" + id
	if mats.has(key):
		return mats[key]
	var mr: Dictionary = {}
	for r in Sheets.load_sheet("materials")["rows"]:
		if r["id"] == id:
			mr = r
	var m := StandardMaterial3D.new()
	m.albedo_texture = content.texture(mr["albedo"], "MainTex")
	if mr["normal"] != "(none)":
		var nt := content.texture(mr["normal"], "BumpMap")
		if nt:
			m.normal_enabled = true
			m.normal_texture = nt
	var tn: Array = mr["tint"]
	m.albedo_color = Color(tn[0], tn[1], tn[2])
	m.roughness = float(mr["roughness"])
	m.uv1_scale = Vector3.ONE / float(mr["uv_scale"])
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.vertex_color_use_as_albedo = true  # hall grime; meshes without colours read white
	mats[key] = m
	return m

## course.json terrain.scatter: trees, bushes, grass tufts and rocks built here (we have no Rust
## vegetation meshes) and scattered over the ground as MultiMeshes in chunks, so the land reads as
## Rust's countryside instead of a painted plain. Each row samples its rect, keeps points whose distance
## outside site_rect is within ring (negative inside), whose cluster noise clears 1 - cover, and that are
## off roads, pits, buildings and props.
func _scatter() -> void:
	for mi in nodes:
		_avoid.append((transform * mi.transform) * mi.get_aabb())
	var S: Dictionary = T["scatter"]
	var r: Array = T["site_rect"]
	var rd: Dictionary = T["roads"]
	for row in S["rows"]:
		var chunk := float(row["chunk"])
		var rng := RandomNumberGenerator.new()
		rng.seed = int(row["seed"])
		var cl := FastNoiseLite.new()
		cl.seed = int(row["seed"])
		cl.frequency = 1.0 / float(row["cluster_period"])
		cl.fractal_octaves = 3
		var mesh := _plant_mesh(String(row["shape"]), rng)
		var mat := _plant_material(row)
		var box: Array = row["rect"]
		var ring: Array = row["ring"]
		var size: Array = row["size"]
		var col: Array = row["color"]
		var jit := float(row["color_jitter"])
		var cover := float(row["cover"])
		var sink := float(row["sink"])
		var bins := {}
		var n := 0
		var tries := 0
		var want := int(row["count"])
		while n < want and tries < want * 12:
			tries += 1
			var x := rng.randf_range(float(box[0]), float(box[2]))
			var z := rng.randf_range(float(box[1]), float(box[3]))
			var dx := maxf(float(r[0]) - x, x - float(r[2]))
			var dz := maxf(float(r[1]) - z, z - float(r[3]))
			var d := sqrt(maxf(dx, 0.0) ** 2 + maxf(dz, 0.0) ** 2) if maxf(dx, dz) > 0.0 else maxf(dx, dz)
			if d < float(ring[0]) or d > float(ring[1]):
				continue
			if cl.get_noise_2d(x, z) * 0.5 + 0.5 < 1.0 - cover:
				continue
			if _pit_at(x, z) != 0 or _on_road(x, z, rd) or _blocked(x, z):
				continue
			var sc := rng.randf_range(float(size[0]), float(size[1]))
			var y := height(x, z)
			var slope := absf(height(x + 1.0, z) - height(x - 1.0, z)) + absf(height(x, z + 1.0) - height(x, z - 1.0))
			if slope > float(row["max_slope"]):
				continue
			var b := Basis.from_euler(Vector3(rng.randf_range(-0.05, 0.05), rng.randf() * TAU, rng.randf_range(-0.05, 0.05)))
			b = b.scaled(Vector3(sc * rng.randf_range(0.85, 1.15), sc, sc * rng.randf_range(0.85, 1.15)))
			var k := Vector2i(floori(x / chunk), floori(z / chunk))
			if not bins.has(k):
				bins[k] = []
			var f := rng.randf_range(1.0 - jit, 1.0 + jit)
			bins[k].append([Transform3D(b, Vector3(x, y - sink * sc, z)), Color(col[0] * f * rng.randf_range(0.95, 1.05), col[1] * f, col[2] * f * rng.randf_range(0.95, 1.05))])
			n += 1
		for k in bins:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mesh
			var items: Array = bins[k]
			mm.instance_count = items.size()
			for i in items.size():
				mm.set_instance_transform(i, items[i][0])
				mm.set_instance_color(i, items[i][1])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			mmi.top_level = true
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(row["shadows"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var vr := float(row["view_range"])
			if vr > 0.0:
				mmi.visibility_range_end = vr
				mmi.visibility_range_end_margin = vr * 0.1
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(mmi)
			mmi.global_transform = Transform3D.IDENTITY
		scattered[row["id"]] = n

func _on_road(x: float, z: float, rd: Dictionary) -> bool:
	var p := Vector2(x, z)
	var lim := float(rd["width"]) * 0.5 + float(T["scatter"]["road_margin"])
	for a in rd["segments"]:
		var s := Geometry2D.get_closest_point_to_segment(p, Vector2(a[0], a[1]), Vector2(a[2], a[3]))
		if p.distance_to(s) < lim:
			return true
	return false

func _blocked(x: float, z: float) -> bool:
	var m := float(T["scatter"]["building_margin"])
	for b in _avoid:
		if x > b.position.x - m and x < b.end.x + m and z > b.position.z - m and z < b.end.z + m:
			return true
	return false

## Plant and rock meshes, about 1 m tall (scaled per instance), vertex-coloured so the instance colour
## tints them: a spruce (a bare trunk and nine tiers of drooping branch tips), a broadleaf (trunk and
## three lumpy crowns), a low bush, a grass tuft (a fan of thin blades) and a rock (a lumpy, flattened ball).
func _plant_mesh(shape: String, rng: RandomNumberGenerator) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match shape:
		"conifer":
			_cyl(st, 0.0, 0.45, 0.022, 0.012, Color(0.3, 0.24, 0.2))
			for i in 9:
				var t := i / 8.0
				var y := lerpf(0.12, 0.84, t)
				var rad := lerpf(0.3, 0.07, pow(t, 0.9)) * rng.randf_range(0.85, 1.12)
				var k := lerpf(0.62, 1.0, t)  # the lower, shaded tiers darker
				_tier(st, y, rad, rad * 0.75, 7 + (i % 2), rng, Color(k, k, k), true)
			_cone(st, 0.86, 0.16, 0.05, 5, rng, Color(1.05, 1.05, 1.05), false)
		"conifer_far":  # a few pixels tall: four tiers, no trunk or undersides
			for i in 4:
				var t := i / 3.0
				var k := lerpf(0.72, 1.0, t)
				_tier(st, lerpf(0.1, 0.72, t), lerpf(0.26, 0.09, t), lerpf(0.3, 0.22, t), 5, rng, Color(k, k, k), false)
			_cone(st, 0.78, 0.22, 0.06, 4, rng, Color(1, 1, 1), false)
		"broadleaf":
			_cyl(st, 0.0, 0.55, 0.035, 0.02, Color(0.62, 0.6, 0.55))
			for c in [Vector3(0, 0.62, 0), Vector3(0.14, 0.5, 0.08), Vector3(-0.12, 0.52, -0.1)]:
				_blob(st, c, Vector3(0.26, 0.22, 0.26), 0.25, rng, Color(1, 1, 1), 4, 6)
		"broadleaf_far":
			_cyl(st, 0.0, 0.45, 0.035, 0.02, Color(0.62, 0.6, 0.55))
			_blob(st, Vector3(0, 0.6, 0), Vector3(0.34, 0.28, 0.34), 0.25, rng, Color(1, 1, 1), 3, 6)
		"bush":
			_blob(st, Vector3(0, 0.3, 0), Vector3(0.6, 0.45, 0.6), 0.3, rng, Color(1, 1, 1), 4, 7)
		"grass":
			for i in 14:
				var a := rng.randf() * TAU
				var o := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.25)
				var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.1, 0.35)
				var side := Vector3(-sin(a), 0, cos(a)) * 0.035
				var h := rng.randf_range(0.6, 1.0)
				for v in [[o - side, 0.55], [o + side, 0.55], [o + lean + Vector3(0, h, 0), 1.15]]:
					st.set_color(Color(v[1], v[1], v[1]))
					st.set_normal(Vector3.UP)  # lit like the ground they grow from
					st.add_vertex(v[0])
		"rubble":  # a broken concrete lump: few facets, pushed hard out of round, lying flat
			_blob(st, Vector3(0, 0.18, 0), Vector3(0.55, 0.3, 0.42), 0.5, rng, Color(1, 1, 1), 3, 5)
		"drum":
			_drum(st, rng)
		_:
			_blob(st, Vector3(0, 0.25, 0), Vector3(0.6, 0.4, 0.5), 0.35, rng, Color(1, 1, 1), 4, 7)
	if shape in ["rock", "rubble", "drum"]:
		st.generate_tangents()
	return st.commit()

func _cyl(st: SurfaceTool, y0: float, y1: float, r0: float, r1: float, c: Color) -> void:
	for i in 6:
		var a0 := TAU * i / 6.0
		var a1 := TAU * (i + 1) / 6.0
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		for v in [[d0, r0, y0], [d1, r1, y1], [d1, r0, y0], [d0, r0, y0], [d0, r1, y1], [d1, r1, y1]]:
			st.set_color(c)
			st.set_normal(v[0])
			st.set_uv(Vector2(v[0].x, v[2]))  # a broadleaf's crowns carry UVs, so every vertex must
			st.add_vertex(v[0] * v[1] + Vector3(0, v[2], 0))

## A steel drum about 1 m tall (0.88 m, 0.29 m radius): a smooth 16-sided shell bulged by two rolling
## hoops and rimmed top and bottom, a lid a little below the rim, and a dent pushed into one side.
func _drum(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var seg := 16
	var prof := [[0.0, 0.285], [0.02, 0.29], [0.29, 0.29], [0.3, 0.3], [0.32, 0.29], [0.58, 0.29], [0.59, 0.3], [0.61, 0.29], [0.86, 0.29], [0.88, 0.295]]
	var dent := rng.randf() * TAU
	for j in prof.size() - 1:
		for i in seg:
			var q := []
			for v in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var a: float = TAU * v[0] / seg
				var d := Vector3(cos(a), 0, sin(a))
				var r: float = prof[v[1]][1] * (1.0 - 0.05 * maxf(cos(a - dent), 0.0) ** 4)
				q.append([d * r + Vector3(0, prof[v[1]][0], 0), d, Vector2(float(v[0]) / seg * 1.8, prof[v[1]][0])])
			for t in [[0, 1, 2], [0, 2, 3]]:  # clockwise seen from outside: Godot's front face
				for k in t:
					st.set_color(Color(1, 1, 1))
					st.set_normal(q[k][1])
					st.set_uv(q[k][2])
					st.add_vertex(q[k][0])
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		for v in [Vector3(0, 0.865, 0), Vector3(cos(a0) * 0.28, 0.87, sin(a0) * 0.28), Vector3(cos(a1) * 0.28, 0.87, sin(a1) * 0.28)]:
			st.set_color(Color(0.92, 0.92, 0.92))
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)

## A cone with a ragged rim (each rim point at its own radius and droop); normals lean out from the
## tree's axis like a round crown, so the foliage shades softly instead of in flat facets.
func _cone(st: SurfaceTool, y: float, h: float, rad: float, seg: int, rng: RandomNumberGenerator, c: Color, under_side: bool) -> void:
	var rim: Array[Vector3] = []
	for i in seg:
		var a := TAU * (i + rng.randf_range(-0.2, 0.2)) / seg
		var rr := rad * rng.randf_range(0.75, 1.2)
		rim.append(Vector3(cos(a) * rr, y - rng.randf_range(0.0, 0.06), sin(a) * rr))
	var tip := Vector3(rng.randf_range(-0.01, 0.01), y + h, rng.randf_range(-0.01, 0.01))
	var under := Vector3(0, y + h * 0.15, 0)
	for i in seg:
		var a := rim[i]
		var b := rim[(i + 1) % seg]
		for v in [[tip, Vector3(0, 1, 0), 1.15], [b, (b - Vector3(0, y, 0)).normalized() + Vector3(0, 0.6, 0), 0.8], [a, (a - Vector3(0, y, 0)).normalized() + Vector3(0, 0.6, 0), 0.8]]:
			st.set_color(c * float(v[2]))
			st.set_normal((v[1] as Vector3).normalized())
			st.add_vertex(v[0])
		if not under_side:
			continue
		for v in [[under, Vector3.DOWN, 0.5], [a, Vector3.DOWN, 0.6], [b, Vector3.DOWN, 0.6]]:
			st.set_color(c * float(v[2]))
			st.set_normal(v[1])
			st.add_vertex(v[0])

## One tier of spruce branches: a low peaked skirt whose rim is a star of seg drooping branch tips
## (radius rad) with notches between them, the tips lighter than the dark heart of the tree, so the
## silhouette is ragged and layered instead of a smooth cone.
func _tier(st: SurfaceTool, y: float, rad: float, h: float, seg: int, rng: RandomNumberGenerator, c: Color, under_side: bool) -> void:
	var rim: Array[Vector3] = []
	var lit: Array[float] = []
	var a0 := rng.randf() * TAU
	for i in seg * 2:
		var tip := i % 2 == 0
		var a := a0 + TAU * (i + rng.randf_range(-0.25, 0.25)) / (seg * 2)
		var rr := rad * (rng.randf_range(0.85, 1.15) if tip else rng.randf_range(0.35, 0.5))
		var droop := rad * (rng.randf_range(0.35, 0.55) if tip else 0.12)
		rim.append(Vector3(cos(a) * rr, y - droop, sin(a) * rr))
		lit.append(1.0 if tip else 0.7)
	var top := Vector3(rng.randf_range(-0.008, 0.008), y + h * 0.55, rng.randf_range(-0.008, 0.008))
	var under := Vector3(0, y - rad * 0.2, 0)
	var n := rim.size()
	for i in n:
		var a := rim[i]
		var b := rim[(i + 1) % n]
		for v in [[top, Vector3.UP, 0.55], [b, b.normalized() + Vector3(0, 0.9, 0), lit[(i + 1) % n]], [a, a.normalized() + Vector3(0, 0.9, 0), lit[i]]]:
			st.set_color(c * float(v[2]))
			st.set_normal((v[1] as Vector3).normalized())
			st.add_vertex(v[0])
		if not under_side:
			continue
		for v in [[under, Vector3.DOWN, 0.35], [a, Vector3.DOWN, 0.5], [b, Vector3.DOWN, 0.5]]:
			st.set_color(c * float(v[2]))
			st.set_normal(v[1])
			st.add_vertex(v[0])

## A lumpy ball: a UV sphere pushed in and out by noise, flattened at the bottom, with UVs for the rock
## texture (the plant material ignores them).
func _blob(st: SurfaceTool, c: Vector3, r: Vector3, lump: float, rng: RandomNumberGenerator, col: Color, rings: int, segs: int) -> void:
	var off := rng.randf() * 100.0
	var nz := FastNoiseLite.new()
	nz.seed = rng.randi()
	nz.frequency = 1.6
	var pts := []
	for j in rings + 1:
		var row := []
		var th := PI * j / rings
		for i in segs + 1:
			var ph := TAU * i / segs
			var d := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var k := 1.0 + lump * nz.get_noise_3d(d.x + off, d.y, d.z)
			var p := c + d * r * k
			p.y = maxf(p.y, c.y - r.y * 0.55)
			row.append([p, d, Vector2(float(i) / segs, float(j) / rings)])
		pts.append(row)
	for j in rings:
		for i in segs:
			var q: Array = [pts[j][i], pts[j][i + 1], pts[j + 1][i + 1], pts[j + 1][i]]
			for t in [[0, 1, 2], [0, 2, 3]]:
				for idx in t:
					var v: Array = q[idx]
					var shade := 0.7 + 0.3 * clampf((v[1] as Vector3).y * 0.5 + 0.5, 0.0, 1.0)
					st.set_color(col * shade)
					st.set_normal(v[1])
					st.set_uv(v[2] * 2.0)
					st.add_vertex(v[0])

func _plant_material(row: Dictionary) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true  # the sheet's colours are sRGB, as picked
	m.roughness = float(row["roughness"])
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if String(row["texture"]) != "(none)":
		var mats := {}
		for r in Sheets.load_sheet("materials")["rows"]:
			mats[r["id"]] = r
		var mr: Dictionary = mats[row["texture"]]
		m.albedo_texture = content.texture(mr["albedo"], "MainTex")
		var nt := content.texture(mr["normal"], "BumpMap")
		if nt:
			m.normal_enabled = true
			m.normal_texture = nt
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE / float(mr["uv_scale"]) * 3.0
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		m.cull_mode = BaseMaterial3D.CULL_BACK
	else:
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP  # foliage lets light through: no black shaded side
	return m

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
	if key in T["blend_materials"]:
		return _ground_material()  # Rust blends these into the terrain; here they take the ground shader
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
	# prep's glTF marks every material opaque, so grates showed their holes and decal sheets their clear
	# texels as black; course.json terrain.alpha says which Rust materials are cut out or laid over
	var A: Dictionary = T["alpha"]
	if key in A["cutout"]:
		b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		b.alpha_scissor_threshold = float(A["scissor"])
	elif key in A["blend"]:
		b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# prep exports every material at metallic 0, roughness 0.9: course.json terrain.sheen gives the steel
	# its own [metallic, roughness] so the towers, trims and vents catch the sun as metal
	var sh: Dictionary = T["sheen"]["materials"]
	if sh.has(key):
		b.metallic = float(sh[key][0])
		b.roughness = float(sh[key][1])
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
	terrain.material_override = _ground_material()
	add_child(terrain)
	terrain.global_transform = Transform3D.IDENTITY

func _ground_material() -> ShaderMaterial:
	if _tmat == null:
		_tmat = _terrain_material()
	return _tmat

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
	var rd: Dictionary = T["roads"]
	var road_mat: Dictionary = rows[rd["material"]]
	sm.set_shader_parameter("tex_road", content.texture(road_mat["albedo"], "MainTex"))
	sm.set_shader_parameter("nrm_road", content.texture(road_mat["normal"], "BumpMap"))
	sm.set_shader_parameter("road_scale", float(road_mat["uv_scale"]))
	sm.set_shader_parameter("road_width", float(rd["width"]))
	var segs := PackedVector4Array()
	for a in rd["segments"]:
		segs.append(Vector4(a[0], a[1], a[2], a[3]))
	sm.set_shader_parameter("road_count", mini(segs.size(), MAX_ROADS))
	segs.resize(MAX_ROADS)
	sm.set_shader_parameter("roads", segs)
	var ln: Dictionary = rd["lines"]
	var lt := content.texture(ln["texture"], "MainTex")
	sm.set_shader_parameter("has_lines", lt != null)
	if lt:
		sm.set_shader_parameter("tex_lines", lt)
	for k in ["centre_v", "edge_v", "dash"]:
		var a: Array = ln[k]
		sm.set_shader_parameter(k, Vector2(a[0], a[1]))
	for k in ["line_width", "line_tile", "line_opacity", "edge_inset"]:
		sm.set_shader_parameter(k, float(ln[k]))
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
uniform sampler2D tex_road : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_road : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float road_scale = 6.0;
uniform float road_width = 8.0;
uniform int road_count = 0;
uniform vec4 roads[16];
uniform sampler2D tex_lines : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_lines = false;
uniform vec2 centre_v = vec2(0.387, 0.413);
uniform vec2 edge_v = vec2(0.387, 0.413);
uniform float line_width = 0.25;
uniform float line_tile = 8.0;
uniform vec2 dash = vec2(9.0, 0.5);
uniform float line_opacity = 0.8;
uniform float edge_inset = 0.5;
uniform int apron_count = 0;
uniform vec4 aprons[32];
uniform float scrub_cell = 4.0;
uniform float scrub_density = 0.3;
uniform vec3 scrub_color = vec3(0.3, 0.32, 0.2);
uniform float stone_cell = 1.3;
uniform float stone_density = 0.25;
uniform vec3 stone_color = vec3(1.15, 1.1, 1.0);
uniform vec3 grass_color = vec3(0.8, 0.95, 0.55);
uniform float grass_cover = 0.45;
uniform float grass_period = 55.0;
uniform vec3 rock_color = vec3(0.62, 0.6, 0.57);
uniform float rock_slope = 0.25;
uniform float hill_shade = 0.3;
uniform vec3 dry_color = vec3(1.0);
uniform float dry_cover = 0.0;
uniform float dry_period = 35.0;
uniform float mottle = 0.0;
uniform float mottle_cell = 1.6;
uniform float relief = 0.0;
uniform float relief_period = 30.0;
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
// scattered blobs (dry scrub, loose stones): at most one per grid cell, with probability dens, kept
// inside its own cell so one lookup is enough; fades to the average cover once a cell is a few pixels
float scatter(vec2 p, float cell, float dens, float seed) {
	float ca = cos(seed * 0.37 + 0.5); float sa = sin(seed * 0.37 + 0.5);
	vec2 q = mat2(vec2(ca, sa), vec2(-sa, ca)) * p / cell;  // each layer's grid turned its own way: no rows
	vec2 g = floor(q);
	float best = 0.0;
	if (hash(g + seed) < dens) {
		vec2 o = vec2(0.25) + 0.5 * vec2(hash(g * 1.7 + seed + 3.1), hash(g * 2.3 + seed + 7.7));
		float r = mix(0.14, 0.28, hash(g + seed + 11.0));
		float d = length(q - g - o) / r + (vnoise(q * 9.0 + g) - 0.5) * 0.5;
		best = 1.0 - smoothstep(0.75, 1.0, d);
	}
	float px = length(fwidth(q));
	return mix(best, dens * 0.12, smoothstep(0.05, 0.3, px));
}
float seg_dist(vec2 p, vec4 s) {
	vec2 a = s.xy; vec2 b = s.zw;
	vec2 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
	return length(p - a - ab * t);
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
	// concrete aprons round the halls, with ragged edges
	float apron = 0.0;
	float ragged = (fbm(p / 5.0 + vec2(3.0, 17.0)) - 0.5) * 6.0;
	for (int i = 0; i < apron_count; i++) {
		vec2 da = max(max(aprons[i].xy - p, p - aprons[i].zw), vec2(0.0));
		apron = max(apron, 1.0 - smoothstep(0.0, 4.0, length(da) + ragged));
	}
	site = max(site, apron * (1.0 - low));
	vec3 c = mix(mix(c0, c1, dirt), c2 * site_shade, site);
	vec3 nm = mix(mix(n0, n1, dirt), n2, site);
	float tint = fbm(p / (macro_period * 2.3) + vec2(7.0, 3.0));
	c *= mix(1.0 - macro_strength, 1.0 + macro_strength * 0.6, tint);
	vec3 tn = mix(tint_a, tint_b, smoothstep(0.3, 0.7, fbm(p / tint_period + vec2(19.0, 41.0))));
	c *= mix(tn, vec3(1.0), site);  // open ground only: olive and brown patches; the site concrete stays grey
	float opn = (1.0 - site) * (1.0 - low);
	// grass: patches of dry green over the open ground, with a fine blade grain close to the camera
	float gm = fbm(p / grass_period + vec2(13.0, 29.0)) * 0.7 + fbm(p / (grass_period * 0.23) + vec2(4.0, 61.0)) * 0.3;
	float grass = smoothstep(1.0 - grass_cover - 0.12, 1.0 - grass_cover + 0.12, gm) * opn * (1.0 - smoothstep(0.15, 0.35, slope));
	float blade = mix(vnoise(p * vec2(9.0, 2.3)) * 0.6 + vnoise(p * 23.0) * 0.4, 0.5, far);
	c = mix(c, c * grass_color * mix(0.78, 1.18, blade), grass);
	// sun-dried straw-coloured patches, and a clump-scale mottle of light and dark tufts that fades to
	// its average once a cell is under a pixel (no shimmer far off)
	float dry = smoothstep(1.0 - dry_cover - 0.15, 1.0 - dry_cover + 0.15, fbm(p / dry_period + vec2(53.0, 17.0))) * opn;
	c = mix(c, c * dry_color, dry);
	vec2 mp = p / mottle_cell;
	float mot = vnoise(mp) * 0.6 + vnoise(mp * 2.7 + vec2(5.0, 9.0)) * 0.4;
	mot = mix(mot, 0.5, smoothstep(0.4, 1.5, length(fwidth(mp))));
	c *= 1.0 + (mot - 0.5) * 2.0 * mottle * opn;
	// outside the site: bare rock on steep hill flanks, and broad light and shade so the coarse far
	// hills read as folded land instead of flat cut-outs
	float hill = 1.0 - inside;
	float rock = smoothstep(rock_slope, rock_slope + 0.2, slope) * hill;
	c = mix(c, vec3(dot(c, vec3(0.333))) * rock_color / 0.33 * 0.5 + c * 0.5, rock);
	c *= mix(1.0, mix(1.0 - hill_shade, 1.0 + hill_shade * 0.5, fbm(p / 160.0 + vec2(71.0, 5.0))), hill);
	float scrub = scatter(p, scrub_cell, scrub_density * smoothstep(0.25, 0.6, fbm(p / 70.0 + vec2(5.0, 2.0))), 1.0) * opn * (1.0 - slope * 2.0);
	c = mix(c, c * scrub_color, clamp(scrub, 0.0, 1.0));
	float stone = scatter(p, stone_cell, stone_density, 23.0) * opn;
	c = mix(c, c * stone_color, stone);
	float rd = 1.0e9;
	float ra = 0.0;  // metres along the nearest road
	float rl = 0.0;  // metres across it (signed)
	float rfade = 0.0;  // 0 at a road's ends: no markings through junctions
	for (int i = 0; i < road_count; i++) {
		vec2 ab = roads[i].zw - roads[i].xy;
		float len = max(length(ab), 1e-3);
		vec2 dir = ab / len;
		vec2 ap = p - roads[i].xy;
		float t = clamp(dot(ap, dir), 0.0, len);
		float d = length(ap - dir * t);
		if (d < rd) {
			rd = d;
			ra = t;
			rl = dot(ap, vec2(-dir.y, dir.x));
			rfade = smoothstep(road_width * 0.6, road_width * 1.4, t) * smoothstep(road_width * 0.6, road_width * 1.4, len - t);
		}
	}
	rd += (fbm(p / 3.0 + vec2(9.0, 4.0)) - 0.5) * 1.6;
	float road = (1.0 - smoothstep(road_width * 0.5 - 0.6, road_width * 0.5 + 0.4, rd)) * (1.0 - low);
	float shoulder = (1.0 - smoothstep(road_width * 0.5, road_width * 0.5 + 3.0, rd)) * (1.0 - road) * (1.0 - low);
	vec2 ruv = p / road_scale;
	vec3 rc = texture(tex_road, ruv).rgb * mix(0.85, 1.1, fbm(p / 17.0 + vec2(2.0, 8.0)));
	c = mix(c, c * 0.82, shoulder);
	c = mix(c, rc, road);
	if (has_lines) {
		// worn painted lines cut from Rust's road_decals atlas: a dashed centre line and solid edge lines,
		// faded to their average once thinner than a pixel so they never shimmer
		float px = max(fwidth(rl), 1e-4);
		float ce = abs(rl) / line_width;
		float ee = abs(abs(rl) - (road_width * 0.5 - edge_inset)) / line_width;
		vec4 lc = texture(tex_lines, vec2(ra / line_tile, mix(centre_v.x, centre_v.y, clamp(rl / line_width + 0.5, 0.0, 1.0))));
		vec4 le = texture(tex_lines, vec2(ra / line_tile + 0.37, mix(edge_v.x, edge_v.y, clamp((abs(rl) - road_width * 0.5 + edge_inset) / line_width + 0.5, 0.0, 1.0))));
		float on = step(fract(ra / dash.x), dash.y);
		float thin = clamp(line_width / px, 0.0, 1.0);
		float mc = (1.0 - smoothstep(0.5 - px / line_width, 0.5 + px / line_width, ce)) * on;
		float me = 1.0 - smoothstep(0.5 - px / line_width, 0.5 + px / line_width, ee);
		float wear = smoothstep(0.25, 0.55, fbm(p / 4.0 + vec2(61.0, 3.0)));
		float k = line_opacity * rfade * road * mix(0.35, 1.0, wear) * mix(0.5, 1.0, thin);
		c = mix(c, lc.rgb, clamp(mc * lc.a * k, 0.0, 1.0));
		c = mix(c, le.rgb, clamp(me * le.a * k, 0.0, 1.0));
	}
	nm = mix(nm, texture(nrm_road, ruv).rgb, road);
	// relief: gullies, humps and sheep tracks finer than the mesh, as a normal tilt from a noise height
	// field and a little shade in its hollows, so the coarse far hills light as folded land, not facets
	vec2 rp = p / relief_period;
	float h0 = fbm(rp);
	vec2 rg = vec2(fbm(rp + vec2(0.3, 0.0)) - h0, fbm(rp + vec2(0.0, 0.3)) - h0) / 0.3;
	float rk = relief * (1.0 - road) * (1.0 - site) * mix(0.35, 1.0, hill);
	nm.xy -= rg * rk;
	c *= 1.0 - 0.25 * rk * (1.0 - smoothstep(0.3, 0.6, h0));
	ALBEDO = c;
	NORMAL_MAP = nm;
	ROUGHNESS = mix(roughness_val, 0.75, road);
}
"

## The sky for Main._lighting: lighting.json gradient, a sun disc with a halo where the sun light comes
## from, a warm horizon band under the sun, and a static cloud layer (nothing moves, so the sky light probe renders once).
## The light probe (reflections and ambient) sees the sky greyed by lighting.json reflect_grey.
static func sky_material(L: Dictionary) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SKY_SHADER
	sm.shader = sh
	for k in ["sky_top", "sky_horizon", "ground_horizon", "ground_bottom", "cloud_color", "cloud_shade", "sun_warm"]:
		var a: Array = L[k]
		sm.set_shader_parameter(k, Color(a[0], a[1], a[2]))
	for k in ["sun_disc_deg", "sun_halo_deg", "sun_halo", "sun_disc_energy", "cloud_cover", "cloud_scale", "cloud_height_fade", "sun_warm_width", "reflect_grey"]:
		sm.set_shader_parameter(k, float(L[k]))
	return sm

## Sun shafts for Main._lighting (lighting.json shaft_*): a full-screen pass that marches from each pixel
## toward the sun on screen and adds sun-coloured light by how much open sky it crosses, so towers,
## ramps and hills throw dark streaks through the bright air round the sun. The light grows with the
## metres of air in front of each surface, so near things (the viewmodel, the ramp under the player)
## take almost none. Our look (screen-space god rays), unverified against Rust's own post stack.
static func sun_shafts(L: Dictionary, toward_sun: Vector3) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	var mi := MeshInstance3D.new()
	mi.name = "sun_shafts"
	mi.mesh = q
	mi.extra_cull_margin = 16384.0  # the vertex shader pins it to the screen: never frustum culled
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHAFT_SHADER
	sm.shader = sh
	sm.set_shader_parameter("toward_sun", toward_sun.normalized())
	var c: Array = L["shaft_color"]
	sm.set_shader_parameter("shaft_color", Vector3(c[0], c[1], c[2]))
	sm.set_shader_parameter("samples", int(L["shaft_samples"]))
	for k in ["shaft_strength", "shaft_reach", "shaft_decay", "shaft_spread_deg", "shaft_air", "shaft_sky"]:
		sm.set_shader_parameter(k, float(L[k]))
	mi.material_override = sm
	return mi

const SHAFT_SHADER := "shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 toward_sun = vec3(0.0, 1.0, 0.0);
uniform vec3 shaft_color = vec3(1.0, 0.9, 0.75);
uniform int samples = 40;
uniform float shaft_strength = 0.3;
uniform float shaft_reach = 0.7;
uniform float shaft_decay = 0.96;
uniform float shaft_spread_deg = 45.0;
uniform float shaft_air = 80.0;
uniform float shaft_sky = 0.4;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}
float open_sky(vec2 uv) {
	return step(texture(depth_tex, clamp(uv, vec2(0.001), vec2(0.999))).r, 1.0e-6);  // reverse z: the sky is depth 0
}
void fragment() {
	vec3 sv = (VIEW_MATRIX * vec4(toward_sun, 0.0)).xyz;
	vec4 sp = PROJECTION_MATRIX * vec4(sv, 0.0);
	float ahead = smoothstep(0.0, 0.25, -sv.z);  // the sun in front of the camera
	vec2 suv = sp.xy / max(sp.w, 1.0e-4) * 0.5 + 0.5;
	vec2 uv = SCREEN_UV;
	float d = texture(depth_tex, uv).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, max(d, 1.0e-7), 1.0);
	vec3 ray = normalize(vp.xyz / vp.w);
	float ang = degrees(acos(clamp(dot(ray, sv), -1.0, 1.0)));
	float fall = pow(clamp(1.0 - ang / shaft_spread_deg, 0.0, 1.0), 2.0) * ahead;
	if (fall <= 0.0) {
		discard;
	}
	float sky = step(d, 1.0e-6);
	float air = sky > 0.5 ? shaft_sky : 1.0 - exp(-length(vp.xyz / vp.w) / shaft_air);
	// jittered start per pixel: the march's steps would band into rings otherwise
	float jit = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec2 stp = (suv - uv) * shaft_reach / float(samples);
	vec2 p = uv + stp * jit;
	float acc = 0.0;
	float w = 1.0;
	float wsum = 0.0;
	for (int i = 0; i < samples; i++) {
		acc += open_sky(p) * w;
		wsum += w;
		w *= shaft_decay;
		p += stp;
	}
	ALBEDO = shaft_color * shaft_strength * (acc / max(wsum, 1.0e-4)) * fall * air;
}
"

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
uniform vec3 sun_warm : source_color;
uniform float sun_warm_width = 4.0;
uniform float reflect_grey = 0.0;

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
		// forward scattering: a warm band along the horizon under the sun, widest near the ground
		vec2 dh = normalize(d.xz + vec2(1e-5));
		vec2 sh = normalize(LIGHT0_DIRECTION.xz + vec2(1e-5));
		float az = pow(max(dot(dh, sh), 0.0), sun_warm_width);
		col += sun_warm * az * pow(1.0 - clamp(abs(h), 0.0, 1.0), 5.0);
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
	if (AT_CUBEMAP_PASS) {
		// what bare metal mirrors and the ambient light: the open sky greyed toward its own brightness, as a
		// map's cubemaps (buildings, ground, haze) would, so steel reads grey instead of sky blue
		col = mix(col, vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), reflect_grey);
	}
	COLOR = col;
}
"
