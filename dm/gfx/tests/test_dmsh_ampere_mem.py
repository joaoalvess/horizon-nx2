#!/usr/bin/env python3
"""Ampere instructions through the offline translator (dmsh_xlate, arch sm86): SUATOM (0x593), the image atomic Donkey Kong Bananza's agl technique compute shaders (agl_technique_pfx) take an
append counter with; shared memory's scaled address, IMAD.HI and ATOMS.CAS; and the instructions tested on the atomic's result below. Needs DMSH_TEST_XLATE (the translator) like the other translator tests."""
import json, os, re, struct, subprocess, sys, tempfile, unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
EXIT = (0x000fea0003800000, 0x000000000000794d)   # hi, lo: EXIT
# SUATOM.ADD.U32 R12, [R3], R12 on the 1D image whose handle is word 12 of c0 (AMapC0: image slot 1), as the game encodes it but unpredicated (PT)
SUATOM = (0x002ea200001ee000, 0x00000c0c030c7593)


def inst(hi, lo): return struct.pack('<QQ', lo, hi)


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class Translated(unittest.TestCase):
    def translate(self, code, **extra):
        with tempfile.TemporaryDirectory(prefix='ampere_mem_') as d:
            work = Path(d); (work / 'k.bin').write_bytes(code)
            # c0 layout (QueryAmpereComputeC0Layout): no uniform or storage buffers, 3 texture handles from 0x10, image handles from 0x28 (word 12 = image slot 1), 0x40 bytes
            job = [dict(dict(key='k', stage='cs', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, local=[32, 1, 1], debug=True, nvn2_cs=[0, 0, 3, 0x40, 0]), **extra)]
            (work / 'jobs.json').write_text(json.dumps(job))
            r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue((work / 'k.spv').exists(), r.stdout + r.stderr)
            sys.path.insert(0, str(TOOLS)); import dmsh_geometry
            dmsh_geometry.flatten_sets(work / 'k.spv')
            r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', '--msl-argument-buffers', '--msl-texture-buffer-native',
                                str(work / 'k.spv')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout


class Suatom(Translated):
    def test_add_u32_on_a_1d_image(self):
        msl = self.translate(inst(*SUATOM) + inst(*EXIT))
        self.assertIn('atomic_fetch_add', msl)   # native (the build's options) or through spirv-cross's buffer alias (these defaults)
        self.assertIn('cp_i_tcb_4A_r32ui', msl)   # image slot 1 (c2 0x128), a 32-bit unsigned image

    def test_result_kept(self):   # the old value is the shader's (it shuffles it to the warp): the atomic's result is used, not discarded
        msl = self.translate(inst(*SUATOM) + inst(*EXIT))
        self.assertRegex(msl, r'uint \w+ = [^;]*atomic_fetch_add')


class MufuF16(Translated):
    """MUFU.F16 (Splatoon Raiders' upscaler network): the source is the half bits 60..61 select (bit 62 its abs, as in every B slot), the result the low half"""
    LOG2_HIGH = (0x000fe60000000e00, 0x5000000c000c7308)   # MUFU.F16.LOG2 R12, |R12.H1|: the game's encoding (c1b8edc09e3313b1 +0x5970) on the register the atomic reads
    LOG2_LOW = (0x0002a20000000e00, 0x4000000c000c7308)    # MUFU.F16.LOG2 R12, |R12.H0| (+0x59a0)

    def msl(self, mufu):
        return self.translate(inst(*mufu) + inst(*SUATOM) + inst(*EXIT))

    def test_high_half(self):
        msl = self.msl(self.LOG2_HIGH)
        self.assertRegex(msl, r'as_type<half2>\(.*\)\)\.y;')
        self.assertIn('log2(abs', re.sub(r'float _\d+ = abs\((_\d+)\);\s*float _\d+ = log2\(_\d+\);', 'log2(abs', msl))

    def test_result_is_the_low_half(self):   # the bits of a half pair, its high half zero: not the float's own bits
        self.assertRegex(self.msl(self.LOG2_HIGH), r'as_type<uint>\(half2\(float2\(\w+, 0\.0\)\)\)')

    def test_low_half_translates_apart(self):   # R12 is a constant here, so the low half folds away; what is left must not read the high one
        self.assertNotRegex(self.msl(self.LOG2_LOW), r'as_type<half2>\(.*\)\)\.y;')


def mov(rd, value):   # MOV Rd, imm32: values the tests can see in the output
    return inst(0x000fc60000000f00, value << 32 | rd << 16 | 0x7802)


def sts(offset, rb, ra=0xff):   # STS.U32 [Ra + offset], Rb (RZ by default): keeps its result
    return inst(0x000fe80000000800, offset << 40 | rb << 32 | ra << 24 | 0x7388)


def lds(rd, ra, offset):   # LDS.U32 Rd, [Ra + offset]
    return inst(0x000fe20000000800, offset << 40 | ra << 24 | rd << 16 | 0x7984)


TID_X, TID_Y, TID_Z = 0x21, 0x22, 0x23


def s2r(rd, sr):   # S2R Rd, SR
    return inst(0x000fe20000000000 | sr << 8, rd << 16 | 0x7919)


def imad(rd, ra, imm, rc):   # IMAD Rd, Ra, imm32, Rc
    return inst(0x000fe200078e0000 | rc, imm << 32 | ra << 24 | rd << 16 | 0x7824)


class Sured(Translated):
    """SURED.ADD.U32 [R4], R0 (0x59f) on a 2D image, Mario Kart World's ab77eaee44cfef88: SUATOM's layout with no result"""
    FORM = (0x000fe2000010e000, 0x60000c000400759f)

    def test_adds_at_the_coordinates(self):
        msl = self.translate(inst(*self.FORM) + inst(*EXIT))
        self.assertIn('atomic_fetch_add', msl)
        self.assertIn('texture2d', msl)

    def test_another_form_is_refused(self):
        with self.assertRaises(AssertionError) as e: self.translate(inst(0x000fe200001ee000, self.FORM[1]) + inst(*EXIT))
        self.assertIn('SURED form', str(e.exception))

    def test_or_from_the_operation_field(self):   # SURED.OR.U32, word 2 0x0310e000 (The Legend of Zelda: Ocarina of Time's d17eefaff4f0bc23 +0x5040)
        msl = self.translate(inst(0x000fe2000310e000, self.FORM[1]) + inst(*EXIT))
        self.assertIn('atomic_fetch_or', msl)
        self.assertNotIn('atomic_fetch_add', msl)


