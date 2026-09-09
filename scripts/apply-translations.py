#!/usr/bin/env python3
"""Files translations into the String Catalog of whichever module owns each string.

Input is a JSON array of {"key", "zhHans", "zhHant"} where "key" is the English string as
it appears **in Swift source** — interpolation and all. This script converts each
`\\(expression)` into the format specifier the compiler actually emitted for it, and writes
the result into the catalog belonging to the module the string came from.

That conversion is the whole reason this exists. `Text("Delete \\(name)?")` is looked up at
runtime under the key `Delete %@?`; a catalog keyed on the source text matches nothing and
the app silently shows English. Expressions are matched by their text, not by position, so a
translation that reorders arguments produces `%1$@`/`%2$@` rather than a silently swapped
pair — and the specifier multiset is asserted equal on both sides before anything is written.

This is a bulk-import tool. Once a translation is in a catalog, the catalog is the source
of truth — Xcode edits it directly, and re-running this with a stale input would undo that.
Reach for it when importing a batch, not to regenerate what is already there.

Usage:  apply-translations.py <translations.json> <DerivedData path>
Run a build with SWIFT_EMIT_LOC_STRINGS=YES first so the compiler has written its keys.
"""
import json
import os
import plistlib
import re
import sys
from collections import Counter, OrderedDict, defaultdict

LANGUAGES = ("zh-Hans", "zh-Hant")
CATALOGS = {
    "ApexTerminal": "App/Resources/Localizable.xcstrings",
    "STCore": "Packages/ApexTerminalKit/Sources/STCore/Localizable.xcstrings",
    "STSSH": "Packages/ApexTerminalKit/Sources/STSSH/Localizable.xcstrings",
    "STCloudflare": "Packages/ApexTerminalKit/Sources/STCloudflare/Localizable.xcstrings",
    "STFileProvider": "Packages/ApexTerminalKit/Sources/STFileProvider/Localizable.xcstrings",
    "STForwarding": "Packages/ApexTerminalKit/Sources/STForwarding/Localizable.xcstrings",
    "STTmux": "Packages/ApexTerminalKit/Sources/STTmux/Localizable.xcstrings",
}
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:@|lld|llu|lf|d|u|s)")


def conversions(text):
    """The conversion letters in `text`, with any positional prefix removed.

    `%@` and `%2$@` are the same conversion; only the argument they take differs. Comparing
    them unnormalised makes a correctly reordered translation look like a broken one, which
    is exactly the case that matters — Chinese reorders arguments routinely.
    """
    return Counter(re.sub(r"^%(?:\d+\$)?", "", s) for s in SPECIFIER.findall(text))


def interpolations(text):
    """Ordered (start, end, expression) for each \\( … ) in `text`, parens balanced.

    Balanced rather than regex: an expression can itself contain parentheses and string
    literals, as in \\(key.algorithm.replacingOccurrences(of: "ssh-", with: "")).
    """
    out, index = [], 0
    while True:
        start = text.find("\\(", index)
        if start < 0:
            return out
        depth, cursor, in_string = 0, start + 1, False
        while cursor < len(text):
            char = text[cursor]
            if char == '"' and text[cursor - 1] != "\\":
                in_string = not in_string
            elif not in_string:
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        break
            cursor += 1
        out.append((start, cursor + 1, text[start + 2:cursor]))
        index = cursor + 1


def as_pattern(source_key):
    """The source key as a regex over compiler keys, each interpolation a specifier."""
    parts, index = [], 0
    for start, end, _ in interpolations(source_key):
        parts.append(re.escape(source_key[index:start]))
        parts.append(r"%(?:\d+\$)?(?:@|lld|llu|lf|d|u|s)")
        index = end
    parts.append(re.escape(source_key[index:]))
    return re.compile("^" + "".join(parts) + "$")


def extracted(derived_data):
    """{module: {key}} for the keys the compiler emitted."""
    found = defaultdict(set)
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
            for entries in (data.get("tables") or {}).values():
                for entry in entries or []:
                    if entry.get("key"):
                        found[module].add(entry["key"])
    return found


def convert(source_key, compiler_key, translation):
    """Rewrite one translation's interpolations as the specifiers the key uses."""
    expressions = [e for _, _, e in interpolations(source_key)]
    specifiers = SPECIFIER.findall(compiler_key)
    if len(expressions) != len(specifiers):
        return None
    position = {expression: index for index, expression in enumerate(expressions)}

    found = interpolations(translation)
    if len(found) != len(expressions) or {e for _, _, e in found} != set(expressions):
        return None
    reordered = [position[e] for _, _, e in found] != list(range(len(expressions)))

    out, index = [], 0
    for start, end, expression in found:
        out.append(translation[index:start])
        at = position[expression]
        out.append(f"%{at + 1}$" + specifiers[at].lstrip("%") if reordered else specifiers[at])
        index = end
    out.append(translation[index:])
    return "".join(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    translations = json.load(open(sys.argv[1]))
    keys_by_module = extracted(sys.argv[2])
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    filed = {module: {} for module in CATALOGS}
    unmatched, broken = [], []

    for entry in translations:
        source_key = entry["key"]
        target = None
        for module, keys in keys_by_module.items():
            if "\\(" not in source_key:
                if source_key in keys:
                    target = (module, source_key)
                    break
                continue
            pattern = as_pattern(source_key)
            hits = sorted((k for k in keys if pattern.match(k)), key=lambda k: abs(len(k) - len(source_key)))
            if hits:
                target = (module, hits[0])
                break
        if target is None:
            unmatched.append(source_key)
            continue

        module, compiler_key = target
        values = {}
        for language, field in zip(LANGUAGES, ("zhHans", "zhHant")):
            text = entry[field]
            if "\\(" in compiler_key or "\\(" in text or SPECIFIER.search(compiler_key):
                converted = convert(source_key, compiler_key, text) if "\\(" in source_key else text
                if converted is None:
                    broken.append((compiler_key, language))
                    break
                text = converted
            values[language] = text
        else:
            want = conversions(compiler_key)
            if any(conversions(v) != want for v in values.values()):
                broken.append((compiler_key, "placeholder-mismatch"))
                continue
            if any("\\(" in v for v in values.values()):
                broken.append((compiler_key, "raw-interpolation-left"))
                continue
            filed[module][compiler_key] = values

    if broken:
        print(f"{len(broken)} translation(s) could not be converted safely:")
        for key, why in broken[:20]:
            print(f"   {why}: {key!r}")
        return 1

    for module, path in CATALOGS.items():
        existing = {}
        full = os.path.join(root, path)
        if os.path.exists(full):
            existing = (json.load(open(full)).get("strings") or {})
        strings = OrderedDict()
        merged = dict(existing)
        for key, values in filed[module].items():
            merged[key] = {"extractionState": "manual", "localizations": {
                language: {"stringUnit": {"state": "translated", "value": values[language]}}
                for language in LANGUAGES}}
        for key in sorted(merged):
            strings[key] = merged[key]
        with open(full, "w") as handle:
            json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                      handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(f"{module}: {len(filed[module])} filed, {len(strings)} total")

    if unmatched:
        print(f"\n{len(unmatched)} translation(s) matched no compiler key — the string is "
              f"either gone or still not localizable in source:")
        for key in unmatched[:15]:
            print(f"   {key!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
