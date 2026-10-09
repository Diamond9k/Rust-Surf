"""Builds the Melty release zip: game build + prep bundle + licenses + README, and refuses to build one
that would install broken.
usage: package.py [<version>] [--skip-pck-scan]  -> dist/RustSurf-<version>.zip, dist/RustSurf-<version>.entries.json
Checks before zipping (each failure is listed, nothing is written):
- melty.recipe.json names one x.y.z everywhere and it is the version asked for; README.md names it too
- every sheets/*.json equals game/data/<name>.json and every prep/*.json equals its sheet (no stray copies)
- dist/RustSurf has RustSurf.exe and RustSurf.pck, and the pck lists data/<sheet>.json for every sheet
- the prep bundle has python.exe, vrf/Source2Viewer-CLI.exe, vgm/vgmstream-cli.exe and, after the repo's
  prep sources are copied in, every prep/*.py and *.json byte for byte
Then the zip is read back: it must open, pass its CRCs and hold every required entry."""
import os, re, sys, json, glob, shutil, hashlib, zipfile, filecmp

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE_TOOLS = ["python.exe", "vrf/Source2Viewer-CLI.exe", "vgm/vgmstream-cli.exe"]


def recipe_version(root):
    with open(os.path.join(root, "melty.recipe.json"), encoding="utf-8") as f:
        recipe = json.load(f)
    rver = recipe["components"][0]["fileName"][len("RustSurf-"):-len(".zip")]
    found = set(re.findall(r"\d+\.\d+\.\d+", json.dumps(recipe)))
    errs = [] if found == {rver} else ["melty.recipe.json names more than one version: %s" % sorted(found)]
    return rver, errs


def check_readme(root, ver):
    with open(os.path.join(root, "README.md"), encoding="utf-8") as f:
        text = f.read()
    return [] if ver in text else ["README.md does not mention version %s (it ships in the zip as the only doc)" % ver]


def prep_sources(root):
    return sorted(f for f in os.listdir(os.path.join(root, "prep")) if f.endswith((".py", ".json")))


def check_copies(root):
    """sheets/ is the source of truth; game/data/ and prep/ hold byte-identical copies."""
    errs = []
    sheets = {os.path.basename(p) for p in glob.glob(os.path.join(root, "sheets", "*.json"))}
    data = {os.path.basename(p) for p in glob.glob(os.path.join(root, "game", "data", "*.json"))}
    for n in sorted(sheets):
        if n not in data:
            errs.append("game/data/%s missing (copy sheets/%s)" % (n, n))
        elif not filecmp.cmp(os.path.join(root, "sheets", n), os.path.join(root, "game", "data", n), shallow=False):
            errs.append("game/data/%s differs from sheets/%s" % (n, n))
    for n in sorted(data - sheets):
        errs.append("game/data/%s has no sheet in sheets/" % n)
    for n in prep_sources(root):
        if not n.endswith(".json"):
            continue
        if n not in sheets:
            errs.append("prep/%s has no sheet in sheets/" % n)
        elif not filecmp.cmp(os.path.join(root, "sheets", n), os.path.join(root, "prep", n), shallow=False):
            errs.append("prep/%s differs from sheets/%s" % (n, n))
    return errs


def check_game(root, game_dir, scan_pck=True):
    errs = ["dist/RustSurf/%s missing (export the Windows Desktop preset)" % p
            for p in ("RustSurf.exe", "RustSurf.pck") if not os.path.isfile(os.path.join(game_dir, p))]
    if scan_pck and not errs:
        with open(os.path.join(game_dir, "RustSurf.pck"), "rb") as f:
            pck = f.read()
        for p in sorted(glob.glob(os.path.join(root, "sheets", "*.json"))):
            n = os.path.basename(p)
            if ("data/" + n).encode() not in pck:
                errs.append("RustSurf.pck has no data/%s: re-export the game (export_presets include_filter *.json)" % n)
    return errs


