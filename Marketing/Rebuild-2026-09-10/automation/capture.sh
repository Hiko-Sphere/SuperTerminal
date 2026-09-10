#!/usr/bin/env bash
#
# Captures the 2026-09 store screenshots from the real app, against real servers.
#
#   1. builds the current app for the simulator;
#   2. builds one fixture image and starts four isolated servers from it —
#      edge-01 (sshd + SFTP + a real X desktop over VNC + an HTTP service to forward to),
#      db-primary, build-runner, and ops-box (which runs tmux). Every account is the
#      fictional `deploy`; every address is under `*.localhost`, reserved by RFC 6761;
#   3. boots each simulator the store sizes come from, removes any previous install, and
#      pins the status bar to 9:41 with a full battery and no carrier clutter;
#   4. runs `RebuildCaptureTests`, which drives the real interface and photographs it;
#   5. exports the attachments to `raw/<device>/<locale>/`.
#
# Nothing fabricates an interface or a result. Every session is a real key exchange with a
# real sshd, every file listing is a real SFTP listing, the forward carries a real SSH
# session of its own so its counters are real numbers, the tmux panes belong to a real
# tmux server, and the desktop is a real X session decoded from real RFB.
#
# Usage:  Marketing/Rebuild-2026-09-10/automation/capture.sh [test-name ...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$ROOT/Marketing/Rebuild-2026-09-10"
WORK="$OUT/automation/build"
mkdir -p "$WORK"

IPHONE69_NAME="${ST_SHOT_IPHONE69:-iPhone 17 Pro Max}"
IPHONE65_NAME="${ST_SHOT_IPHONE65:-iPhone 14 Plus}"
IPHONE65_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus
IPAD_NAME="${ST_SHOT_IPAD:-iPad Air 13-inch (M4)}"
RUNTIME="${ST_SHOT_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
LOCALES=(${ST_SHOT_LOCALES:-en-US zh-Hans zh-Hant})
IMAGE=apexterminal-capture:2
BUNDLE_ID=dev.apexterminal.app
PASSWORD=capture-only-pw

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- fixtures

CONTAINERS=(cap-edge-01 cap-db-primary cap-build-runner cap-ops-box)

cleanup_containers() {
  for name in "${CONTAINERS[@]}"; do docker rm -f "$name" >/dev/null 2>&1 || true; done
}

start_fixtures() {
  say "Building the fixture image"
  docker build -q -t "$IMAGE" "$OUT/automation/fixture" >/dev/null

  say "Starting four servers"
  cleanup_containers
  rm -f "$WORK/shots_key" "$WORK/shots_key.pub"
  ssh-keygen -t ed25519 -f "$WORK/shots_key" -N '' -q -C apexterminal-capture
  local key; key="$(cat "$WORK/shots_key.pub")"

  # Published on both stacks: `*.localhost` resolves to ::1 as well as 127.0.0.1, and a
  # v6 gap makes the app's first attempt hang rather than fail over.
  #
  # edge-01 also runs the desktop (Xvnc on 5901, loopback only — the app reaches it
  # through a direct-tcpip channel on the SSH connection, which is the "nothing exposed"
  # route the screenshot claims) and the HTTP service on 8080.
  docker run -d --name cap-edge-01      --hostname edge-01      -e WITH_DESKTOP=1 -e DEPLOY_PASSWORD="$PASSWORD" \
    -p 127.0.0.1:22:22   -p '[::1]:22:22'   -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null
  docker run -d --name cap-db-primary   --hostname db-primary   -e DEPLOY_PASSWORD="$PASSWORD" \
    -p 127.0.0.1:2201:22 -p '[::1]:2201:22' -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null
  docker run -d --name cap-build-runner --hostname build-runner -e DEPLOY_PASSWORD="$PASSWORD" \
    -p 127.0.0.1:2202:22 -p '[::1]:2202:22' -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null
  docker run -d --name cap-ops-box      --hostname ops-box      -e DEPLOY_PASSWORD="$PASSWORD" \
    -p 127.0.0.1:2203:22 -p '[::1]:2203:22' -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null

  for port in 22 2201 2202 2203; do
    for _ in $(seq 1 60); do
      ssh -i "$WORK/shots_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=2 -p "$port" deploy@127.0.0.1 true 2>/dev/null && break
      sleep 1
    done
  done
  echo "  edge-01 :22 (+desktop :5901, http :8080)   db-primary :2201   build-runner :2202   ops-box :2203 (tmux)"
}

