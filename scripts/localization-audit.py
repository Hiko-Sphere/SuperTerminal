#!/usr/bin/env python3
"""Checks that every localizable string in SuperTerminal is actually translated.

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

LANGUAGES = ("zh-Hans", "zh-Hant")

# Which catalog owns the strings of which module.
CATALOGS = {
    "SuperTerminal": "App/Resources/Localizable.xcstrings",
    "STCore": "Packages/SuperTerminalKit/Sources/STCore/Localizable.xcstrings",
    "STSSH": "Packages/SuperTerminalKit/Sources/STSSH/Localizable.xcstrings",
    "STCloudflare": "Packages/SuperTerminalKit/Sources/STCloudflare/Localizable.xcstrings",
}


def extracted_keys(derived_data: str) -> dict[str, set[str]]:
    """Keys the compiler emitted, per module."""
    found: dict[str, set[str]] = defaultdict(set)
    for root, _dirs, files in os.walk(os.path.join(derived_data, "Build", "Intermediates.noindex")):
        # Require the Objects-normal segment: "SuperTerminal.build" is also an ancestor of
        # "SuperTerminalUITests.build", and the test target's strings are not the app's.
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
            for entries in (data.get("tables") or {}).values():
                for entry in entries or []:
                    if entry.get("key"):
                        found[module].add(entry["key"])
    return found


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

    compiler = extracted_keys(derived)
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
                for key in missing[:20]:
                    print(f"      {key!r}")
                if len(missing) > 20:
                    print(f"      … and {len(missing) - 20} more")
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
