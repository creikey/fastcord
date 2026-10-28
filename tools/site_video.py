#!/usr/bin/env python3 -I
# site_video.py: the site's side-by-side parity videos (site/video/) and their traffic (site/parity_video.json).
#
# The official client runs tests/scenarios/<s>.scn under the capture driver with FC_VIDEO=1 (frames in
# .secrets/screens/<s>/video, traffic in .secrets/raw/video_<s>.jsonl). fastcord runs tests/video/<s>.txt
# live as test account A with FASTCORD_FRAMES / FASTCORD_RECORD (`fastcord <s>`). Both recordings are
# scrubbed (build/scrub) before anything is read from them, and only request shapes leave .secrets:
# method + path (ids folded, query keys only), wire header names in order, JSON body keys, gateway op
# and payload keys, telemetry event types and property keys, and times. Never values, ids or bodies.
#
#   python3 -I tools/site_video.py fastcord <s>...   (live run, needs build/fastcord-dev)
#   python3 -I tools/site_video.py build <s>...      (scrub, encode the videos, write parity_video.json)
import json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC = os.path.join(ROOT, '.secrets') if os.path.isdir(os.path.join(ROOT, '.secrets')) else '/Users/creikey/Documents/fastcord/.secrets'
TTEXT = '1564405699197407414'
# media (CDN images, the image proxy, sticker files) depends on each client's disk cache, not on behaviour
IGNORE = ('/assets/', 'collectibles-shop', 'latency.discord.media', '/cdn-cgi/', 'cdn.discordapp.com', 'media.discordapp.net', 'images-ext-', '/stickers/')
LEAD_MS, TAIL_MS, MAX_MS = 700, 600, 16000
W = 960
TITLES = {'send_message': 'Send a message', 'add_reaction': 'Add a reaction', 'edit_message': 'Edit a message',
          'reply': 'Reply', 'open_dm': 'Open a DM', 'status_change': 'Change status'}


def run(*a, **k):
    print('+', ' '.join(a[:6]), file=sys.stderr)
    return subprocess.run(a, check=True, **k)


def fastcord(s):
    frames = os.path.join(SEC, 'video', 'frames', s)
    os.makedirs(frames, exist_ok=True)
    for f in os.listdir(frames): os.remove(os.path.join(frames, f))
    env = dict(os.environ, FASTCORD_STATE=os.path.join(SEC, 'video-state-a'), FASTCORD_FRAMES=frames,
               FASTCORD_RECORD=os.path.join(SEC, 'raw', f'fc_video_{s}.jsonl'))
    run(os.path.join(ROOT, 'build', 'fastcord-dev'), f'-shot:{SEC}/video/{s}.png', '-dpi:1', '-live:0.2',
        f'-channel:{TTEXT}', f'-script:{ROOT}/tests/video/{s}.txt', env=env, cwd=ROOT)
    for x in ('', '.netlog-a'):  # raw recordings hold the token
        if os.path.exists(env['FASTCORD_RECORD'] + x): os.chmod(env['FASTCORD_RECORD'] + x, 0o600)


def netlog(raw):
    """The netlog with the true wire header order: fastcord's recorder side file, else the official instance's
    netlog snapshot taken after the recording (build/capture writes one when the instance stops)."""
    if os.path.exists(raw + '.netlog-a'): return raw + '.netlog-a'
    d = os.path.join(SEC, 'raw')
    snaps = [os.path.join(d, n) for n in os.listdir(d) if n.startswith('netlog_a_') and n.endswith('.events.json')]
    snaps = [n for n in snaps if os.path.getmtime(n) >= os.path.getmtime(raw)]
    return min(snaps, key=os.path.getmtime) if snaps else None


def scrub(raw, out):
    nl = netlog(raw)
    run(os.path.join(ROOT, 'build', 'scrub'), raw, out, os.path.join(ROOT, 'tests', 'scenarios', 'env'), *([f'-netlog-a:{nl}'] if nl else []), cwd=ROOT)
    return [json.loads(l) for l in open(out)]


def path_shape(method, url):
    m = re.match(r'(\w+)://([^/?]+)([^?]*)(?:\?(.*))?', url)
    if not m: return method + ' ' + url
    host, path, query = m.group(2), m.group(3), m.group(4)
    path = re.sub(r'/(?:\d{5,}|<[a-z]+:\d+>)', '/:id', path)
    path = re.sub(r'/[0-9a-f]{16,}', '/:hash', path)
    if query: path += '?' + '&'.join(sorted({kv.split('=')[0] for kv in query.split('&')}))
    if host not in ('discord.com', 'canary.discord.com'): path = host + path
    return f'{method} {path}'


def keys(v):
    return list(v.keys()) if isinstance(v, dict) and not any(k.startswith('$') for k in v) else []


