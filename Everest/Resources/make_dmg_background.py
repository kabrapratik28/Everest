#!/usr/bin/env python3
"""Draw the .dmg window background: brand wash, drag arrow, Open Anyway steps.

The background is the Finder window wallpaper shown when someone double-clicks
the disk image. It is the only surface that exists before first launch —
Gatekeeper stops the app from running, so nothing in the app can help — which
is why the Open Anyway steps are painted into it rather than left to the
release notes alone.

The icons are NOT drawn here. Finder draws the real app icon and the real
Applications alias on top, at the positions `scripts/make_dmg.sh` sets, so the
two files have to agree about where they land. Two things about Finder's
coordinates were got wrong once and are worth stating:

  - `position` is the top-left of the icon's cell, not its centre. An icon set
    to y=205 at 128pt draws centred near y=269. `ICON_TOP` below is a top-left
    value and `icon_centre()` is what the painting uses.
  - Finder writes a **label** under each icon, outside the icon box. That is
    what collided with the instructions panel the first time, so `PANEL_TOP`
    has to clear the label, not merely the icon.

Output is a multi-representation TIFF, not a PNG. Finder uses an image's pixel
dimensions directly, so a single 1x file is soft on every Mac sold since 2012
and a single 2x file renders at half size. `tiffutil -cathidpicheck` packs both
into one file and macOS picks per display.

Run:  python3 Everest/Resources/make_dmg_background.py
"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import pathlib
import subprocess
import sys

# Geometry. scripts/make_dmg.sh sets the window to exactly W x H and places the
# two icons at (APP_X, ICON_TOP) and (DEST_X, ICON_TOP). Change it in one place
# and the other stops lining up.
W, H = 700, 500
ICON = 128
ICON_TOP = 176                 # top-left y that make_dmg.sh sets
APP_X, DEST_X = 176, 524       # icon-cell centres horizontally
PANEL_TOP = 342                # must clear ICON_TOP + ICON + label height

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Everest/Resources/DMGBackground.tiff"

# Sampled from Artwork/icon-source.png, which is overwhelmingly deep blue.
INK = (6, 14, 38)
DEEP = (10, 30, 78)
GLOW = (32, 86, 190)


def icon_centre() -> int:
    return ICON_TOP + ICON // 2


def font(size, weight="Regular"):
    """System font by path. PIL has no font discovery and its silent fallback
    is a bitmap face, which produces a background that looks broken rather
    than one that looks unstyled — so this fails loudly instead."""
    faces = [
        f"/System/Library/Fonts/SFNSDisplay-{weight}.otf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for f in faces:
        if pathlib.Path(f).exists():
            try:
                return ImageFont.truetype(f, size)
            except OSError:
                continue
    sys.exit("no usable system font found; looked for: " + ", ".join(faces))


def centred(d, y, text, f, fill):
    w = d.textbbox((0, 0), text, font=f)[2]
    d.text(((d.im.size[0] - w) // 2, y), text, font=f, fill=fill)


def render(s):
    """`s` is the scale factor: 1 or 2. Every constant is multiplied by it, so
    the two renders are the same picture rather than two similar ones."""
    w, h = W * s, H * s
    img = Image.new("RGB", (w, h), INK)
    d = ImageDraw.Draw(img)

    # Vertical wash: lighter across the icon row, dark at the top and bottom so
    # Finder's white icon labels and the panel both stay legible.
    focus = icon_centre() / H
    for y in range(h):
        t = abs(y / h - focus)
        k = max(0.0, 1.0 - (t / 0.55) ** 1.6)
        d.line([(0, y), (w, y)], fill=tuple(int(INK[i] + (DEEP[i] - INK[i]) * k) for i in range(3)))

    # A soft halo behind the app icon: a blurred disc used as an alpha mask to
    # lift the wash towards GLOW. The icon is dark blue on dark blue without it.
    mask = Image.new("L", (w, h), 0)
    r = 155 * s
    ImageDraw.Draw(mask).ellipse(
        [APP_X * s - r, icon_centre() * s - r, APP_X * s + r, icon_centre() * s + r], fill=150
    )
    mask = mask.filter(ImageFilter.GaussianBlur(72 * s))
    img = Image.composite(Image.new("RGB", (w, h), GLOW), img, mask)
    d = ImageDraw.Draw(img)

    centred(d, 44 * s, "Everest", font(40 * s, "Bold"), (255, 255, 255))
    centred(d, 98 * s, "Drag Everest onto Applications to install", font(15 * s), (146, 178, 228))
    # The requirement belongs here because it is the last surface before the
    # app is on disk. Below the floor macOS refuses to launch it and shows
    # its own dialog, which is correct but arrives after the download.
    centred(d, 122 * s, "Requires macOS 15 or later, Apple silicon", font(12 * s), (118, 150, 200))

    # Arrow. Sits on the icon centre line, stopping short of both cells so it
    # can never run under an icon or its label.
    y = icon_centre() * s
    x0 = (APP_X + ICON // 2 + 26) * s
    x1 = (DEST_X - ICON // 2 - 26) * s
    d.line([(x0, y), (x1 - 14 * s, y)], fill=(118, 162, 226), width=max(2, 3 * s))
    d.polygon([(x1, y), (x1 - 16 * s, y - 10 * s), (x1 - 16 * s, y + 10 * s)], fill=(118, 162, 226))

    # The Gatekeeper panel. Everyone who downloads this hits the block, so it
    # reads as an expected step and not as troubleshooting. Left-aligned as a
    # block, because a centred heading over a numbered list gives the eye two
    # different left edges to track.
    pad = 44 * s
    x0, y0, x1, y1 = pad, PANEL_TOP * s, w - pad, (H - 28) * s

    # A card, not a hole. The first version was near-black on navy, which read
    # as a gap in the artwork rather than as a panel.
    d.rounded_rectangle([x0, y0, x1, y1], radius=16 * s, fill=(15, 34, 78), outline=(56, 98, 172), width=max(1, s))
    d.line([x0 + 16 * s, y0 + 1 * s, x1 - 16 * s, y0 + 1 * s], fill=(84, 132, 208), width=max(1, s))

    tx = x0 + 26 * s
    d.text((tx, y0 + 15 * s), "macOS blocks the first launch. Three steps, once.",
           font=font(15 * s, "Semibold"), fill=(242, 246, 253))
    d.line([tx, y0 + 42 * s, x1 - 26 * s, y0 + 42 * s], fill=(44, 82, 148), width=max(1, s))

    steps = [
        "Open Everest from Applications, then click Done.",
        "Go to System Settings, then Privacy & Security.",
        "Scroll to Security and click Open Anyway.",
    ]
    fnum, ftxt = font(11 * s, "Bold"), font(13 * s)
    for i, text in enumerate(steps):
        ty = y0 + (55 + i * 23) * s
        cx, cy = tx + 9 * s, ty + 8 * s
        d.ellipse([cx - 9 * s, cy - 9 * s, cx + 9 * s, cy + 9 * s], fill=(48, 94, 178))
        n = str(i + 1)
        nw = d.textbbox((0, 0), n, font=fnum)[2]
        d.text((cx - nw / 2, cy - 7 * s), n, font=fnum, fill=(233, 241, 254))
        d.text((tx + 28 * s, ty), text, font=ftxt, fill=(185, 208, 242))

    # The last step ran off the bottom of the card once, and the render said
    # nothing. Measured against the real glyph box rather than the nominal
    # point size, because a descender is what actually crosses the edge.
    last = d.textbbox((tx + 28 * s, y0 + (55 + 2 * 23) * s), steps[-1], font=ftxt)[3]
    if last > y1 - 6 * s:
        sys.exit(
            f"step 3 ends at y={last // s} and the card ends at {y1 // s}: "
            "lower PANEL_TOP, tighten the 23pt step pitch, or raise H."
        )

    return img


def main():
    tmp = []
    for s, name in ((1, "bg1x.png"), (2, "bg2x.png")):
        p = pathlib.Path("/tmp") / name
        render(s).save(p)
        tmp.append(str(p))
        print(f"  rendered {name} at {W * s}x{H * s}")

    subprocess.run(["tiffutil", "-cathidpicheck", *tmp, "-out", str(OUT)], check=True, capture_output=True)
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")
    print(f"  make_dmg.sh must use: window {W}x{H}, icons at ({APP_X},{ICON_TOP}) and ({DEST_X},{ICON_TOP})")


if __name__ == "__main__":
    main()
