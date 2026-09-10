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

**Addendum (2026-09-06) — file protection is asked for only on iOS.** The known-hosts
file is written with `.completeFileProtection` on iOS. On macOS, where the package's own
tests run, that option makes the atomic write fail with `EPERM` ("Creating a temporary
file via mktemp failed") — reproduced with a five-line script on this volume — so
`KnownHostsRemoveAllTests.fileStoreForgetsOnDisk` had been failing on the host. The option
is now requested under `#if os(iOS)` only; the app's behaviour is unchanged, and the
package suite is green again on the host (172 tests in 25 suites).

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

**Status: implemented and verified.** `patches/niossh-rsa.patch` — 788 lines across the
ten files above — applies cleanly to pristine upstream at tag `0.15.0`. Upstream's suite
passes (347 tests), and the change is proved against OpenSSH rather than against itself:
an RSA user key authenticates to a real `sshd`, a server offering only an RSA host key is
reachable, `ssh-keygen` agrees on the fingerprint, and five adversarial tests check that
the relaxed algorithm-name comparison did not become no comparison.

One design choice worth stating, because it is a deliberate restriction rather than an
oversight: a private key used as a **host** key advertises only `rsa-sha2-512`.
`sign(digest:)` has no way to learn which variant a peer negotiated, so offering both
would let a peer choose SHA-256 and then receive a SHA-512 signature. Advertising one
makes the negotiated and signing algorithms identical by construction. Client-side user
authentication is unaffected: it chooses and declares its own algorithm, and verification
accepts either.

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


## D-008 · A session is displayed by one window at a time

**Decision.** Sessions are shared by the app, but exactly one window *displays* each one.
The window holding the claim draws the grid and reports its geometry; another window that
selects the same session takes the claim, and the first shows "Open in another window"
with a way to take it back. Ownership follows the window's selection, not any view's
lifetime.

**Why.** A terminal's size is a property of the connection, not of a view: the remote
program is told how many columns and rows it has, and `SIGWINCH` is a real event with real
consequences for a full-screen program like `vim`. Two windows showing one session would
each report their own geometry and resize the far end against each other for as long as
both were open.

Two alternatives were rejected. Letting both windows draw and having the last resize win
produces a terminal that visibly fights itself, which is worse than a clear message.
Refusing to select a session another window holds is simpler but strands a user who has
lost track of which window has what — moving it is recoverable, refusing is not.

**Why selection rather than view lifetime.** The first implementation claimed in
`onAppear` and released in `onDisappear`. That looked equivalent and was not: presenting a
sheet over the terminal made the view disappear, releasing the claim, and dismissing the
sheet did not reliably bring it back — so the window told the user their session was open
somewhere else when it was not. A split view also *reuses* the detail view when the
selection changes, so `onAppear` never fired for the newly selected session. Deriving the
claim from the window's selection cannot drift out of sync with what the window is showing.

**Reversible.** Yes. Removing the claim map and letting every window draw every session is
a small change; the resize fight is the reason not to.

## D-009 · The on-screen key row is a preference, not a layout consequence

**Decision.** The accessory key row is shown according to a persisted setting that defaults
to on, on every device.

**Why.** It was previously shown when the horizontal size class was compact. An iPhone is
always compact so the row was always there, and a full-screen iPad never had it — leaving
no way to send `^C`, Esc, Tab or the arrows, none of which the software keyboard offers. An
iPad is as likely to be used without a hardware keyboard as a phone is.

**Rejected: detecting the hardware keyboard.** `GCKeyboard.coalesced` is the documented way
to ask, and hiding the row automatically when a Magic Keyboard is attached would be tidier.
It was implemented and then removed: the simulator reports a keyboard whether or not one is
connected, so the behaviour could not be verified here, and shipping automatic behaviour
that cannot be tested is worse than a predictable setting a user changes once.


## D-010 · Only network failures are retried automatically

**Decision.** Automatic reconnection retries exactly two categories: `network` and
`tunnel`. Everything else stops and waits for a person.

**Why.** The hard part of reconnection is not the backoff, it is knowing what may be
retried. Repeating a rejected password is how an account gets locked out and how an Access
policy starts rate-limiting. Quietly retrying past a changed host key or a failed
certificate check is worse still: those checks are the only thing the connection's security
rests on, and a user who watches one fail and then succeed learns to read it as flakiness.
A key-exchange or MAC failure is ambiguous enough — it may be a coincidence, it may be
someone interfering — that it is not something to paper over either.

The list is exhaustive rather than a default, and a test asserts that every category has a
considered answer, so adding one forces the question rather than inheriting "retry".

**Two categories were corrected as part of this.** "The server closed the connection
before the SSH session was established" and "the handshake did not complete in time" were
both `sshTransport`, grouped with cryptographic failures. Neither is one: nothing SSH
promises was broken, the connection simply went away or never answered. They are the two
most common ways a mobile connection dies — a hand-off between Wi-Fi and cellular, a tunnel
whose origin is restarting, a lift — so with the old categories the feature would have
retried almost nothing. They are `network` now.

**Reversible.** Yes, and it is one line per category. The reasoning is what matters, so it
is written next to the code rather than only here.

## D-011 · Reconnecting keeps the scrollback, and says the shell is new

**Decision.** A reconnection does not clear the terminal. The buffer is kept and a dim rule
is drawn where the break was, labelled with the app's own name.

**Why.** The scrollback is why the user is looking: it holds the command that was running
when the link went and whatever it had printed. Clearing it to make the reconnection look
tidy destroys the only record of what happened.

The label is not decoration. The shell on the other side is a **new** one — a different
working directory, nothing running, none of the environment that was set — and a terminal
that reconnects silently has handed the user a different machine state with no sign that
anything changed. That is how someone runs a command in the place they did not mean to. The
app's name is in the rule so the line can never be read as something the server said.


## D-012 · Sessions are reopened, never "restored", and the scrollback is not kept

**Decision.** After a relaunch the app offers to reopen the connections that were open, and
says in the offer that these are new sessions. The scrollback is not written to disk.

**Why "reopened".** A live SSH session cannot survive the process dying. The socket is
gone, the shell is gone, and whatever was running went with it. An app that presented a
fresh connection as a restored session would be making the same false claim that D-011
guards against inside a running session — with the added risk that someone picks up where
they think they left off, in a directory they are not in.

**Why not the scrollback.** It is the same asset as command history: every command and
everything the server printed back, including whatever was typed on a command line that
should not have been. It is far larger than history and there is no bound on it that means
anything. The app refuses to write command history to disk unless explicitly asked (T-11);
writing the entire buffer instead would make that refusal meaningless.

**Why an offer rather than reconnecting on launch.** Opening an SSH connection is not a
local act. It creates login records, it can trigger MFA, and with a biometric-gated key it
puts a Face ID prompt in front of someone who only opened the app to look something up.
One tap is cheap; a connection nobody asked for is not.

**Reversible.** Yes. Reconnecting automatically is a setting away, and keeping the
scrollback would be a store much like the history one — with the same argument to have
first.


## D-013 · chacha20-poly1305@openssh.com needed two more vendored changes

**Decision.** Add `chacha20-poly1305@openssh.com` as a transport protection scheme, built
from libsodium's ChaCha20 and Poly1305 primitives, and make two small changes to the
vendored `swift-nio-ssh` to allow it: RFC 4253 § 7.2 key extension in the key exchange, and
a `sequenceNumber` parameter on `decryptFirstBlock`.

**Why the cipher.** OpenSSH has listed it first in its defaults since 6.9, hardening guides
narrow `Ciphers` to it alone, and a server so configured was unreachable no matter how
modern. AES-GCM stays preferred: every iPhone has AES in hardware.

**Why it could not be a plugin like AES-CTR.** Two things upstream never needed:

* The cipher wants 64 bytes of key. Every key generator in the vendored key exchange took a
  prefix of a *single* digest and asserted the request fitted — fine for AES-256 under
  SHA-256, impossible for 64. RFC 4253 § 7.2 says what to do (`K2 = HASH(K ‖ H ‖ K1)`, and
  so on) and the generators now do it. Nothing else changes: a request that fits one digest
  produces the byte-identical key it did before.
* The length field is encrypted under a nonce derived from the packet sequence number.
  `decryptFirstBlock` — the call that has to reveal the length — was not told the sequence
  number; only the second half of the read was. OpenSSH's own `cipher_get_length` takes
  `seqnr` for exactly this reason. The parameter is threaded through; the parser already
  passes the same value to both halves, so the scheme needs no stored state between them.

**Rejected: swift-crypto's `ChaChaPoly`.** It is RFC 8439's AEAD. OpenSSH's construction is
not: two keys, a separately encrypted length, and a one-time Poly1305 key taken from the
first block of keystream. The sealed-box API cannot express it. libsodium exposes the stream
cipher and the authenticator separately, is already shipped for the Cloudflare login flow,
and its constant-time `crypto_verify_16` is used for the tag.

**Verification.** Not a unit test with vectors I typed in: a real OpenSSH server configured
with `Ciphers chacha20-poly1305@openssh.com` and nothing else accepts the connection, and a
400 KB burst stays in sync in both directions. A mistake in the key order, the nonce, either
counter, the tag's coverage or the padding fails that handshake outright. The vendored suite
remains green (349, two of them new) and the patch gate in CI still reproduces the tree.

**Reversible.** Yes. Deleting the scheme and the two vendored changes returns to the
previous behaviour; the key-extension change is dormant for every other cipher.


## D-014 · Localization keys come from the compiler, never from the source text

**Decision.** The Chinese String Catalogs are keyed on what the Swift compiler emits, read
from `.stringsdata` after a build with `SWIFT_EMIT_LOC_STRINGS=YES`. `scripts/localization-audit.sh`
compares that list against the catalogs on every CI run and fails the build if anything a
user can read is untranslated.

**Why not read the source.** SwiftUI turns `Text("Delete \(name)?")` into the key
`Delete %@?` — the interpolation becomes a format specifier before it ever reaches a lookup.
A catalog keyed on the source text matches nothing, and the failure is silent: the app
compiles, ships, and shows English. Thirty-six of the translations produced for this project
arrived carrying raw `\(identity.displayName)`, which would have been printed on screen
verbatim. Each was mapped back to the specifier its expression became, matched by expression
text rather than by position so that a reordered argument produces `%1$@`/`%2$@` instead of
a silently swapped one, and the placeholder multisets are asserted equal on both sides.

**Why a CI gate rather than a checklist.** Localization is the rare kind of regression that
nothing catches: a new `Text("Add server")` compiles, passes every test, and quietly shows
English to someone who chose Chinese. There is no crash and no red test — so the gate has to
be built deliberately or it does not exist.

**What is deliberately not translated.** Technical identifiers a user copies or compares
(`user@host:port`, fingerprints, algorithm names, `ssh-keygen` command lines), key-cap
labels (`esc`, `tab`, the arrows — English on a Chinese keyboard too), `TERM` values, wire
format keys, log subsystem names, `underlyingDescription` diagnostics, and anything
serialised or compared. Two traps in particular:

* **`UIKeyCommand(input:)`.** Translating `input: "k"` would silently unbind ⌘K.
* **Enum raw values that are both stored and displayed.** Translating one changes what is
  written to disk, so a device that changes language cannot read back its own data. Where
  one was found, the raw value was left alone and a separate `displayName` added.

**Terminal output is never translated.** It is a remote program's bytes, often read to
compare against documentation or to paste elsewhere. A UI test asserts this by running the
app in Chinese and checking that remote output arrives unchanged.

**Traditional Chinese is translated, not converted.** A character converter over Simplified
leaves mainland vocabulary behind and reads as foreign in Taiwan. The two were produced
independently against a 117-term glossary fixed before any string was translated, and a UI
test asserts the Traditional build shows 連線 and contains no 连接 — the assertion that
catches a converted catalog.

**Security copy was reviewed as its own batch**, on the rule that a Chinese reader must not
come away calmer than an English one. Host key changes, trust prompts and paste warnings are
in that set. Recorded here because a mistranslation there is a security defect, not a
cosmetic one.

## D-015 · iCloud sync is opt-in, per key, and never silent about disagreement

**Off until switched on, and the transport does not exist until then.** `CKSyncEngine`
registers for push and talks to the container the moment it is created, so
`SyncCoordinator` builds the CloudKit transport when the switch goes on and drops it when
the switch goes off. A user who never opens the setting never touches CloudKit.

**What syncs is a list, not "everything".** Hosts, key metadata, snippets and trusted host
keys. Not passwords (each device asks again), not Access tokens (each device signs in),
not command history, restoration state or diagnostics. The list is short so the Privacy
Policy can be exact.

**A private key syncs only if the user says so for that key.** The choice is made when the
key is created or imported, and it is refused — not silently downgraded — when the key is
also biometric-protected, because Apple forbids access control on synchronisable items.
A record that arrives without its secret is shown as "not on this device" rather than
failing at connection time.

**Host-key disagreements are held.** Last-writer-wins is right for a renamed connection
and wrong for a host key: a newer record must not be able to replace a key this device
already trusts. Such a record is kept aside, the connection continues with the local key,
and Settings shows the two so the user can decide. Nothing in the sync path can accept a
changed host key on its own.

**Payload bytes are canonical.** Conflict detection compares this device's encoding of a
key with another device's, so the adapter encodes with sorted keys. The first test of this
passed in one simulator clone and failed in the other — Foundation's key order without
`.sortedKeys` varies per process — which is why the sort is documented as load-bearing.

**Not verified live, and recorded as such.** Without a development team the simulator
build carries no entitlements, so CloudKit cannot be exercised (B-4). The engine is
verified against an in-memory transport and the record mapping is unit-tested; the claim
"sync works" is not made anywhere a user can read it.

## D-016 · The legal texts ship in the bundle and gate first launch

**Three documents, three languages, one source.** Terms of Use, Privacy Policy and User
Notice live in `App/Resources/Legal/` as Markdown, one file per language, rendered by a
parser written for exactly what they contain. They were drafted, judged and adversarially
reviewed against the code before the first screen was built; every reviewer finding that
described a claim the app did not honour was fixed in the app or in the text — never by
softening the text into vagueness.

**Consent is shown once per document version.** `LegalDocument.currentVersion` is bumped
when a document changes in substance; a lower `acceptedTermsVersion` shows the screen
again. UI-test runs pre-accept unless they ask to see the screen, so one gate does not
block every other test.

**Placeholders are visible, not hidden.** Effective date, legal name, contact addresses
and governing law are the owner's to supply (B-5). They ship in square brackets rather than
as invented values.

**The third-party notices are the same file twice, checked.** Apache-2.0 requires the
notices to reach the user, so `THIRD_PARTY_NOTICES.md` is copied into the bundle and CI
fails if the copy drifts from the repository file.

**No contact channel in the texts (2026-09-06).** The owner asked that the app leave no
contact details. The notice, privacy policy and terms no longer have a contact section,
the privacy policy no longer describes what happens to an email sent to the developer,
and the remaining placeholders are the effective date, the developer's legal name, and
the governing law and venue. The texts say what the app does, not whom to write to; the
consent version went to 2 so that existing users see the changed texts. App Store
Connect's own support URL is metadata outside the app and is not affected by this.

## D-017 · Service tokens are a per-connection, per-device credential

**They exist because the carrier already honoured them.** The Access carrier sent the
`Cf-Access-Client-Id` / `Cf-Access-Client-Secret` headers and the vault reserved a Keychain
service for them, but nothing above that layer could set one — dead storage that the
Security table described as if it were live. Wiring the editor, the vault and the
session's credential resolution made the table true rather than deleting the row.

**Per device, on purpose.** A service token is long-lived machine access. It is written
`WhenUnlockedThisDeviceOnly`, excluded from iCloud sync, and deleted with its connection —
as is a saved password, which previously outlived the host it belonged to. A synced record
that says "service token" produces a typed credential error naming what to do, not a
silent fall-back to the browser login.

**AutoFill is told to stay out.** iOS offered to save the service-token secret — and would
the SSH password and key passphrases — into iCloud Keychain passwords, which sync. Every
secure field opts out; the UI test asserts the system sheet never appears.

**Known-host deletions are tombstoned too, and a re-trusted host wins.** Hosts and
snippets record their tombstones inside their stores; the known-hosts store lives in the
package and knows nothing about sync, so the Known hosts screen reports a deletion to the
coordinator. When a host is trusted again after a deletion, the adapter forgets the
tombstone rather than pushing a deletion alongside the live record — found by asking what
"delete a host key on one device" should mean on the other, and answering with a test.

## D-018 · Keyboard and pointer follow xterm and iPadOS, in that order

**The remote host gets what xterm would send.** Modified arrows, Home/End, Insert/Delete,
Page and function keys carry their modifiers in the parameter form (`CSI 1;5C`), Control
produces control bytes, Option is Meta, Control-Backspace is BS and Option-Backspace is
Meta-DEL. Command never reaches the host: it belongs to the app and the system. The
mapping is a pure function with a test per rule, because a `UIKey` cannot be built in a
test and a mapping that cannot be tested drifts.

**The pointer does what every iPadOS text surface does — unless a program asked for it.**
A scroll wheel or trackpad scrolls the history; a secondary click shows the edit menu; a
middle click pastes; a click-drag selects; the pointer is a beam. When the remote program
is tracking the mouse, each of those is reported to it instead (wheel, right and middle
buttons, drag), because `less`, `tmux` and `htop` own the pointer while they run. The
recognisers are configured so scroll events and touches never compete: the wheel
recogniser takes no touches at all, and the drag recogniser takes only the indirect
pointer.
The two click recognisers take only the indirect pointer as well, and this was learnt
the hard way: a button mask is not a pointer check. With `.button(3)` as the only
condition, a synthesised direct tap satisfied the middle-click recogniser, and every
live-terminal UI test that tapped the terminal then pasted whatever the previous test had
copied — the prompt's own glyphs, which the shell tried to run as a command. A finger is
never a secondary or middle click; the unit tests now assert the touch types.

**Verified as configuration, not as gestures.** XCUITest on iOS cannot move a mouse
wheel or send a secondary click, so the tests assert the recognisers and interactions
that make those work; the hardware checklist in `docs/RELEASE.md` names the manual
checks. Hardware-keyboard shortcuts are driven for real through `typeKey`.

**Shortcuts are SwiftUI shortcut buttons in the shell and `UIKeyCommand`s on the terminal.**
UI tests that type real keys showed a hardware ⌘N and ⌘K never reaching SwiftUI `Commands` on
either device (an iPhone has no menu bar at all), never reaching `keyCommands` on the
SwiftUI-wrapped application delegate, and — inserting the same key equivalents into the
system menu — crashing the app at launch. One table, `AppShortcut`, is exposed as hidden
SwiftUI `.keyboardShortcut` buttons in the root view, which is where SwiftUI dispatches a
hardware key when nothing of ours is first responder, and as `UIKeyCommand`s by the terminal
view while it has the keyboard; both route to one `AppShortcutRouter`, so a key cannot fire
twice, and each is disabled when it does not apply because a listed shortcut that does
nothing reads as a broken app. The shortcut buttons keep their titles — that is what the
⌘-hold overlay lists — and are `hidden()`, the one concealment that keeps them out of the
accessibility tree: zero size and zero opacity, `accessibilityHidden` on each button, and
an ignored, hidden container all left eighteen zero-size labelled buttons answering
accessibility queries (a dump of the tree showed them), so "Command Palette…" matched
twice — the real menu item and the shortcut — which the live-terminal palette UI test
caught; hidden, the buttons still fire, measured with the keyboard suite. The Session
menu's own palette item no longer carries ⌘K: with the shell's shortcut and the terminal's
key command, a third registration made two SwiftUI ⌘K shortcuts compete in one hierarchy.
The palette's query field is a UIKit text field with Escape and the arrows as its own priority
key commands, because a SwiftUI `TextField` with `onKeyPress` never saw them.

**A hidden first responder is not a delivery mechanism — measured.** The first design was a
zero-size `UIView` that made itself first responder whenever nothing else was, so that the
shortcuts had a responder to land on. On the iPad simulator (iOS 26.5) with a hardware
keyboard connected, one UI test — open Settings, scroll the form — aborted the app inside
UIKit's focus engine: `Invalid parameter not satisfying: parentEnvironment != nil` in
`_UIFocusContainerGuideFallbackItemsContainer`, reached from `_reevaluateLockedEnvironments`
after a commit. Apple tracks it as r.154431813 (forum thread 805681; FB21878739,
FB24089896) and has not fixed it; the only workaround in circulation swizzles
`updateFocusIfNeeded` into a no-op, which also ends keyboard focus navigation and is not
acceptable. Measured over the same test, interleaving runs of the same build with the view
present and with it left out by a debug launch switch, and against the previous commit:
five aborts in eighteen runs with the view, none in seventeen without it. The persisted log
showed the view taking first responder exactly once, two seconds after launch, and never
again before the abort — it is the *presence* of a foreign first responder the focus
system locks to, not any churn, that exposes the bug. The view is gone; the shortcuts moved
to where SwiftUI already dispatches them.

**What the instrument can and cannot show, measured.** On this simulator the first
hardware key after launch is sometimes dropped before the app sees it; the tests read a
debug probe of shortcuts performed to tell that from a key the app ignored, retry once,
and record it. Escape and Return sent while a text field is first responder never arrive
— measured, while the field's arrow key commands do arrive and ⌘ keys arrive whatever is
focused — so those two cases are strict expected failures that name the instrument and
will flip to failures the day it delivers, and the hardware checklist carries them. (⌘K
with the search field focused was a third such case while the shortcuts lived on the
hidden first-responder view; as a SwiftUI shortcut it arrives, and the test now asserts it.)

## D-019 · The server is asked what it is, on its own channel, and the user can overrule it

**Detection is a second channel, never keystrokes.** After the shell is up, the session
opens an exec channel on the same connection and runs `uname -s`; when that cannot run —
Windows OpenSSH has no `uname`, and its shell says so — it runs `cmd /c ver`. The answer is
read by a pure function with a test per real string (Darwin, Linux, the BSDs, `ver`'s
"Microsoft Windows [Version …]", MSYS and Cygwin kernel names, and both Windows shells'
complaints, which must not be mistaken for a kernel). Nothing is typed into the user's
shell, the prompt is never delayed, and a server that answers with nothing usable leaves
the record as it was rather than overwriting it with a guess.

**Two fields, one answer.** `detectedPlatform` is what the server last said;
`platformOverride` is what the user set in the editor; `effectivePlatform` is the override
if there is one, else the detection. Both are optional in the record so that a record
written before the fields existed decodes, and both sync with the host, because they
describe the server rather than the device. Recording a detection that matches what is
already stored writes nothing, so a connection that reports the same platform every time
neither touches the store nor wakes sync.

**What it is for.** The row shows the platform's symbol and name once it is known, and the
editor's picker corrects a wrong answer or names a server that will not say. The assistant
(D-020) is told which platform a command is meant for, and the VNC and Siri work that
follows reads the same field. The live proof is the test server itself: this Mac's OpenSSH
reports Darwin, and the UI test watches the row come to say macOS; Linux and Windows
detection are proven by the parser against their real output and are listed as hardware
checks until a machine of each kind has been connected to.
## D-020 · The assistant is a separate screen, sends only what it shows you, and is honest about where it runs

**Two engines, one contract.** On a device that has Apple Intelligence, the assistant uses
the on-device Foundation Models framework: nothing leaves the device and no account is
needed. Everywhere else — this development Mac reports `deviceNotEligible` — it uses a
provider the user configures in Settings: an OpenAI-compatible chat-completions endpoint
(URL, model name) with a key the user pastes, stored in the Keychain and never in any
record, log or sync payload. Neither engine is faked: with no eligible device and no
provider configured, the assistant says exactly that and offers Settings.

**It never acts on its own.** The assistant answers three kinds of question — "how do I
… on this server", "explain this output", "what went wrong here" — and its answers are
text and suggested commands. A suggested command can be inserted into the terminal, where
it sits on the prompt for the user to read and run or delete; the assistant never sends a
newline. That is the same rule snippets follow (D-011).

**What it is told is shown first.** The request carries the server's platform (D-019),
the shell's last command, and the terminal text the user chose — the selection, or the
last screen — and the sheet shows that context before anything is sent. Terminal text
can contain secrets; the choice is the user's each time, and the privacy policy says so.

**Verified how.** The prompt builder and the response parser are pure and unit-tested;
the provider client is tested against a local HTTP server that speaks the same protocol,
including streamed answers and error bodies; a live run against a real provider needs a
key the owner supplies (B-6) and is a hardware check until then. The on-device engine can
only be verified on an eligible device (B-4/B-6).

**Where it lives.** The Session menu, ⌘⇧A from the shell or the terminal, and the same
sheet for both. A suggested command is one line by construction — the reply parser takes
lines inside fences, not fences — so "Insert" can never submit anything. Provider settings
are a base URL, a model name and a key; the key field shows only that a key is stored, and
"Remove key" is the only way it leaves. On this development Mac the system reports
`deviceNotEligible` for the on-device model and no key is stored, so the UI test proves the
honest state: the sheet says why it cannot answer and offers Settings.

**A model that says it is there and then is not.** The simulator on a Mac whose host runs
Apple Intelligence reports the on-device model *available* — `modelmanagerd` finds the
3B instruct assets and allows inference — and the request then fails with a
`GenerationError` the framework does not explain (code −1). The coordinator remembers an
on-device failure for the rest of the run, names it in the unavailable reason, and — when
the user configured a provider — asks the provider the same question instead of failing
the same way on every question. Every `GenerationError` case is named in the message with
the framework's own explanation; nothing is reduced to "an error occurred".


## D-021 · Siri and Shortcuts go through the same door as a tap

**App Intents, not a URL scheme.** "Connect to <server> in ApexTerminal" is an App Intent
with a connection entity whose query reads the host store, so Siri offers the user's own
connection names and nothing else about them (the entity carries the name and the row's
subtitle, never a credential). Performing it opens the app and a session through
`SessionManager.open`, the same path as tapping the row: host-key checks, credentials,
prompts — Siri is a way in, not a way around. A session already open to that server is
shown rather than doubled. "Disconnect all sessions" closes every session and says how
many. The intents reach the live container through a handle the app installs at launch.
App Intents' own dependency registry was the first design and was measured out: it takes
one registration per type per process, offers no lookup, its property wrapper is not
visible from a test bundle, and it asserted inside the framework when an intent ran under
test — taking ninety unrelated tests down with it. A handle the app owns is one line, and
every intent can be run in a test. A session opened before any window exists is parked on
the container and consumed by the first root view to appear.

**Verified how.** Unit tests run the intents against a container on temporary stores: the
query's matching and what an entity exposes, that Connect opens exactly one session and
records the connection, and Disconnect All's dialog for zero and one sessions. Siri's
phrase recognition and the Shortcuts listing are checked on a device (`docs/RELEASE.md`);
the simulator cannot speak.

## D-022 · VNC is a second kind of session over the same connections, and the protocol is written, not wrapped

**Scope.** A VNC session shows a remote desktop and drives it with touch, hardware
keyboard and pointer. It is a real RFB client (RFB 3.3/3.7/3.8 handshake; security types
None and VNC Authentication — *extended by D-031 to Apple's type 30 and VeNCrypt's
non-TLS sub-types; VeNCrypt's own TLS is still not implemented, and the SSH or Cloudflare
route is the encrypted path*; ClientInit/
ServerInit; FramebufferUpdateRequest with incremental updates; encodings Raw, CopyRect,
RRE, Hextile and ZRLE with the DesktopSize pseudo-encoding; PointerEvent,
KeyEvent and ClientCutText), written in Swift on SwiftNIO in the package as `STVNC`, with
the pixel format negotiated to 32-bit true colour so decoding is a copy.

**Transport.** Direct TCP to the server, or through an existing SSH connection with a
`direct-tcpip` channel (the way `ssh -L` works) so that a desktop behind the same bastion
or Cloudflare tunnel as the shell needs no extra exposure. VNC Authentication's DES
challenge is weak by design and RFB carries the framebuffer in the clear; the app says so
in the editor. The SSH route is the default and the encrypted one; a direct connection is
for a network the user trusts.

**Input.** A tap is a click, a drag moves the pointer, a long press then drag drags with
the button held, two-finger tap is a right click, two-finger pan is a scroll wheel, pinch
zooms the view. On iPad a mouse or trackpad drives the pointer directly, with the same
recogniser rules as the terminal (D-018): pointer touches only. Hardware keys go through
one table to X11 keysyms; the on-screen keyboard types through `UIKeyInput`.

**Verified how.** The protocol is exercised against LibVNCServer — the reference server
library behind x11vnc and many others — built from Homebrew and run locally with a known
pattern, so every encoding and both auth types are checked against a real server. macOS
Screen Sharing and a Linux desktop are hardware checks for the owner.

**Cursor.** The Cursor pseudo-encoding is deliberately not requested. With it the server
stops painting its pointer into the framebuffer and expects the client to draw one at a
position the server never reports; a touch user, with no local pointer, would then never
see where they are. The server keeps drawing its own cursor, and on iPad the local pointer
is hidden over the screen so there is exactly one.

**What touch means.** Tap: click. Drag: the pointer moves, nothing held — a hover.
Touch and hold, then drag: the button is held. Two fingers tapped: right click. Two fingers
moved: the wheel, at fit-to-screen; once pinched in, two fingers pan the view instead,
because that is what two fingers mean everywhere else on the platform and a gesture
cannot mean both. A key row below the screen carries what a touch keyboard cannot type —
Escape, Tab, arrows, Home, End, paging, Delete — and latches Ctrl, Alt, Shift and Super
for the next key. ⌘ combinations stay with the app unless the user turns on "Send ⌘ to
Remote", in which case ⌘ is Super.

**What the remote may not do.** Text it puts on its clipboard is *offered* in a banner and
copied only when the user says so; a remote desktop must not be able to write the local
clipboard. The screen is never stored.

**Verified how.** In the package, every encoding — ZRLE, Hextile, RRE, Raw, CopyRect —
decodes LibVNCServer's known pattern pixel for pixel; the toggling square arrives as
incremental updates; VNC Authentication succeeds with the right password and is refused
with the wrong one or none; pointer, key and clipboard events arrive in the server's own
log; the server going away ends the stream. Hand-built rectangles pin the corner cases a
server happens not to send. In the app, a UI run opens the seeded connection's screen
through the SSH connection, reads the desktop's name and size decoded from the server,
taps, and finds the press and release in the server's log, then the key row's Escape and a
Ctrl-latched Tab in order. macOS Screen Sharing and a Linux desktop are hardware checks.

## D-023 · The app lock is the app's own passcode, with biometrics in front of it

**Why a passcode of its own.** The device passcode already protects the device; what a
terminal app adds is a second door in front of SSH keys, saved passwords and open
sessions when a phone is handed over unlocked. So the lock is an app passcode, and Face ID
or Touch ID stands in front of it when the user allows — the way banking apps do it, and
for the same reason: biometrics are convenient, the passcode is the thing that is proven.
`LAContext` is used with the biometrics-only policy; the app never sees biometric data and
learns only whether the check passed. Cancelling the prompt falls back to the passcode
field, and the prompt is offered once per lock, so a cancelled prompt does not come
straight back.

**What is stored.** Never the passcode: a 16-byte salt and a 200 000-round PBKDF2-HMAC-SHA256
derivation of it, in the Keychain, this device only, compared in constant time. The setting
alone locks nothing — a record in the Keychain is needed too — so "Delete all data" removes
the lock with everything else and cannot lock anyone out of an empty app.

**When it engages.** At launch when on, and when the app returns after the grace the user
chose (immediately, 1, 5 or 15 minutes away). Wrong guesses are slowed down — thirty seconds
after five, a minute after eight, five minutes after ten — and never punished by deleting
anything: the keys behind the lock are the owner's, and a child at the screen is not an
attacker. Turning the lock off, or changing the passcode, asks for the current passcode
first; Settings being open is not proof the owner is holding the device. "Locked" is
defined as engaged *and still on*: turning the lock off — in Settings, or by deleting all
data — releases a lock that is showing, rather than leaving a screen nothing can unlock,
and turning it on clears any engagement held from before, so the screen the user is on
is never locked by the act of enabling. (Both found by a seeded UI run that inherited the
previous run's passcode: the lock read "engaged" at launch, the seeding cleared the
passcode, and enabling it again re-armed the stale engagement.)

**Where it is drawn.** In a `UIWindow` of its own above the scene's window, one per scene
on iPad, rather than in the view tree — a presented sheet would otherwise stay visible
above a view-tree overlay, and a `fullScreenCover` cannot be presented while a sheet is up.
The window is modal to accessibility, so nothing behind it is reachable by any means.

**Verified how.** Unit tests run the lock with a biometric check that answers what the test
says and a clock the test moves: the record derivation and its constant-time match, the
policy and backoff tables, the grace period, five wrong guesses costing thirty seconds with
the right passcode refused during them, biometrics passing and failing and being off, and
the setting-without-record case. A UI run sets a passcode in Settings, sees a mismatch
refused, relaunches the app keeping its state and finds the lock in front of everything,
gets a wrong passcode refused and the right one accepted, then leaves and returns and is
locked again. Face ID itself is a device check.

## D-024 · Blank means "ask", and the hostname field takes what people paste

**The port is the user's.** It was hidden for Cloudflare connections and fixed at 443
inside the code; the field is now always there, for both transports, and blank means the
transport's default — 22 for a direct connection, 443 for the Cloudflare edge, which also
publishes on 2053, 2083, 2087, 2096 and 8443. For a Cloudflare connection the port is the
edge's, not the origin's: the tunnel's ingress decides where SSH is, and nothing typed here
can change that. Records from before carried the SSH default on Cloudflare connections,
where the field meant nothing; they are rewritten to 443 on load, which no Cloudflare
hostname can contradict.

**A pasted address is taken apart.** `ssh.example.com:443` copied from a dashboard,
`ssh://deploy@build.example.com:2222/` copied from a terminal, `[2001:db8::1]:22` — each
used to be treated as the hostname itself and failed name resolution with a message that
blamed the network. `HostAddress.parse` keeps the host, moves a port into a blank port
field and a user name into a blank user-name field, and drops scheme, path, query and any
password. It is pure and tested on its own.

**A blank user name is asked for.** SSH cannot open without one, so a connection saved
without a user name asks for it when it opens — a plain field, not a secret one — and
keeps the answer for that attempt only. Saving one is a matter of editing the connection.

**No credential chosen means "let the server say".** The connection offers `none` first,
which is how a server discloses the methods it takes, and the credential chain then asks
the person for a password if — and only if — `password` is among them. A key-only server
is never asked; a wrong password is not a loop of prompts, because the chain asks once
per attempt; declining ends the attempt with a message that says so. NIOSSH has no
keyboard-interactive, so a server that takes only that method still fails honestly.

**Verified how.** `HostAddressTests` cover the parser's shapes and refusals.
`SSHCredentialChainTests` drive the chain call by call, as the SSH handler does: none
first, the typed password offered once, a key-only server never asked, a cancelled prompt
failing cleanly, stored credentials unchanged. A UI run edits the seeded connection to a
hostname carrying its port, a blank port field and a blank user name, connects, answers
the user-name prompt, and reaches the shell over the real OpenSSH server. Password
authentication against a real server stays a live check: the harness's sshd takes keys only.

## D-025 · The terminal keeps the keyboard, follows the session on screen, and takes a wheel

Reported from an iPad with a Magic Keyboard: neither the keyboard nor the pointer could
drive the terminal. Every one of these was invisible to the suite, and each has a reason
it could only appear on a device or on an iPad.

**First-responder status is taken and never handed back.** `TerminalInputView` became
first responder once, when it entered the window, and again on a tap. Nothing re-acquired
it after a sheet, the command palette, the find bar, the sidebar's search field or the app
lock — UIKit does not restore the previous responder when a presentation ends. With a
software keyboard that is self-correcting: the keyboard disappears, which tells the user
to tap the terminal. With a hardware keyboard there is nothing to disappear and nothing
worth tapping, so typing just stops. Connecting to a new host makes it near-certain,
because the unknown-host-key sheet is the first thing that happens. The terminal now says
whether it should hold the keyboard — `wantsKeyboard`, false while anything covers it —
and takes it back itself, which is the discipline the VNC screen already used (D-022).

**One terminal view, many sessions.** On iPad the detail column keeps one SwiftUI identity
for every session, so switching sessions does not build a new view: `makeUIView` runs once
and the callbacks it installed keep pointing at the session the view was created with,
while `updateUIView` draws the new one. The grid showed session B and every keystroke went
to session A's shell. The coordinator now remembers which session it is bound to and
rebinds when it changes. The compact layout was never affected, which is why the iPhone
suite never saw it.

**A wheel is a whole gesture.** iPadOS delivers one mouse-wheel notch as `.began` then
`.ended`, with no `.changed`, and the handler read the translation only while changing —
so a mouse wheel did nothing at all while a trackpad, which sends a continuous stream,
worked. Consuming every state that carries a translation is only half of it: a notch is
usually shorter than a line, so zeroing the accumulator per gesture would still never
reach a whole row. The arithmetic is now a value type, `ScrollAccumulator`, that keeps its
remainder between gestures and is tested directly.

**A drag interaction that was always on ate the selection.** A pointer begins a drag lift
on click-and-drag with no long press, and the lift fails every competing recogniser —
including the pan that selects text. The delegate refused the drag a moment later (nothing
was selected), but by then the selection gesture was gone. The interaction is now enabled
only while there is a selection to drag, which is what its own comment already claimed.

**Smaller ones, same session.** A pointer drag anchored where the recogniser recognised
rather than where the button went down, losing the first character or two of every
selection. The privacy shield covered an inactive scene and, being a filled SwiftUI
overlay with no `allowsHitTesting(false)`, swallowed the click meant for the terminal
underneath. ⌘1…⌘9 in a stack layout changed the selection without pushing anything, so the
visible terminal lost its claim and became "Open in another window". Unlocking made "the
first window that is not the lock" key, which on iPad is not reliably the app's window.
The Control latch was mirrored from the session on every SwiftUI update while being
cleared asynchronously, so an update landing between the two re-armed it and ate the next
character; it is cleared synchronously now, and turning the key row off disarms it.

**Verified how.** `PointerScrollTests` pin the scrolling arithmetic — notches smaller than
a row accumulating across gestures, direction, the reset, a zero cell height — and that
the drag interaction follows the selection. `HardwareKeyboardStateUITests` type into the
terminal without ever waiting for a software keyboard, which is the state a hardware
keyboard puts the app in, and assert the shell received it after the find bar, the command
palette and a whole sheet have each taken focus; a second test opens a second session and
asserts the typing lands in the session on screen and not the first. What still needs a
device: a real Magic Keyboard and a real mouse, and the iPadOS focus engine, none of which
XCUITest reproduces — they stay on the release checklist.

## D-026 · A Cloudflare failure says what failed

`AccessError` has carried a precise `STError` for every case since D-001 — "No Cloudflare
Access application was found for this hostname", "Your Cloudflare Access session has
expired", "Could not verify that this hostname is genuinely protected by your Cloudflare
team" — with its own recovery sentence. Nothing ever called it. `HostConnector` let the
error propagate raw and `TerminalSession.connect` recognises only `STError`, wrapping
anything else as `.internalError` with "The connection could not be established." So every
failure before the tunnel opened — a hostname with no Access application, an expired
session, a rejected service token, DNS that did not resolve, a clock that is wrong —
reached the user as the same sentence with no recovery text.

The translation is one `catch` at the Access boundary. It is worth its own note because
the missing line was not in the Cloudflare code, which was complete: it was at the seam,
where a well-described error met a caller that only understood one type.

**Verified how.** `SSHErrorCategoryTests` already pin the mapping's categories.
A live Cloudflare environment is still what proves the messages appear on the right
failures (B-2), and that remains true; what changed is that when it fails, it now says
which failure it was.

## D-027 · A remote screen is its own connection, not a setting on an SSH one

D-022 made a screen "a second kind of session over the same connection", and put its
settings in the SSH connection's editor. That was wrong in a way only using it shows: the
two are not the same thing. A screen has its own address — often a different machine from
the one you SSH to — its own port, its own password, and it may not involve SSH at all.
Configuring it inside a connection meant a screen could not exist without one, two screens
behind the same bastion were impossible, and the SSH editor grew a section most people
never wanted.

**A record of its own.** `ScreenConnection` — name, address, port, route, and whether a
password is stored — in `ScreenStore`, beside the host list and shaped like it. The choice
against a `kind` field on `Host` is deliberate: `Host` means "something you can SSH to",
and half its fields (username, credentials, transport, terminal type) are meaningless for a
screen. A kind field would put a `where kind == .ssh` filter in every consumer of
`hostStore.hosts` — the session manager, Siri's connection query, the command palette,
session restoration — and one missed filter opens a terminal to a screen. A separate type
makes that a compile error instead.

**"Through SSH" is a reference, not a property.** `Route.throughSSH(hostID:)` names a saved
connection; `.direct` names none. The screen contributes what the SSH side cannot know: the
address and port *as that server sees them*, and its own password. Deleting the connection
does not cascade — the row says "SSH connection missing" and opening reports a
configuration error rather than quietly connecting some other way, which also covers the
case where sync applies a screen before the connection it names.

**Migration, once, on every device.** A screen configured the old way moves out at launch:
the password is stored under the screen's id *before* it is deleted from the connection's,
so an interruption can leave it in both places and never in neither; the record is inserted
only if absent; the connection is then stripped and saved without stamping, so a device
still on the old version keeps its working screen until it upgrades and migrates its own
copy. Both devices derive the same screen id — a name-based UUID from the connection's id —
so the two migrations converge instead of producing two screens. A connection arriving
through sync still carrying its old block is migrated the same way on the spot.

**Sync.** `SyncKind.screen`, its own record name and its own tombstones. A device still on
the old version drops records of a kind it does not know, which is exactly right here — it
keeps working from its own copy, and gets the screens when it upgrades.

**Verified how.** `ScreenConnectionTests` cover the record and its validation, the route,
the derived id's stability across devices, the mapping out of every old shape (through SSH
with and without a target, and direct, which used to dial the SSH connection's own
hostname), a migration that moves the password and empties the connection and changes
nothing when run again, and the store's add, update, delete-with-tombstone and
insert-if-absent. `VNCUITests` now open the screen from its own row in the list — checking
the row says which connection it travels through — and drive it against LibVNCServer
behind the harness's OpenSSH server as before; a second test opens the screen's own editor
and asserts the SSH editor no longer has any screen sharing in it. macOS Screen Sharing and
a Linux desktop remain hardware checks.

