"""Builds the Melty release zip: game build + prep bundle + licenses + README, and refuses to build one
that would install broken.
usage: package.py [<version>] --godot <Godot binary> --data <prep output folder> [--no-sync] [--skip-pck-scan]
                  [--no-bundle-smoke]
  -> dist/RustSurf-<version>.zip, dist/RustSurf-<version>.entries.json
       package.py --sync
  -> copies sheets/ over game/data/ and prep/ and checks them; run it before exporting from the Godot editor
     (game/data/ is not in git, so an export without it ships whatever copies were last there)
       package.py --ci --godot <Godot 4.7.2 headless binary>
  -> "CI: clean" or the problems, exit 1; no zip. Every push runs it (.github/workflows/ci.yml): the checks that
     need neither the games' files nor export templates (see ci()), so a script change is tested before release.
     Its headless tests play on a synthetic CS2 stats install (prep/tests/ci_data.py) that prep's own
     write_stats turns into weapon_stats.json, so all 35 guns' stats travel the release path on every push.
First any dist/RustSurf-<version>.zip and .entries.json of the same version are deleted, so a refused build
never leaves an older zip that looks released. The sheets are copied over game/data/ and prep/ (game/data/ is
not in git, so a fresh clone holds none or stale ones; --no-sync only checks). Then the gates, each must pass:
- tools/preflight.py: every sheet cell filled and verified or honestly labelled unverified, and every
  gameplay-critical unverified row (weapon, scoring and crosshair sheets) acknowledged unchanged in
  tools/unverified_ack.json, so a number that may differ from CS2 ships as a decision, not a count
- python -m unittest discover prep/tests (prep, export checks, items_game/vdata readers, this file), with RS_GODOT
  set to --godot so the game-vs-prep reader test runs (under CI it fails rather than skips without one)
- release data: --data is this version's prep run on a real Rust + CS2 install (the release candidate run on the
  packaging PC): done-<version>.txt, prep_status.json ok, every content row and Launch Site piece whole, all
  weapons.json guns with model, clips and shot sound, and every gun's stats_required values read from CS2's
  files (no gun on class averages, whatever stats_required_blocks lets setup accept), and no stat on which CS2's
  items_game.txt and weapons.vdata disagree while sheets/prep.json stats_conflict_winner is still unverified.
  Its hashes and any settled conflicts go in the entries file.
- Godot, headless: --check-only on every game script and --import; the game's own items_game reader
  (tools/kv_parity.gd) must read prep/tests/fixtures/items_game.txt and --data's real items_game.txt exactly as
  prep/items_game.py does; then dist/RustSurf is emptied and the Windows Desktop preset exported into it
  (--export-release; needs the Godot 4.7.2 export templates), and --lobbytest ("LTEST ALL PASS"), --wtest
  ("WTEST weapons checks=N failed=0") and --uitest ("UITEST ok") run on that exported RustSurf.pck
  (--main-pack), each with exit 0, no FAIL / SCRIPT ERROR / Parse Error / engine ERROR: line and a wall-clock
  limit (--ci excuses only "Error opening file" under its content-free data folder), and no check that PASSes
  only by skipping unless another gate covers it (RELEASE_SKIPS), on --data
  (so the real CS2 stats reach the gun model) with empty Rust and CS2 folders so the packager's own CS2 config
  cannot change a result. The zip therefore holds exactly the tested export.
Checks before zipping (each failure is listed, nothing is written):
- melty.recipe.json names one x.y.z everywhere and it is the version asked for; README.md names it too
- every sheets/*.json equals game/data/<name>.json and every prep/*.json equals its sheet (no stray copies)
- dist/RustSurf has RustSurf.exe and RustSurf.pck, and the pck holds every sheet byte for byte (Godot 4.7.2
  stores data/*.json uncompressed: checked with --export-pack); --skip-pck-scan if that ever changes
- the prep bundle has python.exe, its standard library, UnityPy, vrf/Source2Viewer-CLI.exe,
  vgm/vgmstream-cli.exe and, after the repo's prep sources are copied in, every prep/*.py and *.json byte for
  byte, and nothing else: an allowlist (embedded Python files, vrf/, vgm/, installed packages) refuses a dev
  run's data, a done file, prep_status.json, weapon_stats.json or a removed prep module
- the bundle's own python.exe (wine off Windows) imports everything setup imports and decodes a DXT1 and a
  BC7 block through UnityPy, and vrf/Source2Viewer-CLI.exe and vgm/vgmstream-cli.exe each start from the bundle
  and print their usage (a DLL left out of their folder fails); where this cannot run the build is refused,
  unless --no-bundle-smoke, which the entries file records
Then the zip is read back: it must open, pass its CRCs, hold every required entry (LICENSES/ included) and no
prep output."""
import os, re, sys, json, glob, shutil, fnmatch, hashlib, zipfile, filecmp, subprocess, tempfile

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE_TOOLS = ["python.exe", "vrf/Source2Viewer-CLI.exe", "vgm/vgmstream-cli.exe"]
# What may sit at the top of the prep bundle besides the prep sources: the embedded Python's own files, the two
# tools, and installed packages (a folder with __init__, a *.dist-info, or a file a dist-info RECORD lists).
BUNDLE_FILES = ("python*.exe", "pythonw*.exe", "*.dll", "*.pyd", "python3*.zip", "*._pth", "LICENSE*")
BUNDLE_DIRS = ("python3*", "Lib", "vrf", "vgm", "*.dist-info", "*.libs", "*.data")
# What a dev run of prep writes (into --out, or anywhere): never shipped, wherever it sits in the bundle.
DEV_OUTPUTS = ("done-*.txt", "prep_status.json", "prep_status.json.tmp", "weapon_stats.json", "launch_site_placements.json",
               "items_game.txt", "*.vdata", "*.glb", "*.wav", "*.mp3", "*.tmp")
