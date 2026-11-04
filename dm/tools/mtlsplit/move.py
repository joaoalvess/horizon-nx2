#!/usr/bin/env python3
"""Moves one module of the module map out of nvn_mtl.m and the files it includes as code, verbatim, into dm/gfx/nvn/mtl_<module>.m and mtl_<module>.h.

  move.py --map <map.json> --module <name> [--unity <nvn_mtl_all.inc>] (--patch <out.patch> | --apply)

The map is modmap.py's, made on the tree as it is (the tool refuses a map whose files changed). Every line the map gives the module moves, in the order the
compiler reads them (an included .inc at its #include):
- into the header: the module's types, @interfaces, #defines and constants that other modules name, its static inline functions other modules call (when
  they hold no function-local static), and what those need in turn;
- into the .m: everything else, after a copy of nvn_mtl.m's #include and #pragma lines (with the module headers already there) and the module's header,
  closed by nvn_mtl.m's last #pragma.
The header also declares what other modules reach out of line: a function as its definition's signature, a variable as an extern of its declaration;
both hidden when the name was static. Those names lose their static (linkage edit). A line whose declarations belong to several modules is split into
the module's part and the rest; the line's trailing comment stays with the part that holds its first declaration. nvn_mtl.m includes the header after
the module headers before it (or after its #pragma clang attribute push), and the unity file includes the .m before the first module after it in the map's
order (nvn_mtl.m, the facade, being last).

It refuses when the module still needs code that stays in nvn_mtl.m (a call, a variable, a type, a macro or a local prototype of another file's function),
when a line it would split is not one declaration list, when other modules need a prototype of another file's function that moves with it, and when a
header nvn_mtl.m includes after its push holds what would make copying or skipping it change code (common.scope_problems).
--patch writes the change as a git patch (the unity file's change goes in <patch>.unity.patch when that file is outside the repository) and changes
nothing; --apply writes the files.
"""
import argparse, collections, difflib, os, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from mtlsplit.common import (HIDDEN, REPO, SOURCES, UNIT, blank_code, declarators, header_at, identifiers, load_json, module_files, prelude, read_lines, sha1,
                             statements)

DECL_KINDS = ('code', 'var', 'type', 'define', 'proto')


class Refused(Exception):
    pass


def tu_order(m, text):
    inc = {}
    for it in m['items']:
        if it['kind'] == 'include-code':
            q = re.search(r'"([^"]+)"', it.get('path', ''))
            hit = [f for f in SOURCES if q and f.endswith('/' + q.group(1).split('/')[-1])]
            if hit: inc[(it['file'], it['begin'])] = hit[0]
    seen = set()

    def walk(f):
        seen.add(f)
        for ln in range(1, len(text[f]) + 1):
            yield f, ln
            if (f, ln) in inc and inc[(f, ln)] not in seen: yield from walk(inc[(f, ln)])
    order = list(walk(UNIT))
    for f in SOURCES:
        if f not in seen: order += list(walk(f))
    return order


def strip_static(code_text, text, upto):
    """text with its first 'static' keyword before index upto removed (the linkage edit), or None when there is none."""
    m = re.search(r'\bstatic\b[ \t]*', code_text[:upto])
    return None if not m else text[:m.start()] + text[m.end():]


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


