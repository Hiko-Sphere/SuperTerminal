#!/usr/bin/env bash
#
# Regenerates patches/niossh-rsa.patch as the cumulative difference between the vendored
# tree and pristine upstream.
#
# This exists because getting it wrong is easy and silent: `git diff HEAD` produces only
# the *uncommitted* changes, which looks like a valid patch and quietly omits everything
# already committed. The patch would then apply cleanly to upstream and produce a library
# missing most of the change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The commit that vendored upstream unmodified. Everything after it is ours.
BASE="$(git log --format=%H --reverse -- Packages/swift-nio-ssh-rsa | head -1)"
echo "Pristine vendor commit: $BASE"

git add -N Packages/swift-nio-ssh-rsa >/dev/null 2>&1 || true
git diff "$BASE" -- Packages/swift-nio-ssh-rsa > patches/niossh-rsa.patch

FILES="$(grep -c '^diff --git' patches/niossh-rsa.patch || echo 0)"
LINES="$(wc -l < patches/niossh-rsa.patch)"
echo "Wrote patches/niossh-rsa.patch: $FILES files, $LINES lines"

if [[ "$FILES" -lt 5 ]]; then
  echo "::error:: only $FILES files in the patch — that is too few for the RSA change." >&2
  echo "The base commit is probably wrong; the patch must be the cumulative difference" >&2
  echo "from the pristine vendor, not from HEAD." >&2
  exit 1
fi
