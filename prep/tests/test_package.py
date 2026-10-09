"""tools/package.py: the repo's own copies agree, and a fake release tree packages only when whole."""
import os, sys, json, shutil, zipfile, tempfile, unittest, unittest.mock, contextlib, io
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))
import package


class Repo(unittest.TestCase):
    def test_sheet_copies_identical(self):
        self.assertEqual(package.check_copies(REPO), [])

    def test_recipe_and_readme_agree(self):
        ver, errs = package.recipe_version(REPO)
        self.assertEqual(errs, [])
        self.assertEqual(package.check_readme(REPO, ver), [])

    def test_prep_sources_listed(self):
        src = package.prep_sources(REPO)
        for n in ("prep.py", "prep_cs2.py", "items_game.py", "content.json", "weapons.json", "prep.json"):
            self.assertIn(n, src)


class Build(unittest.TestCase):
    """A copy of the repo's recipe, README, sheets and prep with a fake game export and prep bundle."""

    def setUp(self):
        self.r = tempfile.mkdtemp()
        for f in ("melty.recipe.json", "README.md"):
            shutil.copy(os.path.join(REPO, f), self.r)
        for d in ("sheets", os.path.join("game", "data")):
            shutil.copytree(os.path.join(REPO, d), os.path.join(self.r, d))
        shutil.copytree(os.path.join(REPO, "prep"), os.path.join(self.r, "prep"), ignore=shutil.ignore_patterns("__pycache__", "tests"))
        g = os.path.join(self.r, "dist", "RustSurf")
        os.makedirs(g)
        self.write(os.path.join(g, "RustSurf.exe"), b"MZ")
        self.write(os.path.join(g, "RustSurf.pck"), self.pck())
        self.b = os.path.join(self.r, ".work", "prepbundle")
        for t in package.BUNDLE_TOOLS + ["python312/encodings/__init__.pyc", "UnityPy/__init__.py", "UnityPy/__pycache__/x.pyc", "old.log"]:
            self.write(os.path.join(self.b, t), b"x")
        self.write(os.path.join(self.r, "LICENSES", "MIT.txt"), b"x")
        self.ver = package.recipe_version(self.r)[0]

    def tearDown(self):
        shutil.rmtree(self.r, ignore_errors=True)

    def pck(self, old=()):
        """A pck as Godot 4.7.2 writes it: each sheet's path and its bytes uncompressed (old: sheets left stale)."""
        out = b"GDPC"
        for n in sorted(os.listdir(os.path.join(self.r, "sheets"))):
            with open(os.path.join(self.r, "sheets", n), "rb") as f:
                body = f.read()
            out += b"res://data/" + n.encode() + b"\0" + (body[:-2] + b"x\n" if n in old else body)
        return out

    def write(self, p, data):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)

    def build(self, **kw):
        self.smoked = []
        def smoke(cmd, cwd, timeout, log):  # the bundle's python.exe is a stub here; a real one runs only on Windows
            self.smoked.append(cmd)
            return 0, "BUNDLE OK 3.12.10\n"
        kw.setdefault("smoke", smoke)
        with contextlib.redirect_stdout(io.StringIO()):
            return package.build(self.r, **kw)

    def test_bundle_needs_stdlib_and_unitypy(self):
        shutil.rmtree(os.path.join(self.b, "python312"))
        shutil.rmtree(os.path.join(self.b, "UnityPy", "__pycache__"))
        os.remove(os.path.join(self.b, "UnityPy", "__init__.py"))
        self.write(os.path.join(self.b, "UnityPy", "__pycache__", "__init__.cpython-312.pyc"), b"x")  # a cache alone is not the package
        out, errs = self.build()
        self.assertIsNone(out)
        self.assertEqual(len(errs), 2, errs)
        self.assertTrue(any("standard library" in e for e in errs) and any("UnityPy" in e for e in errs), errs)
        self.write(os.path.join(self.b, "python312.zip"), b"PK")
        self.write(os.path.join(self.b, "Lib", "site-packages", "UnityPy", "__init__.pyc"), b"x")
        out, errs = self.build()
        self.assertEqual(errs, [])

    def test_bundle_import_check(self):
        out, errs = self.build()
        self.assertEqual(errs, [])
        cmd = self.smoked[0]
        self.assertEqual(cmd[0], os.path.join(self.b, "python.exe"))
        self.assertEqual(cmd[-1], self.b)
        for mod in ("UnityPy", "lazybundle", "prep", "prep_rust", "normals", "ctypes", "Texture2DConverter", "BC7", "DXT1"):
            self.assertIn(mod, cmd[2])
        out, errs = self.build(smoke=lambda *a: (1, "ModuleNotFoundError: No module named 'lz4'"))
        self.assertIsNone(out)
        self.assertTrue(any("could not import" in e and "lz4" in e for e in errs), errs)
        self.assertFalse(os.path.exists(os.path.join(self.r, "dist", "RustSurf-%s.zip" % self.ver)))
        out, errs = self.build(smoke=lambda *a: (0, "no verdict"))
        self.assertIsNone(out)

    def test_smoke_line_runs_here(self):
        """The import line itself, on this Python and the repo's prep (UnityPy stubbed when it is not installed)."""
        stub = tempfile.mkdtemp()
        try:
            for f in os.listdir(os.path.join(REPO, "prep")):
                if f.endswith((".py", ".json")):
                    shutil.copy(os.path.join(REPO, "prep", f), stub)
            py = os.environ.get("RS_UNITYPY_PYTHON", sys.executable)  # a Python with UnityPy, when this one has none
            code, out = package._run([py, "-c", "import UnityPy"], stub, 120, print)
            if code != 0:
                self.skipTest("UnityPy is not installed here (set RS_UNITYPY_PYTHON to a Python that has it)")
            code, out = package._run([py, "-c", package.SMOKE, stub], stub, 120, print)
            self.assertEqual(code, 0, out)
            self.assertIn("BUNDLE OK", out)
        finally:
            shutil.rmtree(stub)

    def test_builds_and_zip_holds_everything(self):
        out, errs = self.build()
        self.assertEqual(errs, [])
        with zipfile.ZipFile(out) as z:
            names = set(z.namelist())
        for n in ["RustSurf.exe", "RustSurf.pck", "README.md", "LICENSES/MIT.txt", "prep/python312/encodings/__init__.pyc"] + ["prep/" + t for t in package.BUNDLE_TOOLS] + ["prep/" + n for n in package.prep_sources(self.r)]:
            self.assertIn(n, names)
        self.assertNotIn("prep/old.log", names)
        self.assertFalse(any("__pycache__" in n for n in names))
        self.assertTrue(os.path.exists(out[:-4] + ".entries.json"))

    def test_dev_leftovers_in_the_bundle_are_refused(self):
        """An allowlist, not a walk of whatever is there: a dev prep run's data and a removed prep module never ship."""
        for p in ("data/cs2/weapon_stats.json", "prep_status.json", "done-%s.txt" % self.ver, "old_module.py", "notes.json",
                  "UnityPy/resources/x.glb", "Lib/site-packages/thing/__init__.py"):
            self.write(os.path.join(self.b, p), b"x")
        out, errs = self.build()
        self.assertIsNone(out)
        for n in ("data/", "old_module.py", "notes.json", "prep_status.json", "done-%s.txt" % self.ver):
            self.assertTrue(any("prep bundle holds %s," % n in e for e in errs), (n, errs))
        for n in ("data/cs2/weapon_stats.json", "UnityPy/resources/x.glb"):
            self.assertTrue(any("holds %s, a prep output" % n in e for e in errs), (n, errs))
        self.assertFalse(any("Lib" in e for e in errs), errs)
        self.assertFalse(os.path.exists(os.path.join(self.r, "dist", "RustSurf-%s.zip" % self.ver)))

    def test_installed_packages_are_allowed(self):
        """Single-file modules a dist-info RECORD lists, package folders, the embedded Python's own files."""
        for p in ("brotli.py", "_brotli.cp312-win_amd64.pyd", "python312.dll", "python312._pth", "vcruntime140.dll", "LICENSE.txt",
                  "PIL/__init__.py", "Brotli-1.1.0.dist-info/METADATA"):
            self.write(os.path.join(self.b, p), b"x")
        self.write(os.path.join(self.b, "Brotli-1.1.0.dist-info", "RECORD"), b"brotli.py,sha256=x,1\n_brotli.cp312-win_amd64.pyd,,\n")
        out, errs = self.build()
        self.assertEqual(errs, [])

    def test_zip_readback_needs_licenses(self):
        out, errs = self.build()
        self.assertEqual(errs, [])
        bare = os.path.join(self.r, "bare.zip")
        with zipfile.ZipFile(out) as z, zipfile.ZipFile(bare, "w") as w:
            for n in z.namelist():
                if not n.startswith("LICENSES/"):
                    w.writestr(n, z.read(n))
            w.writestr("prep/weapon_stats.json", "{}")
        errs = package.verify_zip(self.r, bare)
        self.assertIn("zip has no LICENSES/ file (the third-party licenses ship with the tools)", errs)
        self.assertIn("zip holds prep/weapon_stats.json, a prep output", errs)
        self.assertEqual(package.verify_zip(self.r, out), [])

    def test_bundle_smoke_never_silently_skipped(self):
        """Off Windows with no wine the import check cannot run: that refuses the build unless --no-bundle-smoke,
        which the entries file then records."""
        if sys.platform == "win32" or shutil.which("wine") or shutil.which("wine64"):
            self.skipTest("the check can run here")
        out, errs = self.build(smoke=None)
        self.assertIsNone(out)
        self.assertTrue(any("import check cannot run here" in e for e in errs), errs)
        out, errs = self.build(smoke=None, allow_no_smoke=True)
        self.assertEqual(errs, [])
        with open(out[:-4] + ".entries.json", encoding="utf-8") as f:
            self.assertEqual(json.load(f)["bundle_smoke"], "not run (--no-bundle-smoke)")

    def test_stale_prep_source_in_bundle_is_replaced(self):
        self.write(os.path.join(self.b, "prep.py"), b"old")
        out, errs = self.build()
        self.assertEqual(errs, [])
        with zipfile.ZipFile(out) as z, open(os.path.join(self.r, "prep", "prep.py"), "rb") as f:
            self.assertEqual(z.read("prep/prep.py"), f.read())

    def test_missing_tools(self):
        for t in package.BUNDLE_TOOLS:
            os.remove(os.path.join(self.b, t))
        out, errs = self.build()
        self.assertIsNone(out)
        self.assertEqual(sorted(errs), sorted("prep bundle has no " + t for t in package.BUNDLE_TOOLS))
        self.assertFalse(os.path.exists(os.path.join(self.r, "dist", "RustSurf-%s.zip" % self.ver)))

    def test_copy_drift(self):
        with open(os.path.join(self.r, "game", "data", "weapons.json"), "a", encoding="utf-8") as f:
            f.write(" ")
        os.remove(os.path.join(self.r, "game", "data", "hud.json"))
        self.write(os.path.join(self.r, "prep", "stray.json"), b"{}")
        out, errs = self.build()
        self.assertIsNone(out)
        self.assertIn("game/data/weapons.json differs from sheets/weapons.json", errs)
        self.assertIn("game/data/hud.json missing (copy sheets/hud.json)", errs)
        self.assertIn("prep/stray.json has no sheet in sheets/", errs)

    def test_pck_without_a_sheet(self):
        self.write(os.path.join(self.r, "dist", "RustSurf", "RustSurf.pck"), b"GDPC res://data/content.json")
        out, errs = self.build()
        self.assertIsNone(out)
        self.assertIn("RustSurf.pck has no data/weapons.json: re-export the game (export_presets include_filter *.json)", errs)
        out, errs = self.build(scan_pck=False)
        self.assertEqual(errs, [])

    def test_pck_with_an_old_sheet(self):
        self.write(os.path.join(self.r, "dist", "RustSurf", "RustSurf.pck"), self.pck(old=["weapons.json"]))
        out, errs = self.build()
        self.assertIsNone(out)
        self.assertEqual(errs, ["RustSurf.pck holds an old data/weapons.json: re-export the game after the sheet change"])

    def test_sync_copies(self):
        with open(os.path.join(self.r, "game", "data", "weapons.json"), "a", encoding="utf-8") as f:
            f.write(" ")
        os.remove(os.path.join(self.r, "game", "data", "hud.json"))
        with open(os.path.join(self.r, "prep", "prep.json"), "a", encoding="utf-8") as f:
            f.write(" ")
        self.assertEqual(sorted(package.sync_copies(self.r)), ["game/data/hud.json", "game/data/weapons.json", "prep/prep.json"])
        self.assertEqual(package.check_copies(self.r), [])
        self.assertEqual(package.sync_copies(self.r), [])
        self.assertFalse(os.path.exists(os.path.join(self.r, "prep", "hud.json")))  # prep only gets the sheets it reads

    def test_sync_flag_before_an_editor_export(self):
        """--sync alone: a game/data/ left from an older version (not in git) is brought in step, nothing else runs."""
        with open(os.path.join(self.r, "game", "data", "weapons.json"), "w", encoding="utf-8") as f:
            f.write('{"version": "0.1.0"}')
        buf = io.StringIO()
        with unittest.mock.patch.object(package, "R", self.r), contextlib.redirect_stdout(buf):
            self.assertEqual(package.main(["--sync"]), 0)
        self.assertIn("synced game/data/weapons.json from sheets/", buf.getvalue())
        self.assertEqual(package.check_copies(self.r), [])
        self.assertTrue(os.path.isfile(os.path.join(self.r, "dist", "RustSurf", "RustSurf.pck")))  # no build, no gate

    def test_failed_gate_blocks_the_zip(self):
        out, errs = self.build(gate=lambda v: (["Godot --wtest: exit 1, pass line present"], 3))
        self.assertIsNone(out)
        self.assertEqual(errs, ["Godot --wtest: exit 1, pass line present"])
        seen = []
        out, errs = self.build(gate=lambda v: (seen.append(v), ([], 3, {"guns": 35, "guns_with_stats": 35}))[1])
        self.assertEqual(errs, [])
        self.assertEqual(seen, [self.ver])
        with open(out[:-4] + ".entries.json", encoding="utf-8") as f:
            meta = json.load(f)
        self.assertEqual((meta["gates"], meta["unverified_cells"], meta["bundle_smoke"]), ("passed", 3, "passed"))
        self.assertEqual(meta["release_data"], {"guns": 35, "guns_with_stats": 35})

    def test_refused_build_removes_an_older_zip(self):
        out, errs = self.build()
        self.assertEqual(errs, [])
        out, errs = self.build(gate=lambda v: (["Godot --wtest on the exported pck: exit 1"], 0))
        self.assertIsNone(out)
        for p in ("RustSurf-%s.zip", "RustSurf-%s.entries.json"):
            self.assertFalse(os.path.exists(os.path.join(self.r, "dist", p % self.ver)), p)

    def test_version_mismatch_and_readme(self):
        out, errs = self.build(ver="9.9.9")
        self.assertIn("version 9.9.9 does not match melty.recipe.json (%s)" % self.ver, errs)
        with open(os.path.join(self.r, "README.md"), "w", encoding="utf-8") as f:
            f.write("# Rust Surf\n")
        out, errs = self.build()
        self.assertTrue(any(e.startswith("README.md does not mention") for e in errs))

    def test_recipe_with_two_versions(self):
        p = os.path.join(self.r, "melty.recipe.json")
        with open(p, encoding="utf-8") as f:
            rec = json.load(f)
        rec["setup"]["done"]["file"] = "{managed}/RustSurf/data/done-0.0.1.txt"
        with open(p, "w", encoding="utf-8") as f:
            json.dump(rec, f)
        out, errs = self.build()
        self.assertTrue(any("more than one version" in e for e in errs))


