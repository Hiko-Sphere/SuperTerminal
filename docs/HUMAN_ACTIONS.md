# What only the owner can do

Each item says why it needs a person, exactly where to go, what to supply, how to verify it
afterwards, and what stays unfinished until then. Nothing here is marked complete on the
strength of code alone.

---

## H-1 · Type Chinese into the terminal on a real device

**Why a person.** `UITextInput` composition is driven by the system input method. The
simulator can be switched to Pinyin, but candidate selection, the `⌫` behaviour inside a
composition and hardware-keyboard switching are input-method behaviours, not app
behaviours, and no automated test on this machine exercises the real one. The protocol
calls are covered by `TerminalCompositionTests` (D-039); the input method itself is not.

**Steps.** On an iPhone or iPad with the build installed:

1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Chinese, Simplified →
   Pinyin – QWERTY. Add Japanese → Kana, and Korean, if you want the other two paths.
2. Open Apex Terminal, connect to any server, and get a shell prompt.
3. Switch to Pinyin with 🌐 and type `nihao` **without** choosing a candidate.
   *Expect:* `nihao` appears underlined at the cursor, the candidate bar shows 你好, and the
   shell has received nothing — press ⌃C and the prompt is still clean.
4. Choose 你好.
   *Expect:* `你好` appears once, from the shell's own echo. Not twice, not `nihao你好`.
5. Type `nihao` again and press ⌫ five times.
   *Expect:* the underlined text shrinks one syllable at a time and then disappears. The
   shell receives nothing — no stray DEL deleting the prompt.
6. Press ⌫ once more.
   *Expect:* now the shell receives it, and the character before the cursor is erased.
7. Type `nihao`, then without choosing a candidate connect a hardware keyboard (or press a
   key on an attached Magic Keyboard) and type `x`.
   *Expect:* `x` reaches the shell and the abandoned Pinyin does not follow it.
8. Repeat 3–4 with Japanese Kana (`にほん`) and with Korean (`한글`).
9. Type an emoji from the emoji keyboard, and a letter with a combining accent.
   *Expect:* each arrives once and whole.

**Verification afterwards.** Record the result in `docs/RELEASE_EVIDENCE.md` against
D-039. Until step 4 and step 7 have both been seen on hardware, input-method support is
**implemented and unit-tested, not verified**, and must be described that way.

**Blocks.** Chinese, Japanese and Korean input into the terminal — which is to say, the
app's usefulness to the audience its own localisation is aimed at.

---

## H-2 · App Store Connect encryption answers

**Why a person.** Whether the app qualifies for the export exemption, and whether a
self-classification report is needed, depends on where it is sold and is a legal judgement.
This repository deliberately does not set `ITSAppUsesNonExemptEncryption`.

**Steps.** App Store Connect → the app → App Information → answer the encryption
questions using the table in `docs/EXPORT_COMPLIANCE.md`, which lists every algorithm, its
use, its origin and its licence. The one row needing attention is
`VNCBigInteger.swift`: modular exponentiation written in this repository because no Apple
API performs it over a server-chosen group.

**Verification afterwards.** The submission passes the encryption step without a follow-up
request from App Review.

**Blocks.** Submission. Nothing else.

---

## H-3 · A real Mac and a real VeNCrypt server

