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
