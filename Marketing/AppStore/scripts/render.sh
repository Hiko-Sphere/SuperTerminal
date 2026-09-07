#!/usr/bin/env bash
#
# Lays the captured screenshots out on the store canvas and writes the final files.
#
# Deterministic: the same `raw/` images and the same `scripts/shotlist.json` produce the
# same output every time. Nothing here retouches the app's own pixels — the screenshot is
# scaled by one factor on both axes, rounded at the corners, and outlined with a hairline.
# It is never recoloured, never stretched and never cropped through anything the app drew.
#
# Usage:  Marketing/AppStore/scripts/render.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$ROOT/Marketing/AppStore"

printf '\n\033[1m▸ Rendering the final images\033[0m\n'
rm -rf "$OUT/final" "$OUT/preview"
# `swift` rather than a Python imaging library: CoreText is what puts the system font on
# the canvas, and it is what falls back to the system's Chinese face for the Simplified
# Chinese captions without a font file having to be found, licensed or shipped.
swift "$OUT/scripts/Render.swift" "$OUT"

printf '\n\033[1m▸ Recording what was rendered\033[0m\n'
python3 "$OUT/scripts/write_manifest.py"
