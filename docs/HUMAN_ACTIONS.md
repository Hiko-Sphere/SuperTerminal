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
