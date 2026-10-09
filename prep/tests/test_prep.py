"""prep.main end to end on the real sheets (prep/content.json, weapons.json, prep.json) with a fake VRF:
the done file appears only when every row and every weapon is in place; otherwise exit 1, the reasons
on screen and in prep_status.json (which the game shows), and a rerun redoes only what is missing."""
import os, sys, io, json, glob, shutil, tempfile, unittest, contextlib
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import prep, prep_cs2
from fakevrf import FakeVRF, glb_bytes, wav_bytes

WEAPONS = prep_cs2.weapon_rows(prep_cs2.sheet("weapons"))


def items_game_for(rows, skip=()):
    """An items_game.txt naming every sheet weapon through a two-level prefab chain."""
    pre = "".join('"%s_prefab" { "prefab" "rifle" "attributes" { "damage" "30" "cycletime" "0.1" } }\n' % w["item"] for w in rows)
    items = "".join('"%d" { "name" "%s" "prefab" "%s_prefab" }\n' % (i, w["item"], w["item"]) for i, w in enumerate(rows) if w["item"] not in skip)
    return '"items_game" { "prefabs" { "rifle" { "attributes" { "is full auto" "1" } }\n%s }\n"items" {\n%s } }\n' % (pre, items)


def fake_rust(a):
    """Stands in for rust_step (UnityPy is not in the test environment): writes every rust row's output."""
    for r in prep.rows(game="rust"):
        for p in prep_cs2.expand(r["out"].split(" ")[0]):
            p = os.path.join(a.out, p.replace("*", "fake"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(glb_bytes() if p.endswith(".glb") else wav_bytes() if p.endswith(".wav") else b"x")


class Prep(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.out = os.path.join(self.d, "data")
        self.cs2 = os.path.join(self.d, "cs2")
        self.tools = os.path.join(self.d, "tools")
        os.makedirs(os.path.join(self.cs2, "game", "csgo"))
        for p in (os.path.join(self.cs2, "game", "csgo", "pak01_dir.vpk"), os.path.join(self.tools, "vrf", "Source2Viewer-CLI.exe")):
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "wb").close()

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def main(self, vrf, steps=None, rust=None):
        argv = ["--rust", rust or os.path.join(self.d, "rust"), "--cs2", self.cs2, "--out", self.out, "--tools", self.tools, "--version", "9.9.9"]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = prep.main(argv, steps or (prep.cs2_step, fake_rust), vrf)
        return code, buf.getvalue()

    def status(self):
        with open(os.path.join(self.out, "prep_status.json"), encoding="utf-8") as f:
            return json.load(f)

    def done(self):
        return os.path.exists(os.path.join(self.out, "done-9.9.9.txt"))

    def test_everything_exports(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done())
        st = self.status()
        self.assertTrue(st["ok"])
        self.assertEqual(st["player"], [])
        with open(os.path.join(self.out, "cs2", "weapon_stats.json"), encoding="utf-8") as f:
            stats = json.load(f)
        self.assertEqual(len(stats), len(WEAPONS))
        self.assertEqual(stats["weapon_ak47"]["is full auto"], "1")
        self.assertIn("RUST SURF SETUP OK", out)

    def test_flaky_vrf_still_finishes(self):
        flaky = [WEAPONS[0]["model"], WEAPONS[3]["clips"]["idle"], WEAPONS[5]["sound_shot"], prep_cs2.ITEMS_GAME]
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), flaky=flaky, poison=flaky[:1]))
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done())

    def test_one_weapon_missing_blocks_done(self):
        w = WEAPONS[7]
        v = FakeVRF(items_game_for(WEAPONS), bad=[w["clips"]["idle"]], poison=[w["clips"]["idle"]])
        code, out = self.main(v)
        self.assertEqual(code, 1)
        self.assertFalse(self.done())
        st = self.status()
        self.assertFalse(st["ok"])
        self.assertTrue(any(w["id"] in p and "clip idle" in p for p in st["problems"]), st["problems"])
        self.assertTrue(st["player"][0].startswith("Prep: "))
        self.assertIn("RUST SURF SETUP DID NOT FINISH", out)
        # the next start: the file exports now, and only the missing files are asked for
        v2 = FakeVRF(items_game_for(WEAPONS))
        code, out = self.main(v2)
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done())
        asked = {f for files, _ in v2.calls for f in files}
        self.assertEqual(asked, {w["clips"]["idle"]})

    def test_items_game_missing_blocks_done(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), bad=[prep_cs2.ITEMS_GAME]))
        self.assertEqual(code, 1)
        self.assertTrue(any("items_game.txt did not export" in p for p in self.status()["problems"]))

    def test_weapon_not_in_items_game_blocks_done(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS, skip=["weapon_awp"]).replace('"weapon_awp_prefab"', '"x_prefab"')))
        self.assertEqual(code, 1)
        self.assertTrue(any("no item for: weapon_awp" in p for p in self.status()["problems"]), self.status())

    def test_thin_stats_warn_but_finish(self):
        ig = items_game_for(WEAPONS).replace('"weapon_deagle_prefab" { "prefab" "rifle" "attributes" { "damage" "30" "cycletime" "0.1" } }', '"weapon_deagle_prefab" { }')
        code, out = self.main(FakeVRF(ig))
        self.assertEqual(code, 0, out)
        self.assertTrue(any("weapon_deagle" in w for w in self.status()["warnings"]))

    def test_rust_content_missing_blocks_done(self):
        def half_rust(a):
            fake_rust(a)
            os.remove(os.path.join(a.out, "rust", "launch_site_placements.json"))
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)), steps=(prep.cs2_step, half_rust))
        self.assertEqual(code, 1)
        self.assertTrue(any("scene_launch_site" in p for p in self.status()["problems"]))

    def test_no_rust_install_says_so(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)), steps=(prep.cs2_step, prep.rust_step))
        self.assertEqual(code, 1)
        self.assertTrue(any(p.startswith("Rust not found") for p in self.status()["problems"]), self.status())

    def test_no_cs2_install_says_so(self):
        os.remove(os.path.join(self.cs2, "game", "csgo", "pak01_dir.vpk"))
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 1)
        self.assertTrue(any(p.startswith("CS2 not found") for p in self.status()["problems"]))

    def test_no_vrf_says_so(self):
        os.remove(os.path.join(self.tools, "vrf", "Source2Viewer-CLI.exe"))
        code, out = self.main(None)
        self.assertEqual(code, 1)
        self.assertTrue(any("Source2Viewer-CLI.exe is missing" in p for p in self.status()["problems"]))

    def test_crashing_step_is_reported(self):
        def boom(a):
            raise ValueError("bad bundle")
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)), steps=(prep.cs2_step, boom))
        self.assertEqual(code, 1)
        self.assertTrue(any("boom crashed (ValueError: bad bundle)" in p for p in self.status()["problems"]))

    def test_stale_done_file_is_removed_on_failure(self):
        os.makedirs(self.out)
        open(os.path.join(self.out, "done-9.9.9.txt"), "w").close()
        code, _ = self.main(FakeVRF(items_game_for(WEAPONS), bad=[WEAPONS[0]["model"]]))
        self.assertEqual(code, 1)
        self.assertFalse(self.done())

    def test_local_data_folder_passes_content_check(self):
        """The real local prep output, when this machine has one (never in the repo)."""
        data = os.environ.get("RS_DATA", "")
        if not os.path.isdir(os.path.join(data, "rust")):
            self.skipTest("set RS_DATA to an extracted data folder")
        miss = prep.content_missing(data)
        self.assertEqual(miss, [], miss)


class Sheets(unittest.TestCase):
    def test_every_weapon_has_the_columns_prep_reads(self):
        self.assertGreater(len(WEAPONS), 0)
        for w in WEAPONS:
            self.assertTrue(w["model"].endswith(".vmdl_c"), w["id"])
            self.assertTrue(w["sound_shot"].endswith(".vsnd_c"), w["id"])
            self.assertIn("idle", w["clips"], w["id"])
            for c in w["clips"].values():
                self.assertTrue(c.endswith(".vnmclip_c"), (w["id"], c))

    def test_prep_settings(self):
        cfg = prep_cs2.settings()
        for k in ("vrf_batch_files", "vrf_batch_chars", "vrf_retries", "vrf_timeout_s"):
            self.assertGreater(int(cfg[k]), 0, k)
        self.assertLess(int(cfg["vrf_batch_chars"]), 32767 - 1024)


if __name__ == "__main__":
    unittest.main()
