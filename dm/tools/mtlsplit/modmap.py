#!/usr/bin/env python3
"""The module map of nvn_mtl.m: which module owns each line of nvn_mtl.m and of the files it includes as code, and how the modules depend on each other.

  modmap.py --facts <facts.json> --out <map.json> [--report <map.md>] [--strict]

Inputs: the facts of the tree (facts.py) and the tables beside this file: modules.tsv (the modules in extraction order), functions.tsv and globals.tsv (the
module of each function and the owner of each variable), cuts.tsv (the upward references the plan cuts before the moves).

The source is divided into items: one per top-level declaration (declarations that share a line form one item) and one per preprocessor directive.
- A function, an @implementation, a variable: the tables' module (an @implementation without methods: its @interface's). A function or variable without a row is listed under "new" and placed: a function in
  the module of the function before it in its file, a variable in the module that writes it most, a constant (no writer) like a type.
- A prototype: the module of the function it declares; one of another file's function (hle_nvn.c's) goes like a type.
- A type, an @interface, a #define, a constant without a row: the lowest module (extraction order) among the items that name it, so that every user sees
  it; with no user, the module of the next item.
- An #include of a header and a #pragma stay in nvn_mtl.m (facade); module files repeat them.
- Other lines (comments, blank lines, code the host does not compile) go with the next item below; a file's last lines with the item above.
- A top-level #if ... #endif goes whole with the module of the items inside it; with several, it is listed as a conflict.

Rows of a module already moved (its dm/gfx/nvn/mtl_<module>.m exists) are not stale when their names are gone from the files.

Edges: a call or a variable access from a function of one module to another module's. The layering check lists every edge that points up (to a later
module), apart from cuts.tsv's rows, calls to mtl_init (the lazy-init wrappers, which stay in facade) and calls from below into dump or capture (the
hook table, cut 2), which are listed apart. --strict exits 1 when an upward edge or a conflict remains.
"""
import argparse, collections, json, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from mtlsplit.common import HERE, REPO, SOURCES, UNIT, blank_code, identifiers, module_files, read_lines, save_json, sha1

DIAG = ('dump', 'capture')
PRELUDE = 'facade'
TYPE_KINDS = ('TypedefDecl', 'RecordDecl', 'EnumDecl', 'ObjCInterfaceDecl', 'ObjCProtocolDecl', 'ObjCCategoryDecl')
DIRECTIVE = re.compile(r'^\s*#\s*(\w+)\s*(.*)$')


def read_table(path):
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        if line and not line.startswith('#'): rows.append(line.split('\t'))
    return rows


def load_tables(d=HERE):
    order = [r[1] for r in read_table(pathlib.Path(d) / 'modules.tsv')]
    fmod = {r[1]: r[0] for r in read_table(pathlib.Path(d) / 'functions.tsv')}
    gmod = {r[1]: r[0] for r in read_table(pathlib.Path(d) / 'globals.tsv')}
    cuts = {(r[0], r[1], r[2]): r[3] for r in read_table(pathlib.Path(d) / 'cuts.tsv')}
    return order, fmod, gmod, cuts


def directives(lines):
    """{line: (directive, argument, last line)} of the preprocessor lines (with their backslash continuations)."""
    out, i = {}, 0
    while i < len(lines):
        m = DIRECTIVE.match(lines[i])
        if m:
            j = i
            while lines[j].endswith('\\') and j + 1 < len(lines): j += 1
            out[i + 1] = (m.group(1), m.group(2), j + 1)
            i = j + 1
        else: i += 1
    return out


