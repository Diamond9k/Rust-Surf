"""Writes sheets/weapons.json: one row per CS2 weapon with every in-game path checked against a
listing of the player's CS2 pak01_dir.vpk (one path per line, as VRF prints it).
usage: gen_weapons.py <cs2_files.txt> [out.json]
Stats are not written here: the game reads them from scripts/items/items_game.txt at runtime."""
import sys, json, re, os

# items_game names that differ from our ids (the M4A4 is weapon_m4a1 in CS2's item schema)
ITEM = {"m4a4": "weapon_m4a1"}
# (id, slot, model dir, model file stem, viewmodel clip folder, clip suffix, display name, sound dir, shot sound stem)
CS2 = [
    ("ak47", "rifle", "ak47", "weapon_rif_ak47", "rifle/rifle_ak", "ak", "AK-47", "ak47", "ak47_01"),
    ("m4a4", "rifle", "m4a4", "weapon_rif_m4a4", "rifle/rifle_m4a4", "m4a4", "M4A4", "m4a1", "m4a1_01"),
    ("m4a1_silencer", "rifle", "m4a1_silencer", "weapon_rif_m4a1_silencer", "rifle/rifle_m4a1_silencer", "m4a1", "M4A1-S", "m4a1", "m4a1_silencer_01"),
    ("aug", "rifle", "aug", "weapon_rif_aug", "rifle/rifle_aug", "aug", "AUG", "aug", None),
    ("sg556", "rifle", "sg556", "weapon_rif_sg556", "rifle/rifle_sg556", "sg556", "SG 553", "sg556", None),
    ("famas", "rifle", "famas", "weapon_rif_famas", "rifle/rifle_famas", "famas", "FAMAS", "famas", None),
    ("galilar", "rifle", "galilar", "weapon_rif_galilar", "rifle/rifle_galilar", "galilar", "Galil AR", "galilar", "galil_01"),
    ("awp", "sniper", "awp", "weapon_snip_awp", "rifle/rifle_awp", "awp", "AWP", "awp", None),
    ("ssg08", "sniper", "ssg08", "weapon_snip_ssg08", "rifle/rifle_ssg08", "ssg08", "SSG 08", "ssg08", None),
    ("scar20", "sniper", "scar20", "weapon_snip_scar20", "rifle/rifle_scar20", "scar20", "SCAR-20", "scar20", None),
    ("g3sg1", "sniper", "g3sg1", "weapon_snip_g3sg1", "rifle/rifle_g3sg1", "g3sg1", "G3SG1", "g3sg1", None),
    ("mp9", "smg", "mp9", "weapon_smg_mp9", "rifle/rifle_mp9", "mp9", "MP9", "mp9", None),
    ("mac10", "smg", "mac10", "weapon_smg_mac10", "rifle/rifle_mac10", "mac10", "MAC-10", "mac10", None),
    ("mp7", "smg", "mp7", "weapon_smg_mp7", "rifle/rifle_mp7", "mp7", "MP7", "mp7", None),
    ("mp5sd", "smg", "mp5sd", "weapon_smg_mp5sd", "rifle/rifle_mp5sd", "mp5sd", "MP5-SD", "mp5", None),
    ("ump45", "smg", "ump45", "weapon_smg_ump45", "rifle/rifle_ump45", "ump45", "UMP-45", "ump45", "ump45_02"),
    ("p90", "smg", "p90", "weapon_smg_p90", "rifle/rifle_p90", "p90", "P90", "p90", None),
    ("bizon", "smg", "bizon", "weapon_smg_bizon", "rifle/rifle_bizon", "bizon", "PP-Bizon", "bizon", None),
    ("nova", "heavy", "nova", "weapon_shot_nova", "rifle/rifle_nova", "nova", "Nova", "nova", None),
    ("xm1014", "heavy", "xm1014", "weapon_shot_xm1014", "rifle/rifle_xm1014", "xm1014", "XM1014", "xm1014", None),
    ("mag7", "heavy", "mag7", "weapon_shot_mag7", "rifle/rifle_mag7", "mag7", "MAG-7", "mag7", None),
    ("sawedoff", "heavy", "sawedoff", "weapon_shot_sawedoff", "rifle/rifle_sawedoff", "sawedoff", "Sawed-Off", "sawedoff", None),
    ("m249", "heavy", "m249", "weapon_mach_m249", "rifle/rifle_m249", "m249", "M249", "m249", None),
    ("negev", "heavy", "negev", "weapon_mach_negev", "rifle/rifle_negev", "negev", "Negev", "negev", None),
    ("glock", "pistol", "glock18", "weapon_pist_glock18", "pistol/pistol_glock18", "glock", "Glock-18", "glock18", None),
    ("hkp2000", "pistol", "hkp2000", "weapon_pist_hkp2000", "pistol/pistol_hkp2000", "hkp2000", "P2000", "hkp2000", None),
    ("usp_silencer", "pistol", "usp_silencer", "weapon_pist_usp_silencer", "pistol/pistol_usp_silencer", "usp", "USP-S", "usp", "usp_01"),
    ("p250", "pistol", "p250", "weapon_pist_p250", "pistol/pistol_p250", "p250", "P250", "p250", None),
    ("fiveseven", "pistol", "fiveseven", "weapon_pist_fiveseven", "pistol/pistol_fiveseven", "fiveseven", "Five-SeveN", "fiveseven", None),
    ("tec9", "pistol", "tec9", "weapon_pist_tec9", "pistol/pistol_tec9", "tec9", "Tec-9", "tec9", "tec9_02"),
    ("cz75a", "pistol", "cz75a", "weapon_pist_cz75a", "pistol/pistol_cz75a", "cz75a", "CZ75-Auto", "cz75a", None),
    ("elite", "pistol", "elite", "weapon_pist_elite", "pistol/pistol_elite", "elite", "Dual Berettas", "elite", None),
    ("deagle", "pistol", "deagle", "weapon_pist_deagle", "pistol/pistol_deagle", "deagle", "Desert Eagle", "deagle", None),
    ("revolver", "pistol", "revolver", "weapon_pist_revolver", "pistol/pistol_revolver", "revolver", "R8 Revolver", "revolver", None),
    ("taser", "pistol", "taser", "weapon_pist_taser", "pistol/pistol_taser", "taser", "Zeus x27", "taser", "taser_shoot"),
]
ACTIONS = ["draw", "idle", "shoot1", "reload", "lookat01"]


