# Project status

**Updated:** 2026-09-04 · **Phase:** 2 of 7 — SSH core proven, Cloudflare carrier
implemented and awaiting live verification

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
| Package builds clean under Swift 6 strict concurrency | `swift build` — zero errors, zero warnings from project code |

### Written, builds, not yet proven end to end

| Capability | What is missing |
| --- | --- |
| Cloudflare Access discovery, JWKS verification, token validation | Unit tests against a controlled identity; live run against a real Access application |
| Cloudflare interactive login (transfer-service flow) | A real Cloudflare account with an identity provider |
| Cloudflare WebSocket carrier | Tests against the local carrier server; then a live tunnel |
| Keychain secure store | Device tests (Keychain behaves differently in a macOS unit-test process) |

### Not started

Terminal emulator · SwiftUI app · design system · iPad multi-scene · hardware keyboard ·
accessibility · Xcode project and app target · CI · snippets, history, SFTP, port
forwarding, App Intents.

---

## Blocking issues

### B-1 · RSA keys are not supported *(open, high)*

`swift-nio-ssh` 0.15.0 implements no RSA key type, so RSA **user keys** cannot
authenticate and servers offering only RSA **host keys** cannot be reached. Recorded in
`DECISIONS.md` D-002. Planned fix: add `rsa-sha2-256` / `rsa-sha2-512` over
`swift-crypto`'s `_RSA.Signing`. Until then the app reports this precisely rather than
as a generic failure.

### B-2 · Live Cloudflare verification needs an account *(open, blocking acceptance)*

Nothing local can prove Access authentication works. The exact inputs required are
listed under **What is needed from the project owner** below.

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

**Not needed yet** — the request will be made when the code is ready to run the
verification the same day. Do not send credentials in chat; the intake procedure is in
`docs/CLOUDFLARE.md`.

1. **A Cloudflare Access-protected SSH hostname** (e.g. `ssh-test.example.com`) fronted
   by a Cloudflare Tunnel whose ingress points at a test SSH server.
   *Unblocks:* the full chain — discovery, login, carrier, SSH handshake, PTY.
2. **A test identity** allowed by that application's policy, ideally with MFA enabled.
   *Unblocks:* SSO/MFA login, token expiry and re-authentication.
3. **An Access service token** (client ID + secret) for the same application.
   *Unblocks:* automated, browser-free end-to-end runs in CI.
4. **An Apple Developer team ID** and a device provisioning profile.
   *Unblocks:* on-device runs, archive, TestFlight. A paired iPhone 16 Pro is already
   visible to the build machine, and two Apple Development signing identities exist.

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
