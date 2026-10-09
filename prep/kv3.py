"""KeyValues3 text (what Source2Viewer-CLI writes for a decompiled .vdata_c) and weapon stats from it.
CS2 may keep live weapon stats in scripts/weapons.vdata rather than in items_game.txt attributes; prep reads
it as a second source for any stat items_game.txt does not give. The file path, its layout and its field
names are unverified here (no real CS2 file has been read): sheets/prep.json vdata_keys maps each field to
the items_game attribute name Weapons.gd reads, and every row of that table is marked unverified.
parse(text) -> dict; vdata_stats(path, names, keymap) -> {weapon_name: {attribute: value string}}."""
import re

_NUM = re.compile(r"-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$")


class KV3Error(ValueError):
    pass


def tokens(text):
    """Punctuation ({ } [ ] = ,), strings (s, text) and bare words (w, text). Comments, the <!-- kv3 --> header
    and flags such as resource_name: are dropped; #[ binary ] blobs become one bare word."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n﻿":
            i += 1
        elif text.startswith("<!--", i):
            j = text.find("-->", i)
            i = n if j < 0 else j + 3
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i)
            i = n if j < 0 else j + 2
        elif c in "{}[]=,":
            yield (c,)
            i += 1
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            if j < 0:
                raise KV3Error("unterminated multi-line string")
            yield ("s", text[i + 3:j].strip("\r\n"))
            i = j + 3
        elif c == '"':
            j, buf = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf.append({"n": "\n", "t": "\t"}.get(text[j + 1], text[j + 1])); j += 2
                else:
                    buf.append(text[j]); j += 1
            if j >= n:
                raise KV3Error("unterminated string")
            yield ("s", "".join(buf))
            i = j + 1
        elif text.startswith("#[", i):
            j = text.find("]", i)
            if j < 0:
                raise KV3Error("unterminated binary blob")
            yield ("w", text[i:j + 1])
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n{}[]=,\"":
                j += 1
            word = text[i:j]
            i = j
            if word.endswith(":") and i < n and text[i] in "\"{[":
                continue  # a flag (resource_name:"...", subclass:{...}): the value follows
            if ":" in word and not _NUM.match(word):
                word = word.split(":", 1)[1] if word.split(":", 1)[1] else word
            yield ("w", word)


def _value(t):
    if t[0] == "s":
        return t[1]
    w = t[1]
    if w == "true":
        return True
    if w == "false":
        return False
    if w == "null":
        return None
    if _NUM.match(w):
        return float(w) if any(ch in w for ch in ".eE") else int(w)
    return w


def parse(text):
    """The whole document as nested dicts and lists. Raises KV3Error on unbalanced input, so a cut-off
    export is never read as a complete one."""
    toks = list(tokens(text))
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        t = peek()
        if t is None:
            raise KV3Error("unexpected end of file")
        pos[0] += 1
        return t

    def value():
        t = take()
        if t[0] == "{":
            return obj()
        if t[0] == "[":
            return arr()
        if t[0] in ("s", "w"):
            return _value(t)
        raise KV3Error("unexpected %r" % (t[0],))

    def obj():
        out = {}
        while True:
            t = take()
            if t[0] == "}":
                return out
            if t[0] == ",":
                continue
            if t[0] not in ("s", "w"):
                raise KV3Error("expected a key, got %r" % (t[0],))
            if take()[0] != "=":
                raise KV3Error("expected = after %s" % t[1])
            out[t[1]] = value()

    def arr():
        out = []
        while True:
            t = peek()
            if t is None:
                raise KV3Error("unexpected end of file in a list")
            if t[0] == "]":
                pos[0] += 1
                return out
            if t[0] == ",":
                pos[0] += 1
                continue
            out.append(value())

    if not toks or toks[0][0] != "{":
        raise KV3Error("not a KeyValues3 document")
    pos[0] = 1
    root = obj()
    if pos[0] != len(toks):
        raise KV3Error("text after the closing brace")
    return root


def whole(path):
    """True when the file is a complete KV3 document (prep_cs2.file_ok for .vdata)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            parse(f.read())
        return True
    except (OSError, KV3Error, RecursionError):
        return False


def _find(node, name, depth=0):
    """The first dict keyed name anywhere under node (the vdata layout is unverified, so no fixed path)."""
    if depth > 8:
        return None
    if isinstance(node, dict):
        if isinstance(node.get(name), dict):
            return node[name]
        for v in node.values():
            r = _find(v, name, depth + 1)
            if r is not None:
                return r
    elif isinstance(node, list):
        for v in node:
            r = _find(v, name, depth + 1)
            if r is not None:
                return r
    return None


def _num(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str) and _NUM.match(v.strip()):
        return v.strip()
    return None


def _pair(v):
    """A plain value, a [primary, alt] list, or a block holding one such list (CFiringModeFloat-style)."""
    if isinstance(v, dict):
        lists = [x for x in v.values() if isinstance(x, list)]
        v = lists[0] if len(lists) == 1 else None
    if isinstance(v, list):
        return (_num(v[0]) if v else None), (_num(v[1]) if len(v) > 1 else None)
    return _num(v), None


def vdata_stats(path, names, keymap):
    """{weapon name: {items_game attribute: value}} for the names the file has. keymap: vdata_keys rows
    (id = vdata field, attribute, attribute_alt or "-"). An entry's "_base" (another entry) is merged under it."""
    with open(path, encoding="utf-8", errors="replace") as f:
        root = parse(f.read())
    res = {}
    for n in names:
        e = _find(root, n)
        if e is None:
            continue
        seen = {n}
        base = e.get("_base")
        while isinstance(base, str) and base not in seen:
            seen.add(base)
            b = _find(root, base)
            if b is None:
                break
            e = dict(b, **e)
            base = b.get("_base")
        out = {}
        for k in keymap:
            if k["id"] not in e:
                continue
            v, alt = _pair(e[k["id"]])
            if v is not None:
                out[k["attribute"]] = v
            if alt is not None and k["attribute_alt"] not in ("", "-"):
                out[k["attribute_alt"]] = alt
        if out:
            res[n] = out
    return res
