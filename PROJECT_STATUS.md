# Project status

**Updated:** 2026-09-06 · **Phase:** 5 of 7 in progress — the app is driven end to end
through its own interface on iPhone and iPad; iCloud sync (opt-in, offline-verified), the
legal texts with a consent gate, clipboard expiry, Access service tokens, and hardware
keyboard and pointer support (xterm modifiers, app shortcuts, wheel, clicks, drag) are
delivered. What remains needs the owner: a live Cloudflare environment (B-2), a
development team for iCloud and archiving (B-4), and the legal placeholders with counsel
review (B-5).

This file is the resumable state of the work. It records what is *proven*, what is
*written but unproven*, and what is *not started* — kept separate on purpose, because
"the code is written" is not the same as "it works".

---

## Where things actually stand

### Proven by execution

| Capability | Evidence |
| --- | --- |
| Ed25519 key authentication against real OpenSSH | `SSHIntegrationTests.ed25519KeyAuthenticationRunsCommand` — real `sshd`, real handshake, remote command returns `CF_E2E_OK` |
| ECDSA P-256 key authentication | `SSHIntegrationTests.ecdsaKeyAuthentication` |
| Passphrase-protected OpenSSH key import (bcrypt + AES-CTR) | `SSHIntegrationTests.encryptedKeyAuthentication` — a wrong passphrase must fail, which only happens if the KDF is bit-exact |
| Interactive PTY allocation | `SSHIntegrationTests.interactivePTYSession` — `stty size` on the remote reports the geometry we requested |
| Terminal resize propagation | `SSHIntegrationTests.terminalResizePropagates` |
| Trust-on-first-use records the server's real host key | `SSHIntegrationTests.trustOnFirstUseRecordsKey` |
| SSH over the WebSocket carrier | `CarrierIntegrationTests` — a full session, a 256 KiB burst, the Access and service-token headers, and each edge failure mode |
| The terminal runs real full-screen programs | `TUIIntegrationTests` — `vim` and `less` over a real SSH PTY, with alternate-screen restore, mid-session resize honoured by vim, and CJK/emoji rendering |
| Unicode cell widths | `CharacterWidthTests` against generated UCD 17.0.0 tables — CJK, halfwidth kana, combining marks, ZWJ sequences, flags, variation selectors |
| Package builds clean under Swift 6 strict concurrency | `swift build` — zero errors, zero warnings from project code |
| Whole suite | 157 tests in 22 suites, 12.0s; the live Cloudflare suite skips cleanly without credentials |
| **The app itself connects** | `scripts/app-integration-e2e.sh` — on an iPhone 17 Pro simulator, the app stores a key in the real Keychain, opens a session, allocates a PTY, and the emulator renders `APP_STACK_OK` and `28 90` from the remote host |
| The host-key prompt gates the connection | Same suite: refusing the prompt fails the session with `.hostKey`, and the fingerprint offered matches the server's real one |
| App launches on iPhone and iPad | Installed and launched on both simulators; UI tests pass |
| Debug and Release both build | Simulator and unsigned device builds, zero warnings from app code |
| **The UI reaches a live terminal** | `scripts/ui-terminal-e2e.sh` — XCUITest taps a connection, the terminal appears, typed text reaches the server and `UI_TERMINAL_READY` renders back; screenshot attached to the result bundle |
| The on-screen Control key sends control characters | Same suite: latching ctrl then `c` interrupts `sleep 30` and the shell stays responsive |
| The host list survives an accessibility text size | Same suite, relaunched at `UICTContentSizeCategoryAccessibilityL` |
| Reflow on column change | 9 tests: widening rejoins, narrowing re-wraps, hard breaks survive, round-trip is stable, wide characters stay whole, attributes and cursor follow, alternate screen is left alone, scrollback stays bounded |
| Selection, copy and scrollback search | 11 tests: soft wraps copy without an injected newline, block selection, wide characters copy once, selection reaches into history, search crosses wraps and is bounded |
| Mouse reporting | 10 unit tests covering both encodings, modifiers, wheel, drag/motion gating and the legacy coordinate ceiling — plus a live round-trip: a remote program enables tracking, and `cat -v` on the far end shows the exact bytes a real terminal would have sent |
| CI | `.github/workflows/ci.yml` — package build/test with a zero-warning gate, app Debug and unsigned-Release builds, both integration suites, and hygiene checks for placeholders and committed secrets |
| iCloud sync engine — merge, tombstones, held host-key conflicts, canonical payloads | 27 tests: `SyncEngineTests` (11, in-memory transport), `CloudKitMappingTests` (5), `AppSyncStoreTests` (11), `KnownHostsRemoveAllTests` (2). CloudKit itself is **not** live-verified — B-4 |
| Legal texts bundled in en / zh-Hans / zh-Hant, parsed and rendered | `LegalDocumentBundleTests` (11) prove every file is in the bundle, comment-free and substantial; `MarkdownDocumentTests` (3); CI fails if the bundled notices drift from `THIRD_PARTY_NOTICES.md` |
| Consent gate and Settings → Legal | `ConsentUITests` (2): a fresh install is gated, the notice renders, acceptance persists across a relaunch, licences open from Settings |
| App Switcher snapshot protection | `PrivacyShield` covers the window whenever the scene is not active; the previously unwired toggle now does what it says |
| Cloudflare Access service tokens, per connection and per device | `ServiceTokenTests` (3): a record written before the field existed decodes; the field round-trips; the real Keychain stores, loads and deletes a token and the secret is redacted in any description. `ServiceTokenUITests` (1): the editor requires the token before saving, saves it, and on reopening reports it as stored without showing it, and iOS's password-save sheet never appears (it did, until every secure field opted out of AutoFill). The carrier's service-token headers were already covered by `CarrierIntegrationTests` |
| Hardware keyboard and pointer | `HardwareKeyMapTests` (8, one per xterm rule: modified arrows, tilde keys, function keys, control bytes, Meta, editing keys, Command never sent); `PointerConfigurationTests` (6): wheel recogniser without touches, indirect-pointer drag, secondary and middle click, edit menu and beam pointer, standard edit actions; `HardwareKeyboardUITests` (7): ⌘K, ⌘N, ⌘, and ↓ in the palette sent as hardware keys pass; Escape / Return in the palette and ⌘K with a text field focused are strict expected failures naming a measured instrument limit. Pointer gestures cannot be driven by XCUITest on iOS — listed for hardware in `docs/RELEASE.md` |
| Clipboard expiry for terminal text | `ClipboardTests` (3): the option mapping, and a real copy in the app host read back through `UIPasteboard.general.string`; the UI copy test reads its selection back the same way. Expiry is enforced by iOS via `expirationDate`, 60 s by default, configurable in Settings → Security |
| **Throughput, measured on the real path** | Release: 14.7 MB/s plain text, 33.5 MB/s coloured, 14.9 MB/s CJK, reflow of a full 5 000-line scrollback in 17 ms — all fed as `Data`, which is what the app feeds. The earlier figures in this table were measured on an `Array`, a path the app never takes and which was far slower, so they understated the product. Both paths are now benchmarked, and their parity is asserted as a ratio rather than a fixed number |
| **Render cost, measured** | A full redraw of both an 80×24 and a 200×55 grid fits inside a 60 Hz frame on the simulator; run coalescing is asserted directly on the run count |
| Selection and find gestures | UI tests: long-press-and-drag selects and offers Copy, and the find bar reports a match count |
| **chacha20-poly1305, proved by removing the alternative** | A real OpenSSH server offering *only* `chacha20-poly1305@openssh.com` is reachable, and a 400 KB burst over it stays in sync. This is the only cipher needing more key than one digest provides, so the same handshake proves the RFC 4253 § 7.2 key extension added to the vendored key exchange. Built from libsodium's primitives, not RFC 8439's AEAD, which cannot express OpenSSH's construction |
| **AES-CTR ciphers** | Proved by removing the alternative: a server offering *only* `aes256-ctr` with encrypt-then-MAC is reachable, and a 400 KB burst over it stays in sync — which is what catches a counter advanced wrongly |
| **Accessibility, run for real** | UI tests launch the app with accessibility text sizes, Reduce Transparency and Bold Text actually enabled, and assert every control carries a label. Screenshots are attached to the result bundle. |
| **Key generation, import and export** | Generated keys are read by `ssh-keygen`, which agrees on the fingerprint, and both algorithms authenticate against a real `sshd` that trusts only the generated key. A UI test generates one through the interface. |
| **Snippets insert without running** | A UI test creates a snippet through the editor, taps it, and asserts against a real shell that the text is on the line *and its output is not* — then presses Return and sees the output appear. The default that a snippet waits for Return is the safety property, so it is tested by observing the absence. |
| **Command history is off until asked for** | A UI test runs a command, finds history empty and off, turns it on through Settings, runs another command, and sees exactly the second one — recorded as typed, with no prompt and no output, and with nothing resurrected from before the opt-in. Turning it off deletes the file, not just the list. |
| **Profiled with Instruments, for real** | `scripts/profile-emulator.sh` records a Time Profiler trace and attributes it to our own frames: 3.16 s of CPU, 99.6% symbolicated, 53.6% in the parse loop and 12.4% in `CharacterWidth.of`. The leaf frames say why — over a fifth in malloc/free and `_StringGuts`, because the parser deals in `Character`. Recorded rather than acted on: the throughput floors are met with room to spare, and rewriting the code every byte passes through is not an end-of-session change |
| **One haptic vocabulary** | Seven ad-hoc feedback generators scattered through the views, none warmed up and none respecting a preference, replaced by a named vocabulary with a setting. Generators are prepared before the gesture that will fire them, because a haptic played cold arrives a beat late and reads as a bug |
| **Keyboard shortcuts that land where you expect** | ⌘N, ⌘K, ⌘⇧[ / ⌘⇧], ⌘1–9, ⌘W, ⌘= / ⌘- / ⌘0 as one `AppShortcut` table exposed as SwiftUI shortcut buttons in the shell and as key commands on the terminal view, routed to one handler, reachable from a hardware keyboard whatever has focus, on iPhone and iPad; `HardwareKeyboardUITests` type ⌘K, ⌘N, ⌘,, ⌘K over a focused search field and Escape as real keys. SwiftUI `Commands` never received them, nor did `keyCommands` on the SwiftUI-wrapped application delegate — found by those tests. A hidden first-responder view was the first mechanism and was measured out: it exposed an iPadOS 26 focus-engine abort with a hardware keyboard (5 of 18 runs; 0 of 17 without it), see D-018 |
| **Simplified and Traditional Chinese, gated** | 385 strings across the app and the two error-producing packages. Keys come from the compiler's `.stringsdata`, not the source, because interpolation becomes `%@` before lookup. `scripts/localization-audit.sh` fails CI on any untranslated string. Three UI tests run the app in each locale against a real server — including the assertion that Traditional shows 連線 and no 连接, which is what catches a converted rather than translated catalog. Terminal output is never translated |
| **`NSFaceIDUsageDescription`, which was missing** | The app gates keys behind Face ID and had no usage description — iOS terminates an app that invokes Face ID without one. No test had reached it because the simulator never invokes Face ID. Added and localized |
| **A command palette that actually ranks** | ⌘K over connections, open sessions, snippets and actions, with real fuzzy scoring — 13 tests pin the ranking against realistic names, so `wp` finds `web-prod-01` rather than `wrapper` and `dps` finds `docker ps`. The matched characters are bolded, which is what makes a fuzzy result legible instead of arbitrary. A UI test types `dfh` and lands on a snippet called "Disk Free Here" — a substring filter would find nothing at all |
| **The connections from last time are offered back** | A UI test opens a session, *terminates* the app rather than backgrounding it, relaunches, and finds the offer — then taps it and reaches a terminal, with the offer gone afterwards. What is remembered is which machines were open, not the scrollback: the buffer is the same asset as command history but far larger, and writing it to disk would make the app's refusal to keep history meaningless |
| **Pinch to resize, and the server is told** | A UI test pinches the live terminal and reads `stty size` from the shell before and after: the column count really drops. A font change alters the size of a cell without changing the view's bounds, so `layoutSubviews` never runs — without an explicit re-measure the remote program would go on wrapping to the old width |
| **Text drags out and drops in** | `UIDragInteraction` lifts the current selection with a snapshot of the selected cells; a drop goes through the same path a paste does, so a multi-line drop is confirmed exactly as a multi-line paste is. A drop that skipped that would run several commands on one gesture with no warning |
| **A dropped connection comes back on its own** | Six integration tests against a real `sshd`, with the traffic running through a relay whose sockets are closed underneath the session — a connection that really dies, not a state flag set by hand. Proves it notices, retries with backoff, comes back with the scrollback intact, gives a working shell, stops when told, retries at once when the network returns, spends no attempts while offline, and does **not** reconnect when the user types `exit` |
| **A second window on iPad is a real second window** | A UI test opens a session in a new window and asserts the app's scene count *increases* — through a Debug-only probe, because a screenshot of the result looks identical whether a scene was created or the menu item did nothing. Selection is per window; a session is displayed by one window at a time so two windows cannot resize the remote program against each other |
| **The iPad layout is tested, not assumed** | The whole UI suite runs on an iPad Pro as a CI gate. Adding that run found four defects the phone run could not see: a snippet row where only the text was tappable, an open-session row that would not select, no Control key at all on a full-screen iPad, and ⌘W listed in the menu with nothing behind it |
| **Typed commands are reconstructed, not scraped** | 12 tests over the keystroke accounting: character-at-a-time, whole-line chunks, multi-line pastes, backspace, `^C`/`^D`/`^Z`/`^U`, and escape sequences. A line the remote line editor may have changed — history recall, cursor movement, tab completion — is dropped rather than guessed at. |

