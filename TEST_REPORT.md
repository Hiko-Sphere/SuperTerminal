# Test report

Every claim here is backed by a command that was actually run, on a stated machine, at a
stated time. Where something has **not** been verified, it says so rather than being
left out.

## Environment

| | |
| --- | --- |
| Machine | Apple silicon Mac, macOS 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| Test host | macOS, `swift test` — the package builds for iOS 17+ but its logic is exercised natively for speed |
| OpenSSH | 10.2p1, LibreSSL 3.3.6 (the `sshd` the integration tests start) |
| Vim | 9.1 |
| Run date | 2026-09-05 |

## Commands run

```bash
cd Packages/SuperTerminalKit
swift build          # 0 errors, 0 warnings from project code
swift test           # 73 tests in 11 suites passed in 7.6s

cd ..
xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# ** BUILD SUCCEEDED **, 0 warnings from App/

xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
  -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# ** BUILD SUCCEEDED **

xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
# ** BUILD SUCCEEDED ** — arm64 device build compiles

./scripts/app-integration-e2e.sh   # 14 tests on iPhone 17 Pro simulator, ** TEST SUCCEEDED **
./scripts/ui-terminal-e2e.sh       # 5 UI tests driving the real interface, ** TEST SUCCEEDED **
```

Warning counts were measured, not assumed:
`swift build 2>&1 | grep -cE "Sources/.*warning:"` → **0**, and
`xcodebuild ... build 2>&1 | grep -cE "warning:.*repo/superterminal/App"` → **0**.

## What the suite covers

### SSH against a real OpenSSH server — 8 tests

`Tests/STSSHTests/SSHIntegrationTests.swift` starts an unprivileged `/usr/sbin/sshd` on
an ephemeral port with generated host keys and its own `authorized_keys`, then connects
to it. Nothing about the SSH protocol or its cryptography is simulated.

| Test | What a pass proves |
| --- | --- |
| Ed25519 key authentication runs a command | Full handshake, key auth, exec channel; the remote host really printed `CF_E2E_OK` |
| ECDSA P-256 key authentication | The second supported key algorithm interoperates |
| Passphrase-protected key unlocks and authenticates | The vendored `bcrypt_pbkdf` is bit-exact — a wrong passphrase is rejected, which only happens if the derived key is right |
| Interactive PTY reports the terminal size | A PTY was genuinely allocated: `stty size` on the remote returned the geometry requested |
| Resize propagates | `window-change` reached the remote and `stty size` changed |
| A wrong key is refused as an *authentication* error, in under 15s | Correct classification, and fail-fast rather than waiting out the server's two-minute `LoginGraceTime` |
| A changed host key aborts | The MITM case is a hard stop, and the stored key is not silently replaced |
| Trust on first use records the server's real key | The recorded fingerprint matches the server's actual host key |

### Cloudflare carrier — 8 tests

`Tests/STCloudflareTests/CarrierIntegrationTests.swift` runs against
`WebSocketCarrierTestServer`, a local NIO server that performs the same HTTP/1.1
WebSocket upgrade as Cloudflare's edge and bridges binary frames to a real `sshd`.

| Test | What a pass proves |
| --- | --- |
| A full SSH session runs over the carrier | SSH works end to end over WebSocket framing — the same `SSHConnection` code as the TCP path |
| Interactive PTY survives a 256 KiB burst | Fragmented, multi-frame data is reassembled in order without loss |
| `Cf-Access-Token` reaches the edge | The server *requires* the exact token, so the header genuinely arrived |
| A token the edge rejects is an Access error | Correct classification of a refused upgrade |
| Service-token headers are sent and accepted | The non-interactive credential path works |
| `Cf-Access-Jump-Destination` is sent | Bastion mode reaches the wire |
| Each edge failure is classified (4 cases) | Access-login redirect, 403, 502 and 530 each map to their own category with an actionable recovery |
| A plaintext carrier refuses non-loopback hosts | The test-only transport mode cannot weaken a real connection |

### Terminal emulator — 43 tests

Parser, width and screen behaviour (`Tests/STTerminalTests/`), including malformed input:
truncated escape sequences, `CAN` mid-sequence, over-long OSC strings, integer-overflow
parameters, and invalid UTF-8. Width tests cover CJK, halfwidth kana, combining marks,
ZWJ emoji sequences, regional-indicator flags and variation selectors.

### Real TUI programs over SSH — 6 tests

`Tests/STTerminalTests/TUIIntegrationTests.swift` runs actual programs over a real SSH
PTY and feeds their output through the emulator. This is the part that cannot be faked:
`vim` and `less` emit sequence combinations, timing and terminal queries no hand-written
fixture anticipates.

| Test | What a pass proves |
| --- | --- |
| `vim` draws, holds typed text, and restores the shell on exit | Alternate screen, full-screen redraw, and correct restoration of the primary buffer |
| `vim` renders CJK, emoji and accented text | Wide characters and combining marks survive a real PTY round trip |
| `less` uses the alternate screen | 500 lines paged without polluting the user's scrollback (`< 100` scrollback lines retained) |
| A mid-session resize is honoured by a running program | After `resize(to:)`, `vim` itself reports `columns=100` |
| A 20 000-line burst is bounded | Scrollback stayed at its 2 000-line cap |
| A remote program's window title reaches the app | OSC 0 parsed and surfaced as an event |

