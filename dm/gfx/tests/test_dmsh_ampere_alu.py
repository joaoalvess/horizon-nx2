#!/usr/bin/env python3
"""Ampere ALU instructions through the offline translator (dmsh_xlate, arch sm86): half-pair operands whose second source sits in the C slot or is an immediate, HFMA2 .H0_NH1,
FSEL signs, LDC .IS and BREV. Pokémon Pokopia's blur stepped its loop by HADD2 R7, R7, 2.0 (form 2) and the translator added R0 instead, a loop that never ended and hung the GPU.
Needs DMSH_TEST_XLATE (the translator) like the other translator tests."""
import json, os, re, struct, subprocess, sys, tempfile, unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
PT = 7
EXIT = (0x000fea0003800000, 0x000000000000794d)   # hi, lo
# SUATOM.ADD.U32 R12, [R3], R12 (test_dmsh_ampere_mem.py): keeps R12 alive
SINK = (0x002ea200001ee000, 0x00000c0c030c7593)
TID_X, TID_Y = 0x21, 0x22
CONTROL = 0x000fe2 << 104   # the scheduling bits of an ordinary instruction (stall 1): the decoder drops one whose control bits are all zero


def bits(*fields):
    v = CONTROL
    for lo, width, value in fields:
        v |= (value & ((1 << width) - 1)) << lo
    return (v >> 64) & (2 ** 64 - 1), v & (2 ** 64 - 1)


def s2r(rd, sr): return bits((0, 12, 0x919), (12, 3, PT), (16, 8, rd), (72, 8, sr))
def half_op(opcode, rd, ra, imm): return bits((0, 12, opcode), (12, 3, PT), (16, 8, rd), (24, 8, ra), (32, 32, imm))   # bits 64..71 left 0: R0


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class Translated(unittest.TestCase):
    def translate(self, insts):
        """→ the MSL, or None when the translator refused the program (its output names why)"""
        with tempfile.TemporaryDirectory(prefix='ampere_alu_') as d:
            work = Path(d); (work / 'k.bin').write_bytes(b''.join(struct.pack('<QQ', lo, hi) for hi, lo in insts + [SINK, EXIT]))
            job = [dict(key='k', stage='cs', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, local=[32, 1, 1], debug=True, nvn2_cs=[0, 0, 3, 0x40, 0])]
            (work / 'jobs.json').write_text(json.dumps(job))
            r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
            self.output = r.stdout + r.stderr
            if not (work / 'k.spv').exists(): return None
            self.res = json.loads((work / 'k.res.json').read_text())
            sys.path.insert(0, str(TOOLS)); import dmsh_geometry
            dmsh_geometry.flatten_sets(work / 'k.spv')
            r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', '--msl-argument-buffers', '--msl-texture-buffer-native',
                                str(work / 'k.spv')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout

    def translated(self, insts):
        msl = self.translate(insts)
        self.assertIsNotNone(msl, self.output)
        return msl


class HalfPairs(Translated):
    def test_hadd2_immediate_in_the_c_slot(self):   # HADD2 R12, R12, 2.0 2.0 (0x430): the immediate is the second source, not R0 (bits 64..71)
        msl = self.translated([s2r(0, TID_X), s2r(12, TID_Y), half_op(0x430, 12, 12, 0x40004000)])
        self.assertIn('gl_LocalInvocationID.y', msl)
        self.assertNotIn('gl_LocalInvocationID.x', msl)
        self.assertRegex(msl, r'\b2\.0\b')

    def test_negative_immediate_keeps_its_sign(self):   # HMUL2 R12, R12, -1.4424 -1.4424 (0x832, Pokopia's exp2 of a decay): bits 62 / 63 are the immediate's, not abs / neg
        msl = self.translated([s2r(12, TID_X), half_op(0x832, 12, 12, 0xbdc5bdc5)])
        self.assertIn('-1.4423828125', msl)

    def test_positive_and_negative_lanes(self):   # 2.0 2.0 times (low 0.5, high -0.5), folded: the low lane is not negated with the high half's sign bit
        mov = bits((0, 12, 0x802), (12, 3, PT), (16, 8, 12), (32, 32, 0x40004000), (72, 4, 0xf))
        self.assertIn('half2(float2(1.0, -1.0))', self.translated([mov, half_op(0x832, 12, 12, 0xb8003800)]))