def main():
    files = set(l.strip() for l in open(sys.argv[1], encoding="utf-8", errors="replace"))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "sheets", "weapons.json")
    rows, report = [], []
    for wid, slot, mdir, stem, folder, suf, name, sdir, shot in CS2:
        model = "weapons/models/%s/%s.vmdl_c" % (mdir, stem)
        row = {"id": "cs2_" + wid, "game": "cs2", "slot": slot, "name": name, "item": ITEM.get(wid, "weapon_" + wid),
               "model": model if model in files else None}
        # clip folder: exact, else any folder starting with the same weapon stem
        base = "animation/anims/viewmodel/" + folder + "/"
        if not any(f.startswith(base) for f in files):
            cands = sorted({f.split("/")[4] for f in files if f.startswith("animation/anims/viewmodel/" + folder.split("/")[0] + "/") and suf in f.split("/")[4]})
            base = ("animation/anims/viewmodel/%s/%s/" % (folder.split("/")[0], cands[0])) if cands else None
        default = "animation/anims/viewmodel/%s/_default_%s/" % (folder.split("/")[0], folder.split("/")[0])
        clips = {}
        for a in ACTIONS:
            hit = None
            if base:
                hits = sorted(f for f in files if f.startswith(base) and f.split("/")[-1].startswith(a + "_") and f.endswith(".vnmclip_c") and "silenc" not in f.split("/")[-1] and "draw_" not in f.split("/")[-1][len(a) + 1:])
                hit = hits[0] if hits else None
            if hit is None:
                hits = sorted(f for f in files if f.startswith(default) and f.split("/")[-1].startswith(a + "_") and f.endswith(".vnmclip_c") and "silenc" not in f)
                hit = hits[0] if hits else None
            clips[a] = hit
        row["clips"] = clips
        sd = "sounds/weapons/%s/" % sdir
        snd = sorted(f for f in files if f.startswith(sd) and re.search(r"(_0?1|-1)\.vsnd_c$", f) and not re.search(r"(distant|draw|clip|bolt|inspect|silenced|sil_|unsil|empty|dry|slide|cock|zoom|hammer|reload|pump|insert|addammo|deploy)", f))
        row["sound_shot"] = snd[0] if snd else None
        if shot and sd + shot + ".vsnd_c" in files:
            row["sound_shot"] = sd + shot + ".vsnd_c"
        missing = [k for k in ("model", "sound_shot") if not row[k]] + [a for a in ACTIONS if not clips[a]]
        row["verified"] = "paths found in the CS2 pak01_dir.vpk listing" + ("" if not missing else "; missing: " + ", ".join(missing))
        rows.append(row)
        report.append("%-16s %s" % (wid, "ok" if not missing else "missing " + ",".join(missing)))
    sheet = {"_sheet": "weapons",
             "_doc": "Every weapon the player can hold. CS2 rows: model, viewmodel clips and shot sound are exact paths in the player's CS2 pak01_dir.vpk (checked against a listing by tools/gen_weapons.py); prep exports them to the data folder. Damage, fire rate, magazine, recoil and spread come from the player's own scripts/items/items_game.txt at runtime, never typed in. Rust rows are added by prep_weapons_rust.py.",
             "columns": ["id", "game", "slot", "name", "item", "model", "clips", "sound_shot", "verified"],
             "rows": rows}
    json.dump(sheet, open(out, "w"), indent=1)
    # prep reads its own copy from the prep folder (it ships without sheets/): keep the two identical
    json.dump(sheet, open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "prep", "weapons.json"), "w"), indent=1)
    print("\n".join(report))
    print("%d weapons, %d complete" % (len(rows), sum(1 for r in report if r.endswith("ok"))))


if __name__ == "__main__":
    main()
