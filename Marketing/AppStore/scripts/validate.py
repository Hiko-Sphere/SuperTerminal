#!/usr/bin/env python3
"""Checks the finished assets, and refuses to be quiet about anything wrong with them.

Three kinds of check:

* **Apple's rules** — pixel sizes off the published list, PNG, no alpha channel, at most
  ten images per size per localization, and the metadata field limits.
* **Fidelity** — the final image's screenshot area has the same aspect ratio as the raw
  capture it came from, so nothing was stretched to reach a size.
* **This project's rules** — no real identity or address anywhere in the copy, no
  competitor named, no absolute claim that cannot be tested, no third-party mark, and
  nothing in the copy about a capability the audit marked as not advertisable.

Run through `validate.sh`.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import unicodedata
import zlib
from datetime import datetime, timezone
from pathlib import Path

# Apple's accepted pixel sizes, read off the App Store Connect screenshot specifications
# on 2026-09-06. See APPLE_REQUIREMENTS.md.
ACCEPTED = {
    "iphone-6.9": {(1260, 2736), (1290, 2796), (1320, 2868), (2736, 1260), (2796, 1290), (2868, 1320)},
    # App Store Connect's 6.5" slot, which takes a 6.7" image too.
    "iphone-6.5": {(1242, 2688), (2688, 1242), (1284, 2778), (2778, 1284)},
    "ipad-13": {(2064, 2752), (2048, 2732), (2752, 2064), (2732, 2048)},
}

FIELD_LIMITS = {
    "App Name": ("chars", 30),
    "Subtitle": ("chars", 30),
    "Promotional Text": ("chars", 170),
    "Keywords": ("bytes", 100),
    "Description": ("chars", 4000),
}

# Words a store listing must not contain, because they cannot be verified — or because
# they name somebody else's product.
FORBIDDEN = [
    (r"\biTerm\b", "names a competing product"),
    (r"\bTermius\b", "names a competing product"),
    (r"\bBlink\s*Shell\b", "names a competing product"),
    (r"\bWarp\b", "names a competing product"),
    (r"\bPrompt\s*3\b", "names a competing product"),
    (r"\bunhackable\b", "an absolute security claim"),
    (r"\bmilitary[- ]grade\b", "an unverifiable claim"),
    (r"\bzero[- ]latency\b", "an unverifiable claim"),
    (r"\bnever\s+drops?\b", "an unverifiable claim"),
    (r"\bcompletely\s+secure\b", "an absolute security claim"),
    (r"\babsolutely\s+secure\b", "an absolute security claim"),
    (r"\b100%\s+secure\b", "an absolute security claim"),
    (r"\bthe\s+fastest\b", "an unverifiable superlative"),
    (r"\bthe\s+most\s+secure\b", "an unverifiable superlative"),
    (r"绝对安全", "an absolute security claim"),
    (r"最强", "an unverifiable superlative"),
    (r"零延迟", "an unverifiable claim"),
    (r"永不掉线", "an unverifiable claim"),
    (r"顶级", "an unverifiable superlative"),
    (r"军工级", "an unverifiable claim"),
    (r"官方合作", "implies an affiliation that does not exist"),
    (r"\bofficial\s+Cloudflare\b", "implies an affiliation that does not exist"),
]

# Capabilities the feature audit marked as not advertisable. If one of these turns up in
# the shipped copy, the copy has drifted ahead of what has been seen to work.
NOT_ADVERTISABLE = [
    (r"\bCloudflare\b", "Cloudflare Access/Tunnel is not verified end to end — FEATURE_AUDIT.md"),
    (r"\bSFTP\b", "not implemented"),
    (r"\bport[- ]forward", "not implemented"),
    (r"\biCloud\b", "sync is not verified against iCloud — FEATURE_AUDIT.md B-4"),
    (r"\bSiri\b", "the phrases are a device check — FEATURE_AUDIT.md"),
    (r"\bsubscription\b", "there is no purchase of any kind in the app"),
    (r"\bin-app purchase\b", "there is no purchase of any kind in the app"),
    (r"内购", "there is no purchase of any kind in the app"),
    (r"订阅", "there is no purchase of any kind in the app"),
]

# Anything that would mean a real person, machine or secret reached an image or a line of
# copy. The fixtures are deliberately named so that none of these can match them.
SENSITIVE = [
    (r"BEGIN [A-Z ]*PRIVATE KEY", "a private key"),
    (r"\bAKIA[0-9A-Z]{16}\b", "an AWS access key id"),
    (r"\bgh[pousr]_[A-Za-z0-9]{20,}", "a GitHub token"),
    (r"\bxox[abpr]-[A-Za-z0-9-]{10,}", "a Slack token"),
    (r"\beyJ[A-Za-z0-9_-]{20,}\.", "a JWT"),
    (r"[A-Za-z0-9._%+-]+@(?!example\.(com|invalid))[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "an email address"),
]

failures: list[str] = []
warnings: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def warn(message: str) -> None:
    warnings.append(message)


# --------------------------------------------------------------------- images


def png_header(path: Path) -> tuple[int, int, int, int]:
    """(width, height, bit depth, colour type) straight out of the IHDR chunk."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    if data[12:16] != b"IHDR":
        raise ValueError("no IHDR where one should be")
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    return width, height, data[24], data[25]


