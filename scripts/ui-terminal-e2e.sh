#!/usr/bin/env bash
#
# Drives the app's UI to a live terminal against a real OpenSSH server.
#
# The app-hosted tests prove the session and emulator work; these prove the *interface*
# does — that tapping a connection reaches a terminal, that typing arrives, and that the
# on-screen Control key sends ^C. Those only exist at the UI layer.
#
# Usage:  ./scripts/ui-terminal-e2e.sh ["platform=iOS Simulator,name=iPhone 17 Pro"]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
WORK="$(mktemp -d)"

cleanup() {
  if [[ -f "$WORK/sshd.pid" ]]; then kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -t ed25519 -f "$WORK/host_ed25519" -N '' -q -C st-ui-host
ssh-keygen -t ed25519 -f "$WORK/client" -N '' -q -C st-ui-client
cp "$WORK/client.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys" "$WORK/host_ed25519" "$WORK/client"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cat > "$WORK/sshd_config" <<CONFIG
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/host_ed25519
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
CONFIG

/usr/sbin/sshd -f "$WORK/sshd_config" -D -e > "$WORK/sshd.log" 2>&1 &
echo $! > "$WORK/sshd.pid"
for _ in $(seq 1 60); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.2; done
nc -z 127.0.0.1 "$PORT" || { echo "sshd did not start:"; cat "$WORK/sshd.log"; exit 1; }
echo "Test sshd listening on 127.0.0.1:$PORT"

cd "$ROOT"
# xcodebuild refuses to overwrite a result bundle, so a second local run would fail
# before a single test ran. CI never sees this; a developer's checkout does.
BUNDLE="${ST_RESULT_BUNDLE:-$ROOT/.build/ui-terminal.xcresult}"
rm -rf "$BUNDLE"
exec env \
  TEST_RUNNER_ST_UITEST_SEED=1 \
  TEST_RUNNER_ST_UITEST_HOST=127.0.0.1 \
  TEST_RUNNER_ST_UITEST_PORT="$PORT" \
  TEST_RUNNER_ST_UITEST_USER="$(whoami)" \
  TEST_RUNNER_ST_UITEST_KEY="$(cat "$WORK/client")" \
  TEST_RUNNER_ST_UITEST_TRUST_HOST_KEYS=1 \
  TEST_RUNNER_ST_UITEST_NAME="Local Test Server" \
  xcodebuild test \
    -project SuperTerminal.xcodeproj \
    -scheme SuperTerminal \
    -destination "$DESTINATION" \
    -resultBundlePath "$BUNDLE" \
    -parallel-testing-enabled NO \
    -only-testing:SuperTerminalUITests

# Parallel testing is off deliberately. Xcode clones the simulator per worker, and the
# clones race to install the runner — which fails intermittently with "Application failed
# preflight checks" and reports a non-zero exit even when every test passed. The tests
# also share one sshd, so running them in parallel buys nothing.