class Move:
    def __init__(self, m, module, root=REPO, unity=None):
        self.m, self.mod, self.root = m, module, pathlib.Path(root)
        if module not in m['order'] or module == m['order'][-1]: raise Refused(f'{module}: not a module the tool moves (modules.tsv, the facade last)')
        for f, v in m['files'].items():
            if sha1(self.root / f) != v['sha1']: raise Refused(f'{f} changed since the map was made (facts.py and modmap.py again)')
        self.text = {f: read_lines(self.root / f) for f in SOURCES}
        self.items = m['items']
        self.lines = m['lines']
        self.line_item = {f: [None] * (len(self.text[f]) + 1) for f in SOURCES}
        for it in self.items:
            for ln in range(it['begin'], it['end'] + 1): self.line_item[it['file']][ln] = it['id']
        self.unity = pathlib.Path(unity) if unity else None
        self.files = {}
        self.notes = collections.defaultdict(list)
        self.plan()

    def code_of(self, it):
        return blank_code('\n'.join(self.text[it['file']][it['begin'] - 1:it['end']]))

    def owner(self, f, ln):
        return self.lines[f][ln - 1]

    def item_names(self, it):
        return set(it['defines'] + it['globals'] + it['functions'] + it['protos'])

    def is_split(self, it):
        ms = {d['module'] for d in it.get('decls', ())}
        return it['kind'] != 'code' and self.mod in ms and len(ms) > 1

    def plan(self):
        M, m = self.mod, self.m
        fns, gls = m['functions'], m['globals']
        self.fM = {k for k, v in fns.items() if v['module'] == M}
        self.gM = {g for g, v in gls.items() if v['module'] == M}
        mine = [it for it in self.items if (it['module'] == M and it['kind'] in DECL_KINDS + ('other',) and not self.is_split_other(it)) or self.is_split(it)]
        self.mine = {it['id']: it for it in mine}
        for c in m['conflicts']:
            if c[0] in ('item', '#if group', 'macro defined inside a function, used by other modules') and M in c[-1]: raise Refused(f'conflict in the map: {c}')
        defined = collections.defaultdict(list)
        for it in self.items:
            if it['kind'] in DECL_KINDS + ('other',):
                for n in self.item_names(it) | {d['name'] for d in it.get('decls', ()) if d.get('name')}: defined[n].append(it['id'])
        self.defined = defined
        self.split = {i for i, it in self.mine.items() if self.is_split(it)}
        self.split_parts = {i: self.split_line(self.mine[i]) for i in self.split}
        mnames = set()
        for i, it in self.mine.items():
            mnames |= self.names_moving(it)
        self.mnames = mnames
        deps, hdr = [], self.header_names()
        for i, it in self.mine.items():
            for n in it.get('uses', ()):
                if n in mnames: continue
                where = [self.items[j] for j in defined.get(n, ()) if j not in self.mine and self.items[j]['module'] != M]
                stat = [w for w in where if self.needs_here(w, n)]
                if not stat and where and n not in hdr and not re.search(r'\bextern\b[^;]*\b' + re.escape(n) + r'\b', self.code_of(it)): stat = where
                if stat: deps.append(f'{it["file"]}:{it["begin"]} names `{n}` of {stat[0]["module"]} ({stat[0]["file"]}:{stat[0]["begin"]})')
        for k in self.fM:
            for c in fns[k]['calls'] + fns[k]['fnrefs']:
                if fns[c]['module'] != M and c not in mnames and (fns[c]['storage'] == 'static' or c not in hdr): deps.append(f'{k} calls `{c}` of {fns[c]["module"]}')
            for g in fns[k]['vars']:
                gm = (gls.get(g) or {}).get('module')
                if gm and gm != M and g not in mnames and (gls[g]['storage'] == 'static' or g not in hdr): deps.append(f'{k} uses `{g}` of {gm}')
        if deps: raise Refused('the module needs code that stays in nvn_mtl.m:\n  ' + '\n  '.join(sorted(set(deps))[:40]))
        refs = set()
        for k, v in fns.items():
            if v['module'] != M: refs |= set(v['calls']) | set(v['fnrefs']) | set(v['vars'])
        for it in self.items:
            if it['id'] in self.mine and it['id'] not in self.split: continue
            if it['kind'] in DECL_KINDS + ('other',): refs |= set(it.get('uses', ()))
        ext_protos = []
        for i, it in self.mine.items():
            if it['kind'] == 'other' and i not in self.split:
                for d in it.get('decls', ()):
                    if d['kind'] == 'FunctionDecl' and d['name'] not in fns and d['name'] in refs: ext_protos.append(f'{it["file"]}:{it["begin"]} `{d["name"]}`')
        if ext_protos: raise Refused('prototypes of other files\' functions that move with the module and that other modules use (put them in a header first):\n  ' + '\n  '.join(ext_protos))
        self.exported = (self.fM | self.gM | mnames) & refs
        self.header_items = set()
        self.closure()

    def header_names(self):
        """The names the headers nvn_mtl.m includes from the repository declare (a crude scan of their identifiers): what a module may use without a local declaration."""
        out = set()
        for t in self.text[UNIT]:
            q = re.match(r'^\s*#\s*(?:include|import)\s+"([^"]+\.h)"', t)
            if not q: continue
            p = (self.root / UNIT).parent / q.group(1)
            if p.exists() and str(p.resolve()) not in {str((self.root / f).resolve()) for f in SOURCES}:
                out |= identifiers(blank_code(p.read_text(errors='replace')))
        return out

    def is_split_other(self, it):
        ms = {d['module'] for d in it.get('decls', ())}
        return it['kind'] != 'code' and len(ms) > 1 and self.mod not in ms

    def needs_here(self, w, n):
        if w['kind'] in ('type', 'define'): return True
        if w['kind'] == 'var': return n in w['globals'] and (self.m['globals'].get(n) or {}).get('storage') == 'static' or n not in w['globals']
        if w['kind'] in ('proto', 'other'):
            fn = self.m['functions'].get(n)
            return fn is None or fn['storage'] == 'static'
        if w['kind'] == 'code':
            fn = self.m['functions'].get(n)
            return fn is not None and fn['storage'] == 'static'
        return False

    def names_moving(self, it):
        if it['id'] in self.split:
            return {d['name'] for d in it['decls'] if d['module'] == self.mod and d.get('name')}
        return self.item_names(it) | {d['name'] for d in it.get('decls', ()) if d.get('name')}

    def header_ok(self, it):
        """An item that may go into the header verbatim: a type, a macro, a constant, a static inline function with no function-local static."""
        if it['id'] in self.split: return False
        if it['kind'] in ('type', 'define'): return True
        if it['kind'] == 'var': return all(self.m['globals'][g]['const'] and g not in self.gM for g in it['globals'])
        if it['kind'] == 'code' and len(it['functions']) == 1 and not it['functions'][0].startswith(('-[', '+[')):
            fn = self.m['functions'][it['functions'][0]]
            return fn['storage'] == 'static' and fn['inline'] and not fn['static_locals'] and it.get('sub') == 'function'
        return False

    def closure(self):
        """The header holds what other modules name and what the header itself names; the rest of the exported names are declared there."""
        by_name = {}
        for i, it in self.mine.items():
            for n in self.names_moving(it): by_name.setdefault(n, i)
        todo = list(self.exported)
        seen = set()
        while todo:
            n = todo.pop()
            if n in seen: continue
            seen.add(n)
            i = by_name.get(n)
            if i is None: continue
            it = self.mine[i]
            if self.header_ok(it) and (it['kind'] != 'code' or n in it['functions']):
                if i not in self.header_items:
                    self.header_items.add(i)
                    for x in identifiers(self.code_of(it)) & self.mnames: self.exported.add(x); todo.append(x)
            else:
                for x in identifiers(self.declaration(n) or '') & self.mnames:
                    if x != n: self.exported.add(x); todo.append(x)
        for i in list(self.header_items):
            self.notes['header'].append(f'{self.mine[i]["file"]}:{self.mine[i]["begin"]}')

    def declaration(self, n):
        """The header's declaration of a name the module keeps out of line: a function's signature or a variable's extern; None for a header item or a method."""
        fns, gls = self.m['functions'], self.m['globals']
        if n in fns and fns[n]['module'] == self.mod and not n.startswith(('-[', '+[')):
            v = fns[n]
            col = next((d['cols'][0] for it in self.mine.values() for d in it.get('decls', ()) if d['name'] == n and d['body'] and d.get('cols')), 1)
            txt = '\n'.join(self.text[v['file']][v['begin'] - 1:v['end']])[col - 1:]
            code = blank_code(txt)
            mm = re.search(r'\b' + re.escape(n) + r'\s*\(', code)
            if not mm: return None
            d, i = 0, mm.end() - 1
            while i < len(code):
                if code[i] == '(': d += 1
                elif code[i] == ')':
                    d -= 1
                    if d == 0: break
                i += 1
            j = code.find('{', i)
            sig = norm(code[:j if j >= 0 else i + 1])
            sig = re.sub(r'\b(static|inline|__inline__)\b\s*', '', sig)
            sig = re.sub(r'__attribute__\(\(\s*always_inline\s*\)\)\s*', '', sig).strip()
            return (HIDDEN + ' ' if v['storage'] == 'static' else '') + sig + ';'
        if n in gls and gls[n]['module'] == self.mod:
            v = gls[n]
            txt = '\n'.join(self.text[v['file']][v['begin'] - 1:v['end']])
            code, sts = statements(txt)
            for s, e in sts or ():
                r = declarators(code, s, e)
                if not r: continue
                pe, ds = r
                for a, b, name in ds:
                    if name != n: continue
                    pre = norm(re.sub(r'\bstatic\b', '', txt[s:pe]))
                    dec = txt[a:b]
                    eq = blank_code(dec)
                    k = self.top_eq(eq)
                    dec = norm(dec[:k] if k is not None else dec)
                    return 'extern ' + (HIDDEN + ' ' if v['storage'] == 'static' else '') + pre + ' ' + dec + ';'
        return None

    @staticmethod
    def top_eq(code):
        d = 0
        for i, c in enumerate(code):
            if c in '([{': d += 1
            elif c in ')]}': d -= 1
            elif c == '=' and d == 0: return i
        return None

    def split_line(self, it):
        """(the module's part, the part that stays) of a one-line item whose declarations belong to several modules."""
        if it['begin'] != it['end']: raise Refused(f'{it["file"]}:{it["begin"]}: a split over several lines')
        text = self.text[it['file']][it['begin'] - 1]
        code, sts = statements(text)
        if not sts: raise Refused(f'{it["file"]}:{it["begin"]}: not a list of declarations')
        dm = {}
        for d in it['decls']:
            if d.get('name') and d['kind'] in ('VarDecl', 'FunctionDecl', 'TypedefDecl'): dm[d['name']] = d['module']
        for d in it['decls']:
            if d.get('name'): dm.setdefault(d['name'], d['module'])
        mine, rest, first_mine = [], [], None
        for k, (s, e) in enumerate(sts):
            r = declarators(code, s, e)
            if not r: raise Refused(f'{it["file"]}:{it["begin"]}: cannot read the declaration `{text[s:e]}`')
            pe, ds = r
            mods = [dm.get(n, it['module']) for _, _, n in ds]
            if k == 0: first_mine = mods[0] == self.mod
            if len(set(mods)) == 1:
                (mine if mods[0] == self.mod else rest).append(text[s:e])
                continue
            pre = text[s:pe]
            a = [text[x:y] for (x, y, _), mo in zip(ds, mods) if mo == self.mod]
            b = [text[x:y] for (x, y, _), mo in zip(ds, mods) if mo != self.mod]
            mine.append(pre + ', '.join(a) + ';'); rest.append(pre + ', '.join(b) + ';')
        indent = text[:sts[0][0]]
        tail = text[sts[-1][1]:]
        p_mine = indent + ' '.join(mine) + (tail if first_mine else '')
        p_rest = indent + ' '.join(rest) + ('' if first_mine else tail)
        self.notes['split'].append(f'{it["file"]}:{it["begin"]}')
        return p_mine, p_rest

    def linkage(self, f, ln, text, names):
        """The line with static dropped from each declaration that starts on it and declares an exported name."""
        code, sts = statements(text)
        if sts:
            out, last = [], 0
            for s, e in sts:
                r = declarators(code, s, e)
                piece = text[s:e]
                if r and any(n in self.exported and n in names for _, _, n in r[1]):
                    q = strip_static(code[s:e], piece, r[0] - s)
                    if q is not None: piece = q; self.notes['linkage'].append(f'{f}:{ln}')
                out.append(text[last:s] + piece); last = e
            return ''.join(out) + text[last:]
        code = blank_code(text)
        for n in names:
            if n not in self.exported: continue
            mm = re.search(r'\b' + re.escape(n) + r'\s*\(', code)
            if mm:
                q = strip_static(code, text, mm.start())
                if q is not None: self.notes['linkage'].append(f'{f}:{ln}'); return q
        return text

    def decl_starts(self):
        """{(file, line): names} of the declarations of the module's functions and variables that start on a line, for the linkage edits."""
        out = collections.defaultdict(set)
        for it in self.mine.values():
            for d in it.get('decls', ()):
                if d['module'] == self.mod and d.get('name') and d['kind'] in ('FunctionDecl', 'VarDecl') and d.get('storage') == 'static':
                    out[(it['file'], d['begin'])].add(d['name'])
        return out

    def build(self):
        M = self.mod
        order = tu_order(self.m, self.text)
        dest = {}
        for f in SOURCES:
            n = len(self.text[f])
            real = [None] * (n + 2)
            for ln in range(1, n + 1):
                i = self.line_item[f][ln]
                if i is not None and i in self.mine and self.mine[i]['kind'] != 'other':
                    real[ln] = 'h' if i in self.header_items else 'm'
            for ln in range(1, n + 1):
                i = self.line_item[f][ln]
                if i is not None and i in self.split: dest[(f, ln)] = 's'; continue
                if self.owner(f, ln) != M: continue
                if real[ln]: dest[(f, ln)] = real[ln]; continue
                d = None
                for x in range(ln + 1, n + 1):
                    j = self.line_item[f][x]
                    if j is not None and self.items[j]['kind'] != 'other':
                        d = real[x] if self.owner(f, x) == M else None
                        break
                if d is None:
                    for x in range(ln - 1, 0, -1):
                        if real[x]: d = real[x]; break
                dest[(f, ln)] = d or 'm'
            self.fix_groups(f, dest)
        starts = self.decl_starts()
        mod_m, mod_h, stay = [], [], {f: [] for f in SOURCES}
        gen = self.generated()
        placed = set()
        hdr_names = {}
        for i in self.header_items:
            for n in self.names_moving(self.mine[i]): hdr_names[n] = i
        need_after = {}
        for n, decl in gen.items():
            used = identifiers(blank_code(decl)) & set(hdr_names)
            used.discard(n)
            need_after[n] = {hdr_names[u] for u in used}
        for n in [n for n in gen if not need_after[n]]:
            mod_h.append(gen[n]); placed.add(n)
        done_items = set()
        for f, ln in order:
            d = dest.get((f, ln))
            t = self.text[f][ln - 1]
            i = self.line_item[f][ln]
            if d is None: stay[f].append(t); continue
            if d == 's':
                pm, pr = self.split_parts[i]
                names = {x['name'] for x in self.mine[i]['decls'] if x['module'] == M}
                mod_m.append(self.linkage(f, ln, pm, names) if pm.strip() else None)
                stay[f].append(pr)
                if mod_m[-1] is None: mod_m.pop()
                continue
            if (f, ln) in starts and d == 'm': t = self.linkage(f, ln, t, starts[(f, ln)])
            (mod_h if d == 'h' else mod_m).append(t)
            if d == 'h' and i is not None and i in self.header_items and ln == self.mine[i]['end']:
                done_items.add(i)
                for n in gen:
                    if n not in placed and need_after[n] <= done_items: mod_h.append(gen[n]); placed.add(n)
        for n in gen:
            if n not in placed: mod_h.append(gen[n])
        unit = stay[UNIT]
        mod_m_path, mod_h_path = module_files(M)
        hname, mname = mod_h_path.split('/')[-1], mod_m_path.split('/')[-1]
        prelude, push, pop = self.prelude(unit, identifiers(blank_code('\n'.join(mod_m + mod_h))))
        at = header_at(unit)
        unit = unit[:at] + [f'#include "{hname}"'] + unit[at:]
        stay[UNIT] = unit
        body_m = prelude + [f'#include "{hname}"'] + mod_m + ([pop] if push and pop else [])
        body_h = ['#pragma once'] + mod_h
        out = {}
        for f in SOURCES:
            if stay[f] != self.text[f]: out[f] = (self.text[f], stay[f])
        out[mod_m_path] = (None, body_m)
        out[mod_h_path] = (None, body_h)
        if self.unity:
            u = read_lines(self.unity)
            out[str(self.unity)] = (u, self.unity_insert(u, mname))
        self.files = out
        self.counts = {'moved': sum(1 for v in dest.values() if v in ('m', 'h')), 'split': len(self.split), 'header items': len(self.header_items),
                       'declarations': len(gen), 'exported': len(self.exported), 'linkage': len(set(self.notes['linkage']))}
        return out

    def fix_groups(self, f, dest):
        """A top-level #if ... #endif of the module goes whole into one file: the header when an item inside it goes there."""
        lines, stack = self.text[f], []
        for ln in range(1, len(lines) + 1):
            if self.line_item[f][ln] is not None and self.items[self.line_item[f][ln]]['kind'] != 'other': continue
            mm = re.match(r'^\s*#\s*(\w+)', lines[ln - 1])
            if not mm: continue
            dv = mm.group(1)
            if dv in ('if', 'ifdef', 'ifndef'): stack.append(ln)
            elif dv == 'endif' and stack:
                b = stack.pop()
                if stack: continue
                ds = {dest.get((f, x)) for x in range(b, ln + 1)} - {None}
                if not ds or self.owner(f, b) != self.mod: continue
                if 's' in ds: raise Refused(f'{f}:{b}: a split line inside #if')
                if 'h' in ds and 'm' in ds:
                    inner = [self.items[self.line_item[f][x]] for x in range(b, ln + 1) if self.line_item[f][x] is not None and self.items[self.line_item[f][x]]['kind'] != 'other']
                    if all(self.header_ok(it) for it in inner):
                        for it in inner: self.header_items.add(it['id'])
                        ds = {'h'}
                    else: raise Refused(f'{f}:{b}-{ln}: an #if group holds header items and code')
                for x in range(b, ln + 1): dest[(f, x)] = ds.pop() if len(ds) == 1 else 'm'

    def generated(self):
        out, lost = {}, []
        for n in sorted(self.exported):
            i = next((i for i, it in self.mine.items() if n in self.names_moving(it) and i in self.header_items), None)
            if i is not None: continue
            d = self.declaration(n)
            if d: out[n] = d
            elif not (n in self.m['functions'] or any(n in it['defines'] and it['kind'] == 'code' for it in self.mine.values())): lost.append(n)
        if lost: raise Refused('names other modules use that neither move into the header nor get a declaration there: ' + ', '.join(lost))
        return out

    def prelude(self, unit, used):
        """The module's prelude (common.prelude), refused when a header nvn_mtl.m includes after its push fails the header rule."""
        def read(path):
            p = self.root / path
            return p.read_text(errors='replace') if p.is_file() else None
        try: return prelude(unit, used, read)
        except ValueError as e: raise Refused(str(e)) from None

    def unity_insert(self, u, mname):
        line = f'#include "{mname}"'
        if line in u: return list(u)
        lv = {mo: i for i, mo in enumerate(self.m['order'])}
        me = lv[self.mod]
        for i, t in enumerate(u):
            mm = re.match(r'^\s*#\s*include\s+"(?:mtl_(\w+)|(nvn_mtl))\.m"', t)
            if not mm: continue
            other = mm.group(1) or 'facade'
            if lv.get(other, len(lv)) > me: return u[:i] + [line] + u[i:]
        raise Refused(f'{self.unity}: no #include of nvn_mtl.m (the facade) to put the module before')


