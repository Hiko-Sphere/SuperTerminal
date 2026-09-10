# Security overview — Apex Terminal 0.1.0

**Written:** 2026-09-10 · **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)
· **Companion to:** [`FEATURE_CATALOG.md`](FEATURE_CATALOG.md)

This is the document for a reader who wants to check rather than be reassured: a security
engineer deciding whether the app may go on a work phone, a journalist asking what the
strongest claim actually rests on, a customer reading the security page on the website.

Apex Terminal is an SSH client for iPhone and iPad, on iOS and iPadOS 17 and later.
Commands run on the customer's own remote servers. There is no account, and this project
operates no server of its own.

Two rules govern every sentence below.

1. A behaviour is described as something the product does when a test exercises it against
   something real — a real `sshd`, a real Keychain, a real pasteboard, a real second server.
   Where that is not so, the section says which part is code-reading rather than measurement.
2. The limit travels with the feature, in the same paragraph, in the same voice. §10 collects
   what this document deliberately does not claim.

Everything here was measured on iOS and iPadOS. No statement in this document extends to any
other platform.

---

## 1 · Where private keys live

There are three places a credential can sit, and they are not equivalent.

**In the Secure Enclave.** A key generated in the enclave has its private half created inside
dedicated hardware. No copy of it exists anywhere else, at any time. The app holds a wrapped
reference; the chip signs. Such a key cannot be exported, backed up, synced or moved to
another device — losing the device loses the key, and the app says so plainly rather than
implying a recovery path. The curve is `ecdsa-sha2-nistp256`, because that is what the
enclave signs with.

*Evidence.* `SecureEnclaveKeyTests.swift:24` generates the key in the enclave, places the
public half alone in a real OpenSSH server's `authorized_keys`, logs in, runs a command, and
asserts on the server's own log line `Accepted publickey … ECDSA <fingerprint>`. The control
case at `:57` proves the same key is refused by a server that was never told about it — a
test that can also fail on purpose proves more than one that always succeeds. `:95` runs
`/usr/bin/ssh-keygen -l` on the public line the app writes and requires it to agree on the
fingerprint. `:123` refuses a reference belonging to another device. The whole login is
repeated through the app's own session stack at `AppTests/SecureEnclaveAuthTests.swift:32`.

**In the iOS Keychain.** Imported and device-generated keys, saved passwords, the app-lock
record and service credentials are Keychain items rather than files. The code writes them
with a this-device-only accessibility class, and it deletes-then-adds so that a protection
class can never be silently downgraded by a later write.

*Evidence, and its edge.* Real Keychain round trips are exercised in the app host:
`AppTests/ServiceTokenTests.swift:26` stores, reads back and deletes; 
`AppTests/ShellIntegrationSessionTests.swift:22` stores a real private key through the
credential vault and then logs in to a real `sshd` with it; `AppTests/AppLockTests.swift`
uses the real vault throughout. **No test reads the accessibility attribute back**, so the
specific protection class is a code-reading claim, not a measured one. The honest public
sentence is "keys are kept in the iOS Keychain". The stronger form — naming the constant —
belongs in engineering documentation, and this file is where that distinction is recorded.

**In a file.** Nowhere. There is no key file on disk for a person or a process to copy. What
is on disk is the known-hosts record (§4) and, if a person exports one, a backup file they
sealed themselves (§8).

Two things the app refuses to do, and says so in its own interface: it does not support FIDO2
or hardware security keys, because iOS exposes them through WebAuthn, which signs a different
structure from the one OpenSSH verifies; and it does not use a local ssh-agent, because iOS
gives each app its own container with no way to reach another app's socket.

---

## 2 · The Secure Enclave claim, stated exactly

The sentence that may be printed is:

> Create a key inside the Secure Enclave. Its private half cannot leave the device — and it
> logs in to an ordinary OpenSSH server.

Both halves matter, and the same test proves both at once. The server in that test is an
unmodified OpenSSH `sshd`: nothing was patched, no plug-in was installed, no agent was
involved. What the server sees is an ordinary ECDSA public key in `authorized_keys`. What the
device does is ask the chip for a signature.

What makes this different from the usual claim in this category is not the strength of an
algorithm. Every "your keys are safe" sentence a person has read before means "the key file
is encrypted". This one means there is no key file.

The known weakness is stated with it: a key that cannot leave the device also cannot be
recovered from a backup, and the backup exporter names such keys as unexportable rather than
quietly dropping them from the file (§8).

---

## 3 · Biometric gating — an option, not a measured claim

Three biometric surfaces exist in the app:

