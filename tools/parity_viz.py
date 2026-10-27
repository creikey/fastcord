#!/usr/bin/env python3 -I
# parity_viz.py: site/parity.json from each scenario's official fixture (traffic/<s>.jsonl) and
# fastcord's scrubbed live recording of the same scenario (.secrets/ours/<s>.jsonl).
#
# For each action window it keeps what Discord's servers see: REST requests (method + path with ids
# folded, query keys only), gateway sends (op, heartbeats left out) and telemetry events (/science
# event types). The two sequences are aligned (longest common subsequence); matched pairs carry both
# timestamps. Only shapes and timings are written, never ids, bodies or headers.
#
# The live recordings come from one long session (build/parity session), while each official fixture
# was recorded right after its own launch. An unmatched official event is marked "earlier" when
# fastcord sent the same thing earlier in the session (session-once loads: command indexes, picker
# data), and "design" when it is a telemetry event fastcord never sends because its values can't be
# measured honestly (analytics_unknowable in src/discord/analytics.jai).
#
#   python3 -I tools/parity_viz.py            (writes site/parity.json)
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IGNORE = ('/assets/', 'collectibles-shop', 'latency.discord.media', '/cdn-cgi/', 'cdn.discordapp.com', 'media.discordapp.net')


def shape(method, url):
    m = re.match(r'(\w+)://([^/?]+)([^?]*)(?:\?(.*))?', url)
    if not m: return method + ' ' + url
    host, path, query = m.group(2), m.group(3), m.group(4)
    path = re.sub(r'/(?:\d{5,}|<[a-z]+:\d+>)', '/:id', path)
    path = re.sub(r'/[0-9a-f]{16,}', '/:hash', path)
    if query: path += '?' + '&'.join(sorted({kv.split('=')[0] for kv in query.split('&')}))
    if host not in ('discord.com', 'canary.discord.com'): path = host + path
    return f'{method} {path}'


def events(path, windows=True):
    """[(t, kind, token)] inside the action windows (marks other than setup*), t from the window's start;
    kinds: 0 REST, 1 gateway, 2 telemetry. With windows=False: every event, t absolute."""
    out, start = [], None if windows else 0
    for line in open(path):
        e = json.loads(line)
        k = e['k']
        if k == 'mark':
            if windows: start = None if e['name'].startswith('setup') or e['name'].startswith('_') else e['t']
            else: out.append((round(e['t']), -1, e['name']))
            continue
        if start is None: continue
        t = round(e['t'] - start)
        if k == 'req':
            url = e['url']
            if any(x in url for x in IGNORE): continue
            if '/science' in url:
                for ev in (e.get('body') or {}).get('events', []) if isinstance(e.get('body'), dict) else []:
                    out.append((t, 2, ev.get('type', '?')))
                continue
            out.append((t, 0, shape(e['method'], url)))
        elif k == 'ws_send':
            op = e.get('op')
            if op == 1: continue  # heartbeat: random phase in both clients
            out.append((t, 1, f'op {op}'))
    return out


def align(a, b):
    """LCS over tokens; returns matched index pairs."""
    n, m = len(a), len(b)
    L = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            L[i][j] = L[i+1][j+1] + 1 if a[i][2] == b[j][2] else max(L[i+1][j], L[i][j+1])
    i = j = 0
    pairs = []
    while i < n and j < m:
        if a[i][2] == b[j][2]: pairs.append((i, j)); i += 1; j += 1
        elif L[i+1][j] >= L[i][j+1]: i += 1
        else: j += 1
    return pairs


def session_order(ours_dir):
    """The live recordings in the order the session made them (raw recording times)."""
    raw = os.path.join(ROOT, '.secrets', 'raw')
    def when(n):
        r = os.path.join(raw, 'ours_' + n)
        return os.path.getmtime(r if os.path.exists(r) else os.path.join(ours_dir, n))
    return sorted((n for n in os.listdir(ours_dir) if n.endswith('.jsonl')), key=when)


def unknowable():
    src = open(os.path.join(ROOT, 'src', 'discord', 'analytics.jai')).read()
    return set(re.findall(r'"(\w+)"', re.search(r'analytics_unknowable :: string\.\[(.*?)\];', src).group(1)))


def main():
    ours_dir = os.path.join(ROOT, '.secrets', 'ours')
    tokens, index, scenarios = [], {}, []
    def tok(s):
        if s not in index: index[s] = len(tokens); tokens.append(s)
        return index[s]
    never = unknowable()
    seen, earlier = set(), {}  # tokens fastcord sent before each scenario's first action window
    for name in session_order(ours_dir):
        evs = events(os.path.join(ours_dir, name), windows=False)
        first = next((t for t, k, x in evs if k == -1 and not x.startswith('setup') and not x.startswith('_')), None)
        earlier[name] = seen | {x for t, k, x in evs if k >= 0 and first is not None and t < first}
        seen |= {x for t, k, x in evs if k >= 0}
    for name in sorted(os.listdir(os.path.join(ROOT, 'traffic'))):
        if not name.endswith('.jsonl'): continue
        s = name[:-6]
        mine = os.path.join(ours_dir, name)
        if not os.path.exists(mine): continue
        a, b = events(os.path.join(ROOT, 'traffic', name)), events(mine)
        if not a and not b: continue
        pairs = align(a, b)
        hit = {i for i, j in pairs}
        scenarios.append({
            'n': s,
            'o': [[t, k, tok(x)] for t, k, x in a],
            'f': [[t, k, tok(x)] for t, k, x in b],
            'm': pairs,
            'e': [i for i, (t, k, x) in enumerate(a) if i not in hit and x in earlier.get(name, ())],
            'x': [i for i, (t, k, x) in enumerate(a) if i not in hit and k == 2 and x in never and x not in earlier.get(name, ())],
        })
    out = {'tokens': tokens, 'scenarios': scenarios}
    dst = os.path.join(ROOT, 'site', 'parity.json')
    with open(dst, 'w') as f: json.dump(out, f, separators=(',', ':'))
    tot_o = sum(len(x['o']) for x in scenarios)
    tot_f = sum(len(x['f']) for x in scenarios)
    tot_m = sum(len(x['m']) for x in scenarios)
    tot_e = sum(len(x['e']) for x in scenarios)
    tot_x = sum(len(x['x']) for x in scenarios)
    print(f'{len(scenarios)} scenarios, official {tot_o} events, fastcord {tot_f}, matched {tot_m}, earlier {tot_e}, by design {tot_x} -> {dst} ({os.path.getsize(dst)} bytes)')


if __name__ == '__main__':
    main()
