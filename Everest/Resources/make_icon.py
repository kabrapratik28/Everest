#!/usr/bin/env python3
"""Turn the source logo art into .icns files for the app bundle.

Two renders of the same composition exist. Both are built, so the icon can be
swapped by editing one plist key instead of re-deriving anything:

    Artwork/icon-source.png      -> AppIcon.icns      (CFBundleIconFile: AppIcon)
    Artwork/icon-source-alt.png  -> AppIcon-alt.icns  (excluded from the bundle)

Both already have the macOS squircle drawn into the art, so the job is getting
a clean alpha onto it and re-padding to Apple's icon grid. The two differ in
how the alpha has to be obtained:

  - icon-source.png ships with transparent corners already. Its own alpha IS
    the mask; rebuilding one would only round off a curve that is already right.
  - icon-source-alt.png is opaque on a white margin. That needs cropping, and
    then the corners punched out at a MEASURED radius -- a tight rectangular
    crop leaves white triangles outside the curve, which show up as white nubs
    against a dark Dock or Finder sidebar.

Run:  python3 Everest/Resources/make_icon.py
"""

from PIL import Image, ImageDraw
import numpy as np
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).parent
ARTWORK = HERE / "Artwork"

SOURCES = [
    (ARTWORK / "icon-source.png", "AppIcon"),
    (ARTWORK / "icon-source-alt.png", "AppIcon-alt"),
]

CANVAS = 1024       # macOS icon canvas
BODY = 824          # icon body within that canvas, per Apple's grid
WHITE_CUTOFF = 245  # a pixel this bright in all channels counts as background


def resize(img, size):
    """Resize RGBA with premultiplied alpha.

    PIL interpolates the colour channels independently of alpha, so a fully
    transparent pixel still donates its RGB to its neighbours. The art stores
    its transparent corners as transparent BLACK, so a plain resize smears a
    dark fringe all the way around the squircle -- the icon reads as having
    dirty, slightly black corners at Dock size while looking fine at 1024.
    Premultiplying keeps transparent pixels from contributing any colour.
    """
    a = np.asarray(img.getchannel("A"), dtype=np.float64) / 255.0
    rgb = np.asarray(img.convert("RGBA"), dtype=np.float64)[:, :, :3]
    prem = np.dstack([rgb * a[:, :, None], a[:, :, None] * 255.0])

    small = np.asarray(
        Image.fromarray(prem.round().astype(np.uint8)).resize(size, Image.LANCZOS),
        dtype=np.float64)

    out_a = small[:, :, 3:4] / 255.0
    # Where nothing is left, alpha is 0 and the colour is unused; avoid 0/0.
    out_rgb = np.divide(small[:, :, :3], out_a, out=np.zeros_like(small[:, :, :3]),
                        where=out_a > 0)
    stacked = np.dstack([out_rgb, out_a * 255.0]).clip(0, 255)
    return Image.fromarray(stacked.round().astype(np.uint8))


def square(img):
    """Centre-crop to a square, in case a crop came out a pixel or two uneven."""
    side = min(img.size)
    w, h = img.size
    left, top = (w - side) // 2, (h - side) // 2
    return img.crop((left, top, left + side, top + side))


def non_white_bbox(img):
    """Bounding box of everything that is not background white."""
    grey = img.convert("L").point(lambda v: 0 if v >= WHITE_CUTOFF else 255)
    box = grey.getbbox()
    if box is None:
        sys.exit("Source image is blank.")
    return box


def measure_corner_radius(img):
    """Measure the squircle's corner radius off the cropped art.

    On a rounded rectangle, the top edge only becomes solid at x = r. So the
    first non-white pixel along the very top row sits approximately at the
    corner radius. Sampling a few rows down and taking the max keeps a stray
    antialiased pixel from throwing the number off.
    """
    w, _ = img.size
    grey = img.convert("L")
    candidates = []
    for y in (0, 1, 2):
        for x in range(w):
            if grey.getpixel((x, y)) < WHITE_CUTOFF:
                candidates.append(x)
                break
    if not candidates:
        return int(w * 0.2237)  # Apple's squircle ratio, as a fallback
    return max(candidates)


