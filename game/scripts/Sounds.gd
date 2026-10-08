## systems.audio: one player per sounds.json row, fired by the triggers the sheet names.
class_name Sounds
extends Node

var players := {}
var rows := {}
var content: Content
var _speed_wind: AudioStreamPlayer
var _wind_db := -10.0

func setup(c: Content) -> void:
	content = c
	for r in Sheets.load_sheet("sounds")["rows"]:
		rows[r["id"]] = r
		var p := AudioStreamPlayer.new()
		p.name = r["id"]
		p.volume_db = float(r["volume_db"])
		var s := content.audio(r["content"], 1 if r["pick"] == "random" else -1)
		if s:
			_loop(s, bool(r["loop"]))
			p.stream = s
		add_child(p)
		players[r["id"]] = p
		if bool(r["loop"]) and r["id"] != "menu_music" and s:
			p.play()
	_speed_wind = players["speed_wind"]
	_wind_db = float(rows["speed_wind"]["volume_db"])

func _loop(s: AudioStream, on: bool) -> void:
	if s is AudioStreamWAV:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD if on else AudioStreamWAV.LOOP_DISABLED
		if on:
			s.loop_end = int(s.get_length() * s.mix_rate)
	elif s is AudioStreamMP3:
		s.loop = on

func play(id: String) -> void:
	var p: AudioStreamPlayer = players.get(id)
	if p == null:
		return
	if rows[id]["pick"] == "random":
		var s := content.audio(rows[id]["content"], randi_range(1, 4))
		if s:
			p.stream = s
	if p.stream:
		p.play()

## sounds.speed_wind: silent at 8 m/s, full at 40 m/s.
func set_speed(mps: float) -> void:
	if _speed_wind == null or _speed_wind.stream == null:
		return
	var k := clampf((mps - 8.0) / 32.0, 0.0, 1.0)
	_speed_wind.volume_db = _wind_db + linear_to_db(maxf(k, 0.001))

func music(on: bool) -> void:
	var p: AudioStreamPlayer = players.get("menu_music")
	if p and p.stream:
		if on and not p.playing:
			p.play()
		elif not on:
			p.stop()
