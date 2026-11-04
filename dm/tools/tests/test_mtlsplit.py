"""The nvn_mtl.m split tools (dm/tools/mtlsplit): the declaration reader the move tool and the move check share, the module prelude and its header rule,
the move check on patches written by hand (moves in order, linkage edits, splits, the generated prelude and declarations; a changed, reordered or
misplaced line fails), the call check on otool and nm text written by hand (counts, allow and inline rows, @cross, folded symbols, functions ThinLTO
inlines in one binary), and, when clang is installed, the whole chain on a small tree in a temporary folder: facts from clang's AST, the module map, a
move, the move check of its patch, and the program built from the moved files (two objects, then the unity file) printing what the original prints."""
import collections
import contextlib
import difflib
import io
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from mtlsplit import callcheck, common, facts, modmap, move, movecheck  # noqa: E402

HID = common.HIDDEN
C = collections.Counter


class Declarations(unittest.TestCase):
    def read(self, text):
        code, sts = common.statements(text)
        out = []
        for s, e in sts:
            pe, ds = common.declarators(code, s, e)
            out.append((text[s:pe], [(text[a:b], n) for a, b, n in ds]))
        return out, text[sts[-1][1]:]

    def test_lists(self):
        got, tail = self.read('static int g_a = -1; static uint64_t g_b[64], g_c[8];   // note; with a semicolon')
        self.assertEqual(got, [('static int ', [('g_a = -1', 'g_a')]), ('static uint64_t ', [('g_b[64]', 'g_b'), ('g_c[8]', 'g_c')])])
        self.assertEqual(tail, '   // note; with a semicolon')

    def test_declarators(self):
        got, _ = self.read('typedef struct seg seg; static seg *g_s; static void put(seg *c, int (*f)(int));')
        self.assertEqual(got, [('typedef struct seg ', [('seg', 'seg')]), ('static seg ', [('*g_s', 'g_s')]), ('static void ', [('put(seg *c, int (*f)(int))', 'put')])])
        got, _ = self.read('static void (*g_fp)(int a, int b), *const g_q; static NSString *g_p, *g_d;')
        self.assertEqual(got, [('static void ', [('(*g_fp)(int a, int b)', 'g_fp'), ('*const g_q', 'g_q')]), ('static NSString ', [('*g_p', 'g_p'), ('*g_d', 'g_d')])])

    def test_not_a_list(self):
        self.assertIsNone(common.statements('static void f(void) {')[1])
        self.assertEqual(common.blank_code('a = "x;y"; // z;'), 'a = "   ";      ')

    def test_top_level(self):
        text = ('#define X(a) { a; }\nstatic int g_n, g_m = 1;\nstatic void f(int x) __attribute__((cold)) {\n    static int k; { k += x; }\n}\n'
                'static struct { int a; } g_s = { 1 };\n@interface Q : NSObject { @public int v; } @end\n@implementation Q\n- (void)go { f(1); }\n@end\nint h(void);\n')
        chunks, code = common.top_level(text)
        got = [(code.count('\n', 0, s) + 1, kind) for s, e, kind, body in chunks]
        self.assertEqual(got, [(2, 'statement'), (3, 'function'), (6, 'statement'), (7, 'objc'), (8, 'objc'), (9, 'function'), (10, 'objc'), (11, 'statement')])


PUSH = '#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)'
POP = '#pragma clang attribute pop'


