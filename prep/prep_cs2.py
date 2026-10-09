"""CS2 side of prep: the content.json cs2 rows (arms, knife, clips, sounds) and every weapons.json row,
exported from the player's pak01_dir.vpk by Source2Viewer-CLI (VRF). Every output file is checked: a glb
against its own length field, its JSON chunk, its BIN chunk and every PNG texture it names (each PNG chunk
CRC), a model must hold a mesh and a clip an animation; wav against its RIFF size, mp3 frame sync, text
files must parse whole. A file that fails is exported again on its own. Whole files are skipped on a rerun,
except the stats files, which are always exported fresh so a CS2 update reaches weapon_stats.json.
No UnityPy here, so prep/tests can run all of it against a fake VRF.
cs2_step(a) -> (problems, warnings) as player-facing sentences; no problems means every CS2 file is in place."""
import os, re, json, struct, subprocess, zlib
import items_game, kv3

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
    encoding, models and clips .glb (with --gltf_export_format glb), other compiled resources lose their _c
    (a .vdata_c decompiles to .vdata text), plain files keep their name."""
    if src.endswith(".vsnd_c"):
        return [src[:-7] + ".wav", src[:-7] + ".mp3"]
    if src.endswith((".vmdl_c", ".vnmclip_c")):
        return [os.path.splitext(src)[0] + ".glb"]
    if src.endswith("_c"):
        return [src[:-2], src]
    return [src]


def png_ok(path):
    """A whole PNG: signature, every chunk's CRC, ending in IEND (a texture cut or garbled by a batch export fails)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    i = 8
    while i + 12 <= len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8])
        end = i + 12 + n
        if end > len(data) or zlib.crc32(data[i + 4:i + 8 + n]) & 0xFFFFFFFF != struct.unpack(">I", data[end - 4:end])[0]:
            return False
        if kind == b"IEND":
            return end == len(data)
        i = end
    return False


