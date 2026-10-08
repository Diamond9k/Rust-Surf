## systems.content_loader: the output file of every content.json row, loaded from the data folder on demand.
class_name Content
extends RefCounted

var dir: String
var rows := {}
var cache := {}
var missing: PackedStringArray = []

func _init(data_dir: String) -> void:
	dir = data_dir
	for r in Sheets.load_sheet("content")["rows"]:
		rows[r["id"]] = r

func path_of(id: String) -> String:
	return dir.path_join(String(rows[id]["out"]).split(" ")[0])

func _miss(id: String) -> void:
	if not missing.has(id):
		missing.append(id)

func texture(id: String, suffix: String = "MainTex") -> Texture2D:
	var key := id + ":" + suffix
	if cache.has(key):
		return cache[key]
	var p := path_of(id).replace("{MainTex,BumpMap}", suffix).replace("{albedo,normal}", "albedo" if suffix == "MainTex" else "normal")
	var img := Image.new()
	if img.load(p) != OK:
		_miss(id)
		return null
	var t := ImageTexture.create_from_image(img)
	cache[key] = t
	return t

func audio(id: String, index: int = -1) -> AudioStream:
	var p := path_of(id)
	if index >= 0:
		p = p.replace("{1..4}", str(index))
	if cache.has(p):
		return cache[p]
	var s: AudioStream = null
	if FileAccess.file_exists(p):
		if p.ends_with(".wav"):
			s = AudioStreamWAV.load_from_file(p)
		elif p.ends_with(".mp3"):
			s = AudioStreamMP3.load_from_file(p)
	if s == null:
		_miss(id)
		return null
	cache[p] = s
	return s

## A .glb exported by prep (Rust meshes, CS2 models and clips) as a fresh scene.
func glb(path_abs: String) -> Node3D:
	if cache.has(path_abs):
		return cache[path_abs].duplicate()
	if not FileAccess.file_exists(path_abs):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path_abs, state) != OK:
		push_error("content: bad glb " + path_abs)
		return null
	var scene := doc.generate_scene(state)
	cache[path_abs] = scene
	return scene.duplicate()

## Cached glTF scenes live outside the tree; free them before the renderer shuts down.
func dispose() -> void:
	for k in cache.keys():
		var v: Variant = cache[k]
		if v is Node and is_instance_valid(v):
			(v as Node).free()
	cache.clear()

func glb_of(id: String) -> Node3D:
	var s := glb(path_of(id))
	if s == null:
		_miss(id)
	return s

func json(id: String) -> Variant:
	if not FileAccess.file_exists(path_of(id)):
		_miss(id)
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path_of(id)))
