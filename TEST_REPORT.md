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
cd Packages/ApexTerminalKit
swift build          # 0 errors, 0 warnings from project code
swift test --no-parallel   # 275 tests in 40 suites passed (the VNC suites run against LibVNCServer
                           # from Homebrew). --no-parallel is required: the sshd-backed suites poll
                           # while blocking the cooperative pool, and parallel runs starve it.
swift test -c release --filter TerminalThroughputTests   # the numbers below

cd ..
xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# ** BUILD SUCCEEDED **, 0 warnings from App/

xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# ** BUILD SUCCEEDED **

xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
# ** BUILD SUCCEEDED ** — arm64 device build compiles

xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ApexTerminalTests test
# the sshd-backed cases skip without the harness; run the script below for the full number

./scripts/app-integration-e2e.sh   # 258 tests in 48 suites on iPhone 17 Pro simulator, ** TEST SUCCEEDED **
./scripts/profile-emulator.sh      # real Instruments trace of the emulator hot path
./scripts/localization-audit.sh    # every user-visible string translated (zh-Hans, zh-Hant): green
./scripts/ui-terminal-e2e.sh       # 48 passed, 2 failed on iPhone — both ZZSearchProbeUITests, another
                                   # session's uncommitted work. Every hardware-keyboard test passes since
                                   # D-050. See docs/DEVELOPMENT.md for what the simulator does to key events.
./scripts/ui-terminal-e2e.sh "platform=iOS Simulator,name=iPad Pro 13-inch (M5)"
                                   # 39 passed on iPad, none skipped, ** TEST SUCCEEDED **

