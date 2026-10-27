#!/usr/bin/env python3 -I
# jaiprec.py: parenthesize bitwise expressions in Jai files ported from Odin so they keep Odin's grouping.
#
# Odin: * / % & << >> bind tightest, then + - | ^, then comparisons, &&, ||; unary casts bind tightest.
# Jai: & | ^ << >> share one level above * and +, and `cast(T) x << 8` casts the whole shift.
# Every expression that contains a bitwise operator is re-parsed with Odin's precedence and printed with
# explicit parentheses wherever Jai would group it differently. Expressions without one are untouched.
#
#   python3 -I tools/jaiprec.py [--fix] jai/<module>/*.jai
import re, sys

PREC = {'*': 7, '/': 7, '%': 7, '&': 7, '<<': 7, '>>': 7, '+': 6, '-': 6, '|': 6, '^': 6,
        '==': 5, '!=': 5, '<': 5, '>': 5, '<=': 5, '>=': 5, '&&': 4, '||': 3}
BITWISE = {'&', '|', '^', '<<', '>>'}
OPS = ['<<=', '>>=', '..', '::', ':=', '->', '==', '!=', '<=', '>=', '&&', '||', '<<', '>>', '+=', '-=', '*=', '/=', '%=',
       '&=', '|=', '^=', '.*']
OPS.sort(key=len, reverse=True)


class Tok:
    __slots__ = ('k', 's', 'pre')
    def __init__(s, k, text, pre): s.k, s.s, s.pre = k, text, pre


def lex(src):
    toks, i, n, pre = [], 0, len(src), ''
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            j = i
            while j < n and src[j] in ' \t\r\n': j += 1
            pre += src[i:j]; i = j; continue
        if src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j
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
        if src.startswith('#string', i):
            m = re.compile(r'#string\s+(\w+)\n').match(src, i)
            if m:
                end = src.index('\n' + m.group(1), m.end() - 1) + 1 + len(m.group(1))
                toks.append(Tok('str', src[i:end], pre)); pre = ''; i = end; continue
        if c.isalpha() or c == '_' or c == '#' or c == '$':
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == '_'): j += 1
            toks.append(Tok('id', src[i:j], pre)); pre = ''; i = j; continue
        if c.isdigit():
            m = re.compile(r'0[xXbBh][0-9a-fA-F_]+|[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9]+)?').match(src, i)
            t = m.group(0)
            if '.' in t and src.startswith('..', i + t.index('.')): t = t[:t.index('.')]
            toks.append(Tok('num', t, pre)); pre = ''; i += len(t); continue
        if c == '"':
            j = i + 1
            while src[j] != '"': j += 2 if src[j] == '\\' else 1
            toks.append(Tok('str', src[i:j+1], pre)); pre = ''; i = j + 1; continue
        for op in OPS:
            if src.startswith(op, i):
                toks.append(Tok('op', op, pre)); pre = ''; i += len(op); break
        else:
            toks.append(Tok('op', c, pre)); pre = ''; i += 1
    return toks, pre


class G:
    def __init__(s, o, items, c): s.o, s.items, s.c, s.k, s.s, s.pre = o, items, c, 'group', o.s, o.pre


def group(toks):
    stack, opens = [[]], []
    for t in toks:
        if t.k == 'op' and t.s in '([{':
            opens.append(t); stack.append([])
        elif t.k == 'op' and t.s in ')]}':
            items = stack.pop(); stack[-1].append(G(opens.pop(), items, t))
        else:
            stack[-1].append(t)
    return stack[0]


def text(items):
    out = []
    for x in items:
        if isinstance(x, G): out.append(x.o.pre + x.o.s + text(x.items) + x.c.pre + x.c.s)
        else: out.append(x.pre + x.s)
    return ''.join(out)


BREAK = {';', ',', '=', ':=', ':', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '..', '->', '::'}
BREAK_ID = {'then', 'else', 'ifx', 'return', 'if', 'while', 'case', 'for', 'defer', 'using', 'inline', 'push_context', '#through'}


def is_op(x, s=None):
    return isinstance(x, Tok) and x.k == 'op' and (s is None or x.s == s)


class Fail(Exception): pass


