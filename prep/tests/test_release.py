"""tools/package.py's release gates that read setup's output: the release data check (a whole prep run of this
version with every gun's stats read from CS2's files) and the items_game reader parity between the game and prep."""
import os, sys, io, json, shutil, tempfile, unittest, contextlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(REPO, "tools"))
import package, prep, prep_cs2, items_game
from fakevrf import FakeVRF
from test_prep import WEAPONS, items_game_for, fake_rust

VER = package.recipe_version(REPO)[0]


class ReleaseData(unittest.TestCase):
    """A data folder written by prep.main (fake VRF, fake Rust step) as the packaging PC's real run would be."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.out = os.path.join(self.d, "data")
        cs2, tools = os.path.join(self.d, "cs2"), os.path.join(self.d, "tools")
        for p in (os.path.join(cs2, "game", "csgo", "pak01_dir.vpk"), os.path.join(tools, "vrf", "Source2Viewer-CLI.exe")):
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "wb").close()
        argv = ["--rust", os.path.join(self.d, "rust"), "--cs2", cs2, "--out", self.out, "--tools", tools, "--version", VER, "--no-dialog"]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(prep.main(argv, (prep.cs2_step, fake_rust), FakeVRF(items_game_for(WEAPONS))), 0)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def check(self):
        return package.check_release_data(REPO, self.out, VER)

    def stats(self, edit):
        p = os.path.join(self.out, "cs2", "weapon_stats.json")
        with open(p, encoding="utf-8") as f:
            st = json.load(f)
        edit(st)
        prep_cs2.write_json(p, st)

    def test_whole_run_passes_and_is_recorded(self):
        errs, rep = self.check()
        self.assertEqual(errs, [])
        self.assertEqual((rep["version"], rep["guns"], rep["guns_with_stats"]), (VER, len(WEAPONS), len(WEAPONS)))
        self.assertEqual(rep["stats_sources"], ["items_game.txt"])
        self.assertEqual(len(rep["weapon_stats_sha256"]), 64)
        self.assertEqual(len(rep["prep_status_sha256"]), 64)

    def test_a_gun_on_class_averages_is_refused(self):
        """setup only warns (stats_required_blocks no); a release built on such a run is refused all the same."""
        self.stats(lambda st: st["weapon_ak47"].pop("recoil seed"))
        errs, rep = self.check()
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("1 gun(s) would play on class averages, CS2's files gave no weapon_ak47 (recoil seed)", errs[0])
        self.assertEqual(rep["guns_with_stats"], len(WEAPONS) - 1)

    def test_a_gun_without_stats_entry_is_refused(self):
        self.stats(lambda st: st.pop("weapon_awp"))
        errs, _ = self.check()
        self.assertTrue(any("no entry for 1 gun(s): weapon_awp" in e for e in errs), errs)

    def test_missing_done_file_or_other_version(self):
        os.remove(os.path.join(self.out, "done-%s.txt" % VER))
        errs, _ = package.check_release_data(REPO, self.out, VER)
        self.assertTrue(any("has no done-%s.txt" % VER in e for e in errs), errs)
        errs, _ = package.check_release_data(REPO, self.out, "9.9.9")
        self.assertTrue(any("prep_status.json is not an ok run of 9.9.9" in e for e in errs), errs)

    def test_missing_weapon_model_or_content(self):
        w = WEAPONS[2]
        for o in prep_cs2.outputs(w["model"]):
            p = os.path.join(self.out, "cs2", o)
            if os.path.exists(p):
                os.remove(p)
        os.remove(os.path.join(self.out, "rust", "tex", "fake_albedo.png"))
        errs, _ = self.check()
        self.assertTrue(any("1 gun(s) not whole" in e and w["id"] + " (model)" in e for e in errs), errs)
        self.assertTrue(any("Launch Site piece(s) not whole" in e for e in errs), errs)

    def test_no_folder(self):
        errs, rep = package.check_release_data(REPO, os.path.join(self.d, "nope"), VER)
        self.assertTrue(errs[0].startswith("no release data folder"), errs)


class KvParity(unittest.TestCase):
    """The fixture through the game's own reader (tools/kv_parity.gd) and prep's; needs a Godot 4.7.2 binary in
    RS_GODOT (or GODOT), skipped without one. tools/package.py runs the same check on every release."""

    def test_fixture_reads_alike(self):
        godot = os.environ.get("RS_GODOT") or os.environ.get("GODOT")
        if not godot or not os.path.isfile(godot):
            self.skipTest("set RS_GODOT to a Godot 4.7.2 binary")
        lines = []
        self.assertEqual(package.kv_parity(REPO, godot, [os.path.join(REPO, package.FIXTURE)], log=lines.append), [])
        self.assertTrue(any("4 gun(s) read alike" in l for l in lines), lines)

    def test_prefab_chains_on_the_fixture(self):
        """What the parity compares: the <weapon>_prefab chain alone (the item's own attributes, such as the M4A1's
        damage 34, reach the game through weapon_stats.json, which goes on top of the chain)."""
        ch = items_game.prefab_chains(os.path.join(REPO, package.FIXTURE), ["weapon_ak47", "weapon_m4a1", "weapon_taser", "weapon_nope"])
        self.assertEqual(sorted(ch), ["weapon_ak47", "weapon_m4a1", "weapon_taser"])
        self.assertEqual(ch["weapon_m4a1"]["damage"], "33")
        self.assertEqual(ch["weapon_ak47"]["in game price"], "2500")
        self.assertNotIn("kill eater score type", ch["weapon_m4a1"])
        st = items_game.stats(os.path.join(REPO, package.FIXTURE), ["weapon_m4a1"])
        self.assertEqual(st["weapon_m4a1"]["damage"], "34")
        self.assertTrue(set(ch["weapon_m4a1"]) <= set(st["weapon_m4a1"]))  # so weapon_stats.json covers every chain key


if __name__ == "__main__":
    unittest.main()
