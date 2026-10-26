import sys
d = open(sys.argv[1], 'rb').read()
if d[:4] == b'DKIF':
    hl = int.from_bytes(d[6:8], 'little'); sz = int.from_bytes(d[hl:hl+4], 'little'); frame = d[hl+12:hl+12+sz]
else:
    frame = d
pad = b'\0' if len(frame) & 1 else b''
chunk = b'VP8 ' + len(frame).to_bytes(4, 'little') + frame + pad
open(sys.argv[2], 'wb').write(b'RIFF' + (4 + len(chunk)).to_bytes(4, 'little') + b'WEBP' + chunk)
