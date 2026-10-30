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
#   python3 -I tools/site_video.py hero              (site/screenshot.jpg from a made-up server built on the threads fixture, offline;
#                                                     then `jai build.jai - og` for the link preview)
import json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC = os.path.join(ROOT, '.secrets') if os.path.isdir(os.path.join(ROOT, '.secrets')) else '/Users/creikey/Documents/fastcord/.secrets'
TGUILD, TTEXT = '1564227669971832975', '1564405699197407414'
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
    script = os.path.join(ROOT, 'tests', 'video', f'{s}.txt')
    # the start route, as the official instance reopened it: the test channel, or Home for go_home scripts
    route = [] if 'go_home' in open(script).read() else [f'-guild:{TGUILD}', f'-channel:{TTEXT}']
    run(os.path.join(ROOT, 'build', 'fastcord-dev'), f'-shot:{SEC}/video/{s}.png', '-dpi:1', '-live:0.2', *route,
        f'-script:{script}', env=env, cwd=ROOT)
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


# Why an event can be in one recording only, for the shapes where the cause is known (shown on the site).
PROMO = ('Promotion', 'Promotion (Shop, Quests, Orbs): Fastcord never sends these')
TIMER = ('Background timer', 'Background save of recent channels and emoji, on a random 0-10 s timer after launch')
WHY = {
    'quest_hover': PROMO, 'quest_hover_off': PROMO, 'dismissible_content_shown': PROMO, 'experiment_user_evaluation_exposed': PROMO,
    'send_message_roundtrip': ('Sampled', 'Sampled: both clients send it for 1 in 10 messages'),
    'GET /api/v9/users/@me/settings-proto/2': TIMER, 'PATCH /api/v9/users/@me/settings-proto/2': TIMER,
    'op 40': ('Background timer', 'Sent on its own background timer'),
    'GET /api/v9/channels/:id/messages?before&limit': ('Fills the window', 'A second page of older messages, loaded when the first one does not fill the window'),
    'search_result_viewed': ('Typing rhythm', 'Sent each time typing pauses, so it follows the typist\'s rhythm'),
}


def why(evs, hit):
    return {i: WHY[e['l']] for i, e in enumerate(evs) if i not in hit and e['l'] in WHY}


def align(a, b):
    """Pairs each official event with the unpaired fastcord event of the same shape nearest in time (within
    2.5 s, human pacing). Order is not required: events a few ms apart (a science batch and a GET) leave in either order."""
    pairs, used = [], set()
    for i, e in enumerate(a):
        best = min((j for j, f in enumerate(b) if j not in used and f['l'] == e['l'] and abs(f['t'] - e['t']) <= 2500),
                   key=lambda j: abs(b[j]['t'] - e['t']), default=None)
        if best is not None: used.add(best); pairs.append([i, best])
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
        f'scale={W}:-2:flags=lanczos:out_range=tv,fps=30,format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '30', '-pix_fmt', 'yuv420p',
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
        m = align(a, b)
        # promotion events are only ever official-side; everything else in WHY can fall on either side
        wo, wf = why(a, {p[0] for p in m}), why(b, {p[1] for p in m})
        scen.append({'n': s, 'title': TITLES.get(s, s), 'lead': LEAD_MS, 'dur': dur, 'o': a, 'f': b, 'om': am, 'fm': bm, 'm': m, 'wo': wo, 'wf': wf})
        print(f'{s}: official {len(a)}, fastcord {len(b)}, matched {len(scen[-1]["m"])}', file=sys.stderr)
    dst = os.path.join(ROOT, 'site', 'parity_video.json')
    with open(dst, 'w') as fh: json.dump({'scenarios': scen}, fh, separators=(',', ':'))
    print(f'-> {dst} ({os.path.getsize(dst)} bytes)')


# ---- the site hero: a made-up server built on the threads fixture's READY, all names and images synthetic ----

