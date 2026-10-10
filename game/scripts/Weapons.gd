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
	"inaccuracy jump": "inacc_jump", "inaccuracy jump initial": "inacc_jump", "inaccuracy land": "inacc_land", "inaccuracy fire": "inacc_fire", "recoil angle": "recoil_angle",
	"recoil angle variance": "recoil_angle_var", "recoil magnitude": "recoil_mag", "recoil magnitude variance": "recoil_mag_var",
	"recovery time stand": "recovery_stand", "recovery time crouch": "recovery_crouch", "zoom levels": "zoom_levels",
	"zoom fov 1": "zoom_fov_1", "zoom fov 2": "zoom_fov_2", "zoom time 1": "zoom_time"}
## Keys with an " alt" twin in items_game: the scoped / silenced / burst / fan value.
const ALT_KEYS := ["spread", "inaccuracy stand", "inaccuracy crouch", "inaccuracy move", "inaccuracy jump", "inaccuracy jump initial",
	"inaccuracy land", "inaccuracy fire",
	"recoil angle", "recoil angle variance", "recoil magnitude", "recoil magnitude variance", "cycletime", "max player speed"]

## KeyValues escapes and the platform defines conditionals test (prep/items_game.py reads the file the same way).
const KV_ESC := {"n": "\n", "t": "\t", "\\": "\\", "\"": "\""}
const KV_DEFINES := ["$WIN32", "$WIN64", "$WINDOWS", "$PC"]

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
var _penalty := 0.0      # CS's accuracy penalty, items_game units: the stand / crouch base plus fire, take-off, landing
## The share of the penalty above its base (the fire inaccuracy the HUD's crosshair shows); setting it puts the
## penalty that far above the held weapon's base.
var _inaccuracy: float:
	get:
		return maxf(_penalty - base_inacc(held()), 0.0)
	set(v):
		_penalty = base_inacc(held()) + v
var _recoil_index := 0.0
var _last_shot := -10.0
var _aim := Vector2.ZERO      # aim punch now, degrees (x pitch up, y yaw left), before recoil_scale
var _aim_vel := Vector2.ZERO
var _view := Vector2.ZERO     # camera-only punch now, degrees
var _aim_c := Vector2.ZERO    # the punch state on the last 64-tick (_punch_at); _aim / _aim_vel / _view are it
var _vel_c := Vector2.ZERO    # carried on to the moment being read
var _view_c := Vector2.ZERO
var _kick_vel := Vector2.ZERO # shots since the last tick: their kick lands on the next tick, like CS's tick
var _kick_view := Vector2.ZERO
var _punch := 0.0             # kept for tools that zero it; the punch lives in _aim / _view
var _tables := {}        # "id:mode" -> PackedVector2Array (angle, magnitude) of the seeded pattern
var _alt_on := {}        # id -> true while silencer / burst is on
var _zoom := 0
var _rezoom := 0
var _base_fov := 0.0
var _base_sens := 0.0
var _scoped_sens := -1.0 # the sensitivity a scope level set, -1 unscoped
var _fov_tween: Tween
var _burst_left := 0
var _burst_at := 0.0
var _fan := false
var _cock := -1.0        # R8 primary: when the hammer pull started, -1 when not pulling
var _voices: Array = []
var _voice := 0
var _sounds := {}
var _decals: Array = []
var _buy: CanvasLayer
var _scope: Control
var _scope_layer: CanvasLayer
var _rng := RandomNumberGenerator.new()
var _pellet_tabs := {}   # id -> PackedVector2Array (angle, radius share) of its fixed shotgun pattern
var _recharge := {}      # id -> when an empty Zeus has its charge back
var _part_at := -1.0     # when the silencer mesh shows or hides mid-toggle, -1 when nothing is pending
var _part_id := ""
var _dry_at := 0.0       # next dry-fire click of a held empty trigger
var problems: PackedStringArray = []  # exported guns missing a stats_required value (running on class averages)
var thin := {}           # id -> the stats_required keys its stats lack
var _paused_total := 0.0 # wall seconds the weapons clock has stood still
var _pause_from := -1.0  # wall time the clock stopped at, -1 while it runs
var _tick_at := -1.0     # weapons-clock time of the last frame
var _punch_at := 0.0     # weapons-clock time of the last punch tick (the committed state's time)
var _shoot_clip := 0     # which of the shoot_clips the next shot plays
var _alt_wait := false   # attack2 pressed while the gun was busy: it acts once ready if still held
var _shot_log: Variant = null  # --wtest: an Array that records each shot's aim punch x recoil_scale
var _inacc_log: Variant = null # --wtest: an Array that records each shot's cone (items_game units) as it flew
var _decay_at := -1.0    # weapons-clock time the fire inaccuracy and recoil index were last recovered to
var _burst_pull := 0.0   # when the burst under way was pulled
var _zoom_full_at := 0.0 # weapons-clock time the scope in progress is fully zoomed (CS's m_zoomFullyActiveTime)

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
	_stats_check()
	for i in int(X["shot_voices"]):
		var p := AudioStreamPlayer.new()
		p.volume_db = float(X["shot_volume_db"])
		add_child(p)
		_voices.append(p)
	slots["primary"] = _first_ready(["cs2_ak47", "cs2_m4a1_silencer", "cs2_m4a4"], "rifle")
	slots["secondary"] = _first_ready(["cs2_usp_silencer", "cs2_glock", "cs2_deagle"], "pistol")
	for id in rows:
		_alt_on[id] = alt_kind(id) == "silencer"  # CS2 hands out the M4A1-S and USP-S silenced
	if main.player and main.player.has_signal("landed"):
		main.player.landed.connect(_on_land)
	if main.player and main.player.has_signal("jumped"):
		main.player.jumped.connect(_on_jump)
	var cv: Variant = main.hud.get("convars") if main.hud else null
	if cv is Dictionary and str(cv.get("zoom_sensitivity_ratio", "")).is_valid_float():
		X["zoom_sensitivity_ratio"] = float(cv["zoom_sensitivity_ratio"])  # the player's own CS2 convar
	_walk_bind()
	refill()
	_punch_reset(_now())
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

## Every attribute of one weapon: its items_game entry the way prep's items_game.stats reads it (any key), then
## prep's weapon_stats.json on top.
func _resolve(id: String) -> void:
	var out := {}
	var item := String(rows[id]["item"])
	if _ig != "":
		var raw := ig_stats(item)
		for k in raw:
			if String(raw[k]).is_valid_float():
				out[k] = float(raw[k])
	var s: Dictionary = stats.get(item, {})
	for k in s:
		if String(s[k]).is_valid_float():
			out[k] = float(s[k])
	_st[id] = out

## prep only warns about a gun missing a stats_required value (prep.json stats_required_blocks "no"), so the
## data folder can hold one: each exported gun missing any is named in problems (Main shows them) instead of
## silently playing on class averages. The wording matches prep's warning: setup again cannot fix it.
func _stats_check() -> void:
	var P := Sheets.values("prep")
	var light := String(P.get("stats_light_slots", "")).split(",", false)
	var names: PackedStringArray = []
	for id in ready_ids:
		var need := String(P.get("stats_required_light" if light.has(String(rows[id]["slot"])) else "stats_required", "")).split(",", false)
		var miss: PackedStringArray = []
		for k in need:
			if not _has(id, k.strip_edges()):
				miss.append(k.strip_edges())
		if miss.size() > 0:
			thin[id] = miss
			names.append("%s (%s)" % [rows[id]["name"], ", ".join(miss)])
	if names.size() > 0:
		problems.append("%d gun(s) lack CS2 stats and use class averages: %s. Rust Surf needs an update for this CS2 version; setup again will not fix it." % [names.size(), "; ".join(names.slice(0, 3)) + (" and more" if names.size() > 3 else "")])
		push_warning("weapons: " + problems[0])

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
	if _zoom > 0 and id == held() and not zoom_ready() and (key == "spread" or key.begins_with("inaccuracy")):
		return stat(id, key)  # a scope still easing in shoots with the unscoped cone
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
	_recharge.clear()
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
	var was_held := held()
	if current == s:
		current = ""  # same slot: force the redraw
	_alt_on[id] = alt_kind(id) == "silencer"  # a bought gun comes in its CS2 stock mode: M4A1-S / USP-S silenced, burst off
	if not switch_to(s, was_held):
		slots[s] = prev
		current = was
		return
	ammo[id] = [int(stat(id, "primary clip size")), int(stat(id, "primary reserve ammo max"))]
	if main.get("shots_running") == true:
		main.viewmodel.settle()  # a Gauntlet capture shows the gun at rest, never mid-draw at a fast frame rate
		_next_fire = _now()
	_hud()

func switch_to(s: String, from: String = "") -> bool:
	if s == current or slots.get(s, "") == "":
		return false
	var was := from if from != "" else held()
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
		_message("can't draw %s: %s" % [id, vm.why], 2.0)
		return false
	_set_zoom(0)
	_rezoom = 0
	_burst_left = 0
	_fan = false
	_holster(was)
	if current != "":
		last = current
	current = s
	_xhair()
	_deploy_reset()
	_silencer_part(id, 0.0)
	_next_fire = _now() + maxf(vm.clip_length("draw"), float(X["draw_min"]))
	_hud()
	return true

## CS's Holster: a silencer turn still under way when the gun is put away is undone, so the gun comes back in
## the mode it was in before the press (its can, its sound and its stats), and the half-way mesh swap is dropped.
func _holster(id: String) -> void:
	if id == "" or alt_kind(id) != "silencer" or _now() >= _toggle_until:
		return
	_alt_on[id] = not _alt_on.get(id, false)
	_toggle_until = 0.0
	_part_at = -1.0

## CS's Deploy: a drawn weapon starts with no fire inaccuracy, a fresh recoil index and no reload or toggle.
func _deploy_reset() -> void:
	_penalty = 0.0
	_recoil_index = 0.0
	_reload_until = 0.0
	_shell_next = 0.0
	_toggle_until = 0.0
	_cock = -1.0
	_shoot_clip = 0

## The weapons clock, seconds: wall time (shots keep their exact cycletime between frames, like CS2's sub-tick
## input) that stands still while the trigger is blocked (Esc menu, buy menu, a frozen player), so a pause never
## finishes a draw, reload, shell, bolt, silencer turn or Zeus charge for free.
func _now() -> float:
	var w := Time.get_ticks_usec() / 1000000.0
	return w - _paused_total - (w - _pause_from if _pause_from >= 0.0 else 0.0)

func _hold_clock(stop: bool) -> void:
	var w := Time.get_ticks_usec() / 1000000.0
	if stop and _pause_from < 0.0:
		_pause_from = w
	elif not stop and _pause_from >= 0.0:
		_paused_total += w - _pause_from
		_pause_from = -1.0

func _blocked() -> bool:
	return (main.settings and main.settings.is_open) or (_buy and _buy.visible) or main.player == null or main.player.frozen

func _process(dt: float) -> void:
	if main == null or main.player == null:
		return
	_hold_clock(_blocked())
	var t := _now()
	var gdt := clampf(t - _tick_at, 0.0, maxf(dt, 0.0)) if _tick_at >= 0.0 else 0.0
	_tick_at = t
	_tick(held(), t, gdt)
	_decay_to(held(), t)  # after the frame's rounds: each of them recovered only up to its own slot time
	_punch_to(t)  # the rounds of this frame read the punch at their own slot times; the camera reads it now
	_camera()

func _tick(id: String, t: float, dt: float) -> void:
	if main.viewmodel and main.viewmodel.has_method("move"):
		main.viewmodel.move(main.player.speed_units() if main.player.grounded else 0.0, Vector2(main.player.pitch, main.player.yaw), dt)
	if Input.is_action_just_pressed("surf_buymenu") and not (main.settings and main.settings.is_open):
		_buy.visible = not _buy.visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _buy.visible else Input.MOUSE_MODE_CAPTURED
	_speed(id)
	_recharge_tick(t)
	_sens_follow()
	if _blocked():  # the scope stays on under a menu: the player comes back scoped
		_burst_left = 0
		_alt_wait = false
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
	_part_tick(t)
	_auto_reload(held(), t)
	while _burst_left > 0 and t >= _burst_at:
		_shoot(held(), _burst_at, true)  # each round on its slot, not the frame's time
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
		_alt_wait = not _attack2(id)
	elif _alt_wait:
		_alt_wait = Input.is_action_pressed("surf_attack2") and not _attack2(id)  # CS reads attack2 held: it acts once the gun is ready
	_fan = alt_kind(id) == "revolver" and Input.is_action_pressed("surf_attack2") and not Input.is_action_pressed("surf_attack")
	if alt_kind(id) == "revolver" and not _fan:
		if hammer(Input.is_action_pressed("surf_attack"), t):
			fire()
		return
	var auto := stat(id, "is full auto") > 0.5
	if Input.is_action_just_pressed("surf_attack"):
		fire()
	elif (auto and Input.is_action_pressed("surf_attack")) or _fan:
		hold_fire(id, t, dt)

## A held automatic trigger: every round whose slot fell inside this frame goes off at its own slot time (up to
## fire_catchup_max a frame), so a long frame or a hitch never lowers the rate of fire, like CS2's sub-tick
## input. A slot older than the frame starts a fresh cycle now. Returns the rounds fired.
func hold_fire(id: String, t: float, dt: float) -> int:
	var n := 0
	while n < int(X["fire_catchup_max"]) and held() == id and t >= _next_fire:
		var before := _next_fire
		_shoot(id, _next_fire if t - _next_fire <= dt + 0.0005 else t, false)
		if _next_fire == before:
			break  # it did not fire (empty, reloading, a toggle)
		n += 1
	return n

## R8 primary: holding attack pulls the hammer once the gun is ready and the round goes off revolver_cock
## seconds later; letting go first cancels it. Held on, it pulls again after each shot. True when it fires.
func hammer(held_down: bool, t: float) -> bool:
	if not held_down or t < _next_fire or _reload_until > 0.0 or t < _toggle_until:
		_cock = -1.0
		return false
	if _cock < 0.0:
		_cock = t
	if t - _cock < float(X["revolver_cock"]):
		return false
	_cock = -1.0
	return true

