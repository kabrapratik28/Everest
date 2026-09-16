#!/usr/bin/env python3
"""Turn a screen recording of a rewrite into the README's demo GIF.

    python3 scripts/make_demo_gif.py <recording.mov> [--start S] [--dur S] \\
        [--key "⌘ A@0.5-1.9" --key "⌥ R@2.0-3.6"]

**A GIF, not a video, on purpose.** GitHub only plays `<video>` for files
uploaded through its own web UI; a relative path to an `.mp4` in the repo
renders as a link. An animated GIF at a relative path plays inline, so that is
what the README can actually use.

## Recording the source

`screencapture -v` records a region, and the region has to contain nothing but
the editor. The trick is that the floating panel is centred on the *screen*
with its bottom fixed 96pt above the visible frame (`PanelGeometry`), so the
editor window is placed to cover that whole area and the recorded rectangle is
a slice strictly inside the window. Then no desktop, no Dock, no other window
and no menu bar can appear in frame, and nothing has to be cropped out later.

    /tmp/vf                          # prints visibleFrame; panel is midX ± 230
    # place the editor window WIDER than the recorded rectangle, so its own
    # chrome — title bar, and Sublime's UNREGISTERED banner — falls outside
    screencapture -v -V 24 -R<x>,<y>,<w>,<h> /tmp/demo_raw.mov

Drive the hotkey with a CGEvent posted at `.cghidEventTap`. A `System Events`
keystroke will not do it: Carbon's `RegisterEventHotKey` listens below the
session tap, which is the note in `docs/MANUAL-CHECKS.md`.

## Key badges

Timings are measured off the recording, never guessed, by extracting frames a
second apart and reading which one first shows the change. They are passed in
rather than hardcoded because a re-record shifts every one of them.
"""

import argparse
import pathlib
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/assets/demo.gif"
# SFNS.ttf, not SFNSDisplay-Bold.otf. The display face has no U+2318 or
# U+2325, so the first version of this shipped ⌘ and ⌥ as tofu boxes.
FONT = "/System/Library/Fonts/SFNS.ttf"


def ffmpeg() -> str:
    for c in ("ffmpeg", str(pathlib.Path.home() / ".local/bin/ffmpeg")):
        if subprocess.run(["which", c], capture_output=True).returncode == 0 or pathlib.Path(c).exists():
            return c
    sys.exit("ffmpeg not found")


def badge(keys: list[str], path: pathlib.Path) -> None:
    """One rounded keycap per key, rendered at the source video's 2x scale so
    the overlay is resampled with the frame rather than drawn crisp onto
    already-soft pixels."""
    f = ImageFont.truetype(FONT, 46)
    for k in keys:
        if f.getmask(k).getbbox() is None:
            sys.exit(f"{FONT} has no glyph for {k!r}; it would render as a tofu box")

    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    caps = [(k, max(int(probe.textbbox((0, 0), k, font=f)[2]) + 44, 74)) for k in keys]
    gap, h = 14, 86
    img = Image.new("RGBA", (sum(w for _, w in caps) + gap * (len(caps) - 1), h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = 0
    for k, w in caps:
        d.rounded_rectangle([x, 0, x + w, h], radius=16, fill=(16, 18, 24, 232),
                            outline=(120, 132, 156, 255), width=3)
        bb = d.textbbox((0, 0), k, font=f)
        d.text((x + (w - bb[2]) / 2, (h - bb[3]) / 2 - 6), k, font=f, fill=(255, 255, 255, 255))
        x += w + gap
    img.save(path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--dur", type=float, default=8.0)
    ap.add_argument("--width", type=int, default=760)
    ap.add_argument("--fps", type=int, default=12)
    ap.add_argument("--badge", choices=("top", "bottom"), default="bottom",
                    help="where the key badges sit; pick whichever corner the recording leaves empty")
    ap.add_argument("--key", action="append", default=[],
                    help='e.g. "⌘ A@0.5-1.9" — keys space-separated, times relative to --start')
    ap.add_argument("--out", type=pathlib.Path, default=OUT,
                    help="output path; a non-.gif suffix writes H.264 instead of a palettised GIF")
    a = ap.parse_args()
    out = a.out
    gif = out.suffix.lower() == ".gif"

    specs = []
    for i, spec in enumerate(a.key):
        m = re.fullmatch(r"(.+)@([\d.]+)-([\d.]+)", spec)
        if not m:
            sys.exit(f"bad --key {spec!r}; want \"⌘ A@0.5-1.9\"")
        p = pathlib.Path(f"/tmp/_badge{i}.png")
        badge(m.group(1).split(), p)
        specs.append((p, float(m.group(2)), float(m.group(3))))

    chain, label = [], "[0:v]"
    for i, (_, t0, t1) in enumerate(specs):
        nxt = f"[b{i}]"
        y = "40" if a.badge == "top" else "main_h-140"
        chain.append(f"{label}[{i + 1}:v]overlay=40:{y}:enable='between(t,{t0},{t1})'{nxt}")
        label = nxt
    if gif:
        chain.append(
            f"{label}fps={a.fps},scale={a.width}:-1:flags=lanczos,split[s0][s1];"
            f"[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3"
        )
    else:
        # -2, not -1: H.264 needs even dimensions and an odd height makes
        # libx264 fail outright rather than round for you.
        chain.append(f"{label}scale={a.width}:-2:flags=lanczos,format=yuv420p")

    cmd = [ffmpeg(), "-y", "-loglevel", "error", "-ss", str(a.start), "-t", str(a.dur), "-i", a.recording]
    for p, _, _ in specs:
        cmd += ["-i", str(p)]
    cmd += ["-filter_complex", ";".join(chain)]
    if not gif:
        # yuv420p + faststart, or QuickTime and every browser refuse it.
        cmd += ["-c:v", "libx264", "-crf", "18", "-preset", "slow",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an"]
    cmd += [str(out)]
    subprocess.run(cmd, check=True)

    kb = out.stat().st_size // 1024
    try:
        shown = out.relative_to(ROOT)
    except ValueError:
        shown = out
    print(f"wrote {shown}  {kb} KB")
    # A README image nobody waits for is a README image nobody sees.
    if gif and kb > 3000:
        print("  over 3 MB — drop --fps to 10 or --width to 640", file=sys.stderr)


if __name__ == "__main__":
    main()
