# Release smoke test (ci-build.yml, release.yml): fails unless the headless screenshot a shipped binary wrote
# exists and isn't blank (a frame that drew nothing has a handful of colours; the fixture's chat has thousands).
#   python3 -I tools/smoke_check.py <shot.png>
import struct, sys, zlib

path = sys.argv[1]
try:
    data = open(path, 'rb').read()
except OSError:
    sys.exit(f'smoke: {path} was not written (the app crashed or failed to start)')
if data[:8] != b'\x89PNG\r\n\x1a\n': sys.exit(f'smoke: {path} is not a PNG')
idat, i = b'', 8
while i + 8 <= len(data):
    n, kind = struct.unpack('>I4s', data[i:i + 8])
    if kind == b'IDAT': idat += data[i + 8:i + 8 + n]
    i += 12 + n
pixels = zlib.decompress(idat)
colours = len({pixels[j:j + 4] for j in range(0, len(pixels) - 4, 4)})
print(f'smoke: {path}: {len(pixels)} bytes, {colours} distinct values')
if colours < 64: sys.exit('smoke: the frame is blank')
