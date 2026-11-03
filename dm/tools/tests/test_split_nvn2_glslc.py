"""shader_split: GLSLC outputs of NVN2 (Switch 2; Pokémon Pokopia's main and its RDB's _S2G7000 containers) keep their length at +0x5c and their section headers from +0xa8,
0x98 bytes apart, with an NVN2 control section and Ampere code in each GPU code section (glslc_nvn2). No game files needed."""
import os
import struct
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
_had = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = '040074A01BF12000'   # shader_split loads a profile at import; other tests expect no default game
import shader_split as ss
if _had is None: del os.environ['DM_GAME']
else: os.environ['DM_GAME'] = _had

MAGIC = b'\x91\x68\x86\x19'


def control(code_len, stage_byte=0, length=0xd8):
    c = bytearray(length)
    c[0:8] = ss.CTL_MAGIC + b'\xc9\0\0\0'
    struct.pack_into('<I', c, 0x30, length)
    struct.pack_into('<I', c, 0x44, code_len)
    c[0x56] = stage_byte
    return bytes(c)


def code(sph_type, n=0x100):
    return struct.pack('<I', sph_type << 10 | 0x62) + bytes(range(n - 4))


def output(gpus, reflection=b'reflection data'):
    n = len(gpus) + 1
    head = bytearray(0xa8 + 0x98 * n)
    head[0:4] = MAGIC
    data, at = bytearray(), len(head)
    for i, (ctl, cd) in enumerate(gpus):
        s = 0xa8 + 0x98 * i
        struct.pack_into('<3I', head, s, len(ctl) + len(cd), at + len(data), 0)
        struct.pack_into('<4I', head, s + 0x30, 0, len(ctl), len(cd), len(ctl))
        data += ctl + cd
    struct.pack_into('<3I', head, 0xa8 + 0x98 * len(gpus), len(reflection), at + len(data), 3)
    data += reflection
    struct.pack_into('<I', head, 0x30, 0xc9)
    struct.pack_into('<3I', head, 0x5c, len(head) + len(data), len(head), n)
    return bytes(head + data)


class Nvn2Glslc(unittest.TestCase):
    def test_one_stage_output(self):
        ctl, cd = control(0x100, length=0x108), code(5)
        d = b'pad' + output([(ctl, cd)]) + b'tail'
        self.assertEqual(ss.glslc_shaders(d, 'x', need=False), [('x#GLSLC@0x3', 'ps', ctl, cd)])

    def test_compute_by_control_stage_byte(self):
        ctl, cd = control(0x80, stage_byte=5), bytes(0x80)
        (_, st, _, _), = ss.glslc_shaders(output([(ctl, cd)]), 'x', need=False)
        self.assertEqual(st, 'cs')

    def test_several_stages_pair(self):
        vs, ps = (control(0x100), code(1)), (control(0x100), code(5))
        got = ss.glslc_shaders(output([vs, ps]), 'x', need=False)
        self.assertEqual([(lb, st) for lb, st, _, _ in got], [('x#GLSLC@0x0#var', 'vs'), ('x#GLSLC@0x0#var', 'ps')])

    def test_rejected(self):
        ctl, cd = control(0x100), code(5)
        self.assertEqual(ss.glslc_shaders(output([(control(0xfc), cd)]), 'x', need=False), [])   # control +0x44 does not match the code area
        self.assertEqual(ss.glslc_shaders(output([(ctl, cd)])[:-1], 'x', need=False), [])      # the output runs past the data
        self.assertEqual(ss.glslc_shaders(output([(ctl, cd), (ctl, cd)]), 'x', need=False), [])  # two sections of one stage
        self.assertEqual(ss.glslc_shaders(MAGIC + bytes(0x200), 'x', need=False), [])            # a magic with no output behind it
        bad = bytearray(output([(ctl, cd)])); bad[0xa8 + 0x98 + 0x10] ^= 1
        self.assertEqual(len(ss.glslc_shaders(bytes(bad), 'x', need=False)), 1)                   # the reflection section's contents do not matter


if __name__ == '__main__':
    unittest.main()