* a Secure Enclave key that requires a fresh Face ID or Touch ID check before every
  signature, and that stops working if someone enrols a new face or fingerprint;
* an ordinary Keychain-stored key that requires a check before the key is read, with the same
  enrolment-change behaviour;
* biometric unlock of the app lock (§7).

**Not one of these has ever run against real biometric hardware in this project.** The
Simulator has a Secure Enclave but no biometrics, and the system returns
"This call is not supported on iOS Simulator" when a biometric policy is requested.
`docs/HUMAN_ACTIONS.md` H-7 is the open item and is not marked done.

Therefore: "a key can be protected with Face ID or Touch ID" is fair, because the option
exists and is offered in the interface. "Face ID-protected keys, proven" is not fair, and a
staged Face ID prompt must not appear in a screenshot or a caption.

What *is* tested is what the app does around such a key rather than the prompt itself: a
biometric key is classified as unusable without a person present, the background file
extension refuses to publish a server that depends on one, and the backup exporter names it
as unexportable with the reason attached
(`SecureEnclaveKeyTests.swift:168`, `AppTests/FileProviderDomainTests.swift:77` and `:131`,
`AppTests/BackupTests.swift:135`).

---

## 4 · Host key verification, and what happens when a key changes

The policy has two states and no third.

**A server not seen before.** Its fingerprint is put in front of the person, who is asked to
compare it out of band. The app cannot tell a real server from an impostor on that very first
connection, and the app's own consent screen says exactly that rather than implying
otherwise. Only after the person accepts is the key recorded.

**A server whose key does not match what was recorded.** The connection is refused. It is a
hard stop, not a prompt to tap through, and the stored key is not silently replaced. A
replacement can be accepted, but through an explicit human decision that shows both
fingerprints.

This is the case most mobile SSH clients get wrong, and it is the case that matters: a
changed host key means either a rebuild or somebody sitting between you and the server.

*Evidence.* `SSHIntegrationTests.swift:200` boots **two** real OpenSSH servers, seeds the
store with the wrong one's key, connects, and requires the failure to carry the host-key
category **and** the stored key to be unchanged. `:235` proves that trust on first use
records the server's real key and its SHA-256 fingerprint. At the app level,
`AppTests/AppSSHIntegrationTests.swift:128` checks that the fingerprint shown in the sheet is
the server's real one, not a value the app made up. The shipping module's automatic approval
policy accepts a first-seen key and never accepts a changed one.

*The limit.* The record is the app's own JSON file, not OpenSSH's `~/.ssh/known_hosts`. There
is no import or export of an existing `known_hosts`, no hashed hostnames, and no
`@cert-authority` or `@revoked` lines. Saying "your known_hosts" would be wrong. On iOS the
file is written with complete data protection and is excluded from device backups, so
restoring an old backup cannot quietly reinstate a retired key — that is an iOS statement and
does not extend to any other platform.

Through a bastion, each hop is checked as itself: the far server's host key is compared
against the far server's record, not the bastion's, and the two get separate entries
(`JumpHostTests.swift:45`, `:117`).

---

## 5 · Certificates

Where an organisation runs an SSH certificate authority, the app supports both directions.

**Host certificates.** Trust the authority once, for host patterns you type in, and there is
no fingerprint left for anyone to eyeball. The key **inside** the certificate is what gets
remembered, so a routine renewal does not surface as a changed host key. A certificate that
fails validation — wrong host name, wrong principal, expired, untrusted issuer — is refused
outright. It is never downgraded into a prompt a tired person can accept.

**User certificates.** Log in with a certificate an authority issued, so the server needs no
per-user `authorized_keys` entry. The app reads the principals, key ID, serial, issuer
fingerprint and expiry, and skips an expired certificate rather than spending an
authentication attempt on it.

*Evidence.* `CertificateTests.swift:162` proves a certified host key needs no fingerprint —
the approval delegate fails the test if it is consulted at all — with `:188` the fallback,
`:210` the remembered bare key, and `:243` a certificate for another host name refused
**and** the user not asked. For user certificates, `:50` gets a key the server has never
heard of into a real `sshd` configured with `TrustedUserCAKeys`, with controls at `:61`,
`:79`, `:96`, `:113` and `:135`.

*The limits.* Authorities are trusted for the patterns a person enters; `@cert-authority`
lines from an existing file are not imported. Critical options carried in a certificate are
not accepted. Certificates are deliberately not remembered, so a revoked or expired one stops
working rather than living on.

---

## 6 · Agent forwarding, and what a hostile server cannot do

