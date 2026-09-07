#!/usr/bin/env bash
#
# Regenerates Sources/STTerminal/CharacterWidthTables.swift from the Unicode Character
# Database. Run this when adopting a new UCD release; the generated file records which
# version it came from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Packages/ApexTerminalKit/Sources/STTerminal/CharacterWidthTables.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE="https://www.unicode.org/Public/UCD/latest/ucd"
curl -fsS -o "$WORK/EastAsianWidth.txt" "$BASE/EastAsianWidth.txt"
curl -fsS -o "$WORK/DerivedGeneralCategory.txt" "$BASE/extracted/DerivedGeneralCategory.txt"

python3 "$ROOT/scripts/generate_width_tables.py" "$WORK" > "$OUT"
echo "Wrote $OUT"
