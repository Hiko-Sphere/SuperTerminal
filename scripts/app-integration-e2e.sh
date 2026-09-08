#!/usr/bin/env bash
#
# Runs the app's own integration tests against a real OpenSSH server.
#
# The package tests prove the SSH and terminal layers work when driven directly. These
# prove the *app* works: the Keychain, the session state machine and the emulator, on a
# simulator or a device, against a server that really exists.
#
# The server runs on this Mac; a simulator shares the host's loopback, so 127.0.0.1
# inside the app reaches it. For a physical device, pass the Mac's LAN address as
# ST_APP_TEST_SSH_HOST_OVERRIDE and make sure the two are on the same network.
#
# Usage:  ./scripts/app-integration-e2e.sh ["platform=iOS Simulator,name=iPhone 17 Pro"]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
WORK="$(mktemp -d)"

cleanup() {
  for pidfile in "$WORK/sshd.pid" "$WORK/sshd2.pid"; do
    if [[ -f "$pidfile" ]]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
    fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# An isolated, unprivileged sshd with its own keys — it cannot touch the machine's real
# SSH configuration.
ssh-keygen -t ed25519 -f "$WORK/host_ed25519" -N '' -q -C st-app-test-host
ssh-keygen -t ed25519 -f "$WORK/client" -N '' -q -C st-app-test-client
cp "$WORK/client.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys" "$WORK/host_ed25519" "$WORK/client"

# A certificate authority, and a key it vouches for that is deliberately absent from
# authorized_keys (D-046). A login with that key proves the server checked the
# certificate, because there is nothing else that could have let it in.
ssh-keygen -t ed25519 -f "$WORK/ca" -N '' -q -C st-app-test-ca
ssh-keygen -t ed25519 -f "$WORK/certified" -N '' -q -C st-app-test-certified
ssh-keygen -s "$WORK/ca" -I st-app-test -n "$(whoami)" -V -5m:+60m "$WORK/certified.pub" >/dev/null
chmod 600 "$WORK/ca" "$WORK/certified"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
PORT2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

cat > "$WORK/sshd_config" <<CONFIG
Port $PORT
ListenAddress ${ST_APP_TEST_SSH_BIND:-127.0.0.1}
HostKey $WORK/host_ed25519
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
TrustedUserCAKeys $WORK/ca.pub
# Without this the sftp subsystem request is refused and the Files integration cannot be
# tested at all — the failure looks like a broken client rather than a server missing a
# line of configuration.
Subsystem sftp internal-sftp
CONFIG

/usr/sbin/sshd -f "$WORK/sshd_config" -D -e > "$WORK/sshd.log" 2>&1 &
echo $! > "$WORK/sshd.pid"

# A second server, for the jump-host tests (D-047). Same keys, its own port and its own
# host key, so a connection that reached it can be told apart from one that stopped at
# the first.
ssh-keygen -t ed25519 -f "$WORK/host2_ed25519" -N '' -q -C st-app-test-host2
chmod 600 "$WORK/host2_ed25519"
sed -e "s|^Port .*|Port $PORT2|" -e "s|^HostKey .*|HostKey $WORK/host2_ed25519|" \
    -e "s|^PidFile .*|PidFile $WORK/sshd2.pid|" "$WORK/sshd_config" > "$WORK/sshd2_config"
/usr/sbin/sshd -f "$WORK/sshd2_config" -D -e > "$WORK/sshd2.log" 2>&1 &
echo $! > "$WORK/sshd2.pid"

for _ in $(seq 1 60); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.2
done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "sshd did not start. Log:" >&2
  cat "$WORK/sshd.log" >&2
  exit 1
fi
for _ in $(seq 1 60); do
  if nc -z 127.0.0.1 "$PORT2" 2>/dev/null; then break; fi
  sleep 0.2
done
if ! nc -z 127.0.0.1 "$PORT2" 2>/dev/null; then
  echo "the second sshd did not start. Log:" >&2
  cat "$WORK/sshd2.log" >&2
  exit 1
fi

FINGERPRINT="$(ssh-keygen -lf "$WORK/host_ed25519.pub" | awk '{print $2}')"
echo "Test sshd listening on 127.0.0.1:$PORT  host key $FINGERPRINT"

cd "$ROOT"

ONLY_TESTING=(-only-testing:"${ST_ONLY_TESTING:-ApexTerminalTests}")

# xcodebuild forwards variables prefixed with TEST_RUNNER_ into the test process on the
# simulator or device, with the prefix stripped. Plain shell variables would only reach
# xcodebuild itself, never the app under test.
#
# One clone, not two. These tests share a single sshd and, for the Files integration, a
# single File Provider domain; running two copies at once has them registering and
# withdrawing the same domain underneath each other.
#
# Run as a child rather than `exec`: an `exec` replaces this shell, so the EXIT trap never
# fires and every run leaves an sshd listening. The same mistake cost a hundred stray
# servers in scripts/ui-terminal-e2e.sh.
env \
  TEST_RUNNER_ST_APP_TEST_SSH_HOST="${ST_APP_TEST_SSH_HOST_OVERRIDE:-127.0.0.1}" \
  TEST_RUNNER_ST_APP_TEST_SSH_PORT="$PORT" \
  TEST_RUNNER_ST_APP_TEST_SSH_USER="$(whoami)" \
  TEST_RUNNER_ST_APP_TEST_SSH_KEY="$(cat "$WORK/client")" \
  TEST_RUNNER_ST_APP_TEST_SSH_HOST_FINGERPRINT="$FINGERPRINT" \
  TEST_RUNNER_ST_APP_TEST_SSH_HOME="$HOME" \
  TEST_RUNNER_ST_APP_TEST_SSH_CERT_KEY="$(cat "$WORK/certified")" \
  TEST_RUNNER_ST_APP_TEST_SSH_CERT="$(cat "$WORK/certified-cert.pub")" \
  TEST_RUNNER_ST_APP_TEST_SSH_PORT2="$PORT2" \
  TEST_RUNNER_ST_APP_TEST_AUTHORIZED_KEYS="$WORK/authorized_keys" \
  xcodebuild test \
    -project ApexTerminal.xcodeproj \
    -scheme ApexTerminal \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    "${ONLY_TESTING[@]}"
STATUS=$?
exit "$STATUS"
