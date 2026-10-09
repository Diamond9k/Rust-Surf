"""kv3.py against a synthetic weapons.vdata (fixtures/weapons.vdata): comments, the <!-- kv3 --> header,
typed values, [primary, alt] pairs, a _base entry, multi-line strings, blobs; the sheet's vdata_keys map."""
import os, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import kv3, prep_cs2

FIX = os.path.join(HERE, "fixtures", "weapons.vdata")
KEYS = prep_cs2.sheet("prep")["vdata_keys"]


class Parse(unittest.TestCase):
    def setUp(self):
        with open(FIX, encoding="utf-8") as f:
            self.text = f.read()
        self.root = kv3.parse(self.text)

    def test_values(self):
        ak = self.root["weapon_ak47"]
        self.assertEqual(ak["m_nDamage"], 36)
        self.assertEqual(ak["m_flCycleTime"], [0.1, 0.1])
        self.assertEqual(ak["m_flMaxSpeed"], {"m_flValues": [215.0, 215.0]})
        self.assertEqual(ak["m_szModel_AG2"], "weapons/models/ak47/weapon_rif_ak47_ag2.vmdl")  # resource_name: flag dropped
        self.assertEqual(ak["m_sSilencedSound"], "")
        self.assertEqual(ak["m_szDescription"], 'A line with "quotes"\nand a second line')
        self.assertEqual(ak["m_vecMuzzle"], [0.15, -2, 3])
        self.assertIsNone(ak["m_pNull"])
        self.assertIs(self.root["weapon_glock"]["m_bIsFullAuto"], False)
        self.assertNotIn("a block comment", str(self.root))

    def test_cut_file_raises(self):
        for cut in (len(self.text) // 2, len(self.text) - 3):
            with self.assertRaises(kv3.KV3Error):
                kv3.parse(self.text[:cut])
        with self.assertRaises(kv3.KV3Error):
            kv3.parse('"items_game" { }')  # KeyValues1, not KV3
        with self.assertRaises(kv3.KV3Error):
            kv3.parse("{ a = 1 } }")

    def test_crlf(self):
        self.assertEqual(kv3.parse(self.text.replace("\n", "\r\n"))["weapon_ak47"]["m_nDamage"], 36)


class Stats(unittest.TestCase):
    def setUp(self):
        self.st = kv3.vdata_stats(FIX, ["weapon_ak47", "weapon_glock", "weapon_taser", "weapon_awp"], KEYS)

    def test_mapped_names_and_pairs(self):
        ak = self.st["weapon_ak47"]
        self.assertEqual(ak["damage"], "36")
        self.assertEqual(ak["cycletime"], "0.1")
        self.assertEqual(ak["cycletime alt"], "0.1")
        self.assertEqual(ak["max player speed"], "215.0")       # pair inside a block
        self.assertEqual(ak["max player speed alt"], "215.0")
        self.assertEqual(ak["recoil seed"], "223")
        self.assertEqual(ak["primary clip size"], "30")

    def test_base_entry_merges_under(self):
        ak = self.st["weapon_ak47"]
        self.assertEqual(ak["is full auto"], "1")
        self.assertEqual(ak["headshot multiplier"], "4.0")
        self.assertEqual(ak["bullets"], "1")

    def test_glock_alt_and_bool(self):
        g = self.st["weapon_glock"]
        self.assertEqual((g["cycletime"], g["cycletime alt"], g["is full auto"]), ("0.15", "0.5", "0"))

    def test_nested_entry_and_missing(self):
        self.assertEqual(self.st["weapon_taser"]["damage"], "500")
        self.assertNotIn("cycletime alt", self.st["weapon_taser"])
        self.assertNotIn("weapon_awp", self.st)

    def test_only_strings_out(self):
        for n, a in self.st.items():
            for v in a.values():
                self.assertIsInstance(v, str)
                float(v)

    def test_sheet_keys_are_weapon_attributes(self):
        """Every vdata_keys attribute is one Weapons.gd reads (its COL map), so a filled value is used."""
        gd = os.path.join(os.path.dirname(os.path.dirname(HERE)), "game", "scripts", "Weapons.gd")
        with open(gd, encoding="utf-8") as f:
            src = f.read()
        for k in KEYS:
            self.assertIn('"%s"' % k["attribute"], src, k["id"])


if __name__ == "__main__":
    unittest.main()
