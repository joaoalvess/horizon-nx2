#!/usr/bin/env python3
"""The move check: a move commit moves lines of the source files into one module, verbatim and in order, apart from the declared edits; a cut commit
moves lines between the source files, apart from the edits its message lists.

  movecheck.py (--patch <file.patch> | --rev <commit>) [--kind move|cut] [--edits <file>] [--root <repo>] [--unity-patch <file>]

Source files: nvn_mtl.m, nvn_rec.h and the .inc files it includes as code, as they were before the change (the tree under --root for a patch, the
commit's parent for --rev). A move adds one module, dm/gfx/nvn/mtl_<name>.m and mtl_<name>.h. The lines it removes from the source files, in the order
the compiler reads them (an .inc at its #include), are the module's lines: each goes to one of its two files, in that order in each (a removed run the
diff placed one identical line off, such as a blank line, is read at either place). Apart from that:
- a linkage edit: a moved line without the leading static of a file-scope declaration starting on it whose name the header declares hidden;
- a split: a removed one-line declaration list that comes back in its place with some of its declarations, the others being a line of the .m (their
  static dropped as above), the line's trailing comment on one of the two;
- generated lines: the .m starts with the prelude the move tool writes (common.prelude: nvn_mtl.m's #include, #import and #pragma lines, a header
  included after the push only when the module names what it declares) and #include "mtl_<name>.h", and ends with nvn_mtl.m's #pragma clang attribute
  pop; the header starts with #pragma once and declares names other modules reach, each exactly as the move tool derives it from the moved definition (a
  function's signature, a variable's extern, hidden when the name was static); nvn_mtl.m includes the header where the move tool puts it (after the
  module headers before it, or after its push); the unity file includes the .m.
The header's moved lines hold no state (common.scope_problems): macros, conditionals, types, @interfaces, prototypes, extern declarations and static
inline functions with no function-local static. A cut: the multiset of lines removed from the source and module files equals the multiset added back,
apart from the edits listed in --edits (lines starting with '-' and '+', as the cut commit's message lists them); it generates nothing.
Exit 1 with what does not match.
"""
import argparse, bisect, collections, pathlib, re, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from mtlsplit.common import (HIDDEN, REPO, SOURCES, UNIT, UNITY, blank_code, declarators, function_name, header_at, identifiers, prelude, read_lines,
                             scope_problems, statement_kind, statements, top_level)

MODULE_FILE = re.compile(r'^dm/gfx/nvn/mtl_(\w+)\.(m|h)$')
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"')


def parse_patch(text):
    """{path: {'new', 'deleted', 'removed': [line], 'added': [line], 'hunks': [(first old line, [(op, line)])]}} of a unified diff (git format)."""
    files, cur, old = {}, None, None
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]; i += 1
        if line.startswith('diff --git '): cur = None; old = None; continue
        if cur is None and line.startswith('--- '): old = line[4:].split('\t')[0]; continue
        if cur is None and line.startswith('+++ ') and old is not None:
            new = line[4:].split('\t')[0]
            path = (old if new == '/dev/null' else new)
            path = path[2:] if path[:2] in ('a/', 'b/') else path
            cur = files.setdefault(path, {'new': old == '/dev/null', 'deleted': new == '/dev/null', 'removed': [], 'added': [], 'hunks': []})
            continue
        h = re.match(r'^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@', line)
        if cur is None or not h: continue
        nold = int(h.group(2)) if h.group(2) is not None else 1
        nnew = int(h.group(3)) if h.group(3) is not None else 1
        ops = []
        cur['hunks'].append((int(h.group(1)) + (0 if nold else 1), ops))
        while (nold > 0 or nnew > 0) and i < len(lines):
            t = lines[i]; i += 1
            if t.startswith('\\'): continue
            if t.startswith('-'): cur['removed'].append(t[1:]); ops.append(('-', t[1:])); nold -= 1
            elif t.startswith('+'): cur['added'].append(t[1:]); ops.append(('+', t[1:])); nnew -= 1
            else: ops.append((' ', t[1:])); nold -= 1; nnew -= 1
    return files


