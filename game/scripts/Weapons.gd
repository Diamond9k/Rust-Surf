## systems.weapons: the loadout (primary, pistol, knife) held on the CS2 arms, hitscan fire with the
## stats of the player's own items_game.txt (prep -> cs2/weapon_stats.json), ammo, reload, recoil
## punch and the B buy menu. A weapon whose files prep has not exported stays greyed out in the menu.
class_name Weapons
extends Node

const SLOT_OF := {"rifle": "primary", "sniper": "primary", "smg": "primary", "heavy": "primary", "pistol": "secondary"}
const MENU_COLUMNS := ["pistol", "smg", "rifle", "heavy", "sniper"]

var main: Node
var rows := {}           # id -> weapons.json row, every weapon
var ready_ids := {}      # id -> true when its model and idle clip are in the data folder
var stats := {}          # weapon_x -> items_game attributes
var defaults := {}       # slot class -> weapon_defaults.json row
var slots := {"primary": "", "secondary": "", "knife": "knife"}
var current := "knife"
var last := "secondary"
var ammo := {}           # id -> [clip, reserve]
var u := 0.01905
var _next_fire := 0.0
var _reload_until := 0.0
var _inaccuracy := 0.0   # extra spread from firing, in milliradians, recovering over time
var _punch := 0.0        # view kick in degrees, recovering over time
var _shot: AudioStreamPlayer
var _sounds := {}
var _decals: Array = []
var _buy: CanvasLayer
var _rng := RandomNumberGenerator.new()

func setup(m: Node) -> void:
	main = m
	u = Sheets.movement()["unit_to_m"]
	for r in Sheets.load_sheet("weapon_defaults")["rows"]:
		defaults[r["id"]] = r
	var sp: String = main.content.dir.path_join("cs2/weapon_stats.json")
	if FileAccess.file_exists(sp):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(sp))
		if d is Dictionary:
			stats = d
	for r in Sheets.load_sheet("weapons")["rows"]:
		rows[r["id"]] = r
		if r.get("game", "") == "cs2" and FileAccess.file_exists(_glb(r["model"])) and FileAccess.file_exists(_glb(r["clips"]["idle"])):
			ready_ids[r["id"]] = true
	_shot = AudioStreamPlayer.new()
	_shot.volume_db = -6.0
	add_child(_shot)
	slots["primary"] = _first_ready(["cs2_ak47", "cs2_m4a1_silencer", "cs2_m4a4"], "rifle")
	slots["secondary"] = _first_ready(["cs2_usp_silencer", "cs2_glock", "cs2_deagle"], "pistol")
	for id in rows:
		ammo[id] = [int(stat(id, "primary clip size", "clip")), int(stat(id, "primary reserve ammo max", "reserve"))]
	_build_buy()
	_hud()

func _first_ready(prefer: Array, cls: String) -> String:
	for id in prefer:
		if ready_ids.has(id):
			return id
	for id in rows:
		if ready_ids.has(id) and rows[id]["slot"] == cls:
			return id
	return ""

func _glb(vpk_path: String) -> String:
	return main.content.dir.path_join("cs2/" + vpk_path.get_basename() + ".glb")

func _cls(id: String) -> String:
	return "knife" if id == "knife" else String(rows[id]["slot"])

## One stat: the player's items_game.txt value, else the class fallback in weapon_defaults.json.
func stat(id: String, key: String, fallback: String) -> float:
	if id != "knife":
		var s: Dictionary = stats.get(String(rows[id]["item"]), {})
		if s.has(key) and String(s[key]).is_valid_float():
			return float(s[key])
	return float(defaults[_cls(id)][fallback])

func held() -> String:
	return slots[current]

## Puts a weapon in its slot (buy menu) and draws it.
func give(id: String) -> void:
	if not ready_ids.has(id):
		return
	var s: String = SLOT_OF[rows[id]["slot"]]
	slots[s] = id
	var prev: String = slots[s]
	slots[s] = id
	if current == s:
		current = ""  # same slot: force the redraw
		if not switch_to(s):
			slots[s] = prev
			current = s
			return
	elif not switch_to(s):
		slots[s] = prev
		return
	ammo[id] = [int(stat(id, "primary clip size", "clip")), int(stat(id, "primary reserve ammo max", "reserve"))]
	_hud()

func switch_to(s: String) -> bool:
	if s == current or slots.get(s, "") == "":
		return false
	var vm: Viewmodel = main.viewmodel
	var id: String = slots[s]
	var ok := false
	if id == "knife":
		ok = vm.equip(main.content.path_of("model_knife_ct"), {"draw": main.content.path_of("clip_knife_draw"), "idle": main.content.path_of("clip_knife_idle"), "inspect": main.content.path_of("clip_knife_inspect")})
	else:
		var clips := {}
		for k in rows[id]["clips"]:
			clips[k] = _glb(rows[id]["clips"][k])
		ok = vm.equip(_glb(rows[id]["model"]), clips)
	if not ok:
		main.hud.message("can't draw %s: %s" % [id, vm.why], 2.0)
		return false
	if current != "":
		last = current
	current = s
	_reload_until = 0.0
	_next_fire = _now() + maxf(vm.clip_length("draw"), 0.3)
	_hud()
	return true

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _blocked() -> bool:
	return (main.settings and main.settings.is_open) or (_buy and _buy.visible) or main.player == null or main.player.frozen

