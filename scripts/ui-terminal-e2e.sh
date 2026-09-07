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

ROOT="${ST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
# A single test or class can be repeated on its own — the way an intermittent crash is
# measured — without editing this file: ST_ONLY_TESTING=ApexTerminalUITests/SomeClass/testX
# Several, comma-separated, become several flags: xcodebuild takes one identifier per
# -only-testing, and passing a comma-separated list to one flag silently runs nothing.
ONLY_TESTING="${ST_ONLY_TESTING:-ApexTerminalUITests}"
ONLY_TESTING_FLAGS=()
IFS=',' read -ra ONLY_TESTING_PARTS <<< "$ONLY_TESTING"
for part in "${ONLY_TESTING_PARTS[@]}"; do
  [[ -n "$part" ]] && ONLY_TESTING_FLAGS+=("-only-testing:$part")
done
WORK="$(mktemp -d)"

XCODEBUILD_PID=""
cleanup() {
  if [[ -n "$XCODEBUILD_PID" ]]; then kill "$XCODEBUILD_PID" 2>/dev/null || true; fi
  if [[ -f "$WORK/sshd.pid" ]]; then kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true; fi
  if [[ -f "$WORK/vnc.pid" ]]; then kill "$(cat "$WORK/vnc.pid")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# A killed harness must take xcodebuild with it, or the next run finds the simulator busy.
trap 'exit 143' TERM INT

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

# A real VNC server for the screen tests (D-022): LibVNCServer from Homebrew, driving the
# same small program the package tests use. It listens on loopback only; the app reaches
# it through a direct-tcpip channel on the SSH connection above. Without the library the
# screen tests skip, and say so.
VNC_PORT=""
VNC_LOG="$WORK/vnc-events.log"
VNC_SRC="$ROOT/Packages/ApexTerminalKit/Sources/STTestSupport/Fixtures/vnc-test-server.c"
for prefix in /opt/homebrew/opt/libvncserver /usr/local/opt/libvncserver; do
  [[ -f "$prefix/include/rfb/rfb.h" ]] || continue
  if cc -O2 -o "$WORK/vnc-test-server" "$VNC_SRC" -I"$prefix/include" -L"$prefix/lib" -lvncserver -Wl,-rpath,"$prefix/lib" 2> "$WORK/vnc-cc.log"; then
    VNC_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    "$WORK/vnc-test-server" "$VNC_PORT" "$VNC_LOG" > "$WORK/vnc.log" 2>&1 &
    echo $! > "$WORK/vnc.pid"
    for _ in $(seq 1 50); do grep -q listening "$VNC_LOG" 2>/dev/null && break; sleep 0.1; done
    grep -q listening "$VNC_LOG" || { echo "VNC test server did not start:"; cat "$WORK/vnc.log"; exit 1; }
    echo "Test VNC server listening on 127.0.0.1:$VNC_PORT"
  else
    echo "VNC test server did not compile; the screen tests will skip:"; cat "$WORK/vnc-cc.log"
  fi
  break
done
[[ -n "$VNC_PORT" ]] || echo "LibVNCServer is not installed (brew install libvncserver); the screen tests will skip"

cd "$ROOT"
# xcodebuild refuses to overwrite a result bundle, so a second local run would fail
# before a single test ran. CI never sees this; a developer's checkout does.
BUNDLE="${ST_RESULT_BUNDLE:-$ROOT/.build/ui-terminal.xcresult}"
rm -rf "$BUNDLE"
# Run as a child, not with exec: exec replaced this shell with xcodebuild, so the EXIT
# trap never ran and every run left its sshd listening — over a hundred were found.
env \
  TEST_RUNNER_ST_UITEST_SEED=1 \
  TEST_RUNNER_ST_UITEST_HOST=127.0.0.1 \
  TEST_RUNNER_ST_UITEST_PORT="$PORT" \
  TEST_RUNNER_ST_UITEST_USER="$(whoami)" \
  TEST_RUNNER_ST_UITEST_KEY="$(cat "$WORK/client")" \
  TEST_RUNNER_ST_UITEST_TRUST_HOST_KEYS=1 \
  TEST_RUNNER_ST_UITEST_NAME="Local Test Server" \
  TEST_RUNNER_ST_UITEST_VNC_PORT="$VNC_PORT" \
  TEST_RUNNER_ST_UITEST_VNC_LOG="$VNC_LOG" \
  xcodebuild test \
    -project ApexTerminal.xcodeproj \
    -scheme ApexTerminal \
    -destination "$DESTINATION" \
    -resultBundlePath "$BUNDLE" \
    -parallel-testing-enabled NO \
    "${ONLY_TESTING_FLAGS[@]}" &
XCODEBUILD_PID=$!
STATUS=0
wait "$XCODEBUILD_PID" || STATUS=$?
XCODEBUILD_PID=""
exit "$STATUS"

# Parallel testing is off deliberately. Xcode clones the simulator per worker, and the
# clones race to install the runner — which fails intermittently with "Application failed
# preflight checks" and reports a non-zero exit even when every test passed. The tests
# also share one sshd, so running them in parallel buys nothing.
