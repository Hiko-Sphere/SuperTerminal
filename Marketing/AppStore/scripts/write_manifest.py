#!/usr/bin/env python3
"""Records what the capture run produced, and against which build.

`CAPTURE_MANIFEST.json` is the audit trail: it says which commit, which Xcode, which
simulator runtime and which app version each image came from, and which real feature it
shows. Written by `capture.sh` after the raw images land, and read by `validate.sh`.
"""

from __future__ import annotations

import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "Marketing" / "AppStore"


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, cwd=ROOT).stdout.strip()


def app_version() -> tuple[str, str]:
    """Reads the version out of the built app rather than the project file."""
    for candidate in sorted((ROOT / "build" / "dd" / "Build" / "Products").glob("*/ApexTerminal.app/Info.plist")):
        data = plistlib.loads(candidate.read_bytes())
        return data.get("CFBundleShortVersionString", "?"), data.get("CFBundleVersion", "?")
    return "?", "?"


# What each capture shows, and the evidence that the feature behind it is real. Keyed by
# the file name the capture test writes; anything captured but not published is listed
# here too, with `published: false`.
SHOTS = {
    "terminal": {
        "feature": "Interactive SSH session over a real PTY, with colour, scrollback and the accessory key row",
        "evidence": "SSHIntegrationTests.interactivePTYSession; TUIIntegrationTests; captured against a real OpenSSH server",
    },
    "sessions": {
        "feature": "Several concurrent SSH sessions, with the server platform detected over a second channel",
        "evidence": "AppTests/HostPlatformTests; TerminalUITests.testConnectingDetectsTheServerPlatform",
    },
    "host-key": {
        "feature": "Host-key verification: the fingerprint the server really presented, shown before the connection is made",
        "evidence": "SSHIntegrationTests.trustOnFirstUseRecordsKey; app-integration-e2e.sh host-key prompt gate",
    },
    "keys": {
        "feature": "Keys generated on the device; the private half stays in the Keychain",
        "evidence": "SSHKeyGenerationTests; TerminalUITests.testGeneratingAKeyShowsSomethingTheUserCanPasteIntoAServer",
    },
    "key-created": {
        "feature": "The public half of a newly generated key, ready to copy to a server",
        "evidence": "Same as `keys`",
    },
    "vim": {
        "feature": "A full-screen program over the PTY: alternate screen, syntax colour, a cursor the remote program places",
        "evidence": "TUIIntegrationTests (vim and less over a real SSH PTY)",
    },
    "find": {
        "feature": "Search across the live session's scrollback, with a match count",
        "evidence": "TerminalTextAccessTests (11); TerminalUITests find-bar test",
    },
    "palette": {
        "feature": "Command palette with real fuzzy ranking over connections, sessions and snippets",
        "evidence": "FuzzyMatchTests (13); TerminalUITests palette test",
    },
    "htop": {
        "feature": "A curses program with meters and a live process table",
        "evidence": "TUIIntegrationTests; captured against a real OpenSSH server",
    },
    "editor": {
        "feature": "The connection editor",
        "evidence": "HostModelTests; BlankFieldsUITests",
    },
}


def main() -> int:
    published = json.loads((OUT / "scripts" / "shotlist.json").read_text())
    order = {locale: [s["name"] for s in shots] for locale, shots in published.items()}

    short, build = app_version()
    manifest = {
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "app": {
            "name": "ApexTerminal",
            "bundleIdentifier": "dev.apexterminal.app",
            "marketingVersion": short,
            "buildNumber": build,
        },
        "source": {
            "gitCommit": run("git", "rev-parse", "HEAD"),
            "gitBranch": run("git", "rev-parse", "--abbrev-ref", "HEAD"),
            "gitDirty": bool(run("git", "status", "--porcelain")),
        },
        "toolchain": {
            "xcode": run("xcodebuild", "-version").replace("\n", " "),
            "macOS": run("sw_vers", "-productVersion"),
            "simulatorRuntime": "iOS 26.5",
        },
        "devices": {
            "iphone": {"model": "iPhone 17 Pro Max", "size": "iPhone 6.9\"", "pixels": "1320x2868", "orientation": "portrait"},
            "iphone65": {"model": "iPhone 14 Plus", "size": "iPhone 6.5\" slot", "pixels": "1284x2778", "orientation": "portrait"},
            "ipad": {"model": "iPad Air 13-inch (M4)", "size": "iPad 13\"", "pixels": "2732x2048", "orientation": "landscape"},
        },
        "fixture": {
            "kind": "Three isolated OpenSSH servers in containers, built by scripts/fixture/",
            "account": "deploy (fictional, created by the fixture image)",
            "hosts": ["edge-01.localhost:22", "db-primary.localhost:2201", "build-runner.localhost:2202"],
            "note": "Every session in these images is a real key exchange with a real sshd. No output is replayed or drawn.",
        },
        "screenshots": [],
    }

    for locale in ("en-US", "zh-Hans"):
        for device, folder in (("iphone", "iphone-6.9"), ("iphone65", "iphone-6.5"), ("ipad", "ipad-13")):
            for index, name in enumerate(order[locale], start=1):
                raw = OUT / "raw" / device / locale / f"{name}.png"
                final = OUT / "final" / locale / folder / f"{index:02d}-{name}.png"
                info = SHOTS.get(name, {})
                manifest["screenshots"].append({
                    "order": index,
                    "locale": locale,
                    "device": device,
                    "shot": name,
                    "feature": info.get("feature", ""),
                    "evidence": info.get("evidence", ""),
                    "rawPath": str(raw.relative_to(ROOT)) if raw.exists() else None,
                    "finalPath": str(final.relative_to(ROOT)) if final.exists() else None,
                    "capturedFromRunningApp": raw.exists(),
                    "sensitiveDataCheck": "pending",
                    "authenticityCheck": "pending",
                })

    (OUT / "CAPTURE_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"  → CAPTURE_MANIFEST.json ({len(manifest['screenshots'])} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