def apply(old, hunks):
    """(the new lines, the removed old line numbers, the gaps: ([removed old line numbers], [added lines]) between two kept lines) of a file's hunks."""
    new, removed, gaps, o = [], [], [], 1
    for first, ops in hunks:
        if first < o or first > len(old) + 1: raise ValueError(f'a hunk at line {first} does not apply')
        new += old[o - 1:first - 1]; o = first
        gap = None
        for op, t in ops:
            if op == '+':
                if gap is None: gap = ([], []); gaps.append(gap)
                new.append(t); gap[1].append(t); continue
            if o > len(old) or old[o - 1] != t: raise ValueError(f'line {o} is not the line the patch has there: {t[:120]}')
            if op == ' ': new.append(t); gap = None
            else:
                if gap is None: gap = ([], []); gaps.append(gap)
                removed.append(o); gap[0].append(o)
            o += 1
    return new + old[o - 1:], removed, gaps


def tu_order(old):
    """[(file, line)] of the source files in the order the compiler reads them: an included source file at its #include, then any file not included."""
    seen, out = set(), []

    def walk(f):
        seen.add(f)
        for ln, t in enumerate(old.get(f, []), 1):
            out.append((f, ln))
            q = INCLUDE.match(t)
            if q:
                hit = [s for s in SOURCES if s not in seen and s.split('/')[-1] == q.group(1).split('/')[-1]]
                if hit: walk(hit[0])
    walk(UNIT)
    for f in SOURCES:
        if f not in seen: walk(f)
    return out


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


def drop_static(pre):
    return re.sub(r'\bstatic\b ?', '', pre).strip()


def units(line):
    """([(specifiers, [(declarator, name)])] of a one-line declaration list, its trailing comment); None when the line is not one."""
    code, sts = statements(line)
    if not sts: return None
    out = []
    for s, e in sts:
        r = declarators(code, s, e)
        if not r: return None
        pe, ds = r
        out.append((norm(line[s:pe]), [(norm(line[a:b]), n) for a, b, n in ds]))
    return out, line[sts[-1][1]:].strip()


def line_key(line):
    u = units(line)
    return (tuple(sorted((pre, d) for pre, ds in u[0] for d, _ in ds)), u[1]) if u else None


def remainder_ok(old, new):
    """Whether new is the part of the declaration list old that stays: some of its declarations, unchanged, and its comment or none."""
    uo, un = units(old), units(new)
    if not uo or not un or un[1] not in ('', uo[1]): return False
    want = collections.Counter((pre, d) for pre, ds in uo[0] for d, _ in ds)
    got = collections.Counter((pre, d) for pre, ds in un[0] for d, _ in ds)
    return bool(got) and not (got - want) and got != want


def decl_name(t):
    """The name a generated header line would declare (extern [hidden] ...; or [hidden] signature;), or None."""
    s = t.strip()
    if not s.endswith(';') or '{' in s: return None
    body = s[len('extern '):] if s.startswith('extern ') else s
    if body.startswith(HIDDEN + ' '): body = body[len(HIDDEN) + 1:]
    code, sts = statements(body)
    if not sts or len(sts) != 1: return None
    r = declarators(code, *sts[0])
    return r[1][0][2] if r and len(r[1]) == 1 else None


def top_eq(code):
    d = 0
    for i, c in enumerate(code):
        if c in '([{': d += 1
        elif c in ')]}': d -= 1
        elif c == '=' and d == 0: return i
    return None


class Source:
    """A source file before the change: its file-scope declarations (common.top_level), the definitions they hold and the declarations starting on each line."""

    def __init__(self, path, lines):
        self.path, self.lines = path, lines
        self.text = '\n'.join(lines)
        self.starts = [0]
        for t in lines: self.starts.append(self.starts[-1] + len(t) + 1)
        chunks, self.code = top_level(self.text)
        self.functions, self.variables, self.on_line = {}, collections.defaultdict(list), collections.defaultdict(list)
        for s, e, kind, body in chunks:
            if kind == 'function':
                n, at = function_name(self.code, s, body)
                if n:
                    self.functions.setdefault(n, (s, body, at))
                    self.on_line[self.line(s)].append((s, at, {n}))
            elif kind == 'statement' and statement_kind(self.code, s, e) in ('var', 'proto'):
                r = declarators(self.code, s, e)
                if not r: continue
                pe, ds = r
                for a, b, n in ds:
                    if not re.match(r'\s*\(', self.code[a:b][self.code[a:b].find(n) + len(n):]): self.variables[n].append((s, pe, a, b))
                self.on_line[self.line(s)].append((s, pe, {n for _, _, n in ds}))

    def line(self, off):
        return bisect.bisect_right(self.starts, off)


