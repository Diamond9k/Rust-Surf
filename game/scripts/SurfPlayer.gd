## systems.movement: Source-engine player movement (CS:GO surf), every constant from movement.json.
## Runs at the fixed physics tick (64 Hz). Units are metres; the sheet keeps the Hammer originals.
class_name SurfPlayer
extends CharacterBody3D

signal jumped
signal landed(fall_speed: float)
signal footstep

var M := Sheets.movement()
var input: SurfInput
var cam: Camera3D
var yaw := 0.0
var pitch := 0.0
var grounded := false
var ground_normal := Vector3.UP
var ducked := false
var shape: BoxShape3D
var col: CollisionShape3D
var frozen := false
var _step_clock := 0.0
var _last_y_vel := 0.0
var last_hits: Array = []   # [normal, collider name, travel] per bump this tick (debug)

func _ready() -> void:
	shape = BoxShape3D.new()
	shape.size = Vector3(M["hull_width"], M["hull_height"], M["hull_width"])
	col = CollisionShape3D.new()
	col.shape = shape
	col.position.y = M["hull_height"] * 0.5
	add_child(col)
	cam = Camera3D.new()
	cam.fov = M["fov_default"]
	cam.near = 0.02
	cam.far = 4000.0
	cam.position.y = M["eye_height"]
	add_child(cam)
	safe_margin = 0.002
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Mouse look like Source: degrees = counts * m_yaw * sensitivity, from unscaled screen counts.
func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var d: Vector2 = ev.screen_relative
		yaw -= input.yaw_deg(d.x)
		pitch = clampf(pitch - input.pitch_deg(d.y), -89.0, 89.0)
		rotation_degrees.y = yaw
		cam.rotation_degrees.x = pitch

