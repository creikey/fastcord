#!/usr/bin/env python3
# Odin -> Jai source transpiler for fastcord. One-shot tool: output is then fixed by hand.
import re, sys, os, json

# ---------------------------------------------------------------- lexer
class T:
    __slots__ = ('k', 's', 'pre', 'nl')
    def __init__(s, k, text, pre=''):
        s.k, s.s, s.pre = k, text, pre
        s.nl = '\n' in pre
    def __repr__(s): return f'{s.k}:{s.s!r}'

OPS = ['..<', '..=', '&~=', '<<=', '>>=', '%%=', '---', '::', ':=', '->', '==', '!=', '<=', '>=', '&&', '||',
       '<<', '>>', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '~=', '&~', '%%', '..', '&&=', '||=']
OPS.sort(key=len, reverse=True)

def lex(src):
    toks, i, n, pre = [], 0, len(src), ''
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            j = i
            while j < n and src[j] in ' \t\r\n': j += 1
            pre += src[i:j]; i = j; continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            pre += src[i:j]; i = j; continue
        if src.startswith('/*', i):
            d, j = 0, i
            while j < n:
                if src.startswith('/*', j): d += 1; j += 2
                elif src.startswith('*/', j):
                    d -= 1; j += 2
                    if d == 0: break
                else: j += 1
            pre += src[i:j]; i = j; continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (src[j].isalnum() or src[j] == '_'): j += 1
            toks.append(T('id', src[i:j], pre)); pre = ''; i = j; continue
        if c.isdigit() or (c == '.' and i + 1 < n and src[i+1].isdigit() and not (toks and toks[-1].s == '.')):
            m = re.compile(r'0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9]+)?|\.[0-9]+([eE][+-]?[0-9]+)?').match(src, i)
            t = m.group(0)
            # 1..<2 : don't eat the dot of a range
            if '.' in t and src.startswith('..', i + t.index('.')):
                t = t[:t.index('.')]
            toks.append(T('num', t, pre)); pre = ''; i += len(t); continue
        if c == '"':
            j = i + 1
            while src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            toks.append(T('str', src[i:j+1], pre)); pre = ''; i = j + 1; continue
        if c == '`':
            j = src.index('`', i + 1)
            toks.append(T('raw', src[i+1:j], pre)); pre = ''; i = j + 1; continue
        if c == "'":
            j = i + 1
            while src[j] != "'":
                j += 2 if src[j] == '\\' else 1
            toks.append(T('chr', src[i+1:j], pre)); pre = ''; i = j + 1; continue
        if c == '#':
            if src.startswith('#+', i):  # build tag line
                j = src.find('\n', i); j = n if j < 0 else j
                toks.append(T('tag', src[i:j], pre)); pre = ''; i = j; continue
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == '_'): j += 1
            toks.append(T('dir', src[i:j], pre)); pre = ''; i = j; continue
        for op in OPS:
            if src.startswith(op, i):
                toks.append(T('op', op, pre)); pre = ''; i += len(op); break
        else:
            toks.append(T('op', c, pre)); pre = ''; i += 1
    toks.append(T('eof', '', pre))
    return toks

# ---------------------------------------------------------------- tables
TYPES = {'int': 'int', 'uint': 'u64', 'i8': 's8', 'i16': 's16', 'i32': 's32', 'i64': 's64', 'i128': 's128',
         'u8': 'u8', 'u16': 'u16', 'u32': 'u32', 'u64': 'u64', 'u128': 'u128', 'f16': 'float16', 'f32': 'float32',
         'f64': 'float64', 'byte': 'u8', 'rune': 'u32', 'rawptr': '*void', 'uintptr': 'u64', 'cstring': '*u8',
         'typeid': 'Type', 'any': 'Any', 'bool': 'bool', 'b8': 'bool', 'b32': 'bool32', 'b64': 'bool64', 'string': 'string',
         'i16le': 's16', 'i32le': 's32', 'u16le': 'u16', 'u32le': 'u32', 'u64le': 'u64', 'i64le': 's64',
         'u16be': 'u16be', 'u32be': 'u32be', 'u64be': 'u64be', 'i16be': 's16be', 'i32be': 's32be'}
JAI_RESERVED = {'it', 'it_index', 'then', 'ifx', 'xx', 'inline', 'operator', 'remove', 'null', 'while', 'case', 'enum_flags',
                'push_context', 'no_inline', 'interface', 'float', 's8', 's16', 's32', 's64', 'float32', 'float64',
                'Type', 'Code', 'temp', 'print', 'New', 'type_of', 'is_constant', 'initializer_of', 'code_of', 'size_of'}
HARD_KEYWORDS = {'remove', 'then', 'ifx', 'xx', 'inline', 'operator', 'push_context', 'while', 'no_inline', 'interface', 'null', 'enum_flags', 'it', 'it_index'}
KEYWORDS = {'if', 'else', 'for', 'switch', 'case', 'when', 'return', 'defer', 'break', 'continue', 'fallthrough', 'proc',
            'struct', 'enum', 'union', 'bit_set', 'bit_field', 'map', 'distinct', 'dynamic', 'in', 'not_in', 'do',
            'using', 'cast', 'transmute', 'auto_cast', 'or_return', 'or_else', 'or_break', 'or_continue', 'foreign',
            'import', 'package', 'nil', 'context', 'where', 'matrix'}
CORE = {'core:strings': 'strings', 'core:fmt': 'fmt', 'core:time': 'time', 'core:os': 'os', 'core:strconv': 'strconv',
        'core:slice': 'slice', 'core:mem': 'mem', 'base:runtime': 'runtime', 'core:sync': 'sync', 'core:thread': 'thread',
        'core:math': 'math', 'core:mem/virtual': 'virtual', 'core:encoding/base64': 'base64', 'core:crypto': 'crypto',
        'core:unicode/utf8': 'utf8', 'core:math/rand': 'rand', 'core:encoding/json': 'json', 'core:path/filepath': 'filepath',
        'core:c': 'c', 'core:bytes': 'bytes', 'base:intrinsics': 'intrinsics', 'core:hash': 'hash',
        'core:compress/zlib': 'zlib', 'core:net': 'net', 'core:debug/trace': 'trace', 'core:crypto/aes': 'aes',
        'core:reflect': 'reflect', 'core:encoding/hex': 'hex', 'core:crypto/sha2': 'sha2', 'core:crypto/hash': 'chash',
        'core:unicode/utf16': 'utf16', 'core:sys/posix': 'posix', 'core:sys/darwin': 'darwin', 'core:hash/xxhash': 'xxhash',
        'core:crypto/pbkdf2': 'pbkdf2', 'core:crypto/legacy/sha1': 'sha1', 'core:crypto/legacy/md5': 'md5',
        'core:crypto/hmac': 'hmac', 'core:crypto/hkdf': 'hkdf', 'core:crypto/ecdsa': 'ecdsa', 'core:crypto/ecdh': 'ecdh',
        'core:crypto/chacha20poly1305': 'chacha20poly1305', 'core:crypto/chacha20': 'chacha20', 'core:compress/gzip': 'gzip',
        'core:compress': 'compress', 'core:sys/windows': 'windows', 'core:math/bits': 'bits', 'core:sort': 'sort',
        'core:io': 'io', 'core:log': 'log', 'core:unicode': 'unicode', 'core:math/linalg': 'linalg', 'core:os/os2': 'os2',
        'vendor:directx/dxgi': 'dxgi', 'vendor:directx/d3d11': 'd3d11', 'vendor:directx/d3d_compiler': 'd3d_compiler'}

GLOBAL = {'types': set(), 'maps': set(), 'map_types': set(), 'procs': {}, 'overloads': {}}

def is_operand_end(t):
    if t is None: return False
    if isinstance(t, G): return t.o in '([' or (t.o == '{' and t.kind == 'lit')
    if t.k in ('num', 'str', 'raw', 'chr'): return True
    if t.k == 'id': return t.s not in KEYWORDS or t.s in ('nil', 'context')
    if t.k == 'op': return t.s in (')', ']', '}', '^', '---', '?')
    if t.k == 'dir': return t.s in ('#caller_location', '#file', '#line', '#procedure', '#directory')
    if t.k == 'x':
        x = t.s.strip()
        if x.startswith('cast(') and x.endswith(')') and x.count('(') == 1: return False
        if x in ('ifx', 'then', 'else', '*', '~', 'xx', 'inline', '& ~', '^', '^=', 'no_inline'): return False
        return True
    return False

# ---------------------------------------------------------------- grouping
class G:
    """A bracketed group: o in '([{', items = children (T or G)."""
    __slots__ = ('o', 'items', 'open', 'close', 'kind')
    def __init__(s, open_t, items, close_t, kind=''):
        s.open, s.items, s.close, s.o, s.kind = open_t, items, close_t, open_t.s, kind
    def __repr__(s): return f'G{s.o}{s.items}'
    @property
    def pre(s): return s.open.pre
    @property
    def nl(s): return s.open.nl
    @property
    def k(s): return 'group'
    @property
    def s(s): return s.o

PAIR = {'(': ')', '[': ']', '{': '}'}
def group(toks):
    stack = [[]]
    opens = []
    for t in toks:
        if t.k == 'op' and t.s in PAIR:
            opens.append(t); stack.append([])
        elif t.k == 'op' and t.s in (')', ']', '}'):
            items = stack.pop(); o = opens.pop()
            assert PAIR[o.s] == t.s, f'mismatched {o.s} {t.s}'
            stack[-1].append(G(o, items, t))
        else:
            stack[-1].append(t)
    assert len(stack) == 1
    return stack[0]

# ---------------------------------------------------------------- emit helpers
def tk(s, pre=''): return T('x', s, pre)
def pre_of(x): return x.pre if x is not None else ''
def flat(items):
    out = []
    for x in items:
        if isinstance(x, G):
            out.append(x.open.pre + x.open.s)
            out.append(flat(x.items))
            out.append(x.close.pre + x.close.s)
        else:
            out.append(x.pre + x.s)
    return ''.join(out)
def strip_pre(items):
    """Copy of items whose first token has no leading trivia; returns (pre, items)."""
    if not items: return '', items
    f = items[0]
    if isinstance(f, G):
        return f.open.pre, [G(T(f.open.k, f.open.s, ''), f.items, f.close, f.kind)] + items[1:]
    return f.pre, [T(f.k, f.s, '')] + items[1:]
def text(items): return flat(items)
def is_t(x, s): return isinstance(x, T) and x.s == s and x.k not in ('str', 'chr', 'raw', 'num')
def split_commas(items):
    parts, cur = [], []
    for x in items:
        if is_t(x, ','): parts.append(cur); cur = []
        else: cur.append(x)
    if cur or parts: parts.append(cur)
    return parts
def find_top(items, s, start=0):
    for i in range(start, len(items)):
        if is_t(items[i], s): return i
    return -1

def nlpre(x):
    """Leading trivia: keep comments/newlines but normalize leading spaces."""
    return x

# ---------------------------------------------------------------- conversion of expressions
class Ctx:
    def __init__(s, pkg, fname):
        s.pkg, s.fname = pkg, fname
        s.proc_stack = []  # list of dicts: results [(name,type)], named bool
        s.tmp = 0
        s.label_map = {}
        s.loop_stack = []
        s.notes = []
    def fresh(s, base='t'):
        s.tmp += 1
        return f'__{base}{s.tmp}'

def conv_type_items(items, cx):
    return conv_expr(items, cx)

def postfix_chain_start(out):
    """Index in out where the operand chain ending at out[-1] begins."""
    i = len(out) - 1
    if i < 0: return 0
    while i >= 0:
        x = out[i]
        if isinstance(x, G) and x.o in '([':
            i -= 1; continue
        if isinstance(x, T) and x.s in ('.*',):
            i -= 1; continue
        if isinstance(x, T) and x.k in ('id', 'num', 'str', 'raw', 'chr', 'x'):
            # ident; check for preceding '.'
            if i - 1 >= 0 and is_t(out[i-1], '.'):
                i -= 2; continue
            return i
        if isinstance(x, G) and x.o == '{':
            # compound literal T.{...}: back over '.' and type
            if i - 1 >= 0 and is_t(out[i-1], '.'):
                i -= 2; continue
            return i
        return i + 1
    return 0

