"""prep_cs2: output checks, batching, per-file retries, skip-if-exported, and the real subprocess runner."""
import os, sys, shutil, stat, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import prep_cs2
from fakevrf import FakeVRF, glb_bytes, wav_bytes

prep_cs2.LOG = lambda s: None
CFG = {"vrf_batch_files": 3, "vrf_batch_chars": 10000, "vrf_retries": 2, "vrf_timeout_s": 5}
FILES = ["a/m%d.vmdl_c" % i for i in range(7)] + ["s/s%d.vsnd_c" % i for i in range(3)]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def put(self, rel, data):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        return p


class Helpers(Tmp):
    def test_expand(self):
        self.assertEqual(prep_cs2.expand("x/a_{albedo,normal}.png"), ["x/a_albedo.png", "x/a_normal.png"])
        self.assertEqual(prep_cs2.expand("c_0{1..4}.wav"), ["c_01.wav", "c_02.wav", "c_03.wav", "c_04.wav"])
        self.assertEqual(prep_cs2.expand("{a,b}_{1..2}"), ["a_1", "a_2", "b_1", "b_2"])
        self.assertEqual(prep_cs2.expand("plain.glb"), ["plain.glb"])

    def test_outputs(self):
        self.assertEqual(prep_cs2.outputs("s/x.vsnd_c"), ["s/x.wav", "s/x.mp3"])
        self.assertEqual(prep_cs2.outputs("m/x.vmdl_c"), ["m/x.glb"])
        self.assertEqual(prep_cs2.outputs("a/x.vnmclip_c"), ["a/x.glb"])
        self.assertEqual(prep_cs2.outputs("scripts/items/items_game.txt"), ["scripts/items/items_game.txt"])

    def test_file_ok(self):
        self.assertTrue(prep_cs2.file_ok(self.put("a.glb", glb_bytes())))
        self.assertFalse(prep_cs2.file_ok(self.put("b.glb", glb_bytes()[:-1])))   # cut short: length field disagrees
        self.assertFalse(prep_cs2.file_ok(self.put("c.glb", b"")))
        self.assertTrue(prep_cs2.file_ok(self.put("a.wav", wav_bytes())))
        self.assertFalse(prep_cs2.file_ok(self.put("b.wav", wav_bytes()[:30])))
        self.assertTrue(prep_cs2.file_ok(self.put("a.mp3", b"\xff\xfb\x90\xc4\0\0")))
        self.assertTrue(prep_cs2.file_ok(self.put("b.mp3", b"ID3\x04\0")))
        self.assertFalse(prep_cs2.file_ok(self.put("c.mp3", b"<html>")))
        self.assertTrue(prep_cs2.file_ok(self.put("a.txt", b"x")))
        self.assertFalse(prep_cs2.file_ok(os.path.join(self.d, "nope.glb")))

    def test_batches_cap_count_and_chars(self):
        b = list(prep_cs2.batches(["x" * 10] * 7, 3, 10000))
        self.assertEqual([len(x) for x in b], [3, 3, 1])
        b = list(prep_cs2.batches(["x" * 10] * 7, 40, 25))
        self.assertEqual([len(x) for x in b], [2, 2, 2, 1])
        for x in b:
            self.assertLessEqual(len(",".join(x)), 25)

    def test_content_sources(self):
        rows = [{"game": "cs2", "kind": "audio", "source": "s/c_01..04.vsnd_c (four)"},
                {"game": "cs2", "kind": "model", "source": "m/arms.vmdl_c"},
                {"game": "cs2", "kind": "config", "source": "x"},
                {"game": "rust", "kind": "audio", "source": "y"}]
        plain, gltf = prep_cs2.content_sources(rows)
        self.assertEqual(plain, ["s/c_01.vsnd_c", "s/c_02.vsnd_c", "s/c_03.vsnd_c", "s/c_04.vsnd_c"])
        self.assertEqual(gltf, ["m/arms.vmdl_c"])


