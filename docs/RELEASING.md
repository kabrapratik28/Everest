# Releasing, and how users get updates

Everest is distributed outside the Mac App Store, because it cannot be in it:
sandboxed, `AXUIElementSetAttributeValue` does nothing and `AXIsProcessTrusted()`
is permanently false (root `AGENTS.md` §7). So distribution and updates are ours
to run.

## What Gatekeeper does

**Releases are Developer ID signed and notarised.** The Apple Developer
Program was joined on 2026-09-17, which removed the one-time Open Anyway step
the 0.1.x and 0.2.x builds required. A notarised build opens on a double
click, on a Mac that has never seen it, with no trip to System Settings.

The check, run on a machine that did not build the app:

```
$ spctl -a -vvv -t exec /Applications/Everest.app
/Applications/Everest.app: accepted
source=Notarized Developer ID
```

**`accepted` and `source=Notarized Developer ID` are both required.** A
Developer ID signature alone gets `accepted` from `spctl` on the machine that
holds the certificate and is still refused on a stranger's, which is the exact
shape of bug that only a second Mac finds. *(Not yet measured — the first
notarised build has not been cut. This is the check that closes it, and this
paragraph gets a measurement stamp when it has been run.)*

**What the old certificate leaked.** An Apple Development designated
requirement embeds the certificate's common name, which for that type is the
Apple ID it was issued to — an email address that anyone who downloaded a
release could read with `codesign -d -r-`. Developer ID carries the account
holder's name and keys the requirement on the team identifier instead. The
email is out; a legal name is in. *(Measured 2026-09-15 on the 0.1.0 build.)*

**Ad-hoc is still not an option for a release, for a second reason.** macOS
binds Accessibility to the designated requirement, and an ad-hoc DR is a
content hash, so every update would silently revoke the permission the app
cannot work without. Developer ID keys the DR on the team identifier, which
survives rebuilds and certificate renewals. Notarisation is about Gatekeeper;
this is about TCC; both point the same way.

A clean clone still builds ad-hoc with no certificate and no Apple account.
That is deliberate and documented in `Everest/Signing.xcconfig`. Only a
release needs the Developer ID identity, and it comes from the untracked
`Everest/Signing.local.xcconfig`.

**The tension with CI.** Building releases from public source via GitHub
Actions is good for trust, and it conflicts with the above: CI cannot sign
without the certificate and its password in repository secrets, and it cannot
notarise without the App Store Connect credentials too. An unsigned CI build
brings back the per-build cdhash. Pick one — reproducibility or a working
install — or sign and notarise locally and let CI only verify.

## Versioning

`project.yml` holds both numbers:

- `MARKETING_VERSION` — what users see. Semantic: `1.0.0`, `1.0.1`, `1.1.0`.
- `CURRENT_PROJECT_VERSION` — a monotonic build number. **Must increase on
  every release**; Sparkle compares it, not the marketing string.

`project.yml` is at `0.2.5` / `10`, unreleased. The public release and
`appcast.xml` are still on `0.2.4` / `9` and stay there until the exact 0.2.5
bytes pass every check in step 5.

## Cutting a release

One-time setup, before the first notarised release:

```bash
# The Developer ID cert's SHA-1, from `security find-identity -v -p codesigning`.
# The SHA-1, not the name — Signing.xcconfig explains why.
echo 'CODE_SIGN_IDENTITY = <sha1>' > Everest/Signing.local.xcconfig

# notarytool credentials, stored in the login Keychain under the profile name
# the recipe below uses. The password is an app-specific password from
# appleid.apple.com, never the account password. Done once, on 2026-09-17.
#
# The profile name needs three characters or more; notarytool rejects a
# shorter one with "Profile name must be at least 3 characters", which is why
# this is not the two-letter name the recipe used to carry.
xcrun notarytool store-credentials "everest" \
  --apple-id kabrapratik28@gmail.com --team-id 4Z892PQN29 --password <app-specific>
```

Then, per release:

```bash
# 1. Bump both numbers in project.yml, commit.

# 2. Release build. A separate derived-data path, so a Debug build sitting in
#    the normal one cannot be mistaken for the artefact.
xcodebuild -project Everest.xcodeproj -scheme Everest -configuration Release \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  -derivedDataPath /tmp/everest-archive build

# 3. Sign and package. make_dmg.sh re-signs Sparkle's nested helpers inside-out
#    with the identity from Signing.local.xcconfig, because the build leaves
#    them ad-hoc, then signs the finished disk image too. It asserts four
#    things that are each invisible until a user hits them: every Mach-O in
#    the bundle carries the app's team, every one carries a secure timestamp,
#    allow-jit survived the re-sign, and the DMG's own signature verifies.
#    The sha256 it prints is marked pre-staple, because step 4 changes it.
#    No `| head -1`. The script writes progress to stderr and the path is the
#    only thing on stdout, so this captures it whole. It used to pipe into
#    `head -1`, which grabbed the first progress line instead of the path and
#    closed the pipe under the script's feet.
DMG=$(./scripts/make_dmg.sh \
  /tmp/everest-archive/Build/Products/Release/Everest.app)

# 4. Notarise TWICE: the app, then the DMG. Both get stapled.
#
#    Why the app as well. Stapling the DMG puts a ticket on the container,
#    not on the bundle the user drags out of it, so an app copied to
#    /Applications has no ticket of its own and Gatekeeper falls back to an
#    online check. That is invisible to anyone with a network and a hard
#    failure for a first launch without one.
#
#    Why it costs almost nothing. `stapler` fetches the ticket from Apple by
#    cdhash, so the second notarisation is a lookup, not a re-scan: measured
#    at under a minute each on 2026-09-17, against 78 minutes for the very
#    first submission this team ever made. That first one is a one-off.
#
#    **A stapled ticket does not survive re-signing.** codesign rewrites the
#    bundle, the cdhash changes, and the ticket stops matching, which is why
#    step 4c packages with SKIP_APP_SIGNING=1. Running make_dmg.sh normally
#    here would silently discard the ticket step 4b just added, and every
#    later check would still pass.

# 4a. Notarise the app that is already inside the DMG from step 3.
MP=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -oE '/Volumes/.*' | head -1)
rm -rf /tmp/appstage && mkdir -p /tmp/appstage
cp -R "$MP/Everest.app" /tmp/appstage/ && hdiutil detach "$MP" -quiet
ditto -c -k --keepParent /tmp/appstage/Everest.app /tmp/Everest-app.zip
xcrun notarytool submit /tmp/Everest-app.zip --keychain-profile "everest" --wait

# 4b. Staple the app. No re-notarisation: the ticket is looked up by cdhash.
xcrun stapler staple /tmp/appstage/Everest.app
xcrun stapler validate /tmp/appstage/Everest.app

# 4c. Repackage around the stapled app, signing the image but NOT the app.
#     make_dmg.sh refuses this flag unless the app really is stapled.
DMG=$(SKIP_APP_SIGNING=1 ./scripts/make_dmg.sh /tmp/appstage/Everest.app)

# 4d. Notarise and staple the finished image.
xcrun notarytool submit "$DMG" --keychain-profile "everest" --wait
xcrun stapler staple "$DMG"

#    On `Invalid`, this prints the per-binary reason. Nothing else does.
#    xcrun notarytool log <submission-id> --keychain-profile "everest"

# 5. Verify. Both tickets, because they are two separate staples and either
#    can be missing on its own.
xcrun stapler validate "$DMG"

#    Then mount and check the app, because that is what the user launches.
#    spctl answers the user's question; codesign only says the signature is
#    intact. Both, because they fail independently.
MP=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -oE '/Volumes/.*' | head -1)
spctl -a -vvv -t exec "$MP/Everest.app"   # must say: accepted, Notarized Developer ID
codesign -v --deep --strict "$MP/Everest.app"
codesign -d -r- "$MP/Everest.app"         # DR names the team id, not an email
xcrun stapler validate "$MP/Everest.app"
hdiutil detach "$MP"

#    Post-staple, so it matches the published bytes. The hash make_dmg.sh
#    printed is the pre-staple one and is already wrong by here.
shasum -a 256 "$DMG"                      # goes in the release body

# 6. Regenerate the feed — AFTER stapling, never before. See "Stapling comes
#    before the appcast" below; getting this backwards ships an update that
#    every installed copy refuses.
mkdir -p /tmp/everest-dist && cp "$DMG" /tmp/everest-dist/
python3 scripts/make_appcast.py /tmp/everest-dist

# 7. Publish. gh creates the tag from HEAD.
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

# 8. Prove the public URL serves the bytes you built, as an anonymous
#    downloader. Checking the release page is not the same thing.
curl -sL -o /tmp/verify.dmg \
  https://github.com/kabrapratik28/Everest/releases/latest/download/Everest.dmg
shasum -a 256 /tmp/verify.dmg
```

