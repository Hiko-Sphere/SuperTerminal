# Final verification report

**Written:** 2026-09-10 · **Repository at:** `8abf4e1` (D-078), working tree not clean ·
**Product:** Apex Terminal 0.1.0 (1), `dev.apexterminal.app`

---

## 0 · Read this first — the assets are finished, and they should not be uploaded today

The material is complete and internally consistent. One thing stands between it and the
App Store, and it is not a marketing problem.

**Every real-`sshd` integration suite in the package is currently failing at HEAD**, with
one shared error. Those suites are the evidence behind eight of the claims this listing
makes.

| | |
| --- | --- |
| Package suite, clean machine | **357 passed, 29 failed** — 41 suites green, 12 red |
| The 12 red suites | all of the real-server integration suites, and only those |
| Shared error | `I/O on closed channel` (×11) and `Already closed` (×3) — one cause, not twelve |
| Introduced | after the project's last recorded green run ("after D-071"); HEAD is D-078 |
| Caused by this work? | **No.** `Packages/` is byte-identical to HEAD; every change here is in `App/`, which the package test target never compiles |

**Claims whose evidence is currently red:** C2 (Secure Enclave keys), C3 (the terminal),
C4 (files), C6 and C7 (tunnels), C13 (certificates), C14 (agent forwarding), C16
(post-quantum KEX).

The claims are not thereby false — they were verified at the commit the audit read, and
the failure is one transport-level fault rather than eight capability regressions. But
"Verified" in this project means *a test exercises it against something real, and passes*.
Until that regression is fixed, eight of these claims do not meet their own bar.

**What to do:** fix the SSH transport regression, re-run `swift test`, and confirm those 12
suites are green. Nothing in `Marketing/Rebuild-2026-09-10/` needs to change when they are —
the assets already say what those tests prove.

---

## 1 · Files created

175 files under `Marketing/Rebuild-2026-09-10/`. The full list is
[`ASSET_INDEX.md`](ASSET_INDEX.md), generated from disk. In summary:

| Area | Files |
| --- | --- |
| `audit/` | truth matrix (201 capabilities), claims matrix, competitor analysis, legacy audit |
| `strategy/` | positioning, messaging system, audience matrix |
| `app-store/` | 3 metadata files, screenshot plan and design, 72 finals, 72 raw captures, 3 contact sheets, 4 preview-video documents, manifest |
| `website/` | information architecture + copy in 3 languages |
| `social/` | evergreen library, launch-day set |
| `press-kit/` | release, kit, media kit, FAQ |
| `feature-catalog/` | catalogue, security overview, internal comparison, internal Cloudflare record |
| `automation/` | fixture, capture, render, validate, two generators |
| root | README, asset index, capture guide, this report |

**Modified outside the rebuild directory** — additive, no shipped behaviour changed:

* `App/Sources/Views/{HostListView,KeyManagementView,PromptSheet,SettingsView,TerminalView}.swift`
  — accessibility identifiers only.
* `App/Sources/Services/UITestSeeding.swift` — already `#if DEBUG`; gained optional
  display-name overrides and a terminal-theme preference.
* `AppUITests/RebuildCaptureTests.swift` — new; skips unless `ST_REBUILD_CAPTURE=1`.
* `.gitignore` — excludes the capture working directories, which hold a throwaway SSH key.

## 2 · Product name

**Apex Terminal**, two words. Confirmed from `INFOPLIST_KEY_CFBundleDisplayName` and from
the title the app draws (`App/Sources/Views/HostListView.swift`). `ApexTerminal` is an
identifier only. `SuperTerminal` is retired and appears in no shipped code or resource.

## 3 · Positioning

> A full SSH workstation for iPhone and iPad: one connection carries your shell, your
> files, your remote desktop and your tunnels — and your keys never leave the device.

## 4 · The five claims the listing rests on

| | Claim | Evidence | Status today |
| --- | --- | --- | --- |
| C1 | One connection carries shell, files, desktop and tunnels | `SSHConnectionPoolTests` | green |
| C2 | A Secure Enclave key cannot leave the device, and still logs in to OpenSSH | `SecureEnclaveKeyTests` — reads `sshd`'s own accept line | **red** (§0) |
| C3 | A real terminal: true colour, sixel, mouse, CJK widths, alternate screen | `TUIIntegrationTests`, `CharacterWidthTests`, fuzz suite | **red** (§0) |
| C4 | Your server's files, in the app and in the Files app | `STSFTPTests`, `FileProviderDomainTests` | **red** (§0) |
| C5 | No account, no back end, nothing measured | proven as an absence by grep | green |

## 5 · Screenshots

**72 final images.** Eight screens × three device slots × three languages.

| Slot | Pixels | Captured natively on | Per language |
| --- | --- | --- | ---: |
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max | 8 |
| iPhone 6.5" | 1284 × 2778 | iPhone 14 Plus | 8 |
| iPad 13" | 2732 × 2048, landscape | iPad Air 13-inch (M4) | 8 |

Languages: `en-US`, `zh-Hans`, `zh-Hant` — the interface in each set is in that language.

## 6 · What the screenshots show

Every screen is a Verified capability photographed from the running app:

1. a live SSH session with real output; 2. a shell, a file browser and a desktop open on one
server; 3. split panes (iPad) / several sessions (iPhone); 4. an SFTP listing; 5. a running
forward with live byte and connection counters; 6. an attached tmux session with its own
panes; 7. a Secure Enclave key with its real fingerprint; 8. a remote desktop over VNC.

