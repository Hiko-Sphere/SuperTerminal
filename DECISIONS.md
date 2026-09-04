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

---

## D-007 — `swift-nio-ssh` is vendored so RSA can be added

**Date:** 2026-09-05 · **Status:** Accepted, patch in progress

### Context

`swift-nio-ssh` implements no RSA key type at any released version, and none on `main`
either — verified against upstream at commit `3ec2814` (tag `0.15.0`, which is also
`main`'s tip). That leaves two real gaps recorded as `PROJECT_STATUS.md` B-1:

* **User keys.** RSA private keys cannot authenticate. This is the gap that matters in
  practice; RSA keys remain common in the wild and in corporate PKI.
* **Host keys.** A server configured with only RSA host keys cannot be reached at all.
  Rarer, because every default OpenSSH install generates an Ed25519 host key, but real.

Adding a key algorithm means adding cases to internal enums and to the negotiated
algorithm lists. There is no extension point; it cannot be done from outside the module.

### Options considered

| Option | Correctness | Ongoing cost | Verdict |
| --- | --- | --- | --- |
| **Vendor upstream and patch it** | Full control; RSA implemented over `swift-crypto`'s audited `_RSA.Signing`, so no cryptography is written here — only SSH wire encoding | 16 871 lines of security-critical source now ours to keep current | **Chosen** |
| Live without RSA, ship an in-app Ed25519 generator instead | Sidesteps the problem; a user can generate a key and add it to the server in under a minute | None | Rejected as the *only* answer — it does not help someone whose key is managed by their organisation, and it cannot reach an RSA-only host at all. The generator is still worth building. |
| Switch to libssh2 | Full algorithm coverage | Loses the NIO pipeline that makes SSH-over-WebSocket a five-line composition; adds a C toolchain and a TLS backend | Rejected — see D-002 |
| Wait for upstream | Free | Unbounded; no RSA work is visible on `main` | Rejected |

### Decision

Vendor `swift-nio-ssh` at tag `0.15.0` into `Packages/swift-nio-ssh-rsa/` and add
`rsa-sha2-256` and `rsa-sha2-512`.

The vendored copy was committed **unmodified first**, and upstream's own 346 tests were
run against it, so the vendor is demonstrably faithful before any change of ours lands on
top of it. Those tests stay vendored and run in CI.

### The maintenance obligation, stated plainly

This is the most expensive decision in the project. A vendored SSH library that falls
behind upstream is **worse** for security than not supporting RSA — upstream's most recent
commit is itself a security fix ("Limit client auth attempts"). Three things make the cost
survivable, and they are obligations, not conveniences:

1. The change lives in `patches/niossh-rsa.patch`, never as edits merged into the tree.
2. `scripts/update-vendored-niossh.sh` re-fetches upstream and re-applies the patch,
   failing loudly if it no longer applies rather than inviting a hand-merge.
3. Upstream's test suite is vendored and runs in CI, so a re-sync that breaks something is
   caught rather than assumed safe.

**Revisit immediately if upstream adds RSA** — at that point this package should be
deleted and the dependency pointed back at upstream.

### Why the patch is bigger than "add an enum case", and where it has to change

Mapped against the vendored source on 2026-09-05. The root cause is that NIOSSH models a
key's blob identifier and its negotiated algorithm name as **the same string**, which is
true for every algorithm it currently supports and false for RSA under RFC 8332. Those two
roles have to be separated first, and that separation reaches into key exchange and user
authentication:

| Site | Change required |
| --- | --- |
| `NIOSSHPublicKey.swift` | `.rsa` case; `keyPrefix` returns `ssh-rsa`; new `signatureAlgorithmNames` (`rsa-sha2-512`, `rsa-sha2-256`); `knownAlgorithms` extended; verification for each variant |
| `NIOSSHPrivateKey.swift` | `.rsa` case; `sign` takes the algorithm to use; `hostKeyAlgorithms` extended |
| `NIOSSHSignature.swift` | `.rsa(algorithm:bytes:)` case; read and write, keyed on the signature algorithm name rather than the key type |
| `UserAuthSignablePayload.swift:48` | Writes `publicKey.keyPrefix` into the signed blob; RFC 8332 §3.1 requires the *algorithm* name there, so it must be passed in |
| `UserAuthenticationMethod.swift:251` | Must choose a variant, build the payload with that name, and sign with it |
| `SSHMessages.swift:697, :774` | `algorithmName == publicKey.keyPrefix` becomes "this algorithm is valid for this key" |
| `SSHMessages.swift:1376, :1410` | Writes `key.keyPrefix` as the algorithm name; must write the signature algorithm |
| `SSHKeyExchangeStateMachine.swift:292, :605` | Same equality check on the host key, plus the advertised algorithm list |

That is roughly 500 lines across eight files, in the two state machines where a mistake is
either an interop failure or — worse, because it is invisible — accepting a signature that
should have been refused.

**Status: deliberately not attempted in a single sitting.** The map above exists so the
work can be done carefully, with adversarial tests at each site, rather than rushed to fit
a work session. Landing a half-verified change to SSH signature verification would be
worse than the gap it closes.

**Interim mitigation, shipped:** in-app key generation, import and export. Someone whose
only key is RSA can generate an Ed25519 key on the device and add it to the server in
under a minute. That does not help an RSA-only *host*, and it does not help someone whose
key is issued by their organisation — so it mitigates the gap rather than closing it.

### Implementation notes for the patch

Recorded here because they are the parts that are easy to get wrong:

* **RFC 8332 §3**: the public key *blob* identifier stays `ssh-rsa` even when the
  signature algorithm is `rsa-sha2-256` or `rsa-sha2-512`. Only the signature carries the
  new name. Conflating the two is the classic implementation bug, and NIOSSH's
  `keyPrefix` currently serves as both the blob identifier and the negotiation name — so
  the two roles have to be separated.
* The public key blob is `string "ssh-rsa"`, `mpint e`, `mpint n` — note e before n, the
  reverse of most other encodings.
* The signature blob is PKCS#1 v1.5, unsigned big-endian, left-padded to the modulus
  length. `swift-crypto`'s `_RSA.Signing` with `.insecurePKCS1v1_5` provides it; the name
  refers to PKCS#1 v1.5 versus PSS, and v1.5 is what RFC 8332 specifies.
* `ssh-rsa` with SHA-1 is **not** implemented and will not be. OpenSSH disabled it by
  default in 8.8 because SHA-1 collisions are practical; supporting it would mean shipping
  a downgrade a server could ask for.
