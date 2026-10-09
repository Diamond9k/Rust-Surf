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
        self.write(os.path.join(g, "RustSurf.pck"), b"GDPC" + b"".join(b"res://data/" + n.encode() + b"\0" for n in os.listdir(os.path.join(self.r, "sheets"))))
        self.b = os.path.join(self.r, ".work", "prepbundle")
        for t in package.BUNDLE_TOOLS + ["python312/encodings/__init__.pyc", "UnityPy/__pycache__/x.pyc", "old.log"]:
            self.write(os.path.join(self.b, t), b"x")
        self.write(os.path.join(self.r, "LICENSES", "MIT.txt"), b"x")
        self.ver = package.recipe_version(self.r)[0]

    def tearDown(self):
        shutil.rmtree(self.r, ignore_errors=True)

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


if __name__ == "__main__":
    unittest.main()