class Export(Tmp):
    def go(self, vrf, files=FILES):
        return prep_cs2.export(vrf(None, self.d, 5), self.d, files, [], CFG)

    def test_clean(self):
        v = FakeVRF()
        self.assertEqual(self.go(v), [])
        self.assertEqual(len(v.calls), 4)  # 10 files in batches of 3

    def test_flaky_file_is_retried_alone(self):
        v = FakeVRF(flaky=["a/m4.vmdl_c"])
        self.assertEqual(self.go(v), [])
        self.assertIn((["a/m4.vmdl_c"], []), v.calls)

    def test_poisoned_batch_recovers_one_by_one(self):
        v = FakeVRF(poison=["a/m4.vmdl_c"], bad=["a/m4.vmdl_c"])  # one bad path kills its whole batch
        self.assertEqual(self.go(v), ["a/m4.vmdl_c"])
        for f in FILES:
            if f != "a/m4.vmdl_c":
                self.assertTrue(prep_cs2.present(self.d, f), f)
        self.assertEqual(sum(1 for c, _ in v.calls if c == ["a/m4.vmdl_c"]), CFG["vrf_retries"])

    def test_truncated_output_is_redone(self):
        v = FakeVRF(truncate=["a/m2.vmdl_c"])
        self.assertEqual(self.go(v), [])
        self.assertTrue(prep_cs2.file_ok(os.path.join(self.d, "a/m2.glb")))

    def test_rerun_skips_what_is_whole(self):
        self.go(FakeVRF())
        os.remove(os.path.join(self.d, "s/s1.wav"))
        v = FakeVRF()
        self.assertEqual(self.go(v), [])
        self.assertEqual(v.calls, [(["s/s1.vsnd_c"], [])])

    def test_never_exports(self):
        v = FakeVRF(bad=["s/s0.vsnd_c", "a/m0.vmdl_c"])
        self.assertEqual(sorted(self.go(v)), ["a/m0.vmdl_c", "s/s0.vsnd_c"])


@unittest.skipIf(os.name == "nt", "the fake VRF executable is a POSIX script")
class Runner(Tmp):
    """vrf_runner with a real child process: non-ASCII output, non-zero exit, a hang past the timeout."""

    def exe(self, body):
        p = os.path.join(self.d, "vrf")
        with open(p, "w", encoding="utf-8") as f:
            f.write("#!%s\nimport sys, time\n%s\n" % (sys.executable, body))
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
        return p

    def test_ok_and_args(self):
        run = prep_cs2.vrf_runner(self.exe("open(sys.argv[-1], 'w').write(' '.join(sys.argv[1:]))\nprint('Größe ✓')"), "pak.vpk", self.d, 5)
        log = os.path.join(self.d, "args.txt")
        self.assertTrue(run(["a.vmdl_c", "b.vmdl_c"], [log]))
        with open(log, encoding="utf-8") as f:
            got = f.read()
        self.assertEqual(got, "-i pak.vpk -o %s -d -f a.vmdl_c,b.vmdl_c %s" % (self.d, log))

    def test_failure_with_non_ascii_bytes(self):
        run = prep_cs2.vrf_runner(self.exe("sys.stdout.buffer.write(b'\\xff\\xfe bad bytes \\xe9'); sys.exit(3)"), "pak.vpk", self.d, 5)
        self.assertFalse(run(["a.vmdl_c"], []))

    def test_timeout(self):
        run = prep_cs2.vrf_runner(self.exe("time.sleep(30)"), "pak.vpk", self.d, 1)
        self.assertFalse(run(["a.vmdl_c"], []))

    def test_missing_exe_is_a_prep_error(self):
        run = prep_cs2.vrf_runner(os.path.join(self.d, "nope.exe"), "pak.vpk", self.d, 5)
        with self.assertRaises(prep_cs2.PrepError):
            run(["a.vmdl_c"], [])


if __name__ == "__main__":
    unittest.main()
