#!/usr/bin/env bash
#
# Fails if any string a user can read is untranslated.
#
# Builds with SWIFT_EMIT_LOC_STRINGS=YES so the compiler writes out exactly the keys the app
# will look up at runtime, then checks each String Catalog against them. Reading the source
# instead would not do: SwiftUI turns an interpolated literal into a %@ key, so a
# source-derived list disagrees with the binary precisely where mistakes are easiest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"

cd "$ROOT"
# The project's usual derived data, not a private one: a second location makes Xcode
# re-resolve the package graph, which is both slow and a source of spurious failures.
DERIVED="$(xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Debug -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/[[:space:]]BUILD_DIR = /{print $2; exit}')"
DERIVED="${DERIVED%/Build/Products}"
[[ -n "$DERIVED" ]] || { echo "could not locate DerivedData"; exit 2; }

xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Debug -destination "$DESTINATION" \
  SWIFT_EMIT_LOC_STRINGS=YES build > /dev/null

exec python3 "$ROOT/scripts/localization-audit.py" "$DERIVED"
