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
swift test           # 141 tests in 21 suites passed in 10.0s
swift test -c release --filter TerminalThroughputTests   # the numbers below

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

./scripts/app-integration-e2e.sh   # 61 app tests on iPhone 17 Pro simulator, ** TEST SUCCEEDED **
./scripts/ui-terminal-e2e.sh       # 13 passed, 1 skipped on iPhone, ** TEST SUCCEEDED **
./scripts/ui-terminal-e2e.sh "platform=iOS Simulator,name=iPad Pro 13-inch (M5)"
                                   # 14 passed on iPad, ** TEST SUCCEEDED **

cd Packages/swift-nio-ssh-rsa
swift test           # Executed 347 tests, with 0 failures
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

### Performance — measured, not asserted

Two halves: how fast the emulator consumes bytes, and how fast Core Text draws the
result. Both produce a number on every run and fail when it regresses.

**Emulator throughput** (`TerminalThroughputTests`, Apple silicon Mac):

| Workload | Release | Debug |
| --- | --- | --- |
| Plain text, 120 columns | 9.0 MB/s | 2.9 MB/s |
| Per-character colour changes | 12.7 MB/s | 5.1 MB/s |
| CJK | 8.0 MB/s | 1.8 MB/s |
| Reflow of a full 5 000-line scrollback | 18 ms | 56 ms |

9 MB/s is about 72 Mbit of continuous output — more than an interactive SSH session
delivers and far more than a person can read. Floors are asserted **per configuration**,
because `swift test` runs Debug by default and Debug is genuinely two to three times
slower; a single Release-calibrated threshold would either fail every ordinary run or be
too low to catch anything.

The first measurement read 5.7 MB/s in Release. Two hot paths accounted for most of it:
the parser ran grapheme breaking on every character to decide whether it extended the
previous cluster, and cell-width lookup allocated a scalar array per character. A
conservative fast path — nothing below U+0300 can extend a cluster — and an ASCII
shortcut in the width table took it to 9.0 MB/s.

**Render cost** (`RenderPerformanceTests`, iPhone 17 Pro simulator): a full redraw of both
an 80×24 and a 200×55 grid completes inside a 60 Hz frame budget, asserted rather than
eyeballed. A terminal rarely redraws every frame, so this is a ceiling, but a full redraw
that misses the budget means a burst of output visibly stutters.

Run coalescing is asserted **on the run count**, not on elapsed time. The first version of
that test compared wall-clock between a uniform row and a hundred-colour row; the two
measured within 1% of each other because fixed per-frame cost dominated, so it passed or
failed at random and proved nothing.

### Mouse reporting — 10 unit tests plus a live round-trip

Both the legacy and SGR encodings, modifier folding, wheel buttons, and the gating that
stops drag and motion being reported in modes that did not ask for them. The legacy
encoding's 223-column ceiling returns *nothing* rather than a wrapped coordinate, because
reporting a click somewhere the user did not touch is worse than reporting none.

The live check is in `TUIIntegrationTests`: a remote program enables tracking with
`ESC[?1000h ESC[?1006h`, the emulator picks the mode up, and `cat -v` on the far end shows
`^[[<0;10;5M` — the exact bytes a real terminal would have sent.

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

### The iPad, run for real — the same suite on a regular-width device

The whole UI suite now runs on an iPad Pro 13-inch as well as an iPhone, and is a CI gate
rather than an occasional check. Doing this for the first time found four defects, none of
which the phone run could have seen:

| Defect | Why the phone run could not see it |
| --- | --- |
| A full-screen iPad had **no Control key at all** | The key row was shown when the size class was compact. An iPhone is always compact, so the row was always there; an iPad at full width never had it, and the software keyboard has no Control, Esc, Tab or arrows. There was no way to interrupt a running command. Now a persisted preference, on by default everywhere |
| Most of a **snippet row was not tappable** | `.buttonStyle(.plain)` inside a `List` gives the button a hit area the size of its text. On a narrow phone row the text nearly fills the row, so a tap landed on it; on a wide iPad row the middle of the row is empty space |
| An **open session could not be selected** from the sidebar | Same class of defect in the row above it, and invisible on a phone for the same reason. The detail column stayed on "No session" while the session sat there marked Connected |
| **⌘W was listed and did nothing** | It posted a notification nothing listened for. It also would have been wrong once a second window existed: both commands broadcast, so ⌘N opened the new-connection sheet in every window at once. Commands now act on the focused window |