## attack2 on a gun: scope level, silencer on/off, burst/semi, or (revolver) fan fire while held. Like CS's
## m_flNextSecondaryAttack (set with every shot, draw and toggle) it waits for the gun: false when refused
## because the gun is busy (a draw, a bolt or shot cycle, a reload or shell load, a silencer turn, a burst).
func _attack2(id: String) -> bool:
	var kind := alt_kind(id)
	if kind in ["scope", "silencer", "burst"] and not alt_ready():
		return false
	match kind:
		"scope":
			_rezoom = 0
			_set_zoom((_zoom + 1) % (_zoom_levels(id) + 1))
		"silencer":
			_alt_on[id] = not _alt_on.get(id, false)
			var vm: Viewmodel = main.viewmodel
			var clip := "silencer_on" if _alt_on[id] else "silencer_off"
			var dur := float(X["silencer_time"])
			if vm.play(clip):
				dur = vm.clip_length(clip)
			else:
				vm.kick("silencer", dur)  # no clip exported: the gun tips and the can turns for silencer_time
			_toggle_until = _now() + dur
			_next_fire = maxf(_next_fire, _toggle_until)
			_silencer_part(id, dur * 0.5)
			_message("Silencer " + ("attached" if _alt_on[id] else "detached"), 1.5)
		"burst":
			_alt_on[id] = not _alt_on.get(id, false)
			var msg: Array = X["burst_messages"]  # burst, full-auto base (FAMAS), semi-auto base (Glock)
			_message(String(msg[0] if _alt_on[id] else (msg[1] if stat(id, "is full auto") > 0.5 else msg[2])), 1.5)
	_hud()
	return true

## The secondary attack is ready: no reload, shell load or burst under way and the next shot is due.
func alt_ready() -> bool:
	return _reload_until == 0.0 and _shell_next == 0.0 and _burst_left == 0 and _now() >= maxf(_next_fire, _toggle_until)

func _message(text: String, secs: float) -> void:
	if main.hud and main.hud.has_method("message"):
		main.hud.message(text, secs)

## The silencer mesh follows the toggle halfway through it (when the can comes off or goes on); delay 0 now.
func _silencer_part(id: String, delay: float) -> void:
	if alt_kind(id) != "silencer":
		_part_at = -1.0
		return
	_part_at = _now() + delay
	_part_id = id
	if delay <= 0.0:
		_part_tick(_part_at)

func _part_tick(t: float) -> void:
	if _part_at < 0.0 or t < _part_at:
		return
	_part_at = -1.0
	if _part_id == held() and main.viewmodel:
		main.viewmodel.set_parts(String(X["silencer_mesh_match"]).split(","), bool(_alt_on.get(_part_id, false)))

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
		if not from_burst:
			_dry(id, t)
		return
	var cyc := mstat(id, "cycletime")
	if alt_kind(id) == "burst" and _alt_on.get(id, false):
		if from_burst:
			_burst_left -= 1
		else:
			_burst_left = int(X["burst_shots"]) - 1
			_burst_pull = t
		_burst_at = t + float(X["burst_gap"])
		if not from_burst or _burst_left <= 0:
			_next_fire = burst_next(t, _burst_pull, _burst_left, stat(id, "cycletime alt") if _has(id, "cycletime alt") else float(X["burst_cooldown"]))
	else:
		_burst_left = 0
		_next_fire = cadence(_next_fire, t, cyc, get_process_delta_time())
	a[0] = int(a[0]) - 1
	if int(a[0]) <= 0 and int(a[1]) <= 0 and rows.has(id) and rows[id]["slot"] == "gear":
		_recharge[id] = t + float(X["taser_recharge"])
	# a catch-up round recovers up to its own slot time first (the rest since the previous round included), so a long
	# frame does not stack the penalty, then flies on the punch of its own slot time
	_decay_to(id, t)
	_punch_to(t)
	_last_shot = t
	_shoot_anim(main.viewmodel)
	_sound(id)
	if main.lobby and main.lobby.has_method("on_shot_fired"):
		main.lobby.on_shot_fired()  # one trigger pull = one shot, pellets and penetration included
	var cam: Camera3D = main.player.cam
	var eye := _eye_basis()
	if _shot_log is Array:
		(_shot_log as Array).append(_aim * float(X["recoil_scale"]))
	if _inacc_log is Array:
		(_inacc_log as Array).append(_inacc(id))
	var inacc := _inacc(id) * float(X["inaccuracy_to_rad"])
	var spr := mstat(id, "spread") * float(X["inaccuracy_to_rad"])
	var reach := stat(id, "range") * u
	var hits: Array = []  # [part, damage, head, point] per pellet per body, in firing order
	# CS FX_FireBullets: one inaccuracy ring for the whole shot, then a spread ring per pellet; each ring is a
	# random angle and a uniform (centre-weighted) radius
	var squares := outer_squarings(id)
	var t0 := _rng.randf() * TAU
	var r0 := ring_share(_rng.randf(), squares) * inacc
	var n := int(stat(id, "bullets"))
	var fixed := pellets(id) if n > 1 and float(X["shotgun_spread_patterns"]) > 0.0 else PackedVector2Array()
	for i in n:
		var t1 := _rng.randf() * TAU
		var r1 := ring_share(_rng.randf(), squares) * spr
		if i < fixed.size():
			t1 = fixed[i].x  # CS2 shotguns: the same pellet pattern every blast, moved by the inaccuracy ring
			r1 = fixed[i].y * spr
		var off := Vector2(cos(t0) * r0 + cos(t1) * r1, sin(t0) * r0 + sin(t1) * r1)
		var dir := (-eye.z + eye.x * off.x + eye.y * off.y).normalized()
		_trace(id, cam.global_position, dir, reach, stat(id, "damage"), hits)
	var head_any := _deliver(hits)
	if hits.size() > 0 and main.hud and main.hud.has_method("hitmarker"):
		main.hud.hitmarker(head_any)
	_penalty = maxf(_penalty, base_inacc(id)) + mstat(id, "inaccuracy fire")
	_recoil(id)
	if _zoom > 0 and unzoom_after_shot(id):
		var z := _zoom
		_set_zoom(0)
		_rezoom = z  # bolt action: out of the scope for the bolt, back in when ready
	if int(a[0]) <= 0:
		_burst_left = 0
	_hud()

## A bolt gun leaves the scope for each shot: items_game's unzoom_key attribute when it has one, else a
## cycletime of bolt_cycletime or more.
func unzoom_after_shot(id: String) -> bool:
	var k := String(X["unzoom_key"])
	return stat(id, k) > 0.5 if _has(id, k) else stat(id, "cycletime") >= float(X["bolt_cycletime"])

## The next pull of a burst gun, from a round fired at t of a burst pulled at pull with left rounds still to come:
## burst_from_pull on (CS:GO's CSBaseGunFire sets the next attack at the pull) the cooldown runs from the pull,
## off from the burst's last round; never before the last round's own slot plus one burst_gap.
func burst_next(t: float, pull: float, left: int, cool: float) -> float:
	var gap := float(X["burst_gap"])
	var last_round := t + gap * float(left)
	var from := pull if float(X["burst_from_pull"]) > 0.0 else last_round
	return maxf(from + cool, last_round + gap)

## The shot clip: CS2 plays its shoot clips in turn; the ones this weapon exported cycle (shoot1 alone when that
## is all there is), else the rig's procedural kick.
func _shoot_anim(vm: Viewmodel) -> void:
	if vm == null:
		return
	var have: Array = []
	for c in String(X["shoot_clips"]).split(",", false):
		if vm.has_clip(c.strip_edges()):
			have.append(c.strip_edges())
	if have.is_empty():
		vm.kick("shot")
		return
	vm.play(String(have[_shoot_clip % have.size()]))  # a draw starts the turn again at shoot1
	_shoot_clip = (_shoot_clip + 1) % have.size()

## How many times FX_FireBullets squares a ring's random radius share before taking 1 - share (pushing the round
## out towards the ring's edge): once for the R8's fan fire, and for the Negev's first shots one more time per
## shot short of outer_ring_first_shots; 0 for a plain centre-weighted ring.
func outer_squarings(id: String) -> int:
	if not rows.has(id):
		return 0
	var item := String(rows[id]["item"])
	if _fan and String(X["outer_ring_alt_items"]).split(",", false).has(item):
		return 1
	var first := float(X["outer_ring_first_shots"])
	if String(X["outer_ring_first_items"]).split(",", false).has(item) and _recoil_index < first:
		return int(first) - floori(_recoil_index)
	return 0

static func ring_share(r: float, squares: int) -> float:
	if squares <= 0:
		return r
	for i in squares:
		r *= r
	return 1.0 - r

## A pull on an empty gun: with auto_reload the gun clicks (one twitch per dry_fire_delay) and reloads once the
## trigger is let go, like CS; without it the pull reloads.
func _dry(id: String, t: float) -> void:
	if float(X["auto_reload"]) <= 0.0:
		reload()
		return
	if t >= _dry_at:
		_dry_at = t + float(X["dry_fire_delay"])
		main.viewmodel.kick("dry")

## CS's auto-reload: an empty gun with reserve reloads on the first frame no attack button is held.
func _auto_reload(id: String, t: float) -> void:
	if id == "" or id == "knife" or float(X["auto_reload"]) <= 0.0 or not ammo.has(id):
		return
	if Input.is_action_pressed("surf_attack") or Input.is_action_pressed("surf_attack2"):
		return
	if int(ammo[id][0]) <= 0 and int(ammo[id][1]) > 0 and t >= maxf(_next_fire, _toggle_until):
		reload()

## Inspect is refused mid reload, shell load, silencer turn, scope or shot cycle (Main asks before inspecting).
func can_inspect() -> bool:
	var id := held()
	if id == "knife":
		return _now() >= _next_fire
	return _reload_until == 0.0 and _shell_next == 0.0 and _zoom == 0 and _now() >= maxf(_next_fire, _toggle_until) and _burst_left == 0

## The next allowed shot. A shot later than its slot by less than one frame keeps the slot (held fire stays
## on the exact cycletime instead of drifting a frame per shot); any later shot starts a new cycle, so
## clicking can never beat the cycletime by more than a frame (and never by more than half a cycle).
static func cadence(next: float, t: float, cyc: float, frame: float) -> float:
	return next + cyc if t - next < minf(frame, cyc * 0.5) else t + cyc

## Eye angles plus aim punch x recoil_scale: where CS2 sends the bullets (the camera shows less of it).
func _eye_basis() -> Basis:
	var p: SurfPlayer = main.player
	var k := float(X["recoil_scale"])
	var pitch := deg_to_rad(clampf(p.pitch + _aim.x * k, -89.0, 89.0))
	return p.global_basis * Basis.from_euler(Vector3(pitch, deg_to_rad(_aim.y * k), 0.0))

## Each pellet's hit lands on the part it struck, like CS's one TakeDamage per bullet: the target applies that
## part's hitgroup, so a blast across legs, chest and head scales every pellet by its own group. True when
## any pellet was a headshot.
func _deliver(hits: Array) -> bool:
	var head_any := false
	for e in hits:
		if is_instance_valid(e[0]):
			(e[0] as Object).hit(float(e[1]), bool(e[2]), e[3])
			head_any = head_any or bool(e[2])
	return head_any

## One bullet: hits along the ray, through up to pen_hits surfaces (one hit per target per bullet). Damage
## falls off with range and loses CS's penetration toll per surface (a chunk, a weapon term and thickness
## squared over 24).
func _trace(id: String, from: Vector3, dir: Vector3, reach: float, dmg: float, hits: Array) -> void:
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var ex: Array[RID] = [main.player.get_rid()]
	var start := from
	var travelled_from := from  # range falloff counts every unit flown, the ones inside walls too
	var flown := 0.0            # units flown so far (falloff_cumulative: CS's flCurrentDistance)
	var cum := float(X["falloff_cumulative"]) > 0.0
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
		var col: Object = r["collider"]
		var body := col != null and col.has_method("hit")
		var key: Object = (col.get("unit") if col.get("unit") is Object else col) if body else null  # a bot's parts are one target
		if body and seen.has(key):
			# CS ignores a player it has hit for the rest of the trace: a further part of the same bot is no stop at
			# all (no falloff step, no toll, no penetration), the bullet just passes it
			ex.append(r["rid"])
			start = pos
			continue
		var seg := travelled_from.distance_to(pos) / u
		flown += seg
		dmg *= pow(rm, (flown if cum else seg) / 500.0)
		travelled_from = pos
		if body:
			var head: bool = col.get_meta("head", false) or col.get("is_head") == true
			seen[key] = true
			var d := dmg * (stat(id, "headshot multiplier") if head else 1.0)
			hits.append([col, _armored(key, d, _group(col, head), id), head, pos])
		else:
			_decal(pos, r["normal"])
		if power <= 0.0:
			return
		var exit := _exit(space, col, pos, dir, ex)
		if exit.is_empty():
			return
		var thick: float = pos.distance_to(exit["position"]) / u
		var pm := 1.0 / maxf(pen_mod(col, body), 0.01)
		dmg -= dmg * float(X["pen_chunk"]) + maxf(0.0, 3.0 / power * 1.25) * pm * 3.0 + pm * thick * thick / 24.0
		if not body:
			_decal(exit["position"], exit["normal"])
		start = exit["position"] + dir * 0.002
		travelled_from = exit["position"]
		flown += thick  # the flight through the wall
		if not cum:
			dmg *= pow(rm, thick / 500.0)
		left -= 1

## A surface's CS penetration modifier (its surfaceproperties value; CS averages the entry and exit surfaces,
## one object here): a "pen_mod" meta on the collider when a scene sets one (wood, metal, glass), else
## pen_mod_body for a body and pen_mod_world for the rest of the world.
func pen_mod(col: Object, body: bool) -> float:
	if col != null and col.has_meta("pen_mod"):
		return float(col.get_meta("pen_mod"))
	return float(X["pen_mod_body"] if body else X["pen_mod_world"])

## One plain ray along the camera inside a cone of spread_mrad (tools aim with it; firing uses _trace).
func _shoot_ray(cam: Camera3D, reach: float, spread_mrad: float) -> Dictionary:
	var ang := _rng.randf() * TAU
	var r := spread_mrad * 0.001 * _rng.randf()
	var dir := (-cam.global_basis.z + (cam.global_basis.x * cos(ang) + cam.global_basis.y * sin(ang)) * r).normalized()
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + dir * reach)
	q.exclude = [main.player.get_rid()]
	return cam.get_world_3d().direct_space_state.intersect_ray(q)

## The far face of what the bullet entered: walk out in pen_step_units steps and look back. Something else met
## on the way back (an overlapping part of the same bot, a body touching the wall) lies past the exit: it is
## skipped and the look back repeats, so the exit found is always the entered object's own far face (the main
## trace then meets the other thing next). Nothing within pen_max_units means the bullet stops here.
func _exit(space: PhysicsDirectSpaceState3D, col: Object, pos: Vector3, dir: Vector3, ex: Array[RID]) -> Dictionary:
	var step := float(X["pen_step_units"]) * u
	var d := step
	var skip: Array[RID] = ex.duplicate()
	while d <= float(X["pen_max_units"]) * u:
		for i in int(X["pen_exit_skips"]) + 1:
			var q := PhysicsRayQueryParameters3D.create(pos + dir * d, pos + dir * 0.001)
			q.exclude = skip
			q.hit_back_faces = false
			var r: Dictionary = space.intersect_ray(q)
			if r.is_empty():
				break
			if r["collider"] == col:
				return r
			skip.append(r["rid"])
		d += step
	return {}

