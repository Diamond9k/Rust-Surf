## The sheets are the source of truth; they ship inside the game at res://data/<sheet>.json.
class_name Sheets
extends RefCounted

static var _cache := {}

static func load_sheet(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var p := "res://data/%s.json" % name
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	assert(d is Dictionary, "sheet missing: " + p)
	_cache[name] = d
	return d

## movement.json rows as id -> value_m (metres).
static func movement() -> Dictionary:
	var out := {}
	for r in load_sheet("movement")["rows"]:
		out[r["id"]] = float(r["value_m"])
	return out

## Source horizontal fov at 4:3 -> vertical fov in degrees (CS2 fov_cs_debug 90, viewmodel_fov 68).
static func vfov_43(hfov_deg: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(hfov_deg) * 0.5) * 0.75))

## A sheet of id -> value rows as a Dictionary (value may be a number, string or array).
static func values(name: String) -> Dictionary:
	var out := {}
	for r in load_sheet(name)["rows"]:
		out[r["id"]] = r["value"]
	return out