**Not done here.** Siri has no "open the screen called X" intent yet; "Disconnect all
sessions" already closes screens.

## D-028 · The package tests share one event-loop group

The package suite crashed intermittently — twice in six runs — with
`Cannot schedule tasks on an EventLoop that has already shut down` followed by a trap on a
leaking promise. Seven test files each built their own `MultiThreadedEventLoopGroup` or
`NIOTSEventLoopGroup` and shut it down in a `defer`, some of them from a detached `Task`,
while swift-testing ran suites in parallel and connections were still closing on those
loops. The crash took the whole run with it, so a green run proved less than it looked.

Every test now uses NIO's singleton groups, which are never shut down — the pattern NIO
itself recommends for exactly this. Fifteen group constructions and twenty-five shutdowns
went; measured afterwards, five consecutive runs produced no shutdown error at all. This
was pre-existing and unrelated to the changes above; it is recorded because an
intermittently-crashing suite quietly weakens every claim made from it.

## D-029 · A screen can have its own tunnel, and takes a keyboard without being asked

**Its own tunnel.** A screen could already ride a Cloudflare-backed SSH connection — the
`direct-tcpip` channel travels the carrier like anything else on that connection — but a
VNC server published as *its own* Cloudflare Tunnel hostname had no route at all. That is
an ordinary Cloudflare setup (`cloudflared access tcp --hostname vnc.example.com --url
localhost:5900`), and on this side it needs exactly what SSH already needed: the same
WebSocket carrier whose binary frames are a raw TCP stream, behind the same Access
credential. `Route.cloudflare(access:)` is that third route. The address is then the
hostname the tunnel publishes and the port is the edge's — blank means 443, and Cloudflare's
other HTTPS ports work as they do for SSH. Where the screen actually is behind the tunnel
is the tunnel's own business, exactly as it is for SSH.

