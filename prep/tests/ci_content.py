"""A synthetic CS2 viewmodel for tools/package.py --ci: arms, the default knife and its draw / idle / inspect clips
as glb files at their content.json paths, so the --wtest checks that need a rig (CONTENT_CHECKS, knife_in_palm)
run on every push instead of only in the release gate on a machine with the games installed.
build(root, data) writes them under data and returns the paths it wrote.
Nothing here comes from CS2: the geometry is boxes, the poses and clip lengths are test values. Only the layout
follows what VRF exports (checked on a 2026-10-08 export, see content.json): a container node per skeleton named
after the .vnmskel / .vmdl_c, the joints under it, the skinned mesh a sibling at the scene root, and clip glbs
holding the viewmodel skeleton and the knife skeleton with one animation. The bone names are the ones
Viewmodel.gd looks up (wpn, attachHand_R, weapon); pelvis is a body bone the arms skin binds but never draws."""
import json, os, struct

ARMS_SKEL = "animation/skeletons/characters/viewmodel.vnmskel"
KNIFE_SKEL = "animation/skeletons/weapons/knife_default_ct.vnmskel"
# (name, parent, translation in m). Model space: +Z forward (the rig is turned 180 degrees), -X the right hand.
# The right arm chain ends exactly on wpn, so attachHand_R (the palm point) and the knife root coincide.
ARM_BONES = [("root_motion", None, (0.0, 0.0, 0.0)),
             ("wpn", "root_motion", (-0.12, -0.12, 0.45)),
             ("armUpperShoulder_R", "root_motion", (-0.15, -0.25, -0.05)),
             ("arm_lower_R", "armUpperShoulder_R", (0.0, 0.06, 0.25)),
             ("hand_R", "arm_lower_R", (0.02, 0.05, 0.20)),
             ("attachHand_R", "hand_R", (0.01, 0.02, 0.05)),
             ("armUpperShoulder_L", "root_motion", (0.15, -0.25, -0.05)),
             ("arm_lower_L", "armUpperShoulder_L", (0.0, 0.06, 0.25))]
BODY_BONES = [("pelvis", "root_motion", (0.0, -1.0, -0.1))]
KNIFE_MODEL_BONES = [("weapon", None, (0.0, 0.0, 0.0)), ("weapon_offset", "weapon", (0.0, 0.0, 0.0)), ("ag1_hand_r", "weapon_offset", (0.0, 0.0, 0.0))]
KNIFE_CLIP_BONES = [("weapon", None, (0.0, 0.0, 0.0)), ("weapon_offset", "weapon", (0.0, 0.0, 0.0)), ("econ", "weapon_offset", (0.0, 0.0, 0.0))]
# clip id -> (animation name, seconds, root_motion pitch at the middle key in degrees)
CLIPS = {"clip_knife_draw": ("ci_draw_knife", 0.6, 12.0), "clip_knife_idle": ("ci_idle_knife", 2.0, 1.5),
         "clip_knife_inspect": ("ci_lookat01_knife", 1.5, -8.0)}
MODELS = ("model_arms", "model_knife_ct")


def _pad(b, ch=b"\0"):
    return bytes(b) + ch * ((4 - len(b) % 4) % 4)


