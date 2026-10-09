## systems.weapons: the loadout (primary, pistol, knife, Zeus) on the CS2 arms and CS2's gun model on top of
## the stats of the player's own items_game.txt: a seeded recoil pattern split into aim punch (where the
## bullets go) and view punch (what the camera shows), spread + inaccuracy cones, scopes, silencer, burst and
## revolver fan modes on attack2, shell-by-shell shotgun reloads, penetration, armor, per-weapon move speed,
## the knife's slash / stab / backstab and the B buy menu. A stat items_game does not give falls back to its
## class row in weapon_defaults.json; the model's constants are that sheet's mechanics rows.
class_name Weapons
extends Node

const SLOT_OF := {"rifle": "primary", "sniper": "primary", "smg": "primary", "heavy": "primary", "pistol": "secondary", "gear": "taser"}
const MENU_COLUMNS := ["pistol", "smg", "rifle", "heavy", "sniper", "gear"]
## items_game attribute -> weapon_defaults.json column (its class fallback)
const COL := {"damage": "damage", "cycletime": "cycletime", "cycletime alt": "cycletime_alt", "primary clip size": "clip",
	"primary reserve ammo max": "reserve", "headshot multiplier": "headshot", "range": "range", "range modifier": "range_modifier",
	"armor ratio": "armor_ratio", "penetration": "penetration", "is full auto": "full_auto", "bullets": "bullets",
	"max player speed": "max_speed", "max player speed alt": "max_speed_alt", "spread": "spread",
	"inaccuracy stand": "inacc_stand", "inaccuracy crouch": "inacc_crouch", "inaccuracy move": "inacc_move",
	"inaccuracy jump": "inacc_jump", "inaccuracy fire": "inacc_fire", "recoil angle": "recoil_angle",
	"recoil angle variance": "recoil_angle_var", "recoil magnitude": "recoil_mag", "recoil magnitude variance": "recoil_mag_var",
	"recovery time stand": "recovery_stand", "recovery time crouch": "recovery_crouch", "zoom levels": "zoom_levels",
	"zoom fov 1": "zoom_fov_1", "zoom fov 2": "zoom_fov_2", "zoom time 1": "zoom_time"}
## Keys with an " alt" twin in items_game: the scoped / silenced / burst / fan value.
const ALT_KEYS := ["spread", "inaccuracy stand", "inaccuracy crouch", "inaccuracy move", "inaccuracy jump", "inaccuracy fire",
	"recoil angle", "recoil angle variance", "recoil magnitude", "recoil magnitude variance", "cycletime", "max player speed"]

var main: Node
var rows := {}           # id -> weapons.json row, every weapon
var ready_ids := {}      # id -> true when its model and idle clip are in the data folder
var stats := {}          # weapon_x -> attributes from prep's weapon_stats.json
var defaults := {}       # class -> weapon_defaults.json row
var X := {}              # weapon_defaults.json mechanics: id -> value
var slots := {"primary": "", "secondary": "", "knife": "knife", "taser": ""}
var current := "knife"
var last := "secondary"
var ammo := {}           # id -> [clip, reserve]
var u := 0.01905
var _st := {}            # id -> resolved attributes (raw items_game prefab chain, then weapon_stats.json on top)
var _ig := ""            # the player's raw items_game.txt while resolving, when prep left it in the data folder
var _ig_prefabs := -1
var _next_fire := 0.0
var _reload_until := 0.0
var _shell_next := 0.0   # shotgun: when the next shell goes in, 0 when not loading shells
var _toggle_until := 0.0 # silencer going on or off
var _inaccuracy := 0.0   # fire inaccuracy (CS's accuracy penalty), items_game units
var _recoil_index := 0.0
var _last_shot := -10.0
var _aim := Vector2.ZERO      # aim punch, degrees (x pitch up, y yaw left), before recoil_scale
var _aim_vel := Vector2.ZERO
var _view := Vector2.ZERO     # camera-only punch, degrees
var _punch := 0.0             # kept for tools that zero it; the punch lives in _aim / _view
var _tables := {}        # "id:mode" -> PackedVector2Array (angle, magnitude) of the seeded pattern
var _alt_on := {}        # id -> true while silencer / burst is on
var _zoom := 0
var _rezoom := 0
var _base_fov := 0.0
var _base_sens := 0.0
var _fov_tween: Tween
var _burst_left := 0
var _burst_at := 0.0
var _fan := false
var _posed := false      # --wpose: a render holds its scope while the camera is frozen
var _voices: Array = []
var _voice := 0
var _sounds := {}
var _decals: Array = []
var _buy: CanvasLayer
var _scope: Control
var _scope_layer: CanvasLayer
var _rng := RandomNumberGenerator.new()

func setup(m: Node) -> void:
	main = m
	u = Sheets.movement()["unit_to_m"]
	var sheet := Sheets.load_sheet("weapon_defaults")
	for r in sheet["rows"]:
		defaults[r["id"]] = r
	for r in sheet["mechanics"]:
		X[r["id"]] = r["value"]
	var sp: String = main.content.dir.path_join("cs2/weapon_stats.json")
	if FileAccess.file_exists(sp):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(sp))
		if d is Dictionary:
			stats = d
	var igp: String = main.content.dir.path_join("cs2/scripts/items/items_game.txt")
	if FileAccess.file_exists(igp):
		_ig = FileAccess.get_file_as_string(igp)
		_ig_prefabs = _ig.find("\"prefabs\"")
	for r in Sheets.load_sheet("weapons")["rows"]:
		rows[r["id"]] = r
		if r.get("game", "") == "cs2" and FileAccess.file_exists(_glb(r["model"])) and FileAccess.file_exists(_glb(r["clips"]["idle"])):
			ready_ids[r["id"]] = true
	for id in rows:
		_resolve(id)
	_ig = ""  # every weapon is resolved: the big text is not kept
	for i in int(X["shot_voices"]):
		var p := AudioStreamPlayer.new()
		p.volume_db = float(X["shot_volume_db"])
		add_child(p)
		_voices.append(p)
	slots["primary"] = _first_ready(["cs2_ak47", "cs2_m4a1_silencer", "cs2_m4a4"], "rifle")
	slots["secondary"] = _first_ready(["cs2_usp_silencer", "cs2_glock", "cs2_deagle"], "pistol")
	for id in rows:
		_alt_on[id] = alt_kind(id) == "silencer"  # CS2 hands out the M4A1-S and USP-S silenced
	refill()
	_build_buy()
	_build_scope()
	var ua := OS.get_cmdline_user_args()
	if ua.has("--wtest"):
		_selftest.call_deferred()
	var wp := ua.find("--wpose")
	if wp >= 0 and wp + 1 < ua.size():
		_pose.call_deferred(ua[wp + 1])
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
	return "knife" if id == "knife" or not rows.has(id) else String(rows[id]["slot"])