Real: every key exchange, every file listing, the forward's traffic (a second SSH session
routed through it), the tmux server, the X session behind the RFB stream. Invented: only
the identities — `deploy`, `edge-01`, `db-primary`, `build-runner`, `ops-box`, all under
`*.localhost` (RFC 6761).

## 7 · Excluded, and why

Present in the binary, absent from every public claim, disclosed to App Review under 2.3.1:

| Excluded | Reason | Unblocked by |
| --- | --- | --- |
| **Cloudflare Access / Tunnel** | No connection has ever been made through a live account. Every passing test runs against a local server reproducing the edge; `LiveCloudflareE2ETests` skips. The entire authentication half — ~950 lines — has no test at all | `docs/HUMAN_ACTIONS.md` H-4 |
| Browser SSO to Access | Same | H-4 |
| iCloud / CloudKit sync | Offline-verified only | H-5 |
| CJK terminal input | Unit-tested; the input methods never exercised on hardware | H-1 |
| macOS Screen Sharing sign-in, VeNCrypt | Tested against vectors, never against a real Mac | H-3 |
| Mac Catalyst | Builds and runs; no signing identity | H-8 |
| visionOS | Offered in compatibility mode, never run | H-9 |
| watchOS | Not started | — |
| The assistant | Never answered from a real provider | B-6 |

Three of the project's own documents overstate Cloudflare coverage by citing test suites
that do not exist. They are recorded as unquotable in the truth matrix.

## 8 · Old material kept, and why

`Marketing/AppStore/` is untouched. Per-file verdicts are in
[`audit/LEGACY_ASSET_AUDIT.md`](audit/LEGACY_ASSET_AUDIT.md). Two things were kept rather
than rewritten for the sake of looking thorough: **the capture method** (drive the real app
through XCUITest against real servers) and **the Cloudflare decision**, which was
re-derived from scratch and reached the same verdict. Its 36 finished images are **Invalid**
— the app's own name is inside the captured pixels, so re-rendering cannot fix them.

## 9 · Claims dropped from the previous set

"SuperTerminal" throughout; a six-screen story that predated SFTP, forwarding, tmux, panes
and enclave keys; and `FEATURE_AUDIT.md`'s reliance on project prose rather than on opening
the cited test — which is how three non-existent test suites went unnoticed.

## 10 · Automated checks

`python3 automation/validate.py` — **passes with 0 warnings**:

* 72 images, each an accepted size for its slot; PNG colour type 2, **no alpha**;
* no capture scaled anisotropically (recomputed from recorded placements, 0.5% tolerance);
* finals newer than the captures they came from;
* field limits: EN 25/30, 26/30, 158/170, 85/100 B, 3983/4000 · zh-Hans 20/30, 13/30,
  81/170, 83/100 B, 1693/4000 · zh-Hant 21/30, 13/30, 76/170, 89/100 B, 1718/4000;
* no forbidden claim in any published field; no competitor named; no secret, email or
  non-loopback address; Chinese punctuation full-width.

## 11 · Visual check

Contact sheets reviewed for all three languages. Four defects found and fixed by
re-capturing: a black VNC frame with a spinner, an iOS keyboard tutorial card covering the
app, a forward shown stopped with zero counters, and an undersized iPad capture. The
current set shows a decoded desktop, a running forward reading `1 open · 3 KB sent ·
4 KB received`, no system overlay, and a larger iPad capture.

## 12 · Still needing a person

| # | Blocker | Unblocked by |
| --- | --- | --- |
| 1 | **The SSH transport regression** (§0) | Fix, then `swift test` green |
| 2 | Support, Marketing and Privacy Policy URLs are not live | Publish `website/`; App Store Connect rejects a listing without them |
| 3 | In-app legal texts carry placeholders | Effective date, legal name, governing law, in three languages, plus counsel review (`PROJECT_STATUS.md` B-5) |
| 4 | Export-compliance answer | The submitter's to give; draft reasoning in each metadata file |
| 5 | Distribution certificate and App Store profile | Only development identities exist (`PROJECT_STATUS.md` B-4) |
| 6 | The App Preview video | Scripts, storyboard and recording commands are written; the video has not been produced |

## 13 · Reproducing everything

```bash
Marketing/Rebuild-2026-09-10/automation/capture.sh                                    # ~50 min
swift Marketing/Rebuild-2026-09-10/automation/Render.swift Marketing/Rebuild-2026-09-10
python3 Marketing/Rebuild-2026-09-10/automation/write_manifest.py
python3 Marketing/Rebuild-2026-09-10/automation/write_asset_index.py
python3 Marketing/Rebuild-2026-09-10/automation/validate.py
```

## 14 · Where everything is

| | |
| --- | --- |
| Screenshots | `Marketing/Rebuild-2026-09-10/app-store/screenshots/<locale>/<slot>/` |
| Contact sheets | `Marketing/Rebuild-2026-09-10/app-store/preview/<locale>-contact-sheet.png` |
| Listing copy | `Marketing/Rebuild-2026-09-10/app-store/metadata/` |
| Website, social, press, catalogue | the directories of those names |
| Provenance | `Marketing/Rebuild-2026-09-10/app-store/SCREENSHOT_MANIFEST.json` |
| Index of everything | `Marketing/Rebuild-2026-09-10/ASSET_INDEX.md` |
