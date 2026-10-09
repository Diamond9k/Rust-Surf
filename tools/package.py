"""Builds the Melty release zip: game build + prep bundle + licenses + README, and refuses to build one
that would install broken.
usage: package.py [<version>] --godot <Godot binary> --data <extracted data folder> [--no-sync] [--skip-pck-scan]
  -> dist/RustSurf-<version>.zip, dist/RustSurf-<version>.entries.json
First the sheets are copied over game/data/ and prep/ (game/data/ is not in git, so a fresh clone holds none
or stale ones; --no-sync only checks). Then the gates, each of which must pass:
- tools/preflight.py: every sheet cell filled and verified or honestly labelled unverified
- python -m unittest discover prep/tests (prep, export checks, items_game/vdata readers, this file)
- Godot, headless: --check-only on every game script, --import, then --lobbytest ("LTEST ALL PASS") and
  --wtest ("WTEST weapons checks=N failed=0"), each with exit 0 and no SCRIPT ERROR / Parse Error line,
  on --data with empty Rust and CS2 folders so the player's own CS2 config cannot change a result
Checks before zipping (each failure is listed, nothing is written):
- melty.recipe.json names one x.y.z everywhere and it is the version asked for; README.md names it too
- every sheets/*.json equals game/data/<name>.json and every prep/*.json equals its sheet (no stray copies)
- dist/RustSurf has RustSurf.exe and RustSurf.pck, and the pck holds every sheet byte for byte (Godot 4.7.2
  stores data/*.json uncompressed: checked with --export-pack), so an export made before the sheets
  changed is refused
- the prep bundle has python.exe, vrf/Source2Viewer-CLI.exe, vgm/vgmstream-cli.exe and, after the repo's
  prep sources are copied in, every prep/*.py and *.json byte for byte
Then the zip is read back: it must open, pass its CRCs and hold every required entry."""
import os, re, sys, json, glob, shutil, hashlib, zipfile, filecmp, subprocess, tempfile

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


def sync_copies(root):
    """sheets/ -> game/data/ (every sheet) and prep/ (the sheets prep reads); returns the names rewritten."""
    out = []
    dd = os.path.join(root, "game", "data")
    os.makedirs(dd, exist_ok=True)
    for p in sorted(glob.glob(os.path.join(root, "sheets", "*.json"))):
        n = os.path.basename(p)
        for d in (dd, os.path.join(root, "prep")):
            t = os.path.join(d, n)
            if d == dd or os.path.isfile(t):
                if not os.path.isfile(t) or not filecmp.cmp(p, t, shallow=False):
                    shutil.copyfile(p, t)
                    out.append(os.path.relpath(t, root).replace(os.sep, "/"))
    return out


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
            else:
                with open(p, "rb") as f:
                    if f.read() not in pck:
                        errs.append("RustSurf.pck holds an old data/%s: re-export the game after the sheet change" % n)
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


def _run(cmd, cwd, timeout, log):
    """(exit code, output) of one gate command; a timeout or a missing program is exit -1."""
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired as e:
        return -1, "timed out after %ds: %s" % (timeout, (e.stdout or b"")[-2000:] if isinstance(e.stdout, bytes) else e.stdout or "")
    except OSError as e:
        return -1, "could not start %s (%s)" % (cmd[0], e)


SCRIPT_ERR = re.compile(r"SCRIPT ERROR|Parse Error|Compile Error")


def _why(out):
    """The error lines of a Godot run, else its last line, for one line of the refusal."""
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    bad = [l for l in lines if SCRIPT_ERR.search(l) or l.startswith("ERROR")]
    return " | ".join(bad or lines[-1:])[:400]