class StageMemory(Translated):
    """A task or mesh shader's stage memory in shared memory, on the game's encodings (job stage_memory: workgroup 0, input 0x10, outputs 0x120, primitives 0x400)"""
    MEMORY = dict(stage_memory=[0, 0x10, 0x120, 0x400], shared=0x800)
    # The game's ISBERDs set a write barrier, which their readers wait on; these set none, so the store after one reads its result
    WORKGROUP = (0x000fe20000007800, 0x00000000ff007923)   # ISBERD R0, mode 0x78 (b6d76b6fc9dc926f +0)
    INPUT = (0x000fe20000003800, 0x00002000ff137923)       # ISBERD R19, [RZ + 0x20], mode 0x38 (ddc034e8e009ebfc, its base register made RZ)
    PAYLOAD = (0x0041e8000000b800, 0x0000100201007927)     # 0x927 [R1 + 0x10], R2, mode 0xb8 (a task's record)
    KEEP_R0 = (0x0041e8000000b800, 0x00001000ff007927)     # the same with [RZ + 0x10], R0: so what ISBERD read is used
    KEEP_R19 = (0x0041e8000000b800, 0x00001013ff007927)    # with R19
    ATTRIBUTE = (0x0001e2000000f800, 0x0000800307007927)   # 0x927 [R7 + 0x80], R3, mode 0xf8 (a vertex's y, b6d76b6fc9dc926f +0x3c0 on another base register)
    COUNT_ZERO = (0x000fe20000008800, 0x000003ffff007927)  # 0x927 [RZ + 3], RZ, mode 0x88: every thread clears the count first
    COUNT = (0x0001e20000008800, 0x00000307ff007927)       # 0x927 [RZ + 3], R7, mode 0x88: the thread with the count
    INDEX = (0x0001e20000008000, 0x0000040605057927)       # 0x927 [R5 + 4], R6, mode 0x80: an index byte

    def msl(self, *code):
        return self.translate(b''.join(inst(*c) for c in code) + inst(*EXIT), **self.MEMORY)

    def test_workgroup_number_reads_word_0(self):
        self.assertRegex(self.msl(self.WORKGROUP, self.KEEP_R0), r'as_type<float>\(_\d+\[0\]\)')

    def test_input_is_at_its_offset(self):   # 0x10 + 0x20
        self.assertRegex(self.msl(self.INPUT, self.KEEP_R19), r'as_type<float>\(_\d+\[12\]\)')

    def test_own_output_is_read_where_its_store_goes(self):   # ISBERD R19, [RZ + 0x10], mode 0xb8 (The Legend of Zelda: Ocarina of Time's task shader 5d3a096025e375a1): 0x120 + 0x10
        self.assertRegex(self.msl((0x000fe2000000b800, 0x00001000ff137923), self.KEEP_R19), r'as_type<float>\(_\d+\[76\]\)')

    def test_word_store_goes_to_the_outputs(self):   # 0x120 + 0x80
        self.assertIn('0 + 416', self.msl(self.ATTRIBUTE))

    def test_the_zero_count_is_left_out(self):   # threads are not in step on Metal: it could land after the real count, and the stage memory starts at zero
        without = self.msl(self.COUNT)
        with_zero = self.msl(self.COUNT_ZERO, self.COUNT)
        self.assertEqual(without.count('atomic_compare_exchange'), with_zero.count('atomic_compare_exchange'))

    def test_a_byte_goes_through_its_word_atomically(self):   # neighbouring threads write neighbouring bytes
        self.assertIn('atomic_compare_exchange', self.msl(self.INDEX))

    def test_outside_a_task_or_mesh_shader_it_is_refused(self):
        with self.assertRaises(AssertionError) as e: self.translate(inst(*self.PAYLOAD) + inst(*EXIT))
        self.assertIn('outside a task or mesh shader', str(e.exception))


