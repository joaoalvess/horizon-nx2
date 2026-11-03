"""shader_split: Koei Tecmo's chunked zlib with chunks larger than 0x10000 (kt_gz), and the LINKDATA pair LD_<name>.BIN / LI_<name>.IDX beside Three Houses' DATA1.bin / DATA0.bin
(linkdata_index, linkdata_jobs, linkdata_shaders). Pokémon Pokopia's LD_C0_R.BIN keeps 336 shader keys in entries of 0x80000 and 0x20000 chunks. No game files needed."""
import os
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_split_nvn2_glslc import code, control, output, ss


def kt_gz(data, cs, plain_last=True):
    n = (len(data) + cs - 1) // cs
    chunks = []
    for i in range(n):
        part = data[i * cs:(i + 1) * cs]
        chunks.append(part if plain_last and i == n - 1 and len(part) < cs else (lambda z: struct.pack('<I', len(z)) + z)(zlib.compress(part)))
    head = struct.pack(f'<III{n}I', cs, n, len(data), *map(len, chunks))
    out = bytearray(head + bytes(-len(head) % 0x80))
    for c in chunks: out += c + bytes(-len(c) % 0x80)
    return bytes(out)


class KtGz(unittest.TestCase):
    def test_chunk_sizes(self):
        data = bytes(range(256)) * 0x900 + b'end'
        for cs in (0x10000, 0x20000, 0x80000):
            self.assertEqual(ss.kt_gz(kt_gz(data, cs)), data)

    def test_not_that_form(self):
        data = bytes(0x30000)
        self.assertIsNone(ss.kt_gz(kt_gz(data, 0x8000)))     # chunks below 0x10000
        bad = bytearray(kt_gz(data, 0x20000)); struct.pack_into('<I', bad, 0, 0x30000)
        self.assertIsNone(ss.kt_gz(bytes(bad)))              # a chunk size that is not a power of two
        bad = bytearray(kt_gz(data, 0x20000)); struct.pack_into('<I', bad, 4, 3)
        self.assertIsNone(ss.kt_gz(bytes(bad)))              # a chunk count that does not match the length


class Linkdata(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(); self.d = Path(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def archive(self, data_name, index_name, entries):
        blob, idx = bytearray(), bytearray()
        for raw, cs in entries:
            stored = kt_gz(raw, cs) if cs else raw
            idx += struct.pack('<QQQQ', len(blob), len(raw), len(stored), 1 if cs else 0)
            blob += stored + bytes(-len(stored) % 0x100)
        (self.d / data_name).write_bytes(blob)
        if index_name: (self.d / index_name).write_bytes(idx)
        return str(self.d / data_name)

    def test_index_names(self):
        self.assertEqual(ss.linkdata_index(self.archive('LD_C0_R.BIN', 'LI_C0_R.IDX', [(b'x', 0)])), str(self.d / 'LI_C0_R.IDX'))
        self.assertEqual(ss.linkdata_index(self.archive('DATA1.bin', 'DATA0.bin', [(b'x', 0)])), str(self.d / 'DATA0.bin'))
        self.assertIsNone(ss.linkdata_index(self.archive('LD_C1_R.BIN', None, [(b'x', 0)])))   # no index beside it
        self.assertIsNone(ss.linkdata_index(self.archive('LD_C2_R.DAT', 'LI_C2_R.IDX', [(b'x', 0)])))

    def test_shaders_in_large_chunk_entries(self):
        ctl, cd = control(0x100, length=0xe0), code(5)
        glslc = output([(ctl, cd)])
        path = self.archive('LD_C0_R.BIN', 'LI_C0_R.IDX', [(b'plain entry', 0), (bytes(0x90000) + glslc, 0x80000), (glslc, 0x20000)])
        jobs = ss.linkdata_jobs(path, 'LD_C0_R.BIN')
        self.assertEqual(sum(b - a for _, _, (a, b) in jobs), 3)
        found = []
        for p, rel, rng in jobs: ss.linkdata_shaders(p, rel, rng, found)
        self.assertEqual([(lb, st, c, k) for lb, st, c, k in found], [('/LD_C0_R.BIN#1#GLSLC@0x90000', 'ps', ctl, cd), ('/LD_C0_R.BIN#2#GLSLC@0x0', 'ps', ctl, cd)])


if __name__ == '__main__':
    unittest.main()
