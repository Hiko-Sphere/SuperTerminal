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
| 1.1 | SFTP | **Protocol done, interface next** — D-041: `STSFTP` version 3 over an SSH subsystem channel, 7 tests against OpenSSH `internal-sftp`. The browser, transfer queue and Files.app import/export are the next slice |
| 1.2 | Files.app File Provider extension | Not started |
| 1.3 | Port forwarding as a first-class object | Not started — the `direct-tcpip` plumbing exists (D-022) but is not a user feature |
| 1.4 | keyboard-interactive, Secure Enclave keys, certificates, ProxyJump, agent, FIDO2, PQ KEX | Not started |

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

## Standing corrections found while auditing

* `PROJECT_STATUS.md` and `TEST_REPORT.md` claimed 13 tests (18 cases) run against
  LibVNCServer. **Five** do — `VNCClientTests`, suite "VNC client against LibVNCServer".
  The rest decode hand-built rectangles, which is a different claim.
* Localisation was described as 385 strings. The shipped catalogs hold **738** entries
  across six files; the audit gates three of them (641 + 49 + 41 = 731) and did not walk
  `InfoPlist.xcstrings` or `AppShortcuts.xcstrings` until D-038.
