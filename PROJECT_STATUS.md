# Project status

**Updated:** 2026-09-05 · **Phase:** 4 of 7 — the app is driven end to end through its
own interface; Cloudflare carrier implemented and awaiting live credentials

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
| Whole suite | 131 tests in 19 suites, 10.0s; the live Cloudflare suite skips cleanly without credentials |
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
| **Throughput, measured** | Release: 9.0 MB/s plain text, 12.7 MB/s coloured, 8.0 MB/s CJK; reflow of a full 5 000-line scrollback in 18 ms. Floors are asserted per configuration, so a regression fails rather than being noticed later as "sluggish" |
| **Render cost, measured** | A full redraw of both an 80×24 and a 200×55 grid fits inside a 60 Hz frame on the simulator; run coalescing is asserted directly on the run count |
| Selection and find gestures | UI tests: long-press-and-drag selects and offers Copy, and the find bar reports a match count |
| **AES-CTR ciphers** | Proved by removing the alternative: a server offering *only* `aes256-ctr` with encrypt-then-MAC is reachable, and a 400 KB burst over it stays in sync — which is what catches a counter advanced wrongly |
| **Accessibility, run for real** | UI tests launch the app with accessibility text sizes, Reduce Transparency and Bold Text actually enabled, and assert every control carries a label. Screenshots are attached to the result bundle. |
| **Key generation, import and export** | Generated keys are read by `ssh-keygen`, which agrees on the fingerprint, and both algorithms authenticate against a real `sshd` that trusts only the generated key. A UI test generates one through the interface. |
| **Snippets insert without running** | A UI test creates a snippet through the editor, taps it, and asserts against a real shell that the text is on the line *and its output is not* — then presses Return and sees the output appear. The default that a snippet waits for Return is the safety property, so it is tested by observing the absence. |
| **Command history is off until asked for** | A UI test runs a command, finds history empty and off, turns it on through Settings, runs another command, and sees exactly the second one — recorded as typed, with no prompt and no output, and with nothing resurrected from before the opt-in. Turning it off deletes the file, not just the list. |
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

Instruments profiling of the renderer · session restoration across launches · iCloud
sync · SFTP · port forwarding · App Intents · Spotlight.

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

### B-4 · Archiving is blocked on a development team *(open)*

`xcodebuild archive` fails with *"Signing for SuperTerminal requires a development
team"*. The same configuration builds for a device with signing disabled, so the code is
device-ready and signing is the only gap. Two Apple Development identities exist on the
machine but no team is set in the project.

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
   `ASWebAuthenticationSession`, so it can only be exercised once the app target exists.
5. **An Apple Developer team ID.** A paired iPhone 16 Pro is already visible to the
   build machine and two Apple Development signing identities exist, so this is needed
   for distribution rather than for device testing.

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
