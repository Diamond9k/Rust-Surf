"""A stand-in for Source2Viewer-CLI: writes files shaped like real VRF 20 output (glb with its length
field, JSON and BIN chunks, meshes for a model, animations for a clip, PNG textures beside a model;
RIFF/WAVE, mp3 frame sync) and can misbehave the ways a real install might."""
import os, json, zlib, struct

MP3 = ("amb_wind_01.vsnd_c",)  # sounds the real VPK stores as mp3 (the one content.json row says so)


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png_bytes(w=1, h=1, ctype=2, raw=None, interlace=0, split=0):
    """A PNG with good chunk CRCs. raw: the pixel stream (default: filter 0 rows of zeros for w x h at 8 bits);
    split: the IDAT stream cut into chunks of this many bytes, as encoders do for big images."""
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    if raw is None:
        raw = b"".join(b"\0" + b"\0" * (w * ch) for _ in range(h))
    z = zlib.compress(raw)
    parts = [z[i:i + split] for i in range(0, len(z), split)] if split else [z]
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, interlace))
            + b"".join(png_chunk(b"IDAT", p) for p in parts) + png_chunk(b"IEND", b""))


def garbled_png():
    """Whole on the outside (signature, CRCs, IEND) but its pixel stream is short and a row filter is invalid:
    what a texture mixed up in a batch export can look like."""
    return png_bytes(4, 4, raw=b"\x09" + b"\x7f" * 12 + b"\0" * 13)


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
    badtex: models whose PNG texture is written cut short every time; batchtex: models whose texture comes out
    garbled (good CRCs, bad pixels) when exported in a call of several files, whole when alone; noclobber: never
    overwrite a file that exists (a damaged output stays unless prep deletes it)."""

    def __init__(self, items_game="", bad=(), flaky=(), poison=(), truncate=(), vdata=None, badtex=(), batchtex=(), noclobber=False):
        self.items_game, self.bad, self.flaky, self.poison, self.truncate = items_game, set(bad), set(flaky), set(poison), set(truncate)
        self.vdata, self.badtex, self.batchtex, self.noclobber = vdata, set(badtex), set(batchtex), noclobber
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
                self.write(outdir, f, first and f in self.truncate, len(files) > 1)
            return ok
        return run

    def write(self, outdir, f, cut, batch=False):
        if f.endswith(".vsnd_c"):
            p, data = f[:-7] + (".mp3" if f.endswith(MP3) else ".wav"), (b"\xff\xfb\x90\xc4" + b"\0" * 60 if f.endswith(MP3) else wav_bytes())
        elif f.endswith(".vmdl_c"):
            p = os.path.splitext(f)[0] + ".glb"
            tex = os.path.basename(p)[:-4] + "_color_psd_0.png"
            png = png_bytes()[:30] if f in self.badtex else garbled_png() if batch and f in self.batchtex else png_bytes()
            self.put(os.path.join(outdir, os.path.dirname(p), tex), png)
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
        if self.noclobber and os.path.exists(p):
            return
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
