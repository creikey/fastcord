# Builds tests/ui/media/media.jsonl (chat.jsonl's READY plus an FxTwitter video embed, a GIF attachment and a Klipy GIFV embed, shaped
# like traffic/gif_send.jsonl) and its media: dance.gif, poster.webp (a PNG; files are sniffed), clip.mp4 is
# tests/ui/attach/clip.mp4. The UI scripts here run with FASTCORD_MEDIA_DIR=tests/ui/media.
# Run: python3 -I tests/ui/media/make_media_fixture.py
import base64, json, math, os, shutil, struct, zlib
here = os.path.dirname(os.path.abspath(__file__))
head = open(os.path.join(here, '..', 'chat.jsonl'), encoding='utf-8').readlines()[:2]
CH, GUILD = 1546820603343016006, 1546820558300258304
EPOCH, base_ms = 1420070400000, 1793000000000
def sf(ms, n): return ((ms - EPOCH) << 22) | n
me = {'id': 1546819257420087346, 'username': 'dingus', 'global_name': 'Dingus Battle', 'avatar': None, 'discriminator': '0'}
gif_id, gif_msg, gifv_msg = sf(base_ms, 2), sf(base_ms, 1), sf(base_ms + 5000, 3)
Q = '?ex=6ae09da0&is=6adf4c20&hm=00&'
def msg(mid, content, attachments, embeds):
    return {'rt': 0, 'dir': 'recv', 'etf': {'op': 0, 't': 'MESSAGE_CREATE', 's': 100, 'd': {
        'id': mid, 'channel_id': CH, 'guild_id': GUILD, 'author': me, 'content': content, 'timestamp': '', 'edited_timestamp': None,
        'type': 0, 'attachments': attachments, 'embeds': embeds, 'mentions': [], 'mention_everyone': False, 'flags': 0, 'tts': False, 'pinned': False}}}
att = {'id': gif_id, 'filename': 'dance.gif', 'size': 4000, 'content_type': 'image/gif', 'width': 160, 'height': 120, 'description': 'a dancing cat',
       'url': 'https://cdn.discordapp.com/attachments/%d/%d/dance.gif%s' % (CH, gif_id, Q),
       'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/dance.gif%s' % (CH, gif_id, Q)}
KLIPY = 'https://static.klipy.com/ii/f87f46a2c5aeaeed4c68910815f73eaf/84/09/'
EXT = 'https://images-ext-1.discordapp.net/external/x/https/static.klipy.com/ii/f87f46a2c5aeaeed4c68910815f73eaf/84/09/'
gifv = {'type': 'gifv', 'url': 'https://klipy.com/gifs/goat-banjo', 'title': 'Goat banjo', 'provider': {'name': 'Klipy', 'url': 'https://klipy.com'},
        'thumbnail': {'url': KLIPY + 'poster.webp', 'proxy_url': EXT + 'poster.webp', 'width': 320, 'height': 180, 'flags': 0},
        'video': {'url': KLIPY + 'clip.mp4', 'proxy_url': EXT + 'clip.mp4', 'width': 320, 'height': 180, 'flags': 0}}
# an FxTwitter video embed (oldest, above the GIFs): masked links and a quote in the description, the
# video proxied, so it plays in the card
FX = 'https://images-ext-1.discordapp.net/external/y/https/video.twimg.com/ext_tw_video/1/'
TW = 'https://x.com/jaybronious/status/2115114109049967088'
fx_msg = sf(base_ms - 5000, 4)
fx = {'type': 'video', 'url': TW, 'color': 6513919, 'author': {'name': 'Jay (@jaybronious)', 'url': TW},
      'description': 'Holy shit. Watch her face change here [#elizabethholmes](https://x.com/hashtag/elizabethholmes)\n\n'
                     '> **[Quoting](https://x.com/jaybronious/status/2112312139595538770) Jay ([@jaybronious](https://x.com/jaybronious)\\)**\n> \n'
                     '> Watch how her stare changes midway during this clip. [#elizabethholmes](https://x.com/hashtag/elizabethholmes)\n\n'
                     '**[💬](https://x.com/intent/tweet?in_reply_to=2115114109049967088) 169 [🔁](https://x.com/intent/retweet?tweet_id=2115114109049967088) 161**',
      'thumbnail': {'url': 'https://pbs.twimg.com/poster.webp', 'proxy_url': FX + 'poster.webp', 'width': 640, 'height': 360, 'flags': 0},
      'video': {'url': 'https://video.twimg.com/clip.mp4', 'proxy_url': FX + 'clip.mp4', 'width': 640, 'height': 360, 'flags': 0}}
# older still: a link card with a tall side thumbnail (IMDb), a YouTube video (no proxied video: a large
# poster that opens the link) and a post whose 4 images arrive as 4 embeds sharing its url (one grid)
IMG = 'https://images-ext-1.discordapp.net/external/z/https/'
imdb = {'type': 'link', 'url': 'https://www.imdb.com/title/tt1231583/', 'title': 'Due Date (2010) ⭐ 6.5 | Comedy, Drama',
        'description': '1h 35m | R', 'provider': {'name': 'IMDb'},
        'thumbnail': {'url': 'https://m.media-amazon.com/poster.webp', 'proxy_url': IMG + 'imdb/poster.webp', 'width': 182, 'height': 268, 'flags': 0}}
yt = {'type': 'video', 'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'title': 'A video', 'color': 16711680,
      'provider': {'name': 'YouTube', 'url': 'https://www.youtube.com'}, 'author': {'name': 'A channel'},
      'thumbnail': {'url': 'https://i.ytimg.com/vi/x/hqdefault.jpg', 'proxy_url': IMG + 'yt/poster.webp', 'width': 480, 'height': 360, 'flags': 0},
      'video': {'url': 'https://www.youtube.com/embed/dQw4w9WgXcQ', 'width': 1280, 'height': 720, 'flags': 0}}
