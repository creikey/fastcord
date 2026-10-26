# Locates the VP8/VP8L constant tables in libwebp by their first bytes and dumps
# them as JSON (input to vp8_tables.odin). Tails were checked against RFC 6386.
import json, sys
data = open(sys.argv[1] if len(sys.argv) > 1 else '/opt/homebrew/opt/webp/lib/libwebp.dylib', 'rb').read()
def find(pat, n, elem=1):
    i = data.find(bytes(pat)); raw = data[i:i + n * elem]
    return list(raw) if elem == 1 else [int.from_bytes(raw[k:k + 2], 'little') for k in range(0, len(raw), 2)]
t = {
    'bmodes': find([231, 120, 48, 89, 115, 113, 120, 152, 112], 900),
    'coef0': find([128] * 33 + [253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128], 1056),
    'coefup': find([255] * 33 + [176, 246, 255, 255], 1056),
    'dc': find([4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17], 128),
    'ac': find([4, 0, 5, 0, 6, 0, 7, 0, 8, 0, 9, 0, 10, 0, 11, 0, 12, 0, 13, 0], 128, 2),
    'plane': find([0x18, 0x07, 0x17, 0x19, 0x28, 0x06], 120),
}
json.dump(t, sys.stdout)