func _process(dt: float) -> void:
	if main == null or main.player == null:
		return
	var id := held()
	# recovery: CS2 eases fire inaccuracy and view punch back to rest
	var rec := stat(id, "recovery time stand", "cycletime") if id != "" else 0.3
	_inaccuracy = move_toward(_inaccuracy, 0.0, dt * maxf(_inaccuracy, 1.0) / maxf(rec, 0.05))
	_punch = move_toward(_punch, 0.0, dt * maxf(_punch * 4.0, 2.0))
	main.player.cam.rotation_degrees.x = clampf(main.player.pitch + _punch, -89.0, 89.0)
	if Input.is_action_just_pressed("surf_buymenu") and not (main.settings and main.settings.is_open):
		_buy.visible = not _buy.visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _buy.visible else Input.MOUSE_MODE_CAPTURED
	if _blocked():
		return
	for pair in [["surf_slot1", "primary"], ["surf_slot2", "secondary"], ["surf_slot3", "knife"]]:
		if Input.is_action_just_pressed(pair[0]):
			switch_to(pair[1])
	if Input.is_action_just_pressed("surf_lastinv"):
		switch_to(last)
	if Input.is_action_just_pressed("surf_reload"):
		reload()
	if _reload_until > 0.0 and _now() >= _reload_until:
		_finish_reload()
	var auto := stat(id, "is full auto", "full_auto") > 0.5
	if Input.is_action_just_pressed("surf_attack") or (auto and Input.is_action_pressed("surf_attack")):
		fire()

func fire() -> void:
	var id := held()
	var t := _now()
	if id == "" or t < _next_fire or _reload_until > 0.0:
		return
	var a: Array = ammo.get(id, [-1, -1])
	if id != "knife" and int(a[0]) <= 0:
		reload()
		return
	# tick-accurate cadence: holding fire keeps the exact cycletime instead of drifting a frame per shot
	var cyc := stat(id, "cycletime", "cycletime")
	_next_fire = _next_fire + cyc if t - _next_fire < cyc else t + cyc
	if id != "knife":
		a[0] = int(a[0]) - 1
	var vm: Viewmodel = main.viewmodel
	if not vm.play("shoot1") and id == "knife":
		vm.play("inspect")
	_sound(id)
	var cam: Camera3D = main.player.cam
	var reach := 1.5
	if id != "knife":
		reach = (stat(id, "range", "damage") if _has(id, "range") else 8192.0) * u
	var spread_mrad := _spread(id)
	var hit_any := false
	var head_any := false
	var per_target := {}  # collider -> [damage, head, point]: shotgun pellets land as one hit per target
	for i in int(stat(id, "bullets", "bullets")):
		var r := _shoot_ray(cam, reach, spread_mrad)
		if r.is_empty():
			continue
		var dist_u: float = cam.global_position.distance_to(r["position"]) / u
		var dmg := stat(id, "damage", "damage") * pow(stat(id, "range modifier", "range_modifier"), dist_u / 500.0)
		var col: Object = r["collider"]
		if col and col.has_method("hit"):
			var head: bool = col.get_meta("head", false) or col.get("is_head") == true
			if head:
				dmg *= stat(id, "headshot multiplier", "headshot")
			var key: Object = col.get("unit") if col.get("unit") is Object else col  # a bot's head and body are one target
			var e: Array = per_target.get(key, [0.0, false, r["position"], col])
			per_target[key] = [float(e[0]) + dmg, bool(e[1]) or head, e[2], e[3]]
		elif id != "knife":
			_decal(r["position"], r["normal"])
	for key in per_target:
		var e: Array = per_target[key]
		(e[3] as Object).hit(float(e[0]), bool(e[1]), e[2])
		hit_any = true
		head_any = head_any or bool(e[1])
	if id != "knife" and main.lobby and main.lobby.has_method("on_shot_fired"):
		main.lobby.on_shot_fired()  # one trigger pull = one shot; knife swings are not shots
	if hit_any and main.hud.has_method("hitmarker"):
		main.hud.hitmarker(head_any)
	if id != "knife":
		_inaccuracy += stat(id, "inaccuracy fire", "damage") * 0.1 if _has(id, "inaccuracy fire") else 2.0
		_punch += stat(id, "recoil magnitude", "damage") * 0.04 if _has(id, "recoil magnitude") else 0.8
	_hud()

func _has(id: String, key: String) -> bool:
	return id != "knife" and Dictionary(stats.get(String(rows[id]["item"]), {})).has(key)

