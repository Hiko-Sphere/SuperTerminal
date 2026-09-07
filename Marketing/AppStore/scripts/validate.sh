#!/usr/bin/env bash
#
# Checks every final image and every line of copy against Apple's rules and against this
# project's own rule that nothing is claimed which has not been seen to run.
#
# Fails loudly. A screenshot that is the wrong size, carries an alpha channel, has been
# stretched, or shows something that should not be in it is a rejection at review; better
# to find it here.
#
# Usage:  Marketing/AppStore/scripts/validate.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec python3 "$ROOT/Marketing/AppStore/scripts/validate.py" "$ROOT/Marketing/AppStore"