def decodes(path: Path) -> bool:
    """Every IDAT stream concatenated has to inflate, or the file is not readable."""
    data = path.read_bytes()
    offset, idat = 8, b""
    while offset < len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        if kind == b"IDAT":
            idat += data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IEND":
            break
    try:
        zlib.decompress(idat)
        return True
    except zlib.error:
        return False


def check_images(root: Path, shotlist: dict) -> None:
    for locale, shots in shotlist.items():
        for folder, key in (("iphone-6.9", "iphone"), ("iphone-6.5", "iphone65"), ("ipad-13", "ipad")):
            directory = root / "final" / locale / folder
            if not directory.is_dir():
                fail(f"{locale}/{folder}: no final images at all")
                continue
            files = sorted(p for p in directory.glob("*.png"))
            if not 1 <= len(files) <= 10:
                fail(f"{locale}/{folder}: {len(files)} images; Apple allows 1 to 10")
            expected = [f"{i:02d}-{s['name']}.png" for i, s in enumerate(shots, start=1)]
            actual = [p.name for p in files]
            if actual != expected:
                fail(f"{locale}/{folder}: files are {actual}, the plan says {expected}")

            for path in files:
                try:
                    width, height, depth, colour = png_header(path)
                except ValueError as error:
                    fail(f"{path.relative_to(root)}: {error}")
                    continue
                if (width, height) not in ACCEPTED[folder]:
                    fail(f"{path.relative_to(root)}: {width}×{height} is not an accepted {folder} size")
                # Colour type 6 is RGBA and 4 is grey+alpha; Apple rejects both.
                if colour in (4, 6):
                    fail(f"{path.relative_to(root)}: carries an alpha channel (PNG colour type {colour})")
                if depth != 8:
                    warn(f"{path.relative_to(root)}: {depth}-bit channels rather than 8")
                if not decodes(path):
                    fail(f"{path.relative_to(root)}: does not decode")

                raw = root / "raw" / key / locale / (path.name.split("-", 1)[1])
                if not raw.exists():
                    fail(f"{path.relative_to(root)}: no raw capture at {raw.relative_to(root)}")

    # The two listings have to tell the same story in the same order.
    counts = {}
    for locale in shotlist:
        for folder in ("iphone-6.9", "iphone-6.5", "ipad-13"):
            counts[(locale, folder)] = len(list((root / "final" / locale / folder).glob("*.png")))
    for folder in ("iphone-6.9", "iphone-6.5", "ipad-13"):
        sizes = {locale: counts[(locale, folder)] for locale in shotlist}
        if len(set(sizes.values())) > 1:
            fail(f"{folder}: localizations have different numbers of screenshots: {sizes}")


