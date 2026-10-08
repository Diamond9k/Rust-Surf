## systems.viewmodel: the CS2 arms + default CT knife with its real draw / idle / inspect clips.
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

func setup(c: Content, cam: Camera3D) -> void:
	content = c
	for r in Sheets.load_sheet("viewmodel")["rows"]:
		V[r["id"]] = float(r["value"])
	cam.add_child(self)
	position = Vector3(V["offset_x"], V["offset_y"], V["offset_z"])
	rotation_degrees = Vector3(0, V["yaw"], 0)
	scale = Vector3.ONE * V["scale"]
	_build()

const ARMS_SKEL := "animation_skeletons_characters_viewmodel_vnmskel"
const KNIFE_SKEL := "animation_skeletons_weapons_knife_default_ct_vnmskel"

## The arms and knife keep their own imported skeletons and skins. Their skeleton containers are
## renamed to the names the clip rig uses, so the clip AnimationPlayer (moved under the same root)
## drives them with its track paths untouched.
func _build() -> void:
	rig = Node3D.new()
	rig.name = "vmroot"
	add_child(rig)
	var got := 0
	for pair in [["model_arms", ARMS_SKEL], ["model_knife_ct", KNIFE_SKEL]]:
		var s := content.glb_of(pair[0])
		if s == null:
			continue
		var inner := _skeleton_container(s)
		if inner == null:
			s.queue_free()
			continue
		inner.get_parent().remove_child(inner)
		inner.name = pair[1]
		rig.add_child(inner)
		got += 1
		s.queue_free()
	if got == 0:
		why = "arms and knife glb missing"
		return
	var clip := content.glb_of("clip_knife_idle")
	if clip == null:
		why = "clip_knife_idle missing"
		return
	anim = _find(clip, "AnimationPlayer") as AnimationPlayer
	if anim == null:
		why = "idle clip has no AnimationPlayer"
		clip.queue_free()
		return
	_idle_name = anim.get_animation_list()[0]
	for name in [ARMS_SKEL, KNIFE_SKEL]:
		var cn := clip.get_node_or_null(name)
		var mn := rig.get_node_or_null(name)
		if cn and mn:
			_copy_rest(_find(cn, "Skeleton3D") as Skeleton3D, _find(mn, "Skeleton3D") as Skeleton3D)
	clip.remove_child(anim)
	rig.add_child(anim)
	clip.queue_free()
	_wire_knife()
	for pair in [["clip_knife_draw", "draw"], ["clip_knife_inspect", "inspect"]]:
		var s := content.glb_of(pair[0])
		if s:
			var ap := _find(s, "AnimationPlayer") as AnimationPlayer
			if ap:
				var a := ap.get_animation(ap.get_animation_list()[0]).duplicate() as Animation
				anim.get_animation_library("").add_animation(pair[1], a)
				if pair[1] == "draw": _draw_name = "draw"
				else: _inspect_name = "inspect"
			s.queue_free()
	ok = true
	if _draw_name != "":
		anim.play(_draw_name)
		anim.animation_finished.connect(func(_n: String) -> void: idle())
	else:
		idle()

## CS2 hangs the weapon off the wpn bone of the arms; the clip has no knife tracks, so every time
## the arms skeleton updates, the knife container is moved so its weapon bone sits on wpn.
func _wire_knife() -> void:
	var an := rig.get_node_or_null(ARMS_SKEL)
	var kn := rig.get_node_or_null(KNIFE_SKEL)
	if an == null or kn == null:
		return
	_arms_skel = _find(an, "Skeleton3D") as Skeleton3D
	_knife_skel = _find(kn, "Skeleton3D") as Skeleton3D
	if _arms_skel == null or _knife_skel == null:
		return
	_wpn = _arms_skel.find_bone("wpn")
	var w := _knife_skel.find_bone("weapon")
	if _wpn < 0 or w < 0:
		return
	_weapon_rest = _knife_skel.transform * _knife_skel.get_bone_global_rest(w)
	_arms_skel.skeleton_updated.connect(_attach_knife)
	_attach_knife()

func _attach_knife() -> void:
	var kn := rig.get_node_or_null(KNIFE_SKEL) as Node3D
	var an := rig.get_node_or_null(ARMS_SKEL) as Node3D
	if kn == null or an == null:
		return
	var wpn_rig := an.transform * _arms_skel.transform * _arms_skel.get_bone_global_pose(_wpn)
	kn.transform = wpn_rig * _weapon_rest.affine_inverse()

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