FAKE_GODOT = """#!/usr/bin/env python3
import os, sys, time
mode = os.environ.get("FAKE_GODOT", "ok")
a = sys.argv[1:]
if "--script" in a and a[a.index("--script") + 1].endswith("kv_parity.gd"):  # tools/kv_parity.gd: the game's items_game reader, played here by prep's own reader
    if mode == "kvcrash":
        print("SCRIPT ERROR: Invalid access to property or key '_ig'")
        sys.exit(1)
    game = a[a.index("--path") + 1]
    sys.path.insert(0, os.path.join(os.path.dirname(game), "prep"))
    import items_game, json
    u = a[a.index("--") + 1:]
    got = items_game.prefab_chains(u[0], u[2:])
    if mode == "kvdiff":
        got["weapon_ak47"]["damage"] = "99"
    with open(u[1], "w") as f:
        json.dump(got, f)
    print("KVPARITY done %d" % len(got))
    sys.exit(0)
if "--check-only" in a:
    if mode == "parse" and a[-1].endswith("B.gd"):
        print('SCRIPT ERROR: Parse Error: Expected expression after "+" operator.')
        sys.exit(1)
    sys.exit(0)
if "--import" in a:
    sys.exit(0)
if "--export-release" in a:
    if mode == "notemplates":
        print('ERROR: Cannot export project with preset "Windows Desktop" due to configuration errors:')
        print("No export template found at the expected path")
        sys.exit(1)
    exe = a[-1]
    for p, body in ((exe, b"MZ"), (exe[:-4] + ".pck", b"GDPC export " + mode.encode())):
        with open(p, "wb") as f:
            f.write(body)
    sys.exit(0)
src = mode.startswith("src") and "--path" in a  # package.py --ci runs the tests on the source project
if not src and ("--main-pack" not in a or not os.path.isfile(a[a.index("--main-pack") + 1])):
    print("not run on an exported pck")
    sys.exit(3)
if "--lobbytest" in a:
    print("LTEST PASS round" if mode != "lfail" else "LTEST FAIL round (x)")
    print("LTEST ALL PASS" if mode != "lfail" else "LTEST FAILED")
    sys.exit(1 if mode == "lfail" else 0)
if "--wtest" in a:
    if mode == "hang":
        sys.exit(0)  # ended before the self-test printed its verdict
    if mode == "werr":
        print("SCRIPT ERROR: Invalid call. Nonexistent function 'x'")
    if mode in ("engerr", "srcengerr"):  # an engine error the self-test itself does not see
        print("ERROR: Failed loading resource: /data/cs2/weapons/models/ak47/weapon_rif_ak47.glb.")
        print("   at: _load (core/io/resource_loader.cpp:343)")
    if mode in ("missing", "srcmissing"):  # what an empty data folder prints for each texture it lacks
        print("ERROR: Error opening file '%s/rust/tex/tarmac_albedo.png'." % a[a.index("--data") + 1])
    fails = {"srccontent": ["viewmodel_inside_hull rig reaches 0.000 m"], "srcreal": ["viewmodel_inside_hull rig", "spray_fps_independent gap 0.2 deg"],
             "srcmiscount": ["reequip_idle idle clip on three equips: []"]}.get(mode, [])
    for f in fails:
        print("WTEST FAIL " + f)
    sheets = os.path.join(os.path.dirname(a[a.index("--path") + 1]), "sheets") if src else ""
    if os.path.isfile(os.path.join(sheets, "weapon_defaults.json")):  # what the game prints when it read the data folder's stats
        import json
        ids = {r["id"] for r in json.load(open(os.path.join(sheets, "weapons.json")))["rows"]}
        n = sum(1 for r in json.load(open(os.path.join(sheets, "weapon_defaults.json")))["reference"] if r["weapon"] in ids)
        print("WTEST PASS stats_reference %d known value(s) compared with the files, all equal" % (0 if mode == "srcnostats" else n))
    print("WTEST weapons checks=21 failed=%d" % (len(fails) + (mode == "srcmiscount")))
    sys.exit(1 if fails else 0)
if "--uitest" in a:
    if mode == "sleep":
        time.sleep(30)
    print("UITEST PASS menu" if mode != "ufail" else "UITEST FAIL rebind moves the key")
    print("UITEST ok" if mode != "ufail" else "UITEST FAILED 1")
    sys.exit(1 if mode == "ufail" else 0)
sys.exit(2)
"""


