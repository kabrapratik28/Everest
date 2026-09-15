#!/usr/bin/env python3
"""Draw the .dmg window background: brand wash, drag arrow, Open Anyway steps.

The background is the Finder window wallpaper shown when someone double-clicks
the disk image. It is the only surface that exists before first launch —
Gatekeeper stops the app from running, so nothing in the app can help — which
is why the Open Anyway steps are painted into it rather than left to the
release notes alone.

The icons are NOT drawn here. Finder draws the real app icon and the real
Applications folder alias on top, at the positions `scripts/make_dmg.sh` sets.
This file paints only what sits behind them, so the two must agree: the gap in
the middle of the arrow is where those icons land.

Output is a multi-representation TIFF, not a PNG. Finder uses an image's pixel
dimensions directly, so a single 1x file is soft on every Mac sold since 2012
and a single 2x file renders at half size. `tiffutil -cathidpicheck` packs both
into one file and macOS picks per display.

Run:  python3 Everest/Resources/make_dmg_background.py
"""

from PIL import Image, ImageDraw, ImageFont
import pathlib
import subprocess
import sys

W, H = 700, 450
ICON_Y = 205          # centre of the icon row, must match make_dmg.sh
APP_X, DEST_X = 180, 520

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Everest/Resources/DMGBackground.tiff"

# Sampled from Artwork/icon-source.png: the icon is overwhelmingly deep blue.
DEEP = (0, 24, 72)
MID = (0, 48, 144)


def font(size, bold=False):
    """System font by path. PIL has no font discovery, and a silent fall back
    to the bitmap default produces a background that looks broken rather than
    one that looks unstyled, so this fails loudly instead."""
    faces = [
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for f in faces:
        if pathlib.Path(f).exists():
            try:
                return ImageFont.truetype(f, size, index=1 if bold and f.endswith("ttc") else 0)
            except OSError:
                continue
    sys.exit("no usable system font found; looked for: " + ", ".join(faces))


def centred(d, y, text, f, fill):
    w = d.textbbox((0, 0), text, font=f)[2]
    d.text(((W - w) // 2, y), text, font=f, fill=fill)


def render(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), DEEP)
    d = ImageDraw.Draw(img)

    # Vertical wash, dark at the edges so white Finder icon labels stay legible.
    for y in range(h):
        t = y / h
        k = 1 - abs(t - 0.38) * 1.5
        k = max(0.0, min(1.0, k))
        d.line(
            [(0, y), (w, y)],
            fill=tuple(int(DEEP[i] + (MID[i] - DEEP[i]) * k * 0.85) for i in range(3)),
        )

    centred(d, 42 * scale, "Everest", font(34 * scale), (255, 255, 255))
    centred(d, 86 * scale, "Drag Everest onto Applications", font(15 * scale), (150, 185, 235))

    # Arrow, stopping well short of both icons so it never runs under a label.
    y = ICON_Y * scale
    x0, x1 = (APP_X + 78) * scale, (DEST_X - 78) * scale
    d.line([(x0, y), (x1 - 13 * scale, y)], fill=(120, 165, 225), width=max(2, 3 * scale))
    d.polygon(
        [(x1, y), (x1 - 15 * scale, y - 9 * scale), (x1 - 15 * scale, y + 9 * scale)],
        fill=(120, 165, 225),
    )

    # The Gatekeeper instructions. Everyone downloading this hits the block, so
    # it is stated as an expected step rather than as troubleshooting.
    box_top = 322 * scale
    d.rounded_rectangle(
        [(46 * scale, box_top), (w - 46 * scale, h - 26 * scale)],
        radius=10 * scale,
        fill=(0, 18, 54),
        outline=(40, 78, 150),
        width=max(1, scale),
    )
    centred(d, box_top + 14 * scale, "First launch is blocked by macOS. This is expected.", font(14 * scale, True), (235, 240, 250))
    steps = [
        "1.  Open Everest from Applications, then click Done on the warning.",
        "2.  System Settings ▸ Privacy & Security, scroll down to Security.",
        "3.  Next to “Everest was blocked”, click Open Anyway.",
    ]
    f = font(13 * scale)
    for i, s in enumerate(steps):
        d.text((72 * scale, box_top + 40 * scale + i * 20 * scale), s, font=f, fill=(165, 195, 240))

    return img


def main():
    tmp = []
    for scale, name in ((1, "bg1x.png"), (2, "bg2x.png")):
        p = pathlib.Path("/tmp") / name
        render(scale).save(p)
        tmp.append(str(p))
        print(f"  rendered {name} at {W * scale}x{H * scale}")

    subprocess.run(
        ["tiffutil", "-cathidpicheck", *tmp, "-out", str(OUT)],
        check=True,
        capture_output=True,
    )
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
