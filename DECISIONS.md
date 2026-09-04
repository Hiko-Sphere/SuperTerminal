# Decision record

Each entry records a decision that is expensive to reverse, the evidence behind it,
and what would make us revisit it. Entries are append-only; superseded decisions are
marked, not deleted.

---

## D-001 — Cloudflare Access is implemented natively, not by embedding `cloudflared`

**Date:** 2026-09-04 · **Status:** Accepted

### Context

The product's differentiating requirement is connecting to SSH servers published
through Cloudflare Tunnel and guarded by Cloudflare Access. On desktop this is done
with `ProxyCommand cloudflared access ssh --hostname <host>`. iOS cannot spawn a helper
binary, cannot run a background daemon of its own, and cannot install a CLI tool, so the
desktop recipe does not transfer.

### What was actually verified

The `cloudflared` source at commit `2253eeeb25a44a713a4b60b8ba1e1b3f377d1a0f`
(2026-09-03, the tip of `master` at the time of writing; released binary 2026.6.1) was
read directly. The relevant behaviour is:

| Step | Where in `cloudflared` | Wire behaviour |
| --- | --- | --- |
| Discover the Access app | `token/token.go: GetAppInfo`, `fetchMetadataJWT` | `HEAD https://<host>/` with `cf-access-metadata-request: true`; the reply carries a signed JWT in `cf-access-metadata` with `auth_domain`, `aud`, `hostname`, `app_hostname`, `iat` |
| Verify that JWT | `token/jwks.go` | RS256, verified against `https://<auth-domain>/cdn-cgi/access/certs`; `auth_domain` must end in `.cloudflareaccess.com` |
| Interactive login | `token/transfer.go: RunTransfer`, `buildRequestURL` | Browser opens `https://<host>/cdn-cgi/access/cli?aud=…&token=<ephemeral pubkey>&redirect_url=…&send_org_token=true&edge_token_transfer=true` |
| Collect the credential | `token/transfer.go: transferRequest` | Poll `https://login.cloudflareaccess.org/transfer/<ephemeral pubkey>`; body is base64 of `nonce‖crypto_box`, sealed to the ephemeral key; `service-public-key` response header names the sender |
| Open the carrier | `carrier/websocket.go`, `carrier/carrier.go: BuildAccessRequest` | WebSocket upgrade to `wss://<host>/` with header `Cf-Access-Token: <app JWT>`; **binary frames carry raw TCP bytes** |
| Bastion mode | `carrier/carrier.go: SetBastionDest` | Header `Cf-Access-Jump-Destination: host:port` |
| Non-interactive | `cmd/cloudflared/access/carrier.go` | Headers `Cf-Access-Client-Id` / `Cf-Access-Client-Secret` |

The decisive finding is the last-but-two row: **the carrier is an ordinary RFC 6455
WebSocket whose binary frames are an opaque byte stream.** There is no `cloudflared`
-specific framing, no custom sub-protocol, and no dependency on the CLI's process
model. Everything the CLI does that matters can be done by a native client.

### Options considered

| Option | Protocol correctness | App Store | Binary size | Background behaviour | Licence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **A. Native Swift implementation of the Access + carrier protocol** | Exact; derived from the source above and independently re-checkable against a live tunnel | Clean: no helper process, no dynamic code, no private API | ~0 beyond libsodium (see D-004) | Runs in-process; suspends and resumes with the app | Ours | **Chosen** |
| B. Port/embed the `cloudflared` Go modules | Would be exact | Go on iOS needs gomobile; ships a second runtime and its own scheduler; a Go binary cannot be spawned, so it must be linked as a library and rearchitected anyway | Tens of MB | Go runtime threads fight the iOS suspension model | Apache-2.0 (compatible) | Rejected: all the cost of a port, none of the benefit, since the protocol is small |
| C. Cloudflare browser-rendered SSH | Not a native SSH session at all — it is a web terminal | Would be a web view claiming to be a terminal | n/a | n/a | n/a | Rejected as a primary path. Explicitly disallowed by the product brief, and it cannot satisfy "native interactive PTY" |
| D. WARP / Client-to-Tunnel via a Network Extension | Would work | Requires the Packet Tunnel Provider entitlement, which this project does not hold and cannot self-grant | Large | Separate extension process | n/a | Rejected as the only path. May be revisited as an *additional* mode if the entitlement is ever obtained |

### Decision

Implement the protocol natively in Swift (option A):
`Sources/STCloudflare/` contains discovery, JWKS verification, token validation, the
transfer-service login, and the WebSocket carrier. The carrier vends a NIO `Channel`
that speaks `ByteBuffer`, and the SSH layer sits directly on it — so a Cloudflare
session and a plain TCP session run through *identical* SSH code.

### Consequences and revisit triggers

* If Cloudflare changes the carrier framing or the login-helper contract, this breaks.
  Mitigation: the wire behaviour is asserted by tests, and `docs/CLOUDFLARE.md` records
  exactly which observable behaviours we depend on.
* FedRAMP endpoints (`login.fed.cloudflareaccess.org`) are not supported. Adding them
  is a configuration change, not a redesign.
* Revisit if Cloudflare publishes a supported client SDK for this flow.

---

## D-002 — SSH is built on `swift-nio-ssh`, with a documented algorithm gap

**Date:** 2026-09-04 · **Status:** Accepted, with a known limitation

### Context

The SSH implementation must run over *two* different byte streams (TCP and the
Cloudflare WebSocket carrier) and must never involve hand-written cryptography.