def glb_ok(path, need=None):
    """A whole glb as VRF 20 writes it (checked on real arms, knife and clip exports): header length = file
    size, a JSON chunk that parses, a BIN chunk at least as long as buffer 0, every image uri a whole PNG
    beside it, and need (meshes for a model, animations for a clip) non-empty."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(20)
            if len(head) < 20 or head[:4] != b"glTF" or struct.unpack("<I", head[8:12])[0] != size or head[16:20] != b"JSON":
                return False
            n = struct.unpack("<I", head[12:16])[0]
            if 20 + n > size:
                return False
            doc = json.loads(f.read(n).decode("utf-8"))
            bins = doc.get("buffers") or []
            if bins and "uri" not in bins[0]:
                bh = f.read(8)
                if len(bh) < 8 or bh[4:8] != b"BIN\0" or struct.unpack("<I", bh[:4])[0] < int(bins[0].get("byteLength", 0)):
                    return False
                if 28 + n + struct.unpack("<I", bh[:4])[0] > size:
                    return False
    except (OSError, ValueError, UnicodeDecodeError):
        return False
    if need and not doc.get(need):
        return False
    d = os.path.dirname(path)
    for im in doc.get("images") or []:
        u = im.get("uri")
        if u and not u.startswith("data:") and not png_ok(os.path.join(d, u.replace("%20", " "))):
            return False
    return True


def file_ok(path, need=None):
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
        return glb_ok(path, need)
    if ext == ".wav":
        return len(head) == 12 and head[:4] == b"RIFF" and head[8:12] == b"WAVE" and struct.unpack("<I", head[4:8])[0] + 8 <= size
    if ext == ".mp3":
        return head[:3] == b"ID3" or (len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0)
    if ext == ".png":
        return png_ok(path)
    if ext == ".txt":
        return items_game.whole(path)
    if ext == ".vdata":
        return kv3.whole(path)
    if ext == ".json":
        try:
            with open(path, encoding="utf-8") as f:
                json.load(f)
            return True
        except (OSError, ValueError):
            return False
    return True


def need_of(src):
    return "meshes" if src.endswith(".vmdl_c") else "animations" if src.endswith(".vnmclip_c") else None


def present(outdir, src):
    return any(file_ok(os.path.join(outdir, o), need_of(src)) for o in outputs(src))


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


def export(run, outdir, files, extra, cfg, fresh=False, retries=None):
    """Export files (VPK paths) with run(batch, extra); returns the ones still missing after the retries.
    fresh: delete earlier outputs first, so a file CS2 has since updated is never read from an old export."""
    files = sorted(set(files))
    if fresh:
        for f in files:
            for o in outputs(f):
                if os.path.isfile(os.path.join(outdir, o)):
                    os.remove(os.path.join(outdir, o))
    todo = [f for f in files if not present(outdir, f)]
    if len(todo) < len(files):
        LOG("  %d of %d already exported, skipped" % (len(files) - len(todo), len(files)))
    for b in batches(todo, int(cfg["vrf_batch_files"]), int(cfg["vrf_batch_chars"])):
        run(b, extra)
    for attempt in range(int(cfg["vrf_retries"]) if retries is None else retries):
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


def write_json(path, data):
    """Whole or not at all: a temp file renamed over the old one, so a crash mid-write never leaves half a file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def write_stats(outdir, ws, here=HERE):
    """items_game.txt (and weapons.vdata for what it lacks) -> weapon_stats.json. Returns (problems, warnings).
    A weapon without every stats_required attribute as a number is never silent: a player-visible warning naming
    the weapon and keys, or a problem when stats_required_blocks is yes (stats_light_slots guns need only
    stats_required_light). No readable stats file, or no entry for a weapon, is always a problem.
    stats_expected gaps are warnings."""
    cfg = settings(here)
    vd = sheet("prep", here)["vdata_keys"]
    light = set(keys(cfg["stats_light_slots"]))
    need_of_item = {w["item"]: keys(cfg["stats_required_light" if w["slot"] in light else "stats_required"]) for w in weapon_rows(ws)}
    names = [w["item"] for w in weapon_rows(ws)]
    st, src = {}, []
    if present(outdir, ITEMS_GAME):
        try:
            st = items_game.stats(os.path.join(outdir, ITEMS_GAME), names)
            src.append("items_game.txt")
        except Exception as e:  # a format change in a CS2 update must say so, not crash prep
            LOG("items_game.txt could not be read (%s: %s)" % (type(e).__name__, e))
    vpath = [os.path.join(outdir, o) for o in outputs(cfg["weapons_vdata"]) if file_ok(os.path.join(outdir, o))]
    vst = {}
    if vpath:
        try:
            vst = kv3.vdata_stats(vpath[0], names, vd)
            src.append("weapons.vdata")
        except Exception as e:
            LOG("weapons.vdata could not be read (%s: %s)" % (type(e).__name__, e))
    filled = 0
    for n, a in vst.items():
        cur = st.setdefault(n, {})
        for k, v in a.items():
            if k not in cur:  # items_game.txt wins; vdata only fills what it lacks
                cur[k] = v
                filled += 1
    for n in st:  # not a number, so Weapons.gd skips it; says where each weapon's stats came from
        st[n]["_source"] = " + ".join(x for x, has in (("items_game.txt", n not in vst or len(st[n]) > len(vst[n])), ("weapons.vdata", n in vst)) if has)
    LOG("weapon stats: %d of %d weapons from %s; %d value(s) filled from weapons.vdata" % (len(st), len(names), " + ".join(src) or "nothing", filled))
    if not src:
        return ["CS2 weapon stats could not be read: scripts/items/items_game.txt did not export or is damaged (verify CS2's files in Steam)"], []
    write_json(os.path.join(outdir, "weapon_stats.json"), st)
    problems, warnings = [], []
    lost = [n for n in names if n not in st]
    if lost:
        problems.append("CS2 has no weapon entry for %s in items_game.txt%s: a CS2 update may have renamed them" % (short(lost), " or weapons.vdata" if vst else ""))
    thin = {n: [k for k in need_of_item[n] if not number(st[n].get(k))] for n in names if n in st}
    thin = ["%s (%s)" % (n, "/".join(m)) for n, m in thin.items() if m]
    for x in thin:
        LOG("  stats missing: " + x)
    if thin and blocks(cfg):
        problems.append("CS2 gave no usable value for some stats of %d weapon(s): %s. Setup stops rather than run those guns on "
                        "guessed numbers; a CS2 update probably moved the stats, so Rust Surf needs an update" % (len(thin), short(thin, 3)))
    elif thin:
        warnings.append("%d gun(s) play on class-average stats because this CS2 version's files did not give them: %s. "
                        "Rust Surf needs an update for this CS2 version; setup again will not fix it" % (len(thin), short(thin, 3)))
    want = keys(cfg["stats_expected"])
    part = ["%s (%s)" % (n, "/".join(k for k in want if not number(st[n].get(k)))) for n in names if n in st and not all(number(st[n].get(k)) for k in want)]
    if part:
        warnings.append("%d weapon(s) use class averages for some stats: %s" % (len(part), short(part, 3)))
    return problems, warnings


def blocks(cfg):
    """stats_required_blocks: yes stops setup on a stats_required gap, anything else makes it a warning."""
    return str(cfg.get("stats_required_blocks", "no")).strip().lower() in ("yes", "true", "1")


def keys(cell):
    """A sheet cell "a,b c,d" -> ["a", "b c", "d"]."""
    return [k.strip() for k in str(cell).split(",") if k.strip()]


def number(v):
    """True for a value Weapons.gd reads as a stat (it skips anything that is not a float)."""
    try:
        return float(v) == float(v)  # NaN is not a stat
    except (TypeError, ValueError):
        return False


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
    lost = export(run, outdir, [ITEMS_GAME], [], cfg, fresh=True)  # alone, so a bad sound path cannot cost the stats
    LOG("cs2 weapons.vdata (optional)")
    export(run, outdir, [cfg["weapons_vdata"]], [], cfg, fresh=True, retries=0)  # optional: only missing stats are a problem
    LOG("cs2 sounds: %d" % len(set(plain + wsounds)))
    lost += export(run, outdir, plain + wsounds, [], cfg)
    LOG("cs2 models+clips: %d" % len(set(gltf + wmodels)))
    lost += export(run, outdir, gltf + wmodels, gl, cfg)
    problems, warnings = write_stats(outdir, ws, here)
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