## A struck part's hitgroup: "head" for a head, else its group property (chest when it has none).
func _group(col: Object, head: bool) -> String:
	if head:
		return "head"
	return String(col.get("group")) if col.get("group") is String else "chest"

## CS armor on a target that carries an armor value (the aim lobby armours its bots itself, after its
## hitgroup scale): an armored hitgroup takes armor ratio x armor_ratio_scale of the damage to health and
## the armor pays armor_bonus of the rest. The legs are never armored, the head only with a helmet.
func _armored(key: Object, d: float, group: String, id: String) -> float:
	var armor: Variant = key.get("armor")
	if not (armor is float or armor is int) or float(armor) <= 0.0 or group == "legs" or (group == "head" and key.get("helmet") != true):
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
	var rs := SourceRandom.new()
	rs.set_seed(_seed(id))
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

## The (angle, suppressed magnitude) of the held mode's pattern at a fractional recoil index: like CS's
## GetRecoilOffsets it blends the two table entries around the index, and the suppression ramp reads the
## fractional index too, so a spray resumed after a partial recovery kicks in between two shots' values.
func kick_at(id: String, index: float) -> Vector2:
	var tab := pattern(id, _mode(id))
	var f := clampf(index, 0.0, float(tab.size() - 1))
	var i := int(f)
	var e := tab[i].lerp(tab[mini(i + 1, tab.size() - 1)], f - float(i))
	var shots := maxf(float(X["recoil_suppression_shots"]), 1.0)
	return Vector2(e.x, e.y * lerpf(float(X["recoil_suppression_factor"]), 1.0, clampf(f / shots, 0.0, 1.0)))

func _alt_or(id: String, key: String, sfx: String) -> float:
	return stat(id, key + sfx) if sfx != "" and _has(id, key + sfx) else stat(id, key)

## One shot's kick: the pattern at the recoil index pushes the aim punch velocity; the camera gets a little
## extra view punch of its own. The first shots of a spray are suppressed.
func _recoil(id: String) -> void:
	var e := kick_at(id, _recoil_index)
	var mag := e.y
	var r := deg_to_rad(e.x)
	var kick := Vector2(cos(r), -sin(r)) * mag  # angle 0 kicks straight up, positive angles to the right
	_kick_vel += kick
	_kick_view += kick * float(X["view_punch_extra"])  # the camera's extra shake follows the same kick
	_recoil_index += 1.0

## The punch at weapons-clock time t (never back): CS's DecayAimPunchAngle runs on a fixed punch_tick grid
## (each tick first decays, then takes the kicks of the shots fired since the last one), and _aim / _aim_vel /
## _view show that state carried on to t inside the current tick. Every shot calls it with its own slot time
## before it reads the punch, and each frame ends with it at the frame's time, so a spray goes the same way at
## any frame rate: only the shot times and the tick grid decide it.
func _punch_to(t: float) -> void:
	var tick := float(X["punch_tick"])
	while _punch_at + tick <= t:
		var st := punch_step(_aim_c, _vel_c, _view_c, tick)
		_aim_c = st[0]
		_vel_c = st[1] + _kick_vel
		_view_c = st[2] + _kick_view
		_kick_vel = Vector2.ZERO
		_kick_view = Vector2.ZERO
		_punch_at += tick
	var now := punch_step(_aim_c, _vel_c, _view_c, maxf(t - _punch_at, 0.0))
	_aim = now[0]
	_aim_vel = now[1]
	_view = now[2]

## Clears the punch, its pending kicks and its clock (a test's fresh start).
func _punch_reset(t: float) -> void:
	_aim_c = Vector2.ZERO
	_vel_c = Vector2.ZERO
	_view_c = Vector2.ZERO
	_kick_vel = Vector2.ZERO
	_kick_view = Vector2.ZERO
	_aim = Vector2.ZERO
	_aim_vel = Vector2.ZERO
	_view = Vector2.ZERO
	_punch_at = t

## CS's DecayAimPunchAngle over h seconds (at most one tick): the aim punch shrinks exponentially, then
## linearly, then follows its velocity in two half steps around the velocity's own decay; the view punch
## decays on its own. Returns [aim, velocity, view].
func punch_step(aim: Vector2, vel: Vector2, view: Vector2, h: float) -> Array:
	if h <= 0.0:
		return [aim, vel, view]
	aim *= exp(-float(X["recoil_decay_exp"]) * h)
	var l := aim.length()
	if l > 0.0:
		aim *= maxf(l - float(X["recoil_decay_lin"]) * h, 0.0) / l
	aim += vel * h * 0.5
	vel *= exp(-float(X["recoil_vel_decay"]) * h)
	aim += vel * h * 0.5
	return [aim, vel, view * exp(-float(X["view_punch_decay"]) * h)]

## Recovery from the last recovered moment up to weapons-clock time t (never back): each frame calls it at the
## frame's time and every round at its own slot time first, so the rounds a long frame fires in a row each
## recover from the one before like at any frame rate.
func _decay_to(id: String, t: float) -> void:
	if _decay_at < 0.0 or t < _decay_at:
		_decay_at = maxf(_decay_at, t)
		return
	_decay(id, t - _decay_at, t)
	_decay_at = t

## CS's UpdateAccuracyPenalty: the accuracy penalty holds the stand or crouch base cone too. A higher base
## (standing up, unscoping) lifts it at once; above the base it falls back to it by recovery_decay_to over the
## recovery time, so crouching or scoping tightens the cone over that time and a shot's penalty fades the same
## way. The recoil index eases back once the trigger has rested recoil_index_rest_cycles cycles (the punch
## decays in _punch_to).
func _decay(id: String, dt: float, t: float) -> void:
	if id == "" or id == "knife":
		_penalty = 0.0
		_recoil_index = 0.0
		return
	var p: SurfPlayer = main.player
	var base := base_inacc(id)
	var rec := stat(id, "recovery time crouch") if p.ducked else stat(id, "recovery time stand")
	var fin := "recovery time crouch final" if p.ducked else "recovery time stand final"
	if _has(id, fin) and _has(id, "recovery transition start bullet") and _has(id, "recovery transition end bullet"):
		var s0 := stat(id, "recovery transition start bullet")
		var s1 := maxf(stat(id, "recovery transition end bullet"), s0 + 1.0)
		rec = lerpf(rec, stat(id, fin), clampf((_recoil_index - s0) / (s1 - s0), 0.0, 1.0))
	var rate := log(1.0 / float(X["recovery_decay_to"])) / maxf(rec, 0.01)
	_penalty = base if _penalty <= base else base + (_penalty - base) * exp(-dt * rate)
	# the recoil index eases back only over the part of dt after the trigger has rested past the threshold
	var rest := minf(dt, t - (_last_shot + mstat(id, "cycletime") * float(X["recoil_index_rest_cycles"])))
	if rest > 0.0:
		_recoil_index *= exp(-rest * rate * float(X["recoil_index_decay_scale"]))
		if _recoil_index < float(X["recoil_index_snap"]):
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
	var a := maxf(_penalty, base_inacc(id))  # the accuracy penalty, never under the base it is lifted to
	var maxspd := maxf(mstat(id, "max player speed"), 1.0)
	a += move_share(p.speed_units(), maxspd, walking()) * mstat(id, "inaccuracy move")
	if not p.grounded:
		a += air_inacc(_jump_inacc(id), absf(p.velocity.y) / u)
	return a

## The base of the accuracy penalty now: the crouch cone while ducked, else the stand cone (the held mode's).
func base_inacc(id: String) -> float:
	if id == "knife" or id == "" or main == null or main.player == null or not rows.has(id):
		return 0.0
	var p: SurfPlayer = main.player
	var crouch: bool = p.ducked and (p.grounded or float(X["air_crouch_cone"]) > 0.0)
	return mstat(id, "inaccuracy crouch") if crouch else mstat(id, "inaccuracy stand")

## CS2's walk (+speed, held): a grounded player holding walk_action moves at walk_speed_scale of the weapon's
## speed and gets the linear movement cone.
func walking() -> bool:
	var act := String(X["walk_action"])
	return InputMap.has_action(act) and Input.is_action_pressed(act) and main.player != null and main.player.grounded

## walk_action from input.json when it binds one, else walk_key (CS2's default +speed key) added here.
func _walk_bind() -> void:
	var act := String(X["walk_action"])
	if InputMap.has_action(act):
		return
	InputMap.add_action(act)
	var ev := InputEventKey.new()
	ev.physical_keycode = OS.find_keycode_from_string(String(X["walk_key"]))
	InputMap.action_add_event(act, ev)

## CS's movement share of the move cone: speed remapped over move_inacc_start..end of the max speed, raised to
## move_inacc_power unless walking (a run is nearly fully inaccurate well before top speed).
func move_share(speed: float, maxspd: float, walking: bool) -> float:
	var k := clampf(remap(speed, maxspd * float(X["move_inacc_start"]), maxspd * float(X["move_inacc_end"]), 0.0, 1.0), 0.0, 1.0)
	return k if walking or k <= 0.0 else pow(k, float(X["move_inacc_power"]))

## The airborne term's base: items_game's "inaccuracy jump initial" (CS's take-off penalty) x air_spread_scale
## (CS's weapon_air_spread_scale), else the class inacc_jump column. Its "inaccuracy jump" is not used here: in
## the CS:GO scripts that key is a small speed factor, not the take-off cone.
func _jump_inacc(id: String) -> float:
	return mstat(id, "inaccuracy jump initial") * float(X["air_spread_scale"])

## Take-off: CS's OnJump puts the take-off cone onto the fire inaccuracy as well, so a shot at the apex (where
## the airborne term is 0) is still wide and only a gun held through its recovery time is accurate again.
func _on_jump() -> void:
	var id := held()
	if id == "" or id == "knife" or float(X["jump_takeoff_penalty"]) <= 0.0:
		return
	_decay_to(id, _now())
	_penalty = maxf(_penalty, base_inacc(id)) + _jump_inacc(id) * float(X["jump_takeoff_penalty"])

## CS's airborne inaccuracy: remapped on the square root of the vertical speed (units/s); none below
## air_inacc_apex_share of sqrt(jump impulse) (the apex), the full value at take-off speed, up to
## air_inacc_max_scale times it on fast falls and surf descents.
func air_inacc(jump: float, vz_units: float) -> float:
	var top := sqrt(float(Sheets.movement()["jump_impulse"]) / u)
	return clampf(remap(sqrt(vz_units), top * float(X["air_inacc_apex_share"]), top, 0.0, jump), 0.0, jump * float(X["air_inacc_max_scale"]))

## Landing: the weapon's "inaccuracy land" x the fall speed goes onto the fire inaccuracy, which recovers
## over the recovery time like a shot's penalty, so a shot the tick after landing is not fully accurate.
func _on_land(fall_speed: float) -> void:
	var id := held()
	if id == "" or id == "knife":
		return
	_decay_to(id, _now())  # the penalty recovers up to the landing first, like a take-off
	_penalty = maxf(_penalty, base_inacc(id)) + land_penalty(id, fall_speed / u)

func land_penalty(id: String, fall_units: float) -> float:
	return mstat(id, "inaccuracy land") * fall_units * float(X["land_velocity_scale"])

## Spread + inaccuracy of the held weapon, items_game units (the HUD's dynamic crosshair reads it).
func _spread(id: String) -> float:
	if id == "knife" or id == "":
		return 0.0
	return mstat(id, "spread") + _inacc(id)

## CS2 moves you at the held weapon's max player speed (its alt value while scoped), on the ground scaled by
## duck_speed_scale while ducked or walk_speed_scale while walking. Air strafing keeps the full value (the
## air acceleration reads it), so a crouched surf is not slowed.
func _speed(id: String) -> void:
	var p: SurfPlayer = main.player
	p.M["max_ground_speed"] = move_speed(id, p.grounded and p.ducked, walking()) * u

func move_speed(id: String, ducked: bool, walk: bool) -> float:
	var v := mstat(id if id != "" else "knife", "max player speed")
	if ducked:
		return v * float(X["duck_speed_scale"])
	return v * float(X["walk_speed_scale"]) if walk else v

## Scope level 0 (off), 1 or 2: the zoom fov (Source horizontal at 4:3), scoped mouse sensitivity, the lens
## overlay, and the viewmodel and crosshair hidden like CS2.
func _set_zoom(level: int) -> void:
	var p: SurfPlayer = main.player
	if p == null or level == _zoom:
		return
	var id := held()
	if _zoom == 0:
		if not (_fov_tween and _fov_tween.is_running()):
			_base_fov = p.cam.fov  # an unscope still easing out keeps the fov it is easing back to
		_base_sens = p.input.sensitivity
	var fov := _base_fov
	if level > 0 and _zoom == 0:
		_zoom_full_at = _now() + (zoom_time(id, level) if float(X["scope_accuracy_wait"]) > 0.0 else 0.0)
	if level > 0:
		var zf := stat(id, "zoom fov %d" % level)
		fov = Sheets.vfov_43(zf)
		p.input.sensitivity = _base_sens * float(X["zoom_sensitivity_ratio"]) * zf / float(Sheets.movement()["fov_default"])
		_scoped_sens = p.input.sensitivity
	else:
		p.input.sensitivity = _base_sens
		_scoped_sens = -1.0
	if _fov_tween:
		_fov_tween.kill()
	_fov_tween = create_tween()
	_fov_tween.tween_property(p.cam, "fov", fov, zoom_time(id, level))
	_zoom = level
	if main.viewmodel:
		main.viewmodel.visible = level == 0
	_scope_layer.visible = level > 0
	_xhair()
	_scope.queue_redraw()

## The scope stays on under the Esc menu: a sensitivity the player sets there is the new unscoped base, and the
## scope's own value is worked out again from it.
## A zoom_sensitivity_ratio changed there (Settings writes X) is applied to the scope at once as well.
func _sens_follow() -> void:
	var p: SurfPlayer = main.player
	if _zoom <= 0 or _scoped_sens < 0.0:
		return
	if not is_equal_approx(p.input.sensitivity, _scoped_sens):
		_base_sens = p.input.sensitivity
	refresh_zoom_sens()

## The scoped sensitivity worked out again from the unscoped base and the current zoom_sensitivity_ratio.
func refresh_zoom_sens() -> void:
	var p: SurfPlayer = main.player
	if p == null or _zoom <= 0:
		return
	var zf := stat(held(), "zoom fov %d" % _zoom)
	p.input.sensitivity = _base_sens * float(X["zoom_sensitivity_ratio"]) * zf / float(Sheets.movement()["fov_default"])
	_scoped_sens = p.input.sensitivity

