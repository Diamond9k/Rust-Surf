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