The Access machinery moved out of `HostConnector` into `AccessCredentialResolver` rather
than being copied: discovery, a stored token while it is valid, a service token when the
connection is set to one, otherwise a sign-in. Two copies of that would have drifted, and
the second copy is where the token handling would have been subtly wrong. A screen's
service token lives in the Keychain under the screen's own id, this device only, and is
deleted with the screen. Access failures are translated the way D-026 translates them, so
"no Access application was found for this hostname" reaches the user as itself.

**A keyboard it does not have to be asked for.** The screen held first-responder status
only while the on-screen keyboard was up, because they were the same switch: an external
keyboard did nothing until you tapped "Keyboard", which then put the system keyboard over
half the picture. They are now separate. The screen holds the keyboard whenever it is
showing — connected, in front, unlocked, nothing over it — so hardware keys reach the
remote immediately, and the on-screen keyboard is a choice, kept down by an input view of
no height rather than by resigning. That is the only way to have both: `UIKeyInput` is what
receives typed characters, and resigning to hide the keyboard is also resigning the keys.

**A wheel, again.** The screen's wheel had the same defect the terminal's did (D-025) —
translation read only while a gesture was `.changed`, and the remainder thrown away
whenever one began — so a mouse wheel did nothing on a remote desktop either. It now uses
the same `ScrollAccumulator`, one per axis. A pointer drag also pressed where the pan was
recognised rather than where the button went down, which drags a remote window from a
point one or two cells away from the one clicked.

