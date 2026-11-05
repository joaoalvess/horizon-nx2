from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
os.environ.setdefault('DM_GAME', '010015100B514000')
import shader_split as split


def compute(tag, code_len, ctl_len=0xe0):
    ctl = bytearray(ctl_len); ctl[:4] = split.CTL_MAGIC; ctl[4] = 0xc9; ctl[0x56] = 5
    struct.pack_into('<I', ctl, 0x30, ctl_len); struct.pack_into('<I', ctl, 0x44, code_len)
    ctl[0x20] = tag
    return bytes(ctl), bytes([tag]) * code_len


def ndsr(shaders):
    entries, body, at = [], bytearray(), 0x200
    def put(blob, typ):
        nonlocal at
        entries.append(struct.pack('<II', at, len(blob) << 4 | typ)); body.extend(blob); at += len(blob)
    for i, (ctl, code) in enumerate(shaders):
        put(bytes(0x10), 0xb)
        put(ctl, 6)
        put(code, 7)
        if i: put(bytes(4), 9)
    head = b'NDSR' + struct.pack('<4I', 0x40100, 0x80300, 9, 0x1020c00) + b''.join(entries) + bytes(8)
    return head.ljust(0x200, b'\0') + body


def pack(shaders, weights):
    head = 8 + (8 if weights else 0) + 16 * len(shaders)
    w = bytes(weights)
    rows, body, at = [], bytearray(w), head + len(w)
    for ctl, code in shaders:
        rows.append(struct.pack('<4I', at, len(ctl), len(code), 0)); body += ctl + code; at += len(ctl) + len(code)
    top = struct.pack('<II', len(shaders), 1 if weights else 0) + (struct.pack('<II', head, len(w)) if weights else b'')
    return top + b''.join(rows) + body


class Ndve(unittest.TestCase):
    def test_ndsr_takes_code_from_the_next_entry(self):
        a, b = compute(1, 0x100), compute(2, 0x200)
        found = split.ndsr_shaders(ndsr([a, b]), 'pck')
        self.assertEqual([(st, ctl, code) for _, st, ctl, code in found], [('cs',) + a, ('cs',) + b])

    def test_ndve_reads_its_ndsr_and_network_packs(self):
        sr, n1, n2, n3 = compute(1, 0x100), compute(2, 0x300, 0x400), compute(3, 0x200, 0x300), compute(4, 0x100, 0x200)
        part = ndsr([sr])
        net = pack([n1, n2], 0x40) + pack([n3], 0) + bytes(0x3c) + b'RLA1'
        d = b'NDVE' + struct.pack('<4I', 0xff00005, 0, len(part), len(net)) + bytes(0x14) + part + net
        found = []; split.scan_blob(d, 'movie', found)
        self.assertEqual([(ctl, code) for _, _, ctl, code in found], [sr, n1, n2, n3])
        self.assertEqual({st for _, st, _, _ in found}, {'cs'})
        self.assertEqual(split.ndve_shaders(d[:-1], 'cut'), [])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'Ndve-Nvn2-vid_seq5.dat'; path.write_bytes(d)
            keys = split.scan_file_in((str(path), 'Movie/Ndve/Ndve-Nvn2-vid_seq5.dat'))[1]
        self.assertEqual(set(keys), {split.skey(*s) for s in (sr, n1, n2, n3)})


if __name__ == '__main__': unittest.main()
