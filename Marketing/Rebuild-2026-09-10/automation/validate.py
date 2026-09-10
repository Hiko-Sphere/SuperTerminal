#!/usr/bin/env python3
"""Checks the finished assets against Apple's rules and this project's own.

Fails loudly. A warning is something to look at; a failure means the asset cannot be
uploaded. Everything here is mechanical — the things a person cannot reliably check by
eye across seventy-two images and three languages.

Usage:  validate.py [rebuild-root]
"""

from __future__ import annotations

import json
import re
import struct
import sys
import unicodedata
from pathlib import Path

# --------------------------------------------------------------------------- rules

# Apple's accepted pixel sizes per slot, re-checked 2026-09-10.
ACCEPTED = {
    "iphone-6.9": {(1260, 2736), (1290, 2796), (1320, 2868),
                   (2736, 1260), (2796, 1290), (2868, 1320)},
    "iphone-6.5": {(1242, 2688), (2688, 1242), (1284, 2778), (2778, 1284)},
    "ipad-13": {(2064, 2752), (2048, 2732), (2752, 2064), (2732, 2048)},
}

LOCALES = ["en-US", "zh-Hans", "zh-Hant"]
SLOTS = ["iphone-6.9", "iphone-6.5", "ipad-13"]

FIELD_LIMITS = {
    "App Name": ("chars", 30),
    "Subtitle": ("chars", 30),
    "Promotional Text": ("chars", 170),
    "Keywords": ("bytes", 100),
    "Description": ("chars", 4000),
    "What's New": ("chars", 4000),
}

# Claims that may never appear, and the reason each is barred. Checked case-insensitively
# across every customer-facing file.
FORBIDDEN = {
    r"\bcloudflare\b": "Cloudflare is withheld from all public claims (POSITIONING.md §6)",
    r"\bfastest\b": "unprovable superlative",
    r"\bmost secure\b": "unprovable superlative",
    r"\bworld'?s (best|first|only)\b": "unprovable superlative",
    # "#1" only as a ranking. `PKCS #1` is a standard's name and `#1` in a list is an
    # index; neither is a claim.
    r"\bnumber one\b|(?<!PKCS )\B#1\b(?!\s*v)": "unprovable ranking",
    r"\bseamless(ly)?\b": "banned by the tone rules",
    r"\beffortless(ly)?\b": "banned by the tone rules",
    r"\brevolutionary\b": "banned by the tone rules",
    r"\b(termius|blink shell|secure shellfish|jump desktop|working copy)\b":
        "no competitor is named in customer-facing copy",
    r"\bsuperterminal\b": "retired product name",
    r"2fa built in|built-in 2fa|two-factor built in":
        "the app relays the server's prompt; it stores no secret and generates no code",
    r"\bbackground connection|stays connected in the background\b":
        "iOS does not guarantee it",
}

# Things that would mean a real person or a real machine leaked into an asset.
SECRETS = {
    # The delimiter alone is a file format worth documenting; what must never appear is
    # the body after it.
    r"BEGIN [A-Z ]*PRIVATE KEY-----[\s\\n]*[A-Za-z0-9+/]{40,}": "private key material",
    r"\bssh-(rsa|ed25519) AAAA[0-9A-Za-z+/]{40,}": "a public key blob",
    # An SSH algorithm name (`chacha20-poly1305@openssh.com`), a retina asset suffix
    # (`logo@2x.png`) and a fixture account (`deploy@edge-01`) all look like addresses and
    # none is one. Documentation domains are allowed by policy.
    r"\b[A-Za-z0-9._%+-]+@(?!example\.(com|invalid)\b|openssh\.com\b|libssh\.org\b|\dx\b)"
    r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b": "an email address",
    r"\bCf-Access-Client-Secret\s*[:=]\s*\S+": "a Cloudflare service token",
    r"\bsk-[A-Za-z0-9]{20,}": "an API key",
}

# Loopback and documentation addresses are the only ones allowed to appear.
ALLOWED_HOSTS = re.compile(
    r"^(127\.0\.0\.1|::1|localhost|0\.0\.0\.0|"
    r"([A-Za-z0-9-]+\.)*localhost|"
    r"([A-Za-z0-9-]+\.)*example\.(com|org|net|invalid))$"
)

