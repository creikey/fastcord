# Builds tests/ui/rail.jsonl: chat.jsonl plus extra guilds, a guild folder
# (settings proto 1 field 14), an unread mention in a guild, unread DMs and a
# group DM — for the server rail (folders, badges, DM avatars) and the DM views.
# Run: python3 -I tests/ui/make_rail_fixture.py
import base64, json, os
here = os.path.dirname(os.path.abspath(__file__))
lines = [json.loads(l) for l in open(os.path.join(here, 'chat.jsonl'))]
ready = next(o['etf']['d'] for o in lines if o['etf'].get('t') in ('READY', {'$atom': 'READY'}))
me = ready['user']['id']
EPOCH = 1420070400000
base_ms = 1793000000000
def sf(ms, n): return ((ms - EPOCH) << 22) | n
def ev(t, d, seq=900): return {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': seq, 'd': d}}
out = list(lines)
G = [1600000000000000001 + i * 1000 for i in range(4)]
names = ['Odin Lang', 'Pixel Art Club', 'Rust Gamedev', 'Night Owls']
users = [{'id': 1000000000000000001 + k, 'username': n.lower(), 'global_name': n, 'avatar': None, 'discriminator': '0'}
         for k, n in enumerate(['Wumpus', 'Nelly', 'Clyde', 'Phibi'])]
for i, gid in enumerate(G):
    ch = gid + 1
    out.append(ev('GUILD_CREATE', {'id': gid, 'name': names[i], 'icon': None, 'owner_id': users[0]['id'], 'joined_at': '2026-01-0%dT00:00:00+00:00' % (i + 1),
        'roles': [], 'emojis': [], 'stickers': [], 'features': [], 'member_count': 3,
        'channels': [{'id': ch, 'type': 0, 'name': 'general', 'position': 0, 'parent_id': None, 'permission_overwrites': [], 'last_message_id': None}]}))
# guild 2 has an unread @mention, guild 3 just unread
for i, (gi, mention) in enumerate([(1, True), (3, False)]):
    out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 5000 * 1000, 70 + i), 'channel_id': G[gi] + 1, 'guild_id': G[gi], 'author': users[1],
        'content': ('<@%d> look at this' % me) if mention else 'hello', 'timestamp': '', 'edited_timestamp': None, 'type': 0, 'attachments': [], 'embeds': [],
        'mentions': [{'id': me, 'username': 'dingus'}] if mention else [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
# folder "Code" with Odin Lang + Rust Gamedev (red), Pixel Art Club + Night Owls loose
def varint(v):
    b = b''
    while v >= 0x80: b += bytes([(v & 0x7f) | 0x80]); v >>= 7
    return b + bytes([v])
def ld(num, payload): return varint(num << 3 | 2) + varint(len(payload)) + payload
def folder(ids, fid, name, color):
    p = ld(1, b''.join(i.to_bytes(8, 'little') for i in ids))
    if fid: p += ld(2, varint(1 << 3) + varint(fid))
    if name: p += ld(3, ld(1, name.encode()))
    if color is not None: p += ld(4, varint(1 << 3) + varint(color))
    return ld(1, p)
gf = folder([G[1]], 0, '', None) + folder([G[0], G[2]], 4242, 'Code', 0xED4245) + folder([G[3]], 0, '', None)
proto = ld(14, gf)
out.append(ev('USER_SETTINGS_PROTO_UPDATE', {'settings': {'type': 1, 'proto': base64.b64encode(proto).decode()}, 'partial': True}))
# DMs: one unread DM (2 messages), a read DM, and a group DM
dms = [(1700000000000000001, 1, [users[1]], 2), (1700000000000000002, 1, [users[2]], 0), (1700000000000000003, 3, [users[1], users[3]], 1)]
for k, (cid, kind, rec, unread) in enumerate(dms):
    out.append(ev('CHANNEL_CREATE', {'id': cid, 'type': kind, 'recipients': rec, 'last_message_id': None, 'name': None, 'owner_id': me if kind == 3 else None, 'icon': None}))
    for m in range(unread):
        out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 6000 * 1000 + m * 1000, 80 + k * 4 + m), 'channel_id': cid, 'author': rec[0], 'content': 'ping %d' % m,
            'timestamp': '', 'edited_timestamp': None, 'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
# friends so the Create DM popout has people to list
for k, u in enumerate(users):
    out.append(ev('RELATIONSHIP_ADD', {'id': u['id'], 'type': 1, 'user': u, 'nickname': None, 'since': '2026-01-01T00:00:00+00:00'}))
with open(os.path.join(here, 'rail.jsonl'), 'w') as f:
    for o in out: f.write(json.dumps(o) + '\n')
print('wrote rail.jsonl', len(out))