**Verified how.** `ScreenConnectionTests` cover the third route — that it is neither
direct nor SSH, that it carries its Access authentication, that blank means the edge's 443
while the other routes still mean 5900, and that it round-trips so a screen saved on one
device opens on another. `VNCTests` pin that the screen can become first responder with the
on-screen keyboard down (an input view of no height, not a resignation) and that it comes
up when asked, and that three ten-point wheel notches arriving as three separate gestures
add up to one step in the right direction. A live tunnelled screen needs the owner's
Cloudflare environment (B-2), and a real external keyboard and mouse remain device checks.

## D-030 · A frame is copied, not walked pixel by pixel

The picture was being assembled one pixel at a time. `Raw` — the encoding every server
uses for the first frame and some use for every frame — went through a call per pixel that
took the framebuffer's lock's word for the bounds and stored four bytes. At 1920×1080 that
is two million calls a frame.

It never had to be. The pixel format the client asks for is 32-bit little-endian with
blue, green and red in the low three bytes, which in memory is byte-for-byte what the
framebuffer holds, so a row of a `Raw` rectangle is a `memcpy` and a solid fill is
`memset_pattern4`. ZRLE, which is what a real desktop actually sends, now decodes over the
inflated bytes through a plain pointer instead of a `ByteBuffer` read per byte, and writes
its raw and solid tiles a row at a time. Measured on a 1080p frame: `Raw` 100 → 4131
frames a second, ZRLE 568 → 800, Hextile 4107, and turning the framebuffer into an image
6819. The screen is no longer waiting on the decoder.

