"""Preflight: lay every sheet over every other and list what will fail.

Checks, per sheet and per table in it (rows, and every other list of rows such as weapon_defaults
mechanics or aim_lobby parts/props): every row has every column filled (the table's <name>_columns, else
columns for rows, else the keys its rows use) and a verification cell ('verified'/'tuned'/'status'/
'evidence'); every cross-sheet reference resolves; game/data/ and prep/ copies are byte-identical to
their sheet. Exit 1 if anything is unfinished, so a build only runs on a clean preflight.
A verification cell that says 'unverified' (or 'from memory', 'estimate', 'guess') is honest, not
unfinished: those cells are counted and listed (--list prints each one); --strict makes them failures.
Gameplay-critical unverified rows (the sheets tools/unverified_ack.json names as critical: the CS weapon, scoring
and crosshair numbers) are a release decision, not a count: each one is acknowledged in that file with a hash of
the whole row, and tools/package.py refuses a release while one is new or has changed since it was acknowledged
(--critical lists them; --ack records the current rows as accepted, which is the decision, so review first).
check(root) -> (problems, unverified) and critical_unacked(root) -> [row] for tools/package.py.
"""
import json, os, sys, glob, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = ("verified", "tuned", "status", "evidence")
UNSURE = ("unverified", "not verified", "from memory", "estimate", "guess")


def tables(s):
    """(table name, columns, rows) for every list of row dicts in a sheet."""
    for k, v in s.items():
        if k.endswith("_columns") or k == "columns" or not isinstance(v, list) or not v or not all(isinstance(r, dict) for r in v):
            continue
        cols = s.get(k + "_columns") or (s.get("columns") if k == "rows" else None)
        if cols is None:
            cols = []
            for r in v:
                cols += [c for c in r if c not in cols]
        yield k, cols, v


def load_sheets(root):
    sheets = {}
    for p in sorted(glob.glob(os.path.join(root, "sheets", "*.json"))):
        with open(p, encoding="utf-8") as f:
            sheets[os.path.basename(p)[:-5]] = json.load(f)
    return sheets


def is_unsure(v):
    return isinstance(v, str) and any(u in v.lower() for u in UNSURE)


ACK = os.path.join("tools", "unverified_ack.json")


def unsure_rows(root, sheet_names=None):
    """{"sheet[.table].row id": sha256 of the whole row (first 16 hex)} for every row whose verification cell is
    labelled unverified, in sheet_names (None: every sheet)."""
    out = {}
    for name, s in load_sheets(root).items():
        if sheet_names is not None and name not in sheet_names:
            continue
        for t, cols, rows in tables(s):
            vcol = [c for c in VERIFY if c in cols]
            for r in rows if vcol else []:
                if is_unsure(r.get(vcol[0])):
                    where = name if t == "rows" else "%s.%s" % (name, t)
                    out["%s.%s" % (where, r.get("id", "?"))] = hashlib.sha256(json.dumps(r, sort_keys=True).encode("utf-8")).hexdigest()[:16]
    return out


def load_ack(root):
    """tools/unverified_ack.json: {"critical": [sheet names], "rows": {key: hash}, ...}; an empty record when missing."""
    try:
        with open(os.path.join(root, ACK), encoding="utf-8") as f:
            ack = json.load(f)
    except (OSError, ValueError):
        return {"critical": [], "rows": {}}
    ack.setdefault("rows", {})
    ack.setdefault("critical", [])
    return ack


def critical_unacked(root):
    """Gameplay-critical unverified rows that are new or changed since tools/unverified_ack.json acknowledged them,
    as "key (new)" / "key (changed)". No ack file (or one naming no critical sheet) is itself a problem."""
    ack = load_ack(root)
    if not ack["critical"]:
        return ["%s is missing or names no critical sheets, so no gameplay-critical unverified row has been reviewed" % ACK.replace(os.sep, "/")]
    now = unsure_rows(root, set(ack["critical"]))
    return ["%s (%s)" % (k, "new" if k not in ack["rows"] else "changed") for k, h in sorted(now.items()) if ack["rows"].get(k) != h]


def write_ack(root):
    """Records every current critical unverified row as accepted; returns (added or changed, dropped) keys."""
    ack = load_ack(root)
    now = unsure_rows(root, set(ack["critical"]))
    changed = sorted(k for k, h in now.items() if ack["rows"].get(k) != h)
    dropped = sorted(k for k in ack["rows"] if k not in now)
    ack["rows"] = dict(sorted(now.items()))
    tmp = os.path.join(root, ACK) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ack, f, indent=1)
        f.write("\n")
    os.replace(tmp, os.path.join(root, ACK))
    return changed, dropped


