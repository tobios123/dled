"""make_light_icons.py -- the light page's home-screen icons (light/src/icon-*.png).

    python tool/make_light_icons.py

The app's look: the page grey with rounded corners, the solid cyan "D" of
the logo with a white dot (a lamp) in a hole in its middle. Drawn pixel by pixel
with 4x4 supersampling; plain Python (zlib), no image library.
"""
import math
import struct
import zlib
from pathlib import Path

GREY = (0x2B, 0x2B, 0x2F)
CYAN = (0x29, 0xB6, 0xF6)
WHITE = (0xFF, 0xFF, 0xFF)


def colour_at(x, y):
    """(r, g, b, a) at x, y in 0..1."""
    # rounded square (corner radius 0.22)
    r = 0.22
    cx, cy = min(max(x, r), 1 - r), min(max(y, r), 1 - r)
    if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
        return (0, 0, 0, 0)
    # the D of the logo (lib/widgets/dled_logo.dart): 14.5 x 16 units, a
    # straight left side and a half circle to the right, with a hole at
    # (6.5, 8) and the white dot in it; 0.6 of the icon high, centred
    k = 0.6 / 16
    u, v = (x - (1 - 14.5 * k) / 2) / k, (y - 0.2) / k
    if 0 <= v <= 16 and u >= 0:
        d = math.hypot(u - 6.5, v - 8)
        if u <= 6.5 or d <= 8:
            if d < 1.7:
                return WHITE + (255,)
            if d >= 2.6:
                return CYAN + (255,)
    return GREY + (255,)


def png(size):
    rows = []
    n = 4  # supersampling
    for py in range(size):
        row = bytearray([0])  # filter: none
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(n):
                for sx in range(n):
                    c = colour_at((px + (sx + 0.5) / n) / size, (py + (sy + 0.5) / n) / size)
                    for i in range(3):
                        acc[i] += c[i] * c[3]
                    acc[3] += c[3]
            a = acc[3] / (n * n)
            rgb = [round(acc[i] / acc[3]) if acc[3] else 0 for i in range(3)]
            row += bytes(rgb + [round(a)])
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    head = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', head) + chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
            + chunk(b'IEND', b''))


if __name__ == '__main__':
    out = Path(__file__).resolve().parent.parent / 'light' / 'src'
    for size in (192, 512):
        (out / f'icon-{size}.png').write_bytes(png(size))
        print(f'light/src/icon-{size}.png')