class Shared(Translated):
    """Fire Emblem Fortune's Weave's Lighting compute shaders: the exposure histogram and its 64-bit average, in the game's own encodings"""
    STS_SCALED_4 = 0x000fe80000004800, 0x0000000302027388   # STS.U32 [R2 * 4], R3 (6d0f6db3f0d396a3 +0x80 with a value): R2 counts words. Read unscaled, bin b came back at about 4b
    STS_SCALED_8 = 0x000fe80000008a00, 0x0000000302027388   # STS.U64 [R2 * 8], R3:R4 (d5bc99ffd183fa20 +0xa0)
    STS_BYTES = 0x000fe80000000800, 0x0000000302027388      # STS.U32 [R2], R3: a byte address
    IMAD_HI = 0x000fc80007820008, 0x0000000b07087227        # IMAD.HI R8, R7, R11, {R9:R8} (08faccfa2eaa7e01 +0xa80)
    ATOMS_CAS = 0x000e640001800001, 0x00000400ff01738d      # ATOMS.CAS R1, [RZ + 4], R0, R1 (f4aa178bc67c9793 +0x200)

    def msl(self, *code):
        msl = self.translate(b''.join(code) + inst(*EXIT), shared=0x400)
        return msl[msl.index('kernel void'):]

    def test_a_32_bit_access_scales_its_register_by_4(self):   # Element 3, not byte 3 (which is element 0)
        self.assertIn('[3] = 77u', self.msl(mov(2, 3), mov(3, 77), inst(*self.STS_SCALED_4)))

    def test_a_64_bit_access_scales_its_register_by_8(self):   # Element 3 of 8 bytes, word 6
        msl = self.msl(mov(2, 3), mov(3, 77), mov(4, 88), inst(*self.STS_SCALED_8))
        self.assertIn('[6] = 77u', msl)
        self.assertIn('[7] = 88u', msl)

    def test_no_scale_keeps_the_byte_address(self):   # Byte 12 is word 3
        self.assertIn('[3] = 77u', self.msl(mov(2, 12), mov(3, 77), inst(*self.STS_BYTES)))

    def test_imad_hi_adds_the_pair_to_the_whole_product(self):   # Without the upper word and the low word's carry, the shader's 64-bit division gave 893011 for 218
        # 0xffffffff * 1 + {4000:1}: the low word carries, so the result is the product's high word + 4000 + 1 (these constants fold down to that sum)
        msl = self.msl(mov(7, 0xffffffff), mov(11, 1), mov(8, 1), mov(9, 4000), inst(*self.IMAD_HI), sts(0x20, 8))
        self.assertIn('._m1', msl)
        self.assertRegex(msl, r'\+ 4000\b')
        self.assertRegex(msl, r'\+ 1\b')

    # 08faccfa2eaa7e01: ISETP.GE P0, R2, 0x20 sets the carry, then IMAD.X adds it. Dropped, the shader's 64-bit division gave 2 for 340 / 1
    ISETP_P0 = 0x000fe20003f06070, 0x000000200200780c
    IMAD_X = 0x000fe400000e0605, 0x000000ffff057224       # IMAD.X R5, RZ, RZ, R5 + P0 (+0xc10)
    IMAD_X_NEG = 0x000fe400000e0e07, 0x000000ffff067224   # IMAD.X R6, RZ, RZ, -R7 + P0 (+0xb20): with .X a negated addend is its bitwise not

    def test_imad_x_adds_its_carry(self):
        self.assertIn('[8] = 101u', self.msl(mov(2, 0x40), mov(5, 100), inst(*self.ISETP_P0), inst(*self.IMAD_X), sts(0x20, 5)))

    def test_imad_x_without_the_carry_adds_nothing(self):
        self.assertIn('[8] = 100u', self.msl(mov(2, 1), mov(5, 100), inst(*self.ISETP_P0), inst(*self.IMAD_X), sts(0x20, 5)))

    def test_imad_x_negates_by_bitwise_not(self):   # ~100 + 1 is -100; a two's complement negation would give -99
        self.assertIn('[8] = 4294967196u', self.msl(mov(2, 0x40), mov(7, 100), inst(*self.ISETP_P0), inst(*self.IMAD_X_NEG), sts(0x20, 6)))

    def test_atoms_cas_takes_its_expected_value_from_rb_and_its_new_value_from_rc(self):
        msl = self.msl(mov(0, 5), mov(1, 9), inst(*self.ATOMS_CAS), sts(0x20, 1))
        self.assertIn('atomic_compare_exchange', msl)
        self.assertRegex(msl, r'= 5u;')
        self.assertRegex(msl, r', 9u,')

    LDS_P0_BARRIER_0 = 0x000e220000000800, 0x00001000ff050984   # @P0 LDS.U32 R5, [RZ + 0x10], write barrier 0
    MOV_NOT_P0 = 0x000fc60000000f00, 0x0000000700058802         # @!P0 MOV R5, 7
    STS_AFTER_0 = 0x001fe80000000800, 0x0000200005ff7388        # STS.U32 [RZ + 0x20], R5, waiting on barrier 0

    def test_a_false_guard_keeps_what_was_written_before_the_wait(self):   # the load's deferred write lands only where its guard held: R5 is 7 when P0 is false (R2 = 1)
        msl = self.msl(mov(2, 1), mov(5, 3), inst(*self.ISETP_P0), inst(*self.LDS_P0_BARRIER_0), inst(*self.MOV_NOT_P0), inst(*self.STS_AFTER_0))
        self.assertRegex(msl, r'_\d+ = 7;')

    # 3,312 of Pokemon Pokopia's shared accesses have stride 3, on 4, 8 and 16 bytes alike (cs_rdb 990's STS.U32 [R2 * 16]): the field is a scale, not the access size
    STS_SCALED_16 = 0x0001e4000000c800, 0x0000000302027388

    def test_stride_3_scales_its_register_by_16(self):   # Element 3 of 16 bytes, word 12
        self.assertIn('[12] = 77u', self.msl(mov(2, 3), mov(3, 77), inst(*self.STS_SCALED_16)))


def f32(v): return struct.unpack('<I', struct.pack('<f', v))[0]


