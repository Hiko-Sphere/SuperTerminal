#!/usr/bin/env bash
#
# Captures the App Store screenshots from the real app, against real SSH servers.
#
# What this does, in order:
#
#   1. builds the current app for the simulator;
#   2. builds and starts three isolated OpenSSH servers in containers — `edge-01`,
#      `db-primary` and `build-runner`, each with a fictional `deploy` account and a
#      seeded home directory, so nothing belonging to the person running this can appear
#      in a screenshot;
#   3. boots the simulators the store sizes come from, removes any previous install so
#      the host-key sheet is genuinely a first connection, and pins the status bar;
#   4. runs `MarketingCaptureTests`, which drives the real interface and photographs it;
#   5. exports the attachments to `raw/<device>/<locale>/`.
#
# Nothing here fabricates an interface or an SSH result. Every session in the output is a
# real key exchange with a real `sshd`, and every command's output came back over it.
#
# Usage:  Marketing/AppStore/scripts/capture.sh [test-name ...]
#         (with no arguments, every capture runs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$ROOT/Marketing/AppStore"
WORK="$OUT/build"
mkdir -p "$WORK"

IPHONE_NAME="${ST_SHOT_IPHONE:-iPhone 17 Pro Max}"
# The Air rather than the Pro: this machine's other simulator work uses the Pro, and
# two `xcodebuild test` runs on one device make the accessibility server drop out
# mid-test. Both produce an accepted iPad 13" size natively.
IPAD_NAME="${ST_SHOT_IPAD:-iPad Air 13-inch (M4)}"
LOCALES=(${ST_SHOT_LOCALES:-en-US zh-Hans})
IMAGE=apexterminal-shots-fixture:1

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- fixtures

cleanup_containers() {
  for name in st-edge-01 st-db-primary st-build-runner; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}

start_fixtures() {
  say "Building the SSH fixture image"
  docker build -q -t "$IMAGE" "$OUT/scripts/fixture" >/dev/null

  say "Starting three OpenSSH servers"
  cleanup_containers
  rm -f "$WORK/shots_key" "$WORK/shots_key.pub"
  ssh-keygen -t ed25519 -f "$WORK/shots_key" -N '' -q -C apexterminal-capture
  local key; key="$(cat "$WORK/shots_key.pub")"

  # `edge-01` takes port 22 so its address reads the way a server's address normally
  # does; the other two take alternate ports, which is also how real machines are run.
  # The names are `*.localhost`, reserved by RFC 6761 and resolved to the loopback
  # address by the host — a real name for a real local server, and one that can never be
  # mistaken for somebody's production box.
  # Published on both stacks. `*.localhost` resolves to ::1 as well as 127.0.0.1, and a
  # v6-only publish gap makes the app's first connection attempt hang rather than fail
  # over — which shows up as a terminal that never prints a prompt.
  docker run -d --name st-edge-01      --hostname edge-01      -p 127.0.0.1:22:22   -p '[::1]:22:22'   -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null
  docker run -d --name st-db-primary   --hostname db-primary   -p 127.0.0.1:2201:22 -p '[::1]:2201:22' -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null
  docker run -d --name st-build-runner --hostname build-runner -p 127.0.0.1:2202:22 -p '[::1]:2202:22' -e AUTHORIZED_KEY="$key" "$IMAGE" >/dev/null

  for port in 22 2201 2202; do
    for _ in $(seq 1 60); do
      ssh -i "$WORK/shots_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=2 -p "$port" deploy@127.0.0.1 true 2>/dev/null && break
      sleep 1
    done
  done
  echo "  edge-01 :22   db-primary :2201   build-runner :2202"
}

# ---------------------------------------------------------------- simulators

udid_for() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
name = sys.argv[1]
data = json.load(sys.stdin)['devices']
for runtime, items in sorted(data.items(), reverse=True):
    for item in items:
        if item['name'] == name:
            print(item['udid']); raise SystemExit
raise SystemExit('no simulator named ' + name)
" "$1"
}

