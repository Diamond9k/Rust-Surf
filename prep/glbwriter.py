"""Minimal GLB writer: one mesh, N primitives, PBR materials with external PNG uris.
Takes Godot-space data (right-handed, Y up): the caller flips Unity data before calling."""
import json, struct


def _pad(b, n=4, ch=b"\0"):
    return b + ch * ((n - len(b) % n) % n)


def write_glb(path, name, prims, materials, image_dir_rel):
    """prims: list of dicts {positions:[(x,y,z)], normals:[(x,y,z)] or None, uvs:[(u,v)] or None,
    indices:[int], material: name or None}. materials: {name: {albedo: file, normal: file or None}}.
    image_dir_rel: uri prefix for images (relative to the glb)."""
    buf = bytearray()
    views, accessors, meshes_prims = [], [], []
    mat_index = {}
    gl_materials, gl_textures, gl_images = [], [], []

    def add_view(data, target=None):
        off = len(buf)
        buf.extend(_pad(data))
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    def add_accessor(view, ctype, count, atype, mn=None, mx=None):
        a = {"bufferView": view, "componentType": ctype, "count": count, "type": atype}
        if mn is not None:
            a["min"], a["max"] = mn, mx
        accessors.append(a)
        return len(accessors) - 1

    def add_image(file):
        gl_images.append({"uri": image_dir_rel + file})
        gl_textures.append({"source": len(gl_images) - 1})
        return len(gl_textures) - 1

    for mname, m in materials.items():
        gm = {"name": mname, "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 0.9}}
        if m.get("albedo"):
            gm["pbrMetallicRoughness"]["baseColorTexture"] = {"index": add_image(m["albedo"])}
        if m.get("normal"):
            gm["normalTexture"] = {"index": add_image(m["normal"])}
        gm["doubleSided"] = True
        mat_index[mname] = len(gl_materials)
        gl_materials.append(gm)

    for p in prims:
        pos = p["positions"]
        n = len(pos)
        pdata = struct.pack("<%df" % (3 * n), *[c for v in pos for c in v])
        mn = [min(v[i] for v in pos) for i in range(3)]
        mx = [max(v[i] for v in pos) for i in range(3)]
        attrs = {"POSITION": add_accessor(add_view(pdata, 34962), 5126, n, "VEC3", mn, mx)}
        if p.get("normals"):
            nd = struct.pack("<%df" % (3 * n), *[c for v in p["normals"] for c in v[:3]])
            attrs["NORMAL"] = add_accessor(add_view(nd, 34962), 5126, n, "VEC3")
        if p.get("uvs"):
            ud = struct.pack("<%df" % (2 * n), *[c for v in p["uvs"] for c in v[:2]])
            attrs["TEXCOORD_0"] = add_accessor(add_view(ud, 34962), 5126, n, "VEC2")
        idx = p["indices"]
        idata = struct.pack("<%dI" % len(idx), *idx)
        prim = {"attributes": attrs, "indices": add_accessor(add_view(idata, 34963), 5125, len(idx), "SCALAR"), "mode": 4}
        if p.get("material") in mat_index:
            prim["material"] = mat_index[p["material"]]
        meshes_prims.append(prim)

    doc = {
        "asset": {"version": "2.0", "generator": "RustSurf prep"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": meshes_prims}],
        "bufferViews": views,
        "accessors": accessors,
        "buffers": [{"byteLength": len(buf)}],
    }
    if gl_materials:
        doc["materials"] = gl_materials
        doc["textures"] = gl_textures
        doc["images"] = gl_images
        doc["samplers"] = []
    jb = _pad(json.dumps(doc, separators=(",", ":")).encode(), 4, b" ")
    bb = bytes(_pad(buf))
    total = 12 + 8 + len(jb) + 8 + len(bb)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<II", len(jb), 0x4E4F534A))
        f.write(jb)
        f.write(struct.pack("<II", len(bb), 0x004E4942))
        f.write(bb)