@unittest.skipIf(os.name == "nt", "the fake Godot is a POSIX script")
class Gate(unittest.TestCase):
    """package.godot_gate with a fake Godot that passes or fails the ways the real tests can."""

    def setUp(self):
        self.r = tempfile.mkdtemp()
        for n in ("A.gd", "B.gd"):
            os.makedirs(os.path.join(self.r, "game", "scripts"), exist_ok=True)
            open(os.path.join(self.r, "game", "scripts", n), "w").close()
        os.makedirs(os.path.join(self.r, "game", ".godot"))
        open(os.path.join(self.r, "game", ".godot", "cache.gd"), "w").close()
        self.godot = os.path.join(self.r, "godot")
        with open(self.godot, "w") as f:
            f.write(FAKE_GODOT)
        os.chmod(self.godot, 0o755)
        self.data = os.path.join(self.r, "data")
        os.makedirs(self.data)
        shutil.copytree(os.path.join(REPO, "prep"), os.path.join(self.r, "prep"), ignore=shutil.ignore_patterns("__pycache__"))
        os.makedirs(os.path.join(self.r, "tools"))
        shutil.copy(os.path.join(REPO, "tools", "kv_parity.gd"), os.path.join(self.r, "tools"))

    def tearDown(self):
        shutil.rmtree(self.r, ignore_errors=True)
        os.environ.pop("FAKE_GODOT", None)

    def gate(self, mode):
        os.environ["FAKE_GODOT"] = mode
        lines = []
        return package.godot_gate(self.r, self.godot, self.data, timeout=60, log=lines.append), lines

    def test_pass(self):
        errs, lines = self.gate("ok")
        self.assertEqual(errs, [])
        self.assertIn("gate: 2 scripts parse-checked", lines)  # .godot/ caches are not game scripts

    def test_kv_parity(self):
        """The game's items_game reader and prep's must agree on the fixture, and on the release data's real file."""
        errs, lines = self.gate("ok")
        self.assertIn("gate: kv parity items_game.txt: 4 gun(s) read alike", lines)
        errs, _ = self.gate("kvdiff")
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("read 1 gun(s) differently (weapon_ak47; first weapon_ak47: damage game '99' prep '36')", errs[0])
        errs, _ = self.gate("kvcrash")
        self.assertTrue(errs and errs[0].startswith("kv parity on") and "SCRIPT ERROR" in errs[0], errs)
        real = os.path.join(self.data, "cs2", "scripts", "items")
        os.makedirs(real)
        shutil.copy(os.path.join(REPO, package.FIXTURE), real)
        errs, lines = self.gate("ok")
        self.assertEqual(errs, [])
        self.assertEqual(sum("kv parity" in l for l in lines), 2)

    def test_parse_error(self):
        errs, _ = self.gate("parse")
        self.assertEqual(len(errs), 1)
        self.assertTrue(errs[0].startswith("Godot --check-only scripts/B.gd: exit 1"), errs)

    def test_lobbytest_fail(self):
        errs, _ = self.gate("lfail")
        self.assertTrue(any(e.startswith("Godot --lobbytest on the exported pck: exit 1, no pass line") and "LTEST FAIL round" in e for e in errs), errs)

    def test_no_verdict_is_a_failure(self):
        errs, _ = self.gate("hang")
        self.assertEqual(errs, ["Godot --wtest on the exported pck: exit 0, no pass line"])

    def test_script_error_with_exit_0(self):
        errs, _ = self.gate("werr")
        self.assertTrue(errs and "SCRIPT ERROR" in errs[0], errs)

    def test_tests_run_on_a_fresh_export(self):
        stray = os.path.join(self.r, "dist", "RustSurf", "left_by_a_dev_run.txt")
        os.makedirs(os.path.dirname(stray))
        open(stray, "w").close()
        errs, lines = self.gate("ok")
        self.assertEqual(errs, [])
        self.assertEqual(sorted(os.listdir(os.path.join(self.r, "dist", "RustSurf"))), ["RustSurf.exe", "RustSurf.pck"])
        self.assertIn("gate: --uitest UITEST ok", lines)

    def test_no_export_templates(self):
        errs, _ = self.gate("notemplates")
        self.assertEqual(len(errs), 1)
        self.assertTrue(errs[0].startswith('Godot --export-release "Windows Desktop": exit 1') and "export templates" in errs[0], errs)

    def test_uitest_fail(self):
        errs, _ = self.gate("ufail")
        self.assertTrue(any(e.startswith("Godot --uitest on the exported pck: exit 1") and "UITEST FAIL rebind" in e for e in errs), errs)

    def test_engine_error_with_a_pass_line(self):
        """A glb that fails to load prints only Godot's ERROR: line; the self-test still passes, the gate does not."""
        errs, _ = self.gate("engerr")
        self.assertEqual(len(errs), 1, errs)
        self.assertTrue(errs[0].startswith("Godot --wtest on the exported pck: exit 0, pass line present") and "Failed loading resource" in errs[0], errs)
        errs, _ = self.gate("missing")  # on release data a missing file is a real gap, never excused
        self.assertTrue(errs and "Error opening file" in errs[0], errs)

    def test_engine_errors_helper(self):
        out = "\n".join(("ERROR: Error opening file '/x/d/rust/tex/a.png'.", "   at: open", "USER ERROR: weapons: bad sheet",
                         "WARNING: The load-time scene is not defined", "ERROR: Error opening file '/x/other/a.png'."))
        self.assertEqual(package.engine_errors(out), ["ERROR: Error opening file '/x/d/rust/tex/a.png'.", "USER ERROR: weapons: bad sheet",
                                                      "ERROR: Error opening file '/x/other/a.png'."])
        self.assertEqual(package.engine_errors(out, "/x/d"), ["USER ERROR: weapons: bad sheet", "ERROR: Error opening file '/x/other/a.png'."])
        win = out.replace("'/x/d/rust/tex/a.png'", "'" + os.path.join(os.path.abspath("/x/d"), "rust", "tex", "a.png").replace("/", "\\") + "'")
        self.assertEqual(len(package.engine_errors(win, "/x/d")), 2)  # Godot on Windows may print either slash

    def test_hung_test_is_stopped_by_the_clock(self):
        os.environ["FAKE_GODOT"] = "sleep"
        errs = package.godot_gate(self.r, self.godot, self.data, timeout=2, log=lambda s: None)
        self.assertTrue(any(e.startswith("Godot --uitest on the exported pck: exit -1") for e in errs), errs)

    def test_missing_godot_or_data(self):
        self.assertTrue(package.godot_gate(self.r, "", self.data)[0].startswith("no Godot binary"))
        self.assertTrue(package.godot_gate(self.r, self.godot, os.path.join(self.r, "nope"))[0].startswith("no extracted data folder"))


