"""Shared paths and helpers of the nvn_mtl.m split tools (dm/tools/mtlsplit; docs/development.md, "Splitting nvn_mtl.m")."""
import hashlib, json, pathlib, posixpath, re

REPO = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
NVN = 'dm/gfx/nvn'
SOURCES = ('dm/gfx/nvn/nvn_mtl.m', 'dm/gfx/nvn/nvn_rec.h', 'dm/gfx/nvn/nvn_geometry.inc', 'dm/gfx/nvn/nvn_feedback.inc', 'dm/gfx/nvn/nvn_capture.inc')
UNIT = 'dm/gfx/nvn/nvn_mtl.m'
UNITY = 'dm/gfx/nvn/nvn_mtl_all.inc'
HIDDEN = '__attribute__((visibility("hidden")))'


def module_files(name):
    return f'{NVN}/mtl_{name}.m', f'{NVN}/mtl_{name}.h'


def read_lines(path):
    text = pathlib.Path(path).read_text(encoding='utf-8', errors='surrogateescape')
    lines = text.split('\n')
    if lines and lines[-1] == '': lines.pop()
    return lines


def write_lines(path, lines):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(''.join(line + '\n' for line in lines), encoding='utf-8', errors='surrogateescape')


def sha1(path):
    return hashlib.sha1(pathlib.Path(path).read_bytes()).hexdigest()


def load_json(path):
    return json.loads(pathlib.Path(path).read_text())


def save_json(path, obj):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(obj, indent=1, sort_keys=True) + '\n')


def blank_code(text):
    """text with comments and the insides of string and character literals blanked (newlines kept), so that scans for braces, semicolons and identifiers see code only."""
    out = list(text); i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i); j = n if j < 0 else j
            for k in range(i, j): out[k] = ' '
            i = j; continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2); j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n': out[k] = ' '
            i = j; continue
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            for k in range(i + 1, min(j, n)):
                if out[k] != '\n': out[k] = ' '
            i = j + 1; continue
        i += 1
    return ''.join(out)


IDENT = re.compile(r'\b[A-Za-z_]\w*')


def identifiers(code):
    """The identifiers code names, leaving out members (after . or ->)."""
    out = set()
    for m in IDENT.finditer(code):
        k = m.start() - 1
        while k >= 0 and code[k] in ' \t': k -= 1
        if k >= 0 and (code[k] == '.' or (code[k] == '>' and k > 0 and code[k - 1] == '-')): continue
        out.add(m.group(0))
    return out


QUALIFIERS = {'const', 'volatile', 'restrict', '__restrict', '__unsafe_unretained', '__strong', '__weak', '__autoreleasing', '_Nullable', '_Nonnull', '_Atomic'}
OPEN, CLOSE = '([{', ')]}'


def statements(text):
    """(code, [(start, end)]): the top-level declarations of a one-line text, each ending after its ';' (None when one is not closed on the line)."""
    code = blank_code(text)
    out, i, n = [], 0, len(code)
    while True:
        while i < n and code[i] in ' \t\n': i += 1
        if i >= n: return code, out
        s, depth = i, 0
        while i < n:
            c = code[i]
            if c in OPEN: depth += 1
            elif c in CLOSE: depth -= 1
            elif c == ';' and depth == 0: break
            i += 1
        if i >= n: return code, None
        i += 1
        out.append((s, i))


def _name_start(code, a, j):
    while True:
        k = j
        while k > a and code[k - 1] in ' \t\n': k -= 1
        if k > a and code[k - 1] in '*^(': j = k - 1; continue
        m = re.search(r'([A-Za-z_]\w*)$', code[a:k])
        if m and m.group(1) in QUALIFIERS:
            k2 = k - len(m.group(1)); k3 = k2
            while k3 > a and code[k3 - 1] in ' \t\n': k3 -= 1
            if k3 > a and code[k3 - 1] in '*^': j = k2; continue
        return j


