"""Builds the Melty release zip: game build + prep bundle + licenses + README.
usage: package.py <version>  -> dist/RustSurf-<version>.zip, dist/RustSurf-<version>.entries.json"""
import os, sys, json, hashlib, zipfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the version is the one melty.recipe.json ships (RustSurf-<ver>.zip), so the zip and the recipe never disagree
recipe = json.load(open(os.path.join(R, "melty.recipe.json"), encoding="utf-8"))
rver = recipe["components"][0]["fileName"][len("RustSurf-"):-len(".zip")]
ver = sys.argv[1] if len(sys.argv) > 1 else rver
if ver != rver:
    sys.exit("version %s does not match melty.recipe.json (%s)" % (ver, rver))
out = os.path.join(R, "dist", "RustSurf-%s.zip" % ver)
parts = [(os.path.join(R, "dist", "RustSurf"), ""), (os.path.join(R, ".work", "prepbundle"), "prep/"), (os.path.join(R, "LICENSES"), "LICENSES/")]
for base, _ in parts:
    if not os.path.isdir(base):
        sys.exit("missing " + base + " (export the game to dist/RustSurf and build .work/prepbundle first)")
# our own prep sources and sheets always come from the repo, so the bundle never ships a stale copy
import shutil
for f in os.listdir(os.path.join(R, "prep")):
    if f.endswith((".py", ".json")):
        shutil.copy2(os.path.join(R, "prep", f), os.path.join(R, ".work", "prepbundle", f))
entries = []
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for base, prefix in parts:
        for dp, dn, fn in os.walk(base):
            for f in fn:
                # the embedded Python stdlib (prep/python312/) is all .pyc: only skip caches of our own .py
                if f.endswith(".log") or "__pycache__" in dp:
                    continue
                p = os.path.join(dp, f)
                rel = prefix + os.path.relpath(p, base).replace(os.sep, "/")
                z.write(p, rel)
                entries.append({"path": rel, "size": os.path.getsize(p)})
    for f in ("README.md",):
        z.write(os.path.join(R, f), f)
        entries.append({"path": f, "size": os.path.getsize(os.path.join(R, f))})
h = hashlib.sha256()
with open(out, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
meta = {"fileName": os.path.basename(out), "size": os.path.getsize(out), "sha256": h.hexdigest(), "entries": entries}
json.dump(meta, open(out[:-4] + ".entries.json", "w"))
print("%s: %d files, %.1f MB zipped, sha256 %s" % (meta["fileName"], len(entries), meta["size"] / 1048576, meta["sha256"][:16]))
