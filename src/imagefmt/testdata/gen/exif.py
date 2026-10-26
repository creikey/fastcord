# exif.py in.jpg out.jpg orientation [be]: insert an APP1 Exif segment with the Orientation tag.
import sys, struct
d = open(sys.argv[1], 'rb').read(); o = int(sys.argv[3]); be = len(sys.argv) > 4
E = '>' if be else '<'
tiff = (b'MM\x00\x2a' if be else b'II\x2a\x00') + struct.pack(E + 'I', 8)
tiff += struct.pack(E + 'H', 2)
tiff += struct.pack(E + 'HHI', 0x010F, 2, 4) + b'abc\x00'          # Make (ASCII, inline)
tiff += struct.pack(E + 'HHIHH', 0x0112, 3, 1, o, 0)               # Orientation
tiff += struct.pack(E + 'I', 0)
seg = b'Exif\x00\x00' + tiff
open(sys.argv[2], 'wb').write(d[:2] + b'\xff\xe1' + struct.pack('>H', len(seg) + 2) + seg + d[2:])