FIXTURE = os.path.join("prep", "tests", "fixtures", "items_game.txt")


def recipe_version(root):
    with open(os.path.join(root, "melty.recipe.json"), encoding="utf-8") as f:
        recipe = json.load(f)
    rver = recipe["components"][0]["fileName"][len("RustSurf-"):-len(".zip")]
    found = set(re.findall(r"\d+\.\d+\.\d+", json.dumps(recipe)))
    errs = [] if found == {rver} else ["melty.recipe.json names more than one version: %s" % sorted(found)]
    return rver, errs


def check_readme(root, ver):
    """README.md's first heading names ver as a whole version (0.2.0 is not 0.2.01 nor 10.2.0), so a README left
    on an older version, or naming the new one only in a changelog line, refuses the build."""
    with open(os.path.join(root, "README.md"), encoding="utf-8") as f:
        head = next((l for l in f if l.startswith("# ")), "")
    if re.search(r"(?<![\d.])%s(?!\d|\.\d)" % re.escape(ver), head):
        return []
    return ["README.md does not mention version %s in its first heading (%r; it ships in the zip as the only doc)" % (ver, head.strip())]


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


def sync_copies(root, prep=True):
    """sheets/ -> game/data/ (every sheet) and, with prep, prep/ (the sheets prep reads); returns the names
    rewritten. --ci syncs only game/data/ (not in git), so a prep/ copy that drifted in git is still reported."""
    out = []
    dd = os.path.join(root, "game", "data")
    os.makedirs(dd, exist_ok=True)
    for p in sorted(glob.glob(os.path.join(root, "sheets", "*.json"))):
        n = os.path.basename(p)
        for d in (dd, os.path.join(root, "prep")) if prep else (dd,):
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


def _found(bundle, pattern):
    return any("__pycache__" not in p for p in glob.glob(os.path.join(bundle, pattern), recursive=True))


def check_bundle(root, bundle):
    """The tools, the embedded Python's stdlib and UnityPy (a zip without them installs, then fails setup on
    every start), and every prep source byte for byte."""
    errs = ["prep bundle has no %s" % t for t in BUNDLE_TOOLS if not os.path.isfile(os.path.join(bundle, t))]
    if not any(_found(bundle, p) for p in ("python3*.zip", os.path.join("python3*", "encodings", "__init__.py*"), os.path.join("Lib", "encodings", "__init__.py*"))):
        errs.append("prep bundle has no Python standard library (python3*.zip or python3*/encodings): the embedded Python cannot start")
    if not _found(bundle, os.path.join("**", "UnityPy", "__init__.py*")):
        errs.append("prep bundle has no UnityPy package: the Rust half of setup cannot run")
    for n in prep_sources(root):
        b = os.path.join(bundle, n)
        if not os.path.isfile(b) or not filecmp.cmp(os.path.join(root, "prep", n), b, shallow=False):
            errs.append("prep bundle %s is not the repo's prep/%s" % (n, n))
    return errs + bundle_extras(root, bundle)


def _recorded(bundle):
    """Top-level names the installed distributions' RECORD files list (single-file modules such as brotli.py)."""
    out = set()
    for rec in glob.glob(os.path.join(bundle, "*.dist-info", "RECORD")) + glob.glob(os.path.join(bundle, "Lib", "site-packages", "*.dist-info", "RECORD")):
        try:
            with open(rec, encoding="utf-8", errors="replace") as f:
                out.update(l.split(",")[0].replace("\\", "/").split("/")[0] for l in f if l.strip())
        except OSError:
            pass
    return out


