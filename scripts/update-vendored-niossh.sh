#!/usr/bin/env bash
#
# Re-syncs the vendored swift-nio-ssh to a chosen upstream tag and re-applies the RSA
# patch.
#
# Vendoring security-critical code means upstream fixes no longer arrive on their own.
# This script is the discipline that makes that survivable: the change is kept as a patch
# rather than as edits merged into the tree, so a re-sync is mechanical and a patch that
# no longer applies fails loudly instead of being quietly hand-merged.
#
# Usage:  ./scripts/update-vendored-niossh.sh [tag]     (default: the current tag)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Packages/swift-nio-ssh-rsa"
PATCH="$ROOT/patches/niossh-rsa.patch"
TAG="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$PATCH" ]]; then
  echo "No patch at $PATCH — nothing to re-apply." >&2
  exit 1
fi

git clone --quiet https://github.com/apple/swift-nio-ssh.git "$WORK/upstream"
cd "$WORK/upstream"

if [[ -z "$TAG" ]]; then
  echo "Available tags (newest first):"
  git tag --sort=-creatordate | head -10
  echo
  echo "Current vendored commit: $(cat "$VENDOR/UPSTREAM_COMMIT")"
  echo "Re-run with a tag to update, e.g. ./scripts/update-vendored-niossh.sh 0.16.0"
  exit 0
fi

git checkout --quiet "$TAG"
COMMIT="$(git rev-parse HEAD)"

# Replace the vendored tree wholesale, then re-apply the patch. Merging by hand is how a
# vendored fork silently diverges.
rm -rf "$VENDOR/Sources" "$VENDOR/Tests"
cp -R "$WORK/upstream/Sources" "$VENDOR/Sources"
cp -R "$WORK/upstream/Tests" "$VENDOR/Tests"
cp "$WORK/upstream/LICENSE.txt" "$VENDOR/LICENSE.txt"
echo "$COMMIT" > "$VENDOR/UPSTREAM_COMMIT"

cd "$VENDOR"
if ! git apply --check "$PATCH" 2>/dev/null; then
  echo "::error:: The RSA patch no longer applies to $TAG." >&2
  echo "Rebase patches/niossh-rsa.patch by hand, or check whether upstream has added RSA" >&2
  echo "— in which case delete this package and depend on upstream directly." >&2
  exit 1
fi
git apply "$PATCH"

echo "Vendored swift-nio-ssh at $TAG ($COMMIT) with the RSA patch applied."
echo "Now run: (cd $VENDOR && swift test) to check upstream's own suite still passes."