func teleport(pos: Vector3, yaw_deg: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	yaw = yaw_deg
	rotation_degrees.y = yaw
	grounded = false

func speed_units() -> float:
	return Vector2(velocity.x, velocity.z).length() / M["unit_to_m"]

func _physics_process(dt: float) -> void:
	if frozen:
		return
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var wish := Vector3.ZERO
	if Input.is_action_pressed("surf_forward"): wish += fwd
	if Input.is_action_pressed("surf_back"): wish -= fwd
	if Input.is_action_pressed("surf_right"): wish += right
	if Input.is_action_pressed("surf_left"): wish -= right
	wish.y = 0.0
	var wishspeed := 0.0
	if wish.length() > 0.0:
		wish = wish.normalized()
		wishspeed = M["max_ground_speed"]
	_duck(Input.is_action_pressed("surf_duck"))

	_categorize_position()
	if grounded and Input.is_action_pressed("surf_jump"):
		velocity.y = M["jump_impulse"]
		grounded = false
		jumped.emit()

	if grounded:
		velocity.y = 0.0
		_friction(dt)
		_accelerate(wish, wishspeed, M["accelerate"], dt)
		_step_sounds(dt)
	else:
		velocity.y -= M["gravity"] * dt * 0.5
		_air_accelerate(wish, wishspeed, M["air_accelerate"], dt)

	var was_grounded := grounded
	_last_y_vel = velocity.y
	if grounded:
		_step_move(dt)
	else:
		_try_player_move(dt)
	if not grounded:
		velocity.y -= M["gravity"] * dt * 0.5
	_clamp()
	_categorize_position()
	if grounded and not was_grounded and -_last_y_vel > 3.0:
		landed.emit(-_last_y_vel)

func _clamp() -> void:
	var mv: float = M["max_velocity"]
	velocity.x = clampf(velocity.x, -mv, mv)
	velocity.y = clampf(velocity.y, -mv, mv)
	velocity.z = clampf(velocity.z, -mv, mv)

## CategorizePosition: a short trace down; standable only when normal.y >= 0.7 (surf ramps are not).
func _categorize_position() -> void:
	if velocity.y > 180.0 * M["unit_to_m"]:
		grounded = false
		return
	var c := move_and_collide(Vector3(0, -2.0 * M["unit_to_m"] - safe_margin, 0), true)
	if c and c.get_normal().y >= M["ground_normal_min"]:
		if not grounded:
			global_position += c.get_travel()
		grounded = true
		ground_normal = c.get_normal()
	else:
		grounded = false

func _friction(dt: float) -> void:
	var speed := velocity.length()
	if speed < 0.0001:
		return
	var control: float = maxf(speed, M["stop_speed"])
	var drop: float = control * M["friction"] * dt
	velocity *= maxf(speed - drop, 0.0) / speed

func _accelerate(wishdir: Vector3, wishspeed: float, accel: float, dt: float) -> void:
	var addspeed := wishspeed - velocity.dot(wishdir)
	if addspeed <= 0.0:
		return
	velocity += minf(accel * dt * wishspeed, addspeed) * wishdir

## AirAccelerate: the wishspeed is capped at 30 u/s, which is what makes strafing gain speed.
func _air_accelerate(wishdir: Vector3, wishspeed: float, accel: float, dt: float) -> void:
	var wishspd: float = minf(wishspeed, M["air_speed_cap"])
	var addspeed := wishspd - velocity.dot(wishdir)
	if addspeed <= 0.0:
		return
	velocity += minf(accel * wishspeed * dt, addspeed) * wishdir

## ClipVelocity with overbounce: slide along the plane, never into it.
func _clip_velocity(v: Vector3, n: Vector3, overbounce: float) -> Vector3:
	var out := v - n * (v.dot(n) * overbounce)
	var adjust := out.dot(n)
	if adjust < 0.0:
		out -= n * adjust
	return out

## TryPlayerMove: up to 4 bumps, clipping against up to 5 planes, like gamemovement.cpp.
func _try_player_move(dt: float) -> void:
	var time_left := dt
	var original := velocity
	var primal := velocity
	var planes: Array[Vector3] = []
	last_hits.clear()
	for bump in range(4):
		if velocity.length_squared() == 0.0:
			break
		var want := velocity * time_left
		var c := move_and_collide(want)
		if c == null:
			break
		var frac := c.get_travel().length() / maxf(want.length(), 1e-9)
		time_left -= time_left * frac
		if planes.size() >= int(M["max_clip_planes"]):
			velocity = Vector3.ZERO
			break
		# Source: hitting a plane already in the list (same surface touched twice in one tick) nudges the
		# velocity 1 u/s off it instead of adding it again; a duplicate pair has no crease to slide along.
		var dup := false
		for pl in planes:
			if pl.dot(c.get_normal()) > 0.99:
				velocity += c.get_normal() * M["unit_to_m"]
				dup = true
				break
		if dup:
			continue
		planes.append(c.get_normal())
		last_hits.append([c.get_normal(), (c.get_collider() as Node).name if c.get_collider() else "?", c.get_travel(), c.get_position()])
		var i := 0
		var ok := false
		while i < planes.size():
			velocity = _clip_velocity(original, planes[i], M["overbounce"])
			ok = true
			for j in range(planes.size()):
				if j != i and velocity.dot(planes[j]) < -1e-6:
					ok = false
					break
			if ok:
				break
			i += 1
		if not ok:
			if planes.size() == 2:
				var dir := planes[0].cross(planes[1]).normalized()
				velocity = dir * dir.dot(velocity)
			else:
				velocity = Vector3.ZERO
				break
		if velocity.dot(primal) <= 0.0:
			velocity = Vector3.ZERO
			break

## StepMove: try the flat move, then an 18u step up + move + down; keep whichever went further.
func _step_move(dt: float) -> void:
	var start_pos := global_position
	var start_vel := velocity
	_try_player_move(dt)
	var flat_pos := global_position
	var flat_vel := velocity
	global_position = start_pos
	velocity = start_vel
	var up := Vector3(0, M["step_height"], 0)
	var c := move_and_collide(up)
	if c:
		up = c.get_travel()
	_try_player_move(dt)
	var down := move_and_collide(-up)
	if down and down.get_normal().y < M["ground_normal_min"]:
		global_position = flat_pos
		velocity = flat_vel
		return
	var flat_d := Vector2(flat_pos.x - start_pos.x, flat_pos.z - start_pos.z).length_squared()
	var step_d := Vector2(global_position.x - start_pos.x, global_position.z - start_pos.z).length_squared()
	if flat_d > step_d:
		global_position = flat_pos
		velocity = flat_vel
	else:
		velocity.y = flat_vel.y

func _duck(want: bool) -> void:
	if want == ducked:
		return
	ducked = want
	var h: float = M["duck_hull_height"] if ducked else M["hull_height"]
	shape.size = Vector3(M["hull_width"], h, M["hull_width"])
	col.position.y = h * 0.5
	cam.position.y = M["duck_eye_height"] if ducked else M["eye_height"]

## sounds.footstep: every 0.35 s while moving on the ground.
func _step_sounds(dt: float) -> void:
	if Vector2(velocity.x, velocity.z).length() < 0.5:
		_step_clock = 0.0
		return
	_step_clock += dt
	if _step_clock >= 0.35:
		_step_clock = 0.0
		footstep.emit()