### Written, builds, not yet proven end to end

| Capability | What is missing |
| --- | --- |
| Cloudflare Access discovery, JWKS verification, token validation | Unit tests against a controlled identity; live run against a real Access application |
| Cloudflare interactive login (transfer-service flow) | A real Cloudflare account with an identity provider |
| Cloudflare WebSocket carrier | Tests against the local carrier server; then a live tunnel |
| Keychain secure store | Device tests (Keychain behaves differently in a macOS unit-test process) |

### Written and running, but not yet verified against a person

Double-tap to select a logical line is implemented and unit-tested at the model level but
not driven by a UI test. Hover reporting is implemented but has not been driven with a
trackpad. The terminal exposes its rendered text as an accessibility value and every
control is labelled, but no VoiceOver session has been *heard* — the tests check structure,
which is not the same as listening to it. Increase Contrast selecting the high-contrast
terminal theme is still verified by reading the code, because the terminal itself needs a
live connection to screenshot at that setting.

### Not started

Instruments profiling of the *renderer* — the emulator is profiled, the Core Text drawing
path is not · SFTP · port forwarding · App Intents · Spotlight.

---

## Blocking issues

### B-1 · RSA keys — **closed**

`rsa-sha2-256` and `rsa-sha2-512` are implemented in the vendored `swift-nio-ssh` and
verified against OpenSSH: an RSA user key authenticates against a real `sshd`, a server
offering **only** an RSA host key can be reached, and the same works over the Cloudflare
carrier. `ssh-keygen` and this app agree on an RSA key's fingerprint.

