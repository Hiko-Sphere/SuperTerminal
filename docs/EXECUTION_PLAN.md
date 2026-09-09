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
| 1.4 | Authentication | **Certificates, jump hosts, post-quantum key exchange, Secure Enclave keys and keyboard-interactive done** — D-046 certificates; D-047 jump chains; D-048 `mlkem768x25519-sha256`, negotiated with a real OpenSSH 10.2 and confirmed from the server's own log; D-049 Secure Enclave P-256 keys, generated in the Enclave and accepted by real OpenSSH, with the biometric policy device-only (H-7). D-051 RFC 4256 keyboard-interactive, multi-round, verified against a containerised OpenSSH with two PAM prompts; D-052 agent forwarding, proved by `ssh-add -l` on the server. Using a *local* agent and FIDO2 are recorded below as not deliverable, with the evidence |

## Phase 2 — moat

| # | Item | State |
| --- | --- | --- |
| 2.1 | Cloudflare as a first-class connection type | **Mostly done**: transport and Access flow (D-001, D-029); D-053 adds the split creation flow, the Access diagnostics screen with per-application sign-out, and marks Cloudflare connections in the list. The live end-to-end run against a real tenant remains H-4 and is not claimed |
| 2.2 | SSH connection multiplexing | **Done (D-054)**: one transport per identity, shared by shells, SFTP, screens and forwards; reference counted with an idle timeout; proved by counting `sshd`'s own accepted authentications — four sessions cost one, not four |
| 2.3 | tmux control mode | **Protocol done (D-057)**: `STTmux` speaks control mode — the `%begin`/`%end`/`%error` framing, every notification a real session sends, octal-unescaped output as bytes, and window layouts with tmux's own checksum verified. Proved against a real tmux 3.3a over a real SSH connection in `TmuxIntegrationTests` (5 tests). **Done (D-059)**: the app attaches. A connection marked *Attach to tmux* opens a tmux session instead of a shell; tmux's windows and panes are drawn where tmux says they are, input goes back as `send-keys -H`, and the toolbar lists windows, splits, closes panes and detaches. Verified through the interface against a real tmux in a container. Earlier: **Workspace (D-058)**: `TmuxWorkspace` keeps the windows, the panes in each and a terminal per pane, primes itself with `list-windows` because reattaching announces almost nothing, sends input as `send-keys -H`, and sizes tmux to the client. Verified against a real tmux (10 tests). The app does not offer it yet; wiring tmux windows onto the app's own panes is the next slice, and nothing in the interface claims it until then |
| 2.4 | Server-to-device channel | **Audited and closed (D-060)**. SSH gives a server exactly four ways to open a channel towards a client: `forwarded-tcpip` (**ships**, D-045), `auth-agent@openssh.com` (**ships**, D-052), `x11`, and `tunnel@openssh.com`. The last two are not implemented and are described below rather than half-built. What the app *refuses* is now proved rather than asserted: `InboundChannelRefusalTests` drives a deliberately hostile server that opens channels nobody asked for |
| 2.5 | Shortcuts, URL scheme, Handoff, Spotlight | **Done (D-061)**: `ssh://` and `apexterminal://` links, with the rule that any link carrying a command — and any link naming a server this device has not saved — is shown before anything happens; Spotlight indexing of saved connections behind a switch that is off by default; Handoff carrying which connection a session is for; and a third App Intent, *Run Snippet on Server*, alongside the two from D-021 |

### Split panes (D-055)

Asked for during Phase 2 and built alongside it: several terminals, several remote screens,
or a mixture, on one screen. A recursive layout — splitting a pane replaces *it* with two —
because a flat grid cannot express "a terminal on the left, and on the right a screen above a
second terminal", which is what people build within a minute of being able to.

### The guide, the legal texts and the notices (D-056)

Asked for alongside the panes, and done as its own slice because documentation that
describes a different product than the one in the bundle is a defect, not a shortfall.

* **User guide** — eighteen topics covering everything the app now does, in English,
  Simplified Chinese and Traditional Chinese. It ships as Markdown the app parses into a
  searchable topic list (**Settings → Help → User Guide**, or ⌘/), and `docs/USER_GUIDE.md`
  is generated from the English file so the two cannot drift.
