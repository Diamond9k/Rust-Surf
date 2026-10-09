"""tools/package.py: the repo's own copies agree, and a fake release tree packages only when whole."""
import os, sys, json, shutil, zipfile, tempfile, unittest, contextlib, io
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
        for mod in ("UnityPy", "lazybundle", "prep", "ctypes"):
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
            try:
                import UnityPy  # noqa: F401
            except ImportError:
                self.skipTest("UnityPy is not installed here (lazybundle patches its real modules)")
            code, out = package._run([sys.executable, "-c", package.SMOKE, stub], stub, 120, print)
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

    def test_failed_gate_blocks_the_zip(self):
        out, errs = self.build(gate=lambda: (["Godot --wtest: exit 1, pass line present"], 3))
        self.assertIsNone(out)
        self.assertEqual(errs, ["Godot --wtest: exit 1, pass line present"])
        out, errs = self.build(gate=lambda: ([], 3))
        self.assertEqual(errs, [])
        with open(out[:-4] + ".entries.json", encoding="utf-8") as f:
            meta = json.load(f)
        self.assertEqual((meta["gates"], meta["unverified_cells"]), ("passed", 3))

    def test_refused_build_removes_an_older_zip(self):
        out, errs = self.build()
        self.assertEqual(errs, [])
        out, errs = self.build(gate=lambda: (["Godot --wtest on the exported pck: exit 1"], 0))
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
if "--main-pack" not in a or not os.path.isfile(a[a.index("--main-pack") + 1]):
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
    print("WTEST weapons checks=21 failed=0")
    sys.exit(0)
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

    def test_hung_test_is_stopped_by_the_clock(self):
        os.environ["FAKE_GODOT"] = "sleep"
        errs = package.godot_gate(self.r, self.godot, self.data, timeout=2, log=lambda s: None)
        self.assertTrue(any(e.startswith("Godot --uitest on the exported pck: exit -1") for e in errs), errs)

    def test_missing_godot_or_data(self):
        self.assertTrue(package.godot_gate(self.r, "", self.data)[0].startswith("no Godot binary"))
        self.assertTrue(package.godot_gate(self.r, self.godot, os.path.join(self.r, "nope"))[0].startswith("no extracted data folder"))


if __name__ == "__main__":
    unittest.main()
