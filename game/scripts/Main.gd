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
var weapons: Weapons
var lobby: AimLobby
var settings: Settings
var _in_start := false
var shots_running := false
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
	hud.setup(sinput.convars, paths.cs2_dir)
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
	viewmodel.setup(content, player.cam, sinput.convars)
	weapons = Weapons.new()
	add_child(weapons)
	weapons.setup(self)
	lobby = AimLobby.new()
	add_child(lobby)
	lobby.build(content, self)
	settings = Settings.new()
	add_child(settings)
	settings.setup(self)
	course.entered_zone.connect(_on_zone)
	player.jumped.connect(func() -> void: sounds.play("jump"))
	player.landed.connect(func(_v: float) -> void: sounds.play("land"))
	player.footstep.connect(func() -> void: sounds.play("footstep"))
	timer.finished.connect(_on_finished)
	_report()
	var ua := OS.get_cmdline_user_args()
	var si := ua.find("--shots")
	if si >= 0 and si + 1 < ua.size():
		var shots := Shots.new()
		shots.main = self
		shots_running = true
		shots.out_dir = ua[si + 1]
		add_child(shots)
	if OS.get_cmdline_user_args().has("--autosurf"):
		add_child(load("res://TestDrive.gd").new())

## sheets/lighting.json: sun, sky, haze and post effects.
func _lighting() -> void:
	var L := Sheets.values("lighting")
	var col := func(k: String) -> Color:
		var a: Array = L[k]
		return Color(a[0], a[1], a[2])
	var sun := DirectionalLight3D.new()
	sun.name = "sun"
	sun.rotation_degrees = Vector3(float(L["sun_pitch"]), float(L["sun_yaw"]), 0)
	sun.light_color = col.call("sun_color")
	sun.light_energy = float(L["sun_energy"])
	sun.shadow_enabled = OS.get_environment("RS_NOSHADOW") == ""
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = float(L["shadow_distance"])
	sun.shadow_blur = float(L["shadow_blur"])
	sun.shadow_bias = float(L["shadow_bias"])
	sun.shadow_normal_bias = float(L["shadow_normal_bias"])
	sun.light_angular_distance = float(L["sun_angular"])
	# cascades packed toward the camera: the near ones carry crisp contact shadows, the last the far site
	var sp: Array = L["shadow_splits"]
	sun.directional_shadow_split_1 = float(sp[0])
	sun.directional_shadow_split_2 = float(sp[1])
	sun.directional_shadow_split_3 = float(sp[2])
	RenderingServer.directional_shadow_atlas_set_size(int(L["shadow_atlas"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(int(L["shadow_quality"]) as RenderingServer.ShadowQuality)
	add_child(sun)
	# bounce: sunlit ground lighting the shaded faces from below, opposite the sun; no shadow, no
	# specular, and kept out of the sky so the sky shader's LIGHT0 stays the sun
	var bounce := DirectionalLight3D.new()
	bounce.name = "bounce"
	bounce.rotation_degrees = Vector3(float(L["bounce_pitch"]), float(L["sun_yaw"]) + 180.0, 0)
	bounce.light_color = col.call("bounce_color")
	bounce.light_energy = float(L["bounce_energy"])
	bounce.light_specular = 0.0
	bounce.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(bounce)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = Backdrop.sky_material(L)  # gradient, sun disc and clouds
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = float(L["ambient_energy"])
	e.ambient_light_color = col.call("ambient_color")
	e.ambient_light_sky_contribution = float(L["ambient_sky_mix"])
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = float(L["exposure"])
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = col.call("fog_color")
	e.fog_density = float(L["fog_density"])
	e.fog_sun_scatter = float(L["fog_sun_scatter"])
	e.fog_aerial_perspective = float(L["fog_aerial"])
	e.fog_sky_affect = float(L["fog_sky_affect"])
	e.ssao_enabled = bool(L["ssao"])
	e.ssao_radius = float(L["ssao_radius"])
	e.ssao_intensity = float(L["ssao_intensity"])
	e.glow_enabled = bool(L["glow"])
	e.glow_intensity = float(L["glow_intensity"])
	e.glow_hdr_threshold = float(L["glow_threshold"])
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE if L["glow_blend"] == "additive" else Environment.GLOW_BLEND_MODE_SCREEN
	var gl: Array = L["glow_levels"]  # wide levels: a broad bloom round the sun disc
	for i in gl.size():
		e.set_glow_level(i, float(gl[i]))
	# sun shafts: a thin volumetric haze lit (and shadowed) by the sun, scattering forward
	e.volumetric_fog_enabled = float(L["shaft_density"]) > 0.0
	e.volumetric_fog_density = float(L["shaft_density"])
	e.volumetric_fog_albedo = col.call("fog_color")
	e.volumetric_fog_anisotropy = float(L["shaft_forward"])
	e.volumetric_fog_length = float(L["shaft_length"])
	e.volumetric_fog_sky_affect = 0.0
	env.environment = e
	add_child(env)

## Gauntlet capture hook (Shots.gd): a shots.json row may name a weapon to hold for its picture.
func shot_setup(r: Dictionary) -> void:
	if r.get("lobby", false) and not lobby.active:
		lobby._enter(false)  # a lobby pose is the lobby as players see it (round running, its own HUD), at the row's own pose
	if String(r.get("weapon", "(none)")) != "(none)":
		weapons.give(String(r["weapon"]))

func _report() -> void:
	var lines: PackedStringArray = []
	if content.missing.size() > 0:
		lines.append("Missing extracted content: " + ", ".join(content.missing))
	if not viewmodel.ok:
		lines.append("Knife viewmodel off: " + viewmodel.why)
	lines.append_array(weapons.problems)
	# prep's own verdict (prep.py finish): what did not export and why, so a partial install says so
	var ps := content.dir.path_join("prep_status.json")
	if FileAccess.file_exists(ps):
		var st: Variant = JSON.parse_string(FileAccess.get_file_as_string(ps))
		if st is Dictionary:
			for l: Variant in st.get("player", []):
				lines.append(str(l))
	_err_lines = lines
	hud.errors(lines)
	print("Binds: %s | sens %.2f" % [sinput.source, sinput.sensitivity])  # console only: CS2 shows no such line over the view
	print("READY course loaded; missing content %d; viewmodel %s; weapons ready %d/%d" % [content.missing.size(), "ok" if viewmodel.ok else "off", weapons.ready_ids.size(), weapons.rows.size()])

func _exit_tree() -> void:
	if content:
		content.dispose()

## Click or alt-tab back in: the mouse is captured again so look keeps working.
func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not (settings and settings.is_open):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and player != null and not (settings and settings.is_open):
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
	if lobby.active or shots_running:  # Gauntlet poses teleport around: never start a run
		_in_start = false
	elif _in_start and not _inside_start():
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
	if Input.is_action_just_pressed("surf_inspect") and weapons.can_inspect():
		viewmodel.inspect()
	if Input.is_action_just_pressed("surf_menu"):
		settings.toggle()
	if Input.is_action_just_pressed("surf_lobby"):
		lobby.toggle()