### 6.1 · The agent is one-directional

With agent forwarding turned on for a connection, the device acts as the agent: a `git push`
on the server is signed by a key that never leaves the phone, including an enclave key that
cannot leave it at all. Two requests are served — list the identities, and sign this — and
nothing else. Adding or removing an identity over the forwarded channel is refused.

Forwarding is off unless a person turns it on for that connection. The keys attached to that
connection are what is offered, and a passphrase-protected key is skipped rather than
prompting from a background context.

*Evidence.* `AgentForwardingTests.swift:26` uses OpenSSH's own `ssh-add -l`, run on a real
`sshd`, to list the fingerprint of a key that never left the device. `:59` is the control:
with forwarding off, there is no agent to find. `:102` refuses a key the device does not
hold; `:121` refuses add and remove.

### 6.2 · The refusals

A server on the other end of an SSH connection can ask to open channels back towards the
client. Here is what happens when it does:

| What the server tries | What the app does |
| --- | --- |
| Open a `forwarded-tcpip` channel for a port nobody forwarded | Refused; the session survives |
| Open a `forwarded-tcpip` for port 9002 when 9001 was the one requested | Refused, and the refused channel never reaches the registered route |
| Open an agent channel where agent forwarding is off | Refused; the session survives |
| Open a session channel — that is, run something on the device | Refused; the session survives |
| Read your clipboard through OSC 52 | Refused, permanently, and the refusal is not even reported back (§9) |
| Write a file onto the device through an inline-image escape | Refused by construction |
| Open an X11 channel, or an IP-level tunnel | Not implemented, and refused by construction |

Each refusal deliberately leaves the connection usable, so a hostile server can keep trying.
It never succeeds.

*Evidence.* `InboundChannelRefusalTests.swift:41`, `:60`, `:75`, `:108`, each asserting both
the refusal and the survival of the session, driven by `HostileSSHTestServer.swift` — a
server written to misbehave, which is unavoidable, because stock OpenSSH will not do these
things on request.

*The limit.* The counterparty in those tests is this project's own fixture: a real NIO SSH
server completing a real handshake over a real socket, but not an attacker in the field.

### 6.3 · Links that carry a command

An `ssh://` or `apexterminal://` link can never make the app run something on a server
without showing the exact command and waiting for agreement. Refusing does nothing at all,
and a link can never add a connection by itself — an unsaved server is offered in the editor
with the fields filled in, for a person to save or not.

*Evidence.* `AppUITests/LinkUITests.swift:37` proves the refusal against a real `sshd`
(nothing ran, no session opened) and `:62` proves the approved case runs and the shell prints
its marker on the server. Unit coverage at `AppTests/IncomingURLTests.swift:52`, `:65`,
`:100`, `:117`, `:129`.

*The limit.* In the end-to-end test the link is injected through a debug hook rather than
delivered by iOS. The confirmation, the refusal and the execution are real; the system's URL
delivery is not part of that test. Separately, `ssh://` is not an exclusive scheme — any
installed SSH client may claim it, and iOS decides which wins.

---

## 7 · The app lock

A passcode of the app's own, separate from the device passcode, in front of the app itself.

* A 16-byte random salt, PBKDF2-HMAC-SHA256 at 200 000 rounds, constant-time comparison. The
  passcode itself is never stored.
* Backoff after repeated wrong guesses: 0, then 30, then 60, then 300 seconds.
* A grace period chosen by the person: immediately, 1, 5 or 15 minutes after the app goes
  away.
* The lock is its own window above the alert level, so a sheet that was open cannot sit on
  top of it.
* Failures cost time, never data. There is no wipe-after-N-attempts, and deleting all data
  cannot lock a person out of their own device.

*Evidence.* `AppTests/AppLockTests.swift:33` (the record holds no passcode, a fresh salt each
time), `:46` (the backoff table), `:73` (the grace period), `:89` (five wrong guesses cost 30
seconds, and the right passcode is not accepted during the backoff), `:129` — all against the
real Keychain. End to end, `AppUITests/AppLockUITests.swift:48-110` sets a passcode in
Settings, terminates and relaunches the app, asserts the lock screen stands in front and that
nothing behind it is reachable, rejects a wrong passcode, accepts the right one, then
backgrounds the app and returns to a lock.

*The limits.* Minimum length is four characters. Face ID or Touch ID can open the lock, and
that is fair to offer as an option — the state machine around it is tested with a stub, and
the biometric check itself has never run here (§3). This evidence is iOS and iPadOS.

---

## 8 · Backup encryption

