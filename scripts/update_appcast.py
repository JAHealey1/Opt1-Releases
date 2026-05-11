#!/usr/bin/env python3
"""Insert a new <item> into Opt1's Sparkle appcast.xml.

Sparkle's appcast is RSS 2.0 with the `sparkle:` namespace. We avoid
`generate_appcast` (which scans a directory of DMGs) because our DMG lives
on a GitHub Release URL — generate_appcast can't reach it. Instead we
hand-roll the <item> from CI inputs.

The script is idempotent on `version`: invoking it twice with the same
sparkle:shortVersionString replaces the existing item rather than
duplicating it. That keeps reruns of the workflow safe.

Usage:
    update_appcast.py 1.0.1 \
        --build 2 \
        --length 12345678 \
        --signature 'BASE64==' \
        --appcast /path/to/Opt1-Releases/appcast.xml \
        [--notes-url https://raw.githubusercontent.com/.../release-notes/1.0.1.html] \
        [--release-url https://github.com/JAHealey1/Opt1-Releases/releases/download/v1.0.1/Opt1-1.0.1.dmg] \
        [--min-os 14.0]
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

DEFAULT_TITLE = "Opt1"
# Used both as the channel <link> (what Sparkle / RSS readers consider the
# "home" of the feed) and as <sparkle:fullReleaseNotesLink> on every item
# (the destination of the "Version History" button shown on the Sparkle
# "You're up to date" alert). GitHub's Releases UI is the right target —
# it's already a properly-rendered changelog with per-release bodies,
# attached assets, and dates.
FULL_RELEASE_NOTES_URL = "https://github.com/JAHealey1/Opt1-Releases/releases"
DEFAULT_LINK = FULL_RELEASE_NOTES_URL
DEFAULT_DESCRIPTION = "Most recent updates to Opt1."
DEFAULT_LANGUAGE = "en"
RELEASE_URL_TEMPLATE = (
    "https://github.com/JAHealey1/Opt1-Releases/releases/download/v{version}/Opt1-{version}.dmg"
)

# Sentinel used to round-trip CDATA-wrapped HTML through ElementTree (which
# does not natively support CDATA sections). We substitute this token in for
# the raw HTML during tree manipulation, then swap it back to a real
# <![CDATA[ ... ]]> block in the on-disk file so the rendered appcast stays
# diff-friendly. Sparkle parses both forms identically — the wrapper is
# purely a readability concession for humans inspecting the feed.
CDATA_TOKEN_PREFIX = "__OPT1_APPCAST_CDATA_TOKEN__"


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def empty_or_missing(path: Path) -> bool:
    return not path.exists() or path.stat().st_size == 0


def is_effectively_empty(path: Path) -> bool:
    """True if the file has no real XML content yet.

    Catches the common bootstrap case where someone has committed an empty
    `appcast.xml` placeholder (zero bytes, just whitespace, or only an XML
    declaration / a comment) so the first release can write the real channel
    skeleton without us erroring out.
    """
    if empty_or_missing(path):
        return True
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        return True
    if text.startswith("<?xml"):
        end = text.find("?>")
        if end != -1:
            text = text[end + 2 :].strip()
    while text.startswith("<!--"):
        end = text.find("-->")
        if end == -1:
            break
        text = text[end + 3 :].strip()
    return not text


def build_root() -> ET.ElementTree:
    """Build a fresh appcast skeleton when the on-disk file is empty/missing."""
    # ElementTree emits the xmlns:sparkle declaration automatically because we
    # called ET.register_namespace above; setting it manually duplicates the
    # attribute on the root, which makes the file un-reparseable.
    rss = ET.Element("rss", attrib={"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = DEFAULT_TITLE
    ET.SubElement(channel, "link").text = DEFAULT_LINK
    ET.SubElement(channel, "description").text = DEFAULT_DESCRIPTION
    ET.SubElement(channel, "language").text = DEFAULT_LANGUAGE
    return ET.ElementTree(rss)


def load_or_init(path: Path) -> ET.ElementTree:
    if is_effectively_empty(path):
        print(f"appcast at {path} is empty, initialising a fresh skeleton.")
        return build_root()
    try:
        return ET.parse(path)
    except ET.ParseError as exc:
        # A genuine parse error on a non-empty file means an existing release
        # history could be lost if we just rebuild from scratch, so fail loud.
        print(f"Failed to parse existing appcast at {path}: {exc}", file=sys.stderr)
        sys.exit(2)


def make_item(args: argparse.Namespace, cdata_payloads: list[str]) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "pubDate").text = pub_date
    ET.SubElement(item, sparkle("version")).text = str(args.build)
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.min_os

    # Inline the rendered release-notes HTML inside <description>. We *don't*
    # emit <sparkle:releaseNotesLink> here — Sparkle prefers the link over
    # the inline description when both are present, and GitHub's raw URLs
    # serve every file as text/plain with X-Content-Type-Options: nosniff,
    # which makes Sparkle's WKWebView display the HTML as raw source. Inline
    # HTML side-steps the hosting question entirely.
    notes_html = Path(args.notes_html).read_text(encoding="utf-8")
    token = f"{CDATA_TOKEN_PREFIX}{len(cdata_payloads)}__"
    cdata_payloads.append(notes_html)
    ET.SubElement(item, "description").text = token

    # The "Version History" button on Sparkle's up-to-date alert opens this
    # URL; without it, Sparkle falls back to the per-update notes — which we
    # no longer link, so the button would dead-end.
    ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = FULL_RELEASE_NOTES_URL
    release_url = args.release_url or RELEASE_URL_TEMPLATE.format(version=args.version)
    ET.SubElement(
        item,
        "enclosure",
        attrib={
            "url": release_url,
            sparkle("edSignature"): args.signature,
            "length": str(args.length),
            "type": "application/octet-stream",
        },
    )
    return item


def upsert_item(channel: ET.Element, new_item: ET.Element, version: str) -> None:
    """Replace an existing <item> with the same shortVersionString, or prepend."""
    for existing in list(channel.findall("item")):
        short = existing.find(sparkle("shortVersionString"))
        if short is not None and (short.text or "") == version:
            channel.remove(existing)
    insert_index = 0
    for idx, child in enumerate(list(channel)):
        if child.tag in {"title", "link", "description", "language"}:
            insert_index = idx + 1
        else:
            break
    channel.insert(insert_index, new_item)


def backfill_channel_metadata(channel: ET.Element) -> None:
    """Bring a previously-published channel up to the current schema.

    Older releases were emitted with the channel <link> pointing at the raw
    appcast.xml URL and without sparkle:fullReleaseNotesLink on each item.
    Apply both fixes idempotently every time we publish so existing items
    benefit retroactively (Sparkle reads fullReleaseNotesLink off the most
    recent matching item).
    """
    link = channel.find("link")
    if link is not None and (link.text or "") != DEFAULT_LINK:
        link.text = DEFAULT_LINK

    full_tag = sparkle("fullReleaseNotesLink")
    for item in channel.findall("item"):
        existing = item.find(full_tag)
        if existing is None:
            ET.SubElement(item, full_tag).text = FULL_RELEASE_NOTES_URL
        elif (existing.text or "") != FULL_RELEASE_NOTES_URL:
            existing.text = FULL_RELEASE_NOTES_URL


def write_appcast(tree: ET.ElementTree, path: Path, cdata_payloads: list[str]) -> None:
    """Write the appcast, restoring CDATA wrappers for any embedded HTML.

    ElementTree escapes element text on serialisation, so each <description>
    points at a placeholder token while the tree is in memory. We render to
    a string, swap each token for its original HTML wrapped in
    <![CDATA[ ... ]]>, and write the result. Sparkle treats the two forms
    identically; CDATA simply keeps the on-disk diff readable.
    """
    ET.indent(tree, space="  ")
    raw = ET.tostring(tree.getroot(), encoding="unicode")
    for index, html in enumerate(cdata_payloads):
        token = f"{CDATA_TOKEN_PREFIX}{index}__"
        # CDATA cannot itself contain "]]>" — the only safe split is to
        # close the section, emit the literal sequence, and reopen.
        safe_html = html.replace("]]>", "]]]]><![CDATA[>")
        cdata = f"<![CDATA[{safe_html}]]>"
        raw = raw.replace(token, cdata, 1)

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("<?xml version='1.0' encoding='UTF-8'?>\n")
        handle.write(raw)
        if not raw.endswith("\n"):
            handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="Semver shortVersionString, e.g. 1.0.1")
    parser.add_argument("--build", required=True, type=int,
                        help="Integer CFBundleVersion / sparkle:version (must increase per release)")
    parser.add_argument("--length", required=True, type=int, help="DMG size in bytes")
    parser.add_argument("--signature", required=True, help="Base64 EdDSA signature from sign_update")
    parser.add_argument("--appcast", required=True, type=Path,
                        help="Path to appcast.xml in a clone of Opt1-Releases")
    parser.add_argument("--notes-html", required=True, type=Path,
                        help="Path to the rendered release-notes HTML to inline as <description>")
    parser.add_argument("--release-url", default=None,
                        help="Override the DMG download URL")
    parser.add_argument("--min-os", default="14.0",
                        help="Minimum macOS version (default: 14.0)")
    args = parser.parse_args()

    if not args.notes_html.is_file():
        print(f"Rendered release-notes HTML not found at {args.notes_html}", file=sys.stderr)
        return 2

    tree = load_or_init(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("Existing appcast.xml has no <channel> element", file=sys.stderr)
        return 2

    cdata_payloads: list[str] = []
    upsert_item(channel, make_item(args, cdata_payloads), args.version)
    backfill_channel_metadata(channel)

    write_appcast(tree, args.appcast, cdata_payloads)
    print(f"Wrote {args.appcast} (version {args.version}, build {args.build}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