def bundle_extras(root, bundle):
    """An allowlist for the bundle: every top-level entry must be a prep source, the embedded Python, a tool
    folder or an installed package, and nothing anywhere may be a prep output (a dev run's data/, done file,
    prep_status.json, weapon_stats.json, exported glb/wav). Each stray is named; nothing is dropped silently."""
    if not os.path.isdir(bundle):
        return []
    ours, rec = set(prep_sources(root)), _recorded(bundle)
    errs = []
    for n in sorted(os.listdir(bundle)):
        p = os.path.join(bundle, n)
        if n == "__pycache__" or n.endswith(".log") or n in ours or n in rec:  # caches and logs are never zipped
            continue
        if os.path.isdir(p):
            ok = any(fnmatch.fnmatch(n, d) for d in BUNDLE_DIRS) or glob.glob(os.path.join(p, "__init__.py*")) or os.path.isdir(os.path.join(p, "__pycache__"))
        else:
            ok = any(fnmatch.fnmatch(n, f) for f in BUNDLE_FILES)
        if not ok:
            errs.append("prep bundle holds %s, which is not a prep source, the embedded Python, vrf/, vgm/ or an installed package "
                        "(a dev run's leftover or a removed prep file?): delete it from .work/prepbundle" % (n + "/" if os.path.isdir(p) else n))
    for dp, dn, fn in os.walk(bundle):
        dn[:] = [d for d in dn if d != "__pycache__"]
        for f in fn:
            if any(fnmatch.fnmatch(f, d) for d in DEV_OUTPUTS):
                errs.append("prep bundle holds %s, a prep output: delete it (a release must not ship one setup run's data)"
                            % os.path.relpath(os.path.join(dp, f), bundle).replace(os.sep, "/"))
    return errs


SMOKE = "\n".join((
    "import sys; sys.path.insert(0, sys.argv[1])",
    "import ctypes, json, zlib, threading, UnityPy, lazybundle, prep, prep_cs2, prep_rust, prep_scene, normals, glbwriter, items_game, kv3",
    "from UnityPy.enums import TextureFormat, BuildTarget",
    "from UnityPy.export import Texture2DConverter",
    "from UnityPy.helpers.MeshHelper import MeshHandler",
    "from UnityPy.helpers.ResourceReader import get_resource_data",
    "lazybundle.install()",
    "for fmt, n in ((TextureFormat.DXT1, 8), (TextureFormat.BC7, 16)):",
    "    assert Texture2DConverter.parse_image_data(bytes(n), 4, 4, fmt, (2022, 3, 0, 0), BuildTarget.StandaloneWindows64).size == (4, 4), fmt",
    "print('BUNDLE OK ' + sys.version.split()[0])"))


def bundle_smoke(bundle, run=None, log=print, allow_skip=False):
    """The bundle's own python.exe (on Windows, else under wine) imports every module setup imports (UnityPy and
    the texture decoders it loads, lazybundle's patch, every prep module, ctypes for the failure box) and decodes
    one DXT1 and one BC7 block, the formats of Rust's textures, as prep does, so a bundle missing a dependency or
    holding packages built for another platform is refused here rather than on the player's first start.
    Where it cannot run at all, the build is refused unless allow_skip (--no-bundle-smoke, which the entries file
    records). Returns errors."""
    cmd = [os.path.join(bundle, "python.exe"), "-c", SMOKE, bundle]
    if run is None:
        run = _run
        if sys.platform != "win32":
            wine = shutil.which("wine") or shutil.which("wine64")
            if not wine:
                if allow_skip:
                    log("gate: prep bundle import check NOT RUN (--no-bundle-smoke: no Windows and no wine here)")
                    return []
                return ["prep bundle import check cannot run here (python.exe needs Windows or wine): package on Windows, "
                        "install wine, or pass --no-bundle-smoke to ship an unchecked bundle (recorded in the entries file)"]
            cmd = [wine] + cmd
    code, out = run(cmd, bundle, 300, log)
    if code != 0 or "BUNDLE OK" not in out:
        return ["prep bundle python.exe could not import setup's modules: exit %d: %s" % (code, _why(out))]
    log("gate: prep bundle " + out.strip().splitlines()[-1])
    errs = []
    for tool, arg in TOOL_STARTS:  # each tool must start from the bundle: a DLL left out of vrf/ or vgm/ fails here
        exe = os.path.join(bundle, *tool.split("/"))
        code, out = run(cmd[:-4] + [exe] + arg, os.path.dirname(exe), 120, log)  # cmd[:-4]: wine, or nothing on Windows
        if not USAGE.search(out) or TOOL_LOAD_ERR.search(out):
            errs.append("prep bundle %s did not start (exit %d): %s; setup could not export with it (a DLL missing from its folder?)"
                        % (tool, code, " | ".join(l.strip() for l in out.strip().splitlines()[-3:])[:400] or "no output"))
        else:
            log("gate: prep bundle %s starts" % tool)
    return errs


# The two tools with an argument that makes them print their usage and exit without touching a file. Both print a
# "Usage" line there (VRF's --help; vgmstream-cli with no input), from their documentation, not yet run from a
# Windows bundle here. Exit codes are not compared: a usage screen may exit 1.
TOOL_STARTS = (("vrf/Source2Viewer-CLI.exe", ["--help"]), ("vgm/vgmstream-cli.exe", []))
USAGE = re.compile(r"usage", re.I)
TOOL_LOAD_ERR = re.compile(r"err:module|could not load file or assembly", re.I)  # wine's and .NET's missing-library reports


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
    errs += ["zip has no %s" % n for n in need if n not in names]
    if not any(n.startswith("LICENSES/") and not n.endswith("/") for n in names):
        errs.append("zip has no LICENSES/ file (the third-party licenses ship with the tools)")
    return errs + ["zip holds %s, a prep output" % n for n in sorted(names)
                   if n.startswith("prep/") and any(fnmatch.fnmatch(n.rsplit("/", 1)[-1], d) for d in DEV_OUTPUTS)]