A backup is one file the person exports themselves through the system file picker.

* **By default it carries no secret at all** — connections, saved screens, snippets, key
  metadata, trusted host keys and preferences, with public halves and nothing more.
* Private keys go in on an explicit choice **and** a password. The password seals the whole
  payload, not merely the keys: PBKDF2-HMAC-SHA256 to derive, then AES-GCM over the JSON.
* Tampering with the ciphertext is caught by the seal. A wrong password is reported as a
  wrong password rather than as a damaged file.
* Restoring previews first: it shows what would be added and what would collide, and offers
  keep-existing or overwrite, before anything is written.
* Keys held behind Face ID or Touch ID, and Secure Enclave keys, have no exportable form.
  They are **named as unexportable, with the reason**, rather than silently dropped — a
  backup that quietly loses a key is worse than one that refuses to pretend.

*Evidence.* `AppTests/BackupTests.swift:36` asserts on the encoded **bytes** that a default
export contains no "PRIVATE KEY" text and no password field, then reads the file back into
fresh stores on a real temporary directory. `:110` proves the seal covers the whole payload;
`:127` that private keys need a password; `:135` the unexportable-key naming; `:151` the
wrong-password report; `:190` tamper detection; `:60`, `:76` and `:95` the preview and the
resolution.

*The limits.* The file is as strong as the password chosen for it. No test writes a file
through the real system picker and re-imports it on a device; the service and the screens are
what is covered.

---

## 9 · Clipboard policy

Three separate things, kept separate on purpose.

**A remote program writing your clipboard.** OSC 52 — the escape sequence tmux and vim use so
that a yank reaches the device — is off until a person turns it on. The first refusal
explains itself once per session. Payloads are capped at 64 KiB and the base64 is validated.

**A remote program reading your clipboard.** Refused, permanently, regardless of the setting,
and the refusal is not even reported back to the program that asked. This is the point of the
whole section: the generous reading of "clipboard support" is that a server can also read.
Here it cannot, and it cannot tell that it was refused.

**Text you copy out of the terminal.** It is set to expire from the iOS pasteboard, after 60
seconds by default, with 30 seconds, 1 minute, 5 minutes and never as the choices — so a
password echoed by mistake does not sit in the clipboard until the next copy. Public keys
copied from the key list are deliberately exempt, being public.

*Evidence.* `ShellIntegrationTests.swift:70`, `:77` (a read is refused and not reported),
`:91`; and against a real `sshd` with the real pasteboard,
`AppTests/ShellIntegrationSessionTests.swift:89` sends the real escape sequence from the
shell and asserts the pasteboard is still untouched, while `:108` asserts the same write
lands once the setting allows it. Expiry: `AppTests/ClipboardTests.swift:7` asserts the
option is computed correctly and `:21` copies through the real pasteboard and reads it back.

*The limit on expiry.* That the text actually disappears is the system's guarantee, which is
why it holds while the app is suspended. No test in this project watches a pasteboard empty
itself. Write "copied terminal text is set to expire"; do not write "proven to vanish after
sixty seconds".

**A related sentence that must be got right.** Pasting text that contains a newline asks
before anything runs, whether the text was pasted or dropped, and bracketed-paste mode does
not suppress that confirmation. The decision function is exhaustively covered
(`AppTests/PasteAndSearchTests.swift:17-63`, `:120`); the sheet appearing in front of a live
shell is not covered by a UI test.

---

## 10 · What leaves the device

The accurate sentence, and the one to use, is:

> Apex Terminal has no server of its own. Your data goes only where you send it.

Unpacked:

* **To the servers a person connects to.** That is the product. Commands, files and
  keystrokes go to machines the customer owns.
* **To an AI provider endpoint, if a person configures the optional assistant.** The
  assistant prefers the device's own model and does nothing at all without a key the person
  supplies and stores. If a person points it at a provider instead, up to 6 000 characters of
  terminal text plus the last command are sent to that endpoint, and the app shows what it
  will send before sending it. **This is the one place terminal content can leave the
  device**, and it is why an unqualified "your terminal never leaves your device" must never
  be written. The assistant is not advertised (see `FEATURE_CATALOG.md` §11); it is named here
  because a privacy claim has to survive it.
* **Nowhere else.** There is no sign-up flow, no first-party domain anywhere in the source,
  no analytics, no telemetry, no crash reporter, no advertising identifier and no third-party
  SDK of that kind. Sync between devices is switched off in this build, so connections, keys,
  known hosts and snippets stay on the one device; the switch in Settings is shown disabled
  and says so.

