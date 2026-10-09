"""Rust side of prep: Launch Site meshes + placements, course textures, FSB audio.
Everything is read from the player-owned Rust install; nothing here is shipped."""
import os, sys, json, math, subprocess, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lazybundle
from glbwriter import write_glb

LOG = print

# backdrop selection: LOD0 meshes whose container path starts with one of these
BACKDROP_PREFIXES = (
    "assets/content/structures/launch_site/models/",
    "assets/content/structures/launch_site_floodlights/models/",
    "assets/content/structures/industrial_structures/models/launch_site_silo",
    "assets/content/structures/warehouses/models/warehouse_launch_site_a",
    # the big Launch Site buildings the monument prefab also places (inventory of its MeshFilters, 2026-10-09)
    "assets/content/structures/rocket_factory_building/",
    "assets/content/structures/rocket_crane/",
    "assets/content/structures/office_buildings/models/space_center",
    "assets/content/structures/perimeter_walls/",
    "assets/content/structures/roads/models/pavement_launchsite",
)
SCENE_NODE = "BuildPlayer-AssetScene-monument.1"
PREFAB = "assets/bundled/prefabs/autospawn/monument/xlarge/launch_site_1.prefab"


def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by, aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw, aw*bw - ax*bx - ay*by - az*bz)


def qrot(q, v):
    x, y, z, w = q
    qv = (x, y, z)
    t = [2 * c for c in cross(qv, v)]
    return tuple(v[i] + w * t[i] + cross(qv, t)[i] for i in range(3))


def cross(a, b):
    return (a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0])


def load_env(UnityPy, rust, bundles, node_filter=None):
    lazybundle.NODE_FILTER = node_filter
    t = time.time()
    env = UnityPy.load(*[os.path.join(rust, "Bundles", "shared", b) for b in bundles])
    lazybundle.NODE_FILTER = None
    LOG("loaded %s in %.0fs" % (", ".join(bundles), time.time() - t))
    return env


def export_texture(tex_pptr, out_png, max_size):
    if os.path.exists(out_png):
        return True
    try:
        tex = tex_pptr.read()
        img = tex.image
        if max(img.size) > max_size:
            img = img.resize((max_size, max_size))
        img.save(out_png)
        return True
    except Exception as e:
        LOG("  texture failed %s: %r" % (out_png, e))
        return False


def material_files(mat, tex_dir, uri_prefix, max_size):
    """Export _MainTex and _BumpMap of a Material; returns {albedo, normal} file names."""
    out = {}
    for key, slot in (("_MainTex", "albedo"), ("_BumpMap", "normal")):
        for k, v in mat.m_SavedProperties.m_TexEnvs:
            if k == key and v.m_Texture.m_PathID:
                fn = "%s_%s.png" % (mat.m_Name, slot)
                if export_texture(v.m_Texture, os.path.join(tex_dir, fn), max_size):
                    out[slot] = fn
    return out


def mesh_prims(mesh, mat_names):
    """UnityPy Mesh -> glb primitives in Godot space (z flipped, winding reversed, v flipped)."""
    from UnityPy.helpers.MeshHelper import MeshHandler
    h = MeshHandler(mesh)
    h.process()
    pos = [(v[0], v[1], -v[2]) for v in h.m_Vertices]
    nrm = [(v[0], v[1], -v[2]) for v in h.m_Normals] if h.m_Normals else None
    uvs = [(v[0], 1.0 - v[1]) for v in h.m_UV0] if h.m_UV0 else None
    prims = []
    for i, tris in enumerate(h.get_triangles()):
        idx = []
        for a, b, c in tris:
            idx += [a, c, b]
        prims.append({"positions": pos, "normals": nrm, "uvs": uvs, "indices": idx,
                      "material": mat_names[i] if i < len(mat_names) else None})
    return prims


def write_mesh_glb(mesh, mat_names, materials, out_dir, name):
    path = os.path.join(out_dir, name + ".glb")
    if os.path.exists(path):
        return
    write_glb(path, name, mesh_prims(mesh, mat_names), {m: materials[m] for m in mat_names if m in materials}, "../tex/")


def decode_fsb(clip, vgm, out_wav):
    from UnityPy.helpers.ResourceReader import get_resource_data
    if os.path.exists(out_wav):
        return True
    d = get_resource_data(clip.m_Resource.m_Source, clip.assets_file, clip.m_Resource.m_Offset, clip.m_Resource.m_Size)
    fsb = out_wav + ".fsb"
    open(fsb, "wb").write(bytes(d))
    r = subprocess.run([vgm, "-o", out_wav, fsb], capture_output=True, text=True)
    os.remove(fsb)
    if r.returncode != 0:
        LOG("  vgmstream failed: " + r.stderr[-300:])
    return r.returncode == 0