Two further bugs were found and fixed in the multi-window work itself, before it could be
claimed: a split view *reuses* the detail view when the selection changes, so `onAppear`
never fired again and the newly selected session was never claimed; and tying the claim to
the terminal view's lifetime at all was wrong, because presenting a sheet over the terminal
released it and dismissing the sheet did not always take it back. Ownership now follows the
window's selection, which cannot drift out of sync with what is on screen.

### UI tests — 14 tests, driving the real interface

`scripts/ui-terminal-e2e.sh` starts an `sshd`, seeds a connection through a Debug-only
environment hook, and drives the app the way a person would.

| Test | What a pass proves |
| --- | --- |
| The terminal connects and shows a prompt | Tapping a connection reaches a terminal, typed text arrives at the server, and `UI_TERMINAL_READY` renders back. A screenshot is attached to the result bundle. |
| The accessory key row sends control characters | Latching ctrl then `c` interrupts `sleep 30`, and the shell answers afterwards — the only way to send ^C on a phone |
| The host list survives an accessibility text size | Relaunched at `UICTContentSizeCategoryAccessibilityL`; the list and its rows stay reachable |
| Long-press selects and offers Copy | The gesture is recognised, dragging extends the selection, the bar reports a size, and copying clears it |
| Find searches the scrollback | The find bar opens, searches the buffer and reports a match count |
| Generating a key shows something pastable | Reached through Settings → Keys, the key is created and its `authorized_keys` line is displayed with a copy action, then appears in the list |
| Launch and editor validation (2) | The empty state offers a way forward; Save stays disabled until the form is usable |
| The host list survives every accessibility text size | Launched at AccessibilityM and AccessibilityXXXL, with screenshots attached |
| Settings stay usable with Reduce Transparency and Bold Text | Both actually enabled; every section remains reachable |
| Every control on the host list is labelled | An unlabelled button reads out as "button" and is unusable without sight |
| A snippet is typed into the terminal but not run | Created through the editor, tapped, and asserted against a real shell: the command text is on the line and its output is **not**, for three seconds. Pressing Return then produces the output. The absence is the assertion — a snippet that ran on tap would pass a test that only looked for the text |
| History is empty until turned on, then records what was typed | A command run before opting in leaves history off and empty; the setting is turned on through Settings; a second command is then recorded as exactly the typed string — no prompt, no output — and the earlier command does not reappear |
| A session opens in a second window (iPad) | The context menu's "Open in New Window" is used, and the app's connected-scene count is asserted to **increase**. It is read through a Debug-only probe because the result is otherwise unverifiable: a screenshot looks the same whether a scene was created or the action did nothing, and XCUITest drives one scene at a time. Skipped on iPhone, which does not offer multiple windows |

Running these rather than reading the code found a layout defect immediately: at
`AccessibilityXXXL` the server icon sat across the wrapped connection name, and the
hostname — the thing that tells two connections apart — was truncated. Rows now stack
vertically and let the subtitle wrap at accessibility sizes.

Writing these found four defects that no unit test could have:

* **On iPhone, tapping a connection opened a session but never showed it.** The list
  started the connection and the split-view detail column would have displayed it, but a
  navigation stack has to be pushed explicitly. On a phone the terminal was unreachable.
* **The on-screen Control key did nothing.** The latch was held in the SwiftUI button
  that drew it, while typed characters arrive through `insertText` on the input view — so
  it highlighted correctly and modified nothing. Tapping ctrl then `c` typed a literal
  `c`. On a phone that means no way to interrupt a running command at all.