class OcarinaOfTime(Translated):
    """The Legend of Zelda: Ocarina of Time's compute encodings: F2IP.U8.F32 (agl_common's colour encoders), ATOMG.CAS (FoliageShader), HMMA.16816.F16 (the movie upscaler)"""
    F2IP = (0x000fe200000004ff, 0x0000000201037243)        # F2IP.U8.F32 R3, R1, R2, RZ
    ATOMG_CAS = (0x000ea400001ee109, 0x00000008020073a9)   # ATOMG.CAS R0, [R2.64], R8, R9 (c144d8f734fbe228 +0x8830)
    HMMA = (0x000fe20000000810, 0x000000181c10723c)        # HMMA.16816.F16 R16, R28, R24, R16 (4f41ccf24f163e0d +0x15b0, no write barrier)
    WAIT_STS = (0x03ffe80000000800, 0x0000200000ff7388)    # STS.U32 [RZ + 0x20], R0 after every barrier

    def msl(self, *code):
        msl = self.translate(b''.join(code) + inst(*EXIT), shared=0x400)
        return msl[msl.index('kernel void'):]

    def test_f2ip_packs_a_above_b(self):   # 300 saturates to 255 in bits 8..15, 17.5 rounds to the even 18 in bits 0..7
        msl = self.msl(mov(1, f32(300.0)), mov(2, f32(17.5)), inst(*self.F2IP), sts(0x20, 3))
        self.assertRegex(msl, r'rint\(300\.0\)[\s\S]*max\([\s\S]*min\([\s\S]*<< 8[\s\S]*rint\(17\.5\)')

    def test_f2ip_of_another_form_is_refused(self):
        with self.assertRaises(AssertionError) as e: self.msl(inst(0x000fe200000005ff, self.F2IP[1]), sts(0x20, 3))
        self.assertIn('F2IP form', str(e.exception))

    def test_atomg_cas_returns_the_old_value(self):
        msl = self.msl(mov(2, 0x1000), mov(3, 0), mov(8, 0), mov(9, 7), inst(*self.ATOMG_CAS), inst(*self.WAIT_STS))
        self.assertIn('atomic_compare_exchange', self.translate(mov(2, 0x1000) + mov(3, 0) + mov(8, 0) + mov(9, 7) + inst(*self.ATOMG_CAS) + inst(*self.WAIT_STS) + inst(*EXIT), shared=0x400))
        self.assertNotRegex(msl, r'\? 1u? : 0u?')

    def test_hmma_whose_second_result_is_overwritten_keeps_the_one_before(self):   # the second HMMA's C is the first's result; its d1 (R17) is written again unread, as at 4f41ccf24f163e0d +0x16c0
        loads = [lds(r, 0xff, 4 * k) for k, r in enumerate((28, 29, 30, 31, 24, 25, 16, 17))]
        msl = self.msl(*loads, inst(*self.HMMA), inst(*self.HMMA), sts(0x40, 16), mov(17, 5), sts(0x44, 17))
        self.assertEqual(re.findall(r'dmsh_hmma16816_f16\w*\(', msl), ['dmsh_hmma16816_f16_768(', 'dmsh_hmma16816_f16_704('])

    def ldsm(self, rd, offset, matrices, transposed):   # LDSM.16.M88 / .MT88 Rd, [RZ + offset], 1 << matrices matrices
        return inst(0x000fe20000000000 | matrices << 8 | transposed << 14, offset << 40 | 0xff << 24 | rd << 16 | 0x783b)

    def hmma(self, rd, ra, rb, rc):   # HMMA.16816.F16 Rd, Ra, Rb, Rc
        return inst(0x000fe20000000800 | rc, rb << 32 | ra << 24 | rd << 16 | 0x723c)

    def helpers(self, *code):
        return re.findall(r'dmsh_hmma16816_f16\w*\(', self.msl(*code))

    def test_a_chain_keeps_its_matrices_in_apples_layout(self):   # LDSM A and MT88 B fragments, C = 0, then D only as the next C: every word but the stored D (layouts 255)
        code = self.ldsm(4, 0, 2, 0), self.ldsm(8, 0x100, 2, 1), self.hmma(16, 4, 8, 0xff), self.hmma(16, 4, 10, 16), sts(0x40, 16), sts(0x44, 17)
        self.assertEqual(self.helpers(*code), ['dmsh_hmma16816_f16_1023(', 'dmsh_hmma16816_f16_255('])

    def test_a_fragment_read_elsewhere_keeps_nvidias_layout(self):   # R4 (A0) also stored: A0 alone stays in NVIDIA's layout; the stored D too
        code = self.ldsm(4, 0, 2, 0), self.ldsm(8, 0x100, 1, 1), self.hmma(16, 4, 8, 0xff), sts(0x40, 4), sts(0x48, 16), sts(0x4c, 17)
        self.assertEqual(self.helpers(*code), ['dmsh_hmma16816_f16_254('])

    def test_a_fragment_in_two_kinds_of_slot_keeps_nvidias_layout(self):   # R4, R5 are A0, A1 and B0, B1 of the same HMMA
        code = self.ldsm(4, 0, 2, 0), self.hmma(16, 4, 4, 0xff), sts(0x48, 16), sts(0x4c, 17)
        self.assertEqual(self.helpers(*code), ['dmsh_hmma16816_f16_204('])

    def test_apples_layout_of_a_non_transposed_b_reads_columns(self):   # B from LDSM.M88 and A from .MT88: both gathered as two halves a matrix
        code = self.ldsm(4, 0, 2, 1), self.ldsm(8, 0x100, 1, 0), self.hmma(16, 4, 8, 0xff), sts(0x48, 16), sts(0x4c, 17)
        msl = self.msl(*code)
        self.assertEqual(re.findall(r'dmsh_hmma16816_f16\w*\(', msl), ['dmsh_hmma16816_f16_255('])
        self.assertEqual(len(re.findall(r'extract_bits\(', msl)), 12)