@unittest.skipIf(os.name == "nt", "the fake Godot is a POSIX script")
class Ci(unittest.TestCase):
    """package.ci: what every push runs, with no game files and no export templates."""
    setUp, tearDown, gate = Gate.setUp, Gate.tearDown, Gate.gate

    def ci(self, mode):
        os.environ["FAKE_GODOT"] = mode
        lines = []
        return package.game_tests(self.godot, ["--path", os.path.join(self.r, "game")], self.data, "on the source project", 60, lines.append,
                                  package.CONTENT_CHECKS), lines

    def test_source_project_passes(self):
        errs, lines = self.ci("src")
        self.assertEqual(errs, [])
        self.assertIn("gate: --wtest WTEST weapons checks=21 failed=0", lines)
        self.assertFalse(os.path.exists(os.path.join(self.r, "dist")))  # nothing exported

    def test_only_content_checks_are_excused(self):
        errs, lines = self.ci("srccontent")
        self.assertEqual(errs, [])
        self.assertTrue(any("1 check(s) that need extracted content not passing: viewmodel_inside_hull" in l for l in lines), lines)
        errs, _ = self.ci("srcreal")  # a real regression next to an excused one still fails
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("spray_fps_independent", errs[0])

    def test_empty_data_errors_excused_only_there(self):
        """--ci runs with an empty data folder, so "Error opening file" under it is expected; any other engine
        error is not."""
        errs, _ = self.ci("srcmissing")
        self.assertEqual(errs, [])
        errs, _ = self.ci("srcengerr")
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("Failed loading resource", errs[0])

    def test_excuse_needs_the_test_own_count_to_agree(self):
        errs, _ = self.ci("srcmiscount")
        self.assertEqual(len(errs), 1, errs)
        self.assertTrue(errs[0].startswith("Godot --wtest on the source project: exit 1"), errs)

    def test_release_gate_excuses_nothing(self):
        errs, _ = self.gate("srccontent")  # the same output on the exported pck is a refusal
        self.assertTrue(any(e.startswith("Godot --wtest on the exported pck: exit 1") for e in errs), errs)

    def test_ci_end_to_end_on_this_repo(self):
        """The repo's own --ci with the fake Godot: game/data synced, preflight and copies clean, every step logged.
        The prep unit tests are not run again from inside themselves."""
        os.environ["FAKE_GODOT"] = "src"
        lines = []
        errs, lines, envs = self.repo_ci()
        self.assertEqual(errs, [], errs)
        for want in ("gate: preflight clean", "gate: prep unit tests OK", "gate: synthetic stats install: prep read every gun's stats",
                     "gate: kv parity items_game.txt", "gate: --wtest", "gate: --uitest UITEST ok"):
            self.assertTrue(any(l.startswith(want) for l in lines), (want, lines))
        self.assertEqual(sum(l.startswith("gate: kv parity items_game.txt") for l in lines), 2, lines)  # the fixture and the synthetic install
        self.assertEqual(envs[0].get("RS_GODOT"), os.path.abspath(self.godot))  # so the unit tests run the reader parity test

    def repo_ci(self, mode="src"):
        """package.ci on the repo itself with the fake Godot; the prep unit tests are not run again from inside themselves."""
        os.environ["FAKE_GODOT"] = mode
        lines, envs = [], []
        real = package._run
        def run(cmd, cwd, timeout, log, env=None):
            if cmd[1:3] == ["-m", "unittest"]:
                envs.append(env or {})
                return 0, "OK"
            return real(cmd, cwd, timeout, log, env)
        with unittest.mock.patch.object(package, "_run", run):
            errs = package.ci(REPO, self.godot, 60, lines.append)
        return errs, lines, envs

    def test_ci_needs_the_game_to_read_the_stats(self):
        """A game that ignores the data folder's weapon_stats.json compares no reference value: --ci refuses."""
        errs, _, _ = self.repo_ci("srcnostats")
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("stats_reference", errs[0])

    def test_ci_without_godot_says_so(self):
        real = package._run
        with unittest.mock.patch.object(package, "_run", lambda c, *a, **k: (0, "OK") if c[1:3] == ["-m", "unittest"] else real(c, *a, **k)):
            errs = package.ci(REPO, "", 60, lambda s: None)
        self.assertEqual(len(errs), 1, errs)
        self.assertTrue(errs[0].startswith("no Godot binary"), errs)


if __name__ == "__main__":
    unittest.main()
