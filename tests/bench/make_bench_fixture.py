# Builds the benchmark account (default build/bench/heavy.jsonl plus build/bench/media/; jai build.jai - bench runs
# this). Its shape is a made-up heavy account: round totals, and a sidebar of 30 guilds whose sizes are
# heavy-tailed like a real one. Pass a shape.json captured with `-shape:` to copy a real account instead
# (counts only; keep it out of the repo). On top of that shape it adds two long channels for the chat
# benches: guild channel 1600000000000100003 (400 messages) and DM 1300000000000100001 (300). Images
# (avatars, guild icons, emoji) are generated PNGs served offline through FASTCORD_MEDIA_DIR, so the GPU
# sees as many distinct textures as on a real account.
# All names and text are synthetic. Changing it changes every benchmark's numbers: update tests/bench/budget.json.
# Run: python3 -I tests/bench/make_bench_fixture.py [out.jsonl] [shape.json]
import base64, json, os, random, struct, sys, zlib
here = os.path.dirname(os.path.abspath(__file__))
out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', '..', 'build', 'bench', 'heavy.jsonl')

def synthetic_shape():
    r = random.Random(7)
    def tail(top): return int(top * r.random() ** 4)
    guilds = [{'channels': 1 + tail(110), 'categories': tail(17), 'voice': tail(13), 'threads': tail(12), 'roles': 1 + tail(100),
               'emojis': tail(200), 'members': 1 + tail(60), 'unread': tail(45), 'mentions': int(r.random() < 0.15),
               'muted': r.random() < 0.4} for _ in range(30)]
    rail = []
    while guilds:
        n = min(r.choice((1, 1, 3, 4, 5)), len(guilds))
        rail.append({'folder': n > 1, 'guilds': guilds[:n]})
        guilds = guilds[n:]
    return {'users': 500, 'users_with_avatar': 470, 'guilds_with_icon': 22, 'emojis': 700, 'animated_emojis': 100,
            'muted_channels': 50, 'collapsed_categories': 65, 'muted_guilds': 120, 'guild_settings': 190, 'dms': 100,
            'group_dms': 5, 'unread_dms': 9, 'mention_dms': 5, 'read_states': 630, 'friends': 500,
            'other_relationships': 1, 'presences': 200, 'rail': rail}

shape = json.load(open(sys.argv[2], encoding='utf-8')) if len(sys.argv) > 2 else synthetic_shape()
media_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), 'media')
os.makedirs(media_dir, exist_ok=True)

lines = [json.loads(l) for l in open(os.path.join(here, '..', 'ui', 'chat.jsonl'), encoding='utf-8')]
def is_t(o, name): return o['etf'].get('t') in (name, {'$atom': name})
ready = next(o['etf']['d'] for o in lines if is_t(o, 'READY'))
supp = next(o['etf']['d'] for o in lines if is_t(o, 'READY_SUPPLEMENTAL'))
me = ready['user']['id']
rng = random.Random(20261026)
EPOCH = 1420070400000
base_ms = 1793000000000  # 2026-10-25
seq = [0]
def sf(ms):
    seq[0] += 1
    return ((ms - EPOCH) << 22) | (seq[0] & 0x3fffff)
out = []
def ev(t, d): out.append({'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': 1000 + len(out), 'd': d}})

# ---- images ----

