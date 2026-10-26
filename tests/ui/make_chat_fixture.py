# Builds tests/ui/chat.jsonl: the scrubbed READY from src/discord/testdata plus
# synthetic messages covering grouping, markdown, mentions, code and reactions.
# Run: python3 -I tests/ui/make_chat_fixture.py
import json, os
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '..', '..', 'src', 'discord', 'testdata', 'gw_a.jsonl')
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
wumpus = {'id': 1000000000020971521, 'username': 'wumpus', 'global_name': 'Wumpus', 'avatar': None, 'discriminator': '0'}
meu = {'id': me, 'username': 'dingus', 'global_name': 'Dingus Battle', 'avatar': None, 'discriminator': '0'}
msgs = [
    (wumpus, 0, 'hey! welcome to **fastcord** testing'),
    (wumpus, 20, 'this message should group with the one above'),
    (meu, 60, 'nice. here is some `inline code` and a link https://discord.com/developers'),
    (meu, 90, 'multi-line\nmessage with *italic*, __underline__, ~~strike~~ and ||a spoiler||'),
    (wumpus, 600, '> quoted text\nreply below the quote <@%d>' % (me or 0)),
    (wumpus, 640, '```odin\nmain :: proc() {\n\tfmt.println("hellope")\n}\n```'),
    (meu, 1200, '# Heading one\nsome text after a heading\n- list item one\n- list item two\n-# subtext line'),
    (wumpus, 1260, 'a long message that should wrap across multiple lines in the chat view because it keeps going and going with plenty of words so that the wrapping logic is exercised properly at typical window widths 🎉'),
    (meu, 1300, '👍'),
]
# chat_emoji.jsonl adds Twemoji / sticker messages (kept out of chat.jsonl so the
# coordinate-based UI scripts keep their layout). Offline media for it:
# FASTCORD_MEDIA_DIR with the twemoji svgs / sticker files (see src/app/emoji.odin).
emoji_msgs = [
    (wumpus, 1320, 'emoji inline: hi 😀 there 👍🏽 family 👨\u200d👩\u200d👧\u200d👦 flag 🇯🇵 keycap 1\ufe0f\u20e3 heart ❤️ and ™ stays text'),
    (wumpus, 1330, '**bold 🔥** and `code 😀 stays text`'),
    (meu, 1340, '😂🎉👀'),
    (wumpus, 1350, ''),
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
  out.append(ev('THREAD_CREATE', {'id': starter, 'guild_id': GUILD, 'parent_id': CH, 'type': 11, 'name': 'wrapping discussion', 'owner_id': wumpus['id'],
      'message_count': 0, 'member_count': 2, 'thread_metadata': meta(), 'member': {'id': starter, 'user_id': me, 'flags': 1, 'join_timestamp': '2026-10-25T00:21:00+00:00'}, 'last_message_id': None}))
  for k, (u, txt) in enumerate([(wumpus, 'does the wrap look right to you?'), (meu, 'yes, matches the client'), (wumpus, 'great 🎉')]):
    out.append(ev('MESSAGE_CREATE', {'id': sf(base_ms + 1270 * 1000 + k * 10000, 40 + k), 'channel_id': starter, 'guild_id': GUILD, 'author': u, 'content': txt, 'timestamp': '', 'edited_timestamp': None,
      'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
  out.append(ev('CHANNEL_CREATE', {'id': FORUM, 'guild_id': GUILD, 'type': 15, 'name': 'feedback', 'position': 1, 'parent_id': None, 'topic': 'Ideas and bug reports',
      'available_tags': [{'id': 1, 'name': 'Bug', 'emoji_name': '🐛', 'emoji_id': None, 'moderated': False}, {'id': 2, 'name': 'Idea', 'emoji_name': '💡', 'emoji_id': None, 'moderated': False}]}))
  posts = [('Scrolling stutters on long channels', [1], wumpus, 'When I scroll fast through a big channel the frame rate drops.', 7, 1100),
           ('Add a compact mode', [2], meu, 'Would love the compact message layout from the official client.', 2, 1200),
           ('Emoji picker search', [2, 1], wumpus, 'Searching :thumbs in the picker should show skin tones.', 0, 1300)]
  for k, (title, tags, u, body, count, dt) in enumerate(posts):
    tid = sf(base_ms + dt * 1000, 60 + k)
    out.append(ev('THREAD_CREATE', {'id': tid, 'guild_id': GUILD, 'parent_id': FORUM, 'type': 11, 'name': title, 'owner_id': u['id'], 'applied_tags': tags,
        'message_count': count, 'member_count': 1, 'thread_metadata': meta(), 'last_message_id': None}))
    out.append(ev('MESSAGE_CREATE', {'id': tid, 'channel_id': tid, 'guild_id': GUILD, 'author': u, 'content': body, 'timestamp': '', 'edited_timestamp': None,
      'type': 0, 'attachments': [], 'embeds': [], 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}))
  return out
for name, ms in (('chat.jsonl', msgs), ('chat_emoji.jsonl', msgs + emoji_msgs), ('chat_threads.jsonl', msgs)):
  out = build(ms)
  if name == 'chat_threads.jsonl': out += threads_extra(ms)
  with open(os.path.join(here, name), 'w') as f:
    for o in out: f.write(json.dumps(o, ensure_ascii=False) + '\n')
  print('wrote', name, len(out), 'lines')
