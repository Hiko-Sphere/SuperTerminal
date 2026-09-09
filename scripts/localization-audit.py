#!/usr/bin/env python3
"""Checks that every localizable string in ApexTerminal is actually translated.

Localization rots silently. A new `Text("Add server")` compiles, ships, and shows English
to a Chinese user with nothing failing anywhere — no warning, no test, no crash. This is
the gate that turns that into a build failure.

It does not read the source. It reads the keys the *compiler* extracted, which is the only
list that matches what the app looks up at runtime: SwiftUI turns `Text("Delete \\(name)?")`
into the key `Delete %@?`, so anything derived from source text would disagree with the
binary. Run `xcodebuild ... SWIFT_EMIT_LOC_STRINGS=YES build` first; `scripts/localization-audit.sh`
does that for you.

Exit status is 1 if any key is missing a translation in any supported language.
"""
import json
import os
import plistlib
import sys
from collections import defaultdict
from datetime import datetime

LANGUAGES = ("zh-Hans", "zh-Hant")

# Which catalog owns the strings of which module.
CATALOGS = {
    "ApexTerminal": "App/Resources/Localizable.xcstrings",
    "STCore": "Packages/ApexTerminalKit/Sources/STCore/Localizable.xcstrings",
    "STSSH": "Packages/ApexTerminalKit/Sources/STSSH/Localizable.xcstrings",
    "STCloudflare": "Packages/ApexTerminalKit/Sources/STCloudflare/Localizable.xcstrings",
    "STFileProvider": "Packages/ApexTerminalKit/Sources/STFileProvider/Localizable.xcstrings",
    "STForwarding": "Packages/ApexTerminalKit/Sources/STForwarding/Localizable.xcstrings",
    "STTmux": "Packages/ApexTerminalKit/Sources/STTmux/Localizable.xcstrings",
}


def extracted_keys(derived_data: str) -> tuple[dict[str, set[str]], dict[tuple[str, str], tuple[str, float]]]:
    """Keys the compiler emitted, per module, and where each was last seen.

    The provenance is not decoration. Xcode leaves the intermediates of builds nobody runs
    any more — a device build from a week ago sits beside today's simulator one — and a key
    that only exists in a stale one is reported as missing for as long as that directory
    survives. Printing the file and its date next to a missing key turns a false alarm into
    something a person recognises in a second, without hiding it.
    """
    found: dict[str, set[str]] = defaultdict(set)
    seen: dict[tuple[str, str], tuple[str, float]] = {}
    for root, _dirs, files in os.walk(os.path.join(derived_data, "Build", "Intermediates.noindex")):
        # Require the Objects-normal segment: "ApexTerminal.build" is also an ancestor of
        # "ApexTerminalUITests.build", and the test target's strings are not the app's.
        module = next((m for m in CATALOGS
                       if f"{os.sep}{m}.build{os.sep}Objects-normal{os.sep}" in root + os.sep), None)
        if module is None:
            continue
        for name in files:
            if not name.endswith(".stringsdata"):
                continue
            path = os.path.join(root, name)
            data = None
            for loader in (lambda p: plistlib.load(open(p, "rb")), lambda p: json.load(open(p))):
                try:
                    data = loader(path)
                    break
                except Exception:
                    continue
            if data is None:
                continue
            when = os.path.getmtime(path)
            for entries in (data.get("tables") or {}).values():
                for entry in entries or []:
                    key = entry.get("key")
                    if not key:
                        continue
                    found[module].add(key)
                    if seen.get((module, key), ("", 0.0))[1] < when:
                        seen[(module, key)] = (path, when)
    return found, seen


def translated_keys(path: str) -> dict[str, set[str]]:
    """For each language, the keys the catalog has a translation for."""
    if not os.path.exists(path):
        return {language: set() for language in LANGUAGES}
    with open(path) as handle:
        catalog = json.load(handle)
    have: dict[str, set[str]] = {language: set() for language in LANGUAGES}
    for key, entry in (catalog.get("strings") or {}).items():
        for language in LANGUAGES:
            unit = ((entry.get("localizations") or {}).get(language) or {}).get("stringUnit") or {}
            # "needs_review" still shows the translation, so it counts; a missing or empty
            # value does not.
            if unit.get("value"):
                have[language].add(key)
    return have


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: localization-audit.py <DerivedData path>", file=sys.stderr)
        return 2
    derived = sys.argv[1]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    compiler, provenance = extracted_keys(derived)
    failures = 0
    for module, catalog_path in CATALOGS.items():
        keys = compiler.get(module, set())
        if not keys:
            # Not a failure: a module may legitimately have nothing a user reads. The
            # catalog stays so the next such string has somewhere to go.
            print(f"{module}: no user-facing strings")
            continue
        have = translated_keys(os.path.join(root, catalog_path))
        print(f"{module}: {len(keys)} localizable strings")
        for language in LANGUAGES:
            missing = sorted(keys - have[language])
            if missing:
                failures += len(missing)
                print(f"  {language}: MISSING {len(missing)}")
                shown = missing if os.environ.get("AUDIT_ALL") else missing[:20]
                for key in shown:
                    where, when = provenance.get((module, key), ("", 0.0))
                    origin = ""
                    if where:
                        origin = f"  [{os.path.relpath(where, derived)} · {datetime.fromtimestamp(when):%Y-%m-%d %H:%M}]"
                    print(f"      {key!r}{origin}")
                if len(missing) > 20:
                    if len(shown) < len(missing):
                        print(f"      … and {len(missing) - 20} more (AUDIT_ALL=1 lists every key)")
            else:
                print(f"  {language}: complete")
        # A key in the catalog that the compiler no longer emits is dead weight; it is not
        # a failure, but it is worth saying so it can be removed.
        orphaned = sorted(have[LANGUAGES[0]] - keys)
        if orphaned:
            print(f"  {len(orphaned)} translated string(s) no longer in the source")

    if failures:
        print(f"\n{failures} untranslated string(s). Every string a user can read must be "
              f"translated, or the app shows English to someone who chose Chinese.")
        return 1
    print("\nEvery localizable string is translated in every supported language.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
