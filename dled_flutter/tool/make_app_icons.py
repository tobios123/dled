"""make_app_icons.py -- DLED's "D" icon (tool/make_light_icons.py) for every
platform of the app: Android launcher icons, the web icons and favicon, the
iOS / macOS app icon sets and the Windows .ico.

    python tool/make_app_icons.py

Every PNG is drawn again at its own size (read from the file), so the sets
keep the sizes Flutter made. iOS gets square corners: iOS rounds app icons
itself and does not accept transparency. Plain Python, no image library.
"""
import importlib.util
import struct
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("light_icons", APP / "tool" / "make_light_icons.py")
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)

_rounded = icons.colour_at


def _square(x, y):
    """The same drawing without the rounded corners (iOS)."""
    c = _rounded(x, y)
    if c[3] == 0:  # a corner: the page grey instead of transparent
        return icons.GREY + (255,)
    return c


def png_size(path):
    data = path.read_bytes()
    w, h = struct.unpack(">II", data[16:24])
    return w, h


def draw(size, square=False):
    icons.colour_at = _square if square else _rounded
    try:
        return icons.png(size)
    finally:
        icons.colour_at = _rounded


def ico(sizes):
    """A Windows .ico holding PNG images of [sizes]."""
    images = [draw(s) for s in sizes]
    head = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for s, img in zip(sizes, images):
        entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    return head + entries + b"".join(images)


def main():
    pngs = [
        *sorted(APP.glob("android/app/src/main/res/mipmap-*/ic_launcher.png")),
        APP / "web" / "favicon.png",
        *sorted(APP.glob("web/icons/*.png")),
        *sorted(APP.glob("ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png")),
        *sorted(APP.glob("macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png")),
    ]
    for p in pngs:
        if not p.exists():
            continue
        w, _ = png_size(p)
        p.write_bytes(draw(w, square="/ios/" in p.as_posix()))
        print(f"{p.relative_to(APP).as_posix()}  {w}px")
    ico_path = APP / "windows" / "runner" / "resources" / "app_icon.ico"
    ico_path.write_bytes(ico([16, 24, 32, 48, 64, 256]))
    print(ico_path.relative_to(APP).as_posix())


if __name__ == "__main__":
    main()
