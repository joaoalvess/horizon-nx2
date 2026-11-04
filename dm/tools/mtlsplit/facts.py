#!/usr/bin/env python3
"""The facts of nvn_mtl.m's translation unit, from clang's AST: every top-level declaration of nvn_mtl.m and the files it includes as code (SOURCES), with
its line range; per function, its calls, the functions it names and the globals it reads (R), writes (W) or takes the address of (P); per global, its type.

  facts.py --game <id> --out <facts.json> [--ast <ast.gz>] [--reuse]

The compile line is the host's (make -n of dm/host, through lint_c.py), so the AST is the one the host compiles. --ast keeps the dump (gzip), --reuse parses a
kept dump instead of running clang. Methods are keyed -[Class sel] / +[Class sel]; blocks count for the function that holds them.
"""
import argparse, gzip, io, os, pathlib, re, shutil, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from mtlsplit.common import REPO, SOURCES, blank_code, read_lines, save_json, sha1

LOC = re.compile(r"<invalid sloc>|<built-in>:\d+:\d+|<scratch space>:\d+:\d+|line:(\d+):(\d+)|col:(\d+)|([^\s<>,=]+):(\d+):(\d+)")
NODE = re.compile(r"^([| `-]*)([A-Za-z]+)(?: 0x([0-9a-f]+))?(.*)$")
TOP_KINDS = {'FunctionDecl', 'VarDecl', 'TypedefDecl', 'RecordDecl', 'EnumDecl', 'ObjCInterfaceDecl', 'ObjCImplementationDecl', 'ObjCCategoryDecl',
             'ObjCCategoryImplDecl', 'ObjCProtocolDecl', 'StaticAssertDecl', 'EmptyDecl', 'FileScopeAsmDecl'}
WRITE_ATOM = ('store', 'exchange', 'fetch', 'compare', 'init')


def host_compile_args(game):
    """The host's clang arguments for nvn_mtl.m (directory, argv without -c / -o), from make's dry run of dm/host."""
    import lint_c
    subprocess.run(['make', '-s', '-C', str(REPO / 'dm/host'), f'GAME={game}', 'game_profile'], check=True)
    sysroot = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    for cwd, line in lint_c.dry_run('dm/host', ['dmhost'], game):
        for e in lint_c.entries(cwd, line, sysroot):
            if e['file'].endswith('/dm/gfx/nvn/nvn_mtl.m'):
                args = [a for a in e['arguments'][1:-2] if not a.startswith(('-O', '-flto', '-g'))]
                return e['directory'], args
    sys.exit('[RED] facts: no compile line for nvn_mtl.m in make -n -B -C dm/host dmhost')


def run_clang(game, ast_path):
    cwd, args = host_compile_args(game)
    clang = shutil.which('clang') or 'clang'
    cmd = [clang, *args, '-fsyntax-only', '-Wno-everything', '-Xclang', '-ast-dump', '-fno-color-diagnostics', str(REPO / 'dm/gfx/nvn/nvn_mtl.m')]
    with gzip.open(ast_path, 'wb', compresslevel=3) as out:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE)
        assert p.stdout is not None
        shutil.copyfileobj(p.stdout, out, 1 << 20)
        if p.wait() != 0: sys.exit(f'[RED] facts: clang exited {p.returncode}: {" ".join(cmd)}')


def norm(f, base):
    if f is None: return None
    p = os.path.normpath(os.path.join(base, f)) if not f.startswith('/') else f
    try: return pathlib.Path(p).resolve().relative_to(REPO).as_posix()
    except ValueError: return p


