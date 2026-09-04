# SuperTerminal

An SSH terminal for iPhone and iPad that connects to servers published through
**Cloudflare Tunnel** and protected by **Cloudflare Access** — with no helper binary on
the device, and a real native interactive PTY at the end of it.

> **Status: in development.** The SSH core and the Cloudflare carrier are implemented
> and covered by tests that run against a real OpenSSH server. Live Cloudflare Access
> verification, the terminal emulator and the app UI are not done yet.
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
    STSSH/                     SSH client, host-key policy, key parsing, sessions
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

## Known limitations

These are real and are not worked around silently:

* **RSA keys are not supported.** `swift-nio-ssh` 0.15.0 implements no RSA key type, so
  RSA user keys cannot authenticate and servers offering only RSA host keys cannot be
  reached. See `DECISIONS.md` D-002 for the plan.
* **Cloudflare Access has not been verified against a live account.** The protocol is
  implemented and the carrier is tested locally, but no local harness can authenticate a
  real identity. See `PROJECT_STATUS.md` B-2.
* **No HTTP proxy support** on the carrier path.
* **No app yet.** The SwiftUI application, the terminal emulator and the design system
  are not built.

## Licence and trademarks

Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.
SuperTerminal is not affiliated with or endorsed by Cloudflare. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