def window(evs):
    """Events of the action windows (marks other than setup), t in ms from the first action mark."""
    marks = [(e['t'], e['name']) for e in evs if e['k'] == 'mark' and not e['name'].startswith(('setup', '_'))]
    if not marks: return [], [], 0
    t0 = marks[0][0]
    out, on = [], False
    for e in evs:
        if e['k'] == 'mark': on = not e['name'].startswith(('setup', '_')); continue
        if not on or e.get('acct') == 'b': continue
        t = round(e['t'] - t0)
        if e['k'] == 'req':
            url = e['url']
            if any(x in url for x in IGNORE): continue
            if '/science' in url:
                body = e.get('body')
                for ev in body.get('events', []) if isinstance(body, dict) else []:
                    out.append({'t': t, 'k': 2, 'l': ev.get('type', '?'), 'd': keys(ev.get('properties'))})
                continue
            hdr = [h[0].lower() for h in (e.get('wire') or e.get('headers') or [])]
            out.append({'t': t, 'k': 0, 'l': path_shape(e['method'], url), 'p': e.get('proto', ''), 'h': hdr, 'd': keys(e.get('body'))})
        elif e['k'] == 'ws_send' and e.get('op') != 1:  # heartbeats: random phase in both clients
            out.append({'t': t, 'k': 1, 'l': f"op {e.get('op')}", 'd': keys(e.get('d'))})
    return out, [(round(t - t0), n) for t, n in marks], t0


def align(a, b):
    n, m = len(a), len(b)
    L = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            L[i][j] = L[i+1][j+1] + 1 if a[i]['l'] == b[j]['l'] else max(L[i+1][j], L[i][j+1])
    i = j = 0
    pairs = []
    while i < n and j < m:
        if a[i]['l'] == b[j]['l']: pairs.append([i, j]); i += 1; j += 1
        elif L[i+1][j] >= L[i][j+1]: i += 1
        else: j += 1
    return pairs


def encode(frames, t0, dur, out):
    """frames: [(ms on the recording clock, path)] -> out (h264, W wide, 1x speed, starting LEAD_MS before t0)."""
    start = t0 - LEAD_MS
    fs = [(t - start, p) for t, p in sorted(frames) if start - 200 <= t <= start + dur]
    if not fs: raise SystemExit(f'no frames for {out}')
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        for i, (t, p) in enumerate(fs):
            nxt = fs[i + 1][0] if i + 1 < len(fs) else dur
            f.write(f"file '{p}'\nduration {max(nxt - max(t, 0), 1) / 1000:.3f}\n")
        f.write(f"file '{fs[-1][1]}'\n")
    run('ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', f.name, '-vf',
        f'scale={W}:-2:flags=lanczos,fps=30', '-c:v', 'libx264', '-preset', 'slow', '-crf', '30', '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart', '-an', out)
    os.remove(f.name)


def build(names):
    os.makedirs(os.path.join(ROOT, 'site', 'video'), exist_ok=True)
    scen = []
    for s in names:
        o = scrub(os.path.join(SEC, 'raw', f'video_{s}.jsonl'), os.path.join(SEC, 'video', f'official_{s}.jsonl'))
        f = scrub(os.path.join(SEC, 'raw', f'fc_video_{s}.jsonl'), os.path.join(SEC, 'video', f'fastcord_{s}.jsonl'))
        a, am, at0 = window(o)
        b, bm, bt0 = window(f)
        # both videos run from the action mark to whichever client finished last
        end = max([e['t'] for e in a + b] + [m[0] for m in am + bm]) + TAIL_MS
        dur = min(LEAD_MS + end, MAX_MS)
        # The official recording clock (rt) is the scrub's t; fastcord's frames are named on its recorder clock.
        vo = os.path.join(SEC, 'screens', s, 'video')
        encode([(int(n[2:-4]), os.path.join(vo, n)) for n in os.listdir(vo) if n.startswith('a_')], at0, dur, os.path.join(ROOT, 'site', 'video', f'{s}-official.mp4'))
        vf = os.path.join(SEC, 'video', 'frames', s)
        encode([(int(n[:-4]), os.path.join(vf, n)) for n in os.listdir(vf) if n.endswith('.png')], bt0, dur, os.path.join(ROOT, 'site', 'video', f'{s}-fastcord.mp4'))
        scen.append({'n': s, 'title': TITLES.get(s, s), 'lead': LEAD_MS, 'dur': dur, 'o': a, 'f': b, 'om': am, 'fm': bm, 'm': align(a, b)})
        print(f'{s}: official {len(a)}, fastcord {len(b)}, matched {len(scen[-1]["m"])}', file=sys.stderr)
    dst = os.path.join(ROOT, 'site', 'parity_video.json')
    with open(dst, 'w') as fh: json.dump({'scenarios': scen}, fh, separators=(',', ':'))
    print(f'-> {dst} ({os.path.getsize(dst)} bytes)')


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('fastcord', 'build'): raise SystemExit(__doc__ if __doc__ else 'usage: site_video.py fastcord|build <scenario>...')
    if sys.argv[1] == 'fastcord':
        for s in sys.argv[2:]: fastcord(s)
    else:
        build(sys.argv[2:])