failures: list[str] = []
warnings: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def warn(message: str) -> None:
    warnings.append(message)


# --------------------------------------------------------------------------- images


def png_header(path: Path) -> tuple[int, int, int]:
    """Returns (width, height, colour_type) straight out of the IHDR chunk."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    return width, height, data[25]


def check_images(root: Path) -> None:
    print("▸ Checking the images")
    counts: dict[tuple[str, str], int] = {}
    order: dict[tuple[str, str], list[str]] = {}

    for locale in LOCALES:
        for slot in SLOTS:
            directory = root / "app-store/screenshots" / locale / slot
            files = sorted(directory.glob("*.png")) if directory.exists() else []
            counts[(locale, slot)] = len(files)
            order[(locale, slot)] = [f.name for f in files]

            if not files:
                fail(f"{locale}/{slot}: no images")
                continue
            if len(files) > 10:
                fail(f"{locale}/{slot}: {len(files)} images, Apple allows at most 10")

            for path in files:
                try:
                    width, height, colour = png_header(path)
                except Exception as error:                      # noqa: BLE001
                    fail(f"{path.name}: cannot be decoded — {error}")
                    continue
                if (width, height) not in ACCEPTED[slot]:
                    fail(f"{locale}/{slot}/{path.name}: {width}×{height} is not an accepted size")
                # Colour type 2 is RGB with no alpha; 6 is RGBA, which Apple rejects.
                if colour != 2:
                    fail(f"{locale}/{slot}/{path.name}: PNG colour type {colour}, expected 2 (no alpha)")

    # Every localisation must tell the same story in the same order.
    reference = order.get(("en-US", "iphone-6.9"), [])
    for (locale, slot), names in order.items():
        if names and names != reference:
            fail(f"{locale}/{slot}: image order differs from en-US/iphone-6.9")
    sizes = {count for count in counts.values() if count}
    if len(sizes) > 1:
        fail(f"the localisations carry different numbers of images: {sorted(sizes)}")


def check_freshness(root: Path) -> None:
    """Fails when a final image is older than the capture it was made from.

    Worth its own check because of how it fails otherwise: the renderer refuses a bad
    caption by aborting, the previous run's finals are still on disk, and every other
    check here passes on them. Green against stale output is worse than no check at all.
    """
    print("▸ Checking the finals are newer than the captures")
    raw_root = root / "app-store/raw-screenshots"
    newest_raw = max(
        (p.stat().st_mtime for p in raw_root.rglob("*.png")), default=None
    )
    if newest_raw is None:
        warn("no raw captures to compare against")
        return
    stale = [
        p for p in (root / "app-store/screenshots").rglob("*.png")
        if p.stat().st_mtime < newest_raw
    ]
    if stale:
        fail(
            f"{len(stale)} final image(s) are older than the newest capture — "
            f"the renderer did not finish. First: {stale[0].relative_to(root)}"
        )


def check_placements(root: Path) -> None:
    """Proves no capture was scaled by different factors on its two axes."""
    path = root / "automation/build/placements.json"
    if not path.exists():
        warn("no placements.json — run the renderer to enable the stretch check")
        return
    print("▸ Checking that nothing was stretched")
    for group, placements in json.loads(path.read_text()).items():
        for placement in placements:
            raw_ratio = placement["rawWidth"] / placement["rawHeight"]
            drawn_ratio = placement["drawnWidth"] / placement["drawnHeight"]
            drift = abs(raw_ratio - drawn_ratio) / raw_ratio
            if drift > 0.005:
                fail(
                    f"{group}/{placement['final']}: drawn at {drawn_ratio:.4f} against a source "
                    f"ratio of {raw_ratio:.4f} — that is a stretch, not a scale"
                )
            # And it must sit inside the canvas.
            if placement["drawnX"] < -1 or placement["drawnWidth"] > placement["canvasWidth"] + 1:
                fail(f"{group}/{placement['final']}: the capture runs off the side of the canvas")


# --------------------------------------------------------------------------- copy


def blocks(text: str) -> dict[str, str]:
    """Every ``### Field`` heading followed by a fenced block, as {field: value}."""
    found = {}
    for match in re.finditer(r"^###\s+(.+?)\s*$\n+```\n(.*?)\n```", text, re.M | re.S):
        found[match.group(1).strip()] = match.group(2)
    return found


