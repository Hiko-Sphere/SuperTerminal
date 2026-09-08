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

# The product name, wherever a person reads it, is spelled with a space. The compact form
# is the identifier — the module, the target, the log subsystem — and belongs nowhere in a
# sentence. The rename missed the Face ID prompt because it lives in a build setting and in
# InfoPlist.xcstrings, neither of which the catalog walk below covers.
name_problems=0
while IFS= read -r line; do
  echo "  $line"
  name_problems=1
done < <(grep -nE 'INFOPLIST_KEY_[A-Za-z]*UsageDescription = "[^"]*ApexTerminal' \
           "$ROOT/ApexTerminal.xcodeproj/project.pbxproj" || true)
while IFS= read -r line; do
  echo "  $line"
  name_problems=1
done < <(grep -n '"value" : "[^"]*ApexTerminal' \
           "$ROOT/App/Resources/InfoPlist.xcstrings" "$ROOT/App/Resources/AppShortcuts.xcstrings" 2>/dev/null || true)
if [[ "$name_problems" == "1" ]]; then
  echo "a user-facing string spells the product without its space (see above)" >&2
  exit 1
fi

exec python3 "$ROOT/scripts/localization-audit.py" "$DERIVED"
