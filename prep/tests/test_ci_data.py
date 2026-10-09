"""prep/tests/ci_data.py, the synthetic CS2 stats install tools/package.py --ci plays the game on: prep reads every
weapons.json gun from it with every required stat, through the same KeyValues traps as the hand-written fixture."""
import os, sys, io, json, shutil, tempfile, unittest, unittest.mock, contextlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import ci_data, prep_cs2, items_game


class CiData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp()
        with contextlib.redirect_stdout(io.StringIO()):
            cls.res = ci_data.build(REPO, cls.d)
        with open(os.path.join(cls.d, "cs2", "weapon_stats.json"), encoding="utf-8") as f:
            cls.st = json.load(f)
        cls.ws = prep_cs2.sheet("weapons")
        cls.wd = prep_cs2.sheet("weapon_defaults", os.path.join(REPO, "sheets"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.d, ignore_errors=True)

    def test_every_gun_every_required_stat(self):
        self.assertEqual(self.res, ([], []))  # no problem and no warning: nothing plays on class averages
        self.assertEqual(sorted(self.st), sorted(w["item"] for w in prep_cs2.weapon_rows(self.ws)))
        self.assertEqual(prep_cs2.stats_gaps(self.st, self.ws, prep_cs2.settings()), {})
        self.assertTrue(items_game.whole(os.path.join(self.d, ci_data.ITEMS_GAME)))

    def test_reference_values_on_the_item_entries(self):
        items = {w["id"]: w["item"] for w in prep_cs2.weapon_rows(self.ws)}
        for r in self.wd["reference"]:
            self.assertAlmostEqual(float(self.st[items[r["weapon"]]][r["key"]]), float(r["value"]), msg=r["id"])
        for r in prep_cs2.sheet("aim_lobby", os.path.join(REPO, "sheets"))["stk_checks"]:  # the lobby's shots-to-kill table
            s = self.st[items[r["weapon"]]]
            self.assertEqual([float(s["damage"]), float(s["armor ratio"]), float(s["headshot multiplier"])],
                             [float(r["damage"]), float(r["armor_ratio"]), float(r["hs_mult"])], r["id"])

    def test_sheets_that_disagree_are_named(self):
        real = prep_cs2.sheet
        def sheet(name, here=prep_cs2.HERE):
            d = real(name, here)
            if name == "aim_lobby":
                d = dict(d, stk_checks=[dict(d["stk_checks"][0], damage=99)])
            return d
        with unittest.mock.patch.object(prep_cs2, "sheet", sheet):
            with self.assertRaises(ValueError):
                ci_data.known(REPO)

    def test_conditionals_and_block_form(self):
        ak = self.st["weapon_ak47"]
        self.assertNotEqual(ak["damage"], "999")           # "damage" "999" [$X360] is dropped on Windows
        self.assertNotEqual(ak["max player speed"], "1")   # [!$WIN32] value dropped, the earlier one restored
        self.assertEqual(self.st["weapon_m4a1"]["recoil seed"], "138")  # block form: "recoil seed" { .. "value" "138" }
        self.assertEqual(self.st["weapon_ak47"]["kill eater score type"], "0")
        seeds = [self.st[w["item"]]["recoil seed"] for w in prep_cs2.weapon_rows(self.ws)]
        self.assertEqual(len(set(seeds)), len(seeds))     # each gun its own recoil pattern

    def test_alt_modes_follow_the_sheet(self):
        for w in prep_cs2.weapon_rows(self.ws):
            s = self.st[w["item"]]
            self.assertEqual("zoom levels" in s, w["alt"] == "scope", w["id"])
            self.assertEqual("has silencer" in s, w["alt"] == "silencer", w["id"])
            self.assertEqual("has burst mode" in s, w["alt"] == "burst", w["id"])

    def test_items_with_blocks_ahead_of_name(self):
        with open(os.path.join(self.d, ci_data.ITEMS_GAME), encoding="utf-8") as f:
            text = f.read()
        name = text.index('"name"\t\t"weapon_deagle"')
        entry = text.rindex('\n\t\t"', 0, name)  # the Deagle's item entry: "visuals" and "attributes" before its "name"
        self.assertLess(entry, text.index('"visuals"', entry))
        self.assertLess(text.index('"attributes"', entry), name)
        self.assertIn('\\"AK-47\\" {not a block}', text)
        self.assertEqual(text.count('"prefabs"'), 2)


if __name__ == "__main__":
    unittest.main()