def check_copy(root: Path) -> None:
    print("▸ Checking the copy")
    metadata = sorted((root / "app-store/metadata").glob("*.md"))
    if not metadata:
        warn("no metadata files yet")
    for path in metadata:
        text = path.read_text()
        for field, value in blocks(text).items():
            if field not in FIELD_LIMITS:
                continue
            unit, limit = FIELD_LIMITS[field]
            size = len(value.encode("utf-8")) if unit == "bytes" else len(value)
            status = "" if size <= limit else "  ← OVER"
            print(f"    {path.name} · {field}: {size}/{limit} {unit}{status}")
            if size > limit:
                fail(f"{path.name}: {field} is {size} {unit}, the limit is {limit}")

        # Keywords must not waste the field on the app's own name or on repeats.
        for field, value in blocks(text).items():
            if field != "Keywords":
                continue
            terms = [t.strip() for t in value.split(",") if t.strip()]
            if len(terms) != len(set(t.lower() for t in terms)):
                fail(f"{path.name}: the keyword list repeats a term")
            if any(t.lower().replace(" ", "") == "apexterminal" for t in terms):
                fail(f"{path.name}: the app's own name is repeated in the keywords")


def customer_facing(root: Path) -> list[Path]:
    """Files a customer could read. Internal analysis is exempt from the claim rules."""
    internal = {
        "PRODUCT_TRUTH_MATRIX.md", "CLAIMS_MATRIX.md", "COMPETITOR_DIFFERENTIATION.md",
        "LEGACY_ASSET_AUDIT.md", "POSITIONING.md", "MESSAGING_SYSTEM.md",
        "AUDIENCE_MATRIX.md", "SCREENSHOT_PLAN.md", "SCREENSHOT_DESIGN.md",
        "CAPTURE_GUIDE.md", "FINAL_VERIFICATION_REPORT.md", "ASSET_INDEX.md",
        "CLOUDFLARE_OVERVIEW.md", "APP_PREVIEW_STORYBOARD.md",
        "WEBSITE_INFORMATION_ARCHITECTURE.md", "FEATURE_COMPARISON.md",
    }
    paths = []
    for directory in ("app-store/metadata", "website", "social", "press-kit", "feature-catalog"):
        paths += sorted((root / directory).rglob("*.md"))
    return [p for p in paths if p.name not in internal]


# Fields whose fenced value is published to customers. The App Review Notes block is
# deliberately absent: it is a private disclosure to Apple, and guideline 2.3.1 *requires*
# it to name the features that are in the binary but not advertised — including the ones
# barred from the listing. Scanning it for those words would forbid the disclosure.
PUBLISHED_FIELDS = {"App Name", "Subtitle", "Promotional Text", "Keywords", "Description", "What's New"}


def scannable(path: Path) -> str:
    """The text of a file that a customer could actually read.

    For a metadata file that is only the listing values, because the prose around them is
    guidance for the submitter — it says things like "deliberately excludes cloudflare",
    which is a statement *about* a rule rather than a breach of it.
    """
    text = path.read_text()
    if path.parent.name == "metadata":
        found = blocks(text)
        return "\n".join(v for k, v in found.items() if k in PUBLISHED_FIELDS)
    return text


# A document may name a forbidden phrase in order to forbid it — the brand guide says not
# to write the retired name, the catalogue says never to claim "2FA built in". Quoting a
# rule is not breaking it. A match is exempt only when the phrase is quoted *and* the line
# also carries a prohibition, so an ordinary sentence cannot slip through by adding quotes.
PROHIBITION = re.compile(
    r"\b(never|not|no|must not|do not|don't|rather than|instead of|retired|forbidden|avoid)\b",
    re.I,
)


