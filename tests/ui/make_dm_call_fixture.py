# Builds tests/ui/dm_call.jsonl: dm.jsonl plus a group DM with a call going on (one member in it).
# Run: python3 -I tests/ui/make_dm_call_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
GROUP = 1800000000000000009
users = [{'id': 1000000000000000100 + i, 'username': n, 'global_name': None, 'avatar': None, 'discriminator': '0'}
         for i, n in ((1, 'creikey'), (2, 'robin'), (3, 'sam'))]
lines = open(os.path.join(here, 'dm.jsonl')).read().rstrip('\n').split('\n')
ev = lambda s, t, d: json.dumps({'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': s, 'd': d}})
lines.append(ev(990, 'CHANNEL_CREATE', {'id': GROUP, 'type': 3, 'recipients': users, 'last_message_id': None, 'name': 'Raid Night', 'owner_id': users[0]['id'], 'icon': None}))
lines.append(ev(991, 'VOICE_STATE_UPDATE', {'user_id': users[0]['id'], 'channel_id': GROUP, 'guild_id': None, 'session_id': 's1', 'self_mute': False,
                                            'self_deaf': False, 'mute': False, 'deaf': False, 'self_video': False, 'suppress': False}))
open(os.path.join(here, 'dm_call.jsonl'), 'w').write('\n'.join(lines) + '\n')