# ---------------------------------------------------------------- simulators

udid_for() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
name = sys.argv[1]
for runtime, items in sorted(json.load(sys.stdin)['devices'].items(), reverse=True):
    for item in items:
        if item['name'] == name:
            print(item['udid']); raise SystemExit
raise SystemExit('no simulator named ' + name)
" "$1"
}

prepare_device() {
  local udid="$1"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  # A previous install would already trust the fixtures' host keys and carry keys from an
  # earlier pass; every pass starts from nothing.
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # Light interface: the app's chrome is the pale one the store canvas is built around,
  # while the terminal itself is set to the dark theme through the app's own setting.
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode notSupported --batteryState discharging --batteryLevel 100 >/dev/null 2>&1 || true
  # iOS offers its keyboard tutorials ("slide to type…") on a device that has never shown
  # them, and the card lands on top of the app mid-capture. A freshly created simulator is
  # exactly that device, which is how one reached a finished screenshot.
  for key in DidShowContinuousPathIntroduction DidShowGestureKeyboardIntroduction \
             KeyboardDidShowProductivityTutorial DidShowGestureKeyboardIntroductionOnPad; do
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences "$key" -bool true >/dev/null 2>&1 || true
  done
  xcrun simctl spawn "$udid" defaults write com.apple.Preferences UIKeyboardDidShowInternationalInfoIntroduction -bool true >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- the run

# db-primary and build-runner are plain hosts; ops-box carries tmux; "edge-01 via tunnel"
# addresses the forward's own listening port on the device, so opening it is a real SSH
# session carried by the tunnel and the forward's counters become real numbers.
HOSTS_JSON='[
 {"name":"db-primary","hostname":"db-primary.localhost","port":2201,"username":"deploy"},
 {"name":"build-runner","hostname":"build-runner.localhost","port":2202,"username":"deploy"},
 {"name":"edge-01 via tunnel","hostname":"127.0.0.1","port":8080,"username":"deploy"}
]'

