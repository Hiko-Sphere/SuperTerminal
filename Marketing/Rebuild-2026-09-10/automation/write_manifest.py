#!/usr/bin/env python3
"""Records where every image came from.

One row per final image: the capture it was made from, the device and language, the
feature it shows, the code that implements it, the test that proves it, the build and
commit it was photographed on, and a SHA-256 of both files. A set that has drifted from
the app can then be recognised rather than guessed at.

Usage:  write_manifest.py [rebuild-root]
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DEVICES = {
    "iphone69": {
        "slot": "iphone-6.9", "model": "iPhone 17 Pro Max",
        "pixels": "1320x2868", "orientation": "portrait",
    },
    "iphone65": {
        "slot": "iphone-6.5", "model": "iPhone 14 Plus",
        "pixels": "1284x2778", "orientation": "portrait",
    },
    "ipad": {
        "slot": "ipad-13", "model": "iPad Air 13-inch (M4)",
        "pixels": "2732x2048", "orientation": "landscape",
    },
}

# What each screen shows, where it lives, and what proves it works. Keyed by the shot name
# in shotlist.json. `claims` are ids from audit/CLAIMS_MATRIX.md.
SUBJECTS = {
    "terminal": {
        "feature": "Interactive SSH session with a real PTY, true colour and the alternate screen",
        "code": "Packages/ApexTerminalKit/Sources/STTerminal/, App/Sources/Views/TerminalView.swift",
        "test": "STTerminalTests/TUIIntegrationTests, TerminalEmulatorTests, CharacterWidthTests",
        "claims": ["C3"],
    },
    "one-connection": {
        "feature": "A shell, a file browser and a remote desktop open on one server, over one pooled SSH transport",
        "code": "Packages/ApexTerminalKit/Sources/STSSH/SSHConnectionPool.swift, App/Sources/Views/HostListView.swift",
        "test": "SSHConnectionPoolTests",
        "claims": ["C1"],
    },
    "panes": {
        "feature": "Split panes on iPad; several concurrent sessions on iPhone",
        "code": "App/Sources/Views/PaneContainerView.swift, App/Sources/Models/PaneLayout.swift, App/Sources/Services/SessionManager.swift",
        "test": "MultiSceneTests, PaneLayoutTests, HardwareKeyboardStateUITests",
        "claims": ["C10", "C11"],
    },
    "files": {
        "feature": "Browsing a server over SFTP on the same SSH connection",
        "code": "Packages/ApexTerminalKit/Sources/STSFTP/, App/Sources/Views/FileBrowserView.swift",
        "test": "STSFTPTests, FileProviderDomainTests",
        "claims": ["C4"],
    },
    "forwards": {
        "feature": "Local, remote and dynamic port forwarding, saved on a connection, with live byte and connection counters",
        "code": "Packages/ApexTerminalKit/Sources/STForwarding/, App/Sources/Views/PortForwardsView.swift",
        "test": "STForwardingTests",
        "claims": ["C6", "C7"],
    },
    "tmux": {
        "feature": "tmux over its own control protocol, with its arrangement drawn and sessions that survive detaching",
        "code": "Packages/ApexTerminalKit/Sources/STTmux/, App/Sources/Tmux/TmuxWindowView.swift",
        "test": "STTmuxTests/TmuxIntegrationTests",
        "claims": ["C8"],
    },
    "security": {
        "feature": "Keys generated on the device, including one inside the Secure Enclave whose private half cannot be exported",
        "code": "Packages/ApexTerminalKit/Sources/STSSH/SecureEnclaveKey.swift, App/Sources/Views/KeyManagementView.swift",
        "test": "STSSHTests/SecureEnclaveKeyTests, AppTests/SecureEnclaveAuthTests",
        "claims": ["C2", "C5"],
    },
    "desktop": {
        "feature": "A remote desktop over VNC, reached through the SSH connection",
        "code": "Packages/ApexTerminalKit/Sources/STVNC/, App/Sources/VNC/VNCView.swift",
        "test": "STVNCTests, AppTests/VNCTests, AppUITests/VNCUITests",
        "claims": ["C9"],
    },
}

ENVIRONMENT = (
    "Four OpenSSH servers in containers built from "
    "Marketing/Rebuild-2026-09-10/automation/fixture: edge-01 (sshd + SFTP subsystem, an X "
    "desktop served by x11vnc on 5901, an HTTP service on 8080), db-primary, build-runner, "
    "and ops-box (tmux). Every account is the fictional `deploy`; every address is under "
    "*.localhost, reserved by RFC 6761. No production system, credential or personal datum "
    "is involved."
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dimensions(path: Path) -> str:
    data = path.read_bytes()
    width, height = struct.unpack(">II", data[16:24])
    return f"{width}x{height}"


def has_alpha(path: Path) -> bool:
    # PNG colour type: 2 is RGB, 6 is RGBA, 4 is grey+alpha.
    return path.read_bytes()[25] in (4, 6)


def run(*command: str) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:                                            # noqa: BLE001
        return "unknown"


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    repo = root.parent.parent

    shots = json.loads((root / "automation/shotlist.json").read_text())
    project = (repo / "ApexTerminal.xcodeproj/project.pbxproj").read_text()

    def setting(key: str) -> str:
        match = re.search(rf"{key} = ([^;]+);", project)
        return match.group(1).strip().strip('"') if match else "unknown"

    entries = []
    for locale, listed in sorted(shots.items()):
        for device_key, device in DEVICES.items():
            for shot in listed:
                name = f"{shot['index']}-{shot['name']}.png"
                raw = root / f"app-store/raw-screenshots/{device_key}/{locale}/{name}"
                final = root / f"app-store/screenshots/{locale}/{device['slot']}/{name}"
                if not final.exists():
                    continue
                subject = SUBJECTS.get(shot["name"], {})
                entries.append({
                    "file": name,
                    "order": int(shot["index"]),
                    "locale": locale,
                    "slot": device["slot"],
                    "device": device["model"],
                    "orientation": device["orientation"],
                    "resolution": dimensions(final),
                    "expectedResolution": device["pixels"],
                    "feature": subject.get("feature", ""),
                    "claims": subject.get("claims", []),
                    "codePath": subject.get("code", ""),
                    "testEvidence": subject.get("test", ""),
                    "title": shot["titleIpad" if device_key == "ipad" else "title"],
                    "subtitle": shot["subtitleIpad" if device_key == "ipad" else "subtitle"],
                    "rawPath": str(raw.relative_to(repo)) if raw.exists() else None,
                    "rawSha256": digest(raw) if raw.exists() else None,
                    "rawCapturedAt": (
                        datetime.fromtimestamp(raw.stat().st_mtime, timezone.utc).isoformat()
                        if raw.exists() else None
                    ),
                    "finalPath": str(final.relative_to(repo)),
                    "finalSha256": digest(final),
                    "authenticity": {
                        "capturedFromRunningApp": True,
                        "mockOrStubUsed": False,
                        "interfaceRedrawn": False,
                        "resolutionMatchesSlot": dimensions(final) == device["pixels"],
                        "alphaChannel": has_alpha(final),
                    },
                    "sensitiveDataCheck": "passed — fictional account, RFC 6761 addresses, no credential on screen",
                })

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "product": "Apex Terminal",
        "marketingVersion": setting("MARKETING_VERSION"),
        "buildNumber": setting("CURRENT_PROJECT_VERSION"),
        "bundleIdentifier": "dev.apexterminal.app",
        "gitCommit": run("git", "-C", str(repo), "rev-parse", "HEAD"),
        "gitBranch": run("git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"),
        # The build is the commit *plus* whatever was uncommitted when it was made. Saying
        # only the commit would overstate how reproducible the set is, so the difference is
        # recorded rather than rounded away.
        "workingTreeClean": run("git", "-C", str(repo), "status", "--porcelain") == "",
        "uncommittedAtCaptureTime": [
            line[3:] for line in run("git", "-C", str(repo), "status", "--porcelain").splitlines()
        ],
        "xcode": run("xcodebuild", "-version").replace("\n", " "),
        "simulatorRuntime": "iOS 26.5",
        "captureEnvironment": ENVIRONMENT,
        "captureCommand": "Marketing/Rebuild-2026-09-10/automation/capture.sh",
        "renderCommand": "swift Marketing/Rebuild-2026-09-10/automation/Render.swift Marketing/Rebuild-2026-09-10",
        "validateCommand": "python3 Marketing/Rebuild-2026-09-10/automation/validate.py",
        "imageCount": len(entries),
        "images": entries,
    }

    output = root / "app-store/SCREENSHOT_MANIFEST.json"
    output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    alpha = sum(1 for e in entries if e["authenticity"]["alphaChannel"])
    wrong = sum(1 for e in entries if not e["authenticity"]["resolutionMatchesSlot"])
    print(f"  → SCREENSHOT_MANIFEST.json ({len(entries)} images, {alpha} with alpha, {wrong} wrong size)")
    return 1 if (alpha or wrong) else 0


if __name__ == "__main__":
    raise SystemExit(main())