class Prelude(unittest.TestCase):
    TEXTS = {'dm/gfx/nvn/t_used.h': '#pragma once\nstatic inline int t_inc(int v) { static const int one = 1; return v + one; }\n',
             'dm/gfx/nvn/t_unused.h': '#pragma once\n#include <stdint.h>\nstatic inline int t_dec(int v) { return v - 1; }\nint t_proto(int v);\n',
             'dm/gfx/nvn/t_nest.h': '#pragma once\n#include "t_deep.h"\n', 'dm/gfx/nvn/t_deep.h': '#pragma once\nenum { T_DEEP = 3 };\n',
             'dm/gfx/nvn/t_pre.h': '#pragma once\n#define T_PRE 1\n'}
    UNIT = ['#include <stdio.h>', '#include "t_pre.h"', PUSH, '#include "t_used.h"', '#include "t_unused.h"', '#include "t_nest.h"', 'int x;', POP]

    def test_rule(self):
        out, push, pop = common.prelude(self.UNIT, {'t_inc', 'T_DEEP'}, self.TEXTS.get)
        self.assertEqual(out, ['#include <stdio.h>', '#include "t_pre.h"', PUSH, '#include "t_used.h"', '#include "t_nest.h"'])
        self.assertEqual((push, pop), (PUSH, POP))
        self.assertEqual(common.prelude(self.UNIT, set(), self.TEXTS.get)[0], ['#include <stdio.h>', '#include "t_pre.h"', PUSH])

    def test_unsafe_header(self):
        for path, bad, why in (('t_unused.h', '#define T_N 1', 'macro'), ('t_unused.h', '#ifdef T_PRE', 'conditional'), ('t_unused.h', '#pragma pack(1)', 'pragma'),
                               ('t_unused.h', '@class Q;', 'ObjC'), ('t_unused.h', 'static int t_n;', 'state'), ('t_unused.h', 'int t_m = 0;', 'state'),
                               ('t_unused.h', 'static inline int t_c(void) { static int n; return ++n; }', 'static'), ('t_deep.h', '#undef T_PRE', 'macro')):
            texts = dict(self.TEXTS); texts['dm/gfx/nvn/' + path] += bad + '\n'
            with self.assertRaisesRegex(ValueError, f'{path}.*{why}'):
                common.prelude(self.UNIT, {'t_inc'}, texts.get)


def patch(*files):
    out = []
    for path, old, new in files:
        out.append(f'diff --git a/{path} b/{path}\n')
        if old is None: out.append('new file mode 100644\n')
        a = [x + '\n' for x in old or []]; b = [x + '\n' for x in new]
        out += list(difflib.unified_diff(a, b, '/dev/null' if old is None else f'a/{path}', f'b/{path}', n=1))
    return ''.join(out)


UNIT = 'dm/gfx/nvn/nvn_mtl.m'
OLD = ['#include <stdio.h>', PUSH, 'static int g_a, g_b;   // c', 'static int ws_on(void) { static int v = -1; return v; }', 'static void f(int x) {',
       '    int k = 0;', '    k = 1;', '    k++;', '    g_a += x + k + ws_on();', '}', '#ifdef NVN_T', 'static void g(void) { f(1); g_b++; }', '#endif', POP]
NEW = ['#include <stdio.h>', PUSH, '#include "mtl_x.h"', 'static int g_b;', '#ifdef NVN_T', 'static void g(void) { f(1); g_b++; }', '#endif', POP]
MOD_M = ['#include <stdio.h>', PUSH, '#include "mtl_x.h"', 'static int g_a;   // c', 'static int ws_on(void) { static int v = -1; return v; }', 'void f(int x) {',
         '    int k = 0;', '    k = 1;', '    k++;', '    g_a += x + k + ws_on();', '}', POP]
MOD_H = ['#pragma once', f'{HID} void f(int x);']


def edit(lines, i, *new):
    return lines[:i] + list(new) + lines[i + 1:]


class MoveCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / 'dm/gfx/nvn').mkdir(parents=True)
        for f in common.SOURCES: (self.tmp / f).write_text('')

    def run_check(self, text, unit=OLD, kind='move', edits=()):
        (self.tmp / UNIT).write_text(''.join(x + '\n' for x in unit))
        p = self.tmp / 'x.patch'; p.write_text(text)
        args = ['--patch', str(p), '--root', str(self.tmp), '--kind', kind]
        if edits:
            (self.tmp / 'edits').write_text(''.join(x + '\n' for x in edits)); args += ['--edits', str(self.tmp / 'edits')]
        out = io.StringIO()
        with contextlib.redirect_stdout(out): rc = movecheck.main(args)
        return rc == 0, out.getvalue()

    def check(self, unit=OLD, new=NEW, mod_m=MOD_M, mod_h=MOD_H, kind='move', edits=(), header_first=False):
        files = [(UNIT, unit, new)]
        if mod_m is not None: files.append(('dm/gfx/nvn/mtl_x.m', None, mod_m))
        if mod_h is not None: files.insert(1 if header_first else len(files), ('dm/gfx/nvn/mtl_x.h', None, mod_h))
        return self.run_check(patch(*files), unit, kind, edits)

    def counts(self, out):
        m = re.search(r'(\d+) lines moved, (\d+) linkage edits, (\d+) splits', out)
        return tuple(int(x) for x in m.groups())

    def test_pass(self):
        ok, out = self.check()
        self.assertTrue(ok, out)
        self.assertEqual(self.counts(out), (6, 1, 1))

    def test_changed_line(self):
        ok, out = self.check(mod_m=edit(MOD_M, 9, '    g_a -= x + k + ws_on();'))
        self.assertFalse(ok)
        self.assertIn('g_a += x', out); self.assertIn('g_a -= x', out)

    def test_split_changed(self):
        self.assertFalse(self.check(new=edit(NEW, 3, 'static long g_b;'))[0])
        self.assertFalse(self.check(mod_m=edit(MOD_M, 3, 'static int g_a;'))[0])

    def test_declarations(self):
        self.assertFalse(self.check(mod_h=MOD_H + [f'{HID} void h(int x);'])[0])
        self.assertFalse(self.check(mod_h=MOD_H + [f'{HID} void f(int x) {{ }}'])[0])
        ok, out = self.check(mod_h=MOD_H + [f'extern {HID} int g_a;'], mod_m=edit(MOD_M, 3, 'int g_a;   // c'))
        self.assertTrue(ok, out)
        self.assertEqual(self.counts(out), (6, 1, 1))
        self.assertFalse(self.check(mod_h=MOD_H + [f'extern {HID} int g_a;'])[0])

    def test_prelude_lines(self):
        self.assertFalse(self.check(mod_m=['#include <stdlib.h>'] + MOD_M)[0])

    def test_local_static(self):
        self.assertFalse(self.check(mod_m=edit(MOD_M, 4, 'static int ws_on(void) { int v = -1; return v; }'))[0])
        self.assertFalse(self.check(mod_m=edit(MOD_M, 4, 'int ws_on(void) { static int v = -1; return v; }'))[0])
        ok, out = self.check(mod_m=edit(MOD_M, 4, 'int ws_on(void) { static int v = -1; return v; }'), mod_h=MOD_H + [f'{HID} int ws_on(void);'])
        self.assertTrue(ok, out)
        self.assertEqual(self.counts(out), (5, 2, 1))

    def test_directives(self):
        self.assertFalse(self.check(mod_m=MOD_M[:7] + ['#ifdef NVN_T'] + MOD_M[7:9] + ['#endif'] + MOD_M[9:])[0])
        self.assertFalse(self.check(mod_m=MOD_M[:-1] + ['#include <stdio.h>', POP])[0])
        self.assertFalse(self.check(mod_m=MOD_M[:1] + MOD_M[2:-1])[0])

    def test_header_content(self):
        self.assertFalse(self.check(mod_m=MOD_M[:4] + MOD_M[5:], mod_h=MOD_H + [MOD_M[4]])[0])
        for first in (True, False):
            self.assertFalse(self.check(mod_h=MOD_H + ['static int k;'], header_first=first)[0])
        self.assertFalse(self.check(mod_h=['#pragma once', f'{HID} int f(int x);'])[0])

    def test_order(self):
        self.assertFalse(self.check(mod_m=MOD_M[:7] + [MOD_M[8], MOD_M[7]] + MOD_M[9:])[0])

    def test_slid_diff(self):
        old = ['#include <stdio.h>', PUSH, 'static int g_b;', '', 'static void f(int x) {', '    (void)x;', '}', '', 'int main(void) { f(1); return g_b; }', POP]
        text = (f'diff --git a/{UNIT} b/{UNIT}\n--- a/{UNIT}\n+++ b/{UNIT}\n@@ -1,10 +1,7 @@\n #include <stdio.h>\n {PUSH}\n+#include "mtl_x.h"\n static int g_b;\n \n'
                f'-static void f(int x) {{\n-    (void)x;\n-}}\n-\n int main(void) {{ f(1); return g_b; }}\n {POP}\n')
        text += patch(('dm/gfx/nvn/mtl_x.m', None, ['#include <stdio.h>', PUSH, '#include "mtl_x.h"', '', 'void f(int x) {', '    (void)x;', '}', POP]),
                      ('dm/gfx/nvn/mtl_x.h', None, ['#pragma once', f'{HID} void f(int x);']))
        ok, out = self.run_check(text, old)
        self.assertTrue(ok, out)

    def test_cut_edits(self):
        self.assertFalse(self.check(['a();', 'b();'], ['b();', 'c();'], None, None, 'cut')[0])
        self.assertTrue(self.check(['a();', 'b();'], ['b();', 'c();'], None, None, 'cut', ['-a();', '+c();'])[0])

    def test_hunks(self):
        files = movecheck.parse_patch(patch((UNIT, ['-- x', 'y'], ['y'])))
        self.assertEqual(files[UNIT]['removed'], ['-- x'])


