# Builds tests/ui/chat.jsonl: the scrubbed READY in tests/data plus
# synthetic messages covering grouping, markdown, mentions, code and reactions.
# Run: python3 -I tests/ui/make_chat_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '..', 'data', 'gw_a.jsonl')
out = []
me = None
for l in open(src):
    o = json.loads(l)
    e = o.get('etf') or {}
    t = e.get('t')
    name = t.get('$atom') if isinstance(t, dict) else t
    if o.get('dir') == 'recv' and e.get('op') == 0 and name in ('READY', 'READY_SUPPLEMENTAL'):
        out.append(o)
        if name == 'READY':
            me = e['d']['user']['id']
CH = 1546820603343016006
GUILD = 1546820558300258304
EPOCH = 1420070400000
base_ms = 1793000000000  # 2026-10-25
def sf(ms, n): return ((ms - EPOCH) << 22) | n
robin = {'id': 1000000000020971521, 'username': 'robin', 'global_name': 'Robin', 'avatar': None, 'discriminator': '0'}
meu = {'id': me, 'username': 'dingus', 'global_name': 'Dingus Battle', 'avatar': None, 'discriminator': '0'}
msgs = [
    (robin, 0, 'hey! welcome to **fastcord** testing'),
    (robin, 20, 'this message should group with the one above'),
    (meu, 60, 'nice. here is some `inline code` and a link https://discord.com/developers'),
    (meu, 90, 'multi-line\nmessage with *italic*, __underline__, ~~strike~~ and ||a spoiler||'),
    (robin, 600, '> quoted text\nreply below the quote <@%d>' % (me or 0)),
    (robin, 640, '```odin\nmain :: proc() {\n\tfmt.println("hellope")\n}\n```'),
    (meu, 1200, '# Heading one\nsome text after a heading\n- list item one\n- list item two\n-# subtext line'),
    (robin, 1260, 'a long message that should wrap across multiple lines in the chat view because it keeps going and going with plenty of words so that the wrapping logic is exercised properly at typical window widths 🎉'),
    (meu, 1300, '👍'),
]
# chat_emoji.jsonl adds Twemoji / sticker messages (kept out of chat.jsonl so the
# coordinate-based UI scripts keep their layout). Offline media for it:
# tests/ui/emoji/media (FASTCORD_MEDIA_DIR for tests/ui/emoji scripts): the Twemoji
# svgs they show, as served from discord.com/assets (Twemoji, CC-BY 4.0).
emoji_msgs = [
    (robin, 1320, 'emoji inline: hi 😀 there 👍🏽 family 👨\u200d👩\u200d👧\u200d👦 flag 🇯🇵 keycap 1\ufe0f\u20e3 heart ❤️ and ™ stays text'),
    (robin, 1330, '**bold 🔥** and `code 😀 stays text`'),
    (meu, 1340, '😂🎉👀'),
    (robin, 1350, ''),
    (meu, 1360, ''),
]
# messages with stickers (index -> sticker_items); standard stickers from the client bundle
STICKERS = {
    12: [{'id': 749054660769218631, 'name': 'Wave', 'format_type': 3}],
    13: [{'id': 781291131828699156, 'name': 'Wave', 'format_type': 2}],
}
base_out = list(out)
def build(msgs):
  out = list(base_out)
  for i, (u, dt, content) in enumerate(msgs):
      mid = sf(base_ms + dt * 1000, i)
      d = {'id': mid, 'channel_id': CH, 'guild_id': GUILD, 'author': u, 'content': content, 'timestamp': '', 'edited_timestamp': None,
           'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}
      if i in STICKERS:
          d['sticker_items'] = STICKERS[i]
      if i == 10:
          d['reactions'] = [{'emoji': {'id': None, 'name': '👍🏽'}, 'count': 1, 'me': False, 'burst_count': 0, 'me_burst': False},
                            {'emoji': {'id': None, 'name': '❤️'}, 'count': 3, 'me': True, 'burst_count': 0, 'me_burst': False}]
      if i == 2:
          d['reactions'] = [{'emoji': {'id': None, 'name': '👍'}, 'count': 2, 'me': True, 'burst_count': 0, 'me_burst': False},
                            {'emoji': {'id': None, 'name': '🔥'}, 'count': 1, 'me': False, 'burst_count': 0, 'me_burst': False}]
      out.append({'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': 'MESSAGE_CREATE', 's': 100 + i, 'd': d}})
  return out
