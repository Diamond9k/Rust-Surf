## systems.viewmodel: the CS2 arms + default CT knife with its real draw / idle / inspect clips, any
## CS2 gun with its clips, and a procedural kick for the actions a weapon has no clip for.
## The clip glb carries the viewmodel skeleton (56 bones) with the animation keyed on it. The arms
## mesh is skinned to a bigger skeleton (82 bones) by index, so its Skin gets bind names and the
## missing bones are added to the clip skeleton before the mesh is re-parented onto it.
class_name Viewmodel
extends Node3D

var content: Content
var anim: AnimationPlayer
var rig: Node3D
var ok := false
var why := ""
var V := {}
var _idle_name := ""
var _inspect_name := ""
var _draw_name := ""
var _arms_skel: Skeleton3D
var _knife_skel: Skeleton3D
var _wpn := -1
var _weapon_rest := Transform3D.IDENTITY
var _kick := ""          # procedural move when a weapon has no clip for it: shot, slash, stab, shell, silencer, dry
var _kick_t := 1.0
var _kick_dur := 0.1
var _next_clip := ""     # one of our clips to play when the current one ends (then idle)
var K := {}              # weapon_defaults.json vm_kick_<kind>: [seconds, x, y, z m, pitch, yaw, roll deg]
var _bob_phase := 0.0    # movement bob cycle, 0..1
var _bob_amt := 0.0      # eased 0..1 share of the bob (ground speed over the reference speed)
var _sway := Vector2.ZERO  # eased lag of the rig behind the turning view, degrees (pitch, yaw)
var _last_view := Vector2.INF
var B := {}              # weapon_defaults.json vm_* mechanics: bob and sway

## The arms keep CS2's viewmodel_fov while the world uses fov 90. Squeezing the rig in the camera
## plane by k = tan(fov/2) / tan(viewmodel_fov/2) (both Source fovs, horizontal at 4:3) projects it
## exactly as a separate viewmodel camera would, and the arms stay lit by the real sun and sky.
## (A SubViewport camera was tried first: Godot did not light the viewmodel layer in it.)
## The whole rig is also drawn `shrink` times smaller and closer to the eye, with the camera's near plane
## scaled to match: the picture is the same, but no wall the player can touch is ever in front of it.
const LAYER := 1 << 19
var _main_cam: Camera3D
var world_fov := 90.0
var shrink := 1.0

## Settings menu hook: any of viewmodel_fov / viewmodel_offset_x/y/z (CS2 units) and world_fov.
func set_view(vals: Dictionary) -> void:
	for k in vals:
		if k == "world_fov":
			world_fov = float(vals[k])
		else:
			V[k] = float(vals[k])
	_place()

func _place() -> void:
	var u: float = Sheets.movement()["unit_to_m"]
	var k := tan(deg_to_rad(world_fov) * 0.5) / tan(deg_to_rad(V["viewmodel_fov"]) * 0.5)
	var squeeze := Basis.from_scale(Vector3(k, k, 1.0))
	var rig_basis := Basis.from_euler(Vector3(0, deg_to_rad(V["yaw"]), 0)).scaled(Vector3.ONE * V["scale"])
	var off := Vector3(V["offset_x"] + V["viewmodel_offset_x"] * u, V["offset_y"] + V["viewmodel_offset_z"] * u, V["offset_z"] - V["viewmodel_offset_y"] * u)
	transform = Transform3D(squeeze * rig_basis * shrink, squeeze * off * shrink)

func setup(c: Content, cam: Camera3D, convars: Dictionary = {}) -> void:
	content = c
	_main_cam = cam
	for r in Sheets.load_sheet("viewmodel")["rows"]:
		V[r["id"]] = float(r["value"])
	# The player's own CS2 viewmodel convars win over the sheet defaults (Source units, x right, y forward, z up).
	for k in ["viewmodel_fov", "viewmodel_offset_x", "viewmodel_offset_y", "viewmodel_offset_z"]:
		if convars.has(k) and str(convars[k]).is_valid_float():
			V[k] = float(convars[k])
	for r in Sheets.load_sheet("weapon_defaults")["mechanics"]:
		if r["id"] == "viewmodel_shrink":
			shrink = clampf(float(r["value"]), 0.01, 1.0)
		elif String(r["id"]).begins_with("vm_kick_") and r["value"] is Array:
			K[String(r["id"]).trim_prefix("vm_kick_")] = r["value"]
		elif String(r["id"]).begins_with("vm_"):
			B[r["id"]] = float(r["value"])
	cam.near *= shrink
	cam.add_child(self)
	world_fov = Sheets.movement()["fov_default"]
	_place()
	_build()
	for mi in _all(self, "MeshInstance3D"):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fix_materials(mi as MeshInstance3D)

