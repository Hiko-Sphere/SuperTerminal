#!/usr/bin/env bash
#
# Runs the live Cloudflare end-to-end suite against a real tunnel and a real Access
# application. Everything else in the test suite runs without credentials; this is the
# only part that cannot.
#
# Nothing here is stored in the repository. Export the variables in your shell, or keep
# them in a file outside the working tree and source it:
#
#   set -a; source ~/.apexterminal-live.env; set +a
#   ./scripts/live-e2e.sh
#
# Required
#   ST_LIVE_CF_HOSTNAME              hostname published by the tunnel, e.g. ssh.example.com
#   ST_LIVE_SSH_USER                 SSH username on the origin host
#
# Access credential — required for the automated run
#   ST_LIVE_CF_SERVICE_TOKEN_ID      Access service token client ID  (…​.access)
#   ST_LIVE_CF_SERVICE_TOKEN_SECRET  Access service token client secret
#
#   The service token is what makes this runnable without a browser. Interactive SSO and
#   MFA login is exercised from the app, not from here.
#
# SSH credential — exactly one
#   ST_LIVE_SSH_KEY_PATH             path to an OpenSSH private key
#   ST_LIVE_SSH_KEY_PASSPHRASE       its passphrase, if it has one
#   ST_LIVE_SSH_PASSWORD             password, if the server allows password auth
#
# Optional
#   ST_LIVE_CF_JUMP_DESTINATION      host:port, when the tunnel runs in bastion mode
#   ST_LIVE_SSH_HOST_FINGERPRINT     SHA256:… to pin instead of trusting on first use
#
set -euo pipefail

if [[ -z "${ST_LIVE_CF_HOSTNAME:-}" ]]; then
  echo "ST_LIVE_CF_HOSTNAME is not set; see the comments at the top of this script." >&2
  exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/ApexTerminalKit"
exec swift test --filter LiveCloudflareE2ETests
