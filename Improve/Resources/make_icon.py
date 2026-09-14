#!/usr/bin/env python3
"""Turn 'Everest logo.png' into AppIcon.icns.

The source art already has the macOS squircle drawn on it, sitting on a white
background. Three things have to happen, in order:

  1. Crop the white margin away, tight to the squircle.
  2. Punch the four corners transparent. A tight rectangular crop still leaves
     white triangles outside the rounded corners, and those show up as white
     nubs against a dark Dock or Finder sidebar. The corner radius is MEASURED
     from the art rather than assumed, so the mask lines up with the curve that
     is actually drawn.
  3. Re-pad to the macOS icon grid. macOS icons are not edge to edge: the body
     occupies 824pt of a 1024pt canvas, and the rest is transparent breathing
     room. Skipping this makes the icon look oversized next to every other icon
     in the Dock.

Run:  python3 make_icon.py
"""

from PIL import Image, ImageDraw
import subprocess, sys, pathlib

SRC = pathlib.Path.home() / "Desktop" / "Everest logo.png"
HERE = pathlib.Path(__file__).parent
ICONSET = HERE / "AppIcon.iconset"
ICNS = HERE / "AppIcon.icns"
MASTER = HERE / "AppIcon-1024.png"

CANVAS = 1024      # macOS icon canvas
BODY = 824         # icon body within that canvas, per Apple's grid
WHITE_CUTOFF = 245 # a pixel this bright in all channels counts as background


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
    corner radius. Sampling a few rows down and taking the minimum keeps a
    stray antialiased pixel from throwing the number off.
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


def main():
    if not SRC.exists():
        sys.exit(f"Missing {SRC}")

    src = Image.open(SRC).convert("RGB")
    body = src.crop(non_white_bbox(src))

    # Square it off, in case the crop came out a pixel or two uneven.
    side = min(body.size)
    body = body.crop((0, 0, side, side)).convert("RGBA")

    radius = measure_corner_radius(body)
    print(f"cropped to {side}x{side}, measured corner radius {radius}px "
          f"({radius / side:.4f} of side)")

    # Supersample the mask so the rounded corners come out smooth.
    scale = 4
    mask = Image.new("L", (side * scale, side * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, side * scale - 1, side * scale - 1),
        radius=radius * scale, fill=255)
    mask = mask.resize((side, side), Image.LANCZOS)
    body.putalpha(mask)

    # Re-pad onto the macOS grid.
    body = body.resize((BODY, BODY), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    canvas.paste(body, (off, off), body)
    canvas.save(MASTER)
    print(f"wrote {MASTER}")

    # iconutil wants this exact set of names.
    if ICONSET.exists():
        for f in ICONSET.iterdir():
            f.unlink()
    else:
        ICONSET.mkdir()

    for pt in (16, 32, 128, 256, 512):
        for mult in (1, 2):
            px = pt * mult
            suffix = "" if mult == 1 else "@2x"
            canvas.resize((px, px), Image.LANCZOS).save(
                ICONSET / f"icon_{pt}x{pt}{suffix}.png")

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
                   check=True)
    print(f"wrote {ICNS} ({ICNS.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