const ARMS_SKEL := "animation_skeletons_characters_viewmodel_vnmskel"
const KNIFE_SKEL := "animation_skeletons_weapons_knife_default_ct_vnmskel"
var _weapon_name := ""   # skeleton container name of the held weapon under rig
var _clips := {}         # our clip name (draw, idle, shoot1, reload, inspect) -> animation name

## The arms stay for the whole session; equip() swaps the held weapon and the clip set.
func _build() -> void:
	rig = Node3D.new()
	rig.name = "vmroot"
	add_child(rig)
	var s := content.glb_of("model_arms")
	var inner := _skeleton_container(s) if s else null
	if inner == null:
		why = "arms glb missing"
		if s: s.queue_free()
		return
	inner.get_parent().remove_child(inner)
	inner.name = ARMS_SKEL
	rig.add_child(inner)
	s.queue_free()
	_arms_skel = _find(inner, "Skeleton3D") as Skeleton3D
	equip(content.path_of("model_knife_ct"), {"draw": content.path_of("clip_knife_draw"), "idle": content.path_of("clip_knife_idle"), "inspect": content.path_of("clip_knife_inspect")})

## Any CS2 weapon: its model glb and its viewmodel clip glbs (absolute paths; idle is required).
## The idle clip carries the arms skeleton and, for guns, the weapon skeleton with its tracks: the
## weapon container is renamed to the name the clip uses so the tracks find it. Returns false and
## keeps the current weapon when a file is missing.
func equip(model_path: String, clip_paths: Dictionary) -> bool:
	if _arms_skel == null:
		return false
	var model := content.glb(model_path)
	var clip := content.glb(String(clip_paths.get("idle", "")))
	var wc := _skeleton_container(model) if model else null
	var ap := _find(clip, "AnimationPlayer") as AnimationPlayer if clip else null
	if wc == null or ap == null:
		why = "missing " + (model_path.get_file() if wc == null else String(clip_paths.get("idle", "")).get_file())
		for n in [model, clip]:
			if n: n.queue_free()
		return false
	if _idle_of(ap, clip_paths) == "":
		why = "no idle clip in " + String(clip_paths.get("idle", "")).get_file()
		model.queue_free()
		clip.queue_free()
		return false
	var wname := KNIFE_SKEL if model_path.contains("knife") else String(wc.name)
	for ch in clip.get_children():
		if ch is Node3D and ch.name != ARMS_SKEL and _find(ch, "Skeleton3D") != null:
			wname = String(ch.name)
	# out with the old weapon and clips
	if _arms_skel.skeleton_updated.is_connected(_attach_weapon):
		_arms_skel.skeleton_updated.disconnect(_attach_weapon)
	if _weapon_name != "" and rig.get_node_or_null(_weapon_name):
		var old := rig.get_node(_weapon_name)
		rig.remove_child(old)
		old.queue_free()
	if anim:
		rig.remove_child(anim)
		anim.queue_free()
	wc.get_parent().remove_child(wc)
	wc.name = wname
	rig.add_child(wc)
	model.queue_free()
	_weapon_name = wname
	_knife_skel = _find(wc, "Skeleton3D") as Skeleton3D
	for name in [ARMS_SKEL, wname]:
		var cn := clip.get_node_or_null(name)
		var mn := rig.get_node_or_null(name)
		if cn and mn:
			_copy_rest(_find(cn, "Skeleton3D") as Skeleton3D, _find(mn, "Skeleton3D") as Skeleton3D)
	clip.remove_child(ap)
	rig.add_child(ap)
	clip.queue_free()
	anim = ap
	# The glb copy shares its AnimationLibrary with Content's cached scene, so this weapon gets a library of
	# its own: adding draw / reload / shoot1 to the shared one would leak them into the next equip of it.
	var idle_clip := _idle_of(ap, clip_paths)
	var lib := AnimationLibrary.new()
	var src := ap.get_animation_library("")
	for n in src.get_animation_list():
		lib.add_animation(n, src.get_animation(n).duplicate() as Animation)
	ap.remove_animation_library("")
	ap.add_animation_library("", lib)
	_clips = {"idle": idle_clip}
	_idle_name = idle_clip
	for k in clip_paths:
		if k == "idle":
			continue
		var s := content.glb(String(clip_paths[k]))
		if s:
			var p2 := _find(s, "AnimationPlayer") as AnimationPlayer
			var names := p2.get_animation_list() if p2 else PackedStringArray()
			var pick := ""
			for n in names:
				if pick == "" and n != "RESET":
					pick = n
			if pick != "":
				lib.add_animation(k, p2.get_animation(pick).duplicate() as Animation)
				_clips[k] = k
			s.queue_free()
	_draw_name = _clips.get("draw", "")
	_inspect_name = _clips.get("inspect", _clips.get("lookat01", ""))
	for mi in _all(wc, "MeshInstance3D"):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fix_materials(mi as MeshInstance3D)
	_wire_weapon()
	ok = true
	why = ""
	anim.animation_finished.connect(func(n: String) -> void:
		if n == _idle_name:
			return
		var nx := _next_clip
		_next_clip = ""
		if nx == "" or not play(nx):
			idle())
	if not play("draw"):
		idle()
	return true

