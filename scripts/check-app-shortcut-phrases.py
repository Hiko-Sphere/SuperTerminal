#!/usr/bin/env python3
"""Fails when a spoken App Shortcut phrase names more than one parameter.

Apple's rule is one parameter per phrase, and `appshortcutstringsprocessor` enforces it —
but only when the app is *archived*. Every Debug build, every simulator run and every unit
test passed with a two-parameter phrase in D-061; the archive is where it turned into
"Multiple parameters detected in phrase", days later. This check takes a fraction of a
second, so the rule is enforced where the mistake is made.

`\\(.applicationName)` is not a parameter — every phrase must name the app.
"""
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "App/Sources/Intents/AppIntents.swift"
PHRASES = re.compile(r"phrases:\s*(\[[^\]]*\]|\"[^\"]*\")", re.S)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# `\(\.$name)` is a parameter; `\(.applicationName)` is the app's own name.
PARAMETER = re.compile(r"\\\(\\\.\$")


def main() -> int:
    text = SOURCE.read_text()
    problems = []
    for block in PHRASES.finditer(text):
        for phrase in STRING.finditer(block.group(1)):
            spoken = phrase.group(1)
            count = len(PARAMETER.findall(spoken))
            if count > 1:
                problems.append(f"{count} parameters: {spoken}")
            if "applicationName" not in spoken:
                problems.append(f"does not name the app: {spoken}")

    if problems:
        print(f"{SOURCE.name}: App Shortcut phrases Apple's validator will reject")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("Every App Shortcut phrase names the app and at most one parameter.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
