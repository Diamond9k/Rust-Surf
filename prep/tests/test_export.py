"""prep_cs2: output checks, batching, per-file retries, skip-if-exported, and the real subprocess runner."""
import os, sys, shutil, stat, tempfile, unittest, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import prep_cs2
from fakevrf import FakeVRF, glb_bytes, wav_bytes, png_bytes, png_chunk, garbled_png

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
        self.assertEqual(prep_cs2.outputs("scripts/weapons.vdata_c"), ["scripts/weapons.vdata", "scripts/weapons.vdata_c"])

    def test_file_ok(self):
        self.assertTrue(prep_cs2.file_ok(self.put("a.glb", glb_bytes())))
        self.assertFalse(prep_cs2.file_ok(self.put("b.glb", glb_bytes()[:-1])))   # cut short: length field disagrees
        self.assertFalse(prep_cs2.file_ok(self.put("c.glb", b"")))
        self.assertTrue(prep_cs2.file_ok(self.put("a.wav", wav_bytes())))
        self.assertFalse(prep_cs2.file_ok(self.put("b.wav", wav_bytes()[:30])))
        self.assertTrue(prep_cs2.file_ok(self.put("a.mp3", b"\xff\xfb\x90\xc4\0\0")))
        self.assertTrue(prep_cs2.file_ok(self.put("b.mp3", b"ID3\x04\0")))
        self.assertFalse(prep_cs2.file_ok(self.put("c.mp3", b"<html>")))
        self.assertTrue(prep_cs2.file_ok(self.put("a.txt", b'"a" { "b" "c" }')))
        self.assertFalse(prep_cs2.file_ok(self.put("b.txt", b'"a" { "b" "c"')))       # cut before its closing brace
        self.assertFalse(prep_cs2.file_ok(self.put("c.txt", b'"a" { "b" "c }')))      # cut inside a string
        self.assertTrue(prep_cs2.file_ok(self.put("a.vdata", b'<!-- kv3 -->\n{ a = 1 }')))
        self.assertFalse(prep_cs2.file_ok(self.put("b.vdata", b'<!-- kv3 -->\n{ a = { b = 1 }')))
        self.assertFalse(prep_cs2.file_ok(os.path.join(self.d, "nope.glb")))

    def test_glb_deep_check(self):
        self.assertTrue(prep_cs2.glb_ok(self.put("m.glb", glb_bytes("mesh")), "meshes"))
        self.assertFalse(prep_cs2.glb_ok(self.put("n.glb", glb_bytes("none")), "meshes"))       # a model with no mesh
        self.assertTrue(prep_cs2.glb_ok(self.put("c.glb", glb_bytes("clip")), "animations"))
        self.assertFalse(prep_cs2.glb_ok(self.put("d.glb", glb_bytes("mesh")), "animations"))  # a clip with no animation
        g = glb_bytes("mesh")
        self.assertFalse(prep_cs2.glb_ok(self.put("j.glb", g[:20] + b"x" + g[21:])))          # JSON chunk does not parse
        short_bin = g.replace(b'"byteLength": 64', b'"byteLength": 99')
        self.assertFalse(prep_cs2.glb_ok(self.put("b.glb", short_bin)))                       # BIN shorter than buffer 0
        self.assertFalse(prep_cs2.glb_ok(self.put("t.glb", glb_bytes("mesh", ["t_color.png"])), "meshes"))  # texture missing
        self.put("t_color.png", png_bytes())
        self.assertTrue(prep_cs2.glb_ok(os.path.join(self.d, "t.glb"), "meshes"))
        bad = bytearray(png_bytes())
        bad[30] ^= 0xFF
        self.put("t_color.png", bytes(bad))                                                   # garbled: a chunk CRC fails
        self.assertFalse(prep_cs2.glb_ok(os.path.join(self.d, "t.glb"), "meshes"))

    def test_png_check(self):
        self.assertTrue(prep_cs2.png_ok(self.put("a.png", png_bytes())))
        self.assertFalse(prep_cs2.png_ok(self.put("b.png", png_bytes()[:-12])))  # no IEND
        self.assertFalse(prep_cs2.png_ok(self.put("c.png", png_bytes() + b"x")))  # bytes after IEND
        self.assertFalse(prep_cs2.png_ok(self.put("d.png", b"GIF89a")))

    def test_png_pixel_stream(self):
        """CRCs alone pass a texture whose pixels are wrong; the inflated stream must match IHDR row for row."""
        self.assertTrue(prep_cs2.png_ok(self.put("rgba.png", png_bytes(37, 5, ctype=6, split=7))))   # IDAT in many chunks
        self.assertTrue(prep_cs2.png_ok(self.put("grey.png", png_bytes(3, 3, ctype=0))))
        self.assertTrue(prep_cs2.png_ok(self.put("adam7.png", png_bytes(5, 3, raw=b"\0" * prep_cs2.png_raw_size(5, 3, 8, 2, 1), interlace=1))))
        self.assertEqual(prep_cs2.png_raw_size(2048, 2048, 8, 6, 0), 2048 * (1 + 2048 * 4))
        self.assertFalse(prep_cs2.png_ok(self.put("g.png", garbled_png())))
        self.assertFalse(prep_cs2.png_ok(self.put("short.png", png_bytes(4, 4, raw=b"\0" * 20))))       # fewer rows than IHDR says
        self.assertFalse(prep_cs2.png_ok(self.put("long.png", png_bytes(1, 1, raw=b"\0" * 9))))         # more data than IHDR says
        self.assertFalse(prep_cs2.png_ok(self.put("filt.png", png_bytes(2, 2, raw=b"\0\0\0\0\0\0\0\x05\0\0\0\0\0\0"))))  # row filter 5
        good = png_bytes(2, 2)
        no_head = good[:8] + good[8 + 25:]                                                            # IDAT before IHDR
        self.assertFalse(prep_cs2.png_ok(self.put("nohead.png", no_head)))
        cut_z = good[:8] + good[8:33] + png_chunk(b"IDAT", zlib.compress(b"\0" * 14)[:-6]) + png_chunk(b"IEND", b"")
        self.assertFalse(prep_cs2.png_ok(self.put("cutz.png", cut_z)))                                  # zlib stream never ends

    def test_glb_with_garbled_texture_fails(self):
        self.put("t_color.png", garbled_png())
        self.assertFalse(prep_cs2.glb_ok(self.put("t.glb", glb_bytes("mesh", ["t_color.png"])), "meshes"))
        self.put("t%20b.png", png_bytes())
        self.assertFalse(prep_cs2.glb_ok(self.put("u.glb", glb_bytes("mesh", ["t%20b.png"])), "meshes"))   # uri is percent-encoded
        os.replace(os.path.join(self.d, "t%20b.png"), os.path.join(self.d, "t b.png"))
        self.assertTrue(prep_cs2.glb_ok(os.path.join(self.d, "u.glb"), "meshes"))

    def test_real_vrf_output_passes(self):
        """VRF 20 exports of the arms, knife and knife clips from a real CS2 install, when this machine has them."""
        data = os.environ.get("RS_DATA", "")
        cs2 = os.path.join(data, "cs2")
        if not os.path.isdir(cs2):
            self.skipTest("set RS_DATA to an extracted data folder")
        rows = [r for r in prep_cs2.sheet("content")["rows"] if r["game"] == "cs2" and r["kind"] in ("model", "animation")]
        self.assertGreater(len(rows), 0)
        for r in rows:
            self.assertTrue(prep_cs2.present(cs2, r["source"].split(" ")[0]), r["id"])

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

    def test_texture_garbled_in_batch_is_redone(self):
        """A batch export that garbles one model's colour texture (CRCs fine): the model fails its check, its damaged
        glb and texture are deleted, and the export on its own writes them whole, even from a VRF that never
        overwrites an existing file."""
        v = FakeVRF(batchtex=["a/m4.vmdl_c"], noclobber=True)
        self.assertEqual(self.go(v), [])
        self.assertTrue(prep_cs2.present(self.d, "a/m4.vmdl_c"))
        self.assertIn((["a/m4.vmdl_c"], []), v.calls)
        self.assertTrue(prep_cs2.png_ok(os.path.join(self.d, "a", "m4_color_psd_0.png")))

    def test_discard_keeps_whole_outputs(self):
        self.go(FakeVRF())
        prep_cs2.discard(self.d, "a/m1.vmdl_c")
        self.assertTrue(prep_cs2.present(self.d, "a/m1.vmdl_c"))
        self.put("a/m2_color_psd_0.png", garbled_png())
        prep_cs2.discard(self.d, "a/m2.vmdl_c")
        self.assertFalse(os.path.exists(os.path.join(self.d, "a", "m2.glb")))
        self.assertFalse(os.path.exists(os.path.join(self.d, "a", "m2_color_psd_0.png")))

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
