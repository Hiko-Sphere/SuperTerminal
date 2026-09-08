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
| 1.4 | Authentication | **Certificates done** — D-046; user certificates offered with a key, host certificates validated against trusted authorities, 12 package tests and 3 app tests against a real OpenSSH server configured with `TrustedUserCAKeys` and `HostCertificate`. keyboard-interactive, ProxyJump, Secure Enclave, agent, FIDO2 and post-quantum KEX are still ahead — see the note below |

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

* **keyboard-interactive** — the vendored NIOSSH does not implement it at all: no
  `SSH_MSG_USERAUTH_INFO_REQUEST`, no `.keyboardInteractive` method, and message 60 is
  parsed unconditionally as `PK_OK`. Adding it means context-sensitive message parsing and
  a new delegate in the fork. It also cannot be verified against this machine's sshd, which
  falls back to BSD auth and would need the login password of a real account — so it lands
  as "implemented, awaiting verification" unless a server that offers it is available.
* **ProxyJump** — no fork change needed: a jump is a `direct-tcpip` channel from the first
  connection used as the transport for the second, and both halves already exist.
  Verifiable with two harness servers.
* **Secure Enclave keys** — P-256 keys whose private half never leaves the Enclave. The
  signing would go through `SecKeyCreateSignature`, which means teaching NIOSSH to accept a
  signer it does not own. Verifiable only on a device.
* **ssh-agent and agent forwarding** — `auth-agent-req@openssh.com` is a channel type the
  fork does not implement, and iOS has no agent ecosystem to talk to. Honest scope is
  probably forwarding *to* a server from keys held in this app, not being an agent client.
* **FIDO2 (`*-sk`)** — needs a security-key middleware iOS does not have; what iOS offers is
  passkeys through `ASAuthorization`, which is not the same protocol. Likely not honestly
  deliverable.
* **Post-quantum KEX** — `mlkem768x25519-sha256` is reachable: swift-crypto vendors
  BoringSSL's ML-KEM, so no primitive would be written here. It needs a new key exchange in
  the fork, and OpenSSH 9.x on this machine can verify it.

## Standing corrections found while auditing

* `PROJECT_STATUS.md` and `TEST_REPORT.md` claimed 13 tests (18 cases) run against
  LibVNCServer. **Five** do — `VNCClientTests`, suite "VNC client against LibVNCServer".
  The rest decode hand-built rectangles, which is a different claim.
* Localisation was described as 385 strings. The shipped catalogs hold **738** entries
  across six files; the audit gates three of them (641 + 49 + 41 = 731) and did not walk
  `InfoPlist.xcstrings` or `AppShortcuts.xcstrings` until D-038.
