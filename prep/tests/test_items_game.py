"""items_game.py against the synthetic fixture (fixtures/items_game.txt): prefab chains, nested
attribute blocks, [$WIN32]-style conditionals, escaped quotes, repeated sections, CRLF files."""
import os, sys, json, shutil, tempfile, unittest
from unittest import mock
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import items_game

FIX = os.path.join(HERE, "fixtures", "items_game.txt")


def fixture_text():
    with open(FIX, encoding="utf-8") as f:
        return f.read()


class Parse(unittest.TestCase):
    def setUp(self):
        self.root = items_game.parse(fixture_text())
        self.ig = self.root["items_game"]

    def test_top_level(self):
        self.assertEqual(self.root["#base"], "items_game_cdn.txt")
        self.assertEqual(set(self.ig), {"game_info", "rarities", "prefabs", "items", "attributes", "sticker_kits"})

    def test_repeated_section_merges(self):
        for p in ("weapon_base", "rifle", "weapon_ak47_prefab", "weapon_glock_prefab", "weapon_taser_prefab"):
            self.assertIn(p, self.ig["prefabs"])

    def test_escaped_quotes_and_braces_in_strings(self):
        self.assertEqual(self.ig["items"]["4"]["item_description"], 'Fires in "burst" mode; path C:\\csgo\\{not a block}')
        self.assertEqual(self.ig["sticker_kits"]["1"]["description_string"], 'Signed "The \\"Best\\"" // not a comment')
        self.assertEqual(self.ig["items"]["4"]["baseitem"], "1")  # the braces in the string did not open a block

    def test_conditional_values(self):
        a = self.ig["prefabs"]["weapon_ak47_prefab"]["attributes"]
        self.assertEqual(a["cycletime"], "0.100000")        # [$X360] value dropped, earlier one kept
        self.assertEqual(a["max player speed"], "215")      # [!$WIN32] value dropped
        self.assertEqual(a["in game price"], "2500")        # [$WIN32||$OSX] value kept (last wins)

    def test_conditional_block(self):
        self.assertNotIn("console_only", self.ig["prefabs"]["weapon_ak47_prefab"])
        self.assertEqual(self.ig["prefabs"]["weapon_ak47_prefab"]["visuals"]["weapon_type"], "Rifle")

    def test_item_with_blocks_before_its_name(self):
        """An items entry need not start with "name": stats() finds it by the parsed key, whatever comes first."""
        st = items_game.stats(FIX, ["weapon_deagle"])["weapon_deagle"]
        self.assertEqual(st["damage"], "63")             # the item's own attribute block
        self.assertEqual(st["cycletime"], "0.225000")
        self.assertEqual(st["penetration"], "1")         # from its prefab chain: pistol -> secondary -> weapon_base
        self.assertEqual(st["range"], "4096")
        self.assertNotIn("weapon_deagle", items_game.prefab_chains(FIX, ["weapon_deagle"]))  # no weapon_deagle_prefab

    def test_cond_true(self):
        for e, want in (("$WIN32", True), ("!$WIN32", False), ("$X360", False), ("!$X360", True),
                        ("$X360||$WIN32", True), ("$WINDOWS&&!$X360", True), ("$WIN32 && $OSX", False), ("$win32", True)):
            self.assertEqual(items_game.cond_true(e), want, e)

    def test_crlf_and_bom(self):
        root = items_game.parse("\ufeff" + fixture_text().replace("\n", "\r\n"))
        self.assertEqual(root, self.root)

    def test_whole_file_check(self):
        d = tempfile.mkdtemp()
        try:
            text = fixture_text()
            for name, body, want in (("full", text, True), ("half", text[:len(text) // 2], False),
                                     ("no_close", text.rstrip()[:-1], False), ("in_string", text[:text.index("Fires in") + 5], False),
                                     ("empty", "", False), ("comment", "// nothing\n", False)):
                p = os.path.join(d, name + ".txt")
                with open(p, "w", encoding="utf-8") as f:
                    f.write(body)
                self.assertEqual(items_game.whole(p), want, name)
        finally:
            shutil.rmtree(d)

    def test_unterminated_input_does_not_raise(self):
        items_game.parse('"items_game" { "items" { "7" { "name" "weapon_ak47"')
        items_game.parse('"a" "b" [$WIN32')


class Stats(unittest.TestCase):
    NAMES = ["weapon_ak47", "weapon_m4a1", "weapon_glock", "weapon_taser", "weapon_awp"]

    def setUp(self):
        self.st = items_game.stats(FIX, self.NAMES)

    def test_prefab_chain(self):
        ak = self.st["weapon_ak47"]
        self.assertEqual(ak["damage"], "36")
        self.assertEqual(ak["cycletime"], "0.100000")
        self.assertEqual(ak["primary clip size"], "30")        # own prefab beats weapon_base's 1
        self.assertEqual(ak["primary reserve ammo max"], "90")  # from rifle
        self.assertEqual(ak["is full auto"], "1")              # from rifle
        self.assertEqual(ak["range"], "8192")                  # primary beats weapon_base
        self.assertEqual(ak["heat per shot"], "0.300000")      # from weapon_base, three prefabs up
        self.assertEqual(ak["recoil seed"], "223")
        self.assertEqual(ak["kill eater score type"], "0")     # second prefab of "rifle statted_item_base", block form

    def test_item_attributes_win(self):
        m4 = self.st["weapon_m4a1"]
        self.assertEqual(m4["damage"], "34")
        self.assertEqual(m4["cycletime"], "0.090000")
        self.assertEqual(m4["tournament event id"], "5")

    def test_pistol_chain_and_alt(self):
        g = self.st["weapon_glock"]
        self.assertEqual(g["is full auto"], "0")
        self.assertEqual(g["cycletime alt"], "0.500000")
        self.assertEqual(g["primary reserve ammo max"], "120")
        self.assertEqual(g["max player speed"], "250")

    def test_prefab_fallback_and_missing(self):
        self.assertEqual(self.st["weapon_taser"]["damage"], "500")
        self.assertNotIn("weapon_awp", self.st)

    def test_no_blocks_in_output(self):
        for n, a in self.st.items():
            for k, v in a.items():
                self.assertIsInstance(v, str, "%s %s" % (n, k))

    def test_rifle_chain_gives_every_required_stat(self):
        """The fixture's AK-47 is whole the way a real rifle is: every stat prep requires, through its chain."""
        import prep_cs2
        need = prep_cs2.keys(prep_cs2.settings()["stats_required"])
        ak = self.st["weapon_ak47"]
        self.assertEqual([k for k in need if not prep_cs2.number(ak.get(k))], [])
        self.assertEqual((ak["inaccuracy move"], ak["inaccuracy crouch"]), ("140.000000", "4.100000"))  # [$X360] dropped; from rifle

    def test_write_stats_on_the_fixture(self):
        """prep_cs2.write_stats with this file as the player's export: the AK passes, the M4A4 (whose prefab
        lists only clip, damage and rate) is named with what it lacks, as a warning or (stats_required_blocks) a problem, the Glock is not in the sheet rows."""
        import prep_cs2
        d = tempfile.mkdtemp()
        try:
            p = os.path.join(d, prep_cs2.ITEMS_GAME)
            os.makedirs(os.path.dirname(p))
            shutil.copy(FIX, p)
            ws = {"rows": [{"game": "cs2", "slot": "rifle", "item": "weapon_ak47"}, {"game": "cs2", "slot": "rifle", "item": "weapon_m4a1"},
                           {"game": "cs2", "slot": "gear", "item": "weapon_taser"}]}
            real = prep_cs2.settings
            with open(os.devnull, "w") as null:
                prep_cs2.LOG = lambda s: null.write(s)
                problems, warnings = prep_cs2.write_stats(d, ws)  # the shipped sheet: gaps are warnings
                self.assertEqual(problems, [])
                self.assertIn("weapon_m4a1 (armor ratio/", warnings[0])
                with mock.patch.object(prep_cs2, "settings", lambda here=prep_cs2.HERE: dict(real(here), stats_required_blocks="yes")):
                    problems, warnings = prep_cs2.write_stats(d, ws)
            self.assertEqual(len(problems), 1, problems)
            self.assertIn("weapon_m4a1 (armor ratio/", problems[0])
            self.assertNotIn("weapon_ak47 (", problems[0])
            self.assertIn("weapon_taser (cycletime)", problems[0])  # light slot: only its four keys; range from weapon_base
            with open(os.path.join(d, "weapon_stats.json"), encoding="utf-8") as f:
                st = json.load(f)
            self.assertEqual((st["weapon_ak47"]["damage"], st["weapon_ak47"]["_source"]), ("36", "items_game.txt"))
        finally:
            prep_cs2.LOG = print
            shutil.rmtree(d)

    def test_cli_output_is_json(self):
        d = tempfile.mkdtemp()
        try:
            p = os.path.join(d, "items_game.txt")
            shutil.copy(FIX, p)
            json.dumps(items_game.stats(p, ["weapon_ak47"]))
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