def _prep_modules(root):
    """The repo's prep and prep_cs2, so the release check asks exactly what setup asks."""
    d = os.path.join(root, "prep")
    if d not in sys.path:
        sys.path.insert(0, d)
    import importlib.util, prep_cs2, items_game
    spec = importlib.util.spec_from_file_location("rs_prep_main", os.path.join(d, "prep.py"))  # by path: "prep" is also the folder
    prep = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prep)
    return prep, prep_cs2, items_game


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_release_data(root, data, ver):
    """The release candidate gate: --data must be what this version's prep wrote from a real Rust + CS2 install
    (on the packaging PC), whole: done-<ver>.txt, prep_status.json ok for <ver>, every content row and Launch Site
    piece, all weapons.json guns with model, clips and shot sound, and every gun's stats_required values read from
    CS2's files (zero guns on class averages, whatever stats_required_blocks says). The headless tests then run on
    this folder, so the stats wiring is exercised on real files. Returns (errors, report for the entries file)."""
    prep, prep_cs2, _ = _prep_modules(root)
    here = os.path.join(root, "prep")
    rerun = "run this version's prep into it on a real Rust + CS2 install: python prep/prep.py --rust <Rust> --cs2 <CS2> --out %s --version %s" % (data, ver)
    if not data or not os.path.isdir(data):
        return ["no release data folder (--data): " + rerun], {}
    errs = []
    if not os.path.isfile(os.path.join(data, "done-%s.txt" % ver)):
        errs.append("%s has no done-%s.txt: %s" % (data, ver, rerun))
    sp, wp = os.path.join(data, "prep_status.json"), os.path.join(data, "cs2", "weapon_stats.json")
    try:
        with open(sp, encoding="utf-8") as f:
            status = json.load(f)
    except (OSError, ValueError):
        status = {}
    if status.get("version") != ver or status.get("ok") is not True:
        errs.append("%s: prep_status.json is not an ok run of %s (version %s, ok %s): %s" % (data, ver, status.get("version"), status.get("ok"), rerun))
    ws, cfg = prep_cs2.sheet("weapons", here), prep_cs2.settings(here)
    rows = prep_cs2.weapon_rows(ws)
    try:
        with open(wp, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
        errs.append("%s: no readable cs2/weapon_stats.json" % data)
    lost = [w["item"] for w in rows if w["item"] not in st]
    if st and lost:
        errs.append("weapon_stats.json has no entry for %d gun(s): %s" % (len(lost), prep_cs2.short(lost)))
    gaps = prep_cs2.stats_gaps(st, ws, cfg)
    if gaps:
        errs.append("%d gun(s) would play on class averages, CS2's files gave no %s: fix the stats keys (sheets/prep.json "
                    "stats_required, vdata_keys) before releasing" % (len(gaps), prep_cs2.short(["%s (%s)" % (n, "/".join(m)) for n, m in gaps.items()], 4)))
    clash = ["%s %s (items_game.txt %s, weapons.vdata %s)" % (n, k, p.get("items_game.txt"), p.get("weapons.vdata"))
             for n, v in sorted(st.items()) if isinstance(v, dict) and isinstance(v.get("_conflicts"), dict)
             for k, p in sorted(v["_conflicts"].items()) if isinstance(p, dict)]
    row = next((r for r in prep_cs2.sheet("prep", here)["rows"] if r["id"] == "stats_conflict_winner"), {})
    if clash and "unverified" in str(row.get("verified", "unverified")).lower():
        errs.append("CS2's items_game.txt and weapons.vdata disagree on %d value(s): %s. The game plays the %s value; check which one CS2 "
                    "plays (or fix the vdata_keys mapping) on these files, then set sheets/prep.json stats_conflict_winner and write what "
                    "you checked in its verified cell" % (len(clash), prep_cs2.short(clash, 4), row.get("value", "items_game.txt")))
    wm = prep_cs2.weapons_missing(os.path.join(data, "cs2"), ws)
    if wm:
        errs.append("%d gun(s) not whole in %s: %s" % (len(wm), data, prep_cs2.short(["%s (%s)" % (k, "/".join(v)) for k, v in sorted(wm.items())])))
    cm, sm = prep.content_missing(data), prep.scene_missing(data)
    if cm:
        errs.append("content rows not extracted in %s: %s" % (data, prep_cs2.short(cm)))
    if sm:
        errs.append("%d Launch Site piece(s) not whole in %s: %s" % (len(sm), data, prep_cs2.short(sm)))
    report = {"version": status.get("version"), "guns": len(rows), "guns_with_stats": len(rows) - len(lost) - len(gaps),
              "stats_sources": sorted({str(v.get("_source", "?")) for v in st.values() if isinstance(v, dict)}),
              "prep_warnings": status.get("warnings", []), "stats_conflicts": clash,
              "prep_status_sha256": _sha(sp) if os.path.isfile(sp) else None, "weapon_stats_sha256": _sha(wp) if os.path.isfile(wp) else None}
    return errs, report


def kv_parity(root, godot, files, timeout=300, log=print):
    """The game reads items_game.txt itself too (Weapons._kv / _ig_chain): tools/kv_parity.gd runs that reader on
    each file and its <weapon>_prefab chains must equal prep/items_game.py's, key for key, for every weapons.json
    gun the file has (the synthetic fixture always, the release data's real file when there is one)."""
    _, prep_cs2, items_game = _prep_modules(root)
    names = [w["item"] for w in prep_cs2.weapon_rows(prep_cs2.sheet("weapons", os.path.join(root, "prep")))]
    game, tool = os.path.abspath(os.path.join(root, "game")), os.path.abspath(os.path.join(root, "tools", "kv_parity.gd"))
    errs = []
    for src in files:
        want = items_game.prefab_chains(src, names)
        tmp = tempfile.mkdtemp(prefix="rs_kv_")  # a private folder: no other process can take or pre-place the name
        out = os.path.join(tmp, "chains.json")
        try:
            code, text = _run([godot, "--headless", "--path", game, "--script", tool, "--", os.path.abspath(src), out] + names, game, timeout, log)
            try:
                with open(out, encoding="utf-8") as f:
                    got = json.load(f)
            except (OSError, ValueError):
                got = None
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if code != 0 or got is None or SCRIPT_ERR.search(text):
            errs.append("kv parity on %s: Godot exit %d: %s" % (src, code, _why(text)))
            continue
        diff = sorted(n for n in set(want) | set(got) if want.get(n) != got.get(n))
        if not want:
            errs.append("kv parity on %s: prep reads no weapon prefab from it" % src)
        elif diff:
            n = diff[0]
            keys = sorted(k for k in set(want.get(n, {})) | set(got.get(n, {})) if want.get(n, {}).get(k) != got.get(n, {}).get(k))
            errs.append("kv parity on %s: the game and prep read %d gun(s) differently (%s; first %s: %s)"
                        % (src, len(diff), prep_cs2.short(diff, 4), n, ", ".join("%s game %r prep %r" % (k, got.get(n, {}).get(k), want.get(n, {}).get(k)) for k in keys[:4])))
        else:
            log("gate: kv parity %s: %d gun(s) read alike" % (os.path.basename(src), len(want)))
    return errs


def _run(cmd, cwd, timeout, log, env=None):
    """(exit code, output) of one gate command; a timeout or a missing program is exit -1."""
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout, env=env)
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


