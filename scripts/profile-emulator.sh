#!/usr/bin/env bash
#
# Records a real Instruments Time Profiler trace of the terminal emulator's hot path and
# prints where the time goes, attributed to our own frames rather than to whichever
# system call happened to be on top of the stack.
#
# The throughput tests already assert floors, which catches a regression. This answers a
# different question — *what* the time is spent on — and it is the question you need
# before optimising anything.
#
# Release, because a Debug profile mostly measures retain/release traffic the optimiser
# would have removed. Run natively on macOS: the emulator is the same code on iOS, and
# profiling it here is what makes it a one-command operation instead of a session with
# a device and a UI to drive.
#
# Usage:  ./scripts/profile-emulator.sh [output.trace]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/.build/emulator.trace}"
PACKAGE="$ROOT/Packages/SuperTerminalKit"
FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
HELPER="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"

# `-enable-testing` on top of Release so `@testable` imports resolve; the emulator itself
# is still optimised, which is the code being measured.
( cd "$PACKAGE" && swift build -c release --build-tests -Xswiftc -enable-testing >/dev/null )
BINARY="$PACKAGE/.build/arm64-apple-macosx/release/SuperTerminalKitPackageTests.xctest/Contents/MacOS/SuperTerminalKitPackageTests"
[[ -x "$BINARY" ]] || { echo "test binary not found at $BINARY"; exit 1; }

rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
# The framework path has to be passed through explicitly: xctrace does not inherit the
# environment into the process it launches, and without it the bundle fails to dlopen.
xcrun xctrace record \
  --template 'Time Profiler' \
  --output "$OUTPUT" \
  --env "DYLD_FRAMEWORK_PATH=$FRAMEWORKS" \
  --target-stdout - \
  --launch -- "$HELPER" \
    --test-bundle-path "$BINARY" "$BINARY" \
    --testing-library swift-testing \
    --filter "TerminalThroughputTests" >/dev/null

XML="$(mktemp -t emulator-profile).xml"
trap 'rm -f "$XML"' EXIT
xcrun xctrace export --input "$OUTPUT" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "$XML" >/dev/null

python3 - "$XML" <<'PYTHON'
import collections
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

# Instruments writes each distinct value once with an id and refers back to it after
# that, so both forms have to be resolved or almost every row reads as empty.
weights, backtraces, frames = {}, {}, {}

def frame_name(element):
    identifier = element.get("id")
    if identifier is not None:
        name = element.get("name") or element.get("addr") or "?"
        frames[identifier] = name
        return name
    return frames.get(element.get("ref"), "?")

OURS = ("STTerminal", "TerminalEmulator", "TerminalScreen", "TerminalParser",
        "CharacterWidth", "TerminalReflow")

total = 0.0
leaves = collections.Counter()
ours = collections.Counter()
symbolicated = 0.0

for row in root.iter("row"):
    weight = None
    stack = None
    for child in row:
        if child.tag == "weight":
            if child.get("id"):
                weights[child.get("id")] = float(child.text or 0)
            weight = weights.get(child.get("id") or child.get("ref"), 0.0)
        elif child.tag == "tagged-backtrace":
            backtrace = child.find("backtrace")
            if backtrace is not None:
                names = [frame_name(f) for f in backtrace.findall("frame")]
                if child.get("id"):
                    backtraces[child.get("id")] = names
                stack = names
            elif child.get("ref"):
                stack = backtraces.get(child.get("ref"))
    if weight is None or not stack:
        continue
    total += weight
    leaves[stack[0]] += weight
    if not stack[0].startswith("0x"):
        symbolicated += weight
    mine = next((f for f in stack if any(marker in f for marker in OURS)), None)
    ours[mine or "(outside the emulator)"] += weight

if total == 0:
    print("no samples: the trace captured nothing")
    raise SystemExit(1)

print(f"CPU sampled: {total / 1e9:.2f} s   symbolicated: {100 * symbolicated / total:.1f}%\n")
print("Attributed to the emulator (deepest frame of ours on the stack):")
for name, weight in ours.most_common(10):
    print(f"  {100 * weight / total:5.1f}%  {name[:100]}")
print("\nLeaf frames, including everything the emulator called into:")
for name, weight in leaves.most_common(10):
    print(f"  {100 * weight / total:5.1f}%  {name[:100]}")
PYTHON
echo
echo "Trace saved to $OUTPUT — open it in Instruments for the full picture."