class Pokopia(Translated):
    """Pokemon Pokopia's encodings, on the register the atomic reads: F2FP.MERGE_C (22,886 shaders), F2I from a half (1,067), MEMBAR with ERRBAR (144)"""
    MERGE_FIRST = (0x000fe200000040ff, 0x00c00600ff0c7a3e)   # F2FP.MERGE_C R12, RZ, c[3][word 6], RZ
    MERGE_SECOND = (0x000fe4000000400c, 0x00c00500ff0c7a3e)   # F2FP.MERGE_C R12, RZ, c[3][word 5], R12
    F2I_LOW = (0x000fe2000010f100, 0x0000000c000c7305)   # F2I.S32.F16.TRUNC R12, R12.H0
    F2I_HIGH = (0x000fe2000010f100, 0x1000000c000c7305)   # F2I.S32.F16.TRUNC R12, R12.H1
    # TLD.1D.LZ R12, R12, texture slot 0 (c0 word 4): 80,220 shaders, KTGL's light and decal lists in texture buffers. The game's words set a write barrier its next instructions wait on;
    # this one sets none, so the atomic sees its result
    TLD_1D = (0x000fe200009e01ff, 0x100004ff0c0c7b66)
    ATOMS_ADD = (0x004e680000000000, 0x0007fc0cff0c738c)   # ATOMS.ADD.U32 R12, [RZ + 0x7fc], R12, under PT
    MEMBAR = (0x000fec0000005000, 0x0000000000007992)
    ERRBAR = (0x000fc00000000000, 0x00000000000079ab)

    def msl(self, *code):
        return self.translate(b''.join(inst(*c) for c in code) + inst(*SUATOM) + inst(*EXIT))

    def test_merge_shifts_c_into_the_high_half(self):   # word 6, converted first, ends in the high half; word 5 in the low one
        msl = self.msl(self.MERGE_FIRST, self.MERGE_SECOND)
        high = re.search(r'uint (_\d+) = as_type<uint>\(half2\(float2\(\(\*spvDescriptorSet0\.cp_c3\)\._m0\[1\]\.z, 0\.0\)\)\);', msl)
        low = re.search(r'uint (_\d+) = as_type<uint>\(half2\(float2\(\(\*spvDescriptorSet0\.cp_c3\)\._m0\[1\]\.y, 0\.0\)\)\);', msl)
        self.assertTrue(high and low, msl)
        shifted = re.search(rf'int (_\d+) = int\({high.group(1)}\) << 16;', msl)
        self.assertTrue(shifted, msl)
        self.assertRegex(msl, rf'{shifted.group(1)} \| int\({low.group(1)}\)')

    def test_merge_with_rz_in_c_is_the_low_half_alone(self):
        msl = self.msl(self.MERGE_FIRST)
        self.assertRegex(msl, r'as_type<uint>\(half2\(float2\(\(\*spvDescriptorSet0\.cp_c3\)\._m0\[1\]\.z, 0\.0\)\)\)')
        self.assertNotIn('<< 16', msl)

    def test_f2i_reads_the_selected_half(self):   # the merge left its float in the low half and zero in the high one; the translator folds the pack and unpack
        self.assertIn('trunc(0.0)', self.msl(self.MERGE_FIRST, self.F2I_HIGH))
        self.assertRegex(self.msl(self.MERGE_FIRST, self.F2I_LOW), r'trunc\(\(\*spvDescriptorSet0\.cp_c3\)\._m0\[1\]\.z\)')

    def test_1d_fetch_wraps_into_rows(self):   # a texture buffer in the slot is bound as rows of 16384 texels (nvn_mtl.m tbuf_as_2d); a 1D texture, one row, reads the same texel
        msl = self.msl(self.MERGE_FIRST, self.TLD_1D)
        self.assertRegex(msl, r'& 16383')
        self.assertRegex(msl, r'>> uint\(14\)')
        self.assertRegex(msl, r'cp_t_tcb_8\.read\(uint2\(')   # slot 0's handle, c2 word 8, as a 2D texture
        self.assertNotIn('texture1d', msl)

    def test_atoms_add_on_shared_memory(self):   # the offset is in bytes: 0x7fc is word 511 of the workgroup's 0x800 bytes
        msl = self.translate(inst(*self.ATOMS_ADD) + inst(*SUATOM) + inst(*EXIT), shared=0x800)
        self.assertRegex(msl, r'atomic_fetch_add_explicit\(\(threadgroup atomic_uint\*\)&_\d+\[511\]')

    # HADD2 / HMUL2 with an immediate (form 2): the second source is the immediate, not the unused register field at 64 (R0, the blur's texture coordinate, in the shader that hung the GPU)
    HADD2_IMM = (0x000fe20000000900, 0x3e003e00ff0c7430)   # HADD2 R12, RZ, (1.5, 1.5)
    HADD2_NEG_IMM = (0x000fe20000000900, 0xb800b800ff0c7430)   # HADD2 R12, RZ, (-0.5, -0.5): bits 63 and 62 belong to the constant, they are not modifiers
    HMUL2_IMM = (0x000fe2000000080c, 0x400040000c0c7432)   # HMUL2 R12, R12, (2.0, 2.0)

    def test_half_add_takes_the_immediate(self):
        msl = self.msl(self.HADD2_IMM)
        self.assertIn('1.5', msl)
        self.assertNotRegex(msl, r'as_type<half2>\(\s*_?\w*r0')

    def test_half_immediate_keeps_its_sign(self):
        self.assertIn('-0.5', self.msl(self.HADD2_NEG_IMM))

    def test_half_multiply_takes_the_immediate(self):
        self.assertIn('2.0', self.msl(self.MERGE_FIRST, self.HMUL2_IMM))

    # HFMA2 .H0_NH1 (bit 86): the low lane multiplies by B's high half negated, the high lane by B's low half. R12 holds (c3[5], c3[6]) from the two merges
    HFMA2_NH1 = (0x000fe200004000ff, 0x0000000c0c0c7231)   # HFMA2 R12, R12, R12.H0_NH1, RZ
    HFMA2_PLAIN = (0x000fe200000000ff, 0x0000000c0c0c7231)   # HFMA2 R12, R12, R12, RZ

    def hfma2_lanes(self, hfma2):   # the generated code, and the names of A.lo, A.hi, B.lo, B.hi, unpacked in that order
        msl = self.msl(self.MERGE_FIRST, self.MERGE_SECOND, hfma2)
        lanes = re.findall(r'float (_\d+) = float2\(as_type<half2>\((?:uint\(_\d+\)|_\d+)\)\)\.[xy];', msl)   # A.lo reads the low word as it is, the half the merge packed it to
        self.assertEqual(len(lanes), 4, msl)
        return (msl, *lanes)

    def test_hfma2_nh1_rotates_b(self):
        msl, a_lo, a_hi, b_lo, b_hi = self.hfma2_lanes(self.HFMA2_NH1)
        negated = re.search(rf'float (_\d+) = -{b_hi};', msl)
        self.assertTrue(negated, msl)
        self.assertIn(f'fma({a_lo}, {negated.group(1)}, 0.0)', msl)   # low lane: A.lo * -B.hi
        self.assertIn(f'fma({a_hi}, {b_lo}, 0.0)', msl)               # high lane: A.hi * B.lo

    def test_hfma2_without_nh1_keeps_the_lanes(self):
        msl, a_lo, a_hi, b_lo, b_hi = self.hfma2_lanes(self.HFMA2_PLAIN)
        self.assertIn(f'fma({a_lo}, {b_lo}, 0.0)', msl)
        self.assertIn(f'fma({a_hi}, {b_hi}, 0.0)', msl)

    # FSEL keeps each operand's modifiers (161,748 of the game's register forms negate B): "x or -x" from one register is how its character and prop lighting picks a sign
    FSEL_NEG_B = (0x000fe40000000000, 0x8000000c0c0c7208)   # FSEL R12, P0, R12, -R12

    def test_fsel_negates_b(self):
        msl = self.msl(self.MERGE_FIRST, self.MERGE_SECOND, self.FSEL_NEG_B)
        self.assertRegex(msl, r'float _\d+ = -')

    def test_up2ur_takes_any_predicate_by_its_mask_bit(self):   # Mario Kart World's pixel shaders save UP6 or UP3 and test the register against URZ later
        for mask in (0x40, 0x08): self.msl((0x000fe20008000000, mask << 32 | 0x3f067883))

    def test_up2ur_with_a_merge_source_is_refused(self):
        with self.assertRaises(AssertionError) as e: self.msl((0x000fe20008000000, 0x40 << 32 | 0x05067883))
        self.assertIn('UP2UR with a merge source', str(e.exception))

    def test_up2ur_reads_up0(self):   # cs_main's encoding: UR6 = UP0 ? 1 : 0
        self.msl((0x000fc60008000000, 0x000000013f067883))

    # Shared memory with a stride of 1: the address is Ra * 4 + offset. RZ would fold the scale away, so the index comes from F2I
    F2I_R3 = (0x000e24000021f000, 0x0000000c00037305)   # F2I.S32 R3, R12
    HIST_INC = (0x0011e4000d00403f, 0x0000000003ff7f8c)   # 0xf8c: the luminance histogram's hist[R3]++
    LDS_SCALED = (0x000fe20000004800, 0x00000000030c7984)   # LDS R12, [R3 * 4]
    LDS_PLAIN = (0x000fe20000000800, 0x00000000030c7984)   # LDS R12, [R3]

    def shared_msl(self, *code):
        return self.translate(b''.join(inst(*c) for c in (self.MERGE_FIRST, self.F2I_R3) + code) + inst(*SUATOM) + inst(*EXIT), shared=0x800)

    def test_histogram_increment_adds_one_at_the_scaled_index(self):
        msl = self.shared_msl(self.HIST_INC)
        self.assertRegex(msl, r'atomic_fetch_add_explicit\(\(threadgroup atomic_uint\*\)&_\d+\[[^\]]*\], 1u')
        self.assertRegex(msl, r'<< 2')

    def test_shared_load_scales_only_with_bit_78(self):
        self.assertRegex(self.shared_msl(self.LDS_SCALED), r'<< 2')
        self.assertNotRegex(self.shared_msl(self.LDS_PLAIN), r'<< 2')

    def test_membar_orders_memory(self):
        self.assertRegex(self.msl(self.MEMBAR, self.ERRBAR), r'threadgroup_barrier|atomic_thread_fence')


