"""Weapon stats from the player's own CS2 scripts/items/items_game.txt (KeyValues text).
An item ("items" -> "7" -> name weapon_ak47) inherits its prefab chain ("prefab" "weapon_ak47_prefab",
which names "rifle", ...); attributes merge with the item's own values winning.
stats(path, names) -> {weapon_name: {attribute: value}} for the attributes the game uses."""
import json, sys

WANT = ["damage", "cycletime", "primary clip size", "primary reserve ammo max", "headshot multiplier",
        "range modifier", "range", "armor ratio", "is full auto", "max player speed", "bullets",
        "penetration", "spread", "inaccuracy stand", "inaccuracy crouch", "inaccuracy move",
        "inaccuracy jump", "inaccuracy fire", "recoil angle", "recoil angle variance", "recoil magnitude",
        "recoil magnitude variance", "recovery time stand", "zoom levels", "zoom fov 1", "zoom fov 2"]


def tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in "{}":
            yield c
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1]); j += 2
                else:
                    buf.append(text[j]); j += 1
            yield ("s", "".join(buf))
            i = j + 1
        elif c == "[":  # platform conditionals like [$WIN32]
            j = text.find("]", i)
            i = n if j < 0 else j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n{}\"":
                j += 1
            yield ("s", text[i:j])
            i = j


def parse(text):
    """Nested dicts; a key seen twice in one block merges when both are blocks, else the last wins."""
    root, stack, key = {}, [], None
    cur = root
    for t in tokens(text):
        if t == "{":
            child = cur.get(key) if isinstance(cur.get(key), dict) else {}
            cur[key] = child
            stack.append(cur)
            cur, key = child, None
        elif t == "}":
            cur = stack.pop() if stack else root
            key = None
        elif key is None:
            key = t[1]
        else:
            cur[key] = t[1]
            key = None
    return root


def _attrs(block):
    a = block.get("attributes", {})
    return {k: v for k, v in a.items() if not isinstance(v, dict)} if isinstance(a, dict) else {}


def stats(path, names):
    root = parse(open(path, encoding="utf-8", errors="replace").read())
    ig = root.get("items_game", root)
    prefabs = ig.get("prefabs", {})
    items = ig.get("items", {})

    def chain(block, seen):
        out = {}
        for p in str(block.get("prefab", "")).split():
            if p in prefabs and p not in seen:
                out.update(chain(prefabs[p], seen | {p}))
        out.update(_attrs(block))
        return out

    by_name = {}
    for k, it in items.items():
        if isinstance(it, dict) and it.get("name") in names:
            by_name[it["name"]] = it
    res = {}
    for n in names:
        it = by_name.get(n) or prefabs.get(n + "_prefab")
        if it is None:
            continue
        a = chain(it, set())
        res[n] = {k: a[k] for k in WANT if k in a}
    return res


if __name__ == "__main__":
    print(json.dumps(stats(sys.argv[1], sys.argv[2:]), indent=1))
