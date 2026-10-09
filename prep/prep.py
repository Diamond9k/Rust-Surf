"""RustSurf prep: run once by Melty before the first start.
Reads every content.json row from the Rust and CS2 installs of the player into --out.
usage: prep.py --rust <Rust dir> --cs2 <CS2 dir> --out <data dir> --tools <dir> --version <v>
Writes done-<version>.txt only when every content.json row and every weapons.json weapon is in place, each
file checked whole, and every weapon has its damage and fire rate from the player's CS2 files; otherwise
exits 1 with the reasons on screen, in prep.log and in prep_status.json (the game shows them)."""
import os, sys, json, glob, argparse, time, traceback
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import prep_cs2
LOG = print

RUST_BUNDLES = ["content.bundle", "assetscenes.bundle", "audio.bundle",
                "textures.0.bundle", "textures.1.bundle", "textures.2.bundle", "textures.3.bundle", "textures.4.bundle"]


def rust_step(a):
    for b in RUST_BUNDLES:
        p = os.path.join(a.rust, "Bundles", "shared", b)
        if not os.path.exists(p):
            raise prep_cs2.PrepError("Rust not found: no Bundles/shared/%s in %s (install or verify Rust in Steam)" % (b, a.rust))
    if not os.path.isfile(a.vgm):
        raise prep_cs2.PrepError("vgmstream-cli.exe is missing from %s (reinstall Rust Surf)" % os.path.dirname(a.vgm))
    import lazybundle  # UnityPy only here, so the CS2 side and prep/tests run without it
    lazybundle.install()
    import UnityPy
    import prep_scene, normals
    import prep_rust
    from prep_rust import load_env, material_files, decode_fsb
    prep_rust.LOG = prep_scene.LOG = LOG
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
            if slot in files and not prep_cs2.file_ok(want):
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


def rows(kind=None, game=None):
    return [r for r in prep_cs2.sheet("content")["rows"] if (kind is None or r["kind"] == kind) and (game is None or r["game"] == game)]


def content_missing(out):
    """content.json rows whose output is not in the data folder (a pattern needs one match, a {a,b} list all)."""
    miss = []
    for r in rows():
        if r["kind"] == "config":
            continue
        pats = prep_cs2.expand(r["out"].split(" ")[0])
        if not all(glob.glob(os.path.join(out, p)) if "*" in p else prep_cs2.file_ok(os.path.join(out, p)) for p in pats):
            miss.append(r["id"])
    return miss


def scene_missing(out):
    """Launch Site pieces the placements file names but that are not whole: each mesh glb (with a mesh and
    every texture it names) and each material texture. Empty when there is no placements file yet."""
    p = os.path.join(out, "rust", "launch_site_placements.json")
    if not prep_cs2.file_ok(p):
        return []
    with open(p, encoding="utf-8") as f:
        sc = json.load(f)
    miss = sorted({m for m in (x["mesh"] for x in sc.get("placements", []))
                   if not prep_cs2.glb_ok(os.path.join(out, "rust", "mesh", m + ".glb"), "meshes")})
    for slots in sc.get("materials", {}).values():
        miss += sorted(fn for fn in slots.values() if not prep_cs2.png_ok(os.path.join(out, "rust", "tex", fn)))
    return miss


def finish(a, problems, warnings, log):
    """done-<version>.txt only when nothing essential is missing; prep_status.json either way, which the
    game shows on its error panel (Main._report), so a broken install never looks like a working one."""
    player = ["Prep: " + p for p in problems] + ["Prep warning: " + w for w in warnings]
    if problems:
        player.append("Prep: setup is not done, so Melty runs it again on the next start; details in data/prep.log")
    status = {"version": a.version, "ok": not problems, "problems": problems, "warnings": warnings, "player": player}
    done = os.path.join(a.out, "done-%s.txt" % a.version)
    if problems and os.path.exists(done):
        os.remove(done)  # first, so no crash below can leave a stale done file next to a failed run
    prep_cs2.write_json(os.path.join(a.out, "prep_status.json"), status)
    if problems:
        log("")
        log("RUST SURF SETUP DID NOT FINISH (%d problem(s)); Melty runs it again on the next start:" % len(problems))
        for p in problems:
            log("  - " + p)
        log("Details: " + os.path.join(a.out, "prep.log"))
        return 1
    with open(done + ".tmp", "w", encoding="utf-8") as f:
        f.write("ok %s warnings=%s\n" % (a.version, warnings))
    os.replace(done + ".tmp", done)
    log("RUST SURF SETUP OK (%s)%s" % (a.version, "; warnings: " + "; ".join(warnings) if warnings else ""))
    return 0


def main(argv=None, steps=None, runner=None):
    """Runs both games, then finish(); returns the exit code. steps/runner are for prep/tests."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", required=True); ap.add_argument("--cs2", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--tools", default=HERE)
    ap.add_argument("--version", default="dev")
    a = ap.parse_args(argv)
    a.vrf = os.path.join(a.tools, "vrf", "Source2Viewer-CLI.exe")
    a.vgm = os.path.join(a.tools, "vgm", "vgmstream-cli.exe")
    a.runner = runner
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "prep.log"), "a", encoding="utf-8") as log:
        def both(s):
            print(s, flush=True); log.write(s + "\n"); log.flush()
        global LOG
        LOG = prep_cs2.LOG = both
        t = time.time()
        problems, warnings = [], []
        try:
            both("prep %s start; rust=%s cs2=%s" % (a.version, a.rust, a.cs2))
            for step in steps or (cs2_step, rust_step):  # one game failing must not skip the other
                try:
                    p = step(a)
                    if p:
                        problems += p[0]; warnings += p[1]
                except prep_cs2.PrepError as e:
                    both("%s: %s" % (step.__name__, e))
                    problems.append(str(e))
                except Exception as e:
                    both(traceback.format_exc())
                    problems.append("%s crashed (%s: %s)" % (step.__name__, type(e).__name__, e))
            missing = content_missing(a.out)
            if missing:
                both("content rows missing: " + ", ".join(missing))
                problems.append("content not extracted: " + prep_cs2.short(missing))
            sm = scene_missing(a.out)
            if sm:
                both("Launch Site pieces not whole: " + ", ".join(sm))
                problems.append("%d Launch Site mesh(es)/texture(s) did not extract whole: %s (verify Rust's files in Steam)" % (len(sm), prep_cs2.short(sm)))
            both("done in %.0fs" % (time.time() - t))
        except Exception as e:
            both(traceback.format_exc())
            problems.append("prep crashed (%s: %s)" % (type(e).__name__, e))
        return finish(a, problems, warnings, both)


def cs2_step(a):
    return prep_cs2.cs2_step(a)


if __name__ == "__main__":
    sys.exit(main())