## Seconds of the fov ease into a scope level: items_game's "zoom time <level>" (0 = back out), else its
## "zoom time 1", else the class zoom_time column.
func zoom_time(id: String, level: int) -> float:
	if id == "" or not rows.has(id):
		return float(X["zoom_time_none"])
	var k := "zoom time %d" % level
	return maxf(stat(id, k) if _has(id, k) else stat(id, "zoom time 1"), 0.01)

func scoped() -> bool:
	return _zoom > 0

## The scope is fully zoomed: its scoped spread and inaccuracy apply (CS's m_zoomFullyActiveTime).
func zoom_ready() -> bool:
	return _zoom > 0 and _now() >= _zoom_full_at

## CS2 draws no crosshair while scoped, nor on an unscoped sniper rifle (AWP, SSG 08, SCAR-20, G3SG1).
func crosshair_shown() -> bool:
	var id := held()
	return _zoom == 0 and not (id != "" and String(X["no_crosshair_classes"]).split(",").has(_cls(id)))

func _xhair() -> void:
	if main.hud and main.hud.get("crosshair") is Control:
		(main.hud.crosshair as Control).visible = crosshair_shown()

## An empty Zeus charges back to a full clip taser_recharge seconds after its shot.
func _recharge_tick(t: float) -> void:
	for id in _recharge.keys():
		if t >= float(_recharge[id]):
			_recharge.erase(id)
			ammo[id] = [int(stat(id, "primary clip size")), int(ammo[id][1])]
			_hud()

## A shotgun's fixed pellet pattern: an angle and a share of the spread radius per pellet, drawn once from
## Source's random stream on the weapon's recoil seed, so every blast puts its pellets in the same shape.
func pellets(id: String) -> PackedVector2Array:
	if _pellet_tabs.has(id):
		return _pellet_tabs[id]
	var rs := SourceRandom.new()
	rs.set_seed(_seed(id) + int(X["shotgun_pattern_seed_offset"]))
	var out := PackedVector2Array()
	for i in int(stat(id, "bullets")):
		out.append(Vector2(rs.rand_float(0.0, TAU), rs.rand_float(0.0, 1.0)))
	_pellet_tabs[id] = out
	return out

func _seed(id: String) -> int:
	return int(stat(id, "recoil seed")) if _has(id, "recoil seed") else (String(rows[id]["item"]).hash() & 0xffff if rows.has(id) else 0)

## CS2's knife: slash (attack) 40 first / 25 combo / 90 in the back, stab (attack2) 65 / 180 in the back.
## A ray to the knife's reach, then a hull swept along it like CS's knife trace; one swing = one shot.
func _knife(stab: bool) -> void:
	var t := _now()
	if t < _next_fire:
		return
	var first := t > _next_fire + float(X["knife_combo"])
	var cam: Camera3D = main.player.cam
	_punch_to(t)
	var dir := -_eye_basis().z
	var reach := float(X["knife_stab_range" if stab else "knife_slash_range"]) * u
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var ex: Array[RID] = [main.player.get_rid()]
	var r := knife_target(space, cam.global_position, dir, reach, ex)
	var col: Object = r.get("collider")
	var at: Vector3 = r.get("position", cam.global_position + dir * reach)
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
	col.hit(_armored(unit, dmg, _group(col, head), "knife"), head, at)
	_next_fire = t + float(X["knife_stab_hit" if stab else "knife_slash_hit"])
	if main.hud and main.hud.has_method("hitmarker"):
		main.hud.hitmarker(head)

## What a swing meets: the first thing on the ray to the knife's reach (a wall stops it), else the hull's pick.
func knife_target(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, reach: float, ex: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * reach)
	q.exclude = ex
	var r: Dictionary = space.intersect_ray(q)
	return knife_hull(space, from, from + dir * reach, ex) if r.is_empty() else r

## CS's knife hull: only when the ray reached nothing, a box knife_hull units across (knife_hull_z tall) swept
## from the eye to the end of the reach, like CS's UTIL_TraceHull with the head hull. What the box meets first
## decides: a body the eye can see is struck (the one nearest the line of the swing), a wall stops the swing.
## A sweep that meets nothing looks at what the box overlaps at the eye (a body pressed against the player).
func knife_hull(space: PhysicsDirectSpaceState3D, from: Vector3, end: Vector3, ex: Array[RID]) -> Dictionary:
	var box := BoxShape3D.new()
	box.size = Vector3(float(X["knife_hull"]), float(X["knife_hull_z"]), float(X["knife_hull"])) * 2.0 * u
	var hull := PhysicsShapeQueryParameters3D.new()
	hull.shape = box
	hull.transform = Transform3D(Basis.IDENTITY, from)
	hull.motion = end - from
	hull.exclude = ex
	var f := space.cast_motion(hull)  # Godot's sweep skips what the box already overlaps at the eye
	hull.motion = Vector3.ZERO
	if f.size() >= 2 and f[1] < 1.0:
		hull.transform = Transform3D(Basis.IDENTITY, from + (end - from) * f[1])
	var best := INF
	var out := {}
	for h in space.intersect_shape(hull, 16):
		var c: Object = h["collider"]
		if c == null or not c.has_method("hit"):
			continue
		var at := (c as Node3D).global_position
		var q := PhysicsRayQueryParameters3D.create(from, at)
		q.exclude = ex
		var seen: Dictionary = space.intersect_ray(q)
		if not seen.is_empty() and not (seen["collider"] as Object).has_method("hit"):
			continue  # a wall between the eye and the body
		var d := Geometry3D.get_closest_point_to_segment(at, from, end).distance_to(at)
		if d < best:
			best = d
			out = {"collider": c, "position": seen.get("position", at) if seen.get("collider") == c else at}
	return out

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

## R: like CS's DefaultReload, refused while the next attack is not ready (a draw, a bolt, a silencer turn).
## A magazine gun takes its reload clip's length (else the class reload_time); a tube shotgun starts loading
## shells: its reload_start clip (else the reload clip, once) and the first shell after it.
func reload() -> void:
	var id := held()
	var t := _now()
	if id == "" or id == "knife" or _reload_until > 0.0 or _shell_next > 0.0 or t < maxf(_next_fire, _toggle_until):
		return
	var a: Array = ammo[id]
	var full := int(stat(id, "primary clip size"))
	if int(a[0]) >= full or int(a[1]) <= 0:
		return
	_set_zoom(0)
	_rezoom = 0
	_burst_left = 0
	var vm: Viewmodel = main.viewmodel
	if _shotgun_shells(id):
		var start := "reload_start" if vm.has_clip("reload_start") else "reload"
		vm.play(start)
		_shell_next = t + (vm.clip_length(start) if start == "reload_start" else float(X["shell_start"]))
		return
	var dur := float(defaults[_cls(id)]["reload_time"])
	if vm.play("reload"):
		dur = vm.clip_length("reload")
	_reload_until = t + maxf(dur, 0.01)

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
		var vm: Viewmodel = main.viewmodel
		if vm.has_clip("reload_loop"):
			vm.play("reload_loop")  # this shell's push
		else:
			vm.kick("shell")
		if int(a[1]) <= 0 or int(a[0]) >= int(stat(id, "primary clip size")):
			_shell_next = 0.0
			if vm.has_clip("reload_end"):
				vm.queue_clip("reload_end")
				_next_fire = maxf(_next_fire, t + vm.clip_length("reload_loop") + vm.clip_length("reload_end"))
		else:
			_shell_next += vm.clip_length("reload_loop") if vm.has_clip("reload_loop") else float(X["shell_each"])
		_hud()

## Shots ring out on a pool of players, so a spray never cuts the previous shot off. A silencer gun with its
## silencer off plays its sound_unsilenced row, else (not exported) its own shot.
func _sound(id: String) -> void:
	var s := _stream(shot_sound(id))
	if s == null:
		s = _stream(String(rows[id]["sound_shot"]))
	if s and _voices.size() > 0:
		var p: AudioStreamPlayer = _voices[_voice]
		_voice = (_voice + 1) % _voices.size()
		p.stream = s
		p.play()

## The weapons.json sound path a shot of this weapon plays now.
func shot_sound(id: String) -> String:
	var un := String(rows[id].get("sound_unsilenced", "none"))
	if alt_kind(id) == "silencer" and not _alt_on.get(id, false) and un != "none" and un != "":
		return un
	return String(rows[id]["sound_shot"])

## One exported sound by its CS2 path (.wav or .mp3 in the data folder), loaded once; null when absent.
func _stream(vpk_path: String) -> AudioStream:
	if not _sounds.has(vpk_path):
		var base: String = main.content.dir.path_join("cs2/" + vpk_path.get_basename())
		var s: AudioStream = null
		if FileAccess.file_exists(base + ".wav"):
			s = AudioStreamWAV.load_from_file(base + ".wav")
		elif FileAccess.file_exists(base + ".mp3"):
			s = AudioStreamMP3.load_from_file(base + ".mp3")
		_sounds[vpk_path] = s
	return _sounds[vpk_path]

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
			elif thin.has(id):
				b.tooltip_text = "CS2 gave no " + ", ".join(thin[id]) + ": class averages stand in"
			var wid: String = id
			b.pressed.connect(func() -> void:
				give(wid)
				_buy.visible = false
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED)
			v.add_child(b)
		cols.add_child(v)

## The scope overlay: black outside a round lens with a soft dark rim. A sniper's lens has thin black cross
## lines edge to edge; a rifle scope (AUG, SG 553: scope_dot_classes) has a smaller lens with a red dot.
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

## The overlay style of a scoped weapon: "dot" for a rifle scope class, else "sniper".
func scope_style(id: String) -> String:
	return "dot" if id != "" and String(X["scope_dot_classes"]).split(",", false).has(_cls(id)) else "sniper"

func _draw_scope() -> void:
	var sz := _scope.size
	var c := sz * 0.5
	var dot := scope_style(held()) == "dot"
	var r := sz.y * float(X["scope_dot_lens" if dot else "scope_lens"]) * 0.5
	var w := sz.length()
	_scope.draw_arc(c, r + w * 0.5, 0.0, TAU, 192, Color.BLACK, w, true)
	var rim := sz.y * float(X["scope_edge"])
	for i in 6:
		var k := float(i) / 6.0
		_scope.draw_arc(c, r - rim * k - rim / 12.0, 0.0, TAU, 192, Color(0, 0, 0, 0.16 * (1.0 - k)), rim / 6.0 + 1.0, true)
	var px := sz.y / 1080.0
	if dot:
		var col: Array = X["scope_dot_color"]
		_scope.draw_circle(c, maxf(float(X["scope_dot_px"]) * px, 1.0), Color(float(col[0]), float(col[1]), float(col[2])), true, -1.0, true)
		return
	var lw := maxf(float(X["scope_line_px"]) * px, 1.0)
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
	if parts.size() > 1:
		_set_zoom(int(parts[1]))
	_hud()

## --wtest: the gun model's own checks, the aim lobby's hit count included. Each prints a WTEST PASS or FAIL
## line; the run ends with exit code 1 on any failure, else 0, so a build can gate on it. Missing CS2 stats are fine: every check also holds on class defaults.
var _fails := 0
var _checks := 0