Two things were measured and left alone. Inflation is 0 ms of a ZRLE frame — zlib was
never the cost, so nothing was "optimised" there. And the receive path was *suspected* of
being quadratic, because the buffer was compacted after every read and a 1080p frame
arrives in hundreds of segments; `RFBReceiveTests` feeds a frame in 16 KB pieces and
compares it against the same frame delivered whole, and the ratio is under 1.2. The
hypothesis was wrong, and the test stays as the guard that would catch it if it ever
became true.

The solid-tile case fills inline rather than calling `RFBFramebuffer.fill`, because the
enclosing closure already holds exclusive access to the pixels and calling back into the
framebuffer through it is a runtime exclusivity trap, not merely slower.

The throughput floors are per-encoding rather than one blanket number. A decoder that is a
`memcpy` per row loses almost nothing to a Debug build; one that touches every pixel loses
a factor of forty. A single divisor would either fail on the fast ones or prove nothing
about the slow ones.

## D-031 · A screen may sign in to an account, and the password is never sent in the clear

Classic VNC has one password and no user at all. The two servers people actually reach
from an iPhone often want more: macOS Screen Sharing authenticates a *macOS account*, and
Linux servers configured for VeNCrypt authenticate a user name and password. Both were
unreachable — the client offered only "None" and classic VNC authentication, so a Mac with
Screen Sharing on and no separate VNC password could not be opened at all.