## Every attribute of one weapon: its items_game prefab chain (any key), then prep's weapon_stats.json.
func _resolve(id: String) -> void:
	var out := {}
	var item := String(rows[id]["item"])
	if _ig != "":
		var raw := _ig_chain(item + "_prefab", {})
		for k in raw:
			if String(raw[k]).is_valid_float():
				out[k] = float(raw[k])
	var s: Dictionary = stats.get(item, {})
	for k in s:
		if String(s[k]).is_valid_float():
			out[k] = float(s[k])
	_st[id] = out

## One stat: the player's items_game value, else the class fallback column in weapon_defaults.json.
func stat(id: String, key: String, fallback: String = "") -> float:
	var s: Dictionary = _st.get(id, {})
	if s.has(key):
		return float(s[key])
	var col := fallback if fallback != "" else String(COL.get(key, ""))
	return float(defaults[_cls(id)].get(col, 0.0))

func _has(id: String, key: String) -> bool:
	return Dictionary(_st.get(id, {})).has(key)

## The held mode's value: in alt mode (scoped, silenced, burst, fan) the key's " alt" twin when items_game
## has it. Without it a scoped cone shrinks by the class scoped_inacc_scale and anything else keeps its value.
func mstat(id: String, key: String) -> float:
	if _mode(id) == 1 and ALT_KEYS.has(key):
		if _has(id, key + " alt"):
			return stat(id, key + " alt")
		if key == "max player speed" and _zoom > 0:
			return stat(id, "max player speed alt")
		if _zoom > 0 and (key == "spread" or key.begins_with("inaccuracy")):
			return stat(id, key) * float(defaults[_cls(id)]["scoped_inacc_scale"])
	return stat(id, key)

func _mode(id: String) -> int:
	if id == held() and (_zoom > 0 or _fan):
		return 1
	return 1 if _alt_on.get(id, false) else 0

## attack2 of a weapon: scope, silencer, burst, revolver (fan fire), stab (knife) or none.
func alt_kind(id: String) -> String:
	if id == "knife":
		return "stab"
	if _has(id, "zoom levels") and stat(id, "zoom levels") > 0.0:
		return "scope"
	if _has(id, "has silencer") and stat(id, "has silencer") > 0.0:
		return "silencer"
	if _has(id, "has burst mode") and stat(id, "has burst mode") > 0.0:
		return "burst"
	return String(rows[id].get("alt", "none")) if rows.has(id) else "none"

func _zoom_levels(id: String) -> int:
	return int(stat(id, "zoom levels")) if alt_kind(id) == "scope" else 0

## Full magazine and reserve for every weapon (each aim lobby round).
func refill() -> void:
	for id in rows:
		ammo[id] = [int(stat(id, "primary clip size")), int(stat(id, "primary reserve ammo max"))]
	_reload_until = 0.0
	_shell_next = 0.0
	_hud()

func held() -> String:
	return String(slots.get(current, ""))

## Puts a weapon in its slot (buy menu) and draws it.
func give(id: String) -> void:
	if not ready_ids.has(id):
		return
	var s: String = SLOT_OF[rows[id]["slot"]]
	var prev: String = slots[s]
	var was := current
	slots[s] = id
	if current == s:
		current = ""  # same slot: force the redraw
	if not switch_to(s):
		slots[s] = prev
		current = was
		return
	ammo[id] = [int(stat(id, "primary clip size")), int(stat(id, "primary reserve ammo max"))]
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
	_set_zoom(0)
	_rezoom = 0
	_burst_left = 0
	_fan = false
	if current != "":
		last = current
	current = s
	_reload_until = 0.0
	_shell_next = 0.0
	_toggle_until = 0.0
	_next_fire = _now() + maxf(vm.clip_length("draw"), 0.3)
	_hud()
	return true

## Wall-clock seconds: shots keep their exact cycletime between frames, like CS2's sub-tick input.
func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func _blocked() -> bool:
	return (main.settings and main.settings.is_open) or (_buy and _buy.visible) or main.player == null or main.player.frozen

func _process(dt: float) -> void:
	if main == null or main.player == null:
		return
	var id := held()
	var t := _now()
	_decay(id, dt, t)
	_camera()
	if Input.is_action_just_pressed("surf_buymenu") and not (main.settings and main.settings.is_open):
		_buy.visible = not _buy.visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _buy.visible else Input.MOUSE_MODE_CAPTURED
	_speed(id)
	if _blocked():
		if _zoom > 0 and not _posed:
			_set_zoom(0)
		_burst_left = 0
		return
	for pair in [["surf_slot1", "primary"], ["surf_slot2", "secondary"]]:
		if Input.is_action_just_pressed(pair[0]):
			switch_to(pair[1])
	if Input.is_action_just_pressed("surf_slot3"):
		switch_to("taser" if current == "knife" and slots["taser"] != "" else "knife")  # 3 again cycles knife / Zeus
	if Input.is_action_just_pressed("surf_lastinv"):
		switch_to(last)
	if Input.is_action_just_pressed("surf_reload"):
		reload()
	_reload_tick(t)
	if _burst_left > 0 and t >= _burst_at:
		_shoot(held(), t, true)
	if _rezoom > 0 and t >= _next_fire and _reload_until == 0.0 and _shell_next == 0.0:
		var rz := _rezoom
		_rezoom = 0
		_set_zoom(rz)
	id = held()
	if id == "knife":
		if Input.is_action_pressed("surf_attack"):
			_knife(false)
		elif Input.is_action_pressed("surf_attack2"):
			_knife(true)
		return
	if Input.is_action_just_pressed("surf_attack2"):
		_attack2(id)
	_fan = alt_kind(id) == "revolver" and Input.is_action_pressed("surf_attack2") and not Input.is_action_pressed("surf_attack")
	var auto := stat(id, "is full auto") > 0.5
	if Input.is_action_just_pressed("surf_attack") or (auto and Input.is_action_pressed("surf_attack")) or _fan:
		fire()

