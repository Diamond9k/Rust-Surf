"""A stand-in for Source2Viewer-CLI: writes files shaped like real VRF 20 output (glb with its length
field, JSON and BIN chunks, meshes for a model, animations for a clip, PNG textures beside a model;
RIFF/WAVE, mp3 frame sync) and can misbehave the ways a real install might."""
import os, json, zlib, struct

MP3 = ("amb_wind_01.vsnd_c",)  # sounds the real VPK stores as mp3 (the one content.json row says so)


def png_bytes():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b""))


def glb_bytes(kind="mesh", images=(), n=64):
    """kind: mesh (a model: meshes), clip (animations, as VRF writes vnmclip exports), none (neither)."""
    doc = {"asset": {"version": "2.0", "generator": "fakevrf"}, "buffers": [{"byteLength": n}]}
    if kind == "mesh":
        doc["meshes"] = [{"primitives": []}]
    elif kind == "clip":
        doc["animations"] = [{"channels": [], "samplers": []}]
    if images:
        doc["images"] = [{"uri": u} for u in images]
    js = json.dumps(doc).encode()
    js += b" " * (-len(js) % 4)
    body = struct.pack("<I", len(js)) + b"JSON" + js + struct.pack("<I", n) + b"BIN\0" + b"\0" * n
    return b"glTF" + struct.pack("<II", 2, 12 + len(body)) + body


def wav_bytes(n=64):
    data = b"\0" * n
    fmt = b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 44100, 88200, 2, 16)
    body = b"WAVE" + fmt + b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


class FakeVRF:
    """runner(vpk, outdir, timeout) -> run(files, extra), as prep_cs2.cs2_step takes it.
    bad: paths that never export; flaky: paths that fail their first call; poison: a call of several files holding any
    of these exports nothing (all-or-nothing batches); truncate: glbs written cut short the first time;
    items_game: text written for scripts/items/items_game.txt; vdata: text for a .vdata_c (None: not in the VPK);
    badtex: models whose PNG texture is written cut short every time."""

    def __init__(self, items_game="", bad=(), flaky=(), poison=(), truncate=(), vdata=None, badtex=()):
        self.items_game, self.bad, self.flaky, self.poison, self.truncate = items_game, set(bad), set(flaky), set(poison), set(truncate)
        self.vdata, self.badtex = vdata, set(badtex)
        self.calls, self.seen = [], set()

    def __call__(self, vpk, outdir, timeout):
        def run(files, extra):
            self.calls.append((list(files), list(extra)))
            if len(files) > 1 and self.poison & set(files):
                return False
            ok = True
            for f in files:
                first = f not in self.seen
                self.seen.add(f)
                if f in self.bad or (first and f in self.flaky):
                    ok = False
                    continue
                self.write(outdir, f, first and f in self.truncate)
            return ok
        return run

    def write(self, outdir, f, cut):
        if f.endswith(".vsnd_c"):
            p, data = f[:-7] + (".mp3" if f.endswith(MP3) else ".wav"), (b"\xff\xfb\x90\xc4" + b"\0" * 60 if f.endswith(MP3) else wav_bytes())
        elif f.endswith(".vmdl_c"):
            p = os.path.splitext(f)[0] + ".glb"
            tex = os.path.basename(p)[:-4] + "_color_psd_0.png"
            self.put(os.path.join(outdir, os.path.dirname(p), tex), png_bytes()[:30] if f in self.badtex else png_bytes())
            data = glb_bytes("mesh", [tex])
        elif f.endswith(".vnmclip_c"):
            p, data = os.path.splitext(f)[0] + ".glb", glb_bytes("clip")
        elif f.endswith(".vdata_c"):
            if self.vdata is None:
                return
            p, data = f[:-2], self.vdata.encode("utf-8")
        else:
            p, data = f, self.items_game.encode("utf-8")
        if cut:
            data = data[:20]
        self.put(os.path.join(outdir, p), data)

    def put(self, p, data):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