class WarpExchange(Translated):
    """LDSM and MOVM take words from other lanes of the warp. In a compute shader they pass them through the SIMD-group's 256 words of the HMMA scratch between two SIMD-group barriers, which on
    an M4 took half the time of MOVM's shuffles and a fifth of LDSM.x4.MT88's (Donkey Kong Bananza's NDSR upscaler); a workgroup with no room left for the scratch shuffles"""
    MOVM = (0x000fe20000000000, 0x000000000c0c723a)           # MOVM.16.MT88 R12, R12
    LDSM_X4_MT88 = (0x000fe20000004200, 0x00004000000c783b)   # LDSM.16.MT88.4 R12, [R0 + 0x40] (the upscaler's 7629d857a0a93833 +0x1ce0 into R20)

    def msl(self, *code, **extra):
        msl = self.translate(b''.join(code) + inst(*SUATOM) + inst(*EXIT), **extra)
        return msl[msl.index('kernel void'):]

    def assert_through_the_scratch(self, msl, words):
        self.assertIn(f'threadgroup spvUnsafeArray<uint, {words}>', msl)
        self.assertEqual(msl.count('simdgroup_barrier(mem_flags::mem_threadgroup)'), 2, msl)
        self.assertNotIn('spvSubgroupShuffle(', msl)

    def test_movm(self):
        self.assert_through_the_scratch(self.msl(s2r(12, TID_X), inst(*self.MOVM)), 256)

    def test_ldsm(self):
        self.assert_through_the_scratch(self.msl(s2r(0, TID_X), sts(0, 0), inst(*self.LDSM_X4_MT88), shared=0x400), 256)

    @staticmethod
    def ldsm(count, mode):   # LDSM.16.M88 / .MT88 (mode 0 / 1) .1 / .2 / .4 (count 0 / 1 / 2) R12, [R0 + 0x40]
        return 0x000fe20000000000 | mode << 14 | count << 8, 0x00004000000c783b

    def test_ldsm_address_is_the_register_as_it_is(self):   # 78..80 are LDSM's mode, not the stride of LDS and STS: read as one, .MT88 took R0 * 4 + 0x40
        for count, mode in [(count, mode) for count in range(3) for mode in range(2)]:
            with self.subTest(matrices=1 << count, transposed=mode):
                self.assertRegex(self.msl(s2r(0, TID_X), sts(0, 0), inst(*self.ldsm(count, mode)), shared=0x400),
                                 r'float (_\d+) = as_type<float>\(gl_LocalInvocationID\.x\);[\s\S]*int _\d+ = as_type<int>\(\1\) \+ 64;')

    def test_scratch_index_is_the_simd_groups_block_and_the_lane(self):   # 64 x 2 invocations: (x + 64y + 128z) >> 5 << 8, plus the lane; the loads from the same block
        msl = self.msl(s2r(12, TID_X), inst(*self.MOVM), local=[64, 2, 1])
        store = re.search(r'float (_\d+) = as_type<float>\(gl_LocalInvocationID\.x\);\s*float (_\d+) = as_type<float>\(gl_LocalInvocationID\.y\);\s*'
                          r'float (_\d+) = as_type<float>\(gl_LocalInvocationID\.z\);\s*int (_\d+) = as_type<int>\(\2\) \* 64;\s*int (_\d+) = as_type<int>\(\3\) \* 128;\s*'
                          r'int (_\d+) = \4 \+ \5;\s*int (_\d+) = as_type<int>\(\1\) \+ \6;\s*uint (_\d+) = uint\(int\(uint\(\7\) >> uint\(5\)\)\);\s*'
                          r'int (?P<block>_\d+) = int\(\8\) << 8;\s*float (_\d+) = as_type<float>\(gl_SubgroupInvocationID\);\s*int (_\d+) = (?P=block) \+ as_type<int>\(\10\);\s*'
                          r'(?P<scratch>_\d+)\[\11\] = ', msl)
        self.assertTrue(store, msl)
        loads = re.findall(rf'int (_\d+) = {store["block"]} \+ _\d+;\s*float _\d+ = as_type<float>\({store["scratch"]}\[\1\]\);', msl)
        self.assertEqual(len(loads), 2, msl)

    def test_a_block_for_each_simd_group(self):   # 128 invocations: 4 SIMD-groups
        self.assert_through_the_scratch(self.msl(s2r(12, TID_X), inst(*self.MOVM), local=[64, 2, 1]), 1024)

    def test_no_room_shuffles(self):   # 31.5 KB of the shader's own shared memory leave no room for the scratch's 1 KB
        msl = self.msl(s2r(12, TID_X), sts(0, 12), inst(*self.MOVM), shared=0x8000 - 0x200)
        self.assertEqual(msl.count('spvSubgroupShuffle('), 2, msl)
        self.assertNotIn('simdgroup_barrier', msl)