## attack2 on a gun: scope level, silencer on/off, burst/semi, or (revolver) fan fire while held.
func _attack2(id: String) -> void:
	match alt_kind(id):
		"scope":
			if _reload_until > 0.0 or _shell_next > 0.0:
				return
			_rezoom = 0
			_set_zoom((_zoom + 1) % (_zoom_levels(id) + 1))
		"silencer":
			if _reload_until > 0.0 or _now() < _toggle_until:
				return
			_alt_on[id] = not _alt_on.get(id, false)
			var vm: Viewmodel = main.viewmodel
			var clip := "silencer_on" if _alt_on[id] else "silencer_off"
			var dur := vm.clip_length(clip) if vm.play(clip) else float(X["silencer_time"])
			_toggle_until = _now() + dur
			_next_fire = maxf(_next_fire, _toggle_until)
			main.hud.message("Silencer " + ("attached" if _alt_on[id] else "detached"), 1.5)
		"burst":
			_alt_on[id] = not _alt_on.get(id, false)
			main.hud.message("Switched to Burst-Fire Mode" if _alt_on[id] else "Switched to Semi-Automatic", 1.5)
	_hud()

func fire() -> void:
	var id := held()
	if id == "knife":
		_knife(false)
		return
	_shoot(id, _now(), false)

## One round (or one shotgun blast). from_burst is a follow-up round of a burst already pulled.
func _shoot(id: String, t: float, from_burst: bool) -> void:
	if id == "" or id == "knife":
		_burst_left = 0
		return
	if not from_burst and (t < _next_fire or _reload_until > 0.0 or t < _toggle_until):
		return
	var a: Array = ammo.get(id, [0, 0])
	if _shell_next > 0.0:
		if int(a[0]) <= 0:
			return
		_shell_next = 0.0  # firing breaks off a shell reload
	if int(a[0]) <= 0:
		_burst_left = 0
		reload()
		return
	var cyc := mstat(id, "cycletime")
	if alt_kind(id) == "burst" and _alt_on.get(id, false):
		if from_burst:
			_burst_left -= 1
		else:
			_burst_left = int(X["burst_shots"]) - 1
		_burst_at = t + float(X["burst_gap"])
		cyc = float(X["burst_gap"]) * float(_burst_left) + (stat(id, "cycletime alt") if _has(id, "cycletime alt") else float(X["burst_cooldown"]))
		_next_fire = t + cyc
	else:
		_burst_left = 0
		# holding the trigger keeps the exact cycletime instead of drifting a frame per shot
		_next_fire = _next_fire + cyc if t - _next_fire < cyc else t + cyc
	a[0] = int(a[0]) - 1
	_last_shot = t
	var vm: Viewmodel = main.viewmodel
	if not vm.play("shoot1"):
		vm.kick("shot")
	_sound(id)
	if main.lobby and main.lobby.has_method("on_shot_fired"):
		main.lobby.on_shot_fired()  # one trigger pull = one shot, pellets and penetration included
	var cam: Camera3D = main.player.cam
	var eye := _eye_basis()
	var inacc := _inacc(id) * float(X["inaccuracy_to_rad"])
	var spr := mstat(id, "spread") * float(X["inaccuracy_to_rad"])
	var reach := stat(id, "range") * u
	var per_target := {}  # unit -> [damage, head, point, collider]: pellets and parts land as one hit per target
	for i in int(stat(id, "bullets")):
		# CS: an inaccuracy ring and a spread ring, each a random angle and a uniform (centre-weighted) radius
		var t0 := _rng.randf() * TAU
		var r0 := _rng.randf() * inacc
		var t1 := _rng.randf() * TAU
		var r1 := _rng.randf() * spr
		var off := Vector2(cos(t0) * r0 + cos(t1) * r1, sin(t0) * r0 + sin(t1) * r1)
		var dir := (-eye.z + eye.x * off.x + eye.y * off.y).normalized()
		_trace(id, cam.global_position, dir, reach, stat(id, "damage"), per_target)
	var hit_any := false
	var head_any := false
	for key in per_target:
		var e: Array = per_target[key]
		if is_instance_valid(e[3]):
			(e[3] as Object).hit(float(e[0]), bool(e[1]), e[2])
			hit_any = true
			head_any = head_any or bool(e[1])
	if hit_any and main.hud.has_method("hitmarker"):
		main.hud.hitmarker(head_any)
	_inaccuracy += mstat(id, "inaccuracy fire")
	_recoil(id)
	if _zoom > 0 and stat(id, "cycletime") >= float(X["bolt_cycletime"]):
		var z := _zoom
		_set_zoom(0)
		_rezoom = z  # bolt action: out of the scope for the bolt, back in when ready
	if int(a[0]) <= 0:
		_burst_left = 0
	_hud()

## Eye angles plus aim punch x recoil_scale: where CS2 sends the bullets (the camera shows less of it).
func _eye_basis() -> Basis:
	var p: SurfPlayer = main.player
	var k := float(X["recoil_scale"])
	var pitch := deg_to_rad(clampf(p.pitch + _aim.x * k, -89.0, 89.0))
	return p.global_basis * Basis.from_euler(Vector3(pitch, deg_to_rad(_aim.y * k), 0.0))