## The idle clip's own name in a freshly loaded clip player: its first clip that is not RESET or one of ours.
func _idle_of(ap: AnimationPlayer, clip_paths: Dictionary) -> String:
	if not ap.has_animation_library(""):
		return ""
	for n in ap.get_animation_library("").get_animation_list():
		if n != "RESET" and not clip_paths.has(String(n)):
			return n
	return ""

func has_clip(clip: String) -> bool:
	return _clips.has(clip)

## Shows or hides the held weapon's meshes whose node name contains any of the words (the silencer part);
## returns how many matched, 0 when the exported model names no such part.
func set_parts(words: PackedStringArray, on: bool) -> int:
	var wn := rig.get_node_or_null(_weapon_name) if rig else null
	if wn == null:
		return 0
	var n := 0
	for mi in _all(wn, "MeshInstance3D"):
		var nm := String((mi as Node).name).to_lower()
		for w in words:
			if w.strip_edges() != "" and nm.contains(w.strip_edges().to_lower()):
				(mi as MeshInstance3D).visible = on
				n += 1
				break
	return n

## Plays one of our clip names (draw, idle, shoot1, reload, inspect); false when this weapon has none.
func play(clip: String) -> bool:
	if anim == null or not _clips.has(clip):
		return false
	_next_clip = ""
	anim.stop()
	anim.play(_clips[clip])
	return true

## Plays one of our clips after the one playing now ends (at once when nothing of ours plays).
func queue_clip(clip: String) -> bool:
	if anim == null or not _clips.has(clip):
		return false
	if current() == "" or current() == "idle":
		return play(clip)
	_next_clip = clip
	return true

## Our clip name playing now ("" when none of ours is).
func current() -> String:
	if anim == null or not anim.is_playing():
		return ""
	for k in _clips:
		if _clips[k] == anim.current_animation:
			return k
	return ""

## A short procedural move of the whole rig for actions the extracted clips do not cover (the default
## knife ships no attack clips here): shot kicks back and up, slash sweeps right to left, stab thrusts, a
## shell dips the gun, the silencer twists it, a dry fire twitches. seconds > 0 scales the move's length.
func kick(kind: String, seconds: float = 0.0) -> void:
	if not K.has(kind):
		return
	var k: Array = K[kind]
	_kick = kind
	_kick_t = 0.0
	_kick_dur = maxf(seconds * float(k[0]) if seconds > 0.0 else float(k[0]), 0.01)

## Weapons feeds the player's ground speed (units/s, 0 in the air) and view angles (degrees) every frame.
func move(speed_units: float, view: Vector2, dt: float) -> void:
	if B.is_empty() or dt <= 0.0:
		return
	var want := clampf(speed_units / maxf(float(B["vm_bob_ref_speed"]), 1.0), 0.0, 1.0)
	_bob_amt = lerpf(_bob_amt, want, 1.0 - exp(-float(B["vm_bob_ease"]) * dt))
	_bob_phase = fmod(_bob_phase + dt / maxf(float(B["vm_bob_cycle"]), 0.05) * _bob_amt, 1.0)
	if _last_view == Vector2.INF:
		_last_view = view
	var d := Vector2(view.x - _last_view.x, wrapf(view.y - _last_view.y, -180.0, 180.0))
	_last_view = view
	var target := (-d * float(B["vm_sway_scale"])).limit_length(float(B["vm_sway_max"]))
	_sway = _sway.lerp(target, 1.0 - exp(-float(B["vm_sway_ease"]) * dt))