def godot_gate(root, godot, data, timeout=600, log=print):
    """Every game script parses, the project imports, and the asserting headless tests pass. Returns errors."""
    game = os.path.abspath(os.path.join(root, "game"))
    godot, data = os.path.abspath(godot) if godot else "", os.path.abspath(data) if data else ""
    errs = []
    if not godot or not os.path.isfile(godot):
        return ["no Godot binary (pass --godot <Godot_v4.7.2 executable>): the headless tests cannot run"]
    if not data or not os.path.isdir(data):
        return ["no extracted data folder (pass --data <a prep output folder>): the headless tests need the content"]
    scripts = sorted(os.path.relpath(p, game).replace(os.sep, "/") for p in glob.glob(os.path.join(game, "**", "*.gd"), recursive=True)
                     if os.sep + ".godot" + os.sep not in p)
    for sc in scripts:
        code, out = _run([godot, "--headless", "--path", game, "--check-only", "--script", "res://" + sc], game, timeout, log)
        if code != 0 or SCRIPT_ERR.search(out):
            errs.append("Godot --check-only %s: exit %d: %s" % (sc, code, _why(out)))
    log("gate: %d scripts parse-checked" % len(scripts))
    code, out = _run([godot, "--headless", "--path", game, "--import"], game, timeout, log)
    if code != 0 or SCRIPT_ERR.search(out):
        errs.append("Godot --import: exit %d: %s" % (code, _why(out)))
    empty = tempfile.mkdtemp(prefix="rs_gate_")
    for d in ("rust", "cs2"):
        os.makedirs(os.path.join(empty, d))  # Paths.gd refuses a folder that does not exist
    try:
        for flag, frames, ok in (("--lobbytest", 6000, re.compile(r"^LTEST ALL PASS\s*$", re.M)),
                                 ("--wtest", 6000, re.compile(r"^WTEST weapons checks=[1-9]\d* failed=0\s*$", re.M))):
            cmd = [godot, "--headless", "--path", game, "--quit-after", str(frames), "--", "--data", data,
                   "--rust", os.path.join(empty, "rust"), "--cs2", os.path.join(empty, "cs2"), flag]
            code, out = _run(cmd, game, timeout, log)
            fails = [l for l in out.splitlines() if SCRIPT_ERR.search(l) or re.match(r"(LTEST|WTEST) FAIL", l)]
            if code != 0 or fails or not ok.search(out):
                errs.append("Godot %s: exit %d, %s%s" % (flag, code, "no pass line" if not ok.search(out) else "pass line present",
                                                          "; " + " | ".join(fails)[:600] if fails else ""))
            else:
                log("gate: %s %s" % (flag, ok.search(out).group(0).strip()))
    finally:
        shutil.rmtree(empty, ignore_errors=True)
    return errs


def gates(root, godot, data, log=print):
    """preflight, the prep unit tests, then the Godot gate. Returns (errors, number of unverified cells)."""
    sys.path.insert(0, os.path.join(root, "tools"))
    import preflight
    problems, unsure = preflight.check(root)
    errs = ["preflight: " + p for p in problems]
    log("gate: preflight %s, %d cell(s) labelled unverified" % ("clean" if not problems else "%d problem(s)" % len(problems), len(unsure)))
    code, out = _run([sys.executable, "-m", "unittest", "discover", "-s", os.path.join("prep", "tests")], root, 1800, log)
    tail = out.strip().splitlines()[-1:] or ["no output"]
    if code != 0:
        errs.append("prep unit tests failed (%s): run python -m unittest discover prep/tests" % tail[0])
    else:
        log("gate: prep unit tests %s" % tail[0])
    errs += godot_gate(root, godot, data, log=log)
    return errs, len(unsure)


def build(root=R, ver=None, scan_pck=True, gate=None):
    """Returns (zip path, errors). No zip is left behind when there are errors.
    gate: a callable returning (errors, unverified count), run first (main passes the real gates)."""
    unverified = None
    errs = []
    if gate:
        errs, unverified = gate()
    rver, verrs = recipe_version(root)
    errs += verrs
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
    meta = {"fileName": os.path.basename(out), "size": os.path.getsize(out), "sha256": h.hexdigest(), "entries": entries,
            "gates": "passed" if gate else "not run", "unverified_cells": unverified}
    with open(out[:-4] + ".entries.json", "w", encoding="utf-8") as f:
        json.dump(meta, f)
    print("%s: %d files, %.1f MB zipped, sha256 %s" % (meta["fileName"], len(entries), meta["size"] / 1048576, meta["sha256"][:16]))
    return out, []


def main(argv):
    opt = {}
    args = []
    i = 0
    while i < len(argv):
        if argv[i] in ("--godot", "--data") and i + 1 < len(argv):
            opt[argv[i]] = argv[i + 1]
            i += 2
            continue
        if not argv[i].startswith("--"):
            args.append(argv[i])
        i += 1
    if "--no-sync" not in argv:
        for n in sync_copies(R):
            print("synced %s from sheets/" % n)
    godot = opt.get("--godot") or os.environ.get("GODOT", "")
    out, errs = build(R, args[0] if args else None, "--skip-pck-scan" not in argv,
                      gate=lambda: gates(R, godot, opt.get("--data") or os.environ.get("RS_DATA", "")))
    if errs:
        print("package.py: not packaged, %d problem(s):" % len(errs))
        for e in errs:
            print("  - " + e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