def png(w, h, seed):
    r = random.Random(seed)
    c0 = [r.randrange(40, 230) for _ in range(3)]
    c1 = [r.randrange(40, 230) for _ in range(3)]
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            t = (x + y) / (w + h - 2)
            band = ((x * 3 // w) + (y * 3 // h)) & 1
            rows += bytes(int(c0[i] * (1 - t) + c1[i] * t) ^ (band * 24) for i in range(3)) + b'\xff'
    def chunk(k, data): return struct.pack('>I', len(data)) + k + data + struct.pack('>I', zlib.crc32(k + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b'')

def media(name, w, seed):
    p = os.path.join(media_dir, name)
    if not os.path.exists(p):
        with open(p, 'wb') as f: f.write(png(w, w, seed))

for i in range(6): media('%d.png' % i, 128, 'default%d' % i)

# ---- text ----

WORDS = ('the quick brown fox jumps over lazy dog frame layout render shader buffer texture arena allocator '
         'cache miss branch thread lock queue packet socket gateway voice opus codec latency jitter pixel glyph '
         'font kerning baseline wrap scroll hover click drag select copy paste emoji reaction thread forum guild '
         'channel message reply mention role member presence typing status online idle offline').split()
FIRST = ['Ada', 'Brook', 'Cass', 'Dev', 'Eli', 'Fern', 'Gus', 'Hana', 'Ivo', 'Jun', 'Kai', 'Lior', 'Mika', 'Nia', 'Oren',
         'Pia', 'Quin', 'Rae', 'Sol', 'Tam', 'Uma', 'Vik', 'Wren', 'Xan', 'Yui', 'Zed']
EMOJI = ['👍', '🔥', '😂', '🎉', '❤️', '👀', '✅', '🙏', '💯', '🤔']
def sentence(lo, hi): return ' '.join(rng.choice(WORDS) for _ in range(rng.randint(lo, hi)))

# ---- users ----

n_users = max(shape['users'] - 1, 1)
users = []
for k in range(n_users):
    n = '%s %s' % (FIRST[k % len(FIRST)], FIRST[(k // len(FIRST) * 5 + k + 3) % len(FIRST)])
    u = {'id': 1100000000000000001 + k, 'username': n.lower().replace(' ', '_') + str(k), 'global_name': n, 'avatar': None, 'discriminator': '0'}
    if k < shape['users_with_avatar']:
        u['avatar'] = 'av%040x' % k
        media(u['avatar'] + '.webp', 128, u['avatar'])
    users.append(u)

def content(k):
    r = k % 12
    if r == 0: return sentence(3, 9)
    if r == 1: return sentence(25, 70)  # wraps over several lines
    if r == 2: return '**%s** and *%s* with `%s` and ~~%s~~' % (sentence(2, 4), sentence(2, 4), sentence(1, 2), sentence(1, 3))
    if r == 3: return '<@%d> %s' % (rng.choice(users)['id'], sentence(4, 12))
    if r == 4: return '```odin\n' + '\n'.join('%s := %s(%d)' % (rng.choice(WORDS), rng.choice(WORDS), i) for i in range(rng.randint(3, 8))) + '\n```'
    if r == 5: return '> %s\n%s' % (sentence(5, 12), sentence(3, 10))
    if r == 6: return '- %s\n- %s\n- %s' % (sentence(3, 6), sentence(3, 6), sentence(3, 6))
    if r == 7: return '%s %s %s' % (sentence(2, 5), rng.choice(EMOJI), sentence(2, 5))
    if r == 8: return '# %s\n%s' % (sentence(2, 4), sentence(10, 25))
    if r == 9: return 'see https://example.com/%s/%d for %s' % (rng.choice(WORDS), k, sentence(3, 8))
    if r == 10: return '||%s|| %s' % (sentence(2, 4), sentence(3, 8))
    return sentence(8, 20) + '\n' + sentence(8, 20)

def messages(channel_id, guild_id, authors, n, end_ms, mention_me=False):
    """n messages ending at end_ms; returns the last id."""
    ids = []
    t = end_ms - n * 600 * 1000
    for k in range(n):
        t += rng.choice([5, 20, 40, 90, 400, 1500]) * 1000
        mid = sf(min(t, end_ms))
        d = {'id': mid, 'channel_id': channel_id, 'author': rng.choice(authors), 'content': content(k), 'timestamp': '', 'edited_timestamp': None,
             'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}
        if guild_id: d['guild_id'] = guild_id
        if mention_me and k == n - 1:
            d['content'] = '<@%d> %s' % (me, sentence(3, 8))
            d['mentions'] = [{'id': me, 'username': ready['user'].get('username', 'me'), 'discriminator': '0', 'avatar': None}]
        if k % 7 == 3:
            d['reactions'] = [{'emoji': {'id': None, 'name': e}, 'count': rng.randint(1, 12), 'me': rng.random() < 0.3, 'burst_count': 0, 'me_burst': False}
                              for e in rng.sample(EMOJI, rng.randint(1, 5))]
        if k % 11 == 5 and ids:
            d['type'] = 19
            d['message_reference'] = {'message_id': rng.choice(ids[-20:]), 'channel_id': channel_id, 'guild_id': guild_id}
        if k % 13 == 8:
            d['embeds'] = [{'type': 'rich', 'title': sentence(3, 6), 'description': sentence(15, 40), 'color': 0x5865F2, 'url': 'https://example.com/%d' % k}]
        ids.append(mid)
        ev('MESSAGE_CREATE', d)
    return ids[-1] if ids else None

# ---- guilds, in sidebar order ----

read_states = []  # (channel id, last read id, mention count) or None for "no read state"
msg_channels = []  # every channel that can hold messages, for read-state accounting: [cid, last_id, unread, mentions]
guild_settings = []
guild_events = []
folders_proto = []
member_lists = []
rail = shape['rail']
flat = [(ei, g) for ei, e in enumerate(rail) for g in e['guilds']]
icons_left = shape['guilds_with_icon']
anim_left = shape['animated_emojis']
emoji_total = max(shape['emojis'], 1)
muted_ch_left, collapsed_left = shape['muted_channels'], shape['collapsed_categories']
GUILDS = [1600000000000100001 + i * 10000 for i in range(len(flat))]
BENCH_CHANNEL = GUILDS[0] + 2
for i, (ei, gs) in enumerate(flat):
    gid = GUILDS[i]
    chans, threads, overrides = [], [], []
    ncat = gs['categories']
    cats = [gid + 1000 + c for c in range(ncat)]
    for c, cid in enumerate(cats):
        chans.append({'id': cid, 'type': 4, 'name': '%s things' % WORDS[(i + c * 5) % len(WORDS)], 'position': c, 'parent_id': None, 'permission_overwrites': []})
        if collapsed_left > 0:
            overrides.append({'channel_id': cid, 'muted': False, 'collapsed': True}); collapsed_left -= 1
    pos = 0
    text_ids = []
    unread_left, mention_left = gs['unread'], gs['mentions']
    for j in range(gs['channels'] + gs['voice']):
        cid = gid + 2 + pos
        pos += 1
        voice = j >= gs['channels']
        ch = {'id': cid, 'type': 2 if voice else 0, 'position': j, 'parent_id': cats[j % ncat] if ncat else None, 'permission_overwrites': [],
              'name': 'general' if cid == BENCH_CHANNEL else '%s-%s' % (WORDS[(i * 3 + j) % len(WORDS)], WORDS[(j * 5) % len(WORDS)])}
        # Voice channels have text chat too: they carry unreads once the text channels are used up.
        if not voice or unread_left > 0:
            last = sf(base_ms - (i * 97 + j) * 3600 * 1000)
            ch['last_message_id'] = last
            unread = unread_left > 0 and cid != BENCH_CHANNEL
            mentions = 0
            if unread:
                unread_left -= 1
                if mention_left > 0: mentions, mention_left = 1 + j % 3, mention_left - 1
            msg_channels.append([cid, last, unread, mentions])
            if not voice: text_ids.append(cid)
            if muted_ch_left > 0 and j % 5 == 4:
                overrides.append({'channel_id': cid, 'muted': True, 'collapsed': False}); muted_ch_left -= 1
        chans.append(ch)
    for t in range(gs['threads']):
        tid = gid + 5000 + t
        last = sf(base_ms - (i * 13 + t) * 7200 * 1000)
        threads.append({'id': tid, 'type': 11, 'name': 'thread %s' % WORDS[(i + t) % len(WORDS)], 'parent_id': text_ids[t % len(text_ids)] if text_ids else None,
                        'guild_id': gid, 'last_message_id': last, 'thread_metadata': {'archived': False, 'locked': False}})
        msg_channels.append([tid, last, False, 0])
    roles = [{'id': gid, 'name': '@everyone', 'color': 0, 'position': 0, 'permissions': '1071698660929', 'hoist': False, 'managed': False, 'mentionable': False}]
    for r in range(1, gs['roles']):
        roles.append({'id': gid + 3000 + r, 'name': '%s role' % WORDS[(i + r) % len(WORDS)], 'color': rng.randrange(0x1000000), 'position': r,
                      'permissions': '0', 'hoist': r < 3, 'managed': False, 'mentionable': False})
    emojis = []
    for e in range(gs['emojis']):
        eid = 1300000000000000001 + i * 1000 + e
        animated = anim_left > 0 and (e * emoji_total) % max(shape['emojis'] // max(shape['animated_emojis'], 1), 1) == 0
        if animated: anim_left -= 1
        emojis.append({'id': eid, 'name': '%s_%d' % (WORDS[(i + e) % len(WORDS)], e), 'animated': animated, 'available': True, 'require_colons': True, 'managed': False, 'roles': []})
        media('%d.webp' % eid, 48, eid)
    icon = None
    if icons_left > 0 and (i % 4 != 3 or icons_left >= len(flat) - i):
        icon = 'ic%040x' % i
        icons_left -= 1
        media(icon + '.webp', 128, icon)
    guild_events.append({'id': gid, 'name': '%s %s %d' % (WORDS[i % len(WORDS)].title(), WORDS[(i * 7) % len(WORDS)].title(), i), 'icon': icon,
        'owner_id': users[0]['id'], 'joined_at': '2026-01-01T00:00:00+00:00', 'roles': roles, 'emojis': emojis, 'stickers': [], 'features': [],
        'member_count': 40 + i * 7, 'channels': chans, 'threads': threads})
    member_lists.append([{'user_id': me, 'roles': [], 'joined_at': '2026-01-01T00:00:00+00:00', 'nick': None}] +
                        [{'user_id': users[(i * 31 + m) % len(users)]['id'], 'roles': [], 'joined_at': '2026-01-01T00:00:00+00:00', 'nick': None} for m in range(max(gs['members'] - 1, 0))])
    guild_settings.append({'guild_id': gid, 'muted': gs['muted'], 'message_notifications': 1, 'suppress_everyone': False, 'suppress_roles': False, 'channel_overrides': overrides})

# Settings for guilds no longer joined, as real accounts keep them.
muted_left = shape['muted_guilds'] - sum(1 for _, g in flat if g['muted'])
for k in range(max(shape['guild_settings'] - len(flat), 0)):
    guild_settings.append({'guild_id': 1650000000000000001 + k, 'muted': k < muted_left, 'message_notifications': 1, 'suppress_everyone': False, 'suppress_roles': False, 'channel_overrides': []})

for g in guild_events: ev('GUILD_CREATE', g)
messages(BENCH_CHANNEL, GUILDS[0], users[:40] + [ready['user']], 400, base_ms)
for mc in msg_channels:
    if mc[0] == BENCH_CHANNEL: mc[1] = None  # its read state is added below, after its messages

# ---- DMs ----

dms = []
n_dm, n_group = shape['dms'], shape['group_dms']
DMS = [1300000000000100001 + k for k in range(n_dm + n_group)]
unread_dm, mention_dm = shape['unread_dms'], shape['mention_dms']
for k, cid in enumerate(DMS):
    group = k >= n_dm
    rec = [users[(k * 3 + j) % len(users)] for j in range(3)] if group else [users[k % len(users)]]
    unread = 1 <= k <= unread_dm
    mentioned = 1 <= k <= mention_dm
    # Like a fresh session, DMs have no messages loaded, only their last_message_id. Unread DMs without a
    # mention count stay off the rail that way; mentioned ones get messages so the bench can open one.
    end = base_ms - k * 900 * 1000 if k else base_ms - 1800 * 1000
    if k == 0 or mentioned:
        last = messages(cid, None, rec if unread else [ready['user']] + rec, 300 if k == 0 else 30, end, mention_me=mentioned and not group)
    else:
        last = sf(end)
    dms.append({'id': cid, 'type': 3 if group else 1, 'recipient_ids': [u['id'] for u in rec], 'last_message_id': last, 'name': None,
                'owner_id': me if group else None, 'icon': None, 'flags': 0})
    msg_channels.append([cid, last, unread, 1 if mentioned else 0])

# ---- read states: drop some unread channels' entries so the count matches (real accounts lack them too) ----

entries = []
missing = max(len(msg_channels) - shape['read_states'], 0)
for cid, last, unread, mentions in msg_channels:
    if last is None:
        continue
    if unread and missing > 0 and mentions == 0 and cid not in DMS:
        missing -= 1
        continue
    entries.append({'id': cid, 'last_message_id': (last - (1 << 22)) if unread else last, 'mention_count': mentions, 'last_pin_timestamp': '1970-01-01T00:00:00+00:00', 'flags': 0})
# The bench channel is read up to its newest message.
entries.append({'id': BENCH_CHANNEL, 'last_message_id': sf(base_ms + 1000), 'mention_count': 0, 'last_pin_timestamp': '1970-01-01T00:00:00+00:00', 'flags': 0})

# ---- settings proto: replace guild folders (field 14) with the shape's sidebar ----

def varint(v):
    b = bytearray()
    while True:
        x = v & 0x7f
        v >>= 7
        if v: b.append(x | 0x80)
        else: b.append(x); return bytes(b)
def field(num, wt, payload): return varint(num << 3 | wt) + payload
def ld(num, data): return field(num, 2, varint(len(data)) + data)
def strip_field(buf, drop):
    out_b, i = bytearray(), 0
    while i < len(buf):
        start = i
        key = 0; shift = 0
        while True:
            c = buf[i]; i += 1; key |= (c & 0x7f) << shift; shift += 7
            if c < 0x80: break
        num, wt = key >> 3, key & 7
        if wt == 0:
            while buf[i] & 0x80: i += 1
            i += 1
        elif wt == 1: i += 8
        elif wt == 5: i += 4
        elif wt == 2:
            n = 0; shift = 0
            while True:
                c = buf[i]; i += 1; n |= (c & 0x7f) << shift; shift += 7
                if c < 0x80: break
            i += n
        else: raise ValueError('wire type %d' % wt)
        if num != drop: out_b += buf[start:i]
    return bytes(out_b)
folders = b''
gi = 0
for ei, e in enumerate(rail):
    ids = GUILDS[gi:gi + len(e['guilds'])]
    gi += len(e['guilds'])
    f = ld(1, b''.join(struct.pack('<Q', g) for g in ids))
    if e['folder']:
        f += ld(2, field(1, 0, varint(9000 + ei))) + ld(3, ld(1, ('%s folder' % WORDS[ei % len(WORDS)]).encode())) + ld(4, field(1, 0, varint(rng.randrange(0x1000000))))
    folders += ld(1, f)
proto = strip_field(base64.b64decode(ready['user_settings_proto']), 14) + ld(14, folders)

# ---- READY / READY_SUPPLEMENTAL ----

friends = users[:shape['friends']]
ready.update({
    'guilds': [], 'merged_members': [], 'users': users, 'private_channels': dms,
    'relationships': [{'id': u['id'], 'type': 1, 'user': u, 'nickname': None, 'since': '2026-01-01T00:00:00+00:00'} for u in friends] +
                     [{'id': users[-1 - k]['id'], 'type': 2, 'user': users[-1 - k], 'nickname': None, 'since': '2026-01-01T00:00:00+00:00'} for k in range(shape['other_relationships'])],
    'read_state': {'version': 1, 'partial': False, 'entries': entries},
    'user_guild_settings': {'version': 1, 'partial': False, 'entries': guild_settings},
    'user_settings_proto': base64.b64encode(proto).decode(),
})
STATUSES = ['online', 'idle', 'dnd', 'online']
supp.update({
    'guilds': [{'id': g, 'voice_states': []} for g in GUILDS], 'merged_members': member_lists, 'lazy_private_channels': [],
    'merged_presences': {'friends': [{'user_id': u['id'], 'status': STATUSES[k % 4], 'client_status': {'desktop': STATUSES[k % 4]}, 'activities': []}
                                     for k, u in enumerate(friends[:shape['presences']])], 'guilds': [[] for _ in GUILDS]},
})
head = [{'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': 'READY', 's': 1, 'd': ready}}, {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': 'READY_SUPPLEMENTAL', 's': 2, 'd': supp}}]

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
    for o in head + out: f.write(json.dumps(o, ensure_ascii=False) + '\n')
print('wrote %s (%d events) and %s; bench guild channel %d, bench DM %d' % (out_path, len(out) + 2, media_dir, BENCH_CHANNEL, DMS[0]))
