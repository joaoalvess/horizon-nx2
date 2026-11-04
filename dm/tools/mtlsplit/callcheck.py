#!/usr/bin/env python3
"""The call check: the calls of the host's hot functions, before and after a step of the split (agents/refactor/plan.md, Oracles).

  callcheck.py --base <dmhost> --new <dmhost> [--allow <tsv>] [--callers <tsv>] [--modules <tsv>] [--function <name> ...]
  callcheck.py --callers-from <map.json> [--callers <tsv>]

Reads the bl targets (and the tail-call b to a symbol) of each checked function in `otool -tvV` of both binaries, with the .llvm.<n> suffixes of ThinLTO
stripped and the names `nm -n` gives one address taken together (the linker folds identical functions), and lists the callees the new binary calls more
often than the base. Checked: draw_, encode_args_, rp_begin_ex_, rp_end and the functions that hold tex_fast, tex_fast_rid or samp_fast (always_inline,
with no symbol of their own): their callers in callcheck_callers.tsv, or the nearest callers that have a symbol. --function replaces the list. A checked
function ThinLTO inlined in one binary is compared with its body folded into each caller the binary calls it from; one inlined in both, through its
callers in callcheck_callers.tsv; one with neither is a defect. A callee the new binary calls fewer times is assumed inlined at more sites: its base body
is folded in for the calls that went, each of its callees up to the rise the new binary shows, so that only the calls its body does not account for count
as new; a callee with an inline row is never explained that way. Counts cannot tell inlining from call sites merged into one (tail merging), so the report
lists what each fold explains.

callcheck_callers.tsv (beside this file) holds the callers of the checked functions and of tex_fast*, frozen from the module map M0 starts from, so
that the check keeps them after their modules move (the map of a later tree no longer lists calls into moved modules); --callers-from rewrites it from a
map. callcheck_allow.tsv holds the treatment of map section 6 and D8: an 'allow' row accepts a new call (out of line by design), an 'inline' row names a
callee that must stay inline (a new call to it is a defect, said as such); a callee pattern may end in '*', and '@cross' stands for any function of
another module than the caller's, by functions.tsv. Any new call no 'allow' row covers is a defect: exit 1.
"""
import argparse, collections, fnmatch, pathlib, re, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from mtlsplit.common import HERE, load_json

HOT = ('draw_', 'encode_args_', 'rp_begin_ex_', 'rp_end')
TEX = ('tex_fast', 'tex_fast_rid', 'samp_fast')
LABEL = re.compile(r'^(\S.*):$')
CALL = re.compile(r'^[0-9a-f]+\s+(bl|b)\s+(.+)$')


def symbol(s):
    s = s.strip()
    m = re.search(r'symbol stub for: (\S+)', s)
    if m: s = m.group(1)
    elif s.startswith('0x'): return None
    s = s.strip('"')
    if s.startswith('_'): s = s[1:]
    return re.sub(r'\.llvm\.\d+$', '', s)


def aliases(nm):
    """{name: key} of the text symbols of `nm -n`: the key joins with '=' the sorted names that share the address."""
    at = collections.defaultdict(set)
    for line in nm.split('\n'):
        p = line.split()
        if len(p) == 3 and p[1] in ('t', 'T'): at[p[0]].add(symbol(p[2]))
    out = {}
    for names in at.values():
        k = '='.join(sorted(names))
        for n in names: out[n] = k
    return out


def disassemble(path, text=None, nm=None):
    """{function: {callee key: count}} of a binary's text section (otool -tvV), with names as in the source; a callee folded with others at one
    address (nm -n) is keyed by all its names, and a function is listed under each of its names."""
    if text is None: text = subprocess.run(['otool', '-tvV', str(path)], check=True, capture_output=True, text=True, errors='replace').stdout
    if nm is None and path is not None: nm = subprocess.run(['nm', '-n', str(path)], check=True, capture_output=True, text=True, errors='replace').stdout
    key = aliases(nm or '')
    out, cur = {}, None
    for line in text.split('\n'):
        m = LABEL.match(line)
        if m and not line.startswith(('/', '(')):
            name = symbol(m.group(1))
            if name is not None:
                names = key.get(name, name).split('=')
                cur = next((out[n] for n in names if n in out), None) or collections.Counter()
                for n in names: out[n] = cur
            continue
        if cur is None: continue
        c = CALL.match(line)
        if not c: continue
        raw = c.group(2).strip()
        tgt = symbol(raw)
        if tgt is not None and (c.group(1) == 'bl' or raw.startswith(('_', '"_')) or 'symbol stub for:' in raw): cur[key.get(tgt, tgt)] += 1
    return out