def declarators(code, s, e):
    """(prefix end, [(start, end, name)]) of the declaration code[s:e] (e after its ';'): the declaration specifiers end where the first declarator starts;
    each declarator runs to its ',' or ';' and is named by the identifier it declares."""
    segs, depth, st = [], 0, s
    for i in range(s, e - 1):
        c = code[i]
        if c in OPEN: depth += 1
        elif c in CLOSE: depth -= 1
        elif c == ',' and depth == 0: segs.append((st, i)); st = i + 1
    segs.append((st, e - 1))
    out, prefix_end = [], None
    for a, b in segs:
        cut, depth = b, 0
        for i in range(a, b):
            c = code[i]
            if c in OPEN: depth += 1
            elif c in CLOSE: depth -= 1
            elif c == '=' and depth == 0: cut = i; break
        j, name, at = cut, None, None
        while name is None:
            while j > a and code[j - 1] in ' \t\n': j -= 1
            if j > a and code[j - 1] in ')]':
                d, x = 0, j - 1
                while x >= a:
                    if code[x] in ')]': d += 1
                    elif code[x] in '([':
                        d -= 1
                        if d == 0: break
                    x -= 1
                inner = code[x + 1:j - 1]
                if code[j - 1] == ')' and re.match(r'\s*[*^]', inner):
                    m = list(re.finditer(r'[A-Za-z_]\w*', inner))
                    name, at = (m[-1].group(0), x + 1 + m[-1].start()) if m else (None, x)
                    if name is None: break
                    continue
                j = x; continue
            m = re.search(r'([A-Za-z_]\w*)$', code[a:j])
            if not m: break
            name, at = m.group(1), a + m.start(1)
        if name is None: return None
        start = _name_start(code, a, at) if prefix_end is None else a
        while start < b and code[start] in ' \t\n': start += 1
        if prefix_end is None: prefix_end = start
        end = b
        while end > start and code[end - 1] in ' \t\n': end -= 1
        out.append((start, end, name))
    return prefix_end, out


DIRECTIVE = re.compile(r'^[ \t]*#')
PUNCT = re.compile(r'[()\[\]{};]')
NON_SPACE = re.compile(r'\S')
OBJC_END = re.compile(r'@end\b')


def blank_directives(code):
    """code (from blank_code) with its preprocessor lines and their continuations blanked."""
    lines, cont = code.split('\n'), False
    for i, t in enumerate(lines):
        if cont or DIRECTIVE.match(t):
            cont = t.rstrip().endswith('\\')
            lines[i] = ' ' * len(t)
        else: cont = False
    return '\n'.join(lines)


def top_level(text):
    """([(start, end, kind, body)], code): the file-scope declarations of a source text, as offsets into it and into code (text with comments, literals
    and preprocessor lines blanked). kind: 'function' (a definition, a method's included; body: the offset of its '{'), 'statement' (up to its ';'),
    'objc' (@interface or @protocol up to @end, @class and forward @protocol up to ';', any other @ line) or 'open' (not closed before the end)."""
    code = blank_directives(blank_code(text))
    out, i, n = [], 0, len(code)
    while True:
        m = NON_SPACE.search(code, i)
        if not m: return out, code
        s = m.start()
        if code[s] == '@':
            w = re.match(r'@(\w*)', code[s:s + 40]).group(1)
            if w in ('interface', 'protocol') and not re.match(r'@protocol\s+[\w\s,]*;', code[s:s + 400]):
                e = OBJC_END.search(code, s + 1); e = e.end() if e else n
            elif w in ('class', 'protocol'):
                e = code.find(';', s); e = n if e < 0 else e + 1
            else:
                e = code.find('\n', s); e = n if e < 0 else e
            out.append((s, e, 'objc', None)); i = e; continue
        method = code[s] in '-+'
        depth, body, kind, e = 0, None, 'open', n
        for p in PUNCT.finditer(code, s):
            c, j = p.group(), p.start()
            if c in '([': depth += 1
            elif c in ')]': depth -= 1
            elif c == '{':
                if depth == 0 and body is None and (method or code[s:j].rstrip().endswith(')')): body = j
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0 and body is not None: kind, e = 'function', j + 1; break
            elif depth == 0: kind, e = 'statement', j + 1; break
            if depth < 0: break
        out.append((s, e, kind, body)); i = e


def function_name(code, s, body):
    """(name, offset) of the function a definition's head code[s:body] defines: the identifier before its first top-level '(' that is not an attribute;
    (None, None) for a method or a head it cannot read."""
    if code[s] in '-+': return None, None
    depth = 0
    for p in re.finditer(r'[()\[\]]', code[s:body]):
        c = p.group()
        if c in ')]': depth -= 1; continue
        if depth == 0 and c == '(':
            m = re.search(r'([A-Za-z_]\w*)\s*$', code[s:s + p.start()])
            if m and m.group(1) not in ('__attribute__', '__declspec', '_Alignas', 'alignas', '__typeof__', 'typeof'): return m.group(1), s + m.start(1)
        depth += 1
    return None, None