class SharedPerInvocation(Translated):
    """Shared memory past Metal's 32 KB that each invocation addresses as words of its own (local invocation index * stride + a constant below it), with no barrier or atomic: 64 of Pokemon
    Pokopia's froxel compute shaders, 8 x 8 x 4 invocations of 37 or 47 words, whose pipelines failed. The words become an array of the invocation's own"""
    BAR = (0x000fec0000000000, 0x0000000000007b1d)        # BAR.SYNC 0x0
    ATOMS_ADD = (0x004e680000000000, 0x0000080c020c738c)  # ATOMS.ADD R12, [R2 + 8], R12

    def msl(self, *code, local=(8, 8, 4), shared=8 * 8 * 4 * 148):
        index = s2r(0, TID_X) + s2r(1, TID_Y) + s2r(4, TID_Z) + imad(2, 0, 148, 0xff) + imad(2, 1, 8 * 148, 2) + imad(2, 4, 64 * 148, 2)   # R2 = (x + 8y + 64z) * 148
        msl = self.translate(index + b''.join(code) + inst(*SUATOM) + inst(*EXIT), local=list(local), shared=shared)
        return msl[msl.index('kernel void'):]

    def shared_read_or_written(self, msl):
        name = re.search(r'threadgroup spvUnsafeArray<uint, \d+> (_\d+);', msl)
        return bool(name and re.search(rf'\b{name.group(1)}\[', msl))

    def test_private(self):
        msl = self.msl(mov(3, 77), sts(8, 3, 2), lds(12, 2, 8))
        self.assertNotIn('threadgroup spvUnsafeArray', msl)
        self.assertRegex(msl, r'spvUnsafeArray<uint, 37> (_\d+);[\s\S]*\1\[2\] = 77u;')

    def test_barrier_keeps_it_shared(self):
        self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(8, 3, 2), inst(*self.BAR), lds(12, 2, 8))))

    def test_atomic_keeps_it_shared(self):
        self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(8, 3, 2), mov(12, 1), inst(*self.ATOMS_ADD))))

    def test_past_the_stride_keeps_it_shared(self):   # word 37 of an invocation is word 0 of the next
        self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(148, 3, 2), lds(12, 2, 8))))

    def test_a_load_outside_the_invocations_words_keeps_it_shared(self):   # word -1, the previous invocation's last, and word 37, the next one's first
        for offset in (-4, 148):
            with self.subTest(offset=offset):
                self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(8, 3, 2), lds(12, 2, offset & 0xffffff))))

    def test_an_8_or_16_bit_access_keeps_it_shared(self):   # STS.U8 / STS.U16 [R2 + 12], R3 beside the 32-bit words
        for size in (0, 2):
            with self.subTest(bits=8 << (size // 2)):
                small = inst(0x000fe80000000000 | size << 8, 12 << 40 | 3 << 32 | 2 << 24 | 0x7388)
                self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(8, 3, 2), small, lds(12, 2, 8))))

    def test_within_the_limit_unchanged(self):   # 8 x 8 x 2 invocations, 18,944 bytes
        self.assertTrue(self.shared_read_or_written(self.msl(mov(3, 77), sts(8, 3, 2), lds(12, 2, 8), local=(8, 8, 2), shared=8 * 8 * 2 * 148)))


class RawGlobalWriteLog(Translated):
    """Stores through addresses read from memory go through the pool table, and set their table entry's bit in the write log. The Legend of Zelda: Ocarina of Time's title movie
    network stores into far more pages than the 1,024 of the page set this replaced: every log ran out of slots, each store then made 8 failed compare-and-swaps"""
    STG = (0x000fe20000000900, 0x0000000402007386)          # STG.E [R2.64], R4
    STG_SECOND = (0x000fe20000000900, 0x0000000705007386)   # STG.E [R5.64], R7

    def msl(self):
        return self.translate(lds(2, 0xff, 0x10) + lds(3, 0xff, 0x14) + mov(4, 7) + inst(*self.STG) + lds(5, 0xff, 0x18) + lds(6, 0xff, 0x1c) + mov(7, 9) + inst(*self.STG_SECOND)
                              + inst(*EXIT), shared=0x400)

    def test_a_store_sets_its_entry_bit(self):
        msl = self.msl()
        self.assertRegex(msl, r'>> uint\(5\)\)\);[\s\S]*1 << \w+;\s*uint \w+ = atomic_fetch_or_explicit\(')
        self.assertNotIn('atomic_compare_exchange', msl)

    def test_a_thread_logs_an_entry_once(self):   # the last entry logged, 0 at the start (entry 0 is empty, never found), is passed to each store
        msl = self.msl()
        main = msl[msl.index('kernel void'):]
        last = re.search(r'uint (_\d+) = 0u;', main).group(1)
        self.assertEqual(len(re.findall(r', %s\);' % last, main)), 2)
        self.assertRegex(msl, r'thread uint& (\w+)\)[\s\S]*as_type<float>\(\1\);\s*bool \w+ = \w+ != [\s\S]*\1 = uint\(\w+\);[\s\S]*atomic_fetch_or_explicit')