OTOOL = """/x/dmhost:
(__TEXT,__text) section
_draw_:
0000000100000000\tbl\t_enc_r_begin
0000000100000004\tbl\t0x100262ad0 ; symbol stub for: _getenv
0000000100000008\tbl\t"_objc_msgSend$setLabel:"
000000010000000c\tb\t_lc_take.llvm.123
0000000100000010\tb\t0x100000000
_rp_end:
0000000100000014\tbl\t_helper.llvm.99
"""
MODS = {'rp_end': 'pass', 'tb_x': 'tbdr', 'pass_y': 'pass', 'draw_': 'draw', 'draw': 'draw'}


class CallCheck(unittest.TestCase):
    rows = [{'verdict': 'inline', 'function': '*', 'callee': 'enc_r_*', 'why': 'sink'}, {'verdict': 'inline', 'function': '*', 'callee': 'rt_sub', 'why': 'state'},
            {'verdict': 'allow', 'function': '*', 'callee': 'pso_get', 'why': 'out of line'}, {'verdict': 'allow', 'function': 'rp_end', 'callee': '@cross', 'why': 'per pass'}]

    def test_disassemble(self):
        d = callcheck.disassemble(None, OTOOL)
        self.assertEqual(dict(d['draw_']), {'enc_r_begin': 1, 'getenv': 1, 'objc_msgSend$setLabel:': 1, 'lc_take': 1})
        self.assertEqual(dict(d['rp_end']), {'helper': 1})

    def test_compare(self):
        base = {'draw_': C(a=1), 'rp_end': C()}
        new = {'draw_': C(a=1, enc_r_vbuf=1, pso_get=1, mystery=1), 'rp_end': C(tb_x=1, pass_y=1)}
        bad, rep = callcheck.compare(base, new, ['draw_', 'rp_end'], self.rows, MODS, {})
        self.assertEqual(bad, 3)
        self.assertTrue(any('enc_r_vbuf (0 -> 1), which must stay inline' in r for r in rep))
        self.assertTrue(any('pso_get (0 -> 1), allowed' in r for r in rep) and any('tb_x (0 -> 1), allowed' in r for r in rep))
        self.assertTrue(any('new call to pass_y (0 -> 1) (not in the allowlist)' in r for r in rep) and any('mystery' in r for r in rep))
        self.assertEqual(callcheck.compare(base, base, ['draw_', 'rp_end'], self.rows, MODS, {})[0], 0)

    def test_counts(self):
        bad, rep = callcheck.compare({'draw_': C(rt_sub=1, a=1)}, {'draw_': C(rt_sub=4, a=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 1)
        self.assertTrue(any('rt_sub (1 -> 4), which must stay inline' in r for r in rep), rep)
        bad, rep = callcheck.compare({'draw_': C(rt_sub=4)}, {'draw_': C(rt_sub=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 0)
        self.assertTrue(any('fewer calls: rt_sub (4 -> 1)' in r for r in rep), rep)

    def test_inlined_more(self):
        base = {'draw_': C(h=2, a=1), 'h': C(x=1, getenv=1)}
        bad, rep = callcheck.compare(base, {'draw_': C(h=1, x=1, getenv=1, a=1), 'h': C(x=1, getenv=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 0, rep)
        self.assertTrue(any('h 2 -> 1 calls, assumed inlined at more sites; its body explains x +1, getenv +1' in r for r in rep), rep)
        bad, rep = callcheck.compare(base, {'draw_': C(h=1, x=1, getenv=1, a=1, rt_sub=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 1, rep)
        self.assertTrue(any('rt_sub (0 -> 1), which must stay inline' in r for r in rep), rep)

    def test_absorb_cascade(self):
        base = {'draw_': C(h=2, a=1), 'h': C(g=1), 'g': C(y=1)}
        bad, rep = callcheck.compare(base, {'draw_': C(h=1, y=1, a=1), 'h': C(g=1), 'g': C(y=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 1, rep)
        self.assertTrue(any('new call to y (0 -> 1)' in r for r in rep), rep)

    def test_absorb_inline_row(self):
        base = {'draw_': C(h=2, a=1), 'h': C(rt_sub=1)}
        bad, rep = callcheck.compare(base, {'draw_': C(h=1, rt_sub=1, a=1), 'h': C(rt_sub=1)}, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 1, rep)
        self.assertTrue(any('rt_sub (0 -> 1), which must stay inline (state), possibly through inlined h' in r for r in rep), rep)

    def test_vanished(self):
        base = {'draw_': C(a=1), 'rp_end': C(b=1)}
        bad, rep = callcheck.compare(base, {'draw_': C(a=1)}, ['draw_', 'rp_end'], self.rows, MODS, {})
        self.assertEqual(bad, 1)
        self.assertTrue(any(r.startswith('[RED] rp_end') for r in rep), rep)
        self.assertEqual(callcheck.compare(base, base, ['draw_', 'nothere'], self.rows, MODS, {})[0], 1)

    def test_draw_inlined(self):
        out_of_line = {'draw': C(draw_=1, x=1), 'draw_': C(rt_sub=1, enc_q=2)}
        inlined = {'draw': C(x=1, rt_sub=1, enc_q=2)}
        for base, new in ((out_of_line, inlined), (inlined, out_of_line)):
            bad, rep = callcheck.compare(base, new, ['draw_'], self.rows, MODS, {})
            self.assertEqual(bad, 0, rep)
            self.assertFalse(any('new call' in r for r in rep), rep)
            self.assertTrue(any('draw_ (inlined into draw in the ' in r for r in rep), rep)
        self.assertEqual(callcheck.compare(out_of_line, {'draw': C(x=1, rt_sub=1, enc_q=2, mystery=1)}, ['draw_'], self.rows, MODS, {})[0], 1)
        self.assertEqual(callcheck.compare(inlined, {'draw': C(draw_=1, x=1), 'draw_': C(rt_sub=1, enc_q=2, mystery=1)}, ['draw_'], self.rows, MODS, {})[0], 1)
        bad, rep = callcheck.compare(inlined, {'draw': C(x=1, rt_sub=2, enc_q=2)}, ['draw_'], self.rows, MODS, {'draw_': ['draw']})
        self.assertEqual(bad, 1)
        self.assertTrue(any('inlined into draw in both binaries' in r for r in rep), rep)

    def test_holders(self):
        callers = callcheck.read_callers(callcheck.HERE / 'callcheck_callers.tsv')
        binary = {'draw_': C(), 'encode_args_': C(), 'pool_gpu': C(), 'fz_p2_draw': C()}
        fns, lost = callcheck.checked(binary, [], callers)
        self.assertEqual(fns, ['draw_', 'encode_args_', 'rp_begin_ex_', 'rp_end', 'fz_p2_draw', 'pool_gpu'])
        self.assertEqual(lost, [])
        self.assertEqual(callcheck.checked({'x': C()}, [], {'tex_fast_rid': ['lost']})[1], ['lost'])

    def test_cross_moved(self):
        mods = callcheck.modules(callcheck.HERE / 'functions.tsv')
        self.assertEqual((mods['rp_end'], mods['tex_fast_rid'], mods['cp_begin']), ('pass', 'treg', 'prof'))
        bad, rep = callcheck.compare({'rp_end': C()}, {'rp_end': C(tex_fast_rid=1, pso_get=1)}, ['rp_end'], [self.rows[3]], mods, {})
        self.assertEqual(bad, 0, rep)

    def test_aliases(self):
        nm = '0000000100000000 T _draw_\n0000000100000100 t _enc_b_end\n0000000100000100 t _enc_r_end\n0000000100000200 t _pso_get\n                 U _abort\n'
        base = callcheck.disassemble(None, '_draw_:\n0000000100000000\tbl\t_enc_r_end\n0000000100000004\tbl\t_enc_r_end\n0000000100000008\tbl\t_pso_get\n', nm)
        new = callcheck.disassemble(None, '_draw_:\n0000000100000000\tbl\t_enc_b_end\n0000000100000004\tbl\t_enc_b_end\n0000000100000008\tbl\t_pso_get\n', nm)
        bad, rep = callcheck.compare(base, new, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 0, rep)
        self.assertTrue(any('same calls' in r for r in rep), rep)
        folded = nm + '0000000100000200 t _rt_sub\n'
        new = callcheck.disassemble(None, '_draw_:\n0000000100000000\tbl\t_enc_b_end\n0000000100000004\tbl\t_enc_b_end\n0000000100000008\tbl\t_pso_get\n'
                                    '000000010000000c\tbl\t_pso_get\n', folded)
        bad, rep = callcheck.compare(base, new, ['draw_'], self.rows, MODS, {})
        self.assertEqual(bad, 1, rep)
        self.assertTrue(any('pso_get (also rt_sub) (1 -> 2), which must stay inline' in r for r in rep), rep)

    def test_allow_file(self):
        rows = callcheck.read_allow(callcheck.HERE / 'callcheck_allow.tsv')
        self.assertTrue(rows and all(r['verdict'] in ('allow', 'inline') and r['callee'] for r in rows))


SRC = r'''// a test unit
#include <stdio.h>
#include <stdint.h>
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)
#include "t_used.h"
#include "t_unused.h"
#define LOGX(...) printf(__VA_ARGS__)
static int g_a, g_b = 2;   // a: module a's counter, b: module b's
// a box of module a
typedef struct { int x; } a_box;
static inline int a_twice(int v) { return 2 * v; }
static int a_count(void) { static int n; LOGX("count\n"); return t_inc(++n) + g_a; }
static void a_bump(a_box *bx) {
    g_a += bx->x;
}
static int b_run(void) { a_box bx = {3}; a_bump(&bx); return a_twice(a_count()) + g_b + g_a + t_dec(1); }
int main(void) { LOGX("%d\n", b_run()); return 0; }
#pragma clang attribute pop
'''
T_USED = '#pragma once\nstatic inline int t_inc(int v) { return v + 1; }\n'
T_UNUSED = '#pragma once\nstatic inline int t_dec(int v) { return v - 1; }\n'


@unittest.skipUnless(shutil.which('clang'), 'clang is needed')
class Chain(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, self.tmp)
        nvn = self.tmp / 'dm/gfx/nvn'; nvn.mkdir(parents=True)
        for f in common.SOURCES: (self.tmp / f).write_text('')
        (self.tmp / UNIT).write_text(SRC)
        (nvn / 't_used.h').write_text(T_USED); (nvn / 't_unused.h').write_text(T_UNUSED)
        (nvn / 'nvn_mtl_all.inc').write_text('#include "nvn_mtl.m"\n')
        t = self.tmp / 'tables'; t.mkdir()
        (t / 'modules.tsv').write_text('1\ta\tthe first\n2\tb\tthe second\n3\tfacade\twhat is left\n')
        (t / 'functions.tsv').write_text('a\ta_twice\na\ta_count\na\ta_bump\nb\tb_run\nfacade\tmain\n')
        (t / 'globals.tsv').write_text('a\tg_a\nb\tg_b\n')
        (t / 'cuts.tsv').write_text('# kind\tfrom\tto\tcut\n')
        self.tables = t

    def run_c(self, *files, out):
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-function', '-o', str(out), *map(str, files)], check=True, cwd=self.tmp)
        return subprocess.run([str(out)], check=True, capture_output=True, text=True).stdout

    def map_json(self):
        ast = subprocess.run(['clang', '-fobjc-arc', '-fsyntax-only', '-Wno-everything', '-Xclang', '-ast-dump', '-fno-color-diagnostics', UNIT],
                             cwd=self.tmp, check=True, capture_output=True, text=True).stdout
        with mock.patch.object(facts, 'REPO', self.tmp):
            f = facts.facts_of(facts.parse(ast.splitlines(True), str(self.tmp)))
        return f, modmap.Map(f, *modmap.load_tables(self.tables), root=self.tmp)

    def test_chain(self):
        want = self.run_c(self.tmp / UNIT, out=self.tmp / 'orig')
        f, m = self.map_json()
        self.assertEqual(sorted(k for k, v in f['functions'].items() if v['body'] and not k.startswith('@init:')), ['a_bump', 'a_count', 'a_twice', 'b_run', 'main'])
        self.assertEqual(f['functions']['b_run']['vars'], {'g_a': 'R', 'g_b': 'R'})
        self.assertIn(('split', UNIT, 8, ['a', 'b']), m.conflicts)
        self.assertFalse(m.upward)
        mj = json.loads(json.dumps(m.to_json()))
        mv = move.Move(mj, 'a', self.tmp, self.tmp / 'dm/gfx/nvn/nvn_mtl_all.inc')
        files = mv.build()
        self.assertEqual(sorted(mv.exported), ['LOGX', 'a_box', 'a_bump', 'a_count', 'a_twice', 'g_a'])
        text = ''.join(''.join(move.diff(k, o, n, str(pathlib.Path(k).relative_to(self.tmp)) if k.startswith('/') else k)) for k, (o, n) in files.items())
        (self.tmp / 'a.patch').write_text(text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out): rc = movecheck.main(['--patch', str(self.tmp / 'a.patch'), '--root', str(self.tmp)])
        self.assertEqual(rc, 0, out.getvalue())
        self.assertIn(' 1 splits', out.getvalue())
        for k, (o, n) in files.items():
            pathlib.Path(k if k.startswith('/') else self.tmp / k).write_text(''.join(x + '\n' for x in n))
        h = (self.tmp / 'dm/gfx/nvn/mtl_a.h').read_text()
        self.assertIn('static inline int a_twice', h)
        self.assertIn(f'extern {HID} int g_a;', h)
        self.assertIn(f'{HID} int a_count(void);', h)
        self.assertIn('static int g_b = 2;', (self.tmp / UNIT).read_text())
        mod = (self.tmp / 'dm/gfx/nvn/mtl_a.m').read_text()
        self.assertIn('int g_a;   // a: module', mod)
        self.assertIn('#include "t_used.h"\n', mod)
        self.assertNotIn('t_unused.h', mod)
        self.assertEqual(self.run_c(self.tmp / UNIT, self.tmp / 'dm/gfx/nvn/mtl_a.m', out=self.tmp / 'split'), want)
        self.assertEqual(self.run_c('-x', 'objective-c', self.tmp / 'dm/gfx/nvn/nvn_mtl_all.inc', out=self.tmp / 'unity'), want)
        self.assertEqual((self.tmp / 'dm/gfx/nvn/nvn_mtl_all.inc').read_text(), '#include "mtl_a.m"\n#include "nvn_mtl.m"\n')

    def test_refuses(self):
        _, m = self.map_json()
        mj = json.loads(json.dumps(m.to_json()))
        with self.assertRaisesRegex(move.Refused, 'b_run calls `a_bump` of a'):
            move.Move(mj, 'b', self.tmp)
        (self.tmp / 'dm/gfx/nvn/t_unused.h').write_text(T_UNUSED + '#define T_N 1\n')
        with self.assertRaisesRegex(move.Refused, 't_unused.h.*macro'):
            move.Move(mj, 'a', self.tmp).build()
        (self.tmp / UNIT).write_text(SRC + '\n')
        with self.assertRaisesRegex(move.Refused, 'changed since the map was made'):
            move.Move(mj, 'a', self.tmp)


if __name__ == '__main__':
    unittest.main()