def is_type_like(items):
    """Heuristic: does this item list look like a type expression?"""
    if not items: return False
    f = items[0]
    if isinstance(f, T) and f.s in ('^', '*', 'map', 'proc', 'struct', 'enum', 'distinct', 'bit_set'): return True
    if isinstance(f, G) and f.o == '[': return True
    if len(items) == 1 and isinstance(f, T) and f.k == 'id':
        return f.s in TYPES or f.s in GLOBAL['types']
    if len(items) == 3 and is_t(items[1], '.') and isinstance(items[2], T):
        return items[2].s in GLOBAL['types']
    return False

def type_extent(items, i):
    """From items[i], consume a type expression; return end index (exclusive)."""
    n = len(items)
    while i < n:
        x = items[i]
        if is_t(x, '^'): i += 1; continue
        if isinstance(x, G) and x.o == '[': i += 1; continue
        if is_t(x, 'map') and i + 1 < n and isinstance(items[i+1], G): i += 2; continue
        if isinstance(x, T) and x.s in ('struct', 'enum', 'union'):
            i += 1
            while i < n and not (isinstance(items[i], G) and items[i].o == '{'): i += 1
            return i + 1
        if is_t(x, 'proc'):
            i += 1
            if i < n and items[i].k == 'str': i += 1
            if i < n and isinstance(items[i], G) and items[i].o == '(': i += 1
            if i < n and is_t(items[i], '->'):
                i += 1
                if i < n and isinstance(items[i], G) and items[i].o == '(': i += 1
                else: i = type_extent(items, i)
            return i
        if isinstance(x, T) and x.k == 'id':
            i += 1
            while i + 1 < n and is_t(items[i], '.') and isinstance(items[i+1], T) and items[i+1].k == 'id':
                i += 2
            if i < n and isinstance(items[i], G) and items[i].o == '(' and not items[i].nl:  # poly type Foo(int)
                i += 1
            return i
        if isinstance(x, T) and x.k == 'dir' and x.s in ('#type', '#soa', '#simd'):
            i += 1; continue
        return i
    return i

def conv_proc_params(g, cx, foreign=False):
    """g: G '(' param list. Returns string of Jai params."""
    parts = split_commas(g.items)
    out = []
    pending = []
    for p in parts:
        if not p: continue
        pre, p = strip_pre(p)
        # drop param directives
        dirs = []
        while p and isinstance(p[0], T) and p[0].k == 'dir':
            dirs.append(p[0].s); p = p[1:]
        using = ''
        if p and is_t(p[0], 'using'):
            using = 'using '; p = p[1:]
        ci = find_top(p, ':')
        di = find_top(p, ':=')
        if ci < 0 and di < 0:
            # either a pending name (a, b: int) or a bare type (proc type param)
            if len(p) == 1 and isinstance(p[0], T) and p[0].k == 'id' and p[0].s not in TYPES and p[0].s not in GLOBAL['types']:
                pending.append((pre, p[0].s, using)); continue
            out.append(pre.strip() and pre or '' )
            out[-1] += conv_s(p, cx)
            continue
        if di >= 0 and (ci < 0 or di < ci):
            name = text(p[:di]).strip(); val = conv_s(p[di+1:], cx)
            for (pp, nm, us) in pending: out.append(f'{us}{nm} := {val}')
            pending = []
            out.append(f'{using}{rn(name)} :={val}')
            continue
        name = text(p[:ci]).strip()
        rest = p[ci+1:]
        ei = find_top(rest, '=')
        typ = conv_s(rest[:ei] if ei >= 0 else rest, cx).strip()
        if '#c_vararg' in dirs: typ = typ.replace('..Any', '..Any')
        default = (' =' + conv_s(rest[ei+1:], cx)) if ei >= 0 else ''
        if default.strip() == '= null' and not nullable_type(typ): default = ' = .{}'
        if fixed_array_type(typ) and default.strip().startswith('= .{'): default = ' = .[' + default.strip()[4:-1] + ']'
        for (pp, nm, us) in pending: out.append(f'{us}{rn(nm)}: {typ}{default}')
        pending = []
        name = name.replace('$', '$')
        out.append(f'{using}{rn(name)}: {typ}{default}')
    for (pp, nm, us) in pending: out.append(conv_s([tk(nm)], cx))
    return ', '.join(o.strip() for o in out)

def rn(name):
    n = name.lstrip('$')
    if n in JAI_RESERVED: return name + '_'
    return name

def conv_results(items, cx):
    """items after '->'. Returns (jai_text, results list [(name or None, type_text, default)])."""
    if not items: return '', []
    if isinstance(items[0], G) and items[0].o == '(' and len(items) == 1:
        parts = split_commas(items[0].items)
        res = []
        for p in parts:
            if not p: continue
            ci = find_top(p, ':')
            if ci >= 0:
                name = text(p[:ci]).strip()
                rest = p[ci+1:]
                ei = find_top(rest, '=')
                typ = conv_s(rest[:ei] if ei >= 0 else rest, cx).strip()
                d = conv_s(rest[ei+1:], cx).strip() if ei >= 0 else None
                res.append((rn(name), typ, d))
            else:
                res.append((None, conv_s(p, cx).strip(), None))
        # Odin allows `a, b: int` in results
        fixed = []
        pend = []
        for r in res:
            if r[0] is None and re.fullmatch(r'[a-z_][a-z_0-9]*', r[1]) and r[1] not in TYPES.values():
                pend.append(r[1]); continue
            for nm in pend: fixed.append((nm, r[1], r[2]))
            pend = []
            fixed.append(r)
        res = fixed
        return ' ' + ', '.join(r[1] for r in res), res
    if is_t(items[0], '!'): return '', []
    t = conv_s(items, cx).strip()
    return ' ' + t, [(None, t, None)]

def conv_proc(items, i, cx, as_type=False):
    """items[i] is 'proc'. Returns (text, end_index, body_info)."""
    n = len(items)
    i += 1
    conv = ''
    if i < n and isinstance(items[i], T) and items[i].k == 'str':
        cc = items[i].s.strip('"')
        conv = {'c': ' #c_call', 'cdecl': ' #c_call', 'system': ' #c_call', 'stdcall': ' #c_call', 'contextless': ' #no_context'}.get(cc, '')
        i += 1
    if i < n and isinstance(items[i], G) and items[i].o == '{':
        # overload set
        names = [text(p).strip() for p in split_commas(items[i].items) if p]
        return ('__OVERLOAD__(' + ','.join(names) + ')', i + 1, None)
    g = items[i]; i += 1
    params = conv_proc_params(g, cx)
    res_txt, res = '', []
    if i < n and is_t(items[i], '->'):
        i += 1
        j = i
        if j < n and isinstance(items[j], G) and items[j].o == '(':
            j += 1
        elif j < n and is_t(items[j], '!'):
            j += 1
        else:
            j = type_extent(items, j)
        res_txt, res = conv_results(items[i:j], cx)
        if res_txt: res_txt = ' ->' + res_txt
        i = j
    # where clauses / directives before body
    extra = ''
    while i < n and isinstance(items[i], T) and (items[i].k == 'dir' or is_t(items[i], 'where')):
        if is_t(items[i], 'where'):
            # skip until '{' group
            while i < n and not (isinstance(items[i], G) and items[i].o == '{'): i += 1
            break
        d = items[i].s
        if d == '#optional_ok': pass
        i += 1
    sig = f'({params}){res_txt}{conv}'
    if i < n and isinstance(items[i], G) and items[i].o == '{' and not as_type:
        body = items[i]
        for st in split_statements(body.items):
            if len(st) == 3 and isinstance(st[0], T) and st[0].k == 'id' and is_t(st[1], ':=') and isinstance(st[2], T) and st[2].s == st[0].s:
                v = st[0].s
                sig = re.sub(r'(?<=[(, ])' + re.escape(rn(v)) + r'(?=:)', rn(v) + '_in', sig, count=1)
                st[2].s = rn(v) + '_in'
        cx.proc_stack.append({'res': res, 'named': any(r[0] for r in res), 'conv': conv, 'statics': []})
        btxt = conv_block(body, cx, inject=proc_prologue(res, conv))
        statics = cx.proc_stack.pop()['statics']
        for nm, decl in statics:
            g = cx.fresh('static_' + nm)[2:]
            btxt = re.sub(r'([{,]\s*)' + re.escape(nm) + r'(\s*=[^=])', r'\1@@FIELD@@\2', btxt)
            btxt = re.sub(r'(?<![\w.])' + re.escape(nm) + r'\b', g, btxt).replace('@@FIELD@@', nm)
            cx.hoisted.append('#scope_file ' + re.sub(r'^\s*' + re.escape(nm) + r'\b', g, decl.strip()) + ' #scope_export')
        return (sig + ' ' + btxt.lstrip(' '), i + 1, True)
    if i < n and is_t(items[i], '---'):
        return (sig, i + 1, 'foreign')
    return (sig, i, None)

def proc_prologue(res, conv):
    lines = []
    for (nm, typ, d) in res:
        if nm:
            lines.append(f'{nm}: {typ}' + (f' = {d};' if d else ';'))
    return lines

def char_lit(s):
    # s: content between quotes
    esc = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, "'": 39, '"': 34, 'a': 7, 'b': 8, 'e': 27, 'f': 12, 'v': 11}
    if s.startswith('\\'):
        c = s[1]
        if c in esc: v = esc[c]
        elif c in 'xuU': v = int(s[2:], 16)
        else: v = int(s[1:], 8)
    else:
        v = ord(s)
    if 32 <= v < 127 and chr(v) not in '"\\': return f'#char "{chr(v)}"'
    return str(v)

def str_lit(s):
    # Odin escapes mostly match Jai's. \U -> \u not supported; translate rarely-used ones.
    s = re.sub(r'\\U([0-9a-fA-F]{8})', lambda m: chr(int(m.group(1), 16)), s)
    return s

def raw_lit(s):
    if '\n' not in s and '"' not in s and '\\' not in s:
        return '"' + s + '"'
    if '\n' not in s:
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return '#string __END\n' + s + '__END\n'

def conv_s(items, cx):
    return text(conv_expr(items, cx))

def is_map_index_base(out, start):
    """out[start:] is an operand chain; is its last identifier a known map name?"""
    chain = out[start:]
    last = None
    for x in chain:
        if isinstance(x, T) and x.k == 'id': last = x.s
        elif isinstance(x, T) and x.k == 'x': last = x.s
    return last in GLOBAL['maps'] or last in GLOBAL.get('ambiguous_maps', ())