`ssh-rsa` (SHA-1) is **not** supported and will not be — OpenSSH disabled it by default in
8.8, and accepting it would ship a downgrade a server could ask for.

The change is `patches/niossh-rsa.patch`, which applies cleanly to pristine upstream at
tag `0.15.0`. Upstream's own suite still passes (347 tests, up from 346: one test used
`ssh-rsa` as its example of an unrecognised algorithm and was moved to `ssh-dss`, with a
new test added so the truncated-key case it covered is not lost).

### B-5 · The legal documents carry the owner's placeholders *(open, owner-only)*

The Terms of Use, Privacy Policy and User Notice ship in three languages with six values
in square brackets that only the project owner can supply: effective date, developer legal
name, and governing law and venue. There is no contact channel in the texts by the owner's decision.
The texts were drafted for review by counsel and say so in their first paragraph; they are
not legal advice until a lawyer has read them.

### B-4 · Archiving is blocked on a development team *(open)*

`xcodebuild archive` fails with *"Signing for SuperTerminal requires a development
team"*. The same configuration builds for a device with signing disabled, so the code is
device-ready and signing is the only gap. Two Apple Development identities exist on the
machine but no team is set in the project. The same gap blocks iCloud: an ad-hoc simulator
build carries no entitlements at all (the `.xcent` is `{}`), so CloudKit sync and iCloud
Keychain cannot be exercised. The sync engine is verified against an in-memory transport;
the live path is not, and nothing user-facing claims it is.