def read_allow(path):
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        if not line or line.startswith('#'): continue
        f = line.split('\t')
        rows.append({'verdict': f[0], 'function': f[1], 'callee': f[2], 'why': f[3] if len(f) > 3 else ''})
    return rows


def read_callers(path=HERE / 'callcheck_callers.tsv'):
    out = collections.defaultdict(list)
    for line in pathlib.Path(path).read_text().splitlines():
        if not line or line.startswith('#'): continue
        f, c = line.split('\t')[:2]
        out[f].append(c)
    return dict(out)


def modules(path=HERE / 'functions.tsv'):
    out = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if not line or line.startswith('#'): continue
        mo, f = line.split('\t')[:2]
        out[f] = mo
    return out


def freeze(m, path):
    """callcheck_callers.tsv from a module map: the callers of the checked functions, of tex_fast* and of those callers."""
    callers = collections.defaultdict(set)
    for k, v in m['functions'].items():
        for c in v['calls']: callers[c].add(k)
    rows = {(f, c) for f in HOT + TEX for c in callers[f]}
    rows |= {(f, c) for t in TEX for f in callers[t] for c in callers[f]}
    sha = m['files'].get('dm/gfx/nvn/nvn_mtl.m', {}).get('sha1', '?')[:12]
    head = ['# The callers of the call check\'s functions (callcheck.py: draw_, encode_args_, rp_begin_ex_, rp_end), of tex_fast, tex_fast_rid and samp_fast',
            f'# and of their callers, frozen from the module map M0 starts from (nvn_mtl.m {sha}; callcheck.py --callers-from), so that the check keeps them once',
            '# their modules move.', '# function\tcaller']
    pathlib.Path(path).write_text('\n'.join(head + [f'{f}\t{c}' for f, c in sorted(rows)]) + '\n')
    return len(rows)


def checked(binary, names, callers):
    """(the functions to compare, the holders of tex_fast* that have no symbol and no caller in callers): HOT, then the holders with a symbol here."""
    if names: return list(names), []
    out, lost, seen = list(HOT), [], set()
    todo = [c for t in TEX for c in callers.get(t, ())]
    while todo:
        k = todo.pop(0)
        if k in seen or k in TEX: continue
        seen.add(k)
        if k in binary: out.append(k)
        elif callers.get(k): todo += callers[k]
        else: lost.append(k)
    return list(dict.fromkeys(out)), lost


def names(key):
    return key.split('=')


def pretty(key):
    n = names(key)
    return n[0] + (f' (also {", ".join(n[1:])})' if len(n) > 1 else '')


def calls_to(counter, ns):
    return sum(k for c, k in counter.items() if set(names(c)) & ns)


def changes(base, new):
    """([(callee, base count, new count)] the new calls more often, [...] fewer), callees compared through all the names of their address."""
    more = [(c, calls_to(base, set(names(c))), n) for c, n in new.items()]
    fewer = [(c, b, calls_to(new, set(names(c)))) for c, b in base.items()]
    return sorted(x for x in more if x[2] > x[1]), sorted(x for x in fewer if x[1] > x[2])


def absorb(b, n, binary, f, keep):
    """(b with the base body of each callee it calls more often than n folded in for the calls n no longer makes, as when ThinLTO inlines that callee at
    more sites, [(callee, base count, new count, [(body callee, calls explained)])], {body callee: [callees]}). Only callees with a symbol in the base
    binary, each once. A body callee is added up to the rise the new binary shows and no further, so that a callee that did not rise never looks fewer
    and is not folded in turn; one keep(key) holds (an inline row) is never added: its rise stays a defect, listed under the callee that may explain it."""
    b, done, through = collections.Counter(b), [], collections.defaultdict(list)
    while True:
        _, fewer = changes(b, n)
        todo = [(c, kb, kn) for c, kb, kn in fewer if c not in {x[0] for x in done} and f not in names(c) and any(x in binary for x in names(c))]
        if not todo: return b, done, through
        for c, kb, kn in todo:
            body, drop, explained = binary[next(x for x in names(c) if x in binary)], kb - kn, []
            b[c] -= drop
            if b[c] <= 0: del b[c]
            for k, m in body.items():
                if keep(k): through[k].append(c); continue
                add = min(drop * m, max(0, calls_to(n, set(names(k))) - calls_to(b, set(names(k)))))
                if add: b[k] += add; explained.append((k, add))
            done.append((c, kb, kn, explained))


def folded(binary, caller, f):
    """The calls of caller with f's body in place of each call to it, as ThinLTO inlines it."""
    c = collections.Counter(binary[caller])
    k = sum(n for key, n in c.items() if f in names(key))
    for key in [key for key in c if f in names(key)]: del c[key]
    for key, n in binary[f].items(): c[key] += k * n
    return c