def const_object(code):
    """Whether a declaration's code after its 'static', up to its declarator's end, declares a const object (a const pointer when it holds a '*')."""
    seg = re.split(r'[=;,{]', code, maxsplit=1)[0]
    if '*' in seg: return bool(re.match(r'\s*const\b', seg[seg.rindex('*') + 1:]))
    return bool(re.search(r'\bconst\b', seg))


def statement_kind(code, s, e):
    """'type' (typedef, tag declaration, static assert), 'extern', 'proto' (function declarations only) or 'var' of the file-scope statement code[s:e]."""
    t = re.sub(r'\s+', ' ', code[s:e]).strip()
    if re.match(r'(typedef|_Static_assert|static_assert)\b', t) or re.match(r'(struct|union|enum)\b[^;=()]*(\{.*\})?\s*;$', t): return 'type'
    if re.match(r'extern\b', t): return 'extern'
    r = declarators(code, s, e)
    if not r or not r[1]: return 'var'
    for a, b, n in r[1]:
        m = re.search(r'\b' + re.escape(n) + r'\b\s*(.)', code[a:b])
        if not m or m.group(1) != '(': return 'var'
    return 'proto'


def scope_problems(text, module=False):
    """What in a header would make its content differ between translation units, as text. module False: a header nvn_mtl.m includes after its #pragma
    clang attribute push, which a module copies only when it names something the header declares; sound only when the header has no macro, conditional,
    #pragma other than once, ObjC, file-scope variable that is not a const static, or function-local static that is not const. module True: the moved
    lines of a module header, which may hold macros, conditionals, types, @interfaces, prototypes, extern declarations and static inline functions with no
    function-local static, and nothing else (no variable definition, no other static, no @implementation)."""
    out = []
    if not module:
        for ln, t in enumerate(blank_code(text).split('\n'), 1):
            mm = re.match(r'^\s*#\s*(\w+)\s*(.*?)\s*$', t)
            if not mm: continue
            dv, arg = mm.groups()
            if dv in ('define', 'undef'): out.append(f'line {ln}: a macro (#{dv})')
            elif dv in ('if', 'ifdef', 'ifndef', 'elif', 'else', 'endif'): out.append(f'line {ln}: a conditional (#{dv})')
            elif dv == 'pragma' and arg != 'once': out.append(f'line {ln}: a #pragma other than once')
            elif dv not in ('include', 'import', 'pragma'): out.append(f'line {ln}: #{dv}')
    chunks, code = top_level(text)
    if not module and '@' in code: out.append('ObjC')
    for s, e, kind, body in chunks:
        ln = code.count('\n', 0, s) + 1
        if kind == 'open': out.append(f'line {ln}: a declaration that does not close'); continue
        if kind == 'objc':
            if module and re.match(r'@(implementation|synthesize|dynamic)\b', code[s:e]): out.append(f'line {ln}: an @implementation')
            continue
        if kind == 'function':
            head = code[s:body]
            if module and not (re.search(r'\bstatic\b', head) and re.search(r'\b(inline|__inline__)\b', head)):
                out.append(f'line {ln}: a function definition that is not static inline')
            for m in re.finditer(r'\bstatic\b', code[body:e]):
                if module: out.append(f'line {ln}: a function-local static')
                elif not const_object(code[body + m.end():e]): out.append(f'line {ln}: a function-local static that is not const (state)')
            continue
        k = statement_kind(code, s, e)
        if k == 'extern' and '=' in code[s:e]: out.append(f'line {ln}: an extern with an initializer (state)')
        elif k == 'var' and (module or not (re.match(r'\s*static\b', code[s:e]) and const_object(code[s:e].split('static', 1)[1]))):
            out.append(f'line {ln}: a variable definition (state)')
        elif module and k in ('proto', 'var') and re.search(r'\bstatic\b', code[s:e]): out.append(f'line {ln}: a static declaration')
    return out


