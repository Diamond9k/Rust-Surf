"""Preflight: lay every sheet over every other and list what will fail.

Checks, per sheet: every row has every column filled; every cross-sheet reference
resolves; every 'verified'/'tuned'/'status' cell is actually checked. Exit 1 if
anything is unfinished, so a build only runs on a clean preflight.
"""
import json, os, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEETS = os.path.join(ROOT, "sheets")
problems = []


def load(name):
    with open(os.path.join(SHEETS, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def ids(sheet):
    return {r["id"] for r in sheet["rows"]}


sheets = {os.path.basename(p)[:-5]: load(os.path.basename(p)[:-5]) for p in glob.glob(os.path.join(SHEETS, "*.json"))}

# 1. every cell filled
for name, s in sheets.items():
    for r in s["rows"]:
        for c in s["columns"]:
            if c not in r:
                problems.append(f"{name}.{r.get('id','?')}: column '{c}' missing")
            elif r[c] in ("", None):
                problems.append(f"{name}.{r.get('id','?')}: cell '{c}' is empty")
        # verification cells
        v = r.get("verified", r.get("tuned", r.get("status")))
        if v in (False, "", None) or (isinstance(v, str) and v.lower().startswith(("pending", "tbd", "to "))):
            problems.append(f"{name}.{r['id']}: unverified ({v!r})")
        if r.get("status") in ("planned", "written"):
            problems.append(f"{name}.{r['id']}: status {r['status']} (needs 'tested')")

# 2. references
content = ids(sheets["content"])
for r in sheets["materials"]["rows"]:
    for c in ("albedo", "normal"):
        if r[c] and r[c] != "(none)" and r[c] not in content:
            problems.append(f"materials.{r['id']}: {c} '{r[c]}' not in content")
mats = ids(sheets["materials"])
for r in sheets["course"]["rows"]:
    if r["material"] not in mats:
        problems.append(f"course.{r['id']}: material '{r['material']}' not in materials")
    if r["kind"] == "ramp" and r["shape"] not in ("ridge", "valley"):
        problems.append(f"course.{r['id']}: ramp shape '{r['shape']}'")
for r in sheets["sounds"]["rows"]:
    if r["content"] not in content:
        problems.append(f"sounds.{r['id']}: content '{r['content']}' not in content")
games = ids(sheets["games"])
for r in sheets["content"]["rows"] + sheets["hooks"]["rows"]:
    if r["game"] not in games:
        problems.append(f"content/hooks.{r['id']}: game '{r['game']}' not in games")
for r in sheets["systems"]["rows"]:
    for ref in r["reads"].replace(",", " ").split():
        if ref.endswith(".json") and ref[:-5] not in sheets:
            problems.append(f"systems.{r['id']}: reads unknown sheet {ref}")
    script = os.path.join(ROOT, r["script"])
    if not os.path.exists(script):
        problems.append(f"systems.{r['id']}: script {r['script']} does not exist")
lst = sheets["credits"].get("listing", {})
for k, v in lst.items():
    if isinstance(v, str) and v.upper().startswith("TBD"):
        problems.append(f"credits.listing.{k}: {v}")

if problems:
    print(f"PREFLIGHT: {len(problems)} unfinished cell(s)")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("PREFLIGHT: clean")
