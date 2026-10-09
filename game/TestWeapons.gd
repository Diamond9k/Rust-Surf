## --wtest: enters the aim lobby, aims at each target, casts the weapons ray and checks the lobby counts the hits.
extends Node

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	var main: Node = get_parent()
	var p: SurfPlayer = main.player
	main.lobby.toggle()
	for i in 10:
		await get_tree().physics_frame
	var targets: Array = get_tree().get_nodes_in_group("aim_target")
	print("WTEST targets=", targets.size(), " held=", main.weapons.held(), " ready=", main.weapons.ready_ids.size(), "/", main.weapons.rows.size())
	var hits := 0
	for t in targets:
		var tn := t as Node3D
		var dir: Vector3 = tn.global_position - p.cam.global_position
		p.yaw = rad_to_deg(atan2(-dir.x, -dir.z))
		p.rotation_degrees.y = p.yaw
		p.pitch = rad_to_deg(asin(dir.normalized().y))
		p.cam.rotation_degrees.x = p.pitch
		main.weapons._punch = 0.0
		await get_tree().physics_frame
		await get_tree().process_frame
		var r: Dictionary = main.weapons._shoot_ray(p.cam, 100.0, 0.0)
		var c: Object = r.get("collider")
		print("WTEST ray -> ", c.name if c else "nothing", " hit()=", c != null and c.has_method("hit"))
		if c and c.has_method("hit"):
			main.lobby.on_shot_fired()
			c.hit(30.0, c.get("is_head") == true, r["position"])
			hits += 1
	print("WTEST done hits=", hits, " lobby: ", main.lobby._stats_line())
	get_tree().quit(0)