class Glb:
    """Just enough glTF 2.0 for skinned boxes and a node animation."""
    def __init__(self):
        self.buf, self.views, self.acc, self.nodes, self.meshes, self.skins, self.anims, self.scene = bytearray(), [], [], [], [], [], [], []

    def data(self, fmt, vals, ctype, atype, count, target=None, bounds=False, flat=None):
        raw = struct.pack("<" + fmt * len(vals), *vals)
        off = len(self.buf)
        self.buf.extend(_pad(raw))
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(raw)}
        if target:
            v["target"] = target
        self.views.append(v)
        a = {"bufferView": len(self.views) - 1, "componentType": ctype, "count": count, "type": atype}
        if bounds:
            w = len(vals) // count
            a["min"] = [min(vals[i::w]) for i in range(w)]
            a["max"] = [max(vals[i::w]) for i in range(w)]
        self.acc.append(a)
        return len(self.acc) - 1

    def skeleton(self, container, bones):
        """A container node at the scene root with the joints under it; returns ({bone: node}, {bone: global pos})."""
        cid = len(self.nodes)
        self.nodes.append({"name": container, "children": []})
        self.scene.append(cid)
        idx, glob = {}, {}
        for name, parent, t in bones:
            idx[name] = len(self.nodes)
            self.nodes.append({"name": name, "translation": list(t), "rotation": [0.0, 0.0, 0.0, 1.0]})
            p = glob[parent] if parent else (0.0, 0.0, 0.0)
            glob[name] = tuple(p[i] + t[i] for i in range(3))
            if parent:
                self.nodes[idx[parent]].setdefault("children", []).append(idx[name])
            else:
                self.nodes[cid]["children"].append(idx[name])
        return idx, glob

    def skinned(self, name, bones, idx, glob, boxes):
        """boxes: [(bone, (x0, y0, z0), (x1, y1, z1))] offsets from the bone's rest position, each bound wholly to it."""
        names = [b[0] for b in bones]
        pos, jnt, wgt, ind = [], [], [], []
        for bone, lo, hi in boxes:
            o, j, base = glob[bone], names.index(bone), len(pos) // 3
            for k in range(8):
                c = (hi if k & 1 else lo, hi if k & 2 else lo, hi if k & 4 else lo)
                pos += [o[0] + c[0][0], o[1] + c[1][1], o[2] + c[2][2]]
                jnt += [j, 0, 0, 0]
                wgt += [1.0, 0.0, 0.0, 0.0]
            for f in ((0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)):
                ind += [base + f[0], base + f[1], base + f[2], base + f[0], base + f[2], base + f[3]]
        n = len(pos) // 3
        attrs = {"POSITION": self.data("f", pos, 5126, "VEC3", n, 34962, True),
                 "JOINTS_0": self.data("H", jnt, 5123, "VEC4", n, 34962),
                 "WEIGHTS_0": self.data("f", wgt, 5126, "VEC4", n, 34962)}
        self.meshes.append({"name": name, "primitives": [{"attributes": attrs, "indices": self.data("I", ind, 5125, "SCALAR", len(ind), 34963), "mode": 4}]})
        ibm = []
        for b in names:  # bones carry no rotation at rest: the inverse bind is a translation by minus the global position
            g = glob[b]
            ibm += [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, -g[0], -g[1], -g[2], 1.0]
        self.skins.append({"joints": [idx[b] for b in names], "inverseBindMatrices": self.data("f", ibm, 5126, "MAT4", len(names))})
        self.scene.append(len(self.nodes))
        self.nodes.append({"name": name, "mesh": len(self.meshes) - 1, "skin": len(self.skins) - 1})

    def animate(self, name, seconds, node, pitch_deg):
        """One clip: node turns about X to pitch_deg at the middle key and back; translation held at rest."""
        import math
        h = math.radians(pitch_deg) * 0.5
        times = [0.0, seconds * 0.5, seconds]
        tin = self.data("f", times, 5126, "SCALAR", 3, bounds=True)
        rot = self.data("f", [0.0, 0.0, 0.0, 1.0, math.sin(h), 0.0, 0.0, math.cos(h), 0.0, 0.0, 0.0, 1.0], 5126, "VEC4", 3)
        tr = self.data("f", list(self.nodes[node]["translation"]) * 3, 5126, "VEC3", 3)
        self.anims.append({"name": name, "samplers": [{"input": tin, "output": rot, "interpolation": "LINEAR"}, {"input": tin, "output": tr, "interpolation": "LINEAR"}],
                           "channels": [{"sampler": 0, "target": {"node": node, "path": "rotation"}}, {"sampler": 1, "target": {"node": node, "path": "translation"}}]})

    def write(self, path):
        doc = {"asset": {"version": "2.0", "generator": "RustSurf prep/tests/ci_content.py (synthetic, not CS2 content)"},
               "scene": 0, "scenes": [{"nodes": self.scene}], "nodes": self.nodes, "meshes": self.meshes, "skins": self.skins,
               "accessors": self.acc, "bufferViews": self.views, "buffers": [{"byteLength": len(self.buf)}]}
        if self.anims:
            doc["animations"] = self.anims
        jb = _pad(json.dumps(doc, separators=(",", ":")).encode(), b" ")
        bb = _pad(self.buf)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(jb) + 8 + len(bb)))
            f.write(struct.pack("<II", len(jb), 0x4E4F534A) + jb)
            f.write(struct.pack("<II", len(bb), 0x004E4942) + bb)


