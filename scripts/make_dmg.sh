#!/bin/bash
# Build the release .dmg: brand background, drag arrow, Applications alias.
#
#   ./scripts/make_dmg.sh <path-to-Everest.app> [version]
#
# Version defaults to the app's own CFBundleShortVersionString, so the DMG
# cannot be named for a version the bundle does not carry.
#
# Why a read-write image first: Finder cannot set a window background, icon
# size or icon positions on a read-only volume, and those settings live in the
# volume's own .DS_Store. So the image is built writable, dressed by Finder,
# then converted to compressed read-only. There is no way to skip the mount.

set -euo pipefail

APP="${1:?usage: make_dmg.sh <path-to-Everest.app> [version]}"
[ -d "$APP" ] || { echo "no such app bundle: $APP" >&2; exit 1; }

VERSION="${2:-$(defaults read "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")/Contents/Info.plist" CFBundleShortVersionString)}"
VOL="Everest $VERSION"
OUT="${OUT:-/tmp/Everest_${VERSION}_aarch64.dmg}"
BG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Everest/Resources/DMGBackground.tiff"
[ -f "$BG" ] || { echo "missing $BG — run Everest/Resources/make_dmg_background.py" >&2; exit 1; }

STAGE=$(mktemp -d)
RW=$(mktemp -u).dmg
trap 'rm -rf "$STAGE" "$RW"' EXIT

cp -R "$APP" "$STAGE/Everest.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"

# 40% headroom: a volume with no free space cannot be dressed, and the failure
# surfaces as an unhelpful Finder -5000 rather than as "disk full".
SIZE=$(( $(du -sm "$STAGE" | cut -f1) * 140 / 100 + 20 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -format UDRW -size "${SIZE}m" "$RW" >/dev/null

DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
MP="/Volumes/$VOL"
sleep 1

# Positions must match Everest/Resources/make_dmg_background.py: the arrow is
# painted into the gap between these two points.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- Content area ends up 700x450, matching the background's pixel size.
    set the bounds of container window to {200, 120, 900, 590}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Everest.app" of container window to {180, 205}
    set position of item "Applications" of container window to {520, 205}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store lazily; detaching before it lands loses the layout.
sync
hdiutil detach "$DEV" -quiet || { sleep 3; hdiutil detach "$DEV" -force -quiet; }

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "$OUT"
echo "  $(du -h "$OUT" | cut -f1)   sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