func _check(what: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("WTEST %s %s %s" % ["PASS" if ok else "FAIL", what, detail])

## --wtest's stand-in for an aim lobby part: one hittable body that records the hits it takes.
class TestPart extends StaticBody3D:
	var unit: Object
	var group := "chest"
	var is_head := false
	var armor := 0.0
	var got: Array = []

	func hit(dmg: float, head: bool, _at: Vector3) -> void:
		got.append([dmg, head, group])

func _test_box(body: StaticBody3D, size: Vector3, at: Vector3) -> StaticBody3D:
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	body.add_child(cs)
	main.add_child(body)
	body.global_position = at
	return body

## --wtest: a readable name for a test body ("none" when null).
static func _tname(o: Variant, objs: Array, names: Array) -> String:
	var i := objs.find(o)
	return "none" if o == null else (String(names[i]) if i >= 0 else str(o))

func _test_ball(body: StaticBody3D, radius: float, at: Vector3) -> StaticBody3D:
	var cs := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = radius
	cs.shape = sp
	body.add_child(cs)
	main.add_child(body)
	body.global_position = at
	return body

func _selftest() -> void:
	var p: SurfPlayer = main.player
	# recoil pattern: seeded, the same on every build, different per weapon
	var a := pattern("cs2_ak47", 0)
	var b := pattern("cs2_ak47", 0)
	_tables.clear()
	var c := pattern("cs2_ak47", 0)
	_check("pattern_seeded", a.size() == int(X["pattern_length"]) and a == b and a == c, "ak47 seed=%s first=%s" % [str(int(stat("cs2_ak47", "recoil seed"))) if _has("cs2_ak47", "recoil seed") else "hash", str(a.slice(0, 3))])
	_check("pattern_per_weapon", pattern("cs2_m4a4", 0) != a, "m4a4 != ak47")
	var rs := SourceRandom.new()
	rs.set_seed(1)
	var r3 := [rs.next(), rs.next(), rs.next()]
	_check("source_random", r3 == [893351816, 197493099, 1624379149], "seed 1 -> %s (ran1 reference 893351816 197493099 1624379149)" % str(r3))
	# a 10-shot AK spray at 0.1 s: the bullets climb, then the punch settles back to zero
	var st0 := _now()
	_punch_reset(st0)
	_recoil_index = 0.0
	var climb: Array = []
	var stt := st0
	for i in 10:
		climb.append(_aim.x * float(X["recoil_scale"]))
		_recoil("cs2_ak47")
		_last_shot = 1000.0
		for j in 6:
			stt += 1.0 / 60.0
			_punch_to(stt)
	for j in 120:
		stt += 1.0 / 60.0
		_punch_to(stt)
	_check("spray_climbs_and_settles", float(climb[9]) > float(climb[2]) and float(climb[2]) > 0.0 and _aim.length() < 0.05, "bullet pitch deg shot3=%.2f shot10=%.2f rest=%.3f" % [climb[2], climb[9], _aim.length()])
	_inaccuracy = 0.0
	var still := _spread("cs2_ak47")
	_inaccuracy = mstat("cs2_ak47", "inaccuracy fire") * 3.0
	var fired := _spread("cs2_ak47")
	_deploy_reset()
	_recoil_index = 7.0
	_inaccuracy = 30.0
	_deploy_reset()
	_check("cone_and_deploy", fired > still and _inaccuracy == 0.0 and _recoil_index == 0.0, "ak47 still=%.2f after3=%.2f, a draw resets the penalty and recoil index" % [still, fired])
	# crouching: the penalty falls from the stand base to the crouch base over the recovery time; standing up
	# lifts it at once (CS's UpdateAccuracyPenalty)
	var keep_duck := p.ducked
	var keep_ground := p.grounded
	var keep_held: String = slots["primary"]
	var keep_cur0 := current
	slots["primary"] = "cs2_ak47"
	current = "primary"
	p.grounded = true
	p.ducked = false
	_inaccuracy = 0.0
	_last_shot = -100.0
	_decay("cs2_ak47", 0.016, 0.0)
	var stand_b := base_inacc("cs2_ak47")
	p.ducked = true
	var crouch_b := base_inacc("cs2_ak47")
	var tick0 := _inacc("cs2_ak47")
	_decay("cs2_ak47", stat("cs2_ak47", "recovery time crouch"), 0.0)
	var after_rec := _inacc("cs2_ak47")
	_decay("cs2_ak47", 5.0, 0.0)
	var settled := _inacc("cs2_ak47")
	p.ducked = false
	var stood := _inacc("cs2_ak47")
	var want_rec := crouch_b + (stand_b - crouch_b) * float(X["recovery_decay_to"])
	_check("crouch_penalty_lerp", stand_b > crouch_b and is_equal_approx(tick0, stand_b) and absf(after_rec - want_rec) < 0.001 and absf(settled - crouch_b) < 0.01 and is_equal_approx(stood, stand_b), "ak47 stand %.2f, crouch %.2f: the tick after ducking %.2f, one recovery time later %.2f (want %.2f), settled %.2f, standing up %.2f at once" % [stand_b, crouch_b, tick0, after_rec, want_rec, settled, stood])
	# moving: ducked or walking on the ground slows the weapon's speed; the air keeps it whole for strafing
	var full_spd := move_speed("cs2_ak47", false, false)
	var duck_spd := move_speed("cs2_ak47", true, false)
	var walk_spd := move_speed("cs2_ak47", false, true)
	p.ducked = true
	p.grounded = false
	_speed("cs2_ak47")
	var air_duck := float(p.M["max_ground_speed"]) / u
	p.grounded = true
	_speed("cs2_ak47")
	var ground_duck := float(p.M["max_ground_speed"]) / u
	p.ducked = keep_duck
	p.grounded = keep_ground
	_check("duck_walk_speed", is_equal_approx(duck_spd, full_spd * float(X["duck_speed_scale"])) and is_equal_approx(walk_spd, full_spd * float(X["walk_speed_scale"])) and is_equal_approx(air_duck, full_spd) and is_equal_approx(ground_duck, duck_spd) and InputMap.has_action(String(X["walk_action"])), "ak47 run %.0f, crouch %.0f, walk %.0f u/s; ducked in the air %.0f, on the ground %.0f; walk bound to %s" % [full_spd, duck_spd, walk_spd, air_duck, ground_duck, X["walk_action"]])
	# view punch: the camera's extra shake runs along the shot's own kick, not straight up
	_punch_reset(_now())
	_recoil_index = 0.0
	var kick0 := kick_at("cs2_ak47", 0.0)
	_recoil("cs2_ak47")
	var vk := _kick_view
	var kr := deg_to_rad(kick0.x)
	var want_vk := Vector2(cos(kr), -sin(kr)) * kick0.y * float(X["view_punch_extra"])
	_punch_reset(_now())
	_recoil_index = 0.0
	_inaccuracy = 0.0
	slots["primary"] = keep_held
	current = keep_cur0
	_speed(held())
	_check("view_punch_along_kick", vk.is_equal_approx(want_vk) and (absf(kick0.x) < 0.01 or absf(vk.y) > 0.0), "ak47 shot 1 angle %.2f deg: view kick %s (want %s)" % [kick0.x, vk, want_vk])
	# cadence: a held trigger keeps the exact cycletime; clicking never beats it
	for wid in ["cs2_ak47", "cs2_deagle"]:
		var cyc := stat(wid, "cycletime")
		var frame := 1.0 / 60.0
		var nf := 0.0
		var shots := 0
		var t := 0.0
		while t < 3.0:
			if t >= nf:
				nf = cadence(nf, t, cyc, frame)
				shots += 1
			t += frame
		var want := 3.0 / cyc
		var fast := 1.0 / 240.0
		nf = 0.0
		var prev := -10.0
		var gap := INF
		t = 0.0
		while t < 3.0:  # spam clicks every frame at 240 fps
			if t >= nf:
				nf = cadence(nf, t, cyc, fast)
				gap = minf(gap, t - prev)
				prev = t
			t += fast
		var late := cadence(1.0, 1.0 + cyc * 0.95, cyc, frame)  # a click just short of a whole cycle late
		_check("cadence_" + wid, absf(float(shots) - want) <= maxf(1.0, want * 0.02) and gap >= cyc - fast - 0.0001 and late >= 1.0 + cyc * 1.95 - 0.0001, "cyc=%.3f held 3 s=%d rounds (want %.1f), spam min gap=%.4f, late click next=%.3f" % [cyc, shots, want, gap, late])
	# scope: AWP levels 1, 2, off; a fast re-scope inside the zoom tween still returns to the real fov
	_next_fire = 0.0
	_reload_until = 0.0
	_shell_next = 0.0
	_toggle_until = 0.0
	_burst_left = 0
	var fov0 := p.cam.fov
	var sens0: float = p.input.sensitivity
	var keep_slot: String = slots["primary"]
	var keep_cur := current
	slots["primary"] = "cs2_awp"
	current = "primary"
	_inaccuracy = 0.0
	var unscoped := _spread("cs2_awp")
	_attack2("cs2_awp")
	_speed("cs2_awp")
	var lvl1 := _zoom
	var quick := _spread("cs2_awp")  # the scope's own tick: not fully zoomed yet
	var keep_full := _zoom_full_at
	_zoom_full_at = 0.0
	var cone1 := _spread("cs2_awp")
	_zoom_full_at = keep_full
	var spd1 := roundi(float(main.player.M["max_ground_speed"]) / u)
	var sens1: float = p.input.sensitivity
	_attack2("cs2_awp")
	var lvl2 := _zoom
	_attack2("cs2_awp")
	_attack2("cs2_awp")  # straight back in while the unscope is still easing out
	_attack2("cs2_awp")
	_attack2("cs2_awp")
	await get_tree().create_timer(maxf(stat("cs2_awp", "zoom time 1"), 0.01) + 0.15).timeout
	_speed("cs2_awp")
	_check("scope_awp", lvl1 == 1 and lvl2 == 2 and _zoom == 0 and cone1 < unscoped and sens1 < sens0 and not _scope_layer.visible, "lvl1 cone %.2f (unscoped %.2f) sens %.3f speed %d, lvl2=%d, off=%d overlay=%s" % [cone1, unscoped, sens1, spd1, lvl2, _zoom, _scope_layer.visible])
	var wait_on := float(X["scope_accuracy_wait"]) > 0.0
	_check("quickscope_unscoped_cone", is_equal_approx(quick, unscoped) == wait_on, "awp shot on the scope's own tick: cone %.2f (unscoped %.2f, fully zoomed %.2f, scope_accuracy_wait=%s)" % [quick, unscoped, cone1, wait_on])
	_check("scope_fov_restored", is_equal_approx(p.cam.fov, fov0) and is_equal_approx(p.input.sensitivity, sens0), "fov %.3f -> %.3f after a fast re-scope, sens %.3f -> %.3f" % [fov0, p.cam.fov, sens0, p.input.sensitivity])
	_next_fire = 0.0
	_attack2("cs2_awp")
	p.input.sensitivity = sens0 * 2.0  # the Esc menu's sensitivity slider while scoped
	_sens_follow()
	var rescoped: float = p.input.sensitivity
	var ratio0 := float(X["zoom_sensitivity_ratio"])
	X["zoom_sensitivity_ratio"] = ratio0 * 0.8  # the Esc menu's zoom_sensitivity_ratio while scoped
	_sens_follow()
	var reratio: float = p.input.sensitivity
	X["zoom_sensitivity_ratio"] = ratio0
	_sens_follow()
	_check("zoom_ratio_follows_menu", is_equal_approx(reratio, rescoped * 0.8) and is_equal_approx(p.input.sensitivity, rescoped), "ratio x0.8 while scoped: scoped sens %.3f -> %.3f at once" % [rescoped, reratio])
	_set_zoom(0)
	var after_menu: float = p.input.sensitivity
	p.input.sensitivity = sens0
	_check("scoped_sens_follows_menu", is_equal_approx(after_menu, sens0 * 2.0) and is_equal_approx(rescoped, sens1 * 2.0), "sens set to %.3f while scoped: scoped %.3f (was %.3f), unscoped %.3f" % [sens0 * 2.0, rescoped, sens1, after_menu])
	var kinds := [alt_kind("cs2_awp"), alt_kind("cs2_m4a1_silencer"), alt_kind("cs2_usp_silencer"), alt_kind("cs2_glock"), alt_kind("cs2_famas"), alt_kind("cs2_revolver"), alt_kind("cs2_ak47"), alt_kind("knife")]
	_check("alt_kinds", kinds == ["scope", "silencer", "silencer", "burst", "burst", "revolver", "none", "stab"], "awp m4a1s usp glock famas r8 ak knife = %s" % str(kinds))
	# attack2 waits for the gun like CS's m_flNextSecondaryAttack: no scope mid bolt or draw, no burst toggle mid cycle
	_next_fire = _now() + 1.0
	var scope_busy := _attack2("cs2_awp") or _zoom != 0
	_next_fire = 0.0
	var scope_ready := _attack2("cs2_awp") and _zoom == 1
	_set_zoom(0)
	var burst0: bool = _alt_on.get("cs2_glock", false)
	_next_fire = _now() + 1.0
	var burst_busy: bool = _attack2("cs2_glock") or _alt_on.get("cs2_glock", false) != burst0
	_next_fire = 0.0
	_alt_on["cs2_glock"] = burst0
	_check("attack2_waits_for_gun", not scope_busy and scope_ready and not burst_busy, "awp scope mid bolt=%s, once ready=%s; glock burst toggle mid cycle=%s" % [scope_busy, scope_ready, burst_busy])
	# R8 fan fire pushes each round out to the cone's edge (1 - r^2); the Negev's first shots too, tightening by shot 3
	var keep_fan := _fan
	_fan = true
	var sq_fan := outer_squarings("cs2_revolver")
	var sq_ak_fan := outer_squarings("cs2_ak47")
	_fan = false
	var sq_r8 := outer_squarings("cs2_revolver")
	_recoil_index = 0.0
	var sq_n0 := outer_squarings("cs2_negev")
	_recoil_index = float(X["outer_ring_first_shots"])
	var sq_n3 := outer_squarings("cs2_negev")
	_recoil_index = 0.0
	_fan = keep_fan
	_check("outer_ring", sq_fan == 1 and sq_ak_fan == 0 and sq_r8 == 0 and sq_n0 == int(X["outer_ring_first_shots"]) and sq_n3 == 0 and is_equal_approx(ring_share(0.5, 1), 0.75) and ring_share(0.5, 0) == 0.5, "r8 fan %d, r8 hammer %d, negev shot 1 %d, shot 4 %d squaring(s); r=0.5 -> %.3f" % [sq_fan, sq_r8, sq_n0, sq_n3, ring_share(0.5, 1)])
	# the weapons clock stands still while the trigger is blocked (menus): a pause never finishes a reload
	var was_held := _pause_from >= 0.0
	_hold_clock(false)
	var c0 := _now()
	_hold_clock(true)
	OS.delay_msec(60)
	var c1 := _now()
	_hold_clock(false)
	OS.delay_msec(30)
	var c2 := _now()
	_hold_clock(was_held)
	_check("clock_holds_in_pause", c1 - c0 < 0.005 and c2 - c1 >= 0.025, "60 ms paused moved the clock %.4f s, 30 ms running moved it %.4f s" % [c1 - c0, c2 - c1])
	# give() puts a bought gun in its stock mode (silencer on, burst off) whatever the last one was set to
	_alt_on["cs2_usp_silencer"] = false
	_alt_on["cs2_glock"] = true
	var keep_sec: String = slots["secondary"]
	var keep_cur2 := current
	var keep_ready2 := ready_ids.duplicate()
	for gid in ["cs2_usp_silencer", "cs2_glock"]:
		ready_ids[gid] = true
		give(gid)  # a gun not exported here fails to draw: give() still puts it back in stock mode before trying
	ready_ids = keep_ready2
	var bought_usp: bool = _alt_on["cs2_usp_silencer"]
	var bought_glock: bool = _alt_on["cs2_glock"]
	slots["secondary"] = keep_sec
	current = keep_cur2
	_check("bought_stock_mode", bought_usp and not bought_glock, "a bought USP-S comes silenced=%s, a bought Glock in burst=%s" % [bought_usp, bought_glock])
	_check("silenced_at_spawn", _alt_on["cs2_m4a1_silencer"] and _alt_on["cs2_usp_silencer"] and _mode("cs2_m4a1_silencer") == 1, "m4a1s=%s usp=%s" % [_alt_on["cs2_m4a1_silencer"], _alt_on["cs2_usp_silencer"]])
	# R8 primary: the hammer pull delays the round, letting go cancels it
	slots["secondary"] = "cs2_revolver"
	current = "secondary"
	_next_fire = 0.0
	var ck := float(X["revolver_cock"])
	var h := [hammer(true, 10.0), hammer(true, 10.0 + ck * 0.9), hammer(true, 10.0 + ck + 0.001), hammer(true, 20.0), hammer(false, 20.0 + ck * 0.5), hammer(true, 20.0 + ck * 0.6), hammer(true, 20.0 + ck * 1.5)]
	_check("r8_hammer", h == [false, false, true, false, false, false, false], "pull, early, after %.2f s, re-pull, let go, re-pull, still short = %s" % [ck, str(h)])
	# burst: one pull of the Glock in burst mode fires burst_shots rounds
	slots["secondary"] = "cs2_glock"
	_alt_on["cs2_glock"] = true
	ammo["cs2_glock"] = [20, 0]
	_next_fire = 0.0
	_shoot("cs2_glock", _now(), false)
	while _burst_left > 0:
		_shoot("cs2_glock", _burst_at, true)
	_check("burst_glock", 20 - int(ammo["cs2_glock"][0]) == int(X["burst_shots"]), "rounds=%d" % (20 - int(ammo["cs2_glock"][0])))
	# burst cadence: at 60 fps every round of a pull lands on burst_gap from the pull, not on the next frame
	ammo["cs2_glock"] = [20, 0]
	_next_fire = 0.0
	var bt0 := _now()
	_shoot("cs2_glock", bt0, false)
	var bshots: Array = [_last_shot - bt0]
	var ft := bt0
	while _burst_left > 0 and ft < bt0 + 1.0:
		ft += 1.0 / 60.0
		while _burst_left > 0 and ft >= _burst_at:
			_shoot("cs2_glock", _burst_at, true)
			bshots.append(_last_shot - bt0)
	var gap := float(X["burst_gap"])
	var cool := stat("cs2_glock", "cycletime alt") if _has("cs2_glock", "cycletime alt") else float(X["burst_cooldown"])
	var on_slot := bshots.size() == int(X["burst_shots"])
	for i in bshots.size():
		on_slot = on_slot and absf(float(bshots[i]) - gap * i) < 0.0001
	var want_next := maxf((0.0 if float(X["burst_from_pull"]) > 0.0 else gap * (bshots.size() - 1)) + cool, gap * bshots.size())
	_check("burst_cadence_60fps", on_slot and absf(_next_fire - bt0 - want_next) < 0.0001, "round times %s s (gap %.3f), next pull at +%.3f s" % [str(bshots), gap, _next_fire - bt0])
	_alt_on["cs2_glock"] = false
	# held full auto at 12 fps keeps the AK's rate of fire (rounds catch up inside a long frame)
	slots["primary"] = "cs2_ak47"
	current = "primary"
	ammo["cs2_ak47"] = [999, 0]
	_reload_until = 0.0
	_shell_next = 0.0
	_toggle_until = 0.0
	var at0 := _now()
	_next_fire = at0
	var rounds := 0
	var slow := 1.0 / 12.0
	var ht := at0
	while ht < at0 + 3.0 - 0.0001:
		rounds += hold_fire("cs2_ak47", ht, slow)
		ht += slow
	var want_r := 3.0 / stat("cs2_ak47", "cycletime")
	_check("auto_rate_low_fps", absf(rounds - want_r) <= 1.0, "ak47 held 3 s at 12 fps: %d rounds (want %.0f)" % [rounds, want_r])
	# sub-tick spray: a 30-round spray held at a low frame rate (several rounds a frame) puts every round on the
	# same punch as at 300 fps, each round flying on the punch of its own slot time
	_inacc_log = []
	var lo := _spray_at(8.0)
	var lo_cone: Array = _inacc_log
	_inacc_log = []
	var hi := _spray_at(300.0)
	var hi_cone: Array = _inacc_log
	_inacc_log = null
	var cone_gap := 0.0
	for i in mini(lo_cone.size(), hi_cone.size()):
		cone_gap = maxf(cone_gap, absf(float(lo_cone[i]) - float(hi_cone[i])))
	_check("cone_fps_independent", lo_cone.size() == hi_cone.size() and lo_cone.size() > 4 and float(hi_cone[4]) > float(hi_cone[0]) and cone_gap < 0.01, "ak47 cone per round at 8 vs 300 fps: largest gap %.4f (round 1 %.2f, round 5 %.2f)" % [cone_gap, float(hi_cone[0]) if hi_cone.size() > 0 else -1.0, float(hi_cone[4]) if hi_cone.size() > 4 else -1.0])
	var worst := 0.0
	var top := 0.0
	for i in mini(lo.size(), hi.size()):
		worst = maxf(worst, ((lo[i] as Vector2) - (hi[i] as Vector2)).length())
		top = maxf(top, (hi[i] as Vector2).length())
	_check("spray_fps_independent", lo.size() == hi.size() and lo.size() == mini(30, int(stat("cs2_ak47", "primary clip size"))) and top > 0.0 and worst <= 0.0001, "ak47 %d rounds at 8 vs 300 fps: largest gap %.6f deg of a %.2f deg spray" % [lo.size(), worst, top])
	refill()
	_punch_reset(_now())
	# recoil index: a fractional index blends the two table entries around it, suppression included
	_recoil_index = 0.0
	var ka := kick_at("cs2_ak47", 5.0)
	var kb := kick_at("cs2_ak47", 6.0)
	var kh := kick_at("cs2_ak47", 5.5)
	var tab := pattern("cs2_ak47", 0)
	var sup := lerpf(float(X["recoil_suppression_factor"]), 1.0, clampf(1.5 / maxf(float(X["recoil_suppression_shots"]), 1.0), 0.0, 1.0))
	var k15 := kick_at("cs2_ak47", 1.5)
	_check("recoil_index_blend", kh.is_equal_approx((ka + kb) * 0.5) and is_equal_approx(k15.y, (tab[1].y + tab[2].y) * 0.5 * sup), "ak47 index 5 %s, 6 %s, 5.5 %s; 1.5 suppressed by %.3f" % [ka, kb, kh, sup])
	_alt_on["cs2_glock"] = false
	# shotgun: shell by shell, one per shell_each, fire breaks it off
	slots["primary"] = "cs2_nova"
	current = "primary"
	ammo["cs2_nova"] = [2, 10]
	_next_fire = 0.0
	reload()
	_reload_tick(_now() + float(X["shell_start"]) + 0.001)
	var after1: int = ammo["cs2_nova"][0]
	_reload_tick(_shell_next + 0.001)
	var after2: int = ammo["cs2_nova"][0]
	_shoot("cs2_nova", _now(), false)
	_check("shells_nova", after1 == 3 and after2 == 4 and _shell_next == 0.0 and int(ammo["cs2_nova"][0]) == 3 and int(ammo["cs2_nova"][1]) == 8, "2 -> %d -> %d, fire breaks off=%s, clip=%d reserve=%d" % [after1, after2, _shell_next == 0.0, ammo["cs2_nova"][0], ammo["cs2_nova"][1]])
	# bodies far below the map: two 8-unit walls, a knife wall with a part behind it, a bot of two parts
	var made: Array = []
	for z in [0.0, -1.0]:
		made.append(_test_box(StaticBody3D.new(), Vector3(4, 4, 8 * u), Vector3(0, -900, z)))
	var kwall := _test_box(StaticBody3D.new(), Vector3(2, 2, 2 * u), Vector3(0, -1000, -0.4))
	var kpart := _test_box(TestPart.new(), Vector3(0.4, 0.4, 0.2), Vector3(0, -1000, -0.75))
	var hpart := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.3), Vector3(0.1, -1050, -0.95))
	var bot := Node3D.new()
	main.add_child(bot)
	var leg := _test_box(TestPart.new(), Vector3(0.3, 0.3, 4 * u), Vector3(0, -1100, -3)) as TestPart
	var chest := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.3), Vector3(1, -1100, -3)) as TestPart
	leg.group = "legs"
	for tp in [leg, chest]:
		(tp as TestPart).unit = bot
	made += [kwall, kpart, hpart, bot, leg, chest]
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = main.player.get_world_3d().direct_space_state
	var ex: Array[RID] = [main.player.get_rid()]
	var e1 := _exit(space, made[0], Vector3(0, -900, 4 * u), Vector3(0, 0, -1), ex)
	var thick := (e1["position"] as Vector3).distance_to(Vector3(0, -900, 4 * u)) / u if not e1.is_empty() else -1.0
	var n0 := _decals.size()
	_trace("cs2_ak47", Vector3(0, -900, 3), Vector3(0, 0, -1), 50.0, stat("cs2_ak47", "damage"), [])
	_check("penetration", absf(thick - 8.0) < 1.0 and _decals.size() - n0 == 4, "exit_units=%.1f surfaces_marked=%d" % [thick, _decals.size() - n0])
	# knife: a wall in front stops the swing; the hull finds a body only when the ray reached nothing and the eye sees it
	var kreach := float(X["knife_slash_range"]) * u
	var through := knife_target(space, Vector3(0, -1000, 0), Vector3(0, 0, -1), kreach, ex)
	var hull_hit := knife_target(space, Vector3(0, -1050, 0), Vector3(0, 0, -1), kreach, ex)
	var tp_wall: Object = through.get("collider")
	_check("knife_wall", tp_wall == kwall and not tp_wall.has_method("hit") and hull_hit.get("collider") == hpart, "through a wall -> %s, hull past the reach -> %s" % [tp_wall, hull_hit.get("collider")])
	# the swept knife hull: a part 20 units ahead and 15 to the side is struck though the ray misses it; a part 34
	# units ahead with a wall plate first in the sweep (22 units) is safe (CS's hull trace stops at the wall)
	var side := _test_box(TestPart.new(), Vector3(0.1, 0.1, 0.1), Vector3(15.0 * u, -1300, -20.0 * u))
	var side2 := _test_box(TestPart.new(), Vector3(0.1, 0.1, 0.1), Vector3(15.0 * u, -1350, -34.0 * u))
	var plate := _test_box(StaticBody3D.new(), Vector3(0.4, 0.6, 1.0 * u), Vector3(0.4, -1350, -22.0 * u))
	made += [side, side2, plate]
	await get_tree().physics_frame
	await get_tree().physics_frame
	var swept := knife_target(space, Vector3(0, -1300, 0), Vector3(0, 0, -1), kreach, ex)
	var walled := knife_target(space, Vector3(0, -1350, 0), Vector3(0, 0, -1), kreach, ex)
	_check("knife_hull_swept", swept.get("collider") == side and walled.get("collider") != side2, "part 20 u ahead, 15 u aside -> %s; 34 u ahead behind a plate at 22 u -> %s" % [_tname(swept.get("collider"), [side, side2, plate], ["part", "part", "plate"]), _tname(walled.get("collider"), [side, side2, plate], ["part", "part", "plate"])])
	# penetration: a collider's pen_mod meta (a wood or metal surface) replaces pen_mod_world
	var keep_meta: Variant = kwall.get_meta("pen_mod") if kwall.has_meta("pen_mod") else null
	kwall.set_meta("pen_mod", 1.0)
	var pm_meta := pen_mod(kwall, false)
	kwall.remove_meta("pen_mod")
	_check("pen_mod_surface", is_equal_approx(pm_meta, 1.0) and is_equal_approx(pen_mod(kwall, false), float(X["pen_mod_world"])) and is_equal_approx(pen_mod(side, true), float(X["pen_mod_body"])) and keep_meta == null, "meta 1.0 -> %.2f, plain wall %.2f, body %.2f" % [pm_meta, pen_mod(kwall, false), pen_mod(side, true)])
	# shotgun pellets: each lands on its own part with its own hitgroup; one bullet hits a target once
	var hits: Array = []
	for at in [Vector3(0, -1100, 0), Vector3(1, -1100, 0), Vector3(1, -1100, 0)]:
		_trace("cs2_nova", at, Vector3(0, 0, -1), 10.0, 26.0, hits)
	var line_hits: Array = []
	var chest_behind := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.3), Vector3(0, -1100, -3.6)) as TestPart
	chest_behind.unit = bot
	made.append(chest_behind)
	await get_tree().physics_frame
	_trace("cs2_ak47", Vector3(0, -1100, 0), Vector3(0, 0, -1), 10.0, 36.0, line_hits)
	_deliver(hits)
	# one bot costs one penetration: through a bot's leg and chest into a second bot, the second takes what
	# one body toll leaves, not two
	var bot2 := Node3D.new()
	main.add_child(bot2)
	var behind := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.3), Vector3(0, -1100, -5)) as TestPart
	behind.unit = bot2
	made += [bot2, behind]
	await get_tree().physics_frame
	var pass_hits: Array = []
	_trace("cs2_ak47", Vector3(0, -1100, 0), Vector3(0, 0, -1), 10.0, 36.0, pass_hits)
	chest_behind.global_position.x += 10.0  # the same shot with bot A's leg alone in the way
	await get_tree().physics_frame
	await get_tree().physics_frame
	var leg_only: Array = []
	_trace("cs2_ak47", Vector3(0, -1100, 0), Vector3(0, 0, -1), 10.0, 36.0, leg_only)
	chest_behind.global_position.x -= 10.0
	var got_b: float = float(pass_hits[1][1]) if pass_hits.size() == 2 else -1.0
	var want_b: float = float(leg_only[1][1]) if leg_only.size() == 2 else -2.0
	_check("pen_one_toll_per_bot", stat("cs2_ak47", "penetration") <= 0.0 or (pass_hits.size() == 2 and pass_hits[1][0] == behind and absf(got_b - want_b) < 0.0001), "36 through bot A's leg and chest into bot B: %d hit(s), B takes %.2f; with A's leg alone in the way %.2f (one body toll per bot)" % [pass_hits.size(), got_b, want_b])
	_check("pellets_per_part", leg.got.size() == 1 and chest.got.size() == 2 and String(leg.got[0][2]) == "legs" and String(chest.got[0][2]) == "chest" and line_hits.size() == 1, "legs got %d, chest got %d, a bullet through leg into chest of one bot hit %d time(s)" % [leg.got.size(), chest.got.size(), line_hits.size()])
	# armor: CS's ratio split
	var armored := TestPart.new()
	armored.armor = 100.0
	var dealt := _armored(armored, 36.0, "chest", "cs2_ak47")
	var want_h := 36.0 * stat("cs2_ak47", "armor ratio") * float(X["armor_ratio_scale"])
	var after_chest := armored.armor
	var leg_dealt := _armored(armored, 27.0, "legs", "cs2_ak47")
	var head_dealt := _armored(armored, 144.0, "head", "cs2_ak47")
	_check("armor", is_equal_approx(dealt, want_h) and is_equal_approx(after_chest, 100.0 - (36.0 - want_h) * float(X["armor_bonus"])) and leg_dealt == 27.0 and head_dealt == 144.0 and armored.armor == after_chest, "chest 36 -> %.2f health, armor %.2f; legs 27 -> %.1f and no-helmet head 144 -> %.1f leave the armor" % [dealt, after_chest, leg_dealt, head_dealt])
	armored.free()
	# range falloff counts the flight inside a penetrated wall: one 8-unit wall costs its toll plus rm^(8/500)
	var fall_hits: Array = []
	var far_part := _test_box(TestPart.new(), Vector3(4, 4, 0.2), Vector3(0, -900, -3)) as TestPart
	made.append(far_part)
	await get_tree().physics_frame
	_trace("cs2_ak47", Vector3(0, -900, 3), Vector3(0, 0, -1), 50.0, 100.0, fall_hits)
	var rmod := stat("cs2_ak47", "range modifier")
	var pmw := 1.0 / float(X["pen_mod_world"])
	var toll := func(d: float) -> float:
		return d - (d * float(X["pen_chunk"]) + maxf(0.0, 3.0 / stat("cs2_ak47", "penetration") * 1.25) * pmw * 3.0 + pmw * 64.0 / 24.0)
	# surfaces met at these distances flown (units, the 8 inside each wall included): wall 1, wall 2, the part
	var legs := [(3.0 - 4.0 * u) / u, 8.0 + (1.0 - 8.0 * u) / u, 8.0 + (1.9 - 4.0 * u) / u]
	var exp_d := 100.0
	var flown := 0.0
	for i in 3:
		flown += float(legs[i])
		exp_d *= pow(rmod, (flown if float(X["falloff_cumulative"]) > 0.0 else float(legs[i])) / 500.0)
		if i < 2:
			exp_d = toll.call(exp_d)
	var got_d: float = float(fall_hits[0][1]) if fall_hits.size() > 0 else -1.0
	_check("falloff_through_walls", stat("cs2_ak47", "penetration") <= 0.0 or absf(got_d - exp_d) < 0.005, "100 through two 8-unit walls to 6 m: %.2f (want %.2f, falloff on the total %.0f units flown, compounding=%s)" % [got_d, exp_d, flown, float(X["falloff_cumulative"]) > 0.0])
	# a head sphere with a thin neck plate inside its back edge: the bullet leaves the head past the plate and
	# goes on into the next bot (the look back skips the plate instead of stopping the bullet in the head)
	var bot_a := Node3D.new()
	var bot_b := Node3D.new()
	main.add_child(bot_a)
	main.add_child(bot_b)
	var head_p := _test_ball(TestPart.new(), 0.12, Vector3(0, -1200, -3)) as TestPart
	var neck_p := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.04), Vector3(0, -1200, -3.12)) as TestPart
	var next_p := _test_box(TestPart.new(), Vector3(0.3, 0.3, 0.3), Vector3(0, -1200, -3.8)) as TestPart
	head_p.is_head = true
	head_p.unit = bot_a
	neck_p.unit = bot_a
	next_p.unit = bot_b
	made += [bot_a, bot_b, head_p, neck_p, next_p]
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ov_hits: Array = []
	_trace("cs2_ak47", Vector3(0, -1200, 0), Vector3(0, 0, -1), 10.0, 36.0, ov_hits)
	_check("pen_overlapping_parts", stat("cs2_ak47", "penetration") <= 0.0 or (ov_hits.size() == 2 and ov_hits[0][0] == head_p and ov_hits[1][0] == next_p), "head over a neck plate, a second bot behind: %d hit(s) %s" % [ov_hits.size(), str(ov_hits.map(func(h: Array) -> String: return "head" if h[0] == head_p else ("next" if h[0] == next_p else "neck")))])
	for w in made:
		(w as Node).queue_free()
	# airborne cone: nothing at the apex, the take-off value at jump speed, capped at air_inacc_max_scale x
	var jmp := _jump_inacc("cs2_ak47")
	var vj := float(Sheets.movement()["jump_impulse"]) / u
	var air := [air_inacc(jmp, 0.0), air_inacc(jmp, vj * 0.04), air_inacc(jmp, vj), air_inacc(jmp, vj * 100.0)]
	_check("air_inaccuracy", air[0] == 0.0 and air[1] == 0.0 and is_equal_approx(air[2], jmp) and is_equal_approx(air[3], jmp * float(X["air_inacc_max_scale"])), "ak47 jump %.1f: apex %.1f, low %.1f, take-off %.1f, fast fall %.1f" % [jmp, air[0], air[1], air[2], air[3]])
	slots["primary"] = "cs2_ak47"
	current = "primary"
	_inaccuracy = 0.0
	_on_land(vj * u)
	var landed := _inaccuracy
	_inaccuracy = 0.0
	_on_jump()
	var took := _inaccuracy
	_inaccuracy = 0.0
	_check("jump_takeoff_penalty", is_equal_approx(took, jmp * float(X["jump_takeoff_penalty"])) and (took > 0.0) == (float(X["jump_takeoff_penalty"]) > 0.0), "ak47 take-off adds %.1f to the fire inaccuracy (take-off cone %.1f)" % [took, jmp])
	_check("land_penalty", landed > 0.0 and is_equal_approx(landed, land_penalty("cs2_ak47", vj)), "ak47 landing from a jump adds %.2f to the fire inaccuracy" % landed)
	# shotguns: the same pellet pattern every blast; rifles stay random
	var pa := pellets("cs2_nova")
	_pellet_tabs.clear()
	_check("shotgun_pattern_fixed", pa.size() == int(stat("cs2_nova", "bullets")) and pa == pellets("cs2_nova") and pa != pellets("cs2_xm1014"), "nova %d pellets, first %s" % [pa.size(), str(pa.slice(0, 2))])
	# Zeus: an empty charge comes back after taser_recharge seconds
	var zeus := ""
	for zid in rows:
		if rows[zid]["slot"] == "gear":
			zeus = zid
	if zeus != "":
		ammo[zeus] = [1, 0]
		slots["taser"] = zeus
		current = "taser"
		_next_fire = 0.0
		var t0 := _now()
		_shoot(zeus, t0, false)
		var empty := int(ammo[zeus][0])
		_recharge_tick(t0 + float(X["taser_recharge"]) * 0.5)
		var half := int(ammo[zeus][0])
		_recharge_tick(t0 + float(X["taser_recharge"]) + 0.01)
		_check("zeus_recharge", empty == 0 and half == 0 and int(ammo[zeus][0]) == int(stat(zeus, "primary clip size")), "%s: 0 after the shot, %d at half time, %d after %.0f s" % [zeus, half, ammo[zeus][0], float(X["taser_recharge"])])
	# crosshair: hidden on an unscoped sniper, shown on a rifle
	slots["primary"] = "cs2_awp"
	current = "primary"
	var xh_awp := crosshair_shown()
	slots["primary"] = "cs2_ak47"
	var xh_ak := crosshair_shown()
	_check("sniper_no_crosshair", not xh_awp and xh_ak, "awp unscoped=%s ak=%s" % [xh_awp, xh_ak])
	var keep_awp: Dictionary = _st.get("cs2_awp", {})
	var uz := [unzoom_after_shot("cs2_awp"), unzoom_after_shot("cs2_ak47")]
	_st["cs2_awp"] = keep_awp.merged({String(X["unzoom_key"]): 0.0}, true)
	uz.append(unzoom_after_shot("cs2_awp"))  # the file's own attribute wins over the cycletime rule
	_st["cs2_awp"] = keep_awp
	_check("unzoom_after_shot", uz == [true, false, false], "awp, ak47, awp with the attribute set to 0 = %s" % str(uz))
	# backstab: behind a +Z-facing target vs in front of it
	var dummy := Node3D.new()
	main.add_child(dummy)
	dummy.global_position = Vector3(0, -900, 0)
	_check("backstab", backstab(dummy, Vector3(0, -900, -1)) and not backstab(dummy, Vector3(0, -900, 1)), "behind / front")
	dummy.queue_free()
	# viewmodel: every mesh of the rig sits nearer the eye than any wall the hull lets the player touch
	var vm: Viewmodel = main.viewmodel
	var far := 0.0
	var body_bone := RegEx.create_from_string("^(head|neck|spine|pelvis|leg|foot|ankle|toe|clavicle|root|wpnPivot)")  # body bones the arms mesh binds but never draws
	var inv := p.cam.global_transform.affine_inverse()
	for mi in vm._all(vm, "MeshInstance3D"):
		var m3 := mi as MeshInstance3D
		var sk3 := m3.get_node_or_null(m3.skeleton) as Skeleton3D
		if m3.skin and sk3:  # a skinned mesh: the posed bones it draws (its own aabb is the bind pose)
			for bi in m3.skin.get_bind_count():
				var bone := m3.skin.get_bind_bone(bi)
				if bone < 0:
					bone = sk3.find_bone(m3.skin.get_bind_name(bi))
				if bone >= 0 and not body_bone.search(sk3.get_bone_name(bone)):
					var v := inv * sk3.global_transform * sk3.get_bone_global_pose(bone).origin
					far = maxf(far, v.length())
		else:
			var bx := m3.get_aabb()
			for k in 8:
				far = maxf(far, (inv * m3.global_transform * bx.get_endpoint(k)).length())
	var wall := float(p.M["hull_width"]) * 0.5
	_check("viewmodel_inside_hull", far > 0.0 and far < wall and p.cam.near < far, "rig reaches %.3f m from the eye, nearest wall %.3f m, near plane %.4f m" % [far, wall, p.cam.near])
	# re-equip: drawing the knife again keeps its own idle clip (the cached glb's clips are not shared)
	var kclips := {"draw": main.content.path_of("clip_knife_draw"), "idle": main.content.path_of("clip_knife_idle"), "inspect": main.content.path_of("clip_knife_inspect")}
	var idles: Array = []
	for i in 3:
		if vm.equip(main.content.path_of("model_knife_ct"), kclips):
			idles.append(vm._idle_name)
			vm.idle()
	var loops := vm.anim != null and vm.anim.current_animation == vm._idle_name and vm.anim.get_animation(vm._idle_name).loop_mode == Animation.LOOP_LINEAR
	_check("reequip_idle", idles.size() == 3 and idles[0] == idles[2] and not kclips.has(String(idles[0])) and loops, "idle clip on three equips: %s, looping=%s" % [str(idles), loops])
	# items_game reader: platform conditionals and escapes as prep reads them
	_ig = '"x" { "a" "1" [$X360] "a" "2" [$WIN32] "b" "say \\"hi\\"" "c" "3" [!$WIN32] "blk" [$X360] { "z" "9" } "d" [$WIN32||$OSX] { "y" "8" } }'
	var kv := _kv(_ig.find("{"))
	_ig = ""
	_check("items_game_reader", kv.get("a") == "2" and kv.get("b") == 'say "hi"' and not kv.has("c") and not kv.has("blk") and kv.get("d", {}).get("y") == "8", str(kv))
	_ig_parity()
	_fixture_stats()
	# movement: CS's power curve puts half the speed range at most of the move cone; walking stays linear
	var ms := [move_share(0.0, 250.0, false), move_share(250.0 * (0.34 + 0.95) * 0.5, 250.0, false), move_share(250.0 * (0.34 + 0.95) * 0.5, 250.0, true), move_share(250.0, 250.0, false)]
	_check("move_power_curve", ms[0] == 0.0 and is_equal_approx(ms[1], pow(0.5, float(X["move_inacc_power"]))) and is_equal_approx(ms[2], 0.5) and ms[3] == 1.0, "share at rest, mid run, mid walk, full = %s" % str(ms))
	# silencer: the shot sound follows the can (sound_unsilenced with it off), the toggle waits for the gun
	slots["primary"] = "cs2_m4a1_silencer"
	current = "primary"
	_alt_on["cs2_m4a1_silencer"] = true
	var snd_on := shot_sound("cs2_m4a1_silencer")
	_next_fire = 0.0
	_toggle_until = 0.0
	_attack2("cs2_m4a1_silencer")
	var snd_off := shot_sound("cs2_m4a1_silencer")
	var busy := _toggle_until > _now()
	_attack2("cs2_m4a1_silencer")  # a second press mid-toggle is ignored
	var still_off: bool = not _alt_on["cs2_m4a1_silencer"]
	_toggle_until = 0.0
	_next_fire = 0.0
	_attack2("cs2_m4a1_silencer")
	_check("silencer_sound", snd_on == String(rows["cs2_m4a1_silencer"]["sound_shot"]) and snd_off == String(rows["cs2_m4a1_silencer"]["sound_unsilenced"]) and snd_off != snd_on and busy and still_off and _alt_on["cs2_m4a1_silencer"] and shot_sound("cs2_ak47") == String(rows["cs2_ak47"]["sound_shot"]), "on %s, off %s, toggle %.1f s, mid-toggle press ignored=%s" % [snd_on.get_file(), snd_off.get_file(), float(X["silencer_time"]), still_off])
	_toggle_until = 0.0
	# CS's Holster: putting the M4A1-S away mid-toggle undoes the press, a finished toggle stays
	_alt_on["cs2_m4a1_silencer"] = true
	_next_fire = 0.0
	_attack2("cs2_m4a1_silencer")
	var mid_off: bool = not _alt_on["cs2_m4a1_silencer"]
	_holster("cs2_m4a1_silencer")
	var undone: bool = _alt_on["cs2_m4a1_silencer"]
	_next_fire = 0.0
	_toggle_until = 0.0
	_attack2("cs2_m4a1_silencer")
	_toggle_until = _now() - 0.01
	_holster("cs2_m4a1_silencer")
	var kept: bool = not _alt_on["cs2_m4a1_silencer"]
	_alt_on["cs2_m4a1_silencer"] = true
	_toggle_until = 0.0
	_next_fire = 0.0
	_check("silencer_holster_cancel", mid_off and undone and kept, "detach pressed=%s, put away mid-turn comes back silenced=%s, a finished detach stays off=%s" % [mid_off, undone, kept])
	# a tap after a rest recovers the recoil index up to the tap before the tap's own kick (CS order)
	slots["primary"] = "cs2_ak47"
	current = "primary"
	ammo["cs2_ak47"] = [30, 0]
	var tap0 := _now()
	_last_shot = tap0 - 3.0
	_decay_at = tap0 - 3.0
	_recoil_index = 5.0
	_next_fire = 0.0
	_reload_until = 0.0
	_shell_next = 0.0
	_shoot("cs2_ak47", tap0, false)
	var tap_index := _recoil_index
	_check("tap_after_rest", is_equal_approx(tap_index, 1.0), "index 5 rested 3 s, then a tap: index after it %.3f (want 1)" % tap_index)
	_recoil_index = 0.0
	_punch_reset(_now())
	# the overlay: a rifle scope (AUG, SG 553) draws the red dot, a sniper the cross lines
	_check("scope_style", scope_style("cs2_aug") == "dot" and scope_style("cs2_sg556") == "dot" and scope_style("cs2_awp") == "sniper" and scope_style("cs2_ssg08") == "sniper", "aug %s, sg553 %s, awp %s, ssg08 %s" % [scope_style("cs2_aug"), scope_style("cs2_sg556"), scope_style("cs2_awp"), scope_style("cs2_ssg08")])
	# empty gun: a held trigger dry-fires and does not reload; letting go reloads; R is refused mid-draw
	slots["primary"] = "cs2_ak47"
	current = "primary"
	ammo["cs2_ak47"] = [0, 30]
	_next_fire = 0.0
	_reload_until = 0.0
	_shoot("cs2_ak47", _now(), false)
	var dry_reload := _reload_until
	_auto_reload("cs2_ak47", _now())  # no attack button is down in a headless run
	var auto_started := _reload_until > 0.0
	var inspect_mid := can_inspect()
	_reload_tick(_reload_until + 0.001)
	var refilled: int = ammo["cs2_ak47"][0]
	ammo["cs2_ak47"] = [5, 30]
	_next_fire = _now() + 1.0  # still drawing
	reload()
	var drawn_reload := _reload_until
	_next_fire = 0.0
	_check("empty_auto_reload", dry_reload == 0.0 and auto_started and not inspect_mid and refilled == mini(int(stat("cs2_ak47", "primary clip size")), 30) and drawn_reload == 0.0, "dry pull reloads=%s, released -> reload=%s, inspect mid-reload=%s, clip after=%d, R mid-draw=%s" % [dry_reload > 0.0, auto_started, inspect_mid, refilled, drawn_reload > 0.0])
	# stats: an exported gun without its stats_required values is named, not silently averaged
	var keep_ready := ready_ids.duplicate()
	var keep_st: Dictionary = _st.get("cs2_ak47", {})
	ready_ids = {"cs2_ak47": true}
	_st["cs2_ak47"] = {"damage": 36.0}
	problems.clear()
	thin.clear()
	_stats_check()
	var flagged := problems.size() == 1 and thin.has("cs2_ak47") and not (thin["cs2_ak47"] as PackedStringArray).has("damage")
	_st["cs2_ak47"] = keep_st
	ready_ids = keep_ready
	problems.clear()
	thin.clear()
	_stats_check()
	_check("stats_required_flagged", flagged, "an AK with only damage is named in the HUD problems")
	# stats: values every CS2 player knows, against what the player's files gave (a moved or renamed key fails)
	var compared := 0
	var wrong: PackedStringArray = []
	for r in Sheets.load_sheet("weapon_defaults")["reference"]:
		var wid := String(r["weapon"])
		if rows.has(wid) and _has(wid, String(r["key"])):
			compared += 1
			if absf(stat(wid, String(r["key"])) - float(r["value"])) > 0.0005:
				wrong.append("%s %s=%s (want %s)" % [wid, r["key"], stat(wid, String(r["key"])), r["value"]])
	_check("stats_reference", wrong.is_empty(), "%d known value(s) compared with the files, %s" % [compared, "all equal" if wrong.is_empty() else "; ".join(wrong)] + ("" if compared > 0 else " (no CS2 stats in this data folder)"))
	# the aim lobby counts a real traced shot on a target the eye can see, one hit per shot
	var lob: Node = main.lobby
	if lob and lob.has_method("toggle") and lob.has_method("on_shot_fired"):
		if not lob.get("active"):
			lob.toggle()
		for i in 12:
			await get_tree().physics_frame
		slots["primary"] = "cs2_ak47"
		current = "primary"
		var before := int(lob.get("_hits"))
		var shots_hit := 0
		space = main.player.get_world_3d().direct_space_state
		for tn in get_tree().get_nodes_in_group("aim_target"):
			if shots_hit >= 5:
				break
			if not is_instance_valid(tn) or not (tn as Node3D).is_inside_tree():
				continue
			var from := p.cam.global_position
			var dir := ((tn as Node3D).global_position - from).normalized()
			var q := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0)
			q.exclude = ex
			var seen: Dictionary = space.intersect_ray(q)
			if seen.is_empty() or seen["collider"] != tn:
				continue
			lob.on_shot_fired()
			var lh: Array = []
			_trace("cs2_ak47", from, dir, 200.0, stat("cs2_ak47", "damage"), lh)
			_deliver(lh)
			shots_hit += 1
		var counted := int(lob.get("_hits")) - before
		_check("lobby_counts_hits", shots_hit > 0 and counted == shots_hit, "%d visible targets shot, lobby counted %d hit(s)" % [shots_hit, counted])
		lob.toggle()
	slots["primary"] = keep_slot
	slots["secondary"] = _first_ready(["cs2_usp_silencer", "cs2_glock", "cs2_deagle"], "pistol")
	current = keep_cur
	refill()
	_punch_reset(_now())
	_deploy_reset()
	_last_shot = -10.0
	_next_fire = 0.0
	_speed(held())
	_hud()
	print("WTEST weapons checks=%d failed=%d" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)