A screen now carries an optional user name beside its optional password. Optional in the
sense that matters: empty is the default and a complete, valid screen, because most
screens have no account.

**macOS Screen Sharing (security type 30).** A Diffie-Hellman exchange over a group the
server chooses; the shared secret's MD5 is an AES-128 key, and the user name and password
travel inside a 128-byte block encrypted under it. So the password is protected even on a
connection with nothing else over it. Neither CryptoKit nor Security exposes modular
exponentiation over an arbitrary group, so `VNCBigInteger` does it — deliberately by
doubling and conditional subtraction, never dividing, because division is where a
hand-written big integer goes wrong and this runs twice per connection, not per frame. It
is 113 ms in release for four exponentiations at 512 and 1024 bits, and it runs on a
background queue rather than on the event loop, which also serves other connections.

**VeNCrypt (security type 19).** Its `VncAuth` sub-type is preferred, because it hashes a
challenge. `Plain` sends the user name and password as they are, and is used *only* when
something else is already encrypting the connection — an SSH channel or the Cloudflare
carrier. On a direct connection the client closes instead and says why. That is what
`Route.isEncrypted` is for. VeNCrypt's own TLS sub-types are refused with their own
message rather than left to hang.

Which type is chosen is a pure function of what the server offered and what the user
supplied, so it is tested without a server. `None` wins whenever it is offered — the
server is saying it wants no secret, and choosing anything else demands one the user does
not have. After that the order is by how well the password is protected: Apple's exchange,
then classic VNC authentication, then VeNCrypt's.