## One bullet: hits along the ray, through up to pen_hits surfaces. Damage falls off with range and loses
## CS's penetration toll per surface (a chunk, a weapon term and thickness squared over 24).
func _trace(id: String, from: Vector3, dir: Vector3, reach: float, dmg: float, per_target: Dictionary) -> void:
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var ex: Array[RID] = [main.player.get_rid()]
	var start := from
	var power := stat(id, "penetration")
	var rm := stat(id, "range modifier")
	var seen := {}
	var left := int(X["pen_hits"])
	var end := from + dir * reach
	while left > 0 and dmg >= 1.0:
		var q := PhysicsRayQueryParameters3D.create(start, end)
		q.exclude = ex
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			return
		var pos: Vector3 = r["position"]
		dmg *= pow(rm, start.distance_to(pos) / u / 500.0)
		var col: Object = r["collider"]
		var body := col != null and col.has_method("hit")
		if body:
			var head: bool = col.get_meta("head", false) or col.get("is_head") == true
			var key: Object = col.get("unit") if col.get("unit") is Object else col  # a bot's parts are one target
			if not seen.has(key):
				seen[key] = true
				var d := dmg * (stat(id, "headshot multiplier") if head else 1.0)
				d = _armored(key, d, head, id)
				var e: Array = per_target.get(key, [0.0, false, pos, col])
				per_target[key] = [float(e[0]) + d, bool(e[1]) or head, e[2], e[3]]
		else:
			_decal(pos, r["normal"])
		if power <= 0.0:
			return
		var exit := _exit(space, col, pos, dir, ex)
		if exit.is_empty():
			return
		var thick: float = pos.distance_to(exit["position"]) / u
		var pm := 1.0 / float(X["pen_mod_body"] if body else X["pen_mod_world"])
		dmg -= dmg * float(X["pen_chunk"]) + maxf(0.0, 3.0 / power * 1.25) * pm * 3.0 + pm * thick * thick / 24.0
		if not body:
			_decal(exit["position"], exit["normal"])
		start = exit["position"] + dir * 0.002
		left -= 1

## One plain ray along the camera inside a cone of spread_mrad (tools aim with it; firing uses _trace).
func _shoot_ray(cam: Camera3D, reach: float, spread_mrad: float) -> Dictionary:
	var ang := _rng.randf() * TAU
	var r := spread_mrad * 0.001 * _rng.randf()
	var dir := (-cam.global_basis.z + (cam.global_basis.x * cos(ang) + cam.global_basis.y * sin(ang)) * r).normalized()
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + dir * reach)
	q.exclude = [main.player.get_rid()]
	return cam.get_world_3d().direct_space_state.intersect_ray(q)

## The far face of what the bullet entered: walk out in pen_step_units steps and look back. Nothing within
## pen_max_units, or a different object first, means the bullet stops here.
func _exit(space: PhysicsDirectSpaceState3D, col: Object, pos: Vector3, dir: Vector3, ex: Array[RID]) -> Dictionary:
	var step := float(X["pen_step_units"]) * u
	var d := step
	while d <= float(X["pen_max_units"]) * u:
		var q := PhysicsRayQueryParameters3D.create(pos + dir * d, pos + dir * 0.001)
		q.exclude = ex
		q.hit_back_faces = false
		var r: Dictionary = space.intersect_ray(q)
		if not r.is_empty():
			return r if r["collider"] == col else {}
		d += step
	return {}

## CS armor: an armored hitgroup (any but the head without a helmet) takes armor ratio x 0.5 of the damage to
## health, and the armor pays half of the rest. Only targets that carry an armor value are armored.
func _armored(key: Object, d: float, head: bool, id: String) -> float:
	var armor: Variant = key.get("armor")
	if not (armor is float or armor is int) or float(armor) <= 0.0 or (head and key.get("helmet") != true):
		return d
	var bonus := float(X["armor_bonus"])
	var health := d * stat(id, "armor ratio") * float(X["armor_ratio_scale"])
	var paid := (d - health) * bonus
	if paid > float(armor):
		health = d - float(armor) / bonus
		paid = float(armor)
	key.set("armor", float(armor) - paid)
	return health

## The weapon's seeded pattern for a mode: CS's recoil table, an angle and a magnitude per shot, each the base
## value plus a variance drawn from Source's uniform random stream seeded with the weapon's recoil seed.
func pattern(id: String, mode: int) -> PackedVector2Array:
	var k := "%s:%d" % [id, mode]
	if _tables.has(k):
		return _tables[k]
	var sfx := " alt" if mode == 1 else ""
	var seed := int(stat(id, "recoil seed")) if _has(id, "recoil seed") else (String(rows[id]["item"]).hash() & 0xffff if rows.has(id) else 0)
	var rs := SourceRandom.new()
	rs.set_seed(seed)
	var auto := stat(id, "is full auto") > 0.5
	var follow := float(X["pattern_follow"])
	var base_a := _alt_or(id, "recoil angle", sfx)
	var var_a := _alt_or(id, "recoil angle variance", sfx)
	var base_m := _alt_or(id, "recoil magnitude", sfx)
	var var_m := _alt_or(id, "recoil magnitude variance", sfx)
	var out := PackedVector2Array()
	var ang := 0.0
	var mag := 0.0
	for j in int(X["pattern_length"]):
		var an := base_a + rs.rand_float(-var_a, var_a)
		var mn := base_m + rs.rand_float(-var_m, var_m)
		if auto and j > 0:
			ang = lerpf(ang, an, follow)
			mag = lerpf(mag, mn, follow)
		else:
			ang = an
			mag = mn
		out.append(Vector2(ang, mag))
	_tables[k] = out
	return out

func _alt_or(id: String, key: String, sfx: String) -> float:
	return stat(id, key + sfx) if sfx != "" and _has(id, key + sfx) else stat(id, key)

## One shot's kick: the pattern entry at the recoil index pushes the aim punch velocity; the camera gets a
## little extra view punch of its own. The first shots of a spray are suppressed.
func _recoil(id: String) -> void:
	var tab := pattern(id, _mode(id))
	var i := clampi(int(_recoil_index), 0, tab.size() - 1)
	var e := tab[i]
	var shots := float(X["recoil_suppression_shots"])
	var mag := e.y * lerpf(float(X["recoil_suppression_factor"]), 1.0, clampf(float(i) / maxf(shots, 1.0), 0.0, 1.0))
	var r := deg_to_rad(e.x)
	_aim_vel += Vector2(cos(r), -sin(r)) * mag  # angle 0 kicks straight up, positive angles to the right
	_view.x += float(X["view_punch_extra"]) * mag
	_recoil_index += 1.0

