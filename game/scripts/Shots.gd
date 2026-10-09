## Gauntlet capture: with --shots <dir>, poses the player camera at each shots.json row, renders,
## saves <dir>/<id>.png and quits. The same poses every round, so critics compare like with like.
class_name Shots
extends Node

var main: Node3D
var out_dir := ""

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var p: SurfPlayer = main.player
	if p == null:
		get_tree().quit(2)
		return
	p.frozen = true
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ua := OS.get_cmdline_user_args()
	var only: PackedStringArray = []
	if ua.find("--only") >= 0:
		only = ua[ua.find("--only") + 1].split(",")
	if main.course:
		main.course.set_process(false)
		for z in main.course.get_children():
			if z is Area3D:
				(z as Area3D).monitoring = false  # posing the camera must not start or finish runs
	for r in Sheets.load_sheet("shots")["rows"]:
		if only.size() > 0 and not only.has(String(r["id"])):
			continue
		var pos: Array = r["pos"]
		p.teleport(Vector3(pos[0], pos[1], pos[2]), float(r["yaw"]))
		p.pitch = float(r["pitch"])
		p.cam.rotation_degrees.x = p.pitch
		if main.has_method("shot_setup"):
			main.shot_setup(r)
		if main.hud:
			main.hud.message("", 0.0)  # the start-up binds toast is not part of any pose
		for i in int(r.get("frames", 20)):
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_dir.path_join(String(r["id"]) + ".png"))
		print("SHOT ", r["id"])
	get_tree().quit(0)
