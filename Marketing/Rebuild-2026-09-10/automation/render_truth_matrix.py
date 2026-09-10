#!/usr/bin/env python3
"""Renders PRODUCT_TRUTH_MATRIX.md from the audit's structured output.

The matrix is generated rather than written by hand on purpose. Every row came from an
agent that opened the cited source and the cited test; rendering it mechanically means the
document cannot drift from what was actually found, and re-running the audit re-renders it
rather than inviting a hand edit that quietly loosens a status.

Usage:  render_truth_matrix.py <areas.json> <output.md>

`areas.json` is the list of per-area objects the audit workflow returned, each with
`area`, `capabilities[]` and `notes`.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

# Order matters: the narrative of the document runs from what the app is, outward.
AREA_ORDER = [
    "SSH authentication",
    "Terminal fidelity",
    "SFTP",
    "Port forwarding",
    "VNC",
    "iPad and multi-platform",
    "System integration",
    "Cloudflare",
    "Security and privacy",
]

STATUS_ORDER = [
    "Verified",
    "Partial",
    "Platform Limited",
    "Implemented but Unverified",
    "Planned",
    "Removed",
]

STATUS_RULE = {
    "Verified": "May appear in screenshots, the subtitle, and headline copy.",
    "Partial": "May be described **only** with its limit stated in the same sentence.",
    "Platform Limited": "May be described **only** with the platform limit stated.",
    "Implemented but Unverified": "**Must not** appear in any public claim. Disclosed to App Review instead.",
    "Planned": "**Must not** appear anywhere.",
    "Removed": "**Must not** appear anywhere. Listed so a later writer does not resurrect it.",
}


def area_sort_key(area: dict) -> int:
    name = area["area"]
    for index, prefix in enumerate(AREA_ORDER):
        if name.startswith(prefix):
            return index
    return len(AREA_ORDER)


def escape(text: str) -> str:
    """Makes a free-text field safe inside a Markdown table cell."""
    return (text or "").replace("|", "\\|").replace("\n", " ").strip()


def render(areas: list[dict]) -> str:
    counts: Counter[str] = Counter()
    for area in areas:
        for capability in area["capabilities"]:
            counts[capability["status"]] += 1
    total = sum(counts.values())

    out: list[str] = []
    add = out.append

    add("# Product truth matrix — Apex Terminal\n")
    add(
        "**Generated:** 2026-09-10 · **From:** the working tree at commit `8434a31` ·\n"
        "**By:** `automation/render_truth_matrix.py` from a nine-way parallel audit in which\n"
        "each area was read out of the source and the tests rather than out of the project's\n"
        "own prose.\n"
    )
    add(
        "This file is the gate. A capability may be advertised only at the strength its status\n"
        "here allows, and every other document in this rebuild cites back to it. Nothing was\n"
        "given a status because an earlier document claimed it.\n"
    )

    add("## The rule attached to each status\n")
    add("| Status | Count | What marketing may do with it |")
    add("| --- | ---: | --- |")
    for status in STATUS_ORDER:
        if counts.get(status):
            add(f"| **{status}** | {counts[status]} | {STATUS_RULE[status]} |")
    add(f"\n**{total} capabilities audited**, {counts['Verified']} of them Verified.\n")

    add("### What 'Verified' required\n")
    add(
        "Code exists, **and** a test exercises it against something real — a real `sshd`, a real\n"
        "server, a real container, a real Keychain — **and** it is not listed as blocked in\n"
        "`docs/HUMAN_ACTIONS.md`. A unit test over a hand-built fixture is not enough on its own;\n"
        "where that is all there is, the status is *Implemented but Unverified*.\n"
    )

    add("---\n")

    for area in sorted(areas, key=area_sort_key):
        add(f"## {area['area']}\n")
        if area.get("notes"):
            add(f"> **What a writer must not get wrong here.** {area['notes'].strip()}\n")

        by_status: dict[str, list[dict]] = {}
        for capability in area["capabilities"]:
            by_status.setdefault(capability["status"], []).append(capability)

        for status in STATUS_ORDER:
            group = by_status.get(status)
            if not group:
                continue
            add(f"### {status}\n")
            add("| Capability | What it lets a person do | Code | Test | Limits | Shot |")
            add("| --- | --- | --- | --- | --- | :---: |")
            for capability in sorted(group, key=lambda c: c["name"]):
                shot = "●" if capability.get("screenshot_worthy") else "—"
                add(
                    f"| **{escape(capability['name'])}** "
                    f"| {escape(capability['user_value'])} "
                    f"| {escape(capability['code_evidence'])} "
                    f"| {escape(capability['test_evidence'])} "
                    f"| {escape(capability['limits'])} "
                    f"| {shot} |"
                )
            add("")

        if area.get("accessibility_identifiers"):
            identifiers = ", ".join(f"`{i}`" for i in sorted(set(area["accessibility_identifiers"])))
            add(f"**Accessibility identifiers in this area** (for the capture run): {identifiers}\n")

        add("---\n")

    add("## Capabilities that may be photographed\n")
    add(
        "Verified **and** reachable in the running interface. The screenshot plan draws only\n"
        "from this list.\n"
    )
    add("| Area | Capability |")
    add("| --- | --- |")
    for area in sorted(areas, key=area_sort_key):
        short = area["area"].split("—")[0].split("(")[0].strip()
        for capability in sorted(area["capabilities"], key=lambda c: c["name"]):
            if capability["status"] == "Verified" and capability.get("screenshot_worthy"):
                add(f"| {escape(short)} | {escape(capability['name'])} |")
    add("")

    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    areas = json.loads(Path(sys.argv[1]).read_text())
    Path(sys.argv[2]).write_text(render(areas))
    print(f"wrote {sys.argv[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
