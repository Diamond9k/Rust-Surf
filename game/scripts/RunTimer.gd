## systems.timer: start zone -> end zone, splits at checkpoints, PB on disk.
class_name RunTimer
extends Node

signal finished(time: float, is_pb: bool)

var running := false
var t := 0.0
var pb := -1.0
var splits := {}
var course_id: String

func setup(cid: String) -> void:
	course_id = cid
	var p := "user://pb_%s.json" % cid
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			pb = float(d.get("pb", -1.0))

func _process(dt: float) -> void:
	if running:
		t += dt

func on_zone(kind: String, id: String) -> void:
	match kind:
		"zone_start":
			reset()
		"checkpoint":
			if running:
				splits[id] = t
		"zone_end":
			if running:
				running = false
				var is_pb := pb < 0.0 or t < pb
				if is_pb:
					pb = t
					var f := FileAccess.open("user://pb_%s.json" % course_id, FileAccess.WRITE)
					f.store_string(JSON.stringify({"pb": pb, "splits": splits}))
				finished.emit(t, is_pb)

## The timer starts the tick the player leaves the start zone, like surf timers.
func start() -> void:
	if not running:
		running = true
		t = 0.0

func reset() -> void:
	running = false
	t = 0.0
	splits.clear()

static func fmt(sec: float) -> String:
	if sec < 0.0:
		return "--:--.---"
	var m := int(sec / 60.0)
	return "%02d:%06.3f" % [m, sec - m * 60.0]
