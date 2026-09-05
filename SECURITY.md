# Security design and threat model

This document states what SuperTerminal defends against, how, and — as importantly —
what it does not defend against.

## Assets

| Asset | Where it lives | Exposure if lost |
| --- | --- | --- |
| SSH private keys | Keychain, `WhenUnlockedThisDeviceOnly`, optionally biometric-gated; `WhenUnlocked` + synchronisable only for a key the user put in iCloud Keychain (never with biometrics) | Full access to every server trusting the key |
| SSH passwords | Keychain, `WhenUnlockedThisDeviceOnly` | Access to one account |
| Cloudflare Access tokens | Keychain, `AfterFirstUnlockThisDeviceOnly` | Ability to reach the tunnelled service until the token expires |
| Cloudflare service tokens | Keychain, `WhenUnlockedThisDeviceOnly` | Long-lived machine access |
| Known host keys | App container, `.completeFileProtection`, excluded from backup | Not secret; but if an attacker can *modify* it, the MITM warning disappears |
| Terminal scrollback | Memory; not persisted by default | Whatever the session displayed |
| Command history | Off by default; when on, app container, `.completeFileProtection`, excluded from backup, capped at 500 entries | A record of what someone was doing, and any secret typed on a command line |
| Snippets | App container, `.completeFileProtection` | Whatever the user chose to save; treated as user content, so it *is* backed up |

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
travel in an iCloud Keychain sync or in a backup restored onto another device — unless
the user chose iCloud Keychain for that key when creating or importing it, in which case
it is written `WhenUnlocked` with `kSecAttrSynchronizable` (D-015). Apple forbids access
control on synchronisable items, so `CredentialVault` refuses the combination of iCloud
and biometrics with a typed error rather than dropping one silently. Queries use
`kSecAttrSynchronizableAny`, so "Delete all data" and the key list see both kinds. Every
secure field in the app opts out of iOS Password AutoFill's "Save Password?" prompt
(`textContentType(.oneTimeCode)`): AutoFill would otherwise offer to keep an SSH password,
a key passphrase or an Access service token in iCloud Keychain *passwords*, which sync —
found by a UI test that could not reach the row behind the system sheet. Biometric
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
result would fail the JWT signature, audience and issuer checks — plus, since D-013, the
`chacha20-poly1305@openssh.com` SSH cipher, whose output is checked against a real
OpenSSH server in the integration suite (a wrong keystream cannot complete a handshake). Building libsodium from
source is a tracked improvement, not a solved problem.

### T-10 · Screen capture and clipboard

*Status:* App Switcher snapshot protection is implemented: `PrivacyShield` covers the
window with the logo whenever the scene is not active, on by default and switchable in
Settings. Paste confirmation for multi-line content is implemented. Clipboard expiry is
implemented with `UIPasteboard`'s `expirationDate` option: text copied from the terminal
(selections and links) leaves the pasteboard after 60 seconds by default, configurable
to 30 s / 1 min / 5 min / never in Settings → Security. The system enforces the expiry,
so it holds even if the app is suspended. Public keys copied from the key list are
exempt on purpose — they are public and meant to be pasted somewhere later.

### T-11 · Command history as a secondary store of secrets

A terminal history is one of the most revealing things a device can hold. It names hosts,
paths, usernames and internal service names, and it captures anything a person typed on a
command line — including the secrets that do not belong there but are typed anyway
(`mysql -p…`, a token pasted into a `curl` call, a one-time code).

*Mitigation:* the feature is **off by default**, and the check is made inside
`SnippetStore.record` rather than at the call sites, so no future caller can record by
forgetting. Turning it off deletes the file rather than hiding it, and a store opened
while the setting is off does not read an existing file back — so re-enabling never
resurrects an older record. The file is written with `.completeFileProtection`, which
makes it unreadable while the device is locked, and excluded from backup, so the history
does not travel to a new device. It is capped at 500 entries.

