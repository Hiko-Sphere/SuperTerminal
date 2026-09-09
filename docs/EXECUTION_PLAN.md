# Execution plan

The order work is being done in, and where it actually stands. Every "done" here means the
definition in the brief: real implementation, reachable by a user, tested, and verified
against something outside itself. Anything short of that says so.

Read this file and `docs/RELEASE_EVIDENCE.md` first after a context reset, then continue
from the first unfinished item rather than starting over.

## Phase 0 — truthfulness, security, data risk

| # | Item | State | Evidence |
| --- | --- | --- | --- |
| 0.1 | Input-method composition in the terminal | **Implemented, awaiting a device** | D-039; `TerminalComposition`, `TerminalInputView+TextInput`; 10 tests driving the real `UITextInput` calls. Real input methods are H-1 |
| 0.2 | Export compliance | **Done** | D-038; `docs/EXPORT_COMPLIANCE.md`; hand-written DES replaced with CommonCrypto and pinned to FIPS 46-3 vectors |
| 0.3 | Data export, import and recovery | **Done** | D-040; `App/Sources/Backup/`, `BackupSettingsSection`; 12 unit tests and 2 UI tests; `.apexbackup` declared in `Config/Info.plist` |

## Phase 1 — core professional capability

| # | Item | State |
| --- | --- | --- |
| 1.1 | SFTP | **Done except multiple tabs** — D-041 protocol, D-042 interface, D-043 prompts, permissions, sharing and drag-and-drop. Several remote folders open at once is the one part not built; the iPad shows one browser at a time |
| 1.2 | Files.app File Provider extension | **Implemented, awaiting a device** — D-044; a replicated extension, a per-connection switch, and 29 package tests against real OpenSSH plus 7 in the app host. The simulator downgrades a replicated domain because it has no FPFS, so the system actually serving Files is H-6 |
| 1.3 | Port forwarding as a first-class object | **Done** — D-045; local, remote and dynamic (SOCKS5), saved with the connection, started by hand or with it, with real byte counters. 9 package tests move real bytes through a real OpenSSH server, 3 app tests through a real `TerminalSession`, 2 UI tests through the screen |
| 1.4 | Authentication | **Certificates, jump hosts, post-quantum key exchange, Secure Enclave keys and keyboard-interactive done** — D-046 certificates; D-047 jump chains; D-048 `mlkem768x25519-sha256`, negotiated with a real OpenSSH 10.2 and confirmed from the server's own log; D-049 Secure Enclave P-256 keys, generated in the Enclave and accepted by real OpenSSH, with the biometric policy device-only (H-7). D-051 RFC 4256 keyboard-interactive, multi-round, verified against a containerised OpenSSH with two PAM prompts. ssh-agent and FIDO2 are still ahead — see the note below |

## Phase 2 — moat

| # | Item | State |
| --- | --- | --- |
| 2.1 | Cloudflare as a first-class connection type | Partly: the transport and Access flow ship (D-001, D-029); the creation flow is still a setting |
| 2.2 | SSH connection multiplexing | Not started |
| 2.3 | tmux control mode | Not started |
| 2.4 | Server-to-device channel | Not started |
| 2.5 | Shortcuts, URL scheme, Handoff, Spotlight | Two App Intents ship (D-021); the rest not started |

## Phase 3 — terminal fidelity

| # | Item | State |
| --- | --- | --- |
| 3.1 | OSC 7, 52, 133 | Not started — `applyOSC` handles 0/1/2 and 8 only |
| 3.2 | DEC 2026, DEC 1004 | Not started |
| 3.3 | Sixel (DCS), Kitty (APC), iTerm2 (OSC 1337) | Not started — DCS is parsed and discarded |
| 3.4 | Font system | Not started — only point size is configurable |

## Phase 4 — platform reach

Mac Catalyst, visionOS, watchOS. Not started, and deliberately after Phase 0–3.

### What 1.4 still needs, and what it will cost

ProxyJump is done (D-047); what follows is the rest.

* ~~**keyboard-interactive**~~ — **done, D-051.** The cost estimate was right about the
  work and wrong about the verification. The fork did need context-sensitive parsing —
  message 60 is `PK_OK` *or* `USERAUTH_INFO_REQUEST` depending on what was sent — and a new
  offer type carrying a responder. But "cannot be verified against this machine's sshd" is
  not the same as "cannot be verified": macOS builds OpenSSH without PAM, so a Linux
  container was stood up with stock OpenSSH, `AuthenticationMethods keyboard-interactive`
  and a PAM stack that asks twice. Every claim below is checked against it.