## CS's DecayAimPunchAngle in steps no longer than a 64-tick, the fire inaccuracy recovering to
## recovery_decay_to over the recovery time, and the recoil index easing back once the trigger rests.
func _decay(id: String, dt: float, t: float) -> void:
	var n := maxi(1, ceili(dt * 64.0))
	var h := dt / float(n)
	var e8 := float(X["recoil_decay_exp"])
	var l18 := float(X["recoil_decay_lin"])
	var v45 := float(X["recoil_vel_decay"])
	var vd := float(X["view_punch_decay"])
	for i in n:
		_aim *= exp(-e8 * h)
		var l := _aim.length()
		if l > 0.0:
			_aim *= maxf(l - l18 * h, 0.0) / l
		_aim += _aim_vel * h * 0.5
		_aim_vel *= exp(-v45 * h)
		_aim += _aim_vel * h * 0.5
		_view *= exp(-vd * h)
	if id == "" or id == "knife":
		_inaccuracy = 0.0
		_recoil_index = 0.0
		return
	var p: SurfPlayer = main.player
	var rec := stat(id, "recovery time crouch") if p.ducked else stat(id, "recovery time stand")
	var fin := "recovery time crouch final" if p.ducked else "recovery time stand final"
	if _has(id, fin) and _has(id, "recovery transition start bullet") and _has(id, "recovery transition end bullet"):
		var s0 := stat(id, "recovery transition start bullet")
		var s1 := maxf(stat(id, "recovery transition end bullet"), s0 + 1.0)
		rec = lerpf(rec, stat(id, fin), clampf((_recoil_index - s0) / (s1 - s0), 0.0, 1.0))
	var k := exp(-dt * log(1.0 / float(X["recovery_decay_to"])) / maxf(rec, 0.01))
	_inaccuracy *= k
	if t > _last_shot + stat(id, "cycletime") * 1.1:
		_recoil_index *= k
		if _recoil_index < 0.5:
			_recoil_index = 0.0

## The camera: eye angles + view punch + the tracked share of the aim punch.
func _camera() -> void:
	var p: SurfPlayer = main.player
	var shown := _view + _aim * float(X["recoil_scale"]) * float(X["view_recoil_tracking"])
	p.cam.rotation_degrees.x = clampf(p.pitch + shown.x, -89.0, 89.0)
	p.cam.rotation_degrees.y = shown.y

## Cone of the next shot in items_game units (x inaccuracy_to_rad = radians), without the spread ring:
## stand or crouch, plus movement by speed (CS's 34%..95% of the weapon's max speed), plus air, plus firing.
func _inacc(id: String) -> float:
	if id == "knife" or id == "":
		return 0.0
	var p: SurfPlayer = main.player
	var a := mstat(id, "inaccuracy crouch") if p.ducked else mstat(id, "inaccuracy stand")
	var maxspd := maxf(mstat(id, "max player speed"), 1.0)
	var k := clampf(remap(p.speed_units(), maxspd * float(X["move_inacc_start"]), maxspd * float(X["move_inacc_end"]), 0.0, 1.0), 0.0, 1.0)
	a += k * mstat(id, "inaccuracy move")
	if not p.grounded:
		a += mstat(id, "inaccuracy jump")
	return a + _inaccuracy

## Spread + inaccuracy of the held weapon, items_game units (the HUD's dynamic crosshair reads it).
func _spread(id: String) -> float:
	if id == "knife" or id == "":
		return 0.0
	return mstat(id, "spread") + _inacc(id)

## CS2 moves you at the held weapon's max player speed (its alt value while scoped).
func _speed(id: String) -> void:
	var v := mstat(id if id != "" else "knife", "max player speed")
	main.player.M["max_ground_speed"] = v * u

## Scope level 0 (off), 1 or 2: the zoom fov (Source horizontal at 4:3), scoped mouse sensitivity, the lens
## overlay, and the viewmodel and crosshair hidden like CS2.
func _set_zoom(level: int) -> void:
	var p: SurfPlayer = main.player
	if p == null or level == _zoom:
		return
	var id := held()
	if _zoom == 0:
		_base_fov = p.cam.fov
		_base_sens = p.input.sensitivity
	var fov := _base_fov
	if level > 0:
		var zf := stat(id, "zoom fov %d" % level)
		fov = Sheets.vfov_43(zf)
		p.input.sensitivity = _base_sens * float(X["zoom_sensitivity_ratio"]) * zf / float(Sheets.movement()["fov_default"])
	else:
		p.input.sensitivity = _base_sens
	if _fov_tween:
		_fov_tween.kill()
	_fov_tween = create_tween()
	_fov_tween.tween_property(p.cam, "fov", fov, maxf(stat(id, "zoom time 1") if id != "" else 0.05, 0.01))
	_zoom = level
	if main.viewmodel:
		main.viewmodel.visible = level == 0
	if main.hud and main.hud.get("crosshair") is Control:
		(main.hud.crosshair as Control).visible = level == 0
	_scope_layer.visible = level > 0
	_scope.queue_redraw()

func scoped() -> bool:
	return _zoom > 0

