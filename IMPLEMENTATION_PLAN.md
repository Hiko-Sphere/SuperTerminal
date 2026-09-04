# Implementation plan

Phases are ordered by risk, not by visibility. The Cloudflare transport is the thing
most likely to be impossible, so it is settled before any pixel is drawn.

Legend: ✅ done and proven · 🟡 written, awaiting verification · ⬜ not started

---

## Phase 0 — Environment and protocol research ✅

* ✅ Toolchain, simulators, devices and signing identities surveyed
* ✅ `cloudflared` source read; carrier and login protocol characterised (`DECISIONS.md` D-001)
* ✅ SSH and crypto dependencies evaluated and chosen (D-002, D-004)
* ✅ Local OpenSSH test server working, unprivileged, on an ephemeral port
* ✅ Quick-tunnel route to a live edge attempted and found unavailable (`PROJECT_STATUS.md` B-3)

## Phase 1 — SSH core ✅

* ✅ `ByteStreamTransport` abstraction; both transports vend an identical `Channel`
* ✅ `DirectTCPTransport` on Network.framework
* ✅ `SSHConnection` / `SSHShellSession` over `swift-nio-ssh`
* ✅ Host-key policy with a hard stop on a changed key
* ✅ OpenSSH private key parsing, including bcrypt-protected keys
* ✅ Credential chain that skips methods the server has ruled out and fails fast when exhausted
* ✅ Handshake monitor: `connect` resolves on `UserAuthSuccessEvent`, or fails with the *first* recorded error
* ✅ Integration tests against a real `sshd`

## Phase 2 — Cloudflare Access transport 🟡 ← current

* ✅ Access application discovery with a signature-verified metadata JWT
* ✅ JWKS provider with caching, rate-limited refresh, RS256-only, `kid` pinning
* ✅ Token validation: audience, issuer, lifetime
* ✅ Interactive login: ephemeral key pair, CLI URL, transfer-service poll, `crypto_box_open`
* ✅ WebSocket carrier with masking, fragment forwarding, ping/pong, close handshake
* ✅ Edge failure classification (Access redirect, 403, 404, 502/503/504, 530)
* ✅ `WebSocketCarrierTestServer` reproducing the edge's protocol and failure responses
* 🟡 Carrier tests: SSH over WebSocket, service-token headers, each failure mode
* 🟡 Access unit tests against a controlled local identity (own JWKS and signed tokens)
* 🟡 Token storage in the Keychain, with expiry and sign-out
* ⬜ **Live end-to-end run** against a real tunnel and Access application *(blocked: B-2)*

## Phase 3 — Terminal emulator ✅ (rendering measured in phase 6)

* ✅ VT/ANSI parser with a state machine that cannot be wedged by malformed input
* ✅ Screen model: primary and alternate buffers, bounded scrollback, scroll regions
* ✅ Unicode widths from generated UCD tables; CJK, emoji, ZWJ sequences, flags
* ✅ 256-colour and true colour, in both the semicolon and colon notations
* ✅ Core Text renderer with run coalescing
* ✅ Selection model, copy that respects soft wraps, block selection, logical-line selection
* ✅ Reflow on resize, including wide characters, attributes and the cursor
* ✅ Search over the whole buffer, including terms split across a wrap
* ✅ Bracketed paste, with a confirmation for multi-line pastes
* ✅ Mouse reporting output, in both encodings, with a live round-trip test
* ✅ OSC 8 link opening, behind a confirmation that shows the destination
* ⬜ Instruments measurement (deferred to phase 6, where there is a real workload)

## Phase 4 — Application 🟡 ← current

* ✅ Xcode project, app target, entitlements, privacy manifest
* ✅ Design system: colour, type, spacing, radius, elevation, motion tokens; three themes
* ✅ Host list, connection editor, terminal screen, prompts, settings, known hosts, diagnostics
* ✅ Error, empty, loading and reconnect states driven by the error taxonomy
* ✅ iPhone accessory key row with a latching Control
* ✅ Hardware keyboard mapping, including application cursor mode and Meta
* ✅ Runs on iPhone and iPad simulators; app-hosted integration test connects to a real server
* ✅ Terminal reachable through the interface on iPhone, verified by a UI test that types and reads back
* ✅ Selection bar, find bar, paste confirmation
* 🟡 iPad: split view works; Stage Manager, multi-scene, pointer and drag & drop outstanding
* ✅ Reduce Transparency honoured through a single modifier rather than per-view
* ✅ Increased contrast selects the high-contrast terminal theme automatically
* ✅ Accessibility run for real: text sizes, Reduce Transparency, Bold Text, label coverage
* 🟡 VoiceOver wired and asserted structurally, but not heard

## Phase 5 — Product features ⬜

Key generation, import and export ✅ · Snippets · searchable local history (off by default) · host tags and folders · iCloud
sync for non-sensitive config · theme and font customisation · Face ID / Touch ID gating
· redacted diagnostics export · App Intents · Spotlight. Port forwarding and SFTP only if
they can be shipped with full security tests.

## Phase 6 — Hardening and release ⬜

Threat-model review pass · dependency and licence audit · Instruments profiling ·
Release build and archive · TestFlight · on-device verification on iPhone and iPad ·
App Store privacy disclosures.

CI is already in place (`.github/workflows/ci.yml`): package build and test with a
zero-warning gate, app builds for simulator and unsigned device, both integration suites,
and hygiene checks for placeholder implementations and committed credentials.

---

## Working rules

1. Nothing is marked ✅ until it has been *executed*, not merely compiled.
2. Every error a user can hit gets a category and a specific recovery action.
3. No `TODO`, no placeholder, no fixed return value standing in for real work.
4. A limitation that cannot be fixed now goes in `PROJECT_STATUS.md` — never hidden.
5. Tests are never weakened to go green.