def png_bytes(w, h, px):
    """px(x, y) -> (r, g, b) floats 0..255; returns an RGB PNG."""
    import struct, zlib
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w): rows += bytes(max(0, min(255, int(c))) for c in px(x, y))
    def chunk(k, d): return struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b'')


def mix(a, b, t): return [a[i] + (b[i] - a[i]) * t for i in range(3)]


def avatar_png(c0, c1):
    """A soft two-colour gradient with a lighter blob, like the abstract avatars people pick."""
    import math
    def px(x, y):
        c = mix(c0, c1, (x + y) / 254)
        g = max(0.0, 1 - math.hypot(x - 44, y - 40) / 70)
        return mix(c, (255, 255, 255), g * g * 0.45)
    return png_bytes(128, 128, px)


def landscape_png(w, h, sky0, sky1, sun, layers):
    """Sky gradient, a sun with a glow, and mountain ridges in layers."""
    import math
    ridges = [[(h * base) + sum(h * a * math.sin(x / w * f + p) for a, f, p in waves) for x in range(w)] for base, waves, _ in layers]
    def px(x, y):
        t = y / h
        c = mix(sky0, sky1, t)
        d = math.hypot(x - w * 0.68, y - h * 0.42) / h
        c = mix(c, sun, max(0.0, 1 - d / 0.09)) if d < 0.09 else mix(c, sun, max(0.0, 0.35 - d) * 0.9)
        for i, (_, _, col) in enumerate(layers):
            if y >= ridges[i][x]: c = mix(col, sky1, max(0.0, 0.25 - (y - ridges[i][x]) / h) * 0.6)
        return c
    return png_bytes(w, h, px)