## --wtest: one held AK spray at a fixed frame rate (simulated frames on the weapons clock), returning each
## round's aim punch x recoil_scale as it flew.
func _spray_at(fps: float) -> Array:
	slots["primary"] = "cs2_ak47"
	current = "primary"
	ammo["cs2_ak47"] = [mini(30, int(stat("cs2_ak47", "primary clip size"))), 0]
	_reload_until = 0.0
	_shell_next = 0.0
	_toggle_until = 0.0
	_burst_left = 0
	_recoil_index = 0.0
	_inaccuracy = 0.0
	var t0 := _now()
	_punch_reset(t0)
	_decay_at = t0
	_next_fire = t0
	_shot_log = []
	var dt := 1.0 / fps
	var ft := t0
	while int(ammo["cs2_ak47"][0]) > 0 and ft < t0 + 10.0:
		hold_fire("cs2_ak47", ft, dt)
		_decay_to("cs2_ak47", ft)
		_punch_to(ft)
		ft += dt
	var out: Array = _shot_log
	_shot_log = null
	_punch_reset(_now())
	_decay_at = _now()
	return out

## One weapon's attributes as prep/items_game.stats gives them: the "items" entry named item (its prefab chain,
## its own attributes on top), else the <item>_prefab block's chain. Strings, like prep's.
func ig_stats(item: String) -> Dictionary:
	var it := _ig_item(item)
	if it.is_empty():
		return _ig_chain(item + "_prefab", {})
	var out := {}
	for p in String(it.get("prefab", "")).split(" ", false):
		out.merge(_ig_chain(p, {}), true)
	out.merge(_ig_attrs(it), true)
	return out

