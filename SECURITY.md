# Security design and threat model

This document states what SuperTerminal defends against, how, and — as importantly —
what it does not defend against.

## Assets

| Asset | Where it lives | Exposure if lost |
| --- | --- | --- |
| SSH private keys | Keychain, `WhenUnlockedThisDeviceOnly`, optionally biometric-gated | Full access to every server trusting the key |
| SSH passwords | Keychain, `WhenUnlockedThisDeviceOnly` | Access to one account |
| Cloudflare Access tokens | Keychain, `AfterFirstUnlockThisDeviceOnly` | Ability to reach the tunnelled service until the token expires |
| Cloudflare service tokens | Keychain, `WhenUnlockedThisDeviceOnly` | Long-lived machine access |
| Known host keys | App container, `.completeFileProtection`, excluded from backup | Not secret; but if an attacker can *modify* it, the MITM warning disappears |
| Terminal scrollback | Memory; not persisted by default | Whatever the session displayed |

## Threat model

### T-1 · Malicious or impersonating server

*Attack:* an attacker answers on the target host and presents a host key of their own.

*Defence:* SSH host-key verification with an explicit three-way policy in
`HostKeyVerifier`: a matching key is accepted; an unseen identity requires confirmation
of a SHA-256 fingerprint the user can compare against `ssh-keygen -lf` on the server;
a **changed** key is refused unless the user explicitly accepts a replacement after
seeing both fingerprints. There is no configuration and no code path that accepts a
changed key silently. Identity includes the port and, for tunnelled hosts, the jump
destination, so one Access hostname fronting several bastion targets does not collapse
their keys into a single entry.

*Residual risk:* trust-on-first-use is still first-use trust. A user who confirms an
attacker's fingerprint on the very first connection is compromised. Mitigated by showing
the fingerprint prominently and by supporting out-of-band pinning
(`PinnedFingerprintApproval`).

### T-2 · Network attacker between device and Cloudflare

*Attack:* intercept or downgrade the TLS connection to the Access-protected hostname.

*Defence:* TLS is terminated by Network.framework with the system's full validation. The
codebase contains no `URLSessionDelegate` authentication-challenge handler, no
`NWProtocolTLS` verify block, and no way to accept an invalid certificate. The one
non-TLS carrier mode, `Security.plaintextLoopbackOnly`, exists so the carrier protocol
can be tested against a local server, and it **refuses at runtime** to contact anything
that is not `127.0.0.1`, `::1` or `localhost`.

*Residual risk:* a device with an attacker-installed trusted root. Out of scope — the
platform's trust store is the platform's to defend.

### T-3 · Hostile origin steering the Access flow

*Attack:* a server that is not actually behind Access claims to be, naming an
attacker-controlled login domain so the user types corporate credentials into it.

*Defence:* the Access application's identity comes only from a metadata JWT whose
RS256 signature is verified against the auth domain's published JWKS, and:

* `auth_domain` must end in `.cloudflareaccess.com` — a hostile origin cannot nominate
  its own login host;
* the auth domain is re-read from the **verified** payload, so the value used before
  verification cannot select the key set;
* `claims.hostname` must equal the host actually requested, so an Access app cannot
  claim to front a different host;
* `iat` must be within 24 hours and not more than 5 minutes in the future.

Only `alg: RS256` is accepted, closing the `alg: none` and algorithm-substitution
families outright. When a `kid` is present, only the key with that `kid` may verify —
falling back to "try every key" after a `kid` miss would keep a rotated-out key usable.

### T-4 · Access token theft, replay or confusion

*Attack:* obtain a token for one Access application and use it against another; or
replay a token after the session should have ended.

*Defence:* `AccessTokenValidator` checks signature, `aud` (must contain the audience
from the *verified* metadata), `iss` (must be the verified auth domain), `exp` and
`nbf`, with a 30-second leeway so a token that would expire mid-handshake is refused
before it is sent rather than after. Tokens are stored per `(appHostname, audience)`.

### T-5 · Login-flow interception and CSRF

*Attack:* induce a login and capture the resulting credential, or substitute a
credential of the attacker's choosing.

*Defence:* the login's ephemeral Curve25519 public key is simultaneously the transfer
service's lookup handle and the encryption target. It is 32 bytes of fresh randomness
generated in-process and never persisted, so only the login attempt that created it can
both retrieve and open the result. A substituted token additionally fails the signature,
audience and issuer checks in T-4.

The app registers no custom URL scheme for this flow at all. The credential never
travels through a redirect, so there is no callback to hijack.

### T-6 · Private key disclosure

*Defence:* keys live in the Keychain with `ThisDeviceOnly` accessibility, so they cannot
travel in an iCloud Keychain sync or in a backup restored onto another device.
`kSecAttrSynchronizable` is explicitly `false` on both writes and queries. Biometric
items use `.biometryCurrentSet`, which invalidates the item if a new face or finger is
enrolled — so an attacker who learns the passcode still cannot enrol a biometric and
read the key. Writes delete-then-add rather than update, so changing an item's
protection class can never leave the old, weaker attributes in place.

### T-7 · Log and diagnostics leakage

*Defence:* redaction happens at construction, not by scrubbing afterwards. `Redacted<T>`
renders `<redacted …>` in interpolation and requires an explicit `reveal()` at the point
of use, so every disclosure is a greppable call site. Hostnames are logged as a short
non-reversible digest plus the public suffix; JWTs as a length and a signature digest.
Commands and terminal output are never logged. Records are marked `.private` in
`OSLog`, so they are elided from a sysdiagnose collected on someone else's device.

### T-8 · Denial of service through the terminal stream

*Defence:* the WebSocket layer forwards data frames as they arrive, including
continuation fragments, instead of reassembling whole messages — so there is no
unbounded reassembly buffer for a hostile peer to grow. Inbound frames are capped at
1 MiB. Terminal memory is bounded by the emulator's scrollback limit.

*Status:* the scrollback bound and escape-sequence hardening land with `STTerminal`;
tracked in `PROJECT_STATUS.md`.

### T-9 · Supply chain

*Defence:* every dependency is pinned in `Package.resolved` with its licence and
rationale recorded in `THIRD_PARTY_NOTICES.md`.

*Known exposure, stated plainly:* `swift-sodium` ships `Clibsodium.xcframework` as a
**prebuilt binary**, so its contents are not auditable from source in this repository.
The mitigations are that the package is maintained by libsodium's own author, that the
version is pinned, and that the binary's role is limited to one operation
(`crypto_box_open`) on data that is independently validated afterwards — a tampered
result would fail the JWT signature, audience and issuer checks. Building libsodium from
source is a tracked improvement, not a solved problem.

### T-10 · Screen capture and clipboard

*Status:* App Switcher snapshot protection, paste confirmation for multi-line content,
and clipboard expiry are designed but not yet implemented. Tracked in
`PROJECT_STATUS.md` — this section will be updated when they land, and not before.

## Cryptography policy

* No algorithm is implemented in this project. Primitives come from CryptoKit,
  `swift-crypto`, libsodium, and OpenBSD's `bcrypt_pbkdf`.
* Verification is never skipped to make a test pass. The test suite contains no
  certificate-validation bypass, no host-key bypass, and no assertion weakened to go
  green.

## Reporting

Security issues should be reported privately to the maintainers rather than through the
public issue tracker.