class HalfSwapNegate(Translated):
    """HFMA2 .H0_NH1 (bit 86): B's lanes swap and the old high half, now low, is negated; Pokémon Pokopia's sun-shadow mask (7,686 shaders) reads it so"""
    B = bits((0, 12, 0x802), (12, 3, PT), (16, 8, 12), (32, 32, 0x40003c00), (72, 4, 0xf))   # MOV R12, (low 1.0, high 2.0)
    A = bits((0, 12, 0x802), (12, 3, PT), (16, 8, 13), (32, 32, 0x3c003c00), (72, 4, 0xf))   # MOV R13, (1.0, 1.0)

    def hfma2(self, swizzle=0):   # HFMA2 R12, R13, R12.H0_NH1, RZ (form 1)
        return bits((0, 12, 0x231), (12, 3, PT), (16, 8, 12), (24, 8, 13), (32, 8, 12), (60, 2, swizzle), (64, 8, 0xff), (86, 1, 1))

    def test_lanes_swap_and_low_negated(self):   # (1, 1) * (-2, 1) + 0, folded
        self.assertRegex(self.translated([self.B, self.A, self.hfma2()]), r'float (_\d+) = fma\(1\.0, -2\.0, 0\.0\);\s*float (_\d+) = fma\(1\.0, 1\.0, 0\.0\);\s*uint _\d+ = as_type<uint>\(half2\(float2\(\1, \2\)\)\)')


class FselSigns(Translated):
    def test_negated_b_selected(self):   # FSEL R12, R0, -R1, !PT: B's neg (63) is kept, as the x-or-minus-x picks of Pokopia's lighting need
        movs = [bits((0, 12, 0x802), (12, 3, PT), (16, 8, r), (32, 32, v), (72, 4, 0xf)) for r, v in ((0, 0x3f800000), (1, 0x40400000))]
        fsel = bits((0, 12, 0x208), (12, 3, PT), (16, 8, 12), (24, 8, 0), (32, 8, 1), (63, 1, 1), (87, 3, PT), (90, 1, 1))
        self.assertIn('3225419776u', self.translated(movs + [fsel]))   # -3.0's bits


class LdcSegmented(Translated):
    """LDC .IS (address mode 2): the bank plus Ra's high half, chosen at run time among the banks the program reads and c1, its own constants; Pokémon Pokopia's vertex shader
    cc679c7b4d3e703c reads a table in c1 so. Before, the translator was told no bank was in use and the load read 0"""
    def ldc(self, mode):   # LDC R12, c[0x0][R0] with address mode 78..80, 32 bits
        return bits((0, 12, 0xb82), (12, 3, PT), (16, 8, 12), (24, 8, 0), (73, 3, 4), (78, 2, mode))

    def test_bank_from_the_high_half(self):
        self.translated([s2r(0, TID_X), self.ldc(2)])
        self.assertIn(1, [b['slot'] for b in self.res['cbufs']])
        self.assertIn('constant bank chosen at run time among c1', self.res['notes'])

    def test_il_refused(self):
        self.assertIsNone(self.translate([s2r(0, TID_X), self.ldc(1)]))
        self.assertIn('address mode 1', self.output)


class Brev(Translated):
    def test_reverse_bits(self):   # BREV R12, R0 (0x301, the source in the B slot)
        msl = self.translated([s2r(0, TID_X), bits((0, 12, 0x301), (12, 3, PT), (16, 8, 12), (24, 8, 0), (32, 8, 0))])
        self.assertIn('reverse_bits', msl)
        self.assertIn('gl_LocalInvocationID.x', msl)


def prmt_reference(a, c, sel):
    src, res = c << 32 | a, 0
    for i in range(4):
        s = (sel >> (4 * i)) & 0xf
        b = (src >> (8 * (s & 7))) & 0xff
        if s & 8: b = 0xff if b & 0x80 else 0
        res |= b << (8 * i)
    return res


class PrmtConstantSelector(Translated):
    A, C = 0x8a7b6c5d, 0xf1e2d3c4
    SELECTORS = [0x5410, 0x7632, 0x3210, 0x7654, 0x1032, 0x0123, 0x4321, 0x6543, 0x3276, 0x5476, 0x1054, 0x0000, 0x7777, 0x8880, 0x9810, 0xb3a2, 0x32ba]

    def prmt(self, sel, ra=0, rc=1): return bits((0, 12, 0x816), (12, 3, PT), (16, 8, 12), (24, 8, ra), (32, 32, sel), (64, 8, rc))
    def mov(self, rd, v): return bits((0, 12, 0x802), (12, 3, PT), (16, 8, rd), (32, 32, v), (72, 4, 0xf))

    def test_folded_bytes_match_the_reference(self):
        import random
        rng = random.Random(5)
        for sel in self.SELECTORS + [rng.randrange(0x10000) for _ in range(30)]:
            with self.subTest(sel=hex(sel)):
                want = prmt_reference(self.A, self.C, sel)
                self.assertRegex(self.translated([self.mov(0, self.A), self.mov(1, self.C), self.prmt(sel)]), rf'\b{want}u?\b')

    def test_halfword_selectors_take_no_byte_extracts(self):
        for sel in (0x5410, 0x7632, 0x3210):
            with self.subTest(sel=hex(sel)):
                self.assertNotIn('extract_bits', self.translated([s2r(0, TID_X), s2r(1, TID_Y), self.prmt(sel)]))


