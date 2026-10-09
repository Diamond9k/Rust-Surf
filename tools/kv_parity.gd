## tools/kv_parity.gd: the game's own items_game reader (Weapons._kv / _ig_chain) on one file, for
## tools/package.py and prep/tests/test_kv_parity.py, which compare it with prep/items_game.py.
## usage: Godot --headless --path game --script <this file> -- <items_game.txt> <out.json> <weapon_x> ...
## Writes {weapon_x: {attribute: value}} from each weapon's <weapon_x>_prefab chain, then prints KVPARITY done.
extends SceneTree

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 2:
		print("KVPARITY FAIL usage: -- <items_game.txt> <out.json> <weapon_x> ...")
		quit(2)
		return
	var w: Node = load("res://scripts/Weapons.gd").new()
	w._ig = FileAccess.get_file_as_string(a[0])
	w._ig_prefabs = w._ig.find("\"prefabs\"")
	var out := {}
	for i in range(2, a.size()):
		var chain: Dictionary = w._ig_chain(a[i] + "_prefab", {})
		if not chain.is_empty():
			out[a[i]] = chain
	w.free()
	var f := FileAccess.open(a[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " ", true))
	f.close()
	print("KVPARITY done %d" % out.size())
	quit(0)