## Cone in milliradians like CS2's spread + inaccuracy: standing, moving (by speed), or in the air.
func _spread(id: String) -> float:
	if id == "knife":
		return 0.0
	var p: SurfPlayer = main.player
	var base := stat(id, "spread", "damage") if _has(id, "spread") else 0.6
	var key := "inaccuracy stand"
	if not p.grounded:
		key = "inaccuracy jump"
	elif p.ducked:
		key = "inaccuracy crouch"
	var inacc := stat(id, key, "damage") if _has(id, key) else (60.0 if key == "inaccuracy jump" else 5.0)
	if p.grounded and _has(id, "inaccuracy move"):
		var maxspd := stat(id, "max player speed", "damage") if _has(id, "max player speed") else 250.0
		var k := clampf(p.speed_units() / maxspd, 0.0, 1.0)
		inacc = lerpf(inacc, stat(id, "inaccuracy move", "damage"), k)
	return base + inacc + _inaccuracy

func _shoot_ray(cam: Camera3D, reach: float, spread_mrad: float) -> Dictionary:
	var fwd := -cam.global_basis.z
	var ang := _rng.randf() * TAU
	var r := spread_mrad * 0.001 * sqrt(_rng.randf())
	var dir := (fwd + (cam.global_basis.x * cos(ang) + cam.global_basis.y * sin(ang)) * tan(r)).normalized()
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + dir * reach)
	q.exclude = [main.player.get_rid()]
	return cam.get_world_3d().direct_space_state.intersect_ray(q)

func reload() -> void:
	var id := held()
	if id == "" or id == "knife" or _reload_until > 0.0:
		return
	var a: Array = ammo[id]
	var full := int(stat(id, "primary clip size", "clip"))
	if int(a[0]) >= full or int(a[1]) <= 0:
		return
	var vm: Viewmodel = main.viewmodel
	vm.play("reload")
	_reload_until = _now() + maxf(vm.clip_length("reload"), 1.0)

func _finish_reload() -> void:
	_reload_until = 0.0
	var id := held()
	var a: Array = ammo[id]
	var need := int(stat(id, "primary clip size", "clip")) - int(a[0])
	var take: int = mini(need, int(a[1]))
	a[0] = int(a[0]) + take
	a[1] = int(a[1]) - take
	_hud()

func _sound(id: String) -> void:
	if id == "knife":
		return
	if not _sounds.has(id):
		var base: String = main.content.dir.path_join("cs2/" + String(rows[id]["sound_shot"]).get_basename())
		var s: AudioStream = null
		if FileAccess.file_exists(base + ".wav"):
			s = AudioStreamWAV.load_from_file(base + ".wav")
		elif FileAccess.file_exists(base + ".mp3"):
			s = AudioStreamMP3.load_from_file(base + ".mp3")
		_sounds[id] = s
	if _sounds[id]:
		_shot.stream = _sounds[id]
		_shot.play()

## Bullet hole: a small dark disc on the surface, the oldest removed past 48.
func _decal(at: Vector3, n: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.05, 0.05)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.05, 0.05)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	main.add_child(mi)
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	mi.global_transform = Transform3D(Basis.looking_at(-n, up), at + n * 0.005)
	_decals.append(mi)
	if _decals.size() > 48:
		(_decals.pop_front() as Node).queue_free()

func _hud() -> void:
	if main.hud == null or not main.hud.has_method("weapon"):
		return
	var id := held()
	if id == "" or id == "knife":
		main.hud.weapon("Knife", -1, -1)
	else:
		main.hud.weapon(String(rows[id]["name"]), int(ammo[id][0]), int(ammo[id][1]), int(stat(id, "primary clip size", "clip")))

## B: CS2's buy menu as columns by class; weapons prep has not exported are greyed out.
func _build_buy() -> void:
	_buy = CanvasLayer.new()
	_buy.layer = 5
	_buy.visible = false
	add_child(_buy)
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_CENTER)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.106, 0.114, 0.125, 0.92)
	sb.set_content_margin_all(18)
	sb.set_corner_radius_all(4)
	bg.add_theme_stylebox_override("panel", sb)
	_buy.add_child(bg)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	bg.add_child(cols)
	for cls in MENU_COLUMNS:
		var v := VBoxContainer.new()
		var h := Label.new()
		h.text = String(cls).to_upper()
		h.add_theme_color_override("font_color", Color(0.878, 0.643, 0.227))
		v.add_child(h)
		for id in rows:
			if rows[id]["slot"] != cls:
				continue
			var b := Button.new()
			b.text = rows[id]["name"]
			b.custom_minimum_size = Vector2(150, 28)
			b.disabled = not ready_ids.has(id)
			if b.disabled:
				b.tooltip_text = "Not exported from your CS2 install yet"
			var wid: String = id
			b.pressed.connect(func() -> void:
				give(wid)
				_buy.visible = false
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED)
			v.add_child(b)
		cols.add_child(v)
	bg.position = -bg.get_combined_minimum_size() * 0.5