prepare_device() {
  local udid="$1"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [[ "$(xcrun simctl list devices -j | python3 -c "
import json,sys
u=sys.argv[1]
for items in json.load(sys.stdin)['devices'].values():
    for i in items:
        if i['udid']==u: print(i['state'])
" "$udid")" == "Booted" ]] && break
    sleep 2
  done
  # A previous install would already trust the fixtures' host keys, and the sheet that
  # asks about them is one of the screenshots.
  xcrun simctl uninstall "$udid" dev.apexterminal.app >/dev/null 2>&1 || true
  # Light interface, so the app's own chrome is the pale one the store canvas is built
  # around; the terminal itself is set to the dark theme through the app's own setting.
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  # Deliberately *not* touching the Simulator's "Connect Hardware Keyboard" preference.
  # It was tried: it does not stop XCUITest raising the software keyboard, so it bought
  # this run nothing — and it is a per-device preference that other UI tests on this
  # machine are measurably sensitive to (`PROJECT_STATUS.md`, D-033's regression note).
  # A capture run must not leave a setting behind that turns somebody else's suite red.
  # Where the keyboard has to go away, `MarketingCaptureTests.dismissKeyboard` presses
  # the key the iPad keyboard provides for it.
  # 9:41, full signal, no carrier clutter, a full battery that is not charging-yellow.
  xcrun simctl status_bar "$udid" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode notSupported --batteryState discharging --batteryLevel 100 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- the run

HOSTS_JSON='[{"name":"db-primary","hostname":"db-primary.localhost","port":2201,"username":"deploy"},{"name":"build-runner","hostname":"build-runner.localhost","port":2202,"username":"deploy"}]'

ONLY=()
for name in "$@"; do ONLY+=("-only-testing:ApexTerminalUITests/MarketingCaptureTests/$name"); done
[[ ${#ONLY[@]} -eq 0 ]] && ONLY=("-only-testing:ApexTerminalUITests/MarketingCaptureTests")

# One pass, with a single retry: a busy machine occasionally loses the simulator's
# accessibility server mid-test, which fails a run that has nothing wrong with it.
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
    TEST_RUNNER_ST_CAPTURE=1 \
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
    xcodebuild test-without-building \
      -project "$ROOT/ApexTerminal.xcodeproj" \
      -scheme ApexTerminal \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$ROOT/build/dd" \
      -resultBundlePath "$bundle" \
      -parallel-testing-enabled NO \
      "${ONLY[@]}" \
      > "$WORK/$device_key-$locale.log" 2>&1 || {
        echo "  xcodebuild test failed — tail of $WORK/$device_key-$locale.log:"
        tail -40 "$WORK/$device_key-$locale.log"
        return 1
      }

  local raw="$OUT/raw/$device_key/$locale"
  rm -rf "$raw"; mkdir -p "$raw"
  local exported="$WORK/attachments-$device_key-$locale"
  rm -rf "$exported"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$exported" >/dev/null
  # `${a[@]}` on an empty array is an error under `set -u` in bash 3.2, which is the bash
  # macOS ships; the flag is passed positionally instead.
  local rotate=""
  [[ "$orientation" == landscape ]] && rotate="--landscape"
  python3 "$OUT/scripts/collect_attachments.py" "$exported" "$raw" $rotate
  echo "  → $(ls "$raw" | wc -l | tr -d ' ') images in ${raw#$ROOT/}"
}

# ---------------------------------------------------------------- main

trap 'cleanup_containers' EXIT

say "Building the app"
xcodebuild build-for-testing \
  -project "$ROOT/ApexTerminal.xcodeproj" \
  -scheme ApexTerminal \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$IPHONE_NAME" \
  -derivedDataPath "$ROOT/build/dd" > "$WORK/build.log" 2>&1 || {
    echo "build failed:"; tail -40 "$WORK/build.log"; exit 1; }

start_fixtures

for locale in "${LOCALES[@]}"; do
  run_pass iphone "$IPHONE_NAME" portrait  "$locale"
  run_pass ipad   "$IPAD_NAME"   landscape "$locale"
done

say "Recording what was captured"
python3 "$OUT/scripts/write_manifest.py"

say "Done. Raw captures are in Marketing/AppStore/raw/"