* ~~**Secure Enclave keys**~~ — **done, D-049.** The estimate above was wrong in a way
  worth recording: it assumed signing would have to go through `SecKeyCreateSignature` and
  that NIOSSH would need a pluggable signer. It does not. `NIOSSHPrivateKey` already takes
  a `SecureEnclave.P256.Signing.PrivateKey` — upstream, not a fork change — so the work was
  storage, UI and honest handling of a key that cannot be exported. It was also wrong that
  this is "verifiable only on a device": the Simulator on Apple silicon has a working
  Enclave, so a key created there authenticates to a real OpenSSH server in the automated
  suite. What is genuinely device-only is the *biometric* policy, which LocalAuthentication
  refuses in the Simulator; that is H-7 and is not claimed as done.
* **Using a local ssh-agent** — not deliverable, and not for want of effort. iOS has no
  system SSH agent, and no way for one app to publish a Unix domain socket another app can
  connect to: the sandbox gives each app its own container, and `SSH_AUTH_SOCK` has no
  meaning where there are no processes to inherit it. There is nothing to talk to. The
  useful half of the idea is the other direction, below.
* **Agent forwarding** — deliverable, and the next slice. The app would be the agent: the
  session asks for `auth-agent-req@openssh.com`, the server opens an `auth-agent@openssh.com`
  channel back, and the app answers `SSH_AGENTC_REQUEST_IDENTITIES` and `SSH_AGENTC_SIGN_REQUEST`
  from the keys it holds — including Secure Enclave keys, which is the interesting part, since
  those can then sign a `git push` on a server without existing anywhere but the phone. What
  the fork lacks is narrow and known: `SSHMessage.ChannelOpenMessage.ChannelType` has exactly
  three cases (`session`, `forwarded-tcpip`, `direct-tcpip`) and its parser has no branch for
  anything else, so an inbound agent channel currently fails to parse. Verifiable end to end:
  connect with forwarding on, then run `ssh-add -l` on the server and require it to list the
  phone's key.
* **FIDO2 (`sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`)** — **not
  deliverable against stock OpenSSH, with a specific missing layer rather than a shrug.**

  iOS does expose security keys, through
  `ASAuthorizationSecurityKeyPublicKeyCredentialProvider`. Two things about it settle the
  question, both read from the iOS 26.5 SDK headers rather than from articles:

  1. The provider is created with
     `- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier`.
     WebAuthn requires that to be a **domain** the app is associated with through
     `webcredentials:` associated domains. OpenSSH's `sk-` keys are scoped by an
     *application* string, conventionally `ssh:` — not a domain, and not something an
     associated-domains entitlement can name.
  2. An assertion comes back as `rawAuthenticatorData`, `signature` and `rawClientDataJSON`
     (`ASAuthorizationPublicKeyCredentialAssertion.h`, `ASPublicKeyCredential.h`). WebAuthn
     signs `authenticatorData ‖ SHA-256(clientDataJSON)`. OpenSSH's `PROTOCOL.u2f` says an
     `sk-` signature is over `SHA-256(application) ‖ flags ‖ counter ‖ SHA-256(challenge)`.
     The `clientDataJSON` wrapper sits *inside* the signed bytes and the public API gives no
     way to remove it, so a signature obtained this way is over a different message than any
     OpenSSH server will verify. It is not a formatting difference that can be repacked.

  There is no public raw CTAP2 API on iOS either. `CryptoTokenKit` ships `TKSmartCard` and
  `TKSmartCardSlotNFCSession` — ISO 7816 smart cards, not CTAP2 HID — and selecting the FIDO
  applet over NFC is not exposed.

  **The deployable alternative already exists and is shipped: Secure Enclave keys (D-049).**
  They give the property people actually want from a security key — a private key that cannot
  be extracted, gated on biometrics — and they work with unmodified OpenSSH today. What they
  do not give is a credential that can be carried between devices, which is the one thing a
  hardware key is for. The app says so rather than offering a switch that cannot work.

## Standing corrections found while auditing

* `PROJECT_STATUS.md` and `TEST_REPORT.md` claimed 13 tests (18 cases) run against
  LibVNCServer. **Five** do — `VNCClientTests`, suite "VNC client against LibVNCServer".
  The rest decode hand-built rectangles, which is a different claim.
* Localisation was described as 385 strings. The shipped catalogs hold **738** entries
  across six files; the audit gates three of them (641 + 49 + 41 = 731) and did not walk
  `InfoPlist.xcstrings` or `AppShortcuts.xcstrings` until D-038.