GAME_TESTS = (("--lobbytest", re.compile(r"^LTEST ALL PASS\s*$", re.M)),
              ("--wtest", re.compile(r"^WTEST weapons checks=[1-9]\d* failed=0\s*$", re.M)),
              ("--uitest", re.compile(r"^UITEST ok\s*$", re.M)))
TEST_FAIL = re.compile(r"^(LTEST|WTEST|UITEST) FAIL", re.M)
# A check that prints PASS with "skipped" tested nothing; each gate names the ones another gate covers.
TEST_SKIP = re.compile(r"^(?:LTEST|WTEST|UITEST) PASS (\S+) skipped\b.*$", re.M)
# The release gate runs on the exported pck, which has no prep/tests beside it: these two compare the game's
# items_game reader with prep's on the fixture, which kv_parity has already done (on the fixture and the real file).
RELEASE_SKIPS = ("items_game_parity", "fixture_stats")
# Godot's own error lines (a resource or glb that does not load, a missing node, push_error): a test can still
# print its pass line after one, so each fails the test too.
ENGINE_ERR = re.compile(r"^(?:USER )?ERROR:")


def engine_errors(out, data=None):
    """Godot ERROR: lines of a run. data: a folder the run was told holds no content (--ci): "Error opening file"
    lines for files under it are what an empty data folder prints and are left out; nothing else is."""
    root = os.path.abspath(data).replace(os.sep, "/").rstrip("/") + "/" if data else None
    errs = []
    for l in out.splitlines():
        l = l.strip()
        if ENGINE_ERR.match(l):
            if root and "Error opening file" in l and root in l.replace("\\", "/"):
                continue
            errs.append(l)
    return errs
TEST_TIMEOUT = 300  # wall clock per headless test; each one quits itself when done (about 20 s here)


def export_game(root, godot, timeout=600, log=print):
    """A clean dist/RustSurf from this tree: the folder is emptied, then Godot exports the Windows Desktop preset
    into it, so the zip only ever holds what this export wrote (no stale pck, no files left by a dev run)."""
    game = os.path.abspath(os.path.join(root, "game"))
    out = os.path.abspath(os.path.join(root, "dist", "RustSurf"))
    shutil.rmtree(out, ignore_errors=True)
    if os.path.exists(out):
        return ["could not empty %s (is RustSurf.exe still running?)" % out]
    os.makedirs(out)
    code, text = _run([godot, "--headless", "--path", game, "--export-release", "Windows Desktop", os.path.join(out, "RustSurf.exe")], game, timeout, log)
    miss = [p for p in ("RustSurf.exe", "RustSurf.pck") if not os.path.isfile(os.path.join(out, p))]
    if code != 0 or miss or SCRIPT_ERR.search(text):
        return ["Godot --export-release \"Windows Desktop\": exit %d%s: %s (Godot 4.7.2 Windows export templates installed?)"
                % (code, ", no " + "/".join(miss) if miss else "", _why(text))]
    log("gate: exported %s" % ", ".join(sorted(os.listdir(out))))
    return []


