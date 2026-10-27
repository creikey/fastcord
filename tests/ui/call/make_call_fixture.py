# Builds tests/ui/call/call.jsonl: chat.jsonl with four people in the General voice
# channel (one live on Go Live, one muted), for the call view.
# Run: python3 -I tests/ui/call/make_call_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
ui = os.path.dirname(here)
VOICE = 1546820558950371411
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
        def vs(uid, **kw):
            v = {'user_id': uid, 'channel_id': VOICE, 'session_id': 's%d' % uid, 'self_mute': False, 'self_deaf': False,
                 'mute': False, 'deaf': False, 'self_video': False, 'suppress': False}
            v.update(kw)
            return v
        g['voice_states'] = [vs(me), vs(others[0], self_stream=True), vs(others[1], self_mute=True), vs(1000000000020971521)]
    out.append(json.dumps(o))
open(os.path.join(here, 'call.jsonl'), 'w').write('\n'.join(out) + '\n')
