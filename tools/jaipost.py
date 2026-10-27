#!/usr/bin/env python3 -I
# jaipost.py: mechanical clean-ups of transpiled Jai that need bracket matching.
#  - `.{__IDX__.X = a, __IDX__.Y = b}` (Odin enumerated-array literal over Axis) -> `.[a, b]`
#  - `__MAPIDX__(base|key)` left in conditions -> `get(base, key)` (works for Map and arrays)
#  - `for < v: HI..LO` (reverse range written high-first) -> `for < v: LO..HI`
#
#   python3 -I tools/jaipost.py jai/<module>/*.jai
import re, sys


def match_close(s, i):
    """s[i] is an opening bracket; index of its partner (skips strings)."""
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack, j = [], i
    while j < len(s):
        c = s[j]
        if c == '"':
            j += 1
            while s[j] != '"': j += 2 if s[j] == '\\' else 1
        elif c in pairs: stack.append(pairs[c])
        elif c in ')]}':
            stack.pop()
            if not stack: return j
        j += 1
    raise ValueError('unbalanced')


def split_top(s, sep):
    parts, depth, cur, j = [], 0, '', 0
    while j < len(s):
        c = s[j]
        if c == '"':
            k = j + 1
            while s[k] != '"': k += 2 if s[k] == '\\' else 1
            cur += s[j:k+1]; j = k + 1; continue
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        if depth == 0 and s.startswith(sep, j):
            parts.append(cur); cur = ''; j += len(sep); continue
        cur += c; j += 1
    parts.append(cur)
    return parts


def axis_literals(s):
    out, i = [], 0
    while True:
        k = s.find('.{__IDX__.X', i)
        if k < 0: out.append(s[i:]); break
        end = match_close(s, k + 1)
        parts = [p.strip() for p in split_top(s[k+2:end], ',') if p.strip()]
        kv = [p.split('=', 1) for p in parts]
        if [x[0].strip() for x in kv] == ['__IDX__.X', '__IDX__.Y']:
            out.append(s[i:k] + '.[' + ', '.join(x[1].strip() for x in kv) + ']')
        else:
            out.append(s[i:end+1])
        i = end + 1
    return ''.join(out)


def mapidx(s):
    while True:
        k = s.find('__MAPIDX__(')
        if k < 0: return s
        end = match_close(s, k + len('__MAPIDX__'))
        inner = s[k + len('__MAPIDX__') + 1:end]
        base, key = split_top(inner, '|')[0], '|'.join(split_top(inner, '|')[1:])
        addr = k > 0 and s[k-1] == '*'
        if addr: s = s[:k-1] + f'at(*{base}, {key})' + s[end+1:]
        else: s = s[:k] + f'get({base}, {key})' + s[end+1:]


def reverse_ranges(s):
    return re.sub(r'for < (\*?\s*\w+): ([^{}\n]+?) - 1\.\.0 \{', r'for < \1: 0..\2 - 1 {', s)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        src = open(p).read()
        new = reverse_ranges(mapidx(axis_literals(src)))
        if new != src:
            open(p, 'w').write(new)
            print('fixed', p)