def conv_expr(items, cx, ctx='expr'):
    """Convert a flat list of items (T and G) representing one expression (or expression list)."""
    items = list(items)
    # segment-level transforms: ternaries, or_else, in
    if any(is_t(x, ',') for x in items):
        parts = split_commas(items)
        out = []
        for k, p in enumerate(parts):
            if k: out.append(tk(','))
            out.extend(conv_expr(p, cx))
        return out
    # Odin ternary forms
    qi = find_top(items, '?')
    if qi > 0:
        ci = find_top(items, ':', qi)
        if ci > 0:
            pre, cond = strip_pre(items[:qi])
            return [tk(f'ifx {conv_s(cond, cx).strip()} then {conv_s(items[qi+1:ci], cx).strip()} else {conv_s(items[ci+1:], cx).strip()}', pre)]
    ii = find_top(items, 'if')
    if ii < 0: ii = find_top(items, 'when')
    if ii > 0:
        ei = find_top(items, 'else', ii)
        if ei > 0:
            pre, a = strip_pre(items[:ii])
            return [tk(f'ifx {conv_s(items[ii+1:ei], cx).strip()} then {conv_s(a, cx).strip()} else {conv_s(items[ei+1:], cx).strip()}', pre)]
    oi = find_top(items, 'or_else')
    if oi > 0:
        pre, a = strip_pre(items[:oi])
        at = conv_s(a, cx).strip()
        d = conv_s(items[oi+1:], cx).strip()
        ma = re.fullmatch(r'(.*)\.__AS__\(([\w.]+)\)', at, re.S)
        if ma:
            k = union_kind(ma.group(2))
            if d == 'null': d = '.{}'
            return [tk(f'ifx {ma.group(1)}.kind == .{k[0]} then {ma.group(1)}.{k[1]} else {d}', pre)]
        return [tk('or_else(', pre)] + conv_expr(a, cx) + [tk(',')] + conv_expr(items[oi+1:], cx) + [tk(')')]
    for kw in ('in', 'not_in'):
        ni = find_top(items, kw)
        if ni > 0:
            # left operand: scan back
            left = conv_expr(items[:ni], cx)
            st = postfix_chain_start(left)
            # include unary prefix? no: `!(k in m)` is grouped by parens
            rhs_items = items[ni+1:]
            right = conv_expr(rhs_items, cx)
            # right operand: take chain from start
            rend = 0
            # find end of first operand in right: up to first top binary operator
            for idx, x in enumerate(right):
                if isinstance(x, T) and x.s in ('&&', '||', '==', '!=', '<', '>', '<=', '>=', '+', '-', '|', '&'): break
                rend = idx + 1
            lpre, lop = strip_pre(left[st:])
            rpre, rop = strip_pre(right[:rend])
            call = [tk(('!' if kw == 'not_in' else '') + 'has(', lpre)] + rop + [tk(', ')] + lop + [tk(')')]
            return left[:st] + call + right[rend:]
    out = []
    n = len(items)
    i = 0
    while i < n:
        x = items[i]
        prev = out[-1] if out else None
        if isinstance(x, G):
            if x.o == '(':
                # type conversion call T(x)?
                if prev is not None and isinstance(prev, T) and prev.k in ('id', 'x') and prev.s in ('__CONVTYPE__',):
                    pass
                inner = conv_expr(x.items, cx)
                out.append(G(x.open, inner, x.close))
                # cast-style (^T)(x)
                if (prev is None or not is_operand_end(prev)) and x.items and is_type_like(x.items) and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '(':
                    out[-1] = tk('cast' + '(' + text(inner).strip() + ')', x.pre)
                i += 1; continue
            if x.o == '[':
                if prev is not None and is_operand_end(prev):
                    # index or slice
                    ci = find_top(x.items, ':')
                    if find_top(x.items, '?') >= 0: ci = -1
                    st = postfix_chain_start(out)
                    if ci >= 0:
                        lo = x.items[:ci]; hi = x.items[ci+1:]
                        base = out[st:]
                        bpre, base = strip_pre(base)
                        del out[st:]
                        args = text(base)
                        if lo and hi: call = f'sub({args}, {conv_s(lo, cx).strip()}, {conv_s(hi, cx).strip()})'
                        elif lo: call = f'sub_from({args}, {conv_s(lo, cx).strip()})'
                        elif hi: call = f'sub({args}, 0, {conv_s(hi, cx).strip()})'
                        else: call = f'view({args})'
                        out.append(tk(call, bpre))
                        i += 1; continue
                    if is_map_index_base(out, st):
                        base = out[st:]
                        bpre, base = strip_pre(base)
                        del out[st:]
                        out.append(tk(f'__MAPIDX__({text(base)}|{conv_s(x.items, cx).strip()})', bpre))
                        i += 1; continue
                    out.append(G(x.open, conv_expr(x.items, cx), x.close))
                    i += 1; continue
                # array type prefix: [N]T, []T, [dynamic]T, [^]T, [Enum]T
                inner = x.items
                j = type_extent(items, i + 1)
                elem = conv_s(items[i+1:j], cx).strip()
                if len(inner) == 1 and is_t(inner[0], '^'):
                    t = '*' + elem
                elif len(inner) == 1 and is_t(inner[0], 'dynamic'):
                    t = '[..]' + elem
                elif not inner:
                    t = '[]' + elem
                elif len(inner) == 1 and is_t(inner[0], '?'):
                    t = '[]' + elem  # [?]T{...}: inferred size
                    t = '__INFER__' + elem
                elif len(inner) == 1 and isinstance(inner[0], T) and inner[0].k == 'id' and inner[0].s in GLOBAL['types']:
                    t = f'[#run enum_count({inner[0].s})]{elem}'
                elif len(inner) == 3 and is_t(inner[1], '.') and isinstance(inner[2], T) and inner[2].s in GLOBAL['types']:
                    t = f'[#run enum_count({text(inner).strip()})]{elem}'
                else:
                    t = '[' + conv_s(inner, cx).strip() + ']' + elem
                # compound literal following?
                if j < n and isinstance(items[j], G) and items[j].o == '{' and not items[j].nl:
                    lit = conv_lit(items[j], cx, arr_elem=elem.startswith('['))
                    if t.startswith('__INFER__'):
                        out.append(tk(t[len('__INFER__'):] + '.[' + lit + ']', x.pre))
                    elif t.startswith('[]') and not t.startswith('[]u8') or t.startswith('[]'):
                        if lit.strip():
                            out.append(tk(t[2:] + '.[' + lit + ']', x.pre))
                        else:
                            out.append(tk('(' + t + ').{}', x.pre))
                    elif t.startswith('[..]'):
                        out.append(tk('(' + t + ').{}' if not lit.strip() else '__DYNLIT__(' + t + '|' + lit + ')', x.pre))
                    elif t.startswith('[#run') or not lit.strip():
                        out.append(tk('(' + t + ').{' + lit + '}' if lit.strip() else 'zero(' + t + ')', x.pre))
                    else:
                        out.append(tk(t[t.index(']') + 1:] + '.[' + lit + ']', x.pre))
                    i = j + 1; continue
                out.append(tk(t, x.pre))
                i = j; continue
            if x.o == '{':
                lit = conv_lit(x, cx)
                if prev is not None and is_operand_end(prev) and not (isinstance(prev, T) and prev.k in ('num', 'str')):
                    out.append(tk('.'))
                    out.append(tk('{' + lit + '}'))
                else:
                    out.append(tk('.{' + lit + '}', x.pre))
                i += 1; continue
        t = x
        s = t.s
        if t.k == 'id':
            if s == 'proc':
                txt, j, _ = conv_proc(items, i, cx)
                out.append(tk(txt, t.pre)); i = j; continue
            if s == 'struct' or s == 'union' or s == 'enum' or s == 'bit_field':
                txt, j = conv_typebody(items, i, cx)
                out.append(tk(txt, t.pre)); i = j; continue
            if s == 'map' and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '[':
                k = conv_s(items[i+1].items, cx).strip()
                j = type_extent(items, i + 2)
                v = conv_s(items[i+2:j], cx).strip()
                tt = f'Map({k}, {v})'
                if j < n and isinstance(items[j], G) and items[j].o == '{' and not items[j].nl:
                    lit = conv_lit(items[j], cx)
                    out.append(tk(tt + '.{}' if not lit.strip() else f'__MAPLIT__({tt}|{lit})', t.pre)); i = j + 1; continue
                out.append(tk(tt, t.pre)); i = j; continue
            if s == 'bit_set':
                g = items[i+1]
                e = conv_s(g.items, cx).split(';')[0].strip()
                out.append(tk(e, t.pre)); i += 2; continue
            if s in GLOBAL['bitset_alias'] and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '{' and not items[i+1].nl \
                    and not (prev is not None and is_t(prev, '.')):
                e = GLOBAL['bitset_alias'][s]
                vals = [conv_s(p, cx).strip() for p in split_commas(items[i+1].items) if p]
                vals = [(e + v if v.startswith('.') else v) for v in vals]
                out.append(tk('(' + (' | '.join(vals) if vals else f'cast({e}) 0') + ')', t.pre)); i += 2; continue
            if s == 'distinct':
                i += 1; continue
            if s == 'cast' or s == 'auto_cast':
                if s == 'auto_cast':
                    out.append(tk('xx', t.pre)); i += 1; continue
                g = items[i+1]
                out.append(tk('cast(' + conv_s(g.items, cx).strip() + ')', t.pre)); i += 2; continue
            if s == 'transmute':
                g = items[i+1]
                # operand: next unary/postfix chain
                j = i + 2
                rest = []
                # take a simple operand
                k = j
                while k < n and isinstance(items[k], T) and items[k].s in ('&', '-', '!', '~'):
                    k += 1
                k += 1
                while k < n and (isinstance(items[k], G) and items[k].o in '([' or is_t(items[k], '.') or is_t(items[k], '^')):
                    if is_t(items[k], '.'): k += 2
                    else: k += 1
                arg = conv_s(items[j:k], cx).strip()
                out.append(tk(f'transmute({conv_s(g.items, cx).strip()}, {arg})', t.pre)); i = k; continue
            if s == 'nil': out.append(tk('null', t.pre)); i += 1; continue
            if s == 'context':
                if i + 2 < n and is_t(items[i+1], '.') and items[i+2].s == 'temp_allocator':
                    out.append(tk('temp', t.pre)); i += 3; continue
                out.append(t); i += 1; continue
            if s in TYPES and not (prev is not None and is_t(prev, '.')):
                jt = TYPES[s]
                # conversion call T(x)
                if i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '(' and not items[i+1].nl and not (prev is not None and is_t(prev, '$')):
                    arg = conv_s(items[i+1].items, cx).strip()
                    if s == 'string': out.append(tk(f'as_string({arg})', t.pre))
                    elif s == 'cstring': out.append(tk(f'to_cstring({arg})', t.pre))
                    else: out.append(tk(f'cast({jt})({arg})', t.pre))
                    i += 2; continue
                out.append(tk(jt, t.pre)); i += 1; continue
            if s in GLOBAL['array_alias'] and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '{' and not items[i+1].nl \
                    and not (prev is not None and is_t(prev, '.')):
                elem, dyn = GLOBAL['array_alias'][s]
                lit = conv_lit(items[i+1], cx)
                out.append(tk((f'{elem}.[{lit}]' if lit.strip() else f'zero({s})') if not dyn else f'({s}).{{}}', t.pre)); i += 2; continue
            if s in GLOBAL['types'] and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '(' and not items[i+1].nl \
                    and not (prev is not None and is_t(prev, '.')) and s not in GLOBAL['poly_types']:
                arg = conv_s(items[i+1].items, cx).strip()
                out.append(tk(f'cast({s})({arg})', t.pre)); i += 2; continue
            if cx.imports.get(s) == 'fc_c' and i + 3 < n and is_t(items[i+1], '.') and isinstance(items[i+3], G) and items[i+3].o == '(' \
                    and ('c.' + items[i+2].s) in QUALIFIED:
                out.append(tk(f'cast({QUALIFIED["c." + items[i+2].s]})({conv_s(items[i+3].items, cx).strip()})', t.pre)); i += 4; continue
            # pkg.Type(x)
            if i + 3 < n and is_t(items[i+1], '.') and isinstance(items[i+2], T) and items[i+2].s in GLOBAL['types'] \
                    and isinstance(items[i+3], G) and items[i+3].o == '(' and s in cx.imports and items[i+2].s not in GLOBAL['poly_types']:
                arg = conv_s(items[i+3].items, cx).strip()
                out.append(tk(f'cast({s}.{items[i+2].s})({arg})', t.pre)); i += 4; continue
            if s in ('len', 'cap') and False: pass
            if s == 'make' and i + 1 < n and isinstance(items[i+1], G):
                out.append(tk(conv_make(items[i+1], cx), t.pre)); i += 2; continue
            if s == 'new' and i + 1 < n and isinstance(items[i+1], G):
                args = split_commas(items[i+1].items)
                a = [conv_s(p, cx).strip() for p in args]
                out.append(tk(f'new({", ".join(a)})', t.pre)); i += 2; continue
            if s == 'runtime' and i + 3 < n and is_t(items[i+1], '.') and items[i+2].s == 'default_context':
                out.append(tk('default_context()', t.pre)); i += 4; continue
            if s in ('or_return',):
                out.append(tk('__OR_RETURN__', t.pre)); i += 1; continue
            if s == 'size_of' or s == 'align_of' or s == 'offset_of' or s == 'type_of' or s == 'typeid_of':
                nm = {'typeid_of': 'type_of'}.get(s, s)
                if s == 'offset_of':
                    a = split_commas(items[i+1].items)
                    out.append(tk(f'offset_of({conv_s(a[0], cx).strip()}, "{text(a[1]).strip()}")', t.pre)); i += 2; continue
                out.append(tk(nm, t.pre)); i += 1; continue
            if s in ('min', 'max') and i + 1 < n and isinstance(items[i+1], G):
                a = items[i+1].items
                if len(a) == 1 and isinstance(a[0], T) and a[0].s in TYPES:
                    jt = TYPES[a[0].s]
                    lim = {'int': 'S64', 's64': 'S64', 's32': 'S32', 's16': 'S16', 's8': 'S8', 'u8': 'U8', 'u16': 'U16', 'u32': 'U32', 'u64': 'U64', 'float32': 'FLOAT32', 'float64': 'FLOAT64'}.get(jt, jt.upper())
                    out.append(tk(f'{lim}_{s.upper()}', t.pre)); i += 2; continue
            if prev is not None and is_t(prev, '.') and len(out) >= 2:
                out.append(tk(s + '_', t.pre) if s in HARD_KEYWORDS else t); i += 1; continue
            if s in JAI_RESERVED and not (i + 1 < n and is_t(items[i+1], '.') and s in cx.imports):
                out.append(tk(s + '_', t.pre)); i += 1; continue
            if s == 'ODIN_OS': out.append(tk('OS', t.pre)); i += 1; continue
            if s == 'ODIN_ARCH': out.append(tk('CPU', t.pre)); i += 1; continue
            if s == 'ODIN_DEBUG': out.append(tk('DEBUG', t.pre)); i += 1; continue
            out.append(t); i += 1; continue
        if t.k == 'op':
            if s == '^':
                if prev is not None and is_operand_end(prev):
                    if len(out) >= 2 and isinstance(out[-1], G) and isinstance(out[-2], T) and out[-2].s.strip().startswith('cast('):
                        g = out.pop(); c = out.pop()
                        out.append(tk('(' + c.s.strip() + text([g]).strip() + ')', c.pre))
                    out.append(tk('.*', t.pre))
                else:
                    out.append(tk('*', t.pre))
                i += 1; continue
            if s == '&':
                if prev is not None and is_operand_end(prev):
                    out.append(t)
                else:
                    out.append(tk('*', t.pre))
                i += 1; continue
            if s == '&~':
                out.append(tk('& ~', t.pre)); i += 1; continue
            if s == '~':
                out.append(tk('^' if prev is not None and is_operand_end(prev) else '~', t.pre)); i += 1; continue
            if s == '~=':
                out.append(tk('^=', t.pre)); i += 1; continue
            if s == '%%':
                out.append(tk('%', t.pre)); cx.notes.append('%%'); i += 1; continue
            if s == '..<' or s == '..=':
                out.append(tk(('__RANGE_EXCL__' if s == '..<' else '__RANGE_INCL__'), t.pre)); i += 1; continue
            if s == '.' and i + 1 < n and isinstance(items[i+1], G) and items[i+1].o == '(':
                # type assertion x.(T)
                out.append(tk(f'.__AS__({conv_s(items[i+1].items, cx).strip()})', t.pre)); i += 2; continue
            if s == '.' and i + 1 < n and is_t(items[i+1], '?'):
                out.append(tk('.__MAYBE__', t.pre)); i += 2; continue
            if s == '---':
                out.append(t); i += 1; continue
            if s == '$':
                out.append(tk('$', t.pre)); i += 1; continue
            out.append(t); i += 1; continue
        if t.k == 'chr': out.append(tk(char_lit(t.s), t.pre)); i += 1; continue
        if t.k == 'str': out.append(tk(str_lit(t.s), t.pre)); i += 1; continue
        if t.k == 'raw': out.append(tk(raw_lit(t.s), t.pre)); i += 1; continue
        if t.k == 'num':
            v = t.s
            if v.lower().startswith('0o'): v = str(int(v[2:].replace('_', ''), 8))
            m = re.fullmatch(r'([0-9_]+)(\.[0-9_]+)?[eE]([+-]?[0-9]+)', v)
            if m:
                mant, frac, ex = m.group(1).replace('_', ''), (m.group(2) or ''), int(m.group(3))
                if not frac and ex >= 0: v = str(int(mant) * 10 ** ex)
                else: v = f'{mant}{frac or ".0"}e{ex}'
            out.append(tk(v, t.pre)); i += 1; continue
        if t.k == 'dir':
            if s == '#caller_location': out.append(t); i += 1; continue
            if s == '#directory': out.append(tk('#filepath', t.pre)); i += 1; continue
            if s == '#procedure': out.append(tk('#procedure_name()', t.pre)); i += 1; continue
            if s == '#file': out.append(tk('#file', t.pre)); i += 1; continue
            if s == '#line': out.append(tk('#line', t.pre)); i += 1; continue
            if s == '#load':
                g = items[i+1]
                a = split_commas(g.items)
                path = text(a[0]).strip()
                out.append(tk(f'#run load_file({path}, #filepath)', t.pre)); i += 2; continue
            if s == '#load_directory':
                g = items[i+1]
                out.append(tk(f'#run load_directory({text(g.items).strip()}, #filepath)', t.pre)); i += 2; continue
            if s == '#config':
                g = items[i+1]
                a = split_commas(g.items)
                out.append(tk(conv_s(a[1], cx).strip(), t.pre)); i += 2; continue
            if s in ('#force_inline',):
                out.append(tk('inline', t.pre)); i += 1; continue
            if s in ('#force_no_inline',):
                out.append(tk('no_inline', t.pre)); i += 1; continue
            if s in ('#type', '#no_bounds_check', '#bounds_check', '#partial', '#optional_ok', '#any_int', '#by_ptr', '#no_alias', '#c_vararg'):
                i += 1; continue
            if s == '#sparse':
                i += 1; continue
            out.append(t); i += 1; continue
        out.append(t); i += 1
    # "a" + "b": constant string concatenation
    k = 0
    while k + 2 < len(out):
        a, op, b = out[k], out[k+1], out[k+2]
        if isinstance(a, T) and isinstance(b, T) and is_t(op, '+') and re.fullmatch(r'"(?:[^"\\]|\\.)*"', a.s) and re.fullmatch(r'"(?:[^"\\]|\\.)*"', b.s):
            out[k:k+3] = [tk(a.s[:-1] + b.s[1:], a.pre)]
            continue
        k += 1
    return out