def scripts_gate(root, godot, timeout=600, log=print):
    """The project imports (first, so a fresh clone has its class_name cache) and every game script passes
    --check-only. Returns errors."""
    game = os.path.abspath(os.path.join(root, "game"))
    errs = []
    code, out = _run([godot, "--headless", "--path", game, "--import"], game, timeout, log)
    if code != 0 or SCRIPT_ERR.search(out):
        errs.append("Godot --import: exit %d: %s" % (code, _why(out)))
    scripts = sorted(os.path.relpath(p, game).replace(os.sep, "/") for p in glob.glob(os.path.join(game, "**", "*.gd"), recursive=True)
                     if os.sep + ".godot" + os.sep not in p)
    for sc in scripts:
        code, out = _run([godot, "--headless", "--path", game, "--check-only", "--script", "res://" + sc], game, timeout, log)
        if code != 0 or SCRIPT_ERR.search(out):
            errs.append("Godot --check-only %s: exit %d: %s" % (sc, code, _why(out)))
    log("gate: %d scripts parse-checked" % len(scripts))
    return errs


def game_tests(godot, launch, data, where, timeout=TEST_TIMEOUT, log=print, allowed=(), expect=None, skips=()):
    """--lobbytest, --wtest and --uitest with launch (["--main-pack", pck] or ["--path", game]) on data, with empty
    Rust and CS2 folders (the packager's own CS2 config cannot change a result), each under a wall-clock limit.
    A test passes on exit 0, its pass line and no FAIL / SCRIPT ERROR / engine ERROR: line. allowed: check names
    whose FAIL alone is accepted (--ci, which has no extracted content); the test's own failed=N must then count
    exactly those, and there "Error opening file" lines for files under the data folder are expected.
    expect: {flag: [(regex, what it proves)]} lines a test must also print (--ci: every stats reference compared).
    skips: check names that may PASS as "skipped" (covered by another gate); any other skipped check fails the test,
    since its PASS would count a check that tested nothing."""
    errs = []
    empty = tempfile.mkdtemp(prefix="rs_gate_")
    for d in ("rust", "cs2", "cwd"):
        os.makedirs(os.path.join(empty, d))  # Paths.gd refuses a folder that does not exist
    try:
        for flag, ok in GAME_TESTS:
            cmd = [godot, "--headless"] + launch + ["--", "--data", data, "--rust", os.path.join(empty, "rust"), "--cs2", os.path.join(empty, "cs2"), flag]
            code, out = _run(cmd, os.path.join(empty, "cwd"), timeout, log)
            fails = [l for l in out.splitlines() if SCRIPT_ERR.search(l) or TEST_FAIL.match(l)]
            fails += [l for l in engine_errors(out, data if allowed else None) if l not in fails]
            excused = [l for l in fails if TEST_FAIL.match(l) and len(l.split()) > 2 and l.split()[2] in allowed]
            hard = [l for l in fails if l not in excused]
            hard += ["no line %s (%s)" % (rx.pattern, what) for rx, what in (expect or {}).get(flag, []) if not rx.search(out)]
            skipped = TEST_SKIP.findall(out)
            hard += ["%s passed only by skipping (it tested nothing here)" % n for n in skipped if n not in skips]
            if skipped:
                log("gate: %s skipped %s (covered elsewhere)" % (flag, ", ".join(n for n in skipped if n in skips) or "nothing allowed"))
            fails += [l for l in hard if l not in fails]
            counted = re.search(r"^\w+ \w+ checks=[1-9]\d* failed=(\d+)\s*$", out, re.M)
            if excused and not hard and counted and int(counted.group(1)) == len(excused) and code in (0, 1):
                log("gate: %s %s with %d check(s) that need extracted content not passing: %s"
                    % (flag, counted.group(0).strip(), len(excused), ", ".join(l.split()[2] for l in excused)))
            elif code != 0 or fails or not ok.search(out):
                errs.append("Godot %s %s: exit %d, %s%s" % (flag, where, code, "no pass line" if not ok.search(out) else "pass line present",
                                                            "; " + " | ".join(fails)[:600] if fails else ""))
            else:
                log("gate: %s %s" % (flag, ok.search(out).group(0).strip()))
    finally:
        shutil.rmtree(empty, ignore_errors=True)
    return errs


