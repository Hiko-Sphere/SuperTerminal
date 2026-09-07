# Feature audit

What this app can actually be said to do, and what it cannot — decided by reading the
code and by looking at what the tests execute, not by reading the README.

**Audited:** 2026-09-06 · **Against:** `SuperTerminal.xcodeproj`, scheme `SuperTerminal`,
Debug and Release both building clean for the iOS Simulator with zero warnings from
project code.

The rule this file enforces: **a claim reaches the store listing only if something was
seen to run.** "The code is written" is not the same as "it works", and the project's own
[`PROJECT_STATUS.md`](../../PROJECT_STATUS.md) keeps those apart deliberately — this audit
keeps them apart too, and throws away everything on the wrong side of the line.

---

## 0 · The app, as it stands

| | |
| --- | --- |
| Product name | SuperTerminal |
| Bundle identifier | `dev.superterminal.app` |
| Marketing version / build | `0.1.0` / `1` |
| Platforms | iOS, iPadOS — `TARGETED_DEVICE_FAMILY = "1,2"` |
| Minimum system | iOS / iPadOS **17.0** (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`) |
| Swift | 6.0 language mode, `SWIFT_STRICT_CONCURRENCY = complete` |
| Team | `7CDDP73WJS`; a Release archive succeeds and carries the iCloud entitlements |
| Languages in the app | **English, Simplified Chinese, Traditional Chinese** — 601 keys in `App/Resources/Localizable.xcstrings`, plus the Shortcuts and Info.plist catalogs; `scripts/localization-audit.sh` fails CI on an untranslated string |
| Assets | `App/Resources/Assets.xcassets` — `AppIcon.appiconset`, `Logo.imageset`, `AccentColor.colorset`. No temporary or placeholder mark was introduced for this work |
| **Money** | **None.** `grep -riE "storekit|in-?app ?purchase|subscription|paywall|SKProduct"` over `App/Sources` and `Packages/SuperTerminalKit/Sources` returns nothing. There is no paywall, no tier, no trial, and no purchase of any kind — so the listing must not imply one, and the review notes say so explicitly |

### Build, run and test, on the day of the audit

```
xcodebuild build-for-testing -scheme SuperTerminal -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'      → TEST BUILD SUCCEEDED, 0 warnings
```

The screenshots in `raw/` are the app from that build, driven through its own interface by
`AppUITests/MarketingCaptureTests`, against three real OpenSSH servers.

---

## 1 · SSH — the core

| Capability | Real? | Code | Test | Advertise? | Screenshot | Risk / limit |
| --- | --- | --- | --- | --- | --- | --- |
| SSH over direct TCP to a real OpenSSH server | **Yes, proven** | `STSSH/SSHConnection.swift`, `DirectTCPTransport.swift` | `SSHIntegrationTests.ed25519KeyAuthenticationRunsCommand` — real `sshd`, real handshake, remote command returns `CF_E2E_OK` | **Yes** | 01 · terminal | — |
| Interactive PTY, correct geometry | **Yes, proven** | `STSSH/SSHShellSession.swift` | `SSHIntegrationTests.interactivePTYSession` — `stty size` on the remote reports the geometry asked for | **Yes** | 01 · terminal | — |
| Resize propagated to the remote program | **Yes, proven** | `SSHShellSession`, `TerminalInputView.reportGridSizeIfChanged` | `SSHIntegrationTests.terminalResizePropagates`; a UI test pinches a live terminal and reads `stty size` before and after | **Yes** | mentioned in copy | — |
| Ed25519 key authentication | **Yes, proven** | `STSSH/SSHAuthentication.swift`, `OpenSSHPrivateKey.swift` | `SSHIntegrationTests.ed25519KeyAuthenticationRunsCommand` | **Yes** | 04 · keys | — |
| ECDSA P-256 key authentication | **Yes, proven** | same | `SSHIntegrationTests.ecdsaKeyAuthentication` | **Yes** | 04 · keys | — |
| RSA (`rsa-sha2-256` / `-512`) | **Yes, proven** | `Packages/swift-nio-ssh-rsa` + `patches/niossh-rsa.patch` | `RSAInteropTests` — an RSA user key authenticates against a real `sshd`; a server offering only an RSA host key is reachable; `ssh-keygen` agrees on the fingerprint | **Yes**, as *supported for keys you already have* | — | `ssh-rsa` (SHA-1) is deliberately **not** supported; the copy must not imply every key type works |
| Passphrase-protected OpenSSH keys (bcrypt + AES-CTR) | **Yes, proven** | `OpenSSHPrivateKey.swift`, `CBcryptPBKDF` | `SSHIntegrationTests.encryptedKeyAuthentication` — a wrong passphrase must fail, which only happens if the KDF is bit-exact | **Yes** | — | — |
| Password authentication | **Yes, proven** | `SSHAuthentication.swift`, `PromptSheet` | `SSHCredentialChainTests`; `BlankFieldsUITests` reaches a shell over real OpenSSH | **Yes** | — | — |
| chacha20-poly1305 and AES-CTR ciphers | **Yes, proven** | `ChaCha20Poly1305TransportProtection.swift`, `AESCTRTransportProtection.swift` | Proved by *removing the alternative*: a server offering only that cipher is reachable and a 400 KB burst stays in sync (`CipherInteropTests`) | **Yes**, as a fact, not a boast | — | Do not turn this into a speed claim |
| Trust on first use records the server's real key | **Yes, proven** | `STSSH/HostKeyVerifier.swift`, `KnownHostsStore.swift` | `SSHIntegrationTests.trustOnFirstUseRecordsKey`; `scripts/app-integration-e2e.sh` proves refusing the prompt fails the session with `.hostKey` and that the fingerprint offered is the server's real one | **Yes** | 03 · host-key | — |
| A **changed** host key is never accepted silently | **Yes, proven** | `HostKeyVerifier.swift:65,95` — the changed case is a distinct decision routed to the user; the file states there is no path that accepts one quietly | `KnownHostsRemoveAllTests`, `SSHIntegrationTests`; the sheet is a separate, deliberately less inviting screen (`PromptSheet.changedHostKey`) | **Yes** | 03 · host-key caption | Say what it does — *asks* — not "protects you from interception" |
| Reconnection after a dropped connection | **Yes, proven** | `STCore/ReconnectionPolicy.swift`, `TerminalSession` | Six integration tests against a real `sshd` through a relay whose sockets are closed underneath the session: it notices, backs off, comes back with scrollback intact, stops when told, and does **not** reconnect when the user typed `exit` | **Yes** | — | Never phrase as "never drops" |
| Free port / pasted `host:port` / blank user name | **Yes, proven** | `STCore/HostAddress.swift`, `Host.swift` | `HostAddressTests`, `SSHCredentialChainTests`, `BlankFieldsUITests` | **Yes** | 02 · sessions (ports visible) | — |
| **SFTP** | **No** | nothing in the tree — `grep -ri sftp App/Sources Packages/.../Sources` is empty | — | **No** | — | `PROJECT_STATUS.md` lists it under "Not started" |
| **Port forwarding** | **No** (as a user feature) | `direct-tcpip` exists only as the channel a remote screen uses | — | **No** | — | Advertising it would be a rejection under 2.3.1 |
| **Agent forwarding** | **No** | not implemented | — | **No** | — | — |

---

## 2 · Cloudflare Access / Cloudflare Tunnel — **not advertisable**

This is the project's headline differentiator, and it is the one thing this listing must
stay silent about.

| Capability | Real? | Code | Test | Advertise? |
| --- | --- | --- | --- | --- |
| WebSocket carrier that turns Cloudflare's transport into a TCP byte stream | Implemented; tested against a local server that reproduces the edge | `STCloudflare/CloudflareCarrierTransport.swift`, `WebSocketByteStream.swift` | `CarrierIntegrationTests` — a full SSH session, a 256 KiB burst, the Access and service-token headers, and each edge failure mode, all against `STTestSupport/WebSocketCarrierTestServer` | **No** |
| Access discovery, JWKS, token validation | Implemented; unit-tested against a controlled identity | `AccessDiscovery.swift`, `JWKS.swift`, `AccessTokenValidator.swift` | unit tests only | **No** |
| Interactive Access login (transfer-service flow) | Implemented; never run against a real account | `AccessLogin.swift`, `BoxCrypto.swift` | none that reach Cloudflare | **No** |
| Access **service tokens**, per connection | Implemented; the *storage* is proven, the *use against Cloudflare* is not | `AccessCredentialResolver.swift`, `HostEditorView` | `ServiceTokenTests` (3) and `ServiceTokenUITests` (1) prove the editor requires, stores and redacts the token and that iOS's password-save sheet never appears | **No** |

**Why not.** No connection has ever been made through a real Cloudflare Tunnel behind a
real Access application. `PROJECT_STATUS.md` records this as blocking issue **B-2**, and
**B-3** records that the no-account shortcut is unavailable: two `trycloudflare.com` quick
tunnels registered successfully and every request to the assigned hostname still came back
as an empty-bodied HTTP 404 from the edge, with nothing reaching the tunnel.
`LiveCloudflareE2ETests` and `scripts/live-e2e.sh` exist and skip cleanly because the
environment is unset.

**Consequence, applied throughout this work:**

* no Cloudflare screenshot, and in particular **no login page presented as a success**;
* the word *Cloudflare* appears in **no** shipped field — not the name, subtitle,
  description, keywords, promotional text or any caption;
* `scripts/validate.py` fails the build if it appears in the copy, so this cannot be
  undone by accident;
* the App Review notes say the capability exists in the binary but is not claimed.

What would change this is listed at the end of this file.

---

## 3 · The terminal

| Capability | Real? | Code | Test | Advertise? | Screenshot | Risk / limit |
| --- | --- | --- | --- | --- | --- | --- |
| VT/ANSI emulation with its own parser and screen | **Yes, proven** | `STTerminal/TerminalParser.swift`, `TerminalEmulator*.swift`, `TerminalScreen.swift` | `TerminalParserTests`, `TerminalEmulatorTests` | **Yes** | 01 · terminal | — |
| Full-screen programs — alternate screen, restore, mid-session resize | **Yes, proven** | `TerminalEmulator+CSI.swift` | `TUIIntegrationTests` — **`vim` and `less` over a real SSH PTY**, with alternate-screen restore and vim honouring a mid-session resize | **Yes** | 05 · vim | Name only programs that were actually run |
| 256-colour / SGR rendering | **Yes, proven** | `TerminalEmulator+SGR.swift`, `TerminalRenderView.swift` | `TerminalEmulatorTests`; every capture shows a coloured prompt and coloured `git`/`ls` output from the real server | **Yes** | 01, 05 | — |
| CJK, emoji and combining-mark cell widths | **Yes, proven** | `CharacterWidth.swift`, `CharacterWidthTables.swift` | `CharacterWidthTests` against generated **UCD 17.0.0** tables — CJK, halfwidth kana, combining marks, ZWJ sequences, flags, variation selectors | **Yes** | — | — |
| Scrollback, with reflow on width change | **Yes, proven** | `TerminalReflow.swift` | `TerminalReflowTests` (9): widening rejoins, narrowing re-wraps, hard breaks survive, round trip is stable, wide characters stay whole, scrollback stays bounded | **Yes** | 06 · find | — |
| Selection, copy, and search across the scrollback | **Yes, proven** | `TerminalTextAccess.swift`, `FindBar.swift` | 11 tests: soft wraps copy without an injected newline, block selection, wide characters copy once, selection reaches into history, **search crosses wraps** and is bounded; UI tests drive long-press-and-drag selection and read the find bar's match count | **Yes** | 06 · find | — |
| Mouse reporting | **Yes, proven** | `MouseReporting.swift` | 10 unit tests over both encodings, modifiers, wheel, drag gating — plus a live round trip where a remote program enables tracking and `cat -v` on the far end shows the exact bytes | **Yes**, in the description | — | Not worth a screenshot; it photographs as nothing |
| Themes | **Yes** | `App/Sources/Terminal/TerminalTheme.swift` — `midnight`, `daylight`, `high-contrast`, with an option to follow the system | `AccessibilityUITests` run the app with Increase Contrast actually on | **Yes**, as "three themes", never "fully themeable" | — | There is no custom-theme editor; do not imply one |
| Measured throughput | **Yes, measured** | `TerminalThroughputTests` | Release build: 14.7 MB/s plain, 33.5 MB/s coloured, 14.9 MB/s CJK; reflow of a 5 000-line scrollback in 17 ms | **Only as "measured"**, with the figure | — | Never "the fastest"; a number with a method behind it is fine, a superlative is not |
| Command history | **Yes, proven**, and **off until asked for** | `SnippetStore.record`, Settings → Terminal | A UI test runs a command, finds history empty and off, turns it on, runs another, and sees exactly the second one — nothing resurrected from before the opt-in; turning it off deletes the file | **Yes**, and worth saying: it is off by default | — | — |
| Snippets | **Yes, proven** | `Snippet.swift`, `SnippetPickerView.swift` | A UI test creates a snippet, taps it, and asserts against a real shell that the text is on the line **and its output is not** — then presses Return and sees the output | **Yes** | — | — |
| Command palette with real fuzzy ranking | **Yes, proven** | `STCore/FuzzyMatch.swift`, `CommandPaletteView.swift` | 13 tests pin the ranking (`wp` → `web-prod-01`, not `wrapper`); a UI test types `dfh` and lands on "Disk Free Here", which a substring filter could not find | **Yes** | captured, not published — see §8 | — |

---

## 4 · Keys, known hosts and the Keychain

| Capability | Real? | Code | Test | Advertise? | Screenshot | Risk / limit |
| --- | --- | --- | --- | --- | --- | --- |
| Key generation on the device (Ed25519, ECDSA P-256) | **Yes, proven** | `STSSH/SSHKeyGeneration.swift`, `KeyManagementView.swift` | Generated keys are read by `ssh-keygen`, which agrees on the fingerprint, and both algorithms authenticate against a real `sshd` that trusts only the generated key; a UI test generates one through the interface | **Yes** | 04 · keys | RSA generation is deliberately absent — do not imply it |
| Import of an existing OpenSSH key, including passphrase-protected | **Yes, proven** | `OpenSSHPrivateKey.swift`, `ImportKeySheet` | `SSHIntegrationTests.encryptedKeyAuthentication` | **Yes** | — | — |
| The private half never leaves the Keychain and is never shown | **Yes, proven** | `STSecureStore/KeychainSecureStore.swift`; `KeyManagementView` shows only fingerprint, algorithm and public half | `ServiceTokenTests` prove the real Keychain stores, loads and deletes, and that secrets are redacted in any description; `STCore/RedactionTests` | **Yes** | 04 · keys | — |
| Explicit Keychain protection classes | **Yes** | `KeychainSecureStore.swift:34-46` — `WhenUnlockedThisDeviceOnly` / `AfterFirstUnlockThisDeviceOnly` / `WhenUnlocked`, and a `SecAccessControl` for the biometric case | Unit + device-class tests | **Yes**, factually | — | Describe the mechanism, not a guarantee |
| A key can be put behind Face ID / Touch ID | **Yes** in code and settings; the **system prompt itself** is a device check | `KeychainSecureStore` `SecAccessControlCreateWithFlags`; `GenerateKeySheet` offers the toggle | `AppLockTests` cover the policy with a biometric check the test controls; the simulator never invokes Face ID | **Yes, carefully** — "can be put behind Face ID", which is what the interface offers and what the screenshot shows | 04 · keys | Must not be phrased as "Face ID protects your keys" without the conditional |
| Known-hosts store, with a removed host staying removed | **Yes, proven** | `KnownHostsStore.swift` | `KnownHostsRemoveAllTests`; a host key removed by hand stays removed across a sync | **Yes**, in the description | — | — |
| App lock — the app's own passcode, behind Face ID or Touch ID | **Yes, proven** (with a stand-in for the biometric check) | `App/Sources/Lock/AppLock.swift` | `AppLockTests` (8): PBKDF2 record and constant-time match, backoff table, five wrong guesses cost thirty seconds, grace period, enabling never locks the current screen. `AppLockUITests` (1) sets a passcode, locks across a relaunch, and unlocks | **Yes**, in the description | — | The real Face ID prompt is a device check; the copy says "passcode, with Face ID or Touch ID in front of it", which is exactly what is implemented |
| Clipboard expiry for copied terminal text | **Yes, proven** | `Services/Clipboard.swift` | `ClipboardTests` (3), including a real copy read back through `UIPasteboard.general.string` | **Yes**, in the description | — | Expiry is enforced by iOS via `expirationDate`; say that |
| Hiding the terminal in the App Switcher | **Yes, proven** | `Views/PrivacyShield.swift` | Covered whenever the scene is not active; the previously unwired toggle now does what it says | **Yes**, in the description | — | — |
| Multi-line paste confirmation | **Yes, proven** | `PastePolicy.swift` | `PasteAndSearchTests`; a drop goes through the same path a paste does | **Yes**, in the description | — | — |

---

## 5 · iPhone and iPad

| Capability | Real? | Code | Test | Advertise? | Screenshot | Risk / limit |
| --- | --- | --- | --- | --- | --- | --- |
| iPad split view — sidebar plus terminal, driven by size class | **Yes, proven** | `Views/RootView.swift` (`NavigationSplitView` when regular, stack when compact) | The whole UI suite runs on an iPad Pro as a CI gate; that run found four defects a phone run could not see | **Yes** | every iPad shot | — |
| Several concurrent sessions | **Yes, proven** | `Services/SessionManager.swift` | The capture run opens three at once against three different servers; `MultiSceneTests` | **Yes** | 02 · sessions | — |
| The server's platform, detected and overridable | **Yes, proven** | `Models/HostPlatform.swift` | `HostPlatformTests` (5); `testConnectingDetectsTheServerPlatform` watches the row change after connecting | **Yes** | 02 · sessions ("Linux · deploy@…") | Linux and Windows live detection beyond this fixture are hardware checks |
| The accessory key row — Escape, Tab, Control, arrows, Home/End, PgUp/PgDn | **Yes, proven** | `Views/AccessoryKeyRow.swift` | A UI test latches ctrl then `c`, interrupts `sleep 30`, and the shell stays responsive | **Yes** | visible in 01, 05, 06 | — |
| Hardware-keyboard shortcuts — ⌘N, ⌘K, ⌘⇧[ / ⌘⇧], ⌘1–9, ⌘W, ⌘= / ⌘- / ⌘0 | **Yes, proven** in the simulator | `Services/AppShortcuts.swift`, `Terminal/HardwareKeyMap.swift` | `HardwareKeyMapTests` (8, one per xterm rule); `HardwareKeyboardUITests` (7) send ⌘K, ⌘N, ⌘, and ↓ as real keys | **Yes**, in the description | — | A real Magic Keyboard and the iPadOS focus engine are on `docs/RELEASE.md`, not in CI — so the copy says the shortcuts exist, not that any particular keyboard is certified |
| Pointer / trackpad on iPad — wheel, clicks, drag, hover | **Written and unit-tested**; **not** drivable by XCUITest | `PointerConfigurationTests` (6), `PointerScrollTests` | Unit level only — iOS gives XCUITest no way to drive a pointer | **Mention only in the description**, never in a caption | — | Listed for hardware in `docs/RELEASE.md` |
| Multi-window on iPad | **Yes, proven** | `RootView`, `openWindow` | A UI test opens a session in a new window and asserts the app's scene count *increases*, through a Debug-only probe | **Yes**, in the description | — | Skipped on devices that do not offer it |
| Reopening the connections from last time | **Yes, proven** | `Services/SessionRestorationStore.swift` | A UI test *terminates* the app, relaunches, finds the offer, taps it and reaches a terminal | **Yes**, in the description | — | What is remembered is which machines were open, not the scrollback — the copy must say so |
| Accessibility — Dynamic Type, Bold Text, Reduce Transparency, labels | **Yes, proven** | throughout; `Design/AccessibilityAdaptation.swift` | UI tests launch with those settings actually enabled and assert every control carries a label; the host list survives `UICTContentSizeCategoryAccessibilityL` | **Yes**, in the description | — | No VoiceOver session has been *heard*; the copy says the terminal exposes its text to VoiceOver, which is what is implemented and tested structurally |

### Layout, looked at rather than assumed

Both devices were driven through every screen in this work. Two things are worth
recording, neither of which is a defect in a screen this listing uses:

* **Command palette on iPhone** — the query field sits well below the top of the sheet and
  the results begin around the vertical middle, leaving a large gap. Nothing is clipped or
  unreachable; it simply reads as loose. That is why the palette is captured but **not**
  published (§8).
* **iPad sidebar search bar** — the `.searchable` field renders as an empty light pill at
  the foot of the sidebar. Again nothing is broken; it is visible at the very bottom edge
  of the iPad captures and is not what any caption points at.

**Chinese screenshots keep two English terms.** The Simplified Chinese host-key sheet
reads "请核对下方的 fingerprint 与服务器上的是否一致" and labels the card "服务器
fingerprint"; elsewhere the app says "host key 已变更". That is not a missed translation —
`DECISIONS.md` **D-014** records it as a rule: technical identifiers a user copies or
compares are deliberately left in English, and the localization audit that gates CI is
written around that rule. It appears in screenshot 03 of the Chinese set and is left
exactly as the app renders it. Changing the app's translations to make a screenshot read
better would be the wrong way round.

Neither layout observation was changed for the sake of a screenshot.

---

## 6 · Everything else in the binary that is *not* being advertised

| Capability | Why it is excluded |
| --- | --- |
| **Remote screens over VNC** | Real and thoroughly tested — `STVNCTests` (13 tests / 18 cases) against LibVNCServer, every encoding decoded pixel for pixel, plus authentication, input and cut text. But it has never been run against a Mac's Screen Sharing or a Linux desktop, and macOS's own sign-in and VeNCrypt are verified only against vectors and a second implementation (D-031). A listing that shows a terminal app and claims remote desktops invites a reviewer to try it against a Mac, which is exactly the path that has not been walked. |
| **The assistant** | Has never produced an answer from a real provider: the wire behaviour is proven against a local server, a live answer needs an API key the owner supplies, and the on-device path needs a device eligible for Apple Intelligence (`PROJECT_STATUS.md` B-6). Not advertisable. |
| **iCloud sync** | The engine, its conflict rules and the CloudKit mapping are covered by 27 tests against an in-memory transport; CloudKit's own behaviour has never been exercised (B-4 — two signed devices and a production schema are needed). Not advertisable. |
| **Siri and Shortcuts** | `AppIntentTests` (3) cover the intents; the spoken phrases are a device check. Excluded to keep every claim reproducible by a reviewer. |
| **The first-run tour** | Landed in the working tree during this audit (D-033). It is real, but it is onboarding, not a reason to install, and it is not in the last committed build. Left out. |
| **Instruments profile numbers** | Real measurements, but a profile is not a product claim. |

---

## 7 · Sensitive-data posture of the capture

Every screenshot was taken against `Marketing/AppStore/scripts/fixture/` — three
containers running real `openssh-server`, each with:

* an invented, unprivileged account, `deploy`, created inside the image;
* an invented machine name — `edge-01`, `db-primary`, `build-runner`;
* addresses under `*.localhost`, which RFC 6761 reserves and the host resolves to the
  loopback address, so no public IP and no real domain can appear;
* a home directory written by `seed-home.sh`: an invented Go service, an invented git
  history with an invented author at `example.invalid`, and a three-line notes file.

Nothing on any screen belongs to the person who ran the capture: not a user name, not a
host name, not a command history, not a key. The one key that exists is generated per run
into `Marketing/AppStore/build/` and is authorised only inside the containers.
`scripts/validate.py` scans every line of copy for private keys, tokens, JWTs and email
addresses, and fails the run on a match.

---

## 8 · Captured but not published

`raw/` holds four more images than the listing uses. They are kept because they are
evidence that the features behind them run, and because a future version of the listing
may want them.

| Shot | Why it is held back |
| --- | --- |
| `palette` | The feature is real and well tested, but the sheet's iPhone layout leaves a large gap (§5) and the shot does not read well at thumbnail size. |
| `htop` | Genuine, and a good demonstration — but the fixture container runs five processes, so the table is short and the screen looks half-empty. Fixing that would mean starting processes purely to be photographed. |
| `key-created` | The screen that shows a new key's public half. A second key screen in a six-image story is one too many. |
| `editor` | The connection editor. Useful, but it is a form; it sells nothing at thumbnail size. |

---

## 9 · What would let Cloudflare be advertised

Nothing in this repository can unblock it. What is needed is listed in
`PROJECT_STATUS.md` under "What is needed from the project owner", and reduces to a live
environment plus a credential:

1. an **Access-protected SSH hostname** fronted by a Cloudflare Tunnel whose ingress
   points at a **test** SSH server — `ST_LIVE_CF_HOSTNAME`;
2. an **Access service token** (client id + secret) authorised by that application's
   policy — `ST_LIVE_CF_SERVICE_TOKEN_ID`, `ST_LIVE_CF_SERVICE_TOKEN_SECRET`;
3. an **SSH credential for that host** — `ST_LIVE_SSH_USER` plus a key path or a password.

With those exported in a shell, `scripts/live-e2e.sh` runs today and
`LiveCloudflareE2ETests` stops skipping. A green run there is what turns "implemented"
into "verified", and only then may a Cloudflare screenshot be captured — from the real
connected session, never from the login page — and the word added to the copy.
The exact request, with nothing speculative in it, is in
[`copy/app-review-notes.en-US.md`](copy/app-review-notes.en-US.md) and in this project's
final report.
