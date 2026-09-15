# Resources — icon and bundle assets

## The app icon

Two renders of the same composition exist. `make_icon.py` (Pillow + numpy)
builds both, so the icon swaps by editing one plist key. Don't hand-edit the
`.icns`; if the art changes, re-run `python3 Everest/Resources/make_icon.py`.

| Source | Output | In the bundle |
|---|---|---|
| `Artwork/icon-source.png` | `AppIcon.icns` | yes — `CFBundleIconFile: AppIcon` |
| `Artwork/icon-source-alt.png` | `AppIcon-alt.icns` | no — excluded in `project.yml`, and gitignored |

**`Artwork/` is committed; what the script prints is not.** The alt art is the
only coverage of the opaque-source alpha path below, so §1 keeps it; its 1.5 MB
`.icns` was always regenerable. Nothing rebuilds without `Artwork/`, nothing
reads `~/Desktop`, and paths resolve relative to the script. Both `project.yml`
exclusions stay regardless of git — re-run the script and the alt is back on
disk, and `__pycache__` appears the moment someone imports rather than runs it.

`.icns` is still correct on macOS 26; Icon Composer `.icon` files only buy the
Liquid Glass treatment. No asset catalog either — one `.icns` and one
`CFBundleIconFile` key is the whole requirement; `.xcassets` would add a build
phase and a second place to go stale.

## Why the script is not just `sips`

Each fixes a defect invisible at 1024px; `verify()` asserts the last three.

**The alpha comes from a different place per source.** `icon-source.png` already
has transparent corners, so its own alpha *is* the mask; rebuilding one would
round off a curve that is already right. `icon-source-alt.png` is opaque on a
white margin, so it needs cropping and the corners punched out — otherwise the
crop leaves white triangles that show as nubs against a dark Dock.

**The corner radius is measured, not assumed.** On a rounded rectangle the top
row only goes solid at `x = r`, so the first non-background pixel there gives
the radius. This art is **0.285 of its side** against Apple's 0.2237 —
hardcoding Apple's shaves the blue off all four corners. Mask supersampled 4x.

**Resizing is premultiplied.** The subtle one. PIL interpolates colour
independently of alpha, so a transparent pixel still donates RGB to neighbours
— and these corners are transparent *black*. A plain `.resize()` smears a dark
fringe round the squircle (edge luminance ~114 → ~83): fine at 1024, grubby
black corners at Dock size. Use `resize()`, never `Image.resize`.

**The body is re-padded to 824pt of a 1024pt canvas.** macOS icons are not edge
to edge; the rest is transparent. iOS insets for you and macOS does not, so an
edge-to-edge icon ships looking oversized beside every other icon on screen.

## The menu bar icon is a separate problem

Everest is `LSUIElement = true`, so there is **no Dock icon** — `AppIcon.icns`
is seen only in Finder, the About box, and System Settings ▸ Accessibility.

The menu bar item must NOT use this artwork. At 18pt a gradient painting turns
to mush, and a fixed-colour image cannot follow light/dark appearance or the
highlighted state. It needs a **template image**: monochrome, `isTemplate =
true`, tinted by AppKit — SF Symbol `mountain.2.fill`, else `sparkles`. Never
point the status item at `AppIcon.icns`.