def check(root=ROOT):
    sheets = load_sheets(root)
    problems, unsure = [], []

    # 1. every cell filled, every row verified, in every table
    for name, s in sheets.items():
        for t, cols, rows in tables(s):
            where = name if t == "rows" else "%s.%s" % (name, t)
            vcol = [c for c in VERIFY if c in cols]
            if not vcol:
                problems.append("%s: no verification column (one of %s)" % (where, ", ".join(VERIFY)))
            for r in rows:
                rid = r.get("id", "?")
                for c in cols:
                    if c not in r:
                        problems.append("%s.%s: column '%s' missing" % (where, rid, c))
                    elif r[c] in ("", None) or r[c] == [] or r[c] == {}:
                        problems.append("%s.%s: cell '%s' is empty" % (where, rid, c))
                for c in [x for x in r if x not in cols]:
                    problems.append("%s.%s: cell '%s' has no column" % (where, rid, c))
                if not vcol:
                    continue
                v = r.get(vcol[0])
                if v in (False, "", None) or (isinstance(v, str) and v.lower().startswith(("pending", "tbd", "to "))):
                    problems.append("%s.%s: unfinished %s (%r)" % (where, rid, vcol[0], v))
                elif is_unsure(v):
                    unsure.append("%s.%s: %s" % (where, rid, v))
                if r.get("status") in ("planned", "written"):
                    problems.append("%s.%s: status %s (needs 'tested')" % (where, rid, r["status"]))

    def ids(n, t="rows"):
        return {r["id"] for r in sheets[n][t]}

    # 2. references
    content = ids("content")
    for r in sheets["materials"]["rows"]:
        for c in ("albedo", "normal"):
            if r[c] and r[c] != "(none)" and r[c] not in content:
                problems.append(f"materials.{r['id']}: {c} '{r[c]}' not in content")
    mats = ids("materials")
    for r in sheets["course"]["rows"]:
        if r["material"] not in mats:
            problems.append(f"course.{r['id']}: material '{r['material']}' not in materials")
        if r["kind"] == "ramp" and r["shape"] not in ("ridge", "valley"):
            problems.append(f"course.{r['id']}: ramp shape '{r['shape']}'")
    for r in sheets["sounds"]["rows"]:
        if r["content"] not in content:
            problems.append(f"sounds.{r['id']}: content '{r['content']}' not in content")
    games = ids("games")
    for r in sheets["content"]["rows"] + sheets["hooks"]["rows"]:
        if r["game"] not in games:
            problems.append(f"content/hooks.{r['id']}: game '{r['game']}' not in games")
    for r in sheets["systems"]["rows"]:
        for ref in r["reads"].replace(",", " ").split():
            if ref.endswith(".json") and ref[:-5] not in sheets:
                problems.append(f"systems.{r['id']}: reads unknown sheet {ref}")
        if not os.path.exists(os.path.join(root, r["script"])):
            problems.append(f"systems.{r['id']}: script {r['script']} does not exist")
    prep = {r["id"]: r["value"] for r in sheets["prep"]["rows"]}
    filled = {r["attribute"] for r in sheets["prep"].get("vdata_keys", [])}
    for k in ("stats_required", "stats_required_light", "stats_expected"):
        for a in str(prep.get(k, "")).split(","):
            if a.strip() and a.strip() not in filled:
                problems.append(f"prep.{k}: '{a.strip()}' is not an attribute any vdata_keys row fills")
    wslots = {r["slot"] for r in sheets["weapons"]["rows"]}
    for sl in str(prep.get("stats_light_slots", "")).split(","):
        if sl.strip() and sl.strip() not in wslots:
            problems.append(f"prep.stats_light_slots: '{sl.strip()}' is no weapons.json slot")

    # 3. copies: game/data/ and prep/ ship byte-identical copies of the sheets (tools/package.py checks the same)
    sys.path.insert(0, os.path.join(root, "tools"))
    import package
    problems += package.check_copies(root)

    for k, v in sheets["credits"].get("listing", {}).items():
        if isinstance(v, str) and v.upper().startswith("TBD"):
            problems.append(f"credits.listing.{k}: {v}")
    return problems, unsure


def main(argv):
    if "--ack" in argv:
        changed, dropped = write_ack(ROOT)
        print("ACK: %d critical unverified row(s) accepted as new or changed, %d no longer unverified dropped" % (len(changed), len(dropped)))
        for k in changed:
            print("  +", k)
        for k in dropped:
            print("  -", k)
    problems, unsure = check(ROOT)
    if "--strict" in argv:
        problems += ["unverified: " + u for u in unsure]
    by = {}
    for u in unsure:
        by[u.split(".")[0]] = by.get(u.split(".")[0], 0) + 1
    print("UNVERIFIED: %d cell(s) honestly labelled (%s)%s" % (len(unsure), ", ".join("%s %d" % kv for kv in sorted(by.items())),
                                                              "" if "--list" in argv else "; --list prints them"))
    if "--list" in argv:
        for u in unsure:
            print("  ~", u)
    crit = critical_unacked(ROOT)
    print("CRITICAL UNVERIFIED: %d gameplay row(s) new or changed since %s (a release refuses them; review, then --ack)%s"
          % (len(crit), ACK.replace(os.sep, "/"), "" if "--critical" in argv or not crit else "; --critical lists them"))
    if "--critical" in argv:
        for c in crit:
            print("  !", c)
    if problems:
        print(f"PREFLIGHT: {len(problems)} unfinished cell(s)")
        for p in problems:
            print("  -", p)
        return 1
    print("PREFLIGHT: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
