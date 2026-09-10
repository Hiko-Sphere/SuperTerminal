# Project status

**Updated:** 2026-09-10 · **Phase:** 5 of 7 in progress — the app is driven end to end
through its own interface on iPhone and iPad; iCloud sync (opt-in, offline-verified), the
legal texts with a consent gate, clipboard expiry, Access service tokens, hardware
keyboard and pointer support (xterm modifiers, app shortcuts, wheel, clicks, drag),
server platform detection with a hand-set override, an assistant for commands and output
(on-device model where eligible, else a user-supplied provider), Siri and Shortcuts
intents, remote screens over VNC — through the SSH connection, with touch, keyboard and
pointer — and an app lock with a passcode of the app's own behind Face ID or Touch ID are
delivered. What remains needs the owner: a live Cloudflare environment (B-2), two signed
devices and a production CloudKit schema for the live iCloud checks (B-4 — archiving and
the entitlements are now proven), and the legal placeholders with counsel review (B-5).

**Where the plan stands (2026-09-10, after D-072):** every item in
`docs/EXECUTION_PLAN.md` is either **done** or blocked on something only the owner can do.
Phase 3 is complete — shell integration, synchronised output, sixel/Kitty/iTerm2 pictures, the
font system, and a fuzz suite that was shown to catch a deliberately broken invariant. Phase
1.1's last gap, several remote folders at once, is closed. Mac Catalyst builds, launches and
runs 316 of its 324 unit tests on a Mac; visionOS is offered in Apple's iPad compatibility mode
and has never been run; watchOS is not started and says why. What is left is H-1 to H-9 in
`docs/HUMAN_ACTIONS.md`: a device for input methods and Files, a Mac Catalyst signing identity,
biometrics, a real VNC server, a Cloudflare tenant, a CloudKit container, and the visionOS and
watchOS simulator runtimes.

**Last full regression (2026-09-10, after D-071):** `ApexTerminalTests` **340 in 65 suites**,
0 failed, against a real `sshd` and a containerised OpenSSH with PAM; `ApexTerminalUITests`
**57 passed on iPhone 17 Pro and 58 on iPad Pro 13-inch (M5)**, 2 failed on each — both of them
another session's `ZZSearchProbeUITests`; localisation complete in every language; **0**
warnings from the app, its unit tests and its UI tests; Release **archive succeeded**. The
per-commit record, with what each number was measured by, is `docs/RELEASE_EVIDENCE.md` — the
figures in the tables further down this file were measured on the dates they name and are not
all current.

Known failures, none in this change:

* `ZZSearchProbeUITests` (2 cases) belongs to another session's uncommitted work and is not
  part of any commit here.
* ~~The two hardware-keyboard failures~~ — **fixed in D-050.** The cause was measured, not
  guessed: XCUITest's first modifier-bearing key press to a screen is discarded, so the
  tests now spend it on a keystroke that means nothing. Both suites pass three runs out of
  three. See `docs/DEVELOPMENT.md` for the eight probes that established it.
* On iPad, `BlankFieldsUITests` and `SnippetUITests` depend on the Simulator's global
  "Connect Hardware Keyboard" preference in *opposite* directions — measured, one setting
  each way, each test in isolation — so the iPad suite cannot be green either way until
  both are made independent of it. Pre-existing; it surfaced while verifying D-033.

This file is the resumable state of the work. It records what is *proven*, what is
*written but unproven*, and what is *not started* — kept separate on purpose, because
"the code is written" is not the same as "it works".

---

## Where things actually stand

### Proven by execution