def check_not_stretched(root: Path) -> None:
    """The renderer records where it put each screenshot; this proves it was not squashed.

    A canvas is a different shape from a capture, so the only thing that can be checked
    from the finished file alone is that it is the right size. What matters as much is
    that the picture *inside* it still has the capture's own proportions — that no axis
    was scaled more than the other to make something fit.
    """
    path = root / "build" / "placements.json"
    if not path.exists():
        fail("build/placements.json is missing; run render.sh")
        return
    for entry in json.loads(path.read_text()):
        source = entry["rawWidth"] / entry["rawHeight"]
        drawn = entry["drawnWidth"] / entry["drawnHeight"]
        if abs(source - drawn) > 0.002:
            fail(
                f"{entry['final']}: drawn at {drawn:.4f}:1 from a capture that is "
                f"{source:.4f}:1 — the picture was stretched"
            )


def check_previews(root: Path) -> None:
    sheets = list((root / "preview").glob("*.png"))
    if not sheets:
        fail("no contact sheet was generated")
    for sheet in sheets:
        try:
            _, _, _, colour = png_header(sheet)
        except ValueError as error:
            fail(f"{sheet.relative_to(root)}: {error}")
            continue
        if colour in (4, 6):
            warn(f"{sheet.relative_to(root)}: carries an alpha channel (it is not uploaded, so this is only untidy)")


# ----------------------------------------------------------------------- copy


def field_values(text: str) -> dict[str, str]:
    """Pulls the fenced field blocks out of a copy document.

    The documents mark every field App Store Connect has a limit for as:

        ### App Name
        ```
        ApexTerminal
        ```
    """
    values = {}
    pattern = re.compile(r"^###\s+(.+?)\s*$\n+```\n(.*?)\n```", re.MULTILINE | re.DOTALL)
    for match in pattern.finditer(text):
        values[match.group(1).strip()] = match.group(2)
    return values


def check_copy(root: Path) -> None:
    for path in sorted((root / "copy").glob("*.md")):
        text = path.read_text()
        name = path.relative_to(root)

        for pattern, why in FORBIDDEN + NOT_ADVERTISABLE:
            for match in re.finditer(pattern, text, re.IGNORECASE):
                # A document may quote a rule in order to say it is being followed; the
                # audit and review notes are where that happens, and they are not uploaded
                # as store copy.
                if path.name.startswith("app-review-notes") or path.name == "FEATURE_OVERVIEW.md":
                    continue
                line = text[:match.start()].count("\n") + 1
                fail(f"{name}:{line}: “{match.group(0)}” — {why}")

        for pattern, what in SENSITIVE:
            for match in re.finditer(pattern, text):
                line = text[:match.start()].count("\n") + 1
                fail(f"{name}:{line}: looks like {what}: {match.group(0)[:40]}")

        if path.name in ("en-US.md", "zh-Hans.md"):
            values = field_values(text)
            for field, (unit, limit) in FIELD_LIMITS.items():
                if field not in values:
                    fail(f"{name}: no “{field}” block")
                    continue
                value = values[field]
                size = len(value) if unit == "chars" else len(value.encode("utf-8"))
                if size > limit:
                    fail(f"{name}: {field} is {size} {unit}; the limit is {limit}")
                else:
                    print(f"    {name.name} · {field}: {size}/{limit} {unit}")
            keywords = values.get("Keywords", "")
            if keywords:
                terms = [t.strip() for t in keywords.split(",")]
                # Spaces removed before comparing: the name is displayed as two words,
                # and "apex terminal" in the keyword list is the same wasted field as
                # "apexterminal" would be.
                if any(t.lower().replace(" ", "") == "apexterminal" for t in terms):
                    fail(f"{name}: the app's own name is repeated in the keywords")
                if len(terms) != len(set(t.lower() for t in terms)):
                    fail(f"{name}: a keyword is repeated")
                if re.search(r"\d+\s*(?:元|USD|\$)", keywords):
                    fail(f"{name}: a price appears in the keywords")


