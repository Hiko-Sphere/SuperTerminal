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

**Blocks.** iCloud sync, which is currently not offered at all.

---

## H-6 · Browse a server in the Files app on a real device

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