def conv_make(g, cx):
    a = split_commas(g.items)
    targ = a[0]
    rest = [conv_s(p, cx).strip() for p in a[1:]]
    alloc = None
    f0 = targ[0]
    dyn = isinstance(f0, G) and f0.o == '[' and f0.items and is_t(f0.items[0], 'dynamic')
    slc = isinstance(f0, G) and f0.o == '[' and not f0.items
    # make([]T, n, alloc) / make([dynamic]T, len, cap, alloc); a 2-arg dynamic make is ambiguous
    if (slc and len(rest) >= 2) or (dyn and len(rest) == 3) or (is_t(f0, 'map') and rest):
        alloc = rest.pop()
    elif rest and re.search(r'allocator|temp\b|arena|alloc\b|\balloc', rest[-1]):
        alloc = rest.pop()
    al = f', allocator = {alloc}' if alloc else ''
    f = targ[0]
    if isinstance(f, G) and f.o == '[':
        j = type_extent(targ, 1)
        elem = conv_s(targ[1:j], cx).strip()
        if not f.items:
            return f'make_slice({elem}, {rest[0]}' + (f', {alloc})' if alloc else ')')
        if is_t(f.items[0], 'dynamic'):
            ln = rest[0] if rest else '0'
            cp = rest[1] if len(rest) > 1 else ln
            return f'make_dynamic({elem}, {ln}, {cp}' + (f', {alloc})' if alloc else ')')
    if is_t(f, 'map'):
        return f'{conv_s(targ, cx).strip()}.{{}}'
    return f'make({", ".join([conv_s(targ, cx).strip()] + rest)}{al})'

def conv_lit(g, cx, arr_elem=False):
    """Contents of a compound literal {...}. arr_elem: elements are fixed arrays, so nested {} become .[]."""
    parts = split_commas(g.items)
    out = []
    for p in parts:
        if not p: continue
        pre, p2 = strip_pre(p)
        ei = find_top(p2, '=')
        if ei > 0:
            k = p2[:ei]
            # field = value, or [index] = value (enumerated), or .Enum = value
            ktxt = conv_s(k, cx).strip()
            if not (len(k) == 1 and isinstance(k[0], T) and k[0].k == 'id'):
                ktxt = '__IDX__' + ktxt
            out.append(pre + ktxt + ' =' + conv_s(p2[ei+1:], cx))
        elif arr_elem and len(p2) == 1 and isinstance(p2[0], G) and p2[0].o == '{':
            out.append(pre + '.[' + conv_lit(p2[0], cx) + ']')
        else:
            out.append(pre + conv_s(p2, cx))
    trailing = g.close.pre
    return ','.join(out) + trailing

def conv_typebody(items, i, cx):
    """items[i] in struct/union/enum/bit_field. Returns (text, end)."""
    n = len(items)
    kw = items[i].s
    i += 1
    head = []
    # struct params / directives / enum backing type until '{'
    params = None
    while i < n and not (isinstance(items[i], G) and items[i].o == '{'):
        x = items[i]
        if isinstance(x, G) and x.o == '(' and head and head[-1] in ('#align', '#max_field_align', '#min_field_align'):
            head[-1] = head[-1] + ' ' + text(x.items).strip()
        elif isinstance(x, G) and x.o == '(' and kw in ('struct', 'union'):
            params = x
        elif isinstance(x, T) and x.k == 'dir':
            head.append(x.s)
        else:
            head.append(conv_s([x], cx).strip())
        i += 1
    body = items[i]
    i += 1
    members = split_commas(body.items)
    if kw == 'enum':
        backing = ' '.join(h for h in head if not h.startswith('#'))
        if cx.cur_decl in GLOBAL['bitset_enums']:
            kw = 'enum_flags'
            backing = GLOBAL['bitset_enums'][cx.cur_decl] or backing
        lines = []
        for m in members:
            if not m: continue
            pre, m2 = strip_pre(m)
            ei = find_top(m2, '=')
            if ei > 0:
                lines.append(pre + text(m2[:ei]).strip() + ' :: ' + conv_s(m2[ei+1:], cx).strip() + ';')
            else:
                lines.append(pre + text(m2).strip() + ';')
        tail = body.close.pre
        return (f'{kw}{(" " + backing) if backing else ""} {{' + ''.join(lines) + tail + '}', i)
    if kw == 'struct':
        lines = []
        pend = []
        for m in members:
            if not m: continue
            pre, m2 = strip_pre(m)
            # drop field tags (raw string after type)
            if m2 and isinstance(m2[-1], T) and m2[-1].k == 'raw':
                m2 = m2[:-1]
            ci = find_top(m2, ':')
            if ci < 0:
                pend.append((pre, text(m2).strip())); continue
            names = ', '.join([p[1] for p in pend] + [rn(text(m2[:ci]).strip())])
            ppre = pend[0][0] if pend else pre
            pend = []
            lines.append(ppre + names + ': ' + conv_s(m2[ci+1:], cx).strip() + ';')
        tail = body.close.pre
        jai_kw = 'struct'
        dirs = []
        for h in head:
            if h == '#raw_union': jai_kw = 'union'
            elif h == '#packed': dirs.append('#no_padding')
            elif h.startswith('#align'): pass
        p = ''
        if params is not None:
            p = ' (' + conv_proc_params(params, cx).replace('$', '') + ')'
        return (f'{jai_kw}{p} {{' + ''.join(lines) + tail + '}' + (' ' + ' '.join(dirs) if dirs else ''), i)
    if kw == 'union':
        alts = [conv_s(m, cx).strip() for m in members if m]
        return (f'__UNION__({"|".join(alts)})', i)
    return (f'__BITFIELD__({text(body.items)})', i)

# ---------------------------------------------------------------- statements
TERMINATORS = None

