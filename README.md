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

## Requirements

| | |
| --- | --- |
| Build machine | macOS 26.5 or later |
| Xcode | 26.6 or later (Swift 6.3) |
| Deployment target | iOS / iPadOS 17.0 |
| Integration tests | OpenSSH (`/usr/sbin/sshd`, `/usr/bin/ssh-keygen`) — present on macOS by default |

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
* **The legal texts carry placeholders.** Effective date, legal name, contact addresses
  and governing law are the project owner's to fill, and the texts have not been reviewed
  by a lawyer — they say so. See `PROJECT_STATUS.md` B-5.

## Licence and trademarks

Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.
SuperTerminal is not affiliated with or endorsed by Cloudflare. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