## CS2's knife: slash (attack) 40 first / 25 combo / 90 in the back, stab (attack2) 65 / 180 in the back.
## A ray to the knife's reach, then a hull around its end like CS's knife trace; one swing = one shot.
func _knife(stab: bool) -> void:
	var t := _now()
	if t < _next_fire:
		return
	var first := t > _next_fire + float(X["knife_combo"])
	var cam: Camera3D = main.player.cam
	var dir := -_eye_basis().z
	var reach := float(X["knife_stab_range" if stab else "knife_slash_range"]) * u
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + dir * reach)
	q.exclude = [main.player.get_rid()]
	var r: Dictionary = space.intersect_ray(q)
	var col: Object = r.get("collider")
	var at: Vector3 = r.get("position", cam.global_position + dir * reach)
	if col == null or not col.has_method("hit"):
		var hull := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = float(X["knife_hull"]) * u
		hull.shape = sph
		hull.transform = Transform3D(Basis.IDENTITY, cam.global_position + dir * reach)
		hull.exclude = [main.player.get_rid()]
		var best := INF
		for h in space.intersect_shape(hull, 16):
			var c: Object = h["collider"]
			if c and c.has_method("hit") and (c as Node3D).global_position.distance_to(cam.global_position) < best:
				best = (c as Node3D).global_position.distance_to(cam.global_position)
				col = c
				at = (c as Node3D).global_position
	if main.lobby and main.lobby.has_method("on_shot_fired"):
		main.lobby.on_shot_fired()
	main.viewmodel.kick("stab" if stab else "slash")
	if col == null or not col.has_method("hit"):
		_next_fire = t + float(X["knife_stab_miss" if stab else "knife_slash_miss"])
		if r.has("normal"):
			_decal(at, r["normal"])
		return
	var head: bool = col.get_meta("head", false) or col.get("is_head") == true
	var unit: Object = col.get("unit") if col.get("unit") is Object else col
	var back := backstab(unit as Node3D, cam.global_position)
	var dmg: float
	if stab:
		dmg = float(X["knife_stab_back" if back else "knife_stab"])
	else:
		dmg = float(X["knife_slash_back"] if back else (X["knife_slash_first"] if first else X["knife_slash"]))
	col.hit(_armored(unit, dmg, head, "knife"), head, at)
	_next_fire = t + float(X["knife_stab_hit" if stab else "knife_slash_hit"])
	if main.hud.has_method("hitmarker"):
		main.hud.hitmarker(head)

## CS's backstab test: the flat line from the attacker to the target agrees with the target's facing.
func backstab(unit: Node3D, from: Vector3) -> bool:
	if unit == null:
		return false
	var fwd := unit.global_basis.z * float(X["knife_target_forward"])
	var los := unit.global_position - from
	fwd.y = 0.0
	los.y = 0.0
	if fwd.length() < 0.001 or los.length() < 0.001:
		return false
	return los.normalized().dot(fwd.normalized()) > float(X["knife_backstab_dot"])

func _shotgun_shells(id: String) -> bool:
	return rows.has(id) and String(rows[id].get("reload", "magazine")) == "shell"

func reload() -> void:
	var id := held()
	if id == "" or id == "knife" or _reload_until > 0.0 or _shell_next > 0.0 or _now() < _toggle_until:
		return
	var a: Array = ammo[id]
	var full := int(stat(id, "primary clip size"))
	if int(a[0]) >= full or int(a[1]) <= 0:
		return
	_set_zoom(0)
	_rezoom = 0
	_burst_left = 0
	var vm: Viewmodel = main.viewmodel
	vm.play("reload")
	if _shotgun_shells(id):
		_shell_next = _now() + float(X["shell_start"])
		return
	_reload_until = _now() + maxf(vm.clip_length("reload"), 1.0)

func _reload_tick(t: float) -> void:
	var id := held()
	if id == "" or id == "knife":
		return
	if _reload_until > 0.0 and t >= _reload_until:
		_reload_until = 0.0
		var a: Array = ammo[id]
		var take: int = mini(int(stat(id, "primary clip size")) - int(a[0]), int(a[1]))
		a[0] = int(a[0]) + take
		a[1] = int(a[1]) - take
		_hud()
	if _shell_next > 0.0 and t >= _shell_next:
		var a: Array = ammo[id]
		if int(a[1]) > 0 and int(a[0]) < int(stat(id, "primary clip size")):
			a[0] = int(a[0]) + 1
			a[1] = int(a[1]) - 1
		if int(a[1]) <= 0 or int(a[0]) >= int(stat(id, "primary clip size")):
			_shell_next = 0.0
		else:
			_shell_next += float(X["shell_each"])
			var vm: Viewmodel = main.viewmodel
			if vm.current() != "reload":
				vm.play("reload")
		_hud()

## Shots ring out on a pool of players, so a spray never cuts the previous shot off.
func _sound(id: String) -> void:
	if not _sounds.has(id):
		var base: String = main.content.dir.path_join("cs2/" + String(rows[id]["sound_shot"]).get_basename())
		var s: AudioStream = null
		if FileAccess.file_exists(base + ".wav"):
			s = AudioStreamWAV.load_from_file(base + ".wav")
		elif FileAccess.file_exists(base + ".mp3"):
			s = AudioStreamMP3.load_from_file(base + ".mp3")
		_sounds[id] = s
	if _sounds[id] and _voices.size() > 0:
		var p: AudioStreamPlayer = _voices[_voice]
		_voice = (_voice + 1) % _voices.size()
		p.stream = _sounds[id]
		p.play()

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
		main.hud.weapon(String(rows[id]["name"]), int(ammo[id][0]), int(ammo[id][1]), int(stat(id, "primary clip size")))

## B: CS2's buy menu as columns by class; weapons prep has not exported are greyed out.
func _build_buy() -> void:
	_buy = CanvasLayer.new()
	_buy.layer = 5
	_buy.visible = false
	add_child(_buy)
	var center := CenterContainer.new()  # keeps the panel centred at any window size
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_buy.add_child(center)
	var bg := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.106, 0.114, 0.125, 0.92)
	sb.set_content_margin_all(18)
	sb.set_corner_radius_all(4)
	bg.add_theme_stylebox_override("panel", sb)
	center.add_child(bg)
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

## The scope overlay: black outside a round lens with a soft dark rim, thin black cross lines edge to edge.
func _build_scope() -> void:
	_scope_layer = CanvasLayer.new()
	_scope_layer.layer = 1
	_scope_layer.visible = false
	add_child(_scope_layer)
	_scope = Control.new()
	_scope.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scope.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scope_layer.add_child(_scope)
	_scope.draw.connect(_draw_scope)
	_scope.resized.connect(_scope.queue_redraw)