def check_bundle(root, bundle):
    errs = ["prep bundle has no %s" % t for t in BUNDLE_TOOLS if not os.path.isfile(os.path.join(bundle, t))]
    for n in prep_sources(root):
        b = os.path.join(bundle, n)
        if not os.path.isfile(b) or not filecmp.cmp(os.path.join(root, "prep", n), b, shallow=False):
            errs.append("prep bundle %s is not the repo's prep/%s" % (n, n))
    return errs


def verify_zip(root, out):
    """The zip as Melty will unpack it: readable, CRCs good, every file the recipe and prep need present."""
    need = ["RustSurf.exe", "RustSurf.pck", "README.md"] + ["prep/" + t for t in BUNDLE_TOOLS] + ["prep/" + n for n in prep_sources(root)]
    try:
        with zipfile.ZipFile(out) as z:
            bad = z.testzip()
            names = set(z.namelist())
    except zipfile.BadZipFile as e:
        return ["zip does not open: %s" % e]
    errs = ["zip entry %s fails its CRC" % bad] if bad else []
    return errs + ["zip has no %s" % n for n in need if n not in names]


def build(root=R, ver=None, scan_pck=True):
    """Returns (zip path, errors). No zip is left behind when there are errors."""
    rver, errs = recipe_version(root)
    ver = ver or rver
    if ver != rver:
        errs.append("version %s does not match melty.recipe.json (%s)" % (ver, rver))
    errs += check_readme(root, rver)
    errs += check_copies(root)
    game, bundle, lic = os.path.join(root, "dist", "RustSurf"), os.path.join(root, ".work", "prepbundle"), os.path.join(root, "LICENSES")
    for d, what in ((game, "export the game to dist/RustSurf"), (bundle, "build .work/prepbundle: embedded Python, vrf/, vgm/"), (lic, "add the LICENSES folder")):
        if not os.path.isdir(d):
            errs.append("missing %s (%s)" % (d, what))
    if errs:
        return None, errs
    errs += check_game(root, game, scan_pck)
    # our own prep sources and sheets always come from the repo, so the bundle never ships a stale copy
    for n in prep_sources(root):
        shutil.copy2(os.path.join(root, "prep", n), os.path.join(bundle, n))
    errs += check_bundle(root, bundle)
    if errs:
        return None, errs
    out = os.path.join(root, "dist", "RustSurf-%s.zip" % ver)
    entries = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for base, prefix in ((game, ""), (bundle, "prep/"), (lic, "LICENSES/")):
            for dp, dn, fn in os.walk(base):
                dn[:] = sorted(d for d in dn if d != "__pycache__")  # the embedded stdlib .pyc stays; only our caches go
                for f in sorted(fn):
                    if f.endswith(".log"):
                        continue
                    p = os.path.join(dp, f)
                    rel = prefix + os.path.relpath(p, base).replace(os.sep, "/")
                    z.write(p, rel)
                    entries.append({"path": rel, "size": os.path.getsize(p)})
        z.write(os.path.join(root, "README.md"), "README.md")
        entries.append({"path": "README.md", "size": os.path.getsize(os.path.join(root, "README.md"))})
    errs += verify_zip(root, out)
    if errs:
        os.remove(out)
        return None, errs
    h = hashlib.sha256()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    meta = {"fileName": os.path.basename(out), "size": os.path.getsize(out), "sha256": h.hexdigest(), "entries": entries}
    with open(out[:-4] + ".entries.json", "w", encoding="utf-8") as f:
        json.dump(meta, f)
    print("%s: %d files, %.1f MB zipped, sha256 %s" % (meta["fileName"], len(entries), meta["size"] / 1048576, meta["sha256"][:16]))
    return out, []


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    out, errs = build(R, args[0] if args else None, "--skip-pck-scan" not in argv)
    if errs:
        print("package.py: not packaged, %d problem(s):" % len(errs))
        for e in errs:
            print("  - " + e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