*Deliberate limitation:* what is recorded is reconstructed from keystrokes, and a line the
remote line editor may have altered — history recall, cursor movement, tab completion — is
dropped rather than guessed at. This loses entries. That is the intended trade: an
inaccurate history is worse than a short one, because a wrong command shown as something
the user ran would be trusted.

*Not mitigated:* history is not filtered for secrets. Attempting to recognise a password
on a command line is unreliable in both directions, and a filter that mostly works would
invite the belief that it always does. If a secret is typed on a command line it is
recorded, exactly as the shell's own history would record it. The defences are that the
feature is off unless asked for, that it can be cleared in one action from Settings, and
that it never leaves the device.

### T-12 · Automatic reconnection as a way past a security check

Retrying a failed connection is convenient, and convenience is how a security control gets
worn away. If a client retries a host-key mismatch, the user sees a warning that clears
itself; if it retries authentication, a rejected credential is sent again and again.

*Mitigation:* only `network` and `tunnel` failures are retried. Host-key mismatches, TLS
validation failures, SSH transport failures, Access refusals, authentication failures and
credential errors all stop the retry loop and leave the error on screen. The classification
is exhaustive — a test asserts that every error category has a considered answer, so a new
one cannot silently inherit "retry". Recorded as D-010.

*Also:* a reconnection is a full handshake, so the host key is verified again through the
same path as the first connection. A server that changes its key between the drop and the
retry produces the same prompt it would have produced on a first connection, and the retry
loop stops there rather than answering it.

*Not mitigated:* an attacker who can drop connections at will can cause repeated
reconnections, and each one is a fresh handshake to a host the user has already trusted.
This is a denial-of-service and a battery cost, not a path to a credential: nothing is sent
that would not be sent on a normal connection, and the retry count is bounded.

## Cryptography policy

Transport ciphers, in preference order: `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`,
`chacha20-poly1305@openssh.com`, `aes256-ctr` with `hmac-sha2-256-etm@openssh.com`. Every one
authenticates before it decrypts. No non-ETM MAC, no CBC, no RC4, no `none`. The chacha20
scheme uses libsodium's primitives and a constant-time tag comparison; its construction and
the two vendored changes it required are in D-013.

* No algorithm is implemented in this project. Primitives come from CryptoKit,
  `swift-crypto`, libsodium, and OpenBSD's `bcrypt_pbkdf`.
* Verification is never skipped to make a test pass. The test suite contains no
  certificate-validation bypass, no host-key bypass, and no assertion weakened to go
  green.

## Reporting

Security issues should be reported privately to the maintainers rather than through the
public issue tracker.

### T-13 · iCloud sync as a way into the trust store

*Surface:* with sync on, the user's Apple Account can reach the connection list, snippets,
key metadata, trusted host keys, and any private key the user chose to put in iCloud
Keychain. Whoever controls that account can read those and can plant a host key that a
device which has never met the host will trust.

*Defence:* sync is off until the user turns it on. Passwords, Access tokens, command
history, restoration state and diagnostics never sync. Biometric keys never sync (Apple
forbids it; the vault refuses). A remote host key that differs from one this device
already trusts is **held, not applied**: the connection keeps using the local key, the
disagreement is shown in Settings → iCloud, and only an explicit choice replaces it.
Deletions travel as tombstones with a 30-day retention so a stale device cannot resurrect
a removed host. "Delete all data" purges the CloudKit zone and the local deletion history
and switches sync off. The Privacy Policy and User Notice tell the user to keep two-factor
authentication on for the Apple Account, because the account is now part of what protects
their servers.

*Not verified live:* CloudKit and iCloud Keychain need a signed build with the container
entitlement (B-4). The engine's merge, conflict-holding and tombstone rules are verified
against an in-memory transport; the CloudKit record mapping is unit-tested; the live path
is not, and `TEST_REPORT.md` says so.