def godot_gate(root, godot, data, timeout=600, log=print):
    """Every game script parses, the project imports, a fresh export lands in dist/RustSurf, and the asserting
    headless tests (--lobbytest, --wtest, --uitest) pass on that exported RustSurf.pck (--main-pack), so the build
    that ships is the build that was tested. Each test runs on --data with empty Rust and CS2 folders (the
    packager's own CS2 config cannot change a result) under a wall-clock limit, not a frame count. Returns errors."""
    godot, data = os.path.abspath(godot) if godot else "", os.path.abspath(data) if data else ""
    if not godot or not os.path.isfile(godot):
        return ["no Godot binary (pass --godot <Godot_v4.7.2 executable>): the headless tests cannot run"]
    if not data or not os.path.isdir(data):
        return ["no extracted data folder (pass --data <a prep output folder>): the headless tests need the content"]
    errs = scripts_gate(root, godot, timeout, log)
    if errs:
        return errs
    real = os.path.join(data, "cs2", "scripts", "items", "items_game.txt")
    errs = kv_parity(root, godot, [os.path.join(root, FIXTURE)] + ([real] if os.path.isfile(real) else []), timeout, log)
    if errs:
        return errs
    errs = export_game(root, godot, timeout, log)
    if errs:
        return errs
    pck = os.path.abspath(os.path.join(root, "dist", "RustSurf", "RustSurf.pck"))
    return game_tests(godot, ["--main-pack", pck], data, "on the exported pck", min(timeout, TEST_TIMEOUT), log, skips=RELEASE_SKIPS)


# --wtest checks that need CS2's arms and knife from a prep run. A --ci machine holds none of the games' files
# (they are never in the repo), so there these two may fail on their own; the release gate runs them on real data.
CONTENT_CHECKS = ("viewmodel_inside_hull", "reequip_idle")


def unit_tests(root, godot, log=print):
    """python -m unittest discover prep/tests, with RS_GODOT set to godot so the game-vs-prep reader test runs
    instead of skipping (and with CI set it fails rather than skips when there is no Godot). Returns errors."""
    env = dict(os.environ)
    if godot:
        env["RS_GODOT"] = os.path.abspath(godot)
    code, out = _run([sys.executable, "-m", "unittest", "discover", "-s", os.path.join("prep", "tests")], root, 1800, log, env)
    tail = out.strip().splitlines()[-1:] or ["no output"]
    if code != 0:
        return ["prep unit tests failed (%s): run python -m unittest discover prep/tests" % tail[0]]
    log("gate: prep unit tests %s" % tail[0])
    return []


def ci_stats_data(root, data, log=print):
    """The synthetic CS2 stats install --ci plays on (prep/tests/ci_data.py): an items_game.txt naming every
    weapons.json gun, through the repo's own prep write_stats into cs2/weapon_stats.json. Returns (errors,
    the --wtest lines that must show every weapon_defaults reference value compared with those files)."""
    tests = os.path.join(root, "prep", "tests")
    if tests not in sys.path:
        sys.path.insert(0, tests)
    import ci_data
    _, prep_cs2, _ = _prep_modules(root)
    keep, prep_cs2.LOG = prep_cs2.LOG, log
    try:
        problems, warnings = ci_data.build(root, data)
    finally:
        prep_cs2.LOG = keep
    errs = ["synthetic stats install: prep says %s" % p for p in problems + warnings]
    ids = {w["id"] for w in prep_cs2.weapon_rows(prep_cs2.sheet("weapons", os.path.join(root, "prep")))}
    n = sum(1 for r in prep_cs2.sheet("weapon_defaults", os.path.join(root, "sheets")).get("reference", []) if r["weapon"] in ids)
    want = re.compile(r"^WTEST PASS stats_reference %d known value" % n, re.M)
    return errs, {"--wtest": [(want, "the game read all %d reference stats from prep's weapon_stats.json" % n)]}


def ci(root, godot, timeout=600, log=print):
    """The checks a push can run without the games or export templates (a Linux Godot 4.7.2 headless binary is
    enough): one version in the recipe and README, sheets/ copied to game/data/ and equal to prep/'s copies,
    preflight, the prep unit tests (the reader parity test among them), --import and --check-only on every
    script, the game-vs-prep items_game parity on prep/tests/fixtures/items_game.txt and on the synthetic
    install, and --lobbytest, --wtest and --uitest on the source project with that synthetic install as the data
    folder: every gun's stats come from an items_game.txt through prep into the game, and --wtest must compare
    every reference stat (CONTENT_CHECKS, which need the games' models, are excused there). Returns errors."""
    rver, errs = recipe_version(root)
    errs += check_readme(root, rver)
    for n in sync_copies(root, prep=False):
        log("synced %s from sheets/" % n)
    errs += check_copies(root)
    sys.path.insert(0, os.path.join(root, "tools"))
    import preflight
    problems, unsure = preflight.check(root)
    errs += ["preflight: " + p for p in problems]
    log("gate: preflight %s, %d cell(s) labelled unverified" % ("clean" if not problems else "%d problem(s)" % len(problems), len(unsure)))
    # only a release refuses unacknowledged gameplay-critical rows (gates()); a push just says how many wait on review
    log("gate: %d gameplay-critical unverified row(s) not yet acknowledged for release" % len(preflight.critical_unacked(root)))
    godot = os.path.abspath(godot) if godot and os.path.isfile(godot) else ""
    errs += unit_tests(root, godot, log)
    if not godot:
        return errs + ["no Godot binary (pass --godot <Godot_v4.7.2 headless executable>): the in-engine checks cannot run"]
    data = tempfile.mkdtemp(prefix="rs_ci_data_")
    try:
        g, expect = ci_stats_data(root, data, log)
        if not g:
            log("gate: synthetic stats install: prep read every gun's stats")
            g = scripts_gate(root, godot, timeout, log)
        if not g:
            g = kv_parity(root, godot, [os.path.join(root, FIXTURE), os.path.join(data, "cs2", "scripts", "items", "items_game.txt")], timeout, log)
        if not g:
            g = game_tests(godot, ["--path", os.path.abspath(os.path.join(root, "game"))], data, "on the source project (synthetic stats, no game content)",
                           min(timeout, TEST_TIMEOUT), log, CONTENT_CHECKS, expect)
    finally:
        shutil.rmtree(data, ignore_errors=True)
    return errs + g


