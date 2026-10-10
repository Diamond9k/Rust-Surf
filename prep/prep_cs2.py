"""CS2 side of prep: the content.json cs2 rows (arms, knife, clips, sounds) and every weapons.json row,
exported from the player's pak01_dir.vpk by Source2Viewer-CLI (VRF). Every output file is checked: a glb
against its own length field, its JSON chunk, its BIN chunk and every PNG texture it names (each chunk CRC and
the pixel stream inflating to the size its header gives), a model must hold a mesh and a clip an animation;
wav against its RIFF size, mp3 frame sync, text files must parse whole. A file that fails has its damaged
outputs (and damaged textures) deleted and is exported again on its own. Whole files are skipped on a rerun,
except the stats files, which are always exported fresh so a CS2 update reaches weapon_stats.json.
No UnityPy here, so prep/tests can run all of it against a fake VRF.
cs2_step(a) -> (problems, warnings) as player-facing sentences; no problems means every CS2 file is in place."""
import os, re, json, struct, subprocess, zlib
from urllib.parse import unquote
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


_PNG_SEEN = {}  # (path, size, mtime) -> verdict, so a texture shared by several models is decoded once per run
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}  # PNG colour type -> samples per pixel


def png_raw_size(w, h, depth, ctype, interlace):
    """Bytes the IDAT stream must inflate to: one filter byte per row plus the packed samples, for each of the
    seven Adam7 passes when interlaced."""
    bits = depth * _CHANNELS[ctype]
    rows = lambda pw, ph: 0 if pw == 0 or ph == 0 else ph * (1 + (pw * bits + 7) // 8)
    if not interlace:
        return rows(w, h)
    return sum(rows((w - x0 + dx - 1) // dx if w > x0 else 0, (h - y0 + dy - 1) // dy if h > y0 else 0)
               for x0, y0, dx, dy in ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)))


def png_ok(path):
    """A whole PNG: signature, IHDR first with a valid size and format, every chunk's CRC, ending in IEND, and
    the IDAT stream inflating to exactly the pixel data IHDR describes with a valid filter byte on every row (a
    texture cut, garbled or mixed up by a batch export fails, even when its chunk CRCs were written over the
    garbage)."""
    try:
        st = os.stat(path)
        key = (os.path.abspath(path), st.st_size, st.st_mtime_ns)
        if key in _PNG_SEEN:
            return _PNG_SEEN[key]
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    ok = _png_check(data)
    if len(_PNG_SEEN) > 4096:
        _PNG_SEEN.clear()
    _PNG_SEEN[key] = ok
    return ok


def _png_check(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    i, head, z, out, stride, filters_ok = 8, None, zlib.decompressobj(), 0, 0, True
    while i + 12 <= len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8])
        end = i + 12 + n
        if end > len(data) or zlib.crc32(data[i + 4:i + 8 + n]) & 0xFFFFFFFF != struct.unpack(">I", data[end - 4:end])[0]:
            return False
        body = data[i + 8:i + 8 + n]
        if head is None:
            if kind != b"IHDR" or n != 13:
                return False
            w, h, depth, ctype, comp, filt, interlace = struct.unpack(">IIBBBBB", body)
            if w == 0 or h == 0 or ctype not in _CHANNELS or depth not in (1, 2, 4, 8, 16) or comp or filt or interlace > 1:
                return False
            head = png_raw_size(w, h, depth, ctype, interlace)
            stride = 0 if interlace else 1 + (w * depth * _CHANNELS[ctype] + 7) // 8
        elif kind == b"IDAT":
            try:
                chunk = z.decompress(body, max(1, head - out + 1))
            except zlib.error:
                return False
            if stride:  # every row starts with a filter type 0..4
                filters_ok = filters_ok and max(chunk[(stride - out % stride) % stride::stride], default=0) <= 4
            out += len(chunk)
            if out > head:
                return False
        elif kind == b"IEND":
            return end == len(data) and head is not None and z.eof and out == head and filters_ok
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
    return all(png_ok(p) for p in glb_images(path, doc))


def glb_images(path, doc=None):
    """The PNG files beside a glb that its images name by uri (embedded data: images are inside the glb)."""
    if doc is None:
        try:
            with open(path, "rb") as f:
                head = f.read(20)
                doc = json.loads(f.read(struct.unpack("<I", head[12:16])[0]).decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError, struct.error):
            return []
    d = os.path.dirname(path)
    return [os.path.join(d, unquote(im["uri"])) for im in doc.get("images") or []
            if isinstance(im, dict) and isinstance(im.get("uri"), str) and im["uri"] and not im["uri"].startswith("data:")]


