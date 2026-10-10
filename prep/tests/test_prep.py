"""prep.main end to end on the real sheets (prep/content.json, weapons.json, prep.json) with a fake VRF:
the done file appears only when every row and every weapon is in place; otherwise exit 1, the reasons
on screen and in prep_status.json (which the game shows), and a rerun redoes only what is missing."""
import os, sys, io, json, glob, shutil, tempfile, unittest, contextlib
from unittest import mock
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import prep, prep_cs2
from fakevrf import FakeVRF, glb_bytes, wav_bytes, png_bytes

WEAPONS = prep_cs2.weapon_rows(prep_cs2.sheet("weapons"))
VDATA = prep_cs2.settings()["weapons_vdata"]
CFG = prep_cs2.settings()
STAT_KEYS = sorted(set(prep_cs2.keys(CFG["stats_required"]) + prep_cs2.keys(CFG["stats_required_light"]) + prep_cs2.keys(CFG["stats_expected"])))
VALUES = {"damage": "30", "cycletime": "0.1", "primary clip size": "30", "max player speed": "215"}
FULL = " ".join('"%s" "%s"' % (k, VALUES.get(k, "1")) for k in STAT_KEYS)  # every stat prep asks for, as a number


def blocking(on=True):
    """prep_cs2.settings with stats_required_blocks forced (the sheet ships "no" until real CS2 keys are seen)."""
    real = prep_cs2.settings
    return mock.patch.object(prep_cs2, "settings", lambda here=prep_cs2.HERE: dict(real(here), stats_required_blocks="yes" if on else "no"))


def items_game_for(rows, skip=()):
    """An items_game.txt naming every sheet weapon through a two-level prefab chain."""
    pre = "".join('"%s_prefab" { "prefab" "rifle" "attributes" { %s } }\n' % (w["item"], FULL) for w in rows)
    items = "".join('"%d" { "name" "%s" "prefab" "%s_prefab" }\n' % (i, w["item"], w["item"]) for i, w in enumerate(rows) if w["item"] not in skip)
    return '"items_game" { "prefabs" { "rifle" { "attributes" { "is full auto" "1" } }\n%s }\n"items" {\n%s } }\n' % (pre, items)


