"""Weapon stats from the player's own CS2 scripts/items/items_game.txt (KeyValues text).
An item ("items" -> "7" -> name weapon_ak47) inherits its prefab chain ("prefab" "weapon_ak47_prefab",
which names "rifle", ...); attributes merge with the item's own values winning.
Platform conditionals ([$WIN32], [!$X360]) are evaluated for Windows; escapes (\\" \\n \\\\) are decoded.
stats(path, names) -> {weapon_name: {attribute: value}}, every attribute of the chain (Weapons.gd picks).
The structure is the one CS:GO's items_game.txt used; the real CS2 file is unverified here (see MODLOG)."""
import json, sys

ESCAPES = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}
# Platform defines KeyValues conditionals test: prep runs on Windows for the Windows CS2 build.
DEFINES = {"$WIN32", "$WIN64", "$WINDOWS", "$PC"}


def cond_true(expr):
    """[$WIN32], [!$X360], [$WIN32||$OSX], [$WINDOWS&&!$X360] against DEFINES."""
    def term(t):
        t = t.strip()
        neg = t.startswith("!")
        return (t.lstrip("!").strip().upper() in DEFINES) != neg
    return any(all(term(t) for t in alt.split("&&")) for alt in expr.split("||"))


def tokens(text, strict=False):
    """("{",) ("}",) ("s", string) ("c", conditional) from KeyValues text. strict: an unterminated string
    or conditional raises ValueError instead of running to the end of the text."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n﻿":
            i += 1
        elif c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in "{}":
            yield (c,)
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf.append(ESCAPES.get(text[j + 1], "\\" + text[j + 1])); j += 2
                else:
                    buf.append(text[j]); j += 1
            if strict and j >= n:
                raise ValueError("unterminated string")
            yield ("s", "".join(buf))
            i = j + 1
        elif c == "[":
            j = text.find("]", i)
            if strict and j < 0:
                raise ValueError("unterminated conditional")
            j = n if j < 0 else j
            yield ("c", text[i + 1:j])
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n{}\"[":
                j += 1
            yield ("s", text[i:j])
            i = j


def parse(text):
    """Nested dicts. A key seen twice in one block merges when both are blocks, else the last wins.
    A conditional after a value drops that value when false; after a key, it drops the block."""
    root, stack, key = {}, [], None
    cur = root
    undo = None      # (block, key, previous value or _NONE) of the last key/value, for a trailing conditional
    skip = False     # the next block belongs to a false conditional
    for t in tokens(text):
        if t[0] == "{":
            if skip:
                child = {}
            else:
                child = cur.get(key) if isinstance(cur.get(key), dict) else {}
                cur[key] = child
            stack.append(cur)
            cur, key, undo, skip = child, None, None, False
        elif t[0] == "}":
            cur = stack.pop() if stack else root
            key, undo, skip = None, None, False
        elif t[0] == "c":
            if key is not None:
                skip = not cond_true(t[1])
            elif undo is not None:
                if not cond_true(t[1]):
                    blk, k, old = undo
                    if old is _NONE:
                        blk.pop(k, None)
                    else:
                        blk[k] = old
                undo = None
        elif key is None:
            key, undo = t[1], None
        else:
            undo = (cur, key, cur.get(key, _NONE))
            cur[key] = t[1]
            key, skip = None, False
    return root


_NONE = object()


def whole(path):
    """True when the file is complete KeyValues text: at least one block, every brace and string closed
    (an export cut short parses into a partial tree, so prep_cs2.file_ok asks this first)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        depth, blocks = 0, 0
        for t in tokens(text, strict=True):
            if t[0] == "{":
                depth += 1
                blocks += 1
            elif t[0] == "}":
                depth -= 1
                if depth < 0:
                    return False
        return depth == 0 and blocks > 0
    except (OSError, ValueError):
        return False


def _attrs(block):
    """An item's attributes: "damage" "36", or the block form "name" { "attribute_class" .. "value" "36" }."""
    a = block.get("attributes", {})
    if not isinstance(a, dict):
        return {}
    out = {}
    for k, v in a.items():
        if isinstance(v, dict):
            if "value" in v and not isinstance(v["value"], dict):
                out[k] = v["value"]
        else:
            out[k] = v
    return out


def stats(path, names):
    """{weapon_name: every attribute of its prefab chain} for the names found (missing names are left out)."""
    with open(path, encoding="utf-8", errors="replace") as f:
        root = parse(f.read())
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
        res[n] = dict(sorted(a.items()))
    return res


if __name__ == "__main__":
    print(json.dumps(stats(sys.argv[1], sys.argv[2:]), indent=1))