def discard(outdir, src):
    """Deletes what a failed export of src left behind: its outputs that fail the check, and for a glb every
    texture it names that is not a whole PNG, so the retry writes them fresh rather than leaving a bad one in place."""
    for o in outputs(src):
        p = os.path.join(outdir, o)
        if not os.path.isfile(p) or file_ok(p, need_of(src)):
            continue
        for t in glb_images(p) if p.endswith(".glb") else []:
            if os.path.isfile(t) and not png_ok(t):
                os.remove(t)
                LOG("  removed damaged texture " + os.path.relpath(t, outdir).replace(os.sep, "/"))
        os.remove(p)


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
        # every file again, not just this run's: an export can overwrite a texture an earlier, whole model shares
        todo = [f for f in files if not present(outdir, f)]
        if not todo:
            break
        LOG("  retry %d: %d file(s) failed the output check: %s" % (attempt + 1, len(todo), ", ".join(todo[:6]) + (" ..." if len(todo) > 6 else "")))
        for f in todo:  # one per call, so one bad path cannot cost the others; a damaged output goes first
            discard(outdir, f)
            run([f], extra)
    lost = [f for f in files if not present(outdir, f)]
    for f in lost:
        LOG("  NOT EXPORTED: " + f)
    return lost


def vrf_runner(vrf, vpk, outdir, timeout, file_timeout=None, hang_limit=0):
    """run(files, extra) -> True on exit 0. A call of one file (every retry) gets file_timeout instead of timeout,
    and after hang_limit calls have timed out in one run a PrepError stops setup with the reason, rather than a
    VRF that hangs on every file holding the player at a frozen setup window for hours (0: no limit)."""
    hung = []

    def run(files, extra):
        cmd = [vrf, "-i", vpk, "-o", outdir, "-d", "-f", ",".join(files)] + extra
        t = file_timeout if file_timeout and len(files) == 1 else timeout
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=t)
        except subprocess.TimeoutExpired:
            LOG("  VRF timed out after %ds on %d file(s)" % (t, len(files)))
            hung.append(files[0])
            if hang_limit and len(hung) >= hang_limit:
                raise PrepError("Source2Viewer-CLI stopped responding on %d exports (%s), so setup stopped instead of waiting on every file: "
                                "verify CS2's files in Steam and let your antivirus allow Rust Surf's prep folder, then start again" % (len(hung), short(hung, 3)))
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
    Where both files give a stat and disagree, stats_conflict_winner picks the value played; each pair is logged
    and kept under the gun's "_conflicts" (tools/package.py refuses a release on one until that row is verified).
    A weapon without every stats_required attribute as a number is never silent: a player-visible warning naming
    the weapon and keys, or a problem when stats_required_blocks is yes (stats_light_slots guns need only
    stats_required_light). No readable stats file, or no entry for a weapon, is always a problem.
    stats_expected gaps are warnings."""
    cfg = settings(here)
    vd = sheet("prep", here)["vdata_keys"]
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
    filled, clash = 0, conflicts(st, vst, cfg)
    for n, a in vst.items():
        cur = st.setdefault(n, {})
        for k, v in a.items():
            if k not in cur:  # vdata fills what items_game.txt lacks
                cur[k] = v
                filled += 1
    vd_wins = str(cfg.get("stats_conflict_winner", "items_game.txt")).strip() == "weapons.vdata"
    for n, c in sorted(clash.items()):
        for k, pair in sorted(c.items()):
            LOG("  stats conflict: %s %s items_game.txt %s, weapons.vdata %s; playing the %s value"
                % (n, k, pair["items_game.txt"], pair["weapons.vdata"], "weapons.vdata" if vd_wins else "items_game.txt"))
            if vd_wins:
                st[n][k] = pair["weapons.vdata"]
        st[n]["_conflicts"] = c  # not a number, so Weapons.gd skips it; tools/package.py reads it
    for n in st:  # not a number, so Weapons.gd skips it; says where each weapon's stats came from
        st[n]["_source"] = " + ".join(x for x, has in (("items_game.txt", n not in vst or len(st[n]) - (n in clash) > len(vst[n])), ("weapons.vdata", n in vst)) if has)
    LOG("weapon stats: %d of %d weapons from %s; %d value(s) filled from weapons.vdata; %d value(s) the two files disagree on"
        % (len(st), len(names), " + ".join(src) or "nothing", filled, sum(len(c) for c in clash.values())))
    if not src:
        return ["CS2 weapon stats could not be read: scripts/items/items_game.txt did not export or is damaged (verify CS2's files in Steam)"], []
    write_json(os.path.join(outdir, "weapon_stats.json"), st)
    problems, warnings = [], []
    lost = [n for n in names if n not in st]
    if lost:
        problems.append("CS2 has no weapon entry for %s in items_game.txt%s: a CS2 update may have renamed them" % (short(lost), " or weapons.vdata" if vst else ""))
    thin = ["%s (%s)" % (n, "/".join(m)) for n, m in stats_gaps(st, ws, cfg).items()]
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


def conflicts(ig, vd, cfg):
    """{weapon: {key: {"items_game.txt": value, "weapons.vdata": value}}} for every stat both files give as a
    number, further apart than stats_conflict_tolerance."""
    tol = float(cfg.get("stats_conflict_tolerance", 0.0005))
    out = {}
    for n, a in vd.items():
        c = {k: {"items_game.txt": ig[n][k], "weapons.vdata": v} for k, v in a.items()
             if n in ig and number(ig[n].get(k)) and number(v) and abs(float(ig[n][k]) - float(v)) > tol}
        if c:
            out[n] = c
    return out


def stats_gaps(st, ws, cfg):
    """{weapon item: [stats_required keys (stats_required_light for stats_light_slots guns) that st does not give
    as a number]} for every weapons.json gun st has an entry for; tools/package.py asks the same of a release's data."""
    light = set(keys(cfg["stats_light_slots"]))
    out = {}
    for w in weapon_rows(ws):
        n = w["item"]
        if n in st:
            miss = [k for k in keys(cfg["stats_required_light" if w["slot"] in light else "stats_required"]) if not number(st[n].get(k))]
            if miss:
                out[n] = miss
    return out


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


