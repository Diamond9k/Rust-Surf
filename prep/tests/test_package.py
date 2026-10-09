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
        for t in package.BUNDLE_TOOLS + ["python312/encodings/__init__.pyc", "UnityPy/__pycache__/x.pyc", "old.log"]:
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
        with contextlib.redirect_stdout(io.StringIO()):
            return package.build(self.r, **kw)

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
import os, sys
mode = os.environ.get("FAKE_GODOT", "ok")
a = sys.argv[1:]
if "--check-only" in a:
    if mode == "parse" and a[-1].endswith("B.gd"):
        print('SCRIPT ERROR: Parse Error: Expected expression after "+" operator.')
        sys.exit(1)
    sys.exit(0)
if "--import" in a:
    sys.exit(0)
if "--lobbytest" in a:
    print("LTEST PASS round" if mode != "lfail" else "LTEST FAIL round (x)")
    print("LTEST ALL PASS" if mode != "lfail" else "LTEST FAILED")
    sys.exit(1 if mode == "lfail" else 0)
if "--wtest" in a:
    if mode == "hang":
        sys.exit(0)  # --quit-after ended it before the self-test printed its verdict
    if mode == "werr":
        print("SCRIPT ERROR: Invalid call. Nonexistent function 'x'")
    print("WTEST weapons checks=21 failed=0")
    sys.exit(0)
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
        self.assertTrue(any(e.startswith("Godot --lobbytest: exit 1, no pass line") and "LTEST FAIL round" in e for e in errs), errs)

    def test_no_verdict_is_a_failure(self):
        errs, _ = self.gate("hang")
        self.assertEqual(errs, ["Godot --wtest: exit 0, no pass line"])

    def test_script_error_with_exit_0(self):
        errs, _ = self.gate("werr")
        self.assertTrue(errs and "SCRIPT ERROR" in errs[0], errs)

    def test_missing_godot_or_data(self):
        self.assertTrue(package.godot_gate(self.r, "", self.data)[0].startswith("no Godot binary"))
        self.assertTrue(package.godot_gate(self.r, self.godot, os.path.join(self.r, "nope"))[0].startswith("no extracted data folder"))


if __name__ == "__main__":
    unittest.main()