POST = 'https://x.com/someone/status/1'
grid = [dict({'type': 'rich', 'url': POST, 'image': {'url': 'https://pbs.twimg.com/%d/poster.webp' % k, 'proxy_url': IMG + '%d/poster.webp' % k, 'width': 640, 'height': 360, 'flags': 0}},
             **({'description': 'Four images', 'author': {'name': 'Someone (@someone)'}} if k == 0 else {})) for k in range(4)]
# a plain file: a card with the name and a download button
note = {'id': sf(base_ms - 20000, 9), 'filename': 'notes.txt', 'size': 416, 'content_type': 'text/plain; charset=utf-8',
        'url': 'https://cdn.discordapp.com/attachments/%d/%d/notes.txt%s' % (CH, sf(base_ms - 20000, 9), Q),
        'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/notes.txt%s' % (CH, sf(base_ms - 20000, 9), Q)}
# a spoilered image: covered until clicked
spoiler = {'id': sf(base_ms - 15000, 9), 'filename': 'SPOILER_poster.webp', 'size': 2000, 'content_type': 'image/webp', 'width': 320, 'height': 180,
           'url': 'https://cdn.discordapp.com/attachments/%d/%d/poster.webp%s' % (CH, sf(base_ms - 15000, 9), Q),
           'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/poster.webp%s' % (CH, sf(base_ms - 15000, 9), Q)}
spoiler_file = {'id': sf(base_ms - 15000, 10), 'filename': 'SPOILER_notes.txt', 'size': 416, 'content_type': 'text/plain; charset=utf-8',
                'url': 'https://cdn.discordapp.com/attachments/%d/%d/SPOILER_notes.txt%s' % (CH, sf(base_ms - 15000, 10), Q),
                'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/SPOILER_notes.txt%s' % (CH, sf(base_ms - 15000, 10), Q)}
# a voice message: waveform bars and the length instead of a file name
wave = bytes(int(127 + 120 * math.sin(i / 5.0) * math.sin(i / 37.0)) for i in range(256))
voice = {'id': sf(base_ms - 25000, 9), 'filename': 'voice-message.ogg', 'size': 30000, 'content_type': 'audio/ogg',
         'duration_secs': 14.2, 'waveform': base64.b64encode(wave).decode(),
         'url': 'https://cdn.discordapp.com/attachments/%d/%d/voice-message.ogg%s' % (CH, sf(base_ms - 25000, 9), Q),
         'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/voice-message.ogg%s' % (CH, sf(base_ms - 25000, 9), Q)}
voice_msg = msg(sf(base_ms - 25000, 8), '', [voice], [])
voice_msg['etf']['d']['flags'] = 8192
old_msgs = [voice_msg,
            msg(sf(base_ms - 20000, 5), 'https://www.imdb.com/title/tt1231583/', [note], [imdb]),
            msg(sf(base_ms - 15000, 6), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', [spoiler, spoiler_file], [yt]),
            msg(sf(base_ms - 10000, 7), POST, [], grid)]
# the grid post is Robin's: as the server's owner (MANAGE_MESSAGES) you may still remove its embeds
old_msgs[-1]['etf']['d']['author'] = {'id': 1000000000020971521, 'username': 'robin', 'global_name': 'Robin', 'avatar': None, 'discriminator': '0'}
with open(os.path.join(here, 'media.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    f.writelines(head)
    for o in (*old_msgs, msg(fx_msg, TW, [], [fx]), msg(gif_msg, '', [att], []), msg(gifv_msg, 'https://klipy.com/gifs/goat-banjo', [], [gifv])):
        f.write(json.dumps(o, ensure_ascii=False) + '\n')

# dance.gif: 80x60, 4 frames of moving stripes (uncompressed LZW: 9-bit literals, clear every 254 codes)
def gif(w, h, frames):
    pal = bytes(c for i in range(256) for c in ((i * 37) & 0xff, (i * 91) & 0xff, (i * 151) & 0xff))
    out = bytearray(b'GIF89a' + struct.pack('<HHBBB', w, h, 0xf7, 0, 0) + pal + b'\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00')
    for fr in range(frames):
        codes = []
        for i, p in enumerate(((x + fr * 20) // 20 * 40) & 0xff for y in range(h) for x in range(w)):
            if i % 254 == 0: codes.append(256)
            codes.append(p)
        codes.append(257)
        data, bits, n = bytearray(), 0, 0
        for c in codes:
            bits |= c << n; n += 9
            while n >= 8: data.append(bits & 0xff); bits >>= 8; n -= 8
        if n: data.append(bits & 0xff)
        out += b'\x21\xf9\x04\x04\x0a\x00\x00\x00\x2c' + struct.pack('<HHHHB', 0, 0, w, h, 0) + b'\x08'
        out += b''.join(bytes([len(data[i:i + 255])]) + bytes(data[i:i + 255]) for i in range(0, len(data), 255)) + b'\x00'
    return bytes(out + b'\x3b')
open(os.path.join(here, 'dance.gif'), 'wb').write(gif(80, 60, 4))

def png(w, h):
    rows = b''.join(b'\x00' + b''.join(bytes((x * 255 // w, y * 255 // h, 160, 255)) for x in range(w)) for y in range(h))
    def chunk(k, d): return struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
open(os.path.join(here, 'poster.webp'), 'wb').write(png(64, 36))
shutil.copyfile(os.path.join(here, '..', 'attach', 'clip.mp4'), os.path.join(here, 'clip.mp4'))