*How an absence is proved.* Not by a test — an absence cannot have one — but by a search
anyone can repeat in seconds, which is a stronger invitation than a promise. The whole
dependency list is swift-nio, swift-nio-ssl, swift-nio-transport-services, swift-crypto,
swift-sodium and a vendored swift-nio-ssh fork; the Xcode project declares no remote package
references at all. `PrivacyInfo.xcprivacy` declares tracking false, an empty tracking-domains
list and an empty collected-data-types list, with two required-reason APIs. A search across
every source, plist, entitlement and project file for the usual analytics and crash-reporting
SDK names returns zero hits in shipping code — the two matches in the whole tree are the
app's own sentences telling the user there is no analytics.

*The entitlements.* Deliberately small: push, an App Group, a Keychain group and iCloud. No
Network Extension and no VPN profile. The app captures no system-wide traffic and is not a
VPN.

*Deleting everything.* One action in Settings closes every session and removes every
connection, key, saved password, snippet, history entry and known-host record from the
device. iOS does not promise to remove Keychain items when an app is deleted, which is why
the documentation tells people to run that action before deleting the app. It touches nothing
on a server.

---

## 11 · Two smaller behaviours, stated precisely

**The App Switcher cover.** When the app is not the active scene, a cover with the logo goes
over the window, so the App Switcher snapshot does not show a terminal. It is on by default
and can be switched off. **It covers the App Switcher snapshot and nothing else.** There is
no screenshot blocking, no screen-recording detection and no secure-display flag anywhere in
this app. The correct phrasing is "hides your terminal in the App Switcher". It has no test,
so it is described, never headlined.

**Secret fields opt out of system password autofill.** Every secure field in the app — SSH
passwords, key passphrases, the app-lock passcode, backup passwords — declares itself in a
way that stops iOS offering to save it into the system's synchronised password store, which
would put it somewhere the app does not control. This was found by a UI test that could not
reach a row behind the system's "Save Password?" sheet; no test asserts the attribute today,
so it belongs on a security page rather than in a headline.

---

## 12 · What we do not claim

Stated here so that nobody has to infer it from silence.

* **Not "two-factor authentication built in".** Servers that ask for a one-time code log in
  from the phone: the app shows the server's own prompt, in the server's own words, and
  passes the answer along. It stores no secret and generates no codes of its own. There is no
  built-in authenticator.
* **Not "Face ID-protected keys, proven".** The option exists; no biometric surface in this
  project has run against real hardware (§3).
* **Not "blocks screenshots" or "blocks screen recording".** Neither exists (§11).
* **Not "your terminal never leaves your device", unqualified.** See §10.
* **Not "sync across your devices".** Sync is switched off in this build, and the app says so
  in its own Settings screen.
* **Not "stays connected in the background".** iOS does not guarantee it, so neither do we. A
  port forward runs while the app is running and on screen; the app says this in the forwards
  screen itself.
* **Not "a VPN", and not "route all your traffic".** This is TCP port forwarding. Local and
  dynamic forwards bind 127.0.0.1 and nothing else, deliberately — the device never becomes a
  gateway for anything else on the network.
* **Not "works with any VNC server".** The encodings that decode are ZRLE, Hextile, RRE and
  Raw; a server configured to offer Tight or TRLE alone will not draw. On a direct route RFB
  carries the picture in the clear, which is why the SSH route exists and why the app says so
  in its own editor.
* **Not "your known_hosts".** The record is the app's own file and is not interoperable with
  OpenSSH's format (§4).
* **Not "resumable transfers".** Resuming from a byte offset is a deliberate refusal, because
  SFTP has no notion of a partial upload the server will remember. A running transfer can be
  paused and resumed; an interrupted one restarts and still lands whole.
* **Not "security keys supported".** FIDO2 is refused, and the app says so on its own Keys
  screen.
* **Not "military-grade", "bank-grade", "unhackable", or any other adjective standing in for
  a measurement.** Where there is a number, it is named along with what produced it. Where
  there is no number, there is no adjective.
* **No user counts, ratings, awards or rankings.** There are none.
* **No named comparison with any other product.** The reasons are in
  [`FEATURE_COMPARISON.md`](FEATURE_COMPARISON.md), which is internal.

---

## 13 · How to check this document

Everything above names an artefact: a test file and a line, a server's own log line, a
manifest, or a search anyone can run. A reader who wants to disagree with a sentence here
should be able to find the thing that would have to be wrong for it to be wrong. That is the
standard this file is written to, and a sentence that cannot meet it does not belong in it.