## The bob and sway as a rig transform: a figure-eight of lat x vert Source units over one cycle, and the
## rig trailing the view by the eased sway angles. The rig faces -Z after the 180 degree yaw, so its x and z
## run opposite to the camera's.
func _motion() -> Transform3D:
	if B.is_empty():
		return Transform3D.IDENTITY
	var u: float = Sheets.movement()["unit_to_m"]
	var a := _bob_phase * TAU
	var lat := sin(a) * float(B["vm_bob_lat"]) * _bob_amt * u
	var vert := -absf(sin(a)) * float(B["vm_bob_vert"]) * _bob_amt * u
	var rot := Basis.from_euler(Vector3(deg_to_rad(-_sway.x), deg_to_rad(_sway.y), 0.0))
	return Transform3D(rot, Vector3(-lat, vert, 0.0))

func _process(dt: float) -> void:
	if rig == null:
		return
	if _kick == "":
		rig.transform = _motion()
		return
	_kick_t += dt / _kick_dur
	if _kick_t >= 1.0:
		_kick = ""
		rig.transform = _motion()
		return
	var w := sin(_kick_t * PI)  # out and back
	var k: Array = K[_kick]
	var pos := Vector3(float(k[1]), float(k[2]), float(k[3])) * w
	var rot := Vector3(deg_to_rad(float(k[4])), deg_to_rad(float(k[5])), deg_to_rad(float(k[6]))) * w
	match _kick:
		"slash":  # sweeps right to left across the view
			pos.x = lerpf(float(k[1]), -float(k[1]) * 1.6, _kick_t) * w
			rot.y = deg_to_rad(lerpf(float(k[5]), -float(k[5]) * 1.4, _kick_t)) * w
		"silencer":  # the can turns a few times while the gun is tipped
			rot.z *= cos(_kick_t * TAU * 2.0)
	rig.transform = _motion() * Transform3D(Basis.from_euler(rot), pos)

func clip_length(clip: String) -> float:
	if anim == null or not _clips.has(clip):
		return 0.0
	return anim.get_animation(_clips[clip]).length

## CS2 hangs the weapon off the wpn bone of the arms: every time the arms skeleton updates, the
## weapon container is moved so the rest pose of its root bone sits on wpn.
func _wire_weapon() -> void:
	var wn := rig.get_node_or_null(_weapon_name)
	if wn == null or _knife_skel == null:
		return
	_wpn = _arms_skel.find_bone("wpn")
	var w := _knife_skel.find_bone("weapon")
	if w < 0:
		w = 0
	if _wpn < 0:
		return
	_weapon_rest = _knife_skel.transform * _knife_skel.get_bone_global_rest(w)
	_arms_skel.skeleton_updated.connect(_attach_weapon)
	_attach_weapon()

func _attach_weapon() -> void:
	var wn := rig.get_node_or_null(_weapon_name) as Node3D
	var an := rig.get_node_or_null(ARMS_SKEL) as Node3D
	if wn == null or an == null:
		return
	var wpn_rig := an.transform * _arms_skel.transform * _arms_skel.get_bone_global_pose(_wpn)
	wn.transform = wpn_rig * _weapon_rest.affine_inverse()

## The model skeleton takes the global rest pose of the clip skeleton for every shared bone, so the
## bones the clip leaves untracked (arm_upper, clavicles) sit where CS2 keeps them.
func _copy_rest(clip: Skeleton3D, model: Skeleton3D) -> void:
	if clip == null or model == null:
		return
	var mg := {}
	for j in range(model.get_bone_count()):
		var parent := model.get_bone_parent(j)
		var parent_g: Transform3D = mg[parent] if parent >= 0 else Transform3D.IDENTITY
		var i := clip.find_bone(model.get_bone_name(j))
		var g: Transform3D
		if i >= 0:
			g = clip.get_bone_global_rest(i)
		else:
			g = parent_g * model.get_bone_rest(j)
		model.set_bone_rest(j, parent_g.affine_inverse() * g)
		model.reset_bone_pose(j)
		mg[j] = g

