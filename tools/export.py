"""Exports the Windows build to dist/RustSurf. The game reads its sheets from res://data/, which is
gitignored, so every export first copies sheets/*.json into game/data/ (a stale copy there once
shipped 0.1.0 sheets inside a 0.2 build and crashed on start).
usage: export.py [godot_console_exe]"""
import os, sys, glob, shutil, subprocess
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
godot = sys.argv[1] if len(sys.argv) > 1 else os.path.join(R, ".tools", "godot", "Godot_v4.7.2-stable_win64_console.exe")
dst = os.path.join(R, "game", "data")
os.makedirs(dst, exist_ok=True)
for f in glob.glob(os.path.join(dst, "*.json")):
    os.remove(f)
sheets = glob.glob(os.path.join(R, "sheets", "*.json"))
for f in sheets:
    shutil.copy2(f, dst)
print("sheets -> game/data: %d" % len(sheets))
os.makedirs(os.path.join(R, "dist", "RustSurf"), exist_ok=True)
game = os.path.join(R, "game")
subprocess.run([godot, "--headless", "--path", game, "--import"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
p = subprocess.run([godot, "--headless", "--path", game, "--export-release", "Windows Desktop", os.path.join(R, "dist", "RustSurf", "RustSurf.exe")],
                   capture_output=True, text=True, errors="replace")
bad = [l for l in (p.stdout + p.stderr).splitlines() if "ERROR" in l or "SCRIPT ERROR" in l]
for l in bad:
    print(l)
if p.returncode != 0 or bad:
    sys.exit("export failed (exit %d, %d error lines)" % (p.returncode, len(bad)))
ver = subprocess.run([godot, "--version"], capture_output=True, text=True).stdout.strip()
print("export ok: Godot %s, --export-release \"Windows Desktop\" -> dist/RustSurf/RustSurf.exe" % ver)