def classify(stack):
    """How the DeclRefExpr on top of stack uses its variable: R read, W write, P address taken (passed to a call or stored), M message receiver."""
    i = len(stack) - 1
    child = stack[i]
    while i > 0:
        p = stack[i - 1]
        k, r = p['k'], p['r']
        if k in ('ParenExpr', 'MemberExpr') or (k == 'ImplicitCastExpr' and ('<ArrayToPointerDecay>' in r or '<NoOp>' in r)):
            child = p; i -= 1; continue
        if k == 'ArraySubscriptExpr':
            if child['i'] == 0: child = p; i -= 1; continue
            return 'R'
        if k in ('ImplicitCastExpr', 'CStyleCastExpr'): return 'R'
        if k == 'BinaryOperator': return 'W' if "'='" in r and child['i'] == 0 else 'R'
        if k == 'CompoundAssignOperator': return 'W' if child['i'] == 0 else 'R'
        if k == 'UnaryOperator':
            if "'++'" in r or "'--'" in r: return 'W'
            if "'&'" in r:
                if i >= 2 and stack[i - 2]['k'] == 'AtomicExpr':
                    m = re.search(r'(__c11_atomic_\w+|__atomic_\w+)', stack[i - 2]['r'])
                    return 'W' if m and any(w in m.group(1) for w in WRITE_ATOM) else 'R'
                return 'P'
            return 'R'
        if k == 'AtomicExpr':
            m = re.search(r'(__c11_atomic_\w+|__atomic_\w+)', r)
            return 'W' if m and any(w in m.group(1) for w in WRITE_ATOM) else 'R'
        if k == 'ObjCMessageExpr': return 'R'
        if k == 'CallExpr': return 'P'
        if k in ('PseudoObjectExpr', 'ObjCPropertyRefExpr'): child = p; i -= 1; continue
        return 'R'
    return 'R'


def is_const(typ):
    t = typ.replace('__strong ', '')
    if re.search(r'\*\s*const\s*(\[|$)', t): return True
    if t.startswith('const ') and '*' not in t: return True
    return bool(re.match(r'^const [^*]*\[', t))


