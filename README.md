# SuperTerminal

An SSH terminal for iPhone and iPad that connects to servers published through
**Cloudflare Tunnel** and protected by **Cloudflare Access** — with no helper binary on
the device, and a real native interactive PTY at the end of it.

> **Status: in development.** The app builds, runs, and connects — with the SSH stack,
> the terminal and the interface each covered by tests that run against a real OpenSSH
> server. Live Cloudflare Access verification is the significant piece still outstanding.
> [`PROJECT_STATUS.md`](PROJECT_STATUS.md) is the authoritative account of what is
> proven, what is merely written, and what is missing — read it before believing
> anything here.

## The problem this solves

On a desktop you reach an Access-protected SSH host with:

```
Host ssh.example.com
  ProxyCommand cloudflared access ssh --hostname %h
```

iOS cannot do that. It cannot spawn a helper process, run a background daemon of its
own, or install a CLI tool. So mobile SSH clients either cannot reach these hosts at
all, or fall back to a browser-rendered web terminal.

SuperTerminal implements the protocol instead. Cloudflare's carrier turns out to be an
ordinary WebSocket whose binary frames are a raw TCP byte stream, and the login flow
delivers its credential through a transfer service rather than through a browser cookie
— both of which a native app can do directly. The result is a genuine SSH session:
real key exchange, real host-key verification, a real PTY.

The evidence behind that claim, including the exact `cloudflared` source consulted, is
in [`DECISIONS.md`](DECISIONS.md) (D-001).

## What it does

* **SSH** over direct TCP or through Cloudflare Tunnel and Access (browser sign-in or a
  service token), with host-key verification that asks and never silently accepts a
  change, Ed25519/ECDSA/RSA keys, passphrase-protected keys and passwords in the Keychain.
* **A real terminal**: its own emulator with scrollback, search, selection, mouse
  reporting, themes, snippets and command history; a hardware keyboard and a mouse or
  trackpad on iPad work the way they do on a desktop (D-018).
* **Remote screens over VNC**, configured as connections of their own and reached through
  a saved SSH connection, through a Cloudflare Tunnel of their own, or directly — touch,
  external keyboard and pointer control, proven against LibVNCServer (D-022, D-027, D-029).
  A screen that signs in to an account — a Mac sharing its screen, or a VeNCrypt server —
  takes an optional user name beside its optional password, and a password is never sent in
  the clear on a connection with nothing protecting it (D-031). A full 1080p frame decodes
  in well under a millisecond (D-030).
* **An assistant** for "how do I…", "explain this" and "what went wrong", on the device's
  own model where it is eligible, else a provider you configure — it shows what it will
  send before it sends it, and a suggested command is inserted, never run (D-020).
* **Siri and Shortcuts** — "Connect to <server> in SuperTerminal" (D-021) — and the
  server's platform (macOS, Linux, Windows…) detected or set by hand (D-019).
* **iCloud sync** of connections, keys' public halves, known hosts and snippets, opt-in
  and conflict-checked (D-015); **an app lock** with a passcode of its own behind Face ID
  or Touch ID (D-023); a privacy policy, terms and notices in English, Simplified and
  Traditional Chinese, accepted in the app before anything else (D-016).

## Requirements

| | |
| --- | --- |
| Build machine | macOS 26.5 or later |
| Xcode | 26.6 or later (Swift 6.3) |
| Deployment target | iOS / iPadOS 17.0 |
| Integration tests | OpenSSH (`/usr/sbin/sshd`, `/usr/bin/ssh-keygen`) — present on macOS by default |
| Screen (VNC) tests | LibVNCServer from Homebrew (`brew install libvncserver`); the package and UI screen tests compile a small server against it, and without it they skip and say so |

## Building and testing

```bash
cd Packages/SuperTerminalKit
swift build
swift test
```

The test suite starts a real `sshd` on an ephemeral port, connects to it over both
transports, and runs real commands. Nothing is stubbed: a green run means the client
interoperates with OpenSSH, not that it agrees with a mock.

```bash
# Just the SSH-over-real-OpenSSH suite
swift test --filter SSHIntegrationTests

# Just the Cloudflare carrier suite
swift test --filter CarrierIntegrationTests
```

## Repository layout