def hero_fixture(d):
    import random
    G, ME, GEN = 1546820558300258304, 1546819257420087346, 1546820603343016006
    VOICE, CAT_T, CAT_V = 1546820558950371411, 1546820558950371408, 1546820558950371409
    EPOCH, NOW = 1420070400000, 1793034000000
    lines = [json.loads(l) for l in open(os.path.join(ROOT, 'tests', 'ui', 'chat_threads.jsonl'), encoding='utf-8')]
    ready, supp = lines[0]['etf']['d'], lines[1]['etf']['d']
    media = os.path.join(d, 'media')
    os.makedirs(media, exist_ok=True)
    def put(name, data):
        with open(os.path.join(media, name), 'wb') as f: f.write(data)
    seq = [0]
    def sf(ms):
        seq[0] += 1
        return ((ms - EPOCH) << 22) | seq[0]
    # users: (id, username, name, colours, status, activity)
    people = [
        (ME, 'sam', 'Sam', ((90, 110, 240), (170, 90, 230)), 'online', None),
        (1000000000020971521, 'maya', 'Maya', ((240, 120, 80), (240, 190, 70)), 'online', {'type': 0, 'name': 'Celeste'}),
        (1000000000020971522, 'theo', 'Theo', ((40, 170, 150), (60, 120, 220)), 'idle', None),
        (1000000000020971523, 'ines', 'Ines', ((220, 80, 140), (250, 160, 120)), 'dnd', {'type': 4, 'name': 'Custom Status', 'state': 'heads down until 6', 'emoji': {'name': '\U0001f3a7'}}),
        (1000000000020971524, 'kai', 'Kai', ((70, 80, 110), (120, 200, 200)), 'online', None),
        (1000000000020971525, 'noor', 'Noor', ((150, 200, 90), (40, 140, 110)), 'offline', None),
        (1000000000020971526, 'jules', 'Jules', ((200, 160, 250), (100, 110, 220)), 'offline', None),
    ]
    MOD = 1546822593921679420
    users = {}
    for uid, un, gn, (c0, c1), *_ in people:
        h = '%032x' % (uid % (1 << 64))
        put(h + '.webp', avatar_png(c0, c1)); put(h + '.png', avatar_png(c0, c1))
        users[uid] = {'id': uid, 'username': un, 'global_name': gn, 'avatar': h, 'discriminator': '0', 'bot': False}
    mods = {ME, 1000000000020971521}

    g = ready['guilds'][0]
    g['properties']['name'] = 'Night Owls'
    ghash = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
    g['properties']['icon'] = ghash
    put(ghash + '.webp', avatar_png((30, 40, 90), (90, 70, 200))); put(ghash + '.png', avatar_png((30, 40, 90), (90, 70, 200)))
    g['member_count'] = len(people)
    for r in g['roles']:
        if r['id'] == MOD: r.update(name='Mods', color=0x3DB8A6, colors={'primary_color': 0x3DB8A6, 'secondary_color': None, 'tertiary_color': None})
    chans = []
    for c in g['channels']:
        if c['id'] == GEN: c.update(name='general', topic='Hang out, share things, plan the weekend')
        if c['id'] == VOICE: c.update(name='Lounge', icon_emoji=None)
        chans.append(c)
    extra = [(1546820603343016011, 'announcements', 0, CAT_T, 0), (1546820603343016012, 'photos', 0, CAT_T, 2),
             (1546820603343016013, 'games', 0, CAT_T, 3), (1546820603343016014, 'music', 0, CAT_T, 4),
             (1546820603343016015, 'Movie night', 2, CAT_V, 1)]
    for cid, name, typ, parent, pos in extra:
        chans.append({'id': cid, 'name': name, 'type': typ, 'parent_id': parent, 'position': pos, 'flags': 0, 'nsfw': False,
                      'permission_overwrites': [], 'last_message_id': sf(NOW - 60000) if name in ('photos', 'games') else None})
    g['channels'] = chans
    ready['users'] = [u for uid, u in users.items() if uid != ME]
    ready['user'].update(global_name='Sam', username='sam', avatar=users[ME]['avatar'])
    member = lambda uid: {'user_id': uid, 'roles': [MOD] if uid in mods else [], 'nick': None, 'avatar': None, 'deaf': False, 'mute': False,
                          'flags': 0, 'pending': False, 'joined_at': '2026-09-08T09:53:38+00:00', 'premium_since': None, 'communication_disabled_until': None}
    ready['merged_members'] = [[member(ME)]]
    supp['merged_members'] = [[member(uid) for uid, *_ in people if uid != ME]]
    supp['merged_presences'] = {'friends': [], 'guilds': [[{'user_id': uid, 'status': st, 'activities': [a] if a else [], 'client_status': {'desktop': st}}
                                                           for uid, _, _, _, st, a in people if uid != ME and st != 'offline']]}
    supp['guilds'][0]['voice_states'] = [
        {'user_id': uid, 'channel_id': VOICE, 'session_id': 's%d' % i, 'self_mute': i == 1, 'self_deaf': False, 'self_video': False,
         'self_stream': i == 0, 'mute': False, 'deaf': False, 'suppress': False, 'request_to_speak_timestamp': None}
        for i, uid in enumerate((1000000000020971522, 1000000000020971524))]
    rs = ready['read_state']['entries']
    rs[0]['last_message_id'] = 0
    out = [lines[0], lines[1]]
    def ev(t, dd): out.append({'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': 100 + len(out), 'd': dd}})

    def msg(uid, ms, content='', cid=GEN, **k):
        m = {'id': sf(ms), 'channel_id': cid, 'guild_id': G, 'author': users[uid], 'content': content, 'timestamp': '', 'edited_timestamp': None,
             'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}
        m.update(k)
        ev('MESSAGE_CREATE', m)
        return m
    def react(*rs): return [{'emoji': {'id': None, 'name': e}, 'count': n, 'me': me, 'burst_count': 0, 'me_burst': False} for e, n, me in rs]
    MAYA, THEO, INES, KAI = (p[0] for p in people[1:5])
    t = NOW - 41 * 60000
    first = msg(THEO, t, 'anyone up for the ridge trail on saturday? leaving around 8')
    msg(KAI, t + 4 * 60000, 'the route: https://trails.example/ridge-loop')
    put('loop.png', landscape_png(320, 180, (120, 170, 200), (220, 230, 210), (255, 250, 220),
                                  [(0.55, [(0.06, 4, 0.5), (0.02, 15, 2.0)], (90, 130, 110)), (0.72, [(0.04, 7, 1.5)], (50, 90, 80))]))
    out[-1]['etf']['d']['embeds'] = [{'type': 'article', 'url': 'https://trails.example/ridge-loop', 'title': 'Ridge Loop via North Saddle',
                                       'description': '11.2 km \u00b7 640 m gain \u00b7 views the whole way',
                                       'color': 0x3DB8A6, 'provider': {'name': 'Trail Notes'},
                                       'thumbnail': {'url': 'https://trails.example/loop.png', 'proxy_url': 'https://images-ext-1.discordapp.net/external/x/https/trails.example/loop.png', 'width': 320, 'height': 180, 'flags': 0}}]
    me_msg = msg(ME, t + 9 * 60000, "<@%d> I'm in. I'll bring snacks, carpool from my place at 7:30?" % THEO,
                 mentions=[users[THEO]], message_reference={'message_id': first['id'], 'channel_id': GEN, 'guild_id': G},
                 referenced_message=first, reactions=react(('\U0001f44d', 3, False), ('\U0001f697', 2, True)))
    th = me_msg['id']
    ev('THREAD_CREATE', {'id': th, 'guild_id': G, 'parent_id': GEN, 'type': 11, 'name': 'carpool + gear', 'owner_id': ME, 'message_count': 0, 'member_count': 4,
                         'thread_metadata': {'archived': False, 'locked': False, 'auto_archive_duration': 1440, 'archive_timestamp': '2026-10-25T00:00:00+00:00', 'create_timestamp': '2026-10-25T00:20:00+00:00'},
                         'member': {'id': th, 'user_id': ME, 'flags': 1, 'join_timestamp': '2026-10-25T00:21:00+00:00'}, 'last_message_id': None})
    for i, (uid, text) in enumerate(((THEO, 'I can drive the second car'), (MAYA, 'packing the stove, who wants cocoa at the top?'), (INES, 'me \U0001f64b'))):
        msg(uid, t + (11 + i) * 60000, text, cid=th)
    put('ridge.png', landscape_png(640, 360, (60, 70, 140), (250, 170, 120), (255, 236, 190),
                                   [(0.52, [(0.05, 7, 0.3), (0.025, 19, 1.1)], (110, 90, 150)), (0.64, [(0.04, 5, 2.0), (0.02, 23, 0.4)], (70, 60, 110)),
                                    (0.78, [(0.03, 9, 4.0), (0.015, 31, 0.9)], (35, 32, 64))]))
    aid = sf(t + 20 * 60000 + 500)
    last = msg(MAYA, t + 20 * 60000 + 1000, 'took this from the top last time \U0001f304', attachments=[{'id': aid, 'filename': 'ridge.png', 'size': 412000, 'content_type': 'image/png', 'width': 640, 'height': 360,
                                       'url': f'https://cdn.discordapp.com/attachments/{GEN}/{aid}/ridge.png', 'proxy_url': f'https://media.discordapp.net/attachments/{GEN}/{aid}/ridge.png'}],
        reactions=react(('\U0001f60d', 4, True), ('\U0001f525', 2, False), ('⛰️', 1, False)))
    rs[0]['last_message_id'] = last['id']
    # the member list as Discord sends it for the channel: hoisted Mods, then Online and Offline
    groups = [(MOD, sorted(mods)), ('online', [p[0] for p in people if p[0] not in mods and p[4] != 'offline']), ('offline', [p[0] for p in people if p[4] == 'offline'])]
    items = []
    for gid, ids in groups:
        items.append({'group': {'id': gid, 'count': len(ids)}})
        for uid in ids:
            p = next(p for p in people if p[0] == uid)
            m = member(uid); del m['user_id']
            items.append({'member': dict(m, user=users[uid], presence={'user': {'id': uid}, 'status': p[4], 'activities': [p[5]] if p[5] else [], 'client_status': {'desktop': p[4]} if p[4] != 'offline' else {}})})
    ev('GUILD_MEMBER_LIST_UPDATE', {'guild_id': G, 'id': 'everyone', 'member_count': len(people), 'online_count': len(people) - 2,
                                    'groups': [{'id': gid, 'count': len(ids)} for gid, ids in groups], 'ops': [{'op': 'SYNC', 'range': [0, 99], 'items': items}]})
    # a few more servers on the rail
    for i, (name, c0, c1) in enumerate((('Pixel Garden', (240, 150, 60), (230, 80, 120)), ('Synth Club', (60, 200, 220), (80, 90, 230)),
                                        ('Book Nook', (120, 190, 110), (230, 210, 100)), ('Climbing', (200, 90, 90), (120, 60, 160)))):
        gid, h = 1600000000000000001 + i * 10, 'b%031x' % i
        put(h + '.webp', avatar_png(c0, c1)); put(h + '.png', avatar_png(c0, c1))
        ev('GUILD_CREATE', {'id': gid, 'name': name, 'icon': h, 'owner_id': MAYA, 'joined_at': '2026-01-01T00:00:00+00:00', 'emojis': [], 'stickers': [], 'features': [], 'member_count': 3,
                            'roles': [{'id': gid, 'name': '@everyone', 'permissions': '311489317953', 'position': 0, 'color': 0, 'hoist': False, 'managed': False, 'mentionable': False}],
                            'channels': [{'id': gid + 1, 'type': 0, 'name': 'general', 'position': 0, 'parent_id': None, 'permission_overwrites': [], 'last_message_id': None}]})
    for l in lines[22:24]: out.append(l)  # the two scheduled events
    out[-2]['etf']['d'].update(name='Saturday ridge hike', channel_id=VOICE, creator_id=MAYA, user_count=5)
    out[-1]['etf']['d'].update(name='Movie night', creator_id=INES, description='Vote on the film in #general.', entity_metadata={'location': 'Theo\'s place'}, user_count=6)
    path = os.path.join(d, 'hero.jsonl')
    with open(path, 'w', encoding='utf-8') as f:
        for o in out: f.write(json.dumps(o, ensure_ascii=False) + '\n')
    with open(os.path.join(d, 'hero.txt'), 'w') as f: f.write('wait 5\nmove 1240 700\nwait 30\n')
    return path, GEN, NOW


def hero():
    d = os.path.join(ROOT, 'build', 'site_hero')
    fixture, chan, now = hero_fixture(d)
    png = os.path.join(d, 'hero.png')
    run(os.path.join(ROOT, 'build', 'fastcord-dev'), f'-shot:{png}', '-dpi:2', '-size:1280x840', f'-fixture:{fixture}', f'-channel:{chan}', f'-now:{now // 1000}',
        f'-script:{d}/hero.txt', cwd=ROOT, env=dict(os.environ, FASTCORD_MEDIA_DIR=os.path.join(d, 'media')))
    run('sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85', png, '--out', os.path.join(ROOT, 'site', 'screenshot.jpg'), stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == 'hero': hero(); raise SystemExit
    if len(sys.argv) < 3 or sys.argv[1] not in ('fastcord', 'build'): raise SystemExit(__doc__ if __doc__ else 'usage: site_video.py fastcord|build <scenario>...')
    if sys.argv[1] == 'fastcord':
        for s in sys.argv[2:]: fastcord(s)
    else:
        build(sys.argv[2:])
