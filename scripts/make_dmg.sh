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

# Sparkle's helpers have to carry the SAME signing identity as the app, or
# the updater refuses to launch them and the user sees "An error occurred
# while launching the installer." They do not get it from the build:
# project.yml sets `CODE_SIGN_IDENTITY: "-"` in `settings.base`, which is
# required there (a real identity in base breaks eight SPM packages at once)
# and which reaches Sparkle's nested tools, leaving them ad-hoc.
#
# Signed inside-out, because signing an inner item invalidates every
# signature outside it. The app itself is last.
SPARKLE="$STAGE/Everest.app/Contents/Frameworks/Sparkle.framework/Versions/B"
IDENTITY=$(sed -n 's/^CODE_SIGN_IDENTITY *= *//p' \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Everest/Signing.local.xcconfig" 2>/dev/null | tr -d ' ')

if [ -n "$IDENTITY" ] && [ -d "$SPARKLE" ]; then
  for item in \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/Updater.app" \
    "$SPARKLE/Autoupdate" \
    "$SPARKLE/../../../Sparkle.framework" \
    "$STAGE/Everest.app"
  do
    [ -e "$item" ] || continue
    codesign --force --options runtime --timestamp=none \
      --sign "$IDENTITY" "$item" >/dev/null 2>&1 \
      || { echo "failed to sign $item" >&2; exit 1; }
  done

  # Assert rather than hope. Every nested Mach-O must report the app's team,
  # because one ad-hoc helper is enough to break every future auto-update,
  # and it fails silently on the user's machine rather than here.
  WANT=$(codesign -dvvv "$STAGE/Everest.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  BAD=0
  while IFS= read -r m; do
    got=$(codesign -dvvv "$m" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$got" = "$WANT" ] || { echo "  team mismatch: ${m#$STAGE/} is '${got:-none}', want '$WANT'" >&2; BAD=1; }
  done <<EOT
$(find "$STAGE/Everest.app/Contents/Frameworks" -type f -perm +111 2>/dev/null | while read -r f; do file "$f" | grep -q Mach-O && echo "$f"; done)
EOT
  [ "$BAD" = "0" ] || { echo "Sparkle helpers are not signed with the app identity; the updater would fail" >&2; exit 1; }
  echo "  Sparkle helpers signed with $WANT"
else
  echo "  note: no Signing.local.xcconfig, leaving signatures alone (auto-update will not work)" >&2
fi
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

# Geometry must match Everest/Resources/make_dmg_background.py, which prints
# the values it expects. The arrow is painted into the gap between these two
# points, so a change in one file without the other shows up as an arrow
# pointing at nothing.
#
# `position` is the top-left of an icon's cell, not its centre — an icon set to
# y=205 at 128pt draws centred near y=269, which is how the arrow ended up
# floating 45pt above the icons the first time.
#
# `.background`, `.fseventsd` and `.Trashes` are parked outside the window
# rather than left to Finder's auto-arrange. They are invisible to most people,
# but anyone with ⌘⇧. on sees them tiled over the title, and `.fseventsd` is
# created by the OS on mount so it cannot simply not be there.
#
# No close-then-open at the end. That idiom is everywhere online and it is
# what produced a 406pt-wide window from a 700pt request: re-opening restores
# whatever size Finder remembers for a volume of this name, and the following
# `update` then writes that remembered size into the .DS_Store we ship. Set,
# update, read back, close.
# The AppleScript goes to a file rather than into $(osascript <<EOF ...). Bash
# scans a command substitution body for the closing paren, so one apostrophe
# anywhere in the script — "the background's size" — made the whole file a
# syntax error. Twice. A file has no such rule.
SCPT="$STAGE/../dress.applescript"
cat > "$SCPT" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 716x524, NOT the background image's 700x500. Finder reports `bounds`
    -- back as whatever you set, but the icon view inside the frame is smaller
    -- by the window chrome, so a frame matching the image exactly leaves the
    -- image slightly too big for the view and Finder adds both scrollbars.
    -- 16 and 24 are the measured allowances on macOS 26.
    set the bounds of container window to {200, 120, 916, 644}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set background picture of opts to file ".background:background.tiff"
    set position of item "Everest.app" of container window to {176, 176}
    set position of item "Applications" of container window to {524, 176}
    repeat with junk in {".background", ".fseventsd", ".Trashes"}
      try
        set position of item junk of container window to {940, 660}
      end try
    end repeat
    update without registering applications
    delay 3
    set b to the bounds of container window
    close
    -- `as string` on each number is required: in AppleScript, & applied to two
    -- numbers builds a list, so this returned "716, x, 524" and the check
    -- below rejected a window that was in fact exactly right.
    return (((item 3 of b) - (item 1 of b)) as string) & "x" & (((item 4 of b) - (item 2 of b)) as string)
  end tell
end tell
APPLESCRIPT

GOT=$(osascript "$SCPT")
# A window that did not take the size ships a cropped, scrolled background.
# Loud here beats finding it in a screenshot, which is how the last three went.
[ "$GOT" = "716x524" ] || { echo "window is ${GOT}, wanted 716x524" >&2; hdiutil detach "$DEV" -force -quiet; exit 1; }

# Dressing the volume makes the OS create these, and hdiutil then bakes them
# into the shipped image, where anyone with hidden files shown sees them tiled
# over the artwork. Handy 0.9.6 ships neither, which is what prompted looking.
#
# A branded `.VolumeIcon.icns` was tried here too, the way Handy does it, and
# did not survive into the converted image for reasons not worth chasing: it
# only changes the disk icon while the image is mounted, and the background is
# the surface that actually carries instructions.
rm -rf "$MP/.fseventsd" "$MP/.Trashes" 2>/dev/null || true

# Finder writes .DS_Store lazily; detaching before it lands loses the layout.
sync
hdiutil detach "$DEV" -quiet || { sleep 3; hdiutil detach "$DEV" -force -quiet; }

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "$OUT"
echo "  $(du -h "$OUT" | cut -f1)   sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