* **Legal texts** — Terms, Privacy Policy and User Notice rewritten in all three languages
  to match the code: Secure Enclave keys, agent forwarding, port forwarding, the Files app,
  reused connections, and the questions a server can ask. The iCloud sections described a
  switch this build does not offer and now say what is true — nothing leaves the device.
  `LegalDocument.currentVersion` is 7, so the consent screen is shown again.
* **Third-party notices** — verified item by item against `Package.resolved` and the
  vendored trees. `swift-nio-ssh` was listed as a package dependency and has not been one
  since D-007; BoringSSL, vendored inside `swift-crypto` and `swift-nio-ssl` under terms
  that are not Apache-2.0, was not mentioned at all; and LibVNCServer, which is GPL and
  test-only, was nowhere in the audit.
* **The vendored patch had drifted.** `patches/niossh-rsa.patch` still described three
  changes and reproduced the tree as it stood before D-046, D-048, D-051 and D-052 — so
  CI's "the patch still reproduces the vendored tree" check would have failed on the next
  run. Regenerated: 33 files, 2902 lines.

### The two channel types a server cannot open here (D-060)

Both are refused by construction — the client cannot even name them — and neither is
claimed anywhere in the interface.

* **`x11`.** Forwarding an X display needs an X server on this device to accept the
  connection. iOS has none, and one app cannot provide a display server to others; the
  only way to honour it would be to implement an X11 server *inside* the app and render
  its clients. That is a product in itself, not a feature of this one. It is not an iOS
  limitation so much as a scope one, and it is recorded as such rather than as impossible.
* **`tunnel@openssh.com`.** This carries IP packets, which on iOS means a `utun`
  interface, which means a Network Extension packet-tunnel provider and the
  `com.apple.developer.networking.networkextension` entitlement. That is available to
  apps, but the provider is a separate process with its own lifecycle: the SSH connection
  would have to live inside the extension rather than in the app, which is a different
  architecture from the one every other feature here depends on. Not started, and no part
  of the app suggests otherwise.

## Phase 3 — terminal fidelity

| # | Item | State |
| --- | --- | --- |
| 3.1 | OSC 7, 52, 133 | **Done (D-062)**: OSC 7 working directory (host ignored, path decoded and checked), OSC 52 clipboard *writes* reported to the app and performed only where the person allowed them — reads refused outright — and OSC 133 prompt/command/output/exit marks. Verified against a real shell over SSH |
| 3.2 | DEC 2026, DEC 1004 | **Done (D-062)**: synchronised output and focus reporting as modes, and DECRQM (`CSI ? Ps $ p`) answers for every private mode this terminal has an opinion about — including 0 for the ones it does not implement, which is what tells a program not to send them |
| 3.3 | Sixel (DCS), Kitty (APC), iTerm2 (OSC 1337) | **Done (D-065)**: all three decode and draw into the grid, scrolling with the text and going when something writes over them. Sixel is checked byte-for-byte against ImageMagick's own encoder; Kitty handles chunked RGB/RGBA/PNG and zlib, answers queries, and refuses the file, temp-file and shared-memory media with `ENOTSUPPORTED` because those name the *server's* filesystem; iTerm2 draws `inline=1` and ignores the rest, which is a download request. The app also sends the pixel size of the grid, which is the only way a program can know how big a cell is |
| 3.4 | Font system | **Done (D-063)**: any monospaced face on the device, a line height, and ligatures — with "monospaced" measured rather than believed (a family is kept only if a narrow character, a wide one and a space all measure the same). Changing any of them re-measures the grid and tells the server, proved through the interface by asking the remote `stty` |
| 3.5 | Fuzzed input | Not started — the parser is written so no byte sequence can wedge it, and that claim is not yet tested by throwing random bytes at it |

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
* ~~**Agent forwarding**~~ — **done, D-052.** The app is the agent. The fork gained the
  `auth-agent@openssh.com` channel type and the `auth-agent-req@openssh.com` request it had
  no branch for; `SSHAgent` answers `REQUEST_IDENTITIES` and `SIGN_REQUEST` and refuses
  everything else. Verified the way it was promised: `ssh-add -l`, run on a real OpenSSH
  server, lists the key by the fingerprint the device holds — with a control that shows the
  same command finding no agent when forwarding is off.
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
