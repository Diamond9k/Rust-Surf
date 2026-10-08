## systems.ghost: records every tick, plays the personal best back as a translucent capsule.
class_name Ghost
extends Node3D

var recording: Array = []
var best: Array = []
var playing := false
var rec := false
var tick := 0
var course_id: String

func setup(cid: String) -> void:
	course_id = cid
	var mesh := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.3
	cm.height = 1.37
	mesh.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	mesh.position.y = 0.685
	add_child(mesh)
	var p := "user://ghost_%s.json" % cid
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Array:
			best = d
	visible = false

func start_run() -> void:
	recording.clear()
	rec = true
	tick = 0
	playing = best.size() > 0
	visible = playing

func stop_run(save_as_best: bool) -> void:
	rec = false
	playing = false
	visible = false
	if save_as_best and recording.size() > 0:
		best = recording.duplicate()
		var f := FileAccess.open("user://ghost_%s.json" % course_id, FileAccess.WRITE)
		f.store_string(JSON.stringify(best))

func record(player: SurfPlayer) -> void:
	if rec:
		recording.append([player.global_position.x, player.global_position.y, player.global_position.z, player.yaw])
	if playing and tick < best.size():
		var s: Array = best[tick]
		global_position = Vector3(s[0], s[1], s[2])
		rotation_degrees.y = float(s[3])
	tick += 1
