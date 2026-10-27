# Builds tests/ui/media/media.jsonl (chat.jsonl's READY plus a GIF attachment and a Klipy GIFV embed, shaped
# like traffic/gif_send.jsonl) and its media: dance.gif, poster.webp (a PNG; files are sniffed), clip.mp4 is
# tests/ui/attach/clip.mp4. The UI scripts here run with FASTCORD_MEDIA_DIR=tests/ui/media.
# Run: python3 -I tests/ui/media/make_media_fixture.py
import json, os, shutil, struct, zlib
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
att = {'id': gif_id, 'filename': 'dance.gif', 'size': 4000, 'content_type': 'image/gif', 'width': 160, 'height': 120,
       'url': 'https://cdn.discordapp.com/attachments/%d/%d/dance.gif%s' % (CH, gif_id, Q),
       'proxy_url': 'https://media.discordapp.net/attachments/%d/%d/dance.gif%s' % (CH, gif_id, Q)}
KLIPY = 'https://static.klipy.com/ii/f87f46a2c5aeaeed4c68910815f73eaf/84/09/'
EXT = 'https://images-ext-1.discordapp.net/external/x/https/static.klipy.com/ii/f87f46a2c5aeaeed4c68910815f73eaf/84/09/'
gifv = {'type': 'gifv', 'url': 'https://klipy.com/gifs/goat-banjo', 'title': 'Goat banjo', 'provider': {'name': 'Klipy', 'url': 'https://klipy.com'},
        'thumbnail': {'url': KLIPY + 'poster.webp', 'proxy_url': EXT + 'poster.webp', 'width': 320, 'height': 180, 'flags': 0},
        'video': {'url': KLIPY + 'clip.mp4', 'proxy_url': EXT + 'clip.mp4', 'width': 320, 'height': 180, 'flags': 0}}
with open(os.path.join(here, 'media.jsonl'), 'w', encoding='utf-8', newline='\n') as f:
    f.writelines(head)
    for o in (msg(gif_msg, '', [att], []), msg(gifv_msg, 'https://klipy.com/gifs/goat-banjo', [], [gifv])):
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