| Capability | Evidence |
| --- | --- |
| Ed25519 key authentication against real OpenSSH | `SSHIntegrationTests.ed25519KeyAuthenticationRunsCommand` — real `sshd`, real handshake, remote command returns `CF_E2E_OK` |
| ECDSA P-256 key authentication | `SSHIntegrationTests.ecdsaKeyAuthentication` |
| **Agent forwarding, with this device as the agent** | `AgentForwardingTests` (D-052) — `ssh-add -l` run on a real OpenSSH server lists the key by the fingerprint this device holds, with a control showing the same command finding no agent when forwarding is off |
| **Keyboard-interactive, multi-round** | `KeyboardInteractiveTests` (package) and `KeyboardInteractiveAuthTests` (app, D-051) — stock OpenSSH in a container accepting *only* `keyboard-interactive`, with PAM asking for a password and then a one-time code. Public key and password are both off there, so a login is evidence about this method alone |
| **A key held in the Secure Enclave authenticates to real OpenSSH** | `SecureEnclaveKeyTests` (package) and `SecureEnclaveAuthTests` (app, D-049) — a key generated inside the enclave, only its public half given to `sshd`, and the server's own log asserted: `Accepted publickey … ECDSA SHA256:<that key's fingerprint>`. The *biometric* policy is not covered: the Simulator has no LocalAuthentication, so it is H-7 |
| Passphrase-protected OpenSSH key import (bcrypt + AES-CTR) | `SSHIntegrationTests.encryptedKeyAuthentication` — a wrong passphrase must fail, which only happens if the KDF is bit-exact |
| Interactive PTY allocation | `SSHIntegrationTests.interactivePTYSession` — `stty size` on the remote reports the geometry we requested |
| Terminal resize propagation | `SSHIntegrationTests.terminalResizePropagates` |
| Trust-on-first-use records the server's real host key | `SSHIntegrationTests.trustOnFirstUseRecordsKey` |
| SSH over the WebSocket carrier | `CarrierIntegrationTests` — a full session, a 256 KiB burst, the Access and service-token headers, and each edge failure mode |
| The terminal runs real full-screen programs | `TUIIntegrationTests` — `vim` and `less` over a real SSH PTY, with alternate-screen restore, mid-session resize honoured by vim, and CJK/emoji rendering |
| Unicode cell widths | `CharacterWidthTests` against generated UCD 17.0.0 tables — CJK, halfwidth kana, combining marks, ZWJ sequences, flags, variation selectors |
| Package builds clean under Swift 6 strict concurrency | `swift build` — zero errors, zero warnings from project code |
| Whole suite | 157 tests in 22 suites, 12.0s; the live Cloudflare suite skips cleanly without credentials |
| **The app itself connects** | `scripts/app-integration-e2e.sh` — on an iPhone 17 Pro simulator, the app stores a key in the real Keychain, opens a session, allocates a PTY, and the emulator renders `APP_STACK_OK` and `28 90` from the remote host |
| The host-key prompt gates the connection | Same suite: refusing the prompt fails the session with `.hostKey`, and the fingerprint offered matches the server's real one |
| App launches on iPhone and iPad | Installed and launched on both simulators; UI tests pass |
| Debug and Release both build | Simulator and unsigned device builds, zero warnings from app code |
| **The UI reaches a live terminal** | `scripts/ui-terminal-e2e.sh` — XCUITest taps a connection, the terminal appears, typed text reaches the server and `UI_TERMINAL_READY` renders back; screenshot attached to the result bundle |
| The on-screen Control key sends control characters | Same suite: latching ctrl then `c` interrupts `sleep 30` and the shell stays responsive |
| The host list survives an accessibility text size | Same suite, relaunched at `UICTContentSizeCategoryAccessibilityL` |
| Reflow on column change | 9 tests: widening rejoins, narrowing re-wraps, hard breaks survive, round-trip is stable, wide characters stay whole, attributes and cursor follow, alternate screen is left alone, scrollback stays bounded |
| Selection, copy and scrollback search | 11 tests: soft wraps copy without an injected newline, block selection, wide characters copy once, selection reaches into history, search crosses wraps and is bounded |
| Mouse reporting | 10 unit tests covering both encodings, modifiers, wheel, drag/motion gating and the legacy coordinate ceiling — plus a live round-trip: a remote program enables tracking, and `cat -v` on the far end shows the exact bytes a real terminal would have sent |
| CI | `.github/workflows/ci.yml` — package build/test with a zero-warning gate, app Debug and unsigned-Release builds, both integration suites, and hygiene checks for placeholders and committed secrets |
| iCloud sync engine — merge, tombstones, held host-key conflicts, canonical payloads | 27 tests: `SyncEngineTests` (11, in-memory transport), `CloudKitMappingTests` (5), `AppSyncStoreTests` (11), `KnownHostsRemoveAllTests` (2). The signed archive carries the iCloud entitlements and the container, verified off the archive itself; CloudKit's own behaviour is still **not** live-verified, which needs two signed devices — B-4 |
| Legal texts bundled in en / zh-Hans / zh-Hant, parsed and rendered | `LegalDocumentBundleTests` (11) prove every file is in the bundle, comment-free, substantial and free of any way to contact anyone; `MarkdownDocumentTests` (3); CI fails if the bundled notices drift from `THIRD_PARTY_NOTICES.md`. The texts were re-verified against the code in D-056: the iCloud sections described a switch this build does not offer |
| A pane holds anything | `SplitTargetTests` (8) and `SplitWithUITests` (1, both devices): ⌘D still opens another shell on the same server, and ⌥⌘D — or *Split With…* — asks instead, offering anything already open, any saved connection or screen, and a server or screen **not in the list yet**, whose editor result goes straight into the pane. A pane whose session ended offers to show something else *there* rather than beside it |
| The File Provider extension no longer aborts | It used to be killed by the system once per test run, written off as a simulator artefact. It was a missing `NSExtensionFileProviderSupportsEnumeration` (D-073), and the daemon's decision code is identical on a device. Measured: the domain now comes back `(disabled,replicated,…)`, the "will fallback" log line is gone, and a full regression adds **no** new crash report where every previous one added exactly one |
| CloudKit writes carry their change tag, and refusals are read | `CloudKitConflictTests` (5, offline): an update is written on top of the server's own record rather than as a new one — without which every write after the first would have been refused for ever — a queued record is removed when taken, and failures are collected and handed over once. `CKSyncEngine` reports per-record and per-zone failures on its events, which the transport used to drop entirely (D-075) |
| Several file browsers at once | `MultipleFileBrowsersTests` (5): two browsers on the same server are two sessions rather than one moved, closing one leaves the other, the arrangement can show a browser and replaces what was there, two can sit side by side in panes, and a route and a pane say the same thing about one. `FileBrowserTabsUITests` (1) opens two against the harness's `sshd`, requires both to reach a directory, finds both listed, and closes one |
| The Mac | The app builds for Mac Catalyst, launches on a Mac and runs **316 of its 324 unit tests** there. The eight that fail are `errSecMissingEntitlement`, from a build that had to strip entitlements to get past signing; the UI suite cannot run there at all, because XCUITest will not load a test bundle whose team differs from the runner's. **H-8** is what a signing identity would unlock. The Files-app feature is genuinely absent on Catalyst and the connection editor says so in all three languages |
| The parser under fire | `FuzzTests` (4 tests, 8 cases): a megabyte of random bytes per seed, sequences assembled from real introducers with random parameters and terminators, resizes interleaved with input, and each picture protocol opened and then fed noise. The invariants are checked after every step — size, cursor, scrollback limit, picture budget — and the suite was shown to be capable by breaking the cursor clamp and watching it fail |
| Pictures in the terminal — sixel, Kitty, iTerm2 | `SixelTests` (8) decode what ImageMagick encoded, byte for byte, and refuse what would not fit; `KittyGraphicsTests` (7) cover chunked transfer, the three formats agreeing with each other, the refusals and the replies; `TerminalGraphicsPlacementTests` (10) cover where a picture goes, that it scrolls into history, that writing over it splits the strip, and that the store is bounded. `GraphicsSessionTests` (2) drive a real `sshd`: a sixel from the shell becomes a picture, and the server sees the pixel size through `TIOCGWINSZ`. `GraphicsUITests` (1) reads the app's own screen pixels and finds the block |
| The font the terminal draws with | `TerminalFontTests` (9): monospaced is measured rather than believed (Menlo and Courier pass, Helvetica does not), every family the picker offers is one the grid can use, a font that is gone falls back instead of failing, the cell is measured from the family actually chosen, a line height cannot collapse the cell to nothing, and the sample in Settings is built from the same metrics the grid uses. `FontUITests` (1) changes the line height through Settings and asks the remote `stty` — fewer rows, the server was told, and the sample grew with it |
| Shell integration — OSC 7, 52, 133; DEC 2026, 1004 | `ShellIntegrationTests` (8) and `SynchronisedOutputTests` (4) in the emulator, including that an OSC 52 *read* is refused and not even reported, and that DECRQM answers 0 for modes this terminal does not implement. `ShellIntegrationSessionTests` (4) drive a real shell over SSH: the working directory arrives, a clipboard write is refused by default and said so once, allowed when permitted, and an OSC 133 exit status is recorded |
| Links, Spotlight, Handoff | `IncomingURLTests` (6) for parsing and the authorisation rule, `LinkCoordinatorTests` (6) for what the app does with a link, `ActivityTests` (5) for search results and handovers, `AppIntentTests` (6) including the snippet shortcut. `LinkUITests` (2) drive the whole path: a link carrying a command asks first and runs nothing when refused, and runs on the real server when allowed |
| What a server may open towards the device | `InboundChannelRefusalTests` (4), against a server written to misbehave: a `forwarded-tcpip` for a port nobody forwarded is refused, an `auth-agent` channel is refused where agent forwarding was never turned on, a server-opened `session` is refused, and a forward that *was* asked for is accepted — but only for its own port and address. Each refusal leaves the connection usable, so refusing is not a way to be disconnected |
| tmux in the app | `TmuxHostRecordTests` (3), `TmuxRoutingTests` (2), `TmuxSeedingTests` (2) and `TmuxAttachTests` (1, against a real tmux in a container: attach, type, read the shell's output back, split, detach). `TmuxUITests` (1) opens a tmux connection through the interface, splits from the toolbar menu, and waits for the second pane to appear |
| tmux workspace — windows, panes, a terminal each | `TmuxWorkspaceTests` (5) against a real tmux: a fresh session, reattaching to one that already has windows and a split, splitting, typing and reading back what the shell printed, and resizing the client. Three defects it found are described in `docs/RELEASE_EVIDENCE.md` — out-of-order writes, a reload that returned before loading, and a stale layout change replayed over newer state |
| tmux control mode, the protocol | `STTmux`: `TmuxControlParserTests` (11) against transcripts from a real tmux 3.3a, `TmuxLayoutTests` (6) including tmux's own layout checksum, `TmuxControlSessionTests` (7) for the reply bookkeeping, and `TmuxIntegrationTests` (5) driving a real tmux over a real SSH connection to a real OpenSSH server in a container. **The app does not offer tmux yet** — this is the protocol, and nothing in the interface claims otherwise |
| User guide, in the app and in the repository | `UserGuideParsingTests` (3) and `UserGuideBundleTests` (6, three of them run once per language): each language parses, the three carry the same eighteen topics in the same order, every topic has a symbol, the shortcut table names shortcuts the app actually binds, and each translation is at least 30% of its English topic's length — the ratio, not a flat count, because Chinese says the same thing in roughly half the characters. `UserGuideUITests` (1) opens it from Settings, searches for a word that appears only in one topic's body, and reads that topic; `HardwareKeyboardUITests` covers ⌘/. CI regenerates `docs/USER_GUIDE.md` and fails if it has drifted from the file the app parses |
| Consent gate and Settings → Legal | `ConsentUITests` (2): a fresh install is gated, the notice renders, acceptance persists across a relaunch, licences open from Settings |
| App Switcher snapshot protection | `PrivacyShield` covers the window whenever the scene is not active; the previously unwired toggle now does what it says |
| Cloudflare Access service tokens, per connection and per device | `ServiceTokenTests` (3): a record written before the field existed decodes; the field round-trips; the real Keychain stores, loads and deletes a token and the secret is redacted in any description. `ServiceTokenUITests` (1): the editor requires the token before saving, saves it, and on reopening reports it as stored without showing it, and iOS's password-save sheet never appears (it did, until every secure field opted out of AutoFill). The carrier's service-token headers were already covered by `CarrierIntegrationTests` |
| Hardware keyboard and pointer | `HardwareKeyMapTests` (8, one per xterm rule: modified arrows, tilde keys, function keys, control bytes, Meta, editing keys, Command never sent); `PointerConfigurationTests` (6): wheel recogniser without touches, indirect-pointer drag, secondary and middle click, edit menu and beam pointer, standard edit actions; `HardwareKeyboardUITests` (7): ⌘K, ⌘N, ⌘, and ↓ in the palette sent as hardware keys pass; Escape / Return in the palette and ⌘K with a text field focused are strict expected failures naming a measured instrument limit. Pointer gestures cannot be driven by XCUITest on iOS — listed for hardware in `docs/RELEASE.md` |
| Clipboard expiry for terminal text | `ClipboardTests` (3): the option mapping, and a real copy in the app host read back through `UIPasteboard.general.string`; the UI copy test reads its selection back the same way. Expiry is enforced by iOS via `expirationDate`, 60 s by default, configurable in Settings → Security |
| **Throughput, measured on the real path** | Release: 14.7 MB/s plain text, 33.5 MB/s coloured, 14.9 MB/s CJK, reflow of a full 5 000-line scrollback in 17 ms — all fed as `Data`, which is what the app feeds. The earlier figures in this table were measured on an `Array`, a path the app never takes and which was far slower, so they understated the product. Both paths are now benchmarked, and their parity is asserted as a ratio rather than a fixed number |
| **Render cost, measured** | A full redraw of both an 80×24 and a 200×55 grid fits inside a 60 Hz frame on the simulator; run coalescing is asserted directly on the run count |
| Selection and find gestures | UI tests: long-press-and-drag selects and offers Copy, and the find bar reports a match count |
| **chacha20-poly1305, proved by removing the alternative** | A real OpenSSH server offering *only* `chacha20-poly1305@openssh.com` is reachable, and a 400 KB burst over it stays in sync. This is the only cipher needing more key than one digest provides, so the same handshake proves the RFC 4253 § 7.2 key extension added to the vendored key exchange. Built from libsodium's primitives, not RFC 8439's AEAD, which cannot express OpenSSH's construction |
| **AES-CTR ciphers** | Proved by removing the alternative: a server offering *only* `aes256-ctr` with encrypt-then-MAC is reachable, and a 400 KB burst over it stays in sync — which is what catches a counter advanced wrongly |
| **Accessibility, run for real** | UI tests launch the app with accessibility text sizes, Reduce Transparency and Bold Text actually enabled, and assert every control carries a label. Screenshots are attached to the result bundle. |
| **Key generation, import and export** | Generated keys are read by `ssh-keygen`, which agrees on the fingerprint, and both algorithms authenticate against a real `sshd` that trusts only the generated key. A UI test generates one through the interface. |
| **Snippets insert without running** | A UI test creates a snippet through the editor, taps it, and asserts against a real shell that the text is on the line *and its output is not* — then presses Return and sees the output appear. The default that a snippet waits for Return is the safety property, so it is tested by observing the absence. |
| **Command history is off until asked for** | A UI test runs a command, finds history empty and off, turns it on through Settings, runs another command, and sees exactly the second one — recorded as typed, with no prompt and no output, and with nothing resurrected from before the opt-in. Turning it off deletes the file, not just the list. |
| **Profiled with Instruments, for real** | `scripts/profile-emulator.sh` records a Time Profiler trace and attributes it to our own frames: 3.16 s of CPU, 99.6% symbolicated, 53.6% in the parse loop and 12.4% in `CharacterWidth.of`. The leaf frames say why — over a fifth in malloc/free and `_StringGuts`, because the parser deals in `Character`. Recorded rather than acted on: the throughput floors are met with room to spare, and rewriting the code every byte passes through is not an end-of-session change |
| **One haptic vocabulary** | Seven ad-hoc feedback generators scattered through the views, none warmed up and none respecting a preference, replaced by a named vocabulary with a setting. Generators are prepared before the gesture that will fire them, because a haptic played cold arrives a beat late and reads as a bug |
| **Keyboard shortcuts that land where you expect** | ⌘N, ⌘K, ⌘⇧[ / ⌘⇧], ⌘1–9, ⌘W, ⌘= / ⌘- / ⌘0 as one `AppShortcut` table exposed as SwiftUI shortcut buttons in the shell and as key commands on the terminal view, routed to one handler, reachable from a hardware keyboard whatever has focus, on iPhone and iPad; `HardwareKeyboardUITests` type ⌘K, ⌘N, ⌘,, ⌘K over a focused search field and Escape as real keys. SwiftUI `Commands` never received them, nor did `keyCommands` on the SwiftUI-wrapped application delegate — found by those tests. A hidden first-responder view was the first mechanism and was measured out: it exposed an iPadOS 26 focus-engine abort with a hardware keyboard (5 of 18 runs; 0 of 17 without it), see D-018 |
| **The server says what it is, and can be overruled** | `HostPlatformTests` (5): `uname -s` and `cmd /c ver` output from macOS, Linux, the BSDs and Windows read into a platform, both Windows shells' complaints rejected, old records decode, the hand-set value wins, no store churn on repeats. `testConnectingDetectsTheServerPlatform` watches the row say macOS after connecting to this Mac's OpenSSH; `testServerPlatformCanBeSetByHand` sets Windows in the editor and sees the row change. Linux and Windows live detection are hardware checks (D-019) |
| **An assistant for commands and output, honest about where it runs** | `AssistantTests` (5): prompt builder (platform, last command, fenced context, top-cut), reply parser (fenced lines only), and the provider client against a real local HTTP server — streamed deltas, key in the header only, model and stream flag in the body, 401 error message, no request without a key. `AssistantUITests` (1): with no eligible on-device model and no key, the sheet says why and offers Settings. A real provider answer and the on-device model are hardware checks (B-6, D-020) |
| **Blank means "ask": free port, pasted addresses, optional user name and credentials** | `HostAddressTests`, `SSHCredentialChainTests`, `HostModelTests`, `BlankFieldsUITests`: `host:port` in the hostname field, blank port taking the transport's default, blank user name asked for on opening, `none` offered so the server says what it takes, shell reached over real OpenSSH (D-024) |
| **The terminal keeps the keyboard, follows the session on screen, and takes a wheel** | `PointerScrollTests`, `HardwareKeyboardStateUITests`: scrolling arithmetic a wheel needs, the drag interaction following the selection, typing that still reaches the shell after the find bar, the palette and a sheet have taken focus, and typing that follows the session shown (D-025). A real keyboard, mouse and the iPadOS focus engine are device checks |
| **A screen can have its own Cloudflare Tunnel, and takes a keyboard unasked** | `ScreenConnectionTests`, `VNCTests`: the third route and its defaults, first responder held with the on-screen keyboard down, wheel notches accumulating across gestures (D-029). The live tunnel is B-2; a real keyboard and mouse are device checks |
| **A first-run tour, once, skippable, and findable again** | `TutorialTests`, `TutorialUITests`: six pages as content rather than layout, the preference off on a fresh install and cleared by a reset; the real tour paged through end to end, skipping gating nothing, and Settings → Help reopening it (D-033). Read on screen in both appearances |
| **iCloud sync is withdrawn, not half-shipped** | `SyncAvailabilityTests`: a preference left over from a build that offered it starts no engine, asking to turn it on is refused and does not quietly set the preference, and the whole path below the flag is still compiled and still under test (D-037). The switch is shown, disabled, and says why |
| **A failed iCloud sync says what to do** | `SyncFailureTests` (6, pure): every actionable CloudKit code becomes its action, transient ones say they retry, a partial failure reports the item's reason, and no message leaks a type name or pointer (D-032) |
| **A screen decodes fast enough to keep up with a desktop** | `VNCThroughputTests`, `RFBReceiveTests`: a full 1080p frame in every encoding against a per-encoding floor — Raw 4131 fps (was 100), a worst-case ZRLE frame 800, Hextile 4107, image creation 6819 — each also checking the picture it decoded; and a frame fed in 16 KB segments costing no more than the same frame whole (D-030) |
| **A screen may sign in to an account, never in the clear** | `VNCAuthenticationTests`, `ScreenConnectionTests`, `VNCUITests`: macOS Screen Sharing's Diffie-Hellman exchange against vectors from an arbitrary-precision implementation and end to end against a server half that decrypts it, FIPS-197 AES, the security-type choice as a table, VeNCrypt driven through the real handler — including Plain refused on an unencrypted route with the password never written (D-031). A real Mac and a real VeNCrypt server are device checks |
| **Remote screens are their own connections** | `ScreenConnectionTests`, `VNCUITests`: the record and store, the derived id two devices agree on, migration out of the SSH connection with the password moved, and the screen opened from its own row through the SSH connection it names (D-027) |
| **App lock: passcode, Face ID or Touch ID** | `AppLockTests` (8): PBKDF2 record and constant-time match, policy and backoff tables, grace period, five wrong guesses cost thirty seconds, biometrics pass/fail/off with a fake check, setting without record locks nothing, a showing lock is released when the record or setting goes and enabling never locks the current screen. `AppLockUITests` (1): passcode set in Settings, lock across a relaunch, wrong then right passcode, locked again after leaving (D-023). Face ID is a device check |
| **Remote screens (VNC) with touch, keyboard and pointer** | `STVNCTests` (13 tests (18 cases)) against LibVNCServer: every encoding decodes the pattern pixel for pixel, incremental updates, VNC Authentication accepted/refused/required, input and cut text in the server's log, server loss reported; hand-built rectangles for every decoder. `VNCTests` (5): record, key table, recognisers, point mapping. `VNCUITests` (1): the seeded connection's screen through the SSH connection, name and size decoded, tap and keys in the server's log (D-022). macOS Screen Sharing and a Linux desktop are hardware checks |
| **Siri and Shortcuts** | `AppIntentTests` (3): connection query by name/hostname exposing only name and subtitle; Connect opens one session, records it, parks it for the next window, never doubles; Disconnect All's dialog. Phrases are a device check (D-021) |
| **Simplified and Traditional Chinese, gated** | 385 strings across the app and the two error-producing packages. Keys come from the compiler's `.stringsdata`, not the source, because interpolation becomes `%@` before lookup. `scripts/localization-audit.sh` fails CI on any untranslated string. Three UI tests run the app in each locale against a real server — including the assertion that Traditional shows 連線 and no 连接, which is what catches a converted rather than translated catalog. Terminal output is never translated |
| **`NSFaceIDUsageDescription`, which was missing** | The app gates keys behind Face ID and had no usage description — iOS terminates an app that invokes Face ID without one. No test had reached it because the simulator never invokes Face ID. Added and localized |
| **A command palette that actually ranks** | ⌘K over connections, open sessions, snippets and actions, with real fuzzy scoring — 13 tests pin the ranking against realistic names, so `wp` finds `web-prod-01` rather than `wrapper` and `dps` finds `docker ps`. The matched characters are bolded, which is what makes a fuzzy result legible instead of arbitrary. A UI test types `dfh` and lands on a snippet called "Disk Free Here" — a substring filter would find nothing at all |
| **The connections from last time are offered back** | A UI test opens a session, *terminates* the app rather than backgrounding it, relaunches, and finds the offer — then taps it and reaches a terminal, with the offer gone afterwards. What is remembered is which machines were open, not the scrollback: the buffer is the same asset as command history but far larger, and writing it to disk would make the app's refusal to keep history meaningless |
| **Pinch to resize, and the server is told** | A UI test pinches the live terminal and reads `stty size` from the shell before and after: the column count really drops. A font change alters the size of a cell without changing the view's bounds, so `layoutSubviews` never runs — without an explicit re-measure the remote program would go on wrapping to the old width |
| **Text drags out and drops in** | `UIDragInteraction` lifts the current selection with a snapshot of the selected cells; a drop goes through the same path a paste does, so a multi-line drop is confirmed exactly as a multi-line paste is. A drop that skipped that would run several commands on one gesture with no warning |
| **A dropped connection comes back on its own** | Six integration tests against a real `sshd`, with the traffic running through a relay whose sockets are closed underneath the session — a connection that really dies, not a state flag set by hand. Proves it notices, retries with backoff, comes back with the scrollback intact, gives a working shell, stops when told, retries at once when the network returns, spends no attempts while offline, and does **not** reconnect when the user types `exit` |
| **A second window on iPad is a real second window** | A UI test opens a session in a new window and asserts the app's scene count *increases* — through a Debug-only probe, because a screenshot of the result looks identical whether a scene was created or the menu item did nothing. Selection is per window; a session is displayed by one window at a time so two windows cannot resize the remote program against each other |
| **The iPad layout is tested, not assumed** | The whole UI suite runs on an iPad Pro as a CI gate. Adding that run found four defects the phone run could not see: a snippet row where only the text was tappable, an open-session row that would not select, no Control key at all on a full-screen iPad, and ⌘W listed in the menu with nothing behind it |
| **Typed commands are reconstructed, not scraped** | 12 tests over the keystroke accounting: character-at-a-time, whole-line chunks, multi-line pastes, backspace, `^C`/`^D`/`^Z`/`^U`, and escape sequences. A line the remote line editor may have changed — history recall, cursor movement, tab completion — is dropped rather than guessed at. |

### Written, builds, not yet proven end to end

| Capability | What is missing |
| --- | --- |
| Cloudflare Access discovery, JWKS verification, token validation | Unit tests against a controlled identity; live run against a real Access application |
| Cloudflare interactive login (transfer-service flow) | A real Cloudflare account with an identity provider |
| Cloudflare WebSocket carrier | Tests against the local carrier server; then a live tunnel |
| Keychain secure store | Device tests (Keychain behaves differently in a macOS unit-test process) |

### Written and running, but not yet verified against a person

Double-tap to select a logical line is implemented and unit-tested at the model level but
not driven by a UI test. Hover reporting is implemented but has not been driven with a
trackpad. The terminal exposes its rendered text as an accessibility value and every
control is labelled, but no VoiceOver session has been *heard* — the tests check structure,
which is not the same as listening to it. Increase Contrast selecting the high-contrast
terminal theme is still verified by reading the code, because the terminal itself needs a
live connection to screenshot at that setting.

### Not started

Instruments profiling of the *renderer* — the emulator is profiled, the Core Text drawing
path is not · SFTP · port forwarding · Spotlight.

---

## Blocking issues

### B-1 · RSA keys — **closed**

`rsa-sha2-256` and `rsa-sha2-512` are implemented in the vendored `swift-nio-ssh` and
verified against OpenSSH: an RSA user key authenticates against a real `sshd`, a server
offering **only** an RSA host key can be reached, and the same works over the Cloudflare
carrier. `ssh-keygen` and this app agree on an RSA key's fingerprint.

`ssh-rsa` (SHA-1) is **not** supported and will not be — OpenSSH disabled it by default in
8.8, and accepting it would ship a downgrade a server could ask for.

The change is `patches/niossh-rsa.patch`, which applies cleanly to pristine upstream at
tag `0.15.0`. Upstream's own suite still passes (347 tests, up from 346: one test used
`ssh-rsa` as its example of an unrecognised algorithm and was moved to `ssh-dss`, with a
new test added so the truncated-key case it covered is not lost).

### B-5 · The legal documents carry the owner's placeholders *(open, owner-only)*

The Terms of Use, Privacy Policy and User Notice ship in three languages with three values
in square brackets that only the project owner can supply: effective date, developer legal
name, and governing law and venue. There is no contact channel in the texts, by the owner's
decision — the Privacy Policy used to end its rights section by asking the reader to write
to an address, and now says instead that there is no request to make, because the developer
receives nothing and the controls that answer those rights are in the app itself.
The texts were drafted for review by counsel and say so in their first paragraph; they are
not legal advice until a lawyer has read them.

### B-6 · The assistant's live checks need what only the owner has *(open, owner-only)*

The provider path is proven against a local server speaking the same protocol; an answer
from a real provider needs an API key the owner supplies in Settings. The on-device path
needs a device eligible for Apple Intelligence: this Mac's simulator reports the model
available and then fails every request with an unexplained `GenerationError` (code −1),
which the app reports honestly and works around by falling back to the provider. Both are
listed as hardware checks in `docs/RELEASE.md`.

### B-4 · Archiving works; only the live iCloud checks and distribution signing are left *(mostly closed)*

Measured 2026-09-06, not assumed. A team is now set in the project
(`DEVELOPMENT_TEAM = 7CDDP73WJS`) and

```
xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates archive \
  -archivePath build/ApexTerminal.xcarchive