class Parser:
    def __init__(self, ours, base):
        self.ours, self.base = set(ours), base
        self.lastf, self.lastl = None, 0
        self.decls, self.functions, self.globals, self.var_addr = [], {}, {}, {}
        self.stack = []
        self.top = None
        self.impl = None

    def locs(self, rest):
        q = rest.find("'")
        part = rest if q < 0 else rest[:q]
        out = []
        for m in LOC.finditer(part):
            if m.group(0).startswith('<'): out.append((None, 0, 0)); continue
            if m.group(1): self.lastl = int(m.group(1)); out.append((self.lastf, self.lastl, int(m.group(2))))
            elif m.group(3): out.append((self.lastf, self.lastl, int(m.group(3))))
            else: self.lastf = m.group(4); self.lastl = int(m.group(5)); out.append((self.lastf, self.lastl, int(m.group(6))))
        return out

    def our_file(self, f):
        n = norm(f, self.base)
        return n if n in self.ours else None

    def fn_entry(self, key, name, cls, f, b, e, storage='', inline=False):
        fn = self.functions.setdefault(key, {'name': name, 'class': cls, 'file': f, 'begin': b, 'end': e, 'storage': storage, 'inline': inline, 'body': False,
                                             'calls': {}, 'fnrefs': [], 'vars': {}, 'static_locals': []})
        return fn

    def line(self, raw):
        m = NODE.match(raw)
        if not m: return
        pre, kind, addr, rest = m.groups()
        depth = len(pre) // 2
        locs = self.locs(rest)
        if depth <= 1: self.stack = []
        while self.stack and self.stack[-1]['d'] >= depth: self.stack.pop()
        parent = self.stack[-1] if self.stack else None
        idx = 0
        if parent is not None: idx = parent['n']; parent['n'] += 1
        node = {'d': depth, 'k': kind, 'r': rest, 'n': 0, 'i': idx, 'fn': parent['fn'] if parent else None}
        if depth == 1:
            self.top = self.impl = None
            if kind in TOP_KINDS: self.top_decl(kind, addr, rest, locs, node)
            if self.top is None: return
        elif self.top is None:
            return
        self.stack.append(node)
        if kind == 'ObjCMethodDecl' and depth == 2 and self.impl:
            mm = re.search(r'\s([-+]) ([\w:]+)', rest)
            sel = f'{mm.group(1)}[{self.impl["name"]} {mm.group(2)}]' if mm else '?'
            b, e = self.range_lines(locs)
            node['fn'] = sel
            fn = self.fn_entry(sel, sel, self.impl['name'], self.impl['file'], b, e)
            self.impl['methods'].append(sel)
            node['method'] = fn
        elif kind == 'CompoundStmt' and parent is not None and parent['k'] in ('FunctionDecl', 'ObjCMethodDecl') and parent.get('fn'):
            self.functions[parent['fn']]['body'] = True
            if parent['d'] == 1: self.top['body'] = True
        elif kind == 'EnumConstantDecl' and depth == 2 and self.top.get('consts') is not None:
            mm = re.search(r"\s([A-Za-z_]\w*) '", rest)
            if mm: self.top['consts'].append(mm.group(1))
        elif kind == 'VarDecl' and depth > 1 and node['fn'] and re.search(r"'\s.*\bstatic\b", rest):
            mm = re.search(r"\s([A-Za-z_]\w*) '", rest)
            if mm: self.functions[node['fn']]['static_locals'].append(mm.group(1))
        elif kind == 'DeclRefExpr':
            self.ref(rest, node)

    def range_lines(self, locs):
        b = locs[0] if locs else (None, 0, 0)
        e = locs[1] if len(locs) > 1 else b
        return b[1], (e[1] if e[0] == b[0] else -1)

    def top_decl(self, kind, addr, rest, locs, node):
        b = locs[0] if locs else (None, 0, 0)
        f = self.our_file(b[0]) if b[0] else None
        if f is None: return
        e = locs[1] if len(locs) > 1 else b
        end = e[1] if e[0] == b[0] else -1
        loc = locs[2] if len(locs) > 2 else b
        d = {'id': len(self.decls), 'kind': kind, 'file': f, 'begin': b[1], 'end': end, 'loc': loc[1] if loc[0] == b[0] else b[1], 'name': None,
             'cols': [b[2], loc[2] if loc[0] == b[0] else 0, e[2] if e[0] == b[0] else 0]}
        tail = rest.split("'")[-1] if "'" in rest else rest
        if kind in ('FunctionDecl', 'VarDecl', 'TypedefDecl'):
            mm = re.search(r"\s(?:(?:used|referenced|implicit|invalid)\s+)*([A-Za-z_]\w*) '([^']*)'", rest)
            if mm: d['name'], d['type'] = mm.group(1), mm.group(2)
            d['storage'] = 'static' if re.search(r'\bstatic\b', tail) else 'extern' if re.search(r'\bextern\b', tail) else ''
        if kind == 'FunctionDecl':
            d['inline'] = bool(re.search(r'\binline\b', tail))
            if d['name']:
                fn = self.fn_entry(d['name'], d['name'], None, f, b[1], end, d['storage'], d['inline'])
                node['fn'] = d['name']; d['fn'] = d['name']
                fn.setdefault('decls', []).append(d['id'])
        elif kind == 'VarDecl':
            d['tls'] = bool(re.search(r'\btls\b', tail)); d['init'] = bool(re.search(r'\b(cinit|callinit|listinit)\b', tail))
            typ = d.get('type', '')
            d['const'] = is_const(typ); d['anon'] = '(unnamed ' in typ or '(anonymous ' in typ
            if d['name'] and d['storage'] != 'extern':
                self.var_addr[addr] = d['name']
                g = self.globals.setdefault(d['name'], {'decls': [], 'refs': {}})
                g['decls'].append(d['id'])
                node['fn'] = '@init:' + d['name']
                self.fn_entry(node['fn'], node['fn'], None, f, b[1], end)
        elif kind in ('RecordDecl', 'EnumDecl'):
            mm = re.search(r'\s(?:struct|union|enum)((?:\s+\w+)*)\s*$', rest)
            words = mm.group(1).split() if mm else []
            d['name'] = next((w for w in words if w != 'definition'), None)
            d['definition'] = 'definition' in words
            if kind == 'EnumDecl': d['consts'] = []
        elif kind in ('ObjCInterfaceDecl', 'ObjCImplementationDecl', 'ObjCCategoryDecl', 'ObjCCategoryImplDecl', 'ObjCProtocolDecl'):
            mm = re.search(r'\s([A-Za-z_]\w*)\s*$', rest.split("'")[0])
            d['name'] = mm.group(1) if mm else None
            if kind == 'ObjCImplementationDecl': d['methods'] = []; self.impl = d
        self.decls.append(d)
        self.top = d

    def ref(self, rest, node):
        fn = node['fn']
        if not fn: return
        mv = re.search(r" Var 0x([0-9a-f]+) '([A-Za-z_]\w*)'", rest)
        if mv:
            name = self.var_addr.get(mv.group(1))
            if name:
                acc = classify(self.stack)
                v = self.functions[fn]['vars']
                if acc not in v.get(name, ''): v[name] = ''.join(sorted(v.get(name, '') + acc))
            return
        mf = re.search(r" Function 0x([0-9a-f]+) '([A-Za-z_]\w*)'", rest)
        if mf:
            par = self.stack[-2] if len(self.stack) > 1 else None
            gp = self.stack[-3] if len(self.stack) > 2 else None
            called = par is not None and par['k'] == 'ImplicitCastExpr' and gp is not None and gp['k'] == 'CallExpr' and par['i'] == 0
            ent = self.functions[fn]
            if called: ent['calls'][mf.group(2)] = ent['calls'].get(mf.group(2), 0) + 1
            elif mf.group(2) not in ent['fnrefs']: ent['fnrefs'].append(mf.group(2))