func _draw_scope() -> void:
	var sz := _scope.size
	var c := sz * 0.5
	var r := sz.y * float(X["scope_lens"]) * 0.5
	var w := sz.length()
	_scope.draw_arc(c, r + w * 0.5, 0.0, TAU, 192, Color.BLACK, w, true)
	var rim := sz.y * float(X["scope_edge"])
	for i in 6:
		var k := float(i) / 6.0
		_scope.draw_arc(c, r - rim * k - rim / 12.0, 0.0, TAU, 192, Color(0, 0, 0, 0.16 * (1.0 - k)), rim / 6.0 + 1.0, true)
	var lw := maxf(float(X["scope_line_px"]) * sz.y / 1080.0, 1.0)
	_scope.draw_line(Vector2(0, c.y), Vector2(sz.x, c.y), Color.BLACK, lw, true)
	_scope.draw_line(Vector2(c.x, 0), Vector2(c.x, sz.y), Color.BLACK, lw, true)

## --wpose <id>[:zoom]: holds a weapon for a render without its files (scoped weapons hide the viewmodel).
func _pose(arg: String) -> void:
	var parts := arg.split(":")
	if not rows.has(parts[0]):
		return
	var s: String = SLOT_OF[rows[parts[0]]["slot"]]
	slots[s] = parts[0]
	current = s
	_posed = true
	if parts.size() > 1:
		_set_zoom(int(parts[1]))
	_hud()

## --wtest: the gun model's own checks, printed as WTEST lines next to the lobby hit test.
func _selftest() -> void:
	var p: SurfPlayer = main.player
	var a := pattern("cs2_ak47", 0)
	var b := pattern("cs2_ak47", 0)
	_tables.clear()
	var c := pattern("cs2_ak47", 0)
	print("WTEST pattern ak47 seed=%s len=%d same=%s first=%s" % [str(int(stat("cs2_ak47", "recoil seed"))) if _has("cs2_ak47", "recoil seed") else "hash", a.size(), a == b and a == c, str(a.slice(0, 4))])
	print("WTEST pattern m4a4!=ak47 %s" % (pattern("cs2_m4a4", 0) != a))
	var rs := SourceRandom.new()
	rs.set_seed(1)
	print("WTEST source_random seed1 %d %d %d" % [rs.next(), rs.next(), rs.next()])
	# a 10-shot AK spray at 0.1 s: bullets climb, the camera shows recoil_scale x tracking of it, then it settles
	_aim = Vector2.ZERO
	_aim_vel = Vector2.ZERO
	_view = Vector2.ZERO
	_recoil_index = 0.0
	var climb: Array = []
	for i in 10:
		climb.append("%.1f/%.1f" % [_aim.x * float(X["recoil_scale"]), _aim.y * float(X["recoil_scale"])])
		_recoil("cs2_ak47")
		_last_shot = 1000.0
		for j in 6:
			_decay("cs2_ak47", 1.0 / 60.0, _last_shot)
	for j in 120:
		_decay("cs2_ak47", 1.0 / 60.0, _last_shot)
	print("WTEST spray ak47 bullet pitch/yaw deg=%s rest=%.3f" % [str(climb), _aim.length()])
	# cones: standing still vs after three shots (fallback rifle class when stats are absent)
	_inaccuracy = 0.0
	var still := _spread("cs2_ak47")
	_inaccuracy = mstat("cs2_ak47", "inaccuracy fire") * 3.0
	var fired := _spread("cs2_ak47")
	_inaccuracy = 0.0
	print("WTEST cone ak47 still=%.2f after3=%.2f grounded=%s" % [still, fired, p.grounded])
	# scope: AWP to level 1 and 2 and back, fov and sensitivity restored
	var fov0 := p.cam.fov
	var sens0: float = p.input.sensitivity
	var keep_slot: String = slots["primary"]
	var keep_cur := current
	slots["primary"] = "cs2_awp"
	current = "primary"
	var unscoped := _spread("cs2_awp")
	_attack2("cs2_awp")
	_speed("cs2_awp")
	var s1 := "lvl=%d sens=%.3f mode=%d cone=%.2f (unscoped %.2f) speed=%d" % [_zoom, p.input.sensitivity, _mode("cs2_awp"), _spread("cs2_awp"), unscoped, roundi(float(main.player.M["max_ground_speed"]) / u)]
	_attack2("cs2_awp")
	var s2 := _zoom
	_attack2("cs2_awp")
	_speed("cs2_awp")
	print("WTEST scope awp %s lvl2=%d off=%d fov_back=%s sens_back=%s overlay=%s speed=%d" % [s1, s2, _zoom, is_equal_approx(_base_fov, fov0), is_equal_approx(p.input.sensitivity, sens0), _scope_layer.visible, roundi(float(main.player.M["max_ground_speed"]) / u)])
	print("WTEST alt kinds glock=%s famas=%s m4a1s=%s usp=%s aug=%s nova=%s r8=%s ak=%s" % [alt_kind("cs2_glock"), alt_kind("cs2_famas"), alt_kind("cs2_m4a1_silencer"), alt_kind("cs2_usp_silencer"), alt_kind("cs2_aug"), alt_kind("cs2_nova"), alt_kind("cs2_revolver"), alt_kind("cs2_ak47")])
	print("WTEST silenced at spawn m4a1s=%s usp=%s mode=%d" % [_alt_on["cs2_m4a1_silencer"], _alt_on["cs2_usp_silencer"], _mode("cs2_m4a1_silencer")])
	# burst: one pull of the Glock in burst mode fires burst_shots rounds
	slots["secondary"] = "cs2_glock"
	current = "secondary"
	_alt_on["cs2_glock"] = true
	ammo["cs2_glock"] = [20, 0]
	_next_fire = 0.0
	_shoot("cs2_glock", _now(), false)
	while _burst_left > 0:
		_shoot("cs2_glock", _burst_at, true)
	print("WTEST burst glock rounds=%d" % (20 - int(ammo["cs2_glock"][0])))
	_alt_on["cs2_glock"] = false
	# shotgun: shell by shell, one per shell_each, fire breaks it off
	slots["primary"] = "cs2_nova"
	current = "primary"
	ammo["cs2_nova"] = [2, 10]
	_next_fire = 0.0
	reload()
	var t0 := _now()
	_reload_tick(t0 + float(X["shell_start"]) + 0.001)
	var after1: int = ammo["cs2_nova"][0]
	_reload_tick(_shell_next + 0.001)
	var after2: int = ammo["cs2_nova"][0]
	_shoot("cs2_nova", _now(), false)
	print("WTEST shells nova 2 -> %d -> %d, fire breaks off=%s clip=%d reserve=%d" % [after1, after2, _shell_next == 0.0, ammo["cs2_nova"][0], ammo["cs2_nova"][1]])
	# penetration: two 8-unit walls 1 m apart far below the map, one bullet through both
	var walls: Array = []
	for z in [0.0, -1.0]:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var bx := BoxShape3D.new()
		bx.size = Vector3(4, 4, 8 * u)
		cs.shape = bx
		sb.add_child(cs)
		main.add_child(sb)
		sb.global_position = Vector3(0, -900, z)
		walls.append(sb)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var ex: Array[RID] = [main.player.get_rid()]
	var e1 := _exit(space, walls[0], Vector3(0, -900, 4 * u), Vector3(0, 0, -1), ex)
	var thick := (e1["position"] as Vector3).distance_to(Vector3(0, -900, 4 * u)) / u if not e1.is_empty() else -1.0
	var n0 := _decals.size()
	_trace("cs2_ak47", Vector3(0, -900, 3), Vector3(0, 0, -1), 50.0, stat("cs2_ak47", "damage"), {})
	print("WTEST penetration exit_units=%.1f surfaces_marked=%d" % [thick, _decals.size() - n0])
	for w in walls:
		(w as Node).queue_free()
	# backstab: behind a +Z-facing target vs in front of it
	var dummy := Node3D.new()
	main.add_child(dummy)
	dummy.global_position = Vector3(0, -900, 0)
	print("WTEST backstab behind=%s front=%s" % [backstab(dummy, Vector3(0, -900, -1)), backstab(dummy, Vector3(0, -900, 1))])
	dummy.queue_free()
	slots["primary"] = keep_slot
	slots["secondary"] = _first_ready(["cs2_usp_silencer", "cs2_glock", "cs2_deagle"], "pistol")
	current = keep_cur
	refill()
	_aim = Vector2.ZERO
	_aim_vel = Vector2.ZERO
	_view = Vector2.ZERO
	_recoil_index = 0.0
	_last_shot = -10.0
	_next_fire = 0.0
	_speed(held())
	_hud()