```

reports **ARCHIVE SUCCEEDED**. The signed product carries the entitlements this needed to
prove, read back off the archive with
`codesign -d --entitlements - --xml …/ApexTerminal.app`:

| entitlement | value |
| --- | --- |
| `application-identifier` | `7CDDP73WJS.dev.apexterminal.app` |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.dev.apexterminal.app` |
| `com.apple.developer.icloud-services` | `CloudKit` |

So the App ID has the iCloud capability and the container registered — the profile would
not carry them otherwise — and the earlier claim that an entitlement-free simulator build
made iCloud unexercisable no longer holds. A first archive attempt failed on missing
`*-linker-args.resp` files, which is stale `ArchiveIntermediates`, not signing; deleting
that directory and re-running succeeded.

What is genuinely left is not local:

* **Two signed devices on one Apple Account**, for the sync and iCloud Keychain checks in
  `docs/RELEASE.md`. One device cannot demonstrate sync.
* **The CloudKit schema deployed to production.** The development environment creates
  record types on first use; production does not.
* **A distribution certificate and App Store profile.** Only two *Apple Development*
  identities exist on this machine, so the archive is development-signed
  (`get-task-allow` is true) and cannot be exported for the App Store yet.

The sync engine remains verified against an in-memory transport; CloudKit's own behaviour
is still not live-verified, and nothing user-facing claims it is.