def decl_end(lines, begin, body):
    """The last line of a declaration that starts on line begin (1-based): the line of its first ';' at depth 0, or of the '}' that closes its body."""
    text = '\n'.join(lines[begin - 1:begin + 400])
    code = blank_code(text)
    depth, ln = 0, begin
    for ch in code:
        if ch == '\n': ln += 1; continue
        if ch in '([{': depth += 1
        elif ch in ')]}':
            depth -= 1
            if depth == 0 and ch == '}' and body: return ln
        elif ch == ';' and depth == 0: return ln
    return begin


def finish(p, sources):
    """Fix the ends the AST gives in another file (a macro ends the declaration), place each function at its definition, and attach the globals' declarations."""
    text = {f: read_lines(REPO / f) for f in sources}
    for d in p.decls:
        if d['end'] < d['begin']: d['end'] = decl_end(text[d['file']], d['begin'], d.get('body', False))
    for key, fn in p.functions.items():
        if key.startswith(('@init:', '-[', '+[')): continue
        defs = [p.decls[i] for i in fn.get('decls', [])]
        if not defs: continue
        d = next((x for x in defs if x.get('body')), defs[-1])
        fn['file'], fn['begin'], fn['end'] = d['file'], d['begin'], d['end']
    for g in p.globals.values():
        ds = [p.decls[i] for i in g['decls']]
        d = next((x for x in ds if x.get('init')), ds[-1])
        g.update({k: d[k] for k in ('file', 'begin', 'end', 'loc', 'type', 'storage', 'tls', 'const', 'anon')})
    for key, fn in p.functions.items():
        for v, acc in fn['vars'].items():
            if v in p.globals: p.globals[v]['refs'][key] = acc


def parse(stream, base):
    p = Parser(SOURCES, base)
    for raw in stream: p.line(raw.rstrip('\n'))
    finish(p, SOURCES)
    return p


def facts_of(p):
    return {'version': 1, 'files': {f: {'lines': len(read_lines(REPO / f)), 'sha1': sha1(REPO / f)} for f in SOURCES},
            'decls': p.decls, 'functions': {k: v for k, v in p.functions.items() if not k.startswith('@init:') or v['calls'] or v['fnrefs'] or v['vars']},
            'globals': p.globals}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--game', default=os.environ.get('GAME') or os.environ.get('DM_GAME'))
    ap.add_argument('--out', required=True)
    ap.add_argument('--ast')
    ap.add_argument('--reuse', action='store_true')
    a = ap.parse_args(argv)
    ast = pathlib.Path(a.ast) if a.ast else pathlib.Path(a.out).with_suffix('.ast.gz')
    if not (a.reuse and ast.exists()):
        if not a.game: sys.exit('facts: --game <id> (or GAME) is needed to build the compile line')
        run_clang(a.game, ast)
    with gzip.open(ast, 'rb') as raw:
        p = parse(io.TextIOWrapper(raw, encoding='utf-8', errors='replace'), str(REPO / 'dm/host'))
    save_json(a.out, facts_of(p))
    nf = sum(1 for k, v in p.functions.items() if v['body'] and not k.startswith('@init:'))
    print(f'facts: {a.out}: {len(p.decls)} declarations, {nf} functions with a body, {len(p.globals)} globals')


if __name__ == '__main__':
    main()