## Just the prefab chain of one items_game entry: its "prefab" parents first, its own attributes on top.
func _ig_chain(name: String, seen: Dictionary) -> Dictionary:
	if seen.has(name) or seen.size() > 16:
		return {}
	seen[name] = true
	var blk := _ig_block(name)
	var out := {}
	for p in String(blk.get("prefab", "")).split(" ", false):
		out.merge(_ig_chain(p, seen), true)
	var at: Variant = blk.get("attributes", {})
	if at is Dictionary:
		for k in at:
			if not (at[k] is Dictionary):
				out[k] = at[k]
	return out

## The block of a key in items_game's prefabs section (the first "key" followed by "{").
func _ig_block(name: String) -> Dictionary:
	if _ig_prefabs < 0:
		return {}
	var needle := "\"" + name + "\""
	var i := _ig.find(needle, _ig_prefabs)
	while i >= 0:
		var j := i + needle.length()
		while j < _ig.length() and " \t\r\n".contains(_ig[j]):
			j += 1
		if j < _ig.length() and _ig[j] == "{":
			return _kv(j)
		i = _ig.find(needle, j)
	return {}

## KeyValues block starting at the "{" at index i: nested dicts, "//" comments and [$PLATFORM] tags skipped.
func _kv(i: int) -> Dictionary:
	var root := {}
	var stack: Array = []
	var cur := root
	var key := ""
	var has_key := false
	var n := _ig.length()
	i += 1
	while i < n:
		var ch := _ig[i]
		if " \t\r\n".contains(ch):
			i += 1
		elif ch == "/" and i + 1 < n and _ig[i + 1] == "/":
			var e := _ig.find("\n", i)
			i = n if e < 0 else e
		elif ch == "[":
			var e := _ig.find("]", i)
			i = n if e < 0 else e + 1
		elif ch == "{":
			var child: Dictionary = cur.get(key, {}) if cur.get(key) is Dictionary else {}
			cur[key] = child
			stack.append(cur)
			cur = child
			has_key = false
			i += 1
		elif ch == "}":
			if stack.is_empty():
				return root
			cur = stack.pop_back()
			has_key = false
			i += 1
		else:
			var tok := ""
			if ch == "\"":
				var e := _ig.find("\"", i + 1)
				if e < 0:
					return root
				tok = _ig.substr(i + 1, e - i - 1)
				i = e + 1
			else:
				var e := i
				while e < n and not " \t\r\n{}\"".contains(_ig[e]):
					e += 1
				tok = _ig.substr(i, e - i)
				i = e
			if not has_key:
				key = tok
				has_key = true
			else:
				cur[key] = tok
				has_key = false
	return root

## Source's uniform random stream (vstdlib random.cpp, Numerical Recipes ran1): a weapon's recoil seed gives
## the same variances on every run and every machine.
class SourceRandom:
	const IA := 16807
	const IM := 2147483647
	const IQ := 127773
	const IR := 2836
	const NTAB := 32
	const NDIV := 1 + 2147483646 / 32
	const AM := 1.0 / 2147483647.0
	const RNMX := 1.0 - 1.2e-7
	var idum := 0
	var iy := 0
	var iv := PackedInt64Array()

	func set_seed(s: int) -> void:
		idum = s if s < 0 else -s
		iy = 0
		iv.resize(NTAB)

	func _step() -> void:
		var k := floori(float(idum) / float(IQ))
		idum = IA * (idum - k * IQ) - IR * k
		if idum < 0:
			idum += IM

	func next() -> int:
		if idum <= 0 or iy == 0:
			idum = 1 if -idum < 1 else -idum
			for j in range(NTAB + 7, -1, -1):
				_step()
				if j < NTAB:
					iv[j] = idum
			iy = iv[0]
		_step()
		var j := floori(float(iy) / float(NDIV))
		if j >= NTAB or j < 0:
			j = (j % NTAB) & 0x7fffffff
		iy = iv[j]
		iv[j] = idum
		return iy

	func rand_float(lo: float, hi: float) -> float:
		var f := AM * float(next())
		return minf(f, RNMX) * (hi - lo) + lo