class Map:
    def __init__(self, facts, order, fmod, gmod, cuts, root=REPO):
        self.facts, self.order, self.root = facts, order, root
        self.lv = {m: i for i, m in enumerate(order)}
        self.fmod_t, self.gmod_t, self.cuts = fmod, gmod, cuts
        self.text = {f: read_lines(root / f) for f in SOURCES}
        self.fns = {k: v for k, v in facts['functions'].items() if v['body'] and not k.startswith('@init:')}
        self.globals = facts['globals']
        self.new, self.conflicts, self.stale = [], [], []
        self.items, self.line_item = [], {f: [None] * (len(self.text[f]) + 1) for f in SOURCES}
        self.build_items()
        self.assign()
        self.edges()

    def low(self, mods):
        mods = [m for m in mods if m in self.lv]
        return min(mods, key=self.lv.__getitem__) if mods else None

    def add_item(self, f, b, e, kind, **kw):
        it = {'id': len(self.items), 'file': f, 'begin': b, 'end': e, 'kind': kind, 'defines': [], 'functions': [], 'globals': [], 'protos': [], 'module': None}
        it.update(kw)
        self.items.append(it)
        for ln in range(b, e + 1): self.line_item[f][ln] = it['id']
        return it

    def build_items(self):
        by_file = collections.defaultdict(list)
        for d in self.facts['decls']: by_file[d['file']].append(d)
        for f in SOURCES:
            spans = sorted(((d['begin'], max(d['end'], d['begin']), d) for d in by_file[f]), key=lambda t: (t[0], t[1], t[2]['id']))
            groups = []
            for b, e, d in spans:
                if groups and b <= groups[-1][1]: groups[-1][1] = max(groups[-1][1], e); groups[-1][2].append(d)
                else: groups.append([b, e, [d]])
            for b, e, ds in groups: self.decl_item(f, b, e, ds)
            dirs = directives(self.text[f])
            for ln, (dv, arg, last) in sorted(dirs.items()):
                if self.line_item[f][ln] is not None: continue
                if dv == 'define':
                    m = re.match(r'(\w+)', arg)
                    self.add_item(f, ln, last, 'define', defines=[m.group(1)] if m else [])
                elif dv in ('include', 'import'):
                    code = re.search(r'"([^"]+\.(?:inc|m)|nvn_rec\.h)"', arg)
                    self.add_item(f, ln, last, 'include-code' if code else 'include', path=arg.split('//')[0].strip())
                elif dv in ('if', 'ifdef', 'ifndef', 'elif', 'else', 'endif'):
                    pass
                else:
                    self.add_item(f, ln, last, 'directive', directive=dv)
        self.inner_defines = []
        for it in self.items:
            if it['kind'] != 'code': continue
            for ln in range(it['begin'], it['end'] + 1):
                m = DIRECTIVE.match(self.text[it['file']][ln - 1])
                if m and m.group(1) == 'define':
                    n = re.match(r'(\w+)', m.group(2))
                    if n: self.inner_defines.append((n.group(1), it['id']))

    def decl_item(self, f, b, e, ds):
        kinds = {d['kind'] for d in ds}
        fns, gls, protos, defs = [], [], [], []
        for d in ds:
            k = d['kind']
            if k == 'FunctionDecl' and d.get('body'): fns.append(d['name'])
            elif k == 'FunctionDecl': protos.append(d['name'])
            elif k == 'ObjCImplementationDecl': fns.extend(d.get('methods') or []); defs.append(d['name'])
            elif k == 'VarDecl' and d.get('storage') != 'extern' and d['name'] in self.globals: gls.append(d['name'])
            elif k in TYPE_KINDS:
                if d.get('name'): defs.append(d['name'])
                defs.extend(d.get('consts') or [])
        if 'ObjCImplementationDecl' in kinds: kind = 'impl'
        elif fns: kind = 'function'
        elif gls: kind = 'var'
        elif protos and not (kinds - {'FunctionDecl'}): kind = 'proto'
        elif kinds & set(TYPE_KINDS): kind = 'type'
        else: kind = 'other-decl'
        defs = [x for x in dict.fromkeys(defs) if x]
        self.add_item(f, b, e, 'code' if kind in ('function', 'impl') else kind, sub=kind, functions=fns, globals=gls, protos=protos, defines=defs)

    def item_code(self, it):
        return blank_code('\n'.join(self.text[it['file']][it['begin'] - 1:it['end']]))

    def assign(self):
        root = self.root
        fmod = {}
        for f in SOURCES:
            last = None
            for it in self.items_of(f):
                for k in it['functions']:
                    if k in self.fmod_t: fmod[k] = self.fmod_t[k]
                    else:
                        fmod[k] = last or (self.order[0] if f == UNIT else self.order[-1]); self.new.append(('function', k, fmod[k]))
                    last = fmod[k]
        self.fmod = fmod
        moved = {mo for mo in self.order if (root / module_files(mo)[0]).exists()}
        for k in self.fmod_t:
            if k not in self.fns and self.fmod_t[k] not in moved: self.stale.append(('functions.tsv', k))
        gmod = {}
        for g, v in self.globals.items():
            if g in self.gmod_t: gmod[g] = self.gmod_t[g]
        for g in self.gmod_t:
            if g not in self.globals and self.gmod_t[g] not in moved: self.stale.append(('globals.tsv', g))
        for g, v in self.globals.items():
            if g in gmod or v['const']: continue
            w = collections.Counter(self.fmod[k] for k, acc in v['refs'].items() if k in self.fmod and ('W' in acc or 'P' in acc))
            r = collections.Counter(self.fmod[k] for k, acc in v['refs'].items() if k in self.fmod)
            gmod[g] = (w or r).most_common(1)[0][0] if (w or r) else None
            self.new.append(('global', g, gmod[g]))
        self.gmod = gmod
        defined = collections.defaultdict(list)
        for it in self.items:
            if it['kind'] in ('code', 'var', 'type', 'define', 'proto'):
                for n in dict.fromkeys(it['defines'] + it['globals'] + it['functions'] + it['protos']): defined[n].append(it['id'])
        self.defined = defined
        ids = {}
        for it in self.items:
            if it['kind'] in ('include', 'include-code', 'directive'): continue
            ids[it['id']] = identifiers(self.item_code(it))
        names_of = {it['id']: set(it['defines'] + it['globals'] + it['functions'] + it['protos']) for it in self.items}
        users = collections.defaultdict(set)
        for i, s in ids.items():
            for n in s:
                if n in names_of[i] and self.items[i]['kind'] not in ('type', 'define'): continue
                for j in defined.get(n, ()):
                    if j != i and self.visible(j, i): users[j].add(i)
        for it in self.items:
            it['uses'] = sorted(n for n in ids.get(it['id'], ()) if n in defined and any(j != it['id'] and self.visible(j, it['id']) for j in defined[n]) and n not in names_of[it['id']])
        self.ids, self.users = ids, users
        mod = {}
        floating = []
        for it in self.items:
            k = it['kind']
            if k == 'code':
                ms = {self.fmod[x] for x in it['functions']}
                if len(ms) > 1: self.conflicts.append(('item', it['file'], it['begin'], sorted(ms)))
                mod[it['id']] = self.low(ms)
            elif k == 'var':
                ms = {self.gmod.get(g) for g in it['globals']}
                consts = [g for g in it['globals'] if self.globals[g]['const'] and g not in self.gmod_t]
                if consts and len(consts) == len(it['globals']): floating.append(it); continue
                ms.discard(None)
                mod[it['id']] = self.low(ms) if ms else None
                if mod[it['id']] is None: floating.append(it)
            elif k == 'proto':
                ms = {self.fmod[x] for x in it['protos'] if x in self.fmod}
                if ms: mod[it['id']] = self.low(ms)
                else: it['kind'] = 'other'; floating.append(it)
            elif k in ('type', 'define'):
                floating.append(it)
            elif k in ('include', 'include-code') or (k == 'directive' and it.get('directive') == 'pragma'):
                mod[it['id']] = PRELUDE
            else:
                it['kind'] = 'other'
        changed = True
        fl = {it['id'] for it in floating}
        while changed:
            changed = False
            for it in floating:
                ums = [mod.get(u) for u in users[it['id']]]
                m = self.low(ums)
                if m is not None and mod.get(it['id']) != m and (mod.get(it['id']) is None or self.lv[m] < self.lv[mod[it['id']]]):
                    mod[it['id']] = m; changed = True
        for it in self.items:
            if it['kind'] == 'code' and not it['functions'] and it.get('sub') == 'impl':
                mod[it['id']] = next((mod.get(j) for n in it['defines'] for j in defined.get(n, ()) if self.items[j]['kind'] == 'type' and mod.get(j)), None)
        for it in self.items:
            if it['id'] in mod and mod[it['id']] is not None: it['module'] = mod[it['id']]
        self.attach()
        for it in self.items:
            if it['id'] in fl:
                it['owner_rule'] = 'lowest user' if users[it['id']] else 'next item'
            if it['kind'] == 'var':
                for g in it['globals']:
                    if g not in self.gmod or self.gmod[g] is None: self.gmod[g] = it['module']
        self.groups()
        self.decl_modules()
        for name, iid in self.inner_defines:
            us = {self.items[u]['module'] for u, s in ids.items() if name in s and u != iid}
            if us - {self.items[iid]['module']}: self.conflicts.append(('macro defined inside a function, used by other modules', name, self.items[iid]['file'], self.items[iid]['begin'], sorted(us)))

    def visible(self, j, i):
        a, b = self.items[j], self.items[i]
        return a['file'] != b['file'] or a['begin'] <= b['begin']

    def decl_modules(self):
        """The module of each declaration of an item (item['decls']); an item whose declarations belong to several modules is a split, listed as a conflict."""
        by_item = collections.defaultdict(list)
        for d in self.facts['decls']:
            i = self.line_item[d['file']][d['begin']]
            if i is not None: by_item[i].append(d)
        for it in self.items:
            ds = sorted(by_item.get(it['id'], ()), key=lambda d: (d['begin'], d.get('cols', [0])[0], d['id']))
            out = []
            for d in ds:
                k, n, m = d['kind'], d.get('name'), None
                if k == 'FunctionDecl': m = self.fmod.get(n)
                elif k == 'ObjCImplementationDecl': m = it['module']
                elif k == 'VarDecl' and d.get('storage') != 'extern' and n in self.globals: m = self.gmod.get(n)
                elif k in TYPE_KINDS and it['kind'] not in ('type',):
                    us = set()
                    for nm in [n] + (d.get('consts') or []):
                        us |= {self.items[u]['module'] for u, s in self.ids.items() if nm in s and u != it['id'] and self.visible(it['id'], u)}
                    m = self.low(us)
                out.append({'kind': k, 'name': n, 'begin': d['begin'], 'end': d['end'], 'cols': d.get('cols'), 'storage': d.get('storage'), 'inline': d.get('inline'),
                            'body': bool(d.get('body')), 'module': m or it['module']})
            it['decls'] = out
            ms = sorted({d['module'] for d in out}, key=self.lv.__getitem__)
            if len(ms) > 1 and it['kind'] != 'code': self.conflicts.append(('split', it['file'], it['begin'], ms))

    def items_of(self, f):
        return sorted((it for it in self.items if it['file'] == f), key=lambda it: it['begin'])

    def attach(self):
        """Lines outside items and items without a module go with the next item below that has one; a file's last lines with the item above."""
        self.line_mod = {}
        for f in SOURCES:
            n = len(self.text[f])
            lm = [None] * (n + 1)
            for ln in range(1, n + 1):
                i = self.line_item[f][ln]
                if i is not None and self.items[i]['module']: lm[ln] = self.items[i]['module']
            nxt = None
            for ln in range(n, 0, -1):
                if lm[ln] is None: lm[ln] = nxt
                else: nxt = lm[ln]
            last = None
            for ln in range(1, n + 1):
                if lm[ln] is None: lm[ln] = last or PRELUDE
                last = lm[ln]
            self.line_mod[f] = lm
            for it in self.items_of(f):
                if it['module'] is None: it['module'] = lm[it['begin']]

    def groups(self):
        for f in SOURCES:
            lines, lm = self.text[f], self.line_mod[f]
            stack = []
            for ln in range(1, len(lines) + 1):
                if self.line_item[f][ln] is not None and self.items[self.line_item[f][ln]]['kind'] not in ('other',): continue
                m = DIRECTIVE.match(lines[ln - 1])
                if not m: continue
                dv = m.group(1)
                if dv in ('if', 'ifdef', 'ifndef'): stack.append(ln)
                elif dv == 'endif' and stack:
                    b = stack.pop()
                    if stack: continue
                    ms = set()
                    for x in range(b + 1, ln):
                        i = self.line_item[f][x]
                        if i is not None and self.items[i]['kind'] not in ('other',): ms.add(self.items[i]['module'])
                    if len(ms) > 1: self.conflicts.append(('#if group', f, b, ln, sorted(ms))); continue
                    m_ = ms.pop() if ms else lm[ln + 1] if ln < len(lines) else lm[ln]
                    for x in range(b, ln + 1): lm[x] = m_
            for x in range(1, len(lines) + 1):
                i = self.line_item[f][x]
                if i is not None and self.items[i]['kind'] != 'other' and lm[x] != self.items[i]['module']: lm[x] = self.items[i]['module']

    def edges(self):
        calls = collections.defaultdict(collections.Counter)
        data = collections.defaultdict(collections.Counter)
        self.upward, self.hooks, self.cut_hits = [], [], collections.Counter()
        self.call_pairs, self.data_pairs = collections.defaultdict(set), collections.defaultdict(set)
        for k, fn in self.fns.items():
            ma = self.fmod[k]
            for c in fn['calls']:
                if c not in self.fmod or c == k: continue
                mb = self.fmod[c]
                if ma == mb: continue
                if ('call', fn['name'], c) in self.cuts: self.cut_hits[('call', fn['name'], c)] += 1; continue
                if c == 'mtl_init': continue
                if mb in DIAG and self.lv[ma] < self.lv[mb]: self.hooks.append((ma, k, mb, c)); continue
                calls[ma][mb] += 1; self.call_pairs[(ma, mb)].add((k, c))
                if self.lv[ma] < self.lv[mb]: self.upward.append(('call', ma, k, mb, c))
            for c in fn['fnrefs']:
                mb = self.fmod.get(c)
                if mb and mb != ma and self.lv[ma] < self.lv[mb] and ('call', fn['name'], c) not in self.cuts: self.upward.append(('fnref', ma, k, mb, c))
            for g in fn['vars']:
                mb = self.gmod.get(g)
                if mb is None or mb == ma: continue
                if ('data', fn['name'], g) in self.cuts: self.cut_hits[('data', fn['name'], g)] += 1; continue
                data[ma][mb] += 1; self.data_pairs[(ma, mb)].add((k, g))
                if self.lv[ma] < self.lv[mb]: self.upward.append(('data', ma, k, mb, g))
        for k, fn in self.facts['functions'].items():
            if not k.startswith('@init:') or self.gmod.get(k[6:]) is None: continue
            ma = self.gmod[k[6:]]
            for n in list(fn['calls']) + fn['fnrefs']:
                mb = self.fmod.get(n)
                if mb and self.lv[ma] < self.lv[mb]: self.upward.append(('init', ma, k, mb, n))
            for g in fn['vars']:
                mb = self.gmod.get(g)
                if mb and self.lv[ma] < self.lv[mb]: self.upward.append(('init', ma, k, mb, g))
        for it in self.items:
            if it['kind'] in ('type', 'define', 'var', 'proto', 'code', 'other'):
                for n in it['uses']:
                    for j in (self.items[x] for x in self.defined[n] if x != it['id'] and self.visible(x, it['id'])):
                        jm = next((d['module'] for d in j.get('decls', ()) if d['name'] == n), j['module'])
                        if j['kind'] in ('type', 'define', 'var') and jm != it['module'] and self.lv.get(it['module'], 0) < self.lv.get(jm, 0):
                            if j['kind'] == 'var' and it['kind'] == 'code' and n in j['globals']: continue
                            self.upward.append(('name', it['module'], f'{it["file"]}:{it["begin"]}', jm, n)); break
        for c in self.cuts:
            if c not in self.cut_hits: self.stale.append(('cuts.tsv', '\t'.join(c)))
        self.calls, self.data = calls, data

    def sizes(self):
        c = collections.Counter()
        for f in SOURCES: c.update(self.line_mod[f][1:])
        return c

    def to_json(self):
        fns = {k: {'module': self.fmod[k], 'file': v['file'], 'begin': v['begin'], 'end': v['end'], 'storage': v['storage'], 'inline': v['inline'],
                   'static_locals': v['static_locals'], 'calls': sorted(c for c in v['calls'] if c in self.fmod), 'fnrefs': sorted(c for c in v['fnrefs'] if c in self.fmod),
                   'vars': v['vars']} for k, v in self.fns.items()}
        gls = {g: {'module': self.gmod.get(g), **{k: v[k] for k in ('file', 'begin', 'end', 'type', 'storage', 'tls', 'const', 'anon')}} for g, v in self.globals.items()}
        items = [{k: it[k] for k in ('id', 'file', 'begin', 'end', 'kind', 'sub', 'module', 'defines', 'functions', 'globals', 'protos', 'uses', 'decls', 'path', 'owner_rule') if k in it}
                 for it in self.items]
        return {'version': 1, 'files': {f: {'lines': len(self.text[f]), 'sha1': sha1(self.root / f)} for f in SOURCES}, 'order': self.order,
                'functions': fns, 'globals': gls, 'items': items, 'lines': {f: self.line_mod[f][1:] for f in SOURCES},
                'calls': {a: dict(b) for a, b in self.calls.items()}, 'data': {a: dict(b) for a, b in self.data.items()},
                'upward': self.upward, 'hooks': self.hooks, 'conflicts': self.conflicts, 'new': self.new, 'stale': self.stale,
                'sizes': dict(self.sizes())}