def split_statements(items):
    """Split a block's items into statements (lists of items). Uses Odin's newline rule."""
    stmts, cur = [], []
    def ends(x):
        if isinstance(x, G): return True
        if x.k in ('id',): return x.s not in ('else', 'do', 'in', 'not_in', 'or_else', 'proc', 'struct', 'enum', 'union', 'map', 'distinct', 'cast', 'transmute', 'auto_cast', 'using', 'defer', 'when', 'if', 'for', 'switch', 'case', 'where', 'bit_set', 'bit_field', 'foreign', 'import', 'package') or x.s in ('return', 'break', 'continue', 'fallthrough')
        if x.k in ('num', 'str', 'raw', 'chr'): return True
        if x.k == 'op': return x.s in ('^', '---', '?', ')', ']', '}')
        if x.k == 'dir': return x.s in ('#caller_location', '#file', '#line', '#procedure', '#directory')
        if x.k == 'tag': return True
        return False
    i = 0
    n = len(items)
    while i < n:
        x = items[i]
        if is_t(x, ';') and not open_header(cur):
            if cur: stmts.append(cur); cur = []
            i += 1; continue
        only_attr = len(cur) >= 2 and all(is_t(cur[k], '@') for k in range(0, len(cur), 2))
        if only_attr:
            pass
        elif cur and x.nl and is_t(x, 'case'):
            stmts.append(cur); cur = []
        elif cur and x.nl and ends(cur[-1]):
            # continuation rules: `else` on the next line belongs to the if
            if is_t(x, 'else') or (isinstance(x, T) and x.k == 'op' and x.s in ('.', '&&', '||', '+', '-', '|', '*', '/', '==', '!=', 'or_else')) and False:
                pass
            elif not (is_t(x, 'else')):
                stmts.append(cur); cur = []
        cur.append(x)
        i += 1
    if cur: stmts.append(cur)
    return stmts

def open_header(cur):
    hdr = False
    for x in cur:
        if isinstance(x, T) and x.k == 'id' and x.s in ('if', 'for', 'switch', 'when'): hdr = True
        elif isinstance(x, G) and x.o == '{' and hdr: hdr = False
        elif is_t(x, 'do'): hdr = False
    return hdr

def indent_of(pre):
    if '\n' in pre: return pre[pre.rindex('\n') + 1:]
    return ''

def conv_block(g, cx, inject=None, extra_open='', extra_close=''):
    """g: G '{' block. Returns text '{ ... }'."""
    stmts = split_statements(g.items)
    body = []
    ind = indent_of(g.close.pre) + '\t'
    if inject:
        for l in inject: body.append('\n' + ind + l)
    for st in stmts:
        body.append(conv_stmt(st, cx))
    return '{' + extra_open + ''.join(body) + g.close.pre + extra_close + '}'

def body_or_do(items, i, cx):
    """At items[i]: either a block G '{' or 'do' stmt. Returns (text, end)."""
    x = items[i]
    if isinstance(x, G) and x.o == '{':
        return ' ' + conv_block(x, cx), i + 1
    if is_t(x, 'do'):
        # rest of statement up to `else` at top level
        j = i + 1
        k = j
        d = 0
        while k < len(items):
            if is_t(items[k], 'if') and k > j: d += 1
            if is_t(items[k], 'else'):
                if d == 0: break
                d -= 1
            k += 1
        s = conv_stmt(items[j:k], cx).strip()
        return ' { ' + s + ' }', k
    raise Exception('expected block at ' + text(items[i:i+5]))

def header_until_block(items, i):
    j = i
    while j < len(items):
        x = items[j]
        if is_t(x, 'do'): break
        if isinstance(x, G) and x.o == '{':
            prev = items[j-1] if j > i else None
            if prev is not None and isinstance(prev, T) and prev.k == 'op' and prev.s not in (')', ']', '}', '^', '?', ';'):
                j += 1; continue
            break
        j += 1
    return j

def conv_if(items, i, cx, kw_text='if'):
    """items[i] == 'if' (or 'when'). Returns (text, end)."""
    pre = items[i].pre
    j = header_until_block(items, i + 1)
    header = items[i+1:j]
    init = None
    si = find_top(header, ';')
    if si >= 0:
        init, header = header[:si], header[si+1:]
    cond = conv_s(header, cx)
    is_when = items[i].s == 'when'
    kw = '#if' if is_when else 'if'
    body, k = body_or_do(items, j, cx)
    out = f'{kw}{cond}{body}'
    if k < len(items) and is_t(items[k], 'else'):
        k += 1
        if k < len(items) and (is_t(items[k], 'if') or is_t(items[k], 'when')):
            t2, k = conv_if(items, k, cx)
            out += ' else ' + t2.strip()
        else:
            b2, k = body_or_do(items, k, cx)
            out += ' else' + b2
    if init is not None:
        ind = indent_of(pre)
        out = '{ ' + conv_stmt(init, cx).strip() + '\n' + ind + out + ' }'
    return pre + out, k

def contains_tok(items, s, stop_nested_loops=True):
    for x in items:
        if isinstance(x, G):
            if contains_tok(x.items, s): return True
        elif is_t(x, s): return True
    return False

def rewrite_continue(g_text, post):
    return g_text

def conv_for(items, i, cx, label=None):
    cx.brk.append(('loop', None))
    cx.loop_stack.append('')  # a C-style loop pushes its post statement on top of this
    try:
        return conv_for_(items, i, cx, label)
    finally:
        cx.brk.pop()
        cx.loop_stack.pop()

def conv_for_(items, i, cx, label=None):
    pre = items[i].pre
    reverse = False
    j = header_until_block(items, i + 1)
    header = items[i+1:j]
    if not header:
        body, k = body_or_do(items, j, cx)
        return pre + 'while true' + body, k
    ii = find_top(header, 'in')
    semis = [idx for idx, x in enumerate(header) if is_t(x, ';')]
    if ii >= 0:
        names = header[:ii]
        rng = header[ii+1:]
        ptr = False
        nm = []
        for p in split_commas(names):
            pp = text(p).strip()
            if pp.startswith('&'): ptr = True; pp = pp[1:].strip()
            nm.append(rn(pp))
        # range?
        ri = -1
        for idx, x in enumerate(rng):
            if isinstance(x, T) and x.s in ('..<', '..='): ri = idx
        if ri >= 0:
            a = conv_s(rng[:ri], cx).strip()
            b = conv_s(rng[ri+1:], cx).strip()
            if rng[ri].s == '..<':
                if re.fullmatch(r'\d+', b): b = str(int(b) - 1)
                elif re.fullmatch(r'[\w.()\[\]]+', b): b = b + '-1'
                else: b = '(' + b + ')-1'
            src = f'{a}..{b}'
        else:
            src = conv_s(rng, cx).strip()
        loopname = nm[0] if nm else None
        last_id = None
        for xx_ in rng:
            if isinstance(xx_, T) and xx_.k == 'id': last_id = xx_.s
        is_iter_call = ri < 0 and len(rng) >= 2 and isinstance(rng[-1], G) and rng[-1].o == '(' and isinstance(rng[-2], T) and \
            (rng[-2].s.endswith('_iterator') or rng[-2].s.endswith('iterate') or rng[-2].s.endswith('_iter') or rng[-2].s.startswith('next'))
        if is_iter_call:
            call = conv_s(rng, cx).strip()
            okv = cx.fresh('ok')
            body, k = body_or_do(items, j, cx)
            b = body.strip()
            assert b.startswith('{')
            lhs = ', '.join(nm + ['_'] * 0)
            return pre + f'while true {{ {lhs}, {okv} := {call}; if !{okv} break;' + b[1:], k
        if False:
            if len(nm) == 1: nm = ['_', nm[0]]
            else: nm = [nm[1], nm[0]]
            if ptr: pass
        if label:
            if not nm or nm[0] == '_':
                if nm: nm[0] = label
                else: nm = [label]
            cx.label_map[label] = nm[0]
        body, k = body_or_do(items, j, cx)
        names_txt = ', '.join(nm)
        rev = '< ' if cx.pending_reverse else ''
        cx.pending_reverse = False
        return pre + f'for {rev}{"* " if ptr else ""}{names_txt}: {src}' + body, k
    if len(semis) == 2:
        init, cond, post = header[:semis[0]], header[semis[0]+1:semis[1]], header[semis[1]+1:]
        it, ct, pt = text(init).strip(), text(cond).strip(), text(post).strip()
        m1 = re.fullmatch(r'(\w+) := (.+)', it)
        if m1:
            v = m1.group(1)
            m2 = re.fullmatch(re.escape(v) + r' (<|<=) (.+)', ct)
            m3 = re.fullmatch(re.escape(v) + r' \+= 1', pt)
            m4 = re.fullmatch(re.escape(v) + r' (>=|>) (.+)', ct)
            m5 = re.fullmatch(re.escape(v) + r' -= 1', pt)
            assigns = assigns_var(items[j], v)
            if m2 and m3 and not assigns:
                a = conv_s(init[2:], cx).strip()
                b = conv_s(cond[2:], cx).strip()
                if m2.group(1) == '<': b = b + '-1' if re.fullmatch(r'[\w.()\[\]]+', b) else '(' + b + ')-1'
                body, k = body_or_do(items, j, cx)
                return pre + f'for {rn(v)}: {a}..{b}' + body, k
            if m4 and m5 and not assigns:
                a = conv_s(init[2:], cx).strip()
                b = conv_s(cond[2:], cx).strip()
                if m4.group(1) == '>': b = b + '+1' if re.fullmatch(r'[\w.()\[\]]+', b) else '(' + b + ')+1'
                body, k = body_or_do(items, j, cx)
                return pre + f'for < {rn(v)}: {a}..{b}' + body, k
        # general: { init; while cond { body; post } } with continue -> { post; continue; }
        posttxt = conv_stmt(post, cx).strip() if post else ''
        cx.loop_stack.append(posttxt)
        g = items[j]
        if isinstance(g, G):
            body = conv_block(g, cx, extra_close=('\t' + posttxt + '\n' if posttxt else ''))
            k = j + 1
        else:
            b, k = body_or_do(items, j, cx)
            body = b.strip()[:-1] + (' ' + posttxt if posttxt else '') + ' }'
        cx.loop_stack.pop()
        ind = indent_of(pre)
        lab = f'/*label {label}*/ ' if label else ''
        ctxt = conv_s(cond, cx) if cond else ' true'
        return pre + '{ ' + (conv_stmt(init, cx).strip() if init else '') + '\n' + ind + lab + 'while' + ctxt + ' ' + body.strip() + ' }', k
    # while
    body, k = body_or_do(items, j, cx)
    lab = f'/*label {label}*/ ' if label else ''
    return pre + lab + 'while' + conv_s(header, cx) + body, k

def assigns_var(g, v):
    toks = []
    def walk(xs):
        for x in xs:
            if isinstance(x, G): walk(x.items)
            else: toks.append(x)
    if isinstance(g, G): walk(g.items)
    for a, b in zip(toks, toks[1:]):
        if a.s == v and a.k == 'id' and b.k == 'op' and b.s in ('=', '+=', '-=', '*=', '/=', '|=', '&='): return True
    return False

def is_const_case(items):
    s = text(items).strip()
    if not s: return True
    if re.fullmatch(r"-?[0-9][0-9_xXa-fA-F.]*|\"[^\"]*\"|'[^']*'|`[^`]*`|\.[A-Za-z_]\w*|[A-Z][A-Z0-9_]*|[\w]+\.[A-Z_][\w]*|[\w]+\.[\w]+\.[A-Z_][\w]*|true|false|nil", s):
        return True
    return False

def conv_switch(items, i, cx, label=None):
    info = {'broke': False, 'cont': False, 'name': cx.fresh('sw')}
    cx.brk.append(('switch', info))
    try:
        t, k = conv_switch_(items, i, cx, label)
    finally:
        cx.brk.pop()
    if info['broke']:
        pre = t[:len(t) - len(t.lstrip())]
        t = pre + f'for {info["name"]}: 0..0 {{ ' + t.lstrip() + ' }'
        if info['cont']: t = t + ' /*SWITCH-CONTINUE: check*/'
    return t, k