* **Snippets and pastes were missing from history.** The recorder started life in the
  keyboard's input callback, which is the one path a snippet or a paste does not take. A
  command inserted either way and then run was silently absent. The accounting moved into
  the session, so there is one place that sees every submitted command whatever sent it.
* **UI runs were not repeatable.** Preferences live in `UserDefaults` and outlive the app,
  so a run that switched history on decided the outcome of the next run — the history test
  passed once and then failed, against unchanged code. The Debug-only seeding now resets
  preferences and snippets alongside the hosts and the Keychain.

A defect the *unit* tests caught, worth recording because the naive implementation is the
obvious one: reconstructing the typed command by appending printable characters put the
bytes of the arrow keys into the command. `ls`, Up, Return recorded `ls[A`. Worse, Up
recalls a different command from the shell's own history, so after any line editing the
line is no longer the one we watched being typed. The parser now consumes escape
sequences whole, and a line the remote editor may have changed is dropped rather than
guessed at — a wrong command in history is worse than no command.

### Manual inspection

The app was installed and launched on the iPhone 17 Pro and iPad Pro 13-inch (M5)
simulators and screenshotted. That found a real defect: on iPad the split view opened
with the sidebar collapsed, so a fresh install showed "No session" and no visible way to
add one. Fixed by starting at `.all` visibility.

### Automatic reconnection — 6 integration tests against a real server

Run on the iPhone 17 Pro simulator as part of `scripts/app-integration-e2e.sh`. The
session's traffic runs through a relay whose sockets can be closed underneath it, so the
drop is a real one: a real `sshd` on the far side, a real handshake through the relay, and
sockets that go away with no SSH disconnect message — what a network vanishing looks like.

Faking the drop would have proved the state machine and nothing else: not whether a socket
dying mid-session is noticed, not whether the SSH layer surfaces it, and not whether what
comes back is a shell that works.

| Test | What a pass proves |
| --- | --- |
| A dropped connection comes back on its own | The drop is noticed, the retry runs, the session reconnects, the banner clears — and `printf` in the recovered shell produces output, so it is a working shell rather than a connected socket |
| The scrollback survives | Output printed before the drop is still readable afterwards. This is the assertion that stops a future "tidy up on reconnect" change |
| It keeps trying while the server is down, and stops when told | New connections are refused as well as severed; at least two attempts happen; cancelling stops it and nothing carries on afterwards |
| Retry now skips the wait | Without it the session would sit out the remaining backoff after the user can see the server is back |
| The setting is honoured | With automatic reconnection off, a drop leaves the session waiting for the user |
| `exit` is not a drop | Typing `exit` disconnects cleanly and starts nothing. The shell's exit status arriving before the channel closes is what distinguishes the two; without it, ending a session deliberately would reopen it |
| Coming back onto a network retries at once | The session waits rather than spending attempts while offline — running out of retries just as the user leaves a tunnel is the worst possible moment to give up — and reconnects immediately when the path returns |

Two error categories were corrected because of this work, and both were real bugs rather
than tidying. "The server closed the connection before the SSH session was established" and
"the handshake did not complete in time" were classified as `sshTransport`, alongside key
exchange and MAC failures. Neither is a transport failure in that sense — nothing SSH
promises was broken, the connection went away or never answered — and they are the two most
common ways a mobile connection dies. With the old classification, automatic reconnection
would have retried almost nothing. A test now pins the category rather than the message.

**Known limitation, measured:** a server that accepts a connection and immediately closes
it takes the full 30-second handshake timeout to fail, because the close can arrive before
the handshake monitor is in the pipeline. Failing faster was implemented and then reverted:
every variant either failed the promise before its callbacks were attached or scheduled
work on an event loop that was already shutting down, and crashed the package suite. The
timeout bounds it correctly and the retry then continues, so the cost is a slow first
retry against a dead load balancer, not a hang. `retriesWhileUnreachableAndStopsOnRequest`
takes 33s for this reason.

### Windows — 11 app tests