```
Packages/SuperTerminalKit/     all logic, testable on macOS without a simulator
  Sources/
    STCore/                    transport protocol, error taxonomy, redacting logger
    STSecureStore/             Keychain with explicit protection classes
    STCloudflare/              Access discovery, JWKS, tokens, login, WebSocket carrier
    STSSH/                     SSH client, host-key policy, key parsing, generation, sessions
    CBcryptPBKDF/              vendored OpenBSD bcrypt_pbkdf (see THIRD_PARTY_NOTICES)
    STTerminal/                VT/ANSI emulation
    STTestSupport/             real sshd harness, carrier server reproducing the edge
  Tests/
App/                           SwiftUI application (not yet created)
docs/                          Cloudflare setup, SSH guide, operations
```

## Documentation

| Document | What it covers |
| --- | --- |
| [`PROJECT_STATUS.md`](PROJECT_STATUS.md) | What works, what is unproven, what is blocked, and what is needed from the project owner |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | Phased plan with per-item state |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Module structure and the end-to-end Cloudflare path |
| [`DECISIONS.md`](DECISIONS.md) | Decision records with the evidence behind each one |
| [`SECURITY.md`](SECURITY.md) | Threat model, key handling, and stated residual risk |
| [`TEST_REPORT.md`](TEST_REPORT.md) | Commands actually run, when, and what they produced |
| [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) | Dependencies, licences, and exactly what was modified in vendored code |

### Guides

| Document | What it covers |
| --- | --- |
| [`docs/CLOUDFLARE.md`](docs/CLOUDFLARE.md) | Publishing an SSH server through Cloudflare Tunnel and Access, service tokens, diagnosing each edge failure, revoking access |
| [`docs/SSH.md`](docs/SSH.md) | Using the app: connections, keys, host key verification, the algorithm matrix, terminal gestures |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Building, testing, signing, and maintaining the vendored `swift-nio-ssh` |
| [`docs/RELEASE.md`](docs/RELEASE.md) | App Store and TestFlight checklist, privacy answers, likely review questions |
| [`docs/PRIVACY.md`](docs/PRIVACY.md) | What is stored, where, and what leaves the device — the engineering view |
| [`App/Resources/Legal/`](App/Resources/Legal/) | The Terms of Use, Privacy Policy and User Notice as shipped, in English, Simplified and Traditional Chinese, plus the third-party notices |

## Known limitations

These are real and are not worked around silently:

* **Cloudflare Access has not been verified against a live account.** The protocol is
  implemented and the carrier is tested locally, but no local harness can authenticate a
  real identity. See `PROJECT_STATUS.md` B-2.
* **No HTTP proxy support** on the carrier path.
* **iCloud sync has not been verified against iCloud.** The engine, its conflict rules
  and the CloudKit record mapping are tested offline; the live path needs a signed build
  with the container entitlement, which an ad-hoc simulator build does not carry. See
  `PROJECT_STATUS.md` B-4. Nothing in the app claims otherwise.
* **The iPad's hardware keyboard and pointer are proven only as far as a simulator can.**
  The defects found in that path (D-025) are covered by tests that reproduce them, but a
  real Magic Keyboard, a real mouse and the iPadOS focus engine are on the release
  checklist, not in CI.
* **Face ID and Touch ID for the app lock are proven with a stand-in.** The lock's rules
  are tested with a biometric check the test controls and the real Keychain and
  derivation; the system prompt itself is a device check on the release checklist.
* **macOS Screen Sharing's own sign-in and VeNCrypt are implemented but not yet run
  against a real Mac or a real VeNCrypt server.** Both are verified against vectors from an
  independent implementation and end to end against a second implementation of the server
  half, because the bundled LibVNCServer fixture serves neither (D-031). A real Mac and a
  real VeNCrypt server are on the device checklist.
* **Remote screens are proven against LibVNCServer, not yet against a Mac or a desktop
  Linux box.** Every encoding, authentication and input path is checked against the
  reference server library; macOS Screen Sharing (with "VNC viewers may control screen with
  password" on) and a Linux desktop are on the release checklist.
* **The assistant has not answered from a real provider here.** Its wire behaviour is
  proven against a local server speaking the same protocol; a live answer needs a key you
  supply, and the on-device model needs a device eligible for Apple Intelligence.
* **The legal texts carry placeholders.** Effective date, legal name and governing law
  are the project owner's to fill (the texts carry no contact details, by decision), and the texts have not been reviewed
  by a lawyer — they say so. See `PROJECT_STATUS.md` B-5.

## Licence and trademarks

Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.
SuperTerminal is not affiliated with or endorsed by Cloudflare. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