def conv_switch_(items, i, cx, label=None):
    pre = items[i].pre
    j = header_until_block(items, i + 1)
    header = items[i+1:j]
    init = None
    si = find_top(header, ';')
    if si >= 0: init, header = header[:si], header[si+1:]
    ind = indent_of(pre)
    body_g = items[j]
    # split into cases
    stmts = split_statements(body_g.items)
    cases = []
    for st in stmts:
        if is_t(st[0], 'case'):
            ci = find_top(st, ':')
            vals = st[1:ci]
            rest = st[ci+1:]
            cases.append([vals, [], st[0].pre])
            if rest: cases[-1][1].append(rest)
        else:
            if not cases: cases.append([None, [], ''])
            cases[-1][1].append(st)
    ii = find_top(header, 'in')
    typeswitch = ii >= 0
    subject = conv_s(header[ii+1:] if typeswitch else header, cx).strip()
    has_range = any(c[0] and any(isinstance(x, T) and x.s in ('..<', '..=') for x in c[0]) for c in cases)
    const = all(c[0] is None or all(is_const_case(v) for v in split_commas(c[0])) for c in cases)
    out = ''
    if typeswitch:
        var = text(header[:ii]).strip()
        ptr = var.startswith('&')
        var = rn(var.lstrip('&').strip())
        subj = subject
        tmp_decl = ''
        if not re.fullmatch(r'[\w.]+', subject):
            tmpn = cx.fresh('v')
            tmp_decl = f'{tmpn} := {subject};\n{ind}'
            subj = tmpn
        out = f'if {subj}.kind == {{'
        for vals, sts, cpre in cases:
            if not vals:
                out += cpre + 'case;' + (f' {var} := {subj};' if var != '_' else '')
            else:
                tys = [conv_s(v, cx).strip() for v in split_commas(vals)]
                ks = [union_kind(t) for t in tys]
                out += cpre + ' #through; '.join(f'case .{k[0]};' for k in ks)
                if var != '_':
                    if len(ks) == 1 and ks[0][1]:
                        out += f' {var} := {"*" if ptr else ""}{subj}.{ks[0][1]};'
                    elif len(ks) == 1: pass
                    else: out += f' {var} := {subj};'
            for st in sts: out += conv_stmt(st, cx)
        out += body_g.close.pre + '}'
        if tmp_decl: out = '{ ' + tmp_decl + out + ' }'
    elif subject and const and not has_range:
        out = f'if {subject} == {{'
        for vals, sts, cpre in cases:
            if vals is None or not vals:
                out += cpre + 'case;'
            else:
                vs = [conv_s(v, cx).strip() for v in split_commas(vals)]
                out += cpre + (' #through; '.join(f'case {v};' for v in vs))
            cx.switch_depth += 1
            for st in sts: out += conv_stmt(st, cx)
            cx.switch_depth -= 1
        out += body_g.close.pre + '}'
    else:
        # if/else chain
        subj = subject
        tmp_decl = ''
        if subject and not re.fullmatch(r'[\w.]+', subject):
            tmpn = cx.fresh('sw')
            tmp_decl = f'{tmpn} := {subject};\n{ind}'
            subj = tmpn
        first = True
        default = None
        chain = ''
        for vals, sts, cpre in cases:
            if vals is None or not vals:
                default = sts; continue
            conds = []
            for v in split_commas(vals):
                ri = -1
                for idx, x in enumerate(v):
                    if isinstance(x, T) and x.s in ('..<', '..='): ri = idx
                if ri >= 0:
                    a = conv_s(v[:ri], cx).strip(); b = conv_s(v[ri+1:], cx).strip()
                    op = '<' if v[ri].s == '..<' else '<='
                    conds.append(f'({subj} >= {a} && {subj} {op} {b})' if subj else '')
                elif subj:
                    conds.append(f'{subj} == {conv_s(v, cx).strip()}')
                else:
                    conds.append(f'({conv_s(v, cx).strip()})')
            cond = ' || '.join(conds) if len(conds) > 1 else (conds[0][1:-1] if not subj and conds[0].startswith('(') else conds[0])
            cx.switch_depth += 1
            body = ''.join(conv_stmt(st, cx) for st in sts)
            cx.switch_depth -= 1
            chain += ('' if first else ' else ') + f'if {cond} {{' + body + cpre + '}'
            first = False
        if default is not None:
            cx.switch_depth += 1
            body = ''.join(conv_stmt(st, cx) for st in default)
            cx.switch_depth -= 1
            if first: chain += '{' + body + body_g.close.pre + '}'
            else: chain += ' else {' + body + body_g.close.pre + '}'
        out = tmp_decl + chain
        if tmp_decl: out = '{ ' + out + ' }'
    if init is not None:
        out = '{ ' + conv_stmt(init, cx).strip() + '\n' + ind + out + ' }'
    return pre + out, j + 1

UNION_KINDS = {'bool': ('Bool', 'b'), 's64': ('Int', 'i'), 'float64': ('Float', 'f'), 'Big': ('Big', 'big'), 'string': ('String', 's'),
    'Atom': ('Atom', 's'), 'Charlist': ('Charlist', 's'), 'List': ('List', 'list'), 'Tuple': ('Tuple', 'list'), 'Map': ('Map', 'map'),
    'null': ('Nil', None), 'Null': ('Nil', None), 'Integer': ('Int', 'i'), 'Float': ('Float', 'f'), 'Boolean': ('Bool', 'b'),
    'String': ('String', 's'), 'Array': ('List', 'list'), 'Object': ('Map', 'map')}
QUALIFIED = {'sync.atomic_load': 'atomic_load', 'sync.atomic_store': 'atomic_store', 'sync.atomic_add': 'atomic_add', 'sync.atomic_exchange': 'atomic_exchange',
    'intrinsics.atomic_load': 'atomic_load', 'intrinsics.atomic_store': 'atomic_store', 'os.remove': 'os.remove_','c.int': 's32', 'c.uint': 'u32', 'c.long': 's64', 'c.ulong': 'u64', 'c.size_t': 'u64', 'c.ssize_t': 's64', 'c.char': 'u8',
    'c.schar': 's8', 'c.uchar': 'u8', 'c.short': 's16', 'c.ushort': 'u16', 'c.longlong': 's64', 'c.ulonglong': 'u64', 'c.float': 'float32',
    'c.double': 'float64', 'c.bool': 'bool', 'c.int32_t': 's32', 'c.uint32_t': 'u32', 'c.int64_t': 's64', 'c.uint64_t': 'u64', 'c.uint8_t': 'u8',
    'c.int8_t': 's8', 'c.uint16_t': 'u16', 'c.int16_t': 's16', 'c.intptr_t': 's64', 'c.uintptr_t': 'u64','mem.Allocator': 'Allocator', 'runtime.Allocator': 'Allocator', 'runtime.Source_Code_Location': 'Source_Code_Location',
    'runtime.Context': 'type_of(context)', 'mem.Allocator_Error': 'mem.Allocator_Error', 'runtime.heap_allocator()': 'context.default_allocator',
    'strings.clone': 'clone', 'slice.clone': 'clone', 'runtime.default_context()': 'default_context()'}
def union_kind(t):
    t = t.split('.')[-1].strip()
    return UNION_KINDS.get(t, (t, t.lower()))

def fix_assert(txt):
    # x.__AS__(T) -> x.field
    return re.sub(r'\.__AS__\(([\w.]+)\)', lambda m: '.' + (union_kind(m.group(1))[1] or 'kind'), txt)