**Verified how.** The arithmetic is checked against exchanges computed by Python's
arbitrary-precision integers at 512 and 1024 bits — an implementation that owes nothing to
this one — because an end-to-end test alone would only prove the client agrees with
itself. AES-128 is checked against the FIPS-197 published answer. The exchange is then run
end to end against a server half that has to *undo* it: it derives the same secret from
the client's public key, decrypts the block, and reads the credentials out. VeNCrypt is
driven through the real handler on an `EmbeddedChannel` — that Plain carries the
credentials, that `VncAuth` is preferred to it, that Plain on an unencrypted route closes
the connection without the password ever being written, and that a TLS-only server is
told so. A real Mac and a real VeNCrypt server remain device checks; neither the bundled
LibVNCServer fixture nor any other server in this repository serves security type 30.

## D-032 · A failed sync says what to do about it

The iCloud status line showed `String(describing:)` of whatever was thrown. For a
`CKError` that is `<CKError 0x…: "Not Authenticated" (9/1002)>` — a developer's string in
a place a user reads. It names a number instead of the thing they can fix, and the two
commonest failures, not signed in and no network, are the two most fixable.

`SyncFailure.describe` turns each code into a sentence that says what to do. A partial
failure reports the reason of the item that failed rather than its own, which says only
that something did. Anything unrecognised keeps the system's wording and carries the
CloudKit code, so a diagnostics export can still be matched to Apple's documentation.

One case is deliberately named as neither the user's fault nor fixable on the device: a
build signed without the app's iCloud container. That is the failure most easily mistaken
for "iCloud is broken", and it is a build problem.

It is a pure function, so all six tests run with no iCloud account and no network.

## D-033 · The tour is shown once, skipped freely, and found again

A terminal has affordances a person will not discover by looking: that a pasted
`user@host:port` is taken apart for them, that Control latches for the next key, that the
palette searches connections and snippets and actions at once, that a screen is not only a
terminal. None of that is visible on an empty connection list.

**Once, and never unasked again.** `hasSeenTutorial` is a device preference, not a synced
one: the tour is about learning the interface in front of you, so syncing it would hide it
from someone picking up their second device for the first time. Skipping and finishing set
the same flag, because a tour that has to be paged through to be dismissed is a gate, and
this is not one. "Delete all data" clears it, which is what a fresh start means.

**After the documents, not instead of them.** The consent screen and the tour are one
`fullScreenCover(item:)` over a single `FirstRun` value rather than two covers. Two
`fullScreenCover` modifiers on one view do not reliably stack, and the ordering — accept,
then learn — has to be a fact rather than a race.

**Drawn, not screenshotted.** Each page's picture is built from the same design tokens as
the interface it describes, so it cannot drift from it; a screenshot of the app inside the
app is stale the first time a corner radius changes, and is six files to keep honest
across two appearances and three scale factors.

**What looking at it caught.** Three defects that no test would have found:

* An accessibility identifier on the root container is inherited by every control inside
  it, so `Skip` and `Continue` both reported themselves as `tutorial` and neither could be
  found by its own name. Presence is now asserted through the controls themselves.
* The entrance stagger gave element *n* a start of `n × 0.12` in a run that ends at 1.0,
  so on the busiest page the last two elements never reached full opacity. The offset is
  now capped so the last one still completes.
* `.fullScreenCover` attached to a `Section` is silently dropped — a `Section` is not a
  view. Reopening the tour from Settings did nothing until the cover moved onto the button.

**A card needs its own colour.** `surface` and `surfaceGrouped` are both black in dark
mode, so a card painted with `surface` on a grouped background was separated from it by a
hairline and nothing else. `surfaceCard` is the pair the system uses for grouped rows.

**Verified how.** `TutorialTests` pin the content as a fact rather than a layout: six
pages, ids that are the order and the tags, a distinct picture each, and a body long
enough to be worth a page. The preference is off on a fresh install, survives a relaunch,
and is cleared by a reset. `TutorialUITests` drive the real thing: a fresh install is
offered it, every page is reachable, the last one finishes rather than continues, back
works, a relaunch does not show it again, skipping does not gate anything, and Settings
brings it back. Every page was also read on screen in both appearances — which is how the
three defects above were found.

## D-034 · A record name CloudKit will accept

Sync failed on a real device with "iCloud rejected the change". CloudKit requires a record
name to be ASCII, and the ids reaching it are not: a known host is identified by
`host:port`, and by `host:port→jump` when it sits behind a bastion — and `→` is U+2192.
One refused name fails the whole batch, which is every record, which is all of sync.

The id is percent-encoded into the name, with `.` deliberately outside the allowed set so
it can separate the kind from the id unambiguously — a hostname is full of dots. Names
written before this are still read, so a device that pushed some before updating can
still match its own deletions.

This was not the failure the user was hitting (that was D-035), but it is a real one, and
it would have been the next.

## D-035 · The CloudKit environment is a decision, not a leftover

With the record names fixed, sync still failed, and the message now carried the code:
CloudKit 15, `serverRejectedRequest`. The app's signed entitlements named **no** CloudKit
environment at all. The provisioning profile offers `["Production", "Development"]`, and
with nothing declared the first one decides — so a build installed from Xcode onto a
development device was asking the *production* container for a record type nobody had
deployed. Production does not create record types on first use; development does. The
server was right to refuse.

`com.apple.developer.icloud-container-environment` is now declared explicitly and driven
by a build setting: `ST_ICLOUD_ENVIRONMENT` is `Development` in Debug and `Production` in
Release. Leaving it unset is how a build meant for development ends up talking to
production, and the symptom — a rejection with no reason attached — points nowhere near
the cause.

The rejection message now also carries whatever CloudKit itself said. "This is a fault in
the app" is true but unactionable; "record type SyncRecord not found" is the difference
between a shrug and a fix, and this is the one branch nobody can act on without it. Three
codes share that sentence, so it carries the code too.

**What this leaves for the owner.** Once sync works in Development, the schema it created
there has to be deployed to Production in the CloudKit Console before any TestFlight or
App Store build can sync — the same `docs/RELEASE.md` item, now with a reason attached
rather than a warning nobody had hit.

