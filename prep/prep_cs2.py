"""CS2 side of prep: the content.json cs2 rows (arms, knife, clips, sounds) and every weapons.json row,
exported from the player's pak01_dir.vpk by Source2Viewer-CLI (VRF). Every output file is checked
(glb/wav headers against their own length fields, mp3 frame sync, text non-empty); a file that fails is
exported again on its own. Files already exported and whole are skipped, so a rerun only redoes what
is missing. No UnityPy here, so prep/tests can run all of it against a fake VRF.
cs2_step(a) -> list of problems (player-facing sentences); empty means every CS2 file is in place."""
import os, re, json, struct, subprocess, glob
import items_game

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = print
GLTF = ["--gltf_export_format", "glb", "--gltf_export_materials", "--gltf_export_animations"]
ITEMS_GAME = "scripts/items/items_game.txt"


class PrepError(Exception):
    """A problem the player has to fix (missing install, missing tool); the message says what."""


def sheet(name, here=HERE):
    with open(os.path.join(here, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def settings(here=HERE):
    return {r["id"]: r["value"] for r in sheet("prep", here)["rows"]}


def expand(pattern):
    """Brace expansion as the sheets write outputs: a_{x,y}.png -> a_x.png, a_y.png; b_0{1..4} -> b_01..b_04."""
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    body = m.group(1)
    r = re.fullmatch(r"(\d+)\.\.(\d+)", body)
    alts = [str(i) for i in range(int(r.group(1)), int(r.group(2)) + 1)] if r else body.split(",")
    out = []
    for alt in alts:
        out += expand(pattern[:m.start()] + alt + pattern[m.end():])
    return out


def outputs(src):
    """What VRF writes for one VPK path (any one of them counts): sounds become .wav or .mp3 by their
    encoding, models and clips .glb (with --gltf_export_format glb), plain files keep their name."""
    if src.endswith(".vsnd_c"):
        return [src[:-7] + ".wav", src[:-7] + ".mp3"]
    if src.endswith((".vmdl_c", ".vnmclip_c")):
        return [os.path.splitext(src)[0] + ".glb"]
    return [src]


def file_ok(path):
    """A whole file, not a crash leftover: checked against the headers real VRF 20 output carries."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(12)
    except OSError:
        return False
    if size == 0:
        return False
    ext = os.path.splitext(path)[1].lower()
    if ext == ".glb":
        return len(head) == 12 and head[:4] == b"glTF" and struct.unpack("<I", head[8:12])[0] == size
    if ext == ".wav":
        return len(head) == 12 and head[:4] == b"RIFF" and head[8:12] == b"WAVE" and struct.unpack("<I", head[4:8])[0] + 8 <= size
    if ext == ".mp3":
        return head[:3] == b"ID3" or (len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0)
    return True


def present(outdir, src):
    return any(file_ok(os.path.join(outdir, o)) for o in outputs(src))


def batches(files, max_files, max_chars):
    cur, n = [], 0
    for f in files:
        if cur and (len(cur) >= max_files or n + len(f) + 1 > max_chars):
            yield cur
            cur, n = [], 0
        cur.append(f)
        n += len(f) + 1
    if cur:
        yield cur


def export(run, outdir, files, extra, cfg):
    """Export files (VPK paths) with run(batch, extra); returns the ones still missing after the retries."""
    files = sorted(set(files))
    todo = [f for f in files if not present(outdir, f)]
    if len(todo) < len(files):
        LOG("  %d of %d already exported, skipped" % (len(files) - len(todo), len(files)))
    for b in batches(todo, int(cfg["vrf_batch_files"]), int(cfg["vrf_batch_chars"])):
        run(b, extra)
    for attempt in range(int(cfg["vrf_retries"])):
        todo = [f for f in todo if not present(outdir, f)]
        if not todo:
            break
        LOG("  retry %d: %d file(s) failed the output check: %s" % (attempt + 1, len(todo), ", ".join(todo[:6]) + (" ..." if len(todo) > 6 else "")))
        for f in todo:  # one per call, so one bad path cannot cost the others
            run([f], extra)
    lost = [f for f in todo if not present(outdir, f)]
    for f in lost:
        LOG("  NOT EXPORTED: " + f)
    return lost


def vrf_runner(vrf, vpk, outdir, timeout):
    def run(files, extra):
        cmd = [vrf, "-i", vpk, "-o", outdir, "-d", "-f", ",".join(files)] + extra
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired:
            LOG("  VRF timed out after %ds on %d file(s)" % (timeout, len(files)))
            return False
        except OSError as e:
            raise PrepError("Source2Viewer-CLI could not start (%s): reinstall Rust Surf so prep/vrf is complete" % e)
        if r.returncode != 0:
            LOG("  VRF exit %d: %s" % (r.returncode, (r.stderr or r.stdout or "")[-400:].strip()))
        return r.returncode == 0
    return run


def content_sources(rows):
    """content.json cs2 rows -> (plain files, model/clip files). concrete_ct_01..04.vsnd_c is four files."""
    plain, gltf = [], []
    for r in rows:
        if r["game"] != "cs2" or r["kind"] == "config":
            continue
        src = r["source"].split(" ")[0]
        m = re.fullmatch(r"(.*_)(\d+)\.\.(\d+)(\.\w+)", src)
        if m:
            w = len(m.group(2))
            plain += ["%s%0*d%s" % (m.group(1), w, i, m.group(4)) for i in range(int(m.group(2)), int(m.group(3)) + 1)]
        elif r["kind"] in ("model", "animation"):
            gltf.append(src)
        else:
            plain.append(src)
    return plain, gltf


def short(names, n=6):
    """A list for one on-screen line; the full list is in prep.log."""
    return ", ".join(names[:n]) + (" and %d more" % (len(names) - n) if len(names) > n else "")


def weapon_rows(ws):
    return [w for w in ws["rows"] if w.get("game") == "cs2"]


def weapon_sources(ws):
    models, sounds = [], []
    for w in weapon_rows(ws):
        models.append(w["model"])
        models += list(w["clips"].values())
        sounds.append(w["sound_shot"])
    return sorted(set(models)), sorted(set(sounds))


def weapons_missing(outdir, ws):
    """{weapon id: [what is missing]} for every CS2 weapon whose model, any clip or shot sound is not in place."""
    out = {}
    for w in weapon_rows(ws):
        need = [("model", w["model"]), ("sound", w["sound_shot"])] + [("clip " + k, v) for k, v in sorted(w["clips"].items())]
        miss = [what for what, src in need if not present(outdir, src)]
        if miss:
            out[w["id"]] = miss
    return out


def write_stats(outdir, ws):
    """items_game.txt -> weapon_stats.json. Returns (problems, warnings)."""
    ig = os.path.join(outdir, ITEMS_GAME)
    names = [w["item"] for w in weapon_rows(ws)]
    if not present(outdir, ITEMS_GAME):
        return ["CS2 scripts/items/items_game.txt did not export, so no weapon has its real stats"], []
    try:
        st = items_game.stats(ig, names)
    except Exception as e:  # a format change in a CS2 update must say so, not crash prep
        return ["CS2 items_game.txt could not be read (%s: %s)" % (type(e).__name__, e)], []
    with open(os.path.join(outdir, "weapon_stats.json"), "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1)
    LOG("weapon stats: %d of %d weapons from items_game.txt" % (len(st), len(names)))
    problems, warnings = [], []
    lost = [n for n in names if n not in st]
    if lost:
        problems.append("CS2 items_game.txt has no item for: " + short(lost))
    thin = [n for n in names if n in st and not ({"damage", "cycletime"} <= set(st[n]))]
    if thin:  # the item exists but these keys were not found: the game fills them from weapon_defaults.json
        warnings.append("items_game.txt gave no damage/cycletime for %s: those use class averages" % short(thin))
    return problems, warnings


def cs2_step(a, here=HERE):
    """Exports everything; returns (problems, warnings) as player-facing sentences."""
    vpk = os.path.join(a.cs2, "game", "csgo", "pak01_dir.vpk")
    gi = os.path.join(a.cs2, "game", "csgo", "gameinfo.gi")
    if not os.path.isfile(vpk):
        raise PrepError("CS2 not found: no game/csgo/pak01_dir.vpk in %s (install or verify Counter-Strike 2 in Steam)" % a.cs2)
    if not os.path.isfile(a.vrf):
        raise PrepError("Source2Viewer-CLI.exe is missing from %s (reinstall Rust Surf; antivirus may have removed it)" % os.path.dirname(a.vrf))
    cfg = settings(here)
    outdir = os.path.join(a.out, "cs2")
    os.makedirs(outdir, exist_ok=True)
    run = a.runner(vpk, outdir, int(cfg["vrf_timeout_s"])) if getattr(a, "runner", None) else vrf_runner(a.vrf, vpk, outdir, int(cfg["vrf_timeout_s"]))
    gl = GLTF + ["--game", gi]
    plain, gltf = content_sources(sheet("content", here)["rows"])
    ws = sheet("weapons", here)
    wmodels, wsounds = weapon_sources(ws)
    LOG("cs2 items_game.txt")
    lost = export(run, outdir, [ITEMS_GAME], [], cfg)  # alone, so a bad sound path cannot cost the stats
    LOG("cs2 sounds: %d" % len(set(plain + wsounds)))
    lost += export(run, outdir, plain + wsounds, [], cfg)
    LOG("cs2 models+clips: %d" % len(set(gltf + wmodels)))
    lost += export(run, outdir, gltf + wmodels, gl, cfg)
    problems, warnings = write_stats(outdir, ws)
    base = [s for s in plain + gltf if not present(outdir, s)]
    if base:
        problems.append("CS2 arms/knife/sounds did not export: " + short([os.path.basename(s) for s in base]))
    wm = weapons_missing(outdir, ws)
    if wm:
        for k, v in sorted(wm.items()):
            LOG("  weapon %s missing: %s" % (k, ", ".join(v)))
        problems.append("%d of %d CS2 weapons did not export fully: %s" % (len(wm), len(weapon_rows(ws)), short(["%s (%s)" % (k, "/".join(v)) for k, v in sorted(wm.items())])))
    if lost and problems:
        problems[-1] += "; VRF failed %d file(s) after %d retries, see prep.log" % (len(lost), int(cfg["vrf_retries"]))
    return problems, warnings