def declared_names(text):
    """The names a header declares at file scope: its macros, functions, variables, typedefs, tags and enum constants."""
    code = blank_code(text)
    out = set(re.findall(r'^\s*#\s*define\s+(\w+)', code, re.M))
    code = '\n'.join(x for x in code.split('\n') if not x.lstrip().startswith('#'))
    top, d, enum_at = [], 0, []
    for i, c in enumerate(code):
        if c in '{([':
            if d == 0: top.append(' ' + c + ' ')
            if c == '{' and re.search(r'\benum\b[^;{}()]*$', code[max(0, i - 80):i]): enum_at.append((i, d))
            d += 1
            continue
        if c in '})]':
            d -= 1
            if enum_at and c == '}' and enum_at[-1][1] == d:
                b = enum_at.pop()[0]
                out |= set(re.findall(r'([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)', code[b + 1:i]))
            if d == 0: top.append(' ' + c + ' ')
            continue
        if d == 0: top.append(c)
    t = ''.join(top)
    out |= set(re.findall(r'([A-Za-z_]\w*)\s*\(', t)) | set(re.findall(r'([A-Za-z_]\w*)\s*(?:;|=|\[|,)', t)) | set(re.findall(r'\b(?:struct|union|enum)\s+([A-Za-z_]\w*)', t))
    return out - {'__attribute__', 'if', 'while', 'for', 'switch', 'return', 'sizeof', 'void', 'int', 'char', 'long', 'double', 'float'}


INCLUDE_Q = re.compile(r'^\s*#\s*(?:include|import)\s+"([^"]+)"', re.M)


def header_names(path, read, before):
    """The names a header after the push declares, with the headers it includes in turn (those before the push excepted): ValueError when one of them
    has a scope problem (scope_problems)."""
    names, todo, seen = set(), [path], set()
    while todo:
        p = todo.pop()
        if p in seen or p in before: continue
        seen.add(p)
        text = read(p)
        if text is None: continue
        probs = scope_problems(text)
        if probs:
            raise ValueError(f'{p}, which nvn_mtl.m includes after its #pragma clang attribute push: ' + '; '.join(probs) +
                             ' (a module copies such a header only when it names something the header declares, which is sound only for a header with none of these)')
        names |= declared_names(text)
        todo += [posixpath.normpath(posixpath.join(posixpath.dirname(p), q)) for q in INCLUDE_Q.findall(text)]
    return names


def prelude(unit, used, read):
    """(lines, push, pop): the lines a module's .m starts with. nvn_mtl.m's #include and #import lines (not those of the source files, .inc or .m files)
    and its #pragma clang attribute push, with the conditionals and #undef lines before the push; a header it includes after the push (that header may
    need nvn_mtl.m's own types) only when the module names (used) something the header or the headers it includes declare. A module header (mtl_*.h)
    is always copied. read(path) is a repository file's text, or None. ValueError when a header after the push fails scope_problems."""
    out, push, pop, before = [], None, None, set()
    for t in unit:
        mm = re.match(r'^\s*#\s*(\w+)\s*(.*)$', t)
        if not mm: continue
        dv, arg = mm.group(1), mm.group(2)
        if dv in ('include', 'import'):
            if re.search(r'"[^"]+\.(inc|m)"|nvn_rec\.h', arg): continue
            q = re.search(r'"([^"]+)"', arg)
            path = posixpath.normpath(posixpath.join(NVN, q.group(1))) if q else None
            if push is None:
                if path: before.add(path)
            elif path and not q.group(1).startswith('mtl_') and read(path) is not None and not (header_names(path, read, before) & used): continue
            out.append(t)
        elif dv == 'pragma' and 'clang attribute push' in arg: out.append(t); push = t
        elif dv == 'pragma' and 'clang attribute pop' in arg: pop = t
        elif push is None and dv in ('if', 'ifdef', 'ifndef', 'else', 'elif', 'endif', 'undef'): out.append(t)
    return out, push, pop


def header_at(unit):
    """Where nvn_mtl.m includes a new module header: after the last module header, else after its #pragma clang attribute push, else after its last #include."""
    last = None
    for i, t in enumerate(unit):
        if re.match(r'^\s*#\s*include\s+"mtl_\w+\.h"', t): last = i + 1
    if last is not None: return last
    for i, t in enumerate(unit):
        if re.match(r'^\s*#\s*pragma\s+clang\s+attribute\s+push', t): return i + 1
    for i, t in enumerate(unit):
        if re.match(r'^\s*#\s*(include|import)\b', t): last = i + 1
    return last or 0