# Wording whose only purpose is to forbid: a brand guide's "must not appear in writing",
# a catalogue's "never claim …". Narrow on purpose — "not" anywhere on the line is not
# enough, or "not just the fastest" would exempt itself.
FORBIDS = re.compile(
    r"must not|may not|never (?:say|write|claim|use|appear)|do not (?:say|write|claim|use)"
    r"|retired name|forbidden|banned|withheld",
    re.I,
)
# A negation sitting immediately in front of the phrase: "No background connections."
IMMEDIATE_NEGATION = re.compile(r"\b(?:no|not|never|without|neither|nor)\b[\s,\u2014-]*$", re.I)


def is_prohibition(line: str, phrase: str, before: str) -> bool:
    quoted = any(
        f"{open_}{phrase}{close}" in line
        for open_, close in (('"', '"'), ("`", "`"), ("\u201c", "\u201d"))
    )
    if quoted and PROHIBITION.search(line):
        return True
    if FORBIDS.search(line):
        return True
    return bool(IMMEDIATE_NEGATION.search(before))


def check_claims(root: Path) -> None:
    print("▸ Checking every customer-facing claim")
    files = customer_facing(root)
    if not files:
        warn("no customer-facing copy yet")
    for path in files:
        text = scannable(path)
        for pattern, reason in FORBIDDEN.items():
            for match in re.finditer(pattern, text, re.I):
                line_start = text.rfind("\n", 0, match.start()) + 1
                line_end = text.find("\n", match.end())
                line = text[line_start : line_end if line_end != -1 else len(text)]
                if is_prohibition(line, match.group(0), text[line_start : match.start()]):
                    continue
                where = text[: match.start()].count("\n") + 1
                fail(f"{path.relative_to(root)} (published text, line {where}): “{match.group(0)}” — {reason}")
        for pattern, what in SECRETS.items():
            for match in re.finditer(pattern, text):
                line = text[: match.start()].count("\n") + 1
                fail(f"{path.relative_to(root)}:{line}: looks like {what}")
        # Any bare host or address that is not loopback or documentation.
        for match in re.finditer(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", text):
            if not ALLOWED_HOSTS.match(match.group(0)):
                line = text[: match.start()].count("\n") + 1
                fail(f"{path.relative_to(root)}:{line}: the address {match.group(0)} is not loopback or documentation")
        for placeholder in ("TODO", "TBD", "Lorem ipsum", "{{PRODUCT_NAME}}", "XXX"):
            if placeholder.lower() in text.lower():
                fail(f"{path.relative_to(root)}: contains the placeholder “{placeholder}”")


def check_punctuation(root: Path) -> None:
    """Chinese copy must use full-width punctuation, not Latin marks."""
    print("▸ Checking Chinese punctuation")
    for path in customer_facing(root):
        if not re.search(r"zh[-_]?(Hans|Hant|CN|TW)", path.name, re.I):
            continue
        found = blocks(path.read_text())
        # Keywords are a comma-separated field, not a sentence; its commas are separators.
        text = "\n".join(v for k, v in found.items() if k in PUBLISHED_FIELDS and k != "Keywords") \
            or path.read_text()
        for line_number, line in enumerate(text.splitlines(), 1):
            # Only lines that are actually Chinese prose, not code or tables.
            if not any(unicodedata.east_asian_width(c) == "W" for c in line):
                continue
            if line.lstrip().startswith(("|", "`", "#", "-", "*", ">")):
                continue
            for mark, want in ((",", "，"), (";", "；"), ("?", "？"), ("!", "！")):
                if re.search(rf"[一-鿿]\s*{re.escape(mark)}", line):
                    warn(f"{path.relative_to(root)}:{line_number}: “{mark}” after Han text; “{want}” is expected")


# --------------------------------------------------------------------------- main


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    check_images(root)
    check_freshness(root)
    check_placements(root)
    check_copy(root)
    check_claims(root)
    check_punctuation(root)

    print()
    for message in warnings:
        print(f"  warning: {message}")
    if failures:
        for message in failures:
            print(f"  FAIL: {message}")
        print(f"\n✗ {len(failures)} failure(s), {len(warnings)} warning(s)")
        return 1
    print(f"✓ everything checks out ({len(warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
