#!/usr/bin/env python3
"""Regenerate appcast.xml — the feed Sparkle reads to find new versions.

    python3 scripts/make_appcast.py <dir-of-release-dmgs>

Everything hard is done by Sparkle's own `generate_appcast`: EdDSA signing
against the private key in the login Keychain, file lengths, and the minimum
system version read out of each bundle. Getting any of those wrong by hand
means an update nobody can install, and the failure shows up on a stranger's
Mac rather than here.

The one thing it cannot do is our download URLs, for two reasons.

`generate_appcast` applies a single `--download-url-prefix` to every item, but
a GitHub release asset lives under its own tag, so the prefix differs per item.

And every release is uploaded under the **same** asset name, `Everest.dmg`,
which is what makes `/releases/latest/download/Everest.dmg` a permanent
download link for the website and the README — GitHub redirects it to the
newest release. The tag in the path is what keeps each appcast URL immutable:
`/releases/download/v0.1.2/Everest.dmg`. Local build artefacts keep their
versioned filenames so a folder can hold several for this tool to read, so the
filename in the URL has to be rewritten too, not just the prefix.

Both rewrites come from the version the item itself declares, read back out of
the generated XML rather than parsed from a filename, so a DMG named for a
version its bundle does not carry cannot produce a working entry.
"""

import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPO = "https://github.com/kabrapratik28/Everest"
PLACEHOLDER = "VERSION_TAG_PLACEHOLDER"
# Every release is uploaded under this one name. See the module docstring.
ASSET = "Everest.dmg"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "appcast.xml"


def find_tool() -> pathlib.Path:
    """`generate_appcast` ships inside Sparkle's SPM artifact bundle, so a
    build puts it in derived data. Searching beats hardcoding a path that
    changes with the Sparkle version."""
    roots = [pathlib.Path("/tmp/everest-archive"), pathlib.Path.home() / "Library/Developer/Xcode/DerivedData"]
    for r in roots:
        if not r.exists():
            continue
        for hit in r.glob("**/artifacts/sparkle/Sparkle/bin/generate_appcast"):
            return hit
    sys.exit(
        "generate_appcast not found. Build the app once (it arrives with the\n"
        "Sparkle package), or download Sparkle-for-Swift-Package-Manager.zip\n"
        "from https://github.com/sparkle-project/Sparkle/releases."
    )


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = pathlib.Path(sys.argv[1]).resolve()
    dmgs = sorted(folder.glob("*.dmg"))
    if not dmgs:
        sys.exit(f"no .dmg files in {folder}")

    tool = find_tool()
    print(f"using {tool}")
    for d in dmgs:
        print(f"  feeding {d.name}")

    subprocess.run(
        [
            str(tool),
            "--download-url-prefix",
            f"{REPO}/releases/download/{PLACEHOLDER}/",
            "--link",
            REPO,
            "-o",
            str(OUT),
            str(folder),
        ],
        check=True,
    )

    ET.register_namespace("sparkle", SPARKLE_NS)
    tree = ET.parse(OUT)
    rewritten, kept = 0, 0
    for item in tree.getroot().iter("item"):
        version = item.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
        enclosure = item.find("enclosure")
        if version is None or enclosure is None:
            sys.exit("an item has no shortVersionString or no enclosure; refusing to guess its URL")
        url = enclosure.get("url", "")
        if PLACEHOLDER in url:
            enclosure.set("url", f"{REPO}/releases/download/v{version}/{ASSET}")
            rewritten += 1
            continue
        # `generate_appcast` merges into an existing appcast.xml rather than
        # replacing it, so items from earlier releases come back already
        # rewritten. Those URLs point at assets that are published and
        # immutable — including ones uploaded under the older versioned
        # filename — so they are left exactly as they are. Only an unprefixed
        # URL is a real fault.
        if url.startswith(f"{REPO}/releases/download/"):
            kept += 1
            continue
        sys.exit(f"url is neither a placeholder nor a published release asset: {url}")

    tree.write(OUT, encoding="utf-8", xml_declaration=True)
    text = OUT.read_text()
    if PLACEHOLDER in text:
        sys.exit("placeholder survived the rewrite; the feed would 404")
    OUT.write_text(text)

    print(f"wrote {OUT.relative_to(ROOT)}, {rewritten} new item(s), {kept} kept")
    for url in re.findall(r'url="([^"]+)"', text):
        print(f"  {url}")


if __name__ == "__main__":
    main()
