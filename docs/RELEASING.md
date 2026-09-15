# Releasing, and how users get updates

Everest is distributed outside the Mac App Store, because it cannot be in it:
sandboxed, `AXUIElementSetAttributeValue` does nothing and `AXIsProcessTrusted()`
is permanently false (root `AGENTS.md` §7). So distribution and updates are ours
to run.

## What Gatekeeper does today

The signing certificate on this machine is `Apple Development`. Measured:

```
$ spctl -a -vvv -t exec /Applications/Everest.app
/Applications/Everest.app: rejected
origin=Apple Development: <your name> (<team id>)
```

`rejected` is what every downloader hits. It does **not** mean the app cannot
be distributed — it means the user must approve it once by hand. Whether that
is acceptable is the $0 question below, not a technical blocker.

**One thing the `rejected` line also gives away.** The designated requirement
embeds the certificate's common name, and for an Apple Development certificate
that is the Apple ID it was issued to — an email address. Anyone who downloads
a release can read it with `codesign -d -r-`. Nothing in the build can strip
it; only a different certificate changes it, and a Developer ID Application
certificate carries the account holder's name instead. Worth knowing before a
public release, and a second reason the $99 question is not purely cosmetic.
*(Measured 2026-09-15 on the shipping build.)*

## The $0 route, and the one thing it must not get wrong

Launching free on GitHub Releases is viable and is the right first move: it
tests whether anyone wants this before spending anything. Developers are used
to it. macOS will say "Apple could not verify Everest is free of malware", and
the user goes to **System Settings ▸ Privacy & Security ▸ Open Anyway** once.
Since macOS 15 the old right-click-Open shortcut is gone, so that pane is the
only path — the README must say so in those words.

**But the build must be signed with the Apple Development certificate, not
ad-hoc.** This is specific to Everest and it is not optional. Measured:

```
Development-signed:  identifier "com.kabrapratik.Everest" and anchor apple
                     generic and certificate leaf[subject.CN] = "Apple
                     Development: …"                              ← stable
ad-hoc (codesign -s -):  cdhash H"f8c78ba8…"                      ← per build
```

macOS binds Accessibility permission to the designated requirement. An ad-hoc
DR is a content hash, so **every update would silently revoke the permission
the app cannot work without**, and the user would have to find it in System
Settings again each time. A Development-signed DR is identifier plus
certificate, which survives rebuilds and renewals. Gatekeeper still refuses it
without notarisation — that is the one-time Open Anyway — but TCC accepts it.

**Untested and worth checking before any public release:** that a
Development-signed build runs at all on a Mac that is not this one. The
signature is valid and Open Anyway should cover it, but development
certificates are not intended for distribution and this has not been
confirmed on second hardware.

**The tension with CI.** Building releases from public source via GitHub
Actions is good for trust, and it conflicts with the above: CI cannot sign
with the Development certificate unless the certificate and its password go
into repository secrets. An unsigned CI build brings back the per-build
cdhash. Pick one — reproducibility or a stable permission grant — or sign
locally and let CI only verify.

### Guiding the user through it

Nothing in the app can help before first launch, because Gatekeeper prevents
the app from running at all. The only surfaces that exist at that moment are
the download page and the disk image. So:

- **A `.dmg` with a background image** showing "drag to Applications" and the
  three Open Anyway steps. This is the only in-install guidance possible.
- **Release notes and README** repeating it in the same words macOS uses, so
  the sentence the user sees on screen matches the one they were given.

Everything after that first launch is already handled: onboarding walks
through the Accessibility grant and polls for it, so the user is not left
guessing.

### When $99 becomes worth it

When the Open Anyway step costs more in lost users than the fee. At a few
hundred installs that is plausible; before the first one it is not. Note the
fee is not avoidable later by open-sourcing — Apple's waiver covers
nonprofits, accredited schools and government, not individual open-source
developers.

## Versioning

`project.yml` holds both numbers:

