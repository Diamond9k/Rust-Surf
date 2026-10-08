"""Launch Site placements: every selected LOD0 mesh in the monument prefab with its world transform."""
import os, json, time
from prep_rust import BACKDROP_PREFIXES, SCENE_NODE, PREFAB, qmul, qrot, export_texture, write_mesh_glb, LOG


def selected_meshes(env):
    """(cab name, path id) -> mesh name for every backdrop LOD0 mesh in content.bundle."""
    sel = {}
    for p, o in env.container.items():
        if o.type.name == "Mesh" and p.startswith(BACKDROP_PREFIXES):
            m = o.read()
            if m.m_Name.endswith("LOD0"):
                af = getattr(o, "assets_file", None) or getattr(o, "assetsfile", None)
                pid = getattr(o, "path_id", None) or getattr(o, "m_PathID", None)
                sel[(af.name, pid)] = (m.m_Name, o)
    LOG("backdrop candidate meshes: %d" % len(sel))
    return sel


def world_trs(pptr, cache):
    """World (pos, rot, scale) of a Transform PPtr, composing up the parent chain."""
    key = pptr.m_PathID
    if key in cache:
        return cache[key]
    tr = pptr.read()
    lp, lr, ls = tr.m_LocalPosition, tr.m_LocalRotation, tr.m_LocalScale
    pos, rot, scl = (lp.x, lp.y, lp.z), (lr.x, lr.y, lr.z, lr.w), (ls.x, ls.y, ls.z)
    if tr.m_Father and tr.m_Father.m_PathID:
        ppos, prot, pscl = world_trs(tr.m_Father, cache)
        sp = (pos[0] * pscl[0], pos[1] * pscl[1], pos[2] * pscl[2])
        rp = qrot(prot, sp)
        pos = (ppos[0] + rp[0], ppos[1] + rp[1], ppos[2] + rp[2])
        rot = qmul(prot, rot)
        scl = (scl[0] * pscl[0], scl[1] * pscl[1], scl[2] * pscl[2])
    cache[key] = (pos, rot, scl)
    return cache[key]


def export_materials_grouped(mats, tex_dir, max_tex):
    """Export every material texture, grouped by the bundle the texture lives in, so each of the
    giant Rust texture blocks is decompressed once. Returns {material name: {albedo, normal}}."""
    jobs = []
    for name, m in mats.items():
        for key, slot in (("_MainTex", "albedo"), ("_BumpMap", "normal")):
            for k, v in m.m_SavedProperties.m_TexEnvs:
                if k == key and v.m_Texture.m_PathID:
                    af = getattr(v.m_Texture, "assetsfile", None)
                    cab = getattr(af, "name", "") if af is not None else ""
                    jobs.append((cab, v.m_Texture.m_FileID, name, slot, v.m_Texture))
    jobs.sort(key=lambda j: (j[0], j[1]))
    out = {n: {} for n in mats}
    t = time.time()
    for cab, fid, name, slot, pptr in jobs:
        fn = "%s_%s.png" % (name, slot)
        if export_texture(pptr, os.path.join(tex_dir, fn), max_tex):
            out[name][slot] = fn
    LOG("textures: %d exported in %.0fs" % (len(jobs), time.time() - t))
    return out


def extract_scene(env, out_dir, max_tex):
    """Writes rust/launch_site_placements.json, rust/mesh/*.glb and rust/tex/*.png."""
    mesh_dir = os.path.join(out_dir, "rust", "mesh")
    tex_dir = os.path.join(out_dir, "rust", "tex")
    os.makedirs(mesh_dir, exist_ok=True)
    os.makedirs(tex_dir, exist_ok=True)
    sel = selected_meshes(env)
    sf = None
    for f in env.files.values():
        for name, node in getattr(f, "files", {}).items():
            if name == SCENE_NODE:
                sf = node
    if sf is None:
        raise RuntimeError("Rust bundle has no " + SCENE_NODE)
    externals = [e.path.split("/")[-1] for e in sf.externals]
    placements, used_meshes, materials, cache = [], {}, {}, {}
    t = time.time()
    for o in sf.objects.values():
        if o.type.name != "MeshFilter":
            continue
        mf = o.read()
        pp = mf.m_Mesh
        if not pp.m_PathID or pp.m_FileID == 0:
            continue
        cab = externals[pp.m_FileID - 1]
        hit = sel.get((cab, pp.m_PathID))
        if hit is None:
            continue
        name, mesh_obj = hit
        go = mf.m_GameObject.read()
        tr, mats = None, []
        for comp in go.m_Component:
            cp = comp.component if hasattr(comp, "component") else comp
            c = cp.read()
            cn = type(c).__name__
            if cn == "Transform":
                tr = cp
            elif cn == "MeshRenderer":
                for mp in c.m_Materials:
                    try:
                        m = mp.read()
                        mats.append(m.m_Name)
                        if m.m_Name not in materials:
                            materials[m.m_Name] = m
                    except Exception as e:
                        mats.append(None)
        if tr is None:
            continue
        pos, rot, scl = world_trs(tr, cache)
        placements.append({"mesh": name, "pos": pos, "rot": rot, "scale": scl})
        if name not in used_meshes:
            used_meshes[name] = (mesh_obj, mats)
    LOG("placements: %d (%d unique meshes, %d materials) in %.0fs" % (len(placements), len(used_meshes), len(materials), time.time() - t))
    materials = export_materials_grouped(materials, tex_dir, max_tex)
    for name, (obj, mats) in used_meshes.items():
        try:
            write_mesh_glb(obj.read(), mats, materials, mesh_dir, name)
        except Exception as e:
            LOG("  mesh %s failed: %r" % (name, e))
    json.dump({"prefab": PREFAB, "placements": placements, "materials": materials},
              open(os.path.join(out_dir, "rust", "launch_site_placements.json"), "w"))
    return len(placements)