ONLY=()
for name in "$@"; do ONLY+=("-only-testing:ApexTerminalUITests/RebuildCaptureTests/$name"); done
[[ ${#ONLY[@]} -eq 0 ]] && ONLY=("-only-testing:ApexTerminalUITests/RebuildCaptureTests")

run_pass() {
  if ! run_pass_once "$@"; then
    echo "  retrying $1 · $4"
    run_pass_once "$@"
  fi
}

run_pass_once() {
  local device_key="$1" device_name="$2" orientation="$3" locale="$4"
  local udid; udid="$(udid_for "$device_name")"
  say "Capturing $device_key · $locale · $orientation ($device_name)"
  prepare_device "$udid"

  local bundle="$WORK/$device_key-$locale.xcresult"
  rm -rf "$bundle"
  env \
    TEST_RUNNER_ST_REBUILD_CAPTURE=1 \
    TEST_RUNNER_ST_CAPTURE_LANGUAGE="$locale" \
    TEST_RUNNER_ST_CAPTURE_ORIENTATION="$orientation" \
    TEST_RUNNER_ST_UITEST_SEED=1 \
    TEST_RUNNER_ST_UITEST_HOST=edge-01.localhost \
    TEST_RUNNER_ST_UITEST_PORT=22 \
    TEST_RUNNER_ST_UITEST_USER=deploy \
    TEST_RUNNER_ST_UITEST_NAME=edge-01 \
    TEST_RUNNER_ST_UITEST_KEY="$(cat "$WORK/shots_key")" \
    TEST_RUNNER_ST_UITEST_HOSTS="$HOSTS_JSON" \
    TEST_RUNNER_ST_UITEST_TERMINAL_THEME="${ST_SHOT_THEME:-midnight}" \
    TEST_RUNNER_ST_UITEST_VNC_PORT=5901 \
    TEST_RUNNER_ST_UITEST_SCREEN_NAME="edge-01 desktop" \
    TEST_RUNNER_ST_UITEST_FORWARD_PORT=8080 \
    TEST_RUNNER_ST_UITEST_FORWARD_NAME="api on edge-01" \
    TEST_RUNNER_ST_UITEST_TUNNEL_NAME="edge-01 via tunnel" \
    TEST_RUNNER_ST_UITEST_TMUX_PORT=2203 \
    TEST_RUNNER_ST_UITEST_TMUX_HOST=ops-box.localhost \
    TEST_RUNNER_ST_UITEST_TMUX_USER=deploy \
    TEST_RUNNER_ST_UITEST_TMUX_PASSWORD="$PASSWORD" \
    TEST_RUNNER_ST_UITEST_TMUX_NAME=ops-box \
    xcodebuild test \
      -project "$ROOT/ApexTerminal.xcodeproj" \
      -scheme ApexTerminal \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$ROOT/build/dd" \
      -resultBundlePath "$bundle" \
      -parallel-testing-enabled NO \
      "${ONLY[@]}" \
      > "$WORK/$device_key-$locale.log" 2>&1 || {
        echo "  xcodebuild test failed — tail of ${WORK#$ROOT/}/$device_key-$locale.log:"
        tail -30 "$WORK/$device_key-$locale.log"
        return 1
      }

  local raw="$OUT/app-store/raw-screenshots/$device_key/$locale"
  rm -rf "$raw"; mkdir -p "$raw"
  local exported="$WORK/attachments-$device_key-$locale"
  rm -rf "$exported"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$exported" >/dev/null
  # Spelled out rather than expanded from an array: macOS ships bash 3.2, where an empty
  # array under `set -u` is an unbound variable and aborts the run.
  if [[ "$orientation" == "landscape" ]]; then
    python3 "$ROOT/Marketing/AppStore/scripts/collect_attachments.py" "$exported" "$raw" --landscape
  else
    python3 "$ROOT/Marketing/AppStore/scripts/collect_attachments.py" "$exported" "$raw"
  fi
  echo "  → $(ls "$raw" | wc -l | tr -d ' ') images in ${raw#$ROOT/}"
}

# ---------------------------------------------------------------- main

trap 'cleanup_containers' EXIT

say "Building the app"
xcodebuild build-for-testing \
  -project "$ROOT/ApexTerminal.xcodeproj" \
  -scheme ApexTerminal \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$IPHONE69_NAME" \
  -derivedDataPath "$ROOT/build/dd" > "$WORK/build.log" 2>&1 || {
    echo "build failed:"; tail -30 "$WORK/build.log"; exit 1; }

# The 6.5" device is not part of a default Xcode install; make it rather than assume it.
if ! xcrun simctl list devices available | grep -q "^ *$IPHONE65_NAME "; then
  say "Creating the $IPHONE65_NAME simulator"
  xcrun simctl create "$IPHONE65_NAME" "$IPHONE65_TYPE" "$RUNTIME" >/dev/null
fi

start_fixtures

for locale in "${LOCALES[@]}"; do
  run_pass iphone69 "$IPHONE69_NAME" portrait  "$locale"
  run_pass iphone65 "$IPHONE65_NAME" portrait  "$locale"
  run_pass ipad     "$IPAD_NAME"     landscape "$locale"
done

say "Done. Raw captures are in Marketing/Rebuild-2026-09-10/app-store/raw-screenshots/"
