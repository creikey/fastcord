# Builds tests/ui/rail.jsonl: chat.jsonl plus extra guilds, a guild folder
# (settings proto 1 field 14), an unread mention in a guild, unread DMs and a
# group DM — for the server rail (folders, badges, DM avatars) and the DM views.
# Run: python3 -I tests/ui/make_rail_fixture.py
import base64, json, os
here = os.path.dirname(os.path.abspath(__file__))
lines = [json.loads(l) for l in open(os.path.join(here, 'chat.jsonl'), encoding='utf-8')]
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
         for k, n in enumerate(['Robin', 'Nelly', 'Sam', 'Phibi'])]
# every guild has @everyone (its own id), here with a new server's usual member permissions
EVERYONE_PERMS = sum(1 << b for b in (0, 6, 10, 11, 14, 15, 16, 18, 20, 21, 25, 26, 31, 35, 38))
def EVERYONE(gid): return {'id': gid, 'name': '@everyone', 'permissions': str(EVERYONE_PERMS), 'position': 0, 'color': 0, 'hoist': False, 'managed': False, 'mentionable': False}
for i, gid in enumerate(G):
    ch = gid + 1
    out.append(ev('GUILD_CREATE', {'id': gid, 'name': names[i], 'icon': None, 'owner_id': users[0]['id'], 'joined_at': '2026-01-0%dT00:00:00+00:00' % (i + 1),
        'roles': [EVERYONE(gid)], 'emojis': [], 'stickers': [], 'features': [], 'member_count': 3,
        'channels': [{'id': ch, 'type': 0, 'name': 'general', 'position': 0, 'parent_id': None, 'permission_overwrites': [], 'last_message_id': None}]}))
# guild 2 has an unread @mention, guild 3 just unread
for i, (gi, mention) in enumerate([(1, True), (3, False)]):
    out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 5000 * 1000, 70 + i), 'channel_id': G[gi] + 1, 'guild_id': G[gi], 'author': users[1],
        'content': ('<@%d> look at this' % me) if mention else 'hello', 'timestamp': '', 'edited_timestamp': None, 'type': 0, 'attachments': [],
        # the mention carries a two-image post, so the inbox's narrow card must shrink its mosaic
        'embeds': [{'type': 'rich', 'url': 'https://x.com/p/1', 'image': {'url': 'https://pbs.twimg.com/%d.png' % k, 'width': 640, 'height': 360}} for k in range(2)] if mention else [],
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
# friends so the Create DM popout has people to list; Nelly has a friend nickname
for k, u in enumerate(users):
    out.append(ev('RELATIONSHIP_ADD', {'id': u['id'], 'type': 1, 'user': u, 'nickname': 'Lil Bean' if k == 1 else None, 'since': '2026-01-01T00:00:00+00:00'}))
# an outgoing friend request alone still shows the Pending tab
quinn = {'id': 1000000000000000009, 'username': 'quinn', 'global_name': 'Quinn', 'avatar': None, 'discriminator': '0'}
out.append(ev('RELATIONSHIP_ADD', {'id': quinn['id'], 'type': 4, 'user': quinn, 'nickname': None, 'since': '2026-01-02T00:00:00+00:00'}))
with open(os.path.join(here, 'rail.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    for o in out: f.write(json.dumps(o) + '\n')
print('wrote rail.jsonl', len(out))
# member_roles.jsonl: chat.jsonl (our own server) plus two roles to hand out (the user menu's Roles)
roles = [ev('GUILD_ROLE_CREATE', {'guild_id': 1546820558300258304, 'role': {'id': 1546820558300258400 + k, 'name': n, 'color': c, 'position': k + 1,
    'permissions': '0', 'hoist': False, 'mentionable': False, 'managed': False, 'icon': None, 'unicode_emoji': None}}) for k, (n, c) in enumerate([('Helper', 0x2ECC71), ('Moderator', 0xE67E22)])]
with open(os.path.join(here, 'member_roles.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    for o in lines + roles + [ev('GUILD_MEMBER_ADD', {'guild_id': 1546820558300258304, 'user': {'id': 1000000000020971521, 'username': 'robin', 'global_name': 'Robin', 'avatar': None, 'discriminator': '0'}, 'roles': [1546820558300258400], 'joined_at': '2026-01-01T00:00:00+00:00'})]: f.write(json.dumps(o) + '\n')
# leaving_discord.jsonl: the rail fixture plus a masked link in Sam's DM (the Leaving Discord dialog)
link = ev('MESSAGE_CREATE', {'id': sf(base_ms + 6500 * 1000, 99), 'channel_id': 1700000000000000002, 'author': users[2],
    'content': 'see [the docs](https://discord.com@example.org/docs) and [ours](https://discord.com/developers)', 'timestamp': '', 'edited_timestamp': None,
    'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False})
with open(os.path.join(here, 'leaving_discord.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    for o in out + [link]: f.write(json.dumps(o) + '\n')
# message_requests.jsonl: the rail fixture plus a message request, a spam DM, a blocked user, an incoming
# friend request and a friend playing a game (Message Requests, Blocked, Pending, Active Now)
strangers = [{'id': 1000000000000000020 + k, 'username': n.lower(), 'global_name': n, 'avatar': None, 'discriminator': '0'}
             for k, n in enumerate(['Stranger', 'Spammer', 'Troll', 'Newbie'])]
for k, (u, spam) in enumerate([(strangers[0], False), (strangers[1], True)]):
    cid = 1700000000000000010 + k
    out.append(ev('CHANNEL_CREATE', {'id': cid, 'type': 1, 'recipients': [u], 'last_message_id': None, 'name': None, 'owner_id': None, 'icon': None,
        'is_message_request': True, 'is_spam': spam}))
    out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 7000 * 1000 + k * 1000, 120 + k), 'channel_id': cid, 'author': u, 'content': 'hey there',
        'timestamp': '', 'edited_timestamp': None, 'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
out.append(ev('RELATIONSHIP_ADD', {'id': strangers[2]['id'], 'type': 2, 'user': strangers[2], 'nickname': None, 'since': '2026-01-03T00:00:00+00:00'}))
out.append(ev('RELATIONSHIP_ADD', {'id': strangers[3]['id'], 'type': 3, 'user': strangers[3], 'nickname': None, 'since': '2026-01-04T00:00:00+00:00'}))
out.append(ev('PRESENCE_UPDATE', {'user': {'id': users[3]['id']}, 'status': 'online', 'client_status': {'desktop': 'online'}, 'activities': [{'type': 0, 'name': 'Factorio'}]}))
with open(os.path.join(here, 'message_requests.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    for o in out: f.write(json.dumps(o) + '\n')
print('wrote message_requests.jsonl', len(out))