def ev(t, d, seq=500):
  return {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': t, 's': seq, 'd': d}}
# chat_threads.jsonl: a thread started from a message (sidebar row + summary
# pill), messages inside it, and a forum channel with tagged posts.
FORUM = 1546820603343016100
def threads_extra(base_msgs):
  out = []
  starter = sf(base_ms + 1260 * 1000, 7)  # the long message starts a thread
  meta = lambda: {'archived': False, 'locked': False, 'auto_archive_duration': 1440, 'archive_timestamp': '2026-10-25T00:00:00+00:00', 'create_timestamp': '2026-10-25T00:20:00+00:00'}
  out.append(ev('THREAD_CREATE', {'id': starter, 'guild_id': GUILD, 'parent_id': CH, 'type': 11, 'name': 'wrapping discussion', 'owner_id': robin['id'],
      'message_count': 0, 'member_count': 2, 'thread_metadata': meta(), 'member': {'id': starter, 'user_id': me, 'flags': 1, 'join_timestamp': '2026-10-25T00:21:00+00:00'}, 'last_message_id': None}))
  for k, (u, txt) in enumerate([(robin, 'does the wrap look right to you?'), (meu, 'yes, matches the client'), (robin, 'great 🎉')]):
    out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 1270 * 1000 + k * 10000, 40 + k), 'channel_id': starter, 'guild_id': GUILD, 'author': u, 'content': txt, 'timestamp': '', 'edited_timestamp': None,
      'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
  out.append(ev('CHANNEL_CREATE', {'id': FORUM, 'guild_id': GUILD, 'type': 15, 'name': 'feedback', 'position': 1, 'parent_id': None, 'topic': 'Ideas and bug reports',
      'available_tags': [{'id': 1, 'name': 'Bug', 'emoji_name': '🐛', 'emoji_id': None, 'moderated': False}, {'id': 2, 'name': 'Idea', 'emoji_name': '💡', 'emoji_id': None, 'moderated': False}]}))
  posts = [('Scrolling stutters on long channels', [1], robin, 'When I scroll fast through a big channel the frame rate drops.', 7, 1100),
           ('Add a compact mode', [2], meu, 'Would love the compact message layout from the official client.', 2, 1200),
           ('Emoji picker search', [2, 1], robin, 'Searching :thumbs in the picker should show skin tones.', 0, 1300)]
  for k, (title, tags, u, body, count, dt) in enumerate(posts):
    tid = sf(base_ms + dt * 1000, 60 + k)
    out.append(ev('THREAD_CREATE', {'id': tid, 'guild_id': GUILD, 'parent_id': FORUM, 'type': 11, 'name': title, 'owner_id': u['id'], 'applied_tags': tags,
        'message_count': count, 'member_count': 1, 'thread_metadata': meta(), 'last_message_id': None}))
    out.append(ev('MESSAGE_CREATE', {'id': tid, 'channel_id': tid, 'guild_id': GUILD, 'author': u, 'content': body, 'timestamp': '', 'edited_timestamp': None,
      'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
  # scheduled events (Events modal): one live in the voice channel, one upcoming elsewhere
  out.append(ev('GUILD_SCHEDULED_EVENT_CREATE', {'id': 1546820603343016200, 'guild_id': GUILD, 'channel_id': 1546820558950371411, 'creator_id': me,
      'name': 'Friday game night', 'description': 'Bring snacks.', 'scheduled_start_time': '2026-10-25T23:00:00+00:00', 'scheduled_end_time': None,
      'privacy_level': 2, 'status': 2, 'entity_type': 2, 'entity_id': None, 'entity_metadata': None, 'user_count': 3}))
  out.append(ev('GUILD_SCHEDULED_EVENT_CREATE', {'id': 1546820603343016201, 'guild_id': GUILD, 'channel_id': None, 'creator_id': robin['id'],
      'name': 'fastcord release party', 'description': 'Celebrating the first public build. Everyone is welcome; we will demo the new client and take questions.',
      'scheduled_start_time': '2026-10-28T18:00:00+00:00', 'scheduled_end_time': '2026-10-28T20:00:00+00:00',
      'privacy_level': 2, 'status': 1, 'entity_type': 3, 'entity_id': None, 'entity_metadata': {'location': 'Robin HQ, San Francisco'}, 'user_count': 12}))
  return out
# code/code.jsonl: ``` blocks in several of the client's highlighted languages, an alias, an
# unknown language (plain), ANSI colours and a long numbered list (tests/ui/code scripts).
code_msgs = [
    (robin, 0, '```js\n// fetch a user\nasync function getUser(id) {\n  const res = await fetch(`/api/users/${id}`);\n  if (!res.ok) throw new Error("bad status: " + res.status);\n  return res.json(); /* parsed */\n}\n```'),
    (meu, 20, '```py\n@dataclass\nclass Point:\n    x: int = 0\n    def norm(self) -> float:\n        """Length."""\n        return (self.x ** 2) ** 0.5  # sqrt\n```'),
    (robin, 40, '```rust\n#[derive(Debug)]\nstruct Ping<\'a> { name: &\'a str }\nfn main() {\n    let n: u32 = 42;\n    println!("hi {} {}\\n", n, \'c\');\n}\n```'),
    (meu, 60, '```c\n#include <stdio.h>\nint main(void) {\n    printf("%d\\n", 0x1F); // hex\n    return NULL == 0;\n}\n```'),
    (robin, 80, '```json\n{"name": "fastcord", "stars": 42, "native": true, "deps": null}\n```'),
    (meu, 100, '```diff\n@@ -1,3 +1,3 @@\n context line\n-removed line\n+added line\n```'),
    (robin, 120, '```sh\n# list files\nls -la ~/src | grep "jai" && echo done\nfor f in *.txt; do cat "$f"; done\n```'),
    (meu, 140, '```whatever\nunknown language stays plain: if (x) { return 1; }\n```'),
    (robin, 160, '```ansi\n\u001b[1;31mred bold\u001b[0m and \u001b[32mgreen\u001b[0m and \u001b[4;34munderlined blue\u001b[0m\n```'),
    # more than 4 blocks: selection order must not wrap between them (tests/ui/code/select_list.txt)
    (meu, 180, '1. **one** first\n2. **two** second\n3. **three** third\n4. **four** fourth\n5. **five** fifth\n6. **six** sixth'),
]
# chat_forward.jsonl: a multi-line wrapped quote, a forwarded message (message_reference type 1
# with a snapshot) and enough newer messages, after a read marker, for the new-messages bar.
forward_msgs = [
    (robin, 1400, '> Mute/unmute sounds: you can keep them. The app doesn\'t ship Discord\'s sound files: it downloads them when it runs, the same way the official client does and the same way we handle the font and default avatars.\n> Nothing of Discord\'s is in the repo for them to take down.\nand a reply under the quote'),
    (robin, 1460, ''),
] + [(robin if k % 2 else meu, 1500 + k * 30, 'filler message %d to push the new line out of view' % k) for k in range(24)]
FORWARD_INDEX = len(msgs) + 1
def forward_extra(ms):
  m = build(ms)
  for o in m:
    d = o['etf']['d'] if o['etf'].get('t') == 'MESSAGE_CREATE' else None
    if d and d['id'] == sf(base_ms + ms[FORWARD_INDEX][1] * 1000, FORWARD_INDEX):
      d['message_reference'] = {'type': 1, 'channel_id': CH, 'guild_id': GUILD, 'message_id': sf(base_ms, 0)}
      d['message_snapshots'] = [{'message': {'type': 0, 'content': 'hey! welcome to **fastcord** testing', 'timestamp': '2026-10-25T00:00:00+00:00',
          'edited_timestamp': None, 'flags': 0, 'mentions': [], 'attachments': [], 'embeds': [], 'components': []}}]
  # read up to the quote: everything after it is new
  m.append(ev('MESSAGE_ACK', {'channel_id': CH, 'message_id': sf(base_ms + ms[len(msgs)][1] * 1000, len(msgs)), 'version': 1}))
  return m
for name, ms in (('chat.jsonl', msgs), ('chat_emoji.jsonl', msgs + emoji_msgs), ('chat_threads.jsonl', msgs), ('chat_forward.jsonl', msgs + forward_msgs), ('code/code.jsonl', code_msgs)):
  out = forward_extra(ms) if name == 'chat_forward.jsonl' else build(ms)
  if name == 'chat_threads.jsonl': out += threads_extra(ms)
  # a custom guild emoji for the composer autocomplete (image: tests/ui/emoji/media/<id>.webp, a PNG)
  if name == 'chat_emoji.jsonl': out.append(ev('GUILD_EMOJIS_UPDATE', {'guild_id': GUILD, 'emojis': [
      {'id': 1546820603343016300, 'name': 'fastdog', 'animated': False, 'available': True, 'require_colons': True, 'managed': False, 'roles': []}]}))
  with open(os.path.join(here, name), 'w') as f:
    for o in out: f.write(json.dumps(o, ensure_ascii=False) + '\n')
  print('wrote', name, len(out), 'lines')
