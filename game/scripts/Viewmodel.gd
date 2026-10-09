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
var _kick := ""          # procedural move when a weapon has no clip for it: shot, slash, stab
var _kick_t := 1.0

## The arms keep CS2's viewmodel_fov while the world uses fov 90. Squeezing the rig in the camera
## plane by k = tan(fov/2) / tan(viewmodel_fov/2) (both Source fovs, horizontal at 4:3) projects it
## exactly as a separate viewmodel camera would, and the arms stay lit by the real sun and sky.
## (A SubViewport camera was tried first: Godot did not light the viewmodel layer in it.)
const LAYER := 1 << 19
var _main_cam: Camera3D
var world_fov := 90.0

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
	transform = Transform3D(squeeze * rig_basis, squeeze * off)

func setup(c: Content, cam: Camera3D, convars: Dictionary = {}) -> void:
	content = c
	_main_cam = cam
	for r in Sheets.load_sheet("viewmodel")["rows"]:
		V[r["id"]] = float(r["value"])
	# The player's own CS2 viewmodel convars win over the sheet defaults (Source units, x right, y forward, z up).
	for k in ["viewmodel_fov", "viewmodel_offset_x", "viewmodel_offset_y", "viewmodel_offset_z"]:
		if convars.has(k) and str(convars[k]).is_valid_float():
			V[k] = float(convars[k])
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
	_clips = {"idle": anim.get_animation_list()[0]}
	_idle_name = _clips["idle"]
	for k in clip_paths:
		if k == "idle":
			continue
		var s := content.glb(String(clip_paths[k]))
		if s:
			var p2 := _find(s, "AnimationPlayer") as AnimationPlayer
			if p2:
				anim.get_animation_library("").add_animation(k, p2.get_animation(p2.get_animation_list()[0]).duplicate() as Animation)
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
		if n != _idle_name: idle())
	if not play("draw"):
		idle()
	return true

## Plays one of our clip names (draw, idle, shoot1, reload, inspect); false when this weapon has none.
func play(clip: String) -> bool:
	if anim == null or not _clips.has(clip):
		return false
	anim.stop()
	anim.play(_clips[clip])
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
## knife ships no attack clips here): shot kicks back and up, slash sweeps right to left, stab thrusts.
func kick(kind: String) -> void:
	_kick = kind
	_kick_t = 0.0

func _process(dt: float) -> void:
	if rig == null or _kick == "":
		return
	var dur := 0.12 if _kick == "shot" else (0.35 if _kick == "slash" else 0.5)
	_kick_t += dt / dur
	if _kick_t >= 1.0:
		_kick = ""
		rig.transform = Transform3D.IDENTITY
		return
	var w := sin(_kick_t * PI)  # out and back
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO
	match _kick:
		"shot":
			pos = Vector3(0, 0.004, 0.025) * w
			rot = Vector3(deg_to_rad(2.5), 0, 0) * w
		"slash":
			pos = Vector3(lerpf(0.05, -0.08, _kick_t), 0.02, -0.04) * w
			rot = Vector3(0, deg_to_rad(lerpf(-25.0, 35.0, _kick_t)), deg_to_rad(30.0)) * w
		"stab":
			pos = Vector3(-0.03, 0.03, -0.12) * w
			rot = Vector3(deg_to_rad(-12.0), deg_to_rad(10.0), 0) * w
	rig.transform = Transform3D(Basis.from_euler(rot), pos)

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
## metal map). Skin and gloves are set to plain dielectric so they never mirror the sky.
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
		mi.set_surface_override_material(i, m)