def gates(root, godot, data, ver, log=print):
    """preflight, the prep unit tests, the release data check, then the Godot gate.
    Returns (errors, number of unverified cells, release data report)."""
    sys.path.insert(0, os.path.join(root, "tools"))
    import preflight
    problems, unsure = preflight.check(root)
    errs = ["preflight: " + p for p in problems]
    log("gate: preflight %s, %d cell(s) labelled unverified" % ("clean" if not problems else "%d problem(s)" % len(problems), len(unsure)))
    crit = preflight.critical_unacked(root)
    if crit:  # a gameplay number that may differ from CS2 ships only as a recorded decision (tools/unverified_ack.json)
        errs.append("preflight: %d gameplay-critical unverified row(s) not acknowledged for this release: %s (review them, then "
                    "python3 tools/preflight.py --ack)" % (len(crit), ", ".join(crit[:8]) + (" and %d more" % (len(crit) - 8) if len(crit) > 8 else "")))
    errs += unit_tests(root, godot if godot and os.path.isfile(godot) else "", log)
    rd_errs, report = check_release_data(root, os.path.abspath(data) if data else "", ver)
    errs += ["release data: " + e for e in rd_errs]
    if not rd_errs:
        log("gate: release data %s: %d/%d guns with every required stat (%s)" % (data, report["guns_with_stats"], report["guns"], ", ".join(report["stats_sources"])))
    errs += godot_gate(root, godot, data, log=log)
    return errs, len(unsure), report


def build(root=R, ver=None, scan_pck=True, gate=None, smoke=None, allow_no_smoke=False):
    """Returns (zip path, errors). No zip is left behind when there are errors.
    gate: a callable taking the version and returning (errors, unverified count[, release data report]), run first
    (main passes the real gates). smoke: the runner bundle_smoke uses (prep/tests); None runs the bundle's
    python.exe (wine off Windows). allow_no_smoke: --no-bundle-smoke, recorded in the entries file."""
    unverified, report = None, None
    rver, verrs = recipe_version(root)
    ver = ver or rver
    for v in {ver, rver}:  # a refused build never leaves an older zip of the same version next to the refusal
        for p in ("RustSurf-%s.zip" % v, "RustSurf-%s.entries.json" % v):
            if os.path.isfile(os.path.join(root, "dist", p)):
                os.remove(os.path.join(root, "dist", p))
    errs = []
    if gate:
        res = gate(ver)
        errs, unverified = list(res[0]), res[1]
        report = res[2] if len(res) > 2 else None
    errs += verrs
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
    smoked = "passed"
    if not errs:
        lines = []
        errs += bundle_smoke(bundle, smoke, lambda l: (lines.append(l), print(l)), allow_no_smoke)
        smoked = "not run (--no-bundle-smoke)" if any("NOT RUN" in l for l in lines) else smoked
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
    meta = {"fileName": os.path.basename(out), "size": os.path.getsize(out), "sha256": _sha(out), "entries": entries,
            "gates": "passed" if gate else "not run", "unverified_cells": unverified, "bundle_smoke": smoked, "release_data": report}
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
    godot = opt.get("--godot") or os.environ.get("GODOT", "")
    if "--sync" in argv:  # before any export made outside this script (the Godot editor, a local export tool)
        names = sync_copies(R)
        for n in names:
            print("synced %s from sheets/" % n)
        errs = check_copies(R)
        print("sheet copies: %s" % ("in step (%d rewritten)" % len(names) if not errs else "; ".join(errs)))
        return 1 if errs else 0
    if "--ci" in argv:
        errs = ci(R, godot)
        print("CI: clean" if not errs else "CI: %d problem(s):" % len(errs))
        for e in errs:
            print("  - " + e)
        return 1 if errs else 0
    if "--no-sync" not in argv:
        for n in sync_copies(R):
            print("synced %s from sheets/" % n)
    out, errs = build(R, args[0] if args else None, "--skip-pck-scan" not in argv,
                      gate=lambda ver: gates(R, godot, opt.get("--data") or os.environ.get("RS_DATA", ""), ver),
                      allow_no_smoke="--no-bundle-smoke" in argv)
    if errs:
        print("package.py: not packaged, %d problem(s):" % len(errs))
        for e in errs:
            print("  - " + e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
