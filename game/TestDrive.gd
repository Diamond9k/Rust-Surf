## Surf bot (headless test via Test.tscn, or in the game with --autosurf for a demo recording). On the ground: W. In the air over a ramp: look along the ramp and hold only the
## strafe key into the face it is on (ridge: toward the apex, valley: toward the wall), like a surfer.
## Logs position/speed so a run can be judged without a screen.
extends Node

var main: Node3D
var ticks := 0
var max_speed := 0.0
var max_x := 0.0
var zones: PackedStringArray = []
var seconds := 30.0
var on_ramp := ""
var _prev_speed := 0.0

func _ready() -> void:
	if get_parent().has_method("_on_zone"):
		# attached by Main for --autosurf (demo / recording)
		main = get_parent()
	else:
		main = load("res://Main.tscn").instantiate()
		add_child(main)
	await get_tree().process_frame
	if main.course:
		main.course.entered_zone.connect(func(kind: String, id: String) -> void:
			zones.append("%s@%.1fs" % [id, ticks / 64.0])
			print("ZONE %s %s at %.2fs" % [kind, id, ticks / 64.0]))
	print("TEST start; player=", main.player != null)

## The ramp whose length spans the player, nearest above-or-below.
func _ramp_under(p: SurfPlayer) -> Dictionary:
	var best := {}
	var best_d := 1e9
	for id in main.course.rows:
		var r: Dictionary = main.course.rows[id]
		if r["kind"] != "ramp":
			continue
		var n: Node3D = main.course.get_node(id)
		var lp := n.to_local(p.global_position)
		if absf(lp.x) <= float(r["length"]) * 0.5 and absf(lp.z) <= float(r["half_width"]) * 1.5:
			var d := absf(lp.y)
			if d < best_d:
				best_d = d
				best = {"row": r, "local": lp}
	return best

func _physics_process(_dt: float) -> void:
	if main.player == null:
		return
	ticks += 1
	var p: SurfPlayer = main.player
	Input.action_release("surf_left")
	Input.action_release("surf_right")
	Input.action_release("surf_forward")
	var ramp := _ramp_under(p) if not p.grounded else {}
	if p.grounded:
		Input.action_press("surf_forward")
		on_ramp = ""
		if ticks == 64 * 1:
			main.viewmodel.inspect()
	elif ramp.size() > 0:
		var r: Dictionary = ramp["row"]
		var lz: float = ramp["local"].z
		on_ramp = r["id"]
		# turn smoothly toward the ramp line (a person moves the mouse, they don't snap)
		p.yaw = lerp_angle(deg_to_rad(p.yaw), deg_to_rad(float(r["yaw"]) - 90.0), 0.08) * 180.0 / PI
		p.rotation_degrees.y = p.yaw
		p.pitch = lerpf(p.pitch, -12.0, 0.05)
		p.cam.rotation_degrees.x = p.pitch
		var push_pos_z: bool = (lz < 0.0) if r["shape"] == "ridge" else (lz > 0.0)
		Input.action_press("surf_right" if push_pos_z else "surf_left")
	if p.speed_units() < _prev_speed * 0.6 and _prev_speed > 300.0:
		print("STOP t=%.3f pos=%s speed %d -> %d hits=%s" % [ticks / 64.0, p.global_position, int(_prev_speed), int(p.speed_units()), p.last_hits])
	_prev_speed = p.speed_units()
	max_speed = maxf(max_speed, p.speed_units())
	max_x = maxf(max_x, p.global_position.x)
	if ticks % 32 == 0:
		print("t=%.1f pos=(%.1f, %.1f, %.1f) speed=%d vy=%.1f gr=%s ramp=%s timer=%.2f" % [ticks / 64.0, p.global_position.x, p.global_position.y, p.global_position.z, int(p.speed_units()), p.velocity.y, p.grounded, on_ramp, main.timer.t])
	if ticks >= int(64 * seconds) or (zones.size() > 0 and zones[-1].begins_with("end_zone")):
		var all_zones := 0
		for z in main.course.get_children():
			if z is Area3D and not String(z.name).contains("start") and not String(z.name).contains("kill"):
				all_zones += 1
		print("TEST end; max_speed=%d u/s max_x=%.1f zones=%s (%d of %d checkpoint and finish zones) pb=%.3f" % [int(max_speed), max_x, zones, zones.size(), all_zones, main.timer.pb])
		get_tree().quit()