The tests replace the login shell with `env -i … /bin/sh -i` before running anything.
The account's real shell is a themed zsh that repaints its prompt and rewrites the window
title on a timer, which would make "is the shell ready?" and "did the program set the
title?" unanswerable. This is a test-harness decision, not a product limitation.

### The app itself — 5 tests, on an iPhone 17 Pro simulator

`AppTests/AppSSHIntegrationTests.swift` runs **inside the app** against a real `sshd`
started on the host by `scripts/app-integration-e2e.sh`. The package tests prove the SSH
and terminal layers work when driven directly; these prove they work when driven the way
the app drives them — through the real Keychain, through `TerminalSession`'s state
machine, with the emulator attached.

| Test | What a pass proves |
| --- | --- |
| The app connects, allocates a PTY, and renders real remote output | End to end through app code: the emulator showed `APP_STACK_OK`, and the remote reported `28 90` — the geometry the app asked for, so the PTY and the resize both reached the server |
| A host key the app has not seen is refused until approved | The prompt machinery gates the connection, the fingerprint offered matches the server's real one, and refusing fails the session with `.hostKey` |
| Host model (3 tests) | A Cloudflare host is recorded against port 443 rather than the origin's SSH port; validation reports every problem |

### UI tests — 5 tests, driving the real interface

`scripts/ui-terminal-e2e.sh` starts an `sshd`, seeds a connection through a Debug-only
environment hook, and drives the app the way a person would.

| Test | What a pass proves |
| --- | --- |
| The terminal connects and shows a prompt | Tapping a connection reaches a terminal, typed text arrives at the server, and `UI_TERMINAL_READY` renders back. A screenshot is attached to the result bundle. |
| The accessory key row sends control characters | Latching ctrl then `c` interrupts `sleep 30`, and the shell answers afterwards — the only way to send ^C on a phone |
| The host list survives an accessibility text size | Relaunched at `UICTContentSizeCategoryAccessibilityL`; the list and its rows stay reachable |
| Launch and editor validation (2) | The empty state offers a way forward; Save stays disabled until the form is usable |

Writing these found two defects that no unit test could have:

* **On iPhone, tapping a connection opened a session but never showed it.** The list
  started the connection and the split-view detail column would have displayed it, but a
  navigation stack has to be pushed explicitly. On a phone the terminal was unreachable.
* **The on-screen Control key did nothing.** The latch was held in the SwiftUI button
  that drew it, while typed characters arrive through `insertText` on the input view — so
  it highlighted correctly and modified nothing. Tapping ctrl then `c` typed a literal
  `c`. On a phone that means no way to interrupt a running command at all.

### Manual inspection

The app was installed and launched on the iPhone 17 Pro and iPad Pro 13-inch (M5)
simulators and screenshotted. That found a real defect: on iPad the split view opened
with the sidebar collapsed, so a fresh install showed "No session" and no visible way to
add one. Fixed by starting at `.all` visibility.

## Not verified

Stated plainly, because a test report that omits these would be misleading:

| Capability | Why not, and what it would take |
| --- | --- |
| **Cloudflare Access authentication (live)** | No local harness can authenticate a real identity. Needs a Cloudflare account with a tunnel, an Access application and a test identity. The local carrier server deliberately does **not** pretend to be Access. |
| **Access token expiry and re-authentication** | Same dependency. |
| **On-device runs** | Needs a development team. The unsigned `generic/platform=iOS` Release build succeeds, so the code is device-ready; a paired iPhone 16 Pro and two Apple Development identities are already on the machine. |
| **Archive and TestFlight** | `xcodebuild archive` fails with *"Signing for SuperTerminal requires a development team"*. Recorded as `PROJECT_STATUS.md` B-4. |
| **External keyboard and pointer** | The key mapping is implemented and unit-testable, but has not been exercised against real hardware. |
| **Accessibility** | VoiceOver, Dynamic Type and high-contrast passes have not been run. |
| **Selection gestures** | The selection model, copy semantics and search have 11 unit tests, but the gestures that drive them — long-press, drag to extend, double-tap — have not been exercised by a test or by hand. |
| **Mouse reporting** | Modes are parsed and surfaced; nothing sends mouse events yet. |
| **VoiceOver, high contrast, Reduce Transparency** | Dynamic Type is verified on the host list. The terminal exposes its rendered text as an accessibility value, but no VoiceOver session has been run. |
| **Keychain behaviour** | `KeychainSecureStore` is written but untested; Keychain semantics differ enough in a macOS unit-test process that a passing test there would prove little. Needs device tests. |
| **RSA keys** | Unsupported — see `DECISIONS.md` D-002. Not a test gap; a capability gap. |
| **Instruments profiling** | Not run. Rendering does not exist yet, so there is nothing meaningful to profile. |

## Observed environment issue

`trycloudflare.com` quick tunnels were attempted on 2026-09-04 as a way to reach a live
edge without an account. Two tunnels registered successfully (`cloudflared` 2026.6.1
connected to `sjc07` over QUIC), but every request to the assigned hostname returned an
empty-bodied HTTP 404 from the Cloudflare edge and **no request ever reached the
tunnel**. Both an `ssh://` and an `http://` origin behaved identically, ruling out the
origin scheme. This closes off the no-account route to live verification; it is recorded
in `PROJECT_STATUS.md` as B-3.
