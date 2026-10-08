## Wires every system together in the order systems.json lists them.
extends Node3D

var paths: Paths
var content: Content
var sinput: SurfInput
var course: Course
var player: SurfPlayer
var timer: RunTimer
var hud: Hud
var sounds: Sounds
var ghost: Ghost
var viewmodel: Viewmodel
var backdrop: Backdrop
var _in_start := false
var _err_lines: PackedStringArray = []
var _debug := OS.get_cmdline_user_args().has("--debug")

func _ready() -> void:
	paths = Paths.new()
	hud = Hud.new()
	add_child(hud)
	if paths.error != "":
		hud.setup({})
		hud.errors([paths.error])
		return
	content = Content.new(paths.data_dir)
	sinput = SurfInput.new(paths)
	hud.setup(sinput.convars)
	_lighting()
	course = Course.new()
	add_child(course)
	course.build(content)
	backdrop = Backdrop.new()
	add_child(backdrop)
	var wo: Dictionary = course.sheet["world_offset_rust"]
	backdrop.build(content, Vector3(wo["pos"][0], wo["pos"][1], wo["pos"][2]), float(wo["yaw"]))
	player = SurfPlayer.new()
	player.input = sinput
	player.position = course.spawn_pos  # spawn where we start, not at the origin inside the kill zone
	add_child(player)
	player.teleport(course.spawn_pos, course.spawn_yaw)
	timer = RunTimer.new()
	add_child(timer)
	timer.setup(course.sheet["course_id"])
	ghost = Ghost.new()
	add_child(ghost)
	ghost.setup(course.sheet["course_id"])
	sounds = Sounds.new()
	add_child(sounds)
	sounds.setup(content)
	viewmodel = Viewmodel.new()
	viewmodel.setup(content, player.cam)
	course.entered_zone.connect(_on_zone)
	player.jumped.connect(func() -> void: sounds.play("jump"))
	player.landed.connect(func(_v: float) -> void: sounds.play("land"))
	player.footstep.connect(func() -> void: sounds.play("footstep"))
	timer.finished.connect(_on_finished)
	_report()
	if OS.get_cmdline_user_args().has("--autosurf"):
		add_child(load("res://TestDrive.gd").new())

func _lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)

func _report() -> void:
	var lines: PackedStringArray = []
	if content.missing.size() > 0:
		lines.append("Missing extracted content: " + ", ".join(content.missing))
	if not viewmodel.ok:
		lines.append("Knife viewmodel off: " + viewmodel.why)
	_err_lines = lines
	hud.errors(lines)
	hud.message("Binds: %s | sens %.2f" % [sinput.source, sinput.sensitivity], 4.0)

func _exit_tree() -> void:
	if content:
		content.dispose()

## Click or alt-tab back in: the mouse is captured again so look keeps working.
func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and player != null:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_zone(kind: String, id: String) -> void:
	match kind:
		"zone_start":
			_in_start = true
			ghost.stop_run(false)
			sounds.music(false)
		"checkpoint":
			hud.message("checkpoint " + id, 1.5)
		"zone_kill":
			hud.message("fell: back to checkpoint", 1.5)
	timer.on_zone(kind, id)

func _on_finished(t: float, is_pb: bool) -> void:
	ghost.stop_run(is_pb)
	sounds.music(true)
	hud.message(("NEW PB  " if is_pb else "finished  ") + RunTimer.fmt(t), 5.0)

func _physics_process(_dt: float) -> void:
	if player == null:
		return
	if _in_start and not _inside_start():
		_in_start = false
		timer.start()
		ghost.start_run()
	ghost.record(player)
	sounds.set_speed(Vector2(player.velocity.x, player.velocity.z).length())

## The start zone box from the sheet, checked against the player position (no physics lag).
func _inside_start() -> bool:
	var sz: Node3D = course.get_node("start_zone")
	var r: Dictionary = course.rows["start_zone"]
	var local := sz.to_local(player.global_position + Vector3(0, 0.5, 0))
	return absf(local.x) <= float(r["length"]) * 0.5 and absf(local.z) <= float(r["half_width"]) and absf(local.y) <= float(r["height"]) * 0.5

func _process(_dt: float) -> void:
	if player == null:
		return
	hud.update(player.speed_units(), timer.t, timer.pb, timer.running)
	if _debug:
		hud.errors(_err_lines + PackedStringArray([viewmodel.debug(), "backdrop placed=%d  yaw=%.1f pitch=%.1f mouse=%s" % [backdrop.placed, player.yaw, player.pitch, Input.mouse_mode]]))
	if Input.is_action_just_pressed("surf_restart"):
		course.restart(player)
		timer.reset()
		ghost.stop_run(false)
	if Input.is_action_just_pressed("surf_checkpoint"):
		course.to_checkpoint(player)
	if Input.is_action_just_pressed("surf_inspect"):
		viewmodel.inspect()
	if Input.is_action_just_pressed("surf_menu"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
