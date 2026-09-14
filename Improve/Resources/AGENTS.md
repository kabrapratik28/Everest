# Resources — icon and bundle assets

## The app icon

`AppIcon.icns` is generated from `~/Desktop/Everest logo.png` by `make_icon.py`. Do not hand-edit the `.icns`. If the source art changes, re-run:

```bash
python3 Everest/Resources/make_icon.py
```

The script does three things, and each exists because skipping it produces a visible defect:

**1. Crops the white margin.** The source art is a squircle floating on a white background with a wide margin. Shipping it uncropped gives a tiny icon lost in a white square.

**2. Punches the corners transparent, at a measured radius.** The squircle is already drawn into the art, so a tight rectangular crop still leaves four white triangles outside the curve. Those render as white nubs against a dark Dock or Finder sidebar.

The radius is *measured* from the art, not taken from Apple's spec. On a rounded rectangle the top row only becomes solid at `x = r`, so the first non-background pixel along the top edge gives the radius directly. This art measures **0.286 of its side**, noticeably rounder than Apple's own squircle ratio of 0.2237. Hardcoding Apple's number would have shaved the blue off all four corners. If you swap the art for something with a different curve, the script re-measures and still lines up.

**3. Re-pads to the macOS icon grid.** macOS icons are not edge to edge: the body occupies 824pt of a 1024pt canvas and the remainder is transparent. An edge-to-edge icon looks oversized beside every other icon on the system. iOS masks icons for you; macOS does not, which is why this step is easy to forget when porting habits across.

The mask is supersampled 4x and downsampled with Lanczos, because a mask drawn at final size gives visibly stair-stepped corners.

## The menu bar icon is a separate problem

Everest is `LSUIElement = true`, so it has **no Dock icon**. `AppIcon.icns` is only seen in Finder, the About box, and System Settings ▸ Accessibility.

The menu bar item must NOT use this artwork. At 18pt a detailed gradient painting turns to mush, and a fixed-colour image cannot follow the menu bar between light and dark appearance or the highlighted state. The menu bar needs a **template image**: monochrome, with `isTemplate = true`, letting AppKit tint it.

Use the SF Symbol `mountain.2.fill`, which matches the brand without inventing a second asset to maintain. If that symbol is unavailable on the deployment target, fall back to `sparkles`. Do not "fix" this by pointing the status item at `AppIcon.icns`.

## Wiring

`AppIcon.icns` is referenced from `Info.plist` via `CFBundleIconFile` (value: `AppIcon`, no extension). There is deliberately no asset catalog: one `.icns` and one plist key is the whole requirement, and an `.xcassets` bundle would add a build phase and a second place for the icon to go stale.
