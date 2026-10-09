"""RustSurf prep: run once by Melty before the first start.
Reads every content.json row from the Rust and CS2 installs of the player into --out.
usage: prep.py --rust <Rust dir> --cs2 <CS2 dir> --out <data dir> --tools <dir> --version <v>"""
import os, sys, json, argparse, subprocess, time, traceback
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lazybundle
lazybundle.install()
import UnityPy
import prep_rust
from prep_rust import load_env, material_files, decode_fsb, LOG
import prep_scene
import normals

RUST_BUNDLES = ["content.bundle", "assetscenes.bundle", "audio.bundle",
                "textures.0.bundle", "textures.1.bundle", "textures.2.bundle", "textures.3.bundle", "textures.4.bundle"]


def rows(kind=None, game=None):
    sheet = json.load(open(os.path.join(HERE, "content.json"), encoding="utf-8"))
    return [r for r in sheet["rows"] if (kind is None or r["kind"] == kind) and (game is None or r["game"] == game)]


def rust_step(a):
    for b in RUST_BUNDLES:
        p = os.path.join(a.rust, "Bundles", "shared", b)
        if not os.path.exists(p):
            raise RuntimeError("Rust bundle missing: " + p)
    env = load_env(UnityPy, a.rust, RUST_BUNDLES, lambda n: "monument.1" in n or not n.startswith("BuildPlayer-"))
    out = a.out
    tex_dir = os.path.join(out, "rust", "tex")
    os.makedirs(tex_dir, exist_ok=True)
    os.makedirs(os.path.join(out, "rust", "audio"), exist_ok=True)
    # course textures (content.json texture rows): the .mat named in source
    by_path = {}
    for p, o in env.container.items():
        by_path[p] = o
    for r in rows("texture", "rust"):
        mat_path = r["source"].split(" :: ")[0]
        o = by_path.get(mat_path)
        if o is None:
            LOG("missing material " + mat_path); continue
        m = o.read()
        files = material_files(m, tex_dir, "", 2048)
        for slot, suffix in (("albedo", "MainTex"), ("normal", "BumpMap")):
            want = os.path.join(out, r["out"].replace("{MainTex,BumpMap}", suffix))
            if slot in files and not os.path.exists(want):
                os.replace(os.path.join(tex_dir, files[slot]), want)
        LOG("texture row %s ok" % r["id"])
    # audio rows
    for r in rows("audio", "rust"):
        src = r["source"].split(" (")[0]
        o = by_path.get(src)
        if o is None and "*" in src:
            import fnmatch
            hits = sorted(k for k in by_path if fnmatch.fnmatch(k, src))
            o = by_path.get(hits[0]) if hits else None
            LOG("audio pattern %s -> %s" % (src, hits[:3]))
        if o is None:
            LOG("missing audio " + src); continue
        ok = decode_fsb(o.read(), a.vgm, os.path.join(out, r["out"]))
        LOG("audio row %s %s" % (r["id"], "ok" if ok else "FAILED"))
    # the Launch Site itself
    n = prep_scene.extract_scene(env, out, 1024)
    LOG("scene row scene_launch_site ok (%d placements)" % n)
    # Unity DXTnm normal maps -> RGB tangent normals (idempotent, so it also fixes 0.1.0 data folders)
    normals.fix_dir(tex_dir, LOG)


def cs2_step(a):
    vpk = os.path.join(a.cs2, "game", "csgo", "pak01_dir.vpk")
    gi = os.path.join(a.cs2, "game", "csgo", "gameinfo.gi")
    if not os.path.exists(vpk):
        raise RuntimeError("CS2 pak01_dir.vpk missing: " + vpk)
    outdir = os.path.join(a.out, "cs2")
    os.makedirs(outdir, exist_ok=True)
    plain, gltf = [], []
    for r in rows(game="cs2"):
        if r["kind"] == "config":
            continue
        src = r["source"].split(" ")[0]
        if ".." in src:  # concrete_ct_01..04 -> four files
            base, rng = src.split("_0")[0], src.split("_0")[1]
            lo, hi = rng.split(".vsnd_c")[0].split("..")
            for i in range(int(lo), int(hi) + 1):
                plain.append("%s_%02d.vsnd_c" % (base, i))
        elif r["kind"] in ("model", "animation"):
            gltf.append(src)
        else:
            plain.append(src)
    def run(args):
        cmd = [a.vrf, "-i", vpk, "-o", outdir, "-d"] + args
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            LOG("VRF failed: " + (r.stderr or r.stdout)[-400:])
        return r.returncode == 0
    LOG("cs2 sounds: %d" % len(plain))
    run(["-f", ",".join(plain)])
    LOG("cs2 models+clips: %d" % len(gltf))
    run(["-f", ",".join(gltf), "--gltf_export_format", "glb", "--gltf_export_materials", "--gltf_export_animations", "--game", gi])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", required=True); ap.add_argument("--cs2", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--tools", default=HERE)
    ap.add_argument("--version", default="dev")
    a = ap.parse_args()
    a.vrf = os.path.join(a.tools, "vrf", "Source2Viewer-CLI.exe")
    a.vgm = os.path.join(a.tools, "vgm", "vgmstream-cli.exe")
    os.makedirs(a.out, exist_ok=True)
    log = open(os.path.join(a.out, "prep.log"), "a", encoding="utf-8")
    def both(s):
        print(s, flush=True); log.write(s + "\n"); log.flush()
    prep_rust.LOG = both; prep_scene.LOG = both
    global LOG; LOG = both
    t = time.time()
    try:
        both("prep %s start; rust=%s cs2=%s" % (a.version, a.rust, a.cs2))
        cs2_step(a)
        rust_step(a)
        missing = [r["id"] for r in rows() if r["kind"] != "config" and "{" not in r["out"] and "*" not in r["out"] and not os.path.exists(os.path.join(a.out, r["out"].split(" ")[0]))]
        both("done in %.0fs; missing rows: %s" % (time.time() - t, missing or "none"))
        open(os.path.join(a.out, "done-%s.txt" % a.version), "w").write("ok %s missing=%s\n" % (a.version, missing))
    except Exception:
        both(traceback.format_exc())
        sys.exit(1)


if __name__ == "__main__":
    main()
