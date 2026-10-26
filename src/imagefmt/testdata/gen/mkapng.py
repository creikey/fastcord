# mkapng.py out.png : hand-built APNG exercising blend OVER, dispose PREVIOUS/BACKGROUND, sub-rects, hidden default image.
import sys, zlib, struct, random
W, H = 64, 48
r = random.Random(5)
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
def img(w, h, f):
    raw = b''.join(b'\0' + bytes(v for x in range(w) for v in f(x, y)) for y in range(h))
    return zlib.compress(raw, 9)
seq = [0]
def fctl(w, h, x, y, num, den, dispose, blend):
    d = struct.pack('>IIIIIHHBB', seq[0], w, h, x, y, num, den, dispose, blend); seq[0] += 1; return chunk(b'fcTL', d)
def fdat(z):
    d = struct.pack('>I', seq[0]) + z; seq[0] += 1; return chunk(b'fdAT', d)
out = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)) + chunk(b'acTL', struct.pack('>II', 5, 3))
out += chunk(b'IDAT', img(W, H, lambda x, y: (255, 0, 0, 255)))  # hidden default image (no fcTL before it)
frames = [
    (W, H, 0, 0, 1, 10, 0, 0, lambda x, y: (x * 4, y * 5, 128, 200 if (x + y) % 7 else 0)),
    (30, 20, 5, 6, 3, 100, 2, 1, lambda x, y: (255, 255, 0, (x * 8) & 255)),
    (20, 30, 30, 10, 0, 0, 1, 1, lambda x, y: (0, 200, 255, 120)),
    (40, 30, 10, 10, 5, 0, 0, 1, lambda x, y: (r.randrange(256), r.randrange(256), r.randrange(256), r.randrange(256))),
    (64, 48, 0, 0, 20, 1000, 0, 1, lambda x, y: (10, 20, 30, 60)),
]
for w, h, x, y, num, den, disp, blend, f in frames:
    out += fctl(w, h, x, y, num, den, disp, blend) + fdat(img(w, h, f))
out += chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(out)