- `MARKETING_VERSION` — what users see. Semantic: `1.0.0`, `1.0.1`, `1.1.0`.
- `CURRENT_PROJECT_VERSION` — a monotonic build number. **Must increase on
  every release**; Sparkle compares it, not the marketing string.

Currently `0.1.0` / `1`, shipped as `v0.1.0` on 2026-09-15.

## Cutting a release

This is what actually ran for `v0.1.0` on 2026-09-15. No notarisation, no
`create-dmg`; `hdiutil` is in the OS and does the job.

```bash
# 1. Bump both numbers in project.yml, commit.

# 2. Release build. A separate derived-data path, so a Debug build sitting in
#    the normal one cannot be mistaken for the artefact.
xcodebuild -project Everest.xcodeproj -scheme Everest -configuration Release \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  -derivedDataPath /tmp/everest-archive build

# 3. Stage the app next to an /Applications symlink — that is the whole of the
#    drag-to-install layout.
APP=/tmp/everest-archive/Build/Products/Release/Everest.app
rm -rf /tmp/everest-dmg && mkdir -p /tmp/everest-dmg
cp -R "$APP" /tmp/everest-dmg/
ln -s /Applications /tmp/everest-dmg/Applications
hdiutil create -volname "Everest 0.1.0" -srcfolder /tmp/everest-dmg \
  -ov -format UDZO /tmp/Everest_0.1.0_aarch64.dmg

# 4. Verify the signature survived packaging, by mounting the DMG rather than
#    by trusting the build. hdiutil is not a signing operation, but this is
#    cheap and a broken signature here is invisible until a user hits it.
MP=$(hdiutil attach -nobrowse -readonly /tmp/Everest_0.1.0_aarch64.dmg \
  | grep -oE '/Volumes/.*' | head -1)
codesign -v --deep --strict "$MP/Everest.app"
codesign -d -r- "$MP/Everest.app"        # DR must match the installed app's
hdiutil detach "$MP"

shasum -a 256 /tmp/Everest_0.1.0_aarch64.dmg   # goes in the release body

# 5. Publish. gh creates the tag from HEAD.
#    ONE asset, and always under the same name: Everest.dmg. That is what
#    makes
#      /releases/latest/download/Everest.dmg
#    a permanent download link — GitHub redirects it to the newest release,
#    so a website CTA and the README button never need editing for a
#    release. The tag in
#      /releases/download/v<version>/Everest.dmg
#    is what keeps each appcast URL immutable, so one asset serves both
#    purposes and nothing is duplicated. The local build keeps a versioned
#    filename only so /tmp/everest-dist can hold several of them for
#    make_appcast.py to read.
cp /tmp/Everest_<version>_aarch64.dmg /tmp/Everest.dmg
gh release create v<version> /tmp/Everest.dmg \
  --title "Everest <version>" --notes-file notes.md

# 6. Prove the public URL serves the bytes you built, as an anonymous
#    downloader. Checking the release page is not the same thing.
curl -sL -o /tmp/verify.dmg \
  https://github.com/kabrapratik28/Everest/releases/download/v0.1.0/Everest_0.1.0_aarch64.dmg
shasum -a 256 /tmp/verify.dmg
```

**Naming.** `Everest_<version>_aarch64.dmg`, matching the convention most
Mac-only Apple-Silicon projects use, so the download URL is guessable and a
script can construct it.

**Still missing from the DMG:** a background image showing "drag to
Applications" and the three Open Anyway steps. `hdiutil` produces a plain
volume window; the background needs artwork plus AppleScript window
positioning, or `create-dmg`. "Guiding the user through it" above argues this is
the only in-install guidance possible, so it is worth doing before the
release is promoted anywhere.

### When notarisation exists

Steps 2 and 3 change: build signed with **Developer ID Application** and
Hardened Runtime on (`com.apple.security.cs.allow-jit` is already required by
MLX), then before packaging:

