# Builds tests/ui/call/call.jsonl: chat.jsonl with four people in the General voice
# channel (one live on Go Live, one muted), a voice channel with a user limit and a
# stage with a speaker and an audience member, for the call view.
# Run: python3 -I tests/ui/call/make_call_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
ui = os.path.dirname(here)
VOICE = 1546820558950371411
LIMITED = 1546820558950371412
STAGE = 1546820558950371413
out = []
for l in open(os.path.join(ui, 'chat.jsonl')):
    o = json.loads(l)
    e = o.get('etf') or {}
    t = e.get('t')
    if isinstance(t, dict) and t.get('$atom') == 'READY':
        d = e['d']
        me = d['user']['id']
        others = [u['id'] for u in d.get('users', []) if u['id'] != me]
        g = d['guilds'][0]
        cat = next(c['id'] for c in g['channels'] if c['type'] == 4 and c['name'] == 'Voice Channels')
        g['channels'] += [
            {'flags': 0, 'id': LIMITED, 'name': 'Duos', 'parent_id': cat, 'permission_overwrites': [], 'position': 1, 'type': 2, 'user_limit': 5, 'bitrate': 64000},
            {'flags': 0, 'id': STAGE, 'name': 'Town Hall', 'parent_id': cat, 'permission_overwrites': [], 'position': 2, 'type': 13, 'user_limit': 0, 'bitrate': 64000},
        ]
        extra = {1000000000020971531: 'Sam', 1000000000020971532: 'Avery', 1000000000020971533: 'Jules'}
        d['users'] += [{'id': i, 'username': n.lower(), 'global_name': n, 'avatar': None, 'discriminator': '0'} for i, n in extra.items()]
        def vs(uid, ch=VOICE, **kw):
            v = {'user_id': uid, 'channel_id': ch, 'session_id': 's%d' % uid, 'self_mute': False, 'self_deaf': False,
                 'mute': False, 'deaf': False, 'self_video': False, 'suppress': False}
            v.update(kw)
            return v
        a, b, c = extra
        g['voice_states'] = [vs(me, mute=True),vs(others[0], self_stream=True), vs(others[1], self_mute=True), vs(1000000000020971521),
                             vs(a, LIMITED), vs(b, STAGE), vs(c, STAGE, suppress=True, request_to_speak_timestamp='2026-10-29T08:00:00.000000+00:00')]
    out.append(json.dumps(o))
open(os.path.join(here, 'call.jsonl'), 'w').write('\n'.join(out) + '\n')