## The block under items_game's "items" whose "name" is item, {} when there is none.
func _ig_item(item: String) -> Dictionary:
	var at := _ig.find("\"items\"", maxi(_ig_prefabs, 0))
	while at >= 0:
		var j := at + 7
		while j < _ig.length() and " \t\r\n".contains(_ig[j]):
			j += 1
		if j < _ig.length() and _ig[j] == "{":
			break
		at = _ig.find("\"items\"", j)
	if at < 0:
		return {}
	var rx := RegEx.create_from_string("\"name\"\\s+\"" + item + "\"")
	var m := rx.search(_ig, at)
	while m:
		var b := _open_of(m.get_start())
		if b > at:
			var blk := _kv(b)
			if String(blk.get("name", "")) == item:
				return blk
		m = rx.search(_ig, m.get_end())
	return {}

## The "{" of the block that holds index i: a backward walk that steps over every block closed before i
## (an item's "visuals" or "attributes" ahead of its "name"), quoted strings and // comments aside. -1 at the top.
func _open_of(i: int) -> int:
	var depth := 0
	var end := i
	while end > 0:
		var ls := _ig.rfind("\n", end - 1) + 1  # one line at a time, last line first (strings never span lines)
		var braces: Array = []
		var q := false
		var k := ls
		while k < end:
			var ch := _ig[k]
			if q and ch == "\\":
				k += 1  # an escaped character inside a string
			elif ch == "\"":
				q = not q
			elif not q and ch == "/" and k + 1 < end and _ig[k + 1] == "/":
				break
			elif not q and (ch == "{" or ch == "}"):
				braces.append(k)
			k += 1
		for n in range(braces.size() - 1, -1, -1):
			if _ig[braces[n]] == "}":
				depth += 1
			elif depth == 0:
				return braces[n]
			else:
				depth -= 1
		end = ls - 1
	return -1

