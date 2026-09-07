#!/usr/bin/env python3
"""Copies the capture run's screenshot attachments out of an exported result bundle.

`xcresulttool export attachments` writes every attachment under generated file names and
a `manifest.json` that maps them back to the name the test gave. The capture test names
each screenshot `stshot-<shot>`; this keeps those and drops everything else — failure
diagnostics, system logs — so `raw/` holds only images that were deliberately taken.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: collect_attachments.py <exported-dir> <destination-dir> [--landscape]", file=sys.stderr)
        return 2

    exported = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    landscape = len(sys.argv) == 4 and sys.argv[3] == "--landscape"
    destination.mkdir(parents=True, exist_ok=True)

    manifest_path = exported / "manifest.json"
    if not manifest_path.exists():
        print(f"no manifest at {manifest_path}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    kept = 0
    # The schema nests attachments under each test; be liberal about its exact shape so a
    # future xcresulttool version does not silently produce an empty raw/ directory.
    for entry in walk(manifest):
        name = entry.get("suggestedHumanReadableName") or entry.get("name") or ""
        exported_name = entry.get("exportedFileName")
        if not exported_name or not name.startswith("stshot-"):
            continue
        source = exported / exported_name
        if not source.exists():
            continue
        shot = name[len("stshot-"):]
        # XCTest appends `_<index>_<uuid>.png` to an attachment's name when it writes it
        # into the bundle; the shot's own name is everything before that.
        shot = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.png)?$", "", shot)
        if shot.endswith(".png"):
            shot = shot[: -len(".png")]
        target = destination / f"{shot}.png"
        if landscape:
            # `XCUIScreen.main.screenshot()` hands back the panel in the orientation the
            # hardware has, not the one the app is drawn in, so a landscape run arrives
            # as a portrait image with the interface lying on its side. Turning it back
            # is a lossless quarter-turn: the same pixels, none resampled, none scaled —
            # the picture the person holding the iPad is looking at.
            rotate_quarter_turn(source, target)
        else:
            shutil.copyfile(source, target)
        kept += 1

    if kept == 0:
        print("no stshot- attachments found; the capture run produced nothing", file=sys.stderr)
        return 1
    return 0


def rotate_quarter_turn(source: Path, target: Path) -> None:
    """Turns a portrait capture a quarter-turn anticlockwise, losslessly."""
    result = subprocess.run(
        ["sips", "-r", "-90", str(source), "--out", str(target)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"could not rotate {source}: {result.stderr.strip()}")


def walk(node):
    """Yields every dict in the manifest that looks like an attachment record."""
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


if __name__ == "__main__":
    raise SystemExit(main())