def fake_rust(a):
    """Stands in for rust_step (UnityPy is not in the test environment): writes every rust row's output,
    and a placements file naming one mesh (whose glb names a texture) and one material."""
    for r in prep.rows(game="rust"):
        for p in prep_cs2.expand(r["out"].split(" ")[0]):
            p = os.path.join(a.out, p.replace("*", "fake"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(glb_bytes("mesh", ["../tex/fake_albedo.png"]) if p.endswith(".glb") else wav_bytes() if p.endswith(".wav")
                        else png_bytes() if p.endswith(".png") else b"x")
    with open(os.path.join(a.out, "rust", "tex", "fake_albedo.png"), "wb") as f:
        f.write(png_bytes())
    prep_cs2.write_json(os.path.join(a.out, "rust", "launch_site_placements.json"),
                        {"prefab": "x", "placements": [{"mesh": "fake", "pos": [0, 0, 0]}], "materials": {"fake": {"albedo": "fake_albedo.png"}}})


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

    def main(self, vrf, steps=None, rust=None, extra=()):
        argv = ["--rust", rust or os.path.join(self.d, "rust"), "--cs2", self.cs2, "--out", self.out, "--tools", self.tools, "--version", "9.9.9"] + list(extra)
        buf = io.StringIO()
        self.boxes = []  # (title, text, wait) of every message box prep asked for; never a real one in a test
        with contextlib.redirect_stdout(buf):
            code = prep.main(argv, steps or (prep.cs2_step, fake_rust), vrf, show=lambda *b: self.boxes.append(b))
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
        self.assertEqual(asked, {w["clips"]["idle"], prep_cs2.ITEMS_GAME, VDATA})  # the stats files are always fresh

    def test_items_game_missing_blocks_done(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), bad=[prep_cs2.ITEMS_GAME]))
        self.assertEqual(code, 1)
        self.assertTrue(any("items_game.txt did not export" in p for p in self.status()["problems"]))

    def test_items_game_missing_blocks_done_even_when_vdata_has_every_stat(self):
        """weapons.vdata fills gaps; it never stands in for an items_game.txt that failed to export."""
        fields = " ".join("%s = 1" % r["id"] for r in prep_cs2.sheet("prep")["vdata_keys"])
        vd = ('<!-- kv3 encoding:text:version{e21c7f3c} format:generic:version{7412167c} -->\n{ %s }'
              % " ".join("%s = { %s }" % (w["item"], fields) for w in WEAPONS))
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), bad=[prep_cs2.ITEMS_GAME], vdata=vd))
        self.assertEqual(code, 1, out)
        self.assertFalse(self.done())
        self.assertIn("weapons.vdata", out)  # it was read
        self.assertTrue(any("items_game.txt did not export whole" in p for p in self.status()["problems"]), self.status())
        self.assertTrue(any(l.startswith("Prep: CS2's scripts/items/items_game.txt") for l in self.status()["player"]))

    def test_weapon_not_in_items_game_blocks_done(self):
        code, out = self.main(FakeVRF(items_game_for(WEAPONS, skip=["weapon_awp"]).replace('"weapon_awp_prefab"', '"x_prefab"')))
        self.assertEqual(code, 1)
        self.assertTrue(any("no weapon entry for weapon_awp" in p for p in self.status()["problems"]), self.status())

    def thin(self):
        return items_game_for(WEAPONS).replace('"weapon_deagle_prefab" { "prefab" "rifle" "attributes" { %s } }' % FULL, '"weapon_deagle_prefab" { }')

    def test_missing_stats_warn_by_default(self):
        """The shipped sheet: a gun CS2 gives no stats for still finishes setup (unverified key names must not brick
        every install), but never quietly: the player lines name the gun, the keys and the real fix."""
        self.assertFalse(prep_cs2.blocks(prep_cs2.settings()))
        code, out = self.main(FakeVRF(self.thin()))
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done())
        w = [x for x in self.status()["player"] if x.startswith("Prep warning: ")]
        self.assertTrue(any("weapon_deagle (damage/cycletime/" in x and "class-average" in x and "needs an update" in x for x in w), w)
        self.assertEqual(self.boxes, [])

    def test_missing_damage_blocks_done(self):
        """With stats_required_blocks yes, no damage/cycletime for a gun is a problem, not a fall back to class averages."""
        with blocking():
            code, out = self.main(FakeVRF(self.thin()))
        self.assertEqual(code, 1, out)
        self.assertFalse(self.done())
        p = self.status()["problems"]
        self.assertTrue(any("weapon_deagle (damage/cycletime/" in x and "guessed numbers" in x for x in p), p)

    def without(self, item, key, value=None):
        """items_game_for(WEAPONS) with one attribute of one weapon dropped, or set to value."""
        body = FULL.replace('"%s" "%s"' % (key, VALUES.get(key, "1")), "" if value is None else '"%s" "%s"' % (key, value))
        return items_game_for(WEAPONS).replace('"%s_prefab" { "prefab" "rifle" "attributes" { %s } }' % (item, FULL),
                                               '"%s_prefab" { "prefab" "rifle" "attributes" { %s } }' % (item, body))

    def test_each_required_stat_blocks_done(self):
        """Every stat the gun model reads is required: one gone (or not a number) stops setup and names it."""
        for key in ("recoil seed", "armor ratio", "penetration", "recovery time crouch", "inaccuracy move"):
            for value in (None, "fast"):
                with blocking(False):
                    code, out = self.main(FakeVRF(self.without("weapon_ak47", key, value)))
                self.assertEqual(code, 0, (key, value))
                self.assertTrue(any("weapon_ak47 (%s)" % key in x for x in self.status()["warnings"]), self.status())
                with blocking():
                    code, out = self.main(FakeVRF(self.without("weapon_ak47", key, value)))
                self.assertEqual(code, 1, (key, value))
                self.assertFalse(self.done())
                p = self.status()["problems"]
                self.assertTrue(any("weapon_ak47 (%s)" % key in x for x in p), p)
                self.assertTrue(any("weapon_ak47 (%s)" % key in x for x in self.status()["player"]), self.status())

    def test_light_slot_needs_less(self):
        """The Zeus (stats_light_slots) does not need a recoil pattern; a rifle does."""
        code, out = self.main(FakeVRF(self.without("weapon_taser", "recoil seed")))
        self.assertEqual(code, 0, out)
        with blocking():
            code, out = self.main(FakeVRF(self.without("weapon_taser", "damage")))
        self.assertEqual(code, 1, out)
        self.assertTrue(any("weapon_taser (damage)" in x for x in self.status()["problems"]), self.status())

    def test_expected_stat_is_a_warning(self):
        code, out = self.main(FakeVRF(self.without("weapon_awp", "headshot multiplier")))
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done())
        self.assertTrue(any("weapon_awp (headshot multiplier)" in w for w in self.status()["warnings"]), self.status())

    def test_vdata_fills_what_items_game_lacks(self):
        fields = " ".join("%s = 1" % r["id"] for r in prep_cs2.sheet("prep")["vdata_keys"] if r["id"] not in ("m_nDamage", "m_flCycleTime"))
        vd = ('<!-- kv3 encoding:text:version{e21c7f3c} format:generic:version{7412167c} -->\n'
              '{ weapon_deagle = { m_nDamage = 53 m_flCycleTime = [ 0.225, 0.225 ] %s } }' % fields)
        code, out = self.main(FakeVRF(self.thin(), vdata=vd))
        self.assertEqual(code, 0, out)
        with open(os.path.join(self.out, "cs2", "weapon_stats.json"), encoding="utf-8") as f:
            st = json.load(f)
        self.assertEqual((st["weapon_deagle"]["damage"], st["weapon_deagle"]["cycletime"], st["weapon_deagle"]["cycletime alt"]), ("53", "0.225", "0.225"))
        self.assertEqual(st["weapon_deagle"]["_source"], "weapons.vdata")  # its items_game entry had no attributes
        self.assertEqual(st["weapon_ak47"]["damage"], "30")  # items_game.txt wins where it has the value
        self.assertEqual(st["weapon_ak47"]["_source"], "items_game.txt")
        self.assertFalse(any("weapon_deagle" in w for w in self.status()["warnings"]))  # vdata gave every stat

    def test_disagreeing_files_are_recorded_and_the_winner_played(self):
        """items_game.txt says 30 for the AK's damage, weapons.vdata 36: logged, kept under _conflicts, and the
        stats_conflict_winner value goes into weapon_stats.json (which the game reads over items_game.txt).
        0.1 against 0.100000 is the same value, not a conflict."""
        vd = ('<!-- kv3 encoding:text:version{e21c7f3c} format:generic:version{7412167c} -->\n'
              '{ weapon_ak47 = { m_nDamage = 36 m_flCycleTime = [ 0.100000, 0.2 ] } }')
        stats = os.path.join(self.out, "cs2", "weapon_stats.json")
        self.assertEqual(prep_cs2.settings()["stats_conflict_winner"], "items_game.txt")
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), vdata=vd))
        self.assertEqual(code, 0, out)
        self.assertIn("stats conflict: weapon_ak47 damage items_game.txt 30, weapons.vdata 36; playing the items_game.txt value", out)
        with open(stats, encoding="utf-8") as f:
            ak = json.load(f)["weapon_ak47"]
        self.assertEqual((ak["damage"], ak["cycletime"], ak["cycletime alt"]), ("30", "0.1", "0.2"))
        self.assertEqual(ak["_conflicts"], {"damage": {"items_game.txt": "30", "weapons.vdata": "36"}})
        self.assertEqual(ak["_source"], "items_game.txt + weapons.vdata")
        real = prep_cs2.settings
        with mock.patch.object(prep_cs2, "settings", lambda here=prep_cs2.HERE: dict(real(here), stats_conflict_winner="weapons.vdata")):
            code, out = self.main(FakeVRF(items_game_for(WEAPONS), vdata=vd))
        self.assertEqual(code, 0, out)
        with open(stats, encoding="utf-8") as f:
            ak = json.load(f)["weapon_ak47"]
        self.assertEqual((ak["damage"], ak["_conflicts"]["damage"]["items_game.txt"]), ("36", "30"))
        self.assertIn("playing the weapons.vdata value", out)

    def test_stale_items_game_is_replaced(self):
        """A CS2 update: an earlier export is never reused for the stats."""
        self.main(FakeVRF(items_game_for(WEAPONS)))
        with blocking():
            code, out = self.main(FakeVRF(self.thin()))
        self.assertEqual(code, 1, out)

    def test_cut_items_game_is_not_read(self):
        ig = items_game_for(WEAPONS)
        code, out = self.main(FakeVRF(ig[:len(ig) // 2], bad=()))
        self.assertEqual(code, 1, out)
        self.assertTrue(any("did not export or is damaged" in p for p in self.status()["problems"]), self.status())

    def test_broken_texture_blocks_done(self):
        w = WEAPONS[2]
        code, out = self.main(FakeVRF(items_game_for(WEAPONS), badtex=[w["model"]]))
        self.assertEqual(code, 1, out)
        self.assertTrue(any(w["id"] + " (model)" in p for p in self.status()["problems"]), self.status())

    def test_rust_content_missing_blocks_done(self):
        def half_rust(a):
            fake_rust(a)
            os.remove(os.path.join(a.out, "rust", "launch_site_placements.json"))
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)), steps=(prep.cs2_step, half_rust))
        self.assertEqual(code, 1)
        self.assertTrue(any("scene_launch_site" in p for p in self.status()["problems"]))

    def test_broken_scene_piece_blocks_done(self):
        def cut_texture(a):
            fake_rust(a)
            p = os.path.join(a.out, "rust", "tex", "fake_albedo.png")
            with open(p, "r+b") as f:
                f.seek(20)
                f.write(b"garbled")  # same size, a chunk CRC no longer matches
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)), steps=(prep.cs2_step, cut_texture))
        self.assertEqual(code, 1, out)
        p = self.status()["problems"]
        self.assertTrue(any("Launch Site mesh(es)/texture(s) did not extract whole: fake, fake_albedo.png" in x for x in p), p)

    def test_local_data_folder_scene_is_whole(self):
        """The real local prep output, when this machine has one (never in the repo)."""
        data = os.environ.get("RS_DATA", "")
        if not os.path.isdir(os.path.join(data, "rust")):
            self.skipTest("set RS_DATA to an extracted data folder")
        self.assertEqual(prep.scene_missing(data), [])

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

    def test_failure_opens_one_message_box_with_the_reasons(self):
        w = WEAPONS[1]
        code, _ = self.main(FakeVRF(items_game_for(WEAPONS), bad=[w["model"]]))
        self.assertEqual(code, 1)
        self.assertEqual(len(self.boxes), 1)
        title, text, wait = self.boxes[0]
        self.assertIn("did not finish", title)
        self.assertIn(w["id"] + " (model)", text)
        self.assertIn(os.path.join(self.out, "prep.log"), text)
        self.assertEqual(wait, float(prep_cs2.settings()["fail_dialog_s"]))
        code, _ = self.main(FakeVRF(items_game_for(WEAPONS), bad=[w["model"]]), extra=["--no-dialog"])
        self.assertEqual((code, self.boxes), (1, []))
        code, _ = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual((code, self.boxes), (0, []))

    def test_unreadable_prep_sheet_still_bounds_the_box(self):
        """prep.json holds fail_dialog_s: when it cannot be read the box still closes on its own, so an unattended
        setup exits instead of waiting for a click forever."""
        def broken(here=prep_cs2.HERE):
            raise ValueError("prep.json is damaged")
        with mock.patch.object(prep_cs2, "settings", broken):
            code, _ = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 1)
        self.assertEqual(len(self.boxes), 1)
        self.assertEqual(self.boxes[0][2], prep.DIALOG_FALLBACK_S)
        self.assertTrue(any("ValueError" in p for p in self.status()["problems"]))

    def test_dialog_text_stays_readable(self):
        a = type("A", (), {"out": self.out})()
        text = prep.dialog_text(a, ["x" * 1000] + ["p%d" % i for i in range(12)])
        self.assertLess(len(text), 1200)
        self.assertIn("and 5 more", text)

    def test_no_real_box_off_windows(self):
        if sys.platform == "win32":
            self.skipTest("would open a real message box")
        self.assertFalse(prep.dialog("t", "x", 0))

    def test_stale_done_file_is_removed_on_failure(self):
        os.makedirs(self.out)
        open(os.path.join(self.out, "done-9.9.9.txt"), "w").close()
        code, _ = self.main(FakeVRF(items_game_for(WEAPONS), bad=[WEAPONS[0]["model"]]))
        self.assertEqual(code, 1)
        self.assertFalse(self.done())

    def test_run_killed_half_way_leaves_no_done_file(self):
        """A rerun over a finished install that is closed half way (after the stats files were deleted for their
        fresh export) must not leave the old done file: Melty sets up again and the game names the run unfinished."""
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 0, out)
        def killed(a):
            os.remove(os.path.join(self.out, "cs2", "scripts", "items", "items_game.txt"))
            raise KeyboardInterrupt  # the console window closed: not an Exception, nothing below runs
        with self.assertRaises(KeyboardInterrupt):
            self.main(FakeVRF(items_game_for(WEAPONS)), steps=(killed,))
        self.assertFalse(self.done())
        st = self.status()
        self.assertFalse(st["ok"])
        self.assertTrue(st["player"] and "did not finish" in st["player"][0], st)
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))  # the next start redoes it and finishes
        self.assertEqual(code, 0, out)
        self.assertTrue(self.done() and self.status()["ok"])

    def test_cs2_update_exports_everything_fresh(self):
        """prep_status.json keeps pak01_dir.vpk's size and time; a rerun after CS2 changed it re-exports every CS2
        file (an old model or sound is not trusted), a rerun on the same CS2 skips what is whole."""
        vpk = os.path.join(self.cs2, "game", "csgo", "pak01_dir.vpk")
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 0, out)
        fp = self.status()["cs2_fingerprint"]
        self.assertEqual([f["path"] for f in fp["files"]], ["game/csgo/pak01_dir.vpk"])  # steam.inf absent: skipped
        self.assertEqual(fp["files"][0]["size"], 0)
        v = FakeVRF(items_game_for(WEAPONS))
        code, out = self.main(v)
        self.assertEqual(code, 0, out)
        same = sum(len(c[0]) for c in v.calls)
        self.assertNotIn("CS2 has updated", out)
        with open(vpk, "wb") as f:
            f.write(b"patched")
        v = FakeVRF(items_game_for(WEAPONS))
        code, out = self.main(v)
        self.assertEqual(code, 0, out)
        self.assertIn("CS2 has updated since the last setup", out)
        model = WEAPONS[0]["model"]
        self.assertIn(model, [f for c in v.calls for f in c[0]])
        self.assertGreater(sum(len(c[0]) for c in v.calls), same)
        self.assertEqual(self.status()["cs2_fingerprint"]["files"][0]["size"], 7)

    def test_failed_cs2_update_run_keeps_the_old_fingerprint(self):
        """A run killed after CS2 updated leaves the last finished export's fingerprint, so the next run still
        re-exports everything rather than trusting files from the old CS2 version."""
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 0, out)
        old = self.status()["cs2_fingerprint"]
        with open(os.path.join(self.cs2, "game", "csgo", "pak01_dir.vpk"), "wb") as f:
            f.write(b"patched")
        def killed(a):
            raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.main(FakeVRF(items_game_for(WEAPONS)), steps=(killed,))
        self.assertEqual(self.status()["cs2_fingerprint"], old)
        code, out = self.main(FakeVRF(items_game_for(WEAPONS)))
        self.assertEqual(code, 0, out)
        self.assertIn("CS2 has updated since the last setup", out)

    def test_fingerprint_changed(self):
        new = {"files": [{"path": "a", "size": 5, "mtime": 100}], "tolerance_s": 2.0}
        for old, want in ((None, False), ({}, False), ({"files": []}, False), ("garbage", False),
                          ({"files": [{"path": "a", "size": 5, "mtime": 101}], "tolerance_s": 2}, False),
                          ({"files": [{"path": "a", "size": 5, "mtime": 103}], "tolerance_s": 2}, True),
                          ({"files": [{"path": "a", "size": 6, "mtime": 100}], "tolerance_s": 2}, True),
                          ({"files": [{"path": "b", "size": 5, "mtime": 100}], "tolerance_s": 2}, True),
                          ({"files": [{"path": "a", "size": "x", "mtime": 100}], "tolerance_s": 2}, True)):
            self.assertEqual(prep_cs2.fingerprint_changed(old, new), want, old)

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
        for k in ("vrf_batch_files", "vrf_batch_chars", "vrf_retries", "vrf_timeout_s", "vrf_file_timeout_s", "vrf_hang_limit", "cs2_update_mtime_tolerance_s"):
            self.assertGreater(int(cfg[k]), 0, k)
        self.assertLess(int(cfg["vrf_batch_chars"]), 32767 - 1024)
        self.assertLessEqual(int(cfg["vrf_file_timeout_s"]), int(cfg["vrf_timeout_s"]))
        self.assertIn("game/csgo/pak01_dir.vpk", prep_cs2.keys(cfg["cs2_update_files"]))  # what prep exports from


if __name__ == "__main__":
    unittest.main()