### Options considered

| Option | Algorithm coverage | Custom transport | Language | Licence | Maintenance |
| --- | --- | --- | --- | --- | --- |
| **`swift-nio-ssh` 0.15.0** | Ed25519 + ECDSA P-256 host/user keys; curve25519 and ECDH kex; AES-GCM | Native — it is a NIO `ChannelHandler`, so any pipeline works, including one whose base is a WebSocket | Swift | Apache-2.0 | Apple, actively maintained |
| `libssh2` | Full, including RSA SHA-2 | Possible via `libssh2_session_callback_set` send/recv callbacks | C | BSD-3 | Maintained, but needs an embedded TLS backend and a hand-built iOS toolchain |
| `libssh` | Full | Yes | C | LGPL-2.1 — problematic for static linking in a closed-source App Store binary | Maintained |

### Decision

Use `swift-nio-ssh`. Being a NIO handler is not a convenience here, it is the
architectural crux: putting `NIOSSHHandler` on top of a WebSocket frame codec is what
makes "SSH over the Cloudflare carrier" a five-line pipeline rather than a byte-pump
between two runtimes.

### Known limitation — recorded, not hidden

`swift-nio-ssh` 0.15.0 implements **no RSA key type**. Concretely:

* **Host keys** — a server that offers only `ssh-rsa` / `rsa-sha2-*` host keys cannot
  be connected to. Every OpenSSH installation since 6.5 generates an Ed25519 host key by
  default, so this affects servers whose administrator removed the Ed25519 and ECDSA
  host keys.
* **User keys** — RSA private keys cannot be used for authentication. This is the
  bigger gap in practice, because RSA keys remain common.

This is tracked in `PROJECT_STATUS.md` as a blocking item for general availability, and
is surfaced to users as a specific error, never as "connection failed". The planned fix
is to add `rsa-sha2-256` / `rsa-sha2-512` support built on `swift-crypto`'s audited
`_RSA.Signing` primitives — the work is SSH wire encoding, not new cryptography.

---

## D-003 — Terminal geometry, host keys and errors are first-class, not incidental

**Date:** 2026-09-04 · **Status:** Accepted

Three things that mobile SSH clients routinely get wrong are handled deliberately:

1. **A changed host key is a hard stop.** `HostKeyVerifier` distinguishes "never seen"
   (confirm and remember) from "different from what we recorded" (refuse unless the user
   explicitly accepts after seeing both fingerprints). No code path accepts a changed key
   silently.
2. **Window resize is a normal event.** On iPad, Split View and Stage Manager resize the
   terminal constantly. `SSHShellSession.resize(to:)` sends `window-change` on every
   geometry change.
3. **Errors carry a category and a recovery.** `STErrorCategory` drives what the UI
   offers — "sign in to Cloudflare again" versus "check your key" versus "the tunnel is
   offline" — instead of a single failure alert.

---

## D-004 — libsodium supplies `crypto_box`; OpenBSD supplies `bcrypt_pbkdf`

**Date:** 2026-09-04 · **Status:** Accepted

Two cryptographic operations have no equivalent in CryptoKit or `swift-crypto`:

| Operation | Why it is needed | Source | Licence |
| --- | --- | --- | --- |
| `crypto_box_open` (X25519 + XSalsa20-Poly1305) | Cloudflare's login helper seals the token with NaCl `crypto_box`; nothing else can open it | `swift-sodium` 0.11.0 → libsodium | ISC |
| `bcrypt_pbkdf` | The KDF protecting passphrase-encrypted `openssh-key-v1` private keys | OpenBSD `blowfish.c` + `bcrypt_pbkdf.c`, vendored from openssh-portable | BSD-3 / ISC |

Neither is reimplemented. The vendored C is unmodified except for replacing OpenSSH's
build-system headers with a small shim (`st_portability.h`, `st_crypto_api.h`), which
maps SHA-512 onto CommonCrypto and supplies `explicit_bzero`. See
`THIRD_PARTY_NOTICES.md` for exact provenance and `SECURITY.md` for the supply-chain
assessment of the libsodium binary artefact.

---

## D-005 — Liveness is probed by the transport, not by SSH keepalive

**Date:** 2026-09-04 · **Status:** Accepted

`swift-nio-ssh` does not expose the global-request API needed to send
`keepalive@openssh.com`. Rather than fork the library for this, liveness is probed one
layer down:

* **Direct TCP** — Network.framework TCP keepalive (30 s idle, 10 s interval, 3 probes).
* **Cloudflare carrier** — WebSocket ping frames every 30 s; an unanswered ping closes
  the carrier. This additionally stops the edge retiring an idle tunnel.

Both detect the failure that matters on mobile — a peer that vanished without a FIN —
and the carrier's pings also solve an idle-timeout problem SSH keepalive would not.

---

## D-006 — Deployment target is iOS/iPadOS 17

**Date:** 2026-09-04 · **Status:** Accepted

Set against Xcode 26.6 / Swift 6.3 / iOS SDK 26.5, which is the current stable
toolchain on the build machine.

iOS 17 is the floor because the app relies on Swift Concurrency's `AsyncStream`-based
session plumbing, Observation, and SwiftUI APIs that are only usable without back-
deployment shims from 17. Going lower would mean parallel code paths in the session
layer for no meaningful reach: devices below iOS 17 are a small and shrinking share, and
this is a tool for people who administer servers.

Revisit if telemetry (which the app does not currently collect) or user reports show
real demand below 17.
