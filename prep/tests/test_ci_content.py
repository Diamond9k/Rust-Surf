"""prep/tests/ci_content.py: the synthetic viewmodel --ci plays on is valid glTF laid out the way VRF exports and
Viewmodel.gd reads (container per skeleton, the bones it looks up, one clip per glb) and holds nothing of CS2's."""
import json, os, struct, sys, tempfile, shutil, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import ci_content


def read_glb(path):
    with open(path, "rb") as f:
        b = f.read()
    magic, ver, total = struct.unpack("<4sII", b[:12])
    jl, jt = struct.unpack("<II", b[12:20])
    doc = json.loads(b[20:20 + jl])
    bl, bt = struct.unpack("<II", b[20 + jl:28 + jl])
    return magic, ver, total, len(b), jt, bt, doc, b[28 + jl:28 + jl + bl]


class CiContent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp()
        cls.paths = ci_content.build(REPO, cls.d)
        cls.docs = {os.path.relpath(p, cls.d).replace(os.sep, "/"): read_glb(p) for p in cls.paths}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.d, ignore_errors=True)

    def doc(self, cid):
        return self.docs[ci_content.outputs(REPO)[cid]][6]

    def test_written_at_content_paths(self):
        with open(os.path.join(REPO, "sheets", "content.json"), encoding="utf-8") as f:
            rows = {r["id"]: r for r in json.load(f)["rows"]}
        want = sorted(rows[i]["out"].split(" ")[0] for i in ("model_arms", "model_knife_ct", "clip_knife_draw", "clip_knife_idle", "clip_knife_inspect"))
        self.assertEqual(sorted(self.docs), want)

    def test_glb_containers_and_accessors_are_sound(self):
        for name, (magic, ver, total, size, jt, bt, doc, binc) in self.docs.items():
            self.assertEqual((magic, ver, total, jt, bt), (b"glTF", 2, size, 0x4E4F534A, 0x004E4942), name)
            self.assertEqual(doc["buffers"][0]["byteLength"], len(binc), name)
            width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
            comp = {5126: 4, 5125: 4, 5123: 2}
            for a in doc["accessors"]:
                v = doc["bufferViews"][a["bufferView"]]
                self.assertEqual(v["byteLength"], a["count"] * width[a["type"]] * comp[a["componentType"]], name)
                self.assertLessEqual(v["byteOffset"] + v["byteLength"], len(binc), name)
                self.assertEqual(v["byteOffset"] % 4, 0, name)
            for m in doc["meshes"]:
                for p in m["primitives"]:
                    n = doc["accessors"][p["attributes"]["POSITION"]]["count"]
                    idx = doc["accessors"][p["indices"]]
                    off = doc["bufferViews"][idx["bufferView"]]["byteOffset"]
                    self.assertLess(max(struct.unpack_from("<%dI" % idx["count"], binc, off)), n, name)
            for s in doc["skins"]:
                self.assertEqual(doc["accessors"][s["inverseBindMatrices"]]["count"], len(s["joints"]), name)
            self.assertNotIn("images", doc, name)  # boxes only: no texture, nothing of CS2's
            self.assertIn("synthetic", doc["asset"]["generator"])

    def names(self, doc):
        return [n["name"] for n in doc["nodes"]]

    def globals_(self, doc):
        par = {c: i for i, n in enumerate(doc["nodes"]) for c in n.get("children", [])}
        def g(i):
            t = doc["nodes"][i].get("translation", [0, 0, 0])
            if i not in par:
                return t
            p = g(par[i])
            return [p[k] + t[k] for k in range(3)]
        return {n["name"]: g(i) for i, n in enumerate(doc["nodes"])}

    def test_arms_have_the_bones_viewmodel_reads_and_the_palm_on_wpn(self):
        doc = self.doc("model_arms")
        for b in ("root_motion", "wpn", "hand_R", "attachHand_R", "pelvis"):
            self.assertIn(b, self.names(doc))
        g = self.globals_(doc)
        self.assertEqual([round(x, 6) for x in g["attachHand_R"]], [round(x, 6) for x in g["wpn"]])
        root = doc["scenes"][0]["nodes"]
        self.assertEqual(len(root), 2)  # the container with the joints, and the skinned mesh beside it (as VRF writes)
        self.assertIn("skin", doc["nodes"][root[1]])
        self.assertEqual(self.names(doc).count("pelvis"), 1)

    def test_knife_root_bone(self):
        doc = self.doc("model_knife_ct")
        self.assertEqual(doc["nodes"][doc["nodes"][doc["scenes"][0]["nodes"][0]]["children"][0]]["name"], "weapon")

    def test_clips_hold_both_skeletons_and_one_named_clip(self):
        seen = set()
        for cid, (name, sec, _) in ci_content.CLIPS.items():
            doc = self.doc(cid)
            roots = [doc["nodes"][i]["name"] for i in doc["scenes"][0]["nodes"]]
            self.assertIn(ci_content.ARMS_SKEL, roots)
            self.assertIn(ci_content.KNIFE_SKEL, roots)
            self.assertNotIn("pelvis", self.names(doc))  # the clip skeleton is smaller than the arms', as in CS2's files
            self.assertEqual([a["name"] for a in doc["animations"]], [name])
            t = doc["accessors"][doc["animations"][0]["samplers"][0]["input"]]
            self.assertAlmostEqual(t["max"][0], sec, places=5)
            self.assertNotIn(name, ("idle", "draw", "inspect"))  # reequip_idle checks the clip keeps its own name
            seen.add(name)
        self.assertEqual(len(seen), 3)


if __name__ == "__main__":
    unittest.main()