class Check:
    def __init__(self, files, kind='move', edits=(), old=None, read=None):
        self.files, self.kind, self.edits = files, kind, list(edits)
        self.old = {f: list((old or {}).get(f, [])) for f in SOURCES}
        self.read = read or (lambda path: None)
        self.errors, self.counts = [], collections.Counter()

    def run(self):
        self.cut() if self.kind == 'cut' else self.move()
        return not self.errors

    def cut(self):
        removed, added = collections.Counter(), collections.Counter()
        for p, v in self.files.items():
            if p in SOURCES or MODULE_FILE.match(p): removed.update(v['removed']); added.update(v['added'])
            elif v['removed'] or v['added']: self.errors.append(f'{p}: a cut changes only the source and module files')
        for t in self.edits:
            pool = removed if t.startswith('-') else added
            if pool[t[1:]] > 0: pool[t[1:]] -= 1; self.counts['edits'] += 1
            else: self.errors.append(f'listed edit not in the patch: {t}')
        for t in list(removed):
            k = min(removed[t], added[t]); removed[t] -= k; added[t] -= k; self.counts['moved'] += k
        self.errors += [f'removed and not added back ({n}x): {t[:200]}' for t, n in removed.items() if n > 0]
        self.errors += [f'added and not removed ({n}x): {t[:200]}' for t, n in added.items() if n > 0]

    def move(self):
        F = self.files
        mods = sorted({m.group(1) for m in map(MODULE_FILE.match, F) if m})
        if len(mods) != 1: self.errors.append(f'a move adds one module; this patch touches {mods or "none"}'); return
        x = mods[0]
        self.mpath, self.hpath = f'dm/gfx/nvn/mtl_{x}.m', f'dm/gfx/nvn/mtl_{x}.h'
        own_h, own_m = f'#include "mtl_{x}.h"', f'#include "mtl_{x}.m"'
        for p in (self.mpath, self.hpath):
            if p not in F or not F[p]['new']: self.errors.append(f'{p}: a move adds it as a new file'); return
        for p, v in F.items():
            if p in SOURCES or p in (self.mpath, self.hpath): continue
            if p == UNITY or p.startswith('unity:'):
                if v['removed'] or v['added'] != [own_m]: self.errors.append(f'{p}: a move only adds {own_m} to the unity file')
                else: self.counts['generated'] += 1
            elif v['removed'] or v['added']: self.errors.append(f'{p}: a move changes only the source files, the module files and the unity file')
        self.src = {f: Source(f, self.old[f]) for f in SOURCES}
        new, self.removed, gaps = {}, set(), []
        for f in SOURCES:
            if f not in F: new[f] = self.old[f]; continue
            try: new[f], rm, gp = apply(self.old[f], F[f]['hunks'])
            except ValueError as e: self.errors.append(f'{f}: the patch does not apply to the tree it is checked against: {e}'); return
            self.removed |= {(f, ln) for ln in rm}
            gaps += [(f, r, a) for r, a in gp]
        H, M = F[self.hpath]['added'], F[self.mpath]['added']
        D, Bh = self.header(H)
        split = self.sources(gaps, new, own_h)
        Bm = self.module(M, H, new[UNIT], own_h)
        if Bm is None: return
        self.order(Bm, Bh, D, split)

    def header(self, H):
        if not H or H[0] != '#pragma once': self.errors.append(f'{self.hpath}: its first line is not #pragma once')
        gen, D, Bh = set(), set(), []
        for t in H[1:]:
            n = decl_name(t)
            if n and n not in gen and self.declaration(n) == t:
                gen.add(n); self.counts['generated'] += 1
                if HIDDEN in t: D.add(n)
            else: Bh.append(t)
        self.counts['generated'] += 1
        for p in scope_problems('\n'.join(Bh), module=True):
            self.errors.append(f'{self.hpath}, its moved lines: {p} (a module header holds types, macros, prototypes and static inline functions with no function-local static)')
        return D, Bh

    def declaration(self, n):
        """The header line the move tool derives for a name whose definition the patch removes: a function's signature or a variable's extern."""
        for src in self.src.values():
            d = src.functions.get(n)
            if d and (src.path, src.line(d[2])) in self.removed:
                s, body, at = d
                sig = re.sub(r'\b(static|inline|__inline__)\b\s*', '', norm(src.code[s:body]))
                sig = re.sub(r'__attribute__\(\(\s*always_inline\s*\)\)\s*', '', sig).strip()
                return (HIDDEN + ' ' if re.search(r'\bstatic\b', src.code[s:at]) else '') + sig + ';'
        for src in self.src.values():
            for s, pe, a, b in src.variables.get(n, ()):
                if (src.path, src.line(a)) not in self.removed: continue
                dec = src.text[a:b]
                k = top_eq(blank_code(dec))
                dec = dec[:k] if k is not None else dec
                static = re.search(r'\bstatic\b', src.code[s:pe])
                return 'extern ' + (HIDDEN + ' ' if static else '') + norm(re.sub(r'\bstatic\b', '', src.text[s:pe])) + ' ' + norm(dec) + ';'
        return None

    def sources(self, gaps, new, own_h):
        """The split lines {(file, line): the part that stays}, after checking that a source file gains only those parts and nvn_mtl.m the header's #include."""
        split, own = {}, 0
        for f, rm, adds in gaps:
            i = 0
            for a in adds:
                if f == UNIT and a == own_h and not own: own += 1; self.counts['generated'] += 1; continue
                while i < len(rm) and not remainder_ok(self.old[f][rm[i] - 1], a): i += 1
                if i == len(rm): self.errors.append(f'added to {f} and not the part of a split line that stays: {a[:200]}'); continue
                split[(f, rm[i])] = a; i += 1
        if own != 1: self.errors.append(f'{UNIT}: a move adds {own_h} once')
        else:
            k = new[UNIT].index(own_h)
            want = header_at(new[UNIT][:k] + new[UNIT][k + 1:])
            if want != k: self.errors.append(f'{UNIT}: {own_h} is at line {k + 1}; the move tool puts it at line {want + 1} (after the module headers, or after the push)')
        return split

    def module(self, M, H, unit, own_h):
        """The .m's moved lines, after checking its prelude and its last line against what the move tool writes."""
        if own_h not in M: self.errors.append(f'{self.mpath}: it does not include {own_h}'); return None
        k = M.index(own_h)
        rest = list(unit)
        if own_h in rest: rest.remove(own_h)
        try:
            _, push, pop = prelude(rest, set(), self.read)
            body = M[k + 1:]
            if push and pop:
                if not body or body[-1] != pop: self.errors.append(f'{self.mpath}: its last line is not {pop}')
                else: body = body[:-1]
            want, _, _ = prelude(rest, identifiers(blank_code('\n'.join(body + H[1:]))), self.read)
        except ValueError as e:
            self.errors.append(str(e)); return None
        if M[:k] != want:
            i = next((i for i, (a, b) in enumerate(zip(M[:k], want)) if a != b), min(k, len(want)))
            self.errors.append(f'{self.mpath}: its first {k} lines are not the prelude the move tool writes ({len(want)} lines); line {i + 1}: '
                               f'{(M[:k] + ["(none)"])[i][:120]!r}, expected {(want + ["(none)"])[i][:120]!r}')
        self.counts['generated'] += k + 1 + (len(M) - k - 1 - len(body))
        return body

    def linkage(self, f, ln, D):
        """The line without the static of each file-scope declaration starting on it that declares a name of D (before the declarator), or None."""
        src = self.src[f]
        t = src.lines[ln - 1]
        base, end = src.starts[ln - 1], src.starts[ln - 1] + len(t)
        cuts = []
        for s, limit, names in src.on_line.get(ln, ()):
            if not names & D: continue
            m = re.search(r'\bstatic\b[ \t]*', src.code[s:min(limit, end)])
            if m: cuts.append((s + m.start() - base, s + m.end() - base))
        if not cuts: return None
        for a, b in sorted(cuts, reverse=True): t = t[:a] + t[b:]
        return t

    def split_key(self, t, rest, D):
        uo, ur = units(t), units(rest)
        left = collections.Counter((pre, d) for pre, ds in ur[0] for d, _ in ds)
        mine = []
        for pre, ds in uo[0]:
            part = []
            for d, n in ds:
                if left[(pre, d)] > 0: left[(pre, d)] -= 1
                else: part.append((d, n))
            if part:
                p2 = drop_static(pre) if {n for _, n in part} & D else pre
                mine += [(p2, d) for d, _ in part]
        return tuple(sorted(mine)), ('' if ur[1] else uo[1])

    def element(self, f, ln, D, split):
        t = self.old[f][ln - 1]
        if (f, ln) in split: return t, None, self.split_key(t, split[(f, ln)], D)
        return t, self.linkage(f, ln, D), None

    def alternatives(self, run, split):
        """The run of removed lines and the runs the diff could have marked instead, one identical line up or down at a time."""
        f, a, b = run[0][0], run[0][1], run[-1][1]
        if any(x in split for x in run): return [run]
        lines, out = self.old[f], [run]
        movable = lambda ln: 1 <= ln <= len(lines) and (f, ln) not in self.removed and not INCLUDE.match(lines[ln - 1])
        v = 1
        while movable(a - v) and lines[a - v - 1] == lines[b - v]: out.append([(f, ln) for ln in range(a - v, b - v + 1)]); v += 1
        v = 1
        while movable(b + v) and lines[a + v - 2] == lines[b + v - 1]: out.append([(f, ln) for ln in range(a + v, b + v + 1)]); v += 1
        return out

    def order(self, Bm, Bh, D, split):
        """S, the removed lines in the order the compiler reads them, must be the .m's moved lines and the header's interleaved: a walk over S keeping
        the set of reachable .m positions as a bit set (the header position is the rest)."""
        S = [x for x in tu_order(self.old) if x in self.removed]
        runs = []
        for x in S:
            if runs and runs[-1][-1][0] == x[0] and runs[-1][-1][1] + 1 == x[1]: runs[-1].append(x)
            else: runs.append([x])
        Lm, Lh = len(Bm), len(Bh)
        posM, keyM, revH = collections.defaultdict(int), collections.defaultdict(int), collections.defaultdict(int)
        for j, t in enumerate(Bm):
            posM[t] |= 1 << j
            k = line_key(t)
            if k: keyM[k] |= 1 << j
        for k, t in enumerate(Bh): revH[t] |= 1 << (Lh - k)

        def step(r, p, e):
            t, link, key = e
            if key: mm, hm = keyM.get(key, 0), 0
            else:
                mm = posM.get(t, 0) | (posM.get(link, 0) if link else 0)
                h, sh = revH.get(t, 0), Lh - p
                hm = h >> sh if sh >= 0 else h << -sh
            return ((r & mm) << 1) | (r & hm)
        reach, p, trace, fail = 1, 0, [], None
        for run in runs:
            outs = []
            for alt in self.alternatives(run, split):
                r, steps = reach, []
                for i, (f, ln) in enumerate(alt):
                    e = self.element(f, ln, D, split)
                    r = step(r, p + i, e); steps.append((e, r))
                outs.append(steps)
            trace.append((reach, p, outs))
            nxt = 0
            for steps in outs: nxt |= steps[-1][1]
            if not nxt: fail = (run, reach, p); break
            reach, p = nxt, p + len(run)
        if fail is None and reach >> Lm & 1 and p == Lm + Lh:
            j = Lm
            for reach0, p0, outs in reversed(trace):
                steps = next(s for s in outs if s[-1][1] >> j & 1)
                for i in range(len(steps) - 1, -1, -1):
                    (t, link, key), _ = steps[i]
                    prev = steps[i - 1][1] if i else reach0
                    if j and prev >> (j - 1) & 1 and ((key and line_key(Bm[j - 1]) == key) or (not key and Bm[j - 1] in (t, link))):
                        self.counts['split' if key else 'moved' if Bm[j - 1] == t else 'linkage'] += 1; j -= 1
                    else: self.counts['moved'] += 1
            return
        self.diagnose(S, Bm, Bh, D, split)
        if not self.errors:
            if fail:
                run, r, p0 = fail
                j = r.bit_length() - 1
                self.errors.append(f'out of order: the lines removed at {run[0][0]}:{run[0][1]}-{run[-1][1]} ({self.old[run[0][0]][run[0][1] - 1][:100]!r}) are not the next '
                                   f'lines of {self.mpath} ({(Bm + ["(end)"])[j][:100]!r}) or {self.hpath} ({(Bh + ["(end)"])[min(p0 - j, Lh)][:100]!r})')
            else: self.errors.append('out of order: the module files do not end with the last removed lines')

    def diagnose(self, S, Bm, Bh, D, split):
        pm, ph = collections.Counter(Bm), collections.Counter(Bh)
        by_key = collections.defaultdict(list)
        for t in Bm:
            k = line_key(t)
            if k: by_key[k].append(t)
        for f, ln in S:
            t, link, key = self.element(f, ln, D, split)
            if key:
                hit = next((x for x in by_key.get(key, ()) if pm[x] > 0), None)
                if hit is not None: pm[hit] -= 1; continue
            elif link and pm[link] > 0: pm[link] -= 1; continue
            elif ph[t] > 0: ph[t] -= 1; continue
            elif pm[t] > 0: pm[t] -= 1; continue
            self.errors.append(f'removed and not added back ({f}:{ln}): {t[:200]}')
        for pool, path in ((pm, self.mpath), (ph, self.hpath)):
            self.errors += [f'added to {path} and not removed ({n}x): {t[:200]}' for t, n in pool.items() if n > 0]