def rounded_mask(side, radius):
    """A rounded-rectangle alpha mask, supersampled so the corners are smooth.

    Drawn at final size the corners come out visibly stair-stepped.
    """
    scale = 4
    mask = Image.new("L", (side * scale, side * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, side * scale - 1, side * scale - 1),
        radius=radius * scale, fill=255)
    return mask.resize((side, side), Image.LANCZOS)


def squircle_body(src, img):
    """Crop the art down to its squircle and return it square, alpha applied."""
    alpha = img.getchannel("A") if "A" in img.getbands() else None

    if alpha is not None and alpha.getextrema()[0] == 0:
        body = square(img.crop(alpha.getbbox()))
        print(f"{src.name}: pre-masked, cropped to {body.size[0]}px")
        return body

    body = square(img.convert("RGB").crop(non_white_bbox(img))).convert("RGBA")
    side = body.size[0]
    radius = measure_corner_radius(body)
    body.putalpha(rounded_mask(side, radius))
    print(f"{src.name}: cropped to {side}px, measured corner radius "
          f"{radius}px ({radius / side:.4f} of side)")
    return body


def on_icon_grid(body):
    """Re-pad the body onto the macOS grid.

    macOS icons are not edge to edge: the body occupies 824pt of a 1024pt
    canvas and the rest is transparent breathing room. iOS masks and insets
    icons for you; macOS does not, and skipping this makes the icon look
    oversized next to every other icon in the Dock.
    """
    body = resize(body, (BODY, BODY))
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    canvas.paste(body, (off, off), body)
    return canvas


def verify(canvas):
    """Fail loudly on the three defects this script exists to prevent.

    Each is invisible in a 1024px preview and obvious once the app is in the
    Dock next to Chrome and Sublime.
    """
    alpha = canvas.getchannel("A")
    off = (CANVAS - BODY) // 2

    # 1. Padding did not happen: the icon renders oversized beside every other
    #    icon on the system. Tolerate a pixel of antialiasing at the extremes.
    box = alpha.getbbox()
    want = (off, off, off + BODY, off + BODY)
    assert all(abs(g - w) <= 2 for g, w in zip(box, want)), \
        f"body not on the {BODY}/{CANVAS} grid: {box}, wanted ~{want}"

    # 2. The transparent margin is not transparent: a white or black square
    #    frames the icon.
    corners = [(0, 0), (CANVAS - 1, 0), (0, CANVAS - 1), (CANVAS - 1, CANVAS - 1)]
    opaque = [c for c in corners if alpha.getpixel(c) != 0]
    assert not opaque, f"canvas corners not transparent: {opaque}"

    # 3. The squircle is square: sharp corners instead of the rounded shape
    #    every other macOS icon has. The body's own corner must be cut away.
    body_corners = [(off + 2, off + 2), (off + BODY - 3, off + 2),
                    (off + 2, off + BODY - 3), (off + BODY - 3, off + BODY - 3)]
    filled = [c for c in body_corners if alpha.getpixel(c) != 0]
    assert not filled, f"corners are not rounded, art fills them: {filled}"


def build(src, name):
    if not src.exists():
        sys.exit(f"Missing {src}")

    canvas = on_icon_grid(squircle_body(src, Image.open(src)))
    verify(canvas)

    # iconutil wants this exact set of names, and nothing else in the folder.
    iconset = HERE / f"{name}.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for mult in (1, 2):
            suffix = "" if mult == 1 else "@2x"
            resize(canvas, (pt * mult, pt * mult)).save(
                iconset / f"icon_{pt}x{pt}{suffix}.png")

    icns = HERE / f"{name}.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)],
                   check=True)
    # Leaving the .iconset behind would get it copied into the bundle.
    shutil.rmtree(iconset)
    print(f"  wrote {icns.name} ({icns.stat().st_size} bytes)")


if __name__ == "__main__":
    for src, name in SOURCES:
        build(src, name)
