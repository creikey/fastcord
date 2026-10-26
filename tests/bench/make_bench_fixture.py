# Builds the benchmark fixture (default build/bench/heavy.jsonl; tools/bench.sh runs this):
# chat.jsonl's READY plus a heavy, deterministic account: 60 guilds with categories and many
# channels, 120 DMs (8 unread), 150 friends, and a guild channel and a DM each holding hundreds of
# messages with markdown, mentions, code, replies, embeds and reactions. All names and text are
# synthetic. Changing it changes every benchmark's numbers: update tests/bench/budget.json with it.
# Run: python3 -I tests/bench/make_bench_fixture.py [out.jsonl]
import json, os, random, sys
here = os.path.dirname(os.path.abspath(__file__))
lines = [json.loads(l) for l in open(os.path.join(here, '..', 'ui', 'chat.jsonl'), encoding='utf-8')]
base = [o for o in lines if o['etf'].get('t') in ('READY', 'READY_SUPPLEMENTAL', {'$atom': 'READY'}, {'$atom': 'READY_SUPPLEMENTAL'})]
ready = next(o['etf']['d'] for o in base if o['etf'].get('t') in ('READY', {'$atom': 'READY'}))
me = ready['user']['id']
rng = random.Random(20261026)
EPOCH = 1420070400000
base_ms = 1793000000000  # 2026-10-25
seq = [0]
def sf(ms):
    seq[0] += 1
    return ((ms - EPOCH) << 22) | (seq[0] & 0x3fffff)
def ev(t, d): return {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': 1000 + len(out), 'd': d}}
out = list(base)

WORDS = ('the quick brown fox jumps over lazy dog frame layout render shader buffer texture arena allocator '
         'cache miss branch thread lock queue packet socket gateway voice opus codec latency jitter pixel glyph '
         'font kerning baseline wrap scroll hover click drag select copy paste emoji reaction thread forum guild '
         'channel message reply mention role member presence typing status online idle offline').split()
FIRST = ['Ada', 'Brook', 'Cass', 'Dev', 'Eli', 'Fern', 'Gus', 'Hana', 'Ivo', 'Jun', 'Kai', 'Lior', 'Mika', 'Nia', 'Oren',
         'Pia', 'Quin', 'Rae', 'Sol', 'Tam', 'Uma', 'Vik', 'Wren', 'Xan', 'Yui', 'Zed']
users = []
for k in range(200):
    n = '%s %s' % (FIRST[k % len(FIRST)], FIRST[(k // len(FIRST) * 5 + k + 3) % len(FIRST)])
    users.append({'id': 1100000000000000001 + k, 'username': n.lower().replace(' ', '_') + str(k), 'global_name': n, 'avatar': None, 'discriminator': '0'})
EMOJI = ['👍', '🔥', '😂', '🎉', '❤️', '👀', '✅', '🙏', '💯', '🤔']

def sentence(lo, hi):
    return ' '.join(rng.choice(WORDS) for _ in range(rng.randint(lo, hi)))

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

def messages(channel_id, guild_id, authors, n, start_ms):
    ids = []
    t = start_ms
    for k in range(n):
        t += rng.choice([5, 20, 40, 90, 400, 3600]) * 1000  # mixes grouped runs and new headers
        mid = sf(t)
        d = {'id': mid, 'channel_id': channel_id, 'author': rng.choice(authors), 'content': content(k), 'timestamp': '', 'edited_timestamp': None,
             'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}
        if guild_id: d['guild_id'] = guild_id
        if k % 7 == 3:
            d['reactions'] = [{'emoji': {'id': None, 'name': e}, 'count': rng.randint(1, 12), 'me': rng.random() < 0.3, 'burst_count': 0, 'me_burst': False}
                              for e in rng.sample(EMOJI, rng.randint(1, 5))]
        if k % 11 == 5 and ids:
            ref = rng.choice(ids[-20:])
            d['type'] = 19
            d['message_reference'] = {'message_id': ref, 'channel_id': channel_id, 'guild_id': guild_id}
        if k % 13 == 8:
            d['embeds'] = [{'type': 'rich', 'title': sentence(3, 6), 'description': sentence(15, 40), 'color': 0x5865F2, 'url': 'https://example.com/%d' % k}]
        ids.append(mid)
        out.append(ev('MESSAGE_CREATE', d))
    return ids

GUILDS = [1600000000000100001 + i * 10000 for i in range(60)]
BENCH_GUILD = GUILDS[0]
BENCH_CHANNEL = GUILDS[0] + 2
for i, gid in enumerate(GUILDS):
    chans = []
    pos = 0
    for c in range(4):
        cat = gid + 1000 + c
        chans.append({'id': cat, 'type': 4, 'name': '%s things' % WORDS[(i + c * 5) % len(WORDS)], 'position': c, 'parent_id': None, 'permission_overwrites': []})
        for j in range(7 if c else 8):
            cid = gid + 2 + pos
            kind = 2 if c == 3 else 0
            chans.append({'id': cid, 'type': kind, 'name': '%s-%s' % (WORDS[(i * 3 + j) % len(WORDS)], WORDS[(j * 5 + c) % len(WORDS)]) if cid != BENCH_CHANNEL else 'general',
                          'position': j, 'parent_id': cat, 'permission_overwrites': [], 'last_message_id': None})
            pos += 1
    out.append(ev('GUILD_CREATE', {'id': gid, 'name': '%s %s %d' % (WORDS[i % len(WORDS)].title(), WORDS[(i * 7) % len(WORDS)].title(), i), 'icon': None,
        'owner_id': users[0]['id'], 'joined_at': '2026-01-01T00:00:00+00:00', 'roles': [], 'emojis': [], 'stickers': [], 'features': [],
        'member_count': 40 + i, 'channels': chans}))
messages(BENCH_CHANNEL, BENCH_GUILD, users[:40] + [ready['user']], 400, base_ms - 400 * 3600 * 1000)

DMS = [1700000000000100001 + k for k in range(120)]
for k, cid in enumerate(DMS):
    rec = [users[k]] if k % 10 else [users[k], users[k + 1], users[k + 2]]
    out.append(ev('CHANNEL_CREATE', {'id': cid, 'type': 1 if len(rec) == 1 else 3, 'recipients': rec, 'last_message_id': None, 'name': None,
        'owner_id': me if len(rec) > 1 else None, 'icon': None}))
    # Most DMs end with our own message, so they are read; every 15th is unread.
    messages(cid, None, rec if k % 15 == 0 else [ready['user']], 300 if k == 0 else 1, base_ms - (k + 1) * 900 * 1000)
for u in users[:150]:
    out.append(ev('RELATIONSHIP_ADD', {'id': u['id'], 'type': 1, 'user': u, 'nickname': None, 'since': '2026-01-01T00:00:00+00:00'}))

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', '..', 'build', 'bench', 'heavy.jsonl')
os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    for o in out: f.write(json.dumps(o, ensure_ascii=False) + '\n')
print('wrote %s: %d events; bench guild channel %d, bench DM %d' % (path, len(out), BENCH_CHANNEL, DMS[0]))