| Area | What is asserted |
| --- | --- |
| Selection is per window | Two windows hold different selections and are distinguishable from each other |
| Opening a session decides nothing about display | The manager owns the connection; which window shows it is the window's business |
| Claiming transfers | A second window taking a session takes it from the first |
| A departing window cannot revoke a live claim | SwiftUI can run the arriving window's appearance before the leaving one's disappearance; an unconditional release would leave the visible window owning nothing and reporting no size |
| A new window takes an unclaimed session | Opening a second window must not empty the first; when everything is on screen already it opens empty |
| Closing forgets the claim | Both for one session and for all of them |
| The claim follows the selection | The case a split view creates by reusing one view for whichever session is selected |

### Snippets and command history — 24 app tests

Run on the iPhone 17 Pro simulator as part of `scripts/app-integration-e2e.sh`.

| Area | What is asserted |
| --- | --- |
| The history setting is honoured at the source | `record` refuses while the setting is off, and no file is written — off means nothing is kept, not merely nothing shown. A store opened while the setting is off does not read an existing file back |
| Clearing | `clearHistory` removes the file, not just the array; a file left behind would return if the setting were re-enabled |
| Bounds | 600 recorded commands leave exactly 500, oldest dropped — opting in does not create an unbounded record of everything, ever |
| Consecutive repeats | Collapsed, so a repeated command does not push out older ones |
| Search | Filters by text, by host, and by both |
| The starter set | Idempotent, read-only (no `rm`, `dd`, `mkfs`, `kill`, restarts), and nothing in it runs on tap |
| Typed-command reconstruction (12) | Character-at-a-time, whole-line chunks, multi-line paste, backspace, `^C`/`^D`/`^Z`/`^U`, CSI sequences, OSC-with-BEL, DCS-with-ST, empty lines, and destructive `take` |
| Line editing | `ls`, Up, Return records **nothing**; so do a cursor move followed by typing, and a tab completion |
| Every input path | Typed, pasted and snippet-inserted commands all reach the same recorder, verified through the session's stream |

### Ciphers — 8 tests

`CipherInteropTests` and `AESCTRCounterTests`. `swift-nio-ssh` ships only AES-GCM;
hardening guides routinely narrow a server's `Ciphers` to the CTR family, which would
otherwise make such a server unreachable however modern it is.

Asserting from the client that a connection "used AES-CTR" would be circular — the client
reporting on itself. Instead the server is configured to offer **only** that scheme, so
the connection is the evidence: it negotiates CTR or it does not happen.

| Test | What a pass proves |
| --- | --- |
| A CTR-with-ETM-only server is reachable | No AES-GCM is on offer at all |
| A long session over CTR stays in sync | 400 KB in one burst. CTR is a stream cipher: a counter advanced wrongly gives one good packet and then garbage, which a single command would not notice |
| AES-GCM still preferred when both are offered | Adding a scheme did not disturb the existing preference |
| Counter arithmetic (5 tests) | Blocks not bytes, carry across byte boundaries, a large increment, and wrapping at the top rather than trapping |

`hmac-sha2-256` without `-etm` is deliberately not implemented: it would let a server
negotiate the construction that authenticates plaintext and encrypts the length, so a
receiver has to decrypt before it can authenticate.

### RSA — 9 tests, proved against OpenSSH and adversarially

`RSAInteropTests`. The change separates a key's blob identifier (`ssh-rsa`) from its
negotiated algorithm name (`rsa-sha2-256` / `rsa-sha2-512`), which RFC 8332 makes
different for RSA alone. Every test exists because that separation is easy to get subtly
wrong.