### B-3 · `trycloudflare.com` quick tunnels do not route from this network *(observed)*

Two quick tunnels were created successfully — `cloudflared` registered a connection to
`sjc07` over QUIC — but every request to the assigned hostname returned an empty-bodied
HTTP 404 from the Cloudflare edge, with no request ever reaching the tunnel. Both an
`ssh://` and an `http://` origin behaved identically, so this is not about the origin
scheme. Consequence: the no-account shortcut for live carrier testing is unavailable,
and B-2 cannot be worked around.

---

## What is needed from the project owner

These are the only things that cannot be produced locally. Each is listed with the
verification it unblocks, so nothing is requested speculatively.

**Ready to run now.** `scripts/live-e2e.sh` and `LiveCloudflareE2ETests` exist and are
skipped only because the environment is unset. Supplying items 1–3 makes a real
end-to-end run possible immediately, with no further code needed.

Do **not** paste secrets into chat. Export them in a shell, or keep them in a file
outside the working tree and `source` it — the script's header documents the variables.

1. **A Cloudflare Access-protected SSH hostname** fronted by a Cloudflare Tunnel whose
   ingress points at a test SSH server. → `ST_LIVE_CF_HOSTNAME`
   *Unblocks:* discovery, carrier, SSH handshake, interactive PTY over the real edge.