def arms():
    g = Glb()
    bones = ARM_BONES + BODY_BONES
    idx, glob = g.skeleton("weapons\\models\\shared\\arms\\weapon_arms.vmdl_c", bones)
    s = 0.035
    boxes = [("armUpperShoulder_R", (-s, -s, 0.0), (s, s, 0.25)), ("arm_lower_R", (-s, -s, 0.0), (s, s, 0.2)), ("hand_R", (-0.03, -0.02, 0.0), (0.03, 0.02, 0.06)),
             ("armUpperShoulder_L", (-s, -s, 0.0), (s, s, 0.25)), ("arm_lower_L", (-s, -s, 0.0), (s, s, 0.2)), ("pelvis", (-0.1, -0.1, -0.1), (0.1, 0.1, 0.1))]
    g.skinned("weapons\\models\\shared\\arms\\weapon_arms.vmdl_c.unnamed_1", bones, idx, glob, boxes)
    return g


def knife():
    g = Glb()
    idx, glob = g.skeleton("weapons\\models\\knife\\knife_default_ct\\weapon_knife_default_ct.vmdl_c", KNIFE_MODEL_BONES)
    g.skinned("weapons\\models\\knife\\knife_default_ct\\weapon_knife_default_ct.vmdl_c.body_legacy", KNIFE_MODEL_BONES, idx, glob,
              [("weapon_offset", (-0.012, -0.015, -0.05), (0.012, 0.015, 0.06)), ("weapon_offset", (-0.003, -0.012, 0.06), (0.003, 0.012, 0.2))])
    return g


def clip(name, seconds, pitch):
    g = Glb()
    tiny = [("root_motion", (0.0, 0.0, 0.0), (0.001, 0.001, 0.001))]
    idx, glob = g.skeleton(ARMS_SKEL, ARM_BONES)
    g.skinned(ARMS_SKEL + ".empty_mesh_reference", ARM_BONES, idx, glob, tiny)
    kidx, kglob = g.skeleton(KNIFE_SKEL, KNIFE_CLIP_BONES)
    g.skinned(KNIFE_SKEL + ".empty_mesh_reference", KNIFE_CLIP_BONES, kidx, kglob, [("weapon", (0.0, 0.0, 0.0), (0.001, 0.001, 0.001))])
    g.animate(name, seconds, idx["root_motion"], pitch)
    return g


def outputs(root):
    """{content id: output path relative to the data folder} for the rows this file stands in for."""
    with open(os.path.join(root, "sheets", "content.json"), encoding="utf-8") as f:
        rows = {r["id"]: r for r in json.load(f)["rows"]}
    return {i: rows[i]["out"].split(" ")[0] for i in MODELS + tuple(CLIPS)}


def build(root, data):
    """Writes the five glbs under data at their content.json paths; returns the paths written."""
    out = outputs(root)
    made = {"model_arms": arms(), "model_knife_ct": knife()}
    for i, (name, sec, pitch) in CLIPS.items():
        made[i] = clip(name, sec, pitch)
    paths = []
    for i, g in made.items():
        p = os.path.join(data, out[i])
        g.write(p)
        paths.append(p)
    return paths


if __name__ == "__main__":
    import sys
    print("\n".join(build(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), sys.argv[1])))