class StorageSlotSum(Translated):
    """An address that adds two registers, one of them a register plus a storage slot's address: (tid.x + c0[0x350]) + tid.y, the shape of every load and store of The Legend
    of Zelda: Ocarina of Time's title movie network (d15370a382630d4e). It is that slot's storage buffer, at the address minus the slot's address, not a pool table search"""
    LDG = (0x000fe20000000900, 0x0000000002047381)   # LDG.E R4, [R2.64]
    STG = (0x000fe20000000900, 0x0000000402007386)   # STG.E [R2.64], R4

    def iadd3(self, rd, ra, rb=None, cbuf=None, pred=7):   # IADD3 Rd, Ra, Rb, RZ or IADD3 Rd, Ra, c[0x0][cbuf], RZ
        lo = cbuf << 38 | 0xa10 if cbuf is not None else rb << 32 | 0x210
        return inst(0x000fe20007ffe0ff, lo | ra << 24 | rd << 16 | pred << 12)

    def msl(self, *address):   # slot 4's address at 0x50 of the shader's c0 (nvn2_cs: 5 storage slots from 0x10), which the translator reads as 0x350
        code = s2r(0, TID_X) + s2r(1, TID_Y) + b''.join(address) + self.iadd3(3, 0xff, cbuf=0x54) + inst(*self.LDG) + sts(0x20, 4) + inst(*self.STG) + inst(*EXIT)
        return self.translate(code, shared=0x400, nvn2_cs=[0, 5, 0, 0x60, 0])

    def test_goes_to_the_slots_storage_buffer(self):
        msl = self.msl(self.iadd3(2, 0, cbuf=0x50), self.iadd3(2, 2, 1))
        self.assert_slot_offset(msl)

    def assert_slot_offset(self, msl):   # both the load and store subtract the exact base, without rounding it to a host alignment
        self.assertNotIn('reinterpret_cast<device', msl)
        self.assertEqual(len(re.findall(r'- as_type<int>\(\(\*spvDescriptorSet0\.cp_c0\)\._m0\[53\]\.x\)', msl)), 2)
        self.assertNotIn('& (-16)', msl)
        self.assertRegex(msl, r'as_type<float>\(\(\*spvDescriptorSet0\.cp_s0\)\._m0\[')
        self.assertRegex(msl, r'\(\*spvDescriptorSet0\.cp_s0\)\._m0\[[^;]* = as_type<uint>')

    def test_base_in_the_second_operand(self):
        self.assert_slot_offset(self.msl(self.iadd3(2, 0, cbuf=0x50), self.iadd3(2, 1, 2)))

    def test_nonzero_offsets_survive_the_base_subtraction(self):   # the outer constant Add must not lose its offset; low-word signed boundaries included
        for offset, literal in ((4, '4'), (0x124, '292'), (0x7ffffffc, '2147483644'), (0x80000000, 'int(0x80000000)'), (0xfffffffc, '(-4)')):
            with self.subTest(offset=hex(offset)):
                msl = self.msl(self.iadd3(2, 0, cbuf=0x50), self.iadd3(2, 2, 1), mov(5, offset), self.iadd3(2, 2, 5))
                self.assert_slot_offset(msl)
                address = re.search(rf'int (_\d+) = _\d+ \+ {re.escape(literal)};', msl)
                self.assertTrue(address, msl)
                self.assertEqual(len(re.findall(rf'{address.group(1)} - as_type<int>\(\(\*spvDescriptorSet0\.cp_c0\)\._m0\[53\]\.x\)', msl)), 2)

    def test_neither_operand_has_a_base_keeps_the_search(self):   # both operands are Adds, but neither contains a c0 base
        msl = self.msl(mov(5, 4), self.iadd3(5, 0, 5), mov(6, 8), self.iadd3(6, 1, 6), self.iadd3(2, 5, 6))
        self.assertIn('reinterpret_cast<device', msl)

    def test_two_slot_addresses_in_the_sum_keep_the_search(self):   # (tid.x + c0[0x350]) + (tid.y + c0[0x310]): no single base
        msl = self.msl(self.iadd3(2, 0, cbuf=0x50), self.iadd3(1, 1, cbuf=0x10), self.iadd3(2, 2, 1))
        self.assertIn('reinterpret_cast<device', msl)

    def test_two_targets_keep_the_low_high_and_size_checks(self):   # a Phi of simple slot addresses still uses checked multi-target dispatch
        msl = self.msl(self.iadd3(2, 0, 1), inst(*Shared.ISETP_P0), self.iadd3(2, 0, cbuf=0x50), self.iadd3(2, 1, cbuf=0x10, pred=0))
        self.assertNotIn('reinterpret_cast<device', msl)
        helpers = msl[msl.index('static inline'):msl.index('kernel void')]
        for slot in (49, 53):   # c0[0x310] and c0[0x350]: low subtraction borrows from high, then size and high must match
            with self.subTest(slot=slot):
                self.assertEqual(len(re.findall(rf'uint\(_\d+\) < as_type<uint>\(cp_c0\._m0\[{slot}\]\.x\)', helpers)), 2)
                self.assertEqual(len(re.findall(rf'uint\(_\d+\) < as_type<uint>\(cp_c0\._m0\[{slot}\]\.z\)', helpers)), 2)
                self.assertEqual(len(re.findall(rf'== as_type<int>\(cp_c0\._m0\[{slot}\]\.y\)', helpers)), 2)
        self.assertEqual(len(re.findall(r'\+ \(_\d+ \? \(-1\) : 0\)', helpers)), 4)

    def test_sums_on_two_paths_keep_the_pool_search(self):   # needsOffset=false must not pick either sum's nested base while collecting Phi targets
        for reverse in (False, True):
            with self.subTest(reverse=reverse):
                ra, rb = (1, 5) if reverse else (5, 1)
                msl = self.msl(self.iadd3(2, 0, 1), inst(*Shared.ISETP_P0), self.iadd3(5, 0, cbuf=0x50), self.iadd3(2, ra, rb),
                               self.iadd3(5, 0, cbuf=0x10), self.iadd3(2, ra, rb, pred=0))
                self.assertIn('reinterpret_cast<device', msl)


if __name__ == '__main__':
    unittest.main()