**Why a person.** The bundled LibVNCServer fixture serves neither RFB security type 30
(macOS Screen Sharing's account login) nor VeNCrypt. Both are implemented and verified
against vectors and a second implementation of the server half (D-031); neither has met a
real server.

**Steps.** See `docs/RELEASE.md`, the two remote-screen lines.

**Blocks.** Claiming macOS account login and VeNCrypt work. They are implemented, not
verified.

---

## H-4 · Cloudflare Access live environment (B-2)

**Why a person.** Needs a Cloudflare account, a tunnel, an Access application and a
service token. Unchanged from `PROJECT_STATUS.md`; the variables are documented in
`scripts/live-e2e.sh` and `docs/CLOUDFLARE.md`.

**Blocks.** The app's central product claim being *verified* rather than implemented.

---

## H-5 · iCloud sync container

**Why a person.** Every push is refused by the container with `CKErrorDomain 15` and
HTTP 500, no server description and no per-record errors, while pulling works — the
container's own state, which is fixed in the CloudKit Console (D-037). Sync is withdrawn
behind `SyncAvailability.isAvailable` until it is.

**Steps.** CloudKit Console → `iCloud.dev.apexterminal.app` → confirm the Development
environment exists and holds the `SyncRecord` type and the `ApexTerminal` zone; then
Deploy Schema to Production before any TestFlight build syncs.

**Verification afterwards.** Set `SyncAvailability.isAvailable = true`, run
`ApexTerminalTests`, then sync between two signed devices.

**What changed under this since it was written (D-075).** Two client-side defects were found
and fixed, and *neither was the cause* — but both were invisible, and both would have bitten
the moment the container started accepting writes:

* No write carried CloudKit's change tag, because every `CKRecord` was built fresh. The first
  write of a record would have succeeded and every write after it would have been refused with
  `serverRecordChanged`, permanently.
* `CKSyncEngine` reports per-record and per-zone failures on its *events*, not on the error
  thrown by `sendChanges()`. The transport read only the success halves, so a push the server
  refused returned the same empty list as a push with nothing to send.

The second one bears on this entry directly: while it stood, a refused push was reported as a
clean one. The HTTP 500 in the diagnosis was read off a real device (D-036) and is a
request-level status, so it stands — but when the container is fixed, re-measure rather than
assuming the rest of the picture is still accurate. `push` now throws when the server refused
everything, and records each failure through `SyncDiagnostics` in DEBUG, so the next
measurement will have something to read.

**Blocks.** iCloud sync, which is currently not offered at all.

---

## H-6 · Browse a server in the Files app on a real device

> **Corrected in D-073.** This entry used to say the extension aborting on the simulator was
> expected and unfixable, because "the simulator has no FPFS". That was wrong. The domain was
> being downgraded because `NSExtensionFileProviderSupportsEnumeration` was missing from the
> extension's Info.plist; `fileproviderd` refuses FPFS for a provider without it, and a
> non-replicated domain is served through an API this extension does not implement — `abort()`.
> The daemon's decision code is byte-for-byte the same in the simulator and the arm64e device
> runtime, so it would have aborted on a phone too. With the key in place the domain stays
> replicated here, the extension is no longer killed, and the end-to-end suite *runs* — it then
> times out waiting for the published folder to appear in the domain root, which is the real
> and much smaller thing this entry is now for.

**Why a person.** Not a matter of judgement this time — a matter of hardware. A replicated
File Provider domain is backed by FPFS, and the iOS Simulator does not have it.
`fileproviderd` says so in as many words and then quietly downgrades the domain:

```
domain <NSFileProviderDomain: … (disabled,replicated,syncTrash,userInfo)> was asked with
FPFS, but it's not supported, will fallback
Adding domain <NSFileProviderDomain: … (disabled,syncTrash,userInfo)>
```

The second line no longer says `replicated`. The system then serves that domain through
the older, non-replicated API, finds that the extension does not implement it — correctly,
because it is a replicated extension — and aborts the extension process in
`__FILEPROVIDER_V2_EXTENSION_WITHOUT_IMPL`. **Nothing about the feature can be concluded
from that**, and it is not a defect to be fixed. `FileProviderDomainTests` asserts the
downgrade so the diagnosis does not have to be made twice.

**Steps.** On an iPhone or iPad with the build installed, and a reachable SSH server:

1. Add a connection, connect once so its host key is checked and remembered, and save
   either a password or a key with no passphrase and no Face ID.
2. Edit the connection → Files → turn on **Show in the Files app**.
   *Expect:* the switch is enabled. If it is not, the footer says which of the three
   conditions is missing.
3. Open the Files app → Browse.
   *Expect:* the connection's name in the sidebar, under Locations.
4. Open it.
   *Expect:* the server's login directory, with the real files in it.
5. Open a text file, edit it in any app that can save back, and save.
   *Expect:* the change is on the server — check with `cat` over SSH, not in Files.
6. Create a folder, rename a file, drag a file in from iCloud Drive, and delete something.
   *Expect:* each one is real on the server, and Delete says Delete rather than offering a
   Trash this provider does not have.
7. Make a change on the server behind the app's back, then pull to refresh in Files.
   *Expect:* the listing catches up. It will not catch up on its own: SFTP cannot push.
8. Turn the switch off.
   *Expect:* the location disappears from Files.

**Automated version.** With the device attached and an SSH server reachable from it, the
whole of steps 3–5 is `FileProviderEndToEndTests`, which skips itself on the simulator:

```
ST_APP_TEST_SSH_HOST_OVERRIDE=<this Mac's LAN address> \
  ./scripts/app-integration-e2e.sh "platform=iOS,name=<device>"
```

**Verification afterwards.** Record the result in `docs/RELEASE_EVIDENCE.md` against
D-044.

**Blocks.** Claiming that servers appear in the Files app. Every layer beneath it is
verified against a real OpenSSH server — the protocol, the file operations, the
enumeration, the error mapping, the domain registration — but the system actually serving
those answers to Files has only been proven on hardware once this is done.

## H-7 · A Secure Enclave key gated on Face ID, on a real device

**Why a person is needed.** The Secure Enclave itself is available in the Simulator on
Apple silicon — measured, and the whole enclave SSH path is verified there against a real
OpenSSH server (D-049). Biometrics are not. Creating a key with the `.biometryCurrentSet`
policy in the Simulator fails inside LocalAuthentication with:

```
Error Domain=com.apple.LocalAuthentication Code=-1020
  "This call is not supported on iOS Simulator."
```

So the `deviceUnlocked` policy is proven and the `biometricsEachUse` policy is not. No
amount of code can close that gap; it needs hardware with Face ID or Touch ID enrolled.

**Exact steps.**

1. On an iPhone or iPad with Face ID or Touch ID set up, install the app and open
   Settings → Keys → Generate.
2. Enter a name, choose **In the Secure Enclave**, and leave **Require Face ID or Touch
   ID** on. Generate.
   *Expect:* the key is created and the confirmation screen shows an
   `ecdsa-sha2-nistp256 …` line. The Keys list shows both "In the Secure Enclave · cannot
   be exported" and "Unlocks with Face ID or Touch ID".
3. Copy the public key onto a server's `~/.ssh/authorized_keys`, and check the fingerprint
   matches what the app shows:
   `ssh-keygen -lf <the pasted line in a file>`.
4. Add a connection using that key and connect.
   *Expect:* **one** Face ID prompt, raised as the connection starts rather than part-way
   through the handshake, then a shell. Two prompts would mean the pre-authenticated
   `LAContext` did not satisfy the key's access control and the reuse window was not
   honoured — report that, it is a real defect. Cancelling the prompt must report that you
   cancelled, promptly, and not hang.
   *Also check:* open a second session to a different server at the same time and connect
   both. Neither should stall while the other's prompt is on screen.
5. Settings → General → Face ID & Passcode → add another face (or fingerprint), then
   connect again.
   *Expect:* the connection fails and the key is reported as no longer usable. This is the
   `.biometryCurrentSet` guarantee: enrolling a new biometric destroys the key.
6. Turn on Files for a connection that uses this key.
   *Expect:* the switch is refused with "needs a credential only you can provide" — a key
   that asks for Face ID at every signature cannot serve a background process.
7. Settings → Backup → Export with private keys included.
   *Expect:* the sheet lists the key by name as unexportable, saying it is held in the
   Secure Enclave.

**Verification afterwards.** Record what happened at each step in
`docs/RELEASE_EVIDENCE.md` against D-049.

**Blocks.** Claiming that the biometric policy for Secure Enclave keys works. Everything
else about those keys — creation, the SSH wire format, authentication against real
OpenSSH, the unattended policy in Files, the export refusal — is verified automatically
and does not depend on this.

## H-8 · A Mac Catalyst signing identity, and what it would unlock

**Why this is here.** Mac Catalyst is enabled and the app builds, launches and runs 316 of its
324 unit tests on this Mac (D-070). What it cannot do here is run *signed*, because this
machine has no Apple Developer team with a Mac Catalyst provisioning profile for
`dev.apexterminal.app`. Everything below needs one, and none of it can be faked.

**What is blocked, precisely.**

1. **The Keychain.** Eight unit tests fail with `errSecMissingEntitlement` (`-34018`) because
   the run has to be built with `CODE_SIGN_ENTITLEMENTS=""` to get past signing at all. The
   `keychain-access-groups` entitlement is what those tests need, and it needs a profile.
2. **The UI suite.** `xcodebuild … -only-testing:ApexTerminalUITests` on Mac Catalyst refuses
   to load the test bundle: *"mapping process and mapped file (non-platform) have different
   Team IDs"*. An ad-hoc signature gives the runner and the bundle different identities, and
   XCUITest will not load across that boundary. Every claim about how the app *looks and
   behaves* on the Mac is therefore unverified.
3. **Per-file data protection.** `completeFileProtection` fails on Mac Catalyst unless the app
   carries the Data Protection capability, which is granted through a provisioning profile.
   Until then the app writes atomically without it on the Mac — see
   `Data.WritingOptions.atomicAndProtected` — and the Mac's equivalent protection is FileVault,
   which is a system setting rather than something a file asks for.

**Steps.**

1. In Xcode, select the ApexTerminal target → Signing & Capabilities, choose a team, and let
   Xcode create a Mac Catalyst development profile.
2. Run the unit tests on the Mac:
   `xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ApexTerminalTests test`
   *Expect:* the eight `AppLockTests`, `ServiceTokenTests` and `ScreenConnectionTests` failures
   to go, because the Keychain group is now real.
3. Run the UI suite the same way, with the harness:
   `bash scripts/ui-terminal-e2e.sh 'platform=macOS,variant=Mac Catalyst'`.
   *Expect:* failures that are about a Mac rather than about signing — this is the first look
   at how the interface actually behaves there, and what it finds belongs in the plan.
4. Decide about data protection. Adding the Data Protection capability restores per-file
   protection on the Mac and would let `atomicAndProtected` ask for it everywhere; leaving it
   off means the privacy policy's "Encrypted while the device is locked" is an iOS statement
   and would need a sentence about the Mac before a Mac build ships.

**Blocks.** Any claim that Apex Terminal *works* on the Mac beyond "it builds, launches and its
logic passes its tests there". The plan says exactly that and no more.

## H-9 · The visionOS and watchOS simulator runtimes

**Why this is here.** Both SDKs are installed on this machine — `xcodebuild -showsdks` lists
visionOS 26.5 and watchOS 26.5 — and **no simulator runtime for either is**:
`xcrun simctl list runtimes` shows iOS 26.5 and nothing else. Neither platform could be run
even if the app compiled for it, so neither is started (Phase 4.2 and 4.3). Downloading a
platform is several gigabytes and is not something to start on somebody's machine unasked.

**Steps.**

1. `xcodebuild -downloadPlatform visionOS` and `xcodebuild -downloadPlatform watchOS`, or
   Xcode → Settings → Components.
2. Confirm with `xcrun simctl list runtimes` that a runtime for each appears.

**What it unblocks, and what it does not.**

* **visionOS.** The app is offered there today in Apple's *Designed for iPad* compatibility
  mode — `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD` is now set explicitly rather than left to a
  default, so it is a decision. It has **never been run** on visionOS by this project. With a
  runtime the first question is whether the iPad layout is usable in that mode; the second, and
  much larger, is whether a native visionOS target is worth building.
* **watchOS.** A runtime makes it buildable and testable, but not designed. A terminal does not
  fit a watch, and what would fit — a session's status, a stop button, a notification when a
  long command finishes — is a product question nobody has answered. It should not be started
  because the SDK is present.

**Blocks.** Every claim about visionOS or watchOS beyond "an iPad app is offered on visionOS in
compatibility mode, untried".