def lines_of(text):
    lines = text.split('\n')
    if lines and lines[-1] == '': lines.pop()
    return lines


def git_show(root, spec):
    r = subprocess.run(['git', '-C', str(root), 'show', spec], capture_output=True, text=True, errors='surrogateescape')
    return r.stdout if r.returncode == 0 else None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--patch')
    g.add_argument('--rev')
    ap.add_argument('--kind', choices=('move', 'cut'), default='move')
    ap.add_argument('--edits')
    ap.add_argument('--unity-patch')
    ap.add_argument('--root', default=str(REPO))
    a = ap.parse_args(argv)
    root = pathlib.Path(a.root)
    if a.patch:
        text = pathlib.Path(a.patch).read_text(errors='surrogateescape')
        old = {f: read_lines(root / f) if (root / f).is_file() else [] for f in SOURCES}

        def read(path): return (root / path).read_text(errors='replace') if (root / path).is_file() else None
    else:
        text = subprocess.run(['git', '-C', str(root), 'show', '--format=', '--no-renames', a.rev], check=True, capture_output=True, text=True, errors='surrogateescape').stdout
        old = {f: lines_of(git_show(root, f'{a.rev}^:{f}') or '') for f in SOURCES}

        def read(path): return git_show(root, f'{a.rev}^:{path}')
    files = parse_patch(text)
    if a.unity_patch:
        for p, v in parse_patch(pathlib.Path(a.unity_patch).read_text()).items(): files['unity:' + p] = v
    edits = [x for x in pathlib.Path(a.edits).read_text().split('\n') if x[:1] in ('-', '+')] if a.edits else []
    c = Check(files, a.kind, edits, old, read)
    ok = c.run()
    n = c.counts
    print(f'move check ({a.kind}): {n["moved"]} lines moved, {n["linkage"]} linkage edits, {n["split"]} splits, {n["generated"]} generated, {n["edits"]} listed edits: '
          + ('pass' if ok else 'FAIL'))
    for e in c.errors[:40]: print(f'[RED] {e}')
    if len(c.errors) > 40: print(f'[RED] ... {len(c.errors) - 40} more')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