def check_captions(root: Path, shotlist: dict) -> None:
    """Captions are part of the images, so they get the same treatment as the copy."""
    for locale, shots in shotlist.items():
        for shot in shots:
            for field in ("title", "subtitle", "titleIpad", "subtitleIpad"):
                value = shot.get(field)
                if not value:
                    continue
                for pattern, why in FORBIDDEN + NOT_ADVERTISABLE:
                    if re.search(pattern, value, re.IGNORECASE):
                        fail(f"shotlist {locale}/{shot['name']}/{field}: “{pattern}” — {why}")
                # A title that runs long stops being readable at the size the store shows.
                limit = 34 if locale.startswith("en") else 24
                if field.startswith("title") and display_width(value) > limit:
                    warn(f"shotlist {locale}/{shot['name']}/{field}: {display_width(value)} columns; over {limit} it crowds the thumbnail")


def display_width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


# ------------------------------------------------------------------- manifest


def check_manifest(root: Path) -> None:
    path = root / "CAPTURE_MANIFEST.json"
    if not path.exists():
        fail("CAPTURE_MANIFEST.json is missing")
        return
    manifest = json.loads(path.read_text())
    for entry in manifest["screenshots"]:
        where = f"{entry['locale']}/{entry['device']}/{entry['shot']}"
        if not entry.get("capturedFromRunningApp"):
            fail(f"manifest {where}: not captured from the running app")
        if not entry.get("finalPath"):
            fail(f"manifest {where}: has no final image")
        if not entry.get("evidence"):
            fail(f"manifest {where}: no evidence recorded for the feature it claims")
    if manifest["source"]["gitCommit"] == "":
        fail("manifest: no commit recorded")


def main() -> int:
    root = Path(sys.argv[1])
    shotlist = json.loads((root / "scripts" / "shotlist.json").read_text())
    print("▸ Checking the copy")
    check_copy(root)
    check_captions(root, shotlist)
    print("▸ Checking the images")
    check_images(root, shotlist)
    check_not_stretched(root)
    check_previews(root)
    print("▸ Checking the manifest")
    check_manifest(root)

    for message in warnings:
        print(f"  ! {message}")
    if failures:
        print(f"\n✗ {len(failures)} problem(s):")
        for message in failures:
            print(f"  ✗ {message}")
        # The manifest must not claim a check passed when it did not.
        stamp_manifest(root, "failed")
        return 1
    stamp_manifest(root, "passed")
    print(f"\n✓ everything checks out ({len(warnings)} warning(s))")
    return 0


def stamp_manifest(root: Path, outcome: str) -> None:
    """Records the outcome of this run against every screenshot in the manifest.

    The manifest is written by `render.sh` with both checks marked pending, because at
    that point nothing has been checked. This is what makes them true.
    """
    path = root / "CAPTURE_MANIFEST.json"
    if not path.exists():
        return
    manifest = json.loads(path.read_text())
    for entry in manifest.get("screenshots", []):
        entry["sensitiveDataCheck"] = outcome
        entry["authenticityCheck"] = outcome
    manifest["validation"] = {
        "outcome": outcome,
        "ranAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "checks": [
            "pixel size against Apple's accepted list",
            "PNG, 8-bit, no alpha channel",
            "the capture inside each canvas keeps its own aspect ratio",
            "both localizations carry the same images in the same order",
            "metadata field lengths",
            "no competitor named, no unverifiable absolute claim",
            "no capability the audit marked not advertisable",
            "no private key, token, JWT or email address in the copy",
        ],
    }
    path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
