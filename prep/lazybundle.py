"""Lazy UnityFS reading for UnityPy.

UnityPy decompresses a whole bundle into memory, and Rust's bundles are 3-7 GB each.
This patch keeps the bundle on disk and decompresses only the blocks that are read,
with a small LRU cache, so a player's PC needs a few hundred MB instead of tens of GB.
"""
import io, bisect
from collections import OrderedDict
import importlib
BF = importlib.import_module('UnityPy.files.BundleFile')
from UnityPy.streams import EndianBinaryReader
from UnityPy.helpers import CompressionHelper

CACHE_BYTES = 4600 * 1048576  # holds one of the ~4 GB Rust texture blocks at a time
NODE_FILTER = None  # callable(node_path) -> bool; None = parse every node


class LazyBlockStream(io.RawIOBase):
    def __init__(self, path, data_start, blocks, decompress):
        self.f = open(path, "rb")
        self.blocks = blocks            # list of (comp_off, comp_size, uncomp_size, flags)
        self.starts = []
        pos = 0
        for b in blocks:
            self.starts.append(pos)
            pos += b[2]
        self.size = pos
        self.pos = 0
        self.decompress = decompress
        self.cache = OrderedDict()

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos

    def _block(self, i):
        b = self.cache.get(i)
        if b is not None:
            self.cache.move_to_end(i)
            return b
        coff, csize, usize, flags = self.blocks[i]
        self.f.seek(coff)
        b = self.decompress(self.f.read(csize), usize, flags, i)
        self.cache[i] = b
        while len(self.cache) > 1 and sum(len(x) for x in self.cache.values()) > CACHE_BYTES:
            self.cache.popitem(last=False)
        return b

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = max(0, min(n, self.size - self.pos))
        out = bytearray()
        while n > 0:
            i = bisect.bisect_right(self.starts, self.pos) - 1
            off = self.pos - self.starts[i]
            coff, csize, usize, flags = self.blocks[i]
            if flags & 0x3F == 0:
                # stored uncompressed (all of Rust's bundles): read straight from the file
                self.f.seek(coff + off)
                chunk = self.f.read(min(n, usize - off))
            else:
                b = self._block(i)
                chunk = b[off:off + n]
            out += chunk
            self.pos += len(chunk)
            n -= len(chunk)
        return bytes(out)

    def readinto(self, buf):
        d = self.read(len(buf))
        buf[:len(d)] = d
        return len(d)


class WindowStream(io.RawIOBase):
    """A sub-range [start, start+size) of another seekable stream."""
    def __init__(self, base, start, size):
        self.base, self.start, self.size, self.pos = base, start, size, 0
    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos
    def read(self, n=-1):
        if n is None or n < 0: n = self.size - self.pos
        n = max(0, min(n, self.size - self.pos))
        self.base.seek(self.start + self.pos)
        d = self.base.read(n)
        self.pos += len(d)
        return d
    def readinto(self, buf):
        d = self.read(len(buf)); buf[:len(d)] = d; return len(d)


_orig_read_fs = BF.BundleFile.read_fs


def _lazy_read_fs(self, reader):
    path = getattr(getattr(reader, "stream", None), "name", None)
    if not isinstance(path, str):
        return _orig_read_fs(self, reader)
    # Mirrors UnityPy's read_fs up to the point where it joins every block in memory.
    size = reader.read_long()
    compressedSize = reader.read_u_int()
    uncompressedSize = reader.read_u_int()
    dataflagsValue = reader.read_u_int()
    self.dataflags = BF.ArchiveFlags(dataflagsValue)
    if self.version >= 7:
        reader.align_stream(16)
        self._uses_block_alignment = True
    start = reader.Position
    if self.dataflags & BF.ArchiveFlags.BlocksInfoAtTheEnd:
        reader.Position = reader.Length - compressedSize
        blocksInfoBytes = reader.read_bytes(compressedSize)
        reader.Position = start
    else:
        blocksInfoBytes = reader.read_bytes(compressedSize)
    blocksInfoBytes = self.decompress_data(blocksInfoBytes, uncompressedSize, self.dataflags)
    bi = EndianBinaryReader(blocksInfoBytes, offset=start)
    bi.read_bytes(16)
    n = bi.read_int()
    raw = [(bi.read_u_int(), bi.read_u_int(), bi.read_u_short()) for _ in range(n)]
    nodes = bi.read_int()
    dirs = [BF.DirectoryInfoFS(bi.read_long(), bi.read_long(), bi.read_u_int(), bi.read_string_to_null())
            for _ in range(nodes)]
    if raw:
        self._block_info_flags = raw[0][2]
    if self.dataflags & BF.ArchiveFlags.BlockInfoNeedPaddingAtStart:
        reader.align_stream(16)
    off = reader.Position + reader.BaseOffset
    blocks = []
    for usize, csize, flags in raw:
        blocks.append((off, csize, usize, flags))
        off += csize
    import sys as _sys
    _sys.stderr.write("lazybundle %s: %d blocks, max %.1f MB, total %.0f MB" % (path.replace(chr(92), "/").split("/")[-1], len(blocks), max(b[2] for b in blocks)/1048576.0, sum(b[2] for b in blocks)/1048576.0) + chr(10))
    stream = LazyBlockStream(path, None, blocks, self.decompress_data)
    return dirs, EndianBinaryReader(stream, offset=0)


def _lazy_read_files(self, reader, files):
    from UnityPy.helpers import ImportHelper
    SF = importlib.import_module("UnityPy.files.SerializedFile")
    stream = getattr(reader, "stream", None)
    if not isinstance(stream, LazyBlockStream):
        return _orig_read_files(self, reader, files)
    for node in files:
        if NODE_FILTER is not None and not NODE_FILTER(node.path):
            continue
        win = WindowStream(stream, node.offset, node.size)
        node_reader = EndianBinaryReader(win, offset=0)
        f = ImportHelper.parse_file(node_reader, self, node.path, is_dependency=self.is_dependency)
        if isinstance(f, (EndianBinaryReader, SF.SerializedFile)) and self.environment:
            self.environment.register_cab(node.path, f)
        f.flags = getattr(node, "flags", 0)
        self.files[node.path] = f


_orig_read_files = BF.BundleFile.read_files


def install():
    BF.BundleFile.read_fs = _lazy_read_fs
    BF.BundleFile.read_files = _lazy_read_files