## --wtest: prep's own test fixture items_game.txt read by this reader and by prep/items_game.py (run with the
## machine's python) must give every weapon the same attributes. Skipped where either is missing (an exported
## game has no prep folder beside it).
func _ig_parity() -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var fx := root.path_join("prep/tests/fixtures/items_game.txt")
	var py := root.path_join("prep/items_game.py")
	var names := ["weapon_ak47", "weapon_m4a1", "weapon_glock", "weapon_taser", "weapon_deagle"]
	if not FileAccess.file_exists(fx) or not FileAccess.file_exists(py):
		_check("items_game_parity", true, "skipped: no prep/tests fixture beside this build")
		return
	var out: Array = []
	var code := -1
	for exe in ["python3", "python"]:
		out.clear()
		code = OS.execute(exe, [py, fx] + names, out, true)
		if code == 0:
			break
	var want: Variant = JSON.parse_string(String(out[0]) if code == 0 and out.size() > 0 else "")
	if not (want is Dictionary):
		_check("items_game_parity", true, "skipped: no python to run prep/items_game.py (exit %d)" % code)
		return
	var keep := _ig
	var keep_p := _ig_prefabs
	_ig = FileAccess.get_file_as_string(fx)
	_ig_prefabs = _ig.find("\"prefabs\"")
	var bad: PackedStringArray = []
	for nm in names:
		var mine := ig_stats(nm)
		var theirs: Dictionary = want.get(nm, {})
		for k in theirs:
			if String(mine.get(k, "<none>")) != String(theirs[k]):
				bad.append("%s %s: gd %s py %s" % [nm, k, mine.get(k, "<none>"), theirs[k]])
		for k in mine:
			if not theirs.has(k):
				bad.append("%s %s: only gd" % [nm, k])
	_ig = keep
	_ig_prefabs = keep_p
	_check("items_game_parity", bad.is_empty() and want.size() == names.size(), "%d weapons of prep's fixture: %s" % [want.size(), "identical" if bad.is_empty() else "; ".join(bad.slice(0, 6))])

## --wtest: the whole stat path on prep's fixture items_game.txt (a CI run has no CS2 data, so every gun plays
## on class rows there): the AK's own recoil seed drives its table, the Deagle's item block is found with
## its sub-blocks ahead of "name", the Glock's burst comes from "has burst mode".
func _fixture_stats() -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var fx := root.path_join("prep/tests/fixtures/items_game.txt")
	if not FileAccess.file_exists(fx):
		_check("fixture_stats", true, "skipped: no prep/tests fixture beside this build")
		return
	var keep_st := _st.duplicate()
	var keep_stats := stats
	var keep_ig := _ig
	var keep_p := _ig_prefabs
	stats = {}
	_ig = FileAccess.get_file_as_string(fx)
	_ig_prefabs = _ig.find("\"prefabs\"")
	for id in ["cs2_ak47", "cs2_deagle", "cs2_glock"]:
		_resolve(id)
	_ig = keep_ig
	_ig_prefabs = keep_p
	_tables.clear()
	var tab := pattern("cs2_ak47", 0)
	var rs := SourceRandom.new()
	rs.set_seed(223)
	var a0 := rs.rand_float(-70.0, 70.0)
	var m0 := 30.0 + rs.rand_float(0.0, 0.0)
	var got := [stat("cs2_ak47", "recoil seed"), stat("cs2_ak47", "max player speed"), stat("cs2_deagle", "cycletime"), stat("cs2_deagle", "damage"), alt_kind("cs2_glock"), stat("cs2_glock", "cycletime alt")]
	var ok := got == [223.0, 215.0, 0.225, 63.0, "burst", 0.5] and tab.size() > 0 and is_equal_approx(tab[0].x, a0) and is_equal_approx(tab[0].y, m0)
	_st = keep_st
	stats = keep_stats
	_tables.clear()
	_check("fixture_stats", ok, "ak47 seed, speed / deagle cycletime, damage / glock alt, cooldown = %s; ak47 shot 1 (%.3f, %.2f) want seed-223 (%.3f, %.2f)" % [str(got), tab[0].x if tab.size() > 0 else -1.0, tab[0].y if tab.size() > 0 else -1.0, a0, m0])

## Just the prefab chain of one items_game entry: its "prefab" parents first, its own attributes on top.
func _ig_chain(name: String, seen: Dictionary) -> Dictionary:
	if seen.has(name) or seen.size() > 16:
		return {}
	seen[name] = true
	var blk := _ig_block(name)
	var out := {}
	for p in String(blk.get("prefab", "")).split(" ", false):
		out.merge(_ig_chain(p, seen), true)
	out.merge(_ig_attrs(blk), true)
	return out

## A block's attributes: "damage" "36", or the block form "damage" { "attribute_class" .. "value" "36" }.
func _ig_attrs(blk: Dictionary) -> Dictionary:
	var out := {}
	var at: Variant = blk.get("attributes", {})
	if at is Dictionary:
		for k in at:
			if not (at[k] is Dictionary):
				out[k] = at[k]
			elif at[k].has("value") and not (at[k]["value"] is Dictionary):
				out[k] = at[k]["value"]  # block form: "damage" { "attribute_class" .. "value" "36" }
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

## KeyValues block starting at the "{" at index i, read the way prep/items_game.py reads it: nested dicts,
## "//" comments skipped, escapes decoded, and [$PLATFORM] conditionals evaluated for Windows (a false one
## after a value drops that value, after a key it drops the block).
func _kv(i: int) -> Dictionary:
	var root := {}
	var stack: Array = []
	var cur := root
	var key := ""
	var has_key := false
	var undo: Array = []  # [block, key, had it, old value] of the last key/value, for a trailing conditional
	var skip := false     # the next block sits behind a false conditional
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
			e = n if e < 0 else e
			var cond := _ig.substr(i + 1, e - i - 1)
			i = e + 1
			if has_key:
				skip = not kv_cond(cond)
			elif not undo.is_empty():
				if not kv_cond(cond):
					var blk: Dictionary = undo[0]
					if undo[2]:
						blk[undo[1]] = undo[3]
					else:
						blk.erase(undo[1])
				undo = []
		elif ch == "{":
			var child := {}
			if not skip:
				child = cur.get(key) if cur.get(key) is Dictionary else {}
				cur[key] = child
			stack.append(cur)
			cur = child
			has_key = false
			undo = []
			skip = false
			i += 1
		elif ch == "}":
			if stack.is_empty():
				return root
			cur = stack.pop_back()
			has_key = false
			undo = []
			skip = false
			i += 1
		else:
			var tok := ""
			if ch == "\"":
				var j := i + 1
				while j < n and _ig[j] != "\"":
					if _ig[j] == "\\" and j + 1 < n:
						tok += String(KV_ESC.get(_ig[j + 1], "\\" + _ig[j + 1]))
						j += 2
					else:
						tok += _ig[j]
						j += 1
				i = j + 1
			else:
				var e := i
				while e < n and not " \t\r\n{}\"[".contains(_ig[e]):
					e += 1
				tok = _ig.substr(i, e - i)
				i = e
			if not has_key:
				key = tok
				has_key = true
				undo = []
			else:
				undo = [cur, key, cur.has(key), cur.get(key)]
				cur[key] = tok
				has_key = false
				skip = false
	return root

## A KeyValues conditional ($WIN32, !$X360, $WIN32||$OSX, $WINDOWS&&!$X360) on the Windows build.
static func kv_cond(expr: String) -> bool:
	for alt in expr.split("||"):
		var ok := true
		for t in alt.split("&&"):
			var tt := t.strip_edges()
			var neg := tt.begins_with("!")
			if (KV_DEFINES.has(tt.trim_prefix("!").strip_edges().to_upper())) == neg:
				ok = false
		if ok:
			return true
	return false

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