def cs2_fingerprint(cs2, cfg):
    """{"files": [{"path", "size", "mtime"}], "tolerance_s"}: size and modified time (whole seconds) of the
    cs2_update_files that exist in the CS2 folder. prep_status.json keeps it; the game compares it with the live
    files at start (Main._cs2_updated) and removes the done file when CS2 has updated, so setup reads the new
    stats on the next start; prep exports every CS2 file fresh when it differs from the last run's."""
    out = []
    for rel in keys(cfg["cs2_update_files"]):
        try:
            st = os.stat(os.path.join(cs2, *rel.split("/")))
        except OSError:
            continue
        out.append({"path": rel, "size": st.st_size, "mtime": int(st.st_mtime)})
    return {"files": out, "tolerance_s": float(cfg["cs2_update_mtime_tolerance_s"])}


def fingerprint_changed(old, new):
    """True when an earlier run's fingerprint names a file set, size or modified time (beyond its tolerance)
    that the current CS2 files no longer match. No earlier fingerprint is no change: nothing to compare."""
    if not isinstance(old, dict) or not old.get("files"):
        return False
    tol = float(old.get("tolerance_s", 0))
    was = {f.get("path"): f for f in old["files"] if isinstance(f, dict)}
    now = {f["path"]: f for f in new.get("files", [])}
    if set(was) != set(now):
        return True
    try:
        return any(int(was[p]["size"]) != now[p]["size"] or abs(float(was[p]["mtime"]) - now[p]["mtime"]) > tol for p in now)
    except (KeyError, TypeError, ValueError):
        return True  # a damaged record: export fresh rather than trust it


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
    run = a.runner(vpk, outdir, int(cfg["vrf_timeout_s"])) if getattr(a, "runner", None) else \
        vrf_runner(a.vrf, vpk, outdir, int(cfg["vrf_timeout_s"]), int(cfg["vrf_file_timeout_s"]), int(cfg["vrf_hang_limit"]))
    fresh = bool(getattr(a, "cs2_changed", False))  # CS2 updated since the last setup: no earlier export is trusted
    if fresh:
        LOG("CS2 has updated since the last setup: every CS2 file is exported fresh")
    gl = GLTF + ["--game", gi]
    plain, gltf = content_sources(sheet("content", here)["rows"])
    ws = sheet("weapons", here)
    wmodels, wsounds = weapon_sources(ws)
    LOG("cs2 items_game.txt")
    lost = export(run, outdir, [ITEMS_GAME], [], cfg, fresh=True)  # alone, so a bad sound path cannot cost the stats
    LOG("cs2 weapons.vdata (optional)")
    export(run, outdir, [cfg["weapons_vdata"]], [], cfg, fresh=True, retries=0)  # optional: only missing stats are a problem
    LOG("cs2 sounds: %d" % len(set(plain + wsounds)))
    lost += export(run, outdir, plain + wsounds, [], cfg, fresh=fresh)
    LOG("cs2 models+clips: %d" % len(set(gltf + wmodels)))
    lost += export(run, outdir, gltf + wmodels, gl, cfg, fresh=fresh)
    a.cs2_exported = True  # every file was exported (or tried) against this CS2 version: prep.finish records it
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