```bash
xcrun notarytool submit Everest.zip --keychain-profile "AC" --wait
xcrun stapler staple Everest.app
```

Stapling matters — without it a first launch offline fails the check. Then
`spctl -a -vvv -t exec` must say **accepted** on a Mac that has never built
the app, and the Open Anyway paragraph comes out of the README and the
release notes.

## Automatic updates — Sparkle

Shipped in 0.1.1. `SPUStandardUpdaterController` is held for the process
lifetime in `AppDelegate` — it *is* the scheduler, so a per-check instance
would be deallocated before any background check ran and only the menu item
would work. Sparkle would normally install its own menu item, but only into
an app menu, which an `LSUIElement` app does not have; the status-item
dropdown carries **Check for Updates…** instead.

**The feed** is `appcast.xml` in the repository's default branch, served over
HTTPS by `raw.githubusercontent.com`. GitHub Pages would also work and would
also be free; this needs no second deployment target that can quietly stop
publishing. `SUFeedURL` and `SUPublicEDKey` live in `project.yml`'s `info:`
block, one home each.

**The key.** An EdDSA pair generated by Sparkle's `generate_keys`. The
private half is in the login Keychain and is never committed; the public half
is in `Info.plist`. This is the entire security model — Sparkle refuses any
update whose signature does not verify, so neither a compromised feed nor a
compromised release host can ship code. **Losing the private key means no
installed build can ever be updated again**, because a replacement key is not
trusted by anything already out there. Back it up wherever the rest of your
credentials live.

**Regenerating the feed** after building a DMG:

```bash
mkdir -p /tmp/everest-dist && cp /tmp/Everest_<version>_aarch64.dmg /tmp/everest-dist/
python3 scripts/make_appcast.py /tmp/everest-dist
```

Sparkle's `generate_appcast` does the signing, lengths and minimum system
version. It applies one `--download-url-prefix` to every item, which a GitHub
release cannot use because each asset sits under its own tag, so the script
runs it with a placeholder and rewrites each URL from the version that item
declares. Keep the DMGs you want in the feed in that folder — the tool
regenerates from the whole directory, it does not append.

Push `appcast.xml` before or with the release. A feed pointing at an asset
that does not exist yet offers an update that 404s.

**Untested and worth checking on the first real update:** Accessibility
permission is bound to the code signature and a Sparkle update replaces the
bundle. Re-signing with the same certificate keeps the designated requirement
stable, so the grant should survive — but a silent permission loss after an
auto-update is the worst possible first impression. See
`docs/MANUAL-CHECKS.md`.

**0.1.0 cannot self-update.** It predates Sparkle, so anyone on it has to
download 0.1.1 by hand. That is one release's worth of users and the README
says so.

## Outstanding, now that v0.1.0 is public

Shipped before these were done, deliberately, to find out whether anyone
wants the thing. In rough order of what a real user hits first:

- **A first-run pass on a Mac that has never run Everest.** The download
  path, the Accessibility prompt and Open Anyway are all invisible on a
  machine that already has the weights and the grant. This is the one with
  the highest chance of a plain embarrassment in it.
- **A Development-signed build has never been launched on second hardware.**
  The signature is valid and Open Anyway should cover it, but development
  certificates are not meant for distribution and this is untested.
- **A DMG background** with the drag-to-Applications and Open Anyway steps.
- `Developer ID Application` certificate and notarisation, which removes the
  Open Anyway step and takes the maintainer's email address out of the
  designated requirement. Measured on `v0.1.0`: the DR names
  `Apple Development: <email>`, and anyone who downloads the DMG can read it
  with `codesign -d -r-`. A Developer ID certificate carries the account
  holder's name instead and keys the DR on the team ID.
- Everything in `docs/PUNCH-LIST.md` and the P0s in `docs/EXTERNAL-AUDIT.md`.
- The open questions in `docs/OPEN-DECISIONS.md`; two of them change defaults
  that are awkward to reverse once strangers are running the app.