def diff(path, old, new, label):
    a = [x + '\n' for x in (old or [])]; b = [x + '\n' for x in new]
    head = [f'diff --git a/{label} b/{label}\n']
    if old is None: head += ['new file mode 100644\n']
    body = list(difflib.unified_diff(a, b, '/dev/null' if old is None else f'a/{label}', f'b/{label}', n=3))
    return head + body if body else []


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--map', required=True)
    ap.add_argument('--module', required=True)
    ap.add_argument('--unity')
    ap.add_argument('--root', default=str(REPO))
    ap.add_argument('-v', '--verbose', action='store_true')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--patch')
    g.add_argument('--apply', action='store_true')
    a = ap.parse_args(argv)
    root = pathlib.Path(a.root).resolve()
    try:
        mv = Move(load_json(a.map), a.module, root, a.unity)
        files = mv.build()
    except Refused as e:
        print(f'[RED] move {a.module}: {e}', file=sys.stderr)
        return 1
    if a.patch:
        main_p, uni_p = [], []
        for path, (old, new) in files.items():
            ap_ = pathlib.Path(path) if os.path.isabs(path) else root / path
            try: label = str(ap_.resolve().relative_to(root))
            except ValueError: label = None
            if label is None: uni_p += diff(path, old, new, ap_.name)
            else: main_p += diff(path, old, new, label)
        pathlib.Path(a.patch).write_text(''.join(main_p))
        if uni_p: pathlib.Path(a.patch + '.unity.patch').write_text(''.join(uni_p))
    else:
        for path, (old, new) in files.items():
            p = pathlib.Path(path) if os.path.isabs(path) else root / path
            if old is None and p.exists(): print(f'[RED] move {a.module}: {path} exists', file=sys.stderr); return 1
        for path, (old, new) in files.items():
            p = pathlib.Path(path) if os.path.isabs(path) else root / path
            p.write_text(''.join(x + '\n' for x in new), encoding='utf-8', errors='surrogateescape')
    if a.verbose:
        for k in ('header', 'split', 'linkage'): print(f'  {k}: ' + ' '.join(sorted(set(mv.notes[k]))), file=sys.stderr)
        print('  exported: ' + ' '.join(sorted(mv.exported)), file=sys.stderr)
    c = mv.counts
    print(f'move {a.module}: {c["moved"]} lines moved ({c["header items"]} header items), {c["split"]} lines split, {c["linkage"]} linkage edits, '
          f'{c["declarations"]} declarations in the header; ' + (f'patch {a.patch}' if a.patch else 'applied'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