| Test | What a pass proves |
| --- | --- |
| An RSA user key authenticates against a real `sshd` | The whole chain: parse, negotiate, sign with the declared algorithm, and be accepted |
| A server offering **only** an RSA host key can be reached | No Ed25519 or ECDSA host key exists on that server, so the connection can only have gone through RSA host-key verification — and the remembered key is the server's real one |
| An RSA key works over the Cloudflare carrier | The carrier is only a byte stream, but that is how transport-specific bugs survive |
| `ssh-keygen` and this parser agree on the fingerprint | The `e`-before-`n` ordering is exactly the kind of thing that yields a plausible key that is not the user's |
| A signature claiming the wrong RSA algorithm does not verify | If the algorithm came from the key rather than the signature, this would pass |
| An RSA key rejects a non-RSA algorithm name, including `ssh-rsa` | `ssh-rsa` names SHA-1 and is refused even though it is the blob's own name |
| An Ed25519 key rejects an RSA algorithm name | The relaxed check must not have become no check |
| A tampered signature does not verify | |
| A signature over different bytes does not verify | |

### Key generation — 8 cases, verified against OpenSSH itself

`SSHKeyGenerationTests`. The strongest check here is interoperability, because a key
format only this app understands would make the app a place keys go to be trapped.

| Test | What a pass proves |
| --- | --- |
| Round-trips through this app's parser (Ed25519, P-256) | The container this app writes is one it can read back; also checked inside the generator itself, so a key that fails to re-parse is never saved |
| `ssh-keygen` reads it and agrees on the fingerprint | `ssh-keygen -y` derives the public key and `-l` reports the same SHA-256 the app shows the user — real interop, not self-consistency |
| Authenticates against a real `sshd` (both algorithms) | The server's `authorized_keys` contains *only* the generated key, so a pass means that key worked rather than another credential being picked up |
| Two keys differ | No accidental reuse |
| The public line is `authorized_keys`-shaped | Three fields, valid base64, the comment preserved |

### Vendored swift-nio-ssh — 347 upstream tests

`Packages/swift-nio-ssh-rsa` is Apple's library at tag `0.15.0`, vendored so RSA can be
added. It was committed **unmodified first** and upstream's own suite was run against the copy:
346 tests, 0 failures. That established the vendor was faithful before any change of ours
landed on it.

With the RSA patch applied the suite is 347 tests, 0 failures. One upstream test used
`ssh-rsa` as its example of an unrecognised algorithm; since that is now a type this
library understands, the example moved to `ssh-dss` — which OpenSSH removed entirely in
10.0 — and a new test was added so the truncated-key case it also covered is not lost. The
behaviour under test is unchanged.

`patches/niossh-rsa.patch` was verified to apply cleanly to a freshly cloned pristine
upstream at tag `0.15.0`, so a future re-sync is mechanical rather than a hand-merge.

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
| **Double-tap to select a line** | Implemented and unit-tested at the model level; not driven by a UI test. Long-press-and-drag selection and find both are. |
| **Mouse reporting** | Modes are parsed and surfaced; nothing sends mouse events yet. |
| **VoiceOver, heard** | Every control is labelled and the terminal exposes its rendered text, both asserted by tests. Nobody has listened to an actual VoiceOver session, which is a different thing. |
| **Increase Contrast selecting the high-contrast theme** | Still verified by reading the code. Screenshotting it needs a live terminal at that setting, which the current harness does not drive. |
| **Pointer and hover on iPad** | Hover reporting is implemented; it has not been driven with a trackpad. |
| **Keychain behaviour** | `KeychainSecureStore` is written but untested; Keychain semantics differ enough in a macOS unit-test process that a passing test there would prove little. Needs device tests. |
| **Instruments profiling** | Not run. `XCTest`'s measurement was used instead because it produces a number on every run, in CI as well as on a desk, and fails on a regression. An Instruments trace remains the better tool for finding *why* something is slow, and is worth doing before release. |

## Observed environment issue

`trycloudflare.com` quick tunnels were attempted on 2026-09-04 as a way to reach a live
edge without an account. Two tunnels registered successfully (`cloudflared` 2026.6.1
connected to `sjc07` over QUIC), but every request to the assigned hostname returned an
empty-bodied HTTP 404 from the Cloudflare edge and **no request ever reached the
tunnel**. Both an `ssh://` and an `http://` origin behaved identically, ruling out the
origin scheme. This closes off the no-account route to live verification; it is recorded
in `PROJECT_STATUS.md` as B-3.