class HalfwordProvenance(Translated):
    """A half pair rebuilt from halves of other pairs by PRMT's halfword selectors (Pokemon Pokopia's 8743dd823fc8e863 does so 110 times): an unpack of it reads the half from the pair that
    holds it. The same bits, rounded to f16 as they were, not the float that pair was packed from; the masks, shifts and ors go"""
    LANES = {0x5410: (('a', 'x'), ('c', 'x')), 0x7632: (('a', 'y'), ('c', 'y')), 0x1054: (('c', 'x'), ('a', 'x')), 0x3276: (('c', 'y'), ('a', 'y'))}

    def plus_one(self, rs, *insts):   # R4, R5 = the x and y invocation IDs' half pairs doubled (a, c); then the instructions; R12 = Rs + 1.0. → the MSL and the words of a and c
        msl = self.translated([s2r(0, TID_X), s2r(1, TID_Y), half_op(0x832, 4, 0, 0x40004000), half_op(0x832, 5, 1, 0x40004000), *insts, half_op(0x430, 12, rs, 0x3c003c00)])
        return msl, dict(zip('ac', re.findall(r'uint (_\d+) = as_type<uint>\(half2\(float2\(', msl)))

    def prmt(self, rd, ra, sel, rc): return bits((0, 12, 0x816), (12, 3, PT), (16, 8, rd), (24, 8, ra), (32, 32, sel), (64, 8, rc))

    def assert_lanes(self, msl, words, lanes):
        self.assertRegex(msl, ''.join(rf'float _\d+ = float2\(as_type<half2>\({words[w]}\)\)\.{h};\s*' for w, h in lanes))
        self.assertNotRegex(msl, r'& 65535|<< 16|>> uint\(16\)')

    def test_unpacks_read_the_packed_halves(self):
        for sel, lanes in self.LANES.items():
            with self.subTest(sel=hex(sel)):
                self.assert_lanes(*self.plus_one(6, self.prmt(6, 4, sel, 5)), lanes)

    def test_a_constant_half(self):   # R6 = (R4's low half, the low half of the constant (2.0, 0)): the high lane is 2.0 + 1.0
        msl, words = self.plus_one(6, bits((0, 12, 0x802), (12, 3, PT), (16, 8, 5), (32, 32, 0x00004000), (72, 4, 0xf)), self.prmt(6, 4, 0x5410, 5))
        self.assertRegex(msl, rf'float (_\d+) = float2\(as_type<half2>\({words["a"]}\)\)\.x;\s*float (_\d+) = spvFAdd\(\1, 1\.0\);\s*uint _\d+ = as_type<uint>\(half2\(float2\(\2, 3\.0\)\)\);')

    def test_a_zero_half(self):   # R6 = PRMT R4, 0x5410, RZ: the high half is 0, so the high lane is 0.0 + 1.0
        msl, words = self.plus_one(6, self.prmt(6, 4, 0x5410, 0xff))
        self.assertRegex(msl, rf'float (_\d+) = float2\(as_type<half2>\({words["a"]}\)\)\.x;\s*float (_\d+) = spvFAdd\(\1, 1\.0\);\s*uint _\d+ = as_type<uint>\(half2\(float2\(\2, 1\.0\)\)\);')

    def test_a_shift_right_then_left(self):   # R6 = (R4 >> 16) | (R5 & 0xffff0000), R7 = (R6 << 16) | (R5 & 0xffff): R7's high half is R4's
        self.assert_lanes(*self.plus_one(7, self.prmt(6, 4, 0x7632, 5), self.prmt(7, 6, 0x1054, 5)), (('c', 'x'), ('a', 'y')))

    def test_an_arithmetic_shift_is_not_followed(self):   # SHF.R.S32.HI R6, RZ, 16, R4: the high half is R4's sign, not 0
        msl, words = self.plus_one(6, bits((0, 12, 0x819), (12, 3, PT), (16, 8, 6), (24, 8, 0xff), (32, 32, 16), (64, 8, 4), (73, 2, 2), (76, 1, 1), (80, 1, 1)))
        shifted = re.search(rf'int (_\d+) = int\({words["a"]}\) >> 16;', msl)
        self.assertTrue(shifted, msl)
        self.assertRegex(msl, rf'float _\d+ = float2\(as_type<half2>\(uint\({shifted.group(1)}\)\)\)\.x;\s*float _\d+ = float2\(as_type<half2>\(uint\({shifted.group(1)}\)\)\)\.y;')
