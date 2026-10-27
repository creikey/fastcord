# Builds tests/ui/dm.jsonl: chat.jsonl plus short DMs for the start-of-history
# header (0, 1 and 3 messages; friends and a stranger).
# Run: python3 -I tests/ui/make_dm_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
out = [json.loads(l) for l in open(os.path.join(here, 'chat.jsonl'))]
EPOCH = 1420070400000
base_ms = 1793000000000
def sf(ms, n): return ((ms - EPOCH) << 22) | n
def ev(t, d, seq=900): return {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': seq, 'd': d}}
users = [{'id': 1000000000000000101 + k, 'username': n, 'global_name': None, 'avatar': None, 'discriminator': '0'}
         for k, n in enumerate(['creikey', 'stranger', 'chatty'])]
# 1800..01: friend, one message; ..02: stranger, no messages; ..03: friend, three messages
for k, (u, friend, n) in enumerate([(users[0], True, 1), (users[1], False, 0), (users[2], True, 3)]):
    cid = 1800000000000000001 + k
    out.append(ev('CHANNEL_CREATE', {'id': cid, 'type': 1, 'recipients': [u], 'last_message_id': None, 'name': None, 'owner_id': None, 'icon': None}))
    if friend:
        out.append(ev('RELATIONSHIP_ADD', {'id': u['id'], 'type': 1, 'user': u, 'nickname': None, 'since': '2026-01-01T00:00:00+00:00'}))
    for m in range(n):
        out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 6000 * 1000 + m * 1000, 90 + k * 4 + m), 'channel_id': cid, 'author': u, 'content': 'hello %d' % m,
            'timestamp': '', 'edited_timestamp': None, 'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
with open(os.path.join(here, 'dm.jsonl'), 'w') as f:
    for o in out: f.write(json.dumps(o) + '\n')
print('wrote dm.jsonl', len(out))