cd Packages/swift-nio-ssh-rsa
swift test           # Executed 349 tests, with 0 failures (347 upstream + 2 for key extension)
```

The numbers above were measured on 2026-09-08, after D-049. The per-slice figures further
down were measured on the dates their sections name; `docs/RELEASE_EVIDENCE.md` carries the
current per-commit record and is the file to trust when the two disagree.

Warning counts were measured, not assumed:
`swift build 2>&1 | grep -cE "Sources/.*warning:"` → **0**, and
`xcodebuild ... build 2>&1 | grep -cE "warning:.*repo/apexterminal/App"` → **0**.
The test targets are held to the same bar, on a clean build so incremental compilation
cannot hide a file that was not recompiled:
`xcodebuild ... clean build-for-testing 2>&1 | grep -c "warning:.*repo/apexterminal/App"` → **0**
across `App/`, `AppTests/` and `AppUITests/`.

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

### iCloud sync — 27 tests, offline by necessity

`SyncEngineTests` drive the engine through an in-memory transport: pull/merge/push,
last-writer-wins for ordinary records, a remote host key that differs from a trusted one
is **held** and never applied, applied records are not echoed back, and an edit made
within the same second as a push is still re-sent (the first version compared against the
wall clock and was caught on the third sync). `AppSyncStoreTests` prove the adapter over
the real `HostStore`, `SnippetStore` and `InMemoryKnownHostsStore`: stamping rules,
tombstones on delete and their removal on resurrection, IPv6-safe known-host identities,
that the payload used for conflict detection is the key alone, that a host key removed by
hand becomes a tombstone rather than silently returning from the other device, and that a
host trusted again after deletion wins over its own stale tombstone. One of these failed in
one simulator clone and passed in the other until the test encoder was made canonical —
recorded in D-015. `CloudKitMappingTests` cover the record ↔ `CKRecord` mapping.
`KnownHostsRemoveAllTests` prove "Delete all data" forgets host keys on disk.

**Not verified:** CloudKit and iCloud Keychain. The simulator build has no entitlements
(B-4). Nothing in the app or its documents claims that live sync has been exercised.

### Legal documents — 14 unit tests and 2 UI tests

`LegalDocumentBundleTests` open every one of the nine bundled documents (three texts ×
three languages) and the third-party notices from the built app, and require each to be
comment-free and to have at least ten headings. `MarkdownDocumentTests` cover the parser's
headings, lists, tables and comment stripping. `ConsentUITests` launch with the consent
flag, read the User Notice from the gate, accept, relaunch without a reset and confirm the
gate does not return; the second test opens the licences from Settings.

### Cloudflare Access service tokens — 3 unit tests and 1 UI test

`ServiceTokenTests` prove the model migration (a host record without the new field decodes
with no authentication choice), the Codable round-trip, and — on the real Keychain in the
app host — that a service token is stored, read back with its secret intact, redacted in any
description, and deleted. `ServiceTokenUITests` drives the connection editor: choosing
"Service token" without entering one keeps Save disabled, entering both fields enables it,
and reopening the saved connection shows the token as stored without displaying it — and
that iOS's "Save Password?" sheet never appears: the first run of this test found AutoFill
offering to keep the secret in iCloud Keychain passwords, which every secure field in the
app now opts out of. The
carrier already sent the `Cf-Access-Client-Id` / `Cf-Access-Client-Secret` headers and is
covered by `CarrierIntegrationTests`; the live Access run (`scripts/live-e2e.sh`) uses the
same path and remains blocked on B-2.

### Hardware keyboard and pointer — 19 unit tests and 7 UI tests

`HardwareKeyMapTests` (8) pin the xterm mapping rule by rule: arrows in both cursor modes,
the `CSI 1;m` parameter for Shift/Option/Control on arrows, Home/End and function keys,
`CSI n;m~` for Insert/Delete/Page keys, control bytes, Option as Meta, Control-Backspace,
Shift-Tab, and that Command never produces bytes for the host. `PointerConfigurationTests`
(6) instantiate the real terminal view and assert the recognisers and interactions that
make a scroll wheel, a click-drag, a secondary click, a middle click, the edit menu and the
beam pointer work — configuration, because XCUITest on iOS cannot synthesise pointer
gestures — and that both click recognisers take only indirect-pointer touches. That last
assertion exists because of a measured failure: with a button mask as the only condition,
a synthesised direct tap satisfied the middle-click recogniser, and every live-terminal UI
test that tapped the terminal then pasted the previous test's copied prompt into the
shell, which reported `command not found: ─░▒▓`. `AppShortcutTests` (5) hold the shortcut
table to one declaration per key, agreement between its SwiftUI and UIKit spellings, a
property-list round trip, the whole table on the terminal view, and
disabled-without-a-scene.

The same runs exposed two leaks in the test infrastructure, both fixed: the UI harness
replaced itself with `xcodebuild` via `exec`, so its cleanup trap never ran and every run
left its `sshd` listening (over a hundred were found on one machine); and the package's
OpenSSH test server stopped only when its test process exited normally, so a run killed
from outside left its servers behind. The harness now runs `xcodebuild` as a child and
forwards a kill to it, and each package server has a watchdog shell that kills it when
the test process is gone — verified by killing a running package test and finding no
server and no watchdog afterwards.

`HardwareKeyboardUITests` type real keys. Five pass outright: ⌘K opens the palette, ⌘N
opens the connection editor, ⌘, opens Settings — each from a freshly launched host list
with nothing focused — ⌘K opens the palette while the host list's search field is
focused (measured after the redesign: delivered on the first key in 8 of 8 runs on iPhone
and 4 of 4 on iPad; one full-suite run saw the simulator drop both the key and its retry,
the probe showing the app received nothing, which is the instrument), and ↓ moves the
palette's highlight to the second row. The live-terminal palette
test also polices the shortcuts' accessibility: its query for the Session menu's
"Command Palette…" item matched two elements while the shortcut buttons were concealed by
size, opacity, `accessibilityHidden` or an ignored container — a dump of the tree showed
eighteen zero-size labelled buttons — and matches one now that they are `hidden()`, with
the keyboard suite proving hidden buttons still fire. The first hardware key after launch is sometimes dropped by the
simulator before the app sees it; the tests read a debug probe of shortcuts performed
(`ST_UITEST_KEY_PROBE`), retry once only when the probe did not move, and attach a note.
Two are strict expected failures that name the instrument: Escape closing the palette and
Return running the highlighted item — sent while a text field is first responder they
measured as undelivered, while the field's arrow key commands and ⌘ keys arrive. They will
flip to failures the day the simulator delivers them; the manual checks are in
`docs/RELEASE.md`. (⌘K with the search field focused was a third while the shortcuts lived
on a hidden first-responder view; it passes now, see the next section.)

### iPadOS 26 focus-engine abort — measured, and the cause removed

On the iPad simulator (iOS 26.5) with a hardware keyboard connected, the accessibility
settings test aborted the app inside UIKit's focus engine (`parentEnvironment != nil` in
`_UIFocusContainerGuideFallbackItemsContainer`; Apple r.154431813, forum thread 805681).
Reproduced by repeating that one test through the harness (`ST_ONLY_TESTING`), counting
crash reports per run, against the previous commit in a detached worktree (`ST_ROOT`) and
as an interleaved A/B of the same build with the hidden first-responder view present and
left out by a debug launch switch. Result: five aborts in eighteen valid runs with the
view, none in seventeen without it (nine on the previous commit, eight with the switch).
The persisted log placed the view's single first-responder acquisition two seconds after
launch and nothing further before each abort. The view was removed and the shortcuts
became SwiftUI shortcut buttons in the root view (D-018); the redesign was then verified
with the keyboard UI suite on both devices and sixteen further runs of the same test.

### Server platform — 5 unit tests and 2 UI tests

`HostPlatformTests` read platforms out of what real systems print: `uname -s` for macOS,
Linux and the BSDs, MSYS and Cygwin kernel names as Windows, `cmd /c ver` for Windows
proper, and both Windows shells' "not recognized" complaints, which must not be read as a
kernel name; nothing usable yields nil rather than a guess. A record written before the two
fields existed decodes; the hand-set value outranks the detected one; recording the same
detection twice writes the store once and an unknown host is ignored.

`TerminalUITests.testConnectingDetectsTheServerPlatform` connects to the harness's real
OpenSSH on this Mac and watches the connection row come to say macOS — detection over a
channel of its own after the shell is up. `HostEditorUITests.testServerPlatformCanBeSetByHand`
opens the seeded connection's editor, sets Windows in the Advanced section, saves, and
sees the row change. Linux and Windows detection are exercised by the parser against
their real output; connecting to a machine of each kind is a hardware check in
`docs/RELEASE.md`.

### Blank means "ask", and a pasted address is taken apart (D-024)

`HostAddressTests` (STCore) take the hostname field's input apart the way people paste it:
bare hosts with and without a port, URLs with a user name (never a password, path or
query), IPv6 literals bracketed and bare — including a zone identifier — and the shapes
that are not an address at all, `a:b:c` among them, which a character-set test cannot tell
from an address but the system can. `SSHCredentialChainTests` drive the chain call by call
as the SSH handler does: with nothing stored it offers `none` first so the server says what
it takes, then the typed password once and only if the server listed `password`; a key-only
server is never asked; a cancelled prompt fails the attempt with a message that says so;
stored credentials behave as before. `HostModelTests` pin that a Cloudflare connection
built without a port takes the edge's 443 rather than SSH's 22, that a record written
before the field existed is rewritten on load, and that a connection with no user name and
no credential is valid. `BlankFieldsUITests` edit the seeded connection to `host:port` with
the port field blank and no user name, save, see the row show `host:port` without a user,
open it, answer the user-name prompt and reach the shell over the harness's real OpenSSH
server. Password authentication against a real server remains a live check: the harness's
sshd takes keys only.

### The terminal keeps the keyboard and takes a wheel (D-025)

`PointerScrollTests` pin the scrolling arithmetic that a wheel needs — notches smaller than
a row accumulating across gestures, direction, the reset, a zero cell height — and that the
drag interaction is enabled only while there is a selection, which is what lets a pointer
select at all. `HardwareKeyboardStateUITests` type into the terminal without ever waiting
for a software keyboard, which is the state a hardware keyboard puts the app in, and assert
the shell received it after the find bar, the command palette and a whole sheet have each
taken focus; a second test opens a second session and asserts the typing lands in the
session on screen rather than the first. A real Magic Keyboard, a real mouse and the
iPadOS focus engine stay on the release checklist: XCUITest reproduces none of them.

### Remote screens are their own connections (D-027)

`ScreenConnectionTests` cover the record, its validation and its endpoint; the route; the
derived id that makes two devices migrating the same connection converge on one screen
(version and variant bits checked, so it is derived rather than random); the mapping out of
every old shape — through SSH with and without a target, and direct, which used to dial the
SSH connection's own hostname; a migration that moves the password to the screen's Keychain
account, empties the connection and changes nothing when run again; and the store's add,
update, delete-with-tombstone, insert-if-absent and reload from disk. `VNCUITests` open the
screen from its own row — checking the row names the connection it travels through — and
drive it against LibVNCServer behind the harness's OpenSSH server; a second test opens the
screen's own editor and asserts the SSH editor has no screen sharing left in it.

### A screen with its own tunnel, and a keyboard it is not asked for (D-029)

`ScreenConnectionTests` cover the third route: that `cloudflare` is neither direct nor
SSH, carries its Access authentication, defaults to the edge's 443 while the other routes
still default to 5900, and round-trips so a screen saved on one device opens on another.
`VNCTests` pin that the screen becomes first responder with the on-screen keyboard down —
held down by an input view of no height rather than by resigning, which would resign the
keys too — and that it comes up when asked; and that three ten-point wheel notches
arriving as three separate gestures add up to one step in the right direction, which is
the defect D-025 fixed in the terminal and this fixes in the other view. A live tunnelled
screen needs the owner's Cloudflare environment (B-2); a real external keyboard and mouse
are device checks.

### A frame is copied, not walked pixel by pixel (D-030)

`VNCThroughputTests` decode a full 1080p frame in each encoding and hold each to a floor
slow enough not to be flaky and fast enough that failing it means a visibly stuttering
screen: measured 4131 frames a second for `Raw` (was 100), 800 for a worst-case ZRLE frame
half made of raw tiles (was 568), 4107 for Hextile, and 6819 for turning the framebuffer
into the image the display takes. The floors are per-encoding, because a decoder that is a
`memcpy` per row loses almost nothing to a Debug build and one that touches every pixel
loses a factor of forty; one blanket divisor would either fail on the fast encodings or
assert nothing about the slow ones. Each test also checks the picture it decoded, so a
decoder cannot pass by being fast and wrong.

`RFBReceiveTests` measure the receive path rather than the decoder: an update fed in 16 KB
segments — a 1080p frame arrives in hundreds of them — against the same update delivered
whole, and the ratio is under 1.2, so nothing done per read costs the whole buffer. This
test exists because that path was *suspected* of being quadratic and measurement said it
was not; it stays as the guard that would catch it becoming true. A second test proves an
incomplete rectangle is not half-drawn and is drawn once, as soon as its last byte lands.

### A screen may sign in to an account (D-031)

`VNCAuthenticationTests` verify the two security types that carry a user name. The
Diffie-Hellman arithmetic is checked against exchanges computed by Python's
arbitrary-precision integers at 512 and 1024 bits — an implementation that owes nothing to
this one — plus small identities (Fermat, reduction, wire round-trip) and the FIPS-197
published answer for AES-128. Without those the end-to-end test would only prove the
client agrees with itself. The exchange is then run end to end against a server half that
has to undo it: it derives the same secret from the client's public key, decrypts the
128-byte block and reads the credentials back out, and the test also asserts the user name
does not appear in the ciphertext. An incomplete challenge is waited for rather than
half-read, a key length no server would send is refused before anything is allocated, and
credentials too long for their fixed 63-byte fields are refused rather than truncated —
a truncated password is a login that fails for a reason nobody could work out.

Which security type is chosen is a pure function, tested as a table: `None` whenever
offered, then Apple's exchange when a user name and password exist, then classic VNC
authentication, then VeNCrypt — and when nothing on offer can be completed, an error
naming which credential is missing. VeNCrypt itself is driven through the real handler on
an `EmbeddedChannel`: the version exchange, `Plain` carrying the credentials, `VncAuth`
preferred to it and the challenge then answered, a TLS-only server told so rather than
left hanging, and — the one that matters — `Plain` on an unencrypted route closing the
connection with the password never written to it. `ScreenConnectionTests` cover the field
itself: empty is the default and a complete screen, a user name round-trips, and a record
saved before D-031 decodes with none and everything else intact. `VNCUITests` type a user
name into the screen's editor, save, reopen and find it still there. A real Mac and a real
VeNCrypt server are device checks — the bundled LibVNCServer fixture serves neither
security type 30 nor VeNCrypt.

### The legal texts offer no way to contact anyone (B-5)

`LegalDocumentBundleTests` check all nine documents — three texts in three languages — for
anything resembling an address and for the sentences that introduce one, in English and in
both Chinese variants, and assert that the only bracketed values left are the three the
owner still has to supply. The Privacy Policy's rights section used to end by asking the
reader to write to `[developer contact email]`, which the earlier sweep missed; it now says
there is no request to make, because the developer receives nothing and the controls that
answer those rights are in the app. `LegalDocument.currentVersion` is 5, so anyone who
accepted version 4 sees the consent screen again. The guard was checked by inserting an
address into the English Privacy Policy and confirming the suite failed, then restoring it —
a rule nobody has watched break is not a rule.

### A failed sync says what to do about it (D-032)

`SyncFailureTests` are pure — six tests, no iCloud account, no network. Every code a user
can act on produces the action: sign in, storage is full, iCloud Drive is off for this
app, update the app. None of those messages leaks the type name or a pointer, which is
what the status line used to show. The transient codes say they retry, so nobody goes
looking for a fault that is fixing itself. A partial failure is asserted to describe the
error *inside* it, because CloudKit's own message for one says only that something
failed. The build-signed-without-the-container case is checked separately: it is the
failure most easily mistaken for "iCloud is broken", and it is a build problem. Anything
unrecognised keeps the system's wording and carries the CloudKit code.

### The tour (D-033)

`TutorialTests` hold the content to being content rather than layout: six pages, ids that
are both the order and the `TabView` tags, a distinct illustration each, and a body long
enough to earn a page. The preference is off on a fresh install, survives a relaunch, and
is cleared by a reset — which is the whole contract, since "shown once" is a claim about
what happens on the second launch.

`TutorialUITests` drive the real thing on a real install: a fresh one is offered the tour,
each of the six pages is reachable, the last offers "Get started" and not "Continue",
going back returns to "Continue", finishing reveals the app, and a relaunch does not show
it again. Skipping is tested as its own path — it gates nothing, it counts as having seen
it, and Settings → Help brings it back, which is what makes skipping safe to offer.

Every page was also read on screen in light and dark. That is not decoration: it is what
found the identifier inherited by every control from its container, the entrance stagger
that left the last two elements of the busiest page permanently half-drawn, and the card
colour that is invisible against its own background in dark mode. None of the three would
have failed a test.

### App lock — 8 unit tests and 1 UI test

`AppLockTests` run the lock (D-023) with a fake biometric check and a movable clock, on
the real Keychain and the real PBKDF2 derivation: a record never holds the passcode,
matches only its own, gets a fresh salt each time and round-trips; the policy and the
backoff table; enabling needs a passcode the policy accepts and locks nothing until the
app goes away; the grace period; four wrong guesses cost nothing and the fifth costs thirty
seconds during which even the right passcode is refused, then the right one clears
everything; biometrics unlock when the system says yes, are prompted once per lock
automatically, and are not prompted when turned off; the setting without a record locks
nothing; a lock that is showing is released when the record or the setting goes, and
enabling the lock again never locks the current screen. `AppLockUITests` set a passcode through Settings (a mismatched confirmation is
refused and said), relaunch the app keeping its state (`ST_UITEST_KEEP_STATE`), find the
lock screen in front of everything with Settings unreachable, get a wrong passcode
refused and the right one accepted, then leave with the Home button and return to find the
app locked again. Face ID is the system's and a device check.

### Remote screens (VNC) — 13 tests (18 cases) in the package, 5 app unit tests, 1 UI test

`STVNCTests` run against LibVNCServer — the reference server library behind x11vnc and
many others — compiled from Homebrew's `libvncserver` and started on an ephemeral loopback
port for each test, serving a known pattern and logging every event it receives. The
client is connected with one encoding at a time (ZRLE, Hextile, RRE, Raw, CopyRect+Raw,
then the usual preference) and the framebuffer is checked pixel for pixel at five points;
the server's toggling square arrives as incremental updates and changes exactly the
pixels inside it; VNC Authentication succeeds with the right password, is refused with the
wrong one, and reports `passwordRequired` with none; pointer moves, presses, wheel, key
downs and ups (Latin-1 as itself) and cut text appear in the server's log as sent; killing
the server ends the event stream. `RFBDecoderTests` hand-build Raw, CopyRect (overlapping),
RRE, Hextile (background/foreground/subrectangles, a raw tile, an edge tile, a half-delivered
tile) and ZRLE (solid, packed palette, plain and palette run-length through a zlib stream)
rectangles, the DesktopSize pseudo-encoding, an unknown encoding, the wire layout of every
client message and the handshake parsers, and the bit-reversed DES challenge.

`VNCTests` in the app cover the record (round-trip, records without the field, port
validation), the hardware-key table (⌘ stays with the app unless asked, shifted and
control-combined characters, named keys, Latin-1 and Unicode keysyms), the recogniser
set-up (two-finger tap, pointer-only click recognisers per D-018, the wheel recogniser
taking scroll events and no touches, touch-and-hold, hover) and the point mapping through
the letterboxed image with clamping. `VNCUITests` run against LibVNCServer behind the
harness's OpenSSH server: the seeded connection's context menu offers Open Screen; the
screen appears with the desktop's own name and size decoded through a `direct-tcpip`
channel; a tap is found in the server's log as a press and a release; the key row's Escape
arrives down and up; a latched Ctrl goes down before Tab and up after it. Without
`libvncserver` installed the harness says so and these tests skip with that reason.

### Assistant — 5 unit tests and 1 UI test

`AssistantTests` hold the two pure ends of the feature: the prompt builder names the
server's platform, the last command and the chosen terminal text (fenced, cut from the top
on a line boundary past the limit), and the reply parser takes commands only from lines
inside fences, stripping a copied `$ ` prompt and ignoring prose. The provider client is
exercised against a real local HTTP server (`ChatCompletionsTestServer`, NIO, a real
socket) speaking the chat-completions protocol: streamed deltas arrive in order and
concatenate, the key travels in the Authorization header and nowhere in the body, the
request asks to stream and names the model, a 401 with an error body surfaces as a provider
error with its message, a missing key never sends a request, and an answer that is not
JSON is reported as unreadable rather than as a Cocoa error. `AssistantUITests` opens the
assistant from the Session menu and reads which engine the sheet reports. With none — no
eligible model, no key — it checks the reason, the "Open Settings" button and the provider
fields in Settings. With the on-device model reported available it asks a question and
accepts one of two honest outcomes: an answer, or the sheet turning to the unavailable
state that names the model's failure and offers Settings. On this Mac's simulator the
second happens: the host runs Apple Intelligence, `modelmanagerd` finds the model, and the
request fails with a `GenerationError` the framework does not explain (code −1); the
sheet reports exactly that. An answer from a real provider, and the on-device model on an
eligible device, remain hardware checks (B-6).

### App Intents — 3 unit tests

`AppIntentTests` run the intents against a container built on temporary stores through
App Intents' own dependency registry: the connection query matches by name and hostname
and exposes only the name and subtitle; "Connect to Server" opens exactly one session,
records the connection, parks the session for the next window, and does not double an
open one; "Disconnect All Sessions" says "No sessions were open" or how many it closed.
Siri's phrases and the Shortcuts listing are checked on a device (`docs/RELEASE.md`).

### Clipboard expiry — 3 tests

`ClipboardTests` prove the option mapping (0 → no expiry; n → `expirationDate` = now + n)
and, on the real pasteboard in the app host, that text copied with an expiry is readable
back immediately through `UIPasteboard.general.string` — the way every paste path reads
it. The expiry itself is the system's: iOS removes the item after the interval, whether
or not the app is running, which is why no app-side timer exists to test.

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
| The command palette finds a snippet by its initials and inserts it | A snippet is created through the interface, then found by typing `dfh` — three initials that appear nowhere in "Disk Free Here" as consecutive characters, so a substring filter would return nothing. It is inserted rather than run, because the palette uses the same snippet path as everything else |
| The connections from last time are offered back | The app is *terminated* rather than backgrounded — what the system does to an app it reclaims, and the case the feature exists for — then relaunched. The offer appears, states plainly that these are new sessions, opens a terminal when tapped, and does not linger afterwards |
| Pinching resizes the terminal and the server is told | `stty size` is read from the real shell before and after a pinch, and the column count really falls. Asserting the font changed would have proved nothing: the whole risk is a font change the remote is never told about, which leaves every wrapped line wrapping in the wrong place |
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

### Throughput, re-measured on the path the app actually uses

The published figures were wrong, and finding out why was worth more than the optimisation
that came out of it.

`TerminalEmulator.feed` takes any sequence of bytes. The benchmarks fed `Array`; the app
feeds `Data`, straight off the socket. Those took different paths through the parser, and
`Array` was far slower — so **every throughput figure this report has carried understated
what the app was really getting**, by 40% for plain text and more than twice for CJK.

Measured in Release on an Apple silicon Mac, all on `Data`:

| Case | Before | After | Note |
| --- | --- | --- | --- |
| Plain text | 14.5 MB/s | 14.7 MB/s | Unchanged. The app was already this fast; the old figure of 9.0 was the array path |
| Heavily coloured | 29.6 MB/s | 33.5 MB/s | +13% |
| CJK | 12.0 MB/s | 14.9 MB/s | +24%, from the width change below |
| The same text as an `Array` | 9.3 MB/s | 15.4 MB/s | +66%, now at parity with `Data` |

Two changes, both argued for by the trace:

* **`TerminalParser.parse` walks contiguous storage** where the sequence offers it. Every
  byte previously went through a generic iterator call, which over a megabyte of output is
  paid a million times. Anything without contiguous storage still takes the ordinary loop.
* **`CharacterWidth.of` makes one pass** instead of building an `Array` of scalars and
  walking it four more times. For CJK — where every character takes that path — it was an
  allocation and five traversals per glyph, and allocation was the largest leaf cost in
  the profile. The rules and their order are unchanged.

The array/`Data` parity is now asserted as a **ratio measured in the same run**, not
against a fixed number: the two paths should cost the same, and that stays true on a slow
CI runner where any absolute floor would be either flaky or too loose to catch the
regression it exists for. It reads 0.98× now and 0.62× on the old parser, so it fails on
the code it was written to catch. The absolute floors were raised to roughly half of what
is measured, keeping the margin the previous ones had.

### Instruments — a real trace, and what it found

`./scripts/profile-emulator.sh` records a Time Profiler trace of the emulator's hot path
and prints where the time goes. Release, because a Debug profile mostly measures
retain/release traffic the optimiser would have removed, and native on macOS, because the
emulator is the same code on iOS and this makes profiling one command rather than a
session with a device and a UI to drive.

Run on 2026-09-05, before the optimisations below: **3.16 s of CPU across 3 163 samples,
99.6% symbolicated.**

Attributed to the deepest frame of ours on each stack:

| Share | Frame |
| --- | --- |
| 53.6% | `TerminalParser.parse(_:sink:)` |
| 12.4% | `CharacterWidth.of(_:)` |
| 10.0% | `TerminalParser.ground(_:sink:)` |
| 6.2% | `TerminalScreen.lineFeed()` |
| 3.4% | `TerminalScreen.write(_:)` |

Leaf frames, showing what that time is actually spent doing:

| Share | Frame | Reading |
| --- | --- | --- |
| 15.2% | `mach_absolute_time` | The throughput test's own clock, not the emulator. Worth naming so it is not mistaken for a finding |
| 9.6% + 9.2% + 2.5% | `_xzm_xzone_malloc_tiny`, `_xzm_free`, `_xzm_xzone_malloc` | Allocation churn is over a fifth of the remaining time |
| 4.6% | `_StringGuts.validateScalarIndex` | `Character` handling, which is what the parser works in |

**What this says.** `CharacterWidth.of` is a lookup with an ASCII fast path already, and it
is still an eighth of the profile — because the cost is not the table search, it is that
the parser deals in `Character`, which is a grapheme cluster backed by String storage. The
allocation and `_StringGuts` figures point the same way. Working in `Unicode.Scalar` or
UTF-8 bytes through the parse loop is the change the trace argues for, and it is a real
refactor of the hottest code in the app rather than a tweak.

**Not done, deliberately.** The throughput floors are met with room to spare — 9.0 MB/s
plain, 12.7 MB/s coloured — so this is an optimisation with evidence behind it rather than
an urgent fix, and rewriting the hot path at the end of a session is how correctness bugs
get introduced into the one component every character passes through. It is recorded here
with the measurement that justifies it.

### Keyboard session switching — 6 app tests

The bindings are declarative; where they *land* is what is worth testing, because a
shortcut that quietly selects the wrong terminal sends the next keystroke to the wrong
machine. Out-of-range numbers do nothing rather than clamping, cycling wraps at both ends,
and a window holding the id of a session someone else closed can still move.

### Fuzzy ranking — 13 package tests

The palette is only as good as its ranking: with forty things matching `wp`, which one is
first *is* the feature. These pin the behaviour against names of the shape people actually
use, rather than asserting that matching works at all.

| Property | Example that pins it |
| --- | --- |
| Order matters, but adjacency does not | `wpr` matches `web-prod`; `rpw` does not match it |
| Initials beat scattered letters | `wp` prefers `web-prod` over `wrapper` |
| Consecutive beats spread out | `prod` prefers `prod-db` over `p-r-o-d` |
| A prefix beats a match in the middle | `db` prefers `db-primary` over `backup-db` |
| Shorter beats longer | `df` prefers `df -h` over `dpkg --force-confold --refresh` |
| Word boundaries are found inside a name | `wp` matches the `P` of `webProd` |
| Realistic hosts | `wp`→`web-prod-01`, `ws`→`web-staging`, `bn`→`backup-nightly` |
| Realistic commands | `dps`→`docker ps`, `jf`→`journalctl -f` |
| Ties keep the caller's order | Which is usually meaningful — most-used first, or alphabetical |
| Matched positions are reported | So the palette can bold them; a fuzzy result that does not show *why* it matched reads as arbitrary |

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

### Localization — 385 strings, a CI gate, and three tests that run the app in Chinese

Simplified and Traditional Chinese, across the app target (295 strings) and the two
package modules whose error messages the user reads verbatim (STSSH 49, STCloudflare 41).
`scripts/localization-audit.sh` builds with `SWIFT_EMIT_LOC_STRINGS=YES`, reads the keys
the compiler emitted, and fails CI if any lacks a translation in either language. It is
green. That gate is the deliverable as much as the translations are: localization is the one
regression nothing else catches — a new `Text("…")` compiles, passes every test, and shows
English to someone who chose Chinese.

| Test | What a pass proves |
| --- | --- |
| Simplified Chinese reaches the interface | Launched with `-AppleLanguages (zh-Hans)`: the Connections header, the search prompt (revealed first — on iPad a sidebar folds it into the navigation bar), Settings and its Appearance section are Chinese. Then a tour opens Keys and Snippets and screenshots each — asserted, not skipped, because a tour that quietly omits the screens it exists for proves nothing |
| Traditional Chinese is translated independently | The Traditional build shows 連線 and contains no 连接. This is the assertion that catches the usual failure: Traditional produced by running a character converter over Simplified, which leaves mainland vocabulary behind and reads as foreign in Taiwan. Same tour, with 金鑰 and 指令片段 |
| Terminal output is never translated | In the Chinese app, against a real `sshd`, `printf` output arrives on screen unchanged. Remote bytes are a program's output; a terminal that "helpfully" localized them would be worse than useless |

**What the compiler said the source could not.** Keys were taken from `.stringsdata`, not
from reading Swift: `Text("Delete \(name)?")` is looked up under `Delete %@?`, so a catalog
keyed on source text matches nothing and fails silently. 36 translations arrived carrying raw
`\(identity.displayName)` and would have printed it on screen. Each was mapped to the
specifier its expression became, matched by expression text so that a reordered argument —
Chinese puts the port before the host in "could not connect to X on port Y" — produces
`%2$@ … %1$@` rather than a silently swapped pair. Placeholder multisets are asserted equal
before anything is written; the first version of that check normalised `%2$@` and `%@`
differently and rejected the one correctly reordered string, which is recorded because it
is exactly the failure a placeholder check exists to catch.

**229 literals were made localizable in source**, by twelve agents on disjoint files with
twelve adversarial reviewers reading the diffs. The reviewers caught real defects: an `Int`
port interpolated into `String(localized:)` becomes a locale-formatted number — port 8022
would render as "8,022" — and was changed to `\(String(port))`; two already-localized
sentences nested inside another localized string; and an environment-request failure left
as a plain literal. They also correctly refused to touch `UIKeyCommand(input: "k")`, which
would have silently unbound ⌘K, and every enum raw value that is both stored and displayed.
The gate then found **five strings the agents had created by restructuring** — one joined
from two source lines, one parameterised — that existed in no inventory.

**A missing `NSFaceIDUsageDescription`, found along the way.** The app protects keys with
`.biometryCurrentSet` and builds an `LAContext`, but shipped no usage description. iOS
terminates an app that invokes Face ID without one. The simulator never invoked Face ID, so
no test had reached it. Added, and localized through an `InfoPlist.xcstrings`.

**Test-harness defects the Chinese runs exposed, none a product fault.** The two Chinese
tours are the first tests to open *several* Settings screens in sequence, and doing so on
both devices found four separate defects in how the UI tests drove the app:

* **Swiping the app instead of the form.** On iPad, Settings is a form sheet and the
  connection list stays visible behind it, so `app.swipeUp()` scrolls the list and the sheet
  never moves. One helper had been fixed for this earlier; the Keys test and the history
  toggle each still had their own inline swipe. The Language section added this session is
  what pushed Keys off-screen and surfaced them.
* **Choosing an element in one snapshot and acting on it in the next.** Three successive
  versions of the form-scrolling helper failed the same way: a count taken then indexed
  (`element(boundBy: count - 1)`), and an `.exists` checked then swiped, both re-resolve
  against the live accessibility tree independently, race a transition, and report "no
  matches" for an element that was there a moment before. The one that works decides and
  acts in the same expression, and the form carries an accessibility identifier so it can
  be found by identity rather than by position in a tree whose order differs by device.
* **A scroll helper that only went one way.** After opening a row near the foot of the form
  and coming back, every row above it was "unreachable" — an ordering artefact of the test,
  not a property of the screen. It now searches both directions, downward first.
* **The wrong Back button.** `navigationBars.buttons.element(boundBy: 0)` is the first
  button of the first bar in the app. Inside a sheet there are two bars, and that button is
  the sheet's own *Done* — so "Back" from Keys dismissed Settings entirely, and the tour's
  next row was genuinely not on screen. This was the real cause of every second-row failure
  on both devices in both languages. It was found because the tour was changed to attach a
  screenshot at the moment it could not find a row, instead of leaving the failure to be
  reasoned about: the screenshot showed the connection list. Back is now taken from the
  pushed screen's own bar.

**A crash I introduced, and removed.** To make the form findable by identity I attached
`.accessibilityElement(children: .contain)` to the Settings `Form` alongside its
identifier. On iPad — the one device whose hardware-keyboard focus engine is live — popping
the Keys screen back to Settings then aborted the process inside UIKit's focus system
(`_UIFocusContainerGuideFallbackItemsContainer`, every frame UIKitCore, none ours): a focus
container derived from an accessibility container nested inside the collection view that
already was one. The Chinese tour found it because it is the first test to push and pop a
screen inside the Settings sheet on iPad; the crash report is the evidence. Removing that
one modifier, and nothing else, took the iPad suite from the abort to 20 of 20, with no new
crash report. The identifier stays; where it does not surface, the scrolling helper falls
back to the only collection view on screen, which is the path iPhone always used.

Two other things from the same investigation are worth recording. A UI-snapshot attachment
cannot answer whether an identifier is exposed: it contains only on-screen elements, so
even the form's first section header was absent from one, and a search of it proves
nothing. And the attachment manifest does not order screenshots by time — a conclusion
drawn from "the last screenshot" was drawn from the first one. Both are the kind of
mistake that reads as evidence, which is why the tour now generates its own.

### Ciphers — 10 tests, three of them against a real server offering one cipher only

`chacha20-poly1305@openssh.com` joined AES-GCM and AES-CTR this session. It is proved the
same way AES-CTR was: by removing the alternative. An OpenSSH server configured with
`Ciphers chacha20-poly1305@openssh.com` and nothing else accepts the connection and runs a
command, and a 400 KB burst over it stays in sync in both directions — hundreds of packets
whose nonce is the sequence number, so a single mis-numbered packet would fail the tag and
end the session.

That one handshake validates, all at once: the RFC 4253 § 7.2 key extension (this is the
only cipher that asks for more key material than a SHA-256 digest provides), the order of
the two 256-bit keys, the sequence-number nonce, counter 0 for the length and the one-time
Poly1305 key against counter 1 for the payload, the tag's coverage of the encrypted length
and payload, and the padding treatment. A mistake in any of them fails outright; there is
no way to pass this test by accident. The construction is OpenSSH's own, not RFC 8439, and
is built from libsodium's ChaCha20 and Poly1305 with a constant-time tag comparison.

It required two changes to the vendored `swift-nio-ssh`, both now in the patch and both
covered by upstream's suite plus two new tests (349 total): key extension in the key
exchange, and a `sequenceNumber` parameter on `decryptFirstBlock` — the call that reveals
the length was never told the sequence number the length is encrypted under. D-013 has the
full reasoning. AES-GCM remains preferred and still wins when both are offered; AES-CTR
still passes through the changed protocol.

#### Two harness defects found by running the regression in parallel

To save time this session's regression was run as three concurrent streams. Three
`xcodebuild test` sessions competing for two simulators produced aborted runs whose result
bundles recorded **no failed test** — "TEST FAILED" with nothing behind it — which is the
signature of a simulator-level abort, not a test outcome. Every one of those passed when
re-run alone. That was a harness choice and it is not repeated: simulator jobs run serially.

But the load exposed two real defects in the tests themselves, both fixed:

* **The Debug throughput floor was miscalibrated.** It divided the Release floor by 3; the
  measured Debug/Release ratio is 4.6–5.1×. The Debug floor sat 20% under the measured rate,
  passing alone and failing under any load. It now divides by 5 — the measured ratio with
  the same near-half margin the Release floors use — and the numbers are in the comment.
* **A test cancelled its consumer before it could consume.** `streamObservesEverySource`
  yielded into a buffering `AsyncStream` and cancelled the collector 50 ms later; on a
  loaded machine the collector had not yet been scheduled, so the buffered elements were
  never read. It now waits for the condition and then cancels.

##### Ciphers — the earlier 8 tests

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
| **Archive and TestFlight** | `xcodebuild archive` fails with *"Signing for ApexTerminal requires a development team"*. Recorded as `PROJECT_STATUS.md` B-4. |
| **External keyboard and pointer** | The key mapping is implemented and unit-testable, but has not been exercised against real hardware. |
| **Accessibility** | VoiceOver, Dynamic Type and high-contrast passes have not been run. |
| **Double-tap to select a line** | Implemented and unit-tested at the model level; not driven by a UI test. Long-press-and-drag selection and find both are. |
| **Mouse reporting** | Modes are parsed and surfaced; nothing sends mouse events yet. |
| **VoiceOver, heard** | Every control is labelled and the terminal exposes its rendered text, both asserted by tests. Nobody has listened to an actual VoiceOver session, which is a different thing. |
| **Increase Contrast selecting the high-contrast theme** | Still verified by reading the code. Screenshotting it needs a live terminal at that setting, which the current harness does not drive. |
| **Pointer and hover on iPad** | Hover reporting is implemented; it has not been driven with a trackpad. |
| **Keychain behaviour** | `KeychainSecureStore` is written but untested; Keychain semantics differ enough in a macOS unit-test process that a passing test there would prove little. Needs device tests. |
| **Instruments profiling of the emulator** | Done — see the trace section above. `scripts/profile-emulator.sh` makes it repeatable. The asserted throughput floors stay as the regression gate, because they produce a number on every run and in CI; the trace answers the different question of *where* the time goes. |
| **Instruments profiling of the renderer** | Still not run. The trace above covers the emulator — parsing and screen updates — which is a different component from the Core Text drawing path. Drawing is covered by asserted frame-budget tests rather than a trace, so nothing claims to know where its time goes. |

## Observed environment issue

`trycloudflare.com` quick tunnels were attempted on 2026-09-04 as a way to reach a live
edge without an account. Two tunnels registered successfully (`cloudflared` 2026.6.1
connected to `sjc07` over QUIC), but every request to the assigned hostname returned an
empty-bodied HTTP 404 from the Cloudflare edge and **no request ever reached the
tunnel**. Both an `ssh://` and an `http://` origin behaved identically, ruling out the
origin scheme. This closes off the no-account route to live verification; it is recorded
in `PROJECT_STATUS.md` as B-3.
