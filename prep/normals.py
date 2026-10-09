"""Unity stores _BumpMap textures as DXTnm: X in alpha, Y in green, red and blue filler (red reads 255).
Godot and glTF want tangent-space XYZ in RGB. unpack() rewrites one PNG in place; fix_dir() does every
*_normal.png / *_BumpMap.png in a folder and is safe to run again (it skips files already unpacked)."""
import os, glob, math
from PIL import Image


def is_dxtnm(img):
    if img.mode != "RGBA":
        return False
    r = img.getchannel("R").resize((32, 32))
    return sum(r.tobytes()) / 1024.0 > 250


def _z_lut():
    # z = sqrt(1 - x^2 - y^2) for every 8-bit (x, y) pair, as one 65536-entry table.
    out = bytearray(65536)
    for xi in range(256):
        fx = xi / 127.5 - 1.0
        for yi in range(256):
            fy = yi / 127.5 - 1.0
            out[(xi << 8) | yi] = int(round((math.sqrt(max(0.0, 1.0 - fx * fx - fy * fy)) * 0.5 + 0.5) * 255))
    return out


_LUT = None


def unpack(path):
    global _LUT
    img = Image.open(path)
    if not is_dxtnm(img):
        return False
    if _LUT is None:
        _LUT = _z_lut()
    x = img.getchannel("A")
    y = img.getchannel("G")
    xs, ys = x.tobytes(), y.tobytes()
    lut = _LUT
    zb = bytes(lut[(a << 8) | b] for a, b in zip(xs, ys))
    z = Image.frombytes("L", x.size, zb)
    Image.merge("RGB", (x, y, z)).save(path)
    return True


def fix_dir(d, log=print):
    n = 0
    for p in sorted(glob.glob(os.path.join(d, "*_normal.png")) + glob.glob(os.path.join(d, "*_BumpMap.png"))):
        if unpack(p):
            n += 1
    log("normals: unpacked %d DXTnm maps in %s" % (n, d))
    return n


if __name__ == "__main__":
    import sys
    fix_dir(sys.argv[1])
