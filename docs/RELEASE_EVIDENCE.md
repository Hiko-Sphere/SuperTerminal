# Release evidence

Commands actually run, and what they actually printed. Numbers here are recounted after
every change rather than carried forward.

## 2026-09-08 — after D-043 (prompts, permissions, sharing, drag-and-drop)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **237 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (FileBrowserUITests) | **2 passed** against the harness's own sshd — a real listing, and a real file's real mode filled into the editor |
| `bash scripts/localization-audit.sh` | **green**, 12 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

## 2026-09-08 — after D-042 (SFTP file browser)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **236 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (FileBrowserUITests) | **1 passed** — a real listing from the harness's own sshd |
| `bash scripts/localization-audit.sh` | **green**, 53 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

The UI test was read on screen before it was trusted: the browser showed the real home
directory over the real server, with real modification dates and real permission strings
(`drwxr-xr-x`, `drwx------`), folders sorted first, and a working path bar. The first two
runs failed on the test's own locator, not on the feature.

## 2026-09-08 — after D-041 (SFTP protocol)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `swift test --filter SFTPIntegrationTests` | **7 passed** against OpenSSH `internal-sftp` |
| `bash scripts/app-integration-e2e.sh` | **229 passed, 0 failed** |

What the integration tests actually prove, since a hand-written server would have agreed
with whatever the client did: a file written through the protocol is on the real
filesystem byte for byte and readable without the client; a 100,000-byte payload survives
being split across 32 KiB chunks with a partial last write and read; a 400-entry directory
is listed in full, which needs more than one READDIR page; version 3's RENAME refuses to
clobber, which is what makes it usable as the commit step of an atomic upload; `lstat` and
`stat` disagree about a symlink in the way they must; and a missing path comes back as
`noSuchFile` rather than a generic failure.

## 2026-09-08 — after D-040 (backup, restore and recovery)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **199 tests in 30 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **229 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (BackupUITests) | **2 passed** |
| `bash scripts/localization-audit.sh` | **green**, 32 new strings translated into both Chinese variants |
| `xcodebuild … -configuration Release -destination 'generic/platform=iOS' … archive` | **ARCHIVE SUCCEEDED** |

The backup file type `dev.apexterminal.backup` is present in the built `Info.plist`,
verified with `plutil -p`.

## 2026-09-08 — after D-038 (export compliance) and D-039 (input-method composition)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **199 tests in 30 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **217 passed, 0 failed** |
| `bash scripts/localization-audit.sh` | **green** — every string translated in zh-Hans and zh-Hant; the product-name check passes |
| `xcodebuild … -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` | **BUILD SUCCEEDED** |
| `xcodebuild … -configuration Release -destination 'generic/platform=iOS' … archive` | **ARCHIVE SUCCEEDED** (before D-039; re-run pending) |

### Counts, recounted

| What | Number | How |
| --- | --- | --- |
| Package tests | 199 in 30 suites | `swift test` output |
| App unit tests | 217 | `grep -c "' passed on"` |
| Tests against a real LibVNCServer | **5** | `grep -c "@Test" Tests/STVNCTests/VNCClientTests.swift`, suite "VNC client against LibVNCServer" |
| Localisation entries, shipped catalogs | **738** across 6 files | counted from the `.xcstrings` JSON |
| … of which the audit gates | 731 across 3 files | `Localizable` 641 + `STSSH` 49 + `STCloudflare` 41 |

### Verified by watching it fail

* The product-name check in `scripts/localization-audit.sh`: the compact spelling was
  reintroduced into `INFOPLIST_KEY_NSFaceIDUsageDescription`, the audit exited 1 and named
  both lines; removing it again returned exit 0.
* The DES replacement: FIPS 46-3 known-answer vectors pass, and the LibVNCServer
  authentication test still passes, which is what proves the swap is byte-identical where
  it matters.

### Not yet evidence

* Input methods on hardware (H-1). The `UITextInput` calls are covered; a real Pinyin,
  Kana or Hangul keyboard is not.
* Archive after D-039.