### B-3 · `trycloudflare.com` quick tunnels do not route from this network *(observed)*

Two quick tunnels were created successfully — `cloudflared` registered a connection to
`sjc07` over QUIC — but every request to the assigned hostname returned an empty-bodied
HTTP 404 from the Cloudflare edge, with no request ever reaching the tunnel. Both an
`ssh://` and an `http://` origin behaved identically, so this is not about the origin
scheme. Consequence: the no-account shortcut for live carrier testing is unavailable,
and B-2 cannot be worked around.

---

## What is needed from the project owner

These are the only things that cannot be produced locally. Each is listed with the
verification it unblocks, so nothing is requested speculatively.

**Ready to run now.** `scripts/live-e2e.sh` and `LiveCloudflareE2ETests` exist and are
skipped only because the environment is unset. Supplying items 1–3 makes a real
end-to-end run possible immediately, with no further code needed.

Do **not** paste secrets into chat. Export them in a shell, or keep them in a file
outside the working tree and `source` it — the script's header documents the variables.

1. **A Cloudflare Access-protected SSH hostname** fronted by a Cloudflare Tunnel whose
   ingress points at a test SSH server. → `ST_LIVE_CF_HOSTNAME`
   *Unblocks:* discovery, carrier, SSH handshake, interactive PTY over the real edge.