## D-036 · iCloud sync needs push, and the server checks before it looks at the records

The rejection turned out not to be about the records at all. With the full error dumped
off the device it read:

```
CKErrorDomain 15   CKHTTPStatus = 500   CKInternalErrorDomain: 2000
ContainerID = iCloud.dev.apexterminal.app
```

No `ServerErrorDescription`, no per-item errors, an HTTP 500 — the request never reached
record validation. The app's entitlements had no `aps-environment` and the bundle no
`remote-notification` background mode. `CKSyncEngine` keeps a database subscription so
that a change on another device is noticed rather than waited for, and a container
request from an app that cannot receive one is refused before the server looks at
anything.

The entitlements file said the app "needs no Network Extension, no VPN, no background
modes and no app groups". That was true when it was written and stopped being true when
sync was added; the comment now says which one exception exists and why, because a
minimal entitlement list is only trustworthy if it is accurate.

Push is declared per configuration, like the container environment: `ST_APS_ENVIRONMENT`
is `development` in Debug and `production` in Release.

**`INFOPLIST_KEY_UIBackgroundModes` does not exist.** Xcode accepts the build setting,
reports it in `-showBuildSettings`, and silently drops it — the built `Info.plist` has no
such key. Background modes can only be declared in a file, so `Config/Info.plist` is a
partial merged into the generated one. It lives outside `App/` because that folder is
synchronised into the target, and a plist there is also copied as a resource, which fails
the build with "Multiple commands produce Info.plist".

Verified by reading the built product rather than the intent: the signed entitlements
carry `aps-environment=development`, the provisioning profile grants it, the merged
`Info.plist` has `UIBackgroundModes = [remote-notification]`, and the generated keys
survived the merge.

**How this was found.** Three hypotheses were tested and discarded first — stale engine
state replaying old record names (the state was pulled off the device and had none), the
record names themselves (D-034, real but not this), and the container environment (D-035,
also real, also not this). Each was checked against the device rather than reasoned
about. The debug-only dump that ended it is compiled out of anything a user could
install.

## D-037 · iCloud sync is withdrawn behind one flag, not half-removed

Every push is refused by the container: `CKErrorDomain 15`, HTTP 500, no server
description, no per-record errors — the request never reaches record validation. Pulling
works, so the account, the entitlements and the push capability are all fine; the
container's own state is not, and that is fixed in the CloudKit Console rather than in
code. Four real defects were found and fixed on the way there (D-034 record names, D-035
the container environment, D-036 push, and the account check that put a pointer on
screen), and none of them was the last one.

So the switch is not offered. A toggle that always fails is worse than an absent feature:
it invites someone to believe their keys and connections are safe somewhere else, which
they are not.

**One flag, nothing ripped out.** `SyncAvailability.isAvailable` is the whole of it. The
engine, the merge, the tombstones, the CloudKit mapping and their tests are all still
compiled and still run — `SyncEngineTests` still exercises the whole reconciliation
against an in-memory transport. Turning it back on is one line, which is the point: a
feature deleted to hide a problem has to be rewritten, and one behind a flag does not.

**Withdrawing has to be complete or it is worse than nothing.** A preference left over
from a build where the switch existed must not start an engine that can only fail; asking
to turn it on must not quietly set the preference either; the switch must read as off
whatever is stored; and the two places that told people to turn it on — the consent
summary and the last page of the tour — must stop saying so. The per-key "Store private
key in iCloud Keychain" control needed nothing: it was already gated on `sync.isEnabled`
and hides itself.

**Shown rather than hidden.** Someone looking for sync should find out where it stands
rather than wonder whether they missed it, so the row is still there, disabled, with the
reason under it.

## D-038 and after · where the later decisions are written

From D-038 the reasoning lives in the commit message of the change it belongs to, with the
state of each item in `docs/EXECUTION_PLAN.md` and what was actually run in
`docs/RELEASE_EVIDENCE.md`. This file is not being abandoned — it is the record for
decisions that outlive one change — but a decision made and carried out in a single commit
is better read next to that commit's diff than paraphrased here.

An index, so nothing has to be hunted for:

| | | |
| --- | --- | --- |
| D-038 | `b2a7fa9` | Export compliance: the algorithm inventory, and the hand-written DES replaced with CommonCrypto |
| D-039 | `67022ca` | `UITextInput` composition, so Pinyin, Kana and Hangul reach the terminal |
| D-040 | `2ab22a0` | Backup and restore, and what a backup must refuse to do |
| D-041 | `713d9d1` | SFTP version 3, spoken to OpenSSH's own `internal-sftp` |
| D-042 | `e30b44b` | The file browser on top of it |
| D-043 | `0622e74` | Prompts, permissions, sharing and drag-and-drop in the browser |
| D-044 | `b6ac72c` | Servers in the Files app, through a replicated File Provider extension |
| D-045 | `f8846de` | Port forwarding as a saved object: local, remote and SOCKS5 |
| D-046 | `4a75b80` | OpenSSH certificates, both directions |
| D-047 | `5300a1f` | Jump hosts, and a connection editor that stops eating fields |
| D-048 | `ef8e1d6` | `mlkem768x25519-sha256`, verified from the server's own log |
| D-049 | `f5e27ea` | SSH keys held in the Secure Enclave, and what the app must refuse to promise about them |
| D-050 | `3cc578a` | The hardware-keyboard test failures: what the simulator does to the first modified key press |
| D-051 | `d2e0c04` | RFC 4256 keyboard-interactive, and the container that made it verifiable |
| D-052 | `d0131fd` | Agent forwarding, with the phone as the agent |
| D-053 | `a8e109d` | Cloudflare as a connection you choose, and diagnostics that measure |
| D-054 | `5f2e1e6` | One SSH transport shared by everything that wants the same server |
| D-055 | `4af75ed` | Split panes: several terminals and screens at once |
| D-056 | `f33d5eb` | The guide, the legal texts and the third-party notices brought back to what the app actually does |
| D-057 | `9ccb306` | tmux control mode: the protocol, against a real tmux |
| D-058 | `c5968f0` | The tmux workspace: windows, panes, and a terminal for each |
| D-059 | `6ff9af5` | tmux in the app: a connection that attaches, and the server's own arrangement on screen |
| D-060 | `7f87801` | What a server may open towards the device, proved against one that tries |
| D-061 | `088633f` | Links, Spotlight, Handoff and a third shortcut — and what a link is not allowed to do |
| D-062 | `e2b14aa` | OSC 7, 52 and 133, DEC 2026 and 1004, and who is allowed to write the clipboard |
| D-063 | `c503865` | A font to work in: any monospaced face, a line height, and ligatures off for a reason |
| D-064 | `0a24b51` | One parameter per spoken phrase, checked in a second rather than at archive time |
| D-065 | `0efe5e8` | Pictures in the grid: sixel, Kitty and iTerm2, and the transfers that cannot work over a network |
| D-066 | `277e492` | A promise nobody would ever complete, on the path where a peer closes before the handshake |
| D-067 | `ea35071` | A missing translation that says which build it came from |
| D-068 | `aae6622` | The app's own warnings, gone and gated — the claim in RELEASE.md made true |
| D-069 | `ca0a658` | The parser's claim that nothing can wedge it, tested by trying |
| D-070 | `83b7c10` | The Mac, as itself: Catalyst with a real menu bar and the limits said out loud |
| D-071 | `89e530e` | Several remote folders at once: a file browser is a session, not a sheet |
| D-072 | `548631d` | visionOS as it actually stands: offered in compatibility mode, and never run |
| D-073 | `c1463c8` | The File Provider crash: one missing Info.plist key, not the simulator |
| D-074 | `a3272e2` | A split screen holds anything: another server, a screen, a folder, or one you have not added yet |
| D-075 | `2dad271` | The change tag CloudKit needs, and the failures nobody was reading |
| D-076 | `882f586` | The pane that lost its session offers to show something else |
| D-077 | `6c85b70` | A picture behind the terminal, dimmed by a measured contract rather than by a slider |
| D-078 | `a122d57` | The themes a restore put back, kept — they were being lost on the next launch |
