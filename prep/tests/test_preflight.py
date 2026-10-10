"""tools/preflight.py: the repo's sheets are clean, and gameplay-critical unverified rows are a recorded decision
(tools/unverified_ack.json) that tools/package.py's release gate enforces."""
import os, sys, json, shutil, tempfile, unittest, unittest.mock, contextlib, io
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))
import preflight, package


class Repo(unittest.TestCase):
    def test_clean(self):
        problems, unsure = preflight.check(REPO)
        self.assertEqual(problems, [])
        self.assertGreater(len(unsure), 0)

    def test_ack_file_names_existing_sheets(self):
        ack = preflight.load_ack(REPO)
        self.assertTrue(ack["critical"])
        for n in ack["critical"]:
            self.assertTrue(os.path.isfile(os.path.join(REPO, "sheets", n + ".json")), n)


class Ack(unittest.TestCase):
    """A copy of the repo's sheets and tools: ack, then change a critical row, a cosmetic row, and verify one."""

    def setUp(self):
        self.r = tempfile.mkdtemp()
        shutil.copytree(os.path.join(REPO, "sheets"), os.path.join(self.r, "sheets"))
        os.makedirs(os.path.join(self.r, "tools"))
        shutil.copy(os.path.join(REPO, preflight.ACK), os.path.join(self.r, preflight.ACK))

    def tearDown(self):
        shutil.rmtree(self.r, ignore_errors=True)

    def sheet(self, n, edit=None):
        p = os.path.join(self.r, "sheets", n + ".json")
        with open(p, encoding="utf-8") as f:
            s = json.load(f)
        if edit:
            edit(s)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(s, f)
        return s

    def first_unsure(self, n):
        s = self.sheet(n)
        for t, cols, rows in preflight.tables(s):
            vcol = [c for c in preflight.VERIFY if c in cols]
            for i, r in enumerate(rows if vcol else []):
                if preflight.is_unsure(r.get(vcol[0])):
                    return t, i, vcol[0]
        self.fail("no unverified row in " + n)

    def test_cycle(self):
        crit = preflight.load_ack(self.r)["critical"]
        with open(os.path.join(self.r, preflight.ACK), "w", encoding="utf-8") as f:
            json.dump({"critical": crit, "rows": {}}, f)
        before = preflight.critical_unacked(self.r)
        self.assertEqual(len(before), len(preflight.unsure_rows(self.r, set(crit))))
        self.assertTrue(all(b.endswith("(new)") for b in before))
        changed, dropped = preflight.write_ack(self.r)
        self.assertEqual(len(changed), len(before))
        self.assertEqual(preflight.critical_unacked(self.r), [])
        # a critical row's number changes: the release must see it again
        n = crit[0]
        t, i, vc = self.first_unsure(n)
        key = [c for c in self.sheet(n)[t][i] if c not in ("id", vc)][0]
        self.sheet(n, lambda s: s[t][i].__setitem__(key, str(s[t][i][key]) + "9"))
        left = preflight.critical_unacked(self.r)
        self.assertEqual(len(left), 1)
        self.assertTrue(left[0].endswith("(changed)"), left)
        # a cosmetic sheet's unverified row is not a release decision
        t2, i2, vc2 = self.first_unsure("lighting")
        self.sheet("lighting", lambda s: s[t2][i2].__setitem__(vc2, s[t2][i2][vc2] + " again"))
        self.assertEqual(len(preflight.critical_unacked(self.r)), 1)
        # verifying the row clears it, and --ack drops it from the record
        self.sheet(n, lambda s: s[t][i].__setitem__(vc, "verified 2026-10-10 against a capture"))
        self.assertEqual(preflight.critical_unacked(self.r), [])
        changed, dropped = preflight.write_ack(self.r)
        self.assertEqual((changed, len(dropped)), ([], 1))

    def test_new_row(self):
        preflight.write_ack(self.r)
        n = preflight.load_ack(self.r)["critical"][0]
        t, i, vc = self.first_unsure(n)
        self.sheet(n, lambda s: s[t].append(dict(s[t][i], id="zz_new_row")))
        self.assertEqual([x for x in preflight.critical_unacked(self.r)], ["%s.zz_new_row (new)" % (n if t == "rows" else n + "." + t)])

    def test_missing_ack_file_is_a_problem(self):
        os.remove(os.path.join(self.r, preflight.ACK))
        left = preflight.critical_unacked(self.r)
        self.assertEqual(len(left), 1)
        self.assertIn("missing", left[0])

    def test_release_gate_refuses_unacked_rows(self):
        """gates() refuses unacknowledged critical rows (the Godot, unit test and release data gates are stubbed out here)."""
        for d in ("prep", os.path.join("game", "data"), os.path.join("game", "scripts")):
            shutil.copytree(os.path.join(REPO, d), os.path.join(self.r, d), ignore=shutil.ignore_patterns("__pycache__", "tests"))
        with open(os.path.join(self.r, preflight.ACK), "w", encoding="utf-8") as f:
            json.dump({"critical": ["weapon_defaults"], "rows": {}}, f)
        with unittest.mock.patch.object(package, "unit_tests", lambda *a, **k: []), \
                unittest.mock.patch.object(package, "godot_gate", lambda *a, **k: []), \
                unittest.mock.patch.object(package, "check_release_data", lambda *a, **k: ([], {"guns": 1, "guns_with_stats": 1, "stats_sources": []})), \
                contextlib.redirect_stdout(io.StringIO()):
            errs, unverified, report = package.gates(self.r, "", "", "0.0.0", log=lambda s: None)
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("gameplay-critical unverified row(s) not acknowledged", errs[0])
        preflight.write_ack(self.r)
        with unittest.mock.patch.object(package, "unit_tests", lambda *a, **k: []), \
                unittest.mock.patch.object(package, "godot_gate", lambda *a, **k: []), \
                unittest.mock.patch.object(package, "check_release_data", lambda *a, **k: ([], {"guns": 1, "guns_with_stats": 1, "stats_sources": []})):
            errs, unverified, report = package.gates(self.r, "", "", "0.0.0", log=lambda s: None)
        self.assertEqual(errs, [])


if __name__ == "__main__":
    unittest.main()
