"""The command digest's layouts (nvn_rec_digest.inc) against the recorder's record sites (nvn_rec.h, nvn_mtl.m): every slot a site writes has a letter, every letter a site leaves unwritten is '-', and objects, pointers and values take letters of their kind. No game or GPU needed."""
import re
import unittest
from pathlib import Path

GFX = Path(__file__).resolve().parents[1]
SOURCES = [GFX / 'nvn/nvn_rec.h', GFX / 'nvn/nvn_mtl.m']
STRUCT_SLOTS = {'MTLViewport': 6, 'MTLScissorRect': 4}
PUT = re.compile(r'\brec_put\((RO_\w+)\s*,|\brec_own_put\([^,]+,\s*(RO_\w+)\s*,|\brec_table_op\((RO_\w+)\s*,')
NEXT = re.compile(r'\brec_put\(|\brec_own_put\(|\brec_table_op\(|\breturn\b')
WRITE = re.compile(r'->a\[(\d+)\]\s*=(?!=)')
MEMCPY = re.compile(r'memcpy\(r->a,\s*&(\w+),\s*sizeof \1\)')
OBJ_LETTERS, PTR_LETTERS, VAL_FORBIDDEN = set('odsp-'), set('m-'), set('odsm')


def scan(text, start, stop=None):
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c in '({[':
            depth += 1
        elif c in ')}]':
            depth -= 1
            if depth < 0:
                return i
        elif depth == 0 and stop and stop(text, i):
            return i
    return len(text)


def until_next(text, i):
    return NEXT.match(text, i)


def until_semicolon(text, i):
    return text[i] == ';'


def kind(expr):
    if 'rec_obj(' in expr or '__bridge' in expr:
        return 'obj'
    return 'ptr' if '(uintptr_t)' in expr else 'val'


def writes(body, signature):
    slots = {}
    for m in WRITE.finditer(body):
        slots[int(m.group(1))] = kind(body[m.end():scan(body, m.end(), stop=until_semicolon)])
    for m in MEMCPY.finditer(body):
        t = re.search(r'\((\w+)\)\s*' + m.group(1) + r'\b', signature)
        if not t or t.group(1) not in STRUCT_SLOTS:
            raise AssertionError(f'a record copies {m.group(1)} of a type this test does not know the size of: {signature.strip()[:120]}')
        for k in range(STRUCT_SLOTS[t.group(1)]):
            slots[k] = 'val'
    return slots


def sites():
    head = SOURCES[0].read_text()
    table = re.search(r'static inline void rec_table_op\([^)]*\)\s*\{', head)
    if not table:
        raise AssertionError('rec_table_op is not defined in nvn_rec.h')
    table_slots = writes(head[table.end():scan(head, table.end())], '')
    found = {}
    for src in SOURCES:
        text = src.read_text()
        for m in PUT.finditer(text):
            op = m.group(1) or m.group(2) or m.group(3)
            if m.group(3):
                slots = table_slots
            else:
                after = scan(text, m.end()) + 1
                slots = writes(text[after:scan(text, after, stop=until_next)], text[text.rfind('\n', 0, m.start()) + 1:m.start()])
            found.setdefault(op, []).append((f'{src.name}:{text.count(chr(10), 0, m.start()) + 1}', slots))
    return found


def layouts():
    text = (Path(__file__).resolve().parent / 'nvn_rec_digest.inc').read_text()
    return {m.group(1): m.group(2) for m in re.finditer(r'\[(RO_\w+)\]\s*=\s*\{"\w+",\s*"([^"]*)"\}', text)}


def ops():
    text = SOURCES[0].read_text()
    body = re.search(r'enum\s*\{\s*(RO_CB_NEW\b.*?)\}', text, re.S).group(1)
    return re.findall(r'\b(RO_\w+)\b', re.sub(r'//[^\n]*', '', body))


class RecordLayout(unittest.TestCase):
    def test_every_op_has_a_layout_and_a_site(self):
        lay, found = layouts(), sites()
        for op in ops():
            self.assertIn(op, lay, f'{op} has no layout in nvn_rec_digest.inc')
            self.assertIn(op, found, f'{op} is never recorded')

    def test_layouts_match_the_record_sites(self):
        lay, found = layouts(), sites()
        for op, where in found.items():
            spec = lay[op]
            width = max((max(s) + 1 for _, s in where if s), default=0)
            self.assertEqual(len(spec), width, f'{op}: layout "{spec}" has {len(spec)} slots, its records write {width} ({", ".join(w for w, _ in where)})')
            for w, slots in where:
                for k, letter in enumerate(spec):
                    if k not in slots:
                        self.assertEqual(letter, '-', f'{op} at {w}: slot {k} is read as "{letter}" but this record never writes it')
                        continue
                    allowed = {'obj': letter in OBJ_LETTERS, 'ptr': letter in PTR_LETTERS, 'val': letter not in VAL_FORBIDDEN}[slots[k]]
                    self.assertTrue(allowed, f'{op} at {w}: slot {k} holds {"an object" if slots[k] == "obj" else "a pointer" if slots[k] == "ptr" else "a value"}, its letter is "{letter}"')
                    if letter == 'm':
                        self.assertIn(k + 1, slots, f'{op} at {w}: slot {k} is digested as bytes whose count is slot {k + 1}, which this record never writes')


if __name__ == '__main__':
    unittest.main()