2. **An Access service token** (client ID + secret) authorised by that application's
   policy. → `ST_LIVE_CF_SERVICE_TOKEN_ID`, `ST_LIVE_CF_SERVICE_TOKEN_SECRET`
   *Unblocks:* the automated run, with no browser in the loop. This is the smallest
   thing that turns the central product claim from "implemented" into "verified".
3. **An SSH credential for that host** — a key path or a password, plus the username.
   → `ST_LIVE_SSH_USER` and one of `ST_LIVE_SSH_KEY_PATH` / `ST_LIVE_SSH_PASSWORD`

Needed later, not now:

4. **A test identity with MFA** for the interactive SSO login. That path runs through
   `ASWebAuthenticationSession` on a device; the app exists, so this is runnable as soon
   as an identity is available.
5. **An Apple Developer team ID**, with the iCloud capability and the container
   `iCloud.dev.superterminal.app` enabled on the app identifier. A paired iPhone 16 Pro is
   already visible to the build machine and two Apple Development signing identities
   exist. *Unblocks:* archiving (B-4), and every live iCloud check in `docs/RELEASE.md` —
   CloudKit sync between two devices, iCloud Keychain for opted-in keys, purge on delete.
6. **The legal placeholders** (B-5): effective date, developer legal name, governing law
   and venue — in all three
   languages of `App/Resources/Legal/` — and a counsel review of the three texts.

---

## Environment

| | |
| --- | --- |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| iOS SDK | 26.5 |
| Deployment target | iOS/iPadOS 17.0 |
| Simulators | iPhone 17 / 17 Pro / 17 Pro Max / Air / 17e; iPad Pro 11" & 13" (M5), iPad Air 11" & 13" (M4), iPad mini (A17 Pro), iPad (A16) — all iOS 26.5 |
| Physical device | iPhone 16 Pro (paired, available) |
| Signing | Two Apple Development identities present; team ID for distribution not yet supplied |
| Tooling | `cloudflared` 2026.6.1, OpenSSH 10.2p1, Go 1.26.4, Docker/Colima available |