def tests_by_module(m, root=REPO):
    td = root / 'dm/gfx/tests'
    tok = collections.defaultdict(set)
    for p in sorted(td.glob('*.[mc]')):
        for t in identifiers(blank_code(p.read_text(errors='replace'))): tok[t].add(p.name)
    generic = {'S', 'R', 'draw', 'post', 'blit', 'attach', 'dispatch', 'shot', 'passdump', 'bootprof', 'rec', 'sp_on'}
    out = collections.defaultdict(set)
    for k, v in m.fmod.items():
        if len(k) >= 4 and k not in generic: out[v] |= tok.get(k, set())
    for g, v in m.gmod.items():
        if v and len(g) >= 4 and g not in generic: out[v] |= tok.get(g, set())
    return out


def report(m, root=REPO):
    sizes = m.sizes()
    nf = collections.Counter(m.fmod.values())
    ng = collections.Counter(v for v in m.gmod.values() if v)
    called = collections.defaultdict(set); in_edges = collections.Counter()
    for (a, b), pairs in m.call_pairs.items():
        for _, c in pairs: called[b].add(c)
        in_edges[b] += len(pairs)
    tests = tests_by_module(m, root)
    out = ['# Module map of nvn_mtl.m', '', 'Made by `dm/tools/mtlsplit/modmap.py` from the facts of the tree (files: ' +
           ', '.join(f'`{f.split("/")[-1]}` {len(m.text[f])}' for f in SOURCES) + f'; {sum(sizes.values())} lines, {len(m.fns)} functions, {len(m.globals)} variables).', '',
           '| # | Module | Lines | Fns | Globals | Called by others: fns / edges | Calls into | Data from | Tests |', '|---|---|---|---|---|---|---|---|---|']
    for i, mo in enumerate(m.order):
        ci = ', '.join(f'{x} {n}' for x, n in sorted(m.calls.get(mo, {}).items(), key=lambda t: m.lv[t[0]]))
        di = ', '.join(sorted({x for x in m.data.get(mo, {})} - set(m.calls.get(mo, {})), key=m.lv.__getitem__))
        out.append(f'| {i + 1} | {mo} | {sizes.get(mo, 0)} | {nf.get(mo, 0)} | {ng.get(mo, 0)} | {len(called[mo])} / {in_edges[mo]} | {ci or "-"} | {di or "-"} | {len(tests.get(mo, ()))} |')
    out += ['', f'Call edges {sum(sum(c.values()) for c in m.calls.values())}, data edges {sum(sum(c.values()) for c in m.data.values())} (distinct function pairs and function-variable pairs across modules).', '']
    out += ['## Upward references', ''] + ([f'- {k} {a} `{x}` → {b} `{y}`' for k, a, x, b, y in m.upward] or ['None.']) + ['']
    out += ['## Hook calls (cut 2)', ''] + ([f'- {a} `{x}` → {b} `{y}`' for a, x, b, y in m.hooks] or ['None.']) + ['']
    out += ['## Conflicts', ''] + ([f'- {c}' for c in m.conflicts] or ['None.']) + ['']
    out += ['## Not in the tables', ''] + ([f'- {k} `{n}` → {mo}' for k, n, mo in m.new] or ['None.']) + ['']
    out += ['## Stale rows', ''] + ([f'- {t}: `{r}`' for t, r in m.stale] or ['None.']) + ['']
    return '\n'.join(out) + '\n'


def build(facts_path, tables=HERE, root=REPO):
    facts = json.loads(pathlib.Path(facts_path).read_text())
    for f, v in facts['files'].items():
        if sha1(root / f) != v['sha1']: sys.exit(f'[RED] modmap: {f} changed since the facts were made (facts.py again)')
    return Map(facts, *load_tables(tables), root=root)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--facts', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--report')
    ap.add_argument('--tables', default=str(HERE))
    ap.add_argument('--strict', action='store_true')
    a = ap.parse_args(argv)
    m = build(a.facts, a.tables)
    save_json(a.out, m.to_json())
    if a.report: pathlib.Path(a.report).write_text(report(m))
    print(f'modmap: {a.out}: {len(m.order)} modules, {len(m.items)} items; upward {len(m.upward)}, hook calls {len(m.hooks)}, conflicts {len(m.conflicts)}, '
          f'new {len(m.new)}, stale {len(m.stale)}')
    return 1 if a.strict and (m.upward or m.conflicts) else 0


if __name__ == '__main__':
    sys.exit(main())
