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
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# `|| true` because the file is legitimately absent on a clean clone, and
# under `set -euo pipefail` a failing `sed` here kills the script on the spot
# with no message at all — which is what happened once the missing-config
# branch below was made fatal: correct exit status, empty stderr, nothing to
# act on. Let the assignment come back empty and let that branch explain it.
IDENTITY=$(sed -n 's/^CODE_SIGN_IDENTITY *= *//p' \
  "$REPO/Everest/Signing.local.xcconfig" 2>/dev/null | tr -d ' ' || true)

if [ -n "$IDENTITY" ] && [ -d "$SPARKLE" ]; then
  # **`SKIP_APP_SIGNING=1` packages an app that is already signed AND stapled.**
  #
  # Needed because a stapled ticket does not survive re-signing: `codesign`
  # rewrites the bundle, the cdhash changes, and Apple's ticket — which is
  # looked up by cdhash — no longer applies. So the order for an offline-safe
  # release is sign, notarise the app, staple the app, then package WITHOUT
  # touching the signature again. Running the loop below at that point would
  # silently undo the stapling this flag exists to preserve.
  if [ "${SKIP_APP_SIGNING:-0}" = "1" ]; then
    xcrun stapler validate "$STAGE/Everest.app" >/dev/null 2>&1 \
      || { echo "SKIP_APP_SIGNING=1 but the app has no stapled ticket; staple it first" >&2; exit 1; }
    echo "  app already signed and stapled, leaving its signature alone" >&2
  else
  for item in \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/Updater.app" \
    "$SPARKLE/Autoupdate" \
    "$SPARKLE/../../../Sparkle.framework" \
    "$STAGE/Everest.app"
  do
    [ -e "$item" ] || continue
    # **`--force` without `--entitlements` drops every entitlement**, and the
    # app is the last item here, so this loop was silently shipping it with
    # Hardened Runtime on and nothing granted. Sparkle's helpers carry none
    # of their own — checked, before and after — so only the app passes one,
    # and it passes the tracked file `project.yml` already builds from rather
    # than re-reading the signature it is about to replace.
    # **`--timestamp`, never `--timestamp=none`.** Notarisation rejects a
    # signature with no secure timestamp ("The signature does not include a
    # secure timestamp"), and it rejects the whole submission, so one helper
    # signed without one fails the app. `=none` was correct while this was a
    # Development-signed build that could never be notarised; it is not any
    # more. This reaches Apple's timestamp server, so signing now needs the
    # network and is a little slower.
    #
    # **An array, not `${ENT:+--entitlements "$ENT"}`.** That form expands to
    # the single argument `--entitlements /path/to/file`, space and all, and
    # codesign answers `unrecognized option` and exits 2. The app is the only
    # item that passes entitlements and the last one signed, so the effect was
    # that the app alone silently kept whatever signature Xcode left on it —
    # which carries `Signed Time`, not a secure `Timestamp`, and would have
    # come back Invalid from the notary service.
    args=(--force --options runtime --timestamp)
    if [ "$item" = "$STAGE/Everest.app" ]; then
      args+=(--entitlements "$REPO/Everest/Resources/Everest.entitlements")
    fi
    # stderr is captured rather than discarded. `>/dev/null 2>&1` here is what
    # kept the `unrecognized option` line off the screen while the build
    # carried on and reported success.
    if ! err=$(codesign "${args[@]}" --sign "$IDENTITY" "$item" 2>&1); then
      echo "failed to sign $item" >&2
      printf '%s\n' "$err" | sed 's/^/    /' >&2
      exit 1
    fi
  done
  fi

  # Assert rather than hope. Every nested Mach-O must report the app's team,
  # because one ad-hoc helper is enough to break every future auto-update,
  # and it fails silently on the user's machine rather than here.
  #
  # **Walks the whole bundle, not just Contents/Frameworks.** The narrower
  # find matched what the signing loop happens to touch, so it could only ever
  # confirm work already done: a dylib or helper dropped anywhere else would
  # go unsigned and unreported, and notarytool would be the first to say so.
  WANT=$(codesign -dvvv "$STAGE/Everest.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  BAD=0
  while IFS= read -r m; do
    # One codesign call, both answers. A secure timestamp is checked on every
    # nested Mach-O and not just on the app, because notarytool rejects the
    # whole submission for one helper that lacks it, and it reports that as a
    # path inside the DMG half an hour after the release build started.
    # `Timestamp=` is the secure one; a local signature says `Signed Time=`.
    desc=$(codesign -dvvv "$m" 2>&1)
    got=$(printf '%s\n' "$desc" | sed -n 's/^TeamIdentifier=//p')
    [ "$got" = "$WANT" ] || { echo "  team mismatch: ${m#$STAGE/} is '${got:-none}', want '$WANT'" >&2; BAD=1; }
    printf '%s\n' "$desc" | grep -q '^Timestamp=' \
      || { echo "  no secure timestamp: ${m#$STAGE/} — notarisation would reject the submission" >&2; BAD=1; }
  done <<EOT
$(find "$STAGE/Everest.app" -type f -perm +111 2>/dev/null | while read -r f; do file "$f" | grep -q Mach-O && echo "$f"; done)
EOT
  [ "$BAD" = "0" ] || { echo "a binary in the bundle is not signed with the app identity: the updater would fail and notarisation would reject it" >&2; exit 1; }
  echo "  all bundle Mach-Os signed with $WANT, timestamped" >&2

  # The loop above now reaches the app too, via Contents/MacOS/Everest, which
  # codesign resolves to the enclosing bundle. This is kept because it is the
  # only check that prints what it actually saw, and a bare "team mismatch"
  # line from the loop is not enough to act on. APPDESC is also what the
  # Developer ID check below reads.
  APPDESC=$(codesign -dvvv "$STAGE/Everest.app" 2>&1)
  if ! printf '%s\n' "$APPDESC" | grep -q '^Timestamp='; then
    echo "the app has no secure timestamp: notarisation would reject it" >&2
    printf '%s\n' "$APPDESC" | grep -iE '^Authority=|^Timestamp|^Signed Time|^TeamIdentifier|flags=' | sed 's/^/    /' >&2
    exit 1
  fi

  # Developer ID is what notarisation accepts. An Apple Development cert
  # signs a build that runs here and is refused by the notary service, and
  # the difference is invisible until the submission comes back Invalid.
  #
  # Reuses the captured text rather than piping codesign into `grep -q`. See
  # the note on the allow-jit check below: under `pipefail` that pattern
  # reports failure at random.
  printf '%s\n' "$APPDESC" | grep -q '^Authority=Developer ID Application' \
    || { echo "not a Developer ID signature: this DMG cannot be notarised" >&2
         echo "set ALLOW_UNSIGNED_DMG=1 to build one anyway, for local testing only" >&2
         [ "${ALLOW_UNSIGNED_DMG:-0}" = "1" ] || exit 1; }

  # Assert the entitlement survived the re-sign above.
  #
  # `codesign --force` without `--entitlements` silently drops every one of
  # them, and the app is the last item in that loop. 0.2.2 through 0.2.4
  # shipped with Hardened Runtime on (flags=0x10000) and an empty
  # entitlement set, while every local build had `allow-jit` — so no amount
  # of testing the Xcode build could have shown it. Checked on the staged
  # app, which is the thing about to become the DMG.
  # **Capture first, then grep. Never pipe codesign straight into `grep -q`.**
  # `grep -q` exits on its first match and closes the pipe, codesign dies of
  # SIGPIPE, and `set -o pipefail` at the top of this file then reports the
  # whole pipeline as failed *because the match succeeded*. It is a race on
  # output buffering, so it passes on one run and fails on the next with no
  # change to the input: two of these gates flipped verdicts between two
  # consecutive runs on 2026-09-17. Piping from `printf` is safe because a
  # builtin writing a short string always finishes before grep exits.
  ENTS=$(codesign -d --entitlements - "$STAGE/Everest.app" 2>/dev/null || true)
  if ! printf '%s\n' "$ENTS" | grep -q "com.apple.security.cs.allow-jit"; then
    echo "allow-jit is missing from the signed app: Hardened Runtime is on, so MLX cannot JIT Metal shaders" >&2
    exit 1
  fi
  echo "  allow-jit present after signing" >&2
else
  echo "no Everest/Signing.local.xcconfig: signatures left alone, so Sparkle's helpers stay" >&2
  echo "ad-hoc, auto-update would fail, and the image cannot be notarised." >&2
  echo "set ALLOW_UNSIGNED_DMG=1 to build one anyway, for local testing only" >&2
  [ "${ALLOW_UNSIGNED_DMG:-0}" = "1" ] || exit 1
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
#
# **No backticks below, in comments either.** The delimiter is unquoted
# because the body interpolates $VOL and $STAGE, so bash expands backticks
# wherever they appear. Two markdown-style quotings in AppleScript comments
# ran as commands on every build: `bounds` printed "command not found", and
# `as string` reached /usr/bin/as, which is why a DMG build emitted clang
# errors about a missing file called "string".
SCPT="$STAGE/../dress.applescript"
cat > "$SCPT" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 716x524, NOT the background image's 700x500. Finder reports bounds
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
    -- as string on each number is required: in AppleScript, & applied to two
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

# Sign the disk image itself, not only the app inside it.
#
# Notarisation accepts an unsigned DMG whose contents are signed, so this is
# not what unblocks the notary. What it buys is that the thing the user
# actually downloads is tamper-evident on its own: without it, the only
# signature is on a bundle nobody can check until after they have opened the
# image. Apple's documented order is sign, notarise, staple, and stapling a
# signed DMG does not break the signature — the ticket goes to a reserved
# area of the image rather than into the signed payload.
if [ -n "$IDENTITY" ]; then
  if ! err=$(codesign --force --timestamp --sign "$IDENTITY" "$OUT" 2>&1); then
    echo "failed to sign the DMG" >&2
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    exit 1
  fi
  # Captured then grepped, never piped into `grep -q`. See the note on the
  # allow-jit check above for what that costs under pipefail.
  DMGDESC=$(codesign -dvvv "$OUT" 2>&1)
  printf '%s\n' "$DMGDESC" | grep -q '^Timestamp=' \
    || { echo "the DMG has no secure timestamp" >&2; exit 1; }
  codesign --verify --strict "$OUT" >/dev/null 2>&1 \
    || { echo "the DMG signature does not verify" >&2; exit 1; }
  echo "  DMG signed and verified" >&2
fi

echo "$OUT"
# **After any stapling, this hash is stale.** `xcrun stapler staple` rewrites
# the image, so the release-body sha256 and Sparkle's `length` and
# `edSignature` all have to be taken from the stapled file. See
# "Stapling comes before the appcast" in docs/RELEASING.md.
echo "  $(du -h "$OUT" | cut -f1)   sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)   (pre-staple)" >&2