## The child of a glb scene root that holds the Skeleton3D (and its skinned meshes).
func _skeleton_container(scene: Node) -> Node3D:
	for ch in scene.get_children():
		if ch is Node3D and _find(ch, "Skeleton3D") != null:
			return ch
	return null

## One line for the HUD while tuning: which clip plays and where the hand and weapon bones sit.
func debug() -> String:
	if rig == null or anim == null:
		return "viewmodel: " + why
	var sk := _find(rig.get_node_or_null(ARMS_SKEL) if rig.get_node_or_null(ARMS_SKEL) else rig, "Skeleton3D") as Skeleton3D
	if sk == null:
		return "viewmodel: no skeleton"
	var h := sk.find_bone("hand_R")
	var w := sk.find_bone("wpn")
	var hp := sk.get_bone_global_pose(h).origin if h >= 0 else Vector3.ZERO
	var wp := sk.get_bone_global_pose(w).origin if w >= 0 else Vector3.ZERO
	var meshes := _all(sk, "MeshInstance3D")
	var binds := -1
	if meshes.size() > 0 and meshes[0].skin:
		binds = meshes[0].skin.get_bind_count()
	return "vm %s playing=%s t=%.2f bones=%d meshes=%d binds=%d hand_R=%s wpn=%s" % [anim.current_animation, anim.is_playing(), anim.current_animation_position, sk.get_bone_count(), meshes.size(), binds, hp, wp]

func idle() -> void:
	if anim and anim.current_animation != _idle_name:
		anim.get_animation(_idle_name).loop_mode = Animation.LOOP_LINEAR
		anim.play(_idle_name)

func inspect() -> void:
	if ok and _inspect_name != "" and anim.current_animation != _inspect_name:
		anim.play(_inspect_name)
	elif ok and _clips.has("lookat01") and anim.current_animation != "lookat01":
		anim.play("lookat01")

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for ch in n.get_children():
		var f := _find(ch, cls)
		if f:
			return f
	return null

func _all(n: Node, cls: String) -> Array:
	var out := []
	if n.get_class() == cls:
		out.append(n)
	for ch in n.get_children():
		out += _all(ch, cls)
	return out

## VRF writes CS2 materials with no metallic factor, which glTF reads as metallic 1 (masked by the
## metal map). Skin and gloves are set to plain dielectric so they never mirror the sky. A weapon's mask
## texture is CS2's csgo_weapon g_tMetalness packed as glTF's metallicRoughness image, but with roughness
## in red, metalness in green and blue empty: read that way (vm_rough_channel / vm_metal_channel) when its
## blue channel is empty, so a blade or a receiver is bare steel instead of grey plastic. vm_metal_scale
## tempers it: without CS2's map cubemaps a full metal mirrors only the open sky and reads blue.
func _fix_materials(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var m := mi.get_active_material(i) as StandardMaterial3D
		if m == null:
			continue
		m = m.duplicate() as StandardMaterial3D
		var n := m.resource_name.to_lower()
		if n.contains("arm") or n.contains("glove") or n.contains("sleeve") or n.contains("hand"):
			m.metallic = 0.0
			m.metallic_texture = null
			m.roughness = 0.75
		elif m.metallic_texture != null and m.metallic_texture == m.roughness_texture and B.has("vm_metal_channel") and _blue_empty(m.metallic_texture):
			m.metallic_texture_channel = int(B["vm_metal_channel"]) as BaseMaterial3D.TextureChannel
			m.roughness_texture_channel = int(B["vm_rough_channel"]) as BaseMaterial3D.TextureChannel
			m.metallic = float(B.get("vm_metal_scale", 1.0))
			m.roughness = 1.0
		mi.set_surface_override_material(i, m)

## True when a mask texture's blue channel is black everywhere (checked on a small copy); false when the
## image cannot be read, so an unreadable mask keeps glTF's own channels.
func _blue_empty(tex: Texture2D) -> bool:
	var img := tex.get_image()
	if img == null or img.is_empty():
		return false
	img = img.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return false
	img.resize(32, 32, Image.INTERPOLATE_BILINEAR)
	var green := 0.0
	for y in 32:
		for x in 32:
			var c := img.get_pixel(x, y)
			if c.b > 0.02:
				return false
			green = maxf(green, c.g)
	return green > 0.02