2. **An Access service token** (client ID + secret) authorised by that application's
   policy. → `ST_LIVE_CF_SERVICE_TOKEN_ID`, `ST_LIVE_CF_SERVICE_TOKEN_SECRET`
   *Unblocks:* the automated run, with no browser in the loop. This is the smallest
   thing that turns the central product claim from "implemented" into "verified".
3. **An SSH credential for that host** — a key path or a password, plus the username.
   → `ST_LIVE_SSH_USER` and one of `ST_LIVE_SSH_KEY_PATH` / `ST_LIVE_SSH_PASSWORD`

Needed later, not now:

4. **A test identity with MFA** for the interactive SSO login. That path runs through
   `ASWebAuthenticationSession` on a device; the app exists, so this is runnable as soon
   as an identity is available.
5. **A second signed device on the same Apple Account**, plus the CloudKit schema
   deployed to the *production* environment, plus a distribution certificate for export.
   The team, the iCloud capability and the container `iCloud.dev.apexterminal.app` are
   done — a Release archive succeeds and carries them (B-4). *Unblocks:* the remaining
   live iCloud checks in `docs/RELEASE.md` — CloudKit sync between two devices, iCloud
   Keychain for opted-in keys, purge on delete — and App Store export.
6. **The legal placeholders** (B-5): effective date, developer legal name, governing law
   and venue — in all three
   languages of `App/Resources/Legal/` — and a counsel review of the three texts.

---

## Environment

| | |
| --- | --- |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| iOS SDK | 26.5 |
| Deployment target | iOS/iPadOS 17.0 |
| Simulators | iPhone 17 / 17 Pro / 17 Pro Max / Air / 17e; iPad Pro 11" & 13" (M5), iPad Air 11" & 13" (M4), iPad mini (A17 Pro), iPad (A16) — all iOS 26.5 |
| Physical device | iPhone 16 Pro (paired, available) |
| Signing | Two Apple Development identities present; team ID for distribution not yet supplied |
| Tooling | `cloudflared` 2026.6.1, OpenSSH 10.2p1, Go 1.26.4, Docker/Colima available |
