## systems.backdrop: the real Launch Site, placed from rust/launch_site_placements.json.
## prep already flips meshes to the Godot right-handed Y-up frame; here only the placements are
## converted: z -> -z, quaternion (x,y,z,w) -> (-x,-y,z,w).
class_name Backdrop
extends Node3D

var content: Content
var meshes := {}
var placed := 0

func build(c: Content, offset: Vector3, yaw_deg: float) -> void:
	content = c
	var data: Variant = content.json("scene_launch_site")
	if data == null:
		return
	transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(yaw_deg), 0)), offset)
	for p in data["placements"]:
		var mesh := _mesh(p["mesh"])
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var q: Array = p["rot"]
		var s: Array = p["scale"]
		var basis := Basis(Quaternion(-q[0], -q[1], q[2], q[3])).scaled(Vector3(s[0], s[1], s[2]))
		var pos: Array = p["pos"]
		mi.transform = Transform3D(basis, Vector3(pos[0], pos[1], -pos[2]))
		add_child(mi)
		placed += 1

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
	meshes[name] = found
	return found

func _all(n: Node, cls: String) -> Array:
	var out := []
	if n.get_class() == cls:
		out.append(n)
	for ch in n.get_children():
		out += _all(ch, cls)
	return out
