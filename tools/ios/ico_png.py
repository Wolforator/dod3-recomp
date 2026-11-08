#!/usr/bin/env python3
"""The largest image of an .ico, as the PNG it holds (no Pillow needed).

    python3 tools/ios/ico_png.py src/res/app.ico out.png

tools/make_icon.py writes src/res/app.ico with PNG-compressed images; the iOS
package takes its icon from the 256 px one when Pillow is not there to draw
it afresh (tools/ios/package_ipa.sh).
"""
import struct
import sys

data = open(sys.argv[1], 'rb').read()
_, kind, count = struct.unpack_from('<HHH', data, 0)
if kind != 1:
    sys.exit('not an .ico')
best = None
for i in range(count):
    w, h, _, _, _, _, size, off = struct.unpack_from('<BBBBHHII', data, 6 + 16 * i)
    w = w or 256
    blob = data[off:off + size]
    if blob[:8] == b'\x89PNG\r\n\x1a\n' and (best is None or w > best[0]):
        best = (w, blob)
if not best:
    sys.exit('no PNG image in the .ico')
open(sys.argv[2], 'wb').write(best[1])
