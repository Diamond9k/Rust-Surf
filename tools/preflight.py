"""Preflight: lay every sheet over every other and list what will fail.

Checks, per sheet and per table in it (rows, and every other list of rows such as weapon_defaults
mechanics or aim_lobby parts/props): every row has every column filled (the table's <name>_columns, else
columns for rows, else the keys its rows use) and a verification cell ('verified'/'tuned'/'status'/
'evidence'); every cross-sheet reference resolves; game/data/ and prep/ copies are byte-identical to
their sheet. Exit 1 if anything is unfinished, so a build only runs on a clean preflight.
A verification cell that says 'unverified' (or 'from memory', 'estimate', 'guess') is honest, not
unfinished: those cells are counted and listed (--list prints each one); --strict makes them failures.
check(root) -> (problems, unverified) for tools/package.py.
"""
import json, os, sys, glob

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


def check(root=ROOT):
    sd = os.path.join(root, "sheets")
    sheets = {}
    for p in sorted(glob.glob(os.path.join(sd, "*.json"))):
        with open(p, encoding="utf-8") as f:
            sheets[os.path.basename(p)[:-5]] = json.load(f)
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
                elif isinstance(v, str) and any(u in v.lower() for u in UNSURE):
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
    if problems:
        print(f"PREFLIGHT: {len(problems)} unfinished cell(s)")
        for p in problems:
            print("  -", p)
        return 1
    print("PREFLIGHT: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