def verdict(fn, key, rows, mods):
    hit = None
    for r in rows:
        if r['function'] not in ('*', fn): continue
        if r['callee'] == '@cross':
            if r['verdict'] == 'allow' and hit is None and mods.get(fn) and any(mods.get(n) and mods[n] != mods[fn] for n in names(key)): hit = r
            continue
        if any(fnmatch.fnmatchcase(n, r['callee']) for n in names(key)):
            if r['verdict'] == 'inline': return r
            if hit is None: hit = r
    return hit


def compare(base, new, fns, rows, mods, callers=None):
    callers = read_callers() if callers is None else callers
    report, bad = [], 0
    for f in fns:
        if f in base and f in new: pairs = [(f, base[f], new[f])]
        else:
            have = base if f in base else new if f in new else None
            if have is not None:
                side = 'new' if have is base else 'base'
                other = new if have is base else base
                cs = sorted(g for g, c in have.items() if g != f and c is not have[f] and g in other and any(f in names(k) for k in c))
                cs = cs or [g for g in callers.get(f, ()) if g in base and g in new and g != f]
                pairs = [(f'{f} (inlined into {g} in the {side} binary)', *((folded(base, g, f), new[g]) if have is base else (base[g], folded(new, g, f))))
                         for g in cs]
                why = f'only in the {"base" if have is base else "new"} binary, and no caller of it has a symbol in both'
            else:
                pairs = [(f'{f} (inlined into {g} in both binaries)', base[g], new[g]) for g in callers.get(f, ()) if g in base and g in new]
                why = 'no symbol in either binary, and none of its callers in callcheck_callers.tsv has one in both'
            if not pairs: bad += 1; report.append(f'[RED] {f}: {why}'); continue
        for label, b, n in pairs:
            b, absorbed, through = absorb(b, n, base, f, lambda k, f=f: (verdict(f, k, rows, mods) or {}).get('verdict') == 'inline')
            for c, kb, kn, explained in absorbed:
                report.append(f'{label}: {pretty(c)} {kb} -> {kn} calls, assumed inlined at more sites; its body explains '
                              + (', '.join(f'{pretty(k)} +{x}' for k, x in explained) or 'no rise'))
            more, fewer = changes(b, n)
            if not more and not fewer: report.append(f'{label}: same calls ({len(n)} callees)' + (' after the folds' if absorbed else '')); continue
            for c, kb, kn in more:
                r = verdict(f, c, rows, mods)
                what = f'{label}: new call to {pretty(c)} ({kb} -> {kn})'
                via = sorted({pretty(h) for k in through if set(names(k)) & set(names(c)) for h in through[k]})
                if r is None: bad += 1; report.append(f'[RED] {what} (not in the allowlist)')
                elif r['verdict'] == 'inline': bad += 1; report.append(f'[RED] {what}, which must stay inline ({r["why"]})' + (f', possibly through inlined {", ".join(via)}' if via else ''))
                else: report.append(f'{what}, allowed ({r["why"]})')
            if fewer: report.append(f'{label}: fewer calls: ' + ', '.join(f'{pretty(c)} ({kb} -> {kn})' for c, kb, kn in fewer))
    return bad, report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--base')
    ap.add_argument('--new')
    ap.add_argument('--allow', default=str(HERE / 'callcheck_allow.tsv'))
    ap.add_argument('--callers', default=str(HERE / 'callcheck_callers.tsv'))
    ap.add_argument('--modules', default=str(HERE / 'functions.tsv'))
    ap.add_argument('--function', action='append', default=[])
    ap.add_argument('--callers-from')
    a = ap.parse_args(argv)
    if a.callers_from:
        print(f'{a.callers}: {freeze(load_json(a.callers_from), a.callers)} rows')
        return 0
    if not (a.base and a.new): ap.error('--base and --new are needed')
    callers = read_callers(a.callers)
    base, new = disassemble(a.base), disassemble(a.new)
    (fb, lb), (fn, ln) = checked(base, a.function, callers), checked(new, a.function, callers)
    fns = list(dict.fromkeys(fb + fn))
    bad, report = compare(base, new, fns, read_allow(a.allow), modules(a.modules), callers)
    for k in dict.fromkeys(lb + ln):
        bad += 1; report.append(f'[RED] {k}: holds tex_fast* (callcheck_callers.tsv), has no symbol and no caller there to check instead')
    for line in report: print(line)
    print(f'call check: {len(fns)} functions, ' + (f'{bad} defects' if bad else 'no new call outside the allowlist'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
