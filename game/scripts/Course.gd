## systems.course_builder + checkpoints: one node per course.json row.
class_name Course
extends Node3D

signal entered_zone(kind: String, id: String)

var sheet: Dictionary
var materials := {}
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
		var n := content.texture(m["normal"], "BumpMap")
		if n:
			mat.normal_enabled = true
			mat.normal_texture = n
	else:
		mat.albedo_color = Color(0.2, 0.9, 0.4, 0.15)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

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
	var uvs: float = uv_scales[r["material"]]
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
		_quad(st, p0, p1, p2, p3, n, uvs, L * 2.0, slope)
	if ridge:
		var pa := Vector3(-L, H, 0); var pl := Vector3(-L, -H, -W); var pr := Vector3(-L, -H, W)
		_tri(st, pa, pl, pr, Vector3(-1, 0, 0))
		var dx := Vector3(2 * L, 0, 0)
		_tri(st, pa + dx, pr + dx, pl + dx, Vector3(1, 0, 0))
		_quad(st, Vector3(-L, -H, -W), Vector3(-L, -H, W), Vector3(L, -H, W), Vector3(L, -H, -W), Vector3.DOWN, uvs, L * 2.0, W * 2.0)
	st.generate_tangents()  # normal maps need tangents; without them shaded faces go black
	var mesh := st.commit()
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = materials[r["material"]]
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(mesh.get_faces())
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	return body

func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, uvs: float, ulen: float, vlen: float) -> void:
	var pts := [p0, p1, p2, p3]
	var uv := [Vector2(0, 0), Vector2(ulen / uvs, 0), Vector2(ulen / uvs, vlen / uvs), Vector2(0, vlen / uvs)]
	# Godot treats clockwise triangles as front faces; with culling off a back face shades with its
	# normal flipped (dark ramp faces), so every triangle is wound to face along n.
	var flip := (p1 - p0).cross(p2 - p0).dot(n) > 0.0
	for tri in ([[0, 2, 1], [0, 3, 2]] if flip else [[0, 1, 2], [0, 2, 3]]):
		for i in tri:
			st.set_normal(n)
			st.set_uv(uv[i])
			st.add_vertex(pts[i])

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	for p in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(p.y, p.z) * 0.25)
		st.add_vertex(p)

func _box_body(r: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	var size := Vector3(float(r["length"]), float(r["height"]), float(r["half_width"]) * 2.0)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat: StandardMaterial3D = materials[r["material"]].duplicate()
	mat.uv1_scale = Vector3.ONE * (size.x / uv_scales[r["material"]])
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