**Naming.** `Everest_<version>_aarch64.dmg` locally, matching the convention
most Mac-only Apple-Silicon projects use; published as `Everest.dmg` for the
reason step 7 gives.

### Stapling comes before the appcast

**`xcrun stapler staple` rewrites the DMG.** The ticket is written into the
file, so the byte length changes and so does every signature over those bytes.

Sparkle ships the DMG itself as the update archive — `appcast.xml` carries a
`length` and a `sparkle:edSignature` computed over the file — so an appcast
generated from the unstapled DMG describes a file that no longer exists. Every
installed copy then downloads the published DMG, computes a signature that
does not match the feed, and refuses the update. It fails on the user's
machine, silently, and the release looks fine from here.

So the order is fixed: **build → notarise → staple → appcast → publish.** The
recipe above is in that order and step 6 says so. Nothing else in the release
depends on the order, which is what makes this easy to get wrong.

Stapling also matters on its own: without it, a first launch with no network
cannot reach Apple to check the ticket.

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

**Push `appcast.xml` last, after the release asset is public.** The two
halves of this used to contradict each other: the instruction said "before or
with the release" and the very next sentence gave the reason that rules it
out. A feed pointing at an asset that does not exist yet offers every
installed copy an update that 404s.

Generating and pushing are separate steps with different constraints, which
is what makes this easy to get wrong. **Generate** after stapling, because the
signature covers the stapled bytes. **Push** after the GitHub asset is live,
because that is the URL the feed names. A draft release works too, as long as
the asset is public before the feed item is.

**Sparkle allows the certificate change, as long as the EdDSA key does not
move with it.** `SUUpdateValidator.validateUpdateForHost` accepts an update if
*either* the EdDSA signature verifies against the old public key *or* the new
code signature matches the old one — "we allow failure of one of them, because
this allows key rotation without breaking chain of trust". Moving from Apple
Development to Developer ID fails the code-signing half and passes on EdDSA,
so the update installs. **Rotate the EdDSA key in the same release and both
halves fail at once**, which strands every installed copy with no way back but
a manual download. Change one or the other, never both.

**The first Developer ID update revokes Accessibility.** macOS keys TCC to the
designated requirement, and that requirement changes with the certificate, so
the grant goes and the switch in System Settings stays on while
`AXIsProcessTrusted()` returns false. The app already handles it:
`OnboardingModel.opensAtLaunch` reopens a finished guide when the grant is
missing and `rewindForLostPermission()` lands it on the Accessibility step,
both covered in `OnboardingModelTests`. **Not a migration problem in
practice** — as of 2026-09-17 there are no installed users to migrate, which
is the cheapest moment this change will ever have. See `docs/MANUAL-CHECKS.md`
for the update rehearsal.

**0.1.0 cannot self-update.** It predates Sparkle, so anyone on it has to
download 0.1.1 by hand. That is one release's worth of users and the README
says so.

## Outstanding, now that v0.1.0 is public

Shipped before these were done, deliberately, to find out whether anyone
wants the thing. In rough order of what a real user hits first:

- **A first-run pass on a Mac that has never run Everest.** The download
  path and the Accessibility prompt are invisible on a machine that already
  has the weights and the grant. This is the one with the highest chance of a
  plain embarrassment in it, and notarisation has not removed it — it removed
  one step inside it.
- **No notarised build has been launched on second hardware.** `spctl` must
  answer `accepted` with `source=Notarized Developer ID` there, not here. The
  machine holding the certificate is the one machine that cannot tell you.
- **The first Sparkle update across the certificate change has not been
  rehearsed.** It should install (EdDSA carries it) and it should drop
  Accessibility (the DR moves). Both predicted, neither observed.
- Everything in `docs/PUNCH-LIST.md` and the P0s in `docs/EXTERNAL-AUDIT.md`.
- The open questions in `docs/OPEN-DECISIONS.md`; two of them change defaults
  that are awkward to reverse once strangers are running the app.
