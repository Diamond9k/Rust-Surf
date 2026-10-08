## systems.hud: speed in u/s like a surf server, timer, PB, the CS2 crosshair of the player, errors.
class_name Hud
extends CanvasLayer

var speed_label: Label
var timer_label: Label
var pb_label: Label
var msg_label: Label
var err_label: Label
var crosshair: Control
var convars := {}

func setup(cv: Dictionary) -> void:
	convars = cv
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	speed_label = _label(root, Control.PRESET_CENTER_BOTTOM, 40, Vector2(0, -80))
	timer_label = _label(root, Control.PRESET_TOP_RIGHT, 28, Vector2(-220, 20))
	pb_label = _label(root, Control.PRESET_TOP_RIGHT, 18, Vector2(-220, 60))
	msg_label = _label(root, Control.PRESET_CENTER, 36, Vector2(-200, -120))
	err_label = _label(root, Control.PRESET_TOP_LEFT, 16, Vector2(20, 20))
	err_label.modulate = Color(1, 0.4, 0.4)
	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.draw.connect(_draw_crosshair)
	root.add_child(crosshair)

func _label(parent: Control, preset: int, size: int, offset: Vector2) -> Label:
	var l := Label.new()
	l.set_anchors_preset(preset)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.position += offset
	parent.add_child(l)
	return l

## cl_crosshair* convars drawn like the CS2 classic static crosshair.
func _draw_crosshair() -> void:
	var size := float(convars.get("cl_crosshairsize", "5")) * 2.0
	var gap := float(convars.get("cl_crosshairgap", "1")) * 2.0 + 4.0
	var th: float = maxf(float(convars.get("cl_crosshairthickness", "0.5")) * 2.0, 1.0)
	var colors := {"0": Color(1, 0, 0), "1": Color(0, 1, 0), "2": Color(1, 1, 0), "3": Color(0, 0, 1), "4": Color(0, 1, 1), "5": Color(1, 1, 1)}
	var c: Color = colors.get(str(convars.get("cl_crosshaircolor", "1")), Color(0, 1, 0))
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		crosshair.draw_line(d * gap, d * (gap + size), c, th)
	if str(convars.get("cl_crosshairdot", "false")) == "true":
		crosshair.draw_rect(Rect2(-th, -th, th * 2, th * 2), c)

func update(speed_u: float, t: float, pb: float, running: bool) -> void:
	speed_label.text = "%d u/s" % int(speed_u)
	timer_label.text = RunTimer.fmt(t) if running or t > 0.0 else "ready"
	pb_label.text = "PB " + RunTimer.fmt(pb)

func message(s: String, seconds: float = 2.5) -> void:
	msg_label.text = s
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(func() -> void:
			if msg_label.text == s:
				msg_label.text = "")

func errors(lines: PackedStringArray) -> void:
	err_label.text = "\n".join(lines)