def conv_assign_like(st, cx):
    """Declarations / assignments / expression statements. Handles or_return, map comma-ok."""
    # find top-level assignment operator
    ops = ('=', ':=', '+=', '-=', '*=', '/=', '%=', '|=', '&=', '~=', '<<=', '>>=', '&~=', '%%=', '&&=', '||=')
    ai = -1
    for idx, x in enumerate(st):
        if isinstance(x, T) and x.k == 'op' and x.s in ops:
            ai = idx; break
        if isinstance(x, T) and x.k == 'op' and x.s == ':' and idx > 0:
            # typed decl `x: T = v` or `x: T : v`
            ai = -2; break
        if isinstance(x, T) and x.k == 'op' and x.s == '::':
            ai = -3; break
    pre = pre_of(st[0])
    if ai == -1:
        e = conv_expr(st, cx)
        txt = text(e)
        return fix_or_return(txt, None, None, cx, pre) + ';'
    if ai in (-2, -3):
        return text(conv_decl_items(st, cx)) + ';'
    lhs, op, rhs = st[:ai], st[ai].s, st[ai+1:]
    if op == '~=': op = '^='
    if op == '%%=': op = '%='
    if op == '&~=':
        return conv_s(lhs, cx) + ' &= ~(' + conv_s(rhs, cx).strip() + ');'
    lhs_parts = split_commas(lhs)
    # map comma-ok / pointer comma-ok
    rhs_items = [x for x in rhs]
    if len(lhs_parts) == 2 and rhs_items and find_top(rhs_items, 'or_return') < 0:
        r = conv_expr(rhs_items, cx)
        rt = text(r).strip()
        ma = re.fullmatch(r'(.*)\.__AS__\(([\w.]+)\)', rt, re.S)
        if ma:
            k = union_kind(ma.group(2))
            base = ma.group(1).strip()
            return conv_s(lhs, cx) + f' {op} {base}.{k[1] or "kind"}, {base}.kind == .{k[0]};'
        m = re.fullmatch(r'(\*?)__MAPIDX__\((.*)\|(.*)\)', rt, re.S)
        if m:
            fn = 'map_find_ptr' if m.group(1) else 'map_find'
            return conv_s(lhs, cx) + f' {op} {fn}(' + ('*' if m.group(1) else '') + f'{m.group(2)}, {m.group(3)});'
    # _ = x
    if len(lhs_parts) == 1 and text(lhs).strip() == '_' and op == '=':
        r = conv_s(rhs, cx).strip()
        if re.fullmatch(r'[\w.]+', r): return ''
        return pre + r + ';'
    lt = conv_s(lhs, cx)
    rt = conv_s(rhs, cx)
    if lt.strip() == 'context' and op == '=':
        v = cx.fresh('ctx')
        if rt.strip() == 'default_context()': return f'{pre}{v}: #Context; push_context,defer_pop {v};'
        return f'{pre}{v} := {rt.strip()}; push_context,defer_pop {v};'
    # lvalue map index
    mm = re.fullmatch(r'(\s*)__MAPIDX__\((.*)\|(.*)\)', lt, re.S)
    if mm and op == '=' and len(lhs_parts) == 1:
        return f'{mm.group(1)}at(*{mm.group(2)}, {mm.group(3)}).* ={rt};'
    lt = re.sub(r'__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'at(*\1, \2).*', lt)
    return fix_or_return(lt + ' ' + op + rt, lt, op, cx, pre) + ';'

VCTOR = {'s64': 'vint', 'float64': 'vfloat', 'Map': 'vmap', 'List': 'vlist', 'Tuple': 'vtuple', 'Atom': 'vatom', 'Charlist': 'vcharlist', 'bool': 'vbool', 'string': 'vstring'}
def wrap_value(t, ty):
    pkg = ty[:-len(ty.split('.')[-1])]
    if ty in ('V',): pkg = 'etf.'
    m = re.fullmatch(r'cast\(((?:etf\.)?\w+)\)\((.*)\)', t, re.S)
    if m and m.group(1).split('.')[-1] in VCTOR:
        return f'{pkg}{VCTOR[m.group(1).split(".")[-1]]}({m.group(2)})'
    if re.fullmatch(r'(?:etf\.)?Big\.\{.*\}', t, re.S): return f'{pkg}vbig({t})'
    if t in ('true', 'false'): return f'{pkg}vbool({t})'
    if re.fullmatch(r'"(?:[^"\\]|\\.)*"', t): return f'{pkg}vstring({t})'
    if re.fullmatch(r'-?\d+', t): return f'{pkg}vint({t})'
    return t

def fixed_array_type(t):
    t = t.strip()
    if t in GLOBAL['array_alias']: return not GLOBAL['array_alias'][t][1]
    return bool(re.match(r'\[[^\].]', t)) and not t.startswith('[..]')

def nullable_type(t):
    t = t.strip()
    return t.startswith('*') or t.startswith('(') or t in ('Any', 'Error', 'os.Error', 'Id', 'objc.Id', 'SEL', 'Type') or t.endswith('Error') and '.' in t \
        or t in GLOBAL.get('pointer_types', ())

def fix_idx(r):
    r = re.sub(r'\*__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'at(*\1, \2)', r)
    return re.sub(r'__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'get(\1, \2)', r)

def fix_or_return(txt, lhs, op, cx, pre):
    txt = re.sub(r'\*__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'at(*\1, \2)', txt)
    txt = re.sub(r'__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'get(\1, \2)', txt)
    if '__OR_RETURN__' not in txt: return txt
    # forms: LHS := EXPR __OR_RETURN__   |  EXPR __OR_RETURN__
    proc = cx.proc_stack[-1] if cx.proc_stack else {'res': [], 'named': False}
    res = proc['res']
    e = cx.fresh('e')
    ind = indent_of(pre)
    body = txt.strip()
    if not body.endswith('__OR_RETURN__'):
        return pre + '/*OR_RETURN nested*/ ' + body
    body = body[:-len('__OR_RETURN__')].rstrip()
    if lhs is not None:
        lhs_s = lhs.strip()
        rhs_s = body[body.index(op) + len(op):].strip()
        ma = re.fullmatch(r'(.*)\.__AS__\(([\w.]+)\)', rhs_s, re.S)
        if ma and op == ':=':
            k = union_kind(ma.group(2))
            base = ma.group(1)
            if not res: ret = 'return;'
            elif proc['named']: ret = 'return ' + ', '.join(r[0] for r in res) + ';'
            elif len(res) == 1: ret = 'return ' + ('false' if res[0][1] == 'bool' else '.{}') + ';'
            else: ret = 'return ' + ', '.join(f'zero({r[1]})' for r in res[:-1]) + ', false;'
            return f'{pre}if {base}.kind != .{k[0]} {ret} {lhs_s} := {base}.{k[1]}'
        if op == ':=': decl = f'{lhs_s}, {e} := {rhs_s};'
        else:
            v = cx.fresh('v')
            decl = f'{v}, {e} := {rhs_s};'
            res2 = res
            if not res2: ret = 'return;'
            elif proc['named']: ret = 'return ' + ', '.join([r[0] for r in res2[:-1]] + [e]) + ';'
            elif len(res2) == 1: ret = f'return {e};'
            else: ret = 'return ' + ', '.join(f'zero({r[1]})' for r in res2[:-1]) + f', {e};'
            return f'{pre}{decl} if failed({e}) {ret} {lhs_s} {op} {v}'
    else:
        decl = f'{e} := {body};'
    if not res:
        ret = 'return;'
    elif proc['named']:
        vals = [r[0] for r in res[:-1]] + [e]
        ret = 'return ' + ', '.join(vals) + ';'
    elif len(res) == 1:
        ret = f'return {e};'
    else:
        ret = 'return ' + ', '.join(f'zero({r[1]})' for r in res[:-1]) + f', {e};'
    return f'{pre}{decl} if failed({e}) {ret[:-1]}'

def conv_decl_items(st, cx):
    """`name: T = v`, `name : T : v`, `name :: v`, `a, b: T`."""
    i = 0
    n = len(st)
    # names before ':' or '::'
    out = []
    for idx, x in enumerate(st):
        if is_t(x, ':') or is_t(x, '::'):
            break
    names = st[:idx]
    pre, names = strip_pre(names)
    nm = conv_s(names, cx).strip()
    nm = ', '.join(rn(p.strip()) for p in nm.split(','))
    if is_t(st[idx], '::'):
        rhs = st[idx+1:]
        return [tk(pre + nm + ' ::' + conv_rhs_decl(rhs, cx, nm))]
    rest = st[idx+1:]
    # typed: find '=' or ':' at top
    ei = find_top(rest, '=')
    ci = find_top(rest, ':')
    if ci >= 0 and (ei < 0 or ci < ei):
        typ = conv_s(rest[:ci], cx).strip()
        return [tk(pre + nm + ': ' + typ + ' :' + conv_rhs_decl(rest[ci+1:], cx, nm))]
    if ei >= 0:
        typ = conv_s(rest[:ei], cx).strip()
        v = conv_s(rest[ei+1:], cx)
        if v.strip() == 'null' and not nullable_type(typ): v = ' .{}'
        if fixed_array_type(typ) and v.strip().startswith('.{') and v.strip().endswith('}'): v = ' .[' + v.strip()[2:-1] + ']'
        return [tk(pre + nm + ': ' + typ + ' =' + v)]
    typ = conv_s(rest, cx).strip()
    return [tk(pre + nm + ': ' + typ)]

def conv_rhs_decl(rhs, cx, name):
    if rhs and is_t(rhs[0], 'distinct'):
        rhs = rhs[1:]
    t = conv_s(rhs, cx)
    m = re.fullmatch(r'\s*__OVERLOAD__\((.*)\)', t)
    if m:
        cx.overloads[name] = m.group(1).split(',')
        return ' __OVERLOAD__'
    return t

def conv_stmt(st, cx):
    if not st: return ''
    x = st[0]
    pre = pre_of(x)
    # attributes
    attrs = []
    while st and is_t(st[0], '@'):
        if isinstance(st[1], G):
            attrs.append(text(st[1].items).strip()); st = st[2:]
        else:
            attrs.append(st[1].s); st = st[2:]
    if not st: return ''
    if attrs:
        st = list(st)
        st[0] = (lambda f: G(T(f.open.k, f.open.s, pre), f.items, f.close, f.kind) if isinstance(f, G) else T(f.k, f.s, pre))(st[0])
    x = st[0]
    s = x.s if isinstance(x, T) else None
    if isinstance(x, T) and x.k == 'tag': return ''
    if s == 'package' and x.k == 'id': return ''
    if s == 'import' and x.k == 'id':
        return pre + conv_import(st, cx)
    if s == 'foreign' and x.k == 'id':
        return conv_foreign(st, cx, attrs, pre)
    # label
    if isinstance(x, T) and x.k == 'id' and len(st) > 2 and is_t(st[1], ':') and isinstance(st[2], T) and st[2].s in ('for', 'switch') :
        lab = x.s
        st2 = list(st[2:]); st2[0] = T(st2[0].k, st2[0].s, pre)
        if st2[0].s == 'for':
            t, k = conv_for(st2, 0, cx, label=lab)
        else:
            t, k = conv_switch(st2, 0, cx, label=lab); t = f'{pre}/*label {lab}*/' + t.lstrip()
        return t + conv_rest(st2[k:], cx)
    if isinstance(x, T) and x.k == 'id' and len(st) > 2 and is_t(st[1], ':') and isinstance(st[2], G) and st[2].o == '{':
        return pre + f'/*label {x.s}*/ ' + conv_block(st[2], cx)
    if s == '#partial' or s == '#no_bounds_check' or s == '#bounds_check':
        st2 = list(st[1:]); st2[0] = T(st2[0].k, st2[0].s, pre) if isinstance(st2[0], T) else st2[0]
        return conv_stmt(st2, cx)
    if s == '#reverse':
        cx.pending_reverse = True
        st2 = list(st[1:]); st2[0] = T(st2[0].k, st2[0].s, pre)
        return conv_stmt(st2, cx)
    if s == '#assert':
        return pre + '#assert ' + conv_s(st[1].items, cx).strip() + ';'
    if s == 'if' or s == 'when':
        t, k = conv_if(st, 0, cx)
        return t + conv_rest(st[k:], cx)
    if s == 'for':
        t, k = conv_for(st, 0, cx)
        return t + conv_rest(st[k:], cx)
    if s == 'switch':
        t, k = conv_switch(st, 0, cx)
        return t + conv_rest(st[k:], cx)
    if s == 'defer' and x.k == 'id':
        rest = list(st[1:])
        inner = conv_stmt(rest, cx)
        return pre + 'defer ' + inner.strip()
    if s == 'return' and x.k == 'id':
        rest = st[1:]
        if not rest and cx.proc_stack and cx.proc_stack[-1]['named']:
            return pre + 'return ' + ', '.join(r[0] for r in cx.proc_stack[-1]['res']) + ';'
        res = cx.proc_stack[-1]['res'] if cx.proc_stack else []
        parts = split_commas(rest)
        if len(parts) == len(res) and len(res) > 0:
            conv = []
            for p, r_ in zip(parts, res):
                t = conv_s(p, cx)
                if t.strip() == 'null' and not nullable_type(r_[1]): t = ' .{}'
                elif fixed_array_type(r_[1]) and t.strip().startswith('.{') and t.strip().endswith('}'): t = ' .[' + t.strip()[2:-1] + ']'
                elif r_[1].split('.')[-1] in ('Value', 'V') and r_[1] not in ('json.Value',): t = ' ' + wrap_value(t.strip(), r_[1])
                conv.append(t)
            r = ','.join(conv)
        else:
            r = conv_s(rest, cx)
        nres = len(res)
        if nres > 1 and rest and find_top(rest, ',') < 0 and '__OR_RETURN__' not in r:
            r2 = fix_idx(r.strip())
            vs = [cx.fresh('r') for _ in range(nres)]
            return pre + '{ ' + ', '.join(vs) + ' := ' + r2 + '; return ' + ', '.join(vs) + '; }'
        r = re.sub(r'\*__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'at(*\1, \2)', r)
        r = re.sub(r'__MAPIDX__\(((?:[^|()]|\([^()]*\))*)\|((?:[^()]|\([^()]*\))*)\)', r'get(\1, \2)', r)
        return pre + 'return' + r + ';'
    if s == 'break' or s == 'continue':
        lab = st[1].s if len(st) > 1 else None
        if lab: lab = cx.label_map.get(lab, lab)
        if s == 'continue' and cx.loop_stack and cx.loop_stack[-1] and not lab:
            return pre + '{ ' + cx.loop_stack[-1] + ' continue; }'
        if s == 'break' and cx.brk and cx.brk[-1][0] == 'switch' and not lab:
            cx.brk[-1][1]['broke'] = True
            return pre + 'break ' + cx.brk[-1][1]['name'] + ';'
        if s == 'continue' and cx.brk and cx.brk[-1][0] == 'switch' and not lab:
            cx.brk[-1][1]['cont'] = True
        return pre + s + (' ' + lab if lab else '') + ';'
    if s == 'fallthrough':
        return pre + '#through;'
    if s == 'using' and x.k == 'id':
        return pre + 'using ' + conv_s(st[1:], cx).strip() + ';'
    if isinstance(x, G) and x.o == '{':
        return pre + conv_block(x, cx)
    # declaration of proc / struct etc
    if len(st) >= 4 and is_t(st[1], '::') and isinstance(st[2], T) and st[2].s == '#type':
        st = st[:2] + st[3:]
    if len(st) >= 3 and is_t(st[1], '::') and isinstance(st[2], T) and st[2].s in ('proc', 'struct', 'enum', 'union', 'bit_field'):
        name = rn(x.s)
        scope = attr_scope(attrs)
        cx.cur_decl = x.s
        t = conv_s(st[2:], cx)
        cx.cur_decl = None
        if st[2].s == 'proc' and t.strip().startswith('__OVERLOAD__'):
            cx.overloads[name] = t.strip()[len('__OVERLOAD__('):-1].split(',')
            return ''
        if st[2].s == 'proc' and '#c_call' in t.split('{')[0] and 'push_context' not in t:
            pass
        semi = '' if (t.rstrip().endswith('}') and st[2].s != 'union') else ';'
        if st[2].s == 'proc' and not t.rstrip().endswith('}'):
            semi = ';'
            t = '#type ' + t.strip()
        return scope[0] + pre + name + ' :: ' + t.strip() + semi + scope[1]
    if attrs:
        scope = attr_scope(attrs)
        extra = ''
        if any(a == 'static' for a in attrs) and cx.proc_stack:
            d = conv_assign_like(st, cx)
            d = d.split('\n')[-1] if '//' in d else d
            nm = re.match(r'\s*(\w+)', d).group(1)
            cx.proc_stack[-1]['statics'].append((nm, d))
            return ''
        if any(a.startswith('thread_local') for a in attrs):
            d = conv_assign_like(st, cx).strip()
            d = d.split('\n')[-1].strip()
            nm = re.match(r'(\w+)', d).group(1)
            cx.thread_locals.append(nm)
            return pre + '#add_context ' + d
        return scope[0] + pre + extra + conv_assign_like(st, cx).lstrip() + scope[1]
    return conv_assign_like(st, cx)

def conv_rest(rest, cx):
    if not rest: return ''
    return conv_stmt(rest, cx)

def attr_scope(attrs):
    for a in attrs:
        if a.startswith('private'):
            if 'file' in a: return ('\n#scope_file', '\n#scope_export')
            return ('\n#scope_module', '\n#scope_export')
    return ('', '')

def conv_import(st, cx):
    # import [name] "path"
    if isinstance(st[1], T) and st[1].k == 'str':
        name = None; path = st[1].s.strip('"')
    else:
        name = st[1].s; path = st[2].s.strip('"')
    if path.startswith('fc:'):
        mod = path[3:]
        nm = name or mod.split('/')[-1]
        jm = mod.replace('/', '_')
        cx.imports[nm] = jm
        return ''
    if path in CORE:
        nm = name or path.split('/')[-1].split(':')[-1]
        cx.imports[nm] = 'fc_' + CORE[path]
        return ''
    cx.imports[name or path] = path
    return ''

def conv_foreign(st, cx, attrs, pre):
    # foreign import name "lib" | foreign import name {"a", "b"} | foreign name { decls }
    if is_t(st[1], 'import'):
        if isinstance(st[2], T) and st[2].k == 'str':
            name = '__lib' + str(cx.fresh()); libs = [st[2].s]
        else:
            name = st[2].s
            libs = [x.s for x in (st[3].items if isinstance(st[3], G) else [st[3]]) if isinstance(x, T) and x.k == 'str']
        cx.foreign_libs[name] = libs
        return ''
    # foreign block
    lib = st[1].s if isinstance(st[1], T) else None
    g = st[-1]
    if not lib: lib = '__libc'
    body = []
    for s2 in split_statements(g.items):
        a2 = []
        while s2 and is_t(s2[0], '@'):
            if isinstance(s2[1], G): a2.append(text(s2[1].items).strip()); s2 = s2[2:]
            else: a2.append(s2[1].s); s2 = s2[2:]
        if not s2: continue
        p2 = pre_of(s2[0])
        link = None
        for a in a2:
            m = re.match(r'link_name\s*=\s*"([^"]+)"', a)
            if m: link = m.group(1)
        if len(s2) >= 3 and is_t(s2[1], '::') and is_t(s2[2], 'proc'):
            sig, j, _ = conv_proc(s2, 2, cx, as_type=True)
            nm = rn(s2[0].s)
            if sig.endswith(' #c_call'): sig = sig[:-len(' #c_call')]
            body.append(f'{p2}{nm} :: {sig} #foreign {lib}' + (f' "{link}"' if link else '') + ';')
        elif len(s2) >= 2 and is_t(s2[1], ':'):
            nm = s2[0].s
            typ = conv_s(s2[2:], cx).strip()
            body.append(f'{p2}{nm}: {typ} #elsewhere {lib}' + (f' "{link}"' if link else '') + ';')
        else:
            body.append(p2 + '/*FOREIGN?*/ ' + text(s2))
    return attr_scope(attrs)[0] + ''.join(body) + attr_scope(attrs)[1]

# ---------------------------------------------------------------- file
def collect_globals(files):
    for f in files:
        src = open(f).read()
        for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s*::\s*(?:distinct\s+)?(struct|enum|union|bit_set|bit_field|\[|\^|map\[|[a-z0-9_]+\s*$|[a-zA-Z_][\w.]*\s*$)', src, re.M):
            name, kind = m.group(1), m.group(2).strip()
            if kind in ('struct', 'enum', 'union', 'bit_set', 'bit_field', '[', '^', 'map['): GLOBAL['types'].add(name)
            elif kind in TYPES or (kind[:1].isupper() and '.' not in kind) or re.match(r'[a-z_]+\.[A-Z]', kind): GLOBAL['types'].add(name)
            if kind == 'map[': GLOBAL['map_types'].add(name)
        GLOBAL['map_types'].add('Object')
        for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s*::\s*(?:distinct\s+)?\[([^\]]*)\]\s*([\w.]+)\s*$', src, re.M):
            et = TYPES.get(m.group(3), m.group(3))
            GLOBAL['array_alias'][m.group(1)] = (et, m.group(2).strip() in ('dynamic', ''))
        for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s*::\s*bit_set\[\s*([\w.]+)\s*(?:;\s*(\w+))?\s*\]', src, re.M):
            GLOBAL['bitset_alias'][m.group(1)] = m.group(2)
            GLOBAL['bitset_enums'][m.group(2).split('.')[-1]] = TYPES.get(m.group(3), m.group(3)) if m.group(3) else None
        for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s*::\s*struct\s*\(', src, re.M):
            GLOBAL['poly_types'].add(m.group(1))
    for f in files:
        src = open(f).read()
        for m in re.finditer(r'\b([a-z_]\w*)\s*:\s*\^?(?:map\[|(\w+)\b)', src):
            name = m.group(1); t = m.group(2)
            if t is None or t in GLOBAL['map_types']:
                GLOBAL['maps'].add(name)
        for m in re.finditer(r'\b([a-z_]\w*)\s*:?=\s*make\(map\[', src):
            GLOBAL['maps'].add(m.group(1))
        for m in re.finditer(r'\b([a-z_]\w*)\s*:=\s*map\[', src):
            GLOBAL['maps'].add(m.group(1))
        for m in re.finditer(r'\b([a-z_]\w*)\s*:\s*(\^?)([\w.\[\]]+)', src):
            t = m.group(3)
            if not t.startswith('map[') and t.split('.')[-1] not in GLOBAL['map_types']:
                GLOBAL.setdefault('nonmaps', set()).add(m.group(1))
    amb = GLOBAL['maps'] & GLOBAL.get('nonmaps', set())
    GLOBAL['maps'] -= amb
    GLOBAL['ambiguous_maps'] = amb
    open('/private/tmp/claude-501/-Users-creikey-Documents-fastcord/631d22d7-f4cc-46a9-909b-9855652e7f92/scratchpad/ambiguous_maps.txt', 'w').write('\n'.join(sorted(amb)))
GLOBAL['poly_types'] = set()
GLOBAL['array_alias'] = {}
GLOBAL['bitset_alias'] = {}
GLOBAL['bitset_enums'] = {}

def convert_file(path, pkg):
    src = open(path).read()
    toks = lex(src)
    eof = toks.pop()
    items = group(toks)
    cx = Ctx(pkg, path)
    cx.imports = {}
    cx.foreign_libs = {}
    cx.overloads = {}
    cx.switch_depth = 0
    cx.pending_reverse = False
    cx.brk = []
    cx.cur_decl = None
    cx.hoisted = []
    cx.thread_locals = []
    stmts = split_statements(items)
    out = []
    file_private = None
    for st in stmts:
        if isinstance(st[0], T) and st[0].k == 'tag':
            tag = st[0].s
            if 'private' in tag: file_private = 'file' if 'file' in tag else 'module'
            if 'build' in tag: cx.build = tag
            st = st[1:]
            if not st: continue
        try:
            out.append(conv_stmt(st, cx))
        except Exception as e:
            out.append('\n/*CONVERT ERROR: ' + str(e).replace('*/', '') + '*/\n' + text(st))
            print(f'{path}: error {e}', file=sys.stderr)
    body = ''.join(out) + eof.pre
    if cx.hoisted: body += '\n' + '\n'.join(cx.hoisted) + '\n'
    for nm in cx.thread_locals:
        body = re.sub(r'(?<![\w.])' + re.escape(nm) + r'\b(?!\s*:)', 'context.' + nm, body)
    body = re.sub(r'\bos\.args\b', 'get_command_line_arguments()', body)
    body = fix_assert(body)
    body = re.sub(r',\s*init_context\s*=\s*context\b', '', body)
    for a, b in (('.Windows', '.WINDOWS'), ('.Darwin', '.MACOS'), ('.Linux', '.LINUX'), ('.amd64', '.X64'), ('.arm64', '.ARM64')):
        body = re.sub(r'((?:OS|CPU) [!=]= )' + re.escape(a) + r'\b', r'\1' + b, body)
    for a, b in QUALIFIED.items():
        body = re.sub(r'(?<![\w.])' + re.escape(a) + (r'\b' if a[-1].isalnum() or a[-1] == '_' else ''), b, body)
    body = re.sub(r'\n#scope_export\n((?:[ \t]*\n)*)(#scope_(?:file|module)\n)', r'\n\1\2', body)
    lines, cur = [], '#scope_export'
    for line in body.split('\n'):
        if line.strip() in ('#scope_export', '#scope_module', '#scope_file'):
            if line.strip() == cur: continue
            cur = line.strip()
        lines.append(line)
    body = '\n'.join(lines)
    if file_private:
        body = ('#scope_file\n' if file_private == 'file' else '#scope_module\n') + body.replace('#scope_export', '#scope_file' if file_private == 'file' else '#scope_module')
    return body.lstrip('\n') + '\n', cx

if __name__ == '__main__':
    pass

OSMAP = {'darwin': 'MACOS', 'windows': 'WINDOWS', 'linux': 'LINUX'}
def file_os(fn, cx):
    b = os.path.basename(fn)[:-5]
    for k, v in OSMAP.items():
        if b.endswith('_' + k): return v
    tag = getattr(cx, 'build', '')
    if tag:
        m = re.search(r'build\s+(.*)', tag)
        if m:
            conds = m.group(1).replace(',', ' ').split()
            neg = [c[1:] for c in conds if c.startswith('!')]
            pos = [c for c in conds if not c.startswith('!')]
            if pos and pos[0] in OSMAP: return OSMAP[pos[0]]
            if neg: return '!' + OSMAP.get(neg[0], neg[0])
    return None

def run(root, out_root, pkgs):
    files_all = []
    for p in pkgs:
        files_all += [os.path.join(root, p, f) for f in os.listdir(os.path.join(root, p)) if f.endswith('.odin') and not f.endswith('_test.odin')]
    collect_globals(files_all)
    report = {}
    for p in pkgs:
        d = os.path.join(root, p)
        files = sorted(f for f in os.listdir(d) if f.endswith('.odin') and not f.endswith('_test.odin'))
        mod = p.replace('src/', '').replace('tools/', 'tool_').replace('/', '_')
        od = os.path.join(out_root, mod)
        os.makedirs(od, exist_ok=True)
        imports = {}
        import_os = {}
        loads = []
        overloads = {}
        libs = {}
        for f in files:
            body, cx = convert_file(os.path.join(d, f), mod)
            jf = f[:-5] + '.jai'
            open(os.path.join(od, jf), 'w').write(body)
            imports.update(cx.imports)
            fos = file_os(f, cx)
            for nm in cx.imports: import_os.setdefault(nm, set()).add(fos)
            overloads.update(cx.overloads)
            libs.update(cx.foreign_libs)
            loads.append((jf, file_os(f, cx)))
        lines = ['#import "Basic";', '#import "String";', '#import "Hash_Table";', '#import "Atomics";', '#import "fc";']
        for nm, m in sorted(imports.items()):
            if m == mod or m == 'fc_c': continue
            oses = import_os.get(nm, {None})
            if None in oses or len(oses) > 1: lines.append(f'{nm} :: #import "{m}";')
            else:
                o = oses.pop()
                lines.append(f'#if OS {"!=" if o.startswith("!") else "=="} .{o.lstrip("!")} {nm} :: #import "{m}";')
        for nm, ls in libs.items():
            l = ls[0].strip('"')
            if l.startswith('system:'):
                l = l[7:]
                if l.endswith('.framework'): lines.append(f'{nm} :: #library,system,link_always "{l[:-10]}";')
                elif l.endswith('.lib'): lines.append(f'{nm} :: #system_library "{l[:-4].lower()}";')
                else: lines.append(f'{nm} :: #system_library "lib{l}";')
            else:
                lines.append(f'{nm} :: #library,no_dll "../../build/fc_vendor";')
        for nm, mem in overloads.items():
            for m in mem:
                lines.append(f'{nm} :: #bake_arguments {m.strip()}();')
        for jf, osn in loads:
            if osn is None: lines.append(f'#load "{jf}";')
            elif osn.startswith('!'): lines.append(f'#if OS != .{osn[1:]} #load "{jf}";')
            else: lines.append(f'#if OS == .{osn} #load "{jf}";')
        open(os.path.join(od, 'module.jai'), 'w').write('\n'.join(lines) + '\n')
    return report

if __name__ == '__main__':
    root, out = sys.argv[1], sys.argv[2]
    run(root, out, sys.argv[3:])
