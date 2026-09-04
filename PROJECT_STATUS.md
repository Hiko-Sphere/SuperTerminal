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
| Whole suite | 73 tests in 11 suites, 7.6s; the live Cloudflare suite skips cleanly without credentials |
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
trackpad. VoiceOver reads the terminal's rendered text, which is wired but has not been
heard. The high-contrast theme is selected automatically under increased contrast,
verified by reading the code rather than by running with the setting on.

### Not started

Multi-scene (`UISceneSession`) support · drag-and-drop on iPad · Instruments profiling of
the renderer · snippets · command history · iCloud sync · SFTP · port forwarding · App
Intents · Spotlight.

---

## Blocking issues

### B-1 · RSA keys are not supported *(open, high — fix under way)*

`swift-nio-ssh` implements no RSA key type at any released version, nor on `main`
(verified at commit `3ec2814`). RSA **user keys** cannot authenticate and servers offering
only RSA **host keys** cannot be reached.

**Progress:** the library is now vendored at `Packages/swift-nio-ssh-rsa/`, committed
unmodified first and verified by running upstream's own 346 tests against it. The RSA
patch itself is not yet written — the decision, the alternatives weighed, the maintenance
obligation this creates and the RFC 8332 pitfalls are recorded in `DECISIONS.md` D-007.

Until it lands the app reports this precisely rather than as a generic failure.

### B-2 · Live Cloudflare verification needs an account *(open, blocking acceptance)*

Nothing local can prove Access authentication works. The exact inputs required are
listed under **What is needed from the project owner** below.

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
