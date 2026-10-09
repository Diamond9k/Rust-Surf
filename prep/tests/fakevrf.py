"""A stand-in for Source2Viewer-CLI: writes files shaped like real VRF 20 output (glb with its length
field, RIFF/WAVE, mp3 frame sync) and can misbehave the ways a real install might."""
import os, struct

MP3 = ("amb_wind_01.vsnd_c",)  # sounds the real VPK stores as mp3 (the one content.json row says so)


def glb_bytes(n=64):
    body = b"\0" * n
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
    items_game: text written for scripts/items/items_game.txt."""

    def __init__(self, items_game="", bad=(), flaky=(), poison=(), truncate=()):
        self.items_game, self.bad, self.flaky, self.poison, self.truncate = items_game, set(bad), set(flaky), set(poison), set(truncate)
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
        elif f.endswith((".vmdl_c", ".vnmclip_c")):
            p, data = os.path.splitext(f)[0] + ".glb", glb_bytes()
        else:
            p, data = f, self.items_game.encode("utf-8")
        if cut:
            data = data[:20]
        p = os.path.join(outdir, p)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