def parse(seg):
    """Pratt parse with Odin precedence. Nodes: ('leaf', items) | ('un', prefix_items, node) | ('bin', op_tok, l, r)."""
    pos = [0]
    def peek(): return seg[pos[0]] if pos[0] < len(seg) else None
    def operand():
        prefix = []
        while True:
            x = peek()
            if is_op(x) and x.s in ('-', '!', '~', '*', '+'):
                prefix.append(x); pos[0] += 1; continue
            if isinstance(x, Tok) and x.k == 'id' and x.s == 'cast':
                prefix.append(x); pos[0] += 1
                while is_op(peek(), ',') or (isinstance(peek(), Tok) and peek().k == 'id' and peek().s in ('no_check', 'trunc', 'force')):
                    prefix.append(peek()); pos[0] += 1
                if not isinstance(peek(), G) or peek().s != '(': raise Fail()
                prefix.append(peek()); pos[0] += 1
                continue
            if isinstance(x, Tok) and x.k == 'id' and x.s == 'xx':
                prefix.append(x); pos[0] += 1; continue
            break
        x = peek()
        if x is None: raise Fail()
        prim = []
        if isinstance(x, G) or x.k in ('id', 'num', 'str'):
            prim.append(x); pos[0] += 1
        elif is_op(x, '.'):  # .Enum / .{...} / .[...]
            prim.append(x); pos[0] += 1
            y = peek()
            if y is None: raise Fail()
            prim.append(y); pos[0] += 1
        else:
            raise Fail()
        while True:  # postfix: calls, index, member, deref, T.{..}
            y = peek()
            if isinstance(y, G) and y.s in '([' and not y.pre: prim.append(y); pos[0] += 1; continue
            if is_op(y, '.*'): prim.append(y); pos[0] += 1; continue
            if is_op(y, '.') and pos[0] + 1 < len(seg):
                prim.append(y); prim.append(seg[pos[0] + 1]); pos[0] += 2; continue
            break
        node = ('leaf', prim)
        return ('un', prefix, node) if prefix else node
    def expr(minp):
        left = operand()
        while True:
            x = peek()
            if not (is_op(x) and x.s in PREC) or PREC[x.s] < minp: break
            pos[0] += 1
            right = expr(PREC[x.s] + 1)
            left = ('bin', x, left, right)
        return left
    tree = expr(0)
    if pos[0] != len(seg): raise Fail()
    return tree


def emit(node, parent_op=None, first=False):
    if node[0] == 'leaf':
        return text(node[1])
    if node[0] == 'un':
        s = text(node[1]) + emit(node[2])
        cast = any(isinstance(p, Tok) and p.s in ('cast', 'xx') for p in node[1])
        if cast and parent_op in BITWISE:
            lead = s[:len(s) - len(s.lstrip())]
            return lead + '(' + s.lstrip() + ')'
        return s
    op, l, r = node[1], node[2], node[3]
    s = emit(l, op.s) + op.pre + op.s + emit(r, op.s)
    if parent_op is not None and parent_op != op.s and (parent_op in BITWISE or op.s in BITWISE):
        lead = s[:len(s) - len(s.lstrip())]
        return lead + '(' + s.lstrip() + ')'
    return s


def has_bitwise(seg):
    return any(is_op(x) and x.s in BITWISE for x in seg)


def fix_items(items, stats):
    """Rewrite each expression segment in this item list; recurse into groups."""
    out, seg = [], []
    def flush():
        if seg:
            if has_bitwise(seg):
                try:
                    tree = parse(seg)
                    new = emit(tree)
                    if new != text(seg): stats['fixed'] += 1
                    out.append(Tok('raw', new, ''))
                except Fail:
                    stats['skipped'] += 1
                    out.extend(seg)
            else:
                out.extend(seg)
            seg.clear()
    for x in items:
        if isinstance(x, G):
            x.items = fix_items(x.items, stats)
            if x.s == '{':  # block or literal body: its own statements
                flush(); out.append(x); continue
            seg.append(x); continue
        if (x.k == 'op' and x.s in BREAK) or (x.k == 'id' and x.s in BREAK_ID):
            flush(); out.append(x); continue
        seg.append(x)
    flush()
    return out


def fix_file(path, write):
    src = open(path).read()
    toks, tail = lex(src)
    items = group(toks)
    stats = {'fixed': 0, 'skipped': 0}
    new = text(fix_items(items, stats)) + tail
    if write and new != src: open(path, 'w').write(new)
    return stats, new != src


if __name__ == '__main__':
    write = '--fix' in sys.argv
    total = {'fixed': 0, 'skipped': 0}
    for p in [a for a in sys.argv[1:] if not a.startswith('--')]:
        st, changed = fix_file(p, write)
        for k in total: total[k] += st[k]
        if st['fixed']: print(f"{p}: {st['fixed']} expressions regrouped")
    print(f"total regrouped {total['fixed']}, unparsed bitwise segments {total['skipped']}")
